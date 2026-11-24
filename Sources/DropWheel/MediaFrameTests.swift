#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import AVFoundation
import CoreImage

/// `--selftest media-frame`: Crop, Redact and Snapshot for video, measured with ffmpeg and AVFoundation, plus their
/// windows (never shown): keys, drags, Undo, the timeline link and the live preview.
///
/// - Crop: the output has the asked size (even), every frame, the sound, and its pixels are the source region's
///   (PSNR, and better than the neighbouring frames); rotated clips crop upright; odd.mkv's non-square pixels give a
///   square-looking 1:1; other containers stay what they were; bad rectangles throw clear errors.
/// - Redact: inside a box during its range the picture is destroyed (low PSNR against the source, little detail
///   left, black boxes black), outside it and outside its range the picture is the source's; the first and last frames
///   of a range are the right ones (also on wmv, whose frames start at 0.046 s).
/// - Snapshot: the PNG is the exact frame at full size, upright, and its colours match AVFoundation's decoding of the
///   same frame (BT.709 for untagged HD; BT.601 would be far off); rotation and non-square pixels are handled.
enum MediaFrameTests {
    typealias S = MediaTestSupport

    static func run() -> String {
        let t = S.Checker("media-frame")
        guard let ff = FFmpeg.shared else { return "OK media-frame: skipped, ffmpeg isn’t installed" }
        guard let fixtures = S.fixturesFolder() else {
            return "FAIL media-frame: can’t find Tests/fixtures/features. Run from the project folder or set DW_FIXTURES."
        }
        let names = ["clip.mp4", "odd.mkv", "sample.avi", "sample.wmv", "tone.wav"]
        let dir: URL
        do { dir = try S.scratchCopy(of: names, from: fixtures) } catch {
            return "FAIL media-frame: couldn’t copy the fixtures: \(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
        let before = Dictionary(uniqueKeysWithValues: names.map { ($0, MediaMeasure.sha256(url($0))) })

        // A quarter-turned phone-style clip and an anamorphic one (pixels twice as wide as tall), made from clip.mp4.
        let rot = url("rot.mp4"), sar = url("sar.mp4")
        let madeRot = (try? ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-display_rotation:v:0", "90",
                                                        "-i", url("clip.mp4").path, "-c", "copy", rot.path]))?.status == 0
        let madeSar = (try? ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", url("clip.mp4").path, "-t", "2",
                                                        "-vf", "scale=640:720,setsar=2", "-c:v", "libx264", "-crf", "12", "-pix_fmt", "yuv420p",
                                                        "-an", sar.path]))?.status == 0
        // The other two quarter turns, for the live preview's orientation.
        let madeOthers = [("-90", "rotm.mp4"), ("180", "rot180.mp4")].allSatisfy { angle, name in
            (try? ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-display_rotation:v:0", angle,
                                              "-i", url("clip.mp4").path, "-c", "copy", url(name).path]))?.status == 0
        }
        t.check(madeRot && madeSar && madeOthers, "test clips made: turned 90°, −90° and 180° (display matrix) and anamorphic (SAR 2:1)")

        crop(t, url("clip.mp4"), odd: url("odd.mkv"), rot: rot, avi: url("sample.avi"), wmv: url("sample.wmv"), wav: url("tone.wav"))
        redact(t, url("clip.mp4"), odd: url("odd.mkv"), wmv: url("sample.wmv"), rot: rot)
        snapshot(t, url("clip.mp4"), odd: url("odd.mkv"), rot: rot, sar: sar, wmv: url("sample.wmv"))
        cropEditor(t, url("clip.mp4"), odd: url("odd.mkv"), rot: rot)
        redactEditor(t, url("clip.mp4"))
        snapshotEditor(t, url("clip.mp4"))
        livePreview(t, url("clip.mp4"), rot: rot, rotm: url("rotm.mp4"), rot180: url("rot180.mp4"))
        frameOnScreen(t, url("clip.mp4"), dir: dir)
        proxyOnScreen(t, url("sample.wmv"))
        // wmv frame 32 starts at 1.113 s, a third of a millisecond after its step; ntsc.mp4 (made by frameOnScreen)
        // frame 30 at 1.25125 s, just after 30 / 23.98 s.
        stillOnScreen(t, [(url("sample.wmv"), 32), (url("ntsc.mp4"), 30)])
        snapshots(t, url("clip.mp4"))

        for name in names {
            t.check(MediaMeasure.sha256(url(name)) == before[name], "\(name) unchanged")
            t.check(MediaMeasure.sha256(fixtures.appendingPathComponent(name)) == before[name], "fixture \(name) unchanged")
        }
        return t.report
    }

    // MARK: Measuring

    private static func f(_ v: Double) -> String { v.isInfinite ? "∞" : String(format: "%.1f", v) }

    /// Frame `index` cut to `rect` (video pixels, upright as ffmpeg shows it), as packed RGB.
    static func regionRGB(_ url: URL, index: Int, rect: CGRect, bt709: Bool = false, scaledTo: CGSize? = nil) -> [UInt8]? {
        guard let ff = FFmpeg.shared else { return nil }
        let cw = Int(rect.width), ch = Int(rect.height)
        let w = Int(scaledTo?.width ?? rect.width), h = Int(scaledTo?.height ?? rect.height)
        var data = Data()
        let matrix = bt709 ? ":in_color_matrix=bt709" : ""
        let flags = scaledTo == nil ? "bicubic+accurate_rnd+full_chroma_int" : "area"
        let status = MediaKit.runBinary(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", url.path, "-map", "0:v:0",
                                                  "-vf", "select=eq(n\\,\(index)),crop=\(cw):\(ch):\(Int(rect.minX)):\(Int(rect.minY)),scale=\(w):\(h):flags=\(flags)\(matrix),format=rgb24",
                                                  "-frames:v", "1", "-f", "rawvideo", "-"]) { data.append($0) }
        guard status == 0, data.count == w * h * 3 else { return nil }
        return [UInt8](data)
    }

    /// Mean absolute difference of neighbouring pixels (right and below) of the green channel: how much detail is left.
    static func detail(_ rgb: [UInt8], width w: Int, height h: Int) -> Double {
        guard w > 1, h > 1, rgb.count == w * h * 3 else { return 0 }
        var sum = 0.0, n = 0.0
        for y in 0..<(h - 1) {
            for x in 0..<(w - 1) {
                let i = (y * w + x) * 3 + 1
                sum += abs(Double(rgb[i]) - Double(rgb[i + 3])) + abs(Double(rgb[i]) - Double(rgb[i + w * 3]))
                n += 2
            }
        }
        return sum / n
    }

    static func mean(_ rgb: [UInt8]) -> Double { rgb.isEmpty ? 0 : Double(rgb.reduce(0) { $0 + Int($1) }) / Double(rgb.count) }

    /// Mean absolute difference per channel value.
    static func meanAbs(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var s = 0
        for i in 0..<a.count { s += abs(Int(a[i]) - Int(b[i])) }
        return Double(s) / Double(a.count)
    }

    /// A picture's RGB values as stored (drawn in its own colour space, so nothing is colour-converted).
    static func rawRGB(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let base = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { out[i * 3] = p[i * 4]; out[i * 3 + 1] = p[i * 4 + 1]; out[i * 3 + 2] = p[i * 4 + 2] }
        return out
    }

    static func pngSize(_ url: URL) -> CGSize {
        guard let image = MediaKit.loadImage(url) else { return .zero }
        return CGSize(width: image.width, height: image.height)
    }

    // MARK: Crop

    private static func cropCheck(_ t: S.Checker, _ url: URL, _ options: ToolOptions, expect: CGRect, label: String,
                                  frames: [Int] = [0, 45, 119], floor: Double = 35) {
        do {
            let source = try MediaSource.load(url)
            let out = try MediaCrop.crop(url, options: options) { _ in }
            defer { try? FileManager.default.removeItem(at: out) }
            let result = try MediaSource.load(out)
            t.check(out.lastPathComponent == "\(url.deletingPathExtension().lastPathComponent) cropped.\(url.pathExtension)",
                    "\(label): named \(out.lastPathComponent)")
            t.check(result.pixelSize == expect.size && result.rotation == 0,
                    "\(label): \(Int(result.pixelSize.width)) × \(Int(result.pixelSize.height)) upright (expected \(Int(expect.width)) × \(Int(expect.height)))")
            let srcTimes = MediaMeasure.frameTimes(url), outTimes = MediaMeasure.frameTimes(out)
            t.check(outTimes.count == srcTimes.count, "\(label): \(outTimes.count) frames (source \(srcTimes.count))")
            t.check(result.hasAudio == source.hasAudio && abs(result.duration - source.duration) < 0.05,
                    "\(label): \(result.hasAudio ? "sound kept" : "no sound, as the source"), \(String(format: "%.2f", result.duration)) s")
            for i in frames where i < srcTimes.count {
                guard let a = regionRGB(out, index: i, rect: CGRect(origin: .zero, size: expect.size)),
                      let b = regionRGB(url, index: i, rect: expect) else { t.check(false, "\(label): frame \(i) decodes"); continue }
                let match = MediaMeasure.psnr(a, b)
                let near = [i - 1, i + 1].filter { $0 >= 0 && $0 < srcTimes.count }
                    .compactMap { regionRGB(url, index: $0, rect: expect).map { MediaMeasure.psnr(a, $0) } }.max() ?? 0
                t.check(match >= floor && match > near + 3,
                        "\(label): frame \(i) is the source’s region (PSNR \(f(match)) dB, neighbours \(f(near)) dB)")
            }
        } catch {
            t.check(false, "\(label): \(error.localizedDescription)")
        }
    }

    private static func crop(_ t: S.Checker, _ clip: URL, odd: URL, rot: URL, avi: URL, wmv: URL, wav: URL) {
        cropCheck(t, clip, ["x": "100", "y": "60", "w": "640", "h": "360"], expect: CGRect(x: 100, y: 60, width: 640, height: 360), label: "clip.mp4 crop")
        cropCheck(t, clip, ["x": "101", "y": "61", "w": "641", "h": "361"], expect: CGRect(x: 100, y: 60, width: 642, height: 362),
                  label: "clip.mp4 odd crop (made even)", frames: [45])
        cropCheck(t, clip, [:], expect: CGRect(x: 280, y: 0, width: 720, height: 720), label: "clip.mp4 default (centred square)", frames: [45])
        // odd.mkv: 641 × 361, SAR 5776:5769, 4:4:4 (a 4:2:0 re-encode loses colour detail, hence the lower floor).
        cropCheck(t, odd, [:], expect: CGRect(x: 140, y: 0, width: 360, height: 360), label: "odd.mkv default", frames: [25], floor: 26)
        if let source = try? MediaSource.load(odd) {
            let r = MediaCrop.defaultRect(source)
            let shown = r.width * CGFloat(source.pixelAspect) / r.height
            t.check(abs(shown - 1) < 0.005, "odd.mkv: the default crop is square as shown (\(String(format: "%.4f", Double(shown))):1)")
        }
        // A quarter-turned clip crops in its upright picture (720 × 1280).
        cropCheck(t, rot, ["x": "100", "y": "200", "w": "300", "h": "400"], expect: CGRect(x: 100, y: 200, width: 300, height: 400),
                  label: "rotated clip crop", frames: [45])
        for (file, codec) in [(avi, "mpeg4"), (wmv, "wmv2")] {
            do {
                let out = try MediaCrop.crop(file, options: [:]) { _ in }
                defer { try? FileManager.default.removeItem(at: out) }
                let r = try MediaSource.load(out), s = try MediaSource.load(file)
                let srcCount = MediaMeasure.frameTimes(file).count, outCount = MediaMeasure.frameTimes(out).count
                t.check(Ext.of(out) == Ext.of(file) && r.videoCodec == codec && r.pixelSize == CGSize(width: 720, height: 720)
                        && r.audioCodec == s.audioCodec && abs(outCount - srcCount) <= 1,
                        "\(file.lastPathComponent): stays \(Ext.of(out)) (\(r.videoCodec ?? "?") + \(r.audioCodec ?? "?")), 720 × 720, \(outCount) frames (source \(srcCount))")
            } catch { t.check(false, "\(file.lastPathComponent) crop: \(error.localizedDescription)") }
        }
        let count = { (try? FileManager.default.contentsOfDirectory(atPath: clip.deletingLastPathComponent().path).filter { $0.contains(" cropped") }.count) ?? -1 }
        let before = count()
        // A picture smaller than the smallest crop: refused with a reason, by the command and before the window opens.
        let tiny = clip.deletingLastPathComponent().appendingPathComponent("tiny.mp4")
        if let ff = FFmpeg.shared, (try? ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "lavfi",
                                                                        "-i", "testsrc2=size=24x24:rate=25", "-t", "1", "-c:v", "mpeg4", tiny.path]))?.status == 0,
           let source = try? MediaSource.load(tiny) {
            t.throwsError("crop of a 24 × 24 video", containing: "smaller than the smallest crop") { _ = try MediaCrop.crop(tiny, options: [:]) { _ in } }
            t.throwsError("Crop window for a 24 × 24 video", containing: "nothing to crop away") { try CropVideoEditorController.check(source) }
            try? FileManager.default.removeItem(at: tiny)
        } else { t.check(false, "a 24 × 24 test video") }
        t.throwsError("crop width that isn’t a number", containing: "Give the crop as numbers") {
            _ = try MediaCrop.crop(clip, options: ["x": "100", "y": "60", "w": "640px", "h": "360"]) { _ in }
        }
        t.throwsError("crop past the right edge", containing: "goes past the edge") { _ = try MediaCrop.crop(clip, options: ["x": "1000", "w": "400"]) { _ in } }
        t.throwsError("crop too small", containing: "too small") { _ = try MediaCrop.crop(clip, options: ["w": "10", "h": "10"]) { _ in } }
        t.throwsError("crop left of the picture", containing: "can’t start left") { _ = try MediaCrop.crop(clip, options: ["x": "-2"]) { _ in } }
        t.throwsError("crop of a sound file", containing: "has no picture to crop") { _ = try MediaCrop.crop(wav, options: [:]) { _ in } }
        t.check(count() == before, "bad crops write nothing")
    }

    // MARK: Redact

    private static func redact(_ t: S.Checker, _ clip: URL, odd: URL, wmv: URL, rot: URL) {
        let blurBox = CGRect(x: 800, y: 450, width: 320, height: 176), pixBox = CGRect(x: 0, y: 0, width: 112, height: 44)
        let blackBox = CGRect(x: 180, y: 260, width: 300, height: 260), outside = CGRect(x: 520, y: 40, width: 260, height: 200)
        do {
            let boxes = "800,450,320,176,blur,1,2.5;0,0,112,44,pixelate;180,260,300,260,black,0.5,3"
            let out = try MediaRedact.redact(clip, options: ["boxes": boxes]) { _ in }
            defer { try? FileManager.default.removeItem(at: out) }
            let result = try MediaSource.load(out)
            t.check(out.lastPathComponent == "clip redacted.mp4" && result.pixelSize == CGSize(width: 1280, height: 720) && result.hasAudio
                    && MediaMeasure.frameTimes(out).count == 120, "clip.mp4 redact: \(out.lastPathComponent), 1280 × 720, 120 frames, sound kept")
            func psnr(_ i: Int, _ r: CGRect) -> Double {
                guard let a = regionRGB(out, index: i, rect: r), let b = regionRGB(clip, index: i, rect: r) else { return -1 }
                return MediaMeasure.psnr(a, b)
            }
            func detailRatio(_ i: Int, _ r: CGRect) -> Double {
                guard let a = regionRGB(out, index: i, rect: r), let b = regionRGB(clip, index: i, rect: r) else { return 1 }
                return detail(a, width: Int(r.width), height: Int(r.height)) / max(0.001, detail(b, width: Int(r.width), height: Int(r.height)))
            }
            // Blur, 1 s to 2.5 s: frames 30…74 (frame 29 ends at 1.0 s, frame 75 starts at 2.5 s).
            let inside = [30, 45, 74].map { psnr($0, blurBox) }, outsideTimes = [15, 29, 75, 100].map { psnr($0, blurBox) }
            t.check(inside.allSatisfy { $0 >= 0 && $0 < 25 }, "blur box during 1–2.5 s is destroyed (PSNR \(inside.map(f)) dB at frames 30, 45, 74)")
            // The re-encode alone scores about 34 dB on this noisy checkerboard.
            t.check(outsideTimes.allSatisfy { $0 >= 30 } && outsideTimes.min()! > inside.max()! + 15, "blur box outside its time is the source (PSNR \(outsideTimes.map(f)) dB at frames 15, 29, 75, 100)")
            let blurDetail = detailRatio(45, blurBox)
            t.check(blurDetail < 0.25, "blur leaves \(Int(blurDetail * 100)) % of the detail")
            // Pixelate over the time code, whole clip.
            let pix = [0, 60, 119].map { psnr($0, pixBox) }
            t.check(pix.allSatisfy { $0 >= 0 && $0 < 25 }, "pixelated time code is destroyed in every frame (PSNR \(pix.map(f)) dB)")
            if let a = regionRGB(out, index: 60, rect: pixBox), let b = regionRGB(out, index: 61, rect: pixBox),
               let sa = regionRGB(clip, index: 60, rect: pixBox), let sb = regionRGB(clip, index: 61, rect: pixBox) {
                // The source's digits change every frame; pixelated, the change is no more than block averages.
                t.check(MediaMeasure.psnr(a, b) > MediaMeasure.psnr(sa, sb) + 6,
                        "pixelated digits can’t be told apart (frames 60/61: PSNR \(f(MediaMeasure.psnr(a, b))) dB vs \(f(MediaMeasure.psnr(sa, sb))) dB in the source)")
            }
            // Black, 0.5 s to 3 s: frames 15…89.
            let blacks = [15, 45, 89].compactMap { regionRGB(out, index: $0, rect: blackBox).map(mean) }
            t.check(blacks.count == 3 && blacks.allSatisfy { $0 < 2 }, "black box is black during 0.5–3 s (mean \(blacks.map { String(format: "%.2f", $0) }))")
            let notBlack = [14, 90].map { psnr($0, blackBox) }
            t.check(notBlack.allSatisfy { $0 >= 35 }, "black box outside its time is the source (PSNR \(notBlack.map(f)) dB at frames 14, 90)")
            let rest = [0, 45, 119].map { psnr($0, outside) }
            t.check(rest.allSatisfy { $0 >= 35 }, "outside the boxes the picture is the source (PSNR \(rest.map(f)) dB)")
        } catch { t.check(false, "clip.mp4 redact: \(error.localizedDescription)") }

        // Black boxes are drawn last: under a black box, a blur box never shows a blurred copy.
        if let source = try? MediaSource.load(clip) {
            let g = MediaRedact.filterGraph([MediaRedact.Box(rect: CGRect(x: 0, y: 0, width: 200, height: 200), style: .black, start: 0, end: 4),
                                             MediaRedact.Box(rect: CGRect(x: 100, y: 100, width: 200, height: 200), style: .blur, start: 0, end: 4)],
                                            source: source)
            t.check((g.range(of: "drawbox")?.lowerBound ?? g.startIndex) > (g.range(of: "overlay")?.lowerBound ?? g.endIndex),
                    "black boxes are drawn after blurred ones")
        }
        do {
            // Where a black box and a blur box overlap, the result is black (no blurred copy of what's under it).
            let out = try MediaRedact.redact(clip, options: ["boxes": "100,100,200,200,black;150,150,200,200,blur"]) { _ in }
            let m = regionRGB(out, index: 45, rect: CGRect(x: 150, y: 150, width: 150, height: 150)).map(mean) ?? -1
            t.check(m >= 0 && m < 2, "where a black box overlaps a blur box it stays black (mean \(String(format: "%.2f", m)))")
            try? FileManager.default.removeItem(at: out)
        } catch { t.check(false, "overlapping boxes: \(error.localizedDescription)") }

        // wmv: frames start at 0.046 s. A black box from 1 s to 2 s covers frames 28…58 (frame 28 is on screen from
        // 0.979 s to 1.013 s, so part of it is in the range; frame 59 starts at 2.013 s).
        do {
            let box = CGRect(x: 100, y: 100, width: 300, height: 300)
            let out = try MediaRedact.redact(wmv, options: ["boxes": "100,100,300,300,black,1,2"]) { _ in }
            defer { try? FileManager.default.removeItem(at: out) }
            let means = [27, 28, 58, 59].map { regionRGB(out, index: $0, rect: box).map(mean) ?? -1 }
            t.check(Ext.of(out) == "wmv" && MediaMeasure.frameTimes(out).count == 120 && means[0] > 20 && means[1] < 3 && means[2] < 3 && means[3] > 20,
                    "sample.wmv: black 1–2 s covers frames 28…58 exactly (means \(means.map { String(format: "%.1f", $0) }) at 27, 28, 58, 59)")
        } catch { t.check(false, "sample.wmv redact: \(error.localizedDescription)") }
        // A box over frame 30 alone (1.046 s to the next step, as I and O set it): frame 29 starts 33 ms before, exactly
        // where the start's slack ends, and must stay bare in the file as the preview shows it (no tie at the threshold).
        do {
            let box = CGRect(x: 100, y: 100, width: 300, height: 300)
            let source = try MediaSource.load(wmv)
            let b = MediaRedact.Box(rect: box, style: .black, start: source.snap(1.046), end: source.step(1.046, by: 1))
            let out = try MediaRedact.redact(wmv, options: ["boxes": MediaRedact.option([b])]) { _ in }
            defer { try? FileManager.default.removeItem(at: out) }
            let times = MediaMeasure.frameTimes(wmv)
            let covered = (28...31).map { (regionRGB(out, index: $0, rect: box).map(mean) ?? 255) < 3 }
            let preview = (28...31).map { MediaRedact.covers(b, frameAt: times[$0], source: source) }
            t.check(covered == [false, false, true, false] && preview == covered,
                    "sample.wmv: a box over frame 30 alone covers only it, in the file \(covered) and by the preview’s rule \(preview) (frames 28…31)")
        } catch { t.check(false, "sample.wmv one-frame redact: \(error.localizedDescription)") }

        // odd.mkv (odd size, 4:4:4, SAR) and the rotated clip: boxes in the upright pixel grid.
        do {
            let out = try MediaRedact.redact(odd, options: ["boxes": "300,200,200,120,pixelate"]) { _ in }
            defer { try? FileManager.default.removeItem(at: out) }
            let r = try MediaSource.load(out)
            let box = CGRect(x: 300, y: 200, width: 200, height: 120)
            let p = regionRGB(out, index: 25, rect: box).flatMap { a in regionRGB(odd, index: 25, rect: box).map { MediaMeasure.psnr(a, $0) } } ?? 99
            let q = regionRGB(out, index: 25, rect: CGRect(x: 20, y: 20, width: 200, height: 120))
                .flatMap { a in regionRGB(odd, index: 25, rect: CGRect(x: 20, y: 20, width: 200, height: 120)).map { MediaMeasure.psnr(a, $0) } } ?? 0
            t.check(Ext.of(out) == "mkv" && r.pixelSize == CGSize(width: 640, height: 360) && p < 25 && q >= 26,
                    "odd.mkv redact: 640 × 360 mkv, box destroyed (PSNR \(f(p)) dB), elsewhere kept (\(f(q)) dB)")
        } catch { t.check(false, "odd.mkv redact: \(error.localizedDescription)") }
        do {
            let box = CGRect(x: 100, y: 800, width: 400, height: 300)
            let out = try MediaRedact.redact(rot, options: ["boxes": "100,800,400,300,black"]) { _ in }
            defer { try? FileManager.default.removeItem(at: out) }
            let r = try MediaSource.load(out)
            let m = regionRGB(out, index: 45, rect: box).map(mean) ?? -1
            let keep = regionRGB(out, index: 45, rect: CGRect(x: 100, y: 200, width: 400, height: 300))
                .flatMap { a in regionRGB(rot, index: 45, rect: CGRect(x: 100, y: 200, width: 400, height: 300)).map { MediaMeasure.psnr(a, $0) } } ?? 0
            t.check(r.pixelSize == CGSize(width: 720, height: 1280) && r.rotation == 0 && m < 2 && keep >= 35,
                    "rotated clip redact: 720 × 1280 upright, the box in upright pixels is black (mean \(String(format: "%.2f", m))), the rest kept (\(f(keep)) dB)")
        } catch { t.check(false, "rotated redact: \(error.localizedDescription)") }

        // The pixelize-less graph (older ffmpeg) works and pixelates too.
        if let source = try? MediaSource.load(clip), let ff = FFmpeg.shared {
            let box = MediaRedact.Box(rect: CGRect(x: 800, y: 450, width: 320, height: 176), style: .pixelate, start: 0, end: 4)
            let out = clip.deletingLastPathComponent().appendingPathComponent("fallback.mp4")
            do {
                try ff.run(input: clip, output: out, args: ["-t", "1"] + MediaFrameTools.encodeArgs(source, ext: "mp4",
                           filterComplex: MediaRedact.filterGraph([box], source: source, pixelize: false)), duration: 1) { _ in }
                let p = regionRGB(out, index: 10, rect: box.rect).flatMap { a in regionRGB(clip, index: 10, rect: box.rect).map { MediaMeasure.psnr(a, $0) } } ?? 99
                t.check(p < 25, "without the pixelize filter, scaling down and up pixelates (PSNR \(f(p)) dB)")
            } catch { t.check(false, "fallback pixelate: \(error.localizedDescription)") }
            try? FileManager.default.removeItem(at: out)
        }

        // Defaults and errors.
        do {
            let out = try MediaRedact.redact(clip, options: [:]) { _ in }
            let middle = CGRect(x: 320, y: 180, width: 640, height: 360), corner = CGRect(x: 1100, y: 20, width: 160, height: 120)
            let a = regionRGB(out, index: 45, rect: middle).flatMap { x in regionRGB(clip, index: 45, rect: middle).map { MediaMeasure.psnr(x, $0) } } ?? 99
            let b = regionRGB(out, index: 45, rect: corner).flatMap { x in regionRGB(clip, index: 45, rect: corner).map { MediaMeasure.psnr(x, $0) } } ?? 0
            t.check(a < 25 && b >= 35, "default: the middle half is pixelated (PSNR \(f(a)) dB), the corner kept (\(f(b)) dB)")
            try? FileManager.default.removeItem(at: out)
        } catch { t.check(false, "default redact: \(error.localizedDescription)") }
        // A picture smaller than the smallest box: refused with a reason (ffmpeg's crop of a 16-pixel box would fail with
        // its own message), by the command and before the window opens.
        let tiny = clip.deletingLastPathComponent().appendingPathComponent("tiny8.mp4")
        if let ff = FFmpeg.shared, (try? ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "lavfi",
                                                                        "-i", "testsrc2=size=8x8:rate=25", "-t", "1", "-c:v", "mpeg4", tiny.path]))?.status == 0,
           let source = try? MediaSource.load(tiny) {
            t.throwsError("redact of an 8 × 8 video", containing: "smaller than the smallest box") { _ = try MediaRedact.redact(tiny, options: [:]) { _ in } }
            t.throwsError("Redact window for an 8 × 8 video", containing: "smaller than the smallest box") { try RedactVideoEditorController.check(source) }
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: tiny.deletingLastPathComponent().path))?.filter { $0.hasPrefix("tiny8 redacted") } ?? []
            t.check(leftovers.isEmpty, "a refused redact writes nothing")
            try? FileManager.default.removeItem(at: tiny)
        } else { t.check(false, "an 8 × 8 test video") }
        t.throwsError("box with three numbers", containing: "needs four numbers") { _ = try MediaRedact.redact(clip, options: ["boxes": "1,2,3"]) { _ in } }
        t.throwsError("unknown style", containing: "Choose blur, pixelate or black") { _ = try MediaRedact.redact(clip, options: ["boxes": "0,0,100,100,smudge"]) { _ in } }
        t.throwsError("box off the picture", containing: "lies outside the picture") { _ = try MediaRedact.redact(clip, options: ["boxes": "2000,0,100,100"]) { _ in } }
        t.throwsError("start after end", containing: "isn’t before its end") { _ = try MediaRedact.redact(clip, options: ["boxes": "0,0,100,100,black,3,2"]) { _ in } }
        if let source = try? MediaSource.load(clip), let parsed = try? MediaRedact.parse("10,20,30,40,blur,1,2", source: source) {
            let b = parsed[0]
            t.check(b.rect == CGRect(x: 10, y: 20, width: 30, height: 40) && b.style == .blur && b.start == 1 && b.end == 2
                    && (try? MediaRedact.parse(MediaRedact.option(parsed), source: source)) == parsed,
                    "boxes option round trip: \(MediaRedact.option(parsed))")
            let small = (try? MediaRedact.parse("11,11,5,5", source: source))?.first?.rect
            t.check(small.map { $0.width >= MediaRedact.minimumSide && $0.contains(CGRect(x: 11, y: 11, width: 5, height: 5)) && Int($0.minX) % 2 == 0 } ?? false,
                    "a tiny box is widened outward to even pixels: \(small.map { "\($0)" } ?? "nil")")
        }
    }

    // MARK: Snapshot

    private static func snapshot(_ t: S.Checker, _ clip: URL, odd: URL, rot: URL, sar: URL, wmv: URL) {
        do {
            let out = try MediaSnapshot.snapshot(clip, options: ["time": "1.5"]) { _ in }
            t.check(out.lastPathComponent == "clip frame 0-01.50.png" && pngSize(out) == CGSize(width: 1280, height: 720),
                    "clip.mp4 at 1.5 s: \(out.lastPathComponent), \(Int(pngSize(out).width)) × \(Int(pngSize(out).height))")
            if let png = MediaKit.loadImage(out).flatMap(rawRGB),
               let av = MediaKit.avStillFrame(clip, at: 1.5, maxPixels: 4096).flatMap(rawRGB),
               let before = MediaKit.avStillFrame(clip, at: 1.5 - 1.0 / 30, maxPixels: 4096).flatMap(rawRGB),
               let after = MediaKit.avStillFrame(clip, at: 1.5 + 1.0 / 30, maxPixels: 4096).flatMap(rawRGB) {
                let d = meanAbs(png, av), dn = min(meanAbs(png, before), meanAbs(png, after))
                t.check(d < 1.5 && dn > d * 2, "its colours match AVFoundation’s frame 45 (mean difference \(String(format: "%.2f", d)) per value; neighbours \(String(format: "%.2f", dn)))")
                // The colour matrix matters: decoded as BT.601 (ffmpeg's guess for untagged video) it is far off.
                if let rgb601 = regionRGB(clip, index: 45, rect: CGRect(x: 0, y: 0, width: 1280, height: 720)) {
                    let d601 = meanAbs(rgb601, av)
                    t.check(d601 > d * 3 && d601 > 3, "BT.601 would be off by \(String(format: "%.2f", d601)) per value, so the BT.709 rule is what matches")
                }
            } else { t.check(false, "clip.mp4 snapshot: AVFoundation decodes the frame for comparison") }
            let props = CGImageSourceCreateWithURL(out as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
            let png = props?[kCGImagePropertyPNGDictionary as String] as? [String: Any]
            t.check(png?[kCGImagePropertyPNGGamma as String] == nil && png?[kCGImagePropertyPNGChromaticities as String] == nil,
                    "the PNG carries no video colour tags (shown as sRGB, like a frame copied from QuickTime)")
            try? FileManager.default.removeItem(at: out)
            let between = try MediaSnapshot.snapshot(clip, options: ["time": "1.51"]) { _ in }
            t.check(between.lastPathComponent == "clip frame 0-01.50.png", "1.51 s takes the frame on screen then: \(between.lastPathComponent)")
            try? FileManager.default.removeItem(at: between)
            let middle = try MediaSnapshot.snapshot(clip, options: [:]) { _ in }
            t.check(middle.lastPathComponent == "clip frame 0-02.00.png", "no time: the middle of the clip (\(middle.lastPathComponent))")
            let again = try MediaSnapshot.snapshot(clip, options: [:]) { _ in }
            t.check(again.lastPathComponent == "clip frame 0-02.00 2.png", "a second snapshot is \(again.lastPathComponent)")
            for u in [middle, again] { try? FileManager.default.removeItem(at: u) }
        } catch { t.check(false, "clip.mp4 snapshot: \(error.localizedDescription)") }

        // Rotated: upright, as AVFoundation shows it (it applies the track's transform).
        do {
            let out = try MediaSnapshot.snapshot(rot, options: ["time": "1.5"]) { _ in }
            let png = MediaKit.loadImage(out).flatMap(rawRGB), av = MediaKit.avStillFrame(rot, at: 1.5, maxPixels: 4096)
            let d = png.flatMap { p in av.flatMap(rawRGB).map { meanAbs(p, $0) } } ?? .infinity
            t.check(pngSize(out) == CGSize(width: 720, height: 1280) && av?.width == 720 && d < 1.5,
                    "rotated clip: 720 × 1280 upright, matching AVFoundation (mean difference \(String(format: "%.2f", d)))")
            try? FileManager.default.removeItem(at: out)
        } catch { t.check(false, "rotated snapshot: \(error.localizedDescription)") }

        // Anamorphic (640 × 720 stored, SAR 2:1): a 1280 × 720 PNG with square pixels.
        do {
            let out = try MediaSnapshot.snapshot(sar, options: ["time": "1"]) { _ in }
            let ours = MediaKit.loadImage(out).flatMap(rawRGB)
            let reference = regionRGB(sar, index: 30, rect: CGRect(x: 0, y: 0, width: 640, height: 720), bt709: true)
            // Compare at the stored width: squeeze ours back to 640 wide by averaging column pairs.
            var squeezed: [UInt8] = []
            if let ours, ours.count == 1280 * 720 * 3 {
                squeezed.reserveCapacity(640 * 720 * 3)
                for y in 0..<720 { for x in 0..<640 { for c in 0..<3 {
                    squeezed.append(UInt8((Int(ours[(y * 1280 + 2 * x) * 3 + c]) + Int(ours[(y * 1280 + 2 * x + 1) * 3 + c])) / 2))
                } } }
            }
            let p = reference.map { MediaMeasure.psnr(squeezed, $0) } ?? 0
            t.check(pngSize(out) == CGSize(width: 1280, height: 720) && p >= 30,
                    "anamorphic clip: \(Int(pngSize(out).width)) × \(Int(pngSize(out).height)) with square pixels, the same picture (PSNR \(f(p)) dB)")
            try? FileManager.default.removeItem(at: out)
        } catch { t.check(false, "anamorphic snapshot: \(error.localizedDescription)") }

        // odd.mkv: pixels within 1% of square keep their exact values (641 × 361, BT.601 as it is SD and untagged).
        do {
            let out = try MediaSnapshot.snapshot(odd, options: ["time": "1"]) { _ in }
            let ours = MediaKit.loadImage(out).flatMap(rawRGB)
            let ref = regionRGB(odd, index: 25, rect: CGRect(x: 0, y: 0, width: 641, height: 361))
            let p = (ours != nil && ref != nil) ? MediaMeasure.psnr(ours!, ref!) : 0
            t.check(out.lastPathComponent == "odd frame 0-01.00.png" && pngSize(out) == CGSize(width: 641, height: 361) && p >= 40,
                    "odd.mkv at 1 s: 641 × 361, frame 25 exactly (PSNR \(f(p)) dB against ffmpeg’s own decoding)")
            try? FileManager.default.removeItem(at: out)
        } catch { t.check(false, "odd.mkv snapshot: \(error.localizedDescription)") }

        // The end of a wmv (sound runs past the last frame): its last frame, named by its own time.
        do {
            let out = try MediaSnapshot.snapshot(wmv, options: ["time": "4.09"]) { _ in }
            let ours = MediaKit.loadImage(out).flatMap(rawRGB)
            let full = CGRect(x: 0, y: 0, width: 1280, height: 720)
            let ref = regionRGB(wmv, index: 119, rect: full, bt709: true), prev = regionRGB(wmv, index: 118, rect: full, bt709: true)
            let p = (ours != nil && ref != nil) ? MediaMeasure.psnr(ours!, ref!) : 0
            let q = (ours != nil && prev != nil) ? MediaMeasure.psnr(ours!, prev!) : 99
            t.check(out.lastPathComponent == "sample frame 0-04.01.png" && p >= 40 && p > q + 3,
                    "sample.wmv at its end: \(out.lastPathComponent), the last frame (PSNR \(f(p)) dB, frame 118 \(f(q)) dB)")
            try? FileManager.default.removeItem(at: out)
        } catch { t.check(false, "wmv snapshot: \(error.localizedDescription)") }

        t.throwsError("negative time", containing: "Give the time in seconds") { _ = try MediaSnapshot.snapshot(clip, options: ["time": "-1"]) { _ in } }
        // Part way into a frame (where a pause leaves the playhead): the frame on screen then, not the next one.
        if let out = try? MediaSnapshot.snapshot(clip, options: ["time": "1.527"], progress: { _ in }) {
            t.check(out.lastPathComponent == "clip frame 0-01.50.png", "1.527 s (frame 45 is on screen until 1.533 s) takes frame 45: \(out.lastPathComponent)")
            try? FileManager.default.removeItem(at: out)
        } else { t.check(false, "snapshot at 1.527 s") }
        if let out = try? MediaSnapshot.snapshot(clip, options: ["time": "0:01.00"], progress: { _ in }) {
            t.check(out.lastPathComponent == "clip frame 0-01.00.png", "time=0:01.00 is read as a time: \(out.lastPathComponent)")
            try? FileManager.default.removeItem(at: out)
        } else { t.check(false, "snapshot at 0:01.00") }
        t.throwsError("a time that isn’t one", containing: "Give the time in seconds") { _ = try MediaSnapshot.snapshot(clip, options: ["time": "abc"]) { _ in } }
        // A frame held for four seconds (a screen recording's still screen): at 4 s the frame from 1 s is on screen, not
        // the next one at 5 s (ffmpeg drops frames before its seek point, so the two seconds before 4 s hold none).
        let hold = clip.deletingLastPathComponent().appendingPathComponent("hold.mp4")
        if let ff = FFmpeg.shared, (try? ProcessRunner.run(ff.tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "lavfi",
                                                                        "-i", "testsrc2=size=320x240:rate=30", "-t", "8", "-vf", "select=not(between(n\\,31\\,149))",
                                                                        "-fps_mode", "passthrough", "-c:v", "mpeg4", "-q:v", "2", "-an", hold.path]))?.status == 0 {
            defer { try? FileManager.default.removeItem(at: hold) }
            let full = CGRect(x: 0, y: 0, width: 320, height: 240)
            if let out = try? MediaSnapshot.snapshot(hold, options: ["time": "4"], progress: { _ in }) {
                let png = MediaKit.loadImage(out).flatMap(rawRGB)
                let p = png.flatMap { a in regionRGB(hold, index: 30, rect: full).map { MediaMeasure.psnr(a, $0) } } ?? 0
                let q = png.flatMap { a in regionRGB(hold, index: 31, rect: full).map { MediaMeasure.psnr(a, $0) } } ?? 99
                t.check(out.lastPathComponent == "hold frame 0-01.00.png" && p > q + 10,
                        "a frame held from 1 s to 5 s: 4 s takes it (\(out.lastPathComponent), PSNR \(f(p)) dB; the 5 s frame \(f(q)) dB)")
                try? FileManager.default.removeItem(at: out)
            } else { t.check(false, "snapshot in a held frame") }
        } else { t.check(false, "a test clip with a held frame") }
        t.throwsError("time past the end", containing: "past the end of clip.mp4") { _ = try MediaSnapshot.snapshot(clip, options: ["time": "9"]) { _ in } }
    }

    // MARK: Windows

    private static func key(_ e: MediaEditorWindowController, _ c: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> Bool {
        e.handleKey(S.key(c, keyCode: code, flags: flags, window: e.window))
    }

    private static func cropEditor(_ t: S.Checker, _ clip: URL, odd: URL, rot: URL) {
        do {
            let e = try S.editor(CropVideoEditorController.self, url: clip)
            let o = e.overlay
            t.check(!e.hasChanges && !e.canSave && e.state.rect == CGRect(x: 0, y: 0, width: 1280, height: 720) && e.timeline.mode == .none,
                    "a new Crop window keeps the whole picture, Save is off, the timeline only scrubs")
            t.check(o.superview === e.preview?.overlay && o.hitTest(e.preview!.convert(CGPoint(x: e.preview!.pictureRect.midX, y: e.preview!.pictureRect.minY - 8), to: o.superview)) === o,
                    "the crop overlay takes presses on the picture and just outside it (handle reach)")
            e.setAspect(.square)
            t.check(e.state.rect == CGRect(x: 280, y: 0, width: 720, height: 720) && e.hasChanges && e.canSave,
                    "1:1 makes the largest centred square: \(e.state.rect)")
            let options = try e.makeOptions()
            t.check(options == ["x": "280", "y": "0", "w": "720", "h": "720"], "Save’s options: \(options)")
            // Drag the bottom-right corner up and left: the square stays square.
            let r = o.viewRect(e.state.rect)
            S.drag(o, from: CGPoint(x: r.maxX - 3, y: r.maxY - 3), to: CGPoint(x: r.maxX - 120, y: r.maxY - 60))
            let s = e.state.rect
            t.check(s.width == s.height && s.width < 720 && s.minX == 280 && s.minY == 0 && Int(s.width) % 2 == 0 && e.undo.undoActionName == "Resize Crop",
                    "dragging a corner keeps 1:1 and the opposite corner: \(s)")
            // Drag inside: moves, stopped at the picture's edge.
            let m = o.viewRect(s)
            S.drag(o, from: CGPoint(x: m.midX, y: m.midY), to: CGPoint(x: m.midX + 2000, y: m.midY + 2000))
            t.check(e.state.rect.maxX == 1280 && e.state.rect.maxY == 720 && e.state.rect.size == s.size, "dragging inside moves it to the edge: \(e.state.rect)")
            // Esc during a drag puts it back.
            let held = e.state.rect, h = o.viewRect(held)
            S.drag(o, from: CGPoint(x: h.midX, y: h.midY), to: CGPoint(x: h.midX - 200, y: h.midY)) { _ = key(e, "\u{1b}", 53) }
            t.check(e.state.rect == held && !o.isDragging, "Esc during a drag cancels it")
            e.performUndo()
            t.check(e.state.rect == s, "Undo puts the move back")
            _ = key(e, "\u{F702}", 123, [.option])
            t.check(e.state.rect.minX == s.minX - 2, "⌥← moves the crop 2 pixels")
            _ = key(e, "\u{F702}", 123, [.option, .shift])
            t.check(e.state.rect.minX == s.minX - 22, "⇧⌥← moves it 20 more")
            let p0 = e.playhead
            _ = key(e, "\u{F703}", 124)
            t.check(abs(e.playhead - p0 - 1.0 / 30) < 1e-6 && e.state.rect.minX == s.minX - 22,
                    "→ without ⌥ steps a frame, the crop stays (\(String(format: "%.4f", p0)) → \(String(format: "%.4f", e.playhead)), x \(e.state.rect.minX))")
            e.reset()
            t.check(!e.hasChanges && e.state.aspect == .free, "Reset keeps the whole picture again")
            e.performUndo()
            t.check(e.state.rect.minX == s.minX - 22, "Undo brings the crop back after Reset")
            // Free: draw a new frame by dragging outside the current one.
            e.setAspect(.free)
            e.reset()
            e.setAspect(.wide16x9)
            let full = o.viewRect(e.state.rect)
            t.check(e.state.rect == CGRect(x: 0, y: 0, width: 1280, height: 720), "16:9 on a 16:9 clip is the whole picture")
            e.setAspect(.free)
            _ = full
            e.commit(.init(rect: CGRect(x: 200, y: 100, width: 400, height: 300), aspect: .free), action: "Test")
            let small = o.viewRect(e.state.rect)
            S.drag(o, from: CGPoint(x: small.maxX + 40, y: small.maxY + 40), to: CGPoint(x: small.maxX + 240, y: small.maxY + 140))
            t.check(e.state.rect.minX > 600 && e.state.rect.width > 300 && e.undo.undoActionName == "Draw Crop", "a drag outside the frame draws a new one: \(e.state.rect)")
            // The size read-out and saving through the command.
            let out = try MediaCrop.crop(clip, options: try e.makeOptions()) { _ in }
            let made = try MediaSource.load(out)
            t.check(made.pixelSize == e.state.rect.size, "saving the window’s crop writes \(Int(made.pixelSize.width)) × \(Int(made.pixelSize.height))")
            try? FileManager.default.removeItem(at: out)
            e.forceClose()

            // odd.mkv: 1:1 is square on screen, so a little narrower in its slightly wide pixels.
            let d = try S.editor(CropVideoEditorController.self, url: odd)
            d.setAspect(.square)
            let v = d.overlay.viewRect(d.state.rect)
            t.check(d.state.rect.size == CGSize(width: 360, height: 360) && abs(v.width / v.height - 1) < 0.01,
                    "odd.mkv 1:1: \(Int(d.state.rect.width)) × \(Int(d.state.rect.height)) pixels drawn \(String(format: "%.3f", Double(v.width / v.height))):1")
            d.forceClose()
            // Rotated: the crop lives in the upright 720 × 1280 grid and the picture is portrait.
            let q = try S.editor(CropVideoEditorController.self, url: rot)
            t.check(q.state.rect.size == CGSize(width: 720, height: 1280) && (q.preview?.pictureRect.height ?? 0) > (q.preview?.pictureRect.width ?? 1),
                    "rotated clip: the Crop window works on the upright 720 × 1280 picture")
            q.forceClose()
        } catch { t.check(false, "Crop window: \(error.localizedDescription)") }
    }

    private static func redactEditor(_ t: S.Checker, _ clip: URL) {
        // The window remembers the last style; leave the user's choice as it was.
        let remembered = ImageExtras.remembered("media-redact")
        defer { ImageExtras.remember(remembered, as: "media-redact") }
        do {
            let e = try S.editor(RedactVideoEditorController.self, url: clip)
            let o = e.overlay, tl = e.timeline!
            t.check(e.boxes.isEmpty && !e.hasChanges && !tl.showsRanges,
                    "a new Redact window has no boxes and no range on the timeline")
            t.check((e.content.preview as? MediaRedactBody)?.inspector === e.inspector && e.inspector.frame.width == MediaRedactBody.inspectorWidth,
                    "the inspector sits beside the picture (\(Int(e.inspector.frame.width)) pt)")
            // Draw a box over the time code.
            let a = o.viewRect(CGRect(x: 0, y: 0, width: 1, height: 1)).origin, b = o.viewRect(CGRect(x: 120, y: 50, width: 1, height: 1)).origin
            S.drag(o, from: a, to: b)
            t.check(e.boxes.count == 1 && e.selected == 0 && e.boxes[0].start == 0 && e.boxes[0].end == 4 && e.hasChanges && tl.showsRanges,
                    "dragging on the picture adds a box for the whole clip, selected, its range on the timeline")
            let r0 = e.boxes[0].rect
            t.check(r0.minX == 0 && r0.minY == 0 && r0.width >= 120 && r0.height >= 50 && Int(r0.width) % 2 == 0,
                    "the new box covers what was dragged, on even pixels: \(r0)")
            // Style from the inspector (a different one from what the new box got).
            let target: MediaRedact.Style = e.boxes[0].style == .black ? .pixelate : .black
            e.inspector.styleControl.selectedSegment = MediaRedact.Style.allCases.firstIndex(of: target)!
            _ = e.inspector.styleControl.sendAction(e.inspector.styleControl.action, to: e.inspector.styleControl.target)
            t.check(e.boxes[0].style == target && e.undo.undoActionName == "Change Style", "the inspector’s Style sets \(target.title)")
            // I and O set the box's time from the playhead; the timeline shows it.
            e.scrub(to: 1.0); _ = key(e, "i", S.Code.i)
            e.scrub(to: 2.0); _ = key(e, "o", S.Code.o)
            t.check(abs(e.boxes[0].start - 1) < 1e-6 && abs(e.boxes[0].end - (2 + 1.0 / 30)) < 1e-6 && e.ranges.first == e.boxes[0].range,
                    "I and O: the box covers \(MediaTime.string(e.boxes[0].start))–\(MediaTime.string(e.boxes[0].end)), shown on the timeline")
            t.check(e.inspector.startField.stringValue == "0:01.00" && e.inspector.endField.stringValue == "0:02.03", "the inspector shows the times")
            // Drag the range's start handle on the timeline.
            let y = tl.bounds.height / 2
            S.drag(tl, from: CGPoint(x: tl.x(1.0) - 4, y: y), to: CGPoint(x: tl.x(0.5) - 4, y: y))
            t.check(abs(e.boxes[0].start - 0.5) < 1e-6 && e.undo.undoActionName == "Change Start", "dragging the timeline’s start handle moves the box’s start to 0.5 s")
            e.performUndo()
            t.check(abs(e.boxes[0].start - 1) < 1e-6, "Undo puts it back")
            // The playhead outside the range: the box isn't active then.
            e.scrub(to: 3.0)
            t.check(!e.boxes[0].isActive(at: e.playhead) && o.playhead == 3.0, "at 3 s the box is outside its range (drawn as an outline)")
            // A second box from the + button, then select the first in the list, delete, undo.
            e.inspector.addButton.performClick(nil)
            t.check(e.boxes.count == 2 && e.selected == 1 && e.boxes[1].style == target, "+ adds a box in the middle (with the last style)")
            e.inspector.table.selectRowIndexes([0], byExtendingSelection: false)
            t.check(e.selected == 0 && e.ranges.first == e.boxes[0].range, "selecting a row selects its box and shows its range")
            _ = key(e, "\u{7f}", S.Code.delete)
            t.check(e.boxes.count == 1 && e.boxes[0].rect != r0, "⌫ deletes the selected box")
            e.performUndo()
            t.check(e.boxes.count == 2 && e.boxes[0].rect == r0, "Undo brings it back")
            _ = key(e, "\u{1b}", S.Code.escape)
            t.check(e.selected == nil && !tl.showsRanges, "Esc deselects; the timeline hides the range")
            // VoiceOver: each box is an element with its number, style, size and time; pressing one selects it.
            let ax = (o.accessibilityChildren() ?? []).compactMap { $0 as? MediaBoxAXElement }
            t.check(ax.count == 2 && (ax[0].accessibilityLabel() ?? "").hasPrefix("Box 1, ") && ((ax[1].accessibilityValue() as? String) ?? "").contains("pixels"),
                    "VoiceOver lists the boxes: \(ax.compactMap { $0.accessibilityLabel() })")
            _ = ax.last?.accessibilityPerformPress()
            t.check(e.selected == 1, "pressing a box’s VoiceOver element selects it")
            // Move the second box with the mouse, and with ⌥→.
            let box1 = o.viewRect(e.boxes[1].rect)
            S.drag(o, from: CGPoint(x: box1.midX, y: box1.midY), to: CGPoint(x: box1.midX + 50, y: box1.midY + 30))
            t.check(e.selected == 1 && e.boxes[1].rect.minX > CGFloat(1280 / 3) && e.undo.undoActionName == "Move Box", "dragging a box selects and moves it")
            let x1 = e.boxes[1].rect.minX, p1 = e.playhead
            _ = key(e, "\u{F703}", 124, [.option])
            t.check(e.boxes[1].rect.minX == x1 + 2, "⌥→ moves it 2 pixels")
            _ = key(e, "\u{F703}", 124)
            t.check(e.boxes[1].rect.minX == x1 + 2 && abs(e.playhead - p1 - 1.0 / 30) < 1e-6, "→ alone steps a frame and leaves the box")
            // Full Keyboard Access: Tab moves the focus to the inspector's controls, and Space presses them (← → move along
            // the Style control). The editor must hand those keys on instead of playing or stepping frames. (Without
            // Full Keyboard Access, AppKit's button ignores Space offscreen, so the press itself isn't measured here.)
            if e.window.makeFirstResponder(e.inspector.addButton) {
                let p0 = e.playhead
                t.check(!e.handleKey(S.key(" ", keyCode: S.Code.space, window: e.window)) && e.playhead == p0,
                        "Space on the focused + button is the button’s (the editor doesn’t take it to play)")
                _ = e.window.makeFirstResponder(e.inspector.styleControl)
                t.check(!e.handleKey(S.key("\u{F703}", keyCode: S.Code.right, window: e.window)) && e.playhead == p0,
                        "→ on the focused Style control is the control’s, not a frame step")
                _ = e.window.makeFirstResponder(nil)
                t.check(key(e, "\u{F703}", S.Code.right) && abs(e.playhead - p0 - 1.0 / 30) < 1e-6, "with nothing focused, → steps a frame again")
                e.scrub(to: p0)
            } else { t.check(false, "the + button takes the keyboard focus") }
            // Save's options run through the command.
            let options = try e.makeOptions()
            let out = try MediaRedact.redact(clip, options: options) { _ in }
            let code = e.boxes[0].rect
            func score(_ i: Int) -> Double {
                regionRGB(out, index: i, rect: code).flatMap { a in regionRGB(clip, index: i, rect: code).map { MediaMeasure.psnr(a, $0) } } ?? -1
            }
            let p15 = score(15), p45 = score(45)
            t.check(p45 >= 0 && p45 < 25 && p15 >= 35, "saving the window’s boxes hides the time code from 1 s (PSNR \(f(p15)) dB at 0.5 s, \(f(p45)) dB at 1.5 s)")
            try? FileManager.default.removeItem(at: out)
            e.forceClose()
        } catch { t.check(false, "Redact window: \(error.localizedDescription)") }

        // The preview draws what the output will be: compare the rendered box with ffmpeg's result.
        do {
            let source = try MediaSource.load(clip)
            guard let still = MediaKit.avStillFrame(clip, at: 1.5, maxPixels: 4096) else { t.check(false, "still for the preview"); return }
            let frame = CIImage(cgImage: still)
            for style in [MediaRedact.Style.pixelate, .blur, .black] {
                let box = MediaRedact.Box(rect: CGRect(x: 800, y: 450, width: 320, height: 176), style: style, start: 0, end: 4)
                let w = 320, h = 176
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: still.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                else { continue }
                // Flipped like the overlay.
                ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                MediaRedactRenderer.draw(box, frame: frame, pixelSize: source.pixelSize, in: CGRect(x: 0, y: 0, width: w, height: h))
                NSGraphicsContext.restoreGraphicsState()
                guard let drawn = ctx.makeImage().flatMap(rawRGB) else { continue }
                let out = try MediaRedact.redact(clip, options: ["boxes": MediaRedact.option([box])]) { _ in }
                let real = regionRGB(out, index: 45, rect: box.rect, bt709: true) ?? []
                let original = regionRGB(clip, index: 45, rect: box.rect, bt709: true) ?? []
                let p = MediaMeasure.psnr(drawn, real), q = MediaMeasure.psnr(drawn, original)
                t.check(p >= 24 && p > q + 8, "the \(style.title) preview looks like the saved result (PSNR \(f(p)) dB; against the unredacted picture \(f(q)) dB)")
                try? FileManager.default.removeItem(at: out)
            }
        } catch { t.check(false, "Redact preview: \(error.localizedDescription)") }
    }

    private static func snapshotEditor(_ t: S.Checker, _ clip: URL) {
        do {
            let e = try S.editor(SnapshotVideoEditorController.self, url: clip)
            let ids = e.window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
            t.check(e.canSave && !e.hasChanges && !ids.contains("media.undo") && ids.contains("media.save") && ids.contains("snapshot.step"),
                    "Snapshot: Save is on, nothing to discard, no Undo/Redo (\(ids.filter { !$0.hasPrefix("NS") }))")
            e.scrub(to: 1.5)
            _ = key(e, "\u{F703}", S.Code.right)
            t.check(abs(e.playhead - (1.5 + 1.0 / 30)) < 1e-6, "→ steps one frame")
            // The toolbar item's menu form (what the overflow menu and VoiceOver's item use) steps back.
            let item = e.window.toolbar?.items.first { $0.itemIdentifier.rawValue == "snapshot.step" }
            if let previous = item?.menuFormRepresentation?.submenu?.items.first, let action = previous.action {
                NSApp.sendAction(action, to: previous.target, from: previous)
            }
            t.check(abs(e.playhead - 1.5) < 1e-6, "Previous Frame steps back")
            let options = try e.makeOptions()
            let out = try MediaSnapshot.snapshot(clip, options: options) { _ in }
            t.check(out.lastPathComponent == "clip frame 0-01.50.png", "Save writes the frame under the playhead: \(out.lastPathComponent)")
            try? FileManager.default.removeItem(at: out)
            e.forceClose()
        } catch { t.check(false, "Snapshot window: \(error.localizedDescription)") }
    }

    // MARK: Live preview (a player, in windows never shown)

    private static func waitUntil(_ timeout: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    /// The Redact preview reads the player's frame, upright: for a rotated clip played directly the frames come out of
    /// the player as stored, and must be turned the way the track says.
    private static func livePreview(_ t: S.Checker, _ clip: URL, rot: URL, rotm: URL, rot180: URL) {
        for (url, size, index) in [(clip, CGSize(width: 1280, height: 720), 45), (rot, CGSize(width: 720, height: 1280), 45),
                                   (rotm, CGSize(width: 720, height: 1280), 45), (rot180, CGSize(width: 1280, height: 720), 45)] {
            do {
                let e = RedactVideoEditorController(source: try MediaSource.load(url), snapshot: false)
                e.window.setContentSize(CGSize(width: 1000, height: 660))
                e.loadPreview()
                guard waitUntil(15, { e.playerReady }) else { t.check(false, "\(url.lastPathComponent): the player gets ready"); e.forceClose(); continue }
                e.addBox(nil)
                e.scrub(to: Double(index) / 30)
                // Wait for the player's frame for that time (earlier buffers may still be queued).
                let target = Double(index) / 30
                _ = waitUntil(5) { e.grabber.playerFrameTime.map { abs($0 - target) < 0.001 } ?? false }
                let frame = abs((e.grabber.playerFrameTime ?? -1) - target) < 0.001 && e.proxyDir == nil ? e.currentFrame() : nil
                guard let frame else { t.check(false, "\(url.lastPathComponent): the preview gets the player’s frame"); e.forceClose(); continue }
                // Compare with ffmpeg's upright decoding, both averaged down by 8 (as ffmpeg's area scaling does).
                let fw = Int(size.width), fh = Int(size.height), w = fw / 8, h = fh / 8
                var pixels = [UInt8](repeating: 0, count: fw * fh * 4)
                MediaRedactRenderer.context.render(frame, toBitmap: &pixels, rowBytes: fw * 4, bounds: frame.extent,
                                                   format: .RGBA8, colorSpace: frame.colorSpace ?? CGColorSpaceCreateDeviceRGB())
                // Core Image writes the top row first.
                var rgb = [UInt8](repeating: 0, count: w * h * 3)
                for y in 0..<h { for x in 0..<w { for c in 0..<3 {
                    var sum = 0
                    for dy in 0..<8 { for dx in 0..<8 { sum += Int(pixels[((y * 8 + dy) * fw + x * 8 + dx) * 4 + c]) } }
                    rgb[(y * w + x) * 3 + c] = UInt8(sum / 64)
                } } }
                guard let ref = regionRGB(url, index: index, rect: CGRect(origin: .zero, size: size), bt709: true, scaledTo: CGSize(width: w, height: h))
                else { t.check(false, "reference frame"); e.forceClose(); continue }
                // The same picture turned over (180°), to show the comparison can tell the orientation apart.
                var turned = [UInt8](repeating: 0, count: w * h * 3)
                for i in 0..<(w * h) { for c in 0..<3 { turned[i * 3 + c] = rgb[(w * h - 1 - i) * 3 + c] } }
                let p = MediaMeasure.psnr(rgb, ref), wrong = MediaMeasure.psnr(turned, ref)
                let near = [index - 1, index + 1].compactMap {
                    regionRGB(url, index: $0, rect: CGRect(origin: .zero, size: size), bt709: true, scaledTo: CGSize(width: w, height: h))
                        .map { MediaMeasure.psnr(rgb, $0) }
                }.max() ?? 99
                t.check(frame.extent.size == size && p >= 24 && p > near + 3 && p > wrong + 20,
                        "\(url.lastPathComponent): the Redact preview reads the player’s frame \(index) upright (\(Int(size.width)) × \(Int(size.height)), "
                        + "PSNR \(f(p)) dB; neighbouring frames \(f(near)) dB, turned over \(f(wrong)) dB)")
                e.forceClose()
            } catch { t.check(false, "\(url.lastPathComponent) live preview: \(error.localizedDescription)") }
        }
    }

    // MARK: The frame on screen (a player, in windows never shown)

    /// When AVFoundation's frame for `time` starts: the frame a paused player shows there.
    private static func avShownTime(_ url: URL, at time: CMTime) -> Double? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let done = DispatchSemaphore(value: 0)
        var shown: Double?
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, _, actual, result, _ in
            if result == .succeeded { shown = actual.seconds }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        return shown
    }

    /// The player can show the frame before the playhead's grid time: a 23.976 fps file (ffmpeg prints "23.98 fps",
    /// so the grid runs early, and the player's time is rounded down), or a frame held longer in variable-rate video.
    /// Redact's preview must never show a frame covered that the saved file leaves bare, I must cover the frame on
    /// screen, and Snapshot must save the frame on screen (also after a pause part way into a frame).
    private static func frameOnScreen(_ t: S.Checker, _ clip: URL, dir: URL) {
        guard let ff = FFmpeg.shared else { return }
        let ntsc = dir.appendingPathComponent("ntsc.mp4"), vfr = dir.appendingPathComponent("vfr.mp4")
        func make(_ out: URL, _ input: [String]) -> Bool {
            for codec in [["-c:v", "libx264", "-g", "12"], ["-c:v", "mpeg4", "-q:v", "2", "-g", "12"]] {
                let args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + input + codec + ["-pix_fmt", "yuv420p", "-an", out.path]
                if (try? ProcessRunner.run(ff.tool, args))?.status == 0 { return true }
            }
            return false
        }
        let madeNTSC = make(ntsc, ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24000/1001", "-t", "3"])
        // Frames 30 and 31 dropped, timestamps kept: frame 29 stays on screen from 0.967 s to 1.067 s.
        let madeVFR = make(vfr, ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30", "-t", "3",
                                 "-vf", "select=not(between(n\\,30\\,31))", "-fps_mode", "passthrough"])
        t.check(madeNTSC && madeVFR, "test clips made: 23.976 fps, and variable rate with a frame held for three")
        let remembered = ImageExtras.remembered("media-redact")
        defer { ImageExtras.remember(remembered, as: "media-redact") }

        for (url, wanted) in [(ntsc, 30.0 / 23.98), (vfr, 1.04)] where madeNTSC && madeVFR {
            let name = url.lastPathComponent
            do {
                let s = try MediaSource.load(url)
                let at = s.snap(wanted)
                let times = MediaMeasure.frameTimes(url)
                let e = RedactVideoEditorController(source: s, snapshot: false)
                defer { e.forceClose() }
                e.window.setContentSize(CGSize(width: 1000, height: 660))
                e.loadPreview()
                guard waitUntil(15, { e.playerReady }) else { t.check(false, "\(name): the player gets ready"); continue }
                e.setStyle(.black)
                e.addBox(CGRect(origin: .zero, size: s.pixelSize))
                e.scrub(to: at)
                // Wait for the player's frame for this time (it has started by the playhead, at most the held frame's
                // three frames before).
                func settled() -> Bool {
                    guard let shown = e.shownFrameTime() else { return false }
                    return shown <= e.playhead + 1e-6 && e.playhead - shown < 3.5 * s.frameDuration
                }
                guard waitUntil(5, settled), let shown = e.shownFrameTime(),
                      let k = times.firstIndex(where: { abs($0 - shown) < 1e-4 }), k > 0 else {
                    t.check(false, "\(name): the preview gets the player’s frame at \(MediaTime.string(at))"); continue
                }
                let full = CGRect(origin: .zero, size: s.pixelSize)
                func blackMeans(_ out: URL) -> (Double, Double) {
                    (regionRGB(out, index: k, rect: full).map(mean) ?? -1, regionRGB(out, index: k - 1, rect: full).map(mean) ?? -1)
                }
                // I at the playhead: the frame on screen is the first one covered.
                _ = key(e, "i", S.Code.i)
                let previewI = e.overlay.isCovering(e.boxes[0])
                let outI = try MediaRedact.redact(url, options: try e.makeOptions()) { _ in }
                let (shownI, beforeI) = blackMeans(outI)
                try? FileManager.default.removeItem(at: outI)
                // The frame before is bare, or covered in the preview too (variable rate: the average frame is longer
                // than these, so the frame of slack reaches it).
                let beforeAgrees = MediaRedact.covers(e.boxes[0], frameAt: times[k - 1], source: s) == (beforeI < 2)
                t.check(previewI && shownI >= 0 && shownI < 2 && beforeI >= 0 && beforeAgrees && (beforeI > 20 || name != "ntsc.mp4"),
                        "\(name): I at \(MediaTime.string(at)) (frame \(k) on screen, from \(String(format: "%.4f", shown)) s) covers that frame "
                        + "in the preview and in the file (mean \(String(format: "%.1f", shownI))); the frame before is "
                        + "\(beforeI < 2 ? "covered" : "bare") in both (mean \(String(format: "%.1f", beforeI)))")
                // A start typed at the grid time: the preview shows what the file will have for the frame on screen.
                e.inspector.onTime?(true, MediaTime.string(at))
                _ = waitUntil(5, settled)
                let previewTyped = e.overlay.isCovering(e.boxes[0])
                let outTyped = try MediaRedact.redact(url, options: try e.makeOptions()) { _ in }
                let (shownTyped, _) = blackMeans(outTyped)
                try? FileManager.default.removeItem(at: outTyped)
                t.check(shownTyped >= 0 && previewTyped == (shownTyped < 2),
                        "\(name): with the start typed as \(MediaTime.string(e.boxes[0].start)), the preview "
                        + "\(previewTyped ? "covers" : "leaves bare") frame \(k), as the file does (mean \(String(format: "%.1f", shownTyped)))")
            } catch { t.check(false, "\(name) redact on screen: \(error.localizedDescription)") }
        }

        // Snapshot saves the frame on screen: at the 23.976 grid time, and after a pause part way into a frame.
        for (url, wanted, snapped) in [(ntsc, 30.0 / 23.98, true), (clip, 1.527, false)] where madeNTSC {
            let name = url.lastPathComponent
            do {
                let s = try MediaSource.load(url)
                let e = SnapshotVideoEditorController(source: s, snapshot: false)
                defer { e.forceClose() }
                e.window.setContentSize(CGSize(width: 1000, height: 660))
                e.loadPreview()
                guard waitUntil(15, { e.playerReady }), let playback = e.playback else { t.check(false, "\(name): the player gets ready"); continue }
                // A pause leaves the playhead where playback stopped, unsnapped: setPlayhead does the same here.
                if snapped { e.scrub(to: wanted) } else { e.setPlayhead(wanted) }
                _ = waitUntil(1.5) { false }
                guard let shown = avShownTime(url, at: playback.player.currentTime()) else { t.check(false, "\(name): AVFoundation’s frame"); continue }
                let out = try MediaSnapshot.snapshot(url, options: try e.makeOptions()) { _ in }
                try? FileManager.default.removeItem(at: out)
                let expected = url.deletingPathExtension().lastPathComponent + MediaSnapshot.suffix(shown) + ".png"
                let index = Int((shown / MediaFrameTools.exactFrameDuration(s)).rounded())
                t.check(out.lastPathComponent == expected && e.frameLabel.stringValue.hasPrefix("Frame \(index) "),
                        "\(name): Save at \(MediaTime.string(e.playhead)) writes the frame on screen (\(out.lastPathComponent), expected \(expected)); "
                        + "the window says “\(e.frameLabel.stringValue.prefix { $0 != " " }) \(index)”")
            } catch { t.check(false, "\(name) snapshot on screen: \(error.localizedDescription)") }
        }
    }

    // MARK: Through a preview proxy

    /// When the frame AVFoundation shows half a millisecond after each of `times` starts (edit lists applied, as the
    /// player plays the file); nil where it shows none.
    private static func avShownTimes(_ url: URL, after times: [Double]) -> [Double?] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 64, height: 64)
        let requests = times.map { NSValue(time: CMTime(seconds: $0 + 0.0005, preferredTimescale: 90_000)) }
        var shown = [Double?](repeating: nil, count: times.count)
        let lock = NSLock(), group = DispatchGroup()
        requests.forEach { _ in group.enter() }
        generator.generateCGImagesAsynchronously(forTimes: requests) { requested, _, actual, result, _ in
            lock.lock()
            if result == .succeeded, let i = requests.firstIndex(where: { $0.timeValue == requested }) { shown[i] = actual.seconds }
            lock.unlock()
            group.leave()
        }
        _ = group.wait(timeout: .now() + 30)
        return shown
    }

    /// A picture averaged down to `size` (whole blocks), as packed RGB, to tell frames apart by what they show.
    private static func averagedRGB(_ image: CIImage, to size: CGSize) -> [UInt8] {
        let fw = Int(image.extent.width), fh = Int(image.extent.height), w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0, fw >= w, fh >= h else { return [] }
        var pixels = [UInt8](repeating: 0, count: fw * fh * 4)
        MediaRedactRenderer.context.render(image, toBitmap: &pixels, rowBytes: fw * 4, bounds: image.extent, format: .RGBA8,
                                           colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB())
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            let y0 = y * fh / h, y1 = (y + 1) * fh / h
            for x in 0..<w {
                let x0 = x * fw / w, x1 = (x + 1) * fw / w
                for c in 0..<3 {
                    var sum = 0
                    for yy in y0..<y1 { for xx in x0..<x1 { sum += Int(pixels[(yy * fw + xx) * 4 + c]) } }
                    rgb[(y * w + x) * 3 + c] = UInt8(sum / ((y1 - y0) * (x1 - x0)))
                }
            }
        }
        return rgb
    }

    /// sample.wmv plays through a preview proxy (AVFoundation can't play wmv). Its frames start at 0.046 s on whole
    /// milliseconds, off the timeline's 1/30 s steps, so the proxy must keep the original's frame times: a proxy re-timed
    /// to 1/30 s shows every frame 13 ms early, and then Redact's preview (which decides from the frame's own time)
    /// showed the frame after a box's end covered while the saved file leaves it bare, and Snapshot saved a frame other
    /// than the one the proxy showed.
    private static func proxyOnScreen(_ t: S.Checker, _ wmv: URL) {
        let name = wmv.lastPathComponent
        let remembered = ImageExtras.remembered("media-redact")
        defer { ImageExtras.remember(remembered, as: "media-redact") }
        do {
            let s = try MediaSource.load(wmv)
            let times = MediaMeasure.frameTimes(wmv)
            let k0 = 30
            guard times.count > k0 + 4 else { t.check(false, "\(name): its frames"); return }
            // The proxy itself: AVFoundation shows each of the original's frames from the original's time.
            let dir = MediaKit.makePreviewFolder()
            defer { try? FileManager.default.removeItem(at: dir) }
            let proxyTimes = avShownTimes(try MediaKit.makeProxy(s, in: dir) { _ in }, after: times)
            let drift = zip(proxyTimes, times).map { shown, time in shown.map { abs($0 - time) } ?? .infinity }.max() ?? .infinity
            t.check(drift < 1e-4, "\(name)’s preview proxy shows every frame from the original’s time (\(times.count) frames; "
                    + "largest difference \(drift.isInfinite ? "–" : String(format: "%.4f", drift)) s)")

            let full = CGRect(origin: .zero, size: s.pixelSize)
            let small = CGSize(width: s.pixelSize.width / 8, height: s.pixelSize.height / 8)
            let refs = ((k0 - 2)...(k0 + 4)).compactMap { k in regionRGB(wmv, index: k, rect: full, bt709: true, scaledTo: small).map { (k, $0) } }
            /// The original's frame a picture shows (the closest of frames 28…34).
            func which(_ image: CIImage) -> Int? {
                let rgb = averagedRGB(image, to: small)
                return refs.max { MediaMeasure.psnr(rgb, $0.1) < MediaMeasure.psnr(rgb, $1.1) }?.0
            }

            // Redact: I and O with frame 30 (1.046 s) on screen, a black box over the whole picture.
            let e = RedactVideoEditorController(source: s, snapshot: false)
            defer { e.forceClose() }
            e.window.setContentSize(CGSize(width: 1000, height: 660))
            e.loadPreview()
            guard waitUntil(60, { e.playerReady }), e.proxyDir != nil else { t.check(false, "\(name): the preview proxy plays"); return }
            func show(_ p: Double) -> (index: Int, time: Double)? {
                e.scrub(to: p)
                _ = waitUntil(1.2) { false }
                guard let frame = e.grabber.playerFrame, let time = e.shownFrameTime(), let k = which(frame) else { return nil }
                return (k, time)
            }
            e.setStyle(.black)
            e.addBox(full)
            let p0 = s.snap(times[k0])
            guard let first = show(p0) else { t.check(false, "\(name): the preview gets the proxy’s frame"); return }
            _ = key(e, "i", S.Code.i)
            _ = key(e, "o", S.Code.o)
            let out = try MediaRedact.redact(wmv, options: try e.makeOptions()) { _ in }
            defer { try? FileManager.default.removeItem(at: out) }
            var covered: [Int: Bool] = [:]
            for k in (k0 - 2)...(k0 + 4) { covered[k] = (regionRGB(out, index: k, rect: full, scaledTo: small).map(mean) ?? 255) < 20 }
            let list = covered.keys.sorted().filter { covered[$0] == true }.map(String.init).joined(separator: ", ")
            t.check(first.index == k0 && list == "\(k0)",
                    "\(name) through the proxy: I and O with frame \(first.index) on screen cover that frame alone in the file (covered: \(list))")
            // Stepping across the box: the preview covers a frame exactly when the file does.
            for step in -1...2 {
                let p = s.step(p0, by: step)
                guard let shown = show(p) else { t.check(false, "\(name): the proxy’s frame at \(MediaTime.string(p))"); continue }
                let preview = e.overlay.isCovering(e.boxes[0])
                t.check(abs(shown.time - times[shown.index]) < 1e-3 && preview == covered[shown.index],
                        "\(name) at \(MediaTime.string(p)): the proxy shows frame \(shown.index) at \(String(format: "%.4f", shown.time)) s "
                        + "(the original’s \(String(format: "%.4f", times[shown.index])) s), and the preview \(preview ? "covers it" : "leaves it bare"); "
                        + "the file \(covered[shown.index] == true ? "covers it" : "leaves it bare"))")
            }

            // Snapshot saves the frame the proxy shows (at 1.11 s that is frame 32, from 1.113 s: the player seeks 1 ms past the
            // playhead, MediaPlayback.videoSeekNudge, so a frame stored in whole milliseconds just after it shows).
            let snap = SnapshotVideoEditorController(source: s, snapshot: false)
            defer { snap.forceClose() }
            snap.window.setContentSize(CGSize(width: 1000, height: 660))
            snap.loadPreview()
            guard waitUntil(60, { snap.playerReady }), let playback = snap.playback, let proxy = snap.proxyDir?.appendingPathComponent("preview.mp4")
            else { t.check(false, "\(name): the Snapshot proxy plays"); return }
            snap.scrub(to: s.step(p0, by: 2))
            _ = waitUntil(1.2) { false }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: proxy))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            guard let image = try? generator.copyCGImage(at: playback.player.currentTime(), actualTime: nil), let k = which(CIImage(cgImage: image))
            else { t.check(false, "\(name): the proxy’s frame for Snapshot"); return }
            let shot = try MediaSnapshot.snapshot(wmv, options: try snap.makeOptions()) { _ in }
            try? FileManager.default.removeItem(at: shot)
            let expected = wmv.deletingPathExtension().lastPathComponent + MediaSnapshot.suffix(times[k]) + ".png"
            t.check(shot.lastPathComponent == expected,
                    "\(name): Save at \(MediaTime.string(snap.playhead)) writes the frame the proxy shows (\(shot.lastPathComponent), expected \(expected))")
        } catch { t.check(false, "\(name) through the proxy: \(error.localizedDescription)") }
    }

    /// Until its player is ready (a proxy being made, or a preview that failed) the Snapshot window shows ffmpeg's still
    /// (MediaKit.stillFrame): the first frame that starts at or after the playhead less a millisecond. On wmv
    /// (millisecond times) and a 23.976 fps grid that is the frame starting just after the playhead, so Save and the
    /// label must take the still's frame then, not the frame the player would show.
    private static func stillOnScreen(_ t: S.Checker, _ files: [(URL, Int)]) {
        for (url, k) in files {
            let name = url.lastPathComponent
            do {
                let s = try MediaSource.load(url)
                let times = MediaMeasure.frameTimes(url)
                guard times.count > k + 2 else { t.check(false, "\(name): its frames"); continue }
                let full = CGRect(origin: .zero, size: s.pixelSize)
                let small = CGSize(width: s.pixelSize.width / 8, height: s.pixelSize.height / 8)
                let refs = ((k - 2)...(k + 2)).compactMap { i in regionRGB(url, index: i, rect: full, bt709: s.pixelSize.height >= 720, scaledTo: small).map { (i, $0) } }
                func which(_ image: CGImage?) -> Int? {
                    guard let image else { return nil }
                    let rgb = averagedRGB(CIImage(cgImage: image), to: small)
                    return refs.max { MediaMeasure.psnr(rgb, $0.1) < MediaMeasure.psnr(rgb, $1.1) }?.0
                }
                // No player (the preview isn't loaded): the still stands in, taken for the playhead as the window takes it.
                let e = SnapshotVideoEditorController(source: s, snapshot: false)
                defer { e.forceClose() }
                e.scrub(to: s.snap(times[k]))
                guard let shown = which(MediaKit.stillFrame(s, at: e.playhead, maxPixels: 1280)) else { t.check(false, "\(name): the still"); continue }
                let out = try MediaSnapshot.snapshot(url, options: try e.makeOptions()) { _ in }
                let saved = which(MediaKit.loadImage(out))
                try? FileManager.default.removeItem(at: out)
                t.check(!e.playerReady && shown == k && saved == shown && out.lastPathComponent.hasSuffix(MediaSnapshot.suffix(times[k]) + ".png")
                        && e.frameLabel.stringValue.hasPrefix("Frame \(shown) "),
                        "\(name): before the player is ready, Save at \(MediaTime.string(e.playhead)) writes the still’s frame \(shown.description) "
                        + "(saved \(saved.map(String.init) ?? "–"), \(out.lastPathComponent)); the window says “\(e.frameLabel.stringValue.prefix { $0 != " " }) \(e.frameIndex)”")
            } catch { t.check(false, "\(name) still: \(error.localizedDescription)") }
        }
    }

    private static func snapshots(_ t: S.Checker, _ clip: URL) {
        for id in ["crop-video", "redact-video", "snapshot-video"] {
            let view = MediaFrameTools.snapshot(id, files: [clip], options: ["playhead": "1.5"])
            let size = (view as? NSImageView)?.image?.size ?? .zero
            t.check(size.width >= 1000 && size.height >= 660, "--snapshot \(id) renders the whole window (\(Int(size.width)) × \(Int(size.height)))")
        }
    }
}
#endif
