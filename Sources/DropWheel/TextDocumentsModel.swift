import AppKit
import ImageIO
import UniformTypeIdentifiers

// A document model the writers share. Rich text from any reader (Cocoa's importers, the Markdown
// reader, PDF reconstruction) is analysed once into blocks (headings, list items, tables, code,
// quotes, rules, pictures), and the DOCX, ODT, HTML, Markdown and plain-text writers each walk it.

extension NSAttributedString.Key {
    /// Int: block-quote nesting depth, set by YummyOrange's own readers.
    static let dwQuote = NSAttributedString.Key("DropWheel.quote")
    /// String: a fenced code block's language ("" when none).
    static let dwCodeBlock = NSAttributedString.Key("DropWheel.codeBlock")
    /// Bool: the paragraph is a horizontal rule.
    static let dwRule = NSAttributedString.Key("DropWheel.rule")
    /// String: a picture's alt text.
    static let dwImageAlt = NSAttributedString.Key("DropWheel.imageAlt")
    /// Int: a paragraph that continues a list item at this depth (it has no marker and no NSTextList,
    /// so Cocoa's writers don't number it).
    static let dwListContinuation = NSAttributedString.Key("DropWheel.listContinuation")
    /// Int: which code block a code paragraph belongs to, so two blocks in a row stay two blocks.
    static let dwCodeBlockID = NSAttributedString.Key("DropWheel.codeBlockID")
    /// Int: a list item's number, when the reader knows it (ODT start values Cocoa's importer drops).
    static let dwListNumber = NSAttributedString.Key("DropWheel.listNumber")
    /// String (RichListLevel.Style raw value): a list item's numbering style, when the reader knows it.
    static let dwListStyle = NSAttributedString.Key("DropWheel.listStyle")
}

/// Limits that keep hostile documents from overflowing the stack (conversions run on threads with 512 KB).
enum RichLimits {
    /// Block nesting (quotes, lists) YummyOrange keeps; deeper levels are flattened into their parent.
    static let blockDepth = 32
    /// Inline nesting (emphasis, links, pictures inside each other).
    static let inlineDepth = 24
    /// Tables inside tables, and other wrappers inside each other in Word documents.
    static let tableDepth = 12
    static let xmlDepth = 64
    /// Element nesting an XML part may have at all (libxml2's own default): deeper ones are refused before
    /// parsing, since building and freeing such a tree recurses once per level.
    static let xmlParseDepth = 256
}

/// XML parts YummyOrange reads itself (DOCX) or hands to Cocoa (ODT) must not carry a DTD: entity
/// declarations can pull in local files or expand into gigabytes. Office formats never declare entities;
/// a bare <!DOCTYPE> naming an outside DTD (old OpenOffice and Cocoa manifests have one) is taken out, so
/// no parser goes looking for that DTD.
enum RichXMLSafety {
    /// A part declared a DTD (or used an encoding the check can't see through), or nests absurdly deep.
    struct Refused: Error { var tooDeep = false }

    /// The part as bytes an ASCII-compatible parser reads the same way (UTF-16 becomes UTF-8), with any
    /// bare <!DOCTYPE> removed. Throws `Refused` for entity declarations or an internal DTD subset.
    static func checked(_ data: Data) throws -> Data {
        var bytes = data
        if data.count >= 2, data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) || data[0] == 0 || data[1] == 0 {
            // UTF-16 (or UTF-32, which then fails the '<' check below).
            let bigEndian = data.starts(with: [0xFE, 0xFF]) || (data[0] == 0 && !data.starts(with: [0xFF, 0xFE]))
            guard var s = String(data: data, encoding: bigEndian ? .utf16BigEndian : .utf16LittleEndian) else { throw Refused() }
            if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
            // The declaration names UTF-16, which the bytes no longer are.
            if s.hasPrefix("<?xml"), let end = s.range(of: "?>") { s = String(s[end.upperBound...]) }
            bytes = Data(s.utf8)
        }
        var i = bytes.startIndex
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i += 3 }
        while i < bytes.endIndex, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        // Every XML part starts with '<' in an ASCII-compatible encoding; anything else (EBCDIC, UCS-4) is refused.
        guard i < bytes.endIndex, bytes[i] == 0x3C else { throw Refused() }
        if hasDeclaration(bytes) { bytes = try withoutDoctype(bytes) }
        if nestsDeeper(bytes, than: RichLimits.xmlParseDepth) { throw Refused(tooDeep: true) }
        return bytes
    }

    /// The bytes without their <!DOCTYPE …> declarations, refused when one has an internal subset ("[ … ]",
    /// where entities live) or anything declares an entity.
    static func withoutDoctype(_ bytes: Data) throws -> Data {
        let b = [UInt8](bytes)
        let n = b.count
        func upper(_ u: UInt8) -> UInt8 { (0x61...0x7A).contains(u) ? u - 32 : u }
        func at(_ i: Int, _ word: String) -> Bool {
            let w = Array(word.utf8)
            guard i + w.count <= n else { return false }
            for k in 0..<w.count where upper(b[i + k]) != w[k] { return false }
            return true
        }
        var out: [UInt8] = []
        out.reserveCapacity(n)
        var i = 0
        while i < n {
            if b[i] == 0x3C, at(i, "<!ENTITY") { throw Refused() }
            if b[i] == 0x3C, at(i, "<!DOCTYPE") {
                var j = i + 9, quote: UInt8 = 0
                while j < n {
                    let c = b[j]
                    if quote != 0 { if c == quote { quote = 0 } }
                    else if c == 0x22 || c == 0x27 { quote = c }
                    else if c == 0x5B { throw Refused() }       // internal subset
                    else if c == 0x3E { break }
                    j += 1
                }
                guard j < n else { throw Refused() }
                i = j + 1
                continue
            }
            out.append(b[i]); i += 1
        }
        return Data(out)
    }

    /// Whether elements nest deeper than `limit` (one pass; quoted attribute values, comments and CDATA
    /// are skipped, so nothing inside them can hide a level).
    static func nestsDeeper(_ bytes: Data, than limit: Int) -> Bool {
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            func skip(to end: [UInt8], from start: Int) -> Int {
                var i = start
                while i + end.count <= n {
                    var same = true
                    for k in 0..<end.count where b[i + k] != end[k] { same = false; break }
                    if same { return i + end.count }
                    i += 1
                }
                return n
            }
            var i = 0, depth = 0
            while i < n {
                guard b[i] == 0x3C, i + 1 < n else { i += 1; continue }
                let next = b[i + 1]
                if next == 0x21 {   // <!-- … -->, <![CDATA[ … ]]>, other declarations
                    if i + 3 < n, b[i + 2] == 0x2D, b[i + 3] == 0x2D { i = skip(to: Array("-->".utf8), from: i + 4) }
                    else if i + 8 < n, b[i + 2] == 0x5B { i = skip(to: Array("]]>".utf8), from: i + 2) }
                    else { i = skip(to: [0x3E], from: i + 2) }
                    continue
                }
                if next == 0x3F { i = skip(to: Array("?>".utf8), from: i + 2); continue }
                var j = i + 1, quote: UInt8 = 0
                while j < n {
                    let c = b[j]
                    if quote != 0 { if c == quote { quote = 0 } }
                    else if c == 0x22 || c == 0x27 { quote = c }
                    else if c == 0x3E { break }
                    j += 1
                }
                if next == 0x2F { depth -= 1 }
                else if !(j < n && b[j - 1] == 0x2F) {
                    depth += 1
                    if depth > limit { return true }
                }
                i = j + 1
            }
            return false
        }
    }

    /// Whether the bytes contain "<!DOCTYPE" or "<!ENTITY" (any case).
    static func hasDeclaration(_ bytes: Data) -> Bool {
        let words: [[UInt8]] = [Array("DOCTYPE".utf8), Array("ENTITY".utf8)]
        return bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            var i = 0
            while i + 2 < n {
                if b[i] == 0x3C, b[i + 1] == 0x21 {
                    for w in words where i + 2 + w.count <= n {
                        var same = true
                        for k in 0..<w.count where (b[i + 2 + k] & 0xDF) != w[k] { same = false; break }
                        if same { return true }
                    }
                }
                i += 1
            }
            return false
        }
    }
}

