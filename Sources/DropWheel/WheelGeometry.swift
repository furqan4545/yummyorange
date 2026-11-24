import AppKit

// MARK: - Metrics

/// The wheel's measurements at full size, in points. One ring of petals around a centre capsule, on a glass
/// annulus that reaches 6.4 pt past the petals on both sides.
enum WheelMetrics {
    static let innerRadius: CGFloat = 48.64
    static let outerRadius: CGFloat = 119.52
    /// Constant width of the straight gap between neighbouring petals.
    static let gap: CGFloat = 5
    static let backdropInner: CGFloat = 42.24
    static let backdropOuter: CGFloat = 125.92
    /// Radius of the disc every petal starts from when the wheel opens.
    static let introRadius: CGFloat = 50.4
    /// Labels sit at labelBase + (outer − labelBase) × labelFraction from the centre: 84.53 pt.
    static let labelBase: CGFloat = 40
    static let labelFraction: CGFloat = 0.56
    /// How far down a petal's side edge its outer corner starts.
    static let outerCornerEdge: CGFloat = 20.16
    /// Side of the wheel's panel: the backdrop plus 60.08 pt on every side.
    static let panelSide: CGFloat = 372
    static let capsule = CGSize(width: 70, height: 36)
    static let centerText = CGSize(width: 58, height: 28)
    /// Widest a petal label may be.
    static let labelWidth: CGFloat = 82
    /// Up to this many petals share one ring; more go in two rings.
    static let singleRingLimit = 8
    /// The second ring: from just past the first one (a gap as wide as the petal gap) outward.
    static var secondInner: CGFloat { outerRadius + gap }
    static let secondWidth: CGFloat = 66
    static var secondOuter: CGFloat { secondInner + secondWidth }

    static var labelRadius: CGFloat { labelBase + (outerRadius - labelBase) * labelFraction }
    static var panelMargin: CGFloat { panelSide / 2 - backdropOuter }

    /// Kept for callers of the earlier growing ring: rings no longer grow, a second ring takes the extra petals.
    static func growth(for count: Int) -> CGFloat { 0 }

    /// Outer edge of the backdrop for `count` petals (6.4 pt past the outermost ring).
    static func backdropOuter(for count: Int) -> CGFloat {
        count > singleRingLimit ? secondOuter + (backdropOuter - outerRadius) : backdropOuter
    }

    /// How many of `count` petals go in the inner ring: all up to 8; beyond that a share that makes petals in
    /// both rings about as wide (the first petals, the most common ones, stay nearest the cursor).
    static func innerCount(for count: Int) -> Int {
        guard count > singleRingLimit else { return count }
        let innerMid = (innerRadius + outerRadius) / 2, outerMid = (secondInner + secondOuter) / 2
        let share = (CGFloat(count) * innerMid / (innerMid + outerMid)).rounded()
        return min(max(Int(share), 3), count - 3)
    }
}

// MARK: - Shapes

