import AppKit
import PDFKit

/// Rebuilds an editable document from a PDF. Lines come from character positions on each page (PDFKit's
/// own line breaks are unreliable), lines join into paragraphs by spacing, indentation and line length,
/// font sizes and bold/italic are kept, larger text becomes headings, "•" and "1." lines become lists,
/// link annotations become links, the page's larger pictures are embedded where they sit, scanned pages
/// are read with OCR, and each page ends with a page break.
enum RichPDFReader {
    /// What to rebuild: OCR for scans, pictures, page breaks, and whether to keep every line.
    struct Options {
        var ocr = true
        var images = true
        var pageBreaks = true
        /// nil: keep each line as its own paragraph only for monospaced (text-dump) PDFs.
        var keepLines: Bool?
    }

    /// One character from the text layer, where it sits and how it looks.
    private struct Glyph {
        var text: String
        var rect: CGRect
        var font: FontFacts
        var color: String?
        var link: String?
        /// Some PDFs report absurd widths for a few glyphs (hundreds of points); those only count vertically.
        var plausible: Bool { rect.width > 0 && rect.width <= max(rect.height, font.size) * 1.6 }
    }

    /// Characters that share a baseline, with their extent.
    private struct Line {
        var glyphs: [Glyph] = []
        var minX: CGFloat = .infinity, maxX: CGFloat = -.infinity, minY: CGFloat = .infinity, maxY: CGFloat = -.infinity
        var text: String { glyphs.map(\.text).joined() }
        var size: CGFloat {
            var count: [CGFloat: Int] = [:]
            for g in glyphs where !g.text.trimmingCharacters(in: .whitespaces).isEmpty { count[(g.font.size * 2).rounded() / 2, default: 0] += 1 }
            return count.max { $0.value < $1.value }?.key ?? 12
        }
        var allBold: Bool { glyphs.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.allSatisfy(\.font.bold) }
        var allMono: Bool { glyphs.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.allSatisfy(\.font.mono) }
        mutating func add(_ g: Glyph) {
            glyphs.append(g)
            if g.plausible { minX = min(minX, g.rect.minX); maxX = max(maxX, g.rect.maxX) }
            if g.rect.height > 0 { minY = min(minY, g.rect.minY); maxY = max(maxY, g.rect.maxY) }
        }
        var hasY: Bool { minY.isFinite }
    }

    /// A picture and where it sits on the page.
    private struct PageImage { var rect: CGRect; var image: RichImage }

