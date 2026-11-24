#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import Foundation

/// Regression checks for the ZIP reader, run as part of `--selftest archives`. Each crafted archive is one
/// that used to trap, read out of bounds or allocate gigabytes; a trap here crashes the self-test, which is
/// exactly the failure being guarded against.
extension ZipReader {
    struct TestEntry {
        var name: [UInt8]
        var data: Data
        var method: UInt16 = 8
        var flags: UInt16 = 0x0800
        var usize: UInt32?
        var csize: UInt32?
        var offset: UInt32?
        var extra = Data()
    }

    /// A ZIP built by hand so that any directory field can lie.
    static func testArchive(_ entries: [TestEntry]) -> Data {
        var body = Data(), cd = Data()
        for e in entries {
            let payload = e.method == 8 ? (ZipWriter.deflate(e.data) ?? Data()) : e.data
            let crc = CRC32.checksum(e.data)
            let offset = UInt32(body.count)
            body.le32(0x0403_4B50); body.le16(20); body.le16(e.flags); body.le16(e.method); body.le16(0); body.le16(0x21)
            body.le32(crc); body.le32(UInt32(payload.count)); body.le32(UInt32(e.data.count))
            body.le16(UInt16(e.name.count)); body.le16(0)
            body.append(contentsOf: e.name); body.append(payload)
            cd.le32(0x0201_4B50); cd.le16(0x0314); cd.le16(20); cd.le16(e.flags); cd.le16(e.method); cd.le16(0); cd.le16(0x21)
            cd.le32(crc); cd.le32(e.csize ?? UInt32(payload.count)); cd.le32(e.usize ?? UInt32(e.data.count))
            cd.le16(UInt16(e.name.count)); cd.le16(UInt16(e.extra.count)); cd.le16(0); cd.le16(0); cd.le16(0)
            cd.le32(0o100644 << 16); cd.le32(e.offset ?? offset)
            cd.append(contentsOf: e.name); cd.append(e.extra)
        }
        var out = body
        let cdOffset = UInt32(out.count)
        out.append(cd)
        out.le32(0x0605_4B50); out.le16(0); out.le16(0); out.le16(UInt16(entries.count)); out.le16(UInt16(entries.count))
        out.le32(UInt32(cd.count)); out.le32(cdOffset); out.le16(0)
        return out
    }

    static func zip64Extra(_ values: UInt64...) -> Data {
        var d = Data()
        d.le16(1); d.le16(UInt16(values.count * 8))
        for v in values { d.le32(UInt32(truncatingIfNeeded: v)); d.le32(UInt32(truncatingIfNeeded: v >> 32)) }
        return d
    }

    /// Opens `data` and reads every entry; returns how many entries read cleanly, or nil if opening failed.
    @discardableResult
    static func readEverything(_ data: Data) -> Int? {
        guard let zip = try? ZipReader(data: data) else { return nil }
        return zip.entries.reduce(0) { $0 + ((try? zip.read($1)) == nil ? 0 : 1) }
    }

