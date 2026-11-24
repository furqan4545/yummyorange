import AppKit
import CoreText

/// A PDF font as far as SVG output needs it: how a string splits into character codes, each code's
/// advance and Unicode text, and a CSS font guessed from the font's name and descriptor. The glyph
/// outlines themselves aren't embedded; the text is set in a matching system font at the exact positions.
final class PDFSVGFont {
    struct Glyph {
        let code: UInt32
        let text: String
        /// Horizontal advance in text space for a 1-unit font size (vertical advance for vertical fonts).
        let width: CGFloat
        /// A single-byte code 32, which word spacing applies to.
        let isSpace: Bool
    }

    let css: String
    let isType3: Bool
    private(set) var vertical = false
    /// Type 3 only: glyph space → text space, the glyph programs and their resources.
    private(set) var fontMatrix = CGAffineTransform(scaleX: 0.001, y: 0.001)
    private(set) var charProcs: CGPDFDictionaryRef?
    private(set) var resources: CGPDFDictionaryRef?

    private let composite: Bool
    private var codespace: [(length: Int, low: [UInt8], high: [UInt8])] = []
    private var toUnicode: [UInt32: String] = [:]
    private var simpleText: [String] = Array(repeating: "", count: 256)
    private var glyphNames: [String?] = Array(repeating: nil, count: 256)
    private var widths: [UInt32: CGFloat] = [:]
    private var defaultWidth: CGFloat = 0
    private var codeToCID: [UInt32: UInt32] = [:]
    private var cidUnicode: [UInt32: String] = [:]
    private var codeIsUnicode = false
    private var legacyEncoding: String.Encoding?
    private var measure: CTFont?
    private var measured: [UInt32: CGFloat] = [:]

    /// A stand-in for text drawn before any Tf (or with a font that can't be read).
    static func makeFallback() -> PDFSVGFont { PDFSVGFont() }

    private init() {
        css = "font-family:Helvetica,Arial,sans-serif"
        isType3 = false

        composite = false
        for i in 0..<256 { simpleText[i] = PDFSVGEncoding.winAnsi[i] }
        measure = CTFontCreateWithName("Helvetica" as CFString, 1000, nil)
    }

    init(_ dict: CGPDFDictionaryRef) {
        let subtype = PDFSVGObj.name(dict, "Subtype") ?? "Type1"
        var baseFont = PDFSVGObj.name(dict, "BaseFont") ?? PDFSVGObj.name(dict, "Name") ?? ""
        isType3 = subtype == "Type3"
        composite = subtype == "Type0"

        var descendant: CGPDFDictionaryRef?
        if composite, let list = PDFSVGObj.array(dict, "DescendantFonts") {
            var d: CGPDFDictionaryRef?
            if CGPDFArrayGetDictionary(list, 0, &d) { descendant = d }
        }
        let descriptor = PDFSVGObj.dict(descendant ?? dict, "FontDescriptor")
        if baseFont.isEmpty { baseFont = PDFSVGObj.name(descriptor, "FontName") ?? "" }

        // CSS font from the name and descriptor.
        let style = PDFSVGFont.cssStyle(baseFont: baseFont, descriptor: descriptor,
                                        family: PDFSVGObj.text(descriptor, "FontFamily"))
        css = style.css

        var isVertical = false
        if composite {
            // Encoding: a predefined CMap name or an embedded CMap stream.
            if let name = PDFSVGObj.name(dict, "Encoding") {
                isVertical = name.hasSuffix("-V")
                if name.hasPrefix("Identity") {
                    codespace = [(2, [0, 0], [0xFF, 0xFF])]
                } else if name.contains("UCS2") || name.contains("UTF16") {
                    codespace = [(2, [0, 0], [0xFF, 0xFF])]
                    codeIsUnicode = true
                } else {
                    codespace = [(1, [0x00], [0x80]), (2, [0x81, 0x40], [0xFE, 0xFE])]
                    legacyEncoding = PDFSVGFont.legacyEncoding(forCMap: name)
                }
            } else if let stream = PDFSVGObj.stream(dict, "Encoding"), let data = PDFSVGObj.data(stream) {
                let cmap = PDFSVGCMap(data)
                codespace = cmap.codespace
                codeToCID = cmap.cids
                isVertical = PDFSVGObj.int(CGPDFStreamGetDictionary(stream), "WMode") == 1 || cmap.vertical
            } else {
                codespace = [(2, [0, 0], [0xFF, 0xFF])]
            }
            defaultWidth = (PDFSVGObj.number(descendant, "DW") ?? 1000) / 1000
            if let w = PDFSVGObj.array(descendant, "W") { widths = PDFSVGFont.cidWidths(w) }
            if isVertical {
                let dw2 = PDFSVGObj.numbers(PDFSVGObj.array(descendant, "DW2"))
                defaultWidth = (dw2.count == 2 ? dw2[1] : -1000) / 1000
                widths = [:]
            }
        } else {
            let first = PDFSVGObj.int(dict, "FirstChar") ?? 0
            let scale: CGFloat
            if isType3 {
                if let m = PDFSVGObj.matrix(PDFSVGObj.array(dict, "FontMatrix")) { fontMatrix = m }
                scale = fontMatrix.a
                charProcs = PDFSVGObj.dict(dict, "CharProcs")
                resources = PDFSVGObj.dict(dict, "Resources")
            } else {
                scale = 0.001
            }
            for (i, w) in PDFSVGObj.numbers(PDFSVGObj.array(dict, "Widths")).enumerated() {
                widths[UInt32(first + i)] = w * scale
            }
            defaultWidth = (PDFSVGObj.number(descriptor, "MissingWidth") ?? 0) * scale
            setUpSimpleEncoding(dict, baseFont: baseFont, descriptor: descriptor)
            if widths.isEmpty && !isType3 {
                measure = CTFontCreateWithName(PDFSVGFont.standardPostScriptName(baseFont) as CFString, 1000, nil)
            }
        }
        vertical = isVertical

        if let stream = PDFSVGObj.stream(dict, "ToUnicode"), let data = PDFSVGObj.data(stream) {
            let cmap = PDFSVGCMap(data)
            toUnicode = cmap.unicode
            if composite && codespace.isEmpty { codespace = cmap.codespace }
        }
        if composite && toUnicode.isEmpty && !codeIsUnicode && legacyEncoding == nil {
            cidUnicode = PDFSVGFont.reverseCMap(descriptor: descriptor, descendant: descendant)
        }
    }