/// The look of documents YummyOrange builds itself (Markdown, plain text, PDF reconstruction).
enum RichStyle {
    static let bodySize: CGFloat = 12
    static let codeSize: CGFloat = 10.5
    /// H1 to H6.
    static let headingSizes: [CGFloat] = [24, 19, 16, 14, 12, 11]
    static let bodyFamily = "Helvetica Neue"
    static let monoFamily = "Menlo"
    static let linkColor = NSColor(srgbRed: 0.05, green: 0.36, blue: 0.80, alpha: 1)
    static let codeBackground = NSColor(srgbRed: 0.955, green: 0.955, blue: 0.965, alpha: 1)
    static let quoteText = NSColor(srgbRed: 0.36, green: 0.36, blue: 0.40, alpha: 1)
    static let rule = NSColor(srgbRed: 0.80, green: 0.80, blue: 0.82, alpha: 1)
    static let tableBorder = NSColor(srgbRed: 0.75, green: 0.75, blue: 0.78, alpha: 1)
    static let headerBackground = NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1)
    static let caption = NSColor(srgbRed: 0.45, green: 0.45, blue: 0.48, alpha: 1)
    /// Widest a picture is shown, in points (fits A4 and Letter text widths).
    static let maxImageWidth: CGFloat = 440

    static func font(family: String = bodyFamily, size: CGFloat = bodySize, bold: Bool = false, italic: Bool = false) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let base = NSFontDescriptor(fontAttributes: [.family: family])
        let descriptor = traits.isEmpty ? base : base.withSymbolicTraits(traits)
        if let f = NSFont(descriptor: descriptor, size: size), f.familyName == family { return f }
        // Families without that face (or missing families) fall back to Helvetica, which always exists.
        let fallback = NSFontDescriptor(fontAttributes: [.family: "Helvetica"]).withSymbolicTraits(traits)
        return NSFont(descriptor: fallback, size: size) ?? NSFont(name: "Helvetica", size: size)!
    }

    static func mono(size: CGFloat = codeSize, bold: Bool = false, italic: Bool = false) -> NSFont {
        font(family: monoFamily, size: size, bold: bold, italic: italic)
    }

    static func paragraph(after: CGFloat = 8, before: CGFloat = 0, lineHeight: CGFloat = 1.15) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = after
        p.paragraphSpacingBefore = before
        p.lineHeightMultiple = lineHeight
        return p
    }
}

/// Font facts the writers care about, read off an NSFont without NSFontManager (safe off the main thread).
struct FontFacts: Equatable {
    var family: String
    var size: CGFloat
    var bold: Bool
    var italic: Bool
    var mono: Bool

    static let monoFamilies: Set<String> = ["menlo", "monaco", "courier", "courier new", "sf mono", "andale mono",
        "consolas", "source code pro", "pt mono", "jetbrains mono", "fira code", "fira mono", "lucida console",
        "inconsolata", "dejavu sans mono", "roboto mono", "ibm plex mono", "liberation mono", "cascadia code",
        "cascadia mono", "ubuntu mono", "hack", "letter gothic", "ocr a std", "nimbus mono"]

    init(family: String, size: CGFloat, bold: Bool, italic: Bool, mono: Bool) {
        self.family = family; self.size = size; self.bold = bold; self.italic = italic; self.mono = mono
    }

    private static let cache = NSCache<NSFont, FactsBox>()
    /// NSCache needs objects.
    private final class FactsBox { let facts: FontFacts; init(_ f: FontFacts) { facts = f } }

    /// Cached: documents use a handful of fonts across thousands of runs.
    static func of(_ font: NSFont?) -> FontFacts {
        guard let font else { return FontFacts(nil) }
        if let hit = cache.object(forKey: font) { return hit.facts }
        let facts = FontFacts(font)
        cache.setObject(FactsBox(facts), forKey: font)
        return facts
    }

