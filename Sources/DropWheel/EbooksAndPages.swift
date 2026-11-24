import AppKit
import PDFKit

/// EPUB (read, write, → PDF) and Apple Pages documents (read-only).
///
/// Convert wheel:
/// - EPUB → PDF, DOCX, TXT, MD, HTML
/// - Pages → PDF, DOCX, TXT, MD, RTF, HTML, EPUB
/// - Text documents and PDFs → EPUB
///
/// Everything goes through one document model (EbooksAndPagesModel.swift), except EPUB → PDF and
/// EPUB → HTML, which keep the book's own markup and styles.
///
/// Options (`--opt key=value`; every one has a default):
/// - pdf: `paper` a4 | letter | a5 (default from the region), `margin` in points (54),
///   `preview` auto | no (Pages: use a PDF the document carries), `floating` auto | yes | no (Pages: text
///   boxes placed on pages; auto adds them when the body is empty)
/// - md: `images` false | true (true writes the pictures to a folder beside the file)
/// - epub: `title`, `author`, `language` (default from the source), `chapters` auto | page and
///   `ocr` true | false (PDF sources)
/// Self-tests: `snappy`, `pages-synthetic`, `epub-roundtrip`, `epub-pdf-background`, `ebooks-hardening`
/// (hostile inputs, EbooksAndPagesHardening.swift), `ebooks` (all).
enum EbooksAndPages: FeatureModule {
    static var commands: [WheelCommand] {
        [
            convert("pdf", "PDF", sources: readable, run: toPDF),
            convert("docx", "DOCX", sources: readable) { url, options, progress in
                try rich(url, options, progress, ext: "docx")
            },
            convert("txt", "TXT", sources: readable) { url, options, progress in
                let doc = try load(url, options, progress)
                guard doc.hasText else { throw ConversionError.unsupported("There’s no text in \(url.lastPathComponent).") }
                let out = outputURL(for: url, ext: "txt")
                try plainText(doc).write(to: out, atomically: true, encoding: .utf8)
                return [out]
            },
            convert("md", "Markdown", sources: readable, run: toMarkdown),
            convert("html", "HTML", sources: readable, run: toHTML),
            convert("rtf", "RTF", sources: Ext.pages) { url, options, progress in
                try rich(url, options, progress, ext: "rtf")
            },
            convert("epub", "EPUB", sources: Ext.textDocuments.union(Ext.pages).union(["pdf"]), run: toEPUB),
        ]
    }

    /// Formats this module reads into its document model.
    static let readable = Ext.ebooks.union(Ext.pages)

    private static func convert(_ id: String, _ title: String, sources: Set<String>,
                                run: @escaping (URL, ToolOptions, @escaping (Double) -> Void) throws -> [URL]) -> WheelCommand {
        WheelCommand(wheel: .convert, id: id, title: title, applies: { Ext.all($0, in: sources) }, run: { files, options, progress in
            var outputs: [URL] = []
            for (i, file) in files.enumerated() {
                outputs += try run(file, options) { progress((Double(i) + $0) / Double(files.count)) }
            }
            return outputs
        })
    }

    // MARK: Loading

    /// Any readable source as a document: EPUB, Pages, a text document or a PDF.
    static func load(_ url: URL, _ options: ToolOptions, _ progress: @escaping (Double) -> Void) throws -> Doc {
        let ext = Ext.of(url)
        var doc: Doc
        if Ext.ebooks.contains(ext) { doc = try EPUBBook(url: url).document(progress: progress) }
        else if Ext.pages.contains(ext) { doc = try PagesDocument.read(url, floating: options.string("floating", "auto")) }
        else if ext == "pdf" { doc = try pdfDocument(url, options: options, progress: progress) }
        else if Ext.textDocuments.contains(ext) { doc = try readTextDocument(url) }
        else { throw ConversionError.unsupported("\(url.lastPathComponent) isn’t a book or a document YummyOrange can read.") }
        if (doc.language ?? "").isEmpty { doc.language = EPUBWriter.detectLanguage(doc) }
        return doc
    }

    static func page(_ options: ToolOptions) -> EbooksAndPagesRenderer.Page {
        var page = EbooksAndPagesRenderer.Page()
        switch options.string("paper", "").lowercased() {
        case "a4": page.size = CGSize(width: 595.28, height: 841.89)
        case "letter": page.size = CGSize(width: 612, height: 792)
        case "a5": page.size = CGSize(width: 419.53, height: 595.28)
        default: break
        }
        page.margin = CGFloat(max(0, min(144, options.double("margin", 54))))
        return page
    }

    // MARK: Conversions

