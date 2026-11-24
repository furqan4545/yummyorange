import AppKit
import SwiftUI

/// The tabs of the Settings window.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, wheels, look, about

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .wheels: return "circle.dotted.circle"
        case .look: return "paintpalette"
        case .about: return "info.circle"
        }
    }
}

extension WheelMode {
    /// What the wheel offers, for the Settings window.
    var settingsDetail: String {
        switch self {
        case .convert: return "Change the file format"
        case .tools: return "Compress, rotate, merge and more"
        case .actions: return "Copy, reveal, share or move"
        }
    }
}

// MARK: - Window

/// The Settings window: a toolbar of tabs (General, Wheels, Look, About), each a native grouped form.
/// Opened from the menu (⌘,) or by tapping comma while dragging files.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let tabs = SettingsTabViewController()

    private init() {
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DropWheelSettings")
        super.init(window: window)
        if !window.setFrameUsingName("DropWheelSettings") { window.center() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ section: SettingsSection? = nil) {
        if let section, let index = SettingsSection.allCases.firstIndex(of: section) {
            tabs.selectedTabViewItemIndex = index
        }
        tabs.fitWindowToSelectedTab(animate: false)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Toolbar-style tabs that resize the window to fit each tab, keeping its top edge in place.
final class SettingsTabViewController: NSTabViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        for section in SettingsSection.allCases {
            let host = NSHostingController(rootView: SettingsSectionView(section: section))
            host.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: host)
            item.label = section.title
            item.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
            addTabViewItem(item)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        fitWindowToSelectedTab(animate: view.window?.isVisible ?? false)
    }

    /// Sizes the window to the selected tab's content, keeping the title bar where it is.
    func fitWindowToSelectedTab(animate: Bool) {
        let index = selectedTabViewItemIndex
        guard let window = view.window, tabViewItems.indices.contains(index),
              let content = tabViewItems[index].viewController?.view else { return }
        let size = content.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        let top = window.frame.maxY
        window.setFrame(CGRect(x: window.frame.minX, y: top - frame.height, width: frame.width, height: frame.height),
                        display: true, animate: animate)
    }
}

// MARK: - Model

/// Bindings onto `Settings`. Refreshes the views whenever a setting changes anywhere (menu, another tab).
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()

    @Published var loginError: String?
    private var observers: [NSObjectProtocol] = []

    init() {
        // Settings, and whether clipboard screenshots can still be read (the caption under Hang copied screenshots).
        observers = [Settings.didChange, ClotheslineScreenshots.clipboardAccessDidChange].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    var results: Binding<ResultsDestination> {
        Binding(get: { Settings.resultsDestination }, set: { Settings.resultsDestination = $0 })
    }
    var screenshots: Binding<Bool> { Binding(get: { Settings.hangScreenshots }, set: { Settings.hangScreenshots = $0 }) }
    var progress: Binding<Bool> { Binding(get: { Settings.showProgressHUD }, set: { Settings.showProgressHUD = $0 }) }
    var autoUpdate: Binding<Bool> {
        Binding(get: { Settings.checkForUpdatesAutomatically }, set: { Settings.checkForUpdatesAutomatically = $0 })
    }
    var haptics: Binding<Bool> { Binding(get: { Settings.haptics }, set: { Settings.haptics = $0 }) }
    var holdKey: Binding<Bool> {
        Binding(get: { Settings.holdKeyFirst }, set: { on in
            Settings.holdKeyFirst = on
            HoldKeyTap.shared.update(prompt: on)
        })
    }
    var style: Binding<WheelStyle> { Binding(get: { Settings.wheelStyle }, set: { Settings.wheelStyle = $0 }) }

    var sounds: Binding<Bool> {
        Binding(get: { Settings.petalSounds }, set: { on in
            Settings.petalSounds = on
            if on { PetalSound.shared.sample(Settings.petalSoundStyle) }   // a sample of what it sounds like
        })
    }

    /// Choosing a sound plays it, like the alert-sound menu in System Settings.
    var soundStyle: Binding<PetalSoundStyle> {
        Binding(get: { Settings.petalSoundStyle }, set: { style in
            Settings.petalSoundStyle = style
            PetalSound.shared.sample(style)
        })
    }

    var launchAtLogin: Binding<Bool> {
        Binding(get: { LaunchAtLogin.isEnabled }, set: { [weak self] on in
            self?.loginError = LaunchAtLogin.set(on)
            self?.objectWillChange.send()
        })
    }

    func key(_ mode: WheelMode) -> Binding<WheelKey> {
        Binding(get: { Settings.wheelKeys.key(for: mode) }, set: { Settings.setKey($0, for: mode) })
    }
}

