import AppKit

/// Paints one wheel style in one appearance.
///
/// Glass (the default, "pillow"): a light ring with a soft shadow under it; each petal is a raised pillow, near
/// white in its middle and fading to light grey at its edges, with its own small drop shadow and a light inner
/// rim; the highlighted petal is filled with the brand colour and gets a tinted shadow; the hole is white with a
/// soft inner shadow and a white capsule. This is how the reference wheel looks on a light window, drawn by hand
/// so it looks the same over any wallpaper. Metallic: an opaque black annulus, graphite petals and a
/// brushed-steel highlight.
struct WheelPainter {
    let style: WheelStyle
    let dark: Bool
    let layout: WheelLayout
    /// The highlight colour before shading (the brand colour unless overridden).
    let accent: NSColor

    init(style: WheelStyle, appearance: NSAppearance, layout: WheelLayout, accent override: NSColor? = nil) {
        self.style = style
        self.layout = layout
        dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        accent = DWPalette.srgb(override ?? DWPalette.wheelAccent)
    }

    private var s: CGFloat { layout.scale }

    // MARK: Colours

    static let graphite = NSColor(srgbRed: 0x24 / 255.0, green: 0x24 / 255.0, blue: 0x24 / 255.0, alpha: 1)   // #242424
    static let steelDark = NSColor(srgbRed: 0x96 / 255.0, green: 0x96 / 255.0, blue: 0x96 / 255.0, alpha: 1)  // #969696
    static let steelLight = NSColor(srgbRed: 0xE0 / 255.0, green: 0xE0 / 255.0, blue: 0xE0 / 255.0, alpha: 1) // #E0E0E0
    static let steelEdge = NSColor(srgbRed: 0x46 / 255.0, green: 0x46 / 255.0, blue: 0x46 / 255.0, alpha: 1)  // #464646

    /// Label and symbol colour on a petal.
    func labelColor(highlighted: Bool) -> NSColor {
        switch style {
        case .glass: return dark || highlighted ? NSColor(white: 1, alpha: 0.96) : Pillow.ink
        case .metallic: return highlighted ? .black : NSColor(white: 1, alpha: 0.96)
        }
    }

    /// Text colour in the centre capsule.
    var centerTextColor: NSColor {
        switch style {
        case .glass: return dark ? NSColor(white: 1, alpha: 0.96) : Pillow.ink
        case .metallic: return .white
        }
    }

    /// Mixes two colours in sRGB.
    static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor { DWPalette.mix(a, b, t) }

