#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import SwiftUI

/// `--selftest menubar`: the menu-bar menu's rows and groups (and that no row comes or goes while it is open), Talk to
/// the Founder… (its panel, its mailto: link, and the copied address), the menu-bar icon's update dot, General's Updates
/// row and About's Questions or ideas.
/// Settings live in memory; nothing opens a mail app, and the clipboard used is a named one of this test's own.
enum MenuBarTests {
    typealias Checker = ResultsShelfTests.Checker

    static func run() -> String {
        let c = Checker()
        let savedDefaults = Settings.defaults
        let savedMenuUpdater = UpdateMenuTarget.shared.updater
        Settings.defaults = SettingsMemoryStore()
        defer {
            Settings.defaults = savedDefaults
            UpdateMenuTarget.shared.updater = savedMenuUpdater
        }
        menu(c)
        founderMail(c)
        icon(c)
        about(c)
        return c.report("menubar")
    }

    static func titles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    // MARK: The menu

    static func menu(_ c: Checker) {
        let updater = UpdaterTests.idleUpdater()
        UpdateMenuTarget.shared.updater = updater
        let menu = AppDelegate.makeMenu(target: nil)
        let expected = ["Show New Files", "Launch at Login", "—", "New Shelf", "Show Clothesline", "Hang Copied Screenshots", "—",
                        "Welcome Tour…", FounderMail.title, "—", UpdateMenu.checkTitle, "Settings…", "Quit YummyOrange"]
        c.check("the menu, in order: where new files show and login; the shelf and the line; help (Welcome Tour…, Talk to the Founder…); updates, Settings… and Quit",
                titles(menu) == expected, titles(menu).joined(separator: " | "))
        updater.latest = UpdaterTests.item(version: "1.0.1", build: "2")
        UpdateMenu.refresh(menu, updater: updater)
        c.check("with an update known, “Update to YummyOrange 1.0.1…” and a separator head it, and the rest stays as it was",
                titles(menu) == ["Update to YummyOrange 1.0.1…", "—"] + expected, titles(menu).joined(separator: " | "))
        let founder = menu.items.first { $0.title == FounderMail.title }
        c.check("Talk to the Founder… has its target and action, is available, and its tooltip gives the address",
                founder?.target === FounderMailTarget.shared && founder?.action == #selector(FounderMailTarget.contact)
                && founder?.isEnabled == true && founder?.toolTip?.contains(FounderMail.address) == true && founder?.keyEquivalent == "")
        let tour = menu.items.first { $0.title == "Welcome Tour…" }
        c.check("Welcome Tour… still opens the tour", tour?.target === ShelfMenuTarget.shared && tour?.action == #selector(ShelfMenuTarget.welcomeTour))
        c.check("the shelf module adds only New Shelf now (Welcome Tour… moved to the help group)",
                ShelfAndWelcome.menuItems().map(\.title) == ["New Shelf"])

        // An update found while the menu is open (the timer's check, say): its row waits until the menu closes, so no
        // row moves under the pointer. The icon's dot doesn't wait (AppDelegate.showUpdate).
        updater.latest = nil
        UpdateMenu.refresh(menu, updater: updater)
        AppDelegate.willOpen(menu)
        let openSize = MenuSnapshotView(menu: menu, open: nil).frame.size
        updater.latest = UpdaterTests.item(version: "1.0.1", build: "2")
        UpdateMenu.follow(menu, updater: updater)
        let whileOpen = titles(menu), openSizeAfter = MenuSnapshotView(menu: menu, open: nil).frame.size
        AppDelegate.didClose(menu)
        c.check("an update found while the menu is open: no row comes or goes until it closes, then “Update to YummyOrange 1.0.1…” heads it",
                UpdateMenu.isOpen(menu) == false && whileOpen == expected && openSize == openSizeAfter
                && titles(menu) == ["Update to YummyOrange 1.0.1…", "—"] + expected, "\(whileOpen) → \(titles(menu))")
        AppDelegate.willOpen(menu)
        updater.latest = nil
        UpdateMenu.follow(menu, updater: updater)
        let goneWhileOpen = titles(menu)
        AppDelegate.didClose(menu)
        c.check("…and one that goes away (skipped from the notification, say) leaves its row until the menu closes",
                goneWhileOpen.first == "Update to YummyOrange 1.0.1…" && titles(menu) == expected, "\(goneWhileOpen) → \(titles(menu))")
        UpdateMenu.follow(menu, updater: updater)
        c.check("…a closed menu follows at once", titles(menu) == expected)
        updater.latest = nil
    }

    // MARK: Talk to the Founder…

    static func founderMail(_ c: Checker) {
        let system = OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0)
        let url = FounderMail.url(version: "1.0.0", build: "1", system: system)
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((parts?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let body = FounderMail.body(version: "1.0.0", build: "1", system: system)
        c.check("the link is a new email to ali@yummyorange.com", url.scheme == "mailto" && parts?.path == "ali@yummyorange.com"
                && FounderMail.address == "ali@yummyorange.com", url.absoluteString)
        c.check("its subject says what it’s about, “About YummyOrange” (the sender can change it; the version is in the footer)",
                FounderMail.subject == "About YummyOrange" && query["subject"] == FounderMail.subject, query["subject"] ?? "none")
        c.check("its body is a greeting, room to write, then the version and the macOS version, lines ending in CR LF",
                body == "Hi Ali,\r\n\r\n\r\n\r\n--\r\nYummyOrange 1.0.0 (build 1)\r\nmacOS 13.6.0\r\n" && query["body"] == body,
                (query["body"] ?? "none").debugDescription)
        let raw = url.absoluteString
        c.check("everything but letters, digits and - . _ ~ is percent-encoded: no “+”, raw space or line break; CR LF as %0D%0A; “(” as %28",
                !raw.contains("+") && !raw.contains(" ") && !raw.contains("\r") && !raw.contains("\n") && raw.contains("%0D%0A")
                && raw.contains("subject=About%20YummyOrange&body=Hi%20Ali%2C%0D%0A") && raw.contains("%28build%201%29"), raw)
        c.check("“&”, “=”, “?”, “#” and “%” in a text can’t break the link",
                FounderMail.encode("a&b=c?d#e%f+g") == "a%26b%3Dc%3Fd%23e%25f%2Bg", FounderMail.encode("a&b=c?d#e%f+g"))
        let private_ = [NSUserName(), NSFullUserName(), ProcessInfo.processInfo.hostName, NSHomeDirectory(), Host.current().localizedName ?? ""]
            .filter { $0.count >= 3 }
        c.check("the message says nothing about the person or the Mac beyond the macOS version (no user name, Mac name or folder)",
                !private_.contains { body.localizedCaseInsensitiveContains($0) || FounderMail.subject.localizedCaseInsensitiveContains($0) })
        c.check("a copy not run as an app says “development build”",
                FounderMail.versionLine(version: nil, build: nil) == "YummyOrange (development build)"
                && FounderMail.body(version: nil, build: nil, system: system).contains("YummyOrange (development build)"))

        // The panel: the address to read or select, and the two ways to write.
        let withMail = FounderMail.panel(mailApp: "Mail"), without = FounderMail.panel(mailApp: nil)
        let field = withMail.accessoryView as? NSTextField
        c.check("the panel shows the address as selectable text, and offers Write in Mail (Return), Copy Address, Cancel (Esc)",
                withMail.buttons.map(\.title) == ["Write in Mail", "Copy Address", "Cancel"]
                && withMail.buttons[0].keyEquivalent == "\r" && withMail.buttons[2].keyEquivalent == "\u{1b}"
                && field?.stringValue == FounderMail.address && field?.isSelectable == true && field?.isEditable == false,
                withMail.buttons.map { "\($0.title)=\($0.keyEquivalent.debugDescription)" }.joined(separator: " "))
        c.check("…its title is a sentence that says who reads it (HIG: sentence style, with its period)",
                withMail.messageText == "Write to Ali, who makes YummyOrange." && withMail.informativeText.hasSuffix("."))
        c.check("…with no app for mail links, Copy Address and Cancel only (Copy Address is the default)",
                without.buttons.map(\.title) == ["Copy Address", "Cancel"] && without.buttons[0].keyEquivalent == "\r")
        c.check("the app that opens mail links on this Mac has a name (Mail.app opens them on every Mac)",
                !(FounderMail.mailAppName(for: url) ?? "").isEmpty && !(FounderMail.mailAppName(for: url) ?? "").hasSuffix(".app"),
                FounderMail.mailAppName(for: url) ?? "none")

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.yummyorange.app.menubar-test.\(getpid())"))
        defer { pasteboard.releaseGlobally() }
        var opened: [URL] = [], told: [String] = [], asked: [String?] = []
        func contact(_ choice: FounderMail.Choice, mailApp: String? = "Mail", opens: Bool = true) {
            pasteboard.clearContents()
            pasteboard.setString("before", forType: .string)
            opened = []; told = []; asked = []
            FounderMail.contact(url: url, mailApp: mailApp, findMailApp: false, ask: { asked.append($0); return choice },
                                open: { opened.append($0); return opens }, pasteboard: pasteboard, tell: { told.append($0) })
        }
        contact(.write)
        c.check("Write in Mail: the new email opens in the mail app the panel named, and the clipboard is left alone",
                asked == ["Mail"] && opened == [url] && told.isEmpty && pasteboard.string(forType: .string) == "before")
        contact(.copy)
        c.check("Copy Address: the address is on the clipboard, the progress panel (and VoiceOver) says so, nothing opens",
                opened.isEmpty && pasteboard.string(forType: .string) == FounderMail.address && told == ["Copied ali@yummyorange.com."], "\(told)")
        contact(.cancel)
        c.check("Cancel: nothing opens, nothing is copied", opened.isEmpty && told.isEmpty && pasteboard.string(forType: .string) == "before")
        contact(.write, opens: false)
        c.check("…and when the mail app can’t start the email, the address is copied instead, and the panel says why",
                pasteboard.string(forType: .string) == FounderMail.address && told == ["Copied ali@yummyorange.com. Mail couldn’t start a new email."],
                "\(told)")
        contact(.copy, mailApp: nil)
        c.check("with no app for mail links, the panel is asked without one, and Copy Address works", asked == [nil]
                && pasteboard.string(forType: .string) == FounderMail.address)
        c.check("this copy’s link has its own version and macOS", FounderMail.currentURL.absoluteString.hasPrefix("mailto:ali@yummyorange.com?subject=About%20YummyOrange&body=")
                && FounderMail.currentURL.absoluteString.contains("macOS%20\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)."))
    }

    // MARK: The update dot

    /// The icon drawn at 2× into a bitmap of its own.
    static func pixels(_ image: NSImage) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(x: 0, y: 0, width: 18, height: 18))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Opacity at a point of the 18 pt icon (y up, as it is drawn).
    static func alpha(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> CGFloat {
        rep.colorAt(x: Int(x * 2), y: 35 - Int(y * 2))?.alphaComponent ?? 0
    }

    static func icon(_ c: Checker) {
        let plain = MenuBarIcon.image(), badged = MenuBarIcon.image(badged: true)
        c.check("the badged icon is still an 18 pt template image (macOS tints the dot with the rest), and says so to VoiceOver",
                badged.isTemplate && badged.size == NSSize(width: 18, height: 18) && badged.accessibilityDescription == "YummyOrange, update available"
                && plain.accessibilityDescription == "YummyOrange")
        guard let p = pixels(plain), let b = pixels(badged) else { c.check("the icon draws", false); return }
        let dot = MenuBarIcon.badgeCenter
        let ring = CGPoint(x: dot.x - 1.95, y: dot.y + 1.95)   // between the dot and the petals, on a petal of the plain icon
        c.check("the dot sits in the bottom-right corner, solid", dot == CGPoint(x: 15.75, y: 2.25) && alpha(b, dot.x, dot.y) > 0.9
                && alpha(p, dot.x, dot.y) < 0.05)
        c.check("a clear ring cuts it free of the petals", alpha(p, ring.x, ring.y) > 0.3 && alpha(b, ring.x, ring.y) < 0.05,
                String(format: "plain %.2f, badged %.2f", alpha(p, ring.x, ring.y), alpha(b, ring.x, ring.y)))
        var changed = 0
        let reach = (MenuBarIcon.badgeRadius + MenuBarIcon.badgeRing + 0.75) * 2
        for x in 0..<36 {
            for y in 0..<36 {
                let px = CGFloat(x) + 0.5, py = CGFloat(35 - y) + 0.5
                guard hypot(px - dot.x * 2, py - dot.y * 2) > reach else { continue }
                if abs((p.colorAt(x: x, y: y)?.alphaComponent ?? 0) - (b.colorAt(x: x, y: y)?.alphaComponent ?? 0)) > 0.01 { changed += 1 }
            }
        }
        c.check("everywhere else the icon is exactly the plain one (the lifted top-right petal untouched)", changed == 0, "\(changed) pixels differ")
        let updater = UpdaterTests.idleUpdater()
        let none = AppDelegate.statusIcon(for: updater)
        updater.latest = UpdaterTests.item(version: "1.0.1", build: "2")
        let known = AppDelegate.statusIcon(for: updater)
        UpdatePreferences.skippedBuild = "2"
        let skipped = AppDelegate.statusIcon(for: updater)
        UpdatePreferences.skippedBuild = nil
        UpdatePreferences.snoozedBuild = "2"
        UpdatePreferences.snoozedUntil = Date().addingTimeInterval(3600)
        let snoozed = AppDelegate.statusIcon(for: updater)
        c.check("the menu-bar icon has the dot while the menu offers an update (also during Remind Me Later), not after Skip This Version",
                none.accessibilityDescription == "YummyOrange" && known.accessibilityDescription == "YummyOrange, update available"
                && skipped.accessibilityDescription == "YummyOrange" && snoozed.accessibilityDescription == "YummyOrange, update available")
        Settings.defaults = SettingsMemoryStore()
    }

    // MARK: Settings: General's Updates row, About's Questions or ideas

    /// The SwiftUI buttons in a hosted view (AppKit controls of SwiftUI's own, not NSButtons; pop-ups and a switch's
    /// label left out), with whether each is available, and the text fields' strings.
    static func controls(_ view: NSView) -> (enabled: [Bool], texts: [String]) {
        var enabled: [Bool] = [], texts: [String] = []
        func walk(_ v: NSView) {
            if !(v is NSPopUpButton), !(v is NSTextField), String(describing: type(of: v)).contains("Button"), let control = v as? NSControl {
                enabled.append(control.isEnabled)
            }
            if let field = v as? NSTextField { texts.append(field.stringValue) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return (enabled, texts)
    }

    static func about(_ c: Checker) {
        // Settings › General: Check for updates automatically, and right under it the Updates row with its button.
        let general = AppShellTests.hosted(SettingsSectionView(section: .general, snapshot: true))
        let generalControls = controls(general.host)
        general.window.contentView = nil
        c.check("General has the Updates button under Check for updates automatically (dimmed in a copy that can’t update, like this one)",
                generalControls.enabled == [Updater.shared.isAvailable], "\(generalControls.enabled)")

        let updater = UpdaterTests.idleUpdater()
        func row() -> [Bool] {
            let hosted = AppShellTests.hosted(Form { UpdatesRow(updater: updater) }.formStyle(.grouped).frame(width: 520))
            defer { hosted.window.contentView = nil }
            return controls(hosted.host).enabled
        }
        let none = row()
        updater.latest = UpdaterTests.item(version: "1.0.1", build: "2")
        let known = row()
        c.check("the Updates row: Check for Updates… (dimmed where this copy can’t check); once an update is known, Update to YummyOrange 1.0.1…, available",
                none == [false] && known == [true], "\(none) → \(known)")
        updater.latest = nil

        let hosted = AppShellTests.hosted(SettingsSectionView(section: .about, snapshot: true))
        let aboutControls = controls(hosted.host)
        hosted.window.contentView = nil
        c.check("About has one button now, Talk to the Founder… (the update check moved to General, beside its setting)",
                aboutControls.enabled == [true], "\(aboutControls.enabled)")
        c.check("…with the address to write to, selectable for webmail", aboutControls.texts.contains { $0.contains(FounderMail.address) },
                "\(aboutControls.texts)")
        c.check("the Updates row says why this copy can’t update", UpdateSetting.status(Updater.shared) == Updater.shared.environment.unavailableReason
                || Updater.shared.isAvailable)
    }
}
#endif
