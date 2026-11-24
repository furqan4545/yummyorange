import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// The clothesline's drawing: the polaroid-like mat card, the wooden clothespin and the string's colours.
/// Everything is drawn in code (no artwork files), in the card's own frame (origin at the pivot, y down).
enum ClotheslineArt {
    // MARK: Colours

    struct Palette {
        let mat: NSColor
        let matEdge: NSColor
        let caption: NSColor
        let well: NSColor
        /// The string is a strand of light: a gradient along it, left end to right end (three stops)…
        let stringColors: [NSColor]
        /// … and a soft glow around it in the same colours, at this opacity (none with Increase Contrast).
        let glowColors: [NSColor]
        let glowOpacity: Float
        /// A thin edge under the string (Increase Contrast only; clear otherwise).
        let stringHalo: NSColor
        let shadowOpacity: Float
        /// Dims photos a little in dark mode so the white in them doesn't glow (HIG Dark Mode).
        let photoDim: CGFloat
        /// The mat's edge line (Increase Contrast: a solid 1 pt border).
        var edgeWidth: CGFloat = 0.5

        static let light = Palette(
            mat: .white,
            matEdge: NSColor(white: 0, alpha: 0.09),
            caption: NSColor(srgbRed: 0x2A / 255.0, green: 0x26 / 255.0, blue: 0x23 / 255.0, alpha: 1),
            well: NSColor(srgbRed: 0xF5 / 255.0, green: 0xF1 / 255.0, blue: 0xEC / 255.0, alpha: 1),
            stringColors: Light.stops.map { DWPalette.blend($0, .white, 0.22) },
            glowColors: Light.stops, glowOpacity: 0.9,
            stringHalo: .clear,
            shadowOpacity: 0.3, photoDim: 0)

        static let dark = Palette(
            mat: NSColor(srgbRed: 0x2E / 255.0, green: 0x2C / 255.0, blue: 0x2B / 255.0, alpha: 1),
            matEdge: NSColor(white: 1, alpha: 0.13),
            caption: DWPalette.cream,
            well: NSColor(srgbRed: 0x3A / 255.0, green: 0x37 / 255.0, blue: 0x35 / 255.0, alpha: 1),
            stringColors: Light.stops.map { DWPalette.blend($0, .white, 0.5) },
            glowColors: Light.glowStops, glowOpacity: 0.95,
            stringHalo: .clear,
            shadowOpacity: 0.5, photoDim: 0.07)

        /// Increase Contrast (HIG Accessibility): defined, solid card edges and an opaque string with a stronger halo.
        static let lightContrast = Palette(
            mat: .white,
            matEdge: NSColor(white: 0, alpha: 0.4),
            caption: NSColor(srgbRed: 0x14 / 255.0, green: 0x12 / 255.0, blue: 0x10 / 255.0, alpha: 1),
            well: NSColor(srgbRed: 0xEC / 255.0, green: 0xE6 / 255.0, blue: 0xDF / 255.0, alpha: 1),
            stringColors: Light.stops.map(DWPalette.deepened),
            glowColors: Light.stops, glowOpacity: 0,
            stringHalo: NSColor(white: 1, alpha: 0.9),
            shadowOpacity: 0.3, photoDim: 0, edgeWidth: 1)

        static let darkContrast = Palette(
            mat: NSColor(srgbRed: 0x2E / 255.0, green: 0x2C / 255.0, blue: 0x2B / 255.0, alpha: 1),
            matEdge: NSColor(white: 1, alpha: 0.5),
            caption: DWPalette.cream,
            well: NSColor(srgbRed: 0x42 / 255.0, green: 0x3F / 255.0, blue: 0x3C / 255.0, alpha: 1),
            stringColors: Light.stops.map { DWPalette.blend($0, .white, 0.6) },
            glowColors: Light.stops, glowOpacity: 0,
            stringHalo: NSColor(white: 0, alpha: 0.75),
            shadowOpacity: 0.5, photoDim: 0.07, edgeWidth: 1)

        /// The light's colours, YummyOrange's own base → glow axis (DWPalette): warm gold at the left end, dahlia pink in
        /// the middle, the deeper accent at the right end.
        enum Light {
            static let stops = [DWPalette.shifted(DWPalette.base, towardGlow: 0.75), DWPalette.base, DWPalette.accent]
            /// Dark mode's glow leans a little further toward the butter, so the gold end reads as light, not orange.
            static let glowStops = [DWPalette.shifted(DWPalette.base, towardGlow: 0.9), DWPalette.base, DWPalette.accent]
        }

