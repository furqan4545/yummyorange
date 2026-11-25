#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import AVFoundation

/// `--selftest media-tools`: Bleep, Speed, Split, Channels and Visualize on the fixtures and on test signals made
/// here (a stereo file with 440 Hz on the left and 880 Hz on the right, and a short "song"), measured with ffmpeg:
/// - Bleep: edges within 2 ms of the ranges (exact samples for PCM), the tone only inside them, the file's own
///   samples everywhere else, silence that is digital zero, the video stream copied bit for bit, many ranges fast;
///   the Bleep window's drags, keys, fields, mode, result waveform, Save options, preview mute and snapshot.
/// - Speed: lengths and frame counts for 0.25× to 4×, pitch kept (or not), channels kept.
/// - Split: part counts, names and lengths; the parts add up to the source frame for frame and sample for sample
///   (the Split window and `at=` are tested by `--selftest media-split`).
/// - Channels: which tone ends up in which channel for every layout, video copied, choices per channel count (Merge,
///   which takes its place for several files, is tested by `--selftest media-merge`).
/// - Visualize: size, length, sound, colours of the page, the band, the drawing and its reflection, never blank.
/// Plus error messages for bad options, and the inputs unchanged.
enum MediaToolsTests {
    typealias Checker = MediaTestSupport.Checker

    static func run() -> String {
        let t = Checker("media-tools")
        guard FFmpeg.shared != nil else { return "OK media-tools: skipped, ffmpeg isn’t installed" }
        guard let fixtures = MediaTestSupport.fixturesFolder() else {
            return "FAIL media-tools: can’t find Tests/fixtures/features. Run from the project folder or set DW_FIXTURES."
        }
        let names = ["clip.mp4", "odd.mkv", "sample.avi", "sample.wmv", "tone.wav", "sample.wma"]
        let dir: URL
        do { dir = try MediaTestSupport.scratchCopy(of: names, from: fixtures) } catch {
            return "FAIL media-tools: couldn’t copy the fixtures: \(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
        guard makeSignals(dir) else { return "FAIL media-tools: couldn’t make the test signals with ffmpeg" }
        let generated = ["st.wav", "stv.mp4", "song.wav", "six.flac", "marks.wma"]
        let all = names + generated
        let before = Dictionary(uniqueKeysWithValues: all.map { ($0, MediaMeasure.sha256(url($0))) })

        commands(t)
        bleep(t, dir)
        bleepEditor(t, dir)
        bleepPreview(t, url("tone.wav"))
        speed(t, dir)
        split(t, dir)
        channels(t, dir)
        visualize(t, dir)
        lateSound(t, dir)
        oldContainers(t, dir)
        visualizeClock(t, dir)

        for name in all { t.check(MediaMeasure.sha256(url(name)) == before[name], "\(name) unchanged") }
        for name in names {
            t.check(MediaMeasure.sha256(fixtures.appendingPathComponent(name)) == before[name], "fixture \(name) unchanged")
        }
        return t.report
    }

    // MARK: Signals and measurements

    /// st.wav: 4 s stereo, 48 kHz, 440 Hz left, 880 Hz right (−6 dBFS). stv.mp4: clip.mp4's picture with that sound
    /// (AAC). song.wav: 3 s of drum, chord and hi-hat, for Visualize. six.flac: 3 s of 5.1.
    private static func makeSignals(_ dir: URL) -> Bool {
        guard let ff = FFmpeg.shared else { return false }
        func run(_ args: [String]) -> Bool {
            (try? ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + MediaTestSupport.h264(args)))?.status == 0
        }
        let p = dir.path + "/"
        return run(["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=4", "-f", "lavfi", "-i",
                    "sine=frequency=880:sample_rate=48000:duration=4", "-filter_complex",
                    "[0:a][1:a]join=inputs=2:channel_layout=stereo,volume=0.5[a]", "-map", "[a]", "-c:a", "pcm_s16le", p + "st.wav"])
            && run(["-i", p + "clip.mp4", "-i", p + "st.wav", "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "aac",
                    "-b:a", "192k", "-shortest", p + "stv.mp4"])
            && run(["-f", "lavfi", "-i", "aevalsrc='0.3*exp(-4*mod(t,0.5))*sin(2*PI*55*t*(1+exp(-30*mod(t,0.5))))"
                    + "+0.12*exp(-2*mod(t,0.25))*(sin(2*PI*261.6*t)+0.6*sin(2*PI*329.6*t)+0.5*sin(2*PI*392*t))':s=48000:d=3",
                    "-f", "lavfi", "-i", "anoisesrc=c=pink:a=0.05:d=3:r=48000:seed=11",
                    "-filter_complex", "[0][1]amix=inputs=2:normalize=0,pan=stereo|c0=c0|c1=c0[a]", "-map", "[a]",
                    "-c:a", "pcm_s16le", p + "song.wav"])
            && run(["-f", "lavfi", "-i", "anoisesrc=c=pink:a=0.1:d=3:r=44100:seed=7", "-f", "lavfi", "-i",
                    "aevalsrc='0.9*sin(2*PI*2000*t)*between(t,2,2.004)':s=44100:d=3", "-filter_complex",
                    "[0][1]amix=inputs=2:normalize=0[a]", "-map", "[a]", "-c:a", "wmav2", "-b:a", "128k", p + "marks.wma"])
            && run(["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=3", "-filter_complex",
                    "[0]asplit=6[a][b][c][d][e][f];[a][b][c][d][e][f]join=inputs=6:channel_layout=5.1(side)[o]",
                    "-map", "[o]", "-c:a", "flac", p + "six.flac"])
    }

    private static func f(_ v: Double) -> String { String(format: "%.3f", v) }

    /// One channel of interleaved samples.
    private static func channel(_ samples: [Int16], _ c: Int, of n: Int) -> [Int16] {
        stride(from: c, to: samples.count, by: n).map { samples[$0] }
    }

    /// The amplitude (0…1 of full scale) of `freq` in `x[from..<to]`, by the Goertzel algorithm.
    private static func amplitude(_ x: [Int16], rate: Double, freq: Double, from: Int, to: Int) -> Double {
        let a = max(0, from), b = min(x.count, to)
        guard b - a > 16 else { return 0 }
        let w = 2 * Double.pi * freq / rate, coeff = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for i in a..<b {
            let s0 = Double(x[i]) / 32768 + coeff * s1 - s2
            s2 = s1; s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return 2 * sqrt(max(0, power)) / Double(b - a)
    }

    /// The amplitude of `freq` in seconds `t0…t1` of channel `c`.
    private static func tone(_ x: [Int16], rate: Double, _ freq: Double, _ t0: Double, _ t1: Double) -> Double {
        amplitude(x, rate: rate, freq: freq, from: Int(t0 * rate), to: Int(t1 * rate))
    }

    /// The MD5 of a stream's packets (the same for a copied stream).
    private static func streamHash(_ url: URL, _ stream: String = "0:v:0") -> String? {
        guard let ff = FFmpeg.shared,
              let r = try? ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", url.path, "-map", stream,
                                                       "-c", "copy", "-f", "md5", "-"]), r.status == 0 else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The strongest of a few candidate frequencies.
    private static func dominant(_ x: [Int16], rate: Double, among freqs: [Double], _ t0: Double, _ t1: Double) -> Double {
        freqs.max { tone(x, rate: rate, $0, t0, t1) < tone(x, rate: rate, $1, t0, t1) } ?? 0
    }

    /// The longest stretch of 5 ms windows whose samples all stay under 1/500 of full scale.
    private static func longestSilence(_ x: [Int16], rate: Double) -> (start: Double, end: Double, length: Double) {
        let w = max(1, Int(rate * 0.005))
        var best = (0, 0), runStart: Int?
        for k in 0...(x.count / w) {
            let lo = k * w, hi = min(x.count, lo + w)
            let silent = hi > lo && x[lo..<hi].allSatisfy { abs(Int($0)) < 66 }
            if silent { if runStart == nil { runStart = lo } } else if let r = runStart {
                if lo - r > best.1 - best.0 { best = (r, lo) }
                runStart = nil
            }
        }
        let a = Double(best.0) / rate, b = Double(best.1) / rate
        return (a, b, b - a)
    }

