import Foundation

/// A protocol-buffer message read straight from the wire format, without a schema. iWork objects are
/// protobufs; we only need a handful of their fields, so they are looked up by number on demand.
struct PagesProto {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(Range<Int>)
    }

    let storage: [UInt8]
    let range: Range<Int>
    private(set) var fields: [(number: Int, value: Value)] = []

    init(_ storage: [UInt8], range: Range<Int>? = nil) throws {
        self.storage = storage
        self.range = range ?? 0..<storage.count
        var p = self.range.lowerBound
        let end = self.range.upperBound
        while p < end {
            let key = try Self.varint(storage, &p, end)
            let number = Int(key >> 3)
            guard number > 0 else { throw Snappy.Failure.corrupt("field number") }
            switch key & 7 {
            case 0: fields.append((number, .varint(try Self.varint(storage, &p, end))))
            case 1:
                guard p + 8 <= end else { throw Snappy.Failure.corrupt("fixed64") }
                var v: UInt64 = 0
                for i in 0..<8 { v |= UInt64(storage[p + i]) << (8 * UInt64(i)) }
                p += 8
                fields.append((number, .fixed64(v)))
            case 2:
                let n = try Self.varint(storage, &p, end)
                guard n <= UInt64(end - p) else { throw Snappy.Failure.corrupt("length-delimited field") }
                fields.append((number, .bytes(p..<(p + Int(n)))))
                p += Int(n)
            case 5:
                guard p + 4 <= end else { throw Snappy.Failure.corrupt("fixed32") }
                let v = UInt32(storage[p]) | UInt32(storage[p + 1]) << 8 | UInt32(storage[p + 2]) << 16 | UInt32(storage[p + 3]) << 24
                p += 4
                fields.append((number, .fixed32(v)))
            default:
                // Groups (3, 4) are long deprecated and never used by iWork.
                throw Snappy.Failure.corrupt("wire type \(key & 7)")
            }
        }
    }

    static func varint(_ b: [UInt8], _ p: inout Int, _ end: Int) throws -> UInt64 {
        var v: UInt64 = 0, shift: UInt64 = 0
        while true {
            guard p < end, shift < 64 else { throw Snappy.Failure.corrupt("varint") }
            let c = b[p]; p += 1
            v |= UInt64(c & 0x7F) << shift
            if c < 0x80 { return v }
            shift += 7
        }
    }

    // MARK: Lookups

    func values(_ n: Int) -> [Value] { fields.filter { $0.number == n }.map(\.value) }
    func has(_ n: Int) -> Bool { fields.contains { $0.number == n } }

    func uint(_ n: Int) -> UInt64? {
        for f in fields where f.number == n {
            switch f.value {
            case .varint(let v), .fixed64(let v): return v
            case .fixed32(let v): return UInt64(v)
            case .bytes: continue
            }
        }
        return nil
    }

    func bool(_ n: Int) -> Bool? { uint(n).map { $0 != 0 } }

    func float(_ n: Int) -> Double? {
        for f in fields where f.number == n {
            switch f.value {
            case .fixed32(let v): return Double(Float(bitPattern: v))
            case .fixed64(let v): return Double(bitPattern: v)
            default: continue
            }
        }
        return nil
    }

    func bytes(_ n: Int) -> [Range<Int>] {
        values(n).compactMap { if case .bytes(let r) = $0 { return r } else { return nil } }
    }

    func string(_ n: Int) -> String? { strings(n).first }

    func strings(_ n: Int) -> [String] {
        bytes(n).map { String(decoding: storage[$0], as: UTF8.self) }
    }

    func message(_ n: Int) -> PagesProto? { messages(n).first }

    func messages(_ n: Int) -> [PagesProto] {
        bytes(n).compactMap { try? PagesProto(storage, range: $0) }
    }

    /// A `TSP.Reference` field: a message whose field 1 is an object identifier.
    func ref(_ n: Int) -> UInt64? { message(n)?.uint(1) }
    func refs(_ n: Int) -> [UInt64] { messages(n).compactMap { $0.uint(1) } }

    /// A repeated integer field, packed or not.
    func uints(_ n: Int) -> [UInt64] {
        var out: [UInt64] = []
        for v in values(n) {
            switch v {
            case .varint(let x), .fixed64(let x): out.append(x)
            case .fixed32(let x): out.append(UInt64(x))
            case .bytes(let r):
                var p = r.lowerBound
                while p < r.upperBound, let x = try? Self.varint(storage, &p, r.upperBound) { out.append(x) }
            }
        }
        return out
    }
}

/// One object of an iWork archive: an identifier and its typed messages (the first is the object itself).
struct PagesObject {
    let id: UInt64
    let type: UInt32
    let message: PagesProto
    var extra: [(type: UInt32, message: PagesProto)] = []
}

