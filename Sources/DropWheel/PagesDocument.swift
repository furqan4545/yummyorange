import AppKit

// Apple Pages documents, read-only. A `.pages` file is a ZIP (or a package folder) holding the document
// as `.iwa` archives under Index/ (or inside an Index.zip in older packages): Snappy-compressed protobuf
// objects. The body text lives in a TSWP storage object (its text plus tables of paragraph styles,
// character styles, list styles and attachments by character index); images are TSD image objects that
// point at files under Data/. Pages '09 documents (index.xml) are read too.

private typealias Run = EbooksAndPages.Run
private typealias Block = EbooksAndPages.Block
private typealias Doc = EbooksAndPages.Doc

enum PagesDocument {
    /// The document's text and images. `floating`: "auto" (default) adds text boxes and pictures placed
    /// on pages when the body itself is empty (page-layout documents), "yes" always, "no" never.
    static func read(_ url: URL, floating: String = "auto") throws -> EbooksAndPages.Doc {
        let name = url.lastPathComponent
        let package: EbooksAndPages.Package
        package = try EbooksAndPages.Package(url, kind: "a Pages document")
        var doc: Doc
        if let iwa = try iwaFiles(package) {
            var objects: [UInt64: PagesObject] = [:]
            var mainFailed: Error?
            for (path, data) in iwa {
                do {
                    for object in try PagesIWA.objects(PagesIWA.decompress([UInt8](data))) { objects[object.id] = object }
                } catch {
                    if path.hasSuffix("Document.iwa") { mainFailed = error }
                }
            }
            let damaged = mainFailed.map {
                ConversionError.unsupported("\(name) is damaged, so its text can’t be read (\($0.localizedDescription))")
            }
            if let damaged, objects.isEmpty { throw damaged }
            var reader = IWAReader(objects: objects, package: package)
            let tooDeep = ConversionError.unsupported(
                "\(name) has text boxes or groups nested more than \(IWAReader.maxNesting) deep, so YummyOrange can’t convert it.")
            do {
                doc = try reader.document(floating: floating)
            } catch {
                if reader.tooDeep { throw tooDeep }
                // Metadata.iwa and the stylesheet always read; no text after a broken Document.iwa means
                // the text was in the part that broke.
                if let damaged { throw damaged }
                throw error
            }
            if reader.tooDeep { throw tooDeep }
        } else if let xml = try legacyXML(package) {
            doc = try legacyDocument(xml, name: name)
        } else {
            throw ConversionError.unsupported("\(name) doesn’t contain a Pages document YummyOrange can read.")
        }
        if doc.title == nil {
            doc.title = url.deletingPathExtension().lastPathComponent
        }
        return doc
    }

    /// A rendering Pages stored inside the document, if any: QuickLook/Preview.pdf (all pages), or a
    /// preview image of the first page.
    static func storedPreview(_ url: URL) -> (data: Data, isPDF: Bool)? {
        guard let package = try? EbooksAndPages.Package(url) else { return nil }
        if let pdf = try? package.data("QuickLook/Preview.pdf") { return (pdf, true) }
        for name in ["preview.jpg", "QuickLook/Thumbnail.jpg", "preview-web.jpg"] {
            if let jpg = try? package.data(name) { return (jpg, false) }
        }
        return nil
    }

    /// The `.iwa` archives: Index/*.iwa directly, or inside an Index.zip. nil when there are none.
    private static func iwaFiles(_ package: EbooksAndPages.Package) throws -> [(String, Data)]? {
        let direct = package.paths.filter { $0.lowercased().hasPrefix("index/") && $0.lowercased().hasSuffix(".iwa") }
        if !direct.isEmpty { return try direct.map { ($0, try package.data($0)) } }
        if let indexZip = try? package.data("Index.zip") {
            let inner = try ZipReader(data: indexZip)
            let files = inner.names.filter { $0.lowercased().hasSuffix(".iwa") }
            if !files.isEmpty { return try files.map { ($0, try inner.read($0)) } }
        }
        return nil
    }

    // MARK: IWA

