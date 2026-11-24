import Foundation

/// Reads OpenDocument spreadsheets (.ods, and flat .fods XML): tables, rows and cells with their
/// repeat counts (the huge empty repeats LibreOffice writes at the end of a sheet are never expanded),
/// office:value-type and the typed values, covered and spanned cells (merges), paragraphs with
/// text:s / text:tab / text:line-break / text:span, hidden tables, and number styles turned into
/// format codes so values are shown the way the file shows them.
enum ODSReader {
    static func read(_ zip: ZipReader, name: String) throws -> Workbook {
        if let manifest = try? zip.readString("META-INF/manifest.xml"), manifest.contains("encryption-data") {
            throw ConversionError.unsupported("\(name) is password-protected. Open it in a spreadsheet app and save it without a password first.")
        }
        guard zip.contains("content.xml") else { throw ConversionError.unsupported("\(name) isn’t an OpenDocument spreadsheet (no content.xml).") }
        let state = ParseState()
        if let styles = try? zip.read("styles.xml") { try parse(styles, state: state, what: "styles") }
        try parse(try zip.read("content.xml"), state: state, what: "content")
        return try finish(state, name: name)
    }

    /// A single-file Flat OpenDocument spreadsheet.
    static func readFlat(_ data: Data, name: String) throws -> Workbook {
        let state = ParseState()
        try parse(data, state: state, what: "document")
        return try finish(state, name: name)
    }

    private static func finish(_ state: ParseState, name: String) throws -> Workbook {
        if let failure = state.failure { throw failure }
        if state.tooManySheets { throw SpreadsheetLimits.tooManySheets(name) }
        guard !state.book.sheets.isEmpty else { throw ConversionError.unsupported("\(name) has no sheets.") }
        return state.book
    }

    // MARK: Parse state

    /// Everything collected while walking styles.xml and content.xml.
    private final class ParseState {
        var book = Workbook()
        var failure: Error?
        var tooManySheets = false

        // Styles
        var dataStyles: [String: String] = [:]          // number style name → format code
        var cellDataStyle: [String: String] = [:]       // cell style name → number style name
        var cellParent: [String: String] = [:]
        var hiddenTables = Set<String>()
        var styleName: String?, styleFamily: String?
        var numberStyle: (name: String, kind: String, code: String)?
        var elapsedHours = false
        var inNumberText = false
        var numberTextBuffer = ""
        var currencyBuffer: String?

        // Tables
        var tableDepth = 0
        var sheet: Worksheet?
        var columnStyles: [(start: Int, count: Int, style: String)] = []
        var columnCursor = 0
        var row = 0                 // index of the next row to materialize
        var pendingEmptyRows = 0
        var rowRepeat = 1
        var rowCells: [SheetCell] = []
        var rowPendingEmpty = 0
        var rowMerges: [(c: Int, rows: Int, cols: Int)] = []
        var col = 0
        var rowStyle: String?

        // Cell
        var inCell = false
        var cellAttrs: SheetXML.Attributes?
        var covered = false
        var paragraphs: [String] = []
        var inParagraph = 0
        var skipText = 0            // inside annotations, frames and other non-cell text
        var total = 0
    }

    private static func parse(_ data: Data, state s: ParseState, what: String) throws {
        let xml = SheetXML()
        xml.onStart = { [unowned xml] el, a in
            if s.failure != nil { return }
            startElement(el, a, s, xml)
        }
        xml.onEnd = { el in
            if s.failure != nil { return }
            endElement(el, s)
        }
        xml.onText = { text in
            if s.inNumberText { s.numberTextBuffer += text }
            if s.currencyBuffer != nil { s.currencyBuffer! += text }
            if s.inCell && s.inParagraph > 0 && s.skipText == 0, !s.paragraphs.isEmpty {
                s.paragraphs[s.paragraphs.count - 1] += text
            }
        }
        do { try xml.parse(data, what: what) } catch { throw s.failure ?? error }
        if let failure = s.failure { throw failure }
    }

