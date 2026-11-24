import AppKit
import Carbon
import CoreGraphics
import os

/// Which wheel a modifier key opens.
enum WheelMode: String, CaseIterable {
    case convert = "Convert"
    case tools = "Tools"
    case actions = "Actions"

    /// The wheel opened by a newly pressed modifier, using the keys chosen in Settings.
    static func from(newlyPressed flags: NSEvent.ModifierFlags) -> WheelMode? {
        Settings.wheelKeys.mode(newlyPressed: flags)
    }
}

/// Notices a file drag anywhere on screen and a modifier tap during it, without an event tap or
/// Accessibility permission. It polls global state that any app may read:
///   - the left mouse button (NSEvent.pressedMouseButtons)
///   - the modifier keys (NSEvent.modifierFlags + CGEventSource flags)
///   - Escape and comma (CGEventSource.keyState; comma is whichever key types "," in the current layout)
///   - the system drag pasteboard, whose change count bumps when a new drag starts
/// Mouse-down monitors (mouse events need no permission) record the exact press point and the pasteboard
/// count at that moment: a global one for other apps, a local one for YummyOrange's own windows (the welcome
/// tour's practice photo, shelves), which global monitors never see. The decisions themselves are made by
/// `DragGestureRecognizer`.
final class DragMonitor {
    var onOpen: ((WheelMode, [URL]) -> Void)?
    var onCancel: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var recognizer = DragGestureRecognizer()
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var mouseDownMonitor: Any?
    private var localMouseDownMonitor: Any?
    private var pendingPress: DragPressEvent?
    private var settingsObserver: NSObjectProtocol?
    /// The keys that type "," in the current keyboard layout (0x2B on US and German, 0x2E on French AZERTY),
    /// looked up again at each press so a layout switch takes effect on the next drag.
    private var commaKeys: [CGKeyCode] = [DragMonitor.defaultCommaKey]
    private var commaLayoutID: String?
    private var mouseWasDown = false
    private var loggedFlags: NSEvent.ModifierFlags = []
    /// Read with: log stream --predicate 'subsystem == "com.yummyorange.app"'
    static let log = Logger(subsystem: "com.yummyorange.app", category: "gesture")

    private static func describe(_ f: NSEvent.ModifierFlags) -> String {
        let parts = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { f.contains($0.0) }.map(\.1)
        return parts.isEmpty ? "none" : parts.joined()
    }

    private static let idleInterval: TimeInterval = 1.0 / 20
    private static let activeInterval: TimeInterval = 1.0 / 60
    private static let relevantFlags: NSEvent.ModifierFlags = [.shift, .command, .control, .option]
    private static let escapeKey: CGKeyCode = 0x35
    /// kVK_ANSI_Comma: the comma key on ANSI and ISO keyboards with a US-like layout.
    static let defaultCommaKey: CGKeyCode = 0x2B

    init() {
        recognizer.keys = Settings.wheelKeys
        recognizer.isInDock = { DockGeometry.current().contains($0) }
        recognizer.readFiles = { [dragPasteboard] in
            dragPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }
        recognizer.frontmostBundleID = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    }

