import AppKit

/// The editors' timeline: a ruler, a film strip (video) and a waveform (sound), a playhead you drag to scrub, zoom
/// and horizontal scrolling, and selection ranges with 20 pt handles.
///
/// Modes:
/// - `.single`: one in/out range (Trim). Outside it the lanes are dimmed; dragging the lanes or the ruler scrubs.
/// - `.multiple`: a list of ranges (Bleep). Click a range to select it, drag its body to move it, drag its edges to
///   resize; drag on empty lanes to add one; the ruler scrubs.
/// - `.none`: no ranges, only the playhead.
///
/// The view never changes the ranges on its own account: during a drag it shows a live copy (`onLiveRanges`), and when
/// the drag ends it reports the result with `onCommitRanges` (new ranges and an action name for Undo). The owner
/// registers Undo and calls `setRanges`. Esc during a drag (`cancelDrag`) puts the ranges back.
final class MediaTimelineView: NSView {
    enum Mode { case none, single, multiple }

    let source: MediaSource
    let mode: Mode
    var strip: MediaKit.FilmStrip? { didSet { needsDisplay = true } }
    var peaks: MediaKit.Peaks? { didSet { needsDisplay = true } }

    /// The playhead in seconds. Setting it redraws only the old and new playhead.
    var playhead: Double = 0 {
        didSet {
            guard playhead != oldValue else { return }
            setNeedsDisplay(playheadRect(oldValue))
            setNeedsDisplay(playheadRect(playhead))
            if followsPlayhead { revealPlayheadWhilePlaying() }
        }
    }
    /// Page the view along while playing, so the playhead stays visible.
    var followsPlayhead = false
    /// Lets a tool show its result in the waveform: given a column's time span and its loudest sample (0…1), the
    /// peak to draw (Bleep draws its tone's level, or nothing, inside its ranges). nil draws the file as it is.
    var waveformPeak: ((_ from: Double, _ to: Double, _ peak: Float) -> Float)? { didSet { needsDisplay = true } }

