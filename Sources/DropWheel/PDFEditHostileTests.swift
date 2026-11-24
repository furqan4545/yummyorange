#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import Foundation
import PDFKit

/// Crafted files for `--selftest pdf-edit` (also alone as `--selftest pdf-edit-hostile`): each must give a clear
/// error or a correct result, never a trap, a hang or a huge allocation. Before the fixes, most of these crashed
/// the whole app (the editor opens files on the main thread), hung, or allocated gigabytes.
extension PDFEditTests {
    static func runHostile() -> String {
        let c = Checker()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-pdfedit-hostile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try hostileFiles(c, dir)
        } catch {
            c.check(false, "error: \(error.localizedDescription)")
        }
        return (c.failed == 0 ? "PASS" : "FAIL") + " pdf-edit-hostile (\(c.count - c.failed)/\(c.count) checks)\n" + c.lines.joined(separator: "\n")
    }

    static let hello = "BT /F1 24 Tf 72 700 Td (Hello World) Tj ET\n"

    /// Raw objects in file order with a classic table (rows for every number up to the largest), so crafted
    /// bytes reach the parser exactly as written.
    static func rawClassic(_ objs: [Int: [UInt8]], size: String? = nil, startxref: String? = nil, extraRows: String = "",
                           trailerExtra: String = "") -> Data {
        var b = Array("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offs: [Int: Int] = [:]
        for n in objs.keys.sorted() { offs[n] = b.count; b += Array("\(n) 0 obj\n".utf8) + objs[n]! + Array("\nendobj\n".utf8) }
        let mx = objs.keys.max() ?? 0
        let start = b.count
        var x = "xref\n0 \(mx + 1)\n"
        for n in 0...mx { x += offs[n].map { String(format: "%010d 00000 n \n", $0) } ?? (n == 0 ? "0000000000 65535 f \n" : "0000000000 00000 f \n") }
        x += extraRows
        x += "trailer\n<< /Size \(size ?? String(mx + 1)) /Root 1 0 R \(trailerExtra)>>\nstartxref\n\(startxref ?? String(start))\n%%EOF\n"
        return Data(b + Array(x.utf8))
    }

    static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    static func flateStream(_ content: [UInt8], dict: String = "") -> [UInt8] {
        let z = PDFFilters.deflate(content)
        return bytes("<< /Filter /FlateDecode \(dict) /Length \(z.count) >>\nstream\n") + z + bytes("\nendstream")
    }

    /// Catalog, one page with Helvetica as /F1, and `content` as its only content stream.
    static func onePage(_ content: String = hello, contentObject: [UInt8]? = nil, pageExtra: String = "", font: String = helvetica) -> [Int: [UInt8]] {
        [1: bytes("<< /Type /Catalog /Pages 2 0 R >>"),
         2: bytes("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
         3: bytes("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R \(pageExtra)>>"),
         4: contentObject ?? flateStream(bytes(content)),
         5: bytes(font)]
    }

    /// A hybrid file: a complete classic table for `objs` (minus `tableFree`), plus an /XRefStm with the given rows.
    static func rawHybrid(_ objs: [Int: [UInt8]], index: [Int], rows: [UInt8], tableFree: Set<Int> = []) -> Data {
        var b = Array("%PDF-1.5\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offs: [Int: Int] = [:]
        for n in objs.keys.sorted() { offs[n] = b.count; b += Array("\(n) 0 obj\n".utf8) + objs[n]! + Array("\nendobj\n".utf8) }
        let z = PDFFilters.deflate(rows)
        let xs = b.count
        b += bytes("20 0 obj\n<< /Type /XRef /Size 21 /W [1 4 2] /Index [\(index.map(String.init).joined(separator: " "))] /Filter /FlateDecode /Length \(z.count) >>\nstream\n") + z + bytes("\nendstream\nendobj\n")
        let start = b.count
        let mx = objs.keys.max() ?? 0
        var x = "xref\n0 \(mx + 1)\n"
        for n in 0...mx {
            if let o = offs[n], !tableFree.contains(n) { x += String(format: "%010d 00000 n \n", o) } else { x += n == 0 ? "0000000000 65535 f \n" : "0000000000 00000 f \n" }
        }
        x += "trailer\n<< /Size 21 /Root 1 0 R /XRefStm \(xs) >>\nstartxref\n\(start)\n%%EOF\n"
        return Data(b + Array(x.utf8))
    }

    static func xrow(_ t: UInt8, _ a: Int, _ g: Int) -> [UInt8] {
        [t, UInt8(a >> 24 & 0xFF), UInt8(a >> 16 & 0xFF), UInt8(a >> 8 & 0xFF), UInt8(a & 0xFF), UInt8(g >> 8 & 0xFF), UInt8(g & 0xFF)]
    }

    /// Runs `body` and reports how long it took, for the "no hang" checks.
    static func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
        let t0 = Date()
        let r = try body()
        return (r, Date().timeIntervalSince(t0))
    }

    static func hostileFiles(_ c: Checker, _ dir: URL) throws {
        c.section("hostile files")

        // Numbers too large for Int where an integer belongs (Int(1e20) traps).
        let hugeXref = rawClassic(onePage(), extraRows: "99999999999999999999 1\n0000000009 00000 n \n")
        let f1 = try? PDFObjectFile(hugeXref)
        c.check(f1?.pages().count == 1, "huge numbers: an xref subsection numbered 99999999999999999999 doesn’t trap (\(f1.map { $0.rebuilt ? "rebuilt" : "read" } ?? "refused"))")
        let f2 = try? PDFObjectFile(rawClassic(onePage(), startxref: "99999999999999999999"))
        c.check(f2?.rebuilt == true && f2?.pages().count == 1, "huge numbers: startxref 99999999999999999999 rebuilds by scanning")
        let f3 = try? PDFObjectFile(rawClassic(onePage(pageExtra: "/Foo 99999999999999999999 0 R /Bar +nan /Baz -inf ")))
        c.check(f3?.pages().first.map { $0.dict["Foo"]?.ref == nil } == true, "huge numbers: “99999999999999999999 0 R” isn’t a reference, “+nan” and “-inf” aren’t numbers")
        var lx = PDFLexer(bytes("1e400 -1e400 0x1p3 +nan 12.5"))
        let toks = (0..<5).map { _ in lx.next().0 }
        let finite = toks.prefix(2).allSatisfy { if case .number(let d, _) = $0 { return d.isFinite }; return false }
        let words = toks[2...3].allSatisfy { if case .keyword = $0 { return true }; return false }
        c.check(finite && words && toks[4] == .number(12.5, "12.5"), "lexer: 1e400 is clamped to a finite number; 0x1p3 and +nan are keywords")

        // /Length references that loop (4 → 6 → 4) recursed until the stack overflowed.
        var lc = onePage()
        lc[4] = bytes("<< /Length 6 0 R >>\nstream\n\(hello)\nendstream")
        lc[6] = bytes("<< /Length 4 0 R >>\nstream\nabc\nendstream")
        let lcData = rawClassic(lc)
        let f4 = try? PDFObjectFile(lcData)
        c.check(f4.flatMap { try? $0.decodedStream(4) }.map { String(decoding: $0, as: UTF8.self).contains("Hello World") } == true,
                "indirect /Length loop (4 → 6 → 4): the stream is still read up to endstream")
        let s4 = try session(lcData, "length-loop.pdf", dir)
        if let id = line(s4, "Hello World") {
            try s4.setText("Hello There", for: id)
            let out = try s4.save()
            c.check(text(try Data(contentsOf: out), 0).contains("Hello There"), "indirect /Length loop: the edit saves and reads back")
        } else { c.check(false, "indirect /Length loop: line found") }

        // Object streams that hold each other (font 5 in 10, 10 in 11, 11 in 10), in a hybrid file PDFKit opens.
        let cyc = rawHybrid(onePage(), index: [5, 1, 10, 2], rows: xrow(2, 10, 0) + xrow(2, 11, 0) + xrow(2, 10, 0), tableFree: [5])
        let f5 = try? PDFObjectFile(cyc)
        c.check(f5 != nil && f5?.object(5) == nil && f5?.object(10) == nil, "object streams that contain each other: no recursion, the objects are unreadable")
        if PDFDocument(data: cyc) != nil {
            let s5 = try session(cyc, "objstm-cycle.pdf", dir)
            let n = s5.lines(page: 0).count
            c.check(n >= 0, "object stream cycle: the session reads the page without recursing (\(n) lines)")
        }

        // An /XRefStm whose /Index claims 600 million entries with no row data.
        var idx: [Int] = []
        for k in 0..<60 { idx += [100 + k * 10_000_000, 9_999_999] }
        let (f6, t6) = timed { try? PDFObjectFile(rawHybrid(onePage(), index: idx, rows: [])) }
        c.check(f6 != nil && (f6?.objectNumbers.count ?? 99) < 100 && t6 < 2,
                "xref stream /Index of 600 million entries and no data: \(f6?.objectNumbers.count ?? -1) objects in \(PDFNumber.format((t6 * 1000).rounded())) ms")
        let w0 = rawHybrid(onePage(), index: [0, 9_999_999], rows: []).replacingOccurrences(of: "/W [1 4 2]", with: "/W [0 0 0]")
        let (f7, t7) = timed { try? PDFObjectFile(w0) }
        c.check((f7?.objectNumbers.count ?? 0) < 100 && t7 < 2, "xref stream /W [0 0 0] is refused (\(PDFNumber.format((t7 * 1000).rounded())) ms)")

        // Deep nesting (100000 arrays) in a page dictionary and in a TJ array; an object stream with a negative
        // /First and a member offset far past its data.
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        let (f8, t8) = timed { try? PDFObjectFile(rawClassic(onePage("BT /F1 24 Tf 72 700 Td \(deep) TJ ET\n" + hello, pageExtra: "/Deep \(deep) "))) }
        let deepRuns = f8.map { PDFPageContent(file: $0, page: $0.pages()[0], fonts: PDFEditFontCache($0)).lines.map(\.text) } ?? []
        c.check(deepRuns.contains("Hello World") && t8 < 5, "100000 nested arrays: parsed without overflowing the stack (\(PDFNumber.format((t8 * 1000).rounded())) ms)")
        var bad = onePage()
        let cat = bad.removeValue(forKey: 1)!
        bad[10] = bytes("<< /Type /ObjStm /N 1 /First -5 /Length \(9 + cat.count) >>\nstream\n1 999999 ") + cat + bytes("\nendstream")
        let badOffsets = rawHybrid(bad, index: [1, 1], rows: xrow(2, 10, 0))
        var badResult = "parsed"
        do { _ = try PDFObjectFile(badOffsets).pages() } catch { badResult = error.localizedDescription }
        c.check(!badResult.isEmpty, "object stream with /First -5 and an offset past its data: no trap (\(badResult))")

        // Predictors: a TIFF row cut short traps on a reversed range; absurd /Columns allocate a terabyte.
        let tiff = try? PDFFilters.unpredict(Array(repeating: 7, count: 44), parms: PDFDict([("Predictor", .integer(2)), ("Colors", .integer(3)), ("Columns", .integer(1))]))
        c.check(tiff?.count == 44, "TIFF predictor: a short last row is left as it is")
        var threw = false
        do { _ = try PDFFilters.unpredict(Array(repeating: 0, count: 64), parms: PDFDict([("Predictor", .integer(12)), ("Columns", .integer(999_999_999_999))])) } catch { threw = true }
        c.check(threw, "PNG predictor: /Columns 999999999999 is refused instead of allocating")
        threw = false
        do { _ = try PDFFilters.unpredict(Array(repeating: 0, count: 64), parms: PDFDict([("Predictor", .integer(12)), ("Columns", .integer(99_999_999_999_999)), ("Colors", .integer(99_999_999_999_999)), ("BitsPerComponent", .integer(16))])) } catch { threw = true }
        c.check(threw, "PNG predictor: a row size that overflows Int is refused")

        // Decompression bombs, with the per-stream limit lowered to 1 MB so the test stays small.
        let savedLimit = PDFFilters.maxDecodedBytes
        PDFFilters.maxDecodedBytes = 1 << 20
        defer { PDFFilters.maxDecodedBytes = savedLimit }
        let bomb = PDFFilters.deflate(bytes(hello) + Array(repeating: 32, count: 4 << 20))
        let bombFile = rawClassic(onePage(contentObject: bytes("<< /Filter /FlateDecode /Length \(bomb.count) >>\nstream\n") + bomb + bytes("\nendstream")))
        var bombError = ""
        do { _ = try PDFObjectFile(bombFile).decodedStream(4) } catch { bombError = error.localizedDescription }
        c.check(bombError.contains("expands to more than 1 MB"), "Flate bomb: \(bomb.count) bytes expanding to 4 MB stop at the limit (“\(bombError)”)")
        // Inflate itself stops at the limit (it never holds the whole expansion), not only the check after it.
        var stopped = false
        do { _ = try PDFFilters.inflate(bomb, limit: 1 << 20) } catch { stopped = "\(error)".contains("expands") || error.localizedDescription.contains("expands") }
        c.check(stopped, "Flate bomb: inflate stops while decoding, at the limit")
        let twice = PDFFilters.deflate(bomb)
        bombError = ""
        do {
            _ = try PDFObjectFile(rawClassic(onePage(contentObject: bytes("<< /Filter [/FlateDecode /FlateDecode] /Length \(twice.count) >>\nstream\n") + twice + bytes("\nendstream")))).decodedStream(4)
        } catch { bombError = error.localizedDescription }
        c.check(bombError.contains("expands to more than"), "double Flate bomb stops at the limit")
        let rl = [UInt8]((0..<20_000).flatMap { _ in [UInt8(129), 32] })
        c.check((try? PDFFilters.runLength(rl)) == nil, "RunLength bomb (\(rl.count) bytes → 2.5 MB) stops at the limit")
        let small = try? PDFFilters.inflate(PDFFilters.deflate(Array(repeating: 65, count: 500_000)))
        c.check(small?.count == 500_000, "Flate under the limit still decodes")
        PDFFilters.maxDecodedBytes = savedLimit
        c.check(PDFFilters.maxDecodedBytes <= 256 << 20 && PDFObjectFile.maxTotalDecodedBytes <= 1 << 30, "limits: \(PDFFilters.maxDecodedBytes >> 20) MB per stream, \(PDFObjectFile.maxTotalDecodedBytes >> 20) MB per file")
        // The editor's error says why the text can't be found.
        PDFFilters.maxDecodedBytes = 1 << 20
        let sb = try session(bombFile, "bomb.pdf", dir)
        let msg = PDFEditTool.notFound("Hello World", page: nil, session: sb).localizedDescription
        PDFFilters.maxDecodedBytes = savedLimit
        c.check(msg.contains("Page 1 couldn’t be read") && msg.contains("expands to more than"), "Flate bomb: the command line says why (“\(msg)”)")

        // Form fan-out: each level draws the next 40 times, 5 levels deep (40⁵ draws).
        var fan = onePage("q " + String(repeating: "/X1 Do ", count: 40) + "Q\n" + hello)
        fan[3] = bytes("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> /XObject << /X1 10 0 R >> >> /Contents 4 0 R >>")
        for lvl in 1...5 {
            let body = lvl < 5 ? String(repeating: "/X\(lvl + 1) Do ", count: 40) : "0 0 m 1 1 l S"
            let res = lvl < 5 ? "/Resources << /XObject << /X\(lvl + 1) \(10 + lvl) 0 R >> >>" : ""
            fan[9 + lvl] = bytes("<< /Type /XObject /Subtype /Form /BBox [0 0 612 792] \(res) /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream")
        }
        let sf = try session(rawClassic(fan), "fanout.pdf", dir)
        let (fanLines, tf) = timed { sf.lines(page: 0) }
        let fanID = fanLines.firstIndex { $0.text.contains("Hello World") }.map { PDFLineID(page: 0, line: $0) }
        c.check(tf < 10 && fanID.map { sf.availability($0) == .readOnly(PDFPageContent.tooComplexMessage) } == true,
                "form fan-out (40⁵ draws): stops at the budget in \(PDFNumber.format((tf * 1000).rounded())) ms and says the page is too complex")

        // Content-stream numbers: a render mode of 1e99 or +nan, and a 1e300 pt font.
        for (what, content) in [("1e99 Tr", "BT /F1 24 Tf 1e99 Tr 72 700 Td (Hello World) Tj ET\n"), ("+nan Tr", "BT /F1 24 Tf +nan Tr 72 700 Td (Hello World) Tj ET\n"),
                                ("+nan cm", "q +nan 0 0 1 0 0 cm \(hello) Q\n")] {
            let s = try session(rawClassic(onePage(content)), "tr.pdf", dir)
            c.check(line(s, "Hello World") != nil, "content “\(what)”: the line is read without trapping")
        }
        let sHuge = try session(rawClassic(onePage("BT /F1 1e300 Tf 72 700 Td (Hello World) Tj ET\n" + "BT /F1 12 Tf 72 600 Td (Normal line) Tj ET\n")), "huge-size.pdf", dir)
        c.check(line(sHuge, "Hello World") == nil && line(sHuge, "Normal line") != nil, "a 1e300 pt font: that text is left out (it can’t be on the page), the rest reads")
        let inkRect = CGRect(x: 1e300, y: 1e300, width: 1e299, height: 1e299)
        if let page = PDFDocument(data: rawClassic(onePage()))?.page(at: 0)?.pageRef {
            c.check(PDFEditVerify.glyphsWithoutInk(page, [inkRect, .infinite]) == 2, "gate: a glyph box at 1e300 pt counts as missing ink instead of trapping")
        }

        // Fonts: /FirstChar and CID /W starts beyond UInt32.
        let fc = try session(rawClassic(onePage(font: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 99999999999 /Widths [500 500] >>")), "firstchar.pdf", dir)
        c.check(line(fc, "Hello World") != nil, "font /FirstChar 99999999999: read without trapping")
        var cid = onePage("BT /F1 24 Tf 72 700 Td <00480065> Tj ET\n", font: "<< /Type /Font /Subtype /Type0 /BaseFont /Foo /Encoding /Identity-H /DescendantFonts [7 0 R] >>")
        cid[7] = bytes("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Foo /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /W [1e300 [500] 70000 70010 500 -9 -2 500] >>")
        let cf = try PDFObjectFile(rawClassic(cid))
        c.check(PDFEditFontCache(cf).font(.ref(5, 0), holder: "t")?.kind == .type0, "CID font /W [1e300 […]]: read without trapping")

        // Inline image data that contains " EI (" — the text after it was swallowed into a string.
        let inl = "q 8 0 0 1 72 600 cm BI /W 8 /H 1 /CS /G /BPC 8 ID A EI (BC\nEI Q\n" + hello
        let si = try session(rawClassic(onePage(inl)), "inline-ei.pdf", dir)
        c.check(line(si, "Hello World") != nil, "inline image whose data holds “ EI (”: the text after it is still found")
        if let id = line(si, "Hello World") {
            try si.setText("Hello There", for: id)
            let out = try Data(contentsOf: try si.save())
            c.check(text(out, 0).contains("Hello There"), "inline image: the edit after it saves and reads back")
        }

        // A hybrid file whose object 6 (in an object stream) was deleted by a later update: it stays deleted, and
        // "Remove replaced text" doesn't write it back.
        let member = bytes("(SECRET-OLD-TEXT)"), head = bytes("6 0 ")
        var hd = onePage()
        hd[10] = flateStream(head + member, dict: "/Type /ObjStm /N 1 /First \(head.count)")
        var hb = Data(rawHybrid(hd, index: [6, 1], rows: xrow(2, 10, 0)))
        let prevStart = Int(String(decoding: hb.suffix(30), as: UTF8.self).components(separatedBy: "startxref\n").last!.components(separatedBy: "\n").first!)!
        let start2 = hb.count
        hb += Data("xref\n0 1\n0000000006 65535 f \n6 1\n0000000000 00001 f \ntrailer\n<< /Size 21 /Root 1 0 R /Prev \(prevStart) >>\nstartxref\n\(start2)\n%%EOF\n".utf8)
        let fd = try PDFObjectFile(hb)
        c.check(fd.entry(6)?.kind == .free && fd.object(6) == nil, "hybrid file: an object deleted by a later update stays deleted (entry \(String(describing: fd.entry(6)?.kind)))")
        let sd = try session(hb, "deleted.pdf", dir)
        sd.removeReplacedText = true
        if let id = line(sd, "Hello World") {
            try sd.setText("Hello There", for: id)
            let out = try Data(contentsOf: try sd.save())
            c.check(out.range(of: Data("SECRET-OLD".utf8)) == nil && text(out, 0).contains("Hello There"),
                    "Remove replaced text: the deleted object isn’t written back")
        } else { c.check(false, "deleted object: line found") }
        try verifierFiles(c, dir)
    }
}

private extension Data {
    func replacingOccurrences(of a: String, with b: String) -> Data {
        guard let r = range(of: Data(a.utf8)) else { return self }
        var d = self
        d.replaceSubrange(r, with: Data(b.utf8))
        return d
    }
}
#endif
