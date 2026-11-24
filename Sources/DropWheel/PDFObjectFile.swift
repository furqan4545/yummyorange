import Compression
import CoreGraphics
import Foundation

// The object layer of Edit PDF: values, a lexer that keeps byte ranges, the cross-reference sections (classic
// tables, xref streams, hybrid files with /XRefStm, the /Prev chain), object streams, stream filters and the
// page tree. It reads only; PDFObjectWriter appends updates or rewrites the file.

/// A PDF value as stored in a file. Numbers keep their source text, so a value written back reads the same.
indirect enum PDFValue {
    case null
    case bool(Bool)
    case number(Double, String)
    case string([UInt8], hex: Bool)
    case name(String)
    case array([PDFValue])
    case dict(PDFDict)
    case ref(Int, Int)

    var dict: PDFDict? { if case .dict(let d) = self { return d }; return nil }
    var array: [PDFValue]? { if case .array(let a) = self { return a }; return nil }
    var double: Double? { if case .number(let d, _) = self { return d }; return nil }
    var int: Int? {
        if case .number(let d, _) = self { return PDFNumber.int(d) }
        return nil
    }
    var name: String? { if case .name(let n) = self { return n }; return nil }
    var bytes: [UInt8]? { if case .string(let b, _) = self { return b }; return nil }
    var ref: (number: Int, generation: Int)? { if case .ref(let n, let g) = self { return (n, g) }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    static func number(_ d: Double) -> PDFValue { .number(d, PDFNumber.format(d)) }
    static func integer(_ i: Int) -> PDFValue { .number(Double(i), String(i)) }
}

/// A dictionary that keeps its keys in file order.
struct PDFDict {
    private(set) var keys: [String] = []
    private var values: [String: PDFValue] = [:]

    init() {}
    init(_ pairs: [(String, PDFValue)]) { for (k, v) in pairs { self[k] = v } }

    subscript(key: String) -> PDFValue? {
        get { values[key] }
        set {
            if let v = newValue {
                if values[key] == nil { keys.append(key) }
                values[key] = v
            } else if values[key] != nil {
                keys.removeAll { $0 == key }
                values[key] = nil
            }
        }
    }

    var pairs: [(String, PDFValue)] { keys.map { ($0, values[$0]!) } }
    var isEmpty: Bool { keys.isEmpty }
}

enum PDFNumber {
    /// A whole number a file can mean (an object number, offset, count or index), or nil when the value is not
    /// finite or too large to be one. Crafted files put numbers like 1e300 where an integer belongs, and
    /// `Int(_:)` traps on them.
    static func int(_ d: Double) -> Int? {
        guard d.isFinite, abs(d) < 1e15 else { return nil }
        return Int(d)
    }

    /// `int(_:)` clamped into `range` (for values that only select a mode, such as a render mode).
    static func int(_ d: Double, clampedTo range: ClosedRange<Int>) -> Int {
        guard !d.isNaN else { return range.lowerBound }
        if d <= Double(range.lowerBound) { return range.lowerBound }
        if d >= Double(range.upperBound) { return range.upperBound }
        return Int(d)
    }

    /// Up to four decimals, no trailing zeros, never "-0".
    static func format(_ d: Double) -> String {
        guard d.isFinite else { return "0" }
        if d == d.rounded(), abs(d) < 1e12 { return String(Int(d)) }
        var s = String(format: "%.4f", d)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        if s == "-0" { s = "0" }
        return s
    }
}

enum PDFObjectError: LocalizedError {
    case unreadable(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let s), .unsupported(let s): return s
        }
    }
}

// MARK: - Lexer

/// Tokens of the PDF syntax with the byte range each one came from. Used for objects and for content streams.
struct PDFLexer {
    enum Token: Equatable {
        case number(Double, String)
        case name(String)
        case string([UInt8], hex: Bool)
        case arrayOpen, arrayClose, dictOpen, dictClose
        case keyword(String)
        case eof
    }

    let b: [UInt8]
    var p: Int

    init(_ bytes: [UInt8], at position: Int = 0) { b = bytes; p = position }

    @inline(__always) static func isWhite(_ c: UInt8) -> Bool { c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32 }
    @inline(__always) static func isDelimiter(_ c: UInt8) -> Bool {
        c == 40 || c == 41 || c == 60 || c == 62 || c == 91 || c == 93 || c == 123 || c == 125 || c == 47 || c == 37
    }

    mutating func skipWhite() {
        while p < b.count {
            let c = b[p]
            if PDFLexer.isWhite(c) { p += 1 }
            else if c == 37 { while p < b.count, b[p] != 10, b[p] != 13 { p += 1 } }
            else { break }
        }
    }

