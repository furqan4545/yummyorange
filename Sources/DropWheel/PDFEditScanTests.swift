#if DEBUG
import AppKit
import CoreText
import PDFKit

/// Scanned pages with OCR text: edits cover the old words in the picture and draw the new ones (part of
/// `--selftest pdf-edit`).
extension PDFEditTests {
    /// A page that is one grey picture with three lines of serif text drawn into it, and invisible OCR text
    /// (Helvetica, 3 Tr) over each line, the way a scanner's OCR writes it.
    static func scannedTextPDF() -> Data {
        let w = 612, h = 792
        var px = [UInt8](repeating: 0, count: w * h)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 0.96, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let font = CTFontCreateWithName("Times-Roman" as CFString, 24, nil)
            for (t, y) in scanLines {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: t, attributes: [.font: font as NSFont,
                                                                                                       .foregroundColor: NSColor.black]))
                ctx.textPosition = CGPoint(x: 72, y: CGFloat(y))
                CTLineDraw(line, ctx)
            }
        }
        var ocr = ""
        for (t, y) in scanLines {
            // OCR stretches each line to the width it measured (Tz), as Tesseract does.
            let times = PDFScanText.inkBounds(t, CTFontCreateWithName("Times-Roman" as CFString, 24, nil)).width
            let helv = PDFScanText.inkBounds(t, CTFontCreateWithName("Helvetica" as CFString, 24, nil)).width
            ocr += "BT 3 Tr /F1 24 Tf \(PDFNumber.format(Double(100 * times / helv))) Tz 72 \(y) Td (\(t)) Tj ET\n"
        }
        var g = Gen()
        g.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
        g.add(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>")
        g.add(3, "<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >> >> /Contents 4 0 R >>")
        g.stream(4, "q 612 0 0 792 0 0 cm /Im1 Do Q\n" + ocr)
        g.add(5, helvetica)
        g.stream(6, "/Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace /DeviceGray /BitsPerComponent 8", bytes: px, flate: true)
        return g.classic()
    }

    /// White italic text on a navy band (a section cover), as a scanned picture with OCR text over it.
    static func darkBandPDF() -> Data {
        let w = 612, h = 792
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.96, blue: 0.94, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(srgbRed: 0.06, green: 0.15, blue: 0.3, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 480, width: w, height: 312))
            // No font smoothing: it thickens light-on-dark text, which a scan doesn't.
            ctx.setShouldSmoothFonts(false)
            ctx.setAllowsFontSmoothing(false)
            let italic = CTFontCreateWithName("Times-Italic" as CFString, 22, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: darkBandText, attributes: [.font: italic as NSFont,
                                                                                                              .foregroundColor: NSColor.white]))
            ctx.textPosition = CGPoint(x: 72, y: 600)
            CTLineDraw(line, ctx)
        }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { rgb[i * 3] = px[i * 4]; rgb[i * 3 + 1] = px[i * 4 + 1]; rgb[i * 3 + 2] = px[i * 4 + 2] }
        let times = PDFScanText.inkBounds(darkBandText, CTFontCreateWithName("Times-Italic" as CFString, 22, nil)).width
        let helv = PDFScanText.inkBounds(darkBandText, CTFontCreateWithName("Helvetica" as CFString, 22, nil)).width
        var g = Gen()
        g.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
        g.add(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>")
        g.add(3, "<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >> >> /Contents 4 0 R >>")
        g.stream(4, "q 612 0 0 792 0 0 cm /Im1 Do Q\nBT 3 Tr /F1 22 Tf \(PDFNumber.format(Double(100 * times / helv))) Tz 72 600 Td (\(darkBandText)) Tj ET\n")
        g.add(5, helvetica)
        g.stream(6, "/Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace /DeviceRGB /BitsPerComponent 8", bytes: rgb, flate: true)
        return g.classic()
    }

    static let darkBandText = "complete only when its exit rule is signed"

    static let scanLines: [(String, Int)] = [("Scanned words stay here", 600), ("Second line of text", 540), ("Third row is untouched", 480)]

    /// The page's pixels in a page-space rectangle (100 dpi), for before/after comparisons.
    static func pixels(_ data: Data, page: Int, in rect: CGRect) -> [UInt8] {
        guard let p = PDFDocument(data: data)?.page(at: page)?.pageRef, let img = PDFEditVerify.render(p, dpi: 100) else { return [] }
        var out: [UInt8] = []
        let x0 = Int((rect.minX - img.origin.x) * img.scale), x1 = Int((rect.maxX - img.origin.x) * img.scale)
        let y0 = img.height - Int((rect.maxY - img.origin.y) * img.scale), y1 = img.height - Int((rect.minY - img.origin.y) * img.scale)
        for row in max(0, y0)..<min(img.height, y1) {
            for col in max(0, x0)..<min(img.width, x1) { out.append(img.pixels[(row * img.width + col) * 4]) }
        }
        return out
    }

    static func scannedText(_ c: Checker, _ dir: URL) throws {
        c.section("Scanned text (OCR over a picture)")
        let data = scannedTextPDF()
        let s = try session(data, "scanned-text.pdf", dir)
        guard let a = line(s, "Scanned words"), let b = line(s, "Second line"), let t = line(s, "Third row") else {
            c.check(false, "scan: OCR lines read"); return
        }
        c.check(s.banners(page: 0) == [.ocrOnly], "scan: banner “\(PDFEditBanner.ocrOnly.message)”")
        let look = s.scanLook(a)
        c.check(look != nil, "scan: the picture under an OCR line is read")
        if let look {
            c.check(abs(look.paper[0] - 0.96) < 0.02, "scan: paper colour from the picture (\(look.paper.map { PDFNumber.format($0) }))")
            c.check(look.ink[0] < 0.25, "scan: ink colour from the picture (\(look.ink.map { PDFNumber.format($0) }))")
            c.check(abs(look.origin.y - 600) < 1.5, "scan: baseline from the ink (\(PDFNumber.format(Double(look.origin.y))))")
            c.check(abs(look.style.size - 24) < 2.5, "scan: size from the ink (\(PDFNumber.format(look.style.size)))")
            let serif = ["Times", "Baskerville", "Hoefler", "Palatino", "Georgia", "Caslon", "Charter", "Cochin", "Didot"]
            c.check(serif.contains { look.style.fontName.contains($0) }, "scan: a serif font for serif ink (\(look.style.fontName))")
            c.check(look.wordStarts?.count == 4, "scan: four words found in the ink")
            c.check(s.notes(a) == [.scannedText(font: look.fontDisplayName)], "scan: note “\(PDFLineNote.scannedText(font: look.fontDisplayName).message)”")
            c.check(s.editorFont(a).font.fontName == look.style.fontName, "scan: the inline editor types in the matched font")
        }
        c.check(s.previewDocument(blanking: a) != nil, "scan: preview with the line covered (behind the inline editor)")

        // Replace the end of line 1, delete line 2; line 3 stays.
        try s.setText("Scanned words changed completely", for: a)
        try s.deleteLine(b)
        let out = try s.save()
        let saved = try Data(contentsOf: out)
        c.check(saved.prefix(data.count) == data, "scan: saved incrementally")
        let txt = PDFEditVerify.normalized(text(saved, 0))
        c.check(txt.contains("Scannedwordschangedcompletely"), "scan: the new line reads back whole")
        c.check(!txt.contains("Secondlineoftext") && !txt.contains("Scannedwordsstayhere"), "scan: old wording gone from the text")
        let lb = s.line(a)!.bounds, tb = s.line(t)!.bounds
        // "Scanned words" is kept as it is in the picture; the rest of the line changed.
        let keepRect = CGRect(x: 72, y: lb.minY - 6, width: 120, height: lb.height + 12)
        c.check(pixels(data, page: 0, in: keepRect) == pixels(saved, page: 0, in: keepRect), "scan: unchanged words keep their own pixels")
        let tailRect = CGRect(x: 200, y: lb.minY - 2, width: 120, height: lb.height + 4)
        c.check(pixels(data, page: 0, in: tailRect) != pixels(saved, page: 0, in: tailRect), "scan: changed words are redrawn")
        // The deleted line is paper.
        let bb = s.line(b)!.bounds
        let gone = pixels(saved, page: 0, in: bb.insetBy(dx: 0, dy: 2))
        c.check(!gone.isEmpty && gone.allSatisfy { $0 > 200 }, "scan: a deleted line is covered with paper")
        let untouched = tb.insetBy(dx: -4, dy: -4)
        c.check(pixels(data, page: 0, in: untouched) == pixels(saved, page: 0, in: untouched), "scan: other lines unchanged")
        // Ink under the new words: the gate checks it, and it's dark.
        let ink = pixels(saved, page: 0, in: CGRect(x: 72, y: lb.minY, width: 380, height: lb.height))
        c.check((ink.min() ?? 255) < 80, "scan: new words show")
        // Light text on a dark band: the ink is the light pixels, the font italic, and the old words are covered.
        let dd = darkBandPDF()
        let ds = try session(dd, "dark-band.pdf", dir)
        if let dl = line(ds, "exit rule"), let dlook = ds.scanLook(dl) {
            c.check(dlook.ink.allSatisfy { $0 > 0.8 } && dlook.paper[2] < 0.45, "scan, dark band: light ink on dark paper (ink \(dlook.ink.map { PDFNumber.format($0) }))")
            let traits = NSFont(name: dlook.style.fontName, size: 12).map { NSFontManager.shared.traits(of: $0) } ?? []
            c.check(traits.contains(.italicFontMask) && !traits.contains(.boldFontMask), "scan, dark band: regular italic text gets a regular italic face (\(dlook.style.fontName))")
            c.check(dlook.cover.height > 12 && dlook.cover.width > 300, "scan, dark band: the cover takes in the old words (\(dlook.cover.integral))")
            try ds.setText("complete only when its exit rule is approved", for: dl)
            let o = try Data(contentsOf: try ds.save())
            let b = ds.line(dl)!.bounds
            // Under the changed word the old white ink is gone except where the new white ink is: the band stays dark.
            let m = PDFEditMarkupTests.meanColor(o, page: 0, in: CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height))
            c.check(m.count == 3 && m[2] < 0.55, "scan, dark band: still a dark band with light words after the edit (\(m.map { PDFNumber.format($0) }))")
            c.check(PDFEditVerify.normalized(text(o, 0)).contains("isapproved"), "scan, dark band: the new words read back")
        } else { c.check(false, "scan, dark band: line read") }

        // Undo-friendly: back to the original, the candidate is the original again.
        s.revert(a); s.revert(b)
        c.check(s.edits.isEmpty, "scan: revert")
    }
}
#endif
