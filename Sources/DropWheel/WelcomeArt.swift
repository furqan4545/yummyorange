import AppKit
import SwiftUI

// Drawings for the welcome tour. Sizes are design points of the 875 × 565 canvas.

// MARK: - Hand-written notes

/// Coach text in the accent colour, rounded semibold, as if written by hand.
struct WelcomeHandText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .foregroundStyle(DWPalette.color(DWPalette.accentOnBackground))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A hand-drawn arrow: one quadratic curve and an uneven two-stroke head. Points are absolute canvas points.
struct WelcomeHandArrow: Shape {
    let start: CGPoint
    let control: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: start)
        p.addQuadCurve(to: end, control: control)
        let theta = atan2(end.y - control.y, end.x - control.x)
        p.move(to: end)
        p.addLine(to: CGPoint(x: end.x + 13 * cos(theta + .pi - 0.5), y: end.y + 13 * sin(theta + .pi - 0.5)))
        p.move(to: end)
        p.addLine(to: CGPoint(x: end.x + 11 * cos(theta + .pi + 0.55), y: end.y + 11 * sin(theta + .pi + 0.55)))
        return p
    }
}

/// A note with an arrow that draws itself on: easeOut 0.45 s after 0.1 s, once per appearance.
struct WelcomeHandNote: View {
    let text: String
    let detail: String?
    let at: CGPoint
    let from: CGPoint
    let control: CGPoint
    let to: CGPoint
    var animated = true

    @WelcomeState private var drawn: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            WelcomeHandArrow(start: from, control: control, end: to)
                .trim(from: 0, to: animated ? drawn : 1)
                .stroke(DWPalette.color(DWPalette.accentOnBackground),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, miterLimit: 10))
                .accessibilityHidden(true)
            VStack(alignment: .center, spacing: 6) {
                WelcomeHandText(text: text)
                if let detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 230)
            .position(at)
        }
        .frame(width: 875, height: 565, alignment: .topLeading)
        .allowsHitTesting(false)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeOut(duration: 0.45).delay(0.1)) { drawn = 1 }
        }
    }
}

// MARK: - Keys

/// One key cap: a face with a hairline, the glyph top-right, the name bottom-left, and a 2 pt side below.
/// `accent` caps are the brand colour; others are near-black like a Mac keyboard.
struct WelcomeKeyboardKey: View {
    let symbol: String?
    let name: String
    let width: CGFloat
    var accent = false

    var body: some View {
        let face = accent ? [DWPalette.accentLight, DWPalette.accent] : [DWPalette.keyFaceTop, DWPalette.keyFaceBottom]
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: face.map(DWPalette.color), startPoint: .top, endPoint: .bottom))
            .frame(width: width, height: 54)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.7))
            .overlay(alignment: .topTrailing) {
                if let symbol {
                    Text(symbol)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.95))
                        .padding(.top, 5)
                        .padding(.trailing, 7)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(name)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .padding(.leading, 6)
                    .padding(.bottom, 5)
            }
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DWPalette.color(accent ? DWPalette.accentDeep : DWPalette.keySide))
                    .offset(x: 0, y: 2)
            }
            .shadow(color: Color.black.opacity(0.18), radius: 1, x: 0, y: 2)
    }
}

/// The keys that open a wheel, two to a row with "+" between them. Raised keys sit 6 pt above a well and sink
/// 5 pt into it while `pressed`.
struct WelcomeShortcutKeys: View {
    let keys: [WheelKey]
    var raised = false
    var pressed = false

