import AppKit
import PDFKit

/// The verification gate. It runs in memory before anything is written, and Save writes nothing when it fails:
/// the original is an exact prefix (incremental saves); our parser, PDFKit and Core Graphics reopen the result;
/// page count, catalog keys, outline and annotation counts are unchanged; the update holds exactly the objects
/// the builder wrote; edited pages rendered at 100 dpi change no pixel outside the old and new text (+2 pt);
/// every new visible glyph has ink; and the new text reads back.
enum PDFEditVerify {
    struct Report {
        var failures: [String] = []
        var pagesCompared = 0
        var glyphsChecked = 0
        var ok: Bool { failures.isEmpty }
    }

    static func check(session: PDFEditSession, build: PDFEditBuild, analysis: PDFEditAnalysis, output: Data, incremental: Bool) throws {
        let r = verify(session: session, build: build, analysis: analysis, output: output, incremental: incremental)
        if let first = r.failures.first {
            throw ConversionError.toolFailed("The edited PDF didn’t pass its final check (\(first)), so nothing was saved.")
        }
    }

    static func verify(session: PDFEditSession, build: PDFEditBuild, analysis: PDFEditAnalysis, output: Data, incremental: Bool) -> Report {
        var r = Report()
        let original = session.originalData
        if incremental && !(output.count > original.count && output.prefix(original.count) == original) {
            r.failures.append("the original bytes aren’t kept")
        }
        guard let parsed = try? PDFObjectFile(output) else { r.failures.append("Edit PDF can’t read the result"); return r }
        if parsed.rebuilt { r.failures.append("the result’s cross-reference data is damaged") }
        if parsed.pages().count != session.pageCount { r.failures.append("the page count changed") }
        guard let doc = PDFDocument(data: output) else { r.failures.append("PDFKit can’t open the result"); return r }
        guard let provider = CGDataProvider(data: output as CFData), let cg = CGPDFDocument(provider) else {
            r.failures.append("Core Graphics can’t open the result"); return r
        }
        let before = session.originalDocument
        if doc.pageCount != before.pageCount || cg.numberOfPages != before.pageCount { r.failures.append("the page count changed") }
        if catalogKeys(before.documentRef) != catalogKeys(cg) { r.failures.append("the document catalog changed") }
        if outlineCount(before.outlineRoot) != outlineCount(doc.outlineRoot) { r.failures.append("the bookmarks changed") }
        for i in 0..<min(doc.pageCount, before.pageCount) where doc.page(at: i)?.annotations.count != before.page(at: i)?.annotations.count {
            r.failures.append("the comments or links on page \(i + 1) changed"); break
        }
        if incremental && !session.file.rebuilt && parsed.newestSectionObjects != build.written {
            r.failures.append("the update holds objects it shouldn’t")
        }
        guard r.failures.isEmpty else { return r }

        // Pixels: edited pages, and pages that use an object the update rewrote.
        var pagesToCompare = build.editedPages
        for p in session.pages where pagesToCompare.count < build.editedPages.count + 20 {
            var refs: Set<Int> = [p.number]
            if case .object(let n) = p.resourcesHome { refs.insert(n) }
            if let f = p.resources["Font"]?.ref?.number { refs.insert(f) }
            refs.formUnion(p.contents)
            if !refs.isDisjoint(with: build.written) { pagesToCompare.insert(p.index) }
        }
        for pi in pagesToCompare.sorted() {
            guard let a = before.page(at: pi)?.pageRef, let b = doc.page(at: pi)?.pageRef else { continue }
            let dirty = (analysis.dirty[pi] ?? []).map { $0.insetBy(dx: -2, dy: -2) }
            let changed = changedPixels(a, b, dpi: 100, outside: dirty)
            r.pagesCompared += 1
            if changed != 0 { r.failures.append("page \(pi + 1) changed outside the edited text (\(changed) pixels)"); break }
        }
        // Ink under every new visible glyph.
        for (pi, rects) in analysis.newGlyphs.sorted(by: { $0.key < $1.key }) where !rects.isEmpty {
            guard let page = doc.page(at: pi)?.pageRef else { continue }
            let missing = glyphsWithoutInk(page, rects)
            r.glyphsChecked += rects.count
            if missing > 0 { r.failures.append("\(missing) new \(missing == 1 ? "character doesn’t" : "characters don’t") show on page \(pi + 1)"); break }
        }
        // The new text reads back.
        for (id, text) in build.expectedText.sorted(by: { $0.key.page * 100000 + $0.key.line < $1.key.page * 100000 + $1.key.line }) {
            let want = normalized(text)
            guard !want.isEmpty else { continue }
            // Text PDFKit couldn't read before (a Type 3 font without ToUnicode, say) isn't expected to read now.
            if let old = session.line(id)?.text, !normalized(before.page(at: id.page)?.string ?? "").contains(normalized(old)) { continue }
            let have = normalized(doc.page(at: id.page)?.string ?? "")
            if !have.contains(want) { r.failures.append("the new text on page \(id.page + 1) doesn’t read back"); break }
        }
        return r
    }

