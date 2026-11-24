import AppKit

// The document model every EbooksAndPages conversion goes through: EPUB chapters, Pages documents,
// text documents and PDFs are read into a `Doc` (headings, paragraphs, list items, tables, images),
// and the writers below turn a `Doc` into plain text, Markdown, XHTML or rich text.

extension EbooksAndPages {
    /// A run of text with one set of inline styles. Line breaks inside a paragraph are "\n".
    struct Run: Equatable {
        var text: String
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var code = false
        /// 1 superscript, -1 subscript.
        var script = 0
        var link: String? = nil
        /// Optional source formatting (Pages, rich text). Only rich outputs use it.
        var font: String? = nil
        var size: Double? = nil
        var color: String? = nil

        func sameStyle(as o: Run) -> Bool {
            bold == o.bold && italic == o.italic && underline == o.underline && strike == o.strike && code == o.code
                && script == o.script && link == o.link && font == o.font && size == o.size && color == o.color
        }
    }

    enum Align: String { case natural, left, center, right, justify }

    /// What kind of paragraph this is, beyond its text.
    enum Role { case body, subtitle, caption, quote }

    /// An image width (points or CSS pixels) worth keeping: finite and between 1 and 10 000.
    static func usableWidth(_ width: Double?) -> Double? {
        guard let w = width, w.isFinite, w >= 1, w <= 10_000 else { return nil }
        return w
    }

    /// List nesting the writers lay out (deeper levels are drawn at this one).
    static let maxListLevel = 8

    enum Block {
        case heading(level: Int, runs: [Run])
        case paragraph(runs: [Run], align: Align, role: Role)
        case item(runs: [Run], ordered: Bool, level: Int)
        case code(String)
        case image(id: String, alt: String, width: Double?)
        /// Rows of cells; the first row is a header row when `header` is true.
        case table(rows: [[[Run]]], header: Bool)
        case rule
        case pageBreak

        static func para(_ runs: [Run]) -> Block { .paragraph(runs: runs, align: .natural, role: .body) }

        var runs: [Run] {
            switch self {
            case .heading(_, let r), .paragraph(let r, _, _), .item(let r, _, _): return r
            case .table(let rows, _): return rows.flatMap { $0.flatMap { $0 } }
            case .code(let s): return [Run(text: s)]
            default: return []
            }
        }

        var plainText: String { runs.map(\.text).joined() }
    }

    /// An image carried by a document, stored once and referenced by id from `.image` blocks.
    struct Picture {
        var data: Data
        var ext: String
        var mime: String {
            switch ext {
            case "jpg", "jpeg": return "image/jpeg"
            case "png": return "image/png"
            case "gif": return "image/gif"
            case "svg": return "image/svg+xml"
            case "webp": return "image/webp"
            default: return "image/\(ext)"
            }
        }
    }

    struct Doc {
        var title: String?
        var author: String?
        var language: String?
        var blocks: [Block] = []
        var pictures: [String: Picture] = [:]
        /// Explicit chapters (PDF pages, EPUB spine items). When nil, chapters come from the headings.
        var chapters: [(title: String, range: Range<Int>)]? = nil

        /// Stores an image and returns its id. Images that ImageIO can't read are converted when possible
        /// (TIFF, HEIC, BMP → PNG/JPEG) so every output format can show them; nil if it isn't an image.
        mutating func addPicture(_ data: Data, ext rawExt: String) -> String? {
            var ext = rawExt.lowercased()
            var payload = data
            if ext == "jpeg" { ext = "jpg" }
            if !["jpg", "png", "gif", "svg", "webp"].contains(ext) {
                guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff) else { return nil }
                let opaque = !rep.hasAlpha
                guard let converted = rep.representation(using: opaque ? .jpeg : .png,
                                                         properties: opaque ? [.compressionFactor: 0.88] : [:]) else { return nil }
                payload = converted
                ext = opaque ? "jpg" : "png"
            }
            let id = "img\(String(format: "%03d", pictures.count + 1))"
            pictures[id] = Picture(data: payload, ext: ext)
            return id
        }

