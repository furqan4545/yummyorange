import AppKit
import QuartzCore

/// The Clothesline: every new file YummyOrange makes can hang on a string just under the menu bar for a moment, then
/// the string is pulled up into the notch. Resting the pointer on the notch drops it again with the files on it.
/// Session only (nothing is saved but whether the welcome card was taken off: ClotheslineWelcome). A click selects a
/// card (the panel then takes the keyboard without activating YummyOrange): Delete takes it off the line. Main thread.
///
///     Clothesline.shared.hang([url])   // adds files and runs the show sequence
///     Clothesline.shared.reveal()      // drops the line (a menu item), retract() gathers it
///     Clothesline.shared.turnOff()     // empties it and stops listening (the user picked the shelf instead)
///     Clothesline.shared.watchDrops()  // listens for files dragged to the notch (On the Clothesline, from launch)
///
/// Launch hook for checks: DW_SELFCHECK_LINE="<file>|<file>|…" hangs those files 0.5 s after launch.
final class Clothesline {
    static let shared = Clothesline()

    /// Made with the first file (the real panel). Self-tests put an offscreen one here, so the shared line runs
    /// without a window.
    var controller: ClotheslineController?

    /// Adds the files (newest first from the left, at most 50) and shows them hanging for 2 s.
    func hang(_ urls: [URL]) {
        dispatchPrecondition(condition: .onQueue(.main))
        live().hang(urls)
    }

    /// Hangs a copied screenshot: its card flies up from `point` (global screen coordinates: the pointer) to the front
    /// of the line, which drops out of the notch to meet it. Reduce Motion: it fades in on the line like any other file.
    func hangScreenshot(_ url: URL, from point: CGPoint) {
        dispatchPrecondition(condition: .onQueue(.main))
        live().hang([url], from: point)
    }

    /// Drops the line showing every file. Nothing happens when the line is empty.
    func reveal() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let c = controller ?? (files.isEmpty ? nil : live()) else { return }
        c.reveal()
    }

    /// Gathers the line into the notch.
    func retract() {
        dispatchPrecondition(condition: .onQueue(.main))
        controller?.retract()
    }

    /// The files on the line, newest first.
    var files: [URL] { controller?.engine.urls ?? [] }

    /// Whether any file on the line is still on disk (deleted and trashed files stay on the line until it next
    /// drops, which takes them off).
    var hasFiles: Bool { controller?.engine.hasFilesOnDisk ?? false }

    /// Turns the line off (for example when results go to the Float shelf instead): empties it, orders the panel out,
    /// stops the clock and stops listening to the pointer and to drags. The next hang() turns it on again. (Clear Line
    /// in a card's menu only empties the line; ClotheslineMenuTarget keeps the files aside when another place is chosen.)
    func turnOff() {
        dispatchPrecondition(condition: .onQueue(.main))
        controller?.shutDown()
    }

    /// Listens for files dragged to the notch, so they can be dropped on the line: from launch while new files go to
    /// the Clothesline, and again whenever that is chosen. Three left-button monitors (press, drag, release); the
    /// drag pasteboard is looked at only for drags near the top of the line's display. Never from the command line.
    func watchDrops() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let c = controller ?? (Self.showsWindows() ? live() : nil) else { return }
        c.watchDrops()
    }

    /// Whether drags are being watched (the monitors are installed).
    var isWatchingDrops: Bool { controller?.isWatchingDrops ?? false }

    /// Whether this process shows windows (not the command line, self-tests or snapshots, which never make the panel).
    static var showsWindows: () -> Bool = { NSApp.map { ResultsPresenter.showsWindows($0.activationPolicy()) } ?? false }

    private func live() -> ClotheslineController {
        if let controller { return controller }
        let c = ClotheslineController.live()
        controller = c
        return c
    }

    /// DW_SELFCHECK_LINE="<file>|<file>|…": the files to hang shortly after launch (nil when unset). A list with
    /// newlines is split on newlines only, so names with "|" work; use absolute paths (an app launched from Finder
    /// runs in /).
    static func selfCheckFiles(_ env: [String: String]) -> [URL]? {
        guard let spec = env["DW_SELFCHECK_LINE"] else { return nil }
        let parts: [Substring] = spec.contains("\n") ? spec.split(separator: "\n") : spec.split(separator: "|")
        let files = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        return files
    }
}

// MARK: - Clock

/// The display-synced clock that drives the motion. It runs only while something moves.
protocol ClotheslineClock: AnyObject {
    var isRunning: Bool { get }
    var onTick: ((Double) -> Void)? { get set }
    func start()
    func stop()
}

/// The display link: CADisplayLink from the line's display on macOS 14 and later, CVDisplayLink on macOS 13.
///
/// Not the view's own display link: that one stops while its window is off screen, and the line's panel is ordered out
/// while a screenshot's card flies to a hidden line (most of the flight). The card then moved only when the pointer did,
/// in jerks, until the line came out. The display's link runs whatever the windows do, at the display's rate (120 Hz
/// on a ProMotion display).
final class ClotheslineDisplayClock: NSObject, ClotheslineClock {
    var onTick: ((Double) -> Void)?
    private weak var view: NSView?
    /// The display the line is on (live: the notch display). Nil: the view's window's display, or else the view's own
    /// link.
    var screen: () -> NSScreen? = { nil }
    private var link: AnyObject?
    private var cvLink: CVDisplayLink?
    /// CVDisplayLink fires on its own thread; one frame at a time goes to the main thread.
    private let pendingLock = NSLock()
    private var tickPending = false
    private(set) var isRunning = false
    /// Frames delivered so far (tests).
    private(set) var ticks = 0