    /// Splits a string into glyphs.
    func glyphs(_ bytes: [UInt8]) -> [Glyph] {
        var out: [Glyph] = []
        out.reserveCapacity(bytes.count)
        if !composite {
            for b in bytes {
                let code = UInt32(b)
                let text = toUnicode[code] ?? simpleText[Int(b)]
                out.append(Glyph(code: code, text: text, width: width(code: code, text: text), isSpace: b == 32))
            }
            return out
        }
        var i = 0
        while i < bytes.count {
            let length = codeLength(bytes, at: i)
            var code: UInt32 = 0
            for k in 0..<length { code = (code << 8) | UInt32(i + k < bytes.count ? bytes[i + k] : 0) }
            let cid = codeToCID[code] ?? code
            var text = toUnicode[code] ?? cidUnicode[cid] ?? ""
            if text.isEmpty {
                if codeIsUnicode, let scalar = Unicode.Scalar(code) { text = String(Character(scalar)) }
                else if let legacyEncoding, let s = String(bytes: bytes[i..<min(bytes.count, i + length)], encoding: legacyEncoding) { text = s }
            }
            let w = widths[cid] ?? defaultWidth
            out.append(Glyph(code: code, text: text, width: w, isSpace: length == 1 && code == 32))
            i += max(1, length)
        }
        return out
    }

    /// Type 3 glyph program for a code.
    func charProc(_ code: UInt32) -> CGPDFStreamRef? {
        guard let charProcs, code < 256, let name = glyphNames[Int(code)] else { return nil }
        return PDFSVGObj.stream(charProcs, name)
    }

    private func codeLength(_ bytes: [UInt8], at i: Int) -> Int {
        guard !codespace.isEmpty else { return 2 }
        for length in 1...4 {
            guard i + length <= bytes.count else { break }
            for range in codespace where range.length == length {
                var inside = true
                for k in 0..<length where bytes[i + k] < range.low[k] || bytes[i + k] > range.high[k] { inside = false; break }
                if inside { return length }
            }
        }
        return codespace.map(\.length).min() ?? 1
    }

    private func width(code: UInt32, text: String) -> CGFloat {
        if let w = widths[code] { return w }
        if let measure {
            if let w = measured[code] { return w }
            var w = defaultWidth
            let chars = Array(text.utf16)
            if !chars.isEmpty {
                var glyphs = [CGGlyph](repeating: 0, count: chars.count)
                if CTFontGetGlyphsForCharacters(measure, chars, &glyphs, chars.count) {
                    var advance = CGSize.zero
                    CTFontGetAdvancesForGlyphs(measure, .horizontal, [glyphs[0]], &advance, 1)
                    w = advance.width / 1000
                }
            }
            measured[code] = w
            return w
        }
        return defaultWidth
    }