/// The petal and backdrop outlines, shared by the AppKit drawing and the SwiftUI glass.
enum WheelGeometry {
    /// One petal: an annular sector with a constant-width gap on each side (so the side edges are straight and
    /// parallel to the neighbour's), quadratic corners whose control point sits on the sharp corner, and arcs
    /// along the inner and outer edge. Angles are mathematical (0 at 3 o'clock, counter-clockwise); with
    /// `yDown` the path is for a flipped (SwiftUI) coordinate space.
    static func petalPath(center c: CGPoint, centerAngle: CGFloat, sector: CGFloat, gap: CGFloat,
                          inner ri: CGFloat, outer ro: CGFloat, cornerEdge: CGFloat = WheelMetrics.outerCornerEdge,
                          yDown: Bool = false) -> CGPath {
        let start = centerAngle - sector / 2, end = centerAngle + sector / 2
        let hg = max(gap / 2, 0)
        // Angular half-gap at radius r, so the gap stays the same width all the way out.
        func half(_ r: CGFloat) -> CGFloat { asin(min(hg / max(hg + 0.01, r), 0.95)) }
        func P(_ r: CGFloat, _ a: CGFloat) -> CGPoint {
            CGPoint(x: c.x + r * cos(a), y: yDown ? c.y - r * sin(a) : c.y + r * sin(a))
        }
        let iS = start + half(ri), iE = end - half(ri)
        let ac = min((iE - iS) * 0.18, 0.18)            // inner corner span (radians)
        let rC = ri / max(cos(ac), 0.01)                 // inner corner control radius
        let rA = ri * tan(ac) + rC                       // where the inner corner meets the side
        let rB = max(ro - cornerEdge, 0)                 // where the outer corner leaves the side
        let oS = start + half(ro), oE = end - half(ro)
        let oc = min((oE - oS) * 0.24, 0.15)            // outer corner span (radians)
        let p = CGMutablePath()
        p.move(to: P(rA, start + half(rA)))
        p.addLine(to: P(rB, start + half(rB)))
        p.addQuadCurve(to: P(ro, oS + oc), control: P(ro, oS))
        addArc(p, c, ro, from: oS + oc, to: oE - oc, yDown: yDown)
        p.addQuadCurve(to: P(rB, end - half(rB)), control: P(ro, oE))
        p.addLine(to: P(rA, end - half(rA)))
        p.addQuadCurve(to: P(ri, iE - ac), control: P(rC, end - half(rC)))
        addArc(p, c, ri, from: iE - ac, to: iS + ac, yDown: yDown)
        p.addQuadCurve(to: P(rA, start + half(rA)), control: P(rC, start + half(rC)))
        p.closeSubpath()
        return p
    }

    /// A ring: the outer circle and, when `inner` > 0, the inner circle wound the other way, so the hole stays
    /// empty under both fill rules.
    static func diskPath(center c: CGPoint, inner: CGFloat, outer: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addArc(center: c, radius: max(outer, 0), startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        p.closeSubpath()
        if inner > 0 {
            p.move(to: CGPoint(x: c.x + inner, y: c.y))
            p.addArc(center: c, radius: inner, startAngle: 0, endAngle: -2 * .pi, clockwise: true)
            p.closeSubpath()
        }
        return p
    }

    /// An arc between two mathematical angles, in whichever direction gets there.
    private static func addArc(_ p: CGMutablePath, _ c: CGPoint, _ r: CGFloat, from a0: CGFloat, to a1: CGFloat, yDown: Bool) {
        // In y-up space a mathematical angle is a CoreGraphics angle; flipped, it is its negative.
        let s = yDown ? -a0 : a0, e = yDown ? -a1 : a1
        p.addArc(center: c, radius: max(r, 0), startAngle: s, endAngle: e, clockwise: yDown ? (a1 > a0) : (a1 < a0))
    }
}

// MARK: - Layout

/// Geometry of a wheel with `count` petals in a view: ring radii, petal shapes, hit-testing and label room.
/// Drawing and hit-testing both come from here, so the petal you see is the petal you hit.
///
/// There is one ring. Petal 0 sits at 12 o'clock (9 o'clock for three petals) and the rest follow clockwise.
/// The wheel is drawn at full size whenever the view is big enough for its backdrop, and shrinks to fit a
/// smaller view (the Settings preview).
struct WheelLayout {
    /// One ring of petals: the petals `first ..< first + count`, between `inner` and `outer`.
    struct Ring {
        let first: Int
        let count: Int
        let inner: CGFloat
        let outer: CGFloat
        var sector: CGFloat { count > 0 ? 2 * .pi / CGFloat(count) : 2 * .pi }
        func contains(_ i: Int) -> Bool { i >= first && i < first + count }
    }

