import AppKit

/// The wheel's colour helpers. The brand seeds live in DWPalette.swift.
extension DWPalette {
    /// The colour of a highlighted wheel petal before shading.
    static var wheelAccent: NSColor { base }

    /// The accent in HSB with saturation × 1.12 (at most 1) and brightness × 0.74.
    static func deep(_ color: NSColor) -> NSColor {
        let c = srgb(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(colorSpace: .sRGB, hue: h, saturation: min(1, s * 1.12), brightness: b * 0.74, alpha: a)
    }

    /// Mixes two colours in sRGB: 0 gives `a`, 1 gives `b`.
    static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let x = srgb(a), y = srgb(b)
        return NSColor(srgbRed: x.redComponent + (y.redComponent - x.redComponent) * t,
                       green: x.greenComponent + (y.greenComponent - x.greenComponent) * t,
                       blue: x.blueComponent + (y.blueComponent - x.blueComponent) * t,
                       alpha: x.alphaComponent + (y.alphaComponent - x.alphaComponent) * t)
    }

    static func srgb(_ c: NSColor) -> NSColor { c.usingColorSpace(.sRGB) ?? c }
}