    /// The next token and its byte range.
    mutating func next() -> (Token, Range<Int>) {
        skipWhite()
        guard p < b.count else { return (.eof, p..<p) }
        let s = p
        let c = b[p]
        switch c {
        case 91: p += 1; return (.arrayOpen, s..<p)
        case 93: p += 1; return (.arrayClose, s..<p)
        case 123, 125: p += 1; return (.keyword(c == 123 ? "{" : "}"), s..<p)
        case 60:
            if p + 1 < b.count, b[p + 1] == 60 { p += 2; return (.dictOpen, s..<p) }
            p += 1
            var out: [UInt8] = []
            var half: UInt8?
            while p < b.count, b[p] != 62 {
                if let v = PDFLexer.hexValue(b[p]) {
                    if let h = half { out.append(h << 4 | v); half = nil } else { half = v }
                }
                p += 1
            }
            if let h = half { out.append(h << 4) }
            if p < b.count { p += 1 }
            return (.string(out, hex: true), s..<p)
        case 62:
            if p + 1 < b.count, b[p + 1] == 62 { p += 2; return (.dictClose, s..<p) }
            p += 1
            return (.keyword(">"), s..<p)
        case 40:
            return (.string(literal(), hex: false), s..<p)
        case 41:
            p += 1
            return (.keyword(")"), s..<p)
        case 47:
            p += 1
            var name: [UInt8] = []
            while p < b.count, !PDFLexer.isWhite(b[p]), !PDFLexer.isDelimiter(b[p]) {
                if b[p] == 35, p + 2 < b.count, let h = PDFLexer.hexValue(b[p + 1]), let l = PDFLexer.hexValue(b[p + 2]) {
                    name.append(h << 4 | l); p += 3
                } else {
                    name.append(b[p]); p += 1
                }
            }
            return (.name(String(decoding: name, as: UTF8.self)), s..<p)
        default:
            while p < b.count, !PDFLexer.isWhite(b[p]), !PDFLexer.isDelimiter(b[p]) { p += 1 }
            if p == s { p += 1 }
            let word = String(decoding: b[s..<p], as: UTF8.self)
            // PDF numbers are digits, a sign and a point (an exponent is tolerated). `Double("+nan")`, "-inf" and
            // "0x1p3" also parse, so anything else is a keyword; values too large for a Double are clamped.
            if let f = word.utf8.first, f == 43 || f == 45 || f == 46 || (48...57).contains(f),
               word.utf8.allSatisfy({ (48...57).contains($0) || $0 == 43 || $0 == 45 || $0 == 46 || $0 == 69 || $0 == 101 }) {
                if let d = Double(word) {
                    if !d.isFinite { let c = d < 0 ? -3.4e38 : 3.4e38; return (.number(c, PDFNumber.format(c)), s..<p) }
                    return (.number(d, word), s..<p)
                }
                if word == "-" || word == "." || word == "+" { return (.number(0, "0"), s..<p) }
                // "--5" and similar: readers take the number they can.
                let digits = word.drop { $0 == "-" || $0 == "+" }
                if let d = Double(digits) {
                    let v = min(3.4e38, word.hasPrefix("-") ? -d : d)
                    return (.number(max(-3.4e38, v), PDFNumber.format(max(-3.4e38, v))), s..<p)
                }
            }
            return (.keyword(word), s..<p)
        }
    }

