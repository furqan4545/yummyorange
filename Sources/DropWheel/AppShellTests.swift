#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import AVFoundation
import SwiftUI

/// Headless checks for the app shell: `--selftest gesture`, `wheel`, `settings` (or `appshell` for all).
enum AppShellTests {
    /// Collects named checks into a report that starts with PASS or FAIL.
    final class Checker {
        private(set) var total = 0
        private(set) var failures: [String] = []
        var notes: [String] = []

        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            total += 1
            if !ok { failures.append(detail().isEmpty ? name : "\(name): \(detail())") }
        }

        func report(_ title: String) -> String {
            var lines = ["\(failures.isEmpty ? "PASS" : "FAIL") \(title): \(total - failures.count)/\(total) checks passed"]
            lines += failures.map { "  ✗ \($0)" }
            lines += notes.map { "  · \($0)" }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Gesture

    static let sampleFiles = [URL(fileURLWithPath: "/tmp/sample photo.png"), URL(fileURLWithPath: "/tmp/sample.pdf")]

    /// Drives a recognizer with synthetic polls at 60 Hz.
    struct Script {
        var recognizer = DragGestureRecognizer()
        var time: TimeInterval = 1000
        var location = CGPoint(x: 400, y: 400)
        var flags: NSEvent.ModifierFlags = []
        var escape = false
        var comma = false
        var mouseDown = false
        var changeCount = 7
        var pressEvent: DragPressEvent?
        var log: [DragGestureEvent] = []

        init(keys: WheelKeyMap = .defaults, files: [URL] = AppShellTests.sampleFiles,
             dock: DockGeometry? = nil, frontmost: String? = "com.apple.finder") {
            recognizer.keys = keys
            recognizer.readFiles = { files }
            recognizer.frontmostBundleID = { frontmost }
            if let dock { recognizer.isInDock = { dock.contains($0) } }
        }

        var opens: [WheelMode] { log.compactMap { if case .open(let m, _) = $0 { return m } else { return nil } } }

        @discardableResult
        mutating func tick(_ dt: TimeInterval = 1.0 / 60) -> [DragGestureEvent] {
            time += dt
            let input = DragGestureInput(time: time, mouseDown: mouseDown, location: location, flags: flags,
                                         escapeDown: escape, commaDown: comma, changeCount: changeCount, press: pressEvent)
            pressEvent = nil
            let events = recognizer.step(input)
            log += events
            return events
        }

        /// Lets `seconds` pass and polls once at the end.
        @discardableResult
        mutating func wait(_ seconds: TimeInterval) -> [DragGestureEvent] { tick(seconds) }

        @discardableResult
        mutating func press(at p: CGPoint? = nil) -> [DragGestureEvent] {
            if let p { location = p }
            mouseDown = true
            return tick()
        }
        /// The drag pasteboard changes: some app started a drag.
        @discardableResult
        mutating func startDrag() -> [DragGestureEvent] { changeCount += 1; return tick() }
        @discardableResult
        mutating func move(_ dx: CGFloat, _ dy: CGFloat = 0) -> [DragGestureEvent] {
            location.x += dx; location.y += dy
            return tick()
        }
        @discardableResult
        mutating func keyDown(_ f: NSEvent.ModifierFlags) -> [DragGestureEvent] { flags.insert(f); return tick() }
        @discardableResult
        mutating func keyUp(_ f: NSEvent.ModifierFlags) -> [DragGestureEvent] { flags.remove(f); return tick() }
        /// Press and release a modifier; returns the events from the press.
        @discardableResult
        mutating func tap(_ f: NSEvent.ModifierFlags) -> [DragGestureEvent] {
            let e = keyDown(f)
            keyUp(f)
            return e
        }
        @discardableResult
        mutating func release() -> [DragGestureEvent] { mouseDown = false; return tick() }

        /// Press, start a file drag and move past the threshold.
        mutating func validDrag(at p: CGPoint? = nil) {
            press(at: p)
            startDrag()
            move(10)
        }
    }

    static func gesture() -> String {
        let c = Checker()
        let files = sampleFiles
        let open: (WheelMode) -> [DragGestureEvent] = { [.open($0, files)] }

        // Basic gesture and switching
        do {
            var s = Script()
            s.validDrag()
            c.check("drag counts once moved with files", s.recognizer.isDragActive)
            c.check("⇧ opens Convert", s.tap(.shift) == open(.convert), "\(s.log)")
            c.check("⌘ switches to Tools", s.tap(.command) == open(.tools))
            c.check("⌃ switches to Actions", s.tap(.control) == open(.actions))
            c.check("⇧ switches back to Convert", s.tap(.shift) == open(.convert))
            c.check("⌥ opens the ⌃ wheel (Actions) with default keys", s.tap(.option) == open(.actions))
            c.check("tapping the same key twice reports it twice", s.tap(.shift) == open(.convert) && s.tap(.shift) == open(.convert))
            c.check("release ends the drag", s.release() == [.dragEnded])
            c.check("nothing after release", s.tap(.shift).isEmpty && !s.recognizer.isDragActive)
            c.check("only one dragEnded", s.tick().isEmpty)
        }

        // Movement threshold
        do {
            var s = Script()
            s.press(); s.startDrag(); s.move(5)
            c.check("5 pt is not a drag", !s.recognizer.isDragActive)
            c.check("tap under 6 pt opens nothing yet", s.tap(.shift).isEmpty)
            s.wait(0.5)
            let e = s.move(1)
            c.check("exactly 6 pt counts", s.recognizer.isDragActive)
            c.check("a key tapped before 6 pt opens its wheel once the drag counts, however late", e == open(.convert), "\(e)")
            c.check("tapping it again reports it again", s.tap(.shift) == open(.convert))
        }
        do {
            var s = Script(); s.press(); s.startDrag(); s.move(4.2, 4.2)
            c.check("diagonal 5.94 pt is not a drag", !s.recognizer.isDragActive)
            s.move(0.05, 0.05)
            c.check("diagonal 6.01 pt counts", s.recognizer.isDragActive)
        }
        do {
            var s = Script(); s.press(); s.startDrag(); s.move(5.99)
            c.check("5.99 pt is not a drag", !s.recognizer.isDragActive)
        }
        do {
            var s = Script(); s.press(); s.startDrag(); s.move(8); s.move(-8)
            c.check("movement latches after going back to the start", s.recognizer.isDragActive && s.tap(.shift) == open(.convert))
        }
        do {
            var s = Script(); s.press(); s.move(3); s.startDrag(); s.move(3)
            c.check("movement is measured from the mouse-down point", s.recognizer.isDragActive)
        }
        do {
            var s = Script(); s.press(); s.startDrag(); s.move(-3, 0); s.move(0, -5.2)
            c.check("movement in any direction counts (hypot 6.0)", s.recognizer.isDragActive)
        }

        // The armed wheel persists through the press
        for wait in [0.10, 0.35, 0.36, 2.0] {
            var s = Script()
            s.press(); s.startDrag(); s.move(2)
            s.tap(.shift)
            s.wait(wait)
            c.check("a tap \(Int(wait * 1000)) ms before the drag counted still opens", s.move(8) == open(.convert), "\(s.log)")
        }
        do {
            var s = Script(); s.press(); s.move(10)                 // moving, but the pasteboard hasn't changed yet
            s.tap(.command)
            s.wait(0.8)
            c.check("a late drag pasteboard opens the armed wheel", s.startDrag() == open(.tools), "\(s.log)")
        }
        do {
            var s = Script(); s.press(); s.startDrag(); s.move(2)
            s.tap(.shift); s.tap(.command)
            c.check("the last key pressed wins", s.move(8) == open(.tools), "\(s.log)")
        }
        do {
            var s = Script(); s.validDrag(); s.tap(.shift)
            c.check("releasing the key keeps the wheel (no events)", s.tick().isEmpty && s.move(30).isEmpty)
        }

        // Keys held as the mouse goes down (hold ⇧, then drag)
        do {
            var s = Script()
            s.flags = .shift
            s.press()                              // ⇧ held, then the mouse goes down
            c.check("holding ⇧ arms Convert at the press", s.recognizer.armedMode == .convert)
            s.startDrag()
            let e = s.move(10)
            c.check("hold ⇧ then drag: Convert opens as soon as the drag counts", e == open(.convert), "\(s.log)")
            c.check("letting go of ⇧ keeps it open", s.keyUp(.shift).isEmpty)
            c.check("tapping ⇧ again reports it again", s.tap(.shift) == open(.convert))
        }
        do {
            var s = Script()
            s.keyDown(.command); s.wait(0.5)       // ⌘ held well before the press
            s.press(); s.startDrag()
            c.check("hold ⌘ then drag: Tools opens", s.move(10) == open(.tools), "\(s.log)")
            c.check("pressing ⌃ while dragging switches to Actions", s.keyDown(.control) == open(.actions))
        }
        do {
            var s = Script()
            s.flags = .shift
            s.press(); s.move(20)                  // ⇧-click and move with no drag (selecting text, a rubber band)
            c.check("hold ⇧ and move without a drag opens nothing", s.opens.isEmpty && !s.recognizer.isDragActive)
            c.check("…and is reported as a stalled held-key press (Finder deselected the file)", s.recognizer.heldKeyPressStalled)
            var t = Script(); t.press(); t.move(20)
            c.check("a plain press and move isn’t a stalled held-key press", !t.recognizer.heldKeyPressStalled)
        }
        do {
            var s = Script()
            s.flags = .option
            s.press(); s.startDrag()
            c.check("hold ⌥ then drag: Actions opens (⌥ stands in for ⌃, which would right-click)", s.move(10) == open(.actions))
            var t = Script(keys: WheelKeyMap(convert: .shift, tools: .command, actions: .off))
            t.flags = .option
            t.press(); t.startDrag()
            c.check("⌥ arms nothing when no wheel uses ⌃ or ⌥", t.move(10).isEmpty && t.recognizer.armedMode == nil)
            var u = Script(keys: WheelKeyMap(convert: .shift, tools: .option, actions: .control))
            u.validDrag()
            c.check("⌥ opens its own wheel when one uses it (Tools), not the ⌃ wheel", u.tap(.option) == open(.tools))
        }
        do {
            var s = Script()
            s.tap(.shift); s.wait(0.05)            // tapped and released just before the press
            s.press(); s.startDrag(); s.move(10)
            c.check("a key released before the mouse-down doesn’t count", s.opens.isEmpty, "\(s.opens)")
        }
        do {
            var s = Script(); s.tap(.shift)
            c.check("a tap with no press does nothing", s.log.isEmpty)
        }

        // Escape
        do {
            var s = Script(); s.validDrag(); s.tap(.shift)
            s.escape = true
            c.check("Esc cancels", s.tick() == [.cancel])
            c.check("holding Esc cancels once", s.tick().isEmpty && s.tick().isEmpty)
            s.escape = false; s.tick()
            s.escape = true
            c.check("Esc again cancels again", s.tick() == [.cancel])
            s.escape = false; s.tick()
            c.check("a tap after Esc opens again", s.tap(.control) == open(.actions))
        }
        do {
            var s = Script(); s.press(); s.startDrag(); s.move(2); s.tap(.shift)
            s.escape = true; s.tick(); s.escape = false
            c.check("Esc before the drag counts drops the pending tap", s.move(8).isEmpty && s.opens.isEmpty)
        }
        do {
            var s = Script(); s.press(); s.startDrag(); s.move(2); s.tap(.shift)
            s.escape = true
            let e = s.move(8)
            c.check("Esc on the tick the drag counts doesn’t open", !e.contains(where: { if case .open = $0 { return true }; return false }), "\(e)")
        }
        do {
            var s = Script(files: []); s.validDrag()
            s.escape = true
            c.check("Esc during a non-file drag does nothing", s.tick().isEmpty)
        }

        // Comma
        do {
            var s = Script(); s.validDrag()
            s.comma = true
            c.check("comma during a drag opens Settings", s.tick() == [.openSettings])
            c.check("holding comma opens Settings once", s.tick().isEmpty)
        }
        do {
            var s = Script(); s.press(); s.move(2)
            s.comma = true
            c.check("comma while clicking (no drag) does nothing", s.tick().isEmpty)
            s.comma = false; s.release(); s.comma = true
            c.check("comma with the mouse up does nothing", s.tick().isEmpty)
        }

        // Fresh state per press
        do {
            var s = Script(); s.press(); s.startDrag(); s.move(2); s.tap(.shift); s.release()
            s.wait(0.05); s.press(); s.startDrag(); s.move(10)
            c.check("a pending tap doesn’t carry into the next press", s.opens.isEmpty)
        }
        do {
            var s = Script(); s.press(); s.move(20)
            c.check("no pasteboard change means no drag", s.tap(.shift).isEmpty && !s.recognizer.isDragActive)
        }

        // Custom keys
        do {
            var s = Script(keys: WheelKeyMap(convert: .option, tools: .shift, actions: .off))
            s.validDrag()
            c.check("custom: ⌥ opens Convert", s.tap(.option) == open(.convert))
            c.check("custom: ⇧ opens Tools", s.tap(.shift) == open(.tools))
            c.check("custom: ⌃ opens nothing (Actions off)", s.tap(.control).isEmpty)
            c.check("custom: ⌘ opens nothing (unassigned)", s.tap(.command).isEmpty)
        }
        do {
            var s = Script(keys: WheelKeyMap(convert: .off, tools: .off, actions: .off))
            s.validDrag()
            let any = [s.tap(.shift), s.tap(.command), s.tap(.control), s.tap(.option)].flatMap { $0 }
            c.check("all wheels off: no modifier opens anything", any.isEmpty)
        }
        do {
            var s = Script(); s.validDrag()
            c.check("⇧⌘ together open the first wheel in order (Convert)", s.tap([.shift, .command]) == open(.convert))
            var t = Script(keys: WheelKeyMap(convert: .command, tools: .shift, actions: .control)); t.validDrag()
            c.check("custom ⇧⌘ together open Convert (⌘)", t.tap([.shift, .command]) == open(.convert))
        }
        do {
            var s = Script(); s.validDrag()
            s.keyDown(.shift)
            c.check("adding ⌘ while ⇧ is held switches to Tools", s.keyDown(.command) == open(.tools))
        }

        // Ignored sources
        do {
            var s = Script(files: []); s.validDrag()
            c.check("a drag without files is ignored", s.tap(.shift).isEmpty && s.recognizer.ignoreReason == .notFiles)
        }
        for id in ["com.adobe.InDesign", "com.adobe.indesign.2025", "COM.ADOBE.INDESIGN"] {
            var s = Script(frontmost: id); s.validDrag()
            c.check("drag while \(id) is frontmost is ignored", s.tap(.shift).isEmpty && s.recognizer.ignoreReason == .ignoredApp)
        }
        do {
            var s = Script(frontmost: "com.adobe.Illustrator"); s.validDrag()
            c.check("other Adobe apps are not ignored", s.tap(.shift) == open(.convert))
            var t = Script(frontmost: nil); t.validDrag()
            c.check("no frontmost app is fine", t.tap(.shift) == open(.convert))
        }

        // Dock geometry
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        func geo(_ visible: CGRect, _ edge: DockGeometry.Edge, autohide: Bool = false, extra: [DockGeometry.Screen] = []) -> DockGeometry {
            DockGeometry(screens: [DockGeometry.Screen(frame: main, visibleFrame: visible)] + extra, edge: edge, autohide: autohide)
        }
        let bottom = geo(CGRect(x: 0, y: 70, width: 1440, height: 805), .bottom)
        c.check("bottom Dock: press in it", bottom.contains(CGPoint(x: 700, y: 30)))
        c.check("bottom Dock: press at its very edge", bottom.contains(CGPoint(x: 700, y: 0)))
        c.check("bottom Dock: 69.5 pt is still Dock", bottom.contains(CGPoint(x: 700, y: 69.5)))
        c.check("bottom Dock: 70 pt is the desktop", !bottom.contains(CGPoint(x: 700, y: 70)))
        c.check("bottom Dock: the menu bar isn’t Dock", !bottom.contains(CGPoint(x: 700, y: 890)))
        c.check("bottom Dock: the strip beside the Dock counts too", bottom.contains(CGPoint(x: 5, y: 30)))
        let left = geo(CGRect(x: 64, y: 0, width: 1376, height: 875), .left)
        c.check("left Dock: press in it", left.contains(CGPoint(x: 20, y: 400)))
        c.check("left Dock: 64 pt is the desktop", !left.contains(CGPoint(x: 64, y: 400)))
        c.check("left Dock: the bottom edge isn’t Dock", !left.contains(CGPoint(x: 700, y: 2)))
        let right = geo(CGRect(x: 0, y: 0, width: 1376, height: 875), .right)
        c.check("right Dock: press in it", right.contains(CGPoint(x: 1420, y: 400)))
        c.check("right Dock: 1375 pt is the desktop", !right.contains(CGPoint(x: 1375, y: 400)))
        c.check("right Dock: the left edge isn’t Dock", !right.contains(CGPoint(x: 2, y: 400)))
        let hiddenBottom = geo(CGRect(x: 0, y: 0, width: 1440, height: 875), .bottom, autohide: true)
        c.check("hidden bottom Dock: band at 2 pt", hiddenBottom.contains(CGPoint(x: 700, y: 2)))
        c.check("hidden bottom Dock: band at 4.9 pt", hiddenBottom.contains(CGPoint(x: 700, y: 4.9)))
        c.check("hidden bottom Dock: 5 pt is the desktop", !hiddenBottom.contains(CGPoint(x: 700, y: 5)))
        c.check("hidden bottom Dock: 60 pt is the desktop", !hiddenBottom.contains(CGPoint(x: 700, y: 60)))
        let hidden4 = geo(CGRect(x: 0, y: 4, width: 1440, height: 871), .bottom, autohide: true)
        c.check("hidden Dock with a 4 pt reserved strip: 3 pt is Dock, 6 pt isn’t",
                hidden4.contains(CGPoint(x: 700, y: 3)) && !hidden4.contains(CGPoint(x: 700, y: 6)))
        let hiddenLeft = geo(CGRect(x: 0, y: 0, width: 1440, height: 875), .left, autohide: true)
        c.check("hidden left Dock: band", hiddenLeft.contains(CGPoint(x: 2, y: 400)) && !hiddenLeft.contains(CGPoint(x: 6, y: 400)))
        let hiddenRight = geo(CGRect(x: 0, y: 0, width: 1440, height: 875), .right, autohide: true)
        c.check("hidden right Dock: band",
                hiddenRight.contains(CGPoint(x: 1438, y: 400)) && !hiddenRight.contains(CGPoint(x: 1434, y: 400)))
        let above = DockGeometry.Screen(frame: CGRect(x: 0, y: 900, width: 1920, height: 1080),
                                        visibleFrame: CGRect(x: 0, y: 900, width: 1920, height: 1055))
        let stacked = geo(CGRect(x: 0, y: 0, width: 1440, height: 875), .bottom, autohide: true, extra: [above])
        c.check("stacked screens: the seam between them isn’t a Dock band", !stacked.contains(CGPoint(x: 700, y: 902)))
        c.check("stacked screens: an outer bottom edge of the upper screen is", stacked.contains(CGPoint(x: 1700, y: 902)))
        c.check("stacked screens: the lower screen’s bottom is", stacked.contains(CGPoint(x: 700, y: 1)))
        let side = DockGeometry.Screen(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                                       visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
        let sideBySide = geo(CGRect(x: 0, y: 0, width: 1440, height: 875), .right, autohide: true, extra: [side])
        c.check("side-by-side screens: the seam isn’t a Dock band", !sideBySide.contains(CGPoint(x: 1438, y: 400)))
        c.check("side-by-side screens: the far right edge is", sideBySide.contains(CGPoint(x: 3358, y: 500)))
        let dockOnSecond = geo(CGRect(x: 0, y: 0, width: 1440, height: 875), .bottom, extra: [
            DockGeometry.Screen(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                                visibleFrame: CGRect(x: 1440, y: 80, width: 1920, height: 975))])
        c.check("Dock on the second screen: the first screen’s bottom isn’t Dock", !dockOnSecond.contains(CGPoint(x: 700, y: 10)))
        c.check("Dock on the second screen: its own bottom is", dockOnSecond.contains(CGPoint(x: 2000, y: 10)))
        c.check("a point on no screen isn’t Dock", !bottom.contains(CGPoint(x: -50, y: -50)))
        do {
            var s = Script(dock: bottom)
            s.validDrag(at: CGPoint(x: 700, y: 30))
            s.move(0, 100)
            c.check("a drag that starts on the Dock is ignored", s.tap(.shift).isEmpty && s.recognizer.ignoreReason == .dock)
            s.release()
            s.validDrag(at: CGPoint(x: 700, y: 300))
            c.check("the next drag from the desktop works", s.tap(.shift) == open(.convert))
        }

        // Mouse-down events from the monitor
        do {
            var s = Script(dock: bottom)
            s.location = CGPoint(x: 700, y: 80)    // the poll sees the mouse already off the Dock...
            s.pressEvent = DragPressEvent(location: CGPoint(x: 700, y: 30), time: s.time + 0.005, changeCount: s.changeCount)
            s.press(); s.startDrag(); s.move(0, 20)
            c.check("the exact press point from the event decides the Dock test", s.tap(.shift).isEmpty && s.recognizer.ignoreReason == .dock)
        }
        do {
            var s = Script()
            s.pressEvent = DragPressEvent(location: s.location, time: s.time + 0.005, changeCount: s.changeCount)
            s.changeCount += 1                     // the drag began between the event and the first poll
            s.press(); s.move(10)
            c.check("a drag that starts before the first poll is still seen (event count)", s.tap(.shift) == open(.convert))
            var t = Script()
            t.changeCount += 1
            t.press(); t.move(10)
            c.check("without the event that drag is missed (why the monitor exists)", t.tap(.shift).isEmpty)
        }
        do {
            var s = Script()
            s.tick()                               // up poll sees the old count
            s.changeCount += 1                     // Finder writes the drag pasteboard...
            s.pressEvent = DragPressEvent(location: s.location, time: s.time + 0.005, changeCount: s.changeCount)
            s.press(); s.move(10)                  // ...before the mouse-down event is delivered
            c.check("a late mouse-down event doesn’t hide a fast drag (the smaller count wins)", s.tap(.shift) == open(.convert), "\(s.log)")
        }
        do {
            var s = Script()
            s.pressEvent = DragPressEvent(location: CGPoint(x: 0, y: 0), time: s.time - 2, changeCount: 0)
            s.press(); s.startDrag(); s.move(10)
            c.check("a stale press event is ignored", s.tap(.shift) == open(.convert))
        }

        // Presses no monitor reported (before the local monitor, every press in YummyOrange's own windows): the
        // last button-up poll gives the baseline, so a flick-drag written before the first down poll still counts.
        do {
            var s = Script()
            s.tick()                               // idle poll, button up
            s.time += 0.03
            s.changeCount += 1                     // the practice photo's drag began 20 ms after the press...
            s.press(); s.move(10)                  // ...before this first poll that sees the button down
            c.check("an own-window flick-drag with no press event is seen (up-poll count)", s.tap(.shift) == open(.convert),
                    "\(s.log)")
            var t = Script()
            t.tick()
            t.time += 1.0                          // the last up poll is a second old: don't trust it
            t.changeCount += 1
            t.press(); t.move(10)
            c.check("an old up poll is still a valid baseline (no drag can predate the press)", t.tap(.shift) == open(.convert))
            var u = Script()
            u.tick(); u.press(); u.move(10)        // a click-and-move with no drag: pasteboard unchanged
            c.check("no drag after an up poll still opens nothing", u.tap(.shift).isEmpty && !u.recognizer.isDragActive)
        }

        // Comma follows the keyboard layout (the key that types ",", not a fixed key code).
        for (id, expected, notExpected) in [("com.apple.keylayout.US", CGKeyCode(0x2B), CGKeyCode?.none),
                                            ("com.apple.keylayout.German", 0x2B, nil),
                                            ("com.apple.keylayout.French", 0x2E, 0x2B),
                                            ("com.apple.keylayout.Belgian", 0x2E, 0x2B),
                                            ("com.apple.keylayout.Dvorak", 0x0D, 0x2B)] {
            guard let keys = DragMonitor.commaKeys(forLayout: id) else { c.notes.append("\(id) isn’t installed; skipped"); continue }
            let name = id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
            c.check("\(name): comma is key \(String(format: "0x%02X", expected))",
                    keys.contains(expected) && !(notExpected.map(keys.contains) ?? false),
                    keys.map { String(format: "0x%02X", $0) }.joined(separator: " "))
        }
        let current = DragMonitor.currentCommaKeys()
        c.check("the current layout has a comma key", !current.isEmpty)
        c.notes.append("comma keys in the current layout: " + current.map { String(format: "0x%02X", $0) }.joined(separator: " "))

        c.check("InDesign prefix check handles nil", !DragGestureRecognizer.isIgnoredApp(nil))
        let live = DockGeometry.dockPreferences()
        c.notes.append("this Mac: Dock on the \(live.edge.rawValue), auto-hide \(live.autohide ? "on" : "off"), \(NSScreen.screens.count) screen(s)")
        c.notes.append("thresholds: \(Int(DragGestureRecognizer.movementThreshold)) pt movement, \(DragGestureRecognizer.minimumVisibleTime) s minimum wheel time, \(Int(DockGeometry.autoHiddenBand)) pt hidden-Dock band")
        return c.report("gesture")
    }

    // MARK: - Main thread

    /// `MainThread` and the petal dispatch: main-thread waits finish when they can and fail at once when they
    /// can't, instead of freezing the app until their timeout.
    static func mainThread() -> String {
        let c = Checker()
        func spin(until done: () -> Bool, seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while !done() && Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        /// Work that finishes through a main-queue callback, as WebKit's and printing's do.
        func queueWork(_ finish: @escaping (Result<Int, Error>) -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { finish(.success(42)) }
        }
        func timedWait() -> (value: Int?, error: String?, seconds: Double) {
            let start = Date()
            do {
                let v = try MainThread.wait(timeout: 30, queueWork)
                return (v, nil, Date().timeIntervalSince(start))
            } catch {
                return (nil, error.localizedDescription, Date().timeIntervalSince(start))
            }
        }

        let top = timedWait()
        c.check("command line (main thread, top level): wait finishes", top.value == 42 && top.seconds < 1, "\(top)")

        var fromRunLoop: (value: Int?, error: String?, seconds: Double)?
        MainThread.async { fromRunLoop = timedWait() }
        spin(until: { fromRunLoop != nil }, seconds: 10)
        c.check("inside MainThread.async (how petals run now): wait finishes fast",
                fromRunLoop?.value == 42 && (fromRunLoop?.seconds ?? 99) < 1, "\(String(describing: fromRunLoop))")

        var fromQueue: (value: Int?, error: String?, seconds: Double)?
        DispatchQueue.main.async { fromQueue = timedWait() }
        spin(until: { fromQueue != nil }, seconds: 40)
        c.check("inside a main-queue block: wait fails within about a second, not at its 30 s timeout",
                fromQueue?.value == nil && (fromQueue?.seconds ?? 99) < MainThread.blockedQueueGrace + 1
                && fromQueue?.error == MainThread.blockedQueueMessage, "\(String(describing: fromQueue))")

        // A job thread waiting on the main thread while a modal prompt (started the way petals start now) runs.
        var background: (value: Int?, error: String?, seconds: Double)?
        var modalEnded = false
        MainThread.async {
            let end = Date().addingTimeInterval(8)
            while background == nil && Date() < end { RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.02)) }
            modalEnded = true
        }
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.1)
            let r = timedWait()
            DispatchQueue.main.async { background = r }
        }
        spin(until: { background != nil && modalEnded }, seconds: 20)
        c.check("a job waiting on the main thread during a modal prompt finishes", background?.value == 42
                && (background?.seconds ?? 99) < 2, "\(String(describing: background))")

