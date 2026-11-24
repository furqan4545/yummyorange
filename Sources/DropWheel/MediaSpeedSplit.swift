import AppKit

// MARK: - Speed

/// Speed… : plays a video or audio file faster or slower, in its own format ("clip 2x.mp4").
/// - Sound keeps its pitch with an `atempo` chain (each step within 0.5…2, so older ffmpeg builds work too), or
///   changes pitch with it, like a tape (`asetrate` + `aresample`), when "Keep pitch" is off.
/// - Picture: `setpts=PTS/S`, then `fps` back to the source's constant rate, so a 2× clip drops every other frame
///   and a 0.5× clip shows each frame twice; the frame rate stays what it was.
enum MediaSpeed {
    /// The speeds the form offers (the command line takes any factor from 0.25 to 4 other than 1).
    static let choices: [Double] = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 4]

    static func title(_ factor: Double) -> String { "\(Ask.formatNumber(factor))×" }

    static func ask(_ files: [URL]) -> ToolOptions? {
        let last = ImageExtras.remembered("speed")
        let lastFactor = ImageExtras.rememberedNumber(last, "factor", 2)
        let selected = choices.contains(lastFactor) ? title(lastFactor) : title(2)
        guard let answer = Ask.form(title: "Change Speed",
                                    message: MediaTools.formMessage(files, "Faster or slower, in the same format."),
                                    fields: [.choice(key: "factor", label: "Speed:", options: choices.map(title), selected: selected),
                                             .toggle(key: "keep_pitch", label: "Keep pitch", on: last.bool("keep_pitch", true))],
                                    button: "Change Speed") else { return nil }
        let factor = choices.first { title($0) == answer["factor"] } ?? 2
        let options: ToolOptions = ["factor": Ask.formatNumber(factor), "keep_pitch": answer["keep_pitch"] ?? "true"]
        ImageExtras.remember(options, as: "speed")
        return options
    }

    /// Options: factor (0.25…4, not 1; default 2) and keep_pitch (default true). Writes "<name> <factor>x.<ext>".
    static func speed(_ url: URL, options: ToolOptions, progress: @escaping (Double) -> Void) throws -> URL {
        let ff = try MediaKit.ffmpeg()
        let source = try MediaSource.load(url)
        let factor = try MediaTools.number(options, "factor", 2, example: "2")
        guard factor.isFinite, factor >= 0.25 - 1e-9, factor <= 4 + 1e-9 else {
            throw ConversionError.unsupported("Choose a speed from 0.25× to 4×, for example factor=2.")
        }
        guard abs(factor - 1) > 0.001 else {
            throw ConversionError.unsupported("A speed of 1× changes nothing. Choose a faster or slower speed, for example factor=2.")
        }
        guard source.duration > 0 else {
            throw ConversionError.unsupported("The file reports no length, so its speed can’t be changed. Convert it first.")
        }
        let keepPitch = options.bool("keep_pitch", true)
        let ext = MediaEncode.outputExtension(for: source)
        let out = outputURL(for: url, ext: ext, suffix: " \(Ask.formatNumber(factor))x")
        let audioFilters = source.hasAudio
            ? audioFilters(factor, keepPitch: keepPitch, sampleRate: source.sampleRate ?? 48_000, length: source.duration) : []
        let args: [String]
        if source.hasVideo {
            let video = ["setpts=PTS/\(number(factor))", "fps=\(source.probe.constantRate)"]
            // The tempo filters keep the sound's first time as it was, so sound that starts late (at 0.5 s under the
            // picture) would still start at 0.5 s at 2×. Padded from 0 first, its start scales with the picture.
            let sound = source.hasAudio ? MediaKit.soundFromZero(source) + audioFilters : []
            args = MediaEncode.videoArgs(for: source, ext: ext, videoFilters: video, audioFilters: sound)
        } else {
            args = MediaEncode.audioOnlyArgs(for: source, ext: ext, filters: audioFilters)
        }
        try ff.run(input: url, output: out, args: args, duration: source.duration / factor, progress: progress)
        return out
    }

    /// `atempo` steps (each within 0.5…2) whose product is `factor`, or a tape-style rate change. `atempo` leaves
    /// out its last part-filled block (23 ms a step), so the sound is padded a little first and cut back to
    /// `length / factor` after.
    static func audioFilters(_ factor: Double, keepPitch: Bool, sampleRate: Int, length: Double? = nil) -> [String] {
        guard keepPitch else {
            return ["asetrate=\(number(Double(sampleRate) * factor))", "aresample=\(sampleRate)"]
        }
        let steps = tempoSteps(factor)
        let tempo = steps.map { "atempo=\(number($0))" }
        guard let length, length > 0 else { return tempo }
        return ["apad=pad_dur=\(number(0.1 * Double(steps.count)))"] + tempo + ["atrim=end=\(MediaTime.arg(length / factor))"]
    }

    static func tempoSteps(_ factor: Double) -> [Double] {
        var rest = factor, steps: [Double] = []
        while rest > 2 + 1e-9 { steps.append(2); rest /= 2 }
        while rest < 0.5 - 1e-9 { steps.append(0.5); rest /= 0.5 }
        steps.append(rest)
        return steps
    }

    static func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.6g", v)
    }
}

