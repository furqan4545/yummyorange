import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ConversionError: LocalizedError {
    case unreadable(String)
    case missingTool(String)
    case toolFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "Couldn’t read \(name)."
        case .missingTool(let tool):
            // A copy that gets its own ffmpeg never sends people to Homebrew (JobRunner normally waits for it instead).
            if FFmpegHelper.canProvide(self) { return FFmpegHelperText.notYet }
            return "\(tool) isn’t installed. Install it (for example with Homebrew) to use this."
        case .toolFailed(let message): return message
        case .unsupported(let what): return what
        }
    }
}

/// Tools offered on the Command wheel.
enum FileTool: String, CaseIterable {
    case compress = "Compress"
    case stripMetadata = "Strip Metadata"
    case halfSize = "Half Size"
    case rotate = "Rotate 90°"
    case mute = "Mute"
    case extractAudio = "Extract Audio"
    case normalize = "Normalize"
    // PDF tools
    case mergePDF = "Merge PDF"
    case makePDF = "Make PDF"
    case split = "Split Pages"
    case extractText = "Extract Text"
    case protect = "Add Password"
    case unlock = "Remove Password"

    /// Tools for a whole selection. Some (Merge, Make PDF) only appear for several files.
    static func tools(for files: [URL]) -> [FileTool] {
        let kinds = Set(files.map(FileKind.of))
        let hasFFmpeg = Capabilities.shared.mediaAvailable
        let several = files.count > 1

        if kinds == [.pdf] {
            var tools: [FileTool] = [.compress, .stripMetadata, .rotate, .split, .extractText]
            let allLocked = files.prefix(20).allSatisfy { PDFTools.isEncrypted($0) }
            tools.append(allLocked ? .unlock : .protect)
            if several { tools.insert(.mergePDF, at: 0) }
            return tools
        }
        if several, kinds.contains(.pdf), kinds.isSubset(of: [.pdf, .image]) { return [.mergePDF] }
        if kinds == [.image] {
            var tools: [FileTool] = [.compress, .stripMetadata, .halfSize, .rotate, .extractText]
            if several { tools.append(.makePDF) }
            return tools
        }
        if kinds == [.video] { return hasFFmpeg ? [.compress, .stripMetadata, .mute, .extractAudio, .normalize] : [] }
        if kinds == [.audio] { return hasFFmpeg ? [.compress, .stripMetadata, .normalize] : [] }
        return []
    }
}

/// Every operation a wheel petal can start.
enum Operation {
    case convert(OutputFormat)
    case tool(FileTool)
    case protect(password: String)
    case unlock(password: String)
    /// A petal contributed by a feature module (see Extensions.swift).
    case command(WheelCommand, ToolOptions)

    var title: String {
        switch self {
        case .convert(let f): return "→ \(f.label)"
        case .tool(let t): return t.rawValue
        case .protect: return FileTool.protect.rawValue
        case .unlock: return FileTool.unlock.rawValue
        case .command(let c, _): return c.wheel == .convert ? "→ \(c.title)" : c.plainTitle
        }
    }

    /// Operations that turn the whole selection into one output instead of one output per file.
    var combinesInputs: Bool {
        if case .tool(let t) = self { return t == .mergePDF || t == .makePDF }
        if case .command(let c, _) = self { return c.combinesInputs }
        return false
    }
}

enum Converter {
    typealias Progress = (Double) -> Void

    static func perform(_ op: Operation, on url: URL, progress: @escaping Progress) throws -> [URL] {
        let kind = FileKind.of(url)
        switch op {
        case .convert(let format):
            switch kind {
            case .image: return try convertImageFile(url, to: format)
            case .pdf: return format == .pdf ? [try savePDFCopy(url)] : try renderPDF(url, to: format)
            case .video, .audio: return [try convertMedia(url, kind: kind, to: format, progress: progress)]
            case .other: throw ConversionError.unsupported("YummyOrange can’t convert this kind of file.")
            }
        case .tool(let tool):
            if op.combinesInputs { return [try PDFTools.combine([url], progress: progress)] }
            if kind == .pdf || tool == .extractText {
                return try PDFTools.run(tool, on: url, kind: kind, progress: progress)
            }
            return [try run(tool, on: url, kind: kind, progress: progress)]
        case .protect(let password):
            return [try PDFTools.protect(url, password: password)]
        case .unlock(let password):
            return [try PDFTools.unlock(url, password: password)]
        case .command(let c, let options):
            guard let run = c.run else { throw ConversionError.unsupported("\(c.plainTitle) has nothing to run.") }
            return try run([url], options, progress)
        }
    }

