import AppKit
import SwiftUI

/// The demo page's state: a sample photo dragged inside the window, the real modifier keys, and a practice wheel
/// drawn by the real wheel view. Nothing is converted; dropping on a petal shows what would be saved.
final class WelcomeDemoModel: ObservableObject {
    /// drag → shortcut → drop → done, derived from the state below.
    enum Step: Equatable { case drag, shortcut, drop, done }

    struct Result: Equatable {
        var wheel: WheelMode
        var title: String
        var symbol: String?
        /// The file the petal would save next to the sample, nil for file actions.
        var fileName: String?
    }

    /// Page geometry, in design points of the 875 × 565 canvas.
    static let center = CGPoint(x: 437.5, y: 262)
    static let wheelSize: CGFloat = 300
    static let fileSize: CGFloat = 88

    @Published private(set) var dragging = false
    @Published private(set) var dragLocation: CGPoint?
    @Published private(set) var wheel: WheelMode?
    @Published private(set) var highlighted: Int?
    @Published private(set) var result: Result?

    let live: Bool
    /// The wheel keys (Settings, or a fixed map in self-tests).
    var keys: () -> WheelKeyMap = { Settings.wheelKeys }
    /// The real wheel view the practice wheel is drawn with.
    private(set) lazy var host = WelcomeWheelHost(size: Self.wheelSize, practice: true, live: live)

    private var previousFlags: NSEvent.ModifierFlags = []
    private var monitor: Any?
    private static let relevantFlags: NSEvent.ModifierFlags = [.shift, .command, .control, .option]

    init(live: Bool) { self.live = live }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    var step: Step {
        if result != nil { return .done }
        if !dragging { return .drag }
        return wheel == nil ? .shortcut : .drop
    }

    /// The wheel the instructions ask for: Convert, or the first wheel that has a key.
    var practiceWheel: WheelMode? {
        [WheelMode.convert, .tools, .actions].first { keys().key(for: $0) != .off }
    }

    // MARK: Input

    /// The pointer moved during a drag of the sample (location in canvas points).
    func dragChanged(to location: CGPoint, flags: NSEvent.ModifierFlags) {
        if !dragging {
            dragging = true
            result = nil
            // A wheel key already held as the drag starts opens its wheel (hold ⇧, then drag).
            previousFlags = flags.intersection(Self.relevantFlags)
            if let mode = keys().mode(heldAtPress: previousFlags) { open(mode) }
            startMonitor()
        } else {
            modifiersChanged(flags)
        }
        dragLocation = location
        updateHighlight()
    }

    /// A modifier went down or up. A wheel key pressed during the drag opens (or switches to) its wheel.
    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        guard dragging else { return }
        let now = flags.intersection(Self.relevantFlags)
        let newlyPressed = now.subtracting(previousFlags)
        previousFlags = now
        if let mode = keys().mode(newlyPressed: newlyPressed) { open(mode) }
    }

    /// Esc during the drag closes the wheel, as it does for real.
    func cancelWheel() {
        wheel = nil
        highlighted = nil
        host.setHighlight(nil)
    }

    /// The mouse went up: a drop on a petal finishes the demo, anywhere else puts the photo back.
    func dragEnded() {
        if let wheel, let i = highlighted {
            let items = WelcomeSample.items(for: wheel)
            if items.indices.contains(i) { result = Self.result(for: items[i], on: wheel) }
        }
        endDrag()
    }

    func retry() {
        endDrag()
        result = nil
    }

    /// Back to the start (leaving the page, closing the window).
    func reset() { retry() }

    static func result(for item: WheelItem, on wheel: WheelMode) -> Result {
        Result(wheel: wheel, title: item.title, symbol: item.symbol,
               fileName: WelcomeSample.outputName(for: item.title, wheel: wheel))
    }

    private func endDrag() {
        dragging = false
        dragLocation = nil
        wheel = nil
        highlighted = nil
        previousFlags = []
        stopMonitor()
    }

    private func open(_ mode: WheelMode) {
        guard wheel != mode else { return }
        host.configure(mode: mode, items: WelcomeSample.items(for: mode))
        wheel = mode
        highlighted = nil
        host.setHighlight(nil)
        updateHighlight()
    }

    private func updateHighlight() {
        guard wheel != nil, let location = dragLocation else { return }
        let i = host.petal(atCanvas: location, center: Self.center, size: Self.wheelSize)
        if i != highlighted {
            highlighted = i
            host.setHighlight(i)
        }
    }

    /// Modifier taps don't move the mouse, so they come from a local monitor while the drag lasts.
    private func startMonitor() {
        guard live, monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self, self.dragging else { return event }
            if event.type == .flagsChanged {
                self.modifiersChanged(event.modifierFlags)
                return event
            }
            if event.keyCode == 53 {   // Esc: close the practice wheel, not the window
                self.cancelWheel()
                return nil
            }
            return event
        }
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // MARK: Previews

    /// Puts the demo in a state without input, for snapshots and the self-check hook:
    /// drag, shortcut, drop, done, and drop-tools / done-actions etc. to pick the wheel.
    func apply(preview: String) {
        let parts = preview.lowercased().split(separator: "-").map(String.init)
        let mode = parts.count > 1 ? WheelMode.allCases.first { $0.rawValue.lowercased() == parts[1] } : nil
        let c = Self.center
        switch parts.first ?? "" {
        case "shortcut":
            dragging = true
            dragLocation = CGPoint(x: c.x + 118, y: c.y + 52)
        case "drop":
            guard let wheel = mode ?? practiceWheel else { return }
            dragging = true
            open(wheel)
            // Over the petal at about half past one.
            let r = Self.wheelSize * 0.36
            dragLocation = CGPoint(x: c.x + r * sin(.pi / 4), y: c.y - r * cos(.pi / 4))
            updateHighlight()
        case "done":
            let wheel = mode ?? practiceWheel ?? .convert
            let items = WelcomeSample.items(for: wheel)
            let preferred = ["JPG", FileTool.rotate.rawValue, "Float"]
            if let item = items.first(where: { preferred.contains($0.title) }) ?? items.first {
                result = Self.result(for: item, on: wheel)
            }
        default:
            break
        }
    }
}

