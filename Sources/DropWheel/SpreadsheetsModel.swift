import Foundation

// The in-memory spreadsheet every reader in this unit produces and every writer consumes.
// Values are kept apart from the file format: numbers stay numbers, dates stay dates, and the
// number format a cell was shown with travels along as an Excel-style format code.

/// What a date cell holds, which decides how it's written and shown.
enum SheetDateKind: Equatable { case date, dateTime, time }

/// A cell's value, independent of the file format it came from.
enum SheetValue: Equatable {
    case empty
    case number(Double)
    case text(String)
    case bool(Bool)
    /// Days since 1899-12-30 (LibreOffice's epoch, and Excel's for dates from 1 March 1900 on).
    /// A `.time` holds a fraction of a day (or more, for durations).
    case date(Double, SheetDateKind)
    case error(String)

    var isEmpty: Bool { if case .empty = self { return true } else { return false } }
    var isText: Bool { if case .text = self { return true } else { return false } }
}

/// One cell: its value, and the number format it's shown with (an index into `Workbook.formats`; 0 is General).
struct SheetCell: Equatable {
    var value: SheetValue
    var format: Int32 = 0
    static let empty = SheetCell(value: .empty)
}

/// A rectangle of cells, zero-based and inclusive (A1:B2 is 0,0 to 1,1).
struct SheetRange: Equatable, Hashable {
    var r0: Int, c0: Int, r1: Int, c1: Int

    var a1: String { "\(SheetRef.name(row: r0, column: c0)):\(SheetRef.name(row: r1, column: c1))" }
    func contains(_ r: Int, _ c: Int) -> Bool { r >= r0 && r <= r1 && c >= c0 && c <= c1 }

    /// "A1:C3", or a single cell "B2".
    static func parse(_ ref: String) -> SheetRange? {
        let parts = ref.split(separator: ":")
        guard let a = parts.first.flatMap({ SheetRef.parse(String($0)) }) else { return nil }
        let b = parts.count > 1 ? SheetRef.parse(String(parts[1])) : a
        guard let b else { return nil }
        return SheetRange(r0: min(a.row, b.row), c0: min(a.column, b.column), r1: max(a.row, b.row), c1: max(a.column, b.column))
    }
}

/// One sheet of a workbook. Rows are dense up to their last used cell.
struct Worksheet {
    var name: String
    var rows: [[SheetCell]] = []
    /// Hidden (or "very hidden") in the original. Kept, and marked hidden again where the format allows.
    var hidden = false
    var merges: [SheetRange] = []
    /// Cells allocated so far, so readers can stop a sparse sheet from blowing up memory.
    private(set) var allocated = 0

    init(name: String) { self.name = name }

    var rowCount: Int { rows.count }
    var columnCount: Int { rows.reduce(0) { max($0, $1.count) } }
    var isEmpty: Bool { !rows.contains { row in row.contains { !$0.value.isEmpty } } }

    subscript(r: Int, c: Int) -> SheetCell {
        r >= 0 && r < rows.count && c >= 0 && c < rows[r].count ? rows[r][c] : .empty
    }

    mutating func set(_ r: Int, _ c: Int, _ cell: SheetCell) {
        guard r >= 0, c >= 0 else { return }
        if r >= rows.count {
            if cell.value.isEmpty { return }
            rows.append(contentsOf: repeatElement([], count: r - rows.count + 1))
        }
        if c >= rows[r].count {
            if cell.value.isEmpty && cell.format == 0 { return }
            allocated += c - rows[r].count + 1
            rows[r].append(contentsOf: repeatElement(.empty, count: c - rows[r].count + 1))
        }
        rows[r][c] = cell
    }

    /// Appends a whole row (readers that stream rows in order).
    mutating func append(row: [SheetCell]) {
        allocated += row.count
        rows.append(row)
    }

    /// Drops empty cells at the end of each row and empty rows at the end of the sheet.
    mutating func trim() {
        for i in rows.indices {
            while let last = rows[i].last, last.value.isEmpty { rows[i].removeLast() }
        }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        let maxRow = rows.count - 1, maxCol = columnCount - 1
        merges = merges.compactMap { m in
            guard m.r0 <= maxRow, m.c0 <= maxCol, m.r1 > m.r0 || m.c1 > m.c0 else { return nil }
            return SheetRange(r0: m.r0, c0: m.c0, r1: min(m.r1, max(maxRow, m.r0)), c1: min(m.c1, max(maxCol, m.c0)))
        }
    }

