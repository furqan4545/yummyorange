import AppKit
import PDFKit

/// PDF page organizer, PDF/A and PDF → SVG.
enum PDFExtras: FeatureModule {
    static var commands: [WheelCommand] {
        [
            WheelCommand(wheel: .tools, id: "organize", title: "Organize…", symbol: "square.grid.2x2",
                         combinesInputs: true, applies: PDFOrganizer.applies,
                         present: { PDFOrganizer.present($0) },
                         run: { files, options, progress in [try PDFOrganizer.run(files, options: options, progress: progress)] }),
            WheelCommand(wheel: .tools, id: "pdfa", title: "PDF/A", symbol: "archivebox",
                         applies: isPDFs,
                         run: { files, _, progress in try files.map { try PDFArchive.makePDFA($0, progress: progress) } }),
            WheelCommand(wheel: .convert, id: "svg", title: "SVG",
                         applies: isPDFs,
                         run: { files, options, progress in
                             try files.flatMap { try PDFSVG.convert($0, options: options, progress: progress) }
                         }),
        ]
    }

    /// Every file is a PDF (by extension, so it stays cheap while the wheel opens).
    static func isPDFs(_ files: [URL]) -> Bool { Ext.all(files, in: ["pdf"]) }

    static func snapshot(_ id: String, files: [URL], options: ToolOptions) -> NSView? {
        guard id == "organizer" else { return nil }
        return PDFOrganizer.snapshotView(files: files, options: options)
    }

    static func selfTest(_ name: String) -> String? {
        #if DEBUG
        switch name {
        case "pdf-extras", "pdfextras": return PDFExtrasSelfTest.run(["organizer", "pdfa", "svg", "tools"])
        case "pdf-organizer": return PDFExtrasSelfTest.run(["organizer"])
        case "pdf-tools": return PDFExtrasSelfTest.run(["tools"])
        case "pdfa": return PDFExtrasSelfTest.run(["pdfa"])
        case "pdf-svg": return PDFExtrasSelfTest.run(["svg"])
        default: return nil
        }
        #else
        return nil
        #endif
    }

    /// The same refusal PDFTools uses for locked files.
    static func lockedError(_ url: URL) -> ConversionError {
        .unsupported("\(url.lastPathComponent) is password-protected. Use Remove Password first.")
    }

    /// Something the user should know about a job that still saved its output (a page or slide left out):
    /// a HUD message in the app, shown after the job's own “Saved …” message, or a line on stderr.
    static func note(_ message: String) {
        let appMode = MainThread.sync { NSApp != nil && NSApp.activationPolicy() != .prohibited }
        if appMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { HUD.shared.flash(message, isError: true, seconds: 6) }
        } else {
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    }
}

// MARK: - PDF/A

/// Archival copies: every page is redrawn into a CGPDFContext created with `kCGPDFContextCreatePDFA`.
/// Redrawing keeps vectors, text and embedded fonts; macOS adds the sRGB output intent and the PDF/A XMP.
/// On this system the result identifies itself as PDF/A-2B (part 2, conformance B), although the SDK header
/// describes the key as PDF/A-2u. Each copy is checked after writing and removed if a check fails.
enum PDFArchive {
    /// What the checks found in a written file.
    struct Report {
        var pageCount = 0
        var part: String?
        var conformance: String?
        var encrypted = false
        var fonts = 0
        var unembeddedFonts: [String] = []
        var textCharacters = 0
        var hasOutputIntent = false
        /// Annotations checked for the Print flag (links, mostly).
        var annotations = 0

        var level: String { "PDF/A-\(part ?? "?")\((conformance ?? "?").lowercased())" }
    }

