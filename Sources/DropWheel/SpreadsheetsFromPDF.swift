import AppKit
import PDFKit
import Vision

/// Rebuilds tables from a PDF's text positions, one sheet per page. Characters (with their boxes from
/// PDFKit) become words; words whose baselines line up become rows; within a row, wide gaps split
/// phrases; and columns come from the x-ranges that phrases of the page's multi-phrase rows leave
/// empty. Numbers ("1,234.50", "(12)", "45%", "$9.99") become numbers. Pages without a text layer are
/// read with Vision OCR, whose line boxes are split the same way.
enum SpreadsheetsFromPDF {
    /// A run of text on the page, in top-left-origin page coordinates.
    struct Piece { var text: String; var box: CGRect }

    static func workbook(from url: URL, options: ToolOptions, progress: (Double) -> Void) throws -> Workbook {
        guard let doc = PDFDocument(url: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
        if doc.isLocked {
            throw ConversionError.unsupported("\(url.lastPathComponent) is password-protected. Use Remove Password first.")
        }
        guard doc.pageCount > 0 else { throw ConversionError.unsupported("\(url.lastPathComponent) has no pages.") }
        let useOCR = options.bool("ocr", true)
        var book = Workbook()
        var anyText = false
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var pieces = words(on: page)
            var fromOCR = false
            if pieces.isEmpty, useOCR {
                pieces = try ocrPieces(page)
                fromOCR = true
            }
            var sheet = Worksheet(name: "Page \(i + 1)")
            if !pieces.isEmpty {
                anyText = true
                let grid = table(from: pieces, splitWords: !fromOCR)
                for (r, row) in grid.enumerated() {
                    for (c, text) in row.enumerated() where !text.isEmpty {
                        sheet.set(r, c, cell(text, book: &book))
                    }
                }
                sheet.trim()
            }
            book.sheets.append(sheet)
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        guard anyText else {
            throw ConversionError.unsupported("No text found in \(url.lastPathComponent)\(useOCR ? "" : " (OCR was off)").")
        }
        // Pages with nothing on them don't need a sheet, as long as one sheet remains.
        let filled = book.sheets.filter { !$0.isEmpty }
        if !filled.isEmpty { book.sheets = filled }
        return book
    }

    // MARK: Text positions

    /// Words with their boxes from the page's text layer, in top-left-origin coordinates of the page as shown.
    ///
    /// Glyph boxes come from `characterBounds(at:)`, which is tight, but on recent macOS its index skips the
    /// line breaks PDFKit inserts into `page.string`, so it drifts one more character per line. One-character
    /// `PDFSelection`s stay aligned but are line-tall, and a whole page tall in PDFs PDFKit sees as one line.
    /// So each page checks which indexing agrees with the selections' x positions and uses that, falling
    /// back to the selections themselves.
    static func words(on page: PDFPage) -> [Piece] {
        guard let string = page.string, !string.isEmpty else { return [] }
        let bounds = page.bounds(for: .cropBox)
        let units = Array(string.utf16)
        let glyphIndex = glyphIndexer(page, units)
        var glyphs: [(units: [UInt16], box: CGRect)] = []
        var i = 0
        while i < units.count {
            let u = units[i]
            // Keep surrogate pairs together.
            let isHigh = (0xD800...0xDBFF).contains(u) && i + 1 < units.count
            let charUnits = isHigh ? [u, units[i + 1]] : [u]
            let index = i
            i += charUnits.count
            let scalar = String(decoding: charUnits, as: UTF16.self)
            if scalar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                glyphs.append((charUnits, .null))       // a word break
                continue
            }
            let raw = glyphIndex(index)
            guard raw.width > 0 || raw.height > 0 else { glyphs.append((charUnits, .null)); continue }
            glyphs.append((charUnits, raw))
        }
        // Turn the page so its text reads left to right, top to bottom.
        let rotation = readingRotation(glyphs.map(\.box), fallback: ((page.rotation % 360) + 360) % 360)
        for k in glyphs.indices where !glyphs[k].box.isNull {
            var box = display(glyphs[k].box, in: bounds, rotation: rotation)
            if box.height < 0.5 { box = box.insetBy(dx: 0, dy: -0.5) }   // rules and dashes
            glyphs[k].box = box
        }

        // The typical glyph size sets how close two glyphs must be to belong to one word.
        let sized = glyphs.filter { !$0.box.isNull && $0.box.height > 2 }
        let charWidth = median(sized.map(\.box.width))
        let charHeight = median(sized.map(\.box.height))
        let repaired = repairWideGlyphs(&glyphs, charWidth: charWidth)

        var words: [Piece] = []
        var current: Piece?
        var currentUnits: [UInt16] = []
        func flush() {
            if var w = current, !currentUnits.isEmpty {
                w.text = String(decoding: currentUnits, as: UTF16.self)
                words.append(w)
            }
            current = nil
            currentUnits = []
        }
        var previousRepaired = false
        for (k, g) in glyphs.enumerated() {
            guard !g.box.isNull else { flush(); previousRepaired = false; continue }
            // A repaired box is a character wide, so the glyph after it can start up to a glyph further on:
            // that gap is still inside the word.
            let slack = previousRepaired || repaired[k] ? max(charHeight, g.box.height) : 0
            previousRepaired = repaired[k]
            if var w = current {
                let sameLine = verticalOverlap(w.box, g.box) > 0.3 * min(w.box.height, g.box.height, charHeight)
                let gap = g.box.minX - w.box.maxX
                if sameLine && gap < 0.3 * charWidth + 0.15 * charHeight + slack && gap > -charWidth - slack {
                    w.box = w.box.union(g.box)
                    current = w
                    currentUnits += g.units
                    continue
                }
                flush()
            }
            current = Piece(text: "", box: g.box)
            currentUnits = g.units
        }
        flush()
        return words
    }

