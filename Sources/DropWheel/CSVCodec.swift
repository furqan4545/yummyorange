import Foundation

/// CSV and TSV: RFC 4180 quoting (embedded delimiters, quotes and line breaks), delimiter sniffing among
/// comma, semicolon, tab and bar (and Excel's "sep=" first line), byte-order marks, UTF-8, UTF-16 and
/// Windows-1252. Reading turns plain numbers, TRUE/FALSE and ISO dates into typed cells; numbers with
/// leading zeros (ZIP codes, IDs) stay text.
enum CSVCodec {
    struct ReadOptions {
        /// nil sniffs it.
        var delimiter: UInt8? = nil
        /// nil detects it.
        var encoding: String.Encoding? = nil
        /// false keeps every cell as text.
        var detectTypes = true
    }

    // MARK: Reading

    static func read(_ data: Data, name: String, sheetName: String, isTSV: Bool, options: ReadOptions = ReadOptions()) throws -> Workbook {
        var text = try decode(data, forced: options.encoding)
        var delimiter = options.delimiter
        // Excel's "sep=;" hint on the first line.
        if text.hasPrefix("sep=") || text.hasPrefix("\"sep=") {
            let firstLine = text.prefix { !$0.isNewline }
            let hint = firstLine.replacingOccurrences(of: "\"", with: "").dropFirst(4)
            if let ch = hint.first, let ascii = ch.asciiValue, delimiter == nil { delimiter = ascii }
            text = String(text.dropFirst(firstLine.count).drop(while: \.isNewline))
        }
        let bytes = Array(text.utf8)
        let sep = delimiter ?? sniff(bytes, preferTab: isTSV)
        var sheet = Worksheet(name: sheetName)
        var book = Workbook()
        // Semicolon files usually come with decimal commas ("1,5"), unless their numbers say otherwise.
        let decimalComma = sep == UInt8(ascii: ";") && (!options.detectTypes || usesDecimalComma(bytes, delimiter: sep))
        var failure: Error?
        parse(bytes, delimiter: sep) { fields in
            guard failure == nil else { return false }
            var row: [SheetCell] = []
            row.reserveCapacity(fields.count)
            for field in fields {
                row.append(options.detectTypes ? typedCell(field, decimalComma: decimalComma, book: &book) : SheetCell(value: field.isEmpty ? .empty : .text(field)))
            }
            while let last = row.last, last.value.isEmpty { row.removeLast() }
            // Rows wider than Excel's 16,384 columns are kept whole: text output keeps them, and the
            // XLSX and ODS writers refuse them with a clear message instead of losing columns.
            sheet.append(row: row)
            if sheet.rowCount > SpreadsheetLimits.maxRows || sheet.allocated > SpreadsheetLimits.maxCells {
                do { try SpreadsheetLimits.check(sheet) } catch { failure = error }
                return false
            }
            return true
        }
        if let failure { throw failure }
        sheet.trim()
        book.sheets = [sheet]
        return book
    }

