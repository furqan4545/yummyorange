#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import CoreText
import PDFKit

/// `--selftest pdf-text-convert`: PDF → TXT and PDF → Markdown on the fixtures in Tests/fixtures/core (report.pdf,
/// tagged.pdf, big.pdf, scan.pdf) and on two PDFs made here: a rich one (headings, lists, a table, a link, emphasis,
/// a picture) and a three-page one with running headers, a sentence over a page break and two columns.
/// Run it from the project folder (test.sh does), or point DW_FIXTURES at the fixtures folder.
extension TextDocuments {
    static func pdfTextConvertTests() -> String {
        let c = AppShellTests.Checker()
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("dropwheel-pdftext-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        petals(c, tmp)
        helpers(c)
        if let fixtures = pdfTextFixtures() {
            textDump(c, fixtures, tmp)
            noText(c, fixtures, tmp)
            scanned(c, fixtures, tmp)
        } else {
            c.check("fixtures found (run from the project folder or set DW_FIXTURES)", false)
        }
        badInput(c, tmp)
        rich(c, tmp)
        columns(c, tmp)
        rightToLeft(c, tmp)
        raggedColumn(c, tmp)
        failedWrite(c, tmp)
        blankPages(c, tmp)
        return c.report("pdf-text-convert")
    }

    /// Tests/fixtures/core, from DW_FIXTURES, the working folder or the folders above the binary.
    static func pdfTextFixtures() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["DW_FIXTURES"] { candidates.append(URL(fileURLWithPath: env)) }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/fixtures/core"))
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<5 {
            candidates.append(dir.appendingPathComponent("Tests/fixtures/core"))
            dir.deleteLastPathComponent()
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("report.pdf").path) }
    }

    // MARK: Petals

    private static func petals(_ c: AppShellTests.Checker, _ tmp: URL) {
        let pdf = tmp.appendingPathComponent("p.pdf"), docx = tmp.appendingPathComponent("d.docx")
        let ids = Registry.convertCommands(for: [pdf], besides: OutputFormat.targets(forAll: [pdf])).map(\.id)
        let order = ["docx", "txt", "md", "epub"].map { ids.firstIndex(of: $0) ?? -1 }
        c.check("a PDF's Convert wheel offers TXT and Markdown right after DOCX", !order.contains(-1) && order == order.sorted(),
                ids.joined(separator: " "))
        let mine = Registry.commands(for: .convert, files: [pdf]).filter { ["txt", "md"].contains($0.id) }
        c.check("titled TXT and Markdown, as the other text petals are",
                mine.map(\.title) == ["TXT", "Markdown"] && targets.contains { $0.id == "md" && $0.title == "Markdown" }, mine.map(\.title).description)
        c.check("plain per-file conversions (no prompt, no window)", mine.allSatisfy { $0.ask == nil && $0.present == nil && !$0.combinesInputs })
        let png = Registry.commands(for: .convert, files: [tmp.appendingPathComponent("a.png")]).map(\.id)
        c.check("not offered for a PNG", !png.contains("txt") && !png.contains("md"), png.joined(separator: " "))
        let mixed = Registry.mixedConvertCommands(for: [pdf, docx], besides: OutputFormat.targets(forAll: [pdf, docx])).map(\.id)
        c.check("PDF + DOCX together get TXT and Markdown", mixed.contains("txt") && mixed.contains("md"), mixed.joined(separator: " "))
    }

    // MARK: Model helpers

    private static func helpers(_ c: AppShellTests.Checker) {
        func para(_ s: String) -> RichBlock { var p = RichParagraph(); p.runs = [RichRun(text: s)]; return .paragraph(p) }
        func texts(_ b: [RichBlock]) -> [String] { b.compactMap { if case .paragraph(let p) = $0 { return p.text } else { return nil } } }
        let hyphen = joinedAcrossPages([para("the plan was recon-"), .pageBreak, para("sidered in May.")])
        c.check("a word hyphenated over a page break joins up", texts(hyphen) == ["the plan was reconsidered in May."], texts(hyphen).description)
        let ended = joinedAcrossPages([para("It ended."), .pageBreak, para("then again")])
        c.check("a finished sentence doesn't join the next page", texts(ended).count == 2)
        let upper = joinedAcrossPages([para("It goes on"), .pageBreak, para("Next page")])
        c.check("a capitalised start doesn't join", texts(upper).count == 2)
        c.check("Markdown block starts are recognised", startsBlock("- item") && startsBlock("12. twelve") && startsBlock("# x")
                && startsBlock("---") && startsBlock("| a |") && !startsBlock("Line 1: text") && !startsBlock("-3 degrees"))
        // A line at the top of every page that also appears in the text is content, not a header.
        let pages: [RichBlock] = [para("Report 1"), para("a"), para("b"), para("c"), para("d"), .pageBreak,
                                  para("Report 2"), para("e"), para("Report 9"), para("f"), para("g")]
        c.check("a line that also sits in the text stays", texts(withoutRunningHeaders(pages)).filter { $0.hasPrefix("Report") }.count == 3)
        let headed: [RichBlock] = [para("Acme Confidential"), para("Body one"), .pageBreak, para("Acme Confidential"), para("Body two")]
        c.check("a line on top of every page goes", texts(withoutRunningHeaders(headed)) == ["Body one", "Body two"])
        func heading(_ s: String) -> RichBlock { var p = RichParagraph(); p.kind = .heading(1); p.runs = [RichRun(text: s)]; return .paragraph(p) }
        let chapters: [RichBlock] = [heading("Chapter 1"), para("One."), .pageBreak, heading("Chapter 2"), para("Two.")]
        c.check("a heading on top of every page stays (chapters)", texts(withoutRunningHeaders(chapters)).count == 4)
    }

    // MARK: Fixtures

    private static func copy(_ name: String, from fixtures: URL, to tmp: URL, folder: String) -> URL? {
        let dir = tmp.appendingPathComponent(folder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: url)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func read(_ url: URL?) -> String { url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "" }

    /// report.pdf and tagged.pdf: monospaced text dumps (3 pages, 165 lines, no line breaks in PDFKit's text).
    private static func textDump(_ c: AppShellTests.Checker, _ fixtures: URL, _ tmp: URL) {
        guard let report = copy("report.pdf", from: fixtures, to: tmp, folder: "dump"),
              let tagged = copy("tagged.pdf", from: fixtures, to: tmp, folder: "dump") else { c.check("copy report.pdf, tagged.pdf", false); return }
        let before = try? Data(contentsOf: report)
        let txtURL = try? pdfToText(report, options: [:]) { _ in }
        let txt = read(txtURL)
        let lines = txt.components(separatedBy: "\n").dropLast()
        c.check("report.pdf → report.txt", txtURL?.lastPathComponent == "report.txt")
        c.check("every line of the dump, in order (165)", lines.count == 165 && lines.first == "Quarterly Report - Page 1"
                && lines.filter { $0.hasSuffix("The quick brown fox jumps over the lazy dog.") }.count == 162, "\(lines.count) lines")
        var ordered = true, last = 0
        for l in lines {
            if l.hasPrefix("Quarterly Report") { last = 0; continue }
            guard let n = Int(l.dropFirst(5).prefix { $0.isNumber }) else { continue }
            if n != last + 1 { ordered = false }
            last = n
        }
        c.check("numbered lines run 1, 2, 3… in every section", ordered)
        c.check("no form feeds and no blank lines by default", !txt.contains("\u{0C}") && !lines.contains(""))
        c.check("the input is unchanged", before != nil && before == (try? Data(contentsOf: report)))
        let paged = read(try? pdfToText(report, options: ["pageBreaks": "true"]) { _ in })
        c.check("pageBreaks=true puts a form feed between the 3 pages", paged.filter { $0 == "\u{0C}" }.count == 2)

        let mdURLs = (try? pdfToMarkdown(report, options: [:]) { _ in }) ?? []
        let md = read(mdURLs.first)
        let mdLines = md.components(separatedBy: "\n").dropLast()
        c.check("report.pdf → report.md, no pictures folder", mdURLs.map(\.lastPathComponent) == ["report.md"])
        c.check("Markdown keeps the lines as one block with line breaks", mdLines.count == 165
                && mdLines.filter { $0.hasSuffix("\\") }.count == 164 && !mdLines.contains(""), "\(mdLines.count) lines")

        let taggedText = read(try? pdfToText(tagged, options: [:]) { _ in })
        c.check("tagged.pdf reads the same as report.pdf (its sticky note isn't text)", taggedText == txt && !taggedText.contains("review this"))
    }

    /// big.pdf is one photo: no text, nothing written.
    private static func noText(_ c: AppShellTests.Checker, _ fixtures: URL, _ tmp: URL) {
        guard let big = copy("big.pdf", from: fixtures, to: tmp, folder: "big") else { c.check("copy big.pdf", false); return }
        for (name, run) in [("TXT", { _ = try pdfToText(big, options: [:]) { _ in } }), ("Markdown", { _ = try pdfToMarkdown(big, options: [:]) { _ in } })] as [(String, () throws -> Void)] {
            var message = ""
            do { try run() } catch { message = error.localizedDescription }
            c.check("big.pdf → \(name): “No text found”, with what to do", message.hasPrefix("No text found in big.pdf.") && message.contains("PNG or JPG"), message)
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: big.deletingLastPathComponent().path)) ?? []
        c.check("nothing written for big.pdf", left == ["big.pdf"], left.joined(separator: ", "))
    }

    /// scan.pdf: two scanned pages of the same dump, read with OCR.
    private static func scanned(_ c: AppShellTests.Checker, _ fixtures: URL, _ tmp: URL) {
        guard let scan = copy("scan.pdf", from: fixtures, to: tmp, folder: "scan") else { c.check("copy scan.pdf", false); return }
        let before = try? Data(contentsOf: scan)
        let txt = read(try? pdfToText(scan, options: [:]) { _ in })
        let found = txt.components(separatedBy: "\n").filter { $0.contains("quick brown") }.count
        c.check("scan.pdf → TXT through OCR (most of its ~115 lines)", found >= 80, "\(found) lines read")
        // OCR misreads a few line numbers ("Line S:"); the ones it reads should mostly run in order.
        let numbers = txt.components(separatedBy: "\n").compactMap { l -> Int? in
            guard let r = l.range(of: "^Line \\d+", options: .regularExpression) else { return nil }
            return Int(l[r].dropFirst(5))
        }
        let inOrder = zip(numbers, numbers.dropFirst()).filter { a, b in (1...3).contains(b - a) || b <= 2 }.count
        c.check("scan.pdf reads top to bottom, page 1 then page 2", numbers.count > 50 && Double(inOrder) >= 0.8 * Double(numbers.count - 1),
                "\(inOrder) of \(numbers.count - 1) steps in order")
        c.check("scan.pdf → TXT has no form feeds", !txt.contains("\u{0C}"))
        c.check("scan.pdf is unchanged", before != nil && before == (try? Data(contentsOf: scan)))
        let md = read((try? pdfToMarkdown(scan, options: [:]) { _ in })?.first)
        c.check("scan.pdf → Markdown through OCR", md.components(separatedBy: "\n").filter { $0.contains("quick brown") }.count >= 80)
        var message = ""
        do { _ = try pdfToText(scan, options: ["ocr": "false"]) { _ in } } catch { message = error.localizedDescription }
        c.check("ocr=false on a scan says to turn OCR on", message.contains("OCR is off"), message)
    }

    /// A password-protected PDF and a file that isn't a PDF at all: clear errors, nothing written.
    private static func badInput(_ c: AppShellTests.Checker, _ tmp: URL) {
        let dir = tmp.appendingPathComponent("bad")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let locked = dir.appendingPathComponent("locked.pdf"), junk = dir.appendingPathComponent("junk.pdf")
        let plain = dir.appendingPathComponent("plain.pdf")
        if makeColumnsPDF(plain), let doc = PDFDocument(url: plain) {
            _ = doc.write(to: locked, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "secret"])
        }
        try? FileManager.default.removeItem(at: plain)
        try? Data("this is not a PDF".utf8).write(to: junk)
        for (url, expect) in [(locked, "password-protected"), (junk, "Couldn’t read junk.pdf")] {
            for (name, run) in [("TXT", { _ = try pdfToText(url, options: [:]) { _ in } }),
                                ("Markdown", { _ = try pdfToMarkdown(url, options: [:]) { _ in } })] as [(String, () throws -> Void)] {
                var message = ""
                do { try run() } catch { message = error.localizedDescription }
                c.check("\(url.lastPathComponent) → \(name): clear error", message.contains(expect), message)
            }
        }
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        c.check("nothing written for bad input", left == ["junk.pdf", "locked.pdf"], left.joined(separator: ", "))
    }

    // MARK: A rich PDF

    private static let longParagraph = String(repeating: "The committee reviewed every proposal in detail and agreed that the new reading room should open in the spring, after the shelving and the lighting have been replaced. ", count: 4).trimmingCharacters(in: .whitespaces)

    private static func rich(_ c: AppShellTests.Checker, _ tmp: URL) {
        let dir = tmp.appendingPathComponent("rich")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A 240 × 120 picture: orange with a blue band.
        let ctx = CGContext(data: nil, width: 240, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.94, green: 0.59, blue: 0.16, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 120))
        ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.35, blue: 0.78, alpha: 1)); ctx.fill(CGRect(x: 0, y: 50, width: 240, height: 20))
        if let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent("chart.png") as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
        }
        let source = """
        # Annual Library Report

        This report covers the year's work. Read the full plan on [the library website](https://example.org/plan) or write to the board.

        ## Highlights

        \(longParagraph)

        - Opened a children's corner
        - Extended weekend hours
          - Saturday until 8 pm
          - Sunday from noon
        - Digitised the map collection

        1. Collect feedback from readers
        2. Publish the budget
        3. Hire two librarians

        ## Visitors by Branch

        | Branch | Visitors | Change |
        | --- | --- | --- |
        | Central | 48,210 | +12% |
        | Harbour | 17,904 | +3% |
        | Hillside | 9,388 | -2% |

        ![Visitors chart](chart.png)

        ### Notes

        Opening hours are *subject to change* and **bold decisions** were taken in March.

        """
        let mdSource = dir.appendingPathComponent("source.md"), pdf = dir.appendingPathComponent("rich.pdf")
        try? source.write(to: mdSource, atomically: true, encoding: .utf8)
        guard let text = try? DocumentIO.read(mdSource), (try? DocumentIO.write(text, to: pdf, ext: "pdf", page: .regional)) != nil else {
            c.check("make the rich PDF", false); return
        }
        let outputs = (try? pdfToMarkdown(pdf, options: [:]) { _ in }) ?? []
        let md = read(outputs.first)
        let mdLines = md.components(separatedBy: "\n")
        c.check("rich.pdf → rich.md + “rich images”", outputs.map(\.lastPathComponent) == ["rich.md", "rich images"])
        c.check("headings keep their levels", mdLines.contains("# Annual Library Report") && mdLines.contains("## Highlights")
                && mdLines.contains("## Visitors by Branch") && mdLines.contains("### Notes"))
        c.check("bulleted list with a nested level", mdLines.contains("- Opened a children's corner") && mdLines.contains("  - Saturday until 8 pm")
                && mdLines.contains("- Digitised the map collection"))
        c.check("numbered list, set apart from the bulleted one", mdLines.contains("1. Collect feedback from readers")
                && mdLines.contains("3. Hire two librarians") && md.contains("collection\n\n1. Collect"))
        c.check("table with a header row", mdLines.contains("| Branch | Visitors | Change |") && mdLines.contains("| --- | --- | --- |")
                && mdLines.contains("| Hillside | 9,388 | -2% |"))
        c.check("link", md.contains("[the library website](https://example.org/plan)"))
        c.check("emphasis", md.contains("*subject to change*") && md.contains("**bold decisions**"))
        c.check("the long paragraph is one reflowed line", mdLines.contains(longParagraph))
        let folder = dir.appendingPathComponent("rich images")
        let pictures = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let picture = pictures.first.flatMap { NSImage(contentsOf: folder.appendingPathComponent($0)) }
        c.check("the picture is saved and linked", pictures.count == 1 && md.contains("](rich%20images/\(pictures.first ?? "?"))")
                && (picture?.representations.first?.pixelsWide ?? 0) >= 200, pictures.joined(separator: ", "))
        c.check("reading order: title, highlights, lists, table, picture, notes", ["# Annual", "## Highlights", "- Opened", "1. Collect", "| Branch", "![", "### Notes"]
                .map { s in md.range(of: s)?.lowerBound.utf16Offset(in: md) ?? -1 }.isIncreasing)

        let txt = read(try? pdfToText(pdf, options: [:]) { _ in })
        let txtLines = txt.components(separatedBy: "\n")
        c.check("TXT: headings as plain lines", txtLines.contains("Annual Library Report") && !txt.contains("#"))
        c.check("TXT: list markers and nesting", txtLines.contains("• Opened a children's corner") && txtLines.contains("    ◦ Saturday until 8 pm")
                && txtLines.contains("1. Collect feedback from readers"))
        c.check("TXT: table in aligned columns", txtLines.contains { $0.range(of: "^Hillside +9,388 +-2%$", options: .regularExpression) != nil }
                && txtLines.contains { $0.range(of: "^Branch +Visitors +Change$", options: .regularExpression) != nil })
        c.check("TXT: a link keeps its address", txt.contains("the library website (https://example.org/plan) or write"))
        c.check("TXT: the long paragraph is one line, set apart by blank lines", txt.contains("\n\n" + longParagraph + "\n\n"))
        c.check("TXT: no picture markers by default", !txt.contains("[Picture"))
        c.check("TXT images=true marks the picture", read(try? pdfToText(pdf, options: ["images": "true"]) { _ in }).contains("[Picture"))
        let bare = (try? pdfToMarkdown(pdf, options: ["images": "false"]) { _ in }) ?? []
        c.check("Markdown images=false writes no folder and no picture", bare.count == 1 && !read(bare.first).contains("!["))
    }

    // MARK: Pages and columns

    /// Three US Letter pages: a running header and a "Page n of 3" footer on each, a sentence that runs from page 1
    /// onto page 2, then two columns on page 2.
    static func makeColumnsPDF(_ url: URL) -> Bool {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        func text(_ s: String, _ size: CGFloat, bold: Bool = false) -> NSAttributedString {
            let font = NSFont(name: bold ? "Helvetica-Bold" : "Times New Roman", size: size) ?? .systemFont(ofSize: size)
            let style = NSMutableParagraphStyle(); style.paragraphSpacing = size * 0.8
            return NSAttributedString(string: s, attributes: [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.black])
        }
        func draw(_ s: NSAttributedString, _ rect: CGRect) {
            let setter = CTFramesetterCreateWithAttributedString(s)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil), ctx)
        }
        let filler = "Readers asked for longer opening hours, quieter study rooms and better lighting in the reading room, and the staff answered with a plan that is easy to follow. "
        for page in 1...3 {
            ctx.beginPDFPage(nil)
            draw(text("Annual Library Report — Confidential", 9), CGRect(x: 72, y: 740, width: 468, height: 20))
            draw(text("Page \(page) of 3", 9), CGRect(x: 280, y: 30, width: 100, height: 20))
            switch page {
            case 1:
                let body = NSMutableAttributedString(attributedString: text("Opening Hours\n", 22, bold: true))
                body.append(text(String(repeating: filler, count: 9) + "The last part of this sentence carries on over the page break and ends on the next", 12))
                draw(body, CGRect(x: 72, y: 90, width: 468, height: 630))
            case 2:
                draw(text("page, where the story continues as planned.", 12), CGRect(x: 72, y: 690, width: 468, height: 30))
                draw(text("Two Columns", 18, bold: true), CGRect(x: 72, y: 650, width: 468, height: 30))
                draw(text("LEFT one. " + String(repeating: filler, count: 3) + "Left column ends here.", 12), CGRect(x: 72, y: 90, width: 220, height: 550))
                draw(text("RIGHT one. " + String(repeating: filler, count: 3) + "Right column ends here.", 12), CGRect(x: 320, y: 90, width: 220, height: 550))
            default:
                draw(text("Closing", 18, bold: true), CGRect(x: 72, y: 680, width: 468, height: 40))
                draw(text("The board thanks every reader for their patience.", 12), CGRect(x: 72, y: 600, width: 468, height: 70))
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return PDFDocument(url: url)?.pageCount == 3
    }

    private static func columns(_ c: AppShellTests.Checker, _ tmp: URL) {
        let dir = tmp.appendingPathComponent("columns")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdf = dir.appendingPathComponent("columns.pdf")
        guard makeColumnsPDF(pdf) else { c.check("make the columns PDF", false); return }
        let txt = read(try? pdfToText(pdf, options: [:]) { _ in })
        let lines = txt.components(separatedBy: "\n")
        c.check("running header and page footers left out", !txt.contains("Confidential") && !txt.contains("of 3"))
        c.check("a sentence cut by a page break is joined up", txt.contains("ends on the next page, where the story continues as planned."))
        let left = lines.first { $0.hasPrefix("LEFT one.") } ?? ""
        let right = lines.first { $0.hasPrefix("RIGHT one.") } ?? ""
        c.check("each column is one reflowed paragraph", left.hasSuffix("Left column ends here.") && right.hasSuffix("Right column ends here."),
                "left: …\(left.suffix(40))")
        c.check("reading order: page 1, page 2, left column, right column, page 3",
                ["Opening Hours", "continues as planned", "Two Columns", "LEFT one", "RIGHT one", "Closing"]
                .map { s in txt.range(of: s)?.lowerBound.utf16Offset(in: txt) ?? -1 }.isIncreasing)
        c.check("paragraphs are set apart by blank lines", txt.contains("Left column ends here.\n\nRIGHT one."))
        let md = read((try? pdfToMarkdown(pdf, options: [:]) { _ in })?.first)
        c.check("Markdown headings by size", md.contains("## Opening Hours") && md.contains("## Two Columns") && md.contains("## Closing"))
        // Extract Text keeps the raw lines: that's the difference between the two TXT petals.
        let raw = read(try? PDFTools.extractText(pdf, kind: .pdf) { _ in })
        c.check("unlike Extract Text, which keeps raw lines, headers and footers",
                raw.contains("Confidential") && !raw.contains("ends on the next page") && !raw.components(separatedBy: "\n").contains { $0.hasPrefix("LEFT one.") && $0.hasSuffix("ends here.") })
    }
}