    @inline(__always) static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }

    private mutating func literal() -> [UInt8] {
        p += 1
        var out: [UInt8] = []
        var depth = 1
        while p < b.count {
            let c = b[p]
            p += 1
            if c == 92 {
                guard p < b.count else { break }
                let e = b[p]
                p += 1
                switch e {
                case 110: out.append(10)
                case 114: out.append(13)
                case 116: out.append(9)
                case 98: out.append(8)
                case 102: out.append(12)
                case 10: break
                case 13: if p < b.count, b[p] == 10 { p += 1 }
                case 48...55:
                    var v = Int(e - 48)
                    var n = 1
                    while n < 3, p < b.count, (48...55).contains(b[p]) { v = v * 8 + Int(b[p] - 48); p += 1; n += 1 }
                    out.append(UInt8(v & 0xFF))
                default: out.append(e)
                }
            } else if c == 40 {
                depth += 1; out.append(c)
            } else if c == 41 {
                depth -= 1
                if depth == 0 { break }
                out.append(c)
            } else if c == 13 {
                out.append(10)
                if p < b.count, b[p] == 10 { p += 1 }
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// One value. `n g R` becomes a reference when `refs` is on (objects; never in content streams).
    mutating func value(refs: Bool = true) -> PDFValue? {
        let (t, _) = next()
        return value(after: t, refs: refs)
    }

    mutating func value(after t: Token, refs: Bool = true, depth: Int = 0) -> PDFValue? {
        guard depth < 256 else { return nil }
        switch t {
        case .number(let d, let s):
            if refs, d >= 0, d == d.rounded(), !s.contains("."), let n = PDFNumber.int(d) {
                let save = p
                let (t2, _) = next()
                if case .number(let g, let gs) = t2, g >= 0, !gs.contains("."), let gen = PDFNumber.int(g) {
                    let (t3, _) = next()
                    if case .keyword("R") = t3 { return .ref(n, gen) }
                }
                p = save
            }
            return .number(d, s)
        case .name(let n): return .name(n)
        case .string(let bytes, let hex): return .string(bytes, hex: hex)
        case .arrayOpen:
            var a: [PDFValue] = []
            while true {
                let (t, _) = next()
                if case .arrayClose = t { break }
                if case .eof = t { break }
                guard let v = value(after: t, refs: refs, depth: depth + 1) else {
                    if case .keyword = t { continue }
                    break
                }
                a.append(v)
            }
            return .array(a)
        case .dictOpen:
            var d = PDFDict()
            while true {
                let (t, _) = next()
                if case .dictClose = t { break }
                if case .eof = t { break }
                guard case .name(let k) = t else { continue }
                let save = p
                let (vt, _) = next()
                if case .dictClose = vt { d[k] = .null; break }
                guard let v = value(after: vt, refs: refs, depth: depth + 1) else { p = save; d[k] = .null; continue }
                d[k] = v
            }
            return .dict(d)
        case .keyword(let w):
            switch w {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default: return nil
            }
        default:
            return nil
        }
    }
}

// MARK: - Stream filters

enum PDFFilters {
    /// The most bytes one stream may decode to. A crafted Flate, LZW or RunLength stream of a few kilobytes can
    /// expand to gigabytes (a decompression bomb); past this limit decoding stops with a clear error.
    static var maxDecodedBytes = 256 << 20

    static var tooLarge: PDFObjectError {
        .unsupported("Part of this PDF expands to more than \(maxDecodedBytes >> 20) MB when it’s decompressed, so it can’t be edited.")
    }

    /// zlib-wrapped DEFLATE, as FlateDecode stores it. Returns what could be decoded from a damaged stream; throws
    /// when the stream is unreadable or expands past `limit`.
    static func inflate(_ z: [UInt8], limit: Int = maxDecodedBytes) throws -> [UInt8] {
        guard !z.isEmpty else { return [] }
        var body = z
        if z.count >= 2, (Int(z[0]) * 256 + Int(z[1])) % 31 == 0, z[0] & 0x0F == 8 { body = Array(z.dropFirst(2)) }
        let (out, exceeded) = process(body, operation: COMPRESSION_STREAM_DECODE, limit: limit)
        if exceeded { throw tooLarge }
        guard let out else { throw PDFObjectError.unreadable("A compressed part of this PDF is damaged.") }
        return out
    }

    /// zlib wrapper (78 9C) + raw DEFLATE + Adler-32, which is what FlateDecode expects.
    static func deflate(_ d: [UInt8]) -> [UInt8] {
        let body = process(d, operation: COMPRESSION_STREAM_ENCODE, limit: Int.max).out ?? []
        let a = adler32(d)
        return [0x78, 0x9C] + body + [UInt8(a >> 24), UInt8(a >> 16 & 0xFF), UInt8(a >> 8 & 0xFF), UInt8(a & 0xFF)]
    }

    static func adler32(_ d: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, c: UInt32 = 0
        var i = 0
        while i < d.count {
            let end = min(d.count, i + 5000)
            while i < end { a += UInt32(d[i]); c += a; i += 1 }
            a %= 65521; c %= 65521
        }
        return c << 16 | a
    }

    private static func process(_ input: [UInt8], operation: compression_stream_operation, limit: Int) -> (out: [UInt8]?, exceeded: Bool) {
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: UnsafePointer(dst), src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return (nil, false) }
        defer { compression_stream_destroy(&stream) }
        // Output is collected in chunks and joined once at the end, so a stream that runs past the limit is
        // dropped before any array doubles to twice the limit.
        var chunks: [[UInt8]] = []
        var total = 0
        var failed = false
        var exceeded = false
        input.withUnsafeBufferPointer { src in
            stream.src_ptr = src.baseAddress ?? UnsafePointer(dst)
            stream.src_size = src.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = 65536
                let flags = operation == COMPRESSION_STREAM_ENCODE ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                let status = compression_stream_process(&stream, flags)
                let produced = 65536 - stream.dst_size
                if total + produced > limit { exceeded = true; break }
                if produced > 0 { chunks.append(Array(UnsafeBufferPointer(start: dst, count: produced))); total += produced }
                if status == COMPRESSION_STATUS_END { break }
                if status == COMPRESSION_STATUS_ERROR { failed = true; break }
                if stream.src_size == 0 && stream.dst_size > 0 && operation == COMPRESSION_STREAM_DECODE { break }
            }
        }
        if exceeded { return (nil, true) }
        if failed && total == 0 { return (nil, false) }
        var out: [UInt8] = []
        out.reserveCapacity(total)
        for c in chunks { out += c }
        return (out, false)
    }

    /// PNG (10…15) and TIFF (2) predictors. Throws for parameters no real stream has (a row longer than the
    /// data could ever be), which crafted files use to force a huge allocation or an arithmetic overflow.
    static func unpredict(_ d: [UInt8], parms: PDFDict?) throws -> [UInt8] {
        guard let parms, let pred = parms["Predictor"]?.int, pred >= 2 else { return d }
        let cols = max(1, parms["Columns"]?.int ?? 1), colors = max(1, parms["Colors"]?.int ?? 1)
        let bpc = max(1, parms["BitsPerComponent"]?.int ?? 8)
        let row = (min(cols, 1 << 24) * min(colors, 64) * min(bpc, 16) + 7) / 8
        guard cols <= 1 << 24, colors <= 64, [1, 2, 4, 8, 16].contains(bpc), d.isEmpty || row <= d.count else {
            throw PDFObjectError.unreadable("A compressed part of this PDF has impossible predictor settings, so it can’t be read.")
        }
        let bpp = max(1, colors * bpc / 8)
        if pred == 2 {
            guard bpc == 8 else { return d }
            var out = d
            var i = 0
            while i < out.count {
                // The last row can be short; bytes before the first whole pixel stay as they are.
                let end = min(row, out.count - i)
                if bpp < end { for k in bpp..<end { out[i + k] = out[i + k] &+ out[i + k - bpp] } }
                i += row
            }
            return out
        }
        // Each row is a filter byte and `row` bytes (the last one may be short and is padded with zeros). Rows are
        // decoded in place in one output buffer: a row of a few bytes (/Columns 1) in a 200 MB stream is 100
        // million rows, and an array per row took over half a minute.
        let rowCount = (d.count + row) / (row + 1)
        var out = [UInt8](repeating: 0, count: rowCount * row)
        out.withUnsafeMutableBufferPointer { o in
            d.withUnsafeBufferPointer { src in
                for r in 0..<rowCount {
                    let i = r * (row + 1), base = r * row
                    let type = src[i]
                    let available = min(row, src.count - i - 1)
                    for k in 0..<available { o[base + k] = src[i + 1 + k] }
                    guard (1...4).contains(type) else { continue }
                    for k in 0..<row {
                        let a = k >= bpp ? Int(o[base + k - bpp]) : 0
                        let up = r > 0 ? Int(o[base - row + k]) : 0
                        let c = k >= bpp && r > 0 ? Int(o[base - row + k - bpp]) : 0
                        var x = Int(o[base + k])
                        switch type {
                        case 1: x += a
                        case 2: x += up
                        case 3: x += (a + up) / 2
                        default:
                            let pp = a + up - c, pa = abs(pp - a), pb = abs(pp - up), pc = abs(pp - c)
                            x += (pa <= pb && pa <= pc) ? a : (pb <= pc ? up : c)
                        }
                        o[base + k] = UInt8(x & 0xFF)
                    }
                }
            }
        }
        return out
    }

    static func asciiHex(_ d: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var half: UInt8?
        for c in d {
            if c == 62 { break }
            guard let v = PDFLexer.hexValue(c) else { continue }
            if let h = half { out.append(h << 4 | v); half = nil } else { half = v }
        }
        if let h = half { out.append(h << 4) }
        return out
    }

    static func ascii85(_ d: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var group: [UInt32] = []
        var i = 0
        if d.count >= 2, d[0] == 60, d[1] == 126 { i = 2 }
        func flush(_ g: [UInt32], count: Int) {
            var v: UInt32 = 0
            for k in 0..<5 { v = v &* 85 &+ (k < g.count ? g[k] : 84) }
            let bytes = [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
            out += bytes.prefix(count)
        }
        while i < d.count {
            let c = d[i]; i += 1
            if c == 126 { break }
            if PDFLexer.isWhite(c) { continue }
            if c == 122 && group.isEmpty { out += [0, 0, 0, 0]; continue }
            guard (33...117).contains(c) else { continue }
            group.append(UInt32(c - 33))
            if group.count == 5 { flush(group, count: 4); group = [] }
        }
        if group.count > 1 { flush(group, count: group.count - 1) }
        return out
    }

    static func lzw(_ d: [UInt8], earlyChange: Int, limit: Int = maxDecodedBytes) throws -> [UInt8] {
        var out: [UInt8] = []
        var table: [[UInt8]] = (0..<256).map { [UInt8($0)] } + [[], []]
        var bits = 9
        var buffer = 0, count = 0
        var prev: [UInt8]?
        var i = 0
        while true {
            while count < bits, i < d.count { buffer = ((buffer << 8) | Int(d[i])) & 0xFFFFFF; i += 1; count += 8 }
            if count < bits { break }
            let code = (buffer >> (count - bits)) & ((1 << bits) - 1)
            count -= bits
            if code == 256 { table = (0..<256).map { [UInt8($0)] } + [[], []]; bits = 9; prev = nil; continue }
            if code == 257 { break }
            var entry: [UInt8]
            if code < table.count { entry = table[code] }
            else if let prev, code == table.count { entry = prev + [prev[0]] }
            else { break }
            if out.count + entry.count > limit { throw tooLarge }
            out += entry
            // 12-bit codes can't address more than 4096 entries: a full table stays as it is until a clear code.
            if let prev, table.count < 4096 { table.append(prev + [entry[0]]) }
            prev = entry
            let limit = (1 << bits) - earlyChange
            if table.count >= limit && bits < 12 { bits += 1 }
        }
        return out
    }

    static func runLength(_ d: [UInt8], limit: Int = maxDecodedBytes) throws -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < d.count {
            let n = Int(d[i]); i += 1
            if n == 128 { break }
            if n < 128 {
                let end = min(d.count, i + n + 1)
                out += d[i..<end]; i = end
            } else if i < d.count {
                out += [UInt8](repeating: d[i], count: 257 - n); i += 1
            }
            if out.count > limit { throw tooLarge }
        }
        return out
    }
}

