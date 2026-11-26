import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Add Background…: puts a picture on a background — a colour, a soft gradient, one of the Mac's wallpapers or any
/// picture — with padding around it, rounded corners and a soft drop shadow, on a canvas of a chosen shape. On macOS 14
/// and later it can lift the subject off its own background first, so a photo gets a clean new one.
///
/// In the app the petal opens the Add Background window (ImageBackgroundView.swift), whose live preview is drawn by
/// `compose`, the same code that writes the file. On the command line `run` does it from options alone.
enum ImageBackground {
    /// Canvas shapes, as width : height. "Original" (Auto in the window) keeps the picture's own shape.
    enum Canvas: String, CaseIterable {
        case original, square, fourFive = "4:5", nineSixteen = "9:16", sixteenNine = "16:9"

        var title: String {
            switch self {
            case .original: return "Original"
            case .square: return "Square"
            default: return rawValue
            }
        }

        /// The short name the window's ratio control shows.
        var shortTitle: String {
            switch self {
            case .original: return "Auto"
            case .square: return "1:1"
            default: return rawValue
            }
        }

        var ratio: CGFloat? {
            switch self {
            case .original: return nil
            case .square: return 1
            case .fourFive: return 4.0 / 5
            case .nineSixteen: return 9.0 / 16
            case .sixteenNine: return 16.0 / 9
            }
        }