    /// false hides the ranges (no frame, dimming, grips or handle elements): single mode with nothing to edit, as
    /// Redact's timeline is while no box is selected. Drags then scrub.
    var showsRanges = true {
        didSet {
            guard showsRanges != oldValue else { return }
            rebuildAccessibility()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    private(set) var ranges: [MediaRange] = []
    private(set) var selectedIndex: Int?

    // MARK: Cut markers (opt-in: Split)

    /// Cut markers (Split): the lanes come apart at each cut into one rounded segment per part, each part shows its
    /// number at its top-left, and each cut has a tab under the lanes. The accent marks only the selected cut (a line
    /// in its gap and a filled tab), so a cut never looks like the playhead. Cuts are grabbed in the lanes or by the
    /// tab, never in the ruler, which always scrubs. Off by default, so the other editors draw and behave as before.
    /// Like ranges, the view never commits cuts itself: it reports `onCommitCuts` and the owner calls `setCuts`.
    var showsCuts = false {
        didSet {
            guard showsCuts != oldValue else { return }
            rebuildAccessibility()
            window?.invalidateCursorRects(for: self)
            superview?.needsLayout = true
            needsDisplay = true
        }
    }
    /// The cuts in seconds, sorted (as committed, or a live copy while a handle is dragged).
    private(set) var cuts: [Double] = []
    private(set) var selectedCut: Int?
    /// Where a dragged cut lands for a time under the pointer (Split: the start of the frame on screen there).
    /// nil: `source.snap`.
    var cutSnap: ((Double) -> Double)?
    /// The first and last place a cut can go, and the least distance between two cuts (every part keeps a frame).
    var cutBounds: ClosedRange<Double>?
    var cutGap: Double = 0
    /// Cuts while a handle is dragged (for read-outs).
    var onLiveCuts: (([Double]) -> Void)?
    /// A finished cut edit: the new cuts, which one is selected, and an action name for Undo ("Move Split").
    var onCommitCuts: (([Double], Int?, String) -> Void)?
    /// The selected cut changed (a handle was pressed, the lanes were clicked, VoiceOver selected one).
    var onCutSelectionChange: ((Int?) -> Void)?
    private var dragStartCuts: [Double] = []
    private var dragStartSelectedCut: Int?
    private var hoveredCut: Int?
    private var pressedCut: Int?
    /// The tab under the lanes at each cut, and the width of the area that grabs a cut (lanes and tab, 20 pt).
    static let cutTabSize = CGSize(width: 14, height: 11)
    static let cutHitWidth: CGFloat = 20
    /// The gap between two parts at a cut: wider than the playhead's 5 pt halo, so a cut under the playhead still
    /// shows. Cuts closer than `cutCompactSpacing` to a neighbour (or an end) are drawn compact instead: a 1 pt gap
    /// and no tab unless selected or under the pointer, so a hundred of them don't eat the lanes, and a part keeps
    /// room for a two-digit number (24 pt) until the cuts are that close.
    static let cutGap: CGFloat = 10
    static let cutCompactSpacing: CGFloat = 36

    /// The user moved the playhead (click, drag, a handle drag, VoiceOver). `ended` is true on mouse-up.
    var onScrub: ((Double, _ ended: Bool) -> Void)?
    /// Ranges while a drag runs (for live read-outs).
    var onLiveRanges: (([MediaRange]) -> Void)?
    /// A finished edit: the new ranges, which one is selected, and an action name for Undo ("Change Start").
    var onCommitRanges: (([MediaRange], Int?, String) -> Void)?
    /// The selected range changed (multiple mode).
    var onSelectionChange: ((Int?) -> Void)?

    // MARK: Layout constants

    static let inset: CGFloat = 20
    private let topPad: CGFloat = 6
    private let rulerHeight: CGFloat = 18
    private let laneGap: CGFloat = 6
    private let stripHeight: CGFloat = 56
    private let waveHeight: CGFloat = 36
    /// Under the lanes: room for the scroller, and for the cut tabs when there are cut markers.
    private var bottomPad: CGFloat { showsCuts ? 30 : 17 }
    /// Visible width of a handle grip, and its hit width.
    static let gripWidth: CGFloat = 11
    static let handleHitWidth: CGFloat = 20

    /// The height the timeline wants under a video preview (audio-only timelines take whatever they get).
    var preferredHeight: CGFloat {
        topPad + rulerHeight + laneGap + (source.hasVideo ? stripHeight : 0)
            + (source.hasVideo && source.hasAudio ? laneGap + waveHeight : 0) + (source.hasVideo ? 0 : 140) + bottomPad
    }

    // MARK: Zoom and scroll

    /// 1 shows the whole file; larger values magnify.
    private(set) var zoom: CGFloat = 1
    /// Points scrolled from the start.
    private(set) var offset: CGFloat = 0

    private var trackWidth: CGFloat { max(1, bounds.width - 2 * Self.inset) }
    private var duration: Double { max(source.duration, 0.001) }
    /// Points per second.
    var pointsPerSecond: CGFloat { trackWidth / CGFloat(duration) * zoom }
    private var contentWidth: CGFloat { CGFloat(duration) * pointsPerSecond }
    private var maxOffset: CGFloat { max(0, contentWidth - trackWidth) }

    /// The most a step (a frame, or 1/100 s of sound) can be magnified to: about 30 pt (video) or 12 pt (audio).
    var maxZoom: CGFloat {
        let base = trackWidth / CGFloat(duration)
        let target: CGFloat = source.hasVideo ? 30 : 12
        return min(4000, max(1, target / (CGFloat(source.frameDuration) * base)))
    }

    func x(_ t: Double) -> CGFloat { Self.inset + CGFloat(t) * pointsPerSecond - offset }
    func time(atX x: CGFloat) -> Double { Double((x - Self.inset + offset) / pointsPerSecond) }

    // MARK: Interaction state

    fileprivate enum Handle: Equatable {
        case start(Int), end(Int)
        var index: Int { switch self { case .start(let i), .end(let i): return i } }
        var isStart: Bool { if case .start = self { return true } else { return false } }
    }
    private enum Drag {
        case scrub
        case handle(Handle, grab: CGFloat)
        case move(Int, grabTime: Double)
        case create(anchor: Double)
        case scroller(grab: CGFloat)
        case cut(Int, grab: CGFloat)
    }
    private var drag: Drag?
    private var dragStartRanges: [MediaRange] = []
    private var dragStartSelection: Int?
    private var dragMoved = false
    private var mouseDownPoint: CGPoint = .zero
    private var hovered: Handle?
    private var pressed: Handle?
    var isDragging: Bool { drag != nil }

    private lazy var playheadElement = MediaTimelineAXElement(timeline: self)
    private var handleElements: [MediaTimelineAXElement] = []

    init(source: MediaSource, mode: Mode) {
        self.source = source
        self.mode = mode
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 140))
        switch mode {
        case .single: ranges = [MediaRange(start: 0, end: source.duration)]; selectedIndex = 0
        case .multiple, .none: ranges = []
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Timeline")
        rebuildAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Replaces the ranges (no callbacks). In single mode exactly one range is kept.
    func setRanges(_ new: [MediaRange], selected: Int?) {
        ranges = mode == .single ? [new.first ?? MediaRange(start: 0, end: source.duration)] : new.sorted { $0.start < $1.start }
        selectedIndex = mode == .single ? 0 : selected.flatMap { $0 < ranges.count ? $0 : nil }
        rebuildAccessibility()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func select(_ index: Int?) {
        guard mode == .multiple, index != selectedIndex else { return }
        selectedIndex = index.flatMap { $0 >= 0 && $0 < ranges.count ? $0 : nil }
        rebuildAccessibility()
        needsDisplay = true
        onSelectionChange?(selectedIndex)
    }

    /// Replaces the cuts (no callbacks).
    func setCuts(_ new: [Double], selected: Int?) {
        cuts = new.sorted()
        selectedCut = selected.flatMap { $0 >= 0 && $0 < cuts.count ? $0 : nil }
        rebuildAccessibility()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// Selects a cut (or none) and reports it.
    func selectCut(_ index: Int?) {
        let new = index.flatMap { $0 >= 0 && $0 < cuts.count ? $0 : nil }
        guard showsCuts, new != selectedCut else { return }
        selectedCut = new
        rebuildAccessibility()
        needsDisplay = true
        onCutSelectionChange?(new)
    }

    /// Where cut `i` of `all` lands for time `t`: snapped (`cutSnap`), inside `cutBounds`, and at least `cutGap`
    /// from its neighbours, so it never crosses one and every part keeps its frame.
    func placeCut(_ i: Int, at t: Double, in all: [Double]) -> Double {
        let snapped = (cutSnap ?? source.snap)(min(max(t, 0), duration))
        var lo = cutBounds?.lowerBound ?? 0, hi = cutBounds?.upperBound ?? duration
        if i > 0, i - 1 < all.count { lo = max(lo, all[i - 1] + cutGap) }
        if i + 1 < all.count { hi = min(hi, all[i + 1] - cutGap) }
        return min(max(snapped, lo), max(lo, hi))
    }

    // MARK: Zooming

    func zoomIn() { setZoom(zoom * 1.6, anchor: playhead) }
    func zoomOut() { setZoom(zoom / 1.6, anchor: playhead) }
    func zoomToFit() { setZoom(1, anchor: playhead) }

    /// Zooms keeping `anchor` (a time) where it is on screen, or centring it when it is off screen.
    func setZoom(_ value: CGFloat, anchor: Double, atX anchorX: CGFloat? = nil) {
        let before = x(anchor)
        let visible = before >= Self.inset && before <= bounds.width - Self.inset
        let screenX = anchorX ?? (visible ? before : bounds.width / 2)
        zoom = min(max(1, value), maxZoom)
        offset = Self.inset + CGFloat(anchor) * pointsPerSecond - screenX
        clampOffset()
        afterScroll()
    }

    func scroll(by dx: CGFloat) {
        offset += dx
        clampOffset()
        afterScroll()
    }

    /// Scrolls so `t` is visible, with a little margin.
    func reveal(_ t: Double) {
        let px = x(t), margin = trackWidth * 0.08
        if px < Self.inset + margin { offset -= Self.inset + margin - px }
        else if px > bounds.width - Self.inset - margin { offset += px - (bounds.width - Self.inset - margin) }
        clampOffset()
        afterScroll()
    }

    private func revealPlayheadWhilePlaying() {
        let px = x(playhead)
        if px > bounds.width - Self.inset || px < Self.inset {
            // Page forward: the playhead starts again near the leading edge.
            offset = CGFloat(playhead) * pointsPerSecond - trackWidth * 0.1
            clampOffset()
            afterScroll()
        }
    }

    private func clampOffset() { offset = min(max(0, offset), maxOffset) }

    private func afterScroll() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    override func setFrameSize(_ newSize: NSSize) {
        // Keep the zoom factor (relative to the width) and the time at the leading edge.
        let leading = bounds.width > 0 ? time(atX: Self.inset) : 0
        super.setFrameSize(newSize)
        zoom = min(zoom, maxZoom)
        offset = CGFloat(leading) * pointsPerSecond
        clampOffset()
    }

    // MARK: Geometry of the parts

    private var rulerRect: CGRect { CGRect(x: 0, y: topPad, width: bounds.width, height: rulerHeight) }
    private var lanesTop: CGFloat { topPad + rulerHeight + laneGap }
    private var stripRect: CGRect? {
        guard source.hasVideo else { return nil }
        return CGRect(x: x(0), y: lanesTop, width: CGFloat(duration) * pointsPerSecond, height: stripHeight)
    }
    private var waveRect: CGRect? {
        guard source.hasAudio else { return nil }
        let top = source.hasVideo ? lanesTop + stripHeight + laneGap : lanesTop
        let height = source.hasVideo ? waveHeight : max(24, bounds.height - bottomPad - top)
        return CGRect(x: x(0), y: top, width: CGFloat(duration) * pointsPerSecond, height: height)
    }
    /// Top and bottom of all lanes together.
    private var lanesSpan: (top: CGFloat, bottom: CGFloat) {
        let rects = [stripRect, waveRect].compactMap { $0 }
        return (rects.map(\.minY).min() ?? lanesTop, rects.map(\.maxY).max() ?? lanesTop + 40)
    }

    private func playheadRect(_ t: Double) -> CGRect {
        CGRect(x: x(t) - 9, y: 0, width: 18, height: bounds.height)
    }

    private func gripRect(_ handle: Handle) -> CGRect {
        let span = lanesSpan
        switch handle {
        case .start(let i):
            return CGRect(x: x(ranges[i].start) - Self.gripWidth, y: span.top - 3, width: Self.gripWidth, height: span.bottom - span.top + 6)
        case .end(let i):
            return CGRect(x: x(ranges[i].end), y: span.top - 3, width: Self.gripWidth, height: span.bottom - span.top + 6)
        }
    }

    /// The 20 pt-wide area that grabs a handle: the grip plus a little of the range.
    private func handleHitRect(_ handle: Handle) -> CGRect {
        let grip = gripRect(handle)
        let extra = Self.handleHitWidth - Self.gripWidth
        switch handle {
        case .start: return CGRect(x: grip.minX - extra / 2, y: grip.minY - 4, width: Self.handleHitWidth, height: grip.height + 8)
        case .end: return CGRect(x: grip.minX - extra / 2, y: grip.minY - 4, width: Self.handleHitWidth, height: grip.height + 8)
        }
    }

    /// Handles that can be dragged: both ends of the single range, or of the selected range (multiple mode).
    private var activeHandles: [Handle] {
        guard showsRanges else { return [] }
        switch mode {
        case .none: return []
        case .single: return ranges.isEmpty ? [] : [.start(0), .end(0)]
        case .multiple: return selectedIndex.map { [.start($0), .end($0)] } ?? []
        }
    }

    private func handle(at p: CGPoint) -> Handle? {
        let hits = activeHandles.filter { handleHitRect($0).contains(p) }
        // When both ends are close together, take the nearer grip.
        return hits.min { abs(gripRect($0).midX - p.x) < abs(gripRect($1).midX - p.x) }
    }

    private var scrollerTrack: CGRect {
        CGRect(x: Self.inset, y: bounds.height - 7, width: trackWidth, height: 4)
    }
    private var scrollerKnob: CGRect? {
        guard maxOffset > 0.5 else { return nil }
        let track = scrollerTrack
        let width = max(28, track.width * trackWidth / contentWidth)
        let x = track.minX + (track.width - width) * offset / maxOffset
        return CGRect(x: x, y: track.minY, width: width, height: track.height)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ImageEditors.Style.chrome.setFill()
            dirtyRect.fill()
            drawRuler(dirtyRect)
            if let strip = stripRect { drawStrip(strip, dirtyRect) }
            if let wave = waveRect { drawWave(wave, dirtyRect) }
            drawRanges()
            if showsCuts { drawCuts() }
            drawPlayhead()
            if let knob = scrollerKnob {
                NSColor.labelColor.withAlphaComponent(isScrollerDrag ? 0.45 : 0.25).setFill()
                NSBezierPath(roundedRect: knob, xRadius: knob.height / 2, yRadius: knob.height / 2).fill()
            }
        }
    }

    private var isScrollerDrag: Bool { if case .scroller? = drag { return true } else { return false } }

    /// Label steps and their minor ticks, smallest first.
    private static let tickTable: [(major: Double, minor: Double)] = [
        (0.01, 0.002), (0.02, 0.005), (0.05, 0.01), (0.1, 0.02), (0.2, 0.05), (0.25, 0.05), (0.5, 0.1), (1, 0.2), (2, 0.5),
        (5, 1), (10, 2), (15, 5), (30, 5), (60, 10), (120, 30), (300, 60), (600, 60), (900, 300), (1800, 300),
        (3600, 600), (7200, 1200),
    ]

    /// Tick spacing that leaves room for a label at every major tick.
    func tickSteps() -> (major: Double, minor: Double) {
        let minGap: CGFloat = source.duration >= 3600 ? 96 : 72
        guard var step = Self.tickTable.first(where: { CGFloat($0.major) * pointsPerSecond >= minGap }) else {
            // Longer than the table reaches (hundreds of hours, or a damaged file that claims years): whole hours in
            // a 1–2–5 series, so the ruler still draws a handful of ticks instead of millions.
            let hours = max(1, Double(minGap / pointsPerSecond) / 3600)
            let magnitude = pow(10, (log10(hours)).rounded(.down))
            let major = ([1.0, 2, 5, 10].first { $0 * magnitude >= hours } ?? 10) * magnitude * 3600
            return (major, major)
        }
        if CGFloat(step.minor) * pointsPerSecond < 6 { step.minor = step.major }
        return step
    }

    private func label(for t: Double, step: Double) -> String {
        if step >= 1 {
            let s = Int(t.rounded())
            return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
        }
        return MediaTime.string(t)
    }

    private func drawRuler(_ dirty: CGRect) {
        let ruler = rulerRect
        guard ruler.intersects(dirty) else { return }
        let (major, minor) = tickSteps()
        let t0 = max(0, time(atX: dirty.minX - 60)), t1 = min(duration, time(atX: dirty.maxX + 60))
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let ticks = NSBezierPath()
        var n = (t0 / minor).rounded(.down)
        while n * minor <= t1 + minor * 0.01 {
            let t = n * minor
            let px = (x(t)).rounded() + 0.5
            let isMajor = abs((t / major) - (t / major).rounded()) < 0.001
            let h: CGFloat = isMajor ? 6 : 3
            ticks.move(to: CGPoint(x: px, y: ruler.maxY - h))
            ticks.line(to: CGPoint(x: px, y: ruler.maxY))
            if isMajor {
                let text = label(for: t, step: major) as NSString
                let size = text.size(withAttributes: attrs)
                // A label that would run off the trailing edge is left out (its tick stays).
                if px + 5 + size.width <= bounds.width - 4 {
                    text.draw(at: CGPoint(x: px + 5, y: ruler.minY - 1), withAttributes: attrs)
                }
            }
            n += 1
        }
        NSColor.tertiaryLabelColor.setStroke()
        ticks.lineWidth = 1
        ticks.stroke()
    }

    private func drawStrip(_ rect: CGRect, _ dirty: CGRect) {
        let visible = rect.intersection(CGRect(x: 0, y: rect.minY, width: bounds.width, height: rect.height))
        guard visible.intersects(dirty), let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
        let parts = partSegments(in: rect)
        parts?.addClip()
        MediaColors.lane.setFill()
        rect.fill(using: .sourceOver)
        if let strip, !strip.tiles.isEmpty {
            let cell = max(8, rect.height * source.displayAspect)
            let first = max(0, Int(((dirty.minX - rect.minX) / cell).rounded(.down)))
            var i = first
            ctx.interpolationQuality = .medium
            while true {
                let cx = rect.minX + CGFloat(i) * cell
                if cx > min(dirty.maxX, rect.maxX) { break }
                let cellRect = CGRect(x: cx, y: rect.minY, width: cell, height: rect.height)
                let t = Double((cellRect.midX - rect.minX) / pointsPerSecond)
                if let tile = strip.tile(at: min(t, duration)) {
                    ctx.saveGState()
                    ctx.translateBy(x: cellRect.minX, y: cellRect.maxY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(tile, in: CGRect(origin: .zero, size: cellRect.size))
                    ctx.restoreGState()
                }
                i += 1
            }
            // Hairlines between thumbnails.
            NSColor.black.withAlphaComponent(0.18).setFill()
            i = first
            while true {
                let cx = rect.minX + CGFloat(i) * cell
                if cx > min(dirty.maxX, rect.maxX) { break }
                if i > 0 { CGRect(x: cx.rounded(), y: rect.minY, width: 1, height: rect.height).fill(using: .sourceOver) }
                i += 1
            }
        }
        ctx.restoreGState()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        if let parts {
            // Each part's own outline, so the parts read as separate clips.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
            parts.addClip()
            partSegments(in: rect, inset: 0.5)?.stroke()
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5)
        border.lineWidth = 1
        border.stroke()
    }

    private func drawWave(_ rect: CGRect, _ dirty: CGRect) {
        let visible = rect.intersection(CGRect(x: dirty.minX - 2, y: rect.minY, width: dirty.width + 4, height: rect.height))
        guard !visible.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
        partSegments(in: rect)?.addClip()
        MediaColors.lane.setFill()
        rect.fill(using: .sourceOver)
        let mid = rect.midY.rounded()
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        CGRect(x: visible.minX, y: mid - 0.5, width: visible.width, height: 1).fill(using: .sourceOver)
        if let peaks {
            let path = NSBezierPath()
            let half = rect.height / 2 - 3
            let step: CGFloat = 1
            var top: [CGPoint] = []
            var px = visible.minX.rounded(.down)
            while px <= visible.maxX {
                let t0 = time(atX: px), t1 = time(atX: px + step)
                let raw = peaks.peak(from: t0, to: t1)
                let a = Double(waveformPeak?(t0, t1, raw) ?? raw)
                let h = max(0.5, CGFloat(pow(a, 0.6)) * half)
                top.append(CGPoint(x: px, y: mid - h))
                px += step
            }
            if let first = top.first {
                path.move(to: first)
                for p in top.dropFirst() { path.line(to: p) }
                for p in top.reversed() { path.line(to: CGPoint(x: p.x, y: 2 * mid - p.y)) }
                path.close()
            }
            if mode == .single, showsRanges, let r = ranges.first {
                let inside = CGRect(x: x(r.start), y: rect.minY, width: x(r.end) - x(r.start), height: rect.height)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: inside).addClip()
                MediaColors.accent.setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
                NSGraphicsContext.saveGraphicsState()
                let outside = NSBezierPath(rect: rect)
                outside.append(NSBezierPath(rect: inside))
                outside.windingRule = .evenOdd
                outside.addClip()
                MediaColors.wave.setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
            } else {
                MediaColors.wave.setFill()
                path.fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawRanges() {
        guard mode != .none, showsRanges else { return }
        let span = lanesSpan
        let lanes = [stripRect, waveRect].compactMap { $0 }
        if mode == .single, let r = ranges.first {
            // Dim what will be cut.
            MediaColors.scrim.setFill()
            for lane in lanes {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: lane, xRadius: 6, yRadius: 6).addClip()
                CGRect(x: lane.minX, y: lane.minY, width: max(0, x(r.start) - lane.minX), height: lane.height).fill(using: .sourceOver)
                CGRect(x: x(r.end), y: lane.minY, width: max(0, lane.maxX - x(r.end)), height: lane.height).fill(using: .sourceOver)
                NSGraphicsContext.restoreGraphicsState()
            }
            drawFrame(index: 0, span: span, filled: false)
            return
        }
        for (i, r) in ranges.enumerated() where i != selectedIndex {
            let rect = CGRect(x: x(r.start), y: span.top, width: x(r.end) - x(r.start), height: span.bottom - span.top)
            MediaColors.accent.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            MediaColors.accent.setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
            border.lineWidth = 1.5
            border.stroke()
        }
        if let selectedIndex, selectedIndex < ranges.count { drawFrame(index: selectedIndex, span: span, filled: true) }
    }

    /// The accent frame with grips at both ends (the selected range).
    private func drawFrame(index: Int, span: (top: CGFloat, bottom: CGFloat), filled: Bool) {
        let r = ranges[index]
        let inner = CGRect(x: x(r.start), y: span.top, width: max(0, x(r.end) - x(r.start)), height: span.bottom - span.top)
        if filled {
            MediaColors.accent.withAlphaComponent(0.3).setFill()
            NSBezierPath(rect: inner).fill()
        }
        let outer = inner.insetBy(dx: -Self.gripWidth, dy: -3)
        let frame = NSBezierPath(roundedRect: outer, xRadius: 6, yRadius: 6)
        frame.append(NSBezierPath(roundedRect: inner, xRadius: 2, yRadius: 2))
        frame.windingRule = .evenOdd
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.set()
        MediaColors.accent.setFill()
        frame.fill()
        NSGraphicsContext.restoreGraphicsState()
        for handle in [Handle.start(index), .end(index)] {
            let grip = gripRect(handle)
            if pressed == handle || hovered == handle {
                (pressed == handle ? DWPalette.accentDeep : DWPalette.accentLight).withAlphaComponent(pressed == handle ? 0.9 : 0.55).setFill()
                let path = NSBezierPath(roundedRect: grip, xRadius: 5, yRadius: 5)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: grip).addClip()
                frame.addClip()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            // A small vertical notch says "grab here".
            let notch = CGRect(x: grip.midX - 1, y: grip.midY - 8, width: 2, height: 16)
            NSColor.white.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: notch, xRadius: 1, yRadius: 1).fill()
        }
    }

    // MARK: Drawing cuts

    /// Whether cut `i` is drawn compact: a neighbour (another cut, or an end of the file) is closer than
    /// `cutCompactSpacing` on screen.
    func isCompactCut(_ i: Int) -> Bool {
        guard i < cuts.count else { return false }
        let before = i > 0 ? cuts[i - 1] : 0, after = i + 1 < cuts.count ? cuts[i + 1] : duration
        return min(x(cuts[i]) - x(before), x(after) - x(cuts[i])) < Self.cutCompactSpacing
    }

    /// Half the gap at cut `i`: 5 pt, or 0.5 pt when compact.
    private func halfGap(_ i: Int) -> CGFloat { isCompactCut(i) ? 0.5 : Self.cutGap / 2 }

    /// Part `k`'s visible span on screen: from the cut before it to the cut after it, less half of each gap.
    private func partSpan(_ k: Int) -> (left: CGFloat, right: CGFloat) {
        let edges = [0] + cuts + [duration]
        let left = x(edges[k]) + (k > 0 ? halfGap(k - 1) : 0)
        let right = x(edges[k + 1]) - (k < cuts.count ? halfGap(k) : 0)
        return (left, right)
    }

    /// The parts as rounded segments of `lane` (one per part, apart at each cut), or nil without cut markers. The
    /// lanes are clipped to it, so each part reads as its own clip, as in a video editor.
    private func partSegments(in lane: CGRect, inset: CGFloat = 0) -> NSBezierPath? {
        guard showsCuts, !cuts.isEmpty else { return nil }
        let path = NSBezierPath()
        for k in 0...cuts.count {
            let (left, right) = partSpan(k)
            guard right > -20, left < bounds.width + 20 else { continue }
            let r = CGRect(x: left, y: lane.minY, width: max(0, right - left), height: lane.height).insetBy(dx: inset, dy: inset)
            guard r.width > 0 else { continue }
            let radius = min(4, r.width / 2)
            path.append(NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius))
        }
        return path
    }

    /// The tab of the cut at `t`, under the lanes.
    func cutTabRect(_ t: Double) -> CGRect {
        let size = Self.cutTabSize
        return CGRect(x: x(t).rounded() - size.width / 2, y: lanesSpan.bottom + 5, width: size.width, height: size.height)
    }

    /// The area that grabs a cut: 20 pt wide, from the top of the lanes to below its tab (never the ruler, which
    /// scrubs, so the playhead's head is always the playhead's).
    func cutHitRect(_ t: Double) -> CGRect {
        let top = lanesSpan.top - 3, bottom = cutTabRect(t).maxY + 4
        return CGRect(x: x(t) - Self.cutHitWidth / 2, y: top, width: Self.cutHitWidth, height: bottom - top)
    }

    /// The cut under `p`: the nearest one, the selected one on a tie.
    private func cut(at p: CGPoint) -> Int? {
        guard showsCuts else { return nil }
        let hits = cuts.indices.filter { cutHitRect(cuts[$0]).contains(p) }
        return hits.min { a, b in
            let da = abs(x(cuts[a]) - p.x), db = abs(x(cuts[b]) - p.x)
            return abs(da - db) > 0.5 ? da < db : a == selectedCut
        }
    }

    /// The parts' numbers, then each cut's tab; the selected cut also gets an accent line in its gap. Unselected
    /// cuts are just the break between two parts, so the accent stays the playhead's and the selection's. The
    /// playhead is drawn after, on top.
    private func drawCuts() {
        let lanes = [stripRect, waveRect].compactMap { $0 }
        let span = lanesSpan
        if !cuts.isEmpty, let top = lanes.first { drawPartNumbers(in: top) }
        for (i, t) in cuts.enumerated() {
            let px = x(t).rounded()
            guard px > -20, px < bounds.width + 20 else { continue }
            let tab = cutTabRect(t)
            let selected = i == selectedCut, pressed = i == pressedCut, hovered = i == hoveredCut
            if selected || pressed {
                MediaColors.accent.setFill()
                CGRect(x: px - 1, y: span.top - 1, width: 2, height: tab.minY + 1 - (span.top - 1)).fill()
            }
            if !isCompactCut(i) || selected || pressed || hovered {
                drawCutTab(tab, selected: selected, pressed: pressed, hovered: hovered)
            }
        }
    }

    /// A small tab under the lanes: hollow in a neutral colour, tinted under the pointer, filled with the accent when
    /// selected (an outline keeps it at 3:1 or more on the light background), deeper while pressed.
    private func drawCutTab(_ r: CGRect, selected: Bool, pressed: Bool, hovered: Bool) {
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        path.lineWidth = 1
        if pressed || selected {
            (pressed ? DWPalette.accentDeep : MediaColors.accent).setFill()
            path.fill()
            MediaColors.cutTabOutline.setStroke()
            path.stroke()
        } else {
            ImageEditors.Style.chrome.setFill()
            path.fill()
            if hovered {
                MediaColors.accent.withAlphaComponent(0.18).setFill()
                path.fill()
            }
            (hovered ? MediaColors.accent : NSColor.secondaryLabelColor).setStroke()
            path.stroke()
        }
        // A notch that continues the break: "grab here".
        let notch = CGRect(x: r.midX - 0.75, y: r.midY - 2.5, width: 1.5, height: 5)
        (selected || pressed ? NSColor.white : hovered ? MediaColors.accent : NSColor.secondaryLabelColor).setFill()
        NSBezierPath(roundedRect: notch, xRadius: 0.75, yRadius: 0.75).fill()
    }

    /// "1", "2", "3"… at each part's top-left inside the top lane, in a dark capsule (white on black at 55 % is
    /// at least 4.7:1 over any picture). When some part in view is too narrow for its number, only every 2nd, 5th,
    /// 10th… part is numbered (and the first), the smallest step whose numbers all fit, so the numbers never look
    /// like a broken count; parts that narrow show none.
    private static let partNumberAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white]

    /// The parts that show their number (counting from 0) and where its capsule goes, in the top lane.
    func partNumberBadges() -> [(part: Int, rect: CGRect)] {
        guard showsCuts, !cuts.isEmpty, let lane = [stripRect, waveRect].compactMap({ $0 }).first else { return [] }
        let h: CGFloat = 14
        func badge(_ k: Int) -> (part: Int, rect: CGRect)? {
            let (l, r) = partSpan(k)
            let left = max(l, 2), right = min(r, bounds.width - 2)
            let size = ("\(k + 1)" as NSString).size(withAttributes: Self.partNumberAttributes)
            let rect = CGRect(x: (left + 3).rounded(), y: lane.minY + 3, width: max(h, (size.width + 6).rounded(.up)), height: h)
            return rect.maxX + 2 <= right ? (k, rect) : nil
        }
        let visible = (0...cuts.count).filter { k in let s = partSpan(k); return s.right > 0 && s.left < bounds.width }
        for step in [1, 2, 5, 10, 20, 25, 50, 100] {
            let wanted = visible.filter { ($0 + 1) % step == 0 }
            let badges = wanted.compactMap(badge)
            guard badges.count == wanted.count else { continue }
            if step > 1, visible.contains(0), let first = badge(0) { return [first] + badges }
            return badges
        }
        return []
    }

    private func drawPartNumbers(in lane: CGRect) {
        for b in partNumberBadges() {
            let text = "\(b.part + 1)" as NSString
            let size = text.size(withAttributes: Self.partNumberAttributes)
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: b.rect, xRadius: b.rect.height / 2, yRadius: b.rect.height / 2).fill()
            text.draw(at: CGPoint(x: b.rect.midX - size.width / 2, y: b.rect.midY - size.height / 2), withAttributes: Self.partNumberAttributes)
        }
    }

    private func drawPlayhead() {
        let px = x(playhead).rounded()
        guard px > -10, px < bounds.width + 10 else { return }
        let span = lanesSpan
        // A halo in the background colour keeps the line visible over the accent waveform and the range frame.
        MediaColors.playheadHalo.setFill()
        NSBezierPath(roundedRect: CGRect(x: px - 2.5, y: rulerRect.midY, width: 5, height: span.bottom + 4 - rulerRect.midY),
                     xRadius: 2.5, yRadius: 2.5).fill()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 2
        shadow.set()
        MediaColors.accent.setFill()
        CGRect(x: px - 1, y: rulerRect.midY, width: 2, height: span.bottom + 3 - rulerRect.midY).fill()
        // The head sits in the ruler: a rounded tab pointing down.
        let head = NSBezierPath()
        let top = rulerRect.minY + 1, w: CGFloat = 9, h: CGFloat = 12
        head.move(to: CGPoint(x: px - w / 2 + 2, y: top))
        head.line(to: CGPoint(x: px + w / 2 - 2, y: top))
        head.curve(to: CGPoint(x: px + w / 2, y: top + 2), controlPoint1: CGPoint(x: px + w / 2 - 1, y: top), controlPoint2: CGPoint(x: px + w / 2, y: top + 1))
        head.line(to: CGPoint(x: px + w / 2, y: top + h - 4))
        head.line(to: CGPoint(x: px, y: top + h + 1))
        head.line(to: CGPoint(x: px - w / 2, y: top + h - 4))
        head.line(to: CGPoint(x: px - w / 2, y: top + 2))
        head.curve(to: CGPoint(x: px - w / 2 + 2, y: top), controlPoint1: CGPoint(x: px - w / 2, y: top + 1), controlPoint2: CGPoint(x: px - w / 2 + 1, y: top))
        head.close()
        head.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func resetCursorRects() {
        for handle in activeHandles { addCursorRect(handleHitRect(handle).intersection(bounds), cursor: .resizeLeftRight) }
        if showsCuts {
            for t in cuts { addCursorRect(cutHitRect(t).intersection(bounds), cursor: .resizeLeftRight) }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = handle(at: p)
        if h != hovered { hovered = h; needsDisplay = true }
        let c = cut(at: p)
        if c != hoveredCut { hoveredCut = c; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
        if hoveredCut != nil { hoveredCut = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouseDownPoint = p
        dragStartRanges = ranges
        dragStartSelection = selectedIndex
        dragStartCuts = cuts
        dragStartSelectedCut = selectedCut
        dragMoved = false
        if let knob = scrollerKnob, p.y >= scrollerTrack.minY - 5 {
            drag = .scroller(grab: p.x - knob.minX)
            if !knob.contains(CGPoint(x: p.x, y: knob.midY)) {
                drag = .scroller(grab: knob.width / 2)
                dragScroller(to: p.x - knob.width / 2)
            }
            needsDisplay = true
            return
        }
        if let h = handle(at: p) {
            let edge = h.isStart ? x(ranges[h.index].start) : x(ranges[h.index].end)
            drag = .handle(h, grab: p.x - edge)
            pressed = h
            needsDisplay = true
            scrubToHandle(h, ended: false)
            return
        }
        if let i = cut(at: p) {
            // A cut, in the lanes or by its tab: select it, show the frame that starts the next part, and get ready
            // to move it. (The ruler isn't part of it: there the playhead is grabbed, as in Trim.)
            selectCut(i)
            drag = .cut(i, grab: p.x - x(cuts[i]))
            pressedCut = i
            needsDisplay = true
            onScrub?(cuts[i], false)
            return
        }
        if p.y < lanesSpan.top - 2 || mode != .multiple {
            // Clicking the lanes (not the ruler) also lets go of the selected cut, as it does of a range.
            if showsCuts, p.y >= lanesSpan.top - 2 { selectCut(nil) }
            drag = .scrub
            scrub(to: p.x, ended: false)
            return
        }
        // Multiple mode, in the lanes: a range selects (and may be dragged); empty space adds a range when dragged.
        let t = time(atX: p.x)
        if let i = ranges.firstIndex(where: { $0.contains(t) }) {
            select(i)
            drag = .move(i, grabTime: t - ranges[i].start)
        } else {
            drag = .create(anchor: source.snap(t))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !dragMoved, abs(p.x - mouseDownPoint.x) < 3 { return }
        dragMoved = true
        autoscroll(near: p.x)
        switch drag {
        case .scroller(let grab):
            dragScroller(to: p.x - grab)
        case .scrub:
            scrub(to: p.x, ended: false)
        case .handle(let h, let grab):
            moveHandle(h, toX: p.x - grab)
            scrubToHandle(h, ended: false)
        case .move(let i, let grabTime):
            var r = ranges[i]
            let length = r.length
            let lower = i > 0 ? ranges[i - 1].end : 0
            let upper = i + 1 < ranges.count ? ranges[i + 1].start : duration
            var start = source.snap(time(atX: p.x) - grabTime)
            start = min(max(start, lower), max(lower, upper - length))
            r.start = start
            r.end = min(upper, start + length)
            ranges[i] = r
            liveChanged()
        case .create(let anchor):
            let raw = min(max(time(atX: p.x), 0), duration)
            let t = raw < anchor ? source.snap(raw) : source.snapEnd(raw)
            var r = MediaRange(start: min(anchor, t), end: max(anchor, t))
            if r.length < source.frameDuration { r.end = min(duration, r.start + source.frameDuration) }
            // Not across a neighbour.
            let others = dragStartRanges
            if let lower = others.last(where: { $0.end <= anchor })?.end { r.start = max(r.start, lower) }
            if let upper = others.first(where: { $0.start >= anchor })?.start { r.end = min(r.end, upper) }
            guard r.length > 0 else { return }
            var all = others + [r]
            all.sort { $0.start < $1.start }
            ranges = all
            selectedIndex = all.firstIndex(of: r)
            liveChanged()
        case .cut(let i, let grab):
            guard i < cuts.count else { return }
            let t = placeCut(i, at: time(atX: p.x - grab), in: cuts)
            guard t != cuts[i] else { return }
            cuts[i] = t
            rebuildAccessibility()
            needsDisplay = true
            onLiveCuts?(cuts)
            onScrub?(t, false)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let current = drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        drag = nil
        pressed = nil
        pressedCut = nil
        defer { needsDisplay = true; window?.invalidateCursorRects(for: self) }
        switch current {
        case .scroller:
            return
        case .scrub:
            scrub(to: p.x, ended: true)
        case .handle(let h, _):
            scrubToHandle(h, ended: true)
            commitIfChanged(h.isStart ? "Change Start" : "Change End")
        case .move(let i, _):
            if dragMoved { commitIfChanged("Move Range") }
            else if i < ranges.count {
                // A click on a range: select it and put the playhead there.
                onScrub?(source.snap(time(atX: p.x)), true)
            }
        case .create:
            if dragMoved { commitIfChanged("Add Range") }
            else {
                select(nil)
                scrub(to: p.x, ended: true)
            }
        case .cut(let i, _):
            if i < cuts.count { onScrub?(cuts[i], true) }
            if dragMoved { commitCutsIfChanged("Move Split") }
        }
    }

    /// Esc during a drag: puts everything back as it was when the drag began.
    func cancelDrag() {
        guard drag != nil else { return }
        drag = nil
        pressed = nil
        pressedCut = nil
        let selectionChanged = selectedIndex != dragStartSelection
        ranges = dragStartRanges
        selectedIndex = dragStartSelection
        onLiveRanges?(ranges)
        if selectionChanged { onSelectionChange?(selectedIndex) }
        if showsCuts {
            let cutSelectionChanged = selectedCut != dragStartSelectedCut
            cuts = dragStartCuts
            selectedCut = dragStartSelectedCut
            onLiveCuts?(cuts)
            if cutSelectionChanged { onCutSelectionChange?(selectedCut) }
            window?.invalidateCursorRects(for: self)
        }
        rebuildAccessibility()
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            // ⌘ or ⌥ with the wheel zooms around the pointer.
            let p = convert(event.locationInWindow, from: nil)
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 100 : event.scrollingDeltaY / 10
            setZoom(zoom * (1 + delta), anchor: time(atX: p.x), atX: p.x)
            return
        }
        guard maxOffset > 0 else { super.scrollWheel(with: event); return }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        let delta = abs(dx) >= abs(dy) ? dx : dy
        scroll(by: -delta * (event.hasPreciseScrollingDeltas ? 1 : 8))
    }

    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        setZoom(zoom * (1 + event.magnification), anchor: time(atX: p.x), atX: p.x)
    }

    // MARK: Drag helpers

    private func scrub(to px: CGFloat, ended: Bool) {
        let t = source.snap(min(max(time(atX: px), 0), duration))
        onScrub?(t, ended)
    }

    /// While a handle moves, the preview shows the frame at that edge: the first kept frame for a start, the last
    /// kept frame for an end.
    private func scrubToHandle(_ h: Handle, ended: Bool) {
        guard h.index < ranges.count else { return }
        let r = ranges[h.index]
        let t = h.isStart ? r.start : max(r.start, source.snap(r.end - source.frameDuration))
        onScrub?(t, ended)
    }

    private func moveHandle(_ h: Handle, toX px: CGFloat) {
        let i = h.index
        guard i < ranges.count else { return }
        var r = ranges[i]
        let raw = min(max(time(atX: px), 0), duration)
        let t = h.isStart ? source.snap(raw) : source.snapEnd(raw)
        let minLength = source.frameDuration
        let lower = mode == .multiple && i > 0 ? ranges[i - 1].end : 0
        let upper = mode == .multiple && i + 1 < ranges.count ? ranges[i + 1].start : duration
        if h.isStart { r.start = min(max(t, lower), r.end - minLength) }
        else { r.end = max(min(t, upper), r.start + minLength) }
        ranges[i] = r
        liveChanged()
    }

    private func liveChanged() {
        rebuildAccessibility()
        needsDisplay = true
        onLiveRanges?(ranges)
    }

    private func commitIfChanged(_ name: String) {
        guard ranges != dragStartRanges else { return }
        let result = ranges, selection = selectedIndex
        // Show the owner's state until it commits (it calls setRanges).
        ranges = dragStartRanges
        selectedIndex = dragStartSelection
        onCommitRanges?(result, selection, name)
    }

    private func commitCutsIfChanged(_ name: String) {
        guard cuts != dragStartCuts else { return }
        let result = cuts, selection = selectedCut
        // Show the owner's cuts until it commits (it calls setCuts).
        cuts = dragStartCuts
        selectedCut = dragStartSelectedCut
        onCommitCuts?(result, selection, name)
    }

    private func dragScroller(to knobX: CGFloat) {
        guard let knob = scrollerKnob else { return }
        let track = scrollerTrack
        let fraction = (knobX - track.minX) / max(1, track.width - knob.width)
        offset = min(max(0, fraction), 1) * maxOffset
        afterScroll()
    }

    private func autoscroll(near px: CGFloat) {
        guard maxOffset > 0 else { return }
        if case .scroller = drag { return }
        if px < Self.inset { scroll(by: -min(40, Self.inset - px + 4)) }
        else if px > bounds.width - Self.inset { scroll(by: min(40, px - bounds.width + Self.inset + 4)) }
    }

    // MARK: Accessibility (VoiceOver: the playhead and each handle are adjustable)

    private func rebuildAccessibility() {
        var elements = [playheadElement]
        var handles: [MediaTimelineAXElement] = []
        switch mode {
        case .none: break
        case .single:
            if !ranges.isEmpty, showsRanges {
                handles = [MediaTimelineAXElement(timeline: self, handle: (0, true)), MediaTimelineAXElement(timeline: self, handle: (0, false))]
            }
        case .multiple:
            for i in ranges.indices {
                handles.append(MediaTimelineAXElement(timeline: self, handle: (i, true)))
                handles.append(MediaTimelineAXElement(timeline: self, handle: (i, false)))
            }
        }
        handleElements = handles
        elements += handles
        var children: [NSAccessibilityElement] = elements
        if showsCuts { children += cuts.indices.map { MediaTimelineCutAXElement(timeline: self, index: $0) } }
        setAccessibilityChildren(children)
    }

    /// VoiceOver for a cut: "Split 2", its time and the parts it separates (the numbers on the timeline count
    /// parts: split 2 is between parts 2 and 3), where it grabs, selected or not.
    func axCutLabel(_ i: Int) -> String { "Split \(i + 1)" }
    func axCutValue(_ i: Int) -> String { i < cuts.count ? "\(MediaTime.string(cuts[i])), between parts \(i + 1) and \(i + 2)" : "" }
    func axCutFrame(_ i: Int) -> CGRect {
        guard i < cuts.count else { return .zero }
        return NSAccessibility.screenRect(fromView: self, rect: cutHitRect(cuts[i]).intersection(bounds))
    }
    func axCutIsSelected(_ i: Int) -> Bool { selectedCut == i }

    /// VoiceOver selects a cut (press) and shows the frame that starts the next part.
    func axSelectCut(_ i: Int) {
        guard i < cuts.count else { return }
        selectCut(i)
        onScrub?(cuts[i], true)
    }

    /// One step (a frame, or 1/100 s) left or right, kept between its neighbours: one undoable move.
    func axAdjustCut(_ i: Int, by steps: Int) {
        guard i < cuts.count, drag == nil else { return }
        selectCut(i)
        dragStartCuts = cuts
        dragStartSelectedCut = selectedCut
        let t = placeCut(i, at: source.step(cuts[i], by: steps), in: cuts)
        guard t != cuts[i] else { NSSound.beep(); return }
        cuts[i] = t
        commitCutsIfChanged("Move Split")
        onScrub?(t, true)
    }

    /// Accessibility label, value, frame and adjustments for an element.
    func axLabel(_ handle: (index: Int, isStart: Bool)?) -> String {
        guard let handle else { return "Playhead" }
        let which = handle.isStart ? "Start" : "End"
        return mode == .multiple ? "Range \(handle.index + 1) \(which.lowercased())" : "Selection \(which.lowercased())"
    }

    func axValue(_ handle: (index: Int, isStart: Bool)?) -> String {
        guard let handle else { return MediaTime.string(playhead) }
        guard handle.index < ranges.count else { return "" }
        return MediaTime.string(handle.isStart ? ranges[handle.index].start : ranges[handle.index].end)
    }

    func axFrame(_ handle: (index: Int, isStart: Bool)?) -> CGRect {
        let rect: CGRect
        if let handle, handle.index < ranges.count {
            rect = handleHitRect(handle.isStart ? .start(handle.index) : .end(handle.index))
        } else {
            rect = playheadRect(playhead)
        }
        return NSAccessibility.screenRect(fromView: self, rect: rect.intersection(bounds))
    }

    /// One step (a frame, or 1/100 s) left or right, from VoiceOver or Full Keyboard Access.
    func axAdjust(_ handle: (index: Int, isStart: Bool)?, by steps: Int) {
        guard let handle else {
            onScrub?(source.step(playhead, by: steps), true)
            return
        }
        guard handle.index < ranges.count else { return }
        dragStartRanges = ranges
        dragStartSelection = selectedIndex
        var r = ranges[handle.index]
        let fd = source.frameDuration
        if handle.isStart {
            let lower = mode == .multiple && handle.index > 0 ? ranges[handle.index - 1].end : 0
            r.start = min(max(source.step(r.start, by: steps), lower), r.end - fd)
        } else {
            let upper = mode == .multiple && handle.index + 1 < ranges.count ? ranges[handle.index + 1].start : duration
            let stepped = steps > 0 && r.end + fd > duration - fd * 0.001 ? duration : source.snapEnd(source.step(r.end, by: steps))
            r.end = max(min(stepped, upper), r.start + fd)
        }
        ranges[handle.index] = r
        commitIfChanged(handle.isStart ? "Change Start" : "Change End")
    }
}

/// The playhead or one range handle, as an adjustable VoiceOver element (a slider).
final class MediaTimelineAXElement: NSAccessibilityElement {
    private weak var timeline: MediaTimelineView?
    private let handle: (index: Int, isStart: Bool)?

    init(timeline: MediaTimelineView, handle: (index: Int, isStart: Bool)? = nil) {
        self.timeline = timeline
        self.handle = handle
        super.init()
        setAccessibilityRole(.slider)
        setAccessibilityParent(timeline)
    }

    override func accessibilityLabel() -> String? { timeline?.axLabel(handle) }
    override func accessibilityValue() -> Any? { timeline?.axValue(handle) }
    override func accessibilityFrame() -> NSRect { timeline?.axFrame(handle) ?? .zero }
    override func accessibilityParent() -> Any? { timeline }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityHelp() -> String? {
        handle == nil ? "Move one frame with the arrow keys." : "Move this edge one frame with increment and decrement."
    }
    override func accessibilityPerformIncrement() -> Bool { timeline?.axAdjust(handle, by: 1); return true }
    override func accessibilityPerformDecrement() -> Bool { timeline?.axAdjust(handle, by: -1); return true }
}

/// One cut (Split), as an adjustable VoiceOver element: "Split 2", its time; press selects it, increment and
/// decrement move it one frame.
final class MediaTimelineCutAXElement: NSAccessibilityElement {
    private weak var timeline: MediaTimelineView?
    let index: Int

    init(timeline: MediaTimelineView, index: Int) {
        self.timeline = timeline
        self.index = index
        super.init()
        setAccessibilityRole(.slider)
        setAccessibilityParent(timeline)
    }

    override func accessibilityLabel() -> String? { timeline?.axCutLabel(index) }
    override func accessibilityValue() -> Any? { timeline?.axCutValue(index) }
    override func accessibilityFrame() -> NSRect { timeline?.axCutFrame(index) ?? .zero }
    override func accessibilityParent() -> Any? { timeline }
    override func isAccessibilityElement() -> Bool { true }
    override func isAccessibilitySelected() -> Bool { timeline?.axCutIsSelected(index) ?? false }
    override func accessibilityHelp() -> String? { "Move this split one frame with increment and decrement. Press to select it." }
    override func accessibilityPerformPress() -> Bool { timeline?.axSelectCut(index); return true }
    override func accessibilityPerformIncrement() -> Bool { timeline?.axAdjustCut(index, by: 1); return true }
    override func accessibilityPerformDecrement() -> Bool { timeline?.axAdjustCut(index, by: -1); return true }
}