    static func makePDFA(_ url: URL, progress: @escaping (Double) -> Void) throws -> URL {
        guard let doc = PDFDocument(url: url), let cgDoc = doc.documentRef else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        if doc.isLocked { throw PDFExtras.lockedError(url) }
        guard doc.pageCount > 0 else { throw ConversionError.unsupported("\(url.lastPathComponent) has no pages.") }
        // Redrawing shows what a viewer shows, so layers that are switched off are left out of the copy.
        let hidesLayers = hasHiddenLayers(cgDoc)

        let out = outputURL(for: url, ext: "pdf", suffix: " PDFA")
        var info: [CFString: Any] = [kCGPDFContextCreatePDFA: kCFBooleanTrue as Any]
        let attributes = doc.documentAttributes ?? [:]
        func text(_ key: PDFDocumentAttribute) -> String? {
            if let s = attributes[key] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
            if let list = attributes[key] as? [String], !list.isEmpty { return list.joined(separator: ", ") }
            return nil
        }
        if let v = text(.titleAttribute) { info[kCGPDFContextTitle] = v }
        if let v = text(.authorAttribute) { info[kCGPDFContextAuthor] = v }
        if let v = text(.subjectAttribute) { info[kCGPDFContextSubject] = v }
        if let v = text(.creatorAttribute) { info[kCGPDFContextCreator] = v }
        if let list = attributes[PDFDocumentAttribute.keywordsAttribute] as? [String], !list.isEmpty { info[kCGPDFContextKeywords] = list }
        else if let v = text(.keywordsAttribute) { info[kCGPDFContextKeywords] = v }

        guard let ctx = CGContext(out as CFURL, mediaBox: nil, info as CFDictionary) else {
            throw ConversionError.toolFailed("Couldn’t create \(out.lastPathComponent).")
        }
        if let outline = cgDoc.outline { CGPDFContextSetOutline(ctx, outline) }

        // Internal links point at a page and a spot on it: name each target, then add them while drawing.
        let transforms = (0..<doc.pageCount).map { pageTransform(doc.page(at: $0)) }
        var targets: [Int: [(name: String, point: CGPoint)]] = [:]
        var linkTargets: [ObjectIdentifier: String] = [:]
        for i in 0..<doc.pageCount {
            for annotation in doc.page(at: i)?.annotations ?? [] where isLink(annotation) {
                guard let dest = destination(of: annotation), let page = dest.page else { continue }
                let index = doc.index(for: page)
                guard index >= 0, index < doc.pageCount else { continue }
                // Unspecified coordinates (kPDFDestinationUnspecifiedValue) mean "keep": use the page's top left.
                let box = page.bounds(for: .cropBox)
                let point = CGPoint(x: abs(dest.point.x) < 1e6 ? dest.point.x : box.minX,
                                    y: abs(dest.point.y) < 1e6 ? dest.point.y : box.maxY)
                let name = "dw-\(index)-\(Int(point.x))-\(Int(point.y))"
                if !(targets[index] ?? []).contains(where: { $0.name == name }) {
                    targets[index, default: []].append((name, point.applying(transforms[index].matrix)))
                }
                linkTargets[ObjectIdentifier(annotation)] = name
            }
        }

        for i in 0..<doc.pageCount {
            autoreleasepool {
                drawPage(i, of: doc, into: ctx, transform: transforms[i], targets: targets[i] ?? [], linkTargets: linkTargets)
            }
            progress(Double(i + 1) / Double(doc.pageCount) * 0.9)
        }
        ctx.closePDF()

        do {
            try addPrintFlags(out)
            try verify(out, against: doc, hiddenLayers: hidesLayers)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        if hidesLayers {
            PDFExtras.note("\(url.lastPathComponent) has layers that are switched off; \(out.lastPathComponent) leaves them out.")
        }
        progress(1)
        return out
    }

    /// Optional content that is off in the default view (/OCProperties /D: an /OFF list, or /BaseState /OFF).
    static func hasHiddenLayers(_ doc: CGPDFDocument) -> Bool {
        let config = PDFSVGObj.dict(PDFSVGObj.dict(doc.catalog, "OCProperties"), "D")
        if let off = PDFSVGObj.array(config, "OFF"), CGPDFArrayGetCount(off) > 0 { return true }
        return PDFSVGObj.name(config, "BaseState") == "OFF"
    }

    /// Core Graphics writes its link annotations without an /F entry, while PDF/A (ISO 19005-2, 6.3.2) wants
    /// every annotation but a pop-up to have one with the Print flag set. The entry is added in an incremental
    /// update, so the bytes Core Graphics wrote (with the PDF/A identification, output intent and fonts) stay
    /// as they are. A file this can't parse is left alone; verify() then reports the problem.
    static func addPrintFlags(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let pdf = PDFRawFile(data)
        guard let xref = pdf.crossReference() else { return }
        var objects: [(number: Int, generation: Int, bytes: [UInt8])] = []
        for (number, entry) in xref.entries.sorted(by: { $0.key < $1.key }) {
            guard let dict = pdf.objectDictionary(number: number, generation: entry.generation, at: entry.offset) else { continue }
            let values = dict.values
            let isAnnotation = values["Type"] == "/Annot" || values["Subtype"] == "/Link"
            guard isAnnotation, values["Subtype"] != "/Popup", values["F"] == nil else { continue }
            objects.append((number, entry.generation, Array(dict.bytes.dropLast(2)) + Array(" /F 4 >>".utf8)))
        }
        guard !objects.isEmpty else { return }
        var tail: [UInt8] = data.last == 0x0A || data.last == 0x0D ? [] : [0x0A]
        var entries: [(number: Int, generation: Int, offset: Int)] = []
        for object in objects {
            entries.append((object.number, object.generation, data.count + tail.count))
            tail += Array("\(object.number) \(object.generation) obj\n".utf8) + object.bytes + Array("\nendobj\n".utf8)
        }
        let xrefOffset = data.count + tail.count
        var text = "xref\n"
        for e in entries { text += "\(e.number) 1\n" + String(format: "%010d %05d n \n", e.offset, e.generation) }
        var trailer = "/Size \(max(xref.size, (entries.map(\.number).max() ?? 0) + 1))"
        for key in ["Root", "Info", "ID"] { if let v = xref.trailer[key] { trailer += " /\(key) \(v)" } }
        trailer += " /Prev \(xref.start)"
        text += "trailer\n<< \(trailer) >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        var updated = data
        updated.append(contentsOf: tail + Array(text.utf8))
        try updated.write(to: url, options: .atomic)
    }

    /// One page: content, visible annotations flattened into it, then link areas and link targets.
    private static func drawPage(_ i: Int, of doc: PDFDocument, into ctx: CGContext,
                                 transform t: (matrix: CGAffineTransform, size: CGSize),
                                 targets: [(name: String, point: CGPoint)], linkTargets: [ObjectIdentifier: String]) {
        guard let page = doc.page(at: i), let ref = page.pageRef else { return }
        var media = CGRect(origin: .zero, size: t.size)
        let boxData = withUnsafeBytes(of: &media) { Data($0) }
        ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
        ctx.saveGState()
        ctx.concatenate(t.matrix)
        ctx.clip(to: ref.getBoxRect(.cropBox))
        // A page without /Contents is blank (drawing it would only log an error).
        if PDFSVGObj.object(ref.dictionary, "Contents") != nil { ctx.drawPDFPage(ref) }
        ctx.restoreGState()
        // Visible annotations (form fields, stamps, drawings) become part of the page, as when printed.
        // PDFKit applies the crop box and /Rotate itself, so they're drawn in the upright page's space.
        ctx.saveGState()
        ctx.clip(to: CGRect(origin: .zero, size: t.size))
        for annotation in page.annotations where annotation.shouldDisplay && !isLink(annotation) && annotation.type != "Popup" {
            annotation.draw(with: .cropBox, in: ctx)
        }
        ctx.restoreGState()
        for target in targets { ctx.addDestination(target.name as CFString, at: target.point) }
        for annotation in page.annotations where isLink(annotation) {
            let rect = annotation.bounds.applying(t.matrix)
            if let url = linkURL(of: annotation) { ctx.setURL(url as CFURL, for: rect) }
            else if let name = linkTargets[ObjectIdentifier(annotation)] { ctx.setDestination(name as CFString, for: rect) }
        }
        ctx.endPDFPage()
    }

    /// The transform from a page's own space to an upright page of its visible size (crop box and /Rotate applied).
    static func pageTransform(_ page: PDFPage?) -> (matrix: CGAffineTransform, size: CGSize) {
        guard let ref = page?.pageRef else { return (.identity, CGSize(width: 612, height: 792)) }
        let crop = ref.getBoxRect(.cropBox)
        let turns = ((ref.rotationAngle % 360) + 360) % 360 / 90
        let size = turns % 2 == 1 ? CGSize(width: crop.height, height: crop.width) : crop.size
        let matrix = ref.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0,
                                             preserveAspectRatio: true)
        return (matrix, size)
    }