    private static func toPDF(_ url: URL, _ options: ToolOptions, _ progress: @escaping (Double) -> Void) throws -> [URL] {
        let out = outputURL(for: url, ext: "pdf")
        let pdf: PDFDocument
        if Ext.ebooks.contains(Ext.of(url)) {
            pdf = try EPUBBook(url: url).renderPDF(page: page(options), progress: progress)
        } else {
            // Pages: a PDF the document carries (Pages '09 "include preview") is the real layout; use it.
            let stored = PagesDocument.storedPreview(url)
            if options.string("preview", "auto") != "no", let stored, stored.isPDF, let doc = PDFDocument(data: stored.data),
               doc.pageCount > 0 {
                try stored.data.write(to: out, options: .atomic)
                return [out]
            }
            do {
                pdf = try renderPDF(try PagesDocument.read(url, floating: options.string("floating", "auto")),
                                    page: page(options), progress: progress)
            } catch let error as ConversionError {
                // No text to lay out: fall back to the first-page preview image if there is one.
                guard let stored, !stored.isPDF, let image = NSImage(data: stored.data),
                      let p = PDFPage(image: image) else { throw error }
                let single = PDFDocument()
                single.insert(p, at: 0)
                pdf = single
            }
        }
        guard pdf.pageCount > 0, pdf.write(to: out) else {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError.toolFailed("Couldn’t save \(out.lastPathComponent).")
        }
        return [out]
    }

    /// DOCX and RTF through DocumentIO, from the document model's rich text.
    private static func rich(_ url: URL, _ options: ToolOptions, _ progress: @escaping (Double) -> Void, ext: String) throws -> [URL] {
        let doc = try load(url, options, progress)
        let out = outputURL(for: url, ext: ext)
        try DocumentIO.write(attributedString(doc), to: out, ext: ext)
        return [out]
    }

    private static func toMarkdown(_ url: URL, _ options: ToolOptions, _ progress: @escaping (Double) -> Void) throws -> [URL] {
        let doc = try load(url, options, progress)
        guard doc.hasText || options.bool("images", false) else {
            throw ConversionError.unsupported("There’s no text in \(url.lastPathComponent).")
        }
        let out = outputURL(for: url, ext: "md")
        var outputs = [out]
        var links: [String: String] = [:]
        if options.bool("images", false), !doc.pictures.isEmpty {
            // Pictures go in a new folder beside the Markdown file, linked relatively. An existing folder
            // is never written into: "<name> images 2", "<name> images 3", ... are tried instead.
            let folder = try newImagesFolder(beside: out)
            let folderName = folder.lastPathComponent
            for (id, pic) in doc.pictures.sorted(by: { $0.key < $1.key }) {
                try pic.data.write(to: folder.appendingPathComponent("\(id).\(pic.ext)"), options: .withoutOverwriting)
                links[id] = "\(folderName)/\(id).\(pic.ext)"
            }
            outputs.append(folder)
        }
        try markdown(doc, imagePath: { links[$0] }).write(to: out, atomically: true, encoding: .utf8)
        return outputs
    }

    /// Creates "<name> images" next to `markdown` (or "<name> images 2", ... when that exists). Creating it
    /// without intermediate folders fails if something appeared there meanwhile, so it is always new.
    static func newImagesFolder(beside markdown: URL) throws -> URL {
        let dir = markdown.deletingLastPathComponent()
        let base = markdown.deletingPathExtension().lastPathComponent + " images"
        let fm = FileManager.default
        for n in 1...10_000 {
            let candidate = dir.appendingPathComponent(n == 1 ? base : "\(base) \(n)", isDirectory: true)
            if fm.fileExists(atPath: candidate.path) { continue }
            do {
                try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
                return candidate
            } catch where fm.fileExists(atPath: candidate.path) {
                continue   // created by someone else just now
            }
        }
        throw ConversionError.toolFailed("Couldn’t find a free folder name for the pictures of \(markdown.lastPathComponent).")
    }

    private static func toHTML(_ url: URL, _ options: ToolOptions, _ progress: @escaping (Double) -> Void) throws -> [URL] {
        let html: String
        if Ext.ebooks.contains(Ext.of(url)) {
            html = try EPUBBook(url: url).singleHTML(progress: progress)
        } else {
            html = standaloneHTML(try load(url, options, progress))
        }
        let out = outputURL(for: url, ext: "html")
        try html.write(to: out, atomically: true, encoding: .utf8)
        return [out]
    }

