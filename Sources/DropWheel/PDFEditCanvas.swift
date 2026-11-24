import AppKit
import PDFKit

/// A line or an added text box: what the Edit PDF canvas selects, hovers and edits.
enum PDFEditTarget: Hashable {
    case line(PDFLineID)
    case added(UUID)
}

/// What the canvas tells its window.
protocol PDFEditCanvasDelegate: AnyObject {
    func canvasSelectionChanged(_ canvas: PDFEditCanvas)
    func canvasPageChanged(_ canvas: PDFEditCanvas)
    func canvasZoomChanged(_ canvas: PDFEditCanvas)
    /// The inline editor's text changed (typing, typing undo, Esc putting it back): not yet a change to the session.
    func canvasTypingChanged(_ canvas: PDFEditCanvas)
    /// Runs one change as its own named undo step. A refusal is shown as a sheet titled `failure`; returns false then.
    func canvas(_ canvas: PDFEditCanvas, perform failure: String, _ body: () throws -> Void) -> Bool
}

/// Colours drawn on the paper. A PDF page is white paper in both appearances, so marks on it resolve in the light
/// appearance (a dark-mode accent or orange is too pale on white).
enum PDFEditPaint {
    static let paperAppearance = NSAppearance(named: .aqua)!

    static func onPaper(_ color: NSColor) -> NSColor {
        var out = color
        paperAppearance.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) ?? color }
        return out
    }

    /// Hover and selection: the system accent.
    static var accent: NSColor { onPaper(.controlAccentColor) }
    /// Text that runs past its room. #C27000 on white is 3.4:1 (a 2 pt outline plus an icon, never colour alone).
    static let amber = NSColor(srgbRed: 0.76, green: 0.44, blue: 0.0, alpha: 1)
    /// Text that can't be edited.
    static let readOnly = NSColor(white: 0.5, alpha: 1)
    /// The app accent (dahlia) marks your edits: the change bar beside an edited line and the sidebar dot.
    static var changeBar: NSColor { DWPalette.accent }
}

/// The page of the Edit PDF window: the candidate document drawn as vectors (the bytes Save writes), hover outlines,
/// the I-beam, click-to-edit with an inline text view in the line's own font, size and colour, overflow warnings,
/// Add Text boxes, the undo outline, and one accessibility element per line.
///
/// Coordinates: page space (the PDF's unrotated user space) → upright space (crop box at the origin, /Rotate
/// applied; `PDFEditGeometry.uprightTransform`) → view space (flipped, zoomed, the page centred with a margin).
final class PDFEditCanvas: NSView, NSTextViewDelegate, NSViewToolTipOwner {
    enum Mode { case editText, addText }

    /// The inline editor while a line or a text box is being typed in.
    final class Editor {
        enum Target: Equatable {
            case line(PDFLineID)
            case added(UUID)
            /// A new text box (Add Text) whose baseline starts at `origin` (page space).
            case new(page: Int, origin: CGPoint)
        }

        let target: Target
        let host = PDFEditEditorHost()
        let textView: PDFEditTextView
        /// The text when editing began, without trailing padding (Esc goes back to it).
        let startText: String
        /// Spaces some PDFs pad a line with: kept out of the editor (they'd stretch it past the visible text) and put
        /// back on commit, so only what you typed changes.
        let padding: String
        /// Typing has its own undo stack; ⌘Z walks it before it undoes committed changes.
        let typingUndo = UndoManager()
        /// Baseline start, page space.
        let origin: CGPoint
        /// Font at 100 % (page points).
        let font: NSFont
        /// Degrees, clockwise on screen (0, 90, 180 or 270).
        let screenAngle: CGFloat
        /// The original line's length in page points (the editor is at least this wide).
        let minLength: CGFloat
        /// Where the first baseline sits in the text view (view points, from its top), as laid out.
        var baseline: CGFloat = 0

        init(target: Target, text: String, origin: CGPoint, font: NSFont, color: NSColor, screenAngle: CGFloat, minLength: CGFloat) {
            self.target = target
            let visible = String(text.reversed().drop(while: { $0 == " " }).reversed())
            startText = visible
            padding = String(text.dropFirst(visible.count))
            self.origin = origin
            self.font = font
            self.screenAngle = screenAngle
            self.minLength = minLength
            textView = PDFEditTextView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
            textView.configure(color: color)
            textView.string = startText
            host.addSubview(textView)
        }

        var lineID: PDFLineID? { if case .line(let id) = target { return id }; return nil }
        var addedID: UUID? { if case .added(let id) = target { return id }; return nil }
        var isNew: Bool { if case .new = target { return true }; return false }
    }

    let session: PDFEditSession
    weak var delegate: PDFEditCanvasDelegate?
    static let margin: CGFloat = 32

