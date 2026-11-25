import Foundation

/// Thin wrapper around an ffmpeg binary: probing, progress, and the argument recipes YummyOrange uses.
struct FFmpeg {
    let tool: URL

    /// The ffmpeg in use, looked for again if its file has gone since it was found.
    static var shared: FFmpeg? { Capabilities.shared.liveFFmpegFound.map { FFmpeg(tool: $0.ffmpeg) } }

    struct MediaInfo {
        var duration: Double?
        /// ffmpeg could open the file and list its streams ("Input #0, …").
        var opened = false
        var hasVideo = false
        var hasAudio = false
        /// The first video stream's codec as ffmpeg names it ("h264", "av1").
        var videoCodec: String?
        var audioCodec: String?
        /// The first audio stream's channel layout as ffmpeg names it ("mono", "stereo", "5.1(side)", "6 channels").
        var audioLayout: String?
        var channels: Int?
        /// The first audio stream's bit rate in kb/s, when ffmpeg reports one (not for FLAC and other VBR streams).
        var audioBitrate: Int?

        /// True for layouts other than plain mono and stereo (5.1(side), 7.1(wide), quad, …).
        var hasSurroundLayout: Bool {
            guard hasAudio else { return false }
            if let layout = audioLayout { return layout != "mono" && layout != "stereo" }
            return (channels ?? 0) > 2
        }
    }

    /// ffmpeg with only an input prints stream info to stderr and exits non-zero; that's enough to probe.
    func probe(_ url: URL) -> MediaInfo {
        guard let result = try? ProcessRunner.run(tool, ["-hide_banner", "-nostdin", "-i", url.path]) else { return MediaInfo() }
        return Self.parse(result.stderr)
    }

