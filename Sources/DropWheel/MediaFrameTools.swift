import AppKit

/// Crop…, Redact… and Snapshot… for video: the frame tools, built on the media editor kit (MEDIA_EDITOR_KIT.md).
/// Each opens an editor window in the app and runs from options alone on the command line:
///
///     --tool crop-video   --opt x=280 --opt y=0 --opt w=720 --opt h=720 clip.mp4      → "clip cropped.mp4"
///     --tool redact-video --opt 'boxes=100,80,400,200,blur,1,2.5;700,300,300,240,black' clip.mp4 → "clip redacted.mp4"
///     --tool snapshot     --opt time=1.5 clip.mp4                                     → "clip frame 0-01.50.png"
///
/// Coordinates are video pixels: the picture's pixel grid in display orientation (a quarter-turned phone clip is
/// 1080 × 1920), which is the grid ffmpeg's filters see and the cropped file's own size. For a file with non-square
/// pixels (odd.mkv) it is the stored grid, so a "1:1" crop is square on screen, not in pixels.
///
/// Files: MediaFrameTools.swift (this module, the three commands, option parsing and ffmpeg arguments),
/// MediaFrameBox.swift (box geometry, handles, pointers and the picture the redaction preview reads),
/// MediaCropEditor.swift, MediaRedactEditor.swift, MediaSnapshotEditor.swift (the windows) and MediaFrameTests.swift
/// (`--selftest media-frame`).
enum MediaFrameTools: FeatureModule {
    static var commands: [WheelCommand] { [cropCommand, redactCommand, snapshotCommand] }

    static let cropCommand = WheelCommand(
        wheel: .tools, id: "crop-video", title: "Crop…", symbol: "crop",
        applies: isVideos,
        present: { openEditors($0, editor: CropVideoEditorController.self) },
        run: { files, options, progress in try each(files, progress) { try MediaCrop.crop($0, options: options, progress: $1) } })

    // The image Redact… uses "text.redaction" too; "eye.slash" is Strip Metadata's on every wheel.
    static let redactCommand = WheelCommand(
        wheel: .tools, id: "redact-video", title: "Redact…", symbol: "text.redaction",
        applies: isVideos,
        present: { openEditors($0, editor: RedactVideoEditorController.self) },
        run: { files, options, progress in try each(files, progress) { try MediaRedact.redact($0, options: options, progress: $1) } })

    static let snapshotCommand = WheelCommand(
        wheel: .tools, id: "snapshot", title: "Snapshot…", symbol: "camera",
        applies: isVideos,
        present: { openEditors($0, editor: SnapshotVideoEditorController.self) },
        run: { files, options, progress in try each(files, progress) { try MediaSnapshot.snapshot($0, options: options, progress: $1) } })

    /// Every file is a video and ffmpeg is installed or YummyOrange can get it (file types only: this runs while the wheel opens).
    static func isVideos(_ files: [URL]) -> Bool {
        Capabilities.shared.mediaAvailable && !files.isEmpty && files.allSatisfy { MoreFormats.kind($0) == .video }
    }

    /// Runs `body` on each file, with the progress of file i mapped into its share of the whole.
    private static func each(_ files: [URL], _ progress: @escaping (Double) -> Void,
                             _ body: (URL, @escaping (Double) -> Void) throws -> URL) throws -> [URL] {
        var outputs: [URL] = []
        for (i, file) in files.enumerated() {
            outputs.append(try body(file) { progress((Double(i) + $0) / Double(files.count)) })
        }
        return outputs
    }

    /// Opens the editor for the files that have a picture; a file with only sound (an audio-only .mkv) gets a
    /// message in the HUD instead of an editor with nothing to frame.
    private static func openEditors(_ files: [URL], editor: MediaEditorWindowController.Type) {
        MainThread.async {
            var pictures: [URL] = [], errors: [String] = []
            for url in files {
                if let source = try? MediaSource.load(url), !source.hasVideo {
                    errors.append("\(url.lastPathComponent) has no picture to \(editor.toolName.lowercased()).")
                } else {
                    pictures.append(url)
                }
            }
            if !errors.isEmpty { HUD.shared.flash(errors.joined(separator: " "), isError: true) }
            if !pictures.isEmpty { MediaEditorWindowController.open(pictures, editor: editor) }
        }
    }

    // MARK: Shared checks and encoding

