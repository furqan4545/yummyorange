import AppKit
import CoreImage

/// The Redact window. Draw boxes over the picture; each is blurred, pixelated or blacked out live in the preview,
/// for its own stretch of time. The inspector on the right lists the boxes (+ and − below the list) and edits the
/// selected one: its style, start and end (or Whole Clip) and its size. The selected box's time range is the range on
/// the timeline: drag its ends, or press I and O at the playhead. Delete removes the selected box; everything is
/// undoable. Return or Save writes "<name> redacted.<ext>" from the original.
final class RedactVideoEditorController: MediaEditorWindowController {
    typealias Box = MediaRedact.Box

    override class var toolName: String { "Redact" }
    override var command: WheelCommand? { MediaFrameTools.redactCommand }
    override var timelineMode: MediaTimelineView.Mode { .single }
    override var hasChanges: Bool { !boxes.isEmpty }
    override var discardMessage: String { "The boxes you drew on \(source.name) haven’t been saved." }
    override var saveToolTip: String { "Save a redacted copy next to the original (⌘S)" }
    override class func check(_ source: MediaSource) throws { try MediaRedact.checkSize(source) }

    private(set) var boxes: [Box] = []
    private(set) var selected: Int?
    let overlay = MediaRedactOverlayView()
    let inspector = MediaRedactInspector()
    private let body = MediaRedactBody()
    let grabber = MediaFrameGrabber()
    private var stillCache: (image: CGImage, ci: CIImage)?

    /// The style a new box gets: the last one chosen (remembered between windows).
    private(set) var newBoxStyle: MediaRedact.Style = {
        MediaRedact.Style(rawValue: ImageExtras.remembered("media-redact")["style"] ?? "") ?? .pixelate
    }()

    var grid: CGRect { MediaFrameTools.evenGrid(source) }

    override func makeOptions() throws -> ToolOptions {
        guard !boxes.isEmpty else { throw ConversionError.unsupported("Draw a box over what you want to hide first.") }
        return ["boxes": MediaRedact.option(boxes)]
    }

    // MARK: Building

