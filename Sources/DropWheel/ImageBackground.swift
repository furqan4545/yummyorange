import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Add Background…: fills behind see-through pixels with a colour, optionally on a canvas of a chosen shape
/// with padding, and (macOS 14 and later) can lift the subject off its own background first, so a photo gets
/// a clean new one. Unlike Add Frame it paints *under* the picture and changes the canvas shape, not a margin
/// of equal width.
enum ImageBackground {
    /// Canvas shapes, as width : height.
    enum Canvas: String, CaseIterable {
        case original, square, fourFive = "4:5", nineSixteen = "9:16", sixteenNine = "16:9"

        var title: String {
            switch self {
            case .original: return "Original"
            case .square: return "Square"
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
            guard let match = Canvas.allCases.first(where: { $0.rawValue == s || $0.title.lowercased() == s }) else { return nil }
            self = match
        }
    }

    /// Largest padding, in % of the picture's long side.
    static let maxPadding = 45.0

    /// Whether this Mac can lift subjects (VNGenerateForegroundInstanceMaskRequest, macOS 14 and later).
    /// Tests set `liftOverride` to false to check how a macOS 13 Mac behaves.
    static var liftOverride: Bool?
    static var canLift: Bool {
        if let liftOverride { return liftOverride }
        if #available(macOS 14.0, *) { return true }
        return false
    }

    // MARK: Asking

    /// The form's fields; "Lift subject first" only where it works.
    static func fields(_ last: ToolOptions) -> [Ask.Field] {
        let canvas = Canvas(option: last.string("canvas", "original")) ?? .original
        var fields: [Ask.Field] = [
            .color(key: "color", label: "Background color:", hex: last.string("color", "#FFFFFF")),
            .choice(key: "canvas", label: "Canvas:", options: Canvas.allCases.map(\.title), selected: canvas.title),
            .number(key: "padding", label: "Padding:", value: ImageExtras.rememberedNumber(last, "padding", 0), unit: "% of the long side"),
        ]
        if canLift { fields.append(.toggle(key: "lift", label: "Lift subject first", on: last.bool("lift", false))) }
        return fields
    }

    static func ask(_ files: [URL]) -> ToolOptions? {
        let last = ImageExtras.remembered("background")
        let what = files.count == 1 ? files[0].lastPathComponent : "\(files.count) images"
        let lift = canLift ? " Lift subject first replaces a photo’s own background." : ""
        guard var answer = Ask.form(title: "Add Background", message: "Fills behind the see-through parts of \(what), on a "
                                    + "canvas of the shape you choose.\(lift)", fields: fields(last), button: "Add Background")
        else { return nil }
        answer["canvas"] = (Canvas(option: answer["canvas"] ?? "") ?? .original).rawValue
        ImageExtras.remember(answer, as: "background")
        return answer
    }

    // MARK: Running

    /// Options: color=#RRGGBB (default white; #RRGGBBAA for a see-through one), canvas=original|square|4:5|9:16|16:9
    /// (default original), padding=0…45 (% of the long side, default 0), lift=true|false (default false; macOS 14
    /// and later). Writes "<name> background.<ext>": the source's format, or PNG when see-through pixels remain
    /// or that format can't hold the result (an icon on a 16:9 canvas).
    /// Animated GIFs and TIFF pages keep every frame (subject lifting works on single pictures only).
    static func run(_ url: URL, options: ToolOptions) throws -> URL {
        let name = url.lastPathComponent
        let color = try ImageExtras.hexColor(options.string("color", "#FFFFFF"))
        guard let canvas = Canvas(option: options.string("canvas", "original")) else {
            throw ConversionError.unsupported("“\(options["canvas"] ?? "")” isn’t a canvas. Use original, square, 4:5, 9:16 or 16:9.")
        }
        let paddingText = options.string("padding", "0").replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")
        guard let padding = Double(paddingText), padding.isFinite, (0...maxPadding).contains(padding) else {
            throw ConversionError.unsupported("Padding must be a number from 0 to \(Int(maxPadding)) (% of the long side).")
        }
        let lift = options.bool("lift", false)
        if lift && !canLift {
            throw ConversionError.unsupported("Lifting the subject needs macOS 14 or later. Turn off “Lift subject first” "
                                              + "to fill behind the see-through parts only.")
        }
        let source = try SourceImage(url)
        try source.requireEveryFrame()
        if lift && source.frameCount > 1 {
            throw ConversionError.unsupported("“Lift subject first” works on single pictures; \(name) has \(source.frameCount) frames.")
        }
        try checkResultSize(source, canvas: canvas, padding: padding, name: name)
        var first = try source.frame(0)
        if lift {
            if #available(macOS 14.0, *) { first = try liftSubject(first, name: name) }
        }
        let seeThrough = lift || ImageExtras.isTransparent(first)
            || (1..<min(3, source.frameCount)).contains { (try? source.frame($0)).map(ImageExtras.isTransparent) ?? false }
        guard seeThrough || canvas != .original || padding > 0 else {
            throw ConversionError.unsupported("\(name) has no see-through pixels to fill. Choose a canvas shape or some padding"
                                              + (canLift ? ", or turn on “Lift subject first”." : "."))
        }
        let opaque = color.alphaComponent >= 1
        // One source frame decoded at a time; the finished frames stay in memory until they are written.
        var filled: [CGImage] = []
        filled.reserveCapacity(source.frameCount)
        for i in 0..<source.frameCount {
            try autoreleasepool {
                filled.append(try place(i == 0 ? first : try source.frame(i), color: color, canvas: canvas, padding: padding,
                                        opaque: opaque))
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

    private static func place(_ image: CGImage, color: NSColor, canvas: Canvas, padding: Double, opaque: Bool) throws -> CGImage {
        let size = canvasSize(width: image.width, height: image.height, canvas: canvas, padding: padding)
        try ImageExtras.checkSize(Double(size.width), Double(size.height))
        let ctx = try ImageExtras.canvas(size.width, size.height, like: image, opaque: opaque)
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        // Whole-pixel placement keeps the picture's pixels exactly as they were.
        let x = (size.width - image.width) / 2, y = (size.height - image.height) / 2
        ctx.draw(image, in: CGRect(x: x, y: y, width: image.width, height: image.height))
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
            throw ConversionError.unsupported("No subject found in \(name). Turn off “Lift subject first” to fill behind "
                                              + "the see-through parts only.")
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
