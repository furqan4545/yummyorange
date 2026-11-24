#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import Foundation
import CoreText

/// Headless checks for `--selftest spreadsheets`: date arithmetic, number formats, CSV parsing, and
/// round trips of a workbook with every value type through XLSX, ODS and CSV.
enum SpreadsheetsSelfTest {
    static func run() -> String {
        var failures: [String] = []
        var passed = 0
        func check(_ ok: Bool, _ what: @autoclosure () -> String) {
            if ok { passed += 1 } else { failures.append(what()) }
        }
        func eq<T: Equatable>(_ a: T, _ b: T, _ what: String) { check(a == b, "\(what): got \(a), expected \(b)") }

        // Dates: Excel's 1900 system (with its phantom 29 February) and the 1904 system.
        eq(SheetDate.iso(SheetDate.fromExcel(1, date1904: false), .date), "1900-01-01", "serial 1")
        eq(SheetDate.iso(SheetDate.fromExcel(59, date1904: false), .date), "1900-02-28", "serial 59")
        eq(SheetDate.iso(SheetDate.fromExcel(61, date1904: false), .date), "1900-03-01", "serial 61")
        eq(SheetDate.iso(SheetDate.fromExcel(45306, date1904: false), .date), "2024-01-15", "serial 45306")
        eq(SheetDate.iso(SheetDate.fromExcel(0, date1904: true), .date), "1904-01-01", "1904 serial 0")
        eq(SheetDate.iso(SheetDate.fromExcel(43845.5, date1904: true), .dateTime), "2024-01-16T12:00:00", "1904 serial")
        eq(SheetDate.toExcel(SheetDate.fromExcel(45306.25, date1904: false)), 45306.25, "serial round trip")
        eq(SheetDate.toExcel(SheetDate.fromExcel(30, date1904: false)), 30, "early serial round trip")
        eq(SheetDate.fromExcel(0.5625, kind: .time, date1904: true), 0.5625, "times ignore the 1904 epoch")
        eq(SheetDate.fromExcel(30.5, kind: .time, date1904: false), 30.5, "durations ignore the 1900 leap-day quirk")
        eq(SheetDate.parseISO("2024-02-29T13:45:30").map { SheetDate.iso($0.0, $0.1) }, "2024-02-29T13:45:30", "ISO date-time")
        eq(SheetDate.parseISO("2023-02-29") == nil, true, "invalid date rejected")
        eq(SheetDate.parseISO("13:45").map { SheetDate.iso($0.0, .time) }, "13:45:00", "ISO time")
        eq(SheetDate.parseDuration("PT13H45M00S").map { SheetDate.iso($0, .time) }, "13:45:00", "ODF duration")
        eq(SheetDate.parseDuration("P1DT12H").map { SheetDate.iso($0, .time) }, "36:00:00", "ODF long duration")
        eq(SheetDate.parts(SheetDate.days(year: 2024, month: 1, day: 15)).weekday, 1, "weekday (Monday)")

        // Number formats.
        let n: [(Double, String, String)] = [
            (1234.5, "#,##0.00", "1,234.50"), (0.256, "0%", "26%"), (0.256, "0.0%", "25.6%"),
            (12345, "0.00E+00", "1.23E+04"), (0.00012, "0.00E+00", "1.20E-04"),
            (-1234, "\"$\"#,##0_);(\"$\"#,##0)", "($1,234)"), (1234, "\"$\"#,##0_);(\"$\"#,##0)", "$1,234 "),
            (-5, "0", "-5"), (0, "#,##0;-#,##0;\"zero\"", "zero"), (1.5, "# ?/?", "1 1/2"),
            (5551234, "000-0000", "555-1234"), (1234567, "#,##0,", "1,235"), (7, "00", "07"),
            (0.5, "#.##", ".5"), (3, "[$€-407] #,##0.00", "€ 3.00"), (12.3, "[Red]0.0", "12.3"),
            (0.1, "General", "0.1"), (1e20, "General", "1E+20"), (123456789012, "General", "123456789012"), (1.5e16, "General", "1.5E+16"),
            (1.0 / 3.0, "General", "0.333333333"),
        ]
        for (v, code, want) in n { eq(SheetNumberFormat.display(.number(v), code: code), want, "format \(code) of \(v)") }
        let jan15 = SheetDate.days(year: 2024, month: 1, day: 15, hour: 18, minute: 5, second: 9)
        let d: [(String, String)] = [
            ("yyyy-mm-dd", "2024-01-15"), ("d-mmm-yy", "15-Jan-24"), ("dddd, mmmm d, yyyy", "Monday, January 15, 2024"),
            ("h:mm AM/PM", "6:05 PM"), ("hh:mm:ss", "18:05:09"), ("m/d/yy h:mm", "1/15/24 18:05"), ("mmm", "Jan"),
        ]
        for (code, want) in d { eq(SheetNumberFormat.display(.date(jan15, .dateTime), code: code), want, "date format \(code)") }
        eq(SheetNumberFormat.display(.date(1.5, .time), code: "[h]:mm:ss"), "36:00:00", "elapsed hours")
        eq(SheetNumberFormat.display(.date(0.5 + 1.25 / 86400, .time), code: "mm:ss.0"), "00:01.3", "fractional seconds")
        eq(SheetNumberFormat.dateKind("yyyy-mm-dd"), .date, "date kind")
        eq(SheetNumberFormat.dateKind("h:mm"), .time, "time kind")
        eq(SheetNumberFormat.dateKind("m/d/yy h:mm"), .dateTime, "date-time kind")
        eq(SheetNumberFormat.dateKind("[$-409]mmmm d, yyyy;@"), .date, "locale date kind")
        eq(SheetNumberFormat.dateKind("0.00%") == nil, true, "percent isn't a date")
        eq(SheetNumberFormat.dateKind("\"Day\" 0") == nil, true, "quoted letters aren't a date")
        eq(SheetNumberFormat.dateKind("[Red]#,##0") == nil, true, "colour isn't a date")

        // OOXML escapes.
        eq(SheetXML.unescapeOOXML("a_x000D_b"), "a\rb", "unescape CR")
        eq(SheetXML.unescapeOOXML(SheetXML.escapeOOXML("x_x0041_y\u{1}")), "x_x0041_y\u{1}", "escape round trip")

        // CSV.
        let csv = "name;amount;when\r\n\"Smith; J\";1,5;2024-01-15\r\n\"multi\nline \"\"quoted\"\"\";-2;\r\n007;TRUE;13:45\r\n"
        var book = Workbook()
        let bytes = Array(csv.utf8)
        eq(CSVCodec.sniff(bytes, preferTab: false), UInt8(ascii: ";"), "sniff semicolon")
        var rows: [[String]] = []
        CSVCodec.parse(bytes, delimiter: UInt8(ascii: ";")) { rows.append($0); return true }
        eq(rows.count, 4, "CSV record count")
        eq(rows.count > 2 ? rows[2][0] : "", "multi\nline \"quoted\"", "CSV embedded newline and quotes")
        eq(CSVCodec.typedCell("1,5", decimalComma: true, book: &book).value, .number(1.5), "decimal comma")
        eq(CSVCodec.typedCell("007", decimalComma: false, book: &book).value, .text("007"), "leading zeros stay text")
        eq(CSVCodec.typedCell("1e-05", decimalComma: false, book: &book).value, .number(1e-05), "exponent")
        eq(CSVCodec.typedCell("4111111111111111", decimalComma: false, book: &book).value, .text("4111111111111111"), "long digits stay text")
        eq(CSVCodec.quoted("a,b", delimiter: ","), "\"a,b\"", "CSV quoting")
        if let utf16 = "a,b\r\n1,2\r\n".data(using: .utf16LittleEndian) {
            eq((try? CSVCodec.decode(utf16)) ?? "", "a,b\r\n1,2\r\n", "BOM-less UTF-16")
        }
        eq((try? CSVCodec.decode(Data([0x63, 0x61, 0x66, 0xE9]))) ?? "", "café", "Windows-1252 fallback")

        // Round trips.
        let sample = sampleWorkbook()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-sheets-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let x = dir.appendingPathComponent("t.xlsx")
            try XLSXWriter.write(sample, to: x)
            let back = try SpreadsheetsIO.read(x)
            compare(sample, back, "XLSX", check: check)
            check(back.sheets.count == 2 && back.sheets[1].hidden, "XLSX hidden sheet kept")
            check(back.sheets.first?.merges == [SheetRange(r0: 5, c0: 0, r1: 5, c1: 2)], "XLSX merge kept")
            eq(back.code(back.sheets[0][1, 1]), "#,##0.00", "XLSX number format kept")
        } catch { failures.append("XLSX round trip threw: \(error.localizedDescription)") }
        do {
            let o = dir.appendingPathComponent("t.ods")
            try ODSWriter.write(sample, to: o)
            let back = try SpreadsheetsIO.read(o)
            compare(sample, back, "ODS", check: check)
            check(back.sheets.count == 2 && back.sheets[1].hidden, "ODS hidden sheet kept")
            check(back.sheets.first?.merges == [SheetRange(r0: 5, c0: 0, r1: 5, c1: 2)], "ODS merge kept")
        } catch { failures.append("ODS round trip threw: \(error.localizedDescription)") }
        do {
            let c = dir.appendingPathComponent("t.csv")
            var one = sample
            one.sheets = [sample.sheets[0]]
            try CSVCodec.write(one.sheets[0], book: one, delimiter: ",", shown: false, bom: false).write(to: c)
            let back = try SpreadsheetsIO.read(c)
            compare(one, back, "CSV", check: check, ignoreFormats: true)
        } catch { failures.append("CSV round trip threw: \(error.localizedDescription)") }

