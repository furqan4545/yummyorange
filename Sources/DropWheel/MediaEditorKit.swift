import AppKit
import AVFoundation
import CryptoKit

// The media editor kit: what the audio and video editors (Trim, and the tools built on it) share.
// See MEDIA_EDITOR_KIT.md for how to build a new editor on it. The pieces live in files that start with "Media":
// - MediaEditorKit.swift: the source probe (MediaSource), ranges, time text, the re-encode rules (MediaEncode),
//   ffmpeg helpers for the editors (key frames, stills, film strip, waveform peaks, preview proxies) and the
//   measurements the self-tests use (MediaMeasure).
// - MediaPreview.swift: the picture (AVPlayerLayer, no system controls), the view ↔ video-pixel mapping, overlays,
//   and playback (MediaPlayback: exact, chased seeks).
// - MediaTimeline.swift: the film strip / waveform timeline with playhead, zoom, scrolling and selection ranges.
// - MediaEditorWindow.swift: the window controller base class (toolbar, keys, undo, discard sheet, preview proxy,
//   snapshot rendering) and the transport bar.
// - MediaTrim.swift, MediaTrimTests.swift: the Trim tool built on it, and `--selftest media-trim`.

// MARK: - Source

/// One audio or video file as the media editors and commands see it: what `ffmpeg -i` reports (MoreFormats.MediaProbe
/// and FFmpeg.MediaInfo parse the same text), plus what those leave out: rotation, pixel aspect, codecs, pixel format,
/// colour tags, PCM bit depth and the first video frame's time.
///
/// Times are seconds from the start of the file (ffmpeg subtracts the container's start time), the same clock
/// `-ss`, AVFoundation (for files it plays) and the preview proxy use.
struct MediaSource {
    let url: URL
    private(set) var probe = MoreFormats.MediaProbe()
    private(set) var info = FFmpeg.MediaInfo()
    /// Length in seconds (0 when ffmpeg reports none).
    private(set) var duration: Double = 0
    /// Clockwise turn (0, 90, 180 or 270) that shows the stored picture upright, from the display matrix.
    private(set) var rotation = 0
    /// Width of one stored pixel relative to its height (the stream's SAR; 1 for square pixels).
    private(set) var sampleAspect: Double = 1
    private(set) var videoCodec: String?
    private(set) var pixelFormat: String?
    /// The colour matrix the stream is tagged with ("bt709", "bt470bg", "smpte170m", "bt2020nc"), nil when untagged.
    private(set) var colorMatrix: String?
    /// When the first video frame is shown (wmv files often start at 0.046 s).
    private(set) var videoStart: Double = 0
    /// When the first audio stream starts, as the container reports it ("start 0.500000" on its stream line; 0 when
    /// it reports none). Decoders can add their own delay on top (ffmpeg's WMA decoder: 0.092 s), which only decoding
    /// shows.
    private(set) var audioStart: Double = 0
    private(set) var audioCodec: String?
    /// Bits per sample of PCM and FLAC audio (16, 24, 32), nil for lossy and float formats.
    private(set) var audioBits: Int?
    /// The first audio stream's bit rate in kb/s, when ffmpeg reports one.
    private(set) var audioBitrate: Int?

    var name: String { url.lastPathComponent }
    var ext: String { Ext.of(url) }
    var hasVideo: Bool { probe.hasVideo && probe.width > 0 && probe.height > 0 }
    var hasAudio: Bool { probe.hasAudio }
    /// .video when there is a picture, otherwise .audio (an audio-only .mp4 or .mkv is audio).
    var kind: FileKind { hasVideo ? .video : .audio }
    var sampleRate: Int? { probe.sampleRate }
    var channels: Int? { probe.channels }

    /// Frames per second (the average rate, else the base rate), nil for audio. ffmpeg prints NTSC rates rounded
    /// ("23.98 fps"); they are taken as the exact 24000/1001, 30000/1001, 60000/1001 and 120000/1001, so the frame
    /// grid stays on the real frames (1/23.98 drifts 0.2 ms by frame 30, and the frame on screen at a grid time was
    /// the one before).
    var fps: Double? {
        guard hasVideo, let rate = [probe.fps, probe.tbr].compactMap({ $0 }).first(where: { $0 >= 1 && $0 <= 240 }) else { return nil }
        for exact in [24000.0 / 1001, 30000.0 / 1001, 60000.0 / 1001, 120000.0 / 1001] where abs(rate - exact) < 0.006 { return exact }
        return rate
    }

    /// One step of the timeline: a video frame, or 1/100 s for audio (the precision the time fields show).
    var frameDuration: Double { hasVideo ? 1 / (fps ?? 30) : 0.01 }

    /// The picture's pixel grid in display orientation (stored width and height swapped for a quarter turn). This is
    /// the grid ffmpeg filters (crop, overlay, drawbox) work in, because ffmpeg turns the picture upright first.
    var pixelSize: CGSize {
        let w = CGFloat(probe.width), h = CGFloat(probe.height)
        return rotation % 180 == 0 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
    }

    /// Width of one pixel of `pixelSize` relative to its height (a quarter turn inverts the stored aspect).
    var pixelAspect: Double { rotation % 180 == 0 ? sampleAspect : 1 / sampleAspect }

    /// The picture's shape on screen, in square units: `pixelSize` with the width scaled by `pixelAspect`.
    var displaySize: CGSize {
        CGSize(width: (pixelSize.width * CGFloat(pixelAspect)).rounded(), height: pixelSize.height)
    }

    var displayAspect: CGFloat {
        let size = displaySize
        guard size.width > 0, size.height > 0 else { return 16.0 / 9 }
        return size.width / size.height
    }

