import AppKit

/// The menu-bar icon: the app icon's wheel in miniature (six petals, the chosen one lifted out), drawn in code as a
/// template image so macOS tints it for light and dark menu bars and for a selected status item (HIG Menu bar extras:
/// a template image, about 16 pt of content in an 18 pt square). While an update is known it carries a dot in the
/// bottom-right corner, cut free of the petals like the badges of SF Symbols (folder.badge.plus): the same template
/// ink, never a red or numbered badge, and never the only sign (the menu and the update notice say it too).
enum MenuBarIcon: FeatureModule {
    static var commands: [WheelCommand] { [] }

    static let size: CGFloat = 18
    /// The resting petals are drawn at this opacity; the lifted petal and the hub are solid.
    static let restingAlpha: CGFloat = 0.62
    /// The update dot and the clear ring around it. Bottom-right, away from the lifted top-right petal that makes the
    /// icon recognizable.
    static let badgeRadius: CGFloat = 2.25, badgeRing: CGFloat = 1
    static var badgeCenter: CGPoint { CGPoint(x: size - badgeRadius, y: badgeRadius) }

    static func image(badged: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            draw(badged: badged)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription(badged: badged)
        return image
    }

    static func accessibilityDescription(badged: Bool) -> String { badged ? "YummyOrange, update available" : "YummyOrange" }

    /// Draws into the current context, in an 18 × 18 point square (y up).
    static func draw(badged: Bool = false) {
        let center = CGPoint(x: size / 2, y: size / 2)
        let count = 6, sector = 2 * CGFloat.pi / CGFloat(count)
        let inner: CGFloat = 3.1, outer: CGFloat = 7.5, gap: CGFloat = 1.05, corner: CGFloat = 1.6, push: CGFloat = 1.25
        func angle(_ i: Int) -> CGFloat { .pi / 2 - CGFloat(i) * sector }
        func petal(_ i: Int, push p: CGFloat = 0) -> CGPath {
            let a = angle(i)
            let c = CGPoint(x: center.x + p * cos(a), y: center.y + p * sin(a))
            return WheelGeometry.petalPath(center: c, centerAngle: a, sector: sector, gap: gap, inner: inner, outer: outer, cornerEdge: corner)
        }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = badgeCenter, r = badgeRadius, cut = badgeRadius + badgeRing
        ctx.saveGState()
        if badged {
            // The petals stop a ring short of the dot (a clip, not a clear: this may draw straight onto the button).
            ctx.addRect(CGRect(x: 0, y: 0, width: size, height: size))
            ctx.addEllipse(in: CGRect(x: c.x - cut, y: c.y - cut, width: 2 * cut, height: 2 * cut))
            ctx.clip(using: .evenOdd)
        }
        ctx.setFillColor(NSColor.black.withAlphaComponent(restingAlpha).cgColor)
        for i in 0..<count where i != 1 { ctx.addPath(petal(i)); ctx.fillPath() }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(petal(1, push: push)); ctx.fillPath()
        let hub: CGFloat = inner - gap * 0.9
        ctx.fillEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: 2 * hub, height: 2 * hub))
        ctx.restoreGState()
        guard badged else { return }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    /// `--snapshot menubar-icon <out.png> [--opt badge=on]`: the icon at its real size and 4×, on a light and a dark
    /// menu bar; with the update dot for badge=on. `--snapshot founder-panel [--opt mail=off]`: Talk to the Founder…'s
    /// panel (without a mail app for mail=off). `--snapshot update-alert [--opt unprompted=on]`: the update alert.
    static func snapshot(_ id: String, files: [URL], options: ToolOptions) -> NSView? {
        switch id {
        case "menubar-icon": return MenuBarIconPreview(badged: options.bool("badge", false))
        case "founder-panel": return alertView(FounderMail.panel(mailApp: options.bool("mail", true) ? "Mail" : nil))
        case "update-alert":
            let item = UpdateItem(version: "1.0.1", build: "2", minimumSystemVersion: "13.0",
                                  url: URL(string: "https://yummyorange.com/downloads/YummyOrange-1.0.1.zip")!, length: 1, sha256: "",
                                  signature: Data(), releaseNotesURL: URL(string: "https://yummyorange.com/release-notes.html"),
                                  releaseNotes: "A sample of the release notes, as the feed gives them.", published: nil)
            return alertView(SystemUpdateUI.offerAlert(item, current: "1.0.0", unprompted: options.bool("unprompted", false)))
        default: return nil
        }
    }

    /// An alert's content, laid out as it shows (for a snapshot).
    private static func alertView(_ alert: NSAlert) -> NSView? {
        alert.layout()
        guard let content = alert.window.contentView else { return nil }
        content.removeFromSuperview()
        return content
    }

    static func selfTest(_ name: String) -> String? {
        #if DEBUG
        switch name {
        case "menubar": return MenuBarTests.run()
        case "menu-latency": return MenuLatencyTests.run()
        default: return nil
        }
        #else
        return nil
        #endif
    }
}

/// The icon tinted as macOS tints a template image, on a light and a dark menu bar, at 1× size and enlarged.
private final class MenuBarIconPreview: NSView {
    private let badged: Bool

    init(badged: Bool) {
        self.badged = badged
        super.init(frame: CGRect(x: 0, y: 0, width: 360, height: 180))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let icon = MenuBarIcon.image(badged: badged)
        for (row, dark) in [false, true].enumerated() {
            let band = CGRect(x: 0, y: CGFloat(1 - row) * 90, width: bounds.width, height: 90)
            (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            band.fill()
            let tint = dark ? NSColor.white : NSColor.black
            for (i, scale) in [CGFloat(1), 4].enumerated() {
                let s = MenuBarIcon.size * scale
                let rect = CGRect(x: 24 + CGFloat(i) * 60, y: band.midY - s / 2, width: s, height: s)
                let tinted = NSImage(size: rect.size, flipped: false) { r in
                    icon.draw(in: r)
                    tint.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: rect)
            }
        }
    }
}