    private static func isLink(_ annotation: PDFAnnotation) -> Bool { annotation.type == "Link" }

    private static func linkURL(of annotation: PDFAnnotation) -> URL? {
        if let url = annotation.url { return url }
        return (annotation.action as? PDFActionURL)?.url
    }

    private static func destination(of annotation: PDFAnnotation) -> PDFDestination? {
        annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination
    }

    /// Checks a written PDF/A file: it opens, has the source's pages at the same sizes, still has its text,
    /// carries PDF/A identification and an output intent, embeds every font and isn't encrypted.
    /// `hiddenLayers`: the source has layers that are off, which the copy leaves out, so its text is compared
    /// with a plain redraw of the source instead of everything PDFKit extracts (which includes hidden layers).
    @discardableResult
    static func verify(_ out: URL, against source: PDFDocument, hiddenLayers: Bool = false) throws -> Report {
        func fail(_ why: String) -> ConversionError {
            .toolFailed("The PDF/A copy didn’t pass its checks: \(why).")
        }
        guard let doc = PDFDocument(url: out), let cg = doc.documentRef else { throw fail("it doesn’t open") }
        var report = inspect(cg)
        if report.encrypted { throw fail("it’s encrypted") }
        guard report.pageCount == source.pageCount else {
            throw fail("it has \(report.pageCount) pages instead of \(source.pageCount)")
        }
        for i in 0..<source.pageCount {
            let want = pageTransform(source.page(at: i)).size
            let got = doc.page(at: i)?.bounds(for: .mediaBox).size ?? .zero
            if abs(want.width - got.width) > 0.5 || abs(want.height - got.height) > 0.5 {
                throw fail("page \(i + 1) changed size")
            }
        }
        guard report.part != nil, report.conformance != nil else { throw fail("it has no PDF/A identification") }
        guard report.hasOutputIntent else { throw fail("it has no output intent") }
        if !report.unembeddedFonts.isEmpty {
            throw fail("these fonts aren’t embedded: \(report.unembeddedFonts.prefix(5).joined(separator: ", "))")
        }
        // ISO 19005-2, 6.3.2: every annotation but a pop-up prints, and none is hidden.
        for i in 0..<cg.numberOfPages {
            guard let annots = PDFSVGObj.array(cg.page(at: i + 1)?.dictionary, "Annots") else { continue }
            for k in 0..<CGPDFArrayGetCount(annots) {
                var a: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annots, k, &a), let a, PDFSVGObj.name(a, "Subtype") != "Popup" else { continue }
                report.annotations += 1
                let flags = PDFSVGObj.int(a, "F") ?? 0
                if flags & 4 == 0 || flags & (1 | 2 | 32 | 256) != 0 {
                    throw fail("a link or annotation on page \(i + 1) isn’t marked to print")
                }
            }
        }
        // Text: compare up to 12 pages spread through the document (PDFKit's text extraction keeps a
        // lot in memory, so a 300-page file isn't read twice in full).
        let sample = Array(Set((0..<min(12, source.pageCount)).map { $0 * source.pageCount / min(12, source.pageCount) })).sorted()
        func letters(_ d: PDFDocument, _ i: Int) -> Int {
            autoreleasepool {
                d.page(at: i)?.string?.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count ?? 0
            }
        }
        let before = sample.reduce(0) { total, i in
            total + (hiddenLayers ? autoreleasepool { redrawnLetters(source.page(at: i)) } : letters(source, i))
        }
        report.textCharacters = sample.reduce(0) { $0 + letters(doc, $1) }
        if before > 0 && Double(report.textCharacters) < Double(before) * 0.9 {
            throw fail("only \(report.textCharacters) of the \(before) text characters on the pages checked can still be "
                       + "selected and searched")
        }
        return report
    }

    /// Non-space characters PDFKit reads from a page redrawn into a plain PDF, the way drawPage draws it
    /// (so without layers that are switched off).
    private static func redrawnLetters(_ page: PDFPage?) -> Int {
        guard let page, let ref = page.pageRef else { return 0 }
        let t = pageTransform(page)
        let data = NSMutableData()
        var media = CGRect(origin: .zero, size: t.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { return 0 }
        ctx.beginPDFPage(nil)
        ctx.concatenate(t.matrix)
        ctx.clip(to: ref.getBoxRect(.cropBox))
        if PDFSVGObj.object(ref.dictionary, "Contents") != nil { ctx.drawPDFPage(ref) }
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)?.string?.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count ?? 0
    }

    /// Reads PDF/A identification, output intents, encryption and font embedding from a document.
    static func inspect(_ doc: CGPDFDocument) -> Report {
        var report = Report()
        report.pageCount = doc.numberOfPages
        report.encrypted = doc.isEncrypted
        if let catalog = doc.catalog {
            var metadata: CGPDFStreamRef?
            if CGPDFDictionaryGetStream(catalog, "Metadata", &metadata), let metadata {
                var format = CGPDFDataFormat.raw
                if let data = CGPDFStreamCopyData(metadata, &format) as Data?,
                   let xmp = String(data: data, encoding: .utf8) {
                    report.part = xmpValue("pdfaid:part", in: xmp)
                    report.conformance = xmpValue("pdfaid:conformance", in: xmp)
                }
            }
            var intents: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(catalog, "OutputIntents", &intents), let intents, CGPDFArrayGetCount(intents) > 0 {
                report.hasOutputIntent = true
            }
        }
        var seen = Set<UnsafeRawPointer>()
        var fonts: [String: Bool] = [:]
        func walk(resources: CGPDFDictionaryRef?, depth: Int) {
            guard let resources, depth < 12, seen.insert(PDFSVGObj.key(resources)).inserted else { return }
            var fontDict: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(resources, "Font", &fontDict), let fontDict {
                CGPDFDictionaryApplyBlock(fontDict, { _, object, _ in
                    var font: CGPDFDictionaryRef?
                    if CGPDFObjectGetValue(object, .dictionary, &font), let font {
                        let (name, embedded) = fontEmbedding(font)
                        fonts[name] = (fonts[name] ?? true) && embedded
                        var res: CGPDFDictionaryRef?
                        if CGPDFDictionaryGetDictionary(font, "Resources", &res) { walk(resources: res, depth: depth + 1) }
                    }
                    return true
                }, nil)
            }
            for key in ["XObject", "Pattern"] {
                var dict: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(resources, key, &dict), let dict else { continue }
                CGPDFDictionaryApplyBlock(dict, { _, object, _ in
                    var stream: CGPDFStreamRef?
                    if CGPDFObjectGetValue(object, .stream, &stream), let stream, let sd = CGPDFStreamGetDictionary(stream) {
                        var res: CGPDFDictionaryRef?
                        if CGPDFDictionaryGetDictionary(sd, "Resources", &res) { walk(resources: res, depth: depth + 1) }
                    }
                    return true
                }, nil)
            }
        }
        for i in 0..<doc.numberOfPages {
            guard let page = doc.page(at: i + 1)?.dictionary else { continue }
            var res: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(page, "Resources", &res) { walk(resources: res, depth: 0) }
        }
        report.fonts = fonts.count
        report.unembeddedFonts = fonts.filter { !$0.value }.map(\.key).sorted()
        return report
    }

    /// A font's name and whether its program is in the file (Type 3 fonts are drawn by the file itself).
    private static func fontEmbedding(_ font: CGPDFDictionaryRef) -> (String, Bool) {
        var cname: UnsafePointer<Int8>?
        let name = CGPDFDictionaryGetName(font, "BaseFont", &cname) && cname != nil ? String(cString: cname!) : "unnamed"
        var subtype: UnsafePointer<Int8>?
        _ = CGPDFDictionaryGetName(font, "Subtype", &subtype)
        let kind = subtype.map { String(cString: $0) } ?? ""
        if kind == "Type3" { return (name, true) }
        var target = font
        if kind == "Type0" {
            var descendants: CGPDFArrayRef?
            var first: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetArray(font, "DescendantFonts", &descendants), let descendants,
                  CGPDFArrayGetDictionary(descendants, 0, &first), let first else { return (name, false) }
            target = first
        }
        var descriptor: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(target, "FontDescriptor", &descriptor), let descriptor else { return (name, false) }
        return (name, PDFSVGObj.stream(descriptor, "FontFile", "FontFile2", "FontFile3") != nil)
    }

    /// `<pdfaid:part>2</pdfaid:part>` or `pdfaid:part="2"`.
    private static func xmpValue(_ key: String, in xmp: String) -> String? {
        for pattern in ["<\(key)>\\s*([^<\\s]+)\\s*</\(key)>", "\(key)\\s*=\\s*[\"']([^\"']+)[\"']"] {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let m = regex.firstMatch(in: xmp, range: NSRange(xmp.startIndex..., in: xmp)),
               let r = Range(m.range(at: 1), in: xmp) {
                return String(xmp[r])
            }
        }
        return nil
    }
}

