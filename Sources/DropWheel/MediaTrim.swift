import AppKit

/// Trim… (video and audio): keeps the part between `start` and `end` seconds, frame-accurately, in the file's own
/// format ("clip trimmed.mp4"). In the app it opens the Trim window (MediaEditorWindowController); on the command line
/// `--tool trim --opt start=1.5 --opt end=3 clip.mp4` does the same.
///
/// How it cuts:
/// - Video is copied without re-encoding only when `start` falls on a key frame (within half a frame), the container
///   is kept and the copy has exactly the frames it should (counted afterwards: copied B-frames can run past the end).
///   Otherwise it is re-encoded with the container's codecs (MediaEncode): the output starts with the first frame at
///   or after `start` and holds every frame that ends by `end`.
/// - Sound is always re-encoded in the file's own format (sample-exact; 24-bit WAV stays 24-bit).
enum MediaTrim: FeatureModule {
    static var commands: [WheelCommand] { [command] }

    static let command = WheelCommand(
        wheel: .tools, id: "trim", title: "Trim…", symbol: "scissors",
        applies: isMedia,
        present: { MediaEditorWindowController.open($0, editor: TrimEditorController.self) },
        run: { files, options, progress in
            var outputs: [URL] = []
            for (i, file) in files.enumerated() {
                outputs.append(try trim(file, options: options) { progress((Double(i) + $0) / Double(files.count)) })
            }
            return outputs
        })

    /// Every file is video or audio, and ffmpeg is installed or YummyOrange can get it. Cheap: file types only.
    static func isMedia(_ files: [URL]) -> Bool {
        Capabilities.shared.mediaAvailable && !files.isEmpty && files.allSatisfy { [.video, .audio].contains(MoreFormats.kind($0)) }
    }

    enum Method: String { case copy, reencode }
    /// How the last trim was written (the self-test checks the fast path is taken when it should be).
    static var lastMethod: Method?

