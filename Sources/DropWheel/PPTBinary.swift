import Foundation
import CoreGraphics

/// Reads PowerPoint 97–2003 files (.ppt, .pps, .pot): the OLE2 compound file, the PowerPoint record
/// stream (persist directory, slides, masters, text atoms with their formatting, drawings) and the
/// Pictures stream, and rebuilds each slide as PPTX parts that `PPTXRenderer` draws and `PPTXWriter` saves.
enum PPTBinary {
    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    static func isCompoundFile(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return ((try? h.read(upToCount: 8)) ?? Data()).elementsEqual(signature)
    }

    /// A password-protected Office 2007+ file is a compound file holding an "EncryptedPackage" stream.
    static func isEncryptedPackage(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let cfb = try? PPTCompoundFile(data) else { return false }
        return cfb.stream("EncryptedPackage") != nil
    }

    static func convert(_ url: URL) throws -> PPTXMemoryParts {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw ConversionError.unreadable(url.lastPathComponent) }
        let cfb: PPTCompoundFile
        do { cfb = try PPTCompoundFile(data) } catch { throw ConversionError.unsupported("\(url.lastPathComponent) is damaged: \(error.localizedDescription)") }
        if cfb.stream("EncryptedPackage") != nil {
            throw ConversionError.unsupported("This presentation is password-protected. Open it in PowerPoint and save a copy without a password first.")
        }
        guard let doc = cfb.stream("PowerPoint Document") else {
            if cfb.stream("WordDocument") != nil { throw ConversionError.unsupported("This is a Word document, not a presentation.") }
            if cfb.stream("Workbook") != nil || cfb.stream("Book") != nil {
                throw ConversionError.unsupported("This is an Excel workbook, not a presentation.")
            }
            throw ConversionError.unsupported("\(url.lastPathComponent) isn’t a PowerPoint presentation.")
        }
        let reader = PPTDocumentReader(stream: [UInt8](doc), currentUser: cfb.stream("Current User").map { [UInt8]($0) },
                                       pictures: cfb.stream("Pictures").map { [UInt8]($0) } ?? [])
        return try reader.convert(title: url.deletingPathExtension().lastPathComponent)
    }
}

// MARK: - Compound file

enum PPTCompoundError: LocalizedError {
    case bad(String)
    var errorDescription: String? { if case .bad(let s) = self { return s }; return nil }
}

/// A minimal OLE2 / Compound File Binary reader (version 3 and 4, FAT, DIFAT, mini stream).
struct PPTCompoundFile {
    private let b: [UInt8]
    private let sectorSize: Int
    private let fat: [UInt32]
    private let miniFat: [UInt32]
    private let miniStream: [UInt8]
    private let entries: [(name: String, type: UInt8, start: UInt32, size: Int)]
    private let cutoff: Int

    private static let endOfChain: UInt32 = 0xFFFF_FFFE

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 512, Array(bytes[0..<8]) == PPTBinary.signature else { throw PPTCompoundError.bad("not a compound file") }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> UInt32 { UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24 }
        let shift = u16(0x1E)
        guard shift == 9 || shift == 12 else { throw PPTCompoundError.bad("unsupported sector size") }
        let ss = 1 << shift
        let cutoffValue = Int(u32(0x38))
        let sectorCount = max(0, (bytes.count - ss) / ss)
        func sectorOffset(_ s: UInt32) -> Int? {
            let o = (Int(s) + 1) * ss
            return Int(s) < sectorCount && o + ss <= bytes.count ? o : nil
        }
        // DIFAT: 109 entries in the header, then a chain of DIFAT sectors.
        var difat: [UInt32] = (0..<109).map { u32(0x4C + $0 * 4) }
        var next = u32(0x44)
        var guardCount = 0
        while next < 0xFFFF_FFFA, let o = sectorOffset(next), guardCount < sectorCount {
            for k in 0..<(ss / 4 - 1) { difat.append(u32(o + k * 4)) }
            next = u32(o + ss - 4)
            guardCount += 1
        }
        var fatList: [UInt32] = []
        for s in difat where s < 0xFFFF_FFFA {
            guard let o = sectorOffset(s) else { continue }
            for k in 0..<(ss / 4) { fatList.append(u32(o + k * 4)) }
        }
        func chain(_ start: UInt32) -> [Int] {
            var out: [Int] = []
            var s = start
            var seen = Set<UInt32>()
            while s < 0xFFFF_FFFA, !seen.contains(s), let o = sectorOffset(s) {
                seen.insert(s)
                out.append(o)
                s = Int(s) < fatList.count ? fatList[Int(s)] : Self.endOfChain
            }
            return out
        }
        func read(_ start: UInt32, _ size: Int?) -> [UInt8] {
            var out: [UInt8] = []
            for o in chain(start) { out.append(contentsOf: bytes[o..<(o + ss)]) }
            if let size, size < out.count { out.removeLast(out.count - size) }
            return out
        }
        // Directory.
        let dir = read(u32(0x30), nil)
        var list: [(String, UInt8, UInt32, Int)] = []
        var p = 0
        while p + 128 <= dir.count {
            let nameLen = min(64, Int(dir[p + 0x40]) | Int(dir[p + 0x41]) << 8)
            var units: [UInt16] = []
            var k = 0
            while k + 1 < nameLen { units.append(UInt16(dir[p + k]) | UInt16(dir[p + k + 1]) << 8); k += 2 }
            if units.last == 0 { units.removeLast() }
            let type = dir[p + 0x42]
            let start = UInt32(dir[p + 0x74]) | UInt32(dir[p + 0x75]) << 8 | UInt32(dir[p + 0x76]) << 16 | UInt32(dir[p + 0x77]) << 24
            var size = 0
            for j in 0..<4 { size |= Int(dir[p + 0x78 + j]) << (8 * j) }
            list.append((String(decoding: units, as: UTF16.self), type, start, size))
            p += 128
        }
        guard let root = list.first, root.1 == 5 else { throw PPTCompoundError.bad("no root entry") }
        let miniData = read(root.2, root.3)
        var mf: [UInt32] = []
        let mfData = read(u32(0x3C), nil)
        var q = 0
        while q + 4 <= mfData.count {
            mf.append(UInt32(mfData[q]) | UInt32(mfData[q + 1]) << 8 | UInt32(mfData[q + 2]) << 16 | UInt32(mfData[q + 3]) << 24)
            q += 4
        }
        b = bytes
        sectorSize = ss
        cutoff = cutoffValue
        fat = fatList
        entries = list.map { (name: $0.0, type: $0.1, start: $0.2, size: $0.3) }
        miniStream = miniData
        miniFat = mf
    }

    func stream(_ name: String) -> Data? {
        guard let e = entries.first(where: { $0.type == 2 && $0.name.lowercased() == name.lowercased() }) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(e.size)
        if e.size < cutoff {
            var s = e.start
            var seen = Set<UInt32>()
            while s < 0xFFFF_FFFA, !seen.contains(s), out.count < e.size {
                seen.insert(s)
                let o = Int(s) * 64
                guard o + 64 <= miniStream.count else { break }
                out.append(contentsOf: miniStream[o..<(o + 64)])
                s = Int(s) < miniFat.count ? miniFat[Int(s)] : Self.endOfChain
            }
        } else {
            var s = e.start
            var seen = Set<UInt32>()
            while s < 0xFFFF_FFFA, !seen.contains(s), out.count < e.size {
                seen.insert(s)
                let o = (Int(s) + 1) * sectorSize
                guard o + sectorSize <= b.count else { break }
                out.append(contentsOf: b[o..<(o + sectorSize)])
                s = Int(s) < fat.count ? fat[Int(s)] : Self.endOfChain
            }
        }
        if out.count > e.size { out.removeLast(out.count - e.size) }
        return Data(out)
    }
}

