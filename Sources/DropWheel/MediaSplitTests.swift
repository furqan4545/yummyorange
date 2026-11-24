#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit

/// `--selftest media-split`: `--tool split --opt at=…` and the Split window, measured with ffmpeg on copies of the
/// fixtures and two clips made here (a test pattern with a 440 Hz tone; a black clip whose sound starts late, with a
/// flash and a burst together at 2.5 s):
/// - the command: clip.mp4 split at 1.2 and 2.6 s gives parts of 36, 42 and 42 frames (the source's 120); each part
///   starts on the source's frame at its split and ends on the frame before the next (PSNR beats the neighbours by
///   3 dB); the parts' sound adds up to the source's; the tone keeps its phase at every split (timing error under
///   0.1 ms) and runs right to each part's edges; the flash and the burst stay together; tone.wav's parts are the
///   source sample for sample (also at odd times); odd.mkv and sample.wmv keep every frame; m:ss.ff times; bad times
///   give clear errors and write nothing; mode=parts and mode=every as before; the inputs are unchanged.
/// - the window: toolbar (Split, Split Evenly, Remove Split centred; Undo, Redo, Save trailing), labels, Save only
///   with a split; ⌘B at the frame on screen; the one-frame minimum (start, end, on and next to a split) and the
///   100-part cap, each with a beep and a reason; Split Evenly and which of its items are available; dragging a
///   handle (frame-snapped, never past a neighbour, Esc puts it back), clicks that select, deselect or scrub; ↑ ↓,
///   Tab ⇧Tab, ⌫ ⌦, Esc, ⌘Z ⇧⌘Z; keys a text field keeps; the time field; VoiceOver elements; every change one Undo
///   step; Save's options run through the command give the same parts as the command line; the audio window; the
///   snapshot.
enum MediaSplitTests {
    typealias Checker = MediaTestSupport.Checker
    typealias S = MediaTestSupport

    static func run() -> String {
        let t = Checker("media-split")
        guard FFmpeg.shared != nil else { return "OK media-split: skipped, ffmpeg isn’t installed" }
        guard let fixtures = S.fixturesFolder() else {
            return "FAIL media-split: can’t find Tests/fixtures/features. Run from the project folder or set DW_FIXTURES."
        }
        let names = ["clip.mp4", "odd.mkv", "sample.wmv", "tone.wav"]
        let dir: URL
        do { dir = try S.scratchCopy(of: names, from: fixtures) } catch {
            return "FAIL media-split: couldn’t copy the fixtures: \(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
        guard makeSignals(dir) else { return "FAIL media-split: couldn’t make the test clips with ffmpeg" }
        let all = names + ["sine.mp4", "late.mp4"]
        let before = Dictionary(uniqueKeysWithValues: all.map { ($0, MediaMeasure.sha256(url($0))) })

        command(t, dir)
        otherFiles(t, dir)
        badTimes(t, dir)
        windowBasics(t, dir)
        windowDrag(t, dir)
        windowKeys(t, dir)
        windowLimits(t, dir)
        windowSave(t, dir)
        audioWindow(t, dir)
        fixes(t, dir)

        for name in all { t.check(MediaMeasure.sha256(url(name)) == before[name], "\(name) unchanged") }
        for name in names {
            t.check(MediaMeasure.sha256(fixtures.appendingPathComponent(name)) == before[name], "fixture \(name) unchanged")
        }
        return t.report
    }

    // MARK: Helpers

    /// sine.mp4: 4 s of a 30 fps test pattern with a 440 Hz tone (48 kHz AAC) that starts at phase 0.
    /// late.mp4: MediaTestSupport.makeLateSoundClip (sound from 0.5 s; a flash and a 1 kHz burst together at 2.5 s).
    private static func makeSignals(_ dir: URL) -> Bool {
        guard let ff = FFmpeg.shared else { return false }
        let sine = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                    "-f", "lavfi", "-i", "testsrc2=s=320x240:r=30:d=4", "-f", "lavfi", "-i", "sine=f=440:sample_rate=48000:d=4",
                    "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-g", "15", "-bf", "2", "-pix_fmt", "yuv420p", "-c:a", "aac",
                    dir.appendingPathComponent("sine.mp4").path]
        guard (try? ProcessRunner.run(ff.tool, sine))?.status == 0 else { return false }
        return S.makeLateSoundClip(dir.appendingPathComponent("late.mp4"))
    }