    init(view: NSView) { self.view = view }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        if #available(macOS 14.0, *), let source = screen() ?? view?.window?.screen ?? NSScreen.main {
            let l = source.displayLink(target: self, selector: #selector(frame(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
        } else if #available(macOS 14.0, *), let view {
            let l = view.displayLink(target: self, selector: #selector(frame(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            var cv: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&cv)
            guard let cv else { isRunning = false; return }
            let me = Unmanaged.passUnretained(self).toOpaque()
            CVDisplayLinkSetOutputCallback(cv, { _, _, _, _, _, ctx in
                guard let ctx else { return kCVReturnSuccess }
                let clock = Unmanaged<ClotheslineDisplayClock>.fromOpaque(ctx).takeUnretainedValue()
                clock.cvFrame()
                return kCVReturnSuccess
            }, me)
            if let id = view?.window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                CVDisplayLinkSetCurrentCGDisplay(cv, id)
            }
            CVDisplayLinkStart(cv)
            cvLink = cv
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if #available(macOS 14.0, *), let l = link as? CADisplayLink { l.invalidate() }
        link = nil
        if let cv = cvLink { CVDisplayLinkStop(cv) }
        cvLink = nil
    }

    /// The line moved to another display: a running link follows it.
    func displayChanged() {
        guard isRunning else { return }
        stop()
        start()
    }

    @available(macOS 14.0, *)
    @objc private func frame(_ link: CADisplayLink) {
        ticks += 1
        onTick?(link.targetTimestamp)
    }

    /// CVDisplayLink calls back on its own thread: one frame at a time onto the main thread.
    private func cvFrame() {
        pendingLock.lock()
        let busy = tickPending
        tickPending = true
        pendingLock.unlock()
        guard !busy else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock(); self.tickPending = false; self.pendingLock.unlock()
            guard self.isRunning else { return }
            self.ticks += 1
            self.onTick?(CACurrentMediaTime() + 1.0 / 60)
        }
    }
}

/// A clock that only records whether it should run (tests, offscreen rendering).
final class ClotheslineManualClock: ClotheslineClock {
    var onTick: ((Double) -> Void)?
    private(set) var isRunning = false
    private(set) var starts = 0
    func start() { if !isRunning { isRunning = true; starts += 1 } }
    func stop() { isRunning = false }
}

// MARK: - Surface

/// Where the line is shown: the real panel, or a stand-in for tests.
protocol ClotheslineSurface: AnyObject {
    var isShown: Bool { get }
    var ignoresMouse: Bool { get set }
    /// Left out of screen captures (screenshots, recordings, screen sharing).
    var excludedFromCapture: Bool { get set }
    var view: ClotheslineView { get }
    func show()
    func hide()
    func geometryChanged(_ g: ClotheslineGeometry)
    /// The panel has the keyboard (it is the key window, without activating YummyOrange): while a card is selected.
    var hasKeyboard: Bool { get }
    func takeKeyboard()
    /// Gives the keyboard back to the window that had it.
    func giveBackKeyboard()
    /// The panel lost the keyboard by itself (a click in another window).
    var onKeyboardLost: (() -> Void)? { get set }
}