    /// Simple fonts: base encoding plus /Differences, as Unicode text per code.
    private func setUpSimpleEncoding(_ dict: CGPDFDictionaryRef, baseFont: String, descriptor: CGPDFDictionaryRef?) {
        let flags = PDFSVGObj.int(descriptor, "Flags") ?? 0
        let symbolic = flags & 4 != 0 && flags & 32 == 0
        let plainName = PDFSVGFont.stripSubset(baseFont)
        var base: [String]
        let encodingName = PDFSVGObj.name(dict, "Encoding") ?? PDFSVGObj.name(PDFSVGObj.dict(dict, "Encoding"), "BaseEncoding")
        switch encodingName {
        case "WinAnsiEncoding": base = PDFSVGEncoding.winAnsi
        case "MacRomanEncoding": base = PDFSVGEncoding.macRoman
        case "StandardEncoding": base = PDFSVGEncoding.standard
        case "MacExpertEncoding": base = PDFSVGEncoding.winAnsi
        default:
            if plainName.hasPrefix("Symbol") { base = PDFSVGEncoding.symbol }
            else if plainName.hasPrefix("ZapfDingbats") { base = PDFSVGEncoding.winAnsi }
            else if symbolic || isType3 { base = PDFSVGEncoding.winAnsi }
            else { base = PDFSVGObj.name(dict, "Subtype") == "TrueType" ? PDFSVGEncoding.winAnsi : PDFSVGEncoding.standard }
        }
        simpleText = base
        if let differences = PDFSVGObj.array(PDFSVGObj.dict(dict, "Encoding"), "Differences") {
            var code = 0
            for i in 0..<CGPDFArrayGetCount(differences) {
                var n: CGPDFInteger = 0
                var name: UnsafePointer<Int8>?
                if CGPDFArrayGetInteger(differences, i, &n) {
                    code = Int(n)
                } else if CGPDFArrayGetName(differences, i, &name), let name {
                    if code >= 0 && code < 256 {
                        let glyph = String(cString: name)
                        glyphNames[code] = glyph
                        if let text = PDFSVGEncoding.unicode(forGlyph: glyph) { simpleText[code] = text }
                    }
                    code += 1
                }
            }
        }
        if isType3 {
            // Type 3 glyphs are found by name; fill in names for codes the Differences didn't cover.
            for code in 0..<256 where glyphNames[code] == nil {
                glyphNames[code] = PDFSVGEncoding.standardNames[code]
            }
        }
    }

    /// /W array: [c [w1 w2 …]] or [cFirst cLast w].
    private static func cidWidths(_ w: CGPDFArrayRef) -> [UInt32: CGFloat] {
        var out: [UInt32: CGFloat] = [:]
        var i = 0
        let n = CGPDFArrayGetCount(w)
        while i < n {
            var first: CGPDFReal = 0
            guard CGPDFArrayGetNumber(w, i, &first) else { i += 1; continue }
            var list: CGPDFArrayRef?
            if CGPDFArrayGetArray(w, i + 1, &list), let list {
                for (k, v) in PDFSVGObj.numbers(list).enumerated() { out[UInt32(Int(first) + k)] = v / 1000 }
                i += 2
            } else {
                var last: CGPDFReal = 0, width: CGPDFReal = 0
                guard CGPDFArrayGetNumber(w, i + 1, &last), CGPDFArrayGetNumber(w, i + 2, &width) else { break }
                if last >= first && last - first < 65536 {
                    for c in Int(first)...Int(last) { out[UInt32(c)] = width / 1000 }
                }
                i += 3
            }
        }
        return out
    }

    /// For composite TrueType fonts without a ToUnicode map: read the embedded font's own cmap backwards
    /// (glyph → character), which works when CIDs are glyph ids (CIDToGIDMap /Identity).
    private static func reverseCMap(descriptor: CGPDFDictionaryRef?, descendant: CGPDFDictionaryRef?) -> [UInt32: String] {
        guard let stream = PDFSVGObj.stream(descriptor, "FontFile2", "FontFile3"), let data = PDFSVGObj.data(stream),
              let provider = CGDataProvider(data: data as CFData), let cgFont = CGFont(provider) else { return [:] }
        if PDFSVGObj.stream(descendant, "CIDToGIDMap") != nil { return [:] }
        let ct = CTFontCreateWithGraphicsFont(cgFont, 12, nil, nil)
        var chars: [UniChar] = []
        for c in 0x20...0xFFFF where !(0xD800...0xDFFF).contains(c) { chars.append(UniChar(c)) }
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        _ = CTFontGetGlyphsForCharacters(ct, chars, &glyphs, chars.count)
        var map: [UInt32: String] = [:]
        for (i, g) in glyphs.enumerated() where g != 0 && map[UInt32(g)] == nil {
            map[UInt32(g)] = String(utf16CodeUnits: [chars[i]], count: 1)
        }
        return map
    }

    private static func legacyEncoding(forCMap name: String) -> String.Encoding? {
        func cf(_ e: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
        }
        if name.contains("RKSJ") { return .shiftJIS }
        if name.hasPrefix("EUC") || name.contains("-EUC") { return name.contains("KSC") || name.contains("KSCms") ? cf(.EUC_KR) : .japaneseEUC }
        if name.contains("GBK") || name.contains("GB-") || name.hasPrefix("GBpc") || name.hasPrefix("GBT") { return cf(.GB_18030_2000) }
        if name.contains("B5") || name.contains("ETen") || name.contains("HKscs") { return cf(.big5) }
        if name.contains("KSC") { return cf(.EUC_KR) }
        return nil
    }

    // MARK: Names → CSS

    static func stripSubset(_ name: String) -> String {
        let parts = name.split(separator: "+", maxSplits: 1)
        if parts.count == 2, parts[0].count == 6, parts[0].allSatisfy({ $0.isUppercase }) { return String(parts[1]) }
        return name
    }

