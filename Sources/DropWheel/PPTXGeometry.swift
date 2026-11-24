import Foundation
import CoreGraphics

/// One subpath of a shape outline, with its own fill and stroke flags (DrawingML lets each path opt out).
struct PPTXPath {
    var path: CGPath
    var fill = true
    var stroke = true
    var evenOdd = false
    /// "norm", "lighten", "lightenLess", "darken", "darkenLess": fill shading for 3-D-looking presets.
    var shade = "norm"
    /// For open paths: the end points and the points just inside them (arrowhead directions).
    var start: (CGPoint, CGPoint)?
    var end: (CGPoint, CGPoint)?
}

/// A shape's outline in its own coordinates (0...w, 0...h, y down) and the box its text goes in.
struct PPTXGeometry {
    var paths: [PPTXPath]
    var textRect: CGRect
    /// Draw the outline first and fill over it (clouds: hides the strokes where the bumps overlap).
    var strokeUnderFill = false

    static func rect(_ w: CGFloat, _ h: CGFloat) -> PPTXGeometry {
        PPTXGeometry(paths: [PPTXPath(path: CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil))],
                     textRect: CGRect(x: 0, y: 0, width: w, height: h))
    }
}

/// Builds a CGPath with DrawingML semantics: `arc` takes a radius pair and start/sweep angles in
/// degrees, measured like the spec (visual angle on the ellipse, clockwise because y points down).
struct PPTXPathBuilder {
    let path = CGMutablePath()
    private(set) var current = CGPoint.zero
    private var first: CGPoint?
    private var firstNext: CGPoint?
    private var beforeLast: CGPoint?
    private(set) var closed = false

    mutating func move(_ x: CGFloat, _ y: CGFloat) {
        let p = CGPoint(x: x, y: y)
        path.move(to: p)
        current = p
        if first == nil { first = p }
    }

    private mutating func note(towards p: CGPoint) {
        if first == nil { first = current }
        if firstNext == nil, p != first { firstNext = p }
    }

    mutating func line(_ x: CGFloat, _ y: CGFloat) {
        let p = CGPoint(x: x, y: y)
        if path.isEmpty { move(x, y); return }
        note(towards: p)
        beforeLast = current
        path.addLine(to: p)
        current = p
    }

    mutating func cubic(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        if path.isEmpty { move(current.x, current.y) }
        note(towards: CGPoint(x: x1, y: y1) == current ? CGPoint(x: x2, y: y2) : CGPoint(x: x1, y: y1))
        beforeLast = CGPoint(x: x2, y: y2) == CGPoint(x: x, y: y) ? CGPoint(x: x1, y: y1) : CGPoint(x: x2, y: y2)
        path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
        current = CGPoint(x: x, y: y)
    }

    mutating func quad(_ x1: CGFloat, _ y1: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        if path.isEmpty { move(current.x, current.y) }
        note(towards: CGPoint(x: x1, y: y1))
        beforeLast = CGPoint(x: x1, y: y1)
        path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x1, y: y1))
        current = CGPoint(x: x, y: y)
    }

    /// Parametric angle on an ellipse for a visual angle, unwrapped to stay near it.
    private static func param(_ deg: Double, _ wR: Double, _ hR: Double) -> Double {
        let t = deg * .pi / 180
        let base = atan2(wR * sin(t), hR * cos(t))
        return base + 2 * .pi * ((t - base) / (2 * .pi)).rounded()
    }

    mutating func arc(_ wR: CGFloat, _ hR: CGFloat, _ stAng: Double, _ swAng: Double) {
        if path.isEmpty { move(current.x, current.y) }
        let rx = Double(abs(wR)), ry = Double(abs(hR))
        let t0 = Self.param(stAng, rx, ry), t1 = Self.param(stAng + swAng, rx, ry)
        let cx = Double(current.x) - rx * cos(t0), cy = Double(current.y) - ry * sin(t0)
        let endPoint = CGPoint(x: cx + rx * cos(t1), y: cy + ry * sin(t1))
        guard rx > 0.0001, ry > 0.0001, abs(swAng) > 0.0001 else { line(endPoint.x, endPoint.y); return }
        let tiny = (t1 > t0 ? 1.0 : -1.0) * min(0.02, abs(t1 - t0) / 4)
        note(towards: CGPoint(x: cx + rx * cos(t0 + tiny), y: cy + ry * sin(t0 + tiny)))
        beforeLast = CGPoint(x: cx + rx * cos(t1 - tiny), y: cy + ry * sin(t1 - tiny))
        let transform = CGAffineTransform(translationX: CGFloat(cx), y: CGFloat(cy)).scaledBy(x: CGFloat(rx), y: CGFloat(ry))
        path.addRelativeArc(center: .zero, radius: 1, startAngle: CGFloat(t0), delta: CGFloat(t1 - t0), transform: transform)
        current = endPoint
    }

    mutating func close() {
        guard !path.isEmpty else { return }
        path.closeSubpath()
        closed = true
        if let first { current = first }
    }

    mutating func polygon(_ pts: [(CGFloat, CGFloat)]) {
        guard let p0 = pts.first else { return }
        move(p0.0, p0.1)
        for p in pts.dropFirst() { line(p.0, p.1) }
        close()
    }

    mutating func ellipse(_ rect: CGRect) {
        move(rect.minX, rect.midY)
        arc(rect.width / 2, rect.height / 2, 180, 360)
        close()
    }

    func make(fill: Bool = true, stroke: Bool = true, shade: String = "norm", evenOdd: Bool = false) -> PPTXPath {
        var p = PPTXPath(path: path.copy() ?? path, fill: fill, stroke: stroke, evenOdd: evenOdd, shade: shade)
        if !closed, let first, let firstNext { p.start = (first, firstNext) }
        if !closed, let beforeLast { p.end = (current, beforeLast) }
        return p
    }
}

// MARK: - Guide formulas

/// Evaluates DrawingML shape guides ("*/ w adj 100000", "pin 0 adj 50000", ...).
struct PPTXGuides {
    private(set) var vars: [String: Double]

    /// Built-in values for a shape of `w` × `h` (in whatever unit the caller uses).
    init(w: Double, h: Double) {
        let ss = min(w, h), ls = max(w, h)
        vars = ["w": w, "h": h, "l": 0, "t": 0, "r": w, "b": h, "hc": w / 2, "vc": h / 2, "ss": ss, "ls": ls,
                "cd2": 10_800_000, "cd4": 5_400_000, "cd8": 2_700_000, "3cd4": 16_200_000, "3cd8": 8_100_000,
                "5cd8": 13_500_000, "7cd8": 18_900_000]
        for d in [2, 3, 4, 5, 6, 8, 10, 12, 16, 32] {
            vars["wd\(d)"] = w / Double(d)
            vars["hd\(d)"] = h / Double(d)
            vars["ssd\(d)"] = ss / Double(d)
        }
    }

    func value(_ token: String) -> Double {
        if let v = vars[token] { return v }
        return Double(token) ?? 0
    }

    subscript(_ name: String) -> Double? { vars[name] }

    /// Evaluates one formula and stores it under `name`.
    mutating func define(_ name: String, _ fmla: String) {
        vars[name] = evaluate(fmla)
    }

    func evaluate(_ fmla: String) -> Double {
        let p = fmla.split(separator: " ").map(String.init)
        guard let op = p.first else { return 0 }
        func a(_ i: Int) -> Double { i < p.count ? value(p[i]) : 0 }
        let deg = { (v: Double) in v / 60000 * .pi / 180 }
        switch op {
        case "val": return a(1)
        case "*/": return a(3) == 0 ? 0 : a(1) * a(2) / a(3)
        case "+-": return a(1) + a(2) - a(3)
        case "+/": return a(3) == 0 ? 0 : (a(1) + a(2)) / a(3)
        case "?:": return a(1) > 0 ? a(2) : a(3)
        case "abs": return abs(a(1))
        case "at2": return atan2(a(2), a(1)) * 180 / .pi * 60000
        case "cat2": return a(1) * cos(atan2(a(3), a(2)))
        case "sat2": return a(1) * sin(atan2(a(3), a(2)))
        case "cos": return a(1) * cos(deg(a(2)))
        case "sin": return a(1) * sin(deg(a(2)))
        case "tan": return a(1) * tan(deg(a(2)))
        case "max": return max(a(1), a(2))
        case "min": return min(a(1), a(2))
        case "mod": return (a(1) * a(1) + a(2) * a(2) + a(3) * a(3)).squareRoot()
        case "pin": return a(2) < a(1) ? a(1) : (a(2) > a(3) ? a(3) : a(2))
        case "sqrt": return max(0, a(1)).squareRoot()
        default: return Double(op) ?? 0
        }
    }
}

// MARK: - Shapes

enum PPTXShapes {
    /// Adjust values from `a:avLst` ("adj" → 16667 from `val 16667`).
    static func adjustments(_ avLst: PPTXNode?, guides: PPTXGuides? = nil) -> [String: Double] {
        var out: [String: Double] = [:]
        let g = guides ?? PPTXGuides(w: 0, h: 0)
        for gd in avLst?.all("a:gd") ?? [] {
            guard let name = gd["name"], let f = gd["fmla"] else { continue }
            out[name] = g.evaluate(f)
        }
        return out
    }

