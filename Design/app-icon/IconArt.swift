import AppKit
import SwiftUI

// YummyOrange app icon: drawn in code at every size an .icns needs. The app ships direction B, "Bloom" (picked on
// 24 Nov 2026 from icon-directions.png); A, C and D stay here as the other options that were shown.
// Rebuild AppIcon.icns with ./make-icon.sh after changing anything below.
// Design space is the macOS icon grid: a 1024 x 1024 canvas, an 824 x 824 continuous-corner body (radius 185.4)
// at 100,100, and the template's drop shadow (0, 10 down, blur 10, black 30 %). Everything below is in those units;
// k = pixels per unit. Small sizes (<= 64 px) are drawn natively with pixel minimums, not scaled down.

// MARK: - Palette (README / DWPalette.swift)

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

enum Pal {
    static let dahlia = hex(0xE2669C)
    static let butter = hex(0xFFE1A1)
    static let cream = hex(0xFFF4EA)
    static let hub = hex(0xF4A9A6)      // "petal hub" in the palette preview
    static let deep = hex(0xA9426F)

    // Derived exactly as DWPalette does.
    static func hsb(_ c: NSColor) -> (h: CGFloat, s: CGFloat, b: CGFloat) {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b)
    }
    static var hueGap: CGFloat {
        var d = hsb(butter).h - hsb(dahlia).h
        if d > 0.5 { d -= 1 }
        if d < -0.5 { d += 1 }
        return d
    }
    static func shifted(_ c: NSColor, _ f: CGFloat, sat: CGFloat = 1) -> NSColor {
        let x = hsb(c)
        var h = x.h + f * hueGap
        h -= floor(h)
        return NSColor(srgbHue: h, saturation: min(max(x.s * sat, 0), 1), brightness: x.b)
    }
    static func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let x = a.usingColorSpace(.sRGB)!, y = b.usingColorSpace(.sRGB)!
        return NSColor(srgbRed: x.redComponent + (y.redComponent - x.redComponent) * t,
                       green: x.greenComponent + (y.greenComponent - x.greenComponent) * t,
                       blue: x.blueComponent + (y.blueComponent - x.blueComponent) * t, alpha: 1)
    }
    static func deepened(_ c: NSColor) -> NSColor {
        let x = hsb(c)
        return NSColor(srgbHue: x.h, saturation: min(x.s * 1.12, 1), brightness: max(x.b * 0.74, 0))
    }
    static let accent = shifted(dahlia, -0.219)
    static let accentLight = blend(accent, .white, 0.24)
    static let accentHighlight = blend(accent, .white, 0.42)
    static let accentDeep = deepened(accent)
}

extension NSColor {
    convenience init(srgbHue h: CGFloat, saturation s: CGFloat, brightness v: CGFloat) {
        let i = Int(floor(h * 6)) % 6
        let f = h * 6 - floor(h * 6)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
    func a(_ alpha: CGFloat) -> NSColor { withAlphaComponent(alpha) }
}

// MARK: - Geometry (petal outline from WheelGeometry.petalPath, y-up)

func petalPath(center c: CGPoint, centerAngle: CGFloat, sector: CGFloat, gap: CGFloat,
               inner ri: CGFloat, outer ro: CGFloat, cornerEdge: CGFloat) -> CGPath {
    let start = centerAngle - sector / 2, end = centerAngle + sector / 2
    let hg = max(gap / 2, 0)
    func half(_ r: CGFloat) -> CGFloat { asin(min(hg / max(hg + 0.01, r), 0.95)) }
    func P(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)) }
    let iS = start + half(ri), iE = end - half(ri)
    let ac = min((iE - iS) * 0.18, 0.18)
    let rC = ri / max(cos(ac), 0.01)
    let rA = ri * tan(ac) + rC
    let rB = max(ro - cornerEdge, 0)
    let oS = start + half(ro), oE = end - half(ro)
    let oc = min((oE - oS) * 0.24, 0.15)
    let p = CGMutablePath()
    p.move(to: P(rA, start + half(rA)))
    p.addLine(to: P(rB, start + half(rB)))
    p.addQuadCurve(to: P(ro, oS + oc), control: P(ro, oS))
    p.addArc(center: c, radius: ro, startAngle: oS + oc, endAngle: oE - oc, clockwise: false)
    p.addQuadCurve(to: P(rB, end - half(rB)), control: P(ro, oE))
    p.addLine(to: P(rA, end - half(rA)))
    p.addQuadCurve(to: P(ri, iE - ac), control: P(rC, end - half(rC)))
    p.addArc(center: c, radius: ri, startAngle: iE - ac, endAngle: iS + ac, clockwise: true)
    p.addQuadCurve(to: P(rA, start + half(rA)), control: P(rC, start + half(rC)))
    p.closeSubpath()
    return p
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
}

