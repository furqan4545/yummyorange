import Foundation

/// Writes an OpenDocument spreadsheet: the stored `mimetype` first, META-INF/manifest.xml, content.xml
/// (typed cells with their shown text, runs of empty cells and rows collapsed with repeat counts,
/// merges as spans plus covered cells, hidden tables, fitted column widths, number and date styles),
/// styles.xml, meta.xml, and settings.xml to freeze a header row.
enum ODSWriter {
    struct Options {
        /// nil: freeze and bold the first row when it looks like a header.
        var freezeHeader: Bool? = nil
    }

    static let mimetype = "application/vnd.oasis.opendocument.spreadsheet"

    static func write(_ book: Workbook, to url: URL, options: Options = Options()) throws {
        guard !book.sheets.isEmpty else { throw ConversionError.unsupported("There are no sheets to save.") }
        for sheet in book.sheets where sheet.rowCount > SpreadsheetLimits.maxRows || sheet.columnCount > SpreadsheetLimits.maxColumns {
            throw ConversionError.unsupported("“\(sheet.name)” is larger than an OpenDocument spreadsheet can hold (1,048,576 rows × 16,384 columns).")
        }
        // Table names must be unique; keep them readable.
        var taken = Set<String>()
        let names = book.sheets.map { uniqueName($0.name, &taken) }
        let headers = book.sheets.map { options.freezeHeader ?? $0.hasHeaderRow }

        let zip = ZipWriter()
        try zip.add("mimetype", string: mimetype, compress: false)
        try zip.add("content.xml", data: content(book, names: names, headers: headers))
        try zip.add("styles.xml", string: styles)
        try zip.add("meta.xml", string: meta())
        try zip.add("settings.xml", string: settings(names: names, headers: headers, sheets: book.sheets))
        try zip.add("META-INF/manifest.xml", string: manifest)
        try zip.write(to: url)
    }

    private static func uniqueName(_ raw: String, _ taken: inout Set<String>) -> String {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        base = String(base.map { "[]*?:/\\".contains($0) ? "_" : $0 })
        if base.isEmpty { base = "Sheet" }
        var name = base, n = 2
        while taken.contains(name.lowercased()) { name = "\(base) (\(n))"; n += 1 }
        taken.insert(name.lowercased())
        return name
    }

    // MARK: content.xml

    /// Collects the automatic styles the cells need while the tables are written.
    private struct StyleBook {
        var dataStyles: [String: String] = [:]      // format code → "N1"
        var dataXML = ""
        var cellStyles: [String: String] = [:]      // "N1|bold|wrap" → "ce1"
        var cellXML = ""
        var columnStyles: [Double: String] = [:]    // width in cm → "co1"
        var columnXML = ""

        mutating func dataStyle(for code: String, value: SheetValue) -> String? {
            if let s = dataStyles[code] { return s }
            let name = "N\(dataStyles.count + 1)"
            guard let xml = ODSWriter.dataStyleXML(code, name: name, value: value) else { return nil }
            dataStyles[code] = name
            dataXML += xml
            return name
        }

        mutating func cellStyle(data: String?, bold: Bool, wrap: Bool) -> String? {
            guard data != nil || bold || wrap else { return nil }
            let key = "\(data ?? "")|\(bold)|\(wrap)"
            if let s = cellStyles[key] { return s }
            let name = "ce\(cellStyles.count + 1)"
            cellStyles[key] = name
            cellXML += "<style:style style:name=\"\(name)\" style:family=\"table-cell\" style:parent-style-name=\"Default\""
            if let data { cellXML += " style:data-style-name=\"\(data)\"" }
            cellXML += ">"
            if wrap { cellXML += "<style:table-cell-properties fo:wrap-option=\"wrap\" style:vertical-align=\"top\"/>" }
            if bold { cellXML += "<style:text-properties fo:font-weight=\"bold\" style:font-weight-asian=\"bold\" style:font-weight-complex=\"bold\"/>" }
            cellXML += "</style:style>"
            return name
        }

