import Foundation

/// Writes a minimal, valid Office Open XML workbook: content types, package and workbook relationships,
/// core and app properties, one worksheet per sheet (numbers as numbers, text in the shared string
/// table, booleans and errors typed), styles.xml with the cells' number formats (a date format on every
/// date cell), column widths fitted to the content, merged cells, hidden sheets, and an optional frozen,
/// bold header row.
enum XLSXWriter {
    struct Options {
        /// nil: freeze and bold the first row when it looks like a header.
        var freezeHeader: Bool? = nil
    }

    static func write(_ book: Workbook, to url: URL, options: Options = Options()) throws {
        guard !book.sheets.isEmpty else { throw ConversionError.unsupported("There are no sheets to save.") }
        for sheet in book.sheets {
            if sheet.rowCount > SpreadsheetLimits.maxRows {
                throw ConversionError.unsupported("“\(sheet.name)” has \(SpreadsheetLimits.grouped(sheet.rowCount)) rows; Excel files hold at most \(SpreadsheetLimits.grouped(SpreadsheetLimits.maxRows)).")
            }
            if sheet.columnCount > SpreadsheetLimits.maxColumns {
                throw ConversionError.unsupported("“\(sheet.name)” has \(SpreadsheetLimits.grouped(sheet.columnCount)) columns; Excel files hold at most \(SpreadsheetLimits.grouped(SpreadsheetLimits.maxColumns)).")
            }
        }
        let zip = ZipWriter()
        var strings = SharedStrings()
        var styles = Styles()

        var taken = Set<String>()
        let names = book.sheets.map { SheetText.excelSheetName($0.name, taken: &taken) }
        // Excel needs at least one visible sheet, and the active tab must be visible.
        var hidden = book.sheets.map(\.hidden)
        if !hidden.contains(false) { hidden[0] = false }
        let active = hidden.firstIndex(of: false) ?? 0

        var sheetParts: [Data] = []
        for (i, sheet) in book.sheets.enumerated() {
            let header = options.freezeHeader ?? sheet.hasHeaderRow
            sheetParts.append(Data(worksheet(sheet, book: book, header: header && sheet.rowCount > 1, selected: i == active,
                                             strings: &strings, styles: &styles).utf8))
        }

        try zip.add("[Content_Types].xml", string: contentTypes(sheets: book.sheets.count))
        try zip.add("_rels/.rels", string: packageRels)
        try zip.add("docProps/app.xml", string: appProps(names))
        try zip.add("docProps/core.xml", string: coreProps())
        try zip.add("xl/workbook.xml", string: workbook(names, hidden: hidden, active: active))
        try zip.add("xl/_rels/workbook.xml.rels", string: workbookRels(sheets: book.sheets.count))
        try zip.add("xl/styles.xml", string: styles.xml())
        try zip.add("xl/sharedStrings.xml", string: strings.xml())
        for (i, part) in sheetParts.enumerated() {
            try zip.add("xl/worksheets/sheet\(i + 1).xml", data: part)
        }
        try zip.write(to: url)
    }

    // MARK: Shared strings and styles

    struct SharedStrings {
        private(set) var list: [String] = []
        private var index: [String: Int] = [:]
        private(set) var count = 0

        mutating func id(_ s: String) -> Int {
            count += 1
            if let i = index[s] { return i }
            let i = list.count
            list.append(s)
            index[s] = i
            return i
        }

        func xml() -> String {
            var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            out += "<sst xmlns=\"\(ns)\" count=\"\(count)\" uniqueCount=\"\(list.count)\">"
            out.reserveCapacity(list.reduce(out.utf8.count) { $0 + $1.utf8.count + 24 })
            for s in list {
                let escaped = SheetText.xmlText(SheetXML.escapeOOXML(String(s.prefix(32767))))
                let preserve = s.first?.isWhitespace == true || s.last?.isWhitespace == true || s.contains(where: \.isNewline)
                out += preserve ? "<si><t xml:space=\"preserve\">\(escaped)</t></si>" : "<si><t>\(escaped)</t></si>"
            }
            return out + "</sst>"
        }
    }

