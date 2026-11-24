#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import SwiftUI

/// The Show New Files setting, for `--selftest settings`: its default, the migration from the old on/off
/// "Reveal results in Finder", the Settings window's pop-up, the menu-bar submenu and the `--opt` mapping.
extension AppShellTests {
    static let resultsTitles = ["On a Shelf", "On the Clothesline", "In Finder", "Don’t Show"]

    static func resultsSettings(_ c: Checker, suite: SettingsMemoryStore, posted: () -> Int, resetPosted: () -> Void) {
        c.check("Show new files: On a Shelf by default", Settings.resultsDestination == .shelf)
        resetPosted()
        Settings.resultsDestination = .finder
        Settings.resultsDestination = .finder
        c.check("Show new files saves (one notification) and never writes the old key",
                Settings.resultsDestination == .finder && suite.string(forKey: "resultsDestination") == "finder"
                && suite.object(forKey: "revealResults") == nil && posted() == 1, "posted \(posted())")
        Settings.resultsDestination = .shelf

        // Migration from the old Bool.
        let cases: [([String: Any], ResultsDestination, String)] = [
            ([:], .shelf, "never set"),
            (["revealResults": true], .shelf, "Reveal was on"),
            (["revealResults": false], .none, "Reveal was turned off"),
            (["revealResults": false, "resultsDestination": "finder"], .finder, "a saved choice wins over the old key"),
            (["revealResults": true, "resultsDestination": "none"], .none, "a saved Don't Show stays"),
            (["revealResults": false, "resultsDestination": "banana"], .none, "an unknown saved value falls back to the old key"),
        ]
        for (values, expected, label) in cases {
            let store = SettingsMemoryStore(values)
            Settings.defaults = store
            let read = Settings.resultsDestination
            let untouched = store.object(forKey: "resultsDestination") as? String == values["resultsDestination"] as? String
                && store.object(forKey: "revealResults") as? Bool == values["revealResults"] as? Bool
            c.check("migration, \(label): \(expected.title)", read == expected && untouched, "read \(read.rawValue)")
        }
        let migrated = SettingsMemoryStore(["revealResults": false])
        Settings.defaults = migrated
        Settings.resultsDestination = .shelf
        c.check("after the migration, choosing On a Shelf sticks", Settings.resultsDestination == .shelf
                && migrated.string(forKey: "resultsDestination") == "shelf")
        Settings.defaults = suite
    }

    /// Picks `title` in a SwiftUI pop-up's own menu, as a click does, without putting a menu on screen. SwiftUI fills
    /// the menu only when it is about to show it (its coordinator's `popUpButtonCell:willShowMenu:`); the chosen item
    /// then sends its action to SwiftUI's target, which writes the picker's binding. Returns the menu's titles, or
    /// nil when the menu couldn't be filled or has no such item.
    static func pick(_ title: String, in popUp: NSPopUpButton) -> [String]? {
        guard let menu = popUp.menu else { return nil }
        let fill = NSSelectorFromString("popUpButtonCell:willShowMenu:")
        if let coordinator = menu.delegate as? NSObject, coordinator.responds(to: fill), let cell = popUp.cell {
            _ = coordinator.perform(fill, with: cell, with: menu)
        }
        guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else { return nil }
        NSApp.sendAction(action, to: item.target, from: item)
        return menu.items.map(\.title)
    }