    private struct ParaStyle {
        var name = ""
        var bold: Bool?
        var italic: Bool?
        var size: Double?
        var font: String?
        var color: String?
        var align: EbooksAndPages.Align?
    }

    private struct IWAReader {
        let objects: [UInt64: PagesObject]
        let package: EbooksAndPages.Package
        var doc = Doc()
        var styles: [UInt64: ParaStyle] = [:]
        /// Text storages and drawables already converted: each object goes in once, however many places
        /// point at it (shared or cyclic references can't repeat or loop the walk).
        var emitted: Set<UInt64> = []
        /// Storages and drawables open on the walk right now; past `maxNesting` the rest is left out and
        /// `tooDeep` makes the conversion fail (rather than silently dropping text).
        var nesting = 0
        var tooDeep = false
        static let maxNesting = 40
        var dataFiles: [UInt64: String] = [:]
        var bodySize: Double = 12
        var languages: [String: Int] = [:]
        /// How many text storages deep we are: 1 is the body (or a floating text box), more is a text
        /// box anchored inside it, whose big styled lines shouldn't become the book's chapters.
        var storageDepth = 0
        var totalText = 0

        init(objects: [UInt64: PagesObject], package: EbooksAndPages.Package) {
            self.objects = objects
            self.package = package
            // Data identifiers → files under Data/ (TSP.PackageMetadata, type 11006).
            let dataPaths = package.paths.filter { $0.hasPrefix("Data/") }
            for object in objects.values where object.type == 11006 {
                for info in object.message.messages(4) {
                    guard let id = info.uint(1) else { continue }
                    let fileName = info.string(4) ?? ""
                    let preferred = info.string(3) ?? ""
                    var path: String?
                    if !fileName.isEmpty, package.exists("Data/" + fileName) { path = "Data/" + fileName }
                    if path == nil {
                        path = dataPaths.first { p in
                            let stem = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
                            return stem.hasSuffix("-\(id)")
                        }
                    }
                    if path == nil, !preferred.isEmpty, package.exists("Data/" + preferred) { path = "Data/" + preferred }
                    if let path { dataFiles[id] = path }
                }
            }
        }

        mutating func document(floating: String) throws -> Doc {
            let documentArchive = objects.values.first { $0.type == 10000 }
            var bodyID = documentArchive?.message.ref(4)
            if bodyID.flatMap({ objects[$0] }).map(isStorage) != true {
                // No document archive (or a different layout): the largest body-kind text storage.
                bodyID = objects.values.filter { isStorage($0) && ($0.message.uint(1) ?? 3) == 0 }
                    .max { text(of: $0).count < text(of: $1).count }?.id
            }
            bodySize = estimateBodySize()
            if let bodyID { storageBlocks(bodyID) }

            let bodyHasText = doc.hasText
            if floating == "yes" || (floating == "auto" && !bodyHasText),
               let floatingID = documentArchive?.message.ref(3), let groups = objects[floatingID]?.message.messages(1) {
                let pages = groups.map { group -> (Int, [UInt64]) in
                    var ids: [UInt64] = []
                    for f in group.fields where f.number != 1 {
                        guard case .bytes(let r) = f.value, let entry = try? PagesProto(group.storage, range: r) else { continue }
                        if let id = entry.ref(1) { ids.append(id) }
                    }
                    return (Int(clamping: group.uint(1) ?? 0), ids)
                }.sorted { $0.0 < $1.0 }
                for (k, page) in pages.enumerated() {
                    let before = doc.blocks.count
                    for id in sortedByPosition(page.1) { drawableBlocks(id) }
                    if doc.blocks.count > before, k < pages.count - 1 { doc.blocks.append(.pageBreak) }
                }
            }
            doc.blocks = EbooksAndPages.tidyPageBreaks(doc.blocks)
            // The storage's language table often marks only a few runs; trust it only when it covers most text.
            let total = max(1, totalText)
            if let best = languages.max(by: { $0.value < $1.value }), best.value * 2 >= total { doc.language = best.key }
            guard doc.hasText || doc.blocks.contains(where: { if case .image = $0 { return true }; return false }) else {
                throw ConversionError.unsupported("This Pages document has no text YummyOrange can read.")
            }
            // Use a lone level-1 heading at the top as the title.
            if let first = doc.blocks.first, case let .heading(1, runs) = first {
                doc.title = EbooksAndPages.plain(runs)
            }
            return doc
        }