    /// The source, checked for a picture and a length.
    static func videoSource(_ url: URL, verb: String) throws -> MediaSource {
        let source = try MediaSource.load(url)
        guard source.hasVideo else {
            throw ConversionError.unsupported("\(source.name) has no picture to \(verb). Choose a video file.")
        }
        guard source.duration > 0 else {
            throw ConversionError.unsupported("\(source.name) reports no length, so it can’t be edited. Convert it first, then \(verb) the copy.")
        }
        return source
    }

    /// The picture grid cut to even sizes (4:2:0 encoders need them): what an edited copy can hold.
    static func evenGrid(_ source: MediaSource) -> CGRect {
        let size = source.pixelSize
        return CGRect(x: 0, y: 0, width: (size.width / 2).rounded(.down) * 2, height: (size.height / 2).rounded(.down) * 2)
    }

    /// Everything after the input for a re-encode of the first video stream through `videoFilters` (a plain chain)
    /// or `filterComplex` (a graph from [0:v] whose last chain is unlabelled), in the input's own container
    /// (MediaEncode's codecs). The sound is copied when the container doesn't change, otherwise re-encoded.
    static func encodeArgs(_ source: MediaSource, ext: String, videoFilters: [String] = [], filterComplex: String? = nil) -> [String] {
        var args: [String]
        if let filterComplex {
            args = ["-filter_complex", filterComplex + "," + MediaEncode.evenCrop + "[v]", "-map", "[v]"]
        } else {
            args = ["-map", "0:v:0"]
        }
        if source.hasAudio { args += ["-map", "0:a:0"] }
        args += MediaEncode.videoCodecArgs(for: source, ext: ext)
        // ASF would otherwise fill the gap before a late first frame (wmv files start at 0.046 s) with a copy of it.
        if ["wmv", "asf"].contains(ext) { args += ["-fps_mode", "passthrough"] }
        if filterComplex == nil { args += ["-vf", (videoFilters + [MediaEncode.evenCrop]).joined(separator: ",")] }
        if source.hasAudio {
            args += ext == source.ext ? ["-c:a", "copy"] : MediaEncode.audioCodecArgs(for: source, ext: ext)
        } else {
            args += ["-an"]
        }
        args += MediaEncode.containerArgs(ext)
        return args
    }

    static func number(_ v: CGFloat) -> String { String(Int(v.rounded())) }

    /// Option `key` as a number: `fallback` when it is missing or empty, nil when it is there but isn't a number
    /// ("640px", "abc"), so a typo is reported instead of silently replaced by the default.
    static func numberOption(_ options: ToolOptions, _ key: String, _ fallback: Double) -> Double? {
        guard let text = options[key]?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return fallback }
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), v.isFinite else { return nil }
        return v
    }

    /// One frame's length at the file's true rate: ffmpeg prints NTSC rates rounded ("23.98 fps" is 24000/1001), and
    /// over a few hundred frames the rounded rate drifts by a frame. Other rates as `frameDuration`.
    static func exactFrameDuration(_ source: MediaSource) -> Double {
        guard let fps = source.fps else { return source.frameDuration }
        for n in [24.0, 30, 48, 60, 120, 240] where abs(fps - n * 1000 / 1001) < 0.006 { return 1001 / (n * 1000) }
        return source.frameDuration
    }

    // MARK: Snapshots and self-test

    /// `--snapshot crop-video|redact-video|snapshot-video <out.png> <video> [--opt …]`
    /// crop-video: x, y, w, h (video pixels), aspect=Free|Original|1:1|4:5|16:9|9:16|4:3.
    /// redact-video: boxes=x,y,w,h,style,start,end;… (default: two boxes), selected=1-based box (default 1, 0 = none).
    /// snapshot-video: playhead. All: playhead, zoom, width, height, dark=true (the kit's options).
    static func snapshot(_ id: String, files: [URL], options: ToolOptions) -> NSView? {
        let editors: [String: MediaEditorWindowController.Type] = [
            "crop-video": CropVideoEditorController.self, "redact-video": RedactVideoEditorController.self,
            "snapshot-video": SnapshotVideoEditorController.self,
        ]
        guard let editor = editors[id] else { return nil }
        do {
            guard let url = files.first else { throw ConversionError.unsupported("Pass a video file to snapshot.") }
            return try MediaEditorWindowController.snapshotView(editor, url: url, options: options)
        } catch {
            let label = NSTextField(wrappingLabelWithString: "Snapshot failed: \(error.localizedDescription)")
            label.frame = CGRect(x: 0, y: 0, width: 600, height: 80)
            return label
        }
    }

    static func selfTest(_ name: String) -> String? {
        #if DEBUG
        name == "media-frame" ? MediaFrameTests.run() : nil
        #else
        return nil
        #endif
    }
}

