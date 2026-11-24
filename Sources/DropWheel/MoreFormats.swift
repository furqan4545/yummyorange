import AppKit

/// WMA, AVI and WMV; subtitles (SRT, VTT, TXT); archives (ZIP, TAR, GZIP, extract, RAR read-only); compress to a target size.
/// The media conversions live here; Subtitles.swift, Archives.swift and TargetSize.swift hold the rest.
enum MoreFormats: FeatureModule {
    static var commands: [WheelCommand] {
        mediaCommands + Subtitles.commands + Archives.commands + TargetSize.commands
    }

    static func selfTest(_ name: String) -> String? {
        #if DEBUG
        switch name {
        case "subtitles": return Subtitles.selfTest()
        case "archives": return Archives.selfTest()
        case "target-size": return TargetSize.selfTest()
        case "media-probe": return MediaProbe.selfTest()
        case "more-formats":
            let reports = [Subtitles.selfTest(), Archives.selfTest(), TargetSize.selfTest(), MediaProbe.selfTest()]
            let failed = reports.contains { $0.hasPrefix("FAIL") }
            return (failed ? "FAIL\n" : "OK\n") + reports.joined(separator: "\n")
        default: return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: WMA, AVI, WMV

    private static var mediaCommands: [WheelCommand] {
        [
            WheelCommand(wheel: .convert, id: "wma", title: "WMA",
                         applies: { offers($0, kinds: [.audio, .video], ext: "wma", encoders: ["wmav2"]) },
                         run: { files, _, progress in try files.map { try toWMA($0, progress: progress) } }),
            WheelCommand(wheel: .convert, id: "avi", title: "AVI",
                         applies: { offers($0, kinds: [.video], ext: "avi", encoders: ["mpeg4"]) },
                         run: { files, _, progress in try files.map { try toAVI($0, progress: progress) } }),
            WheelCommand(wheel: .convert, id: "wmv", title: "WMV",
                         applies: { offers($0, kinds: [.video], ext: "wmv", encoders: ["wmv2", "wmav2"]) },
                         run: { files, _, progress in try files.map { try toWMV($0, progress: progress) } }),
        ]
    }

    /// Every file is one of `kinds`, not all of them are already `ext`, and ffmpeg has the encoders.
    private static func offers(_ files: [URL], kinds: Set<FileKind>, ext: String, encoders: [String]) -> Bool {
        guard Capabilities.shared.ffmpeg != nil, encoders.allSatisfy(Capabilities.shared.has) else { return false }
        return !files.isEmpty && files.allSatisfy { kinds.contains(kind($0)) }
            && !files.allSatisfy { Ext.of($0) == ext }
    }

    static func toWMA(_ url: URL, progress: @escaping (Double) -> Void) throws -> URL {
        let (ff, info) = try probe(url)
        try info.requireReadable(url)
        guard info.hasAudio else { throw ConversionError.unsupported("\(url.lastPathComponent) has no audio track.") }
        let out = outputURL(for: url, ext: "wma")
        let args = ["-vn", "-map", "0:a:0", "-c:a", "wmav2", "-b:a", info.channels == 1 ? "128k" : "192k"]
            + info.audioFit(maxRate: 48_000, maxChannels: 2)
        try ff.run(input: url, output: out, args: args, duration: info.duration, progress: progress)
        return out
    }

    /// MPEG-4 Part 2 video (tagged XVID, which every AVI player knows) with MP3 audio, at a high fixed quality
    /// (q 4: SSIM 0.990 against the source on a detailed test clip; q 3 was 30% bigger for 0.002 more).
    static func toAVI(_ url: URL, progress: @escaping (Double) -> Void) throws -> URL {
        let (ff, info) = try probe(url)
        try info.requireReadable(url)
        guard info.hasVideo else { throw ConversionError.unsupported("\(url.lastPathComponent) has no video track.") }
        let out = outputURL(for: url, ext: "avi")
        // AVI has no variable frame rate and MPEG-4 Part 2 caps the time base, so pin a constant rate.
        var args = ["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "mpeg4", "-vtag", "XVID", "-q:v", "4", "-g", "250",
                    "-pix_fmt", "yuv420p", "-vf", MediaProbe.evenSize, "-r", info.constantRate]
        if info.hasAudio {
            args += Capabilities.shared.has("libmp3lame") ? ["-c:a", "libmp3lame", "-b:a", "192k"] : ["-c:a", "mp2", "-b:a", "224k"]
            args += info.audioFit(maxRate: 48_000, maxChannels: 2)
        }
        try ff.run(input: url, output: out, args: args, duration: info.duration, progress: progress)
        return out
    }

    /// Windows Media Video 8 with Windows Media Audio 2 in an ASF container.
    static func toWMV(_ url: URL, progress: @escaping (Double) -> Void) throws -> URL {
        let (ff, info) = try probe(url)
        try info.requireReadable(url)
        guard info.hasVideo else { throw ConversionError.unsupported("\(url.lastPathComponent) has no video track.") }
        let out = outputURL(for: url, ext: "wmv")
        var args = ["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "wmv2", "-q:v", "4", "-g", "250",
                    "-pix_fmt", "yuv420p", "-vf", MediaProbe.evenSize]
        if info.hasAudio {
            args += ["-c:a", "wmav2", "-b:a", info.channels == 1 ? "128k" : "192k"] + info.audioFit(maxRate: 48_000, maxChannels: 2)
        }
        try ff.run(input: url, output: out, args: args, duration: info.duration, progress: progress)
        return out
    }

    /// FileKind, plus media extensions macOS declares no type for (on macOS 27 .mkv, .mka, .asf, .vob,
    /// .divx and .ape all come back as plain data), so those files still get these petals.
    static func kind(_ url: URL) -> FileKind {
        let k = FileKind.of(url)
        guard k == .other else { return k }
        switch Ext.of(url) {
        case "mkv", "asf", "vob", "divx", "ogm": return .video
        case "mka", "ape", "wv": return .audio
        default: return .other
        }
    }

    private static func probe(_ url: URL) throws -> (FFmpeg, MediaProbe) {
        guard let ff = FFmpeg.shared else { throw ConversionError.missingTool("ffmpeg") }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw ConversionError.unreadable(url.lastPathComponent) }
        return (ff, MediaProbe.of(url, ffmpeg: ff))
    }
}

extension MoreFormats {
    /// What `ffmpeg -i` reports about a file, with more detail than FFmpeg.MediaInfo: frame size,
    /// frame rate, sample rate and channel count. (No ffprobe needed.)
    struct MediaProbe {
        var duration: Double?
        /// ffmpeg could open the file and read its streams ("Input #0, …"). False for damaged,
        /// truncated or non-media files, which would otherwise look like files with no tracks.
        var opened = false
        var hasVideo = false
        var hasAudio = false
        /// Stored frame size (before rotation; only the pixel count matters to callers).
        var width = 0
        var height = 0
        /// Average frame rate ("fps"); for variable-rate video (screen recordings, phone clips) this is
        /// far below the rate of the busy parts.
        var fps: Double?
        /// The stream's base rate ("tbr"): the rate its fastest stretches run at.
        var tbr: Double?
        var sampleRate: Int?
        var channels: Int?