        static func current(dark: Bool, contrast: Bool = false) -> Palette {
            switch (dark, contrast) {
            case (false, false): return .light
            case (true, false): return .dark
            case (false, true): return .lightContrast
            case (true, true): return .darkContrast
            }
        }
    }

    /// Light wood, warmed toward YummyOrange's butter.
    static let woodLight = DWPalette.blend(DWPalette.glow, .white, 0.25)
    static let woodDark = NSColor(srgbRed: 0xD8 / 255.0, green: 0xA4 / 255.0, blue: 0x66 / 255.0, alpha: 1)
    static let woodEdge = NSColor(srgbRed: 0xA8 / 255.0, green: 0x77 / 255.0, blue: 0x43 / 255.0, alpha: 0.75)
    static let grain = NSColor(srgbRed: 0xB0 / 255.0, green: 0x7E / 255.0, blue: 0x48 / 255.0, alpha: 0.42)

    // MARK: Card picture

    /// What a card shows.
    struct CardContent {
        var name: String
        var thumbnail: NSImage?
        /// True when `thumbnail` is the Finder icon (no preview).
        var isIcon: Bool
        /// Seconds, for videos.
        var duration: Double?
    }

    /// The card's picture bounds in its own frame: the mat and the pin, with room for anti-aliasing.
    static func imageRect(width: CGFloat) -> CGRect {
        ClotheslineCardMetrics.matRect(width: width).union(ClotheslineCardMetrics.pinRect).insetBy(dx: -2, dy: -2).integral
    }

    /// How many card and ghost pictures were drawn, how many of them on the main thread and the seconds those took
    /// (the performance self-test reads it).
    struct DrawStats { var all = 0, mainThread = 0; var mainSeconds = 0.0 }
    private static let drawStatsLock = NSLock()
    private static var _drawStats = DrawStats()
    static var drawStats: DrawStats {
        get { drawStatsLock.lock(); defer { drawStatsLock.unlock() }; return _drawStats }
        set { drawStatsLock.lock(); _drawStats = newValue; drawStatsLock.unlock() }
    }
    private static func counted<T>(_ draw: () -> T) -> T {
        let main = Thread.isMainThread, t0 = CACurrentMediaTime()
        let result = draw()
        let seconds = CACurrentMediaTime() - t0
        drawStatsLock.lock()
        _drawStats.all += 1
        if main { _drawStats.mainThread += 1; _drawStats.mainSeconds += seconds }
        drawStatsLock.unlock()
        return result
    }

    /// The card as a bitmap at `scale` pixels per point.
    static func cardImage(_ content: CardContent, width: CGFloat, dark: Bool, contrast: Bool = false, scale: CGFloat) -> CGImage? {
        counted { drawCardImage(content, width: width, dark: dark, contrast: contrast, scale: scale) }
    }

