import Foundation

/// An OLE2 compound file ("Compound File Binary"), the container of .xls workbooks: header, FAT
/// (through the DIFAT), mini FAT and mini stream, and the directory of named streams.
struct XLSCompoundFile {
    struct Entry { let name: String; let type: UInt8; let start: UInt32; let size: Int }

    let entries: [Entry]
    private let bytes: [UInt8]
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniCutoff: Int
    private let fat: [UInt32]
    private let miniFat: [UInt32]
    private let miniStream: [UInt8]

    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    static func isCompound(_ data: Data) -> Bool { data.count >= 512 && data.prefix(8).elementsEqual(signature) }

    init(data: Data) throws {
        let b = [UInt8](data)
        bytes = b
        guard b.count >= 512, b.prefix(8).elementsEqual(Self.signature) else { throw Self.damaged("header") }
        let major = Self.u16(b, 26)
        let shift = Int(Self.u16(b, 30)), miniShift = Int(Self.u16(b, 32))
        guard (shift == 9 || shift == 12), miniShift == 6 else { throw Self.damaged("sector size") }
        sectorSize = 1 << shift
        miniSectorSize = 1 << miniShift
        let fatCount = Int(Self.u32(b, 44))
        let dirStart = Self.u32(b, 48)
        miniCutoff = Int(Self.u32(b, 56)) == 0 ? 4096 : Int(Self.u32(b, 56))
        let miniFatStart = Self.u32(b, 60), miniFatCount = Int(Self.u32(b, 64))
        var difatSector = Self.u32(b, 68)
        let difatCount = Int(Self.u32(b, 72))
        let totalSectors = max(0, (b.count - sectorSize) / sectorSize + 1)
        guard fatCount <= totalSectors, difatCount <= totalSectors else { throw Self.damaged("FAT size") }

        // DIFAT: 109 entries in the header, then a chain of DIFAT sectors.
        var fatSectors: [UInt32] = []
        for i in 0..<109 {
            let s = Self.u32(b, 76 + i * 4)
            if s < 0xFFFF_FFFA { fatSectors.append(s) }
        }
        var guardCount = 0
        while difatSector < 0xFFFF_FFFA, guardCount < difatCount + 1 {
            let off = (Int(difatSector) + 1) * sectorSize
            guard off + sectorSize <= b.count else { break }
            let perSector = sectorSize / 4 - 1
            for i in 0..<perSector {
                let s = Self.u32(b, off + i * 4)
                if s < 0xFFFF_FFFA { fatSectors.append(s) }
            }
            difatSector = Self.u32(b, off + perSector * 4)
            guardCount += 1
        }
        var fatTable: [UInt32] = []
        fatTable.reserveCapacity(fatSectors.count * sectorSize / 4)
        for s in fatSectors.prefix(max(fatCount, 1)) {
            let off = (Int(s) + 1) * sectorSize
            guard off + sectorSize <= b.count else { continue }
            for i in 0..<(sectorSize / 4) { fatTable.append(Self.u32(b, off + i * 4)) }
        }
        fat = fatTable

        // Directory.
        let dirBytes = Self.chain(b, start: dirStart, table: fatTable, unit: sectorSize, offset: { (Int($0) + 1) * $1 }, limit: nil)
        var list: [Entry] = []
        var p = 0
        while p + 128 <= dirBytes.count {
            let nameLen = Int(Self.u16(dirBytes, p + 64))
            let type = dirBytes[p + 66]
            var name = ""
            if nameLen >= 2 && nameLen <= 64 {
                let units = (0..<(nameLen / 2 - 1)).map { UInt16(dirBytes[p + $0 * 2]) | UInt16(dirBytes[p + $0 * 2 + 1]) << 8 }
                name = String(decoding: units, as: UTF16.self)
            }
            let start = Self.u32(dirBytes, p + 116)
            var size = Int(Self.u32(dirBytes, p + 120))
            if major >= 4 { size |= Int(Self.u32(dirBytes, p + 124)) << 32 }
            list.append(Entry(name: name, type: type, start: start, size: size))
            p += 128
        }
        entries = list
        guard let root = list.first, root.type == 5 else { throw Self.damaged("directory") }

        let miniFatBytes = miniFatCount > 0
            ? Self.chain(b, start: miniFatStart, table: fatTable, unit: sectorSize, offset: { (Int($0) + 1) * $1 }, limit: nil)
            : []
        miniFat = stride(from: 0, to: miniFatBytes.count - 3, by: 4).map { Self.u32(miniFatBytes, $0) }
        miniStream = Self.chain(b, start: root.start, table: fatTable, unit: sectorSize, offset: { (Int($0) + 1) * $1 }, limit: root.size)
    }