/// The borderless, transparent, non-activating panel across the top of the notch display.
final class ClotheslinePanel: NSPanel {
    init(geometry: ClotheslineGeometry) {
        super.init(contentRect: geometry.panelFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // isFloatingPanel resets the level to .floating, so it comes first: the line sits above the menu bar
        // (its string goes into the notch; clicks pass through everywhere but on cards).
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        title = "Clothesline"
    }

    /// The panel takes the keyboard only while a card is selected (a click selects one), never otherwise; it never
    /// activates YummyOrange (it is a non-activating panel).
    var takesKeyboard = false
    override var canBecomeKey: Bool { takesKeyboard }
    override var canBecomeMain: Bool { false }
    /// The panel sits over the menu bar on purpose (the string comes out of the notch); keep the frame as given.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class ClotheslinePanelSurface: ClotheslineSurface {
    let panel: ClotheslinePanel
    let view: ClotheslineView

    var onKeyboardLost: (() -> Void)?
    private var resignObserver: NSObjectProtocol?

    init(engine: ClotheslineEngine) {
        panel = ClotheslinePanel(geometry: engine.geometry)
        view = ClotheslineView(engine: engine, frame: CGRect(origin: .zero, size: engine.geometry.panelFrame.size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                                                queue: .main) { [weak self] _ in
            // Not when the panel gives the keyboard back itself.
            guard let self, self.panel.takesKeyboard else { return }
            self.panel.takesKeyboard = false
            self.onKeyboardLost?()
        }
    }

    deinit { resignObserver.map(NotificationCenter.default.removeObserver) }

    var isShown: Bool { panel.isVisible }
    var ignoresMouse: Bool {
        get { panel.ignoresMouseEvents }
        set { if panel.ignoresMouseEvents != newValue { panel.ignoresMouseEvents = newValue } }
    }
    var excludedFromCapture: Bool {
        get { panel.sharingType == .none }
        set { let type: NSWindow.SharingType = newValue ? .none : .readOnly; if panel.sharingType != type { panel.sharingType = type } }
    }
    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    func geometryChanged(_ g: ClotheslineGeometry) { panel.setFrame(g.panelFrame, display: false) }

    var hasKeyboard: Bool { panel.isKeyWindow }
    func takeKeyboard() {
        panel.takesKeyboard = true
        panel.makeKey()
        panel.makeFirstResponder(view)
    }
    /// A key window can't hand the keyboard over by itself: ordered out, the window server gives it back to the active
    /// app's window, and ordered straight back in (unable to become key now) the line stays where it was.
    func giveBackKeyboard() {
        panel.takesKeyboard = false
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }
}

/// A surface with no window: the view alone (tests and offscreen previews).
final class ClotheslineOffscreenSurface: ClotheslineSurface {
    let view: ClotheslineView
    private(set) var isShown = false
    var ignoresMouse = true
    var excludedFromCapture = false
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var hasKeyboard = false
    /// How many times the keyboard was taken and given back (tests).
    private(set) var keyboardTakes = 0, keyboardReturns = 0
    var onKeyboardLost: (() -> Void)?
    init(engine: ClotheslineEngine) {
        view = ClotheslineView(engine: engine, frame: CGRect(origin: .zero, size: engine.geometry.panelFrame.size))
    }
    func show() { if !isShown { isShown = true; showCount += 1 } }
    func hide() { if isShown { isShown = false; hideCount += 1 } }
    func geometryChanged(_ g: ClotheslineGeometry) { view.setFrameSize(g.panelFrame.size) }
    func takeKeyboard() { if !hasKeyboard { hasKeyboard = true; keyboardTakes += 1 } }
    func giveBackKeyboard() { if hasKeyboard { hasKeyboard = false; keyboardReturns += 1 } }
    /// Tests: a click in another window takes the keyboard from the panel.
    func loseKeyboard() { guard hasKeyboard else { return }; hasKeyboard = false; onKeyboardLost?() }
}

// MARK: - Controller

/// Runs the engine on a surface with a clock: starts the clock only while something moves, shows and hides the
/// panel, keeps clicks passing through everywhere except on cards, and wakes up for holds and dwells with a timer.
final class ClotheslineController: ClotheslineViewHost {
    let engine: ClotheslineEngine
    let surface: ClotheslineSurface
    let clock: ClotheslineClock
    /// The time base (CACurrentMediaTime live; a virtual clock in tests).
    var now: () -> Double
    /// Live: a timer that calls `tick` at the deadline. Tests read `scheduledDeadline`.
    private var deadlineTimer: Timer?
    private(set) var scheduledDeadline: Double?
    var usesTimers = true
    /// Adds the pointer monitors and returns their tokens (live: NSEvent monitors; nil adds none, as in previews).
    var monitorInstaller: (() -> [Any])?
    var monitorRemover: (Any) -> Void = { NSEvent.removeMonitor($0) }
    private(set) var monitors: [Any] = []
    /// Adds the left-button monitors that watch for file drags (live: NSEvent monitors; nil adds none).
    var dropMonitorInstaller: (() -> [Any])?
    private(set) var dropMonitors: [Any] = []
    /// Decides from the button events whether a drag is a file drag.
    private(set) var dragWatch = ClotheslineDragWatch()
    /// The drag pasteboard's change count and its file URLs (or stand-ins for promised files), and whether Esc is down
    /// (live: the system's; tests and previews swap them).
    var dragChangeCount: () -> Int = { ClotheslineController.dragPasteboard.changeCount }
    var dragFiles: () -> [URL] = { ClotheslineController.dragItems(on: ClotheslineController.dragPasteboard) }
    var escapeDown: () -> Bool = { CGEventSource.keyState(.combinedSessionState, key: 0x35) }
    /// The modifier keys, the left button and the pointer (live: the system's; tests and previews swap them).
    var modifierFlags: () -> NSEvent.ModifierFlags = {
        NSEvent.modifierFlags.union(NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue)))
    }
    var leftButtonDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// Receives promised files into a folder and calls back on the main thread with each one (nil: it failed). Live:
    /// NSFilePromiseReceiver, as the Float shelf does; self-tests swap it.
    var receivePromises: (_ receivers: [NSFilePromiseReceiver], _ folder: URL, _ done: @escaping (URL?) -> Void) -> Void = { receivers, folder, done in
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: ClotheslineController.promiseQueue) { url, error in
                DispatchQueue.main.async { done(error == nil ? url : nil) }
            }
        }
    }
    /// While a press lasts, the button and the pointer are polled (60 Hz, in the common run loop modes): a drag
    /// session's own loop keeps its events from the monitors (a drag from a Float shelf, a card dragged off the line),
    /// so its moves and its release are seen this way.
    private var pressTimer: Timer?
    private(set) var pressOpen = false
    private var lastFed: CGPoint?
    static let pressPollInterval = 1.0 / 60
    /// The promised files of the last drop, as their app writes them.
    private var promiseBatch: PromiseBatch?
    private final class PromiseBatch {
        let expected: Int
        var answered = 0
        var files: [URL] = []
        var hung = false
        init(expected: Int) { self.expected = expected }
    }
    private var screenObserver: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?
    /// The last pointer position in global screen coordinates.
    private(set) var screenPointer: CGPoint?
    /// Makes the window cards fly in (a screenshot on its way to the line); nil: no flights are drawn. Live: a panel
    /// over the whole notch display, made when the first card takes off, ordered out when the last one lands and kept
    /// for the next one (making a window that size takes a few milliseconds, which used to land in the frame a card was
    /// picked up). The line turned off lets it go.
    var makeFlightSurface: ((ClotheslineGeometry) -> ClotheslineFlightSurface)?
    private(set) var flightSurface: ClotheslineFlightSurface?
    /// Whether the flight window is on screen (something is drawn in the air).
    var flightWindowShown: Bool { flightSurface?.isShown ?? false }
    /// The notch display's visible frame (global coordinates): a card flying in from another display starts near its
    /// bottom edge.
    var visibleFrame: () -> CGRect? = { nil }
    /// The line is out for a screenshot just taken (or about to come out for one): until it next goes away it is left
    /// out of screen captures, so the next screenshot doesn't catch it. Otherwise it can be captured like any window.
    private(set) var outForScreenshot = false
    /// The welcome card's file while an empty line should hold it (live: ClotheslineWelcome.wanted; nil: no welcome
    /// card, as in most tests and previews).
    var welcomeFile: (() -> URL?)?

    init(engine: ClotheslineEngine, surface: ClotheslineSurface, clock: ClotheslineClock, now: @escaping () -> Double) {
        self.engine = engine
        self.surface = surface
        self.clock = clock
        self.now = now
        surface.view.host = self
        clock.onTick = { [weak self] t in self?.tick(at: t) }
        // Changes made from the view (press, drag, menu, a picture arriving) start from now, not from a stale time.
        engine.currentTime = { [weak self] in self?.now() ?? -Double.infinity }
        engine.onItemsChange = { [weak self] in self?.surface.view.itemsChanged() }
        // A click in another window took the keyboard: the selection ends.
        surface.onKeyboardLost = { [weak self] in
            guard let self else { return }
            self.engine.select(nil)
            self.sync()
        }
    }

    /// The real thing: the panel on the notch display, the display link, the pointer monitors.
    static func live() -> ClotheslineController {
        let screen = ClotheslineGeometry.preferredScreen()
        let geometry = screen.map(ClotheslineGeometry.init(screen:)) ?? .builtInSample
        let engine = ClotheslineEngine(geometry: geometry, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                       time: CACurrentMediaTime())
        engine.voiceOverRunning = { NSWorkspace.shared.isVoiceOverEnabled }
        let surface = ClotheslinePanelSurface(engine: engine)
        surface.view.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let clock = ClotheslineDisplayClock(view: surface.view)
        clock.screen = { ClotheslineGeometry.preferredScreen() }
        let c = ClotheslineController(engine: engine, surface: surface, clock: clock, now: { CACurrentMediaTime() })
        c.monitorInstaller = { [weak c] in c?.eventMonitors() ?? [] }
        c.dropMonitorInstaller = { [weak c] in c?.dropEventMonitors() ?? [] }
        c.makeFlightSurface = { ClotheslineFlightPanelSurface(geometry: $0) }
        c.visibleFrame = { ClotheslineGeometry.preferredScreen()?.visibleFrame }
        c.welcomeFile = { ClotheslineWelcome.wanted() }
        engine.onWelcomeRemoval = { Settings.clotheslineWelcomeRemoved = $0 }
        c.startObserving()
        // The flight window is made ahead, between frames, so the first card picked up or flying in doesn't wait for it.
        DispatchQueue.main.async { [weak c] in c?.prepareFlights() }
        return c
    }

    /// Makes the flight window (not shown) if there is none yet.
    func prepareFlights() {
        if flightSurface == nil { flightSurface = makeFlightSurface?(engine.geometry) }
    }

    deinit {
        monitors.forEach(monitorRemover)
        dropMonitors.forEach(monitorRemover)
        [screenObserver, motionObserver].compactMap { $0 }.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
    }

    // MARK: API

    /// `point` (global screen coordinates): the cards fly up to the line from there (a screenshot); nil: they drop onto
    /// it.
    func hang(_ urls: [URL], from point: CGPoint? = nil) {
        engine.advance(to: now())
        let before = Set(engine.items.map(\.id))
        let start = point.map { ClotheslineFlightGeometry.start(from: $0, geometry: engine.geometry, visibleFrame: visibleFrame()) }
        engine.hang(urls, from: start)
        if point != nil && !engine.items.isEmpty { outForScreenshot = true }
        surface.view.announceAdded(engine.items.filter { !before.contains($0.id) })
        installMonitorsIfNeeded()
        sync()
    }

    /// Turns the line off: empties it at once, stops the clock and the timer, orders the panel out, removes the
    /// pointer and drag monitors, stops taking drops and lets the card pictures go.
    func shutDown() {
        engine.advance(to: now())
        engine.reset()
        clock.stop()
        schedule(nil)
        surface.ignoresMouse = true
        surface.view.acceptsFileDrops = false
        if surface.isShown { surface.hide() }
        endFlights()
        flightSurface = nil
        monitors.forEach(monitorRemover)
        monitors = []
        stopWatchingDrops()
    }

    /// Drops the line (Show Clothesline) and tells VoiceOver how many files it holds.
    func reveal() {
        engine.advance(to: now())
        engine.reveal()
        if engine.state != .hidden { surface.view.announceShown() }
        sync()
    }

    func retract() {
        engine.advance(to: now())
        engine.retract()
        sync()
    }

    /// The pointer moved, in global screen coordinates (nil: unknown). `buttonHeld`: it was a drag event; `files`:
    /// the drag watch found files on the drag pasteboard. A drag that didn't start on a card belongs to another app
    /// (or another YummyOrange window): with files on it the line can take them, otherwise it leaves the drag alone.
    func pointerMoved(screen p: CGPoint?, buttonHeld: Bool = false, files: [URL]? = nil) {
        screenPointer = p
        engine.advance(to: now())
        let own = ownsPress
        if buttonHeld && !own {
            var dragged = files ?? dragWatch.knownFiles
            // Esc cancels the drag (the system slides the files back): the line lets it go at once.
            if dragged != nil && escapeDown() { dragWatch.finish(); dragged = nil }
            // ⌥ alone narrows a file drag to copy, which the line never answers: another drag for the line, until ⌥
            // goes up (promised files are a copy anyway).
            if let d = dragged, !d.contains(where: Self.isPromise), Self.narrowsToCopy(modifierFlags()) { dragged = nil }
            if let dragged {
                if engine.fileDrag == nil { surface.view.prefetch(dragged) }
                engine.setFileDrag(dragged)
            } else if engine.fileDrag != nil && !engine.awaitingDrop {
                engine.setFileDrag(nil)
            }
        } else if engine.fileDrag != nil && !engine.awaitingDrop {
            engine.setFileDrag(nil)
        }
        engine.otherDrag = buttonHeld && engine.fileDrag == nil && !own
        let g = engine.geometry
        let scene = p.flatMap { g.screenFrame.contains($0) || g.screenFrame.insetBy(dx: 0, dy: -2).contains($0) ? g.scenePoint(fromScreen: $0) : nil }
        engine.pointerMoved(to: scene)
        sync()
    }

    func clotheslineScroll(_ input: ClotheslineScrollInput) {
        engine.advance(to: now())
        engine.scroll(ClotheslineScrollInput(phase: input.phase, delta: input.delta, time: engine.time))
        sync()
    }

    func clotheslineNeedsUpdate() {
        engine.advance(to: now())
        sync()
    }

    /// A frame (display link) or a deadline (timer).
    func tick(at t: Double? = nil) {
        engine.advance(to: t ?? now())
        sync()
    }

    // MARK: Sync

    /// The press is the line's own: on a card, a card in the hand or its drag session, or the card menu.
    private var ownsPress: Bool { engine.pressedCard != nil || engine.isDragging || engine.isMenuOpen || engine.cardDrag != nil }

    /// Brings the window, the clock, click-through, the keyboard and the wake-up timer in line with the engine.
    func sync() {
        placeWelcomeIfNeeded()
        let hidden = engine.state == .hidden
        if !hidden && !surface.isShown { surface.view.render(); surface.show() }
        // While hidden and ordered out there is nothing to draw (pointer moves cost a few comparisons).
        if surface.isShown { surface.view.render() }
        // Clicks pass through everywhere except on cards, and during a scroll gesture (cards move under the pointer).
        // Not during a drag, the line's own or another app's: the drag session tracks the mouse itself, and the
        // panel would otherwise hide every drop target in the top 300 pt. The one exception: files dragged over the
        // notch zone, the string or a card and then over the line's area, which the line takes (the view registers for
        // file drags only then); and a card moved along the string by hand, which keeps the mouse until it is let go.
        let accepting = engine.acceptsDrop && !hidden
        surface.view.acceptsFileDrops = accepting
        let overCard = engine.hoveredCard != nil && !engine.isDragging
        surface.ignoresMouse = hidden || !(accepting || engine.liftedCard != nil
            || (!engine.otherDrag && (overCard || engine.scroller.mode == .tracking)))
        if engine.needsFrames {
            clock.start()
        } else {
            clock.stop()
        }
        // The panel has the keyboard while a card is selected; it gives it back once the selection ends, but never in
        // the middle of a press (ordered out, the panel would lose the press, or the card's drag session).
        if engine.selectedCard != nil && !hidden {
            if !surface.hasKeyboard { surface.takeKeyboard() }
        } else if surface.hasKeyboard && !pressOpen && !engine.isDragging {
            surface.giveBackKeyboard()
        }
        if hidden && !engine.needsFrames && surface.isShown { surface.hide() }
        if hidden && !engine.hasFlights { outForScreenshot = false }
        surface.excludedFromCapture = outForScreenshot
        syncFlights()
        schedule(engine.needsFrames ? nil : engine.nextDeadline)
    }

    /// Cards in the air are drawn in the flight window, shown when the first one appears and ordered out when the last
    /// one lands (in the same frame its card shows on the line). A screenshot's card flies there, and a card in the hand is
    /// carried there (over the string and the other cards, and never cut off at the line's panel). Only a screenshot's
    /// flight is left out of screen captures; a card being moved can be recorded like the line.
    private func syncFlights() {
        if engine.drawsInAir {
            if flightSurface == nil { flightSurface = makeFlightSurface?(engine.geometry) }
            guard let f = flightSurface else { return }
            f.excludedFromCapture = engine.hasFlights || outForScreenshot
            f.view.render(engine: engine, source: surface.view)
            if !f.isShown { f.show() }
        } else {
            endFlights()
        }
    }

    /// Orders the flight window out (it is kept for the next flight), with nothing left in it.
    private func endFlights() {
        guard let f = flightSurface, f.isShown else { return }
        f.view.render(engine: engine, source: surface.view)
        f.hide()
    }

    private func schedule(_ deadline: Double?) {
        scheduledDeadline = deadline
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard usesTimers, let deadline else { return }
        let delay = max(0.001, deadline - now() + 0.001)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }

    // MARK: Observing

    private func startObserving() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in self?.screensChanged() }
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.engine.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            self.surface.view.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            self.sync()
        }
    }

    private func screensChanged() {
        guard let screen = ClotheslineGeometry.preferredScreen() else { return }
        let g = ClotheslineGeometry(screen: screen)
        guard g != engine.geometry else { return }
        engine.geometry = g
        surface.geometryChanged(g)
        flightSurface?.geometryChanged(g)
        (clock as? ClotheslineDisplayClock)?.displayChanged()
        sync()
    }

    /// Pointer monitors (event driven; global mouse monitors need no Accessibility permission). Installed with the
    /// first file, so an unused line costs nothing.
    private func installMonitorsIfNeeded() {
        guard monitors.isEmpty, let install = monitorInstaller else { return }
        monitors = install()
    }

    /// An empty line that is away gets the welcome card when it should hold it (ClotheslineWelcome): quietly, as if it
    /// had always hung there. The pointer monitors come on as for any file, so resting on the notch shows it.
    private func placeWelcomeIfNeeded() {
        guard engine.state == .hidden, engine.items.isEmpty, !engine.hasFlights, engine.fileDrag == nil,
              !engine.awaitingPromisedFiles, let url = welcomeFile?() else { return }
        engine.placeWelcome(url)
        if !engine.items.isEmpty { installMonitorsIfNeeded() }
    }

    /// The live monitors: global (other apps) and local (YummyOrange's own windows) mouse moves and drags. While the
    /// drag monitors are installed they handle the left-button drags (one handler per event).
    func eventMonitors() -> [Any] {
        var tokens: [Any] = []
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in self?.handle(event) }) {
            tokens.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in self?.handle(event); return event }) {
            tokens.append(l)
        }
        return tokens
    }

    private func handle(_ event: NSEvent) {
        guard event.type != .leftMouseDragged || dropMonitors.isEmpty else { return }
        pointerMoved(screen: NSEvent.mouseLocation, buttonHeld: event.type != .mouseMoved)
    }

    // MARK: Dropping files

    /// Installs the drag monitors (once); the line can then take files dragged to the notch. An empty line gets its
    /// welcome card (new files go to the line now).
    func watchDrops() {
        placeWelcomeIfNeeded()
        guard dropMonitors.isEmpty, let install = dropMonitorInstaller else { return }
        dragWatch.reset(changeCount: dragChangeCount())
        dropMonitors = install()
    }

    func stopWatchingDrops() {
        dropMonitors.forEach(monitorRemover)
        dropMonitors = []
        dragWatch.reset(changeCount: 0)
        stopPolling()
        pressOpen = false
    }

    var isWatchingDrops: Bool { !dropMonitors.isEmpty }

    /// The live drag monitors: left-button press, drag and release, global (other apps) and local (YummyOrange's own
    /// windows). Event driven, so they cost nothing while the mouse is still.
    func dropEventMonitors() -> [Any] {
        var tokens: [Any] = []
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        func kind(_ e: NSEvent) -> ClotheslineDragWatch.Kind {
            e.type == .leftMouseDown ? .down : (e.type == .leftMouseUp ? .up : .dragged)
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.mouseEvent(kind(event), screen: NSEvent.mouseLocation)
        }) { tokens.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.mouseEvent(kind(event), screen: NSEvent.mouseLocation)
            return event
        }) { tokens.append(l) }
        return tokens
    }

    /// Whether a global screen point is near the top of the line's display (in the panel's 300 pt): only there is the
    /// drag pasteboard looked at.
    func isNearLine(_ p: CGPoint) -> Bool { engine.geometry.panelFrame.insetBy(dx: 0, dy: -2).contains(p) }

    /// A left-button event from the drag monitors, in global screen coordinates. Cheap while the line is unused: a
    /// drag far from the top of the line's display costs a rectangle test.
    func mouseEvent(_ kind: ClotheslineDragWatch.Kind, screen p: CGPoint) {
        switch kind {
        case .down:
            // A press anywhere but on one of the cards ends the selection (on a card, the view decides on release).
            if engine.selectedCard != nil, engine.cardID(at: engine.geometry.scenePoint(fromScreen: p)) == nil {
                engine.select(nil)
                sync()
            }
            dragWatch.press(changeCount: dragChangeCount())
            pressOpen = true
            lastFed = p
            startPolling()
        case .up:
            pressOpen = false
            stopPolling()
            dragWatch.release(changeCount: dragChangeCount())
            // A card moved along the string is let go (whether or not the view hears the mouse-up too).
            if engine.liftedCard != nil {
                engine.advance(to: now())
                engine.pointerMoved(to: engine.geometry.scenePoint(fromScreen: p))
                announce(engine.releaseCard())
                sync()
            }
            guard engine.fileDrag != nil || !monitors.isEmpty else { return }
            engine.advance(to: now())
            engine.fileDragReleased()
            pointerMoved(screen: p, buttonHeld: false)
        case .dragged:
            lastFed = p
            let own = ownsPress
            let files = own ? nil : dragWatch.dragged(nearTop: isNearLine(p), time: now(), changeCount: dragChangeCount,
                                                        readFiles: dragFiles)
            // Nothing hung yet and no file drag: nothing to follow.
            guard files != nil || engine.fileDrag != nil || !monitors.isEmpty else { return }
            pointerMoved(screen: p, buttonHeld: true, files: files)
        }
    }

    private func startPolling() {
        guard usesTimers, pressTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pressPollInterval, repeats: true) { [weak self] _ in self?.pollPress() }
        RunLoop.main.add(timer, forMode: .common)
        pressTimer = timer
    }

    private func stopPolling() {
        pressTimer?.invalidate()
        pressTimer = nil
    }

    /// One poll of a held press: a move is a drag event, the button going up is the release (each seen once, whether
    /// the monitors also saw it or a drag session's loop kept it from them).
    func pollPress() {
        guard pressOpen else { stopPolling(); return }
        // Esc while a card is moved along the string (the panel never has the keyboard): it goes back to its place.
        if engine.liftedCard != nil && escapeDown() {
            engine.advance(to: now())
            engine.cancelCardDrag()
            sync()
        }
        let p = pointerLocation()
        if !leftButtonDown() { mouseEvent(.up, screen: p); return }
        if p != lastFed { mouseEvent(.dragged, screen: p) }
    }

    // MARK: The drop (from the view's NSDraggingDestination methods)

    /// Files dragged over the panel (scene point): the operation the line answers, or none (then the drag is not the
    /// line's: it left the notch zone and the band, the line isn't out, or the source offers neither link nor generic).
    func clotheslineDragUpdated(at p: CGPoint, files: [URL], sourceMask: NSDragOperation) -> NSDragOperation {
        engine.advance(to: now())
        // A drag the monitors didn't see start (one from a YummyOrange window, say) is a file drag all the same.
        if !files.isEmpty && engine.fileDrag == nil && !engine.isDragging { engine.setFileDrag(files) }
        engine.otherDrag = false
        // A source that offers nothing the line answers (copy only): no ghost, no gap, no glow, but the panel keeps the
        // drag, so it hears when the source offers more (⌥ let go).
        let op = Self.dropOperation(for: sourceMask, promised: files.contains(where: Self.isPromise))
        engine.setDropRefused(op.isEmpty)
        engine.pointerMoved(to: p)
        sync()
        return engine.acceptsDrop ? op : []
    }

    /// The drag left the panel. AppKit says so when the panel stops taking the drag (the files left the line's area),
    /// and when another window comes over the panel under the files (a notification, a menu), while the files may be
    /// over the line still: the monitors keep following the drag, so an exit changes nothing by itself and the line
    /// never goes from under files that are over it. An exit with Esc down is a cancel (the source gave the drag up):
    /// the drag is over for the line. A drag that ends otherwise ends with the button going up.
    func clotheslineDragExited(at p: CGPoint?) {
        engine.advance(to: now())
        if engine.fileDrag != nil, !engine.awaitingDrop, escapeDown() {
            dragWatch.finish()
            engine.setFileDrag(nil)
        }
        sync()
    }

    /// The files were let go over the panel (scene point): they hang at the gap. Returns whether the line took them.
    func clotheslineDrop(_ files: [URL], at p: CGPoint) -> Bool {
        engine.advance(to: now())
        if engine.fileDrag == nil && !engine.isDragging { engine.setFileDrag(files) }
        engine.otherDrag = false
        engine.pointerMoved(to: p)
        guard engine.acceptsDrop, !files.isEmpty else { sync(); return false }
        let added = engine.drop(files)
        dragWatch.finish()
        surface.view.announceDropped(added)
        // The line holds files now: the pointer monitors (rest on the notch, hover the cards) come on as for a job.
        installMonitorsIfNeeded()
        sync()
        return !added.isEmpty
    }

    /// Promised files were let go over the panel (scene point): the gap stays open while their app writes them into a
    /// new YummyOrange folder in the temporary directory; then they hang there. Returns whether the line takes them.
    func clotheslineDropPromises(_ receivers: [NSFilePromiseReceiver], at p: CGPoint) -> Bool {
        engine.advance(to: now())
        engine.otherDrag = false
        engine.pointerMoved(to: p)
        guard engine.acceptsDrop, !engine.dropRefused, !receivers.isEmpty, let folder = Self.makePromiseFolder() else { sync(); return false }
        engine.awaitPromisedFiles()
        dragWatch.finish()
        let batch = PromiseBatch(expected: receivers.count)
        promiseBatch = batch
        receivePromises(receivers, folder) { [weak self] url in
            guard let self else { return }
            batch.answered += 1
            if let url { batch.files.append(url) }
            if batch.hung {
                // A promise that wrote more than one file: the rest hang at the front, like a job's.
                if let url { self.hang([url]) }
            } else if batch.answered >= batch.expected {
                self.hangPromised(batch)
            }
        }
        sync()
        return true
    }

    /// The promised files are written: they hang at the gap (or at the front, when the gap has given up on them).
    private func hangPromised(_ batch: PromiseBatch) {
        batch.hung = true
        engine.advance(to: now())
        guard !batch.files.isEmpty else { engine.cancelPromisedFiles(); sync(); return }
        if engine.awaitingPromisedFiles && promiseBatch === batch {
            surface.view.announceDropped(engine.drop(batch.files))
            installMonitorsIfNeeded()
            sync()
        } else {
            hang(batch.files)
        }
    }

    /// One of the line's cards was dragged out and its session ended: the press is over (the session's loop kept its
    /// mouse-up from the monitors), so the drag watch starts the next press from the pasteboard as that drag left it.
    func clotheslineOwnDragEnded() {
        pressOpen = false
        stopPolling()
        dragWatch.release(changeCount: dragChangeCount())
    }

    // MARK: Moving a card along the string (from the view's mouse handling and its card's drag session)

    /// A press on a card began: the button and Esc are watched while it lasts (the drag monitors do it when they are
    /// installed; a card's drag session keeps its events from them).
    func clotheslineCardPressed() {
        guard !pressOpen else { return }
        pressOpen = true
        lastFed = pointerLocation()
        startPolling()
    }

    /// The card in the hand moved with the pointer (scene point). Esc down puts it back in its place.
    func clotheslineCardMoved(to p: CGPoint) {
        engine.advance(to: now())
        if engine.liftedCard != nil && escapeDown() {
            engine.cancelCardDrag()
        } else {
            engine.otherDrag = false
            engine.pointerMoved(to: p)
        }
        sync()
    }

    /// The card in the hand was let go (scene point): it hangs at the gap; VoiceOver hears where it went.
    func clotheslineCardReleased(at p: CGPoint) {
        engine.advance(to: now())
        engine.pointerMoved(to: p)
        announce(engine.releaseCard())
        sync()
    }

    /// The line's own card, in its drag session, over the panel (scene point): the operation the line answers (it hangs
    /// the card there when it is over the line's area), or none.
    func clotheslineCardDragUpdated(at p: CGPoint) -> NSDragOperation {
        engine.advance(to: now())
        engine.otherDrag = false
        engine.pointerMoved(to: p)
        sync()
        return engine.acceptsDrop && engine.cardDrag != nil ? .generic : []
    }

    /// The card's drag session was let go over the panel: the same card moves to the gap. Returns whether it did.
    func clotheslineCardDropped(at p: CGPoint) -> Bool {
        engine.advance(to: now())
        engine.pointerMoved(to: p)
        guard engine.acceptsDrop, let move = engine.dropCard() else { sync(); return false }
        announce(move)
        sync()
        return true
    }

    /// The card's drag session ended: unless it was let go over the line, the card goes back to its place.
    func clotheslineCardDragEnded() {
        engine.advance(to: now())
        engine.cardDragEnded()
        sync()
    }

    /// Tells VoiceOver where a card went, when it changed places.
    private func announce(_ move: ClotheslineEngine.CardMove?) {
        guard let move, move.moved else { return }
        surface.view.announceMoved(move)
    }

    /// The drag session ended (dropped anywhere or cancelled).
    func clotheslineDragEnded() {
        engine.advance(to: now())
        if engine.fileDrag != nil && !engine.awaitingDrop {
            dragWatch.finish()
            engine.setFileDrag(nil)
        }
        sync()
    }
}

