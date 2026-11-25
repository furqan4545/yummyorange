import AppKit

/// The audio and video tools built on the media editor kit next to Trim:
/// - Bleep… (an editor window): covers stretches with a tone or silence, sample-exact; video is copied.
/// - Speed… (asks): 0.25× to 4×, with or without keeping the pitch.
/// - Split… (an editor window): splits placed on the timeline (⌘B at the playhead, or evenly), each part an exact
///   trim (" part 1", " part 2"…); the command line also takes equal parts or every N seconds.
/// - Channels… (asks, one file at a time): mono, stereo from mono, swap, left only, right only; video is copied.
/// - Merge (two or more videos, or two or more sounds; runs at once): one new file with every file in the order
///   they were dropped. It takes the slot Channels… has on a one-file wheel (MediaMerge.swift).
/// - Visualize… (asks, audio only): an MP4 of the sound drawn as a waveform, a spectrum or bars.
///
/// Every tool runs from the command line with defaults for every option (`--tool speed --opt factor=2 clip.mp4`),
/// and the app runs the same `run` through JobRunner. The engines live in MediaBleep.swift, MediaSpeedSplit.swift,
/// MediaChannels.swift, MediaMerge.swift and MediaVisualize.swift; `--selftest media-tools` is in MediaToolsTests.swift,
/// the Split window and `--selftest media-split` in MediaSplitEditor.swift and MediaSplitTests.swift, and
/// `--selftest media-merge` in MediaMergeTests.swift.
enum MediaTools: FeatureModule {
    static var commands: [WheelCommand] { [bleep, speed, split, channels, MediaMerge.command, visualize] }

    static let bleep = WheelCommand(
        wheel: .tools, id: "bleep", title: "Bleep…", symbol: symbol("waveform.badge.exclamationmark", or: "speaker.slash"),
        applies: MediaTrim.isMedia,
        present: { MediaEditorWindowController.open($0, editor: BleepEditorController.self) },
        run: perFile { url, options, progress in try MediaBleep.bleep(url, options: options, progress: progress) })

    static let speed = WheelCommand(
        wheel: .tools, id: "speed", title: "Speed…", symbol: symbol("gauge.with.dots.needle.67percent", or: "speedometer"),
        applies: MediaTrim.isMedia, ask: MediaSpeed.ask,
        run: perFile { url, options, progress in try MediaSpeed.speed(url, options: options, progress: progress) })

    static let split = WheelCommand(
        wheel: .tools, id: "split", title: "Split…", symbol: symbol("rectangle.split.3x1", or: "square.split.2x1"),
        applies: MediaTrim.isMedia,
        present: { MediaEditorWindowController.open($0, editor: SplitEditorController.self) },
        run: { files, options, progress in
            var outputs: [URL] = []
            for (i, file) in files.enumerated() {
                outputs += try MediaSplit.split(file, options: options) { progress((Double(i) + $0) / Double(files.count)) }
            }
            return outputs
        })

    static let channels = WheelCommand(
        wheel: .tools, id: "channels", title: "Channels…", symbol: symbol("headphones", or: "speaker.wave.2"),
        applies: { $0.count == 1 && MediaTrim.isMedia($0) }, ask: MediaChannels.ask,
        run: perFile { url, options, progress in try MediaChannels.channels(url, options: options, progress: progress) })

    static let visualize = WheelCommand(
        wheel: .tools, id: "visualize", title: "Visualize…", symbol: symbol("music.note.tv", or: "waveform"),
        applies: isAudio, ask: MediaVisualize.ask,
        run: perFile { url, options, progress in try MediaVisualize.visualize(url, options: options, progress: progress) })

    /// Every file is sound only (no picture), and ffmpeg is installed or YummyOrange can get it. Cheap: file types only.
    static func isAudio(_ files: [URL]) -> Bool {
        Capabilities.shared.mediaAvailable && !files.isEmpty && files.allSatisfy { MoreFormats.kind($0) == .audio }
    }

    /// `name` when this Mac has the symbol, else `fallback` (older systems lack some newer names).
    static func symbol(_ name: String, or fallback: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : fallback
    }

    /// A `run` that handles each file in turn, with progress spread over the files.
    private static func perFile(_ body: @escaping (URL, ToolOptions, @escaping (Double) -> Void) throws -> URL)
        -> ([URL], ToolOptions, @escaping (Double) -> Void) throws -> [URL] {
        { files, options, progress in
            var outputs: [URL] = []
            for (i, file) in files.enumerated() {
                outputs.append(try body(file, options) { progress((Double(i) + $0) / Double(files.count)) })
            }
            return outputs
        }
    }

    /// The probes of the dropped files for a form (main thread; `ffmpeg -i` is quick). Files that can't be read are
    /// left out; nil (after an error in the HUD) when none can.
    static func probeForForm(_ files: [URL], tool: String) -> [MediaSource]? {
        var sources: [MediaSource] = []
        var firstError: Error?
        for url in files {
            do { sources.append(try MediaSource.load(url)) } catch { firstError = firstError ?? error }
        }
        if sources.isEmpty {
            HUD.shared.flash(firstError?.localizedDescription ?? "Drop video or audio files to \(tool) them.", isError: true)
            return nil
        }
        return sources
    }

    /// A number option: `fallback` when it's missing, an error when it's there but isn't a number (a typo
    /// shouldn't quietly become the default).
    static func number(_ options: ToolOptions, _ key: String, _ fallback: Double, example: String) throws -> Double {
        guard let text = options[key]?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return fallback }
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), v.isFinite else {
            throw ConversionError.unsupported("“\(text)” isn’t a number. Give \(key) as a number, for example \(key)=\(example).")
        }
        return v
    }

    /// "clip.mp4" for one file, "3 files" for several.
    static func formMessage(_ files: [URL], _ detail: String) -> String {
        let what = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        return detail.isEmpty ? what : "\(what)\n\n\(detail)"
    }

    // MARK: Snapshot and self-test

    /// `--snapshot bleep <out.png> <video or audio> [--opt ranges=0.8-1.4,2.2-3 selected=1 mode=tone|silence
    /// playhead=… zoom=… width=… height=… dark=true]`
    /// `--snapshot split <out.png> <video or audio> [--opt at=1.2,2.6 selected=1 (the first split) action=split (press
    /// Split at the playhead, to show a refusal) playhead=… zoom=… width=… height=… dark=true]`
    static func snapshot(_ id: String, files: [URL], options: ToolOptions) -> NSView? {
        let editors: [String: MediaEditorWindowController.Type] = ["bleep": BleepEditorController.self, "split": SplitEditorController.self]
        guard let editor = editors[id] else { return nil }
        do {
            guard let url = files.first else { throw ConversionError.unsupported("Pass a video or audio file to snapshot.") }
            return try MediaEditorWindowController.snapshotView(editor, url: url, options: options)
        } catch {
            let label = NSTextField(wrappingLabelWithString: "Snapshot failed: \(error.localizedDescription)")
            label.frame = CGRect(x: 0, y: 0, width: 600, height: 80)
            return label
        }
    }

    static func selfTest(_ name: String) -> String? {
        #if DEBUG
        switch name {
        case "media-tools": return MediaToolsTests.run()
        case "media-split": return MediaSplitTests.run()
        case "media-merge": return MediaMergeTests.run()
        default: return nil
        }
        #else
        return nil
        #endif
    }
}