/// The macOS icon body: 824 x 824 at 100,100 with Apple's continuous corners.
let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath: CGPath = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: bodyRect).cgPath

/// A ring of petals: petal 0 at 12 o'clock, the rest clockwise (as in the app).
struct Wheel {
    var center = CGPoint(x: 512, y: 512)
    var count = 6
    var inner: CGFloat
    var outer: CGFloat
    var gap: CGFloat
    var cornerEdge: CGFloat
    var sector: CGFloat { 2 * .pi / CGFloat(count) }
    func angle(_ i: Int) -> CGFloat { .pi / 2 - CGFloat(i) * sector }
    func petal(_ i: Int, push: CGFloat = 0) -> CGPath {
        let a = angle(i)
        let c = CGPoint(x: center.x + push * cos(a), y: center.y + push * sin(a))
        return petalPath(center: c, centerAngle: a, sector: sector, gap: gap, inner: inner, outer: outer, cornerEdge: cornerEdge)
    }
    func point(_ i: Int, _ r: CGFloat) -> CGPoint {
        CGPoint(x: center.x + r * cos(angle(i)), y: center.y + r * sin(angle(i)))
    }
}

// MARK: - Drawing helpers

final class Painter {
    let ctx: CGContext
    let k: CGFloat           // pixels per design unit
    let px: Int
    var small: Bool { px <= 64 }
    var tiny: Bool { px <= 32 }
    init(ctx: CGContext, px: Int) { self.ctx = ctx; self.px = px; k = CGFloat(px) / 1024 }

    /// Design units that make `pixels` device pixels at this size.
    func u(_ pixels: CGFloat) -> CGFloat { pixels / k }

    func fill(_ path: CGPath, _ color: NSColor) {
        ctx.addPath(path); ctx.setFillColor(color.cgColor); ctx.fillPath()
    }
    func stroke(_ path: CGPath, _ color: NSColor, _ width: CGFloat) {
        ctx.addPath(path); ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(width); ctx.strokePath()
    }
    func gradient(_ stops: [(NSColor, CGFloat)]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                   colors: stops.map { $0.0.cgColor } as CFArray, locations: stops.map { $0.1 })!
    }
    func linear(_ path: CGPath, _ stops: [(NSColor, CGFloat)], _ from: CGPoint, _ to: CGPoint) {
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(gradient(stops), start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
    func radial(_ path: CGPath, _ stops: [(NSColor, CGFloat)], _ c: CGPoint, _ r: CGFloat) {
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.drawRadialGradient(gradient(stops), startCenter: c, startRadius: 0, endCenter: c, endRadius: r,
                               options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }
    /// Draws `body` with a drop shadow under everything it paints. Offsets and blur in design units.
    func shadowed(_ color: NSColor, dy: CGFloat, blur: CGFloat, _ body: () -> Void) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * k), blur: blur * k, color: color.cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
    /// A shadow cast inward from the edges of `path` (pillow shading).
    func innerShadow(_ path: CGPath, _ color: NSColor, dy: CGFloat, blur: CGFloat) {
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * k), blur: blur * k, color: color.cgColor)
        let ring = CGMutablePath()
        ring.addRect(path.boundingBox.insetBy(dx: -400, dy: -400))
        ring.addPath(path)
        ctx.addPath(ring); ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }
    /// The highlighted petal: DWPalette's opaque highlight stops, light at the inner edge, deep at the rim.
    func dahliaPetal(_ wheel: Wheel, _ i: Int, push: CGFloat = 0) {
        let p = wheel.petal(i, push: push)
        linear(p, [(Pal.hub, 0.0), (Pal.dahlia, 0.48), (Pal.deep, 1.0)],
               wheel.point(i, wheel.inner + push), wheel.point(i, wheel.outer + push))
        if !small { innerShadow(p, Pal.deep.a(0.5), dy: 2, blur: 16) }
    }
}

// MARK: - Directions

enum Direction: String, CaseIterable {
    case pillow, bloom, drop, petal

