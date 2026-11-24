import Foundation

/// Reads Office Open XML workbooks (.xlsx, .xlsm, and the ISO "Strict" flavour): sheets in workbook order
/// through their relationships, shared strings (rich-text runs joined, phonetic hints dropped), every cell
/// type (s, str, inlineStr, b, e, n, d), number formats from styles.xml so date cells become dates in
/// both the 1900 and 1904 systems, formulas' cached values, merged cells and hidden sheets.
enum XLSXReader {
    static func read(_ zip: ZipReader, name: String) throws -> Workbook {
        let workbookPath = try mainPart(zip)
        let rels = relationships(zip, of: workbookPath)

        // workbook.xml: sheet list and date system.
        var date1904 = false
        var sheetList: [(name: String, rid: String, hidden: Bool)] = []
        let wbXML = SheetXML()
        wbXML.onStart = { el, a in
            switch el {
            case "workbookPr":
                if let v = a.get("date1904")?.lowercased() { date1904 = v == "1" || v == "true" }
            case "sheet":
                let state = a.get("state")?.lowercased() ?? "visible"
                sheetList.append((a.get("name") ?? "Sheet\(sheetList.count + 1)", a.get("id", prefer: "r") ?? "",
                                  state == "hidden" || state == "veryhidden"))
            default: break
            }
        }
        try wbXML.parse(try zip.read(workbookPath), what: "workbook")
        guard !sheetList.isEmpty else { throw ConversionError.unsupported("\(name) has no sheets.") }
        if sheetList.count > SpreadsheetLimits.maxSheets { throw SpreadsheetLimits.tooManySheets(name) }

        let sharedPath = rels.values.first { $0.type.hasSuffix("/sharedStrings") }?.target
            ?? (zip.contains("xl/sharedStrings.xml") ? "xl/sharedStrings.xml" : nil)
        let strings = try sharedPath.map { try sharedStrings(try zip.read($0)) } ?? []

        var book = Workbook()
        let stylesPath = rels.values.first { $0.type.hasSuffix("/styles") }?.target
            ?? (zip.contains("xl/styles.xml") ? "xl/styles.xml" : nil)
        let styles = try stylesPath.map { try cellStyles(try zip.read($0), into: &book) } ?? []

        var total = 0
        for (i, entry) in sheetList.enumerated() {
            guard let rel = rels[entry.rid] ?? fallbackSheet(zip, index: i) else { continue }
            if rel.type.hasSuffix("/chartsheet") || rel.type.hasSuffix("/dialogsheet") { continue }   // no cells
            guard zip.contains(rel.target) else { continue }
            var sheet = Worksheet(name: entry.name)
            sheet.hidden = entry.hidden
            try readSheet(try zip.read(rel.target), strings: strings, styles: styles, date1904: date1904,
                          into: &sheet, total: total)
            sheet.trim()
            total += sheet.allocated
            book.sheets.append(sheet)
        }
        guard !book.sheets.isEmpty else { throw ConversionError.unsupported("\(name) has no worksheets (only charts).") }
        return book
    }

    // MARK: Package structure

    struct Relationship { let type: String; let target: String }

    /// The workbook part named by the package relationships, falling back to the usual place.
    private static func mainPart(_ zip: ZipReader) throws -> String {
        if let rel = relationships(zip, of: "").values.first(where: { $0.type.hasSuffix("/officeDocument") }),
           zip.contains(rel.target) {
            return rel.target
        }
        if zip.contains("xl/workbook.xml") { return "xl/workbook.xml" }
        if let any = zip.names.first(where: { $0.lowercased().hasSuffix("workbook.xml") }) { return any }
        throw ConversionError.unsupported("This isn’t an Excel workbook (no workbook part inside).")
    }

    /// The relationships of a part (`""` for the package itself), with targets resolved to ZIP entry names.
    static func relationships(_ zip: ZipReader, of part: String) -> [String: Relationship] {
        let dir = part.contains("/") ? String(part[..<part.lastIndex(of: "/")!]) : ""
        let file = part.split(separator: "/").last.map(String.init) ?? ""
        let relsPath = (dir.isEmpty ? "" : dir + "/") + "_rels/" + file + ".rels"
        guard let data = try? zip.read(relsPath) else { return [:] }
        var out: [String: Relationship] = [:]
        let xml = SheetXML()
        xml.onStart = { el, a in
            guard el == "Relationship", let id = a.get("Id"), let target = a.get("Target"),
                  a.get("TargetMode")?.lowercased() != "external" else { return }
            out[id] = Relationship(type: a.get("Type") ?? "", target: resolve(target, from: dir))
        }
        try? xml.parse(data, what: "relationships")
        return out
    }