    var body: some View {
        let rows = stride(from: 0, to: keys.count, by: 2).map { Array(keys[$0..<min($0 + 2, keys.count)]) }
        VStack(alignment: .leading, spacing: 7) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(alignment: .center, spacing: 4) {
                    ForEach(rows[r].indices, id: \.self) { i in
                        if i > 0 {
                            Text("+").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        cap(rows[r][i])
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func cap(_ key: WheelKey) -> some View {
        let c = WelcomeKeys.cap(key)
        return WelcomeKeyboardKey(symbol: c.symbol, name: c.name, width: c.width, accent: raised)
            .offset(x: 0, y: raised && pressed ? 5 : 0)
            .background(alignment: .top) {
                if raised {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(DWPalette.color(DWPalette.accentDeep))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.7))
                        .offset(x: 0, y: 6)
                }
            }
            .padding(.bottom, raised ? 6 : 0)
    }
}

// MARK: - Files

/// The sample photo as a Finder icon: rounded, with a hairline border.
struct WelcomeDemoThumbnail: View {
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size / 7, style: .continuous)
        Image(nsImage: WelcomeSample.image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .background(shape.fill(Color.primary.opacity(0.06)))
    }
}

/// A file: thumbnail and name. A new file's name sits on an accent capsule, like a freshly made file in Finder.
struct WelcomeDemoFile: View {
    let name: String
    let size: CGFloat
    let isNew: Bool

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            WelcomeDemoThumbnail(size: size)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isNew ? Color.white : Color.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(isNew ? DWPalette.color(DWPalette.accent) : Color.clear, in: Capsule(style: .continuous))
        }
    }
}

// MARK: - Where results go

/// A folder with its tab on the right, in a unit square (YummyOrange's own outline).
struct WelcomeFolderBack: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }
        var path = Path()
        path.move(to: p(0.10, 0.14))
        path.addLine(to: p(0.54, 0.14))
        path.addCurve(to: p(0.64, 0.02), control1: p(0.59, 0.14), control2: p(0.59, 0.02))
        path.addLine(to: p(0.90, 0.02))
        path.addQuadCurve(to: p(1.00, 0.12), control: p(1.00, 0.02))
        path.addLine(to: p(1.00, 0.88))
        path.addQuadCurve(to: p(0.90, 1.00), control: p(1.00, 1.00))
        path.addLine(to: p(0.10, 1.00))
        path.addQuadCurve(to: p(0.00, 0.88), control: p(0.00, 1.00))
        path.addLine(to: p(0.00, 0.24))
        path.addQuadCurve(to: p(0.10, 0.14), control: p(0.00, 0.14))
        path.closeSubpath()
        return path
    }
}

/// The original and its new copy side by side in one folder: results are saved next to the file you drop.
struct WelcomeSavedIllustration: View {
    var body: some View {
        let accent = DWPalette.color(DWPalette.accent)
        let top = DWPalette.color(DWPalette.folderTop)
        ZStack {
            WelcomeFolderBack()
                .fill(LinearGradient(colors: [top.opacity(0.75), accent.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                .frame(width: 182, height: 142)
                .position(x: 115, y: 86)
            sheet(isNew: false).rotationEffect(.degrees(-7)).position(x: 82, y: 58)
            sheet(isNew: true).rotationEffect(.degrees(6)).position(x: 148, y: 56)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [top, accent], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 0.7))
                .frame(width: 182, height: 96)
                .shadow(color: accent.opacity(0.18), radius: 12, x: 0, y: 8)
                .position(x: 115, y: 109)
            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.2))
                .position(x: 115, y: 113)
        }
        .frame(width: 230, height: 176)
        .accessibilityHidden(true)
    }

    /// A paper sheet with the photo; the new copy wears an accent corner.
    private func sheet(isNew: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white)
            .frame(width: 62, height: 76)
            .overlay(alignment: .top) {
                Image(nsImage: WelcomeSample.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(.top, 5)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(Color.black.opacity(0.14)).frame(width: 34, height: 3)
                    Capsule().fill(isNew ? DWPalette.color(DWPalette.accent) : Color.black.opacity(0.10)).frame(width: 22, height: 3)
                }
                .padding(.leading, 6)
                .padding(.bottom, 8)
            }
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1)
    }
}

// MARK: - Menu bar

/// A slice of menu bar with YummyOrange's icon picked out and an arrow pointing at it.
struct WelcomeMenuBarPill: View {
    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: "wifi")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)
            Image(systemName: "circle.dotted.circle")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(.primary)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.12)))
                .overlay {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 20, height: 18)
                        .offset(x: 0, y: 28)
                }
            Text("9:41")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WelcomeCopy.menuBarHint)
    }
}

// MARK: - Wheels

/// The real wheel view (and its glass disc) for the tour: a still preview that can turn, or the practice wheel
/// the demo highlights. It never takes clicks or drops, and its petals do nothing.
final class WelcomeWheelHost: NSView {
    let wheel = WheelView(frame: .zero)
    private let live: Bool
    private(set) var mode: WheelMode?
    private var rotationTarget: CGFloat = 0

