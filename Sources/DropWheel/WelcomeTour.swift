import AppKit
import ImageIO
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// The pages of the welcome tour, in order. Pages are laid out on an 875 × 565 design canvas that the window
/// shows at 0.8 scale (700 × 452 points).
enum WelcomePage: Int, CaseIterable {
    case welcome = 0, demo, convert, tools, actions, saved, setup

    /// The wheel a wheel page shows (convert, tools and actions), nil on the others.
    var wheel: WheelMode? {
        switch self {
        case .convert: return .convert
        case .tools: return .tools
        case .actions: return .actions
        default: return nil
        }
    }

    var isWheelPage: Bool { wheel != nil }
    /// 1-based, as the page indicator says it ("Page 3 of 7").
    var number: Int { rawValue + 1 }

    var name: String {
        switch self {
        case .welcome: return "welcome"
        case .demo: return "demo"
        case .convert: return "convert"
        case .tools: return "tools"
        case .actions: return "actions"
        case .saved: return "saved"
        case .setup: return "setup"
        }
    }

    /// A page from its number (1…7, clamped) or its name.
    static func parse(_ text: String) -> WelcomePage? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = Int(t) { return WelcomePage(rawValue: min(max(n, 1), allCases.count) - 1) }
        return allCases.first { $0.name == t }
    }
}

// MARK: - Copy

/// Every sentence the tour shows, in one place.
enum WelcomeCopy {
    static let windowTitle = "Welcome to YummyOrange"
    static let helloLead = "Welcome to"
    static let appName = "YummyOrange"
    static let start = "Get Started"
    static let next = "Continue"
    static let done = "Done"
    static let back = "Back"
    static let skip = "Skip"
    static let retry = "Try again"

    // Demo
    static let demoTitle = "Try it out"
    static let dragNote = "Grab it and drag"
    static let tapLead = "Now tap"
    static func tapTrail(_ wheel: WheelMode) -> String { "for the \(wheel.rawValue) wheel" }
    static func dropNote(_ wheel: WheelMode) -> String { wheel == .convert ? "Let go on a format" : "Let go on a petal" }
    static let savedNote = "Your copy, right beside it"
    static let anywhere = "Same moves work on files in Finder, on your desktop, anywhere."
    static let noWheel = "Every wheel is off. Pick a key in Settings › Wheels to try this."

    static func actionNote(_ title: String) -> String {
        switch title {
        case FileAction.copy.rawValue: return "Copied, ready to paste in any folder"
        case FileAction.copyPath.rawValue: return "Its full path is on the clipboard"
        case FileAction.reveal.rawValue: return "Shown in its Finder window"
        case FileAction.terminal.rawValue: return "A Terminal opens in its folder"
        case FileAction.airDrop.rawValue: return "Sent to a Mac or iPhone nearby"
        case FileAction.moveTo.rawValue: return "Moved to a folder you pick"
        case "Float": return "Parked on a shelf above your windows"
        case "Zip": return "Packed into a zip next to it"
        default: return "Done, and the original stays as it was"
        }
    }

    static func hint(_ step: WelcomeDemoModel.Step, wheel: WheelMode?) -> String {
        switch step {
        case .drag: return "Drag the sample photo."
        case .shortcut:
            guard let wheel, let key = WelcomeKeys.capKey(wheel) else { return noWheel }
            return "Keep dragging and tap \(key.name) to open the \(wheel.rawValue) wheel."
        case .drop: return "Move over a petal and let go."
        case .done: return "A new copy is saved beside the original."
        }
    }

    // Wheel pages
    static func wheelTitle(_ wheel: WheelMode) -> String { "\(wheel.rawValue) wheel" }
    static let stepOne = "1. Drag any file"
    static let stepTwo = "2. Then tap"
    static let keyOff = "Off. Pick a key in Settings."

    // Where results go
    static let savedTitle = "Where copies go"
    static let savedBody = "Each result lands in the same folder as the file you dropped, named after it. Nothing is "
        + "overwritten: lake.png becomes lake.jpg, then lake 2.jpg."
    static let revealTitle = "Show new files"
    /// What the current Show new files choice does (the line under it on the saved page).
    static var revealDetail: String { Settings.resultsDestination.detail }
    static let savedCaption = "The file you drop is never changed.\nChange this any time in Settings."

