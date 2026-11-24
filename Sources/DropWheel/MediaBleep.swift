import Foundation

/// Bleep… : covers stretches of the sound with a tone or with silence, sample-exact, in the file's own format
/// ("clip bleeped.mp4"). The picture is copied untouched (re-encoded only when an MP4 must stand in for a container
/// it can't keep and can't hold its codec, `copyVideoArgs`); only the sound is re-encoded.
///
/// One `aeval` filter does it: for each sample it decides, by time, whether the sample lies in a range (a binary
/// search written as nested `if`s, which ffmpeg evaluates lazily, so many ranges stay fast) and outputs either the
/// original sample or the tone (or 0). Edges therefore land on the exact sample, unlike `volume=…:enable`, which
/// switches per audio frame (about 20–40 ms late).
enum MediaBleep {
    enum Mode: String { case tone, silence }

    /// Peak level of the tone: −10.5 dBFS, about as loud as speech, so a bleep doesn't jump out of the mix.
    static let toneLevel = 0.3
    static let defaultFrequency = 1000.0
    /// Most ranges one run takes (the expression grows with each one).
    static let maxRanges = 500

    /// Options: ranges ("1.2-1.8,3-3.5"; seconds or m:ss.ff; required), mode (tone | silence, default tone) and freq
    /// (the tone in Hz, default 1000). Writes "<name> bleeped.<ext>".
    static func bleep(_ url: URL, options: ToolOptions, progress: @escaping (Double) -> Void) throws -> URL {
        let ff = try MediaKit.ffmpeg()
        let source = try MediaSource.load(url)
        guard source.hasAudio else {
            throw ConversionError.unsupported("The file has no sound to bleep.")
        }
        guard source.duration > 0 else {
            throw ConversionError.unsupported("The file reports no length, so it can’t be bleeped. Convert it first, then bleep the copy.")
        }
        let ranges = try parseRanges(options["ranges"] ?? "", source: source)
        let mode = try parseMode(options)
        let freq = try MediaTools.number(options, "freq", defaultFrequency, example: "1000")
        let rate = Double(source.sampleRate ?? 48_000)
        guard freq.isFinite, freq >= 20, freq < rate / 2 else {
            throw ConversionError.unsupported("Choose a tone between 20 Hz and \(Int(rate / 2) - 1) Hz, for example freq=1000.")
        }
        // The ranges are on the file's clock, the clock of the picture, the player and the waveform (which pads sound
        // that starts late, MediaKit.peaks), and `aeval`'s `t` is that clock too, so they are used as they are.
        let filter = self.filter(ranges, mode: mode, frequency: freq)
        let ext = MediaEncode.outputExtension(for: source)
        let out = outputURL(for: url, ext: ext, suffix: " bleeped")
        let args: [String]
        if source.hasVideo {
            args = copyVideoArgs(source, ext: ext) + MediaEncode.audioCodecArgs(for: source, ext: ext, filters: [filter])
                + MediaEncode.containerArgs(ext)
        } else {
            args = MediaEncode.audioOnlyArgs(for: source, ext: ext, filters: [filter])
        }
        try ff.run(input: url, output: out, args: args, duration: source.duration, progress: progress)
        return out
    }