    /// The macOS font used to measure standard-14 fonts that come without widths.
    static func standardPostScriptName(_ baseFont: String) -> String {
        let name = stripSubset(baseFont)
        switch name {
        case "Times-Roman", "TimesNewRoman", "TimesNewRomanPSMT": return "Times-Roman"
        case "Times-Bold", "TimesNewRoman,Bold": return "Times-Bold"
        case "Times-Italic", "TimesNewRoman,Italic": return "Times-Italic"
        case "Times-BoldItalic": return "Times-BoldItalic"
        case "Courier", "CourierNew": return "Courier"
        case "Courier-Bold": return "Courier-Bold"
        case "Courier-Oblique": return "Courier-Oblique"
        case "Courier-BoldOblique": return "Courier-BoldOblique"
        case "Symbol": return "Symbol"
        case "ZapfDingbats": return "ZapfDingbatsITC"
        default:
            if name.hasPrefix("Arial") || name.hasPrefix("Helvetica") {
                let bold = name.contains("Bold"), italic = name.contains("Italic") || name.contains("Oblique")
                return bold && italic ? "Helvetica-BoldOblique" : bold ? "Helvetica-Bold" : italic ? "Helvetica-Oblique" : "Helvetica"
            }
            return name.replacingOccurrences(of: ",", with: "-")
        }
    }

    /// A CSS declaration list (family with fallbacks, weight, style) from a PDF font name such as
    /// "ABCDEF+TimesNewRomanPS-BoldItalicMT" or "Arial,Bold".
    static func cssStyle(baseFont: String, descriptor: CGPDFDictionaryRef?, family declared: String?) -> (css: String, family: String) {
        var name = stripSubset(baseFont)
        var stylePart = ""
        if let cut = name.firstIndex(where: { $0 == "-" || $0 == "," }) {
            stylePart = String(name[name.index(after: cut)...])
            name = String(name[..<cut])
        }
        let lowerAll = (name + " " + stylePart).lowercased()
        // Style words can also be glued to the family ("ArialBold").
        for suffix in ["BoldItalic", "BoldOblique", "Bold", "Italic", "Oblique", "Black", "Light", "Medium", "Semibold"]
        where name.hasSuffix(suffix) && name.count > suffix.count + 2 {
            stylePart = suffix + stylePart
            name = String(name.dropLast(suffix.count))
            break
        }
        for suffix in ["PSMT", "MT", "PS", "Std", "LT"] where name.hasSuffix(suffix) && name.count > suffix.count + 2 {
            name = String(name.dropLast(suffix.count))
            break
        }
        if name.hasPrefix(".") { name.removeFirst() }
        let style = stylePart.lowercased()
        var weight = 400
        if style.contains("black") || style.contains("heavy") { weight = 900 }
        else if style.contains("extrabold") || style.contains("ultrabold") { weight = 800 }
        else if style.contains("semibold") || style.contains("demibold") || style.contains("demi") { weight = 600 }
        else if style.contains("bold") { weight = 700 }
        else if style.contains("medium") { weight = 500 }
        else if style.contains("extralight") || style.contains("ultralight") { weight = 200 }
        else if style.contains("light") { weight = 300 }
        else if style.contains("thin") || style.contains("hairline") { weight = 100 }
        let flags = PDFSVGObj.int(descriptor, "Flags") ?? 0
        if weight == 400, let declaredWeight = PDFSVGObj.number(descriptor, "FontWeight"), declaredWeight >= 100 {
            weight = Int(declaredWeight / 100) * 100
        }
        if weight == 400 && flags & (1 << 18) != 0 { weight = 700 }
        let italic = style.contains("italic") || style.contains("oblique") || stylePart.hasPrefix("It")
            || flags & 64 != 0 || abs(PDFSVGObj.number(descriptor, "ItalicAngle") ?? 0) > 0.5

        // Keep names CSS-safe: letters, digits, spaces and a little punctuation.
        name = String(name.filter { $0.isLetter || $0.isNumber || "-_ ".contains($0) })
        var family = String((declared ?? "").filter { $0.isLetter || $0.isNumber || "-_ ".contains($0) })
            .trimmingCharacters(in: .whitespaces)
        if family.isEmpty { family = spaced(name) }
        let lower = name.lowercased()
        var generic = "sans-serif"
        if flags & 1 != 0 || ["mono", "courier", "consol", "menlo", "monaco", "code"].contains(where: lowerAll.contains) {
            generic = "monospace"
        } else if flags & 2 != 0 || ["times", "serif", "roman", "georgia", "garamond", "minion", "palatino", "cambria",
                                     "baskerville", "caslon", "book", "charter", "century"].contains(where: lower.contains)
                    && !lower.contains("sans") {
            generic = "serif"
        }
        var families = [family]
        if name != family && !name.isEmpty { families.append(name) }
        switch lower {
        case let n where n.hasPrefix("arial") || n.hasPrefix("helvetica"): families += ["Helvetica", "Arial"]
        case let n where n.hasPrefix("times"): families += ["Times New Roman", "Times"]
        case let n where n.hasPrefix("courier"): families += ["Courier New", "Courier"]
        case let n where n.hasPrefix("sfns") || n.hasPrefix("sfpro") || n.hasPrefix("sfui") || n.hasPrefix("sfcompact"):
            families = ["-apple-system", "SF Pro Text", "Helvetica Neue", "Helvetica"]
        case let n where n.hasPrefix("calibri"): families += ["Carlito"]
        case let n where n.hasPrefix("cambria"): families += ["Caladea"]
        case let n where n.hasPrefix("zapfdingbats"): families = ["Zapf Dingbats", "ZapfDingbatsITC"]
        default: break
        }
        var seen = Set<String>()
        let list = (families.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.map { f in
            f == "-apple-system" || !f.contains(where: { !$0.isLetter && !$0.isNumber && $0 != "-" }) ? f : "'\(f.replacingOccurrences(of: "'", with: ""))'"
        } + [generic]).joined(separator: ",")
        var css = "font-family:\(list)"
        if weight != 400 { css += ";font-weight:\(weight)" }
        if italic { css += ";font-style:italic" }
        return (css, family)
    }