    func start() {
        settingsObserver = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil,
                                                                  queue: .main) { [weak self] _ in
            self?.recognizer.keys = Settings.wheelKeys
            HoldKeyTap.shared.update()
        }
        HoldKeyTap.shared.update()
        refreshCommaKeys()
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.recordPress(event)
        }
        // Presses in YummyOrange's own windows: without this, a drag that starts there (the practice photo, a shelf)
        // has no press event, and one that writes the drag pasteboard before the next poll is never seen.
        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.recordPress(event)
            return event
        }
        schedule(Self.idleInterval)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        mouseDownMonitor = nil
        if let localMouseDownMonitor { NSEvent.removeMonitor(localMouseDownMonitor) }
        localMouseDownMonitor = nil
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
    }

    /// A mouse-down from either monitor: where it happened, and the drag pasteboard's count before any drag began.
    private func recordPress(_ event: NSEvent) {
        let location = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        pendingPress = DragPressEvent(location: location, time: ProcessInfo.processInfo.systemUptime,
                                      changeCount: dragPasteboard.changeCount)
        tick()
    }

    private func schedule(_ newInterval: TimeInterval) {
        guard newInterval != interval || timer == nil else { return }
        interval = newInterval
        timer?.invalidate()
        let t = Timer(timeInterval: newInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // keep firing while menus or drags run the loop in other modes
        timer = t
    }

    private func currentFlags() -> NSEvent.ModifierFlags {
        let cg = NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
        return NSEvent.modifierFlags.union(cg).intersection(Self.relevantFlags)
    }

    private func tick() {
        let mouseDown = NSEvent.pressedMouseButtons & 1 != 0
            || CGEventSource.buttonState(.combinedSessionState, button: .left)
        if mouseDown && !mouseWasDown { refreshCommaKeys() }
        mouseWasDown = mouseDown
        // Escape and comma only matter during a press; skip the key reads while idle.
        let input = DragGestureInput(
            time: ProcessInfo.processInfo.systemUptime,
            mouseDown: mouseDown,
            location: NSEvent.mouseLocation,
            flags: currentFlags(),
            escapeDown: mouseDown && CGEventSource.keyState(.combinedSessionState, key: Self.escapeKey),
            commaDown: mouseDown && commaKeys.contains { CGEventSource.keyState(.combinedSessionState, key: $0) },
            changeCount: dragPasteboard.changeCount,
            press: pendingPress)
        pendingPress = nil

        let wasActive = recognizer.isDragActive, wasIgnored = recognizer.ignoreReason, wasArmed = recognizer.armedMode
        let stalled = recognizer.heldKeyPressStalled
        let events = recognizer.step(input)
        // One line per change, readable with: log stream --predicate 'process == "YummyOrange"'
        if input.flags != loggedFlags {
            loggedFlags = input.flags
            Self.log.notice("modifiers: \(Self.describe(input.flags), privacy: .public)")
        }
        if recognizer.isDragActive != wasActive || recognizer.ignoreReason != wasIgnored || recognizer.armedMode != wasArmed {
            let counted = recognizer.isDragActive ? "yes" : "no", ignored = recognizer.ignoreReason?.rawValue ?? "-"
            let armed = recognizer.armedMode?.rawValue ?? "-"
            Self.log.notice("drag: counted=\(counted, privacy: .public) ignored=\(ignored, privacy: .public) armed=\(armed, privacy: .public)")
        }
        for event in events {
            let text = String(String(describing: event).prefix(160))
            Self.log.notice("event: \(text, privacy: .public)")
            switch event {
            case .open(let mode, let files): onOpen?(mode, files)
            case .cancel: onCancel?()
            case .openSettings: onOpenSettings?()
            case .dragEnded:
                onDragEnded?()
                if stalled { Self.hintHoldKeyFirst() }
            }
        }
        schedule(mouseDown ? Self.activeInterval : Self.idleInterval)
    }

    private static var hinted = false

    /// Once per launch, when a held key met Finder's deselect-on-press, point at the setting that fixes it.
    private static func hintHoldKeyFirst() {
        guard !Settings.holdKeyFirst || !HoldKeyTap.isTrusted, !hinted,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
        hinted = true
        log.notice("hint: held key met Finder's selection click")
        if Settings.holdKeyFirst { HoldKeyTap.shared.update(prompt: true) }   // the system's Accessibility request
        HUD.shared.flash(Settings.holdKeyFirst
            ? "Allow YummyOrange under Privacy & Security › Accessibility to drag selected files with a key held."
            : "To drag a selected file with the key held first, turn on “Hold the key first” in Settings › Wheels.",
            seconds: 5)
    }

    // MARK: Keyboard layout

    /// Looks up the comma keys again when the keyboard layout changed since the last press (main thread).
    private func refreshCommaKeys() {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return }
        let id = Self.inputSourceID(source)
        guard id == nil || id != commaLayoutID else { return }
        commaLayoutID = id
        commaKeys = Self.commaKeys(in: source)
    }

    private static func inputSourceID(_ source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// The keys that type "," with no modifiers in a layout, or the US comma key when none does (or the layout
    /// can't be read).
    static func commaKeys(in source: TISInputSource) -> [CGKeyCode] {
        let keys = keyCodes(typing: ",", in: source)
        return keys.isEmpty ? [defaultCommaKey] : keys
    }

    /// The comma keys of the keyboard layout now in use (main thread).
    static func currentCommaKeys() -> [CGKeyCode] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return [defaultCommaKey] }
        return commaKeys(in: source)
    }

    /// The comma keys of an installed layout such as "com.apple.keylayout.French" (for the self-test); nil when
    /// that layout isn't on this Mac.
    static func commaKeys(forLayout id: String) -> [CGKeyCode]? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return nil }
        return commaKeys(in: source)
    }

    /// The key codes that type `character` with no modifiers in a keyboard layout, found with UCKeyTranslate.
    static func keyCodes(typing character: String, in source: TISInputSource) -> [CGKeyCode] {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [] }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        return data.withUnsafeBytes { bytes -> [CGKeyCode] in
            guard let base = bytes.baseAddress else { return [] }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var found: [CGKeyCode] = []
            for code in 0..<CGKeyCode(128) {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, keyboardType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length) == character { found.append(code) }
            }
            return found
        }
    }
}
