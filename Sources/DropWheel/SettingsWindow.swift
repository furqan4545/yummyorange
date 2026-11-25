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

    /// The window is open (from `show()` until it closes). Its four tabs stay built after it closes, so the model
    /// forwards the updater's and the login status's changes only while it is open (SettingsModel).
    private(set) static var isOpen = false

    private let tabs = SettingsTabViewController()
    private var closeObserver: NSObjectProtocol?
    private static let frameName = "DropWheelSettings"

    private init() {
        let window = Self.makeWindow(tabs, remembersFrame: true)
        super.init(window: window)
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                               queue: .main) { _ in Self.isOpen = false }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The Settings window around `tabs`, already titled after the selected pane so it never shows "Untitled".
    /// `remembersFrame`: only the real window saves where it was (self-tests and snapshots leave preferences alone).
    static func makeWindow(_ tabs: SettingsTabViewController, remembersFrame: Bool) -> NSWindow {
        let window = NSWindow(contentViewController: tabs)
        // Minimize and zoom dimmed (HIG, Settings: "Dim a settings window’s minimize and maximize buttons"): ⌘, opens
        // it in a moment, and it already fits each pane.
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        if remembersFrame { window.setFrameAutosaveName(frameName) }
        tabs.updateWindowTitle()
        return window
    }

    func show(_ section: SettingsSection? = nil) {
        if !Self.isOpen {
            Self.isOpen = true
            SettingsModel.shared.objectWillChange.send()   // what the updater and the login status did while closed
        }
        if let section { tabs.select(section) }
        tabs.fitWindowToSelectedTab(animate: false)
        LaunchAtLogin.refresh()   // in case it was changed in System Settings
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// `--snapshot settings-window [--opt section=general|wheels|look|about]`: a fresh Settings window drawn whole,
    /// title bar and toolbar included, so its title can be checked by eye. Never shown; its frame isn't saved.
    static func snapshotView(section: SettingsSection, dark: Bool) -> NSView {
        let tabs = SettingsTabViewController()
        let window = makeWindow(tabs, remembersFrame: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        tabs.select(section)
        tabs.fitWindowToSelectedTab(animate: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let frameView = window.contentView?.superview else { return tabs.view }
        frameView.layoutSubtreeIfNeeded()
        frameView.display()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return tabs.view }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let image = NSImage(size: frameView.bounds.size)
        image.addRepresentation(rep)
        let view = NSImageView(frame: CGRect(origin: .zero, size: frameView.bounds.size))
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        window.contentViewController = nil
        return view
    }
}

/// Toolbar-style tabs that resize the window to fit each tab, keeping its top edge in place, and title the window
/// after the visible pane (HIG, Settings: "Update the window's title to reflect the currently visible pane").
final class SettingsTabViewController: NSTabViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        for section in SettingsSection.allCases {
            let host = NSHostingController(rootView: SettingsSectionView(section: section))
            host.sizingOptions = [.preferredContentSize]
            // The tab view controller takes the selected tab's title as its own, and the window shows it: without
            // one the window was "Untitled" (in the title bar, Mission Control and to VoiceOver).
            host.title = section.title
            // The image goes on before the view controller. NSTabViewItem(viewController:) looks for images named
            // after the controller's class in the app's asset catalog, which YummyOrange doesn't have: 6 failed
            // lookups per tab, each logged as a CoreUI error, every time Settings… built its window. An item that
            // already has an image skips them.
            let item = NSTabViewItem(identifier: section.rawValue)
            item.label = section.title
            item.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
            item.viewController = host
            addTabViewItem(item)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Every way a pane gets picked ends here: a toolbar click, the toolbar from the keyboard, and `select(_:)`.
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        updateWindowTitle()
        fitWindowToSelectedTab(animate: view.window?.isVisible ?? false)
    }

    /// The visible pane.
    var selectedSection: SettingsSection {
        let items = tabViewItems
        guard items.indices.contains(selectedTabViewItemIndex),
              let id = items[selectedTabViewItemIndex].identifier as? String else { return .general }
        return SettingsSection(rawValue: id) ?? .general
    }

    /// Shows `section` (Settings… from a hint, comma while dragging, the welcome tour).
    func select(_ section: SettingsSection) {
        if let index = tabViewItems.firstIndex(where: { $0.identifier as? String == section.rawValue }) {
            selectedTabViewItemIndex = index
        }
        updateWindowTitle()
    }

    /// Titles the window after the visible pane: "General", "Wheels", "Look" or "About". VoiceOver reads it too.
    func updateWindowTitle() {
        guard isViewLoaded, let window = view.window else { return }
        let title = selectedSection.title
        if window.title != title { window.title = title }
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

    /// Whether the updater's and the login status's changes reach the views: while the Settings window is open.
    /// Self-tests set their own.
    static var followsLiveChanges: () -> Bool = { SettingsWindowController.isOpen }

    init() {
        // Settings, and whether clipboard screenshots can still be read (the caption under Hang copied screenshots).
        observers = [Settings.didChange, ClotheslineScreenshots.clipboardAccessDidChange].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
        // The Launch at Login status read in the background, and the updater (General's Updates row): only while the
        // window is open. Re-rendering the four tabs takes 10 to 17 ms, and these arrive by themselves, also while
        // the menu-bar menu is open; `show()` catches up once instead.
        observers += [LaunchAtLogin.didChange, Updater.didChange].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                if Self.followsLiveChanges() { self?.objectWillChange.send() }
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
                UpdatesRow(updater: Updater.shared)
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
                    .multilineTextAlignment(.leading)   // a grouped form's footer otherwise sets a second line flush right
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle(isOn: model.holdKey) {
                    SettingLabel("Hold the key first", HoldKeySetting.detail(Settings.wheelKeys))
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
                LabeledContent {
                    Button(FounderMail.title) { FounderMail.contact() }
                        .help(FounderMail.toolTip)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Questions or ideas")
                        // Selectable, for people who write from webmail rather than a mail app.
                        Text(verbatim: "Write to Ali, who makes YummyOrange, at \(FounderMail.address).")
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollDisabled(true)
    }
}

/// General's Updates row, under Check for updates automatically: what the updater is doing or last found, and the
/// menu's Check for Updates… (Update to YummyOrange 1.0.1… once it knows of one, like the menu's first item). The
/// status line moves on by itself while the window is open ("Last checked 5 minutes ago").
struct UpdatesRow: View {
    let updater: Updater
    /// Re-rendered with the rest of the window when the updater changes (the updater itself isn't observable).
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        LabeledContent {
            if let update = updater.menuUpdate {
                Button(UpdateMenu.title(for: update)) { updater.offerLatest() }
                    .disabled(updater.phase != .idle)
            } else {
                Button(UpdateMenu.checkTitle) { updater.check(manual: true) }
                    .disabled(!updater.isAvailable || updater.phase != .idle)
            }
        } label: {
            // In a copy that can't update, the setting just above already says why.
            TimelineView(.everyMinute) { context in
                SettingLabel("Updates", updater.isAvailable ? UpdateSetting.status(updater, now: context.date) : nil)
            }
        }
    }
}

/// The words under Check for updates automatically (what it does, or why this copy can't) and in the Updates row.
enum UpdateSetting {
    static func detail(_ unavailableReason: String?) -> String {
        unavailableReason ?? "Looks for new versions a few times a day and tells you when one is available. Nothing installs until you choose."
    }

    /// Why this copy can't update, what the updater is doing, the update it found, or when it last checked.
    static func status(_ updater: Updater, now: Date = Date()) -> String {
        if let reason = updater.environment.unavailableReason { return reason }
        switch updater.phase {
        case .checking: return "Checking for updates…"
        case .downloading: return "Downloading the update…"
        case .installing: return "Installing the update…"
        case .idle: break
        }
        if let update = updater.menuUpdate { return "YummyOrange \(update.version) is available." }
        guard let last = UpdatePreferences.lastCheck else { return "Not checked yet." }
        return "Last checked \(lastChecked(last, now: now))."
    }

    /// "just now", "5 minutes ago", "2 hours ago", "3 days ago" (in English, like the rest of YummyOrange).
    static func lastChecked(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// The words under Hold the key first, naming the keys that can be held ("Hold ⇧, ⌘ or ⌥ before…" with the defaults,
/// "Hold ⇧, ⌘, ⌃ or ⌥ before…" with Actions on ⌃, where ⌥ stands in for it as the footer above says).
enum HoldKeySetting {
    static func detail(_ keys: WheelKeyMap) -> String {
        "Hold \(keys.heldKeyList ?? "a wheel’s key") before pressing on a file in Finder, even one that’s already selected. "
            + "Clicks with a key held still select as usual."
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
