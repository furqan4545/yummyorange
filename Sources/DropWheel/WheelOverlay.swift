import AppKit

struct WheelItem {
    let title: String
    let symbol: String?
    let handler: ([URL]) -> Void
}

// MARK: - View

/// The radial menu: one ring of petals around a centre capsule. Each petal is a drop zone; the view is the
/// drag destination for the whole wheel.
///
/// Everything is drawn by hand, in one layer, so the wheel looks the same over any wallpaper: the backdrop and
/// petals, the highlighted petal's gradient, petal edges, labels and the centre text.
final class WheelView: NSView {
    var items: [WheelItem] = [] { didSet { highlighted = nil; invalidateGeometry() } }
    var modeTitle = "" { didSet { ink.needsDisplay = true } }
    var style: WheelStyle = .glass { didSet { if style != oldValue { ink.needsDisplay = true } } }
    /// Play the petal sound and haptic when the highlight moves (each still follows its setting).
    var playsFeedback = true
    /// Highlight petals under the mouse without a drag (the settings preview).
    var highlightsOnHover = false { didSet { updateTrackingAreas() } }
    /// Draw with this highlight colour instead of the brand one (snapshots and tests).
    var accentOverride: NSColor? { didSet { ink.needsDisplay = true } }
    /// Turns the ring clockwise by this many radians; labels stay upright (previews that swing the wheel).
    var rotation: CGFloat = 0 { didSet { if rotation != oldValue { invalidateGeometry() } } }
    var onDropped: (() -> Void)?

    private(set) var highlighted: Int? {
        didSet {
            guard highlighted != oldValue else { return }
            if let now = highlighted, playsFeedback {
                PetalFeedback.petalChanged(steps: current.layout.steps(from: oldValue, to: now), moveTime: moveTime)
            }
            ink.needsDisplay = true
        }
    }

    /// When the pointer was last tracked, and how long it took to get from there to where it is now (sets how
    /// close together the ticks of petals skipped in one move sound).
    private var lastTrack: TimeInterval?
    private var moveTime: TimeInterval?

    /// How far the wheel has opened (fully open unless `playIntro()` is running).
    private(set) var bloom = WheelBloom.open

    private struct Geometry {
        let layout: WheelLayout
        let paths: [CGPath]
        let labels: [PetalLabel]
    }
    private var geometry: Geometry?
    private let ink = WheelInkView()
    private var introStart: CFTimeInterval = 0
    private var introTimer: Timer?

    /// Stretches the opening animation (self-checks that capture it mid-way); 1 in normal use.
    static var motionScale: Double = {
        Double(ProcessInfo.processInfo.environment["DW_WHEEL_SLOWMO"] ?? "").map { max(1, $0) } ?? 1
    }()

    /// Side of the square a wheel with this many petals is drawn in at full size (its panel).
    static func preferredDiameter(for count: Int) -> CGFloat { WheelLayout.diameter(for: count) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ink.owner = self
        ink.frame = bounds
        ink.autoresizingMask = [.width, .height]
        addSubview(ink)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { introTimer?.invalidate() }

    override var isFlipped: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateGeometry()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ink.needsDisplay = true
    }

    private func invalidateGeometry() {
        geometry = nil
        ink.needsDisplay = true
    }

    /// The current layout, petal paths and label settings, computed once per size and item list.
    private var current: Geometry {
        if let geometry { return geometry }
        let layout = WheelLayout(count: items.count, bounds: bounds, rotation: rotation)
        let g = Geometry(layout: layout,
                         paths: items.indices.map(layout.path),
                         labels: items.indices.map { PetalLabel.fit(items[$0], petal: $0, in: layout) })
        geometry = g
        return g
    }

    var layout: WheelLayout { current.layout }
    var labels: [PetalLabel] { current.labels }
    func petalPath(_ i: Int) -> CGPath { current.paths[i] }

    /// Petal index under a point (view coordinates). Uses exactly the geometry that is drawn.
    func index(at point: CGPoint) -> Int? { current.layout.index(at: point) }

    /// Highlights a petal directly (previews, snapshots, a practice wheel). nil clears it.
    func setHighlight(_ index: Int?) {
        highlighted = index.flatMap { items.indices.contains($0) ? $0 : nil }
    }

    // MARK: Opening