// MARK: - The file

/// A parsed PDF: every cross-reference section from the newest back through /Prev, merged so the newest
/// version of each object wins, plus the trailer of the newest section.
final class PDFObjectFile {
    enum XrefKind { case table, stream }

    struct Entry {
        enum Kind { case free, offset, compressed }
        var kind: Kind
        /// Byte offset (offset) or object stream number (compressed).
        var a: Int
        /// Generation (offset) or index in the object stream (compressed).
        var b: Int
    }

    /// One object of the newest revision.
    struct Object {
        var number: Int
        var generation: Int
        var value: PDFValue
        /// Stream bytes as stored (still encoded).
        var stream: [UInt8]?
        /// "n g obj … endobj" in the file (offset objects) or the member's bytes in its object stream.
        var source: Range<Int>?
        var inObjectStream: Int?
    }

    let bytes: [UInt8]
    let data: Data
    private(set) var entries: [Int: Entry] = [:]
    /// Newest trailer (or the newest xref stream's dictionary).
    private(set) var trailer = PDFDict()
    private(set) var newestKind = XrefKind.table
    /// The offset `startxref` gives: an update's /Prev.
    private(set) var newestStart = 0
    private(set) var sectionCount = 0
    private(set) var xrefStreamObjects: Set<Int> = []
    /// The cross-reference data was damaged and was rebuilt by scanning for "n g obj".
    private(set) var rebuilt = false
    /// Object numbers listed in the newest section only (an update's own objects).
    private(set) var newestSectionObjects: Set<Int> = []

    private var cache: [Int: Object] = [:]
    private var objectStreams: [Int: (data: [UInt8], first: Int, offsets: [(number: Int, offset: Int)])] = [:]

    convenience init(url: URL) throws { try self.init(try Data(contentsOf: url)) }

    init(_ data: Data) throws {
        self.data = data
        bytes = [UInt8](data)
        guard bytes.count > 16 else { throw PDFObjectError.unreadable("The file is too short to be a PDF.") }
        do {
            try readSections()
            guard let root = trailer["Root"], resolve(root).dict != nil, damagedOffsets() == 0 else {
                throw PDFObjectError.unreadable("bad xref")
            }
        } catch {
            entries = [:]; trailer = PDFDict(); cache = [:]; objectStreams = [:]; xrefStreamObjects = []
            newestSectionObjects = []
            try rebuildByScanning()
        }
    }

    // MARK: Cross-reference sections

    private func readSections() throws {
        guard let sx = lastIndex(of: Array("startxref".utf8), within: 4096) else {
            throw PDFObjectError.unreadable("No startxref.")
        }
        var lx = PDFLexer(bytes, at: sx + 9)
        guard case .number(let d, _) = lx.next().0, d >= 0, let start = PDFNumber.int(d), start < bytes.count else {
            throw PDFObjectError.unreadable("Bad startxref.")
        }
        newestStart = start
        var next: Int? = newestStart
        var seen = Set<Int>()
        var first = true
        while let at = next, at >= 0, at < bytes.count, !seen.contains(at), seen.count < 128 {
            seen.insert(at)
            var listed = Set<Int>()
            let (kind, t) = try readSection(at, listed: &listed)
            if first {
                trailer = t; newestKind = kind; first = false
                newestSectionObjects = listed
            }
            sectionCount += 1
            next = t["Prev"]?.int
        }
        if first { throw PDFObjectError.unreadable("No cross-reference section.") }
    }

    /// Newest section wins. Within one hybrid section, the /XRefStm rows fill in what the table leaves free.
    private func set(_ n: Int, _ e: Entry, overrideFree: Bool = false) {
        if let old = entries[n] {
            if overrideFree, old.kind == .free { entries[n] = e }
            return
        }
        entries[n] = e
    }