// MARK: - Page

/// The guided demo: drag the photo, tap the wheel key, drop on a petal, see the result.
struct WelcomeDemoPage: View {
    @ObservedObject var model: WelcomeDemoModel
    let live: Bool
    let onNext: () -> Void
    let onBack: () -> Void

    @WelcomeState private var isNudging = false
    @WelcomeState private var isKeyDown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let c = WelcomeDemoModel.center
    private var accent: Color { DWPalette.color(DWPalette.accentOnBackground) }

    var body: some View {
        let step = model.step
        ZStack(alignment: .topLeading) {
            Text(WelcomeCopy.demoTitle)
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.6)
                .position(x: c.x, y: 80)
                .accessibilityAddTraits(.isHeader)

            if step == .done, let result = model.result {
                doneResult(result)
            } else {
                sampleFile(step)
            }

            if step != .done, model.wheel != nil {
                WelcomePracticeWheel(host: model.host)
                    .frame(width: WelcomeDemoModel.wheelSize, height: WelcomeDemoModel.wheelSize)
                    .background(WelcomeWheelGlass(diameter: WelcomeWheelHost.backdropDiameter(
                        count: WelcomeSample.items(for: model.wheel ?? .convert).count, size: WelcomeDemoModel.wheelSize), live: live))
                    .position(c)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }

            coach(step)
                .id(step)

            if model.dragging, let p = model.dragLocation {
                WelcomeDemoThumbnail(size: 64)
                    .opacity(0.85)
                    .position(x: p.x + 26, y: p.y + 30)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            bottomControls(step)
                .position(x: c.x, y: step == .done ? 434 : 492)
        }
        .frame(width: 875, height: 565, alignment: .topLeading)
        .coordinateSpace(name: "welcomeDemo")
        .task(id: step) { await nudgeLoop(step) }
    }

    // MARK: Parts

