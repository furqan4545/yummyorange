import AppKit
import SwiftUI

/// App-level features: settings window, per-wheel modifier keys, wheel looks and sounds, gesture polish.
/// It adds no petals of its own; it renders snapshots of the wheel and the Settings window, and runs
/// the `gesture`, `wheel`, `settings` and `mainthread` self-tests (`appshell` runs them all).
enum AppShell: FeatureModule {
    /// Launch self-checks, driven by the environment (app mode only):
    /// - DW_SELFCHECK_JOB="<file>|<format>": runs one conversion through the app's job runner.
    /// - DW_SELFCHECK_OVERLAY=1: shows a sample wheel once, ~0.5 s after launch, logs what the window server
    ///   reports for it (on screen, alpha, layer, petals), and hides it ~1.9 s later. Tuned with
    ///   DW_SELFCHECK_OVERLAY_MODE=convert|tools|actions, _COUNT=<n>, _HIGHLIGHT=<i>, _STYLE=glass|metallic,
    ///   _HOLD=<seconds>, _AT=<x,y>|center (a screen point; the mouse location otherwise).
    /// - DW_SELFCHECK_WHEEL_WINDOW=1: the same sample wheel, live, in a small window over the desktop-like
    ///   preview background (same options), so glass can be judged against a known backdrop.
    /// - DW_SELFCHECK_SETTINGS=<general|wheels|look|about>: that Settings tab in a window of its own.
    /// - DW_SELFCHECK_APPEARANCE=dark|light: the app's appearance for these checks.
    /// - DW_SELFCHECK_PRESENT="<tool id>|<file>": that tool's editor window on the file (it takes focus, like the petal).
    /// - DW_WHEEL_SLOWMO=<factor>: slows the wheel's opening.
    /// None of these windows takes focus; each closes itself after its hold time.
    static func appDidLaunch() {
        let env = ProcessInfo.processInfo.environment
        if let spec = env["DW_SELFCHECK_JOB"], let bar = spec.lastIndex(of: "|"),
           let format = OutputFormat(rawValue: String(spec[spec.index(after: bar)...])) {
            let file = URL(fileURLWithPath: String(spec[..<bar]))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { JobRunner.run(.convert(format), on: [file]) }
        }
        if let look = env["DW_SELFCHECK_APPEARANCE"]?.lowercased() {
            NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
        }
        let check = SelfCheckOptions(env)
        if env["DW_SELFCHECK_OVERLAY"] == "1" { showOverlaySelfCheck(check) }
        if env["DW_SELFCHECK_WHEEL_WINDOW"] == "1" { showWheelWindowSelfCheck(check) }
        if let name = env["DW_SELFCHECK_SETTINGS"], let section = SettingsSection(rawValue: name.lowercased()) {
            showSettingsSelfCheck(section, hold: check.hold)
        }
        // DW_SELFCHECK_PRESENT="<tool id>|<file>": opens that tool's window on the file, as its petal does, so the real
        // on-screen window (toolbar glass, active look, cursors) can be captured.
        if let spec = env["DW_SELFCHECK_PRESENT"], let bar = spec.firstIndex(of: "|") {
            let id = String(spec[..<bar]), file = URL(fileURLWithPath: String(spec[spec.index(after: bar)...]))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let match = Registry.commands.first { $0.id == id && $0.present != nil && $0.applies([file]) }
                if let present = match?.present { present([file]) } else { NSLog("DW_SELFCHECK_PRESENT: no window tool \(id) for \(file.path)") }
            }
        }
    }

    /// Options shared by the wheel self-checks.
    struct SelfCheckOptions {
        var mode: WheelMode = .convert
        var count: Int?
        var highlight: Int?
        var style: WheelStyle?
        var hold: TimeInterval = 1.9
        var at: CGPoint?

        init(_ env: [String: String]) {
            if let m = env["DW_SELFCHECK_OVERLAY_MODE"].flatMap({ v in WheelMode.allCases.first { $0.rawValue.lowercased() == v.lowercased() } }) { mode = m }
            count = env["DW_SELFCHECK_OVERLAY_COUNT"].flatMap { Int($0) }
            highlight = env["DW_SELFCHECK_OVERLAY_HIGHLIGHT"].flatMap { Int($0) }
            style = env["DW_SELFCHECK_OVERLAY_STYLE"].flatMap { WheelStyle(rawValue: $0.lowercased()) }
            if let h = env["DW_SELFCHECK_OVERLAY_HOLD"].flatMap({ Double($0) }) { hold = min(max(h, 0.3), 6) }
            if env["DW_SELFCHECK_OVERLAY_AT"] == "center", let screen = NSScreen.main?.visibleFrame {
                at = CGPoint(x: screen.midX, y: screen.midY)
            } else if let xy = env["DW_SELFCHECK_OVERLAY_AT"]?.split(separator: ","), xy.count == 2,
                      let x = Double(xy[0]), let y = Double(xy[1]) { at = CGPoint(x: x, y: y) }
        }

        var items: [WheelItem] {
            let samples = AppShell.sampleItems(mode)
            guard let count else { return samples }
            return (0..<min(max(count, 0), 24)).map { samples[$0 % samples.count] }
        }
    }

    private static func showOverlaySelfCheck(_ check: SelfCheckOptions) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let style = check.style { Settings.defaults = SettingsMemoryStore(["wheelStyle": style.rawValue]) }
            let overlay = OverlayController()
            overlay.wheel.playsFeedback = false
            overlay.show(mode: check.mode, items: check.items, at: check.at)
            overlay.wheel.setHighlight(check.highlight)
            selfCheckRetain = overlay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let number = overlay.windowNumberForSelfCheck
                let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]])?.first
                let line = "overlay self-check: window \(number) onscreen=\(String(describing: info?[kCGWindowIsOnscreen as String] ?? "nil")) alpha=\(String(describing: info?[kCGWindowAlpha as String] ?? "nil")) layer=\(String(describing: info?[kCGWindowLayer as String] ?? "nil")) petals=\(overlay.wheel.items.count)"
                DragMonitor.log.notice("\(line, privacy: .public)")
                print(line)
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, check.hold - 0.4)) {
                    overlay.hide()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { selfCheckRetain = nil }
                }
            }
        }
    }
    private static var selfCheckRetain: OverlayController?
    private static var selfCheckWindows: [NSWindow] = []

    private static func showWheelWindowSelfCheck(_ check: SelfCheckOptions) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let items = check.items
            let side = WheelLayout.diameter(for: items.count)
            let background = AppShellSnapshotBackground(color: nil)
            background.frame = CGRect(x: 0, y: 0, width: side, height: side)
            let wheel = WheelView(frame: background.bounds)
            wheel.autoresizingMask = [.width, .height]
            wheel.style = check.style ?? Settings.wheelStyle
            wheel.modeTitle = check.mode.rawValue
            wheel.items = items
            wheel.playsFeedback = false
            wheel.unregisterDraggedTypes()
            wheel.setHighlight(check.highlight)
            background.addSubview(wheel)
            let window = NSWindow(contentRect: background.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "YummyOrange wheel self-check"
            window.isReleasedWhenClosed = false
            window.contentView = background
            if let at = check.at { window.setFrameOrigin(CGPoint(x: at.x - side / 2, y: at.y - side / 2)) } else { window.center() }
            window.orderFrontRegardless()
            wheel.playIntro()
            selfCheckWindows.append(window)
            print("wheel window self-check: window \(window.windowNumber) petals=\(items.count)")
            DispatchQueue.main.asyncAfter(deadline: .now() + check.hold) {
                window.orderOut(nil)
                selfCheckWindows.removeAll { $0 === window }
            }
        }
    }

    private static func showSettingsSelfCheck(_ section: SettingsSection, hold: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let host = NSHostingView(rootView: SettingsSectionView(section: section))
            host.setFrameSize(host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.title = section.title
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.center()
            window.orderFrontRegardless()
            selfCheckWindows.append(window)
            print("settings self-check: window \(window.windowNumber) section=\(section.rawValue)")
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                window.orderOut(nil)
                selfCheckWindows.removeAll { $0 === window }
            }
        }
    }

    static var commands: [WheelCommand] { [] }

    /// Contract (used by the welcome tour and the menu hint): the key symbol that opens a wheel,
    /// such as "⇧", or "" when that wheel is turned off.
    static func keySymbol(for wheel: WheelMode) -> String {
        Settings.wheelKeys.key(for: wheel).symbol
    }

    // MARK: Snapshots

    /// `--snapshot settings [--opt section=general|wheels|look|about|all]` and
    /// `--snapshot wheel [--opt style=glass|metallic count=<n> mode=convert|tools|actions highlight=<i> accent=#RRGGBB
    /// opening=<seconds into the opening animation> rotation=<degrees clockwise>] [files]`.
    /// Settings options (style, convert, tools, actions, sounds, haptics, progress, results=shelf|clothesline|finder|none,
    /// and reveal=on|off as an older spelling of results=finder|none) apply to the snapshot only; nothing is saved.
    static func snapshot(_ id: String, files: [URL], options: ToolOptions) -> NSView? {
        switch id {
        case "settings":
            useSnapshotSettings(options)
            return settingsSnapshot(options.string("section", "all"))
        case "wheel":
            useSnapshotSettings(options)
            return wheelSnapshot(files: files, options: options)
        default:
            return nil
        }
    }

    /// Points Settings at an in-memory store seeded from the options, so snapshots don't depend on
    /// (or write to) real preferences. Also used by the welcome tour's snapshot.
    static func useSnapshotSettings(_ options: ToolOptions) {
        var values: [String: Any] = [:]
        if let style = options["style"].flatMap({ WheelStyle(rawValue: $0.lowercased()) }) { values["wheelStyle"] = style.rawValue }
        for mode in WheelMode.allCases {
            if let key = options[mode.rawValue.lowercased()].flatMap({ WheelKey(rawValue: $0.lowercased()) }) {
                values["wheelKey.\(mode.rawValue.lowercased())"] = key.rawValue
            }
        }
        for (option, key) in [("sounds", "petalSounds"), ("haptics", "haptics"), ("progress", "showProgressHUD"),
                              ("screenshots", "hangScreenshots")] {
            if options[option] != nil { values[key] = options.bool(option, true) }
        }
        // results=shelf|clothesline|finder|none; reveal=on|off still works (on: In Finder, off: Don't Show).
        if let results = ResultsDestination.parse(options) { values["resultsDestination"] = results.rawValue }
        Settings.defaults = SettingsMemoryStore(values)
    }

    private static func settingsSnapshot(_ section: String) -> NSView {
        let sections = SettingsSection(rawValue: section.lowercased()).map { [$0] } ?? SettingsSection.allCases
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = sections.count > 1 ? 6 : 0
        stack.edgeInsets = sections.count > 1 ? NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0) : NSEdgeInsets()
        for s in sections {
            if sections.count > 1 {
                let title = NSTextField(labelWithString: s.title)
                title.font = .systemFont(ofSize: 15, weight: .semibold)
                let row = NSStackView(views: [title])
                row.edgeInsets = NSEdgeInsets(top: 8, left: 22, bottom: 0, right: 0)
                stack.addArrangedSubview(row)
            }
            let host = NSHostingView(rootView: SettingsSectionView(section: s, snapshot: true))
            host.setFrameSize(host.fittingSize)
            stack.addArrangedSubview(host)
        }
        let container = AppShellSnapshotBackground(color: .windowBackgroundColor)
        container.addSubview(stack)
        stack.setFrameSize(stack.fittingSize)
        container.setFrameSize(stack.fittingSize)
        return container
    }

    private static func wheelSnapshot(files: [URL], options: ToolOptions) -> NSView {
        let mode = WheelMode.allCases.first { $0.rawValue.lowercased() == options.string("mode", "convert").lowercased() } ?? .convert
        var items: [WheelItem]
        if !files.isEmpty && options["count"] == nil {
            items = AppDelegate.items(for: mode, files: files)
        } else {
            let samples = sampleItems(mode)
            let n = min(max(options.int("count", 8), 0), 24)
            items = (0..<n).map { samples[$0 % samples.count] }
        }
        if let titles = options["titles"] {
            items = titles.split(separator: "|").map { WheelItem(title: String($0), symbol: nil, handler: { _ in }) }
        }
        let d = WheelView.preferredDiameter(for: items.count)
        let margin: CGFloat = 24
        let container = AppShellSnapshotBackground(color: nil)
        container.setFrameSize(CGSize(width: d + 2 * margin, height: d + 2 * margin))
        let wheel = WheelView(frame: CGRect(x: margin, y: margin, width: d, height: d))
        wheel.style = Settings.wheelStyle
        wheel.modeTitle = mode.rawValue
        wheel.items = items
        wheel.playsFeedback = false
        wheel.accentOverride = options["accent"].flatMap { NSColor(hex: $0) }
        if options["highlight"] != nil { wheel.setHighlight(options.int("highlight", 0)) }
        if let degrees = options["rotation"].flatMap({ Double($0) }) { wheel.rotation = CGFloat(degrees * .pi / 180) }
        if let seconds = options["opening"].flatMap({ Double($0) }) { wheel.pauseIntro(at: seconds) }
        container.addSubview(wheel)
        return container
    }

    /// Realistic petals for each wheel, about as many as feature modules add, including long titles.
    static func sampleItems(_ mode: WheelMode) -> [WheelItem] {
        let pairs: [(String, String?)]
        switch mode {
        case .convert:
            pairs = ["JPG", "PNG", "HEIC", "WebP", "TIFF", "AVIF", "GIF", "PDF", "BMP", "SVG", "ICO", "DOCX",
                     "Markdown", "EPUB", "RTF", "HTML"].map { ($0, nil) }
        case .tools:
            pairs = [("Compress", "arrow.down.right.and.arrow.up.left"), ("Strip Metadata", "eye.slash"),
                     ("Half Size", "rectangle.compress.vertical"), ("Rotate 90°", "rotate.right"),
                     ("Extract Text", "text.viewfinder"), ("Make PDF", "doc.badge.plus"),
                     ("Resize…", "arrow.up.left.and.arrow.down.right"), ("Frame…", "square.dashed"),
                     ("Collage…", "square.grid.2x2"), ("Read QR Code", "qrcode.viewfinder"),
                     ("Adjust…", "slider.horizontal.3"), ("Annotate…", "pencil.tip.crop.circle"),
                     ("Compress To…", "gauge.with.dots.needle.33percent"), ("Crop…", "crop"),
                     ("Remove Background", "person.crop.rectangle"), ("Watermark…", "signature")]
        case .actions:
            pairs = [("Copy", "doc.on.doc"), ("Copy Path", "link"), ("Reveal", "folder"), ("Terminal", "terminal"),
                     ("AirDrop", "dot.radiowaves.left.and.right"), ("Move To…", "arrowshape.turn.up.right"),
                     ("Float", "tray"), ("Zip", "doc.zipper"), ("Rename…", "pencil"), ("Email", "envelope"),
                     ("Open With…", "arrow.up.forward.app"), ("Duplicate", "plus.square.on.square"),
                     ("Quick Look", "eye"), ("Tags…", "tag"), ("Share…", "square.and.arrow.up"), ("Info", "info.circle")]
        }
        return pairs.map { WheelItem(title: $0.0, symbol: $0.1, handler: { _ in }) }
    }

    // MARK: Self-tests

    static func selfTest(_ name: String) -> String? {
        #if DEBUG
        switch name {
        case "gesture": return AppShellTests.gesture()
        case "wheel": return WheelSelfTest.run()
        case "settings": return AppShellTests.settings()
        case "mainthread": return AppShellTests.mainThread()
        case "appshell":
            let reports = [AppShellTests.gesture(), WheelSelfTest.run(), AppShellTests.settings(), AppShellTests.mainThread()]
            let failed = reports.contains { $0.hasPrefix("FAIL") }
            return (failed ? "FAIL\n" : "PASS\n") + reports.joined(separator: "\n\n")
        default:
            return nil
        }
        #else
        return nil
        #endif
    }
}

/// A flat background for snapshots: a color, or the desktop-like gradient when nil.
final class AppShellSnapshotBackground: NSView {
    private let color: NSColor?

    init(color: NSColor?) {
        self.color = color
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let color = self.color {
                color.setFill()
                self.bounds.fill()
            } else {
                ThemeDesktop.draw(in: self.bounds, dark: self.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            }
        }
    }
}
