import AppKit
import AVFoundation

// MARK: - Preview

/// The picture of a video editor: the current frame drawn aspect-correct on the editor's canvas (a still image, or
/// the AVPlayer's layer once it plays), an `overlay` view on top for frame tools (crop and redact boxes), and the
/// mapping between view points and video pixels.
///
/// Video pixels are the grid ffmpeg's filters use: the picture in display orientation (a quarter-turned phone clip
/// is 1080 × 1920), with the stream's pixel aspect (odd.mkv's 5776:5769 pixels are a little wider than tall), top-left
/// origin. `pictureRect` has the picture's display shape, so a pixel is `pictureRect.width / pixelSize.width` points
/// wide and `pictureRect.height / pixelSize.height` points tall.
final class MediaPreviewView: NSView {
    let source: MediaSource
    /// Space around the picture.
    var inset: CGFloat = 20 { didSet { needsLayout = true; needsDisplay = true } }
    /// The frame drawn until the player shows (and in snapshots, where the player layer isn't captured).
    var still: CGImage? { didSet { needsDisplay = true; onStillChange?() } }
    /// Called after `still` changes (frame tools that draw from the picture redraw then).
    var onStillChange: (() -> Void)?
    /// Transparent, flipped, covering the whole preview; put frame-tool views here (or subclass and draw).
    /// Use `viewRect(fromPixel:)` and friends to place things; they are in the preview's coordinates, which are the
    /// overlay's too.
    let overlay = MediaOverlayView()
    /// Called after every layout (the picture rect may have moved): reposition overlay content here.
    var onLayout: (() -> Void)?

    private let playerHost = MediaPlayerHostView()
    private let loading = MediaLoadingView()