    /// Runs an operation that consumes every file at once (Merge PDF, Make PDF).
    static func performCombined(_ op: Operation, on files: [URL], progress: @escaping Progress) throws -> [URL] {
        if case .command(let c, let options) = op {
            guard let run = c.run else { throw ConversionError.unsupported("\(c.plainTitle) has nothing to run.") }
            return try run(files, options, progress)
        }
        return [try PDFTools.combine(files, progress: progress)]
    }

    // MARK: Images (ImageIO)

    /// SVG, plain or gzip-compressed (.svgz).
    static func isSVG(_ url: URL) -> Bool {
        Ext.svg.contains(Ext.of(url)) || FileKind.svgExtensions.contains(Ext.of(url))
    }

    static func source(_ url: URL) throws -> CGImageSource {
        if isSVG(url) { return try ImageExtras.svgSource(url) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        return src
    }

    /// Decodes the first frame with EXIF orientation applied, optionally limited in size.
    static func orientedImage(_ src: CGImageSource, maxPixels: Int? = nil) throws -> CGImage {
        try orientedImage(src, at: 0, maxPixels: maxPixels)
    }

    /// Decodes picture `index` (a TIFF page, an animation frame) with its orientation applied. Without
    /// `maxPixels` it is decoded at its own size; when ImageIO reports no pixel size (some plug-ins don't),
    /// there is no size cap at all, rather than a cap of 1 pixel.
    static func orientedImage(_ src: CGImageSource, at index: Int, maxPixels: Int? = nil) throws -> CGImage {
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        var opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixels { opts[kCGImageSourceThumbnailMaxPixelSize] = max(maxPixels, 1) }
        else if max(w, h) > 0 { opts[kCGImageSourceThumbnailMaxPixelSize] = max(w, h) }
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary) else {
            throw ConversionError.unsupported("Couldn’t decode the image.")
        }
        return img
    }