    static func document(_ url: URL, options: Options = Options(), progress: (Double) -> Void = { _ in }) throws -> (RichDocument, RichPageSetup) {
        guard let pdf = PDFDocument(url: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
        if pdf.isLocked {
            throw ConversionError.unsupported("\(url.lastPathComponent) is password-protected. Use Remove Password first.")
        }
        guard pdf.pageCount > 0 else { throw ConversionError.unsupported("\(url.lastPathComponent) has no pages.") }

        // Pass 1: lines of every page.
        var pages: [(lines: [Line], images: [PageImage], ocr: [String]?)] = []
        for i in 0..<pdf.pageCount {
            // Each page's PDFKit text, selections and renderings are let go before the next page: a long book
            // would otherwise hold every page's at once (gigabytes for a few thousand pages).
            autoreleasepool {
                guard let page = pdf.page(at: i) else { return }
                var lines = textLines(page)
                var ocr: [String]?
                let hasText = lines.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                if !hasText, options.ocr, let ref = page.pageRef, let image = PDFTools.scanImage(ref) {
                    ocr = (try? PDFTools.recognizeTextAnyOrientation(in: image))?.components(separatedBy: "\n") ?? []
                    lines = []
                }
                var images = options.images ? pictures(page, scanned: !hasText) : []
                // A page with neither text nor readable writing (a photo, a drawing) comes across as a picture.
                let ocrChars = ocr?.joined().filter { !$0.isWhitespace }.count ?? 0
                if !hasText && ocrChars < 20 {
                    ocr = nil
                    images = pictures(page, scanned: false, wholePage: true)
                    if images.isEmpty, let ref = page.pageRef, let image = PDFTools.render(ref, dpi: 150, maxPixels: 3000), let png = RichImage.jpegData(image),
                       let picture = RichImage.from(data: png, name: "page\(i + 1).png",
                                                    display: (((ref.rotationAngle % 360) + 360) % 360) / 90 % 2 == 1
                                                        ? CGSize(width: ref.getBoxRect(.cropBox).height, height: ref.getBoxRect(.cropBox).width)
                                                        : ref.getBoxRect(.cropBox).size) {
                        images = [PageImage(rect: ref.getBoxRect(.cropBox), image: picture)]
                    }
                }
                pages.append((lines, images, ocr))
            }
            progress(Double(i + 1) / Double(pdf.pageCount) * 0.8)
        }

        // Document-wide facts: body size and family, margins, whether it's a monospaced text dump.
        var sizeCount: [CGFloat: Int] = [:], familyCount: [String: Int] = [:], monoCount = 0, glyphCount = 0
        var lefts: [CGFloat] = [], rights: [CGFloat] = []
        for page in pages {
            for line in page.lines {
                for g in line.glyphs where !g.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    sizeCount[(g.font.size * 2).rounded() / 2, default: 0] += 1
                    familyCount[g.font.family, default: 0] += 1
                    glyphCount += 1
                    if g.font.mono { monoCount += 1 }
                }
                if line.minX.isFinite { lefts.append(line.minX); rights.append(line.maxX) }
            }
        }
        var doc = RichDocument()
        doc.title = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
        doc.bodySize = sizeCount.max { $0.value < $1.value }?.key ?? 12
        doc.bodyFamily = familyCount.max { $0.value < $1.value }?.key ?? RichStyle.bodyFamily
        doc.monospaced = glyphCount > 0 && Double(monoCount) / Double(glyphCount) > 0.9
        let keepLines = options.keepLines ?? doc.monospaced
        lefts.sort(); rights.sort()
        let left = lefts.isEmpty ? 72 : lefts[lefts.count / 10]
        let right = rights.isEmpty ? 540 : rights[rights.count * 9 / 10]

        let first = pdf.page(at: 0)!.bounds(for: .cropBox)
        let rotated = (pdf.page(at: 0)!.rotation / 90) % 2 == 1
        let pageSize = rotated ? CGSize(width: first.height, height: first.width) : first.size
        let marginL = min(108, max(36, left - first.minX)), marginR = min(108, max(36, first.maxX - right))
        let setup = RichPageSetup(size: CGSize(width: pageSize.width.rounded(), height: pageSize.height.rounded()),
                              margins: NSEdgeInsets(top: 72, left: marginL.rounded(), bottom: 72, right: marginR.rounded()))

        // Pass 2: paragraphs.
        var anything = false
        for (pi, page) in pages.enumerated() {
            var blocks: [(top: CGFloat, block: RichBlock)] = []
            if let ocr = page.ocr {
                var spaced = false
                for raw in ocr {
                    let text = raw.trimmingCharacters(in: .whitespaces)
                    if text.isEmpty { spaced = true; continue }
                    var p = RichParagraph()
                    p.spaceBefore = spaced ? 10 : 0
                    p.runs = [RichRun(text: text, size: doc.bodySize)]
                    blocks.append((.infinity, .paragraph(p)))
                    spaced = false
                }
            } else {
                // Bare page numbers in the top or bottom margin ("3", "Page 3", "3 / 12") aren't content.
                let height = pdf.page(at: pi)?.bounds(for: .cropBox).height ?? 792
                let lines = page.lines.filter { l in
                    let inMargin = l.minY < 54 || l.maxY > height - 40
                    return !(inMargin && l.text.range(of: "^\\s*(page\\s*)?\\d{1,4}(\\s*(/|of)\\s*\\d{1,4})?\\s*$",
                                                      options: [.regularExpression, .caseInsensitive]) != nil)
                }
                blocks += self.blocks(lines, doc: doc, left: left, right: right, keepLines: keepLines)
            }
            // Pictures go before the first paragraph that starts below their top edge.
            for picture in page.images.sorted(by: { $0.rect.maxY > $1.rect.maxY }) {
                var p = RichParagraph()
                p.alignment = abs(picture.rect.midX - (left + right) / 2) < 30 ? .center : .natural
                p.spaceBefore = 6; p.spaceAfter = 6
                p.runs = [RichRun(text: "\u{FFFC}", size: doc.bodySize, image: picture.image)]
                let index = blocks.firstIndex { $0.top < picture.rect.maxY - 2 } ?? blocks.count
                blocks.insert((picture.rect.maxY, .paragraph(p)), at: index)
            }
            if !blocks.isEmpty { anything = true }
            doc.blocks += blocks.map(\.block)
            if options.pageBreaks, pi < pages.count - 1, !blocks.isEmpty { doc.blocks.append(.pageBreak) }
        }
        while case .pageBreak? = doc.blocks.last { doc.blocks.removeLast() }
        guard anything else { throw ConversionError.unsupported("No text found in \(url.lastPathComponent).") }
        // Runs in the main family don't need to name it.
        for i in doc.blocks.indices {
            guard case .paragraph(var p) = doc.blocks[i] else { continue }
            for k in p.runs.indices where p.runs[k].family == doc.bodyFamily { p.runs[k].family = nil }
            doc.blocks[i] = .paragraph(p)
        }
        progress(0.9)
        return (doc, setup)
    }

