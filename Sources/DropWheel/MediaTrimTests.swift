#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import AVFoundation

/// `--selftest media-trim`: Trim on every media fixture, measured with ffmpeg, plus the editor kit's parsing, the
/// preview's pixel mapping, and the Trim window's keys, drags, Undo and accessibility (in a window never shown).
///
/// For each trim: the output is named "<name> trimmed.<ext>" in the input's format; it has exactly the frames that
/// start inside the cut (both ends on frame boundaries), so its length is within a frame of what was asked; its first
/// frame is the expected source frame (PSNR against that frame, and better than against its neighbours); sound is
/// there when the source had it, with the right length (WAV: the exact sample count and the same samples); copies
/// happen only on key frames; the input is unchanged; bad ranges throw clear errors and write nothing.
enum MediaTrimTests {
    static func run() -> String {
        let t = MediaTestSupport.Checker("media-trim")
        guard FFmpeg.shared != nil else { return "OK media-trim: skipped, ffmpeg isn’t installed" }
        guard let fixtures = MediaTestSupport.fixturesFolder() else {
            return "FAIL media-trim: can’t find Tests/fixtures/features. Run from the project folder or set DW_FIXTURES."
        }
        let names = ["clip.mp4", "odd.mkv", "sample.avi", "sample.wmv", "tone.wav", "sample.wma"]
        let dir: URL
        do { dir = try MediaTestSupport.scratchCopy(of: names, from: fixtures) } catch {
            return "FAIL media-trim: couldn’t copy the fixtures: \(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = Dictionary(uniqueKeysWithValues: names.map { ($0, MediaMeasure.sha256(dir.appendingPathComponent($0))) })
        func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

        parsing(t, fixtures: fixtures)
        mapping(t, url("odd.mkv"))
        // Video: re-encoded and copied cuts, on and off frame boundaries.
        video(t, url("clip.mp4"), 1.5, 3.0, .reencode)
        video(t, url("clip.mp4"), 0, 4.0, .copy)
        video(t, url("clip.mp4"), 0, 2.0, .reencode)          // a copy would run past the end (B-frames), so it re-encodes
        video(t, url("clip.mp4"), 1.51, 2.49, .reencode)      // off the frame grid: rounded to frames 45…74
        video(t, url("odd.mkv"), 0.52, 2.0, .reencode)
        video(t, url("odd.mkv"), 0, 3.0, .copy)
        video(t, url("sample.avi"), 0.833333, 2.333333, .copy) // starts on a key frame
        video(t, url("sample.avi"), 1.0, 2.5, .reencode)
        video(t, url("sample.wmv"), 1.046, 2.546, .reencode)
        video(t, url("sample.wmv"), 0.5, 1.0, .reencode)
        // Sound.
        wav(t, url("tone.wav"), 1.2345, 3.5)
        deepWav(t, dir)
        wma(t, url("sample.wma"), 1.0, 3.0)
        lateSound(t, dir)
        craftedFiles(t, dir)
        unindexed(t, dir)
        badRanges(t, dir)
        editor(t, url("clip.mp4"), url("tone.wav"))
        multipleRanges(t, url("clip.mp4"))
        livePreview(t, url("clip.mp4"), url("odd.mkv"), url("sample.wma"))
        snapshot(t, url("clip.mp4"))

        for name in names {
            t.check(MediaMeasure.sha256(url(name)) == before[name], "\(name) unchanged")
            t.check(MediaMeasure.sha256(fixtures.appendingPathComponent(name)) == before[name], "fixture \(name) unchanged")
        }
        return t.report
    }

    private static func f(_ v: Double) -> String { String(format: "%.3f", v) }

    // MARK: Damaged and crafted files

    /// What a file says about itself can't move the probe, crash the waveform or stall the timeline: tags that look
    /// like ffmpeg's report, a length of 31 700 years, and sound that stops before the picture.
    private static func craftedFiles(_ t: MediaTestSupport.Checker, _ dir: URL) {
        guard let ff = FFmpeg.shared else { return }
        func make(_ name: String, _ args: [String]) -> URL? {
            let url = dir.appendingPathComponent(name)
            let ok = (try? ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + MediaTestSupport.h264(args) + [url.path]))?.status == 0
            return ok ? url : nil
        }
        // Tags (and a file name) that read like the report's own lines.
        let report = """
            Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'Duration: 09:00:00.00, start: 0.000000, Stream #0:5: Video: h264, 7680x4320.m4a':
              Metadata:
                title           : Duration: 10:00:00.00, start: 0.000000, bitrate: 1 kb/s
                comment         : first line
                                : Stream #0:9: Video: h264, yuv420p, 7680x4320, 240 fps, 240 tbr
              Duration: 00:00:03.00, start: 0.000000, bitrate: 74 kb/s
              Stream #0:0[0x1](und): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, mono, fltp, 69 kb/s (default)
                Metadata:
                  handler_name    : rotation of 90.00 degrees
            """
        let parsed = MediaSource.parse(report, url: URL(fileURLWithPath: "/x/evil.m4a"))
        t.check(parsed.duration == 3 && !parsed.hasVideo && parsed.hasAudio && parsed.rotation == 0 && parsed.sampleRate == 44_100,
                "tags and a file name that look like report lines are ignored: \(f(parsed.duration)) s, video \(parsed.hasVideo), rotation \(parsed.rotation)")
        if let evil = make("evil.m4a", ["-f", "lavfi", "-i", "sine=f=440:d=3", "-metadata", "title=Duration: 10:00:00.00, start: 0.000000",
                                        "-metadata", "comment=Stream #0:9: Video: h264, yuv420p, 7680x4320, 240 fps", "-c:a", "aac"]),
           let s = try? MediaSource.load(evil) {
            t.check(abs(s.duration - 3) < 0.05 && !s.hasVideo, "a sound file tagged “Duration: 10:00:00.00” and “Stream … Video:”: \(f(s.duration)) s, no picture")
        } else { t.check(false, "make and load evil.m4a") }

        // A Matroska file whose header claims 10^12 seconds (3 s of sound).
        if let base = make("huge-base.mka", ["-f", "lavfi", "-i", "sine=f=440:d=3", "-c:a", "flac"]), var data = try? Data(contentsOf: base),
           let at = data.firstRange(of: Data([0x44, 0x89, 0x88])) {
            var big = (1e15).bitPattern.bigEndian
            data.replaceSubrange(at.upperBound..<(at.upperBound + 8), with: Data(bytes: &big, count: 8))
            let huge = dir.appendingPathComponent("huge.mka")
            if (try? data.write(to: huge)) != nil, let s = try? MediaSource.load(huge) {
                let peaks = MediaKit.peaks(s)
                t.check(s.duration > 1e11 && peaks.map { $0.values.count < 1_000 && $0.peak(from: 10, to: 11) == 0 } == true,
                        "a file that claims \(MediaTime.string(s.duration)): the waveform reads the 3 s there are (\(peaks?.values.count ?? -1) peaks), no crash")
                // Split counts the parts before listing the cuts. (Checked on a claimed 277 hours, so that a Split that
                // lists them first costs 80 MB here, not the terabytes 10^12 s would.)
                let long = MediaSource.parse("Input #0, matroska,webm, from 'x.mka':\n  Duration: 277:46:40.00, start: 0.000000, bitrate: N/A\n"
                                             + "  Stream #0:0: Audio: flac, 44100 Hz, mono, s16", url: huge)
                t.throwsError("split every 0.1 s of a file that claims \(MediaTime.string(long.duration))", containing: "more than 100 parts") {
                    _ = try MediaSplit.parts(long, options: ["mode": "every", "seconds": "0.1"])
                }
                if let e = try? MediaTestSupport.editor(TrimEditorController.self, url: huge) {
                    let step = e.timeline.tickSteps()
                    let ticks = s.duration / step.minor
                    t.check(ticks.isFinite && ticks < 1_000, "its ruler draws \(min(ticks, 1e12).rounded()) ticks, not hundreds of millions")
                    e.forceClose()
                } else { t.check(false, "a Trim window for huge.mka") }
            } else { t.check(false, "write and load huge.mka") }
            try? FileManager.default.removeItem(at: base)
        } else { t.check(false, "make huge-base.mka") }

        // A file name with line breaks that read like report lines (the name is printed inside the report).
        let lines = "song\n  Duration: 10:00:00.00, start: 0.000000, bitrate: 1 kbps\n  Stream #0:5: Video: h264, yuv420p, 1920x1080, 30 fps\n.m4a"
        if let base = make("named.m4a", ["-f", "lavfi", "-i", "sine=f=440:d=3", "-c:a", "aac"]) {
            let named = dir.appendingPathComponent(lines)
            if (try? FileManager.default.moveItem(at: base, to: named)) != nil, let s = try? MediaSource.load(named) {
                t.check(abs(s.duration - 3) < 0.05 && !s.hasVideo, "a file named “song⏎  Duration: 10:00:00.00…⏎  Stream #0:5: Video…”: "
                        + "\(f(s.duration)) s, \(s.hasVideo ? "a picture" : "no picture")")
            } else { t.check(false, "name and load the file with line breaks in its name") }
            try? FileManager.default.removeItem(at: named)
        } else { t.check(false, "make named.m4a") }

        // Sound the file says starts 100 000 s (27:46:40) after its 3 s picture, and sound whose times jump by 3000 s
        // halfway: padding that much in front (or in the gap) took ffmpeg one 2 GB block and the waveform a minute.
        // The first is drawn where it plays without asking ffmpeg for the silence; the second isn't filled.
        if let far = make("far.mkv", ["-f", "lavfi", "-i", "testsrc2=s=320x240:r=30:d=3", "-itsoffset", "100000", "-f", "lavfi", "-i",
                                      "sine=f=440:d=3:sample_rate=48000", "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-c:a", "flac"]),
           let s = try? MediaSource.load(far) {
            let peaks = MediaKit.peaks(s)
            let loudest = peaks.map { p in p.values.indices.max { p.values[$0] < p.values[$1] }.map { Double($0) / p.rate } ?? 0 } ?? 0
            t.check(abs(s.audioStart - 100_000) < 0.01 && MediaKit.soundFromZero(s).isEmpty && !MediaKit.soundFromZero(s, seek: 99_999.5).isEmpty
                    && abs(loudest - 100_000) < 1,
                    "sound that claims to start at \(MediaTime.string(s.audioStart)): no 100 000 s of padding asked of ffmpeg "
                        + "(a cut from 99 999.5 s still pads), the waveform draws it at \(f(loudest)) s")
            try? FileManager.default.removeItem(at: far)
        } else { t.check(false, "make far.mkv") }
        if let jump = make("jump.mkv", ["-f", "lavfi", "-i", "testsrc2=s=320x240:r=30:d=3", "-f", "lavfi", "-i",
                                        "sine=f=440:d=3:sample_rate=48000,asetpts='if(gte(T,1.5),PTS+3000/TB,PTS)'",
                                        "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-c:a", "flac"]),
           let s = try? MediaSource.load(jump), let peaks = MediaKit.peaks(s) {
            t.check(peaks.duration < 10, "sound whose times jump by 3000 s: the waveform reads the \(f(peaks.duration)) s there are, the gap isn't filled")
            try? FileManager.default.removeItem(at: jump)
        } else { t.check(false, "make jump.mkv") }

        // Sound that stops at 2 s under a 4 s picture: nothing is drawn after it.
        if let url = make("short-sound.mp4", ["-f", "lavfi", "-i", "testsrc2=s=320x240:r=30:d=4", "-f", "lavfi", "-i", "sine=f=440:d=2:sample_rate=48000",
                                               "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-c:a", "aac"]),
           let s = try? MediaSource.load(url), let peaks = MediaKit.peaks(s) {
            let during = peaks.peak(from: 1.0, to: 1.5), after = peaks.peak(from: 3.0, to: 3.5)
            t.check(during > 0.05 && after == 0, "sound that stops at 2 s: the waveform shows \(String(format: "%.2f", during)) at 1 s and \(String(format: "%.2f", after)) at 3 s")
        } else { t.check(false, "make short-sound.mp4") }
    }

