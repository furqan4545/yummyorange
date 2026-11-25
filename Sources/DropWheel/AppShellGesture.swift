import AppKit

// The drag → tap → wheel decision as a pure value type. DragMonitor feeds it one `DragGestureInput` per poll
// and acts on the events it returns; the self-test feeds it synthetic input.

/// What the recognizer asks the app to do.
enum DragGestureEvent: Equatable {
    /// Show (or switch to) a wheel for these files.
    case open(WheelMode, [URL])
    /// Escape was pressed during the drag: close the wheel.
    case cancel
    /// Comma was pressed during the drag: open Settings.
    case openSettings
    /// The mouse button went up.
    case dragEnded
}

/// A mouse-down seen by the event monitor: where and when it happened, and the drag pasteboard's
/// change count at that moment (before any drag could have started).
struct DragPressEvent: Equatable {
    var location: CGPoint
    var time: TimeInterval
    var changeCount: Int
}

/// One poll of global input state. Locations are in global screen coordinates (origin bottom-left).
struct DragGestureInput {
    var time: TimeInterval
    var mouseDown: Bool
    var location: CGPoint
    var flags: NSEvent.ModifierFlags = []
    var escapeDown = false
    var commaDown = false
    /// `NSPasteboard(name: .drag).changeCount`.
    var changeCount: Int
    /// The latest mouse-down from the event monitor since the previous poll, if any.
    var press: DragPressEvent? = nil
}

/// Decides when a file drag plus a modifier key opens a wheel. The rules follow the reference app's drag monitor:
///
/// - A press arms a wheel when its key is already held as the mouse goes down (hold ⇧, then drag), or when the
///   key is pressed at any point during the press (drag, then tap ⇧). Pressing another wheel's key switches
///   wheels; the wheel stays armed after the key is released ("release the key and keep dragging").
/// - The wheel opens once the drag pasteboard changed since the press, holds file URLs, and the mouse moved
///   at least `movementThreshold` points from where it went down.
/// - The baseline pasteboard count is the smaller of the count at the last button-up poll and the count when
///   the mouse-down event arrived, so a fast drag (written before either poll or event) is still seen.
/// - Drags that start on the Dock, or while InDesign is frontmost, are ignored.
/// - Esc closes the wheel and disarms it until a wheel key is pressed again.
struct DragGestureRecognizer {
    static let movementThreshold: CGFloat = 6
    /// The wheel stays up at least this long once shown (applied by the overlay, not here).
    static let minimumVisibleTime: TimeInterval = 0.35
    /// A press event older than this when the poll first sees the button down is stale.
    static let pressEventLifetime: TimeInterval = 0.5
    static let ignoredBundlePrefixes = ["com.adobe.indesign"]

    /// Why a press doesn't count as a wheel drag.
    enum IgnoreReason: String { case dock, notFiles, ignoredApp }

    var keys: WheelKeyMap = .defaults
    /// Whether a mouse-down at this point is on the Dock. Called once per press.
    var isInDock: (CGPoint) -> Bool = { _ in false }
    /// File URLs on the drag pasteboard. Called once per drag.
    var readFiles: () -> [URL] = { [] }
    /// Bundle identifier of the frontmost app. Called once per drag.
    var frontmostBundleID: () -> String? = { nil }

    private struct Press {
        var location: CGPoint
        var changeCount: Int
        var inDock: Bool
        var moved = false
        var files: [URL]?
        var ignored: IgnoreReason?
        /// The wheel the keys chose for this press, if any.
        var armed: WheelMode?
        /// The wheel last reported open (nil while closed).
        var shown: WheelMode?
        /// A wheel key was already held as the mouse went down.
        var armedAtPress = false
    }

    private var press: Press?
    private var mouseWasDown = false
    private var lastUpPoll: (time: TimeInterval, changeCount: Int)?
    private var previousFlags: NSEvent.ModifierFlags = []
    private var escapeWasDown = false
    private var commaWasDown = false

    /// True while a counted file drag is in progress (with or without a wheel).
    var isDragActive: Bool {
        guard let p = press else { return false }
        return p.ignored == nil && !(p.files ?? []).isEmpty && p.moved
    }
    /// Why the current press is ignored, if it is.
    var ignoreReason: IgnoreReason? { press?.ignored }
    /// The wheel the current press has armed, if any.
    var armedMode: WheelMode? { press?.armed }
    /// A wheel key was held before the press and the mouse moved, but no drag ever started: what Finder does with a
    /// ⇧/⌘-press on a file that is already selected (it deselects it) and a ⌃-press when a wheel uses ⌃ (a right-click).
    var heldKeyPressStalled: Bool {
        guard let p = press else { return false }
        return p.armedAtPress && p.moved && p.files == nil
    }

    static func isIgnoredApp(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return ignoredBundlePrefixes.contains { id.hasPrefix($0) }
    }