        // XLSX sheet details: a formula without a cached value, cells without references, ISO date cells.
        do {
            let xml = """
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
            <row><c><f>SUM(B1:B2)</f></c><c t="d"><v>2024-05-06T07:08:09</v></c><c t="e"><v>#REF!</v></c></row>
            <row r="4"><c r="C4" t="b"><v>true</v></c></row></sheetData></worksheet>
            """
            var sheet = Worksheet(name: "t")
            try XLSXReader.readSheet(Data(xml.utf8), strings: [], styles: [], date1904: false, into: &sheet, total: 0)
            eq(sheet[0, 0].value, .text("=SUM(B1:B2)"), "formula without a cached value")
            eq(sheet[0, 1].value.isEmpty ? "" : CSVCodec.raw(sheet[0, 1].value), "2024-05-06 07:08:09", "t=d cell")
            eq(sheet[0, 2].value, .error("#REF!"), "t=e cell")
            eq(sheet[3, 2].value, .bool(true), "t=b true")
        } catch { failures.append("XLSX sheet parse threw: \(error.localizedDescription)") }

        // Flat ODS with LibreOffice's huge trailing repeats: must not expand them.
        do {
            let fods = """
            <office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:spreadsheet>
            <table:table table:name="T"><table:table-row><table:table-cell office:value-type="float" office:value="3"><text:p>3</text:p></table:table-cell><table:table-cell table:number-columns-repeated="16383"/></table:table-row>
            <table:table-row table:number-rows-repeated="1048575"><table:table-cell table:number-columns-repeated="16384"/></table:table-row></table:table>
            </office:spreadsheet></office:body></office:document>
            """
            let book = try ODSReader.readFlat(Data(fods.utf8), name: "t.fods")
            eq(book.sheets.first?.rowCount ?? -1, 1, "trailing empty repeats skipped")
            eq(book.sheets.first?.columnCount ?? -1, 1, "trailing empty cells skipped")
        } catch { failures.append("flat ODS threw: \(error.localizedDescription)") }

