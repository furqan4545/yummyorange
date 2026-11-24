import AppKit

/// Page size and margins, in points.
struct RichPageSetup {
    var size: CGSize
    var margins: NSEdgeInsets

    /// A4 or US Letter from the region, with one-inch margins.
    static var regional: RichPageSetup {
        RichPageSetup(size: Locale.current.measurementSystem == .us ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89),
                  margins: NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72))
    }

    var textWidth: CGFloat { size.width - margins.left - margins.right }
}

/// Writes Word documents (Office Open XML) from a RichDocument. Unlike Cocoa's writer it keeps pictures,
/// uses Word's built-in heading styles (so the navigation pane and table of contents work), real
/// numbered and bulleted lists, tables with merged cells, hyperlinks, quotes, code and page breaks.
enum RichDOCXWriter {
    static func write(_ doc: RichDocument, to url: URL, page: RichPageSetup = .regional) throws {
        var w = Builder(doc: doc, page: page)
        let body = w.body()
        let zip = ZipWriter()
        try zip.add("[Content_Types].xml", string: w.contentTypes())
        try zip.add("_rels/.rels", string: Builder.rootRels)
        try zip.add("docProps/core.xml", string: w.core())
        try zip.add("docProps/app.xml", string: Builder.app)
        try zip.add("word/document.xml", string: body)
        try zip.add("word/styles.xml", string: w.styles())
        try zip.add("word/numbering.xml", string: w.numbering())
        try zip.add("word/settings.xml", string: Builder.settings)
        try zip.add("word/fontTable.xml", string: w.fontTable())
        try zip.add("word/_rels/document.xml.rels", string: w.documentRels())
        for (i, image) in w.media.enumerated() {
            try zip.add("word/media/image\(i + 1).\(image.fileExtension)", data: image.data, compress: false)
        }
        try zip.write(to: url)
    }

    /// Collects pictures, links, lists and fonts while the body is written, then writes the other parts.
    private struct Builder {
        let doc: RichDocument
        let page: RichPageSetup
        var media: [RichImage] = []
        var links: [String] = []
        /// One entry per list: the level styles at each depth (index = ilvl).
        var lists: [[RichListLevel]] = []
        var fonts: Set<String> = []
        var drawingID = 0
        /// Per heading level, the size most of its text uses (so runs rarely need their own size).
        let headingSizes: [CGFloat]

        init(doc: RichDocument, page: RichPageSetup) {
            self.doc = doc
            self.page = page
            var sizes: [CGFloat] = []
            for level in 1...6 {
                var count: [CGFloat: Int] = [:]
                for case .paragraph(let p) in doc.blocks where p.headingLevel == level {
                    for r in p.runs where r.image == nil { count[(r.size * 2).rounded() / 2, default: 0] += r.text.count }
                }
                let fallback = RichStyle.headingSizes[level - 1] * doc.bodySize / RichStyle.bodySize
                sizes.append(count.max { $0.value < $1.value }?.key ?? fallback)
            }
            headingSizes = sizes
            fonts.insert(doc.bodyFamily)
        }

        static func twips(_ pt: CGFloat) -> Int { Int((pt * 20).rounded()) }
        static func half(_ pt: CGFloat) -> Int { Int((pt * 2).rounded()) }

        // MARK: Body

