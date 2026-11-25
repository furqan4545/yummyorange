import AppKit

/// Talk to the Founder…: a small panel with the address of Ali, who makes YummyOrange, as selectable text, and two ways
/// to write: Write in Mail (a new email in the app that opens mail links, with the version filled in) or Copy Address
/// (for webmail; the app that was in front gets the keyboard back, ready to paste). Mail.app opens mail links on every
/// Mac, even one whose Mail has no account, so opening a new email straight away left webmail users in Mail's account
/// setup. The message says nothing about the Mac beyond the macOS version, and nothing is sent: the person writes and
/// sends it. In the menu-bar menu and in Settings › About. `--selftest menubar` checks the link and the panel.
enum FounderMail {
    static let address = "ali@yummyorange.com"
    static let title = "Talk to the Founder…"
    static let toolTip = "Shows \(address), the address of Ali, who makes YummyOrange, to write from your mail app or to copy."
    /// What the email is about, which the sender can change; the version is in the footer.
    static let subject = "About YummyOrange"

    /// "YummyOrange 1.0.0 (build 1)", or "YummyOrange (development build)" when not run as an app.
    static func versionLine(version: String?, build: String?) -> String {
        guard let version else { return "YummyOrange (development build)" }
        return build.map { "YummyOrange \(version) (build \($0))" } ?? "YummyOrange \(version)"
    }

    /// A greeting, room to write, and the two facts that help with an answer: the version and the macOS version. Mail
    /// links end lines with CR LF.
    static func body(version: String?, build: String?, system: OperatingSystemVersion) -> String {
        ["Hi Ali,", "", "", "", "--", versionLine(version: version, build: build), "macOS \(UpdateVersion.string(system))", ""]
            .joined(separator: "\r\n")
    }

    /// mailto:ali@yummyorange.com?subject=…&body=…, with everything but RFC 3986's unreserved characters
    /// percent-encoded (URLComponents leaves "&", "=" and "+" alone in a query, and some mail apps read "+" as a space).
    static func url(version: String?, build: String?, system: OperatingSystemVersion) -> URL {
        let body = encode(body(version: version, build: build, system: system))
        return URL(string: "mailto:\(address)?subject=\(encode(subject))&body=\(body)")!
    }

    static func encode(_ text: String) -> String {
        var unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        unreserved.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// The link for this copy of YummyOrange and this Mac.
    static var currentURL: URL {
        let info = Bundle.main.infoDictionary
        return url(version: info?["CFBundleShortVersionString"] as? String, build: info?["CFBundleVersion"] as? String,
                   system: ProcessInfo.processInfo.operatingSystemVersion)
    }

    /// The name of the app that opens mail links ("Mail", "Spark"), nil when none does.
    static func mailAppName(for url: URL = currentURL) -> String? {
        NSWorkspace.shared.urlForApplication(toOpen: url).map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
    }

    enum Choice { case write, copy, cancel }

    static func writeTitle(_ mailApp: String) -> String { "Write in \(mailApp)" }
    static let copyTitle = "Copy Address"
    static func copied() -> String { "Copied \(address)." }
    static func notOpened(_ mailApp: String) -> String { "Copied \(address). \(mailApp) couldn’t start a new email." }

    /// The panel: the address as selectable text; Write in Mail (Return) when an app opens mail links, Copy Address,
    /// and Cancel (Esc). The person asked for it, so Return may write (HIG Alerts: the likeliest choice is the
    /// default when it isn't destructive).
    static func panel(mailApp: String?) -> NSAlert {
        let alert = NSAlert()
        // A complete sentence: sentence-style, with its period (HIG Alerts › Content).
        alert.messageText = "Write to Ali, who makes YummyOrange."
        alert.informativeText = "Send questions, ideas, or anything that isn’t working to this address."
        if let mailApp { alert.addButton(withTitle: writeTitle(mailApp)) }
        alert.addButton(withTitle: copyTitle)
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let field = NSTextField(labelWithString: address)
        field.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .medium)
        field.isSelectable = true
        field.setAccessibilityLabel("Email address")
        field.sizeToFit()
        field.frame.size.width = max(field.frame.width, 240)
        alert.accessoryView = field
        return alert
    }

    /// Shows the panel and gives the choice. After Copy Address or Cancel, the app that was in front (a browser with
    /// webmail, say) gets the keyboard back.
    static func runPanel(mailApp: String?) -> Choice {
        let alert = panel(mailApp: mailApp)
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let choice: Choice
        switch (response, mailApp != nil) {
        case (.alertFirstButtonReturn, true): choice = .write
        case (.alertFirstButtonReturn, false), (.alertSecondButtonReturn, true): choice = .copy
        default: choice = .cancel
        }
        if choice != .write, let previous, previous != NSRunningApplication.current { previous.activate(options: []) }
        return choice
    }

    /// The progress panel's message, also read out by VoiceOver.
    static func announce(_ text: String) {
        HUD.shared.flash(text, always: true, seconds: 4)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Talk to the Founder…: the panel, then the new email, or the address on `pasteboard` (also when the mail app
    /// can't start the email), said with `tell`. Self-tests pass their own `ask`, `open`, pasteboard and `tell`.
    static func contact(url: URL = currentURL,
                        mailApp: String? = nil,
                        findMailApp: Bool = true,
                        ask: (String?) -> Choice = { runPanel(mailApp: $0) },
                        open: (URL) -> Bool = { NSWorkspace.shared.open($0) },
                        pasteboard: NSPasteboard = .general,
                        tell: (String) -> Void = { announce($0) }) {
        let app = mailApp ?? (findMailApp ? mailAppName(for: url) : nil)
        func copy(_ message: String) {
            pasteboard.clearContents()
            pasteboard.setString(address, forType: .string)
            tell(message)
        }
        switch ask(app) {
        case .write:
            if open(url) { return }
            copy(notOpened(app ?? "The mail app"))
        case .copy: copy(copied())
        case .cancel: break
        }
    }

    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(FounderMailTarget.contact), keyEquivalent: "")
        item.target = FounderMailTarget.shared
        item.toolTip = toolTip
        return item
    }
}

/// The menu item's target (menu items hold their target weakly, so it lives here for good).
final class FounderMailTarget: NSObject {
    static let shared = FounderMailTarget()

    @objc func contact() { FounderMail.contact() }
}