    /// Reads ffmpeg's stream report (what `ffmpeg -i` prints).
    static func parse(_ text: String) -> MediaInfo {
        var info = MediaInfo()
        info.opened = text.split(separator: "\n").contains { $0.hasPrefix("Input #") }
        if let m = text.firstMatch(of: #/Duration: (\d+):(\d+):([0-9.]+)/#),
           let h = Double(m.1), let mi = Double(m.2), let s = Double(m.3) {
            info.duration = h * 3600 + mi * 60 + s
        }
        for line in text.split(separator: "\n") where line.contains("Stream #") {
            // Cover art in audio files shows up as an "attached pic" video stream; ignore it.
            if line.contains("Video:") && !line.contains("attached pic") {
                info.hasVideo = true
                if info.videoCodec == nil, let m = line.firstMatch(of: #/Video: ([a-z0-9_]+)/#) { info.videoCodec = String(m.1) }
            }
            if line.contains("Audio:") {
                let first = !info.hasAudio
                info.hasAudio = true
                if info.audioCodec == nil, let m = line.firstMatch(of: #/Audio: ([a-z0-9_]+)/#) {
                    info.audioCodec = String(m.1)
                }
                guard first else { continue }
                // "Audio: ac3, 48000 Hz, 5.1(side), fltp, 448 kb/s": the field after the rate is the layout.
                let fields = String(line).components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
                if let hz = fields.firstIndex(where: { $0.hasSuffix(" Hz") }), hz + 1 < fields.count {
                    info.audioLayout = fields[hz + 1]
                }
                info.channels = MoreFormats.MediaProbe.channelCount(String(line))
                if let m = line.firstMatch(of: #/, (\d+) kb\/s/#) { info.audioBitrate = Int(m.1) }
            }
        }
        return info
    }

    /// Runs ffmpeg with progress reporting. `progress` receives 0...1 when the duration is known (pass the
    /// output's length). `inputOptions` go before `-i` (e.g. `-ss` for a fast, exact seek).
    func run(input: URL, output: URL, args: [String], duration: Double?, inputOptions: [String] = [],
             extraInputs: [String] = [], progress: @escaping (Double) -> Void) throws {
        let decode = inputOptions.contains("-hwaccel") ? [] : decodeOptions(for: input)
        var full = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + decode + inputOptions + ["-i", input.path]
        full += extraInputs
        full += args
        full += ["-progress", "pipe:1", "-nostats", output.path]
        let result = try ProcessRunner.run(tool, full) { line in
            guard let duration, duration > 0, line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms="),
                  let micros = Double(line.split(separator: "=").last ?? "") else { return }
            progress(min(1, max(0, micros / 1_000_000 / duration)))
        }
        if result.status != 0 {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.toolFailed(Self.failureMessage(result.stderr) ?? "ffmpeg exited with status \(result.status)")
        }
    }

    /// Lines ffmpeg prints as a consequence of an earlier error; they never say what went wrong.
    private static let followUpErrors = [
        "Nothing was written into output file", "Conversion failed", "Error while opening encoder",
        "Could not open encoder before EOF", "Error sending frames to consumers", "Task finished with error code",
        "Terminating thread with return code", "Error while filtering", "Error marking filters as finished",
        "Error while processing the decoded data", "Error initializing output stream", "Error submitting",
        "Error closing", "Error opening output file", "Could not write header",
        "Error parsing options for output file", "To ignore this, add a trailing",
    ]

    /// What an AV1 video says on a Mac whose ffmpeg can only decode AV1 in hardware, and the hardware has no AV1
    /// decoder (before M3): FFmpeg's "Your platform doesn't support hardware accelerated AV1 decoding."
    static let av1Unsupported = "This video is in AV1, which this Mac can’t decode. A Mac with M3 or later can, "
        + "or install a full ffmpeg (for example with Homebrew)."

    /// Input options for reading `url`: `-hwaccel videotoolbox` for an AV1 video when this Mac's ffmpeg decodes AV1
    /// only with the Mac's hardware (YummyOrange's own copy, which has no dav1d; M3 and later decode AV1). Empty
    /// otherwise; nothing is probed when the ffmpeg decodes AV1 itself or the file isn't a video.
    func decodeOptions(for url: URL) -> [String] {
        guard MoreFormats.kind(url) == .video, !Capabilities.shared.decodesAV1InSoftware else { return [] }
        return videoCodec(of: url) == "av1" ? ["-hwaccel", "videotoolbox"] : []
    }

    private static let codecLock = NSLock()
    private static var codecs: [String: String] = [:]

    /// The first video stream's codec ("" for none), asked once per file and version of it.
    func videoCodec(of url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = "\(url.standardizedFileURL.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
        Self.codecLock.lock()
        let known = Self.codecs[key]
        Self.codecLock.unlock()
        if let known { return known }
        let codec = probe(url).videoCodec ?? ""
        Self.codecLock.lock(); Self.codecs[key] = codec; Self.codecLock.unlock()
        return codec
    }

    /// Operating-system errors that say what went wrong wherever they appear.
    private static let systemErrors = ["No space left on device", "File too large", "Disk quota exceeded", "Permission denied",
                                       "Read-only file system", "Operation not permitted"]

    /// The error line that names the cause: the first one that isn't a follow-up ("Nothing was written…",
    /// "Could not write header…"), since ffmpeg reports the cause before its consequences; else the last
    /// line. "[wmav2 @ 0x7578c48a80] too many…" becomes "[wmav2] too many…".
    static func failureMessage(_ stderr: String) -> String? {
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.replacing(#/ @ 0x[0-9a-fA-F]+\]/#, with: "]").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // The system's own words for a full disk or a folder it can't write to name the cause even on a follow-up
        // line ("Error submitting a packet to the muxer: File too large", then "Last message repeated 1 times").
        if let system = lines.first(where: { line in systemErrors.contains { line.localizedCaseInsensitiveContains($0) } }) { return system }
        if lines.contains(where: { $0.localizedCaseInsensitiveContains("hardware accelerated AV1 decoding") }) { return av1Unsupported }
        let causes = lines.filter { line in !followUpErrors.contains { line.localizedCaseInsensitiveContains($0) } }
        return causes.first ?? lines.last
    }

    // MARK: - Recipes

    static func audioArgs(for format: OutputFormat, bitrate: String = "192k") -> [String] {
        let caps = Capabilities.shared
        switch format {
        case .mp3: return ["-c:a", "libmp3lame", "-b:a", bitrate]
        case .m4a: return ["-c:a", caps.has("aac_at") ? "aac_at" : "aac", "-b:a", bitrate]
        case .wav: return ["-c:a", "pcm_s16le"]
        case .aiff: return ["-c:a", "pcm_s16be"]
        case .flac: return ["-c:a", "flac", "-compression_level", "8"]
        case .opus: return caps.has("libopus") ? ["-c:a", "libopus", "-b:a", "160k"]
                                               : ["-c:a", "opus", "-strict", "experimental", "-b:a", "160k"]
        case .ogg: return caps.has("libvorbis") ? ["-c:a", "libvorbis", "-q:a", "6"]
                                                : ["-c:a", "vorbis", "-strict", "experimental", "-ac", "2", "-b:a", bitrate]
        default: return []
        }
    }

    /// libopus only takes the Vorbis channel orders (mono, stereo, 3.0, quad, 5.0, 5.1, 6.1, 7.1): it refuses
    /// 5.1(side), the layout of most AC-3 movie soundtracks and 5.1 FLAC/WAV, and 7.1(wide), hexagonal…
    /// This filter remaps those to the nearest layout it takes (5.1(side) → 5.1) instead of failing.
    static let opusLayoutFilter = "aformat=channel_layouts=7.1|6.1|5.1|5.0|quad|3.0|stereo|mono"

    /// Options that make `info`'s audio fit the Opus encoder that `audioArgs(for: .opus)` picks:
    /// libopus gets `opusLayoutFilter` for layouts other than mono and stereo, ffmpeg's own encoder
    /// (stereo at most) a downmix. Empty for mono and stereo sources.
    static func opusFit(_ info: MediaInfo) -> [String] {
        guard info.hasSurroundLayout else { return [] }
        return Capabilities.shared.has("libopus") ? ["-af", opusLayoutFilter] : ["-ac", "2"]
    }

    /// Scales the shorter side down to `maxShortSide` (even sizes), so a portrait 1080 × 1920 phone video stays
    /// 1080 × 1920 and a 4K one becomes 1080p in either orientation. Smaller videos are left as they are.
    static func shortSideScale(_ maxShortSide: Int) -> String {
        "scale='if(gt(iw,ih),-2,min(\(maxShortSide),trunc(iw/2)*2))':'if(gt(iw,ih),min(\(maxShortSide),trunc(ih/2)*2),-2)'"
    }

    /// Video conversion. H.264 goes through VideoToolbox (hardware, no GPL encoder needed).
    /// `maxShortSide` caps the shorter side (see shortSideScale); `maxHeight` caps the height only.
    /// `audioBitrate` is the AAC/Opus rate; `audioFilter` is added as the audio stream's filter (`-af`).
    static func videoArgs(for format: OutputFormat, quality: Int = 65, maxHeight: Int? = nil, maxShortSide: Int? = nil,
                          audioBitrate: String? = nil, audioFilter: String? = nil) -> [String] {
        var vf: [String] = []
        if let maxShortSide { vf.append(shortSideScale(maxShortSide)) }
        else if let maxHeight { vf.append("scale=-2:'min(\(maxHeight),ih)'") }
        let scale = vf.isEmpty ? [] : ["-vf", vf.joined(separator: ",")]
        let af = audioFilter.map { ["-af", $0] } ?? []
        switch format {
        case .webm:
            return ["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "33",
                    "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-pix_fmt", "yuv420p"] + scale
                + (Capabilities.shared.has("libopus") ? ["-c:a", "libopus", "-b:a", audioBitrate ?? "128k"] + af : ["-an"])
        case .mp4, .mov, .mkv:
            var args = ["-map", "0:v:0", "-map", "0:a:0?",
                        "-c:v", "h264_videotoolbox", "-q:v", String(quality), "-allow_sw", "1",
                        "-pix_fmt", "yuv420p", "-tag:v", "avc1"] + scale
            args += ["-c:a", "aac", "-b:a", audioBitrate ?? "192k"] + af
            if format != .mkv { args += ["-movflags", "+faststart"] }
            if format == .mkv { args.removeAll { $0 == "-tag:v" || $0 == "avc1" } }
            return args
        default:
            return []
        }
    }

    /// Animated GIF through a per-clip palette. GIF has square pixels (readers ignore its aspect byte), so
    /// anamorphic video (HDV 1440 × 1080, DVD 720 × 480) is first stretched to its display shape.
    static func gifArgs(fps: Int = 12, maxWidth: Int = 720) -> [String] {
        ["-filter_complex",
         "[0:v]scale='trunc(iw*sar/2)*2':ih,setsar=1,fps=\(fps),scale='min(\(maxWidth),iw)':-2:flags=lanczos,split[a][b];"
            + "[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a",
         "-an", "-loop", "0"]
    }
}

/// A box blur in this Mac's ffmpeg: boxblur where it is there (a GPL-only filter: Homebrew's ffmpeg has it), else the
/// same box average from avgblur, which every build has (YummyOrange's own LGPL ffmpeg among them). `passes` boxes in a
/// row come close to a Gaussian. `chroma` is boxblur's colour radius for a colour picture (nil: one plane, as
/// Visualize's grey mask). avgblur blurs each plane by `radius` of its own pixels, so a colour picture is first brought
/// to planes of one size (4:4:4 or RGB, at its own bit depth): its colour then gets the blur boxblur gives it, and the
/// Redact preview's Gaussian matches either.
enum BoxBlur {
    /// Formats whose planes are all the size of the picture (what avgblur takes, at 8 to 16 bits).
    static let fullPlanes = "yuv444p|yuv444p10le|yuv444p12le|yuv444p16le|gbrp|gbrp10le|gbrp12le|gbrp16le|gray|gray10le|gray16le"

    static func filter(radius: Int, passes: Int, chroma: String? = nil,
                       boxblur: Bool = Capabilities.shared.hasFilter("boxblur")) -> String {
        if boxblur {
            var filter = "boxblur=luma_radius=\(radius):luma_power=\(passes)"
            if let chroma { filter += ":chroma_radius=\(chroma):chroma_power=\(passes)" }
            return filter
        }
        let blur = Array(repeating: "avgblur=sizeX=\(radius)", count: max(1, passes)).joined(separator: ",")
        return chroma == nil ? blur : "format=pix_fmts=\(fullPlanes),\(blur)"
    }
}