        var hasText: Bool {
            blocks.contains { !$0.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        /// Appends another document's blocks (and images) after this one's.
        mutating func append(_ other: Doc) {
            var map: [String: String] = [:]
            for (id, pic) in other.pictures.sorted(by: { $0.key < $1.key }) {
                if let new = addPicture(pic.data, ext: pic.ext) { map[id] = new }
            }
            for block in other.blocks {
                if case let .image(id, alt, width) = block {
                    if let new = map[id] { blocks.append(.image(id: new, alt: alt, width: width)) }
                } else {
                    blocks.append(block)
                }
            }
        }
    }
}

// MARK: - Runs and blocks

extension EbooksAndPages {
    /// Item numbers for nested lists: a level restarts when a shallower item or a list of the other kind
    /// comes along.
    struct ListCounters {
        private var counts: [Int: (ordered: Bool, n: Int)] = [:]
        mutating func next(level: Int, ordered: Bool) -> Int {
            for k in counts.keys where k > level { counts[k] = nil }
            let n = counts[level].map { $0.ordered == ordered ? $0.n + 1 : 1 } ?? 1
            counts[level] = (ordered, n)
            return n
        }
    }
}

extension EbooksAndPages {
    /// No page break at the start or end, and never two in a row.
    static func tidyPageBreaks(_ blocks: [Block]) -> [Block] {
        var out: [Block] = []
        for b in blocks {
            if case .pageBreak = b {
                if out.isEmpty { continue }
                if case .pageBreak = out.last! { continue }
            }
            out.append(b)
        }
        while let last = out.last, case .pageBreak = last { out.removeLast() }
        return out
    }
}

extension EbooksAndPages {
    /// Joins neighbouring runs that share a style and drops empty ones.
    static func merged(_ runs: [Run]) -> [Run] {
        var out: [Run] = []
        for r in runs where !r.text.isEmpty {
            if let last = out.last, last.sameStyle(as: r) { out[out.count - 1].text += r.text } else { out.append(r) }
        }
        return out
    }

    /// Trims whitespace (not line breaks inside) from both ends of a paragraph.
    static func trimmed(_ runs: [Run]) -> [Run] {
        var r = merged(runs)
        while let first = r.first {
            let t = String(first.text.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" }))
            if t.isEmpty { r.removeFirst() } else { r[0].text = t; break }
        }
        while let last = r.last {
            var t = last.text
            while let c = t.last, c == " " || c == "\t" || c == "\n" { t.removeLast() }
            if t.isEmpty { r.removeLast() } else { r[r.count - 1].text = t; break }
        }
        return r
    }
}

// MARK: - Plain text

extension EbooksAndPages {
    static func plainText(_ doc: Doc) -> String {
        var out = ""
        var counters = ListCounters()
        var previousWasItem = false
        for block in doc.blocks {
            var isItem = false
            let text: String
            switch block {
            case .heading(_, let runs), .paragraph(let runs, _, _):
                text = runs.map(\.text).joined()
            case .item(let runs, let ordered, let level):
                isItem = true
                let n = counters.next(level: level, ordered: ordered)
                text = String(repeating: "    ", count: max(0, min(level, maxListLevel))) + (ordered ? "\(n). " : "• ") + runs.map(\.text).joined()
            case .code(let s):
                text = s
            case .image(_, let alt, _):
                text = alt.isEmpty ? "" : "[\(alt)]"
            case .table(let rows, _):
                text = rows.map { $0.map { $0.map(\.text).joined().replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }
                    .joined(separator: "\n")
            case .rule:
                text = "* * *"
            case .pageBreak:
                text = "\u{0C}"
            }
            if !isItem { counters = ListCounters() }
            if text.isEmpty { continue }
            // List items sit on consecutive lines; everything else is separated by a blank line.
            if !out.isEmpty { out += (isItem && previousWasItem) ? "\n" : "\n\n" }
            out += text
            previousWasItem = isItem
        }
        return out + "\n"
    }
}

// MARK: - Markdown

extension EbooksAndPages {
    /// CommonMark-style Markdown. `imagePath` gives the link for an image id, or nil to leave it out.
    static func markdown(_ doc: Doc, imagePath: (String) -> String? = { _ in nil }) -> String {
        var out: [String] = []
        var counters = ListCounters()
        var previousItem = false
        for block in doc.blocks {
            var isItem = false
            var text: String?
            switch block {
            case .heading(let level, let runs):
                let t = inlineMarkdown(runs.map { var r = $0; r.text = r.text.replacingOccurrences(of: "\n", with: " "); return r })
                text = String(repeating: "#", count: min(6, max(1, level))) + " " + t
            case .paragraph(let runs, _, let role):
                let t = inlineMarkdown(runs)
                if t.isEmpty { continue }
                text = role == .quote ? t.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n") : t
            case .item(let runs, let ordered, let level):
                isItem = true
                let n = counters.next(level: level, ordered: ordered)
                let marker = ordered ? "\(n). " : "- "
                let indent = String(repeating: "    ", count: max(0, min(level, maxListLevel)))
                let body = inlineMarkdown(runs).replacingOccurrences(of: "\n", with: "\n" + indent + "    ")
                text = indent + marker + body
            case .code(let s):
                let fence = s.contains("```") ? "~~~~" : "```"
                text = fence + "\n" + s + "\n" + fence
            case .image(let id, let alt, _):
                if let path = imagePath(id) { text = "![\(escapeMarkdown(alt))](\(path.replacingOccurrences(of: " ", with: "%20")))" }
            case .table(let rows, let header):
                guard let first = rows.first else { continue }
                let columns = rows.map(\.count).max() ?? first.count
                func row(_ cells: [[Run]]) -> String {
                    let padded = cells + Array(repeating: [], count: max(0, columns - cells.count))
                    return "| " + padded.map {
                        inlineMarkdown($0).replacingOccurrences(of: "\n", with: "<br>").replacingOccurrences(of: "|", with: "\\|")
                    }.joined(separator: " | ") + " |"
                }
                var lines: [String] = []
                let head = header ? first : Array(repeating: [Run](), count: columns)
                lines.append(row(head))
                lines.append("|" + Array(repeating: " --- |", count: columns).joined())
                for r in (header ? Array(rows.dropFirst()) : rows) { lines.append(row(r)) }
                text = lines.joined(separator: "\n")
            case .rule, .pageBreak:
                if out.isEmpty || out.last == "---" { continue }   // nothing to separate yet
                text = "---"
            }
            if !isItem { counters = ListCounters() }
            guard let text else { continue }
            if isItem && previousItem, !out.isEmpty { out[out.count - 1] += "\n" + text } else { out.append(text) }
            previousItem = isItem
        }
        return out.joined(separator: "\n\n") + "\n"
    }