    init(_ font: NSFont?) {
        guard let font else { self.init(family: "Helvetica", size: 12, bold: false, italic: false, mono: false); return }
        let traits = font.fontDescriptor.symbolicTraits
        let name = font.fontName.lowercased()
        let family = FontFacts.cleanFamily(font.familyName ?? font.fontName)
        let weight = (font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
        let bold = traits.contains(.bold) || weight >= 0.3 || name.contains("bold") || name.contains("black")
            || name.contains("heavy") || name.contains("semibold") || name.contains("demi")
        let italic = traits.contains(.italic) || name.contains("italic") || name.contains("oblique")
        let mono = traits.contains(.monoSpace) || font.isFixedPitch || FontFacts.monoFamilies.contains(family.lowercased())
            || name.contains("mono") || name.contains("courier")
        self.init(family: family, size: font.pointSize, bold: bold, italic: italic, mono: mono)
    }

    /// "ABCDEF+Helvetica-Bold" → "Helvetica"; PDF subset prefixes and style suffixes removed.
    static func cleanFamily(_ raw: String) -> String {
        var s = raw
        if let plus = s.firstIndex(of: "+"), s.distance(from: s.startIndex, to: plus) == 6 { s = String(s[s.index(after: plus)...]) }
        if s.hasPrefix(".") { return "Helvetica" }   // private system fonts (".SFNS…") mean nothing to other apps
        return s
    }
}

/// A picture inside a document.
struct RichImage {
    var data: Data
    /// "png", "jpeg" or "gif": formats every writer can embed. Others are converted to PNG on creation.
    var format: String
    var pixelSize: CGSize
    /// Size on the page, in points.
    var displaySize: CGSize
    var name: String
    var alt: String

    var mimeType: String { format == "jpeg" ? "image/jpeg" : "image/\(format)" }
    var fileExtension: String { format == "jpeg" ? "jpg" : format }

