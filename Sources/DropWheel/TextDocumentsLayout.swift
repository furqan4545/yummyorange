import AppKit

/// Lays rich text out on pages with TextKit (one NSTextContainer per page) and draws each page into a
/// CGPDFContext, with page numbers in the footer. Links stay clickable: TextKit adds a link annotation
/// for every .link run it draws into a PDF context. No window or print panel is involved, so it works
/// on the job queue and in command-line mode alike.
enum RichPDFLayout {
    /// Paper, page numbers and the PDF title.
    struct Options {
        var page = RichPageSetup.regional
        var pageNumbers = true
        var title: String?
    }

    /// `chunk`: TextKit slows down sharply as one layout manager collects thousands of pages, so long
    /// documents are laid out a few dozen pages at a time. Each piece ends at a paragraph outside any table
    /// or block, and its last (partly filled) page is carried into the next piece, so pages run on naturally.
    static func write(_ text: NSAttributedString, to url: URL, options: Options = Options(), chunk: Int = 40_000) throws {
        let page = options.page
        let textSize = CGSize(width: page.textWidth, height: page.size.height - page.margins.top - page.margins.bottom)
        guard textSize.width > 72, textSize.height > 72 else {
            throw ConversionError.unsupported("The margins leave no room for text on the page.")
        }
        let full = NSMutableAttributedString(attributedString: prepared(text, fitting: textSize))
        var mediaBox = CGRect(origin: .zero, size: page.size)
        var info: [CFString: Any] = [kCGPDFContextCreator: "YummyOrange"]
        if let title = options.title { info[kCGPDFContextTitle] = title }
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw ConversionError.toolFailed("Couldn’t create \(url.lastPathComponent).")
        }
        var pageNumber = 0
        var start = 0
        let length = full.length
        do {
            repeat {
                var end = length
                if length - start > chunk { end = boundary(full, after: start + chunk) }
                // A code block, quote or table row taller than a page can't be split by TextKit, which cuts off
                // what doesn't fit. Such a box is taken off (its text kept) and the piece laid out again.
                var rounds = 0
                var laid: (NSLayoutManager, NSTextStorage, [NSTextContainer])
                var settle = false
                while true {
                    let piece = self.piece(full, from: start, to: end)
                    let result = try paginate(piece, textSize, stopAtClip: !settle)
                    if let clipped = result.clipped, !settle {
                        rounds += 1
                        if rounds <= 60, unbox(full, at: start + clipped) { continue }
                        if unboxAll(full, NSRange(location: start, length: end - start)) { continue }
                        // No box left to take off: lay it all out once more and keep what fits.
                        settle = true
                        continue
                    }
                    // Only a page where nothing fits at all is an error.
                    if result.stuck { throw ConversionError.unsupported("Something in the document is too large to fit on a page.") }
                    laid = (result.layout, result.storage, result.containers)
                    break
                }
                // The layout manager only borrows its text storage, so the storage must outlive the drawing.
                let (layout, storage, containers) = laid
                let last = end >= length
                let count = last || containers.count == 1 ? containers.count : containers.count - 1
                let numbered = options.pageNumbers && (!last || containers.count > 1 || pageNumber > 0)
                let carry: Int? = withExtendedLifetime(storage) {
                    draw(layout, Array(containers[0..<count]), page: page, ctx: ctx, firstNumber: pageNumber + 1, numbered: numbered)
                    guard count < containers.count else { return nil }
                    return layout.characterRange(forGlyphRange: layout.glyphRange(for: containers[count]), actualGlyphRange: nil).location
                }
                pageNumber += count
                if last { break }
                if let carry { start += max(1, carry) } else { start = end }
            } while start < length
        } catch {
            ctx.closePDF()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        ctx.closePDF()
    }

    /// Characters that end a line: no line fragment holds one before its end.
    static let lineEnds = CharacterSet(charactersIn: "\n\r\u{2028}\u{2029}")

