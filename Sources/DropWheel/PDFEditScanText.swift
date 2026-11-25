import AppKit
import CoreText

/// How a line of recognized (OCR) text looks in the scanned picture under it: where its ink is, the paper and ink
/// colours there, and the installed font, size and baseline that draw it most closely.
///
/// OCR text is invisible (render mode 3): changing it alone changes nothing you can see. For a line like that the
/// builder deletes the invisible text, paints `cover` in the paper colour over the old ink, and draws the new text in
/// `style` at `origin`, so editing a scan works like editing any other line.
struct PDFScanLook: Equatable {
    /// Page space: the old ink plus a little room, kept inside the line's band.
    let cover: CGRect
    /// sRGB 0…1.
    let paper: [Double]
    let ink: [Double]
    /// Font (PostScript name), size and colour for the new text.
    let style: PDFTextStyle
    /// Baseline start of the new text, page space.
    let origin: CGPoint
    /// Width of the old ink, page points (Fit Width squeezes the new text to it).
    let inkWidth: Double
    /// Page x where each word's ink starts, when the picture splits into as many words as the OCR text has
    /// (an edit then redraws only from its first changed word; the words before it keep their own pixels).
    var wordStarts: [CGFloat]? = nil
    /// Page x where the old ink ends.
    var inkRight: CGFloat = 0
    /// The font is a guess from the picture (always: a scan carries no font).
    var fontDisplayName: String { PDFFontMatch.displayName(NSFont(name: style.fontName, size: 12) ?? .systemFont(ofSize: 12)) }
}

enum PDFScanText {
    /// Fonts tried against the picture, regular and bold of each. Those not installed are skipped.
    static let candidateFamilies = [
        "Helvetica", "Helvetica Neue", "Arial", "Verdana", "Avenir Next", "Gill Sans", "Futura", "Optima", "Trebuchet MS",
        "Times New Roman", "Times", "Georgia", "Palatino", "Baskerville", "Hoefler Text", "Iowan Old Style", "Charter",
        "Cochin", "Didot", "Book Antiqua", "Garamond", "EB Garamond", "Cormorant Garamond", "Big Caslon", "Charter",
        "Menlo", "Courier New", "Courier", "Monaco", "SF Mono", "Roboto", "Open Sans", "Lato", "Source Serif Pro",
        "Source Sans Pro", "Inter", "Merriweather", "Calibri", "Cambria",
    ]

    /// True for invisible text drawn over a picture, on a horizontal baseline (in page space).
    static func isScanLine(_ session: PDFEditSession, _ id: PDFLineID) -> Bool {
        guard let l = session.line(id), l.hidden, abs(l.direction.dy) < 0.02, l.direction.dx > 0 else { return false }
        let b = l.bounds
        guard !b.isNull, b.width > 0 else { return false }
        let centre = CGPoint(x: b.midX, y: b.midY)
        return session.content(page: id.page).images.contains { PDFEditCanvasGeometry.contains($0.quad, centre) }
    }

    // MARK: Reading the picture

    private struct Raster {
        var px: [UInt8]
        let w: Int, h: Int
        /// Page space of the raster: x = rect.minX + col / k, y = rect.maxY - row / k.
        let rect: CGRect
        let k: CGFloat
        func lum(_ c: Int, _ r: Int) -> Double {
            let i = (r * w + c) * 4
            return (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255
        }
        func rgb(_ c: Int, _ r: Int) -> [Double] {
            let i = (r * w + c) * 4
            return [Double(px[i]) / 255, Double(px[i + 1]) / 255, Double(px[i + 2]) / 255]
        }
        func col(_ x: CGFloat) -> Int { Int(((x - rect.minX) * k).rounded(.down)) }
        func row(_ y: CGFloat) -> Int { Int(((rect.maxY - y) * k).rounded(.down)) }
        func x(_ c: Int) -> CGFloat { rect.minX + CGFloat(c) / k }
        func y(_ r: Int) -> CGFloat { rect.maxY - CGFloat(r) / k }
    }