    /// The nearest step of the timeline: a video frame start (`videoStart + n / fps`), or 1/100 s for audio,
    /// clamped to 0…duration. Times before the first video frame snap to 0 or to that frame.
    func snap(_ t: Double) -> Double {
        guard t.isFinite else { return 0 }
        let fd = frameDuration
        var s: Double
        if hasVideo {
            if t < videoStart { return t < videoStart / 2 ? 0 : videoStart }
            s = videoStart + ((t - videoStart) / fd).rounded() * fd
        } else {
            s = (t / fd).rounded() * fd
        }
        s = min(max(s, 0), duration)
        return s
    }

    /// Where a range that ends near `t` ends: `snap(t)`, or the file's length when no further frame starts before it
    /// (so an end dragged to the last frame keeps the sound after it, as wmv files with longer sound have).
    func snapEnd(_ t: Double) -> Double {
        let s = snap(t)
        return duration - s < frameDuration * 0.999 ? duration : s
    }

    /// `snap(t)` moved by `frames` steps (a frame, or 1/100 s for audio), within 0…duration.
    func step(_ t: Double, by frames: Int) -> Double {
        let base = snap(t)
        if hasVideo, base < videoStart, frames > 0 { return min(duration, videoStart + Double(frames - 1) * frameDuration) }
        return snap(min(max(base + Double(frames) * frameDuration, 0), duration))
    }

    // MARK: Loading

