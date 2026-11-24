import AppKit
import PDFKit

// Reading the sources a book can be made from: text documents (through DocumentIO, except HTML,
// Markdown and plain text, which are read directly so their headings survive), rich text and PDFs.

private typealias Run = EbooksAndPages.Run
private typealias Block = EbooksAndPages.Block
private typealias Doc = EbooksAndPages.Doc

extension EbooksAndPages {
    // MARK: Text documents

    static func readTextDocument(_ url: URL) throws -> Doc {
        let ext = Ext.of(url)
        var doc: Doc
        switch ext {
        case "html", "htm", "xhtml":
            let data = try Data(contentsOf: url)
            guard let markup = parseMarkup(data) else { throw ConversionError.unreadable(url.lastPathComponent) }
            doc = Doc()
            let base = url.deletingLastPathComponent()
            var cache: [String: String] = [:]
            var importer = HTMLImporter { src in
                // Local images only; nothing is ever fetched.
                let isFileURL = src.lowercased().hasPrefix("file:")
                guard !Package.isRemote(src) || isFileURL else { return nil }
                guard let file = isFileURL ? URL(string: src) : base.appendingPathComponent(src.removingPercentEncoding ?? src)
                else { return nil }
                let key = file.standardizedFileURL.path
                if let id = cache[key] { return id }
                guard let bytes = try? Data(contentsOf: file), let id = doc.addPicture(bytes, ext: file.pathExtension) else { return nil }
                cache[key] = id
                return id
            }
            for link in elements(markup, named: "link") where (attribute(link, "rel") ?? "").lowercased().contains("stylesheet") {
                if let href = attribute(link, "href"), !Package.isRemote(href),
                   let css = try? String(contentsOf: base.appendingPathComponent(href.removingPercentEncoding ?? href), encoding: .utf8) {
                    importer.css.add(css)
                }
            }
            let blocks = importer.importBody(of: markup)
            doc.blocks = blocks
            doc.title = firstElement(markup, named: "title").map(textContent).flatMap { $0.isEmpty ? nil : $0 }
            for meta in elements(markup, named: "meta") where (attribute(meta, "name") ?? "").lowercased() == "author" {
                doc.author = attribute(meta, "content")
            }
            doc.language = markup.rootElement().flatMap { attribute($0, "lang") }
        case "md", "markdown", "mdown", "mkd":
            doc = markdownDocument(decodeText(try Data(contentsOf: url)), base: url.deletingLastPathComponent())
        case "txt", "text":
            doc = plainTextDocument(decodeText(try Data(contentsOf: url)))
        default:
            doc = attributedDocument(try DocumentIO.read(url))
            let meta = documentMetadata(url)
            doc.title = meta.title
            doc.author = meta.author
        }
        if doc.title == nil || doc.title!.isEmpty {
            // A document that opens with its title as the only top-level heading uses it.
            if case let .heading(1, runs)? = doc.blocks.first(where: { !$0.plainText.trimmingCharacters(in: .whitespaces).isEmpty }) {
                doc.title = plain(runs)
            }
        }
        return doc
    }

    /// Title and author stored in a document's own metadata (DOCX core properties, ODT meta.xml, RTF \info).
    static func documentMetadata(_ url: URL) -> (title: String?, author: String?) {
        let ext = Ext.of(url)
        func pick(_ doc: XMLDocument, _ names: [String]) -> String? {
            for n in names {
                if let e = firstElement(doc, named: n) {
                    let t = textContent(e)
                    if !t.isEmpty { return t }
                }
            }
            return nil
        }
        if ext == "docx" || ext == "odt", let zip = try? ZipReader(url: url) {
            let part = ext == "docx" ? "docProps/core.xml" : "meta.xml"
            if let data = try? zip.read(part), let xml = parseMarkup(data) {
                return (pick(xml, ["title"]), pick(xml, ["creator", "initial-creator"]))
            }
        }
        if ext == "rtf", let data = try? Data(contentsOf: url) {
            let s = String(decoding: data.prefix(16384), as: UTF8.self)
            func group(_ key: String) -> String? {
                guard let r = s.range(of: "{\\\\\(key)\\s+([^}]*)\\}", options: .regularExpression) else { return nil }
                let inner = s[r].dropFirst(key.count + 2).dropLast()
                let t = inner.trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : t
            }
            return (group("title"), group("author"))
        }
        return (nil, nil)
    }

    // MARK: Rich text