    let count: Int
    let center: CGPoint
    /// Points per design point.
    let scale: CGFloat
    /// Turns the whole wheel clockwise by this many radians (labels stay upright).
    let rotation: CGFloat
    /// The first (inner) ring's edges.
    let inner: CGFloat
    let outer: CGFloat
    let gap: CGFloat
    let backdropInner: CGFloat
    let backdropOuter: CGFloat
    let labelRadius: CGFloat
    let introRadius: CGFloat
    let cornerEdge: CGFloat
    /// One ring up to 8 petals, two rings beyond.
    let rings: [Ring]
    /// Kept for callers of the old layout: points past the outer edge never count.
    let outerSlack: CGFloat = 0

    /// Side of the wheel's panel (and of a full-size wheel view) for `count` petals: 372 pt for one ring, the
    /// same margin around the larger backdrop for two.
    static func diameter(for count: Int) -> CGFloat {
        (2 * (WheelMetrics.backdropOuter(for: count) + WheelMetrics.panelMargin)).rounded(.up)
    }

    /// Diameter of the backdrop: the smallest square that shows the whole wheel at full size.
    static func contentDiameter(for count: Int) -> CGFloat {
        2 * WheelMetrics.backdropOuter(for: count)
    }

    init(count: Int, bounds: CGRect, rotation: CGFloat = 0) {
        self.count = max(0, count)
        self.rotation = rotation
        center = CGPoint(x: bounds.midX, y: bounds.midY)
        let side = min(bounds.width, bounds.height)
        let s = max(0.1, min(1, side / Self.contentDiameter(for: self.count)))
        scale = s
        inner = WheelMetrics.innerRadius * s
        outer = WheelMetrics.outerRadius * s
        gap = WheelMetrics.gap * s
        backdropInner = WheelMetrics.backdropInner * s
        backdropOuter = WheelMetrics.backdropOuter(for: self.count) * s
        labelRadius = WheelMetrics.labelRadius * s
        introRadius = WheelMetrics.introRadius * s
        cornerEdge = WheelMetrics.outerCornerEdge * s
        let k = WheelMetrics.innerCount(for: self.count)
        var rings: [Ring] = []
        if k > 0 { rings.append(Ring(first: 0, count: k, inner: inner, outer: outer)) }
        if self.count > k {
            rings.append(Ring(first: k, count: self.count - k, inner: WheelMetrics.secondInner * s,
                              outer: WheelMetrics.secondOuter * s))
        }
        self.rings = rings
    }

    var hole: CGFloat { inner }
    /// The outermost petal edge.
    var outerRadius: CGFloat { rings.last?.outer ?? outer }
    var backdropRadius: CGFloat { backdropOuter }
    /// Half the width of the centre capsule: nothing within it is ever a petal.
    var centerRadius: CGFloat { WheelMetrics.capsule.width / 2 * scale }
    /// The first ring's sector (kept for callers that assume one ring).
    var sector: CGFloat { rings.first?.sector ?? 2 * .pi }

    /// How many petals the highlight moved by going from `a` to `b`: the shorter way round within one ring, so a
    /// fast sweep that skipped petals still ticks for each one; 1 when it enters from the centre or changes ring.
    func steps(from a: Int?, to b: Int) -> Int {
        guard let a, a != b else { return 1 }
        let r = ring(a)
        guard r.contains(b), r.count > 1 else { return 1 }
        let d = abs(a - b) % r.count
        return max(1, min(d, r.count - d))
    }

    /// The ring holding petal `i`.
    func ring(_ i: Int) -> Ring {
        rings.last { i >= $0.first } ?? rings.first ?? Ring(first: 0, count: 0, inner: inner, outer: outer)
    }

    /// Mathematical angle of a ring's first petal: 12 o'clock (9 o'clock for a lone ring of three).
    private func baseAngle(_ r: Ring) -> CGFloat { (r.count == 3 && rings.count == 1 ? .pi : .pi / 2) - rotation }

    /// Mathematical angle (0 at 3 o'clock, counter-clockwise) through the middle of petal `i`.
    func centerAngle(_ i: Int) -> CGFloat {
        let r = ring(i)
        return baseAngle(r) - CGFloat(i - r.first) * r.sector
    }

