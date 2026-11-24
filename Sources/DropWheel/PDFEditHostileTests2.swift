#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import Foundation
import PDFKit

/// More crafted files for `--selftest pdf-edit` / `pdf-edit-hostile`, found by the second review: negative
/// cross-reference fields, CMap numbers past UInt32, streams that all run to one "endstream", a live object numbered
/// 999,999,999 under "Remove replaced text", pages of hundreds of thousands of show operators, and a PNG predictor of
/// one byte per row. Before the fixes each crashed, hung or took gigabytes.
extension PDFEditTests {
    /// Objects in file order with a table of one subsection per run of consecutive numbers.
    static func rawSparse(_ objs: [Int: [UInt8]]) -> Data {
        var b = Array("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offs: [Int: Int] = [:]
        for n in objs.keys.sorted() { offs[n] = b.count; b += Array("\(n) 0 obj\n".utf8) + objs[n]! + Array("\nendobj\n".utf8) }
        let start = b.count
        var x = "xref\n0 1\n0000000000 65535 f \n"
        var groups: [[Int]] = []
        for n in objs.keys.sorted() { if let l = groups.last?.last, l + 1 == n { groups[groups.count - 1].append(n) } else { groups.append([n]) } }
        for g in groups { x += "\(g[0]) \(g.count)\n" + g.map { String(format: "%010d 00000 n \n", offs[$0]!) }.joined() }
        x += "trailer\n<< /Size \((objs.keys.max() ?? 0) + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
        return Data(b + Array(x.utf8))
    }

    /// An xref-stream file (no table) with rows for the given objects only.
    static func rawXrefStream(_ objs: [Int: [UInt8]], size: Int) -> Data {
        var b = Array("%PDF-1.5\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offs: [Int: Int] = [:]
        for n in objs.keys.sorted() { offs[n] = b.count; b += Array("\(n) 0 obj\n".utf8) + objs[n]! + Array("\nendobj\n".utf8) }
        let xn = (objs.keys.max() ?? 0) + 1
        let start = b.count
        offs[xn] = start
        var rows = xrow(0, 0, 65535), index: [Int] = [0, 1]
        var groups: [[Int]] = []
        for n in offs.keys.sorted() { if let l = groups.last?.last, l + 1 == n { groups[groups.count - 1].append(n) } else { groups.append([n]) } }
        for g in groups { index += [g[0], g.count]; for n in g { rows += xrow(1, offs[n]!, 0) } }
        let z = PDFFilters.deflate(rows)
        b += bytes("\(xn) 0 obj\n<< /Type /XRef /Size \(size) /Root 1 0 R /W [1 4 2] /Index [\(index.map(String.init).joined(separator: " "))] /Filter /FlateDecode /Length \(z.count) >>\nstream\n") + z + bytes("\nendstream\nendobj\n")
        b += bytes("startxref\n\(start)\n%%EOF\n")
        return Data(b)
    }

    /// The PNG predictor as it was first written (an array per row), to check the in-place version against.
    static func referenceUnpredict(_ d: [UInt8], row: Int, bpp: Int) -> [UInt8] {
        var out: [UInt8] = []
        var prev = [UInt8](repeating: 0, count: row)
        var i = 0
        while i < d.count {
            let type = d[i]
            var cur = Array(d[(i + 1)..<min(d.count, i + 1 + row)])
            if cur.count < row { cur += [UInt8](repeating: 0, count: row - cur.count) }
            for k in 0..<row {
                let a = k >= bpp ? Int(cur[k - bpp]) : 0, up = Int(prev[k]), c = k >= bpp ? Int(prev[k - bpp]) : 0
                var x = Int(cur[k])
                switch type {
                case 1: x += a
                case 2: x += up
                case 3: x += (a + up) / 2
                case 4:
                    let pp = a + up - c, pa = abs(pp - a), pb = abs(pp - up), pc = abs(pp - c)
                    x += (pa <= pb && pa <= pc) ? a : (pb <= pc ? up : c)
                default: break
                }
                cur[k] = UInt8(x & 0xFF)
            }
            out += cur
            prev = cur
            i += row + 1
        }
        return out
    }

    static func verifierFiles(_ c: Checker, _ dir: URL) throws {
        c.section("hostile files (second review)")

        // 1. /XRefStm rows whose 8-byte fields have the top bit set wrap to -1: an offset of -1 (object 6) and an
        //    object-stream index of -1 (font 5) indexed arrays at -1 and trapped while the file opened.
        let negOffset = rawHybrid(onePage(), index: [6, 1], rows: [1] + Array(repeating: 0xFF, count: 8) + [0, 0])
            .replacingOccurrences(of: "/W [1 4 2]", with: "/W [1 8 2]")
        let fo = try? PDFObjectFile(negOffset)
        c.check(fo != nil && fo?.object(6) == nil && fo?.pages().count == 1, "xref stream offset 0xFFFFFFFFFFFFFFFF (−1): ignored, no trap")
        let so = try session(negOffset, "neg-offset.pdf", dir)
        if let id = line(so, "Hello World") {
            try so.setText("Hello There", for: id)
            c.check(text(try Data(contentsOf: try so.save()), 0).contains("Hello There"), "xref stream offset −1: the file still edits and saves")
        } else { c.check(false, "xref stream offset −1: line found") }
        var ni = onePage()
        let memberHead = bytes("5 0 ")
        ni[7] = flateStream(memberHead + bytes(helvetica), dict: "/Type /ObjStm /N 1 /First \(memberHead.count)")
        let negIndex = rawHybrid(ni, index: [5, 1], rows: Array(xrow(2, 7, 0).prefix(5)) + Array(repeating: 0xFF, count: 8), tableFree: [5])
            .replacingOccurrences(of: "/W [1 4 2]", with: "/W [1 4 8]")
        let fi = try? PDFObjectFile(negIndex)
        c.check(fi != nil && fi?.object(5) == nil, "xref stream object-stream index −1: ignored, no trap")

        // 2. CMaps with numbers past UInt32: a CID of 99999999999, a CID range starting at 4294967295, and a
        //    bfrange array starting at <FFFFFFFF> (its counter overflowed). Each trapped.
        func cmap(_ body: String) -> PDFSVGCMap {
            PDFSVGCMap(Data("/CIDInit /ProcSet findresource begin 12 dict begin begincmap 1 begincodespacerange <0000> <FFFF> endcodespacerange \(body) endcmap end end".utf8))
        }
        let m1 = cmap("1 begincidchar <0048> 99999999999 endcidchar")
        let m2 = cmap("1 begincidrange <0000> <00FF> 4294967295 endcidrange")
        let m3 = cmap("1 beginbfrange <FFFFFFFF> <FFFFFFFF> [<0041> <0042>] endbfrange")
        c.check(m1.cids[0x48] == UInt32.max && m2.cids[0] == UInt32.max && m2.cids[0xFF] == UInt32.max && m3.unicode[0xFFFF_FFFF] == "A" && m3.unicode.count == 1,
                "CMap: CID 99999999999, a CID range from 4294967295 and a bfrange array at <FFFFFFFF> are clamped, no trap")
        var t0 = onePage("BT /F1 24 Tf 72 700 Td <0048> Tj ET\n" + hello.replacingOccurrences(of: "/F1", with: "/F2"))
        t0[3] = bytes("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 6 0 R /F2 5 0 R >> >> /Contents 4 0 R >>")
        let cm = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap 1 begincodespacerange <0000> <FFFF> endcodespacerange 1 begincidchar <0048> 99999999999 endcidchar endcmap end end"
        t0[8] = bytes("<< /Type /CMap /Length \(cm.utf8.count) >>\nstream\n\(cm)\nendstream")
        t0[6] = bytes("<< /Type /Font /Subtype /Type0 /BaseFont /Foo /Encoding 8 0 R /DescendantFonts [7 0 R] >>")
        t0[7] = bytes("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Foo /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> >>")
        let st0 = try session(rawClassic(t0), "cmap-cid.pdf", dir)
        c.check(line(st0, "Hello World") != nil, "CMap CID 99999999999 in a page’s font: the page reads")

        // 3. Streams with no usable /Length: 4,000 content streams and no "endstream" after them searched the rest of
        //    the file once each (quadratic); 3,000 streams whose /Length all reach one "endstream" at the end copied
        //    the rest of the file once each.
        var ne = onePage()
        var refs: [String] = []
        for k in 0..<4000 { ne[100 + k] = bytes("<< >> stream\nq Q\n"); refs.append("\(100 + k) 0 R") }
        ne[3] = bytes("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents [4 0 R \(refs.joined(separator: " "))] >>")
        let neData = rawClassic(ne)
        let (neLines, tne) = timed { () -> Int in
            guard let f = try? PDFObjectFile(neData) else { return -1 }
            return PDFPageContent(file: f, page: f.pages()[0], fonts: PDFEditFontCache(f)).lines.count
        }
        c.check(neLines == 1 && tne < 1.5, "4,000 streams without “endstream”: read in \(PDFNumber.format((tne * 1000).rounded())) ms (\(neLines) line)")
        // Overlapping streams: object k's /Length runs from its own data to the one "endstream" at the very end.
        let count = 3000
        var head = Array("%PDF-1.4\n".utf8)
        var offs: [Int] = []
        let lineLen = "100000 0 obj\n<< /Length 0000000000 >> stream\n".utf8.count
        let dataEnd = head.count + count * lineLen
        for k in 0..<count {
            offs.append(head.count)
            let dataStart = head.count + lineLen
            head += Array("\(100_000 + k) 0 obj\n<< /Length \(String(format: "%010d", dataEnd - dataStart)) >> stream\n".utf8)
        }
        head += Array("\nendstream\nendobj\n".utf8)
        let ov = onePage()
        var body = head
        var objOffs: [Int: Int] = [:]
        for n in ov.keys.sorted() { objOffs[n] = body.count; body += Array("\(n) 0 obj\n".utf8) + ov[n]! + Array("\nendobj\n".utf8) }
        let xs = body.count
        var x = "xref\n0 6\n0000000000 65535 f \n" + (1...5).map { String(format: "%010d 00000 n \n", objOffs[$0]!) }.joined()
        x += "100000 \(count)\n" + offs.map { String(format: "%010d 00000 n \n", $0) }.joined()
        x += "trailer\n<< /Size \(100_000 + count) /Root 1 0 R >>\nstartxref\n\(xs)\n%%EOF\n"
        body += Array(x.utf8)
        let ovData = Data(body)
        let (copied, tov) = timed { () -> Int in
            guard let f = try? PDFObjectFile(ovData) else { return -1 }
            for k in 0..<count { _ = f.object(100_000 + k) }
            return f.copiedStreamBytes
        }
        c.check(copied >= 0 && copied <= 3 * ovData.count + (64 << 20) && tov < 3,
                "\(count) streams that all end at one “endstream”: \(copied >> 20) MB copied (not \((lineLen * count * (count - 1) / 2) >> 20) MB) in \(PDFNumber.format((tov * 1000).rounded())) ms")

        // 4. "Remove replaced text" with a live object numbered 999,999,999: the rewrite wrote a row for every number
        //    below it (gigabytes). Now the table has subsections; the same for an xref-stream file with /Size 10^12.
        var sp = onePage()
        sp[999_999_999] = bytes("<< /Foo (far) >>")
        let spData = rawSparse(sp)
        let (compact, tc) = timed { PDFCompactWriter.rewrite(try! PDFObjectFile(spData)) }
        let cf = try? PDFObjectFile(compact)
        c.check(compact.count < 64 << 10 && tc < 2 && cf?.rebuilt == false && cf?.object(999_999_999)?.value.dict?["Foo"] != nil
                && PDFDocument(data: compact)?.pageCount == 1,
                "Remove replaced text, object 999,999,999: \(compact.count) bytes in \(PDFNumber.format((tc * 1000).rounded())) ms, reads back")
        let ssp = try session(spData, "sparse.pdf", dir)
        ssp.removeReplacedText = true
        if let id = line(ssp, "Hello World") {
            try ssp.setText("Hello There", for: id)
            let out = try Data(contentsOf: try ssp.save())
            c.check(text(out, 0).contains("Hello There") && out.count < 64 << 10, "Remove replaced text, object 999,999,999: the edit saves through the gate")
        } else { c.check(false, "sparse: line found") }
        let xsData = rawXrefStream(onePage(), size: 1_000_000_000_000)
        if let xf = try? PDFObjectFile(xsData), !xf.rebuilt {
            let (xc, txc) = timed { PDFCompactWriter.rewrite(xf) }
            let back = try? PDFObjectFile(xc)
            c.check(xc.count < 64 << 10 && txc < 2 && back?.rebuilt == false && back?.pages().count == 1,
                    "Remove replaced text, xref-stream file with /Size 10¹²: \(xc.count) bytes, reads back")
        } else { c.check(false, "xref-stream /Size 10¹²: the file reads") }
        // Dense files keep one subsection (the byte-for-byte compaction checks above cover their layout).
        let dense = PDFCompactWriter.rewrite(try PDFObjectFile(rawClassic(onePage())))
        c.check(String(decoding: dense, as: UTF8.self).contains("xref\n0 6\n"), "Remove replaced text, ordinary file: one “0 6” subsection as before")

        // 5. Content within the decoding limit that multiplies into runs: tens of millions of "(A) Tj" from a few
        //    hundred KB reached 3.6 GB. The budget is lowered here so the test stays small.
        let savedItems = PDFPageContent.maxItems
        PDFPageContent.maxItems = 3_000
        defer { PDFPageContent.maxItems = savedItems }
        let many = "BT /F1 1 Tf 72 100 Td " + String(repeating: "(A) Tj ", count: 2_000) + "ET\n"
        let sm = try session(rawClassic(onePage(hello + many)), "many-runs.pdf", dir)
        let mid = line(sm, "Hello World")
        c.check(mid.map { sm.availability($0) == .readOnly(PDFPageContent.tooMuchMessage) } == true && sm.content(page: 0).runs.count < 1_100,
                "2,000 show operators over a budget of 3,000 items: stops (\(sm.content(page: 0).runs.count) runs) and the page is read-only")
        let tjArray = "BT /F1 1 Tf 72 100 Td [" + String(repeating: "1 ", count: 5_000) + "(A)] TJ ET\n"
        let sa = try session(rawClassic(onePage(hello + tjArray)), "tj-array.pdf", dir)
        c.check(line(sa, "Hello World").map { sa.availability($0) == .readOnly(PDFPageContent.tooMuchMessage) } == true,
                "a TJ array of 5,000 elements over the budget: the page is read-only")
        PDFPageContent.maxItems = savedItems
        let sn = try session(rawClassic(onePage(hello + many)), "many-runs-ok.pdf", dir)
        c.check(line(sn, "Hello World").map { sn.availability($0) } == .editable, "the same page under the normal budget stays editable")
        // One line of 60,000 runs: joining runs into a line copied the line's units for each run (quadratic).
        let longLine = "BT /F1 1 Tf 72 100 Td " + String(repeating: "(A) Tj ", count: 60_000) + "ET\n"
        let (longCount, tl) = timed { () -> Int in
            guard let f = try? PDFObjectFile(rawClassic(onePage(longLine))) else { return -1 }
            return PDFPageContent(file: f, page: f.pages()[0], fonts: PDFEditFontCache(f)).lines.first?.units.count ?? -1
        }
        c.check(longCount == 60_000 && tl < 4, "one line of 60,000 runs: built in \(PDFNumber.format((tl * 1000).rounded())) ms")

        // 6. PNG predictor, /Columns 1 (two bytes per row) on 4 MB: an array per row; now in place, same result.
        var rng = SystemRandomNumberGenerator()
        var same = true
        for (cols, colors, bpc) in [(1, 1, 8), (5, 1, 8), (7, 3, 8), (3, 2, 16), (9, 1, 4)] {
            let row = (cols * colors * bpc + 7) / 8, bpp = max(1, colors * bpc / 8)
            var d: [UInt8] = []
            for _ in 0..<57 { d.append(UInt8.random(in: 0...5, using: &rng)); d += (0..<row).map { _ in UInt8.random(in: 0...255, using: &rng) } }
            d += [UInt8.random(in: 0...4, using: &rng)] + (0..<(row / 2)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            let parms = PDFDict([("Predictor", .integer(12)), ("Columns", .integer(cols)), ("Colors", .integer(colors)), ("BitsPerComponent", .integer(bpc))])
            if (try? PDFFilters.unpredict(d, parms: parms)) != referenceUnpredict(d, row: row, bpp: bpp) { same = false }
        }
        c.check(same, "PNG predictor in place: identical to the first version for 5 layouts, every filter type and a short last row")
        let rowCount = 3_000_000
        var rows1 = [UInt8](repeating: 1, count: 2 * rowCount)
        for r in 0..<rowCount { rows1[2 * r] = 2 }
        let (p1, tp) = timed { try? PDFFilters.unpredict(rows1, parms: PDFDict([("Predictor", .integer(12)), ("Columns", .integer(1))])) }
        c.check(p1?.count == rowCount && p1?.last == UInt8(rowCount & 0xFF) && tp < 3,
                "PNG predictor, /Columns 1, 3 million rows: \(PDFNumber.format((tp * 1000).rounded())) ms")

        // 7. Command-line numbers: a page of -9223372036854775808 or -1e30 trapped turning it into an index; an
        //    added text with a size of 1e308 or at x 1e308 was saved although it can never show.
        let cli = dir.appendingPathComponent("cli-edge.pdf")
        try rawClassic(onePage()).write(to: cli)
        func refusal(_ o: ToolOptions) -> String {
            do { _ = try PDFEditTool.run(cli, options: o) { _ in }; return "saved" } catch { return error.localizedDescription }
        }
        let r1 = refusal(["find": "Hello", "replace": "X", "page": "-9223372036854775808"])
        let r2 = refusal(["edits": #"[{"page":-1e30,"add":"x"}]"#])
        let r3 = refusal(["edits": #"[{"page":1e30,"find":"Hello","replace":"X"}]"#])
        c.check(r1.hasPrefix("Page -9223372036854775808 doesn’t exist") && r2.hasPrefix("Page 0 doesn’t exist") && r3.hasPrefix("Page 0 doesn’t exist") && r1.contains("has 1 page."),
                "CLI: pages -9223372036854775808, -1e30 and 1e30 are refused (“\(r1)”)")
        let r4 = refusal(["edits": #"[{"page":1,"add":"x","size":1e308}]"#])
        let r5 = refusal(["edits": #"[{"page":1,"add":"x","size":0}]"#])
        let r6 = refusal(["edits": #"[{"page":1,"add":"x","x":1e308,"y":1e308}]"#])
        c.check(r4 == "size must be from 1 to 400 points." && r5 == r4 && r6.hasPrefix("x and y must be on page 1: x from 0 to 612"),
                "CLI: an added text of size 1e308 or 0, or at x 1e308, is refused (“\(r6)”)")
        let ok = refusal(["edits": #"[{"page":1,"add":"Checked","x":400,"y":60,"size":16}]"#])
        c.check(ok == "saved", "CLI: an added text on the page still saves")
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
