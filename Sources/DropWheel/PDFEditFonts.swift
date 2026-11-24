import AppKit
import CoreText

// Fonts for Edit PDF: how a string splits into codes and back (the run's own font first), which characters a
// font can really draw (evidence: the code is used elsewhere, or it has a width and an outline), and the
// transplant that brings in missing characters from a font on this Mac through a scratch Core Graphics PDF.

/// A font as the editor needs it, read from the file's own objects.
final class PDFEditFont {
    enum Kind { case simple, type0, type3 }

    struct Glyph {
        let code: UInt32
        let bytes: [UInt8]
        let text: String
        /// Horizontal advance in text space for a font size of 1.
        let width: Double
        /// A single-byte code 32 (word spacing applies).
        let isSpace: Bool
    }

    let key: String
    let objectNumber: Int?
    let dict: PDFDict
    let kind: Kind
    let subtype: String
    let baseFont: String
    /// The name without a subset tag ("AAAAAB+Monaco" → "Monaco").
    let plainName: String
    let isSubset: Bool
    private(set) var vertical = false
    let embedded: Bool
    /// One of the 14 standard fonts (or a common alias), not embedded: every PDF viewer has it.
    let isStandard14: Bool
    let flags: Int
    let fontWeight: Double
    let italicAngle: Double
    /// Ascent and descent in text space for a font size of 1.
    let ascent: Double
    let descent: Double
    let fontMatrix: CGAffineTransform
    let fontBBox: CGRect?
    let program: Data?
    let programKind: String?

    private var codespace: [(length: Int, low: [UInt8], high: [UInt8])] = []
    private var codeToCID: [UInt32: UInt32] = [:]
    private(set) var toUnicode: [UInt32: String] = [:]
    private var simpleText: [String] = Array(repeating: "", count: 256)
    private var glyphNames: [String?] = Array(repeating: nil, count: 256)
    private var widths: [UInt32: Double] = [:]
    private var defaultWidth: Double = 0
    private var cidUnicode: [UInt32: String] = [:]
    private var codeIsUnicode = false
    private var legacyEncoding: String.Encoding?
    private var measure: CTFont?
    private var measured: [UInt32: Double] = [:]
    private var charProcNames: Set<String> = []
    private var hasCIDToGIDMap = false

    /// Code → text learned from PDFKit for fonts without a Unicode mapping.
    private(set) var learned: [UInt32: String] = [:]
    /// Codes the document already shows in this font: proof they draw.
    private(set) var used: [UInt32: [UInt8]] = [:]
    private var availability: [UInt32: Bool] = [:]
    private var reverse: [String: [UInt32]]?

    var hasToUnicode: Bool { !toUnicode.isEmpty }
    var isComposite: Bool { kind == .type0 }

