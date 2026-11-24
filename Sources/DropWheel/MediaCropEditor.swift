import AppKit

/// The Crop window: a crop frame over the picture (corners and edges resize, inside moves, a drag outside draws a new
/// one), the aspect pop-up and Reset in the toolbar, the size in video pixels in the transport bar, and the film strip
/// to check other frames. Return or Save writes "<name> cropped.<ext>" from the original.
final class CropVideoEditorController: MediaEditorWindowController {
    struct State: Equatable {
        var rect: CGRect
        var aspect: MediaCrop.Aspect
    }

    override class var toolName: String { "Crop" }
    override var command: WheelCommand? { MediaFrameTools.cropCommand }
    override var timelineMode: MediaTimelineView.Mode { .none }
    override var discardMessage: String { "The crop you set for \(source.name) hasn’t been saved." }
    override var saveToolTip: String { "Save a cropped copy next to the original (⌘S)" }
    override class func check(_ source: MediaSource) throws { try MediaCrop.checkSize(source) }

    private(set) var state: State
    let overlay = MediaCropOverlayView()
    private let aspectPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeLabel = NSTextField(labelWithString: "")

    /// The whole picture on even pixels: what "no crop" is.
    var fullRect: CGRect { MediaFrameTools.evenGrid(source) }
    override var hasChanges: Bool { state.rect != fullRect }

    required init(source: MediaSource, snapshot: Bool) {
        state = State(rect: MediaFrameTools.evenGrid(source), aspect: .free)
        super.init(source: source, snapshot: snapshot)
    }

    override func makeOptions() throws -> ToolOptions {
        let r = state.rect
        return ["x": MediaFrameTools.number(r.minX), "y": MediaFrameTools.number(r.minY),
                "w": MediaFrameTools.number(r.width), "h": MediaFrameTools.number(r.height)]
    }

    // MARK: Toolbar and transport