        mutating func columnStyle(widthCM: Double) -> String {
            if let s = columnStyles[widthCM] { return s }
            let name = "co\(columnStyles.count + 1)"
            columnStyles[widthCM] = name
            columnXML += "<style:style style:name=\"\(name)\" style:family=\"table-column\"><style:table-column-properties fo:break-before=\"auto\" style:column-width=\"\(String(format: "%.3f", widthCM))cm\"/></style:style>"
            return name
        }
    }

    private static let namespaces = """
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
    xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" \
    xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" \
    xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
    xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" \
    xmlns:number="urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0" \
    xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" \
    xmlns:dc="http://purl.org/dc/elements/1.1/" \
    xmlns:calcext="urn:org:documentfoundation:names:experimental:calc:xmlns:calcext:1.0"
    """

    /// content.xml as bytes. The automatic styles must come first, so a quick pass over the cells collects
    /// them; then the tables stream straight into the buffer row by row (big sheets would otherwise be
    /// copied several times as one huge string).
    private static func content(_ book: Workbook, names: [String], headers: [Bool]) -> Data {
        var styles = StyleBook()
        var widths: [[Double]] = []
        for (i, sheet) in book.sheets.enumerated() {
            let w = XLSXWriter.columnWidths(sheet, book: book)
            widths.append(w)
            for width in w { _ = styles.columnStyle(widthCM: centimetres(width)) }
            let bold = headers[i] && sheet.rowCount > 1
            for (r, row) in sheet.rows.enumerated() {
                for cell in row where !cell.value.isEmpty { _ = cellStyle(cell, book: book, bold: bold && r == 0, styles: &styles) }
            }
        }
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<office:document-content \(namespaces) office:version=\"1.2\">"
        out += "<office:font-face-decls/><office:automatic-styles>"
        out += "<style:style style:name=\"ta1\" style:family=\"table\" style:master-page-name=\"Default\"><style:table-properties table:display=\"true\" style:writing-mode=\"lr-tb\"/></style:style>"
        out += "<style:style style:name=\"ta2\" style:family=\"table\" style:master-page-name=\"Default\"><style:table-properties table:display=\"false\" style:writing-mode=\"lr-tb\"/></style:style>"
        out += styles.columnXML + styles.dataXML + styles.cellXML
        out += "</office:automatic-styles><office:body><office:spreadsheet>"
        var data = Data()
        data.append(contentsOf: out.utf8)
        for (i, sheet) in book.sheets.enumerated() {
            table(sheet, name: names[i], book: book, header: headers[i] && sheet.rowCount > 1, widths: widths[i],
                  styles: &styles, into: &data)
        }
        data.append(contentsOf: "</office:spreadsheet></office:body></office:document-content>".utf8)
        return data
    }

    /// Excel character widths → centimetres, rounded so equal widths share a style.
    private static func centimetres(_ width: Double) -> Double { (width * 0.19 * 100).rounded() / 100 }

    private static func table(_ sheet: Worksheet, name: String, book: Workbook, header: Bool, widths: [Double],
                              styles: inout StyleBook, into data: inout Data) {
        var out = "<table:table table:name=\"\(SheetText.xml(name))\" table:style-name=\"\(sheet.hidden ? "ta2" : "ta1")\">"
        // Columns: widths fitted like the XLSX writer's (Excel character units → cm).
        if widths.isEmpty {
            out += "<table:table-column table:default-cell-style-name=\"Default\"/>"
        } else {
            var c = 0
            while c < widths.count {
                var end = c
                while end + 1 < widths.count, widths[end + 1] == widths[c] { end += 1 }
                let style = styles.columnStyle(widthCM: centimetres(widths[c]))
                let rep = end - c + 1
                out += "<table:table-column table:style-name=\"\(style)\"\(rep > 1 ? " table:number-columns-repeated=\"\(rep)\"" : "") table:default-cell-style-name=\"Default\"/>"
                c = end + 1
            }
        }

