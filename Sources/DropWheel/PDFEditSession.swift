import AppKit
import PDFKit

// The Edit PDF document session: the edit list (which is also the undo model), the candidate file (the
// original plus one pending incremental update, rebuilt from the original on every change, so the preview is
// the same bytes Save writes), line states for the UI, banners, and Save through the verification gate.

/// A line of the original document.
struct PDFLineID: Hashable, Codable, CustomStringConvertible {
    let page: Int
    let line: Int
    var description: String { "page \(page + 1) line \(line + 1)" }
}

/// How the rest of a line behaves when an edit changes its length.
enum PDFSpacing: String, CaseIterable, Codable {
    /// Later glyphs of the same show operator move, as when typing. Text placed on its own never moves.
    case flow
    /// A kerning number after the new text keeps everything after it where it was.
    case keep
    /// Horizontal scaling (70–130 %) makes the edited string as wide as it was.
    case fit

    var title: String {
        switch self {
        case .flow: return "Flow"
        case .keep: return "Keep Position"
        case .fit: return "Fit Width"
        }
    }
}

/// For text inside a form drawn on several pages.
enum PDFEditScope: String, Codable { case allPages, thisPage }

/// Style of added text.
struct PDFTextStyle: Equatable, Codable {
    /// A PostScript font name installed on this Mac.
    var fontName: String = "Helvetica"
    var size: Double = 12
    /// sRGB, 0…1.
    var red: Double = 0, green: Double = 0, blue: Double = 0
    /// Bold or italic drawn by the PDF (a thickened outline, a slant) for a family without that face.
    var syntheticBold = false
    var syntheticItalic = false

    var color: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    init(fontName: String = "Helvetica", size: Double = 12, red: Double = 0, green: Double = 0, blue: Double = 0) {
        self.fontName = fontName; self.size = size; self.red = red; self.green = green; self.blue = blue
    }

    init(fontName: String, size: Double, color: CGColor) {
        self.fontName = fontName
        self.size = size
        let c = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        red = Double(c.count >= 3 ? c[0] : c[0]); green = Double(c.count >= 3 ? c[1] : c[0]); blue = Double(c.count >= 3 ? c[2] : c[0])
    }
}

/// A highlight or a picture (an image, a stamp, a signature) placed on a page, drawn over its content.
enum PDFMarkKind: Equatable {
    /// Page-space rectangles, painted with Multiply so the text under them stays readable. sRGB 0…1.
    case highlight(rects: [CGRect], red: Double, green: Double, blue: Double)
    /// PNG data shown upright (for the page's rotation) in `rect`, page space.
    case image(png: Data, rect: CGRect)

    var bounds: CGRect {
        switch self {
        case .highlight(let rects, _, _, _): return rects.reduce(CGRect.null) { $0.union($1) }
        case .image(_, let r): return r
        }
    }
}

struct PDFMark: Equatable {
    let id: UUID
    let page: Int
    let kind: PDFMarkKind
}

/// One entry of the edit list.
enum PDFEdit: Equatable {
    case text(line: PDFLineID, text: String, spacing: PDFSpacing, scope: PDFEditScope)
    case delete(line: PDFLineID, scope: PDFEditScope)
    case add(id: UUID, page: Int, origin: CGPoint, text: String, style: PDFTextStyle)
    /// A line redrawn in another font, size or colour (bold, italic): its text is removed and `text` drawn in `style`.
    case styled(line: PDFLineID, text: String, style: PDFTextStyle, scope: PDFEditScope)
    case mark(id: UUID, page: Int, kind: PDFMarkKind)

    var line: PDFLineID? {
        switch self {
        case .text(let l, _, _, _), .delete(let l, _), .styled(let l, _, _, _): return l
        case .add, .mark: return nil
        }
    }
    var addID: UUID? { if case .add(let id, _, _, _, _) = self { return id }; return nil }
    var markID: UUID? { if case .mark(let id, _, _) = self { return id }; return nil }
    var page: Int {
        switch self {
        case .text(let l, _, _, _), .delete(let l, _), .styled(let l, _, _, _): return l.page
        case .add(_, let p, _, _, _), .mark(_, let p, _): return p
        }
    }
}

enum PDFLineAvailability: Equatable {
    case editable
    case readOnly(String)

    var isEditable: Bool { self == .editable }
    var reason: String? { if case .readOnly(let r) = self { return r }; return nil }
}

/// Something about an editable line the inspector should say.
enum PDFLineNote: Equatable {
    /// Invisible text (render mode 3), usually OCR over a scan.
    case hiddenText
    /// OCR text over a scan whose picture can be read: edits are painted over the picture.
    case scannedText(font: String)
    /// Text used as a clipping path: only characters its font already has can be typed.
    case clippingText
    /// A Type 3 font: new characters come from a font on this Mac at an approximate size.
    case drawnGlyphs
    /// Not a multiple of 90°: edit it in a popover.
    case rotated(Double)

    var message: String {
        switch self {
        case .hiddenText: return "Hidden OCR text. Edits change only the searchable text."
        case .scannedText(let font): return "Scanned text. Changes cover the old words in the picture and use \(font), the closest font on this Mac."
        case .clippingText: return "This text shapes a clipping path, so only characters its font already has can be typed."
        case .drawnGlyphs: return "This font is drawn by the PDF itself. New characters come from a font on this Mac and are approximate."
        case .rotated(let a): return "This text is rotated \(Int(a.rounded()))°."
        }
    }
}

/// Characters an edit takes from a font on this Mac.
struct PDFFontSubstitution: Equatable {
    var characters: Int
    var fontName: String
    /// The PDF's own font is installed; otherwise it's the closest match.
    var exact: Bool
    var approximate: Bool

    var description: String {
        let count = characters == 1 ? "1 character" : "\(characters) characters"
        if approximate { return "\(count) from \(fontName) (this Mac), approximate size" }
        return exact ? "\(count) from \(fontName) (this Mac)" : "\(count) from \(fontName) (closest match on this Mac)"
    }
}

/// A line as the UI draws it now.
struct PDFLineInfo {
    let id: PDFLineID
    let originalText: String
    let text: String
    let isEdited: Bool
    let isDeleted: Bool
    /// The current outline in page space (bottom-left, bottom-right, top-right, top-left).
    let quad: [CGPoint]
    let originalQuad: [CGPoint]
    /// Baseline start in page space, the baseline direction, and its angle in degrees (counter-clockwise).
    let origin: CGPoint
    let direction: CGVector
    let angle: Double
    /// Font size in page points.
    let pointSize: Double
    let color: CGColor
    let availability: PDFLineAvailability
    let notes: [PDFLineNote]
    /// "Embedded subset of Monaco".
    let fontDescription: String
    /// "2 characters from Helvetica (this Mac)".
    let substitutions: [PDFFontSubstitution]
    let spacing: PDFSpacing
    let scope: PDFEditScope
    /// Pages that show this text (more than 1 for text inside a shared form).
    let sharedPages: Int
    /// Points the new text runs past the room it has (0 when it fits).
    let overflow: Double
    /// Horizontal scale Fit Width used (1 = none).
    let fitScale: Double

    var overflowMessage: String? {
        guard overflow >= 0.05 else { return nil }
        return "\(PDFNumber.format((overflow * 10).rounded() / 10)) pt too wide"
    }
}

/// Text added with Add Text, as it is now.
struct PDFAddedText {
    let id: UUID
    let page: Int
    let origin: CGPoint
    let text: String
    let style: PDFTextStyle
    let quad: [CGPoint]
    let substitutions: [PDFFontSubstitution]
}

/// Messages shown at the top of the canvas.
enum PDFEditBanner: Equatable {
    case signed
    case certified
    case scanned
    case ocrOnly
    /// Text inside a form drawn on several pages.
    case sharedText(pages: Int)
    case unreadable(String)

    var message: String {
        switch self {
        case .signed: return "This PDF is signed. Saving keeps the signed version, but viewers will show it was changed after signing."
        case .certified: return "This PDF is certified against changes, so its text can’t be edited."
        case .scanned: return "This page is a scanned image. Its text can’t be edited, but you can add text."
        case .ocrOnly: return "This page is a scanned image with recognized text. Edited text covers the old words in the picture."
        case .sharedText(let n): return "This text appears on \(n) pages."
        case .unreadable(let why): return why
        }
    }
}

/// What changed, so the window can scroll to it and outline it after undo and redo.
struct PDFEditChange {
    let lines: [PDFLineID]
    let added: [UUID]
    let actionName: String
}

// MARK: - Session

final class PDFEditSession {
    let url: URL
    let originalData: Data
    let file: PDFObjectFile
    let originalDocument: PDFDocument
    let fonts: PDFEditFontCache
    let pages: [PDFObjectFile.Page]
    let signatures: PDFObjectFile.Signatures

    /// The edit list. Change it through the methods below, which register undo.
    private(set) var edits: [PDFEdit] = []
    /// Registers undo for every change (the window's undo manager).
    var undoManager: UndoManager?
    var onChange: ((PDFEditChange) -> Void)?
    /// "Remove replaced text from the file" (a full rewrite on save). Off by default; never for signed files.
    var removeReplacedText = false

    private var contents: [Int: PDFPageContent] = [:]
    private var build: PDFEditBuild?
    private var analysis: PDFEditAnalysis?
    private var candidateDoc: PDFDocument?
    private var blankedPreviews: [PDFLineID: PDFDocument] = [:]
    private var hiddenAddPreviews: [UUID: PDFDocument] = [:]
    private var evidenceComplete = false
    /// Per OCR line over a scan: how it looks in the picture (nil when it isn't one, or can't be read).
    private var scanLooks: [PDFLineID: PDFScanLook?] = [:]
    private var formPagesCache: [Int: Set<Int>]?

    var pageCount: Int { pages.count }
    var isReadOnly: Bool { signatures.noChangesAllowed }
    var hasChanges: Bool { !edits.isEmpty }
    /// Pages with at least one edit or added text (the sidebar's "edited" dot).
    var pagesWithChanges: Set<Int> { Set(edits.map(\.page)) }
    var canRemoveReplacedText: Bool { !signatures.signed }
    var removeReplacedTextUnavailableReason: String? {
        signatures.signed ? "Not available for signed PDFs: rewriting the file would remove the signed version." : nil
    }