// MARK: - Records

/// One record of the PowerPoint stream (also used for the OfficeArt drawing records inside it).
struct PPTRecord {
    let version: Int
    let instance: Int
    let type: Int
    /// Offset of the record's data (after the 8-byte header).
    let start: Int
    let length: Int
    var end: Int { start + length }
    var isContainer: Bool { version == 0xF }
}

/// Paragraph formatting from a TextPFException (only what was set).
struct PPTParaFormat {
    var bullet: Bool?
    var bulletChar: UInt16?
    var bulletFont: Int?
    var bulletSize: Int?
    var bulletColor: PPTXColor?
    var align: Int?
    var lineSpacing: Int?
    var spaceBefore: Int?
    var spaceAfter: Int?
    var leftMargin: Int?
    var indent: Int?

    mutating func fill(from o: PPTParaFormat) {
        bullet = bullet ?? o.bullet; bulletChar = bulletChar ?? o.bulletChar; bulletFont = bulletFont ?? o.bulletFont
        bulletSize = bulletSize ?? o.bulletSize; bulletColor = bulletColor ?? o.bulletColor; align = align ?? o.align
        lineSpacing = lineSpacing ?? o.lineSpacing; spaceBefore = spaceBefore ?? o.spaceBefore; spaceAfter = spaceAfter ?? o.spaceAfter
        leftMargin = leftMargin ?? o.leftMargin; indent = indent ?? o.indent
    }
}

/// Character formatting from a TextCFException (only what was set).
struct PPTCharFormat {
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var font: Int?
    var size: Int?
    var color: PPTXColor?
    var position: Int?

    mutating func fill(from o: PPTCharFormat) {
        bold = bold ?? o.bold; italic = italic ?? o.italic; underline = underline ?? o.underline; font = font ?? o.font
        size = size ?? o.size; color = color ?? o.color; position = position ?? o.position
    }
}

/// A text block: the characters plus paragraph and character runs.
struct PPTTextBlock {
    var type = 4
    var text = ""
    var paraRuns: [(count: Int, level: Int, format: PPTParaFormat)] = []
    var charRuns: [(count: Int, format: PPTCharFormat)] = []
}

/// Text master styles for one text type: five levels of paragraph and character formatting.
typealias PPTMasterStyle = [(PPTParaFormat, PPTCharFormat)]

/// Walks the PowerPoint stream and produces PPTX parts.
final class PPTDocumentReader {
    private let b: [UInt8]
    private let currentUser: [UInt8]?
    private let pictures: [UInt8]
    private var persist: [Int: Int] = [:]
    private var fonts: [String] = []
    private var blips: [(data: Data, ext: String)?] = []
    private var defaultsFOPT: [Int: (UInt32, [UInt8]?)] = [:]
    private var scheme: [PPTXColor] = PPTDocumentReader.defaultScheme

    static let defaultScheme: [PPTXColor] = ["FFFFFF", "000000", "808080", "000000", "BBE0E3", "333399", "009999", "99CC00"]
        .map { PPTXColor(hex: $0)! }

    init(stream: [UInt8], currentUser: [UInt8]?, pictures: [UInt8]) {
        b = stream
        self.currentUser = currentUser
        self.pictures = pictures
    }

    // MARK: Low-level

    private func u8(_ i: Int) -> Int { i >= 0 && i < b.count ? Int(b[i]) : 0 }
    private func u16(_ i: Int) -> Int { u8(i) | u8(i + 1) << 8 }
    private func i16(_ i: Int) -> Int { Int(Int16(truncatingIfNeeded: u16(i))) }
    private func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
    private func i32(_ i: Int) -> Int { Int(Int32(bitPattern: u32(i))) }

    private func record(at o: Int) -> PPTRecord? {
        guard o >= 0, o + 8 <= b.count else { return nil }
        let verInst = u16(o)
        let len = Int(u32(o + 4))
        guard len >= 0, o + 8 + len <= b.count else { return nil }
        return PPTRecord(version: verInst & 0xF, instance: verInst >> 4, type: u16(o + 2), start: o + 8, length: len)
    }

    private func children(_ r: PPTRecord) -> [PPTRecord] {
        var out: [PPTRecord] = []
        var o = r.start
        while o + 8 <= r.end, let c = record(at: o), c.end <= r.end {
            out.append(c)
            o = c.end
        }
        return out
    }

    private func child(_ r: PPTRecord, _ type: Int) -> PPTRecord? { children(r).first { $0.type == type } }

    private func find(_ r: PPTRecord, _ type: Int) -> [PPTRecord] {
        var out: [PPTRecord] = []
        for c in children(r) {
            if c.type == type { out.append(c) }
            if c.isContainer { out += find(c, type) }
        }
        return out
    }

    // MARK: Persist directory

    private func loadPersist() throws -> Int {
        var editOffset: Int?
        if let cu = currentUser, cu.count >= 20 {
            let token = UInt32(cu[12]) | UInt32(cu[13]) << 8 | UInt32(cu[14]) << 16 | UInt32(cu[15]) << 24
            if token == 0xF3D1_C4DF {
                throw ConversionError.unsupported("This presentation is password-protected. Open it in PowerPoint and save a copy without a password first.")
            }
            editOffset = Int(UInt32(cu[16]) | UInt32(cu[17]) << 8 | UInt32(cu[18]) << 16 | UInt32(cu[19]) << 24)
        }
        if editOffset == nil || record(at: editOffset!)?.type != 0x0FF5 {
            // No usable Current User stream: take the last UserEditAtom in the document stream.
            var o = 0, last: Int?
            while let r = record(at: o) { if r.type == 0x0FF5 { last = o }; o = r.end }
            editOffset = last
        }
        guard var offset = editOffset else { throw ConversionError.unsupported("This presentation is damaged (no edit record).") }
        var docRef: Int?
        var visited = Set<Int>()
        while offset > 0 || visited.isEmpty, !visited.contains(offset), let edit = record(at: offset), edit.type == 0x0FF5 {
            visited.insert(offset)
            if docRef == nil { docRef = Int(u32(edit.start + 16)) }
            if edit.length >= 32, u32(edit.start + 28) != 0 {
                throw ConversionError.unsupported("This presentation is password-protected. Open it in PowerPoint and save a copy without a password first.")
            }
            let dirOffset = Int(u32(edit.start + 12))
            if let dir = record(at: dirOffset), dir.type == 0x1772 {
                var p = dir.start
                while p + 4 <= dir.end {
                    let head = u32(p)
                    let first = Int(head & 0xFFFFF), count = Int(head >> 20)
                    p += 4
                    for k in 0..<count where p + 4 <= dir.end {
                        if persist[first + k] == nil { persist[first + k] = Int(u32(p)) }
                        p += 4
                    }
                }
            }
            let previous = Int(u32(edit.start + 8))
            if previous == 0 { break }
            offset = previous
        }
        guard let ref = docRef, let docOffset = persist[ref] else { throw ConversionError.unsupported("This presentation is damaged (no document record).") }
        return docOffset
    }

