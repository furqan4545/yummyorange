import Foundation

/// SRT and WebVTT subtitles: SRT ↔ VTT, and either one → TXT (just the spoken lines).
/// The parser is forgiving, because subtitle files in the wild rarely follow either spec: it accepts a
/// byte-order mark, UTF-16 or Windows-1252 text, CRLF or CR line ends, missing blank lines between cues,
/// cue numbers glued to the previous cue, VTT headers, NOTE/STYLE/REGION blocks, cue identifiers and
/// settings, VTT times without hours, and comma or period before the milliseconds.
enum Subtitles {
    static var commands: [WheelCommand] {
        [
            command("vtt", "VTT", from: ["srt"], write: vtt),
            command("srt", "SRT", from: ["vtt"], write: srt),
            command("txt", "TXT", from: ["srt", "vtt"], write: plainText),
        ]
    }

    /// A Convert petal that reads subtitles and writes them back out as `id` next to the source.
    private static func command(_ id: String, _ title: String, from sources: Set<String>,
                                write: @escaping ([Cue]) -> String) -> WheelCommand {
        WheelCommand(wheel: .convert, id: id, title: title,
                     applies: { Ext.all($0, in: sources) },
                     run: { files, _, progress in
                         try files.enumerated().map { i, url in
                             let cues = try read(url)
                             let out = outputURL(for: url, ext: id)
                             try write(cues).write(to: out, atomically: true, encoding: .utf8)
                             progress(Double(i + 1) / Double(files.count))
                             return out
                         }
                     })
    }

    /// One subtitle: times in milliseconds, text lines as written (tags included).
    struct Cue: Equatable {
        var id: String?
        var start: Int
        var end: Int
        /// VTT cue settings after the end time ("align:start line:0"); empty for SRT.
        var settings = ""
        var lines: [String] = []
    }

    // MARK: Reading