    /// Whether the first row looks like column titles: only text, over columns whose later rows hold
    /// numbers, dates or booleans.
    var hasHeaderRow: Bool {
        guard rows.count >= 2, let first = rows.first, first.contains(where: { !$0.value.isEmpty }),
              first.allSatisfy({ $0.value.isEmpty || $0.value.isText }) else { return false }
        for row in rows.dropFirst().prefix(50) {
            for (c, cell) in row.enumerated() where c < first.count && first[c].value.isText {
                switch cell.value {
                case .number, .date, .bool: return true
                default: continue
                }
            }
        }
        return false
    }
}

/// A whole spreadsheet file.
struct Workbook {
    var sheets: [Worksheet] = []
    /// Number format codes used by the cells; index 0 is always "General".
    private(set) var formats: [String] = ["General"]
    private var formatIndex: [String: Int32] = ["General": 0]

    /// The index of a format code, adding it the first time it's seen.
    mutating func format(_ code: String) -> Int32 {
        let key = code.isEmpty ? "General" : code
        if key.caseInsensitiveCompare("General") == .orderedSame { return 0 }
        if let i = formatIndex[key] { return i }
        let i = Int32(formats.count)
        formats.append(key)
        formatIndex[key] = i
        return i
    }

    func code(_ cell: SheetCell) -> String {
        Int(cell.format) < formats.count ? formats[Int(cell.format)] : "General"
    }

    var isEmpty: Bool { sheets.allSatisfy(\.isEmpty) }
}

/// Size limits. Excel's own grid is 1,048,576 × 16,384; the cell cap keeps memory bounded
/// (each stored cell takes about 24 bytes plus its text).
enum SpreadsheetLimits {
    static let maxRows = 1_048_576
    static let maxColumns = 16_384
    static let maxCells = 12_000_000
    /// Workbooks with more sheets are refused (never cut short). The cell cap bounds what the sheets hold.
    static let maxSheets = 10_000

    static func check(_ sheet: Worksheet, total: Int = 0) throws {
        if sheet.rows.count > maxRows {
            throw ConversionError.unsupported("“\(sheet.name)” has more than \(grouped(maxRows)) rows, more than a spreadsheet can hold.")
        }
        if sheet.allocated + total > maxCells { throw tooBig(sheet) }
    }

    /// The error for a workbook over the cell cap. Rows are stored up to their last used cell, so a few cells far
    /// to the right make every row that long; the message names the column when that's what happened.
    static func tooBig(_ sheet: Worksheet) -> Error {
        let base = "This spreadsheet is too big to convert (more than \(grouped(maxCells)) cells)."
        var widest = 0, widestRow = 0, filled = 0, stored = 0
        for (r, row) in sheet.rows.enumerated() {
            stored += row.count
            if row.count > widest { widest = row.count; widestRow = r }
            for cell in row where !cell.value.isEmpty { filled += 1 }
        }
        guard widest > 26, stored > 0, filled * 4 < stored else { return ConversionError.unsupported(base) }
        let column = SheetRef.column(widest - 1)
        return ConversionError.unsupported("This spreadsheet is too big to convert: “\(sheet.name)” has cells as far right as column \(column) (cell \(SheetRef.name(row: widestRow, column: widest - 1))), so its rows would take more than \(grouped(maxCells)) cells, almost all of them empty. Clear the cells far to the right and try again.")
    }

    static func tooManySheets(_ name: String) -> Error {
        ConversionError.unsupported("\(name) has more than \(grouped(maxSheets)) sheets, more than YummyOrange can convert at once.")
    }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }
}

