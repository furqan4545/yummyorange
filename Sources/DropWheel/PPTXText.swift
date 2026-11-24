import Foundation
import CoreGraphics
import CoreText

// MARK: - Fonts

/// Finds installed fonts for PowerPoint typefaces, substituting metric-similar Mac fonts for Office fonts
/// that aren't installed (Calibri, Segoe UI, Cambria, ...). One per render job; not shared across threads.
final class PPTXFontBook {
    struct Pick {
        let font: CTFont
        let fakeBold: Bool
        /// Line metrics in points: from the original font when it was substituted and its metrics are known.
        let ascent: CGFloat
        let descent: CGFloat
    }

    private var cache: [String: Pick] = [:]
    private var installed: [String: Bool] = [:]

    /// Office fonts missing on a Mac → the closest installed family.
    private static let substitutes: [String: String] = [
        "calibri": "Seravek", "calibri light": "Seravek Light", "candara": "Seravek", "corbel": "Seravek",
        "segoe ui": "Seravek", "segoe ui light": "Seravek Light", "segoe ui semibold": "Seravek Medium",
        "segoe ui semilight": "Seravek Light", "segoe ui black": "Seravek Bold", "source sans pro": "Seravek",
        "lato": "Seravek", "carlito": "Seravek",
        "aptos": "Helvetica Neue", "aptos display": "Helvetica Neue", "aptos narrow": "Arial Narrow",
        "open sans": "Helvetica Neue", "roboto": "Helvetica Neue", "arial nova": "Helvetica Neue",
        "franklin gothic book": "Helvetica Neue", "franklin gothic medium": "Helvetica Neue",
        "franklin gothic demi": "Helvetica Neue", "franklin gothic medium cond": "Avenir Next Condensed",
        "bahnschrift": "Avenir Next Condensed", "montserrat": "Avenir Next", "century gothic": "Avenir Next",
        "tw cen mt": "Futura", "gill sans mt": "Gill Sans", "dubai": "Helvetica Neue", "liberation sans": "Arial",
        "arimo": "Arial", "helvetica light": "Helvetica Neue",
        "cambria": "Georgia", "cambria math": "Georgia", "constantia": "Georgia", "georgia pro": "Georgia",
        "bookman old style": "Georgia", "century schoolbook": "Georgia", "rockwell": "Georgia",
        "garamond": "Baskerville", "calisto mt": "Baskerville", "book antiqua": "Palatino",
        "palatino linotype": "Palatino", "liberation serif": "Times New Roman", "tinos": "Times New Roman",
        "consolas": "Menlo", "lucida console": "Menlo", "cascadia code": "Menlo", "cascadia mono": "Menlo",
        "liberation mono": "Courier New", "cousine": "Courier New",
        "segoe print": "Noteworthy", "segoe script": "Snell Roundhand", "lucida handwriting": "Snell Roundhand",
        "ms gothic": "Hiragino Sans", "ms pgothic": "Hiragino Sans", "ms ui gothic": "Hiragino Sans",
        "meiryo": "Hiragino Sans", "meiryo ui": "Hiragino Sans", "yu gothic": "Hiragino Sans",
        "yu gothic ui": "Hiragino Sans", "ms mincho": "Hiragino Mincho ProN", "ms pmincho": "Hiragino Mincho ProN",
        "yu mincho": "Hiragino Mincho ProN", "simsun": "PingFang SC", "nsimsun": "PingFang SC", "simhei": "PingFang SC",
        "microsoft yahei": "PingFang SC", "microsoft yahei ui": "PingFang SC", "dengxian": "PingFang SC",
        "dengxian light": "PingFang SC", "microsoft jhenghei": "PingFang TC", "pmingliu": "PingFang TC",
        "mingliu": "PingFang TC", "malgun gothic": "Apple SD Gothic Neo", "gulim": "Apple SD Gothic Neo",
        "batang": "Apple SD Gothic Neo", "dotum": "Apple SD Gothic Neo",
    ]

    /// Ascent and descent (per point of size) of common Office fonts, so line spacing matches PowerPoint
    /// even when the font itself is substituted.
    private static let knownMetrics: [String: (CGFloat, CGFloat)] = [
        "calibri": (0.952, 0.269), "calibri light": (0.952, 0.269), "segoe ui": (1.079, 0.251),
        "segoe ui light": (1.079, 0.251), "segoe ui semibold": (1.079, 0.251), "cambria": (0.95, 0.222),
        "century gothic": (1.006, 0.220), "candara": (0.952, 0.269), "corbel": (0.952, 0.269),
    ]