    // Setup
    static let setupTitle = "You’re all set"
    static let setupBody = "YummyOrange waits in the menu bar. Choose whether it opens when you log in; keys, looks and "
        + "sounds can be changed any time in Settings."
    static let menuBarHint = "Look for YummyOrange near the clock in your menu bar"
    static let loginTitle = "Open at login"
    static let loginDetail = "Have it ready after every restart."
    static let loginApproval = "macOS wants your OK: switch YummyOrange on in Login Items."
    static let openLoginItems = "Show Login Items"
    static let keysTitle = "Your keys"
    static let openSettings = "Settings…"
}

// MARK: - Keys

/// The keys that open each wheel, as the tour shows them (from AppShell, so changed keys show up here).
enum WelcomeKeys {
    static func symbol(_ wheel: WheelMode) -> String { AppShell.keySymbol(for: wheel) }

    /// The key cap for a wheel, nil when that wheel is off.
    static func capKey(_ wheel: WheelMode) -> WheelKey? {
        let s = symbol(wheel)
        guard !s.isEmpty else { return nil }
        return WheelKey.allCases.first { $0 != .off && $0.symbol == s }
    }

    /// The name printed on a Mac key ("shift"), "" for a combination, "off" when the wheel is off.
    static func name(_ symbol: String) -> String {
        switch symbol {
        case "": return "off"
        case "⇧": return "shift"
        case "⌘": return "command"
        case "⌃": return "control"
        case "⌥": return "option"
        case "fn", "🌐": return "fn"
        default: return ""
        }
    }

    /// The modifier flags a key symbol stands for ("⌥⇧" is option + shift).
    static func flags(_ symbol: String) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if symbol.contains("⇧") { f.insert(.shift) }
        if symbol.contains("⌘") { f.insert(.command) }
        if symbol.contains("⌃") { f.insert(.control) }
        if symbol.contains("⌥") { f.insert(.option) }
        if symbol.contains("fn") || symbol.contains("🌐") { f.insert(.function) }
        return f
    }

    /// The wheel the demo asks for: Convert, or the first wheel that has a key; nil when all are off.
    static var practiceWheel: WheelMode? {
        [WheelMode.convert, .tools, .actions].first { !symbol($0).isEmpty }
    }

    /// Glyph drawn top-right on a key cap (shift has none, like a Mac keyboard), the name bottom-left, and its width.
    static func cap(_ key: WheelKey) -> (symbol: String?, name: String, width: CGFloat) {
        switch key {
        case .shift: return (nil, "shift", 108)
        case .command: return ("⌘", "command", 70)
        case .option: return ("⌥", "option", 56)
        case .control: return ("⌃", "control", 56)
        case .off: return (nil, "off", 56)
        }
    }
}

// MARK: - Sample photo

