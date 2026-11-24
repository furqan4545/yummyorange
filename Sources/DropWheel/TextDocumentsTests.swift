#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import PDFKit

/// Headless checks for `--selftest`: Markdown edge cases, round trips between every format pair, offline
/// HTML import, background-thread conversion, and a model dump for looking at what a reader produced.
extension TextDocuments {
    static func selfTest(_ name: String) -> String? {
        if name.hasPrefix("textdocs-dump:") {
            let url = URL(fileURLWithPath: String(name.dropFirst("textdocs-dump:".count)))
            do { return dump(RichDocument(try DocumentIO.read(url))) } catch { return "FAIL \(error.localizedDescription)" }
        }
        if name == "markdown" { return markdownCases() }
        if name == "textdocs-roundtrip" { return roundTrip() }
        if name == "textdocs-thread" { return backgroundThread() }
        if name == "textdocs-encodings" { return encodings() }
        if name == "textdocs-security" { return security() }
        if name == "textdocs-limits" { return limits() }
        if name == "textdocs-structure" { return structure() }
        if name == "pdf-text-convert" { return pdfTextConvertTests() }   // TextDocumentsPDFTextTests.swift
        if name.hasPrefix("textdocs-offline:") { return offline(port: String(name.dropFirst("textdocs-offline:".count))) }
        if name.hasPrefix("textdocs-pdflines:") {
            return RichPDFReader.lineDump(URL(fileURLWithPath: String(name.dropFirst("textdocs-pdflines:".count))))
        }
        return nil
    }