// MARK: - Review regressions

extension TextDocuments {
    /// One page of text set by Core Text in `rect` (paragraphs separated by a line break only, no space between).
    static func makeProsePDF(_ url: URL, paragraphs: [String], font: NSFont, rect: CGRect, picture: Bool = false) -> Bool {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        ctx.beginPDFPage(nil)
        let text = NSAttributedString(string: paragraphs.joined(separator: "\n"), attributes: [.font: font, .foregroundColor: NSColor.black])
        let setter = CTFramesetterCreateWithAttributedString(text)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil), ctx)
        if picture, let bitmap = CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            bitmap.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
            bitmap.setFillColor(CGColor(srgbRed: 0.9, green: 0.6, blue: 0.1, alpha: 1)); bitmap.fill(CGRect(x: 20, y: 20, width: 80, height: 60))
            if let image = bitmap.makeImage() { ctx.draw(image, in: CGRect(x: 72, y: 100, width: 200, height: 120)) }
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(url: url)?.pageCount == 1
    }

    private static func paragraphs(_ txt: String) -> [String] {
        txt.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Hebrew paragraphs start at the right and leave their short last line at the left: the line that ends a
    /// paragraph mustn't be taken for an indented first line of the next one (in TXT, Markdown and DOCX alike).
    static func rightToLeft(_ c: AppShellTests.Checker, _ tmp: URL) {
        let dir = tmp.appendingPathComponent("rtl")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdf = dir.appendingPathComponent("hebrew.pdf")
        let he = ["פסקה ראשונה: הוועדה התכנסה ביום שלישי כדי לדון בתוכנית לאגף החדש של הספרייה. חברי הוועדה הסכימו שחדר הקריאה יפנה אל הגן, ושפינת הילדים צריכה יותר אור. התקציב אושר עם שינוי אחד בלבד.",
                  "פסקה שנייה: בית הקפה יעבור לשלב השני של הפרויקט, אחרי שהקירות החיצוניים ייבנו. הקבלן ביקש עוד שלושה שבועות כדי להשלים את העבודה על הגג ועל החלונות הגדולים בצד המערבי.",
                  "פסקה שלישית: הישיבה הבאה תתקיים בחודש הבא באולם הגדול, וכל התושבים מוזמנים להשתתף ולהביע את דעתם על התוכנית."]
        guard let font = NSFont(name: "Arial", size: 13) ?? NSFont(name: "Helvetica", size: 13),
              makeProsePDF(pdf, paragraphs: he, font: font, rect: CGRect(x: 72, y: 72, width: 468, height: 648)) else {
            c.check("make the Hebrew PDF", false); return
        }
        let txt = paragraphs(read(try? pdfToText(pdf, options: [:]) { _ in }))
        c.check("RTL: three Hebrew paragraphs come out as three, each whole",
                txt.count == 3 && zip(txt, he).allSatisfy { $0 == $1 }, txt.map { String($0.prefix(14)) + "…" + String($0.suffix(14)) }.joined(separator: " | "))
        let md = paragraphs(read((try? pdfToMarkdown(pdf, options: [:]) { _ in })?.first))
        c.check("RTL: the same in Markdown", md.count == 3 && zip(md, he).allSatisfy { $0 == $1 })
        let doc = try? RichPDFReader.document(pdf, options: pdfReaderOptions([:], images: true, pageBreaks: true)).0
        let docx = doc?.blocks.compactMap { b -> String? in if case .paragraph(let p) = b { return p.text } else { return nil } } ?? []
        c.check("RTL: and in what PDF → DOCX writes", docx.count == 3 && docx.first?.hasSuffix("עם שינוי אחד בלבד.") == true, "\(docx.count) paragraphs")
    }

    /// A narrow column set ragged right: a line that ends early only because the next word is long still belongs
    /// to its paragraph.
    static func raggedColumn(_ c: AppShellTests.Checker, _ tmp: URL) {
        let dir = tmp.appendingPathComponent("ragged")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdf = dir.appendingPathComponent("ragged.pdf")
        let sentence = "The committee met on Tuesday to review the plan for the new library wing. Members agreed that the reading room should face the garden. "
        // Set this way, the third line of each paragraph ends "…face the garden. The", 40 pt short of the column,
        // because "committee" doesn't fit after it.
        let one = (0..<4).map { "Paragraph \($0 + 1) on page 1. " + String(repeating: sentence, count: 2 + $0 % 2) }
        let paras = one + one
        guard let font = NSFont(name: "Times New Roman", size: 10) ?? NSFont(name: "Times", size: 10),
              makeProsePDF(pdf, paragraphs: paras, font: font, rect: CGRect(x: 54, y: 72, width: 240, height: 640)) else {
            c.check("make the ragged-right PDF", false); return
        }
        let txt = paragraphs(read(try? pdfToText(pdf, options: [:]) { _ in }))
        c.check("ragged right: eight paragraphs, none split where a long word wrapped",
                txt == paras.map { $0.trimmingCharacters(in: .whitespaces) },
                "\(txt.count) paragraphs: " + txt.prefix(4).map { "…" + String($0.suffix(24)) }.joined(separator: " | "))
    }

    /// A PDF of empty pages isn't called pictures (nor told to become PNG or JPG).
    static func blankPages(_ c: AppShellTests.Checker, _ tmp: URL) {
        let url = tmp.appendingPathComponent("blank.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { c.check("make the blank PDF", false); return }
        for _ in 0..<2 { ctx.beginPDFPage(nil); ctx.endPDFPage() }
        ctx.closePDF()
        for ocr in ["true", "false"] {
            var message = ""
            let t0 = Date()
            do { _ = try pdfToText(url, options: ["ocr": ocr]) { _ in } } catch { message = error.localizedDescription }
            c.check("blank pages (ocr=\(ocr)): “its pages are blank”, at once and with nothing written",
                    message == "No text found in blank.pdf: its pages are blank." && Date().timeIntervalSince(t0) < 5
                    && !FileManager.default.fileExists(atPath: tmp.appendingPathComponent("blank.txt").path), message)
        }
        c.check("a photo still gets the advice to keep it as a picture", !isBlank(tmp.appendingPathComponent("failed/pictured.pdf")))
    }

    /// A Markdown conversion that can't write its pictures leaves no half-filled "<name> images" folder behind.
    static func failedWrite(_ c: AppShellTests.Checker, _ tmp: URL) {
        let dir = tmp.appendingPathComponent("failed")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdf = dir.appendingPathComponent("pictured.pdf")
        guard makeProsePDF(pdf, paragraphs: ["A page with a picture under its text, long enough to be read as a paragraph of writing."],
                           font: NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12),
                           rect: CGRect(x: 72, y: 400, width: 468, height: 300), picture: true) else {
            c.check("make the pictured PDF", false); return
        }
        let ok = (try? pdfToMarkdown(pdf, options: [:]) { _ in }) ?? []
        c.check("a picture goes into “pictured images”", ok.map(\.lastPathComponent) == ["pictured.md", "pictured images"])
        for u in ok { try? FileManager.default.removeItem(at: u) }
        // A folder the pictures can't be written into (it's made read-only by the umask), as on a full disk.
        let old = umask(0o277)
        var message = ""
        do { _ = try pdfToMarkdown(pdf, options: [:]) { _ in } } catch { message = error.localizedDescription }
        umask(old)
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        c.check("when a picture can't be written, the conversion fails and leaves no Markdown and no images folder",
                !message.isEmpty && left == ["pictured.pdf"], "left: \(left.joined(separator: ", ")); “\(message)”")
        for name in left where name != "pictured.pdf" {
            let u = dir.appendingPathComponent(name)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
            try? FileManager.default.removeItem(at: u)
        }
    }
}

private extension Array where Element == Int {
    /// Every value found (not -1) and strictly increasing.
    var isIncreasing: Bool { !contains(-1) && zip(self, dropFirst()).allSatisfy { $0 < $1 } }
}
#endif