    private static func resolve(_ target: String, from dir: String) -> String {
        let decoded = target.removingPercentEncoding ?? target
        var parts: [Substring] = decoded.hasPrefix("/") ? [] : dir.split(separator: "/")
        for piece in decoded.split(separator: "/") {
            if piece == ".." { _ = parts.popLast() } else if piece != "." { parts.append(piece) }
        }
        return parts.joined(separator: "/")
    }

    /// When a workbook lacks relationships (some hand-made files), sheets sit at the usual paths.
    private static func fallbackSheet(_ zip: ZipReader, index: Int) -> Relationship? {
        let path = "xl/worksheets/sheet\(index + 1).xml"
        return zip.contains(path) ? Relationship(type: "/worksheet", target: path) : nil
    }

    // MARK: Parts

    /// sharedStrings.xml: one string per <si>, joining rich-text runs and skipping phonetic runs (<rPh>).
    static func sharedStrings(_ data: Data) throws -> [String] {
        var list: [String] = []
        var buffer = ""
        var inT = false, phonetic = 0, inSI = false
        let xml = SheetXML()
        xml.onStart = { el, _ in
            switch el {
            case "si": inSI = true; buffer = ""
            case "rPh": phonetic += 1
            case "t": inT = inSI && phonetic == 0
            default: break
            }
        }
        xml.onEnd = { el in
            switch el {
            case "si": list.append(SheetXML.unescapeOOXML(buffer)); inSI = false
            case "rPh": phonetic -= 1
            case "t": inT = false
            default: break
            }
        }
        xml.onText = { if inT { buffer += $0 } }
        try xml.parse(data, what: "shared strings")
        return list
    }

    /// How each cell style shows numbers: the format's index in the workbook, whether it's a date, and whether
    /// a time format counts elapsed time ("[h]:mm") rather than showing a clock time ("h:mm").
    struct CellStyle {
        let format: Int32
        let date: SheetDateKind?
        var elapsed = false
    }

    /// styles.xml: custom number formats and the cellXfs list that cells' `s` attributes index.
    static func cellStyles(_ data: Data, into book: inout Workbook) throws -> [CellStyle] {
        var custom: [Int: String] = [:]
        var xfFormats: [Int] = []
        var inCellXfs = false
        let xml = SheetXML()
        xml.onStart = { el, a in
            switch el {
            case "numFmt":
                if let id = a.int("numFmtId"), let code = a.get("formatCode") { custom[id] = code }
            case "cellXfs": inCellXfs = true
            case "xf": if inCellXfs { xfFormats.append(a.int("numFmtId") ?? 0) }
            default: break
            }
        }
        xml.onEnd = { el in if el == "cellXfs" { inCellXfs = false } }
        try xml.parse(data, what: "styles")
        var cache: [Int: CellStyle] = [:]
        return xfFormats.map { id in
            if let s = cache[id] { return s }
            let code = custom[id] ?? SheetNumberFormat.builtIn(id) ?? "General"
            let style = CellStyle(format: book.format(code), date: SheetNumberFormat.dateKind(code),
                                  elapsed: SheetNumberFormat.isElapsed(code))
            cache[id] = style
            return style
        }
    }

