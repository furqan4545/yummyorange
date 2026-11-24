import Foundation
import Compression

// Minimal ZIP support for the formats that are ZIP packages: DOCX, XLSX, PPTX, ODT, ODS, EPUB and
// single-file Pages documents. Reads stored and deflated entries (ZIP64 sizes and offsets included);
// writes stored and deflated entries. No encryption, no multi-disk archives.
//
// The reader treats every byte of the file as untrusted: each offset and length is checked against the
// file before it is used, 64-bit values that don't fit an Int are refused, and an entry is inflated into a
// buffer that grows with the real output, never to the size the directory claims. An entry is refused when
// it claims more than DEFLATE can produce from its data, more than `maxEntryBytes`, or when the real output
// differs from the declared size.

enum ZipError: LocalizedError {
    case notZip, corrupt(String), unsupported(String), missing(String)
    var errorDescription: String? {
        switch self {
        case .notZip: return "This isn’t a ZIP-based file."
        case .corrupt(let what): return "The file is damaged (\(what))."
        case .unsupported(let what): return "Unsupported ZIP feature: \(what)."
        case .missing(let name): return "The package has no \(name)."
        }
    }
}

struct ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let flags: UInt16
        let crc32: UInt32
        /// Sizes and offset as the central directory declares them. A 64-bit value too large for an Int is
        /// kept as Int.max, so reading that entry fails cleanly while the rest of the archive stays usable.
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
        /// The name exactly as stored, and the "version made by" field (high byte: 0 MS-DOS, 3 Unix, 19 macOS…).
        var rawName: [UInt8] = []
        var versionMadeBy: UInt16 = 0
        var isDirectory: Bool { name.hasSuffix("/") }
        /// General-purpose bit 0 (traditional PKWARE or AES encryption).
        var isEncrypted: Bool { flags & 0x0001 != 0 }
        /// General-purpose bit 11: the writer says the name is UTF-8.
        var hasUTF8Flag: Bool { flags & 0x0800 != 0 }
        /// No UTF-8 flag and a name that isn't valid UTF-8: a legacy code page (CP437 by the spec).
        var hasLegacyName: Bool { !hasUTF8Flag && String(bytes: rawName, encoding: .utf8) == nil }
    }

    /// The most one entry may unpack to.
    static let maxEntryBytes = 1 << 30
    /// The most `extractAll` writes in total.
    static let maxExtractBytes = 4 << 30
    /// The largest central directory `directory(of:)` reads from a file.
    static let maxDirectoryBytes = 256 << 20

    let entries: [Entry]
    private let bytes: [UInt8]
    private let index: [String: Int]

    static func isZip(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 4)) ?? Data()
        return head.count == 4 && head.starts(with: [0x50, 0x4B, 0x03, 0x04])
    }

    init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        let b = [UInt8](data)
        bytes = b
        let read: (Int, Int) throws -> [UInt8] = { offset, count in
            guard offset >= 0, count >= 0, offset <= b.count - count else { throw ZipError.corrupt("central directory") }
            return Array(b[offset..<(offset + count)])
        }
        let layout = try Self.locate(size: b.count, read: read)
        let list = try Self.parseDirectory(try read(layout.offset, layout.size), count: layout.count)
        entries = list
        var idx: [String: Int] = [:]
        for (n, entry) in list.enumerated() where idx[entry.name] == nil { idx[entry.name] = n }
        index = idx
    }

    /// The entries of a ZIP file read from its central directory alone, without loading the file: for
    /// looking inside archives of any size (names, flags, sizes). Throws like `init(url:)`.
    static func directory(of url: URL) throws -> [Entry] {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        guard let size = Int(exactly: try h.seekToEnd()) else { throw ZipError.unsupported("files this large") }
        let read: (Int, Int) throws -> [UInt8] = { offset, count in
            guard offset >= 0, count >= 0, offset <= size - count else { throw ZipError.corrupt("central directory") }
            guard count <= maxDirectoryBytes else { throw ZipError.unsupported("a central directory over 256 MB") }
            if count == 0 { return [] }
            try h.seek(toOffset: UInt64(offset))
            let d = try h.read(upToCount: count) ?? Data()
            guard d.count == count else { throw ZipError.corrupt("central directory") }
            return [UInt8](d)
        }
        let layout = try locate(size: size, read: read)
        return try parseDirectory(try read(layout.offset, layout.size), count: layout.count)
    }

    // MARK: Directory parsing

    /// Finds the central directory from the end-of-central-directory record (and its ZIP64 version).
    /// `read(offset, count)` returns exactly `count` bytes or throws.
    private static func locate(size: Int, read: (Int, Int) throws -> [UInt8]) throws -> (count: Int, offset: Int, size: Int) {
        guard size >= 22 else { throw ZipError.notZip }
        // End of central directory: last occurrence of PK\5\6 within the final 64 KiB + 22 bytes.
        let tailLength = min(size, 22 + 0xFFFF)
        let tailStart = size - tailLength
        let tail = try read(tailStart, tailLength)
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 0x05, tail[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }

        var count = Int(u16(tail, eocd + 10))
        var cdSize = Int(u32(tail, eocd + 12))
        var cdOffset = Int(u32(tail, eocd + 16))
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            // ZIP64: the locator sits right before the classic record.
            let loc = tailStart + eocd - 20
            let locator = loc >= 0 ? try read(loc, 20) : []
            if locator.count == 20, u32(locator, 0) == 0x0706_4B50 {
                guard let z = Int(exactly: u64(locator, 8)), z >= 0, z <= size - 56 else { throw ZipError.corrupt("ZIP64 record") }
                let record = try read(z, 56)
                guard u32(record, 0) == 0x0606_4B50,
                      let c = Int(exactly: u64(record, 32)), let s = Int(exactly: u64(record, 40)),
                      let o = Int(exactly: u64(record, 48)) else { throw ZipError.corrupt("ZIP64 record") }
                count = c; cdSize = s; cdOffset = o
            } else if cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
                throw ZipError.corrupt("ZIP64 locator")
            }   // else: exactly 65,535 entries written without ZIP64
        }
        guard count >= 0, cdOffset >= 0, cdSize >= 0, cdOffset <= size, cdSize <= size - cdOffset else {
            throw ZipError.corrupt("central directory")
        }
        return (count, cdOffset, cdSize)
    }

    /// Every file header in the central directory `cd`. Fewer than `count` headers means it is damaged;
    /// more is accepted (old writers wrap the 16-bit count past 65,535 entries).
    private static func parseDirectory(_ cd: [UInt8], count: Int) throws -> [Entry] {
        var list: [Entry] = []
        list.reserveCapacity(min(count, cd.count / 46))
        var p = 0
        while p <= cd.count - 46, u32(cd, p) == 0x0201_4B50 {
            let madeBy = u16(cd, p + 4)
            let flags = u16(cd, p + 8)
            let method = u16(cd, p + 10)
            let crc = u32(cd, p + 16)
            let csize32 = u32(cd, p + 20), usize32 = u32(cd, p + 24), offset32 = u32(cd, p + 42)
            let nameLen = Int(u16(cd, p + 28)), extraLen = Int(u16(cd, p + 30)), commentLen = Int(u16(cd, p + 32))
            let end = p + 46 + nameLen + extraLen + commentLen
            guard end <= cd.count else { throw ZipError.corrupt("directory entry") }
            let rawName = Array(cd[(p + 46)..<(p + 46 + nameLen)])
            let name = decodeName(rawName)

            // ZIP64 extra field (0x0001) holds the real values of any field stored as 0xFFFFFFFF, in this order.
            var usize = UInt64(usize32), csize = UInt64(csize32), offset = UInt64(offset32)
            var e = p + 46 + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let tag = u16(cd, e), len = Int(u16(cd, e + 2))
                let fieldEnd = min(e + 4 + len, extraEnd)   // a field claiming more than the extra area is cut off
                if tag == 0x0001 {
                    var q = e + 4
                    for need in [usize32, csize32, offset32].enumerated() where need.element == 0xFFFF_FFFF {
                        guard q + 8 <= fieldEnd else { throw ZipError.corrupt("ZIP64 sizes of \(name)") }
                        let value = u64(cd, q)
                        switch need.offset { case 0: usize = value; case 1: csize = value; default: offset = value }
                        q += 8
                    }
                    break
                }
                e += 4 + len
            }
            list.append(Entry(name: name, method: method, flags: flags, crc32: crc,
                              compressedSize: Int(clamping: csize), size: Int(clamping: usize),
                              localHeaderOffset: Int(clamping: offset), rawName: rawName, versionMadeBy: madeBy))
            p = end
        }
        guard list.count >= count else { throw ZipError.corrupt("directory entry") }
        return list
    }

    private static let cp437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))

    /// UTF-8 when the bytes are valid UTF-8 (flagged or not: many writers leave bit 11 unset), else the
    /// ZIP spec's default code page, CP437.
    static func decodeName(_ raw: [UInt8]) -> String {
        if let s = String(bytes: raw, encoding: .utf8) { return s }
        return String(bytes: raw, encoding: cp437) ?? String(bytes: raw, encoding: .isoLatin1) ?? String(decoding: raw, as: UTF8.self)
    }

    // MARK: Reading

    var names: [String] { entries.map(\.name) }

    /// Exact name first, then a case-insensitive match (some writers vary the case of part names).
    func entry(_ name: String) -> Entry? {
        let clean = name.hasPrefix("/") ? String(name.dropFirst()) : name
        if let i = index[clean] { return entries[i] }
        let lower = clean.lowercased()
        return entries.first { $0.name.lowercased() == lower }
    }

    func contains(_ name: String) -> Bool { entry(name) != nil }

    func read(_ name: String) throws -> Data {
        guard let e = entry(name) else { throw ZipError.missing(name) }
        return try read(e)
    }

    func readString(_ name: String) throws -> String {
        let data = try read(name)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    func read(_ e: Entry) throws -> Data {
        if e.flags & 1 != 0 { throw ZipError.unsupported("encrypted entries") }
        let total = bytes.count
        let h = e.localHeaderOffset
        guard h >= 0, total >= 30, h <= total - 30, Self.u32(bytes, h) == 0x0403_4B50 else {
            throw ZipError.corrupt("local header of \(e.name)")
        }
        let start = h + 30 + Int(Self.u16(bytes, h + 26)) + Int(Self.u16(bytes, h + 28))
        guard start <= total, e.compressedSize >= 0, e.compressedSize <= total - start, e.size >= 0 else {
            throw ZipError.corrupt("data of \(e.name)")
        }
        switch e.method {
        case 0:
            guard e.size == e.compressedSize else { throw ZipError.corrupt("size of \(e.name)") }
            guard e.size <= Self.maxEntryBytes else { throw Self.tooLarge(e) }
            return Data(bytes[start..<(start + e.compressedSize)])
        case 8:
            if e.size == 0 { return Data() }
            // DEFLATE expands at most 1032:1; a claim beyond that (plus slack for tiny streams) is a lie.
            let (product, overflow) = e.compressedSize.multipliedReportingOverflow(by: 1032)
            guard !overflow, e.size <= product + 4096 else { throw ZipError.corrupt("size of \(e.name)") }
            guard e.size <= Self.maxEntryBytes else { throw Self.tooLarge(e) }
            return try bytes.withUnsafeBufferPointer { src in
                try Self.inflate(UnsafeBufferPointer(rebasing: src[start..<(start + e.compressedSize)]),
                                 expected: e.size, name: e.name)
            }
        default:
            throw ZipError.unsupported("compression method \(e.method) in \(e.name)")
        }
    }

    private static func tooLarge(_ e: Entry) -> ZipError {
        .unsupported("\(e.name) unpacks to more than \(maxEntryBytes >> 30) GB")
    }

    /// Raw DEFLATE into a buffer that grows with the real output and stops as soon as it passes `expected`.
    private static func inflate(_ src: UnsafeBufferPointer<UInt8>, expected: Int, name: String) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.unsupported("DEFLATE decoder unavailable")
        }
        defer { compression_stream_destroy(stream) }
        guard let base = src.baseAddress, !src.isEmpty else { throw ZipError.corrupt("deflate stream of \(name)") }

        let chunk = 1 << 18
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var out = Data()
        out.reserveCapacity(min(expected, 1 << 22))
        stream.pointee.src_ptr = base
        stream.pointee.src_size = src.count
        while true {
            let before = stream.pointee.src_size
            stream.pointee.dst_ptr = buffer
            stream.pointee.dst_size = chunk
            let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            guard status != COMPRESSION_STATUS_ERROR else { throw ZipError.corrupt("deflate stream of \(name)") }
            let produced = chunk - stream.pointee.dst_size
            if produced > 0 {
                guard produced <= expected - out.count else { throw ZipError.corrupt("size of \(name)") }
                out.append(buffer, count: produced)
            }
            if status == COMPRESSION_STATUS_END { break }
            // Still OK but no output room was used up and no input taken: the stream ends too soon.
            if produced < chunk && (stream.pointee.src_size == 0 || stream.pointee.src_size == before) {
                throw ZipError.corrupt("deflate stream of \(name)")
            }
        }
        guard out.count == expected else { throw ZipError.corrupt("size of \(name)") }
        return out
    }

    /// Writes every entry under `dir`, refusing names that would escape it and archives that would unpack
    /// to more than `maxExtractBytes`.
    func extractAll(to dir: URL) throws {
        let fm = FileManager.default
        let root = dir.standardizedFileURL.path
        var total = 0
        for e in entries where !e.isDirectory {
            let (sum, overflow) = total.addingReportingOverflow(max(0, e.size))
            guard !overflow, sum <= Self.maxExtractBytes else {
                throw ZipError.unsupported("packages that unpack to more than \(Self.maxExtractBytes >> 30) GB")
            }
            total = sum
        }
        for e in entries {
            let target = dir.appendingPathComponent(e.name).standardizedFileURL
            guard target.path == root || target.path.hasPrefix(root + "/") else { throw ZipError.corrupt("unsafe path \(e.name)") }
            if e.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try read(e).write(to: target)
            }
        }
    }

    // Little-endian readers. Callers check `i` against the array first.
    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    static func u64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(u32(b, i)) | UInt64(u32(b, i + 4)) << 32 }
}