    private func isInstalled(_ face: String) -> Bool {
        let key = face.lowercased()
        if let v = installed[key] { return v }
        let f = CTFontCreateWithName(face as CFString, 12, nil)
        let norm = { (s: String) in s.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "") }
        let want = norm(face)
        let names = [CTFontCopyFamilyName(f) as String, CTFontCopyFullName(f) as String, CTFontCopyPostScriptName(f) as String]
        let ok = names.contains { norm($0) == want }
        installed[key] = ok
        return ok
    }

    /// The family to use for a typeface, and the original's metrics when substituted.
    func family(for face: String, pitch: Int?) -> (String, (CGFloat, CGFloat)?) {
        let clean = face.trimmingCharacters(in: .whitespaces)
        if !clean.isEmpty, isInstalled(clean) { return (clean, nil) }
        let key = clean.lowercased()
        if let sub = Self.substitutes[key] { return (sub, Self.knownMetrics[key]) }
        switch (pitch ?? 0) >> 4 {
        case 1: return ("Times New Roman", nil)
        case 3: return ("Courier New", nil)
        case 4: return ("Snell Roundhand", nil)
        default:
            if key.contains("serif") && !key.contains("sans") { return ("Times New Roman", nil) }
            if key.contains("mono") || key.contains("code") { return ("Menlo", nil) }
            return ("Helvetica Neue", nil)
        }
    }

    func pick(face: String, size: CGFloat, bold: Bool, italic: Bool, pitch: Int?) -> Pick {
        let key = "\(face)|\(size)|\(bold)|\(italic)|\(pitch ?? -1)"
        if let p = cache[key] { return p }
        let (family, known) = self.family(for: face, pitch: pitch)
        var font = CTFontCreateWithName(family as CFString, size, nil)
        var fakeBold = false
        var traits = CTFontSymbolicTraits()
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty {
            let current = CTFontGetSymbolicTraits(font)
            if !current.contains(traits) {
                if let styled = CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) {
                    font = styled
                } else {
                    if italic, let i = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitItalic, .traitItalic) {
                        font = i
                    } else if italic {
                        var skew = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
                        font = CTFontCreateCopyWithAttributes(font, size, &skew, nil)
                    }
                    if bold, let bf = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) {
                        font = bf
                    } else if bold {
                        fakeBold = true
                    }
                }
            }
        }
        let asc: CGFloat, desc: CGFloat
        if let known {
            asc = known.0 * size; desc = known.1 * size
        } else {
            asc = CTFontGetAscent(font); desc = CTFontGetDescent(font) + CTFontGetLeading(font)
        }
        let p = Pick(font: font, fakeBold: fakeBold, ascent: asc, descent: desc)
        cache[key] = p
        return p
    }

    /// Characters of the classic Symbol font, which the Mac's Symbol font maps as Unicode.
    static func symbolChar(_ s: String) -> String {
        let map: [UInt32: String] = [0xB7: "•", 0xA7: "♣", 0xA8: "♦", 0xA9: "♥", 0xAA: "♠", 0xAE: "→", 0xDE: "⇒",
                                     0xE0: "◊", 0xD7: "⋅", 0xF0B7: "•", 0x2D: "−", 0xBE: "—", 0xD8: "¬"]
        return String(s.unicodeScalars.map { map[$0.value] ?? String($0) }.joined())
    }
}

// MARK: - Styles

/// Run formatting gathered from `a:rPr`, list styles and defaults (only the properties that were set).
struct PPTXRunStyle {
    var size: CGFloat?
    var bold: Bool?
    var italic: Bool?
    var underline: String?
    var strike: String?
    var baseline: Double?
    var cap: String?
    var spacing: CGFloat?
    var color: PPTXColor?
    var noFill: Bool?
    var latin: String?
    var latinPitch: Int?
    var ea: String?
    var sym: String?
    var highlight: PPTXColor?
    var outline: (CGFloat, PPTXColor)??
    var shadow: PPTXShadow??
    var hyperlink: Bool?

