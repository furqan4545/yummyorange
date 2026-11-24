#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit

/// `--selftest media-merge`: Merge on clips made here with ffmpeg and on the fixtures, measured with ffmpeg.
/// Each made clip has its own colour, a white flash on one frame and a 1 kHz click on the same moment:
/// - a.mp4 / b.mp4: 640×360, 30 fps, 2 s, stereo; red / green, flash on frame 3 (0.1 s). Same encoder settings, so
///   a + b takes the lossless path.
/// - c.mkv / c2.mkv: 480×480 (square, so it is pillarboxed in 16:9), 25 fps, 1.6 s, mono; blue / cyan, flash 0.12 s.
/// - p.mp4: a portrait clip stored on its side with a rotation (upright 360×640), yellow with a white band at the
///   top, 1 s, flash 0.1 s.
/// - n.mp4: 320×240 (4:3), no sound, magenta, 1 s, flash 0.1 s.
/// - l.mp4: black 320×240, 4 s, sound that starts 0.5 s after the picture, flash and burst at 2.5 s.
/// It checks the order (each stretch starts with that file's first frame, the frame before a join is the previous
/// file's), frame counts and lengths that add up, every flash on its frame and its click within a frame of it, the
/// size (the first file's display size, letterboxed, upright), silence for the clip without sound, the late sound in
/// its place, a lossless copy that copies (identical packets and decoded frames, faster than the re-encode), sound
/// merges joined sample for sample, the wheels (Merge instead of Channels… for several files), errors, the command
/// line, inputs unchanged and outputs never overwritten.
enum MediaMergeTests {
    typealias Checker = MediaTestSupport.Checker

    static func run() -> String {
        let t = Checker("media-merge")
        guard FFmpeg.shared != nil else { return "OK media-merge: skipped, ffmpeg isn’t installed" }
        guard let fixtures = MediaTestSupport.fixturesFolder() else {
            return "FAIL media-merge: can’t find Tests/fixtures/features. Run from the project folder or set DW_FIXTURES."
        }
        let names = ["clip.mp4", "odd.mkv", "sample.wmv", "tone.wav", "sample.wma"]
        let dir: URL
        do { dir = try MediaTestSupport.scratchCopy(of: names, from: fixtures) } catch {
            return "FAIL media-merge: couldn’t copy the fixtures: \(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
        guard makeClips(dir) else { return "FAIL media-merge: couldn’t make the test clips with ffmpeg" }
        let made = ["a.mp4", "b.mp4", "c.mkv", "c2.mkv", "p.mp4", "n.mp4", "l.mp4", "gen.mp3", "st.wav", "s1.mp4", "s2.mp4"]
        let all = names + made
        let before = Dictionary(uniqueKeysWithValues: all.map { ($0, MediaMeasure.sha256(url($0))) })

        commands(t, dir)
        wheels(t, dir)
        mixed(t, dir)
        reversed(t, dir)
        copyPath(t, dir)
        fixturesMerge(t, dir)
        sounds(t, dir)
        errors(t, dir)
        preroll(t, dir)
        longSound(t, dir)
        readOnlyFolder(t, dir)
        commandLineScope(t, dir)

        for name in all { t.check(MediaMeasure.sha256(url(name)) == before[name], "\(name) unchanged") }
        for name in names {
            t.check(MediaMeasure.sha256(fixtures.appendingPathComponent(name)) == before[name], "fixture \(name) unchanged")
        }
        return t.report
    }

    // MARK: Clips

    private static func makeClips(_ dir: URL) -> Bool {
        guard let ff = FFmpeg.shared else { return false }
        func run(_ args: [String]) -> Bool {
            (try? ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + args))?.status == 0
        }
        let p = dir.path + "/"
        func picture(_ colour: String, _ size: String, _ rate: Int, _ seconds: Double, flash: Int, extra: String = "") -> String {
            "color=c=\(colour):s=\(size):r=\(rate):d=\(seconds)\(extra),drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='eq(n,\(flash))'"
        }
        func sound(_ seconds: Double, click: Double, rate: Int, stereo: Bool) -> String {
            let one = "0.05*sin(2*PI*300*t)+if(between(t,\(click),\(click + 0.02)),0.9*sin(2*PI*1000*(t-\(click))),0)"
            return "aevalsrc='\(stereo ? one + "|" + one : one)':s=\(rate):d=\(seconds)"
        }
        let x264 = ["-c:v", "libx264", "-preset", "veryfast", "-bf", "2", "-pix_fmt", "yuv420p"]
        func clip(_ name: String, _ video: String, _ audio: String?, gop: Int) -> Bool {
            var args = ["-f", "lavfi", "-i", video]
            if let audio { args += ["-f", "lavfi", "-i", audio, "-map", "0:v", "-map", "1:a"] } else { args += ["-map", "0:v"] }
            args += x264 + ["-g", String(gop)] + (audio == nil ? [] : ["-c:a", "aac", "-b:a", "128k"]) + [p + name]
            return run(args)
        }
        return clip("a.mp4", picture("0xC81E1E", "640x360", 30, 2, flash: 3), sound(2, click: 0.1, rate: 48_000, stereo: true), gop: 30)
            && clip("b.mp4", picture("0x1EA01E", "640x360", 30, 2, flash: 3), sound(2, click: 0.1, rate: 48_000, stereo: true), gop: 30)
            && clip("c.mkv", picture("0x1E3CC8", "480x480", 25, 1.6, flash: 3), sound(1.6, click: 0.12, rate: 44_100, stereo: false), gop: 25)
            && clip("c2.mkv", picture("0x1EB4C8", "480x480", 25, 1.6, flash: 3), sound(1.6, click: 0.12, rate: 44_100, stereo: false), gop: 25)
            // Upright 360×640 with a white band on top, stored turned a quarter clockwise, with a rotation that turns it back.
            && clip("p-stored.mp4", picture("0xDCC81E", "360x640", 30, 1, flash: 3, extra: ",drawbox=x=0:y=0:w=iw:h=80:color=white:t=fill") + ",transpose=1",
                    sound(1, click: 0.1, rate: 48_000, stereo: true), gop: 30)
            && run(["-display_rotation", "90", "-i", p + "p-stored.mp4", "-c", "copy", p + "p.mp4"])
            && clip("n.mp4", picture("0xC81EC8", "320x240", 30, 1, flash: 3), nil, gop: 30)
            && MediaTestSupport.makeLateSoundClip(dir.appendingPathComponent("l.mp4"))
            // s1 / s2: 10 s of 1280×720 each, to time the copy against the re-encode on something the size of a real clip.
            && clip("s1.mp4", "testsrc2=s=1280x720:r=30:d=10", sound(10, click: 1, rate: 48_000, stereo: true), gop: 60)
            && clip("s2.mp4", "testsrc2=s=1280x720:r=30:d=10,hue=h=90", sound(10, click: 1, rate: 48_000, stereo: true), gop: 60)
            && run(["-f", "lavfi", "-i", "sine=frequency=660:sample_rate=44100:duration=1.5", "-c:a", "libmp3lame", "-b:a", "128k", p + "gen.mp3"])
            && run(["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1", "-f", "lavfi", "-i",
                    "sine=frequency=880:sample_rate=48000:duration=1", "-filter_complex",
                    "[0:a][1:a]join=inputs=2:channel_layout=stereo,volume=0.5[a]", "-map", "[a]", "-c:a", "pcm_s16le", p + "st.wav"])
    }