    // MARK: Formatting

    private func color(_ i: Int) -> PPTXColor? {
        let index = u8(i + 3)
        if index == 0xFE { return PPTXColor(r: Double(u8(i)) / 255, g: Double(u8(i + 1)) / 255, b: Double(u8(i + 2)) / 255) }
        if index < 8 { return scheme[index] }
        return nil
    }

    /// Parses a TextPFException at `p`; returns the format and the offset after it.
    private func paraFormat(_ p0: Int) -> (PPTParaFormat, Int) {
        var p = p0
        let m = u32(p); p += 4
        var f = PPTParaFormat()
        func has(_ bit: Int) -> Bool { m & (1 << UInt32(bit)) != 0 }
        if has(0) || has(1) || has(2) || has(3) {
            let flags = u16(p); p += 2
            if has(0) { f.bullet = flags & 1 != 0 }
        }
        if has(7) { f.bulletChar = UInt16(u16(p)); p += 2 }
        if has(4) { f.bulletFont = u16(p); p += 2 }
        if has(6) { f.bulletSize = i16(p); p += 2 }
        if has(5) { f.bulletColor = color(p); p += 4 }
        if has(11) { f.align = u16(p); p += 2 }
        if has(12) { f.lineSpacing = i16(p); p += 2 }
        if has(13) { f.spaceBefore = i16(p); p += 2 }
        if has(14) { f.spaceAfter = i16(p); p += 2 }
        if has(8) { f.leftMargin = i16(p); p += 2 }
        if has(10) { f.indent = i16(p); p += 2 }
        if has(15) { p += 2 }
        if has(20) { let n = u16(p); p += 2 + n * 4 }
        if has(16) { p += 2 }
        if has(17) || has(18) || has(19) { p += 2 }
        if has(21) { p += 2 }
        return (f, p)
    }

    /// Parses a TextCFException at `p`; returns the format and the offset after it.
    private func charFormat(_ p0: Int) -> (PPTCharFormat, Int) {
        var p = p0
        let m = u32(p); p += 4
        var f = PPTCharFormat()
        func has(_ bit: Int) -> Bool { m & (1 << UInt32(bit)) != 0 }
        if m & 0x3EB7 != 0 || has(0) || has(1) || has(2) {
            let style = u16(p); p += 2
            if has(0) { f.bold = style & 1 != 0 }
            if has(1) { f.italic = style & 2 != 0 }
            if has(2) { f.underline = style & 4 != 0 }
        }
        if has(16) { f.font = u16(p); p += 2 }
        if has(21) { p += 2 }
        if has(22) { p += 2 }
        if has(23) { p += 2 }
        if has(17) { f.size = u16(p); p += 2 }
        if has(18) { f.color = color(p); p += 4 }
        if has(19) { f.position = i16(p); p += 2 }
        if has(20) { p += 4 }
        if has(24) { p += 2 }
        if has(25) { p += 2 }
        if has(26) { p += 4 }
        return (f, p)
    }

    private func styleRuns(_ r: PPTRecord, textLength: Int, into block: inout PPTTextBlock) {
        var p = r.start
        var covered = 0
        while covered < textLength + 1, p + 6 <= r.end {
            let count = Int(u32(p)); let level = u16(p + 4)
            let (f, next) = paraFormat(p + 6)
            guard count > 0, next <= r.end else { break }
            block.paraRuns.append((count, min(4, level), f))
            covered += count
            p = next
        }
        covered = 0
        while covered < textLength + 1, p + 4 <= r.end {
            let count = Int(u32(p))
            let (f, next) = charFormat(p + 4)
            guard count > 0, next <= r.end else { break }
            block.charRuns.append((count, f))
            covered += count
            p = next
        }
    }

    /// Reads TextHeader / TextChars / TextBytes / StyleTextProp atoms from a list of records.
    private func textBlocks(_ records: [PPTRecord]) -> [PPTTextBlock] {
        var blocks: [PPTTextBlock] = []
        for r in records {
            switch r.type {
            case 0x0F9F:
                blocks.append(PPTTextBlock(type: Int(u32(r.start))))
            case 0x0FA0, 0x0FA8:
                if blocks.isEmpty { blocks.append(PPTTextBlock()) }
                if r.type == 0x0FA0 {
                    var units: [UInt16] = []
                    var p = r.start
                    while p + 1 < r.end { units.append(UInt16(u16(p))); p += 2 }
                    blocks[blocks.count - 1].text = String(decoding: units, as: UTF16.self)
                } else {
                    blocks[blocks.count - 1].text = String(b[r.start..<r.end].map { Character(UnicodeScalar($0)) })
                }
            case 0x0FA1:
                if !blocks.isEmpty { styleRuns(r, textLength: blocks[blocks.count - 1].text.utf16.count, into: &blocks[blocks.count - 1]) }
            default:
                break
            }
        }
        return blocks
    }

    /// TextMasterStyleAtom → five levels of formatting.
    private func masterStyle(_ r: PPTRecord) -> PPTMasterStyle {
        var out: PPTMasterStyle = []
        let levels = u16(r.start)
        var p = r.start + 2
        for _ in 0..<min(5, levels) {
            if r.instance >= 5 { p += 2 }
            let (pf, p1) = paraFormat(p)
            let (cf, p2) = charFormat(p1)
            guard p2 <= r.end else { break }
            out.append((pf, cf))
            p = p2
        }
        return out
    }

    // MARK: Drawing properties

    private struct Props {
        var values: [Int: (UInt32, [UInt8]?)] = [:]
        func get(_ id: Int) -> UInt32? { values[id]?.0 }
        func data(_ id: Int) -> [UInt8]? { values[id]?.1 }
    }

    private func props(_ r: PPTRecord) -> Props {
        var out = Props()
        let n = r.instance
        var p = r.start
        var complexStart = r.start + n * 6
        for _ in 0..<n where p + 6 <= r.end {
            let opid = u16(p), value = u32(p + 2)
            let id = opid & 0x3FFF
            var extra: [UInt8]?
            if opid & 0x8000 != 0 {
                let len = Int(value)
                if complexStart + len <= r.end { extra = Array(b[complexStart..<(complexStart + len)]) }
                complexStart += len
            }
            out.values[id] = (value, extra)
            p += 6
        }
        return out
    }