    convenience init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url), url: url)
    }

    init(data: Data, url: URL) throws {
        self.url = url
        originalData = data
        let name = url.lastPathComponent
        guard let doc = PDFDocument(data: data) else { throw ConversionError.unreadable(name) }
        if doc.isEncrypted || doc.isLocked {
            throw ConversionError.unsupported("\(name) is encrypted, so its text can’t be edited. Use Remove Password first.")
        }
        originalDocument = doc
        do { file = try PDFObjectFile(data) } catch {
            throw ConversionError.unsupported("\(name) is damaged in a way Edit PDF can’t read: \(error.localizedDescription)")
        }
        if file.isEncrypted {
            throw ConversionError.unsupported("\(name) is encrypted, so its text can’t be edited. Use Remove Password first.")
        }
        pages = file.pages()
        guard pages.count == doc.pageCount, !pages.isEmpty else {
            throw ConversionError.unsupported("\(name)’s pages can’t be read reliably, so it can’t be edited.")
        }
        fonts = PDFEditFontCache(file)
        signatures = file.signatures
    }

    // MARK: Reading

    /// The original page as Edit PDF reads it (lines in reading order).
    func content(page i: Int) -> PDFPageContent {
        if let c = contents[i] { return c }
        let doc = originalDocument
        let c = PDFPageContent(file: file, page: pages[i], fonts: fonts) { rect in
            let r = rect.insetBy(dx: min(0.5, rect.width * 0.05), dy: min(2, rect.height * 0.2))
            return doc.page(at: i)?.selection(for: r)?.string
        }
        contents[i] = c
        return c
    }

    func lines(page i: Int) -> [PDFTextLine] { content(page: i).lines }

    func line(_ id: PDFLineID) -> PDFTextLine? {
        guard id.page >= 0, id.page < pages.count else { return nil }
        let l = lines(page: id.page)
        return id.line >= 0 && id.line < l.count ? l[id.line] : nil
    }

    /// Line ids whose text contains `text`, in page and reading order.
    func find(_ text: String, page: Int? = nil) -> [PDFLineID] {
        let needle = text.precomposedStringWithCanonicalMapping
        guard !needle.isEmpty else { return [] }
        var out: [PDFLineID] = []
        for p in page.map({ [$0] }) ?? Array(0..<pages.count) where p >= 0 && p < pages.count {
            for l in lines(page: p) where l.text.precomposedStringWithCanonicalMapping.contains(needle) {
                out.append(PDFLineID(page: p, line: l.index))
            }
        }
        return out
    }

    func availability(_ id: PDFLineID) -> PDFLineAvailability {
        if signatures.noChangesAllowed { return .readOnly("The signature on this PDF doesn’t allow changes.") }
        guard let l = line(id) else { return .readOnly("This line no longer exists.") }
        let c = content(page: id.page)
        if let p = c.problems.first { return .readOnly(p) }
        if !cgStreamCountMatches(id.page) { return .readOnly("This page’s content can’t be read reliably, so it can’t be edited.") }
        let rs = l.runs.map { c.runs[$0] }
        for r in rs {
            guard let f = c.font(of: r) else { return .readOnly("This text’s font is missing from the PDF.") }
            if f.vertical { return .readOnly("Vertical text can’t be edited yet.") }
        }
        if rs.allSatisfy({ $0.fontFromGState }) { return .readOnly("This text’s font is set in an unusual way, so it can’t be edited.") }
        if l.units.allSatisfy({ $0.text.isEmpty || $0.run == nil }) {
            return .readOnly("This text has no character information, so it can’t be edited.")
        }
        return .editable
    }

    private var cgCounts: [Int: Bool] = [:]
    /// The page's content streams as Core Graphics counts them, cross-checked against the page tree.
    private func cgStreamCountMatches(_ i: Int) -> Bool {
        if let v = cgCounts[i] { return v }
        var ok = true
        if let ref = originalDocument.page(at: i)?.pageRef {
            let cs = CGPDFContentStreamCreateWithPage(ref)
            let n = (CGPDFContentStreamGetStreams(cs) as? [Any])?.count ?? pages[i].contents.count
            ok = n == pages[i].contents.filter { file.object($0)?.stream != nil }.count
        }
        cgCounts[i] = ok
        return ok
    }

    func notes(_ id: PDFLineID) -> [PDFLineNote] {
        guard let l = line(id) else { return [] }
        let c = content(page: id.page)
        var n: [PDFLineNote] = []
        let rs = l.runs.map { c.runs[$0] }
        if l.hidden { n.append(scanLook(id).map { .scannedText(font: $0.fontDisplayName) } ?? .hiddenText) }
        if rs.contains(where: { $0.renderMode >= 4 }) { n.append(.clippingText) }
        if rs.contains(where: { c.font(of: $0)?.kind == .type3 }) { n.append(.drawnGlyphs) }
        let a = l.angle.truncatingRemainder(dividingBy: 90)
        if abs(a) > 0.5 && abs(abs(a) - 90) > 0.5 { n.append(.rotated(l.angle)) }
        return n
    }

    /// Pages that draw the form a line lives in (1 for ordinary page text).
    func sharedPages(_ id: PDFLineID) -> Int {
        guard let l = line(id) else { return 1 }
        let c = content(page: id.page)
        guard c.streams[l.stream].isForm else { return 1 }
        let n = c.streams[l.stream].objectNumber
        let uses = formPages()[n] ?? [id.page]
        return max(1, uses.count)
    }

    /// Form object number → pages that draw it.
    func formPages() -> [Int: Set<Int>] {
        if let formPagesCache { return formPagesCache }
        var map: [Int: Set<Int>] = [:]
        for i in 0..<min(pages.count, 2000) {
            for (n, _) in content(page: i).formUses { map[n, default: []].insert(i) }
        }
        formPagesCache = map
        return map
    }

    func banners(page i: Int) -> [PDFEditBanner] {
        var out: [PDFEditBanner] = []
        if signatures.noChangesAllowed { out.append(.certified) } else if signatures.signed { out.append(.signed) }
        let c = content(page: i)
        if let p = c.problems.first { out.append(.unreadable(p)) }
        let crop = pages[i].cropBox
        let covered = c.images.contains { img in
            let r = img.bounds.intersection(crop)
            return !r.isNull && r.width * r.height >= 0.5 * crop.width * crop.height
        }
        if covered {
            let visible = c.lines.filter { !$0.hidden }
            if c.lines.isEmpty { out.append(.scanned) }
            else if visible.isEmpty { out.append(.ocrOnly) }
        }
        return out
    }

    /// The banner for the selected line (shared text), if any.
    func banner(for id: PDFLineID) -> PDFEditBanner? {
        let n = sharedPages(id)
        return n > 1 ? .sharedText(pages: n) : nil
    }

    // MARK: Changing (each registers one undo step)

    /// Replaces a line's text (the edit is relative to the original line).
    func setText(_ newText: String, for id: PDFLineID, spacing: PDFSpacing? = nil, scope: PDFEditScope? = nil) throws {
        guard let l = line(id) else { throw ConversionError.unsupported("That line doesn’t exist.") }
        // One line at a time: line breaks and tabs typed into the editor become spaces.
        let text = newText.replacingOccurrences(of: "\r\n", with: " ").map { $0.isNewline || $0 == "\t" ? " " : String($0) }.joined()
        if case .readOnly(let why) = availability(id) { throw ConversionError.unsupported(why) }
        let old = edit(for: id)
        if case .styled(_, let t, let style, let sc)? = old {
            // A restyled line keeps its style while its text changes.
            if t == text { return }
            if text.trimmingCharacters(in: .whitespaces).isEmpty { try deleteLine(id, scope: scope ?? sc); return }
            try replaceEdits(edits.map { $0.line == id ? .styled(line: id, text: text, style: style, scope: scope ?? sc) : $0 },
                             actionName: "Edit Text", lines: [id])
            return
        }
        if text.precomposedStringWithCanonicalMapping == l.text.precomposedStringWithCanonicalMapping {
            if old != nil { try replaceEdits(edits.filter { $0.line != id }, actionName: "Edit Text", lines: [id]) }
            return
        }
        let sp = spacing ?? old?.spacingValue ?? .flow
        let sc = scope ?? old?.scopeValue ?? .thisPage
        let entry = PDFEdit.text(line: id, text: text, spacing: sp, scope: sc)
        if entry == old { return }
        var new = edits
        if let i = new.firstIndex(where: { $0.line == id }) { new[i] = entry } else { new.append(entry) }
        try replaceEdits(new, actionName: "Edit Text", lines: [id])
    }

    /// Removes a line's text with a spacer, so nothing else moves.
    func deleteLine(_ id: PDFLineID, scope: PDFEditScope? = nil) throws {
        if case .readOnly(let why) = availability(id) { throw ConversionError.unsupported(why) }
        let sc = scope ?? edit(for: id)?.scopeValue ?? .thisPage
        var new = edits
        let entry = PDFEdit.delete(line: id, scope: sc)
        if let i = new.firstIndex(where: { $0.line == id }) { new[i] = entry } else { new.append(entry) }
        try replaceEdits(new, actionName: "Delete Text", lines: [id])
    }

    /// Back to the original text.
    func revert(_ id: PDFLineID) {
        guard edits.contains(where: { $0.line == id }) else { return }
        try? replaceEdits(edits.filter { $0.line != id }, actionName: "Revert Text", lines: [id])
    }

    func setSpacing(_ spacing: PDFSpacing, for id: PDFLineID) throws {
        guard let e = edit(for: id), case .text(_, let t, let sp, let sc) = e, sp != spacing else { return }
        try replaceEdits(edits.map { $0.line == id ? .text(line: id, text: t, spacing: spacing, scope: sc) : $0 },
                         actionName: "Change Spacing", lines: [id])
    }

    func setScope(_ scope: PDFEditScope, for id: PDFLineID) throws {
        guard let e = edit(for: id) else { return }
        let changed: PDFEdit
        switch e {
        case .text(let l, let t, let sp, _): changed = .text(line: l, text: t, spacing: sp, scope: scope)
        case .delete(let l, _): changed = .delete(line: l, scope: scope)
        case .styled(let l, let t, let st, _): changed = .styled(line: l, text: t, style: st, scope: scope)
        case .add, .mark: return
        }
        try replaceEdits(edits.map { $0.line == id ? changed : $0 }, actionName: scope == .allPages ? "Edit All Pages" : "Edit This Page", lines: [id])
    }

    /// New text at a baseline origin in page space (upright for the page's rotation).
    @discardableResult
    func addText(_ text: String, page: Int, at origin: CGPoint, style: PDFTextStyle) throws -> UUID {
        guard page >= 0, page < pages.count else { throw ConversionError.unsupported("Page \(page + 1) doesn’t exist.") }
        if signatures.noChangesAllowed { throw ConversionError.unsupported("The signature on this PDF doesn’t allow changes.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversionError.unsupported("Type some text to add.") }
        let id = UUID()
        try replaceEdits(edits + [.add(id: id, page: page, origin: origin, text: text, style: style)], actionName: "Add Text", added: [id])
        return id
    }

    func updateAddedText(_ id: UUID, text: String? = nil, origin: CGPoint? = nil, style: PDFTextStyle? = nil) throws {
        guard let i = edits.firstIndex(where: { $0.addID == id }), case .add(_, let p, let o, let t, let s) = edits[i] else { return }
        var new = edits
        new[i] = .add(id: id, page: p, origin: origin ?? o, text: text ?? t, style: style ?? s)
        if new == edits { return }
        try replaceEdits(new, actionName: origin != nil && text == nil ? "Move Text" : "Edit Text", added: [id])
    }

    func removeAddedText(_ id: UUID) {
        guard edits.contains(where: { $0.addID == id }) else { return }
        try? replaceEdits(edits.filter { $0.addID != id }, actionName: "Delete Text", added: [id])
    }

    // MARK: Style of a line

    /// True when the line is redrawn in a style of its own (it is then drawn whole: spacing doesn't apply).
    func isRestyled(_ id: PDFLineID) -> Bool { if case .styled? = edit(for: id) { return true }; return false }

    /// The style a line is drawn in now: its restyle, else its own font (or the scan's closest match), size and colour.
    func style(of id: PDFLineID) -> PDFTextStyle? {
        if case .styled(_, _, let st, _)? = edit(for: id) { return st }
        guard let l = line(id) else { return nil }
        if let scan = scanLook(id) { return scan.style }
        let font = editorFont(id).font
        let c = content(page: id.page)
        let fill = l.runs.first.map { c.runs[$0].fill } ?? [0]
        return PDFTextStyle(fontName: font.fontName, size: (l.pointSize * 100).rounded() / 100, color: PDFEditSession.color(fill))
    }

    /// Redraws a line in `style` (another font, bold, italic, size or colour), keeping its current text.
    func setStyle(_ style: PDFTextStyle, for id: PDFLineID) throws {
        guard let l = line(id) else { throw ConversionError.unsupported("That line doesn’t exist.") }
        if case .readOnly(let why) = availability(id) { throw ConversionError.unsupported(why) }
        guard NSFont(name: style.fontName, size: 12) != nil else { throw ConversionError.unsupported("The font \(style.fontName) isn’t on this Mac.") }
        let old = edit(for: id)
        var text = l.text
        switch old {
        case .text(_, let t, _, _)?: text = t
        case .styled(_, let t, _, _)?: text = t
        case .delete?: throw ConversionError.unsupported("The line is deleted. Revert it first.")
        default: break
        }
        let entry = PDFEdit.styled(line: id, text: text, style: style, scope: old?.scopeValue ?? .thisPage)
        if entry == old { return }
        var new = edits
        if let i = new.firstIndex(where: { $0.line == id }) { new[i] = entry } else { new.append(entry) }
        try replaceEdits(new, actionName: "Change Style", lines: [id])
    }

    // MARK: Highlights and pictures

    var marks: [PDFMark] {
        edits.compactMap { if case .mark(let id, let p, let k) = $0 { return PDFMark(id: id, page: p, kind: k) }; return nil }
    }

    @discardableResult
    func addMark(_ kind: PDFMarkKind, page: Int) throws -> UUID {
        guard page >= 0, page < pages.count else { throw ConversionError.unsupported("Page \(page + 1) doesn’t exist.") }
        if signatures.noChangesAllowed { throw ConversionError.unsupported("The signature on this PDF doesn’t allow changes.") }
        let id = UUID()
        let name: String
        switch kind { case .highlight: name = "Highlight"; case .image: name = "Add Picture" }
        try replaceEdits(edits + [.mark(id: id, page: page, kind: kind)], actionName: name, added: [id])
        return id
    }

    func updateMark(_ id: UUID, _ kind: PDFMarkKind, actionName: String) throws {
        guard let i = edits.firstIndex(where: { $0.markID == id }), case .mark(_, let p, let old) = edits[i], old != kind else { return }
        var new = edits
        new[i] = .mark(id: id, page: p, kind: kind)
        try replaceEdits(new, actionName: actionName, added: [id])
    }

    func removeMark(_ id: UUID) {
        guard let m = marks.first(where: { $0.id == id }) else { return }
        let name: String
        switch m.kind { case .highlight: name = "Remove Highlight"; case .image: name = "Remove Picture" }
        try? replaceEdits(edits.filter { $0.markID != id }, actionName: name, added: [id])
    }

    /// Sets the whole edit list (the undo model), rebuilding the candidate first; a refusal leaves everything as it was.
    func replaceEdits(_ new: [PDFEdit], actionName: String, lines: [PDFLineID] = [], added: [UUID] = []) throws {
        let old = edits
        let b = try makeBuild(new)
        edits = new
        build = b
        analysis = nil
        candidateDoc = nil
        blankedPreviews = [:]
        hiddenAddPreviews = [:]
        if let um = undoManager {
            um.registerUndo(withTarget: self) { s in try? s.replaceEdits(old, actionName: actionName, lines: lines, added: added) }
            um.setActionName(actionName)
        }
        onChange?(PDFEditChange(lines: lines, added: added, actionName: actionName))
    }

    private func edit(for id: PDFLineID) -> PDFEdit? { edits.first { $0.line == id } }

    var addedTexts: [PDFAddedText] {
        let a = currentAnalysis()
        return edits.compactMap { e in
            guard case .add(let id, let p, let o, let t, let s) = e else { return nil }
            return PDFAddedText(id: id, page: p, origin: o, text: t, style: s, quad: a?.addedQuads[id] ?? [],
                                substitutions: build?.addSubstitutions[id] ?? [])
        }
    }

    // MARK: Candidate

    private func currentBuild() throws -> PDFEditBuild {
        if let build { return build }
        let b = try makeBuild(edits)
        build = b
        return b
    }

    /// Original + pending update: exactly what Save writes (before the gate).
    var candidateData: Data { (try? currentBuild())?.data ?? originalData }

    /// The candidate as a PDFDocument. Keep a strong reference while drawing its pages.
    var candidateDocument: PDFDocument {
        if let candidateDoc { return candidateDoc }
        let d = PDFDocument(data: candidateData) ?? originalDocument
        candidateDoc = d
        return d
    }

    /// The candidate with one more line removed (spacer delete), to draw behind the inline editor.
    func previewDocument(blanking id: PDFLineID) -> PDFDocument? {
        if let d = blankedPreviews[id] { return d }
        var list = edits.filter { $0.line != id }
        list.append(.delete(line: id, scope: edit(for: id)?.scopeValue ?? .thisPage))
        guard let b = try? makeBuild(list), let d = PDFDocument(data: b.data) else { return nil }
        blankedPreviews[id] = d
        return d
    }

    /// The candidate without one added text, to draw behind the inline editor while that text is edited.
    func previewDocument(hidingAdded id: UUID) -> PDFDocument? {
        if let d = hiddenAddPreviews[id] { return d }
        let list = edits.filter { $0.addID != id }
        let d: PDFDocument?
        if list.isEmpty { d = originalDocument }
        else { d = (try? makeBuild(list)).flatMap { PDFDocument(data: $0.data) } }
        hiddenAddPreviews[id] = d
        return d
    }

    private func currentAnalysis() -> PDFEditAnalysis? {
        if let analysis { return analysis }
        guard let b = try? currentBuild() else { return nil }
        let a = PDFEditAnalysis(session: self, build: b)
        analysis = a
        return a
    }

    func info(_ id: PDFLineID) -> PDFLineInfo? {
        guard let l = line(id) else { return nil }
        let c = content(page: id.page)
        let e = edit(for: id)
        let a = e == nil ? nil : currentAnalysis()
        let st = a?.lines[id]
        let firstRun = l.runs.first.map { c.runs[$0] }
        let font = firstRun.flatMap { c.font(of: $0) }
        var text = l.text
        var deleted = false
        var styled: PDFTextStyle?
        switch e {
        case .text(_, let t, _, _)?: text = t
        case .styled(_, let t, let st, _)?: text = t; styled = st
        case .delete?: text = ""; deleted = true
        default: break
        }
        // The picture is read when the line is edited or opened for typing (editorFont), not for every line listed.
        let scan = e != nil ? scanLook(id) : cachedScanLook(id)
        let quad = st?.quad ?? l.quad
        let styledName = styled.map { NSFont(name: $0.fontName, size: 12)?.displayName ?? $0.fontName }
        return PDFLineInfo(id: id, originalText: l.text, text: text, isEdited: e != nil, isDeleted: deleted,
                           quad: quad, originalQuad: l.quad, origin: scan?.origin ?? l.origin, direction: l.direction, angle: l.angle,
                           pointSize: styled?.size ?? scan?.style.size ?? l.pointSize,
                           color: styled?.color ?? scan?.style.color ?? PDFEditSession.color(firstRun?.fill ?? [0]), availability: availability(id),
                           notes: notes(id),
                           fontDescription: styledName.map { "\($0) (this Mac)" }
                               ?? scan.map { "Scanned text, drawn in \($0.fontDisplayName) (closest match on this Mac)" }
                               ?? font?.sourceDescription ?? "Unknown font",
                           substitutions: build?.lineSubstitutions[id] ?? [], spacing: e?.spacingValue ?? .flow,
                           scope: e?.scopeValue ?? .thisPage, sharedPages: sharedPages(id), overflow: st?.overflow ?? 0,
                           fitScale: build?.fitScales[id] ?? 1)
    }

    /// The font the inline editor types in, sized in page points (multiply by the zoom).
    func editorFont(_ id: PDFLineID) -> (font: NSFont, source: PDFEditorFontSource) {
        if case .styled(_, _, let st, _)? = edit(for: id), let f = NSFont(name: st.fontName, size: CGFloat(st.size)) { return (f, .installed) }
        if let scan = scanLook(id), let f = NSFont(name: scan.style.fontName, size: CGFloat(scan.style.size)) { return (f, .similar) }
        guard let l = line(id), let r = l.runs.first else { return (NSFont.systemFont(ofSize: 12), .system) }
        let c = content(page: id.page)
        return PDFFontMatch.editorFont(for: c.font(of: c.runs[r]), size: CGFloat(max(1, l.pointSize)))
    }

    static func color(_ fill: [Double]) -> CGColor {
        func c(_ v: Double) -> CGFloat { CGFloat(min(1, max(0, v))) }
        switch fill.count {
        case 3: return CGColor(srgbRed: c(fill[0]), green: c(fill[1]), blue: c(fill[2]), alpha: 1)
        case 4:
            let k = fill[3]
            return CGColor(srgbRed: c((1 - fill[0]) * (1 - k)), green: c((1 - fill[1]) * (1 - k)), blue: c((1 - fill[2]) * (1 - k)), alpha: 1)
        default: return CGColor(srgbRed: c(fill.first ?? 0), green: c(fill.first ?? 0), blue: c(fill.first ?? 0), alpha: 1)
        }
    }

    /// "3 changes on 2 pages · 1 font substituted · Replaced text stays in the file’s history".
    var statusText: String {
        guard !edits.isEmpty else { return "No changes" }
        let n = edits.count
        let p = Set(edits.map(\.page)).count
        var parts = ["\(n) \(n == 1 ? "change" : "changes") on \(p) \(p == 1 ? "page" : "pages")"]
        let subs = build?.substitutedFonts.count ?? 0
        if subs > 0 { parts.append("\(subs) \(subs == 1 ? "font" : "fonts") substituted") }
        if !removeReplacedText && edits.contains(where: { $0.line != nil }) { parts.append("Replaced text stays in the file’s history") }
        return parts.joined(separator: " · ")
    }

    // MARK: Saving

    /// Builds the output, runs the verification gate in memory and writes "<name> edited.pdf" next to the original
    /// (or `destination`). Nothing is written when the gate fails.
    @discardableResult
    func save(to destination: URL? = nil) throws -> URL {
        guard !edits.isEmpty else { throw ConversionError.unsupported("There are no changes to save.") }
        let b = try currentBuild()
        var out = b.data
        let compact = (removeReplacedText && canRemoveReplacedText) || file.rebuilt
        if compact {
            guard let m = try? PDFObjectFile(out) else { throw ConversionError.toolFailed("The edited PDF couldn’t be read back, so nothing was saved.") }
            out = PDFCompactWriter.rewrite(m)
        }
        let a = currentAnalysis() ?? PDFEditAnalysis(session: self, build: b)
        try PDFEditVerify.check(session: self, build: b, analysis: a, output: out, incremental: !compact)
        let target = destination ?? outputURL(for: url, ext: "pdf", suffix: " edited")
        do { try out.write(to: target, options: .atomic) } catch {
            throw ConversionError.toolFailed("Couldn’t save \(target.lastPathComponent): \(error.localizedDescription)")
        }
        return target
    }

    /// The current build and its analysis (self-tests and the gate).
    func currentBuildAndAnalysis() throws -> (build: PDFEditBuild, analysis: PDFEditAnalysis) {
        let b = try currentBuild()
        return (b, currentAnalysis() ?? PDFEditAnalysis(session: self, build: b))
    }

    /// The look if it has been worked out already (nil otherwise, without reading the picture).
    func cachedScanLook(_ id: PDFLineID) -> PDFScanLook? { scanLooks[id] ?? nil }

    /// How an OCR line over a scan looks in the picture; nil for every other line.
    func scanLook(_ id: PDFLineID) -> PDFScanLook? {
        if let cached = scanLooks[id] { return cached }
        let used = Set(scanLooks.values.compactMap { $0?.style.fontName })
        let look = PDFScanText.look(self, id, preferred: used)
        scanLooks[id] = .some(look)
        return look
    }

    // MARK: Building

    /// Every page has been read once, so codes used anywhere count as evidence.
    func ensureEvidence() {
        guard !evidenceComplete else { return }
        evidenceComplete = true
        for i in 0..<min(pages.count, 400) { _ = content(page: i) }
    }

    private func makeBuild(_ list: [PDFEdit]) throws -> PDFEditBuild {
        try PDFEditBuilder(session: self, edits: list).run()
    }
}

private extension PDFEdit {
    var spacingValue: PDFSpacing? { if case .text(_, _, let s, _) = self { return s }; return nil }
    var scopeValue: PDFEditScope? {
        switch self {
        case .text(_, _, _, let s), .delete(_, let s), .styled(_, _, _, let s): return s
        case .add, .mark: return nil
        }
    }
}

// MARK: - The build

/// The candidate update and what the UI and the gate need to know about it.
struct PDFEditBuild {
    let data: Data
    let written: Set<Int>
    /// Pages whose drawing may change.
    let editedPages: Set<Int>
    /// Per target object (or page copy), the splices into its decoded data: original range → new byte count.
    let splices: [PDFEditBuilder.Target: [(range: Range<Int>, length: Int)]]
    /// Original object → the object that holds its new data, per page (copy-on-write content and forms).
    let renames: [Int: [Int: Int]]
    let lineSubstitutions: [PDFLineID: [PDFFontSubstitution]]
    let addSubstitutions: [UUID: [PDFFontSubstitution]]
    let substitutedFonts: Set<String>
    let fitScales: [PDFLineID: Double]
    /// The new text of each edited line, for the read-back check.
    let expectedText: [PDFLineID: String]
    /// Pages with an Add Text stream: the object number of the appended stream.
    let addedStreams: [Int: Int]
    let addIDsByPage: [Int: [UUID]]
    /// Per page, scanned (OCR) lines whose new text the appended stream draws, in drawing order, before any added text.
    var scanLinesByPage: [Int: [PDFLineID]] = [:]
    /// Per page, the paper-coloured covers painted over old scanned words.
    var scanCovers: [Int: [CGRect]] = [:]
}

/// Turns the edit list into one incremental update.
final class PDFEditBuilder {
    enum Target: Hashable {
        case object(Int)
        case pageCopy(object: Int, page: Int)
        var object: Int {
            switch self { case .object(let n), .pageCopy(let n, _): return n }
        }
    }

    private struct Splice {
        let target: Target
        let range: Range<Int>
        let bytes: [UInt8]
        let order: Int
    }

    /// A piece of new text: in the run's own font, or a transplant.
    private struct Piece {
        var text: String
        var own: [UInt8]?
        var transplant: Int?
        /// Advance in text space for size 1, without Tc/Tw/Th.
        var width: Double
        var codes: [UInt32]
        /// Codes of a transplanted piece, in its scratch font.
        var foreignBytes: [UInt8] = []
    }

    private let session: PDFEditSession
    private let edits: [PDFEdit]
    private let file: PDFObjectFile
    private let update: PDFIncrementalUpdate
    private var splices: [Splice] = []
    private var order = 0
    private var requests: [PDFTransplant.Request] = []
    private var transplant: PDFTransplant.Result?
    private var copiedFonts: [Int: Int] = [:]
    private var copyMemo: [Int: Int] = [:]
    private var pendingDicts: [Int: PDFDict] = [:]
    private var pendingPages: [Int: PDFDict] = [:]
    private var pendingFormDicts: [Target: PDFDict] = [:]
    private var fontNames: [String: String] = [:]
    private var lineSubs: [PDFLineID: [PDFFontSubstitution]] = [:]
    private var addSubs: [UUID: [PDFFontSubstitution]] = [:]
    private var substitutedFonts = Set<String>()
    private var fitScales: [PDFLineID: Double] = [:]
    private var expected: [PDFLineID: String] = [:]
    private var contentRefCount: [Int: Int] = [:]
    private var editedPages = Set<Int>()

    init(session: PDFEditSession, edits: [PDFEdit]) {
        self.session = session
        self.edits = edits
        file = session.file
        update = PDFIncrementalUpdate(session.file)
        for p in session.pages { for n in p.contents { contentRefCount[n, default: 0] += 1 } }
    }

    // MARK: Plans

    private struct LinePlan {
        let id: PDFLineID
        let content: PDFPageContent
        let line: PDFTextLine
        let spacing: PDFSpacing
        let scope: PDFEditScope
        let delete: Bool
        /// Per affected run: glyph cut [g0, g1); the host also gets the new pieces.
        var cuts: [(run: Int, g0: Int, g1: Int)]
        var host: Int?
        var middle: String
        var pieces: [Piece] = []
        var newText: String
    }

    /// An OCR line over a scan: its invisible text is deleted, the old ink covered and the new text drawn visibly.
    private struct ScanPlan {
        let id: PDFLineID
        var look: PDFScanLook
        /// Nil for a delete (cover only).
        let text: String?
        let spacing: PDFSpacing
        let request: Int?
        /// Baseline direction, page space (restyled lines keep theirs).
        var direction = CGVector(dx: 1, dy: 0)
        /// Unchanged words before the edit: left as they are in the picture and written as invisible text, so the
        /// line still reads whole.
        var keptText: String? = nil
        var keptRequest: Int? = nil
        var keptOrigin: CGPoint = .zero
    }

    /// Narrows a scanned line's edit to its first changed word: the cover starts there and only the words from
    /// there on are drawn. Nil when the whole line is redrawn.
    private func narrowed(_ look: PDFScanLook, old: String, new: String) -> (look: PDFScanLook, kept: String, drawn: String)? {
        guard let starts = look.wordStarts else { return nil }
        let o = old.split(separator: " ").map(String.init), n = new.split(separator: " ").map(String.init)
        guard starts.count == o.count else { return nil }
        var p = 0
        while p < o.count, p < n.count, o[p] == n[p] { p += 1 }
        guard p > 0, p < o.count, p < n.count else { return nil }
        let drawn = n[p...].joined(separator: " ")
        let font = CTFontCreateWithName(look.style.fontName as CFString, CGFloat(look.style.size), nil)
        let lead = PDFScanText.inkBounds(drawn, font).minX
        let x = starts[p]
        let pad = max(0.75, 0.06 * look.style.size)
        var l = look
        let c = look.cover
        let x0 = max(c.minX, x - pad)
        l = PDFScanLook(cover: CGRect(x: x0, y: c.minY, width: c.maxX - x0, height: c.height), paper: look.paper, ink: look.ink,
                        style: look.style, origin: CGPoint(x: x - (lead.isFinite ? lead : 0), y: look.origin.y),
                        inkWidth: Double(look.inkRight - x), wordStarts: look.wordStarts, inkRight: look.inkRight)
        return (l, n[..<p].joined(separator: " "), drawn)
    }

    private struct AddPlan {
        let id: UUID
        let page: Int
        let origin: CGPoint
        let text: String
        let style: PDFTextStyle
        var request: Int
    }

    func run() throws -> PDFEditBuild {
        guard !edits.isEmpty else {
            return PDFEditBuild(data: session.originalData, written: [], editedPages: [], splices: [:], renames: [:],
                                lineSubstitutions: [:], addSubstitutions: [:], substitutedFonts: [], fitScales: [:],
                                expectedText: [:], addedStreams: [:], addIDsByPage: [:])
        }
        var plans: [LinePlan] = []
        var adds: [AddPlan] = []
        var scans: [ScanPlan] = []
        var marks: [(id: UUID, page: Int, kind: PDFMarkKind)] = []
        for e in edits {
            switch e {
            case .text(let id, let text, let spacing, let scope):
                if let look = session.scanLook(id) {
                    let shown = String(text.reversed().drop(while: { $0 == " " }).reversed())
                    if PDFTransplant.isEmoji(shown) { throw ConversionError.unsupported("Emoji can’t be added as PDF text.") }
                    plans.append(try plan(id, newText: "", spacing: .keep, scope: scope, delete: true))
                    if shown.trimmingCharacters(in: .whitespaces).isEmpty {
                        scans.append(ScanPlan(id: id, look: look, text: nil, spacing: spacing, request: nil))
                    } else if let old = session.line(id)?.text, let nw = narrowed(look, old: old, new: shown) {
                        let f = CTFontCreateWithName(look.style.fontName as CFString, 100, nil)
                        requests.append(PDFTransplant.Request(text: nw.kept + " ", font: f))
                        let keptReq = requests.count - 1
                        requests.append(PDFTransplant.Request(text: nw.drawn, font: f))
                        var sp = ScanPlan(id: id, look: nw.look, text: shown, spacing: spacing, request: requests.count - 1)
                        sp.keptText = nw.kept
                        sp.keptRequest = keptReq
                        sp.keptOrigin = look.origin
                        scans.append(sp)
                    } else {
                        requests.append(PDFTransplant.Request(text: shown, font: CTFontCreateWithName(look.style.fontName as CFString, 100, nil)))
                        scans.append(ScanPlan(id: id, look: look, text: shown, spacing: spacing, request: requests.count - 1))
                    }
                } else {
                    plans.append(try plan(id, newText: text, spacing: spacing, scope: scope, delete: false))
                }
            case .delete(let id, let scope):
                plans.append(try plan(id, newText: "", spacing: .keep, scope: scope, delete: true))
                if let look = session.scanLook(id) { scans.append(ScanPlan(id: id, look: look, text: nil, spacing: .keep, request: nil)) }
            case .styled(let id, let text, let style, let scope):
                // The line's own text goes (as Delete), a scan's old words are covered, and the text is drawn in the style.
                guard let l = session.line(id) else { throw ConversionError.unsupported("\(id) doesn’t exist.") }
                let shown = String(text.reversed().drop(while: { $0 == " " }).reversed())
                if PDFTransplant.isEmoji(shown) { throw ConversionError.unsupported("Emoji can’t be added as PDF text.") }
                plans.append(try plan(id, newText: "", spacing: .keep, scope: scope, delete: true))
                let scan = session.scanLook(id)
                let look = PDFScanLook(cover: scan?.cover ?? .null, paper: scan?.paper ?? [], ink: scan?.ink ?? [], style: style,
                                       origin: scan?.origin ?? l.origin, inkWidth: scan?.inkWidth ?? Double(l.bounds.width))
                if shown.trimmingCharacters(in: .whitespaces).isEmpty {
                    if scan != nil { scans.append(ScanPlan(id: id, look: look, text: nil, spacing: .flow, request: nil)) }
                } else {
                    requests.append(PDFTransplant.Request(text: shown, font: CTFontCreateWithName(style.fontName as CFString, 100, nil)))
                    var sp = ScanPlan(id: id, look: look, text: shown, spacing: .flow, request: requests.count - 1)
                    if scan == nil { sp.direction = l.direction }
                    scans.append(sp)
                }
            case .mark(let id, let page, let kind):
                marks.append((id, page, kind))
            case .add(let id, let page, let origin, let text, let style):
                let ct = CTFontCreateWithName(style.fontName as CFString, 100, nil)
                requests.append(PDFTransplant.Request(text: text.replacingOccurrences(of: "\n", with: " "), font: ct))
                adds.append(AddPlan(id: id, page: page, origin: origin, text: text, style: style, request: requests.count - 1))
            }
        }
        // Encode the new text: the run's own font first, the rest from a font on this Mac.
        for i in plans.indices where !plans[i].middle.isEmpty {
            plans[i].pieces = try pieces(for: &plans[i])
        }
        if !requests.isEmpty { transplant = try PDFTransplant.draw(requests) }
        for i in plans.indices where !plans[i].pieces.isEmpty { try resolveTransplants(&plans[i]) }
        for p in plans { try emit(p) }
        for sp in scans { if let t = sp.text { expected[sp.id] = t } }
        var addedStreams: [Int: Int] = [:]
        var addIDs: [Int: [UUID]] = [:]
        var scanLines: [Int: [PDFLineID]] = [:]
        var scanCovers: [Int: [CGRect]] = [:]
        for page in Set(adds.map(\.page) + scans.map(\.id.page) + marks.map(\.page)).sorted() {
            let list = adds.filter { $0.page == page }
            let pageScans = scans.filter { $0.id.page == page }
            let pageMarks = marks.filter { $0.page == page }.map(\.kind)
            addedStreams[page] = try emitAdds(list, scans: pageScans, marks: pageMarks, page: page)
            addIDs[page] = list.map(\.id)
            scanLines[page] = pageScans.filter { $0.text != nil }.map(\.id)
            scanCovers[page] = pageScans.map(\.look.cover).filter { !$0.isNull } + pageMarks.map { $0.bounds.insetBy(dx: -1, dy: -1) }
        }
        let renames = try writeTargets()
        for (pi, d) in pendingPages { update.put(session.pages[pi].number, .dict(d), generation: session.pages[pi].generation) }
        for (n, d) in pendingDicts { update.put(n, .dict(d)) }
        let data = update.data()
        var written = update.writtenNumbers
        if let x = update.xrefStreamNumber { written.insert(x) }
        var spliceMap: [Target: [(range: Range<Int>, length: Int)]] = [:]
        for (t, list) in groupedSplices() { spliceMap[t] = list.map { ($0.range, $0.bytes.count) } }
        return PDFEditBuild(data: data, written: written, editedPages: editedPages, splices: spliceMap, renames: renames,
                            lineSubstitutions: lineSubs, addSubstitutions: addSubs, substitutedFonts: substitutedFonts,
                            fitScales: fitScales, expectedText: expected, addedStreams: addedStreams, addIDsByPage: addIDs,
                            scanLinesByPage: scanLines, scanCovers: scanCovers)
    }

    /// Common prefix and suffix in glyph units; the middle replaces the units between.
    private func plan(_ id: PDFLineID, newText: String, spacing: PDFSpacing, scope: PDFEditScope, delete: Bool) throws -> LinePlan {
        guard let line = session.line(id) else { throw ConversionError.unsupported("\(id) doesn’t exist.") }
        if case .readOnly(let why) = session.availability(id) { throw ConversionError.unsupported(why) }
        let content = session.content(page: id.page)
        let units = line.units
        let new = Array(newText.precomposedStringWithCanonicalMapping)
        var ua = 0, ub = units.count
        if !delete {
            var pc = 0
            while ua < units.count {
                let t = Array(units[ua].text.precomposedStringWithCanonicalMapping)
                guard !t.isEmpty, pc + t.count <= new.count, Array(new[pc..<(pc + t.count)]) == t else { break }
                pc += t.count; ua += 1
            }
            var sc = 0
            while ub > ua {
                let t = Array(units[ub - 1].text.precomposedStringWithCanonicalMapping)
                guard !t.isEmpty, sc + t.count <= new.count - pc, Array(new[(new.count - sc - t.count)..<(new.count - sc)]) == t else { break }
                sc += t.count; ub -= 1
            }
            let middle = String(new[pc..<(new.count - sc)])
            var cuts: [(Int, Int, Int)] = []
            var host: Int?
            for u in units[ua..<ub] {
                guard let r = u.run, let g = u.glyph else { continue }
                if let k = cuts.firstIndex(where: { $0.0 == r }) { cuts[k].2 = g + 1 } else { cuts.append((r, g, g + 1)) }
                if host == nil { host = r }
            }
            if host == nil {
                // An insertion: after the glyph before it, unless a gap separates them (then before the next glyph).
                var placed = false
                if ua > 0, let r = units[ua - 1].run, let g = units[ua - 1].glyph { cuts = [(r, g + 1, g + 1)]; host = r; placed = true }
                if !placed {
                    for u in units[ua...] {
                        if let r = u.run, let g = u.glyph { cuts = [(r, g, g)]; host = r; placed = true; break }
                    }
                }
                if !placed {
                    for u in units[..<ua].reversed() {
                        if let r = u.run, let g = u.glyph { cuts = [(r, g + 1, g + 1)]; host = r; placed = true; break }
                    }
                }
                guard placed else { throw ConversionError.unsupported("\(id) can’t be edited.") }
            }
            // A cut that starts in the middle of a later run with nothing removed before it: still fine.
            return LinePlan(id: id, content: content, line: line, spacing: spacing, scope: scope, delete: false,
                            cuts: cuts.map { (run: $0.0, g0: $0.1, g1: $0.2) }, host: host, middle: middle, newText: newText)
        }
        var cuts: [(run: Int, g0: Int, g1: Int)] = []
        for r in line.runs where !content.runs[r].glyphs.isEmpty { cuts.append((r, 0, content.runs[r].glyphs.count)) }
        return LinePlan(id: id, content: content, line: line, spacing: .keep, scope: scope, delete: true, cuts: cuts, host: nil,
                        middle: "", newText: "")
    }

    private func pieces(for p: inout LinePlan) throws -> [Piece] {
        guard let host = p.host else { return [] }
        let run = p.content.runs[host]
        guard let font = p.content.font(of: run) else { throw ConversionError.unsupported("This text’s font is missing from the PDF.") }
        var encoded = font.encode(p.middle)
        if encoded.contains(where: { $0.bytes == nil }) {
            session.ensureEvidence()
            encoded = font.encode(p.middle)
        }
        var out: [Piece] = []
        for e in encoded {
            if let b = e.bytes {
                let w = e.codes.reduce(0.0) { $0 + font.advance(of: $1) }
                out.append(Piece(text: e.text, own: b, transplant: nil, width: w, codes: e.codes))
                continue
            }
            if run.renderMode >= 4 {
                throw ConversionError.unsupported("“\(e.text)” isn’t in this text’s font, and clipping text can only use characters its font already has.")
            }
            if run.fontFromGState { throw ConversionError.unsupported("“\(e.text)” isn’t in this text’s font, and this text’s font can’t be switched.") }
            if PDFTransplant.isEmoji(e.text) { throw ConversionError.unsupported("Emoji can’t be added as PDF text.") }
            let match = PDFFontMatch.installedFont(for: font)
            requests.append(PDFTransplant.Request(text: e.text, font: match.font))
            out.append(Piece(text: e.text, own: nil, transplant: requests.count - 1, width: 0, codes: []))
            let name = PDFFontMatch.displayName(match.font)
            substitutedFonts.insert(name)
            let count = e.text.count
            var subs = lineSubs[p.id] ?? []
            if let k = subs.firstIndex(where: { $0.fontName == name }) { subs[k].characters += count }
            else { subs.append(PDFFontSubstitution(characters: count, fontName: name, exact: match.exact, approximate: font.kind == .type3)) }
            lineSubs[p.id] = subs
        }
        return out
    }

    /// Fills in widths of transplanted pieces (they become one piece per scratch font).
    private func resolveTransplants(_ p: inout LinePlan) throws {
        guard let t = transplant else { return }
        var out: [Piece] = []
        for piece in p.pieces {
            guard let r = piece.transplant else { out.append(piece); continue }
            for seg in t.segments[r] {
                out.append(Piece(text: seg.text, own: nil, transplant: seg.scratchFont, width: seg.width, codes: [], foreignBytes: seg.bytes))
            }
        }
        p.pieces = out
    }

    // MARK: Emitting a line

    private func target(for content: PDFPageContent, stream si: Int, scope: PDFEditScope) -> Target {
        let s = content.streams[si]
        let page = content.page.index
        if let form = s.form {
            let users = session.formPages()[s.objectNumber]?.count ?? 1
            if scope == .thisPage && users > 1 && form.depth == 1 { return .pageCopy(object: s.objectNumber, page: page) }
            return .object(s.objectNumber)
        }
        return (contentRefCount[s.objectNumber] ?? 1) > 1 ? .pageCopy(object: s.objectNumber, page: page) : .object(s.objectNumber)
    }

    private func emit(_ p: LinePlan) throws {
        let c = p.content
        let t = target(for: c, stream: p.line.stream, scope: p.scope)
        markEdited(t, page: c.page.index, form: c.streams[p.line.stream].isForm)
        if !p.delete { expected[p.id] = p.newText }
        for cut in p.cuts {
            let run = c.runs[cut.run]
            let isHost = cut.run == p.host
            let bytes = try rewrite(run, in: c, g0: cut.g0, g1: cut.g1, pieces: isHost ? p.pieces : [],
                                    spacing: p.spacing, line: p.id, target: t, isHost: isHost)
            add(Splice(target: t, range: run.opRange, bytes: PDFEditBuilder.separated(bytes, at: run.opRange, in: c.streams[run.stream].data),
                       order: order)); order += 1
        }
        // ActualText around the run: rewrite it with the same change.
        if let host = p.host ?? p.cuts.first?.run, let at = c.runs[host].actualText {
            let oldText = PDFEditBuilder.decodeTextString(at.bytes)
            let old = p.line.text
            var newAT = p.newText
            if oldText.trimmingCharacters(in: .whitespaces) != old.trimmingCharacters(in: .whitespaces) {
                let cutText = p.cuts.map { cut in c.runs[cut.run].glyphs[cut.g0..<cut.g1].map(\.text).joined() }.joined()
                if !cutText.isEmpty, oldText.components(separatedBy: cutText).count == 2 {
                    newAT = oldText.replacingOccurrences(of: cutText, with: p.middle)
                }
            }
            let enc = PDFEditBuilder.encodeTextString(newAT)
            add(Splice(target: t, range: at.range, bytes: enc.serialized(), order: order)); order += 1
        }
    }

    /// A form edited for all pages changes every page that draws it.
    private func markEdited(_ t: Target, page: Int, form: Bool) {
        editedPages.insert(page)
        if form, case .object(let n) = t, let users = session.formPages()[n] { editedPages.formUnion(users) }
    }

    private func add(_ s: Splice) { splices.append(s) }

    /// Adds a space where the new bytes would otherwise run into the token before or after them.
    static func separated(_ bytes: [UInt8], at r: Range<Int>, in data: [UInt8]) -> [UInt8] {
        func regular(_ c: UInt8) -> Bool { !PDFLexer.isWhite(c) && !PDFLexer.isDelimiter(c) }
        let before: UInt8? = r.lowerBound > 0 ? data[r.lowerBound - 1] : nil
        let after: UInt8? = r.upperBound < data.count ? data[r.upperBound] : nil
        guard let first = bytes.first, let last = bytes.last else {
            if let b = before, let a = after, regular(b), regular(a) { return [32] }
            return []
        }
        var out = bytes
        if let b = before, regular(b), regular(first) { out.insert(32, at: 0) }
        if let a = after, regular(a), regular(last) { out.append(32) }
        return out
    }

    /// The bytes that replace one show operator.
    private func rewrite(_ run: PDFTextRun, in c: PDFPageContent, g0: Int, g1: Int, pieces: [Piece], spacing: PDFSpacing,
                         line: PDFLineID, target: Target, isHost: Bool) throws -> [UInt8] {
        let data = c.streams[run.stream].data
        let glyphs = run.glyphs
        let hex = run.elements.first { $0.value.bytes != nil }.map { data[$0.range.lowerBound] == 60 } ?? false
        enum Item { case raw([UInt8]), codes([UInt8]), number(Double) }
        var before: [Item] = [], after: [Item] = []
        let n = glyphs.count
        let startEl = g0 < n ? glyphs[g0].element : (glyphs.last?.element ?? 0)
        let startIdx = g0 < n ? glyphs[g0].index : (glyphs.last.map { $0.index + 1 } ?? 0)
        let endEl = g1 > g0 ? glyphs[g1 - 1].element : startEl
        let endIdx = g1 > g0 ? glyphs[g1 - 1].index + 1 : startIdx
        for (ei, el) in run.elements.enumerated() {
            if ei < startEl { before.append(.raw(Array(data[el.range]))); continue }
            if ei > endEl { after.append(.raw(Array(data[el.range]))); continue }
            guard el.value.bytes != nil else { continue }           // kerning inside the replaced span goes
            let codes = glyphs.filter { $0.element == ei }
            if ei == startEl {
                let head = codes.filter { $0.index < startIdx }.flatMap(\.bytes)
                if !head.isEmpty { before.append(.codes(head)) }
            }
            if ei == endEl {
                let tail = codes.filter { $0.index >= endIdx }.flatMap(\.bytes)
                if !tail.isEmpty { after.append(.codes(tail)) }
            }
        }
        // Old advance of the cut (glyphs plus any kerning between them), new advance of the pieces.
        let cutStart = g0 < n ? glyphs[g0].x0 : run.endX
        let cutEnd: Double
        if g1 > g0 { cutEnd = g1 < n ? glyphs[g1].x0 : glyphs[g1 - 1].x0 + glyphs[g1 - 1].advance } else { cutEnd = cutStart }
        let oldAdvance = cutEnd - cutStart
        let font = c.font(of: run)
        var newAdvance = 0.0
        for piece in pieces {
            if piece.own != nil, let font {
                for code in piece.codes {
                    let isSpace = !font.isComposite && code == 32
                    newAdvance += (font.advance(of: code) * run.fontSize + run.charSpacing + (isSpace ? run.wordSpacing : 0)) * run.hScale
                }
            } else {
                let count = Double(piece.text.count)
                newAdvance += (piece.width * run.fontSize * transplantScale(font) + run.charSpacing * count) * run.hScale
            }
        }
        let unit = run.fontSize * run.hScale
        var keepNumber: Double?
        if spacing == .keep && unit != 0 {
            let k = (newAdvance - oldAdvance) * 1000 / unit
            if abs(k) > 0.0005 { keepNumber = k }
        }
        var tz: Double?
        var fitTail: Double?
        if spacing == .fit && isHost, let lastVisible = glyphs.lastIndex(where: { !$0.isSpace && !$0.text.allSatisfy(\.isWhitespace) }) {
            // The visible text keeps its width (padding spaces don't count); a kerning number at the end keeps the
            // operator's total advance, so text chained after it stays where it was.
            let oldVisible = glyphs[lastVisible].x0 + glyphs[lastVisible].width
            let newVisible = g1 <= lastVisible ? oldVisible - oldAdvance + newAdvance : cutStart + newAdvance
            let newRun = run.endX - oldAdvance + newAdvance
            if newVisible > 0.0001, oldVisible > 0.0001, abs(newVisible - oldVisible) > 0.0001, unit != 0 {
                let s = min(1.3, max(0.7, oldVisible / newVisible))
                tz = run.hScale * 100 * s
                fitScales[line] = s
                let extra = run.endX - s * newRun
                if abs(extra) > 0.0001 { fitTail = -extra * 1000 / (unit * s) }
            }
        }

        // Groups: own-font items (one TJ or Tj) and transplanted strings.
        enum Group { case own([Item]), foreign(name: String, bytes: [UInt8]) }
        var groups: [Group] = []
        func appendOwn(_ i: Item) {
            if case .own(var items)? = groups.last { items.append(i); groups[groups.count - 1] = .own(items) } else { groups.append(.own([i])) }
        }
        before.forEach(appendOwn)
        for piece in pieces {
            if let b = piece.own { appendOwn(.codes(b)) }
            else if let sf = piece.transplant {
                let name = try fontResourceName(scratchFont: sf, run: run, content: c, target: target)
                groups.append(.foreign(name: name, bytes: piece.foreignBytes))
            }
        }
        if let k = keepNumber { appendOwn(.number(k)) }
        after.forEach(appendOwn)
        if let n = fitTail { appendOwn(.number(n)) }

        var out: [UInt8] = []
        func add(_ s: String) { out += Array(s.utf8) }
        if let tz { add("\(PDFNumber.format(tz)) Tz ") }
        if run.op == "'" { add("T* ") }
        if run.op == "\"", run.operands.count >= 3 {
            out += Array(data[run.operands[0].range]); add(" Tw ")
            out += Array(data[run.operands[1].range]); add(" Tc T* ")
        }
        func str(_ b: [UInt8]) -> [UInt8] { PDFValue.string(b, hex: hex).serialized() }
        var switched = false
        let sizeText = run.fontSizeText
        for (gi, g) in groups.enumerated() {
            switch g {
            case .own(let items):
                if switched { out += PDFWriterBytes.name(run.fontName); add(" \(sizeText) Tf "); switched = false }
                // Neighbouring code strings become one string.
                var merged: [Item] = []
                for i in items {
                    if case .codes(let b) = i, case .codes(let a)? = merged.last { merged[merged.count - 1] = .codes(a + b) } else { merged.append(i) }
                }
                if merged.isEmpty { continue }
                let single = merged.count == 1 && run.op != "TJ"
                if single, case .codes(let b) = merged[0] { out += str(b); add(" Tj ") }
                else if single, case .raw(let r) = merged[0] { out += r; add(" Tj ") }
                else {
                    add("[")
                    for (k, i) in merged.enumerated() {
                        if k > 0 { add(" ") }
                        switch i {
                        case .raw(let r): out += r
                        case .codes(let b): out += str(b)
                        case .number(let d): add(PDFNumber.format(d))
                        }
                    }
                    add("] TJ ")
                }
            case .foreign(let name, let bytes):
                let size = run.fontSize * transplantScale(font)
                out += PDFWriterBytes.name(name); add(" \(PDFNumber.format(size)) Tf ")
                out += PDFValue.string(bytes, hex: true).serialized(); add(" Tj ")
                switched = true
                if gi == groups.count - 1 { out += PDFWriterBytes.name(run.fontName); add(" \(sizeText) Tf "); switched = false }
            }
        }
        if let tz { _ = tz; add("\(PDFNumber.format(run.hScale * 100)) Tz ") }
        while out.last == 32 { out.removeLast() }
        return out
    }

    /// Type 3 fonts have their own glyph space: new characters are set at the size their font matrix suggests.
    private func transplantScale(_ font: PDFEditFont?) -> Double {
        guard let font, font.kind == .type3 else { return 1 }
        if let bb = font.fontBBox {
            let h = Double(bb.applying(font.fontMatrix).height)
            if h > 0.05 && h < 20 { return h }
        }
        return font.fontMatrix.a * 1000
    }

    // MARK: Resources

    /// Copies a scratch font in (once per build) and gives it a name in the resources the run's stream uses.
    private func fontResourceName(scratchFont sf: Int, run: PDFTextRun, content c: PDFPageContent, target: Target) throws -> String {
        let number = try copiedFont(sf)
        let s = c.streams[run.stream]
        let holderKey: String
        if s.form != nil { holderKey = "form:\(target)" } else { holderKey = "page:\(c.page.index)" }
        if let n = fontNames["\(holderKey)|\(number)"] { return n }
        let name: String
        if s.form != nil {
            name = mergeFontIntoForm(target: target, stream: s, content: c, font: number)
        } else {
            name = mergeFontIntoPage(c.page.index, font: number)
        }
        fontNames["\(holderKey)|\(number)"] = name
        return name
    }

    private func copiedFont(_ sf: Int) throws -> Int {
        if let n = copiedFonts[sf] { return n }
        guard let t = transplant else { throw ConversionError.toolFailed("Couldn’t prepare the replacement characters.") }
        let n = try copy(sf, from: t.scratch)
        // Quartz writes CID-keyed CFF fonts without ToUnicode: write one from Core Text's string indices.
        if var d = update.currentValue(n)?.dict, d["ToUnicode"] == nil, let pairs = t.pairs[sf], !pairs.isEmpty {
            let length = d["Subtype"]?.name == "Type0" ? 2 : 1
            let cmapNumber = update.allocate()
            update.putStream(cmapNumber, dict: PDFDict(), decoded: PDFTransplant.toUnicodeCMap(pairs, codeLength: length))
            d["ToUnicode"] = .ref(cmapNumber, 0)
            update.put(n, .dict(d), generation: 0)
        }
        copiedFonts[sf] = n
        return n
    }

    private func copy(_ n: Int, from src: PDFObjectFile) throws -> Int {
        if let m = copyMemo[n] { return m }
        let number = update.allocate()
        copyMemo[n] = number
        guard let o = src.object(n) else { update.put(number, .null, generation: 0); return number }
        func remap(_ v: PDFValue) throws -> PDFValue {
            switch v {
            case .ref(let r, _): return .ref(try copy(r, from: src), 0)
            case .array(let a): return .array(try a.map(remap))
            case .dict(let d):
                var out = PDFDict()
                for (k, x) in d.pairs where k != "Parent" { out[k] = try remap(x) }
                return .dict(out)
            default: return v
            }
        }
        let v = try remap(o.value)
        if let raw = o.stream, let d = v.dict { update.putRawStream(number, dict: d, raw: raw, generation: 0) }
        else { update.put(number, v, generation: 0) }
        return number
    }

    private func freshName(in fonts: PDFDict?, prefix: String = "DWF") -> String {
        var k = 1
        while fonts?["\(prefix)\(k)"] != nil { k += 1 }
        return "\(prefix)\(k)"
    }

    /// The page's /Font gets the new entry: a new version of the /Font object, else of the Resources object,
    /// else of the page (with inherited resources copied in).
    /// A picture as an image XObject (RGB, with a soft mask when it has transparency). Returns its object number.
    private func imageXObject(_ png: Data) throws -> (Int, Int, Int)? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0, w * h <= 16_000_000 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var rgb = [UInt8](repeating: 0, count: w * h * 3), alpha = [UInt8](repeating: 255, count: w * h)
        var transparent = false
        for i in 0..<(w * h) {
            let a = px[i * 4 + 3]
            alpha[i] = a
            if a < 255 { transparent = true }
            for k in 0..<3 {
                let c = px[i * 4 + k]
                rgb[i * 3 + k] = a == 0 ? 255 : UInt8(min(255, (Int(c) * 255 + Int(a) / 2) / Int(a)))
            }
        }
        func imageDict(_ space: String) -> PDFDict {
            PDFDict([("Type", .name("XObject")), ("Subtype", .name("Image")), ("Width", .integer(w)), ("Height", .integer(h)),
                     ("ColorSpace", .name(space)), ("BitsPerComponent", .integer(8))])
        }
        var dict = imageDict("DeviceRGB")
        if transparent {
            let mask = update.allocate()
            update.putStream(mask, dict: imageDict("DeviceGray"), decoded: alpha)
            dict["SMask"] = .ref(mask, 0)
        }
        let n = update.allocate()
        update.putStream(n, dict: dict, decoded: rgb)
        return (n, w, h)
    }

    private func mergeFontIntoPage(_ pi: Int, font number: Int) -> String {
        mergeResourceIntoPage(pi, category: "Font", number: number, prefix: "DWF")
    }

    /// The page's resource dictionary of `category` (Font, ExtGState, XObject) gets a new entry for object `number`.
    private func mergeResourceIntoPage(_ pi: Int, category: String, number: Int, prefix: String) -> String {
        let page = session.pages[pi]
        var pageDict = pendingPages[pi] ?? page.dict
        let resValue: PDFValue? = pageDict["Resources"]
        var resources = resValue.flatMap { resolveCurrent($0)?.dict } ?? page.resources
        let fontValue = resources[category]
        if let fref = fontValue?.ref?.number, var fd = pendingDicts[fref] ?? resolveCurrent(.ref(fref, 0))?.dict {
            let name = freshName(in: fd, prefix: prefix)
            fd[name] = .ref(number, 0)
            pendingDicts[fref] = fd
            return name
        }
        var fd = fontValue.flatMap { resolveCurrent($0)?.dict } ?? PDFDict()
        let name = freshName(in: fd, prefix: prefix)
        fd[name] = .ref(number, 0)
        resources[category] = .dict(fd)
        if let rref = resValue?.ref?.number {
            pendingDicts[rref] = resources
        } else {
            pageDict["Resources"] = .dict(resources)
            pendingPages[pi] = pageDict
        }
        return name
    }

    private func mergeFontIntoForm(target: Target, stream s: PDFContentStream, content c: PDFPageContent, font number: Int) -> String {
        var formDict = pendingFormDicts[target] ?? s.dict
        let resValue = formDict["Resources"]
        if case .object = target, let rref = resValue?.ref?.number {
            var res = resolveCurrent(.ref(rref, 0))?.dict ?? PDFDict()
            if let fref = res["Font"]?.ref?.number, var fd = resolveCurrent(.ref(fref, 0))?.dict {
                let name = freshName(in: fd); fd[name] = .ref(number, 0); pendingDicts[fref] = fd; return name
            }
            var fd = res["Font"].flatMap { resolveCurrent($0)?.dict } ?? PDFDict()
            let name = freshName(in: fd); fd[name] = .ref(number, 0)
            res["Font"] = .dict(fd); pendingDicts[rref] = res
            return name
        }
        var res = resValue.flatMap { resolveCurrent($0)?.dict } ?? s.resources
        if case .object = target, let fref = res["Font"]?.ref?.number, var fd = resolveCurrent(.ref(fref, 0))?.dict {
            let name = freshName(in: fd); fd[name] = .ref(number, 0); pendingDicts[fref] = fd; return name
        }
        var fd = res["Font"].flatMap { resolveCurrent($0)?.dict } ?? PDFDict()
        let name = freshName(in: fd); fd[name] = .ref(number, 0)
        res["Font"] = .dict(fd)
        formDict["Resources"] = .dict(res)
        pendingFormDicts[target] = formDict
        return name
    }

    private func resolveCurrent(_ v: PDFValue) -> PDFValue? {
        if let n = v.ref?.number {
            if let d = pendingDicts[n] { return .dict(d) }
            return file.object(n).map { file.resolve($0.value) }
        }
        return v
    }

    // MARK: Add Text

    /// q … Q around the page's own content (plus Q for any q it leaves open), then the new text in its own
    /// q … Q. Returns the appended stream's object number.
    private func emitAdds(_ list: [AddPlan], scans: [ScanPlan] = [], marks: [PDFMarkKind] = [], page pi: Int) throws -> Int {
        let t = transplant
        if t == nil && (!list.isEmpty || scans.contains { $0.request != nil }) {
            throw ConversionError.toolFailed("Couldn’t prepare the text to add.")
        }
        let page = session.pages[pi]
        let c = session.content(page: pi)
        editedPages.insert(pi)
        let angle = Double(page.rotate) * .pi / 180
        let cosA = cos(angle), sinA = sin(angle)
        func f(_ d: Double) -> String { PDFNumber.format(d) }
        var body = "\n" + String(repeating: "Q\n", count: max(0, c.unbalancedSaves) + 1)
        // Scanned lines: paper over the old words, then the new words in the closest font (page space, horizontal).
        for sp in scans where !sp.look.cover.isNull && sp.look.paper.count == 3 {
            let r = sp.look.cover, p = sp.look.paper
            body += "q \(f(p[0])) \(f(p[1])) \(f(p[2])) rg \(f(r.minX)) \(f(r.minY)) \(f(r.width)) \(f(r.height)) re f Q\n"
        }
        // Highlights: under the page's own content where there's no picture (a marker under the text: no
        // transparency, which would make Core Graphics redraw the whole page through a group); over a picture (a scan),
        // painted on top with Multiply so the words in it stay as dark as they were.
        var under = ""
        var highlights: [([CGRect], Double, Double, Double)] = []
        for m in marks {
            guard case .highlight(let rs, let r, let g, let b) = m else { continue }
            let overPicture = rs.filter { rc in c.images.contains { !$0.bounds.intersection(rc).isNull } }
            let plain = rs.filter { rc in !overPicture.contains(rc) }
            if !overPicture.isEmpty { highlights.append((overPicture, r, g, b)) }
            if !plain.isEmpty {
                under += "q \(f(r)) \(f(g)) \(f(b)) rg "
                for rc in plain { under += "\(f(rc.minX)) \(f(rc.minY)) \(f(rc.width)) \(f(rc.height)) re " }
                under += "f Q\n"
            }
        }
        if !highlights.isEmpty {
            let gs = update.allocate()
            update.put(gs, .dict(PDFDict([("Type", .name("ExtGState")), ("BM", .name("Multiply"))])))
            let gsName = mergeResourceIntoPage(pi, category: "ExtGState", number: gs, prefix: "DWGS")
            for (rects, r, g, b) in highlights {
                body += "q /\(gsName) gs \(f(r)) \(f(g)) \(f(b)) rg "
                for rc in rects { body += "\(f(rc.minX)) \(f(rc.minY)) \(f(rc.width)) \(f(rc.height)) re " }
                body += "f Q\n"
            }
        }
        for sp in scans {
            guard let req = sp.request, let t else { continue }
            let st = sp.look.style
            let segs = t.segments[req]
            let width = segs.reduce(0) { $0 + $1.width } * st.size
            var scale = 1.0
            if sp.spacing == .fit, width > 0 { scale = min(1.3, max(0.7, sp.look.inkWidth / width)) }
            if scale != 1 { fitScales[sp.id] = scale }
            body += "q BT 0 Tc 0 Tw 0 Ts \(f(st.red)) \(f(st.green)) \(f(st.blue)) rg "
            // Kept words: invisible, where the scan shows them (squeezed to end where the redrawn words start).
            if let kr = sp.keptRequest {
                let kSegs = t.segments[kr]
                let kw = kSegs.reduce(0) { $0 + $1.width } * st.size
                let room = Double(sp.look.origin.x - sp.keptOrigin.x)
                let kScale = kw > 0 && room > 0 ? min(4, max(0.25, room / kw)) : 1
                body += "3 Tr \(f(100 * kScale)) Tz 1 0 0 1 \(f(sp.keptOrigin.x)) \(f(sp.keptOrigin.y)) Tm "
                for seg in kSegs {
                    let number = try copiedFont(seg.scratchFont)
                    let key = "page:\(pi)|\(number)"
                    let name = fontNames[key] ?? mergeFontIntoPage(pi, font: number)
                    fontNames[key] = name
                    body += "/\(name) \(f(st.size)) Tf "
                    body += String(decoding: PDFValue.string(seg.bytes, hex: true).serialized(), as: UTF8.self) + " Tj "
                }
            }
            let dv = sp.direction
            let slant = st.syntheticItalic ? 0.21 : 0
            body += st.syntheticBold ? "2 Tr \(f(st.red)) \(f(st.green)) \(f(st.blue)) RG \(f(st.size * 0.035)) w " : "0 Tr "
            body += "\(f(100 * scale)) Tz \(f(dv.dx)) \(f(dv.dy)) \(f(slant * dv.dx - dv.dy)) \(f(slant * dv.dy + dv.dx)) \(f(sp.look.origin.x)) \(f(sp.look.origin.y)) Tm "
            for seg in segs {
                let number = try copiedFont(seg.scratchFont)
                let key = "page:\(pi)|\(number)"
                let name = fontNames[key] ?? mergeFontIntoPage(pi, font: number)
                fontNames[key] = name
                body += "/\(name) \(f(st.size)) Tf "
                body += String(decoding: PDFValue.string(seg.bytes, hex: true).serialized(), as: UTF8.self) + " Tj "
            }
            body += "ET Q\n"
        }
        for a in list {
            let st = a.style
            let slant = st.syntheticItalic ? 0.21 : 0
            body += "q BT 0 Tc 0 Tw 100 Tz 0 Ts \(st.syntheticBold ? 2 : 0) Tr \(f(st.red)) \(f(st.green)) \(f(st.blue)) rg "
            if st.syntheticBold { body += "\(f(st.red)) \(f(st.green)) \(f(st.blue)) RG \(f(st.size * 0.035)) w " }
            body += "\(f(cosA)) \(f(sinA)) \(f(slant * cosA - sinA)) \(f(slant * sinA + cosA)) \(f(a.origin.x)) \(f(a.origin.y)) Tm "
            var subs: [PDFFontSubstitution] = []
            guard let t else { continue }
            for seg in t.segments[a.request] {
                let number = try copiedFont(seg.scratchFont)
                let key = "page:\(pi)|\(number)"
                let name = fontNames[key] ?? mergeFontIntoPage(pi, font: number)
                fontNames[key] = name
                body += "/\(name) \(f(st.size)) Tf "
                body += String(decoding: PDFValue.string(seg.bytes, hex: true).serialized(), as: UTF8.self) + " Tj "
                let fontName = t.fonts.font(key: "#\(seg.scratchFont)").map { PDFEditFont.displayName($0.plainName) } ?? st.fontName
                if fontName != PDFEditFont.displayName(st.fontName), let k = subs.firstIndex(where: { $0.fontName == fontName }) {
                    subs[k].characters += seg.text.count
                } else if fontName != PDFEditFont.displayName(st.fontName) {
                    subs.append(PDFFontSubstitution(characters: seg.text.count, fontName: fontName, exact: true, approximate: false))
                }
            }
            body += "ET Q\n"
            addSubs[a.id] = subs
        }
        // Pictures last, on top of everything, upright for the reader.
        for m in marks {
            guard case .image(let png, let rect) = m else { continue }
            guard let (img, w, h) = try imageXObject(png) else { throw ConversionError.unsupported("That picture can’t be read.") }
            let name = mergeResourceIntoPage(pi, category: "XObject", number: img, prefix: "DWIm")
            // Unit square → the rectangle, turned with the page so the picture reads upright.
            let upright = page.rotate % 180 == 0 ? CGSize(width: rect.width, height: rect.height) : CGSize(width: rect.height, height: rect.width)
            _ = (w, h)
            let u = CGVector(dx: cosA * upright.width, dy: sinA * upright.width)
            let v = CGVector(dx: -sinA * upright.height, dy: cosA * upright.height)
            let ox = rect.minX - min(0, u.dx) - min(0, v.dx), oy = rect.minY - min(0, u.dy) - min(0, v.dy)
            body += "q \(f(u.dx)) \(f(u.dy)) \(f(v.dx)) \(f(v.dy)) \(f(ox)) \(f(oy)) cm /\(name) Do Q\n"
        }
        let open = update.allocate(), close = update.allocate()
        update.putStream(open, dict: PDFDict(), decoded: Array((under + "q\n").utf8))
        update.putStream(close, dict: PDFDict(), decoded: Array(body.utf8))
        var pageDict = pendingPages[pi] ?? page.dict
        let existing: [PDFValue]
        switch pageDict["Contents"] {
        case .array(let a)?: existing = a
        case .ref(let n, let g)?:
            if let arr = file.object(n)?.value.array { existing = arr } else { existing = [.ref(n, g)] }
        default: existing = []
        }
        pageDict["Contents"] = .array([.ref(open, 0)] + existing + [.ref(close, 0)])
        pendingPages[pi] = pageDict
        return close
    }

    // MARK: Writing

    private func groupedSplices() -> [Target: [Splice]] {
        var by: [Target: [Splice]] = [:]
        for s in splices { by[s.target, default: []].append(s) }
        for (t, list) in by {
            // The same operator edited twice (a form drawn twice on a page): the later edit wins.
            var latest: [Range<Int>: Splice] = [:]
            for s in list { if let o = latest[s.range], o.order > s.order { continue }; latest[s.range] = s }
            by[t] = latest.values.sorted { $0.range.lowerBound < $1.range.lowerBound }
        }
        return by
    }

    /// New data for every edited stream; copies where the stream is shared and the edit is for one page.
    private func writeTargets() throws -> [Int: [Int: Int]] {
        var renames: [Int: [Int: Int]] = [:]
        let grouped = groupedSplices()
        var targets = Set(grouped.keys)
        targets.formUnion(pendingFormDicts.keys)
        for t in targets.sorted(by: { "\($0)" < "\($1)" }) {
            let list = grouped[t] ?? []
            guard let (data, dict) = sourceData(t) else { continue }
            var d = data
            for s in list.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) where s.range.upperBound <= d.count {
                d.replaceSubrange(s.range, with: s.bytes)
            }
            var streamDict = pendingFormDicts[t] ?? dict
            switch t {
            case .object(let n):
                update.putStream(n, dict: streamDict, decoded: d)
            case .pageCopy(let n, let pi):
                let copy = update.allocate()
                if streamDict["Resources"] == nil, isForm(n) {
                    // A copied form keeps the resources it was drawn with.
                    streamDict["Resources"] = .dict(formResources(n, page: pi))
                }
                update.putStream(copy, dict: streamDict, decoded: d, generation: 0)
                renames[pi, default: [:]][n] = copy
                try repoint(page: pi, from: n, to: copy)
            }
        }
        return renames
    }

    private func isForm(_ n: Int) -> Bool { file.object(n)?.value.dict?["Subtype"]?.name == "Form" }

    private func formResources(_ n: Int, page pi: Int) -> PDFDict {
        let c = session.content(page: pi)
        return c.streams.first { $0.objectNumber == n }?.resources ?? PDFDict()
    }

    private func sourceData(_ t: Target) -> ([UInt8], PDFDict)? {
        var candidates: [Int] = []
        switch t {
        case .pageCopy(_, let p): candidates = [p]
        case .object(let n):
            candidates = session.pages.filter { $0.contents.contains(n) }.map(\.index)
            if candidates.isEmpty { candidates = (session.formPages()[n] ?? []).sorted() }
        }
        for pi in candidates {
            if let s = session.content(page: pi).streams.first(where: { $0.objectNumber == t.object }) { return (s.data, s.dict) }
        }
        return nil
    }

    /// Points the page at its own copy of a content stream or a form.
    private func repoint(page pi: Int, from n: Int, to copy: Int) throws {
        let page = session.pages[pi]
        var pageDict = pendingPages[pi] ?? page.dict
        if page.contents.contains(n) {
            var list: [PDFValue]
            switch pageDict["Contents"] {
            case .array(let a)?: list = a
            case .ref(let cn, let g)?: list = file.object(cn)?.value.array ?? [.ref(cn, g)]
            default: list = []
            }
            list = list.map { $0.ref?.number == n ? .ref(copy, 0) : $0 }
            pageDict["Contents"] = list.count == 1 ? list[0] : .array(list)
            pendingPages[pi] = pageDict
            return
        }
        // A form drawn from the page: the page gets its own resources with the XObject entry renamed.
        var res = pageDict["Resources"].flatMap { resolveCurrent($0)?.dict } ?? page.resources
        var xo = res["XObject"].flatMap { resolveCurrent($0)?.dict } ?? PDFDict()
        for k in xo.keys where xo[k]?.ref?.number == n { xo[k] = .ref(copy, 0) }
        res["XObject"] = .dict(xo)
        pageDict["Resources"] = .dict(res)
        pendingPages[pi] = pageDict
    }

    // MARK: Text strings

    static func decodeTextString(_ b: [UInt8]) -> String {
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF {
            var u: [UInt16] = []
            var i = 2
            while i + 1 < b.count { u.append(UInt16(b[i]) << 8 | UInt16(b[i + 1])); i += 2 }
            return String(decoding: u, as: UTF16.self)
        }
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { return String(decoding: b.dropFirst(3), as: UTF8.self) }
        return String(bytes: b, encoding: .isoLatin1) ?? ""
    }

    static func encodeTextString(_ s: String) -> PDFValue {
        if s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) { return .string(Array(s.utf8), hex: false) }
        var b: [UInt8] = [0xFE, 0xFF]
        for u in s.utf16 { b += [UInt8(u >> 8), UInt8(u & 0xFF)] }
        return .string(b, hex: true)
    }
}

