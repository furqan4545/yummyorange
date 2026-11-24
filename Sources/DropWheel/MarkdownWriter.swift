import Foundation

/// Writes GitHub-flavoured Markdown from a RichDocument: ATX headings, emphasis, links, inline code and
/// fenced code blocks, quotes, nested and task lists, pipe tables and pictures.
enum MarkdownWriter {
    /// `image` saves a picture and returns the path to link to (nil leaves the picture out).
    static func markdown(_ doc: RichDocument, image: (RichImage) -> String?) -> String {
        var lines: [String] = []
        var previous: (kind: String, after: CGFloat, quote: Int)? = nil
        /// Width of the marker at each list depth, so nested items line up under their parent's text.
        var markerWidths: [Int] = []
        var index = 0
        let blocks = doc.blocks

        /// A blank line between blocks (a bare ">" inside quotes), except between items of a tight list.
        func separate(_ kind: String, before: CGFloat = 0, after: CGFloat = 8, quote: Int = 0) {
            defer { previous = (kind, after, quote) }
            guard let prev = previous else { return }
            if kind == "item" && prev.kind == "item" && prev.after <= 4 && before <= 4 && prev.quote == quote { return }
            let q = min(prev.quote, quote)
            lines.append(q > 0 ? String(repeating: ">", count: q) : "")
        }

        while index < blocks.count {
            let block = blocks[index]
            index += 1
            switch block {
            case .pageBreak:
                continue
            case .rule:
                separate("rule")
                lines.append("---")
                markerWidths = []
            case .table(let t):
                separate("table")
                lines += table(t, image: image)
                markerWidths = []
            case .paragraph(let first):
                let quote = String(repeating: "> ", count: first.quoteDepth)
                let depth = first.list.count
                if depth == 0 { markerWidths = [] }
                if markerWidths.count > depth { markerWidths.removeLast(markerWidths.count - depth) }
                let listIndent = String(repeating: " ", count: markerWidths.prefix(max(0, depth - 1)).reduce(0, +))
                if case .code(let lang) = first.kind {
                    // Consecutive code paragraphs of the same block make one fenced block.
                    var code = [first.text]
                    while index < blocks.count, case .paragraph(let next) = blocks[index], first.sameCodeBlock(next),
                          next.list.count == first.list.count {
                        code.append(next.text); index += 1
                    }
                    let body = code.joined(separator: "\n").replacingOccurrences(of: "\u{2028}", with: "\n")
                    let longest = body.components(separatedBy: CharacterSet(charactersIn: "`").inverted).map(\.count).max() ?? 0
                    let fence = String(repeating: "`", count: max(3, longest + 1))
                    let indent = depth > 0 ? String(repeating: " ", count: markerWidths.reduce(0, +)) : ""
                    separate("code", quote: first.quoteDepth)
                    lines.append(quote + indent + fence + lang)
                    for l in body.components(separatedBy: "\n") { lines.append(quote + indent + l) }
                    lines.append(quote + indent + fence)
                    continue
                }
                let text = inline(first.runs, image: image, plainBold: first.headingLevel != nil)
                if let level = first.headingLevel, depth == 0 {
                    separate("heading", quote: first.quoteDepth)
                    lines.append(quote + String(repeating: "#", count: level) + " " + text.replacingOccurrences(of: "\\\n", with: " "))
                    continue
                }
                if depth > 0 {
                    if first.listContinuation {
                        separate("para", quote: first.quoteDepth)
                        let indent = listIndent + String(repeating: " ", count: markerWidths.last ?? 2)
                        lines += prefixLines(text, first: quote + indent, rest: quote + indent)
                        continue
                    }
                    let level = first.list[depth - 1]
                    var marker = level.ordered ? "\(first.itemNumber)." : "-"
                    if let task = first.task { marker += task ? " [x]" : " [ ]" }
                    let width = (level.ordered ? "\(first.itemNumber)." : "-").count + 1
                    if markerWidths.count == depth { markerWidths[depth - 1] = width } else { markerWidths.append(width) }
                    separate("item", before: first.spaceBefore, after: first.spaceAfter, quote: first.quoteDepth)
                    let body = text.isEmpty ? "" : " " + text
                    lines += prefixLines(marker + body, first: quote + listIndent,
                                         rest: quote + listIndent + String(repeating: " ", count: width))
                    continue
                }
                if first.isEmpty { continue }
                separate("para", quote: first.quoteDepth)
                lines += prefixLines(escapeLineStart(text), first: quote, rest: quote)
            }
        }
        var out = lines.joined(separator: "\n")
        while out.hasSuffix("\n") { out.removeLast() }
        return out + "\n"
    }