    struct Styles {
        struct Key: Hashable { let numFmt: Int; let bold: Bool; let wrap: Bool }
        private var custom: [String: Int] = [:]
        private var customList: [(Int, String)] = []
        private var keys: [Key] = [Key(numFmt: 0, bold: false, wrap: false)]
        private var lookup: [Key: Int] = [Key(numFmt: 0, bold: false, wrap: false): 0]

        mutating func numFmtID(_ code: String) -> Int {
            if let id = SheetNumberFormat.builtInID(code) { return id }
            if let id = custom[code] { return id }
            let id = 164 + customList.count
            custom[code] = id
            customList.append((id, code))
            return id
        }

        mutating func xf(code: String, bold: Bool = false, wrap: Bool = false) -> Int {
            let key = Key(numFmt: numFmtID(code), bold: bold, wrap: wrap)
            if let i = lookup[key] { return i }
            keys.append(key)
            lookup[key] = keys.count - 1
            return keys.count - 1
        }

        func xml() -> String {
            var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<styleSheet xmlns=\"\(ns)\">"
            if !customList.isEmpty {
                out += "<numFmts count=\"\(customList.count)\">"
                for (id, code) in customList { out += "<numFmt numFmtId=\"\(id)\" formatCode=\"\(SheetText.xml(code))\"/>" }
                out += "</numFmts>"
            }
            out += "<fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"
            out += "<font><b/><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font></fonts>"
            out += "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
            out += "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
            out += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
            out += "<cellXfs count=\"\(keys.count)\">"
            for k in keys {
                var attrs = "numFmtId=\"\(k.numFmt)\" fontId=\"\(k.bold ? 1 : 0)\" fillId=\"0\" borderId=\"0\" xfId=\"0\""
                if k.numFmt != 0 { attrs += " applyNumberFormat=\"1\"" }
                if k.bold { attrs += " applyFont=\"1\"" }
                if k.wrap {
                    out += "<xf \(attrs) applyAlignment=\"1\"><alignment vertical=\"top\" wrapText=\"1\"/></xf>"
                } else {
                    out += "<xf \(attrs)/>"
                }
            }
            out += "</cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
            out += "<dxfs count=\"0\"/><tableStyles count=\"0\" defaultTableStyle=\"TableStyleMedium2\" defaultPivotStyle=\"PivotStyleLight16\"/>"
            return out + "</styleSheet>"
        }
    }

    /// The format code a cell is written with: its own, or an ISO default for dates that have none.
    static func code(for cell: SheetCell, in book: Workbook) -> String {
        let own = book.code(cell)
        if case .date(_, let kind) = cell.value, SheetNumberFormat.dateKind(own) == nil {
            switch kind {
            case .date: return "yyyy-mm-dd"
            case .dateTime: return "yyyy-mm-dd hh:mm:ss"
            case .time: return "[h]:mm:ss"
            }
        }
        if case .text = cell.value { return own == "@" ? "@" : "General" }
        return own
    }

    // MARK: Worksheet

    private static func worksheet(_ sheet: Worksheet, book: Workbook, header: Bool, selected: Bool,
                                  strings: inout SharedStrings, styles: inout Styles) -> String {
        let columns = sheet.columnCount
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        out += "<worksheet xmlns=\"\(ns)\" xmlns:r=\"\(relNS)\">"
        let dimension = sheet.rowCount == 0 || columns == 0 ? "A1" : "A1:\(SheetRef.name(row: sheet.rowCount - 1, column: columns - 1))"
        out += "<dimension ref=\"\(dimension)\"/>"
        out += "<sheetViews><sheetView workbookViewId=\"0\"\(selected ? " tabSelected=\"1\"" : "")>"
        if header {
            out += "<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/>"
            out += "<selection pane=\"bottomLeft\" activeCell=\"A2\" sqref=\"A2\"/>"
        }
        out += "</sheetView></sheetViews><sheetFormatPr defaultRowHeight=\"15\"/>"

