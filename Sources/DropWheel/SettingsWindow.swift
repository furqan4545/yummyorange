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
            FFmpegRowModel.shared.refresh()   // and YummyOrange’s own ffmpeg
        }
        if let section { tabs.select(section) }
        tabs.fitWindowToSelectedTab(animate: false)
        LaunchAtLogin.refresh()   // in case it was changed in System Settings
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The open window takes the selected pane's height again (About's ffmpeg row grew or shrank).
    func fitToContent() {
        guard Self.isOpen else { return }
        tabs.fitWindowToSelectedTab(animate: true)
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
                        Text("© 2026 Epoxlab LLC").font(.caption).foregroundStyle(.tertiary)
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
            // ffmpeg's row has a section of its own, with no footer: its status can take three lines, and a grouped
            // form gave a row that shares its section, or sits above a footer, only the height of two (the text ran
            // into the next row). The license note, about ffmpeg, closes the group under cwebp.
            Section {
                FFmpegToolRow()
            } header: {
                Text("Helper tools")
            }
            Section {
                ToolRow(name: "cwebp", purpose: "WebP images", tool: AboutInfo.cwebp,
                        missing: Capabilities.shared.offers("libwebp") ? "Not found. WebP is made with ffmpeg instead."
                                                                       : "Not found. Saving WebP is off.")
            } footer: {
                Text(AboutInfo.licenseNoteText).font(.caption).foregroundStyle(.secondary)
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
        unavailableReason ?? "Looks for a new version every hour and tells you when one is out. Nothing installs until you choose."
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

/// What About's ffmpeg row shows (FFmpegToolRow draws it; `--selftest helper` checks the words for each state).
struct FFmpegRow: Equatable {
    enum Trailing: Equatable {
        /// The person's own ffmpeg: where it is.
        case path(String)
        /// YummyOrange's own copy: "Installed by YummyOrange", with its path as the help tag.
        case installed(path: String)
        /// On its way: the fraction downloaded (nil until known; 1 while it is put in place), with Cancel while it
        /// downloads.
        case progress(Double?, cancel: Bool)
        /// None yet, and this copy can get one: a Download button.
        case download
        /// None, and this copy can't get one.
        case missing(String)
    }

    /// Under the name: "Audio and video · version 8.0.1 · LGPL 2.1+ build".
    var detail: String
    /// A line under that: what is happening or what to do.
    var status: String?
    /// The status is a problem (it gets a warning symbol).
    var isProblem = false
    var trailing: Trailing

    static let purpose = "Audio and video"
    static let installedByYummyOrange = "Installed by YummyOrange"
    static let downloading = "Downloading…"
    static let installing = "Installing…"
    static let unavailable = "Not found. Audio and video conversions are off."

    /// The quiet download starts by itself (a minute after launch, on a network that isn't metered) or when a task
    /// needs it; Download gets it now.
    static func notInstalled(size: Int) -> String {
        "Not installed yet. YummyOrange downloads it by itself (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))), "
            + "or click Download to get it now."
    }

    /// `failure`: why the last attempt failed (FFmpegHelper.failure), shown as the row's problem.
    static func make(found: FFmpegLookup.Found?, tool: AboutInfo.Tool, phase: FFmpegHelper.Phase, failure: String? = nil, canFetch: Bool,
                     downloadSize: Int) -> FFmpegRow {
        if canFetch {
            switch phase {
            case .downloading(let fraction): return FFmpegRow(detail: purpose, status: downloading, trailing: .progress(fraction, cancel: true))
            case .installing: return FFmpegRow(detail: purpose, status: installing, trailing: .progress(1, cancel: false))
            case .idle, .failed: break
            }
        }
        if let found {
            let facts = [purpose, tool.version, tool.license].compactMap { $0 }.joined(separator: " · ")
            switch found.source {
            case .user: return FFmpegRow(detail: facts, trailing: .path(found.ffmpeg.path))
            case .helper: return FFmpegRow(detail: facts, trailing: .installed(path: found.ffmpeg.path))
            }
        }
        guard canFetch else { return FFmpegRow(detail: purpose, trailing: .missing(unavailable)) }
        if phase == .failed {
            return FFmpegRow(detail: purpose, status: failure ?? FFmpegHelperText.offline, isProblem: true, trailing: .download)
        }
        return FFmpegRow(detail: purpose, status: notInstalled(size: downloadSize), trailing: .download)
    }

    /// The row for this Mac now.
    static func current() -> FFmpegRow {
        let helper = FFmpegHelper.shared
        return make(found: Capabilities.shared.ffmpegFound, tool: AboutInfo.ffmpeg, phase: helper.phase, failure: helper.failure,
                    canFetch: helper.canFetch, downloadSize: helper.config.build.length)
    }
}

/// Redraws the ffmpeg row as the helper downloads, while the Settings window is open; closed, the row catches up when
/// it opens (SettingsWindowController.show), so a download costs an open menu-bar menu nothing.
final class FFmpegRowModel: ObservableObject {
    static let shared = FFmpegRowModel()
    private var observer: NSObjectProtocol?

    /// The row's words without the percentage, to notice when its height may change.
    private var lastShape = ""

    private init() {
        observer = NotificationCenter.default.addObserver(forName: FFmpegHelper.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, SettingsModel.followsLiveChanges() else { return }
            self.objectWillChange.send()
            // A status line came or went (Downloading… → Installed by YummyOrange): the window takes the pane's new
            // height, as it does when a pane is chosen. Percentages alone change nothing.
            let shape = Self.shape(FFmpegRow.current())
            if shape != self.lastShape {
                self.lastShape = shape
                DispatchQueue.main.async { if SettingsWindowController.isOpen { SettingsWindowController.shared.fitToContent() } }
            }
        }
    }

    func refresh() {
        lastShape = Self.shape(FFmpegRow.current())
        objectWillChange.send()
    }

    private static func shape(_ row: FFmpegRow) -> String {
        var trailing = ""
        switch row.trailing {
        case .path: trailing = "path"
        case .installed: trailing = "installed"
        case .progress: trailing = "progress"
        case .download: trailing = "download"
        case .missing(let text): trailing = text
        }
        return [row.detail, row.status ?? "", trailing].joined(separator: "|")
    }
}

/// About's ffmpeg row: the person's own (its path), YummyOrange's (Installed by YummyOrange), on its way (a bar that
/// fills), or none yet (Download).
private struct FFmpegToolRow: View {
    @ObservedObject private var model = FFmpegRowModel.shared

    var body: some View {
        let row = FFmpegRow.current()
        LabeledContent {
            trailing(row.trailing)
        } label: {
            // A name and one caption Text under it, like SettingLabel: a grouped form lays out a label's second Text as
            // its subtitle and gave a third one no room. A problem's line leads with the warning symbol.
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "ffmpeg")
                caption(row).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func caption(_ row: FFmpegRow) -> Text {
        var text = Text(row.detail).foregroundColor(.secondary)
        if let status = row.status {
            text = text + Text("\n")
            if row.isProblem { text = text + Text(Image(systemName: "exclamationmark.triangle.fill")).foregroundColor(.orange) + Text(" ") }
            text = text + Text(status).foregroundColor(.secondary)
        }
        return text
    }

    @ViewBuilder private func trailing(_ trailing: FFmpegRow.Trailing) -> some View {
        switch trailing {
        case .path(let path):
            Text(path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        case .installed(let path):
            Text(FFmpegRow.installedByYummyOrange).foregroundStyle(.secondary).help(path)
        case .progress(let fraction, let cancel):
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    if let fraction {
                        ProgressView(value: fraction).frame(width: 120)
                        Text("\(FFmpegHelperText.percent(fraction))%").monospacedDigit().foregroundStyle(.secondary)
                            .frame(minWidth: 36, alignment: .trailing)
                    } else {
                        ProgressView().progressViewStyle(.linear).frame(width: 120)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Downloading ffmpeg")
                .accessibilityValue(fraction.map { "\(FFmpegHelperText.percent($0)) percent" } ?? "")
                // Halting it loses only what has come in so far, a few megabytes: no confirmation.
                if cancel {
                    Button("Cancel") { FFmpegHelper.shared.cancel() }
                        .accessibilityLabel("Cancel the ffmpeg download")
                }
            }
        case .download:
            Button("Download") { FFmpegHelper.shared.fetch() }
        case .missing(let text):
            Text(text).foregroundStyle(.orange).multilineTextAlignment(.trailing)
        }
    }
}

/// The app's icon (AppIcon.icns in the bundle); a development build without one shows the menu-bar symbol on an
/// accent tile instead.
private struct AppIconView: View {
    var body: some View {
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") != nil {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).accessibilityHidden(true)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
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

/// Facts for the About tab, each probed once.
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

    /// The ffmpeg in use (the person's own or YummyOrange's): where it is, its version and its license. Each ffmpeg is
    /// asked once; YummyOrange's own copy tells it while it installs (`remember`), so About never waits for it.
    static var ffmpeg: Tool {
        guard let url = Capabilities.shared.ffmpeg else { return Tool() }
        ffmpegLock.lock()
        let known = ffmpegTools[url.path]
        ffmpegLock.unlock()
        if let known { return known }
        let tool = ffmpegTool(path: url.path, versionOutput: (try? ProcessRunner.run(url, ["-hide_banner", "-version"]))?.stdout ?? "")
        ffmpegLock.lock(); ffmpegTools[url.path] = tool; ffmpegLock.unlock()
        return tool
    }

    private static let ffmpegLock = NSLock()
    private static var ffmpegTools: [String: Tool] = [:]

    /// What is known about the ffmpeg at `path`, without running it.
    static func ffmpeg(atPath path: String) -> Tool? {
        ffmpegLock.lock(); defer { ffmpegLock.unlock() }
        return ffmpegTools[path]
    }

    /// What `ffmpeg -version` said for the ffmpeg at `path` (any thread).
    static func remember(ffmpegVersionOutput text: String, path: String) {
        let tool = ffmpegTool(path: path, versionOutput: text)
        ffmpegLock.lock(); ffmpegTools[path] = tool; ffmpegLock.unlock()
    }

    /// "ffmpeg version 8.0.1 Copyright…" and its configuration line: "version 8.0.1" and the license.
    static func ffmpegTool(path: String, versionOutput text: String) -> Tool {
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        var version: String?
        if let range = first.range(of: "version ") {
            version = first[range.upperBound...].split(separator: " ").first.map { "version \($0)" }
        }
        return Tool(path: path, version: version, license: ffmpegLicense(configuration: text))
    }

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

    /// Helper tools' footer: whose ffmpeg runs, and under which license.
    static let licenseNote = "YummyOrange’s own ffmpeg is an LGPL 2.1 build of FFmpeg; its license and source code are at "
        + "\(licenseLinkText). An ffmpeg already on this Mac is used instead, under its own license."
    static let licenseLinkText = "yummyorange.com/licenses/ffmpeg.html"
    static let licenseURL = URL(string: "https://yummyorange.com/licenses/ffmpeg.html")!

    /// The footer with its address as a link.
    static var licenseNoteText: AttributedString {
        var text = AttributedString(licenseNote)
        if let range = text.range(of: licenseLinkText) { text[range].link = licenseURL }
        return text
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