    private static func drawCardImage(_ content: CardContent, width: CGFloat, dark: Bool, contrast: Bool, scale: CGFloat) -> CGImage? {
        let rect = imageRect(width: width)
        let pw = Int((rect.width * scale).rounded(.up)), ph = Int((rect.height * scale).rounded(.up))
        guard pw > 0, ph > 0,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // Top-down coordinates with the pivot at the origin.
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            drawCard(content, width: width, palette: .current(dark: dark, contrast: contrast), in: ctx)
            drawPin(in: ctx)
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    static func drawCard(_ content: CardContent, width w: CGFloat, palette p: Palette, in ctx: CGContext) {
        let M = ClotheslineCardMetrics.self
        let mat = M.matRect(width: w)
        let matPath = NSBezierPath(roundedRect: mat, xRadius: M.radius, yRadius: M.radius)
        p.mat.setFill()
        matPath.fill()

        let well = CGRect(x: mat.minX + M.inset, y: mat.minY + M.inset, width: w - 2 * M.inset, height: M.thumbHeight)
        let wellPath = NSBezierPath(roundedRect: well, xRadius: 3.5, yRadius: 3.5)
        drawPicture(content, in: well, palette: p)
        // A hairline inside the well keeps white pictures from melting into the mat.
        p.matEdge.withAlphaComponent(p.matEdge.alphaComponent * 0.7).setStroke()
        wellPath.lineWidth = 0.5
        wellPath.stroke()

        if let seconds = content.duration { drawPlayBadge(seconds, in: well) }
        drawCaption(content.name, mat: mat, well: well, palette: p)

        p.matEdge.setStroke()
        let edge = NSBezierPath(roundedRect: mat.insetBy(dx: p.edgeWidth / 2, dy: p.edgeWidth / 2), xRadius: M.radius, yRadius: M.radius)
        edge.lineWidth = p.edgeWidth
        edge.stroke()
    }

    /// The card's picture in its well: the preview filling it (a portrait one shown whole on the well's colour), or a
    /// document's Finder icon on the well.
    static func drawPicture(_ content: CardContent, in well: CGRect, palette p: Palette) {
        let wellPath = NSBezierPath(roundedRect: well, xRadius: 3.5, yRadius: 3.5)
        NSGraphicsContext.saveGraphicsState()
        wellPath.addClip()
        if let image = content.thumbnail, !content.isIcon {
            // Fill the well (the card's width already follows the picture's aspect; extreme ones are cropped). A
            // portrait picture on a mat widened for its name is shown whole, centred on the well.
            let aspect = image.size.width / max(image.size.height, 1)
            let portrait = aspect < (well.width / well.height) * 0.85
            if portrait { p.well.setFill(); well.fill() }
            let s = portrait ? min(well.width / max(image.size.width, 1), well.height / max(image.size.height, 1))
                : max(well.width / max(image.size.width, 1), well.height / max(image.size.height, 1))
            let size = CGSize(width: image.size.width * s, height: image.size.height * s)
            let r = CGRect(x: well.midX - size.width / 2, y: well.midY - size.height / 2, width: size.width, height: size.height)
            image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            if p.photoDim > 0 { NSColor(white: 0, alpha: p.photoDim).setFill(); well.fill(using: .sourceOver) }
        } else {
            // A document: its Finder icon on a soft well, like a file lying on paper.
            p.well.setFill()
            well.fill()
            let icon = content.thumbnail ?? NSWorkspace.shared.icon(for: .data)
            let side = min(58, well.height - 18)
            let r = CGRect(x: well.midX - side / 2, y: well.midY - side / 2, width: side, height: side)
            icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The caption: the file name, 11 pt, truncated in the middle (a time-stamped name at its head).
    static func drawCaption(_ name: String, mat: CGRect, well: CGRect, palette p: Palette) {
        let M = ClotheslineCardMetrics.self
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = captionTruncation(name)
        let text = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: p.caption, .paragraphStyle: style,
        ])
        let captionRect = CGRect(x: mat.minX + M.inset + 1, y: well.maxY + 3.5, width: mat.width - 2 * M.inset - 2, height: 14)
        text.draw(with: captionRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Where a caption too long for its card is cut. Names that end in a date and time, as macOS names screenshots and
    /// screen recordings ("Screenshot 2026-11-24 at 10.31.07.png"), share their long beginning and differ only at the
    /// end, so they lose the beginning and keep the whole time ("…11-24 at 10.31.07.png"); others lose their middle.
    static func captionTruncation(_ name: String) -> NSLineBreakMode {
        name.range(of: #"\d{4}-\d{2}-\d{2}\D+\d{1,2}[.:]\d{2}[.:]\d{2}"#, options: .regularExpression) != nil ? .byTruncatingHead : .byTruncatingMiddle
    }

    /// A small dark capsule with a play glyph and the duration, at the picture's lower left.
    static func drawPlayBadge(_ seconds: Double, in well: CGRect) {
        let label = NSAttributedString(string: durationText(seconds), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let size = label.size()
        let h: CGFloat = 16
        let r = CGRect(x: well.minX + 5, y: well.maxY - 5 - h, width: size.width + 22, height: h)
        NSColor(white: 0, alpha: 0.58).setFill()
        NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
        // Play triangle, drawn (a glyph would need flipping care).
        let t = NSBezierPath()
        let cx = r.minX + 8.5, cy = r.midY
        t.move(to: CGPoint(x: cx - 2.6, y: cy - 3.6))
        t.line(to: CGPoint(x: cx + 3.6, y: cy))
        t.line(to: CGPoint(x: cx - 2.6, y: cy + 3.6))
        t.close()
        NSColor.white.setFill()
        t.fill()
        label.draw(at: CGPoint(x: r.minX + 15, y: r.midY - size.height / 2))
    }

    static func durationText(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Ghost card

    /// The ghost that shows where dragged files will hang: the card they will become, not yet real. The mat frosted
    /// and translucent, the file's picture in its well at half strength (a tray-and-arrow glyph until the picture has
    /// loaded), its name (or "3 files") as the caption, the outline dashed in YummyOrange's accent as the only "drop here"
    /// cue, and an open clothespin waiting at the top. When the card fades in over it, the picture simply becomes
    /// opaque and the pin closes (HIG Drag and drop: help people predict the result; show an insertion point).
    static func ghostImage(width: CGFloat, content: CardContent, palette p: Palette, scale: CGFloat) -> CGImage? {
        counted { drawGhostImage(width: width, content: content, palette: p, scale: scale) }
    }

    private static func drawGhostImage(width: CGFloat, content: CardContent, palette p: Palette, scale: CGFloat) -> CGImage? {
        let rect = imageRect(width: width)
        let pw = Int((rect.width * scale).rounded(.up)), ph = Int((rect.height * scale).rounded(.up))
        guard pw > 0, ph > 0,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let dark = p.mat != .white
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            drawGhost(width: width, content: content, palette: p, dark: dark, in: ctx)
            drawPin(in: ctx, open: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// The ghost's opacity: the mat 72 % (92 % with Increase Contrast), so the caption keeps at least 5:1 over any
    /// wallpaper and the card it glides past still shows through; the picture half as strong (70 %).
    static func ghostMatAlpha(contrast: Bool) -> CGFloat { contrast ? 0.92 : 0.72 }
    static func ghostPictureAlpha(contrast: Bool) -> CGFloat { contrast ? 0.7 : 0.5 }

    static func drawGhost(width w: CGFloat, content: CardContent, palette p: Palette, dark: Bool, in ctx: CGContext) {
        let M = ClotheslineCardMetrics.self
        let contrast = p.edgeWidth > 0.5
        let mat = M.matRect(width: w)
        let ink = dark ? DWPalette.accentHighlight : DWPalette.accent
        let shape = NSBezierPath(roundedRect: mat.insetBy(dx: 1, dy: 1), xRadius: M.radius, yRadius: M.radius)
        p.mat.withAlphaComponent(ghostMatAlpha(contrast: contrast)).setFill()
        shape.fill()
        DWPalette.base.withAlphaComponent(dark ? 0.14 : 0.10).setFill()
        shape.fill()
        // Where the picture will be: the picture itself, half strength.
        let well = CGRect(x: mat.minX + M.inset, y: mat.minY + M.inset, width: w - 2 * M.inset, height: M.thumbHeight)
        if content.thumbnail != nil {
            ctx.saveGState()
            ctx.setAlpha(ghostPictureAlpha(contrast: contrast))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            drawPicture(content, in: well, palette: p)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        } else if let symbol = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 24, weight: .regular)) {
            // Until the picture has loaded: a glyph that says "it goes here".
            let tinted = NSImage(size: symbol.size, flipped: false) { r in
                symbol.draw(in: r)
                ink.withAlphaComponent(0.85).setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            let size = symbol.size
            let r = CGRect(x: well.midX - size.width / 2, y: well.midY - size.height / 2 + 2, width: size.width, height: size.height)
            tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        drawCaption(content.name, mat: mat, well: well, palette: p)
        ink.withAlphaComponent(contrast ? 1 : 0.9).setStroke()
        shape.lineWidth = contrast ? 2 : 1.5
        shape.setLineDash(contrast ? [8, 3] : [6, 4], count: 2, phase: 0)
        shape.lineCapStyle = .round
        shape.stroke()
    }

    /// The clothespin: two light-wood prongs with a little grain, gripped by a small steel spring, centred on the pivot.
    /// `open` (0…1) squeezes it: the prongs turn about the spring and the jaws at the bottom part, ready for a card.
    static func drawPin(in ctx: CGContext, open: CGFloat = 0) {
        let M = ClotheslineCardMetrics.self
        let top = M.pinTop, bottom = M.pinTop + M.pinHeight
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
        shadow.shadowOffset = NSSize(width: 0, height: 1.2)   // flipped context: positive is down
        shadow.shadowBlurRadius = 1.6
        shadow.set()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for side in [-1.0, 1.0] {
            let inner: CGFloat = 0.35, outer: CGFloat = 5.7
            let x0 = side < 0 ? -outer : inner
            let prong = CGRect(x: x0, y: top, width: outer - inner, height: bottom - top)
            let path = NSBezierPath(roundedRect: prong, xRadius: 2.1, yRadius: 2.1)
            NSGraphicsContext.saveGraphicsState()
            if open > 0 {
                // Turned about the spring: the bottom of the left prong swings left, the right one's right.
                let turn = NSAffineTransform()
                turn.translateX(by: side < 0 ? -2 : 2, yBy: 6.5)
                turn.rotate(byRadians: CGFloat(side < 0 ? 1 : -1) * open * CGFloat(ClotheslineMath.radians(8)))
                turn.translateX(by: side < 0 ? 2 : -2, yBy: -6.5)
                turn.concat()
            }
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let g = NSGradient(colors: side < 0 ? [woodLight, woodDark] : [DWPalette.blend(woodLight, woodDark, 0.25), woodDark])
            g?.draw(in: prong, angle: 0)
            // Grain: two long, slightly wavy strokes.
            grain.setStroke()
            for (i, fx) in [0.32, 0.7].enumerated() {
                let gx = prong.minX + prong.width * CGFloat(fx)
                let wave = NSBezierPath()
                wave.move(to: CGPoint(x: gx, y: top + 2))
                wave.curve(to: CGPoint(x: gx + (i == 0 ? 0.5 : -0.4), y: bottom - 2),
                           controlPoint1: CGPoint(x: gx + 0.9, y: top + 9), controlPoint2: CGPoint(x: gx - 0.8, y: bottom - 9))
                wave.lineWidth = 0.45
                wave.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
            woodEdge.setStroke()
            path.lineWidth = 0.5
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        // The jaw where the string is caught.
        NSColor(srgbRed: 0.45, green: 0.30, blue: 0.17, alpha: 0.55).setFill()
        NSBezierPath(ovalIn: CGRect(x: -1.3, y: -1.1, width: 2.6, height: 2.2)).fill()
        // The spring: a steel band wrapped round both prongs, with its coils.
        let band = CGRect(x: -6.7, y: 4.2, width: 13.4, height: 4.6)
        let bandPath = NSBezierPath(roundedRect: band, xRadius: 1.6, yRadius: 1.6)
        NSGradient(colors: [NSColor(srgbRed: 0.93, green: 0.94, blue: 0.95, alpha: 1),
                            NSColor(srgbRed: 0.64, green: 0.67, blue: 0.70, alpha: 1)])?.draw(in: bandPath, angle: -90)
        NSColor(srgbRed: 0.42, green: 0.45, blue: 0.48, alpha: 1).setStroke()
        bandPath.lineWidth = 0.5
        bandPath.stroke()
        for i in 0..<3 {
            let x = band.minX + 3.2 + CGFloat(i) * 3.5
            let coil = NSBezierPath()
            coil.move(to: CGPoint(x: x - 0.9, y: band.minY + 0.6))
            coil.line(to: CGPoint(x: x + 0.9, y: band.maxY - 0.6))
            coil.lineWidth = 0.7
            coil.stroke()
        }
        NSColor(white: 1, alpha: 0.7).setStroke()
        let shine = NSBezierPath()
        shine.move(to: CGPoint(x: band.minX + 1.4, y: band.minY + 1.1))
        shine.line(to: CGPoint(x: band.maxX - 1.4, y: band.minY + 1.1))
        shine.lineWidth = 0.5
        shine.stroke()
        ctx.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Media facts

    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    private static var durations: [String: Double] = [:]
    private static var waitingDurations: [String: [(Double?) -> Void]] = [:]

    /// Durations are cached by path and modification date (a new video written to the same name gets its own).
    static func durationKey(_ url: URL) -> String {
        // Through FileManager: a URL caches its resource values, so the same URL would keep reporting the old date.
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return "\(url.path)|\(date?.timeIntervalSince1970 ?? 0)"
    }

    static func cachedDuration(_ url: URL) -> Double? { durations[durationKey(url)] }

    /// A video's duration in seconds (main thread callback; nil when it can't be read).
    static func loadDuration(_ url: URL, completion: @escaping (Double?) -> Void) {
        let path = durationKey(url)
        if let d = durations[path] { completion(d); return }
        guard isVideo(url) else { completion(nil); return }
        if waitingDurations[path] != nil { waitingDurations[path]?.append(completion); return }
        waitingDurations[path] = [completion]
        Task.detached {
            let seconds = try? await AVURLAsset(url: url).load(.duration).seconds
            await MainActor.run {
                let value = seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                if let value { durations[path] = value }
                (waitingDurations.removeValue(forKey: path) ?? []).forEach { $0(value) }
            }
        }
    }

    /// For snapshots and tests: waits (spinning the run loop) for durations.
    static func preloadDurations(_ urls: [URL], timeout: TimeInterval = 4) {
        var pending = 0
        for url in urls where isVideo(url) { pending += 1; loadDuration(url) { _ in pending -= 1 } }
        let deadline = Date().addingTimeInterval(timeout)
        while pending > 0 && Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
}
