import AppKit

/// Visualize… (sound files): an MP4 (H.264 + AAC) that shows the sound moving, for sharing a voice note, a podcast
/// clip or a song where only video is accepted ("song visualized.mp4").
///
/// The look is YummyOrange's dahlia palette: a cream page (#FFF4EA) with a butter band (#FFE1A1) across its lower third,
/// and the drawing in dahlia (#E2669C) standing on the band's top edge like a horizon, with a soft reflection
/// (32 % dahlia) in the band. The drawing is a mask from one of ffmpeg's audio visualizers, made solid and coloured
/// with `alphamerge`, so it isn't limited to the visualizer's own colour schemes:
/// - Waveform (`showwaves`): the loudness of the last 1/30 s across the width, as a skyline.
/// - Spectrum (`showcqt`): a smooth mountain of the frequencies, 40 Hz to 12 kHz, low on the left.
/// - Bars (`showcqt`): the same spectrum in 32 bars (48 for wide video), an equalizer.
/// The visualizer's input is evened out with `dynaudnorm` (only the drawing; the sound in the file is the original),
/// so quiet recordings still move. Sizes: square 1080 × 1080, wide 1920 × 1080, tall 1080 × 1920, 30 frames a second.
enum MediaVisualize {
    enum Style: String, CaseIterable {
        case waveform, spectrum, bars
        var title: String {
            switch self {
            case .waveform: return "Waveform"
            case .spectrum: return "Spectrum"
            case .bars: return "Bars"
            }
        }
        /// The ffmpeg filters this style needs beyond the common ones.
        var filters: [String] {
            switch self {
            case .waveform: return ["showwaves"]
            case .spectrum: return ["showcqt", "boxblur"]
            case .bars: return ["showcqt", "drawgrid"]
            }
        }
    }

    enum Size: String, CaseIterable {
        case square, wide, tall
        var title: String {
            switch self {
            case .square: return "Square 1080 × 1080"
            case .wide: return "Wide 1920 × 1080"
            case .tall: return "Tall 1080 × 1920"
            }
        }
        var pixels: (width: Int, height: Int) {
            switch self {
            case .square: return (1080, 1080)
            case .wide: return (1920, 1080)
            case .tall: return (1080, 1920)
            }
        }
    }

    static let cream = "0xFFF4EA", butter = "0xFFE1A1", dahlia = "0xE2669C"
    /// Filters every style uses.
    static let commonFilters = ["alphamerge", "dynaudnorm", "lut", "vflip", "scale", "crop", "drawbox", "color", "overlay", "split", "setpts", "setparams"]

    /// The styles this Mac's ffmpeg can draw.
    static var availableStyles: [Style] {
        let caps = Capabilities.shared
        guard commonFilters.allSatisfy(caps.hasFilter) else { return [] }
        return Style.allCases.filter { $0.filters.allSatisfy(caps.hasFilter) }
    }

    static func ask(_ files: [URL]) -> ToolOptions? {
        let styles = availableStyles
        guard !styles.isEmpty else {
            HUD.shared.flash("This Mac’s ffmpeg has none of the visualizer filters Visualize needs. Install a full ffmpeg (for example with Homebrew).",
                             isError: true)
            return nil
        }
        let last = ImageExtras.remembered("visualize")
        let style = Style(rawValue: last.string("style", "")).flatMap { styles.contains($0) ? $0 : nil } ?? styles[0]
        let size = Size(rawValue: last.string("size", "")) ?? .square
        guard let answer = Ask.form(title: "Visualize",
                                    message: MediaTools.formMessage(files, "Makes an MP4 video of the sound, drawn in pink on cream."),
                                    fields: [.choice(key: "style", label: "Style:", options: styles.map(\.title), selected: style.title),
                                             .choice(key: "size", label: "Size:", options: Size.allCases.map(\.title), selected: size.title)],
                                    button: "Make Video") else { return nil }
        let options: ToolOptions = ["style": (styles.first { $0.title == answer["style"] } ?? style).rawValue,
                                    "size": (Size.allCases.first { $0.title == answer["size"] } ?? size).rawValue]
        ImageExtras.remember(options, as: "visualize")
        return options
    }

    /// Options: style (waveform | spectrum | bars, default waveform), size (square | wide | tall, default square).
    /// Writes "<name> visualized.mp4".
    static func visualize(_ url: URL, options: ToolOptions, progress: @escaping (Double) -> Void) throws -> URL {
        let ff = try MediaKit.ffmpeg()
        let source = try MediaSource.load(url)
        guard source.hasAudio else { throw ConversionError.unsupported("The file has no sound to visualize.") }
        guard source.duration > 0 else {
            throw ConversionError.unsupported("The file reports no length, so it can’t be visualized. Convert it first.")
        }
        let styleText = options.string("style", Style.waveform.rawValue).lowercased()
        guard let style = Style(rawValue: styleText) else {
            throw ConversionError.unsupported("Choose style=waveform, spectrum or bars (not “\(styleText)”).")
        }
        let sizeText = options.string("size", Size.square.rawValue).lowercased()
        guard let size = Size(rawValue: sizeText) else {
            throw ConversionError.unsupported("Choose size=square, wide or tall (not “\(sizeText)”).")
        }
        let missing = (commonFilters + style.filters).filter { !Capabilities.shared.hasFilter($0) }
        guard missing.isEmpty else {
            let others = availableStyles.map(\.title)
            throw ConversionError.unsupported("This Mac’s ffmpeg has no \(missing.joined(separator: ", ")) filter, so it can’t draw \(style.title). "
                                              + (others.isEmpty ? "Install a full ffmpeg (for example with Homebrew)." : "Choose \(others.joined(separator: " or "))."))
        }
        let out = outputURL(for: url, ext: "mp4", suffix: " visualized")
        var args = ["-filter_complex", graph(style, size: size, pad: MediaKit.soundFromZero(source)), "-map", "[v]", "-map", "0:a:0"]
        args += ["-c:v", "h264_videotoolbox", "-q:v", "65", "-allow_sw", "1", "-pix_fmt", "yuv420p", "-tag:v", "avc1", "-r", "30",
                 // BT.709, tagged, so players show the palette's exact colours.
                 "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv"]
        args += ["-c:a", "aac", "-b:a", "\(MediaEncode.lossyRate(source, floor: 128))k", "-shortest", "-movflags", "+faststart"]
        try ff.run(input: url, output: out, args: args, duration: source.duration, progress: progress)
        return out
    }