    /// Containers whose video is copied when the cut allows it (the output keeps the container).
    static let copyContainers: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "asf"]

    // MARK: Command

    /// Options: start (seconds, default 0) and end (seconds, default the file's length). Writes "<name> trimmed.<ext>"
    /// (Split passes the source it already probed and where each part goes, `output`).
    static func trim(_ url: URL, options: ToolOptions, suffix: String = " trimmed", source probed: MediaSource? = nil,
                     keyframes: [Double]? = nil, output: URL? = nil, progress: @escaping (Double) -> Void) throws -> URL {
        let ff = try MediaKit.ffmpeg()
        let source = try probed ?? MediaSource.load(url)
        let range = try validatedRange(options, source: source)
        let ext = MediaEncode.outputExtension(for: source)
        let out = output ?? outputURL(for: url, ext: ext, suffix: suffix)

        guard source.hasVideo else {
            try ff.run(input: url, output: out, args: MediaEncode.audioOnlyArgs(for: source, ext: ext, filters: soundCut(source, range: range, ext: ext)),
                       duration: range.length, inputOptions: soundInputOptions(source, range: range), progress: progress)
            lastMethod = .reencode
            return out
        }
        // Video cuts fall on frame boundaries: both times are rounded to the nearest frame start.
        let cut = frameRange(range, source: source)
        if try copyTrim(source, range: cut, ext: ext, to: out, ff: ff, progress: progress) {
            lastMethod = .copy
            return out
        }
        // A cut inside a still the file holds starts with that still (the frame on screen at the cut), read from
        // before it.
        let held = heldFrame(source, at: cut.start)
        let seek = seekPoint(source, start: held ?? cut.start, keyframes: keyframes)
        try ff.run(input: url, output: out, args: reencodeArgs(source, range: cut, seek: seek, ext: ext, held: held),
                   duration: cut.length, inputOptions: reencodeInputOptions(source, range: cut, seek: seek), progress: progress)
        lastMethod = .reencode
        return out
    }

    /// The start of the frame on screen at `t` when it began more than a frame and a half before `t`: a still the
    /// file holds across the cut, as variable-rate screen and phone recordings hold a still screen. nil when a frame
    /// starts at the cut. Without it, a part (or a trim) that starts inside such a still showed no picture until the
    /// next frame came, seconds later for a still screen. Constant-rate MP4 and MOV files (average rate = base rate)
    /// hold none and aren't read; others are decoded around `t` (`MediaSnapshot.frameTime`).
    static func heldFrame(_ source: MediaSource, at t: Double) -> Double? {
        let fd = source.frameDuration
        guard source.hasVideo, t > source.videoStart + 1.5 * fd else { return nil }
        if ["mp4", "m4v", "mov"].contains(source.ext), let average = source.probe.fps, let base = source.probe.tbr,
           abs(average - base) < 0.01 { return nil }
        guard let shown = try? MediaSnapshot.frameTime(source, at: t), shown < t - 1.5 * fd else { return nil }
        return shown
    }

    /// `range` with both ends on frame starts (`MediaSource.snap`); an end at (or within a millisecond of) the
    /// file's length stays there, so nothing at the end is lost.
    static func frameRange(_ range: MediaRange, source: MediaSource) -> MediaRange {
        let start = source.snap(range.start)
        let end = range.end >= source.duration - 0.001 ? source.duration : source.snapEnd(range.end)
        return MediaRange(start: start, end: max(end, min(source.duration, start + source.frameDuration)))
    }

    /// Where ffmpeg starts reading for a cut at `start`: half a second early (a fast seek; the filters make it exact),
    /// and in a container without an index before the key frame the decoder needs (`MediaKit.seekBefore`: a cut from
    /// the middle of a long GOP in a .ts or .vob lost up to a GOP of picture, and the rest slid ahead of the sound).
    static func seekPoint(_ source: MediaSource, start: Double, keyframes: [Double]? = nil) -> Double {
        max(0, min(start - 0.5, MediaKit.seekBefore(source, start, keyframes: keyframes)))
    }

    /// Where ffmpeg starts reading (`seek`, from `seekPoint`), and how much it reads, so it stops soon after the end.
    /// No `-ss` at all for a seek to 0: in an FLV it landed seconds into the file (part 1 of a split lost its picture),
    /// and an AAC or Opus decoder seeked to 0 drops its first packet (20 ms of sound).
    private static func reencodeInputOptions(_ source: MediaSource, range: MediaRange, seek: Double) -> [String] {
        var options = seek > 0 ? ["-ss", MediaTime.arg(seek)] : []
        if range.end < source.duration { options += ["-t", MediaTime.arg(range.end - seek + 1)] }
        return options
    }

    // MARK: Sound alone

    /// Where a cut of sound alone starts reading: half a second before the cut, so decoders that need what comes
    /// before (MP3's bit reservoir, AAC's and WMA's overlapping blocks) are ready by the cut; a seek straight to it
    /// left 20–30 ms of silence at the start of every part after the first. Nothing for a cut near the start.
    static func soundSeek(_ start: Double) -> Double { start > 0.5 ? start - 0.5 : 0 }

    private static func soundInputOptions(_ source: MediaSource, range: MediaRange) -> [String] {
        let seek = soundSeek(range.start)
        var options = seek > 0 ? ["-ss", MediaTime.arg(seek)] : []
        if range.end < source.duration { options += ["-t", MediaTime.arg(range.end - seek + 1)] }
        return options
    }

    /// The exact cut of sound alone, on timestamps that start at the seek point: `atrim` keeps the samples in the
    /// range, moved to start at 0, then the encoder's pre-roll (`encoderPreroll`).
    static func soundCut(_ source: MediaSource, range: MediaRange, ext: String) -> [String] {
        let seek = soundSeek(range.start)
        var atrim = "atrim=start=\(MediaTime.arg(range.start - seek))"
        if range.end < source.duration { atrim += ":end=\(MediaTime.arg(range.end - seek))" }
        return [atrim, "asetpts=PTS-STARTPTS"] + encoderPreroll(source, ext: ext)
    }

    /// ffmpeg's WMA encoder drops the first block it is given (2048 samples at 44.1 and 48 kHz: 46 ms), so every
    /// trimmed .wma and every part of a split lost its first 46 ms. That much silence in front is what it drops.
    static func encoderPreroll(_ source: MediaSource, ext: String) -> [String] {
        guard ["wma", "asf", "wmv"].contains(ext) else { return [] }
        let input = source.sampleRate ?? 44_100, rate = min(input, 48_000)     // WMA stops at 48 kHz (wmaRate)
        let block = rate <= 16_000 ? 512 : rate <= 22_050 ? 1024 : 2048
        // In samples at the rate the filter sees (the source's), for the block at the rate the encoder sees.
        return ["adelay=delays=\(Int((Double(block) * Double(input) / Double(rate)).rounded()))S:all=1"]
    }

    /// The exact cut as filters, on timestamps that start at the seek point: `select` keeps the frames whose start
    /// lies within half a frame of the range (so timestamp rounding can't add or drop one; `trim` would also keep a
    /// frame that merely overlaps the start) and `atrim` the samples in it. Both are moved to start at 0; a first
    /// frame that comes after the cut (wmv files start at 0.046 s) keeps its distance from the sound.
    private static func reencodeArgs(_ source: MediaSource, range: MediaRange, seek: Double, ext: String, held: Double? = nil) -> [String] {
        let fd = source.frameDuration
        let toEnd = range.end >= source.duration
        let a = range.start - seek, b = range.end - seek
        // A still held across the cut (`heldFrame`) is kept too: it is the first frame, at 0 (setpts below).
        let first = held.map { $0 - seek - 0.0005 } ?? (a - fd / 2)
        var trim = "select=gte(t\\,\(MediaTime.arg(first)))"
        if !toEnd { trim += "*lt(t\\,\(MediaTime.arg(b - fd / 2)))" }
        // The first kept frame keeps its distance from the cut, as the sound does (atrim starts it at the cut): a
        // wmv's first frame at 0.046 s, or a frame after a gap in a variable-rate recording (a cut inside a 0.5 s
        // still put the next frame at 0 and the picture ran 342 ms ahead of its sound). A frame up to half a frame
        // before the cut (timestamps rounded to milliseconds), or a still held across it, starts at 0.
        let setpts = "setpts=max(0\\,PTS-\(MediaTime.arg(a))/TB)"
        var atrim = "atrim=start=\(MediaTime.arg(a))"
        if !toEnd { atrim += ":end=\(MediaTime.arg(b))" }
        // Sound that starts after the cut (a video whose sound begins late) is padded first, so it keeps its place
        // under the picture instead of moving to the start.
        return MediaEncode.videoArgs(for: source, ext: ext, videoFilters: [trim, setpts],
                                     audioFilters: MediaKit.soundFromZero(source, seek: seek) + [atrim, "asetpts=PTS-STARTPTS"])
    }

    /// The range from the options, checked against the file: a clear message for a start after the end, a time
    /// past the end, or a negative or missing number. An end within 1.5 ms of the length counts as the length.
    static func validatedRange(_ options: ToolOptions, source: MediaSource) throws -> MediaRange {
        let duration = source.duration
        guard duration > 0 else {
            throw ConversionError.unsupported("\(source.name) reports no length, so it can’t be trimmed. Convert it first, then trim the copy.")
        }
        // Seconds ("1.5", "1,5") or the m:ss.ff the window shows ("1:30.00"); anything else is an error rather than
        // quietly becoming the default (start=1:30 used to trim from 0).
        func time(_ key: String, _ fallback: Double) throws -> Double {
            guard let text = options[key]?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return fallback }
            if let t = MediaTime.parse(text) { return t }
            if let v = Double(text.replacingOccurrences(of: ",", with: ".")) { return v }
            throw ConversionError.unsupported("“\(text)” isn’t a time. Give \(key) in seconds or as m:ss.ff, for example \(key)=1.5 or \(key)=1:30.")
        }
        var start = try time("start", 0), end = try time("end", duration)
        guard start.isFinite, end.isFinite else {
            throw ConversionError.unsupported("Give the start and end in seconds, for example start=1.5 end=3.")
        }
        guard start >= 0 else { throw ConversionError.unsupported("The start can’t be before 0:00.00. Choose a start of 0 or later.") }
        if end > duration, end - duration <= 0.0015 { end = duration }
        guard end <= duration else {
            throw ConversionError.unsupported("The end (\(MediaTime.string(end))) is past the end of \(source.name) "
                                              + "(\(MediaTime.string(duration))). Choose an end of \(MediaTime.string(duration)) or less.")
        }
        guard start < end else {
            throw ConversionError.unsupported("The start (\(MediaTime.string(start))) must be before the end (\(MediaTime.string(end))). "
                                              + "Choose a start earlier than the end.")
        }
        start = max(0, start)
        let minimum = source.hasVideo ? source.frameDuration * 0.5 : 0.001
        guard end - start >= minimum else {
            throw ConversionError.unsupported("The part to keep is shorter than \(source.hasVideo ? "one frame" : "a millisecond"). "
                                              + "Choose an end later than the start.")
        }
        return MediaRange(start: start, end: end)
    }

    /// The fast path: copy the video from the key frame at `start` and re-encode only the sound. Returns false (and
    /// leaves nothing behind) when the cut isn't on a key frame, the container changes, or the copy's frame count is
    /// off (B-frames copied past the end), so the caller re-encodes instead.
    private static func copyTrim(_ source: MediaSource, range: MediaRange, ext: String, to out: URL, ff: FFmpeg,
                                 progress: @escaping (Double) -> Void) throws -> Bool {
        guard ext == source.ext, copyContainers.contains(ext) else { return false }
        let fd = source.frameDuration
        let keys = MediaKit.keyframes(source, upTo: range.start + fd)
        guard let key = keys.first(where: { abs($0 - range.start) <= fd * 0.5 }) else { return false }
        // The sound comes from a second reading of the file that starts half a second earlier and is cut exactly
        // with atrim: read from the key frame itself, the first Opus packet of a WebM was lost (20 ms), and a
        // seek to 0 does that too, so a cut at 0 reads from the start without one.
        let soundSeek = soundSeek(key)
        var args: [String] = []
        if source.hasAudio { args += (soundSeek > 0 ? ["-ss", MediaTime.arg(soundSeek)] : []) + ["-i", source.url.path] }
        args += ["-t", MediaTime.arg(range.end - key), "-map", "0:v:0"] + (source.hasAudio ? ["-map", "1:a:0"] : [])
        args += ["-c:v", "copy"]
        if source.videoCodec == "hevc", MediaEncode.isISO(ext) { args += ["-tag:v", "hvc1"] }
        var atrim = "atrim=start=\(MediaTime.arg(key - soundSeek))"
        if range.end < source.duration { atrim += ":end=\(MediaTime.arg(range.end - soundSeek))" }
        let sound = MediaKit.soundFromZero(source, seek: soundSeek) + [atrim, "asetpts=PTS-STARTPTS"]
        args += source.hasAudio ? MediaEncode.audioCodecArgs(for: source, ext: ext, filters: sound) : ["-an"]
        args += MediaEncode.containerArgs(ext)
        do {
            try ff.run(input: source.url, output: out, args: args, duration: range.end - key,
                       inputOptions: key > 0 ? ["-ss", MediaTime.arg(key)] : [], progress: { progress($0 * 0.9) })
        } catch {
            try? FileManager.default.removeItem(at: out)
            return false
        }
        // Frames that should be there: those starting at the key frame and ending by `end`, as far as the file goes.
        let total = MediaKit.videoPacketCount(source.url) ?? Int.max
        let keyIndex = Int(((key - source.videoStart) / fd).rounded())
        let wanted = min(max(0, total - keyIndex), Int(((range.end - key) / fd + 0.01).rounded(.down)))
        guard let got = MediaKit.videoPacketCount(out), got == wanted else {
            try? FileManager.default.removeItem(at: out)
            return false
        }
        return true
    }

    // MARK: Snapshot and self-test

    /// `--snapshot trim <out.png> <video or audio> [--opt start=… end=… playhead=… zoom=… width=… height=… dark=true]`
    static func snapshot(_ id: String, files: [URL], options: ToolOptions) -> NSView? {
        guard id == "trim" else { return nil }
        do {
            guard let url = files.first else { throw ConversionError.unsupported("Pass a video or audio file to snapshot.") }
            return try MediaEditorWindowController.snapshotView(TrimEditorController.self, url: url, options: options)
        } catch {
            let label = NSTextField(wrappingLabelWithString: "Snapshot failed: \(error.localizedDescription)")
            label.frame = CGRect(x: 0, y: 0, width: 600, height: 80)
            return label
        }
    }

    static func selfTest(_ name: String) -> String? {
        #if DEBUG
        name == "media-trim" ? MediaTrimTests.run() : nil
        #else
        return nil
        #endif
    }
}

