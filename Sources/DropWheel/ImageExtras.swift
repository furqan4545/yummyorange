import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Image tools without a window: resize to a chosen size, add a frame, collage, read QR codes; SVG and camera RAW input.
enum ImageExtras: FeatureModule {
    static var commands: [WheelCommand] {
        [
            WheelCommand(wheel: .tools, id: "resize", title: "Resize…", symbol: "arrow.up.left.and.arrow.down.right",
                         applies: allImages, ask: askResize,
                         run: { urls, options, progress in try each(urls, progress) { try resize($0, options: options) } }),
            WheelCommand(wheel: .tools, id: "frame", title: "Add Frame…", symbol: "photo.artframe",
                         applies: allImages, ask: askFrame,
                         run: { urls, options, progress in try each(urls, progress) { try frame($0, options: options) } }),
            WheelCommand(wheel: .tools, id: "collage", title: "Collage…", symbol: "square.grid.2x2", combinesInputs: true,
                         applies: { $0.count >= 2 && allImages($0) }, ask: askCollage,
                         run: { urls, options, progress in [try collage(urls, options: options, progress: progress)] }),
            WheelCommand(wheel: .tools, id: "qr", title: "Read QR Code", symbol: "qrcode.viewfinder", combinesInputs: true,
                         applies: allImages,
                         run: { urls, options, progress in try BarcodeReader.run(urls, options: options, progress: progress) }),
        ]
    }

    // MARK: Contract with Converter