    private(set) var page = 0
    private(set) var zoom: CGFloat = 1
    var mode: Mode = .editText { didSet { if mode != oldValue { modeChanged() } } }
    private(set) var selection: PDFEditTarget?
    private(set) var hovered: PDFEditTarget?
    /// A scanned image under the pointer (Edit Text mode, no text there).
    private(set) var hoveredImage: Int?
    private(set) var editor: Editor?
    /// The style new text boxes get (the inspector's Add Text section).
    var addStyle = PDFTextStyle()
    /// All Pages / Only This Page chosen in the shared-text banner before the line was changed.
    var pendingScope: [PDFLineID: PDFEditScope] = [:]
    /// The 0.6 s outline after an undo or redo (exposed for the self-test).
    private(set) var flashView: PDFEditFlashView?
    /// The last outline faded out (false with Reduce Motion on).
    private(set) var flashFades = false
    private(set) var callout: PDFEditOverflowCallout?
    private(set) var anglePopover: NSPopover?
    /// Reduce Motion, overridable by the self-test.
    static var reduceMotionOverride: Bool?
    var reduceMotion: Bool { Self.reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The document being drawn; held strongly (a page whose document is gone draws nothing).
    private var document: PDFDocument
    private(set) var pageFrame: CGRect = .zero
    private var editedInfos: [PDFLineID: PDFLineInfo] = [:]
    private var addedOnPage: [PDFAddedText] = []
    private var availability: [PDFLineID: PDFLineAvailability] = [:]
    private var drag: (id: UUID, start: CGPoint, origin: CGPoint, moved: Bool, offset: CGVector)?
    private var elements: [PDFEditLineElement]?
    /// Each line's own band (see `band(_:)`), worked out once: lines and their fonts don't change.
    private var bands: [PDFLineID: Band] = [:]

    init(session: PDFEditSession) {
        self.session = session
        document = session.candidateDocument
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        reloadPageState()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// A click that only brings the window forward doesn't also start editing a line.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    // MARK: Geometry

    var pageInfo: PDFObjectFile.Page { session.pages[page] }

    /// The page as shown (rotation applied), in points at 100 %.
    var uprightSize: CGSize {
        let c = pageInfo.cropBox
        return pageInfo.rotate % 180 == 0 ? c.size : CGSize(width: c.height, height: c.width)
    }

    var uprightToView: CGAffineTransform {
        CGAffineTransform(a: zoom, b: 0, c: 0, d: -zoom, tx: pageFrame.minX, ty: pageFrame.maxY)
    }

    var pageToView: CGAffineTransform {
        PDFEditGeometry.uprightTransform(crop: pageInfo.cropBox, rotate: pageInfo.rotate).concatenating(uprightToView)
    }

    func viewPoint(_ p: CGPoint) -> CGPoint { p.applying(pageToView) }
    func pagePoint(_ v: CGPoint) -> CGPoint { v.applying(pageToView.inverted()) }

    /// Sizes the view for the zoom and the visible area, centres the page and moves the overlays with it.
    func updateLayout() {
        let clip = enclosingScrollView?.contentSize ?? bounds.size
        let w = uprightSize.width * zoom, h = uprightSize.height * zoom
        let size = CGSize(width: max(clip.width, (w + 2 * Self.margin).rounded(.up)), height: max(clip.height, (h + 2 * Self.margin).rounded(.up)))
        if frame.size != size { setFrameSize(size) }
        let newFrame = CGRect(x: ((size.width - w) / 2).rounded(), y: ((size.height - h) / 2).rounded(), width: w, height: h)
        // The undo outline is in view space: it stays through ordinary layout passes, and goes when the page moves.
        if newFrame != pageFrame { flashView?.removeFromSuperview(); flashView = nil }
        pageFrame = newFrame
        layoutEditor()
        layoutCallout()
        elements = nil
        rebuildToolTips()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        updateLayout()
    }

    /// The zoom that fits the page's width in the visible area (at most 150 %; below 25 % only for oversized pages).
    var fitWidthZoom: CGFloat {
        let clip = enclosingScrollView?.contentSize ?? bounds.size
        return min(1.5, max(minZoom, (clip.width - 2 * Self.margin) / max(1, uprightSize.width)))
    }

    /// 25 %, or less for a page so big that 25 % doesn't fit it.
    var minZoom: CGFloat {
        let clip = enclosingScrollView?.contentSize ?? bounds.size
        let fit = min((clip.width - 2 * Self.margin) / max(1, uprightSize.width), (clip.height - 2 * Self.margin) / max(1, uprightSize.height))
        return max(0.02, min(0.25, fit))
    }

    static let zoomSteps: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4]

    /// Zooms around `anchor` (view space; the visible centre by default), keeping the page point under it in place.
    func setZoom(_ value: CGFloat, anchor: CGPoint? = nil) {
        let z = min(4, max(minZoom, value))
        guard abs(z - zoom) > 0.0001 else { return }
        let visible = visibleRect
        let a = anchor ?? CGPoint(x: visible.midX, y: visible.midY)
        let pagePt = pagePoint(a)
        let offset = CGPoint(x: a.x - visible.minX, y: a.y - visible.minY)
        zoom = z
        updateLayout()
        let moved = viewPoint(pagePt)
        scroll(CGPoint(x: moved.x - offset.x, y: moved.y - offset.y))
        delegate?.canvasZoomChanged(self)
    }

    func zoomIn() { setZoom(Self.zoomSteps.first { $0 > zoom + 0.001 } ?? 4) }
    func zoomOut() { setZoom(Self.zoomSteps.last { $0 < zoom - 0.001 } ?? minZoom) }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    // MARK: Page and document

    /// Shows page `i` (commits any typing first). Returns false when a commit was refused.
    @discardableResult
    func show(page i: Int) -> Bool {
        guard i >= 0, i < session.pageCount else { return false }
        if i == page { return true }
        if editor != nil, !commitEditing() { return false }
        anglePopover?.close()
        page = i
        selection = nil
        hovered = nil
        hoveredImage = nil
        reloadPageState()
        updateLayout()
        scroll(CGPoint(x: frame.width / 2 - visibleRect.width / 2, y: 0))
        delegate?.canvasPageChanged(self)
        delegate?.canvasSelectionChanged(self)
        return true
    }

    /// After every change to the session: redraw from the new candidate.
    func sessionChanged() {
        reloadPageState()
        if let sel = selection, !exists(sel) { selection = nil }
        layoutCallout()
        elements = nil
        rebuildToolTips()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func exists(_ t: PDFEditTarget) -> Bool {
        if case .added(let id) = t { return session.addedTexts.contains { $0.id == id } }
        return true
    }

    private func reloadPageState() {
        if let ed = editor {
            switch ed.target {
            case .line(let id): document = session.previewDocument(blanking: id) ?? session.candidateDocument
            case .added(let id): document = session.previewDocument(hidingAdded: id) ?? session.candidateDocument
            case .new: document = session.candidateDocument
            }
        } else {
            document = session.candidateDocument
        }
        editedInfos = [:]
        for e in session.edits {
            if let id = e.line, id.page == page, let info = session.info(id) { editedInfos[id] = info }
        }
        addedOnPage = session.addedTexts.filter { $0.page == page }
    }

    func lines() -> [PDFTextLine] { session.lines(page: page) }

    func availability(_ id: PDFLineID) -> PDFLineAvailability {
        if let a = availability[id] { return a }
        let a = session.availability(id)
        availability[id] = a
        return a
    }

    /// The line's quad now (edited lines grow and shrink with their text), page space.
    func currentQuad(_ t: PDFEditTarget) -> [CGPoint] {
        switch t {
        case .line(let id):
            if let info = editedInfos[id] { return info.quad }
            return session.line(id)?.quad ?? []
        case .added(let id):
            return addedOnPage.first { $0.id == id }?.quad ?? session.addedTexts.first { $0.id == id }?.quad ?? []
        }
    }

    /// A quad mapped to view space and grown by `e` points on every side.
    func viewQuad(_ q: [CGPoint], grow e: CGFloat = 0) -> [CGPoint] {
        guard q.count == 4 else { return [] }
        let v = q.map(viewPoint)
        guard e != 0 else { return v }
        func unit(_ a: CGPoint, _ b: CGPoint) -> CGVector {
            let dx = b.x - a.x, dy = b.y - a.y, l = max(0.0001, hypot(dx, dy))
            return CGVector(dx: dx / l, dy: dy / l)
        }
        let u = unit(v[0], v[1]), w = unit(v[0], v[3])
        func p(_ base: CGPoint, _ su: CGFloat, _ sw: CGFloat) -> CGPoint {
            CGPoint(x: base.x + (u.dx * su + w.dx * sw) * e, y: base.y + (u.dy * su + w.dy * sw) * e)
        }
        return [p(v[0], -1, -1), p(v[1], 1, -1), p(v[2], 1, 1), p(v[3], -1, 1)]
    }

    static func bounds(_ q: [CGPoint]) -> CGRect { PDFEditGeometry.bounds(q) }

    func viewBounds(_ t: PDFEditTarget, grow: CGFloat = 0) -> CGRect { Self.bounds(viewQuad(currentQuad(t), grow: grow)) }

    /// The room a line has above and below its baseline before the ink of the lines next to it starts, in page
    /// points (nil: no line close by on that side). Tightly set text (a 12 pt font on a 12 pt pitch) has glyph boxes
    /// that overlap the next line's, so outlines drawn from them would cut through the neighbours' letters.
    struct Band {
        var above: CGFloat?
        var below: CGFloat?
        /// The line's own cap height (page points).
        var capHeight: CGFloat = 0
    }

    func band(_ id: PDFLineID) -> Band {
        if let b = bands[id] { return b }
        var band = Band()
        guard let l = session.line(id) else { return band }
        let size = CGFloat(max(1, l.pointSize))
        band.capHeight = min(session.editorFont(id).font.capHeight, size)
        let d = l.direction
        let n = CGVector(dx: d.dy, dy: -d.dx)            // towards the next line, in page space
        func along(_ p: CGPoint) -> (s: CGFloat, t: CGFloat) {
            let v = CGVector(dx: p.x - l.origin.x, dy: p.y - l.origin.y)
            return (v.dx * d.dx + v.dy * d.dy, v.dx * n.dx + v.dy * n.dy)
        }
        let own = l.quad.map { along($0).s }
        let lo = own.min() ?? 0, hi = own.max() ?? 0
        for m in session.lines(page: id.page) where m.index != id.line && !m.hidden {
            guard m.direction.dx * d.dx + m.direction.dy * d.dy > 0.999 else { continue }
            let mSize = CGFloat(max(1, m.pointSize))
            let t = along(m.origin).t
            // Lines on the next baselines (not text on this one, not lines further away). A superscript or subscript
            // drawn on its own (a footnote mark over the line) sits within the line's cap height: it's part of the
            // line, not a neighbour, and mustn't squeeze the outline into the line's own capitals.
            guard abs(t) > max(0.5 * min(size, mSize), band.capHeight), abs(t) < 3 * max(size, mSize) else { continue }
            let span = m.quad.map { along($0).s }
            guard let mlo = span.min(), let mhi = span.max(), mhi > lo, mlo < hi else { continue }
            let ink = inkExtent(PDFLineID(page: id.page, line: m.index))
            if t > 0 {
                band.below = min(band.below ?? .greatestFiniteMagnitude, t - ink.top)
            } else {
                band.above = min(band.above ?? .greatestFiniteMagnitude, -t + ink.bottom)
            }
        }
        bands[id] = band
        return band
    }

    /// How far a line's letters reach above (top) and below (bottom, negative) its baseline, in page points: the
    /// glyphs' own outlines in the font the editor uses for the line (the PDF's font, or the same one installed),
    /// or its cap height and descender when the font can't map the text.
    private func inkExtent(_ id: PDFLineID) -> (top: CGFloat, bottom: CGFloat) {
        guard let l = session.line(id) else { return (0, 0) }
        let size = CGFloat(max(1, l.pointSize))
        let font = session.editorFont(id).font
        let fallback = (top: min(size, max(font.capHeight, font.xHeight) * 1.05), bottom: max(-0.4 * size, font.descender))
        let text = l.text as NSString
        guard text.length > 0, text.length < 4000 else { return fallback }
        var chars = [UniChar](repeating: 0, count: text.length)
        text.getCharacters(&chars)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        _ = CTFontGetGlyphsForCharacters(font as CTFont, chars, &glyphs, chars.count)
        glyphs.removeAll { $0 == 0 }
        guard !glyphs.isEmpty else { return fallback }
        let r = CTFontGetBoundingRectsForGlyphs(font as CTFont, .horizontal, glyphs, nil, glyphs.count)
        guard !r.isNull, r.height > 0 else { return fallback }
        return (min(size * 1.2, r.maxY), max(-0.5 * size, r.minY))
    }

    /// A view-space quad around a line (or its editor) kept inside the line's band, so it doesn't cross the ink of
    /// the lines above and below; `inset` keeps a stroke of that half-width inside too. Where lines are set so
    /// tightly that there's no room, the neighbours win, but the quad always reaches from three quarters of the
    /// line's cap height to just under its baseline.
    func banded(_ v: [CGPoint], line id: PDFLineID, inset: CGFloat) -> [CGPoint] {
        guard v.count == 4, let l = session.line(id) else { return v }
        let b = band(id)
        guard b.above != nil || b.below != nil, let frame = bandFrame(l) else { return v }
        let (o, dv, nv) = frame
        let ownTop = -0.75 * b.capHeight * zoom, ownBottom: CGFloat = 1
        let maxT = b.below.map { max($0 * zoom - inset, ownBottom) }
        let minT = b.above.map { min(-($0 * zoom - inset), ownTop) }
        return v.map { p in
            let s = (p.x - o.x) * dv.dx + (p.y - o.y) * dv.dy
            var t = (p.x - o.x) * nv.dx + (p.y - o.y) * nv.dy
            if let maxT, t > maxT { t = maxT }
            if let minT, t < minT { t = minT }
            return CGPoint(x: o.x + s * dv.dx + t * nv.dx, y: o.y + s * dv.dy + t * nv.dy)
        }
    }

    /// The line's band as a clip path (view space), for strokes that would otherwise spill over its edges.
    func bandClip(_ id: PDFLineID) -> NSBezierPath? {
        guard let l = session.line(id), let (o, dv, nv) = bandFrame(l) else { return nil }
        let b = band(id)
        guard b.above != nil || b.below != nil else { return nil }
        let far = 4 * max(bounds.width, bounds.height)
        let top = -(b.above.map { $0 * zoom - Self.bandGap } ?? far), bottom = b.below.map { $0 * zoom - Self.bandGap } ?? far
        func pt(_ s: CGFloat, _ t: CGFloat) -> CGPoint { CGPoint(x: o.x + s * dv.dx + t * nv.dx, y: o.y + s * dv.dy + t * nv.dy) }
        let p = NSBezierPath()
        p.move(to: pt(-far, top)); p.line(to: pt(far, top)); p.line(to: pt(far, bottom)); p.line(to: pt(-far, bottom)); p.close()
        return p
    }

    /// A line's baseline start and its reading and next-line directions, in view space (unit vectors).
    private func bandFrame(_ l: PDFTextLine) -> (CGPoint, CGVector, CGVector)? {
        let o = viewPoint(l.origin)
        let a = viewPoint(CGPoint(x: l.origin.x + l.direction.dx, y: l.origin.y + l.direction.dy))
        let b = viewPoint(CGPoint(x: l.origin.x + l.direction.dy, y: l.origin.y - l.direction.dx))
        func unit(_ p: CGPoint) -> CGVector? {
            let dx = p.x - o.x, dy = p.y - o.y, len = hypot(dx, dy)
            return len > 0.000_001 ? CGVector(dx: dx / len, dy: dy / len) : nil
        }
        guard let dv = unit(a), let nv = unit(b) else { return nil }
        return (o, dv, nv)
    }

    /// A line's outline in view space: its quad grown by `grow`, kept on its own line.
    func outlineQuad(_ t: PDFEditTarget, grow: CGFloat, stroke: CGFloat) -> [CGPoint] {
        let q = viewQuad(currentQuad(t), grow: grow)
        guard case .line(let id) = t else { return q }
        return banded(q, line: id, inset: stroke / 2 + Self.bandGap)
    }

    /// The clear space (view points) an outline keeps from the neighbouring lines' letters.
    static let bandGap: CGFloat = 0.5

    /// The reading direction of a quad on screen, in degrees clockwise (0 = left to right).
    func screenAngle(_ q: [CGPoint]) -> CGFloat {
        let v = viewQuad(q)
        guard v.count == 4 else { return 0 }
        let a = atan2(v[1].y - v[0].y, v[1].x - v[0].x) * 180 / .pi
        return a < -0.0001 ? a + 360 : a
    }

    // MARK: Hit testing

    /// The text under a view point: added text first (it is drawn on top), then the line whose middle is nearest.
    func target(at p: CGPoint) -> PDFEditTarget? {
        for a in addedOnPage.reversed() {
            if let d = drag, d.id == a.id { continue }
            if Self.contains(viewQuad(a.quad, grow: 3), p) { return .added(a.id) }
        }
        guard mode == .editText else { return nil }
        var best: (PDFEditTarget, CGFloat)?
        for l in lines() {
            let id = PDFLineID(page: page, line: l.index)
            let q = viewQuad(currentQuad(.line(id)), grow: 2)
            guard Self.contains(q, p) else { continue }
            let mid0 = CGPoint(x: (q[0].x + q[3].x) / 2, y: (q[0].y + q[3].y) / 2)
            let mid1 = CGPoint(x: (q[1].x + q[2].x) / 2, y: (q[1].y + q[2].y) / 2)
            let d = Self.distance(p, toLine: mid0, mid1)
            if best == nil || d < best!.1 { best = (.line(id), d) }
        }
        return best?.0
    }

    static func contains(_ q: [CGPoint], _ p: CGPoint) -> Bool {
        guard q.count == 4 else { return false }
        let path = CGMutablePath()
        path.addLines(between: q)
        path.closeSubpath()
        return path.contains(p)
    }

    static func distance(_ p: CGPoint, toLine a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l = hypot(dx, dy)
        guard l > 0.0001 else { return hypot(p.x - a.x, p.y - a.y) }
        return abs((p.x - a.x) * dy - (p.y - a.y) * dx) / l
    }

    private func image(at p: CGPoint) -> Int? {
        guard mode == .editText else { return nil }
        let images = session.content(page: page).images
        return images.indices.last { Self.contains(viewQuad(images[$0].quad), p) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ImageEditors.Style.canvas.setFill()
            dirtyRect.fill()
        }
        // The sheet of paper: a soft two-layer shadow, then white.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = CGSize(width: 0, height: -2)
        shadow.set()
        NSColor.white.setFill()
        pageFrame.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.08).setStroke()
        NSBezierPath(rect: pageFrame.insetBy(dx: -0.5, dy: -0.5)).stroke()

        if let pdfPage = document.page(at: page) {
            ctx.saveGState()
            ctx.clip(to: pageFrame)
            ctx.concatenate(uprightToView)
            ctx.setFillColor(.white)
            pdfPage.draw(with: .cropBox, to: ctx)
            ctx.restoreGState()
        }
        PDFEditPaint.paperAppearance.performAsCurrentDrawingAppearance { drawMarks() }
    }

    private func drawMarks() {
        // Change bars: the app accent beside every line you changed, and every text you added.
        for (id, info) in editedInfos { drawChangeBar(info.isDeleted ? info.originalQuad : currentQuad(.line(id))) }
        for a in addedOnPage where drag?.id != a.id { drawChangeBar(a.quad) }
        // Overflow: amber outline and a warning sign at the end of the line.
        for (_, info) in editedInfos where info.overflowMessage != nil && !info.isDeleted {
            if editor?.lineID == info.id { continue }
            stroke(outlineQuad(.line(info.id), grow: 2, stroke: 2), color: PDFEditPaint.amber, width: 2)
            drawWarning(at: info.quad)
        }
        // Hover.
        if editor == nil || hovered.map({ !isEditing($0) }) == true, let h = hovered, h != selection {
            let editable: Bool
            if case .line(let id) = h { editable = availability(id).isEditable } else { editable = true }
            stroke(outlineQuad(h, grow: 2, stroke: 1), color: editable ? PDFEditPaint.accent : PDFEditPaint.readOnly,
                   width: 1, dash: [4, 3])
        }
        if let i = hoveredImage, hovered == nil {
            let images = session.content(page: page).images
            if i < images.count { stroke(viewQuad(images[i].quad, grow: -2), color: PDFEditPaint.readOnly, width: 1, dash: [4, 3]) }
        }
        // Selection (not editing).
        if editor == nil, let s = selection {
            var editable = true
            if case .line(let id) = s { editable = availability(id).isEditable }
            let color = editable ? PDFEditPaint.accent : PDFEditPaint.readOnly
            // An overflowing line keeps its amber outline when selected (the callout below says why).
            var overflowing = false
            if case .line(let id) = s, let info = editedInfos[id], info.overflowMessage != nil, !info.isDeleted { overflowing = true }
            let q = outlineQuad(s, grow: 2, stroke: overflowing ? 2 : 1.5)
            fill(q, color: color.withAlphaComponent(0.08))
            stroke(q, color: overflowing ? PDFEditPaint.amber : color, width: overflowing ? 2 : 1.5)
        }
        // Moving an added text: its outline follows the pointer.
        if let d = drag, d.moved, let a = addedOnPage.first(where: { $0.id == d.id }) {
            let q = viewQuad(a.quad, grow: 2).map { CGPoint(x: $0.x + d.offset.dx, y: $0.y + d.offset.dy) }
            stroke(q, color: PDFEditPaint.accent, width: 1.5, dash: [4, 3])
        }
        // Editing: the editor's own area, a little wider than the text, on its own line (the soft outer ring is
        // cut off where the next line's letters start).
        if let ed = editor {
            let q = editorQuad(ed, grow: 2)
            NSGraphicsContext.saveGraphicsState()
            if let id = ed.lineID { bandClip(id)?.addClip() }
            stroke(q, color: PDFEditPaint.accent.withAlphaComponent(0.3), width: 3.5)
            stroke(q, color: PDFEditPaint.accent, width: 1.5)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func isEditing(_ t: PDFEditTarget) -> Bool {
        guard let ed = editor else { return false }
        switch (t, ed.target) {
        case (.line(let a), .line(let b)): return a == b
        case (.added(let a), .added(let b)): return a == b
        default: return false
        }
    }

    private func path(_ q: [CGPoint]) -> NSBezierPath {
        let p = NSBezierPath()
        guard q.count == 4 else { return p }
        // Axis-aligned quads get softly rounded corners; others are drawn as they are.
        let b = Self.bounds(q)
        let aligned = q.allSatisfy { abs($0.x - b.minX) < 0.5 || abs($0.x - b.maxX) < 0.5 }
            && q.allSatisfy { abs($0.y - b.minY) < 0.5 || abs($0.y - b.maxY) < 0.5 }
        if aligned { return NSBezierPath(roundedRect: b, xRadius: 3, yRadius: 3) }
        p.move(to: q[0]); q.dropFirst().forEach { p.line(to: $0) }; p.close()
        return p
    }

    private func stroke(_ q: [CGPoint], color: NSColor, width: CGFloat, dash: [CGFloat]? = nil) {
        let p = path(q)
        p.lineWidth = width
        if let dash { p.setLineDash(dash, count: dash.count, phase: 0) }
        color.setStroke()
        p.stroke()
    }

    private func fill(_ q: [CGPoint], color: NSColor) {
        color.setFill()
        path(q).fill()
    }

    private func drawChangeBar(_ quad: [CGPoint]) {
        let v = viewQuad(quad)
        guard v.count == 4 else { return }
        let dx = v[1].x - v[0].x, dy = v[1].y - v[0].y, l = max(0.0001, hypot(dx, dy))
        let ux = dx / l, uy = dy / l
        let gap: CGFloat = 7
        let bar = NSBezierPath()
        bar.move(to: CGPoint(x: v[0].x - ux * gap, y: v[0].y - uy * gap))
        bar.line(to: CGPoint(x: v[3].x - ux * gap, y: v[3].y - uy * gap))
        bar.lineWidth = 3
        bar.lineCapStyle = .round
        PDFEditPaint.changeBar.setStroke()
        bar.stroke()
    }

    private func drawWarning(at quad: [CGPoint]) {
        let v = viewQuad(quad)
        guard v.count == 4, let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) else { return }
        let dx = v[1].x - v[0].x, dy = v[1].y - v[0].y, l = max(0.0001, hypot(dx, dy))
        let mid = CGPoint(x: (v[1].x + v[2].x) / 2 + dx / l * 11, y: (v[1].y + v[2].y) / 2 + dy / l * 11)
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            PDFEditPaint.amber.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: CGRect(x: mid.x - symbol.size.width / 2, y: mid.y - symbol.size.height / 2,
                               width: symbol.size.width, height: symbol.size.height))
    }

    // MARK: Hover, cursor and tooltips

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { setHover(nil, image: nil) }

    func hover(at p: CGPoint) {
        let t = target(at: p)
        setHover(t, image: t == nil ? image(at: p) : nil)
    }

    private func setHover(_ t: PDFEditTarget?, image: Int?) {
        guard t != hovered || image != hoveredImage else { return }
        for old in [hovered].compactMap({ $0 }) { setNeedsDisplay(viewBounds(old, grow: 6)) }
        if hoveredImage != nil || image != nil { needsDisplay = true }
        hovered = t
        hoveredImage = image
        if let t { setNeedsDisplay(viewBounds(t, grow: 6)) }
    }

    override func resetCursorRects() {
        if mode == .addText {
            addCursorRect(pageFrame.intersection(visibleRect), cursor: .iBeam)
        }
        for a in addedOnPage { addCursorRect(Self.bounds(viewQuad(a.quad, grow: 3)).intersection(visibleRect), cursor: .iBeam) }
        guard mode == .editText else { return }
        for l in lines() {
            let id = PDFLineID(page: page, line: l.index)
            guard availability(id).isEditable else { continue }
            let r = Self.bounds(viewQuad(currentQuad(.line(id)), grow: 2)).intersection(visibleRect)
            guard !r.isEmpty else { continue }
            let a = screenAngle(currentQuad(.line(id))).truncatingRemainder(dividingBy: 180)
            addCursorRect(r, cursor: abs(a - 90) < 1 ? .iBeamCursorForVerticalLayout : .iBeam)
        }
    }

    private func rebuildToolTips() {
        removeAllToolTips()
        guard mode == .editText else { return }
        for l in lines() {
            let id = PDFLineID(page: page, line: l.index)
            if !availability(id).isEditable { addToolTip(viewBounds(.line(id), grow: 2), owner: self, userData: nil) }
        }
        for img in session.content(page: page).images { addToolTip(Self.bounds(viewQuad(img.quad)), owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        if case .line(let id)? = target(at: point), let why = availability(id).reason { return why }
        if image(at: point) != nil { return "Scanned image: its words are part of the picture, so they can’t be edited. Use Add Text to add new text." }
        return ""
    }

    // MARK: Selection

    func select(_ t: PDFEditTarget?, reveal: Bool = false) {
        if let t, case .line(let id) = t, id.page != page { show(page: id.page) }
        if let t, case .added(let id) = t, let a = session.addedTexts.first(where: { $0.id == id }), a.page != page { show(page: a.page) }
        if t != selection {
            for old in [selection].compactMap({ $0 }) { setNeedsDisplay(viewBounds(old, grow: 6)) }
            selection = t
            if let t { setNeedsDisplay(viewBounds(t, grow: 6)) }
        }
        if reveal, let t { scrollToVisible(viewBounds(t, grow: 48)) }
        layoutCallout()
        delegate?.canvasSelectionChanged(self)
    }

    /// Editable lines in reading order, page by page, and the one `step` lines from `from`.
    func neighbour(of from: PDFLineID?, step: Int) -> PDFLineID? {
        var p = from?.page ?? page
        var i = from.map { $0.line + step } ?? (step > 0 ? 0 : lines().count - 1)
        while p >= 0 && p < session.pageCount {
            let ls = session.lines(page: p)
            while i >= 0 && i < ls.count {
                let id = PDFLineID(page: p, line: i)
                if availability(id).isEditable { return id }
                i += step
            }
            p += step
            guard p >= 0 && p < session.pageCount else { break }
            i = step > 0 ? 0 : session.lines(page: p).count - 1
        }
        return nil
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        mouseDown(at: convert(event.locationInWindow, from: nil), clickCount: event.clickCount)
    }

    /// A click on the canvas (the self-test calls this with synthesized positions).
    func mouseDown(at p: CGPoint, clickCount: Int = 1) {
        anglePopover?.close()
        if let ed = editor {
            // A second click inside the line being edited selects a word (the text view takes clicks on its own
            // area; this is the outline's margin).
            if clickCount > 1, Self.contains(editorQuad(ed, grow: 3), p) { selectInEditor(at: p, clickCount: clickCount); return }
            guard commitEditing() else { return }
        }
        window?.makeFirstResponder(self)
        let t = target(at: p)
        if case .added(let id)? = t, let a = addedOnPage.first(where: { $0.id == id }) {
            drag = (id, p, a.origin, false, .zero)
            select(.added(id))
            return
        }
        if mode == .addText {
            if pageFrame.contains(p) { beginNewText(at: p) } else { select(nil) }
            return
        }
        guard case .line(let id)? = t else { select(nil); return }
        if availability(id).isEditable {
            beginEditing(.line(id), caretAt: p, clickCount: clickCount)
        } else {
            select(.line(id))
        }
    }

    override func mouseDragged(with event: NSEvent) { mouseDragged(to: convert(event.locationInWindow, from: nil)) }

    func mouseDragged(to p: CGPoint) {
        guard var d = drag else { return }
        let off = CGVector(dx: p.x - d.start.x, dy: p.y - d.start.y)
        if !d.moved && hypot(off.dx, off.dy) < 3 { return }
        d.moved = true
        d.offset = off
        drag = d
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { mouseUp(at: convert(event.locationInWindow, from: nil)) }

    func mouseUp(at p: CGPoint) {
        guard let d = drag else { return }
        drag = nil
        if d.moved {
            let start = pagePoint(d.start), end = pagePoint(p)
            let origin = CGPoint(x: d.origin.x + end.x - start.x, y: d.origin.y + end.y - start.y)
            _ = delegate?.canvas(self, perform: "Couldn’t move the text") { try session.updateAddedText(d.id, origin: origin) }
            needsDisplay = true
        } else {
            beginEditing(.added(d.id), caretAt: p)
        }
    }

    // MARK: Keys (when the canvas, not the inline editor, has the keyboard)

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 48 where flags.isSubset(of: .shift):                       // Tab, ⇧Tab
            moveSelection(flags.contains(.shift) ? -1 : 1)
        case 48 where flags.contains(.control):                         // ⌃Tab, ⌃⇧Tab: on to the sidebar and inspector
            // Tab moves between lines here, so ⌃Tab is the way out, as in any view that uses Tab itself.
            if flags.contains(.shift) { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
        case 125 where flags.isEmpty: moveSelection(1)                  // ↓
        case 126 where flags.isEmpty: moveSelection(-1)                 // ↑
        case 36, 76:                                                    // Return, Enter
            if let s = selection { beginEditing(s.editorTarget) } else { moveSelection(1) }
        case 51, 117: deleteSelection()                                 // ⌫, ⌦
        case 53: select(nil)                                            // Esc
        case 116: show(page: page - 1)                                  // Page Up
        case 121: show(page: page + 1)                                  // Page Down
        case 115: show(page: 0)                                         // Home
        case 119: show(page: session.pageCount - 1)                     // End
        default: super.keyDown(with: event)
        }
    }

    func moveSelection(_ step: Int) {
        var from: PDFLineID?
        if case .line(let id)? = selection { from = id }
        if let next = neighbour(of: from, step: step) { select(.line(next), reveal: true) } else { NSSound.beep() }
    }

    /// ⌫ on a selected line (not while typing): its text goes, with a spacer so nothing else moves.
    func deleteSelection() {
        switch selection {
        case .line(let id)?:
            guard availability(id).isEditable else { NSSound.beep(); return }
            let scope = pendingScope[id]
            _ = delegate?.canvas(self, perform: "Couldn’t delete the text") { try session.deleteLine(id, scope: scope) }
        case .added(let id)?:
            _ = delegate?.canvas(self, perform: "Couldn’t delete the text") { session.removeAddedText(id) }
            select(nil)
        case nil:
            NSSound.beep()
        }
    }

    // MARK: Inline editor

    /// Starts typing in a line or an added text. Lines at an angle that isn't a multiple of 90° open a popover.
    func beginEditing(_ target: Editor.Target, caretAt p: CGPoint? = nil, clickCount: Int = 1) {
        if editor != nil, !commitEditing() { return }
        anglePopover?.close()
        let ed: Editor
        switch target {
        case .line(let id):
            if id.page != page { show(page: id.page) }
            guard let info = session.info(id), info.availability.isEditable else { select(.line(id)); return }
            let angle = screenAngle(info.originalQuad)
            let rest = angle.truncatingRemainder(dividingBy: 90)
            if min(rest, 90 - rest) > 0.5 { select(.line(id)); presentAngledEditor(id, info: info); return }
            let font = session.editorFont(id).font
            let color = NSColor(cgColor: info.color) ?? .black
            let len = hypot(info.originalQuad[1].x - info.originalQuad[0].x, info.originalQuad[1].y - info.originalQuad[0].y)
            ed = Editor(target: target, text: info.text, origin: info.origin, font: font, color: color,
                        screenAngle: ((angle / 90).rounded() * 90).truncatingRemainder(dividingBy: 360), minLength: len)
            selection = .line(id)
        case .added(let id):
            guard let a = session.addedTexts.first(where: { $0.id == id }) else { return }
            if a.page != page { show(page: a.page) }
            let font = NSFont(name: a.style.fontName, size: CGFloat(a.style.size)) ?? .systemFont(ofSize: CGFloat(a.style.size))
            ed = Editor(target: target, text: a.text, origin: a.origin, font: font,
                        color: NSColor(cgColor: a.style.color) ?? .black, screenAngle: 0, minLength: 0)
            selection = .added(id)
        case .new(let pg, let origin):
            if pg != page { show(page: pg) }
            let size = CGFloat(addStyle.size)
            let font = NSFont(name: addStyle.fontName, size: size) ?? .systemFont(ofSize: size)
            ed = Editor(target: target, text: "", origin: origin, font: font,
                        color: NSColor(cgColor: addStyle.color) ?? .black, screenAngle: 0, minLength: size * 4)
            selection = nil
        }
        ed.textView.delegate = self
        ed.textView.setAccessibilityLabel(ed.isNew ? "New text" : "Text being edited")
        editor = ed
        addSubview(ed.host)
        reloadPageState()
        layoutEditor()
        callout?.removeFromSuperview()
        callout = nil
        window?.makeFirstResponder(ed.textView)
        let tv = ed.textView
        if let p, !ed.isNew {
            let i = characterIndex(at: p, in: ed)
            tv.setSelectedRange(NSRange(location: i, length: 0))
            if clickCount > 1 { selectInEditor(at: p, clickCount: clickCount) }
        } else {
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        }
        elements = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        delegate?.canvasSelectionChanged(self)
    }

    /// A click in Add Text mode: a new text box whose caret is centred on the click.
    func beginNewText(at p: CGPoint) {
        let size = CGFloat(addStyle.size) * zoom
        let font = NSFont(name: addStyle.fontName, size: size) ?? .systemFont(ofSize: size)
        let baseline = CGPoint(x: p.x, y: p.y + (font.ascender + font.descender) / 2)
        beginEditing(.new(page: page, origin: pagePoint(baseline)))
    }

    private func characterIndex(at p: CGPoint, in ed: Editor) -> Int {
        let local = ed.textView.convert(p, from: self)
        return ed.textView.characterIndexForInsertion(at: local)
    }

    private func selectInEditor(at p: CGPoint, clickCount: Int) {
        guard let ed = editor else { return }
        let tv = ed.textView
        let i = characterIndex(at: p, in: ed)
        let granularity: NSSelectionGranularity = clickCount >= 3 ? .selectByParagraph : .selectByWord
        tv.setSelectedRange(tv.selectionRange(forProposedRange: NSRange(location: min(i, (tv.string as NSString).length), length: 0),
                                              granularity: granularity))
    }

    /// The editor's area in view space (unrotated rectangle turned by its angle), kept on the line's own band so its
    /// outline doesn't cross the lines above and below.
    func editorQuad(_ ed: Editor, grow: CGFloat = 0) -> [CGPoint] {
        // The glyph box (ascent to descent on the first baseline), not the text view's taller line height.
        let tv = ed.textView
        let font = tv.font ?? ed.font
        let baseline = ed.baseline
        let box = CGRect(x: 0, y: baseline - font.ascender, width: tv.bounds.width, height: font.ascender - font.descender)
        let local = box.insetBy(dx: -grow, dy: -grow)
        let pts = [CGPoint(x: local.minX, y: local.maxY), CGPoint(x: local.maxX, y: local.maxY),
                   CGPoint(x: local.maxX, y: local.minY), CGPoint(x: local.minX, y: local.minY)]
        let quad = pts.map { ed.textView.convert($0, to: self) }
        guard let id = ed.lineID else { return quad }
        return banded(quad, line: id, inset: 0.75 + Self.bandGap)
    }

    /// Places the editor so its first baseline sits on the line's baseline, at the zoom, turned with the line.
    func layoutEditor() {
        guard let ed = editor else { return }
        let tv = ed.textView
        let font = (CTFontCreateCopyWithAttributes(ed.font as CTFont, ed.font.pointSize * zoom, nil, nil) as NSFont)
        if tv.font != font {
            let sel = tv.selectedRanges
            tv.font = font
            tv.typingAttributes[.font] = font
            tv.textStorage?.addAttribute(.font, value: font, range: NSRange(location: 0, length: (tv.string as NSString).length))
            tv.selectedRanges = sel
        }
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        // The baseline and line height as actually laid out (defaultBaselineOffset disagrees for some fonts and
        // would put the text a few points off its line, or clip descenders).
        var height = lm.defaultLineHeight(for: font)
        var baseline = height + font.descender
        if lm.numberOfGlyphs > 0 {
            let frag = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            height = frag.height
            baseline = frag.minY + lm.location(forGlyphAt: 0).y
        } else if lm.extraLineFragmentRect.height > 0 {
            height = lm.extraLineFragmentRect.height
            baseline = height + font.descender
        }
        height = height.rounded(.up)
        ed.baseline = baseline
        let used = lm.usedRect(for: tc).width
        let width = max(ed.minLength * zoom, used + 3, 4).rounded(.up)
        tv.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let o = viewPoint(ed.origin)
        ed.host.frameRotation = 0
        ed.host.frame = CGRect(x: o.x, y: o.y - baseline, width: width, height: height)
        if ed.screenAngle != 0 {
            // Turn around the frame origin, then move it so the baseline start lands on the line's own.
            ed.host.frameRotation = ed.screenAngle
            let r = ed.screenAngle * .pi / 180
            ed.host.setFrameOrigin(CGPoint(x: o.x + sin(r) * baseline, y: o.y - cos(r) * baseline))
        }
        needsDisplay = true
    }

    /// Ends typing and applies it as one undoable change. A refusal leaves the editor open with the typing kept.
    @discardableResult
    func commitEditing() -> Bool {
        guard let ed = editor else { return true }
        let tv = ed.textView
        if tv.hasMarkedText() { tv.unmarkText() }
        let typed = tv.string
        let text = typed + ed.padding
        var ok = true
        switch ed.target {
        case .line(let id):
            if typed != ed.startText {
                let scope = pendingScope[id]
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    ok = delegate?.canvas(self, perform: "Couldn’t delete the text") { try session.deleteLine(id, scope: scope) } ?? false
                } else {
                    ok = delegate?.canvas(self, perform: "Couldn’t change the text") { try session.setText(text, for: id, scope: scope) } ?? false
                }
            }
        case .added(let id):
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ok = delegate?.canvas(self, perform: "Couldn’t delete the text") { session.removeAddedText(id) } ?? false
                if ok { selection = nil }
            } else if typed != ed.startText {
                ok = delegate?.canvas(self, perform: "Couldn’t change the text") { try session.updateAddedText(id, text: text) } ?? false
            }
        case .new(let pg, let origin):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var newID: UUID?
                ok = delegate?.canvas(self, perform: "Couldn’t add the text") {
                    newID = try session.addText(text, page: pg, at: origin, style: addStyle)
                } ?? false
                if ok, let newID { selection = .added(newID) }
            }
        }
        guard ok else { window?.makeFirstResponder(tv); return false }
        endEditing()
        return true
    }