    override func makeToolItems() -> [NSToolbarItem] {
        let group = NSToolbarItemGroup(itemIdentifier: .init("redact.setEdges"), titles: ["Set Start", "Set End"],
                                       selectionMode: .momentary, labels: ["Set Start", "Set End"],
                                       target: self, action: #selector(setEdge(_:)))
        group.subitems[0].toolTip = "Start the selected box at the playhead (I)"
        group.subitems[1].toolTip = "End the selected box after the frame at the playhead (O)"
        group.label = "Set Start or End"
        return [group]
    }

    override func didBuild() {
        guard let preview else { return }
        overlay.preview = preview
        overlay.pixelSize = source.pixelSize
        overlay.grid = grid
        overlay.frame = preview.overlay.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.source = source
        overlay.frameProvider = { [weak self] in self?.currentFrame() }
        overlay.shownFrameTime = { [weak self] in self?.shownFrameTime() }
        overlay.onSelect = { [weak self] i in self?.select(i) }
        overlay.onChange = { [weak self] i, r, name in self?.changeRect(i, r, action: name) }
        overlay.onDraw = { [weak self] r in self?.addBox(r) }
        overlay.onLive = { [weak self] r in self?.inspector.showSize(r) }
        preview.overlay.addSubview(overlay)
        preview.onLayout = { [weak self] in self?.overlay.needsDisplay = true }
        preview.onStillChange = { [weak self] in self?.overlay.needsDisplay = true }

        // The inspector sits beside the picture, above the transport bar and the timeline.
        content.preview = body
        body.preview = preview
        body.inspector = inspector
        inspector.duration = source.duration
        inspector.onSelect = { [weak self] i in self?.select(i, reveal: true) }
        inspector.onStyle = { [weak self] s in self?.setStyle(s) }
        inspector.onTime = { [weak self] isStart, t in self?.setTime(isStart: isStart, typed: t) }
        inspector.onWholeClip = { [weak self] in self?.wholeClip() }
        inspector.onAdd = { [weak self] in self?.addBox(nil) }
        inspector.onRemove = { [weak self] in self?.deleteSelected() }

        // The timeline's range is the selected box's time range.
        timeline.onCommitRanges = { [weak self] new, _, name in self?.timelineCommitted(new, action: name) }
        sync()
    }

    override func previewDidLoad() {
        guard !isSnapshot, let playback else { return }
        grabber.onFrame = { [weak self] in self?.overlay.needsDisplay = true }
        // A proxy is already upright; the original's frames come out of the player as stored.
        grabber.attach(playback.player, rotation: proxyDir == nil ? source.rotation : 0)
    }

    override func forceClose() {
        grabber.stop()
        super.forceClose()
    }

    override func windowWillClose(_ notification: Notification) {
        grabber.stop()
        super.windowWillClose(notification)
    }

    /// When the frame the preview shows starts (the player's frame, once it plays); nil while a still stands in.
    func shownFrameTime() -> Double? {
        guard playerReady, grabber.playerFrame != nil else { return nil }
        return grabber.playerFrameTime
    }

    /// The picture under the boxes: the player's frame once it plays, else the still (before that, and in snapshots).
    func currentFrame() -> CIImage? {
        if playerReady, let frame = grabber.playerFrame { return frame }
        guard let still = preview?.still else { return nil }
        if let cache = stillCache, cache.image === still { return cache.ci }
        let ci = CIImage(cgImage: still)
        stillCache = (still, ci)
        return ci
    }

    // MARK: Model and Undo

    /// Commits new boxes and selection as one undoable step named `action`.
    func commit(_ new: [Box], selected sel: Int?, action: String) {
        let old = boxes, oldSelected = selected
        let sel = sel.flatMap { $0 >= 0 && $0 < new.count ? $0 : nil }
        guard new != old || sel != oldSelected else { sync(); return }
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { $0.commit(old, selected: oldSelected, action: action) }
        undo.setActionName(action)
        undo.endUndoGrouping()
        boxes = new
        selected = sel
        sync()
    }

    /// Selects a box (not undoable, like selection everywhere); `reveal` scrolls the timeline to its start.
    func select(_ i: Int?, reveal: Bool = false) {
        let i = i.flatMap { $0 >= 0 && $0 < boxes.count ? $0 : nil }
        guard i != selected else { return }
        selected = i
        sync()
        if reveal, let i { timeline.reveal(boxes[i].start) }
    }

    /// Shows the model everywhere: the overlay, the inspector, and the selected box's range on the timeline.
    private func sync() {
        overlay.boxes = boxes
        overlay.selected = selected
        overlay.playhead = playhead
        inspector.update(boxes: boxes, selected: selected, grid: grid)
        timeline.showsRanges = selected != nil
        let range = selected.map { boxes[$0].range } ?? MediaRange(start: 0, end: source.duration)
        if ranges.first != range { replaceRanges([range], selected: 0) }
        updateToolbar()
    }

    func addBox(_ rect: CGRect?) {
        let g = grid
        let r = rect ?? CGRect(x: g.width / 3, y: g.height / 3, width: g.width / 3, height: g.height / 3)
        var all = boxes
        all.append(Box(rect: MediaRedact.normalized(r, in: g), style: newBoxStyle, start: 0, end: source.duration))
        commit(all, selected: all.count - 1, action: "Add Box")
    }

    func deleteSelected() {
        guard let i = selected else { NSSound.beep(); return }
        var all = boxes
        all.remove(at: i)
        commit(all, selected: all.isEmpty ? nil : min(i, all.count - 1), action: "Delete Box")
    }

    private func changeRect(_ i: Int, _ r: CGRect, action: String) {
        guard i < boxes.count else { return }
        var all = boxes
        all[i].rect = MediaRedact.normalized(r, in: grid)
        commit(all, selected: i, action: action)
    }

    func setStyle(_ style: MediaRedact.Style) {
        newBoxStyle = style
        ImageExtras.remember(["style": style.rawValue], as: "media-redact")
        guard let i = selected else { return }
        var all = boxes
        all[i].style = style
        commit(all, selected: i, action: "Change Style")
    }

    private func wholeClip() {
        guard let i = selected else { NSSound.beep(); return }
        var all = boxes
        all[i].start = 0
        all[i].end = source.duration
        commit(all, selected: i, action: "Whole Clip")
    }

    private func setRange(_ r: MediaRange, action: String) {
        guard let i = selected else { NSSound.beep(); return }
        var all = boxes
        all[i].start = r.start
        all[i].end = r.end
        commit(all, selected: i, action: action)
    }

    private func timelineCommitted(_ new: [MediaRange], action: String) {
        guard selected != nil, let r = new.first else { sync(); return }
        setRange(r, action: action)
    }

    /// I: the selected box starts at the playhead (if that's past its end, it runs to the end of the clip), so that
    /// the frame on screen is the first one covered. The player can show a frame that started before the playhead's
    /// grid time (ffmpeg rounds NTSC rates, so a 23.976 fps grid drifts; the player's time rounding; a frame held
    /// longer in variable-rate video): then the box starts with that frame, or the saved file would leave it bare.
    func setStart() {
        guard let i = selected else { NSSound.beep(); return }
        var t = source.snap(playhead)
        let fd = source.frameDuration
        guard t < source.duration - fd / 2 else { NSSound.beep(); return }
        // The grabber's frame is the one for this playhead when it was taken there (a held frame can have started
        // long before; the player sits `seekNudge` past the playhead), or when it started within a frame and a half
        // (else it may be from before a seek).
        if let shown = shownFrameTime(), shown < t,
           t - shown < fd * 1.5 || abs((grabber.playerItemTime ?? -1) - playhead - (playback?.seekNudge ?? 0)) < 1e-3 { t = max(0, shown) }
        var r = boxes[i].range
        if t >= r.end - fd / 2 { r.end = source.duration }
        r.start = t
        setRange(r, action: "Set Start")
    }

    /// O: the selected box ends after the frame under the playhead (that frame is still covered).
    func setEnd() {
        guard let i = selected else { NSSound.beep(); return }
        let fd = source.frameDuration
        let end = source.snapEnd(min(source.duration, source.snap(playhead) + fd))
        var r = boxes[i].range
        if end <= r.start + fd / 2 { r.start = 0 }
        r.end = end
        setRange(r, action: "Set End")
    }

    /// A start or end typed in the inspector: snapped to a frame and checked; one that doesn't fit beeps.
    private func setTime(isStart: Bool, typed: String) {
        guard let i = selected else { return }
        let fd = source.frameDuration
        guard let v = MediaTime.parse(typed) else { NSSound.beep(); sync(); return }
        var r = boxes[i].range
        if isStart {
            let t = source.snap(min(v, source.duration))
            guard t < r.end - fd / 2 else { NSSound.beep(); sync(); return }
            r.start = t
        } else {
            let t = source.snapEnd(min(v, source.duration))
            guard t > r.start + fd / 2 else { NSSound.beep(); sync(); return }
            r.end = t
        }
        guard r != boxes[i].range else { sync(); return }
        setRange(r, action: isStart ? "Set Start" : "Set End")
        scrub(to: isStart ? r.start : max(r.start, source.snap(r.end - fd)))
    }

    @objc private func setEdge(_ sender: NSToolbarItemGroup) {
        sender.selectedIndex == 0 ? setStart() : setEnd()
    }

    // MARK: Kit hooks

    override func playheadDidChange() { overlay.playhead = playhead }

    override func rangesDidChange(live: Bool) {
        if !live { inspector.showTimes(selected.map { boxes[$0].range }) }
    }

    override func updateLiveReadouts(_ live: [MediaRange]) {
        if selected != nil, let r = live.first { inspector.showTimes(r) }
    }

    override func handleKey(_ event: NSEvent) -> Bool {
        keyBelongsToFocusedControl(event) ? false : super.handleKey(event)
    }

    override func handleToolKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.keyCode {
        case 53:                                                 // Esc: a drag, else the selection
            if overlay.isDragging { overlay.cancelDrag(); return true }
            if timeline.isDragging { return false }
            if selected != nil { select(nil); return true }
            return false
        case 36, 76:                                             // Return, Enter
            guard flags.isEmpty else { return false }
            save()
            return true
        case 51, 117:                                            // ⌫ ⌦
            deleteSelected()
            return true
        case 123...126 where flags.contains(.option):    // ⌥ arrows move the box (⇧ ten times as far)
            guard let i = selected else { NSSound.beep(); return true }
            let step: CGFloat = flags.contains(.shift) ? 20 : 2
            let d: CGVector = event.keyCode == 123 ? CGVector(dx: -step, dy: 0) : event.keyCode == 124 ? CGVector(dx: step, dy: 0)
                : event.keyCode == 126 ? CGVector(dx: 0, dy: -step) : CGVector(dx: 0, dy: step)
            changeRect(i, MediaBoxGeometry.moved(boxes[i].rect, by: d, in: grid), action: "Move Box")
            return true
        default:
            break
        }
        guard flags.isEmpty else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "i": setStart(); return true
        case "o": setEnd(); return true
        default: return false
        }
    }

    // MARK: Snapshot

    /// boxes (the `boxes` option's format, or "none"; default: a Pixelate box over the whole clip and a Blur box from
    /// 1 s to 3 s) and selected (1-based, 0 for none; default the last box).
    override func applySnapshotOptions(_ options: ToolOptions) {
        var list: [Box]
        if options["boxes"] == "none" {
            list = []
        } else if let text = options["boxes"], let parsed = try? MediaRedact.parse(text, source: source) {
            list = parsed
        } else {
            let g = grid
            func frac(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                MediaRedact.normalized(CGRect(x: g.width * x, y: g.height * y, width: g.width * w, height: g.height * h), in: g)
            }
            list = [Box(rect: frac(0.625, 0.61, 0.25, 0.27), style: .pixelate, start: 0, end: source.duration),
                    Box(rect: frac(0.13, 0.36, 0.22, 0.4), style: .blur, start: min(1, source.duration / 4),
                        end: min(source.duration, max(3, source.duration * 3 / 4)))]
        }
        let pick = options.int("selected", list.count)
        boxes = list
        selected = pick >= 1 && pick <= list.count ? pick - 1 : nil
        sync()
        undo.removeAllActions()
    }
}