    /// Fills the properties not set yet from `rPr` (or a `defRPr`).
    mutating func fillMissing(_ rPr: PPTXNode?, colors: PPTXColors) {
        guard let r = rPr else { return }
        if size == nil, let v = r.double("sz") { size = CGFloat(v) / 100 }
        if bold == nil { bold = r.bool("b") }
        if italic == nil { italic = r.bool("i") }
        if underline == nil { underline = r["u"] }
        if strike == nil { strike = r["strike"] }
        if baseline == nil, let v = r.double("baseline") { baseline = v / 100000 }
        if cap == nil { cap = r["cap"] }
        if spacing == nil, let v = r.double("spc") { spacing = CGFloat(v) / 100 }
        if color == nil && noFill == nil {
            if r.child("a:noFill") != nil { noFill = true }
            else if let s = r.child("a:solidFill") { color = colors.colorChild(s) }
            else if let g = r.child("a:gradFill") { color = colors.colorChild(g.child("a:gsLst")?.child("a:gs")) }
            else if let p = r.child("a:pattFill") { color = colors.colorChild(p.child("a:fgClr")) }
        }
        if latin == nil, let l = r.child("a:latin"), let face = l["typeface"], !face.isEmpty {
            latin = face; latinPitch = l.int("pitchFamily")
        }
        if ea == nil, let face = r.child("a:ea")?["typeface"], !face.isEmpty { ea = face }
        if sym == nil, let face = r.child("a:sym")?["typeface"], !face.isEmpty { sym = face }
        if highlight == nil, let h = r.child("a:highlight") { highlight = colors.colorChild(h) }
        if outline == nil, let ln = r.child("a:ln") {
            if ln.child("a:noFill") != nil || ln.child("a:solidFill") == nil {
                outline = .some(nil)
            } else if let c = colors.colorChild(ln.child("a:solidFill")) {
                outline = .some((CGFloat(ln.double("w") ?? 12700) / 12700, c))
            }
        }
        if shadow == nil, let fx = r.child("a:effectLst") { shadow = .some(PPTXShadow(fx, colors: colors)) }
        if hyperlink == nil, r.child("a:hlinkClick") != nil { hyperlink = true }
    }

    mutating func fillMissing(_ other: PPTXRunStyle) {
        size = size ?? other.size; bold = bold ?? other.bold; italic = italic ?? other.italic
        underline = underline ?? other.underline; strike = strike ?? other.strike; baseline = baseline ?? other.baseline
        cap = cap ?? other.cap; spacing = spacing ?? other.spacing
        if color == nil && noFill == nil { color = other.color; noFill = other.noFill }
        if latin == nil { latin = other.latin; latinPitch = other.latinPitch }
        ea = ea ?? other.ea; sym = sym ?? other.sym; highlight = highlight ?? other.highlight
        if outline == nil { outline = other.outline }
        if shadow == nil { shadow = other.shadow }
        hyperlink = hyperlink ?? other.hyperlink
    }
}

/// An outer shadow (`a:outerShdw`) in points.
struct PPTXShadow {
    var blur: CGFloat
    var distance: CGFloat
    var direction: Double
    var color: PPTXColor

    init?(_ effectLst: PPTXNode?, colors: PPTXColors) {
        guard let s = effectLst?.child("a:outerShdw"), let c = colors.colorChild(s) else { return nil }
        blur = CGFloat(s.double("blurRad") ?? 0) / 12700
        distance = CGFloat(s.double("dist") ?? 0) / 12700
        direction = (s.double("dir") ?? 0) / 60000
        color = c
    }
}

/// How a paragraph's bullet is drawn.
enum PPTXBullet {
    case none
    case char(String)
    case autoNumber(String, Int)
}

/// Paragraph formatting gathered from `a:pPr` and list-style levels.
struct PPTXParaStyle {
    var align: String?
    var marL: CGFloat?
    var indent: CGFloat?
    var lineSpacing: (pct: Double?, pts: CGFloat?)?
    var spaceBefore: (pct: Double?, pts: CGFloat?)?
    var spaceAfter: (pct: Double?, pts: CGFloat?)?
    var bullet: PPTXBullet?
    /// nil: unset; .some(nil): follow the text; .some(face)
    var bulletFont: (String, Int?)??
    var bulletColor: PPTXColor??
    var bulletSize: (pct: Double?, pts: CGFloat?)??
    var defaultTab: CGFloat?
    var tabs: [(CGFloat, String)]?

    private static func spacing(_ n: PPTXNode?) -> (pct: Double?, pts: CGFloat?)? {
        guard let n else { return nil }
        if let p = n.child("a:spcPct")?.double("val") { return (p / 100000, nil) }
        if let p = n.child("a:spcPts")?.double("val") { return (nil, CGFloat(p) / 100) }
        return nil
    }