    var title: String {
        switch self {
        case .pillow: return "A · Pillow"
        case .bloom: return "B · Bloom"
        case .drop: return "C · Drop"
        case .petal: return "D · Petal"
        }
    }
    var blurb: String {
        switch self {
        case .pillow: return "The wheel as you see it: soft white petals, one dahlia petal, on warm cream."
        case .bloom: return "The welcome page colours. Cream petals, the chosen one lifted out."
        case .drop: return "A file landing on the lit petal. Tells the gesture."
        case .petal: return "One lit petal, up close, with the wheel running off the edges."
        }
    }

    func draw(_ p: Painter) {
        let ctx = p.ctx
        // Body with the template's drop shadow.
        p.shadowed(.black.a(0.3), dy: 10, blur: 10) {
            ctx.saveGState()
            ctx.addPath(bodyPath); ctx.clip()
            drawBody(p)
            ctx.restoreGState()
        }
    }

    private func drawBody(_ p: Painter) {
        switch self {
        case .pillow: pillow(p)
        case .bloom: bloom(p)
        case .drop: drop(p)
        case .petal: petal(p)
        }
    }

    /// Petal sizes from the app's metrics (inner 48.64, outer 119.52, gap 5, backdrop 42.24…125.92, corner 20.16),
    /// scaled by `s`, with the gap held at `minGapPx` pixels or more.
    func wheel(_ p: Painter, s: CGFloat, center: CGPoint = CGPoint(x: 512, y: 512), minGapPx: CGFloat = 1.1) -> Wheel {
        Wheel(center: center, inner: 48.64 * s, outer: 119.52 * s, gap: max(5 * s, p.u(minGapPx)), cornerEdge: 20.16 * s)
    }

    // A: cream body, grey-white pillow petals on a soft ring, one dahlia petal.
    private func pillow(_ p: Painter) {
        let full = CGPath(rect: CGRect(x: 0, y: 0, width: 1024, height: 1024), transform: nil)
        p.fill(full, Pal.cream)
        p.radial(full, [(Pal.butter.a(0.9), 0), (Pal.butter.a(0), 1)], CGPoint(x: 512, y: 40), 760)
        p.linear(full, [(NSColor.white.a(0.55), 0), (NSColor.white.a(0), 1)], CGPoint(x: 512, y: 924), CGPoint(x: 512, y: 560))

        let s: CGFloat = p.tiny ? 2.85 : 2.55
        let w = wheel(p, s: s)
        let ringR = 125.92 * s
        // The ring the petals sit on.
        p.shadowed(hex(0x7A4A2E).a(p.small ? 0.22 : 0.20), dy: p.small ? 6 : 8, blur: p.small ? 10 : 26) {
            p.linear(circle(w.center, ringR), [(hex(p.small ? 0xE4E5EA : 0xF1F1F4), 0), (hex(p.small ? 0xCFD1D8 : 0xDEDFE4), 1)],
                     CGPoint(x: 512, y: w.center.y + ringR), CGPoint(x: 512, y: w.center.y - ringR))
        }
        for i in 0..<w.count where i != 1 {
            let path = w.petal(i)
            p.linear(path, [(hex(0xFFFFFF), 0), (hex(p.small ? 0xF4F4F6 : 0xF3F3F5), 1)],
                     CGPoint(x: 512, y: w.center.y + w.outer), CGPoint(x: 512, y: w.center.y - w.outer))
            if !p.small {
                p.innerShadow(path, hex(0x5B5D6B).a(0.16), dy: 3, blur: 18)
            }
            p.stroke(path, hex(0xC9CBD3).a(p.small ? 0.9 : 0.55), max(1.6, p.u(0.5)))
        }
        p.dahliaPetal(w, 1)
        // Centre hub.
        let hubR = w.inner - w.gap * 0.9
        p.shadowed(.black.a(0.12), dy: 2, blur: 10) { p.fill(circle(w.center, hubR), .white) }
        if !p.small { p.innerShadow(circle(w.center, hubR), hex(0x5B5D6B).a(0.10), dy: -2, blur: 14) }
    }

