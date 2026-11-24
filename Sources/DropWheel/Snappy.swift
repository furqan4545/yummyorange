import Foundation

/// Raw Snappy block decompression (no framing, no CRCs), as used inside iWork's `.iwa` files.
/// A block is a varint with the uncompressed length, then literals and back-references.
enum Snappy {
    enum Failure: LocalizedError {
        case corrupt(String)
        var errorDescription: String? {
            if case .corrupt(let why) = self { return "The compressed data is damaged (\(why))." }
            return nil
        }
    }

    /// Largest block we agree to expand. iWork chunks are 64 KiB; this only stops a hostile length.
    static let maxBlock = 256 << 20

    static func decompress(_ input: [UInt8]) throws -> [UInt8] {
        try input.withUnsafeBufferPointer { try decompress($0[...]) }
    }

    /// Decompresses one block given as a slice of a larger buffer.
    static func decompress(_ src: Slice<UnsafeBufferPointer<UInt8>>) throws -> [UInt8] {
        var p = src.startIndex
        let end = src.endIndex
        // Uncompressed length (varint, at most 5 bytes for 32 bits).
        var length = 0, shift = 0
        while true {
            guard p < end, shift <= 28 else { throw Failure.corrupt("length") }
            let c = src[p]; p += 1
            length |= Int(c & 0x7F) << shift
            if c < 0x80 { break }
            shift += 7
        }
        guard length <= maxBlock else { throw Failure.corrupt("block too large") }
        var out = [UInt8]()
        out.reserveCapacity(length)

        while p < end {
            let tag = src[p]; p += 1
            switch tag & 3 {
            case 0:   // literal
                var n = Int(tag >> 2)
                if n >= 60 {
                    let extra = n - 59
                    guard p + extra <= end else { throw Failure.corrupt("literal length") }
                    n = 0
                    for i in 0..<extra { n |= Int(src[p + i]) << (8 * i) }
                    p += extra
                }
                n += 1
                guard p + n <= end, out.count + n <= length else { throw Failure.corrupt("literal") }
                out.append(contentsOf: src[p..<(p + n)])
                p += n
            default:  // copy
                let n: Int, offset: Int
                switch tag & 3 {
                case 1:
                    guard p < end else { throw Failure.corrupt("copy") }
                    n = Int((tag >> 2) & 7) + 4
                    offset = Int(tag >> 5) << 8 | Int(src[p]); p += 1
                case 2:
                    guard p + 2 <= end else { throw Failure.corrupt("copy") }
                    n = Int(tag >> 2) + 1
                    offset = Int(src[p]) | Int(src[p + 1]) << 8; p += 2
                default:
                    guard p + 4 <= end else { throw Failure.corrupt("copy") }
                    n = Int(tag >> 2) + 1
                    offset = Int(src[p]) | Int(src[p + 1]) << 8 | Int(src[p + 2]) << 16 | Int(src[p + 3]) << 24
                    p += 4
                }
                guard offset > 0, offset <= out.count, out.count + n <= length else { throw Failure.corrupt("back-reference") }
                let start = out.count - offset
                if offset >= n {
                    out.append(contentsOf: out[start..<(start + n)])
                } else {
                    // Overlapping copy (a run): byte by byte.
                    for i in 0..<n { out.append(out[start + i]) }
                }
            }
        }
        guard out.count == length else { throw Failure.corrupt("length mismatch") }
        return out
    }

    /// A valid block made only of literals. Used by the self-test and handy for writing test files.
    static func compressLiterals(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        var n = data.count
        while n >= 0x80 { out.append(UInt8(n & 0x7F) | 0x80); n >>= 7 }
        out.append(UInt8(n))
        var p = 0
        while p < data.count {
            let count = min(65536, data.count - p)
            let l = count - 1
            if l < 60 { out.append(UInt8(l << 2)) }
            else if l < 256 { out.append(60 << 2); out.append(UInt8(l)) }
            else { out.append(61 << 2); out.append(UInt8(l & 0xFF)); out.append(UInt8(l >> 8)) }
            out.append(contentsOf: data[p..<(p + count)])
            p += count
        }
        return out
    }
}