// MARK: - Module

/// Registry entry: the launch hook, the Show Clothesline menu item, the preview snapshot and the self-tests. It adds
/// no petals. Jobs reach the line through ResultsPresenter when Show New Files is On the Clothesline (ResultsShelf.swift).
enum ClotheslineModule: FeatureModule {
    static var commands: [WheelCommand] { [] }

    /// This process runs `--selftest` (there is no app then, only checks).
    static var isSelfTest: Bool { CommandLine.arguments.dropFirst().first == "--selftest" }

    static func appDidLaunch() {
        // Choosing another place for new files turns the line off (it empties and stops watching the pointer);
        // choosing On the Clothesline again hangs its files back.
        ClotheslineMenuTarget.observeSettings()
        // On the Clothesline the line takes dropped files from the start, not only once a job has hung some.
        if Settings.resultsDestination == .clothesline { ClotheslineMenuTarget.watchLine() }
        // Copied screenshots hang on the line while Hang Copied Screenshots is on and new files go to the line. Not in
        // a self-test that calls this hook: it would watch the real clipboard (the screenshot self-test drives its own
        // watcher on named pasteboards).
        if !ClotheslineModule.isSelfTest { ClotheslineScreenshots.shared.start() }
        let env = ProcessInfo.processInfo.environment
        guard let files = Clothesline.selfCheckFiles(env), !files.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Clothesline.shared.hang(files) }
    }

    /// Show Clothesline: drops the line with the files on it, for 2 s (6 s while VoiceOver runs), and tells VoiceOver
    /// how many it holds. Always in the menu, dimmed while none of its files is still there. The cards themselves take
    /// the mouse and VoiceOver's actions, and the keys once a click has selected one (Delete, the arrows, Esc, ⌘Z).
    static func menuItems() -> [NSMenuItem] {
        let item = NSMenuItem(title: ClotheslineMenuTarget.title, action: #selector(ClotheslineMenuTarget.showLine),
                              keyEquivalent: "")
        item.target = ClotheslineMenuTarget.shared
        item.toolTip = "Drops the Clothesline with the files on it."
        let shots = NSMenuItem(title: ClotheslineMenuTarget.screenshotsTitle, action: #selector(ClotheslineMenuTarget.toggleScreenshots),
                               keyEquivalent: "")
        shots.target = ClotheslineMenuTarget.shared
        shots.toolTip = "Copy a screenshot (⌘C in its preview, or take it with Control) and it hangs on the Clothesline."
        return [item, shots]
    }

    static func snapshot(_ id: String, files: [URL], options: ToolOptions) -> NSView? {
        guard id == "clothesline" else { return nil }
        return ClotheslinePreview.snapshotView(files: files, options: options)
    }

    static func selfTest(_ name: String) -> String? {
        #if DEBUG
        switch name {
        case "clothesline": return ClotheslineTests.run()
        case "clothesline-screenshots": return ClotheslineScreenshotsTests.run()
        case "clothesline-perf": return ClotheslinePerfTests.run()
        default: return nil
        }
        #else
        return nil
        #endif
    }
}

