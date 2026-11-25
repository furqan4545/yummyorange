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

/// A small floating status panel in the top-right corner (under the Clothesline's cards while new files go there).
/// When "Show progress and results" is off in Settings it stays hidden for progress and success messages, but errors
/// still appear, and so does what the person asked for directly (`always`: an update's download and restart).
final class HUD {
    static let shared = HUD()

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private var hideWork: DispatchWorkItem?

    private init() {
        let size = CGSize(width: 320, height: 62)
        panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let fx = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 2
        label.cell?.truncatesLastVisibleLine = true
        // Two lines of 12 pt need 30 pt; the text sits at the top, so one line stays where it always was.
        label.frame = CGRect(x: 14, y: 23, width: size.width - 28, height: 31)
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.frame = CGRect(x: 14, y: 10, width: size.width - 28, height: 12)
        fx.addSubview(label)
        fx.addSubview(bar)
        panel.contentView = fx
    }

    private func place() {
        guard let screen = NSScreen.main else { return }
        panel.setFrameOrigin(Self.origin(size: panel.frame.size, visibleFrame: screen.visibleFrame, line: Self.line(on: screen)))
    }

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

    /// Orders the panel in, unless progress is turned off and this isn't an error or shown `always`.
    private func present(isError: Bool, always: Bool = false) {
        guard isError || always || Settings.showProgressHUD else {
            panel.orderOut(nil)
            return
        }
        place()
        panel.orderFrontRegardless()
    }

    /// Sentences (errors, notes, the helper's progress) wrap onto the second line; a job's title and "Saved photo.jpg"
    /// keep one line and shorten a long file name in the middle. (A label that truncates in the middle never wraps,
    /// so long errors used to lose their middle: "Couldn’t get the audio…connection and try again.")
    private func setText(_ text: String, sentence: Bool) {
        label.lineBreakMode = sentence ? .byWordWrapping : .byTruncatingMiddle
        label.stringValue = text
    }

    func begin(_ title: String, always: Bool = false) {
        hideWork?.cancel()
        setText(title, sentence: false)
        label.textColor = .labelColor
        bar.isHidden = false
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        present(isError: false, always: always)
    }

    func update(progress: Double) {
        if bar.isIndeterminate { bar.isIndeterminate = false; bar.stopAnimation(nil) }
        bar.doubleValue = progress
    }

    /// Something a task waits for, with its own words and how far it is: the bar runs indeterminate until the
    /// fraction is known, then fills (YummyOrange’s own ffmpeg downloading: "Downloading ffmpeg for audio and video… 42%").
    func progress(_ title: String, fraction: Double?, always: Bool = false) {
        hideWork?.cancel()
        setText(title, sentence: true)
        label.textColor = .labelColor
        bar.isHidden = false
        if let fraction {
            update(progress: fraction)
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
        if !panel.isVisible { present(isError: false, always: always) }
    }

    /// What the panel says when a job ends: "Saved photo.jpg", "Saved 3 files", or the errors after what was saved.
    static func finishText(saved: [URL], errors: [String]) -> String {
        if errors.isEmpty { return saved.count == 1 ? "Saved \(saved[0].lastPathComponent)" : "Saved \(saved.count) files" }
        return (saved.isEmpty ? "" : "Saved \(saved.count). ") + errors.joined(separator: " ")
    }

    func finish(saved: [URL], errors: [String]) {
        bar.stopAnimation(nil)
        bar.isHidden = true
        setText(Self.finishText(saved: saved, errors: errors), sentence: !errors.isEmpty)
        if errors.isEmpty {
            label.textColor = .labelColor
            if panel.isVisible { scheduleHide(after: 2.0) }
        } else {
            label.textColor = .systemRed
            present(isError: true)
            scheduleHide(after: 6.0)
        }
    }

    func flash(_ text: String, isError: Bool = false, always: Bool = false, seconds: Double? = nil) {
        hideWork?.cancel()
        setText(text, sentence: true)
        label.textColor = isError ? .systemRed : .labelColor
        bar.isHidden = true
        present(isError: isError, always: always)
        scheduleHide(after: seconds ?? (isError ? 4.0 : 1.6))
    }

    func hide() {
        hideWork?.cancel()
        bar.stopAnimation(nil)
        panel.orderOut(nil)
    }

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