// MARK: - Raw PDF reading

/// Just enough PDF syntax to read a classic cross-reference table, a trailer and the top-level entries of an
/// object's dictionary, byte for byte (for small incremental updates such as `PDFArchive.addPrintFlags`).
struct PDFRawFile {
    private let b: [UInt8]

    init(_ data: Data) { b = [UInt8](data) }

    struct CrossReference {
        var entries: [Int: (offset: Int, generation: Int)] = [:]
        var trailer: [String: String] = [:]
        var start = 0
        var size = 0
    }

    /// The newest cross-reference section and the ones it chains to with /Prev. Nil for cross-reference
    /// streams and anything malformed.
    func crossReference() -> CrossReference? {
        guard let keyword = lastIndex(of: "startxref"),
              let (startText, _) = token(skipWhitespace(keyword + 9)), let start = Int(startText) else { return nil }
        var result = CrossReference()
        result.start = start
        var offset = start
        var visited = Set<Int>()
        while visited.insert(offset).inserted, visited.count <= 32 {
            guard offset >= 0, offset < b.count else { return nil }
            var i = skipWhitespace(offset)
            guard matches(i, "xref") else { return nil }
            i += 4
            while true {
                i = skipWhitespace(i)
                if matches(i, "trailer") { i += 7; break }
                guard let (firstText, a) = token(i), let first = Int(firstText),
                      let (countText, c) = token(skipWhitespace(a)), let count = Int(countText),
                      first >= 0, count >= 0, count < 10_000_000 else { return nil }
                i = c
                for n in 0..<count {
                    guard let (offText, o) = token(skipWhitespace(i)), let off = Int(offText),
                          let (genText, g) = token(skipWhitespace(o)), let gen = Int(genText),
                          let (kind, k) = token(skipWhitespace(g)) else { return nil }
                    i = k
                    if kind == "n", result.entries[first + n] == nil { result.entries[first + n] = (off, gen) }
                }
            }
            guard let trailer = dictionary(at: skipWhitespace(i)) else { return nil }
            if visited.count == 1 {
                result.trailer = trailer.values
                result.size = Int(trailer.values["Size"] ?? "") ?? 0
            }
            guard let prev = trailer.values["Prev"].flatMap({ Int($0) }) else { break }
            offset = prev
        }
        return result
    }