// MARK: - Views

/// One tab of the Settings window. `snapshot`: drawn for `--snapshot` (the preview wheel doesn't follow the pointer,
/// and its hint is left out).
struct SettingsSectionView: View {
    let section: SettingsSection
    var snapshot = false
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        Group {
            switch section {
            case .general: general
            case .wheels: wheels
            case .look: look
            case .about: about
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var general: some View {
        Form {
            Section {
                ResultsDestinationPicker(selection: model.results) {
                    SettingLabel("Show new files", model.results.wrappedValue.detail)
                }
                // Only the Clothesline hangs screenshots: with another choice the switch stays, dimmed, and says why.
                Toggle(isOn: model.screenshots) {
                    SettingLabel("Hang copied screenshots", ScreenshotsSetting.detail(for: model.results.wrappedValue,
                                                                                   clipboard: ClotheslineScreenshots.shared.clipboardAccess))
                }
                .disabled(model.results.wrappedValue != .clothesline)
                Toggle(isOn: model.progress) {
                    SettingLabel("Show progress", "A small panel in the top-right corner while files are worked on. Errors always appear.")
                }
            }
            Section {
                Toggle(isOn: model.launchAtLogin) {
                    SettingLabel("Launch at login", LaunchAtLogin.note ?? "Starts YummyOrange in the menu bar when you log in.")
                }
                .disabled(Bundle.main.bundleIdentifier == nil)
                if let error = model.loginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                // Dimmed, with the reason, in a copy that can't update itself (no update key, not signed, not an app).
                Toggle(isOn: model.autoUpdate) {
                    SettingLabel("Check for updates automatically", UpdateSetting.detail(Updater.shared.environment.unavailableReason))
                }
                .disabled(!Updater.shared.isAvailable)
            }
        }
        .scrollDisabled(true)
    }

    private var wheels: some View {
        Form {
            Section {
                ForEach(WheelMode.allCases, id: \.self) { mode in
                    Picker(selection: model.key(mode)) {
                        ForEach(WheelKey.allCases) { key in
                            Text(key.shortTitle).tag(key).help(key.name)
                        }
                    } label: {
                        SettingLabel(mode.rawValue, mode.settingsDetail)
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text("Key that opens each wheel")
            } footer: {
                Text("Start dragging files, then tap the key. Choosing a key another wheel uses swaps the two." +
                     (Settings.wheelKeys.optionStandsInFor.map { " ⌥ also opens \($0.rawValue): unlike ⌃, it can be held before you start dragging." } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle(isOn: model.holdKey) {
                    SettingLabel("Hold the key first",
                                 "Hold ⇧, ⌘, ⌃ or ⌥ before pressing on a file in Finder, even one that’s already selected. Clicks with a key held still select as usual.")
                }
                if Settings.holdKeyFirst && !HoldKeyTap.isTrusted {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield").foregroundStyle(.secondary)
                        Text("Allow YummyOrange in System Settings › Privacy & Security › Accessibility.").font(.caption)
                        Spacer()
                        Button("Open") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            }
            if Settings.wheelKeys.allOff {
                Section {
                    Label("All wheels are off, so dragging files won’t open anything.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                LabeledContent("While dragging") {
                    Text("Esc closes the wheel  ·  , (comma) opens Settings").foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Restore Defaults") { Settings.resetWheelKeys() }
                        .disabled(Settings.wheelKeys == .defaults)
                }
            }
        }
        .scrollDisabled(true)
    }

    private var look: some View {
        Form {
            Section {
                Picker("Wheel style", selection: model.style) {
                    ForEach(WheelStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Spacer()
                    WheelPreview(style: model.style.wrappedValue, snapshot: snapshot)
                        .frame(width: 244, height: 244)
                    Spacer()
                }
                if !snapshot {
                    Text("Move the pointer over the preview to try it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            Section {
                Toggle(isOn: model.sounds) {
                    SettingLabel("Petal sounds", "A tick for each petal you pass. Sweep fast and they run together.")
                }
                Picker(selection: model.soundStyle) {
                    ForEach(PetalSoundStyle.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel("Sound", model.soundStyle.wrappedValue.detail)
                }
                .pickerStyle(.menu)
                .disabled(!model.sounds.wrappedValue)
                Toggle(isOn: model.haptics) {
                    SettingLabel("Haptic feedback", "A light tap on Force Touch trackpads.")
                }
            }
        }
        .scrollDisabled(true)
    }

    private var about: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AppIconView().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("YummyOrange").font(.title2.weight(.semibold))
                        Text(AboutInfo.versionText).foregroundStyle(.secondary)
                        Text("Drag files, tap a key, drop on a petal.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                ToolRow(name: "ffmpeg", purpose: "Audio and video", tool: AboutInfo.ffmpeg,
                        missing: "Not found. Audio and video conversions are off.")
                ToolRow(name: "cwebp", purpose: "WebP images", tool: AboutInfo.cwebp,
                        missing: Capabilities.shared.has("libwebp") ? "Not found. WebP is made with ffmpeg instead."
                                                                    : "Not found. Saving WebP is off.")
            } header: {
                Text("Helper tools")
            } footer: {
                Text(AboutInfo.licenseNote).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollDisabled(true)
    }
}

/// The words under Check for updates automatically: what it does, or why this copy can't.
enum UpdateSetting {
    static func detail(_ unavailableReason: String?) -> String {
        unavailableReason ?? "Looks for a new version a few times a day and lets you know. Nothing is installed until you choose to, and the menu’s Check for Updates… works either way."
    }
}

/// The words under Hang copied screenshots: what it does when on (with what macOS will ask), why clipboard screenshots
/// are skipped when they are, or how to make it available.
enum ScreenshotsSetting {
    static func detail(for destination: ResultsDestination, clipboard: ClotheslineScreenshots.ClipboardAccess = .allowed) -> String {
        guard destination == .clothesline else { return "Available when new files show On the Clothesline." }
        let saved = "Copy a screenshot (⌘C in its preview, or take it with Control) and it hangs on the Clothesline, once."
        switch clipboard {
        case .allowed:
            return saved + " The copy is saved in Pictures › Clothesline; macOS asks once before YummyOrange can paste it."
        case .declined:
            return saved + " Screenshots copied to the clipboard are skipped because pasting wasn’t allowed. Turn this off and on to be asked again."
        case .denied:
            return saved + " Screenshots copied to the clipboard are skipped: allow YummyOrange in System Settings › Privacy & Security › Paste from Other Apps."
        }
    }
}

/// A setting's name with a line of explanation under it. On a dimmed row the name dims too; the explanation stays
/// readable (it often says why the row is dimmed).
struct SettingLabel: View {
    let title: String
    let detail: String?
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, _ detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(isEnabled ? HierarchicalShapeStyle.primary : .secondary)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One helper tool in About: where it was found and its version, or why it matters that it's missing.
private struct ToolRow: View {
    let name: String
    let purpose: String
    let tool: AboutInfo.Tool
    let missing: String

    var body: some View {
        LabeledContent {
            if let path = tool.path {
                Text(path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            } else {
                Text(missing).foregroundStyle(.orange).multilineTextAlignment(.trailing)
            }
        } label: {
            SettingLabel(name, [purpose, tool.version, tool.license].compactMap { $0 }.joined(separator: " · "))
        }
    }
}

/// The app's mark: the menu-bar symbol on an accent tile.
private struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                                     startPoint: .top, endPoint: .bottom))
            Image(systemName: "circle.dotted.circle")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white)
        }
    }
}

/// Facts for the About tab, probed once.
enum AboutInfo {
    struct Tool {
        var path: String?
        var version: String?
        var license: String?
    }

    static var versionText: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }

    static let ffmpeg: Tool = {
        guard let url = Capabilities.shared.ffmpeg else { return Tool() }
        let text = (try? ProcessRunner.run(url, ["-hide_banner", "-version"]))?.stdout ?? ""
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        var version: String?
        if let range = first.range(of: "version ") {
            version = first[range.upperBound...].split(separator: " ").first.map { "version \($0)" }
        }
        return Tool(path: url.path, version: version, license: ffmpegLicense(configuration: text))
    }()

    static let cwebp: Tool = {
        guard let url = Capabilities.shared.cwebp else { return Tool() }
        let text = (try? ProcessRunner.run(url, ["-version"]))?.stdout ?? ""
        let version = text.split(separator: "\n").first.map { "version \($0.trimmingCharacters(in: .whitespaces))" }
        return Tool(path: url.path, version: version)
    }()

    /// The license an ffmpeg build is under, from the options it was configured with.
    static func ffmpegLicense(configuration: String) -> String? {
        guard configuration.contains("configuration:") else { return nil }
        if configuration.contains("--enable-nonfree") { return "non-free build" }
        let v3 = configuration.contains("--enable-version3")
        if configuration.contains("--enable-gpl") { return v3 ? "GPL 3 build" : "GPL 2+ build" }
        return v3 ? "LGPL 3 build" : "LGPL 2.1+ build"
    }

    static var licenseNote: String {
        var note = "ffmpeg is free software under the GNU LGPL (or the GPL, depending on how it was built). YummyOrange runs it as a separate program and contains none of its code; its source is available from ffmpeg.org."
        if let license = ffmpeg.license, !license.hasPrefix("LGPL") {
            note += " The copy found on this Mac is a \(license); a copy of YummyOrange you pass on should bundle an LGPL build instead."
        }
        return note
    }
}

// MARK: - Wheel preview

/// The live style preview in the Look tab.
struct WheelPreview: NSViewRepresentable {
    var style: WheelStyle
    var snapshot: Bool

    func makeNSView(context: Context) -> WheelPreviewView { WheelPreviewView(snapshot: snapshot) }
    func updateNSView(_ view: WheelPreviewView, context: Context) { view.style = style }
}

/// A sample Convert wheel over a desktop-like backdrop. Hovering highlights petals (with sound and
/// haptics when they're on), so both settings can be tried here.
final class WheelPreviewView: NSView {
    private let wheel = WheelView(frame: .zero)
    private let snapshot: Bool

    var style: WheelStyle = .glass { didSet { if style != oldValue { apply() } } }

    init(snapshot: Bool) {
        self.snapshot = snapshot
        super.init(frame: CGRect(x: 0, y: 0, width: 244, height: 244))
        wheel.items = ["JPG", "PNG", "HEIC", "WebP", "TIFF", "PDF"].map { WheelItem(title: $0, symbol: nil, handler: { _ in }) }
        wheel.modeTitle = WheelMode.convert.rawValue
        wheel.playsFeedback = false
        wheel.setHighlight(1)
        wheel.playsFeedback = true
        wheel.highlightsOnHover = !snapshot
        wheel.unregisterDraggedTypes()
        addSubview(wheel)
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        wheel.frame = bounds.insetBy(dx: 6, dy: 6)
    }

    private func apply() {
        wheel.style = style
        needsLayout = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).addClip()
        ThemeDesktop.draw(in: bounds, dark: dark)
    }
}
