#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import AVFoundation

/// `--selftest media-split`, continued: regression checks for what the review of Split found, each made on clips
/// built here so the failure it guards against shows:
/// - the frame the player shows at a playhead on the frame grid is the frame that starts the next part (23.976 fps,
///   where ffmpeg prints "23.98", and an mkv whose times are whole milliseconds, seen through its preview proxy);
/// - sound alone: no silence at the joins of MP3, M4A and WMA parts, and exact lengths (a click 15 ms after each
///   split is 15 ms into its part);
/// - FLV part 1 keeps its picture; a cut inside a variable-rate gap keeps the picture under its sound; a WebM part
///   that starts on a key frame keeps all its sound; 22.05 kHz splits 0.01 s apart are accepted;
/// - empty parts are refused (a split after sample.wmv's last frame, a truncated download), with nothing written;
///   the parts appear only when all are written, under one free set of names; `at=` without times is an error; an
///   error quotes the time as typed;
/// - the window: the ruler always scrubs (also on a split under the playhead), splits are grabbed in the lanes or
///   by their tab, a split under the playhead stays visible (a 10 pt break), unselected splits aren't drawn in the
///   accent, dense splits go compact, part numbers never skip irregularly, ↑ ↓ select, Return edits the time, a
///   refused typed time says why and stops Save, Save commits a typed time, the real last frame bounds the splits,
///   and Save checks the times the way the command will.
extension MediaSplitTests {

