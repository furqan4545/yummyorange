import AppKit
import PDFKit

/// PDF → TXT and PDF → Markdown (Convert wheel, next to PDF → DOCX in TextDocuments.commands).
///
/// Both rebuild the document with RichPDFReader, the reader PDF → DOCX uses, so the text comes out reflowed:
/// lines join into paragraphs, hyphenated line ends join up, headings, lists, tables and links are recognised
/// and bare page numbers are dropped. On top of that, for text output:
/// - running headers and footers (the same short line at the top or bottom of every page) are left out;
/// - a paragraph cut by a page break is joined up again;
/// - scanned pages (read with OCR) have their wrapped lines joined into paragraphs;
/// - line-by-line documents (a monospaced text dump, or `lines=true`) keep their lines; in Markdown the lines of
///   one block become one paragraph with line breaks instead of a paragraph per line.
/// That is what sets the TXT petal apart from Extract Text, which keeps every page's raw lines.
///
/// Options (`--opt key=value`; every one has a default):
/// - both: `ocr` true | false (read scanned pages with OCR, default true), `lines` auto | true | false (keep every
///   line as its own line; auto does that for monospaced text dumps)
/// - txt: `pageBreaks` false | true (a form feed between pages, as Extract Text writes), `images` false | true
///   (a "[Picture: …]" marker where each picture sits)
/// - md: `images` true | false (pictures go into a "<name> images" folder beside the file)
/// Self-test: `pdf-text-convert` (TextDocumentsPDFTextTests.swift).
extension TextDocuments {
    /// PDF → plain text, reflowed into paragraphs. Writes "<name>.txt".
    static func pdfToText(_ url: URL, options: ToolOptions, progress: (Double) -> Void) throws -> URL {
        var doc = try pdfTextDocument(url, options: options, images: false, pageBreaks: false, progress: progress)
        doc.blocks = withLinkAddresses(doc.blocks)
        let out = outputURL(for: url, ext: "txt")
        do {
            try Data(RichPlainText.text(doc).utf8).write(to: out, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError.toolFailed("Couldn’t save \(out.lastPathComponent): \(error.localizedDescription)")
        }
        progress(1)
        return out
    }

    /// PDF → GitHub-flavoured Markdown. Writes "<name>.md" and, when there are pictures, a "<name> images" folder.
    static func pdfToMarkdown(_ url: URL, options: ToolOptions, progress: (Double) -> Void) throws -> [URL] {
        let doc = try pdfTextDocument(url, options: options, images: true, pageBreaks: false, progress: progress)
        let out = outputURL(for: url, ext: "md")
        let written: [URL]
        do {
            written = try DocumentIO.writeMarkdown(doc, to: out)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError.toolFailed("Couldn’t save \(out.lastPathComponent): \(error.localizedDescription)")
        }
        progress(1)
        return written
    }

    /// The PDF as a document model for text output (see the type comment for what happens on top of the reader).
    /// `images` and `pageBreaks` are the defaults of those options for the target.
    static func pdfTextDocument(_ url: URL, options: ToolOptions, images: Bool, pageBreaks: Bool,
                                progress: (Double) -> Void) throws -> RichDocument {
        // Pages are always read with their breaks: headers and footers are found per page, and a paragraph cut by
        // a break can be joined up. The breaks stay in the result only when `pageBreaks` asks for them.
        var opts = pdfReaderOptions(options, images: images, pageBreaks: true)
        opts.pageBreaks = true
        let keepBreaks = options.bool("pageBreaks", pageBreaks)
        let scan = isScanned(url)
        // Empty pages: said as such (not "pictures", not "a scan"), and without reading them with OCR first.
        if scan, isBlank(url) {
            throw ConversionError.unsupported("No text found in \(url.lastPathComponent): its pages are blank.")
        }
        let scanned = opts.ocr && scan
        var (doc, _) = try RichPDFReader.document(url, options: opts, progress: progress)
        let keepLines = opts.keepLines ?? doc.monospaced
        var blocks = doc.blocks
        // A page with no readable writing comes back from the reader as a picture of the page, even when
        // pictures are off.
        if !opts.images { blocks = withoutPictures(blocks) }
        blocks = withoutRunningHeaders(blocks)
        if scanned && !keepLines { blocks = joinedWrappedLines(blocks) }
        if !keepLines { blocks = joinedAcrossPages(blocks) }
        if !keepBreaks { blocks = withoutPageBreaks(blocks, spaced: !keepLines) }
        blocks = spacedLists(blocks)
        if keepLines || scanned { blocks = linesKeptTogether(blocks) } else { blocks = spacedParagraphs(blocks) }
        doc.blocks = blocks
        guard textCount(doc.blocks) > 0 else {
            if scan && !opts.ocr {
                throw ConversionError.unsupported("No text found in \(url.lastPathComponent): it’s a scan, and OCR is off. "
                                                  + "Convert it with OCR on (ocr=true) to read it.")
            }
            throw ConversionError.unsupported("No text found in \(url.lastPathComponent). Its pages are pictures without "
                                              + "readable writing; convert it to PNG or JPG to keep them.")
        }
        if doc.title == nil { doc.title = url.deletingPathExtension().lastPathComponent }
        return doc
    }

    /// Every page lacks a text layer (a scan), so all of the text will come from OCR.
    static func isScanned(_ url: URL) -> Bool {
        guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 else { return false }
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            if let s = page.string, s.contains(where: { !$0.isWhitespace }) { return false }
        }
        return true
    }

