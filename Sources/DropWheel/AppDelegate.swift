import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = DragMonitor()
    private let overlay = OverlayController()
    private var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        _ = Capabilities.shared   // probe encoders once, up front

        monitor.onOpen = { [weak self] mode, files in self?.open(mode, files) }
        monitor.onCancel = { [weak self] in self?.overlay.hide() }
        monitor.onDragEnded = { [weak self] in self?.overlay.hide() }
        monitor.onOpenSettings = { [weak self] in
            self?.overlay.hide()
            SettingsWindowController.shared.show()
        }
        monitor.start()
        Registry.modules.forEach { $0.appDidLaunch() }
    }

    // MARK: Wheel

    private func open(_ mode: WheelMode, _ files: [URL]) {
        if overlay.isVisible && overlay.mode == mode { return }
        overlay.show(mode: mode, items: Self.items(for: mode, files: files))
    }

    /// The petals one wheel offers for these files: the built-in ones, then each feature module's.
    static func items(for mode: WheelMode, files: [URL]) -> [WheelItem] {
        switch mode {
        case .convert:
            let formats = OutputFormat.targets(forAll: files)
            var items = formats.map { format in
                WheelItem(title: format.label, symbol: nil) { urls in
                    // Never re-encode a file into the format it already has (a lossy "photo 2.png").
                    let todo = urls.filter { OutputFormat.targets(forAll: [$0]).contains(format) }
                    guard !todo.isEmpty else {
                        HUD.shared.flash(urls.count == 1 ? "\(urls[0].lastPathComponent) is already \(format.label)."
                                                         : "These files are already \(format.label).", isError: true)
                        return
                    }
                    JobRunner.run(.convert(format), on: todo)
                }
            }
            appendCommands(.convert, files, besides: formats, to: &items)
            return items
        case .tools:
            var items = FileTool.tools(for: files).map { tool in
                WheelItem(title: tool.rawValue, symbol: symbol(for: tool)) { urls in
                    switch tool {
                    case .protect:
                        guard let pw = PasswordPrompt.ask(title: "Add a Password",
                                                          message: "Anyone opening the protected copy will need this password.",
                                                          confirm: true, button: "Protect") else { return }
                        JobRunner.run(.protect(password: pw), on: urls)
                    case .unlock:
                        guard let pw = PasswordPrompt.ask(title: "Remove Password",
                                                          message: "Enter the PDF’s password to save an unprotected copy.",
                                                          confirm: false, button: "Unlock") else { return }
                        JobRunner.run(.unlock(password: pw), on: urls)
                    default:
                        JobRunner.run(.tool(tool), on: urls)
                    }
                }
            }
            appendCommands(.tools, files, to: &items)
            return items
        case .actions:
            var items = FileAction.allCases.map { action in
                WheelItem(title: action.rawValue, symbol: symbol(for: action)) { action.perform(on: $0) }
            }
            appendCommands(.actions, files, to: &items)
            return items
        }
    }

    /// Adds the petals feature modules contribute, skipping any whose title is already on the wheel.
    /// A module petal opens its window (`present`), or asks for options (`ask`) and then runs as a job.
    /// On the Convert wheel, a selection that different modules convert (DOCX + PPTX + XLSX + EPUB) also gets a
    /// petal for each format every file reaches on its own, which runs each file through the command that converts
    /// it (`Registry.convertCommands`; `formats` are the built-in petals already shown).
    private static func appendCommands(_ wheel: WheelMode, _ files: [URL], besides formats: [OutputFormat] = [],
                                       to items: inout [WheelItem]) {
        var titles = Set(items.map(\.title))
        let commands = wheel == .convert ? Registry.convertCommands(for: files, besides: formats)
                                         : Registry.commands(for: wheel, files: files)
        for command in commands where !titles.contains(command.title) {
            titles.insert(command.title)
            items.append(WheelItem(title: command.title, symbol: command.symbol) { urls in
                if let present = command.present { present(urls); return }
                var options: ToolOptions = [:]
                if let ask = command.ask {
                    guard let answer = ask(urls) else { return }
                    options = answer
                }
                JobRunner.run(.command(command, options), on: urls)
            })
        }
    }

    private static func symbol(for tool: FileTool) -> String {
        switch tool {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .stripMetadata: return "eye.slash"
        case .halfSize: return "rectangle.compress.vertical"
        case .rotate: return "rotate.right"
        case .mute: return "speaker.slash"
        case .extractAudio: return "waveform"
        case .normalize: return "slider.horizontal.3"
        case .mergePDF: return "rectangle.stack"
        case .makePDF: return "doc.badge.plus"
        case .split: return "square.split.2x1"
        case .extractText: return "text.viewfinder"
        case .protect: return "lock"
        case .unlock: return "lock.open"
        }
    }

    private static func symbol(for action: FileAction) -> String {
        switch action {
        case .copy: return "doc.on.doc"
        case .copyPath: return "link"
        case .reveal: return "folder"
        case .terminal: return "terminal"
        case .airDrop: return "dot.radiowaves.left.and.right"
        case .moveTo: return "arrowshape.turn.up.right"
        }
    }

    // MARK: Menu bar

    /// The first menu line: which key opens which wheel, from Settings.
    static func menuHint(_ keys: WheelKeyMap = Settings.wheelKeys) -> String {
        keys.allOff ? "All wheels are off. Turn one on in Settings." : "Drag files, then tap \(keys.hint)"
    }

    private enum MenuTag { static let hint = 1, login = 2 }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image()   // the app icon's wheel, as a template image
        let menu = Self.makeMenu(target: self)
        menu.delegate = self
        loginItem = menu.item(withTag: MenuTag.login)
        statusItem.menu = menu
    }

    /// The menu-bar menu. `target` handles Launch at Login and Settings…; `--snapshot menu` draws it with nil.
    /// “Update to YummyOrange 1.0.1…” heads it while an update is known (Updater.swift), “Check for Updates…” is always
    /// above Settings….
    static func makeMenu(target: AppDelegate?) -> NSMenu {
        let menu = NSMenu()
        UpdateMenu.topItems().forEach(menu.addItem)
        menu.addItem(ResultsMenu.shared.makeItem())   // Show New Files › On a Shelf, On the Clothesline, In Finder, Don't Show
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = target
        loginItem.tag = MenuTag.login
        menu.addItem(loginItem)
        let extra = Registry.modules.flatMap { $0.menuItems() }
        if !extra.isEmpty {
            menu.addItem(.separator())
            extra.forEach(menu.addItem)
        }
        menu.addItem(.separator())
        menu.addItem(UpdateMenu.checkItem())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = target
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "Quit YummyOrange", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        UpdateMenu.refresh(menu)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        UpdateMenu.refresh(menu)
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }

    @objc private func toggleLogin() {
        if let message = LaunchAtLogin.set(SMAppService.mainApp.status != .enabled) {
            HUD.shared.flash(message, isError: true)
        }
    }
}

