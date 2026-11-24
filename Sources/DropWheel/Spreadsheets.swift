import AppKit

/// Spreadsheets: XLSX, XLS, ODS, CSV, TSV; spreadsheets → PDF; PDF → XLSX.
/// Everything is YummyOrange's own code (no Office, Numbers, LibreOffice or Java).
///
/// Options (all optional, for `--opt key=value`):
/// - reading CSV/TSV: `delimiter` (auto, comma, semicolon, tab, bar), `encoding` (auto, utf-8, utf-16,
///   windows-1252, macroman), `types` (true: numbers, booleans and ISO dates become typed cells)
/// - every output: `sheet` (all, a 1-based number or a name)
/// - XLSX/ODS: `freeze` (auto, true, false): freeze and bold the header row
/// - CSV/TSV: `shown` (false: raw values; true: values as formatted), `bom` (false), `separator` (CSV only: , ; |)
/// - PDF: `paper` (auto, a4, letter, legal, a3), `orientation` (auto, portrait, landscape), `fontSize` (9),
///   `header` (auto, true, false: repeat the first row), `maxColumnWidth` (220 pt), `maxLines` (4)
/// - PDF → XLSX: `ocr` (true: read scanned pages with Vision)
enum Spreadsheets: FeatureModule {
    /// The outputs offered for spreadsheets, in petal order.
    private static let outputs: [(format: SpreadsheetsIO.Format, title: String)] = [
        (.xlsx, "XLSX"), (.ods, "ODS"), (.csv, "CSV"), (.tsv, "TSV"), (.pdf, "PDF"),
    ]

    static var commands: [WheelCommand] {
        var list = outputs.map { output in
            WheelCommand(wheel: .convert, id: output.format.rawValue, title: output.title,
                         applies: { files in
                             Ext.all(files, in: Ext.spreadsheets) && !files.allSatisfy { sameFormat($0, output.format) }
                         },
                         run: { files, options, progress in
                             var outs: [URL] = []
                             for (i, file) in files.enumerated() where !sameFormat(file, output.format) {
                                 outs += try convert(file, to: output.format, options: options) { f in
                                     progress((Double(i) + f) / Double(files.count))
                                 }
                             }
                             return outs
                         })
        }
        list.append(WheelCommand(wheel: .convert, id: "xlsx", title: "XLSX",
                                 applies: { Ext.all($0, in: ["pdf"]) },
                                 run: { files, options, progress in
                                     var outs: [URL] = []
                                     for (i, file) in files.enumerated() {
                                         outs.append(try pdfToXLSX(file, options: options) { f in
                                             progress((Double(i) + f) / Double(files.count))
                                         })
                                     }
                                     return outs
                                 }))
        return list
    }

    /// Whether `url` already is `format` (by extension), so that petal isn't offered.
    private static func sameFormat(_ url: URL, _ format: SpreadsheetsIO.Format) -> Bool {
        let ext = Ext.of(url)
        return ext == format.rawValue
    }

    /// Any spreadsheet → another format, written next to it.
    static func convert(_ url: URL, to format: SpreadsheetsIO.Format, options: ToolOptions,
                        progress: @escaping (Double) -> Void) throws -> [URL] {
        let book = try SpreadsheetsIO.read(url, options: options)
        progress(0.4)
        return try SpreadsheetsIO.write(book, as: format, next: url, options: options) { progress(0.4 + 0.6 * $0) }
    }

    /// PDF → XLSX, one sheet per page.
    static func pdfToXLSX(_ url: URL, options: ToolOptions, progress: @escaping (Double) -> Void) throws -> URL {
        let book = try SpreadsheetsFromPDF.workbook(from: url, options: options) { progress(0.9 * $0) }
        let out = outputURL(for: url, ext: "xlsx")
        let freeze: Bool? = options.string("freeze", "auto") == "auto" ? nil : options.bool("freeze", false)
        try XLSXWriter.write(book, to: out, options: .init(freezeHeader: freeze))
        progress(1)
        return out
    }

    // MARK: Self-test

    static func selfTest(_ name: String) -> String? {
        #if DEBUG
        guard name == "spreadsheets" else { return nil }
        return SpreadsheetsSelfTest.run()
        #else
        return nil
        #endif
    }
}