/// The demo photo: drawn on the fly, and saved once in a temporary folder so the real wheels can list what they
/// offer for it. The demo never runs a petal on it.
enum WelcomeSample {
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("YummyOrange Practice", isDirectory: true)
    }
    static var url: URL { folder.appendingPathComponent(fileName) }
    static let fileName = "lake.png"
    static let pixelSize = CGSize(width: 600, height: 600)

    /// Writes the sample if it isn't there (or isn't a readable image) and returns it.
    @discardableResult
    static func make() throws -> URL {
        let url = self.url
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 { return url }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let image = drawing(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ConversionError.toolFailed("Couldn’t make the practice photo.")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.toolFailed("Couldn’t save the practice photo.") }
        return url
    }

    /// The thumbnail image (drawn once).
    static let image: NSImage = {
        guard let cg = drawing() else { return NSImage(size: pixelSize) }
        return NSImage(cgImage: cg, size: CGSize(width: pixelSize.width / 2, height: pixelSize.height / 2))
    }()

    /// A mountain lake at blue hour, drawn with Core Graphics.
    static func drawing() -> CGImage? {
        let w = Int(pixelSize.width), h = Int(pixelSize.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let W = CGFloat(w), H = CGFloat(h)
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
        let horizon = H * 0.40
        // Sky: deep blue overhead, pale and warm at the horizon.
        let sky = CGGradient(colorsSpace: nil, colors: [color(0.09, 0.16, 0.40), color(0.30, 0.50, 0.82), color(0.86, 0.88, 0.92),
                                                        color(0.99, 0.86, 0.72)] as CFArray, locations: [0, 0.48, 0.86, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: horizon), options: [.drawsAfterEndLocation])
        // Low sun with a soft halo.
        let sun = CGPoint(x: W * 0.66, y: horizon + H * 0.13)
        let halo = CGGradient(colorsSpace: nil, colors: [color(1, 0.97, 0.88, 0.9), color(1, 0.93, 0.80, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(halo, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: W * 0.26, options: [])
        ctx.setFillColor(color(1, 0.98, 0.92))
        ctx.fillEllipse(in: CGRect(x: sun.x - W * 0.045, y: sun.y - W * 0.045, width: W * 0.09, height: W * 0.09))
        // Two mountain ranges.
        func range(_ peaks: [(CGFloat, CGFloat)], _ fill: CGColor) {
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 0, y: horizon))
            for (x, y) in peaks { ctx.addLine(to: CGPoint(x: W * x, y: horizon + H * y)) }
            ctx.addLine(to: CGPoint(x: W, y: horizon))
            ctx.closePath()
            ctx.setFillColor(fill)
            ctx.fillPath()
        }
        range([(0, 0.10), (0.14, 0.22), (0.27, 0.13), (0.40, 0.27), (0.55, 0.12), (0.72, 0.21), (0.86, 0.09), (1, 0.15)],
              color(0.47, 0.56, 0.76))
        range([(0, 0.04), (0.10, 0.12), (0.22, 0.06), (0.36, 0.15), (0.50, 0.05), (0.63, 0.10), (0.80, 0.03), (0.92, 0.09), (1, 0.05)],
              color(0.22, 0.29, 0.50))
        // The lake, with the sun's reflection broken into ripples.
        let water = CGGradient(colorsSpace: nil, colors: [color(0.58, 0.68, 0.86), color(0.16, 0.24, 0.45)] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: horizon))
        ctx.drawLinearGradient(water, start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: 0), options: [])
        for i in 0..<9 {
            let y = horizon - H * (0.02 + CGFloat(i) * 0.03)
            let half = W * (0.07 - CGFloat(i) * 0.005)
            ctx.setFillColor(color(1, 0.95, 0.85, 0.55 - CGFloat(i) * 0.05))
            ctx.fill(CGRect(x: sun.x - half, y: y, width: half * 2, height: H * 0.008))
        }
        ctx.restoreGState()
        // Dark shore in front.
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0, y: 0))
        ctx.addLine(to: CGPoint(x: 0, y: H * 0.16))
        ctx.addCurve(to: CGPoint(x: W * 0.42, y: H * 0.04), control1: CGPoint(x: W * 0.16, y: H * 0.15), control2: CGPoint(x: W * 0.28, y: H * 0.05))
        ctx.addLine(to: CGPoint(x: W * 0.42, y: 0))
        ctx.closePath()
        ctx.setFillColor(color(0.08, 0.11, 0.21))
        ctx.fillPath()
        return ctx.makeImage()
    }

    /// The petals a wheel offers for the sample, with handlers that do nothing (the demo only shows them).
    static func items(for mode: WheelMode) -> [WheelItem] {
        if let cached = itemCache[mode] { return cached }
        let url = (try? make()) ?? self.url
        let items = AppDelegate.items(for: mode, files: [url]).map { WheelItem(title: $0.title, symbol: $0.symbol, handler: { _ in }) }
        itemCache[mode] = items
        return items
    }
    private static var itemCache: [WheelMode: [WheelItem]] = [:]

    /// The name of the file a petal would save next to the sample, nil when it saves none (file actions).
    static func outputName(for title: String, wheel: WheelMode) -> String? {
        let base = (fileName as NSString).deletingPathExtension, ext = (fileName as NSString).pathExtension
        switch wheel {
        case .convert:
            let t = title.lowercased()
            let known = ["jpeg": "jpg", "markdown": "md", "text": "txt", "tiff": "tiff"]
            let out = OutputFormat(rawValue: t)?.fileExtension ?? known[t] ?? t.filter { $0.isLetter || $0.isNumber }
            return "\(base).\(out.isEmpty ? ext : out)"
        case .tools:
            switch title {
            case FileTool.compress.rawValue: return "\(base) compressed.jpg"
            case FileTool.stripMetadata.rawValue: return "\(base) clean.\(ext)"
            case FileTool.halfSize.rawValue: return "\(base) half.\(ext)"
            case FileTool.rotate.rawValue: return "\(base) rotated.\(ext)"
            case FileTool.extractText.rawValue: return "\(base).txt"
            case FileTool.makePDF.rawValue: return "\(base).pdf"
            default: return "\(base) edited.\(ext)"
            }
        case .actions:
            return nil
        }
    }
}

// MARK: - Model