    init(source: MediaSource) {
        self.source = source
        super.init(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        playerHost.isHidden = true
        addSubview(playerHost)
        overlay.frame = bounds
        addSubview(overlay)
        loading.isHidden = true
        addSubview(loading)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Video preview")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    /// Shows `player`'s picture over the still once its first frame is ready (nil removes it).
    func attach(_ player: AVPlayer?) {
        playerHost.attach(player)
    }

    // MARK: Geometry

    /// Where the picture is drawn: its display shape fitted into the bounds less `inset` (scaled up or down).
    var pictureRect: CGRect {
        let area = bounds.insetBy(dx: inset, dy: inset)
        guard area.width > 1, area.height > 1 else { return .zero }
        let aspect = source.displayAspect
        var size = CGSize(width: area.width, height: area.width / aspect)
        if size.height > area.height { size = CGSize(width: area.height * aspect, height: area.height) }
        return CGRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                      width: size.width.rounded(), height: size.height.rounded())
    }

    /// Points per video pixel, horizontally and vertically (they differ for non-square pixels).
    var pointsPerPixel: CGSize {
        let r = pictureRect, p = source.pixelSize
        guard p.width > 0, p.height > 0 else { return CGSize(width: 1, height: 1) }
        return CGSize(width: r.width / p.width, height: r.height / p.height)
    }

    func viewPoint(fromPixel p: CGPoint) -> CGPoint {
        let r = pictureRect, s = pointsPerPixel
        return CGPoint(x: r.minX + p.x * s.width, y: r.minY + p.y * s.height)
    }

    func pixelPoint(fromView p: CGPoint) -> CGPoint {
        let r = pictureRect, s = pointsPerPixel
        return CGPoint(x: (p.x - r.minX) / s.width, y: (p.y - r.minY) / s.height)
    }

    func viewRect(fromPixel r: CGRect) -> CGRect {
        let a = viewPoint(fromPixel: r.origin), b = viewPoint(fromPixel: CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// The view rect in video pixels (not clamped; intersect with `CGRect(origin: .zero, size: source.pixelSize)`).
    func pixelRect(fromView r: CGRect) -> CGRect {
        let a = pixelPoint(fromView: r.origin), b = pixelPoint(fromView: CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    // MARK: Loading

    /// Shows "Preparing preview…" (or `text`) with a progress bar over the picture; `progress` nil is indeterminate.
    func showLoading(_ text: String, progress: Double?) {
        loading.isHidden = false
        loading.update(text, progress: progress)
        needsLayout = true
    }

    func hideLoading() { loading.isHidden = true }
    var isShowingLoading: Bool { !loading.isHidden }

    // MARK: Drawing

    override func layout() {
        super.layout()
        let rect = pictureRect
        playerHost.frame = rect
        overlay.frame = bounds
        let size = loading.fittingSize
        loading.frame = CGRect(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded(),
                               width: size.width, height: size.height)
        onLayout?()
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ImageEditors.Style.canvas.setFill()
            dirtyRect.fill()
            let rect = pictureRect
            guard rect.width > 0 else { return }
            if let still, let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.interpolationQuality = .high
                // Flipped view: draw the image upside down so it comes out upright.
                ctx.translateBy(x: rect.minX, y: rect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(still, in: CGRect(origin: .zero, size: rect.size))
                ctx.restoreGState()
            } else {
                // Where the picture will be: a quiet placeholder, so the layout doesn't jump when it arrives.
                MediaColors.placeholder.setFill()
                NSBezierPath(rect: rect).fill()
            }
        }
    }
}

/// The transparent layer above the picture for frame tools. Flipped, like the preview.
class MediaOverlayView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    /// Clicks fall through to the preview unless a subclass or subview takes them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Hosts an AVPlayerLayer, shown once the player has a frame to display (no black flash while it loads).
final class MediaPlayerHostView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var readyObservation: NSKeyValueObservation?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resize   // the view already has the picture's display shape
        playerLayer.backgroundColor = .clear
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func attach(_ player: AVPlayer?) {
        readyObservation = nil
        playerLayer.player = player
        guard player != nil else { isHidden = true; return }
        isHidden = !playerLayer.isReadyForDisplay
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            DispatchQueue.main.async { if ready { self?.isHidden = false } }
        }
    }
}

/// "Preparing preview…" with a progress bar.
final class MediaLoadingView: NSView {
    private let label = NSTextField(labelWithString: "Preparing preview…")
    private let bar = MediaProgressBar(width: 200)
    private let stack: NSStackView

    override init(frame: NSRect) {
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .centerX
        super.init(frame: frame)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ text: String, progress: Double?) {
        label.stringValue = text
        setAccessibilityLabel(text)
        bar.isHidden = progress == nil
        if let progress {
            bar.value = progress
            setAccessibilityValue("\(Int((min(1, max(0, progress)) * 100).rounded())) %")
        }
    }
}

/// A thin determinate progress bar: a track and an accent fill. Drawn in `draw`, so offscreen snapshots show the
/// progress (the system bar's fill is a layer they don't capture).
final class MediaProgressBar: NSView {
    var value: Double = 0 {
        didSet {
            needsDisplay = true
            setAccessibilityValue("\(Int((min(1, max(0, value)) * 100).rounded())) %")
        }
    }

    init(width: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 5))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 5).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Progress")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let r = bounds.height / 2
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
            let fill = CGRect(x: 0, y: 0, width: max(bounds.height, bounds.width * CGFloat(min(1, max(0, value)))), height: bounds.height)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r).fill()
        }
    }
}

/// Colours the media editors share (system colours where one fits; the brand accent for playhead and ranges).
enum MediaColors {
    /// Playhead and selection ranges: the app's accent (dahlia), a little lighter on dark backgrounds.
    static let accent = DWPalette.accentOnBackground
    /// Where a picture or thumbnail will be, before it has loaded.
    static let placeholder = ImageEditors.Style.dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.06))
    /// Lanes of the timeline (behind the film strip and the waveform).
    static let lane = ImageEditors.Style.dynamic(light: NSColor(white: 0, alpha: 0.055), dark: NSColor(white: 1, alpha: 0.055))
    /// The waveform outside the selection.
    static let wave = ImageEditors.Style.dynamic(light: NSColor(white: 0.42, alpha: 1), dark: NSColor(white: 0.62, alpha: 1))
    /// Around the playhead line, so it stands out from the accent waveform and range frame.
    static let playheadHalo = ImageEditors.Style.dynamic(light: NSColor(white: 1, alpha: 0.92), dark: NSColor(white: 0.08, alpha: 0.92))
    /// The outline of a selected cut's tab (Split): the deep accent on light backgrounds keeps the tab at 3:1 or
    /// more against them (the accent alone is 2.9:1 on the light timeline); in dark mode the accent is light enough.
    static let cutTabOutline = ImageEditors.Style.dynamic(light: DWPalette.accentDeep, dark: DWPalette.accentLight)
    /// Over the parts of the timeline that are not selected (Trim).
    static let scrim = ImageEditors.Style.dynamic(light: NSColor(white: 0.96, alpha: 0.62), dark: NSColor(white: 0.06, alpha: 0.62))
}