    init(dict: PDFDict, key: String, objectNumber: Int?, file: PDFObjectFile) {
        self.dict = dict
        self.key = key
        self.objectNumber = objectNumber
        subtype = dict["Subtype"]?.name ?? "Type1"
        kind = subtype == "Type0" ? .type0 : subtype == "Type3" ? .type3 : .simple
        var base = dict["BaseFont"]?.name ?? dict["Name"]?.name ?? ""

        var descendant: PDFDict?
        if kind == .type0, let list = file.resolve(dict["DescendantFonts"])?.array, let first = list.first {
            descendant = file.resolve(first).dict
        }
        let descriptor = file.resolve((descendant ?? dict)["FontDescriptor"])?.dict
        if base.isEmpty { base = descriptor?["FontName"]?.name ?? "" }
        baseFont = base
        plainName = PDFSVGFont.stripSubset(base)
        isSubset = plainName != base
        flags = file.resolve(descriptor?["Flags"])?.int ?? 0
        fontWeight = file.resolve(descriptor?["FontWeight"])?.double ?? 0
        italicAngle = file.resolve(descriptor?["ItalicAngle"])?.double ?? 0

        var prog: Data?, progKind: String?
        for k in ["FontFile2", "FontFile3", "FontFile"] {
            guard let ref = descriptor?[k], let n = ref.ref?.number, let o = file.object(n), let sd = o.value.dict, let raw = o.stream,
                  let decoded = try? file.decode(sd, raw) else { continue }
            prog = Data(decoded)
            progKind = k == "FontFile3" ? (sd["Subtype"]?.name ?? "FontFile3") : k
            break
        }
        program = prog
        programKind = progKind
        embedded = prog != nil

        if kind == .type3, let m = file.resolve(dict["FontMatrix"])?.array?.compactMap({ file.resolve($0).double }), m.count == 6 {
            fontMatrix = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
        } else {
            fontMatrix = CGAffineTransform(scaleX: 0.001, y: 0.001)
        }
        let bboxSource = kind == .type3 ? dict["FontBBox"] : descriptor?["FontBBox"]
        if let b = file.resolve(bboxSource)?.array?.compactMap({ file.resolve($0).double }), b.count == 4, b[2] > b[0] || b[3] > b[1] {
            fontBBox = CGRect(x: min(b[0], b[2]), y: min(b[1], b[3]), width: abs(b[2] - b[0]), height: abs(b[3] - b[1]))
        } else {
            fontBBox = nil
        }
        var asc = 0.0, desc = 0.0
        if kind == .type3, let bb = fontBBox {
            let r = bb.applying(fontMatrix)
            asc = r.maxY; desc = r.minY
        } else {
            asc = (file.resolve(descriptor?["Ascent"])?.double ?? 0) / 1000
            desc = (file.resolve(descriptor?["Descent"])?.double ?? 0) / 1000
            if asc <= 0, let bb = fontBBox { asc = bb.maxY / 1000 }
            if desc >= 0, let bb = fontBBox { desc = min(0, bb.minY / 1000) }
        }
        if asc <= 0.2 || asc > 2 { asc = 0.8 }
        if desc > 0 || desc < -1 { desc = -0.2 }
        if desc == 0 { desc = -0.2 }
        ascent = asc
        descent = desc

        let standard = ["Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic", "Helvetica", "Helvetica-Bold",
                        "Helvetica-Oblique", "Helvetica-BoldOblique", "Courier", "Courier-Bold", "Courier-Oblique",
                        "Courier-BoldOblique", "Symbol", "ZapfDingbats", "Arial", "Arial,Bold", "Arial,Italic", "Arial,BoldItalic",
                        "ArialMT", "Arial-BoldMT", "TimesNewRoman", "TimesNewRoman,Bold", "TimesNewRomanPSMT", "CourierNew",
                        "CourierNewPSMT"]
        isStandard14 = kind == .simple && prog == nil && standard.contains(plainName)

        var isVertical = false
        if kind == .type0 {
            if let name = dict["Encoding"]?.name {
                isVertical = name.hasSuffix("-V")
                if name.hasPrefix("Identity") {
                    codespace = [(2, [0, 0], [0xFF, 0xFF])]
                } else if name.contains("UCS2") || name.contains("UTF16") {
                    codespace = [(2, [0, 0], [0xFF, 0xFF])]
                    codeIsUnicode = true
                } else {
                    codespace = [(1, [0x00], [0x80]), (2, [0x81, 0x40], [0xFE, 0xFE])]
                    legacyEncoding = PDFEditFont.legacyEncoding(forCMap: name)
                }
            } else if let n = dict["Encoding"]?.ref?.number, let data = try? file.decodedStream(n) {
                let cmap = PDFSVGCMap(Data(data))
                codespace = cmap.codespace
                codeToCID = cmap.cids
                isVertical = cmap.vertical || file.resolve(file.object(n)?.value.dict?["WMode"])?.int == 1
            } else {
                codespace = [(2, [0, 0], [0xFF, 0xFF])]
            }
            defaultWidth = (file.resolve(descendant?["DW"])?.double ?? 1000) / 1000
            if let w = file.resolve(descendant?["W"])?.array { widths = PDFEditFont.cidWidths(w.map { file.resolve($0) }, file: file) }
            hasCIDToGIDMap = descendant?["CIDToGIDMap"]?.ref != nil
        } else {
            let first = file.resolve(dict["FirstChar"])?.int ?? 0
            let scale = kind == .type3 ? fontMatrix.a : 0.001
            if let w = file.resolve(dict["Widths"])?.array {
                // Simple fonts have one-byte codes: a /FirstChar outside 0…255 (a crafted 99999999999 would trap
                // in UInt32) only moves widths to codes no string can show.
                for (i, v) in w.prefix(256).enumerated() where (0...255).contains(first + i) {
                    widths[UInt32(first + i)] = (file.resolve(v).double ?? 0) * scale
                }
            }
            defaultWidth = (file.resolve(descriptor?["MissingWidth"])?.double ?? 0) * scale
            if kind == .type3, let procs = file.resolve(dict["CharProcs"])?.dict { charProcNames = Set(procs.keys) }
            setUpSimpleEncoding(file: file, descriptor: descriptor)
            if widths.isEmpty && kind == .simple {
                measure = CTFontCreateWithName(PDFSVGFont.standardPostScriptName(base) as CFString, 1000, nil)
            }
        }
        vertical = isVertical

        if let n = dict["ToUnicode"]?.ref?.number, let data = try? file.decodedStream(n) {
            let cmap = PDFSVGCMap(Data(data))
            toUnicode = cmap.unicode
            if kind == .type0 && codespace.isEmpty { codespace = cmap.codespace }
        }
        if kind == .type0 && toUnicode.isEmpty && !codeIsUnicode && legacyEncoding == nil && !hasCIDToGIDMap {
            cidUnicode = reverseEmbeddedCMap()
        }
    }