    private func readSection(_ at: Int, listed: inout Set<Int>) throws -> (XrefKind, PDFDict) {
        var lx = PDFLexer(bytes, at: at)
        let (t, _) = lx.next()
        if case .keyword("xref") = t {
            var rows: [(Int, Entry)] = []
            while true {
                let save = lx.p
                let (a, _) = lx.next()
                guard case .number(let fs, _) = a else { lx.p = save; break }
                guard case .number(let cs, _) = lx.next().0, let firstNumber = PDFNumber.int(fs), let count = PDFNumber.int(cs),
                      firstNumber >= 0 else { throw PDFObjectError.unreadable("Bad xref subsection.") }
                guard count >= 0, count < 10_000_000 else { throw PDFObjectError.unreadable("Bad xref count.") }
                for k in 0..<count {
                    guard case .number(let o, _) = lx.next().0, case .number(let g, _) = lx.next().0,
                          case .keyword(let type) = lx.next().0, let offset = PDFNumber.int(o), let gen = PDFNumber.int(g) else {
                        throw PDFObjectError.unreadable("Bad xref row.")
                    }
                    let n = firstNumber + k
                    rows.append((n, type == "n" && offset > 0 ? Entry(kind: .offset, a: offset, b: gen) : Entry(kind: .free, a: 0, b: gen)))
                }
            }
            guard case .keyword("trailer") = lx.next().0, let tr = lx.value()?.dict else {
                throw PDFObjectError.unreadable("No trailer.")
            }
            // The /XRefStm of a hybrid section may only fill in what this same table leaves free; a free entry from a
            // newer section is a deletion and must stay deleted.
            var ownFree = Set<Int>()
            for (n, e) in rows {
                if e.kind == .free, entries[n] == nil { ownFree.insert(n) }
                set(n, e)
                if e.kind != .free { listed.insert(n) }
            }
            if let xs = tr["XRefStm"]?.int, xs > 0, xs < bytes.count {
                var hybridListed = Set<Int>()
                if let (_, _) = try? readStreamSection(xs, overrideFree: true, fillable: ownFree, listed: &hybridListed) { listed.formUnion(hybridListed) }
            }
            return (.table, tr)
        }
        return try readStreamSection(at, overrideFree: false, listed: &listed)
    }

    private func readStreamSection(_ at: Int, overrideFree: Bool, fillable: Set<Int> = [], listed: inout Set<Int>) throws -> (XrefKind, PDFDict) {
        guard let obj = parseIndirect(at: at), let d = obj.value.dict, d["Type"]?.name == "XRef", let raw = obj.stream else {
            throw PDFObjectError.unreadable("Bad xref stream.")
        }
        xrefStreamObjects.insert(obj.number)
        let rows = try decode(d, raw)
        let w = (d["W"]?.array ?? []).compactMap(\.int)
        guard w.count == 3, w.allSatisfy({ $0 >= 0 && $0 <= 8 }), w[1] + w[2] > 0 else { throw PDFObjectError.unreadable("Bad /W.") }
        let size = d["Size"]?.int ?? 0
        let index = d["Index"]?.array?.compactMap(\.int) ?? [0, size]
        let rowWidth = w[0] + w[1] + w[2]
        var p = 0
        func field(_ len: Int, _ fallback: Int) -> Int {
            if len == 0 { return fallback }
            var v = 0
            for _ in 0..<len { v = v << 8 | Int(p < rows.count ? rows[p] : 0); p += 1 }
            return v
        }
        var k = 0
        // Rows come from the stream's data: /Index can't claim more entries than the data holds (a crafted
        // /Index of millions of entries with no data would otherwise fill memory with phantom entries).
        rowLoop: while k + 1 < index.count {
            let start = index[k], count = index[k + 1]
            guard start >= 0, count >= 0, count < 10_000_000 else { break }
            for n in start..<(start + count) {
                guard p + rowWidth <= rows.count else { break rowLoop }
                let type = field(w[0], 1), f2 = field(w[1], 0), f3 = field(w[2], 0)
                // An 8-byte field with its top bit set wraps to a negative Int: no offset, object stream or index
                // can be negative, so the row is ignored (reading at a negative offset would trap).
                guard f2 >= 0, f3 >= 0 else { continue }
                switch type {
                case 0: set(n, Entry(kind: .free, a: 0, b: f3), overrideFree: overrideFree && fillable.contains(n))
                case 1: set(n, Entry(kind: .offset, a: f2, b: f3), overrideFree: overrideFree && fillable.contains(n)); listed.insert(n)
                case 2: set(n, Entry(kind: .compressed, a: f2, b: f3), overrideFree: overrideFree && fillable.contains(n)); listed.insert(n)
                default: break
                }
            }
            k += 2
        }
        return (.stream, d)
    }

    /// Offset entries that don't point at "n g obj".
    private func damagedOffsets() -> Int {
        var bad = 0
        for (n, e) in entries where e.kind == .offset {
            guard e.a >= 0, e.a < bytes.count else { bad += 1; continue }
            var lx = PDFLexer(bytes, at: e.a)
            guard case .number(let a, _) = lx.next().0, PDFNumber.int(a) == n, case .number = lx.next().0, case .keyword("obj") = lx.next().0 else {
                bad += 1; continue
            }
        }
        return bad
    }

