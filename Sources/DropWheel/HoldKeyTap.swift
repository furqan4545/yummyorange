import AppKit
import ApplicationServices
import os

// "Hold the key first" (opt-in, needs Accessibility).
//
// Holding a wheel key and then pressing on a file in Finder doesn't always start a drag: Finder reads ⇧- or
// ⌘-press on a file that is already selected as "take it out of the selection", and ⌃-press as a right-click.
// So no drag begins and the wheel has nothing to open for. With this on, an event tap holds back a left
// mouse-down that lands on a FILE in Finder (a selected one, for ⇧ and ⌘) while a wheel key is down, and waits:
//   - the mouse moves 6 points (the wheel's own drag threshold): the mouse-down and the drag go on WITHOUT the
//     wheel keys, so Finder drags the selection as usual, while DragMonitor still sees the physical key and opens
//     that wheel;
//   - the button comes up first (a click): the original down and up go on unchanged, so ⇧/⌘/⌃-click keep working;
//   - 0.8 s pass first (a long press): the original mouse-down goes on unchanged (with a matching mouse-up if the
//     button was released meanwhile, so no app is left thinking the button is down).
// Everything else (presses with no wheel key, on empty space, on window chrome, outside Finder) is never touched.

/// The pure decision part, so it can be self-tested without an event tap.
struct HoldKeyDecider {
    enum Kind { case down, dragged, up }

    enum Action: Equatable {
        /// Deliver the event unchanged.
        case pass
        /// Drop the event (it's being held back).
        case swallow
        /// Send the held mouse-down on first, then this event, both without `strip`.
        case releaseAsDrag(strip: CGEventFlags)
        /// Send the held mouse-down on first, then this event, both unchanged.
        case releaseAsClick
        /// Deliver the event with `strip` removed.
        case strip(CGEventFlags)
    }

    /// Movement that makes a held press a drag: the same 6 pt the wheel needs (`DragGestureRecognizer`), so a
    /// ⌘-click that wobbles a few points stays a ⌘-click.
    static let dragDistance: CGFloat = DragGestureRecognizer.movementThreshold
    /// A press that hasn't become a drag or a click by then goes on as it was.
    static let longPress: TimeInterval = 0.8

    private enum State {
        case idle
        case holding(location: CGPoint, time: TimeInterval, strip: CGEventFlags)
        case dragging(strip: CGEventFlags)
    }
    private var state: State = .idle

    var isHolding: Bool { if case .holding = state { return true } else { return false } }

    /// - Parameters:
    ///   - wheelFlags: the modifier flags that open a wheel (with the current key settings).
    ///   - target: for mouse-downs only, whether the press is on a file in Finder and whether that file is selected.
    mutating func decide(_ kind: Kind, flags: CGEventFlags, location: CGPoint, time: TimeInterval,
                         wheelFlags: CGEventFlags, target: () -> HoldKeyTarget) -> Action {
        switch (kind, state) {
        case (.down, .holding):
            // A second press while one is held back (an up was lost): let both through as they were.
            state = .idle
            return .releaseAsClick
        case (.down, _):
            state = .idle
            let held = flags.intersection(wheelFlags)
            guard !held.isEmpty, Self.shouldHold(held, target()) else { return .pass }
            state = .holding(location: location, time: time, strip: held)
            return .swallow
        case (.dragged, .holding(let start, _, let strip)):
            guard hypot(location.x - start.x, location.y - start.y) >= Self.dragDistance else { return .swallow }
            state = .dragging(strip: strip)
            return .releaseAsDrag(strip: strip)
        case (.dragged, .dragging(let strip)):
            return .strip(strip)
        case (.up, .holding):
            state = .idle
            return .releaseAsClick
        case (.up, .dragging(let strip)):
            state = .idle
            return .strip(strip)
        default:
            return .pass
        }
    }