    /// "TimesNewRoman" → "Times New Roman", "SFProText" → "SF Pro Text".
    private static func spaced(_ s: String) -> String {
        var out = ""
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase {
                let prev = chars[i - 1]
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if prev.isLowercase || (prev.isUppercase && next.isLowercase) || prev.isNumber { out.append(" ") }
            } else if i > 0, c.isNumber, chars[i - 1].isLetter {
                out.append(" ")
            }
            out.append(c)
        }
        return out.replacingOccurrences(of: "_", with: " ")
    }
}

// MARK: - CMaps

/// The parts of a CMap that matter here: code space ranges, code → CID and code → Unicode.
struct PDFSVGCMap {
    var codespace: [(length: Int, low: [UInt8], high: [UInt8])] = []
    var cids: [UInt32: UInt32] = [:]
    var unicode: [UInt32: String] = [:]
    var vertical = false

    private enum Token { case hex([UInt8]), number(Int), name(String), word(String), open, close }

    init(_ data: Data) {
        let tokens = PDFSVGCMap.tokenize([UInt8](data))
        var i = 0
        func code(_ bytes: [UInt8]) -> UInt32 { bytes.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) } }
        func text(_ bytes: [UInt8]) -> String {
            var units: [UInt16] = []
            var k = 0
            while k + 1 < bytes.count { units.append(UInt16(bytes[k]) << 8 | UInt16(bytes[k + 1])); k += 2 }
            if bytes.count % 2 == 1 { units.append(UInt16(bytes.last!)) }
            return String(decoding: units, as: UTF16.self)
        }
        while i < tokens.count {
            guard case .word(let w) = tokens[i] else {
                if case .name("WMode") = tokens[i], i + 1 < tokens.count, case .number(1) = tokens[i + 1] { vertical = true }
                i += 1
                continue
            }
            i += 1
            switch w {
            case "begincodespacerange":
                while i + 1 < tokens.count, case .hex(let lo) = tokens[i], case .hex(let hi) = tokens[i + 1] {
                    if lo.count == hi.count && !lo.isEmpty && lo.count <= 4 { codespace.append((lo.count, lo, hi)) }
                    i += 2
                }
            case "beginbfchar":
                while i + 1 < tokens.count, case .hex(let src) = tokens[i] {
                    switch tokens[i + 1] {
                    case .hex(let dst): unicode[code(src)] = text(dst)
                    case .name(let glyph): if let t = PDFSVGEncoding.unicode(forGlyph: glyph) { unicode[code(src)] = t }
                    default: break
                    }
                    i += 2
                }
            case "beginbfrange":
                while i + 2 < tokens.count, case .hex(let lo) = tokens[i], case .hex(let hi) = tokens[i + 1] {
                    let a = code(lo), b = code(hi)
                    switch tokens[i + 2] {
                    case .hex(let dst) where b >= a && b - a < 65536:
                        var units: [UInt16] = []
                        var k = 0
                        while k + 1 < dst.count { units.append(UInt16(dst[k]) << 8 | UInt16(dst[k + 1])); k += 2 }
                        if units.isEmpty { units = [0] }
                        for c in a...b {
                            var u = units
                            u[u.count - 1] = u[u.count - 1] &+ UInt16(truncatingIfNeeded: c - a)
                            unicode[c] = String(decoding: u, as: UTF16.self)
                        }
                        i += 3
                    case .open:
                        var j = i + 3
                        // 64-bit counter: a range starting at <FFFFFFFF> would overflow UInt32 (a trap).
                        var c = UInt64(a)
                        while j < tokens.count, case .hex(let dst) = tokens[j] {
                            if c <= UInt64(b) { unicode[UInt32(c)] = text(dst) }
                            c += 1; j += 1
                        }
                        i = j + 1
                    default:
                        i += 3
                    }
                }
            case "begincidchar":
                while i + 1 < tokens.count, case .hex(let src) = tokens[i], case .number(let cid) = tokens[i + 1] {
                    // A CID past UInt32 (a crafted 99999999999) would trap in UInt32(_:); clamp it instead.
                    cids[code(src)] = UInt32(clamping: max(0, cid))
                    i += 2
                }
            case "begincidrange":
                while i + 2 < tokens.count, case .hex(let lo) = tokens[i], case .hex(let hi) = tokens[i + 1],
                      case .number(let cid) = tokens[i + 2] {
                    let a = code(lo), b = code(hi)
                    if b >= a && b - a < 65536 { for c in a...b { cids[c] = UInt32(clamping: min(max(0, cid), Int(UInt32.max)) + Int(c - a)) } }
                    i += 3
                }
            default:
                break
            }
        }
        if codespace.isEmpty, let any = unicode.keys.max() {
            // No code space given: guess the width from the largest code.
            let length = any > 0xFFFF ? 3 : any > 0xFF ? 2 : 1
            codespace = [(length, Array(repeating: 0, count: length), Array(repeating: 0xFF, count: length))]
        }
    }

    private static func tokenize(_ b: [UInt8]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        func isDelimiter(_ c: UInt8) -> Bool { "()<>[]{}/%".utf8.contains(c) || c <= 32 }
        while i < b.count {
            let c = b[i]
            if c <= 32 { i += 1; continue }
            if c == UInt8(ascii: "%") { while i < b.count && b[i] != 10 && b[i] != 13 { i += 1 }; continue }
            if c == UInt8(ascii: "<") {
                if i + 1 < b.count && b[i + 1] == UInt8(ascii: "<") { i += 2; continue }
                var hex: [UInt8] = []
                i += 1
                var half: UInt8? = nil
                while i < b.count && b[i] != UInt8(ascii: ">") {
                    let ch = b[i]
                    let v: UInt8? = ch >= 48 && ch <= 57 ? ch - 48 : ch >= 65 && ch <= 70 ? ch - 55 : ch >= 97 && ch <= 102 ? ch - 87 : nil
                    if let v { if let h = half { hex.append(h << 4 | v); half = nil } else { half = v } }
                    i += 1
                }
                if let h = half { hex.append(h << 4) }
                i += 1
                tokens.append(.hex(hex))
                continue
            }
            if c == UInt8(ascii: ">") { i += 1; continue }
            if c == UInt8(ascii: "[") { tokens.append(.open); i += 1; continue }
            if c == UInt8(ascii: "]") { tokens.append(.close); i += 1; continue }
            if c == UInt8(ascii: "(") {
                // Literal strings only appear in headers here; skip them.
                var depth = 1
                i += 1
                while i < b.count && depth > 0 {
                    if b[i] == UInt8(ascii: "\\") { i += 2; continue }
                    if b[i] == UInt8(ascii: "(") { depth += 1 } else if b[i] == UInt8(ascii: ")") { depth -= 1 }
                    i += 1
                }
                continue
            }
            var j = i + (c == UInt8(ascii: "/") ? 1 : 0)
            while j < b.count && !isDelimiter(b[j]) { j += 1 }
            let word = String(decoding: b[(c == UInt8(ascii: "/") ? i + 1 : i)..<j], as: UTF8.self)
            if c == UInt8(ascii: "/") { tokens.append(.name(word)) }
            else if let n = Int(word) { tokens.append(.number(n)) }
            else { tokens.append(.word(word)) }
            i = max(j, i + 1)
        }
        return tokens
    }
}