    private static func remove(_ urls: [URL]) { for u in urls { try? FileManager.default.removeItem(at: u) } }

    // MARK: Commands

    private static func commands(_ t: Checker) {
        let cmds = MediaTools.commands
        t.check(cmds.map(\.id) == ["bleep", "speed", "split", "channels", "merge", "visualize"], "six tools: \(cmds.map(\.id))")
        // Merge runs at once on the whole selection (no “…”); the others ask or open a window, one file at a time.
        let perFile = cmds.filter { $0.id != "merge" }
        t.check(perFile.allSatisfy { $0.title.hasSuffix("…") && $0.wheel == .tools && !$0.combinesInputs }, "titles end in “…”, per file")
        t.check(MediaTools.commands[4].title == "Merge" && MediaTools.commands[4].combinesInputs, "Merge: no “…”, combines the files")
        let symbols = cmds.compactMap(\.symbol)
        t.check(symbols.count == 6 && symbols.allSatisfy { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil },
                "every symbol exists: \(symbols)")
        t.check(symbols == ["waveform.badge.exclamationmark", "gauge.with.dots.needle.67percent", "rectangle.split.3x1", "headphones",
                            "arrow.triangle.merge", "music.note.tv"], "the preferred symbols are used on this Mac")
        let video = [URL(fileURLWithPath: "/x/a.mp4")], audio = [URL(fileURLWithPath: "/x/a.wav")], pdf = [URL(fileURLWithPath: "/x/a.pdf")]
        t.check(cmds.prefix(4).allSatisfy { $0.applies(video) && $0.applies(audio) && !$0.applies(pdf) }, "Bleep, Speed, Split, Channels: video and audio")
        t.check(MediaTools.visualize.applies(audio) && !MediaTools.visualize.applies(video) && !MediaTools.visualize.applies(pdf), "Visualize: audio only")
        let windows = cmds.filter { $0.present != nil }.map(\.id), asking = cmds.filter { $0.ask != nil }.map(\.id)
        t.check(windows == ["bleep", "split"] && asking == ["speed", "channels", "visualize"] && cmds.allSatisfy { $0.run != nil },
                "Bleep and Split open a window; Speed, Channels and Visualize ask; all run from options")
    }

    // MARK: Bleep