    /// The start of the first paragraph at or after `position` that isn't inside a table or other block. A
    /// paragraph longer than the window is cut inside, after a space (TextKit slows down sharply on one
    /// huge paragraph too); the piece after it then continues that paragraph.
    private static func boundary(_ text: NSAttributedString, after position: Int) -> Int {
        let ns = text.string as NSString
        let first = ns.paragraphRange(for: NSRange(location: min(position, ns.length - 1), length: 0))
        if NSMaxRange(first) - position > 30_000 {
            var k = position
            let stop = min(ns.length, position + 2_000)
            while k < stop, ns.character(at: k) != 0x20, ns.character(at: k) != 0x09 { k += 1 }
            // Never between the halves of a surrogate pair or inside a composed character.
            let cut = k < stop ? k + 1 : position
            return ns.rangeOfComposedCharacterSequence(at: min(cut, ns.length - 1)).location
        }
        var location = first.location
        let limit = min(ns.length, position + 30_000)
        while location < limit {
            let r = ns.paragraphRange(for: NSRange(location: location, length: 0))
            if NSMaxRange(r) >= ns.length { return ns.length }
            let next = NSMaxRange(r)
            let style = text.attribute(.paragraphStyle, at: next, effectiveRange: nil) as? NSParagraphStyle
            if style?.textBlocks.isEmpty ?? true { return next }
            location = next
        }
        return min(ns.length, max(position, limit))
    }

    /// The text from `start` to `end`. A piece that starts inside a paragraph (a cut long paragraph, or the
    /// carried last page) continues it: no first-line indent or space before.
    private static func piece(_ full: NSAttributedString, from start: Int, to end: Int) -> NSAttributedString {
        let piece = full.attributedSubstring(from: NSRange(location: start, length: end - start))
        let ns = full.string as NSString
        guard start > 0, piece.length > 0, ![0x0A, 0x0D, 0x2029, 0x0C].contains(ns.character(at: start - 1)),
              let style = piece.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
              style.firstLineHeadIndent != style.headIndent || style.paragraphSpacingBefore != 0,
              let fixed = style.mutableCopy() as? NSMutableParagraphStyle else { return piece }
        fixed.firstLineHeadIndent = fixed.headIndent
        fixed.paragraphSpacingBefore = 0
        let out = NSMutableAttributedString(attributedString: piece)
        let first = (piece.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        out.addAttribute(.paragraphStyle, value: fixed, range: first)
        return out
    }

    /// Lays a piece of text into as many page-sized containers as it needs. `clipped` is where text was cut
    /// off (a box taller than a page: TextKit leaves out the lines that don't fit, or places nothing at all).
    private static func paginate(_ text: NSAttributedString, _ size: CGSize, stopAtClip: Bool = true) throws
        -> (layout: NSLayoutManager, storage: NSTextStorage, containers: [NSTextContainer], clipped: Int?, stuck: Bool) {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        layout.usesFontLeading = true
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        var emptyInARow = 0
        var clipped: Int?
        while true {
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            let range = layout.glyphRange(for: container)
            if clipped == nil, range.length > 0 {
                // Every glyph of the page should be on one of its lines. What doesn't fit in a box TextKit
                // can't split ends up on no line, or on a line of no height below the page.
                // (or on one squashed line holding several paragraphs).
                var covered: [NSRange] = []
                var lost = Int.max
                let ns = text.string as NSString
                layout.enumerateLineFragments(forGlyphRange: range) { rect, _, _, glyphs, _ in
                    let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                    let inner = NSRange(location: chars.location, length: max(0, chars.length - 1))
                    let squashed = inner.length > 0 && ns.rangeOfCharacter(from: RichPDFLayout.lineEnds, options: [], range: inner).location != NSNotFound
                    if squashed || rect.height < 0.5 || rect.minY >= size.height - 0.5 { lost = min(lost, glyphs.location) } else { covered.append(glyphs) }
                }
                covered.sort { $0.location < $1.location }
                var next = range.location
                for r in covered where r.location <= next { next = max(next, NSMaxRange(r)) }
                next = min(next, lost)
                if next < NSMaxRange(range) {
                    let char = layout.characterIndexForGlyph(at: next)
                    // A lone paragraph mark or attachment slot past the last line is harmless.
                    let rest = (text.string as NSString).substring(with: layout.characterRange(forGlyphRange: NSRange(location: next, length: NSMaxRange(range) - next), actualGlyphRange: nil))
                    if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clipped = char }
                }
            }
            if NSMaxRange(range) >= layout.numberOfGlyphs { break }
            emptyInARow = range.length == 0 ? emptyInARow + 1 : 0
            if emptyInARow >= 3 {
                // Nothing fits on a page at all: whatever comes next is too tall.
                return (layout, storage, containers, clipped ?? layout.characterIndexForGlyph(at: min(NSMaxRange(range), max(0, layout.numberOfGlyphs - 1))), true)
            }
            if stopAtClip, clipped != nil, containers.count >= 2 { break }   // it will be laid out again anyway
            if containers.count >= 5_000 { throw ConversionError.unsupported("The document is too long to make into a PDF.") }
        }
        // A trailing page holding nothing but the final paragraph mark isn't worth printing.
        while containers.count > 1, layout.glyphRange(for: containers.last!).length == 0 { containers.removeLast() }
        return (layout, storage, containers, clipped, false)
    }