    static func escapeMarkdown(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\`*_[]<>#".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    private static func inlineMarkdown(_ runs: [Run]) -> String {
        var out = ""
        for r in merged(runs) {
            if r.code {
                let t = r.text.replacingOccurrences(of: "\n", with: " ")
                out += t.contains("`") ? "`` \(t) ``" : "`\(t)`"
                continue
            }
            var t = escapeMarkdown(r.text)
            // Keep markers tight around the words: "** bold**" is not bold in CommonMark.
            let lead = String(t.prefix(while: { $0 == " " }))
            t.removeFirst(lead.count)
            var trail = ""
            while t.last == " " { trail.append(" "); t.removeLast() }
            if t.isEmpty { out += lead + trail; continue }
            if r.strike { t = "~~\(t)~~" }
            if r.italic { t = "*\(t)*" }
            if r.bold { t = "**\(t)**" }
            if r.script == 1 { t = "<sup>\(t)</sup>" } else if r.script == -1 { t = "<sub>\(t)</sub>" }
            if let link = r.link, !link.isEmpty, !link.hasPrefix("#") { t = "[\(t)](\(link.replacingOccurrences(of: " ", with: "%20")))" }
            out += lead + t + trail
        }
        // A hard line break inside a paragraph.
        return out.replacingOccurrences(of: "\n", with: "\\\n")
    }
}

// MARK: - XHTML

extension EbooksAndPages {
    static func escapeXML(_ s: String, attribute: Bool = false) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            default:
                // Characters XML 1.0 forbids (most C0 controls, U+FFFE/FFFF) are dropped.
                let v = u.value
                if v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D { continue }
                if v == 0xFFFE || v == 0xFFFF { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// XHTML for a list of blocks (well-formed XML, also valid HTML5). `imageSrc` maps image ids to URLs;
    /// `rich` keeps source fonts and colours (for HTML and PDF output, not for EPUB).
    static func xhtmlBody(_ blocks: [Block], imageSrc: (String) -> String?, rich: Bool = false) -> String {
        var out = ""
        // Open lists, innermost last; `itemOpen` is whether its last <li> still needs closing.
        var stack: [(ordered: Bool, level: Int, itemOpen: Bool)] = []
        func closeTop() {
            guard let top = stack.popLast() else { return }
            out += (top.itemOpen ? "</li>\n" : "") + "</\(top.ordered ? "ol" : "ul")>\n"
        }
        for block in blocks {
            if case let .item(runs, ordered, rawLevel) = block {
                let level = max(0, min(rawLevel, 8))
                while let top = stack.last, top.level > level { closeTop() }
                if let top = stack.last, top.level == level, top.ordered != ordered { closeTop() }
                if let top = stack.last, top.level == level, top.itemOpen {
                    out += "</li>\n"
                    stack[stack.count - 1].itemOpen = false
                }
                while (stack.last?.level ?? -1) < level {
                    // A nested list lives inside an item of its parent; make one if a level was skipped.
                    if let parent = stack.last, !parent.itemOpen {
                        out += "<li class=\"nested\">"
                        stack[stack.count - 1].itemOpen = true
                    }
                    let l = (stack.last?.level ?? -1) + 1
                    out += "<\(ordered ? "ol" : "ul")>\n"
                    stack.append((ordered, l, false))
                }
                out += "<li>" + inlineXHTML(runs, rich: rich)
                stack[stack.count - 1].itemOpen = true
                continue
            }
            while !stack.isEmpty { closeTop() }
            switch block {
            case .heading(let level, let runs):
                let l = min(6, max(1, level))
                out += "<h\(l)>\(inlineXHTML(runs, rich: rich))</h\(l)>\n"
            case .paragraph(let runs, let align, let role):
                var classes: [String] = []
                switch role {
                case .subtitle: classes.append("subtitle")
                case .caption: classes.append("caption")
                case .quote: classes.append("quote")
                case .body: break
                }
                let style = (align == .natural || align == .left) ? "" : " style=\"text-align: \(align.rawValue)\""
                let cls = classes.isEmpty ? "" : " class=\"\(classes.joined(separator: " "))\""
                let inner = inlineXHTML(runs, rich: rich)
                if role == .quote {
                    out += "<blockquote><p\(style)>\(inner)</p></blockquote>\n"
                } else {
                    out += "<p\(cls)\(style)>\(inner.isEmpty ? "&#160;" : inner)</p>\n"
                }
            case .code(let s):
                out += "<pre><code>\(escapeXML(s))</code></pre>\n"
            case .image(let id, let alt, let width):
                guard let src = imageSrc(id) else { continue }
                let w = usableWidth(width).map { " style=\"width: \(Int($0.rounded()))px\"" } ?? ""
                out += "<div class=\"figure\"><img src=\"\(escapeXML(src, attribute: true))\" alt=\"\(escapeXML(alt, attribute: true))\"\(w)/></div>\n"
            case .table(let rows, let header):
                out += "<table>\n"
                for (i, row) in rows.enumerated() {
                    let tag = header && i == 0 ? "th" : "td"
                    out += "<tr>" + row.map { "<\(tag)>\(inlineXHTML($0, rich: rich))</\(tag)>" }.joined() + "</tr>\n"
                }
                out += "</table>\n"
            case .rule:
                out += "<hr/>\n"
            case .pageBreak:
                out += "<div class=\"page-break\"></div>\n"
            case .item:
                break
            }
        }
        while !stack.isEmpty { closeTop() }
        return out
    }

    static func inlineXHTML(_ runs: [Run], rich: Bool) -> String {
        var out = ""
        for r in merged(runs) {
            var t = escapeXML(r.text).replacingOccurrences(of: "\n", with: "<br/>")
                .replacingOccurrences(of: "\t", with: " ")
            if r.code { t = "<code>\(t)</code>" }
            if r.strike { t = "<s>\(t)</s>" }
            if r.underline && r.link == nil { t = "<u>\(t)</u>" }
            if r.italic { t = "<em>\(t)</em>" }
            if r.bold { t = "<strong>\(t)</strong>" }
            if r.script == 1 { t = "<sup>\(t)</sup>" } else if r.script == -1 { t = "<sub>\(t)</sub>" }
            if rich {
                var css: [String] = []
                if let f = r.font, !f.isEmpty { css.append("font-family: '\(cssFamily(f))'") }
                if let c = r.color, c.uppercased() != "#000000" { css.append("color: \(c)") }
                if !css.isEmpty { t = "<span style=\"\(escapeXML(css.joined(separator: "; "), attribute: true))\">\(t)</span>" }
            }
            if let link = r.link, !link.isEmpty {
                t = "<a href=\"\(escapeXML(link, attribute: true))\">\(t)</a>"
            }
            out += t
        }
        return out
    }

    /// A PostScript font name ("Futura-Bold") as a CSS family the browser can match ("Futura").
    static func cssFamily(_ name: String) -> String {
        if let font = NSFont(name: name, size: 12), let family = font.familyName { return family.replacingOccurrences(of: "'", with: "") }
        return name.split(separator: "-").first.map(String.init)?.replacingOccurrences(of: "'", with: "") ?? name
    }

    /// The stylesheet used for generated EPUB chapters and HTML/PDF exports.
    static let bookCSS = """
    body { font-family: Georgia, "Iowan Old Style", "Times New Roman", serif; line-height: 1.45; margin: 0 5%; }
    h1, h2, h3, h4, h5, h6 { font-family: "Helvetica Neue", Helvetica, Arial, sans-serif; line-height: 1.2; page-break-after: avoid; break-after: avoid; }
    h1 { font-size: 1.8em; margin: 1.2em 0 0.6em; }
    h2 { font-size: 1.45em; margin: 1.1em 0 0.5em; }
    h3 { font-size: 1.2em; margin: 1em 0 0.4em; }
    p { margin: 0 0 0.7em; }
    p.subtitle { font-size: 1.25em; font-style: italic; }
    p.caption { font-size: 0.9em; color: #555; text-align: center; }
    blockquote { margin: 0.8em 2em; color: #333; }
    pre { font-family: Menlo, Consolas, monospace; font-size: 0.85em; white-space: pre-wrap; background: #f4f4f4; padding: 0.6em; }
    code { font-family: Menlo, Consolas, monospace; font-size: 0.9em; }
    .figure { text-align: center; margin: 1em 0; page-break-inside: avoid; break-inside: avoid; }
    img { max-width: 100%; height: auto; }
    table { border-collapse: collapse; margin: 1em 0; max-width: 100%; }
    th, td { border: 1px solid #999; padding: 0.3em 0.5em; vertical-align: top; text-align: left; }
    li.nested { list-style-type: none; }
    .page-break { page-break-after: always; break-after: page; height: 0; }
    """

    /// Whether a language is written right to left (Arabic, Hebrew, Persian, Urdu and a few more).
    static func isRightToLeft(_ language: String?) -> Bool {
        let base = (language ?? "").lowercased().split(separator: "-").first.map(String.init) ?? ""
        return ["ar", "he", "iw", "fa", "ur", "yi", "ps", "sd", "ug", "dv", "ckb"].contains(base)
    }

    /// A complete XHTML document (for EPUB chapters and standalone HTML).
    static func xhtmlDocument(title: String, language: String?, body: String, css: String? = nil,
                              stylesheetHref: String? = nil, epub: Bool = false) -> String {
        let lang = (language ?? "en")
        let dir = isRightToLeft(language) ? " dir=\"rtl\"" : ""
        let ns = epub ? " xmlns:epub=\"http://www.idpf.org/2007/ops\"" : ""
        var head = "<meta charset=\"utf-8\"/>\n<title>\(escapeXML(title))</title>\n"
        if let stylesheetHref { head += "<link rel=\"stylesheet\" type=\"text/css\" href=\"\(escapeXML(stylesheetHref, attribute: true))\"/>\n" }
        if let css { head += "<style type=\"text/css\">\n\(css)\n</style>\n" }   // our own CSS: no &, < or >
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml"\(ns) xml:lang="\(escapeXML(lang, attribute: true))" lang="\(escapeXML(lang, attribute: true))"\(dir)>
        <head>
        \(head)</head>
        <body>
        \(body)</body>
        </html>

        """
    }
}

// MARK: - Rich text

extension EbooksAndPages {
    /// Rich text for the DOCX and RTF writers (DocumentIO). Headings get larger bold fonts and a header
    /// level, lists get text lists, tables become NSTextTable cells, images become attachments.
    /// Page breaks are form feeds (U+000C), which DocumentIO's RTF and DOCX writers turn into page breaks;
    /// `pageBreaks: false` leaves them out.
    static func attributedString(_ doc: Doc, pageBreaks: Bool = true) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let bodySize: CGFloat = 12
        let headingSizes: [CGFloat] = [24, 18, 15, 13, 12, 12]
        var counters = ListCounters()

        func font(_ r: Run, base: CGFloat, forceBold: Bool = false) -> NSFont {
            let size = r.size.map { CGFloat($0) } ?? base
            var f = (r.font.flatMap { NSFont(name: $0, size: size) }) ?? NSFont(name: r.code ? "Menlo" : "Georgia", size: size)
                ?? NSFont.systemFont(ofSize: size)
            var traits: NSFontTraitMask = []
            if r.bold || forceBold { traits.insert(.boldFontMask) }
            if r.italic { traits.insert(.italicFontMask) }
            if !traits.isEmpty { f = NSFontManager.shared.convert(f, toHaveTrait: traits) }
            return f
        }
        func attrs(_ r: Run, base: CGFloat, para: NSParagraphStyle, forceBold: Bool = false) -> [NSAttributedString.Key: Any] {
            var a: [NSAttributedString.Key: Any] = [.font: font(r, base: base, forceBold: forceBold), .paragraphStyle: para]
            if r.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if r.strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if r.script != 0 { a[.superscript] = r.script }
            if let link = r.link, !link.isEmpty, !link.hasPrefix("#"), let url = URL(string: link) { a[.link] = url }
            if let c = r.color, let color = NSColor(hex: c) { a[.foregroundColor] = color }
            return a
        }
        func append(_ runs: [Run], base: CGFloat, para: NSParagraphStyle, forceBold: Bool = false, prefix: String = "") {
            if !prefix.isEmpty { out.append(NSAttributedString(string: prefix, attributes: attrs(Run(text: ""), base: base, para: para))) }
            for r in merged(runs) {
                out.append(NSAttributedString(string: r.text.replacingOccurrences(of: "\n", with: "\u{2028}"),
                                              attributes: attrs(r, base: base, para: para, forceBold: forceBold)))
            }
            out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: para, .font: NSFont(name: "Georgia", size: base) ?? NSFont.systemFont(ofSize: base)]))
        }
        func style(_ align: Align, spacing: CGFloat = 6, before: CGFloat = 0) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            switch align {
            case .center: p.alignment = .center
            case .right: p.alignment = .right
            case .justify: p.alignment = .justified
            case .left: p.alignment = .left
            case .natural: p.alignment = .natural
            }
            p.paragraphSpacing = spacing
            p.paragraphSpacingBefore = before
            return p
        }

        for block in doc.blocks {
            if case .item = block {} else { counters = ListCounters() }
            switch block {
            case .heading(let level, let runs):
                let l = min(6, max(1, level))
                let p = style(.natural, spacing: 6, before: l <= 2 ? 12 : 8)
                p.headerLevel = l
                append(runs.map { var r = $0; r.size = nil; return r }, base: headingSizes[l - 1], para: p, forceBold: true)
            case .paragraph(let runs, let align, let role):
                let p = style(align)
                var rs = runs
                if role == .quote { p.headIndent = 36; p.firstLineHeadIndent = 36; p.tailIndent = -36 }
                if role == .subtitle || role == .quote { rs = rs.map { var r = $0; r.italic = true; return r } }
                append(rs, base: role == .caption ? 10 : bodySize, para: p)
            case .item(let runs, let ordered, let rawLevel):
                let level = max(0, min(rawLevel, maxListLevel))
                let n = counters.next(level: level, ordered: ordered)
                let p = style(.natural, spacing: 2)
                let list = NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)
                p.textLists = Array(repeating: list, count: level + 1)
                // A hanging indent: the marker at the start of the line, the text at the indent (Word treats
                // the hanging indent as a tab stop, and Cocoa's DOCX writer doesn't write tab stops).
                let indent = CGFloat(level + 1) * 36
                p.headIndent = indent
                p.firstLineHeadIndent = indent - 36
                p.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                let marker = ordered ? "\(n).\t" : "•\t"
                append(runs, base: bodySize, para: p, prefix: marker)
            case .code(let s):
                let p = style(.natural)
                append([Run(text: s, code: true)], base: 10, para: p)
            case .image(let id, let alt, _):
                guard let pic = doc.pictures[id] else { continue }
                let wrapper = FileWrapper(regularFileWithContents: pic.data)
                wrapper.preferredFilename = "\(id).\(pic.ext)"
                let attachment = NSTextAttachment(fileWrapper: wrapper)
                if let image = NSImage(data: pic.data) {
                    // Fit to a 6-inch text column.
                    let scale = min(1, 432 / max(image.size.width, 1))
                    attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
                }
                let p = style(.center)
                let s = NSMutableAttributedString(attachment: attachment)
                s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
                if !alt.isEmpty { s.addAttribute(.toolTip, value: alt, range: NSRange(location: 0, length: s.length)) }
                out.append(s)
                out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: p]))
            case .table(let rows, let header):
                let columns = rows.map(\.count).max() ?? 0
                guard columns > 0 else { continue }
                let table = NSTextTable()
                table.numberOfColumns = columns
                table.collapsesBorders = true
                for (r, row) in rows.enumerated() {
                    for c in 0..<columns {
                        let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                        cell.setBorderColor(.gray)
                        cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                        cell.setWidth(4, type: .absoluteValueType, for: .padding)
                        let p = style(.natural, spacing: 0)
                        p.textBlocks = [cell]
                        append(c < row.count ? row[c] : [], base: bodySize, para: p, forceBold: header && r == 0)
                    }
                }
            case .rule:
                append([Run(text: "* * *")], base: bodySize, para: style(.center))
            case .pageBreak:
                if pageBreaks { out.append(NSAttributedString(string: "\u{0C}", attributes: [.paragraphStyle: style(.natural)])) }
            }
        }
        return out
    }
}

// MARK: - Chapters

extension EbooksAndPages {
    struct Chapter {
        var title: String
        var blocks: [Block]
    }

    /// Splits a document into chapters: explicit chapters when it has them, otherwise at the top-level
    /// headings (the highest level that occurs more than once, so a lone document title doesn't count),
    /// and very long stretches are cut into parts.
    static func chapters(of doc: Doc, maxCharacters: Int = 120_000) -> [Chapter] {
        let fallbackTitle = doc.title ?? "Text"
        var result: [Chapter] = []
        if let explicit = doc.chapters, !explicit.isEmpty {
            for c in explicit {
                let blocks = Array(doc.blocks[c.range.clamped(to: 0..<doc.blocks.count)])
                result.append(Chapter(title: c.title, blocks: blocks))
            }
        } else {
            var levels: [Int: Int] = [:]
            for case let .heading(level, runs) in doc.blocks where !plain(runs).isEmpty { levels[level, default: 0] += 1 }
            let splitLevel = levels.keys.sorted().first { levels[$0]! >= 2 } ?? levels.keys.min()
            var current = Chapter(title: "", blocks: [])
            for block in doc.blocks {
                if case let .heading(level, runs) = block, let splitLevel, level <= splitLevel, !plain(runs).isEmpty {
                    if current.blocks.contains(where: { !isBlank($0) }) { result.append(current) }
                    current = Chapter(title: plain(runs), blocks: [])
                }
                if case .pageBreak = block, current.blocks.isEmpty { continue }
                current.blocks.append(block)
            }
            if current.blocks.contains(where: { !isBlank($0) }) || result.isEmpty { result.append(current) }
            for i in result.indices where result[i].title.isEmpty {
                result[i].title = i == 0 ? fallbackTitle : "Part \(i + 1)"
            }
        }
        // Keep each chapter file a reasonable size for reading systems.
        var sized: [Chapter] = []
        for chapter in result {
            var size = 0
            var part = Chapter(title: chapter.title, blocks: [])
            var n = 1
            for block in chapter.blocks {
                let s = block.plainText.utf8.count + 40
                if size + s > maxCharacters, !part.blocks.isEmpty {
                    sized.append(part)
                    n += 1
                    part = Chapter(title: "\(chapter.title) (\(n))", blocks: [])
                    size = 0
                }
                part.blocks.append(block)
                size += s
            }
            sized.append(part)
        }
        // Trailing page breaks are noise at the end of a chapter.
        for i in sized.indices {
            while let last = sized[i].blocks.last, case .pageBreak = last { sized[i].blocks.removeLast() }
        }
        return sized
    }

    static func plain(_ runs: [Run]) -> String {
        runs.map(\.text).joined().replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isBlank(_ b: Block) -> Bool {
        switch b {
        case .image, .table, .rule, .code: return false
        case .pageBreak: return true
        default: return b.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