        mutating func body() -> String {
            var x = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>
            """
            var listIndex = -1
            var inList = false
            var lastTop: (style: RichListLevel.Style, number: Int)?
            let blocks = doc.blocks
            for (i, block) in blocks.enumerated() {
                switch block {
                case .paragraph(let p):
                    if !p.list.isEmpty {
                        // A new list starts after any non-list block, when the outer list changes kind, or when
                        // an outer numbered list starts counting again.
                        if p.list.count == 1, !p.listContinuation, let top = lastTop,
                           top.style != p.list[0].style || (p.list[0].ordered && p.itemNumber <= top.number) {
                            inList = false
                        }
                        if !inList { lists.append([]); listIndex = lists.count - 1; inList = true }
                        if p.list.count == 1, !p.listContinuation { lastTop = (p.list[0].style, p.itemNumber) }
                        for (d, level) in p.list.enumerated() where d < 9 {
                            if lists[listIndex].count <= d { lists[listIndex].append(level) }
                        }
                    } else {
                        inList = false
                        lastTop = nil
                    }
                    // Code paragraphs of one block run together; a new block gets space before it.
                    let prevCode = i > 0 ? { if case .paragraph(let q) = blocks[i - 1] { return q.sameCodeBlock(p) } else { return false } }() : false
                    let nextCode = i + 1 < blocks.count ? { if case .paragraph(let q) = blocks[i + 1] { return p.sameCodeBlock(q) } else { return false } }() : false
                    x += paragraph(p, numId: p.list.isEmpty ? nil : listIndex + 1, codeEdges: (!prevCode, !nextCode))
                case .table(let t):
                    inList = false
                    x += table(t)
                    // Word needs a paragraph between two tables and after a table that ends the document.
                    let next: RichBlock? = i + 1 < blocks.count ? blocks[i + 1] : nil
                    if next == nil || { if case .table = next! { return true } else { return false } }() {
                        x += "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/></w:pPr></w:p>"
                    }
                case .rule:
                    inList = false
                    x += "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"C8C8CC\"/></w:pBdr><w:spacing w:before=\"120\" w:after=\"240\"/></w:pPr></w:p>"
                case .pageBreak:
                    inList = false
                    x += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
                }
            }
            let landscape = page.size.width > page.size.height
            x += "<w:sectPr><w:pgSz w:w=\"\(Builder.twips(page.size.width))\" w:h=\"\(Builder.twips(page.size.height))\"\(landscape ? " w:orient=\"landscape\"" : "")/>"
            x += "<w:pgMar w:top=\"\(Builder.twips(page.margins.top))\" w:right=\"\(Builder.twips(page.margins.right))\" w:bottom=\"\(Builder.twips(page.margins.bottom))\" w:left=\"\(Builder.twips(page.margins.left))\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/><w:cols w:space=\"708\"/></w:sectPr>"
            return x + "</w:body></w:document>"
        }

        /// The size a paragraph's style gives its text.
        func styleSize(_ p: RichParagraph) -> CGFloat {
            if let level = p.headingLevel { return headingSizes[level - 1] }
            if p.codeLanguage != nil { return RichStyle.codeSize * doc.bodySize / RichStyle.bodySize }
            return doc.bodySize
        }

        mutating func paragraph(_ p: RichParagraph, numId: Int?, codeEdges: (first: Bool, last: Bool) = (true, true), inCell: Bool = false) -> String {
            var ppr = ""
            if let level = p.headingLevel { ppr += "<w:pStyle w:val=\"Heading\(level)\"/>" }
            else if p.codeLanguage != nil { ppr += "<w:pStyle w:val=\"SourceCode\"/>" }
            else if p.quoteDepth > 0 { ppr += "<w:pStyle w:val=\"Quote\"/>" }
            else if !p.list.isEmpty && !inCell { ppr += "<w:pStyle w:val=\"ListParagraph\"/>" }
            if let numId, !p.listContinuation, !inCell {
                ppr += "<w:numPr><w:ilvl w:val=\"\(min(8, p.list.count - 1))\"/><w:numId w:val=\"\(numId)\"/></w:numPr>"
            }
            if p.quoteDepth > 0 {
                ppr += "<w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:space=\"8\" w:color=\"CFCFD4\"/></w:pBdr>"
            }
            if let bg = p.background ?? (p.codeLanguage != nil ? "F4F4F6" : nil) { ppr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(bg)\"/>" }
            if p.rtl { ppr += "<w:bidi/>" }
            if p.codeLanguage != nil {
                ppr += "<w:spacing w:before=\"\(codeEdges.first ? 120 : 0)\" w:after=\"\(codeEdges.last ? 160 : 0)\" w:line=\"240\" w:lineRule=\"auto\"/>"
            } else {
                var spacing = "<w:spacing w:before=\"\(Builder.twips(p.spaceBefore))\" w:after=\"\(Builder.twips(p.spaceAfter))\""
                if p.lineHeight > 0.5 { spacing += " w:line=\"\(Int((p.lineHeight * 240).rounded()))\" w:lineRule=\"auto\"" }
                ppr += spacing + "/>"
            }
            if p.quoteDepth > 0 {
                ppr += "<w:ind w:left=\"\(360 * p.quoteDepth + Builder.twips(p.leftIndent))\" w:right=\"360\"/>"
            } else if !p.list.isEmpty && p.listContinuation {
                ppr += "<w:ind w:left=\"\(720 * min(9, p.list.count))\"/>"
            } else if p.list.isEmpty, p.leftIndent > 0.5 || abs(p.firstLineIndent) > 0.5 {
                let first = p.firstLineIndent >= 0 ? "w:firstLine=\"\(Builder.twips(p.firstLineIndent))\"" : "w:hanging=\"\(Builder.twips(-p.firstLineIndent))\""
                ppr += "<w:ind w:left=\"\(Builder.twips(max(0, p.leftIndent)))\" \(first)/>"
            }
            // In a right-to-left paragraph Word's left/right mean start/end.
            switch p.alignment {
            case .center: ppr += "<w:jc w:val=\"center\"/>"
            case .right: ppr += "<w:jc w:val=\"\(p.rtl ? "left" : "right")\"/>"
            case .left where p.rtl: ppr += "<w:jc w:val=\"right\"/>"
            case .justified: ppr += "<w:jc w:val=\"both\"/>"
            default: break
            }
            var runs = p.runs
            if let task = p.task { runs.insert(RichRun(text: task ? "☑ " : "☐ ", size: styleSize(p)), at: 0) }
            // A hidden bookmark marks where a code block starts, so two blocks in a row read back as two.
            var mark = ""
            if p.codeLanguage != nil, codeEdges.first {
                drawingID += 1
                mark = "<w:bookmarkStart w:id=\"\(drawingID)\" w:name=\"_DWCode\(drawingID)\"/><w:bookmarkEnd w:id=\"\(drawingID)\"/>"
            }
            return "<w:p><w:pPr>\(ppr)</w:pPr>" + mark + self.runs(runs, p) + "</w:p>"
        }

        mutating func runs(_ runs: [RichRun], _ p: RichParagraph) -> String {
            var x = ""
            var i = 0
            while i < runs.count {
                if let link = runs[i].link, RichDocument.isSafeLink(link) {
                    var group: [RichRun] = []
                    while i < runs.count, runs[i].link == link { group.append(runs[i]); i += 1 }
                    let inner = group.map { run($0, p, hyperlink: true) }.joined()
                    if link.hasPrefix("#") {
                        x += "<w:hyperlink w:anchor=\"\(richXMLEscape(String(link.dropFirst()), attribute: true))\" w:history=\"1\">\(inner)</w:hyperlink>"
                    } else {
                        links.append(link)
                        x += "<w:hyperlink r:id=\"rIdL\(links.count)\" w:history=\"1\">\(inner)</w:hyperlink>"
                    }
                } else {
                    x += run(runs[i], p, hyperlink: false)
                    i += 1
                }
            }
            return x
        }

        mutating func run(_ r: RichRun, _ p: RichParagraph, hyperlink: Bool) -> String {
            if let image = r.image { return drawing(image) }
            var rpr = ""
            if r.code { rpr += "<w:rStyle w:val=\"InlineCode\"/>" } else if hyperlink { rpr += "<w:rStyle w:val=\"Hyperlink\"/>" }
            // Font, size and weight are also written on each run, not only in the styles: Word reads either,
            // but Cocoa's importer (TextEdit, Quick Look) ignores styles.
            let code = r.code || p.codeLanguage != nil
            let family = code ? RichStyle.monoFamily : (r.family ?? doc.bodyFamily)
            fonts.insert(family)
            let f = richXMLEscape(family, attribute: true)
            rpr += "<w:rFonts w:ascii=\"\(f)\" w:hAnsi=\"\(f)\" w:eastAsia=\"\(f)\" w:cs=\"\(f)\"/>"
            if r.bold { rpr += "<w:b/><w:bCs/>" } else if p.headingLevel != nil { rpr += "<w:b w:val=\"0\"/>" }
            if r.italic { rpr += "<w:i/><w:iCs/>" }
            if r.strike { rpr += "<w:strike/>" }
            if let c = r.color { rpr += "<w:color w:val=\"\(c)\"/>" }
            else if hyperlink { rpr += "<w:color w:val=\"0B5CCC\"/>" }
            else if p.headingLevel == 6 { rpr += "<w:color w:val=\"737378\"/>" }
            let size = code ? RichStyle.codeSize * doc.bodySize / RichStyle.bodySize : (r.script != 0 ? max(r.size, styleSize(p)) : r.size)
            rpr += "<w:sz w:val=\"\(Builder.half(size))\"/><w:szCs w:val=\"\(Builder.half(size))\"/>"
            if hyperlink && !r.underline { rpr += "<w:u w:val=\"single\"/>" }
            if r.underline { rpr += "<w:u w:val=\"single\"/>" }
            if let h = r.highlight ?? (r.code ? "F2F2F4" : nil) { rpr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(h)\"/>" }
            if r.script != 0 { rpr += "<w:vertAlign w:val=\"\(r.script > 0 ? "superscript" : "subscript")\"/>" }
            if p.rtl, RichDocument.startsRightToLeft(r.text) { rpr += "<w:rtl/>" }
            let open = "<w:r>" + (rpr.isEmpty ? "" : "<w:rPr>\(rpr)</w:rPr>")
            // Tabs and line breaks are elements of their own in WordprocessingML.
            var x = ""
            var text = ""
            func flushText() {
                if !text.isEmpty { x += "<w:t xml:space=\"preserve\">\(richXMLEscape(text))</w:t>"; text = "" }
            }
            let special: Set<UInt16> = [0x09, 0x0A, 0x0D, 0x0C, 0xAD, 0x2028, 0x2029]
            if !r.text.utf16.contains(where: special.contains) {
                let t = richXMLEscape(r.text)
                return t.isEmpty ? "" : open + "<w:t xml:space=\"preserve\">\(t)</w:t></w:r>"
            }
            for ch in r.text {
                switch ch {
                case "\t": flushText(); x += "<w:tab/>"
                case "\u{2028}", "\n", "\r", "\u{2029}": flushText(); x += "<w:br/>"
                case "\u{0C}": flushText(); x += "<w:br w:type=\"page\"/>"
                case "\u{00AD}": flushText(); x += "<w:softHyphen/>"
                default: text.append(ch)
                }
            }
            flushText()
            return x.isEmpty ? "" : open + x + "</w:r>"
        }

        mutating func drawing(_ image: RichImage) -> String {
            media.append(image)
            drawingID += 1
            let n = media.count
            var size = image.displaySize
            let maxW = page.textWidth, maxH = page.size.height - page.margins.top - page.margins.bottom
            let scale = min(1, maxW / max(size.width, 1), maxH / max(size.height, 1))
            size = CGSize(width: size.width * scale, height: size.height * scale)
            let cx = Int(size.width * 12700), cy = Int(size.height * 12700)
            let descr = richXMLEscape(image.alt, attribute: true)
            return """
            <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:docPr id="\(drawingID)" name="Picture \(drawingID)" descr="\(descr)"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(drawingID)" name="image\(n).\(image.fileExtension)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rIdI\(n)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
            """
        }

        mutating func table(_ t: RichTable) -> String {
            let cols = max(1, t.columns)
            let width = Builder.twips(page.textWidth)
            let colW = width / cols
            let border = "w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"BFBFC7\""
            var x = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"\(width)\" w:type=\"dxa\"/><w:tblBorders><w:top \(border)/><w:left \(border)/><w:bottom \(border)/><w:right \(border)/><w:insideH \(border)/><w:insideV \(border)/></w:tblBorders><w:tblLook w:val=\"04A0\" w:firstRow=\"1\" w:lastRow=\"0\" w:firstColumn=\"0\" w:lastColumn=\"0\" w:noHBand=\"0\" w:noVBand=\"1\"/></w:tblPr><w:tblGrid>"
            x += String(repeating: "<w:gridCol w:w=\"\(colW)\"/>", count: cols) + "</w:tblGrid>"
            // Which cell covers each slot, so vertical merges can be written as continuations.
            var owner: [[(Int, Int)?]] = Array(repeating: Array(repeating: nil, count: cols), count: t.rows.count)
            for (r, row) in t.rows.enumerated() {
                for (c, cell) in row.enumerated() where !cell.covered && c < cols {
                    for rr in r..<min(t.rows.count, r + cell.rowSpan) { for cc in c..<min(cols, c + cell.colSpan) { owner[rr][cc] = (r, c) } }
                }
            }
            for r in t.rows.indices {
                x += "<w:tr>" + (r < t.headerRows ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
                var c = 0
                while c < cols {
                    let (orow, ocol) = owner[r][c] ?? (r, c)
                    let cell = orow < t.rows.count && ocol < t.rows[orow].count ? t.rows[orow][ocol] : RichCell()
                    let span = max(1, min(cell.colSpan, cols - c))
                    var tcpr = "<w:tcW w:w=\"\(colW * span)\" w:type=\"dxa\"/>"
                    if span > 1 { tcpr += "<w:gridSpan w:val=\"\(span)\"/>" }
                    if cell.rowSpan > 1 { tcpr += orow == r ? "<w:vMerge w:val=\"restart\"/>" : "<w:vMerge/>" }
                    if let bg = cell.background ?? (r < t.headerRows ? "F0F0F2" : nil) {
                        tcpr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(bg)\"/>"
                    }
                    x += "<w:tc><w:tcPr>\(tcpr)</w:tcPr>"
                    if orow == r && ocol == c && !cell.paragraphs.isEmpty {
                        for var p in cell.paragraphs {
                            p.spaceBefore = 0
                            p.spaceAfter = 0
                            if r < t.headerRows { for k in p.runs.indices { p.runs[k].bold = true } }
                            x += paragraph(p, numId: nil, inCell: true)
                        }
                    } else {
                        x += "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/></w:pPr></w:p>"
                    }
                    x += "</w:tc>"
                    c += span
                }
                x += "</w:tr>"
            }
            return x + "</w:tbl>"
        }

        // MARK: Parts

        func contentTypes() -> String {
            var defaults = "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            for ext in Set(media.map(\.fileExtension)).sorted() {
                defaults += "<Default Extension=\"\(ext)\" ContentType=\"\(ext == "jpg" ? "image/jpeg" : "image/\(ext)")\"/>"
            }
            return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\(defaults)<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/><Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/><Override PartName="/word/fontTable.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.fontTable+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
            """
        }