    private static func ffmpeg(_ args: [String]) -> Bool {
        guard let ff = FFmpeg.shared else { return false }
        return (try? ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + MediaTestSupport.h264(args)))?.status == 0
    }

    private static func g(_ v: Double) -> String { String(format: "%.3f", v) }
    private static func partFiles(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains(" part ") }.sorted()
    }
    private static func clean(_ dir: URL) {
        for name in partFiles(dir) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
    }

    static func fixes(_ t: MediaTestSupport.Checker, _ base: URL) {
        let dir = base.appendingPathComponent("fixes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        previewMatchesCut(t, dir)
        soundJoins(t, dir)
        containers(t, dir, fixtures: base)
        emptyAndNames(t, dir, fixtures: base)
        windowFixes(t, dir, fixtures: base)
    }

    // MARK: The frame on screen is the frame that starts the next part

    /// The mean grey (0…255) of the frame AVFoundation shows when the player seeks to `t` (MediaPlayback.seekTime,
    /// with the nudge the window sets for video).
    private static func playerGrey(_ url: URL, at t: Double) -> Double? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let image = try? generator.copyCGImage(at: MediaPlayback.seekTime(t, nudge: 0.001), actualTime: nil),
              let ctx = CGContext(data: nil, width: 16, height: 9, bitsPerComponent: 8, bytesPerRow: 16,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 9))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return Double((0..<144).reduce(0) { $0 + Int(data[$1]) }) / 144
    }

    /// Frame n of these clips is flat grey at video level 16 + 30 × (n mod 7): which of seven frames is on screen
    /// reads from its brightness through any decoder (full-range RGB from the player, raw Y from ffmpeg).
    private static let greyClip = "geq=lum='16+30*mod(N\\,7)':cb=128:cr=128"
    private static func phaseFromRGB(_ grey: Double) -> Int { Int((grey * 219 / 255 / 30).rounded()) % 7 }
    private static func phaseFromY(_ y: Double) -> Int { Int(((y - 16) / 30).rounded()) % 7 }
    private static func firstFramePhase(_ url: URL) -> Int? {
        guard let y = MediaMeasure.frameLuma(url, index: 0, width: 16, height: 9) else { return nil }
        return phaseFromY(Double(y.reduce(0) { $0 + Int($1) }) / Double(y.count))
    }

    private static func previewMatchesCut(_ t: MediaTestSupport.Checker, _ dir: URL) {
        // 23.976 fps: ffmpeg prints "23.98 fps"; on a grid of 1/23.98 the time of frame 300 is 2 ms early.
        let ntsc = dir.appendingPathComponent("ntsc.mp4")
        let mkv = dir.appendingPathComponent("ms.mkv")
        guard ffmpeg(["-f", "lavfi", "-i", "color=black:s=160x90:r=24000/1001:d=14," + greyClip, "-c:v", "libx264", "-crf", "10",
                      "-g", "24", "-pix_fmt", "yuv420p", ntsc.path]),
              ffmpeg(["-f", "lavfi", "-i", "color=black:s=160x90:r=30:d=4," + greyClip, "-c:v", "libx264", "-crf", "10", "-g", "30",
                      "-pix_fmt", "yuv420p", mkv.path]),
              let s = try? MediaSource.load(ntsc), let m = try? MediaSource.load(mkv) else {
            t.check(false, "make the 23.976 fps and millisecond-timed clips"); return
        }
        t.check(s.probe.fps.map { abs($0 - 23.98) < 0.001 } == true && s.frameDuration == 1001.0 / 24000,
                "“23.98 fps” is taken as 24000/1001: a frame lasts \(String(format: "%.7f", s.frameDuration)) s")
        // The player on the file itself (23.976), and on the preview proxy the window makes for an mkv.
        let proxy: URL? = try? MediaKit.makeProxy(m, in: dir.appendingPathComponent("proxy")) { _ in }
        for (source, shown, frames) in [(s, ntsc, [30, 300]), (m, proxy, [29, 74])] {
            guard let shown else { t.check(false, "\(source.name): a preview to look at"); continue }
            for n in frames {
                let at = source.videoStart + Double(n) * source.frameDuration
                let onScreen = playerGrey(shown, at: at).map(phaseFromRGB)
                do {
                    let parts = try MediaSplit.split(source.url, options: ["at": MediaTime.arg(at)]) { _ in }
                    defer { for p in parts { try? FileManager.default.removeItem(at: p) } }
                    let first = parts.count == 2 ? firstFramePhase(parts[1]) : nil
                    t.check(onScreen == n % 7 && first == n % 7,
                            "\(source.name) at frame \(n) (\(g(at)) s): the player shows frame \(n) (phase \(onScreen.map(String.init) ?? "?") of \(n % 7)) "
                            + "and part 2 starts with it (phase \(first.map(String.init) ?? "?"))")
                } catch { t.check(false, "\(source.name) split at frame \(n): \(error.localizedDescription)") }
            }
        }
    }

    // MARK: Sound alone: no silence at the joins

    /// The first sample over `level` (of full scale) from `from` on, in seconds.
    private static func click(_ x: [Int16], rate: Double, from: Int = 0, level: Double = 0.6) -> Double? {
        let limit = Int16(level * 32767)
        guard from < x.count, let i = x[from...].firstIndex(where: { $0 > limit }) else { return nil }
        return Double(i) / rate
    }

    private static func soundJoins(_ t: MediaTestSupport.Checker, _ dir: URL) {
        // An 8 s, 440 Hz tone with a 2 ms click 15 ms after each split (2.0, 4.37, 6.111 s) and one at 15 ms.
        let wav = dir.appendingPathComponent("clicks.wav")
        let clicks = [0.2, 2.015, 4.385, 6.126]
        let expr = "0.2*sin(2*PI*440*t)+if(" + clicks.map { "between(t,\($0),\($0 + 0.002))" }.joined(separator: "+") + ",0.75,0)"
        guard ffmpeg(["-f", "lavfi", "-i", "aevalsrc='\(expr)':s=44100:d=8", "-c:a", "pcm_s16le", wav.path]) else {
            t.check(false, "make the clicks clip"); return
        }
        let codecs: [(String, [String])] = [("mp3", ["-c:a", "libmp3lame", "-b:a", "192k"]), ("m4a", ["-c:a", "aac", "-b:a", "160k"]),
                                            ("wma", ["-c:a", "wmav2", "-b:a", "128k"])]
        for (ext, codec) in codecs {
            let url = dir.appendingPathComponent("clicks.\(ext)")
            guard ffmpeg(["-i", wav.path] + codec + [url.path]) else { t.check(false, "make clicks.\(ext)"); continue }
            // Where each click is in the source as the window shows it (the file's clock), and the splits 15 ms before.
            let source = MediaMeasure.pcm(url, channels: 1, fileClock: true)
            var marks: [Double] = []
            var from = 0
            while let c = click(source, rate: 44_100, from: from) { marks.append(c); from = Int((c + 0.1) * 44_100) }
            guard marks.count == 4 else { t.check(false, "clicks.\(ext): four clicks in the source (\(marks.map(g)))"); continue }
            let cuts = marks.dropFirst().map { $0 - 0.015 }
            // Part 1 starts with the source's first sample: its click is where the source decodes it (WMA's decoder
            // puts its first sample at 0.092 s on the file's clock, so the two clocks differ there).
            let firstClick = click(MediaMeasure.pcm(url, channels: 1), rate: 44_100) ?? -1
            do {
                let parts = try MediaSplit.split(url, options: ["at": cuts.map(MediaTime.arg).joined(separator: ",")]) { _ in }
                defer { for p in parts { try? FileManager.default.removeItem(at: p) } }
                let pcm = parts.map { MediaMeasure.pcm($0, channels: 1) }
                let offsets = pcm.map { click($0, rate: 44_100).map { $0 * 1000 } }
                let firstOK = offsets.first.flatMap { $0 }.map { abs($0 - firstClick * 1000) < 1 } ?? false
                let restOK = offsets.dropFirst().allSatisfy { $0.map { abs($0 - 15) < 1 } ?? false }
                t.check(parts.count == 4 && firstOK && restOK,
                        "\(ext): each part’s click is where it was after its split, nothing lost at a join "
                        + "(ms into parts: \(offsets.map { $0.map { String(format: "%.1f", $0) } ?? "none" }.joined(separator: ", ")))")
                if ext != "wma" {
                    let total = pcm.reduce(0) { $0 + $1.count }, whole = MediaMeasure.pcm(url, channels: 1).count
                    t.check(total == whole, "\(ext): the parts hold \(total) samples, the source \(whole): no padding at the joins")
                }
            } catch { t.check(false, "split clicks.\(ext): \(error.localizedDescription)") }
        }
    }

    // MARK: Containers and timing

    private static func containers(_ t: MediaTestSupport.Checker, _ dir: URL, fixtures: URL) {
        // FLV (H.264 + AAC, key frames 2 s apart): a seek to 0 landed seconds in and part 1 lost its picture.
        let flv = dir.appendingPathComponent("keys.flv")
        if ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=160x90:r=30:d=6", "-f", "lavfi", "-i", "sine=f=440:sample_rate=44100:d=6",
                   "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-g", "60", "-pix_fmt", "yuv420p", "-c:a", "aac", flv.path]) {
            do {
                let parts = try MediaSplit.split(flv, options: ["at": "1.0,2.5"]) { _ in }
                defer { for p in parts { try? FileManager.default.removeItem(at: p) } }
                let counts = parts.map { MediaMeasure.frameTimes($0).count }
                // The frames before each split, by the source's own times (x264's first frame sits a frame in).
                let times = MediaMeasure.frameTimes(flv), s = try MediaSource.load(flv)
                let before = [1.0, 2.5].map { cut in times.filter { $0 < s.snap(cut) - s.frameDuration / 2 }.count }
                let expected = [before[0], before[1] - before[0], times.count - before[1]]
                t.check(counts == expected && times.count == 180,
                        "keys.flv at=1.0,2.5: \(counts) frames (\(expected) of \(times.count)): part 1 keeps its picture")
            } catch { t.check(false, "split keys.flv: \(error.localizedDescription)") }
        } else { t.check(false, "make keys.flv") }

        // A recording that holds one picture for half a second (frames 40–54 dropped): the part that starts inside
        // the gap starts its picture where the next frame comes, under its sound, not at 0.
        let gap = dir.appendingPathComponent("gap.mp4")
        if ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=160x90:r=30:d=6", "-f", "lavfi", "-i", "sine=f=440:sample_rate=48000:d=6",
                   "-map", "0:v", "-map", "1:a", "-vf", "select='not(between(n\\,40\\,54))'", "-fps_mode", "vfr",
                   "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", gap.path]), let s = try? MediaSource.load(gap) {
            do {
                let parts = try MediaSplit.split(gap, options: ["at": "1.5"]) { _ in }
                defer { for p in parts { try? FileManager.default.removeItem(at: p) } }
                let cut = s.snap(1.5), expected = 55.0 / 30 - cut
                let times = parts.count == 2 ? MediaMeasure.frameTimes(parts[1]) : []
                let second = times.count > 1 ? times[1] : nil
                t.check(second.map { abs($0 - expected) < 0.02 } == true,
                        "gap.mp4 split at \(g(cut)) s (inside a 0.5 s still): part 2’s next frame shows at \(second.map(g) ?? "?") s, "
                        + "\(g(expected)) s after the split as in the source (it was at 0, 0.34 s ahead of its sound)")
                // The still on screen at the split (frame 39, shown from 1.3 s) starts part 2 at 0: before, part 2 had
                // no picture until the next frame (for a still screen held to the end, none at all).
                let still = parts.count == 2 ? MediaMeasure.frameRGB(parts[1], index: 0) : nil
                let scores = [38, 39, 40].map { i in still.flatMap { a in MediaMeasure.frameRGB(gap, index: i).map { MediaMeasure.psnr(a, $0) } } ?? 0 }
                t.check(times.first.map { abs($0) < 0.001 } == true && scores[1] >= 35 && scores[1] > scores[0] + 3 && scores[1] > scores[2] + 3,
                        "… and part 2 starts at \(times.first.map(g) ?? "?") s with the still on screen at the split "
                        + "(PSNR against source frames 38/39/55: \(scores.map { String(format: "%.1f", $0) }.joined(separator: "/")) dB)")
            } catch { t.check(false, "split gap.mp4: \(error.localizedDescription)") }
        } else { t.check(false, "make gap.mp4") }

        // The same recording as an MKV that reports its nominal 30 fps (as browser and screen-recorder WebM/MKV files
        // do) while 15 frames are missing: frame count × 1/30 put the "last frame" at 5.467 s, half a second early,
        // so a split in the last half second was refused and the window couldn't place one there.
        let gapMKV = dir.appendingPathComponent("gap30.mkv")
        if ffmpeg(["-i", gap.path, "-c", "copy", "-r", "30", gapMKV.path]), let s = try? MediaSource.load(gapMKV) {
            let last = MediaSplit.lastFrameStart(s)
            t.check(last.map { abs($0 - 179.0 / 30) < 0.002 } == true,
                    "gap30.mkv (30 fps nominal, 165 frames): the last frame starts at \(last.map(g) ?? "?") s, the real one (5.967 s)")
            t.check((MediaSplit.cutBounds(s, lastFrame: last)?.upperBound ?? 0) > 5.9,
                    "… and the window may split up to \(g(MediaSplit.cutBounds(s, lastFrame: last)?.upperBound ?? 0)) s")
            do {
                let parts = try MediaSplit.split(gapMKV, options: ["at": "5.8"]) { _ in }
                defer { for p in parts { try? FileManager.default.removeItem(at: p) } }
                let frames = parts.map { MediaMeasure.frameTimes($0).count }
                t.check(frames == [159, 6], "gap30.mkv at=5.8 is accepted: \(frames) frames (159 + 6, all 165)")
            } catch { t.check(false, "split gap30.mkv at=5.8: \(error.localizedDescription)") }
            try? FileManager.default.removeItem(at: gapMKV)
        } else { t.check(false, "make gap30.mkv") }

        // WebM (VP9 + Opus, a key frame each second): parts that start on a key frame are copied; their sound was
        // 20 ms short (the first Opus packet).
        let webm = dir.appendingPathComponent("keys.webm")
        if ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=160x90:r=30:d=6", "-f", "lavfi", "-i", "sine=f=440:sample_rate=48000:d=6",
                   "-map", "0:v", "-map", "1:a", "-c:v", "libvpx-vp9", "-g", "30", "-deadline", "realtime", "-b:v", "200k",
                   "-c:a", "libopus", webm.path]) {
            do {
                let parts = try MediaSplit.split(webm, options: ["at": "1.0,2.5"]) { _ in }
                defer { for p in parts { try? FileManager.default.removeItem(at: p) } }
                let pcm = parts.map { MediaMeasure.pcm($0, rate: 48_000, channels: 1) }
                let samples = pcm.map(\.count)
                // The tone runs from each part's first millisecond (a lost packet was padded with silence).
                let starts = pcm.map { x -> Double in
                    guard x.count > 24_000 else { return 0 }
                    return rms(x[0..<48]) / max(1, rms(x[12_000..<12_480]))
                }
                t.check(samples.count == 3 && samples[0] == 48_000 && samples[1] == 72_000 && abs(samples[2] - 168_000) <= 960
                        && starts.allSatisfy { $0 > 0.5 },
                        "keys.webm at=1.0,2.5: the parts’ sound is \(samples) samples (48000, 72000, about 168000), the tone there from "
                        + "each part’s first millisecond (level \(starts.map { String(format: "%.2f", $0) }.joined(separator: ", ")) of the middle’s)")
            } catch { t.check(false, "split keys.webm: \(error.localizedDescription)") }
        } else { t.check(false, "make keys.webm") }

        // 22.05 and 11.025 kHz: times on the window's 0.01 s grid fall between samples; the command accepts them.
        for rate in [22_050, 11_025] {
            let wav = dir.appendingPathComponent("s\(rate).wav")
            guard ffmpeg(["-f", "lavfi", "-i", "sine=f=440:sample_rate=\(rate):d=3", wav.path]), let s = try? MediaSource.load(wav) else {
                t.check(false, "make s\(rate).wav"); continue
            }
            for at in ["1.23,1.24", "2.99", "0.01"] {
                t.check((try? MediaSplit.parts(s, options: ["at": at]))?.count == at.split(separator: ",").count + 1,
                        "\(rate) Hz: at=\(at) (0.01 s apart or from an end, as the window allows) is accepted")
            }
        }
    }

    // MARK: Empty parts, all or none, names, messages

    private static func emptyAndNames(_ t: MediaTestSupport.Checker, _ dir: URL, fixtures: URL) {
        let fm = FileManager.default
        // sample.wmv: its sound runs 44 ms past its last frame (4.013 s); the grid's last frame start, 4.046 s, has none.
        let wmv = dir.appendingPathComponent("sample.wmv")
        try? fm.copyItem(at: fixtures.appendingPathComponent("sample.wmv"), to: wmv)
        if let s = try? MediaSource.load(wmv) {
            let last = MediaSplit.lastFrameStart(s)
            t.check(last.map { abs($0 - (s.videoStart + 119.0 / 30)) < 0.002 } == true, "sample.wmv’s last frame starts at \(last.map(g) ?? "?") s (frame 120 of 120)")
            t.throwsError("sample.wmv at=4.046 (past the last frame)", containing: "comes after the last frame of sample.wmv (0:04.01)") {
                _ = try MediaSplit.split(wmv, options: ["at": "4.046"]) { _ in }
            }
            t.check(partFiles(dir).isEmpty, "… and writes nothing")
        }
        // A download cut off at 40 % (its header still says 12 s): the parts after the data would be empty.
        let full = dir.appendingPathComponent("full.mp4"), cut = dir.appendingPathComponent("cut.mp4")
        if ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=160x90:r=30:d=12", "-f", "lavfi", "-i", "sine=f=440:d=12", "-map", "0:v", "-map", "1:a",
                   "-c:v", "libx264", "-g", "30", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart", full.path]),
           let data = try? Data(contentsOf: full) {
            try? data.prefix(data.count * 4 / 10).write(to: cut)
            t.throwsError("a truncated mp4 in 3 parts", containing: "came out empty") {
                _ = try MediaSplit.split(cut, options: ["mode": "parts", "parts": "3"]) { _ in }
            }
            t.check(partFiles(dir).isEmpty, "… and no part is left behind (all or none)")
            try? fm.removeItem(at: full); try? fm.removeItem(at: cut)
        }
        // The parts appear only when all are written; an older part 2 makes the new set "clip 2 part …".
        let clip = dir.appendingPathComponent("clip.mp4")
        try? fm.copyItem(at: fixtures.appendingPathComponent("clip.mp4"), to: clip)
        var seenEarly = false
        do {
            let parts = try MediaSplit.split(clip, options: ["at": "1.2,2.6"]) { p in
                if p < 0.99, !partFiles(dir).isEmpty { seenEarly = true }
            }
            t.check(!seenEarly && parts.count == 3, "no part shows in the folder until all three are written")
            clean(dir)
        } catch { t.check(false, "split clip.mp4: \(error.localizedDescription)") }
        let old = dir.appendingPathComponent("clip part 2.mp4")
        fm.createFile(atPath: old.path, contents: Data("old".utf8))
        if let parts = try? MediaSplit.split(clip, options: ["at": "1.2,2.6"], progress: { _ in }) {
            t.check(parts.map(\.lastPathComponent) == ["clip 2 part 1.mp4", "clip 2 part 2.mp4", "clip 2 part 3.mp4"]
                    && (try? Data(contentsOf: old)) == Data("old".utf8),
                    "with an older “clip part 2.mp4” there, the new set is \(parts.map(\.lastPathComponent)) and the old file is untouched")
        } else { t.check(false, "split next to an older part") }
        clean(dir)
        // A folder it can't write to: a sentence, nothing written.
        let locked = dir.appendingPathComponent("locked")
        try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try? fm.copyItem(at: clip, to: locked.appendingPathComponent("clip.mp4"))
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        t.throwsError("a folder it can’t write to", containing: "YummyOrange can’t write to the folder “locked”") {
            _ = try MediaSplit.split(locked.appendingPathComponent("clip.mp4"), options: ["at": "1.2"]) { _ in }
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        t.check(partFiles(locked).isEmpty, "… and nothing is written there")
        // A full disk: ffmpeg names it only on follow-up lines ("Last message repeated" came out as the error).
        let fullDisk = "[vost#0:0/h264_videotoolbox @ 0x75be910000] Error submitting a packet to the muxer: File too large\n"
            + "    Last message repeated 1 times\n[out#0/mp4 @ 0x75bf000840] Error muxing a packet\n"
            + "[out#0/mp4 @ 0x75bf000840] Task finished with error code: -27 (File too large)\n"
        let cause = FFmpeg.failureMessage(fullDisk) ?? ""
        let said = MediaSplit.friendly(ConversionError.toolFailed(cause), folder: dir).localizedDescription
        t.check(cause.contains("File too large") && said.hasPrefix("There isn’t enough space on the disk for the parts, so none were saved."),
                "a full disk reads “\(said)” (ffmpeg’s cause: “\(cause)”)")
        // Messages and empty times.
        t.throwsError("at= (empty)", containing: "Give the times to split at") { _ = try MediaSplit.split(clip, options: ["at": ""]) { _ in } }
        t.throwsError("at=, (no times)", containing: "Give the times to split at") { _ = try MediaSplit.split(clip, options: ["at": ","]) { _ in } }
        t.throwsError("at=0.01 quotes the time typed", containing: "The split at 0.01 (the frame at 0:00.00) leaves a part shorter than one frame") {
            _ = try MediaSplit.split(clip, options: ["at": "0.01"]) { _ in }
        }
        t.check(partFiles(dir).isEmpty, "the refused splits wrote nothing")
    }

    // MARK: The window

    /// The timeline drawn into a bitmap, and a function that reads a point's colour (sRGB, 0…255).
    private static func render(_ view: NSView) -> (CGPoint) -> (r: Int, g: Int, b: Int) {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return { p in
            let c = rep.colorAt(x: Int(p.x * scale), y: Int(p.y * scale))?.usingColorSpace(.sRGB)
            return (Int(((c?.redComponent ?? 0) * 255).rounded()), Int(((c?.greenComponent ?? 0) * 255).rounded()),
                    Int(((c?.blueComponent ?? 0) * 255).rounded()))
        }
    }

    private static func same(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int), _ tolerance: Int = 4) -> Bool {
        abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
    }

    private static func windowFixes(_ t: MediaTestSupport.Checker, _ dir: URL, fixtures: URL) {
        let clip = dir.appendingPathComponent("clip.mp4")
        if !FileManager.default.fileExists(atPath: clip.path) { try? FileManager.default.copyItem(at: fixtures.appendingPathComponent("clip.mp4"), to: clip) }
        do {
            let e = try S.editor(SplitEditorController.self, url: clip, loadLanes: true)
            defer { e.forceClose() }
            var beeps = 0
            e.beep = { beeps += 1 }
            let w = e.window, tl = e.timeline!
            func press(_ c: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> Bool { e.handleKey(S.key(c, keyCode: code, flags: flags, window: w)) }
            let ruler: CGFloat = 14, strip: CGFloat = 50
            // ⌘B at 2.6: the new split sits under the playhead. Dragging the playhead's head in the ruler scrubs.
            e.scrub(to: 1.2); _ = press("b", 11, .command)
            e.scrub(to: 2.6); _ = press("b", 11, .command)
            S.drag(tl, from: CGPoint(x: tl.x(2.6), y: ruler), to: CGPoint(x: tl.x(2.6) + 50, y: ruler))
            t.check(e.cuts.count == 2 && near(e.cuts[1], 2.6) && e.playhead > 2.7 && e.undo.undoActionName == "Split",
                    "dragging the playhead’s head off a split it sits on scrubs (playhead \(g(e.playhead)) s) and leaves the split at 2.60 s")
            e.scrub(to: 2.6); _ = press("b", 11, .command)
            t.check(e.notice == "There’s already a split at 0:02.60.", "… so ⌘B there still finds the split")
            // By its tab: drag it to 3.0.
            let tab = tl.cutTabRect(2.6)
            S.drag(tl, from: CGPoint(x: tab.midX, y: tab.midY), to: CGPoint(x: tl.x(3.0), y: tab.midY))
            t.check(near(e.cuts[1], 3.0) && e.selectedCut == 1 && e.undo.undoActionName == "Move Split", "dragging Split 2 by its tab moves it to 3.00 s")
            e.performUndo()
            // What the timeline shows with the playhead on the selected split: the parts come apart around the halo.
            // In the light appearance (the darker outline matters there), then the dark one.
            e.selectCut(1); e.scrub(to: 2.6)
            w.appearance = NSAppearance(named: .aqua)
            var pixel = render(tl)
            let background = pixel(CGPoint(x: 6, y: strip))
            let px = tl.x(2.6).rounded()
            t.check(same(pixel(CGPoint(x: px - 4, y: strip)), background) && same(pixel(CGPoint(x: px + 4, y: strip)), background),
                    "a split under the playhead stays visible: the film strip breaks 4 pt either side of it, beyond the playhead’s halo")
            let accent = pixel(CGPoint(x: tl.cutTabRect(2.6).midX - 4, y: tl.cutTabRect(2.6).midY))
            let ux = tl.x(1.2).rounded()
            t.check(same(pixel(CGPoint(x: ux, y: strip)), background) && same(pixel(CGPoint(x: ux - 3, y: strip)), background)
                    && !same(accent, background, 40),
                    "an unselected split is a break in the background colour, not an accent line (the accent is for the playhead and the selection)")
            // The tab of the selected split: filled, with an outline at 3:1 or more against the background (light).
            let outline = pixel(CGPoint(x: tl.cutTabRect(2.6).minX + 0.5, y: tl.cutTabRect(2.6).midY))
            let ratio = contrast(outline, background)
            w.appearance = NSAppearance(named: .darkAqua)
            pixel = render(tl)
            let darkRatio = contrast(pixel(CGPoint(x: tl.cutTabRect(2.6).minX + 0.5, y: tl.cutTabRect(2.6).midY)), pixel(CGPoint(x: 6, y: strip)))
            w.appearance = nil
            t.check(ratio >= 3 && darkRatio >= 3, "the selected split’s tab outline is \(String(format: "%.2f", ratio)):1 (light) and "
                    + "\(String(format: "%.2f", darkRatio)):1 (dark) against the timeline (3:1 or more)")

            // ↑ ↓ select the split they land on; Return edits its time.
            e.selectCut(nil); e.scrub(to: 0)
            _ = press("\u{F701}", 125)
            t.check(near(e.playhead, 1.2) && e.selectedCut == 0, "↓ goes to Split 1 and selects it")
            _ = press("\u{F701}", 125); _ = press("\u{F701}", 125)
            t.check(e.selectedCut == nil && near(e.playhead, 4 - 1.0 / 30), "↓ past the last split goes to the last frame, with no split selected")
            _ = press("\u{F700}", 126)
            t.check(e.selectedCut == 1, "↑ selects Split 2")
            t.check(press("\r", 36) && w.firstResponder === e.cutField.currentEditor() && e.cutField.currentEditor()?.selectedRange.length == 7,
                    "Return edits the selected split’s time, its text selected")
            // A refused typed time says why, and Save (which commits the field first) doesn't save.
            var saved: ToolOptions?
            e.runSave = { _, options, _ in saved = options }
            e.cutField.currentEditor()?.string = "abc"
            let beepsBefore = beeps
            e.save()
            t.check(saved == nil && beeps == beepsBefore + 1 && e.notice == "“abc” isn’t a time. Type one like 0:01.50, or seconds."
                    && e.cutField.stringValue == "0:02.60" && tl.onScrub != nil,
                    "Save with “abc” typed: the field is put back, it says “\(e.notice ?? "")”, and nothing is saved")
            e.selectCut(0)
            e.cutField.stringValue = "3.0"
            e.cutField.sendAction(e.cutField.action, to: e.cutField.target)
            t.check(near(e.cuts[0], 1.2) && e.notice == "Split 1 has to stay between 0:00.03 and 0:02.57.", "a time past the next split says “\(e.notice ?? "")”")
            // Save commits a time still being typed (the toolbar's Save doesn't take the focus from the field).
            e.selectCut(1)
            _ = press("\r", 36)
            e.cutField.currentEditor()?.string = "3.5"
            e.save()
            t.check(saved == ["at": "1.200000,3.500000"], "Save with 3.5 typed but not confirmed saves it: \(saved ?? [:])")
        } catch { t.check(false, "Split window fixes: \(error.localizedDescription)") }

        // Dense splits: compact marks, the ruler still scrubs, part numbers in a regular step.
        do {
            let e = try S.editor(SplitEditorController.self, url: clip, loadLanes: true)
            defer { e.forceClose() }
            let tl = e.timeline!
            let thirty = (1...30).map { e.source.snap(Double($0) * 0.13) }
            e.commitCuts(thirty, selected: 9, action: "Set")
            let compact = thirty.indices.filter { tl.isCompactCut($0) }.count
            let numbers = tl.partNumberBadges().map { $0.part + 1 }
            let step = numbers.count > 1 ? numbers[1] : 0
            let regular = numbers == Array(1...31) || (step > 1 && numbers == [1] + Array(stride(from: step, through: 31, by: step)))
            t.check(compact == 30 && regular && !numbers.isEmpty,
                    "30 splits about 0.13 s (24–32 pt) apart: drawn compact (\(compact) of 30), numbers \(numbers.map(String.init).joined(separator: " ")) (a regular step)")
            S.drag(tl, from: CGPoint(x: tl.x(1.0), y: 14), to: CGPoint(x: tl.x(2.0), y: 14))
            t.check(near(e.playhead, 2.0) && e.cuts == thirty, "with 30 splits the ruler still scrubs (playhead \(g(e.playhead)) s), the splits stay put")
            e.commitCuts([1.2, 2.6], selected: nil, action: "Set")
            t.check(tl.partNumberBadges().map(\.part) == [0, 1, 2] && !tl.isCompactCut(0), "with two splits every part is numbered and the splits are full breaks")
            // One part two frames long among wide ones: the numbers go 1, 5, 10 rather than skip 6 alone.
            let uneven = [0.3, 0.6, 0.9, 1.2, 1.5, 1.5 + 2.0 / 30, 1.9, 2.2, 2.5, 2.8, 3.1, 3.4].map { e.source.snap($0) }
            e.commitCuts(uneven, selected: nil, action: "Set")
            let shown = tl.partNumberBadges().map { $0.part + 1 }
            t.check(shown == [1, 5, 10], "a two-frame part 6 among wide parts: numbers \(shown.map(String.init).joined(separator: " ")) (every 5th, not 1–5 and 7–13)")
        } catch { t.check(false, "dense splits: \(error.localizedDescription)") }

        // The real last frame bounds the splits (sample.wmv), and Save checks the times as the command will.
        let wmv = dir.appendingPathComponent("sample.wmv")
        if !FileManager.default.fileExists(atPath: wmv.path) { try? FileManager.default.copyItem(at: fixtures.appendingPathComponent("sample.wmv"), to: wmv) }
        do {
            let e = try S.editor(SplitEditorController.self, url: wmv)
            defer { e.forceClose() }
            var beeps = 0
            e.beep = { beeps += 1 }
            let end = e.source.snap(e.source.duration - e.source.frameDuration)
            e.commitCuts([end], selected: nil, action: "Set")
            t.throwsError("Save with a split at \(g(end)) s, after the last frame, before the window knows it", containing: "The split at 0:04.05 comes after the last frame") {
                _ = try e.makeOptions()
            }
            e.commitCuts([], selected: nil, action: "Set")
            e.useLastFrame(MediaSplit.lastFrameStart(e.source))
            e.scrub(to: end)
            _ = e.handleKey(S.key("b", keyCode: 11, flags: .command, window: e.window))
            t.check(e.cuts.isEmpty && beeps == 1 && e.notice == "That’s after the last frame (0:04.01).", "⌘B at \(g(end)) s (End) on sample.wmv: “\(e.notice ?? "")”")
            e.scrub(to: 1.0)
            _ = e.handleKey(S.key("\u{F701}", keyCode: 125, window: e.window))
            t.check(abs(e.playhead - (e.lastFrame ?? 0)) < 1e-6 && abs(e.playhead - 4.013) < 0.002, "↓ stops on the last real frame (\(g(e.playhead)) s)")
        } catch { t.check(false, "sample.wmv window: \(error.localizedDescription)") }

        // 22.05 kHz in the window: splits 0.01 s apart, and Save's check agrees.
        let s22 = dir.appendingPathComponent("w22.wav")
        if ffmpeg(["-f", "lavfi", "-i", "sine=f=440:sample_rate=22050:d=3", s22.path]) {
            do {
                let e = try S.editor(SplitEditorController.self, url: s22, size: CGSize(width: 900, height: 380))
                defer { e.forceClose() }
                e.beep = {}
                e.scrub(to: 1.23); _ = e.handleKey(S.key("b", keyCode: 11, flags: .command, window: e.window))
                e.scrub(to: 1.24); _ = e.handleKey(S.key("b", keyCode: 11, flags: .command, window: e.window))
                e.scrub(to: 2.99); _ = e.handleKey(S.key("b", keyCode: 11, flags: .command, window: e.window))
                let options = try? e.makeOptions()
                t.check(e.cuts.count == 3 && options != nil && (try? MediaSplit.parts(e.source, options: options ?? [:]))?.count == 4,
                        "22.05 kHz: splits at 1.23, 1.24 and 2.99 s are placed and Save’s times are accepted by the command")
            } catch { t.check(false, "22.05 kHz window: \(error.localizedDescription)") }
        }
    }

    private static func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) < tolerance }

    private static func rms(_ x: ArraySlice<Int16>) -> Double {
        sqrt(x.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count)))
    }

    /// WCAG contrast ratio of two sRGB colours.
    private static func contrast(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int)) -> Double {
        func lum(_ c: (r: Int, g: Int, b: Int)) -> Double {
            func ch(_ v: Int) -> Double { let s = Double(v) / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
            return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
#endif