        // Spreadsheet → PDF → table again.
        do {
            let pdf = dir.appendingPathComponent("t.pdf")
            var one = sample
            one.sheets = [sample.sheets[0]]
            try SpreadsheetsPDF.write(one, to: pdf, title: "t.xlsx", options: [:]) { _ in }
            let back = try SpreadsheetsFromPDF.workbook(from: pdf, options: ["ocr": "false"]) { _ in }
            let values = back.sheets.flatMap { $0.rows.flatMap { $0.map(\.value) } }
            check(values.contains(.number(1234.5)), "PDF table: 1,234.50 read back as a number")
            check(values.contains(.text("Item")) && values.contains(.text("Price")), "PDF table: header words in their own cells")
            check(values.contains(.number(42)), "PDF table: 42 read back")
        } catch { failures.append("PDF round trip threw: \(error.localizedDescription)") }

        regressions(dir: dir, check: check, eq: eq)

        if failures.isEmpty { return "OK spreadsheets: \(passed) checks passed" }
        return "FAIL spreadsheets: \(failures.count) of \(passed + failures.count) checks failed\n" + failures.joined(separator: "\n")
    }

    /// Checks for problems found in review: values that used to trap, sparse and wide sheets, and values that
    /// changed type or shifted on a round trip.
    static func regressions(dir: URL, check: (Bool, @autoclosure () -> String) -> Void,
                            eq: (String, String, String) -> Void) {
        // Fractions, dates and times never trap, whatever the number.
        let odd: [Double] = [1e20, -1e20, 1e300, -1e300, .infinity, -.infinity, .nan, 2e14, 1e19, 5e-324, -0.25, 9.9e14]
        for code in ["# ?/?", "# ??/??", "?/?", "# ?/" + String(repeating: "?", count: 19), "# ?/8", "[h]:mm:ss", "yyyy-mm-dd",
                     "h:mm AM/PM", "mm:ss.0", "0.00E+00", "0%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%"] {
            for v in odd {
                _ = SheetNumberFormat.display(.number(v), code: code)
                _ = SheetNumberFormat.display(.date(v, .time), code: code)
                _ = SheetNumberFormat.display(.date(v, .dateTime), code: code)
            }
        }
        for v in odd { _ = SheetDate.iso(v, .time); _ = SheetDate.iso(v, .date); _ = SheetDate.duration(v); _ = SheetDate.parts(v) }
        eq(SheetNumberFormat.display(.number(1e20), code: "# ?/?"), "1E+20", "fraction of a huge value")
        eq(SheetNumberFormat.display(.number(0.5), code: "# ?/" + String(repeating: "?", count: 19)), "1/2", "fraction with a long denominator")
        eq(SheetNumberFormat.display(.number(3.14159), code: "# ??/??"), "3 14/99", "closest two-digit fraction")
        eq(SheetNumberFormat.display(.number(-2.25), code: "# ?/?"), "-2 1/4", "negative fraction")
        eq(SheetNumberFormat.display(.number(0.999), code: "# ?/?"), "1", "fraction rounding up to a whole")
        eq(SheetNumberFormat.display(.number(2e14), code: "[h]:mm:ss"), "200000000000000", "elapsed time out of range")
        eq(SheetNumberFormat.display(.number(1e19), code: "yyyy-mm-dd"), "1E+19", "date out of range")
        eq(SheetNumberFormat.display(.date(-0.25, .time), code: "[h]:mm"), "-6:00", "negative duration")
        eq(SheetDate.iso(-0.25, .time), "-06:00:00", "negative time as text")
        eq(SheetDate.iso(1e30, .time), "1e+30", "time out of range as text")
        do {
            let fods = """
            <office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:spreadsheet>
            <table:table table:name="T"><table:table-row><table:table-cell office:value-type="time" office:time-value="PT999999999999999999999999999999H"><text:p>x</text:p></table:table-cell><table:table-cell office:value-type="time" office:time-value="PT6H"><text:p>6:00</text:p></table:table-cell></table:table-row></table:table>
            </office:spreadsheet></office:body></office:document>
            """
            let book = try ODSReader.readFlat(Data(fods.utf8), name: "t.fods")
            eq(CSVCodec.raw(book.sheets[0][0, 0].value), "x", "ODS duration out of range kept as shown")
            eq(CSVCodec.raw(book.sheets[0][0, 1].value), "06:00:00", "ODS duration")
        } catch { check(false, "ODS huge duration threw: \(error.localizedDescription)") }

        // A truncated BIFF8 string at the end of the stream (rich and extended flags pointing past it).
        do {
            var stream = biffRecord(0x0809, [0x00, 0x06, 0x05, 0x00, 0xBB, 0x0D, 0xCC, 0x07, 0, 0, 0, 0, 0x06, 0, 0, 0])
            stream += biffRecord(0x1234, [UInt8](repeating: 0, count: 4200))
            stream += biffRecord(0x041E, [0xA4, 0x00, 0x01, 0x00, 0x0C])
            _ = try XLSReader.read(compoundFile(stream), name: "t.xls")
            check(false, "truncated XLS string: expected an error")
        } catch { check(error.localizedDescription.contains("no worksheets"), "truncated XLS string: \(error.localizedDescription)") }

        // Sparse sheets: CSV covers the used range, and refuses one too big for text.
        var corner = Worksheet(name: "S")
        corner.set(0, 0, SheetCell(value: .number(1)))
        corner.set(1_048_575, 16_383, SheetCell(value: .number(2)))
        do {
            try CSVCodec.checkSize(corner, file: "corner.xlsx", format: "CSV")
            check(false, "sparse sheet to CSV: expected an error")
        } catch { check(error.localizedDescription.contains("A1:XFD1048576"), "sparse sheet error: \(error.localizedDescription)") }
        var small = Worksheet(name: "S")
        small.set(0, 0, SheetCell(value: .number(1))); small.set(2, 3, SheetCell(value: .number(2)))
        check((try? CSVCodec.checkSize(small, file: "s.xlsx", format: "CSV")) != nil, "small sheet passes the CSV size check")
        eq(String(decoding: CSVCodec.write(small, book: Workbook(), delimiter: ",", shown: false, bom: false), as: UTF8.self),
           "1,,,\r\n,,,\r\n,,,2\r\n", "CSV covers the used range")
        var wide = Worksheet(name: "S")
        for r in 0..<30 { wide.set(r, 0, SheetCell(value: .number(1))); wide.set(r, 1000, SheetCell(value: .text("note"))) }
        check(SpreadsheetLimits.tooBig(wide).localizedDescription.contains("column ALM"), "too-big error names the far column")

        // CSV: no column cut; decimals of any length are numbers; semicolon files with decimal points.
        do {
            let line = (0..<17_000).map { "h\($0)" }.joined(separator: ",") + "\r\n" + (0..<17_000).map(String.init).joined(separator: ",") + "\r\n"
            let book = try CSVCodec.read(Data(line.utf8), name: "w.csv", sheetName: "w", isTSV: false)
            eq(String(book.sheets[0].columnCount), "17000", "CSV keeps every column")
            do {
                try XLSXWriter.write(book, to: dir.appendingPathComponent("w.xlsx"))
                check(false, "17,000 columns to XLSX: expected an error")
            } catch { check(error.localizedDescription.contains("17,000 columns"), "wide XLSX error: \(error.localizedDescription)") }
            let py = try CSVCodec.read(Data("a,b\r\n0.30000000000000004,3.141592653589793\r\n".utf8), name: "p.csv", sheetName: "p", isTSV: false)
            check(py.sheets[0][1, 0].value == .number(0.1 + 0.2) && py.sheets[0][1, 1].value == .number(Double.pi), "long decimals are numbers")
            let semi = try CSVCodec.read(Data("item;price;qty\r\napple;1.25;3\r\npear;0.5;2\r\n".utf8), name: "s.csv", sheetName: "s", isTSV: false)
            check(semi.sheets[0][1, 1].value == .number(1.25) && semi.sheets[0][2, 1].value == .number(0.5), "semicolon file with decimal points")
            let eu = try CSVCodec.read(Data("item;price\r\napple;1,25\r\npear;1.250\r\n".utf8), name: "e.csv", sheetName: "e", isTSV: false)
            check(eu.sheets[0][1, 1].value == .number(1.25) && eu.sheets[0][2, 1].value == .text("1.250"), "semicolon file with decimal commas")
        } catch { check(false, "CSV regressions threw: \(error.localizedDescription)") }

        // A clock-time format on a date-time serial reads as a date-time; elapsed formats stay durations.
        do {
            let xml = """
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
            <row r="1"><c r="A1" s="1"><v>45306.75</v></c><c r="B1" s="2"><v>1.5</v></c><c r="C1" s="1"><v>0.25</v></c></row></sheetData></worksheet>
            """
            var sheet = Worksheet(name: "t")
            let styles = [XLSXReader.CellStyle(format: 0, date: nil),
                          XLSXReader.CellStyle(format: 0, date: .time, elapsed: false),
                          XLSXReader.CellStyle(format: 0, date: .time, elapsed: true)]
            try XLSXReader.readSheet(Data(xml.utf8), strings: [], styles: styles, date1904: false, into: &sheet, total: 0)
            eq(CSVCodec.raw(sheet[0, 0].value), "2024-01-15 18:00:00", "h:mm on a date-time serial")
            eq(CSVCodec.raw(sheet[0, 1].value), "36:00:00", "[h]:mm:ss stays a duration")
            eq(CSVCodec.raw(sheet[0, 2].value), "06:00:00", "h:mm on a time of day")
        } catch { check(false, "clock-time sheet threw: \(error.localizedDescription)") }

        // 1899-12-31 can't be an Excel 1900-system date: it stays text instead of shifting a day.
        do {
            var book = Workbook()
            var s = Worksheet(name: "d")
            s.set(0, 0, SheetCell(value: .date(1, .date)))
            s.set(1, 0, SheetCell(value: .date(SheetDate.days(year: 1900, month: 1, day: 1), .date)))
            book.sheets = [s]
            let x = dir.appendingPathComponent("early.xlsx")
            try XLSXWriter.write(book, to: x)
            let back = try SpreadsheetsIO.read(x)
            eq(CSVCodec.raw(back.sheets[0][0, 0].value), "1899-12-31", "1899-12-31 kept")
            eq(CSVCodec.raw(back.sheets[0][1, 0].value), "1900-01-01", "1900-01-01 kept")
        } catch { check(false, "early date threw: \(error.localizedDescription)") }

        // The PDF page-limit advice fits the source.
        let advice = SpreadsheetsPDF.tooManyPages(title: "log.csv", sheets: 1).localizedDescription
        check(advice.contains("XLSX or TSV") && !advice.contains("sheet"), "page-limit advice for a CSV: \(advice)")

        // PDF → XLSX: a large heading over a table keeps its words and doesn't split the table's columns.
        do {
            let pdf = dir.appendingPathComponent("heading.pdf")
            try headingTablePDF(pdf)
            let book = try SpreadsheetsFromPDF.workbook(from: pdf, options: ["ocr": "false"]) { _ in }
            let s = book.sheets[0]
            eq(CSVCodec.raw(s[0, 0].value), "Monthly Wage Report", "PDF heading in one cell")
            eq((0..<4).map { CSVCodec.raw(s[1, $0].value) }.joined(separator: "|"), "Name|Hours|Rate|Total", "PDF table columns under a heading")
        } catch { check(false, "PDF heading threw: \(error.localizedDescription)") }
    }

    private static func biffRecord(_ type: UInt16, _ body: [UInt8]) -> [UInt8] {
        [UInt8(type & 0xFF), UInt8(type >> 8), UInt8(body.count & 0xFF), UInt8(body.count >> 8)] + body
    }

    /// A minimal compound file holding one "Workbook" stream (at least 4,096 bytes, so it isn't in the mini stream).
    private static func compoundFile(_ stream: [UInt8]) -> Data {
        func put32(_ b: inout [UInt8], _ at: Int, _ v: UInt32) { for k in 0..<4 { b[at + k] = UInt8(v >> (8 * UInt32(k)) & 0xFF) } }
        func put16(_ b: inout [UInt8], _ at: Int, _ v: UInt16) { b[at] = UInt8(v & 0xFF); b[at + 1] = UInt8(v >> 8) }
        let sectors = (stream.count + 511) / 512
        var header = [UInt8](repeating: 0, count: 512)
        header.replaceSubrange(0..<8, with: XLSCompoundFile.signature)
        put16(&header, 24, 0x3E); put16(&header, 26, 3); put16(&header, 28, 0xFFFE); put16(&header, 30, 9); put16(&header, 32, 6)
        put32(&header, 44, 1); put32(&header, 48, 1); put32(&header, 56, 4096)
        put32(&header, 60, 0xFFFF_FFFE); put32(&header, 68, 0xFFFF_FFFE)
        put32(&header, 76, 0)
        for i in 1..<109 { put32(&header, 76 + 4 * i, 0xFFFF_FFFF) }
        var fat = [UInt32](repeating: 0xFFFF_FFFF, count: 128)
        fat[0] = 0xFFFF_FFFD; fat[1] = 0xFFFF_FFFE
        for i in 0..<sectors { fat[2 + i] = i == sectors - 1 ? 0xFFFF_FFFE : UInt32(3 + i) }
        var fatBytes = [UInt8](repeating: 0, count: 512)
        for (i, v) in fat.enumerated() { put32(&fatBytes, i * 4, v) }
        func entry(_ name: String, type: UInt8, start: UInt32, size: UInt32, child: UInt32) -> [UInt8] {
            var e = [UInt8](repeating: 0, count: 128)
            let units = Array(name.utf16) + [0]
            for (i, u) in units.enumerated() { put16(&e, i * 2, u) }
            put16(&e, 64, UInt16(units.count * 2)); e[66] = type; e[67] = 1
            put32(&e, 68, 0xFFFF_FFFF); put32(&e, 72, 0xFFFF_FFFF); put32(&e, 76, child)
            put32(&e, 116, start); put32(&e, 120, size)
            return e
        }
        let dir = entry("Root Entry", type: 5, start: 0xFFFF_FFFE, size: 0, child: 1)
            + entry("Workbook", type: 2, start: 2, size: UInt32(stream.count), child: 0xFFFF_FFFF) + [UInt8](repeating: 0, count: 256)
        return Data(header + fatBytes + dir + stream + [UInt8](repeating: 0, count: sectors * 512 - stream.count))
    }

    /// A page with a 32 pt bold heading over a 4 × 4 table in 10 pt type.
    private static func headingTablePDF(_ url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ConversionError.toolFailed("no PDF context") }
        ctx.beginPDFPage(nil)
        func draw(_ s: String, _ font: String, _ size: CGFloat, _ x: CGFloat, _ y: CGFloat) {
            let f = CTFontCreateWithName(font as CFString, size, nil)
            let attrs = [NSAttributedString.Key(kCTFontAttributeName as String): f]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs) as CFAttributedString)
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, ctx)
        }
        draw("Monthly Wage Report", "Helvetica-Bold", 32, 72, 700)
        let rows = [["Name", "Hours", "Rate", "Total"], ["Mark", "40", "12.5", "500"], ["Wendy", "35", "14", "490"], ["Kim", "20", "11.25", "225"]]
        for (r, row) in rows.enumerated() {
            for (c, text) in row.enumerated() { draw(text, "Helvetica", 10, 72 + CGFloat(c) * 90, 660 - CGFloat(r) * 16) }
        }
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// A workbook with every kind of value, a merge and a hidden sheet.
    static func sampleWorkbook() -> Workbook {
        var book = Workbook()
        var s = Worksheet(name: "Data & more")
        let money = book.format("#,##0.00")
        let pct = book.format("0.0%")
        let day = book.format("yyyy-mm-dd")
        s.set(0, 0, SheetCell(value: .text("Item"))); s.set(0, 1, SheetCell(value: .text("Price")))
        s.set(0, 2, SheetCell(value: .text("When"))); s.set(0, 3, SheetCell(value: .text("Done")))
        s.set(1, 0, SheetCell(value: .text("Café “crème”, <b>&</b>"))); s.set(1, 1, SheetCell(value: .number(1234.5), format: money))
        s.set(1, 2, SheetCell(value: .date(SheetDate.days(year: 2024, month: 1, day: 15), .date), format: day))
        s.set(1, 3, SheetCell(value: .bool(true)))
        s.set(2, 0, SheetCell(value: .text("Line one\nLine two"))); s.set(2, 1, SheetCell(value: .number(-0.125), format: pct))
        s.set(2, 2, SheetCell(value: .date(SheetDate.days(year: 2023, month: 12, day: 31, hour: 23, minute: 59, second: 30), .dateTime)))
        s.set(2, 3, SheetCell(value: .bool(false)))
        s.set(3, 0, SheetCell(value: .text("  padded  "))); s.set(3, 1, SheetCell(value: .number(1e-7)))
        s.set(3, 2, SheetCell(value: .date(0.75, .time))); s.set(3, 3, SheetCell(value: .error("#DIV/0!")))
        s.set(4, 0, SheetCell(value: .text("日本語 ✓"))); s.set(4, 1, SheetCell(value: .number(12345678901234)))
        s.set(4, 2, SheetCell(value: .date(30.5, .time), format: book.format("[h]:mm:ss")))
        s.set(5, 0, SheetCell(value: .text("Merged across three")))
        s.merges = [SheetRange(r0: 5, c0: 0, r1: 5, c1: 2)]
        s.set(7, 5, SheetCell(value: .number(42)))
        book.sheets.append(s)
        var hidden = Worksheet(name: "Secret")
        hidden.hidden = true
        hidden.set(0, 0, SheetCell(value: .text("hidden value")))
        book.sheets.append(hidden)
        return book
    }

    /// Compares values and types cell by cell.
    static func compare(_ a: Workbook, _ b: Workbook, _ label: String, check: (Bool, @autoclosure () -> String) -> Void,
                        ignoreFormats: Bool = false) {
        check(a.sheets.count == b.sheets.count, "\(label): \(b.sheets.count) sheets, expected \(a.sheets.count)")
        for (sa, sb) in zip(a.sheets, b.sheets) {
            check(sa.name == sb.name || label == "CSV", "\(label): sheet name \(sb.name), expected \(sa.name)")
            for r in 0..<max(sa.rowCount, sb.rowCount) {
                for c in 0..<max(sa.columnCount, sb.columnCount) {
                    let va = sa[r, c].value, vb = sb[r, c].value
                    var same = va == vb
                    if case .number(let x) = va, case .number(let y) = vb { same = x == y || abs(x - y) <= abs(x) * 1e-15 }
                    if case .date(let x, let kx) = va, case .date(let y, let ky) = vb { same = abs(x - y) < 1e-8 && kx == ky }
                    check(same, "\(label): \(SheetRef.name(row: r, column: c)) is \(vb), expected \(va)")
                }
            }
        }
    }
}
#endif
