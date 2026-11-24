import AppKit

/// Writes OpenDocument text (.odt) from a RichDocument: outline headings, nested lists, tables with
/// merged cells, embedded pictures, links, quotes, code and page breaks. (Cocoa's own ODT writer drops
/// pictures, headings and links.)
enum RichODTWriter {
    static func write(_ doc: RichDocument, to url: URL, page: RichPageSetup = .regional) throws {
        var b = Builder(doc: doc, page: page)
        let content = b.content()
        let zip = ZipWriter()
        try zip.add("mimetype", string: "application/vnd.oasis.opendocument.text", compress: false)
        try zip.add("content.xml", string: content)
        try zip.add("styles.xml", string: b.styles())
        try zip.add("meta.xml", string: b.meta())
        for (i, image) in b.pictures.enumerated() {
            try zip.add("Pictures/image\(i + 1).\(image.fileExtension)", data: image.data, compress: false)
        }
        try zip.add("META-INF/manifest.xml", string: b.manifest())
        try zip.write(to: url)
    }

    /// Collects automatic styles, pictures and fonts while content.xml is written.
    private struct Builder {
        let doc: RichDocument
        let page: RichPageSetup
        var pictures: [RichImage] = []
        var fonts: Set<String>
        /// Automatic styles, deduplicated by their properties.
        var textStyles: [String: String] = [:]
        var paragraphStyles: [String: String] = [:]
        var listStyles: [String] = []
        var tables = 0
        let headingSizes: [CGFloat]

        init(doc: RichDocument, page: RichPageSetup) {
            self.doc = doc
            self.page = page
            fonts = [doc.bodyFamily, RichStyle.monoFamily]
            var sizes: [CGFloat] = []
            for level in 1...6 {
                var count: [CGFloat: Int] = [:]
                for case .paragraph(let p) in doc.blocks where p.headingLevel == level {
                    for r in p.runs where r.image == nil { count[(r.size * 2).rounded() / 2, default: 0] += r.text.count }
                }
                sizes.append(count.max { $0.value < $1.value }?.key ?? RichStyle.headingSizes[level - 1] * doc.bodySize / RichStyle.bodySize)
            }
            headingSizes = sizes
        }

        static func pt(_ v: CGFloat) -> String { String(format: "%.2fpt", v) }

        // MARK: Content