// MARK: - Crop

/// Crop… for video: keeps a rectangle of the picture (even pixel values, so 4:2:0 encoders take it) in the file's
/// own format, the sound copied. Writes "<name> cropped.<ext>".
enum MediaCrop {
    /// The aspect presets of the Crop window (width ÷ height as the picture is shown).
    enum Aspect: String, CaseIterable {
        case free = "Free", original = "Original", square = "1:1", portrait4x5 = "4:5", wide16x9 = "16:9",
             tall9x16 = "9:16", classic4x3 = "4:3"

        var title: String { rawValue }

        /// Width ÷ height on screen, nil for Free.
        func ratio(_ source: MediaSource) -> CGFloat? {
            switch self {
            case .free: return nil
            case .original: return source.displayAspect
            case .square: return 1
            case .portrait4x5: return 4.0 / 5
            case .wide16x9: return 16.0 / 9
            case .tall9x16: return 9.0 / 16
            case .classic4x3: return 4.0 / 3
            }
        }

        /// The same ratio in video pixels (a non-square pixel is `pixelAspect` wide).
        func pixelRatio(_ source: MediaSource) -> CGFloat? {
            ratio(source).map { $0 / CGFloat(source.pixelAspect) }
        }

        init?(option: String) {
            let text = option.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "x", with: ":")
            guard let match = Aspect.allCases.first(where: { $0.rawValue.lowercased() == text }) else { return nil }
            self = match
        }
    }

    /// The command line's default: the largest square (as shown) in the middle of the picture.
    static func defaultRect(_ source: MediaSource) -> CGRect {
        let grid = MediaFrameTools.evenGrid(source)
        let ratio = Aspect.square.pixelRatio(source) ?? 1
        var w = grid.width, h = w / ratio
        if h > grid.height { h = grid.height; w = h * ratio }
        w = min(grid.width, max(2, (w / 2).rounded() * 2)); h = min(grid.height, max(2, (h / 2).rounded() * 2))
        return CGRect(x: ((grid.width - w) / 4).rounded(.down) * 2, y: ((grid.height - h) / 4).rounded(.down) * 2, width: w, height: h)
    }

    /// The smallest crop, in video pixels on each side (VideoToolbox refuses tiny pictures).
    static let minimumSide: CGFloat = 32

    /// The crop from options x, y, w, h (video pixels; default `defaultRect`), checked against the picture and made
    /// even: x and y round down, width and height to the nearest even number, inside the even picture grid.
    static func rect(_ options: ToolOptions, source: MediaSource) throws -> CGRect {
        try checkSize(source)
        let grid = MediaFrameTools.evenGrid(source)
        let size = source.pixelSize
        let fallback = defaultRect(source)
        let parsed = [("x", fallback.minX), ("y", fallback.minY), ("w", fallback.width), ("h", fallback.height)].map {
            MediaFrameTools.numberOption(options, $0.0, Double($0.1))
        }
        guard parsed.allSatisfy({ $0 != nil }) else {
            throw ConversionError.unsupported("Give the crop as numbers of pixels, for example x=280 y=0 w=720 h=720.")
        }
        let values = parsed.map { $0! }
        let x = CGFloat(values[0]), y = CGFloat(values[1]), w = CGFloat(values[2]), h = CGFloat(values[3])
        let sizeText = "\(MediaFrameTools.number(size.width)) × \(MediaFrameTools.number(size.height)) pixels"
        guard x >= 0, y >= 0 else {
            throw ConversionError.unsupported("The crop can’t start left of or above the picture. Choose x and y of 0 or more.")
        }
        guard w >= minimumSide, h >= minimumSide else {
            throw ConversionError.unsupported("The crop is too small. Choose a width and height of at least \(Int(minimumSide)) pixels.")
        }
        guard x + w <= size.width + 0.5, y + h <= size.height + 0.5 else {
            throw ConversionError.unsupported("The crop (\(MediaFrameTools.number(w)) × \(MediaFrameTools.number(h)) at "
                + "\(MediaFrameTools.number(x)), \(MediaFrameTools.number(y))) goes past the edge of \(source.name) (\(sizeText)). "
                + "Choose x + w ≤ \(MediaFrameTools.number(size.width)) and y + h ≤ \(MediaFrameTools.number(size.height)).")
        }
        return even(CGRect(x: x, y: y, width: w, height: h), in: grid)
    }

    /// Refuses a picture smaller than the smallest crop (no crop of it fits; the window would place one off the picture).
    static func checkSize(_ source: MediaSource) throws {
        let grid = MediaFrameTools.evenGrid(source)
        guard grid.width < minimumSide || grid.height < minimumSide else { return }
        throw ConversionError.unsupported("\(source.name) is only \(MediaFrameTools.number(source.pixelSize.width)) × "
            + "\(MediaFrameTools.number(source.pixelSize.height)) pixels, smaller than the smallest crop (\(Int(minimumSide)) × \(Int(minimumSide))), "
            + "so there is nothing to crop away. Use the whole video as it is.")
    }

    /// `r` on even pixels inside `grid`: x and y round down, sizes to the nearest even value (at least the minimum).
    static func even(_ r: CGRect, in grid: CGRect) -> CGRect {
        func down(_ v: CGFloat) -> CGFloat { (v / 2).rounded(.down) * 2 }
        func near(_ v: CGFloat) -> CGFloat { (v / 2).rounded() * 2 }
        let x = min(max(0, down(r.minX)), grid.width - minimumSide), y = min(max(0, down(r.minY)), grid.height - minimumSide)
        let w = min(max(minimumSide, near(r.width)), grid.width - x), h = min(max(minimumSide, near(r.height)), grid.height - y)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Options: x, y, w, h in video pixels (default: the centred square). Writes "<name> cropped.<ext>".
    static func crop(_ url: URL, options: ToolOptions, progress: @escaping (Double) -> Void) throws -> URL {
        let ff = try MediaKit.ffmpeg()
        let source = try MediaFrameTools.videoSource(url, verb: "crop")
        let r = try rect(options, source: source)
        let ext = MediaEncode.outputExtension(for: source)
        let out = outputURL(for: url, ext: ext, suffix: " cropped")
        let filter = "crop=\(MediaFrameTools.number(r.width)):\(MediaFrameTools.number(r.height)):\(MediaFrameTools.number(r.minX)):\(MediaFrameTools.number(r.minY))"
        try ff.run(input: url, output: out, args: MediaFrameTools.encodeArgs(source, ext: ext, videoFilters: [filter]),
                   duration: source.duration, progress: progress)
        return out
    }
}

