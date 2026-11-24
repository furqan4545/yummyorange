import AppKit
import SwiftUI

/// Every YummyOrange brand colour, in one place. Change `base` and `glow` and everything else follows: the other
/// tones are derived from those two by the same rules the reference design uses for its own palette.
///
/// - `base` and `glow` are the two seeds (the welcome page's background colour and its bottom glow).
/// - Derived tones move the base hue along the base → glow axis by a fraction of the hue gap between them
///   (negative fractions go the other way, deeper), keeping the base saturation unless stated:
///   `accent` −0.219, `button` +0.129, `folderTop` +0.53 at 0.68 × saturation.
/// - `accentLight` is the accent blended 24 % toward white, `accentHighlight` 42 % toward white, and `accentDeep`
///   is the accent with saturation × 1.12 (capped at 1) and brightness × 0.74.
enum DWPalette {
    // MARK: Seeds

    /// #E2669C, dahlia pink: the welcome page background and the highlighted petal.
    static let base = NSColor(srgbRed: 0xE2 / 255.0, green: 0x66 / 255.0, blue: 0x9C / 255.0, alpha: 1)
    /// #FFE1A1, butter yellow: the soft glow at the bottom of the welcome page.
    static let glow = NSColor(srgbRed: 0xFF / 255.0, green: 0xE1 / 255.0, blue: 0xA1 / 255.0, alpha: 1)
    /// #FFF4EA, the cream of the petal tips.
    static let cream = NSColor(srgbRed: 0xFF / 255.0, green: 0xF4 / 255.0, blue: 0xEA / 255.0, alpha: 1)

    // MARK: Derived tones

    /// The accent: page dots, hand-written notes, raised key caps, the "new file" badge, switches.
    static let accent = shifted(base, towardGlow: -0.219)
    /// The filled Continue button.
    static let button = shifted(base, towardGlow: 0.129)
    /// Top of the folder gradient in the "saved next to the original" illustration (bottom is `accent`).
    static let folderTop = shifted(base, towardGlow: 0.53, saturation: 0.68)
    /// Top of a raised key cap.
    static let accentLight = blend(accent, .white, 0.24)
    /// Inner stop of the highlight gradient.
    static let accentHighlight = blend(accent, .white, 0.42)
    /// Side of a raised key cap, its well, and the rim of the highlight gradient.
    static let accentDeep = deepened(accent)

    /// The accent where it sits on the window background: the accent itself in light mode, `accentLight` in dark
    /// mode, so hand-written notes stay readable on the dark text background.
    static let accentOnBackground = NSColor(name: "DWPalette.accentOnBackground") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? accentLight : accent
    }

    // MARK: Window chrome (not brand colours, kept here so every colour lives in one file)

    /// The close dot (Display P3).
    static let closeDot = NSColor(displayP3Red: 0.9222, green: 0.0771, blue: 0.0771, alpha: 1)
    /// The minimize dot (Display P3).
    static let minimizeDot = NSColor(displayP3Red: 1.0, green: 0.7833, blue: 0.0, alpha: 1)
    /// Key caps that are not raised: a near-black face and side.
    static let keyFaceTop = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1)
    static let keyFaceBottom = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1)
    static let keySide = NSColor(srgbRed: 0.04, green: 0.04, blue: 0.04, alpha: 1)

    // MARK: SwiftUI

    static func color(_ c: NSColor) -> Color { Color(nsColor: c) }

    // MARK: Derivation

    /// sRGB hue, saturation and brightness of a colour.
    static func hsb(_ c: NSColor) -> (h: CGFloat, s: CGFloat, b: CGFloat) {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b)
    }

    /// The signed hue step (in turns, −0.5…0.5) from `base` to `glow`, the short way round.
    static var hueGap: CGFloat {
        var d = hsb(glow).h - hsb(base).h
        if d > 0.5 { d -= 1 }
        if d < -0.5 { d += 1 }
        return d
    }

    /// `color` with its hue moved by `fraction` of the base → glow hue gap, and its saturation scaled.
    static func shifted(_ color: NSColor, towardGlow fraction: CGFloat, saturation: CGFloat = 1) -> NSColor {
        let c = hsb(color)
        var h = c.h + fraction * hueGap
        h -= floor(h)
        return srgb(hue: h, saturation: min(max(c.s * saturation, 0), 1), brightness: c.b)
    }

    /// `a` mixed toward `b` by `t` in sRGB.
    static func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let x = a.usingColorSpace(.sRGB) ?? a, y = b.usingColorSpace(.sRGB) ?? b
        return NSColor(srgbRed: x.redComponent + (y.redComponent - x.redComponent) * t,
                       green: x.greenComponent + (y.greenComponent - x.greenComponent) * t,
                       blue: x.blueComponent + (y.blueComponent - x.blueComponent) * t, alpha: 1)
    }

    /// Saturation × 1.12 (capped at 1) and brightness × 0.74.
    static func deepened(_ color: NSColor) -> NSColor {
        let c = hsb(color)
        return srgb(hue: c.h, saturation: min(c.s * 1.12, 1), brightness: max(c.b * 0.74, 0))
    }

    /// An sRGB colour from hue, saturation and brightness (all 0…1).
    static func srgb(hue h: CGFloat, saturation s: CGFloat, brightness v: CGFloat) -> NSColor {
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
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// "#RRGGBB" of a colour in sRGB (tests and logs).
    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}
