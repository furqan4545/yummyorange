import AppKit
import ServiceManagement
import SwiftUI

// The tour window's SwiftUI content. Everything is laid out on an 875 × 565 design canvas, clipped to a continuous
// capsule and shown at 0.8 scale in the 700 × 452 window.

/// View-local state, like SwiftUI's `@State`. (With this SDK `@State` resolves to a macro whose compiler plugin the
/// command-line tools don't ship, so the tour wraps `State` itself.)
@propertyWrapper
struct WelcomeState<Value>: DynamicProperty {
    private let storage: State<Value>

    init(wrappedValue: Value) { storage = State(initialValue: wrappedValue) }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}

// MARK: - Page transition

/// The page change, as numbers: a 0.22 s dip to the window colour while the old page drifts 6 pt (and a wheel
/// turns 6°), a swap 12 pt (and 10°) the other way under the veil, 34 ms, then 0.32 s back to rest.
/// Reduce Motion keeps only the veil, faster (0.14 s / 0.18 s).
struct WelcomeTransition: Equatable {
    struct Phase: Equatable {
        var duration: Double
        var veil: Double
        var offset: CGFloat
        var rotation: Double
        var rotationDuration: Double
    }

    var out: Phase
    /// Values set instantly when the new page swaps in.
    var swap: Phase
    var pause: Double
    var into: Phase

    static func between(_ old: WelcomePage, _ new: WelcomePage, reduceMotion rm: Bool) -> WelcomeTransition {
        let backward = new.rawValue < old.rawValue
        let outDuration = rm ? 0.14 : 0.22, inDuration = rm ? 0.18 : 0.32
        return WelcomeTransition(
            out: Phase(duration: outDuration, veil: 1, offset: rm ? 0 : (backward ? 6 : -6),
                       rotation: !rm && old.isWheelPage ? (backward ? -6 : 6) : 0, rotationDuration: rm ? 0 : outDuration),
            swap: Phase(duration: 0, veil: 1, offset: rm ? 0 : (backward ? -12 : 12),
                        rotation: !rm && new.isWheelPage ? (backward ? 10 : -10) : 0, rotationDuration: 0),
            pause: 0.034,
            into: Phase(duration: inDuration, veil: 0, offset: 0, rotation: 0, rotationDuration: rm ? 0 : inDuration))
    }
}

// MARK: - Root

struct WelcomeRootView: View {
    @ObservedObject var model: WelcomeModel

    @WelcomeState private var displayedPage: WelcomePage
    @WelcomeState private var veilOpacity: Double = 0
    @WelcomeState private var pageOffset: CGFloat = 0
    @WelcomeState private var wheelRotation: Double = 0
    @WelcomeState private var wheelRotationDuration: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: WelcomeModel) {
        self.model = model
        _displayedPage = WelcomeState(wrappedValue: model.page)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if displayedPage == .welcome {
                WelcomeGlowBackground()
            }
            pageContent(displayedPage)
                .frame(width: 875, height: 565, alignment: .topLeading)
                .id(displayedPage)
                .offset(x: 0, y: displayedPage.isWheelPage ? 0 : pageOffset)
                .allowsHitTesting(!model.isChangingPage)
            Color(nsColor: .textBackgroundColor)
                .opacity(veilOpacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            WelcomeWindowDragArea()
                .frame(width: 480, height: 88)
                .accessibilityHidden(true)
            WelcomeWindowControls(onClose: { model.dismiss() })
                .frame(width: 875, height: 104)
            if displayedPage != .welcome {
                WelcomePageIndicator(page: displayedPage)
            }
        }
        .foregroundStyle(.primary)
        .frame(width: 875, height: 565)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(Capsule(style: .continuous))
        .scaleEffect(0.8, anchor: .topLeading)
        .frame(width: 700, height: 452, alignment: .topLeading)
        .ignoresSafeArea()
        .task(id: model.page, priority: .userInitiated) { await changePage(to: model.page) }
    }

    @ViewBuilder
    private func pageContent(_ page: WelcomePage) -> some View {
        switch page {
        case .welcome:
            WelcomeHelloPage(onNext: model.next)
        case .demo:
            WelcomeDemoPage(model: model.demo, live: model.live, onNext: model.next, onBack: model.back)
        case .convert, .tools, .actions:
            WelcomeWheelPage(wheel: page.wheel ?? .convert, rotation: wheelRotation, rotationDuration: wheelRotationDuration,
                             instructionsOffset: pageOffset, live: model.live, onNext: model.next, onBack: model.back)
        case .saved:
            WelcomeSidePage(page: page, onNext: model.next, onBack: model.back) { WelcomeSavedColumn() }
        case .setup:
            WelcomeSidePage(page: page, onNext: model.next, onBack: model.back) { WelcomeSetupColumn(model: model) }
        }
    }

    @MainActor
    private func changePage(to new: WelcomePage) async {
        guard new != displayedPage else {
            veilOpacity = 0
            pageOffset = 0
            wheelRotation = 0
            wheelRotationDuration = 0
            model.pageChangeFinished()
            return
        }
        let t = WelcomeTransition.between(displayedPage, new, reduceMotion: reduceMotion)
        model.isChangingPage = true
        await animate(t.out.duration) {
            veilOpacity = t.out.veil
            pageOffset = t.out.offset
            wheelRotation = t.out.rotation
            wheelRotationDuration = t.out.rotationDuration
        }
        if Task.isCancelled { return }
        var swap = Transaction(animation: nil)
        swap.disablesAnimations = true
        withTransaction(swap) {
            displayedPage = new
            pageOffset = t.swap.offset
            wheelRotation = t.swap.rotation
            wheelRotationDuration = 0
        }
        try? await Task.sleep(nanoseconds: UInt64(t.pause * 1_000_000_000))
        if Task.isCancelled { return }
        await animate(t.into.duration) {
            veilOpacity = 0
            pageOffset = 0
            wheelRotation = 0
            wheelRotationDuration = t.into.rotationDuration
        }
        model.pageChangeFinished()
    }

    /// Runs `body` with an ease-in-out animation and returns when it has finished.
    @MainActor
    private func animate(_ duration: Double, _ body: @escaping () -> Void) async {
        let animation = Animation.easeInOut(duration: duration)
        if #available(macOS 14.0, *) {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                withAnimation(animation, completionCriteria: .removed) { body() } completion: { done.resume() }
            }
        } else {
            withAnimation(animation) { body() }
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        }
    }
}

