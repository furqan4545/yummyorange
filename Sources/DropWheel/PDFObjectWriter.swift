import Foundation

// Writing for Edit PDF. The default save appends one incremental update, so the original file stays an exact
// byte prefix of the result. The optional compaction ("Remove replaced text from the file") rewrites the file
// with only the live objects, copying each unchanged object byte for byte.

// MARK: - Serializing values

extension PDFValue {
    func serialized() -> [UInt8] {
        var out: [UInt8] = []
        write(into: &out)
        return out
    }

    func write(into out: inout [UInt8]) {
        switch self {
        case .null: out += Array("null".utf8)
        case .bool(let b): out += Array((b ? "true" : "false").utf8)
        case .number(_, let s): out += Array(s.utf8)
        case .string(let b, let hex):
            if hex {
                out.append(60)
                for c in b { out += PDFWriterBytes.hex(c) }
                out.append(62)
            } else {
                out.append(40); out += PDFWriterBytes.escapeLiteral(b); out.append(41)
            }
        case .name(let n): out += PDFWriterBytes.name(n)
        case .array(let a):
            out.append(91)
            for (i, e) in a.enumerated() {
                if i > 0 { out.append(32) }
                e.write(into: &out)
            }
            out.append(93)
        case .dict(let d):
            out += Array("<<".utf8)
            for (k, v) in d.pairs {
                out.append(32); out += PDFWriterBytes.name(k); out.append(32)
                v.write(into: &out)
            }
            out += Array(" >>".utf8)
        case .ref(let n, let g): out += Array("\(n) \(g) R".utf8)
        }
    }
}

enum PDFWriterBytes {
    private static let digits = Array("0123456789ABCDEF".utf8)

    static func hex(_ c: UInt8) -> [UInt8] { [digits[Int(c >> 4)], digits[Int(c & 15)]] }

    /// Escapes ( ) \ and writes every byte outside 0x20…0x7E as \ddd, so the string survives any EOL conversion.
    static func escapeLiteral(_ b: [UInt8]) -> [UInt8] {
        var o: [UInt8] = []
        o.reserveCapacity(b.count + 4)
        for c in b {
            switch c {
            case 40, 41, 92: o += [92, c]
            case 0x20...0x7E: o.append(c)
            default:
                o.append(92)
                o += [48 + (c >> 6), 48 + ((c >> 3) & 7), 48 + (c & 7)]
            }
        }
        return o
    }

    static func name(_ n: String) -> [UInt8] {
        var out: [UInt8] = [47]
        for c in n.utf8 {
            if c < 33 || c > 126 || PDFLexer.isDelimiter(c) || c == 35 { out.append(35); out += hex(c) } else { out.append(c) }
        }
        return out
    }

    static func randomID() -> [UInt8] { (0..<16).map { _ in UInt8.random(in: 0...255) } }
}

// MARK: - Incremental update

/// New versions of objects (same number and generation) and new objects, appended after the original bytes
/// with a cross-reference section of the same kind as the file's newest: a table for classic and hybrid files,
/// an xref stream for xref-stream files (Core Graphics can't open an xref-stream file updated with a table).
final class PDFIncrementalUpdate {
    let file: PDFObjectFile
    private(set) var nextNumber: Int
    private var objects: [Int: (generation: Int, bytes: [UInt8])] = [:]
    /// Values of objects written as plain values, so later changes can merge into them.
    private var values: [Int: PDFValue] = [:]
    private var streams: [Int: (dict: PDFDict, decoded: [UInt8]?)] = [:]
    /// The object number of the xref stream the last `data()` wrote (xref-stream files only).
    private(set) var xrefStreamNumber: Int?

    init(_ file: PDFObjectFile) {
        self.file = file
        nextNumber = file.maxObjectNumber + 1
    }

    func allocate() -> Int {
        defer { nextNumber += 1 }
        return nextNumber
    }

    var writtenNumbers: Set<Int> { Set(objects.keys) }

    /// The value as this update will write it, else the file's.
    func currentValue(_ n: Int) -> PDFValue? {
        if let v = values[n] { return v }
        if let s = streams[n] { return .dict(s.dict) }
        return file.object(n)?.value
    }

    func generation(for n: Int) -> Int { n < file.maxObjectNumber + 1 ? file.generation(n) : 0 }

    func put(_ n: Int, _ value: PDFValue, generation: Int? = nil) {
        let g = generation ?? self.generation(for: n)
        var o = Array("\(n) \(g) obj\n".utf8)
        value.write(into: &o)
        o += Array("\nendobj\n".utf8)
        objects[n] = (g, o)
        values[n] = value
        streams[n] = nil
    }