    private static func startElement(_ el: String, _ a: SheetXML.Attributes, _ s: ParseState, _ xml: SheetXML) {
        if s.inCell {
            switch el {
            case "annotation", "frame", "custom-shape", "rect", "ellipse", "line", "g": s.skipText += 1
            case "p", "h":
                if s.skipText == 0 { s.paragraphs.append(""); s.inParagraph += 1 }
            case "s":
                if s.skipText == 0, s.inParagraph > 0, !s.paragraphs.isEmpty {
                    s.paragraphs[s.paragraphs.count - 1] += String(repeating: " ", count: max(1, min(a.int("c") ?? 1, 1000)))
                }
            case "tab":
                if s.skipText == 0, s.inParagraph > 0, !s.paragraphs.isEmpty { s.paragraphs[s.paragraphs.count - 1] += "\t" }
            case "line-break":
                if s.skipText == 0, s.inParagraph > 0, !s.paragraphs.isEmpty { s.paragraphs[s.paragraphs.count - 1] += "\n" }
            case "table":
                s.skipText += 1    // a sub-table inside a cell
                s.tableDepth += 1
            default: break
            }
            return
        }

        switch el {
        // Number styles (styles.xml and content.xml automatic styles).
        case "number-style", "percentage-style", "currency-style", "date-style", "time-style", "boolean-style", "text-style":
            s.numberStyle = (a.get("name", prefer: "style") ?? "", el, "")
            s.elapsedHours = el == "time-style" && a.get("truncate-on-overflow", prefer: "number") == "false"
        case "number", "scientific-number", "fraction":
            guard s.numberStyle != nil else { break }
            let decimals = a.int("decimal-places") ?? 0
            let minInt = a.int("min-integer-digits") ?? 1
            let grouping = a.get("grouping") == "true"
            var code = grouping ? "#,##" + String(repeating: "0", count: max(1, minInt)) : String(repeating: "0", count: max(1, minInt))
            if grouping && minInt > 1 { code = "#," + String(repeating: "0", count: minInt) }
            if decimals > 0 { code += "." + String(repeating: "0", count: decimals) }
            if el == "scientific-number" { code += "E+" + String(repeating: "0", count: max(2, a.int("min-exponent-digits") ?? 2)) }
            if el == "fraction" { code = "# " + String(repeating: "?", count: max(1, a.int("min-numerator-digits") ?? 1)) + "/" + String(repeating: "?", count: max(1, a.int("min-denominator-digits") ?? 1)) }
            s.numberStyle!.code += code
        case "year": s.numberStyle?.code += a.get("style") == "long" ? "yyyy" : "yy"
        case "month":
            let long = a.get("style") == "long"
            if a.get("textual") == "true" { s.numberStyle?.code += long ? "mmmm" : "mmm" }
            else { s.numberStyle?.code += long ? "mm" : "m" }
        case "day": s.numberStyle?.code += a.get("style") == "long" ? "dd" : "d"
        case "day-of-week": s.numberStyle?.code += a.get("style") == "long" ? "dddd" : "ddd"
        case "hours":
            let h = a.get("style") == "long" ? "hh" : "h"
            s.numberStyle?.code += s.elapsedHours ? "[\(h)]" : h
        case "minutes": s.numberStyle?.code += a.get("style") == "long" ? "mm" : "m"
        case "seconds":
            s.numberStyle?.code += a.get("style") == "long" ? "ss" : "s"
            if let d = a.int("decimal-places"), d > 0 { s.numberStyle?.code += "." + String(repeating: "0", count: min(d, 3)) }
        case "am-pm": s.numberStyle?.code += "AM/PM"
        case "text-content": s.numberStyle?.code += "@"
        case "text":
            if s.numberStyle != nil { s.inNumberText = true; s.numberTextBuffer = "" }
        case "currency-symbol":
            if s.numberStyle != nil { s.currencyBuffer = "" }

        // Cell and table styles.
        case "style":
            s.styleName = a.get("name", prefer: "style")
            s.styleFamily = a.get("family", prefer: "style")
            if let n = s.styleName, s.styleFamily == "table-cell" {
                if let d = a.get("data-style-name", prefer: "style") { s.cellDataStyle[n] = d }
                if let p = a.get("parent-style-name", prefer: "style") { s.cellParent[n] = p }
            }
        case "table-properties":
            if let n = s.styleName, s.styleFamily == "table", a.get("display", prefer: "table") == "false" { s.hiddenTables.insert(n) }

        // Tables.
        case "table":
            s.tableDepth += 1
            guard s.tableDepth == 1 else { break }
            var sheet = Worksheet(name: a.get("name", prefer: "table") ?? "Sheet\(s.book.sheets.count + 1)")
            if let st = a.get("style-name", prefer: "table"), s.hiddenTables.contains(st) { sheet.hidden = true }
            s.sheet = sheet
            s.columnStyles = []; s.columnCursor = 0; s.row = 0; s.pendingEmptyRows = 0
        case "table-column":
            guard s.tableDepth == 1 else { break }
            let n = min(max(1, a.int("number-columns-repeated") ?? 1), SpreadsheetLimits.maxColumns)
            if let style = a.get("default-cell-style-name", prefer: "table"), style != "Default" {
                s.columnStyles.append((s.columnCursor, n, style))
            }
            s.columnCursor += n
        case "table-row":
            guard s.tableDepth == 1 else { break }
            s.rowRepeat = max(1, a.int("number-rows-repeated") ?? 1)
            s.rowCells = []; s.rowPendingEmpty = 0; s.rowMerges = []; s.col = 0
            s.rowStyle = a.get("default-cell-style-name", prefer: "table")
        case "table-cell", "covered-table-cell":
            guard s.tableDepth == 1 else { break }
            s.inCell = true
            s.cellAttrs = a
            s.covered = el == "covered-table-cell"
            s.paragraphs = []
            s.inParagraph = 0
            s.skipText = 0
        default: break
        }
    }