// MARK: - Body: the picture with the inspector beside it

final class MediaRedactBody: NSView {
    var preview: NSView? { didSet { oldValue?.removeFromSuperview(); if let preview { addSubview(preview) }; needsLayout = true } }
    var inspector: NSView? { didSet { oldValue?.removeFromSuperview(); if let inspector { addSubview(inspector) }; needsLayout = true } }
    static let inspectorWidth: CGFloat = 268

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = Self.inspectorWidth
        preview?.frame = CGRect(x: 0, y: 0, width: max(0, bounds.width - w), height: bounds.height)
        inspector?.frame = CGRect(x: max(0, bounds.width - w), y: 0, width: w, height: bounds.height)
    }
}

// MARK: - Overlay

/// The boxes over the picture. A box whose time range holds the playhead shows its effect (from the frame on
/// screen); one outside its range shows only a dashed outline. The selected box has an accent outline and knobs.
/// Drag a knob to resize, inside a box to select and move it, on empty picture to draw a new box; click empty picture
/// to deselect. Esc during a drag puts it back.
final class MediaRedactOverlayView: MediaFrameOverlayView {
    typealias Box = MediaRedact.Box

    var pixelSize: CGSize = .zero
    var grid: CGRect = .zero
    var boxes: [Box] = [] { didSet { if drag == nil { live = boxes }; needsDisplay = true; rebuildAccessibility() } }
    var selected: Int? { didSet { needsDisplay = true } }
    var playhead: Double = 0 { didSet { if playhead != oldValue { needsDisplay = true } } }
    var frameProvider: (() -> CIImage?)?
    /// When the frame under the boxes starts (nil while a still stands in, and in snapshots).
    var shownFrameTime: (() -> Double?)?
    var source: MediaSource?
    var onSelect: ((Int?) -> Void)?
    var onChange: ((Int, CGRect, String) -> Void)?
    var onDraw: ((CGRect) -> Void)?
    var onLive: ((CGRect) -> Void)?