        init?(option: String) {
            let s = option.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "x", with: ":")
            if s == "1:1" { self = .square; return }
            if s == "auto" { self = .original; return }
            guard let match = Canvas.allCases.first(where: { $0.rawValue == s || $0.title.lowercased() == s }) else { return nil }
            self = match
        }
    }

    /// Largest padding, in % of the picture's long side.
    static let maxPadding = 45.0
    /// Largest corner radius, in % of the picture's short side (50 would make the short side a half circle).
    static let maxCorners = 25.0
    /// Shadow strength runs from 0 (none) to 100.
    static let maxShadow = 100.0

    /// Whether this Mac can lift subjects (VNGenerateForegroundInstanceMaskRequest, macOS 14 and later).
    /// Tests set `liftOverride` to false to check how a macOS 13 Mac behaves.
    static var liftOverride: Bool?
    static var canLift: Bool {
        if let liftOverride { return liftOverride }
        if #available(macOS 14.0, *) { return true }
        return false
    }

    // MARK: Gradients

    /// A soft, many-coloured background drawn in code: a diagonal blend with a few glows on top, so it looks the
    /// same at any size and needs no files.
    struct Gradient: Equatable {
        struct Glow: Equatable {
            let x: CGFloat, y: CGFloat   // centre, 0…1 from the top-left corner
            let radius: CGFloat          // in units of the canvas's long side
            let hex: String
            let alpha: CGFloat
        }
        let id: String
        let name: String
        /// Top-left to bottom-right.
        let stops: [String]
        let glows: [Glow]

        static func == (a: Gradient, b: Gradient) -> Bool { a.id == b.id }
    }

    static let gradients: [Gradient] = [
        Gradient(id: "sunset", name: "Sunset", stops: ["#FF4E7A", "#FF7A45", "#FFC93C"], glows: [
            .init(x: 0.92, y: 0.08, radius: 0.55, hex: "#FFE66B", alpha: 0.95),
            .init(x: 0.08, y: 0.95, radius: 0.6, hex: "#B45CF0", alpha: 0.8),
            .init(x: 0.75, y: 0.85, radius: 0.45, hex: "#6A7BFF", alpha: 0.55)]),
        Gradient(id: "dawn", name: "Dawn", stops: ["#F7F8FC", "#EEF1FA", "#FBEFF6"], glows: [
            .init(x: 0.1, y: 0.1, radius: 0.6, hex: "#9EC2FF", alpha: 0.75),
            .init(x: 0.92, y: 0.9, radius: 0.6, hex: "#FFB8DA", alpha: 0.75)]),
        Gradient(id: "prism", name: "Prism", stops: ["#FFE9A8", "#FFC4D6", "#B9E4FF"], glows: [
            .init(x: 0.15, y: 0.2, radius: 0.5, hex: "#FFD34E", alpha: 0.85),
            .init(x: 0.85, y: 0.3, radius: 0.5, hex: "#FF7EB6", alpha: 0.7),
            .init(x: 0.5, y: 0.95, radius: 0.55, hex: "#5CE1B9", alpha: 0.7)]),
        Gradient(id: "aurora", name: "Aurora", stops: ["#1B1446", "#3A1C71", "#0F3D5E"], glows: [
            .init(x: 0.2, y: 0.25, radius: 0.55, hex: "#FF4FA3", alpha: 0.75),
            .init(x: 0.85, y: 0.3, radius: 0.5, hex: "#FFB347", alpha: 0.55),
            .init(x: 0.6, y: 0.9, radius: 0.6, hex: "#3DD6F5", alpha: 0.6)]),
        Gradient(id: "ocean", name: "Ocean", stops: ["#2E6BFF", "#2FA8F0", "#5FE3E8"], glows: [
            .init(x: 0.9, y: 0.1, radius: 0.5, hex: "#C9F7FF", alpha: 0.7),
            .init(x: 0.1, y: 0.9, radius: 0.55, hex: "#5A3CF0", alpha: 0.6)]),
        Gradient(id: "peach", name: "Peach", stops: ["#FFF1E4", "#FFD9C2", "#FFC0A8"], glows: [
            .init(x: 0.85, y: 0.15, radius: 0.5, hex: "#FFE9A3", alpha: 0.8),
            .init(x: 0.15, y: 0.9, radius: 0.55, hex: "#FF9CB0", alpha: 0.6)]),
    ]

    static func gradient(_ id: String) -> Gradient? {
        let s = id.trimmingCharacters(in: .whitespaces).lowercased()
        return gradients.first { $0.id == s || $0.name.lowercased() == s }
    }

    /// Paints `gradient` over `rect` (Core Graphics coordinates, y up).
    static func paint(_ gradient: Gradient, in rect: CGRect, ctx: CGContext) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = gradient.stops.compactMap { NSColor(hex: $0)?.cgColor } as CFArray
        let locations: [CGFloat] = gradient.stops.indices.map { CGFloat($0) / CGFloat(max(gradient.stops.count - 1, 1)) }
        ctx.saveGState()
        ctx.clip(to: rect)
        if let g = CGGradient(colorsSpace: space, colors: colors, locations: locations) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
        }
        let long = max(rect.width, rect.height)
        for glow in gradient.glows {
            guard let c = NSColor(hex: glow.hex)?.usingColorSpace(.sRGB) else { continue }
            let inner = c.withAlphaComponent(glow.alpha).cgColor, outer = c.withAlphaComponent(0).cgColor
            guard let g = CGGradient(colorsSpace: space, colors: [inner, outer] as CFArray, locations: [0, 1]) else { continue }
            let center = CGPoint(x: rect.minX + glow.x * rect.width, y: rect.maxY - glow.y * rect.height)
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: glow.radius * long, options: [])
        }
        ctx.restoreGState()
    }

    // MARK: Wallpapers

    /// One of the Mac's own desktop pictures (or the one on the desktop now).
    struct Wallpaper: Equatable {
        let name: String
        let url: URL
        /// A small copy for the swatch, when macOS keeps one.
        let thumbnail: URL?
    }

    static let wallpaperFolder = URL(fileURLWithPath: "/System/Library/Desktop Pictures")

    /// The desktop pictures that are real files on this Mac, big enough for a background: the one on the desktop
    /// now first, then the full-size pictures macOS ships (most of its wallpapers are only downloaded when chosen in
    /// System Settings, so they aren't here). Reads file headers only.
    static func wallpapers() -> [Wallpaper] {
        let fm = FileManager.default
        var found: [Wallpaper] = []
        var seen = Set<String>()
        func add(_ url: URL, name: String) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path), isUsableWallpaper(url) else { return }
            seen.insert(path)
            let thumb = wallpaperFolder.appendingPathComponent(".thumbnails/\(url.deletingPathExtension().lastPathComponent).heic")
            found.append(Wallpaper(name: name, url: url, thumbnail: fm.fileExists(atPath: thumb.path) ? thumb : nil))
        }
        if let screen = NSScreen.main ?? NSScreen.screens.first, let current = NSWorkspace.shared.desktopImageURL(for: screen),
           current.isFileURL, !current.path.contains("/.thumbnails/") {
            add(current, name: "Current Wallpaper")
        }
        let images = Set(["heic", "jpg", "jpeg", "png"])
        var files = (try? fm.contentsOfDirectory(at: wallpaperFolder, includingPropertiesForKeys: nil)) ?? []
        let nested = wallpaperFolder.appendingPathComponent(".wallpapers")
        for folder in (try? fm.contentsOfDirectory(at: nested, includingPropertiesForKeys: nil)) ?? [] {
            files += (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        }
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where images.contains(url.pathExtension.lowercased()) {
            add(url, name: url.deletingPathExtension().lastPathComponent)
        }
        return found
    }

    /// A readable picture at least 1,000 pixels on its short side (the solid colours macOS ships are 128 px).
    private static func isUsableWallpaper(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return false }
        return min(w, h) >= 1000
    }

    /// A background picture decoded upright at most `maxPixels` on its long side (a 6K wallpaper decodes small
    /// for the preview and only as big as the canvas for the file).
    static func loadPicture(_ url: URL, maxPixels: Int) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixels),
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { throw ConversionError.unsupported("Couldn’t open the background picture “\(url.lastPathComponent)”.") }
        return image
    }

    // MARK: Style

    /// What fills the canvas behind the picture.
    enum Fill: Equatable {
        case color(NSColor)
        case gradient(Gradient)
        case image(URL)

        var isOpaque: Bool {
            if case .color(let c) = self { return c.alphaComponent >= 1 }
            return true
        }
    }

    /// Everything that decides the result, from options or from the window.
    struct Style: Equatable {
        var fill: Fill = .color(.white)
        var canvas: Canvas = .original
        /// % of the picture's long side.
        var padding: Double = 0
        /// % of the picture's short side.
        var corners: Double = 0
        /// 0…100.
        var shadow: Double = 0
        var lift = false

        /// The options that reproduce this style on the command line (and that Save runs the command with).
        var options: ToolOptions {
            var o: ToolOptions = ["canvas": canvas.rawValue, "padding": Self.number(padding), "corners": Self.number(corners),
                                  "shadow": Self.number(shadow), "lift": lift ? "true" : "false"]
            switch fill {
            case .color(let c): o["color"] = c.hexString
            case .gradient(let g): o["gradient"] = g.id
            case .image(let url): o["image"] = url.path
            }
            return o
        }

        private static func number(_ v: Double) -> String {
            v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        }
    }

    /// Reads and checks the options: color=#RRGGBB(AA), gradient=<name>, image=<path> (image, then gradient, then
    /// colour wins), canvas, padding, corners, shadow, lift.
    static func style(_ options: ToolOptions) throws -> Style {
        var style = Style()
        if let path = options["image"]?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw ConversionError.unsupported("The background picture “\(path)” isn’t there or can’t be read.")
            }
            style.fill = .image(url)
        } else if let name = options["gradient"], !name.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let g = gradient(name) else {
                throw ConversionError.unsupported("“\(name)” isn’t a gradient. Use one of: "
                                                  + gradients.map { $0.id }.joined(separator: ", ") + ".")
            }
            style.fill = .gradient(g)
        } else {
            style.fill = .color(try ImageExtras.hexColor(options.string("color", "#FFFFFF")))
        }
        guard let canvas = Canvas(option: options.string("canvas", "original")) else {
            throw ConversionError.unsupported("“\(options["canvas"] ?? "")” isn’t a canvas. Use original, square, 4:5, 9:16 or 16:9.")
        }
        style.canvas = canvas
        func number(_ key: String, max: Double, what: String) throws -> Double {
            let text = options.string(key, "0").replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")
            guard let v = Double(text), v.isFinite, (0...max).contains(v) else {
                throw ConversionError.unsupported("\(what) must be a number from 0 to \(Int(max))\(key == "shadow" ? "" : " (% of the \(key == "padding" ? "long" : "short") side)").")
            }
            return v
        }
        style.padding = try number("padding", max: maxPadding, what: "Padding")
        style.corners = try number("corners", max: maxCorners, what: "Corners")
        style.shadow = try number("shadow", max: maxShadow, what: "Shadow")
        style.lift = options.bool("lift", false)
        return style
    }

    // MARK: Drawing

    /// Where the picture sits and how big the canvas is, for a `width` × `height` picture.
    struct Layout {
        let canvas: CGSize
        let picture: CGRect   // Core Graphics coordinates (y up), whole pixels
        let radius: CGFloat
        let shadowBlur: CGFloat
        let shadowOffset: CGFloat
        let shadowAlpha: CGFloat
    }

    static func layout(width: Int, height: Int, style: Style) -> Layout {
        let size = canvasSize(width: width, height: height, canvas: style.canvas, padding: style.padding)
        // Whole-pixel placement keeps the picture's pixels exactly as they were.
        let x = (size.width - width) / 2, y = (size.height - height) / 2
        let long = CGFloat(max(width, height)), short = CGFloat(min(width, height))
        let t = CGFloat(style.shadow / maxShadow)
        return Layout(canvas: CGSize(width: size.width, height: size.height),
                      picture: CGRect(x: x, y: y, width: width, height: height),
                      radius: short * CGFloat(style.corners / 100),
                      shadowBlur: long * 0.07 * t, shadowOffset: long * 0.022 * t, shadowAlpha: 0.12 + 0.3 * t)
    }

    /// Draws the whole result into `ctx`, whose current transform maps canvas pixels to the target with `scale`
    /// (1 when writing the file, smaller for the preview). `picture` may be a smaller copy of the
    /// `pictureSize`-pixel original: it is drawn into the original's place. `background` is the decoded picture for
    /// an image fill. Shadows ignore the transform, so they are scaled here.
    static func compose(_ picture: CGImage, pictureSize: CGSize, style: Style, background: CGImage?, ctx: CGContext, scale: CGFloat = 1) {
        let l = layout(width: Int(pictureSize.width), height: Int(pictureSize.height), style: style)
        let full = CGRect(origin: .zero, size: l.canvas)
        switch style.fill {
        case .color(let c):
            ctx.setFillColor(c.cgColor)
            ctx.fill(full)
        case .gradient(let g):
            paint(g, in: full, ctx: ctx)
        case .image:
            if let background {
                // Fill the canvas, cropping the picture's longer side evenly.
                let bw = CGFloat(background.width), bh = CGFloat(background.height)
                let s = max(full.width / bw, full.height / bh)
                let w = bw * s, h = bh * s
                ctx.saveGState()
                ctx.interpolationQuality = .high
                ctx.clip(to: full)
                ctx.draw(background, in: CGRect(x: (full.width - w) / 2, y: (full.height - h) / 2, width: w, height: h))
                ctx.restoreGState()
            } else {
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(full)
            }
        }
        let rect = l.picture
        guard l.radius > 0 || style.shadow > 0 else {
            ctx.draw(picture, in: rect)
            return
        }
        ctx.saveGState()
        if style.shadow > 0 {
            ctx.setShadow(offset: CGSize(width: 0, height: -l.shadowOffset * scale), blur: l.shadowBlur * scale,
                          color: NSColor(white: 0, alpha: l.shadowAlpha).cgColor)
        }
        // The shadow falls from the picture's own shape: its rounded corners, and a lifted subject's outline.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if l.radius > 0 {
            let r = min(l.radius, rect.width / 2, rect.height / 2)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.clip()
        }
        ctx.interpolationQuality = .high
        ctx.draw(picture, in: rect)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // MARK: Running

    /// Options: color=#RRGGBB (default white; #RRGGBBAA for a see-through one), gradient=<sunset|dawn|…>,
    /// image=<path of a picture to fill with, such as a wallpaper>, canvas=original|square|4:5|9:16|16:9 (default
    /// original), padding=0…45 (% of the long side, default 0), corners=0…25 (radius, % of the short side, default 0),
    /// shadow=0…100 (default 0), lift=true|false (default false; macOS 14 and later). Writes "<name> background.<ext>":
    /// the source's format, or PNG when see-through pixels remain or that format can't hold the result (an icon on a
    /// 16:9 canvas). Animated GIFs and TIFF pages keep every frame (subject lifting works on single pictures only).
    static func run(_ url: URL, options: ToolOptions) throws -> URL {
        let name = url.lastPathComponent
        let style = try style(options)
        if style.lift && !canLift {
            throw ConversionError.unsupported("Removing a photo’s own background needs macOS 14 or later. Turn off “Remove photo’s "
                                              + "own background” to keep the picture as it is.")
        }
        let source = try SourceImage(url)
        try source.requireEveryFrame()
        if style.lift && source.frameCount > 1 {
            throw ConversionError.unsupported("“Remove photo’s own background” works on single pictures; \(name) has \(source.frameCount) frames.")
        }
        try checkResultSize(source, canvas: style.canvas, padding: style.padding, name: name)
        var first = try source.frame(0)
        if style.lift {
            if #available(macOS 14.0, *) { first = try liftSubject(first, name: name) }
        }
        let seeThrough = style.lift || ImageExtras.isTransparent(first)
            || (1..<min(3, source.frameCount)).contains { (try? source.frame($0)).map(ImageExtras.isTransparent) ?? false }
        guard seeThrough || style.canvas != .original || style.padding > 0 || style.corners > 0 else {
            throw ConversionError.unsupported("\(name) has no see-through pixels to fill. Choose a canvas shape, some padding "
                                              + "or rounded corners" + (canLift ? ", or turn on “Remove photo’s own background”." : "."))
        }
        var background: CGImage?
        if case .image(let bgURL) = style.fill {
            let size = canvasSize(width: first.width, height: first.height, canvas: style.canvas, padding: style.padding)
            background = try loadPicture(bgURL, maxPixels: max(size.width, size.height))
        }
        let opaque = style.fill.isOpaque
        // One source frame decoded at a time; the finished frames stay in memory until they are written.
        var filled: [CGImage] = []
        filled.reserveCapacity(source.frameCount)
        for i in 0..<source.frameCount {
            try autoreleasepool {
                filled.append(try place(i == 0 ? first : try source.frame(i), style: style, background: background, opaque: opaque))
            }
        }
        // A see-through colour leaves transparency, which only PNG keeps here; otherwise the source's own format,
        // or PNG when that format can't hold the result (an icon made non-square or bigger than icons go), as the
        // image editors do.
        func save(_ type: String, _ ext: String) throws -> URL {
            let out = outputURL(for: url, ext: ext, suffix: " background")
            try ImageExtras.save(filled, to: out, type: type, quality: 0.92,
                                 metadata: { source.metadata(frame: $0, width: filled[$0].width, height: filled[$0].height, as: type) },
                                 fileProperties: filled.count > 1 ? source.fileProperties(as: type) : [:])
            return out
        }
        let outType = opaque ? source.outType : UTType.png.identifier
        do { return try save(outType, opaque ? source.outExt : "png") }
        catch where outType != UTType.png.identifier { return try save(UTType.png.identifier, "png") }
    }

    /// The most pixels an animation's result may hold in all its frames together. Every frame stays in memory
    /// until the file is written, and writing a GIF needs about 13 bytes per pixel at its peak (measured: 345
    /// megapixels took 4.6 GB), while a GIF of a few kilobytes can claim hundreds of 4-megapixel frames (a 23 KB
    /// one with 200 took 11.5 GB; 1,000 would need about 60). 400 megapixels keeps the peak near 5 GB and still
    /// takes a 25-second 720p screen recording (250 frames, 319 megapixels with a 16:9 canvas).
    static let maxAnimationPixels = 400_000_000.0

    /// Refuses, from the file's header and before decoding anything, a result that is too big: a picture beyond
    /// the largest image YummyOrange makes (a PNG of a few megabytes can claim 60,000 × 60,000 pixels, and decoding
    /// it first took 7.2 GB), or an animation or multi-page file whose frames together would not fit in memory.
    static func checkResultSize(_ source: SourceImage, canvas: Canvas, padding: Double, name: String) throws {
        var total = 0.0
        for i in 0..<source.frameCount {
            var w = source.width, h = source.height
            if source.frameCount > 1 {
                let p = CGImageSourceCopyPropertiesAtIndex(source.source, i, nil) as? [CFString: Any] ?? [:]
                w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? source.width
                h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? source.height
                if ((p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5 { swap(&w, &h) }
            }
            let size = canvasSize(width: max(w, 1), height: max(h, 1), canvas: canvas, padding: padding)
            do { try ImageExtras.checkSize(Double(size.width), Double(size.height)) } catch {
                throw ConversionError.unsupported("\(name) is \(w) × \(h) pixels; with the background it would be \(size.width) × "
                                                  + "\(size.height), more than YummyOrange can make (\(ImageExtras.maxPixels / 1_000_000) "
                                                  + "megapixels, \(ImageExtras.maxEdge.formatted()) pixels a side). Make it smaller first (Half Size)"
                                                  + (padding > 0 ? ", or use less padding." : "."))
            }
            total += Double(size.width) * Double(size.height)
        }
        guard source.frameCount == 1 || total <= maxAnimationPixels else {
            throw ConversionError.unsupported("\(name) has \(source.frameCount) frames of \(source.width) × \(source.height) pixels; with "
                                              + "the background that is \(Int(total / 1_000_000)) megapixels in all, more than the "
                                              + "\(Int(maxAnimationPixels / 1_000_000)) YummyOrange can hold at once. Make it smaller first "
                                              + "(Half Size), or use fewer frames.")
        }
    }

    /// The canvas size for a `width` × `height` picture: padding on every side (whole pixels), then grown in
    /// one direction to the canvas shape.
    static func canvasSize(width: Int, height: Int, canvas: Canvas, padding: Double) -> (width: Int, height: Int, pad: Int) {
        let pad = Int((padding / 100 * Double(max(width, height))).rounded())
        var w = Double(width + 2 * pad), h = Double(height + 2 * pad)
        if let r = canvas.ratio.map(Double.init) {
            if w / h > r { h = (w / r).rounded() } else { w = (h * r).rounded() }
        }
        return (Int(w), Int(h), pad)
    }

    private static func place(_ image: CGImage, style: Style, background: CGImage?, opaque: Bool) throws -> CGImage {
        let size = canvasSize(width: image.width, height: image.height, canvas: style.canvas, padding: style.padding)
        try ImageExtras.checkSize(Double(size.width), Double(size.height))
        let ctx = try ImageExtras.canvas(size.width, size.height, like: image, opaque: opaque)
        compose(image, pictureSize: CGSize(width: image.width, height: image.height), style: style, background: background, ctx: ctx)
        guard let out = ctx.makeImage() else { throw ConversionError.toolFailed("Couldn’t add the background.") }
        return out
    }

    /// The picture with everything but its subject (people, pets, objects) made see-through.
    @available(macOS 14.0, *)
    static func liftSubject(_ image: CGImage, name: String) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw ConversionError.unsupported("There’s no person, pet or object to cut out of \(name). “Remove photo’s own "
                                              + "background” is for photos; leave it off for documents and screenshots.")
        }
        let mask = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        let input = CIImage(cgImage: image)
        let maskImage = CIImage(cvPixelBuffer: mask)
        let sx = input.extent.width / maskImage.extent.width, sy = input.extent.height / maskImage.extent.height
        let fittedMask = sx == 1 && sy == 1 ? maskImage : maskImage.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let cut = input.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                       kCIInputMaskImageKey: fittedMask])
        let space = ImageEditors.outputColorSpace(for: image)
        guard let out = ImageEditors.renderContext.createCGImage(cut, from: input.extent, format: .RGBA8, colorSpace: space) else {
            throw ConversionError.toolFailed("Couldn’t lift the subject from \(name).")
        }
        return out
    }
}