    static func normalized(_ s: String) -> String {
        String(s.precomposedStringWithCompatibilityMapping.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    static func catalogKeys(_ doc: CGPDFDocument?) -> [String] {
        guard let cat = doc?.catalog else { return [] }
        var keys: [String] = []
        CGPDFDictionaryApplyBlock(cat, { k, _, _ in keys.append(String(cString: k)); return true }, nil)
        return keys.sorted()
    }

    static func outlineCount(_ o: PDFOutline?) -> Int {
        guard let o else { return 0 }
        var n = 0
        for i in 0..<o.numberOfChildren { n += 1 + outlineCount(o.child(at: i)) }
        return n
    }

    // MARK: Rendering

    /// The page in unrotated user space (so page-space rectangles map directly), white behind it.
    static func render(_ page: CGPDFPage, dpi: CGFloat, maxSide: CGFloat = 2400) -> (pixels: [UInt8], width: Int, height: Int, scale: CGFloat, origin: CGPoint)? {
        let box = page.getBoxRect(.mediaBox)
        let scale = min(dpi / 72, maxSide / max(box.width, box.height, 1))
        let w = max(1, Int((box.width * scale).rounded(.up))), h = max(1, Int((box.height * scale).rounded(.up)))
        var px = [UInt8](repeating: 255, count: w * h * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
            return true
        }
        return ok ? (px, w, h, scale, box.origin) : nil
    }

    /// Pixels that differ between two renders, ignoring those inside `outside` (page space).
    static func changedPixels(_ a: CGPDFPage, _ b: CGPDFPage, dpi: CGFloat, outside dirty: [CGRect]) -> Int {
        guard let x = render(a, dpi: dpi), let y = render(b, dpi: dpi), x.width == y.width, x.height == y.height else { return -1 }
        var n = 0
        let rowBytes = x.width * 4
        x.pixels.withUnsafeBufferPointer { pa in
            y.pixels.withUnsafeBufferPointer { pb in
                for row in 0..<x.height {
                    let off = row * rowBytes
                    if memcmp(pa.baseAddress! + off, pb.baseAddress! + off, rowBytes) == 0 { continue }
                    for col in 0..<x.width {
                        let i = off + col * 4
                        if pa[i] == pb[i] && pa[i + 1] == pb[i + 1] && pa[i + 2] == pb[i + 2] { continue }
                        let p = CGPoint(x: x.origin.x + (CGFloat(col) + 0.5) / x.scale, y: x.origin.y + (CGFloat(x.height - 1 - row) + 0.5) / x.scale)
                        if dirty.contains(where: { $0.contains(p) }) { continue }
                        n += 1
                    }
                }
            }
        }
        return n
    }

    /// New glyph boxes whose pixels are all one shade (nothing was drawn).
    static func glyphsWithoutInk(_ page: CGPDFPage, _ rects: [CGRect]) -> Int {
        guard let img = render(page, dpi: 288, maxSide: 4000) else { return rects.count }
        var missing = 0
        /// Pixel coordinate, clamped first: a glyph box far off the page must not trap in Int(_:).
        func px(_ v: CGFloat, _ limit: Int, up: Bool) -> Int {
            guard v.isFinite else { return v > 0 ? limit : 0 }
            return Int(min(max((up ? v.rounded(.up) : v.rounded(.down)), -1), CGFloat(limit) + 1))
        }
        for r in rects {
            guard !r.isNull, !r.isInfinite else { missing += 1; continue }
            let x0 = max(0, px((r.minX - img.origin.x) * img.scale, img.width, up: false))
            let x1 = min(img.width, px((r.maxX - img.origin.x) * img.scale, img.width, up: true))
            let y0 = max(0, img.height - px((r.maxY - img.origin.y) * img.scale, img.height, up: true))
            let y1 = min(img.height, img.height - px((r.minY - img.origin.y) * img.scale, img.height, up: false))
            guard x1 > x0, y1 > y0 else { missing += 1; continue }
            var lo = 255, hi = 0
            for row in y0..<y1 {
                for col in x0..<x1 {
                    let i = (row * img.width + col) * 4
                    let l = (Int(img.pixels[i]) * 3 + Int(img.pixels[i + 1]) * 6 + Int(img.pixels[i + 2])) / 10
                    lo = min(lo, l); hi = max(hi, l)
                }
            }
            if hi - lo < 40 { missing += 1 }
        }
        return missing
    }
}