/// A1-style cell names.
enum SheetRef {
    /// 0 → "A", 25 → "Z", 26 → "AA".
    static func column(_ c: Int) -> String {
        var n = c + 1
        var s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(UInt8(65 + r))) + s
            n = (n - 1) / 26
        }
        return s
    }

    static func name(row: Int, column c: Int) -> String { column(c) + String(row + 1) }

    /// "B12" → (11, 1). Accepts "$B$12". Returns nil for anything else.
    static func parse(_ ref: String) -> (row: Int, column: Int)? {
        var col = 0, row = 0, letters = 0, digits = 0
        for u in ref.utf8 {
            switch u {
            case UInt8(ascii: "$"): continue
            case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                guard digits == 0 else { return nil }
                col = col * 26 + Int(u - 64); letters += 1
            case UInt8(ascii: "a")...UInt8(ascii: "z"):
                guard digits == 0 else { return nil }
                col = col * 26 + Int(u - 96); letters += 1
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                row = row * 10 + Int(u - 48); digits += 1
                if row > 10_000_000 { return nil }
            default: return nil
            }
            if letters > 3 { return nil }
        }
        guard letters > 0, digits > 0, row > 0 else { return nil }
        return (row - 1, col - 1)
    }

    /// Only the column letters of a reference ("C7" → 2), for cells written without a row.
    static func parseColumn(_ ref: String) -> Int? {
        var col = 0, letters = 0
        for u in ref.utf8 {
            switch u {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): col = col * 26 + Int(u - 64); letters += 1
            case UInt8(ascii: "a")...UInt8(ascii: "z"): col = col * 26 + Int(u - 96); letters += 1
            case UInt8(ascii: "$"): continue
            default: return letters > 0 ? col - 1 : nil
            }
        }
        return letters > 0 ? col - 1 : nil
    }
}

/// Calendar arithmetic on day counts (days since 1899-12-30), without time zones: a spreadsheet date
/// is a wall-clock date, so it must never shift by the Mac's UTC offset.
enum SheetDate {
    /// Days between 1899-12-30 and 1970-01-01.
    static let unixOffset = 25569.0

    /// Day counts a date or time can have: Excel's range (up to 9999-12-31) and as far back. Values outside it
    /// (or NaN, infinity) aren't dates; formats show them as plain numbers.
    static let maxDays = 2_958_466.0
    static func inRange(_ days: Double) -> Bool { days.isFinite && abs(days) < maxDays }

    /// An Excel serial number to days since 1899-12-30. In the 1900 system Excel counts a 29 February 1900
    /// that never existed, so serials below 61 are one day off; the 1904 system starts 1,462 days later.
    static func fromExcel(_ serial: Double, date1904: Bool) -> Double {
        if date1904 { return serial + 1462 }
        if serial >= 1 && serial < 61 { return serial + 1 }
        return serial
    }

    /// An Excel serial shown with a format of `kind`. Times and durations ("h:mm", "[h]:mm:ss") are a count
    /// of days, not a calendar date, so neither date system's epoch applies to them.
    static func fromExcel(_ serial: Double, kind: SheetDateKind, date1904: Bool) -> Double {
        kind == .time ? serial : fromExcel(serial, date1904: date1904)
    }

    /// Days since 1899-12-30 to an Excel serial in the 1900 system.
    static func toExcel(_ days: Double) -> Double {
        if days >= 2 && days < 61 { return days - 1 }
        return days
    }

    struct Parts: Equatable {
        var year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, millisecond: Int
        /// 0 = Sunday.
        var weekday: Int
    }

    /// Splits a day count into calendar parts, rounding to the millisecond. Values outside `inRange` are clamped
    /// so the arithmetic can't overflow (callers that show dates check `inRange` first).
    static func parts(_ days: Double) -> Parts {
        let days = days.isFinite ? min(max(days, -1e9), 1e9) : 0
        let totalMs = (days * 86_400_000).rounded()
        var dayNumber = (totalMs / 86_400_000).rounded(.down)
        var ms = Int(totalMs - dayNumber * 86_400_000)
        if ms >= 86_400_000 { ms -= 86_400_000; dayNumber += 1 }
        let (y, m, d) = civil(fromDays: Int(dayNumber) - Int(unixOffset))
        let weekday = ((Int(dayNumber) - 1) % 7 + 7) % 7   // day 0, 1899-12-30, was a Saturday (6)
        return Parts(year: y, month: m, day: d, hour: ms / 3_600_000, minute: ms / 60_000 % 60,
                     second: ms / 1000 % 60, millisecond: ms % 1000, weekday: weekday)
    }

    static func days(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Double = 0) -> Double {
        Double(daysFromCivil(year, month, day)) + unixOffset + (Double(hour) * 3600 + Double(minute) * 60 + second) / 86400
    }