    // MARK: Containers without an index

    /// MPEG transport and program streams (.m2ts, .vob) with a key frame every 2 s and a flash and a burst together at
    /// 3.5 s: a cut at 3.0–4.5 s, between key frames, keeps every frame of it (ffmpeg's seek in these lands near the
    /// time asked for, and the decoder dropped the frames up to the next key frame at 4 s: 12 of 38 were left, ahead of
    /// the sound) and keeps the flash with the burst; Split's second part, from 3 s, keeps its frames too.
    private static func unindexed(_ t: MediaTestSupport.Checker, _ dir: URL) {
        guard let ff = FFmpeg.shared else { return }
        for (name, codecs) in [("gop.m2ts", ["-c:v", "libx264", "-g", "50", "-bf", "2", "-c:a", "aac", "-f", "mpegts"]),
                               ("gop.vob", ["-c:v", "mpeg2video", "-g", "50", "-c:a", "mp2", "-f", "vob"])] {
            let url = dir.appendingPathComponent(name)
            let args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                        "-f", "lavfi", "-i", "color=black:s=320x240:r=25:d=6,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='between(t,3.49,3.59)'",
                        "-f", "lavfi", "-i", "aevalsrc='0.05*sin(2*PI*300*t)+if(between(t,3.5,3.52),0.9*sin(2*PI*1000*(t-3.5)),0)':s=48000:d=6"]
                + codecs + [url.path]
            guard (try? ProcessRunner.run(ff.tool, MediaTestSupport.h264(args)))?.status == 0, let source = try? MediaSource.load(url) else {
                t.check(false, "make \(name)"); continue
            }
            defer { try? FileManager.default.removeItem(at: url) }
            let all = MediaMeasure.frameTimes(url), fd = source.frameDuration
            func wanted(_ r: MediaRange) -> Int {
                let cut = MediaTrim.frameRange(r, source: source)
                return all.filter { $0 >= cut.start - fd / 2 && $0 < cut.end - fd / 2 }.count
            }
            do {
                let out = try MediaTrim.trim(url, options: ["start": "3", "end": "4.5"]) { _ in }
                defer { try? FileManager.default.removeItem(at: out) }
                let got = MediaMeasure.frameTimes(out).count, want = wanted(MediaRange(start: 3, end: 4.5))
                let m = MediaTestSupport.flashAndBurst(out)
                t.check(got == want && m.map { abs($0.flash - 0.52) < 0.06 && abs($0.burst - $0.flash) < 0.03 } == true,
                        "\(name) trimmed 3.0–4.5 s (key frames 2 s apart): \(got) of \(want) frames, flash at "
                            + "\(m.map { f($0.flash) } ?? "?") s, the burst \(m.map { String(Int((($0.burst - $0.flash) * 1000).rounded())) } ?? "?") ms from it")
            } catch { t.check(false, "trim \(name): \(error.localizedDescription)") }
            do {
                let parts = try MediaSplit.split(url, options: ["mode": "every", "seconds": "3"]) { _ in }
                defer { parts.forEach { try? FileManager.default.removeItem(at: $0) } }
                // Every frame once (a lost GOP shows as a short sum); the cut may fall a frame either side of 3 s, as
                // ffmpeg's frame times in a transport stream and its reported video start differ by part of a frame.
                let got = parts.map { MediaMeasure.frameTimes($0).count }
                let want = [wanted(MediaRange(start: 0, end: 3)), wanted(MediaRange(start: 3, end: source.duration))]
                t.check(got.count == 2 && got.reduce(0, +) == all.count && abs(got[1] - want[1]) <= 1,
                        "\(name) split every 3 s: \(got.map(String.init).joined(separator: " + ")) frames of \(all.count) "
                            + "(about \(want.map(String.init).joined(separator: " + ")))")
            } catch { t.check(false, "split \(name): \(error.localizedDescription)") }
        }
        // The editor's still (shown while a preview copy is made) at 3.0 s of a moving picture, 1 s past a key frame:
        // the frame itself, not one decoded without its references (20 dB from every frame near it).
        let moving = dir.appendingPathComponent("moving.m2ts")
        guard (try? ProcessRunner.run(ff.tool, MediaTestSupport.h264(["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
                                                "testsrc2=s=320x240:r=25:d=6", "-c:v", "libx264", "-g", "50", "-bf", "2", "-f", "mpegts",
                                                moving.path])))?.status == 0, let source = try? MediaSource.load(moving) else {
            t.check(false, "make moving.m2ts"); return
        }
        defer { try? FileManager.default.removeItem(at: moving) }
        let times = MediaMeasure.frameTimes(moving)
        let k = times.firstIndex { $0 >= 3.0 - 0.001 } ?? 0
        let still = MediaKit.stillFrame(source, at: 3.0, maxPixels: 320).flatMap(MediaFrameTests.rawRGB)
        let scores = (max(0, k - 1)...(k + 1)).map { i in
            still.flatMap { s in MediaMeasure.frameRGB(moving, index: i, width: 320, height: 240).map { MediaMeasure.psnr(s, $0) } } ?? 0
        }
        t.check((scores.max() ?? 0) >= 35, "moving.m2ts: the still at 3.0 s is a frame of the file (best match of "
                + "\(scores.map { $0.isInfinite ? "inf" : String(format: "%.1f", $0) }.joined(separator: " / ")) dB against frames \(max(0, k - 1))–\(k + 1))")
    }

    // MARK: Sound that starts after the picture

    /// A clip whose sound starts at 0.5 s, with a flash and a burst together at 2.5 s: the waveform draws the burst
    /// under the flash, and cuts (re-encoded, copied from a key frame, Split's first part, a WMV) keep them together.
    private static func lateSound(_ t: MediaTestSupport.Checker, _ dir: URL) {
        for name in ["late.mp4", "late.wmv"] {
            let url = dir.appendingPathComponent(name)
            guard MediaTestSupport.makeLateSoundClip(url), let source = try? MediaSource.load(url),
                  let marks = MediaTestSupport.flashAndBurst(url) else { t.check(false, "make \(name)"); continue }
            t.check(abs(marks.flash - 2.5) < 0.02 && abs(marks.burst - 2.5) < 0.02,
                    "\(name): the flash (\(f(marks.flash)) s) and the burst (\(f(marks.burst)) s) are together at 2.5 s")
            if name == "late.mp4", let peaks = MediaKit.peaks(source) {
                let loudest = peaks.values.indices.max { peaks.values[$0] < peaks.values[$1] }.map { Double($0) / peaks.rate } ?? 0
                t.check(abs(loudest - 2.5) < 0.03, "\(name): the waveform draws the burst at \(f(loudest)) s, under the flash at 2.5 s")
            }
            var cuts: [(String, ToolOptions)] = [("re-encoded 0.2–3.5", ["start": "0.2", "end": "3.5"])]
            if name == "late.mp4" { cuts.append(("copied 0 to the end", ["start": "0"])) }
            for (what, options) in cuts {
                do {
                    let out = try MediaTrim.trim(url, options: options) { _ in }
                    defer { try? FileManager.default.removeItem(at: out) }
                    let m = MediaTestSupport.flashAndBurst(out)
                    let gap = m.map { $0.burst - $0.flash } ?? .nan
                    t.check(abs(gap) < 0.02, "\(name) trimmed \(what) (\(MediaTrim.lastMethod?.rawValue ?? "?")): the burst is "
                            + "\(Int((gap * 1000).rounded())) ms from the flash (the sound kept its place under the picture)")
                } catch { t.check(false, "trim \(name) \(what): \(error.localizedDescription)") }
            }
            do {
                let parts = try MediaSplit.split(url, options: ["parts": "2"]) { _ in }
                defer { parts.forEach { try? FileManager.default.removeItem(at: $0) } }
                // Part 1 is 0–2 s: its sound starts as long after its first frame as the source's does (0.5 s; a WMV
                // muxer may move both by the same amount). Part 2 (2–4 s) holds the flash and the burst together.
                func humAfterFirstFrame(_ u: URL) -> Double {
                    let x = MediaMeasure.pcm(u, rate: 48_000, channels: 1, fileClock: true)
                    let hum = x.firstIndex { abs(Int($0)) > 800 }.map { Double($0) / 48_000 } ?? .nan
                    return hum - (MediaMeasure.frameTimes(u).first ?? .nan)
                }
                let m = parts.count == 2 ? MediaTestSupport.flashAndBurst(parts[1]) : nil
                let want = humAfterFirstFrame(url), got = parts.first.map(humAfterFirstFrame) ?? .nan
                t.check(abs(want - 0.5) < 0.06 && abs(got - want) < 0.02 && m.map { abs($0.burst - $0.flash) < 0.02 } == true,
                        "\(name) split in 2: part 1’s sound starts \(f(got)) s after its first frame (the source: \(f(want)) s), "
                            + "part 2’s burst is with its flash")
            } catch { t.check(false, "split \(name): \(error.localizedDescription)") }
        }
    }

    // MARK: Probe parsing and time text

    private static func parsing(_ t: MediaTestSupport.Checker, fixtures: URL) {
        let phone = """
            Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'phone.mov':
              Duration: 00:00:02.50, start: 0.000000, bitrate: 9000 kb/s
              Stream #0:0[0x1](und): Video: hevc (Main) (hvc1 / 0x31637668), yuv420p(tv, bt709), 1920x1080, 8000 kb/s, 29.97 fps, 29.97 tbr, 600 tbn (default)
                Side data:
                  displaymatrix: rotation of -90.00 degrees
              Stream #0:1[0x2](und): Audio: pcm_s24le (in24 / 0x34326E69), 48000 Hz, stereo, s32 (24 bit), 2304 kb/s (default)
            """
        let p = MediaSource.parse(phone, url: URL(fileURLWithPath: "/x/phone.mov"))
        t.check(p.rotation == 90 && p.pixelSize == CGSize(width: 1080, height: 1920), "rotated clip: \(p.rotation)°, pixels \(p.pixelSize)")
        t.check(p.videoCodec == "hevc" && p.colorMatrix == "bt709" && p.audioCodec == "pcm_s24le" && p.audioBits == 24,
                "codecs, colour tag and bit depth parsed")
        t.check(abs(p.frameDuration - 1 / 29.97) < 1e-6 && p.snap(1.0) == p.snap(p.snap(1.0)), "frame grid at 29.97 fps")
        if let odd = try? MediaSource.load(fixtures.appendingPathComponent("odd.mkv")) {
            t.check(abs(odd.sampleAspect - 5776.0 / 5769) < 1e-9 && odd.pixelSize == CGSize(width: 641, height: 361)
                    && abs(odd.displayAspect - 16.0 / 9) < 0.003, "odd.mkv: SAR 5776:5769, 641 × 361 pixels shown at 16:9")
        } else { t.check(false, "odd.mkv probes") }
        if let wmv = try? MediaSource.load(fixtures.appendingPathComponent("sample.wmv")) {
            t.check(abs(wmv.videoStart - 0.046) < 1e-6 && abs(wmv.snap(1.05) - 1.046) < 1e-6 && wmv.snap(0.01) == 0,
                    "sample.wmv: first frame at 0.046 s, frames snap to its grid")
            t.check(wmv.snapEnd(4.08) == wmv.duration && abs(wmv.snapEnd(2.0) - wmv.snap(2.0)) < 1e-9,
                    "sample.wmv: an end after the last frame keeps the sound to \(f(wmv.duration)) s")
        } else { t.check(false, "sample.wmv probes") }
        t.check(MediaTime.string(65.5) == "1:05.50" && MediaTime.string(3725.25) == "1:02:05.25" && MediaTime.string(0.034) == "0:00.03",
                "times as m:ss.ff")
        t.check(MediaTime.parse("1:05.5") == 65.5 && MediaTime.parse("90") == 90 && MediaTime.parse("0,5") == 0.5
                && MediaTime.parse("0:61") == nil && MediaTime.parse("abc") == nil && MediaTime.parse("1.5:00") == nil,
                "typed times are read (and nonsense refused)")
    }

    // MARK: Pixel mapping

    private static func mapping(_ t: MediaTestSupport.Checker, _ odd: URL) {
        guard let source = try? MediaSource.load(odd) else { t.check(false, "odd.mkv probes for mapping"); return }
        let view = MediaPreviewView(source: source)
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        view.layoutSubtreeIfNeeded()
        let rect = view.pictureRect
        t.check(abs(rect.width / rect.height - 16.0 / 9) < 0.01, "odd.mkv is drawn 16:9 (\(rect.size))")
        let ppp = view.pointsPerPixel
        t.check(abs((ppp.width / ppp.height) - 5776.0 / 5769) < 0.004, "a pixel is drawn 5776:5769 wide (\(f(Double(ppp.width / ppp.height))))")
        let corner = view.viewPoint(fromPixel: CGPoint(x: 641, y: 361))
        t.check(view.viewPoint(fromPixel: .zero) == rect.origin && abs(corner.x - rect.maxX) < 0.01 && abs(corner.y - rect.maxY) < 0.01,
                "pixel corners land on the picture's corners")
        let box = CGRect(x: 100, y: 50, width: 240, height: 120)
        let back = view.pixelRect(fromView: view.viewRect(fromPixel: box))
        t.check(abs(back.minX - box.minX) < 0.01 && abs(back.width - box.width) < 0.01 && abs(back.maxY - box.maxY) < 0.01,
                "pixel → view → pixel round trip")
        let text = "Input #0, mov, from 'p.mov':\n  Duration: 00:00:01.00, start: 0.000000, bitrate: 1 kb/s\n"
            + "  Stream #0:0: Video: h264, yuv420p, 1920x1080, SAR 1:1 DAR 16:9, 30 fps, 30 tbr, 600 tbn\n"
            + "    Side data:\n      displaymatrix: rotation of -90.00 degrees\n"
        let rotated = MediaPreviewView(source: MediaSource.parse(text, url: URL(fileURLWithPath: "/x/p.mov")))
        rotated.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        rotated.layoutSubtreeIfNeeded()
        let r = rotated.pictureRect
        t.check(r.height > r.width && abs(r.width / r.height - 1080.0 / 1920) < 0.01
                && abs(rotated.viewPoint(fromPixel: CGPoint(x: 1080, y: 1920)).y - r.maxY) < 0.01,
                "a quarter-turned clip maps 1080 × 1920 pixels onto a portrait picture")
    }

    // MARK: Video

    private static var frameTimeCache: [URL: [Double]] = [:]

    private static func video(_ t: MediaTestSupport.Checker, _ url: URL, _ start: Double, _ end: Double, _ method: MediaTrim.Method) {
        let label = "\(url.lastPathComponent) \(f(start))–\(f(end))"
        do {
            let source = try MediaSource.load(url)
            let sourceTimes = frameTimeCache[url] ?? MediaMeasure.frameTimes(url)
            frameTimeCache[url] = sourceTimes
            let out = try MediaTrim.trim(url, options: ["start": String(start), "end": String(end)]) { _ in }
            defer { try? FileManager.default.removeItem(at: out) }
            let base = url.deletingPathExtension().lastPathComponent
            t.check(out.lastPathComponent == "\(base) trimmed.\(url.pathExtension)", "\(label): named \(out.lastPathComponent)")
            t.check(MediaTrim.lastMethod == method, "\(label): \(MediaTrim.lastMethod?.rawValue ?? "nil") (expected \(method.rawValue))")

            let cut = MediaTrim.frameRange(MediaRange(start: start, end: end), source: source)
            let fd = source.frameDuration
            let expected = sourceTimes.indices.filter {
                sourceTimes[$0] >= cut.start - fd / 2 && (cut.end >= source.duration || sourceTimes[$0] < cut.end - fd / 2)
            }
            let times = MediaMeasure.frameTimes(out)
            t.check(times.count == expected.count && !times.isEmpty, "\(label): \(times.count) frames (expected \(expected.count))")
            let measured = times.isEmpty ? 0 : times[times.count - 1] - times[0] + fd
            t.check(abs(measured - (end - start)) <= fd + 0.002, "\(label): \(f(measured)) s long, within a frame of \(f(end - start)) s")

            // Compare at the output's size: a re-encode evens an odd size by cutting the last row and column.
            let result = try MediaSource.load(out)
            let crop = result.pixelSize == source.pixelSize ? nil : result.pixelSize
            if let first = expected.first, let a = MediaMeasure.frameRGB(out, index: 0),
               let b = MediaMeasure.frameRGB(url, index: first, crop: crop) {
                let match = MediaMeasure.psnr(a, b)
                let neighbours = [first - 1, first + 1].filter { $0 >= 0 && $0 < sourceTimes.count }
                    .compactMap { MediaMeasure.frameRGB(url, index: $0, crop: crop).map { MediaMeasure.psnr(a, $0) } }
                let best = neighbours.max() ?? 0
                // 4:4:4 sources lose colour detail in a 4:2:0 re-encode (the test pattern's sharp colour edges).
                let floor = (source.pixelFormat ?? "").contains("444") ? 26.0 : 30.0
                t.check(match >= floor && match > best + 3,
                        "\(label): first frame is source frame \(first) (PSNR \(match.isInfinite ? "∞" : f(match)) dB, neighbours \(f(best)) dB)")
            } else {
                t.check(false, "\(label): frames decode for comparison")
            }

            t.check(result.hasAudio == source.hasAudio, "\(label): sound \(result.hasAudio ? "kept" : "absent, as in the source")")
            t.check(result.pixelSize.width >= source.pixelSize.width - 1 && result.pixelSize.height >= source.pixelSize.height - 1,
                    "\(label): picture \(Int(result.pixelSize.width)) × \(Int(result.pixelSize.height))")
            if source.hasAudio {
                let seconds = Double(MediaMeasure.pcm(out, rate: 8000, channels: 1).count) / 8000
                t.check(abs(seconds - (cut.end - cut.start)) <= 0.07, "\(label): sound lasts \(f(seconds)) s")
            }
        } catch {
            t.check(false, "\(label): \(error.localizedDescription)")
        }
    }

    // MARK: Sound

    private static func wav(_ t: MediaTestSupport.Checker, _ url: URL, _ start: Double, _ end: Double) {
        let label = "\(url.lastPathComponent) \(f(start))–\(f(end))"
        do {
            let out = try MediaTrim.trim(url, options: ["start": String(start), "end": String(end)]) { _ in }
            defer { try? FileManager.default.removeItem(at: out) }
            let result = try MediaSource.load(out)
            t.check(out.lastPathComponent == "tone trimmed.wav" && result.audioCodec == "pcm_s16le", "\(label): \(out.lastPathComponent), 16-bit PCM")
            let rate = Double(result.sampleRate ?? 0)
            let samples = MediaMeasure.pcm(out)
            let wanted = Int(((end - start) * rate).rounded())
            t.check(samples.count == wanted, "\(label): \(samples.count) samples (exactly \(wanted))")
            let original = MediaMeasure.pcm(url)
            let offset = Int((start * rate).rounded())
            let head = Array(samples.prefix(4000))
            t.check(head.count == 4000 && offset + 4000 <= original.count && Array(original[offset..<(offset + 4000)]) == head,
                    "\(label): the first 4000 samples are the source’s from sample \(offset)")
            let again = try MediaTrim.trim(url, options: ["start": "0", "end": "1"]) { _ in }
            t.check(again.lastPathComponent == "tone trimmed 2.wav", "a second trim is named \(again.lastPathComponent)")
            try? FileManager.default.removeItem(at: again)
        } catch {
            t.check(false, "\(label): \(error.localizedDescription)")
        }
    }

    /// 24-bit WAV stays 24-bit, sample for sample.
    private static func deepWav(_ t: MediaTestSupport.Checker, _ dir: URL) {
        guard let ff = FFmpeg.shared else { return }
        let url = dir.appendingPathComponent("deep.wav")
        do {
            try ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
                                            "sine=frequency=330:sample_rate=48000:duration=2", "-c:a", "pcm_s24le", url.path])
            let out = try MediaTrim.trim(url, options: ["start": "0.5", "end": "1.5"]) { _ in }
            let result = try MediaSource.load(out)
            let samples = MediaMeasure.pcm(out).count
            t.check(result.audioCodec == "pcm_s24le" && result.audioBits == 24 && samples == 48_000,
                    "24-bit WAV stays 24-bit: \(result.audioCodec ?? "?"), \(samples) samples")
        } catch {
            t.check(false, "24-bit WAV: \(error.localizedDescription)")
        }
    }

    private static func wma(_ t: MediaTestSupport.Checker, _ url: URL, _ start: Double, _ end: Double) {
        let label = "\(url.lastPathComponent) \(f(start))–\(f(end))"
        do {
            let out = try MediaTrim.trim(url, options: ["start": String(start), "end": String(end)]) { _ in }
            defer { try? FileManager.default.removeItem(at: out) }
            let result = try MediaSource.load(out)
            let seconds = Double(MediaMeasure.pcm(out, rate: 8000, channels: 1).count) / 8000
            // WMA decodes in blocks of 2048 samples (46 ms at 44.1 kHz).
            t.check(Ext.of(out) == "wma" && result.audioCodec == "wmav2" && abs(seconds - (end - start)) <= 0.05,
                    "\(label): WMA 2, \(f(seconds)) s")
            // The sound itself: the trimmed RMS matches the source's over the same stretch.
            let src = MediaMeasure.pcm(url, rate: 8000, channels: 1), got = MediaMeasure.pcm(out, rate: 8000, channels: 1)
            func rms(_ s: ArraySlice<Int16>) -> Double { sqrt(s.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, s.count))) }
            let a = rms(src[min(src.count, 8000 + 800)..<min(src.count, 8000 + 8800)]), b = rms(got[min(got.count, 800)..<min(got.count, 8800)])
            t.check(a > 100 && abs(a - b) / a < 0.1, "\(label): same loudness as the source stretch (RMS \(Int(a)) vs \(Int(b)))")
        } catch {
            t.check(false, "\(label): \(error.localizedDescription)")
        }
    }

    // MARK: Errors

    private static func badRanges(_ t: MediaTestSupport.Checker, _ dir: URL) {
        let fm = FileManager.default
        let count = { (try? fm.contentsOfDirectory(atPath: dir.path).filter { $0.contains(" trimmed") }.count) ?? -1 }
        let before = count()
        let wav = dir.appendingPathComponent("tone.wav"), clip = dir.appendingPathComponent("clip.mp4")
        t.throwsError("start after end", containing: "must be before the end") {
            _ = try MediaTrim.trim(wav, options: ["start": "3", "end": "2"]) { _ in }
        }
        t.throwsError("start equal to end", containing: "must be before the end") {
            _ = try MediaTrim.trim(clip, options: ["start": "2", "end": "2"]) { _ in }
        }
        t.throwsError("end past the length", containing: "past the end of tone.wav") {
            _ = try MediaTrim.trim(wav, options: ["end": "9"]) { _ in }
        }
        t.throwsError("start past the length", containing: "must be before the end") {
            _ = try MediaTrim.trim(clip, options: ["start": "6"]) { _ in }
        }
        t.throwsError("negative start", containing: "before 0:00.00") {
            _ = try MediaTrim.trim(clip, options: ["start": "-1", "end": "2"]) { _ in }
        }
        t.throwsError("less than a frame", containing: "shorter than one frame") {
            _ = try MediaTrim.trim(clip, options: ["start": "1", "end": "1.01"]) { _ in }
        }
        t.throwsError("start=abc", containing: "“abc” isn’t a time") {
            _ = try MediaTrim.trim(wav, options: ["start": "abc", "end": "2"]) { _ in }
        }
        t.check(count() == before, "bad ranges write nothing")
        // The window shows m:ss.ff; the same text works on the command line (start=1:30 once trimmed from 0).
        do {
            let out = try MediaTrim.trim(wav, options: ["start": "0:01.50", "end": "0:03"]) { _ in }
            defer { try? fm.removeItem(at: out) }
            let samples = MediaMeasure.pcm(out).count
            t.check(samples == 66_150, "start=0:01.50 end=0:03 keeps 1.5 s (\(samples) samples, 66150 expected)")
        } catch { t.check(false, "trim with m:ss.ff times: \(error.localizedDescription)") }
        t.throwsError("not a media file", containing: "can’t be read as video or audio") {
            let junk = dir.appendingPathComponent("junk.mp4")
            try Data("not a movie".utf8).write(to: junk)
            _ = try MediaTrim.trim(junk, options: [:]) { _ in }
        }
        t.check(count() == before, "bad ranges write nothing")
    }

    // MARK: Editor

    private static func editor(_ t: MediaTestSupport.Checker, _ clip: URL, _ tone: URL) {
        typealias S = MediaTestSupport
        do {
            let e = try S.editor(TrimEditorController.self, url: clip)
            let w = e.window
            func press(_ c: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) { _ = e.handleKey(S.key(c, keyCode: code, flags: flags, window: w)) }
            func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }
            t.check(!e.hasChanges && e.range == MediaRange(start: 0, end: 4), "a new Trim window keeps everything")
            let bar = S.toolbarLayout(w, tools: ["trim.setEdges"])
            t.check(bar.centred && bar.items == ["flex", "trim.setEdges", "flex", "media.undo", "media.redo", "space", "media.save"],
                    "toolbar: Set Start | Set End centred, Undo, Redo and Save trailing (\(bar.items.joined(separator: " ")))")
            // An item's `.prominent` style draws nothing in YummyOrange's toolbars: Save must be the accent push button.
            let saveButton = w.toolbar?.items.first { $0.itemIdentifier.rawValue == "media.save" }?.view as? ImageEditors.Bar.ProminentButton
            t.check(saveButton != nil && saveButton?.isEnabled == false,
                    "Save is the accent push button, disabled while nothing has changed")
            e.scrub(to: 1.0); press("i", S.Code.i)
            e.scrub(to: 2.0); press("o", S.Code.o)
            t.check(near(e.range.start, 1.0) && near(e.range.end, 2.0 + 1.0 / 30) && e.hasChanges,
                    "I and O: \(f(e.range.start))–\(f(e.range.end)) (O keeps the frame under the playhead)")
            press("z", S.Code.z, .command)
            t.check(near(e.range.end, 4.0) && near(e.range.start, 1.0), "⌘Z undoes Set End")
            press("z", S.Code.z, [.command, .shift])
            t.check(near(e.range.end, 2.0 + 1.0 / 30), "⇧⌘Z redoes it")
            press("\u{F703}", S.Code.right)
            t.check(near(e.playhead, 2.0 + 1.0 / 30), "→ steps one frame (\(f(e.playhead)))")
            press("\u{F703}", S.Code.right, .shift)
            t.check(near(e.playhead, 3.0 + 1.0 / 30), "⇧→ steps one second (\(f(e.playhead)))")
            press("\u{F729}", S.Code.home)
            t.check(e.playhead == 0, "Home goes to the start")
            press("\u{F72B}", S.Code.end)
            t.check(near(e.playhead, 4.0 - 1.0 / 30), "End goes to the last frame (\(f(e.playhead)))")
            press("I", S.Code.i, .shift)
            t.check(near(e.playhead, 1.0), "⇧I goes to the start of the selection")
            press("O", S.Code.o, .shift)
            t.check(near(e.playhead, 2.0), "⇧O goes to its last frame")
            press("=", 24, .command)
            t.check(e.timeline.zoom > 1, "⌘+ zooms the timeline in (\(f(Double(e.timeline.zoom)))×)")
            press("0", 29, .command)
            t.check(e.timeline.zoom == 1, "⌘0 fits it again")

            // The options Save would run, through the command itself.
            let options = try e.makeOptions()
            t.check(options["start"] == "1.000000" && options["end"] == "2.033333", "Save’s options: \(options)")
            let out = try MediaTrim.trim(clip, options: options) { _ in }
            let frames = MediaMeasure.frameTimes(out).count
            if let a = MediaMeasure.frameRGB(out, index: 0), let b = MediaMeasure.frameRGB(clip, index: 30) {
                t.check(frames == 31 && MediaMeasure.psnr(a, b) >= 30, "saving the window’s range keeps frames 30…60 (\(frames) frames)")
            } else { t.check(false, "the window’s range saves") }
            try? FileManager.default.removeItem(at: out)

            // Dragging the start handle (grabbed a few points inside its grip), then Esc during another drag.
            let tl = e.timeline!
            let y = tl.bounds.height / 2
            S.drag(tl, from: CGPoint(x: tl.x(1.0) - 4, y: y), to: CGPoint(x: tl.x(1.5) - 4, y: y))
            t.check(near(e.range.start, 1.5) && e.undo.undoActionName == "Change Start", "dragging the start handle: \(f(e.range.start)) s")
            S.drag(tl, from: CGPoint(x: tl.x(1.5) - 4, y: y), to: CGPoint(x: tl.x(0.5) - 4, y: y)) { tl.cancelDrag() }
            t.check(near(e.range.start, 1.5), "Esc during a drag puts the handle back")
            e.performUndo()
            t.check(near(e.range.start, 1.0), "Undo puts the dragged handle back")
            S.drag(tl, from: CGPoint(x: tl.x(3.0), y: 8), to: CGPoint(x: tl.x(3.5), y: 8))
            t.check(near(e.playhead, 3.5) && near(e.range.start, 1.0), "dragging in the ruler scrubs (\(f(e.playhead)) s)")

            // VoiceOver: the playhead and both handles are adjustable.
            let children = (tl.accessibilityChildren() ?? []).compactMap { $0 as? MediaTimelineAXElement }
            t.check(children.count == 3 && children.allSatisfy { $0.accessibilityRole() == .slider },
                    "timeline exposes 3 adjustable elements: \(children.compactMap { $0.accessibilityLabel() })")
            if let endHandle = children.first(where: { $0.accessibilityLabel() == "Selection end" }) {
                _ = endHandle.accessibilityPerformIncrement()
                t.check(near(e.range.end, 2.0 + 2.0 / 30) && (endHandle.accessibilityValue() as? String) == "0:02.07",
                        "incrementing the end handle moves it one frame (\(f(e.range.end)))")
            } else { t.check(false, "end handle element") }

            // Sound: no preview; O ends exactly at the playhead.
            let a = try S.editor(TrimEditorController.self, url: tone)
            t.check(a.preview == nil && a.timeline.mode == .single, "the audio window has no picture")
            a.scrub(to: 1.0); _ = a.handleKey(S.key("i", keyCode: S.Code.i, window: a.window))
            a.scrub(to: 2.5); _ = a.handleKey(S.key("o", keyCode: S.Code.o, window: a.window))
            t.check(near(a.range.start, 1.0) && near(a.range.end, 2.5), "audio I/O: \(f(a.range.start))–\(f(a.range.end))")
            a.forceClose()
            e.forceClose()
        } catch {
            t.check(false, "editor: \(error.localizedDescription)")
        }
    }

    // MARK: The kit's other modes (what Bleep and the frame tools build on)

    /// A list-of-ranges editor, as Bleep will be.
    final class RangesEditor: MediaEditorWindowController {
        override class var toolName: String { "Ranges" }
        override var timelineMode: MediaTimelineView.Mode { .multiple }
    }

    /// Only a playhead, as Crop and Snapshot will be; a box overlay installed in didBuild.
    final class FrameEditor: MediaEditorWindowController {
        override class var toolName: String { "Frame" }
        override var timelineMode: MediaTimelineView.Mode { .none }
        let box = NSView()
        override func didBuild() {
            guard let preview else { return }
            box.frame = preview.overlay.bounds
            box.autoresizingMask = [.width, .height]
            preview.overlay.addSubview(box)
        }
    }

    private static func multipleRanges(_ t: MediaTestSupport.Checker, _ clip: URL) {
        typealias S = MediaTestSupport
        do {
            let e = try S.editor(RangesEditor.self, url: clip)
            let w = e.window, tl = e.timeline!
            func press(_ c: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) { _ = e.handleKey(S.key(c, keyCode: code, flags: flags, window: w)) }
            func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }
            t.check(e.ranges.isEmpty && !e.hasChanges, "multiple mode starts with no ranges")
            e.scrub(to: 1.0); press("i", S.Code.i)
            t.check(e.ranges.count == 1 && near(e.ranges[0].start, 1) && near(e.ranges[0].end, 2) && e.selectedRange == 0,
                    "I with nothing selected adds a one-second range")
            e.scrub(to: 1.5); press("o", S.Code.o)
            t.check(near(e.ranges[0].end, 1.5 + 1.0 / 30), "O ends the selected range after the frame at the playhead")
            // Drag on empty lanes adds a range; it stops at its neighbour.
            let y = tl.bounds.height / 2
            S.drag(tl, from: CGPoint(x: tl.x(3.0), y: y), to: CGPoint(x: tl.x(1.2), y: y))
            t.check(e.ranges.count == 2 && near(e.ranges[1].start, 1.5 + 1.0 / 30) && near(e.ranges[1].end, 3.0) && e.selectedRange == 1,
                    "dragging on empty lanes adds a range that stops at its neighbour: \(e.ranges.map { "\(f($0.start))–\(f($0.end))" })")
            // Click the first range to select it, then drag its body.
            S.drag(tl, from: CGPoint(x: tl.x(1.2), y: y), to: CGPoint(x: tl.x(1.2), y: y))
            t.check(e.selectedRange == 0, "clicking a range selects it")
            S.drag(tl, from: CGPoint(x: tl.x(1.2), y: y), to: CGPoint(x: tl.x(0.7), y: y))
            t.check(near(e.ranges[0].start, 0.5) && near(e.ranges[0].length, 0.5 + 1.0 / 30) && e.undo.undoActionName == "Move Range",
                    "dragging a range moves it, length kept (\(f(e.ranges[0].start))–\(f(e.ranges[0].end)))")
            S.drag(tl, from: CGPoint(x: tl.x(0.7), y: y), to: CGPoint(x: tl.x(3.5), y: y))
            t.check(e.ranges[0].end <= e.ranges[1].start + 1e-9, "a moved range can’t overlap the next one")
            e.performUndo()
            press("\u{7f}", S.Code.delete)
            t.check(e.ranges.count == 1 && near(e.ranges[0].start, 1.5 + 1.0 / 30) && e.selectedRange == nil, "⌫ deletes the selected range")
            e.performUndo()
            t.check(e.ranges.count == 2 && near(e.ranges[0].start, 0.5), "Undo brings it back")
            let children = tl.accessibilityChildren() ?? []
            t.check(children.count == 5, "VoiceOver: the playhead and both ends of each range (\(children.count) elements)")
            e.forceClose()

            let fr = try S.editor(FrameEditor.self, url: clip)
            t.check(fr.timeline.mode == .none && fr.box.superview === fr.preview?.overlay && fr.box.frame.size == fr.preview?.overlay.bounds.size,
                    "frame mode: no ranges, the overlay view installed by didBuild covers the preview")
            fr.scrub(to: 2.0); _ = fr.handleKey(S.key("i", keyCode: S.Code.i, window: fr.window))
            t.check(fr.ranges.isEmpty && fr.playhead == 2.0, "frame mode: I sets no range")
            fr.forceClose()
        } catch {
            t.check(false, "multiple ranges: \(error.localizedDescription)")
        }
    }

    // MARK: Live preview (AVFoundation, proxies, exact scrubbing), in windows that are never shown

    private static func waitUntil(_ timeout: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    /// The player's picture at `t`: its luma plane averaged to 160 × 90 (through AVPlayerItemVideoOutput). Waits for
    /// the buffer whose display time is `t` (older buffers still queued in the output are skipped).
    private static func playerLuma(_ output: AVPlayerItemVideoOutput, at t: Double) -> [UInt8]? {
        let time = CMTime(seconds: t, preferredTimescale: 90_000)
        var buffer: CVPixelBuffer?
        _ = waitUntil(3) {
            guard output.hasNewPixelBuffer(forItemTime: time) else { return false }
            var shownAt = CMTime.zero
            buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &shownAt)
            return buffer != nil && abs(shownAt.seconds - t) < 0.005
        }
        guard let buffer, CVPixelBufferGetPlaneCount(buffer) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        return MediaMeasure.areaAverage(base.assumingMemoryBound(to: UInt8.self), width: CVPixelBufferGetWidthOfPlane(buffer, 0),
                                        height: CVPixelBufferGetHeightOfPlane(buffer, 0),
                                        rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), to: 160, 90)
    }

    /// A video output on the player's item, so tests can see the frame it shows (added once, before scrubbing).
    private static func attachOutput(_ e: TrimEditorController) -> AVPlayerItemVideoOutput? {
        guard let item = e.playback?.player.currentItem else { return nil }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        item.add(output)
        _ = waitUntil(0.5) { false }
        return output
    }

    /// Scrubs to `t` and checks the player shows source frame `index` (closest match of it and its neighbours).
    private static func checkScrub(_ t: MediaTestSupport.Checker, _ e: TrimEditorController, _ output: AVPlayerItemVideoOutput?,
                                   to time: Double, frame index: Int, _ label: String) {
        guard let output else { t.check(false, "\(label): no player item"); return }
        e.scrub(to: time)
        // It lands 1 ms in (MediaPlayback.seekNudge), so a frame stored a little late (whole milliseconds) still shows.
        t.check(waitUntil(5) { abs((e.playback?.currentTime ?? -1) - time - 0.001) < 0.0005 }, "\(label): the player seeks exactly to \(f(time)) s (+1 ms)")
        guard let shown = playerLuma(output, at: time) else { t.check(false, "\(label): the player has a frame to show"); return }
        let scores = (index - 1...index + 1).map { i in MediaMeasure.frameLuma(e.source.url, index: i).map { MediaMeasure.psnr(shown, $0) } ?? 0 }
        t.check(scores[1] >= 30 && scores[1] > max(scores[0], scores[2]) + 3,
                "\(label): scrubbing shows source frame \(index) (PSNR \(scores.map { f($0) }.joined(separator: " / ")) for frames \(index - 1)…\(index + 1))")
    }

    private static func livePreview(_ t: MediaTestSupport.Checker, _ clip: URL, _ odd: URL, _ wma: URL) {
        do {
            // A file AVFoundation plays: no proxy.
            let e = TrimEditorController(source: try MediaSource.load(clip), snapshot: false)
            e.window.setContentSize(CGSize(width: 1000, height: 660))
            e.loadPreview()
            t.check(waitUntil(15) { e.playerReady }, "clip.mp4: the preview plays the file itself")
            t.check(e.proxyDir == nil && (e.playback?.player.currentItem?.asset as? AVURLAsset)?.url == clip, "clip.mp4: no proxy")
            let output = attachOutput(e)
            checkScrub(t, e, output, to: 1.5, frame: 45, "clip.mp4")
            checkScrub(t, e, output, to: 3.0 + 1.0 / 30, frame: 91, "clip.mp4")
            checkScrub(t, e, output, to: e.source.step(3.0 + 1.0 / 30, by: -1), frame: 90, "clip.mp4 ← one frame")
            e.forceClose()

            // mkv: a proxy, with "Preparing preview…" while it's made; deleted on close.
            let m = TrimEditorController(source: try MediaSource.load(odd), snapshot: false)
            m.window.setContentSize(CGSize(width: 1000, height: 660))
            m.loadPreview()
            t.check(waitUntil(10) { m.preview?.isShowingLoading == true || m.playerReady }, "odd.mkv: “Preparing preview…” shows while the proxy is made")
            t.check(waitUntil(60) { m.playerReady } && m.preview?.isShowingLoading == false, "odd.mkv: the proxy plays and the progress goes away")
            let proxy = (m.playback?.player.currentItem?.asset as? AVURLAsset)?.url
            let dir = m.proxyDir
            t.check(dir != nil && proxy?.deletingLastPathComponent().standardizedFileURL == dir?.standardizedFileURL
                    && FileManager.default.fileExists(atPath: proxy?.path ?? ""), "odd.mkv: proxy \(proxy?.lastPathComponent ?? "none") in a temporary folder")
            if let proxy, let p = try? MediaSource.load(proxy) {
                t.check(p.sampleAspect == 1 && abs(p.displayAspect - 16.0 / 9) < 0.01 && abs(p.duration - 3) < 0.05,
                        "odd.mkv: the proxy has square pixels, 16:9 and the same length (\(Int(p.pixelSize.width)) × \(Int(p.pixelSize.height)))")
            }
            checkScrub(t, m, attachOutput(m), to: 1.0, frame: 25, "odd.mkv proxy")
            m.forceClose()
            t.check(dir.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false, "odd.mkv: closing deletes the proxy")

            // wma: an .m4a proxy; the transport bar shows the progress (no picture to show it on).
            let a = TrimEditorController(source: try MediaSource.load(wma), snapshot: false)
            a.loadPreview()
            t.check(waitUntil(60) { a.playerReady } && a.transport.playButton.isEnabled, "sample.wma: an .m4a proxy plays")
            t.check(a.proxyDir.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("preview.m4a").path) } ?? false,
                    "sample.wma: preview.m4a")
            let aDir = a.proxyDir
            a.forceClose()
            t.check(aDir.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false, "sample.wma: closing deletes the proxy")

            // Closing while it plays (muted) lets go of everything: the window's controller, the player and its item,
            // so no observer, boundary or audio keeps running after the window is gone.
            weak var closed: TrimEditorController?, player: AVPlayer?, item: AVPlayerItem?
            try autoreleasepool {
                let c = TrimEditorController(source: try MediaSource.load(clip), snapshot: false)
                c.loadPreview()
                _ = waitUntil(15) { c.playerReady }
                c.playback?.player.isMuted = true
                c.togglePlay()
                let playing = waitUntil(3) { c.playback?.isPlaying == true && (c.playback?.currentTime ?? 0) > 0.1 }
                closed = c; player = c.playback?.player; item = c.playback?.player.currentItem
                c.forceClose()
                t.check(playing && player?.rate == 0 && player?.currentItem == nil, "closing while playing stops the player and lets go of the item")
            }
            _ = waitUntil(3) { closed == nil && player == nil && item == nil }
            t.check(closed == nil && player == nil && item == nil,
                    "… and the controller, player and item are freed (\(closed == nil && player == nil && item == nil ? "nothing left" : [closed == nil ? "" : "controller", player == nil ? "" : "player", item == nil ? "" : "item"].filter { !$0.isEmpty }.joined(separator: ", ") + " left"))")
        } catch {
            t.check(false, "live preview: \(error.localizedDescription)")
        }
    }

    private static func snapshot(_ t: MediaTestSupport.Checker, _ clip: URL) {
        let view = MediaTrim.snapshot("trim", files: [clip], options: ["start": "1", "end": "3"])
        let size = (view as? NSImageView)?.image?.size ?? .zero
        t.check(size.width >= 1000 && size.height >= 660, "the snapshot renders the whole window (\(Int(size.width)) × \(Int(size.height)))")
    }
}
#endif