    private enum Drag {
        case handle(Int, MediaBoxGeometry.Handle, start: CGRect)
        case move(Int, start: CGRect, from: CGPoint)
        case draw(anchor: CGPoint)
    }
    private var drag: Drag?
    private var moved = false
    private var downPoint: CGPoint = .zero
    private var live: [Box] = []
    private var drawing: CGRect?
    var isDragging: Bool { drag != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Redaction boxes")
        setAccessibilityHelp("Drag across the picture to add a box. Drag a box to move it, its corners to resize it.")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Drawing

    /// Whether `b` covers the picture on screen. With the player's frame, decided from that frame's own time by the
    /// saved file's rule (MediaRedact.covers), so the preview never shows a frame covered that the file leaves bare;
    /// with a still (taken from the playhead on), from the playhead.
    func isCovering(_ b: Box) -> Bool {
        if let source, let t = shownFrameTime?() { return MediaRedact.covers(b, frameAt: t, source: source) }
        return b.isActive(at: playhead)
    }

    override func draw(_ dirtyRect: NSRect) {
        let picture = pictureRect
        guard picture.width > 0 else { return }
        let covering = live.map(isCovering)
        let needsFrame = live.indices.contains { live[$0].style != .black && covering[$0] }
        let frame = needsFrame ? frameProvider?() : nil
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: picture).addClip()
        for (i, b) in live.enumerated() {
            let r = viewRect(b.rect)
            if covering[i] {
                MediaRedactRenderer.draw(b, frame: frame, pixelSize: pixelSize, in: r)
            } else {
                // Not covering anything at this time: a light veil and a dashed outline say where it will be.
                NSColor.white.withAlphaComponent(0.12).setFill()
                r.fill(using: .sourceOver)
            }
            outline(r, selected: i == selected, active: covering[i])
            tag(i + 1, in: r, selected: i == selected)
        }
        NSGraphicsContext.restoreGraphicsState()
        if let s = selected, s < live.count {
            MediaFrameOverlayView.drawKnobs(viewRect(live[s].rect), edges: true, ring: MediaColors.accent)
        }
        if let drawing {
            let r = viewRect(drawing)
            MediaColors.accent.withAlphaComponent(0.18).setFill()
            r.fill(using: .sourceOver)
            let path = NSBezierPath(rect: r.insetBy(dx: 0.75, dy: 0.75))
            path.lineWidth = 1.5
            MediaColors.accent.setStroke()
            path.stroke()
        }
    }