// MARK: - Redact

/// Redact… for video: boxes over the picture, each blurred, pixelated or filled black for its own stretch of time
/// (the whole clip by default), in one ffmpeg filter graph. Writes "<name> redacted.<ext>" in the file's own format.
///
/// How strong: Blur is a three-pass box blur whose radius is a sixth of the box's shorter side (about a Gaussian of
/// that sigma), Pixelate uses blocks of an eighth of the shorter side (at least 4 pixels), so a face that fills the box
/// is at most 8 blocks across. Boxes are widened outward to even pixels, never narrowed. Black boxes are drawn last, so
/// a black box is never covered by a blurred copy of what lies under it. A frame is redacted when any part of the
/// time it is on screen lies in the box's range.
enum MediaRedact {
    enum Style: String, CaseIterable {
        case blur, pixelate, black
        var title: String { rawValue.capitalized }
    }

    struct Box: Equatable {
        /// Video pixels, top-left origin.
        var rect: CGRect
        var style: Style
        var start: Double
        var end: Double

        var range: MediaRange { MediaRange(start: start, end: end) }
        func isActive(at t: Double) -> Bool { t >= start - 1e-6 && t < end - 1e-6 }
    }

    /// The smallest box side in video pixels (a blur needs room for its radius).
    static let minimumSide: CGFloat = 16

    /// Refuses a picture smaller than the smallest box: a box would stick out of it, and ffmpeg's crop of the box fails.
    static func checkSize(_ source: MediaSource) throws {
        let grid = MediaFrameTools.evenGrid(source)
        guard grid.width < minimumSide || grid.height < minimumSide else { return }
        throw ConversionError.unsupported("\(source.name) is only \(MediaFrameTools.number(source.pixelSize.width)) × "
            + "\(MediaFrameTools.number(source.pixelSize.height)) pixels, smaller than the smallest box (\(Int(minimumSide)) × "
            + "\(Int(minimumSide))). Redact works on pictures at least \(Int(minimumSide)) pixels wide and high.")
    }