    private static func endElement(_ el: String, _ s: ParseState) {
        if s.inCell && el != "table-cell" && el != "covered-table-cell" {
            switch el {
            case "annotation", "frame", "custom-shape", "rect", "ellipse", "line", "g": s.skipText = max(0, s.skipText - 1)
            case "p", "h": if s.skipText == 0 { s.inParagraph = max(0, s.inParagraph - 1) }
            case "table": s.skipText = max(0, s.skipText - 1); s.tableDepth -= 1
            default: break
            }
            return
        }
        switch el {
        case "number-style", "percentage-style", "currency-style", "date-style", "time-style", "boolean-style", "text-style":
            if let st = s.numberStyle {
                var code = st.code
                if st.kind == "percentage-style" && !code.contains("%") { code += "%" }
                if st.kind == "boolean-style" { code = "General" }
                if st.kind == "text-style" && !code.contains("@") { code = "@" }
                s.dataStyles[st.name] = code.isEmpty ? "General" : code
            }
            s.numberStyle = nil
        case "text":
            if s.inNumberText {
                s.inNumberText = false
                let t = s.numberTextBuffer
                if !t.isEmpty { s.numberStyle?.code += t == "%" ? "%" : quote(t) }
            }
        case "currency-symbol":
            if let sym = s.currencyBuffer, !sym.isEmpty { s.numberStyle?.code += quote(sym) }
            s.currencyBuffer = nil
        case "style":
            s.styleName = nil; s.styleFamily = nil
        case "table-cell", "covered-table-cell":
            guard s.tableDepth == 1, s.inCell else { return }
            s.inCell = false
            finishCell(s)
        case "table-row":
            guard s.tableDepth == 1 else { return }
            finishRow(s)
        case "table":
            s.tableDepth -= 1
            guard s.tableDepth == 0, var sheet = s.sheet else { return }
            sheet.trim()
            s.total += sheet.allocated
            if s.book.sheets.count < SpreadsheetLimits.maxSheets { s.book.sheets.append(sheet) } else { s.tooManySheets = true }
            s.sheet = nil
        default: break
        }
    }

    /// Format-code quoting for literal text from a number style.
    private static func quote(_ t: String) -> String {
        if t.count == 1, " -/:.,()$€£¥".contains(t) { return t }
        return "\"" + t.replacingOccurrences(of: "\"", with: "") + "\""
    }

    private static func formatCode(cellStyle: String?, _ s: ParseState) -> String? {
        var name = cellStyle
        var hops = 0
        while let n = name, hops < 8 {
            if let ds = s.cellDataStyle[n] { return s.dataStyles[ds] }
            name = s.cellParent[n]
            hops += 1
        }
        return nil
    }