    // MARK: Lines

    /// The rebuilt lines of every page, with their left edge, baseline and size (for `--selftest textdocs-pdflines:`).
    static func lineDump(_ url: URL) -> String {
        guard let pdf = PDFDocument(url: url) else { return "FAIL unreadable" }
        var out: [String] = []
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            out.append("page \(i + 1)")
            for l in textLines(page) {
                out.append(String(format: "  x=%.1f..%.1f y=%.1f size=%.1f bold=%d ", l.minX, l.maxX, l.minY, l.size, l.allBold ? 1 : 0) + String(reflecting: l.text))
            }
        }
        return out.joined(separator: "\n")
    }

    /// The page's characters grouped into lines by vertical overlap (as Extract Text does), with fonts,
    /// colors and link targets.
    private static func textLines(_ page: PDFPage) -> [Line] {
        guard let string = page.string, !string.isEmpty else { return [] }
        let ns = string as NSString
        let attributed = page.attributedString
        let useAttributes = attributed?.length == ns.length
        let links: [(CGRect, String)] = page.annotations.compactMap { a in
            guard let url = a.url ?? (a.action as? PDFActionURL)?.url, RichDocument.isSafeLink(url.absoluteString) else { return nil }
            return (a.bounds, url.absoluteString)
        }
        var lines: [Line] = []
        var line = Line()
        var lastFont = FontFacts(nil)
        var lastColor: String?
        func endLine() {
            while let last = line.glyphs.last, last.text.trimmingCharacters(in: .whitespaces).isEmpty { line.glyphs.removeLast() }
            while let first = line.glyphs.first, first.text.trimmingCharacters(in: .whitespaces).isEmpty { line.glyphs.removeFirst() }
            if !line.glyphs.isEmpty, line.hasY {
                if !line.minX.isFinite { line.minX = line.glyphs.first?.rect.minX ?? 0; line.maxX = line.glyphs.last?.rect.maxX ?? 0 }
                lines.append(line)
            } else if !line.glyphs.isEmpty, !lines.isEmpty {
                // Characters without any box of their own still belong to the text: they join the line before.
                lines[lines.count - 1].glyphs.append(Glyph(text: " ", rect: .zero, font: lastFont, color: nil, link: nil))
                lines[lines.count - 1].glyphs += line.glyphs
            }
            line = Line()
        }
        // characterBounds(at:) counts glyphs, which drift from page.string's characters after every
        // ligature ("fi", "ffl") and, in some PDFs, after PDFKit's added line breaks. The indexer checks
        // both numberings against one-character selections and falls back to selections when neither fits.
        let glyphBox = SpreadsheetsFromPDF.glyphIndexer(page, (0..<ns.length).map { ns.character(at: $0) })
        var i = 0
        while i < ns.length {
            let r = ns.rangeOfComposedCharacterSequence(at: i)
            let text = ns.substring(with: r)
            i = NSMaxRange(r)
            if text == "\n" || text == "\r" || text == "\r\n" || text == "\u{2029}" || text == "\u{2028}" { endLine(); continue }
            let found = glyphBox(r.location)
            let rect = found.isNull ? .zero : found
            let blank = text.trimmingCharacters(in: .whitespaces).isEmpty
            if blank {
                // Real spaces are kept (monospaced text lines things up with them); none at a line's start.
                if !line.glyphs.isEmpty {
                    line.glyphs.append(Glyph(text: text == "\t" ? "\t" : " ", rect: .zero, font: lastFont, color: nil, link: line.glyphs.last?.link))
                }
                continue
            }
            if rect.width <= 0 && rect.height <= 0 {
                // A character with no box (PDFKit gives none for some): kept on the line being built.
                line.glyphs.append(Glyph(text: text, rect: .zero, font: lastFont, color: lastColor, link: line.glyphs.last?.link))
                continue
            }
            var font = lastFont
            var color: String?
            if useAttributes, let attributed {
                let attrs = attributed.attributes(at: r.location, effectiveRange: nil)
                font = FontFacts(attrs[.font] as? NSFont)
                if let c = attrs[.foregroundColor] as? NSColor, let h = RichDocument.hex(c), !RichDocument.isPlain(h, link: false) { color = h }
            } else {
                font.size = max(4, rect.height)
            }
            lastFont = font
            lastColor = color
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let link = links.first { $0.0.insetBy(dx: -1, dy: -1).contains(center) }?.1
            let glyph = Glyph(text: text, rect: rect, font: font, color: color, link: link)
            if line.hasY {
                let overlap = min(rect.maxY, line.maxY) - max(rect.minY, line.minY)
                var backwards = false, gap = false
                if glyph.plausible, let last = line.glyphs.last(where: \.plausible) {
                    backwards = rect.minX < last.rect.maxX - max(30, 3 * rect.height)
                    gap = rect.minX - last.rect.maxX > 0.3 * max(rect.height, font.size)
                }
                if overlap < 0.25 * min(rect.height, line.maxY - line.minY) || backwards {
                    endLine()
                } else if let last = line.glyphs.last(where: \.plausible), glyph.plausible,
                          rect.minX - last.rect.maxX > max(2 * font.size, 20) {
                    // A wide gap is a column boundary (tables, tab stops).
                    while line.glyphs.last?.text == " " { line.glyphs.removeLast() }
                    line.glyphs.append(Glyph(text: "\t", rect: .zero, font: font, color: nil, link: nil))
                } else if gap, line.glyphs.last?.text != " " {
                    line.glyphs.append(Glyph(text: " ", rect: .zero, font: font, color: nil, link: nil))   // a gap PDFKit didn't fill
                }
            }
            line.add(glyph)
        }
        endLine()
        return lines
    }

    // MARK: Paragraphs

    private static let bulletChars: Set<Character> = ["•", "◦", "▪", "▫", "●", "○", "■", "□", "‣", "⁃", "–", "-", "*", "·", "➢", "►", "✓", "✔"]

    /// A line's cells: its glyphs split at column gaps (marked "\t" while the line was built).
    private static func cells(_ line: Line) -> [[Glyph]] {
        var out: [[Glyph]] = [[]]
        for g in line.glyphs {
            if g.text == "\t" { out.append([]) } else { out[out.count - 1].append(g) }
        }
        return out.map { cell in
            var c = cell
            while c.first?.text == " " { c.removeFirst() }
            while c.last?.text == " " { c.removeLast() }
            return c
        }.filter { !$0.isEmpty }
    }

    /// Turns lines into blocks: tables from runs of lines with the same columns, paragraphs from the rest.
    /// Returns each block with its top edge (PDF y, for placing pictures).
    private static func blocks(_ lines: [Line], doc: RichDocument, left: CGFloat, right: CGFloat, keepLines: Bool) -> [(CGFloat, RichBlock)] {
        guard !lines.isEmpty else { return [] }
        // Typical distance between baselines of body lines.
        var pitches: [CGFloat] = []
        for k in 1..<max(1, lines.count) where k < lines.count {
            let d = lines[k - 1].minY - lines[k].minY
            if d > 0, d < 3 * lines[k].size, abs(lines[k].size - doc.bodySize) < 1 { pitches.append(d) }
        }
        pitches.sort()
        let pitch = pitches.isEmpty ? doc.bodySize * 1.2 : pitches[pitches.count / 2]
        let width = max(100, right - left)
        // Side-by-side columns: a line can only run to its own column's edges, so the full lines of a left column
        // aren't taken for the short last lines of paragraphs. Only where some line sits beside it.
        let columnEdges: [(left: CGFloat, right: CGFloat)] = lines.count > 2000 ? lines.map { _ in (left, right) } : lines.map { l in
            let beside = lines.contains { o in
                min(o.maxY, l.maxY) - max(o.minY, l.minY) > 0 && (o.minX > l.maxX + l.size || o.maxX < l.minX - l.size)
            }
            guard beside else { return (left, right) }
            let column = lines.filter { o in abs(o.minY - l.minY) < 6 * pitch && o.minX < l.maxX && o.maxX > l.minX }
            return (max(left, column.map(\.minX).min() ?? left), min(right, column.map(\.maxX).max() ?? right))
        }
        // List nesting from where markers sit: marker positions within 8 pt of each other are one level.
        var markerXs: [CGFloat] = []
        for l in lines where startsList(l.text) != nil {
            if !markerXs.contains(where: { abs($0 - l.minX) < 8 }) { markerXs.append(l.minX) }
        }
        markerXs.sort()
        var listLevels: [RichListLevel] = []

        var out: [(CGFloat, RichBlock)] = []
        var group: [Line] = []
        var gapBefore: CGFloat = 0
        var groupRTL = false

        func flush() {
            guard !group.isEmpty else { return }
            var p = paragraph(group, doc: doc, left: left, right: right, gapBefore: gapBefore)
            if let level = p.list.last {
                let depth = (markerXs.firstIndex { abs($0 - group[0].minX) < 8 } ?? 0) + 1
                var levels = Array(listLevels.prefix(depth - 1))
                while levels.count < depth - 1 { levels.append(levels.last ?? level) }
                levels.append(level)
                p.list = levels
                listLevels = levels
            } else {
                listLevels = []
            }
            out.append((group[0].maxY, .paragraph(p)))
            group = []
        }

        var k = 0
        while k < lines.count {
            let line = lines[k]
            // Two or more lines in a row with the same number (≥ 2) of columns make a table.
            let columns = cells(line).count
            if columns >= 2 {
                var end = k + 1
                while end < lines.count, cells(lines[end]).count == columns, abs(lines[end].size - line.size) < 1.5,
                      lines[end - 1].minY - lines[end].minY < 4 * max(pitch, line.size) {
                    end += 1
                }
                if end - k >= 2 {
                    flush()
                    var rows: [[RichCell]] = []
                    for row in lines[k..<end] {
                        rows.append(cells(row).map { glyphs in
                            var cp = RichParagraph()
                            cp.runs = runs(glyphs, doc: doc)
                            return RichCell(paragraphs: [cp])
                        })
                    }
                    let header = lines[k].allBold && !lines[k + 1].allBold
                    out.append((line.maxY, .table(RichTable(rows: rows, headerRows: header ? 1 : 0))))
                    listLevels = []
                    gapBefore = 0
                    k = end
                    continue
                }
            }
            k += 1
            guard let prev = group.last else { gapBefore = 0; group = [line]; groupRTL = isRightToLeft(line.text); continue }
            let step = prev.minY - line.minY
            let extra = step - max(pitch, line.size * 1.1)
            var breakHere = keepLines || columns >= 2 || cells(prev).count >= 2
            if abs(prev.size - line.size) > 0.6 { breakHere = true }
            if step < -2 || step > max(pitch, prev.size) * 1.45 { breakHere = true }
            if startsList(line.text) != nil { breakHere = true }
            // Where a line starts (`lead`) and ends (`trail`) in its reading direction: right-to-left paragraphs
            // (Hebrew, Arabic) start at the right edge and leave their short last line and indents at the left.
            let rtl = groupRTL
            func lead(_ l: Line) -> CGFloat { rtl ? -l.maxX : l.minX }
            func trail(_ l: Line) -> CGFloat { rtl ? -l.minX : l.maxX }
            let columnEnd = rtl ? -columnEdges[k - 2].left : columnEdges[k - 2].right
            // A short line ends its paragraph, unless the next line's first word wouldn't have fitted in the room
            // left: then the line was full and only wrapped early (ragged right before a long word).
            if trail(prev) < columnEnd - max(3 * line.size, 0.12 * width),
               columnEnd - trail(prev) > firstWordWidth(line) + 0.25 * line.size { breakHere = true }
            // An indented line after a full one starts a paragraph (first-line indents), except inside a
            // list item, whose later lines are indented to its text.
            let listItem = startsList(group[0].text) != nil
            if !listItem && lead(line) > lead(prev) + 1.5 * line.size { breakHere = true }
            if listItem && lead(line) < lead(group[0]) + 0.5 * line.size && lead(line) < lead(prev) - 0.5 * line.size { breakHere = true }
            if prev.allBold != line.allBold { breakHere = true }
            // A line indented less than the paragraph's continuation lines starts something new.
            if group.count >= 2, lead(line) < lead(group[1]) - 1.5 * line.size { breakHere = true }
            if breakHere {
                flush()
                gapBefore = max(0, extra)
                groupRTL = isRightToLeft(line.text)
            }
            group.append(line)
        }
        flush()
        return out
    }

    /// The width of a line's first word (in reading order), from its glyphs' boxes; 0 when they have none.
    private static func firstWordWidth(_ line: Line) -> CGFloat {
        var lo = CGFloat.infinity, hi = -CGFloat.infinity
        var started = false
        for g in line.glyphs {
            if g.text == " " || g.text == "\t" { if started { break } else { continue } }
            started = true
            if g.plausible { lo = min(lo, g.rect.minX); hi = max(hi, g.rect.maxX) }
        }
        return hi > lo ? hi - lo : 0
    }

    /// Most of the line's letters are from a right-to-left script (Hebrew, Arabic, Syriac, Thaana, N’Ko…).
    static func isRightToLeft(_ text: String) -> Bool {
        var rtl = 0, ltr = 0
        for u in text.unicodeScalars {
            switch u.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: rtl += 1
            default: if u.properties.isAlphabetic { ltr += 1 }
            }
        }
        return rtl > ltr
    }

    /// The marker style and text length when a line starts like a list item.
    private static func startsList(_ text: String) -> (RichListLevel, Int, Int)? {
        let t = text.drop { $0 == " " }
        let offset = text.count - t.count
        if let c = t.first, bulletChars.contains(c), t.dropFirst().first == " " || t.dropFirst().first == "\t" {
            let style: RichListLevel.Style = c == "◦" || c == "○" ? .circle : (c == "▪" || c == "■" || c == "□" || c == "▫") ? .square
                : (c == "–" || c == "-" || c == "⁃") ? .dash : .bullet
            return (RichListLevel(style: style), 1, offset + 2)
        }
        if let m = t.range(of: "^\\d{1,3}[.)][ \\t]", options: .regularExpression) {
            let n = Int(t[m].dropLast(2)) ?? 1
            return (RichListLevel(style: .decimal), n, offset + t.distance(from: t.startIndex, to: m.upperBound))
        }
        if let m = t.range(of: "^[a-h][.)][ \\t]", options: .regularExpression) {
            let n = Int(t.first!.asciiValue! - 96)
            return (RichListLevel(style: .lowerAlpha), n, offset + t.distance(from: t.startIndex, to: m.upperBound))
        }
        return nil
    }

    /// Glyphs → runs: neighbours with the same look merge; spaces take the look of what's before them.
    private static func runs(_ glyphs: [Glyph], doc: RichDocument) -> [RichRun] {
        var out: [RichRun] = []
        for g in glyphs {
            if g.text == " " || g.text == "\t" {
                if !out.isEmpty { out[out.count - 1].text += g.text }
                continue
            }
            var run = RichRun(text: g.text)
            run.bold = g.font.bold
            run.italic = g.font.italic
            run.size = g.font.size
            run.family = g.font.family
            run.color = g.color
            run.link = g.link
            run.code = g.font.mono && !doc.monospaced
            if let last = out.last, last.sameStyle(run) { out[out.count - 1].text += run.text } else { out.append(run) }
        }
        while let last = out.last, last.text.hasSuffix(" ") || last.text.hasSuffix("\t") {
            out[out.count - 1].text.removeLast()
            if out[out.count - 1].text.isEmpty { out.removeLast() }
        }
        return out
    }

    private static func paragraph(_ lines: [Line], doc: RichDocument, left: CGFloat, right: CGFloat, gapBefore: CGFloat) -> RichParagraph {
        var p = RichParagraph()
        // Glyphs of all lines, joined with spaces; a hyphen at a line end joins the word back up.
        var glyphs: [Glyph] = []
        for (k, line) in lines.enumerated() {
            var g = line.glyphs
            if k > 0, let last = glyphs.last {
                let joinsWord = last.text == "-" && glyphs.count >= 2 && glyphs[glyphs.count - 2].text.first?.isLetter == true
                    && g.first?.text.first?.isLowercase == true
                if joinsWord { glyphs.removeLast() }
                else if last.text != " " { glyphs.append(Glyph(text: " ", rect: .zero, font: last.font, color: last.color, link: nil)) }
            }
            if k == 0, let (level, number, length) = startsList(line.text) {
                var dropped = 0
                while dropped < length, !g.isEmpty { dropped += g.removeFirst().text.count }
                p.list = [level]
                p.itemNumber = number
            }
            glyphs += g
        }
        p.runs = runs(glyphs, doc: doc)
        let size = lines.map(\.size).max() ?? doc.bodySize
        let ratio = size / max(doc.bodySize, 1)
        if p.list.isEmpty, lines.count <= 3, p.text.count < 200 {
            if ratio >= 1.85 { p.kind = .heading(1) }
            else if ratio >= 1.45 { p.kind = .heading(2) }
            else if ratio >= 1.18 { p.kind = .heading(3) }
            else if ratio >= 1.05, lines.allSatisfy(\.allBold) { p.kind = .heading(4) }
        }
        // Whole-paragraph monospace in a proportional document is code.
        if p.kind == .body, !doc.monospaced, lines.allSatisfy(\.allMono) {
            p.kind = .code("")
            for k in p.runs.indices { p.runs[k].code = false }
        }
        let minX = lines.map(\.minX).min() ?? left, maxX = lines.map(\.maxX).max() ?? right
        let width = right - left
        let center = (left + right) / 2
        if p.list.isEmpty {
            if abs((minX + maxX) / 2 - center) < max(6, width * 0.03), minX > left + 2 * size, maxX < right - 2 * size {
                p.alignment = .center
            } else if lines.count == 1, minX > left + width * 0.3, abs(maxX - right) < size {
                p.alignment = .right
            } else {
                let rest = lines.count > 1 ? lines.dropFirst().map(\.minX).min()! : minX
                if rest - left > 4 { p.leftIndent = (rest - left).rounded() }
                if lines.count > 1, abs(lines[0].minX - rest) > 4 { p.firstLineIndent = (lines[0].minX - rest).rounded() }
                else if lines.count == 1, lines[0].minX - left > 4 { p.leftIndent = (lines[0].minX - left).rounded() }
            }
        }
        p.spaceBefore = min(36, gapBefore.rounded())
        if lines.count > 1 {
            let step = (lines.first!.minY - lines.last!.minY) / CGFloat(lines.count - 1)
            let natural = size * 1.2
            if step > natural * 1.08 { p.lineHeight = min(3, (step / natural * 100).rounded() / 100) }
        }
        return p
    }

    // MARK: Pictures

    /// The page's larger pictures with where they sit (PDF points). A scanned page's full-page image is
    /// left out: its text is what OCR reads. JPEGs are taken from the file as they are; other pictures are
    /// cut from a rendering of the page.
    private static func pictures(_ page: PDFPage, scanned: Bool, wholePage: Bool = false) -> [PageImage] {
        guard let ref = page.pageRef else { return [] }
        let box = ref.getBoxRect(.cropBox)
        let area = box.width * box.height
        var out: [PageImage] = []
        var rendered: (image: CGImage, scale: CGFloat)?
        // The page as shown (after /Rotate), and the transform from page space onto it (bottom-left origin).
        let turned = (((ref.rotationAngle % 360) + 360) % 360) / 90 % 2 == 1
        let shown = turned ? CGSize(width: box.height, height: box.width) : box.size
        let toShown = ref.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: shown), rotate: 0, preserveAspectRatio: true)
        let upright = ((ref.rotationAngle % 360) + 360) % 360 == 0
        let all = RichPDFImageFinder.images(on: ref)
        // Render at the resolution the pictures were stored at (72–300 DPI), not more.
        let dpi = min(300, max(72, all.map { CGFloat($0.pixelWidth) / max(1, $0.rect.width / 72) }.max() ?? 150))
        for found in all {
            let r = found.rect.intersection(box)
            guard !r.isNull, r.width >= 24, r.height >= 24, r.width * r.height >= area * 0.015 else { continue }
            if !wholePage, r.width * r.height > area * (scanned ? 0.5 : 0.85) { continue }
            var picture: RichImage?
            if upright, found.isJPEG, found.straight, let data = found.jpegData, let img = RichImage.from(data: data, name: "picture", display: r.size) {
                picture = img
            }
            if picture == nil {
                // Cut from a rendering of the page as shown, so pictures on turned pages (/Rotate) come out
                // the way the reader sees them.
                if rendered == nil, let img = PDFTools.render(ref, dpi: dpi, maxPixels: 4000) { rendered = (img, CGFloat(img.width) / max(1, shown.width)) }
                if let (img, scale) = rendered {
                    let d = r.applying(toShown)
                    let crop = CGRect(x: d.minX * scale, y: (shown.height - d.maxY) * scale,
                                      width: d.width * scale, height: d.height * scale).integral
                    // Big pictures (photos, scans) as JPEG; small ones (diagrams, logos) as PNG.
                    if let cut = img.cropping(to: crop),
                       let data = cut.width * cut.height > 400_000 ? RichImage.jpegData(cut) : RichImage.pngData(cut) {
                        picture = RichImage.from(data: data, name: "picture", display: d.size)
                    }
                }
            }
            if var picture {
                picture.name = "picture\(out.count + 1).\(picture.fileExtension)"
                out.append(PageImage(rect: r, image: picture))
            }
        }
        return out
    }
}