    private static func render(_ page: CGPDFPage, _ rect: CGRect, k: CGFloat) -> Raster? {
        let w = max(1, Int((rect.width * k).rounded(.up))), h = max(1, Int((rect.height * k).rounded(.up)))
        guard w * h < 40_000_000 else { return nil }
        var px = [UInt8](repeating: 255, count: w * h * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.scaleBy(x: k, y: k)
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
            ctx.drawPDFPage(page)
            return true
        }
        return ok ? Raster(px: px, w: w, h: h, rect: rect, k: k) : nil
    }

    /// The part of the page that belongs to this line: its box, grown, but never past halfway to the lines above and
    /// below (so their ink isn't covered or measured).
    static func band(_ session: PDFEditSession, _ id: PDFLineID) -> CGRect? {
        guard let l = session.line(id) else { return nil }
        let b = l.bounds, s = CGFloat(max(1, l.pointSize))
        var lo = b.minY - 0.45 * s, hi = b.maxY + 0.45 * s
        for o in session.lines(page: id.page) where o.index != l.index {
            let ob = o.bounds
            guard !ob.isNull, ob.maxX > b.minX + 1, ob.minX < b.maxX - 1 else { continue }
            if ob.midY > b.midY, ob.minY < hi { hi = max(b.maxY - 0.1 * s, min(hi, (b.maxY + ob.minY) / 2)) }
            if ob.midY < b.midY, ob.maxY > lo { lo = min(b.minY + 0.1 * s, max(lo, (b.minY + ob.maxY) / 2)) }
        }
        var x0 = b.minX - 0.3 * s, x1 = b.maxX + 0.3 * s
        // Other text on the same baseline (a second column, a number in the margin) stays out.
        for o in session.lines(page: id.page) where o.index != l.index {
            let ob = o.bounds
            guard !ob.isNull, ob.maxY > b.minY + 0.3 * (b.height), ob.minY < b.maxY - 0.3 * b.height else { continue }
            if ob.minX >= b.maxX - 0.5 { x1 = min(x1, (b.maxX + ob.minX) / 2) }
            if ob.maxX <= b.minX + 0.5 { x0 = max(x0, (b.minX + ob.maxX) / 2) }
        }
        let crop = session.pages[id.page].cropBox
        let r = CGRect(x: x0, y: lo, width: x1 - x0, height: hi - lo).intersection(crop)
        return r.isNull || r.width < 1 || r.height < 1 ? nil : r
    }