    // MARK: Decoding

    func glyphs(_ bytes: [UInt8]) -> [Glyph] {
        var out: [Glyph] = []
        out.reserveCapacity(bytes.count)
        if kind != .type0 {
            for b in bytes {
                let code = UInt32(b)
                let t = toUnicode[code] ?? learned[code] ?? simpleText[Int(b)]
                out.append(Glyph(code: code, bytes: [b], text: t, width: width(code: code, text: t), isSpace: b == 32))
            }
            return out
        }
        var i = 0
        while i < bytes.count {
            let length = codeLength(bytes, at: i)
            var code: UInt32 = 0
            for k in 0..<length { code = (code << 8) | UInt32(i + k < bytes.count ? bytes[i + k] : 0) }
            let cid = codeToCID[code] ?? code
            var t = toUnicode[code] ?? learned[code] ?? cidUnicode[cid] ?? ""
            if t.isEmpty {
                if codeIsUnicode, let s = Unicode.Scalar(code) { t = String(Character(s)) }
                else if let legacyEncoding, let s = String(bytes: bytes[i..<min(bytes.count, i + length)], encoding: legacyEncoding) { t = s }
            }
            out.append(Glyph(code: code, bytes: Array(bytes[i..<min(bytes.count, i + length)]), text: t,
                             width: widths[cid] ?? defaultWidth, isSpace: length == 1 && code == 32))
            i += max(1, length)
        }
        return out
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

    /// The bytes of a code, by the code space.
    private func bytes(of code: UInt32) -> [UInt8] {
        if let b = used[code] { return b }
        if kind != .type0 { return [UInt8(code & 0xFF)] }
        for range in codespace.sorted(by: { $0.length < $1.length }) {
            let b = (0..<range.length).map { UInt8((code >> (8 * UInt32(range.length - 1 - $0))) & 0xFF) }
            if code >> (8 * UInt32(range.length)) != 0 && range.length < 4 { continue }
            var inside = true
            for k in 0..<range.length where b[k] < range.low[k] || b[k] > range.high[k] { inside = false; break }
            if inside { return b }
        }
        return [UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]
    }

    private func width(code: UInt32, text: String) -> Double {
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
                    w = Double(advance.width) / 1000
                }
            }
            measured[code] = w
            return w
        }
        return defaultWidth
    }

    /// Advance of a code for a font size of 1.
    func advance(of code: UInt32) -> Double {
        if kind == .type0 { return widths[codeToCID[code] ?? code] ?? defaultWidth }
        return width(code: code, text: text(of: code))
    }

    func text(of code: UInt32) -> String {
        if kind == .type0 { return toUnicode[code] ?? learned[code] ?? cidUnicode[codeToCID[code] ?? code] ?? "" }
        return toUnicode[code] ?? learned[code] ?? simpleText[Int(code & 0xFF)]
    }

    // MARK: Evidence

    func noteUsed(_ g: Glyph) {
        if used[g.code] == nil { used[g.code] = g.bytes; availability[g.code] = nil }
    }

    func learn(_ code: UInt32, bytes: [UInt8], text: String) {
        guard !text.isEmpty else { return }
        learned[code] = text
        used[code] = bytes
        reverse = nil
        availability[code] = nil
    }

    private lazy var cgFont: CGFont? = {
        guard let program, let provider = CGDataProvider(data: program as CFData) else { return nil }
        return CGFont(provider)
    }()

    /// The embedded font program as a Core Text font, for outlines and for the editor's text view.
    lazy var embeddedCTFont: CTFont? = {
        guard let cgFont else { return nil }
        return CTFontCreateWithGraphicsFont(cgFont, 12, nil, nil)
    }()

    /// Whether `code` can be shown with this font: used elsewhere in the document, or a width above zero and an
    /// outline in the embedded program (subset fonts from Quartz, Word and Acrobat write width 0 for codes
    /// they left out). Standard-14 fonts that aren't embedded can show any code of their encoding.
    func isAvailable(_ code: UInt32) -> Bool {
        if let a = availability[code] { return a }
        let a = computeAvailable(code)
        availability[code] = a
        return a
    }

    private func computeAvailable(_ code: UInt32) -> Bool {
        if used[code] != nil { return true }
        if vertical { return false }
        let t = text(of: code)
        guard !t.isEmpty else { return false }
        let whitespace = t.allSatisfy { $0.isWhitespace }
        switch kind {
        case .type3:
            guard code < 256, let name = glyphNames[Int(code)] else { return false }
            return charProcNames.contains(name) && advance(of: code) > 0
        case .simple:
            if isStandard14 { return code >= 32 }
            if !embedded { return widths.isEmpty || advance(of: code) > 0 }
            if !widths.isEmpty, (widths[code] ?? 0) <= 0 { return false }
            if let ct = embeddedCTFont {
                let g = glyph(forCode: code, text: t, in: ct)
                guard g != 0 else { return false }
                return whitespace || hasOutline(g, in: ct)
            }
            return !isSubset && !widths.isEmpty
        case .type0:
            let cid = codeToCID[code] ?? code
            if isSubset, !widths.isEmpty, widths[cid] == nil { return false }
            if (widths[cid] ?? defaultWidth) <= 0 { return false }
            if !embedded { return true }
            if let ct = embeddedCTFont, !hasCIDToGIDMap, programKind == "FontFile2" {
                let count = CTFontGetGlyphCount(ct)
                guard cid < UInt32(count), cid > 0 else { return false }
                return whitespace || hasOutline(CGGlyph(cid), in: ct)
            }
            return toUnicode[code] != nil || learned[code] != nil
        }
    }

    private func glyph(forCode code: UInt32, text: String, in ct: CTFont) -> CGGlyph {
        let chars = Array(text.utf16)
        if !chars.isEmpty {
            var gs = [CGGlyph](repeating: 0, count: chars.count)
            if CTFontGetGlyphsForCharacters(ct, chars, &gs, chars.count), gs[0] != 0 { return gs[0] }
        }
        // Symbolic TrueType: the (3,0) cmap maps 0xF000 + code.
        var sym = [UniChar(0xF000 + (code & 0xFF))]
        var g: [CGGlyph] = [0]
        if CTFontGetGlyphsForCharacters(ct, &sym, &g, 1), g[0] != 0 { return g[0] }
        if code < 256, let cg = cgFont {
            let names = [glyphNames[Int(code)], PDFSVGEncoding.standardNames[Int(code)]].compactMap { $0 }
            for n in names {
                let gg = cg.getGlyphWithGlyphName(name: n as CFString)
                if gg != 0 { return gg }
            }
        }
        return 0
    }

    private func hasOutline(_ g: CGGlyph, in ct: CTFont) -> Bool {
        guard let path = CTFontCreatePathForGlyph(ct, g, nil) else { return false }
        return !path.isEmpty
    }

    // MARK: Encoding

    /// A piece of text and its codes in this font, or nil codes where the font can't show it.
    struct Piece {
        var text: String
        var bytes: [UInt8]?
        var codes: [UInt32]
    }

    /// Splits `text` into pieces this font can show (with their bytes) and pieces it can't.
    func encode(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        for ch in text.precomposedStringWithCanonicalMapping {
            let s = String(ch)
            if let code = code(for: s) {
                let b = bytes(of: code)
                if let last = pieces.last, last.bytes != nil {
                    pieces[pieces.count - 1].text += s
                    pieces[pieces.count - 1].bytes! += b
                    pieces[pieces.count - 1].codes.append(code)
                } else {
                    pieces.append(Piece(text: s, bytes: b, codes: [code]))
                }
            } else if let last = pieces.last, last.bytes == nil {
                pieces[pieces.count - 1].text += s
            } else {
                pieces.append(Piece(text: s, bytes: nil, codes: []))
            }
        }
        return pieces
    }

    func canEncode(_ text: String) -> Bool { encode(text).allSatisfy { $0.bytes != nil } }

    private func code(for s: String) -> UInt32? {
        if vertical { return nil }
        if kind == .type0 {
            if codeIsUnicode {
                let u = Array(s.utf16)
                guard u.count == 1 else { return nil }
                return UInt32(u[0])
            }
            if let legacyEncoding, toUnicode.isEmpty, learned.isEmpty, let d = s.data(using: legacyEncoding), d.count <= 2, !embedded {
                return d.reduce(0) { $0 << 8 | UInt32($1) }
            }
        }
        if reverse == nil { buildReverse() }
        guard let candidates = reverse?[s] else { return nil }
        return candidates.first { used[$0] != nil } ?? candidates.first { isAvailable($0) }
    }

    private func buildReverse() {
        var r: [String: [UInt32]] = [:]
        if kind == .type0 {
            for (c, t) in toUnicode where !t.isEmpty { r[t, default: []].append(c) }
            for (c, t) in learned where !t.isEmpty { r[t, default: []].append(c) }
            if toUnicode.isEmpty {
                for (cid, t) in cidUnicode where codeToCID.isEmpty { r[t, default: []].append(cid) }
            }
        } else {
            for c in 0..<256 {
                let t = text(of: UInt32(c))
                if !t.isEmpty { r[t.precomposedStringWithCanonicalMapping, default: []].append(UInt32(c)) }
            }
        }
        for k in r.keys { r[k]!.sort() }
        reverse = r
    }

    // MARK: Descriptions

    /// For the inspector: where the run's own glyphs come from.
    var sourceDescription: String {
        let family = PDFEditFont.displayName(plainName)
        switch kind {
        case .type3: return "Glyphs drawn by the PDF itself (\(family.isEmpty ? "custom font" : family))"
        case .type0, .simple:
            if embedded { return isSubset ? "Embedded subset of \(family)" : "Embedded \(family)" }
            if isStandard14 { return "\(family), a standard PDF font" }
            return "\(family), not embedded"
        }
    }

    static func displayName(_ name: String) -> String {
        var n = name.replacingOccurrences(of: ",", with: " ")
        for suffix in ["PSMT", "MT", "PS"] where n.hasSuffix(suffix) && n.count > suffix.count + 2 { n = String(n.dropLast(suffix.count)) }
        n = n.replacingOccurrences(of: "-", with: " ")
        return n
    }

    var looksBold: Bool {
        let n = plainName.lowercased()
        return n.contains("bold") || n.contains("black") || n.contains("heavy") || n.contains("semibold") || fontWeight >= 600 || flags & (1 << 18) != 0
    }
    var looksItalic: Bool {
        let n = plainName.lowercased()
        return n.contains("italic") || n.contains("oblique") || flags & 64 != 0 || abs(italicAngle) > 0.5
    }
    var isFixedPitch: Bool { flags & 1 != 0 || ["mono", "courier", "menlo", "monaco", "consol"].contains { plainName.lowercased().contains($0) } }
    var isSerif: Bool { flags & 2 != 0 || ["times", "georgia", "garamond", "palatino", "baskerville", "minion"].contains { plainName.lowercased().contains($0) } }

    // MARK: Setup helpers

    private func setUpSimpleEncoding(file: PDFObjectFile, descriptor: PDFDict?) {
        let symbolic = flags & 4 != 0 && flags & 32 == 0
        var base: [String]
        let encValue = file.resolve(dict["Encoding"])
        let encodingName = encValue?.name ?? encValue?.dict?["BaseEncoding"]?.name
        switch encodingName {
        case "WinAnsiEncoding": base = PDFSVGEncoding.winAnsi
        case "MacRomanEncoding": base = PDFSVGEncoding.macRoman
        case "StandardEncoding": base = PDFSVGEncoding.standard
        default:
            if plainName.hasPrefix("Symbol") { base = PDFSVGEncoding.symbol }
            else if symbolic || kind == .type3 { base = PDFSVGEncoding.winAnsi }
            else { base = subtype == "TrueType" ? PDFSVGEncoding.winAnsi : PDFSVGEncoding.standard }
        }
        simpleText = base
        if let differences = encValue?.dict?["Differences"].flatMap({ file.resolve($0).array }) {
            var code = 0
            for v in differences {
                let x = file.resolve(v)
                if let n = x.int { code = n }
                else if let name = x.name {
                    if code >= 0 && code < 256 {
                        glyphNames[code] = name
                        if let t = PDFSVGEncoding.unicode(forGlyph: name) { simpleText[code] = t }
                        else if name.count == 1 { simpleText[code] = name }
                    }
                    code += 1
                }
            }
        }
        if kind == .type3 {
            for code in 0..<256 where glyphNames[code] == nil { glyphNames[code] = PDFSVGEncoding.standardNames[code] }
        }
    }

    private static func cidWidths(_ w: [PDFValue], file: PDFObjectFile) -> [UInt32: Double] {
        var out: [UInt32: Double] = [:]
        var i = 0
        // CIDs are 0…65535; values outside (1e300 in a crafted /W) are skipped instead of trapping in Int/UInt32.
        let cids = 0...0xFFFF
        while i < w.count {
            guard let fd = w[i].double else { i += 1; continue }
            let first = PDFNumber.int(fd)
            if i + 1 < w.count, let list = w[i + 1].array {
                if let first { for (k, v) in list.enumerated() where cids.contains(first + k) { out[UInt32(first + k)] = (file.resolve(v).double ?? 0) / 1000 } }
                i += 2
            } else if i + 2 < w.count, let ld = w[i + 1].double, let width = w[i + 2].double {
                if let first, let last = PDFNumber.int(ld), last >= first, last - first < 65536 {
                    let lo = max(first, 0), hi = min(last, 0xFFFF)
                    if lo <= hi { for c in lo...hi { out[UInt32(c)] = width / 1000 } }
                }
                i += 3
            } else { break }
        }
        return out
    }

    /// Composite TrueType without ToUnicode: the embedded font's own cmap read backwards (CIDs are glyph ids).
    private func reverseEmbeddedCMap() -> [UInt32: String] {
        guard programKind == "FontFile2", let ct = embeddedCTFont else { return [:] }
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
        if name.hasPrefix("EUC") || name.contains("-EUC") { return name.contains("KSC") ? cf(.EUC_KR) : .japaneseEUC }
        if name.contains("GBK") || name.contains("GB-") || name.hasPrefix("GBpc") || name.hasPrefix("GBT") { return cf(.GB_18030_2000) }
        if name.contains("B5") || name.contains("ETen") || name.contains("HKscs") { return cf(.big5) }
        if name.contains("KSC") { return cf(.EUC_KR) }
        return nil
    }
}

