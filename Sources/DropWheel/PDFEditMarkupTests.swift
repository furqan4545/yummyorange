#if DEBUG
import AppKit
import PDFKit

/// Style (font, bold, italic, size, colour) for existing lines, highlights and pictures (part of `--selftest pdf-edit`).
extension PDFEditTests {
    /// A 60 × 30 PNG: a red square with a transparent border (a stamp with transparency).
    static func stampPNG() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        CGRect(x: 0, y: 0, width: 60, height: 30).fill()
        NSColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1).setFill()
        CGRect(x: 10, y: 5, width: 40, height: 20).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// Mean of the red, green and blue samples in a page-space rectangle (100 dpi).
    static func meanColor(_ data: Data, page: Int, in rect: CGRect) -> [Double] {
        guard let p = PDFDocument(data: data)?.page(at: page)?.pageRef, let img = PDFEditVerify.render(p, dpi: 100) else { return [] }
        var sum = [0.0, 0.0, 0.0], n = 0.0
        let x0 = Int((rect.minX - img.origin.x) * img.scale), x1 = Int((rect.maxX - img.origin.x) * img.scale)
        let y0 = img.height - Int((rect.maxY - img.origin.y) * img.scale), y1 = img.height - Int((rect.minY - img.origin.y) * img.scale)
        for row in max(0, y0)..<min(img.height, y1) {
            for col in max(0, x0)..<min(img.width, x1) {
                let i = (row * img.width + col) * 4
                sum[0] += Double(img.pixels[i]); sum[1] += Double(img.pixels[i + 1]); sum[2] += Double(img.pixels[i + 2]); n += 1
            }
        }
        return n > 0 ? sum.map { $0 / n / 255 } : []
    }

    static func markup(_ c: Checker, _ dir: URL) throws {
        c.section("Style, highlights and pictures")
        let data = classicPDF()
        let s = try session(data, "markup.pdf", dir)
        guard let hello = line(s, "Hello World"), let alpha = line(s, "AlphaBeta") ?? line(s, "Alpha") else {
            c.check(false, "markup: lines read"); return
        }
        // Restyle: bold, red, bigger; the text stays and reads back.
        let skip = ProcessInfo.processInfo.environment["MARKUP_SKIP"] ?? ""
        let base = s.style(of: hello)!
        c.check(base.fontName.contains("Helvetica") && abs(base.size - 24) < 0.1, "style: a line's own font and size (\(base.fontName) \(base.size))")
        let bold = NSFontManager.shared.convert(NSFont(name: "Helvetica", size: 24)!, toHaveTrait: .boldFontMask).fontName
        if !skip.contains("style") { try s.setStyle(PDFTextStyle(fontName: bold, size: 30, red: 0.8, green: 0, blue: 0), for: hello) }
        let info = s.info(hello)!
        c.check(info.isEdited && info.pointSize == 30 && info.fontDescription.contains("Bold"), "style: inspector shows the new style (\(info.fontDescription))")
        try s.setText("Hello Bold World", for: hello)
        if case .styled(_, let t, let st, _)? = s.edits.first(where: { $0.line == hello }) {
            c.check(t == "Hello Bold World" && st.fontName == bold, "style: typing keeps the style")
        } else { c.check(false, "style: typing keeps the style") }
        // Highlight over a line, and a picture with transparency.
        let lb = s.line(alpha)!.bounds
        let hl = skip.contains("hl") ? UUID() : try s.addMark(.highlight(rects: [lb.insetBy(dx: -1, dy: -2)], red: 1, green: 0.9, blue: 0.2), page: 0)
        let stampRect = CGRect(x: 300, y: 300, width: 120, height: 60)
        let pic = skip.contains("pic") ? UUID() : try s.addMark(.image(png: stampPNG(), rect: stampRect), page: 0)
        c.check(s.marks.count == 2, "marks: listed (highlight \(lb.integral), line “\(s.line(alpha)!.text)”)")
        let out = try s.save()
        let saved = try Data(contentsOf: out)
        c.check(saved.prefix(data.count) == data, "markup: saved incrementally, through the gate")
        let txt = PDFEditVerify.normalized(text(saved, 0))
        c.check(txt.contains("HelloBoldWorld") && !txt.contains("HelloWorld"), "style: the restyled line reads back")
        let red = meanColor(saved, page: 0, in: CGRect(x: 72, y: 700, width: 60, height: 18))
        c.check(red.count == 3 && red[0] > red[1] + 0.1, "style: drawn red (\(red.map { PDFNumber.format($0) }))")
        let yellow = meanColor(saved, page: 0, in: CGRect(x: lb.maxX - 6, y: lb.minY - 1, width: 4, height: 2))
        c.check(yellow.count == 3 && yellow[2] < 0.5 && yellow[0] > 0.8, "highlight: yellow over the line (\(yellow.map { PDFNumber.format($0) }))")
        c.check(txt.contains("AlphaBeta"), "highlight: the text under it is still text")
        let inside = meanColor(saved, page: 0, in: CGRect(x: 330, y: 315, width: 60, height: 30))
        let border = meanColor(saved, page: 0, in: CGRect(x: 302, y: 302, width: 10, height: 10))
        c.check(inside.count == 3 && inside[0] > 0.7 && inside[1] < 0.3, "picture: drawn where placed")
        c.check(border.count == 3 && border.allSatisfy { $0 > 0.95 }, "picture: its transparent edge shows the page")
        // The second page shares the first one's resources and content: it doesn't change.
        c.check(pixels(data, page: 1, in: CGRect(x: 0, y: 0, width: 612, height: 792)) == pixels(saved, page: 1, in: CGRect(x: 0, y: 0, width: 612, height: 792)),
                "markup: the page sharing resources is unchanged")
        // Move, then remove.
        try s.updateMark(pic, .image(png: stampPNG(), rect: stampRect.offsetBy(dx: 50, dy: 0)), actionName: "Move Picture")
        c.check(s.marks.first { $0.id == pic }?.kind.bounds.minX == 350, "picture: moved")
        s.removeMark(hl)
        c.check(s.marks.map(\.id) == [pic], "highlight: removed")

        // A highlight on a scan (Multiply keeps the scanned words dark under it).
        let scan = scannedTextPDF()
        let ss = try session(scan, "markup-scan.pdf", dir)
        if let a = line(ss, "Scanned words") {
            let b = ss.line(a)!.bounds
            try ss.addMark(.highlight(rects: [b], red: 1, green: 0.9, blue: 0.2), page: 0)
            let o = try Data(contentsOf: try ss.save())
            let dark = pixels(o, page: 0, in: b).min() ?? 255
            c.check(dark < 90, "highlight on a scan: the words under it stay dark (\(dark))")
            let m = meanColor(o, page: 0, in: b)
            c.check(m.count == 3 && m[2] < m[0] - 0.2, "highlight on a scan: tinted")
        }
    }
}
#endif