    /// Some generators' text (cupsfilter's, for one) makes PDFKit report absurd boxes for the last glyph of a
    /// line and the first word of the next: many characters wide, starting off the page. Their vertical
    /// position is still right, and so is the right edge of a word's last letter, so each such glyph is
    /// placed next to its sound neighbour in the same word instead: after it going forward, before it going back.
    /// A glyph is absurd when it's far wider than its own height (or the page's typical glyph): large type, a
    /// heading's "M" or "W", is wide for the page but not for its size. Returns which glyphs were moved.
    @discardableResult
    private static func repairWideGlyphs(_ glyphs: inout [(units: [UInt16], box: CGRect)], charWidth: CGFloat) -> [Bool] {
        let none = [Bool](repeating: false, count: glyphs.count)
        guard charWidth > 0 else { return none }
        func bad(_ r: CGRect) -> Bool { !r.isNull && (r.width > 2.5 * max(charWidth, r.height) || r.minX < -1) }
        guard glyphs.contains(where: { bad($0.box) }) else { return none }
        func sameLine(_ a: CGRect, _ b: CGRect) -> Bool { verticalOverlap(a, b) > 0.3 * min(a.height, b.height) }
        var fixed = glyphs.map { !bad($0.box) }
        let wasBad = fixed.map { !$0 }
        /// The sound glyph `step` away (±1), or one further across a single space, with the gap to leave.
        func anchor(_ i: Int, _ step: Int) -> (box: CGRect, gap: CGFloat)? {
            let j = i + step
            guard j >= 0, j < glyphs.count else { return nil }
            if !glyphs[j].box.isNull { return fixed[j] ? (glyphs[j].box, 0.05 * charWidth) : nil }
            let k = j + step
            guard k >= 0, k < glyphs.count, fixed[k], !glyphs[k].box.isNull else { return nil }
            return (glyphs[k].box, charWidth)     // across a space, about a character wide
        }
        for i in glyphs.indices where !fixed[i] && !glyphs[i].box.isNull {
            guard let (prev, gap) = anchor(i, -1), sameLine(prev, glyphs[i].box) else { continue }
            let g = glyphs[i].box
            glyphs[i].box = CGRect(x: prev.maxX + gap, y: g.minY, width: charWidth, height: g.height)
            fixed[i] = true
        }
        for i in glyphs.indices.reversed() where !fixed[i] && !glyphs[i].box.isNull {
            guard let (next, gap) = anchor(i, 1), sameLine(next, glyphs[i].box) else { continue }
            let g = glyphs[i].box
            glyphs[i].box = CGRect(x: next.minX - gap - charWidth, y: g.minY, width: charWidth, height: g.height)
            fixed[i] = true
        }
        // Whatever is left (one-letter words) shrinks to a character's width around its centre.
        for i in glyphs.indices where !fixed[i] && !glyphs[i].box.isNull {
            let g = glyphs[i].box
            glyphs[i].box = CGRect(x: max(0, g.midX - charWidth / 2), y: g.minY, width: charWidth, height: g.height)
        }
        return glyphs.indices.map { i in !glyphs[i].box.isNull && wasBad[i] }
    }