    /// One worksheet's cells and merged ranges.
    static func readSheet(_ data: Data, strings: [String], styles: [CellStyle], date1904: Bool,
                          into sheet: inout Worksheet, total: Int) throws {
        var row = -1, col = -1
        var type = "n", style = 0
        var value = "", inline = "", formula = ""
        var hasValue = false, inV = false, inIs = false, inT = false, inF = false, phonetic = 0
        var failure: Error?
        var local = sheet
        let xml = SheetXML()

        xml.onStart = { [unowned xml] el, a in
            switch el {
            case "row":
                if let r = a.int("r"), r >= 1 { row = r - 1 } else { row += 1 }
                col = -1
                if row >= SpreadsheetLimits.maxRows {
                    failure = ConversionError.unsupported("“\(local.name)” has more rows than a spreadsheet can hold.")
                    xml.abort(failure!)
                }
            case "c":
                if let ref = a.get("r"), let p = SheetRef.parse(ref) { row = p.row; col = p.column }
                else if let ref = a.get("r"), let c = SheetRef.parseColumn(ref) { col = c }
                else { col += 1 }
                if row < 0 { row = 0 }
                type = a.get("t") ?? "n"
                style = a.int("s") ?? 0
                value = ""; inline = ""; formula = ""; hasValue = false
            case "v": inV = true; hasValue = true
            case "f": inF = true
            case "is": inIs = true
            case "rPh": phonetic += 1
            case "t": inT = inIs && phonetic == 0
            case "mergeCell":
                if let ref = a.get("ref"), let range = SheetRange.parse(ref) { local.merges.append(range) }
            default: break
            }
        }
        xml.onText = { s in
            if inV { value += s } else if inT { inline += s } else if inF { formula += s }
        }
        xml.onEnd = { [unowned xml] el in
            switch el {
            case "v": inV = false
            case "f": inF = false
            case "is": inIs = false
            case "rPh": phonetic -= 1
            case "t": inT = false
            case "c":
                guard col >= 0, col < SpreadsheetLimits.maxColumns else { return }
                let st = style < styles.count ? styles[style] : nil
                let cell = makeCell(type: type, value: value, hasValue: hasValue, inline: inline, formula: formula,
                                    style: st, strings: strings, date1904: date1904)
                if !cell.value.isEmpty { local.set(row, col, cell) }
                if local.allocated + total > SpreadsheetLimits.maxCells {
                    failure = SpreadsheetLimits.tooBig(local)
                    xml.abort(failure!)
                }
            default: break
            }
        }
        do { try xml.parse(data, what: "worksheet") } catch { throw failure ?? error }
        if let failure { throw failure }
        sheet = local
    }

    private static func makeCell(type: String, value: String, hasValue: Bool, inline: String, formula: String,
                                 style: CellStyle?, strings: [String], date1904: Bool) -> SheetCell {
        let fmt = style?.format ?? 0
        switch type {
        case "s":
            guard let i = Int(value.trimmingCharacters(in: .whitespaces)), i >= 0, i < strings.count else { return .empty }
            return SheetCell(value: .text(strings[i]), format: fmt)
        case "inlineStr":
            let text = SheetXML.unescapeOOXML(hasValue ? value : inline)
            return SheetCell(value: .text(text), format: fmt)
        case "str":
            return SheetCell(value: hasValue ? .text(SheetXML.unescapeOOXML(value)) : formulaText(formula), format: fmt)
        case "b":
            guard hasValue else { return SheetCell(value: formulaText(formula)) }
            let v = value.trimmingCharacters(in: .whitespaces).lowercased()
            return SheetCell(value: .bool(v == "1" || v == "true"), format: fmt)
        case "e":
            return SheetCell(value: .error(value.trimmingCharacters(in: .whitespaces)), format: fmt)
        case "d":
            if let (d, kind) = SheetDate.parseISO(value) {
                return SheetCell(value: .date(d, style?.date ?? kind), format: fmt)
            }
            return SheetCell(value: .text(value), format: fmt)
        default:
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard hasValue, !trimmed.isEmpty else { return SheetCell(value: formulaText(formula)) }
            guard let v = Double(trimmed) else { return SheetCell(value: .text(trimmed), format: fmt) }
            if let style, var kind = style.date, v.isFinite, v > -1, v < 2_958_466 {   // up to 9999-12-31
                // "h:mm" on a serial with a date part shows a date-time's clock time; "[h]:mm" a duration.
                if kind == .time, v >= 1, !style.elapsed { kind = .dateTime }
                return SheetCell(value: .date(SheetDate.fromExcel(v, kind: kind, date1904: date1904), kind), format: fmt)
            }
            return SheetCell(value: .number(v), format: fmt)
        }
    }

    /// A formula with no cached result (files written by some libraries): keep the formula as text.
    private static func formulaText(_ formula: String) -> SheetValue {
        let f = formula.trimmingCharacters(in: .whitespacesAndNewlines)
        return f.isEmpty ? .empty : .text("=" + f)
    }
}