    /// Clock angle (0 at 12 o'clock, clockwise) through the middle of petal `i`.
    func midAngle(_ i: Int) -> CGFloat {
        let a = (.pi / 2 - centerAngle(i)).truncatingRemainder(dividingBy: 2 * .pi)
        return a < 0 ? a + 2 * .pi : a
    }

    func point(radius: CGFloat, clockAngle a: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * sin(a), y: center.y + radius * cos(a))
    }

    func point(radius: CGFloat, angle a: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
    }

    /// The centre capsule.
    var capsuleRect: CGRect {
        let w = WheelMetrics.capsule.width * scale, h = WheelMetrics.capsule.height * scale
        return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    }

    // MARK: Shapes

    /// Petal `i` fully open.
    func path(_ i: Int) -> CGPath { path(i, bloom: 1) }

    /// Petal `i` while the wheel opens: at 0 every petal is a slice of one disc of the intro radius with no
    /// hole and no gap; at 1 it is the full petal.
    func path(_ i: Int, bloom t: CGFloat, yDown: Bool = false, in rect: CGRect? = nil) -> CGPath {
        let c = rect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? center
        let r = ring(i)
        return WheelGeometry.petalPath(center: c, centerAngle: centerAngle(i), sector: r.sector,
                                       gap: gap * t, inner: r.inner * t, outer: introRadius + (r.outer - introRadius) * t,
                                       cornerEdge: cornerEdge, yDown: yDown)
    }

    /// The backdrop annulus while the wheel opens (a disc of the intro radius at 0).
    func backdropPath(bloom t: CGFloat) -> CGPath {
        WheelGeometry.diskPath(center: center, inner: backdropInner * t,
                               outer: introRadius + (backdropOuter - introRadius) * t)
    }

    // MARK: Hit-testing

    /// The ring whose band (with half a point to spare) holds a point, if any.
    private func ringBand(at p: CGPoint) -> Ring? {
        let d = hypot(p.x - center.x, p.y - center.y)
        return rings.first { d >= $0.inner - 0.5 && d <= $0.outer + 0.5 }
    }

    /// Whether a point lies in a ring's band (the petal's own shape decides the rest).
    func isInBand(_ p: CGPoint) -> Bool { count > 0 && ringBand(at: p) != nil }

    /// The petal under a point: in the ring whose band holds it, the slot whose middle is nearest in angle, if
    /// the point is inside that petal's drawn shape. The centre, the gaps and everything outside are no petal.
    func index(at p: CGPoint) -> Int? {
        guard count > 0, let r = ringBand(at: p) else { return nil }
        let i = slot(at: p, in: r)
        return path(i).contains(p) ? i : nil
    }

    /// The slot whose middle is nearest in angle to a point, in the ring at that distance (the inner ring when
    /// the point is in neither band).
    func slot(at p: CGPoint) -> Int {
        guard let r = ringBand(at: p) ?? rings.first else { return 0 }
        return slot(at: p, in: r)
    }

    private func slot(at p: CGPoint, in r: Ring) -> Int {
        guard r.count > 1 else { return r.first }
        let theta = atan2(p.y - center.y, p.x - center.x)
        var a = (baseAngle(r) - theta).truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        return r.first + Int((a / r.sector).rounded()) % r.count
    }

    // MARK: Labels

    /// Where a label may be centred in petal `i`, best first: the middle of its band (the label radius in the
    /// inner ring), then a little outward where the petal is wider.
    func labelAnchors(_ i: Int) -> [CGPoint] {
        let a = centerAngle(i), r = ring(i)
        let base = r.first == 0 ? labelRadius : (r.inner + r.outer) / 2
        return [0, 4, 8].map { point(radius: base + $0 * scale, angle: a) }
    }