    /// Rich text → blocks. Headings come from the header level the importer set, else from font size:
    /// short paragraphs set clearly larger than the body text (or bold at body size, standing alone).
    static func attributedDocument(_ text: NSAttributedString) -> Doc {
        var doc = Doc()
        let ns = text.string as NSString
        guard ns.length > 0 else { return doc }

        // Body size: the font size that covers the most characters.
        var sizeCount: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: ns.length)) { value, range, _ in
            if let f = value as? NSFont { sizeCount[(f.pointSize * 2).rounded() / 2, default: 0] += range.length }
        }
        let bodySize = sizeCount.max { $0.value < $1.value }?.key ?? 12
        struct Para { var runs: [Run]; var size: CGFloat; var bold: Bool; var style: NSParagraphStyle?; var images: [String] }
        var paras: [Para] = []

        var start = 0
        while start < ns.length {
            var end = 0, contentsEnd = 0
            ns.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            let range = NSRange(location: start, length: contentsEnd - start)
            var runs: [Run] = []
            var maxSize: CGFloat = 0
            var allBold = true
            var images: [String] = []
            var style: NSParagraphStyle?
            text.enumerateAttributes(in: range) { attrs, r, _ in
                var s = ns.substring(with: r)
                if style == nil { style = attrs[.paragraphStyle] as? NSParagraphStyle }
                if let attachment = attrs[.attachment] as? NSTextAttachment {
                    if let id = picture(from: attachment, into: &doc) { images.append(id) }
                    s = s.replacingOccurrences(of: "\u{FFFC}", with: "")
                }
                guard !s.isEmpty else { return }
                let font = attrs[.font] as? NSFont
                let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                var run = Run(text: s.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{0B}", with: "\n"))
                run.bold = traits.contains(.boldFontMask)
                run.italic = traits.contains(.italicFontMask)
                run.underline = ((attrs[.underlineStyle] as? Int) ?? 0) != 0
                run.strike = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
                if let sup = attrs[.superscript] as? Int, sup != 0 { run.script = sup > 0 ? 1 : -1 }
                if let link = attrs[.link] { run.link = (link as? URL)?.absoluteString ?? (link as? String) }
                if let f = font, f.isFixedPitch || f.fontName.lowercased().contains("mono") || f.fontName.hasPrefix("Courier") {
                    run.code = true
                }
                if !s.trimmingCharacters(in: .whitespaces).isEmpty {
                    maxSize = max(maxSize, font?.pointSize ?? bodySize)
                    if !run.bold { allBold = false }
                }
                runs.append(run)
            }
            paras.append(Para(runs: merged(runs), size: maxSize, bold: allBold && !runs.isEmpty, style: style, images: images))
            start = end
        }

        // Rank the larger sizes into heading levels.
        let headingSizes = Set(paras.filter { p in
            let len = p.runs.map(\.text).joined().count
            return len > 0 && len < 160 && p.size >= bodySize * 1.15
        }.map { ($0.size * 2).rounded() / 2 }).sorted(by: >)

        var currentTable: NSTextTable?
        var tableRows: [[[Run]]] = []
        func flushTable() {
            if !tableRows.isEmpty { doc.blocks.append(.table(rows: tableRows, header: false)) }
            tableRows = []
            currentTable = nil
        }

        for p in paras {
            let textOnly = p.runs.map(\.text).joined()
            let trimmedText = textOnly.trimmingCharacters(in: .whitespacesAndNewlines)
            // Table cells.
            if let cell = p.style?.textBlocks.last as? NSTextTableBlock {
                if currentTable !== cell.table { flushTable(); currentTable = cell.table }
                while tableRows.count <= cell.startingRow { tableRows.append([]) }
                while tableRows[cell.startingRow].count < cell.startingColumn { tableRows[cell.startingRow].append([]) }
                if tableRows[cell.startingRow].count == cell.startingColumn {
                    tableRows[cell.startingRow].append(trimmed(p.runs))
                } else {
                    tableRows[cell.startingRow][cell.startingColumn] += [Run(text: "\n")] + trimmed(p.runs)
                }
                continue
            }
            flushTable()
            for id in p.images { doc.blocks.append(.image(id: id, alt: "", width: nil)) }
            if trimmedText == "\u{0C}" { doc.blocks.append(.pageBreak); continue }
            guard !trimmedText.isEmpty else { continue }
            var runs = trimmed(p.runs)
            let align: Align
            switch p.style?.alignment {
            case .center?: align = .center
            case .right?: align = .right
            case .justified?: align = .justify
            default: align = .natural
            }
            if let level = p.style?.headerLevel, level > 0 {
                doc.blocks.append(.heading(level: min(6, level), runs: runs.map { var r = $0; r.bold = false; return r }))
                continue
            }
            if let lists = p.style?.textLists, let list = lists.last {
                // Drop the marker the importer put in front of the text ("\t•\t", "\t1.\t").
                if let first = runs.first, first.text.hasPrefix("\t") || first.text.hasPrefix("•") {
                    let stripped = first.text.replacingOccurrences(of: #"^\t?[^\t]{0,8}\t"#, with: "", options: .regularExpression)
                    if stripped.isEmpty { runs.removeFirst() } else { runs[0].text = stripped }
                }
                let ordered = ![NSTextList.MarkerFormat.disc, .circle, .square, .hyphen, .box, .check, .diamond].contains(list.markerFormat)
                doc.blocks.append(.item(runs: runs, ordered: ordered, level: lists.count - 1))
                continue
            }
            // Lists the importer left as plain text with a typed marker ("•\tItem", "1.\tItem").
            if let first = runs.first,
               let m = first.text.range(of: #"^\t?([•◦▪‣·\-–*]|\d{1,3}[.)]|[a-zA-Z][.)])\t"#, options: .regularExpression) {
                let marker = first.text[m].trimmingCharacters(in: .whitespaces)
                let ordered = marker.first.map { $0.isNumber || $0.isLetter } ?? false
                let rest = String(first.text[m.upperBound...])
                if rest.isEmpty { runs.removeFirst() } else { runs[0].text = rest }
                let steps = ((p.style?.headIndent ?? 0) - 1) / 36
                let level = steps.isFinite ? Int(max(0, min(8, steps))) : 0
                doc.blocks.append(.item(runs: runs, ordered: ordered, level: level))
                continue
            }
            let rounded = (p.size * 2).rounded() / 2
            if trimmedText.count < 160, let rank = headingSizes.firstIndex(of: rounded) {
                doc.blocks.append(.heading(level: min(rank + 1, 4), runs: runs.map { var r = $0; r.bold = false; return r }))
            } else if trimmedText.count < 100, p.bold, !trimmedText.hasSuffix("."), !trimmedText.hasSuffix(":"),
                      abs(p.size - bodySize) < 0.5, headingSizes.count < 4 {
                doc.blocks.append(.heading(level: min(headingSizes.count + 1, 4), runs: runs.map { var r = $0; r.bold = false; return r }))
            } else {
                doc.blocks.append(.paragraph(runs: runs, align: align, role: .body))
            }
        }
        flushTable()
        return doc
    }

    private static func picture(from attachment: NSTextAttachment, into doc: inout Doc) -> String? {
        if let wrapper = attachment.fileWrapper, wrapper.isRegularFile, let data = wrapper.regularFileContents {
            let ext = (wrapper.preferredFilename ?? wrapper.filename ?? "").split(separator: ".").last.map(String.init) ?? "png"
            if let id = doc.addPicture(data, ext: ext) { return id }
        }
        if let data = attachment.contents, let id = doc.addPicture(data, ext: "png") { return id }
        if let image = attachment.image, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return doc.addPicture(png, ext: "png")
        }
        return nil
    }

    // MARK: Plain text

    /// Plain text: paragraphs are separated by blank lines (or are single lines when the text has none);
    /// short standalone lines like "Chapter 3" or "PROLOGUE" become headings.
    static func plainTextDocument(_ text: String) -> Doc {
        var doc = Doc()
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let hasBlankLines = normalized.contains("\n\n")
        let chunks: [String] = hasBlankLines
            ? normalized.components(separatedBy: "\n\n")
            : normalized.components(separatedBy: "\n")
        let headingPattern = #"^(chapter|part|book|section|prologue|epilogue|introduction|preface|foreword|afterword|appendix|kapitel|chapitre|cap[ií]tulo|teil)\b.{0,60}$"#
        // A short first line on its own, followed by more text, is the title.
        var level = 1
        if hasBlankLines, let first = chunks.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            let t = first.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.contains("\n"), t.count <= 80, !".,;:".contains(t.last ?? "."),
               t.range(of: headingPattern, options: [.regularExpression, .caseInsensitive]) == nil {
                doc.title = t
                level = 2
            }
        }
        for chunk in chunks {
            let pieces = chunk.components(separatedBy: "\u{0C}")
            for (k, piece) in pieces.enumerated() {
                if k > 0 { doc.blocks.append(.pageBreak) }
                let t = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                let oneLine = !t.contains("\n")
                if doc.title == t && doc.blocks.isEmpty {
                    doc.blocks.append(.heading(level: 1, runs: [Run(text: t)]))
                } else if oneLine, t.count <= 70, t.range(of: headingPattern, options: [.regularExpression, .caseInsensitive]) != nil {
                    doc.blocks.append(.heading(level: level, runs: [Run(text: t)]))
                } else if hasBlankLines {
                    // Lines inside a paragraph were wrapped for the screen: join them.
                    let joined = t.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                    doc.blocks.append(.para([Run(text: joined)]))
                } else {
                    doc.blocks.append(.para([Run(text: t)]))
                }
            }
        }
        return doc
    }

    // MARK: Markdown

    /// Markdown (CommonMark's common subset): ATX and setext headings, paragraphs, lists, block quotes,
    /// fenced and indented code, rules, tables, images and inline emphasis, code and links. A YAML front
    /// matter's title and author are used for the book.
    static func markdownDocument(_ source: String, base: URL?) -> Doc {
        var doc = Doc()
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---" || $0.trimmingCharacters(in: .whitespaces) == "..." }) {
            for line in lines[1..<end] {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                switch parts[0].trimmingCharacters(in: .whitespaces).lowercased() {
                case "title": doc.title = value
                case "author": doc.author = value
                case "lang", "language": doc.language = value
                default: break
                }
            }
            lines.removeSubrange(0...end)
        }

        var paragraph: [String] = []
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.enumerated().map { i, l -> String in
                var line = l.trimmingCharacters(in: .whitespaces)
                if i < paragraph.count - 1 {
                    if l.hasSuffix("  ") || line.hasSuffix("\\") {
                        if line.hasSuffix("\\") { line.removeLast() }
                        return line + "\n"
                    }
                    return line + " "
                }
                return line
            }.joined()
            paragraph = []
            emitInline(text) { doc.blocks.append(.para($0)) }
        }
        func emitInline(_ text: String, _ make: ([Run]) -> Void) {
            // Images standing alone become image blocks.
            let imagePattern = #"^!\[([^\]]*)\]\(([^)\s]+)(\s+"[^"]*")?\)$"#
            if let m = text.range(of: imagePattern, options: .regularExpression), m == text.startIndex..<text.endIndex {
                let alt = text.range(of: #"(?<=!\[)[^\]]*"#, options: .regularExpression).map { String(text[$0]) } ?? ""
                if let srcRange = text.range(of: #"(?<=\]\()[^)\s]+"#, options: .regularExpression),
                   let base, let id = loadImage(String(text[srcRange]), base: base, into: &doc) {
                    doc.blocks.append(.image(id: id, alt: alt, width: nil))
                    return
                }
            }
            make(markdownInline(text))
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Fenced code.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[i]); i += 1 }
                doc.blocks.append(.code(code.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.isEmpty { flushParagraph(); i += 1; continue }
            // Indented code (not inside a paragraph).
            if paragraph.isEmpty, line.hasPrefix("    ") || line.hasPrefix("\t"), !isListLine(trimmed) {
                var code: [String] = []
                while i < lines.count, lines[i].hasPrefix("    ") || lines[i].hasPrefix("\t") || lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    code.append(lines[i].hasPrefix("\t") ? String(lines[i].dropFirst()) : String(lines[i].dropFirst(min(4, lines[i].count))))
                    i += 1
                }
                while code.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { code.removeLast() }
                doc.blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            // ATX heading.
            if let m = trimmed.range(of: #"^#{1,6}(\s+|$)"#, options: .regularExpression) {
                flushParagraph()
                let level = trimmed[m].filter { $0 == "#" }.count
                var text = String(trimmed[m.upperBound...])
                text = text.replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
                doc.blocks.append(.heading(level: level, runs: markdownInline(text)))
                i += 1
                continue
            }
            // Setext heading underline.
            if !paragraph.isEmpty, trimmed.range(of: #"^(=+|-+)$"#, options: .regularExpression) != nil {
                let level = trimmed.hasPrefix("=") ? 1 : 2
                let text = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                paragraph = []
                doc.blocks.append(.heading(level: level, runs: markdownInline(text)))
                i += 1
                continue
            }
            // Rule.
            if trimmed.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil {
                flushParagraph()
                doc.blocks.append(.rule)
                i += 1
                continue
            }
            // Block quote.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var q = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    if q.hasPrefix(" ") { q = q.dropFirst() }
                    quote.append(String(q))
                    i += 1
                }
                for para in quote.split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    doc.blocks.append(.paragraph(runs: markdownInline(para.joined(separator: " ")), align: .natural, role: .quote))
                }
                continue
            }
            // List item.
            if isListLine(trimmed) {
                flushParagraph()
                let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                let ordered = trimmed.first?.isNumber == true
                var text = trimmed.replacingOccurrences(of: #"^([-*+]|\d{1,9}[.)])\s+"#, with: "", options: .regularExpression)
                text = text.replacingOccurrences(of: #"^\[[ xX]\]\s+"#, with: "", options: .regularExpression)
                // Lazy continuation lines.
                var j = i + 1
                while j < lines.count {
                    let next = lines[j].trimmingCharacters(in: .whitespaces)
                    if next.isEmpty || isListLine(next) || next.hasPrefix("#") || next.hasPrefix(">") || next.hasPrefix("```") { break }
                    text += " " + next
                    j += 1
                }
                doc.blocks.append(.item(runs: markdownInline(text), ordered: ordered, level: min(indent / 2, 8)))
                i = j
                continue
            }
            // Table: a header row followed by a delimiter row.
            if trimmed.hasPrefix("|") || trimmed.contains(" | "), i + 1 < lines.count,
               lines[i + 1].trimmingCharacters(in: .whitespaces).range(of: #"^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$"#,
                                                                        options: .regularExpression) != nil {
                flushParagraph()
                func cells(_ l: String) -> [[Run]] {
                    var t = l.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("|") { t.removeFirst() }
                    if t.hasSuffix("|") { t.removeLast() }
                    return t.components(separatedBy: "|").map { markdownInline($0.trimmingCharacters(in: .whitespaces)) }
                }
                var rows = [cells(line)]
                i += 2
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, lines[i].contains("|") {
                    rows.append(cells(lines[i]))
                    i += 1
                }
                doc.blocks.append(.table(rows: rows, header: true))
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return doc
    }

    private static func isListLine(_ trimmed: String) -> Bool {
        trimmed.range(of: #"^([-*+]|\d{1,9}[.)])\s+\S"#, options: .regularExpression) != nil
    }

    private static func loadImage(_ src: String, base: URL, into doc: inout Doc) -> String? {
        guard !Package.isRemote(src) else { return nil }
        let file = base.appendingPathComponent(src.removingPercentEncoding ?? src)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return doc.addPicture(data, ext: file.pathExtension)
    }

    /// Inline Markdown: `code`, **strong**, *emphasis*, ~~strike~~, [links](url), <br>, backslash escapes.
    static func markdownInline(_ text: String) -> [Run] {
        var runs: [Run] = []
        var bold = false, italic = false, strike = false
        var current = ""
        func push(_ extra: Run? = nil) {
            if !current.isEmpty { runs.append(Run(text: current, bold: bold, italic: italic, strike: strike)) }
            current = ""
            if let extra { runs.append(extra) }
        }
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, "\\`*_{}[]()#+-.!~|<>".contains(chars[i + 1]) {
                current.append(chars[i + 1]); i += 2; continue
            }
            if c == "\\", i + 1 == chars.count - 0 { i += 1; continue }
            if c == "`" {
                var ticks = 0
                while i + ticks < chars.count, chars[i + ticks] == "`" { ticks += 1 }
                let fence = String(repeating: "`", count: ticks)
                let rest = String(chars[(i + ticks)...])
                if let close = rest.range(of: fence) {
                    push(Run(text: String(rest[..<close.lowerBound]).trimmingCharacters(in: .whitespaces), code: true))
                    i += ticks + rest.distance(from: rest.startIndex, to: close.upperBound)
                    continue
                }
            }
            if (c == "*" || c == "_"), i + 1 < chars.count, chars[i + 1] == c {
                push(); bold.toggle(); i += 2; continue
            }
            if c == "~", i + 1 < chars.count, chars[i + 1] == "~" { push(); strike.toggle(); i += 2; continue }
            if c == "*" || (c == "_" && (i == 0 || !chars[i - 1].isLetter || italic)) {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if italic || next != " " { push(); italic.toggle(); i += 1; continue }
            }
            if c == "!" || c == "[" {
                let start = c == "!" ? i + 1 : i
                if start < chars.count, chars[start] == "[" {
                    let rest = String(chars[start...])
                    if let m = rest.range(of: #"^\[([^\]]*)\]\(([^)\s]*)(\s+"[^"]*")?\)"#, options: .regularExpression) {
                        let matched = String(rest[m])
                        let label = String(matched.dropFirst().prefix(while: { $0 != "]" }))
                        let url = matched.range(of: #"(?<=\]\()[^)\s]*"#, options: .regularExpression).map { String(matched[$0]) } ?? ""
                        if c == "!" {
                            if !label.isEmpty { push(Run(text: label, italic: true)) }
                        } else {
                            push()
                            for var r in markdownInline(label) {
                                if Package.isRemote(url) { r.link = url }
                                r.bold = r.bold || bold; r.italic = r.italic || italic
                                runs.append(r)
                            }
                        }
                        i = start + matched.count
                        continue
                    }
                }
            }
            if c == "<" {
                let rest = String(chars[i...]).lowercased()
                if rest.hasPrefix("<br>") || rest.hasPrefix("<br/>") || rest.hasPrefix("<br />") {
                    current.append("\n")
                    i += rest.hasPrefix("<br>") ? 4 : rest.hasPrefix("<br/>") ? 5 : 6
                    continue
                }
            }
            current.append(c)
            i += 1
        }
        push()
        return merged(runs)
    }

    // MARK: PDF

    /// A PDF's text, page by page. Chapters follow the outline (bookmarks) when it has two or more
    /// top-level entries, otherwise each page is a chapter. Pages without a text layer are read with OCR,
    /// and a page that still has no text keeps a picture of itself.
    static func pdfDocument(_ url: URL, options: ToolOptions, progress: (Double) -> Void) throws -> Doc {
        guard let pdf = PDFDocument(url: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
        if pdf.isLocked {
            throw ConversionError.unsupported("\(url.lastPathComponent) is password-protected. Use Remove Password first.")
        }
        guard pdf.pageCount > 0 else { throw ConversionError.unsupported("\(url.lastPathComponent) has no pages.") }
        var doc = Doc()
        let attrs = pdf.documentAttributes ?? [:]
        doc.title = (attrs[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
        doc.author = (attrs[PDFDocumentAttribute.authorAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let ocr = options.bool("ocr", true)
        let mode = options.string("chapters", "auto")
        let byOutline = mode != "page" && (pdf.outlineRoot?.numberOfChildren ?? 0) >= 2
        var pageStarts: [Int] = []
        for i in 0..<pdf.pageCount {
            pageStarts.append(doc.blocks.count)
            guard let page = pdf.page(at: i) else { continue }
            var blocks = pdfPageBlocks(page)
            if blocks.isEmpty, ocr, let ref = page.pageRef, let image = PDFTools.scanImage(ref),
               let text = try? PDFTools.recognizeTextAnyOrientation(in: image) {
                // OCR gives lines without geometry: keep them as lines, paragraphs at blank lines.
                blocks = text.components(separatedBy: "\n\n").flatMap { para -> [Block] in
                    let t = para.trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty ? [] : [.para([Run(text: t)])]
                }
            }
            if blocks.isEmpty, let ref = page.pageRef, let image = PDFTools.render(ref, dpi: 110),
               let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
               let id = doc.addPicture(jpeg, ext: "jpg") {
                blocks = [.image(id: id, alt: "Page \(i + 1)", width: nil)]
            }
            // A paragraph running over the page break continues (chapters spanning pages only).
            if byOutline, case let .paragraph(prevRuns, align, role)? = doc.blocks.last, case let .paragraph(nextRuns, _, _)? = blocks.first,
               let end = plain(prevRuns).last, !".!?:;\"”’)]".contains(end), plain(nextRuns).first?.isLowercase == true {
                doc.blocks[doc.blocks.count - 1] = .paragraph(runs: merged(prevRuns + [Run(text: " ")] + nextRuns), align: align, role: role)
                blocks.removeFirst()
                pageStarts[pageStarts.count - 1] = doc.blocks.count
            }
            doc.blocks += blocks
            progress(Double(i + 1) / Double(pdf.pageCount))
        }
        pageStarts.append(doc.blocks.count)

        var chapters: [(title: String, range: Range<Int>)] = []
        if byOutline, let root = pdf.outlineRoot {
            var marks: [(String, Int)] = []
            for k in 0..<root.numberOfChildren {
                guard let item = root.child(at: k), let page = item.destination?.page ?? (item.action as? PDFActionGoTo)?.destination.page
                else { continue }
                let index = pdf.index(for: page)
                if index >= 0, index < pdf.pageCount, marks.last?.1 != index { marks.append((item.label ?? "Chapter \(k + 1)", index)) }
            }
            marks.sort { $0.1 < $1.1 }
            if marks.count >= 2 {
                if marks[0].1 > 0 { marks.insert((doc.title ?? "Start", 0), at: 0) }
                for (k, m) in marks.enumerated() {
                    let from = pageStarts[m.1]
                    let to = k + 1 < marks.count ? pageStarts[marks[k + 1].1] : doc.blocks.count
                    if to > from { chapters.append((m.0, from..<to)) }
                }
            }
        }
        if chapters.isEmpty {
            for p in 0..<pdf.pageCount where pageStarts[p + 1] > pageStarts[p] {
                chapters.append(("Page \(p + 1)", pageStarts[p]..<pageStarts[p + 1]))
            }
        }
        doc.chapters = chapters
        guard !doc.blocks.isEmpty else { throw ConversionError.unsupported("No text found in \(url.lastPathComponent).") }
        return doc
    }

    /// Whether the page's lines run up (90) or down (270) in page space rather than left to right (0),
    /// by a vote over its lines: the first and last letters of each line show which way it advances.
    /// Upside-down text isn't considered (right-to-left scripts would look the same).
    static func verticalTextRotation(_ page: PDFPage, _ lines: [(range: Range<Int>, box: CGRect)]) -> Int {
        // Cheap test first: sideways lines of a few letters are boxes taller than they are wide.
        let tall = lines.filter { $0.range.count >= 3 && $0.box.height > 1.5 * $0.box.width }.count
        guard tall * 2 > lines.count, let string = page.string else { return 0 }
        let units = Array(string.utf16)
        func box(_ i: Int) -> CGRect? {
            guard let b = page.selection(for: NSRange(location: i, length: 1))?.bounds(for: page), !b.isEmpty else { return nil }
            return b
        }
        var across = 0, up = 0, down = 0
        for (range, _) in lines.prefix(60) {
            // First and last letters that aren't spaces.
            guard let first = range.first(where: { units[$0] > 0x20 }),
                  let last = range.reversed().first(where: { units[$0] > 0x20 }), last > first,
                  let a = box(first), let b = box(last) else { continue }
            let dx = b.midX - a.midX, dy = b.midY - a.midY
            if abs(dx) > 2 * abs(dy) { across += 1 } else if abs(dy) > 2 * abs(dx) { if dy > 0 { up += 1 } else { down += 1 } }
        }
        guard up + down > across else { return 0 }
        return up >= down ? 90 : 270
    }

    /// A box in page space turned so that text advancing in `rotation`'s direction runs left to right,
    /// with y still growing upwards (so "above" keeps meaning a larger y). Rotation 0 leaves it as it is.
    static func uprightBox(_ r: CGRect, in page: CGRect, rotation: Int) -> CGRect {
        switch rotation {
        case 90:   // advancing up the page; the line above is further left
            return CGRect(x: r.minY - page.minY, y: page.maxX - r.maxX, width: r.height, height: r.width)
        case 270:  // advancing down the page; the line above is further right
            return CGRect(x: page.maxY - r.maxY, y: r.minX - page.minX, width: r.height, height: r.width)
        default:
            return r
        }
    }

    /// One page's text as paragraphs. Lines are rebuilt from character positions (some generators emit no
    /// line breaks). A clearly larger vertical gap, an indented first line or a line that stops well short
    /// of the right edge ends a paragraph. Fonts come from the page's attributed text: bold and italic runs
    /// are kept, and short lines set clearly larger than the body text become headings.
    static func pdfPageBlocks(_ page: PDFPage) -> [Block] {
        guard let string = page.string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let chars = Array(string.utf16)

        // Font size and style per character, when the attributed text lines up with the string.
        var sizes = [CGFloat](repeating: 0, count: chars.count)
        var bolds = [Bool](repeating: false, count: chars.count)
        var italics = [Bool](repeating: false, count: chars.count)
        if let attributed = page.attributedString, attributed.length == chars.count {
            attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                guard let font = value as? NSFont else { return }
                let traits = NSFontManager.shared.traits(of: font)
                let name = font.fontName.lowercased()
                let bold = traits.contains(.boldFontMask) || name.contains("bold") || name.contains("black") || name.contains("heavy")
                let italic = traits.contains(.italicFontMask) || name.contains("italic") || name.contains("oblique")
                for i in range.location..<(range.location + range.length) {
                    sizes[i] = font.pointSize; bolds[i] = bold; italics[i] = italic
                }
            }
        }

        struct Line {
            var units: [UInt16] = []
            var runs: [Run] = []
            var sizeCounts: [CGFloat: Int] = [:]
            var minY = CGFloat.infinity, maxY = -CGFloat.infinity, minX = CGFloat.infinity, maxX = -CGFloat.infinity
            var text: String { runs.map(\.text).joined() }
            /// The font size most of the line is set in (0 when unknown).
            var size: CGFloat { sizeCounts.max { $0.value < $1.value }?.key ?? 0 }
            var height: CGFloat { maxY > minY ? maxY - minY : 0 }
        }
        /// Runs and font sizes for the characters in `range` of the page string.
        func styledLine(_ range: Range<Int>) -> Line {
            var line = Line()
            var runStart = range.lowerBound
            for i in range {
                if i > runStart, bolds[i] != bolds[runStart] || italics[i] != italics[runStart] {
                    line.runs.append(Run(text: String(decoding: chars[runStart..<i], as: UTF16.self), bold: bolds[runStart], italic: italics[runStart]))
                    runStart = i
                }
                if sizes[i] > 0, chars[i] != 0x20 { line.sizeCounts[(sizes[i] * 2).rounded() / 2, default: 0] += 1 }
            }
            if range.upperBound > runStart {
                line.runs.append(Run(text: String(decoding: chars[runStart..<range.upperBound], as: UTF16.self),
                                     bold: bolds[runStart], italic: italics[runStart]))
            }
            line.runs = trimmed(line.runs)
            return line
        }

        var lines: [Line] = []
        var pageWidth = page.bounds(for: .cropBox).width
        if chars.contains(0x0A) || chars.contains(0x0D) {
            // PDFKit already broke the text into lines; measure each line through a selection (character
            // boxes can be offset from string indexes by the line breaks PDFKit adds).
            var pieces: [(range: Range<Int>, box: CGRect)] = []
            var start = 0
            for i in 0...chars.count where i == chars.count || chars[i] == 0x0A || chars[i] == 0x0D {
                defer { start = i + 1 }
                guard i > start, let box = page.selection(for: NSRange(location: start, length: i - start))?.bounds(for: page),
                      !box.isEmpty else { continue }
                pieces.append((start..<i, box))
            }
            // Text drawn sideways (a landscape table on a portrait page turned with /Rotate): the boxes are
            // turned so its lines read left to right, top to bottom, like any other page.
            let rotation = verticalTextRotation(page, pieces)
            if rotation != 0 { pageWidth = page.bounds(for: .cropBox).height }
            for piece in pieces {
                var line = styledLine(piece.range)
                guard !line.runs.isEmpty else { continue }
                let box = uprightBox(piece.box, in: page.bounds(for: .cropBox), rotation: rotation)
                line.minX = box.minX; line.maxX = box.maxX; line.minY = box.minY; line.maxY = box.maxY
                // A piece PDFKit split off the same row (after a superscript, say) goes back onto its line,
                // with a space when there is a visible gap between them.
                if var prev = lines.last, line.minX >= prev.maxX - 1,
                   min(prev.maxY, line.maxY) - max(prev.minY, line.minY) > 0.5 * min(prev.height, line.height) {
                    let em = max(prev.size, line.size, min(prev.height, line.height), 1)
                    if line.minX - prev.maxX > 0.15 * em, let last = prev.runs.last?.text.last, !last.isWhitespace,
                       let first = line.runs.first?.text.first, !first.isWhitespace {
                        line.runs[0].text = " " + line.runs[0].text
                    }
                    prev.runs += line.runs
                    for (k, v) in line.sizeCounts { prev.sizeCounts[k, default: 0] += v }
                    prev.maxX = line.maxX; prev.minY = min(prev.minY, line.minY); prev.maxY = max(prev.maxY, line.maxY)
                    lines[lines.count - 1] = prev
                    continue
                }
                lines.append(line)
            }
        } else {
            // No line breaks at all (some generators): rebuild lines from character positions.
            var start = 0
            var box = (minY: CGFloat.infinity, maxY: -CGFloat.infinity, minX: CGFloat.infinity, maxX: -CGFloat.infinity)
            func endLine(_ end: Int) {
                var line = styledLine(start..<end)
                if !line.runs.isEmpty {
                    line.minY = box.minY; line.maxY = box.maxY; line.minX = box.minX; line.maxX = box.maxX
                    lines.append(line)
                }
                start = end
                box = (.infinity, -.infinity, .infinity, -.infinity)
            }
            for (i, c) in chars.enumerated() {
                let r = page.characterBounds(at: i)
                guard r.height > 0, c != 0x20 else { continue }
                if box.minY.isFinite, min(r.maxY, box.maxY) - max(r.minY, box.minY) < 0.25 * min(r.height, box.maxY - box.minY) {
                    endLine(i)
                }
                box = (min(box.minY, r.minY), max(box.maxY, r.maxY), min(box.minX, r.minX), max(box.maxX, r.maxX))
            }
            endLine(chars.count)
        }
        guard !lines.isEmpty else { return [] }

        // Body size: the font size covering the most characters; line height stands in when fonts are unknown.
        var bodyCounts: [CGFloat: Int] = [:]
        for l in lines { for (size, n) in l.sizeCounts { bodyCounts[size, default: 0] += n } }
        let bodySize = bodyCounts.max { $0.value < $1.value }?.key ?? 0
        let heights = lines.map(\.height).filter { $0 > 0 }.sorted()
        let typical = heights.isEmpty ? 10 : heights[heights.count / 2]
        func isHeading(_ l: Line) -> Bool {
            guard l.text.count < 120 else { return false }
            return bodySize > 0 ? l.size >= bodySize * 1.25 : l.height > typical * 1.4
        }
        let gaps = zip(lines, lines.dropFirst()).map { $0.minY - $1.maxY }.filter { $0 > -typical && $0 < typical * 3 }.sorted()
        let normalGap = gaps.isEmpty ? typical * 0.3 : gaps[gaps.count / 3]
        let leftEdge = lines.map(\.minX).filter(\.isFinite).min() ?? 0
        // The text column's right edge: the widest line, or the page mirrored from the left margin
        // (a page of short lines has no full-width line to measure against).
        let rightEdge = max(lines.map(\.maxX).filter(\.isFinite).max() ?? pageWidth, pageWidth - leftEdge)

        var blocks: [Block] = []
        var para: [Run] = []
        func flush() {
            let r = trimmed(para)
            if !r.isEmpty { blocks.append(.para(r)) }
            para = []
        }
        for (k, line) in lines.enumerated() {
            if isHeading(line) {
                flush()
                // A heading set over two lines continues when the next line has the same size.
                if case let .heading(level, runs)? = blocks.last, k > 0, isHeading(lines[k - 1]),
                   abs(lines[k - 1].size - line.size) <= max(0.5, line.size * 0.05) {
                    blocks[blocks.count - 1] = .heading(level: level, runs: [Run(text: plain(runs) + " " + line.text)])
                } else {
                    blocks.append(.heading(level: bodySize > 0 && line.size >= bodySize * 1.8 ? 1 : 2, runs: [Run(text: line.text)]))
                }
                continue
            }
            if k > 0 {
                let prev = lines[k - 1]
                let gap = prev.minY - line.maxY
                let indented = line.minX - leftEdge > typical * 0.8 && prev.minX - leftEdge < typical * 0.5
                // A line that stops well short of the right edge ends its paragraph.
                let short = prev.maxX < leftEdge + 0.8 * (rightEdge - leftEdge)
                if gap > normalGap + typical * 0.6 || indented || short || isHeading(prev) { flush() }
            }
            var runs = line.runs
            if let last = para.last, last.text.hasSuffix("-"), let first = runs.first?.text.first, first.isLowercase {
                para[para.count - 1].text.removeLast()   // re-join a word hyphenated across lines
            } else if !para.isEmpty, !runs.isEmpty {
                runs[0].text = " " + runs[0].text
            }
            para += runs
        }
        flush()
        return blocks.map { block in
            if case let .paragraph(runs, align, role) = block { return .paragraph(runs: merged(runs), align: align, role: role) }
            return block
        }
    }
}