    private func officeColor(_ v: UInt32, scheme: [PPTXColor]) -> PPTXColor? {
        let flags = (v >> 24) & 0xFF
        if flags & 0x08 != 0 { let i = Int(v & 0xFF); return i < scheme.count ? scheme[i] : nil }
        if flags & 0x10 != 0 { return nil }
        return PPTXColor(r: Double(v & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double((v >> 16) & 0xFF) / 255)
    }

    // MARK: Pictures

    private func loadBlips(_ docContainer: PPTRecord) {
        guard let group = child(docContainer, 0x040B), let dgg = child(group, 0xF000) else { return }
        if let defaults = child(dgg, 0xF00B) { defaultsFOPT = props(defaults).values }
        guard let store = child(dgg, 0xF001) else { return }
        for fbse in children(store) where fbse.type == 0xF007 {
            let size = Int(u32(fbse.start + 20)), offset = Int(u32(fbse.start + 28))
            let nameLen = u8(fbse.start + 33)
            var blip: (Data, String)?
            if fbse.length > 36 + nameLen, let embedded = record(at: fbse.start + 36 + nameLen) {
                blip = decodeBlip(b, embedded)
            } else if size > 0, offset >= 0, offset + 8 <= pictures.count {
                let p = pictures
                let verInst = Int(p[offset]) | Int(p[offset + 1]) << 8
                let len = Int(UInt32(p[offset + 4]) | UInt32(p[offset + 5]) << 8 | UInt32(p[offset + 6]) << 16 | UInt32(p[offset + 7]) << 24)
                if offset + 8 + len <= p.count {
                    let r = PPTRecord(version: verInst & 0xF, instance: verInst >> 4,
                                      type: Int(p[offset + 2]) | Int(p[offset + 3]) << 8, start: offset + 8, length: len)
                    blip = decodeBlip(p, r)
                }
            }
            blips.append(blip)
        }
    }

    /// The image data of a BLIP record (JPEG, PNG, TIFF, or a DIB wrapped as BMP). Metafiles are skipped.
    private func decodeBlip(_ bytes: [UInt8], _ r: PPTRecord) -> (Data, String)? {
        func uidCount(_ single: Int) -> Int { r.instance == single ? 1 : 2 }
        switch r.type {
        case 0xF01D, 0xF02A:
            let skip = 16 * uidCount(r.instance == 0x46A || r.instance == 0x46B ? 0x46A : 0x6E2) + 1
            guard r.length > skip else { return nil }
            return (Data(bytes[(r.start + skip)..<r.end]), "jpeg")
        case 0xF01E:
            let skip = 16 * uidCount(0x6E0) + 1
            guard r.length > skip else { return nil }
            return (Data(bytes[(r.start + skip)..<r.end]), "png")
        case 0xF029:
            let skip = 16 * uidCount(0x6E4) + 1
            guard r.length > skip else { return nil }
            return (Data(bytes[(r.start + skip)..<r.end]), "tiff")
        case 0xF01F:
            let skip = 16 * uidCount(0x7A8) + 1
            guard r.length > skip + 40 else { return nil }
            let dib = Array(bytes[(r.start + skip)..<r.end])
            // Wrap the DIB in a BITMAPFILEHEADER so ImageIO reads it as BMP.
            let headerSize = Int(dib[0]) | Int(dib[1]) << 8 | Int(dib[2]) << 16
            let bitCount = Int(dib[14]) | Int(dib[15]) << 8
            var colors = dib.count > 35 ? Int(dib[32]) | Int(dib[33]) << 8 | Int(dib[34]) << 16 : 0
            if colors == 0 && bitCount <= 8 { colors = 1 << bitCount }
            let offBits = 14 + headerSize + colors * 4
            var file = Data([0x42, 0x4D])
            file.le32(UInt32(14 + dib.count)); file.le32(0); file.le32(UInt32(offBits))
            file.append(contentsOf: dib)
            return (file, "bmp")
        default:
            return nil
        }
    }

    // MARK: Conversion

    private struct Master {
        var scheme: [PPTXColor]
        var styles: [Int: PPTMasterStyle]
        var background: String?
        var shapes: [String]
        var media: [(Data, String)]
    }

    func convert(title: String) throws -> PPTXMemoryParts {
        let docOffset = try loadPersist()
        guard let doc = record(at: docOffset), doc.type == 0x03E8 else {
            throw ConversionError.unsupported("This presentation is damaged (bad document record).")
        }
        var width = 5760, height = 4320
        if let atom = child(doc, 0x03E9) { width = max(576, i32(atom.start)); height = max(576, i32(atom.start + 4)) }
        if let env = child(doc, 0x03F2), let fc = child(env, 0x07D5) {
            for fe in children(fc) where fe.type == 0x0FB7 {
                var units: [UInt16] = []
                var p = fe.start
                while p + 1 < fe.start + 64, u16(p) != 0 { units.append(UInt16(u16(p))); p += 2 }
                fonts.append(String(decoding: units, as: UTF16.self))
            }
        }
        loadBlips(doc)

        let lists = children(doc).filter { $0.type == 0x0FF0 }
        // Masters.
        var masters: [UInt32: Master] = [:]
        if let masterList = lists.first(where: { $0.instance == 1 }) {
            for atom in children(masterList) where atom.type == 0x03F3 {
                let ref = Int(u32(atom.start)), id = u32(atom.start + 12)
                if let o = persist[ref], let m = record(at: o), m.type == 0x03F8 || m.type == 0x03EE {
                    masters[id] = readMaster(m)
                }
            }
        }
        guard let slideList = lists.first(where: { $0.instance == 0 }) else {
            throw ConversionError.unsupported("This presentation has no slides.")
        }
        // Slides with their outline text.
        var slideRefs: [(ref: Int, texts: [PPTTextBlock])] = []
        var pending: [PPTRecord] = []
        var current: Int?
        for r in children(slideList) {
            if r.type == 0x03F3 {
                if let c = current { slideRefs.append((c, textBlocks(pending))) }
                current = Int(u32(r.start)); pending = []
            } else {
                pending.append(r)
            }
        }
        if let c = current { slideRefs.append((c, textBlocks(pending))) }
        guard !slideRefs.isEmpty else { throw ConversionError.unsupported("This presentation has no slides.") }

        let writer = PPTXWriter(width: width * 1587 + width / 2, height: height * 1587 + height / 2)
        writer.title = title
        for (ref, outline) in slideRefs {
            guard let o = persist[ref], let slide = record(at: o), slide.type == 0x03EE else { continue }
            let index = writer.addSlide()
            var masterID: UInt32 = 0
            var flags = 7
            if let atom = child(slide, 0x03EF) { masterID = u32(atom.start + 12); flags = u16(atom.start + 20) }
            if let info = child(slide, 0x03F9), info.length >= 12, u16(info.start + 10) & 0x4 != 0 { writer.setHidden(index, true) }
            let master = masters[masterID] ?? masters.values.first
            scheme = (flags & 2 != 0 ? master?.scheme : nil) ?? colorScheme(slide) ?? master?.scheme ?? Self.defaultScheme
            let styles = master?.styles ?? [:]
            var background = flags & 4 != 0 ? master?.background : nil
            // Master objects first (their pictures take the first relationship ids, as on the master).
            if flags & 1 != 0, let master {
                for (data, ext) in master.media { _ = writer.addMedia(index, data: data, ext: ext) }
                for s in master.shapes { writer.addShapeXML(index, renumber(s, writer: writer, slide: index)) }
            }
            if let dg = find(slide, 0xF002).first {
                let (bg, list) = drawing(dg, outline: outline, styles: styles, writer: writer, slide: index, placeholders: true)
                if flags & 4 == 0 || background == nil { background = bg ?? background }
                for s in list { writer.addShapeXML(index, s) }
            }
            if let bg = background { writer.setBackground(index, bg) }
        }
        guard writer.slideCount > 0 else { throw ConversionError.unsupported("None of the slides could be read.") }
        return PPTXMemoryParts(files: writer.parts())
    }

    private func colorScheme(_ r: PPTRecord) -> [PPTXColor]? {
        guard let atom = children(r).first(where: { $0.type == 0x07F0 && $0.length >= 32 }) else { return nil }
        return (0..<8).map { i in
            let p = atom.start + i * 4
            return PPTXColor(r: Double(u8(p)) / 255, g: Double(u8(p + 1)) / 255, b: Double(u8(p + 2)) / 255)
        }
    }

    private func readMaster(_ m: PPTRecord) -> Master {
        let saved = scheme
        scheme = colorScheme(m) ?? Self.defaultScheme
        var styles: [Int: PPTMasterStyle] = [:]
        for atom in children(m) where atom.type == 0x0FA3 { styles[atom.instance] = masterStyle(atom) }
        let probe = PPTXWriter(width: 9_144_000, height: 6_858_000)
        let index = probe.addSlide()
        var bg: String?
        var shapes: [String] = []
        if let dg = find(m, 0xF002).first {
            (bg, shapes) = drawing(dg, outline: [], styles: styles, writer: probe, slide: index, placeholders: false)
        }
        let media = probe.mediaOf(index)
        let master = Master(scheme: scheme, styles: styles, background: bg, shapes: shapes, media: media)
        scheme = saved
        return master
    }

    /// Master shapes were numbered for the probe slide; give them ids and image links on the real slide.
    private func renumber(_ xml: String, writer: PPTXWriter, slide: Int) -> String {
        var out = ""
        var rest = Substring(xml)
        while let r = rest.range(of: #"<p:cNvPr id="\d+""#, options: .regularExpression) {
            out += rest[..<r.lowerBound] + "<p:cNvPr id=\"\(writer.nextID(slide))\""
            rest = rest[r.upperBound...]
        }
        return out + rest
    }

    // MARK: Drawings

    /// Shapes of one OfficeArtDgContainer as PPTX XML, plus the background colour.
    private func drawing(_ dg: PPTRecord, outline: [PPTTextBlock], styles: [Int: PPTMasterStyle], writer: PPTXWriter,
                         slide: Int, placeholders: Bool) -> (String?, [String]) {
        var background: String?
        var shapes: [String] = []
        for c in children(dg) {
            if c.type == 0xF004 {
                // The background shape sits directly in the drawing.
                let p = child(c, 0xF00B).map(props) ?? Props()
                if let fill = p.get(0x0181), let color = officeColor(fill, scheme: scheme) { background = color.hex }
            } else if c.type == 0xF003 {
                let ctx = ShapeContext(outline: outline, styles: styles, writer: writer, slide: slide, placeholders: placeholders)
                for (i, s) in children(c).enumerated() where i > 0 || s.type == 0xF003 {
                    if let xml = shape(s, ctx: ctx, group: nil) { shapes.append(xml) }
                }
            }
        }
        return (background, shapes)
    }

    private struct ShapeContext {
        let outline: [PPTTextBlock]
        let styles: [Int: PPTMasterStyle]
        let writer: PPTXWriter
        let slide: Int
        let placeholders: Bool
    }

    /// Maps a group's child coordinate space onto its anchor.
    private struct GroupSpace {
        var child: CGRect
        var frame: CGRect
        func map(_ r: CGRect) -> CGRect {
            let sx = child.width != 0 ? frame.width / child.width : 1, sy = child.height != 0 ? frame.height / child.height : 1
            return CGRect(x: frame.minX + (r.minX - child.minX) * sx, y: frame.minY + (r.minY - child.minY) * sy,
                          width: r.width * sx, height: r.height * sy)
        }
    }

    private static let presets: [Int: String] = [
        1: "rect", 2: "roundRect", 3: "ellipse", 4: "diamond", 5: "triangle", 6: "rtTriangle", 7: "parallelogram",
        8: "trapezoid", 9: "hexagon", 10: "octagon", 11: "plus", 12: "star5", 13: "rightArrow", 15: "homePlate", 16: "cube",
        20: "line", 21: "plaque", 22: "can", 23: "donut", 32: "straightConnector1", 33: "bentConnector2", 34: "bentConnector3",
        35: "bentConnector4", 36: "bentConnector5", 37: "curvedConnector2", 38: "curvedConnector3", 55: "chevron",
        56: "pentagon", 58: "star8", 59: "star16", 60: "star32", 61: "wedgeRectCallout", 62: "wedgeRoundRectCallout",
        63: "wedgeEllipseCallout", 66: "leftArrow", 67: "downArrow", 68: "upArrow", 69: "leftRightArrow",
        70: "upDownArrow", 71: "irregularSeal1", 72: "irregularSeal2", 73: "lightningBolt", 74: "heart", 75: "rect",
        96: "smileyFace", 109: "flowChartProcess", 110: "flowChartDecision", 111: "flowChartInputOutput",
        112: "flowChartPredefinedProcess", 113: "flowChartInternalStorage", 114: "flowChartDocument",
        115: "flowChartMultidocument", 116: "flowChartTerminator", 117: "flowChartPreparation", 118: "flowChartManualInput",
        119: "flowChartManualOperation", 120: "flowChartConnector", 121: "flowChartPunchedCard", 122: "flowChartPunchedTape",
        123: "flowChartSummingJunction", 124: "flowChartOr", 125: "flowChartCollate", 126: "flowChartSort",
        127: "flowChartExtract", 128: "flowChartMerge", 130: "flowChartOnlineStorage", 131: "flowChartMagneticTape",
        132: "flowChartMagneticDisk", 133: "flowChartMagneticDrum", 134: "flowChartDisplay", 135: "flowChartDelay",
        176: "flowChartAlternateProcess", 177: "flowChartOffpageConnector", 183: "sun", 184: "moon", 185: "bracketPair",
        186: "bracePair", 187: "star4", 188: "doubleWave", 202: "rect",
    ]

    private func anchor(_ c: PPTRecord, group: GroupSpace?) -> CGRect? {
        if let a = child(c, 0xF00F), a.length >= 16 {
            let r = CGRect(x: i32(a.start), y: i32(a.start + 4), width: i32(a.start + 8) - i32(a.start), height: i32(a.start + 12) - i32(a.start + 4))
            return group?.map(r) ?? r
        }
        if let a = child(c, 0xF010) {
            // PowerPoint client anchors are top, left, right, bottom in master units (576 per inch).
            let k: CGFloat = 1587.5
            if a.length >= 16 {
                let t = i32(a.start), l = i32(a.start + 4), r = i32(a.start + 8), bt = i32(a.start + 12)
                return CGRect(x: CGFloat(l) * k, y: CGFloat(t) * k, width: CGFloat(r - l) * k, height: CGFloat(bt - t) * k)
            }
            if a.length >= 8 {
                let t = i16(a.start), l = i16(a.start + 2), r = i16(a.start + 4), bt = i16(a.start + 6)
                return CGRect(x: CGFloat(l) * k, y: CGFloat(t) * k, width: CGFloat(r - l) * k, height: CGFloat(bt - t) * k)
            }
        }
        return nil
    }

    private func shape(_ c: PPTRecord, ctx: ShapeContext, group: GroupSpace?) -> String? {
        if c.type == 0xF003 {
            // Group: the first child carries the group's own anchor and child coordinate space.
            let kids = children(c)
            guard let head = kids.first, head.type == 0xF004, let spgr = child(head, 0xF009), spgr.length >= 16,
                  var frame = anchor(head, group: group) else { return nil }
            let space = CGRect(x: i32(spgr.start), y: i32(spgr.start + 4), width: i32(spgr.start + 8) - i32(spgr.start),
                               height: i32(spgr.start + 12) - i32(spgr.start + 4))
            frame = frame.standardized
            let inner = kids.dropFirst().compactMap { shape($0, ctx: ctx, group: GroupSpace(child: space, frame: frame)) }
            guard !inner.isEmpty else { return nil }
            let id = ctx.writer.nextID(ctx.slide)
            let box = PPTXWriter.xfrm(frame)
            let groupXfrm = box.replacingOccurrences(of: "</a:xfrm>", with: "<a:chOff x=\"\(Int(frame.minX))\" y=\"\(Int(frame.minY))\"/>"
                                                     + "<a:chExt cx=\"\(Int(frame.width))\" cy=\"\(Int(frame.height))\"/></a:xfrm>")
            return "<p:grpSp><p:nvGrpSpPr><p:cNvPr id=\"\(id)\" name=\"Group \(id)\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
                + "<p:grpSpPr>\(groupXfrm)</p:grpSpPr>\(inner.joined())</p:grpSp>"
        }
        guard c.type == 0xF004, let fsp = child(c, 0xF00A) else { return nil }
        let flags = u32(fsp.start + 4)
        if flags & 0x8 != 0 || flags & 0x1 != 0 { return nil }      // deleted / group header
        let type = fsp.instance
        guard var frame = anchor(c, group: group)?.standardized, frame.width >= 0, frame.height >= 0 else { return nil }
        let p = child(c, 0xF00B).map(props) ?? Props()
        let tertiary = child(c, 0xF122).map(props) ?? Props()
        func prop(_ id: Int) -> UInt32? { p.get(id) ?? tertiary.get(id) }

        var rotation = 0.0
        if let r = prop(0x0004) { rotation = Double(Int32(bitPattern: r)) / 65536 }
        var norm = rotation.truncatingRemainder(dividingBy: 360); if norm < 0 { norm += 360 }
        if (norm >= 45 && norm < 135) || (norm >= 225 && norm < 315) {
            // Anchors of shapes turned about a quarter are stored with width and height swapped.
            frame = CGRect(x: frame.midX - frame.height / 2, y: frame.midY - frame.width / 2, width: frame.height, height: frame.width)
        }
        let flipH = flags & 0x40 != 0, flipV = flags & 0x80 != 0
        let xfrm = PPTXWriter.xfrm(frame, rot: rotation, flipH: flipH, flipV: flipV)

        // Placeholder and text.
        var text: PPTTextBlock?
        var placeholderType: Int?
        if let data = child(c, 0xF011) {
            for r in children(data) {
                if r.type == 0x0BC3 { placeholderType = u8(r.start + 4) }
                if r.type == 0x0F9E { let i = i32(r.start); if i >= 0, i < ctx.outline.count { text = ctx.outline[i] } }
            }
        }
        if let box = child(c, 0xF00D) {
            let recs = children(box)
            if let ref = recs.first(where: { $0.type == 0x0F9E }) {
                let i = i32(ref.start); if i >= 0, i < ctx.outline.count { text = ctx.outline[i] }
            } else if let block = textBlocks(recs).first { text = block }
        }
        // Master placeholders are templates; their text is never shown on slides.
        if !ctx.placeholders, placeholderType != nil { return nil }
        let isPlaceholder = placeholderType != nil && placeholderType != 0

        // Fill and line (text boxes and placeholders default to none).
        let plain = type == 202 || isPlaceholder || type == 75
        func boolProp(_ id: Int, bit: Int, useBit: Int, _ fallback: Bool) -> Bool {
            if let v = prop(id) ?? defaultsFOPT[id]?.0, v & (1 << UInt32(useBit)) != 0 { return v & (1 << UInt32(bit)) != 0 }
            return fallback
        }
        let filled = boolProp(0x01BF, bit: 4, useBit: 20, !plain)
        let lined = boolProp(0x01FF, bit: 3, useBit: 19, !plain && type != 75)
        var spPr = xfrm
        var geometry = "<a:prstGeom prst=\"\(Self.presets[type] ?? "rect")\"><a:avLst/></a:prstGeom>"
        if type == 0, let custom = freeform(prop: prop, data: { p.data($0) ?? tertiary.data($0) }, frame: frame) { geometry = custom }
        spPr += geometry
        let isLine = [20, 32, 33, 34, 35, 36, 37, 38].contains(type)
        if !filled || isLine {
            spPr += "<a:noFill/>"
        } else if let v = prop(0x0181) ?? defaultsFOPT[0x0181]?.0, let col = officeColor(v, scheme: scheme) {
            let opacity = prop(0x0182).map { Double($0) / 65536 } ?? 1
            spPr += "<a:solidFill><a:srgbClr val=\"\(col.hex)\">\(opacity < 1 ? "<a:alpha val=\"\(Int(opacity * 100000))\"/>" : "")</a:srgbClr></a:solidFill>"
        } else {
            spPr += "<a:solidFill><a:srgbClr val=\"\(scheme[4].hex)\"/></a:solidFill>"
        }
        if lined {
            let w = Int(prop(0x01CB) ?? 9525)
            let col = (prop(0x01C0) ?? defaultsFOPT[0x01C0]?.0).flatMap { officeColor($0, scheme: scheme) } ?? scheme[1]
            let dashes = ["solid", "sysDash", "sysDot", "dashDot", "lgDashDotDot", "sysDot", "sysDash", "lgDash", "sysDashDot",
                          "lgDashDot", "lgDashDotDot"]
            let dash = prop(0x01CE).map { Int($0) < dashes.count ? dashes[Int($0)] : "solid" } ?? "solid"
            let heads = ["none", "triangle", "stealth", "diamond", "oval", "arrow"]
            func end(_ id: Int, _ tag: String) -> String {
                guard let v = prop(id), v > 0, Int(v) < heads.count else { return "" }
                return "<a:\(tag) type=\"\(heads[Int(v)])\"/>"
            }
            spPr += "<a:ln w=\"\(w)\"><a:solidFill><a:srgbClr val=\"\(col.hex)\"/></a:solidFill><a:prstDash val=\"\(dash)\"/>"
                + end(0x01D0, "headEnd") + end(0x01D1, "tailEnd") + "</a:ln>"
        } else {
            spPr += "<a:ln><a:noFill/></a:ln>"
        }
        let id = ctx.writer.nextID(ctx.slide)

        // Pictures.
        if let pib = prop(0x0104), pib > 0, Int(pib) <= blips.count, let blip = blips[Int(pib) - 1] {
            let rid = ctx.writer.addMedia(ctx.slide, data: blip.data, ext: blip.ext)
            func crop(_ pid: Int) -> Int { prop(pid).map { Int(Double(Int32(bitPattern: $0)) / 65536 * 100000) } ?? 0 }
            let t = crop(0x0100), bt = crop(0x0101), l = crop(0x0102), r = crop(0x0103)
            let src = t != 0 || bt != 0 || l != 0 || r != 0 ? "<a:srcRect l=\"\(l)\" t=\"\(t)\" r=\"\(r)\" b=\"\(bt)\"/>" : ""
            if type == 75 || !filled {
                return "<p:pic><p:nvPicPr><p:cNvPr id=\"\(id)\" name=\"Picture \(id)\"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>"
                    + "<p:blipFill><a:blip r:embed=\"\(rid)\"/>\(src)<a:stretch><a:fillRect/></a:stretch></p:blipFill>"
                    + "<p:spPr>\(xfrm)\(geometry)\(lined ? spPr.components(separatedBy: geometry).last ?? "" : "")</p:spPr></p:pic>"
            }
        }
        if let fillBlip = prop(0x0186), filled, Int(fillBlip) <= blips.count, fillBlip > 0, let blip = blips[Int(fillBlip) - 1],
           (prop(0x0180) ?? 0) >= 2, (prop(0x0180) ?? 0) <= 3 {
            let rid = ctx.writer.addMedia(ctx.slide, data: blip.data, ext: blip.ext)
            spPr = spPr.replacingOccurrences(of: #"<a:solidFill><a:srgbClr val="[0-9A-F]{6}"(/>|>.*?</a:srgbClr>)</a:solidFill>"#,
                                             with: "<a:blipFill><a:blip r:embed=\"\(rid)\"/><a:stretch><a:fillRect/></a:stretch></a:blipFill>",
                                             options: .regularExpression)
        }

        var body = ""
        if let text, !text.text.isEmpty {
            let insets = (prop(0x0081) ?? 91440, prop(0x0082) ?? 45720, prop(0x0083) ?? 91440, prop(0x0084) ?? 45720)
            let anchors = ["t", "ctr", "b", "t", "ctr", "b", "t", "ctr", "b", "t"]
            let anchorValue = prop(0x0087).map { Int($0) < anchors.count ? anchors[Int($0)] : "t" }
                ?? ([0, 6].contains(text.type) ? "ctr" : "t")
            let wrap = prop(0x0085) == 2 ? " wrap=\"none\"" : " wrap=\"square\""
            body = "<p:txBody><a:bodyPr lIns=\"\(insets.0)\" tIns=\"\(insets.1)\" rIns=\"\(insets.2)\" bIns=\"\(insets.3)\"\(wrap) "
                + "anchor=\"\(anchorValue)\" rtlCol=\"0\"><a:noAutofit/></a:bodyPr><a:lstStyle/>\(paragraphs(text, styles: ctx.styles))</p:txBody>"
        } else if type == 202 {
            return nil
        }
        return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"Shape \(id)\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>\(spPr)</p:spPr>"
            + (body.isEmpty ? "<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang=\"en-US\"/></a:p></p:txBody>" : body) + "</p:sp>"
    }

