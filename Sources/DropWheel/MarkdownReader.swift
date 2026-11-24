import AppKit

/// A Markdown reader: CommonMark blocks and inlines plus the GitHub extensions people use (tables,
/// task lists, strikethrough, bare-URL autolinks), turned into styled rich text. Pictures load from
/// local files and data: URLs only; remote pictures become links, because nothing is fetched.
enum MarkdownReader {
    /// `baseURL` is the Markdown file, for resolving relative picture paths.
    static func read(_ source: String, baseURL: URL?) -> NSAttributedString {
        var parser = MDBlockParser()
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map(MDBlockParser.expandLeadingTabs)
        if lines.first?.hasPrefix("\u{FEFF}") == true { lines[0].removeFirst() }
        let title = MDBlockParser.stripFrontMatter(&lines)
        let blocks = parser.parse(lines[...])
        let renderer = MDRenderer(refs: parser.refs, baseURL: baseURL)
        let out = renderer.render(blocks)
        if let title, out.length == 0 { out.append(NSAttributedString(string: title)) }
        return out
    }

    /// The title from YAML front matter or the first heading, for document properties.
    static func title(of source: String) -> String? {
        for line in source.split(separator: "\n", omittingEmptySubsequences: true).prefix(80) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("title:") { return t.dropFirst(6).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            if t.hasPrefix("# ") { return String(t.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: " #")) }
        }
        return nil
    }
}

// MARK: - Blocks

/// A Markdown block; inline text stays raw until reference links are all known.
indirect enum MDBlock {
    case heading(Int, String)
    case paragraph(String)
    case code(String, String)          // text, info string
    case quote([MDBlock])
    case list(ordered: Bool, start: Int, tight: Bool, items: [MDItem])
    case table(header: [String], align: [NSTextAlignment], rows: [[String]])
    case rule
    case html(String)
}

/// A list item: task state and its own blocks.
struct MDItem {
    var task: Bool?
    var blocks: [MDBlock]
}

/// Line-based block parser. Containers (quotes, list items) collect their lines, strip their markers and
/// parse the result recursively, which covers nesting the way people write it.
struct MDBlockParser {
    var refs: [String: (url: String, title: String)] = [:]

    static func expandLeadingTabs(_ line: String) -> String {
        guard line.first == "\t" || (line.first == " " && line.contains("\t")) else { return line }
        var out = "", col = 0
        var rest = Substring(line)
        while let c = rest.first, c == " " || c == "\t" {
            if c == "\t" { let n = 4 - col % 4; out += String(repeating: " ", count: n); col += n } else { out += " "; col += 1 }
            rest = rest.dropFirst()
        }
        return out + rest
    }