        var synced = 0
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { synced = MainThread.sync { Thread.isMainThread ? 1 : -1 }; group.leave() }
        spin(until: { group.wait(timeout: .now()) == .success }, seconds: 5)
        c.check("MainThread.sync from a job thread runs on the main thread", synced == 1)
        c.check("MainThread.sync on the main thread runs inline", MainThread.sync { Thread.isMainThread })

        // A drop on a petal runs its handler from the run loop, where it can wait on main-queue callbacks.
        let wheel = WheelView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        wheel.playsFeedback = false
        var handled: (urls: [URL], wait: (value: Int?, error: String?, seconds: Double))?
        wheel.items = [WheelItem(title: "Wait", symbol: nil) { urls in handled = (urls, timedWait()) }]
        wheel.setHighlight(0)
        let file = URL(fileURLWithPath: "/tmp/YummyOrange selftest/photo.png")
        let accepted = wheel.performDragOperation(ShelfMockDrag([file], source: nil))
        c.check("the drop is accepted and the handler waits for the next turn", accepted && handled == nil)
        spin(until: { handled != nil }, seconds: 10)
        c.check("a petal handler can wait on main-thread work (no 60 s freeze)", handled?.urls == [file]
                && handled?.wait.value == 42 && (handled?.wait.seconds ?? 99) < 1, "\(String(describing: handled))")

