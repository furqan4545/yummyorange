#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import CoreText
import PDFKit

/// `--selftest pdf-edit`: the object layer and writer on generated files of every cross-reference kind, runs and
/// same-font edits with golden operator bytes, the render-mode-3 oracle, the gate, shared objects, spacing,
/// marked content, fonts (transplant, learned CJK codes, standard 14, Type 3, refusals), Add Text, Delete,
/// compaction, signed and encrypted files, undo, the command line, and the real fixtures (report, tagged, scan, big).
enum PDFEditTests {
    final class Checker {
        var lines: [String] = []
        var failed = 0
        var count = 0
        func check(_ ok: Bool, _ what: @autoclosure () -> String) {
            count += 1
            if !ok { failed += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what())")
            if Checker.verbose { FileHandle.standardError.write(Data((lines.last! + "\n").utf8)) }
        }
        func section(_ s: String) {
            lines.append("— \(s)")
            if Checker.verbose { FileHandle.standardError.write(Data((lines.last! + "\n").utf8)) }
        }
        static let verbose = ProcessInfo.processInfo.environment["PDFEDIT_VERBOSE"] != nil
    }

    static func run() -> String {
        let c = Checker()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-pdfedit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let t0 = Date()
            try objectLayer(c, dir)
            try runsAndReplace(c, dir)
            try lineState(c, dir)
            try gateSharedSpacing(c, dir)
            try fontsTests(c, dir)
            try addDeleteClean(c, dir)
            try documentsAndCLI(c, dir)
            try realFixtures(c, dir)
            try scannedText(c, dir)
            try hostileFiles(c, dir)
            c.lines.append("time \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        } catch {
            c.check(false, "error: \(error.localizedDescription)")
        }
        return (c.failed == 0 ? "PASS" : "FAIL") + " pdf-edit (\(c.count - c.failed)/\(c.count) checks)\n" + c.lines.joined(separator: "\n")
    }

    // MARK: - Generated PDFs

    /// Objects written into a classic or an xref-stream file.
    struct Gen {
        enum Body { case plain(String), stream(dict: String, data: [UInt8], flate: Bool) }
        var objects: [(Int, Body)] = []
        var eol = "\n"

        mutating func add(_ n: Int, _ s: String) { objects.append((n, .plain(s))) }
        mutating func stream(_ n: Int, _ data: String, dict: String = "", flate: Bool = true) {
            objects.append((n, .stream(dict: dict, data: Array(data.utf8), flate: flate)))
        }
        mutating func stream(_ n: Int, _ dict: String, bytes: [UInt8], flate: Bool) { objects.append((n, .stream(dict: dict, data: bytes, flate: flate))) }

        func body(_ b: Body) -> [UInt8] {
            switch b {
            case .plain(let s): return Array(s.utf8)
            case .stream(let d, let data, let flate):
                let z = flate ? PDFFilters.deflate(data) : data
                return Array("<< \(d) \(flate ? "/Filter /FlateDecode " : "")/Length \(z.count) >>\(eol)stream\(eol)".utf8) + z + Array("\(eol)endstream".utf8)
            }
        }

        func classic(root: Int = 1, info: Int? = nil, trailingEOL: Bool = true) -> Data {
            var out = Array("%PDF-1.4\(eol)%\u{E2}\u{E3}\u{CF}\u{D3}\(eol)".utf8)
            var offsets: [Int: Int] = [:]
            for (n, b) in objects {
                offsets[n] = out.count
                out += Array("\(n) 0 obj\(eol)".utf8) + body(b) + Array("\(eol)endobj\(eol)".utf8)
            }
            let size = (offsets.keys.max() ?? 0) + 1
            let start = out.count
            var x = "xref\(eol)0 \(size)\(eol)"
            let rowEnd = eol == "\r\n" ? "\r\n" : " \n"
            for n in 0..<size {
                if let o = offsets[n] { x += String(format: "%010d 00000 n", o) + rowEnd } else { x += (n == 0 ? "0000000000 65535 f" : "0000000000 00000 f") + rowEnd }
            }
            x += "trailer\(eol)<< /Size \(size) /Root \(root) 0 R\(info.map { " /Info \($0) 0 R" } ?? "") /ID [<00112233445566778899AABBCCDDEEFF> <00112233445566778899AABBCCDDEEFF>] >>\(eol)startxref\(eol)\(start)\(eol)%%EOF"
            if trailingEOL { x += eol }
            return Data(out + Array(x.utf8))
        }

        /// Plain objects listed in `compressed` go into one object stream; the xref stream uses Flate with the
        /// PNG Up predictor, as Acrobat writes it.
        func xrefStream(root: Int = 1, info: Int? = nil, compressed: Set<Int>, objStm: Int, xref: Int) -> Data {
            var out = Array("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
            var rows: [Int: (Int, Int, Int)] = [:]
            var head = "", members: [UInt8] = []
            var index = 0
            for (n, b) in objects where compressed.contains(n) {
                guard case .plain(let s) = b else { continue }
                head += "\(n) \(members.count) "
                members += Array(s.utf8) + [10]
                rows[n] = (2, objStm, index)
                index += 1
            }
            for (n, b) in objects where !compressed.contains(n) {
                rows[n] = (1, out.count, 0)
                out += Array("\(n) 0 obj\n".utf8) + body(b) + Array("\nendobj\n".utf8)
            }
            if index > 0 {
                rows[objStm] = (1, out.count, 0)
                let z = PDFFilters.deflate(Array(head.utf8) + members)
                out += Array("\(objStm) 0 obj\n<< /Type /ObjStm /N \(index) /First \(head.utf8.count) /Filter /FlateDecode /Length \(z.count) >>\nstream\n".utf8) + z + Array("\nendstream\nendobj\n".utf8)
            }
            rows[xref] = (1, out.count, 0)
            rows[0] = (0, 0, 65535)
            let size = xref + 1
            var raw: [UInt8] = []
            var prev = [UInt8](repeating: 0, count: 7)
            for n in 0..<size {
                let r = rows[n] ?? (0, 0, 0)
                let row: [UInt8] = [UInt8(r.0), UInt8(r.1 >> 24 & 0xFF), UInt8(r.1 >> 16 & 0xFF), UInt8(r.1 >> 8 & 0xFF), UInt8(r.1 & 0xFF), UInt8(r.2 >> 8 & 0xFF), UInt8(r.2 & 0xFF)]
                raw.append(2)                                                 // PNG Up
                for k in 0..<7 { raw.append(row[k] &- prev[k]) }
                prev = row
            }
            let z = PDFFilters.deflate(raw)
            let start = out.count
            out += Array("\(xref) 0 obj\n<< /Type /XRef /Size \(size) /W [1 4 2] /Root \(root) 0 R\(info.map { " /Info \($0) 0 R" } ?? "") /ID [<0102030405060708090A0B0C0D0E0F10> <0102030405060708090A0B0C0D0E0F10>] /Filter /FlateDecode /DecodeParms << /Columns 7 /Predictor 12 >> /Length \(z.count) >>\nstream\n".utf8)
            out += z + Array("\nendstream\nendobj\nstartxref\n\(start)\n%%EOF\n".utf8)
            return Data(out)
        }
    }

    /// An earlier incremental update (new versions of some objects), in the file's own xref kind.
    static func priorUpdate(_ data: Data, objects: [(Int, String)], stream: Bool) throws -> Data {
        let f = try PDFObjectFile(data)
        let u = PDFIncrementalUpdate(f)
        for (n, s) in objects {
            var lx = PDFLexer(Array(s.utf8))
            u.put(n, lx.value() ?? .null)
        }
        return u.data(id: Array(repeating: 7, count: 16))
    }

    static let helvetica = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"

    static let classicContent = """
    BT /F1 24 Tf 72 700 Td (Hello World) Tj ET
    BT /F1 12 Tf 72 660 Td [(Kerned) -250 (Te) 30 (xt)] TJ ET
    BT /F1 12 Tf 72 640 Td <486578206C696E65> Tj ET
    BT /F1 12 Tf 72 620 Td (Paren \\( and \\) back\\\\slash) Tj ET
    BT /F1 12 Tf 14 TL 72 600 Td (First) Tj (Second) ' 2 1 (Third) " ET
    BT /F1 12 Tf 72 540 Td (Alpha) Tj (Beta) Tj ET
    BT /F1 12 Tf 72 520 Td (Left) Tj ET BT /F1 12 Tf 140 520 Td (Right) Tj ET
    BT /F2 12 Tf 72 500 Td (\\001le) Tj ET
    """