// MARK: - Encodings

/// Base encodings and glyph names, for simple fonts without a ToUnicode map.
enum PDFSVGEncoding {
    /// Glyph names in code order 32…255 for Windows-1252 positions (WinAnsiEncoding); "" where undefined.
    private static let winAnsiNames: [String] = """
    space exclam quotedbl numbersign dollar percent ampersand quotesingle parenleft parenright asterisk plus comma hyphen period slash \
    zero one two three four five six seven eight nine colon semicolon less equal greater question \
    at A B C D E F G H I J K L M N O P Q R S T U V W X Y Z bracketleft backslash bracketright asciicircum underscore \
    grave a b c d e f g h i j k l m n o p q r s t u v w x y z braceleft bar braceright asciitilde bullet \
    Euro bullet quotesinglbase florin quotedblbase ellipsis dagger daggerdbl circumflex perthousand Scaron guilsinglleft OE bullet Zcaron bullet \
    bullet quoteleft quoteright quotedblleft quotedblright bullet endash emdash tilde trademark scaron guilsinglright oe bullet zcaron Ydieresis \
    space exclamdown cent sterling currency yen brokenbar section dieresis copyright ordfeminine guillemotleft logicalnot hyphen registered macron \
    degree plusminus twosuperior threesuperior acute mu paragraph periodcentered cedilla onesuperior ordmasculine guillemotright onequarter onehalf threequarters questiondown \
    Agrave Aacute Acircumflex Atilde Adieresis Aring AE Ccedilla Egrave Eacute Ecircumflex Edieresis Igrave Iacute Icircumflex Idieresis \
    Eth Ntilde Ograve Oacute Ocircumflex Otilde Odieresis multiply Oslash Ugrave Uacute Ucircumflex Udieresis Yacute Thorn germandbls \
    agrave aacute acircumflex atilde adieresis aring ae ccedilla egrave eacute ecircumflex edieresis igrave iacute icircumflex idieresis \
    eth ntilde ograve oacute ocircumflex otilde odieresis divide oslash ugrave uacute ucircumflex udieresis yacute thorn ydieresis
    """.split(separator: " ").map(String.init)