    /// A stream's bytes by name (case-insensitive), or nil.
    func stream(_ name: String) -> [UInt8]? {
        guard let e = entries.first(where: { $0.type == 2 && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        if e.size < miniCutoff {
            return Self.chain(miniStream, start: e.start, table: miniFat, unit: miniSectorSize, offset: { Int($0) * $1 }, limit: e.size)
        }
        return Self.chain(bytes, start: e.start, table: fat, unit: sectorSize, offset: { (Int($0) + 1) * $1 }, limit: e.size)
    }

    func hasStream(_ name: String) -> Bool { entries.contains { $0.type == 2 && $0.name.caseInsensitiveCompare(name) == .orderedSame } }

    /// Follows a sector chain, guarding against loops and running off the end.
    private static func chain(_ b: [UInt8], start: UInt32, table: [UInt32], unit: Int,
                              offset: (UInt32, Int) -> Int, limit: Int?) -> [UInt8] {
        var out: [UInt8] = []
        if let limit { out.reserveCapacity(min(limit, b.count)) }
        var s = start
        var steps = 0
        while s < 0xFFFF_FFFA, Int(s) < table.count || table.isEmpty, steps <= table.count {
            let off = offset(s, unit)
            guard off >= 0, off + unit <= b.count else {
                if off >= 0, off < b.count { out.append(contentsOf: b[off..<b.count]) }
                break
            }
            out.append(contentsOf: b[off..<(off + unit)])
            if let limit, out.count >= limit { break }
            guard Int(s) < table.count else { break }
            s = table[Int(s)]
            steps += 1
        }
        if let limit, out.count > limit { out.removeLast(out.count - limit) }
        return out
    }

    private static func damaged(_ what: String) -> Error {
        ConversionError.unsupported("This Excel file is damaged (\(what)).")
    }

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { i + 1 < b.count ? UInt16(b[i]) | UInt16(b[i + 1]) << 8 : 0 }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        i + 3 < b.count ? UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24 : 0
    }
}

/// Reads Excel 97–2003 workbooks: the BIFF8 "Workbook" stream (and BIFF5's "Book" from Excel 5/95) —
/// BOUNDSHEET for sheet names, order and visibility, the shared string table across CONTINUE records,
/// LABELSST, LABEL, RSTRING, NUMBER, RK, MULRK, BOOLERR, FORMULA with its cached result (and the STRING
/// record that follows it), MERGEDCELLS, and XF/FORMAT for number formats so dates come out as dates.
enum XLSReader {
    static func read(_ data: Data, name: String) throws -> Workbook {
        let file = try XLSCompoundFile(data: data)
        if file.hasStream("EncryptedPackage") {
            throw ConversionError.unsupported("\(name) is password-protected. Open it in Excel or Numbers and save it without a password first.")
        }
        guard let stream = file.stream("Workbook") ?? file.stream("Book") else {
            if file.hasStream("WordDocument") { throw ConversionError.unsupported("\(name) is a Word document, not a spreadsheet.") }
            if file.hasStream("PowerPoint Document") { throw ConversionError.unsupported("\(name) is a PowerPoint file, not a spreadsheet.") }
            throw ConversionError.unsupported("\(name) has no Excel workbook inside.")
        }
        return try parseWorkbook(stream, name: name)
    }

    // MARK: Records

    private struct Record { let type: UInt16; let start: Int; let length: Int }

    private static func records(_ s: [UInt8], from offset: Int) -> AnyIterator<Record> {
        var p = offset
        return AnyIterator {
            guard p + 4 <= s.count else { return nil }
            let type = XLSCompoundFile.u16(s, p), len = Int(XLSCompoundFile.u16(s, p + 2))
            let start = p + 4
            guard start + len <= s.count else { p = s.count; return Record(type: type, start: start, length: s.count - start) }
            p = start + len
            return Record(type: type, start: start, length: len)
        }
    }

    private struct BoundSheet { let offset: Int; let hidden: Bool; let kind: UInt8; let name: String }