    private static func bleep(_ t: Checker, _ dir: URL) {
        let st = dir.appendingPathComponent("st.wav")
        let source = MediaMeasure.pcm(st)
        let rate = 48_000.0
        let ranges = [MediaRange(start: 1, end: 1.5), MediaRange(start: 2.25, end: 3)]
        do {
            let out = try MediaBleep.bleep(st, options: ["ranges": "1-1.5, 2.25-3"]) { _ in }
            defer { remove([out]) }
            let result = try MediaSource.load(out)
            let got = MediaMeasure.pcm(out)
            t.check(out.lastPathComponent == "st bleeped.wav" && result.audioCodec == "pcm_s16le" && result.channels == 2 && got.count == source.count,
                    "bleep st.wav: \(out.lastPathComponent), \(result.audioCodec ?? "?"), \(result.channels ?? 0) channels, \(got.count / 2) samples")
            for c in 0..<2 {
                let a = channel(source, c, of: 2), b = channel(got, c, of: 2)
                guard a.count == b.count else { continue }
                // Every changed sample lies in a range; each range's edges are where the changes start and stop.
                let changed = a.indices.filter { a[$0] != b[$0] }
                let outside = changed.filter { i in !ranges.contains { $0.contains(Double(i) / rate) } }
                t.check(outside.isEmpty, "channel \(c): no sample outside the ranges changed (\(outside.count))")
                for r in ranges {
                    let inR = changed.filter { r.contains(Double($0) / rate) }
                    let first = Double(inR.first ?? 0) / rate, last = Double((inR.last ?? 0) + 1) / rate
                    t.check(abs(first - r.start) <= 0.002 && abs(last - r.end) <= 0.002,
                            "channel \(c) \(f(r.start))–\(f(r.end)): the tone starts at \(f(first)) s and stops at \(f(last)) s (within 2 ms)")
                    // The samples are the tone itself: 0.3 × sin(2π·1000·(t − start)).
                    let i0 = Int(r.start * rate)
                    var worst = 0.0
                    for i in i0..<(i0 + 2000) {
                        let expected: Double = 0.3 * sin(2 * Double.pi * 1000 * (Double(i) / rate - r.start))
                        worst = max(worst, abs(Double(b[i]) / 32768 - expected))
                    }
                    t.check(worst < 0.0002, "channel \(c) \(f(r.start)) s: the samples are the 1 kHz tone at −10.5 dBFS (worst error \(String(format: "%.5f", worst)))")
                }
                let inside = ranges.map { tone(b, rate: rate, 1000, $0.start + 0.05, $0.end - 0.05) }
                let gaps = [(0.1, 0.9), (1.6, 2.15), (3.1, 3.9)].map { tone(b, rate: rate, 1000, $0.0, $0.1) }
                t.check(inside.allSatisfy { $0 > 0.25 } && gaps.allSatisfy { $0 < 0.005 },
                        "channel \(c): 1 kHz inside the ranges (\(inside.map(f))) and not outside (\(gaps.map(f)))")
                let own = c == 0 ? 440.0 : 880.0
                t.check(ranges.allSatisfy { tone(b, rate: rate, own, $0.start + 0.05, $0.end - 0.05) < 0.005 },
                        "channel \(c): its own \(Int(own)) Hz is gone inside the ranges")
            }
            let again = try MediaBleep.bleep(st, options: ["ranges": "0.5-1"]) { _ in }
            t.check(again.lastPathComponent == "st bleeped 2.wav", "a second bleep is named \(again.lastPathComponent)")
            remove([again])
        } catch { t.check(false, "bleep st.wav: \(error.localizedDescription)") }

        // Silence: digital zero inside, untouched outside.
        do {
            let out = try MediaBleep.bleep(st, options: ["ranges": "1-1.5", "mode": "silence"]) { _ in }
            defer { remove([out]) }
            let got = MediaMeasure.pcm(out)
            let zeroInside = (Int(1.0 * rate) * 2..<Int(1.5 * rate) * 2).allSatisfy { got[$0] == 0 }
            let sameOutside = got.count == source.count && (0..<Int(1.0 * rate) * 2).allSatisfy { got[$0] == source[$0] }
                && (Int(1.5 * rate) * 2..<source.count).allSatisfy { got[$0] == source[$0] }
            t.check(zeroInside && sameOutside, "silence: samples 48000…71999 are 0, every other sample is the source’s")
        } catch { t.check(false, "bleep silence: \(error.localizedDescription)") }

        // Video: the picture is copied bit for bit; the AAC sound has the tone within 10 ms of the edges.
        do {
            let stv = dir.appendingPathComponent("stv.mp4")
            let out = try MediaBleep.bleep(stv, options: ["ranges": "1-2"]) { _ in }
            defer { remove([out]) }
            let result = try MediaSource.load(out)
            t.check(out.lastPathComponent == "stv bleeped.mp4" && result.videoCodec == "h264" && result.audioCodec == "aac" && result.channels == 2,
                    "bleep stv.mp4: \(out.lastPathComponent), \(result.videoCodec ?? "?") + \(result.audioCodec ?? "?")")
            let ha = streamHash(stv), hb = streamHash(out)
            t.check(ha != nil && ha == hb && MediaKit.videoPacketCount(out) == 120, "the video stream is copied unchanged (\(hb ?? "no hash"))")
            let left = channel(MediaMeasure.pcm(out, rate: 48_000), 0, of: 2)
            let seconds = Double(left.count) / rate
            t.check(abs(seconds - 4) < 0.03, "the sound is still 4 s long (\(f(seconds)) s)")
            // 1 kHz in 5 ms steps: the first and last step above half the tone's level.
            let steps = stride(from: 0.8, to: 2.2, by: 0.005).map { ($0, tone(left, rate: rate, 1000, $0, $0 + 0.005)) }
            let on = steps.filter { $0.1 > 0.15 }
            if let a = on.first?.0, let b = on.last.map({ $0.0 + 0.005 }) {
                t.check(abs(a - 1) <= 0.01 && abs(b - 2) <= 0.01, "AAC: the tone runs \(f(a))–\(f(b)) s (within 10 ms of 1–2 s)")
            } else { t.check(false, "AAC: the tone is there") }
        } catch { t.check(false, "bleep video: \(error.localizedDescription)") }

        // Other containers keep their format; their video is copied; the silence is half a second long.
        for (name, ext) in [("sample.wmv", "wmv"), ("sample.avi", "avi"), ("sample.wma", "wma")] {
            let src = dir.appendingPathComponent(name)
            do {
                let out = try MediaBleep.bleep(src, options: ["ranges": "1-1.5", "mode": "silence"]) { _ in }
                defer { remove([out]) }
                let s = try MediaSource.load(src), r = try MediaSource.load(out)
                let sameVideo = !s.hasVideo || streamHash(src) == streamHash(out)
                let quiet = longestSilence(MediaMeasure.pcm(out, rate: 8000, channels: 1), rate: 8000)
                t.check(Ext.of(out) == ext && r.audioCodec == s.audioCodec && sameVideo && abs(quiet.length - 0.5) < 0.05 && abs(r.duration - s.duration) < 0.06,
                        "bleep \(name): \(ext), \(r.audioCodec ?? "?"), video \(s.hasVideo ? "copied" : "none"), silent for \(f(quiet.length)) s, \(f(r.duration)) s long")
            } catch { t.check(false, "bleep \(name): \(error.localizedDescription)") }
        }
        // WMA: ffmpeg's decoder puts the first sample at 0.092 s and every encode moves the sound 46 ms; the bleep must
        // still cover what the waveform (on the file's clock, like the player) showed at 1.0–1.5 s. A click at 2.0 s
        // tells how far the whole sound moved.
        do {
            let marks = dir.appendingPathComponent("marks.wma")
            let src = MediaMeasure.pcm(marks, rate: 44_100, channels: 1, fileClock: true)
            let out = try MediaBleep.bleep(marks, options: ["ranges": "1-1.5", "mode": "silence"]) { _ in }
            defer { remove([out]) }
            let got = MediaMeasure.pcm(out, rate: 44_100, channels: 1, fileClock: true)
            let click = { (x: [Int16]) in Double(x.firstIndex { abs(Int($0)) > 20_000 } ?? 0) / 44_100 }
            let lag = click(got) - click(src)
            let quiet = longestSilence(got, rate: 44_100)
            // WMA smears each edge over about one 46 ms block, so the silence is judged by its middle and length.
            let a = quiet.start - lag, b = quiet.end - lag, middle = (a + b) / 2
            t.check(click(src) > 1.9 && abs(middle - 1.25) <= 0.015 && b - a > 0.4 && b - a <= 0.5,
                    "WMA: the silence sits on 1.0–1.5 s of the source’s sound (silent \(f(a))–\(f(b)) s, middle \(f(middle)) s; the encode moved everything \(Int((lag * 1000).rounded())) ms)")
        } catch { t.check(false, "bleep marks.wma: \(error.localizedDescription)") }

        // Many ranges stay fast and exact (the nested ifs are a binary search).
        do {
            let many = (0..<300).map { MediaRange(start: 0.1 + Double($0) * 0.0125, end: 0.1 + Double($0) * 0.0125 + 0.005) }
            let start = Date()
            let out = try MediaBleep.bleep(st, options: ["ranges": MediaBleep.rangesOption(many), "mode": "silence"]) { _ in }
            let elapsed = Date().timeIntervalSince(start)
            defer { remove([out]) }
            let got = channel(MediaMeasure.pcm(out), 0, of: 2), src = channel(source, 0, of: 2)
            let probes = [17, 150, 299].map { many[$0] }
            let exact = probes.allSatisfy { r in
                let a = Int((r.start * rate).rounded(.up)), b = Int((r.end * rate).rounded(.up))
                return (a..<b).allSatisfy { got[$0] == 0 } && got[b] == src[b] && got[a - 1] == src[a - 1]
            }
            t.check(exact && elapsed < 10, "300 ranges: exact edges, \(f(elapsed)) s")
        } catch { t.check(false, "300 ranges: \(error.localizedDescription)") }

        // Options.
        if let s = try? MediaSource.load(st) {
            let merged = try? MediaBleep.parseRanges("2-3, 1-2.5, 3.5-3.6, 0:00.2-0:00.4", source: s)
            t.check(merged == [MediaRange(start: 0.2, end: 0.4), MediaRange(start: 1, end: 3), MediaRange(start: 3.5, end: 3.6)],
                    "ranges are sorted, overlaps joined, m:ss.ff read")
            let expr = MediaBleep.expression([MediaRange(start: 1, end: 2), MediaRange(start: 3, end: 4)][...], mode: .silence, frequency: 1000)
            t.check(expr == "if(lt(t,3.000000),if(gte(t,1.000000)*lt(t,2.000000),0,val(ch)),if(gte(t,3.000000)*lt(t,4.000000),0,val(ch)))",
                    "the expression is a binary search: \(expr)")
        }
        let clip = dir.appendingPathComponent("clip.mp4"), odd = dir.appendingPathComponent("odd.mkv")
        let fm = FileManager.default
        let count = { (try? fm.contentsOfDirectory(atPath: dir.path).filter { $0.contains(" bleeped") }.count) ?? -1 }
        let before = count()
        t.throwsError("bleep without ranges", containing: "Give the stretches to bleep") { _ = try MediaBleep.bleep(clip, options: [:]) { _ in } }
        t.throwsError("bleep past the end", containing: "ends past the end of the file (0:04.00)") {
            _ = try MediaBleep.bleep(clip, options: ["ranges": "3-5"]) { _ in }
        }
        t.throwsError("bleep a malformed range", containing: "“abc” isn’t a range") { _ = try MediaBleep.bleep(clip, options: ["ranges": "abc"]) { _ in } }
        t.throwsError("bleep a backwards range", containing: "must start before it ends") { _ = try MediaBleep.bleep(clip, options: ["ranges": "2-1"]) { _ in } }
        t.throwsError("bleep mode=beep", containing: "mode=tone or mode=silence") {
            _ = try MediaBleep.bleep(clip, options: ["ranges": "1-2", "mode": "beep"]) { _ in }
        }
        t.throwsError("bleep freq=abc", containing: "isn’t a number") { _ = try MediaBleep.bleep(clip, options: ["ranges": "1-2", "freq": "abc"]) { _ in } }
        t.throwsError("bleep freq=30000", containing: "Choose a tone between 20 Hz") {
            _ = try MediaBleep.bleep(clip, options: ["ranges": "1-2", "freq": "30000"]) { _ in }
        }
        t.throwsError("bleep a video without sound", containing: "no sound to bleep") { _ = try MediaBleep.bleep(odd, options: ["ranges": "1-2"]) { _ in } }
        t.check(count() == before, "bad bleeps write nothing")
    }

    // MARK: Bleep window