    /// Opens the wheel the way it appears under the cursor: every petal grows out of one small disc into the
    /// ring (0.2 s), labels fade in, then the petal edges. With Reduce Motion it is simply there.
    func playIntro() {
        introTimer?.invalidate()
        introTimer = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setBloom(.open)
            return
        }
        introStart = CACurrentMediaTime()
        setBloom(.closed)
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.stepIntro() }
        RunLoop.main.add(timer, forMode: .common)   // keeps running while a drag holds the run loop
        introTimer = timer
    }

    /// Holds the wheel where the opening is `seconds` in (snapshots of the animation).
    func pauseIntro(at seconds: CFTimeInterval) {
        introTimer?.invalidate()
        introTimer = nil
        setBloom(WheelMotion.state(at: seconds))
    }

    /// Ends the opening at once (fully open).
    func finishIntro() {
        introTimer?.invalidate()
        introTimer = nil
        setBloom(.open)
    }

    private func stepIntro() {
        let t = (CACurrentMediaTime() - introStart) / Self.motionScale
        setBloom(WheelMotion.state(at: t))
        if t >= WheelMotion.total { finishIntro() }
    }

    private func setBloom(_ b: WheelBloom) {
        guard b != bloom else { return }
        bloom = b
        ink.needsDisplay = true
    }

    // MARK: Window

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ink.needsDisplay = true
        if window == nil { PetalSound.shared.release(self) }   // a hover preview that closed under the pointer
    }

    // MARK: Drawing

    fileprivate func drawInk(_ ctx: CGContext) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.drawWheel(ctx)
        }
    }

    private func drawWheel(_ ctx: CGContext) {
        let g = current
        let layout = g.layout
        let painter = WheelPainter(style: style, appearance: effectiveAppearance, layout: layout, accent: accentOverride)
        let opening = bloom.shape < 1
        painter.drawBackdrop(ctx, bloom: bloom.shape)
        for i in items.indices {
            let path = opening ? layout.path(i, bloom: bloom.shape) : g.paths[i]
            painter.drawPetal(ctx, path: path, angle: layout.centerAngle(i), highlighted: i == highlighted, ring: layout.ring(i))
        }
        for i in items.indices {
            let path = opening ? layout.path(i, bloom: bloom.shape) : g.paths[i]
            painter.drawBorder(ctx, path: path, angle: layout.centerAngle(i), highlighted: i == highlighted, alpha: bloom.borders)
        }
        if bloom.labels > 0 {
            ctx.saveGState()
            ctx.setAlpha(bloom.labels)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            for i in items.indices {
                drawLabel(g.labels[i], color: painter.labelColor(highlighted: i == highlighted))
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        painter.drawCapsule(ctx)
        drawCenterText(painter.centerTextColor, layout: layout)
    }

    /// What the capsule says: the wheel's name, the highlighted petal's full title, or that nothing applies.
    var centerText: String {
        if items.isEmpty { return "Nothing for these files" }
        if let highlighted, items.indices.contains(highlighted) { return items[highlighted].title }
        return modeTitle
    }

    private func drawLabel(_ label: PetalLabel, color: NSColor) {
        var top = label.anchor.y + label.height / 2
        if let symbol = label.symbol {
            let config = NSImage.SymbolConfiguration(pointSize: label.symbolPointSize, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            let img = symbol.withSymbolConfiguration(config) ?? symbol
            let fit = min(1, label.symbolHeight / max(img.size.height, 1))
            let size = CGSize(width: img.size.width * fit, height: img.size.height * fit)
            img.draw(in: CGRect(x: label.anchor.x - size.width / 2, y: top - label.symbolHeight / 2 - size.height / 2,
                                width: size.width, height: size.height))
            top -= label.symbolHeight + label.spacing
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: label.font, .foregroundColor: color,
                                                         .paragraphStyle: paragraph, .kern: label.kern]
        for line in label.lines {
            let rect = CGRect(x: label.anchor.x - label.width / 2 - 2, y: top - label.lineHeight,
                              width: label.width + 4, height: label.lineHeight)
            (line as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: attributes)
            top -= label.lineHeight
        }
    }

    private func drawCenterText(_ color: NSColor, layout: WheelLayout) {
        let text = WheelCenterLabel.fit(centerText.uppercased(), scale: layout.scale)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: text.font, .foregroundColor: color,
                                                         .paragraphStyle: paragraph, .kern: text.kern]
        let c = layout.center
        var top = c.y + text.lineHeight * CGFloat(text.lines.count) / 2
        for line in text.lines {
            let rect = CGRect(x: c.x - text.width / 2, y: top - text.lineHeight, width: text.width, height: text.lineHeight)
            (line as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: attributes)
            top -= text.lineHeight
        }
    }

    // MARK: Hover (previews)

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard highlightsOnHover else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard highlightsOnHover else { return }
        track(convert(event.locationInWindow, from: nil))
    }

    /// Hover previews (Settings) start from no highlight, so the first petal ticks once, and keep the sound
    /// engine running while the pointer is over them.
    override func mouseEntered(with event: NSEvent) {
        guard highlightsOnHover else { return }
        highlighted = nil
        lastTrack = nil
        if playsFeedback { PetalSound.shared.hold(self, start: Settings.petalSounds) }
    }

    override func mouseExited(with event: NSEvent) {
        guard highlightsOnHover else { return }
        highlighted = nil
        PetalSound.shared.release(self)
    }

    /// Follows the pointer: the petal under it; in a gap between petals, the petal it came from; nothing in
    /// the centre or outside the ring.
    func track(_ p: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        moveTime = lastTrack.map { now - $0 }
        lastTrack = now
        let layout = current.layout
        if let i = layout.index(at: p) {
            highlighted = i
        } else if !layout.isInBand(p) {
            highlighted = nil
        }
    }

    // MARK: Drag destination

    private func updateHighlight(_ sender: NSDraggingInfo) -> NSDragOperation {
        track(convert(sender.draggingLocation, from: nil))
        return highlighted == nil ? [] : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateHighlight(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateHighlight(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = nil }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { highlighted != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let i = highlighted, items.indices.contains(i) else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        let handler = items[i].handler
        // After the drop returns, from the run loop rather than a main-queue block: handlers run modal prompts
        // and open editors that wait on WebKit, which can't call back while a main-queue block is running.
        MainThread.async { handler(urls) }
        onDropped?()
        return true
    }
}

/// The wheel's hand-drawn layer. Takes no clicks; the wheel view handles everything.
final class WheelInkView: NSView {
    fileprivate weak var owner: WheelView?

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        owner?.drawInk(ctx)
    }
}

// MARK: - Panel

/// Borderless panel that never takes focus, so the drag (and the app it came from) stays in charge.
final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows the wheel under the cursor in a clear, shadowless 372 pt panel (larger for more than 10 petals) that
/// keeps its centre when you switch wheels. It fades in over 0.07 s while the petals bloom, and disappears at
/// once.
final class OverlayController {
    let wheel = WheelView(frame: .zero)
    private(set) var mode: WheelMode?

    private var anchor: CGPoint = .zero

    private(set) lazy var panel: WheelPanel = {
        let size = WheelLayout.diameter(for: 0)
        let p = WheelPanel(contentRect: CGRect(x: 0, y: 0, width: size, height: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = false
        p.ignoresMouseEvents = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let container = NSView(frame: p.contentRect(forFrameRect: p.frame))
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        wheel.frame = container.bounds
        wheel.autoresizingMask = [.width, .height]
        container.addSubview(wheel)
        p.contentView = container
        return p
    }()

    /// True while the wheel is up.
    var isVisible: Bool { panel.isVisible }
    /// The panel's window-server number, for the launch self-check.
    var windowNumberForSelfCheck: Int { panel.windowNumber }

    init() {
        wheel.onDropped = { [weak self] in self?.hide() }
    }

    /// Shows `items` as the `mode` wheel, centred on the pointer (or `point`) when it opens.
    func show(mode: WheelMode, items: [WheelItem], at point: CGPoint? = nil) {
        let opening = !isVisible
        if opening {
            anchor = point ?? NSEvent.mouseLocation
            // Keeps the sound engine running while the wheel is up, so no tick waits for a restart.
            PetalSound.shared.hold(self, start: Settings.petalSounds)
        }
        let switching = opening || self.mode != mode
        self.mode = mode
        wheel.modeTitle = mode.rawValue
        wheel.style = Settings.wheelStyle
        wheel.items = items

        let d = WheelLayout.diameter(for: items.count)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        panel.setFrame(Self.panelFrame(anchor: anchor, diameter: d, visibleFrame: screen?.visibleFrame), display: false)
        if switching { wheel.playIntro() }

        if opening {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = WheelMotion.panelFade
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    /// The panel centred on the anchor, pushed inside the screen's visible area when it would cross an edge.
    static func panelFrame(anchor: CGPoint, diameter d: CGFloat, visibleFrame vis: CGRect?) -> CGRect {
        var frame = CGRect(x: anchor.x - d / 2, y: anchor.y - d / 2, width: d, height: d)
        guard let vis else { return frame }
        frame.origin.x = min(max(frame.minX, vis.minX), max(vis.minX, vis.maxX - d))
        frame.origin.y = min(max(frame.minY, vis.minY), max(vis.minY, vis.maxY - d))
        return frame
    }

    /// Takes the wheel away at once (no fade-out).
    func hide() {
        PetalSound.shared.release(self)
        guard panel.isVisible else { return }
        mode = nil
        wheel.finishIntro()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }
}