/// The fonts of one document, shared by its pages so learned codes and usage carry across pages.
final class PDFEditFontCache {
    let file: PDFObjectFile
    private var fonts: [String: PDFEditFont] = [:]

    init(_ file: PDFObjectFile) { self.file = file }

    /// The font a resource value names: indirect fonts are keyed by object number, direct ones by their holder.
    func font(_ value: PDFValue, holder: String) -> PDFEditFont? {
        let key: String
        let number = value.ref?.number
        if let number { key = "#\(number)" } else { key = "\(holder)" }
        if let f = fonts[key] { return f }
        guard let d = file.resolve(value).dict else { return nil }
        let f = PDFEditFont(dict: d, key: key, objectNumber: number, file: file)
        fonts[key] = f
        return f
    }

    func font(key: String) -> PDFEditFont? { fonts[key] }
    var all: [PDFEditFont] { Array(fonts.values) }
}

// MARK: - Choosing a font on this Mac

enum PDFFontMatch {
    /// The installed font for a PDF font: the same family when it's installed (subset tag removed), else a
    /// close match by the descriptor's flags: fixed pitch → Menlo, serif → Times New Roman, else Helvetica.
    static func installedFont(for f: PDFEditFont, size: CGFloat = 100) -> (font: CTFont, exact: Bool) {
        let name = f.plainName
        let candidates = [name, name.replacingOccurrences(of: ",", with: "-"), PDFSVGFont.standardPostScriptName(name)]
        for c in candidates where !c.isEmpty {
            let ct = CTFontCreateWithName(c as CFString, size, nil)
            let ps = CTFontCopyPostScriptName(ct) as String
            let family = (CTFontCopyFamilyName(ct) as String).replacingOccurrences(of: " ", with: "")
            let wanted = c.lowercased()
            if ps.lowercased() == wanted || wanted.hasPrefix(family.lowercased()) && family.count >= 3 {
                return (ct, true)
            }
        }
        let bold = f.looksBold, italic = f.looksItalic
        let ps: String
        if f.isFixedPitch { ps = bold ? "Menlo-Bold" : italic ? "Menlo-Italic" : "Menlo-Regular" }
        else if f.isSerif { ps = bold ? (italic ? "TimesNewRomanPS-BoldItalicMT" : "TimesNewRomanPS-BoldMT") : italic ? "TimesNewRomanPS-ItalicMT" : "TimesNewRomanPSMT" }
        else { ps = bold ? (italic ? "Helvetica-BoldOblique" : "Helvetica-Bold") : italic ? "Helvetica-Oblique" : "Helvetica" }
        return (CTFontCreateWithName(ps as CFString, size, nil), false)
    }