    // MARK: Measurements

    /// Each decoded frame's mean brightness (0…255) in the middle of the picture (a quarter of the width, half the
    /// height: inside every letterboxed or pillarboxed clip here), in order.
    private static func brightness(_ url: URL) -> [Int] {
        guard let ff = FFmpeg.shared,
              let r = try? ProcessRunner.run(ff.tool, ["-hide_banner", "-nostdin", "-i", url.path, "-map", "0:v:0",
                                                       "-vf", "crop=iw/4:ih/2,scale=16:12,format=gray,showinfo", "-f", "null", "-"]) else { return [] }
        return r.stderr.split(separator: "\n").filter { $0.contains("pts_time:") }
            .compactMap { $0.firstMatch(of: #/mean:\[(\d+)/#).flatMap { Int($0.1) } }
    }

    /// Frames that are a white flash (mean brightness over 200).
    private static func flashes(_ url: URL) -> [Int] {
        brightness(url).enumerated().filter { $0.element > 200 }.map(\.offset)
    }

    /// When each click starts (the first sample over 0.3 of full scale after a stretch of at least 0.2 s without
    /// one), in seconds on the file's clock, from the sound mixed to mono at 48 kHz.
    private static func clicks(_ url: URL) -> [Double] {
        let x = MediaMeasure.pcm(url, rate: 48_000, channels: 1, fileClock: true)
        var out: [Double] = []
        var last = -1_000_000
        for (i, v) in x.enumerated() where abs(Int(v)) > 9_830 {
            if i - last > 9_600 { out.append(Double(i) / 48_000) }
            last = i
        }
        return out
    }

    /// The packets of a stream as "size crc", in order (the same list for a copied stream).
    private static func packets(_ url: URL, _ stream: String = "0:v:0") -> [String] {
        guard let ff = FFmpeg.shared,
              let r = try? ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", url.path, "-map", stream,
                                                       "-c", "copy", "-f", "framecrc", "-"]), r.status == 0 else { return [] }
        return r.stdout.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { line in
            line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.dropFirst(4).prefix(2).joined(separator: " ")
        }
    }