    override func makeToolItems() -> [NSToolbarItem] {
        aspectPopup.addItems(withTitles: MediaCrop.Aspect.allCases.map(\.title))
        // The button shows an aspect-ratio symbol before the choice, so it reads as "shape" without opening it.
        if let cell = aspectPopup.cell as? NSPopUpButtonCell {
            cell.usesItemFromMenu = false
            cell.menuItem = NSMenuItem(title: state.aspect.title, action: nil, keyEquivalent: "")
            cell.menuItem?.image = NSImage(systemSymbolName: "aspectratio", accessibilityDescription: nil)
            cell.imagePosition = .imageLeading
        }
        aspectPopup.target = self
        aspectPopup.action = #selector(aspectChosen)
        aspectPopup.toolTip = "Shape of the crop"
        aspectPopup.setAccessibilityLabel("Aspect ratio")
        let aspect = NSToolbarItem(itemIdentifier: .init("crop.aspect"))
        aspect.view = aspectPopup
        aspect.label = "Aspect Ratio"
        let menu = NSMenuItem(title: "Aspect Ratio", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (i, a) in MediaCrop.Aspect.allCases.enumerated() {
            let item = NSMenuItem(title: a.title, action: #selector(aspectMenuChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            sub.addItem(item)
        }
        menu.submenu = sub
        aspect.menuFormRepresentation = menu

        let reset = NSToolbarItem(itemIdentifier: .init("crop.reset"))
        reset.label = "Reset"
        reset.title = "Reset"
        reset.toolTip = "Keep the whole picture again"
        reset.target = self
        reset.action = #selector(resetAction)
        reset.isBordered = true
        reset.autovalidates = false
        return [aspect, reset]
    }

    override func makeTransportAccessory() -> NSView? {
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .right
        sizeLabel.setAccessibilityLabel("Crop size in video pixels")
        sizeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        sizeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        return sizeLabel
    }

    override func didBuild() {
        guard let preview else { return }
        overlay.preview = preview
        overlay.source = source
        overlay.frame = preview.overlay.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.onLive = { [weak self] r in self?.showSize(r) }
        overlay.onCommit = { [weak self] r, name in self?.commitRect(r, action: name) }
        preview.overlay.addSubview(overlay)
        preview.onLayout = { [weak self] in
            self?.overlay.needsDisplay = true
            self?.overlay.updateAccessibility()
        }
        apply(state)
    }

    // MARK: State and Undo

    /// Commits `new` as one undoable step named `action`.
    func commit(_ new: State, action: String) {
        let old = state
        guard new != old else { apply(old); return }
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { $0.commit(old, action: action) }
        undo.setActionName(action)
        undo.endUndoGrouping()
        apply(new)
    }

    private func apply(_ s: State) {
        state = s
        overlay.rect = s.rect
        overlay.ratio = s.aspect.pixelRatio(source)
        if let i = MediaCrop.Aspect.allCases.firstIndex(of: s.aspect), aspectPopup.indexOfSelectedItem != i { aspectPopup.selectItem(at: i) }
        if let cell = aspectPopup.cell as? NSPopUpButtonCell, cell.menuItem?.title != s.aspect.title {
            cell.menuItem?.title = s.aspect.title
            aspectPopup.needsDisplay = true
        }
        aspectPopup.setAccessibilityValue(s.aspect.title)
        showSize(s.rect)
        updateToolbar()
    }

    private func commitRect(_ r: CGRect, action: String) {
        var s = state
        s.rect = MediaCrop.even(r, in: fullRect)
        commit(s, action: action)
    }

    private func showSize(_ r: CGRect) {
        let e = MediaCrop.even(r, in: fullRect)
        let size = "\(MediaFrameTools.number(e.width)) × \(MediaFrameTools.number(e.height))"
        let text = NSMutableAttributedString(string: size, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: " px  at \(MediaFrameTools.number(e.minX)), \(MediaFrameTools.number(e.minY))", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
        sizeLabel.attributedStringValue = text
        sizeLabel.setAccessibilityValue("\(size) pixels, at \(MediaFrameTools.number(e.minX)), \(MediaFrameTools.number(e.minY))")
    }

    /// A fixed shape makes the crop the largest of that shape around its current centre.
    func setAspect(_ aspect: MediaCrop.Aspect) {
        var s = state
        s.aspect = aspect
        if let ratio = aspect.pixelRatio(source) {
            let full = fullRect
            s.rect = MediaCrop.even(MediaBoxGeometry.largest(ratio: ratio, in: full, around: CGPoint(x: state.rect.midX, y: state.rect.midY)), in: full)
        }
        commit(s, action: "Change Aspect Ratio")
    }

    @objc private func aspectChosen() {
        let all = MediaCrop.Aspect.allCases
        let i = aspectPopup.indexOfSelectedItem
        guard i >= 0, i < all.count else { return }
        setAspect(all[i])
    }

    @objc private func aspectMenuChosen(_ sender: NSMenuItem) {
        let all = MediaCrop.Aspect.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        setAspect(all[sender.tag])
    }

    @objc private func resetAction() { reset() }

    func reset() { commit(State(rect: fullRect, aspect: .free), action: "Reset Crop") }

    // MARK: Keys

    override func handleKey(_ event: NSEvent) -> Bool {
        keyBelongsToFocusedControl(event) ? false : super.handleKey(event)
    }

    override func handleToolKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.keyCode {
        case 53 where overlay.isDragging:                       // Esc
            overlay.cancelDrag()
            return true
        case 36, 76:                                             // Return, Enter
            guard flags.isEmpty else { return false }
            save()
            return true
        case 123...126 where flags.contains(.option):    // ⌥ arrows move the crop (⇧ ten times as far)
            let step: CGFloat = flags.contains(.shift) ? 20 : 2
            let d: CGVector = event.keyCode == 123 ? CGVector(dx: -step, dy: 0) : event.keyCode == 124 ? CGVector(dx: step, dy: 0)
                : event.keyCode == 126 ? CGVector(dx: 0, dy: -step) : CGVector(dx: 0, dy: step)
            commitRect(MediaBoxGeometry.moved(state.rect, by: d, in: fullRect), action: "Move Crop")
            return true
        default:
            return false
        }
    }

    // MARK: Snapshot

    /// x, y, w, h (video pixels) and aspect; without them, the centred square the command line uses.
    override func applySnapshotOptions(_ options: ToolOptions) {
        let aspect = options["aspect"].flatMap(MediaCrop.Aspect.init(option:))
        if options["x"] != nil || options["w"] != nil, let r = try? MediaCrop.rect(options, source: source) {
            apply(State(rect: r, aspect: aspect ?? .free))
        } else if let aspect, let ratio = aspect.pixelRatio(source) {
            apply(State(rect: MediaCrop.even(MediaBoxGeometry.largest(ratio: ratio, in: fullRect, around: CGPoint(x: fullRect.midX, y: fullRect.midY)), in: fullRect), aspect: aspect))
        } else {
            apply(State(rect: MediaCrop.defaultRect(source), aspect: .square))
        }
        undo.removeAllActions()
    }
}

// MARK: - Overlay

/// The crop frame over the picture: outside dimmed, a white frame with corner and edge grips, thirds while dragging.
/// Corners and edges resize (with the aspect kept when one is set, or with ⇧ for the current shape), inside moves,
/// a drag outside the frame draws a new one. Esc during a drag puts it back.
final class MediaCropOverlayView: MediaFrameOverlayView {
    var source: MediaSource?
    /// The crop in video pixels (as committed; during a drag `live` is drawn).
    var rect: CGRect = .zero { didSet { if !isDragging { live = rect }; needsDisplay = true; updateAccessibility() } }
    /// Width ÷ height in pixels, nil for Free.
    var ratio: CGFloat?
    var onLive: ((CGRect) -> Void)?
    var onCommit: ((CGRect, String) -> Void)?

    private enum Drag {
        case handle(MediaBoxGeometry.Handle, start: CGRect)
        case move(start: CGRect, from: CGPoint)
        case draw(anchor: CGPoint)
    }
    private var drag: Drag?
    private var moved = false
    private var downPoint: CGPoint = .zero
    private(set) var live: CGRect = .zero
    var isDragging: Bool { drag != nil }

    private var grid: CGRect {
        guard let source else { return .zero }
        return MediaFrameTools.evenGrid(source)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutItem)
        setAccessibilityLabel("Crop area")
        setAccessibilityHelp("Drag the corners or edges to resize, drag inside to move. Option and the arrow keys move it.")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func updateAccessibility() {
        let r = MediaCrop.even(live, in: grid)
        setAccessibilityValue("\(MediaFrameTools.number(r.width)) × \(MediaFrameTools.number(r.height)) pixels at "
                              + "\(MediaFrameTools.number(r.minX)), \(MediaFrameTools.number(r.minY))")
    }

    override func accessibilityFrame() -> NSRect {
        guard window != nil else { return .zero }
        return NSAccessibility.screenRect(fromView: self, rect: viewRect(live))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let picture = pictureRect
        guard picture.width > 0 else { return }
        let r = viewRect(live).intersection(picture)
        // Outside the crop: dimmed, so the kept part reads at a glance (in both appearances: it's over the picture).
        let dim = NSBezierPath(rect: picture)
        dim.append(NSBezierPath(rect: r))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        dim.fill()

        if isDragging {
            // Thirds, as in Photos, while the frame is being adjusted.
            let thirds = NSBezierPath()
            for k in 1...2 {
                let x = (r.minX + r.width * CGFloat(k) / 3).rounded() + 0.5, y = (r.minY + r.height * CGFloat(k) / 3).rounded() + 0.5
                thirds.move(to: CGPoint(x: x, y: r.minY)); thirds.line(to: CGPoint(x: x, y: r.maxY))
                thirds.move(to: CGPoint(x: r.minX, y: y)); thirds.line(to: CGPoint(x: r.maxX, y: y))
            }
            thirds.lineWidth = 1
            NSColor.white.withAlphaComponent(0.45).setStroke()
            thirds.stroke()
        }

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 2
        shadow.set()
        let border = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        NSColor.white.withAlphaComponent(0.9).setStroke()
        border.stroke()
        // Grips: L-shaped corners and short bars at the edge midpoints, 3 pt thick, just inside the frame.
        let grips = NSBezierPath()
        let t: CGFloat = 4, arm = min(22, r.width / 3, r.height / 3)
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.maxX, r.maxY, -1.0, -1.0), (r.minX, r.maxY, 1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            grips.append(NSBezierPath(rect: CGRect(x: dx > 0 ? x : x - arm, y: dy > 0 ? y : y - t, width: arm, height: t)))
            grips.append(NSBezierPath(rect: CGRect(x: dx > 0 ? x : x - t, y: dy > 0 ? y : y - arm, width: t, height: arm)))
        }
        if r.width >= 90 {
            grips.append(NSBezierPath(rect: CGRect(x: r.midX - 11, y: r.minY, width: 22, height: t)))
            grips.append(NSBezierPath(rect: CGRect(x: r.midX - 11, y: r.maxY - t, width: 22, height: t)))
        }
        if r.height >= 90 {
            grips.append(NSBezierPath(rect: CGRect(x: r.minX, y: r.midY - 11, width: t, height: 22)))
            grips.append(NSBezierPath(rect: CGRect(x: r.maxX - t, y: r.midY - 11, width: t, height: 22)))
        }
        NSColor.white.setFill()
        grips.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func cursor(at p: CGPoint) -> NSCursor {
        let r = viewRect(live)
        if let h = MediaBoxGeometry.handle(at: p, of: r) { return h.cursor }
        if r.contains(p) { return isDragging ? .closedHand : .openHand }
        return pictureRect.contains(p) ? .crosshair : .arrow
    }

    override func cursorUpdate(with event: NSEvent) { cursor(at: location(event)).set() }
    override func mouseMoved(with event: NSEvent) { if !isDragging { cursor(at: location(event)).set() } }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = location(event)
        downPoint = p
        moved = false
        let r = viewRect(live)
        if let h = MediaBoxGeometry.handle(at: p, of: r) {
            drag = .handle(h, start: live)
        } else if r.contains(p) {
            drag = .move(start: live, from: pixelPoint(p))
            NSCursor.closedHand.set()
        } else if pictureRect.contains(p) {
            drag = .draw(anchor: MediaBoxGeometry.clamp(pixelPoint(p), to: grid))
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let p = location(event)
        if !moved, hypot(p.x - downPoint.x, p.y - downPoint.y) < 2 { return }
        moved = true
        let px = pixelPoint(p)
        let shiftRatio: CGFloat? = event.modifierFlags.contains(.shift) ? (ratio ?? shapeRatio(drag)) : ratio
        switch drag {
        case .handle(let h, let start):
            live = MediaBoxGeometry.resize(start, handle: h, to: px, ratio: shiftRatio, bounds: grid, minSide: MediaCrop.minimumSide)
        case .move(let start, let from):
            live = MediaBoxGeometry.moved(start, by: CGVector(dx: px.x - from.x, dy: px.y - from.y), in: grid)
        case .draw(let anchor):
            live = MediaBoxGeometry.drawn(from: anchor, to: px, ratio: shiftRatio, bounds: grid, minSide: MediaCrop.minimumSide)
        }
        needsDisplay = true
        updateAccessibility()
        onLive?(live)
    }

    /// The ratio ⇧ keeps in Free mode: the current shape for a resize, square on screen for a new frame.
    private func shapeRatio(_ drag: Drag) -> CGFloat? {
        switch drag {
        case .handle(_, let start): return start.height > 0 ? start.width / start.height : nil
        case .draw: return source.map { 1 / CGFloat($0.pixelAspect) }
        case .move: return nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let current = drag else { return }
        drag = nil
        needsDisplay = true
        cursor(at: location(event)).set()
        guard moved else { live = rect; return }
        let name: String
        switch current {
        case .handle: name = "Resize Crop"
        case .move: name = "Move Crop"
        case .draw: name = "Draw Crop"
        }
        let result = live
        live = rect
        onCommit?(result, name)
    }

    /// Esc during a drag: back to the committed crop.
    func cancelDrag() {
        guard drag != nil else { return }
        drag = nil
        live = rect
        needsDisplay = true
        updateAccessibility()
        onLive?(rect)
    }
}
