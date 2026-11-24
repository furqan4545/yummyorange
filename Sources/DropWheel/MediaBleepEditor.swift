import AppKit
import AVFoundation
import os

/// The Bleep window: any number of ranges over the film strip and waveform (drag across empty lanes to add one,
/// click to select, drag its body or edges, ⌫ deletes, I and O set the selected one's edges), Tone or Silence in the
/// toolbar, exact Start and End fields for the selected range, and Save, which writes "<name> bleeped.<ext>" from the
/// original through `--tool bleep`'s code.
///
/// Playing previews the result: the file's own sound is muted inside the ranges (an AVAudioMix with volume steps at
/// the ranges' edges) and, in Tone mode, a tone generator plays there, timed by the player's clock.
final class BleepEditorController: MediaEditorWindowController {
    override class var toolName: String { "Bleep" }
    override var command: WheelCommand? { MediaTools.bleep }
    override var timelineMode: MediaTimelineView.Mode { .multiple }
    override var discardMessage: String { "The bleeps you marked in \(source.name) haven’t been saved." }
    override var saveToolTip: String { "Save a bleeped copy next to the original (⌘S)" }
    override class func check(_ source: MediaSource) throws {
        guard source.hasAudio else { throw ConversionError.unsupported("\(source.name) has no sound to bleep.") }
    }

    /// Tone or Silence (remembered for the next window).
    private(set) var mode: MediaBleep.Mode = BleepEditorController.rememberedMode
    private var modeGroup: NSToolbarItemGroup?
    private(set) var deleteItem: NSToolbarItem?
    let startField = MediaTimeField(label: "Start")
    let endField = MediaTimeField(label: "End")
    let summaryLabel = NSTextField(labelWithString: "")
    /// The preview's mute and tone (nil in snapshots and until the player is ready).
    private(set) var previewAudio: BleepPreviewAudio?

    private static var rememberedMode: MediaBleep.Mode {
        MediaBleep.Mode(rawValue: ImageExtras.remembered("bleep").string("mode", "tone")) ?? .tone
    }

    // MARK: Options

    override func makeOptions() throws -> ToolOptions {
        guard !ranges.isEmpty else {
            throw ConversionError.unsupported("Mark at least one stretch to bleep: drag across the waveform, or press I.")
        }
        return ["ranges": MediaBleep.rangesOption(ranges), "mode": mode.rawValue, "freq": Ask.formatNumber(MediaBleep.defaultFrequency)]
    }

    func setMode(_ new: MediaBleep.Mode) {
        mode = new
        modeGroup?.selectedIndex = new == .tone ? 0 : 1
        if !isSnapshot { ImageExtras.remember(["mode": new.rawValue], as: "bleep") }
        previewAudio?.update(ranges: ranges, tone: new == .tone)
        updateSummary(ranges)
        timeline?.needsDisplay = true
    }