    /// Hold only a press on a file. ⌃ turns any file press into a right-click, so ⌃ (alone or with others) is held
    /// on any file. With ⇧ or ⌘ the file must also be selected: on an unselected file Finder adds it and drags the
    /// whole selection anyway, and that must keep working. ⌥ alone is never held: Finder neither deselects nor
    /// right-clicks on a ⌥-press, so the drag starts by itself (and ⌥-drag keeps meaning "copy").
    static func shouldHold(_ held: CGEventFlags, _ target: HoldKeyTarget) -> Bool {
        guard target.isFile else { return false }
        if held.contains(.maskControl) { return true }
        if held.contains(.maskShift) || held.contains(.maskCommand) { return target.selected != false }
        return false
    }

    /// Called from the timer while holding: after `longPress`, give the press back.
    mutating func timedOut(now: TimeInterval) -> Bool {
        guard case .holding(_, let t0, _) = state, now - t0 >= Self.longPress - 0.001 else { return false }
        state = .idle
        return true
    }

    mutating func reset() { state = .idle }
}

/// What is under a press in Finder.
struct HoldKeyTarget: Equatable {
    var isFile: Bool
    /// Whether that file is selected; nil when Finder doesn't say.
    var selected: Bool?
    static let none = HoldKeyTarget(isFile: false, selected: nil)
}

final class HoldKeyTap {
    static let shared = HoldKeyTap()

    /// Marks the events this tap posts itself (timer and shutdown paths), so it lets them through untouched.
    fileprivate static let marker: Int64 = 0x4457_484B   // "DWHK"

    /// Settings the tap thread reads, kept current from the main thread: the wheel flags and Finder's pid.
    fileprivate struct Shared { var wheelFlags: CGEventFlags = []; var finderPID: pid_t = 0 }
    fileprivate let shared = OSAllocatedUnfairLock(initialState: Shared())

    // Each start makes a new `TapRun` with its own tap, thread, decider, held press and timer, so a run that is
    // still winding down can never touch the next one's state. Only the main thread touches these three.
    private var run: TapRun?
    private var trustPoll: Timer?
    private var running = false