        private func isStorage(_ o: PagesObject) -> Bool { o.type == 2001 || o.type == 2005 }

        private func text(of o: PagesObject) -> String { o.message.strings(3).joined() }

        /// The font size used by the most body text, for spotting headings set as big bold text.
        private mutating func estimateBodySize() -> Double {
            var counts: [Double: Int] = [:]
            for o in objects.values where o.type == 2022 {
                if let size = PagesDocument.fontSize(o.message.message(11)?.float(3)), style(o.id).name.lowercased().hasPrefix("body") {
                    counts[size, default: 0] += 1
                }
            }
            return counts.max { $0.value < $1.value }?.key ?? 12
        }

        // MARK: Styles

        /// A paragraph or character style with its parents' values filled in.
        mutating func style(_ id: UInt64) -> ParaStyle {
            if let s = styles[id] { return s }
            var s = ParaStyle()
            var current: UInt64? = id
            var seen: Set<UInt64> = []
            while let cid = current, !seen.contains(cid), let o = objects[cid] {
                seen.insert(cid)
                let m = o.message
                let base = m.message(1)
                if s.name.isEmpty, let n = base?.string(1) { s.name = n }
                if let chars = m.message(11) {
                    if s.bold == nil { s.bold = chars.bool(1) }
                    if s.italic == nil { s.italic = chars.bool(2) }
                    if s.size == nil { s.size = PagesDocument.fontSize(chars.float(3)) }
                    if s.font == nil, let f = chars.string(5), !f.isEmpty { s.font = f }
                    if s.color == nil, let c = chars.message(7) { s.color = hexColor(c) }
                }
                if s.align == nil, let para = m.message(12), let a = para.uint(1) {
                    s.align = [0: .left, 1: .right, 2: .center, 3: .justify, 4: .natural][a]
                }
                current = base?.ref(3)
            }
            if let f = s.font {
                let lower = f.lowercased()
                if s.bold == nil, ["bold", "black", "heavy", "semibold"].contains(where: lower.contains) { s.bold = true }
                if s.italic == nil, lower.contains("italic") || lower.contains("oblique") { s.italic = true }
            }
            styles[id] = s
            return s
        }

        /// TSP.Color as #RRGGBB. Near-white colours are dropped: they are meant for dark backgrounds
        /// (photos, shapes) that the conversion doesn't carry over.
        private func hexColor(_ c: PagesProto) -> String? {
            guard let rawR = c.float(3), let rawG = c.float(4), let rawB = c.float(5),
                  [rawR, rawG, rawB].allSatisfy({ $0.isFinite }) else { return nil }
            let r = min(1, max(0, rawR)), g = min(1, max(0, rawG)), b = min(1, max(0, rawB))
            if 0.299 * r + 0.587 * g + 0.114 * b > 0.8 { return nil }
            let hex = String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
            return hex == "#000000" ? nil : hex
        }

        private static let headingNames: [String: Int] = [
            "title": 1, "chapter": 1, "chapter title": 1, "part": 1, "book title": 1, "title 2": 1,
            "heading": 2, "heading 1": 2, "section": 2, "section title": 2,
            "heading 2": 3, "subheading": 3, "subheading 1": 3,
            "heading 3": 4, "subheading 2": 4, "heading 4": 5, "subheading 3": 5, "heading 5": 6, "heading 6": 6,
        ]

        // MARK: Text

        /// An attribute table of a storage: entries sorted by character index.
        private func table(_ storage: PagesProto, _ field: Int) -> [(Int, PagesProto)] {
            guard let t = storage.message(field) else { return [] }
            // An index too large for Int can't point into any text: such entries are dropped.
            return t.messages(1).compactMap { e in e.uint(1).flatMap { Int(exactly: $0) }.map { ($0, e) } }.sorted { $0.0 < $1.0 }
        }