    // B: the welcome page's dahlia with a butter glow; translucent cream petals, the chosen one lifted out.
    private func bloom(_ p: Painter) {
        let full = CGPath(rect: CGRect(x: 0, y: 0, width: 1024, height: 1024), transform: nil)
        p.linear(full, [(Pal.blend(Pal.dahlia, Pal.deep, 0.12), 0), (Pal.dahlia, 0.5), (hex(0xEC94A0), 1)], CGPoint(x: 300, y: 1000), CGPoint(x: 640, y: 80))
        p.radial(full, [(Pal.butter.a(0.95), 0), (Pal.butter.a(0.55), 0.45), (Pal.butter.a(0), 1)], CGPoint(x: 512, y: 60), 620)

        let s: CGFloat = p.tiny ? 2.7 : 2.5
        let w = wheel(p, s: s, minGapPx: 1.2)
        for i in 0..<w.count where i != 1 {
            let path = w.petal(i)
            p.fill(path, Pal.cream.a(p.small ? 0.62 : 0.5))
            if !p.small { p.stroke(path, NSColor.white.a(0.55), 3) }
        }
        let push: CGFloat = p.tiny ? 10 : 26
        p.shadowed(Pal.accentDeep.a(0.55), dy: p.small ? 6 : 12, blur: p.small ? 8 : 30) {
            p.linear(w.petal(1, push: push), [(NSColor.white, 0), (Pal.cream, 0.6), (hex(0xFFEBD3), 1)],
                     w.point(1, w.inner + push), w.point(1, w.outer + push))
        }
        let hubR = w.inner - w.gap * 0.9
        p.fill(circle(w.center, hubR), Pal.cream.a(0.94))
        if !p.small { p.innerShadow(circle(w.center, hubR), Pal.accentDeep.a(0.25), dy: -3, blur: 16) }
    }

    // C: butter-to-cream body, a pink wheel, a cream file card dropping onto the dahlia petal.
    private func drop(_ p: Painter) {
        let full = CGPath(rect: CGRect(x: 0, y: 0, width: 1024, height: 1024), transform: nil)
        p.linear(full, [(hex(0xFFF8F0), 0), (Pal.cream, 0.4), (Pal.butter, 1)], CGPoint(x: 512, y: 924), CGPoint(x: 512, y: 100))

        let s: CGFloat = p.tiny ? 2.4 : 2.2
        let w = wheel(p, s: s, center: CGPoint(x: p.tiny ? 470 : 462, y: p.tiny ? 452 : 446), minGapPx: 1.1)
        p.shadowed(Pal.accentDeep.a(0.28), dy: 8, blur: p.small ? 10 : 24) {
            for i in 0..<w.count where i != 1 {
                p.linear(w.petal(i), [(hex(0xF8C3C3), 0), (Pal.hub, 1)],
                         CGPoint(x: 512, y: w.center.y + w.outer), CGPoint(x: 512, y: w.center.y - w.outer))
            }
            p.dahliaPetal(w, 1)
            p.fill(circle(w.center, w.inner - w.gap * 0.9), .white)
        }
        if !p.small {
            for i in 0..<w.count where i != 1 { p.innerShadow(w.petal(i), Pal.deep.a(0.18), dy: 2, blur: 16) }
        }

        // The file: a rounded card with a folded corner, tilted, its lower corner over the lit petal.
        let cw: CGFloat = p.tiny ? 240 : 214, ch: CGFloat = p.tiny ? 290 : 262, r: CGFloat = p.tiny ? 40 : 32
        let fold: CGFloat = p.tiny ? 0 : 66
        let card = CGMutablePath()
        card.move(to: CGPoint(x: -cw / 2 + r, y: -ch / 2))
        card.addLine(to: CGPoint(x: cw / 2 - r, y: -ch / 2))
        card.addQuadCurve(to: CGPoint(x: cw / 2, y: -ch / 2 + r), control: CGPoint(x: cw / 2, y: -ch / 2))
        card.addLine(to: CGPoint(x: cw / 2, y: ch / 2 - max(fold, r)))
        if fold > 0 {
            card.addLine(to: CGPoint(x: cw / 2 - fold, y: ch / 2))
        } else {
            card.addQuadCurve(to: CGPoint(x: cw / 2 - r, y: ch / 2), control: CGPoint(x: cw / 2, y: ch / 2))
        }
        card.addLine(to: CGPoint(x: -cw / 2 + r, y: ch / 2))
        card.addQuadCurve(to: CGPoint(x: -cw / 2, y: ch / 2 - r), control: CGPoint(x: -cw / 2, y: ch / 2))
        card.addLine(to: CGPoint(x: -cw / 2, y: -ch / 2 + r))
        card.addQuadCurve(to: CGPoint(x: -cw / 2 + r, y: -ch / 2), control: CGPoint(x: -cw / 2, y: -ch / 2))
        card.closeSubpath()
        var t = CGAffineTransform(translationX: p.tiny ? 700 : 724, y: p.tiny ? 720 : 744).rotated(by: -0.26)
        let placed = card.copy(using: &t)!
        p.shadowed(hex(0x6B2A48).a(0.32), dy: p.small ? 8 : 22, blur: p.small ? 10 : 34) {
            p.linear(placed, [(NSColor.white, 0), (hex(0xFFF7EF), 1)], CGPoint(x: 704, y: 860), CGPoint(x: 704, y: 540))
        }
        if fold > 0 {
            let f = CGMutablePath()
            f.move(to: CGPoint(x: cw / 2, y: ch / 2 - fold))
            f.addLine(to: CGPoint(x: cw / 2 - fold, y: ch / 2))
            f.addQuadCurve(to: CGPoint(x: cw / 2 - fold * 0.92, y: ch / 2 - fold * 0.92), control: CGPoint(x: cw / 2 - fold, y: ch / 2 - fold))
            f.closeSubpath()
            let fp = f.copy(using: &t)!
            p.fill(fp, hex(0xF3DCCB))
        }
        if !p.small { p.stroke(placed, hex(0xE7CDBE).a(0.8), 2) }
    }