    /// The MD5 of every decoded frame, in order.
    private static func frameHashes(_ url: URL) -> [String] {
        guard let ff = FFmpeg.shared,
              let r = try? ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", url.path, "-map", "0:v:0",
                                                       "-f", "framemd5", "-"]), r.status == 0 else { return [] }
        return r.stdout.split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap { $0.split(separator: ",").last.map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The colour of frame `index` at (x, y) in a 64×36 thumbnail of it (or `w`×`h`).
    private static func colour(_ url: URL, _ index: Int, x: Int, y: Int, w: Int = 64, h: Int = 36) -> (r: Int, g: Int, b: Int)? {
        guard let rgb = MediaMeasure.frameRGB(url, index: index, width: w, height: h) else { return nil }
        let i = (y * w + x) * 3
        return (Int(rgb[i]), Int(rgb[i + 1]), Int(rgb[i + 2]))
    }

    private static func near(_ c: (r: Int, g: Int, b: Int)?, _ hex: Int, _ tolerance: Int = 40) -> Bool {
        guard let c else { return false }
        return abs(c.r - (hex >> 16 & 255)) <= tolerance && abs(c.g - (hex >> 8 & 255)) <= tolerance && abs(c.b - (hex & 255)) <= tolerance
    }

    private static func dark(_ c: (r: Int, g: Int, b: Int)?) -> Bool { c.map { $0.r < 24 && $0.g < 24 && $0.b < 24 } ?? false }
    private static func describe(_ c: (r: Int, g: Int, b: Int)?) -> String { c.map { "(\($0.r),\($0.g),\($0.b))" } ?? "nil" }
    private static func f(_ v: Double) -> String { String(format: "%.4f", v) }

    private static func merge(_ t: Checker, _ what: String, _ files: [URL], allowCopy: Bool = true,
                              progress: @escaping (Double) -> Void = { _ in }) -> URL? {
        do { return try MediaMerge.merge(files, allowCopy: allowCopy, progress: progress) } catch {
            t.check(false, "\(what): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Command and wheels

    private static func commands(_ t: Checker, _ dir: URL) {
        let c = MediaMerge.command
        t.check(c.id == "merge" && c.title == "Merge" && c.wheel == .tools && c.combinesInputs && c.ask == nil && c.present == nil && c.run != nil,
                "Merge: id merge, title without “…”, Tools wheel, combines the files, runs at once")
        t.check(c.symbol == "arrow.triangle.merge" && NSImage(systemSymbolName: c.symbol ?? "", accessibilityDescription: nil) != nil,
                "symbol arrow.triangle.merge exists on this Mac")
        let ids = MediaTools.commands.map(\.id)
        t.check(ids == ["bleep", "speed", "split", "channels", "merge", "visualize"], "Merge comes right after Channels: \(ids)")
        func u(_ n: String) -> URL { dir.appendingPathComponent(n) }
        t.check(c.applies([u("clip.mp4"), u("odd.mkv"), u("sample.wmv")]) && c.applies([u("tone.wav"), u("sample.wma"), u("gen.mp3")]),
                "applies to videos together and to sounds together")
        t.check(!c.applies([u("clip.mp4")]) && !c.applies([u("tone.wav")]) && !c.applies([u("clip.mp4"), u("tone.wav")])
                && !c.applies([u("clip.mp4"), URL(fileURLWithPath: "/x/report.pdf")]),
                "not for one file, a video with a sound, or a video with a PDF")
        let channels = MediaTools.channels
        t.check(channels.applies([u("clip.mp4")]) && channels.applies([u("tone.wav")]) && !channels.applies([u("clip.mp4"), u("a.mp4")])
                && !channels.applies([u("tone.wav"), u("sample.wma")]), "Channels… only for one file")
        let perFile = MediaTools.commands.filter { $0.id != "merge" && $0.id != "channels" && $0.id != "visualize" }
        t.check(perFile.allSatisfy { $0.applies([u("clip.mp4"), u("a.mp4")]) && $0.applies([u("clip.mp4")]) },
                "Bleep, Speed and Split still apply to one or several videos")
        t.check(Registry.command(.tools, named: "merge", files: [u("a.mp4"), u("b.mp4")])?.id == "merge"
                && Registry.command(.tools, named: "Merge", files: [u("a.mp4"), u("b.mp4")])?.id == "merge", "found by id and by title")
    }

    private static func wheels(_ t: Checker, _ dir: URL) {
        func u(_ n: String) -> URL { dir.appendingPathComponent(n) }
        func titles(_ files: [URL]) -> [String] { AppDelegate.items(for: .tools, files: files).map(\.title) }
        let one = titles([u("a.mp4")]), two = titles([u("a.mp4"), u("b.mp4")]), three = titles([u("a.mp4"), u("c.mkv"), u("sample.wmv")])
        t.check(one.contains("Channels…") && !one.contains("Merge"), "one video: Channels…, no Merge")
        t.check(two.contains("Merge") && !two.contains("Channels…") && three.contains("Merge") && !three.contains("Channels…"),
                "two or three videos: Merge, no Channels…")
        t.check(two == one.map { $0 == "Channels…" ? "Merge" : $0 }, "Merge takes Channels…’s place; every other petal stays: \(two)")
        let mixed = titles([u("a.mp4"), u("tone.wav")])
        t.check(!mixed.contains("Merge") && !mixed.contains("Channels…"), "a video and a sound: neither Merge nor Channels…: \(mixed)")
        let sounds = titles([u("tone.wav"), u("sample.wma")]), sound = titles([u("tone.wav")])
        t.check(sounds.contains("Merge") && !sounds.contains("Channels…") && sounds.contains("Visualize…")
                && sound.contains("Channels…") && !sound.contains("Merge"), "sounds: Merge for two, Channels… for one; Visualize… stays")
        for (name, files) in [("two videos", [u("a.mp4"), u("b.mp4")]), ("two sounds", [u("tone.wav"), u("sample.wma")])] {
            let items = AppDelegate.items(for: .tools, files: files)
            let d = WheelLayout.diameter(for: items.count)
            let view = WheelView(frame: CGRect(x: 0, y: 0, width: d, height: d))
            view.items = items
            let cut = view.labels.indices.filter { view.labels[$0].truncated }.map { items[$0].title }
            t.check(view.layout.count == items.count && cut.isEmpty, "\(name): all \(items.count) petals on the wheel, no label cut \(cut)")
        }
    }

    // MARK: Videos

    /// a, c, p, n, l: every kind of difference at once (re-encode).
    private static func mixed(_ t: Checker, _ dir: URL) {
        func u(_ n: String) -> URL { dir.appendingPathComponent(n) }
        var seen: [Double] = []
        let start = Date()
        guard let out = merge(t, "merge a c p n l", [u("a.mp4"), u("c.mkv"), u("p.mp4"), u("n.mp4"), u("l.mp4")], progress: { seen.append($0) })
        else { return }
        let elapsed = Date().timeIntervalSince(start)
        t.check(out.lastPathComponent == "a merged.mp4" && out.deletingLastPathComponent().path == dir.path && MediaMerge.lastMethod == .reencode,
                "one file, “a merged.mp4” next to a.mp4, re-encoded (\(MediaMerge.lastCopyRefusal ?? "")) in \(String(format: "%.2f", elapsed)) s")
        guard let r = try? MediaSource.load(out) else { t.check(false, "the result can’t be read"); return }
        t.check(r.pixelSize == CGSize(width: 640, height: 360) && r.sampleAspect == 1 && r.rotation == 0 && r.fps == 30
                && r.videoCodec == "h264" && r.audioCodec == "aac" && r.sampleRate == 48_000 && r.channels == 2,
                "640×360 (a’s size), square pixels, upright, 30 fps, H.264 + AAC 48 kHz stereo: \(r.pixelSize) SAR \(r.sampleAspect) "
                + "\(r.fps ?? 0) fps \(r.videoCodec ?? "?") \(r.audioCodec ?? "?") \(r.sampleRate ?? 0) Hz \(r.channels ?? 0) ch")
        // Stretches in frames at 30 fps: a 60, c 1.6 s → 48, p 30, n 30, l 120.
        let starts = [0, 60, 108, 138, 168], total = 288
        let times = MediaMeasure.frameTimes(out)
        let grid = times.enumerated().map { abs($0.element - Double($0.offset) / 30) }.max() ?? 1
        t.check(times.count == total && grid < 0.001, "\(times.count) frames (60 + 48 + 30 + 30 + 120 = 288), every one on the 30 fps grid (off by \(f(grid)) s at most)")
        let scan = (try? MediaMerge.inspect(out, ff: FFmpeg.shared!))?.scan
        t.check(abs((scan?.videoEnd ?? 0) - 9.6) < 0.001 && abs((scan?.audioEnd ?? 0) - 9.6) < 0.025,
                "picture and sound both 9.6 s long (2 + 1.6 + 1 + 1 + 4): \(f(scan?.videoEnd ?? 0)) and \(f(scan?.audioEnd ?? 0))")
        let samples = MediaMeasure.pcm(out, rate: 48_000, channels: 1).count
        t.check(abs(samples - 460_800) <= 2, "the sound decodes to \(samples) samples (9.6 s × 48 kHz = 460800)")
        // Order: each stretch begins with that file's first frame; the frame before each join is the previous file's.
        let firstColours: [(String, Int?)] = [("a", 0xC81E1E), ("c", 0x1E3CC8), ("p", 0xDCC81E), ("n", 0xC81EC8), ("l", nil)]
        for (k, (name, hex)) in firstColours.enumerated() {
            let c = colour(out, starts[k], x: 32, y: 24)
            t.check(hex.map { near(c, $0) } ?? dark(c), "frame \(starts[k]) is \(name)’s first frame: \(describe(c))")
            if k > 0 {
                let prev = firstColours[k - 1]
                let p = colour(out, starts[k] - 1, x: 32, y: 24)
                t.check(prev.1.map { near(p, $0) } ?? dark(p), "frame \(starts[k] - 1), just before the join, is still \(prev.0)’s: \(describe(p))")
            }
        }
        // Flashes: a, p, n on frame 3 of their stretch (3, 111, 141), c's (0.12 s at 25 fps) on the nearest 30 fps frame
        // (60 + 4), l's at 2.5 s (168 + 75…77).
        let expected = [3, 64, 111, 141, 243, 244, 245]
        let got = flashes(out)
        t.check(got == expected, "every flash on its frame (no frame lost or repeated at a join): \(got)")
        // Sync: each click within a frame of its flash.
        let heard = clicks(out)
        let pairs: [(String, Double)] = [("a", 0.1), ("c", 2.0 + 0.12), ("p", 3.6 + 0.1), ("l", 5.6 + 2.5)]
        t.check(heard.count == 4, "four clicks (n has no sound): \(heard.map(f))")
        for (i, (name, time)) in pairs.enumerated() where i < heard.count {
            let flash = Double(expected[[0, 1, 2, 4][i]]) / 30
            t.check(abs(heard[i] - time) < 0.002 && abs(heard[i] - flash) <= 1.0 / 30 + 0.001,
                    "\(name): click at \(f(heard[i])) s (expected \(f(time))), flash at \(f(flash)) s, \(String(format: "%.1f", abs(heard[i] - flash) * 1000)) ms apart")
        }
        // n (no sound) is silent; l's sound keeps its 0.5 s start.
        let x = MediaMeasure.pcm(out, rate: 48_000, channels: 1, fileClock: true)
        let nQuiet = x.count > Int(5.6 * 48_000) ? x[Int(4.62 * 48_000)..<Int(5.58 * 48_000)].map { abs(Int($0)) }.max() ?? 0 : 99_999
        t.check(nQuiet < 40, "n’s second is silence: peak \(nQuiet)")
        let lLead = x.count > Int(6.1 * 48_000) ? x[Int(5.62 * 48_000)..<Int(6.08 * 48_000)].map { abs(Int($0)) }.max() ?? 0 : 99_999
        let lHum = x.count > Int(6.3 * 48_000) ? x[Int(6.15 * 48_000)..<Int(6.3 * 48_000)].map { abs(Int($0)) }.max() ?? 0 : 0
        t.check(lLead < 40 && lHum > 800, "l’s sound starts 0.5 s into its stretch, as in the file: peak \(lLead) before, \(lHum) after")
        // Letterboxing: c (square) pillarboxed to 360×360 at x 140; p upright 202×360 at x 218 with its white band on top;
        // n (4:3) 480×360 at x 80. In a 64×36 thumbnail: 10 pixels per thumbnail pixel.
        let cL = colour(out, 61, x: 5, y: 18), cM = colour(out, 61, x: 32, y: 18), cR = colour(out, 61, x: 58, y: 18)
        t.check(dark(cL) && near(cM, 0x1E3CC8) && dark(cR), "c is pillarboxed, not stretched: \(describe(cL)) \(describe(cM)) \(describe(cR))")
        let pTop = colour(out, 109, x: 32, y: 2), pLow = colour(out, 109, x: 32, y: 30), pSide = colour(out, 109, x: 10, y: 18)
        t.check(near(pTop, 0xFFFFFF) && near(pLow, 0xDCC81E) && dark(pSide), "p is upright (white band on top) and pillarboxed: "
                + "top \(describe(pTop)), low \(describe(pLow)), side \(describe(pSide))")
        let nL = colour(out, 139, x: 4, y: 18), nM = colour(out, 139, x: 10, y: 18), nR = colour(out, 139, x: 59, y: 18)
        t.check(dark(nL) && near(nM, 0xC81EC8) && dark(nR), "n (4:3) is pillarboxed at 480×360: \(describe(nL)) \(describe(nM)) \(describe(nR))")
        t.check(MediaMerge.fitted(CGSize(width: 360, height: 640), into: 640, 360) == (202, 360)
                && MediaMerge.fitted(CGSize(width: 480, height: 480), into: 640, 360) == (360, 360)
                && MediaMerge.fitted(CGSize(width: 642, height: 361), into: 642, 360) == (642, 360), "fit sizes: 202×360, 360×360, a 1-pixel rounding fills")
        t.check(!seen.isEmpty && seen.allSatisfy { (0...1).contains($0) } && (seen.max() ?? 0) > 0.9 && zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 },
                "progress: \(seen.count) reports, rising from \(f(seen.first ?? -1)) to \(f(seen.max() ?? -1))")
    }

    /// c then a: the order is the given one, and the first file decides the size, the rate and the container.
    private static func reversed(_ t: Checker, _ dir: URL) {
        func u(_ n: String) -> URL { dir.appendingPathComponent(n) }
        guard let out = merge(t, "merge c a", [u("c.mkv"), u("a.mp4")]) else { return }
        let r = try? MediaSource.load(out)
        t.check(out.lastPathComponent == "c merged.mkv" && r?.pixelSize == CGSize(width: 480, height: 480) && r?.fps == 25 && r?.channels == 2,
                "c + a: “c merged.mkv”, 480×480 at 25 fps, stereo (a is): \(out.lastPathComponent) \(r?.pixelSize ?? .zero) \(r?.fps ?? 0)")
        let frames = MediaMeasure.frameTimes(out).count
        t.check(frames == 90, "40 + 2 s × 25 = 90 frames: \(frames)")
        let first = colour(out, 0, x: 32, y: 18, w: 64, h: 64), join = colour(out, 40, x: 32, y: 32, w: 64, h: 64)
        let top = colour(out, 40, x: 32, y: 6, w: 64, h: 64), before = colour(out, 39, x: 32, y: 32, w: 64, h: 64)
        // a (16:9) in 480×480: 480×270 at y 104, so rows 0–103 of 480 are black (0–13 of 64).
        t.check(near(first, 0x1E3CC8) && near(before, 0x1E3CC8) && near(join, 0xC81E1E) && dark(top),
                "blue first, blue up to the join, then red letterboxed: \(describe(first)) \(describe(before)) \(describe(join)) top \(describe(top))")
        // 30 → 25 fps keeps, for each 25 fps frame, the 30 fps frame nearest it: a's frames 3 (0.1 s, the flash) and 4
        // (0.133 s) both fall on 0.12 s, and 4 is nearer, so a's one-frame flash is one of the frames the change of rate
        // drops. Its click still lands at 1.6 + 0.1 s.
        let heard = clicks(out)
        t.check(flashes(out) == [3] && heard.count == 2 && abs(heard[0] - 0.12) < 0.002 && abs((heard.last ?? 0) - 1.7) < 0.002,
                "c’s flash on frame 3, clicks at \(heard.map(f)) (0.12 and 1.6 + 0.1)")
    }

    /// a + b and c + c2 share every parameter: the pictures are copied packet for packet.
    private static func copyPath(_ t: Checker, _ dir: URL) {
        func u(_ n: String) -> URL { dir.appendingPathComponent(n) }
        guard let copied = merge(t, "copy a b", [u("a.mp4"), u("b.mp4")]) else { return }
        let method = MediaMerge.lastMethod
        t.check(method == .copy && copied.lastPathComponent == "a merged 2.mp4",
                "a + b take the lossless path (\(method?.rawValue ?? "nil") \(MediaMerge.lastCopyRefusal ?? "")), and “a merged.mp4” isn’t overwritten: \(copied.lastPathComponent)")
        guard let encoded = merge(t, "re-encode a b", [u("a.mp4"), u("b.mp4")], allowCopy: false) else { return }
        t.check(MediaMerge.lastMethod == .reencode && encoded.lastPathComponent == "a merged 3.mp4", "with the fast path off it re-encodes: \(encoded.lastPathComponent)")
        let same = packets(copied) == packets(u("a.mp4")) + packets(u("b.mp4"))
        t.check(same && packets(copied).count == 120, "the copy’s picture packets are a’s then b’s, byte for byte (\(packets(copied).count))")
        let hashes = frameHashes(copied)
        t.check(hashes.count == 120 && hashes == frameHashes(u("a.mp4")) + frameHashes(u("b.mp4")), "every decoded frame is identical (\(hashes.count) MD5s)")
        t.check(frameHashes(encoded).count == 120 && frameHashes(encoded) != hashes, "the re-encode also has 120 frames, but not the same pixels")
        // Speed, on 2 × 10 s of 1280×720. The copy's own cost is mostly encoding the sound once more; how much faster it
        // is depends on what else the Mac is doing (measured 0.68 s against 1.37 s, and 1.16 s against 1.77 s under load).
        var start = Date()
        let fast = merge(t, "copy s1 s2", [u("s1.mp4"), u("s2.mp4")])
        let copyTime = Date().timeIntervalSince(start), fastMethod = MediaMerge.lastMethod
        start = Date()
        let slow = merge(t, "re-encode s1 s2", [u("s1.mp4"), u("s2.mp4")], allowCopy: false)
        let encodeTime = Date().timeIntervalSince(start)
        t.check(fast != nil && slow != nil && fastMethod == .copy && copyTime < encodeTime && MediaKit.videoPacketCount(fast!) == 600,
                "2 × 10 s of 720p: copying took \(String(format: "%.2f", copyTime)) s (600 frames), re-encoding \(String(format: "%.2f", encodeTime)) s")
        for o in [fast, slow].compactMap({ $0 }) { try? FileManager.default.removeItem(at: o) }
        let times = MediaMeasure.frameTimes(copied)
        t.check(times.count == 120 && abs((times.last ?? 0) - 119.0 / 30) < 0.001 && abs((times.first ?? 1)) < 0.001,
                "copied frames run 0 … 3.9667 s with no gap at the join: \(f(times.first ?? -1)) … \(f(times.last ?? -1))")
        let heard = clicks(copied), seen = flashes(copied)
        t.check(seen == [3, 63] && heard.count == 2 && abs((heard.last ?? 0) - 2.1) < 0.002 && abs((heard.first ?? 0) - 0.1) < 0.002,
                "b’s flash on frame 63 and its click at \(f(heard.last ?? -1)) s (2.1): in sync after the join")
        let samples = MediaMeasure.pcm(copied, rate: 48_000, channels: 1).count
        t.check(abs(samples - 192_000) <= 2, "the copy’s sound is 4 s: \(samples) samples")
        // Matroska: c + c2 copy too.
        guard let mkv = merge(t, "copy c c2", [u("c.mkv"), u("c2.mkv")]) else { return }
        t.check(MediaMerge.lastMethod == .copy && Ext.of(mkv) == "mkv" && packets(mkv) == packets(u("c.mkv")) + packets(u("c2.mkv"))
                && flashes(mkv) == [3, 43] && clicks(mkv).count == 2 && abs((clicks(mkv).last ?? 0) - 1.72) < 0.002,
                "c + c2 (mkv) copy packet for packet, flash and click in sync after the join: \(mkv.lastPathComponent) \(flashes(mkv)) \(clicks(mkv).map(f))")
        // Different parameters say why they aren't copied.
        guard let i1 = try? MediaMerge.inspect(u("a.mp4"), ff: FFmpeg.shared!), let i2 = try? MediaMerge.inspect(u("p.mp4"), ff: FFmpeg.shared!) else { return }
        t.check(MediaMerge.copyRefusal([i1, i2])?.contains("p.mp4") == true, "a + p aren’t copied: \(MediaMerge.copyRefusal([i1, i2]) ?? "nil")")
    }

    /// clip.mp4 + odd.mkv + sample.wmv: the command-line example (no sound in odd.mkv, a late first frame in sample.wmv).
    private static func fixturesMerge(_ t: Checker, _ dir: URL) {
        func u(_ n: String) -> URL { dir.appendingPathComponent(n) }
        guard let out = merge(t, "merge clip odd sample.wmv", [u("clip.mp4"), u("odd.mkv"), u("sample.wmv")]) else { return }
        let r = try? MediaSource.load(out)
        let frames = MediaKit.videoPacketCount(out) ?? 0
        t.check(out.lastPathComponent == "clip merged.mp4" && r?.pixelSize == CGSize(width: 1280, height: 720) && frames == 331 && r?.channels == 1,
                "clip + odd + sample.wmv: 1280×720, 120 + 90 + 121 = \(frames) frames, mono (every file with sound is): \(r?.channels ?? 0) ch")
        let x = MediaMeasure.pcm(out, rate: 48_000, channels: 1)
        t.check(abs(x.count - 529_600) <= 2, "sound as long as the picture (331 / 30 s): \(x.count) samples")
        let quiet = x.count > Int(6.9 * 48_000) ? x[Int(4.05 * 48_000)..<Int(6.95 * 48_000)].map { abs(Int($0)) }.max() ?? 0 : 99_999
        t.check(quiet < 40, "odd.mkv (no sound) is silence: peak \(quiet)")
        let oddFrame = colour(out, 120, x: 32, y: 18), oddSource = colour(u("odd.mkv"), 0, x: 32, y: 18)
        if let a = oddFrame, let b = oddSource {
            t.check(abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) < 40, "frame 120 is odd.mkv’s first frame: \(describe(a)) vs \(describe(b))")
        }
    }

    // MARK: Sounds

    private static func sounds(_ t: Checker, _ dir: URL) {
        func u(_ n: String) -> URL { dir.appendingPathComponent(n) }
        guard let out = merge(t, "merge tone sample.wma gen.mp3", [u("tone.wav"), u("sample.wma"), u("gen.mp3")]) else { return }
        let r = try? MediaSource.load(out)
        t.check(out.lastPathComponent == "tone merged.wav" && MediaMerge.lastMethod == .sound && r?.audioCodec == "pcm_s16le"
                && r?.sampleRate == 44_100 && r?.channels == 1 && r?.hasVideo == false,
                "tone + wma + mp3: “tone merged.wav”, 16-bit 44.1 kHz mono like tone.wav: \(r?.audioCodec ?? "?") \(r?.sampleRate ?? 0) \(r?.channels ?? 0)")
        let parts = ["tone.wav", "sample.wma", "gen.mp3"].map { MediaMeasure.pcm(u($0)) }
        let joined = parts.flatMap { $0 }, got = MediaMeasure.pcm(out)
        let diff = got.count == joined.count ? zip(got, joined).map { abs(Int($0) - Int($1)) }.max() ?? 0 : 99_999
        t.check(got.count == joined.count && diff <= 1,
                "sample for sample: \(got.count) samples = \(parts.map(\.count).map(String.init).joined(separator: " + ")), largest difference \(diff)")
        // A lossy first file: MP3 at its own rate, stereo because st.wav is.
        guard let mp3 = merge(t, "merge gen.mp3 st.wav", [u("gen.mp3"), u("st.wav")]) else { return }
        let m = try? MediaSource.load(mp3)
        let length = MediaMeasure.pcm(mp3, channels: 2).count / 2
        let wanted = 66_150 + 44_100
        t.check(mp3.lastPathComponent == "gen merged.mp3" && m?.audioCodec == "mp3" && m?.sampleRate == 44_100 && m?.channels == 2
                && abs(length - wanted) <= 1_152, "gen + st: “gen merged.mp3”, 44.1 kHz stereo, \(length) samples (1.5 s + 1 s = \(wanted))")
    }

    // MARK: Errors and the command line

    private static func errors(_ t: Checker, _ dir: URL) {
        func u(_ n: String) -> URL { dir.appendingPathComponent(n) }
        let before = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("merged") }.sorted()) ?? []
        t.throwsError("one file", containing: "two or more") { _ = try MediaMerge.merge([u("a.mp4")]) { _ in } }
        t.throwsError("a video and a sound", containing: "a.mp4 is a video and tone.wav is sound only") {
            _ = try MediaMerge.merge([u("a.mp4"), u("tone.wav")]) { _ in }
        }
        try? Data("not a video".utf8).write(to: u("junk.mp4"))
        t.throwsError("a file that isn’t media", containing: "junk.mp4 can’t be read as video or audio") {
            _ = try MediaMerge.merge([u("a.mp4"), u("junk.mp4")]) { _ in }
        }
        t.throwsError("a missing file", containing: "Couldn’t read gone.mp4") { _ = try MediaMerge.merge([u("a.mp4"), u("gone.mp4")]) { _ in } }
        try? FileManager.default.removeItem(at: u("junk.mp4"))
        // The command line runs the same command and refuses with the same sentence.
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        if let r = try? ProcessRunner.run(binary, ["--tool", "merge", u("a.mp4").path, u("tone.wav").path]) {
            t.check(r.status == 1 && r.stderr.contains("Merge joins videos with videos") && r.stdout.isEmpty,
                    "--tool merge a.mp4 tone.wav: exit \(r.status), “\(r.stderr.split(separator: "\n").last ?? "")”")
        } else { t.check(false, "couldn’t run \(binary.path)") }
        if let r = try? ProcessRunner.run(binary, ["--tool", "merge", u("n.mp4").path, u("a.mp4").path]) {
            let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            t.check(r.status == 0 && path.hasSuffix("/n merged.mp4") && FileManager.default.fileExists(atPath: path),
                    "--tool merge n.mp4 a.mp4 writes one file: \(URL(fileURLWithPath: path).lastPathComponent)")
            if let s = try? MediaSource.load(URL(fileURLWithPath: path)) {
                t.check(s.pixelSize == CGSize(width: 320, height: 240) && s.channels == 2 && MediaMeasure.frameTimes(URL(fileURLWithPath: path)).count == 90,
                        "n first: 320×240, 30 + 60 frames, stereo sound (silence, then a’s)")
            }
            try? FileManager.default.removeItem(atPath: path)
        }
        let after = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("merged") }.sorted()) ?? []
        t.check(after == before, "refused merges leave nothing behind")
    }

    // MARK: Found in review

    private static func run(_ args: [String]) -> Bool {
        guard let ff = FFmpeg.shared else { return false }
        return (try? ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + args))?.status == 0
    }

    /// Clips cut with `-c copy` between key frames keep the frames before the cut, marked to be discarded (an edit
    /// list hides them). Copied into the middle of a merge, the second clip's hidden frames showed at the join (139
    /// frames instead of 113, times running backwards), so such clips are re-encoded.
    private static func preroll(_ t: Checker, _ dir: URL) {
        func u(_ n: String) -> URL { dir.appendingPathComponent(n) }
        guard run(["-f", "lavfi", "-i", "testsrc=s=320x180:r=30:d=6", "-f", "lavfi", "-i", "sine=f=440:sample_rate=48000:d=6",
                   "-c:v", "libx264", "-preset", "veryfast", "-g", "90", "-bf", "2", "-pix_fmt", "yuv420p", "-c:a", "aac", u("long.mp4").path]),
              run(["-ss", "1", "-i", u("long.mp4").path, "-t", "2", "-c", "copy", u("e1.mp4").path]),
              run(["-ss", "4", "-i", u("long.mp4").path, "-t", "1.5", "-c", "copy", u("e2.mp4").path]),
              let ff = FFmpeg.shared, let i1 = try? MediaMerge.inspect(u("e1.mp4"), ff: ff), let i2 = try? MediaMerge.inspect(u("e2.mp4"), ff: ff)
        else { t.check(false, "couldn’t make the copy-cut clips"); return }
        let hashes = [u("e1.mp4"), u("e2.mp4")].map(MediaMeasure.sha256)
        t.check(i1.scan.videoPreroll > 0 && i2.scan.videoPreroll > 0, "the copy-cut clips have hidden frames before their start: "
                + "\(i1.scan.videoPreroll) and \(i2.scan.videoPreroll) of \(i1.scan.videoPackets) and \(i2.scan.videoPackets) packets")
        // Each stretch is the clip's picture on its own clock, rounded to 30 fps frames.
        let want = [i1, i2].map { Int((($0.scan.videoEnd ?? 0) * 30).rounded()) }
        guard let out = merge(t, "merge e1 e2", [u("e1.mp4"), u("e2.mp4")]) else { return }
        t.check(MediaMerge.lastMethod == .reencode && (MediaMerge.lastCopyRefusal ?? "").contains("e1.mp4"),
                "copy-cut clips aren’t copied: \(MediaMerge.lastMethod?.rawValue ?? "nil") (\(MediaMerge.lastCopyRefusal ?? ""))")
        let times = MediaMeasure.frameTimes(out)
        let grid = times.enumerated().map { abs($0.element - Double($0.offset) / 30) }.max() ?? 1
        t.check(times.count == want.reduce(0, +) && grid < 0.001,
                "\(times.count) frames (\(want.map(String.init).joined(separator: " + "))), in order on the 30 fps grid (off by \(f(grid)) s at most)")
        // The second stretch starts with e2's first shown frame, not one of its hidden ones.
        let e2First = MediaMeasure.frameRGB(u("e2.mp4"), index: 0, width: 64, height: 36)
        let join = MediaMeasure.frameRGB(out, index: want[0], width: 64, height: 36)
        let before = MediaMeasure.frameRGB(out, index: want[0] - 1, width: 64, height: 36)
        if let a = e2First, let b = join, let c = before {
            t.check(MediaMeasure.psnr(a, b) > 30 && MediaMeasure.psnr(a, c) < 30,
                    "frame \(want[0]) is e2’s first shown frame (PSNR \(String(format: "%.1f", MediaMeasure.psnr(a, b))) dB), the one before isn’t")
        } else { t.check(false, "couldn’t read the frames at the join") }
        t.check([u("e1.mp4"), u("e2.mp4")].map(MediaMeasure.sha256) == hashes, "e1.mp4 and e2.mp4 unchanged")
        try? FileManager.default.removeItem(at: out)
    }

    /// A still picture with a song (one frame, seconds of sound, as made from a cover and an MP3): the stretch runs to
    /// the end of the sound with the last frame held. Cut to its picture, 3.5 s of sound became 0.08 s.
    private static func longSound(_ t: Checker, _ dir: URL) {
        func u(_ n: String) -> URL { dir.appendingPathComponent(n) }
        func still(_ name: String, _ colour: String, _ hz: Int, _ seconds: Double) -> Bool {
            run(["-f", "lavfi", "-i", "color=c=\(colour):s=640x360:r=25:d=0.04", "-frames:v", "1", "-c:v", "libx264", "-tune", "stillimage",
                 "-pix_fmt", "yuv420p", u(name + "-v.mp4").path])
                && run(["-f", "lavfi", "-i", "sine=f=\(hz):sample_rate=48000:d=\(seconds)", "-c:a", "aac", u(name + "-a.m4a").path])
                && run(["-i", u(name + "-v.mp4").path, "-i", u(name + "-a.m4a").path, "-map", "0", "-map", "1", "-c", "copy", u(name + ".mp4").path])
        }
        guard still("song1", "0xC81E1E", 440, 2), still("song2", "0x1E3CC8", 880, 1.5) else { t.check(false, "couldn’t make the still clips"); return }
        func loud(_ x: [Int16], _ from: Double, _ to: Double) -> Int {
            let a = Int(from * 48_000), b = Int(to * 48_000)
            return x.count > b ? x[a..<b].map { abs(Int($0)) }.max() ?? 0 : 0
        }
        for allowCopy in [true, false] {
            guard let out = merge(t, "merge song1 song2", [u("song1.mp4"), u("song2.mp4")], allowCopy: allowCopy) else { return }
            let method = MediaMerge.lastMethod?.rawValue ?? "nil"
            let x = MediaMeasure.pcm(out, rate: 48_000, channels: 1)
            let seconds = Double(x.count) / 48_000
            t.check(abs(seconds - 3.5) < 0.05 && loud(x, 0.1, 1.9) > 1000 && loud(x, 2.1, 3.4) > 1000,
                    "\(method): both songs’ sound kept whole, 2 s + 1.5 s: \(f(seconds)) s, peaks \(loud(x, 0.1, 1.9)) and \(loud(x, 2.1, 3.4))")
            if !allowCopy {
                let times = MediaMeasure.frameTimes(out)
                let red = colour(out, 40, x: 32, y: 18), blue = colour(out, (times.count + 55) / 2, x: 32, y: 18)
                t.check(abs(Double(times.count) / 25 - seconds) < 0.1 && near(red, 0xC81E1E) && near(blue, 0x1E3CC8),
                        "re-encoded: the picture runs with the sound (\(times.count) frames at 25 fps), each still held: \(describe(red)) \(describe(blue))")
            }
            try? FileManager.default.removeItem(at: out)
        }
        // With a clip that has a picture all along: song1's stretch is 2 s, then a's 2 s.
        guard let mixed = merge(t, "merge song1 a", [u("song1.mp4"), u("a.mp4")]) else { return }
        let x = MediaMeasure.pcm(mixed, rate: 48_000, channels: 1, fileClock: true)
        let clicked = clicks(mixed)
        t.check(abs(Double(x.count) / 48_000 - 4.0) < 0.05 && loud(x, 0.5, 1.9) > 1000 && clicked.count == 1 && abs((clicked.first ?? 0) - 2.1) < 0.03,
                "song1 + a: 2 s of song, then a with its click at \(clicked.map(f)) (2 + 0.1)")
        try? FileManager.default.removeItem(at: mixed)
    }

    /// The first file's folder is read-only: the message says so (it used to say "Convert the file it names first").
    private static func readOnlyFolder(_ t: Checker, _ dir: URL) {
        let ro = dir.appendingPathComponent("locked")
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: ro, withIntermediateDirectories: true)) != nil,
              (try? fm.copyItem(at: dir.appendingPathComponent("a.mp4"), to: ro.appendingPathComponent("a.mp4"))) != nil,
              (try? fm.copyItem(at: dir.appendingPathComponent("n.mp4"), to: ro.appendingPathComponent("n.mp4"))) != nil,
              (try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)) != nil
        else { t.check(false, "couldn’t make a read-only folder"); return }
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path)
            try? fm.removeItem(at: ro)
        }
        do {
            _ = try MediaMerge.merge([ro.appendingPathComponent("a.mp4"), ro.appendingPathComponent("n.mp4")]) { _ in }
            t.check(false, "a read-only folder: no error")
        } catch {
            let text = error.localizedDescription
            t.check(text.contains("locked") && text.contains("folder you can write to") && !text.contains("Convert"), "a read-only folder: “\(text)”")
        }
        t.check(((try? fm.contentsOfDirectory(atPath: ro.path)) ?? []).sorted() == ["a.mp4", "n.mp4"], "nothing written in the read-only folder")
    }

    /// `--tool` reaches Merge's own refusal (above), but a tool that runs per file still isn't run on a file it
    /// doesn't apply to (Visualize on a video wrote “a visualized.mp4”), and Channels still runs on each of several files.
    private static func commandLineScope(_ t: Checker, _ dir: URL) {
        func u(_ n: String) -> URL { dir.appendingPathComponent(n) }
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        if let r = try? ProcessRunner.run(binary, ["--tool", "visualize", u("a.mp4").path]) {
            let made = FileManager.default.fileExists(atPath: u("a visualized.mp4").path)
            t.check(r.status == 2 && !made, "--tool visualize a.mp4: exit \(r.status), nothing written (\(made ? "wrote a visualized.mp4" : "none"))")
            try? FileManager.default.removeItem(at: u("a visualized.mp4"))
        } else { t.check(false, "couldn’t run \(binary.path)") }
        if let r = try? ProcessRunner.run(binary, ["--tool", "channels", "--opt", "layout=mono", u("st.wav").path, u("a.mp4").path]) {
            let outs = r.stdout.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            t.check(r.status == 0 && outs.map(\.lastPathComponent) == ["st mono.wav", "a mono.mp4"],
                    "--tool channels on two files runs on each: exit \(r.status), \(outs.map(\.lastPathComponent))")
            outs.forEach { try? FileManager.default.removeItem(at: $0) }
        } else { t.check(false, "couldn’t run \(binary.path)") }
    }
}
#endif