        let widths = columnWidths(sheet, book: book)
        if !widths.isEmpty {
            out += "<cols>"
            var c = 0
            while c < widths.count {
                var end = c
                while end + 1 < widths.count, widths[end + 1] == widths[c] { end += 1 }
                out += "<col min=\"\(c + 1)\" max=\"\(end + 1)\" width=\"\(widths[c])\" customWidth=\"1\"/>"
                c = end + 1
            }
            out += "</cols>"
        }

        out += "<sheetData>"
        let columnNames = (0..<max(columns, 1)).map { SheetRef.column($0) }
        for (r, row) in sheet.rows.enumerated() where row.contains(where: { !$0.value.isEmpty }) {
            let rowNumber = String(r + 1)
            out += "<row r=\"\(rowNumber)\">"
            for (c, cell) in row.enumerated() {
                let ref = columnNames[c] + rowNumber
                let bold = header && r == 0
                switch cell.value {
                case .empty:
                    continue
                case .text(let s):
                    let s32 = String(s.prefix(32767))
                    let xf = styles.xf(code: code(for: cell, in: book), bold: bold, wrap: s32.contains(where: \.isNewline))
                    out += "<c r=\"\(ref)\"\(xf != 0 ? " s=\"\(xf)\"" : "") t=\"s\"><v>\(strings.id(s32))</v></c>"
                case .number(let v):
                    let xf = styles.xf(code: code(for: cell, in: book), bold: bold)
                    let s = xf != 0 ? " s=\"\(xf)\"" : ""
                    if v.isFinite { out += "<c r=\"\(ref)\"\(s)><v>\(SheetText.number(v))</v></c>" }
                    else { out += "<c r=\"\(ref)\"\(s) t=\"e\"><v>#NUM!</v></c>" }
                case .bool(let b):
                    let xf = styles.xf(code: "General", bold: bold)
                    out += "<c r=\"\(ref)\"\(xf != 0 ? " s=\"\(xf)\"" : "") t=\"b\"><v>\(b ? 1 : 0)</v></c>"
                case .error(let e):
                    out += "<c r=\"\(ref)\" t=\"e\"><v>\(SheetText.xmlText(e))</v></c>"
                case .date(let d, let kind):
                    let xf = styles.xf(code: code(for: cell, in: book), bold: bold)
                    let serial = kind == .time ? d : SheetDate.toExcel(d)
                    // Excel's 1900 system has no 1899-12-31: its serial 1 is 1900-01-01, and serial 0 (shown
                    // "1900-01-00") is the zero date 1899-12-30 that times and LibreOffice's empty dates use.
                    let representable = kind == .time ? d >= 0 : d >= 2 || (d >= 0 && d < 1)
                    if representable && serial.isFinite {
                        out += "<c r=\"\(ref)\" s=\"\(xf)\"><v>\(SheetText.number(serial))</v></c>"
                    } else {
                        // Before 1900: Excel can't hold it as a date, so keep the text.
                        let text = SheetNumberFormat.display(cell.value, code: book.code(cell))
                        out += "<c r=\"\(ref)\" t=\"s\"><v>\(strings.id(text))</v></c>"
                    }
                }
            }
            out += "</row>"
        }
        out += "</sheetData>"
        let merges = sheet.merges.filter { $0.r1 > $0.r0 || $0.c1 > $0.c0 }
        if !merges.isEmpty {
            out += "<mergeCells count=\"\(merges.count)\">"
            for m in merges { out += "<mergeCell ref=\"\(m.a1)\"/>" }
            out += "</mergeCells>"
        }
        out += "<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>"
        return out + "</worksheet>"
    }

    /// Widths in Excel's character units, fitted to the longest shown value of each column (8.43–60).
    static func columnWidths(_ sheet: Worksheet, book: Workbook) -> [Double] {
        let columns = sheet.columnCount
        guard columns > 0 else { return [] }
        var longest = [Int](repeating: 0, count: columns)
        // Text in a cell merged across columns spreads over them, so it doesn't widen its own column.
        var spread = Set<Int>()
        for m in sheet.merges where m.c1 > m.c0 && spread.count < 200_000 {
            for r in m.r0...min(m.r1, m.r0 + 1000) { spread.insert(r << 16 | m.c0) }
        }
        let step = max(1, sheet.rowCount / 20_000)   // sample very long sheets
        var r = 0
        while r < sheet.rowCount {
            for (c, cell) in sheet.rows[r].enumerated() where !cell.value.isEmpty {
                if !spread.isEmpty, spread.contains(r << 16 | c) { continue }
                let text = SheetNumberFormat.display(cell.value, code: code(for: cell, in: book))
                let width = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                    .map { line in line.reduce(0) { $0 + (($1.unicodeScalars.first?.value ?? 0) > 0x2E80 ? 2 : 1) } }
                    .max() ?? 0
                if width > longest[c] { longest[c] = width }
            }
            r += step
        }
        return longest.map { n in
            let w = min(60, max(8.43, Double(n) * 1.1 + 2))
            return (w * 100).rounded() / 100
        }
    }

    // MARK: Package parts

    static let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let relNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    private static func contentTypes(sheets: Int) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        out += "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        out += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        out += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        out += "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        for i in 1...sheets {
            out += "<Override PartName=\"/xl/worksheets/sheet\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        out += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        out += "<Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/>"
        out += "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
        out += "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
        return out + "</Types>"
    }

    private static let packageRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
    <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>\
    </Relationships>
    """

    private static func workbookRels(sheets: Int) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        out += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for i in 1...sheets {
            out += "<Relationship Id=\"rId\(i)\" Type=\"\(relNS)/worksheet\" Target=\"worksheets/sheet\(i).xml\"/>"
        }
        out += "<Relationship Id=\"rId\(sheets + 1)\" Type=\"\(relNS)/styles\" Target=\"styles.xml\"/>"
        out += "<Relationship Id=\"rId\(sheets + 2)\" Type=\"\(relNS)/sharedStrings\" Target=\"sharedStrings.xml\"/>"
        return out + "</Relationships>"
    }

    private static func workbook(_ names: [String], hidden: [Bool], active: Int) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        out += "<workbook xmlns=\"\(ns)\" xmlns:r=\"\(relNS)\"><workbookPr/>"
        out += "<bookViews><workbookView activeTab=\"\(active)\"\(active > 0 ? " firstSheet=\"\(active)\"" : "")/></bookViews><sheets>"
        for (i, name) in names.enumerated() {
            out += "<sheet name=\"\(SheetText.xml(name))\" sheetId=\"\(i + 1)\"\(hidden[i] ? " state=\"hidden\"" : "") r:id=\"rId\(i + 1)\"/>"
        }
        return out + "</sheets></workbook>"
    }

    private static func appProps(_ names: [String]) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        out += "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\" "
        out += "xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\">"
        out += "<Application>YummyOrange</Application><DocSecurity>0</DocSecurity><ScaleCrop>false</ScaleCrop>"
        out += "<HeadingPairs><vt:vector size=\"2\" baseType=\"variant\"><vt:variant><vt:lpstr>Worksheets</vt:lpstr></vt:variant>"
        out += "<vt:variant><vt:i4>\(names.count)</vt:i4></vt:variant></vt:vector></HeadingPairs>"
        out += "<TitlesOfParts><vt:vector size=\"\(names.count)\" baseType=\"lpstr\">"
        for n in names { out += "<vt:lpstr>\(SheetText.xmlText(n))</vt:lpstr>" }
        out += "</vt:vector></TitlesOfParts><AppVersion>16.0300</AppVersion>"
        return out + "</Properties>"
    }

    private static func coreProps() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let now = f.string(from: Date())
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        out += "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" "
        out += "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" "
        out += "xmlns:dcmitype=\"http://purl.org/dc/dcmitype/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
        out += "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(now)</dcterms:created>"
        out += "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(now)</dcterms:modified>"
        return out + "</cp:coreProperties>"
    }
}