// MARK: - Reading the candidate back

/// The candidate re-read: where each edited line and added text is now, how much it overflows, and the areas
/// and glyphs the gate checks.
final class PDFEditAnalysis {
    struct LineState {
        var quad: [CGPoint]
        var overflow: Double
    }

    private(set) var lines: [PDFLineID: LineState] = [:]
    private(set) var addedQuads: [UUID: [CGPoint]] = [:]
    /// Per page: old ∪ new areas that may change.
    private(set) var dirty: [Int: [CGRect]] = [:]
    /// Per page: new visible glyphs that must have ink.
    private(set) var newGlyphs: [Int: [CGRect]] = [:]
    private(set) var candidateFile: PDFObjectFile?

    init(session: PDFEditSession, build: PDFEditBuild) {
        guard !build.written.isEmpty, let cf = try? PDFObjectFile(build.data) else { return }
        candidateFile = cf
        let cfonts = PDFEditFontCache(cf)
        let cpages = cf.pages()
        guard cpages.count == session.pages.count else { return }
        for pi in build.editedPages.sorted() {
            let orig = session.content(page: pi)
            let cand = PDFPageContent(file: cf, page: cpages[pi], fonts: cfonts)
            analyze(page: pi, orig: orig, cand: cand, build: build, session: session)
        }
    }