/// What the tour shows and where it goes next. The view runs the page transition; while it does, `isChangingPage`
/// keeps Continue and Back from firing twice.
final class WelcomeModel: ObservableObject {
    @Published var page: WelcomePage
    @Published var isChangingPage = false
    /// Shown once when Done is pressed while macOS still wants approval for Open at Login.
    @Published var loginApprovalShown = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginNote: String?

    let demo: WelcomeDemoModel
    /// False for snapshots and self-tests: no transitions, timers or system changes.
    let live: Bool
    var onFinish: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// Where "completed" is recorded (self-tests use a scratch suite).
    var defaults: UserDefaults = .standard
    private var observers: [NSObjectProtocol] = []

    static let completedKey = "welcome.completed"

    init(page: WelcomePage = .welcome, live: Bool, demoState: String? = nil) {
        self.page = page
        self.live = live
        demo = WelcomeDemoModel(live: live)
        if let demoState { demo.apply(preview: demoState) }
        refreshLogin()
        guard live else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.objectWillChange.send()
            self?.refreshLogin()
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshLogin()
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func next() {
        guard !isChangingPage else { return }
        if page == .setup {
            if finish() { onFinish?() }
            return
        }
        move(to: WelcomePage(rawValue: min(page.rawValue + 1, WelcomePage.allCases.count - 1)) ?? .setup)
    }

    func back() {
        guard !isChangingPage else { return }
        move(to: WelcomePage(rawValue: max(page.rawValue - 1, 0)) ?? .welcome)
    }

    /// Jumps straight to a page (the menu item, self-check hooks).
    func go(to target: WelcomePage) {
        guard target != page else { return }
        move(to: target)
    }

    private func move(to target: WelcomePage) {
        guard target != page else { return }
        if target != .demo { demo.reset() }
        // The view's transition clears this; headless there is no view, so there is nothing to wait for.
        isChangingPage = live
        page = target
    }

    /// The view calls this when a transition has finished.
    func pageChangeFinished() { isChangingPage = false }

    func dismiss() { onDismiss?() }

    /// Done on the last page. Returns false (and shows a hint) the first time Open at Login still needs approval.
    func finish() -> Bool {
        if launchAtLogin, SMAppService.mainApp.status == .requiresApproval, !loginApprovalShown {
            loginApprovalShown = true
            return false
        }
        defaults.set(true, forKey: Self.completedKey)
        return true
    }

    // MARK: Open at Login (the app's Launch at Login setting)

    var loginAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func refreshLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        loginNote = loginAvailable ? (status == .requiresApproval ? WelcomeCopy.loginApproval : nil) : LaunchAtLogin.note
    }

    func setLaunchAtLogin(_ on: Bool) {
        guard live, loginAvailable else { return }
        if let message = LaunchAtLogin.set(on) {
            refreshLogin()
            loginNote = message
        } else {
            refreshLogin()
        }
    }
}

// MARK: - Window

/// A borderless panel that can still become key (for Return, Esc and the switches) and closes with Esc and ⌘W.
final class WelcomePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { closeIfAllowed() }
    override func performClose(_ sender: Any?) { closeIfAllowed() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers == "w" { closeIfAllowed(); return true }
        if mods == .command, event.charactersIgnoringModifiers == "m" { miniaturize(nil); return true }
        return super.performKeyEquivalent(with: event)
    }

    private func closeIfAllowed() {
        if delegate?.windowShouldClose?(self) ?? true { close() }
    }
}

/// Shows the tour: once on first launch, and from "Welcome Tour…" in the menu bar. It's an ordinary window,
/// so the real wheel keeps working while it's open.
final class WelcomeTour: NSObject, NSWindowDelegate {
    static let shownKey = "welcome.tourShown"
    static let size = CGSize(width: 700, height: 452)
    static let canvas = CGSize(width: 875, height: 565)
    private(set) static var current: WelcomeTour?

    static func shouldShowOnLaunch(_ defaults: UserDefaults = .standard) -> Bool { !defaults.bool(forKey: shownKey) }
    static func markShown(_ defaults: UserDefaults = .standard) { defaults.set(true, forKey: shownKey) }

    /// Opens the tour (on page `page`, 1…7, when given). When it is already open it is brought forward where it
    /// is, or moved to `page` when one is given.
    static func show(page: Int? = nil) {
        show(page.map { WelcomePage(rawValue: min(max($0, 1), WelcomePage.allCases.count) - 1) ?? .welcome })
    }