    /// Glyph name → text, from the Windows-1252 table plus extra names seen in Differences arrays.
    private static let nameTable: [String: String] = {
        var t: [String: String] = [:]
        for (i, name) in winAnsiNames.enumerated() where t[name] == nil {
            let code = i + 32
            if let s = String(bytes: [UInt8(code)], encoding: .windowsCP1252), !(0x80...0x9F).contains(code) || name != "bullet" {
                t[name] = s
            }
        }
        t["bullet"] = "\u{2022}"; t["space"] = " "; t["nbspace"] = "\u{00A0}"; t["hyphen"] = "-"
        let extra: [String: String] = [
            "fi": "fi", "fl": "fl", "ff": "ff", "ffi": "ffi", "ffl": "ffl", "dotlessi": "ı", "dotlessj": "ȷ",
            "Lslash": "Ł", "lslash": "ł", "breve": "˘", "dotaccent": "˙", "ring": "˚", "ogonek": "˛", "caron": "ˇ",
            "hungarumlaut": "˝", "fraction": "⁄", "minus": "−", "quoteright": "’", "quoteleft": "‘", "endash": "–",
            "emdash": "—", "periodcentered": "·", "middot": "·", "Omega": "Ω", "Delta": "∆", "mu": "µ", "pi": "π",
            "lessequal": "≤", "greaterequal": "≥", "notequal": "≠", "infinity": "∞", "summation": "∑", "product": "∏",
            "radical": "√", "integral": "∫", "approxequal": "≈", "partialdiff": "∂", "lozenge": "◊", "apple": "\u{F8FF}",
            "dotlessi.sc": "ı", "Euro": "€", "uni00A0": "\u{00A0}", "arrowright": "→", "arrowleft": "←", "arrowup": "↑",
            "arrowdown": "↓", "checkmark": "✓", "Gcircumflex": "Ĝ", "gbreve": "ğ", "Gbreve": "Ğ", "scedilla": "ş",
            "Scedilla": "Ş", "Idotaccent": "İ", "Zdotaccent": "Ż", "zdotaccent": "ż", "Sacute": "Ś", "sacute": "ś",
            "Cacute": "Ć", "cacute": "ć", "Nacute": "Ń", "nacute": "ń", "Ccaron": "Č", "ccaron": "č", "Rcaron": "Ř",
            "rcaron": "ř", "Ecaron": "Ě", "ecaron": "ě", "Uring": "Ů", "uring": "ů", "Aogonek": "Ą", "aogonek": "ą",
            "Eogonek": "Ę", "eogonek": "ę", "Ohungarumlaut": "Ő", "ohungarumlaut": "ő", "Uhungarumlaut": "Ű", "uhungarumlaut": "ű",
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ",
            "iota": "ι", "kappa": "κ", "lambda": "λ", "nu": "ν", "xi": "ξ", "omicron": "ο", "rho": "ρ", "sigma": "σ",
            "tau": "τ", "upsilon": "υ", "phi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Theta": "Θ",
            "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "multiply": "×", "divide": "÷",
            "degree": "°", "plusminus": "±", "copyright": "©", "registered": "®", "trademark": "™", "ellipsis": "…",
        ]
        for (k, v) in extra { t[k] = v }
        return t
    }()

    /// Code → text for WinAnsiEncoding (Windows-1252), with codes below 32 kept as themselves.
    static let winAnsi: [String] = (0..<256).map { code in
        if code < 32 { return code == 9 || code == 10 || code == 13 ? " " : "" }
        if code == 127 { return "" }
        if let s = String(bytes: [UInt8(code)], encoding: .windowsCP1252) { return s }
        return code >= 0x80 && code <= 0x9F ? "\u{2022}" : String(UnicodeScalar(UInt8(code)))
    }

    static let macRoman: [String] = (0..<256).map { code in
        if code < 32 { return code == 9 || code == 10 || code == 13 ? " " : "" }
        return String(bytes: [UInt8(code)], encoding: .macOSRoman) ?? ""
    }