    /// Whether every one of `parts` (boxes relative to `anchor`) lies inside petal `i`, `padding` from every edge.
    func fits(parts: [CGRect], at anchor: CGPoint, in i: Int, padding: CGFloat) -> Bool {
        parts.allSatisfy { r in
            fits(r.size, at: CGPoint(x: anchor.x + r.midX, y: anchor.y + r.midY), in: i, padding: padding)
        }
    }

    /// Whether an upright box of `size` centred at `anchor` lies inside petal `i`, `padding` from every edge
    /// (a negative padding lets it reach into the gap, never past the line between two petals).
    func fits(_ size: CGSize, at anchor: CGPoint, in i: Int, padding: CGFloat) -> Bool {
        let r = ring(i)
        let box = CGRect(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2, width: size.width, height: size.height)
        // Inner edge: the point of the box nearest the centre must clear the inner circle.
        let nx = min(max(center.x, box.minX), box.maxX), ny = min(max(center.y, box.minY), box.maxY)
        guard hypot(nx - center.x, ny - center.y) >= r.inner + padding else { return false }
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
        // Outer edge: a box is inside a disc when its corners are.
        guard corners.allSatisfy({ hypot($0.x - center.x, $0.y - center.y) <= r.outer - padding }) else { return false }
        guard r.count > 1 else { return true }
        // Sides: every corner at least half a gap plus padding inside both side edges.
        let a = centerAngle(i)
        let u0 = CGPoint(x: cos(a - r.sector / 2), y: sin(a - r.sector / 2))
        let u1 = CGPoint(x: cos(a + r.sector / 2), y: sin(a + r.sector / 2))
        let margin = gap / 2 + padding
        return corners.allSatisfy { corner in
            let q = CGPoint(x: corner.x - center.x, y: corner.y - center.y)
            let fromStart = u0.x * q.y - u0.y * q.x     // positive counter-clockwise of the first edge
            let fromEnd = -(u1.x * q.y - u1.y * q.x)    // positive clockwise of the last edge
            return fromStart >= margin && fromEnd >= margin
        }
    }
}

// MARK: - Petal labels

/// How one petal's label is set. A conversion petal shows its format name on one line (11.25 pt semibold,
/// +0.35 tracking); a tool or action petal shows its symbol (12.6 pt medium) over a small name (7.5 pt semibold,
/// +0.2 tracking, up to two lines). Both may shrink to 85% of that to fit the petal; labels are always upright.
struct PetalLabel {
    var anchor: CGPoint
    var lines: [String]
    var font: NSFont
    var kern: CGFloat
    var symbol: NSImage?
    var symbolPointSize: CGFloat
    /// Height of the symbol's box (0 without a symbol).
    var symbolHeight: CGFloat
    /// Space between symbol and text.
    var spacing: CGFloat
    var lineHeight: CGFloat
    /// Width every line is drawn in (longer lines are cut with "…").
    var width: CGFloat
    var truncated: Bool
    /// The symbol's box and each line's box, in view coordinates.
    var parts: [CGRect] = []
    /// Whether the label needed to reach into the gaps beside its petal (as crowded labels may).
    var overhangs = false

    var height: CGFloat { symbolHeight + (symbol == nil ? 0 : spacing) + lineHeight * CGFloat(lines.count) }

    static let formatSize: CGFloat = 10.5
    static let formatKern: CGFloat = 0.5
    static let toolSize: CGFloat = 8.25
    static let toolKern: CGFloat = 0.45
    static let symbolSize: CGFloat = 11.5
    static let symbolBox: CGFloat = 13
    static let symbolSpacing: CGFloat = 3
    static let minimumScale: CGFloat = 0.85

    /// Padding a label keeps from its petal's edges; when that fails at a size, it may reach to the middle of
    /// the gap beside it (never into the next petal) before it shrinks.
    static func padding(_ layout: WheelLayout, overhang: Bool) -> CGFloat { overhang ? -layout.gap / 2 : 3 * layout.scale }