    static func show(_ page: WelcomePage?, demoState: String? = nil, markAsShown: Bool = true) {
        if let current {
            if let page { current.model.go(to: page) }
            current.refocus()
            return
        }
        let tour = WelcomeTour(page: page ?? .welcome, demoState: demoState)
        current = tour
        if markAsShown { markShown() }
        NSApp.activate(ignoringOtherApps: true)
        tour.place()
        tour.panel.orderFrontRegardless()
        tour.panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak tour] in tour?.refocus() }
        // The shadow follows the window's alpha; trace it again once SwiftUI has drawn the capsule.
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak tour] in tour?.panel.invalidateShadow() }
        }
    }

    let panel: WelcomePanel
    let model: WelcomeModel

    private init(page: WelcomePage, demoState: String?) {
        model = WelcomeModel(page: page, live: true, demoState: demoState)
        panel = Self.makePanel(model: model)
        super.init()
        panel.delegate = self
        model.onDismiss = { [weak self] in self?.close() }
        model.onFinish = { [weak self] in self?.close() }
    }

    /// The window: borderless, clear and shadowed, clipped to a stadium; SwiftUI draws the continuous capsule inside.
    static func makePanel(model: WelcomeModel) -> WelcomePanel {
        let panel = WelcomePanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.closable, .miniaturizable],
                                 backing: .buffered, defer: false)
        panel.title = WelcomeCopy.windowTitle
        panel.identifier = NSUserInterfaceItemIdentifier("dropWheelWelcome")
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .documentWindow
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentMinSize = size
        panel.contentMaxSize = size

        let controller = NSViewController()
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        let clip = NSView(frame: root.bounds)
        clip.autoresizingMask = [.width, .height]
        clip.wantsLayer = true
        clip.layer?.cornerRadius = size.height / 2
        clip.layer?.masksToBounds = true
        let host = NSHostingController(rootView: WelcomeRootView(model: model))
        host.sizingOptions = []
        host.view.frame = clip.bounds
        host.view.autoresizingMask = [.width, .height]
        clip.addSubview(host.view)
        root.addSubview(clip)
        controller.view = root
        controller.addChild(host)
        panel.contentViewController = controller
        panel.setContentSize(size)
        return panel
    }

    /// The tour's content for `--snapshot welcome`: no window, transitions or system changes.
    static func snapshotView(page: WelcomePage, demoState: String?) -> NSView {
        let model = WelcomeModel(page: page, live: false, demoState: demoState)
        let host = NSHostingView(rootView: WelcomeRootView(model: model))
        host.frame = CGRect(origin: .zero, size: size)
        return host
    }

    /// Centred on the screen that has the pointer.
    private func place() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            panel.center()
            return
        }
        let v = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: (v.midX - Self.size.width * 0.5).rounded(), y: (v.midY - Self.size.height * 0.5).rounded()))
    }

    private func refocus() {
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func close() {
        model.demo.reset()
        panel.orderOut(nil)
        panel.contentViewController = nil
        panel.delegate = nil
        if Self.current === self { Self.current = nil }
    }

    /// Esc and ⌘W end up here: tidy up the same way the close dot does.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        model.demo.reset()
        if Self.current === self { Self.current = nil }
    }

    // MARK: Self-check hooks

    /// DW_SELFCHECK_WELCOME=<page>[:<demo state>] opens the tour on that page (number 1…7 or name) shortly after
    /// launch without marking it as seen. Demo states: drag, shortcut, drop, done, plus -tools / -actions variants
    /// (drop-tools, done-actions…). Also: DW_SELFCHECK_APPEARANCE=dark|light, DW_SELFCHECK_WELCOME_ADVANCE=<s>[,<s>…]
    /// (press Continue after each delay, in seconds from opening) and DW_SELFCHECK_QUIT_AFTER=<s>.
    /// Returns true when the hook ran (the first-launch tour is then skipped).
    static func runSelfCheckHook(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let spec = env["DW_SELFCHECK_WELCOME"] else { return false }
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        let page = parts.first.flatMap(WelcomePage.parse) ?? .welcome
        let state = parts.count > 1 ? parts[1] : nil
        switch env["DW_SELFCHECK_APPEARANCE"]?.lowercased() {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            show(page, demoState: state, markAsShown: false)
            let steps = (env["DW_SELFCHECK_WELCOME_ADVANCE"] ?? "").split(separator: ",").compactMap { Double($0) }
            for delay in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { current?.model.next() }
            }
        }
        if let quit = env["DW_SELFCHECK_QUIT_AFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + quit) { NSApp.terminate(nil) }
        }
        return true
    }
}