    /// Damaged files: the last "n g obj" for each number wins; the trailer is the last one with /Root, else the
    /// catalog is found by its /Type.
    private func rebuildByScanning() throws {
        rebuilt = true
        newestKind = .table
        var i = 0
        let b = bytes
        var found: [Int: (Int, Int)] = [:]
        /// Digits ending at `end` (exclusive), after skipping whitespace backwards: (start, value).
        func digits(before end: Int) -> (start: Int, value: Int)? {
            var j = end - 1
            while j >= 0, PDFLexer.isWhite(b[j]) { j -= 1 }
            let last = j
            while j >= 0, (48...57).contains(b[j]) { j -= 1 }
            guard j < last, last - j <= 10, let v = Int(String(decoding: b[(j + 1)...last], as: UTF8.self)) else { return nil }
            return (j + 1, v)
        }
        while i + 3 <= b.count {
            // "n g obj": "obj" after whitespace, followed by whitespace or a delimiter.
            if b[i] == 111, b[i + 1] == 98, b[i + 2] == 106, i > 3, PDFLexer.isWhite(b[i - 1]),
               i + 3 >= b.count || PDFLexer.isWhite(b[i + 3]) || PDFLexer.isDelimiter(b[i + 3]),
               let gen = digits(before: i), gen.start > 0, PDFLexer.isWhite(b[gen.start - 1]),
               let num = digits(before: gen.start), num.start == 0 || PDFLexer.isWhite(b[num.start - 1]) || PDFLexer.isDelimiter(b[num.start - 1]) {
                found[num.value] = (num.start, gen.value)
            }
            i += 1
        }
        for (n, (o, g)) in found { entries[n] = Entry(kind: .offset, a: o, b: g) }
        // Object streams found by the scan contribute their members (unless a plain object of the number exists).
        for (n, _) in found {
            guard let o = object(n), o.value.dict?["Type"]?.name == "ObjStm", let box = objectStream(n) else { continue }
            for (idx, member) in box.offsets.enumerated() where entries[member.number] == nil {
                entries[member.number] = Entry(kind: .compressed, a: n, b: idx)
            }
        }
        // Trailer: the last "trailer" dictionary, or an xref stream dictionary with /Root.
        var t = PDFDict()
        if let ti = lastIndex(of: Array("trailer".utf8), within: b.count) {
            var lx = PDFLexer(b, at: ti + 7)
            if let d = lx.value()?.dict { t = d }
        }
        if t["Root"] == nil {
            for (n, _) in found.sorted(by: { $0.key > $1.key }) {
                if let d = object(n)?.value.dict, d["Type"]?.name == "XRef", d["Root"] != nil { t = d; break }
            }
        }
        if t["Root"] == nil || resolve(t["Root"]!).dict == nil {
            for (n, _) in found.sorted(by: { $0.key < $1.key }) where object(n)?.value.dict?["Type"]?.name == "Catalog" {
                t["Root"] = .ref(n, found[n]!.1); break
            }
        }
        guard t["Root"] != nil else { throw PDFObjectError.unreadable("This PDF is damaged: its page tree can’t be found.") }
        for k in ["Type", "W", "Index", "Length", "Filter", "DecodeParms", "Prev", "XRefStm"] { t[k] = nil }
        trailer = t
        newestStart = 0
        sectionCount = 0
        newestSectionObjects = []
    }

    private func lastIndex(of needle: [UInt8], within window: Int) -> Int? {
        var i = bytes.count - needle.count
        let stop = max(0, bytes.count - window)
        while i >= stop {
            if bytes[i] == needle[0] {
                var ok = true
                for k in 1..<needle.count where bytes[i + k] != needle[k] { ok = false; break }
                if ok { return i }
            }
            i -= 1
        }
        return nil
    }

    // MARK: Objects

    /// "n g obj value [stream … endstream] endobj" at an offset.
    func parseIndirect(at offset: Int) -> Object? {
        var lx = PDFLexer(bytes, at: offset)
        lx.skipWhite()
        let start = lx.p
        guard case .number(let nd, _) = lx.next().0, case .number(let gd, _) = lx.next().0, case .keyword("obj") = lx.next().0,
              let n = PDFNumber.int(nd), let g = PDFNumber.int(gd) else { return nil }
        let (vt, _) = lx.next()
        if case .keyword("endobj") = vt { return Object(number: n, generation: g, value: .null, stream: nil, source: start..<lx.p) }
        guard let value = lx.value(after: vt) else { return nil }
        var stream: [UInt8]?
        let afterValue = lx.p
        let (t, r) = lx.next()
        if case .keyword("stream") = t {
            var s = r.upperBound
            if s < bytes.count, bytes[s] == 13 { s += 1 }
            if s < bytes.count, bytes[s] == 10 { s += 1 }
            var length = -1
            if let lv = value.dict?["Length"] {
                switch lv {
                // object() refuses a number it is already reading, so /Length references that loop (4 → 6 → 4) end.
                case .ref(let ln, _): length = (ln == n ? nil : object(ln))?.value.int ?? -1
                default: length = lv.int ?? -1
                }
            }
            func endsAt(_ e: Int) -> Bool {
                guard e >= s, e <= bytes.count else { return false }
                var k = PDFLexer(bytes, at: e)
                if case .keyword(let w) = k.next().0 { return w == "endstream" || w.hasPrefix("endstream") }
                return false
            }
            if length < 0 || !endsAt(s + length) {
                // A wrong /Length is common: trust "endstream".
                guard let e = endstream(from: s) else { return nil }
                var end = e
                if end > s, bytes[end - 1] == 10 { end -= 1 }
                if end > s, bytes[end - 1] == 13 { end -= 1 }
                length = end - s
            }
            // Streams of one file can't add up to much more than the file: a crafted file of thousands of streams
            // that all run to one "endstream" near its end would copy the rest of the file once for each of them.
            guard copiedStreamBytes + length <= 3 * bytes.count + (64 << 20) else { return nil }
            copiedStreamBytes += length
            stream = Array(bytes[s..<(s + length)])
            var k = PDFLexer(bytes, at: s + length)
            _ = k.next()                                            // endstream
            lx.p = k.p
        } else {
            lx.p = afterValue
        }
        let save = lx.p
        if case .keyword("endobj") = lx.next().0 {} else { lx.p = save }
        return Object(number: n, generation: g, value: value, stream: stream, source: start..<lx.p)
    }

    /// Where each "endstream" begins, found once: a file of many streams without a usable /Length would otherwise
    /// search the rest of the file once per stream (quadratic in the file size).
    private lazy var endstreamPositions: [Int] = {
        let needle = Array("endstream".utf8)
        var out: [Int] = []
        var i = 0
        while i + needle.count <= bytes.count {
            if bytes[i] == needle[0] {
                var ok = true
                for k in 1..<needle.count where bytes[i + k] != needle[k] { ok = false; break }
                if ok { out.append(i); i += needle.count; continue }
            }
            i += 1
        }
        return out
    }()

    /// Raw stream bytes `parseIndirect` has copied out of the file (bounded, see there).
    private(set) var copiedStreamBytes = 0