    static func selfTestFailures() -> [String] {
        var failures: [String] = []
        let text = Data(String(repeating: "<w:p>YummyOrange zip check</w:p>\n", count: 600).utf8)
        func doc(_ tweak: (inout TestEntry) -> Void) -> Data {
            var main = TestEntry(name: Array("word/document.xml".utf8), data: text)
            tweak(&main)
            return testArchive([TestEntry(name: Array("[Content_Types].xml".utf8), data: Data("<Types/>".utf8), method: 0),
                                main, TestEntry(name: Array("docProps/app.xml".utf8), data: Data("<Properties/>".utf8))])
        }
        func expectRefused(_ label: String, _ data: Data, part: String = "word/document.xml") {
            let start = Date()
            if let zip = try? ZipReader(data: data), (try? zip.read(part)) != nil { failures.append("zip: \(label) was read") }
            if Date().timeIntervalSince(start) > 2 { failures.append("zip: \(label) took \(Date().timeIntervalSince(start)) s") }
        }

        // The plain package reads back exactly.
        let plain = doc { _ in }
        if let zip = try? ZipReader(data: plain) {
            if (try? zip.read("word/document.xml")) != text { failures.append("zip: plain entry differs") }
            if zip.names.count != 3 { failures.append("zip: plain has \(zip.names.count) entries") }
        } else { failures.append("zip: plain archive refused") }

        // ZIP64 values past Int.max, sizes the data can't hold, a declared size that is a lie.
        expectRefused("usize 2^64-1", doc { $0.usize = 0xFFFF_FFFF; $0.extra = zip64Extra(.max) })
        expectRefused("csize 2^63-16", doc { $0.csize = 0xFFFF_FFFF; $0.extra = zip64Extra(0x7FFF_FFFF_FFFF_FFF0) })
        expectRefused("offset 2^64-1", doc { $0.offset = 0xFFFF_FFFF; $0.extra = zip64Extra(.max) })
        expectRefused("usize 1 TB", doc { $0.usize = 0xFFFF_FFFF; $0.extra = zip64Extra(1 << 40) })
        expectRefused("usize 4 GB", doc { $0.usize = 0xFFFF_FFF0 })
        expectRefused("usize one byte long", doc { $0.usize = UInt32(text.count + 1) })
        expectRefused("usize one byte short", doc { $0.usize = UInt32(text.count - 1) })
        expectRefused("ZIP64 field cut short", doc { $0.usize = 0xFFFF_FFFF; var d = Data(); d.le16(1); d.le16(8); $0.extra = d })
        // A junk entry nobody reads doesn't spoil the others.
        let junk = testArchive([TestEntry(name: Array("a.xml".utf8), data: text),
                                TestEntry(name: Array("junk.bin".utf8), data: Data(count: 100), usize: 0xFFFF_FFFF, extra: zip64Extra(.max))])
        if let zip = try? ZipReader(data: junk) {
            if (try? zip.read("a.xml")) != text { failures.append("zip: entry beside junk unreadable") }
        } else { failures.append("zip: archive with a junk entry refused") }

        // EOCD that claims ZIP64 with a locator pointing past the file.
        var eocd64 = plain
        if let end = eocd64.lastRange(of: Data([0x50, 0x4B, 0x05, 0x06])) {
            var loc = Data(); loc.le32(0x0706_4B50); loc.le32(0); loc.le32(0xFFFF_FFFF); loc.le32(0xFFFF_FFFF); loc.le32(1)
            eocd64.replaceSubrange(end.lowerBound + 8..<end.lowerBound + 12, with: Data([0xFF, 0xFF, 0xFF, 0xFF]))
            eocd64.insert(contentsOf: loc, at: end.lowerBound)
            if (try? ZipReader(data: eocd64)) != nil { failures.append("zip: ZIP64 locator past the file accepted") }
        }

        // Central directory after the end record, whose last ZIP64 header runs off the end of the file.
        var oob = Data(), oobCD = Data()
        let deflated = ZipWriter.deflate(text) ?? Data()
        oob.le32(0x0403_4B50); oob.le16(20); oob.le16(0); oob.le16(8); oob.le16(0); oob.le16(0)
        oob.le32(CRC32.checksum(text)); oob.le32(UInt32(deflated.count)); oob.le32(UInt32(text.count)); oob.le16(5); oob.le16(0)
        oob.append(Data("a.xml".utf8)); oob.append(deflated)
        oobCD.le32(0x0201_4B50); oobCD.le16(0x0314); oobCD.le16(20); oobCD.le16(0); oobCD.le16(8); oobCD.le16(0); oobCD.le16(0)
        oobCD.le32(CRC32.checksum(text)); oobCD.le32(UInt32(deflated.count)); oobCD.le32(0xFFFF_FFFF)
        oobCD.le16(5); oobCD.le16(4); oobCD.le16(0); oobCD.le16(0); oobCD.le16(0); oobCD.le32(0); oobCD.le32(0)
        oobCD.append(Data("a.xml".utf8)); oobCD.le16(1); oobCD.le16(8)
        let cdAt = UInt32(oob.count + 22)
        oob.le32(0x0605_4B50); oob.le16(0); oob.le16(0); oob.le16(1); oob.le16(1); oob.le32(UInt32(oobCD.count)); oob.le32(cdAt); oob.le16(0)
        oob.append(oobCD)
        readEverything(oob)

        // Every truncation and a few thousand random byte changes: never a trap.
        for n in stride(from: 0, to: plain.count, by: max(1, plain.count / 400)) { readEverything(plain.prefix(n)) }
        var seed: UInt64 = 0x5EED_D209
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(truncatingIfNeeded: seed >> 33) }
        let cdStart = plain.count - 200
        for round in 0..<1500 {
            var bad = [UInt8](plain)
            for _ in 0..<(1 + round % 4) {
                let at = round % 3 == 0 ? next() % bad.count : cdStart + next() % 200
                bad[at] = UInt8(truncatingIfNeeded: next())
            }
            readEverything(Data(bad))
        }

        // Too many declared bytes in total for extractAll; nothing gets written.
        let gb = (0..<5).map { TestEntry(name: Array("part\($0).bin".utf8), data: Data(count: 2 << 20), usize: 1 << 30) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-zip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        if let zip = try? ZipReader(data: testArchive(gb)) {
            if (try? zip.extractAll(to: dir)) != nil { failures.append("zip: 5 GB of declared parts extracted") }
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("part0.bin").path) {
                failures.append("zip: extractAll wrote before refusing")
            }
        }

        // Names: CP437 without the UTF-8 flag, and directory(of:) agrees with the in-memory reader.
        let legacy = testArchive([TestEntry(name: [0x9A] + Array("bersicht.txt".utf8), data: Data("u".utf8), method: 0, flags: 0)])
        if let e = (try? ZipReader(data: legacy))?.entries.first {
            if e.name != "Übersicht.txt" || !e.hasLegacyName { failures.append("zip: CP437 name read as \(e.name)") }
        } else { failures.append("zip: CP437 archive refused") }
        let file = dir.appendingPathExtension("zip")
        defer { try? FileManager.default.removeItem(at: file) }
        if (try? plain.write(to: file)) != nil {
            let listed = (try? ZipReader.directory(of: file))?.map(\.name)
            if listed != (try? ZipReader(data: plain))?.names { failures.append("zip: directory(of:) gave \(listed ?? [])") }
        }
        return failures
    }
}

private extension Data {
    func lastRange(of pattern: Data) -> Range<Int>? {
        range(of: pattern, options: .backwards).map { $0.lowerBound..<$0.upperBound }
    }
}
#endif