extension OutputFormat {
    /// The built-in conversions offered for a whole selection: the formats every file can be converted to, in
    /// wheel order, whatever order the files came in. A file's own format is no conversion for it, so
    /// [photo.png, camera.dng] gets no PNG petal (and [clip.mp4, odd.mkv] neither MP4 nor MKV).
    static func targets(forAll files: [URL]) -> [OutputFormat] {
        guard !files.isEmpty else { return [] }
        let kind = FileKind.common(files)
        var seen = Set<String>()
        var result: [OutputFormat]?
        for file in files where seen.insert(file.pathExtension.lowercased()).inserted {
            let formats = targets(for: kind, source: file.pathExtension)
            result = result.map { list in list.filter(formats.contains) } ?? formats
        }
        return result ?? []
    }
}

/// Launch at Login through SMAppService, shared by the menu and the Settings window.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Turns it on or off. Returns a message to show when that didn't work.
    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            NotificationCenter.default.post(name: Settings.didChange, object: nil)
            return nil
        } catch {
            return "Couldn’t change Launch at Login: \(error.localizedDescription)"
        }
    }

    /// A note for the Settings window when macOS needs something from the user, nil when all is well.
    static var note: String? {
        if Bundle.main.bundleIdentifier == nil { return "Available when YummyOrange runs as an app." }
        if SMAppService.mainApp.status == .requiresApproval {
            return "Allow YummyOrange in System Settings › General › Login Items."
        }
        return nil
    }
}