    private func sampleFile(_ step: WelcomeDemoModel.Step) -> some View {
        WelcomeDemoFile(name: WelcomeSample.fileName, size: WelcomeDemoModel.fileSize, isNew: false)
            .contentShape(Rectangle())
            .opacity(model.dragging ? 0.35 : 1)
            .offset(x: isNudging ? 14 : 0, y: isNudging ? -6 : 0)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("welcomeDemo"))
                    .onChanged { value in model.dragChanged(to: value.location, flags: NSEvent.modifierFlags) }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.25)) { model.dragEnded() }
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sample photo, \(WelcomeSample.fileName)")
            .accessibilityHint(WelcomeCopy.hint(step, wheel: model.practiceWheel))
            .accessibilityIdentifier("welcomeDemoFile")
            .position(c)
    }

    @ViewBuilder
    private func doneResult(_ result: WelcomeDemoModel.Result) -> some View {
        let appear = AnyTransition.scale(scale: 0.8, anchor: .center).combined(with: .opacity)
        if let name = result.fileName {
            WelcomeDemoFile(name: WelcomeSample.fileName, size: WelcomeDemoModel.fileSize, isNew: false)
                .position(x: c.x - 90, y: c.y)
                .transition(appear)
            WelcomeDemoFile(name: name, size: WelcomeDemoModel.fileSize, isNew: true)
                .position(x: c.x + 90, y: c.y)
                .transition(appear)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("New file, \(name)")
        } else {
            VStack(spacing: 12) {
                Image(systemName: result.symbol ?? "checkmark.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(accent)
                Text(result.title)
                    .font(.system(size: 18, weight: .semibold))
            }
            .position(c)
            .transition(appear)
        }
    }

    @ViewBuilder
    private func coach(_ step: WelcomeDemoModel.Step) -> some View {
        let animated = live && !reduceMotion
        switch step {
        case .drag:
            WelcomeHandNote(text: WelcomeCopy.dragNote, detail: nil,
                            at: CGPoint(x: c.x + 190, y: c.y - 140), from: CGPoint(x: c.x + 150, y: c.y - 116),
                            control: CGPoint(x: c.x + 152, y: c.y - 52), to: CGPoint(x: c.x + 60, y: c.y - 52), animated: animated)
        case .shortcut:
            Group {
                if let wheel = model.practiceWheel, let key = WelcomeKeys.capKey(wheel) {
                    HStack(alignment: .center, spacing: 14) {
                        WelcomeHandText(text: WelcomeCopy.tapLead)
                        WelcomeShortcutKeys(keys: [key], raised: true, pressed: isKeyDown)
                        WelcomeHandText(text: WelcomeCopy.tapTrail(wheel))
                    }
                } else {
                    WelcomeHandText(text: WelcomeCopy.noWheel).frame(width: 420)
                }
            }
            .position(x: c.x, y: 408)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WelcomeCopy.hint(.shortcut, wheel: model.practiceWheel))
        case .drop:
            WelcomeHandNote(text: WelcomeCopy.dropNote(model.wheel ?? .convert), detail: nil,
                            at: CGPoint(x: c.x + 255, y: c.y - 150), from: CGPoint(x: c.x + 235, y: c.y - 124),
                            control: CGPoint(x: c.x + 228, y: c.y - 56), to: CGPoint(x: c.x + 160, y: c.y - 40), animated: animated)
        case .done:
            let result = model.result
            let isFile = result?.fileName != nil
            WelcomeHandNote(text: isFile ? WelcomeCopy.savedNote : WelcomeCopy.actionNote(result?.title ?? ""),
                            detail: WelcomeCopy.anywhere,
                            at: CGPoint(x: c.x + 232, y: c.y - 135), from: CGPoint(x: c.x + 214, y: c.y - 82),
                            control: CGPoint(x: c.x + 206, y: c.y - 50), to: CGPoint(x: c.x + (isFile ? 140 : 48), y: c.y - 50),
                            animated: animated)
        }
    }

    private func bottomControls(_ step: WelcomeDemoModel.Step) -> some View {
        VStack(alignment: .center, spacing: 18) {
            if step == .done {
                WelcomeContinueButton(title: WelcomeCopy.next, action: onNext)
            }
            HStack(alignment: .center, spacing: 24) {
                WelcomeBackButton(action: onBack)
                if step != .done {
                    Button(WelcomeCopy.skip, action: onNext)
                        .accessibilityIdentifier("welcomeDemoSkip")
                } else {
                    Button {
                        withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.25)) { model.retry() }
                    } label: {
                        Label(WelcomeCopy.retry, systemImage: "arrow.counterclockwise")
                    }
                    .accessibilityIdentifier("welcomeDemoRetry")
                }
            }
            .font(.system(size: 12))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Motion

    /// Nudges the photo while it waits for a drag, and presses the key cap while it waits for the key.
    private func nudgeLoop(_ step: WelcomeDemoModel.Step) async {
        isNudging = false
        isKeyDown = false
        guard live, !reduceMotion else { return }
        do {
            try await Task.sleep(nanoseconds: 600_000_000)
            while !Task.isCancelled {
                switch step {
                case .drag:
                    withAnimation(.easeOut(duration: 0.22)) { isNudging = true }
                    try await Task.sleep(nanoseconds: 260_000_000)
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.45, blendDuration: 0)) { isNudging = false }
                    try await Task.sleep(nanoseconds: 1_600_000_000)
                case .shortcut:
                    withAnimation(.easeIn(duration: 0.10)) { isKeyDown = true }
                    try await Task.sleep(nanoseconds: 220_000_000)
                    withAnimation(.easeOut(duration: 0.16)) { isKeyDown = false }
                    try await Task.sleep(nanoseconds: 800_000_000)
                default:
                    return
                }
            }
        } catch {
            isNudging = false
            isKeyDown = false
        }
    }
}