    private static func parseWorkbook(_ s: [UInt8], name: String) throws -> Workbook {
        let it = records(s, from: 0)
        guard let bof = it.next(), bof.type == 0x0809 || bof.type == 0x0409 || bof.type == 0x0209 || bof.type == 0x0009 else {
            throw ConversionError.unsupported("\(name) isn’t an Excel workbook.")
        }
        guard bof.type == 0x0809 else {
            throw ConversionError.unsupported("\(name) is from Excel 4 or earlier, which YummyOrange can’t read.")
        }
        let version = XLSCompoundFile.u16(s, bof.start)
        let biff5 = version < 0x0600
        var codepage: UInt16 = 1252
        var date1904 = false
        var sheets: [BoundSheet] = []
        var sst: [String] = []
        var formats: [Int: String] = [:]
        var xfFormats: [Int] = []
        var sstSegments: [ArraySlice<UInt8>] = []
        var collectingSST = false

        func finishSST() {
            if collectingSST { sst = parseSST(sstSegments); sstSegments = []; collectingSST = false }
        }

        while let r = it.next() {
            let d = s[r.start..<(r.start + r.length)]
            if collectingSST && r.type != 0x003C { finishSST() }
            switch r.type {
            case 0x000A: finishSST(); break      // EOF of the globals
            case 0x002F:
                throw ConversionError.unsupported("\(name) is password-protected. Open it in Excel or Numbers and save it without a password first.")
            case 0x0042: codepage = XLSCompoundFile.u16(s, r.start)
            case 0x0022: date1904 = XLSCompoundFile.u16(s, r.start) == 1
            case 0x0085:
                guard r.length >= 7 else { continue }
                let offset = Int(XLSCompoundFile.u32(s, r.start))
                let hidden = s[r.start + 4] & 0x03 != 0
                let kind = s[r.start + 5]
                var p = r.start + 6
                let sheetName = biff5 ? byteString(s, &p, end: r.start + r.length, codepage: codepage)
                                      : shortUnicode(s, &p, end: r.start + r.length)
                sheets.append(BoundSheet(offset: offset, hidden: hidden, kind: kind, name: sheetName))
            case 0x00FC:
                collectingSST = true
                sstSegments = [d]
            case 0x003C:
                if collectingSST { sstSegments.append(d) }
            case 0x041E, 0x001E:
                guard r.length >= 3 else { continue }
                let id = Int(XLSCompoundFile.u16(s, r.start))
                var p = r.start + 2
                formats[id] = biff5 ? byteString(s, &p, end: r.start + r.length, codepage: codepage)
                                    : unicodeString(s, &p, end: r.start + r.length)
            case 0x00E0:
                guard r.length >= 4 else { continue }
                xfFormats.append(Int(XLSCompoundFile.u16(s, r.start + 2)))
            default: break
            }
            if r.type == 0x000A { break }
        }

        var book = Workbook()
        var styleCache: [Int: CellStyle] = [:]
        func style(_ xf: Int) -> CellStyle {
            let id = xf < xfFormats.count ? xfFormats[xf] : 0
            if let c = styleCache[id] { return c }
            let code = formats[id] ?? SheetNumberFormat.builtIn(id) ?? "General"
            let result = CellStyle(format: book.format(code), date: SheetNumberFormat.dateKind(code),
                                   elapsed: SheetNumberFormat.isElapsed(code))
            styleCache[id] = result
            return result
        }
        let sheetCount = sheets.filter { $0.kind == 0 || $0.kind == 1 }.count
        if sheetCount > SpreadsheetLimits.maxSheets { throw SpreadsheetLimits.tooManySheets(name) }

        var total = 0
        for bs in sheets where bs.kind == 0 || bs.kind == 1 {
            var sheet = Worksheet(name: bs.name.isEmpty ? "Sheet\(book.sheets.count + 1)" : bs.name)
            sheet.hidden = bs.hidden
            guard bs.offset >= 0, bs.offset + 4 <= s.count else { continue }
            try parseSheet(s, from: bs.offset, biff5: biff5, codepage: codepage, sst: sst, date1904: date1904,
                           style: style, into: &sheet, total: total)
            sheet.trim()
            total += sheet.allocated
            book.sheets.append(sheet)
        }
        guard !book.sheets.isEmpty else { throw ConversionError.unsupported("\(name) has no worksheets.") }
        return book
    }

