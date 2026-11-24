import AppKit
import CoreText

/// Prints a workbook as a paginated table: grid lines, a shaded bold header row repeated on every page,
/// column widths from the content (capped, with long text wrapped to a few lines and then cut with "…"),
/// landscape pages when the table is wide, pages down then across, and the sheet name, cell range and
/// page numbers in the header and footer. Drawn with Core Graphics and Core Text, so it runs on any thread.
enum SpreadsheetsPDF {
    static let maxPages = 5000

    struct Style {
        let font: CTFont
        let bold: CTFont
        let fontSize: CGFloat
        let lineHeight: CGFloat
        let ascent: CGFloat
        let padX: CGFloat = 4
        let padY: CGFloat = 3
        let minColumn: CGFloat = 26
        let maxColumn: CGFloat
        let maxLines: Int

        init(fontSize: CGFloat, maxColumn: CGFloat, maxLines: Int) {
            self.fontSize = fontSize
            font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            bold = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
            ascent = CTFontGetAscent(font)
            lineHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font) + 1)
            self.maxColumn = maxColumn
            self.maxLines = maxLines
        }
    }

    /// One printed page: a block of rows by a block of columns.
    struct Page { let sheet: Int; let rows: Range<Int>; let columns: Range<Int> }

    /// How one sheet is laid out.
    struct Plan {
        let sheetIndex: Int
        let widths: [CGFloat]
        let heights: [CGFloat]
        let header: Bool
        let paper: CGSize
        var pages: [Page]
    }

    static func write(_ book: Workbook, to url: URL, title: String, options: ToolOptions,
                      progress: (Double) -> Void) throws {
        let used = book.sheets.indices.filter { !book.sheets[$0].isEmpty }
        guard !used.isEmpty else { throw ConversionError.unsupported("\(title) has no cells to print.") }
        let style = Style(fontSize: CGFloat(min(max(options.double("fontSize", 9), 5), 24)),
                          maxColumn: CGFloat(min(max(options.double("maxColumnWidth", 220), 60), 500)),
                          maxLines: min(max(options.int("maxLines", 4), 1), 20))
        let portrait = paperSize(options.string("paper", "auto"))
        let margin: CGFloat = 36

        var plans: [Plan] = []
        var pageCount = 0
        let tooMany = tooManyPages(title: title, sheets: used.count)
        for i in used {
            let plan = try layout(book.sheets[i], index: i, book: book, style: style, portrait: portrait, margin: margin,
                                  orientation: options.string("orientation", "auto").lowercased(),
                                  repeatHeader: options.string("header", "auto").lowercased(), tooMany: tooMany)
            pageCount += plan.pages.count
            if pageCount > maxPages { throw tooMany }
            plans.append(plan)
        }

        var box = CGRect(origin: .zero, size: plans.first?.paper ?? portrait)
        let info: [CFString: Any] = [kCGPDFContextTitle: title as CFString, kCGPDFContextCreator: "YummyOrange" as CFString]
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw ConversionError.toolFailed("Couldn’t create the PDF.")
        }
        var printed = 0
        for plan in plans {
            let sheet = book.sheets[plan.sheetIndex]
            let merges = MergeMap(sheet.merges)
            for page in plan.pages {
                var pageBox = CGRect(origin: .zero, size: plan.paper)
                let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size) as CFData
                ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
                printed += 1
                drawPage(page, plan: plan, sheet: sheet, book: book, merges: merges, style: style, ctx: ctx, margin: margin,
                         title: title, number: printed, of: pageCount)
                ctx.endPDFPage()
                progress(Double(printed) / Double(pageCount))
            }
        }
        ctx.closePDF()
    }

    /// The page-limit error, with advice that fits the source: other formats than its own, and picking one
    /// sheet only when there are several.
    static func tooManyPages(title: String, sheets: Int) -> Error {
        let formats: String
        switch (title as NSString).pathExtension.lowercased() {
        case "csv": formats = "XLSX or TSV"
        case "tsv": formats = "XLSX or CSV"
        case "xlsx", "xlsm": formats = "ODS or CSV"
        default: formats = "XLSX or CSV"
        }
        let advice = "Convert it to \(formats) instead" + (sheets > 1 ? ", or convert one sheet at a time." : ".")
        return ConversionError.unsupported("\(title) would need more than \(SpreadsheetLimits.grouped(maxPages)) PDF pages. " + advice)
    }

    static func paperSize(_ choice: String) -> CGSize {
        switch choice.lowercased() {
        case "a4": return CGSize(width: 595.28, height: 841.89)
        case "letter", "us": return CGSize(width: 612, height: 792)
        case "legal": return CGSize(width: 612, height: 1008)
        case "a3": return CGSize(width: 841.89, height: 1190.55)
        default:
            return Locale.current.measurementSystem == .us ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
        }
    }

    // MARK: Layout

    private static func layout(_ sheet: Worksheet, index: Int, book: Workbook, style: Style, portrait: CGSize, margin: CGFloat,
                               orientation: String, repeatHeader: String, tooMany: Error) throws -> Plan {
        let columns = sheet.columnCount
        let merges = MergeMap(sheet.merges)
        // Natural column widths from a sample of rows.
        var widths = [CGFloat](repeating: style.minColumn, count: columns)
        let sampleStep = max(1, sheet.rowCount / 3000)
        var r = 0
        while r < sheet.rowCount {
            for (c, cell) in sheet.rows[r].enumerated() where !cell.value.isEmpty {
                if let m = merges.origin(r, c), m.c1 > m.c0 { continue }
                let text = SheetNumberFormat.display(cell.value, code: book.code(cell))
                let font = r == 0 ? style.bold : style.font
                let w = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                    .map { lineWidth(String($0), font: font, fontSize: style.fontSize) }.max() ?? 0
                widths[c] = max(widths[c], min(style.maxColumn, ceil(w + 2 * style.padX + 1)))
            }
            r += sampleStep
        }
        let total = widths.reduce(0, +)
        let landscape: Bool
        switch orientation {
        case "landscape": landscape = true
        case "portrait": landscape = false
        default: landscape = total > portrait.width - 2 * margin
        }
        let paper = landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
        let printWidth = paper.width - 2 * margin
        widths = widths.map { min($0, printWidth) }

        // Row heights: the tallest wrapped cell in each row.
        var heights = [CGFloat](repeating: style.lineHeight + 2 * style.padY, count: sheet.rowCount)
        for (r, row) in sheet.rows.enumerated() {
            var lines = 1
            for (c, cell) in row.enumerated() where !cell.value.isEmpty {
                guard cell.value.isText else { continue }    // numbers, dates and booleans stay on one line
                var width = widths[c]
                if let m = merges.origin(r, c) {
                    if m.r1 > m.r0 { continue }
                    width = (m.c0...min(m.c1, columns - 1)).reduce(0) { $0 + widths[$1] }
                }
                let text = SheetNumberFormat.display(cell.value, code: book.code(cell))
                lines = max(lines, lineCount(text, width: width - 2 * style.padX, font: r == 0 ? style.bold : style.font,
                                             style: style))
                if lines >= style.maxLines { break }
            }
            heights[r] = CGFloat(lines) * style.lineHeight + 2 * style.padY
        }

        let header: Bool
        switch repeatHeader {
        case "true", "yes", "1", "on": header = sheet.rowCount > 1
        case "false", "no", "0", "off": header = false
        default: header = sheet.hasHeaderRow
        }

        // Column groups that fit the page width.
        var groups: [Range<Int>] = []
        var start = 0, used: CGFloat = 0
        for c in 0..<columns {
            if c > start && used + widths[c] > printWidth {
                groups.append(start..<c)
                start = c; used = 0
            }
            used += widths[c]
        }
        groups.append(start..<max(columns, start + 1))

        // Row blocks that fit the page height, below the header row when it repeats.
        let headerRoom: CGFloat = 30, footerRoom: CGFloat = 24
        let printHeight = paper.height - 2 * margin - headerRoom - footerRoom
        var blocks: [Range<Int>] = []
        let firstBody = header ? 1 : 0
        let available = printHeight - (header ? heights[0] : 0)
        start = firstBody
        used = 0
        for r in firstBody..<sheet.rowCount {
            let h = min(heights[r], available)
            if r > start && used + h > available {
                blocks.append(start..<r)
                start = r; used = 0
            }
            used += h
        }
        if start < sheet.rowCount || blocks.isEmpty { blocks.append(start..<max(sheet.rowCount, start)) }

        if groups.count.multipliedReportingOverflow(by: blocks.count).partialValue > maxPages || groups.count > maxPages
            || blocks.count > maxPages { throw tooMany }
        var pages: [Page] = []
        for g in groups { for b in blocks { pages.append(Page(sheet: index, rows: b, columns: g)) } }
        return Plan(sheetIndex: index, widths: widths, heights: heights, header: header, paper: paper, pages: pages)
    }

    /// Width of one line of text.
    private static func lineWidth(_ s: String, font: CTFont, fontSize: CGFloat) -> CGFloat {
        if s.isEmpty { return 0 }
        let line = CTLineCreateWithAttributedString(attributed(s, font: font))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func attributed(_ s: String, font: CTFont, color: CGColor? = nil) -> CFAttributedString {
        // No ligatures, so text copied or extracted from the PDF reads "fl", not "ﬂ".
        var attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                    NSAttributedString.Key(kCTLigatureAttributeName as String): 0]
        if let color { attrs[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        return NSAttributedString(string: s, attributes: attrs) as CFAttributedString
    }

    /// Lines a text needs at a width, up to the style's maximum.
    private static func lineCount(_ s: String, width: CGFloat, font: CTFont, style: Style) -> Int {
        guard width > 0 else { return 1 }
        var count = 0
        for paragraph in s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let p = String(paragraph)
            if p.isEmpty || (p.utf8.count == p.count && CGFloat(p.count) * style.fontSize * 0.62 <= width) {
                count += 1
            } else {
                let ts = CTTypesetterCreateWithAttributedString(attributed(p, font: font))
                let length = (p as NSString).length
                var start = 0
                while start < length && count < style.maxLines {
                    let n = CTTypesetterSuggestLineBreak(ts, start, Double(width))
                    start += max(1, n)
                    count += 1
                }
            }
            if count >= style.maxLines { return style.maxLines }
        }
        return max(1, count)
    }

    // MARK: Drawing

    /// Merged ranges by their first cell, and which merge covers every other cell.
    struct MergeMap {
        private var origins: [Int: SheetRange] = [:]
        private var covered: [Int: Int] = [:]

        init(_ merges: [SheetRange]) {
            for m in merges where m.r1 > m.r0 || m.c1 > m.c0 {
                let key = m.r0 << 16 | m.c0
                origins[key] = m
                guard covered.count < 1_000_000 else { continue }
                for r in m.r0...min(m.r1, m.r0 + 5000) {
                    for c in m.c0...m.c1 where r != m.r0 || c != m.c0 { covered[r << 16 | c] = key }
                }
            }
        }

        var isEmpty: Bool { origins.isEmpty }
        func origin(_ r: Int, _ c: Int) -> SheetRange? { origins.isEmpty ? nil : origins[r << 16 | c] }
        func coveringOrigin(_ r: Int, _ c: Int) -> SheetRange? {
            guard !covered.isEmpty, let key = covered[r << 16 | c] else { return nil }
            return origins[key]
        }
    }

    private static func drawPage(_ page: Page, plan: Plan, sheet: Worksheet, book: Workbook, merges: MergeMap, style: Style,
                                 ctx: CGContext, margin: CGFloat, title: String, number: Int, of total: Int) {
        let paper = plan.paper
        let top = paper.height - margin
        let gray = CGColor(gray: 0.45, alpha: 1)

        // Header: sheet name on the left, cell range on the right. Footer: file and page number.
        let small = CTFontCreateWithName("Helvetica" as CFString, 8, nil)
        let nameFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 10, nil)
        let lastRow = max(page.rows.upperBound, page.rows.lowerBound + 1)
        let firstShown = plan.header && page.rows.lowerBound == 1 ? 0 : page.rows.lowerBound
        let range = "\(SheetRef.name(row: firstShown, column: page.columns.lowerBound)):\(SheetRef.name(row: lastRow - 1, column: max(page.columns.upperBound - 1, page.columns.lowerBound)))"
        drawLine(sheet.name + (sheet.hidden ? "  (hidden sheet)" : ""), font: nameFont, color: CGColor(gray: 0, alpha: 1),
                 x: margin, baseline: top - 10, ctx: ctx, maxWidth: paper.width - 2 * margin - 120)
        let rangeWidth = lineWidth(range, font: small, fontSize: 8)
        drawLine(range, font: small, color: gray, x: paper.width - margin - rangeWidth, baseline: top - 10, ctx: ctx, maxWidth: 200)
        let footer = "\(title)  ·  Page \(number) of \(total)"
        let footerWidth = min(lineWidth(footer, font: small, fontSize: 8), paper.width - 2 * margin)
        drawLine(footer, font: small, color: gray, x: (paper.width - footerWidth) / 2, baseline: margin - 4, ctx: ctx,
                 maxWidth: paper.width - 2 * margin)

        // Row positions (the header row first when it repeats).
        var rows: [Int] = []
        if plan.header { rows.append(0) }
        rows.append(contentsOf: page.rows.filter { !(plan.header && $0 == 0) })
        let tableTop = top - 30
        var rowTop: [Int: CGFloat] = [:]
        var y = tableTop
        let maxRowHeight = paper.height - 2 * margin - 54
        for r in rows {
            rowTop[r] = y
            y -= min(plan.heights[r], maxRowHeight)
        }
        var colLeft: [Int: CGFloat] = [:]
        var x = margin
        for c in page.columns { colLeft[c] = x; x += c < plan.widths.count ? plan.widths[c] : style.minColumn }

        func rect(rows rr: ClosedRange<Int>, cols cc: ClosedRange<Int>) -> CGRect? {
            let visibleRows = rows.filter { rr.contains($0) }
            let visibleCols = page.columns.filter { cc.contains($0) }
            guard let r0 = visibleRows.first, let r1 = visibleRows.last, let c0 = visibleCols.first, let c1 = visibleCols.last,
                  let t = rowTop[r0], let b = rowTop[r1], let l = colLeft[c0], let rt = colLeft[c1] else { return nil }
            let bottom = b - min(plan.heights[r1], maxRowHeight)
            let right = rt + (c1 < plan.widths.count ? plan.widths[c1] : style.minColumn)
            return CGRect(x: l, y: bottom, width: right - l, height: t - bottom)
        }

        // Header row shading.
        if plan.header, let band = rect(rows: 0...0, cols: page.columns.lowerBound...max(page.columns.lowerBound, page.columns.upperBound - 1)) {
            ctx.setFillColor(CGColor(gray: 0.92, alpha: 1))
            ctx.fill(band)
        }

        ctx.setStrokeColor(CGColor(gray: 0.72, alpha: 1))
        ctx.setLineWidth(0.5)
        var drawnMerges = Set<Int>()
        for r in rows {
            for c in page.columns {
                var cellRect: CGRect?
                var cell = sheet[r, c]
                var textAllowed = true
                if let m = merges.origin(r, c) ?? merges.coveringOrigin(r, c) {
                    let key = m.r0 << 16 | m.c0
                    if drawnMerges.contains(key) { continue }
                    drawnMerges.insert(key)
                    cellRect = rect(rows: m.r0...m.r1, cols: m.c0...m.c1)
                    cell = sheet[m.r0, m.c0]
                    textAllowed = rows.contains(m.r0) && page.columns.contains(m.c0)
                } else if let t = rowTop[r], let l = colLeft[c] {
                    cellRect = CGRect(x: l, y: t - min(plan.heights[r], maxRowHeight), width: c < plan.widths.count ? plan.widths[c] : style.minColumn,
                                      height: min(plan.heights[r], maxRowHeight))
                }
                guard let box = cellRect else { continue }
                ctx.stroke(box)
                if textAllowed && !cell.value.isEmpty {
                    drawCell(cell, in: box, book: book, bold: plan.header && r == 0, style: style, ctx: ctx)
                }
            }
        }
    }

    private static func drawCell(_ cell: SheetCell, in box: CGRect, book: Workbook, bold: Bool, style: Style, ctx: CGContext) {
        let text = SheetNumberFormat.display(cell.value, code: book.code(cell))
        guard !text.isEmpty else { return }
        let font = bold ? style.bold : style.font
        let inner = box.insetBy(dx: style.padX, dy: style.padY)
        guard inner.width > 2, inner.height > 2 else { return }
        ctx.saveGState()
        ctx.clip(to: box.insetBy(dx: 0.5, dy: 0.5))
        let black = CGColor(gray: 0, alpha: 1)
        let baseline0 = box.maxY - style.padY - style.ascent

        switch cell.value {
        case .number, .date:
            // One line, right-aligned; "###" when it can't fit, like a spreadsheet app.
            var shown = text
            if lineWidth(text, font: font, fontSize: style.fontSize) > inner.width { shown = String(repeating: "#", count: max(1, Int(inner.width / (style.fontSize * 0.6)))) }
            let w = lineWidth(shown, font: font, fontSize: style.fontSize)
            drawLine(shown, font: font, color: black, x: inner.maxX - w, baseline: baseline0, ctx: ctx, maxWidth: inner.width)
        case .bool, .error:
            let w = lineWidth(text, font: font, fontSize: style.fontSize)
            drawLine(text, font: font, color: black, x: inner.midX - min(w, inner.width) / 2, baseline: baseline0, ctx: ctx, maxWidth: inner.width)
        default:
            let maxLines = max(1, Int((inner.height + 0.5) / style.lineHeight))
            var lines: [String] = []
            var truncated = false
            outer: for paragraph in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                let p = String(paragraph)
                if p.isEmpty { lines.append(""); if lines.count >= maxLines { truncated = true; break }; continue }
                let ns = p as NSString
                let ts = CTTypesetterCreateWithAttributedString(attributed(p, font: font))
                var start = 0
                while start < ns.length {
                    let n = max(1, CTTypesetterSuggestLineBreak(ts, start, Double(inner.width)))
                    lines.append(ns.substring(with: NSRange(location: start, length: min(n, ns.length - start))))
                    start += n
                    if lines.count >= maxLines {
                        if start < ns.length { truncated = true }
                        break outer
                    }
                }
            }
            if lines.count >= maxLines && !truncated && text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count > lines.count {
                truncated = true
            }
            for (i, l) in lines.enumerated() {
                let last = i == lines.count - 1
                let content = last && truncated ? l.trimmingCharacters(in: .whitespaces) + "…" : l.trimmingCharacters(in: .newlines)
                drawLine(content, font: font, color: black, x: inner.minX, baseline: baseline0 - CGFloat(i) * style.lineHeight,
                         ctx: ctx, maxWidth: inner.width, truncateEnd: true)
            }
        }
        ctx.restoreGState()
    }

    /// Draws one line of text, cut with "…" if it's wider than `maxWidth`.
    private static func drawLine(_ s: String, font: CTFont, color: CGColor, x: CGFloat, baseline: CGFloat, ctx: CGContext,
                                 maxWidth: CGFloat, truncateEnd: Bool = true) {
        guard !s.isEmpty else { return }
        var line = CTLineCreateWithAttributedString(attributed(s, font: font, color: color))
        if CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maxWidth {
            let token = CTLineCreateWithAttributedString(attributed("…", font: font, color: color))
            if let cut = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, token) { line = cut }
        }
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
    }
}