        static let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
        """

        static let app = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>YummyOrange</Application></Properties>
        """

        static let settings = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:defaultTabStop w:val="720"/><w:characterSpacingControl w:val="doNotCompress"/><w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat></w:settings>
        """

        func core() -> String {
            let now = ISO8601DateFormatter().string(from: Date())
            let title = doc.title.map { "<dc:title>\(richXMLEscape($0))</dc:title>" } ?? ""
            return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\(title)<dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified></cp:coreProperties>
            """
        }

        func documentRels() -> String {
            var x = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/><Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/fontTable" Target="fontTable.xml"/>
            """
            for (i, image) in media.enumerated() {
                x += "<Relationship Id=\"rIdI\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/image\(i + 1).\(image.fileExtension)\"/>"
            }
            for (i, link) in links.enumerated() {
                x += "<Relationship Id=\"rIdL\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(richXMLEscape(link, attribute: true))\" TargetMode=\"External\"/>"
            }
            return x + "</Relationships>"
        }

        func fontTable() -> String {
            var x = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:fonts xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
            // Declaring the code font as fixed-pitch lets Word substitute another monospaced font if Menlo is missing.
            x += "<w:font w:name=\"\(RichStyle.monoFamily)\"><w:family w:val=\"modern\"/><w:pitch w:val=\"fixed\"/></w:font>"
            for f in fonts.sorted() where f != RichStyle.monoFamily {
                let mono = FontFacts.monoFamilies.contains(f.lowercased())
                x += "<w:font w:name=\"\(richXMLEscape(f, attribute: true))\"><w:family w:val=\"\(mono ? "modern" : "auto")\"/><w:pitch w:val=\"\(mono ? "fixed" : "variable")\"/></w:font>"
            }
            return x + "</w:fonts>"
        }

        func styles() -> String {
            let f = richXMLEscape(doc.bodyFamily, attribute: true)
            let mono = RichStyle.monoFamily
            let body = Builder.half(doc.bodySize)
            let code = Builder.half(RichStyle.codeSize * doc.bodySize / RichStyle.bodySize)
            var x = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="\(f)" w:hAnsi="\(f)" w:eastAsia="\(f)" w:cs="\(f)"/><w:sz w:val="\(body)"/><w:szCs w:val="\(body)"/><w:lang w:val="en-US" w:eastAsia="en-US" w:bidi="ar-SA"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
            <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
            <w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/><w:unhideWhenUsed/></w:style>
            <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>
            <w:style w:type="numbering" w:default="1" w:styleId="NoList"><w:name w:val="No List"/><w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/></w:style>
            """
            for level in 1...6 {
                let size = Builder.half(headingSizes[level - 1])
                let before = level <= 2 ? 360 : 240
                let color = level == 6 ? "<w:color w:val=\"737378\"/>" : ""
                x += "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:uiPriority w:val=\"9\"/><w:qFormat/><w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before=\"\(before)\" w:after=\"120\"/><w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr><w:rPr><w:b/><w:bCs/>\(color)<w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/></w:rPr></w:style>"
            }
            x += """
            <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="10"/><w:qFormat/><w:pPr><w:spacing w:after="240"/></w:pPr><w:rPr><w:b/><w:sz w:val="\(Builder.half(doc.bodySize * 2.3))"/></w:rPr></w:style>
            <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:uiPriority w:val="34"/><w:qFormat/><w:pPr><w:ind w:left="720"/></w:pPr></w:style>
            <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="29"/><w:qFormat/><w:rPr><w:color w:val="5C5C66"/></w:rPr></w:style>
            <w:style w:type="paragraph" w:styleId="SourceCode"><w:name w:val="Source Code"/><w:basedOn w:val="Normal"/><w:uiPriority w:val="99"/><w:qFormat/><w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F4F4F6"/><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:ind w:left="144" w:right="144"/></w:pPr><w:rPr><w:rFonts w:ascii="\(mono)" w:hAnsi="\(mono)" w:eastAsia="\(mono)" w:cs="\(mono)"/><w:noProof/><w:sz w:val="\(code)"/><w:szCs w:val="\(code)"/></w:rPr></w:style>
            <w:style w:type="character" w:styleId="InlineCode"><w:name w:val="Inline Code"/><w:basedOn w:val="DefaultParagraphFont"/><w:uiPriority w:val="99"/><w:rPr><w:rFonts w:ascii="\(mono)" w:hAnsi="\(mono)" w:eastAsia="\(mono)" w:cs="\(mono)"/><w:noProof/><w:sz w:val="\(code)"/><w:szCs w:val="\(code)"/><w:shd w:val="clear" w:color="auto" w:fill="F2F2F4"/></w:rPr></w:style>
            <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:basedOn w:val="DefaultParagraphFont"/><w:uiPriority w:val="99"/><w:unhideWhenUsed/><w:rPr><w:color w:val="0B5CCC"/><w:u w:val="single"/></w:rPr></w:style>
            <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/><w:uiPriority w:val="39"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="BFBFC7"/><w:left w:val="single" w:sz="4" w:space="0" w:color="BFBFC7"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="BFBFC7"/><w:right w:val="single" w:sz="4" w:space="0" w:color="BFBFC7"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="BFBFC7"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="BFBFC7"/></w:tblBorders><w:tblCellMar><w:top w:w="40" w:type="dxa"/><w:left w:w="108" w:type="dxa"/><w:bottom w:w="40" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>
            </w:styles>
            """
            return x
        }