    mutating func step(_ input: DragGestureInput) -> [DragGestureEvent] {
        let newlyPressed = input.flags.subtracting(previousFlags)
        let escapeEdge = input.escapeDown && !escapeWasDown
        let commaEdge = input.commaDown && !commaWasDown
        let pressEdge = input.mouseDown && !mouseWasDown
        defer {
            mouseWasDown = input.mouseDown
            previousFlags = input.flags
            escapeWasDown = input.escapeDown
            commaWasDown = input.commaDown
        }

        if !input.mouseDown {
            lastUpPoll = (input.time, input.changeCount)
            guard mouseWasDown else { return [] }
            press = nil
            return [.dragEnded]
        }

        if pressEdge {
            let event = input.press.flatMap { e in
                input.time - e.time <= Self.pressEventLifetime && e.time <= input.time + 0.05 ? e : nil
            }
            let location = event?.location ?? input.location
            // No drag of this press can start before the button went down, so the smallest count seen around
            // the press (the last button-up poll, or the mouse-down event if it arrived in time) is the baseline.
            let candidates = [lastUpPoll?.changeCount, event?.changeCount].compactMap { $0 }
            let baseline = candidates.min() ?? input.changeCount
            var p = Press(location: location, changeCount: baseline, inDock: isInDock(location))
            // A wheel key already held as the mouse goes down arms that wheel (hold ⇧, then drag). ⌃ only counts for a
            // wheel that uses ⌃ itself: as a stand-in for ⌥ it is tapped mid-drag, and a ⌃-press stays a right-click.
            p.armed = keys.mode(heldAtPress: input.flags)
            p.armedAtPress = p.armed != nil
            press = p
        }
        guard var p = press else { return [] }   // the button was already down when monitoring began
        defer { press = p }

        if !p.moved, hypot(input.location.x - p.location.x, input.location.y - p.location.y) >= Self.movementThreshold {
            p.moved = true
        }
        if p.files == nil, input.changeCount != p.changeCount {
            let files = readFiles()
            p.files = files
            if p.inDock { p.ignored = .dock }
            else if files.isEmpty { p.ignored = .notFiles }
            else if Self.isIgnoredApp(frontmostBundleID()) { p.ignored = .ignoredApp }
        }

        // A wheel key pressed during the press arms (or switches to) its wheel.
        let tapped = pressEdge ? nil : keys.mode(newlyPressed: newlyPressed)
        if let tapped { p.armed = tapped }
        if escapeEdge { p.armed = nil }

        guard p.ignored == nil, let files = p.files, !files.isEmpty, p.moved else { return [] }

        var events: [DragGestureEvent] = []
        if escapeEdge {
            events.append(.cancel)
            p.shown = nil
        } else if let mode = p.armed, p.shown != mode || tapped != nil {
            events.append(.open(mode, files))
            p.shown = mode
        }
        if commaEdge { events.append(.openSettings) }
        return events
    }
}

/// Where the Dock is, from each screen's frame and visible frame plus the Dock's own preferences.
struct DockGeometry {
    enum Edge: String { case bottom, left, right }

    struct Screen {
        var frame: CGRect
        var visibleFrame: CGRect
    }

    var screens: [Screen]
    var edge: Edge
    var autohide: Bool

    /// Thickness of the band at the Dock edge that counts as the Dock when it hides itself.
    static let autoHiddenBand: CGFloat = 5

    /// Whether a mouse-down at `p` is on the Dock (or on the edge band where a hidden Dock appears).
    func contains(_ p: CGPoint) -> Bool {
        guard let screen = screens.first(where: { Self.inclusive($0.frame, p) }) else { return false }
        let f = screen.frame, v = screen.visibleFrame
        let inset: CGFloat, distance: CGFloat, outside: CGPoint
        switch edge {
        case .bottom: inset = v.minY - f.minY; distance = p.y - f.minY; outside = CGPoint(x: p.x, y: f.minY - 1)
        case .left: inset = v.minX - f.minX; distance = p.x - f.minX; outside = CGPoint(x: f.minX - 1, y: p.y)
        case .right: inset = f.maxX - v.maxX; distance = f.maxX - p.x; outside = CGPoint(x: f.maxX + 1, y: p.y)
        }
        // A visible Dock shrinks this screen's visible frame on its edge.
        if inset >= 1, distance < inset { return true }
        // A hidden Dock slides in at an outer edge of the desktop, never between two screens.
        if autohide, distance < Self.autoHiddenBand {
            return !screens.contains { Self.inclusive($0.frame, outside) }
        }
        return false
    }

    private static func inclusive(_ r: CGRect, _ p: CGPoint) -> Bool {
        p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY
    }

    /// The Dock's edge and auto-hide setting, read from its preferences (bottom and visible when unset).
    static func dockPreferences() -> (edge: Edge, autohide: Bool) {
        let dock = UserDefaults(suiteName: "com.apple.dock")
        let edge = dock?.string(forKey: "orientation").flatMap(Edge.init(rawValue:)) ?? .bottom
        return (edge, dock?.bool(forKey: "autohide") ?? false)
    }

    private static var cached: (edge: Edge, autohide: Bool, time: TimeInterval)?

    #if DEBUG
    /// The next `current()` reads the Dock's preferences again (the menu-latency self-test times that read).
    static func forgetPreferences() { cached = nil }
    #endif

    /// The current geometry. The Dock's preferences are re-read at most every two seconds.
    static func current() -> DockGeometry {
        let now = ProcessInfo.processInfo.systemUptime
        let prefs: (edge: Edge, autohide: Bool)
        if let c = cached, now - c.time < 2 { prefs = (c.edge, c.autohide) }
        else {
            prefs = dockPreferences()
            cached = (prefs.edge, prefs.autohide, now)
        }
        return DockGeometry(screens: NSScreen.screens.map { Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) },
                            edge: prefs.edge, autohide: prefs.autohide)
    }
}