    /// The outline of `a:prstGeom` or `a:custGeom` for a shape of w × h points (EMU sizes for custom guides).
    static func geometry(of spPr: PPTXNode?, w: CGFloat, h: CGFloat, defaultPreset: String = "rect") -> PPTXGeometry {
        if let cust = spPr?.child("a:custGeom"), let g = custom(cust, w: w, h: h) { return g }
        let prst = spPr?.child("a:prstGeom")
        let name = prst?["prst"] ?? defaultPreset
        return preset(name, w: w, h: h, adj: adjustments(prst?.child("a:avLst")))
    }

    // MARK: Custom geometry

    static func custom(_ cust: PPTXNode, w: CGFloat, h: CGFloat) -> PPTXGeometry? {
        // Guides work in EMU, the unit the coordinates are written in.
        let W = Double(w) * 12700, H = Double(h) * 12700
        var g = PPTXGuides(w: W, h: H)
        for gd in cust.child("a:avLst")?.all("a:gd") ?? [] { if let n = gd["name"], let f = gd["fmla"] { g.define(n, f) } }
        for gd in cust.child("a:gdLst")?.all("a:gd") ?? [] { if let n = gd["name"], let f = gd["fmla"] { g.define(n, f) } }

        var paths: [PPTXPath] = []
        for p in cust.child("a:pathLst")?.all("a:path") ?? [] {
            let pw = p.double("w") ?? 0, ph = p.double("h") ?? 0
            let sx = pw > 0 ? W / pw / 12700 : 1 / 12700.0
            let sy = ph > 0 ? H / ph / 12700 : 1 / 12700.0
            var b = PPTXPathBuilder()
            func pt(_ n: PPTXNode?) -> (CGFloat, CGFloat) {
                guard let n else { return (0, 0) }
                return (CGFloat(g.value(n["x"] ?? "0") * sx), CGFloat(g.value(n["y"] ?? "0") * sy))
            }
            for cmd in p.children {
                switch cmd.name {
                case "a:moveTo": let q = pt(cmd.child("a:pt")); b.move(q.0, q.1)
                case "a:lnTo": let q = pt(cmd.child("a:pt")); b.line(q.0, q.1)
                case "a:cubicBezTo":
                    let pts = cmd.all("a:pt").map(pt)
                    if pts.count == 3 { b.cubic(pts[0].0, pts[0].1, pts[1].0, pts[1].1, pts[2].0, pts[2].1) }
                case "a:quadBezTo":
                    let pts = cmd.all("a:pt").map(pt)
                    if pts.count == 2 { b.quad(pts[0].0, pts[0].1, pts[1].0, pts[1].1) }
                case "a:arcTo":
                    b.arc(CGFloat(g.value(cmd["wR"] ?? "0") * sx), CGFloat(g.value(cmd["hR"] ?? "0") * sy),
                          g.value(cmd["stAng"] ?? "0") / 60000, g.value(cmd["swAng"] ?? "0") / 60000)
                case "a:close": b.close()
                default: break
                }
            }
            guard !b.path.isEmpty else { continue }
            let fillMode = p["fill"] ?? "norm"
            paths.append(b.make(fill: fillMode != "none", stroke: p.bool("stroke") ?? true,
                                shade: fillMode == "none" ? "norm" : fillMode))
        }
        guard !paths.isEmpty else { return nil }
        var textRect = CGRect(x: 0, y: 0, width: w, height: h)
        if let r = cust.child("a:rect") {
            let l = g.value(r["l"] ?? "l") / 12700, t = g.value(r["t"] ?? "t") / 12700
            let rr = g.value(r["r"] ?? "r") / 12700, bb = g.value(r["b"] ?? "b") / 12700
            if rr > l, bb > t { textRect = CGRect(x: l, y: t, width: rr - l, height: bb - t) }
        }
        return PPTXGeometry(paths: paths, textRect: textRect)
    }

    // MARK: Presets