        func numbering() -> String {
            var x = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
            for (n, levels) in lists.enumerated() {
                x += "<w:abstractNum w:abstractNumId=\"\(n)\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
                for ilvl in 0..<9 {
                    let level = ilvl < levels.count ? levels[ilvl]
                        : (levels.last?.ordered ?? false ? RichListLevel(style: [.decimal, .lowerAlpha, .lowerRoman][ilvl % 3]) : .defaultBullet(depth: ilvl))
                    let (fmt, text): (String, String)
                    switch level.style {
                    case .decimal: (fmt, text) = ("decimal", "%\(ilvl + 1).")
                    case .lowerAlpha: (fmt, text) = ("lowerLetter", "%\(ilvl + 1).")
                    case .upperAlpha: (fmt, text) = ("upperLetter", "%\(ilvl + 1).")
                    case .lowerRoman: (fmt, text) = ("lowerRoman", "%\(ilvl + 1).")
                    case .upperRoman: (fmt, text) = ("upperRoman", "%\(ilvl + 1).")
                    case .bullet: (fmt, text) = ("bullet", "•")
                    case .circle: (fmt, text) = ("bullet", "◦")
                    case .square: (fmt, text) = ("bullet", "▪")
                    case .dash: (fmt, text) = ("bullet", "–")
                    }
                    let left = 720 * (ilvl + 1)
                    x += "<w:lvl w:ilvl=\"\(ilvl)\"><w:start w:val=\"\(max(0, level.start))\"/><w:numFmt w:val=\"\(fmt)\"/><w:lvlText w:val=\"\(text)\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(left)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
                }
                x += "</w:abstractNum>"
            }
            for n in lists.indices {
                x += "<w:num w:numId=\"\(n + 1)\"><w:abstractNumId w:val=\"\(n)\"/></w:num>"
            }
            return x + "</w:numbering>"
        }
    }
}