    private func analyze(page pi: Int, orig: PDFPageContent, cand: PDFPageContent, build: PDFEditBuild, session: PDFEditSession) {
        let renames = build.renames[pi] ?? [:]
        // Splices that apply to this page, per original object.
        var splicesFor: [Int: [(range: Range<Int>, length: Int)]] = [:]
        for (t, list) in build.splices {
            switch t {
            case .object(let n): splicesFor[n] = list
            case .pageCopy(let n, let p) where p == pi: splicesFor[n] = list
            default: break
            }
        }
        // Candidate runs by (object, start) and occurrence.
        var candRuns: [String: [PDFTextRun]] = [:]
        for r in cand.runs { candRuns["\(cand.streams[r.stream].objectNumber)@\(r.opRange.lowerBound)", default: []].append(r) }
        var candByObject: [Int: [PDFTextRun]] = [:]
        for r in cand.runs { candByObject[cand.streams[r.stream].objectNumber, default: []].append(r) }

        func newPosition(_ obj: Int, _ x: Int) -> Int {
            var shift = 0
            for s in splicesFor[obj] ?? [] where s.range.upperBound <= x { shift += s.length - s.range.count }
            return x + shift
        }
        func spliceContaining(_ obj: Int, _ r: Range<Int>) -> Range<Int>? {
            for s in splicesFor[obj] ?? [] where s.range.lowerBound <= r.lowerBound && r.upperBound <= s.range.upperBound {
                let start = newPosition(obj, s.range.lowerBound)
                return start..<(start + s.length)
            }
            return nil
        }
        var dirtyRects: [CGRect] = []
        var glyphRects: [CGRect] = []
        var mapped: [Int: [PDFTextRun]] = [:]
        var overlayRuns: [PDFLineID: [PDFTextRun]] = [:]
        var occurrence: [String: Int] = [:]
        for r in orig.runs {
            let obj = orig.streams[r.stream].objectNumber
            let newObj = renames[obj] ?? obj
            let k = "\(obj)@\(r.opRange.lowerBound)"
            let occ = occurrence[k, default: 0]
            occurrence[k] = occ + 1
            if let sr = spliceContaining(obj, r.opRange) {
                let news = (candByObject[newObj] ?? []).filter { $0.opRange.lowerBound >= sr.lowerBound && $0.opRange.upperBound <= sr.upperBound + 0 }
                mapped[r.index] = news
                dirtyRects.append(PDFEditAnalysis.generous(orig, r))
                for n in news {
                    dirtyRects.append(PDFEditAnalysis.generous(cand, n))
                    if n.renderMode != 3 && n.renderMode != 7 {
                        for (gi, g) in n.glyphs.enumerated() where !g.isSpace && !g.text.allSatisfy(\.isWhitespace) && g.width > 0 {
                            glyphRects.append(PDFEditGeometry.bounds(cand.quad(n, from: gi, to: gi + 1)))
                        }
                    }
                }
            } else {
                let start = newPosition(obj, r.opRange.lowerBound)
                let list = candRuns["\(newObj)@\(start)"] ?? []
                let n = occ < list.count ? list[occ] : list.first
                mapped[r.index] = n.map { [$0] } ?? []
                if let n, !PDFEditAnalysis.samePlace(r, n) {
                    dirtyRects.append(PDFEditAnalysis.generous(orig, r))
                    dirtyRects.append(PDFEditAnalysis.generous(cand, n))
                }
            }
        }
        // Added text: everything drawn by the appended stream.
        if let close = build.addedStreams[pi] {
            let added = cand.runs.filter { cand.streams[$0.stream].objectNumber == close }
            for n in added {
                dirtyRects.append(PDFEditAnalysis.generous(cand, n))
                if n.renderMode == 3 || n.renderMode == 7 { continue }
                for (gi, g) in n.glyphs.enumerated() where !g.text.allSatisfy(\.isWhitespace) && g.width > 0 {
                    glyphRects.append(PDFEditGeometry.bounds(cand.quad(n, from: gi, to: gi + 1)))
                }
            }
            // One text object per scanned line's new text, then one per added text, in edit order.
            let scanIDs = build.scanLinesByPage[pi] ?? []
            let ids = build.addIDsByPage[pi] ?? []
            var byObject: [Int: [PDFTextRun]] = [:]
            for n in added { byObject[n.textObject, default: []].append(n) }
            for (k, key) in byObject.keys.sorted().enumerated() {
                if k < scanIDs.count { overlayRuns[scanIDs[k]] = byObject[key]!; continue }
                guard k - scanIDs.count < ids.count else { break }
                let pts = byObject[key]!.flatMap { cand.quad($0) }
                addedQuads[ids[k - scanIDs.count]] = PDFEditAnalysis.boxQuad(pts, direction: byObject[key]!.first.map { PDFEditAnalysis.direction($0) } ?? CGVector(dx: 1, dy: 0))
            }
        }
        dirtyRects += build.scanCovers[pi] ?? []
        dirty[pi] = dirtyRects.filter { !$0.isNull }
        newGlyphs[pi] = glyphRects.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }

