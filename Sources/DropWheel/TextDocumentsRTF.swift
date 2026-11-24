import AppKit

/// RTF with pictures. Cocoa's RTF reader skips `\pict` groups and its writer drops attachments, so
/// pictures are carried across by hand: on reading, each picture group is swapped for a placeholder
/// before Cocoa parses the text and turned into an attachment afterwards; on writing, attachments
/// become placeholders that are replaced with `\pict\pngblip` / `\jpegblip` groups.
enum RichRTF {
    private static func token(_ n: Int) -> String { String(format: "DWPICT%05dX", n) }
    /// Placeholder for a horizontal rule; written as a bottom paragraph border.
    static let ruleToken = "DWRULEX"

    // MARK: Reading

    static func read(data: Data) throws -> NSAttributedString {
        let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.rtf]
        // Latin-1 maps every byte to one character, so offsets survive the round trip.
        guard let source = String(data: data, encoding: .isoLatin1), source.contains("\\pict") else {
            return try NSAttributedString(data: data, options: opts, documentAttributes: nil)
        }
        var pictures: [RichImage] = []
        let rewritten = extract(source, &pictures)
        guard !pictures.isEmpty, let rtf = rewritten.data(using: .isoLatin1) else {
            return try NSAttributedString(data: data, options: opts, documentAttributes: nil)
        }
        let text = NSMutableAttributedString(attributedString: try NSAttributedString(data: rtf, options: opts, documentAttributes: nil))
        for (n, image) in pictures.enumerated().reversed() {
            let r = (text.string as NSString).range(of: token(n))
            guard r.location != NSNotFound else { continue }
            let wrapper = FileWrapper(regularFileWithContents: image.data)
            wrapper.preferredFilename = image.name
            let attachment = NSTextAttachment(fileWrapper: wrapper)
            attachment.bounds = CGRect(origin: .zero, size: image.displaySize)
            var attrs = text.attributes(at: r.location, effectiveRange: nil)
            attrs[.attachment] = attachment
            text.replaceCharacters(in: r, with: NSAttributedString(string: "\u{FFFC}", attributes: attrs))
        }
        return text
    }

    /// Replaces picture groups with placeholders, collecting the pictures it can decode.
    private static func extract(_ s: String, _ pictures: inout [RichImage]) -> String {
        let c = Array(s.utf8)
        var out = [UInt8]()
        out.reserveCapacity(c.count)
        var i = 0
        func matches(_ word: String, at j: Int) -> Bool {
            let w = Array(word.utf8)
            guard j + w.count <= c.count, Array(c[j..<(j + w.count)]) == w else { return false }
            let next = j + w.count < c.count ? c[j + w.count] : 0x20
            return !((0x41...0x5A).contains(next) || (0x61...0x7A).contains(next))
        }
        while i < c.count {
            if c[i] == UInt8(ascii: "{") {
                var j = i + 1
                while j < c.count, c[j] == 0x0A || c[j] == 0x0D || c[j] == 0x20 { j += 1 }
                let isNonShp = matches("\\*\\nonshppict", at: j)
                let isShp = matches("\\*\\shppict", at: j)
                let isPict = matches("\\pict", at: j)
                if isNonShp || isShp || isPict, let end = groupEnd(c, i) {
                    if isNonShp {
                        i = end + 1; continue   // an older duplicate of the picture before it
                    }
                    let inner = String(decoding: c[(i + 1)..<end], as: UTF8.self)
                    if let image = picture(inner) {
                        out += Array(token(pictures.count).utf8)
                        pictures.append(image)
                    }
                    i = end + 1
                    continue
                }
            }
            if c[i] == UInt8(ascii: "\\"), i + 1 < c.count { out.append(c[i]); out.append(c[i + 1]); i += 2; continue }
            out.append(c[i]); i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Index of the brace closing the group that opens at `start`.
    private static func groupEnd(_ c: [UInt8], _ start: Int) -> Int? {
        var depth = 0, i = start
        while i < c.count {
            switch c[i] {
            case UInt8(ascii: "\\"): i += 1
            case UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
            i += 1
        }
        return nil
    }

    /// Decodes one picture group (its text without the outer braces). PNG, JPEG and DIB bitmaps are
    /// supported; Windows metafiles and old QuickDraw pictures can't be drawn on macOS and are skipped.
    private static func picture(_ group: String) -> RichImage? {
        // A \shppict wrapper holds the real \pict group: use that.
        if let r = group.range(of: "{\\pict"), !group.hasPrefix("\\pict") {
            let bytes = Array(group.utf8)
            let offset = group.utf8.distance(from: group.startIndex, to: r.lowerBound)
            if let end = groupEnd(bytes, offset) { return picture(String(decoding: bytes[(offset + 1)..<end], as: UTF8.self)) }
        }
        var words: [String: Int] = [:]
        var kind = ""
        var hex = [UInt8]()
        let c = Array(group.utf8)
        var i = 0, depth = 0
        while i < c.count {
            let ch = c[i]
            if ch == UInt8(ascii: "{") { depth += 1; i += 1; continue }
            if ch == UInt8(ascii: "}") { depth -= 1; i += 1; continue }
            if depth > 0 { i += 1; continue }   // nested groups (\*\blipuid …) carry no pixels
            if ch == UInt8(ascii: "\\") {
                var j = i + 1, name = ""
                while j < c.count, (0x61...0x7A).contains(c[j]) || (0x41...0x5A).contains(c[j]) { name.append(Character(UnicodeScalar(c[j]))); j += 1 }
                var num = ""
                if j < c.count, c[j] == UInt8(ascii: "-") { num = "-"; j += 1 }
                while j < c.count, (0x30...0x39).contains(c[j]) { num.append(Character(UnicodeScalar(c[j]))); j += 1 }
                if j < c.count, c[j] == 0x20 { j += 1 }
                if ["pngblip", "jpegblip", "emfblip", "wmetafile", "macpict", "dibitmap", "wbitmap", "pmmetafile"].contains(name) { kind = name }
                if name == "bin", let n = Int(num), j + n <= c.count {
                    return image(kind: kind, bytes: Array(c[j..<(j + n)]), words: words)
                }
                if let n = Int(num) { words[name] = n }
                i = j
                continue
            }
            if (0x30...0x39).contains(ch) || (0x61...0x66).contains(ch) || (0x41...0x46).contains(ch) { hex.append(ch) }
            i += 1
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        func nibble(_ x: UInt8) -> UInt8 { x <= 0x39 ? x - 0x30 : (x | 0x20) - 0x61 + 10 }
        var k = 0
        while k + 1 < hex.count { bytes.append(nibble(hex[k]) << 4 | nibble(hex[k + 1])); k += 2 }
        return image(kind: kind, bytes: bytes, words: words)
    }

    private static func image(kind: String, bytes: [UInt8], words: [String: Int]) -> RichImage? {
        var data = Data(bytes)
        switch kind {
        case "pngblip", "jpegblip": break
        case "dibitmap":
            // A device-independent bitmap without its file header: add one so ImageIO reads it as BMP.
            guard bytes.count > 40 else { return nil }
            let headerSize = Int(bytes[0]) | Int(bytes[1]) << 8
            let colors = Int(bytes[32]) | Int(bytes[33]) << 8
            let bits = Int(bytes[14]) | Int(bytes[15]) << 8
            let palette = (colors == 0 && bits <= 8 ? 1 << bits : colors) * 4
            var bmp = Data([0x42, 0x4D])
            bmp.le32(UInt32(14 + bytes.count)); bmp.le32(0); bmp.le32(UInt32(14 + headerSize + palette))
            data = bmp + data
        default:
            return nil
        }
        var display: CGSize?
        if let gw = words["picwgoal"], let gh = words["pichgoal"], gw > 0, gh > 0 {
            let sx = CGFloat(words["picscalex"] ?? 100) / 100, sy = CGFloat(words["picscaley"] ?? 100) / 100
            display = CGSize(width: CGFloat(gw) / 20 * sx, height: CGFloat(gh) / 20 * sy)
        }
        return RichImage.from(data: data, name: "picture", display: display)
    }

    // MARK: Writing

    static func write(_ text: NSAttributedString) throws -> Data {
        let copy = NSMutableAttributedString(attributedString: text)
        var ranges: [NSRange] = []
        copy.enumerateAttribute(.attachment, in: NSRange(location: 0, length: copy.length)) { v, r, _ in
            if v is NSTextAttachment { ranges.append(r) }
        }
        var pictures: [Int: RichImage] = [:]
        for (k, r) in ranges.enumerated().reversed() {
            guard let attachment = copy.attribute(.attachment, at: r.location, effectiveRange: nil) as? NSTextAttachment else { continue }
            var attrs = copy.attributes(at: r.location, effectiveRange: nil)
            attrs[.attachment] = nil
            let image = RichDocument.image(from: attachment, alt: "")
            pictures[k] = image
            copy.replaceCharacters(in: r, with: NSAttributedString(string: image == nil ? "" : token(k), attributes: attrs))
        }
        let range = NSRange(location: 0, length: copy.length)
        let data = try copy.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        guard !pictures.isEmpty || copy.string.contains(ruleToken), var rtf = String(data: data, encoding: .isoLatin1) else { return data }
        for (k, image) in pictures { rtf = rtf.replacingOccurrences(of: token(k), with: pict(image)) }
        rtf = rtf.replacingOccurrences(of: ruleToken, with: "\\brdrb\\brdrs\\brdrw10\\brsp40\\brdrcf0 ")
        return rtf.data(using: .isoLatin1) ?? data
    }

    private static func pict(_ image: RichImage) -> String {
        var img = image
        if img.format == "gif", let src = CGImageSourceCreateWithData(img.data as CFData, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, nil), let png = RichImage.pngData(cg) {
            img.data = png; img.format = "png"
        }
        let blip = img.format == "jpeg" ? "\\jpegblip" : "\\pngblip"
        let w = Int(img.pixelSize.width), h = Int(img.pixelSize.height)
        let gw = Int((img.displaySize.width * 20).rounded()), gh = Int((img.displaySize.height * 20).rounded())
        let digits = Array("0123456789abcdef".utf8)
        var hex = [UInt8]()
        hex.reserveCapacity(img.data.count * 2 + img.data.count / 64 + 8)
        for (i, byte) in img.data.enumerated() {
            hex.append(digits[Int(byte >> 4)]); hex.append(digits[Int(byte & 0x0F)])
            if i % 64 == 63 { hex.append(0x0A) }
        }
        return "{\\pict\(blip)\\picw\(w)\\pich\(h)\\picwgoal\(gw)\\pichgoal\(gh)\n" + String(decoding: hex, as: UTF8.self) + "}"
    }
}