/// The Show Clothesline menu item's target, and what happens to the line when Show New Files changes.
final class ClotheslineMenuTarget: NSObject, NSMenuItemValidation {
    /// Menu items hold their target weakly, so the target lives here for good.
    static let shared = ClotheslineMenuTarget()
    static let title = "Show Clothesline"
    /// The line's files, whether any of them is still on disk, turning it off, dropping it, and hanging files back on
    /// it. Self-tests swap them.
    static var lineFiles: () -> [URL] = { Clothesline.shared.files }
    static var lineHasFiles: () -> Bool = { Clothesline.shared.hasFiles }
    static var turnOffLine: () -> Void = { Clothesline.shared.turnOff() }
    static var revealLine: () -> Void = { Clothesline.shared.reveal() }
    static var restoreLine: ([URL]) -> Void = { Clothesline.shared.hang($0) }
    /// Starts listening for files dragged to the notch (On the Clothesline). Self-tests swap it.
    static var watchLine: () -> Void = { Clothesline.shared.watchDrops() }
    /// The files the line held (newest first) when another place was chosen for new files. They go back on the line
    /// when On the Clothesline is chosen again, so trying another choice costs nothing.
    private(set) static var parked: [URL] = []
    /// The Settings observer appDidLaunch adds (one at a time).
    private(set) static var settingsObserver: NSObjectProtocol?