    /// Three-pass box blur radius (video pixels) for a box: a sixth of its shorter side.
    static func blurRadius(_ r: CGRect) -> Int { max(2, Int(min(r.width, r.height) / 6)) }
    /// Pixelate block side (video pixels): an eighth of the shorter side, at least 4.
    static func blockSize(_ r: CGRect) -> Int { max(4, Int((min(r.width, r.height) / 8).rounded(.up))) }

    /// `r` widened outward to even pixels inside the even picture grid, at least `minimumSide` on each side.
    static func normalized(_ r: CGRect, in grid: CGRect) -> CGRect {
        var x0 = (r.minX / 2).rounded(.down) * 2, y0 = (r.minY / 2).rounded(.down) * 2
        var x1 = (r.maxX / 2).rounded(.up) * 2, y1 = (r.maxY / 2).rounded(.up) * 2
        x0 = max(0, x0); y0 = max(0, y0); x1 = min(grid.width, x1); y1 = min(grid.height, y1)
        if x1 - x0 < minimumSide { let mid = ((x0 + x1) / 4).rounded() * 2; x0 = max(0, min(mid - minimumSide / 2, grid.width - minimumSide)); x1 = x0 + minimumSide }
        if y1 - y0 < minimumSide { let mid = ((y0 + y1) / 4).rounded() * 2; y0 = max(0, min(mid - minimumSide / 2, grid.height - minimumSide)); y1 = y0 + minimumSide }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The command line's default: one Pixelate box over the middle of the picture (half its width and height), for
    /// the whole clip.
    static func defaultBoxes(_ source: MediaSource) -> [Box] {
        let grid = MediaFrameTools.evenGrid(source)
        let r = CGRect(x: grid.width / 4, y: grid.height / 4, width: grid.width / 2, height: grid.height / 2)
        return [Box(rect: normalized(r, in: grid), style: .pixelate, start: 0, end: source.duration)]
    }

    /// Reads "x,y,w,h,style,start,end;…" (style, start and end optional: pixelate, 0 and the clip's length).
    static func parse(_ text: String, source: MediaSource) throws -> [Box] {
        let grid = MediaFrameTools.evenGrid(source)
        let example = "Write boxes as x,y,w,h,style,start,end separated by semicolons, for example boxes=100,80,400,200,blur,1,2.5."
        let items = text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !items.isEmpty else { throw ConversionError.unsupported("There are no boxes to redact. " + example) }
        guard items.count <= 64 else { throw ConversionError.unsupported("Redact takes up to 64 boxes at a time. Save with fewer boxes, then redact the copy.") }
        var boxes: [Box] = []
        for (i, item) in items.enumerated() {
            let fields = item.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let numbers = fields.prefix(4).compactMap { Double($0) }.filter { $0.isFinite }
            guard fields.count >= 4, fields.count <= 7, numbers.count == 4 else {
                throw ConversionError.unsupported("Box \(i + 1) (“\(item)”) needs four numbers first. " + example)
            }
            var style = Style.pixelate
            if fields.count > 4, !fields[4].isEmpty {
                guard let s = Style(rawValue: fields[4].lowercased()) else {
                    throw ConversionError.unsupported("Box \(i + 1) has the style “\(fields[4])”. Choose blur, pixelate or black.")
                }
                style = s
            }
            func time(_ index: Int, _ fallback: Double) throws -> Double {
                guard fields.count > index, !fields[index].isEmpty else { return fallback }
                guard let v = MediaTime.parse(fields[index]) else {
                    throw ConversionError.unsupported("Box \(i + 1) has the time “\(fields[index])”. Give times in seconds, for example 1.5.")
                }
                return v
            }
            let start = try time(5, 0)
            var end = try time(6, source.duration)
            if end > source.duration, end - source.duration < 0.0015 { end = source.duration }
            guard start < end else {
                throw ConversionError.unsupported("Box \(i + 1) starts at \(MediaTime.string(start)), which isn’t before its end (\(MediaTime.string(end))). Choose a start earlier than the end.")
            }
            guard start < source.duration else {
                throw ConversionError.unsupported("Box \(i + 1) starts at \(MediaTime.string(start)), after the end of \(source.name) (\(MediaTime.string(source.duration))). Choose an earlier start.")
            }
            let raw = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]).standardized
            guard raw.width > 0, raw.height > 0 else {
                throw ConversionError.unsupported("Box \(i + 1) has no width or height. Give it a size of at least \(Int(minimumSide)) × \(Int(minimumSide)) pixels.")
            }
            guard raw.intersects(grid) else {
                throw ConversionError.unsupported("Box \(i + 1) (\(MediaFrameTools.number(raw.width)) × \(MediaFrameTools.number(raw.height)) at "
                    + "\(MediaFrameTools.number(raw.minX)), \(MediaFrameTools.number(raw.minY))) lies outside the picture "
                    + "(\(MediaFrameTools.number(grid.width)) × \(MediaFrameTools.number(grid.height)) pixels). Move it onto the picture.")
            }
            boxes.append(Box(rect: normalized(raw.intersection(grid), in: grid), style: style, start: max(0, start), end: min(end, source.duration)))
        }
        return boxes
    }

    /// The boxes as the `boxes` option (what the window hands to `run`).
    static func option(_ boxes: [Box]) -> String {
        boxes.map { b in
            [b.rect.minX, b.rect.minY, b.rect.width, b.rect.height].map { MediaFrameTools.number($0) }.joined(separator: ",")
                + ",\(b.style.rawValue),\(MediaTime.arg(b.start)),\(MediaTime.arg(b.end))"
        }.joined(separator: ";")
    }

    /// The times a frame must start after and before to be covered by `box` (nil: open on that side). A frame shown
    /// from t to t + fd overlaps [start, end) when t > start − fd and t < end (a hundredth of a frame of slack each way
    /// for rounded timestamps). Each sits half a microsecond off the microsecond grid (towards leaving the frame bare),
    /// so it never equals a frame's time: at a tie ffmpeg's t (pts × time base, a hair over) and the player's time (the
    /// exact fraction) fell on different sides, and a 30 fps wmv's frame 33 ms before a start was covered in the file but
    /// bare in the preview. Printed as ffmpeg will read them (`thresholdArg`), so `covers` and the filter agree.
    static func thresholds(_ box: Box, source: MediaSource) -> (after: Double?, before: Double?) {
        let fd = source.frameDuration
        func offGrid(_ v: Double, _ nudge: Double) -> Double { Double(thresholdArg((v * 1e6).rounded() / 1e6 + nudge)) ?? v }
        let after = box.start <= 1e-6 ? nil : offGrid(max(0, box.start - fd * 0.99), 0.5e-6)
        let before = box.end >= source.duration - 1e-6 ? nil : offGrid(box.end - fd * 0.01, -0.5e-6)
        return (after, before)
    }

    /// A threshold as the filter's text: seconds with seven decimals (the half microsecond), no exponent.
    static func thresholdArg(_ t: Double) -> String { String(format: "%.7f", max(0, t)) }

    /// When a box is on: the frames any part of whose time on screen lies in its range (nil: the whole clip).
    static func enableExpression(_ box: Box, source: MediaSource) -> String? {
        let (after, before) = thresholds(box, source: source)
        if after == nil && before == nil { return nil }
        var terms: [String] = []
        if let after { terms.append("gt(t,\(thresholdArg(after)))") }
        if let before { terms.append("lt(t,\(thresholdArg(before)))") }
        return terms.joined(separator: "*")
    }

    /// Whether the saved file covers the frame that starts at `t` with `box` (the filter's own rule). The preview
    /// decides from the frame it shows with this, so it never draws a frame covered that the file leaves bare.
    static func covers(_ box: Box, frameAt t: Double, source: MediaSource) -> Bool {
        let (after, before) = thresholds(box, source: source)
        return (after.map { t > $0 } ?? true) && (before.map { t < $0 } ?? true)
    }

    /// The filter graph (from [0:v], last chain unlabelled): blurred and pixelated crops overlaid in box order,
    /// then the black boxes drawn on top.
    static func filterGraph(_ boxes: [Box], source: MediaSource, pixelize: Bool = Capabilities.shared.hasFilter("pixelize"),
                            boxblur: Bool = Capabilities.shared.hasFilter("boxblur")) -> String {
        func n(_ v: CGFloat) -> String { MediaFrameTools.number(v) }
        func enable(_ b: Box) -> String { enableExpression(b, source: source).map { ":enable='\($0)'" } ?? "" }
        let effects = boxes.filter { $0.style != .black }
        var chains: [String] = []
        var current = "[0:v]"
        if !effects.isEmpty {
            chains.append("[0:v]split=\(effects.count + 1)[base]" + effects.indices.map { "[s\($0)]" }.joined())
            for (i, b) in effects.enumerated() {
                let r = b.rect
                var chain = "[s\(i)]crop=\(n(r.width)):\(n(r.height)):\(n(r.minX)):\(n(r.minY)),"
                switch b.style {
                case .blur:
                    let radius = blurRadius(r)
                    // boxblur, or avgblur three times on ffmpeg builds without it (YummyOrange's own LGPL copy).
                    chain += BoxBlur.filter(radius: radius, passes: 3, chroma: "'min(cw,ch)/6'", boxblur: boxblur)
                case .pixelate:
                    let s = blockSize(r)
                    if pixelize {
                        chain += "pixelize=w=\(s):h=\(s)"
                    } else {
                        // Older ffmpeg: average down to one pixel per block, then blow it up without smoothing.
                        let cols = Int((r.width / CGFloat(s)).rounded(.up)), rows = Int((r.height / CGFloat(s)).rounded(.up))
                        chain += "scale=\(cols):\(rows):flags=area,scale=\(n(r.width)):\(n(r.height)):flags=neighbor"
                    }
                case .black:
                    break
                }
                chains.append(chain + "[e\(i)]")
            }
            current = "[base]"
            for (i, b) in effects.enumerated() {
                chains.append("\(current)[e\(i)]overlay=x=\(n(b.rect.minX)):y=\(n(b.rect.minY)):format=auto\(enable(b))[o\(i)]")
                current = "[o\(i)]"
            }
        }
        var last = current + "null"
        for b in boxes where b.style == .black {
            let r = b.rect
            last += ",drawbox=x=\(n(r.minX)):y=\(n(r.minY)):w=\(n(r.width)):h=\(n(r.height)):color=black:t=fill\(enable(b))"
        }
        chains.append(last)
        return chains.joined(separator: ";")
    }

    /// Options: boxes="x,y,w,h,style,start,end;…" (video pixels, style blur|pixelate|black, times in seconds; default
    /// one Pixelate box over the middle half of the picture for the whole clip). Writes "<name> redacted.<ext>".
    static func redact(_ url: URL, options: ToolOptions, progress: @escaping (Double) -> Void) throws -> URL {
        let ff = try MediaKit.ffmpeg()
        let source = try MediaFrameTools.videoSource(url, verb: "redact")
        try checkSize(source)
        let boxes = try options["boxes"].map { try parse($0, source: source) } ?? defaultBoxes(source)
        let ext = MediaEncode.outputExtension(for: source)
        let out = outputURL(for: url, ext: ext, suffix: " redacted")
        try ff.run(input: url, output: out, args: MediaFrameTools.encodeArgs(source, ext: ext, filterComplex: filterGraph(boxes, source: source)),
                   duration: source.duration, progress: progress)
        return out
    }
}