    mutating func fillMissing(_ pPr: PPTXNode?, colors: PPTXColors) {
        guard let p = pPr else { return }
        if align == nil { align = p["algn"] }
        if marL == nil, let v = p.double("marL") { marL = CGFloat(v) / 12700 }
        if indent == nil, let v = p.double("indent") { indent = CGFloat(v) / 12700 }
        if lineSpacing == nil { lineSpacing = Self.spacing(p.child("a:lnSpc")) }
        if spaceBefore == nil { spaceBefore = Self.spacing(p.child("a:spcBef")) }
        if spaceAfter == nil { spaceAfter = Self.spacing(p.child("a:spcAft")) }
        if bullet == nil {
            if p.child("a:buNone") != nil { bullet = PPTXBullet.none }
            else if let c = p.child("a:buChar") { bullet = .char(c["char"] ?? "•") }
            else if let a = p.child("a:buAutoNum") { bullet = .autoNumber(a["type"] ?? "arabicPeriod", max(1, min(32767, a.int("startAt") ?? 1))) }
            else if p.child("a:buBlip") != nil { bullet = .char("•") }
        }
        if bulletFont == nil {
            if p.child("a:buFontTx") != nil { bulletFont = .some(nil) }
            else if let f = p.child("a:buFont"), let face = f["typeface"] { bulletFont = .some((face, f.int("pitchFamily"))) }
        }
        if bulletColor == nil {
            if p.child("a:buClrTx") != nil { bulletColor = .some(nil) }
            else if let c = p.child("a:buClr"), let color = colors.colorChild(c) { bulletColor = .some(color) }
        }
        if bulletSize == nil {
            if p.child("a:buSzTx") != nil { bulletSize = .some(nil) }
            else if let v = p.child("a:buSzPct")?.double("val") { bulletSize = .some((v / 100000, nil)) }
            else if let v = p.child("a:buSzPts")?.double("val") { bulletSize = .some((nil, CGFloat(v) / 100)) }
        }
        if defaultTab == nil, let v = p.double("defTabSz") { defaultTab = CGFloat(v) / 12700 }
        if tabs == nil, let list = p.child("a:tabLst")?.all("a:tab"), !list.isEmpty {
            tabs = list.map { (CGFloat($0.double("pos") ?? 0) / 12700, $0["algn"] ?? "l") }
        }
    }
}

/// `a:bodyPr` with inheritance applied (later `apply` calls override earlier ones).
struct PPTXBodyProps {
    enum Autofit { case none, normal(fontScale: Double, lineReduction: Double), shape }

    var insets = (l: CGFloat(7.2), t: CGFloat(3.6), r: CGFloat(7.2), b: CGFloat(3.6))
    var anchor = "t"
    var wrap = true
    var vert = "horz"
    var rotation: Double = 0
    var autofit = Autofit.none
    var columns = 1
    var columnSpacing: CGFloat = 0

    mutating func apply(_ b: PPTXNode?) {
        guard let b else { return }
        if let v = b.double("lIns") { insets.l = CGFloat(v) / 12700 }
        if let v = b.double("tIns") { insets.t = CGFloat(v) / 12700 }
        if let v = b.double("rIns") { insets.r = CGFloat(v) / 12700 }
        if let v = b.double("bIns") { insets.b = CGFloat(v) / 12700 }
        if let v = b["anchor"] { anchor = v }
        if let v = b["wrap"] { wrap = v != "none" }
        if let v = b["vert"] { vert = v }
        if let v = b.double("rot") { rotation = v / 60000 }
        if let v = b.int("numCol") { columns = max(1, min(16, v)) }
        if let v = b.double("spcCol") { columnSpacing = CGFloat(v) / 12700 }
        if let n = b.child("a:normAutofit") {
            autofit = .normal(fontScale: (n.double("fontScale") ?? 100000) / 100000,
                              lineReduction: (n.double("lnSpcReduction") ?? 0) / 100000)
        } else if b.child("a:noAutofit") != nil {
            autofit = .none
        } else if b.child("a:spAutoFit") != nil {
            autofit = .shape
        }
    }
}

// MARK: - Layout

/// Everything one text body needs to lay itself out.
struct PPTXTextSource {
    var body: PPTXNode
    /// List styles from nearest to farthest (shape, layout placeholder, master placeholder, master text
    /// style, presentation default), each holding `a:lvl1pPr`...`a:lvl9pPr`.
    var listStyles: [PPTXNode?]
    /// Formatting that sits just below the shape's own list style: the shape style's font reference, or
    /// a table style's text properties.
    var styleRun: PPTXRunStyle?
    var props: PPTXBodyProps
    var colors: PPTXColors
    var theme: PPTXTheme
    var slideNumber: Int
}

/// Attribute carried on each run for the drawing pass (things Core Text doesn't draw itself).
final class PPTXRunExtras {
    var underline: String = "none"
    var strike: String = "noStrike"
    var highlight: CGColor?
    var shift: CGFloat = 0
    var shadow: PPTXShadow?
    var visible = true
    var color: CGColor = .black
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    init() {}
}

private let extrasKey = NSAttributedString.Key("DropWheelPPTXRunExtras")

/// Lays out a text body with Core Text and draws it.
final class PPTXTextLayout {
    struct Line {
        var line: CTLine
        var x: CGFloat
        var baseline: CGFloat
        var bullet: (CTLine, CGFloat)?
    }

