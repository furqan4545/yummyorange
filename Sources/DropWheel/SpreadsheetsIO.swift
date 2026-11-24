import Foundation

/// Reading any spreadsheet into a `Workbook` and writing one out. The format is decided from the file's
/// bytes, not its extension, so an .xls that is really an .xlsx (or CSV text) still opens.
enum SpreadsheetsIO {
    enum Format: String { case xlsx, ods, xls, csv, tsv, pdf }

    /// Files over this size are refused before reading (memory: a workbook expands several times when parsed).
    static let maxInputBytes = 512 * 1024 * 1024

    static func read(_ url: URL, options: ToolOptions = [:]) throws -> Workbook {
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > maxInputBytes {
            throw ConversionError.unsupported("\(name) is too large to convert (over \(maxInputBytes / 1_048_576) MB).")
        }
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw ConversionError.unreadable(name) }
        let ext = Ext.of(url)
        let sheetName = url.deletingPathExtension().lastPathComponent

        if data.isEmpty { throw ConversionError.unsupported("\(name) is empty.") }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) || data.starts(with: [0x50, 0x4B, 0x05, 0x06]) {
            let zip: ZipReader
            do { zip = try ZipReader(data: data) } catch {
                throw ConversionError.unsupported("\(name) is damaged or incomplete, so it can’t be opened.")
            }
            if let mime = try? zip.readString("mimetype"), mime.hasPrefix("application/vnd.oasis.opendocument") {
                guard mime.contains("spreadsheet") else {
                    throw ConversionError.unsupported("\(name) is an OpenDocument file but not a spreadsheet.")
                }
                return try ODSReader.read(zip, name: name)
            }
            if zip.contains("[Content_Types].xml") {
                if zip.contains("word/document.xml") { throw ConversionError.unsupported("\(name) is a Word document, not a spreadsheet.") }
                if zip.contains("ppt/presentation.xml") { throw ConversionError.unsupported("\(name) is a PowerPoint file, not a spreadsheet.") }
                return try XLSXReader.read(zip, name: name)
            }
            if zip.contains("content.xml") { return try ODSReader.read(zip, name: name) }
            if zip.names.contains(where: { $0.hasPrefix("Index/") && $0.hasSuffix(".iwa") }) {
                throw ConversionError.unsupported("\(name) is a Numbers document. Export it from Numbers as Excel first.")
            }
            throw ConversionError.unsupported("\(name) is a ZIP archive, not a spreadsheet.")
        }
        if XLSCompoundFile.isCompound(data) {
            return try XLSReader.read(data, name: name)
        }
        let head = String(decoding: data.prefix(2048), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("<") {
            if head.contains("office:document") { return try ODSReader.readFlat(data, name: name) }
            if head.contains("urn:schemas-microsoft-com:office:spreadsheet") {
                throw ConversionError.unsupported("\(name) is an Excel 2003 XML spreadsheet, which YummyOrange can’t read yet.")
            }
            if ext != "csv" && ext != "tsv" && head.lowercased().contains("<table") {
                throw ConversionError.unsupported("\(name) is a web page saved as a spreadsheet, which YummyOrange can’t read yet.")
            }
        }
        if data.starts(with: [0x25, 0x50, 0x44, 0x46]) { throw ConversionError.unsupported("\(name) is a PDF, not a spreadsheet.") }
        // A binary format that matched nothing above is damaged (or misnamed), not delimited text.
        if ["xlsx", "xlsm", "ods", "xls"].contains(ext), data.prefix(4096).contains(0) {
            throw ConversionError.unsupported("\(name) is damaged or isn’t really a .\(ext) file.")
        }
        // Anything else is delimited text.
        return try CSVCodec.read(data, name: name, sheetName: sheetName, isTSV: ext == "tsv", options: csvOptions(options))
    }

    static func csvOptions(_ o: ToolOptions) -> CSVCodec.ReadOptions {
        var r = CSVCodec.ReadOptions()
        switch o.string("delimiter", "auto").lowercased() {
        case ",", "comma": r.delimiter = UInt8(ascii: ",")
        case ";", "semicolon": r.delimiter = UInt8(ascii: ";")
        case "tab", "\\t", "\t": r.delimiter = UInt8(ascii: "\t")
        case "|", "bar", "pipe": r.delimiter = UInt8(ascii: "|")
        default: break
        }
        switch o.string("encoding", "auto").lowercased() {
        case "utf-8", "utf8": r.encoding = .utf8
        case "utf-16", "utf16": r.encoding = .utf16
        case "utf-16le": r.encoding = .utf16LittleEndian
        case "utf-16be": r.encoding = .utf16BigEndian
        case "windows-1252", "cp1252", "latin1", "iso-8859-1": r.encoding = .windowsCP1252
        case "mac", "macroman": r.encoding = .macOSRoman
        default: break
        }
        r.detectTypes = o.bool("types", true)
        return r
    }

    /// Which sheets an option selects: "all" (default), a 1-based number, or a name.
    static func selectSheets(_ book: Workbook, _ o: ToolOptions) throws -> [Worksheet] {
        let pick = o.string("sheet", "all")
        if pick.lowercased() == "all" { return book.sheets }
        if let n = Int(pick), n >= 1, n <= book.sheets.count { return [book.sheets[n - 1]] }
        if let s = book.sheets.first(where: { $0.name.caseInsensitiveCompare(pick) == .orderedSame }) { return [s] }
        throw ConversionError.unsupported("There’s no sheet called “\(pick)”. Sheets: \(book.sheets.map(\.name).joined(separator: ", ")).")
    }

    /// Writes `book` in `format` next to `source`. Delimited text gives one file per sheet when there are several.
    static func write(_ book: Workbook, as format: Format, next source: URL, options: ToolOptions,
                      progress: (Double) -> Void) throws -> [URL] {
        var book = book
        guard !book.isEmpty || format == .xlsx || format == .ods else {
            throw ConversionError.unsupported("\(source.lastPathComponent) has no cells to convert.")
        }
        let freeze: Bool? = {
            switch options.string("freeze", "auto").lowercased() {
            case "true", "yes", "1", "on": return true
            case "false", "no", "0", "off": return false
            default: return nil
            }
        }()
        switch format {
        case .xls:
            throw ConversionError.unsupported("YummyOrange can’t write the old Excel 97–2003 format; choose XLSX instead.")
        case .xlsx:
            book.sheets = try selectSheets(book, options)
            let out = outputURL(for: source, ext: "xlsx")
            try XLSXWriter.write(book, to: out, options: .init(freezeHeader: freeze))
            return [out]
        case .ods:
            book.sheets = try selectSheets(book, options)
            let out = outputURL(for: source, ext: "ods")
            try ODSWriter.write(book, to: out, options: .init(freezeHeader: freeze))
            return [out]
        case .csv, .tsv:
            var sheets = try selectSheets(book, options)
            // Several sheets: skip the empty ones, unless every one is empty.
            if sheets.count > 1 {
                let used = sheets.filter { !$0.isEmpty }
                sheets = used.isEmpty ? [sheets[0]] : used
            }
            let delimiter: Character
            switch (format, options.string("separator", ",").lowercased()) {
            case (.tsv, _): delimiter = "\t"
            case (_, ";"), (_, "semicolon"): delimiter = ";"
            case (_, "|"), (_, "bar"), (_, "pipe"): delimiter = "|"
            case (_, "tab"): delimiter = "\t"
            default: delimiter = ","
            }
            let ext = format.rawValue
            for sheet in sheets {
                try CSVCodec.checkSize(sheet, file: source.lastPathComponent, format: ext.uppercased())
            }
            var outs: [URL] = []
            for (i, sheet) in sheets.enumerated() {
                let data = CSVCodec.write(sheet, book: book, delimiter: delimiter, shown: options.bool("shown", false),
                                          bom: options.bool("bom", false))
                let out = sheets.count > 1 ? outputURL(for: source, ext: ext, suffix: " - " + SheetText.fileNamePart(sheet.name))
                                           : outputURL(for: source, ext: ext)
                do { try data.write(to: out, options: .atomic) }
                catch { throw ConversionError.toolFailed("Couldn’t save \(out.lastPathComponent).") }
                outs.append(out)
                progress(Double(i + 1) / Double(sheets.count))
            }
            return outs
        case .pdf:
            book.sheets = try selectSheets(book, options)
            let out = outputURL(for: source, ext: "pdf")
            try SpreadsheetsPDF.write(book, to: out, title: source.lastPathComponent, options: options, progress: progress)
            return [out]
        }
    }
}
