import AppKit

/// YummyOrange lives in the menu bar, but while any of its windows is open (an editor, the PDF organizer, Settings, the
/// welcome tour) it shows in the Dock and the app switcher too, so a window that slipped behind others can be brought
/// back with a click or ⌘Tab. When the last one closes it goes back to the menu bar only. Shelves, the Clothesline and
/// the corner banner float above everything and don't count.
///
/// While it is in the Dock the menu bar shows a small app menu (About, Settings…, Hide, Quit) and a Window menu listing
/// its windows. Quitting with unsaved edits asks first.
enum DockPresence {
    private static var observers: [NSObjectProtocol] = []
    private static var pending = false
    /// The updater has already asked about unsaved work before it restarts, so quitting then doesn't ask again.
    static var quittingForUpdate = false

    /// From launch, in the app only.
    static func start() {
        guard observers.isEmpty else { return }
        NSApp.mainMenu = makeMainMenu()
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                                          NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification]
        observers = names.map { NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { _ in scheduleUpdate() } }
        update()
    }

    /// Several windows change at once (one closes, another becomes key): look once, after they have settled.
    private static func scheduleUpdate() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async {
            pending = false
            update()
        }
    }

    /// A window someone works in: titled and closable, not a panel or a sheet, open (or in the Dock) and on a screen
    /// (snapshot windows sit far off every screen).
    static func counts(_ window: NSWindow) -> Bool {
        guard window.styleMask.contains(.titled), window.styleMask.contains(.closable), !(window is NSPanel), !window.isSheet,
              window.isVisible || window.isMiniaturized else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    static var userWindows: [NSWindow] { NSApp.windows.filter(counts) }

    /// The policy for the windows that are open: in the Dock while there is one, menu bar only otherwise.
    static func policy(hasWindows: Bool) -> NSApplication.ActivationPolicy { hasWindows ? .regular : .accessory }

    static func update() {
        let current = NSApp.activationPolicy()
        guard current != .prohibited else { return }
        let wanted = policy(hasWindows: !userWindows.isEmpty)
        guard wanted != current else { return }
        NSApp.setActivationPolicy(wanted)
        // Becoming a Dock app while one of its windows is key: keep that window in front, with its menu bar.
        if wanted == .regular, let key = NSApp.keyWindow, counts(key) { NSApp.activate(ignoringOtherApps: true) }
    }

    /// The Dock icon was clicked: bring back a window that is in the Dock (minimized) when none is showing.
    static func reopen(hasVisibleWindows: Bool) -> Bool {
        let windows = userWindows
        if !windows.contains(where: { $0.isVisible && !$0.isMiniaturized }), let first = windows.first {
            if first.isMiniaturized { first.deminiaturize(nil) }
            first.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    /// ⌘Q, Quit in the Dock's menu or the menu bar: asks first when an editor has changes that haven't been saved.
    static func shouldTerminate() -> NSApplication.TerminateReply {
        let unsaved = PendingWork.unsavedEditors()
        guard !quittingForUpdate, !unsaved.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit YummyOrange?"
        alert.informativeText = unsaved.joined(separator: " ") + " Quitting now throws those changes away."
        alert.addButton(withTitle: "Cancel")
        let quit = alert.addButton(withTitle: "Quit")
        quit.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: The menu bar while in the Dock

    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu(title: "YummyOrange")
        app.addItem(NSMenuItem(title: "About YummyOrange", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        app.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(MainMenuTarget.openSettings), keyEquivalent: ",")
        settings.target = MainMenuTarget.shared
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Hide YummyOrange", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let others = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(others)
        app.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Quit YummyOrange", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = app

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        window.addItem(.separator())
        window.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        windowItem.submenu = window
        NSApp.windowsMenu = window
        return main
    }
}

/// Targets for the app menu (menu items hold their target weakly, so it lives here for good).
final class MainMenuTarget: NSObject {
    static let shared = MainMenuTarget()
    @objc func openSettings() { SettingsWindowController.shared.show() }
}
