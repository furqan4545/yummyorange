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

/// One entry of the edit list.
enum PDFEdit: Equatable {
    case text(line: PDFLineID, text: String, spacing: PDFSpacing, scope: PDFEditScope)
    case delete(line: PDFLineID, scope: PDFEditScope)
    case add(id: UUID, page: Int, origin: CGPoint, text: String, style: PDFTextStyle)

    var line: PDFLineID? {
        switch self {
        case .text(let l, _, _, _), .delete(let l, _): return l
        case .add: return nil
        }
    }
    var addID: UUID? { if case .add(let id, _, _, _, _) = self { return id }; return nil }
    var page: Int {
        switch self {
        case .text(let l, _, _, _), .delete(let l, _): return l.page
        case .add(_, let p, _, _, _): return p
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
    /// Text used as a clipping path: only characters its font already has can be typed.
    case clippingText
    /// A Type 3 font: new characters come from a font on this Mac at an approximate size.
    case drawnGlyphs
    /// Not a multiple of 90°: edit it in a popover.
    case rotated(Double)

    var message: String {
        switch self {
        case .hiddenText: return "Hidden OCR text. Edits change only the searchable text."
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
        case .ocrOnly: return "This page is a scanned image with recognized text. Edits change only the hidden, searchable text."
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
        if l.hidden { n.append(.hiddenText) }
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
        case .add: return
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
        switch e {
        case .text(_, let t, _, _)?: text = t
        case .delete?: text = ""; deleted = true
        default: break
        }
        return PDFLineInfo(id: id, originalText: l.text, text: text, isEdited: e != nil, isDeleted: deleted,
                           quad: st?.quad ?? l.quad, originalQuad: l.quad, origin: l.origin, direction: l.direction, angle: l.angle,
                           pointSize: l.pointSize, color: PDFEditSession.color(firstRun?.fill ?? [0]), availability: availability(id),
                           notes: notes(id), fontDescription: font?.sourceDescription ?? "Unknown font",
                           substitutions: build?.lineSubstitutions[id] ?? [], spacing: e?.spacingValue ?? .flow,
                           scope: e?.scopeValue ?? .thisPage, sharedPages: sharedPages(id), overflow: st?.overflow ?? 0,
                           fitScale: build?.fitScales[id] ?? 1)
    }

    /// The font the inline editor types in, sized in page points (multiply by the zoom).
    func editorFont(_ id: PDFLineID) -> (font: NSFont, source: PDFEditorFontSource) {
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
        case .text(_, _, _, let s), .delete(_, let s): return s
        case .add: return nil
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
        for e in edits {
            switch e {
            case .text(let id, let text, let spacing, let scope):
                plans.append(try plan(id, newText: text, spacing: spacing, scope: scope, delete: false))
            case .delete(let id, let scope):
                plans.append(try plan(id, newText: "", spacing: .keep, scope: scope, delete: true))
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
        var addedStreams: [Int: Int] = [:]
        var addIDs: [Int: [UUID]] = [:]
        for page in Set(adds.map(\.page)).sorted() {
            let list = adds.filter { $0.page == page }
            addedStreams[page] = try emitAdds(list, page: page)
            addIDs[page] = list.map(\.id)
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
                            fitScales: fitScales, expectedText: expected, addedStreams: addedStreams, addIDsByPage: addIDs)
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

    private func freshName(in fonts: PDFDict?) -> String {
        var k = 1
        while fonts?[ "DWF\(k)"] != nil { k += 1 }
        return "DWF\(k)"
    }

    /// The page's /Font gets the new entry: a new version of the /Font object, else of the Resources object,
    /// else of the page (with inherited resources copied in).
    private func mergeFontIntoPage(_ pi: Int, font number: Int) -> String {
        let page = session.pages[pi]
        var pageDict = pendingPages[pi] ?? page.dict
        let resValue: PDFValue? = pageDict["Resources"]
        var resources = resValue.flatMap { resolveCurrent($0)?.dict } ?? page.resources
        let fontValue = resources["Font"]
        if let fref = fontValue?.ref?.number, var fd = resolveCurrent(.ref(fref, 0))?.dict {
            let name = freshName(in: fd)
            fd[name] = .ref(number, 0)
            pendingDicts[fref] = fd
            return name
        }
        var fd = fontValue.flatMap { resolveCurrent($0)?.dict } ?? PDFDict()
        let name = freshName(in: fd)
        fd[name] = .ref(number, 0)
        resources["Font"] = .dict(fd)
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
    private func emitAdds(_ list: [AddPlan], page pi: Int) throws -> Int {
        guard let t = transplant else { throw ConversionError.toolFailed("Couldn’t prepare the text to add.") }
        let page = session.pages[pi]
        let c = session.content(page: pi)
        editedPages.insert(pi)
        let angle = Double(page.rotate) * .pi / 180
        let cosA = cos(angle), sinA = sin(angle)
        func f(_ d: Double) -> String { PDFNumber.format(d) }
        var body = "\n" + String(repeating: "Q\n", count: max(0, c.unbalancedSaves) + 1)
        for a in list {
            let st = a.style
            body += "q BT 0 Tc 0 Tw 100 Tz 0 Ts 0 Tr \(f(st.red)) \(f(st.green)) \(f(st.blue)) rg "
            body += "\(f(cosA)) \(f(sinA)) \(f(-sinA)) \(f(cosA)) \(f(a.origin.x)) \(f(a.origin.y)) Tm "
            var subs: [PDFFontSubstitution] = []
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
        let open = update.allocate(), close = update.allocate()
        update.putStream(open, dict: PDFDict(), decoded: Array("q\n".utf8))
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
                for (gi, g) in n.glyphs.enumerated() where !g.text.allSatisfy(\.isWhitespace) && g.width > 0 {
                    glyphRects.append(PDFEditGeometry.bounds(cand.quad(n, from: gi, to: gi + 1)))
                }
            }
            // One text object per added text, in edit order.
            let ids = build.addIDsByPage[pi] ?? []
            var byObject: [Int: [PDFTextRun]] = [:]
            for n in added { byObject[n.textObject, default: []].append(n) }
            for (k, key) in byObject.keys.sorted().enumerated() where k < ids.count {
                let pts = byObject[key]!.flatMap { cand.quad($0) }
                addedQuads[ids[k]] = PDFEditAnalysis.boxQuad(pts, direction: byObject[key]!.first.map { PDFEditAnalysis.direction($0) } ?? CGVector(dx: 1, dy: 0))
            }
        }
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
            for ri in line.runs {
                for n in mapped[ri] ?? [] {
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