    /// Adobe StandardEncoding names in code order (nil where undefined).
    static let standardNames: [String?] = {
        var names = [String?](repeating: nil, count: 256)
        for (i, n) in winAnsiNames.prefix(95).enumerated() { names[i + 32] = n }
        names[0x27] = "quoteright"; names[0x60] = "quoteleft"
        let upper: [Int: String] = [
            0xA1: "exclamdown", 0xA2: "cent", 0xA3: "sterling", 0xA4: "fraction", 0xA5: "yen", 0xA6: "florin",
            0xA7: "section", 0xA8: "currency", 0xA9: "quotesingle", 0xAA: "quotedblleft", 0xAB: "guillemotleft",
            0xAC: "guilsinglleft", 0xAD: "guilsinglright", 0xAE: "fi", 0xAF: "fl", 0xB1: "endash", 0xB2: "dagger",
            0xB3: "daggerdbl", 0xB4: "periodcentered", 0xB6: "paragraph", 0xB7: "bullet", 0xB8: "quotesinglbase",
            0xB9: "quotedblbase", 0xBA: "quotedblright", 0xBB: "guillemotright", 0xBC: "ellipsis", 0xBD: "perthousand",
            0xBF: "questiondown", 0xC1: "grave", 0xC2: "acute", 0xC3: "circumflex", 0xC4: "tilde", 0xC5: "macron",
            0xC6: "breve", 0xC7: "dotaccent", 0xC8: "dieresis", 0xCA: "ring", 0xCB: "cedilla", 0xCD: "hungarumlaut",
            0xCE: "ogonek", 0xCF: "caron", 0xD0: "emdash", 0xE1: "AE", 0xE3: "ordfeminine", 0xE8: "Lslash",
            0xE9: "Oslash", 0xEA: "OE", 0xEB: "ordmasculine", 0xF1: "ae", 0xF5: "dotlessi", 0xF8: "lslash",
            0xF9: "oslash", 0xFA: "oe", 0xFB: "germandbls",
        ]
        for (k, v) in upper { names[k] = v }
        return names
    }()

    static let standard: [String] = (0..<256).map { code in
        guard let name = standardNames[code] else { return code < 32 ? "" : winAnsi[code] }
        return unicode(forGlyph: name) ?? ""
    }

    /// The Symbol font's Greek letters and maths signs at their ASCII positions.
    static let symbol: [String] = {
        var t = winAnsi
        let greek = "ΑΒΧΔΕΦΓΗΙϑΚΛΜΝΟΠΘΡΣΤΥςΩΞΨΖ"
        for (i, ch) in greek.enumerated() { t[0x41 + i] = String(ch) }
        let lower = "αβχδεφγηιϕκλμνοπθρστυϖωξψζ"
        for (i, ch) in lower.enumerated() { t[0x61 + i] = String(ch) }
        t[0x22] = "∀"; t[0x24] = "∃"; t[0x27] = "∋"; t[0x2A] = "∗"; t[0x2D] = "−"; t[0x40] = "≅"; t[0x5C] = "∴"
        t[0x5E] = "⊥"; t[0x60] = "‾"; t[0x7E] = "∼"; t[0xA3] = "≤"; t[0xA5] = "∞"; t[0xB1] = "±"; t[0xB3] = "≥"
        t[0xB4] = "×"; t[0xB6] = "∂"; t[0xB7] = "•"; t[0xB8] = "÷"; t[0xB9] = "≠"; t[0xBA] = "≡"; t[0xBB] = "≈"
        t[0xBC] = "…"; t[0xC5] = "⊕"; t[0xC6] = "∅"; t[0xC7] = "∩"; t[0xC8] = "∪"; t[0xCE] = "∈"; t[0xD1] = "∇"
        t[0xD6] = "√"; t[0xE5] = "∑"; t[0xF2] = "∫"; t[0xAE] = "→"; t[0xAC] = "←"; t[0xAD] = "↑"; t[0xAF] = "↓"
        return t
    }()

    /// Unicode text for an Adobe glyph name: known names, "uniXXXX", "uXXXX[XX]", ligatures with "_",
    /// and suffixed variants such as "a.sc".
    static func unicode(forGlyph name: String) -> String? {
        if let hit = nameTable[name] { return hit }
        var base = name
        if let dot = base.firstIndex(of: "."), dot != base.startIndex { base = String(base[..<dot]) }
        if base != name, let hit = nameTable[base] { return hit }
        if base.contains("_") {
            let parts = base.split(separator: "_").compactMap { unicode(forGlyph: String($0)) }
            return parts.isEmpty ? nil : parts.joined()
        }
        if base.hasPrefix("uni"), base.count >= 7 {
            var out = ""
            var hex = Substring(base.dropFirst(3))
            while hex.count >= 4, let v = UInt32(hex.prefix(4), radix: 16), let s = Unicode.Scalar(v) {
                out.unicodeScalars.append(s)
                hex = hex.dropFirst(4)
            }
            return out.isEmpty ? nil : out
        }
        if base.hasPrefix("u"), (5...7).contains(base.count), let v = UInt32(base.dropFirst(), radix: 16),
           let s = Unicode.Scalar(v) {
            return String(Character(s))
        }
        if base.count == 1 { return base }
        return nil
    }
}