    /// Probes `url` with `ffmpeg -i`. Throws when ffmpeg is missing, the file can't be read, or it has neither
    /// picture nor sound.
    static func load(_ url: URL) throws -> MediaSource {
        guard let ff = FFmpeg.shared else { throw ConversionError.missingTool("ffmpeg") }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw ConversionError.unreadable(url.lastPathComponent) }
        let result = try ProcessRunner.run(ff.tool, ["-hide_banner", "-nostdin", "-i", url.path])
        let source = parse(result.stderr, url: url)
        try source.probe.requireReadable(url)
        guard source.hasVideo || source.hasAudio else {
            throw ConversionError.unsupported("\(url.lastPathComponent) has no picture or sound to edit.")
        }
        return source
    }

    /// Reads ffmpeg's stream report (exposed for tests).
    static func parse(_ report: String, url: URL) -> MediaSource {
        // The path first: a file name can hold line breaks, so cutting the "Input #0" line isn't enough to drop it.
        let text = withoutTags(url.path.isEmpty ? report : report.replacingOccurrences(of: url.path, with: "<file>"))
        var s = MediaSource(url: url)
        s.probe.parse(text)
        s.info = FFmpeg.parse(text)
        s.duration = max(0, s.probe.duration ?? 0)
        var formatStart = 0.0
        if let m = text.firstMatch(of: #/Duration: [^,]*, start: (-?[0-9.]+)/#), let v = Double(m.1) { formatStart = v }
        let lines = text.split(separator: "\n").map(String.init)
        if let line = lines.first(where: { $0.contains("Stream #") && $0.contains("Video:") && !$0.contains("attached pic") }) {
            let body = line.components(separatedBy: "Video: ").dropFirst().joined(separator: "Video: ")
            let fields = splitTopLevel(body)
            s.videoCodec = fields.first.flatMap { $0.split(separator: " ").first.map(String.init) }
            if fields.count > 1 {
                let pf = fields[1]
                s.pixelFormat = String(pf.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces)
                if let open = pf.firstIndex(of: "("), let close = pf.lastIndex(of: ")"), open < close {
                    let tags = pf[pf.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    // "bt709" when matrix, primaries and transfer agree, else "matrix/primaries/transfer".
                    let matrices = ["bt709", "bt470bg", "smpte170m", "bt2020nc", "bt2020c", "fcc", "smpte240m"]
                    s.colorMatrix = tags.map { String($0.prefix { $0 != "/" }) }.first { matrices.contains($0) }
                }
            }
            // "[SAR 3301:3297 DAR …], SAR 5776:5769 DAR 16:9": the last one is the stream's, which ffmpeg uses.
            if let m = line.matches(of: #/SAR (\d+):(\d+)/#).last, let n = Double(m.1), let d = Double(m.2), n > 0, d > 0 {
                s.sampleAspect = n / d
            }
            if let m = line.firstMatch(of: #/, start (-?[0-9.]+)/#), let v = Double(m.1) { s.videoStart = max(0, v - formatStart) }
        }
        if let m = text.firstMatch(of: #/rotation of (-?[0-9.]+) degrees/#), let r = Double(m.1) {
            // ffmpeg prints the counter-clockwise angle; the picture is shown turned the other way.
            let quarter = Int((-r / 90).rounded()) * 90
            s.rotation = ((quarter % 360) + 360) % 360
        }
        if let line = lines.first(where: { $0.contains("Stream #") && $0.contains("Audio:") }) {
            let body = line.components(separatedBy: "Audio: ").dropFirst().joined(separator: "Audio: ")
            let fields = splitTopLevel(body)
            s.audioCodec = fields.first.flatMap { $0.split(separator: " ").first.map(String.init) }
            if let m = line.firstMatch(of: #/\((\d+) bit\)/#) { s.audioBits = Int(m.1) }
            else if let codec = s.audioCodec, let m = codec.firstMatch(of: #/^pcm_[suf](\d+)/#) { s.audioBits = Int(m.1) }
            else if s.audioCodec == "flac" || s.audioCodec?.hasPrefix("pcm_") == true {
                if fields.contains(where: { $0.hasPrefix("s16") }) { s.audioBits = 16 }
                else if fields.contains(where: { $0.hasPrefix("s32") }) { s.audioBits = 32 }
            }
            if let m = line.firstMatch(of: #/, (\d+) kb\/s/#) { s.audioBitrate = Int(m.1) }
            if let m = line.firstMatch(of: #/, start (-?[0-9.]+)/#), let v = Double(m.1) { s.audioStart = max(0, v - formatStart) }
        }
        return s
    }

    /// ffmpeg's report without the text a file supplies: the file name on the "Input #0, …, from '…':" line and
    /// every "Metadata:" block (titles, comments, encoder notes and their continuation lines, which ffmpeg indents
    /// deeper than the block's header). The parsers take the first "Duration:" and every "Stream #" anywhere in the
    /// text, so a podcast comment like "Duration: 10:00:00.00" or a crafted tag would otherwise set the length, or
    /// add a picture to a sound file.
    static func withoutTags(_ report: String) -> String {
        var kept: [Substring] = []
        var blockIndent: Int?
        for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix { $0 == " " }.count
            if let b = blockIndent {
                if indent > b { continue }
                blockIndent = nil
            }
            let body = line.dropFirst(indent)
            if body.hasPrefix("Metadata:") { blockIndent = indent; continue }
            if body.hasPrefix("Input #") { kept.append(line.prefix { $0 != "," }); continue }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// Splits "h264 (High) (avc1 / 0x31), yuv420p(tv, bt709), 1280x720" at the commas outside brackets.
    private static func splitTopLevel(_ s: String) -> [String] {
        var parts: [String] = [], current = "", depth = 0
        for ch in s {
            if ch == "(" || ch == "[" { depth += 1 } else if ch == ")" || ch == "]" { depth = max(0, depth - 1) }
            if ch == ",", depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            } else { current.append(ch) }
        }
        if !current.isEmpty { parts.append(current.trimmingCharacters(in: .whitespaces)) }
        return parts
    }

    /// Options for ffmpeg's `scale` filter that decode the picture with the right colour matrix when converting to
    /// RGB: untagged HD (720 lines and up) is BT.709, which ffmpeg would otherwise read as BT.601.
    var rgbScaleOptions: String {
        if colorMatrix == nil, pixelSize.height >= 720 || pixelSize.width >= 1280 { return ":in_color_matrix=bt709" }
        return ""
    }
}

// MARK: - Ranges and time text

/// A stretch of the file in seconds, `start` < `end`.
struct MediaRange: Equatable, Codable {
    var start: Double
    var end: Double
    var length: Double { end - start }
    func contains(_ t: Double) -> Bool { t >= start && t < end }
}

/// Times as the editors show them: m:ss.ff (hundredths), h:mm:ss.ff from an hour.
enum MediaTime {
    static func string(_ t: Double) -> String {
        let hundredths = Int((max(0, t.isFinite ? t : 0) * 100).rounded())
        let h = hundredths / 360_000, m = (hundredths / 6000) % 60, s = (hundredths / 100) % 60, f = hundredths % 100
        return h > 0 ? String(format: "%d:%02d:%02d.%02d", h, m, s, f) : String(format: "%d:%02d.%02d", m, s, f)
    }

    /// A length as "2.70 s" under a minute, else as a time.
    static func lengthString(_ t: Double) -> String {
        t < 60 ? String(format: "%.2f s", max(0, t)) : string(t)
    }

    /// Reads "1.5", "90", "0:01.50", "1:02:03.5" (also with a decimal comma). nil when it isn't a time.
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (i, part) in parts.enumerated() {
            guard let v = Double(part), v.isFinite, v >= 0 else { return nil }
            if i < parts.count - 1, v != v.rounded() { return nil }
            if i > 0, v >= 60 { return nil }
            total = total * 60 + v
        }
        return total
    }

    /// Seconds as an ffmpeg time argument (microsecond precision, no exponent).
    static func arg(_ t: Double) -> String { String(format: "%.6f", max(0, t)) }
}

// MARK: - Re-encode rules

/// How a media edit writes its result: in the input's own container with the codecs that container is known for
/// (the table in map-media.md), so a trimmed .wmv is still a .wmv. Video: VideoToolbox H.264 + AAC for mp4/mov/m4v/3gp
/// and mkv, VP9 + Opus for webm, MPEG-4 Part 2 (XVID) + MP3 for avi, WMV2 + WMA2 for wmv/asf, and an mp4 for other
/// containers (ts, vob, flv…). Audio keeps its own format; PCM and FLAC keep their bit depth.
enum MediaEncode {
    static let videoContainers: Set<String> = ["mp4", "m4v", "mov", "3gp", "3g2", "mkv", "webm", "avi", "wmv", "asf"]
    static let audioContainers: Set<String> = ["mp3", "m4a", "m4b", "aac", "mp4", "m4v", "mov", "wav", "aiff", "aif", "aifc",
                                               "caf", "flac", "ogg", "oga", "opus", "wma", "asf", "wmv", "mkv", "mka", "webm"]

    /// The extension an edited copy of `source` gets.
    static func outputExtension(for source: MediaSource) -> String {
        let ext = source.ext
        if source.hasVideo { return videoContainers.contains(ext) ? ext : "mp4" }
        return audioContainers.contains(ext) ? ext : "m4a"
    }

    /// Whether `ext` is an MP4-family container (QuickTime atoms, `-movflags`, `-tag:v`).
    static func isISO(_ ext: String) -> Bool { ["mp4", "m4v", "mov", "3gp", "3g2", "m4a", "m4b"].contains(ext) }

    /// A crop to even width and height (no resampling; 4:2:0 encoders need even sizes).
    static let evenCrop = "crop=trunc(iw/2)*2:trunc(ih/2)*2:0:0"

    /// Everything after the input for a full re-encode of the first video and first audio stream into `ext`:
    /// maps, codecs, `-vf` (your `videoFilters` first, then an even crop) and `-af` (your `audioFilters`).
    /// Pass `audio: false` to drop the sound. Don't add another `-vf`/`-af`: ffmpeg keeps only the last one.
    static func videoArgs(for source: MediaSource, ext: String, videoFilters: [String] = [], audio: Bool = true,
                          audioFilters: [String] = [], quality: Int = 70) -> [String] {
        let withAudio = audio && source.hasAudio
        var args = ["-map", "0:v:0"] + (withAudio ? ["-map", "0:a:0"] : [])
        args += videoCodecArgs(for: source, ext: ext, quality: quality)
        args += ["-vf", (videoFilters + [evenCrop]).joined(separator: ",")]
        args += withAudio ? audioCodecArgs(for: source, ext: ext, filters: audioFilters) : ["-an"]
        args += containerArgs(ext)
        return args
    }

    /// The video encoder options for `ext` (no maps, no filters).
    static func videoCodecArgs(for source: MediaSource, ext: String, quality: Int = 70) -> [String] {
        switch ext {
        case "webm":
            return ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "32", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4",
                    "-pix_fmt", "yuv420p"]
        case "avi":
            // AVI has no variable frame rate and MPEG-4 Part 2 caps the time base (MoreFormats.toAVI).
            return ["-c:v", "mpeg4", "-vtag", "XVID", "-q:v", "3", "-g", "250", "-pix_fmt", "yuv420p", "-r", source.probe.constantRate]
        case "wmv", "asf":
            // ASF keeps each frame's time, but ffmpeg treats it as constant-rate and would repeat a last frame whose
            // display runs on to the end of longer sound (a cut to the end of sample.wmv gained a frame).
            return ["-c:v", "wmv2", "-q:v", "3", "-g", "250", "-pix_fmt", "yuv420p", "-fps_mode", "passthrough"]
        default:
            var args = ["-c:v", "h264_videotoolbox", "-q:v", String(quality), "-allow_sw", "1", "-pix_fmt", "yuv420p"]
            if isISO(ext) { args += ["-tag:v", "avc1"] }
            return args
        }
    }

    /// Muxer options: `+faststart` for MP4-family files.
    static func containerArgs(_ ext: String) -> [String] { isISO(ext) ? ["-movflags", "+faststart"] : [] }

    /// The audio encoder options (with `-af` when there are filters) for the sound of `source` written into `ext`.
    /// Video containers: AAC (mp4, mov, mkv, other), Opus (webm), MP3 (avi), WMA 2 (wmv, asf). Audio files keep their
    /// own codec (Converter.normalizeAudioArgs), PCM keeps its sample format (24-bit WAV stays 24-bit) and lossy
    /// codecs keep about the source's bit rate.
    static func audioCodecArgs(for source: MediaSource, ext: String, filters: [String] = []) -> [String] {
        let caps = Capabilities.shared
        var filters = filters
        var args: [String]
        if source.hasVideo {
            switch ext {
            case "webm":
                let (a, f) = Converter.normalizeAudioArgs(kind: .video, ext: "webm", info: source.info)
                args = a; if let f { filters.append(f) }
            case "avi":
                args = caps.has("libmp3lame") ? ["-c:a", "libmp3lame", "-b:a", "192k"] : ["-c:a", "mp2", "-b:a", "224k"]
                args += source.probe.audioFit(maxRate: 48_000, maxChannels: 2)
            case "wmv", "asf":
                let (a, f) = Converter.normalizeAudioArgs(kind: .video, ext: ext, info: source.info)
                args = a + wmaRate(source)
                if let f { filters.append(f) }
            default:
                args = ["-c:a", "aac", "-b:a", "\(lossyRate(source, floor: 128))k"]
            }
        } else {
            let (a, f) = Converter.normalizeAudioArgs(kind: .audio, ext: ext, info: source.info)
            args = a
            if let f { filters.append(f) }
            // AudioToolbox's AAC pads the end to a whole 1024-sample frame and doesn't record it, so every edited
            // .m4a ran up to 23 ms long (silence at each join of a split). ffmpeg's own AAC records it: exact lengths.
            if let i = args.firstIndex(of: "-c:a"), i + 1 < args.count, args[i + 1] == "aac_at" { args[i + 1] = "aac" }
            if let codec = source.audioCodec, codec.hasPrefix("pcm_"), ["wav", "aiff", "aif", "aifc", "caf"].contains(ext),
               caps.has(codec), let i = args.firstIndex(of: "-c:a"), i + 1 < args.count {
                // Keep the sample format: 24-bit and float WAV/AIFF stay what they were (audioArgs writes 16-bit).
                args[i + 1] = codec
            }
            if ext == "caf" && !(source.audioCodec?.hasPrefix("pcm_") ?? false) {
                args = FFmpeg.audioArgs(for: .m4a, bitrate: "\(lossyRate(source, floor: 96))k")
            }
            if let i = args.firstIndex(of: "-b:a"), i + 1 < args.count,
               let codec = args.firstIndex(of: "-c:a").map({ args[$0 + 1] }), ["libmp3lame", "aac", "aac_at"].contains(codec) {
                args[i + 1] = "\(lossyRate(source, floor: 96))k"
            }
            if ["wma", "asf", "wmv"].contains(ext) { args += wmaRate(source) }
        }
        if !filters.isEmpty { args += ["-af", filters.joined(separator: ",")] }
        return args
    }

    /// WMA stops at 48 kHz (normalizeAudioArgs already folds more than two channels into two).
    private static func wmaRate(_ source: MediaSource) -> [String] {
        (source.sampleRate ?? 0) > 48_000 ? ["-ar", "48000"] : []
    }

    /// A lossy re-encode's bit rate in kb/s: the source's (so a second generation doesn't lose much), at least
    /// `floor`, at most 320.
    static func lossyRate(_ source: MediaSource, floor: Int) -> Int {
        guard let rate = source.audioBitrate ?? source.info.audioBitrate, rate > 0 else { return 192 }
        return min(320, max(floor, rate))
    }

    /// Everything after the input for the first audio stream alone, re-encoded into `ext` (no picture, no cover art).
    static func audioOnlyArgs(for source: MediaSource, ext: String, filters: [String] = []) -> [String] {
        ["-map", "0:a:0", "-vn"] + audioCodecArgs(for: source, ext: ext, filters: filters) + containerArgs(ext)
    }
}

// MARK: - ffmpeg helpers for the editors

enum MediaKit {
    static func ffmpeg() throws -> FFmpeg {
        guard let ff = FFmpeg.shared else { throw ConversionError.missingTool("ffmpeg") }
        return ff
    }

    /// Key frame times up to `limit` seconds (decoding only the key frames, reading no further than `limit` + 1 s).
    static func keyframes(_ source: MediaSource, upTo limit: Double? = nil) -> [Double] {
        guard source.hasVideo, let ff = FFmpeg.shared else { return [] }
        var args = ["-hide_banner", "-nostdin", "-skip_frame", "nokey"]
        if let limit { args += ["-t", MediaTime.arg(limit + 1)] }
        args += ["-i", source.url.path, "-map", "0:v:0", "-vf", "showinfo", "-f", "null", "-"]
        guard let result = try? ProcessRunner.run(ff.tool, args) else { return [] }
        return result.stderr.matches(of: #/pts_time:(-?[0-9.]+)/#).compactMap { Double($0.1) }
    }

    /// Containers with no index (MPEG transport and program streams: .ts, .m2ts, .vob, .mpg…). ffmpeg seeks in them by
    /// bytes and lands near the time asked for; the decoder then drops every frame up to the next key frame.
    static let unindexedContainers: Set<String> = ["ts", "m2ts", "mts", "m2t", "tts", "trp", "vob", "mpg", "mpeg", "m2p", "ps", "mod", "tod", "evo"]

    /// Where an input `-ss` for the frame at `t` must land so the decoder gets the key frame that frame needs: `t` in
    /// most containers (ffmpeg seeks back to that key frame itself); half a second before the last key frame at or
    /// before `t` in one without an index (from `keyframes`, else found by decoding only the key frames up to `t`).
    /// Frames between the seek point and `t` still have to be skipped (an output `-ss`, or `select`).
    static func seekBefore(_ source: MediaSource, _ t: Double, keyframes: [Double]? = nil) -> Double {
        guard source.hasVideo, unindexedContainers.contains(source.ext) else { return max(0, t) }
        let keys = keyframes ?? self.keyframes(source, upTo: t + source.frameDuration)
        let key = keys.last { $0 <= t + source.frameDuration / 2 } ?? 0
        return max(0, min(t, key - 0.5))
    }

    /// The number of video packets (frames) in a file, read without decoding.
    static func videoPacketCount(_ url: URL) -> Int? {
        guard let ff = FFmpeg.shared,
              let result = try? ProcessRunner.run(ff.tool, ["-hide_banner", "-nostdin", "-loglevel", "error", "-i", url.path,
                                                            "-map", "0:v:0", "-c", "copy", "-f", "null", "-progress", "pipe:1", "-nostats", "-"]),
              result.status == 0 else { return nil }
        return result.stdout.matches(of: #/frame=(\d+)/#).last.flatMap { Int($0.1) }
    }

    /// Where `stillFrame` seeks for `t`: the still is the first frame that starts at or after this time. Snapshot's
    /// Save reads the same frame while its window shows a still (MediaSnapshot.frameTime, `still`).
    static func stillSeek(_ t: Double) -> Double { max(0, t - 0.001) }

    /// The video frame shown at `t` as an RGB image, at most `maxPixels` on its longer side, upright and with square
    /// pixels (decoded by ffmpeg, so it works for every format). nil without a picture.
    static func stillFrame(_ source: MediaSource, at t: Double, maxPixels: Int = 1600) -> CGImage? {
        guard source.hasVideo, let ff = FFmpeg.shared else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-still-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        let out = dir.appendingPathComponent("frame.png")
        let size = fitted(source.displaySize, maxSide: maxPixels)
        // Seek a little early, then take the first frame at or after t (the frame on screen at t). In a container
        // without an index the seek lands before the key frame (seekBefore) and an output -ss skips to t.
        let at = stillSeek(t), seek = seekBefore(source, at)
        let args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + ff.decodeOptions(for: source.url)
            + ["-ss", MediaTime.arg(seek), "-i", source.url.path]
            + (at - seek > 0.0005 ? ["-ss", MediaTime.arg(at - seek)] : [])
            + ["-map", "0:v:0", "-frames:v", "1",
               "-vf", "scale=\(Int(size.width)):\(Int(size.height))\(source.rgbScaleOptions),setsar=1,format=rgb24", out.path]
        guard let result = try? ProcessRunner.run(ff.tool, args), result.status == 0 else { return nil }
        return loadImage(out)
    }

    /// A still through AVFoundation (exact frame, the preferred transform applied): for files it plays and for
    /// preview proxies. Waits for the generator, so call it off the main thread in the app (it's quick).
    static func avStillFrame(_ url: URL, at t: Double, maxPixels: Int = 1600) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        let done = DispatchSemaphore(value: 0)
        var image: CGImage?
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: max(0, t), preferredTimescale: 600))]) { _, cg, _, _, _ in
            image = cg
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        return image
    }

    /// `size` scaled down to fit `maxSide`, even and at least 2 × 2.
    static func fitted(_ size: CGSize, maxSide: Int) -> CGSize {
        let scale = min(1, CGFloat(maxSide) / max(size.width, size.height, 1))
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * scale / 2).rounded() * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    /// Decodes an image now, from bytes read into memory, so it survives the temporary file being deleted
    /// (ImageIO otherwise decodes lazily, from the file).
    static func loadImage(_ url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url), let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    // MARK: Film strip

    /// Thumbnails across the whole video, made in one ffmpeg run (fps + tile): thumbnail k shows the frame near
    /// `k * duration / count`. Long videos (over two minutes) decode key frames only, which is much faster.
    struct FilmStrip {
        let tiles: [CGImage]
        let duration: Double
        /// The thumbnail nearest to `t`.
        func tile(at t: Double) -> CGImage? {
            guard !tiles.isEmpty, duration > 0 else { return tiles.first }
            let i = Int((t / duration * Double(tiles.count)).rounded(.down))
            return tiles[min(max(i, 0), tiles.count - 1)]
        }
    }

    static func filmStrip(_ source: MediaSource, height: Int = 108, maxCount: Int = 120) -> FilmStrip? {
        guard source.hasVideo, source.duration > 0, let ff = FFmpeg.shared else { return nil }
        let frames = Int((source.duration * (source.fps ?? 30)).rounded())
        let count = max(1, min(maxCount, frames))
        let w = max(2, Int((CGFloat(height) * source.displayAspect / 2).rounded()) * 2)
        let cols = min(count, 12), rows = (count + cols - 1) / cols
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-strip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        let out = dir.appendingPathComponent("strip.png")
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
        if source.duration > 120 { args += ["-skip_frame", "nokey"] }
        let rate = "\(count)/\(MediaTime.arg(source.duration))"
        args += ff.decodeOptions(for: source.url)
        args += ["-i", source.url.path, "-map", "0:v:0", "-frames:v", "1",
                 "-vf", "fps=\(rate):start_time=0,scale=\(w):\(height)\(source.rgbScaleOptions),setsar=1,format=rgb24,tile=\(cols)x\(rows)",
                 out.path]
        guard let result = try? ProcessRunner.run(ff.tool, args), result.status == 0, let sheet = loadImage(out) else { return nil }
        var tiles: [CGImage] = []
        for i in 0..<count {
            let rect = CGRect(x: (i % cols) * w, y: (i / cols) * height, width: w, height: height)
            if let tile = sheet.cropping(to: rect) { tiles.append(tile) }
        }
        return FilmStrip(tiles: tiles, duration: source.duration)
    }

    // MARK: Waveform peaks

    /// The loudest sample (of any channel) per bucket of 1/`rate` s, 0…1, decoded at the file's own sample rate so
    /// nothing is filtered away. `coarse` holds the same peaks 32 buckets at a time, for drawing zoomed-out views.
    struct Peaks {
        let rate: Double
        let values: [Float]
        let coarse: [Float]
        static let coarseFactor = 32
        var duration: Double { Double(values.count) / rate }

        /// The loudest peak between `t0` and `t1` (at least one bucket).
        func peak(from t0: Double, to t1: Double) -> Float {
            // Past the end of the sound (a video whose sound stops early) there is nothing to draw.
            guard !values.isEmpty, t0.isFinite, t1.isFinite, t0 * rate < Double(values.count) else { return 0 }
            var a = Int((t0 * rate).rounded(.down)), b = Int((t1 * rate).rounded(.up))
            a = min(max(a, 0), values.count - 1); b = min(max(b, a + 1), values.count)
            if b - a > Self.coarseFactor * 4 {
                // Whole coarse buckets in the middle, single ones at the edges.
                let ca = (a + Self.coarseFactor - 1) / Self.coarseFactor, cb = b / Self.coarseFactor
                var m: Float = 0
                for i in a..<min(b, ca * Self.coarseFactor) { m = max(m, values[i]) }
                if ca < cb { for i in ca..<min(cb, coarse.count) { m = max(m, coarse[i]) } }
                for i in max(a, cb * Self.coarseFactor)..<b { m = max(m, values[i]) }
                return m
            }
            var m: Float = 0
            for i in a..<b { m = max(m, values[i]) }
            return m
        }
    }

    /// Pads the sound with silence so it starts at 0 on the file's clock (the clock of the picture, `-ss`, `atrim`,
    /// `aeval`'s `t` and the player). Sound that starts late (a video whose sound begins at 0.5 s; ffmpeg's WMA decoder,
    /// whose first sample is at 0.092 s) otherwise moves earlier as soon as it is decoded to raw samples, re-encoded
    /// with `asetpts=PTS-STARTPTS`, or written to a container that can't record a start time (AVI).
    /// `min_hard_comp` keeps it to the start: a jump later in the sound's times is left as it is (ffmpeg would fill
    /// it in one block too, and a damaged file can jump by days).
    static let soundFromZero = "aresample=first_pts=0:min_hard_comp=1e9"

    /// The most samples (all channels together) `soundFromZero` may put in front of the sound. ffmpeg makes that
    /// silence as one block in memory, so a file claiming its sound starts a day after its picture took 2 GB and a
    /// minute of decoding; 2^26 samples is about 11 minutes of 48 kHz stereo.
    static let maxLeadSamples = 67_108_864.0

    /// `[soundFromZero]` when the sound ffmpeg reads from `seek` on starts within `maxLeadSamples` of it, else
    /// nothing: a sound the file says starts that much later is taken from its first sample (as before the padding).
    static func soundFromZero(_ source: MediaSource, seek: Double = 0) -> [String] {
        let lead = max(0, source.audioStart - max(0, seek))
        return lead * Double(source.sampleRate ?? 48_000) * Double(max(1, source.channels ?? 2)) <= maxLeadSamples ? [soundFromZero] : []
    }

    /// Reads the first audio stream's peaks (1000 a second; fewer for files over an hour, at most 4 million), on the
    /// file's clock: a sound that starts late starts late in the waveform too, under the picture it plays with.
    static func peaks(_ source: MediaSource) -> Peaks? {
        guard source.hasAudio, let ff = FFmpeg.shared else { return nil }
        let sampleRate = Double(source.sampleRate ?? 48_000)
        let channels = max(1, source.channels ?? 2)
        let duration = max(source.duration, 1)
        let peakRate = min(1000, max(50, 4_000_000 / duration))
        let bucket = max(1, Int((sampleRate / peakRate).rounded()))
        let rate = sampleRate / Double(bucket)
        var values: [Float] = []
        // The length is what the file claims; a damaged or crafted one can claim years. Reserve no more than an
        // honest long file needs (the array still grows with the sound that is really there).
        values.reserveCapacity(Int(min(duration * rate, 8_000_000)) + 16)
        // A sound too far in to pad in ffmpeg (soundFromZero) gets its silent lead here, a bucket at a time.
        let pad = soundFromZero(source)
        if pad.isEmpty { values.append(contentsOf: repeatElement(0, count: Int(min(source.audioStart * rate, 8_000_000)))) }
        var current: Float = 0, filled = 0
        var pending = Data()
        let frameBytes = 4 * channels
        let status = runBinary(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", source.url.path,
                                         "-map", "0:a:0", "-vn"] + (pad.isEmpty ? [] : ["-af"] + pad)
                                         + ["-ac", String(channels), "-f", "f32le", "-"]) { chunk in
            pending.append(chunk)
            let usable = pending.count - pending.count % frameBytes
            guard usable > 0 else { return }
            // Copy into an aligned buffer: the pipe hands over chunks of any length.
            var floats = [Float](repeating: 0, count: usable / 4)
            _ = floats.withUnsafeMutableBytes { pending.copyBytes(to: $0, from: pending.startIndex..<(pending.startIndex + usable)) }
            for f in 0..<(usable / frameBytes) {
                var m: Float = 0
                for c in 0..<channels { m = max(m, abs(floats[f * channels + c])) }
                current = max(current, m)
                filled += 1
                if filled == bucket { values.append(min(1, current)); current = 0; filled = 0 }
            }
            pending = pending.count > usable ? Data(pending[(pending.startIndex + usable)...]) : Data()
        }
        if filled > 0 { values.append(min(1, current)) }
        guard status == 0 || !values.isEmpty else { return nil }
        var coarse: [Float] = []
        coarse.reserveCapacity(values.count / Peaks.coarseFactor + 1)
        var i = 0
        while i < values.count {
            coarse.append(values[i..<min(values.count, i + Peaks.coarseFactor)].max() ?? 0)
            i += Peaks.coarseFactor
        }
        return Peaks(rate: rate, values: values, coarse: coarse)
    }

    /// Runs a tool and hands its standard output to `onChunk` as it arrives (binary-safe; stderr is discarded).
    @discardableResult
    static func runBinary(_ tool: URL, _ args: [String], onChunk: (Data) -> Void) -> Int32 {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return -1 }
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            onChunk(chunk)
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: Preview proxies

    /// Whether AVFoundation can preview `source` itself (it plays mp4, mov, m4a, mp3, wav, aiff, flac…, not mkv,
    /// webm, avi, wmv or wma), with a video track when the file has a picture. Asks AVFoundation, so it is right
    /// for each Mac. Calls `done` on the main thread.
    static func checkPlayable(_ source: MediaSource, done: @escaping (Bool) -> Void) {
        let asset = AVURLAsset(url: source.url)
        Task {
            var ok = false
            do {
                let (playable, tracks) = try await asset.load(.isPlayable, .tracks)
                let hasVideoTrack = tracks.contains { $0.mediaType == .video }
                let hasAudioTrack = tracks.contains { $0.mediaType == .audio }
                ok = playable && (!source.hasVideo || hasVideoTrack) && (source.hasVideo || hasAudioTrack)
            } catch { ok = false }
            let result = ok
            await MainActor.run { done(result) }
        }
    }

    /// Writes a preview copy AVFoundation plays into `dir`: H.264 (VideoToolbox, short GOP for quick exact seeks),
    /// upright with square pixels and at most 1280 on its longer side, plus AAC; an .m4a for audio. Times match the
    /// original's, so a time on the proxy is the same time in the original. Edits still read the original.
    static func makeProxy(_ source: MediaSource, in dir: URL, job: MediaJob? = nil, progress: @escaping (Double) -> Void) throws -> URL {
        _ = try ffmpeg()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if source.hasVideo {
            let out = dir.appendingPathComponent("preview.mp4")
            let size = fitted(source.displaySize, maxSide: 1280)
            var args = ["-map", "0:v:0"] + (source.hasAudio ? ["-map", "0:a:0"] : [])
            args += ["-vf", "scale=\(Int(size.width)):\(Int(size.height)),setsar=1",
                     "-c:v", "h264_videotoolbox", "-q:v", "55", "-allow_sw", "1", "-pix_fmt", "yuv420p", "-g", "12", "-tag:v", "avc1"]
            // Every frame at the original's own time. An mp4 defaults to a constant rate on 1/fps steps, which moves
            // frames that aren't on them (wmv's start at 0.046 s on whole milliseconds; variable rates): the preview
            // would show each such frame early, and the frame tools decide from the time of the frame on screen.
            args += ["-fps_mode", "vfr", "-enc_time_base:v", "1:90000"]
            args += source.hasAudio ? ["-c:a", "aac", "-b:a", "160k"] : ["-an"]
            args += ["-movflags", "+faststart"]
            try runFFmpeg(input: source.url, output: out, args: args, duration: source.duration, job: job, progress: progress)
            return out
        }
        let out = dir.appendingPathComponent("preview.m4a")
        try runFFmpeg(input: source.url, output: out, args: ["-map", "0:a:0", "-vn", "-c:a", "aac", "-b:a", "192k"],
                      duration: source.duration, job: job, progress: progress)
        return out
    }

    /// `FFmpeg.run` that a `MediaJob` can stop: the same arguments, progress and error messages; a cancelled run
    /// deletes its output and throws "Cancelled.".
    static func runFFmpeg(input: URL, output: URL, args: [String], duration: Double?, inputOptions: [String] = [],
                          job: MediaJob?, progress: @escaping (Double) -> Void) throws {
        let ff = try ffmpeg()
        guard let job else {
            try ff.run(input: input, output: output, args: args, duration: duration, inputOptions: inputOptions, progress: progress)
            return
        }
        let process = Process()
        process.executableURL = ff.tool
        let decode = inputOptions.contains("-hwaccel") ? [] : ff.decodeOptions(for: input)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + decode + inputOptions + ["-i", input.path] + args
            + ["-progress", "pipe:1", "-nostats", output.path]
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let lock = NSLock()
        var errData = Data(), pending = Data()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); pending.append(chunk)
            var lines: [String] = []
            while let nl = pending.firstIndex(of: 0x0A) {
                lines.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...nl)
            }
            lock.unlock()
            for line in lines where line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                if let duration, duration > 0, let us = Double(line.split(separator: "=").last ?? "") {
                    progress(min(1, max(0, us / 1_000_000 / duration)))
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); errData.append(chunk); lock.unlock()
        }
        guard job.attach(process) else { throw ConversionError.toolFailed("Cancelled.") }
        try process.run()
        process.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        let rest = err.fileHandleForReading.readDataToEndOfFile()
        lock.lock(); errData.append(rest); lock.unlock()
        if job.isCancelled {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.toolFailed("Cancelled.")
        }
        if process.terminationStatus != 0 {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.toolFailed(FFmpeg.failureMessage(String(decoding: errData, as: UTF8.self))
                                             ?? "ffmpeg exited with status \(process.terminationStatus)")
        }
    }

    /// A fresh folder for one editor's preview proxy, and removal of folders left behind by a crash (over a day old).
    static func makePreviewFolder() -> URL {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
        if let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for item in items where item.lastPathComponent.hasPrefix("dropwheel-media-preview-") {
                let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
                if date.timeIntervalSinceNow < -86_400 { try? fm.removeItem(at: item) }
            }
        }
        return base.appendingPathComponent("dropwheel-media-preview-\(UUID().uuidString)")
    }
}