    /// A freeform (shape type 0) from its vertices and segment list, as `a:custGeom`.
    private func freeform(prop: (Int) -> UInt32?, data: (Int) -> [UInt8]?, frame: CGRect) -> String? {
        guard let v = data(0x0145), v.count >= 6 else { return nil }
        func u16(_ a: [UInt8], _ i: Int) -> Int { i + 1 < a.count ? Int(a[i]) | Int(a[i + 1]) << 8 : 0 }
        func s16(_ a: [UInt8], _ i: Int) -> Int { Int(Int16(truncatingIfNeeded: u16(a, i))) }
        func s32(_ a: [UInt8], _ i: Int) -> Int { Int(Int32(bitPattern: UInt32(u16(a, i)) | UInt32(u16(a, i + 2)) << 16)) }
        let count = u16(v, 0), size = u16(v, 4)
        var points: [(Int, Int)] = []
        for k in 0..<count {
            if size == 0xFFF0 || size == 4 {
                let o = 6 + k * 4; guard o + 4 <= v.count else { break }
                points.append((s16(v, o), s16(v, o + 2)))
            } else {
                let o = 6 + k * 8; guard o + 8 <= v.count else { break }
                points.append((s32(v, o), s32(v, o + 4)))
            }
        }
        guard points.count >= 2 else { return nil }
        let left = Int(Int32(bitPattern: prop(0x0140) ?? 0)), top = Int(Int32(bitPattern: prop(0x0141) ?? 0))
        let right = Int(Int32(bitPattern: prop(0x0142) ?? 21600)), bottom = Int(Int32(bitPattern: prop(0x0143) ?? 21600))
        let w = max(1, right - left), h = max(1, bottom - top)
        func pt(_ i: Int) -> String {
            let p = points[min(i, points.count - 1)]
            return "<a:pt x=\"\(p.0 - left)\" y=\"\(p.1 - top)\"/>"
        }
        var path = ""
        var i = 0
        if let segs = data(0x0146), segs.count >= 6 {
            let n = u16(segs, 0), es = u16(segs, 4) == 0xFFF0 ? 2 : max(2, u16(segs, 4))
            for k in 0..<n {
                let s = u16(segs, 6 + k * es)
                let kind = (s >> 13) & 0x7, cnt = max(1, s & 0x1FFF)
                switch kind {
                case 0: for _ in 0..<cnt { path += "<a:lnTo>\(pt(i))</a:lnTo>"; i += 1 }
                case 1: for _ in 0..<cnt { path += "<a:cubicBezTo>\(pt(i))\(pt(i + 1))\(pt(i + 2))</a:cubicBezTo>"; i += 3 }
                case 2: path += "<a:moveTo>\(pt(i))</a:moveTo>"; i += 1
                case 3: path += "<a:close/>"
                default: break
                }
            }
        } else {
            path = "<a:moveTo>\(pt(0))</a:moveTo>" + (1..<points.count).map { "<a:lnTo>\(pt($0))</a:lnTo>" }.joined()
        }
        guard !path.isEmpty else { return nil }
        if !path.hasPrefix("<a:moveTo>") { path = "<a:moveTo>\(pt(0))</a:moveTo>" + path }
        return "<a:custGeom><a:avLst/><a:gdLst/><a:ahLst/><a:cxnLst/><a:rect l=\"l\" t=\"t\" r=\"r\" b=\"b\"/><a:pathLst>"
            + "<a:path w=\"\(w)\" h=\"\(h)\">\(path)</a:path></a:pathLst></a:custGeom>"
    }