    private func outline(_ r: CGRect, selected: Bool, active: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 2
        shadow.set()
        let path = NSBezierPath(rect: r.insetBy(dx: selected ? 1 : 0.5, dy: selected ? 1 : 0.5))
        path.lineWidth = selected ? 2 : 1
        if !active { path.setLineDash([5, 3], count: 2, phase: 0) }
        (selected ? MediaColors.accent : NSColor.white.withAlphaComponent(0.9)).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The box's number in its top-left corner (the same number as in the list).
    private func tag(_ n: Int, in r: CGRect, selected: Bool) {
        guard r.width >= 30, r.height >= 24 else { return }
        let text = "\(n)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                                                    .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let chip = CGRect(x: r.minX + 5, y: r.minY + 5, width: max(18, size.width + 10), height: 17)
        (selected ? MediaColors.accent : NSColor.black.withAlphaComponent(0.6)).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: chip.midX - size.width / 2, y: chip.midY - size.height / 2), withAttributes: attrs)
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func topBox(at p: CGPoint) -> Int? {
        live.indices.reversed().first { viewRect(live[$0].rect).contains(p) }
    }

    private func cursor(at p: CGPoint) -> NSCursor {
        if let s = selected, s < live.count, let h = MediaBoxGeometry.handle(at: p, of: viewRect(live[s].rect)) { return h.cursor }
        if topBox(at: p) != nil { return isDragging ? .closedHand : .openHand }
        return pictureRect.contains(p) ? .crosshair : .arrow
    }