// MARK: - Background

/// The welcome page's background: the base colour with a large blurred circle of the glow colour at the bottom.
struct WelcomeGlowBackground: View {
    var body: some View {
        ZStack {
            DWPalette.color(DWPalette.base)
            Circle()
                .fill(DWPalette.color(DWPalette.glow))
                .frame(width: 638, height: 638)
                .blur(radius: 184)
                .position(x: 437.5, y: 548)
        }
        .frame(width: 875, height: 565)
        .accessibilityHidden(true)
    }
}

// MARK: - Window chrome

enum WelcomeChrome {
    /// Centres of the close, minimize and hollow dots: on rays from the left end's centre (282.5, 282.5) at −120°,
    /// −112° and −104°, 40 pt inside the continuous capsule's edge (found by bisection, once).
    static let dotCenters: [CGPoint] = {
        let outline = Capsule(style: .continuous).path(in: CGRect(origin: .zero, size: WelcomeTour.canvas)).cgPath
        let band = outline.copy(strokingWithWidth: 80, lineCap: .butt, lineJoin: .round, miterLimit: 0)
        let origin = CGPoint(x: 282.5, y: 282.5)
        return (0..<3).map { i in
            let a = (-120 + 8 * Double(i)) * Double.pi / 180
            func point(_ t: CGFloat) -> CGPoint { CGPoint(x: origin.x + CGFloat(cos(a)) * t, y: origin.y + CGFloat(sin(a)) * t) }
            var lo: CGFloat = 0, hi: CGFloat = 282.5
            for _ in 0..<40 {
                let t = (lo + hi) / 2
                if band.contains(point(t), using: .winding) { hi = t } else { lo = t }
            }
            return point((lo + hi) / 2)
        }
    }()
}

/// Close and minimize dots, and a hollow third that is only decoration (it takes no clicks and has no menu).
struct WelcomeWindowControls: View {
    let onClose: () -> Void

    var body: some View {
        let p = WelcomeChrome.dotCenters
        ZStack(alignment: .topLeading) {
            Button(action: onClose) { WelcomeWindowDot(color: DWPalette.closeDot) }
                .buttonStyle(.plain)
                .accessibilityLabel("Close welcome tour")
                .accessibilityIdentifier("welcomeClose")
                .position(p[0])
            Button { NSApp.keyWindow?.miniaturize(nil) } label: { WelcomeWindowDot(color: DWPalette.minimizeDot) }
                .buttonStyle(.plain)
                .accessibilityLabel("Minimize welcome tour")
                .accessibilityIdentifier("welcomeMinimize")
                .position(p[1])
            Circle()
                .fill(Color.primary.opacity(0.035))
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5))
                .position(p[2])
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// A 22 pt window dot that brightens while the pointer is over it.
struct WelcomeWindowDot: View {
    let color: NSColor
    @WelcomeState private var isHovering = false