    /// Reads the picture under the line and finds the closest font. Nil when there's no picture to read.
    /// `preferred`: fonts already used for other lines of this document; one of them wins a near tie, so lines set
    /// in the same typeface don't come out in two lookalikes.
    static func look(_ session: PDFEditSession, _ id: PDFLineID, preferred: Set<String> = []) -> PDFScanLook? {
        guard isScanLine(session, id), let l = session.line(id), let band = band(session, id),
              let page = session.originalDocument.page(at: id.page)?.pageRef else { return nil }
        let s = CGFloat(max(1, l.pointSize))
        // About 48 px per em: enough to tell fonts apart, small enough to be quick.
        let k = min(12, max(2, 48 / s))
        guard let r = render(page, band, k: k) else { return nil }

        // Paper: the most common colour inside the OCR box (a highlighted line keeps its highlight).
        let qb = l.bounds
        let c0 = max(0, r.col(qb.minX)), c1 = min(r.w, r.col(qb.maxX) + 1)
        let r0 = max(0, r.row(qb.maxY)), r1 = min(r.h, r.row(qb.minY) + 1)
        guard c1 > c0, r1 > r0 else { return nil }
        var bins: [Int: (n: Int, sum: [Double])] = [:]
        var lums: [Double] = []
        for row in r0..<r1 {
            for col in c0..<c1 {
                let c = r.rgb(col, row)
                let key = (Int(c[0] * 31) << 10) | (Int(c[1] * 31) << 5) | Int(c[2] * 31)
                var e = bins[key] ?? (0, [0, 0, 0])
                e.n += 1; e.sum = zip(e.sum, c).map(+)
                bins[key] = e
                lums.append(r.lum(col, row))
            }
        }
        guard let top = bins.values.max(by: { $0.n < $1.n }) else { return nil }
        let paper = top.sum.map { $0 / Double(top.n) }
        let paperLum = 0.2126 * paper[0] + 0.7152 * paper[1] + 0.0722 * paper[2]
        lums.sort()
        let darkLum = lums[min(lums.count - 1, lums.count / 50)]
        let contrast = abs(paperLum - darkLum)
        let darkInk = darkLum < paperLum
        // Ink: clearly away from the paper, toward the darkest (or lightest, for light text on dark) pixels.
        let threshold = (paperLum + darkLum) / 2
        func isInk(_ c: Int, _ row: Int) -> Bool {
            guard contrast > 0.12 else { return false }
            let v = r.lum(c, row)
            return darkInk ? v < threshold : v > threshold
        }
        var mask = [Bool](repeating: false, count: r.w * r.h)
        var minC = r.w, maxC = -1, minR = r.h, maxR = -1
        var rowCount = [Int](repeating: 0, count: r.h)
        var inkSum = [0.0, 0.0, 0.0], inkN = 0
        let core = darkInk ? (darkLum + threshold) / 2 : (darkLum + threshold) / 2
        for row in 0..<r.h {
            for col in 0..<r.w where isInk(col, row) {
                mask[row * r.w + col] = true
                minC = min(minC, col); maxC = max(maxC, col); minR = min(minR, row); maxR = max(maxR, row)
                rowCount[row] += 1
                let v = r.lum(col, row)
                if darkInk ? v <= core : v >= core { inkSum = zip(inkSum, r.rgb(col, row)).map(+); inkN += 1 }
            }
        }
        let ink = inkN > 0 ? inkSum.map { $0 / Double(inkN) } : [0, 0, 0]

        let text = l.text.trimmingCharacters(in: .whitespaces)
        guard maxC >= minC, maxR >= minR, !text.isEmpty else {
            // No ink found: cover the OCR box and draw at the OCR position in a plain font.
            let style = PDFTextStyle(fontName: "Helvetica", size: Double(s), red: ink[0], green: ink[1], blue: ink[2])
            return PDFScanLook(cover: qb, paper: paper, ink: ink, style: style, origin: l.origin, inkWidth: Double(qb.width), inkRight: qb.maxX)
        }
        // Baseline: the lowest row that's well filled (descenders are sparse).
        let peak = rowCount.max() ?? 1
        var baseRow = maxR
        while baseRow > minR && Double(rowCount[baseRow]) < 0.3 * Double(peak) { baseRow -= 1 }
        let baselineY = r.y(baseRow + 1)
        let inkLeft = r.x(minC), inkRight = r.x(maxC + 1)
        let inkWidth = inkRight - inkLeft

        // Font: the candidate whose drawing of the OCR text overlaps the picture's ink best, sized to its width.
        // How much ink the line holds (blur in the scan spreads ink but doesn't add any, so this tells the weight).
        // Full ink is the typical stroke centre (median of the ink pixels), not the darkest speck.
        var inkLums: [Double] = []
        for row in minR...maxR { for col in minC...maxC where mask[row * r.w + col] { inkLums.append(r.lum(col, row)) } }
        inkLums.sort()
        let fullInk = inkLums.isEmpty ? darkLum : inkLums[inkLums.count / 2]
        var scanInk = 0.0
        let span = max(0.05, abs(paperLum - fullInk))
        for row in max(0, minR - 2)..<min(r.h, maxR + 3) {
            for col in max(0, minC - 2)..<min(r.w, maxC + 3) {
                let v = r.lum(col, row)
                scanInk += min(1, max(0, (darkInk ? paperLum - v : v - paperLum) / span))
            }
        }
        let best = matchFont(text: text, mask: mask, raster: r, box: (minC, maxC, minR, maxR), baseRow: baseRow,
                             inkWidthPx: CGFloat(maxC - minC + 1), scanInk: scanInk, emGuessPx: s * k, preferred: preferred)
        var fontName = best?.name ?? "Helvetica"
        var size = best?.size ?? Double(s)
        if !(size > 0.4 * Double(s) && size < 2.5 * Double(s)) { size = Double(s); fontName = best?.name ?? "Helvetica" }
        // Start where the old ink starts, less the new font's own side bearing.
        let ct = CTFontCreateWithName(fontName as CFString, CGFloat(size), nil)
        let lead = inkBounds(text, ct).minX
        let origin = CGPoint(x: inkLeft - (lead.isFinite ? lead : 0), y: baselineY)
        // Cover: the old ink plus room for anti-aliasing, inside the band.
        let pad = max(0.75, 0.06 * s)
        // Across, it also takes in the OCR box: a tinted chip behind a word (inline code) isn't ink but is part of it.
        let cx0 = min(inkLeft - pad, qb.minX), cx1 = max(inkRight + pad, qb.maxX)
        let cover = CGRect(x: cx0, y: r.y(maxR + 1) - pad, width: cx1 - cx0, height: r.y(minR) - r.y(maxR + 1) + 2 * pad)
            .intersection(band)
        let style = PDFTextStyle(fontName: fontName, size: (size * 100).rounded() / 100, red: ink[0], green: ink[1], blue: ink[2])
        // Words: ink columns split where they go blank for longer than a word gap.
        var colInk = [Bool](repeating: false, count: r.w)
        for row in minR...maxR { for col in minC...maxC where mask[row * r.w + col] { colInk[col] = true } }
        let gap = max(2, Int(0.16 * s * k))
        var starts: [CGFloat] = []
        var col = minC, blank = gap + 1
        while col <= maxC {
            if colInk[col] { if blank > gap { starts.append(r.x(col)) }; blank = 0 } else { blank += 1 }
            col += 1
        }
        let words = text.split(separator: " ")
        return PDFScanLook(cover: cover, paper: paper, ink: ink, style: style, origin: origin, inkWidth: Double(inkWidth),
                           wordStarts: starts.count == words.count ? starts : nil, inkRight: inkRight)
    }