    private static func finishCell(_ s: ParseState) {
        guard let a = s.cellAttrs else { return }
        let repeatCount = max(1, a.int("number-columns-repeated") ?? 1)
        var value: SheetValue = .empty
        var code: String?

        if !s.covered {
            let styleName = a.get("style-name", prefer: "table") ?? columnStyle(at: s.col, s) ?? s.rowStyle
            code = formatCode(cellStyle: styleName, s)
            let text = s.paragraphs.joined(separator: "\n")
            let type = a.get("value-type", prefer: "office")?.lowercased()
            let calc = a.get("value-type", prefer: "calcext")?.lowercased()
            switch type {
            case "float", "percentage", "currency":
                if let v = a.get("value", prefer: "office").flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) {
                    value = .number(v)
                    if code == nil && type == "percentage" { code = "0%" }
                } else if !text.isEmpty { value = .text(text) }
            case "date":
                if let raw = a.get("date-value", prefer: "office"), let (d, kind) = SheetDate.parseISO(raw) {
                    var shown = code.flatMap(SheetNumberFormat.dateKind) ?? kind
                    // A date-value with a clock-time style ("h:mm") is a date-time whose time is shown.
                    if shown == .time, let code, !SheetNumberFormat.isElapsed(code), !(d >= 0 && d < 1) { shown = .dateTime }
                    value = .date(d, shown)
                } else if !text.isEmpty { value = .text(text) }
            case "time":
                if let raw = a.get("time-value", prefer: "office"), let d = SheetDate.parseDuration(raw) {
                    // Durations beyond the date range (or overflowing) aren't times: keep what the file shows.
                    if SheetDate.inRange(d) { value = .date(d, .time) }
                    else if !text.isEmpty { value = .text(text) }
                    else if d.isFinite { value = .number(d) }
                } else if !text.isEmpty { value = .text(text) }
            case "boolean":
                let raw = a.get("boolean-value", prefer: "office")?.lowercased()
                value = .bool(raw == "true" || raw == "1")
            case "string":
                let sv = a.get("string-value", prefer: "office") ?? ""
                let str = sv.isEmpty ? text : sv
                value = str.isEmpty ? .empty : (calc == "error" ? .error(str) : .text(str))
            default:
                if calc == "error" { value = .error(text) }
                else if !text.isEmpty { value = .text(text) }
            }
            if case .text = value, code.map({ SheetNumberFormat.dateKind($0) != nil || SheetNumberFormat.numberShape($0) != nil }) == true {
                code = nil
            }
        }

        let spannedCols = max(1, a.int("number-columns-spanned") ?? 1)
        let spannedRows = max(1, a.int("number-rows-spanned") ?? 1)
        if !s.covered, spannedCols > 1 || spannedRows > 1 {
            s.rowMerges.append((s.col, min(spannedRows, 100_000), min(spannedCols, SpreadsheetLimits.maxColumns)))
        }

        if value.isEmpty {
            s.rowPendingEmpty += repeatCount
        } else {
            let room = SpreadsheetLimits.maxColumns - (s.col)
            let n = min(repeatCount, max(0, room))
            if n > 0 {
                s.rowCells.append(contentsOf: repeatElement(.empty, count: s.rowPendingEmpty))
                s.rowPendingEmpty = 0
                var cell = SheetCell(value: value)
                if let code { cell.format = s.book.format(code) }
                s.rowCells.append(contentsOf: repeatElement(cell, count: n))
            }
        }
        s.col += repeatCount
        s.cellAttrs = nil
    }

    private static func columnStyle(at c: Int, _ s: ParseState) -> String? {
        s.columnStyles.last { c >= $0.start && c < $0.start + $0.count }?.style
    }

    private static func finishRow(_ s: ParseState) {
        // Move the sheet out while it's changed, so its rows aren't copied on every row.
        guard var sheet = s.sheet else { return }
        s.sheet = nil
        defer { s.sheet = sheet }
        let hasContent = !s.rowCells.isEmpty
        let hasMerges = !s.rowMerges.isEmpty
        if !hasContent && !hasMerges {
            s.pendingEmptyRows += s.rowRepeat
            if s.row + s.pendingEmptyRows > SpreadsheetLimits.maxRows { s.pendingEmptyRows = SpreadsheetLimits.maxRows - s.row }
            return
        }
        // A row with content: the empty rows before it become real.
        for _ in 0..<s.pendingEmptyRows { sheet.append(row: []) }
        s.row += s.pendingEmptyRows
        s.pendingEmptyRows = 0
        let copies = min(s.rowRepeat, SpreadsheetLimits.maxRows - s.row)
        for k in 0..<max(0, copies) {
            sheet.append(row: s.rowCells)
            for m in s.rowMerges {
                sheet.merges.append(SheetRange(r0: s.row + k, c0: m.c, r1: s.row + k + m.rows - 1, c1: m.c + m.cols - 1))
            }
            if sheet.allocated + s.total > SpreadsheetLimits.maxCells { break }
        }
        s.row += max(0, copies)
        do { try SpreadsheetLimits.check(sheet, total: s.total) } catch { s.failure = error }
    }
}