// MARK: - Split

/// Split… : cuts a video or audio file into parts, each an exact trim made by Trim's engine ("clip part 1.mp4",
/// "clip part 2.mp4"…), so the parts meet on the same frame boundary and nothing is lost or repeated.
/// In the app it opens the Split window (SplitEditorController, MediaSplitEditor.swift), where splits are placed on
/// the timeline; Save runs this same code with `at=` (the split times). On the command line:
/// - `at=1.5,3.25` (seconds or m:ss.ff, separated by commas): split at those times. A video split goes on the nearest
///   frame start; sound is split on the nearest sample. Times are sorted and repeats dropped; every part keeps at
///   least one frame (0.01 s of sound), and no split may come after the last frame.
/// - `mode=parts parts=3`: 2 to 20 parts of the same length (video: on the frame grid, so lengths differ by at most
///   a frame).
/// - `mode=every seconds=10`: parts of that length; the last is what remains. A remainder shorter than half the length
///   (and under half a second) joins the last part instead of making a tiny one.
///
/// The parts are written into a temporary folder on the same disk and moved next to the original only when every
/// one of them was written and has a picture or sound in it, under one free set of names ("clip part 1…", else
/// "clip 2 part 1…"): all parts or none, also when the app quits half way.
enum MediaSplit {
    enum Mode: String { case parts, every, at }
    static let maxParts = 100