    private static func f(_ v: Double) -> String { String(format: "%.3f", v) }
    private static func remove(_ urls: [URL]) { for u in urls { try? FileManager.default.removeItem(at: u) } }
    private static func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) < tolerance }

    /// The MD5 of a stream as decoded (equal when two encodes give the same pictures or samples).
    private static func decodedHash(_ url: URL, _ stream: String) -> String? {
        guard let ff = FFmpeg.shared,
              let r = try? ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", url.path, "-map", stream,
                                                       "-f", "md5", "-"]), r.status == 0 else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether frame `index` of `part` is source frame `wanted`: PSNR at least `floor` and 3 dB better than the
    /// source frames next to it. Returns the line for the report.
    private static func sameFrame(_ part: URL, _ index: Int, _ source: URL, _ wanted: Int, frames: Int, floor: Double = 30,
                                  crop: CGSize? = nil) -> (Bool, String) {
        guard let a = MediaMeasure.frameRGB(part, index: index), let b = MediaMeasure.frameRGB(source, index: wanted, crop: crop) else {
            return (false, "frames don’t decode")
        }
        let match = MediaMeasure.psnr(a, b)
        let others = [wanted - 1, wanted + 1].filter { $0 >= 0 && $0 < frames }
            .compactMap { MediaMeasure.frameRGB(source, index: $0, crop: crop).map { MediaMeasure.psnr(a, $0) } }
        let best = others.max() ?? 0
        return (match >= floor && match > best + 3, "PSNR \(match.isInfinite ? "∞" : f(match)) dB, neighbours \(f(best)) dB")
    }

    /// The timing error (ms) of a tone of `freq` that had phase 0 at the source's 0 s, read from 100 ms of `x`
    /// starting at sample `start`, which should be the source's time `time`. Exact to a fraction of a period.
    private static func toneTimingError(_ x: [Int16], rate: Double, freq: Double, start: Int, time: Double) -> Double? {
        let n = Int(rate * 0.1)
        guard start >= 0, start + n <= x.count else { return nil }
        var s = 0.0, c = 0.0
        for i in 0..<n {
            let w = 2 * Double.pi * freq * Double(i) / rate
            s += Double(x[start + i]) * sin(w)
            c += Double(x[start + i]) * cos(w)
        }
        let error = remainder(atan2(c, s) - 2 * .pi * freq * time, 2 * .pi)
        return error / (2 * .pi * freq) * 1000
    }

    private static func rms(_ x: ArraySlice<Int16>) -> Double {
        sqrt(x.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count)))
    }

    // MARK: The command

    private static func command(_ t: Checker, _ dir: URL) {
        let clip = dir.appendingPathComponent("clip.mp4")
        let sourceFrames = MediaMeasure.frameTimes(clip).count
        do {
            let parts = try MediaSplit.split(clip, options: ["at": "1.2,2.6"]) { _ in }
            defer { remove(parts) }
            let counts = parts.map { MediaMeasure.frameTimes($0).count }
            t.check(parts.map(\.lastPathComponent) == ["clip part 1.mp4", "clip part 2.mp4", "clip part 3.mp4"]
                    && counts == [36, 42, 42] && counts.reduce(0, +) == sourceFrames,
                    "at=1.2,2.6 on clip.mp4: \(parts.map(\.lastPathComponent)), \(counts) frames = \(counts.reduce(0, +)) of \(sourceFrames)")
            for (k, first) in [(1, 36), (2, 78)] where k < parts.count {
                let (ok, line) = sameFrame(parts[k], 0, clip, first, frames: sourceFrames)
                t.check(ok, "part \(k + 1) starts on source frame \(first), the frame at its split (\(line))")
            }
            for (k, last) in [(0, 35), (1, 77)] where k < parts.count && counts[k] > 0 {
                let (ok, line) = sameFrame(parts[k], counts[k] - 1, clip, last, frames: sourceFrames)
                t.check(ok, "part \(k + 1) ends on source frame \(last): nothing repeated or dropped at the split (\(line))")
            }
            let sound = parts.map { Double(MediaMeasure.pcm($0, rate: 44_100, channels: 1).count) / 44_100 }
            t.check(zip(sound, [1.2, 1.4, 1.4]).allSatisfy { near($0, $1, 0.003) } && near(sound.reduce(0, +), 4, 0.005),
                    "the parts’ sound lasts \(sound.map(f)) s, \(f(sound.reduce(0, +))) s in all")
        } catch { t.check(false, "split clip.mp4 at 1.2, 2.6: \(error.localizedDescription)") }

        // The same split as m:ss.ff, out of order and repeated: the same ranges.
        if let s = try? MediaSource.load(clip) {
            let a = try? MediaSplit.parts(s, options: ["at": "1.2,2.6"])
            let b = try? MediaSplit.parts(s, options: ["at": "0:02.60, 0:01.20;1.2"])
            t.check(a != nil && a == b && a?.count == 3 && near(a![1].start, 1.2) && near(a![2].start, 2.6) && a![2].end == 4,
                    "at=0:02.60,0:01.20;1.2 (m:ss.ff, unsorted, repeated) gives the same three parts as at=1.2,2.6")
            let c = try? MediaSplit.parts(s, options: ["at": "1.21"])
            t.check(c.map { near($0[0].end, 1.2) } == true, "a time between frames goes to the nearest frame start (1.21 → \(c.map { f($0[0].end) } ?? "?"))")
            // The older modes are unchanged.
            let thirds = try? MediaSplit.parts(s, options: ["parts": "3"])
            let every = try? MediaSplit.parts(s, options: ["mode": "every", "seconds": "1.5"])
            t.check(thirds?.map(\.end) == [4.0 / 3, 8.0 / 3, 4] && every?.map(\.end) == [1.5, 3, 4],
                    "mode=parts and mode=every as before: \(thirds?.map { f($0.end) } ?? []), \(every?.map { f($0.end) } ?? [])")
        }

        // Sound: a tone keeps its phase at each split and fills each part to its edges.
        let sine = dir.appendingPathComponent("sine.mp4")
        do {
            let parts = try MediaSplit.split(sine, options: ["at": "1.2,2.6"]) { _ in }
            defer { remove(parts) }
            let ranges = [(0.0, 1.2), (1.2, 2.6), (2.6, 4.0)]
            var worst = 0.0, lengthsOK = parts.count == 3, edgesOK = parts.count == 3
            var lengths: [String] = []
            for (k, part) in parts.enumerated() where k < ranges.count {
                let x = MediaMeasure.pcm(part, rate: 48_000, channels: 1)
                let (a, b) = ranges[k]
                lengths.append(f(Double(x.count) / 48_000))
                lengthsOK = lengthsOK && abs(Double(x.count) / 48_000 - (b - a)) < 0.002
                for (start, time) in [(0, a), (x.count - 4800, b - 0.1)] {
                    if let e = toneTimingError(x, rate: 48_000, freq: 440, start: start, time: time) { worst = max(worst, abs(e)) } else { worst = .infinity }
                }
                let middle = rms(x[(x.count / 2)..<(x.count / 2 + 2400)])
                edgesOK = edgesOK && x.count > 4800 && rms(x[0..<240]) > middle * 0.8 && rms(x[(x.count - 240)...]) > middle * 0.8
            }
            t.check(lengthsOK, "sine.mp4 at 1.2, 2.6: the parts’ sound lasts \(lengths) s (1.2, 1.4, 1.4)")
            t.check(worst < 0.1, "the 440 Hz tone is where it was in the source at both ends of every part (worst \(f(worst * 1000)) µs)")
            t.check(edgesOK, "the tone runs right to each part’s edges: no gap or fade at a split")
        } catch { t.check(false, "split sine.mp4: \(error.localizedDescription)") }

        // Sound that starts late stays under its picture: the flash and the burst stay together in part 2.
        let late = dir.appendingPathComponent("late.mp4")
        do {
            let parts = try MediaSplit.split(late, options: ["at": "1.2,2.6"]) { _ in }
            defer { remove(parts) }
            if parts.count == 3, let m = S.flashAndBurst(parts[1]) {
                t.check(near(m.flash, 1.3, 0.017) && abs(m.burst - m.flash) < 0.02,
                        "late.mp4 part 2: the flash at \(f(m.flash)) s, the burst at \(f(m.burst)) s (both were at 2.5 s, 1.3 s into the part)")
            } else { t.check(false, "late.mp4: 3 parts with the flash and burst in part 2") }
        } catch { t.check(false, "split late.mp4: \(error.localizedDescription)") }
    }

    private static func otherFiles(_ t: Checker, _ dir: URL) {
        let wav = dir.appendingPathComponent("tone.wav")
        let source = MediaMeasure.pcm(wav)
        for (at, expected) in [("1.2,2.6", [52_920, 61_740, 105_840]), ("1.23457,2.5", [54_445, 55_805, 110_250]), ("0:00.01,4.99", [441, 219_618, 441])] {
            do {
                let parts = try MediaSplit.split(wav, options: ["at": at]) { _ in }
                defer { remove(parts) }
                let samples = parts.map { MediaMeasure.pcm($0) }
                t.check(samples.map(\.count) == expected && Array(samples.joined()) == source && parts.allSatisfy { Ext.of($0) == "wav" },
                        "tone.wav at=\(at): \(samples.map(\.count)) samples, joined back they are the source exactly")
            } catch { t.check(false, "split tone.wav at=\(at): \(error.localizedDescription)") }
        }
        for (name, floor) in [("odd.mkv", 26.0), ("sample.wmv", 30.0)] {
            let url = dir.appendingPathComponent(name)
            do {
                let s = try MediaSource.load(url)
                let times = MediaMeasure.frameTimes(url)
                let parts = try MediaSplit.split(url, options: ["at": "1.2,2.6"]) { _ in }
                defer { remove(parts) }
                let counts = parts.map { MediaMeasure.frameTimes($0).count }
                // The frames before each split, as the source's own times put them.
                let fd = s.frameDuration
                let firsts = [s.snap(1.2), s.snap(2.6)].map { cut in times.filter { $0 < cut - fd / 2 }.count }
                let expected = [firsts[0], firsts[1] - firsts[0], times.count - firsts[1]]
                t.check(counts == expected && parts.allSatisfy { Ext.of($0) == Ext.of(url) },
                        "\(name) at=1.2,2.6: \(counts) frames = \(counts.reduce(0, +)) of \(times.count), each part a .\(Ext.of(url))")
                if parts.count == 3, let result = try? MediaSource.load(parts[1]) {
                    let crop = result.pixelSize == s.pixelSize ? nil : result.pixelSize
                    let (ok, line) = sameFrame(parts[1], 0, url, firsts[0], frames: times.count, floor: floor, crop: crop)
                    t.check(ok, "\(name) part 2 starts on source frame \(firsts[0]) (\(line))")
                }
            } catch { t.check(false, "split \(name): \(error.localizedDescription)") }
        }
    }

    private static func badTimes(_ t: Checker, _ dir: URL) {
        let clip = dir.appendingPathComponent("clip.mp4")
        let fm = FileManager.default
        let count = { (try? fm.contentsOfDirectory(atPath: dir.path).filter { $0.contains(" part ") }.count) ?? -1 }
        let before = count()
        func bad(_ what: String, _ options: ToolOptions, _ text: String) {
            t.throwsError(what, containing: text) { _ = try MediaSplit.split(clip, options: options) { _ in } }
        }
        bad("at=abc", ["at": "abc"], "“abc” isn’t a time. Give the split times in seconds or as m:ss.ff")
        bad("at=1,x", ["at": "1,x"], "“x” isn’t a time")
        bad("at=0:61", ["at": "0:61"], "“0:61” isn’t a time")
        bad("at=nan", ["at": "nan"], "“nan” isn’t a time")
        bad("at=inf", ["at": "inf"], "“inf” isn’t a time")
        bad("at=-1", ["at": "-1"], "would leave nothing before it")
        bad("at=0", ["at": "0"], "would leave nothing before it")
        bad("at=4 (the end)", ["at": "4"], "is at or past the end of clip.mp4 (0:04.00). Give times before the end.")
        bad("at=9", ["at": "1,9"], "The split at 9 is at or past the end")
        bad("at=0.01 (inside the first frame)", ["at": "0.01"], "leaves a part shorter than one frame")
        bad("at=3.99 (inside the last frame)", ["at": "3.99"], "leaves a part shorter than one frame")
        let many = (1...100).map { MediaTime.arg(Double($0) / 30) }.joined(separator: ",")
        bad("at= 100 times (101 parts)", ["at": many], "That would make 101 parts; Split makes at most 100")
        bad("at= with mode=parts", ["at": "1", "mode": "parts"], "Give either the split times (at=…) or mode=parts, not both")
        bad("mode=at without times", ["mode": "at"], "Give the times to split at")
        bad("mode=halves", ["mode": "halves"], "mode=parts or mode=every")
        t.check(count() == before, "bad split times write nothing")
        if let s = try? MediaSource.load(clip) {
            let edge = try? MediaSplit.parts(s, options: ["at": "0.0333334,3.9666667"])
            t.check(edge?.map(\.length).map { near($0, 1.0 / 30, 1e-6) } == [true, false, true],
                    "one-frame parts at either end are allowed (\(edge?.map { f($0.length) } ?? []))")
            let hundred = try? MediaSplit.parts(s, options: ["at": (1...99).map { MediaTime.arg(Double($0) / 30) }.joined(separator: ",")])
            t.check(hundred?.count == 100, "99 times make 100 parts (\(hundred?.count ?? 0))")
        }
    }

    // MARK: The window

    private static func saveEnabled(_ w: NSWindow) -> Bool? {
        guard let item = w.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "media.save" }) else { return nil }
        return (item.view as? NSControl)?.isEnabled ?? item.isEnabled
    }

    private static func windowBasics(_ t: Checker, _ dir: URL) {
        let clip = dir.appendingPathComponent("clip.mp4")
        t.check(MediaTools.split.present != nil && MediaTools.split.ask == nil && MediaTools.split.run != nil
                && MediaTools.split.title == "Split…" && MediaTools.split.symbol == "rectangle.split.3x1",
                "the Split… petal opens the window (no alert), with the same title and symbol; the command still runs from options")
        do {
            let e = try S.editor(SplitEditorController.self, url: clip, loadLanes: true)
            defer { e.forceClose() }
            let w = e.window, tl = e.timeline!
            let trim = try S.editor(TrimEditorController.self, url: clip)
            t.check(w.title == "clip.mp4" && w.subtitle == "Split" && w.contentMinSize == trim.window.contentMinSize
                    && w.contentMinSize == CGSize(width: 760, height: 540) && e.preview != nil,
                    "window: title clip.mp4, subtitle Split, minimum size \(Int(w.contentMinSize.width)) × \(Int(w.contentMinSize.height)) as Trim’s, a picture")
            t.check(!trim.timeline.showsCuts && (trim.timeline.accessibilityChildren() ?? []).count == 3,
                    "Trim’s timeline shows no cuts and keeps its three VoiceOver elements")
            trim.forceClose()
            t.check(tl.mode == .none && tl.showsCuts && e.cuts.isEmpty && !e.hasChanges && !e.canSave && saveEnabled(w) == false,
                    "a new Split window has no splits and nothing to save (Save disabled)")
            let bar = S.toolbarLayout(w, tools: ["split.add", "split.evenly", "split.remove"])
            t.check(bar.centred && bar.items == ["flex", "split.add", "split.evenly", "split.remove", "flex", "media.undo", "media.redo", "space", "media.save"],
                    "toolbar: Split, Split Evenly and Remove Split centred; Undo, Redo and Save trailing (\(bar.items.joined(separator: " ")))")
            let split = e.splitItem, evenly = e.evenlyItem, remove = e.removeItem
            t.check(split?.label == "Split" && split?.toolTip == "Split at Playhead (⌘B)" && split?.image?.accessibilityDescription == "Split at Playhead",
                    "Split: scissors, “Split”, tooltip “Split at Playhead (⌘B)”, VoiceOver “Split at Playhead”")
            let titles = evenly?.menu.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
            t.check(titles == ["2 Equal Parts", "3 Equal Parts", "4 Equal Parts", "5 Equal Parts", "—", "Every 10 Seconds", "Every 30 Seconds",
                               "Every Minute", "—", "Remove All Splits"] && evenly?.label == "Evenly" && evenly?.image?.accessibilityDescription == "Split Evenly",
                    "Split Evenly: a pull-down labelled “Evenly”: \(titles.joined(separator: " | "))")
            t.check(remove?.label == "Remove Split" && remove?.toolTip == "Remove Selected Split (⌫)" && remove?.isEnabled == false,
                    "Remove Split: trash, “Remove Selected Split (⌫)”, disabled while no split is selected")
            t.check(e.cutField.accessibilityLabel() == "Split at" && e.cutField.labelView.stringValue == "Split at" && !e.cutField.isEnabled && e.summaryLabel.accessibilityLabel() == "Parts"
                    && e.summaryLabel.stringValue == "Press ⌘B to split at the playhead",
                    "transport: the time field (disabled) and “\(e.summaryLabel.stringValue)”")
            if let menu = evenly?.menu {
                e.menuNeedsUpdate(menu)
                let enabled = menu.items.filter { !$0.isSeparatorItem }.map { "\($0.title)=\($0.isEnabled ? "on" : "off")" }
                t.check(menu.items.filter { !$0.isSeparatorItem }.map(\.isEnabled) == [true, true, true, true, false, false, false, false],
                        "a 4 s clip: equal parts available; every 10 s, 30 s, a minute and Remove All not (\(enabled.joined(separator: ", ")))")
            }

            // ⌘B at the playhead.
            var beeps = 0
            e.beep = { beeps += 1 }
            func press(_ c: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> Bool { e.handleKey(S.key(c, keyCode: code, flags: flags, window: w)) }
            e.scrub(to: 1.2)
            _ = press("b", 11, .command)
            t.check(e.cuts.count == 1 && near(e.cuts[0], 1.2) && e.selectedCut == 0 && e.undo.undoActionName == "Split" && e.hasChanges
                    && saveEnabled(w) == true && remove?.isEnabled == true,
                    "⌘B at 1.20 s adds a split there, selects it, is one Undo step “Split”, and enables Save and Remove Split")
            t.check(e.summaryLabel.stringValue == "2 parts · shortest 1.20 s" && e.cutField.stringValue == "0:01.20" && e.cutField.isEnabled,
                    "read-out “\(e.summaryLabel.stringValue)” (a length, as Trim and Bleep write it), Split at \(e.cutField.stringValue)")
            // A paused player can sit part way into a frame: the split goes at the start of the frame on screen.
            e.setPlayhead(2.62, seek: false)
            e.splitItem.map { _ = NSApp.sendAction($0.action!, to: $0.target, from: $0) }
            t.check(e.cuts.count == 2 && near(e.cuts[1], 2.6), "Split (toolbar) with the playhead at 2.62 s splits at 2.60 s, the start of the frame on screen")
            t.check(tl.cuts == e.cuts && tl.selectedCut == 1 && e.summaryLabel.stringValue == "3 parts · shortest 1.20 s",
                    "the timeline shows both splits; “\(e.summaryLabel.stringValue)”")
            // On a split, next to one, at the start, at the end.
            e.scrub(to: 2.6)
            _ = press("b", 11, .command)
            t.check(e.cuts.count == 2 && beeps == 1 && e.notice == "There’s already a split at 0:02.60.",
                    "⌘B on a split beeps and says “\(e.notice ?? "")”")
            e.scrub(to: 1.0); e.scrub(to: 2.6)
            t.check(e.notice == nil, "moving the playhead clears the reason")
            e.scrub(to: 0)
            _ = press("b", 11, .command)
            t.check(e.cuts.count == 2 && beeps == 2 && e.notice == "Each part needs at least one frame.", "⌘B at 0:00.00 beeps: “\(e.notice ?? "")”")
            e.setPlayhead(4.0, seek: false)
            _ = press("b", 11, .command)
            t.check(e.cuts.count == 2 && beeps == 3, "⌘B at the very end beeps (the last part would have no frame)")
            e.scrub(to: 2.6 + 1.0 / 30)
            _ = press("b", 11, .command)
            t.check(e.cuts.count == 3 && near(e.cuts[2], 2.6 + 1.0 / 30) && beeps == 3, "⌘B one frame after a split is allowed (a one-frame part)")
            e.performUndo()
            t.check(e.cuts.count == 2 && near(e.cuts[1], 2.6), "Undo removes it again")
            e.scrub(to: 4.0 - 1.0 / 30)
            _ = press("b", 11, .command)
            t.check(e.cuts.count == 3 && near(e.cuts[2], 4.0 - 1.0 / 30), "⌘B on the last frame is allowed (its part is that frame)")
            e.performUndo()

            // Split Evenly: one Undo step each; Remove All.
            e.splitEvenly(.parts(3))
            t.check(e.cuts.count == 2 && near(e.cuts[0], 40.0 / 30) && near(e.cuts[1], 80.0 / 30) && e.selectedCut == nil
                    && e.undo.undoActionName == "Split into 3 Equal Parts" && e.summaryLabel.stringValue == "3 parts · shortest 1.33 s",
                    "3 Equal Parts: splits at frames 40 and 80 (\(e.cuts.map(f))), one Undo step “\(e.undo.undoActionName)”")
            e.performUndo()
            t.check(e.cuts.count == 2 && near(e.cuts[0], 1.2) && near(e.cuts[1], 2.6), "Undo puts the previous splits back")
            e.performRedo()
            t.check(near(e.cuts[0], 40.0 / 30), "Redo splits evenly again")
            e.splitEvenly(.parts(5))
            t.check(e.cuts.count == 4 && near(e.cuts[0], 0.8) && near(e.cuts[3], 3.2), "5 Equal Parts replaces the splits: \(e.cuts.map(f))")
            if let menu = evenly?.menu {
                e.menuNeedsUpdate(menu)
                t.check(menu.items.last?.isEnabled == true, "Remove All Splits is available once there are splits")
            }
            e.splitEvenly(.removeAll)
            t.check(e.cuts.isEmpty && e.undo.undoActionName == "Remove All Splits" && !e.hasChanges && saveEnabled(w) == false,
                    "Remove All Splits: no splits, Save disabled again")
            e.performUndo()
            t.check(e.cuts.count == 4, "Undo brings all four back in one step")
            e.splitEvenly(.every(10))
            t.check(e.cuts.count == 4 && beeps == 4 && e.notice == "clip.mp4 is only 4.00 s long, so parts of 10 seconds would leave it whole.",
                    "Every 10 Seconds on a 4 s clip beeps, changes nothing and says “\(e.notice ?? "")”")
            // Undo all the way back: nothing left, nothing to save.
            while e.undo.canUndo { e.performUndo() }
            t.check(e.cuts.isEmpty && !e.hasChanges, "undoing every step leaves no splits")

            // VoiceOver.
            e.commitCuts([1.2, 2.6], selected: nil, action: "Set")
            let children = tl.accessibilityChildren() ?? []
            let cutElements = children.compactMap { $0 as? MediaTimelineCutAXElement }
            t.check(children.count == 3 && cutElements.map { $0.accessibilityLabel() ?? "" } == ["Split 1", "Split 2"]
                    && cutElements.map { ($0.accessibilityValue() as? String) ?? "" } == ["0:01.20, between parts 1 and 2", "0:02.60, between parts 2 and 3"]
                    && cutElements.allSatisfy { $0.accessibilityRole() == .slider },
                    "VoiceOver: the playhead and two adjustable splits, “Split 1” “\((cutElements.first?.accessibilityValue() as? String) ?? "")” and “Split 2”")
            if cutElements.count == 2 {
                _ = cutElements[1].accessibilityPerformPress()
                t.check(e.selectedCut == 1 && near(e.playhead, 2.6) && cutElements[1].isAccessibilitySelected(), "pressing “Split 2” selects it and shows its frame")
                _ = cutElements[0].accessibilityPerformIncrement()
                t.check(near(e.cuts[0], 1.2 + 1.0 / 30) && e.selectedCut == 0 && e.undo.undoActionName == "Move Split",
                        "incrementing “Split 1” moves it one frame (\(f(e.cuts[0]))), one Undo step")
                _ = cutElements[0].accessibilityPerformDecrement()
                t.check(near(e.cuts[0], 1.2), "decrementing moves it back")
                let frame = tl.cutHitRect(e.cuts[0])
                t.check(frame.width >= 20 && frame.height >= 20, "a split’s handle grabs \(Int(frame.width)) × \(Int(frame.height)) pt")
            }
            // Typing the selected split’s time.
            e.selectCut(0)
            e.cutField.stringValue = "2.0"
            e.cutField.sendAction(e.cutField.action, to: e.cutField.target)
            t.check(near(e.cuts[0], 2.0) && e.undo.undoActionName == "Move Split" && near(e.playhead, 2.0), "typing 2.0 moves the selected split to 2.00 s")
            let beepsBefore = beeps
            e.cutField.stringValue = "abc"
            e.cutField.sendAction(e.cutField.action, to: e.cutField.target)
            t.check(near(e.cuts[0], 2.0) && e.cutField.stringValue == "0:02.00" && beeps == beepsBefore + 1, "“abc” beeps and is put back")
            e.cutField.stringValue = "3.0"
            e.cutField.sendAction(e.cutField.action, to: e.cutField.target)
            t.check(near(e.cuts[0], 2.0) && e.cutField.stringValue == "0:02.00" && beeps == beepsBefore + 2, "a time past the next split beeps and is put back")
            e.cutField.stringValue = "0:02.57"
            e.cutField.sendAction(e.cutField.action, to: e.cutField.target)
            t.check(near(e.cuts[0], 77.0 / 30), "0:02.57 goes on the nearest frame, one before the next split (\(f(e.cuts[0])))")
            t.throwsError("Save with no splits", containing: "Add at least one split") {
                let empty = try S.editor(SplitEditorController.self, url: clip)
                defer { empty.forceClose() }
                _ = try empty.makeOptions()
            }
        } catch { t.check(false, "Split window: \(error.localizedDescription)") }

        let view = MediaTools.snapshot("split", files: [clip], options: ["at": "1.2,2.6", "selected": "1"])
        let size = (view as? NSImageView)?.image?.size ?? .zero
        t.check(size.width >= 1000 && size.height >= 660, "the split snapshot renders the whole window (\(Int(size.width)) × \(Int(size.height)))")
    }

    private static func windowDrag(_ t: Checker, _ dir: URL) {
        let clip = dir.appendingPathComponent("clip.mp4")
        do {
            let e = try S.editor(SplitEditorController.self, url: clip, loadLanes: true)
            defer { e.forceClose() }
            var beeps = 0
            e.beep = { beeps += 1 }
            let tl = e.timeline!
            e.commitCuts([1.2, 2.6], selected: nil, action: "Set")
            e.undo.removeAllActions()
            // Splits are grabbed in the lanes (the film strip here) or by their tab under the lanes; the ruler scrubs.
            let ruler: CGFloat = 14, strip: CGFloat = 50, lanes = strip
            let grab = strip
            // Press a split and drag it: it lands on the start of the frame under the pointer.
            S.drag(tl, from: CGPoint(x: tl.x(1.2), y: grab), to: CGPoint(x: tl.x(2.025), y: grab))
            t.check(near(e.cuts[0], 2.0) && e.selectedCut == 0 && e.undo.undoActionName == "Move Split" && near(e.playhead, 2.0),
                    "dragging Split 1 to 2.025 s puts it on 2.000 s, the start of the frame there (\(f(e.cuts[0]))), selected, playhead on it")
            // Grabbed off-centre, it keeps the offset.
            S.drag(tl, from: CGPoint(x: tl.x(2.0) + 6, y: grab), to: CGPoint(x: tl.x(1.5) + 6, y: grab))
            t.check(near(e.cuts[0], 1.5), "a handle grabbed 6 pt off its line keeps that offset (\(f(e.cuts[0])))")
            // Never past a neighbour, never closer than a frame; never within a frame of either end.
            S.drag(tl, from: CGPoint(x: tl.x(1.5), y: grab), to: CGPoint(x: tl.x(3.6), y: grab))
            t.check(near(e.cuts[0], 2.6 - 1.0 / 30) && e.cuts.count == 2, "dragged past Split 2 it stops a frame before it (\(f(e.cuts[0])))")
            S.drag(tl, from: CGPoint(x: tl.x(e.cuts[0]), y: grab), to: CGPoint(x: tl.x(0) - 30, y: grab))
            t.check(near(e.cuts[0], 1.0 / 30), "dragged off the start it stops after the first frame (\(f(e.cuts[0])))")
            S.drag(tl, from: CGPoint(x: tl.x(2.6), y: grab), to: CGPoint(x: tl.x(4.0) + 30, y: grab))
            t.check(near(e.cuts[1], 4.0 - 1.0 / 30), "dragged off the end it stops on the last frame (\(f(e.cuts[1])))")
            e.performUndo(); e.performUndo()
            t.check(near(e.cuts[0], 2.6 - 1.0 / 30) && near(e.cuts[1], 2.6), "each drag is one Undo step")
            // Esc during a drag puts it back.
            S.drag(tl, from: CGPoint(x: tl.x(2.6), y: grab), to: CGPoint(x: tl.x(3.2), y: grab)) {
                _ = e.handleKey(S.key("\u{1b}", keyCode: S.Code.escape, window: e.window))
            }
            t.check(near(e.cuts[1], 2.6) && !tl.isDragging && e.undo.undoActionName == "Move Split", "Esc during a drag puts the split back")
            // Clicks: the lanes move the playhead and let go of the split; the ruler away from a handle only scrubs.
            e.selectCut(1)
            S.drag(tl, from: CGPoint(x: tl.x(0.5), y: ruler), to: CGPoint(x: tl.x(0.5), y: ruler))
            t.check(near(e.playhead, 0.5) && e.selectedCut == 1, "a click in the ruler moves the playhead and keeps the selection")
            S.drag(tl, from: CGPoint(x: tl.x(3.0), y: lanes), to: CGPoint(x: tl.x(3.0), y: lanes))
            t.check(near(e.playhead, 3.0) && e.selectedCut == nil && e.removeItem?.isEnabled == false,
                    "a click on the film strip moves the playhead and lets go of the split")
            // A click on a split selects it without moving it.
            S.drag(tl, from: CGPoint(x: tl.x(2.6) + 1, y: grab), to: CGPoint(x: tl.x(2.6) + 1, y: grab))
            t.check(e.selectedCut == 1 && near(e.cuts[1], 2.6) && near(e.playhead, 2.6), "a click on a split in the film strip selects it and shows its frame")
            t.check(beeps == 0, "no beeps along the way")
        } catch { t.check(false, "Split window drags: \(error.localizedDescription)") }
    }

    private static func windowKeys(_ t: Checker, _ dir: URL) {
        let clip = dir.appendingPathComponent("clip.mp4")
        do {
            let e = try S.editor(SplitEditorController.self, url: clip)
            defer { e.forceClose() }
            var beeps = 0
            e.beep = { beeps += 1 }
            let w = e.window
            func press(_ c: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> Bool { e.handleKey(S.key(c, keyCode: code, flags: flags, window: w)) }
            e.scrub(to: 1.2); _ = press("b", 11, .command)
            e.scrub(to: 2.6); _ = press("b", 11, .command)
            e.scrub(to: 1.8)
            // ↑ ↓: previous and next split, then the start and the last frame.
            var stops: [String] = []
            for _ in 0..<3 { _ = press("\u{F701}", 125); stops.append(f(e.playhead)) }
            t.check(stops == ["2.600", "3.967", "3.967"] && beeps == 1, "↓ from 1.80 s: \(stops) (the last frame, then a beep)")
            stops = []
            for _ in 0..<4 { _ = press("\u{F700}", 126); stops.append(f(e.playhead)) }
            t.check(stops == ["2.600", "1.200", "0.000", "0.000"] && beeps == 2, "↑: \(stops) (the start, then a beep)")
            // Tab and ⇧Tab cycle the selection, with the playhead on the split.
            e.selectCut(nil)
            _ = press("\t", 48)
            t.check(e.selectedCut == 0 && near(e.playhead, 1.2), "Tab selects Split 1")
            _ = press("\t", 48)
            t.check(e.selectedCut == 1 && near(e.playhead, 2.6), "Tab selects Split 2")
            _ = press("\t", 48)
            t.check(e.selectedCut == 0, "Tab wraps round to Split 1")
            _ = press("\u{19}", 48, .shift)
            t.check(e.selectedCut == 1, "⇧Tab goes back to Split 2")
            // ← → still step frames.
            _ = press("\u{F703}", S.Code.right)
            t.check(near(e.playhead, 2.6 + 1.0 / 30), "→ steps one frame (\(f(e.playhead)))")
            // Esc lets go of the selection; ⌫ with nothing selected beeps; ⌫ and ⌦ remove the selected split.
            _ = press("\u{1b}", S.Code.escape)
            t.check(e.selectedCut == nil, "Esc lets go of the selected split")
            let beepsBefore = beeps
            _ = press("\u{7f}", S.Code.delete)
            t.check(e.cuts.count == 2 && beeps == beepsBefore + 1, "⌫ with no split selected beeps")
            e.selectCut(1)
            _ = press("\u{7f}", S.Code.delete)
            t.check(e.cuts.count == 1 && near(e.cuts[0], 1.2) && e.undo.undoActionName == "Remove Split" && e.selectedCut == nil, "⌫ removes the selected split, one Undo step")
            e.selectCut(0)
            _ = press("\u{F728}", 117)
            t.check(e.cuts.isEmpty, "⌦ removes it too")
            _ = press("z", S.Code.z, .command)
            _ = press("z", S.Code.z, .command)
            t.check(e.cuts.count == 2, "⌘Z twice brings both back")
            _ = press("z", S.Code.z, [.command, .shift])
            t.check(e.cuts.count == 1 && near(e.cuts[0], 1.2), "⇧⌘Z removes one again")
            _ = press("z", S.Code.z, .command)
            // Keys a text field keeps: while the time field is edited, ⌫ and Tab are the field’s; ⌘B leaves it and splits.
            e.selectCut(0)
            if w.makeFirstResponder(e.cutField), w.firstResponder is NSText {
                let deleteTaken = press("\u{7f}", S.Code.delete), tabTaken = press("\t", 48)
                t.check(!deleteTaken && !tabTaken && e.cuts.count == 2 && e.selectedCut == 0, "while the time field is edited, ⌫ and Tab stay with it")
                e.scrub(to: 3.0)
                _ = press("b", 11, .command)
                t.check(e.cuts.count == 3 && !(w.firstResponder is NSText), "⌘B from the field leaves it and splits at the playhead")
            } else { t.check(false, "the time field takes the keyboard focus") }
        } catch { t.check(false, "Split window keys: \(error.localizedDescription)") }
    }

    private static func windowLimits(_ t: Checker, _ dir: URL) {
        let clip = dir.appendingPathComponent("clip.mp4")
        do {
            // 100 parts at most: 99 splits by keyboard, then the 100th is refused.
            let e = try S.editor(SplitEditorController.self, url: clip)
            defer { e.forceClose() }
            var beeps = 0
            e.beep = { beeps += 1 }
            for k in 1...99 {
                e.scrub(to: Double(k) / 30)
                _ = e.handleKey(S.key("b", keyCode: 11, flags: .command, window: e.window))
            }
            t.check(e.cuts.count == 99 && beeps == 0 && e.summaryLabel.stringValue == "100 parts · shortest 0.03 s", "99 splits make 100 parts: “\(e.summaryLabel.stringValue)”")
            e.scrub(to: 110.0 / 30)
            _ = e.handleKey(S.key("b", keyCode: 11, flags: .command, window: e.window))
            t.check(e.cuts.count == 99 && beeps == 1 && e.notice == "Split makes at most 100 parts.", "the 100th split beeps: “\(e.notice ?? "")”")
            if let options = try? e.makeOptions(), let s = try? MediaSource.load(clip) {
                t.check((try? MediaSplit.parts(s, options: options))?.count == 100, "the command takes the window’s 99 splits as 100 parts")
            } else { t.check(false, "Save’s options for 99 splits") }
        } catch { t.check(false, "Split window, 100 parts: \(error.localizedDescription)") }

        // Which Split Evenly items a file allows: a 3-frame clip, and 16 m 50 s of sound (101 parts of 10 s).
        let tiny = MediaSource.parse("Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'x.mp4':\n  Duration: 00:00:00.10, start: 0.000000, bitrate: N/A\n"
                                     + "  Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p(progressive), 320x240 [SAR 1:1 DAR 4:3], "
                                     + "100 kb/s, 30 fps, 30 tbr, 15360 tbn (default)", url: URL(fileURLWithPath: "/nonexistent/tiny.mp4"))
        let three = SplitEditorController(source: tiny, snapshot: true)
        let available = [2, 3, 4, 5].map { three.cuts(for: .parts($0)) != nil }
        t.check(available == [true, true, false, false], "a 3-frame clip: 2 and 3 equal parts available, 4 and 5 not (\(available))")
        three.forceClose()
        let long = MediaSource.parse("Input #0, wav, from 'x.wav':\n  Duration: 00:16:50.00, start: 0.000000, bitrate: N/A\n"
                                     + "  Stream #0:0: Audio: pcm_s16le ([1][0][0][0] / 0x0001), 8000 Hz, mono, s16, 128 kb/s", url: URL(fileURLWithPath: "/nonexistent/long.wav"))
        let a = SplitEditorController(source: long, snapshot: true)
        let every = [10.0, 30, 60].map { a.cuts(for: .every($0))?.count ?? -1 }
        t.check(every == [-1, 33, 16], "16:50 of sound: every 10 s (101 parts) not available; every 30 s 34 parts, every minute 17 (\(every))")
        a.forceClose()
        let oneFrame = MediaSource.parse("Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'x.mp4':\n  Duration: 00:00:00.03, start: 0.000000, bitrate: N/A\n"
                                         + "  Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p(progressive), 320x240, 30 fps, 30 tbr, 15360 tbn",
                                         url: URL(fileURLWithPath: "/nonexistent/one.mp4"))
        t.throwsError("a one-frame clip", containing: "one.mp4 is too short to split") { try SplitEditorController.check(oneFrame) }
    }

    /// Save's options, run through the command as JobRunner runs it, give the same parts as the command line.
    private static func windowSave(_ t: Checker, _ dir: URL) {
        let clip = dir.appendingPathComponent("clip.mp4")
        do {
            let e = try S.editor(SplitEditorController.self, url: clip)
            defer { e.forceClose() }
            e.scrub(to: 1.2); _ = e.handleKey(S.key("b", keyCode: 11, flags: .command, window: e.window))
            e.scrub(to: 2.6); _ = e.handleKey(S.key("b", keyCode: 11, flags: .command, window: e.window))
            let options = try e.makeOptions()
            t.check(options == ["at": "1.200000,2.600000"] && e.command?.id == "split", "Save’s options: \(options), run by --tool split")
            guard let run = e.command?.run else { t.check(false, "the split command runs"); return }
            let saved = try run([clip], options) { _ in }
            defer { remove(saved) }
            let cli = try MediaSplit.split(clip, options: ["at": "1.2,2.6"]) { _ in }
            defer { remove(cli) }
            let same = saved.count == 3 && cli.count == 3 && zip(saved, cli).allSatisfy { a, b in
                ["0:v:0", "0:a:0"].allSatisfy { s in decodedHash(a, s).map { $0 == decodedHash(b, s) } ?? false }
            }
            t.check(same && saved.map(\.lastPathComponent) == ["clip part 1.mp4", "clip part 2.mp4", "clip part 3.mp4"],
                    "the window’s Save writes \(saved.map(\.lastPathComponent)), decoding to the same pictures and sound as --tool split --opt at=1.2,2.6")
        } catch { t.check(false, "Split window save: \(error.localizedDescription)") }
    }

    private static func audioWindow(_ t: Checker, _ dir: URL) {
        let wav = dir.appendingPathComponent("tone.wav")
        do {
            let e = try S.editor(SplitEditorController.self, url: wav, size: CGSize(width: 900, height: 380), loadLanes: true)
            defer { e.forceClose() }
            var beeps = 0
            e.beep = { beeps += 1 }
            let w = e.window
            t.check(e.preview == nil && e.timeline.showsCuts && w.contentMinSize == CGSize(width: 880, height: 320) && w.subtitle == "Split",
                    "the sound-only window: no picture, splits on the waveform, minimum 880 × 320 as Trim’s")
            e.scrub(to: 1.25); _ = e.handleKey(S.key("b", keyCode: 11, flags: .command, window: w))
            e.scrub(to: 0.004); _ = e.handleKey(S.key("b", keyCode: 11, flags: .command, window: w))
            t.check(e.cuts.count == 1 && near(e.cuts[0], 1.25) && beeps == 1 && e.notice == "Each part needs at least 0.01 seconds.", "sound: ⌘B at 0 beeps: “\(e.notice ?? "")”")
            e.scrub(to: 0.01); _ = e.handleKey(S.key("b", keyCode: 11, flags: .command, window: w))
            e.scrub(to: 1.26); _ = e.handleKey(S.key("b", keyCode: 11, flags: .command, window: w))
            t.check(e.cuts.count == 3 && near(e.cuts[0], 0.01) && near(e.cuts[2], 1.26), "sound: splits 0.01 s from the start and from each other are allowed")
            let options = try e.makeOptions()
            let parts = try MediaSplit.split(wav, options: options) { _ in }
            defer { remove(parts) }
            let samples = parts.map { MediaMeasure.pcm($0) }
            t.check(samples.map(\.count) == [441, 54_684, 441, 164_934] && Array(samples.joined()) == MediaMeasure.pcm(wav),
                    "saving them: \(samples.map(\.count)) samples, the source exactly when joined")
        } catch { t.check(false, "Split window for sound: \(error.localizedDescription)") }
    }
}
#endif