    /// Contract (called by Converter.source): SVG → a bitmap image source, so every image conversion
    /// and image tool accepts SVG files. Drawn at 2× the SVG's size (long edge at most 4096 px), with
    /// transparency, as an in-memory PNG whose DPI keeps the SVG's own size in points.
    static func svgSource(_ url: URL) throws -> CGImageSource {
        let (data, info) = try SVGRenderer.load(url)
        let px = SVGRenderer.defaultPixelSize(info)
        let image = try SVGRenderer.render(data, info: info, width: px.width, height: px.height, name: url.lastPathComponent)
        let png = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw ConversionError.toolFailed("Couldn’t draw \(url.lastPathComponent).")
        }
        let dpi = 72 * Double(px.scale)
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let src = CGImageSourceCreateWithData(png, nil) else {
            throw ConversionError.toolFailed("Couldn’t draw \(url.lastPathComponent).")
        }
        return src
    }

    /// Contract (called by Converter.convertImage for SVG → PDF): write a vector PDF next to the source
    /// and return it, or return nil to fall back to a PDF of the rendered bitmap.
    static func svgToPDF(_ url: URL) throws -> URL? {
        let (data, info) = try SVGRenderer.load(url)
        let out = outputURL(for: url, ext: "pdf")
        guard SVGRenderer.writePDF(data, info: info, to: out, name: url.lastPathComponent) else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }

    // MARK: Petal helpers

    private static func allImages(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy { FileKind.of($0) == .image }
    }

    /// Runs `body` on each file in turn and reports progress per file.
    private static func each(_ urls: [URL], _ progress: @escaping (Double) -> Void, _ body: (URL) throws -> URL) throws -> [URL] {
        var outputs: [URL] = []
        for (i, url) in urls.enumerated() {
            outputs.append(try body(url))
            progress(Double(i + 1) / Double(urls.count))
        }
        return outputs
    }

    /// The last answers to a form, so the next one starts from them (app mode only).
    static func remembered(_ form: String) -> ToolOptions {
        UserDefaults.standard.dictionary(forKey: "ImageExtras." + form) as? [String: String] ?? [:]
    }

    static func remember(_ options: ToolOptions, as form: String) {
        UserDefaults.standard.set(options, forKey: "ImageExtras." + form)
    }

    /// A remembered number for a form field, or `fallback` when it's missing, not finite or absurdly big:
    /// a saved "1e20" or "inf" must not stop the form from opening next time.
    static func rememberedNumber(_ last: ToolOptions, _ key: String, _ fallback: Double) -> Double {
        let v = last.double(key, fallback)
        return v.isFinite && abs(v) < 1e9 ? v : fallback
    }

    /// "photo.png is 1600 × 1000 pixels." for one file, "3 images." for several. An SVG has no pixel
    /// size of its own, so its note gives its size in points and what 100% is.
    private static func sizeNote(_ urls: [URL]) -> String {
        guard urls.count == 1 else { return "\(urls.count) images." }
        let name = urls[0].lastPathComponent
        if Ext.svg.contains(Ext.of(urls[0])) {
            guard let info = try? SVGRenderer.load(urls[0]).info else { return "" }
            let px = SVGRenderer.defaultPixelSize(info)
            func points(_ v: CGFloat) -> String { v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", Double(v)) }
            return "\(name) is a vector image of \(points(info.size.width)) × \(points(info.size.height)) points "
                + "(100% is \(px.width) × \(px.height) pixels)."
        }
        guard let size = try? pixelSize(urls[0]) else { return "" }
        return "\(name) is \(size.width) × \(size.height) pixels."
    }

    /// Upright pixel size without decoding (an SVG's is the size it's drawn at).
    static func pixelSize(_ url: URL) throws -> (width: Int, height: Int) {
        if Ext.svg.contains(Ext.of(url)) {
            let px = SVGRenderer.defaultPixelSize(try SVGRenderer.load(url).info)
            return (px.width, px.height)
        }
        let image = try SourceImage(url)
        return (image.width, image.height)
    }

    // MARK: - Resize

    enum ResizeMode: String, CaseIterable {
        case percent, width, height, longEdge

        var label: String {
            switch self {
            case .percent: return "Percentage"
            case .width: return "Width"
            case .height: return "Height"
            case .longEdge: return "Long edge"
            }
        }

        /// Accepts the ids, the form's labels and a few common spellings.
        init?(option: String) {
            let s = option.lowercased().filter { $0.isLetter || $0 == "%" }
            switch s {
            case "percent", "percentage", "%", "pct", "scale": self = .percent
            case "width", "w": self = .width
            case "height", "h": self = .height
            case "longedge", "long", "longest", "longestedge", "longside", "max", "edge": self = .longEdge
            default: return nil
            }
        }
    }

    /// The size `width` × `height` becomes, keeping the aspect ratio; the side that was asked for is exact.
    /// Never traps: a side beyond `maxEdge` (or not finite) comes back as `maxEdge + 1`, which checkSize refuses.
    static func resizedSize(width: Int, height: Int, mode: ResizeMode, value: Double) -> (width: Int, height: Int) {
        let w = Double(width), h = Double(height)
        let scale: Double
        switch mode {
        case .percent: scale = value / 100
        case .width: scale = value / w
        case .height: scale = value / h
        case .longEdge: scale = value / max(w, h)
        }
        var size = (width: pixelCount(w * scale), height: pixelCount(h * scale))
        let exact = pixelCount(value)
        switch mode {
        case .width: size.width = exact
        case .height: size.height = exact
        case .longEdge: if width >= height { size.width = exact } else { size.height = exact }
        case .percent: break
        }
        return size
    }

    private static func askResize(_ urls: [URL]) -> ToolOptions? {
        let last = remembered("resize")
        let mode = ResizeMode(option: last.string("mode", "percent")) ?? .percent
        guard var answer = Ask.form(title: "Resize", message: sizeNote(urls), fields: [
            .choice(key: "mode", label: "Resize by:", options: ResizeMode.allCases.map(\.label), selected: mode.label),
            .number(key: "value", label: "Size:", value: rememberedNumber(last, "value", mode == .percent ? 50 : 1920),
                    unit: "% or pixels"),
            .toggle(key: "upscale", label: "Allow enlarging", on: last.bool("upscale", false)),
        ], button: "Resize") else { return nil }
        answer["mode"] = (ResizeMode(option: answer["mode"] ?? "") ?? .percent).rawValue
        remember(answer, as: "resize")
        return answer
    }

    /// Options: mode=percent|width|height|longEdge (default percent), value=<number> (default 50 for
    /// percent, else 1920), upscale=true|false (default false; SVG never needs it). Same format as the source
    /// when ImageIO can write it (else PNG), metadata kept, every frame of an animated GIF or PNG resized.
    static func resize(_ url: URL, options: ToolOptions) throws -> URL {
        guard let mode = ResizeMode(option: options.string("mode", "percent")) else {
            throw ConversionError.unsupported("“\(options["mode"] ?? "")” isn’t a way to resize. Use percent, width, height or longEdge.")
        }
        let value = try number(options, "value", mode == .percent ? 50 : 1920)
        guard value.isFinite, value > 0 else { throw ConversionError.unsupported("Enter a size bigger than zero.") }
        let enlarge = options.bool("upscale", false)
        let name = url.lastPathComponent

        let isSVG = Ext.svg.contains(Ext.of(url))
        let original = try pixelSize(url)
        let target = resizedSize(width: original.width, height: original.height, mode: mode, value: value)
        try checkSize(target.width, target.height)
        // A vector has no pixel size of its own (`original` is only its default raster), so any size is
        // drawn fresh and sharp: no “Allow enlarging” and no “already that size” for SVG.
        if !isSVG {
            if target.width > original.width || target.height > original.height, !enlarge {
                throw ConversionError.unsupported("\(name) is \(original.width) × \(original.height) pixels, smaller than that. "
                                                  + "Turn on “Allow enlarging” to make it bigger.")
            }
            if target == original { throw ConversionError.unsupported("\(name) is already \(original.width) × \(original.height) pixels.") }
        }

        if isSVG {
            // Vector source: draw it straight at the new size, so even enlargements stay sharp.
            let (data, info) = try SVGRenderer.load(url)
            let image = try SVGRenderer.render(data, info: info, width: target.width, height: target.height, name: name)
            let out = outputURL(for: url, ext: "png", suffix: " resized")
            let dpi = 72 * Double(target.width) / Double(info.size.width)
            try save([image], to: out, type: UTType.png.identifier,
                     metadata: { _ in [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] })
            return out
        }

        let source = try SourceImage(url)
        try source.requireEveryFrame()
        // Decode at most twice the target size, then scale down with high-quality interpolation.
        let decodeLimit = min(max(source.width, source.height), 2 * max(target.width, target.height))
        var frames: [CGImage] = []
        for i in 0..<source.frameCount {
            let image = try source.frame(i, maxPixels: decodeLimit)
            var size = target
            if source.frameCount > 1 {
                // TIFF pages can differ in size: each follows the same rule, and later pages are never enlarged
                // unless asked.
                size = resizedSize(width: image.width, height: image.height, mode: mode, value: value)
                if !enlarge, size.width > image.width || size.height > image.height { size = (image.width, image.height) }
                try checkSize(size.width, size.height)
            }
            let opaque = !hasAlphaChannel(image)
            let ctx = try canvas(size.width, size.height, like: image, opaque: opaque, keepGray: opaque)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            guard let resized = ctx.makeImage() else { throw ConversionError.toolFailed("Couldn’t resize \(name).") }
            frames.append(resized)
        }
        let out = outputURL(for: url, ext: source.outExt, suffix: " resized")
        try save(frames, to: out, type: source.outType, quality: 0.9,
                 metadata: { source.metadata(frame: $0, width: frames[$0].width, height: frames[$0].height) },
                 fileProperties: source.fileProperties)
        return out
    }

    // MARK: - Add Frame

    enum FrameUnit: String {
        case px, percent
        init?(option: String) {
            switch option.lowercased().trimmingCharacters(in: .whitespaces) {
            case "px", "pixel", "pixels": self = .px
            case "%", "percent", "pct", "% of short side": self = .percent
            default: return nil
            }
        }
    }

    private static func askFrame(_ urls: [URL]) -> ToolOptions? {
        let last = remembered("frame")
        let unit = FrameUnit(option: last.string("unit", "percent")) ?? .percent
        let unitLabels = ["% of short side", "pixels"]
        guard var answer = Ask.form(title: "Add Frame", message: sizeNote(urls), fields: [
            .number(key: "width", label: "Border:", value: rememberedNumber(last, "width", 5)),
            .choice(key: "unit", label: "Measured in:", options: unitLabels, selected: unit == .px ? unitLabels[1] : unitLabels[0]),
            .color(key: "color", label: "Border color:", hex: last.string("color", "#FFFFFF")),
            .number(key: "radius", label: "Corner radius:", value: rememberedNumber(last, "radius", 0)),
            .number(key: "padding", label: "Inner padding:", value: rememberedNumber(last, "padding", 0)),
            .color(key: "padColor", label: "Padding color:", hex: last.string("padColor", "#FFFFFF")),
        ], button: "Add Frame") else { return nil }
        answer["unit"] = (FrameUnit(option: answer["unit"] ?? "") ?? .percent).rawValue
        remember(answer, as: "frame")
        return answer
    }

    /// Options: width=<border> (default 5), unit=percent|px (default percent: % of the short side, for
    /// width, radius and padding), color=#RRGGBB[AA] (default white), radius=<corner radius> (default 0),
    /// padding=<inner padding> (default 0), padColor=#RRGGBB[AA] (default white).
    /// PNG when the result has transparency (rounded corners, see-through colours or source) unless the
    /// source is already PNG or TIFF; otherwise the source's format. An animated GIF keeps every frame: it
    /// stays a GIF (on/off transparency) unless a border or padding colour is partly see-through, which
    /// only an animated PNG can hold. A border or padding that rounds to less than a pixel is 1 pixel.
    static func frame(_ url: URL, options: ToolOptions) throws -> URL {
        let name = url.lastPathComponent
        guard let unit = FrameUnit(option: options.string("unit", "percent")) else {
            throw ConversionError.unsupported("“\(options["unit"] ?? "")” isn’t a unit. Use px or percent.")
        }
        let color = try hexColor(options.string("color", "#FFFFFF"))
        let padColor = try hexColor(options.string("padColor", "#FFFFFF"))
        let raw = (border: try number(options, "width", 5), radius: try number(options, "radius", 0),
                   padding: try number(options, "padding", 0))
        guard [raw.border, raw.radius, raw.padding].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw ConversionError.unsupported("Border, corner radius and padding can’t be negative.")
        }
        guard raw.border > 0 || raw.radius > 0 || raw.padding > 0 else {
            throw ConversionError.unsupported("Set a border, a corner radius or some padding.")
        }

        let source = try SourceImage(url)
        try source.requireEveryFrame()
        let short = Double(min(source.width, source.height))
        func pixels(_ v: Double) -> Double { unit == .percent ? v * short / 100 : v }
        // Whole pixels for border and padding, so the image lands exactly on the pixel grid; anything asked
        // for is at least one pixel, so a small image never gets an unchanged copy called “framed”.
        let borderPx = wholePixels(pixels(raw.border)), paddingPx = wholePixels(pixels(raw.padding))
        // Checked as numbers first: a huge border must be refused, not overflow an Int.
        try checkSize(Double(source.width) + 2 * (borderPx + paddingPx), Double(source.height) + 2 * (borderPx + paddingPx))
        let border = CGFloat(borderPx), padding = CGFloat(paddingPx), radius = CGFloat(pixels(raw.radius))
        let inset = border + padding
        let insetPx = Int(borderPx + paddingPx)

        let frames = try (0..<source.frameCount).map { try source.frame($0) }
        let seeThroughSource = frames.prefix(3).contains(where: isTransparent)
        let transparent = seeThroughSource || radius > 0 || color.alphaComponent < 1 || (padding > 0 && padColor.alphaComponent < 1)
        // Rings only (nothing under the picture or between layers) when anything is see-through.
        let ringsOnly = seeThroughSource || color.alphaComponent < 1 || padColor.alphaComponent < 1
        let keepsAlpha: Set<String> = [UTType.png.identifier, UTType.tiff.identifier]
        var outType = transparent && !keepsAlpha.contains(source.outType) ? UTType.png.identifier : source.outType
        if outType != source.outType, frames.count > 1, source.outType == UTType.gif.identifier {
            // Every frame is kept. GIF transparency is on or off, which holds the source's own see-through
            // pixels and rounded corners; a partly see-through colour needs an animated PNG.
            func partly(_ c: NSColor) -> Bool { c.alphaComponent > 0 && c.alphaComponent < 1 }
            let needsPartialAlpha = (border > 0 && partly(color)) || (padding > 0 && partly(padColor))
            outType = needsPartialAlpha ? UTType.png.identifier : source.outType
        }

        // Each frame gets its own canvas (TIFF pages can differ in size); the border is the same on all.
        let framed = try frames.map { image -> CGImage in
            let width = image.width + 2 * insetPx, height = image.height + 2 * insetPx
            try checkSize(width, height)
            let outer = CGRect(x: 0, y: 0, width: width, height: height)
            let middle = outer.insetBy(dx: border, dy: border)
            let inner = outer.insetBy(dx: inset, dy: inset)
            let outerPath = roundedPath(outer, radius)
            let middlePath = roundedPath(middle, radius - border)
            let innerPath = roundedPath(inner, radius - inset)
            let ctx = try canvas(width, height, like: image, opaque: !transparent)
            if ringsOnly {
                // The picture's own transparency stays see-through, and see-through colours don't stack.
                fillRing(ctx, outerPath, middlePath, color, when: border > 0)
                fillRing(ctx, middlePath, innerPath, padColor, when: padding > 0)
            } else {
                if border > 0 { ctx.addPath(outerPath); ctx.setFillColor(color.cgColor); ctx.fillPath() }
                if padding > 0 { ctx.addPath(middlePath); ctx.setFillColor(padColor.cgColor); ctx.fillPath() }
            }
            ctx.saveGState()
            ctx.addPath(innerPath)
            ctx.clip()
            ctx.draw(image, in: inner)
            ctx.restoreGState()
            guard let result = ctx.makeImage() else { throw ConversionError.toolFailed("Couldn’t frame \(name).") }
            return result
        }
        let outExt = outType == source.outType ? source.outExt : "png"
        let out = outputURL(for: url, ext: outExt, suffix: " framed")
        try save(framed, to: out, type: outType, quality: 0.92,
                 metadata: { source.metadata(frame: $0, width: framed[$0].width, height: framed[$0].height, as: outType) },
                 fileProperties: framed.count > 1 ? source.fileProperties(as: outType) : [:])
        return out
    }

    /// A border or padding in whole pixels: rounded, and at least 1 when anything was asked for.
    static func wholePixels(_ v: Double) -> Double {
        v > 0 ? max(1, v.rounded()) : 0
    }

    private static func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        let r = min(max(0, radius), rect.width / 2, rect.height / 2)
        return r > 0 ? CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil) : CGPath(rect: rect, transform: nil)
    }

    private static func fillRing(_ ctx: CGContext, _ outside: CGPath, _ inside: CGPath, _ color: NSColor, when: Bool) {
        guard when else { return }
        ctx.addPath(outside)
        ctx.addPath(inside)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath(using: .evenOdd)
    }

    /// A number option: the fallback when missing or empty, an error when it isn't a number.
    private static func number(_ options: ToolOptions, _ key: String, _ fallback: Double) throws -> Double {
        let text = options.string(key, "")
        guard !text.isEmpty else { return fallback }
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), v.isFinite else {
            throw ConversionError.unsupported("“\(text)” isn’t a number (\(key)).")
        }
        return v
    }

    static func hexColor(_ text: String) throws -> NSColor {
        guard let color = NSColor(hex: text) else {
            throw ConversionError.unsupported("“\(text)” isn’t a color. Use #RRGGBB, or #RRGGBBAA for see-through.")
        }
        return color
    }

    // MARK: - Collage

    enum CollageFit: String {
        case fill, fit
        init?(option: String) {
            let s = option.lowercased()
            if s.hasPrefix("fill") || s == "crop" { self = .fill }
            else if s.hasPrefix("fit") || s == "contain" || s == "whole" { self = .fit }
            else { return nil }
        }
    }

    private static func askCollage(_ urls: [URL]) -> ToolOptions? {
        let last = remembered("collage")
        let labels = ["Fill cells (crop edges)", "Fit inside cells"]
        let fit = CollageFit(option: last.string("fit", "fill")) ?? .fill
        guard var answer = Ask.form(title: "Collage", message: "\(urls.count) images, in the order they were dragged.", fields: [
            .number(key: "columns", label: "Columns:", value: rememberedNumber(last, "columns", 0), unit: "0 = automatic"),
            .number(key: "width", label: "Width:", value: rememberedNumber(last, "width", 2400), unit: "pixels"),
            .number(key: "spacing", label: "Spacing:", value: rememberedNumber(last, "spacing", 16), unit: "pixels"),
            .color(key: "background", label: "Background:", hex: last.string("background", "#FFFFFF")),
            .choice(key: "fit", label: "Images:", options: labels, selected: fit == .fill ? labels[0] : labels[1]),
        ], button: "Make Collage") else { return nil }
        answer["fit"] = (CollageFit(option: answer["fit"] ?? "") ?? .fill).rawValue
        remember(answer, as: "collage")
        return answer
    }

    /// Columns and rows for `count` cells whose width/height is `aspect`: a landscape 4:3 sheet with as
    /// few empty cells as possible, unless `columns` is given.
    static func collageGrid(count: Int, aspect: Double, columns: Int = 0) -> (columns: Int, rows: Int) {
        guard count > 0 else { return (1, 1) }
        if columns > 0 {
            let c = min(columns, count)
            return (c, (count + c - 1) / c)
        }
        var best = (columns: 1, rows: count, score: Double.infinity)
        for c in 1...count {
            let r = (count + c - 1) / c
            let sheet = Double(c) * aspect / Double(r)
            let score = abs(log(sheet / (4.0 / 3.0))) + 0.35 * Double(c * r - count) / Double(count)
            if score < best.score - 1e-9 { best = (c, r, score) }
        }
        return (best.columns, best.rows)
    }

    /// Options: columns=<n> (default 0, automatic), width=<px> (default 2400), spacing=<px> (default 16,
    /// also the outer margin), background=#RRGGBB[AA] (default white), fit=fill|fit (default fill: crop
    /// to fill each cell; fit shows each whole image). Saves "<first name> collage.jpg", or .png when the
    /// background or any image is see-through.
    static func collage(_ urls: [URL], options: ToolOptions, progress: @escaping (Double) -> Void) throws -> URL {
        guard urls.count >= 2, let first = urls.first else { throw ConversionError.unsupported("A collage needs at least two images.") }
        guard let fit = CollageFit(option: options.string("fit", "fill")) else {
            throw ConversionError.unsupported("“\(options["fit"] ?? "")” isn’t an option. Use fill or fit.")
        }
        let background = try hexColor(options.string("background", "#FFFFFF"))
        // Range-checked as numbers before any Int conversion, so huge values are refused instead of trapping.
        let widthValue = try number(options, "width", 2400).rounded(), spacing = try number(options, "spacing", 16).rounded()
        let columnsValue = try number(options, "columns", 0).rounded()
        guard (100...20_000).contains(widthValue) else { throw ConversionError.unsupported("Pick a width between 100 and 20,000 pixels.") }
        guard spacing >= 0, columnsValue >= 0 else { throw ConversionError.unsupported("Spacing and columns can’t be negative.") }
        let width = Int(widthValue)
        let columns = Int(min(columnsValue, Double(urls.count)))   // more columns than images is one row

        let sources = try urls.map { try SourceImage($0) }
        let aspects = sources.map { Double($0.width) / Double($0.height) }.sorted()
        let aspect = min(2, max(0.5, aspects[aspects.count / 2]))   // median, kept sensible
        let grid = collageGrid(count: sources.count, aspect: aspect, columns: columns)
        let cellW = (Double(width) - spacing * Double(grid.columns + 1)) / Double(grid.columns)
        guard cellW >= 16 else { throw ConversionError.unsupported("That’s too much spacing for that width. Use less spacing or a bigger width.") }
        let cellH = cellW / aspect
        let heightValue = (Double(grid.rows) * cellH + spacing * Double(grid.rows + 1)).rounded()
        try checkSize(Double(width), heightValue)
        let height = Int(heightValue)

        // Draw in the images' own colour space when they all share one (Display P3 stays P3).
        var pending: CGImage? = try sources[0].frame(0, maxPixels: decodeLimit(sources[0], cellW, cellH, fit))
        let sameSpace = Set(sources.map { $0.colorSpaceName ?? "" }).count == 1
        let ctx = try canvas(width, height, like: sameSpace ? pending : nil, opaque: false)
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var anyTransparent = false
        for (i, source) in sources.enumerated() {
            let image = try pending ?? source.frame(0, maxPixels: decodeLimit(source, cellW, cellH, fit))
            pending = nil   // each decoded image is let go once drawn
            anyTransparent = anyTransparent || isTransparent(image)
            let row = i / grid.columns, col = i % grid.columns
            // A short last row is centred.
            let inRow = row == grid.rows - 1 ? sources.count - row * grid.columns : grid.columns
            let shift = Double(grid.columns - inRow) * (cellW + spacing) / 2
            let cell = CGRect(x: spacing + Double(col) * (cellW + spacing) + shift,
                              y: Double(height) - spacing - cellH - Double(row) * (cellH + spacing),
                              width: cellW, height: cellH)
            let iw = Double(image.width), ih = Double(image.height)
            let scale = fit == .fill ? max(cellW / iw, cellH / ih) : min(cellW / iw, cellH / ih)
            let rect = CGRect(x: cell.midX - iw * scale / 2, y: cell.midY - ih * scale / 2, width: iw * scale, height: ih * scale)
            ctx.saveGState()
            ctx.clip(to: cell)
            ctx.draw(image, in: rect)
            ctx.restoreGState()
            progress(Double(i + 1) / Double(sources.count))
        }
        guard let result = ctx.makeImage() else { throw ConversionError.toolFailed("Couldn’t make the collage.") }
        let png = anyTransparent || background.alphaComponent < 1
        let out = outputURL(for: first, ext: png ? "png" : "jpg", suffix: " collage")
        try save([result], to: out, type: png ? UTType.png.identifier : UTType.jpeg.identifier, quality: 0.9,
                 metadata: { _ in [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72] })
        return out
    }

    /// The decode size that still covers the image's drawn size twice over (sharper scaling, less memory).
    private static func decodeLimit(_ source: SourceImage, _ cellW: Double, _ cellH: Double, _ fit: CollageFit) -> Int {
        let w = Double(source.width), h = Double(source.height)
        let scale = fit == .fill ? max(cellW / w, cellH / h) : min(cellW / w, cellH / h)
        let long = max(source.width, source.height)
        let wanted = (max(w, h) * scale * 2).rounded(.up) + 2
        return wanted.isFinite && wanted < Double(long) ? Int(wanted) : long
    }

    // MARK: - Pixels

    /// Results bigger than this many pixels are refused rather than risking running out of memory.
    static let maxPixels = 250_000_000
    /// Results wider or taller than this are refused too.
    static let maxEdge = 65_000

    /// A computed pixel length as an Int, rounded and at least 1, without ever trapping: anything beyond
    /// `maxEdge` (huge, infinite or not a number) becomes `maxEdge + 1`, which checkSize refuses.
    static func pixelCount(_ v: Double) -> Int {
        guard !v.isNaN, v < Double(maxEdge) + 0.5 else { return maxEdge + 1 }
        return v < 1 ? 1 : Int(v.rounded())
    }

    private static func checkSize(_ width: Int, _ height: Int) throws {
        try checkSize(Double(width), Double(height))
    }

    /// Refuses a result size that's too big, compared as numbers so no size can overflow an Int.
    static func checkSize(_ width: Double, _ height: Double) throws {
        let limit = Double(maxEdge)
        guard width.isFinite, height.isFinite, width <= limit, height <= limit else {
            throw ConversionError.unsupported("That would make an image more than 65,000 pixels wide or tall, which is too big. "
                                              + "Pick a smaller size.")
        }
        guard width * height <= Double(maxPixels) else {
            throw ConversionError.unsupported("That would make an image of \(Int(width)) × \(Int(height)) pixels, which is too big. "
                                              + "Pick a smaller size.")
        }
    }

    static func hasAlphaChannel(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Whether any pixel is actually see-through, not just whether there's an alpha channel.
    /// Big images are checked on a copy at most 2048 px wide.
    static func isTransparent(_ image: CGImage) -> Bool {
        guard hasAlphaChannel(image) else { return false }
        let scale = min(1, 2048 / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let pixels = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return true }
        for i in stride(from: 3, to: w * h * 4, by: 4) where pixels[i] < 255 { return true }
        return false
    }

    /// A drawing context with high-quality scaling. RGB sources keep their colour space (Display P3
    /// stays P3) and 16-bit sources stay 16-bit; opaque greyscale ones stay grey when `keepGray`.
    static func canvas(_ width: Int, _ height: Int, like image: CGImage?, opaque: Bool, keepGray: Bool = false) throws -> CGContext {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let deep = (image?.bitsPerComponent ?? 8) > 8
        var attempts: [(Int, CGColorSpace, UInt32)] = []
        if keepGray, opaque, let cs = image?.colorSpace, cs.model == .monochrome {
            attempts.append((deep ? 16 : 8, cs, CGImageAlphaInfo.none.rawValue))
            attempts.append((8, CGColorSpaceCreateDeviceGray(), CGImageAlphaInfo.none.rawValue))
        }
        let space = image?.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil } ?? srgb
        let alpha = (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue
        if deep { attempts.append((16, space, alpha)) }
        attempts += [(8, space, alpha), (8, srgb, CGImageAlphaInfo.premultipliedLast.rawValue)]
        for (bits, cs, info) in attempts {
            if let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0,
                                   space: cs, bitmapInfo: info) {
                ctx.interpolationQuality = .high
                return ctx
            }
        }
        throw ConversionError.toolFailed("Not enough memory for a \(width) × \(height) image.")
    }

    /// Writes one image (or every frame of an animation). A half-written file is removed on failure.
    static func save(_ images: [CGImage], to out: URL, type: String, quality: Double = 0.9,
                     metadata: (Int) -> [CFString: Any], fileProperties: [CFString: Any] = [:]) throws {
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, images.count, nil) else {
            throw ConversionError.unsupported("This Mac can’t write \(out.pathExtension.uppercased()) images.")
        }
        if !fileProperties.isEmpty { CGImageDestinationSetProperties(dest, fileProperties as CFDictionary) }
        for (i, image) in images.enumerated() {
            var props = metadata(i)
            props[kCGImageDestinationLossyCompressionQuality] = quality
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
        }
        guard ImageEditors.finalize(dest, at: out) else {   // also removes ImageIO's hidden temporary file
            throw ConversionError.toolFailed("Couldn’t save \(out.lastPathComponent).")
        }
    }

    // MARK: - Self-tests

    static func selfTest(_ name: String) -> String? {
        #if DEBUG
        switch name {
        case "image-extras": return checks()
        case "image-extras-files": return ImageExtrasTests.run()
        case "raw-types": return rawTypes()
        default: return nil
        }
        #else
        return nil
        #endif
    }

    /// Pure checks: SVG sizes, resize maths, collage grids, petal symbols.
    private static func checks() -> String {
        var lines: [String] = [], failed = 0
        func expect(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            lines.append((ok ? "ok    " : "FAIL  ") + what + (ok ? "" : "  " + detail()))
            if !ok { failed += 1 }
        }
        func near(_ a: CGFloat?, _ b: CGFloat) -> Bool { a.map { abs($0 - b) < 0.01 } ?? false }

        expect("length 100", near(SVGRenderer.length("100"), 100))
        expect("length 12.5px", near(SVGRenderer.length(" 12.5px "), 12.5))
        expect("length 1in = 72", near(SVGRenderer.length("1in"), 72))
        expect("length 25.4mm = 72", near(SVGRenderer.length("25.4mm"), 72))
        expect("length 2.54cm = 72", near(SVGRenderer.length("2.54cm"), 72))
        expect("length 1pc = 12", near(SVGRenderer.length("1pc"), 12))
        expect("length 50% = nil", SVGRenderer.length("50%") == nil)
        expect("length auto = nil", SVGRenderer.length("auto") == nil)
        expect("length -5 = nil", SVGRenderer.length("-5") == nil)
        expect("viewBox commas", SVGRenderer.parseViewBox("0,0,64,32") == CGRect(x: 0, y: 0, width: 64, height: 32))
        expect("viewBox zero width = nil", SVGRenderer.parseViewBox("0 0 0 10") == nil)

        let cases: [(String?, String?, String?, CGSize)] = [
            ("400", "300", nil, CGSize(width: 400, height: 300)),
            ("200", nil, "0 0 100 50", CGSize(width: 200, height: 100)),
            (nil, "100", "0 0 100 50", CGSize(width: 200, height: 100)),
            (nil, nil, "0 0 64 32", CGSize(width: 64, height: 32)),
            ("100%", "100%", "0 0 640 480", CGSize(width: 640, height: 480)),
            (nil, nil, nil, CGSize(width: 300, height: 150)),
            ("210mm", "297mm", nil, CGSize(width: 595.28, height: 841.89)),
        ]
        for (w, h, vb, size) in cases {
            let got = SVGRenderer.info(width: w, height: h, viewBox: vb).size
            expect("svg size \(w ?? "-") \(h ?? "-") \(vb ?? "-")", abs(got.width - size.width) < 0.01 && abs(got.height - size.height) < 0.01,
                   "got \(got)")
        }
        let big = SVGRenderer.defaultPixelSize(SVGRenderer.Info(size: CGSize(width: 5000, height: 2500), viewBox: nil))
        expect("svg raster capped at 4096", big.width == 4096 && big.height == 2048, "got \(big)")
        let small = SVGRenderer.defaultPixelSize(SVGRenderer.Info(size: CGSize(width: 24, height: 24), viewBox: nil))
        expect("svg raster 2x", small.width == 48 && small.height == 48, "got \(small)")

        let resizeCases: [(Int, Int, ResizeMode, Double, Int, Int)] = [
            (1600, 1000, .percent, 50, 800, 500), (1600, 1000, .width, 1000, 1000, 625),
            (1600, 1000, .height, 250, 400, 250), (1000, 1600, .longEdge, 800, 500, 800),
            (1600, 1000, .longEdge, 800, 800, 500), (3, 1000, .percent, 10, 1, 100),
        ]
        for (w, h, mode, v, ew, eh) in resizeCases {
            let got = resizedSize(width: w, height: h, mode: mode, value: v)
            expect("resize \(w)x\(h) \(mode.rawValue) \(v)", got == (ew, eh), "got \(got)")
        }
        expect("mode spellings", ResizeMode(option: "Long edge") == .longEdge && ResizeMode(option: "%") == .percent
               && ResizeMode(option: "Width") == .width && ResizeMode(option: "nope") == nil)

        let grids: [(Int, Double, Int, Int, Int)] = [
            (2, 0.75, 0, 2, 1), (4, 1.5, 0, 2, 2), (9, 1.33, 0, 3, 3), (3, 1.5, 0, 2, 2), (5, 1, 2, 2, 3), (7, 1, 10, 7, 1),
        ]
        for (n, a, c, ec, er) in grids {
            let got = collageGrid(count: n, aspect: a, columns: c)
            expect("grid \(n) @\(a) cols \(c)", got == (ec, er), "got \(got)")
        }
        for command in commands {
            expect("symbol \(command.symbol ?? "-")", command.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) } != nil)
            expect("title \(command.title) is short", command.title.count <= 12)
        }
        expect("needsWebKit plain shapes", !SVGRenderer.needsWebKit(Data("<svg><rect width='1' height='1'/></svg>".utf8)))
        expect("needsWebKit remote image", SVGRenderer.needsWebKit(Data("<svg><image href = 'https://x/y.png'/></svg>".utf8)))
        expect("needsWebKit marker", SVGRenderer.needsWebKit(Data("<svg><marker id='m'/></svg>".utf8)))
        expect("needsWebKit linked image", SVGRenderer.needsWebKit(Data(#"<svg><image xlink:href="pic.jpg" width="9"/></svg>"#.utf8)))
        expect("needsWebKit file: image", SVGRenderer.needsWebKit(Data("<svg><image href='file:///tmp/a.png'></image></svg>".utf8)))
        expect("needsWebKit image without href", SVGRenderer.needsWebKit(Data("<svg><image width='9'/></svg>".utf8)))
        expect("needsWebKit embedded image", !SVGRenderer.needsWebKit(Data(#"<svg><image href="data:image/png;base64,AAAA"/></svg>"#.utf8)))
        let stripped = String(decoding: SVGRenderer.withoutLinkedImages(Data(
            #"<svg><IMAGE xlink:href="a.jpg"/><rect/><image href='data:image/png;base64,AA'/><image href="b.png"></image></svg>"#.utf8)),
            as: UTF8.self)
        expect("withoutLinkedImages keeps embedded ones", stripped == #"<svg><rect/><image href='data:image/png;base64,AA'/></svg>"#,
               "got \(stripped)")

        // Huge option values: refused by checkSize, never an Int overflow trap.
        let hugeResize = resizedSize(width: 400, height: 300, mode: .width, value: 1e20)
        expect("resize to 1e20 px saturates", hugeResize == (maxEdge + 1, maxEdge + 1), "got \(hugeResize)")
        let hugePercent = resizedSize(width: 400, height: 300, mode: .percent, value: .greatestFiniteMagnitude)
        expect("resize to max % saturates", hugePercent == (maxEdge + 1, maxEdge + 1), "got \(hugePercent)")
        expect("pixelCount edge cases", pixelCount(-.infinity) == 1 && pixelCount(.nan) == maxEdge + 1 && pixelCount(0.4) == 1
               && pixelCount(2.5) == 3 && pixelCount(1e300) == maxEdge + 1)
        expect("checkSize refuses 5e9 × 5e9", (try? checkSize(5e9, 5e9)) == nil)
        expect("checkSize refuses infinity", (try? checkSize(Double.infinity, 10)) == nil)
        expect("checkSize refuses 20000 × 20000", (try? checkSize(20_000.0, 20_000.0)) == nil)
        expect("checkSize allows 4000 × 3000", (try? checkSize(4000.0, 3000.0)) != nil)
        expect("frame border under a pixel is 1 px", wholePixels(0.45) == 1 && wholePixels(0) == 0 && wholePixels(2.4) == 2)
        expect("remembered 1e20 falls back", rememberedNumber(["v": "1e20"], "v", 5) == 5)
        expect("remembered inf falls back", rememberedNumber(["v": "inf"], "v", 5) == 5 && rememberedNumber(["v": "nan"], "v", 5) == 5)
        expect("remembered 12 is kept", rememberedNumber(["v": "12"], "v", 5) == 12)
        return (failed == 0 ? "PASS" : "FAIL: \(failed) failed") + "\n" + lines.joined(separator: "\n")
    }

    /// Camera RAW: whether each extension YummyOrange lists is an image to macOS and readable by ImageIO.
    private static func rawTypes() -> String {
        let readable = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
        let writable = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        var lines: [String] = [], problems: [String] = []
        for ext in Ext.rawImages.sorted() {
            let type = UTType(filenameExtension: ext)
            let kind = FileKind.of(URL(fileURLWithPath: "/nonexistent/sample.\(ext)"))
            let isImage = type?.conforms(to: .image) ?? false, isRaw = type?.conforms(to: .rawImage) ?? false
            let decodable = type.map { readable.contains($0.identifier) } ?? false
            lines.append("\(ext.padding(toLength: 4, withPad: " ", startingAt: 0)) \(type?.identifier ?? "none")  kind=\(kind.rawValue) "
                         + "image=\(isImage) raw=\(isRaw) imageIOListsType=\(decodable)")
            if kind != .image { problems.append(ext) }
        }
        lines.append("ImageIO can write DNG: \(writable.contains(UTType("com.adobe.raw-image")?.identifier ?? "com.adobe.raw-image"))")
        let head = problems.isEmpty ? "PASS: every RAW extension is an image"
                                    : "FAIL: not seen as images: \(problems.joined(separator: ", "))"
        return head + "\n" + lines.joined(separator: "\n")
    }
}

// MARK: - Source images

/// A source image opened through Converter.source (so SVG and RAW work), with what the tools need to
/// write a result in the same format.
struct SourceImage {
    let url: URL
    let source: CGImageSource
    /// ImageIO type of the source data.
    let type: String
    /// Same as `type` when ImageIO can write it (not camera RAW), else PNG; and its file extension.
    let outType: String
    let outExt: String
    /// Upright pixel size (EXIF orientation applied).
    let width: Int
    let height: Int
    /// Frames to keep: every frame of an animated GIF or PNG and every page of a TIFF (at most
    /// `maxFrames`), else 1.
    let frameCount: Int
    /// Frames or pages in the file, for refusing ones with more than `maxFrames` (see requireEveryFrame).
    let totalFrames: Int
    let colorSpaceName: String?

    /// The most frames or pages a tool keeps in memory at once.
    static let maxFrames = 1000

    init(_ url: URL) throws {
        self.url = url
        source = try Converter.source(url)
        let type = CGImageSourceGetType(source) as String? ?? UTType.png.identifier
        self.type = type
        let writable = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        // Camera RAW always gives PNG, even when ImageIO only reads a DNG's TIFF preview.
        let ext = Ext.of(url)
        let isRaw = (UTType(type)?.conforms(to: .rawImage) ?? false) || Ext.rawImages.contains(ext)
            || (UTType(filenameExtension: ext)?.conforms(to: .rawImage) ?? false)
        let outType = writable.contains(type) && !isRaw ? type : UTType.png.identifier
        self.outType = outType
        // Keep the source's own spelling (jpeg, tif) when it names the same format.
        if let own = UTType(filenameExtension: ext), let out = UTType(outType), own.conforms(to: out) {
            outExt = ext
        } else {
            outExt = UTType(outType)?.preferredFilenameExtension ?? "png"
        }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        if (props[kCGImagePropertyOrientation] as? Int ?? 1) >= 5 { swap(&w, &h) }
        if w <= 0 || h <= 0 {
            let image: CGImage
            do { image = try Converter.orientedImage(source) } catch { throw Self.decodeError(url) }
            (w, h) = (image.width, image.height)
        }
        width = w
        height = h
        let count = CGImageSourceGetCount(source)
        let multi = [UTType.gif.identifier, UTType.png.identifier, UTType.tiff.identifier]
        let keepsFrames = count > 1 && outType == type && multi.contains(type)
        frameCount = keepsFrames ? min(count, Self.maxFrames) : 1
        totalFrames = keepsFrames ? count : 1
        colorSpaceName = (props[kCGImagePropertyProfileName] as? String) ?? (props[kCGImagePropertyColorModel] as? String)
    }

    /// “Couldn’t decode photo.png.”: names the file, since tools such as Collage read many at once.
    static func decodeError(_ url: URL) -> ConversionError {
        .unsupported("Couldn’t decode \(url.lastPathComponent).")
    }

    /// Tools that write every frame call this first, so an animation or document with more frames than
    /// they keep is refused clearly instead of losing the rest.
    func requireEveryFrame() throws {
        guard totalFrames > frameCount else { return }
        throw ConversionError.unsupported("\(url.lastPathComponent) has \(totalFrames) frames or pages; YummyOrange can "
                                          + "keep at most \(Self.maxFrames), so it wasn’t changed.")
    }

    /// Frame `index`, upright, decoded at most `maxPixels` on its long edge (single images; frames of an
    /// animation or document are decoded whole).
    func frame(_ index: Int, maxPixels: Int? = nil) throws -> CGImage {
        if frameCount == 1 {
            do { return try Converter.orientedImage(source, maxPixels: maxPixels) } catch { throw Self.decodeError(url) }
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (2...8).contains(orientation) {
            // A TIFF page with its own orientation tag (scanners write them): decode it upright, as single
            // images are, since metadata() writes orientation 1.
            let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, index, opts as CFDictionary) { return image }
        } else if let image = CGImageSourceCreateImageAtIndex(source, index, nil) {
            return image
        }
        throw ConversionError.unsupported("Couldn’t decode frame \(index + 1) of \(url.lastPathComponent).")
    }

    /// EXIF, GPS, TIFF, IPTC and DPI worth keeping, with the orientation reset (pixels are written upright)
    /// and the EXIF pixel size updated; animation frames keep their delays. With `outType` PNG for a GIF
    /// source, the GIF delays are written as animated-PNG delays.
    func metadata(frame index: Int, width: Int, height: Int, as outType: String) -> [CFString: Any] {
        var keep = metadata(frame: index, width: width, height: height)
        if outType == UTType.png.identifier, type == UTType.gif.identifier,
           let gif = keep.removeValue(forKey: kCGImagePropertyGIFDictionary) as? [CFString: Any] {
            var png: [CFString: Any] = [:]
            png[kCGImagePropertyAPNGDelayTime] = gif[kCGImagePropertyGIFDelayTime]
            png[kCGImagePropertyAPNGUnclampedDelayTime] = gif[kCGImagePropertyGIFUnclampedDelayTime]
            keep[kCGImagePropertyPNGDictionary] = png
        }
        return keep
    }

    /// EXIF, GPS, TIFF, IPTC and DPI worth keeping, with the orientation reset (pixels are written upright)
    /// and the EXIF pixel size updated; animation frames keep their delays.
    func metadata(frame index: Int, width: Int, height: Int) -> [CFString: Any] {
        guard let p = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return [:] }
        var keep: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyDPIWidth,
                    kCGImagePropertyDPIHeight] {
            if let v = p[key] { keep[key] = v }
        }
        if var exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            keep[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            keep[kCGImagePropertyTIFFDictionary] = tiff
        }
        keep.merge(timing(frame: index, properties: p)) { _, new in new }
        return keep
    }

    /// Only the frame's animation delay (GIF or animated PNG), for copies that keep no other metadata.
    func timing(frame index: Int, properties: [CFString: Any]? = nil) -> [CFString: Any] {
        guard frameCount > 1,
              let p = properties ?? CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return [:] }
        var keep: [CFString: Any] = [:]
        for (dict, keys) in [(kCGImagePropertyGIFDictionary, [kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFUnclampedDelayTime]),
                             (kCGImagePropertyPNGDictionary, [kCGImagePropertyAPNGDelayTime, kCGImagePropertyAPNGUnclampedDelayTime])] {
            guard let d = p[dict] as? [CFString: Any] else { continue }
            keep[dict] = d.filter { keys.contains($0.key) }
        }
        return keep
    }

    /// File-level properties for animations written as `outType`: a GIF's loop count becomes an animated
    /// PNG's (a GIF without one plays once).
    func fileProperties(as outType: String) -> [CFString: Any] {
        var keep = fileProperties
        guard outType == UTType.png.identifier, type == UTType.gif.identifier, frameCount > 1 else { return keep }
        let gif = keep.removeValue(forKey: kCGImagePropertyGIFDictionary) as? [CFString: Any]
        keep[kCGImagePropertyPNGDictionary] = [kCGImagePropertyAPNGLoopCount: gif?[kCGImagePropertyGIFLoopCount] ?? 1]
        return keep
    }

    /// File-level properties for animations (loop count).
    var fileProperties: [CFString: Any] {
        guard frameCount > 1, let p = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] else { return [:] }
        var keep: [CFString: Any] = [:]
        if let gif = p[kCGImagePropertyGIFDictionary] as? [CFString: Any], let loop = gif[kCGImagePropertyGIFLoopCount] {
            keep[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFLoopCount: loop]
        }
        if let png = p[kCGImagePropertyPNGDictionary] as? [CFString: Any], let loop = png[kCGImagePropertyAPNGLoopCount] {
            keep[kCGImagePropertyPNGDictionary] = [kCGImagePropertyAPNGLoopCount: loop]
        }
        return keep
    }
}