/// A running tool its owner can stop (closing an editor stops the preview proxy it was making).
final class MediaJob {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }

    /// Remembers the process to stop; false when the job was already cancelled (then don't start it).
    fileprivate func attach(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        process = p
        return true
    }
}

// MARK: - Measurements (self-tests)

/// Measurements for media self-tests, all through ffmpeg: decoded frame times, a frame's pixels, PSNR, PCM samples
/// and file hashes. Slow-ish (they decode), so use them on the short fixtures.
enum MediaMeasure {
    /// The presentation time of every decoded video frame.
    static func frameTimes(_ url: URL) -> [Double] {
        guard let ff = FFmpeg.shared,
              let result = try? ProcessRunner.run(ff.tool, ["-hide_banner", "-nostdin", "-i", url.path, "-map", "0:v:0",
                                                            "-vf", "showinfo", "-f", "null", "-"]) else { return [] }
        return result.stderr.matches(of: #/pts_time:(-?[0-9.]+)/#).compactMap { Double($0.1) }
    }

    /// Frame `index` (in decode-output order) as packed RGB bytes scaled to `width` × `height`. `crop` first cuts the
    /// picture to that many pixels from the top-left (to compare with an output whose odd size was evened).
    static func frameRGB(_ url: URL, index: Int, width: Int = 320, height: Int = 180, crop: CGSize? = nil) -> [UInt8]? {
        guard let ff = FFmpeg.shared, index >= 0 else { return nil }
        var data = Data()
        let cropFilter = crop.map { "crop=\(Int($0.width)):\(Int($0.height)):0:0," } ?? ""
        let status = MediaKit.runBinary(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", url.path, "-map", "0:v:0",
                                                  "-vf", "select=eq(n\\,\(index)),\(cropFilter)scale=\(width):\(height),format=rgb24",
                                                  "-frames:v", "1", "-f", "rawvideo", "-"]) { data.append($0) }
        guard status == 0, data.count == width * height * 3 else { return nil }
        return [UInt8](data)
    }

