import AppKit

/// The menu-bar icon: the app icon's wheel in miniature (six petals, the chosen one lifted out), drawn in code as a
/// template image so macOS tints it for light and dark menu bars and for a selected status item (HIG Menu bar extras:
/// a template image, about 16 pt of content in an 18 pt square).
enum MenuBarIcon: FeatureModule {
    static var commands: [WheelCommand] { [] }

    static let size: CGFloat = 18
    /// The resting petals are drawn at this opacity; the lifted petal and the hub are solid.
    static let restingAlpha: CGFloat = 0.62

    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "YummyOrange"
        return image
    }

    /// Draws into the current context, in an 18 × 18 point square (y up).
    static func draw() {
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
        ctx.setFillColor(NSColor.black.withAlphaComponent(restingAlpha).cgColor)
        for i in 0..<count where i != 1 { ctx.addPath(petal(i)); ctx.fillPath() }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(petal(1, push: push)); ctx.fillPath()
        let hub: CGFloat = inner - gap * 0.9
        ctx.fillEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: 2 * hub, height: 2 * hub))
    }

    /// `--snapshot menubar-icon <out.png>`: the icon at its real size and 6×, on a light and a dark menu bar.
    static func snapshot(_ id: String, files: [URL], options: ToolOptions) -> NSView? {
        guard id == "menubar-icon" else { return nil }
        return MenuBarIconPreview()
    }
}

/// The icon tinted as macOS tints a template image, on a light and a dark menu bar, at 1× size and enlarged.
private final class MenuBarIconPreview: NSView {
    init() { super.init(frame: CGRect(x: 0, y: 0, width: 360, height: 180)) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let icon = MenuBarIcon.image()
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
