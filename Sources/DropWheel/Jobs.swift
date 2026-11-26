import AppKit

// `Settings` (where new files show, progress HUD, wheel keys and looks) lives in SettingsStore.swift.

/// Runs an operation over the dropped files in the background and reports through the HUD.
enum JobRunner {
    private static let queue = DispatchQueue(label: "dropwheel.jobs", qos: .userInitiated)
    private static let countLock = NSLock()
    private static var running = 0

    /// Jobs started and not yet finished (queued ones too). The updater waits for none before it restarts YummyOrange.
    static var runningCount: Int {
        countLock.lock(); defer { countLock.unlock() }
        return running
    }

    private static func count(_ change: Int) {
        countLock.lock(); running += change; countLock.unlock()
    }

    static func run(_ op: Operation, on files: [URL]) { run(op, on: files, earlier: nil) }

    /// What a first run saved and the errors it met, before it waited for YummyOrange’s own ffmpeg, and whether
    /// it ran on several files (errors then name their file).
    private struct Earlier {
        var outputs: [URL]
        var errors: [String]
        var several: Bool
    }

    /// A file whose run meets a missing ffmpeg on a Mac that has none, in a copy that can get YummyOrange's own, waits
    /// for it (FFmpegHelper.whenAvailable, one download for every waiting job, progress in the HUD) and runs again
    /// once it is there. Only once: a second run reports whatever it meets.
    private static func run(_ op: Operation, on files: [URL], earlier: Earlier?) {
        let name = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        HUD.shared.begin("\(op.title)  ·  \(name)")
        count(1)
        let several = earlier?.several ?? (files.count > 1)
        let mayWait = earlier == nil
        queue.async { defer { count(-1) }; onBigStack {
            var outputs = earlier?.outputs ?? []
            var errors = earlier?.errors ?? []
            var waiting: [URL] = []
            if op.combinesInputs {
                do {
                    outputs += try Converter.performCombined(op, on: files) { fraction in
                        DispatchQueue.main.async { HUD.shared.update(progress: fraction) }
                    }
                } catch where mayWait && FFmpegHelper.canProvide(error) {
                    waiting = files
                } catch {
                    errors.append(error.localizedDescription)
                }
                DispatchQueue.main.async { waiting.isEmpty ? finish(outputs, errors) : waitForHelper(op, waiting, Earlier(outputs: outputs, errors: errors, several: several)) }
                return
            }
            for (i, file) in files.enumerated() {
                do {
                    outputs += try Converter.perform(op, on: file) { fraction in
                        let overall = (Double(i) + fraction) / Double(files.count)
                        DispatchQueue.main.async { HUD.shared.update(progress: overall) }
                    }
                } catch where mayWait && FFmpegHelper.canProvide(error) {
                    waiting.append(file)
                } catch {
                    errors.append(several ? "\(file.lastPathComponent): \(error.localizedDescription)" : error.localizedDescription)
                }
                DispatchQueue.main.async { HUD.shared.update(progress: Double(i + 1) / Double(files.count)) }
            }
            DispatchQueue.main.async { waiting.isEmpty ? finish(outputs, errors) : waitForHelper(op, waiting, Earlier(outputs: outputs, errors: errors, several: several)) }
        } }
    }

    /// Main thread. Counts as running while it waits, so an update's restart waits for it too.
    private static func waitForHelper(_ op: Operation, _ files: [URL], _ earlier: Earlier) {
        count(1)
        FFmpegHelper.shared.whenAvailable({
            count(-1)
            run(op, on: files, earlier: earlier)
        }, otherwise: { message in
            count(-1)
            finish(earlier.outputs, earlier.errors + [message])
        })
    }

    /// Runs `body` on a fresh thread with a 16 MB stack and waits for it, keeping jobs one at a time.
    private static func onBigStack(_ body: @escaping () -> Void) {
        let done = DispatchSemaphore(value: 0)
        let worker = Thread { body(); done.signal() }
        worker.stackSize = 16 << 20
        worker.qualityOfService = .userInitiated
        worker.name = "dropwheel.job"
        worker.start()
        done.wait()
    }