    override func cursorUpdate(with event: NSEvent) { cursor(at: location(event)).set() }
    override func mouseMoved(with event: NSEvent) { if !isDragging { cursor(at: location(event)).set() } }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = location(event)
        downPoint = p
        moved = false
        live = boxes
        if let s = selected, s < live.count, let h = MediaBoxGeometry.handle(at: p, of: viewRect(live[s].rect)) {
            drag = .handle(s, h, start: live[s].rect)
        } else if let i = topBox(at: p) {
            if i != selected { onSelect?(i) }
            drag = .move(i, start: live[i].rect, from: pixelPoint(p))
            NSCursor.closedHand.set()
        } else if pictureRect.contains(p) {
            drag = .draw(anchor: MediaBoxGeometry.clamp(pixelPoint(p), to: grid))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let p = location(event)
        if !moved, hypot(p.x - downPoint.x, p.y - downPoint.y) < 3 { return }
        moved = true
        let px = pixelPoint(p)
        let square: CGFloat? = event.modifierFlags.contains(.shift) ? (pixelSize.width > 0 ? 1 : nil) : nil
        switch drag {
        case .handle(let i, let h, let start):
            live[i].rect = MediaBoxGeometry.resize(start, handle: h, to: px, ratio: square.map { _ in start.width / max(1, start.height) },
                                                   bounds: grid, minSide: MediaRedact.minimumSide)
            onLive?(live[i].rect)
        case .move(let i, let start, let from):
            live[i].rect = MediaBoxGeometry.moved(start, by: CGVector(dx: px.x - from.x, dy: px.y - from.y), in: grid)
            onLive?(live[i].rect)
        case .draw(let anchor):
            drawing = MediaBoxGeometry.drawn(from: anchor, to: px, ratio: square, bounds: grid, minSide: 1)
            if let drawing { onLive?(drawing) }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let current = drag else { return }
        drag = nil
        let result = live
        let drawn = drawing
        live = boxes
        drawing = nil
        needsDisplay = true
        cursor(at: location(event)).set()
        switch current {
        case .handle(let i, _, _):
            if moved { onChange?(i, result[i].rect, "Resize Box") }
        case .move(let i, _, _):
            if moved { onChange?(i, result[i].rect, "Move Box") }
        case .draw:
            if moved, let drawn, drawn.width >= 4, drawn.height >= 4 { onDraw?(drawn) } else { onSelect?(nil) }
        }
    }

    func cancelDrag() {
        guard drag != nil else { return }
        drag = nil
        live = boxes
        drawing = nil
        needsDisplay = true
        if let s = selected, s < boxes.count { onLive?(boxes[s].rect) }
    }

    // MARK: Accessibility

    private func rebuildAccessibility() {
        let elements: [NSAccessibilityElement] = boxes.indices.map { MediaBoxAXElement(overlay: self, index: $0) }
        setAccessibilityChildren(elements)
    }

    /// VoiceOver's description and on-screen frame of box `i` (read when asked, so they follow layout).
    func axLabel(_ i: Int) -> String {
        guard i < boxes.count else { return "" }
        return "Box \(i + 1), \(boxes[i].style.title)\(i == selected ? ", selected" : "")"
    }

    func axValue(_ i: Int) -> String {
        guard i < boxes.count else { return "" }
        let b = boxes[i]
        return "\(MediaFrameTools.number(b.rect.width)) × \(MediaFrameTools.number(b.rect.height)) pixels, "
            + "\(MediaTime.string(b.start)) to \(MediaTime.string(b.end))"
    }

    func axFrame(_ i: Int) -> CGRect {
        guard i < boxes.count, window != nil else { return .zero }
        return NSAccessibility.screenRect(fromView: self, rect: viewRect(boxes[i].rect).intersection(pictureRect))
    }

    func axSelect(_ i: Int) { onSelect?(i) }
}

// MARK: - Inspector

/// The list of boxes (+ and − below it) and the selected box's style, time and size.
final class MediaRedactInspector: ImageEditors.FillView, NSTableViewDataSource, NSTableViewDelegate {
    var duration: Double = 0
    var onSelect: ((Int?) -> Void)?
    var onStyle: ((MediaRedact.Style) -> Void)?
    var onTime: ((_ isStart: Bool, _ text: String) -> Void)?
    var onWholeClip: (() -> Void)?
    var onAdd: (() -> Void)?
    var onRemove: (() -> Void)?