    /// The dictionary of object `number` at `offset` (not a stream's), with its exact bytes.
    func objectDictionary(number: Int, generation: Int, at offset: Int) -> (values: [String: String], bytes: ArraySlice<UInt8>)? {
        guard offset >= 0, offset < b.count,
              let (n, a) = token(skipWhitespace(offset)), Int(n) == number,
              let (g, c) = token(skipWhitespace(a)), Int(g) == generation,
              let (keyword, k) = token(skipWhitespace(c)), keyword == "obj" else { return nil }
        let start = skipWhitespace(k)
        guard let dict = dictionary(at: start) else { return nil }
        if matches(skipWhitespace(dict.end), "stream") { return nil }
        return (dict.values, b[start..<dict.end])
    }

    /// Top-level entries of the dictionary at `i`: key without the slash → value as written
    /// (an indirect reference as "12 0 R").
    func dictionary(at i: Int, depth: Int = 0) -> (values: [String: String], end: Int)? {
        guard depth < 100, i >= 0, i + 1 < b.count, b[i] == 0x3C, b[i + 1] == 0x3C else { return nil }
        var items: [Range<Int>] = []
        var j = i + 2
        while true {
            j = skipWhitespace(j)
            guard j < b.count else { return nil }
            if b[j] == 0x3E, j + 1 < b.count, b[j + 1] == 0x3E { break }
            guard let end = objectEnd(j, depth: depth + 1) else { return nil }
            items.append(j..<end)
            j = end
        }
        func text(_ r: Range<Int>) -> String { String(decoding: b[r], as: UTF8.self) }
        var values: [String: String] = [:]
        var k = 0
        while k + 1 < items.count {
            let key = text(items[k])
            guard key.hasPrefix("/") else { k += 1; continue }
            var value = text(items[k + 1])
            var next = k + 2
            if k + 3 < items.count, Int(value) != nil, Int(text(items[k + 2])) != nil, text(items[k + 3]) == "R" {
                value += " " + text(items[k + 2]) + " R"
                next = k + 4
            }
            values[String(key.dropFirst())] = value
            k = next
        }
        return (values, j + 2)
    }

