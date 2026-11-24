import AppKit

/// Plain text in and out, and Finder text clippings.
enum RichPlainText {
    /// Decodes text bytes: a byte-order mark first (UTF-8, UTF-16, UTF-32), then UTF-8, then BOM-less
    /// UTF-16 (detected from its zero bytes), then Windows-1252, which covers most old Western files.
    static func decode(_ data: Data) -> (text: String, encoding: String.Encoding) {
        let b = [UInt8](data.prefix(4))
        if b.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(data: data.dropFirst(3), encoding: .utf8) { return (s, .utf8) }
        if b.starts(with: [0xFF, 0xFE, 0x00, 0x00]), let s = String(data: data.dropFirst(4), encoding: .utf32LittleEndian) { return (s, .utf32LittleEndian) }
        if b.starts(with: [0x00, 0x00, 0xFE, 0xFF]), let s = String(data: data.dropFirst(4), encoding: .utf32BigEndian) { return (s, .utf32BigEndian) }
        if b.starts(with: [0xFF, 0xFE]), let s = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) { return (s, .utf16LittleEndian) }
        if b.starts(with: [0xFE, 0xFF]), let s = String(data: data.dropFirst(2), encoding: .utf16BigEndian) { return (s, .utf16BigEndian) }
        // UTF-16 without a BOM: ASCII-heavy text has a zero in every other byte. (Zero bytes are valid
        // UTF-8, so this has to be looked at first; real text files don't contain them.)
        let sample = [UInt8](data.prefix(4096))
        if sample.count >= 4, sample.contains(0) {
            let evenZeros = stride(from: 0, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
            let oddZeros = stride(from: 1, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
            let half = sample.count / 2
            if oddZeros > half * 4 / 10, evenZeros < half / 10, let s = String(data: data, encoding: .utf16LittleEndian) { return (s, .utf16LittleEndian) }
            if evenZeros > half * 4 / 10, oddZeros < half / 10, let s = String(data: data, encoding: .utf16BigEndian) { return (s, .utf16BigEndian) }
        }
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        if let (s, encoding) = eastAsian(data) { return (s, encoding) }
        if let s = String(data: data, encoding: .windowsCP1252) { return (s, .windowsCP1252) }
        if let s = String(data: data, encoding: .isoLatin1) { return (s, .isoLatin1) }
        return (String(decoding: data, as: UTF8.self), .utf8)
    }

    /// Japanese, Chinese and Korean legacy encodings (Shift_JIS, EUC-JP, GB18030, Big5, EUC-KR), when one
    /// of them reads the bytes cleanly as text in that script. Western text in Windows-1252 also decodes
    /// in some of them, but then its accented letters turn into lone ideographs inside Latin words, which
    /// is what rules them out.
    static func eastAsian(_ data: Data) -> (String, String.Encoding)? {
        func enc(_ cf: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
        }
        let sample = data.prefix(200_000)
        guard sample.contains(where: { $0 >= 0x80 }) else { return nil }
        // (encoding, the script it should mostly decode to)
        let candidates: [(String.Encoding, String)] = [
            (.shiftJIS, "ja"), (.japaneseEUC, "ja"), (enc(.GB_18030_2000), "zh"), (enc(.big5), "zh"), (enc(.EUC_KR), "ko"),
        ]
        var best: (score: Double, encoding: String.Encoding)?
        for (encoding, script) in candidates {
            // A cut sample may end inside a character: back off a byte or three.
            let tries = sample.count < data.count ? 0...3 : 0...0
            guard let text = tries.lazy.compactMap({ String(data: sample.dropLast($0), encoding: encoding) }).first else { continue }
            var good = 0, bad = 0, kana = 0, hangul = 0, lone = 0
            let scalars = Array(text.unicodeScalars)
            for (k, u) in scalars.enumerated() where u.value >= 0x80 {
                let v = u.value
                let isKana = (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v)
                let isHangul = (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v)
                let isHan = (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
                let isPunct = (0x3000...0x303F).contains(v) || (0xFF01...0xFF60).contains(v) || (0xFFE0...0xFFE6).contains(v)
                    || (0x2010...0x2027).contains(v) || (0x2030...0x203B).contains(v) || (0x2460...0x24FF).contains(v)
                    || (0x2500...0x257F).contains(v) || (0x25A0...0x25FF).contains(v) || (0x2190...0x21FF).contains(v)
                    || v == 0x00B7 || v == 0x00D7 || v == 0x00F7 || v == 0x00B0 || v == 0x00A7
                if isKana { kana += 1 }
                if isHangul { hangul += 1 }
                if isKana || isHangul || isHan || isPunct { good += 1 } else { bad += 1 }
                // A single ideograph with ASCII letters on both sides is a misread accented letter.
                if isHan || isHangul, k > 0, k + 1 < scalars.count,
                   scalars[k - 1].value < 0x80 && scalars[k - 1].properties.isAlphabetic,
                   scalars[k + 1].value < 0x80 && scalars[k + 1].properties.isAlphabetic { lone += 1 }
            }
            let total = good + bad
            guard total > 0, Double(good) >= 0.95 * Double(total), Double(lone) <= 0.1 * Double(good) else { continue }
            if text.unicodeScalars.contains(where: { $0.value == 0xFFFD || ($0.value < 0x20 && ![0x09, 0x0A, 0x0D, 0x0C].contains($0.value)) }) { continue }
            // Japanese text always has kana; Korean is mostly Hangul; Chinese has neither.
            var score = Double(good - 3 * bad - 3 * lone)
            switch script {
            case "ja": score *= kana > 0 ? 1.2 : 0.5
            case "ko": score *= hangul * 2 > good ? 1.2 : 0.3
            default: score *= kana == 0 && hangul == 0 ? 1.0 : 0.6
            }
            if score > 0, score > (best?.score ?? 0) { best = (score, encoding) }
        }
        guard let best, let s = String(data: data, encoding: best.encoding) else { return nil }
        return (s, best.encoding)
    }

    /// Text that lines things up with runs of spaces, box drawing or tab columns (tables, ASCII art, code)
    /// keeps a monospaced font; prose gets the normal body font.
    static func looksAligned(_ text: String) -> Bool {
        var lines = 0, aligned = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(2000) {
            lines += 1
            let trimmed = line.drop { $0 == " " }
            if line.contains("   ") && trimmed.contains("   ") { aligned += 1; continue }
            if line.unicodeScalars.contains(where: { (0x2500...0x257F).contains($0.value) }) { aligned += 1; continue }
            if trimmed.contains("\t") { aligned += 1 }
        }
        return lines > 0 && Double(aligned) / Double(lines) > 0.15
    }

    /// Plain text as rich text: one paragraph per line, no spacing between them.
    static func attributed(_ text: String) -> NSAttributedString {
        var clean = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if clean.hasPrefix("\u{FEFF}") { clean.removeFirst() }
        let mono = looksAligned(clean)
        let style = RichStyle.paragraph(after: 0, lineHeight: mono ? 1.0 : 1.1)
        let font = mono ? RichStyle.mono(size: 10.5) : RichStyle.font()
        if mono { style.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * 8 }   // tab = 8 columns
        return NSAttributedString(string: clean, attributes: [
            .font: font,
            .paragraphStyle: style,
        ])
    }

    static func read(_ url: URL) throws -> NSAttributedString {
        attributed(decode(try Data(contentsOf: url)).text)
    }

    // MARK: Text clippings

    /// Finder clippings (.textClipping): the modern plist form (UTI-Data with RTF, HTML or plain text),
    /// and the classic form whose data lives in resource-fork resources ('RTF ', 'utf8', 'utxt', 'TEXT').
    static func readClipping(_ url: URL) throws -> NSAttributedString {
        let data = (try? Data(contentsOf: url)) ?? Data()
        if !data.isEmpty, let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let uti = plist["UTI-Data"] as? [String: Any] {
            func bytes(_ key: String) -> Data? {
                if let d = uti[key] as? Data { return d }
                if let s = uti[key] as? String { return Data(s.utf8) }
                return nil
            }
            if let d = bytes("com.apple.flat-rtfd"),
               let s = try? NSAttributedString(data: d, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil) {
                return s
            }
            if let d = bytes("public.rtf") { return try RichRTF.read(data: d) }
            if let d = bytes("com.apple.webarchive") {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-\(UUID().uuidString).webarchive")
                defer { try? FileManager.default.removeItem(at: tmp) }
                try d.write(to: tmp)
                if let s = try? OfflineHTML.webArchive(tmp) { return s }
            }
            if let d = bytes("public.html") { return try OfflineHTML.importHTML(OfflineHTML.decode(d), base: nil) }
            if let s = uti["public.utf8-plain-text"] as? String { return attributed(s) }
            if let d = uti["public.utf8-plain-text"] as? Data { return attributed(String(decoding: d, as: UTF8.self)) }
            for key in ["public.utf16-plain-text", "public.utf16-external-plain-text"] {
                // UTF-16 in the Mac's byte order unless a byte-order mark says otherwise.
                if let d = uti[key] as? Data {
                    let bom = d.starts(with: [0xFF, 0xFE]) || d.starts(with: [0xFE, 0xFF])
                    return attributed(bom ? decode(d).text : (String(data: d, encoding: .utf16LittleEndian) ?? decode(d).text))
                }
            }
            if let d = bytes("com.apple.traditional-mac-plain-text") ?? bytes("public.plain-text") {
                return attributed(String(data: d, encoding: .macOSRoman) ?? decode(d).text)
            }
            if let s = uti["public.url"] as? String ?? (uti["public.url"] as? Data).map({ String(decoding: $0, as: UTF8.self) }) {
                let link = NSMutableAttributedString(attributedString: attributed(s))
                if let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    link.addAttribute(.link, value: u, range: NSRange(location: 0, length: link.length))
                }
                return link
            }
        }
        // Classic clipping: the text is in the resource fork.
        let fork = url.appendingPathComponent("..namedfork/rsrc")
        if let rsrc = try? Data(contentsOf: fork), !rsrc.isEmpty {
            let resources = resourceFork(rsrc)
            if let d = resources["RTF "] { return try RichRTF.read(data: d) }
            if let d = resources["utf8"] { return attributed(String(decoding: d, as: UTF8.self)) }
            if let d = resources["utxt"] { return attributed(String(data: d, encoding: .utf16BigEndian) ?? "") }
            if let d = resources["TEXT"] { return attributed(String(data: d, encoding: .macOSRoman) ?? "") }
            if let d = resources["url "] { return attributed(String(decoding: d, as: UTF8.self)) }
        }
        throw ConversionError.unsupported("\(url.lastPathComponent) has no text YummyOrange can read.")
    }

    /// The first resource of each type in a classic Mac resource fork.
    static func resourceFork(_ data: Data) -> [String: Data] {
        let b = [UInt8](data)
        func u32(_ i: Int) -> Int { i + 4 <= b.count ? Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) : -1 }
        func u16(_ i: Int) -> Int { i + 2 <= b.count ? Int(b[i]) << 8 | Int(b[i + 1]) : -1 }
        let dataOffset = u32(0), mapOffset = u32(4)
        guard dataOffset > 0, mapOffset > 0, mapOffset + 28 <= b.count else { return [:] }
        let typeList = mapOffset + u16(mapOffset + 24)
        let typeCount = u16(typeList) + 1
        guard typeCount > 0, typeCount < 500 else { return [:] }
        var out: [String: Data] = [:]
        for t in 0..<typeCount {
            let entry = typeList + 2 + t * 8
            guard entry + 8 <= b.count else { break }
            let type = String(bytes: b[entry..<(entry + 4)], encoding: .macOSRoman) ?? ""
            let refList = typeList + u16(entry + 6)
            guard refList + 12 <= b.count else { continue }
            let resData = dataOffset + (u32(refList + 4) & 0x00FF_FFFF)
            let length = u32(resData)
            guard length >= 0, resData + 4 + length <= b.count else { continue }
            if out[type] == nil { out[type] = Data(b[(resData + 4)..<(resData + 4 + length)]) }
        }
        return out
    }