    /// The font the inline editor should type in: the embedded program (but for a subset, the same family
    /// installed on this Mac, which has every glyph and is what new characters come from), else the installed
    /// font or its closest match, else the system font.
    static func editorFont(for f: PDFEditFont?, size: CGFloat) -> (font: NSFont, source: PDFEditorFontSource) {
        if let f, f.isSubset || f.embeddedCTFont == nil, f.kind != .type3 {
            let m = installedFont(for: f, size: size)
            if m.exact { return (m.font as NSFont, .installed) }
        }
        if let f, let ct = f.embeddedCTFont {
            let sized = CTFontCreateCopyWithAttributes(ct, size, nil, nil)
            return (sized as NSFont, .embedded)
        }
        if let f {
            let m = installedFont(for: f, size: size)
            return (m.font as NSFont, m.exact ? .installed : .similar)
        }
        return (NSFont.systemFont(ofSize: size), .system)
    }

    static func displayName(_ ct: CTFont) -> String { CTFontCopyFamilyName(ct) as String }
}

/// Where the inline editor's font came from.
enum PDFEditorFontSource { case embedded, installed, similar, system }

// MARK: - Transplant

/// Text the run's font can't show, drawn by Core Text into one scratch PDF per build; the fonts Quartz writes
/// there are copied into the update and shown inside the same BT, so position, colour, clip and reading order stay.
enum PDFTransplant {
    struct Request {
        var text: String
        var font: CTFont
    }