    /// A stream with new decoded data: its dictionary kept key for key, except the encoding keys.
    func putStream(_ n: Int, dict: PDFDict, decoded: [UInt8], generation: Int? = nil) {
        var d = dict
        for k in ["Length", "Filter", "DecodeParms", "DL", "F", "FFilter", "FDecodeParms", "DP"] { d[k] = nil }
        let z = PDFFilters.deflate(decoded)
        d["Filter"] = .name("FlateDecode")
        d["Length"] = .integer(z.count)
        writeStream(n, dict: d, raw: z, generation: generation)
        streams[n] = (d, decoded)
    }

    /// A stream whose encoded bytes are copied as they are (fonts moved in from another file).
    func putRawStream(_ n: Int, dict: PDFDict, raw: [UInt8], generation: Int? = nil) {
        var d = dict
        d["Length"] = .integer(raw.count)
        writeStream(n, dict: d, raw: raw, generation: generation)
        streams[n] = (d, nil)
    }

    private func writeStream(_ n: Int, dict: PDFDict, raw: [UInt8], generation: Int?) {
        let g = generation ?? self.generation(for: n)
        var o = Array("\(n) \(g) obj\n".utf8)
        PDFValue.dict(dict).write(into: &o)
        o += Array("\nstream\n".utf8)
        o += raw
        o += Array("\nendstream\nendobj\n".utf8)
        objects[n] = (g, o)
        values[n] = nil
    }

    func remove(_ n: Int) { objects[n] = nil; values[n] = nil; streams[n] = nil }

    /// The original bytes followed by the update. `id` is the new second half of /ID.
    func data(id: [UInt8] = PDFWriterBytes.randomID()) -> Data {
        var out = file.data
        var tail: [UInt8] = []
        if let last = file.bytes.last, last != 10, last != 13 { tail.append(10) }
        var offsets: [(number: Int, generation: Int, offset: Int)] = []
        for n in objects.keys.sorted() {
            let o = objects[n]!
            offsets.append((n, o.generation, out.count + tail.count))
            tail += o.bytes
        }
        var trailer = PDFDict()
        let skip: Set<String> = ["Size", "Prev", "XRefStm", "Type", "W", "Index", "Length", "Filter", "DecodeParms", "ID", "Encrypt"]
        for (k, v) in file.trailer.pairs where !skip.contains(k) { trailer[k] = v }
        if let ids = file.trailer["ID"]?.array, let first = ids.first, first.bytes != nil {
            trailer["ID"] = .array([first, .string(id, hex: true)])
        } else {
            trailer["ID"] = .array([.string(id, hex: true), .string(id, hex: true)])
        }
        if !file.rebuilt { trailer["Prev"] = .integer(file.newestStart) }
        func groups(_ nums: [Int]) -> [[Int]] {
            var g: [[Int]] = []
            for n in nums.sorted() { if let l = g.last?.last, l + 1 == n { g[g.count - 1].append(n) } else { g.append([n]) } }
            return g
        }
        if file.newestKind == .table || file.rebuilt {
            xrefStreamNumber = nil
            let start = out.count + tail.count
            var x = "xref\n"
            let byNumber = Dictionary(uniqueKeysWithValues: offsets.map { ($0.number, $0) })
            var rows = offsets.map(\.number)
            if file.rebuilt { rows.append(0) }
            for g in groups(rows) {
                x += "\(g[0]) \(g.count)\n"
                for n in g {
                    if n == 0, byNumber[0] == nil { x += "0000000000 65535 f\r\n"; continue }
                    x += String(format: "%010d %05d n\r\n", byNumber[n]!.offset, byNumber[n]!.generation)
                }
            }
            var t = PDFDict([("Size", .integer(max(nextNumber, file.maxObjectNumber + 1)))])
            for (k, v) in trailer.pairs { t[k] = v }
            x += "trailer\n"
            tail += Array(x.utf8)
            PDFValue.dict(t).write(into: &tail)
            tail += Array("\nstartxref\n\(start)\n%%EOF\n".utf8)
        } else {
            let xn = nextNumber
            xrefStreamNumber = xn
            let start = out.count + tail.count
            offsets.append((xn, 0, start))
            let w2 = start > 0xFFFF_FFFF ? 8 : 4
            var rows: [UInt8] = []
            var index: [PDFValue] = []
            let byNumber = Dictionary(uniqueKeysWithValues: offsets.map { ($0.number, $0) })
            for g in groups(offsets.map(\.number)) {
                index += [.integer(g[0]), .integer(g.count)]
                for n in g {
                    let e = byNumber[n]!
                    rows.append(1)
                    for k in stride(from: w2 - 1, through: 0, by: -1) { rows.append(UInt8((e.offset >> (8 * k)) & 0xFF)) }
                    rows += [UInt8(e.generation >> 8 & 0xFF), UInt8(e.generation & 0xFF)]
                }
            }
            var d = PDFDict([("Type", .name("XRef")), ("Size", .integer(xn + 1)),
                             ("W", .array([.integer(1), .integer(w2), .integer(2)])), ("Index", .array(index))])
            for (k, v) in trailer.pairs { d[k] = v }
            d["Length"] = .integer(rows.count)
            var o = Array("\(xn) 0 obj\n".utf8)
            PDFValue.dict(d).write(into: &o)
            o += Array("\nstream\n".utf8) + rows + Array("\nendstream\nendobj\n".utf8)
            tail += o + Array("startxref\n\(start)\n%%EOF\n".utf8)
        }
        out.append(contentsOf: tail)
        return out
    }
}