    private static func toEPUB(_ url: URL, _ options: ToolOptions, _ progress: @escaping (Double) -> Void) throws -> [URL] {
        var doc = try load(url, options, progress)
        guard doc.hasText || !doc.pictures.isEmpty else {
            throw ConversionError.unsupported("There’s no text in \(url.lastPathComponent) to put in a book.")
        }
        if let t = options["title"], !t.isEmpty { doc.title = t }
        if let a = options["author"], !a.isEmpty { doc.author = a }
        if let l = options["language"], !l.isEmpty { doc.language = l }
        let out = outputURL(for: url, ext: "epub")
        try EPUBWriter.write(doc, to: out, fallbackTitle: url.deletingPathExtension().lastPathComponent)
        return [out]
    }

    // MARK: Self-tests

    static func selfTest(_ name: String) -> String? {
        switch name {
        case "snappy": return report(name, snappyChecks())
        case "pages-synthetic": return report(name, syntheticPagesChecks())
        case "epub-roundtrip": return report(name, roundTripChecks())
        case "epub-pdf-background": return report(name, backgroundPDFChecks())
        case "ebooks-hardening": return report(name, hardeningChecks())
        case "ebooks":
            return report(name, snappyChecks() + syntheticPagesChecks() + roundTripChecks() + backgroundPDFChecks() + hardeningChecks())
        default: return nil
        }
    }

    private static func report(_ name: String, _ checks: [(String, Bool)]) -> String {
        let failed = checks.filter { !$0.1 }
        let lines = checks.map { ($0.1 ? "  ok   " : "  FAIL ") + $0.0 }.joined(separator: "\n")
        return (failed.isEmpty ? "PASS" : "FAIL") + " \(name): \(checks.count - failed.count)/\(checks.count)\n" + lines
    }