    private static func isWhitespace(_ c: UInt8) -> Bool { c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32 }
    private static func isDelimiter(_ c: UInt8) -> Bool {
        c == 0x28 || c == 0x29 || c == 0x3C || c == 0x3E || c == 0x5B || c == 0x5D || c == 0x7B || c == 0x7D || c == 0x2F || c == 0x25
    }

    private func skipWhitespace(_ i: Int) -> Int {
        var i = max(0, i)
        while i < b.count {
            if Self.isWhitespace(b[i]) { i += 1 }
            else if b[i] == 0x25 { while i < b.count, b[i] != 10, b[i] != 13 { i += 1 } }   // comment
            else { break }
        }
        return i
    }

    /// A run of regular characters at `i`.
    private func token(_ i: Int) -> (String, Int)? {
        var j = i
        while j < b.count, !Self.isWhitespace(b[j]), !Self.isDelimiter(b[j]) { j += 1 }
        return j > i ? (String(decoding: b[i..<j], as: UTF8.self), j) : nil
    }

    private func matches(_ i: Int, _ keyword: String) -> Bool {
        let k = Array(keyword.utf8)
        guard i >= 0, i + k.count <= b.count, Array(b[i..<(i + k.count)]) == k else { return false }
        return i + k.count == b.count || Self.isWhitespace(b[i + k.count]) || Self.isDelimiter(b[i + k.count])
    }