    private static func write(_ image: CGImage, to out: URL, type: String, quality: Double = 0.85,
                              properties: [CFString: Any] = [:]) throws {
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, 1, nil) else {
            throw ConversionError.unsupported("This Mac can’t write \(out.pathExtension.uppercased()) images.")
        }
        var props = properties
        props[kCGImageDestinationLossyCompressionQuality] = quality
        // The pixels are already rotated upright, so drop any orientation tag.
        props[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.toolFailed("Couldn’t save \(out.lastPathComponent).") }
    }

    /// Metadata worth keeping across a format change (EXIF, GPS, TIFF, IPTC dictionaries).
    private static func keptMetadata(_ src: CGImageSource, index: Int = 0) -> [CFString: Any] {
        guard let p = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] else { return [:] }
        var keep: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                    kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary] {
            if let v = p[key] { keep[key] = v }
        }
        return keep
    }

    static func convertImage(_ url: URL, to format: OutputFormat) throws -> URL {
        try convertImage(url, src: try source(url), to: format)
    }

    /// Converts an image file. A multi-page TIFF or an animated GIF, PNG or WebP keeps every page or frame
    /// when the format can hold them (PDF and TIFF pages, GIF and PNG animations, animated WebP); TIFF
    /// pages become one file per page in the other formats; an animation saved as a still format keeps
    /// its first frame, and the file is named so ("clip first frame.jpg").
    static func convertImageFile(_ url: URL, to format: OutputFormat) throws -> [URL] {
        let src = try source(url)
        guard let frames = Frames(src, url: url) else { return [try convertImage(url, src: src, to: format)] }
        switch (format, frames.kind) {
        case (.pdf, _):
            return [try writePDF(frames)]
        case (.tiff, _), (.gif, .animation), (.png, .animation):
            return [try writeSequence(frames, as: format)]
        case (.webp, .animation):
            if let animated = try writeAnimatedWebP(frames) { return [animated] }
            return [try convertImage(url, src: src, to: format, suffix: " first frame")]
        case (_, .pages):
            try frames.requireAtMostMax()
            var outputs: [URL] = []
            do {
                for i in 0..<frames.count {
                    try autoreleasepool {
                        let out = outputURL(for: url, ext: format.fileExtension, suffix: " page \(i + 1)")
                        try writeStill(try frames.image(i), src: src, index: i, format: format, name: url.lastPathComponent, to: out)
                        outputs.append(out)
                    }
                }
            } catch {
                outputs.forEach { try? FileManager.default.removeItem(at: $0) }
                throw error
            }
            return outputs
        case (_, .animation):
            // JPG, HEIC, AVIF and BMP hold one picture.
            return [try convertImage(url, src: src, to: format, suffix: " first frame")]
        }
    }

    private static func convertImage(_ url: URL, src: CGImageSource, to format: OutputFormat, suffix: String = "") throws -> URL {
        if format == .pdf, isSVG(url), let vector = try ImageExtras.svgToPDF(url) { return vector }
        let image = try orientedImage(src)
        let out = outputURL(for: url, ext: format.fileExtension, suffix: suffix)
        try writeStill(image, src: src, index: 0, format: format, name: url.lastPathComponent, to: out)
        return out
    }

    /// One upright picture (picture `index` of `src`, for its metadata and DPI) saved as `format`.
    private static func writeStill(_ image: CGImage, src: CGImageSource, index: Int, format: OutputFormat, name: String,
                                   to out: URL) throws {
        switch format {
        case .pdf:
            // Page size follows the image's own DPI (72 when it has none), like Preview's export.
            var box = pageBox(image, src: src, index: index)
            guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { throw ConversionError.toolFailed("Couldn’t create the PDF.") }
            ctx.beginPDFPage(nil); ctx.draw(image, in: box); ctx.endPDFPage(); ctx.closePDF()
        case .webp:
            try writeWebP(image, to: out, name: name)
        default:
            guard let type = format.imageIOType else { throw ConversionError.unsupported("Unsupported image format.") }
            var props = keptMetadata(src, index: index)
            if format == .jpg || format == .bmp, image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst {
                // Formats without alpha: composite onto white so transparent areas don't turn black.
                try write(flattened(image), to: out, type: type, properties: props)
                return
            }
            if format == .gif { props = [:] }
            try write(image, to: out, type: type, properties: props)
        }
    }

    /// A PDF page the size of the picture at its DPI (72 when it has none).
    private static func pageBox(_ image: CGImage, src: CGImageSource, index: Int) -> CGRect {
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let dpi = max(72, (props[kCGImagePropertyDPIWidth] as? Double) ?? 72)
        return CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
    }

    /// A PDF in another wrapper (a PDF-compatible Illustrator .ai) saved as a plain .pdf: the same bytes,
    /// so vectors, text and every page stay exactly as they are.
    static func savePDFCopy(_ url: URL) throws -> URL {
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { throw ConversionError.unreadable(url.lastPathComponent) }
        let out = outputURL(for: url, ext: "pdf")
        try FileManager.default.copyItem(at: url, to: out)
        return out
    }

    // MARK: Several pages or frames

    /// The pages of a multi-page TIFF or the frames of an animated GIF, PNG (APNG) or WebP. Icons (one
    /// picture in several sizes), camera RAW previews and HEIC thumbnails aren't sequences.
    private struct Frames {
        enum Kind { case pages, animation }
        let url: URL
        let src: CGImageSource
        let kind: Kind
        let count: Int

        /// The most pages or frames a conversion writes (the image tools' limit too).
        static let maxCount = SourceImage.maxFrames

        init?(_ src: CGImageSource, url: URL) {
            let count = CGImageSourceGetCount(src)
            guard count > 1, let type = CGImageSourceGetType(src) as String? else { return nil }
            switch type {
            case UTType.tiff.identifier: kind = .pages
            case UTType.gif.identifier, UTType.png.identifier, UTType.webP.identifier: kind = .animation
            default: return nil
            }
            self.url = url
            self.src = src
            self.count = count
        }

        var name: String { url.lastPathComponent }
        var noun: String { kind == .pages ? "pages" : "frames" }

        func requireAtMostMax() throws {
            guard count > Self.maxCount else { return }
            throw ConversionError.unsupported("\(name) has \(count) \(noun); YummyOrange converts at most \(Self.maxCount), "
                                              + "so it wasn’t converted.")
        }

        /// Picture `index`, upright and full size.
        func image(_ index: Int) throws -> CGImage {
            let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
            let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            if (2...8).contains(orientation) { return try Converter.orientedImage(src, at: index) }
            guard let image = CGImageSourceCreateImageAtIndex(src, index, nil) else {
                throw ConversionError.unsupported("Couldn’t decode \(kind == .pages ? "page" : "frame") \(index + 1) of \(name).")
            }
            return image
        }

        /// How long frame `index` shows, in seconds, the way browsers play it (0 or 0.01 s means 0.1 s).
        func delay(_ index: Int) -> Double {
            let p = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
            let keys: [(CFString, CFString, CFString)] = [
                (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
                (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
                (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            ]
            for (dict, unclamped, clamped) in keys {
                guard let d = p[dict] as? [CFString: Any] else { continue }
                if let v = (d[unclamped] as? NSNumber)?.doubleValue, v > 0.0105 { return v }
                if let v = (d[clamped] as? NSNumber)?.doubleValue, v > 0.0105 { return v }
                return 0.1
            }
            return 0.1
        }

        /// The animation's loop count (0: forever), or nil when the file sets none (it plays once).
        var loopCount: Int? {
            let p = CGImageSourceCopyProperties(src, nil) as? [CFString: Any] ?? [:]
            for (dict, key) in [(kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount),
                                (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount),
                                (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount)] {
                if let d = p[dict] as? [CFString: Any], let n = (d[key] as? NSNumber)?.intValue { return n }
            }
            return nil
        }
    }

    /// Every page or frame as one PDF page each, sized from its DPI.
    private static func writePDF(_ frames: Frames) throws -> URL {
        try frames.requireAtMostMax()
        let out = outputURL(for: frames.url, ext: "pdf")
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, nil) else { throw ConversionError.toolFailed("Couldn’t create the PDF.") }
        do {
            for i in 0..<frames.count {
                try autoreleasepool {
                    let image = try frames.image(i)
                    var box = pageBox(image, src: frames.src, index: i)
                    let info = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
                    ctx.beginPDFPage(info); ctx.draw(image, in: box); ctx.endPDFPage()
                }
            }
            ctx.closePDF()
        } catch {
            ctx.closePDF()
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    /// Every page or frame in one TIFF (as pages) or one animated GIF or PNG (with each frame's delay and
    /// the loop count). Frames are added straight from the source, so a long animation isn't held in memory.
    private static func writeSequence(_ frames: Frames, as format: OutputFormat) throws -> URL {
        try frames.requireAtMostMax()
        guard let type = format.imageIOType else { throw ConversionError.unsupported("Unsupported image format.") }
        let out = outputURL(for: frames.url, ext: format.fileExtension)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, frames.count, nil) else {
            throw ConversionError.unsupported("This Mac can’t write \(format.label) images.")
        }
        let loop = frames.loopCount
        switch format {
        case .gif:
            // A GIF without a loop count plays once; APNG's "play once" is 1.
            if let loop, loop != 1 || frames.kind == .pages {
                CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop]] as CFDictionary)
            }
        case .png:
            CGImageDestinationSetProperties(dest, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: loop ?? 1]] as CFDictionary)
        default: break
        }
        for i in 0..<frames.count {
            var props = keptMetadata(frames.src, index: i)
            switch format {
            case .gif:
                let d = frames.delay(i)
                props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: d, kCGImagePropertyGIFUnclampedDelayTime: d]]
            case .png:
                let d = frames.delay(i)
                props[kCGImagePropertyPNGDictionary] = [kCGImagePropertyAPNGDelayTime: d, kCGImagePropertyAPNGUnclampedDelayTime: d]
            default: break
            }
            let orientation = (CGImageSourceCopyPropertiesAtIndex(frames.src, i, nil) as? [CFString: Any])?[kCGImagePropertyOrientation]
            if let o = orientation as? NSNumber, (2...8).contains(o.intValue) {
                // A page with its own orientation tag: written upright, like single images.
                props[kCGImagePropertyOrientation] = 1
                try autoreleasepool { CGImageDestinationAddImage(dest, try frames.image(i), props as CFDictionary) }
            } else {
                CGImageDestinationAddImageFromSource(dest, frames.src, i, props as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError.toolFailed("Couldn’t save \(out.lastPathComponent).")
        }
        return out
    }

    /// An animated WebP with each frame's delay and the loop count, through img2webp (libwebp's animation
    /// tool, next to cwebp) or an ffmpeg with libwebp's animation encoder. nil when neither is installed.
    private static func writeAnimatedWebP(_ frames: Frames) throws -> URL? {
        try frames.requireAtMostMax()
        let loop = String(frames.loopCount ?? 1)
        if let img2webp = Capabilities.shared.img2webp {
            let first = try frames.image(0)
            try requireWebPSize(first.width, first.height, name: frames.name)
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("dropwheel-webp-\(UUID().uuidString)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            var args = ["-loop", loop, "-lossy", "-q", "85"]
            for i in 0..<frames.count {
                try autoreleasepool {
                    let image = i == 0 ? first : try frames.image(i)
                    let png = dir.appendingPathComponent(String(format: "frame%05d.png", i))
                    try write(image, to: png, type: UTType.png.identifier)
                    args += ["-d", String(max(1, Int((frames.delay(i) * 1000).rounded()))), png.path]
                }
            }
            let out = outputURL(for: frames.url, ext: "webp")
            let r = try ProcessRunner.run(img2webp, args + ["-o", out.path])
            guard r.status == 0, fileSize(out) > 0 else {
                try? fm.removeItem(at: out)
                let message = r.stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                throw ConversionError.toolFailed(message.isEmpty ? "img2webp couldn’t write \(out.lastPathComponent)." : message)
            }
            return out
        }
        if let ff = FFmpeg.shared, Capabilities.shared.has("libwebp_anim") {
            let out = outputURL(for: frames.url, ext: "webp")
            try ff.run(input: frames.url, output: out, args: ["-c:v", "libwebp_anim", "-quality", "85", "-loop", loop],
                       duration: nil) { _ in }
            return out
        }
        return nil
    }

    private static func flattened(_ image: CGImage) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ConversionError.toolFailed("Couldn’t flatten the image.") }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white); ctx.fill(rect); ctx.draw(image, in: rect)
        return ctx.makeImage()!
    }

    /// WebP's limit on each side.
    static let maxWebPSide = 16383

    private static func requireWebPSize(_ width: Int, _ height: Int, name: String) throws {
        guard width > maxWebPSide || height > maxWebPSide else { return }
        throw ConversionError.unsupported("\(name) is \(width) × \(height) pixels, and WebP allows at most \(maxWebPSide) "
                                          + "on each side. Convert it to PNG or JPG, or make it smaller with Resize… first.")
    }

    private static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// ImageIO can't write WebP, so go through a temporary PNG and cwebp (or ffmpeg's libwebp). Nothing is
    /// left behind when the encoder fails.
    private static func writeWebP(_ image: CGImage, to out: URL, name: String) throws {
        try requireWebPSize(image.width, image.height, name: name)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try write(image, to: tmp, type: UTType.png.identifier)
        if let cwebp = Capabilities.shared.cwebp {
            let r = try ProcessRunner.run(cwebp, ["-quiet", "-mt", "-q", "85", tmp.path, "-o", out.path])
            guard r.status == 0 else {
                try? FileManager.default.removeItem(at: out)
                let message = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw ConversionError.toolFailed(message.isEmpty ? "cwebp couldn’t write \(out.lastPathComponent)." : message)
            }
        } else if let ff = FFmpeg.shared, Capabilities.shared.has("libwebp") {
            try ff.run(input: tmp, output: out, args: ["-frames:v", "1", "-c:v", "libwebp", "-quality", "85"], duration: nil) { _ in }
        } else {
            throw ConversionError.missingTool("cwebp")
        }
        guard fileSize(out) > 0 else {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError.toolFailed("Couldn’t save \(out.lastPathComponent).")
        }
    }

    /// PDF → one image per page at 200 DPI.
    static func renderPDF(_ url: URL, to format: OutputFormat) throws -> [URL] {
        guard let doc = CGPDFDocument(url as CFURL) else { throw ConversionError.unreadable(url.lastPathComponent) }
        // A file that needs a password to open has pages that can't be drawn: say so instead of writing nothing.
        if doc.isEncrypted && !doc.isUnlocked && !doc.unlockWithPassword("") { throw PDFExtras.lockedError(url) }
        guard doc.numberOfPages > 0, let type = format.imageIOType else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        // PDFKit, for the annotations (form values, stamps, notes, highlights) Core Graphics doesn't draw.
        let annotated = PDFDocument(url: url)
        if let annotated, annotated.isLocked { _ = annotated.unlock(withPassword: "") }
        var outputs: [URL] = []
        for index in 1...doc.numberOfPages {
            guard let page = doc.page(at: index),
                  let image = PDFTools.render(page, dpi: 200, annotations: annotated?.page(at: index - 1)) else { continue }
            let suffix = doc.numberOfPages > 1 ? " page \(index)" : ""
            let out = outputURL(for: url, ext: format.fileExtension, suffix: suffix)
            try write(image, to: out, type: type, quality: 0.9)
            outputs.append(out)
        }
        guard !outputs.isEmpty else {
            throw ConversionError.toolFailed("Couldn’t draw any page of \(url.lastPathComponent) (the pages may be empty or damaged).")
        }
        return outputs
    }

    // MARK: Audio & video (ffmpeg)

    static func convertMedia(_ url: URL, kind: FileKind, to format: OutputFormat, progress: @escaping Progress) throws -> URL {
        guard let ff = FFmpeg.shared else { throw ConversionError.missingTool("ffmpeg") }
        let info = ff.probe(url)
        if format == .gif || format.isVideo { try requireVideo(info, url) }
        let out = outputURL(for: url, ext: format.fileExtension)
        let args: [String]
        if format == .gif {
            args = FFmpeg.gifArgs()
        } else if format.isVideo {
            // WebM's Opus audio: 5.1(side) and other layouts libopus refuses are remapped.
            let fit = format == .webm && info.hasSurroundLayout ? FFmpeg.opusLayoutFilter : nil
            args = FFmpeg.videoArgs(for: format, audioFilter: fit)
        } else {
            guard info.hasAudio else { throw ConversionError.unsupported("This file has no audio track.") }
            var fit: [String] = []
            if format == .opus { fit = FFmpeg.opusFit(info) }
            // libvorbis takes the same channel orders as libopus (5.1, not 5.1(side)).
            if format == .ogg, Capabilities.shared.has("libvorbis"), info.hasSurroundLayout { fit = ["-af", FFmpeg.opusLayoutFilter] }
            args = ["-vn", "-map", "0:a:0"] + FFmpeg.audioArgs(for: format) + fit
        }
        try ff.run(input: url, output: out, args: args, duration: info.duration, progress: progress)
        return out
    }

    // MARK: Tools

    /// "clip.mp4 has no video track." for a picture recipe on a file ffmpeg opened and found no picture in
    /// (an audio-only .mkv or .webm). Files ffmpeg can't open are left to ffmpeg's own error.
    private static func requireVideo(_ info: FFmpeg.MediaInfo, _ url: URL) throws {
        guard info.opened, !info.hasVideo else { return }
        throw ConversionError.unsupported("\(url.lastPathComponent) has no video track.")
    }

    /// Compress's result must be smaller than the file it came from; otherwise it is deleted.
    private static func requireSmaller(_ out: URL, than url: URL) throws {
        guard fileSize(out) >= fileSize(url) else { return }
        try? FileManager.default.removeItem(at: out)
        throw ConversionError.unsupported("\(url.lastPathComponent) is already as small as YummyOrange can make it.")
    }

    /// Compress's audio rate: 128 kb/s, or the source's own rate when that is lower (a 32 kb/s voice memo
    /// isn't re-encoded at 128).
    private static func compressedAudioRate(_ info: FFmpeg.MediaInfo) -> String {
        guard let source = info.audioBitrate, source > 0 else { return "128k" }
        return "\(min(128, max(8, source)))k"
    }

    /// The audio options Normalize writes into a file of this kind and extension, so the result stays
    /// playable in its own container: Opus in WebM, Vorbis in Ogg, Windows Media Audio in WMA/WMV/ASF,
    /// the file's own codec for audio formats YummyOrange writes, AAC otherwise.
    static func normalizeAudioArgs(kind: FileKind, ext: String, info: FFmpeg.MediaInfo) -> (args: [String], filter: String?) {
        let caps = Capabilities.shared
        switch OutputFormat.canonicalExtension(ext) {
        case "webm":
            if caps.has("libopus") {
                return (["-c:a", "libopus", "-b:a", "160k"], info.hasSurroundLayout ? FFmpeg.opusLayoutFilter : nil)
            }
            if caps.has("libvorbis") { return (FFmpeg.audioArgs(for: .ogg), nil) }
            // ffmpeg's own Opus encoder: stereo at most.
            return (FFmpeg.audioArgs(for: .opus) + ((info.channels ?? 3) > 2 ? ["-ac", "2"] : []), nil)
        case "ogg", "ogv", "oga":
            return (FFmpeg.audioArgs(for: .ogg), nil)
        case "opus":
            let fit = FFmpeg.opusFit(info)
            if fit.first == "-af" { return (FFmpeg.audioArgs(for: .opus), fit.last) }
            return (FFmpeg.audioArgs(for: .opus) + fit, nil)
        case "wma", "wmv", "asf":
            return (["-c:a", "wmav2", "-b:a", info.channels == 1 ? "128k" : "192k"] + ((info.channels ?? 3) > 2 ? ["-ac", "2"] : []), nil)
        default:
            if kind == .audio, let own = OutputFormat(rawValue: OutputFormat.canonicalExtension(ext)) {
                let args = FFmpeg.audioArgs(for: own)
                if !args.isEmpty { return (args, nil) }
            }
            return (FFmpeg.audioArgs(for: .m4a), nil)
        }
    }

    static func run(_ tool: FileTool, on url: URL, kind: FileKind, progress: @escaping Progress) throws -> URL {
        if kind == .image { return try imageTool(tool, url) }
        guard let ff = FFmpeg.shared else { throw ConversionError.missingTool("ffmpeg") }
        let info = ff.probe(url)
        let ext = url.pathExtension.lowercased()
        let sameFormat = OutputFormat(rawValue: OutputFormat.canonicalExtension(ext))
        // A movie file with sound and no picture (an audio-only .mkv or .webm) is handled as audio.
        let kind: FileKind = kind == .video && info.opened && !info.hasVideo && info.hasAudio ? .audio : kind

        switch tool {
        case .compress:
            if kind == .video {
                try requireVideo(info, url)
                let out = outputURL(for: url, ext: "mp4", suffix: " compressed")
                // At most 1080p: the shorter side is capped, so portrait phone video stays 1080 wide.
                try ff.run(input: url, output: out,
                           args: FFmpeg.videoArgs(for: .mp4, quality: 45, maxShortSide: 1080, audioBitrate: compressedAudioRate(info)),
                           duration: info.duration, progress: progress)
                try requireSmaller(out, than: url)
                return out
            }
            let format: OutputFormat = sameFormat == .mp3 ? .mp3 : .m4a
            let out = outputURL(for: url, ext: format.fileExtension, suffix: " compressed")
            try ff.run(input: url, output: out, args: ["-vn"] + FFmpeg.audioArgs(for: format, bitrate: compressedAudioRate(info)),
                       duration: info.duration, progress: progress)
            try requireSmaller(out, than: url)
            return out
        case .stripMetadata:
            let out = outputURL(for: url, ext: ext, suffix: " clean")
            try ff.run(input: url, output: out, args: ["-map", "0", "-map_metadata", "-1", "-map_metadata:s", "-1",
                                                        "-map_chapters", "-1", "-c", "copy"],
                       duration: info.duration, progress: progress)
            return out
        case .mute:
            try requireVideo(info, url)
            let out = outputURL(for: url, ext: ext, suffix: " muted")
            try ff.run(input: url, output: out, args: ["-map", "0:v", "-c:v", "copy", "-an"], duration: info.duration, progress: progress)
            return out
        case .extractAudio:
            guard info.hasAudio else { throw ConversionError.unsupported("This video has no audio track.") }
            let copyable = info.audioCodec == "aac"
            let out = outputURL(for: url, ext: copyable ? "m4a" : "mp3")
            let args = copyable ? ["-vn", "-map", "0:a:0", "-c:a", "copy"] : ["-vn", "-map", "0:a:0"] + FFmpeg.audioArgs(for: .mp3)
            try ff.run(input: url, output: out, args: args, duration: info.duration, progress: progress)
            return out
        case .normalize:
            guard info.hasAudio else { throw ConversionError.unsupported("This file has no audio track.") }
            let out = outputURL(for: url, ext: ext, suffix: " normalized")
            let audio = normalizeAudioArgs(kind: kind, ext: ext, info: info)
            // loudnorm resamples to 192 kHz internally; bring it back to 48 kHz so every encoder accepts it.
            var args = ["-af", ["loudnorm=I=-16:TP=-1.5:LRA=11", audio.filter].compactMap { $0 }.joined(separator: ","), "-ar", "48000"]
            if kind == .video { args = ["-map", "0:v:0", "-map", "0:a:0", "-c:v", "copy"] + args }
            args += audio.args
            try ff.run(input: url, output: out, args: args, duration: info.duration, progress: progress)
            return out
        case .halfSize, .rotate:
            throw ConversionError.unsupported("\(tool.rawValue) works on images and PDFs only.")
        case .mergePDF, .makePDF, .split, .extractText, .protect, .unlock:
            throw ConversionError.unsupported("\(tool.rawValue) works on PDFs and images only.")
        }
    }

    private static func imageTool(_ tool: FileTool, _ url: URL) throws -> URL {
        let src = try source(url)
        let ext = url.pathExtension.lowercased()
        let type = (CGImageSourceGetType(src) as String?) ?? UTType.png.identifier
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(type)
        // Camera RAW and SVG decode to other data (TIFF/PNG), so name the output after what is written.
        let isRaw = Ext.rawImages.contains(ext) || (UTType(filenameExtension: ext)?.conforms(to: .rawImage) ?? false)
        let outType = writable && !isRaw ? type : UTType.png.identifier
        let sameSpelling = UTType(filenameExtension: ext).map { $0.conforms(to: UTType(outType) ?? .png) } ?? false
        let outExt = sameSpelling ? ext : (UTType(outType)?.preferredFilenameExtension ?? "png")
        switch tool {
        case .compress:
            // A single JPEG is written, which would silently drop every page or frame but the first.
            if let frames = Frames(src, url: url) {
                throw ConversionError.unsupported("\(url.lastPathComponent) has \(frames.count) \(frames.noun), and Compress would "
                                                  + "keep only the first, so it wasn’t changed. It works on single pictures.")
            }
            let lossy = [UTType.jpeg.identifier, UTType.heic.identifier, "public.avif"].contains(outType)
            let out = outputURL(for: url, ext: lossy ? outExt : "jpg", suffix: " compressed")
            var image = try orientedImage(src)
            if !lossy { image = try flattened(image) }
            try write(image, to: out, type: lossy ? outType : UTType.jpeg.identifier, quality: 0.6, properties: keptMetadata(src))
            try requireSmaller(out, than: url)
            return out
        case .stripMetadata:
            // Animated GIFs and PNGs and multi-page TIFFs keep every frame or page (and the animation timing).
            if CGImageSourceGetCount(src) > 1 {
                let frames = try SourceImage(url)
                if frames.frameCount > 1 { return try eachFrame(tool, frames) }
            }
            let out = outputURL(for: url, ext: outExt, suffix: " clean")
            // Re-encode the pixels only; no EXIF, GPS, TIFF, IPTC or XMP is copied.
            try write(try orientedImage(src), to: out, type: outType, quality: 0.95)
            return out
        case .halfSize, .rotate:
            // Animated GIFs and PNGs and multi-page TIFFs: every frame or page, with delays and loop count.
            if CGImageSourceGetCount(src) > 1 {
                let frames = try SourceImage(url)
                if frames.frameCount > 1 { return try eachFrame(tool, frames) }
            }
            if tool == .halfSize {
                let full = try orientedImage(src)
                let out = outputURL(for: url, ext: outExt, suffix: " half")
                try write(try orientedImage(src, maxPixels: max(full.width, full.height) / 2), to: out, type: outType,
                          properties: keptMetadata(src))
                return out
            }
            let out = outputURL(for: url, ext: outExt, suffix: " rotated")
            try write(try rotated(try orientedImage(src), name: url.lastPathComponent), to: out, type: outType, quality: 0.92,
                      properties: keptMetadata(src))
            return out
        default:
            throw ConversionError.unsupported("\(tool.rawValue) doesn’t apply to images.")
        }
    }

    /// The image turned 90° clockwise, keeping its depth (16-bit stays 16-bit), colour space and greyscale,
    /// and adding no alpha channel to an opaque image.
    private static func rotated(_ image: CGImage, name: String) throws -> CGImage {
        let opaque = !ImageExtras.hasAlphaChannel(image)
        let ctx = try ImageExtras.canvas(image.height, image.width, like: image, opaque: opaque, keepGray: opaque)
        ctx.translateBy(x: 0, y: CGFloat(image.width))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = ctx.makeImage() else { throw ConversionError.toolFailed("Couldn’t rotate \(name).") }
        return result
    }

    /// The image at half its size (the long side halved, as Half Size does for single images), same depth.
    private static func halved(_ image: CGImage, name: String) throws -> CGImage {
        let long = max(image.width, image.height)
        let scale = Double(max(1, long / 2)) / Double(long)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let opaque = !ImageExtras.hasAlphaChannel(image)
        let ctx = try ImageExtras.canvas(width, height, like: image, opaque: opaque, keepGray: opaque)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = ctx.makeImage() else { throw ConversionError.toolFailed("Couldn’t resize \(name).") }
        return result
    }

    /// Rotate 90°, Half Size or Strip Metadata on every frame of an animation or page of a TIFF, saved in
    /// the source's format with each frame's delay and the loop count (and, except for Strip Metadata, the
    /// metadata). Files with more frames than the tools keep are refused rather than cut short.
    private static func eachFrame(_ tool: FileTool, _ source: SourceImage) throws -> URL {
        try source.requireEveryFrame()
        let name = source.url.lastPathComponent
        var frames: [CGImage] = []
        for i in 0..<source.frameCount {
            let image = try source.frame(i)
            switch tool {
            case .rotate: frames.append(try rotated(image, name: name))
            case .halfSize: frames.append(try halved(image, name: name))
            default: frames.append(image)
            }
        }
        let strip = tool == .stripMetadata
        let suffix = tool == .rotate ? " rotated" : tool == .halfSize ? " half" : " clean"
        let out = outputURL(for: source.url, ext: source.outExt, suffix: suffix)
        try ImageExtras.save(frames, to: out, type: source.outType, quality: tool == .rotate ? 0.92 : strip ? 0.95 : 0.85,
                             metadata: { strip ? source.timing(frame: $0)
                                               : source.metadata(frame: $0, width: frames[$0].width, height: frames[$0].height) },
                             fileProperties: source.fileProperties)
        return out
    }
}