    /// Leaves the editor without applying the typing.
    func cancelEditing() {
        guard editor != nil else { return }
        endEditing()
    }

    private func endEditing() {
        guard let ed = editor else { return }
        ed.textView.delegate = nil
        ed.host.removeFromSuperview()
        editor = nil
        if window?.firstResponder === ed.textView || window?.firstResponder == nil { window?.makeFirstResponder(self) }
        reloadPageState()
        layoutCallout()
        elements = nil
        rebuildToolTips()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        delegate?.canvasSelectionChanged(self)
    }

    /// Commits and edits the next (or previous) editable line in reading order.
    private func commitAndMove(_ step: Int) {
        guard let ed = editor else { return }
        let from = ed.lineID
        guard commitEditing() else { return }
        if let from, let next = neighbour(of: from, step: step) {
            beginEditing(.line(next))
            scrollToVisible(viewBounds(.line(next), grow: 48))
        }
    }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let ed = editor, textView === ed.textView else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            commitAndMove(1)
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertTabIgnoringFieldEditor(_:)):
            commitAndMove(1)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            commitAndMove(-1)
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
            escape()
            return true
        default:
            return false
        }
    }

    /// Esc while typing: the first press puts back the text from before typing; the next leaves the line selected.
    func escape() {
        guard let ed = editor else { return }
        if ed.textView.string != ed.startText {
            if ed.textView.hasMarkedText() { ed.textView.unmarkText() }
            ed.textView.string = ed.startText
            ed.textView.setSelectedRange(NSRange(location: (ed.startText as NSString).length, length: 0))
            ed.typingUndo.removeAllActions()
            layoutEditor()
            delegate?.canvasTypingChanged(self)
        } else {
            let keep = selection
            cancelEditing()
            if case .line? = keep { select(keep) }
        }
    }

    func textDidChange(_ notification: Notification) {
        layoutEditor()
        delegate?.canvasTypingChanged(self)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { editor?.typingUndo }

    /// One line at a time: pasted line breaks and tabs become spaces.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        guard let text, text.contains(where: { $0.isNewline || $0 == "\t" }) else { return true }
        let clean = text.map { $0.isNewline || $0 == "\t" ? " " : String($0) }.joined()
        textView.insertText(clean, replacementRange: range)
        return false
    }

    // MARK: Lines at an angle

    /// Lines that aren't a multiple of 90° on screen are edited in a popover (an inline editor can't follow them).
    private func presentAngledEditor(_ id: PDFLineID, info: PDFLineInfo) {
        let vc = PDFEditAngledEditor(text: info.text, angle: info.angle) { [weak self] text in
            guard let self else { return }
            self.anglePopover?.close()
            guard let text, text != info.text else { return }
            _ = self.delegate?.canvas(self, perform: "Couldn’t change the text") {
                try self.session.setText(text, for: id, scope: self.pendingScope[id])
            }
        }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = vc
        anglePopover = pop
        if window?.isVisible == true { pop.show(relativeTo: viewBounds(.line(id), grow: 2), of: self, preferredEdge: .maxY) }
    }

    // MARK: Overflow callout

    /// The selected line runs past its room: a callout under it with Fit Width and Keep Position.
    func layoutCallout() {
        var show: PDFLineInfo?
        if editor == nil, case .line(let id)? = selection, id.page == page, let info = editedInfos[id] ?? session.info(id),
           info.isEdited, !info.isDeleted, info.overflowMessage != nil { show = info }
        guard let info = show else { callout?.removeFromSuperview(); callout = nil; return }
        let c = callout ?? PDFEditOverflowCallout()
        c.update(info) { [weak self] spacing in
            guard let self else { return }
            _ = self.delegate?.canvas(self, perform: "Couldn’t change the spacing") { try self.session.setSpacing(spacing, for: info.id) }
        }
        if c.superview == nil { addSubview(c) }
        callout = c
        let size = c.fittingSize
        let b = viewBounds(.line(info.id), grow: 3)
        var x = b.minX
        x = min(x, pageFrame.maxX - size.width - 8)
        x = max(x, pageFrame.minX + 8)
        var y = b.maxY + 6
        if y + size.height > pageFrame.maxY - 4 { y = b.minY - 6 - size.height }
        c.frame = CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    // MARK: Undo outline

    /// After an undo or redo: scroll to the text and outline it for 0.6 s (fading, unless Reduce Motion is on).
    func flash(_ t: PDFEditTarget) {
        flashView?.removeFromSuperview()
        let q = outlineQuad(t, grow: 3, stroke: 2.5)
        guard q.count == 4 else { return }
        let b = Self.bounds(q).insetBy(dx: -3, dy: -3)
        scrollToVisible(b.insetBy(dx: -40, dy: -40))
        let v = PDFEditFlashView(frame: b, quad: q.map { CGPoint(x: $0.x - b.minX, y: $0.y - b.minY) })
        addSubview(v)
        flashView = v
        flashFades = !reduceMotion
        if reduceMotion {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak v] in
                v?.removeFromSuperview()
                if self?.flashView === v { self?.flashView = nil }
            }
        } else {
            let remove = { [weak self, weak v] in
                v?.removeFromSuperview()
                if let v, self?.flashView === v { self?.flashView = nil }
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.6
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                v.animator().alphaValue = 0
            }, completionHandler: remove)
            // The completion handler waits for Core Animation, which doesn't run for a window that isn't on screen
            // (or a display that's asleep): the faded outline goes on time either way.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: remove)
        }
    }

    private func modeChanged() {
        if editor != nil { _ = commitEditing() }
        if mode == .addText, case .line? = selection { select(nil) }
        hovered = nil
        hoveredImage = nil
        rebuildToolTips()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        delegate?.canvasSelectionChanged(self)
    }

    // MARK: Accessibility

    override func accessibilityLabel() -> String? { "Page \(page + 1)" }

    override func accessibilityChildren() -> [Any]? {
        if elements == nil {
            var out: [PDFEditLineElement] = []
            for l in lines() {
                let id = PDFLineID(page: page, line: l.index)
                if isEditing(.line(id)) { continue }
                let e = PDFEditLineElement(canvas: self, target: .line(id))
                let info = editedInfos[id]
                e.setAccessibilityLabel("Line \(l.index + 1)\(info != nil ? ", edited" : "")")
                e.setAccessibilityValue(info?.text ?? l.text)
                if let why = availability(id).reason { e.setAccessibilityRole(.staticText); e.setAccessibilityHelp(why) }
                else { e.setAccessibilityRole(.textArea); e.setAccessibilityHelp("Press to edit this line.") }
                e.setAccessibilityFrameInParentSpace(viewBounds(.line(id)))
                e.setAccessibilityParent(self)
                out.append(e)
            }
            for a in addedOnPage where !isEditing(.added(a.id)) {
                let e = PDFEditLineElement(canvas: self, target: .added(a.id))
                e.setAccessibilityRole(.textArea)
                e.setAccessibilityLabel("Added text")
                e.setAccessibilityValue(a.text)
                e.setAccessibilityHelp("Press to edit this text.")
                e.setAccessibilityFrameInParentSpace(Self.bounds(viewQuad(a.quad)))
                e.setAccessibilityParent(self)
                out.append(e)
            }
            elements = out
        }
        var children: [Any] = elements ?? []
        if let ed = editor { children.append(ed.textView) }
        if let callout { children.append(callout) }
        return children
    }
}