        /// A scale filter that rounds odd frame sizes down to even ones (4:2:0 video and WMV need even sizes).
        static let evenSize = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

        static func of(_ url: URL, ffmpeg: FFmpeg) -> MediaProbe {
            var info = MediaProbe()
            guard let result = try? ProcessRunner.run(ffmpeg.tool, ["-hide_banner", "-nostdin", "-i", url.path]) else { return info }
            info.parse(result.stderr)
            return info
        }

        mutating func parse(_ text: String) {
            opened = text.split(separator: "\n").contains { $0.hasPrefix("Input #") }
            if let m = text.firstMatch(of: #/Duration: (\d+):(\d+):([0-9.]+)/#),
               let h = Double(m.1), let mi = Double(m.2), let s = Double(m.3) {
                duration = h * 3600 + mi * 60 + s
            }
            for raw in text.split(separator: "\n") where raw.contains("Stream #") {
                let line = String(raw)
                if line.contains("Video:") && !line.contains("attached pic") && !hasVideo {
                    hasVideo = true
                    if let m = line.firstMatch(of: #/, (\d{1,5})x(\d{1,5})/#), let w = Int(m.1), let h = Int(m.2) {
                        width = w; height = h
                    }
                    if let m = line.firstMatch(of: #/([0-9.]+) tbr/#) { tbr = Double(m.1) }
                    if let m = line.firstMatch(of: #/([0-9.]+) fps/#) { fps = Double(m.1) } else { fps = tbr }
                } else if line.contains("Audio:") && !hasAudio {
                    hasAudio = true
                    if let m = line.firstMatch(of: #/(\d+) Hz/#) { sampleRate = Int(m.1) }
                    channels = Self.channelCount(line)
                }
            }
        }

        /// ffmpeg's named channel layouts that aren't written as "5.1" and the like.
        private static let namedLayouts: [String: Int] = [
            "mono": 1, "stereo": 2, "downmix": 2, "binaural": 2, "quad": 4,
            "hexagonal": 6, "octagonal": 8, "cube": 8, "hexadecagonal": 16,
        ]

        /// Channels from the layout ffmpeg prints: "mono", "stereo", "5.1(side)", "7.1.4", "hexagonal",
        /// "4 channels" and so on.
        static func channelCount(_ line: String) -> Int? {
            let fields = line.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
            for f in fields {
                if let m = f.firstMatch(of: #/^(\d+) channels/#) { return Int(m.1) }
                // "quad(side)", "7.1(wide)": the part before the bracket names the layout.
                let name = f.prefix { $0 != "(" }
                if let n = namedLayouts[String(name)] { return n }
                if name.wholeMatch(of: #/\d{1,2}(\.\d{1,2}){1,2}/#) != nil {
                    return name.split(separator: ".").compactMap { Int($0) }.reduce(0, +)   // 5.1 → 6, 7.1.4 → 12, 22.2 → 24
                }
            }
            return nil
        }

        /// Resampling and downmix options for encoders with limits (WMA and MP3 stop at 48 kHz and two channels).
        /// A layout this parser doesn't know is downmixed too: mono and stereo are always recognised.
        func audioFit(maxRate: Int, maxChannels: Int) -> [String] {
            var args: [String] = []
            if let rate = sampleRate, rate > maxRate { args += ["-ar", String(maxRate)] }
            if (channels ?? .max) > maxChannels { args += ["-ac", String(maxChannels)] }
            return args
        }

        /// Throws a clear message when ffmpeg couldn't open the file at all (instead of "has no video track").
        func requireReadable(_ url: URL) throws {
            guard opened else {
                throw ConversionError.unsupported("\(url.lastPathComponent) can’t be read as video or audio. "
                                                  + "It may be damaged, incomplete or not a media file.")
            }
        }

        /// A constant rate that keeps every frame: the higher of the average rate and the base rate (tbr),
        /// since a variable-rate video's average is far below the rate of its busy parts (repeating frames in
        /// the still parts is harmless; dropping frames in the busy parts is not). Exact fractions for the
        /// NTSC rates (29.97 → 30000/1001); 30 when unknown.
        var constantRate: String {
            guard let fps = [fps, tbr].compactMap({ $0 }).filter({ $0 >= 1 && $0 <= 240 }).max() else { return "30" }
            for (approx, exact) in [(23.976, "24000/1001"), (29.97, "30000/1001"), (59.94, "60000/1001"), (119.88, "120000/1001")]
            where abs(fps - approx) < 0.02 { return exact }
            return fps == fps.rounded() ? String(Int(fps)) : String(format: "%.3f", fps)
        }

        /// `--selftest media-probe`: parsing of ffmpeg's stream report (no ffmpeg needed) and .ts sniffing.
        static func selfTest() -> String {
            var failures: [String] = []
            func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
                if !ok { failures.append("\(name) \(detail())") }
            }
            func probe(_ text: String) -> MediaProbe { var p = MediaProbe(); p.parse(text); return p }
            let head = "Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'x.mov':\n  Duration: 00:00:02.15, start: 0.000000, bitrate: 900 kb/s\n"

            // A screen recording: 7.65 fps on average, 60 in the busy parts. AVI must run at 60.
            let vfr = probe(head + "  Stream #0:0[0x1]: Video: h264 (High) (avc1 / 0x31637661), yuv420p(progressive), 1280x720, "
                            + "616 kb/s, SAR 1:1 DAR 16:9, 7.65 fps, 60 tbr, 15360 tbn (default)\n")
            check("vfr rate", vfr.constantRate == "60", vfr.constantRate)
            check("vfr size", vfr.width == 1280 && vfr.height == 720 && vfr.opened && vfr.hasVideo)
            let ntsc = probe(head + "  Stream #0:0: Video: h264, yuv420p, 1920x1080, 29.97 fps, 29.97 tbr, 30k tbn\n")
            check("ntsc rate", ntsc.constantRate == "30000/1001", ntsc.constantRate)
            let noTbr = probe(head + "  Stream #0:0: Video: mpeg4, yuv420p, 640x480, 25 fps, 1k tbn\n")
            check("fps only", noTbr.constantRate == "25", noTbr.constantRate)

            // Channel layouts: every one above stereo must be recognised, or downmixed anyway.
            for (layout, n) in [("mono", 1), ("stereo", 2), ("quad(side)", 4), ("5.1(side)", 6), ("hexagonal", 6),
                                ("7.1(wide)", 8), ("octagonal", 8), ("cube", 8), ("5.1.4", 10), ("7.1.4", 12),
                                ("hexadecagonal", 16), ("22.2", 24), ("3 channels (FL+FR+LFE)", 3)] {
                let line = "  Stream #0:0: Audio: pcm_s16le ([1][0][0][0] / 0x0001), 48000 Hz, \(layout), s16, 4608 kb/s"
                check("layout \(layout)", channelCount(line) == n, "\(channelCount(line).map(String.init) ?? "nil")")
            }
            let hex = probe(head + "  Stream #0:0: Audio: pcm_s16le, 48000 Hz, hexagonal, s16, 4608 kb/s\n")
            check("hexagonal → stereo", hex.audioFit(maxRate: 48_000, maxChannels: 2) == ["-ac", "2"], "\(hex.audioFit(maxRate: 48_000, maxChannels: 2))")
            let odd = probe(head + "  Stream #0:0: Audio: pcm_s16le, 96000 Hz, someday-layout, s16, 4608 kb/s\n")
            check("unknown layout → stereo", odd.audioFit(maxRate: 48_000, maxChannels: 2) == ["-ar", "48000", "-ac", "2"])
            let stereo = probe(head + "  Stream #0:0: Audio: aac (LC), 44100 Hz, stereo, fltp, 128 kb/s\n")
            check("stereo untouched", stereo.audioFit(maxRate: 48_000, maxChannels: 2).isEmpty)

            // A damaged file: ffmpeg opens nothing, so it must not look like a file without tracks.
            let broken = probe("[mov,mp4,m4a,3gp,3g2,mj2 @ 0x1] moov atom not found\n/x/holiday.mp4: Invalid data found when processing input\n")
            check("damaged", !broken.opened && !broken.hasVideo)
            check("damaged message", (try? broken.requireReadable(URL(fileURLWithPath: "/x/holiday.mp4"))) == nil)
            check("readable", (try? vfr.requireReadable(URL(fileURLWithPath: "/x/x.mov"))) != nil)

            // ffmpeg's error report: the cause, not the "Nothing was written" that follows it.
            let wmaFailure = """
                [wmav2 @ 0x7578c48a80] too many channels: got 6, need 2 or fewer
                [aost#0:0/wmav2 @ 0x7579040000] [enc:wmav2 @ 0x7578c181c0] Error while opening encoder - maybe incorrect parameters such as bit_rate, rate, width or height.
                [af#0:0 @ 0x7578c54000] Error sending frames to consumers: Invalid argument
                [af#0:0 @ 0x7578c54000] Task finished with error code: -22 (Invalid argument)
                [aost#0:0/wmav2 @ 0x7579040000] [enc:wmav2 @ 0x7578c181c0] Could not open encoder before EOF
                [out#0/asf @ 0x7579018180] Nothing was written into output file, because at least one of its streams received no packets.

                """
            let cause = FFmpeg.failureMessage(wmaFailure)
            check("ffmpeg cause", cause == "[wmav2] too many channels: got 6, need 2 or fewer", cause ?? "nil")
            let onlyFollowUp = FFmpeg.failureMessage("[out#0/asf @ 0x1] Nothing was written into output file.\nConversion failed!\n")
            check("ffmpeg follow-up only", onlyFollowUp == "Conversion failed!", onlyFollowUp ?? "nil")
            check("ffmpeg silent", FFmpeg.failureMessage("\n") == nil)

            // .ts: TypeScript source is not video; packets with a 0x47 sync byte every 188 (or 192) bytes are.
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("dropwheel-probe-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: dir) }
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let code = dir.appendingPathComponent("app.ts"), mts = dir.appendingPathComponent("mod.mts")
                try Data("export function add(a: number, b: number): number {\n  return a + b;\n}\n".utf8).write(to: code)
                try Data(String(repeating: "Ghost = 1 // G\n", count: 200).utf8).write(to: mts)
                func packets(_ size: Int, offset: Int, count: Int) -> Data {
                    var d = Data(repeating: 0xFF, count: offset + size * count)
                    for i in 0..<count { d[offset + i * size] = 0x47; d[offset + i * size + 1] = 0x40 }
                    return d
                }
                let ts = dir.appendingPathComponent("clip.ts"), m2ts = dir.appendingPathComponent("clip.m2ts")
                let cut = dir.appendingPathComponent("cut.ts")
                try packets(188, offset: 0, count: 20).write(to: ts)
                try packets(192, offset: 4, count: 20).write(to: m2ts)
                try packets(188, offset: 77, count: 20).write(to: cut)
                check("typescript .ts", FileKind.of(code) == .other, FileKind.of(code).rawValue)
                check("typescript .mts", FileKind.of(mts) == .other, FileKind.of(mts).rawValue)
                check("mpeg-ts .ts", FileKind.of(ts) == .video, FileKind.of(ts).rawValue)
                check("bdav .m2ts", FileKind.of(m2ts) == .video, FileKind.of(m2ts).rawValue)
                check("mid-packet .ts", FileKind.of(cut) == .video, FileKind.of(cut).rawValue)
                check("missing .ts", FileKind.of(dir.appendingPathComponent("none.ts")) == .video)
                check("mp4 unaffected", FileKind.of(dir.appendingPathComponent("none.mp4")) == .video)
            } catch {
                failures.append("error: \(error.localizedDescription)")
            }
            if Capabilities.shared.ffmpeg != nil {
                let caps = Capabilities.shared
                check("ffmpeg filters are probed (scale, crop, atempo, pan)",
                      ["scale", "crop", "atempo", "pan"].allSatisfy(caps.hasFilter) && !caps.hasFilter("=") && !caps.hasFilter("no-such-filter"))
            }
            return failures.isEmpty ? "OK media-probe: frame rates, channel layouts, damaged files, ffmpeg errors, .ts sniffing, filters"
                                    : "FAIL media-probe:\n" + failures.joined(separator: "\n")
        }
    }

    /// File sizes, as Finder shows them (decimal megabytes).
    enum ByteSize {
        static func of(_ url: URL) -> Int {
            (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }

        static func text(_ bytes: Int) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }
}
