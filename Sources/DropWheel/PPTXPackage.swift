import Foundation
import CoreGraphics
import ImageIO

/// Where a deck's parts come from: a ZIP package on disk, or parts built in memory (decks converted from PPT).
protocol PPTXParts {
    var names: [String] { get }
    func data(_ name: String) -> Data?
}

/// Parts read from a PPTX/PPSX/POTX file.
struct PPTXZipParts: PPTXParts {
    let zip: ZipReader
    var names: [String] { zip.names }
    /// Parts are inflated whole, so absurd declared sizes (damaged or hostile files) are refused.
    func data(_ name: String) -> Data? {
        guard let e = zip.entry(name), e.size < 1 << 30, e.compressedSize < 1 << 30 else { return nil }
        return try? zip.read(e)
    }
}

/// Parts held in memory.
struct PPTXMemoryParts: PPTXParts {
    var files: [String: Data]
    var names: [String] { Array(files.keys) }
    func data(_ name: String) -> Data? { files[name] ?? files.first { $0.key.lowercased() == name.lowercased() }?.value }
}

/// One package relationship, with its target resolved to a part name (or kept as a URL when external).
struct PPTXRel {
    let id: String
    /// The last path component of the relationship type ("slide", "slideLayout", "image", ...).
    let kind: String
    let target: String
    let external: Bool
}

/// Parsed XML parts, relationships and decoded images of one package, cached.
final class PPTXPackage {
    let parts: PPTXParts
    private var xmlCache: [String: PPTXNode?] = [:]
    private var relsCache: [String: [String: PPTXRel]] = [:]
    private var imageCache: [String: CGImageSource?] = [:]
    private let lock = NSLock()

    init(_ parts: PPTXParts) { self.parts = parts }

    func xml(_ part: String) -> PPTXNode? {
        lock.lock(); defer { lock.unlock() }
        if let cached = xmlCache[part] { return cached }
        let parsed = parts.data(part).flatMap { PPTXXMLParser.parse($0) }
        xmlCache[part] = parsed
        return parsed
    }

    /// Relationships of a part, keyed by id.
    func rels(_ part: String) -> [String: PPTXRel] {
        lock.lock()
        if let cached = relsCache[part] { lock.unlock(); return cached }
        lock.unlock()
        let dir = (part as NSString).deletingLastPathComponent
        let relsPart = (dir.isEmpty ? "" : dir + "/") + "_rels/" + (part as NSString).lastPathComponent + ".rels"
        var out: [String: PPTXRel] = [:]
        if let root = xml(relsPart) {
            for r in root.children where r.localName == "Relationship" {
                guard let id = r["Id"], let target = r["Target"] else { continue }
                let kind = (r["Type"] ?? "").split(separator: "/").last.map(String.init) ?? ""
                let external = r["TargetMode"]?.lowercased() == "external"
                out[id] = PPTXRel(id: id, kind: kind, target: external ? target : Self.resolve(target, from: part), external: external)
            }
        }
        lock.lock(); relsCache[part] = out; lock.unlock()
        return out
    }