    private(set) var boxes: [MediaRedact.Box] = []
    private(set) var selected: Int?
    let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Drag across the picture to cover a face, a name or a number plate.")
    let addButton = NSButton()
    let removeButton = NSButton()
    private let listBox = MediaListBox()
    let styleControl = NSSegmentedControl(labels: MediaRedact.Style.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let startField = MediaTimeField(label: "Start")
    let endField = MediaTimeField(label: "End")
    let wholeClipButton = NSButton(title: "Whole Clip", target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "")
    private let styleLabel = NSTextField(labelWithString: "Style")
    private let timeLabel = NSTextField(labelWithString: "Time")
    private let sizeTitle = NSTextField(labelWithString: "Size")
    private var reloading = false

    init() {
        super.init(color: ImageEditors.Style.chrome, hairlines: [.minX])
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let header = NSTextField(labelWithString: "Boxes")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .labelColor

        let column = NSTableColumn(identifier: .init("box"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 28
        table.intercellSpacing = CGSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Boxes")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        // + and − at the bottom of the list's box, as in System Settings.
        for (button, symbol, label, tip, action) in [
            (addButton, "plus", "Add Box", "Add a box in the middle of the picture", #selector(addClicked)),
            (removeButton, "minus", "Delete Box", "Delete the selected box (⌫)", #selector(removeClicked)),
        ] as [(NSButton, String, String, String, Selector)] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.bezelStyle = .smallSquare
            button.toolTip = tip
            button.setAccessibilityLabel(label)
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        listBox.translatesAutoresizingMaskIntoConstraints = false
        let listDivider = ImageEditors.FillView(color: ImageEditors.Style.hairline)
        listDivider.translatesAutoresizingMaskIntoConstraints = false
        let buttonDivider = ImageEditors.FillView(color: ImageEditors.Style.hairline)
        buttonDivider.translatesAutoresizingMaskIntoConstraints = false
        for v in [scroll, emptyLabel, listDivider, addButton, buttonDivider, removeButton] as [NSView] { listBox.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: listBox.topAnchor, constant: 1),
            scroll.leadingAnchor.constraint(equalTo: listBox.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: listBox.trailingAnchor, constant: -1),
            listDivider.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            listDivider.leadingAnchor.constraint(equalTo: listBox.leadingAnchor, constant: 1),
            listDivider.trailingAnchor.constraint(equalTo: listBox.trailingAnchor, constant: -1),
            listDivider.heightAnchor.constraint(equalToConstant: 1),
            addButton.topAnchor.constraint(equalTo: listDivider.bottomAnchor, constant: 1),
            addButton.leadingAnchor.constraint(equalTo: listBox.leadingAnchor, constant: 4),
            addButton.bottomAnchor.constraint(equalTo: listBox.bottomAnchor, constant: -1),
            buttonDivider.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 1),
            buttonDivider.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            buttonDivider.widthAnchor.constraint(equalToConstant: 1),
            buttonDivider.heightAnchor.constraint(equalToConstant: 14),
            removeButton.leadingAnchor.constraint(equalTo: buttonDivider.trailingAnchor, constant: 1),
            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: listBox.leadingAnchor, constant: 18),
            emptyLabel.trailingAnchor.constraint(equalTo: listBox.trailingAnchor, constant: -18),
        ])

        styleControl.target = self
        styleControl.action = #selector(styleChosen)
        styleControl.segmentDistribution = .fillEqually
        styleControl.setAccessibilityLabel("Style")
        styleControl.translatesAutoresizingMaskIntoConstraints = false
        for f in [startField, endField] {
            f.target = self
            f.action = #selector(timeCommitted(_:))
        }
        wholeClipButton.target = self
        wholeClipButton.action = #selector(wholeClipClicked)
        wholeClipButton.bezelStyle = .rounded
        wholeClipButton.controlSize = .small
        wholeClipButton.toolTip = "Cover the whole clip"
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.setAccessibilityLabel("Size in video pixels")
        for l in [styleLabel, timeLabel, sizeTitle] {
            l.font = .systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            l.alignment = .right
        }
        let dash = NSTextField(labelWithString: "–")
        dash.textColor = .secondaryLabelColor

        let times = NSStackView(views: [startField, dash, endField])
        times.spacing = 4
        let grid = NSGridView(views: [
            [styleLabel, styleControl],
            [timeLabel, times],
            [NSGridCell.emptyContentView, wholeClipButton],
            [sizeTitle, sizeLabel],
        ])
        grid.columnSpacing = 8
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 36
        grid.rowAlignment = .firstBaseline
        grid.row(at: 2).topPadding = -4
        grid.translatesAutoresizingMaskIntoConstraints = false

        header.translatesAutoresizingMaskIntoConstraints = false

        for v in [header, listBox, grid] as [NSView] { addSubview(v) }
        let pad: CGFloat = 16
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            listBox.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            listBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            listBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            grid.topAnchor.constraint(equalTo: listBox.bottomAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            styleControl.widthAnchor.constraint(equalToConstant: 188),
        ])
        update(boxes: [], selected: nil, grid: .zero)
    }

    // MARK: Showing the model

    func update(boxes: [MediaRedact.Box], selected: Int?, grid: CGRect) {
        reloading = true
        defer { reloading = false }
        self.boxes = boxes
        self.selected = selected
        table.reloadData()
        if let selected { table.selectRowIndexes([selected], byExtendingSelection: false); table.scrollRowToVisible(selected) }
        else { table.deselectAll(nil) }
        emptyLabel.isHidden = !boxes.isEmpty
        removeButton.isEnabled = selected != nil
        let box = selected.map { boxes[$0] }
        for c in [styleControl, startField, endField, wholeClipButton] as [NSControl] { c.isEnabled = box != nil }
        for l in [styleLabel, timeLabel, sizeTitle] { l.textColor = box != nil ? .secondaryLabelColor : .tertiaryLabelColor }
        if let box, let i = MediaRedact.Style.allCases.firstIndex(of: box.style) {
            styleControl.selectedSegment = i
        } else {
            styleControl.selectedSegment = -1
        }
        showTimes(box?.range)
        if let box { showSize(box.rect) } else {
            sizeLabel.stringValue = "—"
            sizeLabel.textColor = .tertiaryLabelColor
        }
        wholeClipButton.isEnabled = box.map { $0.start > 0.0005 || $0.end < duration - 0.0005 } ?? false
    }