extension PDFEditTarget {
    var editorTarget: PDFEditCanvas.Editor.Target {
        switch self {
        case .line(let id): return .line(id)
        case .added(let id): return .added(id)
        }
    }
}

// MARK: - Small views

/// The inline editor's text view: one line, transparent over the page, its own font and colour.
final class PDFEditTextView: NSTextView {
    func configure(color: NSColor) {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
        textContainerInset = .zero
        isHorizontallyResizable = false
        isVerticallyResizable = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticTextCompletionEnabled = false
        usesFindBar = false
        if let tc = textContainer {
            tc.lineFragmentPadding = 0
            tc.widthTracksTextView = false
            tc.heightTracksTextView = false
            tc.containerSize = CGSize(width: 1_000_000, height: 1_000_000)
            tc.maximumNumberOfLines = 1
        }
        textColor = color
        typingAttributes[.foregroundColor] = color
        // The caret follows the text colour unless that is too pale to see on white paper.
        let c = color.usingColorSpace(.sRGB) ?? color
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        insertionPointColor = luminance < 0.6 ? color : PDFEditPaint.accent
        selectedTextAttributes = [.backgroundColor: PDFEditPaint.accent.withAlphaComponent(0.25)]
    }
}

/// Holds the text view so it can be turned with a rotated line.
final class PDFEditEditorHost: NSView {
    override var isFlipped: Bool { true }
}