// MARK: - Window

/// The Trim window: one in/out range over the film strip and waveform, Set Start / Set End in the toolbar (I and O),
/// exact start and end fields in the transport bar, and Save, which writes "<name> trimmed.<ext>" from the original.
final class TrimEditorController: MediaEditorWindowController {
    override class var toolName: String { "Trim" }
    override var command: WheelCommand? { MediaTrim.command }
    override var timelineMode: MediaTimelineView.Mode { .single }
    override var discardMessage: String { "The trim you set for \(source.name) hasn’t been saved." }
    override var saveToolTip: String { "Save a trimmed copy next to the original (⌘S)" }

    private let startField = MediaTimeField(label: "Start")
    private let endField = MediaTimeField(label: "End")
    private let lengthLabel = NSTextField(labelWithString: "")

    var range: MediaRange { ranges.first ?? MediaRange(start: 0, end: source.duration) }

    override func makeOptions() throws -> ToolOptions {
        ["start": MediaTime.arg(range.start), "end": MediaTime.arg(range.end)]
    }

    override func makeToolItems() -> [NSToolbarItem] {
        let group = NSToolbarItemGroup(itemIdentifier: .init("trim.setEdges"), titles: ["Set Start", "Set End"],
                                       selectionMode: .momentary, labels: ["Set Start", "Set End"],
                                       target: self, action: #selector(setEdge(_:)))
        group.subitems[0].toolTip = "Start the trim at the playhead (I)"
        group.subitems[1].toolTip = "End the trim after the frame at the playhead (O)"
        group.label = "Set Start or End"
        return [group]
    }

    override func makeTransportAccessory() -> NSView? {
        for field in [startField, endField] {
            field.target = self
            field.action = #selector(fieldCommitted(_:))
        }
        lengthLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        lengthLabel.textColor = .secondaryLabelColor
        lengthLabel.setAccessibilityLabel("Length")
        lengthLabel.alignment = .right
        lengthLabel.translatesAutoresizingMaskIntoConstraints = false
        lengthLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true
        let stack = NSStackView(views: [startField.labelView, startField, endField.labelView, endField, lengthLabel])
        for v in stack.arrangedSubviews { v.setContentCompressionResistancePriority(.required, for: .horizontal) }
        stack.spacing = 6
        stack.setCustomSpacing(16, after: startField)
        stack.setCustomSpacing(14, after: endField)
        return stack
    }

    override func rangesDidChange(live: Bool) {
        if !live { show(range) }
    }

    override func updateLiveReadouts(_ live: [MediaRange]) {
        if let r = live.first { show(r) }
    }

    private func show(_ r: MediaRange) {
        if startField.currentEditor() == nil { startField.stringValue = MediaTime.string(r.start) }
        if endField.currentEditor() == nil { endField.stringValue = MediaTime.string(r.end) }
        lengthLabel.stringValue = "Length " + MediaTime.lengthString(r.length)
    }

    override func applySnapshotOptions(_ options: ToolOptions) {
        let start = source.snap(options.double("start", 0)), end = source.snapEnd(options.double("end", source.duration))
        if start < end { setRanges([MediaRange(start: start, end: end)], selected: 0, action: "Set Range") }
        undo.removeAllActions()
    }

    @objc private func setEdge(_ sender: NSToolbarItemGroup) {
        sender.selectedIndex == 0 ? setInPoint() : setOutPoint()
    }

    /// A start or end typed in: snapped to a frame and checked; a time that doesn't fit beeps and is put back.
    @objc private func fieldCommitted(_ sender: MediaTimeField) {
        guard let typed = MediaTime.parse(sender.stringValue) else { refusedEdit = true; NSSound.beep(); show(range); return }
        var r = range
        let fd = source.frameDuration
        let t = sender === startField ? source.snap(min(typed, source.duration)) : source.snapEnd(min(typed, source.duration))
        if sender === startField {
            guard t < r.end - fd / 2 else { refusedEdit = true; NSSound.beep(); show(range); return }
            r.start = t
        } else {
            guard t > r.start + fd / 2 else { refusedEdit = true; NSSound.beep(); show(range); return }
            r.end = t
        }
        if r == range { show(range); return }
        setRanges([r], selected: 0, action: sender === startField ? "Set Start" : "Set End")
        scrub(to: sender === startField ? r.start : max(r.start, source.snap(r.end - fd)))
    }
}