    /// Removes YAML front matter (--- … --- at the very top) and returns its title, if any.
    static func stripFrontMatter(_ lines: inout [String]) -> String? {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let end = lines.dropFirst().prefix(300).firstIndex(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) }),
              end > 1 else { return nil }
        let body = lines[1..<end]
        // Only real front matter: every non-blank line is "key: value", a list entry or a comment.
        guard body.allSatisfy({ l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || t.hasPrefix("#") || t.hasPrefix("- ") || l.hasPrefix(" ") || t.range(of: "^[A-Za-z0-9_-]+:", options: .regularExpression) != nil
        }) else { return nil }
        let title = body.first { $0.hasPrefix("title:") }.map {
            $0.dropFirst(6).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        lines.removeSubrange(0...end)
        return title
    }

    static func isBlank(_ s: String) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }

    static func indent(_ s: String) -> Int { s.prefix { $0 == " " }.count }

    static func dropIndent(_ s: String, _ n: Int) -> String {
        let k = min(n, indent(s))
        return String(s.dropFirst(k))
    }

    /// (fence character, length, indent, info string)
    static func fenceOpen(_ s: String) -> (Character, Int, Int, String)? {
        let ind = indent(s)
        guard ind <= 3 else { return nil }
        let rest = s.dropFirst(ind)
        guard let c = rest.first, c == "`" || c == "~" else { return nil }
        let n = rest.prefix { $0 == c }.count
        guard n >= 3 else { return nil }
        let info = rest.dropFirst(n).trimmingCharacters(in: .whitespaces)
        if c == "`" && info.contains("`") { return nil }
        return (c, n, ind, info)
    }

    static func isFenceClose(_ s: String, _ c: Character, _ n: Int) -> Bool {
        let ind = indent(s)
        guard ind <= 3 else { return false }
        let rest = s.dropFirst(ind)
        let k = rest.prefix { $0 == c }.count
        return k >= n && rest.dropFirst(k).allSatisfy { $0 == " " || $0 == "\t" }
    }

    static func atxHeading(_ s: String) -> (Int, String)? {
        let ind = indent(s)
        guard ind <= 3 else { return nil }
        let rest = s.dropFirst(ind)
        let n = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(n) else { return nil }
        let after = rest.dropFirst(n)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // Optional closing #s (preceded by a space, or the whole text).
        if let r = text.range(of: "(^|\\s)#+\\s*$", options: .regularExpression) { text = String(text[..<r.lowerBound]) }
        return (n, text.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ s: String) -> Bool {
        guard indent(s) <= 3 else { return false }
        let chars = s.filter { $0 != " " && $0 != "\t" }
        guard chars.count >= 3, let c = chars.first, "*-_".contains(c) else { return false }
        return chars.allSatisfy { $0 == c }
    }

    static func quoteContent(_ s: String) -> String? {
        let ind = indent(s)
        guard ind <= 3, s.dropFirst(ind).first == ">" else { return nil }
        var rest = s.dropFirst(ind + 1)
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    /// A list item marker and where the item's content starts.
    struct Marker {
        var ordered: Bool
        var char: Character      // bullet character, or the ordered delimiter
        var start: Int
        var contentIndent: Int
        var content: String
        var task: Bool?
    }

    static func listMarker(_ s: String) -> Marker? {
        let ind = indent(s)
        guard ind <= 3 else { return nil }
        let rest = Array(s.dropFirst(ind))
        guard let first = rest.first else { return nil }
        var width = 0, ordered = false, char: Character = first, start = 1
        if "-+*".contains(first) {
            width = 1
        } else if first.isASCII, first.isNumber {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard digits.count <= 9, digits.count < rest.count, ".)".contains(rest[digits.count]) else { return nil }
            ordered = true
            char = rest[digits.count]
            start = Int(String(digits)) ?? 1
            width = digits.count + 1
        } else { return nil }
        let after = rest.dropFirst(width)
        if !after.isEmpty && after.first != " " { return nil }
        let spaces = after.prefix { $0 == " " }.count
        var content = String(after.dropFirst(spaces))
        let contentIndent: Int
        if content.isEmpty { contentIndent = ind + width + 1 }
        else if spaces > 4 { contentIndent = ind + width + 1; content = String(repeating: " ", count: spaces - 1) + content }
        else { contentIndent = ind + width + spaces }
        var task: Bool?
        if let r = content.range(of: "^\\[[ xX]\\](\\s|$)", options: .regularExpression) {
            task = content[content.index(after: content.startIndex)] != " "
            content = String(content[r.upperBound...])
        }
        return Marker(ordered: ordered, char: char, start: start, contentIndent: contentIndent, content: content, task: task)
    }

    static func splitRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s.removeLast() }
        var cells: [String] = [], cur = "", escaped = false
        for c in s {
            if escaped { if c != "|" { cur.append("\\") }; cur.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "|" { cells.append(cur); cur = ""; continue }
            cur.append(c)
        }
        if escaped { cur.append("\\") }
        cells.append(cur)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func delimiterRow(_ line: String) -> [NSTextAlignment]? {
        guard line.contains("-"), line.allSatisfy({ "|:- \t".contains($0) }) else { return nil }
        let cells = splitRow(line)
        var out: [NSTextAlignment] = []
        for c in cells {
            guard !c.isEmpty, c.range(of: "^:?-+:?$", options: .regularExpression) != nil else { return nil }
            out.append(c.hasPrefix(":") && c.hasSuffix(":") ? .center : c.hasSuffix(":") ? .right : c.hasPrefix(":") ? .left : .natural)
        }
        return out
    }

    static func tableStarts(_ lines: ArraySlice<String>, _ i: Int) -> [NSTextAlignment]? {
        guard i + 1 < lines.endIndex, lines[i].contains("|"), indent(lines[i]) <= 3,
              let align = delimiterRow(lines[i + 1]), splitRow(lines[i]).count == align.count else { return nil }
        return align
    }

    static let htmlBlockTags: Set<String> = ["address", "article", "aside", "blockquote", "body", "center", "details",
        "dialog", "dd", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4",
        "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "main", "menu", "nav", "ol", "p",
        "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "title", "tr", "ul", "script", "style",
        "pre", "picture", "img", "br", "a", "video", "audio", "kbd", "sup", "sub", "span", "b", "i", "strong", "em"]

    static func htmlBlockStart(_ s: String) -> Bool {
        guard indent(s) <= 3 else { return false }
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("<!--") { return true }
        guard let m = t.range(of: "^</?([A-Za-z][A-Za-z0-9]*)(\\s|/?>|$)", options: .regularExpression) else { return false }
        let name = t[m].trimmingCharacters(in: CharacterSet(charactersIn: "</> \t")).lowercased()
        // Inline-level tags only start a block when the line is nothing but HTML.
        let inlineOnly: Set<String> = ["img", "br", "a", "kbd", "sup", "sub", "span", "b", "i", "strong", "em"]
        if inlineOnly.contains(name) { return t.hasSuffix(">") && !t.contains("](") }
        return htmlBlockTags.contains(name)
    }

    func startsBlock(_ s: String, interruptingParagraph: Bool) -> Bool {
        if MDBlockParser.atxHeading(s) != nil || MDBlockParser.fenceOpen(s) != nil || MDBlockParser.isRule(s)
            || MDBlockParser.quoteContent(s) != nil { return true }
        if let m = MDBlockParser.listMarker(s) {
            // A list can interrupt a paragraph only with content, and a numbered one only from 1.
            if !interruptingParagraph { return true }
            return !m.content.trimmingCharacters(in: .whitespaces).isEmpty && (!m.ordered || m.start == 1)
        }
        if MDBlockParser.htmlBlockStart(s) && !interruptingParagraph { return true }
        return false
    }

    mutating func linkDefinition(_ s: String) -> Bool {
        let pattern = "^ {0,3}\\[([^\\]]+)\\]:\\s*(<[^>]*>|\\S+)(?:\\s+(\"[^\"]*\"|'[^']*'|\\([^)]*\\)))?\\s*$"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return false }
        let ns = s as NSString
        let label = MDBlockParser.normalizeLabel(ns.substring(with: m.range(at: 1)))
        var url = ns.substring(with: m.range(at: 2))
        if url.hasPrefix("<") { url = String(url.dropFirst().dropLast()) }
        var title = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : ""
        if title.count >= 2 { title = String(title.dropFirst().dropLast()) }
        if refs[label] == nil { refs[label] = (url, title) }
        return true
    }

    static func normalizeLabel(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
    }

    /// `depth`: how many quotes and list items enclose these lines. Past RichLimits.blockDepth the rest is
    /// one paragraph (its markers stay as text), so hostile nesting can't exhaust the stack.
    mutating func parse(_ lines: ArraySlice<String>, depth: Int = 0) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var i = lines.startIndex
        let end = lines.endIndex
        var tableCloses: [Int]?
        if depth >= RichLimits.blockDepth {
            let text = lines.filter { !MDBlockParser.isBlank($0) }.map { String($0.drop { $0 == " " }) }.joined(separator: "\n")
            return text.isEmpty ? [] : [.paragraph(text)]
        }
        while i < end {
            let line = lines[i]
            if MDBlockParser.isBlank(line) { i += 1; continue }

            if MDBlockParser.indent(line) >= 4 {
                var code: [String] = []
                while i < end, MDBlockParser.isBlank(lines[i]) || MDBlockParser.indent(lines[i]) >= 4 {
                    code.append(MDBlockParser.dropIndent(lines[i], 4)); i += 1
                }
                while let last = code.last, MDBlockParser.isBlank(last) { code.removeLast() }
                blocks.append(.code(code.joined(separator: "\n"), ""))
                continue
            }
            if let (c, n, ind, info) = MDBlockParser.fenceOpen(line) {
                var code: [String] = []
                i += 1
                while i < end, !MDBlockParser.isFenceClose(lines[i], c, n) { code.append(MDBlockParser.dropIndent(lines[i], ind)); i += 1 }
                if i < end { i += 1 }
                blocks.append(.code(code.joined(separator: "\n"), String(info.split(separator: " ").first ?? "")))
                continue
            }
            if let (level, text) = MDBlockParser.atxHeading(line) { blocks.append(.heading(level, text)); i += 1; continue }
            if MDBlockParser.isRule(line) { blocks.append(.rule); i += 1; continue }
            if MDBlockParser.quoteContent(line) != nil {
                var inner: [String] = []
                while i < end {
                    if let c = MDBlockParser.quoteContent(lines[i]) { inner.append(c); i += 1; continue }
                    // Lazy continuation of a paragraph inside the quote.
                    if !MDBlockParser.isBlank(lines[i]), let last = inner.last, !MDBlockParser.isBlank(last),
                       MDBlockParser.fenceOpen(last) == nil, !startsBlock(lines[i], interruptingParagraph: true) {
                        inner.append(lines[i]); i += 1; continue
                    }
                    break
                }
                blocks.append(.quote(parse(inner[...], depth: depth + 1)))
                continue
            }
            if let first = MDBlockParser.listMarker(line) {
                blocks.append(parseList(lines, &i, first, depth: depth))
                continue
            }
            if let align = MDBlockParser.tableStarts(lines, i) {
                let header = MDBlockParser.splitRow(line)
                var rows: [[String]] = []
                i += 2
                while i < end, !MDBlockParser.isBlank(lines[i]), !startsBlock(lines[i], interruptingParagraph: false) {
                    var cells = MDBlockParser.splitRow(lines[i])
                    if cells.count < align.count { cells += Array(repeating: "", count: align.count - cells.count) }
                    rows.append(Array(cells.prefix(align.count)))
                    i += 1
                }
                blocks.append(.table(header: header, align: align, rows: rows))
                continue
            }
            if MDBlockParser.htmlBlockStart(line) {
                var html: [String] = []
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let comment = trimmed.hasPrefix("<!--")
                // A table (README layouts) keeps going through blank lines until it closes.
                var openTable = false
                if trimmed.range(of: "^<table\\b", options: [.regularExpression, .caseInsensitive]) != nil {
                    // Lines that close a table, found once per parse (binary-searched after that).
                    if tableCloses == nil { tableCloses = lines.indices.filter { lines[$0].range(of: "</table", options: .caseInsensitive) != nil } }
                    let closes = tableCloses!
                    var lo = 0, hi = closes.count
                    while lo < hi { let mid = (lo + hi) / 2; if closes[mid] < i { lo = mid + 1 } else { hi = mid } }
                    openTable = lo < closes.count && closes[lo] < i + 1000
                }
                while i < end {
                    if !comment && !openTable && MDBlockParser.isBlank(lines[i]) { break }
                    html.append(lines[i]); i += 1
                    if comment && html.last!.contains("-->") { break }
                    if openTable, html.last!.range(of: "</table\\s*>", options: [.regularExpression, .caseInsensitive]) != nil { openTable = false }
                }
                blocks.append(.html(html.joined(separator: "\n")))
                continue
            }
            if linkDefinition(line) { i += 1; continue }

            // Paragraph, possibly a setext heading.
            var para = [String(line.drop { $0 == " " })]
            var setext = 0
            i += 1
            while i < end {
                let l = lines[i]
                if MDBlockParser.isBlank(l) { break }
                let t = l.trimmingCharacters(in: .whitespaces)
                if MDBlockParser.indent(l) <= 3, !t.isEmpty, t.allSatisfy({ $0 == "=" }) { setext = 1; i += 1; break }
                if MDBlockParser.indent(l) <= 3, !t.isEmpty, t.allSatisfy({ $0 == "-" }) { setext = 2; i += 1; break }
                if startsBlock(l, interruptingParagraph: true) || MDBlockParser.tableStarts(lines, i) != nil { break }
                // Keep trailing spaces: two of them mean a hard line break.
                para.append(String(l.drop { $0 == " " }))
                i += 1
            }
            let text = para.joined(separator: "\n")
            blocks.append(setext > 0 ? .heading(setext, text.trimmingCharacters(in: .whitespaces)) : .paragraph(text))
        }
        return blocks
    }

    private mutating func parseList(_ lines: ArraySlice<String>, _ i: inout Int, _ first: Marker, depth: Int) -> MDBlock {
        var items: [MDItem] = []
        var loose = false
        let end = lines.endIndex
        while i < end, let m = MDBlockParser.listMarker(lines[i]), m.ordered == first.ordered, m.char == first.char,
              !MDBlockParser.isRule(lines[i]) {
            var itemLines = [m.content]
            i += 1
            var sawBlank = false
            var inFence = MDBlockParser.fenceOpen(m.content) != nil
            var internalBlank = false
            while i < end {
                let l = lines[i]
                if MDBlockParser.isBlank(l) { itemLines.append(""); sawBlank = true; i += 1; continue }
                if MDBlockParser.indent(l) >= m.contentIndent {
                    let content = MDBlockParser.dropIndent(l, m.contentIndent)
                    if sawBlank && !inFence { internalBlank = true }
                    if MDBlockParser.fenceOpen(content) != nil { inFence.toggle() }
                    itemLines.append(content); sawBlank = false; i += 1; continue
                }
                if sawBlank { break }
                // The next item (or any other list marker) ends this one.
                if MDBlockParser.listMarker(l) != nil { break }
                // Lazy continuation: unindented text that carries on the item's paragraph.
                if !startsBlock(l, interruptingParagraph: true), let last = itemLines.last, !MDBlockParser.isBlank(last),
                   !inFence, MDBlockParser.tableStarts(lines, i) == nil {
                    itemLines.append(l.trimmingCharacters(in: .whitespaces)); i += 1; continue
                }
                break
            }
            var trailing = 0
            while let last = itemLines.last, MDBlockParser.isBlank(last), itemLines.count > 1 { itemLines.removeLast(); trailing += 1 }
            if internalBlank { loose = true }
            if trailing > 0, i < end, let next = MDBlockParser.listMarker(lines[i]), next.ordered == first.ordered, next.char == first.char {
                loose = true
            }
            items.append(MDItem(task: m.task, blocks: parse(itemLines[...], depth: depth + 1)))
            if sawBlank && (i >= end || MDBlockParser.listMarker(lines[i]) == nil) { break }
        }
        return .list(ordered: first.ordered, start: first.start, tight: !loose, items: items)
    }
}