    /// Glyph-path bounds of the text set in `font` (baseline at y = 0).
    static func inkBounds(_ text: String, _ font: CTFont) -> CGRect {
        let a = NSAttributedString(string: text, attributes: [.font: font as NSFont])
        return CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(a), .useGlyphPathBounds)
    }

    static func installedCandidates() -> [String] {
        if let cached = candidateCache { return cached }
        var names: [String] = []
        let fm = NSFontManager.shared
        let families = Set(fm.availableFontFamilies)
        for fam in candidateFamilies where families.contains(fam) {
            // Upright members from regular to bold (weights 5…10, no italics, no condensed): semibold headings too.
            for m in fm.availableMembers(ofFontFamily: fam) ?? [] {
                guard m.count >= 4, let name = m[0] as? String, let weight = m[2] as? Int,
                      let traits = (m[3] as? NSNumber)?.uintValue else { continue }
                let t = NSFontTraitMask(rawValue: traits)
                if t.contains(.italicFontMask) || t.contains(.condensedFontMask) || t.contains(.narrowFontMask) { continue }
                if (5...10).contains(weight), !name.localizedCaseInsensitiveContains("ornament") { names.append(name) }
            }
        }
        var seen = Set<String>()
        names = names.filter { seen.insert($0).inserted }
        candidateCache = names
        return names
    }
    private static var candidateCache: [String]?