    init(size: CGFloat, practice: Bool, live: Bool) {
        self.live = live
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        wheel.frame = bounds
        wheel.autoresizingMask = [.width, .height]
        wheel.playsFeedback = false
        wheel.unregisterDraggedTypes()
        addSubview(wheel)
        wheel.playsFeedback = practice && live
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The live practice wheel keeps the sound engine running while it is on screen.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && wheel.playsFeedback {
            PetalSound.shared.hold(self, start: Settings.petalSounds)
        } else {
            PetalSound.shared.release(self)
        }
    }

    func configure(mode: WheelMode, items: [WheelItem]) {
        let style = Settings.wheelStyle
        guard mode != self.mode || style != wheel.style else { return }
        let feedback = wheel.playsFeedback
        wheel.playsFeedback = false
        self.mode = mode
        wheel.style = style
        wheel.modeTitle = mode.rawValue
        wheel.items = items
        wheel.playsFeedback = feedback
    }

    func setHighlight(_ index: Int?) { wheel.setHighlight(index) }

    /// The petal under a point given in canvas points, for a wheel of `size` drawn centred on `center`.
    func petal(atCanvas p: CGPoint, center: CGPoint, size: CGFloat) -> Int? {
        let b = bounds.width > 0 ? bounds : CGRect(x: 0, y: 0, width: size, height: size)
        let x = (p.x - (center.x - size / 2)) / size * b.width
        let y = (1 - (p.y - (center.y - size / 2)) / size) * b.height
        return wheel.index(at: convert(CGPoint(x: x, y: y), to: wheel))
    }

    /// Turns the wheel clockwise by `degrees`, animated (ease in-out) when `duration` > 0.
    func setRotation(degrees: Double, duration: Double) {
        let target = CGFloat(-degrees)
        guard target != rotationTarget else { return }
        rotationTarget = target
        if duration > 0 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                wheel.animator().frameCenterRotation = target
            }
        } else {
            wheel.frameCenterRotation = target
        }
    }

    /// Diameter of the glass disc for a wheel of `count` petals drawn `size` points wide.
    static func backdropDiameter(count: Int, size: CGFloat) -> CGFloat {
        WheelLayout(count: count, bounds: CGRect(x: 0, y: 0, width: size, height: size)).backdropRadius * 2
    }
}

/// Liquid Glass disc for the tour's wheels (macOS 26+). Nothing on earlier systems, offscreen, or for metallic wheels:
/// there the wheel paints its own disc.
struct WelcomeWheelGlass: View {
    let diameter: CGFloat
    let live: Bool

    static func isLive(_ live: Bool) -> Bool {
        guard live else { return false }
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var body: some View {
        if Self.isLive(live), Settings.wheelStyle == .glass {
            if #available(macOS 26.0, *) {
                Color.clear
                    .frame(width: diameter, height: diameter)
                    .glassEffect(.regular, in: Circle())
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The wheel on the convert, tools and actions pages. SwiftUI never animates it: it turns itself.
struct WelcomeWheelPreview: NSViewRepresentable {
    let mode: WheelMode
    /// Degrees, positive is clockwise.
    let rotation: Double
    let duration: Double
    let live: Bool

    func makeNSView(context: Context) -> WelcomeWheelHost {
        let host = WelcomeWheelHost(size: 360, practice: false, live: live)
        host.configure(mode: mode, items: WelcomeSample.items(for: mode))
        host.setRotation(degrees: rotation, duration: 0)
        return host
    }

    func updateNSView(_ host: WelcomeWheelHost, context: Context) {
        host.configure(mode: mode, items: WelcomeSample.items(for: mode))
        host.setRotation(degrees: rotation, duration: live ? duration : 0)
    }
}

/// The demo's practice wheel: the model's wheel host, shown while the wheel is open.
struct WelcomePracticeWheel: NSViewRepresentable {
    let host: WelcomeWheelHost

    func makeNSView(context: Context) -> WelcomeWheelHost { host }
    func updateNSView(_ nsView: WelcomeWheelHost, context: Context) {}
}