    /// Clears the Finder "hidden" flag on outputs that have it, so a result never shows up dimmed or invisible.
    static func unhide(_ outputs: [URL]) {
        for url in outputs {
            guard (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true, !url.lastPathComponent.hasPrefix(".")
            else { continue }
            var values = URLResourceValues()
            values.isHidden = false
            var target = url
            do {
                try target.setResourceValues(values)
                DragMonitor.log.notice("cleared the hidden flag on \(url.lastPathComponent, privacy: .public)")
            } catch {
                DragMonitor.log.error("couldn’t clear the hidden flag on \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// For windows that save their own output (editors, organizer): report it like a finished job.
    static func report(saved outputs: [URL], errors: [String] = []) {
        MainThread.sync { finish(outputs, errors) }
    }

    /// Where a finished job is reported. `--selftest results-shelf` swaps in a recorder, so no panel appears.
    static var reportToHUD: (_ saved: [URL], _ errors: [String]) -> Void = { HUD.shared.finish(saved: $0, errors: $1) }

    private static func finish(_ outputs: [URL], _ errors: [String]) {
        unhide(outputs)
        // A synced folder (iCloud Desktop) has been seen marking a fresh output hidden just after it was written,
        // when a file of the same name had been deleted moments before. Check once more after the sync settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { unhide(outputs) }
        reportToHUD(outputs, errors)
        // Every file this job made, even when some inputs failed: on a new shelf, in Finder, or nowhere
        // (Settings › Show new files). See ResultsShelf.swift.
        ResultsPresenter.present(outputs)
    }
}

/// A small banner in the top-right corner, in the style of a macOS notification: an icon, a bold line and a grey one,
/// on the system's frosted material. It appears for errors and for what the person asked for directly (`always`: an
/// update's download and restart). Progress and "Saved" messages appear only when Settings › Show progress is on, which
/// it is not by default: the shelf or the Clothesline already shows the new files, and that is feedback enough. A job
/// that is still running after `slowJobDelay` (a long video, a big batch, a download) shows its progress anyway, and
/// then says "Saved" when it ends.
/// Clicking the banner dismisses it; while the pointer rests on it, it stays and shows a close button.
final class HUD {
    static let shared = HUD()

    enum Kind { case working, success, error, info }

    static let width: CGFloat = 340
    private static let pad: CGFloat = 14
    private static let iconSide: CGFloat = 22

    private let panel: NSPanel
    private let content = HUDContentView()
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let title = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private let closeButton = NSButton()
    private var hideWork: DispatchWorkItem?
    /// Shows a job's progress once it has run for `slowJobDelay`.
    private var revealWork: DispatchWorkItem?
    /// How long a job runs before its progress shows when Show progress is off.
    static let slowJobDelay = 1.5

    /// When work in progress shows: at once (asked for directly, or Show progress is on), or only if it is still
    /// running after `slowJobDelay`.
    static func revealDelay(always: Bool, showProgress: Bool) -> Double {
        always || showProgress ? 0 : slowJobDelay
    }
    /// The seconds the current message stays once the pointer leaves it (nil while work is in progress).
    private var lingerSeconds: Double?
    /// The job's name from `begin` ("Add Background"), for the title of its error.
    private var jobTitle: String?
    private var kind: Kind = .info

    private init() {
        let size = CGSize(width: Self.width, height: 64)
        panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let fx = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        // The material is drawn by the window server behind the window, so a layer's rounded corners don't clip it
        // (that left a square of frosted glass around the card). A mask image does, and the window's shadow follows it.
        fx.maskImage = Self.roundedMask(radius: 16)
        fx.autoresizingMask = [.width, .height]

        content.frame = fx.bounds
        content.autoresizingMask = [.width, .height]
        content.onClick = { [weak self] in self?.dismiss() }
        content.onHover = { [weak self] inside in self?.hovered(inside) }

        icon.imageScaling = .scaleProportionallyUpOrDown
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 1
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 4
        body.lineBreakMode = .byWordWrapping
        body.cell?.truncatesLastVisibleLine = true
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close"
        closeButton.isHidden = true

        for v in [icon, spinner, title, body, bar, closeButton] as [NSView] { content.addSubview(v) }
        fx.addSubview(content)
        panel.contentView = fx
        panel.setAccessibilityRole(.popover)
    }

    /// A stretchable rounded rectangle for the material's mask: the corners stay, the middle stretches.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: Placing

    /// Where the panel goes: the top-right corner, 12 pt under the menu bar. While new files go to the Clothesline
    /// and the line hangs on this screen (`line`), it goes 12 pt under the lowest a card can hang instead: the line
    /// drops at the end of every job, at the same window level, and its cards would cover what the panel says.
    static func origin(size: CGSize, visibleFrame vis: CGRect, line: ClotheslineGeometry?) -> CGPoint {
        var top = vis.maxY - 12
        if let line { top = min(top, line.screenFrame.maxY - line.cardsBottom - 12) }
        return CGPoint(x: vis.maxX - size.width - 16, y: top - size.height)
    }

    /// The Clothesline's geometry when new files go to it and it hangs on `screen`; nil otherwise.
    static func line(on screen: NSScreen) -> ClotheslineGeometry? {
        guard Settings.resultsDestination == .clothesline, let lineScreen = ClotheslineGeometry.preferredScreen(),
              lineScreen.frame == screen.frame else { return nil }
        return ClotheslineGeometry(screen: lineScreen)
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Lays the contents out for the current text and returns the panel's height.
    private func layout() -> CGFloat {
        let w = Self.width, pad = Self.pad, side = Self.iconSide
        let textX = pad + side + 10
        let textW = w - textX - pad - 14   // room for the close button
        let hasBody = !body.stringValue.isEmpty, hasBar = !bar.isHidden
        let titleH: CGFloat = 17
        let bodyH = hasBody ? ceil(body.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: textW, height: 200)).height ?? 16) : 0
        var textH = titleH + (hasBody ? 2 + bodyH : 0) + (hasBar ? 8 + 6 : 0)
        textH = max(textH, side)
        let h = (textH + 2 * 12).rounded(.up)
        // Flipped-free coordinates: y grows upward, so place from the top.
        var y = h - 12 - titleH
        title.frame = CGRect(x: textX, y: y, width: textW, height: titleH)
        if hasBody {
            y -= 2 + bodyH
            body.frame = CGRect(x: textX, y: y, width: textW, height: bodyH)
        }
        if hasBar {
            y -= 8 + 6
            bar.frame = CGRect(x: textX, y: y, width: textW, height: 6)
        }
        // The icon sits level with the title (centred on the whole banner when it is one line).
        let iconY = hasBody || hasBar ? h - 12 - side + 0.5 : (h - side) / 2
        icon.frame = CGRect(x: pad, y: iconY, width: side, height: side)
        spinner.frame = icon.frame.insetBy(dx: 3, dy: 3)
        closeButton.frame = CGRect(x: w - 8 - 18, y: h - 8 - 18, width: 18, height: 18)
        return h
    }

    /// Shows the message, or keeps it hidden unless it is an error, `always`, or progress is turned on.
    private func present(isError: Bool, always: Bool = false) {
        guard isError || always || Settings.showProgressHUD else {
            if panel.isVisible { hide() }
            return
        }
        guard let screen = NSScreen.main else { return }
        let size = CGSize(width: Self.width, height: layout())
        let origin = Self.origin(size: size, visibleFrame: screen.visibleFrame, line: Self.line(on: screen))
        let target = CGRect(origin: origin, size: size)
        if panel.isVisible && panel.alphaValue > 0.5 {
            // Already showing: grow or shrink in place, keeping the top edge.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = reduceMotion ? 0 : 0.18
                panel.animator().setFrame(target, display: true)
            }
            panel.invalidateShadow()
            return
        }
        // Slides in a little from the right edge and fades up; with Reduce Motion it only fades.
        panel.setFrame(reduceMotion ? target : target.offsetBy(dx: 18, dy: 0), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.15 : 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: [title.stringValue, body.stringValue].filter { !$0.isEmpty }.joined(separator: ". "),
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func setKind(_ kind: Kind) {
        self.kind = kind
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        switch kind {
        case .working:
            icon.image = nil
            spinner.startAnimation(nil)
        case .success:
            spinner.stopAnimation(nil)
            icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Done")?.withSymbolConfiguration(config)
            icon.contentTintColor = .systemGreen
        case .error:
            spinner.stopAnimation(nil)
            icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")?.withSymbolConfiguration(config)
            icon.contentTintColor = .systemOrange
        case .info:
            spinner.stopAnimation(nil)
            icon.image = NSImage(systemSymbolName: "info.circle.fill", accessibilityDescription: "Note")?.withSymbolConfiguration(config)
            icon.contentTintColor = .secondaryLabelColor
        }
    }

    private func setText(_ heading: String, _ detail: String = "") {
        title.stringValue = heading
        body.stringValue = detail
    }

    /// A long sentence goes in the grey line under a short heading; a short one is the heading itself.
    private func setSentence(_ text: String, heading: String) {
        if text.count <= 44 { setText(text) } else { setText(heading, text) }
    }

    // MARK: Messages

    /// A job started: "Add Background  ·  photo.png" shows as the job's name over the file's.
    func begin(_ text: String, always: Bool = false) {
        hideWork?.cancel()
        lingerSeconds = nil
        let parts = text.components(separatedBy: "  ·  ")
        jobTitle = parts.first.map(Self.jobName)
        setKind(.working)
        setText(jobTitle ?? text, parts.dropFirst().joined(separator: "  ·  "))
        bar.isHidden = false
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        presentWorking(always: always)
    }

    /// Shows work in progress now, or once it has gone on for `slowJobDelay` (quick jobs stay silent).
    private func presentWorking(always: Bool) {
        revealWork?.cancel()
        let delay = Self.revealDelay(always: always, showProgress: Settings.showProgressHUD)
        guard delay > 0 else { present(isError: false, always: true); return }
        if panel.isVisible { present(isError: false, always: true); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.kind == .working else { return }
            self.present(isError: false, always: true)
        }
        revealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func update(progress: Double) {
        if bar.isIndeterminate { bar.isIndeterminate = false; bar.stopAnimation(nil) }
        bar.doubleValue = progress
    }

    /// Something a task waits for, with its own words and how far it is: the bar runs indeterminate until the
    /// fraction is known, then fills (YummyOrange’s own ffmpeg downloading: "Downloading ffmpeg for audio and video… 42%").
    func progress(_ text: String, fraction: Double?, always: Bool = false) {
        hideWork?.cancel()
        lingerSeconds = nil
        setKind(.working)
        setSentence(text, heading: "Working…")
        bar.isHidden = false
        if let fraction {
            update(progress: fraction)
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
        presentWorking(always: always)
    }

    /// A job's name for the banner: a conversion's petal title "→ JPG" reads "Convert to JPG".
    static func jobName(_ title: String) -> String {
        title.hasPrefix("→ ") ? "Convert to " + title.dropFirst(2) : title
    }

    /// What the panel says when a job ends: "Saved photo.jpg", "Saved 3 files", or the errors after what was saved.
    static func finishText(saved: [URL], errors: [String]) -> String {
        if errors.isEmpty { return saved.count == 1 ? "Saved \(saved[0].lastPathComponent)" : "Saved \(saved.count) files" }
        return (saved.isEmpty ? "" : "Saved \(saved.count). ") + errors.joined(separator: " ")
    }

    /// The banner's heading and line for a finished job.
    static func finishLines(saved: [URL], errors: [String], job: String?) -> (title: String, body: String) {
        if errors.isEmpty {
            return ("Saved", saved.count == 1 ? saved[0].lastPathComponent : "\(saved.count) files")
        }
        let heading = saved.isEmpty ? (job.map { "\($0) didn’t finish" } ?? "Couldn’t finish")
                                    : "Saved \(saved.count) of \(saved.count + errors.count)"
        return (heading, errors.joined(separator: " "))
    }

    func finish(saved: [URL], errors: [String]) {
        revealWork?.cancel()
        bar.stopAnimation(nil)
        bar.isHidden = true
        let lines = Self.finishLines(saved: saved, errors: errors, job: jobTitle)
        setText(lines.title, lines.body)
        if errors.isEmpty {
            setKind(.success)
            if panel.isVisible {
                present(isError: false, always: true)
                scheduleHide(after: 2.0)
            }
        } else {
            setKind(.error)
            present(isError: true)
            scheduleHide(after: 8.0)
        }
    }

    func flash(_ text: String, isError: Bool = false, always: Bool = false, seconds: Double? = nil) {
        hideWork?.cancel()
        revealWork?.cancel()
        bar.stopAnimation(nil)
        bar.isHidden = true
        setKind(isError ? .error : .info)
        setSentence(text, heading: isError ? "Couldn’t do that" : "YummyOrange")
        present(isError: isError, always: always)
        scheduleHide(after: seconds ?? (isError ? 6.0 : 2.0))
    }

    func hide() {
        hideWork?.cancel()
        revealWork?.cancel()
        bar.stopAnimation(nil)
        spinner.stopAnimation(nil)
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0.1 : 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.panel.alphaValue < 0.01 else { return }
            self.panel.orderOut(nil)
            self.closeButton.isHidden = true
        })
    }

    // MARK: Pointer

    private func dismiss() { hide() }
    @objc private func closeClicked() { hide() }

    /// While the pointer rests on the banner it stays and offers its close button; it goes a moment after it leaves.
    private func hovered(_ inside: Bool) {
        closeButton.isHidden = !inside
        if inside {
            hideWork?.cancel()
        } else if let lingerSeconds {
            scheduleHide(after: min(lingerSeconds, 2.5))
        }
    }

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        lingerSeconds = seconds
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// `--snapshot hud`: the banner as it shows for `kind` (error by default), for checking its look.
    static func snapshotView(kind: String, dark: Bool) -> NSView {
        let hud = HUD.shared
        switch kind {
        case "success": hud.jobTitle = "Add Background"; hud.bar.isHidden = true; hud.setKind(.success)
            hud.setText("Saved", "Screenshot 2026-11-26 at 4.11.34 PM background.png")
        case "working": hud.bar.isHidden = false; hud.bar.isIndeterminate = false; hud.bar.doubleValue = 0.45; hud.setKind(.working)
            hud.setText("Add Background", "Screenshot 2026-11-26 at 4.11.34 PM.png")
        case "info": hud.bar.isHidden = true; hud.setKind(.info); hud.setText("Opened 5 of 8 images", "Editors open 5 at a time.")
        default: hud.bar.isHidden = true; hud.setKind(.error)
            hud.setText("Add Background didn’t finish", "photo.png has no see-through pixels to fill. Choose a canvas shape, some padding or rounded corners.")
        }
        let h = hud.layout()
        // The material is drawn by the window server, so the real panel is shown far off screen and captured.
        hud.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hud.panel.setFrame(CGRect(x: -30_000, y: -30_000, width: width, height: h), display: true)
        hud.panel.alphaValue = 1
        hud.panel.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        hud.panel.displayIfNeeded()
        let image = ImageEditors.captureWindow(hud.panel.windowNumber)
        hud.panel.orderOut(nil)
        return HUDSnapshotView(image: image, size: CGSize(width: width, height: h), dark: dark)
    }
}

/// The banner's contents: a click dismisses it, and hovering keeps it up.
final class HUDContentView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    /// A hairline just inside the rounded edge, so the banner holds its shape over any wallpaper.
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 15.5, yRadius: 15.5)
            path.lineWidth = 1
            NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
            path.stroke()
        }
    }
}

/// `--snapshot hud`: the captured banner over a desktop-like backdrop, as it sits in the screen's corner.
final class HUDSnapshotView: NSView {
    let image: CGImage?
    let banner: CGSize
    let dark: Bool

    init(image: CGImage?, size: CGSize, dark: Bool) {
        self.image = image
        banner = size
        self.dark = dark
        super.init(frame: CGRect(x: 0, y: 0, width: size.width + 80, height: size.height + 80))
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        ThemeDesktop.draw(in: bounds, dark: dark)
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        // The capture includes the window's shadow around the banner; centre it.
        let w = CGFloat(image.width) / 2, h = CGFloat(image.height) / 2
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h))
    }
}