    /// The installed font that draws `text` most like the picture's ink. The ink is split into words where the
    /// columns go blank; when that gives as many words as the text has, each word is drawn on its own scanned word
    /// (one font's advances never drift the rest of the line out of place), else the whole line is drawn once.
    /// Score: overlap with a pixel of tolerance, less a weight term (a soft scan spreads strokes, so a bold face
    /// overlaps it well, but it can't add ink: the amount of ink tells regular from bold).
    private static func matchFont(text: String, mask: [Bool], raster r: Raster, box: (Int, Int, Int, Int), baseRow: Int,
                                  inkWidthPx: CGFloat, scanInk: Double, emGuessPx: CGFloat,
                                  preferred: Set<String>) -> (name: String, size: Double)? {
        let (minC, maxC, minR, maxR) = box
        let margin = 4
        let bw = maxC - minC + 1 + 2 * margin, bh = maxR - minR + 1 + 2 * margin
        let shrink = min(1, 4000 / CGFloat(bw))
        let w = max(1, Int(CGFloat(bw) * shrink)), h = max(1, Int(CGFloat(bh) * shrink))
        var scan = [Bool](repeating: false, count: w * h)
        for row in max(0, minR - margin)..<min(r.h, maxR + margin + 1) {
            for col in max(0, minC - margin)..<min(r.w, maxC + margin + 1) where mask[row * r.w + col] {
                let x = Int(CGFloat(col - minC + margin) * shrink), y = Int(CGFloat(row - minR + margin) * shrink)
                if x < w, y < h { scan[y * w + x] = true }
            }
        }
        let scanCount = scan.lazy.filter { $0 }.count
        guard scanCount > 0 else { return nil }
        let scanGrown = dilate(scan, w, h)
        let scanStroke = strokeWidth(scan, w, h)
        let baseY = CGFloat(baseRow + 1 - minR + margin) * shrink   // from the top, in the compare bitmap

        // Words in the picture.
        var colInk = [Bool](repeating: false, count: w)
        for y in 0..<h { for x in 0..<w where scan[y * w + x] { colInk[x] = true } }
        let gap = max(2, Int(0.16 * emGuessPx * shrink))
        var segments: [(x0: Int, x1: Int)] = []
        var x = 0
        while x < w {
            guard colInk[x] else { x += 1; continue }
            var end = x
            var blank = 0
            var k = x
            while k < w {
                if colInk[k] { end = k; blank = 0 } else { blank += 1; if blank > gap { break } }
                k += 1
            }
            segments.append((x, end + 1))
            x = end + 1
        }
        let words = text.split(separator: " ").map(String.init)
        let wordMode = words.count > 1 && segments.count == words.count

        var best: (name: String, size: Double, score: Double)?
        var bestPreferred: (name: String, size: Double, score: Double)?
        for name in installedCandidates() {
            let f100 = CTFontCreateWithName(name as CFString, 100, nil)
            // Size in compare pixels per em.
            let em: CGFloat
            if wordMode {
                let rendered = words.reduce(CGFloat(0)) { $0 + inkBounds($1, f100).width }
                let scanned = segments.reduce(CGFloat(0)) { $0 + CGFloat($1.x1 - $1.x0) }
                guard rendered > 0 else { continue }
                em = 100 * scanned / rendered
            } else {
                let ib = inkBounds(text, f100)
                guard ib.width > 0 else { continue }
                em = 100 * inkWidthPx * shrink / ib.width
            }
            guard em > 1 else { continue }
            let font = CTFontCreateWithName(name as CFString, em, nil)
            var px = [UInt8](repeating: 0, count: w * h)
            px.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                ctx.setFillColor(gray: 0, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                func draw(_ t: String, at left: CGFloat) {
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: t, attributes: [.font: font as NSFont,
                                                                                                           .foregroundColor: NSColor.white]))
                    ctx.textPosition = CGPoint(x: left - inkBounds(t, font).minX, y: CGFloat(h) - baseY)
                    CTLineDraw(line, ctx)
                }
                if wordMode { for (wd, sg) in zip(words, segments) { draw(wd, at: CGFloat(sg.x0)) } }
                else { draw(text, at: CGFloat(margin) * shrink) }
            }
            var drawn = [Bool](repeating: false, count: w * h)
            var ink = 0.0, drawnCount = 0
            for i in 0..<(w * h) {
                ink += Double(px[i]) / 255
                if px[i] > 127 { drawn[i] = true; drawnCount += 1 }
            }
            let drawnGrown = dilate(drawn, w, h)
            var hitA = 0, hitB = 0
            for i in 0..<(w * h) {
                if scan[i] && drawnGrown[i] { hitA += 1 }
                if drawn[i] && scanGrown[i] { hitB += 1 }
            }
            let overlap = Double(hitA + hitB) / Double(max(1, scanCount + drawnCount))
            let candInk = ink / Double(shrink * shrink)
            let inkMiss = scanInk > 0 && candInk > 0 ? abs(log(candInk / scanInk)) : 1
            // Weight: stroke thickness tells regular, semibold and bold apart where overlap and ink can't.
            let stroke = strokeWidth(drawn, w, h)
            let strokeMiss = scanStroke > 0 && stroke > 0 ? abs(log(stroke / scanStroke)) : 1
            let weightMiss = 0.3 * inkMiss + strokeMiss
            let score = overlap - 0.5 * weightMiss
            let size = Double(em / shrink / r.k)
            if ProcessInfo.processInfo.environment["DW_SCAN_DEBUG"] == "1" {
                print(String(format: "%-30@ words %d overlap %.3f stroke %.2f/%.2f miss %.3f score %.3f size %.2f", name as NSString,
                             wordMode ? 1 : 0, overlap, stroke, scanStroke, weightMiss, score, size))
            }
            if best == nil || score > best!.score { best = (name, size, score) }
            if preferred.contains(name), bestPreferred == nil || score > bestPreferred!.score { bestPreferred = (name, size, score) }
        }
        if let p = bestPreferred, let b = best, p.score >= b.score - 0.02 { return (p.name, p.size) }
        return best.map { ($0.name, $0.size) }
    }

    /// Typical stroke thickness in pixels: the median length of horizontal ink runs (vertical stems dominate).
    private static func strokeWidth(_ m: [Bool], _ w: Int, _ h: Int) -> Double {
        var runs: [Int] = []
        for y in 0..<h {
            var n = 0
            for x in 0..<w {
                if m[y * w + x] { n += 1 } else if n > 0 { runs.append(n); n = 0 }
            }
            if n > 0 { runs.append(n) }
        }
        guard !runs.isEmpty else { return 0 }
        runs.sort()
        // Mean of the middle half: steadier than one median pixel count.
        let mid = runs[(runs.count / 4)...(max(runs.count / 4, runs.count * 3 / 4 - 1))]
        return Double(mid.reduce(0, +)) / Double(mid.count)
    }

    /// Grows a mask by one pixel in every direction.
    private static func dilate(_ m: [Bool], _ w: Int, _ h: Int) -> [Bool] {
        var out = m
        for y in 0..<h {
            for x in 0..<w where m[y * w + x] {
                for dy in -1...1 {
                    let yy = y + dy
                    guard yy >= 0, yy < h else { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        if xx >= 0, xx < w { out[yy * w + xx] = true }
                    }
                }
            }
        }
        return out
    }
}

/// Point-in-quad, shared with the canvas.
enum PDFEditCanvasGeometry {
    static func contains(_ q: [CGPoint], _ p: CGPoint) -> Bool {
        guard q.count == 4 else { return false }
        var sign: CGFloat = 0
        for i in 0..<4 {
            let a = q[i], b = q[(i + 1) % 4]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if abs(cross) < 1e-9 { continue }
            if sign == 0 { sign = cross } else if (sign > 0) != (cross > 0) { return false }
        }
        return true
    }
}