// MARK: - Playback

/// An AVPlayer for an editor: exact seeks that chase the latest target while scrubbing (a new seek starts only when
/// the previous one lands, so the picture keeps up), play-until for previewing a selection, and callbacks on the
/// main thread.
final class MediaPlayback: NSObject {
    let player = AVPlayer()
    private(set) var isPlaying = false
    /// The playhead during playback (about 60 times a second) and after each seek lands.
    var onTime: ((Double) -> Void)?
    var onPlayingChange: ((Bool) -> Void)?
    /// The item is ready (true) or failed (false), once per `load`.
    var onReady: ((Bool) -> Void)?

    private var timeObserver: Any?
    private var boundaryObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var seekTarget: CMTime?
    private var seeking = false
    private var reported = false

    override init() {
        super.init()
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            guard let self, self.isPlaying else { return }
            self.onTime?(time.seconds)
        }
    }

    func load(_ url: URL) {
        let item = AVPlayerItem(url: url)
        reported = false
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            DispatchQueue.main.async {
                guard let self, !self.reported, status != .unknown else { return }
                self.reported = true
                self.onReady?(status == .readyToPlay)
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.setPlaying(false)
        }
        player.replaceCurrentItem(with: item)
    }

    var currentTime: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? t : 0
    }

    /// Plays from the current time; when `until` is given, stops there and shows `settle` (the last frame inside).
    func play(until end: Double? = nil, settle: Double? = nil) {
        guard player.currentItem != nil else { return }
        clearBoundary()
        if let end {
            boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 90_000))],
                                                              queue: .main) { [weak self] in
                guard let self else { return }
                self.pause()
                self.seek(to: settle ?? end)
            }
        }
        player.play()
        setPlaying(true)
    }

    func pause() {
        let wasPlaying = isPlaying
        player.pause()
        clearBoundary()
        setPlaying(false)
        // Where playback stopped (nothing to report when it wasn't playing: a scrub sets its own time).
        if wasPlaying { onTime?(currentTime) }
    }

    /// How far past a time a seek lands for video (the window sets it): 1 ms, so the frame shown is the one that
    /// starts at that time even when the file stores its start rounded (whole milliseconds in mkv, webm, wmv and
    /// their proxies) or the time doesn't fall on a 90 kHz tick (23.976 fps). Without it the frame before showed,
    /// while a split there starts the next part with this one. 0 for sound.
    var seekNudge: Double = 0
    /// The nudge the editor windows set for video. The frame tools take "the frame on screen at t" as the last frame
    /// that has started by t plus this (MediaSnapshot.frameTime, Redact's I), the frame the player shows.
    static let videoSeekNudge = 0.001

    /// The player time a seek to `t` asks for: `t` plus `nudge`, rounded up to the next 90 kHz tick.
    static func seekTime(_ t: Double, nudge: Double) -> CMTime {
        CMTime(value: CMTimeValue(((max(0, t) + nudge) * 90_000 - 1e-6).rounded(.up)), timescale: 90_000)
    }

    /// Seeks exactly to `t` (to the frame on screen at that time). While a seek runs, only the latest target is kept.
    func seek(to t: Double) {
        seekTarget = Self.seekTime(t, nudge: seekNudge)
        seekRequested = max(0, t)
        if !seeking { startSeek() }
    }

    /// The time the latest seek asked for (reported when it lands, without the nudge).
    private var seekRequested: Double = 0

    private func startSeek() {
        guard let target = seekTarget, player.currentItem != nil else { seekTarget = nil; return }
        seeking = true
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let pending = self.seekTarget, pending != target {
                    self.startSeek()
                } else {
                    self.seeking = false
                    self.seekTarget = nil
                    if !self.isPlaying { self.onTime?(self.seekRequested) }
                }
            }
        }
    }

    private func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        onPlayingChange?(playing)
    }

    private func clearBoundary() {
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
    }

    /// Stops playback and lets go of the item and observers (call before the window closes).
    func tearDown() {
        player.pause()
        clearBoundary()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation = nil
        onTime = nil; onPlayingChange = nil; onReady = nil
        player.replaceCurrentItem(with: nil)
    }
}