    /// A SwiftUI view in an offscreen window, laid out, with its pop-up buttons and switches.
    static func hosted<V: View>(_ view: V) -> (window: NSWindow, host: NSView, popUps: [NSPopUpButton], switches: Int, settle: () -> Void) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = host
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        var popUps: [NSPopUpButton] = []
        var switches = 0
        func walk(_ v: NSView) {
            if let p = v as? NSPopUpButton { popUps.append(p) }
            if v is NSSwitch { switches += 1 }
            v.subviews.forEach(walk)
        }
        walk(host)
        return (window, host, popUps, switches, settle)
    }

    /// The General tab's pop-up, as AppKit draws it: picking each choice in its own menu saves it, and the button
    /// shows the saved choice when it changes elsewhere. The welcome tour's pop-up writes the same setting.
    static func resultsPopUp(_ c: Checker) {
        Settings.resultsDestination = .finder
        let model = SettingsModel()
        let (window, _, popUps, switches, settle) = hosted(SettingsSectionView(section: .general, snapshot: true))
        c.check("General has one pop-up (Show new files); the four switches are Hang copied screenshots, Show progress, Launch at login and Check for updates automatically",
                popUps.count == 1 && switches == 4, "\(popUps.count) pop-ups, \(switches) switches")
        guard let popUp = popUps.first else { return }
        for choice in [ResultsDestination.none, .clothesline, .shelf, .finder] {
            let titles = pick(choice.title, in: popUp)
            settle()
            c.check("Settings pop-up: choosing \(choice.title) in its menu saves it and the button shows it",
                    titles == resultsTitles && Settings.resultsDestination == choice
                    && Settings.defaults.string(forKey: "resultsDestination") == choice.rawValue && popUp.title == choice.title,
                    titles == nil ? "couldn’t open the pop-up’s menu offscreen (SwiftUI changed how it fills it?)"
                                  : "menu \(titles!), saved \(Settings.resultsDestination.rawValue), button \(popUp.title)")
        }
        for choice in [ResultsDestination.shelf, .clothesline, .none, .finder] {
            model.results.wrappedValue = choice     // the picker's selection binding
            settle()
            c.check("pop-up set to \(choice.title): saved, and the button shows “\(choice.title)”",
                    Settings.resultsDestination == choice && Settings.defaults.string(forKey: "resultsDestination") == choice.rawValue
                    && popUp.title == choice.title, "button shows \(popUp.title)")
        }
        c.check("the row under the pop-up explains each choice",
                Set(ResultsDestination.allCases.map(\.detail)).count == ResultsDestination.allCases.count
                && ResultsDestination.allCases.allSatisfy { $0.detail.hasSuffix(".") })
        do {
            let saved = ResultsDestination.hasNotch
            defer { ResultsDestination.hasNotch = saved }
            ResultsDestination.hasNotch = { true }
            let notched = ResultsDestination.clothesline.detail
            ResultsDestination.hasNotch = { false }
            let plain = ResultsDestination.clothesline.detail
            c.check("On the Clothesline says “notch” only on a Mac that has one (else: the middle of the menu bar)",
                    notched.contains("notch") && !plain.contains("notch") && plain.contains("menu bar")
                    && notched.hasSuffix(".") && plain.hasSuffix("."), "\(notched) | \(plain)")
        }
        window.contentView = nil

        // The welcome tour's “Where copies go” page has the same pop-up.
        Settings.resultsDestination = .shelf
        let welcome = hosted(WelcomeSavedColumn())
        if let wp = welcome.popUps.first, welcome.popUps.count == 1 {
            let titles = pick(ResultsDestination.finder.title, in: wp)
            welcome.settle()
            c.check("welcome pop-up: choosing In Finder in its menu saves it",
                    titles == resultsTitles && Settings.resultsDestination == .finder && wp.title == ResultsDestination.finder.title,
                    "menu \(titles ?? []), saved \(Settings.resultsDestination.rawValue), button \(wp.title)")
        } else {
            c.check("the welcome page has one Show new files pop-up", false, "\(welcome.popUps.count) pop-ups")
        }
        welcome.window.contentView = nil
        Settings.resultsDestination = .shelf
    }

    /// The menu-bar menu: Show New Files replaces the old toggle; its submenu checks the current choice and sets it.
    static func resultsMenu(_ c: Checker) {
        Settings.resultsDestination = .shelf
        let menu = AppDelegate.makeMenu(target: nil)
        let titles = menu.items.map(\.title)
        c.check("the menu has Show New Files and no Reveal toggle",
                titles.contains(ResultsMenu.title) && !titles.contains("Reveal Results in Finder"), titles.joined(separator: " | "))
        guard let sub = menu.items.first(where: { $0.title == ResultsMenu.title })?.submenu else {
            c.check("Show New Files has a submenu", false)
            return
        }
        func checked() -> [String] { sub.items.filter { $0.state == .on }.map(\.title) }
        c.check("submenu: On a Shelf, On the Clothesline, In Finder, Don’t Show, with On a Shelf checked",
                sub.items.map(\.title) == resultsTitles && checked() == ["On a Shelf"], "\(checked())")
        for (index, choice) in ResultsDestination.allCases.enumerated().reversed() {
            sub.performActionForItem(at: index)
            c.check("choosing \(choice.title) in the menu writes the setting and moves the checkmark",
                    Settings.resultsDestination == choice && checked() == [choice.title], "\(Settings.resultsDestination.rawValue) \(checked())")
        }
        Settings.resultsDestination = .finder   // changed elsewhere (Settings window)
        ResultsMenu.shared.menuNeedsUpdate(sub)
        c.check("the checkmark follows a change made elsewhere when the menu opens", checked() == ["In Finder"], "\(checked())")
        let icon = MenuBarIcon.image()
        let rep = icon.cgImage(forProposedRect: nil, context: nil, hints: nil).map { NSBitmapImageRep(cgImage: $0) }
        let inked = rep.map { r in (0..<r.pixelsWide).contains { x in (0..<r.pixelsHigh).contains { y in (r.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 } } } ?? false
        c.check("the menu-bar icon is the wheel as an 18 pt template image (tinted by macOS for light and dark menu bars)",
                icon.isTemplate && icon.size == NSSize(width: 18, height: 18) && inked && icon.accessibilityDescription == "YummyOrange")
        c.check("every submenu item has a target and an explanation",
                sub.items.allSatisfy { $0.target != nil && $0.action != nil && !($0.toolTip ?? "").isEmpty })
        // A MacBook's lid opened after launch: the next time the menu opens, On the Clothesline talks about the notch.
        do {
            let saved = ResultsDestination.hasNotch
            defer { ResultsDestination.hasNotch = saved }
            let entry = sub.items.first { $0.title == ResultsDestination.clothesline.title }
            ResultsDestination.hasNotch = { false }
            ResultsMenu.shared.menuNeedsUpdate(sub)
            let before = entry?.toolTip ?? ""
            ResultsDestination.hasNotch = { true }
            ResultsMenu.shared.menuNeedsUpdate(sub)
            let after = entry?.toolTip ?? ""
            c.check("On the Clothesline's explanation in the menu follows the displays (no notch, then one)",
                    !before.contains("notch") && after.contains("notch") && after == ResultsDestination.clothesline.detail,
                    "\(before) | \(after)")
        }
        Settings.resultsDestination = .shelf
    }

    /// `--opt results=…` and the older `--opt reveal=on|off` (snapshots and the welcome tour's snapshot).
    static func resultsOptions(_ c: Checker) {
        let cases: [(ToolOptions, ResultsDestination, String)] = [
            ([:], .shelf, "no option"),
            (["results": "finder"], .finder, "results=finder"),
            (["results": " None "], .none, "results= None "),
            (["results": "shelf"], .shelf, "results=shelf"),
            (["results": "Clothesline"], .clothesline, "results=Clothesline"),
            (["reveal": "on"], .finder, "reveal=on (older spelling)"),
            (["reveal": "off"], .none, "reveal=off (older spelling)"),
            (["reveal": "false"], .none, "reveal=false"),
            (["results": "shelf", "reveal": "off"], .shelf, "results wins over reveal"),
            (["results": "banana"], .shelf, "an unknown value is ignored"),
        ]
        for (options, expected, label) in cases {
            AppShell.useSnapshotSettings(options)
            c.check("--opt \(label) → \(expected.title)", Settings.resultsDestination == expected
                    && Settings.defaults.object(forKey: "revealResults") == nil, "got \(Settings.resultsDestination.rawValue)")
        }
    }
}
#endif