    /// The largest setting that fits the petal: full size first, one line before two (tool names wrap first,
    /// format names shrink first), down to 85%; a format name may go down to 9 pt before anything is cut.
    static func fit(_ item: WheelItem, petal i: Int, in layout: WheelLayout) -> PetalLabel {
        let s = layout.scale
        let symbolImage = item.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: item.title) }
        let symbolWidth = symbolImage.map { img -> CGFloat in
            let config = NSImage.SymbolConfiguration(pointSize: symbolSize * s, weight: .medium)
            return ceil((img.withSymbolConfiguration(config) ?? img).size.width)
        } ?? 0
        let isFormat = item.symbol == nil
        // Petals show the name without the "…" that marks a command with options (the reference shows none).
        var title = item.title.trimmingCharacters(in: .whitespaces)
        for suffix in ["…", "..."] where title.hasSuffix(suffix) { title = String(title.dropLast(suffix.count)) }
        title = title.uppercased()
        let anchors = layout.labelAnchors(i)
        let maxWidth = WheelMetrics.labelWidth * s
        let splits = twoLineSplits(title)
        var scales: [CGFloat] = [1, 0.95, 0.9, minimumScale, 0.8, 0.75]
        if isFormat { scales.append(9 / formatSize) }
        let attempts: [(CGFloat, [String])] = isFormat
            ? scales.map { ($0, [title]) } + scales.flatMap { k in splits.map { (k, $0) } }
            : scales.flatMap { k in ([[title]] + splits).map { (k, $0) } }

        func setting(_ k: CGFloat) -> (font: NSFont, kern: CGFloat, line: CGFloat, symbolHeight: CGFloat, spacing: CGFloat) {
            let size = (isFormat ? formatSize : toolSize) * k * s
            let font = NSFont.systemFont(ofSize: size, weight: .medium)
            let line = ceil(font.ascender - font.descender + font.leading)
            let kern = (isFormat ? formatKern : toolKern) * s
            return (font, kern, line, symbolImage == nil ? 0 : symbolBox * s, symbolImage == nil ? 0 : symbolSpacing * s)
        }
        func parts(_ widths: [CGFloat], _ set: (font: NSFont, kern: CGFloat, line: CGFloat, symbolHeight: CGFloat, spacing: CGFloat)) -> [CGRect] {
            var top = (set.symbolHeight + set.spacing + set.line * CGFloat(widths.count)) / 2
            var rects: [CGRect] = []
            if set.symbolHeight > 0 {
                rects.append(CGRect(x: -symbolWidth / 2, y: top - set.symbolHeight, width: symbolWidth, height: set.symbolHeight))
                top -= set.symbolHeight + set.spacing
            }
            for w in widths {
                rects.append(CGRect(x: -w / 2, y: top - set.line, width: w, height: set.line))
                top -= set.line
            }
            return rects
        }
        func make(_ anchor: CGPoint, _ lines: [String], _ set: (font: NSFont, kern: CGFloat, line: CGFloat, symbolHeight: CGFloat, spacing: CGFloat),
                  _ widths: [CGFloat], _ truncated: Bool, _ overhangs: Bool) -> PetalLabel {
            PetalLabel(anchor: anchor, lines: lines, font: set.font, kern: set.kern, symbol: symbolImage,
                       symbolPointSize: symbolSize * s, symbolHeight: set.symbolHeight, spacing: set.spacing,
                       lineHeight: set.line, width: widths.max() ?? 0, truncated: truncated,
                       parts: parts(widths, set).map { $0.offsetBy(dx: anchor.x, dy: anchor.y) }, overhangs: overhangs)
        }

        for (k, lines) in attempts {
            let set = setting(k)
            let widths = lines.map { textWidth($0, set.font, set.kern) }
            guard (widths.max() ?? 0) <= maxWidth else { continue }
            let shape = parts(widths, set)
            for overhang in [false, true] {
                let pad = padding(layout, overhang: overhang)
                if let anchor = anchors.first(where: { layout.fits(parts: shape, at: $0, in: i, padding: pad) }) {
                    return make(anchor, lines, set, widths, false, overhang)
                }
            }
        }
        // Nothing fits whole: the smallest size, the best split, each line as wide as the petal allows.
        let set = setting(scales.last ?? minimumScale)
        let lines = splits.first ?? [title]
        let pad = padding(layout, overhang: true)
        let natural = lines.map { textWidth($0, set.font, set.kern) }
        var lo: CGFloat = 0, hi = maxWidth
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            if layout.fits(parts: parts(natural.map { min($0, mid) }, set), at: anchors[0], in: i, padding: pad) { lo = mid } else { hi = mid }
        }
        let width = max(lo, 12 * s)
        return make(anchors[0], lines, set, natural.map { min($0, width) }, true, true)
    }

    static func textWidth(_ text: String, _ font: NSFont, _ kern: CGFloat) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font, .kern: kern]).width) + 1
    }

    /// Two-line versions of a title, split at spaces: the most balanced first and, between equally balanced
    /// ones, the one with the longer second line ("Read" over "QR Code").
    static func twoLineSplits(_ title: String) -> [[String]] {
        let words = title.split(separator: " ").map(String.init)
        guard words.count > 1 else { return [] }
        let splits = (1..<words.count).map { k in
            [words[..<k].joined(separator: " "), words[k...].joined(separator: " ")]
        }
        return splits.sorted { a, b in
            let wa = max(a[0].count, a[1].count), wb = max(b[0].count, b[1].count)
            return wa != wb ? wa < wb : a[1].count > b[1].count
        }
    }
}