// MARK: - Inlines

/// One inline element. Delimiter runs (`*`, `_`, `~`) live in the list until emphasis is matched.
final class MDInline {
    /// Kinds of inline element.
    enum Kind { case text, code, softBreak, hardBreak, emph, strong, strike, link, image, html, delim }
    var kind: Kind
    var text: String
    var children: [MDInline] = []
    var url = ""
    var title = ""
    var delim: Character = "*"
    var count = 0
    var origCount = 0
    var canOpen = false
    var canClose = false
    /// Nesting below and including this node (1 for a leaf); kept at most RichLimits.inlineDepth.
    var depth = 1

    init(_ kind: Kind, _ text: String = "") { self.kind = kind; self.text = text }

    /// A container (emphasis, link, picture) around `children`. Nesting deeper than RichLimits.inlineDepth
    /// keeps the text and drops the inner formatting, so walking the tree can't exhaust the stack.
    static func wrap(_ kind: Kind, _ children: [MDInline]) -> MDInline {
        let node = MDInline(kind)
        for c in children where c.kind == .delim { c.kind = .text; c.text = String(repeating: String(c.delim), count: c.count) }
        let d = (children.map(\.depth).max() ?? 0) + 1
        if d > RichLimits.inlineDepth {
            node.children = [MDInline(.text, children.map(\.plainText).joined())]
            node.depth = 2
        } else {
            node.children = children
            node.depth = d
        }
        return node
    }

    var plainText: String {
        switch kind {
        case .text, .code: return text
        case .softBreak, .hardBreak: return " "
        case .image: return children.map(\.plainText).joined()
        case .delim: return String(repeating: String(delim), count: count)
        case .html: return ""
        default: return children.map(\.plainText).joined()
        }
    }
}

/// Parses inline Markdown: code spans, emphasis, links, autolinks, entities and inline HTML. Every scan that
/// could run to the end of the text remembers where it failed, so the work stays close to linear.
struct MDInlineParser {
    let refs: [String: (url: String, title: String)]

    static func isPunct(_ c: Character) -> Bool {
        c.isPunctuation || c.isSymbol
    }

    static let asciiPunct = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    /// Results of forward scans, reused by later scans that start inside the same stretch.
    private struct Memo {
        /// Backtick run length → the position from which no closing run of that length exists.
        var noCodeCloser: [Int: Int] = [:]
        /// `<destination>`: from `from`, the first unescaped '>' or newline is at `stop`.
        var angle = (from: Int.max, stop: 0)
        /// Title delimiter → (from, index of the first unescaped closer at or after it, or n).
        var title: [Character: (from: Int, stop: Int)] = [:]
        /// From this position on, no "-->" closes a comment.
        var noCommentClose = Int.max
        /// next[i]: the first '<' or '>' at or after i (built on first use).
        var nextAngle: [Int32]?
    }