    private typealias CellStyle = XLSXReader.CellStyle

    private static func parseSheet(_ s: [UInt8], from offset: Int, biff5: Bool, codepage: UInt16, sst: [String],
                                   date1904: Bool, style: (Int) -> CellStyle, into sheet: inout Worksheet,
                                   total: Int) throws {
        let it = records(s, from: offset)
        guard let bof = it.next(), bof.type == 0x0809 else { return }
        var depth = 1
        var pendingString: (row: Int, col: Int, xf: Int)?
        var stringSegments: [ArraySlice<UInt8>] = []

        func put(_ r: Int, _ c: Int, _ xf: Int, _ value: SheetValue) {
            guard r < SpreadsheetLimits.maxRows, c < SpreadsheetLimits.maxColumns else { return }
            let st = style(xf)
            var v = value
            if case .number(let n) = value, var kind = st.date, n > -1, n < 2_958_466 {
                // "h:mm" on a serial with a date part shows a date-time's clock time; "[h]:mm" a duration.
                if kind == .time, n >= 1, !st.elapsed { kind = .dateTime }
                v = .date(SheetDate.fromExcel(n, kind: kind, date1904: date1904), kind)
            }
            sheet.set(r, c, SheetCell(value: v, format: st.format))
        }
        func finishString() {
            guard let p = pendingString, !stringSegments.isEmpty else { return }
            let reader = SegmentReader(stringSegments)
            let text: String
            if biff5 {
                let n = Int(reader.u16())
                text = decodeBytes(reader.bytes(n), codepage: codepage)
            } else {
                text = reader.richString()
            }
            put(p.row, p.col, p.xf, .text(text))
            pendingString = nil
            stringSegments = []
        }

        while let r = it.next() {
            let st = r.start, len = r.length
            if !stringSegments.isEmpty && r.type != 0x003C { finishString() }
            switch r.type {
            case 0x0809: depth += 1               // an embedded chart's substream
            case 0x000A:
                depth -= 1
                if depth == 0 { finishString(); return }
            default: break
            }
            guard depth == 1 else { continue }
            func row() -> Int { Int(XLSCompoundFile.u16(s, st)) }
            func col() -> Int { Int(XLSCompoundFile.u16(s, st + 2)) }
            func xf() -> Int { Int(XLSCompoundFile.u16(s, st + 4)) }
            switch r.type {
            case 0x00FD where len >= 10:          // LABELSST
                let i = Int(XLSCompoundFile.u32(s, st + 6))
                put(row(), col(), xf(), i < sst.count ? .text(sst[i]) : .empty)
            case 0x0204 where len >= 8, 0x00D6 where len >= 8:    // LABEL, RSTRING
                var p = st + 6
                let text = biff5 ? wordByteString(s, &p, end: st + len, codepage: codepage) : unicodeString(s, &p, end: st + len)
                put(row(), col(), xf(), text.isEmpty ? .empty : .text(text))
            case 0x0203 where len >= 14:          // NUMBER
                put(row(), col(), xf(), .number(double(s, st + 6)))
            case 0x027E where len >= 10:          // RK
                put(row(), col(), xf(), .number(rk(XLSCompoundFile.u32(s, st + 6))))
            case 0x00BD where len >= 6:           // MULRK
                let r0 = row(), c0 = col()
                let n = (len - 6) / 6
                for k in 0..<n {
                    let p = st + 4 + k * 6
                    put(r0, c0 + k, Int(XLSCompoundFile.u16(s, p)), .number(rk(XLSCompoundFile.u32(s, p + 2))))
                }
            case 0x0205 where len >= 8:           // BOOLERR
                let v = s[st + 6], isError = s[st + 7] != 0
                put(row(), col(), xf(), isError ? .error(errorText(v)) : .bool(v != 0))
            case 0x0006 where len >= 14:          // FORMULA
                let rr = row(), cc = col(), x = xf()
                if s[st + 12] == 0xFF && s[st + 13] == 0xFF {
                    switch s[st + 6] {
                    case 0: pendingString = (rr, cc, x)            // the text follows in a STRING record
                    case 1: put(rr, cc, x, .bool(s[st + 8] != 0))
                    case 2: put(rr, cc, x, .error(errorText(s[st + 8])))
                    default: break                                 // empty string
                    }
                } else {
                    put(rr, cc, x, .number(double(s, st + 6)))
                }
            case 0x0207:                          // STRING (a formula's text result)
                if pendingString != nil { stringSegments = [s[st..<(st + len)]] }
            case 0x003C:
                if !stringSegments.isEmpty { stringSegments.append(s[st..<(st + len)]) }
            case 0x00E5 where len >= 2:           // MERGEDCELLS
                let n = Int(XLSCompoundFile.u16(s, st))
                for k in 0..<n {
                    let p = st + 2 + k * 8
                    guard p + 8 <= st + len else { break }
                    let r0 = Int(XLSCompoundFile.u16(s, p)), r1 = Int(XLSCompoundFile.u16(s, p + 2))
                    let c0 = Int(XLSCompoundFile.u16(s, p + 4)), c1 = Int(XLSCompoundFile.u16(s, p + 6))
                    if r1 >= r0, c1 >= c0 { sheet.merges.append(SheetRange(r0: r0, c0: c0, r1: r1, c1: c1)) }
                }
            default: break
            }
            if sheet.allocated + total > SpreadsheetLimits.maxCells { try SpreadsheetLimits.check(sheet, total: total) }
        }
        finishString()
    }