// MARK: - Centre label

/// The text in the centre capsule (58 × 28 pt inside a 70 × 36 capsule): 9.5 pt medium on one line, or,
/// when that would shrink below 65%, a compact 7.5 pt semibold on up to two lines.
struct WheelCenterLabel {
    var lines: [String]
    var font: NSFont
    var kern: CGFloat
    var lineHeight: CGFloat
    var width: CGFloat
    var compact: Bool

    static func fit(_ text: String, scale s: CGFloat) -> WheelCenterLabel {
        let box = CGSize(width: WheelMetrics.centerText.width * s, height: WheelMetrics.centerText.height * s)
        let title = text.trimmingCharacters(in: .whitespaces)
        func font(_ size: CGFloat, _ weight: NSFont.Weight) -> (NSFont, CGFloat) {
            let f = NSFont.systemFont(ofSize: size, weight: weight)
            return (f, ceil(f.ascender - f.descender + f.leading))
        }
        // Regular: one line, 9.5 pt down to 65%.
        for k in stride(from: 1.0, through: 0.65, by: -0.05) {
            let (f, line) = font(9.5 * CGFloat(k) * s, .medium)
            let kern = 0.35 * s
            if PetalLabel.textWidth(title, f, kern) <= box.width {
                return WheelCenterLabel(lines: [title], font: f, kern: kern, lineHeight: line, width: box.width, compact: false)
            }
        }
        // Compact: 7.5 pt semibold, wrapped onto two lines, down to 55%.
        let options = [[title]] + PetalLabel.twoLineSplits(title)
        for k in stride(from: 1.0, through: 0.55, by: -0.05) {
            let (f, line) = font(7.5 * CGFloat(k) * s, .semibold)
            let kern = 0.2 * s
            for lines in options where CGFloat(lines.count) * line <= box.height + 0.5 {
                if lines.allSatisfy({ PetalLabel.textWidth($0, f, kern) <= box.width }) {
                    return WheelCenterLabel(lines: lines, font: f, kern: kern, lineHeight: line, width: box.width, compact: true)
                }
            }
        }
        let (f, line) = font(7.5 * 0.55 * s, .semibold)
        return WheelCenterLabel(lines: Array((options.count > 1 ? options[1] : [title]).prefix(2)), font: f, kern: 0.2 * s,
                                lineHeight: line, width: box.width, compact: true)
    }
}