    /// Options: at (split times; implies mode=at), or mode (parts | every, default parts), parts (2–20, default 2),
    /// seconds (default 10). Writes "<name> part 1.<ext>", "<name> part 2.<ext>"… All parts or none.
    static func split(_ url: URL, options: ToolOptions, progress: @escaping (Double) -> Void) throws -> [URL] {
        _ = try MediaKit.ffmpeg()
        let source = try MediaSource.load(url)
        let ranges = try parts(source, options: options)
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: folder.path) else {
            throw ConversionError.unsupported("YummyOrange can’t write to the folder “\(folder.lastPathComponent)”, so the parts can’t be saved "
                                              + "next to \(source.name). Copy the file to a folder you can write to, then split the copy.")
        }
        let ext = MediaEncode.outputExtension(for: source)
        let finals = partURLs(for: url, ext: ext, count: ranges.count)
        // Written on the same disk (so moving them is instant) but out of sight until they are all there.
        let staging = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true))
            ?? folder.appendingPathComponent(".yummyorange-split-\(UUID().uuidString)")
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        // A container without an index needs the key frames before each cut (MediaTrim.seekPoint): read them once.
        let keyframes = source.hasVideo && MediaKit.unindexedContainers.contains(source.ext)
            ? MediaKit.keyframes(source, upTo: (ranges.last?.start ?? 0) + source.frameDuration) : nil
        var written: [URL] = []
        do {
            for (k, r) in ranges.enumerated() {
                let staged = staging.appendingPathComponent(finals[k].lastPathComponent)
                _ = try MediaTrim.trim(url, options: ["start": MediaTime.arg(r.start), "end": MediaTime.arg(r.end)],
                                       source: source, keyframes: keyframes, output: staged) { p in
                    progress((Double(k) + p) * 0.99 / Double(ranges.count))
                }
                guard hasContent(staged, video: source.hasVideo) else {
                    throw ConversionError.unsupported("Part \(k + 1) of \(source.name) (from \(MediaTime.string(r.start))) came out empty: "
                                                      + "the file has no picture or sound there, though it says it runs to "
                                                      + "\(MediaTime.string(source.duration)). Move the last split earlier, or repair the file first.")
                }
            }
            for final in finals {
                try fm.moveItem(at: staging.appendingPathComponent(final.lastPathComponent), to: final)
                written.append(final)
            }
        } catch {
            // All parts or none: a half-split file is confusing.
            for part in written { try? fm.removeItem(at: part) }
            throw friendly(error, folder: folder)
        }
        progress(1)
        return written
    }

    /// Where the parts go: "<name> part 1.<ext>"… when none of them exists yet, else the first "<name> 2 part 1…",
    /// "<name> 3 part 1…" set that is free throughout, so a new set never mixes with an older one.
    static func partURLs(for url: URL, ext: String, count: Int) -> [URL] {
        let dir = url.deletingLastPathComponent(), name = url.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        var n = 1
        while true {
            let base = n == 1 ? name : "\(name) \(n)"
            let urls = (1...max(1, count)).map { dir.appendingPathComponent("\(base) part \($0)").appendingPathExtension(ext) }
            if urls.allSatisfy({ !fm.fileExists(atPath: $0.path) }) { return urls }
            n += 1
        }
    }

    /// Whether a part has a picture (a video packet) or, failing that, sound that decodes.
    static func hasContent(_ url: URL, video: Bool) -> Bool {
        if video, (MediaKit.videoPacketCount(url) ?? 0) > 0 { return true }
        guard let ff = FFmpeg.shared,
              let r = try? ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", url.path, "-map", "0:a:0",
                                                       "-t", "1", "-ac", "1", "-f", "s16le", "-"]) else { return false }
        return r.status == 0 && !r.stdout.isEmpty
    }

    /// ffmpeg's own words for a full disk or a folder it can't write to, as a sentence that says what to do.
    static func friendly(_ error: Error, folder: URL) -> Error {
        let text = error.localizedDescription
        if ["No space left", "File too large", "Disk quota exceeded"].contains(where: { text.localizedCaseInsensitiveContains($0) })
            || text.contains("status 25") {
            return ConversionError.unsupported("There isn’t enough space on the disk for the parts, so none were saved. "
                                               + "Free some space on the disk that holds “\(folder.lastPathComponent)”, then split again.")
        }
        if text.localizedCaseInsensitiveContains("Permission denied") || text.localizedCaseInsensitiveContains("not permitted") {
            return ConversionError.unsupported("YummyOrange can’t write to the folder “\(folder.lastPathComponent)”, so no parts were saved. "
                                               + "Copy the file to a folder you can write to, then split the copy.")
        }
        return error
    }

    /// The parts' ranges, in seconds, covering the whole file.
    static func parts(_ source: MediaSource, options: ToolOptions) throws -> [MediaRange] {
        let duration = source.duration
        guard duration > 0 else {
            throw ConversionError.unsupported("The file reports no length, so it can’t be split. Convert it first, then split the copy.")
        }
        let atText = options["at"]?.trimmingCharacters(in: .whitespaces)
        let modeText = (options["mode"] ?? (atText == nil ? Mode.parts.rawValue : Mode.at.rawValue)).lowercased()
        guard let mode = Mode(rawValue: modeText) else {
            throw ConversionError.unsupported("Choose mode=parts or mode=every, or give the split times with at=1.5,3 (not “\(modeText)”).")
        }
        if mode != .at, let atText, !atText.isEmpty {
            throw ConversionError.unsupported("Give either the split times (at=…) or mode=\(mode.rawValue), not both.")
        }
        let shortest = shortestPart(source)
        var cuts: [Double] = []
        switch mode {
        case .at:
            cuts = try cutTimes(atText ?? "", source: source)
        case .parts:
            let n = try MediaTools.number(options, "parts", 2, example: "3")
            guard n.isFinite, n == n.rounded(), (2...20).contains(Int(n)) else {
                throw ConversionError.unsupported("Choose 2 to 20 parts, for example parts=3.")
            }
            let count = Int(n)
            guard duration / Double(count) >= shortest else {
                throw ConversionError.unsupported("The file is too short for \(count) parts. Choose fewer parts.")
            }
            cuts = evenCuts(duration: duration, count: count)
        case .every:
            let length = try MediaTools.number(options, "seconds", 10, example: "10")
            guard length.isFinite, length >= max(0.1, shortest) else {
                throw ConversionError.unsupported("Choose a part length of at least 0.1 seconds, for example seconds=10.")
            }
            guard length < duration - 0.001 else {
                throw ConversionError.unsupported("The file is only \(MediaTime.lengthString(duration)) long, so parts of "
                                                  + "\(MediaTime.lengthString(length)) would leave it whole. Choose a shorter length.")
            }
            // Count before listing the cuts: a file can claim to be years long, and 0.1 s parts of that are billions.
            guard let every = everyCuts(duration: duration, length: length) else {
                throw ConversionError.unsupported("That would make more than \(maxParts) parts; Split makes at most \(maxParts). Choose a longer length.")
            }
            cuts = every
        }
        let edges = [0] + cuts + [duration]
        return zip(edges, edges.dropFirst()).map { MediaRange(start: $0, end: $1) }
    }

    // MARK: Split times (shared with the window)

    /// The shortest part Split makes: one frame, or 0.01 s of sound.
    static func shortestPart(_ source: MediaSource) -> Double { source.hasVideo ? source.frameDuration : 0.01 }

    /// How far a split may be inside the limits and still count: sound split times go on the nearest sample, which
    /// moves a time on the window's 0.01 s grid by up to half a sample at each end (1.23 s at 22.05 kHz is sample
    /// 27121.5), so up to one sample is allowed; video times are on the frame grid already.
    static func slack(_ source: MediaSource) -> Double {
        guard !source.hasVideo, let rate = source.sampleRate, rate > 0 else { return 1e-6 }
        return 1 / Double(rate) + 1e-6
    }

    /// The first and last place a split can go so the first and last parts keep at least one frame (the second
    /// frame's start; the last frame's start, as the End key finds it) or 0.01 s of sound. `lastFrame`, when known
    /// (`lastFrameStart`), is where the picture really ends: sample.wmv's sound runs 44 ms past its last frame.
    /// nil when the file is too short to split.
    static func cutBounds(_ source: MediaSource, lastFrame: Double? = nil) -> ClosedRange<Double>? {
        let d = source.duration
        guard d > 0, d.isFinite else { return nil }
        let lo: Double, hi: Double
        if source.hasVideo {
            lo = source.videoStart + source.frameDuration
            hi = min(source.snap(d - source.frameDuration), lastFrame ?? .infinity)
        } else {
            lo = 0.01
            hi = d - 0.01
        }
        return lo <= hi + 1e-9 ? lo...max(lo, hi) : nil
    }

    /// The start of the last video frame the file really has, read from the frames at its end (the frame on screen
    /// at the end, `MediaSnapshot.frameTime`; it decodes only the last seconds, further back only for a long still):
    /// the frame grid can reach past it when the sound runs longer than the picture, and a split there made an empty
    /// last part. Not frame count × frame length: a variable-rate WebM or MKV that reports its nominal rate (30 fps)
    /// while frames are missing would end that way seconds early, and the end of the file couldn't be split.
    /// nil for sound, or when no frame can be read.
    static func lastFrameStart(_ source: MediaSource) -> Double? {
        guard source.hasVideo, let t = try? MediaSnapshot.frameTime(source, at: source.duration) else { return nil }
        return source.snap(t)
    }

    /// A split time on the grid the parts are cut on: the nearest frame start (video), or the nearest sample (sound).
    static func normalize(_ t: Double, source: MediaSource) -> Double {
        if source.hasVideo { return source.snap(t) }
        guard let rate = source.sampleRate, rate > 0 else { return t }
        return (t * Double(rate)).rounded() / Double(rate)
    }

    /// The start of the frame on screen at `t` (a paused player can sit part way into a frame): where the window's
    /// Split puts a split, so the frame you see starts the next part. Sound: the nearest 1/100 s, as the playhead.
    static func frameStart(at t: Double, source: MediaSource) -> Double {
        guard source.hasVideo else { return source.snap(t) }
        let fd = source.frameDuration
        guard t >= source.videoStart else { return source.videoStart }
        let n = ((t - source.videoStart) / fd + 1e-5).rounded(.down)
        return min(source.videoStart + n * fd, source.duration)
    }

    /// nil when `cuts` (sorted, on the grid) leave every part at least `shortestPart` long, end by the last frame and
    /// make at most `maxParts` parts; otherwise a sentence that says which split is wrong and what to do. `typed` are
    /// the times as given (quoted with the frame they went to when that differs).
    static func problem(_ cuts: [Double], source: MediaSource, typed: [String]? = nil, lastFrame: Double? = nil) -> String? {
        let what = source.hasVideo ? "one frame" : "0.01 seconds"
        guard cuts.count + 1 <= maxParts else {
            return "That would make \(cuts.count + 1) parts; Split makes at most \(maxParts). Give fewer times."
        }
        guard let bounds = cutBounds(source, lastFrame: lastFrame) else {
            return "\(source.name) is too short to split: it has less than two \(source.hasVideo ? "frames" : "hundredths of a second")."
        }
        let slack = slack(source)
        let gap = shortestPart(source) - slack
        for (i, t) in cuts.enumerated() {
            var name = MediaTime.string(t)
            if let typed, i < typed.count, typed[i] != name {
                name = "\(typed[i]) (\(source.hasVideo ? "the frame at " : "")\(MediaTime.string(t)))"
            }
            if let lastFrame, t > lastFrame + slack, t <= (cutBounds(source)?.upperBound ?? 0) + slack {
                return "The split at \(name) comes after the last frame of \(source.name) (\(MediaTime.string(lastFrame))), so its part "
                    + "would have no picture. Give a time up to \(MediaTime.string(lastFrame))."
            }
            let tooEarly = t < bounds.lowerBound - slack, tooLate = t > bounds.upperBound + slack
            let tooClose = i > 0 && t - cuts[i - 1] < gap
            if tooEarly || tooLate || tooClose {
                return "The split at \(name) leaves a part shorter than \(what). "
                    + "Keep at least \(what) between splits and from either end."
            }
        }
        return nil
    }

    /// Split times from an `at` option: times in seconds or m:ss.ff, separated by commas (or semicolons or spaces),
    /// each inside the file; put on the grid, sorted, with repeats dropped, and checked with `problem` (with the
    /// file's real last frame when a split is near the end; the window passes it when it has read it).
    static func cutTimes(_ text: String, source: MediaSource, lastFrame known: Double? = nil, quoteTyped: Bool = true) throws -> [Double] {
        let tokens = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }).map(String.init)
        guard !tokens.isEmpty else {
            throw ConversionError.unsupported("Give the times to split at, for example at=1.5,3.25 (seconds or m:ss.ff).")
        }
        guard tokens.count < maxParts * 4 else {
            throw ConversionError.unsupported("That’s \(tokens.count) split times; Split makes at most \(maxParts) parts. Give fewer times.")
        }
        var cuts: [(t: Double, typed: String)] = []
        for token in tokens {
            guard let t = MediaTime.parse(token) ?? Double(token), t.isFinite else {
                throw ConversionError.unsupported("“\(token)” isn’t a time. Give the split times in seconds or as m:ss.ff, "
                                                  + "separated by commas, for example at=1.5,3.25 or at=0:01.50,1:02.")
            }
            guard t > 0 else {
                throw ConversionError.unsupported("A split at \(t < 0 ? token : MediaTime.string(t)) would leave nothing before it. "
                                                  + "Give times after the start, for example at=1.5.")
            }
            guard t < source.duration else {
                throw ConversionError.unsupported("The split at \(token) is at or past the end of \(source.name) "
                                                  + "(\(MediaTime.string(source.duration))). Give times before the end.")
            }
            cuts.append((normalize(t, source: source), token))
        }
        cuts.sort { $0.t < $1.t }
        var unique: [(t: Double, typed: String)] = []
        for c in cuts where unique.last.map({ abs(c.t - $0.t) > 1e-9 }) ?? true { unique.append(c) }
        let times = unique.map(\.t)
        // Only a split near the end can come after the real last frame; counting the frames reads the whole file.
        let lastFrame = known ?? (source.hasVideo && (times.last ?? 0) > source.duration - 2 ? lastFrameStart(source) : nil)
        if let problem = problem(times, source: source, typed: quoteTyped ? unique.map(\.typed) : nil, lastFrame: lastFrame) {
            throw ConversionError.unsupported(problem)
        }
        return times
    }

    /// Split times for `count` equal parts.
    static func evenCuts(duration: Double, count: Int) -> [Double] {
        (1..<max(1, count)).map { duration * Double($0) / Double(count) }
    }

    /// Split times for parts `length` seconds long; the last part is what remains, and a tiny remainder joins it.
    /// nil when that would make more than `maxParts` parts (counted first: a file can claim to be years long).
    static func everyCuts(duration: Double, length: Double) -> [Double]? {
        guard length > 0, duration > 0, (duration / length).rounded(.down) <= Double(maxParts) else { return nil }
        var cuts: [Double] = []
        var t = length
        while t < duration - 1e-9 { cuts.append(t); t += length }
        if let last = cuts.last, duration - last < min(0.5, length / 2) { cuts.removeLast() }
        return cuts.count + 1 <= maxParts ? cuts : nil
    }
}