    // MARK: Writing

    /// Plain text from the document model: list markers and indentation, tables as aligned columns,
    /// quotes with "> ", pictures as [Picture: name], page breaks as form feeds.
    static func text(_ doc: RichDocument) -> String {
        var out: [String] = []
        var previousAfter: CGFloat = 0
        var previousKind = ""
        var previousCode: RichParagraph?
        /// A blank line between blocks with space between them, or of different kinds (lists may follow
        /// their lead-in line directly).
        func gap(before: CGFloat, after: CGFloat, kind: String) {
            let spaced = before > 4 || previousAfter > 4
            let differs = kind != previousKind && kind != "item" && previousKind != "item"
            if !out.isEmpty && out.last != "\u{0C}" && (spaced || differs), out.last != "" { out.append("") }
            previousAfter = after
            previousKind = kind
        }
        func plain(_ runs: [RichRun]) -> String {
            runs.map { r in
                if let img = r.image { return "[Picture: \(img.alt.isEmpty ? img.name : img.alt)]" }
                return r.text.replacingOccurrences(of: "\u{2028}", with: "\n")
            }.joined()
        }
        for block in doc.blocks {
            switch block {
            case .pageBreak:
                out.append("\u{0C}")
                previousKind = "break"
            case .rule:
                gap(before: 8, after: 8, kind: "rule")
                out.append(String(repeating: "─", count: 24))
            case .table(let t):
                gap(before: 8, after: 8, kind: "table")
                out += table(t)
            case .paragraph(let p):
                let quote = String(repeating: "> ", count: p.quoteDepth)
                var text = plain(p.runs)
                if p.headingLevel != nil {
                    gap(before: 8, after: 8, kind: "heading")
                    out += text.components(separatedBy: "\n").map { quote + $0 }
                    continue
                }
                if case .code = p.kind {
                    // Lines of one code block run together; the next block is a new paragraph.
                    let sameBlock = previousKind == "code" && previousCode.map { $0.sameCodeBlock(p) } == true
                    gap(before: sameBlock ? 0 : 8, after: 0, kind: sameBlock ? "code" : "code\(out.count)")
                    previousKind = "code"
                    previousCode = p
                    out += text.components(separatedBy: "\n").map { quote + "    " + $0 }
                    continue
                }
                let depth = p.list.count
                if depth > 0 {
                    let indent = String(repeating: "    ", count: depth - 1)
                    let level = p.list[depth - 1]
                    let marker = p.listContinuation ? "  " : level.marker(p.itemNumber)
                    if let task = p.task { text = (task ? "[x] " : "[ ] ") + text }
                    gap(before: p.spaceBefore, after: p.spaceAfter, kind: "item")
                    let lines = text.components(separatedBy: "\n")
                    let pad = String(repeating: " ", count: marker.count + 1)
                    for (i, l) in lines.enumerated() { out.append(quote + indent + (i == 0 ? marker + " " : pad) + l) }
                    continue
                }
                gap(before: p.spaceBefore, after: p.spaceAfter, kind: "para")
                out += text.components(separatedBy: "\n").map { quote + $0 }
            }
        }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }

    /// Columns padded to their widest cell (East Asian wide characters count double).
    private static func table(_ t: RichTable) -> [String] {
        let cols = t.columns
        guard cols > 0 else { return [] }
        let cells: [[String]] = t.rows.map { row in
            (0..<cols).map { c in
                guard c < row.count, !row[c].covered else { return "" }
                return row[c].paragraphs.map { p in
                    p.runs.map { $0.image != nil ? "[Picture]" : $0.text }.joined().replacingOccurrences(of: "\u{2028}", with: " ")
                }.joined(separator: " ")
            }
        }
        var widths = Array(repeating: 1, count: cols)
        for row in cells { for (c, s) in row.enumerated() { widths[c] = max(widths[c], width(s)) } }
        func line(_ row: [String]) -> String {
            row.enumerated().map { c, s in s + String(repeating: " ", count: widths[c] - width(s)) }
                .joined(separator: "  ").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        var out: [String] = []
        for (r, row) in cells.enumerated() {
            out.append(line(row))
            if r == 0 && t.headerRows > 0 { out.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")) }
        }
        return out
    }

    static func width(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { n, u in
            let v = u.value
            if (0x0300...0x036F).contains(v) || v == 0x200B || v == 0xFE0F { return n }
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v) || (0x20000...0x3FFFD).contains(v)
            return n + (wide ? 2 : 1)
        }
    }
}