    private(set) var lines: [Line] = []
    private(set) var height: CGFloat = 0
    let isEmpty: Bool

    private struct Para {
        var text: NSAttributedString
        var style: PPTXParaStyle
        var firstRun: PPTXRunStyle
        var endRun: PPTXRunStyle
        var level: Int
    }

    private let fonts: PPTXFontBook
    private var paras: [Para] = []
    private let source: PPTXTextSource

    init(_ source: PPTXTextSource, fonts: PPTXFontBook) {
        self.source = source
        self.fonts = fonts
        let ps = source.body.all("a:p")
        isEmpty = !ps.contains { p in
            p.children.contains { ($0.name == "a:r" || $0.name == "a:fld") && !($0.child("a:t")?.text.isEmpty ?? true) }
        }
    }

    private func level(_ p: PPTXNode) -> Int { max(0, min(8, p.child("a:pPr")?.int("lvl") ?? 0)) }

    private func levelNode(_ list: PPTXNode?, _ level: Int) -> PPTXNode? { list?.child("a:lvl\(level + 1)pPr") }

    private func runStyle(_ rPr: PPTXNode?, level: Int) -> PPTXRunStyle {
        var s = PPTXRunStyle()
        s.fillMissing(rPr, colors: source.colors)
        for (i, list) in source.listStyles.enumerated() {
            s.fillMissing(levelNode(list, level)?.child("a:defRPr"), colors: source.colors)
            if i == 0, let extra = source.styleRun { s.fillMissing(extra) }
        }
        if source.listStyles.isEmpty, let extra = source.styleRun { s.fillMissing(extra) }
        return s
    }

    private func paraStyle(_ pPr: PPTXNode?, level: Int) -> PPTXParaStyle {
        var s = PPTXParaStyle()
        s.fillMissing(pPr, colors: source.colors)
        for list in source.listStyles { s.fillMissing(levelNode(list, level), colors: source.colors) }
        return s
    }