    /// Where things go in a `width` × `height` frame (even values).
    struct Layout {
        let width: Int, height: Int
        /// The band's top edge, which the drawing stands on.
        let horizon: Int
        /// The drawing's box: `x`, `top`, `drawWidth` × `drawHeight` (bottom at the horizon).
        let x: Int, top: Int, drawWidth: Int, drawHeight: Int
        /// The reflection's height, and the gap between the drawing and it.
        let reflection: Int, gap: Int
        /// Bars (bars style).
        let bars: Int

        init(_ style: Style, size: Size) {
            let (w, h) = size.pixels
            func even(_ v: Double) -> Int { Int((v / 2).rounded()) * 2 }
            width = w; height = h
            horizon = even(Double(h) * 2 / 3)
            top = even(Double(h) * 0.14)
            bars = w < 1500 ? 32 : 48
            var dw = w - 2 * even(Double(w) * 0.08)
            if style == .bars { dw = dw / bars * bars }      // whole pixels per bar, so the gaps fall evenly
            drawWidth = dw
            x = (w - dw) / 2
            drawHeight = horizon - top
            reflection = even(Double(h - horizon) * 0.62)
            gap = max(4, even(Double(h) * 0.006))
        }
    }

    /// The whole filter graph: background, the style's mask, the dahlia drawing and its reflection, into [v].
    /// `pad` (MediaKit.soundFromZero) puts the drawing on the file's clock, the clock the sound in the MP4 keeps: a
    /// sound that starts late (ffmpeg's WMA decoder: 0.092 s) would otherwise be drawn that much ahead of itself.
    static func graph(_ style: Style, size: Size, pad: [String] = []) -> String {
        let l = Layout(style, size: size)
        let w = l.drawWidth, a = l.drawHeight
        let background = "color=c=\(cream):s=\(l.width)x\(l.height):r=30,"
            + "drawbox=x=0:y=\(l.horizon):w=iw:h=ih-\(l.horizon):color=\(butter)@0.55:t=fill[bg]"
        let pink = "color=c=\(dahlia):s=\(w)x\(a):r=30,format=rgba[p];color=c=\(dahlia):s=\(w)x\(l.reflection):r=30,format=rgba[pr]"
        let level = "dynaudnorm=f=200:g=11:p=0.9:m=12"
        let cqt = "showcqt=s=\(w)x\(a):r=30:axis=0:sono_h=0:basefreq=40:endfreq=12000:bar_g=2:bar_v=9:cscheme=1|1|1|1|1|1,"
            + "format=gray,lut=y='if(gt(val,6),255,0)'"
        let mask: String
        var x = l.x
        switch style {
        case .waveform:
            // A centred waveform twice as tall, cut at its middle: the upper half is the skyline.
            mask = "showwaves=s=\(w)x\(2 * a):mode=cline:rate=30:scale=sqrt:draw=full:colors=white,format=gray,crop=\(w):\(a):0:0"
        case .spectrum:
            mask = "\(cqt),boxblur=luma_radius=6:luma_power=2,lut=y='if(gt(val,127),255,0)'"
        case .bars:
            let gapWidth = max(4, Int((Double(w / l.bars) * 0.3).rounded()))
            mask = "\(cqt),scale=\(l.bars):\(a):flags=area,lut=y='if(gt(val,127),255,0)',scale=\(w):\(a):flags=neighbor,"
                + "drawgrid=w=\(w / l.bars):h=ih+10:t=\(gapWidth):c=black"
            x -= gapWidth / 2      // each bar's gap is on its left: centre the bars, not the slots
        }
        // setpts: showwaves stamps a frame at the end of the sound it shows; draw it from the start instead (and
        // never let the drawing begin after the page, or the first frame would be all pink).
        return "\(background);\(pink);[0:a:0]\((pad + [level]).joined(separator: ",")),\(mask),setpts=PTS-STARTPTS,format=gray,split[m][mr];"
            + "[mr]vflip,scale=\(w):\(l.reflection),lut=y='val*0.32'[r];[p][m]alphamerge[f];[pr][r]alphamerge[fr];"
            + "[bg][f]overlay=\(x):\(l.top):format=auto:shortest=1[b1];[b1][fr]overlay=\(x):\(l.horizon + l.gap):format=auto,"
            + "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv[v]"
    }
}