    /// The waveform as Save will write it: inside a range, the tone's level (Tone) or nothing (Silence); a column
    /// that straddles an edge keeps the louder of the two. Outside `sound` (before a late sound starts, after a sound
    /// that ends before the picture) there are no samples for the tone to replace, so nothing is drawn there.
    func resultPeak(from t0: Double, to t1: Double, peak: Float, ranges: [MediaRange], sound: MediaRange? = nil) -> Float {
        if let sound, t1 <= sound.start || t0 >= sound.end { return peak }
        let level: Float = mode == .tone ? Float(MediaBleep.toneLevel) : 0
        var lo = 0, hi = ranges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2, r = ranges[mid]
            if r.end <= t0 { lo = mid + 1 } else if r.start >= t1 { hi = mid - 1 } else {
                if r.start <= t0 && r.end >= t1 { return level }
                return max(peak, level)
            }
        }
        return peak
    }

    // MARK: Toolbar and transport bar

    private static let modeID = NSToolbarItem.Identifier("bleep.mode")

    override func makeToolItems() -> [NSToolbarItem] {
        let group = NSToolbarItemGroup(itemIdentifier: Self.modeID, titles: ["Tone", "Silence"], selectionMode: .selectOne,
                                       labels: ["Tone", "Silence"], target: self, action: #selector(modeChanged(_:)))
        group.label = "Cover With"
        group.subitems[0].toolTip = "Cover the marked stretches with a 1 kHz tone"
        group.subitems[1].toolTip = "Cover the marked stretches with silence"
        group.selectedIndex = mode == .tone ? 0 : 1
        modeGroup = group
        let add = symbolItem(.init("bleep.add"), symbol: "plus", label: "Add Bleep",
                             tip: "Add a one-second bleep at the playhead (I)", action: #selector(addAction))
        let delete = symbolItem(.init("bleep.delete"), symbol: "trash", label: "Delete Bleep",
                                tip: "Delete the selected bleep (⌫)", action: #selector(deleteAction))
        deleteItem = delete
        // Spaces keep the three groups apart: what covers the sound, the range actions, then Undo and Redo.
        return [group, NSToolbarItem(itemIdentifier: .space), add, delete, NSToolbarItem(itemIdentifier: .space)]
    }

    override func makeTransportAccessory() -> NSView? {
        for field in [startField, endField] {
            field.target = self
            field.action = #selector(fieldCommitted(_:))
            field.placeholderString = "–"
        }
        startField.toolTip = "Start of the selected bleep (m:ss.ff, or seconds)"
        endField.toolTip = "End of the selected bleep (m:ss.ff, or seconds)"
        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.alignment = .right
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setAccessibilityLabel("Bleeps")
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true
        let stack = NSStackView(views: [startField.labelView, startField, endField.labelView, endField, summaryLabel])
        for v in stack.arrangedSubviews { v.setContentCompressionResistancePriority(.required, for: .horizontal) }
        stack.spacing = 6
        stack.setCustomSpacing(16, after: startField)
        stack.setCustomSpacing(16, after: endField)
        return stack
    }

    @objc private func modeChanged(_ sender: NSToolbarItemGroup) {
        setMode(sender.selectedIndex == 1 ? .silence : .tone)
    }

    @objc private func addAction() {
        // A one-second bleep at the playhead (as I does when nothing is selected).
        let t = source.snap(playhead)
        addRange(MediaRange(start: t, end: min(source.duration, t + 1)))
    }

    @objc private func deleteAction() { removeSelectedRange() }

    // MARK: Read-outs

    override func rangesDidChange(live: Bool) {
        if !live {
            showSelected(ranges, selected: selectedRange)
            updateSummary(ranges)
            deleteItem?.isEnabled = selectedRange != nil
            previewAudio?.update(ranges: ranges, tone: mode == .tone)
        }
    }

    override func updateLiveReadouts(_ live: [MediaRange]) {
        showSelected(live, selected: timeline?.selectedIndex)
        updateSummary(live)
    }

    private func showSelected(_ all: [MediaRange], selected: Int?) {
        let r = selected.flatMap { $0 < all.count ? all[$0] : nil }
        for field in [startField, endField] { field.isEnabled = r != nil }
        if startField.currentEditor() == nil { startField.stringValue = r.map { MediaTime.string($0.start) } ?? "" }
        if endField.currentEditor() == nil { endField.stringValue = r.map { MediaTime.string($0.end) } ?? "" }
        startField.labelView.textColor = r == nil ? .tertiaryLabelColor : .secondaryLabelColor
        endField.labelView.textColor = r == nil ? .tertiaryLabelColor : .secondaryLabelColor
    }

    private func updateSummary(_ all: [MediaRange]) {
        if all.isEmpty {
            summaryLabel.stringValue = "Drag across the sound to add a bleep"
        } else {
            let total = all.reduce(0) { $0 + $1.length }
            let noun = mode == .tone ? (all.count == 1 ? "bleep" : "bleeps") : (all.count == 1 ? "silence" : "silences")
            summaryLabel.stringValue = "\(all.count) \(noun) · \(MediaTime.lengthString(total))"
        }
        summaryLabel.setAccessibilityValue(summaryLabel.stringValue)
    }

    /// A start or end typed for the selected range: snapped to a frame and kept between its neighbours.
    @objc private func fieldCommitted(_ sender: MediaTimeField) {
        guard let i = selectedRange, i < ranges.count else { showSelected(ranges, selected: nil); return }
        guard let typed = MediaTime.parse(sender.stringValue) else { NSSound.beep(); showSelected(ranges, selected: i); return }
        var all = ranges
        var r = all[i]
        let fd = source.frameDuration
        let lower = i > 0 ? all[i - 1].end : 0, upper = i + 1 < all.count ? all[i + 1].start : source.duration
        if sender === startField {
            let t = source.snap(min(typed, source.duration))
            guard t >= lower - 1e-9, t < r.end - fd / 2 else { NSSound.beep(); showSelected(ranges, selected: i); return }
            r.start = t
        } else {
            let t = source.snapEnd(min(typed, source.duration))
            guard t <= upper + 1e-9, t > r.start + fd / 2 else { NSSound.beep(); showSelected(ranges, selected: i); return }
            r.end = t
        }
        guard r != all[i] else { showSelected(ranges, selected: i); return }
        all[i] = r
        setRanges(all, selected: i, action: sender === startField ? "Set Start" : "Set End")
        scrub(to: sender === startField ? r.start : max(r.start, source.snap(r.end - fd)))
    }

    // MARK: Preview

    override func didBuild() {
        timeline.waveformPeak = { [weak self] t0, t1, peak in
            guard let self, let timeline = self.timeline else { return peak }
            // Where the decoded sound is, on the file's clock (the waveform's end; the container's start).
            let sound = timeline.peaks.map { MediaRange(start: self.source.audioStart, end: $0.duration) }
            return self.resultPeak(from: t0, to: t1, peak: peak, ranges: timeline.ranges, sound: sound)
        }
        updateSummary(ranges)
        showSelected(ranges, selected: nil)
        deleteItem?.isEnabled = false
        // Follow play/pause to start the tone generator the first time it's needed.
        if let playback {
            let previous = playback.onPlayingChange
            playback.onPlayingChange = { [weak self] playing in
                previous?(playing)
                if playing { self?.previewAudio?.startIfNeeded() }
            }
        }
    }

    override func previewDidLoad() {
        guard !isSnapshot, let item = playback?.player.currentItem else { return }
        let audio = BleepPreviewAudio(item: item)
        previewAudio = audio
        audio.update(ranges: ranges, tone: mode == .tone)
    }

    override func forceClose() {
        previewAudio?.stop()
        super.forceClose()
    }

    override func windowWillClose(_ notification: Notification) {
        previewAudio?.stop()
        super.windowWillClose(notification)
    }

    // MARK: Snapshot

    /// Options: ranges ("0.8-1.4,2.2-3"; default two ranges), selected (index, default the last), mode.
    override func applySnapshotOptions(_ options: ToolOptions) {
        let d = source.duration
        var marked = (try? MediaBleep.parseRanges(options["ranges"] ?? "", source: source)) ?? []
        if options["ranges"] == nil {
            marked = [MediaRange(start: source.snap(d * 0.2), end: source.snap(d * 0.36)),
                      MediaRange(start: source.snap(d * 0.56), end: source.snap(d * 0.76))]
        }
        let selected = options["selected"].flatMap(Int.init) ?? (marked.isEmpty ? nil : marked.count - 1)
        setMode(MediaBleep.Mode(rawValue: options.string("mode", "tone")) ?? .tone)
        setRanges(marked, selected: selected.flatMap { $0 >= 0 && $0 < marked.count ? $0 : nil }, action: "Set Ranges")
        undo.removeAllActions()
    }
}

// MARK: - Preview sound

/// What the Bleep window plays: the item's own sound muted inside the ranges (AVAudioMix volume steps, exact to the
/// sample), and in Tone mode a 1 kHz tone there from an AVAudioEngine source node that reads the player's clock.
/// The tone keeps its phase from buffer to buffer and only re-reads the clock when it drifts, so it doesn't click.
final class BleepPreviewAudio {
    private weak var item: AVPlayerItem?
    private var track: AVAssetTrack?
    private var pending: (ranges: [MediaRange], tone: Bool)?
    private var engine: AVAudioEngine?

    /// Shared with the render thread.
    private final class State {
        var lock = os_unfair_lock()
        var ranges: [MediaRange] = []
        var tone = true
        var timebase: CMTimebase?
        var latency: Double = 0
        /// Render thread only: where the next buffer starts, for a continuous phase.
        var next: Double?
    }
    private let state = State()

    init(item: AVPlayerItem) {
        self.item = item
        state.timebase = item.timebase
        item.asset.loadTracks(withMediaType: .audio) { [weak self] tracks, _ in
            let first = tracks?.first
            DispatchQueue.main.async {
                guard let self else { return }
                self.track = first
                if let p = self.pending { self.update(ranges: p.ranges, tone: p.tone) }
            }
        }
    }

    /// The audio mix that mutes the ranges, as applied to the item (for tests).
    var audioMix: AVAudioMix? { item?.audioMix }

    func update(ranges: [MediaRange], tone: Bool) {
        pending = (ranges, tone)
        os_unfair_lock_lock(&state.lock)
        state.ranges = ranges
        state.tone = tone
        os_unfair_lock_unlock(&state.lock)
        guard let item, let track else { return }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.setVolume(1, at: .zero)
        for r in ranges {
            params.setVolume(0, at: CMTime(seconds: r.start, preferredTimescale: 96_000))
            params.setVolume(1, at: CMTime(seconds: r.end, preferredTimescale: 96_000))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
    }

    /// Starts the tone generator (once; it stays silent while the player is paused or outside the ranges).
    func startIfNeeded() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard rate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let state = self.state
        let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let n = Int(frameCount)
            func silence() -> OSStatus {
                for b in buffers { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
                isSilence.pointee = true
                return noErr
            }
            guard os_unfair_lock_trylock(&state.lock) else { return silence() }
            let ranges = state.ranges, tone = state.tone, timebase = state.timebase, latency = state.latency
            os_unfair_lock_unlock(&state.lock)
            guard tone, !ranges.isEmpty, let timebase else { state.next = nil; return silence() }
            let speed = CMTimebaseGetRate(timebase)
            guard speed > 0 else { state.next = nil; return silence() }
            // The sound this buffer holds is heard `latency` from now.
            let clock = CMTimebaseGetTime(timebase).seconds + latency * speed
            let t0 = state.next.flatMap { abs($0 - clock) < 0.03 ? $0 : nil } ?? clock
            let step = speed / rate
            var any = false
            for b in buffers {
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<n {
                    let s = BleepPreviewAudio.toneSample(at: t0 + Double(i) * step, ranges: ranges)
                    if s != 0 { any = true }
                    p[i] = s
                }
            }
            state.next = t0 + Double(n) * step
            isSilence.pointee = ObjCBool(!any)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return }
        os_unfair_lock_lock(&state.lock)
        state.latency = engine.outputNode.presentationLatency
        os_unfair_lock_unlock(&state.lock)
        self.engine = engine
    }

    func stop() {
        engine?.stop()
        engine = nil
        os_unfair_lock_lock(&state.lock)
        state.timebase = nil
        os_unfair_lock_unlock(&state.lock)
    }

    /// The preview tone at time `t`: the same sine `--tool bleep` writes inside a range (phase 0 at its start), 0
    /// outside. `ranges` are sorted and don't overlap.
    static func toneSample(at t: Double, ranges: [MediaRange], frequency: Double = MediaBleep.defaultFrequency) -> Float {
        var lo = 0, hi = ranges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2, r = ranges[mid]
            if t < r.start { hi = mid - 1 } else if t >= r.end { lo = mid + 1 } else {
                return Float(MediaBleep.toneLevel * sin(2 * .pi * frequency * (t - r.start)))
            }
        }
        return 0
    }
}