// MARK: - Motion

/// The wheel's timing: a 0.2 s bloom on a fast-out curve, labels fading in from 0.05 s for 0.1 s, petal
/// edges from 0.2 s for 0.06 s, and a 0.07 s fade-in of the panel. No springs, no scaling.
enum WheelMotion {
    /// The opening is Apple's default UI spring: critically damped (no overshoot, no hard stop) with a 0.3 s
    /// response, started with a push of half its natural speed so the first frames already move (a spring from
    /// rest hesitates at the start). It settles gently, with no fixed end point to brake against.
    static let response: CFTimeInterval = 0.3
    static var omega: Double { 2 * .pi / response }
    /// Initial velocity as a fraction of ω (0 = from rest, 1 = a pure exponential ease-out).
    static let kick: Double = 0.5
    /// The petal edges and colours are there while the petals grow: full strength a third of the way open.
    static let bordersFullAt: CGFloat = 0.3
    /// Labels fade in over the second half of the growth, so they are settled when the petals are.
    static let labelsFrom: CGFloat = 0.45
    static let labelsTo: CGFloat = 0.9
    /// The panel's own fade, short enough to stay inside the first frames of the spring.
    static let panelFade: CFTimeInterval = 0.04
    /// When the spring is within 0.2% of open (about 0.4 s; the last 0.2 s of it is too small to see).
    static let total: CFTimeInterval = {
        var t = 0.0
        while 1 - Double(spring(t)) > 0.002 { t += 0.001 }
        return t
    }()

    /// A critically damped spring from 0 toward 1, starting at velocity kick·ω: 1 − (1 + (1 − kick)·ωt)·e^(−ωt).
    /// It rises monotonically and never overshoots for kick ≤ 1.
    static func spring(_ t: CFTimeInterval) -> CGFloat {
        guard t > 0 else { return 0 }
        let x = omega * t
        return CGFloat(min(1, 1 - (1 + (1 - kick) * x) * exp(-x)))
    }

    /// Bloom, label and border progress `t` seconds after the wheel starts opening.
    static func state(at t: CFTimeInterval) -> WheelBloom {
        guard t > 0 else { return .closed }
        guard t < total else { return .open }
        let s = spring(t)
        func smooth(_ x: CGFloat) -> CGFloat { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }
        return WheelBloom(shape: s, labels: smooth((s - labelsFrom) / (labelsTo - labelsFrom)),
                          borders: smooth(s / bordersFullAt))
    }

    /// The standard ease-out curve, cubic-bezier(0, 0, 0.58, 1).
    static func easeOut(_ x: CGFloat) -> CGFloat { bezier(0, 0, 0.58, 1, x) }

    /// A CSS-style cubic-bezier timing curve from (0,0) to (1,1): the curve's y where its x is `x`.
    static func bezier(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat) -> CGFloat {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func coord(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        func slope(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let u = 1 - t
            return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b)
        }
        var t = x
        for _ in 0..<8 {   // Newton, then bisection if it stalls
            let err = coord(t, x1, x2) - x
            if abs(err) < 1e-5 { return coord(t, y1, y2) }
            let d = slope(t, x1, x2)
            if abs(d) < 1e-6 { break }
            t = min(max(t - err / d, 0), 1)
        }
        var lo: CGFloat = 0, hi: CGFloat = 1
        t = x
        for _ in 0..<40 {
            let v = coord(t, x1, x2)
            if abs(v - x) < 1e-6 { break }
            if v < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return coord(t, y1, y2)
    }
}

/// How far the wheel has opened: the petal shapes, the labels' opacity and the petal edges' opacity.
struct WheelBloom: Equatable {
    var shape: CGFloat
    var labels: CGFloat
    var borders: CGFloat
    static let open = WheelBloom(shape: 1, labels: 1, borders: 1)
    static let closed = WheelBloom(shape: 0, labels: 0, borders: 0)
}