        /// Index of the first entry at or after `index` (binary search).
        private static func lowerBound<T>(_ table: [(Int, T)], _ index: Int) -> Int {
            var lo = 0, hi = table.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if table[mid].0 < index { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        /// The entry in force at `index`: the last one starting at or before it.
        private static func entry<T>(_ table: [(Int, T)], at index: Int) -> T? {
            let i = lowerBound(table, index + 1)
            return i > 0 ? table[i - 1].1 : nil
        }

        /// Character indexes of the entries that start inside `range`.
        private static func starts<T>(_ table: [(Int, T)], in range: Range<Int>) -> [Int] {
            var out: [Int] = []
            var i = lowerBound(table, range.lowerBound)
            while i < table.count, table[i].0 < range.upperBound { out.append(table[i].0); i += 1 }
            return out
        }

        private struct StorageTables {
            var paraStyles: [(Int, UInt64)] = []
            var listStyles: [(Int, PagesProto)] = []
            var levels: [(Int, PagesProto)] = []
            var charStyles: [(Int, PagesProto)] = []
            var attachments: [(Int, UInt64)] = []
            var smartFields: [(Int, PagesProto)] = []
        }

        /// Appends one text storage's paragraphs (and anything attached inside them) to the document.
        mutating func storageBlocks(_ id: UInt64) {
            guard let o = objects[id], isStorage(o), !emitted.contains(id) else { return }
            guard (o.message.uint(1) ?? 3) != 7 else { return }   // table of contents: page numbers only
            guard nesting < Self.maxNesting else { tooDeep = true; return }
            emitted.insert(id)
            storageDepth += 1
            nesting += 1
            defer { storageDepth -= 1; nesting -= 1 }
            let m = o.message
            let u = Array(text(of: o).utf16)
            var t = StorageTables()
            // Paragraph style entries without a style keep the previous paragraph's style.
            t.paraStyles = table(m, 5).compactMap { idx, e in e.ref(2).map { (idx, $0) } }
            t.listStyles = table(m, 7)
            t.levels = table(m, 6)
            t.charStyles = table(m, 8)
            t.attachments = table(m, 9).compactMap { idx, e in e.ref(2).map { (idx, $0) } }
            t.smartFields = table(m, 11)
            // Languages, weighted by how much text each covers.
            totalText += u.count
            let langs = table(m, 19)
            for (k, (idx, e)) in langs.enumerated() {
                guard let lang = e.string(2), !lang.isEmpty else { continue }
                let start = min(idx, u.count)
                let end = min(max(start, k + 1 < langs.count ? langs[k + 1].0 : u.count), u.count)
                languages[lang, default: 0] += end - start
            }

            var start = 0
            for i in 0...u.count {
                let c: UInt16 = i < u.count ? u[i] : 0x0A
                // Paragraph ends: newline, paragraph separator, section break (4), page break (5), column breaks.
                guard c == 0x0A || c == 0x2029 || c == 0x04 || c == 0x05 || c == 0x0C || c == 0x0E else { continue }
                if i > start { paragraph(u, start..<i, t) }
                if i < u.count, c == 0x04 || c == 0x05 { doc.blocks.append(.pageBreak) }
                start = i + 1
            }
        }

        private mutating func paragraph(_ u: [UInt16], _ range: Range<Int>, _ t: StorageTables) {
            let ps = Self.entry(t.paraStyles, at: range.lowerBound).map { style($0) } ?? ParaStyle()
            let level = Int(min(Self.entry(t.levels, at: range.lowerBound)?.uint(2) ?? 0, UInt64(EbooksAndPages.maxListLevel)))
            var listKind: UInt64 = 0
            if let lsID = Self.entry(t.listStyles, at: range.lowerBound)?.ref(2), let ls = objects[lsID] {
                let kinds = ls.message.uints(11)
                if !kinds.isEmpty { listKind = kinds[min(level, kinds.count - 1)] }
            }

            // Runs, cut wherever the character style or a hyperlink changes, and around attachments.
            var cuts = Set([range.lowerBound, range.upperBound])
            Self.starts(t.charStyles, in: range).forEach { cuts.insert($0) }
            Self.starts(t.smartFields, in: range).forEach { cuts.insert($0) }
            let anchored = Self.starts(t.attachments, in: range)
            anchored.forEach { cuts.insert($0); cuts.insert(min($0 + 1, range.upperBound)) }
            let bounds = cuts.sorted()
            var runs: [Run] = []

            for k in 0..<(bounds.count - 1) {
                let seg = bounds[k]..<bounds[k + 1]
                if seg.count == 1, u[seg.lowerBound] == 0xFFFC, let target = Self.entry(t.attachments, at: seg.lowerBound),
                   anchored.contains(seg.lowerBound) {
                    // Something anchored here (a picture, a text box, a group) goes in as its own block(s),
                    // after the text before it.
                    let before = doc.blocks.count
                    drawableBlocks(target)
                    if doc.blocks.count > before {
                        let added = Array(doc.blocks[before...])
                        doc.blocks.removeSubrange(before...)
                        emit(runs, ps, listKind: listKind, level: level)
                        runs = []
                        doc.blocks += added
                    }
                    continue
                }
                var run = Run(text: "")
                let cs = Self.entry(t.charStyles, at: seg.lowerBound)?.ref(2).map { style($0) }
                run.bold = cs?.bold ?? ps.bold ?? false
                run.italic = cs?.italic ?? ps.italic ?? false
                run.font = cs?.font ?? ps.font
                run.size = cs?.size ?? ps.size
                run.color = cs?.color ?? ps.color
                if let fieldID = Self.entry(t.smartFields, at: seg.lowerBound)?.ref(2), let f = objects[fieldID], f.type == 2032,
                   let url = f.message.string(2), url.contains(":") {
                    run.link = url
                }
                var units: [UInt16] = []
                units.reserveCapacity(seg.count)
                for idx in seg {
                    let ch = u[idx]
                    switch ch {
                    case 0x2028, 0x0B: units.append(0x0A)      // line break inside the paragraph
                    case 0x09: units.append(0x09)
                    case 0xFFFC, 0xFFFD: continue            // attachment anchors with nothing to show
                    default: if ch >= 0x20 { units.append(ch) }
                    }
                }
                run.text = String(decoding: units, as: UTF16.self)
                runs.append(run)
            }
            emit(runs, ps, listKind: listKind, level: level)
        }

        private mutating func emit(_ runs: [Run], _ ps: ParaStyle, listKind: UInt64, level: Int) {
            let r = EbooksAndPages.trimmed(runs)
            guard !r.isEmpty else { return }
            let lname = ps.name.lowercased()
            var headingLevel = Self.headingNames[lname]
            if headingLevel == nil, lname.hasPrefix("heading "), let n = Int(lname.dropFirst(8)) { headingLevel = min(6, n + 1) }
            let plainText = EbooksAndPages.plain(r)
            if headingLevel == nil, ps.bold == true, let size = ps.size, size >= bodySize * 1.3, plainText.count < 100,
               !lname.contains("body") {
                headingLevel = size >= bodySize * 1.8 ? 1 : 2
            }
            if headingLevel != nil, storageDepth > 1 {
                // A heading style inside an anchored text box (a cover, a sidebar): keep it as bold text.
                doc.blocks.append(.paragraph(runs: r.map { var x = $0; x.bold = true; return x }, align: ps.align ?? .natural, role: .body))
            } else if let h = headingLevel, plainText.count < 300 {
                doc.blocks.append(.heading(level: h, runs: r.map { var x = $0; x.bold = false; x.size = nil; return x }))
            } else if listKind != 0 {
                doc.blocks.append(.item(runs: r, ordered: listKind == 3, level: level))
            } else {
                let role: EbooksAndPages.Role = lname.contains("subtitle") ? .subtitle
                    : lname.contains("caption") ? .caption : lname.contains("quote") ? .quote : .body
                doc.blocks.append(.paragraph(runs: r, align: ps.align ?? .natural, role: role))
            }
        }

        // MARK: Drawables

        /// Blocks for an attached or floating object: images, text boxes (shapes with text) and groups.
        mutating func drawableBlocks(_ id: UInt64) {
            guard let o = objects[id], !emitted.contains(id) else { return }
            guard nesting < Self.maxNesting else { tooDeep = true; return }
            emitted.insert(id)
            nesting += 1
            defer { nesting -= 1 }
            let m = o.message
            switch o.type {
            case 2003, 2004, 2007, 2009, 2241:
                // Attachment wrappers: the drawable is field 1, or field 1 of their base message.
                if let target = m.ref(1), objects[target] != nil { drawableBlocks(target) }
                else if let target = m.message(1)?.ref(1) { drawableBlocks(target) }
            case 3005, 3006:
                imageBlock(m)
            case 2011:
                if let storage = m.ref(4) ?? m.ref(2) { storageBlocks(storage) }
            case 3008:
                for child in sortedByPosition(m.refs(2)) { drawableBlocks(child) }
            default:
                break
            }
        }

        private mutating func imageBlock(_ m: PagesProto) {
            // data (11), then the original (15) and the thumbnail (12) when the full image isn't stored.
            for field in [11, 15, 12, 13] {
                guard let dataID = m.ref(field), let path = dataFiles[dataID], let data = try? package.data(path),
                      let pic = doc.addPicture(data, ext: (path as NSString).pathExtension) else { continue }
                let alt = m.message(1)?.string(8) ?? ""
                let width = EbooksAndPages.usableWidth(m.message(4)?.float(1))
                doc.blocks.append(.image(id: pic, alt: alt, width: width.flatMap { $0 <= 450 ? $0 : nil }))
                return
            }
        }

        /// Drawables in reading order: top to bottom, then left to right.
        private func sortedByPosition(_ ids: [UInt64]) -> [UInt64] {
            func position(_ id: UInt64) -> (Double, Double) {
                guard var cur = objects[id]?.message else { return (0, 0) }
                for _ in 0..<5 {
                    guard let next = cur.message(1) else { break }
                    if let x = next.float(1), let y = next.float(2) { return x.isFinite && y.isFinite ? (y, x) : (0, 0) }
                    cur = next
                }
                return (0, 0)
            }
            return ids.enumerated().sorted { a, b in
                let pa = position(a.element), pb = position(b.element)
                if abs(pa.0 - pb.0) > 4 { return pa.0 < pb.0 }
                if abs(pa.1 - pb.1) > 4 { return pa.1 < pb.1 }
                return a.offset < b.offset
            }.map(\.element)
        }
    }

    /// A font size worth keeping: finite and between 1 and 1638 points (Word's largest).
    static func fontSize(_ v: Double?) -> Double? {
        guard let v, v.isFinite, v >= 1, v <= 1638 else { return nil }
        return v
    }

    // MARK: Pages '09 (XML)

    private static func legacyXML(_ package: EbooksAndPages.Package) throws -> Data? {
        if let xml = try? package.data("index.xml") { return xml }
        if let gz = try? package.data("index.xml.gz") { return try gunzip(gz) }
        return nil
    }

    /// gzip → raw DEFLATE body → bytes.
    static func gunzip(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { throw ConversionError.unsupported("Damaged compressed index.") }
        let flags = b[3]
        var p = 10
        if flags & 4 != 0 { guard p + 2 <= b.count else { throw ZipError.corrupt("gzip") }; p += 2 + (Int(b[p]) | Int(b[p + 1]) << 8) }
        if flags & 8 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }
        if flags & 16 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }
        if flags & 2 != 0 { p += 2 }
        guard p < b.count - 8 else { throw ZipError.corrupt("gzip") }
        let body = Data(b[p..<(b.count - 8)]) as NSData
        return try body.decompressed(using: .zlib) as Data
    }