    private static func bleepEditor(_ t: Checker, _ dir: URL) {
        typealias S = MediaTestSupport
        let clip = dir.appendingPathComponent("clip.mp4")
        do {
            let e = try S.editor(BleepEditorController.self, url: clip, loadLanes: true)
            let tl = e.timeline!, w = e.window
            func press(_ c: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) { _ = e.handleKey(S.key(c, keyCode: code, flags: flags, window: w)) }
            func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }
            e.setMode(.tone)
            t.check(e.window.subtitle == "Bleep" && tl.mode == .multiple && e.ranges.isEmpty && !e.hasChanges, "a new Bleep window has no ranges and nothing to save")
            let bar = S.toolbarLayout(w, tools: ["bleep.mode", "bleep.add", "bleep.delete"])
            t.check(bar.centred && bar.items == ["flex", "bleep.mode", "space", "bleep.add", "bleep.delete", "flex", "media.undo", "media.redo", "space", "media.save"],
                    "toolbar: Tone | Silence, Add and Delete centred, Undo, Redo and Save trailing (\(bar.items.joined(separator: " ")))")
            t.check(e.summaryLabel.stringValue == "Drag across the sound to add a bleep" && !e.startField.isEnabled && e.deleteItem?.isEnabled == false,
                    "empty state: “\(e.summaryLabel.stringValue)”, fields and Delete disabled")
            t.throwsError("Save with no ranges", containing: "Mark at least one stretch") { _ = try e.makeOptions() }
            let y = tl.bounds.height / 2
            S.drag(tl, from: CGPoint(x: tl.x(1.0), y: y), to: CGPoint(x: tl.x(1.5), y: y))
            S.drag(tl, from: CGPoint(x: tl.x(2.5), y: y), to: CGPoint(x: tl.x(3.2), y: y))
            t.check(e.ranges.count == 2 && near(e.ranges[0].start, 1) && near(e.ranges[0].end, 1.5) && near(e.ranges[1].start, 2.5)
                    && near(e.ranges[1].end, 3.2) && e.selectedRange == 1 && e.undo.undoActionName == "Add Range",
                    "dragging on the waveform adds ranges: \(e.ranges.map { "\(f($0.start))–\(f($0.end))" })")
            t.check(e.summaryLabel.stringValue == "2 bleeps · 1.20 s" && e.startField.stringValue == "0:02.50" && e.endField.stringValue == "0:03.20"
                    && e.deleteItem?.isEnabled == true, "read-outs: “\(e.summaryLabel.stringValue)”, Start \(e.startField.stringValue), End \(e.endField.stringValue)")
            // Typing an end for the selected range.
            e.endField.stringValue = "3.5"
            e.endField.sendAction(e.endField.action, to: e.endField.target)
            t.check(near(e.ranges[1].end, 3.5) && e.undo.undoActionName == "Set End", "typing 3.5 in End moves the selected range’s end")
            e.endField.stringValue = "0:01.00"
            e.endField.sendAction(e.endField.action, to: e.endField.target)
            t.check(near(e.ranges[1].end, 3.5) && e.endField.stringValue == "0:03.50", "an end before the start is refused and put back")
            // I with nothing selected adds a one-second range at the playhead; ⌫ deletes the selected one; Undo.
            S.drag(tl, from: CGPoint(x: tl.x(0.3), y: y), to: CGPoint(x: tl.x(0.3), y: y))
            t.check(e.selectedRange == nil && near(e.playhead, 0.3), "clicking empty lanes deselects and moves the playhead")
            press("i", S.Code.i)
            t.check(e.ranges.count == 3 && near(e.ranges[0].start, 0.3) && near(e.ranges[0].end, 1.0) && e.selectedRange == 0,
                    "I adds a bleep at the playhead, stopped at its neighbour (\(f(e.ranges[0].start))–\(f(e.ranges[0].end)))")
            press("\u{7f}", S.Code.delete)
            t.check(e.ranges.count == 2 && e.selectedRange == nil, "⌫ deletes the selected bleep")
            press("z", S.Code.z, .command)
            t.check(e.ranges.count == 3, "⌘Z brings it back")
            // Tone or Silence, shown in the waveform and in Save's options.
            let peakInside = tl.waveformPeak?(2.6, 2.61, 0.9), peakOutside = tl.waveformPeak?(1.7, 1.71, 0.9)
            t.check(peakInside == Float(MediaBleep.toneLevel) && peakOutside == 0.9, "Tone: the waveform shows the tone’s level inside a range")
            e.setMode(.silence)
            t.check(tl.waveformPeak?(2.6, 2.61, 0.9) == 0 && tl.waveformPeak?(1.49, 1.51, 0.9) == 0.9 && e.summaryLabel.stringValue.hasPrefix("3 silences"),
                    "Silence: the waveform is flat inside a range (a column across an edge keeps the sound)")
            let options = try e.makeOptions()
            t.check(options["mode"] == "silence" && options["ranges"] == "0.300000-1.000000,1.000000-1.500000,2.500000-3.500000" && options["freq"] == "1000",
                    "Save’s options: \(options)")
            let out = try MediaBleep.bleep(clip, options: options) { _ in }
            let mono = MediaMeasure.pcm(out, rate: 8000, channels: 1)
            let quiet = mono[2440..<2560].allSatisfy { abs(Int($0)) < 40 } && mono[20_400..<27_600].allSatisfy { abs(Int($0)) < 40 }
            t.check(quiet && mono[16_000..<19_600].contains { abs(Int($0)) > 1000 }, "saving the window’s ranges silences 0.3–1.5 s and 2.5–3.5 s, nothing else")
            remove([out])
            let children = tl.accessibilityChildren() ?? []
            t.check(children.count == 7 && e.startField.accessibilityLabel() == "Start" && e.summaryLabel.accessibilityLabel() == "Bleeps",
                    "VoiceOver: playhead, both ends of 3 ranges, labelled fields")
            e.forceClose()

            let a = try S.editor(BleepEditorController.self, url: dir.appendingPathComponent("tone.wav"))
            t.check(a.preview == nil && a.timeline.mode == .multiple, "the audio Bleep window has no picture")
            a.scrub(to: 2.0); _ = a.handleKey(S.key("i", keyCode: S.Code.i, window: a.window))
            a.scrub(to: 2.5); _ = a.handleKey(S.key("o", keyCode: S.Code.o, window: a.window))
            t.check(a.ranges == [MediaRange(start: 2, end: 2.5)], "audio I/O mark 2.00–2.50 s")
            a.forceClose()
        } catch { t.check(false, "Bleep window: \(error.localizedDescription)") }