    /// The best way to get a glyph box for a `page.string` UTF-16 index (see `words(on:)`).
    static func glyphIndexer(_ page: PDFPage, _ units: [UInt16]) -> (Int) -> CGRect {
        var skipped = [Int](repeating: 0, count: units.count)
        var breaks = 0
        for (i, u) in units.enumerated() {
            skipped[i] = i - breaks
            if u == 10 || u == 13 { breaks += 1 }
        }
        // Compare both indexings with one-character selections on a sample of visible characters.
        let visible = units.indices.filter { units[$0] > 32 && !(0xDC00...0xDFFF).contains(units[$0]) }
        let step = max(1, visible.count / 300)
        var direct = 0, shifted = 0, checked = 0
        for k in stride(from: 0, to: visible.count, by: step) {
            let i = visible[k]
            guard let sel = page.selection(for: NSRange(location: i, length: 1)) else { continue }
            let ref = sel.bounds(for: page)
            guard ref.width > 0 else { continue }
            checked += 1
            if abs(page.characterBounds(at: i).midX - ref.midX) < 1.5 { direct += 1 }
            if abs(page.characterBounds(at: skipped[i]).midX - ref.midX) < 1.5 { shifted += 1 }
        }
        if checked == 0 || direct * 10 >= checked * 9 && direct >= shifted { return { page.characterBounds(at: $0) } }
        if shifted * 10 >= checked * 9 { return { page.characterBounds(at: skipped[$0]) } }
        return { i in page.selection(for: NSRange(location: i, length: 1))?.bounds(for: page) ?? .null }
    }

    /// Which way the text runs in page space, as the quarter turn `display` needs: 0 when letters advance
    /// rightwards, 90 upwards, 180 leftwards, 270 downwards. Decided by a vote over neighbouring letters,
    /// because a page's /Rotate says how it's shown, not how its text was drawn (a portrait page turned with
    /// /Rotate holds sideways text, while a landscape page is often upright text drawn turned, then /Rotate'd).
    private static func readingRotation(_ boxes: [CGRect], fallback: Int) -> Int {
        let sizes = boxes.filter { !$0.isNull }.map { max($0.width, $0.height) }
        let typical = median(sizes)
        var votes = [0: 0, 90: 0, 180: 0, 270: 0]
        for k in boxes.indices.dropFirst() {
            let a = boxes[k - 1], b = boxes[k]
            guard !a.isNull, !b.isNull, max(a.width, a.height) < 3 * typical, max(b.width, b.height) < 3 * typical else { continue }
            let dx = b.midX - a.midX, dy = b.midY - a.midY
            guard max(abs(dx), abs(dy)) < 3 * typical else { continue }
            if abs(dx) > 2 * abs(dy) { votes[dx > 0 ? 0 : 180, default: 0] += 1 }
            else if abs(dy) > 2 * abs(dx) { votes[dy > 0 ? 90 : 270, default: 0] += 1 }
        }
        guard let best = votes.max(by: { $0.value < $1.value }), best.value > 0 else { return fallback }
        return best.key
    }

    /// A box in PDF page space (bottom-left origin, unrotated) → the page as displayed, top-left origin.
    private static func display(_ r: CGRect, in page: CGRect, rotation: Int) -> CGRect {
        let x = r.minX - page.minX, y = r.minY - page.minY
        let w = page.width, h = page.height
        switch rotation {
        case 90:  return CGRect(x: y, y: x, width: r.height, height: r.width)
        case 180: return CGRect(x: w - x - r.width, y: y, width: r.width, height: r.height)
        case 270: return CGRect(x: h - y - r.height, y: w - x - r.width, width: r.height, height: r.width)
        default:  return CGRect(x: x, y: h - y - r.height, width: r.width, height: r.height)
        }
    }