    /// Pages '09: paragraphs (`sf:p`) of the body text storage, with paragraph style names for headings.
    /// The index is parsed from a decoded string with its DOCTYPE removed and entity declarations defused,
    /// so a hostile internal subset can't expand into gigabytes ("billion laughs").
    private static func legacyDocument(_ xml: Data, name: String) throws -> Doc {
        let text = EbooksAndPages.numericEntities(EbooksAndPages.safeMarkupString(EbooksAndPages.decodeText(xml)))
        guard let tree = try? XMLDocument(xmlString: text, options: [.nodeLoadExternalEntitiesNever]) else {
            throw ConversionError.unsupported("\(name) is damaged (its index can’t be read).")
        }
        EbooksAndPages.flattenDeepNesting(tree)
        var styleNames: [String: String] = [:]
        var parents: [String: String] = [:]
        for e in EbooksAndPages.elements(tree, named: "paragraphstyle") + EbooksAndPages.elements(tree, named: "paragraph-style") {
            guard let ident = EbooksAndPages.attribute(e, "ident") else { continue }
            if let n = EbooksAndPages.attribute(e, "name") { styleNames[ident] = n }
            if let parent = EbooksAndPages.attribute(e, "parent-ident") { parents[ident] = parent }
        }
        func styleName(_ ident: String?) -> String {
            var cur = ident
            var hops = 0
            while let c = cur, hops < 10 {
                if let n = styleNames[c] { return n }
                cur = parents[c]
                hops += 1
            }
            return ident ?? ""
        }
        let storages = EbooksAndPages.elements(tree, named: "text-storage")
        let body = storages.first { EbooksAndPages.attribute($0, "kind") == "body" } ?? storages.first
        guard let body else { throw ConversionError.unsupported("\(name) has no text YummyOrange can read.") }
        var doc = Doc()
        for p in EbooksAndPages.elements(body, named: "p") {
            var runs: [Run] = []
            func walk(_ n: XMLNode, link: String?, depth: Int = 0) {
                guard depth < EbooksAndPages.maxMarkupDepth else {
                    runs.append(Run(text: EbooksAndPages.textContent(n), link: link))
                    return
                }
                switch n.kind {
                case .text: runs.append(Run(text: n.stringValue ?? "", link: link))
                case .element:
                    guard let e = n as? XMLElement else { return }
                    switch EbooksAndPages.localName(e) {
                    case "br", "lnbr": runs.append(Run(text: "\n"))
                    case "tab": runs.append(Run(text: "\t"))
                    case "pgbr", "sectbr", "contbr": break
                    case "link": e.children?.forEach { walk($0, link: EbooksAndPages.attribute(e, "href"), depth: depth + 1) }
                    case "footnote", "annotation", "attachment-ref": break
                    default: e.children?.forEach { walk($0, link: link, depth: depth + 1) }
                    }
                default: break
                }
            }
            p.children?.forEach { walk($0, link: nil) }
            let r = EbooksAndPages.trimmed(runs)
            let breaks = EbooksAndPages.elements(p, named: "pgbr").count + EbooksAndPages.elements(p, named: "sectbr").count
            if !r.isEmpty {
                let style = styleName(EbooksAndPages.attribute(p, "style")).lowercased()
                if let level = IWAReaderNames.heading(style) {
                    doc.blocks.append(.heading(level: level, runs: r))
                } else {
                    doc.blocks.append(.paragraph(runs: r, align: .natural,
                                                 role: style.contains("subtitle") ? .subtitle : style.contains("caption") ? .caption : .body))
                }
            }
            if breaks > 0 { doc.blocks.append(.pageBreak) }
        }
        while let last = doc.blocks.last, case .pageBreak = last { doc.blocks.removeLast() }
        guard doc.hasText else { throw ConversionError.unsupported("\(name) has no text YummyOrange can read.") }
        return doc
    }

    private enum IWAReaderNames {
        static func heading(_ name: String) -> Int? {
            let map: [String: Int] = ["title": 1, "chapter": 1, "heading": 2, "heading 1": 2, "heading 2": 3,
                                      "heading 3": 4, "subheading": 3, "heading 4": 5]
            return map[name]
        }
    }
}