        t.throwsError("the Bleep window refuses a video without sound", containing: "odd.mkv has no sound to bleep") {
            try BleepEditorController.check(try MediaSource.load(dir.appendingPathComponent("odd.mkv")))
        }
        let view = MediaTools.snapshot("bleep", files: [clip], options: [:])
        let size = (view as? NSImageView)?.image?.size ?? .zero
        t.check(size.width >= 1000 && size.height >= 660, "the bleep snapshot renders the whole window (\(Int(size.width)) × \(Int(size.height)))")
    }

    /// The live window mutes the ranges in the player (an audio mix), and the preview tone is the saved tone.
    private static func bleepPreview(_ t: Checker, _ tone: URL) {
        func waitUntil(_ timeout: Double, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() && Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            return condition()
        }
        do {
            let e = BleepEditorController(source: try MediaSource.load(tone), snapshot: false)
            e.loadPreview()
            t.check(waitUntil(15) { e.playerReady && e.previewAudio != nil }, "tone.wav: the preview plays and the bleep preview is attached")
            e.setRanges([MediaRange(start: 1, end: 1.5), MediaRange(start: 3, end: 4)], selected: nil, action: "Test")
            t.check(waitUntil(5) { e.previewAudio?.audioMix != nil }, "the player item gets an audio mix")
            if let params = e.previewAudio?.audioMix?.inputParameters.first {
                func volume(_ s: Double) -> Float? {
                    var a: Float = -1, b: Float = -1, range = CMTimeRange()
                    return params.getVolumeRamp(for: CMTime(seconds: s, preferredTimescale: 96_000), startVolume: &a, endVolume: &b, timeRange: &range) ? a : nil
                }
                let v = [0.5, 1.2, 2.0, 3.5, 4.5].map { volume($0) ?? -1 }
                t.check(v == [1, 0, 1, 0, 1], "the file’s own sound is muted inside the ranges: volumes \(v)")
            } else { t.check(false, "audio mix parameters") }
            let ranges = [MediaRange(start: 1, end: 1.5)]
            let s = BleepPreviewAudio.toneSample(at: 1.0 + 0.00025, ranges: ranges)
            t.check(abs(Double(s) - 0.3) < 1e-6 && BleepPreviewAudio.toneSample(at: 0.99, ranges: ranges) == 0
                    && BleepPreviewAudio.toneSample(at: 1.5, ranges: ranges) == 0, "the preview tone is the saved tone, only inside ranges")
            e.forceClose()
        } catch { t.check(false, "Bleep preview: \(error.localizedDescription)") }
    }

    // MARK: Speed

    private static func speed(_ t: Checker, _ dir: URL) {
        let clip = dir.appendingPathComponent("clip.mp4")
        for (factor, frames, name) in [(2.0, 60, "clip 2x.mp4"), (4.0, 30, "clip 4x.mp4"), (0.5, 240, "clip 0.5x.mp4"), (0.25, 480, "clip 0.25x.mp4")] {
            do {
                let out = try MediaSpeed.speed(clip, options: ["factor": String(factor)]) { _ in }
                defer { remove([out]) }
                let r = try MediaSource.load(out)
                let times = MediaMeasure.frameTimes(out)
                let length = 4 / factor
                let sound = Double(MediaMeasure.pcm(out, rate: 8000, channels: 1).count) / 8000
                t.check(out.lastPathComponent == name && times.count == frames && abs((r.fps ?? 0) - 30) < 0.01 && abs(sound - length) < 0.05,
                        "speed \(Ask.formatNumber(factor))×: \(out.lastPathComponent), \(times.count) frames (expected \(frames)) at \(Ask.formatNumber(r.fps ?? 0)) fps, sound \(f(sound)) s")
            } catch { t.check(false, "speed \(factor): \(error.localizedDescription)") }
        }
        // Pitch: kept with atempo, raised with a rate change. tone.wav's frequency is measured first.
        let toneURL = dir.appendingPathComponent("tone.wav")
        let src = MediaMeasure.pcm(toneURL)
        let candidates = stride(from: 100.0, through: 2000, by: 10).map { $0 }
        let f0 = dominant(src, rate: 44_100, among: candidates, 1, 2)
        for keep in [true, false] {
            do {
                let out = try MediaSpeed.speed(toneURL, options: ["factor": "1.5", "keep_pitch": keep ? "true" : "false"]) { _ in }
                defer { remove([out]) }
                let got = MediaMeasure.pcm(out, rate: 44_100)
                let seconds = Double(got.count) / 44_100
                let f1 = dominant(got, rate: 44_100, among: candidates + [f0 * 1.5], 1, 2)
                let expected = keep ? f0 : f0 * 1.5
                t.check(abs(seconds - 5 / 1.5) < 0.02 && abs(f1 - expected) < 6,
                        "speed 1.5× \(keep ? "keeping" : "not keeping") pitch: \(f(seconds)) s, \(Int(f0)) Hz → \(Int(f1)) Hz")
            } catch { t.check(false, "speed tone: \(error.localizedDescription)") }
        }
        // Channels and the stereo test tone survive a slow-down.
        do {
            let out = try MediaSpeed.speed(dir.appendingPathComponent("st.wav"), options: ["factor": "0.5"]) { _ in }
            defer { remove([out]) }
            let got = MediaMeasure.pcm(out)
            let l = channel(got, 0, of: 2), r = channel(got, 1, of: 2)
            t.check(abs(Double(l.count) / 48_000 - 8) < 0.02 && dominant(l, rate: 48_000, among: [440, 880], 2, 3) == 440
                    && dominant(r, rate: 48_000, among: [440, 880], 2, 3) == 880,
                    "speed 0.5× of st.wav: \(f(Double(l.count) / 48_000)) s, still 440 Hz left and 880 Hz right")
        } catch { t.check(false, "speed st.wav: \(error.localizedDescription)") }
        for (name, factor, ext) in [("sample.wma", 2.0, "wma"), ("sample.avi", 4.0, "avi"), ("sample.wmv", 2.0, "wmv"), ("odd.mkv", 0.5, "mkv")] {
            do {
                let src = dir.appendingPathComponent(name)
                let out = try MediaSpeed.speed(src, options: ["factor": String(factor)]) { _ in }
                defer { remove([out]) }
                let s = try MediaSource.load(src), r = try MediaSource.load(out)
                // Lengths from the content: an ASF muxer shifts both streams by the WMA encoder's delay, which its
                // reported duration counts again. Frames for the picture, samples for the sound.
                // (Sound files on the file's clock: ffmpeg's WMA decoder starts at 0.092 s.)
                let sound = s.hasAudio ? Double(MediaMeasure.pcm(out, channels: 1, fileClock: !s.hasVideo).count) / Double(r.sampleRate ?? 44_100)
                                       : r.duration
                let frames = (MediaMeasure.frameTimes(src).count, MediaMeasure.frameTimes(out).count)
                let framesOK = !s.hasVideo || abs(Double(frames.1) - Double(frames.0) / factor) <= 1
                t.check(Ext.of(out) == ext && abs(sound - s.duration / factor) < 0.08 && framesOK && r.hasAudio == s.hasAudio,
                        "speed \(Ask.formatNumber(factor))× \(name): \(f(s.duration)) s → \(s.hasAudio ? "sound" : "file") \(f(sound)) s"
                            + (s.hasVideo ? ", \(frames.0) → \(frames.1) frames" : "") + ", still .\(ext)")
            } catch { t.check(false, "speed \(name): \(error.localizedDescription)") }
        }
        t.check(MediaSpeed.tempoSteps(0.25) == [0.5, 0.5] && MediaSpeed.tempoSteps(4) == [2, 2] && MediaSpeed.tempoSteps(0.75) == [0.75]
                && MediaSpeed.audioFilters(1.5, keepPitch: false, sampleRate: 44_100) == ["asetrate=66150", "aresample=44100"],
                "atempo steps stay within 0.5…2; a tape-style change resamples")
        t.throwsError("speed 1×", containing: "changes nothing") { _ = try MediaSpeed.speed(clip, options: ["factor": "1"]) { _ in } }
        t.throwsError("speed 5×", containing: "from 0.25× to 4×") { _ = try MediaSpeed.speed(clip, options: ["factor": "5"]) { _ in } }
        t.throwsError("speed factor=fast", containing: "“fast” isn’t a number") { _ = try MediaSpeed.speed(clip, options: ["factor": "fast"]) { _ in } }
    }

    // MARK: Sound that starts after the picture

    /// A clip whose sound starts at 0.5 s, with a flash and a burst together at 2.5 s (MediaTestSupport): Bleep's
    /// ranges are on the picture's clock (a bleep at 2.45–2.6 s covers the burst), and Speed keeps the burst with its
    /// flash at 2× and 0.5×.
    private static func lateSound(_ t: Checker, _ dir: URL) {
        let url = dir.appendingPathComponent("late.mp4")
        guard MediaTestSupport.makeLateSoundClip(url), MediaTestSupport.flashAndBurst(url) != nil else {
            t.check(false, "make late.mp4"); return
        }
        defer { remove([url]) }
        do {
            let out = try MediaBleep.bleep(url, options: ["ranges": "2.45-2.6", "mode": "silence"]) { _ in }
            defer { remove([out]) }
            let x = MediaMeasure.pcm(out, rate: 48_000, channels: 1, fileClock: true)
            let loud = x.firstIndex { abs(Int($0)) > 9_830 }.map { Double($0) / 48_000 }
            let hum = tone(x, rate: 48_000, 300, 1.0, 2.4)
            t.check(loud == nil && hum > 0.03, "late sound: a silence at 2.45–2.6 s covers the burst under the flash at 2.5 s "
                    + "(\(loud.map { "a burst is left at \(f($0)) s" } ?? "no burst left"); the hum is still there, \(f(hum)))")
        } catch { t.check(false, "bleep late.mp4: \(error.localizedDescription)") }
        for factor in [2.0, 0.5] {
            do {
                let out = try MediaSpeed.speed(url, options: ["factor": Ask.formatNumber(factor)]) { _ in }
                defer { remove([out]) }
                let m = MediaTestSupport.flashAndBurst(out)
                let gap = m.map { $0.burst - $0.flash } ?? .nan
                t.check(abs(gap) < 0.04 && m.map { abs($0.flash - 2.5 / factor) < 0.05 } == true,
                        "late sound at \(Ask.formatNumber(factor))×: flash at \(m.map { f($0.flash) } ?? "?") s, the burst \(Int((gap * 1000).rounded())) ms from it")
            } catch { t.check(false, "speed late.mp4: \(error.localizedDescription)") }
        }
        bleepWhereSoundIs(t, dir, late: url)
    }

    /// The Bleep window's result waveform draws the tone only where there are samples for Save to replace: not before
    /// a sound that starts late (late.mp4: 0.5 s), not after one that ends before the picture (2 s of sound, 4 s of
    /// picture). Ranges 0.1–0.4, 1.0–2.5 and 3.0–3.5 in Tone mode.
    private static func bleepWhereSoundIs(_ t: Checker, _ dir: URL, late: URL) {
        let short = dir.appendingPathComponent("short-sound.mp4")
        guard let ff = FFmpeg.shared, (try? ProcessRunner.run(ff.tool, MediaTestSupport.h264(["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                                                                       "-f", "lavfi", "-i", "testsrc2=s=320x240:r=30:d=4",
                                                                       "-f", "lavfi", "-i", "sine=f=440:d=2:sample_rate=48000",
                                                                       "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-c:a", "aac", short.path])))?.status == 0
        else { t.check(false, "make short-sound.mp4"); return }
        defer { remove([short]) }
        let tone = Float(MediaBleep.toneLevel)
        for (url, where_, inside, outside) in [(short, "after the sound ends at 2 s", 1.6, 3.1), (late, "before the sound starts at 0.5 s", 1.6, 0.2)] {
            do {
                let e = try MediaTestSupport.editor(BleepEditorController.self, url: url, loadLanes: true)
                defer { e.forceClose() }
                e.setMode(.tone)
                e.setRanges([MediaRange(start: 0.1, end: 0.4), MediaRange(start: 1.0, end: 2.5), MediaRange(start: 3.0, end: 3.5)],
                            selected: nil, action: "Test")
                func drawn(_ t0: Double) -> Float {
                    let raw = e.timeline.peaks?.peak(from: t0, to: t0 + 0.05) ?? 0
                    return e.timeline.waveformPeak?(t0, t0 + 0.05, raw) ?? raw
                }
                let a = drawn(inside), b = drawn(outside)
                t.check(abs(a - tone) < 0.001 && b == 0,
                        "\(url.lastPathComponent): the tone is drawn at \(f(inside)) s (\(String(format: "%.2f", a))) and not \(where_) "
                            + "(\(String(format: "%.2f", b)) at \(f(outside)) s), where Save has no sound to replace")
            } catch { t.check(false, "Bleep window for \(url.lastPathComponent): \(error.localizedDescription)") }
        }
    }

    // MARK: Old containers and Visualize's clock

    /// A Flash video (Sorenson Spark, the codec of old .flv files) is written as an MP4, which can't hold that codec:
    /// Bleep and Channels re-encode its picture instead of stopping with ffmpeg's "Could not find tag for codec flv1".
    private static func oldContainers(_ t: Checker, _ dir: URL) {
        let flv = dir.appendingPathComponent("old.flv")
        guard let ff = FFmpeg.shared, (try? ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                                                                       "-f", "lavfi", "-i", "testsrc2=s=320x240:r=25:d=3",
                                                                       "-f", "lavfi", "-i", "sine=f=440:d=3:sample_rate=44100",
                                                                       "-c:v", "flv", "-c:a", "libmp3lame", flv.path]))?.status == 0
        else { t.check(false, "make old.flv"); return }
        defer { remove([flv]) }
        let frames = MediaMeasure.frameTimes(flv).count
        for (name, run) in [("bleep", { try MediaBleep.bleep(flv, options: ["ranges": "1-2"]) { _ in } }),
                            ("channels", { try MediaChannels.channels(flv, options: [:]) { _ in } })] as [(String, () throws -> URL)] {
            do {
                let out = try run()
                defer { remove([out]) }
                let r = try MediaSource.load(out)
                let got = MediaMeasure.frameTimes(out).count
                t.check(Ext.of(out) == "mp4" && r.videoCodec == "h264" && r.hasAudio && got == frames,
                        "\(name) old.flv (flv1): \(out.lastPathComponent), \(r.videoCodec ?? "no picture"), \(got) of \(frames) frames")
            } catch { t.check(false, "\(name) old.flv (flv1): \(error.localizedDescription)") }
        }
    }

    /// Visualize draws on the file's clock: a click at 2 s in a WMA (whose decoder starts its sound at 0.092 s) shows
    /// in the picture within a frame and a half of when it sounds in the MP4, as it does for a WAV.
    private static func visualizeClock(_ t: Checker, _ dir: URL) {
        guard let ff = FFmpeg.shared, MediaVisualize.availableStyles.contains(.waveform) else { return }
        let wav = dir.appendingPathComponent("click.wav"), wma = dir.appendingPathComponent("click.wma")
        func run(_ args: [String]) -> Bool {
            (try? ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + MediaTestSupport.h264(args)))?.status == 0
        }
        guard run(["-f", "lavfi", "-i", "aevalsrc='0.001*sin(2*PI*300*t)+if(between(t,2.0,2.05),0.9*sin(2*PI*1000*(t-2)),0)':s=44100:d=4",
                   "-c:a", "pcm_s16le", wav.path]),
              run(["-i", wav.path, "-c:a", "wmav2", wma.path]) else { t.check(false, "make click.wav and click.wma"); return }
        defer { remove([wav, wma]) }
        for src in [wav, wma] {
            do {
                let out = try MediaVisualize.visualize(src, options: ["style": "waveform"]) { _ in }
                defer { remove([out]) }
                // The drawing's area, a few pixels a frame: the first frame that differs from the first one is the click.
                guard let r = try? ProcessRunner.run(ff.tool, ["-hide_banner", "-nostdin", "-i", out.path, "-map", "0:v:0", "-vf",
                                                               "crop=iw:ih*0.5:0:ih*0.14,scale=16:8,format=gray,showinfo", "-f", "null", "-"])
                else { t.check(false, "measure \(out.lastPathComponent)"); continue }
                var first: Int?, drawnAt: Double?
                for line in r.stderr.split(separator: "\n") where line.contains("pts_time:") {
                    guard let time = line.firstMatch(of: #/pts_time:(-?[0-9.]+)/#).flatMap({ Double($0.1) }),
                          let mean = line.firstMatch(of: #/mean:\[(\d+)/#).flatMap({ Int($0.1) }) else { continue }
                    if let base = first { if abs(mean - base) > 3 { drawnAt = time; break } } else { first = mean }
                }
                let x = MediaMeasure.pcm(out, rate: 44_100, channels: 1, fileClock: true)
                let heard = x.firstIndex { abs(Int($0)) > 9_830 }.map { Double($0) / 44_100 }
                let gap = (drawnAt ?? .nan) - (heard ?? .nan)
                t.check(abs(gap) < 0.05, "visualize \(src.lastPathComponent): the click is drawn at \(drawnAt.map(f) ?? "?") s and heard at "
                        + "\(heard.map(f) ?? "?") s (\(gap.isNaN ? "?" : String(Int((gap * 1000).rounded()))) ms)")
            } catch { t.check(false, "visualize \(src.lastPathComponent): \(error.localizedDescription)") }
        }
    }

    // MARK: Split

    private static func split(_ t: Checker, _ dir: URL) {
        let clip = dir.appendingPathComponent("clip.mp4")
        do {
            let parts = try MediaSplit.split(clip, options: ["parts": "3"]) { _ in }
            defer { remove(parts) }
            let counts = parts.map { MediaMeasure.frameTimes($0).count }
            t.check(parts.map(\.lastPathComponent) == ["clip part 1.mp4", "clip part 2.mp4", "clip part 3.mp4"] && counts == [40, 40, 40],
                    "split clip.mp4 into 3: \(parts.map(\.lastPathComponent)), \(counts) frames")
            if let a = MediaMeasure.frameRGB(parts[1], index: 0), let b = MediaMeasure.frameRGB(clip, index: 40),
               let c = MediaMeasure.frameRGB(clip, index: 39) {
                t.check(MediaMeasure.psnr(a, b) > 30 && MediaMeasure.psnr(a, b) > MediaMeasure.psnr(a, c) + 3,
                        "part 2 starts on source frame 40 (PSNR \(f(MediaMeasure.psnr(a, b))) dB, frame 39 \(f(MediaMeasure.psnr(a, c))) dB)")
            }
            let sound = parts.map { Double(MediaMeasure.pcm($0, rate: 8000, channels: 1).count) / 8000 }
            t.check(abs(sound.reduce(0, +) - 4) < 0.08, "the parts’ sound adds up to 4 s (\(sound.map(f)))")
        } catch { t.check(false, "split clip.mp4: \(error.localizedDescription)") }
        do {
            let wmv = dir.appendingPathComponent("sample.wmv")
            let total = MediaMeasure.frameTimes(wmv).count
            let parts = try MediaSplit.split(wmv, options: ["mode": "every", "seconds": "1"]) { _ in }
            defer { remove(parts) }
            let counts = parts.map { MediaMeasure.frameTimes($0).count }
            t.check(parts.count == 4 && counts.reduce(0, +) == total && parts.allSatisfy { Ext.of($0) == "wmv" },
                    "split sample.wmv every second: \(parts.count) parts, \(counts) frames = \(total) in the source")
        } catch { t.check(false, "split sample.wmv: \(error.localizedDescription)") }
        do {
            let wav = dir.appendingPathComponent("tone.wav")
            let source = MediaMeasure.pcm(wav)
            let parts = try MediaSplit.split(wav, options: ["mode": "every", "seconds": "1.5"]) { _ in }
            defer { remove(parts) }
            let samples = parts.map { MediaMeasure.pcm($0) }
            t.check(samples.map(\.count) == [66_150, 66_150, 66_150, 22_050] && Array(samples.joined()) == source,
                    "split tone.wav every 1.5 s: \(samples.map(\.count)) samples, joined back they are the source exactly")
        } catch { t.check(false, "split tone.wav: \(error.localizedDescription)") }
        do {
            let odd = dir.appendingPathComponent("odd.mkv")
            let parts = try MediaSplit.split(odd, options: [:]) { _ in }
            defer { remove(parts) }
            let counts = parts.map { MediaMeasure.frameTimes($0).count }
            t.check(parts.count == 2 && counts.sorted() == [37, 38], "split odd.mkv (defaults: 2 parts): \(counts) frames of 75")
        } catch { t.check(false, "split odd.mkv: \(error.localizedDescription)") }
        if let s = try? MediaSource.load(clip) {
            let r = try? MediaSplit.parts(s, options: ["mode": "every", "seconds": "1.9"])
            t.check(r == [MediaRange(start: 0, end: 1.9), MediaRange(start: 1.9, end: 4)], "a 0.2 s remainder joins the last part")
            let r2 = try? MediaSplit.parts(s, options: ["mode": "every", "seconds": "1.5"])
            t.check(r2?.count == 3 && r2?.last == MediaRange(start: 3, end: 4), "a 1 s remainder is its own part")
        }
        let fm = FileManager.default
        let count = { (try? fm.contentsOfDirectory(atPath: dir.path).filter { $0.contains(" part ") }.count) ?? -1 }
        let before = count()
        t.throwsError("split into 1", containing: "Choose 2 to 20 parts") { _ = try MediaSplit.split(clip, options: ["parts": "1"]) { _ in } }
        t.throwsError("split into 21", containing: "Choose 2 to 20 parts") { _ = try MediaSplit.split(clip, options: ["parts": "21"]) { _ in } }
        t.throwsError("split every 10 s of 4 s", containing: "only 4.00 s long") {
            _ = try MediaSplit.split(clip, options: ["mode": "every", "seconds": "10"]) { _ in }
        }
        t.throwsError("split every 0.05 s", containing: "at least 0.1 seconds") {
            _ = try MediaSplit.split(clip, options: ["mode": "every", "seconds": "0.05"]) { _ in }
        }
        t.throwsError("split mode=halves", containing: "mode=parts or mode=every") { _ = try MediaSplit.split(clip, options: ["mode": "halves"]) { _ in } }
        t.check(count() == before, "bad splits write nothing")
    }

    // MARK: Channels

    private static func channels(_ t: Checker, _ dir: URL) {
        let st = dir.appendingPathComponent("st.wav")
        let rate = 48_000.0
        typealias L = MediaChannels.Layout
        func amps(_ x: [Int16]) -> (Double, Double) { (tone(x, rate: rate, 440, 1, 3), tone(x, rate: rate, 880, 1, 3)) }
        // The source's level of each tone, on its own channel.
        let st0 = MediaMeasure.pcm(st)
        let level = (tone(channel(st0, 0, of: 2), rate: rate, 440, 1, 3) + tone(channel(st0, 1, of: 2), rate: rate, 880, 1, 3)) / 2
        func same(_ v: Double, _ w: Double) -> Bool { abs(v - w) < w * 0.03 }
        let none = level * 0.02
        let cases: [(L, String, Int)] = [(.mono, "st mono.wav", 1), (.swap, "st swapped.wav", 2), (.left, "st left.wav", 1), (.right, "st right.wav", 1)]
        for (layout, name, n) in cases {
            do {
                let out = try MediaChannels.channels(st, options: ["layout": layout.rawValue]) { _ in }
                defer { remove([out]) }
                let r = try MediaSource.load(out)
                let pcm = MediaMeasure.pcm(out)
                let chans = (0..<n).map { amps(channel(pcm, $0, of: n)) }
                let ok: Bool
                switch layout {
                case .mono: ok = same(chans[0].0, level / 2) && same(chans[0].1, level / 2)
                case .swap: ok = chans[0].0 < none && same(chans[0].1, level) && same(chans[1].0, level) && chans[1].1 < none
                case .left: ok = same(chans[0].0, level) && chans[0].1 < none
                case .right: ok = chans[0].0 < none && same(chans[0].1, level)
                case .stereo: ok = false
                }
                let text = chans.enumerated().map { "ch\($0.offset): 440 Hz \(f($0.element.0 / level)), 880 Hz \(f($0.element.1 / level))" }
                    .joined(separator: "; ") + " (of the source’s level)"
                t.check(out.lastPathComponent == name && r.channels == n && ok, "\(layout.title): \(out.lastPathComponent), \(r.channels ?? 0) ch — \(text)")
            } catch { t.check(false, "channels \(layout): \(error.localizedDescription)") }
        }
        do {
            let toneURL = dir.appendingPathComponent("tone.wav")
            let out = try MediaChannels.channels(toneURL, options: [:]) { _ in }
            defer { remove([out]) }
            let pcm = MediaMeasure.pcm(out), src = MediaMeasure.pcm(toneURL)
            t.check(out.lastPathComponent == "tone stereo.wav" && channel(pcm, 0, of: 2) == src && channel(pcm, 1, of: 2) == src,
                    "a mono file becomes stereo by default: both channels are the source, sample for sample")
        } catch { t.check(false, "channels tone.wav: \(error.localizedDescription)") }
        do {
            let stv = dir.appendingPathComponent("stv.mp4")
            let out = try MediaChannels.channels(stv, options: ["layout": "swap"]) { _ in }
            defer { remove([out]) }
            let pcm = MediaMeasure.pcm(out, rate: 48_000)
            let l = amps(channel(pcm, 0, of: 2)), r = amps(channel(pcm, 1, of: 2))
            t.check(out.lastPathComponent == "stv swapped.mp4" && streamHash(stv) == streamHash(out) && l.1 > 10 * l.0 && r.0 > 10 * r.1,
                    "swap in a video: picture copied, left now 880 Hz (\(f(l.1))), right 440 Hz (\(f(r.0)))")
        } catch { t.check(false, "channels video: \(error.localizedDescription)") }
        do {
            let six = dir.appendingPathComponent("six.flac")
            let out = try MediaChannels.channels(six, options: ["layout": "mono"]) { _ in }
            let stereo = try MediaChannels.channels(six, options: ["layout": "stereo"]) { _ in }
            defer { remove([out, stereo]) }
            t.check((try? MediaSource.load(out))?.channels == 1 && (try? MediaSource.load(stereo))?.channels == 2 && Ext.of(out) == "flac",
                    "5.1 downmixes to mono and to stereo")
        } catch { t.check(false, "channels 5.1: \(error.localizedDescription)") }
        t.check(MediaChannels.layouts(forChannels: 1) == [.stereo] && MediaChannels.layouts(forChannels: 2) == [.mono, .swap, .left, .right]
                && MediaChannels.layouts(forChannels: 6) == [.mono, .stereo, .left, .right], "the form offers only what fits the channels")
        let toneURL = dir.appendingPathComponent("tone.wav")
        t.throwsError("left of a mono file", containing: "is mono") { _ = try MediaChannels.channels(toneURL, options: ["layout": "left"]) { _ in } }
        t.throwsError("stereo of a stereo file", containing: "already stereo") { _ = try MediaChannels.channels(st, options: ["layout": "stereo"]) { _ in } }
        t.throwsError("swap of 5.1", containing: "6 channels") {
            _ = try MediaChannels.channels(dir.appendingPathComponent("six.flac"), options: ["layout": "swap"]) { _ in }
        }
        t.throwsError("layout=quad", containing: "Choose layout=mono") { _ = try MediaChannels.channels(st, options: ["layout": "quad"]) { _ in } }
        t.throwsError("a video without sound", containing: "has no sound") {
            _ = try MediaChannels.channels(dir.appendingPathComponent("odd.mkv"), options: [:]) { _ in }
        }
    }

    // MARK: Visualize

    private static func visualize(_ t: Checker, _ dir: URL) {
        let song = dir.appendingPathComponent("song.wav")
        t.check(MediaVisualize.availableStyles == [.waveform, .spectrum, .bars], "this Mac’s ffmpeg draws every style")
        let runs: [(MediaVisualize.Style, MediaVisualize.Size)] = [(.waveform, .square), (.spectrum, .square), (.bars, .square),
                                                                   (.bars, .wide), (.waveform, .tall)]
        for (style, size) in runs {
            let label = "\(style.title), \(size.rawValue)"
            do {
                let out = try MediaVisualize.visualize(song, options: ["style": style.rawValue, "size": size.rawValue]) { _ in }
                defer { remove([out]) }
                let r = try MediaSource.load(out)
                let (w, h) = size.pixels
                let frames = MediaMeasure.frameTimes(out)
                let sound = Double(MediaMeasure.pcm(out, rate: 8000, channels: 1).count) / 8000
                t.check(out.lastPathComponent == "song visualized.mp4" && Int(r.pixelSize.width) == w && Int(r.pixelSize.height) == h
                        && r.videoCodec == "h264" && r.audioCodec == "aac" && r.colorMatrix == "bt709",
                        "\(label): \(out.lastPathComponent), \(Int(r.pixelSize.width)) × \(Int(r.pixelSize.height)) H.264 BT.709 + AAC")
                t.check(abs(Double(frames.count) / 30 - 3) < 0.07 && abs(sound - 3) < 0.05,
                        "\(label): \(frames.count) frames at 30 fps (\(f(Double(frames.count) / 30)) s), sound \(f(sound)) s")
                // A frame at 1.5 s, a quarter size: the page, the band, the drawing and its reflection.
                let qw = w / 4, qh = h / 4
                guard let px = MediaMeasure.frameRGB(out, index: 45, width: qw, height: qh),
                      let first = MediaMeasure.frameRGB(out, index: 0, width: qw, height: qh) else {
                    t.check(false, "\(label): frames decode"); continue
                }
                func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * qw + x) * 3; return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2])) }
                func close(_ a: (Int, Int, Int), _ b: (Int, Int, Int), _ tol: Int) -> Bool {
                    abs(a.0 - b.0) <= tol && abs(a.1 - b.1) <= tol && abs(a.2 - b.2) <= tol
                }
                let page = pixel(2, 2), band = pixel(2, qh - 3)
                t.check(close(page, (255, 244, 234), 5) && close(band, (255, 233, 194), 6),
                        "\(label): cream page \(page), butter band \(band)")
                let horizon = qh * 2 / 3
                func isDahlia(_ p: (Int, Int, Int)) -> Bool { close(p, (226, 102, 156), 22) }
                func isReflection(_ p: (Int, Int, Int)) -> Bool { close(p, (246, 191, 182), 16) }
                var drawing = 0, reflection = 0
                for y in 0..<qh { for x in 0..<qw {
                    let p = pixel(x, y)
                    if y < horizon, isDahlia(p) { drawing += 1 }
                    if y > horizon, isReflection(p) { reflection += 1 }
                } }
                let total = Double(qw * qh)
                t.check(Double(drawing) / total > 0.01 && Double(reflection) / total > 0.003,
                        "\(label): not blank — dahlia drawing \(String(format: "%.1f", 100 * Double(drawing) / total)) %, reflection \(String(format: "%.1f", 100 * Double(reflection) / total)) % of the frame")
                var firstPink = 0
                for i in stride(from: 0, to: first.count, by: 3) where isDahlia((Int(first[i]), Int(first[i + 1]), Int(first[i + 2]))) { firstPink += 1 }
                t.check(Double(firstPink) / total < 0.3, "\(label): the first frame isn’t a pink block (\(String(format: "%.1f", 100 * Double(firstPink) / total)) % dahlia)")
            } catch { t.check(false, "\(label): \(error.localizedDescription)") }
        }
        // Silence draws nothing (the drawing follows the sound).
        do {
            guard let ff = FFmpeg.shared else { return }
            let quiet = dir.appendingPathComponent("quiet.wav")
            try ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
                                            "anullsrc=r=48000:cl=mono", "-t", "1", quiet.path])
            let out = try MediaVisualize.visualize(quiet, options: ["style": "bars"]) { _ in }
            defer { remove([out, quiet]) }
            let px = MediaMeasure.frameRGB(out, index: 15, width: 270, height: 270) ?? []
            var pink = 0
            for i in stride(from: 0, to: px.count, by: 3) where px[i + 1] < 160 { pink += 1 }
            t.check(!px.isEmpty && pink == 0, "silence draws no bars (\(pink) pink pixels)")
        } catch { t.check(false, "visualize silence: \(error.localizedDescription)") }
        t.throwsError("style=swirl", containing: "Choose style=waveform") { _ = try MediaVisualize.visualize(song, options: ["style": "swirl"]) { _ in } }
        t.throwsError("size=huge", containing: "Choose size=square") { _ = try MediaVisualize.visualize(song, options: ["size": "huge"]) { _ in } }
        t.throwsError("a video without sound", containing: "no sound to visualize") {
            _ = try MediaVisualize.visualize(dir.appendingPathComponent("odd.mkv"), options: [:]) { _ in }
        }
    }
}
#endif