        // Merges: spans on the first cell, covered cells for the rest.
        var spans: [Int: (rows: Int, cols: Int)] = [:]
        var coveredCells = Set<Int>()
        var mergeRowWidth: [Int: Int] = [:]     // row → columns its spans and covered cells reach
        for m in sheet.merges where m.r1 > m.r0 || m.c1 > m.c0 {
            guard (m.r1 - m.r0 + 1) * (m.c1 - m.c0 + 1) <= 1_000_000, coveredCells.count < 2_000_000 else { continue }
            spans[m.r0 << 16 | m.c0] = (m.r1 - m.r0 + 1, m.c1 - m.c0 + 1)
            for r in m.r0...m.r1 {
                mergeRowWidth[r] = max(mergeRowWidth[r] ?? 0, m.c1 + 1)
                for c in m.c0...m.c1 where r != m.r0 || c != m.c0 { coveredCells.insert(r << 16 | c) }
            }
        }
        let rowCount = max(sheet.rowCount, (mergeRowWidth.keys.max() ?? -1) + 1)

        if rowCount == 0 {
            out += "<table:table-row><table:table-cell/></table:table-row></table:table>"
            data.append(contentsOf: out.utf8)
            return
        }
        var emptyRun = 0
        func flushEmptyRows() {
            guard emptyRun > 0 else { return }
            out += "<table:table-row\(emptyRun > 1 ? " table:number-rows-repeated=\"\(emptyRun)\"" : "")><table:table-cell/></table:table-row>"
            emptyRun = 0
        }
        for r in 0..<rowCount {
            let row = r < sheet.rows.count ? sheet.rows[r] : []
            let mergeWidth = mergeRowWidth[r] ?? 0
            if mergeWidth == 0 && row.allSatisfy({ $0.value.isEmpty }) {
                emptyRun += 1
                continue
            }
            flushEmptyRows()
            if header && r == 0 { out += "<table:table-header-rows>" }
            out += "<table:table-row>"
            var emptyCells = 0, written = 0
            let width = max(row.count, mergeWidth)
            func flushEmptyCells() {
                guard emptyCells > 0 else { return }
                out += emptyCells > 1 ? "<table:table-cell table:number-columns-repeated=\"\(emptyCells)\"/>" : "<table:table-cell/>"
                emptyCells = 0
            }
            for c in 0..<width {
                let key = r << 16 | c
                if coveredCells.contains(key) {
                    flushEmptyCells()
                    out += "<table:covered-table-cell/>"
                    written += 1
                    continue
                }
                let cell = c < row.count ? row[c] : .empty
                let span = spans[key]
                if cell.value.isEmpty && span == nil { emptyCells += 1; continue }
                flushEmptyCells()
                out += cellXML(cell, book: book, bold: header && r == 0, span: span, styles: &styles)
                written += 1
            }
            if written == 0 { out += "<table:table-cell/>" }   // a row needs at least one cell
            out += "</table:table-row>"
            if header && r == 0 { out += "</table:table-header-rows>" }
            if out.utf8.count > 1 << 16 {
                data.append(contentsOf: out.utf8)
                out = ""
            }
        }
        // Trailing empty rows carry nothing; leave them out.
        out += "</table:table>"
        data.append(contentsOf: out.utf8)
    }

    private static func cellXML(_ cell: SheetCell, book: Workbook, bold: Bool, span: (rows: Int, cols: Int)?,
                                styles: inout StyleBook) -> String {
        var attrs = ""
        if let span {
            if span.cols > 1 { attrs += " table:number-columns-spanned=\"\(span.cols)\"" }
            if span.rows > 1 { attrs += " table:number-rows-spanned=\"\(span.rows)\"" }
        }
        let code = XLSXWriter.code(for: cell, in: book)
        let shown = SheetNumberFormat.display(cell.value, code: code)
        switch cell.value {
        case .empty, .text:
            if !cell.value.isEmpty { attrs += " office:value-type=\"string\"" }
        case .number(let v):
            let percent = SheetNumberFormat.numberShape(code)?.percent == true
            if v.isFinite {
                attrs += " office:value-type=\"\(percent ? "percentage" : "float")\" office:value=\"\(SheetText.number(v))\""
            } else {
                attrs += " office:value-type=\"string\""
            }
        case .bool(let b):
            attrs += " office:value-type=\"boolean\" office:boolean-value=\"\(b ? "true" : "false")\""
        case .error:
            // LibreOffice marks error results this way; readers without calcext see the text.
            attrs += " office:value-type=\"string\" office:string-value=\"\" calcext:value-type=\"error\""
        case .date(let d, let kind):
            if !SheetDate.inRange(d) {
                // Outside the date range: the number, as a plain float.
                attrs += d.isFinite ? " office:value-type=\"float\" office:value=\"\(SheetText.number(d))\"" : " office:value-type=\"string\""
            } else if kind == .time {
                attrs += " office:value-type=\"time\" office:time-value=\"\(SheetDate.duration(d))\""
            } else {
                attrs += " office:value-type=\"date\" office:date-value=\"\(SheetDate.iso(d, kind))\""
            }
        }
        if let style = cellStyle(cell, book: book, bold: bold, styles: &styles) {
            attrs = " table:style-name=\"\(style)\"" + attrs
        }
        if cell.value.isEmpty { return "<table:table-cell\(attrs)/>" }
        return "<table:table-cell\(attrs)>\(paragraphs(shown))</table:table-cell>"
    }

    /// The automatic cell style a cell needs (number or date style, bold header, wrapping), or nil.
    private static func cellStyle(_ cell: SheetCell, book: Workbook, bold: Bool, styles: inout StyleBook) -> String? {
        var data: String?
        var wrap = false
        switch cell.value {
        case .text(let s): wrap = s.contains(where: \.isNewline)
        case .number:
            let code = XLSXWriter.code(for: cell, in: book)
            if code != "General" { data = styles.dataStyle(for: code, value: cell.value) }
        case .date:
            data = styles.dataStyle(for: XLSXWriter.code(for: cell, in: book), value: cell.value)
        default: break
        }
        return styles.cellStyle(data: data, bold: bold && cell.value.isText, wrap: wrap)
    }

    /// Text as ODF paragraphs: one <text:p> per line, runs of spaces as <text:s/>, tabs as <text:tab/>.
    static func paragraphs(_ s: String) -> String {
        var out = ""
        for line in s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            out += "<text:p>"
            var spaces = 0
            var atStart = true
            func flush() {
                guard spaces > 0 else { return }
                // A single space between words stays literal; leading and repeated spaces need text:s.
                if spaces == 1 && !atStart { out += " " }
                else if spaces == 1 { out += "<text:s/>" }
                else if atStart { out += "<text:s text:c=\"\(spaces)\"/>" }
                else { out += " <text:s text:c=\"\(spaces - 1)\"/>" }
                spaces = 0
            }
            for ch in line {
                if ch == " " { spaces += 1; continue }
                flush()
                atStart = false
                if ch == "\t" { out += "<text:tab/>" } else { out += SheetText.xmlText(String(ch)) }
            }
            if spaces > 0 { out += spaces == 1 ? "<text:s/>" : "<text:s text:c=\"\(spaces)\"/>" }
            out += "</text:p>"
        }
        return out
    }

    // MARK: Number styles

    /// An ODF number, percentage, date or time style for a format code, or nil when there's no close match.
    static func dataStyleXML(_ code: String, name: String, value: SheetValue) -> String? {
        if SheetNumberFormat.dateKind(code) != nil { return dateStyleXML(code, name: name) }
        guard let shape = SheetNumberFormat.numberShape(code) else { return nil }
        let element = shape.percent ? "number:percentage-style" : "number:number-style"
        var out = "<\(element) style:name=\"\(name)\">"
        let prefix = shape.prefix.trimmingCharacters(in: .init(charactersIn: "()"))
        if !prefix.isEmpty { out += "<number:text>\(SheetText.xmlText(prefix))</number:text>" }
        if shape.scientific {
            out += "<number:scientific-number number:decimal-places=\"\(shape.decimals)\" number:min-integer-digits=\"\(max(1, shape.minInteger))\" number:min-exponent-digits=\"2\"/>"
        } else {
            out += "<number:number number:decimal-places=\"\(shape.decimals)\" number:min-decimal-places=\"\(shape.decimals)\" number:min-integer-digits=\"\(shape.minInteger)\"\(shape.grouping ? " number:grouping=\"true\"" : "")/>"
        }
        var suffix = shape.suffix.trimmingCharacters(in: .init(charactersIn: "()"))
        if shape.percent { suffix = suffix.replacingOccurrences(of: "%", with: "") ; out += "<number:text>%</number:text>" }
        if !suffix.trimmingCharacters(in: .whitespaces).isEmpty { out += "<number:text>\(SheetText.xmlText(suffix))</number:text>" }
        return out + "</\(element)>"
    }

    private static func dateStyleXML(_ code: String, name: String) -> String? {
        guard let section = SheetNumberFormat.sections(code).first else { return nil }
        let kind = SheetNumberFormat.dateKind(code)
        let element = kind == .time ? "number:time-style" : "number:date-style"
        var out = "<\(element) style:name=\"\(name)\"\(kind == .time && code.contains("[") ? " number:truncate-on-overflow=\"false\"" : "")>"
        let minutes = minuteTokens(section.tokens)
        for (i, t) in section.tokens.enumerated() {
            switch t {
            case .literal(let l): out += "<number:text>\(SheetText.xmlText(l))</number:text>"
            case .date(let d):
                let long = d.count >= 2
                switch d.first! {
                case "y": out += "<number:year\(d.count > 2 ? " number:style=\"long\"" : "")/>"
                case "m" where minutes.contains(i): out += "<number:minutes\(long ? " number:style=\"long\"" : "")/>"
                case "m":
                    if d.count >= 3 { out += "<number:month number:textual=\"true\"\(d.count >= 4 ? " number:style=\"long\"" : "")/>" }
                    else { out += "<number:month\(long ? " number:style=\"long\"" : "")/>" }
                case "d":
                    if d.count >= 3 { out += "<number:day-of-week\(d.count >= 4 ? " number:style=\"long\"" : "")/>" }
                    else { out += "<number:day\(long ? " number:style=\"long\"" : "")/>" }
                case "h": out += "<number:hours\(long ? " number:style=\"long\"" : "")/>"
                case "s": out += "<number:seconds\(long ? " number:style=\"long\"" : "")/>"
                default: break
                }
            case .elapsed(let unit, let n):
                let style = n >= 2 ? " number:style=\"long\"" : ""
                switch unit {
                case "h": out += "<number:hours\(style)/>"
                case "m": out += "<number:minutes\(style)/>"
                default: out += "<number:seconds\(style)/>"
                }
            case .ampm: out += "<number:am-pm/>"
            case .fraction:
                // Fractional seconds: ODF puts decimals on the seconds element; keep the shown value simple.
                break
            case .point: out += "<number:text>.</number:text>"
            case .comma: out += "<number:text>,</number:text>"
            case .slash: out += "<number:text>/</number:text>"
            default: break
            }
        }
        return out + "</\(element)>"
    }

    /// Which "m"/"mm" tokens are minutes (mirrors SheetNumberFormat's rule).
    private static func minuteTokens(_ tokens: [SheetNumberFormat.Token]) -> Set<Int> {
        var result = Set<Int>()
        let idx = tokens.indices.filter { if case .date = tokens[$0] { return true }; if case .elapsed = tokens[$0] { return true }; return false }
        for (k, i) in idx.enumerated() {
            guard case .date(let d) = tokens[i], d.hasPrefix("m"), d.count <= 2 else { continue }
            if k > 0 {
                if case .date(let p) = tokens[idx[k - 1]], p.hasPrefix("h") { result.insert(i) }
                if case .elapsed("h", _) = tokens[idx[k - 1]] { result.insert(i) }
            }
            if k + 1 < idx.count {
                if case .date(let n) = tokens[idx[k + 1]], n.hasPrefix("s") { result.insert(i) }
                if case .elapsed("s", _) = tokens[idx[k + 1]] { result.insert(i) }
            }
        }
        return result
    }

    // MARK: Other parts

    private static let styles = """
    <?xml version="1.0" encoding="UTF-8"?>
    <office:document-styles \(namespaces) office:version="1.2">\
    <office:font-face-decls/>\
    <office:styles>\
    <style:default-style style:family="table-cell"><style:paragraph-properties style:tab-stop-distance="1.25cm"/>\
    <style:text-properties fo:font-size="10pt" style:font-name="Liberation Sans"/></style:default-style>\
    <style:style style:name="Default" style:family="table-cell"/>\
    </office:styles>\
    <office:automatic-styles>\
    <style:page-layout style:name="pm1"><style:page-layout-properties style:writing-mode="lr-tb"/></style:page-layout>\
    </office:automatic-styles>\
    <office:master-styles><style:master-page style:name="Default" style:page-layout-name="pm1"/></office:master-styles>\
    </office:document-styles>
    """

    private static func meta() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let now = f.string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-meta \(namespaces) office:version="1.2"><office:meta>\
        <meta:generator>YummyOrange</meta:generator><meta:creation-date>\(now)</meta:creation-date>\
        <dc:date>\(now)</dc:date></office:meta></office:document-meta>
        """
    }

    /// View settings: freezes the first row of sheets with a header (LibreOffice reads these).
    private static func settings(names: [String], headers: [Bool], sheets: [Worksheet]) -> String {
        var tables = ""
        for (i, name) in names.enumerated() where headers[i] && sheets[i].rowCount > 1 {
            tables += "<config:config-item-map-entry config:name=\"\(SheetText.xml(name))\">"
            tables += "<config:config-item config:name=\"VerticalSplitMode\" config:type=\"short\">2</config:config-item>"
            tables += "<config:config-item config:name=\"VerticalSplitPosition\" config:type=\"int\">1</config:config-item>"
            tables += "<config:config-item config:name=\"ActiveSplitRange\" config:type=\"short\">2</config:config-item>"
            tables += "<config:config-item config:name=\"PositionTop\" config:type=\"int\">0</config:config-item>"
            tables += "<config:config-item config:name=\"PositionBottom\" config:type=\"int\">1</config:config-item>"
            tables += "</config:config-item-map-entry>"
        }
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<office:document-settings xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" "
        out += "xmlns:config=\"urn:oasis:names:tc:opendocument:xmlns:config:1.0\" office:version=\"1.2\"><office:settings>"
        out += "<config:config-item-set config:name=\"ooo:view-settings\"><config:config-item-map-indexed config:name=\"Views\">"
        out += "<config:config-item-map-entry><config:config-item config:name=\"ViewId\" config:type=\"string\">view1</config:config-item>"
        out += "<config:config-item-map-named config:name=\"Tables\">\(tables)</config:config-item-map-named>"
        out += "</config:config-item-map-entry></config:config-item-map-indexed></config:config-item-set>"
        return out + "</office:settings></office:document-settings>"
    }

    private static let manifest = """
    <?xml version="1.0" encoding="UTF-8"?>
    <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">\
    <manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>\
    <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>\
    <manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>\
    <manifest:file-entry manifest:full-path="meta.xml" manifest:media-type="text/xml"/>\
    <manifest:file-entry manifest:full-path="settings.xml" manifest:media-type="text/xml"/>\
    </manifest:manifest>
    """
}