    /// Builds a picture from any image data ImageIO (or PDFKit, for PDF attachments) can decode.
    /// `display` is the size to show it at; nil uses the image's own size (its DPI respected), capped to the page.
    static func from(data: Data, name: String, alt: String = "", display: CGSize? = nil) -> RichImage? {
        guard !data.isEmpty else { return nil }
        if data.starts(with: Array("%PDF".utf8)), let provider = CGDataProvider(data: data as CFData),
           let doc = CGPDFDocument(provider), let page = doc.page(at: 1), let image = PDFTools.render(page, dpi: 144),
           let png = pngData(image) {
            let box = page.getBoxRect(.cropBox).size
            return RichImage(data: png, format: "png", pixelSize: CGSize(width: image.width, height: image.height),
                             displaySize: fit(display ?? box), name: baseName(name) + ".png", alt: alt)
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        var w = CGFloat(props[kCGImagePropertyPixelWidth] as? Int ?? 0), h = CGFloat(props[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        if orientation >= 5 { swap(&w, &h) }
        guard w > 0, h > 0 else { return nil }
        let dpi = max(72, (props[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72)
        let natural = CGSize(width: w * 72 / dpi, height: h * 72 / dpi)
        let type = (CGImageSourceGetType(src) as String?) ?? ""
        var format: String
        var bytes = data
        switch type {
        case UTType.png.identifier: format = "png"
        case UTType.jpeg.identifier: format = "jpeg"
        case UTType.gif.identifier: format = "gif"
        default: format = "png"; bytes = Data()
        }
        if bytes.isEmpty || orientation != 1 {
            // Formats other apps may not show (HEIC, TIFF, WebP…) and rotated JPEGs become upright PNGs.
            guard let image = try? Converter.orientedImage(src), let png = pngData(image) else { return nil }
            bytes = png; format = "png"
        }
        return RichImage(data: bytes, format: format, pixelSize: CGSize(width: w, height: h),
                         displaySize: fit(display ?? natural), name: baseName(name) + "." + (format == "jpeg" ? "jpg" : format), alt: alt)
    }

    static func jpegData(_ image: CGImage, quality: Double = 0.85) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    static func pngData(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Caps a size to the widest a picture is shown, keeping its shape.
    static func fit(_ size: CGSize, maxWidth: CGFloat = RichStyle.maxImageWidth, maxHeight: CGFloat = 620) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 100, height: 100) }
        let scale = min(1, maxWidth / size.width, maxHeight / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    private static func baseName(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let cleaned = base.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "-")
        return cleaned.isEmpty ? "image" : cleaned
    }
}

/// A stretch of text with one look.
struct RichRun {
    var text: String
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var code = false
    /// 1 superscript, -1 subscript.
    var script = 0
    var link: String?
    /// nil = the document's main font family.
    var family: String?
    var size: CGFloat = 12
    /// "RRGGBB", nil = automatic (black).
    var color: String?
    var highlight: String?
    var image: RichImage?

    /// Same look (everything except the text), so neighbours can merge.
    func sameStyle(_ o: RichRun) -> Bool {
        bold == o.bold && italic == o.italic && underline == o.underline && strike == o.strike && code == o.code &&
        script == o.script && link == o.link && family == o.family && abs(size - o.size) < 0.01 &&
        color == o.color && highlight == o.highlight && image == nil && o.image == nil
    }
}

/// One level of a list: its numbering style.
struct RichListLevel: Equatable {
    /// Marker kinds YummyOrange writes.
    enum Style: String { case bullet, circle, square, dash, decimal, lowerAlpha, upperAlpha, lowerRoman, upperRoman }
    var style: Style
    var start: Int = 1
    var ordered: Bool { ![.bullet, .circle, .square, .dash].contains(style) }

    static func from(_ list: NSTextList) -> RichListLevel {
        let f = list.markerFormat.rawValue.lowercased()
        let style: Style
        if f.contains("{decimal}") || f.contains("{octal}") || f.contains("{hexadecimal}") { style = .decimal }
        else if f.contains("{lower-alpha}") || f.contains("{lower-latin}") { style = .lowerAlpha }
        else if f.contains("{upper-alpha}") || f.contains("{upper-latin}") { style = .upperAlpha }
        else if f.contains("{lower-roman}") { style = .lowerRoman }
        else if f.contains("{upper-roman}") { style = .upperRoman }
        else if f.contains("{circle}") { style = .circle }
        else if f.contains("{square}") || f.contains("{box}") { style = .square }
        else if f.contains("{hyphen}") { style = .dash }
        else { style = .bullet }
        return RichListLevel(style: style, start: max(0, list.startingItemNumber))
    }

    /// The NSTextList marker format for this style.
    var markerFormat: NSTextList.MarkerFormat {
        switch style {
        case .bullet: return .disc
        case .circle: return .circle
        case .square: return .square
        case .dash: return .hyphen
        case .decimal: return NSTextList.MarkerFormat("{decimal}.")
        case .lowerAlpha: return NSTextList.MarkerFormat("{lower-alpha}.")
        case .upperAlpha: return NSTextList.MarkerFormat("{upper-alpha}.")
        case .lowerRoman: return NSTextList.MarkerFormat("{lower-roman}.")
        case .upperRoman: return NSTextList.MarkerFormat("{upper-roman}.")
        }
    }

    /// The marker text for item `n` ("•", "3.", "c.", "iv.").
    func marker(_ n: Int) -> String {
        switch style {
        case .bullet: return "•"
        case .circle: return "◦"
        case .square: return "▪"
        case .dash: return "–"
        case .decimal: return "\(n)."
        case .lowerAlpha: return RichListLevel.alpha(n).lowercased() + "."
        case .upperAlpha: return RichListLevel.alpha(n) + "."
        case .lowerRoman: return RichListLevel.roman(n).lowercased() + "."
        case .upperRoman: return RichListLevel.roman(n) + "."
        }
    }

    static func alpha(_ n: Int) -> String {
        var n = max(1, n), s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(UInt8(65 + n % 26))) + s; n /= 26 }
        return s
    }

    static func roman(_ n: Int) -> String {
        var n = max(1, min(n, 3999)), s = ""
        for (v, r) in [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"),
                       (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")] {
            while n >= v { s += r; n -= v }
        }
        return s
    }

    /// Bullet styles by depth, for lists that don't say.
    static func defaultBullet(depth: Int) -> RichListLevel {
        RichListLevel(style: [.bullet, .circle, .square][depth % 3])
    }
}

/// A paragraph and what kind it is.
struct RichParagraph {
    /// Body text, a heading (1–6) or a code line (with its language).
    enum Kind: Equatable { case body, heading(Int), code(String) }
    var kind: Kind = .body
    var quoteDepth = 0
    /// List nesting, outermost first. Empty: not in a list.
    var list: [RichListLevel] = []
    /// Ordinal of the item at the innermost level (ordered lists).
    var itemNumber = 1
    /// A paragraph that continues the previous list item (no marker of its own).
    var listContinuation = false
    /// nil: not a task item; true/false: checked or not.
    var task: Bool?
    var alignment: NSTextAlignment = .natural
    /// Right-to-left paragraph (Arabic, Hebrew…): from the source's direction or its first strong letter.
    var rtl = false
    /// Code paragraphs of one block share this (nil: unknown, consecutive code paragraphs merge).
    var codeBlockID: Int?
    var leftIndent: CGFloat = 0
    var firstLineIndent: CGFloat = 0
    var spaceBefore: CGFloat = 0
    var spaceAfter: CGFloat = 0
    var lineHeight: CGFloat = 0
    var background: String?
    var runs: [RichRun] = []

    var text: String { runs.map(\.text).joined() }
    var isEmpty: Bool { runs.allSatisfy { $0.image == nil && $0.text.trimmingCharacters(in: .whitespaces).isEmpty } }
    var headingLevel: Int? { if case .heading(let l) = kind { return l } else { return nil } }
    var codeLanguage: String? { if case .code(let l) = kind { return l } else { return nil } }

    /// Whether `next` continues the same code block (same language, place and block).
    func sameCodeBlock(_ next: RichParagraph) -> Bool {
        guard let lang = codeLanguage, next.codeLanguage == lang, next.quoteDepth == quoteDepth else { return false }
        return codeBlockID == next.codeBlockID
    }
}

/// A table cell: its paragraphs, spans and background.
struct RichCell {
    var paragraphs: [RichParagraph] = []
    var rowSpan = 1
    var colSpan = 1
    var background: String?
    /// Part of a merged cell that starts elsewhere.
    var covered = false
}

/// A table as a grid of rows; merged cells cover the slots they span.
struct RichTable {
    var rows: [[RichCell]]
    var headerRows: Int
    var columns: Int { rows.map(\.count).max() ?? 0 }
}

/// One block of a document, in reading order.
enum RichBlock {
    case paragraph(RichParagraph)
    case table(RichTable)
    case rule
    case pageBreak
}

/// A whole document: blocks plus the facts writers need (main font and size).
struct RichDocument {
    var blocks: [RichBlock] = []
    var title: String?
    var bodyFamily = RichStyle.bodyFamily
    var bodySize = RichStyle.bodySize
    /// The whole document is set in a monospaced font (plain-text dumps): don't call every line code.
    var monospaced = false

    var images: [RichImage] {
        var out: [RichImage] = []
        func scan(_ p: RichParagraph) { out += p.runs.compactMap(\.image) }
        for b in blocks {
            switch b {
            case .paragraph(let p): scan(p)
            case .table(let t): t.rows.joined().forEach { $0.paragraphs.forEach(scan) }
            default: break
            }
        }
        return out
    }
}

// MARK: - Analysis

extension RichDocument {
    /// Breaks rich text into blocks. Headings come from the paragraph's header level (set by the HTML and
    /// Markdown readers) or, failing that, from font size against the body text; lists from NSTextList;
    /// tables from NSTextTable; code from monospaced paragraphs in a proportional document.
    init(_ text: NSAttributedString, title: String? = nil) {
        self.title = title
        // A native copy: indexing a Swift-backed NSString character by character is slow on long texts.
        let ns = NSMutableString(string: text.string) as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0 else { return }

        // Main family and size: the most characters, ignoring headings and code.
        var familyCount: [String: Int] = [:], sizeCount: [CGFloat: Int] = [:], monoChars = 0, allChars = 0
        text.enumerateAttributes(in: full) { attrs, range, _ in
            if (attrs[.paragraphStyle] as? NSParagraphStyle)?.headerLevel ?? 0 > 0 { return }
            var facts = FontFacts.of(attrs[.font] as? NSFont)
            if let family = attrs[.dwFontFamily] as? String { facts.family = family }
            let n = ns.substring(with: range).unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
            guard n > 0 else { return }
            allChars += n
            if facts.mono { monoChars += n }
            if attrs[.dwCodeBlock] != nil || facts.mono { return }
            familyCount[facts.family, default: 0] += n
            sizeCount[(facts.size * 2).rounded() / 2, default: 0] += n
        }
        monospaced = allChars > 0 && Double(monoChars) / Double(allChars) > 0.9
        if monospaced {
            // Everything is monospaced: take the main font from all of it.
            text.enumerateAttribute(.font, in: full) { v, range, _ in
                let f = FontFacts.of(v as? NSFont)
                familyCount[f.family, default: 0] += range.length
                sizeCount[(f.size * 2).rounded() / 2, default: 0] += range.length
            }
        }
        bodyFamily = familyCount.max { $0.value < $1.value }?.key ?? RichStyle.bodyFamily
        bodySize = sizeCount.max { $0.value < $1.value }?.key ?? RichStyle.bodySize

        var table: (object: NSTextTable, cells: [String: (row: Int, col: Int, cell: RichCell)])?
        func flushTable() {
            guard let t = table else { return }
            blocks.append(.table(RichDocument.grid(t.object, t.cells.values.map { ($0.row, $0.col, $0.cell) })))
            table = nil
        }

        var counters: [ObjectIdentifier: Int] = [:]
        var lastItemLevels: [RichListLevel] = []
        /// Numbers items that carry no marker text (Cocoa's DOCX and ODT importers leave it out).
        func numbered(_ p: RichParagraph, _ style: NSParagraphStyle?, markerNumber: Int?) -> RichParagraph {
            var p = p
            guard !p.list.isEmpty, !p.listContinuation else { return p }
            guard let list = style?.textLists.last else {
                // A marker typed into the text carries its own number.
                if let markerNumber { p.itemNumber = markerNumber }
                lastItemLevels = p.list
                return p
            }
            let key = ObjectIdentifier(list)
            let n = markerNumber ?? ((counters[key] ?? (list.startingItemNumber - 1)) + 1)
            counters[key] = n
            p.itemNumber = n
            lastItemLevels = p.list
            return p
        }
        func continuation(_ p: RichParagraph, at location: Int) -> RichParagraph {
            guard p.list.isEmpty, let rawDepth = text.attribute(.dwListContinuation, at: location, effectiveRange: nil) as? Int,
                  rawDepth > 0, !lastItemLevels.isEmpty else { return p }
            let depth = min(rawDepth, RichLimits.blockDepth)
            var p = p
            p.list = Array(lastItemLevels.prefix(depth))
            while p.list.count < depth { p.list.append(.defaultBullet(depth: p.list.count)) }
            p.listContinuation = true
            p.leftIndent = 0; p.firstLineIndent = 0
            return p
        }

        var start = 0
        while start < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: start, length: 0))
            start = NSMaxRange(pr)
            var content = pr
            // Drop the paragraph terminator.
            while content.length > 0, let last = UnicodeScalar(ns.character(at: NSMaxRange(content) - 1)),
                  ["\n", "\r", "\u{2029}"].contains(Character(last)) { content.length -= 1 }
            let style = text.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle
            let tableBlock = style?.textBlocks.compactMap { $0 as? NSTextTableBlock }.first

            // Form feeds split a paragraph into page-broken pieces.
            var pieces: [NSRange] = []
            var pieceStart = content.location
            for i in content.location..<NSMaxRange(content) where ns.character(at: i) == 0x0C {
                pieces.append(NSRange(location: pieceStart, length: i - pieceStart))
                pieceStart = i + 1
            }
            pieces.append(NSRange(location: pieceStart, length: NSMaxRange(content) - pieceStart))

            for (pi, piece) in pieces.enumerated() {
                if pi > 0 { flushTable(); blocks.append(.pageBreak) }
                if pieces.count > 1 && piece.length == 0 { continue }
                if let tableBlock, pi == 0 {
                    if table.map({ $0.object !== tableBlock.table }) ?? false { flushTable() }
                    if table == nil { table = (tableBlock.table, [:]) }
                    let key = "\(tableBlock.startingRow),\(tableBlock.startingColumn)"
                    var entry = table!.cells[key] ?? (tableBlock.startingRow, tableBlock.startingColumn,
                                                     RichCell(rowSpan: tableBlock.rowSpan, colSpan: tableBlock.columnSpan,
                                                              background: tableBlock.backgroundColor.flatMap(RichDocument.hex)))
                    if let (p, _) = paragraph(text, ns, piece, style: style, inCell: true) { entry.cell.paragraphs.append(p) }
                    table!.cells[key] = entry
                    continue
                }
                flushTable()
                if text.attribute(.dwRule, at: min(piece.location, text.length - 1), effectiveRange: nil) != nil,
                   ns.substring(with: piece).trimmingCharacters(in: .whitespaces).isEmpty {
                    blocks.append(.rule)
                    continue
                }
                if let (p, number) = paragraph(text, ns, piece, style: style, inCell: false) {
                    blocks.append(.paragraph(continuation(numbered(p, style, markerNumber: number), at: piece.location < text.length ? piece.location : pr.location)))
                }
            }
        }
        flushTable()
    }