        mutating func content() -> String {
            var body = ""
            var pendingBreak = false
            let groups = doc.grouped()
            var i = 0
            while i < groups.count {
                let group = groups[i]
                i += 1
                switch group {
                case .list(let items):
                    for node in RichListNode.build(items) { body += list(node, top: true) }
                case .block(.paragraph(let p)):
                    body += paragraph(p, pageBreakBefore: pendingBreak)
                    pendingBreak = false
                case .block(.table(let t)):
                    if pendingBreak { body += "<text:p text:style-name=\"\(paragraphStyle("fo:break-before=\"page\"", parent: "Standard"))\"/>"; pendingBreak = false }
                    body += table(t)
                case .block(.rule):
                    let s = paragraphStyle("fo:margin-top=\"6pt\" fo:margin-bottom=\"12pt\" fo:border-bottom=\"0.75pt solid #C8C8CC\" fo:border-top=\"none\" fo:border-left=\"none\" fo:border-right=\"none\" fo:padding-bottom=\"2pt\"", parent: "Standard")
                    body += "<text:p text:style-name=\"\(s)\"/>"
                case .block(.pageBreak):
                    pendingBreak = true
                }
            }
            if pendingBreak { body += "<text:p text:style-name=\"\(paragraphStyle("fo:break-before=\"page\"", parent: "Standard"))\"/>" }

            var auto = ""
            for (props, name) in paragraphStyles.sorted(by: { $0.value.localizedStandardCompare($1.value) == .orderedAscending }) {
                let parts = props.components(separatedBy: "\u{1}")
                auto += "<style:style style:name=\"\(name)\" style:family=\"paragraph\" style:parent-style-name=\"\(parts[0])\"><style:paragraph-properties \(parts[1])/></style:style>"
            }
            for (props, name) in textStyles.sorted(by: { $0.value.localizedStandardCompare($1.value) == .orderedAscending }) {
                auto += "<style:style style:name=\"\(name)\" style:family=\"text\"><style:text-properties \(props)/></style:style>"
            }
            auto += listStyles.joined()
            let textWidth = page.textWidth
            for t in 0..<tables {
                auto += "<style:style style:name=\"Tbl\(t + 1)\" style:family=\"table\"><style:table-properties style:width=\"\(Builder.pt(textWidth))\" table:align=\"margins\" fo:margin-top=\"4pt\" fo:margin-bottom=\"8pt\"/></style:style>"
            }
            auto += "<style:style style:name=\"Cell\" style:family=\"table-cell\"><style:table-cell-properties fo:padding=\"3pt\" fo:border=\"0.5pt solid #BFBFC7\"/></style:style>"
            auto += "<style:style style:name=\"HeaderCell\" style:family=\"table-cell\"><style:table-cell-properties fo:padding=\"3pt\" fo:border=\"0.5pt solid #BFBFC7\" fo:background-color=\"#F0F0F2\"/></style:style>"
            auto += "<style:style style:name=\"fr1\" style:family=\"graphic\"><style:graphic-properties style:vertical-pos=\"top\" style:vertical-rel=\"baseline\" fo:border=\"none\"/></style:style>"

            return """
            <?xml version="1.0" encoding="UTF-8"?>
            <office:document-content \(Builder.namespaces) office:version="1.3">\(fontDecls())<office:automatic-styles>\(auto)</office:automatic-styles><office:body><office:text>\(body)</office:text></office:body></office:document-content>
            """
        }

        static let namespaces = "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:draw=\"urn:oasis:names:tc:opendocument:xmlns:drawing:1.0\" xmlns:fo=\"urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:meta=\"urn:oasis:names:tc:opendocument:xmlns:meta:1.0\" xmlns:svg=\"urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0\""

        func fontDecls() -> String {
            "<office:font-face-decls>" + fonts.sorted().map { f in
                let e = richXMLEscape(f, attribute: true)
                let mono = FontFacts.monoFamilies.contains(f.lowercased())
                return "<style:font-face style:name=\"\(e)\" svg:font-family=\"&apos;\(e)&apos;\" style:font-pitch=\"\(mono ? "fixed" : "variable")\"/>"
            }.joined() + "</office:font-face-decls>"
        }

        mutating func paragraphStyle(_ props: String, parent: String) -> String {
            let key = parent + "\u{1}" + props
            if let name = paragraphStyles[key] { return name }
            let name = "P\(paragraphStyles.count + 1)"
            paragraphStyles[key] = name
            return name
        }

        mutating func textStyle(_ props: String) -> String {
            if let name = textStyles[props] { return name }
            let name = "T\(textStyles.count + 1)"
            textStyles[props] = name
            return name
        }

        /// A paragraph (or heading) element with an automatic style for its spacing, alignment and indents.
        mutating func paragraph(_ p: RichParagraph, pageBreakBefore: Bool = false, inList: Bool = false, inCell: Bool = false, header: Bool = false) -> String {
            let parent: String
            if let level = p.headingLevel { parent = "Heading_20_\(level)" }
            else if p.codeLanguage != nil { parent = "Preformatted_20_Text" }
            else if p.quoteDepth > 0 { parent = "Quotations" }
            else if inCell { parent = header ? "Table_20_Heading" : "Table_20_Contents" }
            else { parent = "Standard" }
            var props: [String] = []
            if p.codeLanguage == nil && !inCell {
                props.append("fo:margin-top=\"\(Builder.pt(p.spaceBefore))\" fo:margin-bottom=\"\(Builder.pt(p.spaceAfter))\"")
                if p.lineHeight > 0.5 { props.append("fo:line-height=\"\(Int((p.lineHeight * 100).rounded()))%\"") }
            }
            switch p.alignment {
            case .center: props.append("fo:text-align=\"center\"")
            case .right: props.append("fo:text-align=\"\(p.rtl ? "start" : "end")\"")
            case .left where p.rtl: props.append("fo:text-align=\"end\"")
            case .justified: props.append("fo:text-align=\"justify\"")
            default: break
            }
            if p.rtl { props.append("style:writing-mode=\"rl-tb\"") }
            if p.quoteDepth > 1 { props.append("fo:margin-left=\"\(Builder.pt(18 * CGFloat(p.quoteDepth)))\"") }
            else if p.list.isEmpty && !inList && (p.leftIndent > 0.5 || abs(p.firstLineIndent) > 0.5) {
                props.append("fo:margin-left=\"\(Builder.pt(max(0, p.leftIndent)))\" fo:text-indent=\"\(Builder.pt(p.firstLineIndent))\"")
            }
            if let bg = p.background { props.append("fo:background-color=\"#\(bg)\"") }
            if pageBreakBefore { props.append("fo:break-before=\"page\"") }
            let style = props.isEmpty ? parent : paragraphStyle(props.joined(separator: " "), parent: parent)
            var runs = p.runs
            if let task = p.task { runs.insert(RichRun(text: task ? "☑ " : "☐ ", size: doc.bodySize), at: 0) }
            let inner = spans(runs, p)
            if let level = p.headingLevel, !inCell {
                return "<text:h text:style-name=\"\(style)\" text:outline-level=\"\(level)\">\(inner)</text:h>"
            }
            return "<text:p text:style-name=\"\(style)\">\(inner)</text:p>"
        }

        mutating func spans(_ runs: [RichRun], _ p: RichParagraph) -> String {
            var x = ""
            var i = 0
            let base: CGFloat = p.headingLevel.map { headingSizes[$0 - 1] } ?? (p.codeLanguage != nil ? RichStyle.codeSize : doc.bodySize)
            var first = true
            while i < runs.count {
                if let link = runs[i].link, RichDocument.isSafeLink(link) {
                    var inner = ""
                    while i < runs.count, runs[i].link == link {
                        inner += span(runs[i], base: base, heading: p.headingLevel != nil, link: true, atStart: &first); i += 1
                    }
                    x += "<text:a xlink:type=\"simple\" xlink:href=\"\(richXMLEscape(link, attribute: true))\" text:style-name=\"Internet_20_link\">\(inner)</text:a>"
                } else {
                    x += span(runs[i], base: base, heading: p.headingLevel != nil, link: false, atStart: &first); i += 1
                }
            }
            return x
        }

        mutating func span(_ r: RichRun, base: CGFloat, heading: Bool, link: Bool, atStart: inout Bool) -> String {
            if let image = r.image { atStart = false; return frame(image) }
            var props: [String] = []
            if r.bold && !heading { props.append("fo:font-weight=\"bold\" style:font-weight-asian=\"bold\" style:font-weight-complex=\"bold\"") }
            if !r.bold && heading { props.append("fo:font-weight=\"normal\"") }
            if r.italic { props.append("fo:font-style=\"italic\" style:font-style-asian=\"italic\" style:font-style-complex=\"italic\"") }
            if r.underline { props.append("style:text-underline-style=\"solid\" style:text-underline-width=\"auto\" style:text-underline-color=\"font-color\"") }
            if r.strike { props.append("style:text-line-through-style=\"solid\"") }
            if let c = r.color { props.append("fo:color=\"#\(c)\"") }
            if r.code {
                props.append("style:font-name=\"\(RichStyle.monoFamily)\" fo:font-size=\"\(Builder.pt(RichStyle.codeSize * doc.bodySize / RichStyle.bodySize))\" fo:background-color=\"#F2F2F4\"")
            } else {
                if let family = r.family { fonts.insert(family); props.append("style:font-name=\"\(richXMLEscape(family, attribute: true))\"") }
                if abs(r.size - base) > 0.25 && r.script == 0 { props.append("fo:font-size=\"\(Builder.pt(r.size))\"") }
            }
            if let h = r.highlight { props.append("fo:background-color=\"#\(h)\"") }
            if r.script != 0 { props.append("style:text-position=\"\(r.script > 0 ? "super" : "sub") 58%\"") }
            let text = Builder.odfText(r.text, atStart: &atStart)
            guard !text.isEmpty else { return "" }
            if props.isEmpty { return text }
            return "<text:span text:style-name=\"\(textStyle(props.joined(separator: " ")))\">\(text)</text:span>"
        }

        /// ODF collapses white space, so runs of spaces, tabs and line breaks are elements.
        static func odfText(_ s: String, atStart: inout Bool) -> String {
            var out = ""
            var spaces = 0
            func flushSpaces() {
                guard spaces > 0 else { return }
                if atStart { out += "<text:s text:c=\"\(spaces)\"/>" }
                else { out += " "; if spaces > 1 { out += "<text:s text:c=\"\(spaces - 1)\"/>" } }
                spaces = 0
            }
            for ch in s {
                switch ch {
                case " ": spaces += 1
                case "\t": flushSpaces(); out += "<text:tab/>"; atStart = false
                case "\u{2028}", "\n", "\r", "\u{2029}": flushSpaces(); out += "<text:line-break/>"; atStart = true
                default:
                    flushSpaces()
                    out += richXMLEscape(String(ch))
                    atStart = false
                }
            }
            flushSpaces()
            return out
        }

        mutating func frame(_ image: RichImage) -> String {
            pictures.append(image)
            let n = pictures.count
            var size = image.displaySize
            let scale = min(1, page.textWidth / max(size.width, 1))
            size = CGSize(width: size.width * scale, height: size.height * scale)
            // The alt text goes where LibreOffice puts it (and RichODTReader looks): svg:title and svg:desc.
            let alt = image.alt.trimmingCharacters(in: .whitespacesAndNewlines)
            let described = alt.isEmpty ? "" : "<svg:title>\(richXMLEscape(alt))</svg:title><svg:desc>\(richXMLEscape(alt))</svg:desc>"
            return "<draw:frame draw:style-name=\"fr1\" draw:name=\"Image\(n)\" text:anchor-type=\"as-char\" svg:width=\"\(Builder.pt(size.width))\" svg:height=\"\(Builder.pt(size.height))\" draw:z-index=\"0\"><draw:image xlink:href=\"Pictures/image\(n).\(image.fileExtension)\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\" draw:mime-type=\"\(image.mimeType)\"/>\(described)</draw:frame>"
        }

        mutating func list(_ node: RichListNode, top: Bool) -> String {
            var x = ""
            if top {
                let name = "L\(listStyles.count + 1)"
                listStyles.append(listStyle(name, node))
                x += "<text:list text:style-name=\"\(name)\">"
            } else {
                x += "<text:list>"
            }
            for item in node.items {
                x += "<text:list-item>"
                if item.paragraphs.isEmpty { x += "<text:p text:style-name=\"Standard\"/>" }
                for p in item.paragraphs { x += paragraph(p, inList: true) }
                for child in item.children { x += list(child, top: false) }
                x += "</text:list-item>"
            }
            return x + "</text:list>"
        }

        /// Levels from the list's own items where known, sensible defaults below them.
        func listStyle(_ name: String, _ root: RichListNode) -> String {
            var levels: [RichListLevel] = []
            var node: RichListNode? = root
            while let n = node, levels.count < 10 {
                levels.append(n.level)
                node = n.items.lazy.flatMap(\.children).first
            }
            var x = "<text:list-style style:name=\"\(name)\">"
            for i in 0..<10 {
                let level = i < levels.count ? levels[i]
                    : (levels.last?.ordered ?? false ? RichListLevel(style: [.decimal, .lowerAlpha, .lowerRoman][i % 3]) : .defaultBullet(depth: i))
                let margin = 0.25 * Double(i + 2)
                let props = "<style:list-level-properties text:list-level-position-and-space-mode=\"label-alignment\"><style:list-level-label-alignment text:label-followed-by=\"listtab\" text:list-tab-stop-position=\"\(margin)in\" fo:text-indent=\"-0.25in\" fo:margin-left=\"\(margin)in\"/></style:list-level-properties>"
                if level.ordered {
                    let format: String
                    switch level.style {
                    case .lowerAlpha: format = "a"
                    case .upperAlpha: format = "A"
                    case .lowerRoman: format = "i"
                    case .upperRoman: format = "I"
                    default: format = "1"
                    }
                    let start = i == 0 ? (root.items.first?.paragraphs.first?.itemNumber ?? level.start) : level.start
                    x += "<text:list-level-style-number text:level=\"\(i + 1)\" style:num-suffix=\".\" style:num-format=\"\(format)\" text:start-value=\"\(max(1, start))\">\(props)</text:list-level-style-number>"
                } else {
                    x += "<text:list-level-style-bullet text:level=\"\(i + 1)\" text:bullet-char=\"\(level.marker(1))\">\(props)</text:list-level-style-bullet>"
                }
            }
            return x + "</text:list-style>"
        }

        mutating func table(_ t: RichTable) -> String {
            tables += 1
            let cols = max(1, t.columns)
            var x = "<table:table table:name=\"Table\(tables)\" table:style-name=\"Tbl\(tables)\"><table:table-column table:number-columns-repeated=\"\(cols)\"/>"
            for (r, row) in t.rows.enumerated() {
                if r == 0 && t.headerRows > 0 { x += "<table:table-header-rows>" }
                x += "<table:table-row>"
                let header = r < t.headerRows
                for c in 0..<cols {
                    let cell = c < row.count ? row[c] : RichCell()
                    if cell.covered { x += "<table:covered-table-cell/>"; continue }
                    var attrs = "table:style-name=\"\(header ? "HeaderCell" : "Cell")\" office:value-type=\"string\""
                    if cell.colSpan > 1 { attrs += " table:number-columns-spanned=\"\(cell.colSpan)\"" }
                    if cell.rowSpan > 1 { attrs += " table:number-rows-spanned=\"\(cell.rowSpan)\"" }
                    x += "<table:table-cell \(attrs)>"
                    if cell.paragraphs.isEmpty { x += "<text:p text:style-name=\"Table_20_Contents\"/>" }
                    for p in cell.paragraphs { x += paragraph(p, inCell: true, header: header) }
                    x += "</table:table-cell>"
                }
                x += "</table:table-row>"
                if r == t.headerRows - 1 { x += "</table:table-header-rows>" }
            }
            return x + "</table:table>"
        }

        // MARK: Other parts

        func styles() -> String {
            let f = richXMLEscape(doc.bodyFamily, attribute: true)
            let size = Builder.pt(doc.bodySize)
            var headings = ""
            for level in 1...6 {
                let color = level == 6 ? " fo:color=\"#737378\"" : ""
                headings += "<style:style style:name=\"Heading_20_\(level)\" style:display-name=\"Heading \(level)\" style:family=\"paragraph\" style:parent-style-name=\"Heading\" style:next-style-name=\"Standard\" style:default-outline-level=\"\(level)\" style:class=\"text\"><style:paragraph-properties fo:margin-top=\"\(level <= 2 ? "18pt" : "12pt")\" fo:margin-bottom=\"6pt\"/><style:text-properties fo:font-size=\"\(Builder.pt(headingSizes[level - 1]))\" fo:font-weight=\"bold\" style:font-weight-asian=\"bold\" style:font-weight-complex=\"bold\"\(color)/></style:style>"
            }
            let landscape = page.size.width > page.size.height
            return """
            <?xml version="1.0" encoding="UTF-8"?>
            <office:document-styles \(Builder.namespaces) office:version="1.3">\(fontDecls())<office:styles><style:default-style style:family="paragraph"><style:paragraph-properties style:writing-mode="page"/><style:text-properties style:font-name="\(f)" fo:font-size="\(size)" style:font-name-asian="\(f)" style:font-size-asian="\(size)" style:font-name-complex="\(f)" style:font-size-complex="\(size)" fo:language="en" fo:country="US"/></style:default-style><style:style style:name="Standard" style:family="paragraph" style:class="text"/><style:style style:name="Heading" style:family="paragraph" style:parent-style-name="Standard" style:next-style-name="Standard" style:class="text"><style:paragraph-properties fo:keep-with-next="always"/><style:text-properties fo:font-weight="bold"/></style:style>\(headings)<style:style style:name="Quotations" style:family="paragraph" style:parent-style-name="Standard" style:class="html"><style:paragraph-properties fo:margin-left="18pt" fo:margin-right="18pt" fo:padding-left="8pt" fo:border-left="2.25pt solid #CFCFD4" fo:border-right="none" fo:border-top="none" fo:border-bottom="none"/><style:text-properties fo:color="#5C5C66"/></style:style><style:style style:name="Preformatted_20_Text" style:display-name="Preformatted Text" style:family="paragraph" style:parent-style-name="Standard" style:class="html"><style:paragraph-properties fo:margin-top="0pt" fo:margin-bottom="0pt" fo:background-color="#F4F4F6" fo:padding-left="6pt" fo:padding-right="6pt"/><style:text-properties style:font-name="\(RichStyle.monoFamily)" fo:font-size="\(Builder.pt(RichStyle.codeSize * doc.bodySize / RichStyle.bodySize))" style:font-name-asian="\(RichStyle.monoFamily)" style:font-name-complex="\(RichStyle.monoFamily)"/></style:style><style:style style:name="Table_20_Contents" style:display-name="Table Contents" style:family="paragraph" style:parent-style-name="Standard" style:class="extra"/><style:style style:name="Table_20_Heading" style:display-name="Table Heading" style:family="paragraph" style:parent-style-name="Table_20_Contents" style:class="extra"><style:text-properties fo:font-weight="bold" style:font-weight-asian="bold" style:font-weight-complex="bold"/></style:style><style:style style:name="Internet_20_link" style:display-name="Internet link" style:family="text"><style:text-properties fo:color="#0B5CCC" style:text-underline-style="solid" style:text-underline-width="auto" style:text-underline-color="font-color"/></style:style></office:styles><office:automatic-styles><style:page-layout style:name="pm1"><style:page-layout-properties fo:page-width="\(Builder.pt(page.size.width))" fo:page-height="\(Builder.pt(page.size.height))" style:print-orientation="\(landscape ? "landscape" : "portrait")" fo:margin-top="\(Builder.pt(page.margins.top))" fo:margin-bottom="\(Builder.pt(page.margins.bottom))" fo:margin-left="\(Builder.pt(page.margins.left))" fo:margin-right="\(Builder.pt(page.margins.right))"/></style:page-layout></office:automatic-styles><office:master-styles><style:master-page style:name="Standard" style:page-layout-name="pm1"/></office:master-styles></office:document-styles>
            """
        }

        func meta() -> String {
            let now = ISO8601DateFormatter().string(from: Date())
            let title = doc.title.map { "<dc:title>\(richXMLEscape($0))</dc:title>" } ?? ""
            return """
            <?xml version="1.0" encoding="UTF-8"?>
            <office:document-meta \(Builder.namespaces) office:version="1.3"><office:meta><meta:generator>YummyOrange</meta:generator>\(title)<meta:creation-date>\(now)</meta:creation-date><dc:date>\(now)</dc:date></office:meta></office:document-meta>
            """
        }

        func manifest() -> String {
            var x = """
            <?xml version="1.0" encoding="UTF-8"?>
            <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3"><manifest:file-entry manifest:full-path="/" manifest:version="1.3" manifest:media-type="application/vnd.oasis.opendocument.text"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/><manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/><manifest:file-entry manifest:full-path="meta.xml" manifest:media-type="text/xml"/>
            """
            for (i, image) in pictures.enumerated() {
                x += "<manifest:file-entry manifest:full-path=\"Pictures/image\(i + 1).\(image.fileExtension)\" manifest:media-type=\"\(image.mimeType)\"/>"
            }
            return x + "</manifest:manifest>"
        }
    }
}