    /// Every preset with its own drawing below; anything else falls back to a rectangle.
    static let known: [String] = [
        "rect", "roundRect", "ellipse", "triangle", "rtTriangle", "diamond", "parallelogram", "trapezoid", "pentagon",
        "hexagon", "heptagon", "octagon", "decagon", "dodecagon", "chevron", "homePlate", "rightArrow", "leftArrow",
        "upArrow", "downArrow", "leftRightArrow", "upDownArrow", "notchedRightArrow", "stripedRightArrow", "quadArrow",
        "leftRightUpArrow", "bentArrow", "uturnArrow", "line", "lineInv", "straightConnector1", "bentConnector2",
        "bentConnector3", "bentConnector4", "bentConnector5", "curvedConnector2", "curvedConnector3", "curvedConnector4",
        "curvedConnector5", "star4", "star5", "star6", "star7", "star8", "star10", "star12", "star16", "star24", "star32",
        "irregularSeal1", "irregularSeal2", "plus", "cross", "mathPlus", "mathMinus", "mathMultiply", "mathEqual",
        "mathDivide", "mathNotEqual", "donut", "noSmoking", "frame", "halfFrame", "corner", "diagStripe", "can", "cube",
        "bevel", "foldedCorner", "heart", "lightningBolt", "moon", "smileyFace", "sun", "cloud", "cloudCallout",
        "wedgeRectCallout", "wedgeRoundRectCallout", "wedgeEllipseCallout", "callout1", "callout2", "callout3",
        "borderCallout1", "borderCallout2", "borderCallout3", "accentCallout1", "accentCallout2", "accentCallout3",
        "accentBorderCallout1", "accentBorderCallout2", "accentBorderCallout3", "snip1Rect", "snip2SameRect",
        "snip2DiagRect", "snipRoundRect", "round1Rect", "round2SameRect", "round2DiagRect", "plaque", "teardrop", "pie",
        "pieWedge", "arc", "chord", "blockArc", "leftBracket", "rightBracket", "bracketPair", "leftBrace", "rightBrace",
        "bracePair", "wave", "doubleWave", "verticalScroll", "horizontalScroll", "flowChartProcess",
        "flowChartAlternateProcess", "flowChartDecision", "flowChartInputOutput", "flowChartPredefinedProcess",
        "flowChartInternalStorage", "flowChartDocument", "flowChartMultidocument", "flowChartTerminator",
        "flowChartPreparation", "flowChartManualInput", "flowChartManualOperation", "flowChartConnector",
        "flowChartOffpageConnector", "flowChartPunchedCard", "flowChartPunchedTape", "flowChartSummingJunction",
        "flowChartOr", "flowChartCollate", "flowChartSort", "flowChartExtract", "flowChartMerge",
        "flowChartOfflineStorage", "flowChartOnlineStorage", "flowChartMagneticTape", "flowChartMagneticDisk",
        "flowChartMagneticDrum", "flowChartDisplay", "flowChartDelay", "actionButtonBlank", "funnel", "gear6", "gear9",
        "ribbon", "ribbon2", "ellipseRibbon", "ellipseRibbon2", "chartPlus", "chartX", "chartStar", "squareTabs",
        "plaqueTabs", "cornerTabs",
    ]

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func preset(_ name: String, w: CGFloat, h: CGFloat, adj: [String: Double]) -> PPTXGeometry {
        let W = max(w, 0.01), H = max(h, 0.01)
        let ss = min(W, H)
        let hc = W / 2, vc = H / 2
        func av(_ key: String, _ def: Double) -> CGFloat {
            CGFloat(adj[key] ?? (key == "adj1" ? adj["adj"] : key == "adj" ? adj["adj1"] : nil) ?? def)
        }
        func pin(_ lo: CGFloat, _ v: CGFloat, _ hi: CGFloat) -> CGFloat { max(lo, min(hi, v)) }
        var b = PPTXPathBuilder()
        var paths: [PPTXPath] = []
        var text = CGRect(x: 0, y: 0, width: W, height: H)
        func done() { if !b.path.isEmpty { paths.append(b.make()) }; b = PPTXPathBuilder() }
        func add(_ p: PPTXPath) { paths.append(p) }
        func tr(_ l: CGFloat, _ t: CGFloat, _ r: CGFloat, _ bt: CGFloat) {
            if r > l, bt > t { text = CGRect(x: l, y: t, width: r - l, height: bt - t) }
        }
        func roundedRect(tl: CGFloat, tr rtr: CGFloat, br: CGFloat, bl: CGFloat, snip: Set<Int> = []) {
            // Corners clockwise from top-left; a corner in `snip` is cut instead of rounded.
            let r = [tl, rtr, br, bl].map { max(0, min($0, ss / 2)) }
            b.move(0, r[0])
            if snip.contains(0) { b.line(r[0], 0) } else { b.arc(r[0], r[0], 180, 90) }
            b.line(W - r[1], 0)
            if snip.contains(1) { b.line(W, r[1]) } else { b.arc(r[1], r[1], 270, 90) }
            b.line(W, H - r[2])
            if snip.contains(2) { b.line(W - r[2], H) } else { b.arc(r[2], r[2], 0, 90) }
            b.line(r[3], H)
            if snip.contains(3) { b.line(0, H - r[3]) } else { b.arc(r[3], r[3], 90, 90) }
            b.close()
        }
        func regular(_ n: Int, rx: CGFloat, ry: CGFloat, cx: CGFloat, cy: CGFloat, start: Double = -90) {
            var pts: [(CGFloat, CGFloat)] = []
            for k in 0..<n {
                let t = (start + Double(k) * 360 / Double(n)) * .pi / 180
                pts.append((cx + rx * CGFloat(cos(t)), cy + ry * CGFloat(sin(t))))
            }
            b.polygon(pts)
        }
        func star(_ n: Int, inner: CGFloat, rx: CGFloat, ry: CGFloat, cx: CGFloat, cy: CGFloat) {
            var pts: [(CGFloat, CGFloat)] = []
            for k in 0..<(2 * n) {
                let t = (-90 + Double(k) * 180 / Double(n)) * .pi / 180
                let f = k % 2 == 0 ? 1 : inner
                pts.append((cx + rx * f * CGFloat(cos(t)), cy + ry * f * CGFloat(sin(t))))
            }
            b.polygon(pts)
            tr(cx - rx * inner * 0.8, cy - ry * inner * 0.8, cx + rx * inner * 0.8, cy + ry * inner * 0.8)
        }
        func ellipsePoint(_ deg: Double, rx: CGFloat, ry: CGFloat, cx: CGFloat, cy: CGFloat) -> (CGFloat, CGFloat) {
            let t = deg * .pi / 180
            let p = atan2(Double(rx) * sin(t), Double(ry) * cos(t))
            return (cx + rx * CGFloat(cos(p)), cy + ry * CGFloat(sin(p)))
        }
        func scaled(_ pts: [(CGFloat, CGFloat)], _ unit: CGFloat) -> [(CGFloat, CGFloat)] {
            pts.map { ($0.0 * W / unit, $0.1 * H / unit) }
        }
        func openLine(_ pts: [(CGFloat, CGFloat)]) {
            guard let p0 = pts.first else { return }
            b.move(p0.0, p0.1)
            for p in pts.dropFirst() { b.line(p.0, p.1) }
            paths.append(b.make(fill: false)); b = PPTXPathBuilder()
        }
        func wedgeTip(_ dxDef: Double, _ dyDef: Double) -> (CGFloat, CGFloat) {
            (hc + W * av("adj1", dxDef) / 100000, vc + H * av("adj2", dyDef) / 100000)
        }
        func calloutLines(_ count: Int, accent: Bool) {
            let defs: [[Double]] = [[18750, -8333, 112500, -38333],
                                    [18750, -8333, 18750, -16667, 112500, -46667],
                                    [18750, -8333, 18750, -16667, 100000, -16667, 112963, -8333]]
            let d = defs[count - 1]
            var pts: [(CGFloat, CGFloat)] = []
            for i in stride(from: 0, to: d.count, by: 2) {
                let y = H * av("adj\(i + 1)", d[i]) / 100000, x = W * av("adj\(i + 2)", d[i + 1]) / 100000
                pts.append((x, y))
            }
            if accent, let p0 = pts.first { openLine([(p0.0, 0), (p0.0, H)]) }
            openLine(pts)
        }

        switch name {
        case "rect", "flowChartProcess", "actionButtonBlank":
            b.polygon([(0, 0), (W, 0), (W, H), (0, H)])
        case "roundRect":
            let r = ss * pin(0, av("adj", 16667), 50000) / 100000
            roundedRect(tl: r, tr: r, br: r, bl: r)
            let il = r * 0.29289; tr(il, il, W - il, H - il)
        case "flowChartAlternateProcess":
            let r = ss / 6
            roundedRect(tl: r, tr: r, br: r, bl: r)
            let il = r * 0.29289; tr(il, il, W - il, H - il)
        case "ellipse", "flowChartConnector":
            b.ellipse(CGRect(x: 0, y: 0, width: W, height: H))
            let dx = hc * 0.70711, dy = vc * 0.70711; tr(hc - dx, vc - dy, hc + dx, vc + dy)
        case "triangle", "flowChartExtract":
            let a = name == "triangle" ? pin(0, av("adj", 50000), 100000) : 50000
            let x = W * a / 100000
            b.polygon([(0, H), (x, 0), (W, H)])
            let x1 = W * a / 200000; tr(x1, vc, x1 + hc, H)
        case "flowChartMerge":
            b.polygon([(0, 0), (W, 0), (hc, H)]); tr(W / 4, 0, W * 3 / 4, vc)
        case "rtTriangle":
            b.polygon([(0, 0), (W, H), (0, H)]); tr(W / 12, H * 7 / 12, W * 7 / 12, H * 11 / 12)
        case "diamond", "flowChartDecision":
            b.polygon([(0, vc), (hc, 0), (W, vc), (hc, H)]); tr(W / 4, H / 4, W * 3 / 4, H * 3 / 4)
        case "flowChartSort":
            b.polygon([(0, vc), (hc, 0), (W, vc), (hc, H)]); done()
            b.move(0, vc); b.line(W, vc); add(b.make(fill: false)); b = PPTXPathBuilder()
            tr(W / 4, H / 4, W * 3 / 4, H * 3 / 4)
        case "parallelogram", "flowChartInputOutput":
            let x2 = name == "parallelogram" ? ss * pin(0, av("adj", 25000), 100000 * W / ss) / 100000 : W / 5
            b.polygon([(0, H), (x2, 0), (W, 0), (W - x2, H)]); tr(x2 / 2, 0, W - x2 / 2, H)
        case "trapezoid":
            let maxA = 50000 * W / ss, a = pin(0, av("adj", 25000), maxA)
            let x2 = ss * a / 100000
            b.polygon([(0, H), (x2, 0), (W - x2, 0), (W, H)])
            let il = W / 3 * a / maxA, it = H / 3 * a / maxA; tr(il, it, W - il, H)
        case "flowChartManualOperation":
            b.polygon([(0, 0), (W, 0), (W * 4 / 5, H), (W / 5, H)]); tr(W / 5, 0, W * 4 / 5, H)
        case "pentagon":
            b.polygon([(hc, 0), (W, H * 0.38197), (W * 0.80902, H), (W * 0.19098, H), (0, H * 0.38197)])
            tr(W * 0.19098, H * 0.38197, W * 0.80902, H)
        case "hexagon":
            let x1 = ss * pin(0, av("adj", 25000), 50000 * W / ss) / 100000
            b.polygon([(0, vc), (x1, 0), (W - x1, 0), (W, vc), (W - x1, H), (x1, H)]); tr(x1 / 2, H * 0.1, W - x1 / 2, H * 0.9)
        case "flowChartPreparation":
            let x1 = W / 5
            b.polygon([(0, vc), (x1, 0), (W - x1, 0), (W, vc), (W - x1, H), (x1, H)]); tr(x1, 0, W - x1, H)
        case "heptagon":
            regular(7, rx: hc, ry: vc, cx: hc, cy: vc)
            tr(W * 0.15, H * 0.2, W * 0.85, H * 0.85)
        case "octagon":
            let x1 = ss * pin(0, av("adj", 29289), 50000) / 100000
            b.polygon([(0, x1), (x1, 0), (W - x1, 0), (W, x1), (W, H - x1), (W - x1, H), (x1, H), (0, H - x1)])
            tr(x1 / 2, x1 / 2, W - x1 / 2, H - x1 / 2)
        case "decagon":
            regular(10, rx: hc * 1.05146, ry: vc, cx: hc, cy: vc, start: 0); tr(W * 0.1, H * 0.15, W * 0.9, H * 0.85)
        case "dodecagon":
            regular(12, rx: hc * 1.03528, ry: vc * 1.03528, cx: hc, cy: vc, start: -75); tr(W * 0.1, H * 0.1, W * 0.9, H * 0.9)
        case "chevron":
            let x2 = ss * pin(0, av("adj", 50000), 100000 * W / ss) / 100000, x3 = W - x2
            b.polygon([(0, 0), (x3, 0), (W, vc), (x3, H), (0, H), (x2, vc)])
            if x3 > x2 { tr(x2, 0, x3, H) }
        case "homePlate":
            let dx1 = ss * pin(0, av("adj", 50000), 100000 * W / ss) / 100000, x1 = W - dx1
            b.polygon([(0, 0), (x1, 0), (W, vc), (x1, H), (0, H)]); tr(0, 0, (x1 + W) / 2, H)
        case "rightArrow", "leftArrow", "notchedRightArrow", "stripedRightArrow":
            let a1 = pin(0, av("adj1", 50000), 100000), a2 = pin(0, av("adj2", 50000), 100000 * W / ss)
            let dx1 = ss * a2 / 100000, dy1 = H * a1 / 200000
            let y1 = vc - dy1, y2 = vc + dy1
            var x1 = W - dx1
            var pts: [(CGFloat, CGFloat)]
            if name == "stripedRightArrow" {
                let s = ss / 8
                b.polygon([(0, y1), (s / 4, y1), (s / 4, y2), (0, y2)]); done()
                b.polygon([(s / 2, y1), (s, y1), (s, y2), (s / 2, y2)]); done()
                x1 = max(x1, s * 1.25)
                pts = [(s * 1.25, y1), (x1, y1), (x1, 0), (W, vc), (x1, H), (x1, y2), (s * 1.25, y2)]
            } else {
                pts = [(0, y1), (x1, y1), (x1, 0), (W, vc), (x1, H), (x1, y2), (0, y2)]
                if name == "notchedRightArrow" { pts.append((dy1 * dx1 / vc, vc)) }
            }
            if name == "leftArrow" { pts = pts.map { (W - $0.0, $0.1) } }
            b.polygon(pts)
            let dx2 = y1 * dx1 / vc
            if name == "leftArrow" { tr(W - x1 - dx2, y1, W, y2) } else { tr(0, y1, x1 + dx2, y2) }
        case "upArrow", "downArrow":
            let a1 = pin(0, av("adj1", 50000), 100000), a2 = pin(0, av("adj2", 50000), 100000 * H / ss)
            let dy1 = ss * a2 / 100000, dx1 = W * a1 / 200000
            let x1 = hc - dx1, x2 = hc + dx1
            var pts: [(CGFloat, CGFloat)] = [(0, dy1), (hc, 0), (W, dy1), (x2, dy1), (x2, H), (x1, H), (x1, dy1)]
            if name == "downArrow" { pts = pts.map { ($0.0, H - $0.1) } }
            b.polygon(pts)
            if name == "downArrow" { tr(x1, 0, x2, H - dy1 * 0.5) } else { tr(x1, dy1 * 0.5, x2, H) }
        case "leftRightArrow":
            let a1 = pin(0, av("adj1", 50000), 100000), a2 = pin(0, av("adj2", 50000), 50000 * W / ss)
            let x2 = ss * a2 / 100000, x3 = W - x2, dy = H * a1 / 200000
            b.polygon([(0, vc), (x2, 0), (x2, vc - dy), (x3, vc - dy), (x3, 0), (W, vc), (x3, H), (x3, vc + dy),
                       (x2, vc + dy), (x2, H)])
            tr(x2 / 2, vc - dy, W - x2 / 2, vc + dy)
        case "upDownArrow":
            let a1 = pin(0, av("adj1", 50000), 100000), a2 = pin(0, av("adj2", 50000), 50000 * H / ss)
            let y2 = ss * a2 / 100000, y3 = H - y2, dx = W * a1 / 200000
            b.polygon([(hc, 0), (W, y2), (hc + dx, y2), (hc + dx, y3), (W, y3), (hc, H), (0, y3), (hc - dx, y3),
                       (hc - dx, y2), (0, y2)])
            tr(hc - dx, y2 / 2, hc + dx, H - y2 / 2)
        case "quadArrow", "leftRightUpArrow":
            let a1 = av("adj1", 22500), a2 = av("adj2", 22500), a3 = av("adj3", 22500)
            let dx2 = ss * a2 / 200000, dx3 = ss * a1 / 200000, head = ss * a3 / 100000
            var pts: [(CGFloat, CGFloat)] = [(0, vc), (head, vc - dx2), (head, vc - dx3), (hc - dx3, vc - dx3),
                                              (hc - dx3, head), (hc - dx2, head), (hc, 0), (hc + dx2, head),
                                              (hc + dx3, head), (hc + dx3, vc - dx3), (W - head, vc - dx3),
                                              (W - head, vc - dx2), (W, vc), (W - head, vc + dx2), (W - head, vc + dx3)]
            if name == "quadArrow" {
                pts += [(hc + dx3, vc + dx3), (hc + dx3, H - head), (hc + dx2, H - head), (hc, H), (hc - dx2, H - head),
                        (hc - dx3, H - head), (hc - dx3, vc + dx3)]
            } else {
                pts += [(head, vc + dx3)]
            }
            pts += [(head, vc + dx3), (head, vc + dx2)]
            b.polygon(pts)
        case "bentArrow":
            let a1 = av("adj1", 25000), a2 = av("adj2", 25000), a3 = av("adj3", 25000), a4 = av("adj4", 43750)
            let th = ss * a1 / 100000, aw2 = ss * a2 / 100000, ah = ss * a3 / 100000, rr = ss * a4 / 100000
            let y3 = aw2, x3 = W - ah, shaftTop = aw2 - th / 2
            let ro = max(rr, th), ri = max(0, ro - th)
            b.move(0, H); b.line(0, shaftTop + ro); b.arc(ro, ro, 180, 90); b.line(x3, shaftTop); b.line(x3, 0)
            b.line(W, y3); b.line(x3, 2 * aw2); b.line(x3, shaftTop + th); b.line(th + ri, shaftTop + th)
            if ri > 0 { b.arc(ri, ri, 270, -90) } else { b.line(th, shaftTop + th) }
            b.line(th, H); b.close()
        case "uturnArrow":
            // Shaft up the left, a bend of radius adj4 over the top, and the head pointing down on the right.
            let th = ss * av("adj1", 25000) / 100000, aw = ss * av("adj2", 25000) / 100000
            let ah = ss * av("adj3", 25000) / 100000, y4 = max(ah + th, H * av("adj5", 75000) / 100000)
            let xc = W - aw, xR = min(W, xc + th / 2)
            let ro = max(th, min(ss * av("adj4", 43750) / 100000, xR / 2, y4 - ah)), ri = ro - th
            b.move(0, H); b.line(0, ro); b.arc(ro, ro, 180, 90); b.line(xR - ro, 0); b.arc(ro, ro, 270, 90)
            b.line(xR, y4 - ah); b.line(W, y4 - ah); b.line(xc, y4); b.line(xc - aw, y4 - ah); b.line(xR - th, y4 - ah)
            b.line(xR - th, ro)
            if ri > 0 { b.arc(ri, ri, 0, -90) } else { b.line(xR - th, th) }
            b.line(ro, th)
            if ri > 0 { b.arc(ri, ri, 270, -90) } else { b.line(th, th) }
            b.line(th, H); b.close()
        case "line", "straightConnector1":
            openLine([(0, 0), (W, H)])
        case "lineInv":
            openLine([(0, H), (W, 0)])
        case "bentConnector2":
            openLine([(0, 0), (W, 0), (W, H)])
        case "bentConnector3":
            let x1 = W * av("adj1", 50000) / 100000
            openLine([(0, 0), (x1, 0), (x1, H), (W, H)])
        case "bentConnector4":
            let x1 = W * av("adj1", 50000) / 100000, y2 = H * av("adj2", 50000) / 100000
            openLine([(0, 0), (x1, 0), (x1, y2), (W, y2), (W, H)])
        case "bentConnector5":
            let x1 = W * av("adj1", 50000) / 100000, y2 = H * av("adj2", 50000) / 100000
            let x3 = W * av("adj3", 50000) / 100000
            openLine([(0, 0), (x1, 0), (x1, y2), (x3, y2), (x3, H), (W, H)])
        case "curvedConnector2":
            b.move(0, 0); b.cubic(hc, 0, W, vc, W, H); add(b.make(fill: false)); b = PPTXPathBuilder()
        case "curvedConnector3":
            let x2 = W * av("adj1", 50000) / 100000, x1 = x2 / 2, x3 = (W + x2) / 2
            b.move(0, 0); b.cubic(x1, 0, x2, H / 4, x2, vc); b.cubic(x2, H * 3 / 4, x3, H, W, H)
            add(b.make(fill: false)); b = PPTXPathBuilder()
        case "curvedConnector4", "curvedConnector5":
            let x2 = W * av("adj1", 50000) / 100000, y4 = H * av("adj2", 50000) / 100000
            b.move(0, 0); b.cubic(x2 / 2, 0, x2, y4 / 4, x2, y4 / 2)
            b.cubic(x2, y4, (x2 + W) / 2, y4, (x2 + W) / 2 + (W - x2) / 4, y4)
            b.cubic(W, y4, W, (y4 + H) / 2, W, H)
            add(b.make(fill: false)); b = PPTXPathBuilder()
        case "star4": star(4, inner: av("adj", 12500) / 50000, rx: hc, ry: vc, cx: hc, cy: vc)
        case "star5":
            let rx = W / 1.90211, ry = H / 1.80902
            star(5, inner: av("adj", 19098) / 50000, rx: rx, ry: ry, cx: hc, cy: ry)
        case "star6": star(6, inner: av("adj", 28868) / 50000, rx: hc * 1.1547, ry: vc, cx: hc, cy: vc)
        case "star7": star(7, inner: av("adj", 34601) / 50000, rx: hc * 1.02572, ry: vc * 1.0521, cx: hc, cy: vc * 1.0521)
        case "star8": star(8, inner: av("adj", 38250) / 50000, rx: hc, ry: vc, cx: hc, cy: vc)
        case "star10": star(10, inner: av("adj", 42533) / 50000, rx: hc * 1.05146, ry: vc, cx: hc, cy: vc)
        case "star12": star(12, inner: av("adj", 37500) / 50000, rx: hc, ry: vc, cx: hc, cy: vc)
        case "star16": star(16, inner: av("adj", 37500) / 50000, rx: hc, ry: vc, cx: hc, cy: vc)
        case "star24": star(24, inner: av("adj", 37500) / 50000, rx: hc, ry: vc, cx: hc, cy: vc)
        case "star32": star(32, inner: av("adj", 37500) / 50000, rx: hc, ry: vc, cx: hc, cy: vc)
        case "irregularSeal1":
            b.polygon(scaled([(10800, 5800), (14522, 0), (14155, 5325), (18380, 4457), (16702, 7315), (21097, 8137),
                              (17607, 10475), (21600, 13290), (16837, 12942), (18145, 18095), (14020, 14457),
                              (13247, 19737), (10532, 14935), (8485, 21600), (7715, 15627), (4762, 17617),
                              (5667, 13937), (135, 14587), (3722, 11775), (0, 8615), (4627, 7617), (370, 2295),
                              (7312, 6320), (8352, 2295)], 21600))
            tr(W * 0.2, H * 0.3, W * 0.75, H * 0.7)
        case "irregularSeal2":
            b.polygon(scaled([(11462, 4342), (14790, 0), (14525, 5777), (18007, 3172), (16380, 6532), (21600, 6645),
                              (16985, 9402), (18270, 11290), (16380, 12310), (18877, 15632), (14640, 14350),
                              (14942, 17370), (12180, 15935), (11612, 18842), (9872, 17370), (8700, 19712),
                              (7527, 18125), (4917, 21600), (4805, 18240), (1285, 17825), (3330, 15370),
                              (0, 12877), (3935, 11592), (1172, 8270), (5372, 7817), (4502, 3625), (8550, 6382),
                              (9722, 1887)], 21600))
            tr(W * 0.25, H * 0.3, W * 0.75, H * 0.7)
        case "plus", "cross":
            let x1 = ss * pin(0, av("adj", 25000), 50000) / 100000, x2 = W - x1, y2 = H - x1
            b.polygon([(0, x1), (x1, x1), (x1, 0), (x2, 0), (x2, x1), (W, x1), (W, y2), (x2, y2), (x2, H), (x1, H),
                       (x1, y2), (0, y2)])
            tr(0, x1, W, y2)
        case "chartPlus":
            b.polygon([(0, 0), (W, 0), (W, H), (0, H)]); add(b.make(stroke: false)); b = PPTXPathBuilder()
            openLine([(hc, 0), (hc, H)]); openLine([(0, vc), (W, vc)])
        case "chartX":
            b.polygon([(0, 0), (W, 0), (W, H), (0, H)]); add(b.make(stroke: false)); b = PPTXPathBuilder()
            openLine([(0, 0), (W, H)]); openLine([(0, H), (W, 0)])
        case "chartStar":
            b.polygon([(0, 0), (W, 0), (W, H), (0, H)]); add(b.make(stroke: false)); b = PPTXPathBuilder()
            openLine([(0, 0), (W, H)]); openLine([(0, H), (W, 0)]); openLine([(hc, 0), (hc, H)])
        case "mathPlus":
            let a1 = pin(0, av("adj1", 23520), 73490)
            let dx1 = W * 73490 / 200000, dy1 = H * 73490 / 200000, dx2 = ss * a1 / 200000
            b.polygon([(hc - dx1, vc - dx2), (hc - dx2, vc - dx2), (hc - dx2, vc - dy1), (hc + dx2, vc - dy1),
                       (hc + dx2, vc - dx2), (hc + dx1, vc - dx2), (hc + dx1, vc + dx2), (hc + dx2, vc + dx2),
                       (hc + dx2, vc + dy1), (hc - dx2, vc + dy1), (hc - dx2, vc + dx2), (hc - dx1, vc + dx2)])
        case "mathMinus":
            let dy1 = H * pin(0, av("adj1", 23520), 100000) / 200000, dx1 = W * 73490 / 200000
            b.polygon([(hc - dx1, vc - dy1), (hc + dx1, vc - dy1), (hc + dx1, vc + dy1), (hc - dx1, vc + dy1)])
        case "mathEqual", "mathNotEqual":
            let dy1 = H * av("adj1", 23520) / 100000, dy2 = H * av("adj2", 11760) / 200000, dx1 = W * 73490 / 200000
            b.polygon([(hc - dx1, vc - dy2 - dy1), (hc + dx1, vc - dy2 - dy1), (hc + dx1, vc - dy2), (hc - dx1, vc - dy2)]); done()
            b.polygon([(hc - dx1, vc + dy2), (hc + dx1, vc + dy2), (hc + dx1, vc + dy2 + dy1), (hc - dx1, vc + dy2 + dy1)])
            if name == "mathNotEqual" {
                done()
                let t = dy1 / 2
                b.polygon([(hc + dx1 * 0.35 - t, vc - dy2 - dy1 * 2.2), (hc + dx1 * 0.35 + t, vc - dy2 - dy1 * 2.2),
                           (hc - dx1 * 0.35 + t, vc + dy2 + dy1 * 2.2), (hc - dx1 * 0.35 - t, vc + dy2 + dy1 * 2.2)])
            }
        case "mathDivide":
            let dy1 = H * av("adj1", 23520) / 200000, gap = H * av("adj2", 5880) / 100000
            let rad = H * av("adj3", 11760) / 100000, dx1 = W * 73490 / 200000
            b.polygon([(hc - dx1, vc - dy1), (hc + dx1, vc - dy1), (hc + dx1, vc + dy1), (hc - dx1, vc + dy1)]); done()
            b.ellipse(CGRect(x: hc - rad, y: vc - dy1 - gap - 2 * rad, width: 2 * rad, height: 2 * rad)); done()
            b.ellipse(CGRect(x: hc - rad, y: vc + dy1 + gap, width: 2 * rad, height: 2 * rad))
        case "mathMultiply":
            let t = ss * pin(0, av("adj1", 23520), 51965) / 100000 / 2
            let k: CGFloat = 0.15
            func bar(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
                let dx = x1 - x0, dy = y1 - y0, len = max(0.001, (dx * dx + dy * dy).squareRoot())
                let nx = -dy / len * t, ny = dx / len * t
                b.polygon([(x0 + nx, y0 + ny), (x1 + nx, y1 + ny), (x1 - nx, y1 - ny), (x0 - nx, y0 - ny)]); done()
            }
            bar(W * k, H * k, W * (1 - k), H * (1 - k)); bar(W * (1 - k), H * k, W * k, H * (1 - k))
        case "donut", "noSmoking":
            let dr = ss * pin(0, av("adj", name == "donut" ? 25000 : 18750), 50000) / 100000
            b.ellipse(CGRect(x: 0, y: 0, width: W, height: H))
            b.move(dr, vc); b.arc(hc - dr, vc - dr, 180, -360); b.close()
            if name == "noSmoking" {
                // The bar across, inside the ring.
                let rx = hc - dr, ry = vc - dr, t = dr / 2
                let a = atan2(Double(H), Double(W))
                let ux = CGFloat(cos(a)) * rx, uy = CGFloat(sin(a)) * ry
                let nx = -CGFloat(sin(a)) * t, ny = CGFloat(cos(a)) * t
                paths.append(b.make(evenOdd: true)); b = PPTXPathBuilder()
                b.polygon([(hc - ux + nx, vc - uy + ny), (hc + ux + nx, vc + uy + ny), (hc + ux - nx, vc + uy - ny),
                           (hc - ux - nx, vc - uy - ny)])
            } else {
                paths.append(b.make(evenOdd: true)); b = PPTXPathBuilder()
            }
        case "frame":
            let x1 = ss * pin(0, av("adj1", 12500), 50000) / 100000
            b.polygon([(0, 0), (W, 0), (W, H), (0, H)])
            b.polygon([(x1, x1), (x1, H - x1), (W - x1, H - x1), (W - x1, x1)])
            paths.append(b.make(evenOdd: true)); b = PPTXPathBuilder()
            tr(x1, x1, W - x1, H - x1)
        case "halfFrame":
            let x1 = ss * av("adj2", 33333) / 100000, y1 = ss * av("adj1", 33333) / 100000
            b.polygon([(0, 0), (W, 0), (W - y1 * W / H, y1), (x1, y1), (x1, H - x1 * H / W), (0, H)])
        case "corner":
            let dy1 = ss * av("adj1", 50000) / 100000, dx1 = ss * av("adj2", 50000) / 100000
            b.polygon([(0, 0), (dx1, 0), (dx1, H - dy1), (W, H - dy1), (W, H), (0, H)])
            tr(0, H - dy1, W, H)
        case "diagStripe":
            let x2 = W * av("adj", 50000) / 100000, y2 = H * av("adj", 50000) / 100000
            b.polygon([(0, y2), (x2, 0), (W, 0), (0, H)])
        case "can", "flowChartMagneticDisk":
            let y1 = name == "can" ? ss * pin(0, av("adj", 25000), 50000 * H / ss) / 200000 : H / 6
            let y3 = H - y1
            b.move(0, y1); b.arc(hc, y1, 180, -180); b.line(W, y3); b.arc(hc, y1, 0, 180); b.close()
            add(b.make(stroke: false)); b = PPTXPathBuilder()
            b.move(0, y1); b.arc(hc, y1, 180, 180); b.arc(hc, y1, 0, 180); b.close()
            add(b.make(stroke: false, shade: name == "can" ? "lighten" : "norm")); b = PPTXPathBuilder()
            b.move(W, y1); b.arc(hc, y1, 0, 180); b.arc(hc, y1, 180, 180); b.line(W, y3); b.arc(hc, y1, 0, 180); b.line(0, y1)
            add(b.make(fill: false)); b = PPTXPathBuilder()
            tr(0, y1 * 2, W, y3)
        case "flowChartMagneticDrum":
            let x1 = W / 6, x3 = W - x1
            b.move(x1, 0); b.line(x3, 0); b.arc(x1, vc, 270, 180); b.line(x1, H); b.arc(x1, vc, 90, 180); b.close(); done()
            b.move(x3, H); b.arc(x1, vc, 90, -180); add(b.make(fill: false)); b = PPTXPathBuilder()
            tr(x1, 0, x3 - x1, H)
        case "cube":
            let y1 = ss * pin(0, av("adj", 25000), 100000) / 100000, x4 = W - y1, y4 = H - y1
            b.polygon([(0, y1), (x4, y1), (x4, H), (0, H)]); add(b.make(stroke: false)); b = PPTXPathBuilder()
            b.polygon([(0, y1), (y1, 0), (W, 0), (x4, y1)]); add(b.make(stroke: false, shade: "lightenLess")); b = PPTXPathBuilder()
            b.polygon([(x4, H), (x4, y1), (W, 0), (W, y4)]); add(b.make(stroke: false, shade: "darkenLess")); b = PPTXPathBuilder()
            b.polygon([(0, y1), (y1, 0), (W, 0), (W, y4), (x4, H), (0, H)]); add(b.make(fill: false)); b = PPTXPathBuilder()
            b.move(0, y1); b.line(x4, y1); b.line(W, 0); add(b.make(fill: false)); b = PPTXPathBuilder()
            b.move(x4, y1); b.line(x4, H); add(b.make(fill: false)); b = PPTXPathBuilder()
            tr(0, y1, x4, H)
        case "bevel":
            let x1 = ss * pin(0, av("adj", 12500), 50000) / 100000, x2 = W - x1, y2 = H - x1
            b.polygon([(x1, x1), (x2, x1), (x2, y2), (x1, y2)]); add(b.make(stroke: false)); b = PPTXPathBuilder()
            b.polygon([(0, 0), (W, 0), (x2, x1), (x1, x1)]); add(b.make(stroke: false, shade: "lightenLess")); b = PPTXPathBuilder()
            b.polygon([(0, H), (x1, y2), (x2, y2), (W, H)]); add(b.make(stroke: false, shade: "darken")); b = PPTXPathBuilder()
            b.polygon([(0, 0), (x1, x1), (x1, y2), (0, H)]); add(b.make(stroke: false, shade: "lighten")); b = PPTXPathBuilder()
            b.polygon([(W, 0), (W, H), (x2, y2), (x2, x1)]); add(b.make(stroke: false, shade: "darkenLess")); b = PPTXPathBuilder()
            b.polygon([(0, 0), (W, 0), (W, H), (0, H)]); add(b.make(fill: false)); b = PPTXPathBuilder()
            b.polygon([(x1, x1), (x2, x1), (x2, y2), (x1, y2)]); add(b.make(fill: false)); b = PPTXPathBuilder()
            tr(x1, x1, x2, y2)
        case "foldedCorner":
            let dx2 = ss * pin(0, av("adj", 16667), 50000) / 100000, x1 = W - dx2, dx3 = dx2 / 5
            let x2 = x1 + dx3, y2 = H - dx2, y1 = y2 + dx3
            b.polygon([(0, 0), (W, 0), (W, y2), (x1, H), (0, H)]); add(b.make(stroke: false)); b = PPTXPathBuilder()
            b.polygon([(x1, H), (x2, y1), (W, y2)]); add(b.make(stroke: false, shade: "darkenLess")); b = PPTXPathBuilder()
            b.move(x1, H); b.line(x2, y1); b.line(W, y2); b.line(x1, H); b.line(0, H); b.line(0, 0); b.line(W, 0); b.line(W, y2)
            add(b.make(fill: false)); b = PPTXPathBuilder()
            tr(0, 0, W, y2)
        case "heart":
            let dx1 = W * 49 / 48, dx2 = W * 10 / 48, y1 = -H / 3
            b.move(hc, H / 4); b.cubic(hc + dx2, y1, hc + dx1, H / 4, hc, H)
            b.cubic(hc - dx1, H / 4, hc - dx2, y1, hc, H / 4); b.close()
            tr(W * 0.17, H * 0.25, W * 0.83, H * 0.75)
        case "lightningBolt":
            b.polygon(scaled([(8472, 0), (12860, 6080), (11050, 6797), (16577, 12007), (14767, 12877), (21600, 21600),
                              (10012, 14915), (12222, 13987), (5022, 9705), (7602, 8382), (0, 3890)], 21600))
            tr(W * 0.39, H * 0.35, W * 0.6, H * 0.6)
        case "moon":
            let g0 = ss * pin(0, av("adj", 50000), 87500) / 100000
            b.move(W, H); b.arc(W, vc, 90, 180); b.arc(max(0.01, W - g0), vc, 270, -180); b.close()
            tr(g0 * 0.2, H * 0.3, g0 * 0.9, H * 0.7)
        case "smileyFace":
            b.ellipse(CGRect(x: 0, y: 0, width: W, height: H)); done()
            let er = W * 0.07, eh = H * 0.07
            b.ellipse(CGRect(x: W * 0.32 - er, y: H * 0.37 - eh, width: 2 * er, height: 2 * eh))
            add(b.make(shade: "darkenLess")); b = PPTXPathBuilder()
            b.ellipse(CGRect(x: W * 0.68 - er, y: H * 0.37 - eh, width: 2 * er, height: 2 * eh))
            add(b.make(shade: "darkenLess")); b = PPTXPathBuilder()
            let smile = H * av("adj", 4653) / 100000
            b.move(W * 0.22, H * 0.72 - smile); b.quad(hc, H * 0.72 + smile * 3, W * 0.78, H * 0.72 - smile)
            add(b.make(fill: false)); b = PPTXPathBuilder()
            let dx = hc * 0.70711, dy = vc * 0.70711; tr(hc - dx, vc - dy, hc + dx, vc + dy)
        case "sun":
            let a = pin(12500, av("adj", 25000), 46875)
            let rx = hc * (1 - a / 50000) * 0.95, ry = vc * (1 - a / 50000) * 0.95
            b.ellipse(CGRect(x: hc - rx, y: vc - ry, width: 2 * rx, height: 2 * ry)); done()
            for k in 0..<8 {
                let t = Double(k) * .pi / 4
                let c = CGFloat(cos(t)), s = CGFloat(sin(t))
                let tip = (hc + hc * c, vc + vc * s)
                let baseR = 1.15
                let p1 = (hc + rx * CGFloat(baseR) * CGFloat(cos(t - 0.18)), vc + ry * CGFloat(baseR) * CGFloat(sin(t - 0.18)))
                let p2 = (hc + rx * CGFloat(baseR) * CGFloat(cos(t + 0.18)), vc + ry * CGFloat(baseR) * CGFloat(sin(t + 0.18)))
                b.polygon([tip, p1, p2]); done()
            }
            tr(hc - rx * 0.7, vc - ry * 0.7, hc + rx * 0.7, vc + ry * 0.7)
        case "cloud", "cloudCallout":
            let bumps: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (0.20, 0.38, 0.17, 0.20), (0.36, 0.24, 0.18, 0.21), (0.55, 0.21, 0.17, 0.20), (0.72, 0.30, 0.18, 0.20),
                (0.82, 0.52, 0.17, 0.20), (0.68, 0.72, 0.20, 0.21), (0.46, 0.77, 0.20, 0.21), (0.25, 0.68, 0.19, 0.20),
                (0.12, 0.54, 0.12, 0.15), (0.50, 0.50, 0.33, 0.28),
            ]
            for (x, y, rx, ry) in bumps { b.ellipse(CGRect(x: (x - rx) * W, y: (y - ry) * H, width: 2 * rx * W, height: 2 * ry * H)) }
            done()
            if name == "cloudCallout" {
                let tip = wedgeTip(-20833, 62500)
                for (i, f) in [0.75, 0.5, 0.25].enumerated() {
                    let r = ss * CGFloat(0.03 + 0.02 * Double(i))
                    let cx = tip.0 + (hc - tip.0) * CGFloat(f) * 0.6, cy = tip.1 + (vc - tip.1) * CGFloat(f) * 0.6
                    b.ellipse(CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)); done()
                }
            }
            tr(W * 0.15, H * 0.25, W * 0.85, H * 0.75)
            return PPTXGeometry(paths: paths, textRect: text, strokeUnderFill: true)
        case "wedgeRectCallout", "wedgeRoundRectCallout":
            let (xPos, yPos) = wedgeTip(-20833, 62500)
            let r = name == "wedgeRoundRectCallout" ? ss * av("adj3", 16667) / 100000 : 0
            let dx = xPos - hc, dy = yPos - vc
            let inside = xPos >= 0 && xPos <= W && yPos >= 0 && yPos <= H
            let vertical = abs(dy) * W > abs(dx) * H
            let left = dx < 0
            let up = dy < 0
            let xb1 = left ? W * 2 / 12 : W * 7 / 12, xb2 = left ? W * 5 / 12 : W * 10 / 12
            let yb1 = up ? H * 2 / 12 : H * 7 / 12, yb2 = up ? H * 5 / 12 : H * 10 / 12
            b.move(0, r)
            if r > 0 { b.arc(r, r, 180, 90) }
            if !inside && vertical && up { b.line(xb1, 0); b.line(xPos, yPos); b.line(xb2, 0) }
            b.line(W - r, 0)
            if r > 0 { b.arc(r, r, 270, 90) }
            if !inside && !vertical && !left { b.line(W, yb1); b.line(xPos, yPos); b.line(W, yb2) }
            b.line(W, H - r)
            if r > 0 { b.arc(r, r, 0, 90) }
            if !inside && vertical && !up { b.line(xb2, H); b.line(xPos, yPos); b.line(xb1, H) }
            b.line(r, H)
            if r > 0 { b.arc(r, r, 90, 90) }
            if !inside && !vertical && left { b.line(0, yb2); b.line(xPos, yPos); b.line(0, yb1) }
            b.close()
        case "wedgeEllipseCallout":
            let (xPos, yPos) = wedgeTip(-20830, 62500)
            let nx = (xPos - hc) / hc, ny = (yPos - vc) / vc
            if nx * nx + ny * ny <= 1 {
                b.ellipse(CGRect(x: 0, y: 0, width: W, height: H))
            } else {
                let ang = atan2(Double(ny), Double(nx)) * 180 / .pi
                let p0 = ellipsePoint(ang + 11, rx: hc, ry: vc, cx: hc, cy: vc)
                b.move(p0.0, p0.1); b.arc(hc, vc, ang + 11, 338); b.line(xPos, yPos); b.close()
            }
            let dx = hc * 0.70711, dy = vc * 0.70711; tr(hc - dx, vc - dy, hc + dx, vc + dy)
        case "callout1", "callout2", "callout3", "accentCallout1", "accentCallout2", "accentCallout3":
            b.polygon([(0, 0), (W, 0), (W, H), (0, H)]); add(b.make(stroke: false)); b = PPTXPathBuilder()
            calloutLines(Int(String(name.last!))!, accent: name.hasPrefix("accent"))
        case "borderCallout1", "borderCallout2", "borderCallout3", "accentBorderCallout1", "accentBorderCallout2",
             "accentBorderCallout3":
            b.polygon([(0, 0), (W, 0), (W, H), (0, H)]); done()
            calloutLines(Int(String(name.last!))!, accent: name.hasPrefix("accent"))
        case "snip1Rect":
            let d = ss * pin(0, av("adj", 16667), 50000) / 100000
            b.polygon([(0, 0), (W - d, 0), (W, d), (W, H), (0, H)]); tr(0, d / 2, W - d / 2, H)
        case "snip2SameRect":
            let d1 = ss * pin(0, av("adj1", 16667), 50000) / 100000, d2 = ss * pin(0, av("adj2", 0), 50000) / 100000
            b.polygon([(d1, 0), (W - d1, 0), (W, d1), (W, H - d2), (W - d2, H), (d2, H), (0, H - d2), (0, d1)])
            tr(d1 / 2, d1 / 2, W - d1 / 2, H - d2 / 2)
        case "snip2DiagRect":
            let d1 = ss * pin(0, av("adj1", 0), 50000) / 100000, d2 = ss * pin(0, av("adj2", 16667), 50000) / 100000
            b.polygon([(d1, 0), (W - d2, 0), (W, d2), (W, H - d1), (W - d1, H), (d2, H), (0, H - d2), (0, d1)])
        case "snipRoundRect":
            let r = ss * pin(0, av("adj1", 16667), 50000) / 100000, d = ss * pin(0, av("adj2", 16667), 50000) / 100000
            roundedRect(tl: r, tr: d, br: 0, bl: 0, snip: [1])
        case "round1Rect":
            let r = ss * pin(0, av("adj", 16667), 50000) / 100000
            roundedRect(tl: 0, tr: r, br: 0, bl: 0)
        case "round2SameRect":
            let r1 = ss * pin(0, av("adj1", 16667), 50000) / 100000, r2 = ss * pin(0, av("adj2", 0), 50000) / 100000
            roundedRect(tl: r1, tr: r1, br: r2, bl: r2)
        case "round2DiagRect":
            let r1 = ss * pin(0, av("adj1", 16667), 50000) / 100000, r2 = ss * pin(0, av("adj2", 0), 50000) / 100000
            roundedRect(tl: r1, tr: r2, br: r1, bl: r2)
        case "plaque":
            let x1 = ss * pin(0, av("adj", 16667), 50000) / 100000
            b.move(0, x1); b.arc(x1, x1, 90, -90); b.line(W - x1, 0); b.arc(x1, x1, 180, -90)
            b.line(W, H - x1); b.arc(x1, x1, 270, -90); b.line(x1, H); b.arc(x1, x1, 0, -90); b.close()
            tr(x1 * 0.7, x1 * 0.7, W - x1 * 0.7, H - x1 * 0.7)
        case "teardrop":
            let a = pin(0, av("adj", 100000), 200000)
            let tip = (hc + hc * a / 100000, vc - vc * a / 100000)
            b.move(0, vc); b.arc(hc, vc, 180, 90)
            b.quad((hc + tip.0) / 2 + (tip.0 - hc) * 0.1, min(0, tip.1), tip.0, tip.1)
            b.quad(W, (vc + tip.1) / 2, W, vc)
            b.arc(hc, vc, 0, 180); b.close()
            let dx = hc * 0.70711, dy = vc * 0.70711; tr(hc - dx, vc - dy, hc + dx, vc + dy)
        case "pie", "arc", "chord":
            let defs: (Double, Double) = name == "pie" ? (0, 16_200_000) : name == "arc" ? (16_200_000, 0) : (2_700_000, 16_200_000)
            let st = Double(av("adj1", defs.0)) / 60000
            var sw = Double(av("adj2", defs.1)) / 60000 - st
            while sw <= 0 { sw += 360 }
            while sw > 360 { sw -= 360 }
            let p0 = ellipsePoint(st, rx: hc, ry: vc, cx: hc, cy: vc)
            switch name {
            case "pie":
                b.move(hc, vc); b.line(p0.0, p0.1); b.arc(hc, vc, st, sw); b.close()
            case "chord":
                b.move(p0.0, p0.1); b.arc(hc, vc, st, sw); b.close()
            default:
                b.move(hc, vc); b.line(p0.0, p0.1); b.arc(hc, vc, st, sw); b.close()
                add(b.make(stroke: false)); b = PPTXPathBuilder()
                b.move(p0.0, p0.1); b.arc(hc, vc, st, sw); add(b.make(fill: false)); b = PPTXPathBuilder()
            }
            let dx = hc * 0.70711, dy = vc * 0.70711; tr(hc - dx, vc - dy, hc + dx, vc + dy)
        case "pieWedge":
            b.move(0, H); b.arc(W, H, 180, 90); b.line(W, H); b.close(); tr(W * 0.29, H * 0.29, W, H)
        case "blockArc":
            let st = Double(av("adj1", 10_800_000)) / 60000
            var sw = Double(av("adj2", 0)) / 60000 - st
            while sw <= 0 { sw += 360 }
            let dr = ss * pin(0, av("adj3", 25000), 50000) / 100000
            let p0 = ellipsePoint(st, rx: hc, ry: vc, cx: hc, cy: vc)
            b.move(p0.0, p0.1); b.arc(hc, vc, st, sw)
            let p1 = ellipsePoint(st + sw, rx: hc - dr, ry: vc - dr, cx: hc, cy: vc)
            b.line(p1.0, p1.1); b.arc(max(0.01, hc - dr), max(0.01, vc - dr), st + sw, -sw); b.close()
        case "leftBracket", "rightBracket":
            let y1 = ss * pin(0, av("adj", 8333), 50000 * H / ss) / 100000
            if name == "rightBracket" {
                b.move(0, 0); b.arc(W, y1, 270, 90); b.line(W, H - y1); b.arc(W, y1, 0, 90)
            } else {
                b.move(W, H); b.arc(W, y1, 90, 90); b.line(0, y1); b.arc(W, y1, 180, 90)
            }
            add(b.make(fill: false)); b = PPTXPathBuilder()
        case "bracketPair":
            let r = ss * pin(0, av("adj", 16667), 50000) / 100000
            b.move(r, H); b.arc(r, r, 90, 90); b.line(0, r); b.arc(r, r, 180, 90); add(b.make(fill: false)); b = PPTXPathBuilder()
            b.move(W - r, 0); b.arc(r, r, 270, 90); b.line(W, H - r); b.arc(r, r, 0, 90); add(b.make(fill: false)); b = PPTXPathBuilder()
            tr(r * 0.3, r * 0.3, W - r * 0.3, H - r * 0.3)
        case "leftBrace", "rightBrace":
            let y1 = ss * av("adj1", 8333) / 100000, ym = H * av("adj2", 50000) / 100000
            let rx = W / 2
            if name == "rightBrace" {
                b.move(0, 0); b.arc(rx, y1, 270, 90); b.line(rx, ym - y1); b.arc(rx, y1, 180, -90)
                b.arc(rx, y1, 270, -90); b.line(rx, H - y1); b.arc(rx, y1, 0, 90)
            } else {
                b.move(W, H); b.arc(rx, y1, 90, 90); b.line(rx, ym + y1); b.arc(rx, y1, 0, -90)
                b.arc(rx, y1, 90, -90); b.line(rx, y1); b.arc(rx, y1, 180, 90)
            }
            add(b.make(fill: false)); b = PPTXPathBuilder()
        case "bracePair":
            let y1 = ss * pin(0, av("adj", 8333), 25000) / 100000, rx = y1
            b.move(rx * 2, H); b.arc(rx, y1, 90, 90); b.line(rx, vc + y1); b.arc(rx, y1, 0, -90); b.arc(rx, y1, 90, -90)
            b.line(rx, y1); b.arc(rx, y1, 180, 90); add(b.make(fill: false)); b = PPTXPathBuilder()
            b.move(W - rx * 2, 0); b.arc(rx, y1, 270, 90); b.line(W - rx, vc - y1); b.arc(rx, y1, 180, -90)
            b.arc(rx, y1, 270, -90); b.line(W - rx, H - y1); b.arc(rx, y1, 0, 90); add(b.make(fill: false)); b = PPTXPathBuilder()
            tr(rx * 2, 0, W - rx * 2, H)
        case "wave", "doubleWave", "flowChartPunchedTape":
            let a = name == "flowChartPunchedTape" ? CGFloat(10000) : av("adj1", name == "wave" ? 12500 : 6250)
            let y1 = H * a / 100000
            b.move(0, y1)
            if name == "doubleWave" {
                b.cubic(W / 6, y1 - 2 * y1, W / 3, y1 + 2 * y1, hc, y1); b.cubic(W * 2 / 3, y1 - 2 * y1, W * 5 / 6, y1 + 2 * y1, W, y1)
                b.line(W, H - y1)
                b.cubic(W * 5 / 6, H - y1 + 2 * y1, W * 2 / 3, H - y1 - 2 * y1, hc, H - y1)
                b.cubic(W / 3, H - y1 + 2 * y1, W / 6, H - y1 - 2 * y1, 0, H - y1)
            } else {
                b.cubic(W / 3, y1 - 2 * y1, W * 2 / 3, y1 + 2 * y1, W, y1)
                b.line(W, H - y1)
                b.cubic(W * 2 / 3, H - y1 + 2 * y1, W / 3, H - y1 - 2 * y1, 0, H - y1)
            }
            b.close()
            tr(0, y1 * 2, W, H - y1 * 2)
        case "flowChartDocument", "flowChartMultidocument":
            var pts = CGFloat(21600)
            if name == "flowChartMultidocument" {
                let o = W * 0.1
                b.polygon([(o, 0), (W, 0), (W, H * 0.7), (W - o, H * 0.7), (W - o, o * H / W), (o, o * H / W)])
                done()
                pts = 21600
            }
            let sx = (name == "flowChartMultidocument" ? W * 0.9 : W) / pts, sy = H / pts
            let oy: CGFloat = name == "flowChartMultidocument" ? H * 0.1 : 0
            let syy = name == "flowChartMultidocument" ? sy * 0.9 : sy
            b.move(0, oy); b.line(21600 * sx, oy); b.line(21600 * sx, oy + 17322 * syy)
            b.cubic(10800 * sx, oy + 17322 * syy, 10800 * sx, oy + 23922 * syy, 0, oy + 20172 * syy); b.close()
            tr(0, oy, 21600 * sx, oy + 17322 * syy)
        case "flowChartTerminator":
            let rx = W * 3475 / 21600
            b.move(rx, 0); b.line(W - rx, 0); b.arc(rx, vc, 270, 180); b.line(rx, H); b.arc(rx, vc, 90, 180); b.close()
            tr(W * 1018 / 21600, H * 3163 / 21600, W * 20582 / 21600, H * 18437 / 21600)
        case "flowChartPredefinedProcess":
            b.polygon([(0, 0), (W, 0), (W, H), (0, H)]); done()
            openLine([(W / 8, 0), (W / 8, H)]); openLine([(W * 7 / 8, 0), (W * 7 / 8, H)])
            tr(W / 8, 0, W * 7 / 8, H)
        case "flowChartInternalStorage":
            b.polygon([(0, 0), (W, 0), (W, H), (0, H)]); done()
            openLine([(W / 8, 0), (W / 8, H)]); openLine([(0, H / 8), (W, H / 8)])
            tr(W / 8, H / 8, W, H)
        case "flowChartManualInput":
            b.polygon([(0, H / 5), (W, 0), (W, H), (0, H)]); tr(0, H / 5, W, H)
        case "flowChartOffpageConnector":
            b.polygon([(0, 0), (W, 0), (W, H * 4 / 5), (hc, H), (0, H * 4 / 5)]); tr(0, 0, W, H * 4 / 5)
        case "flowChartPunchedCard":
            b.polygon([(W / 5, 0), (W, 0), (W, H), (0, H), (0, H / 5)]); tr(0, H / 5, W, H)
        case "flowChartSummingJunction", "flowChartOr":
            b.ellipse(CGRect(x: 0, y: 0, width: W, height: H)); done()
            if name == "flowChartOr" {
                openLine([(hc, 0), (hc, H)]); openLine([(0, vc), (W, vc)])
            } else {
                let dx = hc * 0.70711, dy = vc * 0.70711
                openLine([(hc - dx, vc - dy), (hc + dx, vc + dy)]); openLine([(hc + dx, vc - dy), (hc - dx, vc + dy)])
            }
            let dx = hc * 0.70711, dy = vc * 0.70711; tr(hc - dx, vc - dy, hc + dx, vc + dy)
        case "flowChartCollate":
            b.move(0, 0); b.line(W, 0); b.line(0, H); b.line(W, H); b.close(); tr(W / 4, H / 4, W * 3 / 4, H * 3 / 4)
        case "flowChartOfflineStorage":
            b.polygon([(0, 0), (W, 0), (hc, H)]); done(); openLine([(W * 2 / 5, H * 4 / 5), (W * 3 / 5, H * 4 / 5)])
            tr(W / 4, 0, W * 3 / 4, H * 2 / 3)
        case "flowChartOnlineStorage":
            let x1 = W / 6
            b.move(x1, 0); b.line(W, 0); b.arc(x1, vc, 270, -180); b.line(x1, H); b.arc(x1, vc, 90, 180); b.close()
            tr(x1, 0, W - x1, H)
        case "flowChartMagneticTape":
            b.move(hc, H); b.arc(hc, vc, 90, 315); b.line(W, b.current.y); b.line(W, H); b.close()
            let dx = hc * 0.70711, dy = vc * 0.70711; tr(hc - dx, vc - dy, hc + dx, vc + dy)
        case "flowChartDisplay":
            let x1 = W / 6, x2 = W * 5 / 6
            b.move(0, vc); b.line(x1, 0); b.line(x2, 0); b.arc(x1, vc, 270, 180); b.line(x1, H); b.close()
            tr(x1, 0, x2, H)
        case "flowChartDelay":
            b.move(0, 0); b.line(hc, 0); b.arc(hc, vc, 270, 180); b.line(0, H); b.close()
            tr(0, H * 0.15, W * 0.85, H * 0.85)
        case "verticalScroll", "horizontalScroll":
            let r = ss * pin(0, av("adj", 12500), 25000) / 100000
            roundedRect(tl: r, tr: r, br: r, bl: r); done()
            if name == "horizontalScroll" {
                openLine([(r, r), (W - r, r)]); openLine([(r, H - r), (W - r, H - r)])
                tr(r, r * 2, W - r, H - r * 2)
            } else {
                openLine([(r, r), (r, H - r)]); openLine([(W - r, r), (W - r, H - r)])
                tr(r * 2, r, W - r * 2, H - r)
            }
        case "funnel":
            b.move(0, H * 0.1); b.arc(hc, H * 0.1, 180, 180)
            b.line(W * 0.58, H * 0.92); b.arc(W * 0.08, H * 0.08, 0, 180); b.close()
            tr(W * 0.3, H * 0.25, W * 0.7, H * 0.7)
        case "gear6", "gear9":
            let n = name == "gear6" ? 6 : 9
            var pts: [(CGFloat, CGFloat)] = []
            for k in 0..<(n * 4) {
                let t = (Double(k) / Double(n * 4) * 360 - 90) * .pi / 180
                let f: CGFloat = (k % 4 == 1 || k % 4 == 2) ? 1 : 0.78
                pts.append((hc + hc * f * CGFloat(cos(t)), vc + vc * f * CGFloat(sin(t))))
            }
            b.polygon(pts)
            tr(W * 0.25, H * 0.25, W * 0.75, H * 0.75)
        case "ribbon", "ribbon2", "ellipseRibbon", "ellipseRibbon2":
            let down = name == "ribbon" || name == "ellipseRibbon"
            let fold = H / 4, tail = W / 8
            func y(_ v: CGFloat) -> CGFloat { down ? v : H - v }
            b.polygon([(tail, y(fold)), (W - tail, y(fold)), (W - tail, y(H - fold)), (tail, y(H - fold))]); done()
            b.polygon([(0, y(fold * 1.6)), (tail * 2, y(fold * 1.6)), (tail * 2, y(H)), (0, y(H)), (tail * 0.7, y(fold * 1.6 + (H - fold * 1.6) / 2))])
            add(b.make(shade: "darkenLess")); b = PPTXPathBuilder()
            b.polygon([(W, y(fold * 1.6)), (W - tail * 2, y(fold * 1.6)), (W - tail * 2, y(H)), (W, y(H)), (W - tail * 0.7, y(fold * 1.6 + (H - fold * 1.6) / 2))])
            add(b.make(shade: "darkenLess")); b = PPTXPathBuilder()
            b.polygon([(tail, y(fold)), (W - tail, y(fold)), (W - tail, y(H - fold)), (tail, y(H - fold))]); done()
            tr(tail * 2, min(y(fold), y(H - fold)), W - tail * 2, max(y(fold), y(H - fold)))
        case "squareTabs", "plaqueTabs", "cornerTabs":
            let t = ss / 10
            for (x, y) in [(0, 0), (W - t, 0), (0, H - t), (W - t, H - t)] {
                b.polygon([(x, y), (x + t, y), (x + t, y + t), (x, y + t)]); done()
            }
            tr(t, t, W - t, H - t)
        default:
            b.polygon([(0, 0), (W, 0), (W, H), (0, H)])
        }
        done()
        if paths.isEmpty { return .rect(W, H) }
        return PPTXGeometry(paths: paths, textRect: text)
    }
}