    @objc func showLine() { Self.revealLine() }

    static let screenshotsTitle = "Hang Copied Screenshots"
    /// Turns Hang copied screenshots on or off (the same switch as in Settings › General).
    @objc func toggleScreenshots() { Settings.hangScreenshots.toggle() }

    /// Dimmed while none of the line's files is still on disk: choosing it would show nothing.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleScreenshots) {
            menuItem.state = Settings.hangScreenshots ? .on : .off
            return Settings.resultsDestination == .clothesline
        }
        return menuItem.action == #selector(showLine) ? Self.lineHasFiles() : true
    }

    /// Calls settingsChanged() whenever a setting changes, for as long as the app runs.
    static func observeSettings() {
        stopObservingSettings()
        settingsObserver = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { _ in
            settingsChanged()
        }
    }

    static func stopObservingSettings() {
        settingsObserver.map(NotificationCenter.default.removeObserver)
        settingsObserver = nil
    }

    /// Settings changed. Any choice but On the Clothesline turns the line off and keeps its files aside; choosing On
    /// the Clothesline again hangs them back (the line drops to show them, without the files that are gone) and
    /// listens for dropped files again. Turning it off again does nothing, and it also stops the pointer and drag
    /// monitors of a line that was emptied with Clear Line.
    static func settingsChanged() {
        if Settings.resultsDestination == .clothesline {
            watchLine()
            guard !parked.isEmpty else { return }
            let files = parked
            parked = []
            restoreLine(files)
            return
        }
        // The welcome card is no file of the person's: it comes back by itself when the line is empty again.
        let files = lineFiles().filter { !ClotheslineWelcome.isWelcome($0) }
        if !files.isEmpty { parked = files }
        turnOffLine()
    }
}