    // D: one lit petal, up close: the wheel's hub low on the left, the dahlia petal reaching to the top right,
    // its neighbours tone-on-tone cream and running off the edges.
    private func petal(_ p: Painter) {
        let full = CGPath(rect: CGRect(x: 0, y: 0, width: 1024, height: 1024), transform: nil)
        p.linear(full, [(Pal.cream, 0), (hex(0xFFEBC4), 0.6), (Pal.butter, 1)], CGPoint(x: 760, y: 924), CGPoint(x: 260, y: 100))
        let c = CGPoint(x: p.tiny ? 300 : 318, y: p.tiny ? 300 : 318)
        // Petal 1 of a six-petal wheel turned so it points at 45 degrees.
        var w = Wheel(center: c, count: 6, inner: p.tiny ? 118 : 128, outer: 580, gap: max(24, p.u(1.3)), cornerEdge: 70)
        let turn = CGFloat.pi / 4 - w.angle(1)
        func turned(_ path: CGPath) -> CGPath {
            var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: turn).translatedBy(x: -c.x, y: -c.y)
            return path.copy(using: &t)!
        }
        for i in 0..<w.count where i != 1 {
            let path = turned(w.petal(i))
            p.linear(path, [(NSColor.white, 0), (hex(0xFFF8F1), 1)], CGPoint(x: 512, y: 924), CGPoint(x: 512, y: 100))
            if !p.small { p.innerShadow(path, hex(0x8A5A3A).a(0.18), dy: 3, blur: 26) }
            p.stroke(path, hex(0xE2C6AF).a(p.small ? 1 : 0.8), max(2.5, p.u(0.6)))
        }
        w.outer = p.tiny ? 660 : 640
        let lit = turned(w.petal(1))
        let a = CGFloat.pi / 4
        p.shadowed(Pal.deep.a(0.42), dy: p.small ? 6 : 14, blur: p.small ? 8 : 34) {
            p.linear(lit, [(Pal.hub, 0.0), (Pal.dahlia, 0.48), (Pal.deep, 1.0)],
                     CGPoint(x: c.x + w.inner * cos(a), y: c.y + w.inner * sin(a)),
                     CGPoint(x: c.x + w.outer * cos(a), y: c.y + w.outer * sin(a)))
        }
        if !p.small { p.innerShadow(lit, Pal.deep.a(0.45), dy: 2, blur: 18) }
        let hubR = w.inner - w.gap * 0.8
        p.shadowed(hex(0x7A4A2E).a(0.22), dy: 4, blur: p.small ? 8 : 20) { p.fill(circle(c, hubR), .white) }
        if !p.small { p.innerShadow(circle(c, hubR), hex(0x8A5A3A).a(0.10), dy: -2, blur: 16) }
    }
}

// MARK: - Rendering

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func render(_ d: Direction, px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    let p = Painter(ctx: ctx, px: px)
    ctx.scaleBy(x: p.k, y: p.k)
    d.draw(p)
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

/// The ten files an .iconset holds, by pixel size.
let iconsetFiles: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func writeIconset(_ d: Direction, to dir: URL) {
    try? FileManager.default.removeItem(at: dir)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var cache: [Int: CGImage] = [:]
    for f in iconsetFiles {
        let img = cache[f.px] ?? render(d, px: f.px)
        cache[f.px] = img
        writePNG(img, dir.appendingPathComponent(f.name + ".png"))
    }
}