    /// Lays table cells out on a grid, marking the slots merged cells cover.
    private static func grid(_ table: NSTextTable, _ cells: [(Int, Int, RichCell)]) -> RichTable {
        let columns = max(table.numberOfColumns, (cells.map { $0.1 + $0.2.colSpan }.max() ?? 1))
        let rowsCount = cells.map { $0.0 + $0.2.rowSpan }.max() ?? 0
        var rows = Array(repeating: Array(repeating: RichCell(covered: true), count: columns), count: rowsCount)
        var filled = Array(repeating: Array(repeating: false, count: columns), count: rowsCount)
        for (r, c, cell) in cells where r < rowsCount && c < columns {
            rows[r][c] = cell
            filled[r][c] = true
            for rr in r..<min(rowsCount, r + cell.rowSpan) {
                for cc in c..<min(columns, c + cell.colSpan) where !(rr == r && cc == c) { filled[rr][cc] = true }
            }
        }
        // Slots no cell claims are real (empty) cells, not merged ones.
        for r in 0..<rowsCount { for c in 0..<columns where !filled[r][c] { rows[r][c] = RichCell() } }
        let headerLooksBold = rowsCount > 1 && rows[0].filter { !$0.covered }.allSatisfy { cell in
            cell.paragraphs.allSatisfy { p in p.runs.allSatisfy { $0.bold || $0.text.trimmingCharacters(in: .whitespaces).isEmpty } }
        }
        return RichTable(rows: rows, headerRows: headerLooksBold ? 1 : 0)
    }