    // MARK: Text → DrawingML

    private func paragraphs(_ block: PPTTextBlock, styles: [Int: PPTMasterStyle]) -> String {
        let styleKey: Int
        switch block.type {
        case 0, 6: styleKey = styles[block.type] != nil ? block.type : 0
        case 1, 5, 7, 8: styleKey = styles[block.type] != nil ? block.type : 1
        default: styleKey = 4
        }
        let base = styleKey >= 5 ? (styleKey == 6 ? styles[0] : styles[1]) : nil
        let style = styles[styleKey] ?? []
        let defaults: [Int: (Int, Bool)] = [0: (44, false), 6: (44, false), 1: (32, true), 5: (32, false), 7: (28, true),
                                            8: (24, true), 4: (18, false)]
        let fallbackSize = defaults[block.type]?.0 ?? 18
        let fallbackBullet = defaults[block.type]?.1 ?? false

        let units = Array(block.text.utf16)
        var paraRuns = block.paraRuns
        if paraRuns.isEmpty { paraRuns = [(units.count + 1, 0, PPTParaFormat())] }
        var charRuns = block.charRuns
        if charRuns.isEmpty { charRuns = [(units.count + 1, PPTCharFormat())] }
        func charFormat(at i: Int) -> PPTCharFormat {
            var acc = 0
            for r in charRuns { acc += r.count; if i < acc { return r.format } }
            return charRuns.last?.format ?? PPTCharFormat()
        }
        func paraFormat(at i: Int) -> (Int, PPTParaFormat) {
            var acc = 0
            for r in paraRuns { acc += r.count; if i < acc { return (r.level, r.format) } }
            return (paraRuns.last?.level ?? 0, paraRuns.last?.format ?? PPTParaFormat())
        }
        var xml = ""
        var start = 0
        let total = units.count
        while start <= total {
            var end = start
            while end < total && units[end] != 0x0D { end += 1 }
            let (level, ownPara) = paraFormat(at: start)
            var pf = ownPara
            if level < style.count { pf.fill(from: style[level].0) }
            if let base, level < base.count { pf.fill(from: base[level].0) }
            let bulleted = pf.bullet ?? fallbackBullet
            let marL = bulleted ? 342900 + level * 457200 : level * 457200
            var ppr = "<a:pPr marL=\"\(marL)\" lvl=\"\(level)\" indent=\"\(bulleted ? -342900 : 0)\""
            let aligns = ["l", "ctr", "r", "just", "dist", "thaiDist", "justLow"]
            if let a = pf.align, a < aligns.count { ppr += " algn=\"\(aligns[a])\"" } else if [5, 6].contains(block.type) { ppr += " algn=\"ctr\"" }
            ppr += ">"
            if let ls = pf.lineSpacing, ls != 0 {
                ppr += ls > 0 ? "<a:lnSpc><a:spcPct val=\"\(ls * 1000)\"/></a:lnSpc>" : "<a:lnSpc><a:spcPts val=\"\(-ls * 100 / 8)\"/></a:lnSpc>"
            }
            if let sb = pf.spaceBefore, sb != 0 {
                ppr += sb > 0 ? "<a:spcBef><a:spcPct val=\"\(sb * 1000)\"/></a:spcBef>" : "<a:spcBef><a:spcPts val=\"\(-sb * 100 / 8)\"/></a:spcBef>"
            }
            if let sa = pf.spaceAfter, sa != 0 {
                ppr += sa > 0 ? "<a:spcAft><a:spcPct val=\"\(sa * 1000)\"/></a:spcAft>" : "<a:spcAft><a:spcPts val=\"\(-sa * 100 / 8)\"/></a:spcAft>"
            }
            if bulleted {
                if let c = pf.bulletColor { ppr += "<a:buClr><a:srgbClr val=\"\(c.hex)\"/></a:buClr>" }
                if let s = pf.bulletSize, s >= 25, s <= 400 { ppr += "<a:buSzPct val=\"\(s * 1000)\"/>" }
                if let f = pf.bulletFont, f < fonts.count { ppr += "<a:buFont typeface=\"\(PPTXNode.escape(fonts[f]))\"/>" }
                let ch = pf.bulletChar.flatMap { $0 > 0x1F ? String(utf16CodeUnits: [$0], count: 1) : nil } ?? "•"
                ppr += "<a:buChar char=\"\(PPTXNode.escape(ch))\"/>"
            } else {
                ppr += "<a:buNone/>"
            }
            ppr += "</a:pPr>"
            // Runs: split where the character formatting changes, and at vertical tabs (line breaks).
            var runs = ""
            var i = start
            var lastSize = fallbackSize
            while i < end {
                var j = i
                let f0 = charFormat(at: i)
                while j < end, units[j] != 0x0B, charFormat(at: j).size == f0.size, charFormat(at: j).bold == f0.bold,
                      charFormat(at: j).italic == f0.italic, charFormat(at: j).color == f0.color,
                      charFormat(at: j).font == f0.font, charFormat(at: j).underline == f0.underline { j += 1 }
                if j == i, units[i] == 0x0B {
                    runs += "<a:br><a:rPr lang=\"en-US\" sz=\"\(lastSize * 100)\"/></a:br>"
                    i += 1
                    continue
                }
                var cf = f0
                if level < style.count { cf.fill(from: style[level].1) }
                if let base, level < base.count { cf.fill(from: base[level].1) }
                let size = max(1, min(400, cf.size ?? fallbackSize))
                lastSize = size
                var rpr = "<a:rPr lang=\"en-US\" sz=\"\(size * 100)\""
                if cf.bold == true { rpr += " b=\"1\"" }
                if cf.italic == true { rpr += " i=\"1\"" }
                if cf.underline == true { rpr += " u=\"sng\"" }
                if let pos = cf.position, pos != 0 { rpr += " baseline=\"\(pos * 1000)\"" }
                rpr += ">"
                let color = cf.color ?? ([0, 6].contains(block.type) ? scheme[3] : scheme[1])
                rpr += "<a:solidFill><a:srgbClr val=\"\(color.hex)\"/></a:solidFill>"
                if let f = cf.font, f < fonts.count, !fonts[f].isEmpty { rpr += "<a:latin typeface=\"\(PPTXNode.escape(fonts[f]))\"/>" }
                rpr += "</a:rPr>"
                let text = String(decoding: units[i..<j], as: UTF16.self).replacingOccurrences(of: "\u{0B}", with: "")
                if !text.isEmpty { runs += "<a:r>\(rpr)<a:t>\(PPTXNode.escape(text))</a:t></a:r>" }
                i = j
            }
            xml += "<a:p>\(ppr)\(runs)<a:endParaRPr lang=\"en-US\" sz=\"\(lastSize * 100)\"/></a:p>"
            if end >= total { break }
            start = end + 1
        }
        return xml
    }
}