    /// Howard Hinnant's days-from-civil (proleptic Gregorian), relative to 1970-01-01.
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(fromDays z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (m <= 2 ? y + 1 : y, m, d)
    }

    /// ISO 8601 text: "2024-01-15", "2024-01-15T13:45:00" (separator configurable), or "13:45:00" for times.
    /// Times over a day are written as elapsed hours ("36:00:00"), negative ones with a sign ("-06:00:00").
    /// A value outside the date range is written as the plain number it is.
    static func iso(_ days: Double, _ kind: SheetDateKind, separator: String = "T") -> String {
        guard inRange(days) else { return SheetText.number(days) }
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : String(n) }
        switch kind {
        case .date:
            let p = parts(days)
            return String(format: "%04d-%02d-%02d", p.year, p.month, p.day)
        case .dateTime:
            let p = parts(days)
            let frac = p.millisecond > 0 ? String(format: ".%03d", p.millisecond) : ""
            return String(format: "%04d-%02d-%02d", p.year, p.month, p.day) + separator
                + "\(two(p.hour)):\(two(p.minute)):\(two(p.second))\(frac)"
        case .time:
            let a = abs(days)
            let totalMs = Int((a * 86_400_000).rounded())
            let h = a >= 1 ? totalMs / 3_600_000 : totalMs / 3_600_000 % 24
            let m = totalMs / 60_000 % 60, s = totalMs / 1000 % 60, ms = totalMs % 1000
            let frac = ms > 0 ? String(format: ".%03d", ms) : ""
            return (days < 0 && totalMs > 0 ? "-" : "") + "\(two(h)):\(two(m)):\(two(s))\(frac)"
        }
    }

    /// Parses "2024-01-15", "2024-01-15T13:45", "2024-01-15 13:45:00.5", an optional trailing "Z" or offset
    /// (ignored: spreadsheet dates are wall-clock), and plain times "13:45" / "13:45:00" / "36:00:00".
    static func parseISO(_ text: String) -> (Double, SheetDateKind)? {
        let s = text.trimmingCharacters(in: .whitespaces)
        let u = Array(s.utf8)
        guard u.count >= 4 else { return nil }
        var i = 0
        func number(_ maxDigits: Int) -> Int? {
            var n = 0, count = 0
            while i < u.count, count < maxDigits, u[i] >= 48, u[i] <= 57 { n = n * 10 + Int(u[i] - 48); i += 1; count += 1 }
            return count > 0 ? n : nil
        }
        func expect(_ c: UInt8) -> Bool { if i < u.count, u[i] == c { i += 1; return true }; return false }

        // Time only?
        if let colon = u.firstIndex(of: UInt8(ascii: ":")), colon <= 3, !u.contains(UInt8(ascii: "-")) || colon < 3 {
            guard let h = number(4), expect(58), let m = number(2), m < 60 else { return nil }
            var sec = 0.0
            if expect(58) { guard let sv = number(2), sv < 60 else { return nil }; sec = Double(sv) }
            if expect(46) { let start = i; if let f = number(9) { sec += Double(f) / pow(10, Double(i - start)) } }
            guard i == u.count else { return nil }
            return ((Double(h) * 3600 + Double(m) * 60 + sec) / 86400, .time)
        }

        guard let y = number(4), i == 4, expect(45), let mo = number(2), (1...12).contains(mo), expect(45),
              let d = number(2), (1...31).contains(d) else { return nil }
        guard d <= daysIn(month: mo, year: y) else { return nil }
        if i == u.count { return (days(year: y, month: mo, day: d), .date) }
        guard expect(UInt8(ascii: "T")) || expect(32) else { return nil }
        guard let h = number(2), h < 24, expect(58), let mi = number(2), mi < 60 else { return nil }
        var sec = 0.0
        if expect(58) { guard let sv = number(2), sv < 61 else { return nil }; sec = Double(min(sv, 59)) }
        if expect(46) { let start = i; if let f = number(9) { sec += Double(f) / pow(10, Double(i - start)) } }
        // Zone designators are accepted and ignored.
        if expect(UInt8(ascii: "Z")) || i == u.count {
        } else if i < u.count, u[i] == 43 || u[i] == 45 {
            i += 1
            guard number(2) != nil else { return nil }
            _ = expect(58); _ = number(2)
        }
        guard i == u.count else { return nil }
        let value = days(year: y, month: mo, day: d, hour: h, minute: mi, second: sec)
        return (value, .dateTime)
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// ISO 8601 durations as ODF writes times: "PT13H45M00S", "PT1.5S", "P1DT2H", "-PT1H".
    static func parseDuration(_ text: String) -> Double? {
        var s = Substring(text.trimmingCharacters(in: .whitespaces).uppercased())
        var sign = 1.0
        if s.hasPrefix("-") { sign = -1; s = s.dropFirst() }
        guard s.hasPrefix("P") else { return nil }
        s = s.dropFirst()
        var seconds = 0.0, number = "", inTime = false, any = false
        for ch in s {
            if ch == "T" { inTime = true; continue }
            if ch.isNumber || ch == "." || ch == "," { number.append(ch == "," ? "." : ch); continue }
            guard let v = Double(number) else { return nil }
            number = ""
            any = true
            switch (ch, inTime) {
            case ("Y", false): seconds += v * 365 * 86400
            case ("M", false): seconds += v * 30 * 86400
            case ("W", false): seconds += v * 7 * 86400
            case ("D", false): seconds += v * 86400
            case ("H", true): seconds += v * 3600
            case ("M", true): seconds += v * 60
            case ("S", true): seconds += v
            default: return nil
            }
        }
        guard any, number.isEmpty else { return nil }
        return sign * seconds / 86400
    }

    /// A fraction of a day (or more) as an ODF duration, "PT13H45M00S". (Callers keep to `inRange`; anything
    /// beyond is clamped rather than overflowing.)
    static func duration(_ days: Double) -> String {
        let a = days.isFinite ? min(abs(days), 1e9) : 0
        let totalMs = Int((a * 86_400_000).rounded())
        let h = totalMs / 3_600_000, m = totalMs / 60_000 % 60, s = totalMs / 1000 % 60, ms = totalMs % 1000
        let sec = ms > 0 ? String(format: "%02d.%03d", s, ms) : String(format: "%02d", s)
        return (days < 0 ? "-" : "") + String(format: "PT%02dH%02dM", h, m) + sec + "S"
    }
}