    // MARK: Picture-free and empty documents

    /// Every page is empty paper (nothing drawn on it shows, at a glance). Only asked of a PDF without a text layer,
    /// so a blank one isn't called a scan or pictures.
    static func isBlank(_ url: URL) -> Bool {
        guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0, pdf.pageCount <= 1000 else { return false }
        for i in 0..<pdf.pageCount {
            let blank: Bool = autoreleasepool {
                guard let page = pdf.page(at: i), let image = PDFTools.render(page, dpi: 18, maxPixels: 300) else { return false }
                let w = image.width, h = image.height
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                guard let data = ctx.data else { return false }
                let bytes = data.bindMemory(to: UInt8.self, capacity: w * h)
                return !(0..<(w * h)).contains { bytes[$0] < 250 }
            }
            if !blank { return false }
        }
        return true
    }

    /// The blocks without picture runs, and without paragraphs left empty by that.
    static func withoutPictures(_ blocks: [RichBlock]) -> [RichBlock] {
        func strip(_ p: RichParagraph) -> RichParagraph? {
            guard p.runs.contains(where: { $0.image != nil }) else { return p }
            var q = p
            q.runs.removeAll { $0.image != nil }
            return q.isEmpty ? nil : q
        }
        var out: [RichBlock] = []
        for block in blocks {
            switch block {
            case .paragraph(let p):
                if let q = strip(p) { out.append(.paragraph(q)) }
            case .table(var t):
                for r in t.rows.indices { for c in t.rows[r].indices { t.rows[r][c].paragraphs = t.rows[r][c].paragraphs.compactMap(strip) } }
                out.append(.table(t))
            case .pageBreak:
                // No page break where a page held nothing but pictures.
                if let last = out.last, case .pageBreak = last { continue }
                if !out.isEmpty { out.append(block) }
            default:
                out.append(block)
            }
        }
        while case .pageBreak? = out.last { out.removeLast() }
        return out
    }

    /// Letters and digits in the blocks' text (pictures don't count).
    static func textCount(_ blocks: [RichBlock]) -> Int {
        func count(_ p: RichParagraph) -> Int {
            p.runs.reduce(0) { $0 + ($1.image == nil ? $1.text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count : 0) }
        }
        return blocks.reduce(0) { n, block in
            switch block {
            case .paragraph(let p): return n + count(p)
            case .table(let t): return n + t.rows.joined().reduce(0) { $0 + $1.paragraphs.reduce(0) { $0 + count($1) } }
            default: return n
            }
        }
    }

    // MARK: Pages