    /// WCAG contrast ratio between two opaque colours.
    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        func luminance(_ c: NSColor) -> Double {
            let s = DWPalette.srgb(c)
            func channel(_ v: CGFloat) -> Double {
                let v = Double(v)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(s.redComponent) + 0.7152 * channel(s.greenComponent) + 0.0722 * channel(s.blueComponent)
        }
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    // MARK: Backdrop

    /// The annulus behind the petals: opaque black for metallic; for glass, the pillow look's light ring.
    func drawBackdrop(_ ctx: CGContext, bloom: CGFloat) {
        guard layout.count > 0 else { return }
        let path = layout.backdropPath(bloom: bloom)
        switch style {
        case .metallic:
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath(using: .evenOdd)
        case .glass:
            drawPillowBackdrop(ctx, bloom: bloom)
        }
    }

    // MARK: Pillow look

    /// Colours of the pillow look, light and dark.
    enum Pillow {
        /// Design-preview overrides: DW_WHEEL_RING, DW_WHEEL_PETAL_MID, DW_WHEEL_PETAL_EDGE (hex colours).
        private static func override(_ key: String) -> NSColor? {
            ProcessInfo.processInfo.environment[key].flatMap { NSColor(hex: $0) }
        }
        /// Label and symbol colour on a light petal: a dark grey (#3A3A3C), not black.
        static let ink = NSColor(srgbRed: 0x3A / 255.0, green: 0x3A / 255.0, blue: 0x3C / 255.0, alpha: 1)
        static func ring(_ dark: Bool) -> NSColor { override("DW_WHEEL_RING") ?? (dark ? NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1) : NSColor(srgbRed: 0xEE / 255.0, green: 0xEF / 255.0, blue: 0xF1 / 255.0, alpha: 1)) }   // #EEEFF1 (F; E was #EBECEE)
        static func hole(_ dark: Bool) -> NSColor { dark ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1) : .white }
        /// Petal fill: its middle, and its edges.
        static func petalMiddle(_ dark: Bool) -> NSColor { override("DW_WHEEL_PETAL_MID") ?? petalMiddleDefault(dark) }
        /// Petal fill (your pick, variation 8): lighter toward the wheel's centre, the same in every petal.
        /// Light: #F0F0F2 → #E3E4E7 (light-mode shade 10). Dark: #434347 → #36363A.
        static func petalMiddleDefault(_ dark: Bool) -> NSColor { dark ? NSColor(srgbRed: 0x43 / 255.0, green: 0x43 / 255.0, blue: 0x47 / 255.0, alpha: 1) : NSColor(srgbRed: 0xF0 / 255.0, green: 0xF0 / 255.0, blue: 0xF2 / 255.0, alpha: 1) }
        static func petalEdge(_ dark: Bool) -> NSColor { override("DW_WHEEL_PETAL_EDGE") ?? petalEdgeDefault(dark) }
        static func petalEdgeDefault(_ dark: Bool) -> NSColor { dark ? NSColor(srgbRed: 0x36 / 255.0, green: 0x36 / 255.0, blue: 0x3A / 255.0, alpha: 1) : NSColor(srgbRed: 0xE3 / 255.0, green: 0xE4 / 255.0, blue: 0xE7 / 255.0, alpha: 1) }
        /// The petal border (variation 12): #D1D1D6 (systemGray4) on the #EEEFF1 ring in light mode, #3A3A3C in dark.
        /// DW_WHEEL_BORDER=<hex> and DW_WHEEL_BORDER_WIDTH=<pt> override them for design previews.
        static func border(_ dark: Bool) -> NSColor {
            if let hex = ProcessInfo.processInfo.environment["DW_WHEEL_BORDER"], let c = NSColor(hex: hex) { return c }
            return dark ? NSColor(srgbRed: 0x3A / 255.0, green: 0x3A / 255.0, blue: 0x3C / 255.0, alpha: 1)
                        : NSColor(srgbRed: 0xD1 / 255.0, green: 0xD1 / 255.0, blue: 0xD6 / 255.0, alpha: 1)
        }
        static var borderWidth: CGFloat {
            ProcessInfo.processInfo.environment["DW_WHEEL_BORDER_WIDTH"].flatMap(Double.init).map { CGFloat($0) } ?? 2
        }
        static func capsule(_ dark: Bool) -> NSColor { dark ? NSColor(srgbRed: 0.24, green: 0.24, blue: 0.26, alpha: 1) : .white }
    }

    private func circle(_ r: CGFloat) -> CGRect {
        CGRect(x: layout.center.x - r, y: layout.center.y - r, width: 2 * r, height: 2 * r)
    }

    /// The light ring with a soft shadow beneath it, and the white hole with a soft inner shadow at its rim.
    private func drawPillowBackdrop(_ ctx: CGContext, bloom t: CGFloat) {
        let outerR = layout.introRadius + (layout.backdropOuter - layout.introRadius) * t
        let innerR = layout.backdropInner * t
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2 * s), blur: 10 * s,
                      color: NSColor.shadowColor.withAlphaComponent(dark ? 0.4 : 0.11).cgColor)
        ctx.setFillColor(Pillow.ring(dark).cgColor)
        ctx.fillEllipse(in: circle(outerR))
        ctx.restoreGState()
        // A faint light edge on the ring's outside.
        ctx.saveGState()
        ctx.addEllipse(in: circle(outerR - 0.5 * s))
        ctx.setStrokeColor(NSColor(white: 1, alpha: dark ? 0.08 : 0.7).cgColor)
        ctx.setLineWidth(1 * s)
        ctx.strokePath()
        ctx.restoreGState()
        guard innerR > 1 else { return }
        ctx.saveGState()
        ctx.addEllipse(in: circle(innerR))
        ctx.clip()
        ctx.setFillColor(Pillow.hole(dark).cgColor)
        ctx.fill(circle(innerR))
        // Inner shadow: a band just outside the hole casts onto it.
        ctx.setShadow(offset: CGSize(width: 0, height: -1 * s), blur: 4 * s,
                      color: NSColor.shadowColor.withAlphaComponent(dark ? 0.35 : 0.07).cgColor)
        ctx.addEllipse(in: circle(innerR + 14 * s))
        ctx.addEllipse(in: circle(innerR))
        ctx.setFillColor(Pillow.ring(dark).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    /// A raised pillow: a small soft shadow, then a radial fill from near-white in the petal's middle to light
    /// grey at its edges.
    private func drawPillowPetal(_ ctx: CGContext, path: CGPath, angle: CGFloat, highlighted: Bool,
                                 inner: CGFloat, outer: CGFloat) {
        let middle = layout.point(radius: (inner + outer) / 2, angle: angle)
        let reach = (outer - inner) * 0.78
        // A raised control's shadow: small, soft and light, like a macOS button's.
        ctx.saveGState()
        let shadowColor = highlighted ? DWPalette.deep(accent).withAlphaComponent(dark ? 0.45 : 0.22)
                                      : NSColor.shadowColor.withAlphaComponent(dark ? 0.35 : 0.09)
        ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * s), blur: (highlighted ? 3 : 2) * s, color: shadowColor.cgColor)
        ctx.addPath(path)
        ctx.setFillColor((highlighted ? accent : Pillow.petalEdge(dark)).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if highlighted {
            let deep = DWPalette.deep(accent)
            let colors = [accent, DWPalette.mix(accent, deep, 0.35), DWPalette.mix(accent, deep, 0.8)]
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray,
                                  locations: [0, 0.5, 1]) {
                ctx.drawRadialGradient(g, startCenter: layout.center, startRadius: inner, endCenter: layout.center,
                                       endRadius: outer, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        } else {
            // Fill style. DW_WHEEL_FILL=radial|flat|linear|hub and DW_WHEEL_FILL_REACH=<× of the default reach>
            // override it for design previews.
            let env = ProcessInfo.processInfo.environment
            let mid = Pillow.petalMiddle(dark), edge = Pillow.petalEdge(dark)
            let colors = [mid, DWPalette.mix(mid, edge, 0.5), edge]
            let reachScale = env["DW_WHEEL_FILL_REACH"].flatMap(Double.init).map { CGFloat($0) } ?? 1
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray,
                                  locations: [0, 0.5, 1]) {
                switch env["DW_WHEEL_FILL"] ?? "hub" {
                case "flat":
                    ctx.setFillColor(mid.cgColor)
                    ctx.fill(path.boundingBoxOfPath)
                case "linear":   // light from above: lighter at the top of the petal, evenly across it
                    let box = path.boundingBoxOfPath
                    ctx.drawLinearGradient(g, start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY),
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                case "hub":      // lighter toward the wheel's centre, the same in every petal
                    ctx.drawRadialGradient(g, startCenter: layout.center, startRadius: inner, endCenter: layout.center,
                                           endRadius: outer, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                default:
                    ctx.drawRadialGradient(g, startCenter: middle, startRadius: 0, endCenter: middle, endRadius: reach * reachScale,
                                           options: [.drawsAfterEndLocation])
                }
            }
        }
        ctx.restoreGState()
    }

    /// The pillow's rim: a light inner edge (brighter on the side facing up) and a faint outer hairline.
    private func drawPillowRim(_ ctx: CGContext, path: CGPath, highlighted: Bool, alpha: CGFloat) {
        guard alpha > 0 else { return }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor(white: 1, alpha: (highlighted ? 0.22 : (dark ? 0.08 : 0.75)) * alpha).cgColor)
        ctx.setLineWidth(1.5 * s)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
        // A distinct grey border, so every petal stands apart from the light ring behind it.
        ctx.addPath(path)
        ctx.setStrokeColor((highlighted ? DWPalette.deep(accent) : Pillow.border(dark)).withAlphaComponent(alpha).cgColor)
        ctx.setLineWidth(Pillow.borderWidth * s)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    // MARK: Petals

    /// A petal's body (metallic, or the glass pillow), then its highlight.
    func drawPetal(_ ctx: CGContext, path: CGPath, angle: CGFloat, highlighted: Bool, ring: WheelLayout.Ring? = nil) {
        switch style {
        case .metallic:
            ctx.addPath(path)
            ctx.setFillColor((highlighted ? Self.steelDark : Self.graphite).cgColor)
            ctx.fillPath()
            if highlighted { drawSteel(ctx, path: path, angle: angle) }
        case .glass:
            drawPillowPetal(ctx, path: path, angle: angle, highlighted: highlighted,
                            inner: ring?.inner ?? layout.inner, outer: ring?.outer ?? layout.outer)
        }
    }

    /// The petal's edge: a 0.75 pt hairline on glass, brushed-steel rim on a highlighted metallic petal.
    func drawBorder(_ ctx: CGContext, path: CGPath, angle: CGFloat, highlighted: Bool, alpha: CGFloat) {
        switch style {
        case .glass:
            drawPillowRim(ctx, path: path, highlighted: highlighted, alpha: alpha)
        case .metallic:
            guard highlighted else { return }
            // A light–dark–light rim along the petal's direction, 1.5 pt.
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setLineWidth(1.5 * s)
            ctx.setLineJoin(.round)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            let (start, end) = steelAxis(angle)
            let colors = [NSColor.white.cgColor, Self.steelEdge.cgColor, NSColor.white.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.485577, 1]) {
                ctx.drawLinearGradient(g, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx.restoreGState()
        }
    }

    /// Brushed steel: #969696 at the rim to #E0E0E0 toward the hub, along the petal's direction.
    private func drawSteel(_ ctx: CGContext, path: CGPath, angle: CGFloat) {
        let colors = [Self.steelDark.cgColor, Self.steelLight.cgColor] as CFArray
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else { return }
        let (start, end) = steelAxis(angle)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(g, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// From just outside the outer edge (0.324 of the panel from the centre) to 0.108 of it, along `angle`.
    private func steelAxis(_ angle: CGFloat) -> (CGPoint, CGPoint) {
        let grow = layout.outer - WheelMetrics.outerRadius * s
        let outerR = 0.324 * WheelMetrics.panelSide * s + grow
        let innerR = 0.108 * WheelMetrics.panelSide * s + grow
        return (layout.point(radius: outerR, angle: angle), layout.point(radius: innerR, angle: angle))
    }

    // MARK: Centre

    var capsulePath: CGPath {
        let r = layout.capsuleRect
        return CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
    }

    /// The centre capsule: solid black on metal; on glass, a light capsule with a soft shadow.
    func drawCapsule(_ ctx: CGContext) {
        switch style {
        case .metallic:
            ctx.addPath(capsulePath)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
        case .glass:
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * s), blur: 3 * s,
                          color: NSColor.shadowColor.withAlphaComponent(dark ? 0.35 : 0.10).cgColor)
            ctx.addPath(capsulePath)
            ctx.setFillColor(Pillow.capsule(dark).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(capsulePath)
            ctx.setStrokeColor(NSColor(white: 0, alpha: dark ? 0.3 : 0.04).cgColor)
            ctx.setLineWidth(0.5 * s)
            ctx.strokePath()
        }
    }
}

/// A soft desktop-like background for previews and snapshots, so translucent styles can be judged.
enum ThemeDesktop {
    static func draw(in rect: CGRect, dark: Bool) {
        let colors = dark
            ? [NSColor(srgbRed: 0.10, green: 0.13, blue: 0.22, alpha: 1), NSColor(srgbRed: 0.24, green: 0.16, blue: 0.30, alpha: 1)]
            : [NSColor(srgbRed: 0.62, green: 0.76, blue: 0.93, alpha: 1), NSColor(srgbRed: 0.93, green: 0.78, blue: 0.70, alpha: 1)]
        NSGradient(colors: colors)?.draw(in: rect, angle: -60)
    }
}