    /// When ffmpeg's clock shows the first sound sample: 0 for most files, 0.092 s for WMA (its decoder starts late),
    /// later for a video whose sound begins after the picture.
    static func audioStart(_ url: URL) -> Double {
        guard let ff = FFmpeg.shared,
              let r = try? ProcessRunner.run(ff.tool, ["-hide_banner", "-nostdin", "-i", url.path, "-map", "0:a:0", "-af", "ashowinfo",
                                                       "-frames:a", "1", "-f", "null", "-"]),
              let m = r.stderr.firstMatch(of: #/pts_time:(-?[0-9.]+)/#), let v = Double(m.1), v.isFinite else { return 0 }
        return v
    }

    /// Video codecs an MP4 holds as they are. A file whose container isn't kept (flv, ts, mpg…) is written as an MP4,
    /// and its picture can only be copied into it when the codec is one of these.
    static let mp4VideoCodecs: Set<String> = ["h264", "hevc", "mpeg4", "mpeg2video", "mpeg1video", "mjpeg", "vp9", "av1"]

    /// Maps the first video and first audio stream and copies the video (QuickTime needs the hvc1 tag for HEVC). When
    /// the output is an MP4 in place of another container and MP4 can't hold the picture's codec (Sorenson Spark in
    /// old FLV files, Theora), the picture is re-encoded instead; ffmpeg would otherwise stop with "Could not find
    /// tag for codec flv1".
    static func copyVideoArgs(_ source: MediaSource, ext: String) -> [String] {
        var args = ["-map", "0:v:0", "-map", "0:a:0"]
        if ext != source.ext, !mp4VideoCodecs.contains(source.videoCodec ?? "") {
            return args + MediaEncode.videoCodecArgs(for: source, ext: ext) + ["-vf", MediaEncode.evenCrop]
        }
        args += ["-c:v", "copy"]
        if source.videoCodec == "hevc", MediaEncode.isISO(ext) { args += ["-tag:v", "hvc1"] }
        return args
    }

    static func parseMode(_ options: ToolOptions) throws -> Mode {
        let text = options.string("mode", Mode.tone.rawValue).lowercased()
        guard let mode = Mode(rawValue: text) else {
            throw ConversionError.unsupported("Choose mode=tone or mode=silence (not “\(text)”).")
        }
        return mode
    }

    /// Reads "1.2-1.8, 3-3.5" (seconds or m:ss.ff), checks every range against the file, and sorts and merges
    /// ranges that overlap or touch. An end within 1.5 ms past the length counts as the length.
    static func parseRanges(_ text: String, source: MediaSource) throws -> [MediaRange] {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            throw ConversionError.unsupported("Give the stretches to bleep in seconds, for example ranges=1.2-1.8,3-3.5.")
        }
        guard parts.count <= maxRanges else {
            throw ConversionError.unsupported("That’s \(parts.count) ranges; Bleep takes at most \(maxRanges) at a time. Bleep the file in two goes.")
        }
        var ranges: [MediaRange] = []
        for part in parts {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard ends.count == 2, let a = MediaTime.parse(ends[0]), var b = MediaTime.parse(ends[1]) else {
                throw ConversionError.unsupported("“\(part)” isn’t a range. Write each one as start-end, for example 1.2-1.8.")
            }
            if b > source.duration, b - source.duration <= 0.0015 { b = source.duration }
            guard b <= source.duration else {
                throw ConversionError.unsupported("The range \(part) ends past the end of the file (\(MediaTime.string(source.duration))). "
                                                  + "Choose an end of \(MediaTime.string(source.duration)) or less.")
            }
            guard b - a >= 0.001 else {
                throw ConversionError.unsupported("The range \(part) must start before it ends. Write it as start-end, for example 1.2-1.8.")
            }
            ranges.append(MediaRange(start: a, end: b))
        }
        return merged(ranges)
    }

    /// Sorted, with overlapping or touching ranges joined.
    static func merged(_ ranges: [MediaRange]) -> [MediaRange] {
        var out: [MediaRange] = []
        for r in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, r.start <= last.end { out[out.count - 1].end = max(last.end, r.end) } else { out.append(r) }
        }
        return out
    }

    /// The `aeval` filter for sorted, non-overlapping `ranges`. The expression is quoted, so its commas need no
    /// escaping (ffmpeg's filter parser keeps quoted text as it is).
    static func filter(_ ranges: [MediaRange], mode: Mode, frequency: Double) -> String {
        "aeval='\(expression(ranges[...], mode: mode, frequency: frequency))':c=same"
    }

    /// Per sample: inside range i → the tone (its phase starts at 0 at the range's start, so it begins without a
    /// click) or 0; outside → the sample as it was. Nested `if`s split the ranges in halves (lazy, O(log n)).
    static func expression(_ ranges: ArraySlice<MediaRange>, mode: Mode, frequency: Double) -> String {
        if ranges.count == 1, let r = ranges.first {
            let a = MediaTime.arg(r.start), b = MediaTime.arg(r.end)
            let inside = mode == .tone ? "\(toneLevel)*sin(2*PI*\(String(format: "%.6f", frequency))*(t-\(a)))" : "0"
            return "if(gte(t,\(a))*lt(t,\(b)),\(inside),val(ch))"
        }
        let mid = ranges.startIndex + ranges.count / 2
        let left = expression(ranges[ranges.startIndex..<mid], mode: mode, frequency: frequency)
        let right = expression(ranges[mid...], mode: mode, frequency: frequency)
        return "if(lt(t,\(MediaTime.arg(ranges[mid].start))),\(left),\(right))"
    }

    /// The text `ranges=` takes ("1.200000-1.800000,3.000000-3.500000").
    static func rangesOption(_ ranges: [MediaRange]) -> String {
        ranges.map { "\(MediaTime.arg($0.start))-\(MediaTime.arg($0.end))" }.joined(separator: ",")
    }
}