    /// Leaves out running headers and footers: a short plain line (not a heading) among the first or last two blocks
    /// of at least half the pages (two at least), the same each time apart from its numbers, and nowhere else in the text.
    static func withoutRunningHeaders(_ blocks: [RichBlock]) -> [RichBlock] {
        // Page ranges between the breaks.
        var pages: [Range<Int>] = []
        var start = 0
        for (i, b) in blocks.enumerated() {
            if case .pageBreak = b { pages.append(start..<i); start = i + 1 }
        }
        pages.append(start..<blocks.count)
        pages = pages.filter { !$0.isEmpty }
        guard pages.count >= 2 else { return blocks }
        func key(_ i: Int) -> String? {
            // Headings don't count: a chapter that starts every page ("Chapter 3") is content.
            guard case .paragraph(let p) = blocks[i], p.kind == .body, p.list.isEmpty, !p.runs.contains(where: { $0.image != nil })
            else { return nil }
            let text = p.text.lowercased().replacingOccurrences(of: "\\d+", with: "#", options: .regularExpression)
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            return text.isEmpty || text.count > 120 ? nil : text
        }
        var edges: [String: Set<Int>] = [:]          // text → pages it sits at the edge of
        var edgeBlocks: [String: [Int]] = [:]
        var edgeIndices = Set<Int>()
        for (n, range) in pages.enumerated() {
            let ends = Array(range.prefix(2)) + Array(range.suffix(2))
            for i in Set(ends) {
                guard let k = key(i) else { continue }
                edges[k, default: []].insert(n)
                edgeBlocks[k, default: []].append(i)
                edgeIndices.insert(i)
            }
        }
        var elsewhere: [String: Int] = [:]
        for i in blocks.indices where !edgeIndices.contains(i) { if let k = key(i), edges[k] != nil { elsewhere[k, default: 0] += 1 } }
        var drop = Set<Int>()
        for (k, onPages) in edges where onPages.count >= max(2, (pages.count + 1) / 2) && elsewhere[k, default: 0] == 0 {
            drop.formUnion(edgeBlocks[k] ?? [])
        }
        guard !drop.isEmpty else { return blocks }
        return blocks.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    /// A body paragraph that runs on over a page break (it ends without closing punctuation and the next page
    /// carries on in lower case) becomes one paragraph again; the page break moves after it.
    static func joinedAcrossPages(_ blocks: [RichBlock]) -> [RichBlock] {
        var out: [RichBlock] = []
        var i = 0
        while i < blocks.count {
            if case .pageBreak = blocks[i], case .paragraph(let a)? = out.last, i + 1 < blocks.count,
               case .paragraph(let b) = blocks[i + 1], runsOn(a, into: b) {
                out[out.count - 1] = .paragraph(joined(a, b))
                out.append(.pageBreak)
                i += 2
                continue
            }
            out.append(blocks[i])
            i += 1
        }
        return out
    }

    /// The blocks without page breaks. With `spaced`, what starts a page is set apart from what ended the one
    /// before (the reader gives a page's first paragraph no space before it), except inside a list.
    static func withoutPageBreaks(_ blocks: [RichBlock], spaced: Bool) -> [RichBlock] {
        var out: [RichBlock] = []
        var afterBreak = false
        for block in blocks {
            if case .pageBreak = block { afterBreak = !out.isEmpty; continue }
            if afterBreak, spaced, case .paragraph(var p) = block {
                let listGoesOn: Bool = {
                    guard case .paragraph(let q)? = out.last else { return false }
                    return !q.list.isEmpty && !p.list.isEmpty
                }()
                if !listGoesOn { p.spaceBefore = max(p.spaceBefore, 8) }
                out.append(.paragraph(p))
            } else {
                out.append(block)
            }
            afterBreak = false
        }
        return out
    }

    // MARK: Paragraphs

    /// OCR gives one paragraph per line. A line that ends mid-sentence and is followed by one starting in lower case
    /// is joined to it (a hyphen at the end joins the word back up); page breaks are crossed too.
    static func joinedWrappedLines(_ blocks: [RichBlock]) -> [RichBlock] {
        var out: [RichBlock] = []
        var pendingBreak = false
        for block in blocks {
            if case .pageBreak = block { pendingBreak = true; out.append(block); continue }
            if case .paragraph(let b) = block {
                // The paragraph before, skipping one page break.
                let back = pendingBreak ? out.count - 2 : out.count - 1
                if back >= 0, case .paragraph(let a) = out[back], runsOn(a, into: b), b.spaceBefore <= 4 || pendingBreak {
                    out[back] = .paragraph(joined(a, b))
                    pendingBreak = false
                    continue
                }
            }
            pendingBreak = false
            out.append(block)
        }
        return out
    }

    /// Whether paragraph `b` carries on the sentence `a` breaks off.
    private static func runsOn(_ a: RichParagraph, into b: RichParagraph) -> Bool {
        guard a.kind == .body, b.kind == .body, b.list.isEmpty, a.quoteDepth == b.quoteDepth,
              !a.runs.contains(where: { $0.image != nil }), !b.runs.contains(where: { $0.image != nil }),
              a.alignment != .center, b.alignment != .center else { return false }
        let end = a.text.trimmingCharacters(in: .whitespaces)
        let start = b.text.trimmingCharacters(in: .whitespaces)
        guard let last = end.last, let first = start.first, first.isLetter, first.isLowercase,
              start.range(of: "^[a-h][.)]\\s", options: .regularExpression) == nil else { return false }
        return !".!?:;…\"”’)]".contains(last)
    }

    /// `a` and `b` as one paragraph, with a space between them, or none where `a` ends in a word-splitting hyphen.
    private static func joined(_ a: RichParagraph, _ b: RichParagraph) -> RichParagraph {
        var p = a
        while let k = p.runs.indices.last, p.runs[k].text.hasSuffix(" ") {
            p.runs[k].text.removeLast()
            if p.runs[k].text.isEmpty { p.runs.removeLast() }
        }
        var runs = b.runs
        let text = p.text
        let hyphenated = text.hasSuffix("-") && text.dropLast().last?.isLetter == true
        if hyphenated, let k = p.runs.indices.last {
            p.runs[k].text.removeLast()
            if p.runs[k].text.isEmpty { p.runs.removeLast() }
        } else if let k = p.runs.indices.last {
            p.runs[k].text += " "
        }
        if let first = runs.first, first.text.hasPrefix(" ") { runs[0].text = String(first.text.drop { $0 == " " }) }
        for r in runs where !r.text.isEmpty || r.image != nil {
            if let last = p.runs.last, last.sameStyle(r) { p.runs[p.runs.count - 1].text += r.text } else { p.runs.append(r) }
        }
        p.spaceAfter = b.spaceAfter
        return p
    }

    /// A list set apart from the paragraph before it (unless that paragraph leads into it, ending in ":"), and a
    /// numbered list from a bulleted one right before it, as the PDF's spacing usually shows but the reader
    /// doesn't always measure.
    static func spacedLists(_ blocks: [RichBlock]) -> [RichBlock] {
        var out = blocks
        for i in out.indices.dropFirst() {
            guard case .paragraph(var p) = out[i], let level = p.list.first, !p.listContinuation,
                  case .paragraph(let prev) = out[i - 1] else { continue }
            if prev.list.isEmpty {
                let leadIn = prev.text.trimmingCharacters(in: .whitespaces).hasSuffix(":")
                if !leadIn, prev.headingLevel == nil { p.spaceBefore = max(p.spaceBefore, 8) }
            } else if p.list.count == 1, let before = prev.list.first, before.ordered != level.ordered {
                p.spaceBefore = max(p.spaceBefore, 8)
            }
            out[i] = .paragraph(p)
        }
        return out
    }

    /// Paragraphs set apart by a blank line in plain text even where the PDF shows them only by an indent or by
    /// starting a new column. Runs of short lines (an address, a poem) stay together, as the PDF shows them.
    static func spacedParagraphs(_ blocks: [RichBlock]) -> [RichBlock] {
        var out = blocks
        for i in out.indices.dropFirst() {
            guard case .paragraph(var p) = out[i], p.kind == .body, p.list.isEmpty, case .paragraph(let prev) = out[i - 1],
                  prev.kind == .body, prev.list.isEmpty else { continue }
            if prev.text.count > 90 || p.text.count > 90 || p.firstLineIndent > 0 {
                p.spaceBefore = max(p.spaceBefore, 8)
                out[i] = .paragraph(p)
            }
        }
        return out
    }

    /// Lines kept as lines: consecutive plain lines with no space between them become one paragraph with line
    /// breaks, so Markdown shows them as one block (a paragraph per line would put a gap after every line).
    /// Plain text comes out the same either way. A line Markdown would read as the start of a heading, list,
    /// quote, rule or table stays a paragraph of its own (it gets escaped there).
    static func linesKeptTogether(_ blocks: [RichBlock]) -> [RichBlock] {
        func plain(_ p: RichParagraph) -> Bool {
            p.kind == .body && p.list.isEmpty && p.quoteDepth == 0 && !p.isEmpty && !p.runs.contains { $0.image != nil }
        }
        var out: [RichBlock] = []
        for block in blocks {
            if case .paragraph(let b) = block, plain(b), b.spaceBefore <= 0.5, !startsBlock(b.text),
               case .paragraph(var a)? = out.last, plain(a), a.spaceAfter <= 0.5, a.alignment == b.alignment {
                while let k = a.runs.indices.last, a.runs[k].text.hasSuffix(" ") {
                    a.runs[k].text.removeLast()
                    if a.runs[k].text.isEmpty { a.runs.removeLast() }
                }
                if let k = a.runs.indices.last { a.runs[k].text += "\u{2028}" }
                for r in b.runs {
                    if let last = a.runs.last, last.sameStyle(r) { a.runs[a.runs.count - 1].text += r.text } else { a.runs.append(r) }
                }
                a.spaceAfter = b.spaceAfter
                out[out.count - 1] = .paragraph(a)
                continue
            }
            out.append(block)
        }
        return out
    }

    /// Text that, on a line of its own inside a Markdown paragraph, would start a heading, list, quote, code
    /// fence, rule, table or HTML block.
    static func startsBlock(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let c = t.first else { return true }
        if "#>|<".contains(c) || t.hasPrefix("```") || t.hasPrefix("~~~") { return true }
        if "-+*".contains(c), t.dropFirst().first == " " || t.dropFirst().first == "\t" || t.count == 1 { return true }
        if t.range(of: "^\\d{1,9}[.)](\\s|$)", options: .regularExpression) != nil { return true }
        if t.allSatisfy({ "=-_*|: \t".contains($0) }) { return true }
        return false
    }

    /// Plain text can't link, so a link's address follows its text in brackets ("the website (https://…)"),
    /// unless the text already is the address.
    static func withLinkAddresses(_ blocks: [RichBlock]) -> [RichBlock] {
        func spelled(_ p: RichParagraph) -> RichParagraph {
            var q = p
            var runs: [RichRun] = []
            var k = 0
            while k < p.runs.count {
                guard let link = p.runs[k].link else { runs.append(p.runs[k]); k += 1; continue }
                var end = k
                while end + 1 < p.runs.count, p.runs[end + 1].link == link { end += 1 }
                runs += p.runs[k...end]
                let text = p.runs[k...end].map(\.text).joined().trimmingCharacters(in: .whitespaces)
                let bare = link.hasPrefix("mailto:") ? String(link.dropFirst(7)) : link
                let same = [link, bare].contains { $0 == text || $0 == "http://" + text || $0 == "https://" + text || $0 == text + "/" }
                if !same, !text.isEmpty {
                    let trail = String(runs[runs.count - 1].text.reversed().prefix { $0 == " " })
                    runs[runs.count - 1].text = String(runs[runs.count - 1].text.dropLast(trail.count))
                    var address = p.runs[end]
                    address.link = nil
                    address.image = nil
                    address.text = " (\(bare))" + trail
                    runs.append(address)
                }
                k = end + 1
            }
            q.runs = runs
            return q
        }
        return blocks.map { block in
            switch block {
            case .paragraph(let p): return .paragraph(spelled(p))
            case .table(var t):
                for r in t.rows.indices { for c in t.rows[r].indices { t.rows[r][c].paragraphs = t.rows[r][c].paragraphs.map(spelled) } }
                return .table(t)
            default: return block
            }
        }
    }
}