    /// The first "endstream" at or after `from`.
    private func endstream(from: Int) -> Int? {
        let p = endstreamPositions
        var lo = 0, hi = p.count
        while lo < hi { let mid = (lo + hi) / 2; if p[mid] < from { lo = mid + 1 } else { hi = mid } }
        return lo < p.count ? p[lo] : nil
    }

    func entry(_ n: Int) -> Entry? { entries[n] }
    var objectNumbers: [Int] { entries.filter { $0.value.kind != .free }.keys.sorted() }

    /// Objects being read right now. Reading one can need another (an indirect /Length, the object stream that
    /// holds it); a crafted file can make those needs loop, and each lap would recurse until the stack overflows.
    private var reading = Set<Int>()

    /// The newest version of an object.
    func object(_ n: Int) -> Object? {
        if let c = cache[n] { return c }
        guard let e = entries[n], reading.count < 64, reading.insert(n).inserted else { return nil }
        defer { reading.remove(n) }
        var result: Object?
        switch e.kind {
        case .offset:
            guard e.a >= 0, e.a < bytes.count, let o = parseIndirect(at: e.a), o.number == n else { return nil }
            result = o
        case .compressed:
            guard e.a != n, e.b >= 0, let box = objectStream(e.a), e.b < box.offsets.count else { return nil }
            let start = box.first + box.offsets[e.b].offset
            guard start < box.data.count else { return nil }
            let end = e.b + 1 < box.offsets.count ? min(box.data.count, box.first + box.offsets[e.b + 1].offset) : box.data.count
            var lx = PDFLexer(box.data, at: start)
            guard let v = lx.value() else { return nil }
            result = Object(number: n, generation: 0, value: v, stream: nil, source: start..<max(start, end), inObjectStream: e.a)
        case .free:
            return nil
        }
        if let result { cache[n] = result }
        return result
    }

    func objectStream(_ n: Int) -> (data: [UInt8], first: Int, offsets: [(number: Int, offset: Int)])? {
        if let c = objectStreams[n] { return c }
        guard let o = object(n), let d = o.value.dict, let raw = o.stream, let data = try? decode(d, raw) else { return nil }
        let count = d["N"]?.int ?? 0, first = d["First"]?.int ?? 0
        guard first >= 0, first <= data.count else { return nil }
        var lx = PDFLexer(data, at: 0)
        var offsets: [(Int, Int)] = []
        for _ in 0..<max(0, min(count, 1_000_000)) {
            guard case .number(let a, _) = lx.next().0, case .number(let b, _) = lx.next().0,
                  let number = PDFNumber.int(a), let offset = PDFNumber.int(b), offset >= 0 else { break }
            offsets.append((number, offset))
        }
        objectStreams[n] = (data, first, offsets.map { (number: $0.0, offset: $0.1) })
        return objectStreams[n]
    }

    /// The member bytes of an object stream member, for verbatim copies.
    func memberBytes(_ n: Int) -> [UInt8]? {
        guard let o = object(n), let s = o.inObjectStream, let box = objectStream(s), let r = o.source else { return nil }
        return Array(box.data[r])
    }

    func resolve(_ v: PDFValue) -> PDFValue {
        var v = v
        var hops = 0
        while case .ref(let n, _) = v, hops < 32 { v = object(n)?.value ?? .null; hops += 1 }
        return v
    }

    func resolve(_ v: PDFValue?) -> PDFValue? { v.map { resolve($0) } }

    func generation(_ n: Int) -> Int {
        if let e = entries[n], e.kind == .offset { return e.b }
        return 0
    }

    var maxObjectNumber: Int { max(entries.keys.max() ?? 0, (trailer["Size"]?.int ?? 1) - 1) }

    /// The filters of a stream dictionary, with their parameters.
    func filters(_ dict: PDFDict) -> [(name: String, parms: PDFDict?)] {
        var names: [String] = []
        switch resolve(dict["Filter"]) {
        case .name(let n)?: names = [n]
        case .array(let a)?: names = a.compactMap { resolve($0).name }
        default: break
        }
        var parms: [PDFDict?] = []
        switch resolve(dict["DecodeParms"] ?? dict["DP"]) {
        case .dict(let d)?: parms = [d]
        case .array(let a)?: parms = a.map { resolve($0).dict }
        default: break
        }
        return names.enumerated().map { ($0.element, $0.offset < parms.count ? parms[$0.offset] : nil) }
    }

    /// Decoded stream data. Image-only filters (DCT, JPX, JBIG2, CCITT) and encryption are refused.
    func decode(_ dict: PDFDict, _ raw: [UInt8]) throws -> [UInt8] {
        var d = raw
        // Every filter is bounded by the same limit, so chained filters can't multiply into a bomb either.
        let chain = filters(dict)
        guard chain.count <= 8 else { throw PDFObjectError.unsupported("Part of this PDF is encoded too many times over, so it can’t be edited.") }
        for (name, parms) in chain {
            switch name {
            case "FlateDecode", "Fl":
                d = try PDFFilters.unpredict(try PDFFilters.inflate(d), parms: parms)
            case "LZWDecode", "LZW":
                let early = PDFNumber.int(Double(parms?["EarlyChange"]?.int ?? 1), clampedTo: 0...1)
                d = try PDFFilters.unpredict(try PDFFilters.lzw(d, earlyChange: early), parms: parms)
            case "ASCIIHexDecode", "AHx": d = PDFFilters.asciiHex(d)
            case "ASCII85Decode", "A85": d = PDFFilters.ascii85(d)
            case "RunLengthDecode", "RL": d = try PDFFilters.runLength(d)
            default:
                throw PDFObjectError.unsupported("Part of this page is stored with \(name), which can’t be edited.")
            }
            if d.count > PDFFilters.maxDecodedBytes { throw PDFFilters.tooLarge }
        }
        return d
    }

    /// Decoded streams are kept (a form drawn on every page is decoded once) within one budget for the whole
    /// file, so a document of many pages that each expand to just under the per-stream limit can't fill memory
    /// as its pages are read.
    static var maxTotalDecodedBytes = 1 << 30
    private var decodedCache: [Int: [UInt8]] = [:]
    private(set) var decodedTotal = 0