    var body: some View {
        Circle()
            .fill(DWPalette.color(color))
            .frame(width: 22, height: 22)
            .overlay {
                Circle().fill(Color.white.opacity(isHovering ? 0.18 : 0))
                WelcomeWindowHoverArea(isHovering: $isHovering)
            }
            .contentShape(Circle())
    }
}

/// Tracks the pointer without taking clicks.
struct WelcomeWindowHoverArea: NSViewRepresentable {
    @Binding var isHovering: Bool

    func makeNSView(context: Context) -> HoverView {
        let view = HoverView()
        view.onChange = { isHovering = $0 }
        return view
    }

    func updateNSView(_ view: HoverView, context: Context) { view.onChange = { isHovering = $0 } }

    final class HoverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var area: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(a)
            area = a
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
    }
}

/// The band at the top left that moves the window (the window has no title bar).
struct WelcomeWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Only inside the window's stadium, so the clear corners stay click-through.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let window, let content = window.contentView, let superview else { return nil }
            let p = superview.convert(point, to: content)
            let b = content.bounds
            let shape = CGPath(roundedRect: b, cornerWidth: b.height * 0.5, cornerHeight: b.height * 0.5, transform: nil)
            guard shape.contains(p), frame.contains(point) else { return nil }
            return self
        }

        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func rightMouseDown(with event: NSEvent) {}
        override func menu(for event: NSEvent) -> NSMenu? { nil }
    }
}

/// Seven dots, the current one in the accent colour.
struct WelcomePageIndicator: View {
    let page: WelcomePage

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ForEach(WelcomePage.allCases, id: \.self) { p in
                Circle()
                    .fill(p == page ? DWPalette.color(DWPalette.accentOnBackground) : Color.primary.opacity(0.12))
                    .frame(width: 5, height: 5)
            }
        }
        .frame(width: 875, height: 12)
        .offset(x: 0, y: 523)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(page.number) of \(WelcomePage.allCases.count)")
    }
}

// MARK: - Buttons

/// The big capsule button: accent with white text, or white with black text (`inverted`) on the welcome page.
struct WelcomeContinueButton: View {
    let title: String
    var inverted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 19, weight: .medium))
                .frame(width: 169, height: 66)
                .foregroundStyle(inverted ? Color.black : Color.white)
                .background(inverted ? Color.white : DWPalette.color(DWPalette.button), in: Capsule(style: .continuous))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("welcomeContinue")
    }
}

struct WelcomeBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(WelcomeCopy.back, systemImage: "arrow.left") }
            .font(.system(size: 12))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("welcomeBack")
    }
}

// MARK: - Pages

struct WelcomeHelloPage: View {
    let onNext: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .center, spacing: -16) {
                Text(WelcomeCopy.helloLead)
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.49))
                    .frame(height: 50)
                Text(WelcomeCopy.appName)
                    .font(.system(size: 96, weight: .medium))
                    .foregroundStyle(LinearGradient(stops: [.init(color: .white.opacity(0.8), location: 0),
                                                            .init(color: .white.opacity(0.8), location: 0.1236),
                                                            .init(color: .white.opacity(0.33), location: 1)],
                                                    startPoint: .top, endPoint: .bottom))
                    .frame(height: 116)
            }
            .frame(width: 720)
            .position(x: 437.5, y: 267)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            WelcomeContinueButton(title: WelcomeCopy.start, inverted: true, action: onNext)
                .position(x: 437.5, y: 410)
        }
        .frame(width: 875, height: 565, alignment: .topLeading)
    }
}

/// Convert, Tools and Actions: the real wheel on the left, two steps and the keys on the right.
struct WelcomeWheelPage: View {
    let wheel: WheelMode
    let rotation: Double
    let rotationDuration: Double
    let instructionsOffset: CGFloat
    let live: Bool
    let onNext: () -> Void
    let onBack: () -> Void

    static let instructionsLeading: CGFloat = 524