    // MARK: Values

    /// RK: a compressed number. Bit 0 divides by 100; bit 1 marks a 30-bit integer, otherwise the top
    /// 30 bits of a double.
    static func rk(_ v: UInt32) -> Double {
        var d: Double
        if v & 2 != 0 {
            d = Double(Int32(bitPattern: v) >> 2)
        } else {
            d = Double(bitPattern: UInt64(v & 0xFFFF_FFFC) << 32)
        }
        if v & 1 != 0 { d /= 100 }
        return d
    }

    private static func double(_ s: [UInt8], _ i: Int) -> Double {
        var bits: UInt64 = 0
        for k in 0..<8 { bits |= UInt64(s[i + k]) << (8 * UInt64(k)) }
        return Double(bitPattern: bits)
    }

    static func errorText(_ code: UInt8) -> String {
        switch code {
        case 0x00: return "#NULL!"
        case 0x07: return "#DIV/0!"
        case 0x0F: return "#VALUE!"
        case 0x17: return "#REF!"
        case 0x1D: return "#NAME?"
        case 0x24: return "#NUM!"
        case 0x2A: return "#N/A"
        default: return "#N/A"
        }
    }

    // MARK: Strings

    /// BIFF8 ShortXLUnicodeString: 1-byte length, flags, characters.
    private static func shortUnicode(_ s: [UInt8], _ p: inout Int, end: Int) -> String {
        guard p + 2 <= end else { return "" }
        let n = Int(s[p]), flags = s[p + 1]
        p += 2
        return chars(s, &p, count: n, wide: flags & 1 != 0, end: end)
    }

    /// BIFF8 XLUnicodeString: 2-byte length, flags, optional rich-text and extended headers, characters.
    private static func unicodeString(_ s: [UInt8], _ p: inout Int, end: Int) -> String {
        guard p + 3 <= end else { return "" }
        let n = Int(XLSCompoundFile.u16(s, p)), flags = s[p + 2]
        p += 3
        if flags & 0x08 != 0 { p += 2 }
        if flags & 0x04 != 0 { p += 4 }
        return chars(s, &p, count: n, wide: flags & 1 != 0, end: end)
    }

    /// The characters of a string, cut at the end of the record (a damaged or truncated file can claim more,
    /// or have its headers run past the end).
    private static func chars(_ s: [UInt8], _ p: inout Int, count n: Int, wide: Bool, end: Int) -> String {
        let end = min(end, s.count)
        guard p >= 0, p < end else { p = max(end, 0); return "" }
        if wide {
            let available = min(n, max(0, (end - p) / 2))
            let units = (0..<available).map { UInt16(s[p + $0 * 2]) | UInt16(s[p + $0 * 2 + 1]) << 8 }
            p += available * 2
            return String(decoding: units, as: UTF16.self)
        }
        let available = min(n, max(0, end - p))
        // "Compressed" BIFF8 text is UTF-16 with the high bytes dropped, i.e. Latin-1.
        let str = String(s[p..<(p + available)].map { Character(UnicodeScalar($0)) })
        p += available
        return str
    }