// MARK: - Snapshot

/// Snapshot… for video: one frame as a PNG at full resolution, upright, decoded with the right colour matrix (the
/// stream's tag, else BT.709 for HD and BT.601 below), with square pixels (files whose pixels are within 1% of square
/// keep their exact pixels). Writes "<name> frame m-ss.ff.png" named after the frame's time.
enum MediaSnapshot {
    /// The frame on screen at `t`, read from the file: its exact start time, the last frame that has started by then.
    /// Frames are listed by decoding from two seconds before `t`, and from further back while none has started by
    /// then (a frame held for longer, as screen recordings hold a still screen; ffmpeg drops frames before its seek
    /// point). Before the first frame, the first. With `still`, the frame the editor's still shows at `t` instead
    /// (MediaKit.stillFrame, with its own seek: the first that starts at or after `stillSeek(t)`, which on wmv's
    /// millisecond times and 23.976 fps grids starts just after `t`), for Save before the player is ready.
    static func frameTime(_ source: MediaSource, at t: Double, still: Bool = false) throws -> Double {
        let ff = try MediaKit.ffmpeg()
        let target = min(max(0, t), source.duration)
        /// Frame start times decoded from `from` for `length` seconds (`frames`: at most that many), compared to the
        /// microsecond (ffmpeg prints them so), from the seek point exactly as ffmpeg reads it.
        func times(from: Double, length: Double?, frames: Int? = nil) throws -> [Double] {
            let seekArg = MediaTime.arg(max(0, from))
            let seek = Double(seekArg) ?? 0
            let args = ["-hide_banner", "-nostdin", "-ss", seekArg] + (length.map { ["-t", MediaTime.arg($0)] } ?? [])
                + ["-i", source.url.path, "-map", "0:v:0"] + (frames.map { ["-frames:v", String($0)] } ?? [])
                + ["-vf", "showinfo", "-f", "null", "-"]
            let result = try ProcessRunner.run(ff.tool, args)
            return result.stderr.matches(of: #/pts_time:(-?[0-9.]+)/#).compactMap { Double($0.1) }.map { seek + $0 }
        }
        let missing = ConversionError.toolFailed("ffmpeg found no picture near \(MediaTime.string(target)) in \(source.name).")
        // Past the last frame the still finds none and keeps the one before, the frame on screen.
        if still, let shown = try times(from: MediaKit.stillSeek(target), length: nil, frames: 1).first { return shown }
        var lookback = 2.0
        while true {
            let from = max(0, target - lookback)
            let list = try times(from: from, length: target - from + 1)
            // The last one that has started by `target` (not the nearest one, which half the time is the next frame,
            // one the window never showed at that time), give or take the 1 ms the player seeks past the playhead
            // (MediaPlayback.videoSeekNudge), so a frame stored in whole milliseconds just after it counts, as on screen.
            if let shown = list.last(where: { $0 <= target + MediaPlayback.videoSeekNudge + 1e-6 }) { return shown }
            if from <= 0 {
                guard let first = list.first else { throw missing }
                return first
            }
            lookback *= 4
        }
    }

    /// The PNG's size: the display size, or the stored pixels (upright) when they are within 1% of square.
    static func outputSize(_ source: MediaSource) -> CGSize {
        abs(source.pixelAspect - 1) < 0.01 ? source.pixelSize : source.displaySize
    }

    /// The scale filter that turns the frame into upright square RGB with the right matrix and clears the colour
    /// tags (the values are the video's R′G′B′, which Macs show as sRGB, like a frame copied from QuickTime).
    static func rgbFilters(_ source: MediaSource) -> [String] {
        let size = outputSize(source)
        var filters = ["scale=\(Int(size.width)):\(Int(size.height)):flags=bicubic+accurate_rnd+full_chroma_int\(source.rgbScaleOptions)",
                       "setsar=1", "format=rgb24"]
        if Capabilities.shared.hasFilter("setparams") {
            filters.append("setparams=color_primaries=unknown:color_trc=unknown:colorspace=unknown")
        }
        return filters
    }

    /// " frame 0-01.50": the frame's time as m-ss.ff (h-mm-ss.ff from an hour), safe in a file name.
    static func suffix(_ t: Double) -> String { " frame " + MediaTime.string(t).replacingOccurrences(of: ":", with: "-") }

    /// Options: time (seconds or m:ss.ff, default the middle of the clip: the frame on screen then), still (true: the
    /// frame the editor's still shows at that time, which the window passes until its player is ready; default false).
    /// Writes "<name> frame m-ss.ff.png".
    static func snapshot(_ url: URL, options: ToolOptions, progress: @escaping (Double) -> Void) throws -> URL {
        let ff = try MediaKit.ffmpeg()
        let source = try MediaFrameTools.videoSource(url, verb: "snapshot")
        // A time that can't be read is an error, not the middle of the clip.
        let text = options["time"]?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let t = text.isEmpty ? source.duration / 2 : MediaTime.parse(text), t.isFinite, t >= 0 else {
            throw ConversionError.unsupported("Give the time in seconds from the start, for example time=1.5.")
        }
        guard t <= source.duration + 0.0015 else {
            throw ConversionError.unsupported("The time (\(MediaTime.string(t))) is past the end of \(source.name) (\(MediaTime.string(source.duration))). "
                                              + "Choose a time of \(MediaTime.string(source.duration)) or less.")
        }
        let frame = try frameTime(source, at: t, still: options.bool("still", false))
        progress(0.4)
        let out = outputURL(for: url, ext: "png", suffix: suffix(frame))
        let seek = max(0, frame - 1)
        let pick = "select=gte(t\\,\(MediaTime.arg(frame - seek - source.frameDuration * 0.25)))"
        try ff.run(input: url, output: out, args: ["-map", "0:v:0", "-vf", ([pick] + rgbFilters(source)).joined(separator: ","),
                                                   "-frames:v", "1", "-update", "1", "-c:v", "png"],
                   duration: nil, inputOptions: ["-ss", MediaTime.arg(seek), "-t", MediaTime.arg(frame - seek + 1)], progress: { _ in })
        guard FileManager.default.fileExists(atPath: out.path) else {
            throw ConversionError.toolFailed("ffmpeg wrote no frame for \(MediaTime.string(frame)) of \(source.name).")
        }
        progress(1)
        return out
    }
}