/// Reads OpenDocument text with Cocoa's importer, which handles text, lists, tables and links but drops
/// pictures, heading levels, merged cells (it ignores covered cells, so later cells slide left) and list
/// start numbers. Before Cocoa reads a copy of the file, content.xml gets placeholders for all of these:
/// picture frames become tokens, headings and numbered items get a marker with their level or number,
/// merged cells a marker paragraph with their span, and covered cells become marked empty cells. After
/// the import the markers are turned back into pictures, header levels, spans and list numbers.
enum RichODTReader {
    private static func token(_ n: Int) -> String { String(format: "DWODTPIC%05dX", n) }

    static func read(_ url: URL) throws -> NSAttributedString {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.openDocument]
        guard let zip = try? ZipReader(url: url) else { return try NSAttributedString(url: url, options: options, documentAttributes: nil) }
        // No entity declarations (Cocoa's importer would resolve them) and no absurd nesting (it recurses per
        // level). Parts with a bare <!DOCTYPE> go to Cocoa without it.
        var cleaned: [String: Data] = [:]
        for entry in zip.entries where !entry.isDirectory && entry.name.lowercased().hasSuffix(".xml") {
            guard let data = try? zip.read(entry) else { continue }
            do {
                let safe = try RichXMLSafety.checked(data)
                if safe != data { cleaned[entry.name] = safe }
            } catch let refused as RichXMLSafety.Refused {
                throw ConversionError.unsupported(refused.tooDeep
                    ? "\(url.lastPathComponent) nests its contents more than \(RichLimits.xmlParseDepth) levels deep, which no real document does. YummyOrange won’t open it."
                    : "\(url.lastPathComponent) declares XML entities (in a <!DOCTYPE>), which OpenDocument files never do. YummyOrange won’t open it.")
            }
        }
        guard let content = cleaned["content.xml"].map({ String(decoding: $0, as: UTF8.self) }) ?? (try? zip.readString("content.xml")) else {
            guard cleaned.isEmpty else { throw ConversionError.unreadable(url.lastPathComponent) }
            return try NSAttributedString(url: url, options: options, documentAttributes: nil)
        }
        var pictures: [RichImage] = []
        var rewritten = content
        if content.contains("<draw:image") {
            rewritten = ""
            let ns = content as NSString
            var last = 0
            let frameRE = try NSRegularExpression(pattern: "<draw:frame\\b([^>]*)>((?:(?!<draw:frame\\b)[\\s\\S])*?)</draw:frame>")
            for m in frameRE.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
                let attrs = ns.substring(with: m.range(at: 1)), inner = ns.substring(with: m.range(at: 2))
                guard let href = firstMatch("<draw:image\\b[^>]*xlink:href=\"([^\"]+)\"", inner),
                      !href.contains(":"), let data = try? zip.read(href.removingPercentEncoding ?? href) else { continue }
                var display: CGSize?
                if let w = firstMatch("svg:width=\"([^\"]+)\"", attrs).flatMap(points), let h = firstMatch("svg:height=\"([^\"]+)\"", attrs).flatMap(points) {
                    display = CGSize(width: w, height: h)
                }
                let alt = firstMatch("<svg:title>([^<]*)</svg:title>", inner) ?? firstMatch("<svg:desc>([^<]*)</svg:desc>", inner) ?? ""
                guard let image = RichImage.from(data: data, name: (href as NSString).lastPathComponent,
                                                 alt: MDInlineParser.decodeEntities(alt), display: display) else { continue }
                rewritten += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                rewritten += token(pictures.count)
                pictures.append(image)
                last = NSMaxRange(m.range)
            }
            rewritten += ns.substring(from: last)
        }
        var listStyles = Structure.listStyles(content)
        if let styles = cleaned["styles.xml"].map({ String(decoding: $0, as: UTF8.self) }) ?? (try? zip.readString("styles.xml")) {
            for (name, levels) in Structure.listStyles(styles) where listStyles[name] == nil { listStyles[name] = levels }
        }
        let (marked, changed) = Structure.mark(rewritten, listStyles: listStyles)
        guard !pictures.isEmpty || changed || !cleaned.isEmpty else { return try NSAttributedString(url: url, options: options, documentAttributes: nil) }

        let copy = ZipWriter()
        if zip.contains("mimetype") { try copy.add("mimetype", data: try zip.read("mimetype"), compress: false) }
        for entry in zip.entries where entry.name != "mimetype" && !entry.isDirectory {
            try copy.add(entry.name, data: entry.name == "content.xml" ? Data(marked.utf8) : try cleaned[entry.name] ?? zip.read(entry))
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-\(UUID().uuidString).odt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try copy.write(to: tmp)
        let text = NSMutableAttributedString(attributedString: try NSAttributedString(url: tmp, options: options, documentAttributes: nil))
        Structure.apply(text, pictures: pictures)
        return text
    }

    /// Markers for what Cocoa's ODT importer drops, put into content.xml and taken back out after it.
    enum Structure {
        /// Per list style, per level (1-based): its numbering ("1", "a", "A", "i", "I"; "" for bullets) and start.
        typealias ListStyles = [String: [Int: (format: String, start: Int)]]

        static let markerRE = try! NSRegularExpression(pattern: "DWODT(?:PIC(\\d{5})|H(\\d)|N(\\d{1,9})S([daAiI])|S(\\d{1,4})x(\\d{1,4})|C)X")

        /// One tag of an XML text: its name, whether it closes or is empty, its attributes, where it ends.
        private struct Tag {
            var name: String
            var closing: Bool
            var empty: Bool
            var raw: String
            func attr(_ key: String) -> String? {
                guard let r = raw.range(of: "\\s\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*(\"[^\"]*\"|'[^']*')", options: .regularExpression) else { return nil }
                let v = raw[r]
                guard let q = v.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
                return String(v[v.index(after: q)..<v.index(before: v.endIndex)])
            }
        }

        /// Walks the tags of an XML text, handing each to `visit` with the text before it. Comments, CDATA
        /// and processing instructions pass through as text; quoted attribute values may hold '>'.
        private static func walk(_ xml: String, _ visit: (_ before: Substring, _ tag: Tag?) -> Void) {
            let u = xml.utf8
            var textStart = u.startIndex
            var i = u.startIndex
            func find(_ end: String, from: String.UTF8View.Index) -> String.UTF8View.Index {
                let e = Array(end.utf8)
                var k = from
                while k < u.endIndex {
                    if u[k] == e[0] {
                        var m = k, j = 0
                        while j < e.count, m < u.endIndex, u[m] == e[j] { m = u.index(after: m); j += 1 }
                        if j == e.count { return m }
                    }
                    k = u.index(after: k)
                }
                return u.endIndex
            }
            while i < u.endIndex {
                guard u[i] == UInt8(ascii: "<") else { i = u.index(after: i); continue }
                let rest = xml[i...]
                var end: String.UTF8View.Index
                if rest.hasPrefix("<!--") { end = find("-->", from: u.index(i, offsetBy: 4)) }
                else if rest.hasPrefix("<![CDATA[") { end = find("]]>", from: u.index(i, offsetBy: 9)) }
                else if rest.hasPrefix("<?") { end = find("?>", from: u.index(i, offsetBy: 2)) }
                else if rest.hasPrefix("<!") { end = find(">", from: u.index(i, offsetBy: 2)) }
                else {
                    // A tag: up to the '>' outside quotes.
                    var k = u.index(after: i), quote: UInt8 = 0
                    while k < u.endIndex {
                        let c = u[k]
                        if quote != 0 { if c == quote { quote = 0 } }
                        else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") { quote = c }
                        else if c == UInt8(ascii: ">") { break }
                        k = u.index(after: k)
                    }
                    guard k < u.endIndex else { break }
                    let raw = String(xml[i...k])
                    visit(xml[textStart..<i], nil)
                    let closing = raw.hasPrefix("</")
                    let name = String(raw.dropFirst(closing ? 2 : 1).prefix { !$0.isWhitespace && $0 != "/" && $0 != ">" })
                    visit("", Tag(name: name, closing: closing, empty: raw.hasSuffix("/>"), raw: raw))
                    i = u.index(after: k)
                    textStart = i
                    continue
                }
                i = end   // comments and the like stay part of the text
            }
            visit(xml[textStart...], nil)
        }

        static func listStyles(_ xml: String) -> ListStyles {
            var out: ListStyles = [:]
            var current: String?
            walk(xml) { _, tag in
                guard let tag else { return }
                switch tag.name {
                case "text:list-style":
                    if tag.closing { current = nil } else if !tag.empty { current = tag.attr("style:name") }
                case "text:list-level-style-number", "text:list-level-style-bullet", "text:list-level-style-image":
                    guard !tag.closing, let name = current, let level = tag.attr("text:level").flatMap(Int.init) else { return }
                    let number = tag.name == "text:list-level-style-number"
                    let format = number ? (tag.attr("style:num-format") ?? "1") : ""
                    out[name, default: [:]][level] = (format, tag.attr("text:start-value").flatMap(Int.init) ?? 1)
                default: break
                }
            }
            return out
        }

        /// content.xml with the markers in, and whether there was anything to mark.
        static func mark(_ xml: String, listStyles: ListStyles) -> (String, Bool) {
            var out = ""
            out.reserveCapacity(xml.utf8.count + 1024)
            var changed = false
            // Open lists: their style (inherited by nested lists) and level; counters per level.
            var lists: [String?] = []
            var counters: [Int] = []
            var pendingNumber: String?
            var skippingCovered = 0
            walk(xml) { before, tag in
                if skippingCovered == 0 { out += before }
                guard let tag else { return }
                if skippingCovered > 0 {
                    if tag.name == "table:covered-table-cell" {
                        if tag.closing { skippingCovered -= 1 } else if !tag.empty { skippingCovered += 1 }
                    }
                    return
                }
                switch (tag.name, tag.closing) {
                case ("text:list", false) where !tag.empty:
                    let style = tag.attr("text:style-name") ?? lists.last ?? nil
                    if lists.isEmpty, tag.attr("text:continue-numbering") != "true", tag.attr("text:continue-list") == nil { counters = [] }
                    lists.append(style)
                    out += tag.raw
                case ("text:list", true):
                    if !lists.isEmpty { lists.removeLast() }
                    out += tag.raw
                case ("text:list-item", false):
                    let level = max(1, lists.count)
                    while counters.count < level { counters.append(Int.min) }
                    counters.removeSubrange(level...)
                    let info = (lists.last ?? nil).flatMap { listStyles[$0]?[min(level, 10)] }
                    if let info, ["1", "a", "A", "i", "I"].contains(info.format) {
                        let n = tag.attr("text:start-value").flatMap(Int.init)
                            ?? (counters[level - 1] == Int.min ? info.start : counters[level - 1] + 1)
                        counters[level - 1] = n
                        let code = info.format == "1" ? "d" : info.format
                        pendingNumber = "DWODTN\(max(0, n))S\(code)X"
                    } else {
                        counters[level - 1] = counters[level - 1] == Int.min ? 1 : counters[level - 1] + 1
                        pendingNumber = nil
                    }
                    out += tag.raw
                case ("text:list-header", false):
                    pendingNumber = nil
                    out += tag.raw
                case ("text:p", false), ("text:h", false):
                    var markers = pendingNumber ?? ""
                    pendingNumber = nil
                    if tag.name == "text:h" {
                        let level = min(6, max(1, tag.attr("text:outline-level").flatMap(Int.init) ?? 1))
                        markers += "DWODTH\(level)X"
                    }
                    if markers.isEmpty { out += tag.raw; return }
                    changed = true
                    if tag.empty { out += String(tag.raw.dropLast(2)) + ">" + markers + "</\(tag.name)>" } else { out += tag.raw + markers }
                case ("table:table-cell", false):
                    let cols = max(1, min(1000, tag.attr("table:number-columns-spanned").flatMap(Int.init) ?? 1))
                    let rows = max(1, min(1000, tag.attr("table:number-rows-spanned").flatMap(Int.init) ?? 1))
                    guard cols > 1 || rows > 1 else { out += tag.raw; return }
                    changed = true
                    let marker = "<text:p>DWODTS\(cols)x\(rows)X</text:p>"
                    if tag.empty { out += String(tag.raw.dropLast(2)) + ">" + marker + "</table:table-cell>" } else { out += tag.raw + marker }
                case ("table:covered-table-cell", false):
                    // A real (marked) cell, so the cells after it keep their columns.
                    changed = true
                    let repeated = max(1, min(1000, tag.attr("table:number-columns-repeated").flatMap(Int.init) ?? 1))
                    out += String(repeating: "<table:table-cell><text:p>DWODTCX</text:p></table:table-cell>", count: repeated)
                    if !tag.empty { skippingCovered = 1 }
                case ("table:covered-table-cell", true):
                    break
                default:
                    out += tag.raw
                }
            }
            return (out, changed)
        }

        /// Turns the markers in the imported text back into pictures, header levels, spans and list numbers.
        static func apply(_ text: NSMutableAttributedString, pictures: [RichImage]) {
            let found = markerRE.matches(in: text.string, range: NSRange(location: 0, length: text.length))
            for m in found.reversed() {
                let s = text.string as NSString
                func group(_ k: Int) -> String? { m.range(at: k).location == NSNotFound ? nil : s.substring(with: m.range(at: k)) }
                let para = s.paragraphRange(for: m.range)
                if let pic = group(1).flatMap(Int.init), pic < pictures.count {
                    let image = pictures[pic]
                    let wrapper = FileWrapper(regularFileWithContents: image.data)
                    wrapper.preferredFilename = image.name
                    let attachment = NSTextAttachment(fileWrapper: wrapper)
                    attachment.bounds = CGRect(origin: .zero, size: image.displaySize)
                    var a = text.attributes(at: m.range.location, effectiveRange: nil)
                    a[.attachment] = attachment
                    a[.dwImageAlt] = image.alt
                    text.replaceCharacters(in: m.range, with: NSAttributedString(string: "\u{FFFC}", attributes: a))
                } else if let level = group(2).flatMap(Int.init) {
                    text.deleteCharacters(in: m.range)
                    let r = NSRange(location: para.location, length: max(0, para.length - m.range.length))
                    if r.length > 0 || para.location < text.length {
                        let at = min(para.location, max(0, text.length - 1))
                        let style = (text.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                            ?? NSMutableParagraphStyle()
                        style.headerLevel = level
                        text.addAttribute(.paragraphStyle, value: style, range: r.length > 0 ? r : NSRange(location: at, length: text.length > 0 ? 1 : 0))
                    }
                } else if let n = group(3).flatMap(Int.init), let code = group(4) {
                    text.deleteCharacters(in: m.range)
                    let r = NSRange(location: para.location, length: max(0, para.length - m.range.length))
                    let style: RichListLevel.Style = ["d": .decimal, "a": .lowerAlpha, "A": .upperAlpha, "i": .lowerRoman, "I": .upperRoman][code] ?? .decimal
                    if r.length > 0 { text.addAttributes([.dwListNumber: n, .dwListStyle: style.rawValue], range: r) }
                } else if let cols = group(5).flatMap(Int.init), let rows = group(6).flatMap(Int.init) {
                    // The marker paragraph opens the merged cell: give the cell its span, then drop the marker.
                    let style = text.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle
                    if let block = style?.textBlocks.last as? NSTextTableBlock {
                        let spanned = respan(block, rows: rows, columns: cols)
                        var end = NSMaxRange(para)
                        while end < s.length {
                            let next = s.paragraphRange(for: NSRange(location: end, length: 0))
                            guard (text.attribute(.paragraphStyle, at: next.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.last === block else { break }
                            end = NSMaxRange(next)
                        }
                        var updates: [(NSRange, NSParagraphStyle)] = []
                        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: para.location, length: end - para.location)) { v, r, _ in
                            guard let ps = (v as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                            ps.textBlocks = ps.textBlocks.map { $0 === block ? spanned : $0 }
                            updates.append((r, ps))
                        }
                        for (r, ps) in updates { text.addAttribute(.paragraphStyle, value: ps, range: r) }
                        // Keep the cell's own paragraphs; the marker paragraph goes (unless it's all there is).
                        if end > NSMaxRange(para) { text.deleteCharacters(in: para) } else { text.deleteCharacters(in: m.range) }
                    } else {
                        text.deleteCharacters(in: m.range)
                    }
                } else {
                    // A covered cell: the whole marked cell goes (its slot belongs to the merged cell).
                    let style = text.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle
                    if style?.textBlocks.last is NSTextTableBlock, s.substring(with: para).trimmingCharacters(in: .whitespacesAndNewlines) == s.substring(with: m.range) {
                        text.deleteCharacters(in: para)
                    } else {
                        text.deleteCharacters(in: m.range)
                    }
                }
            }
        }

        /// A table cell like `block`, spanning `rows` × `columns`.
        static func respan(_ b: NSTextTableBlock, rows: Int, columns: Int) -> NSTextTableBlock {
            let cols = max(1, min(columns, b.table.numberOfColumns - b.startingColumn))
            let n = NSTextTableBlock(table: b.table, startingRow: b.startingRow, rowSpan: max(1, rows), startingColumn: b.startingColumn, columnSpan: cols)
            n.backgroundColor = b.backgroundColor
            n.verticalAlignment = b.verticalAlignment
            let edges: [NSRectEdge] = [.minX, .minY, .maxX, .maxY]
            for layer in [NSTextBlock.Layer.padding, .border, .margin] {
                for edge in edges { n.setWidth(b.width(for: layer, edge: edge), type: b.widthValueType(for: layer, edge: edge), for: layer, edge: edge) }
            }
            for edge in edges { if let c = b.borderColor(for: edge) { n.setBorderColor(c, for: edge) } }
            for d in [NSTextBlock.Dimension.width, .minimumWidth, .maximumWidth, .height, .minimumHeight, .maximumHeight] {
                n.setValue(b.value(for: d), type: b.valueType(for: d), for: d)
            }
            return n
        }
    }

    private static func firstMatch(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// "2.5in", "4cm", "30mm", "120pt", "96px" → points.
    private static func points(_ s: String) -> CGFloat? {
        let units: [(String, CGFloat)] = [("in", 72), ("cm", 72 / 2.54), ("mm", 72 / 25.4), ("pt", 1), ("pc", 12), ("px", 0.75)]
        for (u, f) in units where s.hasSuffix(u) {
            return Double(s.dropLast(u.count)).map { CGFloat($0) * f }
        }
        return Double(s).map { CGFloat($0) }
    }
}