/// Finds where image XObjects are drawn on a page by following the content stream's transforms
/// (q, Q, cm, Do), including images inside form XObjects.
final class RichPDFImageFinder {
    /// An image drawn on the page.
    struct Found {
        var rect: CGRect
        var isJPEG: Bool
        /// Drawn upright and unmirrored, so the stored JPEG looks like the page.
        var straight: Bool
        var jpegData: Data?
        var pixelWidth: Int
    }

    private var ctm = CGAffineTransform.identity
    private var stack: [CGAffineTransform] = []
    private var found: [Found] = []
    private var depth = 0
    private let table: CGPDFOperatorTableRef

    private init() {
        table = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let f = Unmanaged<RichPDFImageFinder>.fromOpaque(info!).takeUnretainedValue()
            f.stack.append(f.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let f = Unmanaged<RichPDFImageFinder>.fromOpaque(info!).takeUnretainedValue()
            if let last = f.stack.popLast() { f.ctm = last }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let f = Unmanaged<RichPDFImageFinder>.fromOpaque(info!).takeUnretainedValue()
            var v = [CGPDFReal](repeating: 0, count: 6)
            for k in (0..<6).reversed() { guard CGPDFScannerPopNumber(scanner, &v[k]) else { return } }
            f.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(f.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let f = Unmanaged<RichPDFImageFinder>.fromOpaque(info!).takeUnretainedValue()
            var name: UnsafePointer<Int8>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let cs = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(cs, "XObject", name) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<Int8>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return }
            switch String(cString: subtype) {
            case "Image":
                let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(f.ctm)
                var format = CGPDFDataFormat.raw
                var data: Data?
                var smask: CGPDFObjectRef?
                let masked = CGPDFDictionaryGetObject(dict, "SMask", &smask)
                if !masked, let d = CGPDFStreamCopyData(stream, &format), format == .jpegEncoded { data = d as Data }
                let straight = f.ctm.b == 0 && f.ctm.c == 0 && f.ctm.a > 0 && f.ctm.d > 0
                var width: CGPDFInteger = 0
                _ = CGPDFDictionaryGetInteger(dict, "Width", &width)
                f.found.append(Found(rect: rect, isJPEG: data != nil, straight: straight, jpegData: data, pixelWidth: Int(width)))
            case "Form":
                guard f.depth < 4 else { return }
                var matrix = CGAffineTransform.identity
                var array: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dict, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
                    var v = [CGPDFReal](repeating: 0, count: 6)
                    for k in 0..<6 { _ = CGPDFArrayGetNumber(array, k, &v[k]) }
                    matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                }
                var resources: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(dict, "Resources", &resources)
                // Without its own resources a form looks names up in its parent stream.
                let inner = CGPDFContentStreamCreateWithStream(stream, resources ?? dict, cs)
                let saved = f.ctm
                f.ctm = matrix.concatenating(f.ctm)
                f.depth += 1
                let sub = CGPDFScannerCreate(inner, f.table, info)
                CGPDFScannerScan(sub)
                CGPDFScannerRelease(sub)
                CGPDFContentStreamRelease(inner)
                f.depth -= 1
                f.ctm = saved
            default: break
            }
        }
    }

    static func images(on page: CGPDFPage) -> [Found] {
        let finder = RichPDFImageFinder()
        let info = Unmanaged.passUnretained(finder).toOpaque()
        let cs = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(cs, finder.table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(cs)
        CGPDFOperatorTableRelease(finder.table)
        return finder.found
    }
}