    func parse(_ source: String) -> [MDInline] {
        let c = Array(source)
        let n = c.count
        var nodes: [MDInline] = []
        var brackets: [(index: Int, image: Bool, active: Bool, src: Int)] = []
        var memo = Memo()
        var buf = ""
        func flush() { if !buf.isEmpty { nodes.append(MDInline(.text, buf)); buf = "" } }
        var i = 0
        while i < n {
            let ch = c[i]
            switch ch {
            case "\\":
                if i + 1 < n, c[i + 1] == "\n" {
                    flush(); nodes.append(MDInline(.hardBreak)); i += 2
                } else if i + 1 < n, MDInlineParser.asciiPunct.contains(c[i + 1]) {
                    buf.append(c[i + 1]); i += 2
                } else { buf.append("\\"); i += 1 }
            case "`":
                var k = 0
                while i + k < n, c[i + k] == "`" { k += 1 }
                var j = i + k, found = -1
                if let none = memo.noCodeCloser[k], i >= none { j = n }
                while j < n {
                    if c[j] == "`" {
                        var m = 0
                        while j + m < n, c[j + m] == "`" { m += 1 }
                        if m == k { found = j; break }
                        j += m
                    } else { j += 1 }
                }
                if found >= 0 {
                    var code = String(c[(i + k)..<found]).replacingOccurrences(of: "\n", with: " ")
                    if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" "), !code.allSatisfy({ $0 == " " }) {
                        code = String(code.dropFirst().dropLast())
                    }
                    flush(); nodes.append(MDInline(.code, code)); i = found + k
                } else {
                    memo.noCodeCloser[k] = min(memo.noCodeCloser[k] ?? i, i)
                    buf += String(repeating: "`", count: k); i += k
                }
            case "*", "_", "~":
                var k = 0
                while i + k < n, c[i + k] == ch { k += 1 }
                if ch == "~" && k > 2 { buf += String(repeating: "~", count: k); i += k; break }
                let before: Character = i > 0 ? c[i - 1] : " "
                let after: Character = i + k < n ? c[i + k] : " "
                let bw = before.isWhitespace, aw = after.isWhitespace
                let bp = MDInlineParser.isPunct(before), ap = MDInlineParser.isPunct(after)
                let left = !aw && (!ap || bw || bp)
                let right = !bw && (!bp || aw || ap)
                let d = MDInline(.delim)
                d.delim = ch; d.count = k; d.origCount = k
                if ch == "_" {
                    d.canOpen = left && (!right || bp)
                    d.canClose = right && (!left || ap)
                } else {
                    d.canOpen = left; d.canClose = right
                }
                flush(); nodes.append(d); i += k
            case "!" where i + 1 < n && c[i + 1] == "[":
                flush(); nodes.append(MDInline(.text, "![")); brackets.append((nodes.count - 1, true, true, i + 2)); i += 2
            case "[":
                flush(); nodes.append(MDInline(.text, "[")); brackets.append((nodes.count - 1, false, true, i + 1)); i += 1
            case "]":
                guard let b = brackets.popLast() else { buf.append("]"); i += 1; break }
                flush()
                if !b.active { nodes.append(MDInline(.text, "]")); i += 1; break }
                var dest: (url: String, title: String, end: Int)? = inlineLink(c, i + 1, &memo)
                if dest == nil, !refs.isEmpty {
                    // Reference link: [text][label], [text][] or [text]. Labels are at most 999 characters
                    // (CommonMark), which also keeps this from copying the text inside every bracket.
                    var label: String? = i - b.src <= 999 ? String(c[b.src..<i]) : nil
                    var endIndex = i + 1
                    if i + 1 < n, c[i + 1] == "[" {
                        var j = i + 2, close = -1
                        while j < n, j - (i + 2) <= 1000, c[j] != "[" { if c[j] == "]" { close = j; break }; j += 1 }
                        if close >= 0 {
                            let inner = String(c[(i + 2)..<close])
                            if !inner.isEmpty { label = inner }
                            endIndex = close + 1
                        }
                    }
                    if let label, let ref = refs[MDBlockParser.normalizeLabel(label)] { dest = (ref.url, ref.title, endIndex) }
                }
                guard let d = dest else { nodes.append(MDInline(.text, "]")); i += 1; break }
                var kids = Array(nodes[(b.index + 1)...])
                nodes.removeSubrange(b.index...)
                MDInlineParser.processEmphasis(&kids)
                let link = MDInline.wrap(b.image ? .image : .link, kids)
                link.url = d.url; link.title = d.title
                nodes.append(link)
                if !b.image {
                    // Links can't contain links: earlier [ brackets stop counting (those below an inactive
                    // one already were, so the walk ends there).
                    var k = brackets.count - 1
                    while k >= 0 {
                        if !brackets[k].image {
                            if !brackets[k].active { break }
                            brackets[k].active = false
                        }
                        k -= 1
                    }
                }
                i = d.end
            case "<":
                if i + 3 < n, c[i + 1] == "!", c[i + 2] == "-", c[i + 3] == "-" {
                    // <!-- comment -->: dropped. Without a closer it's text.
                    var close = -1
                    if i < memo.noCommentClose {
                        var j = i + 4
                        while j + 2 < n { if c[j] == "-", c[j + 1] == "-", c[j + 2] == ">" { close = j; break }; j += 1 }
                        if close < 0 { memo.noCommentClose = i }
                    }
                    if close >= 0 { flush(); i = close + 3; break }
                    buf.append("<"); i += 1; break
                }
                // A tag or autolink ends at the first '>' and holds no other '<'.
                if memo.nextAngle == nil {
                    var next = [Int32](repeating: Int32(n), count: n + 1)
                    var k = n - 1
                    while k >= 0 { next[k] = (c[k] == "<" || c[k] == ">") ? Int32(k) : next[k + 1]; k -= 1 }
                    memo.nextAngle = next
                }
                let e = i + 1 < n ? Int(memo.nextAngle![i + 1]) : n
                guard e < n, c[e] == ">", e - i < 2000 else { buf.append("<"); i += 1; break }
                let rest = String(c[i...e])
                if let m = rest.range(of: "^<[A-Za-z][A-Za-z0-9.+-]{1,31}:[^\\s<>]*>$", options: .regularExpression) {
                    let url = String(rest[m].dropFirst().dropLast())
                    let link = MDInline(.link); link.url = url; link.children = [MDInline(.text, url)]; link.depth = 2
                    flush(); nodes.append(link); i = e + 1
                } else if rest.range(of: "^<[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*>$", options: .regularExpression) != nil {
                    let mail = String(rest.dropFirst().dropLast())
                    let link = MDInline(.link); link.url = "mailto:" + mail; link.children = [MDInline(.text, mail)]; link.depth = 2
                    flush(); nodes.append(link); i = e + 1
                } else if rest.range(of: "^</?[A-Za-z][A-Za-z0-9-]*(\\s+[^<>]*)?/?>$", options: .regularExpression) != nil {
                    flush(); nodes.append(MDInline(.html, rest)); i = e + 1
                } else { buf.append("<"); i += 1 }
            case "&":
                let rest = String(c[i..<min(n, i + 40)])
                if let m = rest.range(of: "^&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});", options: .regularExpression),
                   let decoded = MDInlineParser.entity(String(rest[m])) {
                    buf += decoded; i += rest[m].count
                } else { buf.append("&"); i += 1 }
            case "\n":
                let hard = buf.hasSuffix("  ")
                while buf.last == " " { buf.removeLast() }
                flush(); nodes.append(MDInline(hard ? .hardBreak : .softBreak)); i += 1
                while i < n, c[i] == " " { i += 1 }
            default:
                buf.append(ch); i += 1
            }
        }
        flush()
        MDInlineParser.processEmphasis(&nodes)
        return MDInlineParser.autolink(nodes)
    }

    /// `(destination "title")` right after a closing bracket. Positions are found first and the strings
    /// built only for a real link, so failed attempts cost little.
    private func inlineLink(_ c: [Character], _ start: Int, _ memo: inout Memo) -> (url: String, title: String, end: Int)? {
        let n = c.count
        guard start < n, c[start] == "(" else { return nil }
        var j = start + 1
        func skipSpace() { while j < n, c[j] == " " || c[j] == "\n" || c[j] == "\t" { j += 1 } }
        skipSpace()
        var urlRange = j..<j
        var angled = false
        if j < n, c[j] == "<" {
            let from = j + 1
            var stop: Int
            if from >= memo.angle.from && from <= memo.angle.stop {
                stop = memo.angle.stop
            } else {
                stop = from
                while stop < n, c[stop] != ">", c[stop] != "\n" { if c[stop] == "\\", stop + 1 < n { stop += 1 }; stop += 1 }
                memo.angle = (from, stop)
            }
            guard stop < n, c[stop] == ">" else { return nil }
            urlRange = from..<stop
            angled = true
            j = stop + 1
        } else {
            var depth = 0
            let from = j
            while j < n {
                let ch = c[j]
                if ch == " " || ch == "\n" || ch == "\t" { break }
                if ch == "\\", j + 1 < n, MDInlineParser.asciiPunct.contains(c[j + 1]) { j += 2; continue }
                if ch == "(" { depth += 1; if depth > 32 { return nil } }   // CommonMark's limit on nested parentheses
                if ch == ")" { if depth == 0 { break }; depth -= 1 }
                j += 1
            }
            urlRange = from..<j
        }
        skipSpace()
        var titleRange: Range<Int>?
        if j < n, let close: Character = ["\"": "\"", "'": "'", "(": ")"][c[j]] {
            let from = j + 1
            var stop: Int
            if let t = memo.title[close], from >= t.from, from <= t.stop {
                stop = t.stop
            } else {
                stop = from
                while stop < n, c[stop] != close { if c[stop] == "\\", stop + 1 < n { stop += 1 }; stop += 1 }
                memo.title[close] = (from, stop)
            }
            guard stop < n else { return nil }
            titleRange = from..<stop
            j = stop + 1
            skipSpace()
        }
        guard j < n, c[j] == ")" else { return nil }
        // Now that it is a link, unescape the pieces.
        var url = ""
        var k = urlRange.lowerBound
        while k < urlRange.upperBound {
            if c[k] == "\\", k + 1 < urlRange.upperBound, angled || MDInlineParser.asciiPunct.contains(c[k + 1]) { k += 1 }
            url.append(c[k]); k += 1
        }
        var title = ""
        if let r = titleRange {
            k = r.lowerBound
            while k < r.upperBound { if c[k] == "\\", k + 1 < r.upperBound { k += 1 }; title.append(c[k]); k += 1 }
        }
        return (MDInlineParser.decodeEntities(url), title, j + 1)
    }

    /// CommonMark's emphasis matching, including the "multiple of 3" rule; unmatched runs become text.
    /// A stack of possible openers plus, per kind of closer, the height below which nothing matches
    /// ("openers bottom"), keeps it linear.
    static func processEmphasis(_ input: inout [MDInline]) {
        guard input.contains(where: { $0.kind == .delim }) else { return }
        var out: [MDInline] = []
        out.reserveCapacity(input.count)
        var openers: [Int] = []          // indices into `out` of delimiter runs that can open
        var bottom: [String: Int] = [:]
        func clampBottoms() { for (k, v) in bottom where v > openers.count { bottom[k] = openers.count } }
        func toText(_ d: MDInline) { d.kind = .text; d.text = String(repeating: String(d.delim), count: d.count) }
        for node in input {
            guard node.kind == .delim else { out.append(node); continue }
            let closer = node
            if closer.canClose {
                while closer.count > 0 {
                    let key = "\(closer.delim)\(closer.canOpen ? 1 : 0)\(closer.origCount % 3)" + (closer.delim == "~" ? "\(closer.count)" : "")
                    let floor = min(bottom[key] ?? 0, openers.count)
                    var found = -1
                    var si = openers.count - 1
                    while si >= floor {
                        let o = out[openers[si]]
                        if o.delim == closer.delim, o.count > 0 {
                            if closer.delim == "~" {
                                if o.count == closer.count { found = si; break }
                            } else {
                                let odd = (o.canClose || closer.canOpen) && (o.origCount + closer.origCount) % 3 == 0
                                    && !(o.origCount % 3 == 0 && closer.origCount % 3 == 0)
                                if !odd { found = si; break }
                            }
                        }
                        si -= 1
                    }
                    guard found >= 0 else { bottom[key] = openers.count; break }
                    // Delimiter runs between opener and closer can no longer match: they are text.
                    for s in (found + 1)..<openers.count { toText(out[openers[s]]) }
                    openers.removeSubrange((found + 1)...)
                    let oi = openers[found]
                    let opener = out[oi]
                    let use = closer.delim == "~" ? closer.count : (opener.count >= 2 && closer.count >= 2 ? 2 : 1)
                    let wrapped = MDInline.wrap(closer.delim == "~" ? .strike : (use == 2 ? .strong : .emph), Array(out[(oi + 1)...]))
                    out.removeSubrange((oi + 1)...)
                    out.append(wrapped)
                    opener.count -= use
                    closer.count -= use
                    if opener.count == 0 { out.remove(at: oi); openers.removeLast() }
                    clampBottoms()
                }
            }
            if closer.count > 0 {
                out.append(closer)
                if closer.canOpen { openers.append(out.count - 1) }
            }
        }
        for node in out where node.kind == .delim { toText(node) }
        input = out
    }

    /// GitHub-style bare links: http(s)://… and www.… in plain text.
    static func autolink(_ nodes: [MDInline]) -> [MDInline] {
        guard let re = try? NSRegularExpression(pattern: "(?<![\\w/@.])(?:https?://|www\\.)[^\\s<>]+") else { return nodes }
        var out: [MDInline] = []
        for node in nodes {
            if node.kind != .text {
                if [.emph, .strong, .strike].contains(node.kind) { node.children = autolink(node.children) }
                out.append(node); continue
            }
            let s = node.text as NSString
            var last = 0
            for m in re.matches(in: node.text, range: NSRange(location: 0, length: s.length)) {
                var url = s.substring(with: m.range)
                while let ch = url.last, ".,:;!?\"'*_~".contains(ch) { url.removeLast() }
                // Unbalanced closing parentheses at the end aren't part of the address.
                let opens = url.filter { $0 == "(" }.count
                var closes = url.filter { $0 == ")" }.count
                while url.hasSuffix(")"), opens < closes { url.removeLast(); closes -= 1 }
                guard !url.isEmpty, url != "www.", !url.hasSuffix("://") else { continue }
                if m.range.location > last { out.append(MDInline(.text, s.substring(with: NSRange(location: last, length: m.range.location - last)))) }
                let link = MDInline(.link)
                link.url = url.hasPrefix("www.") ? "http://" + url : url
                link.children = [MDInline(.text, url)]
                link.depth = 2
                out.append(link)
                last = m.range.location + (url as NSString).length
            }
            if last == 0 { out.append(node) }
            else if last < s.length { out.append(MDInline(.text, s.substring(from: last))) }
        }
        return out
    }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
        "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“",
        "rdquo": "”", "bull": "•", "middot": "·", "deg": "°", "plusmn": "±", "times": "×", "divide": "÷",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶", "laquo": "«", "raquo": "»",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔", "check": "✓", "hearts": "♥", "ensp": "\u{2002}",
        "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwj": "\u{200D}", "zwnj": "\u{200C}", "shy": "\u{00AD}",
        "frac12": "½", "frac14": "¼", "frac34": "¾", "sup2": "²", "sup3": "³", "micro": "µ", "iexcl": "¡", "iquest": "¿",
        "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß", "eacute": "é",
        "egrave": "è", "agrave": "à", "aacute": "á", "ccedil": "ç", "ntilde": "ñ", "oacute": "ó", "uacute": "ú", "iacute": "í",
    ]

    static func entity(_ s: String) -> String? {
        let body = String(s.dropFirst().dropLast())
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            return UInt32(body.dropFirst(2), radix: 16).flatMap { UnicodeScalar($0 == 0 ? 0xFFFD : $0) }.map { String(Character($0)) }
        }
        if body.hasPrefix("#") {
            return UInt32(body.dropFirst()).flatMap { UnicodeScalar($0 == 0 ? 0xFFFD : $0) }.map { String(Character($0)) }
        }
        return namedEntities[body]
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&"), let re = try? NSRegularExpression(pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});") else { return s }
        let ns = s as NSString
        var out = "", last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let e = ns.substring(with: m.range)
            out += entity(e) ?? e
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }
}