    /// Text from bytes: BOM first, then strict UTF-8, then BOM-less UTF-16 (lots of zero bytes), then Windows-1252.
    static func decode(_ data: Data, forced: String.Encoding? = nil) throws -> String {
        if let forced {
            guard let s = String(data: data, encoding: forced) else {
                throw ConversionError.unsupported("This file isn’t valid text in the chosen encoding.")
            }
            return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
        }
        let b = [UInt8](data.prefix(4))
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE {
            if let s = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) { return s }
        }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF {
            if let s = String(data: data.dropFirst(2), encoding: .utf16BigEndian) { return s }
        }
        // UTF-16 without a BOM: ASCII text has a zero in every other byte (and would pass as UTF-8).
        let sample = [UInt8](data.prefix(4096))
        if sample.count >= 4 {
            let evenZeros = stride(from: 0, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
            let oddZeros = stride(from: 1, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
            let half = sample.count / 2
            if oddZeros > half * 6 / 10, evenZeros < half / 10, let s = String(data: data, encoding: .utf16LittleEndian) { return s }
            if evenZeros > half * 6 / 10, oddZeros < half / 10, let s = String(data: data, encoding: .utf16BigEndian) { return s }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if data.contains(0) { throw ConversionError.unsupported("This doesn’t look like a text file.") }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    /// Picks the delimiter whose field count is most consistent over the first lines.
    static func sniff(_ bytes: [UInt8], preferTab: Bool) -> UInt8 {
        let candidates: [UInt8] = [UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "\t"), UInt8(ascii: "|")]
        let sample = Array(bytes.prefix(64 * 1024))
        var best: (UInt8, Double) = (preferTab ? UInt8(ascii: "\t") : UInt8(ascii: ","), 0)
        for d in candidates {
            var counts: [Int] = []
            parse(sample, delimiter: d) { fields in
                counts.append(fields.count)
                return counts.count < 50
            }
            // A cut-off last line may be short; ignore it when there are others.
            if counts.count > 2 { counts.removeLast() }
            guard let mode = Dictionary(grouping: counts, by: { $0 }).max(by: { $0.value.count < $1.value.count }),
                  mode.key > 1 else { continue }
            let consistency = Double(mode.value.count) / Double(counts.count)
            var score = consistency * Double(min(mode.key, 20))
            if d == UInt8(ascii: "\t") && preferTab { score *= 1.5 }
            if d == UInt8(ascii: "|") { score *= 0.8 }
            if score > best.1 { best = (d, score) }
        }
        return best.0
    }

    /// RFC 4180 parsing over UTF-8 bytes. `row` gets each record's fields and returns false to stop.
    /// Lenient like spreadsheet apps: a quote inside an unquoted field is literal, text after a closing
    /// quote is kept, and CR, LF or CRLF end a record.
    static func parse(_ b: [UInt8], delimiter: UInt8, row: ([String]) -> Bool) {
        let quote = UInt8(ascii: "\""), cr: UInt8 = 13, lf: UInt8 = 10
        var fields: [String] = []
        var field: [UInt8] = []
        var i = 0
        let n = b.count
        var inQuotes = false, wasQuoted = false
        func endField() {
            fields.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
            wasQuoted = false
        }
        while i < n {
            let c = b[i]
            if inQuotes {
                if c == quote {
                    if i + 1 < n && b[i + 1] == quote { field.append(quote); i += 2; continue }
                    inQuotes = false
                } else {
                    field.append(c)
                }
                i += 1
                continue
            }
            switch c {
            case quote where field.isEmpty && !wasQuoted:
                inQuotes = true; wasQuoted = true
            case delimiter:
                endField()
            case cr, lf:
                endField()
                if c == cr && i + 1 < n && b[i + 1] == lf { i += 1 }
                if !row(fields) { return }
                fields.removeAll(keepingCapacity: true)
            default:
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !fields.isEmpty || wasQuoted {
            endField()
            _ = row(fields)
        }
    }

    /// Whether a semicolon-delimited file writes decimals with a comma (European spreadsheet apps do, and it's
    /// the default) or with a point, judged from the numbers in its first records. Only marks that can't be a
    /// thousands separator count ("1.25", "0,5", "1.234,5"; not "1.250").
    static func usesDecimalComma(_ bytes: [UInt8], delimiter: UInt8) -> Bool {
        var points = 0, commas = 0, records = 0
        parse(Array(bytes.prefix(256 * 1024)), delimiter: delimiter) { fields in
            for f in fields {
                switch decimalMark(f) {
                case "."?: points += 1
                case ","?: commas += 1
                default: break
                }
            }
            records += 1
            return records < 2000
        }
        return !(points > 0 && commas == 0)
    }

    /// "." or "," when a field is a plain number whose decimal mark can only be that one; nil otherwise.
    static func decimalMark(_ field: String) -> Character? {
        var t = Substring(field.trimmingCharacters(in: .whitespaces))
        if t.hasPrefix("-") || t.hasPrefix("+") { t = t.dropFirst() }
        guard !t.isEmpty, t.utf8.count <= 40 else { return nil }
        var dots = 0, commas = 0, lead = 0, tail = 0
        var last: Character?
        for ch in t {
            switch ch {
            case "0"..."9": if last == nil { lead += 1 } else { tail += 1 }
            case ".", ",":
                if ch == "." { dots += 1 } else { commas += 1 }
                last = ch; tail = 0
            default: return nil
            }
        }
        guard let mark = last, lead > 0, tail > 0 else { return nil }
        if dots > 0 && commas > 0 { return mark }      // "1,234.5", "1.234,5": the last mark is the decimal one
        if dots + commas > 1 { return nil }            // "1.234.567": groups only
        return tail == 3 ? nil : mark                  // "1.250" may be a thousands group
    }

    /// A field's typed value: numbers, booleans, ISO dates and times; everything else text.
    static func typedCell(_ field: String, decimalComma: Bool, book: inout Workbook) -> SheetCell {
        if field.isEmpty { return .empty }
        let t = field.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.utf8.count <= 40 else { return SheetCell(value: .text(field)) }
        if let v = number(t, decimalComma: decimalComma) { return SheetCell(value: .number(v)) }
        switch t.uppercased() {
        case "TRUE": return SheetCell(value: .bool(true))
        case "FALSE": return SheetCell(value: .bool(false))
        case "#NULL!", "#DIV/0!", "#VALUE!", "#REF!", "#NAME?", "#NUM!", "#N/A": return SheetCell(value: .error(t.uppercased()))
        default: break
        }
        if let first = t.utf8.first, first >= 48 && first <= 57, let (d, kind) = SheetDate.parseISO(t) {
            return SheetCell(value: .date(d, kind))
        }
        return SheetCell(value: .text(field))
    }

    /// A plain number: optional sign, digits, one decimal point, optional exponent. Leading zeros ("007")
    /// are kept as text, as are whole numbers too long to survive as a double (card or account numbers).
    /// Decimals of any length are numbers ("0.30000000000000004", as written for exact round trips).
    static func number(_ t: String, decimalComma: Bool) -> Double? {
        var s = Substring(t)
        var digits = 0, intDigits = 0, sawPoint = false, sawExp = false, expDigits = 0
        var first = true, leadingZero = false
        let point: Character = decimalComma ? "," : "."
        var normalized = ""
        for (k, ch) in s.enumerated() {
            switch ch {
            case "+", "-":
                guard first || (sawExp && normalized.last == "e") else { return nil }
                if ch == "-" { normalized.append("-") }
            case "0"..."9":
                if sawExp { expDigits += 1 } else {
                    if digits == 0 && ch == "0" && !sawPoint { leadingZero = true }
                    digits += 1
                    if !sawPoint { intDigits += 1 }
                }
                normalized.append(ch)
            case point:
                guard !sawPoint, !sawExp else { return nil }
                sawPoint = true; normalized.append(".")
            case "e", "E":
                guard digits > 0, !sawExp, k < s.count - 1 else { return nil }
                sawExp = true; normalized.append("e")
            default:
                return nil
            }
            first = false
        }
        s = ""
        guard digits > 0, !sawExp || expDigits > 0 else { return nil }
        if leadingZero && intDigits > 1 { return nil }          // "007"
        if intDigits > 15 && !sawExp { return nil }              // would lose digits of an identifier
        return Double(normalized)
    }

    // MARK: Writing

    /// The most fields a sheet is written with. Delimited text covers the used range, rows × columns, so a
    /// stray cell far right or far down (A1 and XFD1048576) would otherwise mean gigabytes of delimiters.
    static let maxFields = 25_000_000

    /// Refuses a sheet whose used range is too big for delimited text, naming the file, sheet and range.
    static func checkSize(_ sheet: Worksheet, file: String, format: String) throws {
        let rows = sheet.rowCount, cols = max(sheet.columnCount, 1)
        let (fields, overflow) = rows.multipliedReportingOverflow(by: cols)
        guard overflow || fields > maxFields else { return }
        var filled = 0
        for row in sheet.rows { for cell in row where !cell.value.isEmpty { filled += 1 } }
        let range = "A1:\(SheetRef.name(row: rows - 1, column: cols - 1))"
        let count = overflow ? "billions of" : SpreadsheetLimits.grouped(fields)
        let sparse = overflow || filled * 4 < fields
        throw ConversionError.unsupported("\(file) can’t be saved as \(format): “\(sheet.name)” spans \(range), \(count) cells\(sparse ? ", almost all of them empty" : ""), more than \(SpreadsheetLimits.grouped(maxFields)) for a text file. " + (sparse ? "Clear the stray cells far from the data, or convert it to XLSX or ODS instead." : "Convert it to XLSX or ODS instead."))
    }

    /// The sheet as delimited text: UTF-8, CRLF line ends, fields quoted when they hold the delimiter,
    /// quotes, line breaks or leading/trailing spaces. `shown` writes values as formatted in the sheet.
    static func write(_ sheet: Worksheet, book: Workbook, delimiter: Character, shown: Bool, bom: Bool) -> Data {
        var out = ""
        out.reserveCapacity(sheet.rows.reduce(0) { $0 + $1.count * 8 })
        let sep = String(delimiter)
        let width = sheet.columnCount
        for row in sheet.rows {
            var line = ""
            for c in 0..<max(width, 1) {
                if c > 0 { line += sep }
                let cell = c < row.count ? row[c] : .empty
                let text = shown ? SheetNumberFormat.display(cell.value, code: book.code(cell)) : raw(cell.value)
                line += quoted(text, delimiter: delimiter)
            }
            out += line + "\r\n"
        }
        var data = Data()
        if bom { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(contentsOf: out.utf8)
        return data
    }

    /// Values as they read back: plain numbers, TRUE/FALSE, ISO dates ("2024-01-15", "2024-01-15 13:45:00", "13:45:00").
    static func raw(_ v: SheetValue) -> String {
        switch v {
        case .empty: return ""
        case .text(let s): return s
        case .number(let d): return SheetText.number(d)
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .error(let e): return e
        case .date(let d, let kind): return SheetDate.iso(d, kind, separator: " ")
        }
    }

    static func quoted(_ s: String, delimiter: Character) -> String {
        guard !s.isEmpty else { return s }
        let needs = s.contains(delimiter) || s.contains("\"") || s.contains(where: \.isNewline)
            || s.first == " " || s.last == " "
        return needs ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}