    func decodedStream(_ n: Int) throws -> [UInt8]? {
        if let c = decodedCache[n] { return c }
        guard let o = object(n), let d = o.value.dict, let raw = o.stream else { return nil }
        let data = try decode(d, raw)
        guard decodedTotal + data.count <= PDFObjectFile.maxTotalDecodedBytes else {
            throw PDFObjectError.unsupported("This PDF expands to more than \(PDFObjectFile.maxTotalDecodedBytes >> 20) MB when it’s decompressed, so the rest of it can’t be edited.")
        }
        decodedTotal += data.count
        decodedCache[n] = data
        return data
    }

    // MARK: Document

    var catalog: PDFDict? { trailer["Root"].flatMap { resolve($0).dict } }

    /// An /Encrypt dictionary: strings and streams would need the file key.
    var isEncrypted: Bool { trailer["Encrypt"] != nil && !(trailer["Encrypt"]!.isNull) }

    struct Signatures {
        var signed = false
        /// A certification signature that allows no changes (DocMDP P = 1).
        var noChangesAllowed = false
    }

    /// Signature fields with a value, /Perms, or SigFlags bit 1.
    var signatures: Signatures {
        var s = Signatures()
        guard let cat = catalog else { return s }
        if let perms = resolve(cat["Perms"])?.dict, !perms.isEmpty {
            s.signed = true
            if let mdp = resolve(perms["DocMDP"])?.dict {
                for r in resolve(mdp["Reference"])?.array ?? [] {
                    guard let ref = resolve(r).dict, ref["TransformMethod"]?.name == "DocMDP" else { continue }
                    let p = resolve(ref["TransformParams"])?.dict?["P"]?.int ?? 2
                    if p == 1 { s.noChangesAllowed = true }
                }
            }
        }
        if let form = resolve(cat["AcroForm"])?.dict {
            if let flags = resolve(form["SigFlags"])?.int, flags & 1 != 0 { s.signed = true }
            var seen = Set<Int>()
            func walk(_ v: PDFValue, depth: Int) {
                guard depth < 32 else { return }
                if let r = v.ref { guard seen.insert(r.number).inserted else { return } }
                guard let f = resolve(v).dict else { return }
                if f["FT"]?.name == "Sig", let sv = f["V"], !resolve(sv).isNull { s.signed = true }
                for k in resolve(f["Kids"])?.array ?? [] { walk(k, depth: depth + 1) }
            }
            for f in resolve(form["Fields"])?.array ?? [] { walk(f, depth: 0) }
        }
        return s
    }

    // MARK: Page tree

    /// Where a page's /Resources dictionary lives.
    enum ResourcesHome {
        /// Inline in the page dictionary.
        case pageInline
        /// Its own object, referenced from the page.
        case object(Int)
        /// Inherited from a Pages node (inline there or its own object).
        case inherited(node: Int, object: Int?)
        /// No resources at all.
        case none
    }

    struct Page {
        let index: Int
        let number: Int
        let generation: Int
        let dict: PDFDict
        let resources: PDFDict
        let resourcesHome: ResourcesHome
        let mediaBox: CGRect
        let cropBox: CGRect
        let rotate: Int
        /// Content stream object numbers, in order.
        let contents: [Int]
        /// /Contents is a reference to an array object.
        let contentsArrayObject: Int?
    }

    private var pageCache: [Page]?

    func pages() -> [Page] {
        if let pageCache { return pageCache }
        var out: [Page] = []
        guard let cat = catalog, let top = cat["Pages"] else { pageCache = []; return [] }
        var seen = Set<Int>()
        struct Inherit { var resources: PDFValue?; var resNode: Int?; var media: PDFValue?; var crop: PDFValue?; var rotate: PDFValue? }
        func rect(_ v: PDFValue?) -> CGRect? {
            guard let a = v.flatMap({ resolve($0).array })?.compactMap({ resolve($0).double }), a.count == 4 else { return nil }
            return CGRect(x: min(a[0], a[2]), y: min(a[1], a[3]), width: abs(a[2] - a[0]), height: abs(a[3] - a[1]))
        }
        func walk(_ ref: PDFValue, _ inh: Inherit, depth: Int) {
            guard depth < 64, let (n, _) = ref.ref, seen.insert(n).inserted, let d = object(n)?.value.dict else { return }
            var inh = inh
            if let r = d["Resources"] { inh.resources = r; inh.resNode = n }
            if let m = d["MediaBox"] { inh.media = m }
            if let c = d["CropBox"] { inh.crop = c }
            if let r = d["Rotate"] { inh.rotate = r }
            let kids = resolve(d["Kids"])?.array
            if d["Type"]?.name == "Pages" || (kids != nil && d["Type"]?.name != "Page") {
                for k in kids ?? [] { walk(k, inh, depth: depth + 1) }
                return
            }
            let resources = inh.resources.flatMap { resolve($0).dict } ?? PDFDict()
            var home = ResourcesHome.none
            if let r = d["Resources"] { home = r.ref.map { .object($0.number) } ?? .pageInline }
            else if let rv = inh.resources, let node = inh.resNode { home = .inherited(node: node, object: rv.ref?.number) }
            let media = rect(inh.media) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
            let crop = rect(inh.crop)?.intersection(media) ?? media
            var contents: [Int] = []
            var arrayObject: Int?
            if let c = d["Contents"] {
                switch c {
                case .ref(let cn, _):
                    if let arr = object(cn)?.value.array { arrayObject = cn; contents = arr.compactMap { $0.ref?.number } }
                    else { contents = [cn] }
                case .array(let a): contents = a.compactMap { $0.ref?.number }
                default: break
                }
            }
            let rot = ((inh.rotate.flatMap { resolve($0).int } ?? 0) % 360 + 360) % 360
            out.append(Page(index: out.count, number: n, generation: generation(n), dict: d, resources: resources, resourcesHome: home,
                            mediaBox: media, cropBox: crop.isEmpty ? media : crop, rotate: rot - rot % 90, contents: contents,
                            contentsArrayObject: arrayObject))
        }
        walk(top, Inherit(), depth: 0)
        pageCache = out
        return out
    }
}