    /// Two pages sharing one content stream; Helvetica (standard 14) and a ligature font.
    static func classicPDF(eol: String = "\n", trailingEOL: Bool = true) -> Data {
        var g = Gen()
        g.eol = eol
        g.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
        g.add(2, "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 /MediaBox [0 0 612 792] >>")
        g.add(3, "<< /Type /Page /Parent 2 0 R /Resources 5 0 R /Contents 4 0 R >>")
        g.stream(4, classicContent)
        g.add(5, "<< /Font << /F1 7 0 R /F2 8 0 R >> >>")
        g.add(6, "<< /Type /Page /Parent 2 0 R /Resources 5 0 R /Contents 4 0 R >>")
        g.add(7, helvetica)
        g.add(8, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [1 /fi] >> >>")
        g.add(9, "<< /Title (Classic) /Producer (pdf-edit self-test) >>")
        return g.classic(info: 9, trailingEOL: trailingEOL)
    }

    static func xrefStreamPDF(prior: Bool) throws -> Data {
        var g = Gen()
        g.add(1, "<< /Type /Catalog /Pages 2 0 R /MarkInfo << /Marked true >> >>")
        g.add(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        g.add(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>")
        g.stream(4, "/Span << /MCID 0 /ActualText (Hello World) >> BDC BT /F1 24 Tf 72 700 Td (Hello World) Tj ET EMC\nBT /F1 12 Tf 72 650 Td (Second line) Tj ET\n")
        g.add(5, helvetica)
        g.add(6, "<< /Title (Rich) /Producer (handmade) >>")
        var d = g.xrefStream(info: 6, compressed: [1, 2, 3, 5, 6], objStm: 7, xref: 8)
        if prior { d = try priorUpdate(d, objects: [(6, "<< /Title (Rich updated) /Producer (handmade) >>")], stream: true) }
        return d
    }

    /// Classic table plus /XRefStm (page dictionaries in an object stream), a form shared by two pages,
    /// inherited resources, a /Rotate 90 page, a /Contents array, TJ kerning and hex strings.
    static func hybridPDF() -> Data {
        var out = Array("%PDF-1.5\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var off: [Int: Int] = [:]
        func obj(_ n: Int, _ body: [UInt8]) { off[n] = out.count; out += Array("\(n) 0 obj\n".utf8) + body + Array("\nendobj\n".utf8) }
        func stream(_ n: Int, _ d: String, _ s: [UInt8]) { obj(n, Array("<< \(d) /Length \(s.count) >>\nstream\n".utf8) + s + Array("\nendstream".utf8)) }
        obj(1, Array("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        stream(4, "/Filter /FlateDecode", PDFFilters.deflate(Array("BT /F1 18 Tf 72 700 Td [(Kerned) -250 (Te) 30 (xt) -250 (line)] TJ ET\n".utf8)))
        stream(9, "", Array("q 1 0 0 1 0 0 cm /X1 Do Q\n".utf8))
        stream(7, "/Filter /FlateDecode", PDFFilters.deflate(Array("BT /F1 14 Tf 72 500 Td <486578206C696E65> Tj 0 -20 Td (Next ) Tj (chained) Tj ET /X1 Do\n".utf8)))
        stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 612 200] /Resources << /Font << /F1 5 0 R >> >>", Array("BT /F1 10 Tf 72 100 Td (Shared footer) Tj ET".utf8))
        let plain: [Int: String] = [
            2: "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 /Resources << /Font << /F1 5 0 R >> /XObject << /X1 8 0 R >> >> /MediaBox [0 0 612 792] >>",
            3: "<< /Type /Page /Parent 2 0 R /Contents [4 0 R 9 0 R] >>",
            6: "<< /Type /Page /Parent 2 0 R /Rotate 90 /Contents 7 0 R >>",
            5: helvetica,
        ]
        let nums = plain.keys.sorted()
        var head = "", body: [UInt8] = []
        for n in nums { head += "\(n) \(body.count) "; body += Array(plain[n]!.utf8) + [10] }
        stream(10, "/Type /ObjStm /N \(nums.count) /First \(head.utf8.count) /Filter /FlateDecode", PDFFilters.deflate(Array(head.utf8) + body))
        var rows: [UInt8] = []
        for (i, _) in nums.enumerated() { rows += [2, 0, 0, 0, 10, 0, UInt8(i)] }
        off[11] = out.count
        out += Array("11 0 obj\n<< /Type /XRef /W [1 4 2] /Index [\(nums.map { "\($0) 1" }.joined(separator: " "))] /Size 12 /Length \(rows.count) >>\nstream\n".utf8) + rows + Array("\nendstream\nendobj\n".utf8)
        let xref = out.count
        var t = "xref\n0 12\n0000000000 65535 f\r\n"
        for n in 1..<12 { t += off[n] != nil && plain[n] == nil ? String(format: "%010d 00000 n\r\n", off[n]!) : "0000000000 00000 f\r\n" }
        t += "trailer\n<< /Size 12 /Root 1 0 R /XRefStm \(off[11]!) /ID [<00112233445566778899aabbccddeeff><00112233445566778899aabbccddeeff>] >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out + Array(t.utf8))
    }

    /// Text drawn by Core Text into a PDF (Quartz's own font objects).
    static func quartzPDF(_ lines: [(text: String, font: String, size: CGFloat, y: CGFloat)], ligatures: Bool = false) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        for l in lines {
            let f = CTFontCreateWithName(l.font as CFString, l.size, nil)
            let attr = NSAttributedString(string: l.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f,
                                                                      NSAttributedString.Key(kCTLigatureAttributeName as String): ligatures ? 1 : 0])
            ctx.textPosition = CGPoint(x: 72, y: l.y)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// A Type 3 font with three box glyphs (a b c), and the same text again as clipping text (7 Tr).
    static func type3PDF() -> Data {
        var g = Gen()
        g.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
        g.add(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>")
        g.add(3, "<< /Type /Page /Parent 2 0 R /Resources << /Font << /T3 5 0 R >> >> /Contents 4 0 R >>")
        g.stream(4, "BT /T3 24 Tf 72 700 Td (abc) Tj ET\nq BT 7 Tr /T3 24 Tf 72 600 Td (cab) Tj ET Q\n")
        g.add(5, "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 600 700] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs 6 0 R /Encoding << /Type /Encoding /Differences [97 /a /b /c] >> /FirstChar 97 /LastChar 99 /Widths [600 600 600] /Resources << >> /ToUnicode 10 0 R >>")
        g.stream(10, "/CIDInit /ProcSet findresource begin 12 dict begin begincmap 1 begincodespacerange <00> <FF> endcodespacerange 3 beginbfchar <61> <0061> <62> <0062> <63> <0063> endbfchar endcmap end end")
        g.add(6, "<< /a 7 0 R /b 8 0 R /c 9 0 R >>")
        g.stream(7, "600 0 0 0 500 500 d1 50 0 400 500 re f", flate: false)
        g.stream(8, "600 0 0 0 500 700 d1 50 0 150 700 re f 50 0 400 300 re f", flate: false)
        g.stream(9, "600 0 0 0 500 500 d1 50 0 400 120 re f 50 0 120 500 re f 50 380 400 120 re f", flate: false)
        return g.classic()
    }

    static func verticalPDF() -> Data {
        var g = Gen()
        g.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
        g.add(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>")
        g.add(3, "<< /Type /Page /Parent 2 0 R /Resources << /Font << /V1 5 0 R /F1 9 0 R >> >> /Contents 4 0 R >>")
        g.stream(4, "BT /V1 20 Tf 300 700 Td <00010002> Tj ET\nBT /F1 12 Tf 72 100 Td (Horizontal) Tj ET\n")
        g.add(5, "<< /Type /Font /Subtype /Type0 /BaseFont /HeiseiMin-W3 /Encoding /Identity-V /DescendantFonts [6 0 R] /ToUnicode 7 0 R >>")
        g.add(6, "<< /Type /Font /Subtype /CIDFontType0 /BaseFont /HeiseiMin-W3 /CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) /Supplement 2 >> /FontDescriptor 8 0 R /DW 1000 >>")
        g.stream(7, "/CIDInit /ProcSet findresource begin 12 dict begin begincmap 1 begincodespacerange <0000> <FFFF> endcodespacerange 2 beginbfchar <0001> <65E5> <0002> <672C> endbfchar endcmap end end")
        g.add(8, "<< /Type /FontDescriptor /FontName /HeiseiMin-W3 /Flags 4 /FontBBox [0 -120 1000 880] /ItalicAngle 0 /Ascent 880 /Descent -120 /CapHeight 700 /StemV 80 >>")
        g.add(9, helvetica)
        return g.classic()
    }

    /// Signed (a signature field with a value) or certified with DocMDP P = 1.
    static func signedPDF(certified: Bool) -> Data {
        var g = Gen()
        g.add(1, "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [10 0 R] /SigFlags 3 >>\(certified ? " /Perms << /DocMDP 11 0 R >>" : "") >>")
        g.add(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>")
        g.add(3, "<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R /Annots [10 0 R] >>")
        g.stream(4, "BT /F1 24 Tf 72 700 Td (Signed text) Tj ET\n")
        g.add(5, helvetica)
        g.add(10, "<< /Type /Annot /Subtype /Widget /FT /Sig /T (sig1) /V 11 0 R /Rect [0 0 0 0] /F 132 /P 3 0 R >>")
        g.add(11, "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange [0 10 20 30] /Contents <\(String(repeating: "00", count: 32))>\(certified ? " /Reference [<< /Type /SigRef /TransformMethod /DocMDP /TransformParams << /Type /TransformParams /P 1 /V /1.2 >> >>]" : "") >>")
        return g.classic()
    }

    /// A scan-like page: an image over the page and invisible (3 Tr) text on top.
    static func ocrPDF() -> Data {
        var g = Gen()
        g.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
        g.add(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>")
        g.add(3, "<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >> >> /Contents 4 0 R >>")
        g.stream(4, "q 612 0 0 792 0 0 cm /Im1 Do Q\nBT 3 Tr /F1 24 Tf 72 400 Td (Scanned words) Tj ET\n")
        g.add(5, helvetica)
        g.stream(6, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", bytes: [230, 240, 240, 230], flate: true)
        return g.classic()
    }

    /// A classic file whose startxref points nowhere (readers rebuild the cross-reference data by scanning).
    static func brokenPDF() -> Data {
        let data = classicPDF()
        guard let r = data.range(of: Data("startxref\n".utf8), options: .backwards),
              let e = data.range(of: Data("\n".utf8), in: r.upperBound..<data.count) else { return data }
        var d = data
        d.replaceSubrange(r.upperBound..<e.lowerBound, with: Data("17".utf8))
        return d
    }

    // MARK: - Helpers

    static func session(_ data: Data, _ name: String, _ dir: URL) throws -> PDFEditSession {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        if let dump = ProcessInfo.processInfo.environment["PDFEDIT_DUMP"] { try? data.write(to: URL(fileURLWithPath: dump).appendingPathComponent(name)) }
        return try PDFEditSession(url: url)
    }

    static func dump(_ data: Data, _ name: String) {
        if let dir = ProcessInfo.processInfo.environment["PDFEDIT_DUMP"] { try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name)) }
    }

    static func line(_ s: PDFEditSession, page: Int = 0, _ text: String) -> PDFLineID? {
        s.lines(page: page).first { $0.text.contains(text) }.map { PDFLineID(page: page, line: $0.index) }
    }

    /// The decoded data of the newest version of an object in a file.
    static func decoded(_ data: Data, _ n: Int) -> String {
        guard let f = try? PDFObjectFile(data), let d = try? f.decodedStream(n) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    static func allDecoded(_ data: Data) -> String {
        guard let f = try? PDFObjectFile(data) else { return "" }
        var s = ""
        for n in f.objectNumbers {
            if let d = try? f.decodedStream(n) { s += String(decoding: d, as: UTF8.self) }
            else if let o = f.object(n) { s += String(decoding: o.value.serialized(), as: UTF8.self) }
        }
        return s
    }

    static func pages(_ data: Data) -> (PDFDocument, CGPDFDocument)? {
        guard let d = PDFDocument(data: data), let p = CGDataProvider(data: data as CFData), let c = CGPDFDocument(p) else { return nil }
        return (d, c)
    }

    /// Changed pixels between page `i` of two files at 100 dpi, outside `dirty`.
    static func pixelDiff(_ a: Data, _ b: Data, page i: Int, outside dirty: [CGRect] = [], dpi: CGFloat = 100) -> Int {
        guard let x = pages(a), let y = pages(b), let pa = x.1.page(at: i + 1), let pb = y.1.page(at: i + 1) else { return -1 }
        return PDFEditVerify.changedPixels(pa, pb, dpi: dpi, outside: dirty)
    }

    static func text(_ data: Data, _ i: Int) -> String { PDFDocument(data: data)?.page(at: i)?.string ?? "" }

    /// The update section of a file: every entry points at "n g obj".
    static func offsetsValid(_ data: Data) -> Bool {
        guard let f = try? PDFObjectFile(data), !f.rebuilt else { return false }
        for n in f.newestSectionObjects {
            guard let e = f.entry(n) else { return false }
            if e.kind == .offset, f.parseIndirect(at: e.a)?.number != n { return false }
        }
        return true
    }

    /// A no-op update: page 1's dictionary and first content stream rewritten unchanged.
    static func noOpUpdate(_ data: Data) throws -> Data {
        let f = try PDFObjectFile(data)
        let u = PDFIncrementalUpdate(f)
        let p = f.pages()[0]
        u.put(p.number, .dict(p.dict), generation: p.generation)
        if let c = p.contents.first, let d = f.object(c)?.value.dict, let decoded = try f.decodedStream(c) {
            u.putStream(c, dict: d, decoded: decoded)
        }
        return u.data()
    }

    static func fixture(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            var d = exe.deletingLastPathComponent()
            for _ in 0..<6 { candidates.append(d); d = d.deletingLastPathComponent() }
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        for c in candidates {
            let u = c.appendingPathComponent("Tests/fixtures/core").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    // MARK: - 1. Object layer and writer

    static func objectLayer(_ c: Checker, _ dir: URL) throws {
        c.section("object layer and writer")
        var files: [(String, Data)] = [
            ("classic", classicPDF()), ("classic CRLF", classicPDF(eol: "\r\n")), ("classic no EOL", classicPDF(trailingEOL: false)),
            ("xref stream + ObjStm", try xrefStreamPDF(prior: false)), ("prior update", try xrefStreamPDF(prior: true)),
            ("classic prior update", try priorUpdate(classicPDF(), objects: [(9, "<< /Title (Classic two) /Producer (pdf-edit self-test) >>")], stream: false)),
            ("hybrid", hybridPDF()),
        ]
        for name in ["report", "tagged", "scan", "big"] {
            if let u = fixture(name + ".pdf") { files.append((name, try Data(contentsOf: u))) } else { c.check(false, "fixture \(name).pdf found") }
        }
        for (name, data) in files {
            guard let f = try? PDFObjectFile(data) else { c.check(false, "\(name): parses"); continue }
            let pdfkit = PDFDocument(data: data)?.pageCount ?? -1
            c.check(!f.rebuilt && f.pages().count == pdfkit, "\(name): parsed (\(f.sectionCount) sections, \(f.newestKind), \(f.pages().count) pages = PDFKit \(pdfkit))")
            let up = try noOpUpdate(data)
            let reparsed = try? PDFObjectFile(up)
            let prefix = up.prefix(data.count) == data
            let opens = pages(up).map { $0.0.pageCount == pdfkit && $0.1.numberOfPages == pdfkit } ?? false
            c.check(prefix && opens && reparsed?.sectionCount == f.sectionCount + 1 && reparsed?.newestKind == f.newestKind && offsetsValid(up),
                    "\(name): no-op update keeps the original as a prefix, opens in PDFKit and CGPDF, re-reads (\(reparsed?.sectionCount ?? -1) sections, \(reparsed.map { "\($0.newestKind)" } ?? "?")), offsets point at objects")
            let second = try noOpUpdate(up)
            c.check(second.prefix(up.count) == up && (try? PDFObjectFile(second))?.sectionCount == f.sectionCount + 2 && PDFDocument(data: second)?.pageCount == pdfkit,
                    "\(name): a second update on top works")
            c.check(pixelDiff(data, up, page: 0) == 0, "\(name): no-op update renders identically (0 px)")
            // Compaction: every live object byte-identical, the same picture, old revisions gone.
            let compact = PDFCompactWriter.rewrite(f)
            if let m = try? PDFObjectFile(compact), PDFDocument(data: compact)?.pageCount == pdfkit {
                var differ: [Int] = []
                for n in f.objectNumbers where !f.xrefStreamObjects.contains(n) {
                    guard let o = f.object(n), o.value.dict?["Type"]?.name != "ObjStm", o.value.dict?["Linearized"] == nil else { continue }
                    if body(f, n) != body(m, n) { differ.append(n) }
                }
                c.check(differ.isEmpty && !m.rebuilt, "\(name): compaction copies every live object byte for byte (differ: \(differ))")
                c.check(pixelDiff(data, compact, page: 0) == 0, "\(name): compaction renders identically (0 px)")
            } else {
                c.check(false, "\(name): compaction output opens")
            }
            if name == "prior update" || name == "classic prior update" {
                let oldTitle = name == "prior update" ? "(Rich)" : "(Classic)"
                c.check(!allDecoded(compact).contains(oldTitle) && (allDecoded(data).contains(oldTitle) || String(decoding: data, as: UTF8.self).contains(oldTitle)) && !String(decoding: compact, as: UTF8.self).contains(oldTitle),
                        "\(name): the superseded /Info is gone after compaction")
            }
        }
        // A damaged cross-reference table is rebuilt by scanning, and saving compacts the file.
        let broken = brokenPDF()
        let bf = try PDFObjectFile(broken)
        c.check(bf.rebuilt && bf.pages().count == 2, "broken xref: rebuilt by scanning (\(bf.pages().count) pages)")
        let s = try session(broken, "broken.pdf", dir)
        if let id = line(s, "Hello World") {
            try s.setText("Hello Earth", for: id)
            let out = try s.save()
            let d = try Data(contentsOf: out)
            let f2 = try? PDFObjectFile(d)
            c.check(f2?.rebuilt == false && text(d, 0).contains("Hello Earth") && d.prefix(broken.count) != broken,
                    "broken xref: save rewrites the file whole (repaired) and the edit reads back")
        } else { c.check(false, "broken xref: line found") }
    }

    /// The bytes of an object's body, whatever way it is stored.
    static func body(_ f: PDFObjectFile, _ n: Int) -> String {
        guard let o = f.object(n) else { return "<missing>" }
        if o.inObjectStream != nil { return String(decoding: f.memberBytes(n) ?? [], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let r = o.source else { return "" }
        var lx = PDFLexer(f.bytes, at: r.lowerBound)
        _ = lx.next(); _ = lx.next(); _ = lx.next()
        var s = String(decoding: f.bytes[lx.p..<r.upperBound], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("endobj") { s = String(s.dropLast(6)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return s
    }

    // MARK: - 2. Runs, same-font replace, golden bytes, the oracle

    static func runsAndReplace(_ c: Checker, _ dir: URL) throws {
        c.section("runs and same-font edits")
        let data = classicPDF()
        // Golden operator bytes.
        let cases: [(find: String, new: String, expect: String, what: String)] = [
            ("Hex line", "Hex lime", "<486578206C696D65> Tj", "hex strings stay hex"),
            ("back\\slash", "fore\\slash", "(Paren \\( and \\) fore\\\\slash) Tj", "literal escapes for ( ) \\"),
            ("Kerned Text", "Kerned Next", "[(Kerned) -250 (Ne) 30 (xt)] TJ", "kerning outside the edited span is kept"),
            ("Second", "Secxnd", "T* (Secxnd) Tj", "' becomes T* + show"),
            ("Third", "Thxrd", "2 Tw 1 Tc T* (Thxrd) Tj", "\" becomes aw Tw ac Tc T* + show"),
            ("file", "files", "(\\001les) Tj", "a ligature glyph (fi) is kept as one unit"),
            ("Hello World", "Hallo Wörld €", "(Hallo W\\366rld \\200) Tj", "standard-14 WinAnsi: ö and € in the font's own encoding"),
        ]
        for k in cases {
            let s = try session(data, "golden.pdf", dir)
            guard let id = line(s, k.find) else { c.check(false, "golden \(k.what): line “\(k.find)” found"); continue }
            let old = s.line(id)!.text
            try s.setText(old.replacingOccurrences(of: k.find, with: k.new), for: id)
            let out = s.candidateData
            let content = decoded(out, 4) + decoded(out, 10) + decoded(out, 11)
            c.check(content.contains(k.expect), "golden \(k.what): \(k.expect)")
            c.check(s.info(id)?.substitutions.isEmpty == true, "golden \(k.what): no font substituted")
        }
        // Report: same-font replace, PDFKit search, other pages, pixels outside the line.
        guard let reportURL = fixture("report.pdf") else { c.check(false, "report.pdf found"); return }
        let report = try Data(contentsOf: reportURL)
        let s = try session(report, "report.pdf", dir)
        let lines = s.lines(page: 0)
        c.check(lines.first?.text.hasPrefix("Quarterly Report - Page 1") == true && lines.dropFirst().first?.text.hasPrefix("Line 1:") == true,
                "report: lines in reading order (\(lines.count) lines, first “\(lines.first?.text.prefix(25) ?? "")”)")
        // Glyph quads against PDFKit's character bounds.
        let c0 = s.content(page: 0)
        if let page = s.originalDocument.page(at: 0), let run = lines.first.map({ c0.runs[$0.runs[0]] }) {
            // PDFKit gives ink boxes; a glyph quad is its advance by the font's descent…ascent. Horizontal edges
            // agree within side bearings, and the ink sits inside the quad's height.
            var worst = 0.0, outside = 0.0
            for i in 0..<16 where run.glyphs[i].text != " " {
                let q = PDFEditGeometry.bounds(c0.quad(run, from: i, to: i + 1))
                let b = page.characterBounds(at: i)
                worst = max(worst, abs(q.minX - b.minX), abs(q.maxX - b.maxX))
                outside = max(outside, q.minY - b.minY, b.maxY - q.maxY)
            }
            c.check(worst < 1 && outside < 1, "report: glyph quads within 1 pt of PDFKit characterBounds (x \(PDFNumber.format(worst)) pt, ink outside height \(PDFNumber.format(max(0, outside))) pt)")
        }
        guard let first = line(s, "Quarterly Report") else { c.check(false, "report: title line"); return }
        try s.setText(s.line(first)!.text.replacingOccurrences(of: "Quarterly Report", with: "Quarterly Totals"), for: first)
        let out = try s.save()
        let d = try Data(contentsOf: out)
        let doc = PDFDocument(data: d)!
        c.check(out.lastPathComponent == "report edited.pdf", "report: saved as \(out.lastPathComponent)")
        // Page 1 also shows “Quarterly Report - Page 2” below its first 54 lines: only the title line changes.
        let oldHits = doc.findString("Quarterly Report - Page 1", withOptions: []).count
        let newHits = doc.findString("Quarterly Totals - Page 1", withOptions: []).count
        let otherHits = doc.findString("Quarterly Report - Page 2", withOptions: []).count
        c.check(oldHits == 0 && newHits == 1 && otherHits == PDFDocument(data: report)!.findString("Quarterly Report - Page 2", withOptions: []).count,
                "report: findString(old) = \(oldHits), findString(new) = \(newHits), other titles unchanged (\(otherHits))")
        c.check(text(d, 0).hasPrefix("Quarterly Totals - Page 1") && text(d, 1) == text(report, 1) && text(d, 2) == text(report, 2),
                "report: page 1 reads “Quarterly Totals - Page 1”, pages 2–3 unchanged")
        let band = PDFEditGeometry.bounds(s.line(first)!.quad).insetBy(dx: -2, dy: -2)
        c.check(pixelDiff(report, d, page: 0, outside: [CGRect(x: band.minX, y: band.minY, width: 2000, height: band.height)]) == 0
                && pixelDiff(report, d, page: 1) == 0 && pixelDiff(report, d, page: 2) == 0,
                "report: 0 px changed outside the edited line band; pages 2–3 0 px")
        c.check(d.prefix(report.count) == report && d.count - report.count < 2000, "report: original is a prefix; update is \(d.count - report.count) bytes")

        // The render-mode-3 oracle: a spacer delete renders exactly like the same text drawn invisible.
        let so = try session(report, "oracle.pdf", dir)
        if let id = line(so, "Line 1: The quick") {
            let full = so.line(id)!.text
            try so.setText(full.replacingOccurrences(of: "quick", with: ""), for: id, spacing: .keep)
            let spacer = so.candidateData
            let f = try PDFObjectFile(report)
            var content = String(decoding: try f.decodedStream(4) ?? [], as: UTF8.self)
            let old = "(Line 1: The quick brown fox jumps over the lazy dog.                            )\nTj"
            let tr3 = "(Line 1: The ) Tj 3 Tr (quick) Tj 0 Tr ( brown fox jumps over the lazy dog.                            ) Tj"
            c.check(content.contains(old), "oracle: original operator found")
            if let r = content.range(of: old) { content.replaceSubrange(r, with: tr3) }
            let u = PDFIncrementalUpdate(f)
            u.putStream(4, dict: f.object(4)!.value.dict!, decoded: Array(content.utf8))
            let oracle = u.data()
            dump(spacer, "oracle-spacer.pdf"); dump(oracle, "oracle-tr3.pdf")
            let diff = pixelDiff(spacer, oracle, page: 0, dpi: 200)
            c.check(diff == 0, "oracle: spacer delete of “quick” renders pixel-identical to 3 Tr (\(diff) px differ at 200 dpi)")
            let k = decoded(spacer, 4)
            c.check(k.contains("[(Line 1: The ) -3000.5 ( brown fox"), "oracle: spacer is [-3000.5] in thousandths (A_old·1000/(Tfs·Th))")
        }
        // Whole-line delete against 3 Tr on the whole line.
        let sd = try session(report, "oracle2.pdf", dir)
        if let id = line(sd, "Line 2:") {
            try sd.deleteLine(id)
            let spacer = sd.candidateData
            dump(spacer, "delete-line2.pdf")
            let f = try PDFObjectFile(report)
            let content = String(decoding: try f.decodedStream(4) ?? [], as: UTF8.self)
            let old = "(Line 2: The quick brown fox jumps over the lazy dog.                            )\nTj"
            var hidden = content
            if let r = hidden.range(of: old) { hidden.replaceSubrange(r, with: "3 Tr " + old + " 0 Tr") }
            let u = PDFIncrementalUpdate(f)
            u.putStream(4, dict: f.object(4)!.value.dict!, decoded: Array(hidden.utf8))
            c.check(pixelDiff(spacer, u.data(), page: 0, dpi: 200) == 0, "oracle: deleting a whole line renders like 3 Tr on it")
            let before = text(report, 0).components(separatedBy: "Line 2:").count, after = text(spacer, 0).components(separatedBy: "Line 2:").count
            c.check(after == before - 1 && text(spacer, 0).hasPrefix("Quarterly Report - Page 1 Line 1: The quick brown fox jumps over the lazy dog.\nLine 3:"),
                    "delete: page 1’s “Line 2” is gone, “Line 3” still reads")
        }
    }

    // MARK: - UI-facing line state

    static func lineState(_ c: Checker, _ dir: URL) throws {
        c.section("line state for the editor")
        guard let reportURL = fixture("report.pdf") else { return }
        let report = try Data(contentsOf: reportURL)
        let s = try session(report, "state.pdf", dir)
        guard let id = s.find("Quarterly Report").first, let before = s.info(id) else { c.check(false, "state: title line"); return }
        let ef = s.editorFont(id)
        c.check(before.fontDescription == "Embedded subset of Monaco" && ef.source == .installed && ef.font.familyName == "Monaco" && abs(ef.font.pointSize - 12) < 0.01,
                "state: “\(before.fontDescription)”, editor font \(ef.font.fontName) \(PDFNumber.format(Double(ef.font.pointSize))) pt (the subset’s family, installed)")
        c.check(abs(before.pointSize - 12) < 0.01 && abs(before.angle) < 0.01 && before.availability == .editable && !before.isEdited && before.sharedPages == 1,
                "state: 12 pt, 0°, editable, not edited, on 1 page")
        let gray = before.color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? []
        c.check(gray.prefix(3).allSatisfy { $0 < 0.01 }, "state: text colour black")
        try s.setText("Quarterly Report - Page 1 and a much longer title", for: id)
        let after = s.info(id)!
        c.check(after.isEdited && after.text.hasSuffix("much longer title") && PDFEditGeometry.bounds(after.quad).maxX > PDFEditGeometry.bounds(before.quad).maxX + 100,
                "state: the outline grows with the new text (\(Int(PDFEditGeometry.bounds(before.quad).maxX)) → \(Int(PDFEditGeometry.bounds(after.quad).maxX)) pt)")
        // The blanked preview for the inline editor: the line is gone there, the candidate keeps it.
        let blank = s.previewDocument(blanking: id)
        let blankText = blank?.page(at: 0)?.string ?? ""
        c.check(!blankText.contains("much longer title") && !blankText.hasPrefix("Quarterly") && text(s.candidateData, 0).contains("much longer title"),
                "state: blanked preview hides the line being edited; the candidate still shows it")
        // A rotated page (hybrid page 2): lines run up the page, edits work.
        let sh = try session(hybridPDF(), "rot.pdf", dir)
        if let hex = sh.find("Hex line", page: 1).first, let i = sh.info(hex) {
            c.check(abs(i.angle) < 0.01 && sh.pages[1].rotate == 90, "rotated page: text angle \(PDFNumber.format(i.angle))° in page space on a /Rotate 90 page")
            try sh.setText("Hex lime", for: hex)
            c.check(text(sh.candidateData, 1).contains("Hex lime") && decoded(sh.candidateData, 7).contains("<486578206C696D65> Tj"), "rotated page: hex edit")
            _ = try sh.save()
        } else { c.check(false, "rotated page: “Hex line” found") }
        let chained = sh.find("Next chained", page: 1)
        c.check(chained.count == 1, "lines: chained runs “Next ” + “chained” form one line")
        let kerned = sh.lines(page: 0).first?.text
        c.check(kerned == "Kerned Text line", "lines: wide TJ gaps read as spaces (“\(kerned ?? "")”)")
    }

    // MARK: - 3. Gate, shared objects, spacing, ActualText

    static func gateSharedSpacing(_ c: Checker, _ dir: URL) throws {
        c.section("gate, shared objects, spacing, marked content")
        guard let reportURL = fixture("report.pdf") else { return }
        let report = try Data(contentsOf: reportURL)
        let s = try session(report, "gate.pdf", dir)
        guard let id = line(s, "Line 3:") else { c.check(false, "gate: line"); return }
        try s.setText(s.line(id)!.text.replacingOccurrences(of: "lazy", with: "busy"), for: id)
        let (b, a) = try s.currentBuildAndAnalysis()
        c.check(PDFEditVerify.verify(session: s, build: b, analysis: a, output: b.data, incremental: true).ok, "gate: the real candidate passes")
        // Corruptions: the prefix, pixels outside the edit, an extra object, text that doesn't read back.
        var broken = b.data
        broken[100] ^= 0x20
        let r1 = PDFEditVerify.verify(session: s, build: b, analysis: a, output: broken, incremental: true)
        c.check(!r1.ok, "gate: rejects a changed original byte (\(r1.failures.first ?? "passed"))")
        let s2 = try session(report, "gate2.pdf", dir)
        if let other = line(s2, "Line 5:") {
            try s2.setText(s2.line(other)!.text.replacingOccurrences(of: "lazy", with: "busy"), for: other)
            try s2.setText(s2.line(id)!.text.replacingOccurrences(of: "lazy", with: "busy"), for: id)
            let r2 = PDFEditVerify.verify(session: s, build: b, analysis: a, output: s2.candidateData, incremental: true)
            c.check(!r2.ok, "gate: rejects pixels changed outside the edited text (\(r2.failures.first ?? "passed"))")
        }
        let f = try PDFObjectFile(b.data)
        let u = PDFIncrementalUpdate(f)
        u.put(u.allocate(), .dict(PDFDict([("Extra", .bool(true))])))
        let r3 = PDFEditVerify.verify(session: s, build: b, analysis: a, output: u.data(), incremental: true)
        c.check(!r3.ok, "gate: rejects an update with unexpected objects (\(r3.failures.first ?? "passed"))")
        let fakeBuild = PDFEditBuild(data: b.data, written: b.written, editedPages: b.editedPages, splices: b.splices, renames: b.renames,
                                     lineSubstitutions: [:], addSubstitutions: [:], substitutedFonts: [], fitScales: [:],
                                     expectedText: [id: "Line 3: The quick brown fox jumps over the hungry dog."], addedStreams: [:], addIDsByPage: [:])
        let r4 = PDFEditVerify.verify(session: s, build: fakeBuild, analysis: a, output: b.data, incremental: true)
        c.check(!r4.ok, "gate: rejects text that doesn’t read back (\(r4.failures.first ?? "passed"))")
        let noInk = PDFEditVerify.glyphsWithoutInk(PDFDocument(data: b.data)!.page(at: 0)!.pageRef!, [CGRect(x: 500, y: 400, width: 6, height: 8)])
        c.check(noInk == 1, "gate: a blank glyph box counts as missing ink")

        // A content stream shared by two pages: copy on write.
        let classic = classicPDF()
        let sc = try session(classic, "shared.pdf", dir)
        if let hello = line(sc, "Hello World") {
            try sc.setText("Hello There", for: hello)
            let d = sc.candidateData
            let pf = try PDFObjectFile(d).pages()
            c.check(pf[0].contents != pf[1].contents && pf[1].contents == [4], "shared content: page 1 got its own copy (\(pf[0].contents)), page 2 still uses 4")
            c.check(pixelDiff(classic, d, page: 1) == 0 && text(d, 1).contains("Hello World") && text(d, 0).contains("Hello There"),
                    "shared content: page 2 0 px and unchanged text")
        }
        // A form drawn on two pages: Only This Page and All Pages.
        let hybrid = hybridPDF()
        let sh = try session(hybrid, "hybrid.pdf", dir)
        if let foot = line(sh, "Shared footer") {
            c.check(sh.sharedPages(foot) == 2 && sh.banner(for: foot) == .sharedText(pages: 2), "shared form: banner says it appears on 2 pages")
            try sh.setText("Shared header", for: foot, scope: .thisPage)
            let d1 = sh.candidateData
            c.check(text(d1, 0).contains("Shared header") && text(d1, 1).contains("Shared footer") && pixelDiff(hybrid, d1, page: 1) == 0,
                    "shared form, Only This Page: page 2 keeps the footer (0 px)")
            try sh.setScope(.allPages, for: foot)
            let d2 = sh.candidateData
            c.check(text(d2, 0).contains("Shared header") && text(d2, 1).contains("Shared header"), "shared form, All Pages: both pages change")
            _ = try sh.save()
            c.check(true, "shared form: All Pages passes the gate")
        } else { c.check(false, "shared form: footer line") }
        // Rotated page: the upright transform matches Core Graphics.
        if let p2 = PDFDocument(data: hybrid)?.page(at: 1) {
            let mine = PDFEditGeometry.uprightTransform(crop: sh.pages[1].cropBox, rotate: sh.pages[1].rotate)
            let cgT = PDFArchive.pageTransform(p2).matrix
            let same = [mine.a - cgT.a, mine.b - cgT.b, mine.c - cgT.c, mine.d - cgT.d, mine.tx - cgT.tx, mine.ty - cgT.ty].allSatisfy { abs($0) < 0.001 }
            c.check(same, "rotated page: upright transform equals PDFArchive.pageTransform")
        }
        // Spacing: chained runs "Alpha" "Beta".
        func betaX(_ data: Data) -> Double? {
            guard let f = try? PDFObjectFile(data) else { return nil }
            let pc = PDFPageContent(file: f, page: f.pages()[0], fonts: PDFEditFontCache(f))
            return pc.runs.first { $0.text == "Beta" }.map { Double($0.trm.tx) }
        }
        let original = betaX(classic) ?? -1
        for (sp, newText, expectMove) in [(PDFSpacing.keep, "AlphabetBeta", false), (.flow, "AlphabetBeta", true), (.fit, "AlphasBeta", false)] {
            let ss = try session(classic, "spacing.pdf", dir)
            guard let id = line(ss, "AlphaBeta") else { c.check(false, "spacing: line AlphaBeta"); continue }
            try ss.setText(newText, for: id, spacing: sp)
            let x = betaX(ss.candidateData) ?? -100
            let moved = abs(x - original)
            c.check(expectMove ? moved > 5 : moved < 0.01, "spacing \(sp.rawValue): next run moved \(PDFNumber.format(moved)) pt")
            if sp == .fit { c.check(abs((ss.info(id)?.fitScale ?? 1) - 5.0 / 6.0) < 0.05, "spacing fit: scale \(PDFNumber.format(ss.info(id)?.fitScale ?? 1))") }
            _ = try ss.save()
        }
        // Fit Width on a padded line (report: every string ends in spaces): the visible text keeps its width.
        if let reportURL = fixture("report.pdf") {
            let sf = try session(try Data(contentsOf: reportURL), "fit.pdf", dir)
            if let id = line(sf, page: 1, "Line 9:") {
                let before = PDFEditGeometry.bounds(sf.line(id)!.quad)
                try sf.setText(sf.line(id)!.text.replacingOccurrences(of: "quick brown", with: "quick brown and clever"), for: id, spacing: .fit)
                let after = PDFEditGeometry.bounds(sf.info(id)!.quad)
                c.check(abs(after.maxX - before.maxX) < 0.5 && abs(after.minX - before.minX) < 0.01,
                        "spacing fit: visible width kept on a padded line (\(PDFNumber.format(before.width)) → \(PDFNumber.format(after.width)) pt, scale \(PDFNumber.format(sf.info(id)!.fitScale)))")
                _ = try sf.save()
            }
        }
        // Overflow: Flow into the next text on the same baseline.
        let so = try session(classic, "overflow.pdf", dir)
        if let left = line(so, "Left") {
            try so.setText("Left side, much longer", for: left)
            let info = so.info(left)
            c.check((info?.overflow ?? 0) > 5 && info?.overflowMessage != nil, "overflow: “\(info?.overflowMessage ?? "none")”")
        }
        // Marked content: MCID kept, ActualText rewritten.
        let rich = try xrefStreamPDF(prior: true)
        let sr = try session(rich, "rich.pdf", dir)
        if let hello = line(sr, "Hello World") {
            try sr.setText("Hello There", for: hello)
            let out = try sr.save()
            let d = try Data(contentsOf: out)
            let content = decoded(d, 4)
            c.check(content.contains("/MCID 0") && content.contains("BDC") && content.contains("EMC"), "marked content: /MCID 0 BDC … EMC kept around the edit")
            c.check(content.contains("/ActualText (Hello There)"), "marked content: ActualText rewritten to “Hello There”")
            let f = try PDFObjectFile(d)
            c.check(f.newestKind == .stream && d.prefix(rich.count) == rich, "xref-stream file: update written as an xref stream after a prior update")
        }
    }

    // MARK: - 4. Fonts

    static func fontsTests(_ c: Checker, _ dir: URL) throws {
        c.section("fonts")
        guard let reportURL = fixture("report.pdf") else { return }
        let report = try Data(contentsOf: reportURL)
        // Transplant: Monaco is installed; é and € aren't in the embedded subset.
        let s = try session(report, "transplant.pdf", dir)
        let font = s.content(page: 1).font(of: s.content(page: 1).runs[0])
        c.check(font?.canEncode("Report") == true && font?.canEncode("é") == false && font?.canEncode("€") == false,
                "subset evidence: “Report” encodes in AAAAAB+Monaco, é and € don’t")
        if let id = line(s, page: 1, "Line 7:") {
            try s.setText(s.line(id)!.text.replacingOccurrences(of: "The quick brown fox", with: "The QUICK brown € fox"), for: id)
            let info = s.info(id)
            c.check(info?.substitutions.first?.fontName == "Monaco" && info?.substitutions.first?.exact == true,
                    "transplant: “\(info?.substitutions.map(\.description).joined(separator: ", ") ?? "")”")
            let out = try s.save()
            let d = try Data(contentsOf: out)
            c.check(text(d, 1).contains("Line 7: The QUICK brown € fox jumps"), "transplant: page 2 reads “The QUICK brown € fox” in order")
            // New codes have widths above zero; the gate checked their ink.
            let f = try PDFObjectFile(d)
            let fonts = PDFEditFontCache(f)
            let pc = PDFPageContent(file: f, page: f.pages()[1], fonts: fonts)
            let newGlyphs = pc.runs.filter { $0.fontName.hasPrefix("DWF") }.flatMap(\.glyphs)
            c.check(!newGlyphs.isEmpty && newGlyphs.allSatisfy { $0.width > 0 } && newGlyphs.map(\.text).joined() == "UICK€",
                    "transplant: new glyphs “\(newGlyphs.map(\.text).joined())” all have width > 0")
            let (b, a) = try s.currentBuildAndAnalysis()
            let r = PDFEditVerify.verify(session: s, build: b, analysis: a, output: b.data, incremental: true)
            c.check(r.ok && r.glyphsChecked > 0, "transplant: gate checked ink of \(r.glyphsChecked) new glyphs")
        }
        // CJK from Quartz: codes learned from PDFKit, an in-place reorder, and a transplant with a synthesized ToUnicode.
        let cjk = quartzPDF([("こんにちは世界、東京の天気", "HiraginoSans-W3", 20, 700), ("Second line 二", "HiraginoSans-W3", 20, 650)])
        let sj = try session(cjk, "cjk.pdf", dir)
        let jf = sj.content(page: 0).runs.first.flatMap { sj.content(page: 0).font(of: $0) }
        c.check(jf?.kind == .type0 && sj.lines(page: 0).first?.text == "こんにちは世界、東京の天気",
                "CJK: Type0 line reads “\(sj.lines(page: 0).first?.text ?? "")” (ToUnicode \(jf?.hasToUnicode == true ? "present" : "absent, codes learned"))")
        if let id = line(sj, "こんにちは") {
            try sj.setText("世界、こんにちは東京の天気", for: id)
            c.check(sj.info(id)?.substitutions.isEmpty == true, "CJK: reordering known characters needs no other font")
            try sj.setText("こんにちは大阪、東京の天気", for: id)
            let subs = sj.info(id)?.substitutions ?? []
            c.check(subs.first.map { $0.characters == 2 } == true, "CJK: new characters from \(subs.first?.fontName ?? "?")")
            dump(sj.candidateData, "cjk-candidate.pdf")
            let out = try sj.save()
            let d = try Data(contentsOf: out)
            c.check(text(d, 0).contains("こんにちは大阪、東京の天気"), "CJK: reads back “こんにちは大阪、東京の天気”")
            let f = try PDFObjectFile(d)
            let fd = f.resolve(f.pages()[0].resources["Font"] ?? .null).dict
            let added = fd?.keys.filter { $0.hasPrefix("DWF") }.compactMap { fd?[$0] }.compactMap { f.resolve($0).dict } ?? []
            let withMap = added.filter { $0["ToUnicode"] != nil }
            c.check(!added.isEmpty && withMap.count == added.count, "CJK: every transplanted font has a ToUnicode map (\(withMap.count)/\(added.count))")
            if let tu = withMap.first?["ToUnicode"]?.ref?.number, let cmap = try? f.decodedStream(tu) {
                let t = String(decoding: cmap, as: UTF8.self)
                c.check(t.contains("<5927>") && t.contains("<962A>"), "CJK: synthesized ToUnicode maps 大 (5927) and 阪 (962A)")
            }
        }
        // Quartz text with ligatures on (Pages, TextEdit): ligature glyphs read as their letters and stay one unit.
        let lig = quartzPDF([("The office files are final.", "TimesNewRomanPSMT", 18, 700), ("Second para of text.", "HelveticaNeue", 14, 660)], ligatures: true)
        let sl = try session(lig, "ligatures.pdf", dir)
        if let id = line(sl, "office") {
            c.check(sl.line(id)?.text == "The office files are final.", "Quartz ligatures: line reads “\(sl.line(id)?.text ?? "")”")
            try sl.setText("The office folders are final.", for: id)
            let out = try sl.save()
            c.check(text(try Data(contentsOf: out), 0).contains("The office folders are final."), "Quartz ligatures: edit reads back (\(sl.info(id)?.substitutions.map(\.description).joined() ?? "own font"))")
        } else { c.check(false, "Quartz ligatures: line found (\(sl.lines(page: 0).map(\.text)))") }
        if let id = line(sl, "Second para") {
            try sl.setText("Second paragraph of text, revised.", for: id)
            let out = try sl.save()
            c.check(text(try Data(contentsOf: out), 0).contains("Second paragraph of text, revised."), "Quartz Helvetica Neue: edit reads back (\(sl.info(id)?.substitutions.map(\.description).joined() ?? ""))")
        }
        // Standard 14 (Helvetica, not embedded): any WinAnsi character, no other font.
        let sc = try session(classicPDF(), "std14.pdf", dir)
        if let id = line(sc, "Hello World") {
            let f = sc.content(page: 0).font(of: sc.content(page: 0).runs[0])
            c.check(f?.isStandard14 == true && f?.sourceDescription == "Helvetica, a standard PDF font", "standard 14: “\(f?.sourceDescription ?? "")”")
            try sc.setText("Grüße, Œuvre — 50 €", for: id)
            c.check(sc.info(id)?.substitutions.isEmpty == true && text(sc.candidateData, 0).contains("Grüße, Œuvre — 50 €"),
                    "standard 14: “Grüße, Œuvre — 50 €” in the font’s own WinAnsi codes")
        }
        // Type 3: known codes in place; a new character comes from this Mac at an approximate size.
        let t3 = type3PDF()
        let st = try session(t3, "type3.pdf", dir)
        if let id = line(st, "abc") {
            c.check(st.notes(id).contains(.drawnGlyphs), "Type 3: inspector note “\(PDFLineNote.drawnGlyphs.message)”")
            try st.setText("cab", for: id)
            c.check(decoded(st.candidateData, 4).contains("(cab) Tj") && st.info(id)?.substitutions.isEmpty == true, "Type 3: “cab” uses the font’s own glyphs")
            try st.setText("abcz", for: id)
            c.check(st.info(id)?.substitutions.first?.approximate == true, "Type 3: “z” is \(st.info(id)?.substitutions.first?.description ?? "?")")
            _ = try st.save()
            c.check(true, "Type 3: transplant passes the gate")
        }
        // Clipping text can't take another font.
        if let clip = st.lines(page: 0).first(where: { $0.text == "cab" }).map({ PDFLineID(page: 0, line: $0.index) }) {
            c.check(st.notes(clip).contains(.clippingText), "clipping text: note shown")
            do { try st.setText("cabz", for: clip); c.check(false, "clipping text: refuses a character its font lacks") }
            catch { c.check(error.localizedDescription.contains("clipping"), "clipping text refused: \(error.localizedDescription)") }
        }
        // Emoji and vertical text are refused with their messages.
        let se = try session(classicPDF(), "emoji.pdf", dir)
        if let id = line(se, "Hello World") {
            do { try se.setText("Hello 😀", for: id); c.check(false, "emoji refused") }
            catch { c.check(error.localizedDescription == "Emoji can’t be added as PDF text.", "emoji refused: \(error.localizedDescription)") }
            c.check(se.edits.isEmpty, "emoji: the edit list is unchanged after a refusal")
        }
        let sv = try session(verticalPDF(), "vertical.pdf", dir)
        if let v = sv.lines(page: 0).first(where: { $0.text == "日本" }).map({ PDFLineID(page: 0, line: $0.index) }) {
            c.check(sv.availability(v) == .readOnly("Vertical text can’t be edited yet."), "vertical: \(sv.availability(v).reason ?? "editable")")
        } else { c.check(false, "vertical: line 日本 found (\(sv.lines(page: 0).map(\.text)))") }
    }

    // MARK: - 5. Add Text, Delete, compaction

    static func addDeleteClean(_ c: Checker, _ dir: URL) throws {
        c.section("add text, delete, remove replaced text")
        guard let reportURL = fixture("report.pdf") else { return }
        let report = try Data(contentsOf: reportURL)
        let s = try session(report, "add.pdf", dir)
        let style = PDFTextStyle(fontName: "Helvetica", size: 14, red: 0.8, green: 0.1, blue: 0.1)
        let id = try s.addText("Added: Grüße · 日本語", page: 0, at: CGPoint(x: 72, y: 100), style: style)
        let d = s.candidateData
        c.check(text(d, 0).contains("Added: Grüße · 日本語"), "add text: reads back (Japanese from a fallback font)")
        let quad = s.addedTexts.first { $0.id == id }?.quad ?? []
        let area = PDFEditGeometry.bounds(quad)
        c.check(!quad.isEmpty && abs(area.minX - 72) < 2 && area.minY < 100 && area.maxY > 108, "add text: outline at \(area.integral)")
        c.check(pixelDiff(report, d, page: 0, outside: [area.insetBy(dx: -3, dy: -3)]) == 0, "add text: 0 px changed outside the new text")
        let f = try PDFObjectFile(d)
        let first = f.pages()[0].contents.first.flatMap { try? f.decodedStream($0) }.map { String(decoding: $0, as: UTF8.self) }
        c.check(first == "q\n" && f.pages()[0].contents.count == 3, "add text: page content wrapped in q … Q (\(f.pages()[0].contents))")
        try s.updateAddedText(id, origin: CGPoint(x: 200, y: 120))
        c.check(PDFEditGeometry.bounds(s.addedTexts[0].quad).minX > 190, "add text: moved")
        _ = try s.save()
        c.check(true, "add text: passes the gate")
        // Rotated page: added text is upright for the reader.
        let sh = try session(hybridPDF(), "hybrid-add.pdf", dir)
        let rid = try sh.addText("Upright", page: 1, at: CGPoint(x: 300, y: 300), style: PDFTextStyle())
        let rq = sh.addedTexts.first { $0.id == rid }?.quad ?? []
        let up = PDFEditGeometry.bounds(rq).applying(PDFEditGeometry.uprightTransform(crop: sh.pages[1].cropBox, rotate: 90))
        c.check(up.width > up.height * 2, "add text on a /Rotate 90 page runs left to right as shown (\(up.integral.size))")
        // Scans: no text lines, the banner, and Add Text works.
        if let scanURL = fixture("scan.pdf") {
            let scan = try Data(contentsOf: scanURL)
            let ss = try session(scan, "scan.pdf", dir)
            c.check(ss.lines(page: 0).isEmpty && ss.banners(page: 0) == [.scanned], "scan: no lines, banner “\(PDFEditBanner.scanned.message)”")
            try ss.addText("Reviewed", page: 0, at: CGPoint(x: 60, y: 780), style: PDFTextStyle(fontName: "Helvetica-Bold", size: 18))
            let out = try ss.save()
            let d2 = try Data(contentsOf: out)
            c.check(text(d2, 0).contains("Reviewed") && d2.prefix(scan.count) == scan, "scan: added text saved incrementally")
        }
        // OCR text over a blank scan (no ink to read): the edit is still drawn, in a plain font, and searchable.
        let so = try session(ocrPDF(), "ocr.pdf", dir)
        c.check(so.banners(page: 0) == [.ocrOnly], "OCR: banner “\(PDFEditBanner.ocrOnly.message)”")
        if let id = line(so, "Scanned words") {
            c.check(so.notes(id) == [.scannedText(font: "Helvetica")], "OCR: note “\(PDFLineNote.scannedText(font: "Helvetica").message)”")
            try so.setText("Scanned text", for: id)
            let out = try so.save()
            c.check(text((try Data(contentsOf: out)), 0).contains("Scanned text"), "OCR: edited text drawn and searchable")
        }
        // Remove replaced text: the old wording is gone from every stream, the picture is the same.
        let sc = try session(report, "clean.pdf", dir)
        if let t = line(sc, "Quarterly Report") {
            try sc.setText(sc.line(t)!.text.replacingOccurrences(of: "Quarterly Report", with: "Quarterly Totals"), for: t)
            c.check(sc.statusText == "1 change on 1 page · Replaced text stays in the file’s history", "status: “\(sc.statusText)”")
            let incremental = sc.candidateData
            let f0 = try PDFObjectFile(incremental)
            let oldVersion = String(decoding: (try? f0.decode(f0.parseIndirect(at: (try PDFObjectFile(report)).entry(4)!.a)!.value.dict!,
                                                              f0.parseIndirect(at: (try PDFObjectFile(report)).entry(4)!.a)!.stream!)) ?? [], as: UTF8.self)
            c.check(oldVersion.contains("Quarterly Report - Page 1") && incremental.prefix(report.count) == report,
                    "history: the incremental file still holds the old wording")
            sc.removeReplacedText = true
            c.check(sc.statusText == "1 change on 1 page", "status with removal on: “\(sc.statusText)”")
            let out = try sc.save()
            let d2 = try Data(contentsOf: out)
            c.check(!allDecoded(d2).contains("Quarterly Report - Page 1") && !String(decoding: d2, as: UTF8.self).contains("Quarterly Report - Page 1")
                    && text(d2, 0).hasPrefix("Quarterly Totals"), "remove replaced text: old wording gone from the file")
            let sections = (try PDFObjectFile(d2)).sectionCount
            c.check(pixelDiff(incremental, d2, page: 0) == 0 && sections == 1, "remove replaced text: same picture, one revision")
        }
        // Undo and redo through an UndoManager, with action names.
        let su = try session(report, "undo.pdf", dir)
        let um = UndoManager()
        um.groupsByEvent = false
        su.undoManager = um
        var changes: [String] = []
        su.onChange = { changes.append($0.actionName) }
        if let l1 = line(su, "Line 1:"), let l4 = line(su, "Line 4:") {
            um.beginUndoGrouping(); try su.setText("Line 1: edited", for: l1); um.endUndoGrouping()
            um.beginUndoGrouping(); try su.deleteLine(l4); um.endUndoGrouping()
            c.check(um.undoActionName == "Delete Text" && su.edits.count == 2, "undo: “\(um.undoActionName)” is next")
            um.undo()
            c.check(su.edits.count == 1 && su.info(l4)?.isDeleted == false, "undo: delete undone")
            um.undo()
            c.check(su.edits.isEmpty && su.candidateData == report, "undo: back to the original bytes")
            um.redo(); um.redo()
            c.check(su.edits.count == 2 && su.info(l1)?.text == "Line 1: edited" && su.info(l4)?.isDeleted == true, "redo: both edits back")
            c.check(changes == ["Edit Text", "Delete Text", "Delete Text", "Edit Text", "Edit Text", "Delete Text"], "change notices: \(changes)")
            um.beginUndoGrouping(); su.revert(l1); um.endUndoGrouping()
            c.check(su.edits.count == 1 && su.info(l1)?.isEdited == false, "revert: line 1 back to its original text")
        }
    }

    // MARK: - 6. Documents and the command line

    static func documentsAndCLI(_ c: Checker, _ dir: URL) throws {
        c.section("signed, encrypted, bad input, command line")
        let signed = signedPDF(certified: false)
        let s = try session(signed, "signed.pdf", dir)
        c.check(s.banners(page: 0) == [.signed] && !s.canRemoveReplacedText && s.removeReplacedTextUnavailableReason != nil, "signed: banner and no removal of replaced text")
        if let id = line(s, "Signed text") {
            try s.setText("Signed words", for: id)
            s.removeReplacedText = true
            let out = try s.save()
            let d = try Data(contentsOf: out)
            c.check(d.prefix(signed.count) == signed && text(d, 0).contains("Signed words"), "signed: saved as an update after the signed bytes")
        }
        let cert = try session(signedPDF(certified: true), "certified.pdf", dir)
        c.check(cert.isReadOnly && cert.banners(page: 0) == [.certified], "certified (DocMDP P=1): read-only with banner")
        if let id = line(cert, "Signed text") {
            c.check(cert.availability(id) == .readOnly("The signature on this PDF doesn’t allow changes."), "certified: line read-only")
            do { try cert.setText("x", for: id); c.check(false, "certified: edit refused") } catch { c.check(true, "certified: edit refused") }
        }
        // Encrypted files (user password, and owner password only) are refused.
        let plainURL = dir.appendingPathComponent("plain.pdf")
        try classicPDF().write(to: plainURL)
        for (opts, what) in [([PDFDocumentWriteOption.userPasswordOption: "u", .ownerPasswordOption: "o"], "user password"),
                             ([.ownerPasswordOption: "owner"], "owner password only")] {
            let enc = dir.appendingPathComponent("enc-\(what.count).pdf")
            _ = PDFDocument(url: plainURL)?.write(to: enc, withOptions: opts)
            do { _ = try PDFEditSession(url: enc); c.check(false, "encrypted (\(what)) refused") }
            catch { c.check(error.localizedDescription.contains("Remove Password"), "encrypted (\(what)): \(error.localizedDescription)") }
        }
        // Bad input.
        let junk = dir.appendingPathComponent("junk.pdf")
        try Data("not a pdf at all".utf8).write(to: junk)
        do { _ = try PDFEditSession(url: junk); c.check(false, "junk refused") } catch { c.check(error.localizedDescription == "Couldn’t read junk.pdf.", "junk: \(error.localizedDescription)") }
        // Command line: find/replace, missing find, text not found, JSON edits, input unchanged.
        guard let reportURL = fixture("report.pdf") else { return }
        let input = dir.appendingPathComponent("cli.pdf")
        try FileManager.default.copyItem(at: reportURL, to: input)
        let before = try Data(contentsOf: input)
        let out = try PDFEditTool.run(input, options: ["find": "Quarterly Report", "replace": "Quarterly Totals"]) { _ in }
        let outData = try Data(contentsOf: out)
        c.check(out.lastPathComponent == "cli edited.pdf" && text(outData, 0).hasPrefix("Quarterly Totals"), "CLI: find/replace wrote \(out.lastPathComponent)")
        do { _ = try PDFEditTool.run(input, options: [:]) { _ in }; c.check(false, "CLI: missing find refused") }
        catch { c.check(error.localizedDescription.hasPrefix("Say what to change"), "CLI: \(error.localizedDescription)") }
        do { _ = try PDFEditTool.run(input, options: ["find": "Zebra"]) { _ in }; c.check(false, "CLI: unknown text refused") }
        catch { c.check(error.localizedDescription == "“Zebra” isn’t in cli.pdf.", "CLI: \(error.localizedDescription)") }
        let all = try PDFEditTool.run(input, options: ["find": "lazy", "replace": "sleepy", "all": "true", "spacing": "keep"]) { _ in }
        let ad = try Data(contentsOf: all)
        let count = (0..<3).map { text(ad, $0).components(separatedBy: "sleepy").count - 1 }.reduce(0, +)
        let wanted = (0..<3).map { text(before, $0).components(separatedBy: "lazy").count - 1 }.reduce(0, +)
        let left = (0..<3).map { text(ad, $0).components(separatedBy: "lazy").count - 1 }.reduce(0, +)
        c.check(count == wanted && left == 0, "CLI: all=true replaced all \(count) of \(wanted) “lazy” on 3 pages")
        let json = ##"[{"page":1,"find":"Line 1","replace":"Row 1"},{"page":2,"delete":"Line 8: The quick brown fox jumps over the lazy dog."},{"page":3,"add":"Checked","x":400,"y":60,"size":16,"color":"#CC2200"}]"##
        let je = try PDFEditTool.run(input, options: ["edits": json, "clean": "true"]) { _ in }
        let jd = try Data(contentsOf: je)
        let jsections = (try PDFObjectFile(jd)).sectionCount
        let line8 = text(before, 1).components(separatedBy: "Line 8:").count - text(jd, 1).components(separatedBy: "Line 8:").count
        c.check(text(jd, 0).contains("Row 1: The quick") && line8 == 1 && text(jd, 2).contains("Checked") && jsections == 1,
                "CLI: JSON edits (replace, delete, add) with clean=true")
        c.check((try Data(contentsOf: input)) == before, "CLI: the input file is unchanged")
        c.check(PDFEditTool.applies([input]) && !PDFEditTool.applies([input, input]) && !PDFEditTool.applies([dir.appendingPathComponent("a.png")]),
                "petal applies to exactly one PDF")
    }

    // MARK: - 7. Real fixtures

    static func realFixtures(_ c: Checker, _ dir: URL) throws {
        c.section("fixtures")
        if let u = fixture("tagged.pdf") {
            let data = try Data(contentsOf: u)
            let s = try session(data, "tagged.pdf", dir)
            if let id = line(s, "Quarterly Report") {
                try s.setText(s.line(id)!.text.replacingOccurrences(of: "Report", with: "Résumé"), for: id)
                let out = try s.save()
                let d = try Data(contentsOf: out)
                c.check(text(d, 0).hasPrefix("Quarterly Résumé") && PDFDocument(data: d)?.page(at: 0)?.annotations.count == 1,
                        "tagged: MacRoman font edit reads “Quarterly Résumé”, the note annotation is kept")
            }
        }
        if let u = fixture("big.pdf") {
            let data = try Data(contentsOf: u)
            let t0 = Date()
            let s = try session(data, "big.pdf", dir)
            c.check(s.lines(page: 0).isEmpty && s.banners(page: 0) == [.scanned], "big: an image page with no text (banner scanned)")
            try s.addText("Big label", page: 0, at: CGPoint(x: 100, y: 100), style: PDFTextStyle(size: 60))
            let out = try s.save()
            let d = try Data(contentsOf: out)
            c.check(text(d, 0).contains("Big label") && d.prefix(data.count) == data && d.count - data.count < 40_000,
                    "big: Add Text saved as a \(d.count - data.count)-byte update in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        }
    }
}
#endif