    /// BIFF5 strings: 1-byte length and code-page bytes (sheet names, formats).
    private static func byteString(_ s: [UInt8], _ p: inout Int, end: Int, codepage: UInt16) -> String {
        guard p < end else { return "" }
        let n = min(Int(s[p]), end - p - 1)
        defer { p += 1 + max(0, n) }
        return decodeBytes(Array(s[(p + 1)..<(p + 1 + max(0, n))]), codepage: codepage)
    }

    /// BIFF5 cell strings: 2-byte length and code-page bytes.
    private static func wordByteString(_ s: [UInt8], _ p: inout Int, end: Int, codepage: UInt16) -> String {
        guard p + 2 <= end else { return "" }
        let n = min(Int(XLSCompoundFile.u16(s, p)), end - p - 2)
        defer { p += 2 + max(0, n) }
        return decodeBytes(Array(s[(p + 2)..<(p + 2 + max(0, n))]), codepage: codepage)
    }

    static func decodeBytes(_ bytes: [UInt8], codepage: UInt16) -> String {
        if codepage == 1200 || codepage == 0 { return String(bytes.map { Character(UnicodeScalar($0)) }) }
        let cf = CFStringConvertWindowsCodepageToEncoding(UInt32(codepage == 32769 ? 1252 : codepage))
        if cf != kCFStringEncodingInvalidId {
            let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            if let s = String(bytes: bytes, encoding: enc) { return s }
        }
        return String(bytes: bytes, encoding: .windowsCP1252) ?? String(bytes.map { Character(UnicodeScalar($0)) })
    }

    /// The shared string table, whose strings may be split across CONTINUE records. When a string's
    /// characters continue in the next record, that record starts with a fresh flags byte saying whether
    /// the rest is 8-bit or 16-bit.
    private static func parseSST(_ segments: [ArraySlice<UInt8>]) -> [String] {
        let reader = SegmentReader(segments)
        _ = reader.u32()
        let unique = Int(reader.u32())
        var out: [String] = []
        out.reserveCapacity(min(unique, 1_000_000))
        for _ in 0..<unique {
            guard !reader.atEnd else { break }
            out.append(reader.richString())
        }
        return out
    }

    /// Reads across CONTINUE boundaries.
    private final class SegmentReader {
        private let segments: [ArraySlice<UInt8>]
        private var seg = 0
        private var pos: Int

        init(_ segments: [ArraySlice<UInt8>]) {
            self.segments = segments
            pos = segments.first?.startIndex ?? 0
        }

        var atEnd: Bool {
            var s = seg, p = pos
            while s < segments.count {
                if p < segments[s].endIndex { return false }
                s += 1
                if s < segments.count { p = segments[s].startIndex }
            }
            return true
        }

        private func normalize() {
            while seg < segments.count, pos >= segments[seg].endIndex {
                seg += 1
                if seg < segments.count { pos = segments[seg].startIndex }
            }
        }

        func u8() -> UInt8 {
            normalize()
            guard seg < segments.count else { return 0 }
            let v = segments[seg][pos]
            pos += 1
            return v
        }

        func u16() -> UInt16 { UInt16(u8()) | UInt16(u8()) << 8 }
        func u32() -> UInt32 { UInt32(u16()) | UInt32(u16()) << 16 }

        func skip(_ n: Int) {
            var left = n
            while left > 0 {
                normalize()
                guard seg < segments.count else { return }
                let step = min(left, segments[seg].endIndex - pos)
                pos += step
                left -= step
            }
        }

        func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in u8() } }

        /// XLUnicodeRichExtendedString, switching between 8- and 16-bit characters at record boundaries.
        func richString() -> String {
            let count = Int(u16())
            var flags = u8()
            let runs = flags & 0x08 != 0 ? Int(u16()) : 0
            let ext = flags & 0x04 != 0 ? Int(u32()) : 0
            var units: [UInt16] = []
            units.reserveCapacity(count)
            while units.count < count {
                if seg < segments.count, pos >= segments[seg].endIndex {
                    // Characters continue in the next record, behind a new flags byte.
                    seg += 1
                    guard seg < segments.count else { break }
                    pos = segments[seg].startIndex
                    flags = u8()
                    continue
                }
                guard seg < segments.count else { break }
                if flags & 1 != 0 {
                    units.append(u16())
                } else {
                    units.append(UInt16(u8()))
                }
            }
            skip(runs * 4 + ext)
            return String(decoding: units, as: UTF16.self)
        }
    }
}