    /// Font, colour and drawing extras for a run style at a given autofit scale.
    private func attributes(_ s: PPTXRunStyle, scale: Double, text: String) -> [NSAttributedString.Key: Any] {
        var size = (s.size ?? 18) * CGFloat(scale)
        let shift = (s.baseline ?? 0) != 0 ? size * CGFloat(s.baseline ?? 0) : 0
        if (s.baseline ?? 0) != 0 { size *= 2.0 / 3 }
        size = max(1, size)
        let face = source.theme.font(s.latin ?? "+mn-lt")
        var pick = fonts.pick(face: face, size: size, bold: s.bold ?? false, italic: s.italic ?? false, pitch: s.latinPitch)
        // Text that's entirely East Asian uses the East Asian typeface when there is one.
        if let ea = s.ea, text.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) {
            let eaFace = source.theme.font(ea)
            if !eaFace.isEmpty { pick = fonts.pick(face: eaFace, size: size, bold: s.bold ?? false, italic: s.italic ?? false, pitch: nil) }
        }
        var color = s.color ?? .black
        // PowerPoint draws hyperlinks in the theme's hyperlink colour.
        if s.hyperlink == true, let link = source.colors.theme.colors["hlink"] { color = link }
        let extras = PPTXRunExtras()
        extras.underline = s.underline ?? (s.hyperlink == true ? "sng" : "none")
        extras.strike = s.strike ?? "noStrike"
        extras.highlight = s.highlight?.cgColor
        extras.shift = shift
        extras.shadow = s.shadow ?? nil
        extras.visible = !(s.noFill ?? false)
        extras.color = color.cgColor
        extras.ascent = pick.ascent
        extras.descent = pick.descent
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): pick.font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
            extrasKey: extras,
        ]
        if let spc = s.spacing, spc != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = spc * CGFloat(scale) }
        if let o = s.outline ?? nil, o.0 > 0 {
            let pct = o.0 / size * 100
            attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = extras.visible ? -pct : pct
            attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = o.1.cgColor
            extras.visible = true
        } else if pick.fakeBold {
            attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -3.0
            attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = color.cgColor
        }
        return attrs
    }

    private func buildParagraphs(scale: Double) {
        paras = []
        for p in source.body.all("a:p") {
            let lvl = level(p)
            let pPr = p.child("a:pPr")
            let style = paraStyle(pPr, level: lvl)
            let text = NSMutableAttributedString()
            var first: PPTXRunStyle?
            for r in p.children {
                let s: PPTXRunStyle
                var t: String
                switch r.name {
                case "a:r":
                    s = runStyle(r.child("a:rPr"), level: lvl)
                    t = r.child("a:t")?.text ?? ""
                case "a:fld":
                    s = runStyle(r.child("a:rPr"), level: lvl)
                    t = r.child("a:t")?.text ?? ""
                    if (r["type"] ?? "").lowercased() == "slidenum" { t = String(source.slideNumber) }
                case "a:br":
                    s = runStyle(r.child("a:rPr"), level: lvl)
                    t = "\u{2028}"
                default:
                    continue
                }
                if t.isEmpty { continue }
                t = t.replacingOccurrences(of: "\r\n", with: "\u{2028}").replacingOccurrences(of: "\n", with: "\u{2028}")
                    .replacingOccurrences(of: "\u{0B}", with: "\u{2028}")
                if s.cap == "all" || s.cap == "small" { t = t.uppercased() }
                if let symFace = s.sym ?? s.latin, source.theme.font(symFace).lowercased() == "symbol" {
                    t = PPTXFontBook.symbolChar(t)
                }
                if first == nil, r.name != "a:br" { first = s }
                var drawn = s
                // Small caps: capitals at about 80% (close enough to Office's synthesized small caps).
                if s.cap == "small" { drawn.size = (s.size ?? 18) * 0.8 }
                text.append(NSAttributedString(string: t, attributes: attributes(drawn, scale: scale, text: t)))
            }
            let endRun = runStyle(p.child("a:endParaRPr"), level: lvl)
            paras.append(Para(text: text, style: style, firstRun: first ?? endRun, endRun: endRun, level: lvl))
        }
    }

    private static func romanNumeral(_ n: Int) -> String {
        let table: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
                                      (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var v = max(1, min(n, 3999)), out = ""
        for (value, s) in table { while v >= value { out += s; v -= value } }
        return out
    }

    private static func alpha(_ n: Int) -> String {
        // a…z, then aa…zz, bbb… like Office.
        let v = max(1, n) - 1
        let letter = Character(UnicodeScalar(UInt8(97 + v % 26)))
        return String(repeating: letter, count: v / 26 + 1)
    }

    /// The label of an automatic number ("3.", "(c)", "IV)").
    static func autoNumberLabel(_ type: String, _ n: Int) -> String {
        var body: String
        if type.hasPrefix("roman") { body = romanNumeral(n) }
        else if type.hasPrefix("alpha") { body = alpha(n) }
        else if type.hasPrefix("circleNumDb") || type.hasPrefix("circleNumWd") {
            return n >= 1 && n <= 20 ? String(UnicodeScalar(0x2460 + UInt32(n - 1))!) : "\(n)"
        } else { body = String(n) }
        if type.contains("Uc") { body = body.uppercased() }
        if type.hasSuffix("ParenBoth") { return "(\(body))" }
        if type.hasSuffix("ParenR") { return "\(body))" }
        if type.hasSuffix("Period") { return "\(body)." }
        if type.hasSuffix("Minus") { return "- \(body) -" }
        return body
    }

    private func lineMetrics(_ line: CTLine, fallback: PPTXRunStyle, scale: Double) -> (CGFloat, CGFloat) {
        var asc: CGFloat = 0, desc: CGFloat = 0
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            if let e = attrs[extrasKey] as? PPTXRunExtras {
                asc = max(asc, e.ascent + max(0, e.shift))
                desc = max(desc, e.descent - min(0, e.shift))
            }
        }
        if asc == 0 && desc == 0 {
            let s = fallback
            let face = source.theme.font(s.latin ?? "+mn-lt")
            let p = fonts.pick(face: face, size: max(1, (s.size ?? 18) * CGFloat(scale)), bold: s.bold ?? false,
                               italic: false, pitch: s.latinPitch)
            asc = p.ascent; desc = p.descent
        }
        return (asc, desc)
    }

    /// Lays out the paragraphs inside `width` (the text area, insets already removed). Returns the height.
    @discardableResult
    func layout(width: CGFloat, scale: Double = 1, lineReduction: Double = 0) -> CGFloat {
        buildParagraphs(scale: scale)
        lines = []
        var y: CGFloat = 0
        var counters = [Int](repeating: 0, count: 9)
        let wrapWidth = source.props.wrap ? max(1, width) : 1_000_000
        for (pi, para) in paras.enumerated() {
            let st = para.style
            let marL = st.marL ?? 0
            let indent = st.indent ?? 0
            let hasText = para.text.length > 0 && !para.text.string.allSatisfy { $0 == "\u{2028}" }

            // Bullet. Numbering continues at a level until an unnumbered paragraph at that level, or any
            // paragraph at a shallower level, interrupts it.
            var bulletLine: CTLine?
            if hasText {
                for deeper in (para.level + 1)..<9 { counters[deeper] = 0 }
                var label: String?
                switch st.bullet {
                case .char(let c)?:
                    label = c
                    counters[para.level] = 0
                case .autoNumber(let type, let start)?:
                    if counters[para.level] == 0 { counters[para.level] = start - 1 }
                    counters[para.level] += 1
                    label = Self.autoNumberLabel(type, counters[para.level])
                default:
                    counters[para.level] = 0
                }
                if let label { bulletLine = makeBullet(label, para: para, scale: scale) }
            }

            // Space before.
            let (fa, fd) = metricsFor(para.firstRun, scale: scale)
            // PowerPoint ignores space before the first paragraph of a text box.
            if let sb = st.spaceBefore, pi > 0 {
                y += sb.pts.map { $0 * CGFloat(scale) } ?? CGFloat(sb.pct ?? 0) * (fa + fd)
            }

            let attr = NSMutableAttributedString(attributedString: para.text)
            if attr.length == 0 {
                // An empty paragraph still takes a line, sized by its end-of-paragraph run.
                let h = lineHeight(asc: fa, desc: fd, spacing: st.lineSpacing, reduction: lineReduction, scale: scale)
                y += h
            } else {
                applyTabs(attr, style: st, scale: scale)
                let ts = CTTypesetterCreateWithAttributedString(attr)
                var start = 0
                var firstLine = true
                let length = attr.length
                while start < length {
                    var x = firstLine ? marL + indent : marL
                    var bulletX: CGFloat = 0
                    if firstLine, let bl = bulletLine {
                        // Hanging indent: the bullet sits at marL + indent and the text at marL, unless the
                        // bullet is wider than the gap.
                        bulletX = marL + indent
                        let bw = CGFloat(CTLineGetTypographicBounds(bl, nil, nil, nil))
                        x = indent < 0 ? max(marL, bulletX + bw) : bulletX + bw
                    }
                    let avail = max(1, wrapWidth - x)
                    var count = CTTypesetterSuggestLineBreak(ts, start, Double(avail))
                    if count <= 0 { count = 1 }
                    var line = CTTypesetterCreateLine(ts, CFRange(location: start, length: count))
                    let end = start + count
                    let isLast = end >= length || attr.attributedSubstring(from: NSRange(location: end - 1, length: 1)).string == "\u{2028}"
                    let align = st.align ?? "l"
                    if (align == "just" && !isLast) || align == "dist" || align == "thaiDist" {
                        if let j = CTLineCreateJustifiedLine(line, 1.0, Double(avail)) { line = j }
                    }
                    let (asc, desc) = lineMetrics(line, fallback: para.endRun, scale: scale)
                    let h = lineHeight(asc: asc, desc: desc, spacing: st.lineSpacing, reduction: lineReduction, scale: scale)
                    let lw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
                    var lx = x
                    switch align {
                    case "ctr": lx = x + (avail - lw) / 2
                    case "r": lx = x + avail - lw
                    default: break
                    }
                    if !source.props.wrap {
                        // Unwrapped text is aligned within the box itself.
                        let box = width - x
                        switch align {
                        case "ctr": lx = x + (box - lw) / 2
                        case "r": lx = x + box - lw
                        default: lx = x
                        }
                    }
                    let baseline = y + h - desc
                    lines.append(Line(line: line, x: lx, baseline: baseline,
                                      bullet: firstLine ? bulletLine.map { ($0, bulletX) } : nil))
                    y += h
                    start = end
                    firstLine = false
                }
            }
            if let sa = st.spaceAfter, pi < paras.count - 1 {
                y += sa.pts.map { $0 * CGFloat(scale) } ?? CGFloat(sa.pct ?? 0) * (fa + fd)
            }
        }
        height = y
        return y
    }

    private func metricsFor(_ s: PPTXRunStyle, scale: Double) -> (CGFloat, CGFloat) {
        let face = source.theme.font(s.latin ?? "+mn-lt")
        let p = fonts.pick(face: face, size: max(1, (s.size ?? 18) * CGFloat(scale)), bold: s.bold ?? false,
                           italic: s.italic ?? false, pitch: s.latinPitch)
        return (p.ascent, p.descent)
    }

    private func lineHeight(asc: CGFloat, desc: CGFloat, spacing: (pct: Double?, pts: CGFloat?)?, reduction: Double,
                            scale: Double) -> CGFloat {
        if let pts = spacing?.pts { return pts * CGFloat(scale) }
        let pct = max(0.1, (spacing?.pct ?? 1) - reduction)
        return (asc + desc) * CGFloat(pct)
    }

    private func applyTabs(_ attr: NSMutableAttributedString, style: PPTXParaStyle, scale: Double) {
        guard attr.string.contains("\t") else { return }
        var interval = style.defaultTab ?? 72
        if interval <= 0 { interval = 72 }
        var stops: [CTTextTab] = []
        for (pos, algn) in style.tabs ?? [] {
            let a: CTTextAlignment = algn == "r" ? .right : algn == "ctr" ? .center : .left
            // Tab positions count from the text box's edge; Core Text counts from the line start.
            let p = pos - (style.marL ?? 0)
            if p > 0 { stops.append(CTTextTabCreate(a, Double(p), nil)) }
        }
        var stopsRef = stops as CFArray
        let paragraph: CTParagraphStyle = withUnsafePointer(to: &interval) { ip in
            withUnsafePointer(to: &stopsRef) { sp in
                let settings = [
                    CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: ip),
                    CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: sp),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        attr.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: paragraph,
                          range: NSRange(location: 0, length: attr.length))
    }

    private func makeBullet(_ label: String, para: Para, scale: Double) -> CTLine? {
        let st = para.style
        var run = para.firstRun
        run.underline = "none"; run.strike = "noStrike"; run.baseline = 0; run.hyperlink = false; run.highlight = nil
        var text = label
        if case .some(.some(let (face, pitch))) = st.bulletFont {
            run.latin = face; run.latinPitch = pitch; run.sym = nil; run.ea = nil; run.bold = false; run.italic = false
            if source.theme.font(face).lowercased() == "symbol" { text = PPTXFontBook.symbolChar(text) }
        }
        if let c = st.bulletColor, let color = c { run.color = color; run.noFill = nil }
        let base = run.size ?? 18
        if let sz = st.bulletSize, let s = sz {
            if let pct = s.pct { run.size = base * CGFloat(pct) }
            if let pts = s.pts { run.size = pts }
        }
        var attrs = attributes(run, scale: scale, text: text)
        attrs.removeValue(forKey: NSAttributedString.Key(kCTKernAttributeName as String))
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    // MARK: Drawing

    /// Draws the laid-out lines with their top-left at `origin` in a y-down context.
    func draw(in ctx: CGContext, origin: CGPoint, pixelScale: CGFloat) {
        for l in lines {
            if let (bl, bx) = l.bullet { drawLine(bl, at: CGPoint(x: origin.x + bx, y: origin.y + l.baseline), ctx: ctx, pixelScale: pixelScale) }
            drawLine(l.line, at: CGPoint(x: origin.x + l.x, y: origin.y + l.baseline), ctx: ctx, pixelScale: pixelScale)
        }
    }

    private func drawLine(_ line: CTLine, at p: CGPoint, ctx: CGContext, pixelScale: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let e = attrs[extrasKey] as? PPTXRunExtras ?? PPTXRunExtras()
            let font = attrs[kCTFontAttributeName] as! CTFont
            var origin = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &origin)
            var a: CGFloat = 0, d: CGFloat = 0
            let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(), &a, &d, nil))
            let glyphCount = CTRunGetGlyphCount(run)
            if glyphCount == 0 { continue }
            if let hl = e.highlight {
                ctx.setFillColor(hl)
                ctx.fill(CGRect(x: origin.x, y: -e.descent + e.shift, width: width, height: e.ascent + e.descent))
            }
            guard e.visible else { continue }
            ctx.saveGState()
            if let s = e.shadow {
                let rad = s.direction * .pi / 180
                ctx.setShadow(offset: CGSize(width: CGFloat(cos(rad)) * s.distance * pixelScale,
                                             height: -CGFloat(sin(rad)) * s.distance * pixelScale),
                              blur: s.blur * pixelScale, color: s.color.cgColor)
            }
            ctx.textPosition = CGPoint(x: 0, y: e.shift)
            CTRunDraw(run, ctx, CFRange())
            ctx.restoreGState()
            if e.underline != "none" || e.strike != "noStrike" {
                let thick = max(0.5, CTFontGetUnderlineThickness(font))
                ctx.setFillColor(e.color)
                if e.underline != "none" {
                    let uy = CTFontGetUnderlinePosition(font) + e.shift
                    ctx.fill(CGRect(x: origin.x, y: uy - thick / 2, width: width, height: thick))
                    if e.underline.hasPrefix("dbl") {
                        ctx.fill(CGRect(x: origin.x, y: uy - thick * 2.5, width: width, height: thick))
                    }
                }
                if e.strike != "noStrike" {
                    let sy = CTFontGetXHeight(font) * 0.5 + e.shift
                    ctx.fill(CGRect(x: origin.x, y: sy - thick / 2, width: width, height: thick))
                    if e.strike == "dblStrike" { ctx.fill(CGRect(x: origin.x, y: sy + thick, width: width, height: thick)) }
                }
            }
        }
        ctx.restoreGState()
    }
}