// MARK: - Compaction

/// "Remove replaced text from the file": a full rewrite of the newest revision. Every live object is written in
/// number order, unchanged objects byte for byte; object streams that still hold a superseded member are rebuilt
/// from their live members (whose bytes stay the same); old revisions, the /Linearized dictionary, xref streams
/// and free entries are dropped. Info and XMP metadata are left as they are.
enum PDFCompactWriter {
    static func rewrite(_ m: PDFObjectFile, id: [UInt8] = PDFWriterBytes.randomID()) -> Data {
        let style: PDFObjectFile.XrefKind = m.rebuilt ? .table : m.newestKind
        var out: [UInt8] = []
        let headerEnd = min(m.bytes.firstIndex(where: { $0 == 10 || $0 == 13 }) ?? 8, 16)
        var header = Array(m.bytes[0..<headerEnd])
        if !header.starts(with: Array("%PDF-".utf8)) { header = Array("%PDF-1.7".utf8) }
        out += header + [10, 37, 0xE2, 0xE3, 0xCF, 0xD3, 10]
        var rows: [Int: PDFObjectFile.Entry] = [:]
        let live = Set(m.objectNumbers).subtracting(m.xrefStreamObjects)
        func emit(_ n: Int, _ g: Int, body: [UInt8]) {
            rows[n] = .init(kind: .offset, a: out.count, b: g)
            out += Array("\(n) \(g) obj\n".utf8) + body + Array("\nendobj\n".utf8)
        }
        var containers = Set<Int>()
        for n in live { if let e = m.entry(n), e.kind == .compressed { containers.insert(e.a) } }
        for n in live where m.object(n)?.value.dict?["Type"]?.name == "ObjStm" { containers.insert(n) }
        var repacked: [Int: [UInt8]] = [:]
        var newIndex: [Int: (Int, Int)] = [:]
        if style == .stream {
            for c in containers {
                guard let box = m.objectStream(c) else { continue }
                let members = box.offsets.enumerated().filter { i, member in
                    guard let e = m.entry(member.number) else { return false }
                    return e.kind == .compressed && e.a == c && e.b == i
                }
                if members.count == box.offsets.count {
                    for (i, member) in members { newIndex[member.number] = (c, i) }
                    continue
                }
                guard !members.isEmpty else { continue }
                var head: [UInt8] = [], body: [UInt8] = []
                for (j, (_, member)) in members.enumerated() {
                    head += Array("\(member.number) \(body.count) ".utf8)
                    body += (m.memberBytes(member.number) ?? []) + [10]
                    newIndex[member.number] = (c, j)
                }
                let z = PDFFilters.deflate(head + body)
                let d = PDFDict([("Type", .name("ObjStm")), ("N", .integer(members.count)), ("First", .integer(head.count)),
                                 ("Filter", .name("FlateDecode")), ("Length", .integer(z.count))])
                repacked[c] = PDFValue.dict(d).serialized() + Array("\nstream\n".utf8) + z + Array("\nendstream".utf8)
            }
        }
        for n in live.sorted() {
            guard let e = m.entry(n) else { continue }
            if containers.contains(n) {
                if style == .table { continue }                                  // members are written out below
                if let r = repacked[n] { emit(n, 0, body: r); continue }
                if !newIndex.values.contains(where: { $0.0 == n }) { continue }   // nothing live inside any more
            }
            switch e.kind {
            case .offset:
                guard let o = m.object(n), let src = o.source else { continue }
                if o.value.dict?["Linearized"] != nil { continue }
                // Copy the bytes between "obj" and "endobj" exactly.
                var lx = PDFLexer(m.bytes, at: src.lowerBound)
                _ = lx.next(); _ = lx.next(); _ = lx.next()
                var bodyEnd = src.upperBound
                let tailText = String(decoding: m.bytes[max(src.lowerBound, src.upperBound - 6)..<src.upperBound], as: UTF8.self)
                if tailText == "endobj" { bodyEnd -= 6 }
                var body = Array(m.bytes[lx.p..<bodyEnd])
                while let f = body.first, PDFLexer.isWhite(f) { body.removeFirst() }
                while let l = body.last, PDFLexer.isWhite(l) { body.removeLast() }
                emit(n, e.b, body: body)
            case .compressed:
                if style == .stream, let idx = newIndex[n] { rows[n] = .init(kind: .compressed, a: idx.0, b: idx.1) }
                else if let b = m.memberBytes(n) {
                    var body = b
                    while let l = body.last, PDFLexer.isWhite(l) { body.removeLast() }
                    emit(n, 0, body: body)
                }
            case .free: break
            }
        }
        var t = PDFDict()
        let skip: Set<String> = ["Prev", "XRefStm", "Size", "Type", "W", "Index", "Length", "Filter", "DecodeParms", "ID"]
        for (k, v) in m.trailer.pairs where !skip.contains(k) { t[k] = v }
        if let ids = m.trailer["ID"]?.array, let first = ids.first, first.bytes != nil {
            t["ID"] = .array([first, .string(id, hex: true)])
        } else {
            t["ID"] = .array([.string(id, hex: true), .string(id, hex: true)])
        }
        let xrefNumber = max(m.maxObjectNumber, rows.keys.max() ?? 0) + 1
        let size = style == .stream ? xrefNumber + 1 : (rows.keys.max() ?? 0) + 1
        let xrefStart = out.count
        // One row per number up to /Size, unless the numbers are sparse: a crafted file can list a live object
        // numbered 999,999,999 (or give a /Size that large), and a row for every number below it would take
        // gigabytes. Then only the numbers in use get rows, in subsections of consecutive numbers.
        func subsections() -> [(first: Int, count: Int)] {
            if size <= 4 * rows.count + 1024 { return [(0, size)] }
            var out: [(first: Int, count: Int)] = []
            for n in Set(rows.keys).union([0]).sorted() where n < size {
                if let last = out.last, last.first + last.count == n { out[out.count - 1].count += 1 } else { out.append((n, 1)) }
            }
            return out
        }
        if style == .table {
            var x = "xref\n"
            for sub in subsections() {
                x += "\(sub.first) \(sub.count)\n"
                for n in sub.first..<(sub.first + sub.count) {
                    if let r = rows[n], r.kind == .offset { x += String(format: "%010d %05d n\r\n", r.a, r.b) }
                    else { x += n == 0 ? "0000000000 65535 f\r\n" : "0000000000 00000 f\r\n" }
                }
            }
            var tt = PDFDict([("Size", .integer(size))])
            for (k, v) in t.pairs { tt[k] = v }
            out += Array(x.utf8) + Array("trailer\n".utf8) + PDFValue.dict(tt).serialized() + Array("\nstartxref\n\(xrefStart)\n%%EOF\n".utf8)
        } else {
            rows[xrefNumber] = .init(kind: .offset, a: xrefStart, b: 0)
            var d: [UInt8] = []
            let subs = subsections()
            for sub in subs {
                for n in sub.first..<(sub.first + sub.count) {
                    let r = rows[n] ?? .init(kind: .free, a: 0, b: n == 0 ? 65535 : 0)
                    let type: UInt8 = r.kind == .free ? 0 : r.kind == .offset ? 1 : 2
                    d += [type, UInt8(r.a >> 24 & 0xFF), UInt8(r.a >> 16 & 0xFF), UInt8(r.a >> 8 & 0xFF), UInt8(r.a & 0xFF),
                          UInt8(r.b >> 8 & 0xFF), UInt8(r.b & 0xFF)]
                }
            }
            let z = PDFFilters.deflate(d)
            var dd = PDFDict([("Type", .name("XRef")), ("Size", .integer(size)),
                              ("W", .array([.integer(1), .integer(4), .integer(2)]))])
            if subs.count != 1 || subs[0].first != 0 || subs[0].count != size {
                dd["Index"] = .array(subs.flatMap { [PDFValue.integer($0.first), .integer($0.count)] })
            }
            for (k, v) in t.pairs { dd[k] = v }
            dd["Filter"] = .name("FlateDecode")
            dd["Length"] = .integer(z.count)
            out += Array("\(xrefNumber) 0 obj\n".utf8) + PDFValue.dict(dd).serialized() + Array("\nstream\n".utf8) + z
            out += Array("\nendstream\nendobj\nstartxref\n\(xrefStart)\n%%EOF\n".utf8)
        }
        return Data(out)
    }
}