    var isRunning: Bool { running }
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Starts or stops the tap to match the setting and the Accessibility permission. `prompt` shows the
    /// system's request when the permission is missing. While the setting is on, the permission is checked
    /// every 2 s: the tap starts once it is given and stops if it is taken away.
    func update(prompt: Bool = false) {
        refreshShared()
        guard Settings.holdKeyFirst else { trustPoll?.invalidate(); trustPoll = nil; stop(); return }
        if Self.isTrusted { start() } else {
            stop()
            if prompt {
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            }
        }
        guard trustPoll == nil else { return }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, Settings.holdKeyFirst else { return }
            self.refreshShared()   // Finder may have relaunched with a new pid
            if Self.isTrusted != self.running { self.update() }
        }
        RunLoop.main.add(t, forMode: .common)
        trustPoll = t
    }

    private func refreshShared() {
        let flags = Self.wheelFlags()
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier ?? 0
        shared.withLock { $0 = Shared(wheelFlags: flags, finderPID: pid) }
    }

    private func start() {
        guard !running else { return }
        let newRun = TapRun(owner: self)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { newRun.body { ready.signal() } }
        thread.name = "dropwheel.holdkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        // Wait (briefly) until the tap is up or has failed, so `stop` always finds its loop.
        guard ready.wait(timeout: .now() + 2) == .success, newRun.loop != nil else {
            newRun.cancel()   // a late start shuts itself down instead of running unowned
            DragMonitor.log.error("hold-key tap: didn’t start (Accessibility not allowed?)")
            return
        }
        run = newRun
        running = true
    }

    func stop() {
        running = false
        run?.end()
        run = nil
    }

    /// The modifier flags that open a wheel with the current keys (⌥ included when it stands in for ⌃).
    static func wheelFlags(_ keys: WheelKeyMap = Settings.wheelKeys) -> CGEventFlags {
        var flags: CGEventFlags = []
        for mode in WheelMode.allCases {
            switch keys.key(for: mode) {
            case .shift: flags.insert(.maskShift)
            case .control: flags.insert(.maskControl)
            case .option: flags.insert(.maskAlternate)
            case .command: flags.insert(.maskCommand)
            case .off: break
            }
        }
        if keys.optionStandsInFor != nil { flags.insert(.maskAlternate) }
        return flags
    }

    /// `flags` without `strip`, including the left/right key bits that go with each stripped modifier.
    static func removing(_ strip: CGEventFlags, from flags: CGEventFlags) -> CGEventFlags {
        var bits = strip.rawValue
        if strip.contains(.maskShift) { bits |= 0x2 | 0x4 }            // left/right shift
        if strip.contains(.maskControl) { bits |= 0x1 | 0x2000 }       // left/right control
        if strip.contains(.maskAlternate) { bits |= 0x20 | 0x40 }      // left/right option
        if strip.contains(.maskCommand) { bits |= 0x8 | 0x10 }         // left/right command
        return CGEventFlags(rawValue: flags.rawValue & ~bits)
    }

    // MARK: What is under a press

    /// The Finder window under a press: its CG number, frame and layer (the desktop sits far below 0), or nil when
    /// the window that will get the event isn't Finder's. One cheap window lookup; no Accessibility call.
    static func finderWindow(_ event: CGEvent, finderPID: pid_t) -> (id: CGWindowID, frame: CGRect, desktop: Bool)? {
        guard finderPID > 0 else { return nil }
        func entry(_ w: [String: Any]) -> (CGWindowID, CGRect, Bool)? {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == finderPID,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b)
            else { return nil }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            return (CGWindowID(w[kCGWindowNumber as String] as? Int ?? 0), r, layer < 0)
        }
        let id = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        if id > 0 {
            guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]])?.first
            else { return nil }
            return entry(info).map { (id: $0.0, frame: $0.1, desktop: $0.2) }
        }
        let point = event.location
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
                  r.contains(point) else { continue }
            if let alpha = w[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            return entry(w).map { (id: $0.0, frame: $0.1, desktop: $0.2) }
        }
        return nil
    }

    /// Whether a press is on a file that is selected in the Finder window (or desktop) under it. Finder's icon views
    /// build their accessibility tree lazily, so hit-testing only finds a container; instead this asks the window's
    /// list for its selected items and checks their frames: an icon with its name below it, or a list or column row.
    /// The containers for each window are found once and cached. Any answer that doesn't come within `budget`
    /// seconds in all is `.none`, and so is anything off a selected item (an unselected file, empty space, chrome).
    static func finderTarget(at point: CGPoint, window: (id: CGWindowID, frame: CGRect, desktop: Bool),
                             finderPID: pid_t, budget: TimeInterval? = nil) -> HoldKeyTarget {
        let budget = budget ?? (FinderLists.shared.knows(window.id) ? 0.04 : 0.08)
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        func timeLeft() -> Float { Float(max(0.005, deadline - ProcessInfo.processInfo.systemUptime)) }
        func late() -> Bool { ProcessInfo.processInfo.systemUptime >= deadline }
        let containers = FinderLists.shared.containers(window: window, finderPID: finderPID, timeLeft: timeLeft, late: late)
        for list in containers {
            guard !late() else { return .none }
            AXUIElementSetMessagingTimeout(list, timeLeft())
            guard let selected = attribute(list, kAXSelectedChildrenAttribute) as? [AXUIElement] else {
                FinderLists.shared.forget(window.id)   // the list went away (the window changed view): look again next time
                continue
            }
            for item in selected.prefix(400) {
                guard !late() else { return .none }
                AXUIElementSetMessagingTimeout(item, timeLeft())
                let role = attribute(item, kAXRoleAttribute) as? String ?? ""
                var frame = Self.frame(item)
                if role != kAXRowRole {
                    // An icon: its frame is the picture only; the name sits below it and may be wider.
                    frame = CGRect(x: frame.minX - 28, y: frame.minY - 4, width: frame.width + 56, height: frame.height + 44)
                }
                if frame.contains(point) { return HoldKeyTarget(isFile: true, selected: true) }
            }
        }
        return .none
    }

    static func frame(_ e: AXUIElement) -> CGRect {
        var p = CGPoint.zero, s = CGSize.zero
        if let v = attribute(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
        if let v = attribute(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }

    fileprivate static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}

/// For each Finder window, the lists that hold its files (icon view, list view, every column of column view, or
/// the desktop), found once by walking the window's accessibility tree and kept until they stop answering.
/// Used only on the tap's thread.
final class FinderLists {
    static let shared = FinderLists()
    private var cache: [CGWindowID: [AXUIElement]] = [:]
    private let lock = NSLock()

    func forget(_ id: CGWindowID) { lock.lock(); cache[id] = nil; lock.unlock() }
    func knows(_ id: CGWindowID) -> Bool { lock.lock(); defer { lock.unlock() }; return cache[id] != nil }

    func containers(window: (id: CGWindowID, frame: CGRect, desktop: Bool), finderPID: pid_t,
                    timeLeft: () -> Float, late: () -> Bool) -> [AXUIElement] {
        lock.lock(); let hit = cache[window.id]; lock.unlock()
        if let hit { return hit }
        let app = AXUIElementCreateApplication(finderPID)
        AXUIElementSetMessagingTimeout(app, timeLeft())
        // The window's accessibility element: the one with the same frame (the desktop is a scroll area).
        var root: AXUIElement?
        if window.desktop {
            root = (HoldKeyTap.attribute(app, kAXChildrenAttribute) as? [AXUIElement] ?? [])
                .first { (HoldKeyTap.attribute($0, kAXRoleAttribute) as? String) == kAXScrollAreaRole }
        } else {
            root = (HoldKeyTap.attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).first { w in
                let f = HoldKeyTap.frame(w)
                return abs(f.minX - window.frame.minX) < 2 && abs(f.minY - window.frame.minY) < 2
                    && abs(f.width - window.frame.width) < 2 && abs(f.height - window.frame.height) < 2
            }
        }
        guard let root else { return [] }
        // Breadth-first, a few levels deep, looking for lists that report selected children. The file lists sit
        // near the top (window › split group › split group › scroll area › list), so this stays small.
        let listRoles: Set<String> = [kAXListRole, kAXOutlineRole, kAXTableRole, kAXGroupRole]
        var found: [AXUIElement] = []
        var level = [root]
        for _ in 0..<7 where !level.isEmpty && !late() {
            var next: [AXUIElement] = []
            for e in level {
                AXUIElementSetMessagingTimeout(e, timeLeft())
                let role = HoldKeyTap.attribute(e, kAXRoleAttribute) as? String ?? ""
                let label = (HoldKeyTap.attribute(e, kAXDescriptionAttribute) as? String) ?? (HoldKeyTap.attribute(e, kAXTitleAttribute) as? String) ?? ""
                if label == "sidebar" { continue }   // the sidebar lists places, not the files you drag
                if listRoles.contains(role), HoldKeyTap.attribute(e, kAXSelectedChildrenAttribute) != nil {
                    found.append(e)
                    continue   // its children are files, not more lists
                }
                if role == kAXToolbarRole { continue }
                next += (HoldKeyTap.attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(16)
            }
            level = next
        }
        if !late() {   // a complete answer is worth keeping; a rushed one is tried again next press
            lock.lock(); cache[window.id] = found; lock.unlock()
        }
        return found
    }
}

/// One run of the tap: its thread, tap, loop and per-press state. Everything except `loop` (handed over through
/// a semaphore at start) and `cancelled` (under a lock) is touched only on the run's own thread.
private final class TapRun {
    unowned let owner: HoldKeyTap
    private(set) var loop: CFRunLoop?
    private var tap: CFMachPort?
    private var decider = HoldKeyDecider()
    private var heldDown: CGEvent?
    private var timer: Timer?
    private let cancelledFlag = OSAllocatedUnfairLock(initialState: false)

    init(owner: HoldKeyTap) { self.owner = owner }

    /// Asks a run that hasn't reported in time to shut down as soon as it can.
    func cancel() { cancelledFlag.withLock { $0 = true }; end() }

    /// Ends the run's loop (main thread).
    func end() {
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(loop) }
        CFRunLoopWakeUp(loop)
    }

    /// The thread's body: create the tap, report (loop set, or nil on failure), run until ended.
    func body(_ started: () -> Void) {
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<TapRun>.fromOpaque(refcon).takeUnretainedValue().handle(proxy, type, event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            started()
            return
        }
        let runLoop = CFRunLoopGetCurrent()!
        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(runLoop, src, .commonModes)
        tap = port
        loop = runLoop
        started()
        if !cancelledFlag.withLock({ $0 }) {
            CGEvent.tapEnable(tap: port, enable: true)
            DragMonitor.log.notice("hold-key tap: on")
            CFRunLoopRun()
        }
        // Ended: switch the tap off first, then give back any press still held.
        CGEvent.tapEnable(tap: port, enable: false)
        flushHeld()
        CFRunLoopRemoveSource(runLoop, src, .commonModes)
        CFMachPortInvalidate(port)
        tap = nil
        DragMonitor.log.notice("hold-key tap: off")
    }

    private func handle(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Events went past while the tap was off: give back any held press (with an up if the button is up).
            flushHeld()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == HoldKeyTap.marker { return Unmanaged.passUnretained(event) }
        let kind: HoldKeyDecider.Kind
        switch type {
        case .leftMouseDown: kind = .down
        case .leftMouseDragged: kind = .dragged
        case .leftMouseUp: kind = .up
        default: return Unmanaged.passUnretained(event)
        }
        let location = event.location
        let state = owner.shared.withLock { $0 }
        let action = decider.decide(kind, flags: event.flags, location: location,
                                    time: ProcessInfo.processInfo.systemUptime, wheelFlags: state.wheelFlags,
                                    target: {
                                        guard let window = HoldKeyTap.finderWindow(event, finderPID: state.finderPID) else { return .none }
                                        return HoldKeyTap.finderTarget(at: location, window: window, finderPID: state.finderPID)
                                    })
        switch action {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .swallow:
            if kind == .down {
                heldDown = event.copy()
                scheduleLongPress()
            }
            return nil
        case .releaseAsDrag(let strip):
            // tapPostEvent puts the held down into the stream just before the event returned here, and only the
            // taps after this one see it: right order, no duplicates.
            timer?.invalidate()
            if let down = heldDown?.copy() {
                down.flags = HoldKeyTap.removing(strip, from: down.flags)
                down.tapPostEvent(proxy)
            }
            heldDown = nil
            event.flags = HoldKeyTap.removing(strip, from: event.flags)
            return Unmanaged.passUnretained(event)
        case .releaseAsClick:
            timer?.invalidate()
            heldDown?.tapPostEvent(proxy)
            heldDown = nil
            return Unmanaged.passUnretained(event)
        case .strip(let strip):
            event.flags = HoldKeyTap.removing(strip, from: event.flags)
            return Unmanaged.passUnretained(event)
        }
    }

    /// A press that hasn't become a drag or a click within `longPress` goes on as it was.
    private func scheduleLongPress() {
        timer?.invalidate()
        let t = Timer(timeInterval: HoldKeyDecider.longPress, repeats: false) { [weak self] _ in
            guard let self, self.decider.timedOut(now: ProcessInfo.processInfo.systemUptime) else { return }
            self.giveBack()
        }
        RunLoop.current.add(t, forMode: .common)   // this run's thread
        timer = t
    }

    /// Never leave a mouse-down held back (the tap is being turned off or was disabled).
    private func flushHeld() {
        timer?.invalidate()
        if decider.isHolding { giveBack() }
        heldDown = nil
        decider.reset()
    }

    /// Sends the held mouse-down on unchanged, from outside a callback. If the button is already up (its up went
    /// past while the tap was off, or is queued behind us), also sends a matching up, so no app is left with a
    /// press that never ends.
    private func giveBack() {
        guard let down = heldDown else { return }
        heldDown = nil
        post(down)
        if !CGEventSource.buttonState(.hidSystemState, button: .left), let up = down.copy() {
            up.type = .leftMouseUp
            post(up)
        }
    }

    private func post(_ event: CGEvent) {
        guard let copy = event.copy() else { return }
        copy.setIntegerValueField(.eventSourceUserData, value: HoldKeyTap.marker)
        copy.post(tap: .cgSessionEventTap)
    }
}

/// `--selftest holdkey`: the decider's rules, without an event tap.
enum HoldKey: FeatureModule {
    static var commands: [WheelCommand] { [] }

    static func selfTest(_ name: String) -> String? {
        // `--selftest holdkey-at:<CG window id>:<x>,<y>` (diagnostic, read-only): what a press there would be.
        if name.hasPrefix("holdkey-at:") {
            let parts = name.dropFirst("holdkey-at:".count).split(separator: ":")
            guard parts.count == 2, let id = UInt32(parts[0]) else { return "FAIL usage: holdkey-at:<window id>:<x>,<y>" }
            let xy = parts[1].split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2, let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
                  let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
                  let b = info[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b)
            else { return "FAIL no such window" }
            let window = (id: id, frame: r, desktop: (info[kCGWindowLayer as String] as? Int ?? 0) < 0)
            var lines = ["trusted: \(AXIsProcessTrusted())"]
            for pass in ["first (finds the lists)", "second (cached)"] {
                let t0 = ProcessInfo.processInfo.systemUptime
                let target = HoldKeyTap.finderTarget(at: CGPoint(x: xy[0], y: xy[1]), window: window, finderPID: finder.processIdentifier)
                let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
                lines.append("\(pass): file=\(target.isFile) selected=\(target.selected.map { "\($0)" } ?? "-") in \(String(format: "%.1f", ms)) ms")
            }
            return "OK holdkey-at\n" + lines.joined(separator: "\n")
        }
        guard name == "holdkey" else { return nil }
        var failures: [String] = []
        var passed = 0
        func check(_ label: String, _ ok: Bool) { if ok { passed += 1 } else { failures.append(label) } }
        let wheel: CGEventFlags = [.maskShift, .maskCommand, .maskControl, .maskAlternate]
        let p0 = CGPoint(x: 100, y: 100)
        let selectedFile = HoldKeyTarget(isFile: true, selected: true)
        func run(_ steps: [(HoldKeyDecider.Kind, CGEventFlags, CGPoint, TimeInterval)],
                 target: HoldKeyTarget = HoldKeyTarget(isFile: true, selected: true)) -> [HoldKeyDecider.Action] {
            var d = HoldKeyDecider()
            return steps.map { d.decide($0.0, flags: $0.1, location: $0.2, time: $0.3, wheelFlags: wheel, target: { target }) }
        }
        check("no key: a press passes", run([(.down, [], p0, 0)]) == [.pass])
        check("key held, not on a file (empty space, window chrome, outside Finder): passes",
              run([(.down, .maskShift, p0, 0)], target: .none) == [.pass])
        check("⇧ or ⌘ on an unselected file: passes (Finder adds it and drags the selection)",
              run([(.down, .maskCommand, p0, 0)], target: HoldKeyTarget(isFile: true, selected: false)) == [.pass]
              && run([(.down, .maskShift, p0, 0)], target: HoldKeyTarget(isFile: true, selected: false)) == [.pass])
        check("⌃ on any file, alone or with ⇧/⌘: held (it would be a right-click)",
              run([(.down, .maskControl, p0, 0)], target: HoldKeyTarget(isFile: true, selected: false)) == [.swallow]
              && run([(.down, [.maskControl, .maskShift], p0, 0)], target: HoldKeyTarget(isFile: true, selected: false)) == [.swallow])
        check("⌥ alone: never held (Finder starts the drag by itself)",
              run([(.down, .maskAlternate, p0, 0)], target: HoldKeyTarget(isFile: true, selected: true)) == [.pass])
        check("selection unknown: held", run([(.down, .maskShift, p0, 0)], target: HoldKeyTarget(isFile: true, selected: nil)) == [.swallow])
        check("unrelated flag (caps lock) alone: passes", run([(.down, .maskAlphaShift, p0, 0)], target: selectedFile) == [.pass])
        let drag = run([(.down, .maskShift, p0, 0), (.dragged, .maskShift, CGPoint(x: 103, y: 100), 0.02),
                        (.dragged, .maskShift, CGPoint(x: 106, y: 100), 0.04), (.dragged, .maskShift, CGPoint(x: 140, y: 100), 0.1),
                        (.up, .maskShift, CGPoint(x: 140, y: 100), 0.5)])
        check("⇧ on a selected file: held, released as a drag without ⇧ at 6 pt, then stripped to the end",
              drag == [.swallow, .swallow, .releaseAsDrag(strip: .maskShift), .strip(.maskShift), .strip(.maskShift)])
        let wobble = run([(.down, .maskCommand, p0, 0), (.dragged, .maskCommand, CGPoint(x: 104, y: 103), 0.05), (.up, .maskCommand, p0, 0.12)])
        check("⌘-click with a 5 pt wobble stays a ⌘-click", wobble == [.swallow, .swallow, .releaseAsClick])
        let ctrl = run([(.down, [.maskControl, .maskShift], p0, 0), (.dragged, .maskControl, CGPoint(x: 110, y: 100), 0.05)])
        check("⌃⇧ held: both stripped (no right-click)", ctrl == [.swallow, .releaseAsDrag(strip: [.maskControl, .maskShift])])
        let keepOther = run([(.down, [.maskShift, .maskAlphaShift], p0, 0), (.dragged, .maskShift, CGPoint(x: 110, y: 100), 0.05)])
        check("only wheel flags are stripped", keepOther == [.swallow, .releaseAsDrag(strip: .maskShift)])
        var d = HoldKeyDecider()
        _ = d.decide(.down, flags: .maskShift, location: p0, time: 0, wheelFlags: wheel, target: { selectedFile })
        check("long press: no give-back before 0.8 s", !d.timedOut(now: 0.5))
        check("long press: given back at 0.8 s", d.timedOut(now: 0.8) && !d.isHolding)
        check("after a give-back, the rest of the press passes",
              d.decide(.dragged, flags: .maskShift, location: CGPoint(x: 150, y: 100), time: 0.9, wheelFlags: wheel, target: { selectedFile }) == .pass
              && d.decide(.up, flags: .maskShift, location: p0, time: 1, wheelFlags: wheel, target: { selectedFile }) == .pass)
        check("the next press starts fresh", run([(.down, .maskShift, p0, 0), (.up, .maskShift, p0, 0.1), (.down, [], p0, 0.3)])
              == [.swallow, .releaseAsClick, .pass])
        check("a second down while holding lets both through", run([(.down, .maskShift, p0, 0), (.down, .maskShift, p0, 0.2)])
              == [.swallow, .releaseAsClick])
        let stripped = HoldKeyTap.removing(.maskShift, from: CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x2 | 0x100))
        check("stripping ⇧ also clears the left-shift bit and keeps others", stripped.rawValue == 0x100)
        check("wheel flags follow the keys (defaults: ⇧ ⌘ ⌃ plus ⌥ for ⌃)",
              HoldKeyTap.wheelFlags(.defaults) == [.maskShift, .maskCommand, .maskControl, .maskAlternate])
        check("wheel flags: Off wheels add nothing",
              HoldKeyTap.wheelFlags(WheelKeyMap(convert: .shift, tools: .off, actions: .off)) == .maskShift)
        let report = "\(passed)/\(passed + failures.count) checks passed"
        return failures.isEmpty ? "PASS holdkey: \(report)" : "FAIL holdkey: \(report)\n" + failures.map { "  ✗ \($0)" }.joined(separator: "\n")
    }
}