    private static func prefixLines(_ text: String, first: String, rest: String) -> [String] {
        text.components(separatedBy: "\n").enumerated().map { i, l in (i == 0 ? first : rest) + l }
    }

    /// Text that would otherwise start a heading, quote, list or rule gets a backslash.
    static func escapeLineStart(_ s: String) -> String {
        guard let c = s.first else { return s }
        if "#>".contains(c) { return "\\" + s }
        if "-+*".contains(c), s.dropFirst().first == " " || s.count == 1 { return "\\" + s }
        if s.range(of: "^\\d{1,9}[.)](\\s|$)", options: .regularExpression) != nil, let end = s.firstIndex(where: { !$0.isNumber }) {
            return String(s[..<end]) + "\\" + s[end...]
        }
        if s.allSatisfy({ $0 == "=" || $0 == "-" }) { return "\\" + s }
        return s
    }

    private static func table(_ t: RichTable, image: (RichImage) -> String?) -> [String] {
        let columns = t.columns
        guard columns > 0, !t.rows.isEmpty else { return [] }
        func cellText(_ cell: RichCell, header: Bool) -> String {
            if cell.covered { return "" }
            return cell.paragraphs.map { inline($0.runs, image: image, inTable: true, plainBold: header) }.filter { !$0.isEmpty }.joined(separator: "<br>")
        }
        func row(_ r: [RichCell], header: Bool = false) -> String {
            let cells = (0..<columns).map { $0 < r.count ? cellText(r[$0], header: header) : "" }
            return "| " + cells.map { $0.isEmpty ? " " : $0 }.joined(separator: " | ") + " |"
        }
        let aligns: [String] = (0..<columns).map { c in
            let a = t.rows.dropFirst().first.flatMap { $0.count > c ? $0[c].paragraphs.first?.alignment : nil }
                ?? t.rows[0][min(c, t.rows[0].count - 1)].paragraphs.first?.alignment ?? .natural
            switch a {
            case .center: return ":---:"
            case .right: return "---:"
            default: return "---"
            }
        }
        // GitHub tables always have a header row, which renders bold by itself.
        var out = [row(t.rows[0], header: true), "| " + aligns.joined(separator: " | ") + " |"]
        for r in t.rows.dropFirst() { out.append(row(r)) }
        return out
    }

