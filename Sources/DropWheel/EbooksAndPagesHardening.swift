import AppKit
import PDFKit

// Self-test `ebooks-hardening`: hostile and damaged inputs that once crashed, hung, leaked files or
// wrote into the user's folders. Each check builds its input in a temporary folder.

private typealias Block = EbooksAndPages.Block

extension EbooksAndPages {
    static func hardeningChecks() -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-hardening-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            checks += pagesHostileChecks(dir)
            checks += markupHostileChecks(dir)
            checks += exportChecks(dir)
            checks += rotatedPDFChecks()
            checks += printConfinementChecks(dir)
        } catch {
            checks.append(("hardening setup: \(error.localizedDescription)", false))
        }
        return checks
    }

    /// Runs `body` on a thread with the 512 KB stack GCD gives the app's conversion jobs.
    private static func onSmallStack(_ body: @escaping () -> Void) {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { body(); done.signal() }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
    }

    // MARK: Pages

    private static func pagesFile(_ dir: URL, _ name: String, document: [UInt8], metadata: [UInt8]? = nil,
                                  rawDocument: Data? = nil, files: [String: Data] = [:]) throws -> URL {
        let w = ZipWriter()
        try w.add("Index/Document.iwa", data: rawDocument ?? Data(PagesIWA.wrap(document)))
        if let metadata { try w.add("Index/Metadata.iwa", data: Data(PagesIWA.wrap(metadata))) }
        for (path, data) in files { try w.add(path, data: data) }
        let url = dir.appendingPathComponent(name)
        try w.write(to: url)
        return url
    }

    private static func pagesHostileChecks(_ dir: URL) -> [(String, Bool)] {
        let e = PagesIWA.encode
        func ref(_ id: Int) -> [UInt8] { e([(1, id)]) }
        func entry(_ index: Any, _ id: Int) -> [UInt8] { e([(1, index), (2, ref(id))]) }
        func table(_ entries: [[UInt8]]) -> [UInt8] { e(entries.map { (1, $0 as Any) }) }
        func storage(_ text: String, _ extra: [(Int, Any)] = []) -> [UInt8] { e([(1, 0), (3, text)] + extra) }
        let documentArchive = PagesIWA.archive(id: 1, type: 10000, payload: e([(4, ref(100))]))
        let bodyStyle = PagesIWA.archive(id: 101, type: 2022, payload: e([(1, e([(1, "Body")])), (11, e([(3, Float(12))]))]))
        var checks: [(String, Bool)] = []
        do {
            // 1. A message length of 2^64 - 1 (once "Not enough bits to represent the passed value").
            let info = e([(1, UInt64(100)), (2, e([(1, 2001), (3, UInt64.max)]))])
            let huge = documentArchive + PagesIWA.varintBytes(UInt64(info.count)) + info + storage("x")
            let a = try pagesFile(dir, "A.pages", document: huge)
            checks.append(("message length 2^64-1 is an error, not a trap", (try? PagesDocument.read(a)) == nil))

            // 2. A paragraph-style table index of 2^63.
            let b = try pagesFile(dir, "B.pages", document: documentArchive + bodyStyle + PagesIWA.archive(id: 100, type: 2001,
                payload: storage("Text B", [(5, table([entry(0, 101), entry(UInt64(1) << 63, 101)]))])))
            let docB = try? PagesDocument.read(b)
            checks.append(("table index 2^63 is skipped (text kept)", docB.map { plainText($0).contains("Text B") } == true))

            // 3. A list level of 2^63: clamped, and every writer copes.
            let listStyle = PagesIWA.archive(id: 201, type: 2023, payload: e([(1, e([(1, "Bullet")])), (11, 2)]))
            let c = try pagesFile(dir, "C.pages", document: documentArchive + listStyle + PagesIWA.archive(id: 100, type: 2001,
                payload: storage("Item C", [(6, table([e([(1, 0), (2, UInt64(1) << 63)])])), (7, table([entry(0, 201)]))])))
            if let docC = try? PagesDocument.read(c) {
                let level = docC.blocks.compactMap { b -> Int? in if case let .item(_, _, l) = b { return l }; return nil }.first
                checks.append(("list level 2^63 clamped (got \(level.map(String.init) ?? "none"))", level == maxListLevel))
                checks.append(("clamped list in TXT, Markdown, rich text", plainText(docC).contains("Item C")
                    && markdown(docC).contains("Item C") && attributedString(docC).string.contains("Item C")))
            } else {
                checks.append(("list level 2^63 reads", false))
            }

            // 4. Text colours with NaN and -1e30 components.
            let nan = PagesIWA.archive(id: 301, type: 2021, payload: e([(1, e([(1, "N")])), (11, e([(7, e([(3, Float.nan), (4, Float(0)), (5, Float(0))]))]))]))
            let neg = PagesIWA.archive(id: 302, type: 2021, payload: e([(1, e([(1, "M")])), (11, e([(7, e([(3, Float(-1e30)), (4, Float(0.5)), (5, Float(0))]))]))]))
            let d = try pagesFile(dir, "D.pages", document: documentArchive + nan + neg + PagesIWA.archive(id: 100, type: 2001,
                payload: storage("Colour one two", [(8, table([entry(0, 301), entry(7, 302)]))])))
            if let docD = try? PagesDocument.read(d) {
                let colours = docD.blocks.flatMap(\.runs).compactMap(\.color)
                checks.append(("NaN colour ignored, negative colour clamped (got \(colours))", colours == ["#008000"]))
                checks.append(("colour document writes rich text", attributedString(docD).string.contains("Colour")))
            } else {
                checks.append(("bad colours read", false))
            }

            // 5. Picture frame widths of -1e30 and NaN.
            let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                .representation(using: .png, properties: [:])!
            var pics = PagesIWA.archive(id: 401, type: 2003, payload: e([(1, ref(402))]))
                + PagesIWA.archive(id: 402, type: 3005, payload: e([(4, e([(1, Float(-1e30))])), (11, ref(7))]))
                + PagesIWA.archive(id: 403, type: 2003, payload: e([(1, ref(404))]))
                + PagesIWA.archive(id: 404, type: 3005, payload: e([(4, e([(1, Float.nan)])), (11, ref(7))]))
            pics += PagesIWA.archive(id: 100, type: 2001,
                                     payload: storage("Pictures\u{FFFC}\u{FFFC}", [(9, table([entry(8, 401), entry(9, 403)]))]))
            let f = try pagesFile(dir, "F.pages", document: documentArchive + pics,
                                  metadata: PagesIWA.archive(id: 2, type: 11006, payload: e([(4, e([(1, 7), (3, "red.png")]))])),
                                  files: ["Data/red-7.png": png])
            if let docF = try? PagesDocument.read(f) {
                let widths = docF.blocks.compactMap { b -> Double?? in if case let .image(_, _, w) = b { return .some(w) }; return nil }
                checks.append(("bad picture widths dropped (\(widths.count) pictures)", widths.count == 2 && widths.allSatisfy { $0 == nil }))
                checks.append(("pictures with bad widths write HTML", standaloneHTML(docF).contains("<img")))
            } else {
                checks.append(("bad picture widths read", false))
            }
            checks.append(("xhtmlBody ignores an infinite or NaN width",
                           xhtmlBody([.image(id: "a", alt: "", width: .infinity), .image(id: "a", alt: "", width: .nan),
                                      .image(id: "a", alt: "", width: 1e300)], imageSrc: { _ in "a.png" }).contains("width") == false))

            // 6. Groups that each list the next one 40 times: 40^12 walks before, each object once now.
            var dag = documentArchive + PagesIWA.archive(id: 100, type: 2001,
                                                         payload: storage("Shared\u{FFFC}", [(9, table([entry(6, 600)]))]))
            dag += PagesIWA.archive(id: 600, type: 2003, payload: e([(1, ref(500))]))
            for k in 0..<12 {
                let next = k < 11 ? Array(repeating: (2, ref(501 + k) as Any), count: 40) : []
                dag += PagesIWA.archive(id: UInt64(500 + k), type: 3008, payload: e(next))
            }
            let g = try pagesFile(dir, "G.pages", document: dag)
            let start = Date()
            let docG = try? PagesDocument.read(g)
            let elapsed = Date().timeIntervalSince(start)
            checks.append((String(format: "shared groups walked once (%.2f s)", elapsed), docG != nil && elapsed < 2))

            // 7–8. Text boxes anchored inside text boxes: a sane depth reads, a hostile one is refused, and
            // neither overflows a 512 KB stack.
            func chain(_ n: Int) -> [UInt8] {
                var out = documentArchive
                for k in 0..<n {
                    let anchor: [(Int, Any)] = k < n - 1 ? [(9, table([entry(6 + String(k).count, 3000 + k)]))] : []
                    out += PagesIWA.archive(id: UInt64(k == 0 ? 100 : 1000 + k), type: 2001, payload: storage("Level \(k)\u{FFFC}", anchor))
                    if k < n - 1 { out += PagesIWA.archive(id: UInt64(3000 + k), type: 2011, payload: e([(4, ref(1000 + k + 1))])) }
                }
                return out
            }
            let shallow = try pagesFile(dir, "H10.pages", document: chain(10))
            let deep = try pagesFile(dir, "H300.pages", document: chain(300))
            var shallowText = "", deepError = ""
            onSmallStack {
                shallowText = (try? PagesDocument.read(shallow)).map(plainText) ?? ""
                do { _ = try PagesDocument.read(deep) } catch { deepError = error.localizedDescription }
            }
            checks.append(("10 nested text boxes all read", (0..<10).allSatisfy { shallowText.contains("Level \($0)") }))
            checks.append(("300 nested text boxes refused by name (\(deepError))", deepError.contains("H300.pages") && deepError.contains("nested")))

            // 9. A damaged Document.iwa next to a readable Metadata.iwa is "damaged", not "no text".
            let t = try pagesFile(dir, "T.pages", document: [], metadata: PagesIWA.archive(id: 2, type: 11006, payload: e([(4, e([(1, 7)]))])),
                                  rawDocument: Data([0, 0xFF, 0xFF, 0x00, 1, 2, 3]))
            var message = ""
            do { _ = try PagesDocument.read(t) } catch { message = error.localizedDescription }
            checks.append(("damaged Document.iwa reported as damaged (\(message))", message.contains("is damaged")))

            // 10. Pages '09 index.xml with nested entity declarations ("billion laughs").
            var decls = "<!ENTITY lol \"lol\">"
            for k in 2...9 { decls += "<!ENTITY lol\(k) \"" + String(repeating: "&lol\(k == 2 ? "" : String(k - 1));", count: 10) + "\">" }
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE sl:document [\(decls)]>
            <sl:document xmlns:sl="http://developer.apple.com/namespaces/sl" xmlns:sf="http://developer.apple.com/namespaces/sf">\
            <sf:text-storage sf:kind="body"><sf:p>Start &lol9; end</sf:p></sf:text-storage></sl:document>
            """
            let lw = ZipWriter()
            try lw.add("index.xml", data: Data(xml.utf8))
            let legacy = dir.appendingPathComponent("laughs.pages")
            try lw.write(to: legacy)
            let lstart = Date()
            let legacyText = (try? PagesDocument.read(legacy)).map(plainText) ?? ""
            checks.append((String(format: "Pages '09 entity declarations not expanded (%d characters, %.2f s)", legacyText.count,
                                  Date().timeIntervalSince(lstart)), legacyText.contains("Start") && legacyText.count < 100))
        } catch {
            checks.append(("hostile Pages setup: \(error.localizedDescription)", false))
        }
        return checks
    }

    // MARK: Markup

    private static func epubFile(_ dir: URL, _ name: String, chapters: [String], files: [String: Data] = [:]) throws -> URL {
        let w = ZipWriter()
        try w.add("mimetype", data: Data("application/epub+zip".utf8), compress: false)
        try w.add("META-INF/container.xml", data: Data("""
        <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.utf8))
        let items = chapters.indices.map { "<item id=\"c\($0)\" href=\"ch\($0).xhtml\" media-type=\"application/xhtml+xml\"/>" }.joined()
        let refs = chapters.indices.map { "<itemref idref=\"c\($0)\"/>" }.joined()
        try w.add("OEBPS/content.opf", data: Data("""
        <?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">\
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">x</dc:identifier><dc:title>T</dc:title>\
        <dc:language>en</dc:language></metadata><manifest>\(items)</manifest><spine>\(refs)</spine></package>
        """.utf8))
        for (i, c) in chapters.enumerated() { try w.add("OEBPS/ch\(i).xhtml", data: Data(c.utf8)) }
        for (path, data) in files { try w.add(path, data: data) }
        let url = dir.appendingPathComponent(name)
        try w.write(to: url)
        return url
    }

    private static func xhtml(_ body: String, head: String = "", prolog: String = "") -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\(prolog)<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>t</title>\(head)</head><body>\(body)</body></html>"
    }

    private static func markupHostileChecks(_ dir: URL) -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        // Entity declarations are never expanded, wherever the DOCTYPE sits.
        var decls = "<!ENTITY lol \"lol\">"
        for k in 2...9 { decls += "<!ENTITY lol\(k) \"" + String(repeating: "&lol\(k == 2 ? "" : String(k - 1));", count: 10) + "\">" }
        let padded = "<?xml version=\"1.0\"?>" + String(repeating: "<!-- pad -->", count: 600) + "<!DOCTYPE html [\(decls)]>"
            + "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>A &lol9; B</p></body></html>"
        let laughs = Data(padded.utf8)
        let text = parseMarkup(laughs).flatMap { $0.rootElement()?.stringValue } ?? ""
        checks.append(("billion laughs after 7 KB of comments not expanded (\(text.count) characters)", text.contains("A") && text.count < 100))
        checks.append(("markup declaring entities isn't printed as XML", !isWellFormedXML(laughs)))
        checks.append(("entity in a quoted DOCTYPE value doesn't end it early",
                       stripDoctype("<!DOCTYPE x [<!ENTITY a \"]>\">]><r>ok</r>") == "<r>ok</r>"))

        // The XML declaration's encoding doesn't decode the already decoded text a second time.
        var latin = Data("<?xml version=\"1.0\" encoding=\"iso-8859-1\"?><html><body><p>caf".utf8)
        latin += Data([0xE9, 0x20, 0x93, 0x71, 0x94])
        latin += Data("</p></body></html>".utf8)
        let decoded = parseMarkup(latin).flatMap { $0.rootElement()?.stringValue } ?? ""
        checks.append(("iso-8859-1 declaration read once (got \(decoded))", decoded == "café “q”"))

        // Image widths that are not numbers a layout can use.
        if let doc = parseMarkup(Data("<html><body><img src=\"a.png\" width=\"99999999999999999999\"/><img src=\"a.png\" width=\"Infinity\"/><img src=\"a.png\" width=\"120\"/></body></html>".utf8)) {
            var importer = HTMLImporter(image: { _ in "img001" })
            let widths = importer.importBody(of: doc).compactMap { b -> Double?? in if case let .image(_, _, w) = b { return .some(w) }; return nil }
            checks.append(("huge and infinite HTML widths dropped, 120 kept (got \(widths))", widths == [nil, nil, 120]))
        }

        // 5000 nested spans on a 512 KB stack: flattened to text, every output still written.
        do {
            let deep = try epubFile(dir, "deep.epub", chapters: [xhtml("<div>start" + String(repeating: "<span>", count: 5000)
                + "deep text" + String(repeating: "</span>", count: 5000) + "end</div>")])
            var txt = "", html = ""
            onSmallStack {
                autoreleasepool {
                    if let book = try? EPUBBook(url: deep) {
                        txt = (try? book.document()).map(plainText) ?? ""
                        html = (try? book.singleHTML()) ?? ""
                    }
                }
            }
            checks.append(("5000 nested spans: text on a 512 KB stack", txt.contains("deep text") && txt.contains("end")))
            checks.append(("5000 nested spans: HTML on a 512 KB stack", html.contains("deep text")))
        } catch {
            checks.append(("deep EPUB setup: \(error.localizedDescription)", false))
        }

        // A folder book whose chapter is a link to a file elsewhere.
        do {
            let secret = dir.appendingPathComponent("secret.xhtml")
            try xhtml("<p>SECRET-OUTSIDE</p>").write(to: secret, atomically: true, encoding: .utf8)
            let zipped = try epubFile(dir, "plain.epub", chapters: [xhtml("<p>Inside one</p>"), xhtml("<p>Inside two</p>")])
            let folder = dir.appendingPathComponent("folder.epub", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try ZipReader(url: zipped).extractAll(to: folder)
            let link = folder.appendingPathComponent("OEBPS/ch1.xhtml")
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
            let text = (try? EPUBBook(url: folder).document()).map(plainText) ?? ""
            checks.append(("folder book skips a symlinked chapter", text.contains("Inside one") && !text.contains("SECRET-OUTSIDE")))
        } catch {
            checks.append(("folder book setup: \(error.localizedDescription)", false))
        }

        // "an EPUB book", not "a EPUB book".
        do {
            let junk = dir.appendingPathComponent("junk.epub")
            try Data("hello".utf8).write(to: junk)
            var message = ""
            do { _ = try EPUBBook(url: junk) } catch { message = error.localizedDescription }
            checks.append(("error says “an EPUB book”", message.contains("isn’t really an EPUB book")))
        } catch {
            checks.append(("junk setup: \(error.localizedDescription)", false))
        }
        return checks
    }

    // MARK: Exports

    private static func exportChecks(_ dir: URL) -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        do {
            // EPUB → HTML keeps nothing that runs, embeds, redirects or loads from the network.
            let hostile = xhtml("""
            <p>Visible text.</p><script>alert(1)</script>\
            <iframe srcdoc="&lt;script&gt;parent.document.title='PWNED'&lt;/script&gt;"></iframe>\
            <a href="javascript:alert('JSLINK')">one</a><a href=" JaVaScRiPt:alert(2)">two</a><a href="https://example.com/">web</a>\
            <object data="data:text/html;base64,PHNjcmlwdD4="></object><embed src="data:image/svg+xml;base64,PHN2Zy8+"/>\
            <div style="background:url(https://tracker.invalid/p.png)">styled</div>\
            <meta http-equiv="refresh" content="0;url=https://evil.invalid/"/><base href="https://evil.invalid/"/>\
            <form action="https://evil.invalid/"><input name="q"/></form><img src="x.png" onerror="alert(3)" alt="pic"/>\
            <svg xmlns="http://www.w3.org/2000/svg"><a href="javascript:alert(4)"><text>s</text></a><animate attributeName="href" to="javascript:alert(5)"/></svg>
            """, head: "<style>body { background: url(https://tracker.invalid/bg.png) }</style>")
            let book = try epubFile(dir, "hostile.epub", chapters: [hostile])
            let html = try EPUBBook(url: book).singleHTML()
            let lower = html.lowercased()
            let banned = ["<script", "srcdoc", "javascript:", "<iframe", "<object", "<embed", "tracker.invalid", "evil.invalid",
                          "http-equiv=\"refresh\"", "<base", "<form", "<input", "onerror", "<animate", "data:text/html"]
            let found = banned.filter { lower.contains($0) }
            checks.append(("HTML export drops script, frames, js links, refresh, remote loads (left: \(found))", found.isEmpty))
            checks.append(("HTML export keeps text and web links", html.contains("Visible text.") && html.contains("href=\"https://example.com/\"")))
            checks.append(("HTML export carries a Content-Security-Policy", html.contains("Content-Security-Policy")))

            // Markdown pictures never go into an existing folder.
            var doc = Doc(title: "Pics", author: nil, language: "en")
            let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                .representation(using: .png, properties: [:])!
            let pic = doc.addPicture(png, ext: "png")!
            doc.blocks = [.para([Run(text: "Hello")]), .image(id: pic, alt: "dot", width: nil)]
            let mdDir = dir.appendingPathComponent("md")
            let existing = mdDir.appendingPathComponent("pics images")
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
            let mine = Data("USER FILE".utf8)
            try mine.write(to: existing.appendingPathComponent("\(pic).png"))
            let source = mdDir.appendingPathComponent("pics.epub")
            try EPUBWriter.write(doc, to: source, fallbackTitle: "pics")
            if let command = commands.first(where: { $0.id == "md" }), let run = command.run {
                let outputs = try run([source], ["images": "true"]) { _ in }
                let untouched = (try? Data(contentsOf: existing.appendingPathComponent("\(pic).png"))) == mine
                let folder = outputs.first { $0.pathExtension.isEmpty }
                let md = outputs.first { $0.pathExtension == "md" }.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
                checks.append(("Markdown pictures go to a new folder (\(folder?.lastPathComponent ?? "none")); user's file untouched",
                               untouched && folder?.lastPathComponent == "pics images 2" && md.contains("pics%20images%202/")))
            } else {
                checks.append(("md command", false))
            }

            // EPUB → PDF prints a chapter as written, not what an XSLT stylesheet would make of it.
            let x = dir.appendingPathComponent("x.xhtml")
            try xhtml("<p>Original chapter text.</p>", prolog: "<?xml-stylesheet type=\"text/xsl\" href=\"t.xsl\"?><?xml-stylesheet type=\"text/css\" href=\"a.css\"?>")
                .write(to: x, atomically: true, encoding: .utf8)
            let printed = (try? String(contentsOf: EPUBBook.preparedForPrint(x), encoding: .utf8)) ?? ""
            checks.append(("XSLT processing instruction removed before printing, CSS one kept",
                           !printed.contains("text/xsl") && printed.contains("text/css") && printed.contains("Original chapter text.")))
            let rules = EbooksAndPagesRenderer.contentRules(allowingFolder: dir)
            checks.append(("print rules block file: and the network, except the book folder",
                           rules.contains("^file:") && rules.contains("^https?:") && rules.contains("ignore-previous-rules")))
        } catch {
            checks.append(("export setup: \(error.localizedDescription)", false))
        }
        return checks
    }

    // MARK: PDF → EPUB

    /// A portrait page turned with /Rotate 90 whose lines are drawn running up the page.
    private static func rotatedPDF() -> Data {
        let content = "BT /F1 18 Tf 0 1 -1 0 100 72 Tm (Landscape heading upright) Tj ET\n"
            + "BT /F1 14 Tf 0 1 -1 0 130 72 Tm (Second row of landscape text) Tj ET\n"
            + "BT /F1 14 Tf 0 1 -1 0 160 72 Tm (Name Qty Price) Tj ET\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate 90 /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(format: "%010d 00000 n \n", o) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    private static func rotatedPDFChecks() -> [(String, Bool)] {
        guard let pdf = PDFDocument(data: rotatedPDF()), let page = pdf.page(at: 0) else { return [("rotated PDF builds", false)] }
        let texts = pdfPageBlocks(page).map(\.plainText)
        let expected = ["Landscape heading upright", "Second row of landscape text", "Name Qty Price"]
        return [("sideways lines stay separate lines (got \(texts))", texts == expected)]
    }

    // MARK: EPUB → PDF confinement

    /// A book whose chapter pulls a stylesheet from outside the book with an absolute file: URL, next to one
    /// inside it. Only the inside one may reach the PDF.
    private static func printConfinementChecks(_ dir: URL) -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        do {
            let outside = dir.appendingPathComponent("outside.css")
            try "p::before { content: \"OUTSIDE-SECRET \"; }".write(to: outside, atomically: true, encoding: .utf8)
            let chapter = xhtml("<p>Chapter text.</p>", head: "<link rel=\"stylesheet\" href=\"\(URL(fileURLWithPath: outside.path).absoluteString)\"/>"
                + "<link rel=\"stylesheet\" href=\"in.css\"/>")
            let book = try epubFile(dir, "confined.epub", chapters: [chapter],
                                    files: ["OEBPS/in.css": Data("p::after { content: \" INSIDE-OK\"; }".utf8)])
            guard let command = commands.first(where: { $0.id == "pdf" }), let run = command.run else { return [("pdf command", false)] }
            var result: Result<[URL], Error>?
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Result { try run([book], [:]) { _ in } }
                DispatchQueue.main.async { result = r }
            }
            let deadline = Date().addingTimeInterval(120)
            while result == nil, Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
            if case .success(let urls)? = result, let text = urls.first.flatMap({ PDFDocument(url: $0) })?.string {
                checks.append(("EPUB → PDF reads its own stylesheet", text.contains("INSIDE-OK") && text.contains("Chapter text.")))
                checks.append(("EPUB → PDF can't read a file outside the book", !text.contains("OUTSIDE-SECRET")))
            } else {
                checks.append(("confined EPUB → PDF renders", false))
            }
        } catch {
            checks.append(("confinement setup: \(error.localizedDescription)", false))
        }
        return checks
    }
}