final class ZipWriter {
    private var body = Data()
    private var directory = Data()
    private var count = 0
    private var names = Set<String>()
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(date: Date = Date()) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max((c.year ?? 1980) - 1980, 0), 127)   // DOS dates cover 1980–2107
        dosTime = UInt16(truncatingIfNeeded: (c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        dosDate = UInt16(truncatingIfNeeded: year << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
    }

    /// Adds a file. `compress: false` stores it (required for an EPUB's or OpenDocument's `mimetype`).
    func add(_ name: String, data: Data, compress: Bool = true) throws {
        guard !names.contains(name) else { throw ZipError.corrupt("duplicate entry \(name)") }
        guard data.count < 0xFFFF_FFFF, body.count < 0xFFFF_FFFF else { throw ZipError.unsupported("entries over 4 GB") }
        let nameData = Data(name.utf8)
        guard nameData.count <= 0xFFFF else { throw ZipError.unsupported("names over 64 KB") }
        let crc = CRC32.checksum(data)
        var method: UInt16 = 0
        var payload = data
        if compress, data.count > 64, let deflated = Self.deflate(data), deflated.count < data.count {
            method = 8
            payload = deflated
        }
        // The whole archive must stay addressable with 32-bit offsets (no ZIP64 writing).
        guard body.count + 30 + nameData.count + payload.count < 0xFFFF_FFFF else { throw ZipError.unsupported("archives over 4 GB") }
        names.insert(name)
        let offset = UInt32(body.count)

        var local = Data()
        local.le32(0x0403_4B50); local.le16(20); local.le16(0x0800); local.le16(method)
        local.le16(dosTime); local.le16(dosDate); local.le32(crc)
        local.le32(UInt32(payload.count)); local.le32(UInt32(data.count))
        local.le16(UInt16(nameData.count)); local.le16(0)
        body.append(local); body.append(nameData); body.append(payload)

        var central = Data()
        central.le32(0x0201_4B50); central.le16(0x0314); central.le16(20); central.le16(0x0800); central.le16(method)
        central.le16(dosTime); central.le16(dosDate); central.le32(crc)
        central.le32(UInt32(payload.count)); central.le32(UInt32(data.count))
        central.le16(UInt16(nameData.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
        central.le32(name.hasSuffix("/") ? 0o040755 << 16 : 0o100644 << 16)
        central.le32(offset)
        directory.append(central); directory.append(nameData)
        count += 1
    }

    func add(_ name: String, string: String, compress: Bool = true) throws {
        try add(name, data: Data(string.utf8), compress: compress)
    }

    func finish() -> Data {
        var out = body
        let cdOffset = UInt32(clamping: out.count)
        out.append(directory)
        var end = Data()
        end.le32(0x0605_4B50); end.le16(0); end.le16(0)
        end.le16(UInt16(min(count, 0xFFFF))); end.le16(UInt16(min(count, 0xFFFF)))
        end.le32(UInt32(clamping: directory.count)); end.le32(cdOffset); end.le16(0)
        out.append(end)
        return out
    }

    func write(to url: URL) throws { try finish().write(to: url, options: .atomic) }

    /// Zips the contents of `dir` (paths relative to it). Names in `storedFirst` go first, uncompressed.
    static func zipDirectory(_ dir: URL, to url: URL, storedFirst: [String] = []) throws {
        let w = ZipWriter()
        let fm = FileManager.default
        for name in storedFirst {
            try w.add(name, data: try Data(contentsOf: dir.appendingPathComponent(name)), compress: false)
        }
        let base = dir.standardizedFileURL.path
        var files: [String] = []
        if let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let file as URL in walker {
                if (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
                if file.lastPathComponent == ".DS_Store" { continue }
                let rel = String(file.standardizedFileURL.path.dropFirst(base.count + 1))
                if !storedFirst.contains(rel) { files.append(rel) }
            }
        }
        for rel in files.sorted() { try w.add(rel, data: try Data(contentsOf: dir.appendingPathComponent(rel))) }
        try w.write(to: url)
    }

    /// Raw DEFLATE (Apple's COMPRESSION_ZLIB has no zlib header, which is what ZIP wants).
    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 8 + 1024
        var out = [UInt8](repeating: 0, count: capacity)
        let n = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            out.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(dst.baseAddress!, capacity, src.bindMemory(to: UInt8.self).baseAddress!,
                                          data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n > 0 ? Data(out[0..<n]) : nil
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for byte in buf { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { le16(UInt16(v & 0xFFFF)); le16(UInt16(v >> 16)) }
}