    /// Takes the outermost box (code block, quote, or the table rows) around `location` off its paragraphs,
    /// keeping their text and a hint of the look. false when there is no box there.
    private static func unbox(_ text: NSMutableAttributedString, at location: Int) -> Bool {
        guard text.length > 0 else { return false }
        let at = min(max(0, location), text.length - 1)
        guard let style = text.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle,
              let outer = style.textBlocks.first else { return false }
        let carries: (NSParagraphStyle?) -> Bool
        if let cell = outer as? NSTextTableBlock {
            // The rows that cell spans, in every column.
            let rows = cell.startingRow..<(cell.startingRow + max(1, cell.rowSpan))
            carries = { ps in
                ps?.textBlocks.contains { b in
                    guard let c = b as? NSTextTableBlock, c.table === cell.table else { return false }
                    return rows.overlaps(c.startingRow..<(c.startingRow + max(1, c.rowSpan)))
                } ?? false
            }
        } else {
            carries = { ps in ps?.textBlocks.contains { $0 === outer } ?? false }
        }
        let ns = text.string as NSString
        var lo = ns.paragraphRange(for: NSRange(location: at, length: 0)).location
        while lo > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: lo - 1, length: 0))
            guard carries(text.attribute(.paragraphStyle, at: prev.location, effectiveRange: nil) as? NSParagraphStyle) else { break }
            lo = prev.location
        }
        var hi = NSMaxRange(ns.paragraphRange(for: NSRange(location: at, length: 0)))
        while hi < ns.length {
            let next = ns.paragraphRange(for: NSRange(location: hi, length: 0))
            guard carries(text.attribute(.paragraphStyle, at: next.location, effectiveRange: nil) as? NSParagraphStyle) else { break }
            hi = NSMaxRange(next)
        }
        strip(text, NSRange(location: lo, length: hi - lo)) { block in
            if let c = block as? NSTextTableBlock, let o = outer as? NSTextTableBlock { return c.table === o.table }
            return block === outer
        }
        return true
    }

    /// Takes every box off a range (the last resort when one piece keeps clipping).
    private static func unboxAll(_ text: NSMutableAttributedString, _ range: NSRange) -> Bool {
        var any = false
        text.enumerateAttribute(.paragraphStyle, in: range) { v, _, stop in
            if let ps = v as? NSParagraphStyle, !ps.textBlocks.isEmpty { any = true; stop.pointee = true }
        }
        if any { strip(text, range) { _ in true } }
        return any
    }

    /// Removes the blocks `matches` picks from the paragraph styles in `range`. A quote's indent and a
    /// code block's shading stay on the text.
    private static func strip(_ text: NSMutableAttributedString, _ range: NSRange, _ matches: (NSTextBlock) -> Bool) {
        var styles: [(NSRange, NSParagraphStyle)] = []
        var shading: [(NSRange, NSColor)] = []
        text.enumerateAttribute(.paragraphStyle, in: range) { v, r, _ in
            guard let ps = v as? NSParagraphStyle, ps.textBlocks.contains(where: matches),
                  let fixed = ps.mutableCopy() as? NSMutableParagraphStyle else { return }
            for b in ps.textBlocks where matches(b) && !(b is NSTextTableBlock) {
                if b.width(for: .border, edge: .minX) > 0 || b.width(for: .padding, edge: .minX) > 8 {
                    fixed.headIndent += 18; fixed.firstLineHeadIndent += 18
                }
                if let bg = b.backgroundColor { shading.append((r, bg)) }
            }
            if ps.textBlocks.contains(where: { matches($0) && $0 is NSTextTableBlock }) { fixed.paragraphSpacing = max(fixed.paragraphSpacing, 2) }
            fixed.textBlocks = ps.textBlocks.filter { !matches($0) }
            styles.append((r, fixed))
        }
        for (r, ps) in styles { text.addAttribute(.paragraphStyle, value: ps, range: r) }
        for (r, color) in shading {
            text.enumerateAttribute(.backgroundColor, in: r) { v, sub, _ in if v == nil { text.addAttribute(.backgroundColor, value: color, range: sub) } }
        }
    }

    private static func draw(_ layout: NSLayoutManager, _ containers: [NSTextContainer], page: RichPageSetup,
                             ctx: CGContext, firstNumber: Int, numbered: Bool) {
        let origin = CGPoint(x: page.margins.left, y: page.margins.top)
        let work = {
            for (index, container) in containers.enumerated() {
                ctx.beginPDFPage(nil)
                let glyphs = layout.glyphRange(for: container)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                ctx.saveGState()
                ctx.translateBy(x: 0, y: page.size.height)
                ctx.scaleBy(x: 1, y: -1)
                layout.drawBackground(forGlyphRange: glyphs, at: origin)
                layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
                ctx.restoreGState()
                NSGraphicsContext.restoreGraphicsState()

                if numbered {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                    let label = "\(firstNumber + index)" as NSString
                    let attrs: [NSAttributedString.Key: Any] = [.font: RichStyle.font(size: 9), .foregroundColor: RichStyle.caption]
                    let w = label.size(withAttributes: attrs).width
                    label.draw(at: CGPoint(x: (page.size.width - w) / 2, y: max(14, page.margins.bottom / 2 - 6)), withAttributes: attrs)
                    NSGraphicsContext.restoreGraphicsState()
                }
                ctx.endPDFPage()
            }
        }
        // Dynamic colors (labelColor and friends) must resolve as on paper, not as in Dark Mode.
        if #available(macOS 11.0, *), let aqua = NSAppearance(named: .aqua) { aqua.performAsCurrentDrawingAppearance(work) } else { work() }
    }

    /// A copy ready for paging: pictures scaled to fit the page (TextKit can't split them), attachments that
    /// aren't pictures named instead of drawn as icons, right-to-left paragraphs set that way, links colored.
    static func prepared(_ text: NSAttributedString, fitting box: CGSize) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: out.length)
        var replacements: [(NSRange, NSTextAttachment)] = []
        var labels: [(NSRange, String)] = []
        out.enumerateAttribute(.attachment, in: full) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            guard let image = RichDocument.image(from: attachment, alt: ""),
                  let picture = NSImage(data: image.data) else {
                let alt = out.attribute(.dwImageAlt, at: range.location, effectiveRange: nil) as? String ?? ""
                labels.append((range, RichDocument.attachmentLabel(attachment, alt: alt).map { "[\($0)]" } ?? ""))
                return
            }
            // Inside tables and indented blocks there is less room; leave some margin for that.
            let style = out.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let inBlock = !(style?.textBlocks.isEmpty ?? true)
            let maxW = box.width - (style?.headIndent ?? 0) - (inBlock ? 24 : 0)
            let maxH = box.height - 24
            var size = image.displaySize
            let scale = min(1, maxW / max(size.width, 1), maxH / max(size.height, 1))
            size = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
            picture.size = size
            let fresh = NSTextAttachment()
            fresh.attachmentCell = NSTextAttachmentCell(imageCell: picture)
            fresh.bounds = CGRect(origin: .zero, size: size)
            replacements.append((range, fresh))
        }
        for (range, attachment) in replacements { out.addAttribute(.attachment, value: attachment, range: range) }
        for (range, label) in labels.reversed() {
            var attrs = out.attributes(at: range.location, effectiveRange: nil)
            attrs[.attachment] = nil
            out.replaceCharacters(in: range, with: NSAttributedString(string: label, attributes: attrs))
        }
        // Paragraphs with no stated direction whose first strong letter is Arabic, Hebrew… run right to left
        // (TextKit's "natural" means the app's language, not the text's).
        let ns = out.string as NSString
        var location = 0
        var directions: [(NSRange, NSParagraphStyle)] = []
        while location < ns.length {
            let r = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(r)
            let style = out.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle
            guard style?.baseWritingDirection ?? .natural == .natural,
                  RichDocument.startsRightToLeft(ns.substring(with: NSRange(location: r.location, length: min(r.length, 400)))),
                  let fixed = (style ?? NSParagraphStyle.default).mutableCopy() as? NSMutableParagraphStyle else { continue }
            fixed.baseWritingDirection = .rightToLeft
            directions.append((r, fixed))
        }
        for (r, ps) in directions { out.addAttribute(.paragraphStyle, value: ps, range: r) }
        out.enumerateAttribute(.link, in: full) { value, range, _ in
            guard value != nil else { return }
            if out.attribute(.foregroundColor, at: range.location, effectiveRange: nil) == nil {
                out.addAttribute(.foregroundColor, value: RichStyle.linkColor, range: range)
            }
        }
        return out
    }
}