    var body: some View {
        let width = 875 - Self.instructionsLeading - 52
        let key = WelcomeKeys.capKey(wheel)
        ZStack(alignment: .topLeading) {
            WelcomeWheelPreview(mode: wheel, rotation: rotation, duration: rotationDuration, live: live)
                .frame(width: 360, height: 360)
                .background(WelcomeWheelGlass(diameter: WelcomeWheelHost.backdropDiameter(count: WelcomeSample.items(for: wheel).count, size: 360),
                                              live: live))
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                .position(x: 282.5, y: 282.5)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(wheel.rawValue) wheel. " + WelcomeSample.items(for: wheel).map(\.title).joined(separator: ", "))
                .accessibilityIdentifier("welcomeWheelPreview")
            VStack(alignment: .leading, spacing: 0) {
                WelcomeBackButton(action: onBack)
                    .padding(.bottom, 20)
                Text(WelcomeCopy.wheelTitle(wheel))
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.6)
                    .padding(.bottom, 28)
                    .accessibilityAddTraits(.isHeader)
                Text(WelcomeCopy.stepOne)
                    .padding(.bottom, 14)
                HStack(alignment: .top, spacing: 8) {
                    Text(WelcomeCopy.stepTwo).frame(height: 54)
                    if let key {
                        WelcomeShortcutKeys(keys: [key])
                    } else {
                        Text(WelcomeCopy.keyOff)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(height: 54)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(key.map { "Step 2. While dragging, tap \($0.name) to open the \(wheel.rawValue) wheel." }
                                    ?? "Step 2. This wheel is off. Pick a key for it in Settings.")
                .padding(.bottom, 32)
                WelcomeContinueButton(title: WelcomeCopy.next, action: onNext)
            }
            .font(.system(size: 22, weight: .medium))
            .frame(width: width, alignment: .leading)
            .position(x: Self.instructionsLeading + width / 2, y: 282.5)
            .offset(x: 0, y: instructionsOffset)
        }
        .frame(width: 875, height: 565, alignment: .topLeading)
    }
}

/// The last two pages: an illustration or settings on the left, title, text and button on the right.
struct WelcomeSidePage<Left: View>: View {
    let page: WelcomePage
    let onNext: () -> Void
    let onBack: () -> Void
    @ViewBuilder let left: () -> Left

    var body: some View {
        let last = page == .setup
        HStack(alignment: .center, spacing: 32) {
            left().frame(width: 360, height: 320)
            VStack(alignment: .leading, spacing: 20) {
                WelcomeBackButton(action: onBack)
                Text(last ? WelcomeCopy.setupTitle : WelcomeCopy.savedTitle)
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.6)
                    .accessibilityAddTraits(.isHeader)
                Text(last ? WelcomeCopy.setupBody : WelcomeCopy.savedBody)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                WelcomeContinueButton(title: last ? WelcomeCopy.done : WelcomeCopy.next, action: onNext)
                    .padding(.top, 8)
            }
            .frame(width: 270, alignment: .leading)
        }
        .frame(width: 662, height: 380)
        .position(x: 439.5, y: 286)
        .frame(width: 875, height: 565, alignment: .topLeading)
    }
}

/// A rounded card on a faint fill, as used on the last two pages.
struct WelcomeCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

/// A setting row: a title, a caption and a switch in the accent colour.
struct WelcomeSwitchRow: View {
    let title: String
    let detail: String
    let isOn: Binding<Bool>
    var enabled = true

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(DWPalette.color(DWPalette.accent))
                .disabled(!enabled)
        }
    }
}

/// Where results go: the illustration, Show new files (on a shelf, on the Clothesline, in Finder or not at all), and a
/// reassurance.
struct WelcomeSavedColumn: View {
    @WelcomeState private var results = Settings.resultsDestination

    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            WelcomeSavedIllustration()
            WelcomeCard {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(WelcomeCopy.revealTitle).font(.system(size: 14, weight: .medium))
                        Text(results.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    ResultsDestinationPicker(selection: Binding(get: { results }, set: { results = $0; Settings.resultsDestination = $0 })) {
                        Text(WelcomeCopy.revealTitle)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .accessibilityIdentifier("welcomeRevealResults")
            Text(WelcomeCopy.savedCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: Settings.didChange)) { _ in results = Settings.resultsDestination }
    }
}

/// Setup: where the icon is, Open at Login, and the keys with a way into Settings.
struct WelcomeSetupColumn: View {
    @ObservedObject var model: WelcomeModel

    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            WelcomeMenuBarPill()
                .padding(.bottom, 14)
            WelcomeCard {
                WelcomeSwitchRow(title: WelcomeCopy.loginTitle, detail: WelcomeCopy.loginDetail,
                                 isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }),
                                 enabled: model.loginAvailable)
                if let note = model.loginApprovalShown ? WelcomeCopy.loginApproval : model.loginNote {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.loginAvailable {
                        Button(WelcomeCopy.openLoginItems) { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
            }
            .accessibilityIdentifier("welcomeLaunchAtLogin")
            WelcomeCard {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(WelcomeCopy.keysTitle).font(.system(size: 14, weight: .medium))
                        Text(Settings.wheelKeys.allOff ? "All wheels are off" : Settings.wheelKeys.hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button(WelcomeCopy.openSettings) {
                        if model.live { SettingsWindowController.shared.show() }
                    }
                    .accessibilityIdentifier("welcomeOpenSettings")
                }
            }
        }
    }
}