/// The outline drawn for 0.6 s after an undo or redo.
final class PDFEditFlashView: NSView {
    private let quad: [CGPoint]

    init(frame: CGRect, quad: [CGPoint]) {
        self.quad = quad
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath()
        guard quad.count == 4 else { return }
        let b = PDFEditGeometry.bounds(quad)
        let aligned = quad.allSatisfy { abs($0.x - b.minX) < 0.5 || abs($0.x - b.maxX) < 0.5 }
        if aligned { p.append(NSBezierPath(roundedRect: b, xRadius: 3, yRadius: 3)) }
        else { p.move(to: quad[0]); quad.dropFirst().forEach { p.line(to: $0) }; p.close() }
        PDFEditPaint.accent.withAlphaComponent(0.12).setFill()
        p.fill()
        p.lineWidth = 2.5
        PDFEditPaint.accent.setStroke()
        p.stroke()
    }
}

/// "17.5 pt too wide" under the selected line, with Fit Width and Keep Position.
final class PDFEditOverflowCallout: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    let fitButton = NSButton(title: PDFSpacing.fit.title, target: nil, action: nil)
    let keepButton = NSButton(title: PDFSpacing.keep.title, target: nil, action: nil)
    private var onSpacing: ((PDFSpacing) -> Void)?

    init() {
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon.contentTintColor = .systemOrange
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        for (b, s) in [(fitButton, PDFSpacing.fit), (keepButton, .keep)] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
            b.target = self
            b.action = #selector(choose(_:))
            b.tag = s == .fit ? 1 : 2
        }
        fitButton.toolTip = "Squeeze the new text to the line’s old width (70–130 %)."
        keepButton.toolTip = "Keep the text after the change where it was."
        let stack = NSStackView(views: [icon, label, fitButton, keepButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.setCustomSpacing(12, after: label)
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        wantsLayer = true
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.25)
            s.shadowBlurRadius = 6
            s.shadowOffset = CGSize(width: 0, height: -2)
            return s
        }()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func update(_ info: PDFLineInfo, onSpacing: @escaping (PDFSpacing) -> Void) {
        self.onSpacing = onSpacing
        label.stringValue = info.overflowMessage ?? ""
        fitButton.isEnabled = info.spacing != .fit
        keepButton.isEnabled = info.spacing != .keep
        setAccessibilityLabel("“\(PDFEditWindowController.excerpt(info.text))” is \(info.overflowMessage ?? "too wide")")
    }

    var message: String { label.stringValue }

    @objc private func choose(_ sender: NSButton) { onSpacing?(sender.tag == 1 ? .fit : .keep) }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let r = bounds.insetBy(dx: 0.5, dy: 0.5)
            let p = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            NSColor.windowBackgroundColor.setFill()
            p.fill()
            NSColor.systemOrange.withAlphaComponent(0.7).setStroke()
            p.lineWidth = 1
            p.stroke()
        }
    }
}