/// The `.iwa` container: chunks of a 1-byte type (0), a 3-byte little-endian length and a raw Snappy
/// block. The decompressed stream is a run of `ArchiveInfo` records (varint length + message), each
/// followed by the payloads its `MessageInfo`s describe.
enum PagesIWA {
    static func decompress(_ data: [UInt8]) throws -> [UInt8] {
        var out = [UInt8]()
        var p = 0
        try data.withUnsafeBufferPointer { buf in
            while p < data.count {
                guard p + 4 <= data.count else { throw Snappy.Failure.corrupt("chunk header") }
                let kind = data[p]
                let length = Int(data[p + 1]) | Int(data[p + 2]) << 8 | Int(data[p + 3]) << 16
                p += 4
                guard p + length <= data.count else { throw Snappy.Failure.corrupt("chunk length") }
                switch kind {
                case 0: out.append(contentsOf: try Snappy.decompress(buf[p..<(p + length)]))
                case 1: out.append(contentsOf: data[p..<(p + length)])   // stored, never seen in practice
                default: throw Snappy.Failure.corrupt("chunk type \(kind)")
                }
                p += length
            }
        }
        return out
    }

    /// Every object in one decompressed stream.
    static func objects(_ stream: [UInt8]) throws -> [PagesObject] {
        var objects: [PagesObject] = []
        var p = 0
        while p < stream.count {
            let infoLength = try PagesProto.varint(stream, &p, stream.count)
            guard infoLength <= UInt64(stream.count - p) else { throw Snappy.Failure.corrupt("archive info") }
            let info = try PagesProto(stream, range: p..<(p + Int(infoLength)))
            p += Int(infoLength)
            guard let id = info.uint(1) else { throw Snappy.Failure.corrupt("archive identifier") }
            var messages: [(UInt32, PagesProto)] = []
            for m in info.messages(2) {
                guard let length = Int(exactly: m.uint(3) ?? 0), length <= stream.count - p else {
                    throw Snappy.Failure.corrupt("message length")
                }
                messages.append((UInt32(truncatingIfNeeded: m.uint(1) ?? 0), try PagesProto(stream, range: p..<(p + length))))
                p += length
            }
            guard let first = messages.first else { continue }
            objects.append(PagesObject(id: id, type: first.0, message: first.1,
                                       extra: messages.dropFirst().map { (type: $0.0, message: $0.1) }))
        }
        return objects
    }

    // MARK: Writing (self-tests and test files)

    static func varintBytes(_ value: UInt64) -> [UInt8] {
        var v = value, out: [UInt8] = []
        while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        out.append(UInt8(v))
        return out
    }

    /// Builds a message from (field, value) pairs: integers become varints, strings and byte arrays
    /// length-delimited fields, Floats fixed32.
    static func encode(_ fields: [(Int, Any)]) -> [UInt8] {
        var out: [UInt8] = []
        for (n, v) in fields {
            switch v {
            case let b as Bool: out += varintBytes(UInt64(n << 3)) + varintBytes(b ? 1 : 0)
            case let i as Int: out += varintBytes(UInt64(n << 3)) + varintBytes(UInt64(i))
            case let i as UInt64: out += varintBytes(UInt64(n << 3)) + varintBytes(i)
            case let f as Float:
                out += varintBytes(UInt64(n << 3 | 5))
                let bits = f.bitPattern
                out += [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24)]
            case let s as String:
                let b = Array(s.utf8)
                out += varintBytes(UInt64(n << 3 | 2)) + varintBytes(UInt64(b.count)) + b
            case let b as [UInt8]:
                out += varintBytes(UInt64(n << 3 | 2)) + varintBytes(UInt64(b.count)) + b
            default: continue
            }
        }
        return out
    }

    /// One archive record (ArchiveInfo + payload) for an object with a single message.
    static func archive(id: UInt64, type: UInt32, payload: [UInt8]) -> [UInt8] {
        let messageInfo = encode([(1, Int(type)), (3, payload.count)])
        let info = encode([(1, id), (2, messageInfo)])
        return varintBytes(UInt64(info.count)) + info + payload
    }

    /// A stream wrapped into `.iwa` chunks of literal-only Snappy blocks.
    static func wrap(_ stream: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var p = 0
        repeat {
            let block = Snappy.compressLiterals(Array(stream[p..<min(stream.count, p + 65536)]))
            out += [0, UInt8(block.count & 0xFF), UInt8(block.count >> 8 & 0xFF), UInt8(block.count >> 16 & 0xFF)] + block
            p += 65536
        } while p < stream.count
        return out
    }
}