        // The real case: an SVG that needs WebKit, drawn from a petal handler (Adjust…/Annotate… on an SVG).
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="30"><text x="2" y="20">a<tspan dy="2">b</tspan></text></svg>"#.utf8)
        c.check("the sample SVG needs WebKit", SVGRenderer.needsWebKit(svg))
        var drawn: (ok: Bool, seconds: Double, detail: String)?
        let svgWheel = WheelView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        svgWheel.playsFeedback = false
        svgWheel.items = [WheelItem(title: "SVG", symbol: nil) { _ in
            let start = Date()
            do {
                let image = try WebSVG.snapshot(svg, pixelWidth: 40, pixelHeight: 30, name: "sample.svg")
                drawn = (image.width == 40 && image.height == 30, Date().timeIntervalSince(start), "\(image.width)×\(image.height)")
            } catch { drawn = (false, Date().timeIntervalSince(start), error.localizedDescription) }
        }]
        svgWheel.setHighlight(0)
        _ = svgWheel.performDragOperation(ShelfMockDrag([file], source: nil))
        spin(until: { drawn != nil }, seconds: 90)
        c.check("a petal handler draws a WebKit SVG in seconds, not after a 60 s timeout", drawn?.ok == true && (drawn?.seconds ?? 99) < 10,
                "\(String(describing: drawn))")
        if let drawn { c.notes.append(String(format: "WebKit SVG from a petal handler: %.2f s", drawn.seconds)) }
        return c.report("mainthread")
    }

    // MARK: - Wheel

    static func wheel() -> String {
        let c = Checker()

        // Layout and hit-testing: every point inside a drawn petal must hit that petal.
        var summary: [String] = []
        for count in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 20, 24] {
            for side in [WheelLayout.diameter(for: count), 232] {
                let bounds = CGRect(x: 0, y: 0, width: side, height: side)
                let layout = WheelLayout(count: count, bounds: bounds)
                let paths = (0..<count).map(layout.path)
                c.check("\(count) petals: rings hold every petal", layout.rings.reduce(0) { $0 + $1.count } == count)
                var drawn = 0, mismatched = 0, overlaps = 0, extra = 0
                var hitPerPetal = [Int](repeating: 0, count: count)
                let step: CGFloat = side > 300 ? 1.5 : 1
                var y: CGFloat = 0.25
                while y < side {
                    var x: CGFloat = 0.25
                    while x < side {
                        let p = CGPoint(x: x, y: y)
                        let inside = paths.indices.filter { paths[$0].contains(p) }
                        let hit = layout.index(at: p)
                        if inside.count > 1 { overlaps += 1 }
                        if let d = inside.first {
                            drawn += 1
                            if hit != d { mismatched += 1 }
                        } else if hit != nil { extra += 1 }
                        if let hit { hitPerPetal[hit] += 1 }
                        x += step
                    }
                    y += step
                }
                let label = "\(count) petals at \(Int(side)) pt"
                c.check("\(label): drawn points hit their own petal", mismatched == 0, "\(mismatched) of \(drawn) points mismatched")
                c.check("\(label): petals never overlap", overlaps == 0, "\(overlaps) points in two petals")
                c.check("\(label): every petal can be hit", hitPerPetal.allSatisfy { $0 > 0 })
                c.check("\(label): the centre is never a petal", layout.index(at: layout.center) == nil
                        && layout.index(at: CGPoint(x: layout.center.x + layout.centerRadius - 1, y: layout.center.y)) == nil)
                c.check("\(label): far outside is never a petal",
                        layout.index(at: CGPoint(x: layout.center.x, y: layout.center.y + layout.outerRadius + layout.outerSlack + 1)) == nil)
                for i in 0..<count {
                    for anchor in layout.labelAnchors(i) where layout.index(at: anchor) != i {
                        c.check("\(label): label anchor of petal \(i) is in petal \(i)", false)
                    }
                }
                if side == WheelLayout.diameter(for: count), count > 0 {
                    let rings = layout.rings.map { "\($0.count)" }.joined(separator: "+")
                    let forgiving = drawn > 0 ? Double(extra) / Double(drawn + extra) * 100 : 0
                    summary.append("\(count):\(rings)\(String(format: "(%.0f%%)", forgiving))")
                }
            }
        }
        c.notes.append("rings per count (share of hit area that is gap or edge slack): " + summary.joined(separator: " "))

        // Labels: realistic petal sets must fit without being cut, at the sizes the wheel shows them.
        for mode in WheelMode.allCases {
            let samples = AppShell.sampleItems(mode)
            for count in [4, 8, 12, 16] {
                let items = Array(samples.prefix(count))
                let d = WheelLayout.diameter(for: count)
                let layout = WheelLayout(count: count, bounds: CGRect(x: 0, y: 0, width: d, height: d))
                let labels = items.indices.map { PetalLabel.fit(items[$0], petal: $0, in: layout) }
                let cut = labels.indices.filter { labels[$0].truncated }.map { items[$0].title }
                c.check("\(mode.rawValue) × \(count): no label is cut short", cut.isEmpty, cut.joined(separator: ", "))
                let symbolsKept = items.indices.allSatisfy { (items[$0].symbol == nil) == (labels[$0].symbol == nil) }
                c.check("\(mode.rawValue) × \(count): symbols kept", symbolsKept)
                for (i, l) in labels.enumerated() where !l.truncated {
                    let size = CGSize(width: l.width, height: l.height)
                    c.check("\(mode.rawValue) × \(count): label \(i) lies inside its petal",
                            layout.fits(size, at: l.anchor, in: i, padding: 4 * layout.scale - 0.01))
                }
                let sizes = labels.map { $0.font.pointSize }
                let twoLine = labels.indices.filter { labels[$0].lines.count == 2 }.map { items[$0].title }
                c.check("\(mode.rawValue) × \(count): fonts at least 9 pt", (sizes.min() ?? 9) >= 9)
                c.notes.append("\(mode.rawValue) × \(count): font \(fmt(sizes.min() ?? 0))–\(fmt(sizes.max() ?? 0)) pt"
                               + (twoLine.isEmpty ? "" : ", two lines: \(twoLine.joined(separator: ", "))"))
            }
        }
        let long = WheelItem(title: "Supercalifragilisticexpialidocious Conversion", symbol: "star", handler: { _ in })
        let crowded = WheelLayout(count: 16, bounds: CGRect(x: 0, y: 0, width: 460, height: 460))
        let fitted = PetalLabel.fit(long, petal: 3, in: crowded)
        c.check("an impossible title is cut, not overflowing", fitted.truncated && fitted.font.pointSize >= 9)
        c.check("two-line splits are balanced", PetalLabel.twoLineSplits("Read QR Code").first == ["Read", "QR Code"]
                && PetalLabel.twoLineSplits("Strip Metadata").first == ["Strip", "Metadata"]
                && PetalLabel.twoLineSplits("Markdown").isEmpty)
        let started = ProcessInfo.processInfo.systemUptime
        let timed = WheelView(frame: CGRect(x: 0, y: 0, width: 460, height: 460))
        timed.items = AppShell.sampleItems(.tools)
        _ = timed.labels
        let layoutMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
        c.check("laying out 16 petals takes under 50 ms", layoutMs < 50, fmt(layoutMs))
        c.notes.append("layout of 16 petals with label fitting: \(fmt(layoutMs)) ms (debug build)")

        // Built-in Convert petals: the formats valid for every file, whatever order the files came in.
        do {
            let dir = URL(fileURLWithPath: "/tmp/YummyOrange selftest", isDirectory: true)
            let png = dir.appendingPathComponent("photo.png"), dng = dir.appendingPathComponent("camera.dng")
            let jpg = dir.appendingPathComponent("b.jpeg"), png2 = dir.appendingPathComponent("other.png")
            let mp4 = dir.appendingPathComponent("clip.mp4"), mkv = dir.appendingPathComponent("odd.mkv")
            let names: ([URL]) -> [String] = { OutputFormat.targets(forAll: $0).map(\.rawValue) }
            let builtIn: ([URL]) -> [String] = { files in
                AppDelegate.items(for: .convert, files: files).filter { $0.symbol == nil }.map(\.title)
            }
            c.check("one file: same petals as before", names([png]) == OutputFormat.targets(for: .image, source: "png").map(\.rawValue)
                    && names([dng]) == OutputFormat.targets(for: .image, source: "dng").map(\.rawValue))
            c.check("[PNG, DNG] and [DNG, PNG] offer the same formats", names([png, dng]) == names([dng, png]),
                    "\(names([png, dng])) vs \(names([dng, png]))")
            c.check("[PNG, DNG] offers no PNG (the PNG already is one) but JPG", !names([dng, png]).contains("png")
                    && names([png, dng]).contains("jpg"))
            c.check("the wheel itself agrees in both orders", builtIn([png, dng]) == builtIn([dng, png])
                    && !builtIn([dng, png]).contains("PNG"), "\(builtIn([png, dng])) vs \(builtIn([dng, png]))")
            c.check("[PNG, JPEG, PNG] offers neither PNG nor JPG", !names([png, jpg, png2]).contains("png")
                    && !names([png, jpg, png2]).contains("jpg") && names([png, jpg, png2]) == names([jpg, png2, png]))
            c.check("[MP4, MKV] and [MKV, MP4] offer the same formats, neither MP4 nor MKV",
                    names([mp4, mkv]) == names([mkv, mp4]) && !names([mp4, mkv]).contains("mp4") && !names([mkv, mp4]).contains("mkv"),
                    "\(names([mp4, mkv])) vs \(names([mkv, mp4]))")
            c.check("mixed kinds offer no built-in format", names([png, mp4]).isEmpty)
            // Spreadsheet petals for every workbook the Spreadsheets module reads.
            for ext in ["xlsm", "xltx", "xltm", "fods"] {
                let ids = Registry.commands(for: .convert, files: [dir.appendingPathComponent("book.\(ext)")]).map(\.id)
                c.check(".\(ext) gets spreadsheet petals", ids.contains("xlsx") && ids.contains("csv") && ids.contains("pdf"),
                        ids.joined(separator: " "))
            }
        }

        // View API
        let view = WheelView(frame: CGRect(x: 0, y: 0, width: 360, height: 360))
        view.playsFeedback = false
        view.items = Array(AppShell.sampleItems(.tools).prefix(6))
        view.setHighlight(9)
        c.check("out-of-range highlight is ignored", view.highlighted == nil)
        view.setHighlight(2)
        c.check("setHighlight", view.highlighted == 2)
        view.items = Array(view.items.prefix(5))
        c.check("new items clear the highlight", view.highlighted == nil)
        c.check("preferred sizes", WheelView.preferredDiameter(for: 8) == 372 && WheelView.preferredDiameter(for: 9) == 460
                && WheelView.preferredDiameter(for: 0) == 182)
        // Five petals of 72°: petal 1 is centred at 72° clockwise from 12 o’clock, petal 4 at 288°.
        let at: (CGFloat) -> CGPoint = { deg in
            let a = deg * .pi / 180
            return CGPoint(x: 180 + 110 * sin(a), y: 180 + 110 * cos(a))
        }
        c.check("petal 0 is centred at 12 o’clock", view.index(at: at(0)) == 0 && view.index(at: at(-30)) == 0
                && view.index(at: at(30)) == 0)
        c.check("petals run clockwise", view.index(at: at(72)) == 1 && view.index(at: at(144)) == 2
                && view.index(at: at(288)) == 4)
        c.check("hit-testing follows a resized view", {
            view.setFrameSize(CGSize(width: 200, height: 200))
            defer { view.setFrameSize(CGSize(width: 360, height: 360)) }
            return view.index(at: CGPoint(x: 100, y: 100 + 60)) == 0 && view.index(at: CGPoint(x: 100, y: 100)) == nil
        }())

        // Rendered pixels: accent on the highlighted petal, legible labels, both styles, light and dark,
        // with the system accent and with each standard accent color.
        let accents: [(String, NSColor?)] = [("system", nil),
            ("blue", NSColor(hex: "#0A84FF")), ("purple", NSColor(hex: "#A550A7")), ("pink", NSColor(hex: "#F74F9E")),
            ("red", NSColor(hex: "#FF5257")), ("orange", NSColor(hex: "#F7821B")), ("yellow", NSColor(hex: "#FFC600")),
            ("green", NSColor(hex: "#62BA46")), ("graphite", NSColor(hex: "#8C8C8C"))]
        var worst: (Double, String) = (99, "")
        for style in WheelStyle.allCases {
            for dark in [false, true] {
                for (accentName, accentColor) in accents {
                    let name = "\(style.title) \(dark ? "dark" : "light") \(accentName)"
                    guard let r = renderWheel(style: style, dark: dark, count: 8, highlight: 0, accent: accentColor) else {
                        c.check("\(name): renders", false); continue
                    }
                    let side = WheelLayout.diameter(for: 8)
                    let layout = WheelLayout(count: 8, bounds: CGRect(x: 0, y: 0, width: side, height: side))
                    let ring = layout.rings[0]
                    let painter = WheelPainter(style: style, appearance: NSAppearance(named: dark ? .darkAqua : .aqua)!,
                                               layout: layout, accent: accentColor)
                    let text = painter.labelColor(highlighted: true)
                    // Sample the highlighted petal away from its label, near both ends of its radius.
                    var hiContrast = 99.0
                    for radius in [ring.inner + 8, ring.outer - 8] {
                        for da in [-0.18, 0.0, 0.18] {
                            let p = layout.point(radius: radius, clockAngle: CGFloat(da))
                            hiContrast = min(hiContrast, contrast(text, r.color(at: p)))
                        }
                    }
                    let hi = r.color(at: layout.point(radius: ring.outer - 9, clockAngle: 0))
                    let accent = painter.accent
                    if accent.saturationComponent > 0.25 {
                        let dh = abs(hi.hueComponent - accent.hueComponent)
                        c.check("\(name): highlighted petal is the accent color", min(dh, 1 - dh) < 0.06 && hi.saturationComponent > 0.25,
                                "hue \(fmt(hi.hueComponent)) vs \(fmt(accent.hueComponent))")
                    }
                    c.check("\(name): label contrast on the highlighted petal ≥ 4.5", hiContrast >= 4.5, fmt(hiContrast))
                    let lightAccent = ["yellow", "orange", "green"].contains(accentName)
                    c.check("\(name): label is \(lightAccent ? "dark" : "white") on the accent",
                            (text.usingColorSpace(.sRGB)!.redComponent > 0.5) != lightAccent)
                    if hiContrast < worst.0 { worst = (hiContrast, name) }
                    guard accentName == "system" else { continue }
                    // Plain petals: sample several, including the ones the metal's reflections brighten.
                    var plainContrast = 99.0
                    for i in 1..<8 {
                        for radius in [ring.inner + 8, ring.outer - 8] {
                            let p = layout.point(radius: radius, clockAngle: layout.midAngle(i))
                            plainContrast = min(plainContrast, contrast(painter.labelColor(highlighted: false), r.color(at: p)))
                        }
                    }
                    c.check("\(name): label contrast on plain petals ≥ 4.5", plainContrast >= 4.5, fmt(plainContrast))
                    c.notes.append("\(name): plain-petal label contrast at least \(fmt(plainContrast)):1, highlighted \(fmt(hiContrast)):1")
                }
            }
        }
        c.notes.append("lowest highlighted-label contrast over 9 accents × 2 styles × 2 appearances: \(fmt(worst.0)):1 (\(worst.1))")

        // Panel placement near screen edges
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let mid = OverlayController.panelFrame(anchor: CGPoint(x: 700, y: 400), diameter: 372, visibleFrame: screen)
        c.check("panel is centred on the cursor", mid.midX == 700 && mid.midY == 400 && mid.width == 372)
        let corner = OverlayController.panelFrame(anchor: CGPoint(x: 10, y: 870), diameter: 460, visibleFrame: screen)
        c.check("panel stays on screen in a corner", corner.minX == 0 && corner.maxY == 875)
        let right = OverlayController.panelFrame(anchor: CGPoint(x: 1439, y: 5), diameter: 372, visibleFrame: screen)
        c.check("panel stays on screen at the bottom right", right.maxX == 1440 && right.minY == 0)
        let tiny = OverlayController.panelFrame(anchor: CGPoint(x: 50, y: 50), diameter: 460,
                                                visibleFrame: CGRect(x: 0, y: 0, width: 300, height: 300))
        c.check("a screen smaller than the wheel pins it to the corner", tiny.origin == .zero)
        let second = OverlayController.panelFrame(anchor: CGPoint(x: 1500, y: -300), diameter: 372,
                                                  visibleFrame: CGRect(x: 1440, y: -1080, width: 1920, height: 1055))
        c.check("works on a screen with negative coordinates", second.minX == 1440 && second.midY == -300)

        // The petal sounds are checked in the wheel self-test (WheelSelfTest.sound).

        return c.report("wheel")
    }

    /// A rendered wheel and a way to read its pixels in view coordinates.
    struct Rendered {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let scale: CGFloat

        /// The sRGB color at a point (origin bottom-left, in points).
        func color(at p: CGPoint) -> NSColor {
            let x = min(max(Int(p.x * scale), 0), width - 1)
            let row = min(max(height - 1 - Int(p.y * scale), 0), height - 1)
            let o = (row * width + x) * 4
            let a = CGFloat(pixels[o + 3]) / 255
            guard a > 0 else { return .clear }
            return NSColor(srgbRed: CGFloat(pixels[o]) / 255 / a, green: CGFloat(pixels[o + 1]) / 255 / a,
                           blue: CGFloat(pixels[o + 2]) / 255 / a, alpha: a)
        }
    }

    /// Renders the wheel the way `--snapshot wheel` does (over the desktop gradient, glass backdrop drawn)
    /// into an sRGB bitmap at 2×, so sampled colors compare directly with the painter's sRGB colors.
    static func renderWheel(style: WheelStyle, dark: Bool, count: Int, highlight: Int?, accent: NSColor? = nil) -> Rendered? {
        let size = WheelLayout.diameter(for: count)
        let container = AppShellSnapshotBackground(color: nil)
        container.frame = CGRect(x: 0, y: 0, width: size, height: size)
        let wheel = WheelView(frame: container.bounds)
        wheel.style = style
        wheel.playsFeedback = false
        wheel.modeTitle = "Tools"
        wheel.items = Array(AppShell.sampleItems(.tools).prefix(count))
        wheel.accentOverride = accent
        wheel.setHighlight(highlight)
        container.addSubview(wheel)
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = container
        container.layoutSubtreeIfNeeded()

        let w = Int(size * 2), h = Int(size * 2)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: 2, y: 2)
        container.displayIgnoringOpacity(container.bounds, in: NSGraphicsContext(cgContext: ctx, flipped: false))
        guard let data = ctx.data else { return nil }
        let pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
        return Rendered(pixels: pixels, width: w, height: h, scale: 2)
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> Double { WheelPainter.contrast(a, b) }

    static func fmt(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
    static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    // MARK: - Settings

    static func settings() -> String {
        let c = Checker()

        // Key map rules
        let d = WheelKeyMap.defaults
        c.check("defaults are ⇧ ⌘ ⌃", d.key(for: .convert) == .shift && d.key(for: .tools) == .command && d.key(for: .actions) == .control)
        c.check("default hint", d.hint == "⇧ Convert · ⌘ Tools · ⌃ Actions", d.hint)
        var m = d
        m.assign(.command, to: .convert)
        c.check("taking another wheel’s key swaps", m.key(for: .convert) == .command && m.key(for: .tools) == .shift
                && m.key(for: .actions) == .control)
        m.assign(.off, to: .tools)
        c.check("Off frees a wheel", m.key(for: .tools) == .off && m.hint == "⌘ Convert · ⌃ Actions", m.hint)
        m.assign(.off, to: .actions)
        c.check("several wheels can be Off", m.key(for: .tools) == .off && m.key(for: .actions) == .off)
        m.assign(.command, to: .tools)
        c.check("taking a key from a wheel gives it the Off you had", m.key(for: .tools) == .command && m.key(for: .convert) == .off)
        m.assign(.off, to: .tools)
        c.check("all off", m.allOff && m.hint.isEmpty)
        c.check("duplicates read from preferences are repaired",
                WheelKeyMap(convert: .shift, tools: .shift, actions: .control) == WheelKeyMap(convert: .shift, tools: .off, actions: .control))

        // Exhaustive: from every valid map, every assignment keeps keys unique and sets what was asked.
        var cases = 0, broken = 0
        for a in WheelKey.allCases { for b in WheelKey.allCases { for e in WheelKey.allCases {
            let start = WheelKeyMap(convert: a, tools: b, actions: e)
            for mode in WheelMode.allCases { for key in WheelKey.allCases {
                var map = start
                map.assign(key, to: mode)
                cases += 1
                let used = WheelMode.allCases.map { map.key(for: $0) }.filter { $0 != .off }
                let othersKept = WheelMode.allCases.filter { $0 != mode }.allSatisfy { other in
                    map.key(for: other) == start.key(for: other) || start.key(for: other) == key
                }
                if Set(used).count != used.count || map.key(for: mode) != key || !othersKept { broken += 1 }
            } }
        } } }
        c.check("\(cases) assignments keep every key on one wheel", broken == 0, "\(broken) broken")
        c.check("mode(newlyPressed:) follows the map",
                d.mode(newlyPressed: .control) == .actions && d.mode(newlyPressed: .option) == .actions
                && d.mode(newlyPressed: [.control, .shift]) == .convert)

        // Persistence, in memory only.
        let saved = Settings.defaults
        let suite = SettingsMemoryStore()
        Settings.defaults = suite
        defer { Settings.defaults = saved }
        c.check("fresh defaults", Settings.resultsDestination == .shelf && Settings.showProgressHUD && Settings.petalSounds && Settings.haptics
                && Settings.wheelStyle == .glass && Settings.wheelKeys == .defaults && Settings.petalSoundStyle == .dial)
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: nil) { _ in posted += 1 }
        Settings.wheelStyle = .metallic
        Settings.wheelStyle = .metallic
        c.check("style saves and posts once", Settings.wheelStyle == .metallic && suite.string(forKey: "wheelStyle") == "metallic"
                && posted == 1, "posted \(posted)")
        Settings.showProgressHUD = false
        Settings.petalSounds = false
        Settings.haptics = false
        c.check("toggles save", !Settings.showProgressHUD && !Settings.petalSounds && !Settings.haptics
                && suite.object(forKey: "petalSounds") as? Bool == false)
        resultsSettings(c, suite: suite, posted: { posted }, resetPosted: { posted = 0 })
        posted = 0
        Settings.setKey(.option, for: .tools)
        c.check("a key saves (one notification)", Settings.wheelKeys.key(for: .tools) == .option
                && suite.string(forKey: "wheelKey.tools") == "option" && posted == 1, "posted \(posted)")
        Settings.setKey(.option, for: .convert)
        c.check("swaps persist", Settings.wheelKeys == WheelKeyMap(convert: .option, tools: .shift, actions: .control))
        c.check("keySymbol follows Settings", AppShell.keySymbol(for: .convert) == "⌥" && AppShell.keySymbol(for: .tools) == "⇧")
        c.check("WheelMode.from follows Settings", WheelMode.from(newlyPressed: .option) == .convert
                && WheelMode.from(newlyPressed: .command) == nil)
        Settings.setKey(.off, for: .actions)
        c.check("an Off wheel has no symbol", AppShell.keySymbol(for: .actions) == "")
        c.check("menu hint follows Settings", AppDelegate.menuHint() == "Drag files, then tap ⌥ Convert · ⇧ Tools", AppDelegate.menuHint())
        Settings.setKey(.off, for: .convert); Settings.setKey(.off, for: .tools)
        c.check("menu hint when every wheel is off", AppDelegate.menuHint() == "All wheels are off. Turn one on in Settings.")
        posted = 0
        Settings.resetWheelKeys()
        c.check("Restore Defaults", Settings.wheelKeys == .defaults && posted == 1)
        posted = 0
        Settings.petalSoundStyle = .wood
        c.check("the petal sound saves (one notification)", Settings.petalSoundStyle == .wood
                && suite.string(forKey: "petalSound") == "wood" && posted == 1, "posted \(posted)")
        suite.set("kazoo", forKey: "petalSound")
        c.check("an unknown petal sound falls back to Dial", Settings.petalSoundStyle == .dial)
        suite.set("banana", forKey: "wheelStyle")
        suite.set("hyper", forKey: "wheelKey.convert")
        suite.set("command", forKey: "wheelKey.actions")
        c.check("unknown values fall back, and a repeated key is turned off",
                Settings.wheelStyle == .glass && Settings.wheelKeys == WheelKeyMap(convert: .shift, tools: .command, actions: .off))
        NotificationCenter.default.removeObserver(token)

        // Settings window bindings
        Settings.resetWheelKeys()
        let model = SettingsModel()
        model.key(.actions).wrappedValue = .shift
        c.check("the window’s key picker swaps too", Settings.wheelKeys == WheelKeyMap(convert: .control, tools: .command, actions: .shift))
        model.style.wrappedValue = .glass
        model.results.wrappedValue = .finder
        c.check("the window’s controls write Settings", Settings.wheelStyle == .glass && Settings.resultsDestination == .finder
                && suite.string(forKey: "resultsDestination") == "finder")
        resultsPopUp(c)
        resultsMenu(c)
        resultsOptions(c)
        Settings.defaults = suite
        for section in SettingsSection.allCases {
            let host = NSHostingView(rootView: SettingsSectionView(section: section, snapshot: true))
            let size = host.fittingSize
            c.check("\(section.title) tab has a sensible size", size.width >= 400 && size.height >= 120 && size.height < 900,
                    "\(Int(size.width))×\(Int(size.height))")
            c.notes.append("\(section.title) tab: \(Int(size.width))×\(Int(size.height)) pt")
        }

        let tabs = SettingsTabViewController()
        c.check("Settings has four toolbar tabs", tabs.tabViewItems.map(\.label) == ["General", "Wheels", "Look", "About"]
                && tabs.tabViewItems.allSatisfy { $0.image != nil } && tabs.tabStyle == .toolbar)

        // About
        let gpl = "configuration: --prefix=/x --enable-gpl --enable-version3 --enable-libx264"
        c.check("license: GPL 3", AboutInfo.ffmpegLicense(configuration: gpl) == "GPL 3 build")
        c.check("license: GPL 2+", AboutInfo.ffmpegLicense(configuration: "configuration: --enable-gpl") == "GPL 2+ build")
        c.check("license: LGPL", AboutInfo.ffmpegLicense(configuration: "configuration: --disable-programs") == "LGPL 2.1+ build")
        c.check("license: non-free", AboutInfo.ffmpegLicense(configuration: "configuration: --enable-gpl --enable-nonfree") == "non-free build")
        c.check("license: unknown output", AboutInfo.ffmpegLicense(configuration: "garbage") == nil)
        c.notes.append("ffmpeg: \(AboutInfo.ffmpeg.path ?? "not found") \(AboutInfo.ffmpeg.version ?? "") \(AboutInfo.ffmpeg.license ?? "")")
        c.notes.append("cwebp: \(AboutInfo.cwebp.path ?? "not found") \(AboutInfo.cwebp.version ?? "")")
        return c.report("settings")
    }
}
#endif