        // Lines of this page that were edited.
        let crop = cand.page.cropBox
        for e in session.edits where e.line?.page == pi {
            guard let id = e.line, let line = session.line(id) else { continue }
            var pts: [CGPoint] = []
            var spans: [(Double, Double)] = []
            let dir = line.direction
            func along(_ p: CGPoint) -> Double { p.x * dir.dx + p.y * dir.dy }
            for n in overlayRuns[id] ?? line.runs.flatMap({ mapped[$0] ?? [] }) {
                do {
                    guard let lastVisible = n.glyphs.lastIndex(where: { !$0.isSpace && !$0.text.allSatisfy(\.isWhitespace) }) else { continue }
                    pts += cand.quad(n, from: 0, to: lastVisible + 1)
                    for (gi, g) in n.glyphs.enumerated() where !g.isSpace && !g.text.allSatisfy(\.isWhitespace) {
                        let q = cand.quad(n, from: gi, to: gi + 1)
                        if q.count == 4 { spans.append((along(q[0]), along(q[1]))) }
                    }
                }
            }
            let quad = pts.isEmpty ? [] : PDFEditAnalysis.boxQuad(pts, direction: dir)
            // Room: up to the next text on the same baseline, or the crop box edge, never less than the line had.
            var limit = Double.infinity
            let corners = [CGPoint(x: crop.minX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.maxY), CGPoint(x: crop.minX, y: crop.maxY)]
            limit = corners.map(along).max() ?? limit
            let lineStart = along(line.quad[0]), lineEnd = along(line.quad[1])
            for other in orig.lines where other.index != line.index {
                let sameBaseline = abs(other.direction.dx * dir.dx + other.direction.dy * dir.dy) > 0.999
                    && abs((other.origin.x - line.origin.x) * -dir.dy + (other.origin.y - line.origin.y) * dir.dx) < 0.35 * line.pointSize
                let s = along(other.quad[0])
                if sameBaseline && s > lineStart + 0.5 { limit = min(limit, s) }
            }
            limit = max(limit, lineEnd)
            let newEnd = spans.map(\.1).max() ?? lineStart
            var overflow = max(0, newEnd - limit)
            // Glyphs that now overlap the next glyph (Keep Position with longer text).
            let sorted = spans.sorted { $0.0 < $1.0 }
            var overlap = 0.0
            for k in 1..<max(1, sorted.count) { overlap = max(overlap, sorted[k - 1].1 - sorted[k].0) }
            var origOverlap = 0.0
            let ospans = line.runs.flatMap { ri -> [(Double, Double)] in
                let r = orig.runs[ri]
                return r.glyphs.indices.filter { !r.glyphs[$0].isSpace && !r.glyphs[$0].text.allSatisfy(\.isWhitespace) }.compactMap {
                    let q = orig.quad(r, from: $0, to: $0 + 1)
                    return q.count == 4 ? (along(q[0]), along(q[1])) : nil
                }
            }.sorted { $0.0 < $1.0 }
            for k in 1..<max(1, ospans.count) { origOverlap = max(origOverlap, ospans[k - 1].1 - ospans[k].0) }
            if overlap - origOverlap > 0.25 { overflow = max(overflow, overlap - origOverlap) }
            lines[id] = LineState(quad: quad, overflow: overflow)
        }
    }

    static func direction(_ r: PDFTextRun) -> CGVector {
        let m = r.trm
        let len = max(1e-9, hypot(m.a, m.b))
        return CGVector(dx: m.a / len, dy: m.b / len)
    }

    /// The run's whole box with room for any glyph of its size (the gate allows changes inside it).
    static func generous(_ c: PDFPageContent, _ r: PDFTextRun) -> CGRect {
        let f = c.font(of: r)
        let lo = r.rise + min(f?.descent ?? -0.3, -0.35) * r.fontSize, hi = r.rise + max(f?.ascent ?? 1, 1.05) * r.fontSize
        let x1 = max(r.endX, (r.glyphs.last.map { $0.x0 + $0.width } ?? 0))
        let pts = PDFTextRun.corners(x0: min(0, r.glyphs.first?.x0 ?? 0) - abs(r.fontSize) * 0.1, x1: x1 + abs(r.fontSize) * 0.1, lo: lo, hi: hi, m: r.trm)
        return PDFEditGeometry.bounds(pts)
    }

    static func samePlace(_ a: PDFTextRun, _ b: PDFTextRun) -> Bool {
        let m1 = a.trm, m2 = b.trm
        func close(_ x: CGFloat, _ y: CGFloat) -> Bool { abs(x - y) < 0.001 }
        guard close(m1.a, m2.a), close(m1.b, m2.b), close(m1.c, m2.c), close(m1.d, m2.d), close(m1.tx, m2.tx), close(m1.ty, m2.ty),
              a.glyphs.count == b.glyphs.count else { return false }
        return zip(a.glyphs, b.glyphs).allSatisfy { abs($0.x0 - $1.x0) < 0.001 && $0.code == $1.code }
    }

    /// The smallest box along `direction` around the points.
    static func boxQuad(_ pts: [CGPoint], direction d: CGVector) -> [CGPoint] {
        guard !pts.isEmpty else { return [] }
        let up = CGVector(dx: -d.dy, dy: d.dx)
        let s = pts.map { $0.x * d.dx + $0.y * d.dy }, h = pts.map { $0.x * up.dx + $0.y * up.dy }
        let s0 = s.min()!, s1 = s.max()!, h0 = h.min()!, h1 = h.max()!
        func p(_ a: Double, _ b: Double) -> CGPoint { CGPoint(x: d.dx * a + up.dx * b, y: d.dy * a + up.dy * b) }
        return [p(s0, h0), p(s1, h0), p(s1, h1), p(s0, h1)]
    }
}