    /// One line per block: kind, list levels, quote depth, and the runs with their looks.
    static func dump(_ doc: RichDocument) -> String {
        var lines = ["body: \(doc.bodyFamily) \(doc.bodySize)pt mono=\(doc.monospaced)"]
        func para(_ p: RichParagraph, indent: String = "") -> String {
            var head = "\(p.kind)"
            if !p.list.isEmpty { head += " list\(p.list.map { $0.style.rawValue }) #\(p.itemNumber)\(p.listContinuation ? " cont" : "")" }
            if let t = p.task { head += " task=\(t)" }
            if p.quoteDepth > 0 { head += " quote\(p.quoteDepth)" }
            if p.alignment != .natural && p.alignment != .left { head += " align\(p.alignment.rawValue)" }
            head += " sp\(Int(p.spaceBefore))/\(Int(p.spaceAfter))"
            let runs = p.runs.map { r -> String in
                if let img = r.image { return "[IMG \(img.name) \(Int(img.displaySize.width))x\(Int(img.displaySize.height)) \(img.format)]" }
                var f: [String] = []
                if r.bold { f.append("b") }; if r.italic { f.append("i") }; if r.code { f.append("code") }
                if r.strike { f.append("s") }; if r.underline { f.append("u") }; if r.script != 0 { f.append("sup\(r.script)") }
                if let l = r.link { f.append("link=\(l)") }; if let c = r.color { f.append("#\(c)") }
                if let fam = r.family { f.append(fam) }; if abs(r.size - doc.bodySize) > 0.1 { f.append("\(r.size)pt") }
                return String(reflecting: r.text) + (f.isEmpty ? "" : "{" + f.joined(separator: ",") + "}")
            }.joined(separator: " ")
            return indent + head + " | " + runs
        }
        for b in doc.blocks {
            switch b {
            case .paragraph(let p): lines.append(para(p))
            case .rule: lines.append("RULE")
            case .pageBreak: lines.append("PAGEBREAK")
            case .table(let t):
                lines.append("TABLE \(t.rows.count)x\(t.columns) header=\(t.headerRows)")
                for (r, row) in t.rows.enumerated() {
                    for (c, cell) in row.enumerated() {
                        if cell.covered { lines.append("  [\(r),\(c)] covered"); continue }
                        lines.append("  [\(r),\(c)] span \(cell.rowSpan)x\(cell.colSpan)" + (cell.background.map { " bg#\($0)" } ?? ""))
                        cell.paragraphs.forEach { lines.append(para($0, indent: "    ")) }
                    }
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Markdown

extension TextDocuments {
    /// The HTML body YummyOrange writes for a Markdown snippet (a compact, checkable form of the parse).
    static func mdBody(_ md: String, base: URL? = nil) -> String {
        let html = RichHTMLWriter.html(RichDocument(MarkdownReader.read(md, baseURL: base)))
        guard let a = html.range(of: "<body>\n"), let b = html.range(of: "\n</body>") else { return html }
        return String(html[a.upperBound..<b.lowerBound])
    }

    static func markdownCases() -> String {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-mdtest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // A tiny PNG next to a fake Markdown file, for local picture paths.
        let pixel = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try? pixel.representation(using: .png, properties: [:])?.write(to: tmp.appendingPathComponent("dot.png"))
        try? pixel.representation(using: .png, properties: [:])?.write(to: tmp.appendingPathComponent("hash #1.png"))
        // A picture beside the test folder: a document must not reach it with ../
        let outside = tmp.deletingLastPathComponent().appendingPathComponent("dropwheel-outside.png")
        if !FileManager.default.fileExists(atPath: outside.path) { try? pixel.representation(using: .png, properties: [:])?.write(to: outside) }
        let base = tmp.appendingPathComponent("doc.md")

        let cases: [(String, String, [String], [String])] = [
            ("emphasis", "*a* **b** ***c*** _d_ __e__ ~~f~~",
             ["<em>a</em>", "<strong>b</strong>", "<strong><em>c</em></strong>", "<em>d</em>", "<strong>e</strong>", "<s>f</s>"], []),
            ("intraword", "snake_case_name and 2*3*4 and un*frigging*believable",
             ["snake_case_name", "2<em>3</em>4", "un<em>frigging</em>believable"], ["<em>case</em>"]),   // CommonMark: * works inside words, _ doesn't
            ("nested emphasis", "**bold *both* bold**", ["<strong>bold </strong><strong><em>both</em></strong><strong> bold</strong>"], []),
            ("code spans", "`a ** b` and `` x ` y ``", ["<code>a ** b</code>", "<code>x ` y</code>"], ["<strong>"]),
            ("escapes", "\\*not\\* \\# \\[x\\] 1\\. a\\\\b", ["*not* # [x] 1. a\\b"], ["<em>"]),
            ("links", "[t](http://x.com \"T\") <http://y.com> www.z.com and <me@ex.com>",
             ["<a href=\"http://x.com\">t</a>", "<a href=\"http://y.com\">http://y.com</a>", "<a href=\"http://www.z.com\">www.z.com</a>",
              "<a href=\"mailto:me@ex.com\">me@ex.com</a>"], []),
            ("reference links", "[one][r] and [r] and [R][]\n\n[r]: http://ref.com 'Title'",
             ["<a href=\"http://ref.com\">one</a>", "<a href=\"http://ref.com\">r</a>", "<a href=\"http://ref.com\">R</a>"], ["[r]:"]),
            ("link with parens", "[w](https://en.wikipedia.org/wiki/Foo_(bar))", ["href=\"https://en.wikipedia.org/wiki/Foo_(bar)\""], []),
            ("headings", "# One #\nSetext\n===\nTwo\n---\n####### seven\n#no", ["<h1>One</h1>", "<h1>Setext</h1>", "<h2>Two</h2>", "####### seven", "#no"], []),
            ("tight list", "- a\n- b\n- c", ["<ul><li>a</li><li>b</li><li>c</li></ul>"], []),
            ("ordered start", "3. three\n4. four", ["<ol start=\"3\"><li>three</li><li>four</li></ol>"], []),
            ("paren list", "1) one\n2) two", ["<ol><li>one</li><li>two</li></ol>"], []),
            ("nested list", "- a\n  1. x\n  2. y\n- b", ["<ul><li>a<ol type=\"a\"><li>x</li><li>y</li></ol></li><li>b</li></ul>"], []),
            ("loose item with continuation", "- a\n\n  more about a\n- b", ["<li>a<p>more about a</p></li>"], []),
            ("task list", "- [ ] todo\n- [x] done", ["<input type=\"checkbox\" disabled>todo", "<input type=\"checkbox\" disabled checked>done"], []),
            ("lazy list continuation", "- item one\ncontinues here\n- two", ["<li>item one continues here</li>"], []),
            ("list after paragraph", "Shopping:\n- milk\n- eggs", ["<p>Shopping:</p>", "<li>milk</li>"], []),
            ("number in text", "The year\n1984. was good", ["The year 1984. was good"], ["<ol"]),
            ("fenced code", "```swift\nlet x = 1 < 2\n```", ["<pre><code class=\"language-swift\">let x = 1 &lt; 2</code></pre>"], []),
            ("tilde fence", "~~~\n```\nnot closing\n~~~", ["<pre><code>```\nnot closing</code></pre>"], []),
            ("indented code", "para\n\n    code line\n    second", ["<pre><code>code line\nsecond</code></pre>"], []),
            ("unclosed fence", "```\nruns to end", ["<pre><code>runs to end</code></pre>"], []),
            ("quote", "> quoted\nlazy line\n\n> > deeper", ["<blockquote>\n<p>quoted lazy line</p>", "<blockquote>\n<p>deeper</p>"], []),
            ("quote with list", "> - in quote\n> - second", ["<blockquote>", "<li>in quote</li><li>second</li>"], []),
            ("rules", "a\n\n***\n\n- - -\n\n___", ["<hr>\n<hr>\n<hr>"], []),
            ("table", "| A | B | C |\n|:--|:-:|--:|\n| 1 | `x\\|y` | **z** |\n| only |",
             ["<th>A</th><th style=\"text-align: center\">B</th><th style=\"text-align: right\">C</th>",
              "<td style=\"text-align: center\"><code>x|y</code></td>", "<strong>z</strong>", "<td>only</td><td style=\"text-align: center\"></td>"], []),
            ("not a table", "a | b\nnot a delimiter", ["<p>a | b not a delimiter</p>"], ["<table"]),
            ("hard breaks", "one  \ntwo\\\nthree", ["one<br>two<br>three"], []),
            ("inline html", "a<br>b <b>bold</b> <sup>2</sup> <kbd>K</kbd> <!-- hidden -->", ["a<br>b", "<strong>bold</strong>", "<sup>2</sup>", "<code>K</code>"], ["hidden"]),
            ("entities", "&copy; &amp; &#169; &#x1F600; &bogus;", ["© &amp; © 😀 &amp;bogus;"], []),
            ("local picture", "![dot](dot.png)", ["<img src=\"data:image/png;base64,", "alt=\"dot\""], []),
            ("remote picture", "![logo](https://example.com/logo.png)", ["<a href=\"https://example.com/logo.png\"><em>[logo]</em></a>"], ["<img"]),
            ("missing picture", "![gone](nothere.png)", ["[gone]"], ["<img"]),
            ("html block", "<div align=\"center\">\n<h1>Title</h1>\n<p>Centered <b>text</b></p>\n</div>",
             ["<h1 style=\"text-align: center\">Title</h1>", "<p style=\"text-align: center\">Centered <strong>text</strong></p>"], ["&lt;div"]),
            ("front matter", "---\ntitle: Hello\ntags: [a, b]\n---\nBody text", ["<p>Body text</p>"], ["title:", "<hr>"]),
            ("empty", "", [], ["<p>"]),
            ("whitespace only", "   \n\n\t\n", [], ["<p>"]),
            ("crlf", "# Head\r\n\r\npara\r\n", ["<h1>Head</h1>", "<p>para</p>"], ["\r"]),
            ("unicode", "Ünïcödé — 日本語 🎉 **粗体**", ["Ünïcödé — 日本語 🎉 <strong>粗体</strong>"], []),
            ("emphasis rule of three", "*foo**bar**baz*", ["<em>foo</em><strong><em>bar</em></strong><em>baz</em>"], []),
            ("unmatched", "**open and *half", ["**open and *half"], ["<strong>", "<em>"]),
            ("adjacent code blocks", "```\nnpm install\n```\n\n```\nnpm start\n```", ["<pre><code>npm install</code></pre>\n<pre><code>npm start</code></pre>"], []),
            ("unsafe links", "[x](javascript:alert(1)) [d](data:text/html,hi) [y](https://ok.com) [r](other.md#top)",
             ["<a href=\"https://ok.com\">y</a>", "<a href=\"other.md#top\">r</a>"], ["javascript", "data:text"]),
            ("html table", "<table>\n<tr><th>Feature</th><th>Status</th></tr>\n\n<tr><td>Alpha</td><td><b>Done</b></td></tr>\n</table>",
             ["<th>Feature</th><th>Status</th>", "<td>Alpha</td><td><strong>Done</strong></td>"], ["FeatureStatus"]),
            ("html scripts and comments", "<div>\n<script>alert(1)</script><!-- note --><p>Kept</p>\n</div>", ["<p>Kept</p>"], ["alert", "note"]),
            ("picture name with #", "![h](hash%20%231.png)", ["<img src=\"data:image/png;base64,"], []),
            ("picture outside the folder", "![up](../dropwheel-outside.png) ![abs](/etc/hosts) ![url](file:///etc/hosts)", ["[up]", "[abs]", "[url]"], ["<img"]),
            ("deep quotes", String(repeating: ">", count: 3000) + " deep", ["deep"], []),
            ("deep emphasis", String(repeating: "*", count: 3000) + "x" + String(repeating: "*", count: 3000), ["x"], []),
        ]
        var failures: [String] = []
        var passed = 0
        for (name, md, want, avoid) in cases {
            let body = mdBody(md, base: base)
            let missing = want.filter { !body.contains($0) }
            let unwanted = avoid.filter { body.contains($0) }
            if missing.isEmpty && unwanted.isEmpty { passed += 1; continue }
            failures.append("\(name): missing \(missing) unwanted \(unwanted)\n    got: \(body)")
        }
        // Writer round trip: Markdown → model → Markdown → model gives the same HTML.
        let sample = "# T\n\nPara with **b**, *i*, `c`, [l](http://l.com) and a_b.\n\n- one\n  - two\n- [x] three\n\n1. a\n2. b\n\n> q\n\n```\ncode\n```\n\n| H | I |\n| --- | ---: |\n| 1 | 2 |\n\n---\n\nend  \nline"
        let first = mdBody(sample)
        let again = MarkdownWriter.markdown(RichDocument(MarkdownReader.read(sample, baseURL: nil))) { _ in nil }
        let second = mdBody(again)
        if first == second { passed += 1 } else { failures.append("writer round trip differs:\n\(first)\n---\n\(second)\n--- markdown:\n\(again)") }
        // Pipes inside code in a table are escaped, so the table reads back with its cells.
        let piped = MarkdownWriter.markdown(RichDocument(MarkdownReader.read("| Command | Meaning |\n| --- | --- |\n| `ls \\| wc -l` | count |", baseURL: nil))) { _ in nil }
        let pipedBack = mdBody(piped)
        if piped.contains("`ls \\| wc -l`"), pipedBack.contains("<td><code>ls | wc -l</code></td><td>count</td>") { passed += 1 }
        else { failures.append("table pipe in code:\n\(piped)\n---\n\(pipedBack)") }
        let total = cases.count + 2
        return failures.isEmpty ? "OK markdown: \(passed)/\(total) cases" : "FAIL markdown: \(passed)/\(total) passed\n" + failures.joined(separator: "\n")
    }
}

// MARK: - Round trips, threads, encodings, offline

extension TextDocuments {
    /// What a document read back from a format still has.
    struct Features: CustomStringConvertible {
        var headings = 0, items = 0, tables = 0, cells = 0, pictures = 0, links = 0, code = 0, quotes = 0
        var text = ""
        var description: String { "h\(headings) li\(items) tbl\(tables)/\(cells) pic\(pictures) link\(links) code\(code) quote\(quotes)" }

        init(_ doc: RichDocument) {
            func scan(_ p: RichParagraph) {
                if p.headingLevel != nil { headings += 1 }
                if !p.list.isEmpty && !p.listContinuation { items += 1 }
                if p.codeLanguage != nil { code += 1 }
                if p.quoteDepth > 0 { quotes += 1 }
                pictures += p.runs.filter { $0.image != nil }.count
                links += Set(p.runs.compactMap(\.link)).count
                text += p.text + "\n"
            }
            for b in doc.blocks {
                switch b {
                case .paragraph(let p): scan(p)
                case .table(let t):
                    tables += 1
                    for row in t.rows { for c in row where !c.covered { cells += 1; c.paragraphs.forEach(scan) } }
                default: break
                }
            }
        }
    }

    static let roundTripSample = """
    # Round Trip

    Text with **bold**, *italic*, `code`, a [link](https://example.com/rt) and café, Zürich, 日本語, Ελληνικά.

    ## Lists

    - alpha
    - beta
      - nested
    1. first
    2. second

    | Name | Qty |
    | --- | ---: |
    | Apple | 3 |
    | Pear | 10 |

    ![dot](dot.png)

    > A quote.

    ```
    let x = 1
    ```
    """

    static func roundTrip() -> String {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("dropwheel-rt-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try? rep.representation(using: .png, properties: [:])?.write(to: tmp.appendingPathComponent("dot.png"))
        let source = tmp.appendingPathComponent("rt.md")
        try? roundTripSample.write(to: source, atomically: true, encoding: .utf8)
        guard let original = try? DocumentIO.read(source) else { return "FAIL couldn’t read the sample" }
        let base = Features(RichDocument(original))
        let phrases = ["Round Trip", "bold", "café", "日本語", "Ελληνικά", "alpha", "nested", "second", "Apple", "Pear", "A quote.", "let x = 1"]

        // What each format must keep: (headings, list items, table, picture, link, code, quote)
        let expect: [String: (h: Bool, li: Bool, tbl: Bool, pic: Bool, link: Bool, code: Bool, quote: Bool)] = [
            "docx": (true, true, true, true, true, true, true),
            "odt": (true, true, true, true, true, false, false),
            "html": (true, true, true, true, true, true, true),
            "md": (true, true, true, true, true, true, true),
            "rtf": (true, true, true, true, true, false, false),
            "rtfd": (true, true, true, true, true, false, false),
            "doc": (true, false, true, false, false, false, false),
            "txt": (false, false, false, false, false, false, false),
        ]
        var lines = ["source md: \(base)"]
        var failed = false
        for ext in ["docx", "odt", "html", "md", "rtf", "rtfd", "doc", "txt", "pdf"] {
            let out = tmp.appendingPathComponent("out.\(ext)")
            do {
                _ = try DocumentIO.write(original, to: out, ext: ext, page: .regional)
                if ext == "pdf" {
                    guard let pdf = PDFDocument(url: out) else { throw ConversionError.unreadable("out.pdf") }
                    let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
                    let missing = phrases.filter { !text.contains($0) }
                    let links = (0..<pdf.pageCount).flatMap { pdf.page(at: $0)?.annotations.compactMap(\.url) ?? [] }
                    let ok = missing.isEmpty && !links.isEmpty
                    failed = failed || !ok
                    lines.append("\(ok ? "PASS" : "FAIL") pdf: \(pdf.pageCount) page(s), \(links.count) link annotation(s)" + (missing.isEmpty ? "" : " missing \(missing)"))
                    continue
                }
                let back = Features(RichDocument(try DocumentIO.read(out)))
                let e = expect[ext]!
                var problems: [String] = phrases.filter { !back.text.contains($0) }.map { "text '\($0)'" }
                if e.h && back.headings < base.headings { problems.append("headings \(back.headings)/\(base.headings)") }
                if e.li && back.items != base.items { problems.append("list items \(back.items)/\(base.items)") }
                if e.tbl && (back.tables != 1 || back.cells != base.cells) { problems.append("table \(back.tables)/\(back.cells)") }
                if e.pic && back.pictures != base.pictures { problems.append("pictures \(back.pictures)") }
                if e.link && back.links < 1 { problems.append("links") }
                if e.code && back.code < 1 { problems.append("code") }
                if e.quote && back.quotes < 1 { problems.append("quote") }
                failed = failed || !problems.isEmpty
                lines.append("\(problems.isEmpty ? "PASS" : "FAIL") \(ext): \(back)" + (problems.isEmpty ? "" : " — " + problems.joined(separator: ", ")))
            } catch {
                failed = true
                lines.append("FAIL \(ext): \(error.localizedDescription)")
            }
        }
        return (failed ? "FAIL round trip\n" : "OK round trip\n") + lines.joined(separator: "\n")
    }

    /// Conversions run off the main thread in the app. Runs them on a background queue while the main thread
    /// keeps its run loop going (HTML import hops to it), as the app does.
    static func backgroundThread() -> String {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("dropwheel-bg-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let md = tmp.appendingPathComponent("bg.md"), html = tmp.appendingPathComponent("bg.html")
        try? roundTripSample.write(to: md, atomically: true, encoding: .utf8)
        try? "<h1>Hello</h1><p>From <b>HTML</b> café</p><ul><li>a</li><li>b</li></ul>".write(to: html, atomically: true, encoding: .utf8)
        var results: [String] = []
        var done = false
        DispatchQueue.global(qos: .userInitiated).async {
            for (src, target) in [(md, "pdf"), (md, "docx"), (html, "pdf"), (html, "odt"), (md, "html")] {
                do {
                    let outs = try convert(src, to: target, options: [:]) { _ in }
                    results.append("PASS \(src.pathExtension)→\(target) on \(Thread.isMainThread ? "main" : "background")")
                    _ = outs
                } catch {
                    results.append("FAIL \(src.pathExtension)→\(target): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async { done = true }
        }
        let deadline = Date().addingTimeInterval(120)
        while !done && Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        if !done { return "FAIL timed out" }
        let ok = results.allSatisfy { $0.hasPrefix("PASS") }
        return (ok ? "OK" : "FAIL") + " background conversions\n" + results.joined(separator: "\n")
    }

    /// Plain-text encodings and text clippings (modern plist and classic resource-fork forms).
    static func encodings() -> String {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("dropwheel-enc-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let sample = "Café – “quotes” naïve"
        var cases: [(String, Data, String)] = [
            ("utf8", Data(sample.utf8), sample),
            ("utf8 bom", Data([0xEF, 0xBB, 0xBF]) + Data(sample.utf8), sample),
            ("utf16le bom", Data([0xFF, 0xFE]) + sample.data(using: .utf16LittleEndian)!, sample),
            ("utf16be bom", Data([0xFE, 0xFF]) + sample.data(using: .utf16BigEndian)!, sample),
            ("utf16le no bom", "Plain ASCII text in UTF-16".data(using: .utf16LittleEndian)!, "Plain ASCII text in UTF-16"),
            ("windows-1252", sample.data(using: .windowsCP1252)!, sample),
            ("utf32le bom", Data([0xFF, 0xFE, 0x00, 0x00]) + sample.data(using: .utf32LittleEndian)!, sample),
        ]
        cases.append(("latin1 high bytes", Data([0x43, 0x61, 0x66, 0xE9, 0x20, 0x81]), "Caf"))
        func cf(_ e: CFStringEncodings) -> String.Encoding { String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue))) }
        let japanese = "日本語のテキストです。これはテストです。", chinese = "中文文本测试。这是第二句话。"
        let traditional = "繁體中文測試。這是第二句話。", korean = "한국어 텍스트입니다. 두 번째 문장."
        let western = "Größe und naïve Café – Übergröße, Ça va très bien, façade."
        for (name, text, encoding) in [("shift_jis", japanese, String.Encoding.shiftJIS), ("euc-jp", japanese, .japaneseEUC),
                                       ("gb18030", chinese, cf(.GB_18030_2000)), ("big5", traditional, cf(.big5)),
                                       ("euc-kr", korean, cf(.EUC_KR)), ("windows-1252 western", western, .windowsCP1252)] {
            if let data = text.data(using: encoding) { cases.append((name, data, text)) }
        }
        var lines: [String] = []
        var failed = false
        for (name, data, want) in cases {
            let got = RichPlainText.decode(data).text
            let ok = got.hasPrefix(want)
            failed = failed || !ok
            lines.append("\(ok ? "PASS" : "FAIL") \(name): \(String(reflecting: got))")
        }
        // Modern clipping: a plist with UTI-Data.
        func clipping(_ name: String, _ uti: [String: Any]) -> URL {
            let url = tmp.appendingPathComponent(name + ".textClipping")
            let data = try! PropertyListSerialization.data(fromPropertyList: ["UTI-Data": uti], format: .binary, options: 0)
            try! data.write(to: url)
            return url
        }
        let rtf = try! NSAttributedString(string: "Bold clipping").data(from: NSRange(location: 0, length: 13), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let clips: [(URL, String)] = [
            (clipping("plain", ["public.utf8-plain-text": "Clipped text ✓"]), "Clipped text ✓"),
            (clipping("rich", ["public.rtf": rtf, "public.utf8-plain-text": "fallback"]), "Bold clipping"),
            (clipping("html", ["public.html": Data("<p>From <b>HTML</b> <img src=\"https://example.com/x.png\" alt=\"pic\"></p>".utf8)]), "From HTML"),
            (clipping("utf16", ["public.utf16-plain-text": "Wide text".data(using: .utf16LittleEndian)!]), "Wide text"),
        ]
        for (url, want) in clips {
            let got = (try? DocumentIO.read(url).string) ?? "(error)"
            let ok = got.contains(want)
            failed = failed || !ok
            lines.append("\(ok ? "PASS" : "FAIL") clipping \(url.deletingPathExtension().lastPathComponent): \(String(reflecting: got))")
        }
        // Classic clipping: empty data fork, text in a 'utf8' resource.
        let classic = tmp.appendingPathComponent("classic.textClipping")
        fm.createFile(atPath: classic.path, contents: Data())
        let payload = Data("Old-style clipping é".utf8)
        var fork = Data()
        func be32(_ v: Int) -> Data { Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
        func be16(_ v: Int) -> Data { Data([UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
        let dataOffset = 256, dataBlock = be32(payload.count) + payload
        let mapOffset = dataOffset + dataBlock.count
        var map = Data(count: 16) + be32(0) + be16(0) + be16(0) + be16(28) + be16(28 + 2 + 8 + 12)
        map += be16(0)                                  // one type
        map += Data("utf8".utf8) + be16(0) + be16(10)   // one resource; reference list 10 bytes after the type list
        map += be16(128) + be16(0xFFFF) + Data([0]) + Data([0, 0, 0]) + be32(0)
        fork += be32(dataOffset) + be32(mapOffset) + be32(dataBlock.count) + be32(map.count)
        fork += Data(count: dataOffset - fork.count) + dataBlock + map
        do {
            try fork.write(to: classic.appendingPathComponent("..namedfork/rsrc"))
            let got = (try? DocumentIO.read(classic).string) ?? "(error)"
            let ok = got.contains("Old-style clipping é")
            failed = failed || !ok
            lines.append("\(ok ? "PASS" : "FAIL") classic clipping (resource fork): \(String(reflecting: got))")
        } catch {
            lines.append("SKIP classic clipping: can’t write a resource fork here (\(error.localizedDescription))")
        }
        return (failed ? "FAIL" : "OK") + " encodings and clippings\n" + lines.joined(separator: "\n")
    }

    /// Imports HTML full of remote references to a local test server, sanitized and (to check the backstop)
    /// unsanitized. The server's own log shows whether anything was fetched.
    static func offline(port: String) -> String {
        let host = "http://127.0.0.1:\(port)"
        let html = """
        <html><head><link rel="stylesheet" href="\(host)/style.css"><script src="\(host)/app.js"></script>
        <style>@import url("\(host)/import.css"); body { background: url('\(host)/bg.png'); }</style>
        <base href="\(host)/"><meta http-equiv="refresh" content="0; url=\(host)/refresh"></head>
        <body><h1>Offline</h1><p>Text <a href="\(host)/link">a link</a> <img src="\(host)/pic.png" alt="remote pic">
        <img srcset="\(host)/a.png 1x, \(host)/b.png 2x"> <span style="background-image:url(\(host)/span.png)">styled</span></p>
        <iframe src="\(host)/frame.html"></iframe><video poster="\(host)/poster.png" src="\(host)/v.mp4"></video>
        <svg><image href="\(host)/svg.png"/></svg><object data="\(host)/obj"></object><img src="//127.0.0.1:\(port)/proto.png"></body></html>
        """
        var lines: [String] = []
        let before = OfflineURLProtocol.refused.count
        do {
            let text = try OfflineHTML.importHTML(html, base: nil)
            let linkKept = text.attribute(.link, at: (text.string as NSString).range(of: "a link").location, effectiveRange: nil) != nil
            lines.append("sanitized import: \(String(reflecting: text.string.trimmingCharacters(in: .whitespacesAndNewlines))) link kept: \(linkKept) refused by guard: \(OfflineURLProtocol.refused.count - before)")
        } catch { lines.append("sanitized import failed: \(error.localizedDescription)") }
        let mid = OfflineURLProtocol.refused.count
        do {
            _ = try OfflineHTML.importHTML(html, base: nil, sanitizing: false)
            lines.append("unsanitized import, guard only: refused \(OfflineURLProtocol.refused.count - mid) request(s)")
        } catch { lines.append("unsanitized import failed: \(error.localizedDescription)") }
        let clean = OfflineHTML.sanitize(html)
        let leftovers = clean.components(separatedBy: host).count - 1 - 1   // the <a href> link is allowed
        lines.append("remote references left after sanitizing (excluding the link): \(leftovers)")
        return (leftovers == 0 ? "OK" : "FAIL") + " offline HTML\n" + lines.joined(separator: "\n")
    }
}


// MARK: - Security, limits, structure

extension TextDocuments {
    /// A minimal DOCX whose document.xml is `body` (already a whole XML part).
    static func docx(_ url: URL, documentXML: String, extra: [(String, Data)] = []) throws {
        let zip = ZipWriter()
        try zip.add("[Content_Types].xml", string: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>")
        try zip.add("_rels/.rels", string: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>")
        try zip.add("word/document.xml", string: documentXML)
        for (name, data) in extra { try zip.add(name, data: data) }
        try zip.write(to: url)
    }

    /// Entities, local files and script links: nothing gets in or out.
    static func security() -> String {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("dropwheel-sec-\(UUID().uuidString)")
        let inbox = tmp.appendingPathComponent("inbox"), privateDir = tmp.appendingPathComponent("private")
        try? fm.createDirectory(at: inbox.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: privateDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        var lines: [String] = []
        var failed = false
        func check(_ ok: Bool, _ what: String) { failed = failed || !ok; lines.append("\(ok ? "PASS" : "FAIL") \(what)") }

        let secret = privateDir.appendingPathComponent("secret.txt")
        try? "TOPSECRET-LOCAL".write(to: secret, atomically: true, encoding: .utf8)
        let w = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
        // External entity in DOCX.
        let xxe = inbox.appendingPathComponent("xxe.docx")
        try? docx(xxe, documentXML: "<?xml version=\"1.0\"?>\n<!DOCTYPE w:document [<!ENTITY x SYSTEM \"file://\(secret.path)\">]><w:document \(w)><w:body><w:p><w:r><w:t>A [&x;] B</w:t></w:r></w:p></w:body></w:document>")
        do { let t = try DocumentIO.read(xxe); check(!t.string.contains("TOPSECRET"), "DOCX entity not expanded (read \(t.string.count) chars)") }
        catch { check(error.localizedDescription.contains("<!DOCTYPE>"), "DOCX with a DTD refused: \(error.localizedDescription)") }
        // A bare DOCTYPE naming an outside DTD (old OpenOffice, Cocoa's own ODT manifest) is fine: it's dropped.
        let bare = inbox.appendingPathComponent("bare.docx")
        try? docx(bare, documentXML: "<?xml version=\"1.0\"?>\n<!DOCTYPE w:document PUBLIC \"-//X//DTD Y//EN\" \"http://127.0.0.1:9/x.dtd\"><w:document \(w)><w:body><w:p><w:r><w:t>Bare doctype</w:t></w:r></w:p></w:body></w:document>")
        check((try? DocumentIO.read(bare))?.string.contains("Bare doctype") == true, "DOCX with a bare external DOCTYPE reads")
        // Billion laughs, in UTF-16 so a plain byte search can't see it.
        var bomb = "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\n<!DOCTYPE w:document [<!ENTITY a \"aaaaaaaaaa\">"
        for k in 1..<10 { bomb += "<!ENTITY \(Character(UnicodeScalar(97 + k)!)) \"" + String(repeating: "&\(Character(UnicodeScalar(96 + k)!));", count: 10) + "\">" }
        bomb += "]><w:document \(w)><w:body><w:p><w:r><w:t>&j;</w:t></w:r></w:p></w:body></w:document>"
        let laughs = inbox.appendingPathComponent("laughs.docx")
        try? docx(laughs, documentXML: "")
        if let z = try? ZipReader(url: laughs) {
            let rebuilt = ZipWriter()
            for e in z.entries where !e.isDirectory {
                try? rebuilt.add(e.name, data: e.name == "word/document.xml" ? Data([0xFF, 0xFE]) + bomb.data(using: .utf16LittleEndian)! : (try? z.read(e)) ?? Data())
            }
            try? rebuilt.write(to: laughs)
        }
        let started = Date()
        let bombResult = Result { try DocumentIO.read(laughs) }
        check((try? bombResult.get()) == nil && Date().timeIntervalSince(started) < 10, "UTF-16 entity bomb refused in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        // Deep XML.
        let deep = inbox.appendingPathComponent("deep.docx")
        try? docx(deep, documentXML: "<w:document \(w)><w:body>" + String(repeating: "<w:sdt><w:sdtContent>", count: 400) + "<w:p><w:r><w:t>x</w:t></w:r></w:p>" + String(repeating: "</w:sdtContent></w:sdt>", count: 400) + "</w:body></w:document>")
        check((try? DocumentIO.read(deep)) == nil, "DOCX nested 800 levels refused")
        // ODT with a DTD.
        let odt = inbox.appendingPathComponent("xxe.odt")
        let zo = ZipWriter()
        try? zo.add("mimetype", string: "application/vnd.oasis.opendocument.text", compress: false)
        try? zo.add("content.xml", string: "<?xml version=\"1.0\"?>\n<!DOCTYPE office:document-content [<!ENTITY x SYSTEM \"file://\(secret.path)\">]><office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\"><office:body><office:text><text:p>A [&x;] B</text:p></office:text></office:body></office:document-content>")
        try? zo.write(to: odt)
        check(((try? DocumentIO.read(odt))?.string.contains("TOPSECRET") ?? false) == false, "ODT entity not expanded")

        // Pictures only from the document's own folder.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        try? png.write(to: privateDir.appendingPathComponent("photo.png"))
        try? png.write(to: inbox.appendingPathComponent("sub/ok.png"))
        let html = inbox.appendingPathComponent("report.html"), md = inbox.appendingPathComponent("notes.md")
        try? "<p><img src=\"file://\(privateDir.path)/photo.png\" alt=\"abs\"><img src=\"../private/photo.png\" alt=\"up\"><img src=\"file:///etc/hosts\" alt=\"hosts\"><img src=\"missing.png\" alt=\"gone\"><img src=\"sub/ok.png\"></p>".write(to: html, atomically: true, encoding: .utf8)
        try? "![abs](\(privateDir.path)/photo.png) ![up](../private/photo.png) ![tilde](~/photo.png) ![ok](sub/ok.png)".write(to: md, atomically: true, encoding: .utf8)
        for (url, name) in [(html, "HTML"), (md, "Markdown")] {
            guard let doc = try? DocumentIO.read(url) else { check(false, "\(name) read"); continue }
            let pics = RichDocument(doc).images.count
            check(pics == 1, "\(name): only the picture inside the folder is embedded (\(pics))")
        }
        // Script links leave every format.
        let links = inbox.appendingPathComponent("links.md")
        try? "[a](javascript:alert(1)) [b](vbscript:x) [c](data:text/html,x) [ok](https://example.com)".write(to: links, atomically: true, encoding: .utf8)
        if let text = try? DocumentIO.read(links) {
            for ext in ["html", "docx", "odt", "md", "rtf", "pdf"] {
                let out = inbox.appendingPathComponent("links-out.\(ext)")
                _ = try? DocumentIO.write(text, to: out, ext: ext, page: .regional)
                var bytes = (try? Data(contentsOf: out)) ?? Data()
                if let z = try? ZipReader(url: out) { bytes = z.entries.compactMap { try? z.read($0) }.reduce(Data(), +) }
                let s = String(decoding: bytes, as: UTF8.self).lowercased()
                check(!s.contains("javascript:") && !s.contains("vbscript:") && !s.contains("data:text/html"), "\(ext): no script links")
            }
        }
        return (failed ? "FAIL" : "OK") + " document security\n" + lines.joined(separator: "\n")
    }

    /// Hostile nesting and sizes, run where conversions run (a thread with a 512 KB stack), with time limits.
    static func limits() -> String {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("dropwheel-limits-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let cases: [(String, String, String, Double)] = [
            ("deep quotes", "md", String(repeating: ">", count: 2000) + " deep\n", 10),
            ("deep lists", "md", (0..<300).map { String(repeating: "  ", count: $0) + "- item \($0)\n" }.joined(), 20),
            ("nested brackets", "md", String(repeating: "[", count: 30000) + "x" + String(repeating: "]", count: 30000) + "\n", 15),
            ("open link parens", "md", String(repeating: "[a](", count: 15000) + "\n", 15),
            ("open link titles", "md", String(repeating: "[a](x (", count: 15000) + "\n", 15),
            ("unmatched emphasis", "md", String(repeating: "a* ", count: 30000) + "\n", 15),
            ("nested pictures", "md", String(repeating: "![", count: 10000) + "x" + String(repeating: "](u)", count: 10000) + "\n", 15),
            ("deep emphasis", "md", String(repeating: "*", count: 20000) + "x" + String(repeating: "*", count: 20000) + "\n", 15),
            ("unclosed scripts", "html", "<p>start</p>" + String(repeating: "<script x>", count: 20000), 20),
            ("unclosed comments", "md", String(repeating: "<!-- ", count: 20000) + "\n", 15),
            ("one long paragraph", "txt", (0..<150000).map { ["alpha", "beta", "gamma", "delta"][$0 % 4] }.joined(separator: " ") + "\n", 40),
        ]
        var lines: [String] = []
        var failed = false
        for (name, ext, text, limit) in cases {
            let src = tmp.appendingPathComponent("\(name.replacingOccurrences(of: " ", with: "-")).\(ext)")
            try? text.write(to: src, atomically: true, encoding: .utf8)
            let target = ext == "txt" ? "pdf" : (ext == "md" ? "html" : "md")
            var outcome = "timed out"
            let done = DispatchSemaphore(value: 0)
            let started = Date()
            let thread = Thread {
                do { _ = try convert(src, to: target, options: [:]) { _ in }; outcome = "ok" } catch { outcome = "error: \(error.localizedDescription)" }
                done.signal()
            }
            thread.stackSize = 512 * 1024
            thread.start()
            let deadline = Date().addingTimeInterval(limit * 4)
            while done.wait(timeout: .now()) == .timedOut, Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            let seconds = Date().timeIntervalSince(started)
            let ok = outcome == "ok" && seconds < limit
            failed = failed || !ok
            lines.append("\(ok ? "PASS" : "FAIL") \(name) → \(target): \(outcome) in \(String(format: "%.2f", seconds)) s (limit \(Int(limit)) s)")
            if outcome == "timed out" { break }
        }
        return (failed ? "FAIL" : "OK") + " limits\n" + lines.joined(separator: "\n")
    }

    /// What readers and writers keep: ODT headings, merged cells and list numbers, right-to-left paragraphs,
    /// separate code blocks, picture alt text, tall boxes in PDFs, ligature PDFs and turned pages, mixed selections.
    static func structure() -> String {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("dropwheel-struct-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        var lines: [String] = []
        var failed = false
        func check(_ ok: Bool, _ what: String) { failed = failed || !ok; lines.append("\(ok ? "PASS" : "FAIL") \(what)") }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try? rep.representation(using: .png, properties: [:])?.write(to: tmp.appendingPathComponent("pic.png"))

        // Markdown → ODT → back: heading levels, list start numbers and styles, merged cells, alt text.
        let md = tmp.appendingPathComponent("s.md")
        try? "# One\n\n## Two\n\n### Three\n\n3. three\n4. four\n\nnote\n\n![ALT-TEXT](pic.png)\n\n```\nfirst\n```\n\n```\nsecond\n```\n".write(to: md, atomically: true, encoding: .utf8)
        if let text = try? DocumentIO.read(md) {
            let odt = tmp.appendingPathComponent("s.odt")
            _ = try? DocumentIO.write(text, to: odt, ext: "odt", page: .regional)
            if let back = try? DocumentIO.read(odt) {
                let doc = RichDocument(back)
                let levels = doc.blocks.compactMap { if case .paragraph(let p) = $0 { return p.headingLevel } else { return nil } }
                check(levels == [1, 2, 3], "ODT heading levels \(levels)")
                let numbers = doc.blocks.compactMap { b -> Int? in if case .paragraph(let p) = b, !p.list.isEmpty { return p.itemNumber } else { return nil } }
                check(numbers == [3, 4], "ODT list numbers \(numbers)")
                check(doc.images.first?.alt == "ALT-TEXT", "ODT picture alt text '\(doc.images.first?.alt ?? "")'")
            } else { check(false, "ODT read back") }
            let docx = tmp.appendingPathComponent("s.docx")
            _ = try? DocumentIO.write(text, to: docx, ext: "docx", page: .regional)
            if let back = try? DocumentIO.read(docx) {
                let html = RichHTMLWriter.html(RichDocument(back))
                check(html.components(separatedBy: "<pre>").count - 1 == 2, "two code blocks survive DOCX")
            }
        }
        // ODT with a merged cell and a covered cell, as LibreOffice writes it.
        let lo = tmp.appendingPathComponent("lo.odt")
        let ns = "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\""
        let z = ZipWriter()
        try? z.add("mimetype", string: "application/vnd.oasis.opendocument.text", compress: false)
        try? z.add("content.xml", string: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-content \(ns) office:version=\"1.2\"><office:body><office:text><text:h text:outline-level=\"2\">Second</text:h><table:table table:name=\"T\"><table:table-column table:number-columns-repeated=\"3\"/><table:table-row><table:table-cell><text:p>H1</text:p></table:table-cell><table:table-cell><text:p>H2</text:p></table:table-cell><table:table-cell><text:p>H3</text:p></table:table-cell></table:table-row><table:table-row><table:table-cell table:number-columns-spanned=\"2\"><text:p>SPAN</text:p></table:table-cell><table:covered-table-cell/><table:table-cell><text:p>C-ONLY</text:p></table:table-cell></table:table-row></table:table></office:text></office:body></office:document-content>")
        try? z.add("META-INF/manifest.xml", string: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.text\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>")
        try? z.write(to: lo)
        if let back = try? DocumentIO.read(lo) {
            let doc = RichDocument(back)
            check(doc.blocks.contains { if case .paragraph(let p) = $0 { return p.headingLevel == 2 } else { return false } }, "LibreOffice heading level 2")
            var cell: (span: Int, col: Int)?
            for case .table(let t) in doc.blocks where t.rows.count == 2 {
                if let c = t.rows[1].firstIndex(where: { $0.paragraphs.contains { $0.text == "C-ONLY" } }) { cell = (t.rows[1][0].colSpan, c) }
            }
            check(cell?.span == 2 && cell?.col == 2, "merged cell spans 2 and C-ONLY stays in column 3 (\(String(describing: cell)))")
            check(!back.string.contains("DWODT"), "no ODT markers left")
        } else { check(false, "LibreOffice-style ODT read") }

        // Right-to-left DOCX paragraphs.
        let rtl = tmp.appendingPathComponent("rtl.docx")
        try? docx(rtl, documentXML: "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:pPr><w:bidi/></w:pPr><w:r><w:rPr><w:rtl/></w:rPr><w:t>مرحبا بالعالم!</w:t></w:r></w:p><w:p><w:r><w:t>Left to right.</w:t></w:r></w:p></w:body></w:document>")
        if let text = try? DocumentIO.read(rtl) {
            let html = RichHTMLWriter.html(RichDocument(text))
            check(html.contains("<p dir=\"rtl\">مرحبا") && html.contains("<p>Left to right.</p>"), "right-to-left paragraph keeps dir=rtl")
            let odt = tmp.appendingPathComponent("rtl.odt")
            _ = try? DocumentIO.write(text, to: odt, ext: "odt", page: .regional)
            let content = (try? ZipReader(url: odt)).flatMap { try? $0.readString("content.xml") } ?? ""
            check(content.contains("rl-tb"), "ODT writing-mode rl-tb")
        }

        // A code block taller than a page: every line in the PDF.
        let tall = tmp.appendingPathComponent("tall.md")
        try? ("```\n" + (0..<300).map { String(format: "codeline %04d", $0) }.joined(separator: "\n") + "\n```\n\nEND-MARKER\n").write(to: tall, atomically: true, encoding: .utf8)
        if let text = try? DocumentIO.read(tall) {
            let pdfURL = tmp.appendingPathComponent("tall.pdf")
            _ = try? DocumentIO.write(text, to: pdfURL, ext: "pdf", page: .regional)
            let pdfText = PDFDocument(url: pdfURL).map { d in (0..<d.pageCount).compactMap { d.page(at: $0)?.string }.joined(separator: "\n") } ?? ""
            let found = Set(pdfText.components(separatedBy: .newlines).filter { $0.hasPrefix("codeline ") }).count
            check(found == 300 && pdfText.contains("END-MARKER"), "tall code block: \(found)/300 lines in the PDF")
        }

        // PDF → DOCX: ligatures, and a picture on a page turned with /Rotate.
        let lig = tmp.appendingPathComponent("lig.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        if let ctx = CGContext(lig as CFURL, mediaBox: &box, nil), let font = NSFont(name: "Palatino", size: 12) ?? NSFont(name: "Times New Roman", size: 12) {
            ctx.beginPDFPage(nil)
            for k in 0..<12 {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Line \(k + 1): the official financial figures were filed in the office.", attributes: [.font: font]))
                ctx.textPosition = CGPoint(x: 72, y: 720 - CGFloat(k) * 20)
                CTLineDraw(line, ctx)
            }
            ctx.endPDFPage(); ctx.closePDF()
            if let (doc, _) = try? RichPDFReader.document(lig) {
                let text = doc.blocks.map { if case .paragraph(let p) = $0 { return p.text } else { return "" } }.joined(separator: "\n")
                check(text.contains("Line 12: the official financial figures were filed in the office."), "ligature PDF keeps its last line")
                check(!text.contains("of fice") && !text.contains("fig ures"), "ligature PDF words not split")
            } else { check(false, "ligature PDF read") }
        }
        let turned = tmp.appendingPathComponent("turned.pdf")
        var page = CGRect(x: 0, y: 0, width: 400, height: 400)
        if let ctx = CGContext(turned as CFURL, mediaBox: &page, nil), let cg = rep.cgImage {
            ctx.beginPDFPage(nil)
            ctx.draw(cg, in: CGRect(x: 100, y: 100, width: 160, height: 80))
            ctx.endPDFPage(); ctx.closePDF()
            if let pdf = PDFDocument(url: turned), let p = pdf.page(at: 0) {
                p.rotation = 90
                pdf.write(to: turned)
                if let (doc, _) = try? RichPDFReader.document(turned) {
                    let size = doc.images.first?.displaySize ?? .zero
                    check(doc.images.count == 1 && size.height > size.width, "picture on a /Rotate 90 page kept, turned (\(Int(size.width))x\(Int(size.height)))")
                } else { check(false, "turned PDF read") }
            }
        }

        // A petal offered for docx + md skips the DOCX instead of failing on it.
        let a = tmp.appendingPathComponent("a.md"), bDoc = tmp.appendingPathComponent("b.docx")
        try? "# A".write(to: a, atomically: true, encoding: .utf8)
        if let text = try? DocumentIO.read(a) { _ = try? DocumentIO.write(text, to: bDoc, ext: "docx", page: .regional) }
        if let command = commands.first(where: { $0.id == "docx" && $0.applies([a, bDoc]) }), let run = command.run {
            let outs = (try? run([a, bDoc], [:], { _ in })) ?? []
            let single = (try? run([bDoc], [:], { _ in })) ?? [URL(fileURLWithPath: "/error")]
            check(outs.count == 1 && outs[0].pathExtension == "docx" && single.isEmpty, "mixed selection: md converted, docx skipped (\(outs.map(\.lastPathComponent)))")
        } else { check(false, "DOCX petal offered for md + docx") }
        return (failed ? "FAIL" : "OK") + " structure\n" + lines.joined(separator: "\n")
    }
}
#endif