    func showTimes(_ r: MediaRange?) {
        if startField.currentEditor() == nil { startField.stringValue = r.map { MediaTime.string($0.start) } ?? "" }
        if endField.currentEditor() == nil { endField.stringValue = r.map { MediaTime.string($0.end) } ?? "" }
    }

    func showSize(_ r: CGRect) {
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.stringValue = "\(MediaFrameTools.number(r.width)) × \(MediaFrameTools.number(r.height)) px  at "
            + "\(MediaFrameTools.number(r.minX)), \(MediaFrameTools.number(r.minY))"
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { boxes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: MediaRedactBoxCell.id, owner: nil) as? MediaRedactBoxCell) ?? MediaRedactBoxCell()
        let b = boxes[row]
        let whole = b.start <= 0.0005 && b.end >= duration - 0.0005
        cell.configure(number: row + 1, style: b.style.title,
                       time: whole ? "Whole clip" : "\(MediaTime.string(b.start)) – \(MediaTime.string(b.end))")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading else { return }
        let row = table.selectedRow
        onSelect?(row >= 0 ? row : nil)
    }

    // MARK: Actions

    @objc private func addClicked() { onAdd?() }
    @objc private func removeClicked() { onRemove?() }

    @objc private func styleChosen() {
        let all = MediaRedact.Style.allCases
        guard styleControl.selectedSegment >= 0, styleControl.selectedSegment < all.count else { return }
        onStyle?(all[styleControl.selectedSegment])
    }

    @objc private func timeCommitted(_ sender: MediaTimeField) {
        guard !reloading, selected != nil else { return }
        onTime?(sender === startField, sender.stringValue)
    }

    @objc private func wholeClipClicked() { onWholeClip?() }
}

/// One row of the box list: the box's number (as tagged on the picture), its style and its time.
final class MediaRedactBoxCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("MediaRedactBoxCell")
    private let badge = NSTextField(labelWithString: "")
    private let styleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 240, height: 30))
        identifier = Self.id
        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        badge.alignment = .center
        styleLabel.font = .systemFont(ofSize: 13)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .right
        timeLabel.lineBreakMode = .byTruncatingHead
        styleLabel.lineBreakMode = .byTruncatingTail
        for v in [badge, styleLabel, timeLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        textField = styleLabel
        timeLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        styleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 20),
            styleLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            styleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: styleLabel.trailingAnchor, constant: 8),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(number: Int, style: String, time: String) {
        badge.stringValue = "\(number)"
        styleLabel.stringValue = style
        timeLabel.stringValue = time
        setAccessibilityLabel("Box \(number), \(style), \(time)")
        needsDisplay = true
    }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // The number sits on a small chip, like the tag on the picture.
            let chip = badge.frame.insetBy(dx: 0, dy: -1.5).integral
            let emphasized = backgroundStyle == .emphasized
            (emphasized ? NSColor.white.withAlphaComponent(0.25) : NSColor.labelColor.withAlphaComponent(0.1)).setFill()
            NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        }
    }
}

/// A list's rounded box: the control background with a hairline edge (the list, then + and − below a divider).
final class MediaListBox: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let r = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
            ImageEditors.Style.dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.05)).setFill()
            path.fill()
            ImageEditors.Style.hairline.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// One redaction box for VoiceOver: its number, style, size and time; pressing it selects it.
final class MediaBoxAXElement: NSAccessibilityElement {
    private weak var overlay: MediaRedactOverlayView?
    private let index: Int

    init(overlay: MediaRedactOverlayView, index: Int) {
        self.overlay = overlay
        self.index = index
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityParent(overlay)
    }

    override func accessibilityLabel() -> String? { overlay?.axLabel(index) }
    override func accessibilityValue() -> Any? { overlay?.axValue(index) }
    override func accessibilityFrame() -> NSRect { overlay?.axFrame(index) ?? .zero }
    override func accessibilityParent() -> Any? { overlay }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool { overlay?.axSelect(index); return true }
}