    /// Reads one paragraph's runs and decides its kind. Returns nil only for nothing at all.
    private func paragraph(_ text: NSAttributedString, _ ns: NSString, _ range: NSRange, style: NSParagraphStyle?, inCell: Bool) -> (RichParagraph, Int?)? {
        var p = RichParagraph()
        var markerNumber: Int?
        var content = range
        if let style {
            p.alignment = style.alignment
            p.rtl = style.baseWritingDirection == .rightToLeft
            p.spaceBefore = style.paragraphSpacingBefore
            p.spaceAfter = style.paragraphSpacing
            p.lineHeight = style.lineHeightMultiple
            if !style.textLists.isEmpty {
                // Absurdly deep lists (hostile HTML) keep their outer levels and the item's own.
                let lists = style.textLists.count > RichLimits.blockDepth
                    ? Array(style.textLists.prefix(RichLimits.blockDepth - 1)) + [style.textLists.last!] : style.textLists
                p.list = lists.map(RichListLevel.from)
                if let raw = text.attribute(.dwListStyle, at: min(range.location, max(0, text.length - 1)), effectiveRange: nil) as? String,
                   let known = RichListLevel.Style(rawValue: raw) {
                    p.list[p.list.count - 1].style = known
                }
                // Cocoa's HTML and RTF importers keep the marker in the text ("\t•\tItem"; its DOCX and ODT
                // importers don't). Take it out, and read the number from it.
                let s = ns.substring(with: range)
                if let m = s.range(of: #"^\t?(\(?[0-9A-Za-z]{1,8}[.)]?|[^\t\n\p{L}\p{N}]{1,3})\t"#, options: .regularExpression) {
                    let marker = s[m].trimmingCharacters(in: .whitespaces)
                    markerNumber = RichDocument.ordinal(marker, style: p.list.last!.style)
                    content = NSRange(location: range.location + (s[..<m.upperBound] as Substring).utf16.count,
                                      length: range.length - (s[..<m.upperBound] as Substring).utf16.count)
                }
            } else if !inCell, let (level, number, length) = RichDocument.textMarker(ns.substring(with: range), style: style) {
                // Lists written as plain text ("\t•\tItem", "\t1\tItem"), as Cocoa's DOCX, DOC and RTF writers do.
                let depth = max(1, min(6, Int((style.headIndent / 36).rounded())))
                p.list = Array(repeating: level, count: depth)
                markerNumber = number
                content = NSRange(location: range.location + length, length: range.length - length)
            } else {
                p.leftIndent = style.headIndent
                p.firstLineIndent = style.firstLineHeadIndent - style.headIndent
            }
            if style.headerLevel > 0 { p.kind = .heading(min(6, style.headerLevel)) }
        }
        let at = min(range.location, max(0, text.length - 1))
        if let n = text.attribute(.dwListNumber, at: at, effectiveRange: nil) as? Int, !p.list.isEmpty { markerNumber = n }
        if let depth = text.attribute(.dwQuote, at: at, effectiveRange: nil) as? Int { p.quoteDepth = depth }
        else if let intent = text.attribute(.presentationIntentAttributeName, at: at, effectiveRange: nil) as? PresentationIntent {
            // The HTML importer marks block quotes and code blocks this way (macOS 12+).
            for component in intent.components {
                switch component.kind {
                case .blockQuote: p.quoteDepth += 1
                case .header(let level) where p.headingLevel == nil: p.kind = .heading(min(6, max(1, level)))
                case .codeBlock(let lang) where p.headingLevel == nil:
                    p.kind = .code(lang ?? "")
                    p.codeBlockID = -1 - component.identity   // negative: never equal to a reader's own ids
                default: break
                }
            }
        }
        p.quoteDepth = min(p.quoteDepth, RichLimits.blockDepth)
        if let lang = text.attribute(.dwCodeBlock, at: at, effectiveRange: nil) as? String {
            p.kind = .code(lang)
            if let id = text.attribute(.dwCodeBlockID, at: at, effectiveRange: nil) as? Int { p.codeBlockID = id }
        }
        if p.quoteDepth > 0 || p.codeLanguage != nil { p.leftIndent = 0; p.firstLineIndent = 0 }   // the block shows the indent

        p.runs = runs(text, ns, content)
        // A paragraph with no stated direction reads the way its first strong letter does.
        if !p.rtl, style?.baseWritingDirection != .leftToRight, RichDocument.startsRightToLeft(ns.substring(with: content)) { p.rtl = true }
        if p.quoteDepth > 0 || p.headingLevel == 6 {
            // The reader's own quote and small-heading greys are part of the style, not the text.
            for i in p.runs.indices where p.runs[i].color == RichDocument.hex(RichStyle.quoteText) || p.runs[i].color == RichDocument.hex(RichStyle.caption) {
                p.runs[i].color = nil
            }
        }
        // Task items: "☐ Buy milk" / "☑ Done".
        if !p.list.isEmpty, !p.listContinuation, let first = p.runs.first?.text {
            for (mark, done) in [("☐ ", false), ("☑ ", true), ("☒ ", true), ("[ ] ", false), ("[x] ", true), ("[X] ", true)]
            where first.hasPrefix(mark) {
                p.task = done
                p.runs[0].text.removeFirst(mark.count)
                if p.runs[0].text.isEmpty { p.runs.removeFirst() }
                break
            }
        }

        let visible = p.runs.filter { $0.image != nil || $0.text.utf16.contains(where: { $0 != 0x20 && $0 != 0x09 }) }
        if p.kind == .body, !monospaced, !inCell, !visible.isEmpty, visible.allSatisfy({ $0.code && $0.image == nil }) {
            p.kind = .code("")
            for i in p.runs.indices { p.runs[i].code = false }
        }
        if case .code = p.kind { for i in p.runs.indices { p.runs[i].code = false } }
        if p.kind == .body, p.list.isEmpty, !inCell, !visible.isEmpty, visible.allSatisfy({ $0.image == nil }),
           case let units = p.runs.reduce(0, { $0 + $1.text.utf16.count }), units < 300,
           !p.runs.contains(where: { $0.text.utf16.contains(0x2028) }), visible.contains(where: { $0.size > bodySize * 1.07 }) {
            // No header level: guess from size against the body text.
            let sizes = visible.map(\.size)
            let size = sizes.max() ?? bodySize
            let ratio = size / max(bodySize, 1)
            let allBold = visible.allSatisfy(\.bold)
            if ratio >= 1.85 { p.kind = .heading(1) }
            else if ratio >= 1.45 { p.kind = .heading(2) }
            else if ratio >= 1.2 { p.kind = .heading(3) }
            else if ratio >= 1.08 && allBold { p.kind = .heading(4) }
        }
        return (p, markerNumber)
    }