    /// Inline Markdown for a run of text. Styles open and close as a stack so they always nest, and
    /// spaces are kept outside the markers (`** bold**` wouldn't be bold).
    /// `plainBold`: leave bold out (headings and table headers are bold anyway).
    static func inline(_ runs: [RichRun], image: (RichImage) -> String?, inTable: Bool = false, plainBold: Bool = false) -> String {
        /// Markdown constructs that open and close around text.
        enum Mark: Equatable { case link(String), bold, italic, strike, sup, sub }
        var out = ""
        var stack: [Mark] = []
        var pendingSpace = ""

        func open(_ m: Mark) -> String {
            switch m {
            case .link: return "["
            case .bold: return "**"
            case .italic: return "*"
            case .strike: return "~~"
            case .sup: return "<sup>"
            case .sub: return "<sub>"
            }
        }
        func close(_ m: Mark) -> String {
            switch m {
            case .link(let url): return "](" + destination(url, inTable: inTable) + ")"
            case .bold: return "**"
            case .italic: return "*"
            case .strike: return "~~"
            case .sup: return "</sup>"
            case .sub: return "</sub>"
            }
        }
        func transition(to marks: [Mark]) {
            while let top = stack.last, !marks.contains(top) || stack.contains(where: { !marks.contains($0) }) {
                out += close(top); stack.removeLast()
            }
            out += pendingSpace; pendingSpace = ""
        }

        for run in runs {
            var marks: [Mark] = []
            if let link = run.link, RichDocument.isSafeLink(link) { marks.append(.link(link)) }
            if run.bold && !plainBold { marks.append(.bold) }
            if run.italic { marks.append(.italic) }
            if run.strike { marks.append(.strike) }
            if run.script > 0 { marks.append(.sup) } else if run.script < 0 { marks.append(.sub) }

            if let img = run.image {
                transition(to: marks)
                for m in marks where !stack.contains(m) { out += open(m); stack.append(m) }
                if let path = image(img) {
                    let stem = (img.name as NSString).deletingPathExtension
                    let generic = ["unknown", "attachment", "image", "picture", "pasted graphic"].contains { stem.lowercased().hasPrefix($0) }
                    let alt = img.alt.isEmpty ? (generic ? "" : stem) : img.alt
                    out += "![" + escape(alt, inTable: inTable) + "](" + destination(path, inTable: inTable) + ")"
                }
                continue
            }
            let text = run.text.replacingOccurrences(of: "\n", with: " ")
            let core = text.trimmingCharacters(in: .whitespaces)
            if core.isEmpty { pendingSpace += text; continue }
            // A bare web address that links to itself is written as an autolink.
            if let link = run.link, core == link || "mailto:" + core == link, link.hasPrefix("http") || link.hasPrefix("mailto:"),
               !run.code, !core.contains(">"), !core.contains(" "), !(inTable && core.contains("|")) {
                let rest = marks.filter { if case .link = $0 { return false } else { return true } }
                transition(to: rest)
                out += String(text.prefix { $0 == " " })
                for m in rest where !stack.contains(m) { out += open(m); stack.append(m) }
                out += "<" + core + ">"
                pendingSpace = String(text.reversed().prefix { $0 == " " })
                continue
            }
            let lead = String(text.prefix { $0 == " " || $0 == "\t" })
            let trail = String(text.reversed().prefix { $0 == " " || $0 == "\t" })
            // Spaces before the run belong outside any marker that opens or closes here.
            transition(to: marks)
            out += lead
            for m in marks where !stack.contains(m) { out += open(m); stack.append(m) }
            if run.code {
                // GFM splits table rows at every unescaped '|', code spans included.
                out += inTable ? codeSpan(core).replacingOccurrences(of: "|", with: "\\|") : codeSpan(core)
            } else {
                out += escape(core, inTable: inTable)
                    .replacingOccurrences(of: "\u{2028}", with: inTable ? "<br>" : "\\\n")
            }
            pendingSpace = trail
        }
        while let top = stack.popLast() { out += close(top) }
        out += pendingSpace
        return out.replacingOccurrences(of: "\u{2028}", with: inTable ? "<br>" : "\\\n")
    }

    private static func destination(_ url: String, inTable: Bool = false) -> String {
        var clean = url.replacingOccurrences(of: "\n", with: "")
        if inTable { clean = clean.replacingOccurrences(of: "|", with: "%7C") }
        if clean.contains(" ") || clean.contains("(") || clean.contains(")") || clean.contains("<") {
            return "<" + clean.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E") + ">"
        }
        return clean
    }

    private static func codeSpan(_ s: String) -> String {
        let longest = s.components(separatedBy: CharacterSet(charactersIn: "`").inverted).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: longest + 1)
        let pad = s.hasPrefix("`") || s.hasSuffix("`") ? " " : ""
        return fence + pad + s.replacingOccurrences(of: "\u{2028}", with: " ") + pad + fence
    }

    /// Backslash-escapes characters Markdown would read as syntax. Underscores inside words are left
    /// alone (they never make emphasis), so snake_case stays readable.
    static func escape(_ s: String, inTable: Bool = false) -> String {
        var out = ""
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            switch c {
            case "\\", "`", "*", "[", "]", "~":
                out.append("\\"); out.append(c)
            case "_":
                let before = i > 0 ? chars[i - 1] : " ", after = i + 1 < chars.count ? chars[i + 1] : " "
                if !(before.isLetter || before.isNumber) || !(after.isLetter || after.isNumber) { out.append("\\") }
                out.append(c)
            case "<":
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if next.isLetter || next == "/" || next == "!" || next == "?" { out += "&lt;" } else { out.append(c) }
            case "|":
                if inTable { out += "\\|" } else { out.append(c) }
            case "&":
                let rest = String(chars[i...].prefix(12))
                if rest.range(of: "^&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);", options: .regularExpression) != nil { out += "&amp;" }
                else { out.append(c) }
            default:
                out.append(c)
            }
        }
        return out
    }
}