    /// Frame `index`'s luma plane as stored (no colour conversion), averaged down to `width` × `height`: compares
    /// pictures decoded by different decoders without colour-matrix differences getting in the way.
    static func frameLuma(_ url: URL, index: Int, width: Int = 160, height: Int = 90) -> [UInt8]? {
        guard let ff = FFmpeg.shared, index >= 0 else { return nil }
        var data = Data()
        let status = MediaKit.runBinary(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", url.path, "-map", "0:v:0",
                                                  "-vf", "select=eq(n\\,\(index)),extractplanes=y,scale=\(width):\(height):flags=area",
                                                  "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "gray", "-"]) { data.append($0) }
        guard status == 0, data.count == width * height else { return nil }
        return [UInt8](data)
    }

    /// A luma plane (8-bit, `rowBytes` apart) averaged down to `width` × `height` (for player frames).
    static func areaAverage(_ plane: UnsafePointer<UInt8>, width w: Int, height h: Int, rowBytes: Int, to width: Int, _ height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        for oy in 0..<height {
            let y0 = oy * h / height, y1 = max(y0 + 1, (oy + 1) * h / height)
            for ox in 0..<width {
                let x0 = ox * w / width, x1 = max(x0 + 1, (ox + 1) * w / width)
                var sum = 0
                for y in y0..<y1 { for x in x0..<x1 { sum += Int(plane[y * rowBytes + x]) } }
                out[oy * width + ox] = UInt8(sum / ((y1 - y0) * (x1 - x0)))
            }
        }
        return out
    }

    /// Peak signal-to-noise ratio in dB (infinity for identical pictures).
    static func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sum = 0.0
        for i in 0..<a.count { let d = Double(a[i]) - Double(b[i]); sum += d * d }
        let mse = sum / Double(a.count)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    /// The first audio stream decoded to 16-bit samples (channels interleaved), at its own rate unless `rate` is given.
    /// `fileClock` pads the start with silence so sample i is at i / rate on the file's clock (the picture's), not
    /// counted from the first decoded sample.
    static func pcm(_ url: URL, rate: Int? = nil, channels: Int? = nil, fileClock: Bool = false) -> [Int16] {
        guard let ff = FFmpeg.shared else { return [] }
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", url.path, "-map", "0:a:0"]
        if fileClock { args += ["-af", MediaKit.soundFromZero] }
        if let rate { args += ["-ar", String(rate)] }
        if let channels { args += ["-ac", String(channels)] }
        args += ["-f", "s16le", "-"]
        var data = Data()
        MediaKit.runBinary(ff.tool, args) { data.append($0) }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    static func sha256(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