/// A popover editor for lines that sit at an angle.
final class PDFEditAngledEditor: NSViewController, NSTextFieldDelegate {
    private let text: String
    private let angle: Double
    private let done: (String?) -> Void
    let field = NSTextField()

    init(text: String, angle: Double, done: @escaping (String?) -> Void) {
        self.text = text
        self.angle = angle
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let note = NSTextField(labelWithString: "This text is turned \(Int(angle.rounded()))°, so it’s edited here.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        field.stringValue = text
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        (field.cell as? NSTextFieldCell)?.allowsUndo = false
        field.setAccessibilityLabel("Text")
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let change = NSButton(title: "Change", target: self, action: #selector(change(_:)))
        change.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, change])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [note, field, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        buttons.widthAnchor.constraint(equalTo: field.widthAnchor).isActive = true
        view = stack
    }

    @objc private func cancel(_ sender: Any?) { done(nil) }
    @objc private func change(_ sender: Any?) { done(field.stringValue) }
}

/// One line (or added text) for VoiceOver: its text as the value; pressing it starts editing.
final class PDFEditLineElement: NSAccessibilityElement {
    weak var canvas: PDFEditCanvas?
    let target: PDFEditTarget

    init(canvas: PDFEditCanvas, target: PDFEditTarget) {
        self.canvas = canvas
        self.target = target
        super.init()
    }

    /// Where the text is on screen now. (A frame set in the parent's space comes out mirrored for a flipped view,
    /// and wouldn't follow zooming and scrolling.)
    override func accessibilityFrame() -> NSRect {
        guard let canvas, let window = canvas.window else { return super.accessibilityFrame() }
        return window.convertToScreen(canvas.convert(canvas.viewBounds(target), to: nil))
    }

    override func accessibilityPerformPress() -> Bool {
        guard let canvas else { return false }
        if case .line(let id) = target, !canvas.availability(id).isEditable { return false }
        canvas.beginEditing(target.editorTarget)
        return canvas.editor != nil
    }
}