    struct Segment {
        /// Object number of the font in the scratch file.
        var scratchFont: Int
        var bytes: [UInt8]
        var text: String
        /// Sum of the glyph widths for a font size of 1.
        var width: Double
    }

    struct Result {
        let scratch: PDFObjectFile
        let fonts: PDFEditFontCache
        /// Per request, its segments in order.
        let segments: [[Segment]]
        /// Code bytes → text per scratch font, from Core Text's string indices.
        let pairs: [Int: [[UInt8]: String]]
    }

    static func isEmoji(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2FFF) }
    }

    static func draw(_ requests: [Request]) throws -> Result {
        let data = NSMutableData()
        let lineGap: CGFloat = 100
        var box = CGRect(x: 0, y: 0, width: 30000, height: lineGap * CGFloat(requests.count + 1))
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw ConversionError.toolFailed("Couldn’t prepare the replacement characters.")
        }
        ctx.beginPDFPage(nil)
        var ctGlyphTexts: [[(font: String, text: String)]] = []
        for (k, r) in requests.enumerated() {
            if isEmoji(r.text) { throw ConversionError.unsupported("Emoji can’t be added as PDF text.") }
            let attr = NSAttributedString(string: r.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): r.font,
                NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            var texts: [(String, String)] = []
            let ns = r.text as NSString
            for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let runFont = attrs[kCTFontAttributeName as String].map { $0 as! CTFont }
                let fontName = runFont.map { CTFontCopyPostScriptName($0) as String } ?? ""
                if fontName.contains("AppleColorEmoji") { throw ConversionError.unsupported("Emoji can’t be added as PDF text.") }
                let n = CTRunGetGlyphCount(run)
                var idx = [CFIndex](repeating: 0, count: n)
                CTRunGetStringIndices(run, CFRange(location: 0, length: n), &idx)
                let range = CTRunGetStringRange(run)
                for i in 0..<n {
                    let start = idx[i]
                    var end = range.location + range.length
                    for j in 0..<n where idx[j] > start && idx[j] < end { end = idx[j] }
                    let t = end > start ? ns.substring(with: NSRange(location: start, length: end - start)) : ""
                    texts.append((fontName, t))
                }
            }
            ctGlyphTexts.append(texts)
            ctx.textPosition = CGPoint(x: 10, y: lineGap * CGFloat(k + 1))
            CTLineDraw(line, ctx)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        let scratch = try PDFObjectFile(data as Data)
        guard let page = scratch.pages().first else { throw ConversionError.toolFailed("Couldn’t prepare the replacement characters.") }
        let fonts = PDFEditFontCache(scratch)
        let content = PDFPageContent(file: scratch, page: page, fonts: fonts)
        var segments = [[Segment]](repeating: [], count: requests.count)
        var codesPerLine = [[(font: Int, bytes: [UInt8])]](repeating: [], count: requests.count)
        let fontDict = scratch.resolve(page.resources["Font"])?.dict ?? PDFDict()
        for run in content.runs {
            let y = run.textMatrix.concatenating(run.ctm).ty
            let k = Int((y / lineGap).rounded()) - 1
            guard k >= 0, k < requests.count, let fref = fontDict[run.fontName]?.ref?.number,
                  let font = fonts.font(key: run.fontKey) else { continue }
            var bytes: [UInt8] = []
            var width = 0.0
            var text = ""
            for g in run.glyphs {
                bytes += g.bytes; width += font.advance(of: g.code); text += g.text
                codesPerLine[k].append((fref, g.bytes))
            }
            guard !bytes.isEmpty else { continue }
            if let last = segments[k].last, last.scratchFont == fref {
                segments[k][segments[k].count - 1].bytes += bytes
                segments[k][segments[k].count - 1].width += width
                segments[k][segments[k].count - 1].text += text
            } else {
                segments[k].append(Segment(scratchFont: fref, bytes: bytes, text: text, width: width))
            }
        }
        var pairs: [Int: [[UInt8]: String]] = [:]
        for (k, r) in requests.enumerated() {
            guard !segments[k].isEmpty else {
                throw ConversionError.unsupported("“\(r.text)” can’t be drawn with the fonts on this Mac.")
            }
            let codes = codesPerLine[k], texts = ctGlyphTexts[k]
            if codes.count == texts.count {
                for (c, t) in zip(codes, texts) where !t.text.isEmpty { pairs[c.font, default: [:]][c.bytes] = t.text }
            }
            // A glyph Core Text drew that never reached the PDF as text (an image, say) means the text is incomplete.
            let drawn = segments[k].reduce(0) { $0 + $1.bytes.count }
            if drawn == 0 || codes.count < texts.filter({ !$0.text.allSatisfy(\.isWhitespace) }).count {
                throw ConversionError.unsupported("Some of “\(r.text)” can’t be added as PDF text.")
            }
            // Segments whose scratch font has no Unicode mapping (Quartz's CID-keyed CFF): Core Text's text per code.
            for i in segments[k].indices where segments[k][i].text.isEmpty || segments[k][i].text.contains("\u{FFFD}") {
                let seg = segments[k][i]
                let length = fonts.font(key: "#\(seg.scratchFont)")?.isComposite == true ? 2 : 1
                var text = ""
                var p = 0
                while p + length <= seg.bytes.count {
                    text += pairs[seg.scratchFont]?[Array(seg.bytes[p..<(p + length)])] ?? ""
                    p += length
                }
                segments[k][i].text = text.isEmpty ? r.text : text
            }
        }
        return Result(scratch: scratch, fonts: fonts, segments: segments, pairs: pairs)
    }

    /// A ToUnicode CMap for codes of the given byte length.
    static func toUnicodeCMap(_ pairs: [[UInt8]: String], codeLength: Int) -> [UInt8] {
        func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }
        var s = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
        s += "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n"
        s += "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n1 begincodespacerange\n"
        s += codeLength == 1 ? "<00> <FF>\n" : "<0000> <FFFF>\n"
        s += "endcodespacerange\n"
        let sorted = pairs.sorted { $0.key.lexicographicallyPrecedes($1.key) }
        var i = 0
        while i < sorted.count {
            let chunk = sorted[i..<min(sorted.count, i + 100)]
            s += "\(chunk.count) beginbfchar\n"
            for (code, text) in chunk {
                let utf16 = Array(text.utf16)
                let dst = utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
                s += "<\(hex(code))> <\(hex(dst))>\n"
            }
            s += "endbfchar\n"
            i += 100
        }
        s += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
        return Array(s.utf8)
    }
}