// MARK: - Rendering

/// Turns parsed blocks into rich text in RichStyle's look, using the conventions Cocoa's own writers
/// understand (NSTextList markers in the text, NSTextTable cells, header levels).
final class MDRenderer {
    let inline: MDInlineParser
    let baseURL: URL?
    private let out = NSMutableAttributedString()
    /// Numbers code blocks, so two blocks in a row stay two blocks.
    private var codeBlocks = 0

    init(refs: [String: (url: String, title: String)], baseURL: URL?) {
        inline = MDInlineParser(refs: refs)
        self.baseURL = baseURL
    }

    /// Where in the block tree rendering is: enclosing blocks, lists and quotes.
    struct Context {
        var blocks: [NSTextBlock] = []
        var lists: [NSTextList] = []
        var quoteDepth = 0
        var tight = false
        /// Marker text for the next paragraph (the first paragraph of a list item).
        var marker: String?
    }

    /// The character look while inline elements are rendered.
    struct Style {
        var bold = false, italic = false, code = false, strike = false, underline = false, mark = false
        var script = 0
        var size = RichStyle.bodySize
        var link: URL?
        var color: NSColor?
    }

    func render(_ blocks: [MDBlock]) -> NSMutableAttributedString {
        renderBlocks(blocks, Context())
        // No empty last paragraph.
        while out.length > 0, out.string.hasSuffix("\n"), out.length > 1,
              (out.string as NSString).character(at: out.length - 2) == 0x0A,
              (out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.isEmpty ?? true {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    private func paragraphStyle(_ ctx: Context, after: CGFloat, before: CGFloat = 0) -> NSMutableParagraphStyle {
        let p = RichStyle.paragraph(after: after, before: before)
        p.textBlocks = ctx.blocks
        // Only a list item's first paragraph is in the NSTextList; later ones are continuations.
        p.textLists = ctx.marker == nil ? [] : ctx.lists
        if !ctx.lists.isEmpty {
            let indent = CGFloat(ctx.lists.count) * 24 + 4
            p.headIndent = indent
            p.firstLineHeadIndent = ctx.marker == nil ? indent : 0
            p.tabStops = [NSTextTab(textAlignment: .right, location: indent - 7), NSTextTab(textAlignment: .left, location: indent)]
        }
        return p
    }

    private func baseAttributes(_ ctx: Context, _ ps: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.paragraphStyle: ps, .font: RichStyle.font()]
        if ctx.quoteDepth > 0 { a[.dwQuote] = ctx.quoteDepth; a[.foregroundColor] = RichStyle.quoteText }
        if ps.textLists.isEmpty && !ctx.lists.isEmpty { a[.dwListContinuation] = ctx.lists.count }
        return a
    }

    private func renderBlocks(_ blocks: [MDBlock], _ context: Context) {
        var ctx = context
        for (bi, block) in blocks.enumerated() {
            let last = bi == blocks.count - 1
            switch block {
            case .heading(let level, let text):
                let ps = paragraphStyle(ctx, after: 6, before: level <= 2 ? 18 : 12)
                ps.headerLevel = level
                var style = Style(); style.bold = true; style.size = RichStyle.headingSizes[level - 1]
                if level == 6 { style.color = RichStyle.caption }
                emitParagraph(inline.parse(text), style, &ctx, ps)
            case .paragraph(let text):
                let after: CGFloat = ctx.tight ? (last ? 4 : 2) : 8
                emitParagraph(inline.parse(text), Style(), &ctx, paragraphStyle(ctx, after: after))
            case .code(let text, let lang):
                if let marker = ctx.marker { emitMarkerOnly(marker, &ctx) }
                let block = NSTextBlock()
                block.setContentWidth(100, type: .percentageValueType)   // TextKit ignores blocks without a width
                block.backgroundColor = RichStyle.codeBackground
                block.setWidth(8, type: .absoluteValueType, for: .padding)
                block.setWidth(2, type: .absoluteValueType, for: .margin, edge: .minY)
                block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
                var inner = ctx
                inner.blocks.append(block)
                let lines = text.components(separatedBy: "\n")
                codeBlocks += 1
                for line in lines {
                    let ps = paragraphStyle(inner, after: 0)
                    ps.lineHeightMultiple = 1.0
                    if !ctx.lists.isEmpty { ps.firstLineHeadIndent = ps.headIndent }
                    var a = baseAttributes(inner, ps)
                    a[.font] = RichStyle.mono()
                    a[.dwCodeBlock] = lang
                    a[.dwCodeBlockID] = codeBlocks
                    out.append(NSAttributedString(string: line.replacingOccurrences(of: "\t", with: "    ") + "\n", attributes: a))
                }
            case .quote(let inner):
                if let marker = ctx.marker { emitMarkerOnly(marker, &ctx) }
                let block = NSTextBlock()
                block.setContentWidth(100, type: .percentageValueType)   // TextKit ignores blocks without a width
                block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                block.setBorderColor(RichStyle.rule, for: .minX)
                block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(2, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
                var q = ctx
                q.blocks.append(block)
                q.quoteDepth += 1
                q.tight = true
                renderBlocks(inner, q)
            case .list(let ordered, let start, let tight, let items):
                let depth = ctx.lists.count
                let level = ordered ? RichListLevel(style: depth % 2 == 0 ? .decimal : .lowerAlpha, start: start)
                                    : RichListLevel.defaultBullet(depth: depth)
                let list = NSTextList(markerFormat: level.markerFormat, options: 0)
                list.startingItemNumber = start
                if let marker = ctx.marker { emitMarkerOnly(marker, &ctx) }
                for (n, item) in items.enumerated() {
                    var inner = ctx
                    inner.lists.append(list)
                    inner.tight = tight
                    let markerText = list.marker(forItemNumber: start + n)
                    inner.marker = "\t\(markerText)\t" + (item.task.map { $0 ? "☑ " : "☐ " } ?? "")
                    if item.blocks.isEmpty {
                        emitMarkerOnly(inner.marker!, &inner)
                    } else {
                        renderBlocks(item.blocks, inner)
                    }
                }
                // Space after the whole list.
                if depth == 0, out.length > 0 { bumpLastSpacing(to: 8) }
            case .table(let header, let align, let rows):
                emitTable([header] + rows, headerRows: 1, align: align, &ctx)
            case .rule:
                if let marker = ctx.marker { emitMarkerOnly(marker, &ctx) }
                let block = NSTextBlock()
                block.setContentWidth(100, type: .percentageValueType)   // TextKit ignores blocks without a width
                block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                block.setBorderColor(RichStyle.rule, for: .maxY)
                block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .minY)
                block.setWidth(12, type: .absoluteValueType, for: .margin, edge: .maxY)
                var c = ctx
                c.blocks.append(block)
                let ps = paragraphStyle(c, after: 0)
                ps.lineHeightMultiple = 1
                var a = baseAttributes(c, ps)
                a[.font] = RichStyle.font(size: 2)
                a[.dwRule] = true
                out.append(NSAttributedString(string: "\n", attributes: a))
            case .html(let html):
                renderHTMLBlock(html, &ctx)
            }
        }
    }

    /// A table of inline-Markdown cells; the first `headerRows` rows are bold on a grey background.
    private func emitTable(_ rows: [[String]], headerRows: Int, align: [NSTextAlignment], _ ctx: inout Context) {
        if let marker = ctx.marker { emitMarkerOnly(marker, &ctx) }
        let table = NSTextTable()
        table.numberOfColumns = max(1, rows.map(\.count).max() ?? 1)
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        for (r, row) in rows.enumerated() {
            for col in 0..<table.numberOfColumns {
                let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: col, columnSpan: 1)
                cell.setWidth(0.75, type: .absoluteValueType, for: .border)
                cell.setBorderColor(RichStyle.tableBorder)
                cell.setWidth(5, type: .absoluteValueType, for: .padding)
                if r < headerRows { cell.backgroundColor = RichStyle.headerBackground }
                var c = ctx
                c.blocks.append(cell)
                c.lists = []
                let ps = paragraphStyle(c, after: 0)
                ps.alignment = col < align.count ? align[col] : .natural
                var style = Style(); style.bold = r < headerRows
                let text = col < row.count ? row[col] : ""
                emitParagraph(inline.parse(text), style, &c, ps)
            }
        }
        bumpLastSpacing(to: 10)
    }

    private func bumpLastSpacing(to value: CGFloat) {
        guard out.length > 0 else { return }
        let r = (out.string as NSString).paragraphRange(for: NSRange(location: out.length - 1, length: 0))
        guard let ps = (out.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy()
                as? NSMutableParagraphStyle, ps.paragraphSpacing < value else { return }
        ps.paragraphSpacing = value
        out.addAttribute(.paragraphStyle, value: ps, range: r)
    }

    /// A list item whose first block isn't a paragraph gets a paragraph holding just its marker.
    private func emitMarkerOnly(_ marker: String, _ ctx: inout Context) {
        let ps = paragraphStyle(ctx, after: 2)
        out.append(NSAttributedString(string: marker + "\n", attributes: baseAttributes(ctx, ps)))
        ctx.marker = nil
    }

    private func emitParagraph(_ nodes: [MDInline], _ style: Style, _ ctx: inout Context, _ ps: NSParagraphStyle) {
        let base = baseAttributes(ctx, ps)
        if let marker = ctx.marker {
            var a = base
            a[.font] = RichStyle.font(size: style.size, bold: style.bold)
            out.append(NSAttributedString(string: marker, attributes: a))
            ctx.marker = nil
        }
        var s = style
        if ctx.quoteDepth > 0, s.color == nil { s.color = RichStyle.quoteText }
        var tagStack: [(String, Style)] = []
        emitInlines(nodes, &s, base, &tagStack)
        out.append(NSAttributedString(string: "\n", attributes: base))
    }

    private func attributes(_ s: Style, _ base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var a = base
        let size = s.script != 0 ? s.size * 0.75 : s.size
        a[.font] = s.code ? RichStyle.mono(size: size * 0.9, bold: s.bold, italic: s.italic)
                          : RichStyle.font(size: size, bold: s.bold, italic: s.italic)
        if s.code { a[.backgroundColor] = RichStyle.codeBackground }
        if s.strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if s.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if s.mark { a[.backgroundColor] = NSColor(srgbRed: 1, green: 0.93, blue: 0.55, alpha: 1) }
        if s.script != 0 { a[.superscript] = s.script }
        if let color = s.color { a[.foregroundColor] = color }
        if let link = s.link { a[.link] = link; a[.foregroundColor] = RichStyle.linkColor }
        return a
    }

    private func emitInlines(_ nodes: [MDInline], _ s: inout Style, _ base: [NSAttributedString.Key: Any],
                             _ tags: inout [(String, Style)]) {
        for node in nodes {
            switch node.kind {
            case .text: out.append(NSAttributedString(string: node.text, attributes: attributes(s, base)))
            case .code:
                var c = s; c.code = true
                out.append(NSAttributedString(string: node.text, attributes: attributes(c, base)))
            case .softBreak: out.append(NSAttributedString(string: " ", attributes: attributes(s, base)))
            case .hardBreak: out.append(NSAttributedString(string: "\u{2028}", attributes: attributes(s, base)))
            case .emph, .strong, .strike:
                var inner = s
                if node.kind == .emph { inner.italic = true }
                if node.kind == .strong { inner.bold = true }
                if node.kind == .strike { inner.strike = true }
                emitInlines(node.children, &inner, base, &tags)
            case .link:
                var inner = s
                inner.link = MDRenderer.linkURL(node.url, base: baseURL)
                emitInlines(node.children, &inner, base, &tags)
            case .image:
                emitImage(src: node.url, alt: node.children.map(\.plainText).joined(), width: nil, height: nil, s, base)
            case .html:
                html(node.text, &s, base, &tags)
            case .delim:
                out.append(NSAttributedString(string: node.plainText, attributes: attributes(s, base)))
            }
        }
    }

    /// The few inline HTML tags Markdown files use: line breaks, emphasis, underline, super/subscript,
    /// keyboard keys, highlights, links and pictures. Other tags are dropped, their text kept.
    private func html(_ tag: String, _ s: inout Style, _ base: [NSAttributedString.Key: Any], _ tags: inout [(String, Style)]) {
        guard let m = tag.range(of: "^</?[A-Za-z][A-Za-z0-9-]*", options: .regularExpression) else { return }
        let closing = tag.hasPrefix("</")
        let name = tag[m].trimmingCharacters(in: CharacterSet(charactersIn: "</")).lowercased()
        let attrs = MDRenderer.htmlAttributes(tag)
        if closing {
            if let i = tags.lastIndex(where: { $0.0 == name }) { s = tags[i].1; tags.removeSubrange(i...) }
            return
        }
        switch name {
        case "br": out.append(NSAttributedString(string: "\u{2028}", attributes: attributes(s, base))); return
        case "img":
            emitImage(src: attrs["src"] ?? "", alt: attrs["alt"] ?? "", width: attrs["width"].flatMap { Double($0) },
                      height: attrs["height"].flatMap { Double($0) }, s, base)
            return
        case "hr": out.append(NSAttributedString(string: "\u{2028}", attributes: attributes(s, base))); return
        default: break
        }
        if tag.hasSuffix("/>") { return }
        tags.append((name, s))
        switch name {
        case "b", "strong": s.bold = true
        case "i", "em", "cite", "var": s.italic = true
        case "u", "ins": s.underline = true
        case "s", "del", "strike": s.strike = true
        case "code", "kbd", "tt", "samp": s.code = true
        case "sup": s.script = 1
        case "sub": s.script = -1
        case "mark": s.mark = true
        case "small": s.size *= 0.85
        case "a": if let href = attrs["href"] { s.link = MDRenderer.linkURL(href, base: baseURL) }
        default: break
        }
    }

    static func htmlAttributes(_ tag: String) -> [String: String] {
        guard let re = try? NSRegularExpression(pattern: "([A-Za-z_:][-A-Za-z0-9_:.]*)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s\"'=<>`]+)") else { return [:] }
        let ns = tag as NSString
        var out: [String: String] = [:]
        for m in re.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            var v = ns.substring(with: m.range(at: 2))
            if v.hasPrefix("\"") || v.hasPrefix("'") { v = String(v.dropFirst().dropLast()) }
            out[ns.substring(with: m.range(at: 1)).lowercased()] = MDInlineParser.decodeEntities(v)
        }
        return out
    }

    /// A link target. Relative links stay relative (they keep working next to the converted file and
    /// don't carry this Mac's folder names along).
    static func linkURL(_ raw: String, base: URL?) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let u = URL(string: s), u.scheme != nil { return u }
        if s.hasPrefix("#") { return URL(string: s) }
        if let encoded = s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(CharacterSet(charactersIn: "#%"))),
           let u = URL(string: encoded) {
            return u
        }
        return nil
    }

    /// Local and data: pictures are embedded; remote ones become a link with their alt text.
    private func emitImage(src: String, alt: String, width: Double?, height: Double?, _ s: Style, _ base: [NSAttributedString.Key: Any]) {
        let source = src.trimmingCharacters(in: .whitespaces)
        var data: Data?
        var name = "image"
        if source.hasPrefix("data:"), let comma = source.firstIndex(of: ",") {
            let meta = source[..<comma]
            let payload = String(source[source.index(after: comma)...])
            data = meta.contains(";base64") ? Data(base64Encoded: payload.removingPercentEncoding ?? payload, options: .ignoreUnknownCharacters)
                                            : payload.removingPercentEncoding?.data(using: .utf8)
        } else if let file = MDRenderer.localFile(source, base: baseURL) {
            name = file.lastPathComponent
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > 0, size < 80_000_000 {
                data = try? Data(contentsOf: file)
                if data != nil, Ext.svg.contains(Ext.of(file)), let src = try? ImageExtras.svgSource(file),
                   let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    data = RichImage.pngData(cg)
                }
            }
        }
        var display: CGSize?
        if let data, let w = width, w > 0, let probe = RichImage.from(data: data, name: name) {
            let h = height ?? Double(probe.pixelSize.height / max(probe.pixelSize.width, 1)) * w
            display = CGSize(width: w, height: h)
        }
        if let data, let image = RichImage.from(data: data, name: name, alt: alt, display: display) {
            let wrapper = FileWrapper(regularFileWithContents: image.data)
            wrapper.preferredFilename = image.name
            let attachment = NSTextAttachment(fileWrapper: wrapper)
            attachment.bounds = CGRect(origin: .zero, size: image.displaySize)
            var a = attributes(s, base)
            a[.attachment] = attachment
            a[.dwImageAlt] = alt
            out.append(NSAttributedString(string: "\u{FFFC}", attributes: a))
            return
        }
        // Not loadable (remote, missing, or not a picture): keep the alt text, linked to the source.
        var placeholder = s
        placeholder.italic = true
        placeholder.color = RichStyle.caption
        if placeholder.link == nil, let url = URL(string: source), url.scheme != nil, url.scheme != "data" { placeholder.link = url }
        let label = alt.isEmpty ? (URL(string: source)?.lastPathComponent ?? "image") : alt
        out.append(NSAttributedString(string: "[\(label)]", attributes: attributes(placeholder, base)))
    }

    /// The local file a picture reference names, only when it lies inside the document's own folder (or a
    /// folder below it). file: URLs, absolute and ~ paths, and ../ (or symlink) escapes are refused, so a
    /// document can't pull in pictures from elsewhere on the disk. `base` is the document itself.
    static func localFile(_ src: String, base: URL?) -> URL? {
        let source = src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, let base, base.isFileURL else { return nil }
        if let u = URL(string: source), let scheme = u.scheme, scheme.count > 1 { return nil }
        let folder = base.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let root = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        // The encoded form with its ?query / #fragment cut off first, then decoded ("Figure%20%231.png" is
        // "Figure #1.png"); then the reference taken literally, for hand-written names with # or %.
        var cut = source
        if let q = cut.firstIndex(where: { $0 == "?" || $0 == "#" }) { cut = String(cut[..<q]) }
        var seen: Set<String> = []
        for path in [cut.removingPercentEncoding ?? cut, source.removingPercentEncoding ?? source, source] where seen.insert(path).inserted {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.hasPrefix("\\"), !path.contains("\0") else { continue }
            let url = folder.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(root) else { continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue { return url }
        }
        return nil
    }

    /// Raw HTML blocks: comments, scripts and styles dropped, headings kept, tables kept as tables, other
    /// block tags become paragraph breaks and inline tags go on to the inline parser. One pass over the text.
    private func renderHTMLBlock(_ html: String, _ ctx: inout Context) {
        let centered = html.range(of: "align\\s*=\\s*[\"']?center", options: [.regularExpression, .caseInsensitive]) != nil
        let breaks: Set<String> = ["p", "div", "li", "ul", "ol", "blockquote", "section", "article", "header", "footer", "details",
                                   "summary", "center", "figure", "figcaption", "pre", "dl", "dt", "dd", "hr", "picture", "main",
                                   "nav", "aside", "body", "html", "head", "title", "form", "fieldset", "legend", "address", "dialog"]
        var para = ""
        var heading = 0
        // The table being read: rows of (inline markup, header cell) and the cell being filled.
        var rows: [[(text: String, header: Bool)]] = []
        var cell: (text: String, header: Bool)?
        var tables = 0          // nesting depth; inner tables are flattened into the cell
        var caption = ""

        func flushParagraph() {
            let text = para.replacingOccurrences(of: "\\s*\n\\s*", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            para = ""
            defer { heading = 0 }
            guard !text.isEmpty else { return }
            if heading > 0 {
                let ps = paragraphStyle(ctx, after: 6, before: heading <= 2 ? 18 : 12)
                ps.headerLevel = heading
                if centered { ps.alignment = .center }
                var style = Style(); style.bold = true; style.size = RichStyle.headingSizes[heading - 1]
                emitParagraph(inline.parse(text), style, &ctx, ps)
            } else {
                let ps = paragraphStyle(ctx, after: 8)
                if centered { ps.alignment = .center }
                emitParagraph(inline.parse(text), Style(), &ctx, ps)
            }
        }
        func endCell() {
            guard let c = cell else { return }
            if rows.isEmpty { rows.append([]) }
            let text = c.text.replacingOccurrences(of: "\\s*\n\\s*", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            rows[rows.count - 1].append((text, c.header))
            cell = nil
        }
        func endTable() {
            endCell()
            let kept = rows.filter { !$0.isEmpty }
            rows = []
            if !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { para = caption; flushParagraph() }
            caption = ""
            guard !kept.isEmpty else { return }
            let headerRows = kept[0].allSatisfy(\.header) ? 1 : 0
            emitTable(kept.map { $0.map(\.text) }, headerRows: headerRows, align: [], &ctx)
        }
        func append(_ s: String) {
            if tables > 0 {
                if cell != nil { cell!.text += s } else { caption += s }
            } else {
                para += s
            }
        }

        for token in MDHTMLScan.tokens(html) {
            switch token {
            case .text(let t):
                append(t)
            case .tag(let name, let closing, let raw, let attrs):
                if tables > 0 {
                    switch name {
                    case "table":
                        if closing { if tables == 1 { tables = 0; endTable() } else { tables -= 1; append(" ") } }
                        else { tables += 1; append(" ") }
                        continue
                    case "tr":
                        if tables == 1 { endCell(); if !closing { rows.append([]) } } else { append(" ") }
                        continue
                    case "td", "th":
                        guard tables == 1 else { append(" "); continue }
                        endCell()
                        if !closing {
                            if rows.isEmpty { rows.append([]) }
                            cell = ("", name == "th")
                            // Spanned columns keep the cells after them in their own columns.
                            let span = min(50, max(1, Int(attrs["colspan"] ?? "") ?? 1))
                            if span > 1 { for _ in 1..<span { rows[rows.count - 1].append(("", name == "th")) } }
                        }
                        continue
                    case "thead", "tbody", "tfoot", "colgroup", "col", "caption":
                        continue
                    default:
                        if breaks.contains(name) || name == "br" { append(cell != nil ? "<br>" : " ") } else { append(raw) }
                        continue
                    }
                }
                if name == "table" {
                    if !closing { flushParagraph(); tables = 1; rows = []; cell = nil; caption = "" }
                    continue
                }
                if name.count == 2, name.first == "h", let level = Int(String(name.last!)), (1...6).contains(level) {
                    flushParagraph()
                    if !closing { heading = level }
                    continue
                }
                if breaks.contains(name) || ["tr", "td", "th", "thead", "tbody", "tfoot"].contains(name) { flushParagraph(); continue }
                para += raw
            }
        }
        if tables > 0 { tables = 0; endTable() }
        flushParagraph()
    }
}

/// A linear scan of HTML into text and tags, with comments, scripts and styles left out. Tags are found
/// by the next '>' with no '<' before it, so unclosed tags and scripts can't make the scan quadratic.
enum MDHTMLScan {
    enum Token {
        case text(String)
        /// Lower-cased name, whether it's a closing tag, the tag as written, and its attributes.
        case tag(String, Bool, String, [String: String])
    }

    static func tokens(_ html: String) -> [Token] {
        let c = Array(html.utf16)
        let n = c.count
        var out: [Token] = []
        var text: [UInt16] = []
        func flushText() { if !text.isEmpty { out.append(.text(String(decoding: text, as: UTF16.self))); text = [] } }
        func lower(_ u: UInt16) -> UInt16 { (0x41...0x5A).contains(u) ? u + 32 : u }
        func isNameChar(_ u: UInt16) -> Bool { (0x30...0x39).contains(u) || (0x41...0x5A).contains(u) || (0x61...0x7A).contains(u) || u == 0x2D || u == 0x3A }
        /// The first index ≥ from where `word` (lower-case ASCII) starts, ignoring case.
        func find(_ word: [UInt16], from: Int) -> Int? {
            var i = from
            while i + word.count <= n {
                if lower(c[i]) == word[0] {
                    var k = 1
                    while k < word.count, lower(c[i + k]) == word[k] { k += 1 }
                    if k == word.count { return i }
                }
                i += 1
            }
            return nil
        }
        var i = 0
        while i < n {
            guard c[i] == 0x3C else { text.append(c[i]); i += 1; continue }
            // Comments: to the next "-->", or the end.
            if i + 3 < n, c[i + 1] == 0x21, c[i + 2] == 0x2D, c[i + 3] == 0x2D {
                flushText()
                if let close = find(Array("-->".utf16), from: i + 4) { i = close + 3 } else { i = n }
                continue
            }
            var j = i + 1
            let closing = j < n && c[j] == 0x2F
            if closing { j += 1 }
            let nameStart = j
            while j < n, isNameChar(c[j]) { j += 1 }
            guard j > nameStart, (0x41...0x5A).contains(c[nameStart]) || (0x61...0x7A).contains(c[nameStart]) else {
                text.append(c[i]); i += 1; continue
            }
            var end = j
            while end < n, c[end] != 0x3E, c[end] != 0x3C { end += 1 }
            guard end < n, c[end] == 0x3E else { text.append(c[i]); i += 1; continue }
            let name = String(decoding: c[nameStart..<j].map(lower), as: UTF16.self)
            let raw = String(decoding: c[i...end], as: UTF16.self)
            flushText()
            if !closing, name == "script" || name == "style" || name == "template" {
                // Skipped with everything up to its closing tag (or the end, as browsers do).
                if let close = find(Array("</\(name)".utf16), from: end + 1) {
                    var k = close
                    while k < n, c[k] != 0x3E { k += 1 }
                    i = min(n, k + 1)
                } else { i = n }
                continue
            }
            out.append(.tag(name, closing, raw, closing ? [:] : MDRenderer.htmlAttributes(raw)))
            i = end + 1
        }
        flushText()
        return out
    }

    /// The HTML with whole elements removed (opening tag to closing tag, or to the end when unclosed),
    /// found in one pass; names are lower-case.
    static func removingElements(_ html: String, _ names: Set<String>, keepUnclosed: Bool = false) -> String {
        let c = Array(html.utf16)
        let n = c.count
        var out: [UInt16] = []
        out.reserveCapacity(n)
        func lower(_ u: UInt16) -> UInt16 { (0x41...0x5A).contains(u) ? u + 32 : u }
        func isNameChar(_ u: UInt16) -> Bool { (0x30...0x39).contains(u) || (0x41...0x5A).contains(u) || (0x61...0x7A).contains(u) || u == 0x2D || u == 0x3A }
        // Where each name's next closing tag is: scanning positions only move forward.
        var nextClose: [String: Int] = [:]
        func closeTag(_ name: String, from: Int) -> Int? {
            if let k = nextClose[name], k >= from { return k < n ? k : nil }
            let word = Array("</\(name)".utf16)
            var i = from
            while i + word.count <= n {
                if c[i] == 0x3C {
                    var k = 1
                    while k < word.count, lower(c[i + k]) == word[k] { k += 1 }
                    if k == word.count, i + k >= n || !isNameChar(c[i + k]) { nextClose[name] = i; return i }
                }
                i += 1
            }
            nextClose[name] = n
            return nil
        }
        var i = 0
        while i < n {
            if c[i] == 0x3C, i + 1 < n {
                var j = i + 1
                while j < n, isNameChar(c[j]) { j += 1 }
                if j > i + 1, j - i <= 20 {
                    let name = String(decoding: c[(i + 1)..<j].map(lower), as: UTF16.self)
                    if names.contains(name) {
                        if let close = closeTag(name, from: j) {
                            var k = close
                            while k < n, c[k] != 0x3E { k += 1 }
                            i = min(n, k + 1)
                            continue
                        }
                        if !keepUnclosed { break }
                    }
                }
            }
            out.append(c[i]); i += 1
        }
        return String(decoding: out, as: UTF16.self)
    }
}

extension MDHTMLScan {
    /// The HTML with opening and closing tags of `names` rewritten by `transform` (nil removes the tag),
    /// in one pass. A tag runs to the next '>'.
    static func rewritingTags(_ html: String, _ names: Set<String>, _ transform: (_ name: String, _ tag: String) -> String?) -> String {
        let c = Array(html.utf16)
        let n = c.count
        var out: [UInt16] = []
        out.reserveCapacity(n)
        func lower(_ u: UInt16) -> UInt16 { (0x41...0x5A).contains(u) ? u + 32 : u }
        func isNameChar(_ u: UInt16) -> Bool { (0x30...0x39).contains(u) || (0x41...0x5A).contains(u) || (0x61...0x7A).contains(u) || u == 0x2D || u == 0x3A }
        var nextGT = -1   // the first '>' at or after the last search start (n: none)
        var i = 0
        while i < n {
            if c[i] == 0x3C, i + 1 < n {
                var j = i + 1
                if c[j] == 0x2F { j += 1 }
                let start = j
                while j < n, isNameChar(c[j]) { j += 1 }
                if j > start, j - start <= 20, names.contains(String(decoding: c[start..<j].map(lower), as: UTF16.self)) {
                    if nextGT < j { nextGT = j; while nextGT < n, c[nextGT] != 0x3E { nextGT += 1 } }
                    if nextGT < n {
                        let name = String(decoding: c[start..<j].map(lower), as: UTF16.self)
                        let tag = String(decoding: c[i...nextGT], as: UTF16.self)
                        if let replacement = transform(name, tag) { out += Array(replacement.utf16) }
                        i = nextGT + 1
                        continue
                    }
                }
            }
            out.append(c[i]); i += 1
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// Each `<name …>content</name>` element's content rewritten by `transform`, in one pass (an unclosed
    /// element's content runs to the end).
    static func rewritingContent(_ html: String, of name: String, _ transform: (String) -> String) -> String {
        let c = Array(html.utf16)
        let n = c.count
        let open = Array("<\(name)".utf16), close = Array("</\(name)".utf16)
        func lower(_ u: UInt16) -> UInt16 { (0x41...0x5A).contains(u) ? u + 32 : u }
        func isNameChar(_ u: UInt16) -> Bool { (0x30...0x39).contains(u) || (0x41...0x5A).contains(u) || (0x61...0x7A).contains(u) || u == 0x2D || u == 0x3A }
        func at(_ i: Int, _ w: [UInt16]) -> Bool {
            guard i + w.count <= n else { return false }
            for k in 0..<w.count where lower(c[i + k]) != w[k] { return false }
            return i + w.count >= n || !isNameChar(c[i + w.count])
        }
        var out: [UInt16] = []
        out.reserveCapacity(n)
        var i = 0
        while i < n {
            if c[i] == 0x3C, at(i, open) {
                var gt = i
                while gt < n, c[gt] != 0x3E { gt += 1 }
                guard gt < n else { break }
                out += c[i...gt]
                var k = gt + 1
                while k < n, !(c[k] == 0x3C && at(k, close)) { k += 1 }
                out += Array(transform(String(decoding: c[(gt + 1)..<k], as: UTF16.self)).utf16)
                i = k
                continue
            }
            out.append(c[i]); i += 1
        }
        return String(decoding: out, as: UTF16.self)
    }
}