    /// The runs of a range, neighbours with the same look merged.
    private func runs(_ text: NSAttributedString, _ ns: NSString, _ range: NSRange) -> [RichRun] {
        var out: [RichRun] = []
        guard range.length > 0 else { return out }
        text.enumerateAttributes(in: range) { attrs, r, _ in
            var run = RichRun(text: ns.substring(with: r))
            var facts = FontFacts.of(attrs[.font] as? NSFont)
            if let family = attrs[.dwFontFamily] as? String { facts.family = family }
            run.bold = facts.bold
            run.italic = facts.italic
            run.code = facts.mono && !monospaced
            run.size = facts.size
            run.family = facts.family == bodyFamily || run.code ? nil : facts.family
            if let u = attrs[.underlineStyle] as? Int, u != 0 { run.underline = true }
            if let s = attrs[.strikethroughStyle] as? Int, s != 0 { run.strike = true }
            if let sup = attrs[.superscript] as? Int, sup != 0 { run.script = sup > 0 ? 1 : -1 }
            else if let off = attrs[.baselineOffset] as? CGFloat, abs(off) >= 1, facts.size < bodySize { run.script = off > 0 ? 1 : -1 }
            if let url = attrs[.link] as? URL { run.link = url.absoluteString }
            else if let s = attrs[.link] as? String { run.link = s }
            if let c = attrs[.foregroundColor] as? NSColor, let h = RichDocument.hex(c), !RichDocument.isPlain(h, link: run.link != nil) {
                run.color = h
            }
            if let c = attrs[.backgroundColor] as? NSColor, let h = RichDocument.hex(c), h != "FFFFFF", !run.code {
                run.highlight = h
            }
            if run.link != nil, run.underline { run.underline = false }   // links are underlined by their style
            if let link = run.link, !RichDocument.isSafeLink(link) { run.link = nil }   // javascript:, data:… keep only their text
            if let attachment = attrs[.attachment] as? NSTextAttachment {
                let alt = attrs[.dwImageAlt] as? String ?? ""
                let rest = run.text.replacingOccurrences(of: "\u{FFFC}", with: "")
                if let image = RichDocument.image(from: attachment, alt: alt) {
                    var pic = run
                    pic.text = "\u{FFFC}"
                    pic.image = image
                    // One run per picture; any other characters in the range stay as text.
                    out.append(pic)
                    if !rest.isEmpty { run.text = rest; out.append(run) }
                } else if let label = RichDocument.attachmentLabel(attachment, alt: alt) {
                    // A file that isn't a picture (or a picture that never loaded) is named, not drawn as an icon.
                    run.text = "[\(label)]" + rest
                    if let last = out.last, last.sameStyle(run) { out[out.count - 1].text += run.text } else { out.append(run) }
                } else if !rest.isEmpty {
                    run.text = rest
                    out.append(run)
                }
                return
            }
            if run.text.utf16.contains(0xFFFC) { run.text = run.text.replacingOccurrences(of: "\u{FFFC}", with: "") }
            guard !run.text.isEmpty else { return }
            if let last = out.last, last.sameStyle(run) { out[out.count - 1].text += run.text } else { out.append(run) }
        }
        return out
    }

    /// Text attachments → pictures. Non-picture attachments (a PDF stays a picture of its first page) are skipped.
    static func image(from attachment: NSTextAttachment, alt: String) -> RichImage? {
        let wrapper = attachment.fileWrapper
        let name = wrapper?.preferredFilename ?? wrapper?.filename ?? "image.png"
        let display: CGSize? = attachment.bounds.size.width > 1 ? attachment.bounds.size : nil
        if let data = wrapper?.isRegularFile == true ? wrapper?.regularFileContents : nil,
           let img = RichImage.from(data: data, name: name, alt: alt, display: display) { return img }
        if let data = attachment.contents, let img = RichImage.from(data: data, name: name, alt: alt, display: display) { return img }
        // An attachment with a file or data of its own that isn't a picture shows a system icon (a text file's
        // page, a broken picture's "?"): that icon isn't the document's. Only a bare image (set in code) counts.
        guard wrapper == nil, attachment.contents == nil else { return nil }
        if let image = attachment.image ?? (attachment.attachmentCell as? NSTextAttachmentCell)?.image,
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let png = RichImage.pngData(cg) {
            return RichImage.from(data: png, name: name, alt: alt, display: display ?? image.size)
        }
        return nil
    }

    /// What to write in place of an attachment that isn't a picture: its alt text or file name.
    static func attachmentLabel(_ attachment: NSTextAttachment, alt: String) -> String? {
        let a = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !a.isEmpty { return a }
        guard let wrapper = attachment.fileWrapper else { return nil }
        let name = wrapper.preferredFilename ?? wrapper.filename ?? ""
        let stem = (name as NSString).deletingPathExtension.lowercased()
        if name.isEmpty || ["attachment", "image", "unknown", "picture"].contains(stem) { return nil }
        return name
    }

    /// Links writers keep: web, mail, phone, files, in-document anchors and relative paths. Script-capable
    /// schemes (javascript:, vbscript:, data:) and anything unknown lose their target and keep their text.
    static func isSafeLink(_ link: String) -> Bool {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !s.isEmpty else { return false }
        if s.hasPrefix("#") { return true }
        // A scheme is letters, digits, + - . before the first ':' (and before any '/', '?' or '#').
        guard let colon = s.firstIndex(of: ":") else { return true }
        let scheme = s[..<colon]
        if scheme.contains(where: { "/?#".contains($0) }) { return true }   // "a/b:c" is a relative path
        let lower = scheme.lowercased().filter { !$0.isWhitespace }
        return ["http", "https", "mailto", "tel", "ftp", "ftps", "sms", "news", "irc", "ircs", "xmpp", "file"].contains(lower)
    }

    /// Whether the text's first strong letter is right-to-left (Hebrew, Arabic, Syriac, Thaana, N'Ko…).
    static func startsRightToLeft(_ s: String) -> Bool {
        for u in s.unicodeScalars {
            let v = u.value
            if (0x0590...0x08FF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v)
                || (0x10800...0x10FFF).contains(v) || (0x1E800...0x1EFFF).contains(v) {
                // Combining marks and Arabic digits in these blocks aren't strong; letters are.
                if u.properties.isAlphabetic { return true }
                continue
            }
            if u.properties.isAlphabetic { return false }
        }
        return false
    }