    /// Reads and parses a subtitle file; throws when nothing in it looks like a cue.
    static func read(_ url: URL) throws -> [Cue] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        guard data.count < 200_000_000 else {
            throw ConversionError.unsupported("\(url.lastPathComponent) is too big to be a subtitle file.")
        }
        let text = decode(data)
        let cues = parse(text, vtt: Ext.of(url) == "vtt")
        guard !cues.isEmpty else {
            throw ConversionError.unsupported("No subtitles found in \(url.lastPathComponent).")
        }
        return cues
    }

    /// Text from bytes: UTF-8 (with or without BOM), UTF-16 (BOM, or guessed from zero bytes), else Windows-1252.
    /// A file that mixes UTF-8 and Windows-1252 (a line added in another editor) is read line by line,
    /// so one stray byte doesn't garble every accented letter in it.
    static func decode(_ data: Data) -> String {
        let b = [UInt8](data.prefix(4))
        var text: String?
        if b.starts(with: [0xEF, 0xBB, 0xBF]) {
            let body = data.dropFirst(3)
            text = String(data: body, encoding: .utf8) ?? decodeMixed([UInt8](body), mostlyUTF8: true)
        } else if b.starts(with: [0xFF, 0xFE]) {
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if b.starts(with: [0xFE, 0xFF]) {
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else if b.count == 4, b[1] == 0, b[3] == 0, b[0] != 0 {
            text = String(data: data, encoding: .utf16LittleEndian)
        } else if b.count == 4, b[0] == 0, b[2] == 0, b[1] != 0 {
            text = String(data: data, encoding: .utf16BigEndian)
        }
        if text == nil { text = String(data: data, encoding: .utf8) }
        var s = text ?? decodeMixed([UInt8](data))
        while s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s
    }

    /// Bytes that aren't valid UTF-8 throughout. Lines that are valid UTF-8 are read as UTF-8, the others as
    /// Windows-1252; in a file that is mostly UTF-8 (more valid multi-byte sequences than stray bytes), only
    /// the stray bytes of a broken line are read as Windows-1252. `mostlyUTF8` overrides the count (a BOM says so).
    static func decodeMixed(_ bytes: [UInt8], mostlyUTF8: Bool? = nil) -> String {
        let utf8Wins: Bool
        if let mostlyUTF8 {
            utf8Wins = mostlyUTF8
        } else {
            var sequences = 0, stray = 0, i = 0
            while i < bytes.count {
                if bytes[i] < 0x80 { i += 1 } else if let n = utf8Length(bytes, at: i) { sequences += 1; i += n } else { stray += 1; i += 1 }
            }
            utf8Wins = sequences > stray
        }
        var out = String.UnicodeScalarView()
        var start = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count, bytes[end] != 0x0A, bytes[end] != 0x0D { end += 1 }
            if end < bytes.count { end += 1 }   // the line end, which is ASCII either way
            let line = bytes[start..<end]
            if let valid = String(bytes: line, encoding: .utf8) {
                out.append(contentsOf: valid.unicodeScalars)
            } else {
                var i = start
                while i < end {
                    if utf8Wins, bytes[i] >= 0x80, let n = utf8Length(bytes, at: i), i + n <= end {
                        out.append(contentsOf: String(decoding: bytes[i..<(i + n)], as: UTF8.self).unicodeScalars)
                        i += n
                    } else {
                        out.append(cp1252(bytes[i]))
                        i += 1
                    }
                }
            }
            start = end
        }
        return String(out)
    }

    /// Length of the well-formed UTF-8 multi-byte sequence starting at `i` (2…4), or nil.
    private static func utf8Length(_ b: [UInt8], at i: Int) -> Int? {
        let n: Int, second: ClosedRange<UInt8>
        switch b[i] {
        case 0xC2...0xDF: n = 2; second = 0x80...0xBF
        case 0xE0: n = 3; second = 0xA0...0xBF
        case 0xE1...0xEC, 0xEE...0xEF: n = 3; second = 0x80...0xBF
        case 0xED: n = 3; second = 0x80...0x9F
        case 0xF0: n = 4; second = 0x90...0xBF
        case 0xF1...0xF3: n = 4; second = 0x80...0xBF
        case 0xF4: n = 4; second = 0x80...0x8F
        default: return nil
        }
        guard i + n <= b.count, second.contains(b[i + 1]) else { return nil }
        for k in 2..<n where !(0x80...0xBF).contains(b[i + k]) { return nil }
        return n
    }

    /// Windows-1252 0x80…0x9F; the five bytes it leaves undefined become U+FFFD instead of failing the file.
    private static let cp1252High: [UInt32] = [
        0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
        0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
    ]

    private static func cp1252(_ byte: UInt8) -> Unicode.Scalar {
        guard (0x80...0x9F).contains(byte) else { return Unicode.Scalar(byte) }   // ASCII and Latin-1 match
        return Unicode.Scalar(cp1252High[Int(byte) - 0x80]) ?? "\u{FFFD}"
    }

    /// Parses SRT or VTT. `vtt` turns on WebVTT's header and NOTE/STYLE/REGION blocks and
    /// lets any line before a timing line be a cue identifier (in SRT only a number can be).
    static func parse(_ text: String, vtt vttHint: Bool) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        let isVTT = vttHint || normalized.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT")

        var cues: [Cue] = []
        var current: Cue?          // the cue whose text is being read
        var pending: [String] = [] // lines after a blank line that aren't in a cue (yet)
        var skippingBlock = false  // inside the VTT header or a NOTE/STYLE/REGION block

        /// Lines that turned out not to start a cue: in broken files they're text that a stray blank
        /// line cut off from the cue before, so they go there. (Junk before the first cue is dropped.)
        func flushPending() {
            if !pending.isEmpty, !cues.isEmpty { cues[cues.count - 1].lines += pending }
            pending.removeAll()
        }
        func closeCurrent() {
            if let c = current { cues.append(c) }
            current = nil
        }

        /// The identifier line before a timing line, taken out of the text it was read into.
        func takeCueID() -> String? {
            var id: String?
            if let last = pending.last {
                if isVTT || isInteger(last) { id = last; pending.removeLast() }
                flushPending()
            } else if var c = current, let last = c.lines.last, isInteger(last),
                      c.lines.count >= 2 || Int(last) == (c.id.flatMap { Int($0) } ?? -9) + 1 {
                // A cue number glued to the previous cue's text: the blank line before it is missing.
                c.lines.removeLast()
                id = last
                current = c
            }
            return id
        }

        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if index == 0, isVTT, line.hasPrefix("WEBVTT") { skippingBlock = true; continue }

            if line.contains(">"), let timing = parseTiming(line) {
                let id = takeCueID()
                closeCurrent()
                skippingBlock = false
                current = Cue(id: id, start: timing.start, end: timing.end, settings: timing.settings)
                continue
            }
            if looksLikeTiming(line) {
                // A timing line that can't be read ("00:00:03 --> soon"): skip that cue, rather than show the
                // timestamp as dialogue or add the cue's text to the one before.
                _ = takeCueID()
                closeCurrent()
                skippingBlock = true
                continue
            }
            if skippingBlock {
                if line.isEmpty { skippingBlock = false }
                continue
            }
            if line.isEmpty {
                closeCurrent()
                flushPending()
                continue
            }
            if current != nil {
                current!.lines.append(line)
                continue
            }
            if isVTT, pending.isEmpty, isBlockStart(line) {
                skippingBlock = true
                continue
            }
            pending.append(line)
        }
        closeCurrent()
        flushPending()
        return cues
    }

    /// A line meant as a timing line, even if it can't be read: a time-like start ("00:00:03:50 -->").
    private static func looksLikeTiming(_ line: String) -> Bool {
        guard let arrow = line.range(of: "-->") else { return false }
        let left = line[..<arrow.lowerBound]
        return left.first?.isASCII == true && left.first?.isNumber == true && left.contains(":")
            && left.allSatisfy { $0.isASCII && ($0.isNumber || ":.,; \t".contains($0)) }
    }

    private static func isInteger(_ s: String) -> Bool {
        !s.isEmpty && s.count < 10 && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func isBlockStart(_ line: String) -> Bool {
        for word in ["NOTE", "STYLE", "REGION"] where line == word || line.hasPrefix(word + " ") || line.hasPrefix(word + "\t") {
            return true
        }
        return false
    }

    /// "00:01:02,500 --> 00:01:04,000 align:start" → times in ms plus the settings. Parsed by hand:
    /// it runs once per cue, and a 50,000-cue file shouldn't wait on regular expressions.
    static func parseTiming(_ line: String) -> (start: Int, end: Int, settings: String)? {
        guard let arrow = line.range(of: "->") else { return nil }
        var left = line[..<arrow.lowerBound]
        if left.hasSuffix("-") { left = left.dropLast() }
        let right = line[arrow.upperBound...].drop { $0 == " " || $0 == "\t" }
        let endToken = right.prefix { !$0.isWhitespace }
        let settings = right.dropFirst(endToken.count)   // starts with whitespace, so "00:02.000x" fails below
        guard let start = milliseconds(left.trimmingCharacters(in: .whitespaces)),
              let end = milliseconds(String(endToken)) else { return nil }
        return (start, end, settings.trimmingCharacters(in: .whitespaces))
    }

    /// "[h:]mm:ss[.,fff]" → milliseconds. Hours are optional (VTT); the fraction may have 1–3 digits.
    static func milliseconds(_ s: String) -> Int? {
        func number(_ part: Substring, maxDigits: Int) -> Int? {
            guard !part.isEmpty, part.count <= maxDigits, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        var main = Substring(s)
        var ms = 0
        var parts: [Substring]
        if let sep = s.lastIndex(where: { $0 == "," || $0 == "." }) {
            main = s[..<sep]
            let frac = s[s.index(after: sep)...]
            guard let f = number(frac, maxDigits: 3) else { return nil }
            ms = f * [100, 10, 1][frac.count - 1]
            parts = main.split(separator: ":", omittingEmptySubsequences: false)
        } else {
            parts = main.split(separator: ":", omittingEmptySubsequences: false)
            // "00:00:03:500": a colon typed for the comma. (Three digits, so not a frame number.)
            if parts.count == 4, parts[3].count == 3, let f = number(parts[3], maxDigits: 3) {
                ms = f
                parts.removeLast()
            }
        }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let h = parts.count == 3 ? number(parts[0], maxDigits: 6) : 0
        guard let h, let m = number(parts[parts.count - 2], maxDigits: 2), let sec = number(parts[parts.count - 1], maxDigits: 2)
        else { return nil }
        return ((h * 60 + m) * 60 + sec) * 1000 + ms
    }

    // MARK: Writing

    /// "01:02:03,004" (SRT, comma) or "01:02:03.004" (VTT, period). VTT output always includes hours.
    static func time(_ ms: Int, separator: Character) -> String {
        let t = max(0, ms)
        return String(format: "%02d:%02d:%02d", t / 3_600_000, t / 60_000 % 60, t / 1000 % 60)
            + String(separator) + String(format: "%03d", t % 1000)
    }

    static func srt(_ cues: [Cue]) -> String {
        var out = ""
        var n = 0
        for cue in cues {
            var text = cue.lines.map(srtLine).filter { !$0.isEmpty }
            guard !text.isEmpty else { continue }
            // SRT has no cue settings; players read {\an8} as "at the top" (vtt() maps it back to line:0).
            if isTopLine(cue.settings) || cue.lines.first?.range(of: #"\{\\an[789]\}"#, options: .regularExpression) != nil {
                text[0] = "{\\an8}" + text[0]
            }
            n += 1
            out += "\(n)\n\(time(cue.start, separator: ",")) --> \(time(cue.end, separator: ","))\n"
            out += text.joined(separator: "\n") + "\n\n"
        }
        return out
    }

    /// Whether VTT cue settings put the cue at the top of the picture: "line:0" (or another small line
    /// number, counted from the top) or a line position under 50%, with or without an alignment (",start").
    static func isTopLine(_ settings: String) -> Bool {
        for token in settings.split(whereSeparator: { $0 == " " || $0 == "\t" }) where token.hasPrefix("line:") {
            let value = token.dropFirst(5).prefix { $0 != "," }
            if value.hasSuffix("%") { return Double(value.dropLast()).map { $0 < 50 } ?? false }
            if let n = Int(value) { return (0...4).contains(n) }
        }
        return false
    }

    static func vtt(_ cues: [Cue]) -> String {
        var out = "WEBVTT\n\n"
        for cue in cues {
            var settings = ""
            // {\an7}…{\an9} put an SRT subtitle at the top of the picture.
            if cue.lines.first?.range(of: #"\{\\an[789]\}"#, options: .regularExpression) != nil { settings = " line:0" }
            let text = cue.lines.map(vttLine).filter { !$0.isEmpty }
            guard !text.isEmpty else { continue }
            if let id = cue.id, !id.contains("-->") { out += id + "\n" }
            out += "\(time(cue.start, separator: ".")) --> \(time(cue.end, separator: "."))\(settings)\n"
            out += text.joined(separator: "\n") + "\n\n"
        }
        return out
    }

    /// Only the spoken lines: no numbers, timings or tags, and a line repeated by the next cue
    /// (as rolling captions do) appears once.
    static func plainText(_ cues: [Cue]) -> String {
        var out: [String] = []
        for cue in cues {
            for line in cue.lines {
                let clean = spoken(line)
                if clean.isEmpty || clean == out.last { continue }
                out.append(clean)
            }
        }
        return out.isEmpty ? "" : out.joined(separator: "\n") + "\n"
    }

    // MARK: Cue text

    /// A piece of cue text: a markup tag or plain text.
    private enum Piece { case tag(String), text(String) }

    /// Splits text into tags ("<i>", "</c>", "<v Bob>", "<00:01.000>") and the text between them.
    /// A "<" that doesn't open a tag ("a < b") stays text.
    private static func pieces(_ line: String) -> [Piece] {
        guard line.contains("<") else { return [.text(line)] }
        var result: [Piece] = []
        var rest = Substring(line)
        while let r = rest.firstMatch(of: #/<(?:/?[A-Za-z][^<>]*|\d[\d:.]*)>/#) {
            if r.range.lowerBound > rest.startIndex { result.append(.text(String(rest[..<r.range.lowerBound]))) }
            result.append(.tag(String(r.output)))
            rest = rest[r.range.upperBound...]
        }
        if !rest.isEmpty { result.append(.text(String(rest))) }
        return result
    }

    /// The tag's name, lower-cased, without "/" or classes: "</c.yellow>" → "c".
    private static func tagName(_ tag: String) -> String {
        var t = tag.dropFirst().dropLast()
        if t.hasPrefix("/") { t = t.dropFirst() }
        let name = t.prefix { $0.isLetter }
        return name.lowercased()
    }

    /// Removes ASS/SSA override blocks ("{\an8}", "{\i1}") and turns their "\N" line breaks into spaces.
    private static func withoutOverrides(_ line: String) -> String {
        guard line.contains("\\") else { return line }
        return line.replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: " ").replacingOccurrences(of: "\\n", with: " ")
    }

    /// Drops ruby annotations (<rt>…</rt>), which are pronunciation hints rather than spoken text.
    private static func withoutRuby(_ line: String) -> String {
        guard line.range(of: "<rt", options: .caseInsensitive) != nil else { return line }
        return line.replacingOccurrences(of: #"<rt(?:\.[^>]*)?>.*?</rt>"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    private static let keptStyles: Set<String> = ["i", "b", "u"]

    /// Normalizes a style tag both formats share ("<i.loud>" → "<i>"), or nil for any other tag.
    private static func keptStyle(_ tag: String) -> String? {
        let name = tagName(tag)
        guard keptStyles.contains(name) else { return nil }
        return tag.hasPrefix("</") ? "</\(name)>" : "<\(name)>"
    }

    /// SRT text: italic, bold and underline survive; other VTT markup goes; entities become characters.
    private static func srtLine(_ line: String) -> String {
        pieces(withoutRuby(withoutOverrides(line))).map { piece -> String in
            switch piece {
            case .tag(let t): return keptStyle(t) ?? ""
            case .text(let s): return decodeEntities(s)
            }
        }.joined().trimmingCharacters(in: .whitespaces)
    }

    /// VTT text: italic, bold and underline survive (SRT's <font> doesn't exist in VTT); & and < are escaped,
    /// and "-->" (not allowed in a cue) is broken up.
    private static func vttLine(_ line: String) -> String {
        pieces(withoutOverrides(line)).map { piece -> String in
            switch piece {
            case .tag(let t): return keptStyle(t) ?? ""
            case .text(let s):
                return decodeEntities(s).replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "-->", with: "--&gt;")
            }
        }.joined().trimmingCharacters(in: .whitespaces)
    }

    /// Plain words: every tag, override and annotation removed, entities decoded, spaces collapsed.
    static func spoken(_ line: String) -> String {
        let text = pieces(withoutRuby(withoutOverrides(line))).map { piece -> String in
            if case .text(let s) = piece { return decodeEntities(s) }
            return ""
        }.joined()
        let collapsed = text.replacingOccurrences(of: "\u{00A0}", with: " ").split(whereSeparator: { $0 == " " || $0 == "\t" })
        return collapsed.joined(separator: " ")
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "lrm": "\u{200E}", "rlm": "\u{200F}",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = Substring(s)
        while let r = rest.firstMatch(of: #/&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,6});/#) {
            out += rest[..<r.range.lowerBound]
            let name = String(r.output.1)
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
            } else {
                replacement = entities[name]
            }
            out += replacement ?? String(r.output.0)
            rest = rest[r.range.upperBound...]
        }
        out += rest
        return out
    }

    // MARK: Self-test

    /// `--selftest subtitles`: tricky inputs, checked cue by cue and line by line.
    static func selfTest() -> String {
        var failures: [String] = []
        var checks = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            checks += 1
            if !ok { failures.append("\(name) \(detail())") }
        }

        // SRT with BOM, CRLF, a missing blank line, tags, a dot before the milliseconds and an ASS override.
        let srtText = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,500\r\n<i>Hello</i> <font color=\"#ff0000\">world</font>\r\n"
            + "2\r\n00:00:03.000 --> 00:00:04,000 X1:100 X2:200\r\n{\\an8}Top line\r\nSecond & last\r\n\r\n\r\n"
            + "3\r\n00:00:05,000 --> 00:00:06,000\r\nSecond & last\r\n"
        let a = parse(decode(Data(srtText.utf8)), vtt: false)
        check("srt count", a.count == 3, "\(a.count)")
        check("srt glued index", a.first?.lines == ["<i>Hello</i> <font color=\"#ff0000\">world</font>"], "\(a.first?.lines ?? [])")
        check("srt times", a.count == 3 && a[1].start == 3000 && a[1].end == 4000 && a[0].end == 2500)
        let asVTT = vtt(a)
        check("srt→vtt", asVTT == "WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.500\n<i>Hello</i> world\n\n"
              + "2\n00:00:03.000 --> 00:00:04.000 line:0\nTop line\nSecond &amp; last\n\n"
              + "3\n00:00:05.000 --> 00:00:06.000\nSecond &amp; last\n\n", asVTT)
        check("srt→txt", plainText(a) == "Hello world\nTop line\nSecond & last\n", plainText(a))

        // VTT with header metadata, STYLE, REGION, NOTE, identifiers, settings, no hours, voice/class/ruby/timestamp tags.
        let vttText = "WEBVTT - Example\nKind: captions\nLanguage: en\n\nSTYLE\n::cue { color: yellow }\n\n"
            + "REGION\nid:fred width:40%\n\nNOTE This is a comment\nspanning two lines\n\n"
            + "intro\n00:01.000 --> 00:02.000 align:start position:10%\n<v Bob>Hi &amp; welcome</v>\n\n"
            + "00:02.000 --> 00:04.000\n<c.yellow>Rolling</c> <00:00:02.500>line\nNext &lt;one&gt;\n\n"
            + "NOTE\nanother note\n\n"
            + "1:00:00.5 --> 1:00:01.25\n<ruby>漢<rt>kan</rt></ruby>字 <i.loud>loud</i>\n"
        let b = parse(vttText, vtt: true)
        check("vtt count", b.count == 3, "\(b.count) \(b)")
        check("vtt id", b.first?.id == "intro" && b.first?.settings == "align:start position:10%")
        check("vtt hours optional", b.count == 3 && b[2].start == 3_600_500 && b[2].end == 3_601_250, "\(b.last.map { "\($0.start) \($0.end)" } ?? "")")
        let asSRT = srt(b)
        check("vtt→srt", asSRT == "1\n00:00:01,000 --> 00:00:02,000\nHi & welcome\n\n"
              + "2\n00:00:02,000 --> 00:00:04,000\nRolling line\nNext <one>\n\n"
              + "3\n01:00:00,500 --> 01:00:01,250\n漢字 <i>loud</i>\n\n", asSRT)
        check("vtt→txt", plainText(b) == "Hi & welcome\nRolling line\nNext <one>\n漢字 loud\n", plainText(b))

        // Rolling captions repeat the previous line; TXT keeps one copy. A stray blank line inside a cue.
        let rolling = "1\n00:00:00,000 --> 00:00:01,000\nfirst line\n\n2\n00:00:01,000 --> 00:00:02,000\nfirst line\nsecond line\n\n"
            + "3\n00:00:02,000 --> 00:00:03,000\nsecond line\n\nstray continuation\n\n4\n00:00:03,000 --> 00:00:04,000\nend\n"
        let c = parse(rolling, vtt: false)
        check("rolling count", c.count == 4, "\(c.count)")
        check("stray text joins its cue", c.count == 4 && c[2].lines == ["second line", "stray continuation"], "\(c)")
        check("rolling txt", plainText(c) == "first line\nsecond line\nstray continuation\nend\n", plainText(c))

        // UTF-16 LE with BOM, CR-only line ends, Windows-1252 bytes.
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("1\r00:00:01,000 --> 00:00:02,000\rCafé\r".data(using: .utf16LittleEndian)!)
        check("utf16", plainText(parse(decode(utf16), vtt: false)) == "Café\n", plainText(parse(decode(utf16), vtt: false)))
        let cp1252 = Data("1\n00:00:01,000 --> 00:00:02,000\n".utf8) + Data([0x43, 0x61, 0x66, 0xE9, 0x20, 0x93, 0x71, 0x94, 0x0A])
        check("cp1252", plainText(parse(decode(cp1252), vtt: false)) == "Café \u{201C}q\u{201D}\n", plainText(parse(decode(cp1252), vtt: false)))

        // UTF-8 with one Windows-1252 byte appended; Windows-1252 with a byte it leaves undefined.
        let cue = "1\n00:00:01,000 --> 00:00:02,000\nCafé crème brûlée\n\n2\n00:00:03,000 --> 00:00:04,000\nÇa coûte 10 €\n\n"
            + "3\n00:00:05,000 --> 00:00:06,000\nfin"
        let mixed = plainText(parse(decode(Data(cue.utf8) + Data([0x85, 0x0A])), vtt: false))
        check("utf8 + stray cp1252", mixed == "Café crème brûlée\nÇa coûte 10 €\nfin…\n", mixed)
        let fourth = "\n\n4\n00:00:07,000 --> 00:00:08,000\n"
        let mixedLine = plainText(parse(decode(Data((cue + fourth + "Café ").utf8) + Data([0x93, 0x71, 0x94, 0x0A])), vtt: false))
        check("utf8 + cp1252 on one line", mixedLine == "Café crème brûlée\nÇa coûte 10 €\nfin\nCafé \u{201C}q\u{201D}\n", mixedLine)
        let utf8Added = plainText(parse(decode(cue.data(using: .windowsCP1252)! + Data((fourth + "Naïve").utf8)), vtt: false))
        check("cp1252 + utf8 line", utf8Added == "Café crème brûlée\nÇa coûte 10 €\nfin\nNaïve\n", utf8Added)
        let undefined = plainText(parse(decode(cue.data(using: .windowsCP1252)! + Data([0x81, 0x0A])), vtt: false))
        check("cp1252 + undefined byte", undefined == "Café crème brûlée\nÇa coûte 10 €\nfin\u{FFFD}\n", undefined)
        let bom = plainText(parse(decode(Data([0xEF, 0xBB, 0xBF]) + Data(cue.utf8) + Data([0xE9, 0x0A])), vtt: false))
        check("bom + stray byte", bom == "Café crème brûlée\nÇa coûte 10 €\nfiné\n", bom)

        // A timing line with a colon before the milliseconds is read; one that can't be read drops its cue,
        // and neither ever shows up as text.
        let typo = parse("1\n00:00:01,000 --> 00:00:02,000\nFirst line\n\n2\n00:00:03:500 --> 00:00:04:500\nSecond line\n\n"
                         + "3\n00:00:05,000 --> soon\nLost line\n\n4\n00:00:07,000 --> 00:00:08,000\nFourth line\n", vtt: false)
        check("colon ms", typo.count == 3 && typo[1].start == 3500 && typo[1].end == 4500 && typo[1].lines == ["Second line"], "\(typo)")
        check("bad timing skipped", plainText(typo) == "First line\nSecond line\nFourth line\n", plainText(typo))
        check("text arrow kept", parse("1\n00:00:01,000 --> 00:00:02,000\nA --> B\n", vtt: false).first?.lines == ["A --> B"])

        // Top placement survives SRT → VTT → SRT.
        let top = parse(vtt(parse("1\n00:00:01,000 --> 00:00:02,000\n{\\an8}Speaker at top\n", vtt: false)), vtt: true)
        check("top → srt", srt(top) == "1\n00:00:01,000 --> 00:00:02,000\n{\\an8}Speaker at top\n\n", srt(top))
        check("top settings", isTopLine("line:0") && isTopLine("align:start line:10%,start") && !isTopLine("line:-1")
              && !isTopLine("line:90%") && !isTopLine("position:10%"))

        // Not subtitles at all, and an empty file.
        check("garbage", parse("just some text\nno timings here\n", vtt: false).isEmpty)
        check("empty", parse("", vtt: true).isEmpty && parse("WEBVTT\n\n", vtt: true).isEmpty)
        check("bad timing", parseTiming("00:00:01,000 --> soon") == nil && parseTiming("00:01.000 -->00:02.000x") == nil)

        return failures.isEmpty ? "OK subtitles: \(checks) checks" : "FAIL subtitles:\n" + failures.joined(separator: "\n")
    }
}