    private func lastIndex(of keyword: String) -> Int? {
        let k = Array(keyword.utf8)
        var i = b.count - k.count
        let stop = max(0, b.count - 8192)
        while i >= stop {
            if b[i] == k[0], Array(b[i..<(i + k.count)]) == k { return i }
            i -= 1
        }
        return nil
    }

    /// Where the object starting at `i` ends (exclusive).
    private func objectEnd(_ i: Int, depth: Int) -> Int? {
        guard i < b.count, depth < 100 else { return nil }
        switch b[i] {
        case 0x3C where i + 1 < b.count && b[i + 1] == 0x3C:   // << dictionary >>
            return dictionary(at: i, depth: depth + 1)?.end
        case 0x3C:   // <hex string>
            var j = i + 1
            while j < b.count, b[j] != 0x3E { j += 1 }
            return j < b.count ? j + 1 : nil
        case 0x5B:   // [ array ]
            var j = i + 1
            while true {
                j = skipWhitespace(j)
                guard j < b.count else { return nil }
                if b[j] == 0x5D { return j + 1 }
                guard let end = objectEnd(j, depth: depth + 1) else { return nil }
                j = end
            }
        case 0x28:   // (literal string), with nested parentheses and escapes
            var j = i + 1, level = 1
            while j < b.count {
                if b[j] == 0x5C { j += 2; continue }
                if b[j] == 0x28 { level += 1 } else if b[j] == 0x29 { level -= 1; if level == 0 { return j + 1 } }
                j += 1
            }
            return nil
        case 0x2F:   // /Name
            var j = i + 1
            while j < b.count, !Self.isWhitespace(b[j]), !Self.isDelimiter(b[j]) { j += 1 }
            return j
        case 0x29, 0x3E, 0x5D, 0x7B, 0x7D:
            return nil
        default:
            return token(i)?.1
        }
    }
}