    func rel(_ part: String, kind: String) -> PPTXRel? {
        rels(part).values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }.first { $0.kind == kind && !$0.external }
    }

    /// Resolves a relationship target relative to the part that owns it.
    static func resolve(_ target: String, from part: String) -> String {
        var t = target.removingPercentEncoding ?? target
        if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }
        if t.hasPrefix("/") { return String(t.dropFirst()) }
        var comps = (part as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for c in t.split(separator: "/").map(String.init) {
            if c == ".." { if !comps.isEmpty { comps.removeLast() } } else if c != "." { comps.append(c) }
        }
        return comps.joined(separator: "/")
    }

    /// An image source for a media part (nil for formats ImageIO can't read, such as EMF and WMF).
    func imageSource(_ part: String) -> CGImageSource? {
        lock.lock(); defer { lock.unlock() }
        if let cached = imageCache[part] { return cached }
        var src: CGImageSource?
        if let data = parts.data(part), let s = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(s) > 0,
           CGImageSourceGetType(s) != nil {
            src = s
        }
        imageCache[part] = src
        return src
    }

    /// Decodes a media part, downsampled so its longer side is at most `maxPixels`.
    func image(_ part: String, maxPixels: Int) -> CGImage? {
        guard let src = imageSource(part) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        if max(w, h) > 0, max(w, h) <= maxPixels {
            return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixels),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

// MARK: - Colours

/// An RGBA colour with the DrawingML colour transforms.
struct PPTXColor: Equatable {
    var r: Double, g: Double, b: Double, a: Double = 1

    static let black = PPTXColor(r: 0, g: 0, b: 0)
    static let white = PPTXColor(r: 1, g: 1, b: 1)

    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    init?(hex: String) {
        let s = hex.trimmingCharacters(in: .whitespaces)
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255
    }

    var hex: String {
        String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)])!
    }

    func with(alpha: Double) -> PPTXColor { var c = self; c.a = alpha; return c }

    // HSL, all components 0...1.
    var hsl: (h: Double, s: Double, l: Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h /= 6
        return (h, s, l)
    }

    init(h: Double, s: Double, l: Double, a: Double = 1) {
        func hue(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        if s == 0 { self.init(r: l, g: l, b: l, a: a); return }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        self.init(r: hue(p, q, h + 1.0 / 3), g: hue(p, q, h), b: hue(p, q, h - 1.0 / 3), a: a)
    }

    private static func toLinear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    private static func toSRGB(_ c: Double) -> Double {
        let v = min(1, max(0, c))
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// Applies one transform child of a colour element (lumMod, tint, alpha, ...). `v` is the raw value / 100000.
    mutating func apply(_ op: String, _ v: Double) {
        func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
        switch op {
        case "lumMod": var c = hsl; c.l = clamp(c.l * v); self = PPTXColor(h: c.h, s: c.s, l: c.l, a: a)
        case "lumOff": var c = hsl; c.l = clamp(c.l + v); self = PPTXColor(h: c.h, s: c.s, l: c.l, a: a)
        case "satMod": var c = hsl; c.s = clamp(c.s * v); self = PPTXColor(h: c.h, s: c.s, l: c.l, a: a)
        case "satOff": var c = hsl; c.s = clamp(c.s + v); self = PPTXColor(h: c.h, s: c.s, l: c.l, a: a)
        case "hueMod": var c = hsl; c.h = (c.h * v).truncatingRemainder(dividingBy: 1); self = PPTXColor(h: c.h, s: c.s, l: c.l, a: a)
        case "hueOff":
            // hueOff is in 60000ths of a degree, so v (value / 100000) needs rescaling.
            var c = hsl; c.h = (c.h + v * 100000 / 60000 / 360).truncatingRemainder(dividingBy: 1); if c.h < 0 { c.h += 1 }
            self = PPTXColor(h: c.h, s: c.s, l: c.l, a: a)
        case "tint":
            // Towards white, in linear light (how Office applies it).
            r = Self.toSRGB(1 - (1 - Self.toLinear(r)) * v)
            g = Self.toSRGB(1 - (1 - Self.toLinear(g)) * v)
            b = Self.toSRGB(1 - (1 - Self.toLinear(b)) * v)
        case "shade":
            r = Self.toSRGB(Self.toLinear(r) * v); g = Self.toSRGB(Self.toLinear(g) * v); b = Self.toSRGB(Self.toLinear(b) * v)
        case "alpha": a = clamp(v)
        case "alphaMod": a = clamp(a * v)
        case "alphaOff": a = clamp(a + v)
        case "comp": var c = hsl; c.h = (c.h + 0.5).truncatingRemainder(dividingBy: 1); self = PPTXColor(h: c.h, s: c.s, l: c.l, a: a)
        case "inv": r = 1 - r; g = 1 - g; b = 1 - b
        case "gray": let y = 0.2126 * r + 0.7152 * g + 0.0722 * b; r = y; g = y; b = y
        case "red": r = clamp(v)
        case "green": g = clamp(v)
        case "blue": b = clamp(v)
        case "redMod": r = clamp(r * v)
        case "greenMod": g = clamp(g * v)
        case "blueMod": b = clamp(b * v)
        case "redOff": r = clamp(r + v)
        case "greenOff": g = clamp(g + v)
        case "blueOff": b = clamp(b + v)
        default: break
        }
    }

    /// Named colours of `a:prstClr`.
    static func preset(_ name: String) -> PPTXColor? {
        let table: [String: String] = [
            "black": "000000", "white": "FFFFFF", "red": "FF0000", "green": "008000", "blue": "0000FF", "yellow": "FFFF00",
            "cyan": "00FFFF", "magenta": "FF00FF", "gray": "808080", "grey": "808080", "silver": "C0C0C0", "maroon": "800000",
            "navy": "000080", "olive": "808000", "purple": "800080", "teal": "008080", "lime": "00FF00", "aqua": "00FFFF",
            "fuchsia": "FF00FF", "orange": "FFA500", "pink": "FFC0CB", "brown": "A52A2A", "gold": "FFD700", "indigo": "4B0082",
            "violet": "EE82EE", "ltGray": "D3D3D3", "lightGray": "D3D3D3", "dkGray": "A9A9A9", "darkGray": "A9A9A9",
            "dkBlue": "00008B", "darkBlue": "00008B", "dkRed": "8B0000", "darkRed": "8B0000", "dkGreen": "006400",
            "darkGreen": "006400", "ltBlue": "ADD8E6", "lightBlue": "ADD8E6", "ltGreen": "90EE90", "lightGreen": "90EE90",
            "ltYellow": "FFFFE0", "lightYellow": "FFFFE0", "beige": "F5F5DC", "tan": "D2B48C", "coral": "FF7F50",
            "salmon": "FA8072", "tomato": "FF6347", "crimson": "DC143C", "khaki": "F0E68C", "lavender": "E6E6FA",
            "turquoise": "40E0D0", "skyBlue": "87CEEB", "steelBlue": "4682B4", "royalBlue": "4169E1", "slateGray": "708090",
            "chocolate": "D2691E", "firebrick": "B22222", "forestGreen": "228B22", "seaGreen": "2E8B57", "orchid": "DA70D6",
            "plum": "DDA0DD", "sienna": "A0522D", "wheat": "F5DEB3", "ivory": "FFFFF0", "snow": "FFFAFA", "linen": "FAF0E6",
        ]
        return table[name].flatMap { PPTXColor(hex: $0) }
    }
}

/// A theme: colour scheme, fonts and the format scheme that `p:style` references index into.
struct PPTXTheme {
    var colors: [String: PPTXColor] = [
        "dk1": .black, "lt1": .white, "dk2": PPTXColor(hex: "44546A")!, "lt2": PPTXColor(hex: "E7E6E6")!,
        "accent1": PPTXColor(hex: "4472C4")!, "accent2": PPTXColor(hex: "ED7D31")!, "accent3": PPTXColor(hex: "A5A5A5")!,
        "accent4": PPTXColor(hex: "FFC000")!, "accent5": PPTXColor(hex: "5B9BD5")!, "accent6": PPTXColor(hex: "70AD47")!,
        "hlink": PPTXColor(hex: "0563C1")!, "folHlink": PPTXColor(hex: "954F72")!,
    ]
    var majorLatin = "Calibri Light", minorLatin = "Calibri"
    var majorEA = "", minorEA = "", majorCS = "", minorCS = ""
    var fillStyles: [PPTXNode] = [], lineStyles: [PPTXNode] = [], effectStyles: [PPTXNode] = [], bgFillStyles: [PPTXNode] = []

    init() {}

    init(_ root: PPTXNode?) {
        guard let elements = root?.child("a:themeElements") else { return }
        if let scheme = elements.child("a:clrScheme") {
            for entry in scheme.children {
                let key = entry.localName
                if let c = entry.children.first, let color = PPTXColors.base(c) { colors[key] = color }
            }
        }
        if let fonts = elements.child("a:fontScheme") {
            func face(_ group: String, _ kind: String) -> String? {
                fonts.child(group)?.child(kind)?["typeface"].flatMap { $0.isEmpty ? nil : $0 }
            }
            majorLatin = face("a:majorFont", "a:latin") ?? majorLatin
            minorLatin = face("a:minorFont", "a:latin") ?? minorLatin
            majorEA = face("a:majorFont", "a:ea") ?? ""
            minorEA = face("a:minorFont", "a:ea") ?? ""
            majorCS = face("a:majorFont", "a:cs") ?? ""
            minorCS = face("a:minorFont", "a:cs") ?? ""
        }
        if let fmt = elements.child("a:fmtScheme") {
            fillStyles = fmt.child("a:fillStyleLst")?.children ?? []
            lineStyles = fmt.child("a:lnStyleLst")?.children ?? []
            effectStyles = fmt.child("a:effectStyleLst")?.children ?? []
            bgFillStyles = fmt.child("a:bgFillStyleLst")?.children ?? []
        }
    }

    /// Resolves "+mj-lt", "+mn-ea" and similar theme font references.
    func font(_ typeface: String) -> String {
        switch typeface {
        case "+mj-lt": return majorLatin
        case "+mn-lt": return minorLatin
        case "+mj-ea": return majorEA.isEmpty ? majorLatin : majorEA
        case "+mn-ea": return minorEA.isEmpty ? minorLatin : minorEA
        case "+mj-cs": return majorCS.isEmpty ? majorLatin : majorCS
        case "+mn-cs": return minorCS.isEmpty ? minorLatin : minorCS
        default: return typeface
        }
    }
}

/// Everything needed to turn a colour element into RGBA: the theme, the slide's colour map and,
/// inside a style reference, the placeholder colour (`phClr`).
struct PPTXColors {
    var theme: PPTXTheme
    var map: [String: String]
    var phClr: PPTXColor?

    static let colorNames: Set<String> = ["a:srgbClr", "a:schemeClr", "a:sysClr", "a:prstClr", "a:scrgbClr", "a:hslClr"]

    /// Colour of an element without scheme lookups (used for the theme's own scheme entries).
    static func base(_ n: PPTXNode) -> PPTXColor? {
        var c: PPTXColor?
        switch n.name {
        case "a:srgbClr": c = n["val"].flatMap { PPTXColor(hex: $0) }
        case "a:sysClr":
            c = n["lastClr"].flatMap { PPTXColor(hex: $0) }
                ?? (["windowText", "menuText", "captionText", "btnText", "infoText"].contains(n["val"] ?? "") ? .black : .white)
        case "a:prstClr": c = n["val"].flatMap { PPTXColor.preset($0) }
        case "a:scrgbClr":
            func lin(_ k: String) -> Double {
                let v = (n.double(k) ?? 0) / 100000
                return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
            }
            c = PPTXColor(r: lin("r"), g: lin("g"), b: lin("b"))
        case "a:hslClr":
            c = PPTXColor(h: (n.double("hue") ?? 0) / 60000 / 360, s: (n.double("sat") ?? 0) / 100000, l: (n.double("lum") ?? 0) / 100000)
        default: return nil
        }
        guard var color = c else { return nil }
        applyTransforms(n, to: &color)
        return color
    }

    static func applyTransforms(_ n: PPTXNode, to color: inout PPTXColor) {
        for t in n.children {
            let op = t.localName
            if op == "comp" || op == "inv" || op == "gray" { color.apply(op, 0); continue }
            guard let raw = t["val"], let v = Double(raw.replacingOccurrences(of: "%", with: "")) else { continue }
            // Some writers use percentages ("50%") instead of 1000ths of a percent.
            color.apply(op, raw.hasSuffix("%") ? v / 100 : v / 100000)
        }
    }

    /// Colour of a colour element (`a:srgbClr`, `a:schemeClr`, ...).
    func color(_ n: PPTXNode) -> PPTXColor? {
        guard n.name == "a:schemeClr" else { return Self.base(n) }
        let val = n["val"] ?? ""
        var c: PPTXColor?
        if val == "phClr" {
            c = phClr ?? .black
        } else {
            let key = map[val] ?? val
            c = theme.colors[key] ?? theme.colors[val]
        }
        guard var color = c else { return nil }
        Self.applyTransforms(n, to: &color)
        return color
    }

    /// The colour held by the first colour child of `n` (for `a:solidFill`, `a:fgClr`, `a:buClr`, ...).
    func colorChild(_ n: PPTXNode?) -> PPTXColor? {
        guard let n, let c = n.children.first(where: { Self.colorNames.contains($0.name) }) else { return nil }
        return color(c)
    }

    func with(phClr: PPTXColor?) -> PPTXColors { var c = self; c.phClr = phClr; return c }
}