/// Small text helpers shared by the writers.
enum SheetText {
    /// Numbers as plain text that reads back exactly: integers without ".0", otherwise the shortest
    /// round-trip form ("0.1", "1.5e-07").
    static func number(_ v: Double) -> String {
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v > 0 ? "INF" : "-INF" }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return "\(v)"
    }

    /// A sheet name Excel accepts: no []:*?/\ , at most 31 characters, not blank, not "History",
    /// and unique (ignoring case) among `taken`.
    static func excelSheetName(_ raw: String, taken: inout Set<String>) -> String {
        var name = String(raw.map { "[]:*?/\\".contains($0) || $0.isNewline ? "_" : $0 })
            .trimmingCharacters(in: .whitespaces)
        while name.hasPrefix("'") { name.removeFirst() }
        while name.hasSuffix("'") { name.removeLast() }
        if name.isEmpty || name.caseInsensitiveCompare("History") == .orderedSame { name = "Sheet" }
        name = String(name.prefix(31))
        var candidate = name
        var n = 2
        while taken.contains(candidate.lowercased()) {
            let suffix = " (\(n))"
            candidate = String(name.prefix(31 - suffix.count)) + suffix
            n += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    /// Part of a file name made from a sheet name.
    static func fileNamePart(_ raw: String) -> String {
        var s = String(raw.map { "/:\\".contains($0) || $0.isNewline || $0 == "\0" ? "-" : $0 })
            .trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "Sheet" }
        return String(s.prefix(80))
    }

    /// Escapes text for XML content or attribute values, dropping characters XML 1.0 can't carry.
    static func xml(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count + 8)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\n": out += "&#10;"
            case "\r": out += "&#13;"
            case "\t": out += "&#9;"
            default:
                let v = scalar.value
                if v < 0x20 || v == 0xFFFE || v == 0xFFFF { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// XML escaping for element text, where newlines and tabs may stay literal.
    static func xmlText(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count + 8)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\n", "\t": out.unicodeScalars.append(scalar)
            case "\r": out += "&#13;"
            default:
                let v = scalar.value
                if v < 0x20 || v == 0xFFFE || v == 0xFFFF { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