    /// A list marker typed into the text: its level, number, and length in UTF-16 units. Numbers count
    /// only with a hanging indent, so tab-separated text isn't mistaken for a list.
    static func textMarker(_ s: String, style: NSParagraphStyle) -> (RichListLevel, Int?, Int)? {
        guard s.hasPrefix("\t") || s.contains("\t") else { return nil }
        if let m = s.range(of: #"^\t?([•◦▪▫‣⁃–*●○■□✓-])\t"#, options: .regularExpression) {
            let glyph = s[m].trimmingCharacters(in: .whitespaces)
            let kind: RichListLevel.Style = ["◦", "○"].contains(glyph) ? .circle : ["▪", "▫", "■", "□"].contains(glyph) ? .square
                : ["–", "-", "⁃"].contains(glyph) ? .dash : .bullet
            return (RichListLevel(style: kind), nil, s[..<m.upperBound].utf16.count)
        }
        guard style.headIndent > 0, style.firstLineHeadIndent < style.headIndent,
              let m = s.range(of: #"^\t?\(?([0-9]{1,3}|[a-z]|[A-Z]|[ivxlc]{1,6}|[IVXLC]{1,6})[.)]?\t"#, options: .regularExpression) else { return nil }
        let core = s[m].trimmingCharacters(in: CharacterSet(charactersIn: "\t().").union(.whitespaces))
        let kind: RichListLevel.Style
        if Int(core) != nil { kind = .decimal }
        else if core.allSatisfy({ "ivxlc".contains($0) }) && core != "c" { kind = .lowerRoman }
        else if core.allSatisfy({ "IVXLC".contains($0) }) && core != "C" { kind = .upperRoman }
        else { kind = core.first!.isUppercase ? .upperAlpha : .lowerAlpha }
        return (RichListLevel(style: kind), ordinal(core, style: kind), s[..<m.upperBound].utf16.count)
    }

    /// The item number written in a list marker ("3.", "c)", "iv."), or nil for bullets.
    static func ordinal(_ marker: String, style: RichListLevel.Style) -> Int? {
        let core = marker.trimmingCharacters(in: CharacterSet(charactersIn: ".)( \t"))
        switch style {
        case .decimal: return Int(core)
        case .lowerAlpha, .upperAlpha:
            guard !core.isEmpty, core.allSatisfy({ $0.isLetter }) else { return nil }
            return core.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 }
        case .lowerRoman, .upperRoman:
            let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
            let digits = core.uppercased().compactMap { values[$0] }
            guard !digits.isEmpty, digits.count == core.count else { return nil }
            var total = 0
            for (i, v) in digits.enumerated() { total += (i + 1 < digits.count && digits[i + 1] > v) ? -v : v }
            return total
        default: return nil
        }
    }

    /// "RRGGBB" in sRGB, or nil for colors that can't be converted (patterns).
    static func hex(_ color: NSColor) -> String? {
        guard let c = color.usingColorSpace(.sRGB), c.alphaComponent > 0.05 else { return nil }
        let a = c.alphaComponent
        // Blend translucent colors onto white, the page they'll sit on.
        func ch(_ v: CGFloat) -> Int { Int(((v * a + (1 - a)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", ch(c.redComponent), ch(c.greenComponent), ch(c.blueComponent))
    }

    /// Near-black text (and the usual link blues on links) counts as "automatic" color.
    static func isPlain(_ hex: String, link: Bool) -> Bool {
        guard let v = Int(hex, radix: 16) else { return true }
        let r = (v >> 16) & 0xFF, g = (v >> 8) & 0xFF, b = v & 0xFF
        if max(r, g, b) < 40 { return true }
        if link && b > 150 && r < 90 && g < 140 { return true }
        return false
    }
}

// MARK: - Shared helpers for writers

extension RichDocument {
    /// Paragraph blocks grouped into runs of consecutive list items (with continuations), for writers that
    /// need nested list elements. Each element is either a single block or a list run.
    enum Group {
        case block(RichBlock)
        case list([RichParagraph])
    }

    func grouped() -> [Group] {
        var out: [Group] = []
        var current: [RichParagraph] = []
        func flush() { if !current.isEmpty { out.append(.list(current)); current = [] } }
        for b in blocks {
            if case .paragraph(let p) = b, !p.list.isEmpty {
                // A list run stays at one quote depth.
                if let first = current.first, first.quoteDepth != p.quoteDepth { flush() }
                if !(current.isEmpty && p.listContinuation) { current.append(p); continue }
            }
            flush()
            out.append(.block(b))
        }
        flush()
        return out
    }
}

/// A nested list built from flat list paragraphs.
final class RichListNode {
    let level: RichListLevel
    var items: [(paragraphs: [RichParagraph], children: [RichListNode])] = []
    init(_ level: RichListLevel) { self.level = level }

    /// Builds the tree. Items whose depth jumps by more than one are attached as deep as they say.
    static func build(_ paragraphs: [RichParagraph]) -> [RichListNode] {
        var roots: [RichListNode] = []
        var stack: [RichListNode] = []
        for p in paragraphs {
            let depth = max(1, p.list.count)
            if p.listContinuation, let top = stack.last, !top.items.isEmpty {
                // Continuations belong to the item at their depth or the deepest open one.
                let owner = stack.count >= depth ? stack[depth - 1] : top
                if owner.items.isEmpty { owner.items.append(([p], [])) } else { owner.items[owner.items.count - 1].paragraphs.append(p) }
                continue
            }
            while stack.count > depth { stack.removeLast() }
            if stack.count == depth, stack[depth - 1].level.ordered != p.list[depth - 1].ordered {
                stack.removeLast()   // a bulleted list right after a numbered one (or the reverse) is a new list
            }
            while stack.count < depth {
                let level = p.list[stack.count]
                let node = RichListNode(level)
                if let parent = stack.last {
                    if parent.items.isEmpty { parent.items.append(([], [])) }
                    parent.items[parent.items.count - 1].children.append(node)
                } else {
                    roots.append(node)
                }
                stack.append(node)
            }
            stack[depth - 1].items.append(([p], []))
        }
        return roots
    }
}

/// XML text escaping that also drops characters XML 1.0 forbids (control codes, U+FFFE/FFFF).
func richXMLEscape(_ s: String, attribute: Bool = false) -> String {
    var out = ""
    out.reserveCapacity(s.utf8.count)
    for scalar in s.unicodeScalars {
        switch scalar {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"" where attribute: out += "&quot;"
        case "\n" where attribute: out += "&#10;"
        case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
        default:
            let v = scalar.value
            if v < 0x20 || v == 0xFFFE || v == 0xFFFF || (0x7F...0x84).contains(v) || (0x86...0x9F).contains(v) { continue }
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}