    private static func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        min(a.maxY, b.maxY) - max(a.minY, b.minY)
    }

    /// Vision OCR of a scanned page: each recognised run becomes a piece (Vision splits lines at wide gaps).
    /// macOS 15 and later use the newer RecognizeTextRequest, which reads dense pages much better.
    private static func ocrPieces(_ page: PDFPage) throws -> [Piece] {
        guard let ref = page.pageRef, let image = PDFTools.scanImage(ref) else { return [] }
        var found: [(String, CGRect)] = []     // normalized boxes, bottom-left origin
        if #available(macOS 15.0, *) {
            var failure: Error?
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    var request = RecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.automaticallyDetectsLanguage = true
                    found = try await request.perform(on: image).compactMap { obs in
                        obs.topCandidates(1).first.map { ($0.string, obs.boundingBox.cgRect) }
                    }
                } catch { failure = error }
                done.signal()
            }
            done.wait()   // Vision runs on its own threads, so this is safe on the main thread too
            if let failure { throw failure }
        } else {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            found = (request.results ?? []).compactMap { obs in obs.topCandidates(1).first.map { ($0.string, obs.boundingBox) } }
        }
        let size = page.bounds(for: .cropBox).size
        let rotated = ((page.rotation % 360) + 360) % 360 % 180 == 90
        let shown = rotated ? CGSize(width: size.height, height: size.width) : size
        return found.map { text, b in
            Piece(text: text, box: CGRect(x: b.minX * shown.width, y: (1 - b.maxY) * shown.height,
                                          width: b.width * shown.width, height: b.height * shown.height))
        }
    }

    // MARK: Rows and columns

    /// Arranges pieces into a grid of strings.
    static func table(from pieces: [Piece], splitWords: Bool) -> [[String]] {
        guard !pieces.isEmpty else { return [] }
        // Rows: sort by vertical centre and cluster pieces that overlap the row's band.
        let sorted = pieces.sorted { $0.box.midY < $1.box.midY }
        var rows: [[Piece]] = []
        var band = CGRect.null
        for p in sorted {
            if let _ = rows.last, verticalOverlap(band, p.box) > 0.5 * min(band.height, p.box.height),
               abs(band.midY - p.box.midY) < 0.6 * max(band.height, p.box.height) {
                rows[rows.count - 1].append(p)
                band = band.union(p.box)
            } else {
                rows.append([p])
                band = p.box
            }
        }

        // Phrases: words in a row joined across normal word spaces. A space is about one character wide in
        // monospaced text and narrower in proportional fonts; column gaps are wider than one and a half.
        let charWidth = median(pieces.filter { $0.text.count >= 2 }.map { $0.box.width / CGFloat($0.text.count) })
        let lineHeight = median(pieces.map(\.box.height))
        var phraseRows: [[Piece]] = []
        for row in rows {
            let words = row.sorted { $0.box.minX < $1.box.minX }
            let height = median(words.map(\.box.height))
            var phrases: [Piece] = []
            for w in words {
                // Spaces grow with the type: between words of clearly larger type than the page's (a heading),
                // the gap that still joins them grows in proportion.
                var scale: CGFloat = 1
                if let last = phrases.last, lineHeight > 0 {
                    let ratio = min(last.box.height, w.box.height) / lineHeight
                    if ratio > 1.4 { scale = ratio }
                }
                let joinGap = splitWords ? max(1.5, 1.5 * charWidth * scale) : 0.0
                if var last = phrases.last, w.box.minX - last.box.maxX < joinGap {
                    last.text += (w.box.minX - last.box.maxX > 0.08 * height ? " " : "") + w.text
                    last.box = last.box.union(w.box)
                    phrases[phrases.count - 1] = last
                } else {
                    phrases.append(w)
                }
            }
            phraseRows.append(phrases)
        }

        // Columns: x-ranges covered by phrases of rows that have at least two of them.
        let tableRows = phraseRows.filter { $0.count >= 2 }
        var spans: [(CGFloat, CGFloat)] = tableRows.flatMap { $0.map { ($0.box.minX, $0.box.maxX) } }
        spans.sort { $0.0 < $1.0 }
        var columns: [(CGFloat, CGFloat)] = []
        for s in spans {
            if let last = columns.last, s.0 <= last.1 + 1 {
                columns[columns.count - 1].1 = max(last.1, s.1)
            } else {
                columns.append(s)
            }
        }
        // Too few table rows to trust: one column per phrase position instead.
        if columns.isEmpty { return phraseRows.map { $0.map(\.text) } }

        func columnIndex(_ p: Piece) -> Int {
            var best = 0, bestOverlap: CGFloat = -.infinity
            for (i, c) in columns.enumerated() {
                let overlap = min(c.1, p.box.maxX) - max(c.0, p.box.minX)
                let score = overlap > 0 ? overlap : -abs((c.0 + c.1) / 2 - p.box.midX)
                if score > bestOverlap { bestOverlap = score; best = i }
            }
            // A phrase starting left of every column (a title) goes in the first one.
            if p.box.minX < columns[0].0 { return 0 }
            return best
        }

        return phraseRows.map { row in
            var cells = [String](repeating: "", count: columns.count)
            for p in row {
                let c = columnIndex(p)
                cells[c] = cells[c].isEmpty ? p.text : cells[c] + " " + p.text
            }
            while let last = cells.last, last.isEmpty { cells.removeLast() }
            return cells
        }
    }

    private static func median(_ v: [CGFloat]) -> CGFloat {
        guard !v.isEmpty else { return 10 }
        let s = v.sorted()
        return s[s.count / 2]
    }

    // MARK: Values

    /// A table cell's value: plain and grouped numbers, accounting negatives, percentages, currency, ISO dates.
    static func cell(_ raw: String, book: inout Workbook) -> SheetCell {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if let (v, code) = parseNumber(t) {
            return SheetCell(value: .number(v), format: code.map { book.format($0) } ?? 0)
        }
        if let first = t.first, first.isNumber, let (d, kind) = SheetDate.parseISO(t) {
            return SheetCell(value: .date(d, kind))
        }
        return SheetCell(value: .text(t))
    }

    /// Parses "1,234.56", "-12", "(1,234)", "12.5%", "$1,234.50", "€ 12", "1 234" and returns the value with
    /// a format code that shows it the same way (nil for General).
    static func parseNumber(_ s: String) -> (Double, String?)? {
        var t = s.replacingOccurrences(of: "\u{2212}", with: "-")   // minus sign
        guard !t.isEmpty, t.count <= 32 else { return nil }
        var negative = false, percent = false
        var currency = ""
        if t.hasPrefix("(") && t.hasSuffix(")") { negative = true; t = String(t.dropFirst().dropLast()) }
        if t.hasPrefix("-") { negative.toggle(); t = String(t.dropFirst()) } else if t.hasPrefix("+") { t = String(t.dropFirst()) }
        if t.hasSuffix("%") { percent = true; t = String(t.dropLast()) }
        for sym in ["$", "€", "£", "¥"] {
            if t.hasPrefix(sym) { currency = sym; t = String(t.dropFirst()); break }
            if t.hasSuffix(sym) { currency = sym; t = String(t.dropLast()); break }
        }
        if t.hasPrefix("-") && !negative { negative = true; t = String(t.dropFirst()) }
        t = t.trimmingCharacters(in: .whitespaces)
        guard let first = t.first, first.isNumber || first == "." else { return nil }

        // Grouping: commas (or thin spaces) between groups of three digits.
        var grouped = false
        var digitsOnly = t
        if t.contains(",") || t.contains("\u{202F}") || t.contains("\u{00A0}") {
            let parts = t.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let intPart = String(parts[0])
            let groups = intPart.split(whereSeparator: { $0 == "," || $0 == "\u{202F}" || $0 == "\u{00A0}" }).map(String.init)
            guard groups.count >= 2, (1...3).contains(groups[0].count), groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
            grouped = true
            digitsOnly = groups.joined() + (parts.count > 1 ? "." + parts[1] : "")
        }
        guard digitsOnly.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              digitsOnly.filter({ $0 == "." }).count <= 1, var v = Double(digitsOnly) else { return nil }
        // Leading zeros mean an identifier, not a number.
        if digitsOnly.count > 1, digitsOnly.hasPrefix("0"), !digitsOnly.hasPrefix("0.") { return nil }
        if digitsOnly.filter(\.isNumber).count > 15 { return nil }
        let decimals = digitsOnly.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
        if percent { v /= 100 }
        if negative { v = -v }

        var code: String?
        if grouped || percent || !currency.isEmpty || s.hasPrefix("(") || decimals > 0 {
            var body = grouped ? "#,##0" : "0"
            if decimals > 0 { body += "." + String(repeating: "0", count: decimals) }
            if percent { body += "%" }
            if !currency.isEmpty { body = "\"\(currency)\"" + body }
            code = s.hasPrefix("(") ? "\(body);(\(body))" : body
            if code == "0" { code = nil }
        }
        if decimals > 0 && !grouped && !percent && currency.isEmpty && !s.hasPrefix("(") {
            // Plain decimals read fine as General unless trailing zeros matter ("1.50").
            if !digitsOnly.hasSuffix("0") { code = nil }
        }
        return (v, code)
    }
}
