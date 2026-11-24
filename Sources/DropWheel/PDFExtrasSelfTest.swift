#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import CoreText
import PDFKit

/// Headless checks for `--selftest pdf-extras` (or `pdf-organizer`, `pdfa`, `pdf-svg`, `pdf-tools`): builds small PDFs in a
/// temporary folder, runs each feature on them and checks the results with PDFKit and XMLParser.
enum PDFExtrasSelfTest {
    static func run(_ parts: [String]) -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-pdfextras-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var lines: [String] = []
        var failed = false
        func check(_ ok: Bool, _ what: String) {
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
            if !ok { failed = true }
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let sample = dir.appendingPathComponent("sample.pdf")
            try makeSample(sample, pages: 3)
            if parts.contains("organizer") {
                try organizer(sample, check); try organizerWindow(sample, dir, check); try organizerLinks(dir, check)
            }
            if parts.contains("pdfa") { try pdfa(sample, check); try pdfaLinksAndLayers(dir, check) }
            if parts.contains("svg") { try svg(sample, check); try svgTextClip(dir, check) }
            if parts.contains("tools") { try tools(dir, check); try mergeAndUnlock(dir, check); try multiPageTIFF(dir, check) }
        } catch {
            check(false, "error: \(error.localizedDescription)")
        }
        return (failed ? "FAIL" : "PASS") + " pdf-extras (\(parts.joined(separator: ", ")))\n" + lines.joined(separator: "\n")
    }

    /// A Letter-size PDF whose pages say "Page N" in Helvetica, with a coloured box.
    static func makeSample(_ url: URL, pages: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: "Self-test", kCGPDFContextAuthor: "YummyOrange"] as CFDictionary) else {
            throw ConversionError.toolFailed("Couldn’t create the sample PDF.")
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
        for n in 1...pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 72, y: 600, width: 200, height: 100))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Page \(n)", attributes: [.font: font]))
            ctx.textPosition = CGPoint(x: 72, y: 500)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private static func pageText(_ doc: PDFDocument, _ i: Int) -> String {
        doc.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func organizer(_ sample: URL, _ check: (Bool, String) -> Void) throws {
        let out = try PDFOrganizer.run([sample], options: ["order": "3,1,2,2", "rotate": "1:90,3:-90"]) { _ in }
        guard let doc = PDFDocument(url: out) else { check(false, "organizer output opens"); return }
        check(out.lastPathComponent == "sample organized.pdf", "organizer names its output \(out.lastPathComponent)")
        check(doc.pageCount == 4, "organizer page count \(doc.pageCount) == 4")
        let texts = (0..<doc.pageCount).map { pageText(doc, $0) }
        check(texts == ["Page 3", "Page 1", "Page 2", "Page 2"], "organizer order \(texts)")
        let rotations = (0..<doc.pageCount).map { doc.page(at: $0)?.rotation ?? -1 }
        check(rotations == [270, 90, 0, 0], "organizer rotations \(rotations)")

        let combined = try PDFOrganizer.run([sample, sample], options: ["order": "6-4"]) { _ in }
        if let d = PDFDocument(url: combined) {
            let t = (0..<d.pageCount).map { pageText(d, $0) }
            check(t == ["Page 3", "Page 2", "Page 1"], "organizer combines two files and reverses 6-4: \(t)")
        }
        for (options, what) in [(["order": "5"], "page out of range"), (["rotate": "1:45"], "rotation of 45°"),
                                (["order": "x"], "non-numeric order")] {
            do {
                _ = try PDFOrganizer.run([sample], options: options) { _ in }
                check(false, "organizer refuses \(what)")
            } catch {
                check(true, "organizer refuses \(what): \(error.localizedDescription)")
            }
        }
        let unchanged = try PDFOrganizer.run([sample], options: [:]) { _ in }
        check(PDFDocument(url: unchanged)?.pageCount == 3, "organizer without options keeps all pages")
    }

    /// Drives the organizer's controller the way its buttons and keys do (no window is shown).
    private static func organizerWindow(_ sample: URL, _ dir: URL, _ check: (Bool, String) -> Void) throws {
        let c = try PDFOrganizerController(files: [sample], synchronous: true)
        c.root.setFrameSize(CGSize(width: 900, height: 620))
        func texts() -> [String] { c.pages.map { $0.page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" } }
        c.select([0]); c.rotateRight()
        check(c.pages[0].turn == 90 && c.selection == [0], "organizer UI: rotate right turns page 1 to 90° and keeps it selected")
        c.rotateLeft(); c.rotateLeft()
        check(c.pages[0].turn == 270, "organizer UI: two rotate lefts give 270° (\(c.pages[0].turn))")
        c.select([1, 2]); c.duplicateSelected()
        check(texts() == ["Page 1", "Page 2", "Page 2", "Page 3", "Page 3"] && c.selection == [2, 4],
              "organizer UI: duplicate puts copies after each page \(texts()) and selects them \(c.selection)")
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                      context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}",
                                      isARepeat: false, keyCode: 51)!
        c.collection.keyDown(with: delete)
        check(texts() == ["Page 1", "Page 2", "Page 3"], "organizer UI: ⌫ deletes the selected pages \(texts())")
        c.move([2], to: 0)
        check(texts() == ["Page 3", "Page 1", "Page 2"] && c.selection == [0], "organizer UI: drag page 3 to the front \(texts())")
        c.move([0, 1], to: 3)
        check(texts() == ["Page 2", "Page 3", "Page 1"], "organizer UI: multi-page drag to the end \(texts())")
        c.undoChange()
        check(texts() == ["Page 3", "Page 1", "Page 2"], "organizer UI: undo restores the previous order")
        c.redoChange()
        check(texts() == ["Page 2", "Page 3", "Page 1"], "organizer UI: redo")
        for _ in 0..<10 { c.undoChange() }
        check(texts() == ["Page 1", "Page 2", "Page 3"] && c.pages.allSatisfy { $0.turn == 0 }, "organizer UI: undo all the way back")
        let image = dir.appendingPathComponent("dot.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: image)
        c.insert([image, sample], at: 1)
        check(c.pages.count == 7 && c.selection == Array(1...4), "organizer UI: insert an image and a PDF after page 1 (\(c.pages.count) pages)")
        // Dropping files from Finder onto the grid, through the same delegate calls a real drop makes.
        let wired = ["collectionView:canDragItemsAtIndexPaths:withEvent:", "collectionView:pasteboardWriterForItemAtIndexPath:",
                     "collectionView:validateDrop:proposedIndexPath:dropOperation:", "collectionView:acceptDrop:indexPath:dropOperation:",
                     "collectionView:draggingSession:willBeginAtPoint:forItemsAtIndexPaths:",
                     "collectionView:draggingSession:endedAtPoint:dragOperation:", "collectionView:didSelectItemsAtIndexPaths:"]
        check(wired.allSatisfy { c.responds(to: NSSelectorFromString($0)) }, "organizer UI: drag-and-drop delegate methods are wired")
        let board = NSPasteboard(name: NSPasteboard.Name("dropwheel-selftest-\(UUID().uuidString)"))
        board.clearContents()
        board.setString(sample.absoluteString, forType: .fileURL)
        let drop = FakeDrop(board)
        var proposed = NSIndexPath(forItem: 7, inSection: 0)
        var operation = NSCollectionView.DropOperation.on
        let verdict = c.collectionView(c.collection, validateDrop: drop, proposedIndexPath: &proposed, dropOperation: &operation)
        check(verdict == .copy && operation == .before, "organizer UI: a file drop is accepted as a copy between pages")
        _ = c.collectionView(c.collection, acceptDrop: drop, indexPath: IndexPath(item: 7, section: 0), dropOperation: .before)
        check(c.pages.count == 10, "organizer UI: dropping a 3-page PDF at the end adds 3 pages (\(c.pages.count))")
        c.undoChange()
        board.releaseGlobally()
        c.select([0]); c.rotateRight()
        c.setThumbnailSide(300)
        check(c.flow.itemSize.width == 320, "organizer UI: size slider sets thumbnails to 300 pt")
        let out = try c.saveCopy()
        let doc = PDFDocument(url: out)
        check(doc?.pageCount == 7 && doc?.page(at: 0)?.rotation == 90 && doc?.page(at: 1)?.bounds(for: .mediaBox).width ?? 0 > 800,
              "organizer UI: Save writes \(out.lastPathComponent) with 7 pages, page 1 at 90°, the image as a landscape page")
        c.select(Set(0..<7)); c.deleteSelected()
        check(c.pages.isEmpty, "organizer UI: deleting every page leaves an empty grid")
        do { _ = try c.saveCopy(); check(false, "organizer UI: refuses to save no pages") }
        catch { check(true, "organizer UI: refuses to save no pages: \(error.localizedDescription)") }
    }

    private static func pdfa(_ sample: URL, _ check: (Bool, String) -> Void) throws {
        let out = try PDFArchive.makePDFA(sample) { _ in }
        guard let doc = PDFDocument(url: out), let source = PDFDocument(url: sample) else { check(false, "PDF/A output opens"); return }
        let report = try PDFArchive.verify(out, against: source)
        check(out.lastPathComponent == "sample PDFA.pdf", "PDF/A names its output \(out.lastPathComponent)")
        check(report.part == "2", "PDF/A part \(report.part ?? "none")")
        check(report.conformance != nil, "PDF/A conformance \(report.conformance ?? "none") (\(report.level))")
        check(report.unembeddedFonts.isEmpty && report.fonts > 0, "PDF/A fonts embedded (\(report.fonts) checked)")
        check(!report.encrypted, "PDF/A not encrypted")
        check(pageText(doc, 1) == "Page 2", "PDF/A text kept: \(pageText(doc, 1))")
        check((doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) == "Self-test", "PDF/A keeps the title")
    }

    private static func svg(_ sample: URL, _ check: (Bool, String) -> Void) throws {
        let outs = try PDFSVG.convert(sample, options: [:]) { _ in }
        check(outs.map(\.lastPathComponent) == ["sample page 1.svg", "sample page 2.svg", "sample page 3.svg"],
              "SVG names \(outs.map(\.lastPathComponent))")
        for (i, url) in outs.enumerated() {
            guard let data = try? Data(contentsOf: url) else { check(false, "SVG \(i + 1) readable"); continue }
            let parser = XMLParser(data: data)
            let ok = parser.parse()
            check(ok, "SVG \(i + 1) is well-formed XML\(ok ? "" : ": \(parser.parserError?.localizedDescription ?? "")")")
            let text = String(decoding: data, as: UTF8.self)
            check(text.contains(">Page \(i + 1)</text>"), "SVG \(i + 1) has selectable text “Page \(i + 1)”")
            check(text.contains("#3366E6"), "SVG \(i + 1) has the blue box")
        }
        let one = try PDFSVG.convert(sample, options: ["pages": "2"]) { _ in }
        check(one.map(\.lastPathComponent) == ["sample page 2 2.svg"] || one.count == 1, "SVG pages=2 gives one file")
    }
}

// MARK: - Links, bookmarks, annotations, layers, text clips, sideways text

extension PDFExtrasSelfTest {
    /// A PDF from raw objects (object 1 is the catalog), for content Core Graphics can't write.
    static func rawPDF(_ objects: [String], to url: URL) throws {
        var b = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(b.count)
            b.append(Data("\(i + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let start = b.count
        var tail = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { tail += String(format: "%010d 00000 n \n", o) }
        tail += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
        b.append(Data(tail.utf8))
        try b.write(to: url)
    }

    static func stream(_ content: String) -> String { "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream" }

    /// Three pages; page 1 links to page 3, and there is a bookmark per page.
    static func makeLinked(_ url: URL, _ dir: URL) throws {
        let base = dir.appendingPathComponent("linked-base.pdf")
        try makeSample(base, pages: 3)
        // Built in a new document: PDFKit doesn't write links or bookmarks added to a document it opened.
        guard let opened = PDFDocument(url: base) else { throw ConversionError.toolFailed("Couldn’t open the linked sample.") }
        let doc = PDFDocument()
        for i in 0..<opened.pageCount { if let copy = opened.page(at: i)?.copy() as? PDFPage { doc.insert(copy, at: doc.pageCount) } }
        guard let first = doc.page(at: 0), let third = doc.page(at: 2) else {
            throw ConversionError.toolFailed("Couldn’t build the linked sample.")
        }
        let link = PDFAnnotation(bounds: CGRect(x: 72, y: 72, width: 120, height: 20), forType: .link, withProperties: nil)
        link.destination = PDFDestination(page: third, at: CGPoint(x: 0, y: 300))
        first.addAnnotation(link)
        let root = PDFOutline()
        for i in 0..<3 {
            guard let page = doc.page(at: i) else { continue }
            let item = PDFOutline()
            item.label = "Chapter \(i + 1)"
            item.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 792))
            root.insertChild(item, at: i)
        }
        doc.outlineRoot = root
        guard doc.write(to: url) else { throw ConversionError.toolFailed("Couldn’t write the linked sample.") }
    }

    /// Page numbers (1-based) of each page's internal links, and the bookmarks as "label→page".
    static func links(_ url: URL) -> (links: [[Int]], outline: [String]) {
        guard let doc = PDFDocument(url: url) else { return ([], []) }
        let links = (0..<doc.pageCount).map { i -> [Int] in
            (doc.page(at: i)?.annotations ?? []).compactMap { a in
                guard a.type == "Link", let page = (a.destination ?? (a.action as? PDFActionGoTo)?.destination)?.page else { return nil }
                return doc.index(for: page) + 1
            }
        }
        var outline: [String] = []
        if let root = doc.outlineRoot {
            for k in 0..<root.numberOfChildren {
                guard let item = root.child(at: k) else { continue }
                let page = item.destination?.page.map { doc.index(for: $0) + 1 } ?? 0
                outline.append("\(item.label ?? "")→\(page)")
            }
        }
        return (links, outline)
    }

    static func organizerLinks(_ dir: URL, _ check: (Bool, String) -> Void) throws {
        let linked = dir.appendingPathComponent("linked.pdf")
        try makeLinked(linked, dir)
        let same = links(try PDFOrganizer.run([linked], options: [:]) { _ in })
        check(same.links == [[3], [], []], "organizer keeps the link on page 1 pointing at page 3: \(same.links)")
        check(same.outline == ["Chapter 1→1", "Chapter 2→2", "Chapter 3→3"], "organizer keeps the bookmarks: \(same.outline)")
        let moved = links(try PDFOrganizer.run([linked], options: ["order": "3,1"]) { _ in })
        check(moved.links == [[], [1]], "organizer moves the link with its target page (order 3,1): \(moved.links)")
        check(moved.outline == ["Chapter 1→2", "Chapter 3→1"], "organizer drops the deleted page's bookmark, moves the rest: \(moved.outline)")
        let cut = links(try PDFOrganizer.run([linked], options: ["order": "1,2"]) { _ in })
        check(cut.links == [[], []], "organizer removes a link to a deleted page: \(cut.links)")
        let clean = links(try PDFTools.stripMetadata(linked))
        check(clean.links == [[3], [], []] && clean.outline.count == 3, "Strip Metadata keeps links and bookmarks: \(clean.links) \(clean.outline)")
    }

    static func pdfaLinksAndLayers(_ dir: URL, _ check: (Bool, String) -> Void) throws {
        let linked = dir.appendingPathComponent("linked-pdfa.pdf")
        try makeLinked(linked, dir)
        let out = try PDFArchive.makePDFA(linked) { _ in }
        if let source = PDFDocument(url: linked) {
            let report = try PDFArchive.verify(out, against: source)
            check(report.annotations == 1, "PDF/A link carries the Print flag (\(report.annotations) annotation checked)")
        }
        check(links(out).links == [[3], [], []], "PDF/A link still goes to page 3: \(links(out).links)")

        let layered = dir.appendingPathComponent("layers.pdf")
        try rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [6 0 R 7 0 R] /D << /ON [6 0 R] /OFF [7 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /Properties << /OC1 6 0 R /OC2 7 0 R >> >> >>",
            stream("/OC /OC1 BDC BT /F1 20 Tf 20 200 Td (Visible layer) Tj ET EMC\n/OC /OC2 BDC BT /F1 20 Tf 20 100 Td (Hidden layer) Tj ET EMC"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /OCG /Name (On) >>",
            "<< /Type /OCG /Name (Off) >>",
        ], to: layered)
        do {
            let copy = try PDFArchive.makePDFA(layered) { _ in }
            let text = PDFDocument(url: copy).map { pageText($0, 0) } ?? ""
            check(text == "Visible layer", "PDF/A of a file with a hidden layer keeps what's shown: “\(text)”")
        } catch {
            check(false, "PDF/A of a file with a hidden layer: \(error.localizedDescription)")
        }
    }

    static func svgTextClip(_ dir: URL, _ check: (Bool, String) -> Void) throws {
        let url = dir.appendingPathComponent("textclip.pdf")
        try rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /Shading << /Sh1 6 0 R >> >> >>",
            stream("BT /F1 14 Tf 72 600 Td (Body) Tj ET\nq BT /F1 60 Tf 7 Tr 72 680 Td (GRADIENT) Tj ET /Sh1 sh Q\nBT /F1 14 Tf 72 560 Td (More) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>",
            "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [72 0 400 0] /Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >> /Extend [true true] >>",
        ], to: url)
        let svg = try PDFSVG.convert(url, options: [:]) { _ in }.first.map { String(decoding: (try? Data(contentsOf: $0)) ?? Data(), as: UTF8.self) } ?? ""
        let clip = svg.range(of: "<clipPath[^>]*>\\s*<text[^>]*>GRADIENT</text>", options: .regularExpression) != nil
        let clipped = svg.range(of: "<g clip-path=\"url\\(#c[0-9]+\\)\">\\s*<path [^>]*fill=\"url\\(#g", options: .regularExpression) != nil
        check(clip && clipped, "SVG: text in clip mode (7 Tr) clips the shading that follows (clip \(clip), shading inside \(clipped))")
    }

    static func tools(_ dir: URL, _ check: (Bool, String) -> Void) throws {
        // Annotations drawn into page images, in the right place on a rotated page with an offset crop box.
        let annotated = dir.appendingPathComponent("annotated.pdf")
        var media = CGRect(x: 100, y: 50, width: 612, height: 792)
        var crop = CGRect(x: 120, y: 70, width: 480, height: 730)
        guard let ctx = CGContext(annotated as CFURL, mediaBox: &media, nil) else { throw ConversionError.toolFailed("PDF context") }
        ctx.beginPDFPage([kCGPDFContextMediaBox: withUnsafeBytes(of: &media) { Data($0) },
                          kCGPDFContextCropBox: withUnsafeBytes(of: &crop) { Data($0) }] as CFDictionary)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 150, y: 100, width: 50, height: 50))
        ctx.endPDFPage()
        ctx.closePDF()
        guard let doc = PDFDocument(url: annotated), let page = doc.page(at: 0) else { throw ConversionError.toolFailed("annotated sample") }
        page.rotation = 90
        let square = PDFAnnotation(bounds: CGRect(x: 300, y: 500, width: 120, height: 80), forType: .square, withProperties: nil)
        square.interiorColor = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
        square.color = .red
        page.addAnnotation(square)
        guard doc.write(to: annotated), let reread = PDFDocument(url: annotated), let p = reread.page(at: 0) else {
            throw ConversionError.toolFailed("annotated sample")
        }
        // Where PDFKit itself draws the square: 730 × 480 pt page, y from the top.
        let expected = CGRect(x: 430, y: 180, width: 80, height: 120)
        func yellowBox(_ image: CGImage?) -> CGRect {
            guard let image, let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                               bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let data = c.data else { return .null }
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let px = data.assumingMemoryBound(to: UInt8.self)
            var box = CGRect.null
            for y in 0..<image.height { for x in 0..<image.width {
                let q = px + (y * image.width + x) * 4
                if q[0] > 200 && q[1] > 200 && q[2] < 80 { box = box.union(CGRect(x: x, y: y, width: 1, height: 1)) }
            } }
            return box
        }
        func near(_ a: CGRect, _ b: CGRect) -> Bool {
            !a.isNull && abs(a.minX - b.minX) < 6 && abs(a.minY - b.minY) < 6 && abs(a.maxX - b.maxX) < 6 && abs(a.maxY - b.maxY) < 6
        }
        let drawn = yellowBox(PDFTools.render(p, dpi: 72))
        check(near(drawn, expected), "page images include annotations where PDFKit shows them: \(drawn) vs \(expected)")
        check(yellowBox(PDFTools.render(p.pageRef!, dpi: 72)).isNull, "Core Graphics alone leaves the annotation out (the reason for the PDFKit pass)")
        let archived = try PDFArchive.makePDFA(annotated) { _ in }
        let flattened = PDFDocument(url: archived)?.page(at: 0).flatMap { PDFTools.render($0, dpi: 72) }
        check(near(yellowBox(flattened), expected), "PDF/A flattens annotations in the same place: \(yellowBox(flattened))")

        // Extract Text on a sideways page keeps whole lines and spaces.
        let sideways = dir.appendingPathComponent("sideways.pdf")
        try rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate 90 /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            stream("BT /F1 18 Tf 0 1 -1 0 100 72 Tm (Landscape heading upright) Tj ET\nBT /F1 14 Tf 0 1 -1 0 130 72 Tm (Second row of landscape text) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ], to: sideways)
        let txt = try PDFTools.extractText(sideways, kind: .pdf) { _ in }
        let lines = (try? String(contentsOf: txt, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        check(lines.prefix(2) == ["Landscape heading upright", "Second row of landscape text"], "Extract Text reads sideways lines whole: \(lines.prefix(3))")
    }
}

// MARK: - Merge, Remove Password, multi-page TIFFs

extension PDFExtrasSelfTest {
    /// Every bookmark as "label→page", children indented by two spaces per level.
    static func outlineTree(_ url: URL) -> [String] {
        guard let doc = PDFDocument(url: url), let root = doc.outlineRoot else { return [] }
        var out: [String] = []
        func walk(_ item: PDFOutline, _ depth: Int) {
            for k in 0..<item.numberOfChildren {
                guard let child = item.child(at: k) else { continue }
                let dest = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                let page = dest?.page.map { doc.index(for: $0) + 1 } ?? 0
                out.append(String(repeating: "  ", count: depth) + "\(child.label ?? "")→\(page)")
                walk(child, depth + 1)
            }
        }
        walk(root, 0)
        return out
    }

    static func mergeAndUnlock(_ dir: URL, _ check: (Bool, String) -> Void) throws {
        let folder = dir.appendingPathComponent("merge", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let linked = folder.appendingPathComponent("linked.pdf")
        try makeLinked(linked, folder)
        let plain = folder.appendingPathComponent("plain.pdf")
        try makeSample(plain, pages: 2)

        let merged = try PDFTools.combine([linked, plain, linked]) { _ in }
        let m = links(merged)
        check(m.links == [[3], [], [], [], [], [8], [], []],
              "Merge PDF keeps each file's links on its own pages: \(m.links)")
        let tree = outlineTree(merged)
        let expected = ["linked→1", "  Chapter 1→1", "  Chapter 2→2", "  Chapter 3→3", "Self-test→4",
                        "linked→6", "  Chapter 1→6", "  Chapter 2→7", "  Chapter 3→8"]
        check(tree == expected, "Merge PDF puts each file's bookmarks under the file's name: \(tree)")
        let noBookmarks = try PDFTools.combine([plain, plain]) { _ in }
        check(PDFDocument(url: noBookmarks)?.outlineRoot == nil && PDFDocument(url: noBookmarks)?.pageCount == 4,
              "Merge PDF of files without bookmarks adds none")

        let locked = try PDFTools.protect(linked, password: "selftest")
        check(PDFDocument(url: locked)?.isLocked == true, "Protect locks the linked sample")
        let unlocked = try PDFTools.unlock(locked, password: "selftest")
        let u = links(unlocked)
        check(PDFDocument(url: unlocked)?.isEncrypted == false, "Remove Password writes an unencrypted copy")
        check(u.links == [[3], [], []] && u.outline == ["Chapter 1→1", "Chapter 2→2", "Chapter 3→3"],
              "Remove Password keeps the link to page 3 and the bookmarks: \(u.links) \(u.outline)")
    }

    /// Big black words on a 1200 × 300 white image, shown upright with the EXIF `orientation` (6: the pixels are
    /// stored turned a quarter left, 300 × 1200, so a viewer turns them right).
    static func wordsImage(_ text: String, orientation: Int = 1) -> CGImage? {
        let w = 1200, h = 300
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 80, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]))
        ctx.textPosition = CGPoint(x: 40, y: 110)
        CTLineDraw(line, ctx)
        guard let upright = ctx.makeImage() else { return nil }
        guard orientation == 6 else { return upright }
        guard let turned = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        turned.translateBy(x: CGFloat(h), y: 0)
        turned.rotate(by: .pi / 2)
        turned.draw(upright, in: CGRect(x: 0, y: 0, width: w, height: h))
        return turned.makeImage()
    }

    static func multiPageTIFF(_ dir: URL, _ check: (Bool, String) -> Void) throws {
        let folder = dir.appendingPathComponent("tiff", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scan = folder.appendingPathComponent("scan.tif")
        let pages: [(String, Int)] = [("FIRST PAGE ALPHA", 1), ("SECOND PAGE BRAVO", 6)]
        guard let dest = CGImageDestinationCreateWithURL(scan as CFURL, "public.tiff" as CFString, pages.count, nil) else {
            throw ConversionError.toolFailed("TIFF writer")
        }
        for (text, orientation) in pages {
            guard let image = wordsImage(text, orientation: orientation) else { throw ConversionError.toolFailed("TIFF page") }
            CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.toolFailed("TIFF writer") }
        let png = folder.appendingPathComponent("one.png")
        guard let one = wordsImage("THIRD"), let pngDest = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)
        else { throw ConversionError.toolFailed("PNG writer") }
        CGImageDestinationAddImage(pngDest, one, nil)
        _ = CGImageDestinationFinalize(pngDest)

        let made = try PDFTools.combine([scan, png]) { _ in }
        let doc = PDFDocument(url: made)
        let landscape = (0..<(doc?.pageCount ?? 0)).map { i -> Bool in
            let box = doc?.page(at: i)?.bounds(for: .mediaBox) ?? .zero
            return box.width > box.height
        }
        check(doc?.pageCount == 3 && landscape == [true, true, true],
              "Make PDF gives every TIFF page its own page, the turned one upright: \(doc?.pageCount ?? 0) pages, landscape \(landscape)")
        check(PDFDocument(url: made)?.outlineRoot == nil, "Make PDF of images adds no bookmarks")
        let (organized, _) = try PDFOrganizer.load([scan])
        check(organized.map(\.label) == ["scan.tif, page 1", "scan.tif, page 2"], "Organize… loads both TIFF pages: \(organized.map(\.label))")

        let txt = try PDFTools.extractText(scan, kind: .image) { _ in }
        let text = (try? String(contentsOf: txt, encoding: .utf8)) ?? ""
        let parts = text.components(separatedBy: "\u{0C}").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        check(parts == ["FIRST PAGE ALPHA", "SECOND PAGE BRAVO"], "Extract Text reads every page of a multi-page TIFF: \(parts)")
    }
}

/// Just enough of a drag for testing the organizer's drop handling: a pasteboard and no source.
private final class FakeDrop: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(_ board: NSPasteboard) { draggingPasteboard = board }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
#endif