    private static func snappyChecks() -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        let text = Array("The quick brown fox jumps over the lazy dog. ".utf8)
        checks.append(("literal round trip", (try? Snappy.decompress(Snappy.compressLiterals(text))) == text))
        let big = (0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 7) }
        checks.append(("200 KB literal round trip", (try? Snappy.decompress(Snappy.compressLiterals(big))) == big))
        // "abc" + copy(offset 3, length 9) = "abcabcabcabc" (1-byte-offset copy: tag = (len-4)<<2 | 1).
        let copy1: [UInt8] = [12, 2 << 2, 0x61, 0x62, 0x63, UInt8((9 - 4) << 2 | 1), 3]
        checks.append(("overlapping 1-byte-offset copy", (try? Snappy.decompress(copy1)).map { String(decoding: $0, as: UTF8.self) } == "abcabcabcabc"))
        // 2-byte-offset copy: "xy" then copy offset 2 length 6.
        let copy2: [UInt8] = [8, 1 << 2, 0x78, 0x79, UInt8((6 - 1) << 2 | 2), 2, 0]
        checks.append(("2-byte-offset copy", (try? Snappy.decompress(copy2)).map { String(decoding: $0, as: UTF8.self) } == "xyxyxyxy"))
        checks.append(("rejects a copy before the start", (try? Snappy.decompress([4, UInt8(0 << 2 | 1), 9])) == nil))
        checks.append(("rejects a truncated literal", (try? Snappy.decompress([10, 9 << 2, 0x61])) == nil))
        checks.append(("rejects a wrong length", (try? Snappy.decompress([5, 0, 0x61])) == nil))
        checks.append(("rejects an empty block", (try? Snappy.decompress([])) == nil))
        let iwa = PagesIWA.wrap(Array("hello iwa".utf8))
        checks.append(("iwa chunk round trip", (try? PagesIWA.decompress(iwa)) == Array("hello iwa".utf8)))
        checks.append(("iwa rejects an unknown chunk type", (try? PagesIWA.decompress([7, 1, 0, 0, 0])) == nil))
        return checks
    }

    /// Builds a small Pages-like package in memory (IWA objects modelled on the real TSWP storage,
    /// paragraph/character/list styles, an image attachment and a document archive) and reads it back.
    private static func syntheticPagesChecks() -> [(String, Bool)] {
        let e = PagesIWA.encode
        func ref(_ id: Int) -> [UInt8] { e([(1, id)]) }
        func entry(_ index: Int, _ id: Int?) -> [UInt8] { e([(1, index)] + (id.map { [(2, ref($0) as Any)] } ?? [])) }
        func tableOf(_ entries: [[UInt8]]) -> [UInt8] { e(entries.map { (1, $0 as Any) }) }
        let text = "My Book\nIntro text with bold words.\nFirst item\nSecond item\n\u{FFFC}\u{04}Chapter Two\nCaf\u{E9} \u{1F600} line\u{2028}break."
        func idx(_ s: String) -> Int { (text as NSString).range(of: s).location }   // UTF-16 index, like TSWP
        let title = idx("My Book"), intro = idx("Intro"), bold = idx("bold words"), boldEnd = bold + 10
        let item1 = idx("First item"), anchor = idx("\u{FFFC}"), ch2 = idx("Chapter Two"), cafe = idx("Caf")
        let storage = e([
            (1, 0), (3, text),
            (5, tableOf([entry(title, 101), entry(intro, 102), entry(ch2, 101), entry(cafe, 102)])),
            (6, tableOf([e([(1, 0), (2, 0)])])),
            (7, tableOf([entry(0, nil), entry(item1, 201), entry(anchor, nil)])),
            (8, tableOf([entry(0, nil), entry(bold, 301), entry(boldEnd, nil)])),
            (9, tableOf([entry(anchor, 401)])),
        ])
        let styleTitle = e([(1, e([(1, "Title")])), (11, e([(1, true), (3, Float(28))]))])
        let styleBody = e([(1, e([(1, "Body")])), (11, e([(1, false), (3, Float(12))]))])
        let listBullet = e([(1, e([(1, "Bullet")])), (11, 2), (11, 2)])
        let charBold = e([(1, e([(1, "Strong")])), (11, e([(1, true)]))])
        let attachment = e([(1, ref(402))])
        let image = e([(1, e([(8, "A red square")])), (11, ref(7))])
        let document = e([(4, ref(100))])
        var stream: [UInt8] = []
        stream += PagesIWA.archive(id: 1, type: 10000, payload: document)
        stream += PagesIWA.archive(id: 100, type: 2001, payload: storage)
        stream += PagesIWA.archive(id: 101, type: 2022, payload: styleTitle)
        stream += PagesIWA.archive(id: 102, type: 2022, payload: styleBody)
        stream += PagesIWA.archive(id: 201, type: 2023, payload: listBullet)
        stream += PagesIWA.archive(id: 301, type: 2021, payload: charBold)
        stream += PagesIWA.archive(id: 401, type: 2003, payload: attachment)
        stream += PagesIWA.archive(id: 402, type: 3005, payload: image)
        let metadata = PagesIWA.archive(id: 2, type: 11006, payload: e([(4, e([(1, 7), (3, "red.png")]))]))

        var checks: [(String, Bool)] = []
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-pages-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                .representation(using: .png, properties: [:])!
            let w = ZipWriter()
            try w.add("Index/Document.iwa", data: Data(PagesIWA.wrap(stream)))
            try w.add("Index/Metadata.iwa", data: Data(PagesIWA.wrap(metadata)))
            try w.add("Data/red-7.png", data: png)
            let url = dir.appendingPathComponent("Synthetic.pages")
            try w.write(to: url)
            let doc = try PagesDocument.read(url)
            let blocks = doc.blocks
            func kind(_ b: Block) -> String {
                switch b {
                case .heading(let l, _): return "h\(l)"
                case .paragraph: return "p"
                case .item: return "li"
                case .image: return "img"
                case .pageBreak: return "br"
                default: return "?"
                }
            }
            let kinds = blocks.map(kind).joined(separator: " ")
            checks.append(("block structure h1 p li li img br h1 p (got: \(kinds))", kinds == "h1 p li li img br h1 p"))
            checks.append(("title from first heading", doc.title == "My Book"))
            if blocks.count > 1, case let .paragraph(runs, _, _) = blocks[1] {
                checks.append(("bold run from character style", runs.contains { $0.bold && $0.text == "bold words" }))
            }
            if blocks.count > 4, case let .image(id, alt, _) = blocks[4] {
                checks.append(("image resolved through Data/ with alt text", doc.pictures[id] != nil && alt == "A red square"))
            }
            if let last = blocks.last, case let .paragraph(runs, _, _) = last {
                let t = runs.map(\.text).joined()
                checks.append(("non-BMP text and line break kept", t == "Caf\u{E9} \u{1F600} line\nbreak."))
            }
            let md = markdown(doc)
            checks.append(("markdown has heading and bullets", md.contains("# My Book") && md.contains("- First item")))
            // Damaged input: a chunk header promising more data than there is.
            let broken = dir.appendingPathComponent("Broken.pages")
            let bw = ZipWriter()
            try bw.add("Index/Document.iwa", data: Data([0, 0xFF, 0xFF, 0x00, 1, 2, 3]))
            try bw.write(to: broken)
            checks.append(("damaged IWA gives an error, not a crash", (try? PagesDocument.read(broken)) == nil))
        } catch {
            checks.append(("synthetic Pages document reads: \(error.localizedDescription)", false))
        }
        return checks
    }

    /// EPUB → PDF the way the app runs it: the command on a background queue, WebKit on the main thread
    /// through MainThread while the main run loop keeps turning.
    private static func backgroundPDFChecks() -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-bg-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var doc = Doc(title: "Background", author: "Tester", language: "en")
            doc.blocks = [.heading(level: 1, runs: [Run(text: "First")]), .para([Run(text: "Alpha paragraph.")]),
                          .heading(level: 1, runs: [Run(text: "Second")]), .para([Run(text: "Beta paragraph.")])]
            let book = dir.appendingPathComponent("bg.epub")
            try EPUBWriter.write(doc, to: book, fallbackTitle: "bg")
            guard let command = commands.first(where: { $0.id == "pdf" }), let run = command.run else { return [("pdf command", false)] }
            var result: Result<[URL], Error>?
            var progressCalls = 0
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Result { try run([book], [:]) { _ in progressCalls += 1 } }
                DispatchQueue.main.async { result = r }
            }
            let deadline = Date().addingTimeInterval(120)
            while result == nil, Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
            switch result {
            case .success(let urls)?:
                let pdf = urls.first.flatMap { PDFDocument(url: $0) }
                checks.append(("PDF written from a background queue", pdf != nil))
                checks.append(("one page per chapter (got \(pdf?.pageCount ?? 0))", pdf?.pageCount == 2))
                let text = pdf?.string ?? ""
                checks.append(("text is real text", text.contains("Alpha paragraph.") && text.contains("Beta paragraph.")))
                checks.append(("bookmarks from the table of contents", pdf?.outlineRoot?.numberOfChildren == 2))
                checks.append(("progress reported", progressCalls > 0))
            case .failure(let error)?:
                checks.append(("background EPUB → PDF: \(error.localizedDescription)", false))
            case nil:
                checks.append(("background EPUB → PDF finished in time", false))
            }
        } catch {
            checks.append(("background test setup: \(error.localizedDescription)", false))
        }
        return checks
    }

    /// Writes a book with chapters, a list, a table and an image, reads it back and compares.
    private static func roundTripChecks() -> [(String, Bool)] {
        var doc = Doc(title: "Round & Trip <Test>", author: "A. Writer", language: "en")
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            .representation(using: .png, properties: [:])!
        let pic = doc.addPicture(png, ext: "png")!
        doc.blocks = [
            .heading(level: 1, runs: [Run(text: "One")]),
            .para([Run(text: "Hello "), Run(text: "bold", bold: true), Run(text: " & <escaped>.")]),
            .item(runs: [Run(text: "a")], ordered: false, level: 0),
            .item(runs: [Run(text: "b")], ordered: false, level: 1),
            .item(runs: [Run(text: "c")], ordered: true, level: 0),
            .heading(level: 1, runs: [Run(text: "Two")]),
            .image(id: pic, alt: "dot", width: nil),
            .table(rows: [[[Run(text: "x")], [Run(text: "y")]], [[Run(text: "1")], [Run(text: "2")]]], header: true),
        ]
        var checks: [(String, Bool)] = []
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-epub-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("rt.epub")
            try EPUBWriter.write(doc, to: url, fallbackTitle: "rt")
            let zip = try ZipReader(url: url)
            checks.append(("mimetype is the first entry, stored", zip.entries.first?.name == "mimetype" && zip.entries.first?.method == 0))
            for name in zip.names where name.hasSuffix(".xhtml") || name.hasSuffix(".opf") || name.hasSuffix(".ncx") {
                checks.append(("\(name) is well-formed XML", isWellFormedXML(try zip.read(name))))
            }
            let book = try EPUBBook(url: url)
            checks.append(("title and author", book.title == "Round & Trip <Test>" && book.authors == ["A. Writer"]))
            checks.append(("two chapters in spine and toc", book.spine.count == 2 && book.toc.map(\.title) == ["One", "Two"]))
            let back = try book.document()
            let text = plainText(back)
            checks.append(("text survives", text.contains("Hello bold & <escaped>.") && text.contains("• a")))
            checks.append(("image survives", back.pictures.count == 1))
            checks.append(("table survives", back.blocks.contains { if case .table(let rows, true) = $0 { return rows.count == 2 }; return false }))
            checks.append(("nested list level survives", back.blocks.contains { if case .item(_, false, 1) = $0 { return true }; return false }))
        } catch {
            checks.append(("round trip: \(error.localizedDescription)", false))
        }
        return checks
    }
}
