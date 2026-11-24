import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

extension ImageEditors {
    /// An image opened for editing: its upright size, its format, and how to save a copy like it.
    /// Opening only reads the header; pixels are decoded by `proxy` (for the screen) and `fullImage` (for saving).
    final class SourceImage {
        /// Larger images are refused: a full-resolution edit needs several copies of the pixels in memory.
        static let maxMegapixels = 200.0

        let url: URL
        let source: CGImageSource
        /// Pixel size with the EXIF orientation applied, the coordinate space of every edit.
        let size: CGSize
        /// EXIF orientation, 1 to 8 (1 is upright).
        let orientation: Int
        let typeIdentifier: String
        let frameCount: Int

        init(_ url: URL) throws {
            let name = url.lastPathComponent
            if Ext.isFolder(url) { throw ConversionError.unsupported("\(name) is a folder, not an image.") }
            let src = try Converter.source(url)
            guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0
            else { throw ConversionError.unreadable(name) }
            let megapixels = Double(w) * Double(h) / 1_000_000
            guard megapixels <= Self.maxMegapixels else {
                throw ConversionError.unsupported("\(name) is too large to edit (\(Int(megapixels)) megapixels; "
                                                  + "the limit is \(Int(Self.maxMegapixels))).")
            }
            let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            self.url = url
            source = src
            self.orientation = (1...8).contains(orientation) ? orientation : 1
            size = (5...8).contains(self.orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
            typeIdentifier = (CGImageSourceGetType(src) as String?) ?? UTType.png.identifier
            frameCount = CGImageSourceGetCount(src)
        }

        var longSide: CGFloat { max(size.width, size.height) }

        /// "1600 × 1000 · JPEG", for the editors' footers.
        var summary: String {
            let format = UTType(typeIdentifier)?.preferredFilenameExtension?.uppercased() ?? url.pathExtension.uppercased()
            return "\(Int(size.width)) × \(Int(size.height)) · \(format)"
        }

        /// A downscaled, upright copy for the screen.
        func proxy(maxPixels: Int) throws -> CGImage {
            try Converter.orientedImage(source, maxPixels: min(maxPixels, Int(longSide)))
        }

        /// The full-resolution upright image. Upright sources decode directly, which keeps 16-bit depth;
        /// rotated ones go through Converter.orientedImage.
        func fullImage() throws -> CGImage {
            if orientation == 1,
               let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
               image.width == Int(size.width), image.height == Int(size.height) {
                return image
            }
            let image = try Converter.orientedImage(source)
            guard image.width > 0, image.height > 0 else { throw ConversionError.unreadable(url.lastPathComponent) }
            return image
        }

        /// The format a copy is saved in: the source's own when this Mac can write it (and it's a single
        /// frame), otherwise PNG. The extension keeps the source's spelling ("jpeg" stays "jpeg").
        var outputFormat: (type: String, ext: String) {
            let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
            let ext = url.pathExtension.lowercased()
            guard frameCount == 1, writable.contains(typeIdentifier), let type = UTType(typeIdentifier) else {
                return (UTType.png.identifier, "png")
            }
            if let extType = UTType(filenameExtension: ext), extType == type { return (typeIdentifier, ext) }
            return (typeIdentifier, type.preferredFilenameExtension ?? "png")
        }

        /// Writes `image` next to the source as "<name><suffix>.<ext>", keeping its metadata. Falls back to PNG
        /// when the source format can't hold the result (an icon with odd dimensions, say).
        func save(_ image: CGImage, suffix: String, quality: Double = 0.92) throws -> URL {
            let format = outputFormat
            let out = outputURL(for: url, ext: format.ext, suffix: suffix)
            do {
                try write(image, to: out, type: format.type, quality: quality)
                return out
            } catch where format.type != UTType.png.identifier {
                let png = outputURL(for: url, ext: "png", suffix: suffix)
                try write(image, to: png, type: UTType.png.identifier, quality: quality)
                return png
            }
        }

        private func write(_ image: CGImage, to out: URL, type: String, quality: Double) throws {
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, 1, nil) else {
                throw ConversionError.unsupported("This Mac can’t write \(out.pathExtension.uppercased()) images.")
            }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
            // The pixels are upright now, so an orientation tag (if the source had one) says 1.
            let tagged = props[kCGImagePropertyOrientation] != nil
            var options: [CFString: Any] = [:]
            if tagged { options[kCGImagePropertyOrientation] = 1 }
            if ImageEditors.lossyTypes.contains(type) {
                options[kCGImageDestinationLossyCompressionQuality] = min(1, max(0.1, quality))
            }
            for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] { options[key] = props[key] }
            if let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil), let copy = CGImageMetadataCreateMutableCopy(meta) {
                // Metadata carries EXIF, GPS, IPTC and XMP together; only the tags that no longer fit change.
                if tagged {
                    CGImageMetadataSetValueMatchingImageProperty(copy, kCGImagePropertyTIFFDictionary,
                                                                 kCGImagePropertyTIFFOrientation, 1 as CFNumber)
                }
                if exif?[kCGImagePropertyExifPixelXDimension] != nil {
                    CGImageMetadataSetValueMatchingImageProperty(copy, kCGImagePropertyExifDictionary,
                                                                 kCGImagePropertyExifPixelXDimension, image.width as CFNumber)
                    CGImageMetadataSetValueMatchingImageProperty(copy, kCGImagePropertyExifDictionary,
                                                                 kCGImagePropertyExifPixelYDimension, image.height as CFNumber)
                }
                CGImageDestinationAddImageAndMetadata(dest, image, copy, options as CFDictionary)
            } else {
                for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                            kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary] {
                    guard var dict = props[key] as? [CFString: Any] else { continue }
                    if key == kCGImagePropertyTIFFDictionary, tagged { dict[kCGImagePropertyTIFFOrientation] = 1 }
                    if key == kCGImagePropertyExifDictionary, dict[kCGImagePropertyExifPixelXDimension] != nil {
                        dict[kCGImagePropertyExifPixelXDimension] = image.width
                        dict[kCGImagePropertyExifPixelYDimension] = image.height
                    }
                    options[key] = dict
                }
                CGImageDestinationAddImage(dest, image, options as CFDictionary)
            }
            guard ImageEditors.finalize(dest, at: out) else {
                throw ConversionError.toolFailed("Couldn’t save \(out.lastPathComponent).")
            }
        }
    }

    /// CGImageDestinationFinalize for a destination made with CGImageDestinationCreateWithURL, cleaning up when
    /// it fails. ImageIO writes into a hidden file beside `out` (".<name>-XXXXXX") and renames it on success;
    /// on failure that file stays behind in the person's folder (every crop of an icon to a size icons can't
    /// have left one, before the PNG fallback), so it is removed here, with anything at `out`.
    static func finalize(_ dest: CGImageDestination, at out: URL) -> Bool {
        if CGImageDestinationFinalize(dest) { return true }
        try? FileManager.default.removeItem(at: out)
        let folder = out.deletingLastPathComponent(), prefix = "." + out.lastPathComponent + "-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix(prefix) && name.count == prefix.count + 6 {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        return false
    }

    static let lossyTypes: Set<String> = [UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier,
                                          "public.avif", "public.jpeg-2000"]

    // MARK: Bitmaps

    /// Shared Core Image context for full-resolution renders (no intermediate caching, to save memory).
    static let renderContext = CIContext(options: [.cacheIntermediates: false])

    /// RGB color space for a result: the source's own when it's RGB (keeps Display P3 and Adobe RGB),
    /// otherwise sRGB (gray, CMYK and indexed sources become RGB once colored marks or tints are added).
    static func outputColorSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    }

    /// Renders a Core Image result like its source: 16 bits per channel when the source has more than 8,
    /// and without an alpha channel when the source has none.
    static func render(_ image: CIImage, like original: CGImage, context: CIContext = renderContext) throws -> CGImage {
        let width = original.width, height = original.height
        let deep = original.bitsPerComponent > 8
        let opaque = !hasAlpha(original)
        let space = outputColorSpace(for: original)
        let bytesPerPixel = deep ? 8 : 4
        let rowBytes = width * bytesPerPixel
        let byteCount = rowBytes * height
        guard let memory = malloc(byteCount) else {
            throw ConversionError.toolFailed("There isn’t enough memory to render this image.")
        }
        context.render(image, toBitmap: memory, rowBytes: rowBytes,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: deep ? .RGBA16 : .RGBA8, colorSpace: space)
        guard let provider = CGDataProvider(dataInfo: nil, data: memory, size: byteCount, releaseData: { _, data, _ in
            free(UnsafeMutableRawPointer(mutating: data))
        }) else {
            free(memory)
            throw ConversionError.toolFailed("Couldn’t render the image.")
        }
        var info = CGBitmapInfo(rawValue: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)
        if deep { info.insert(.byteOrder16Little) }
        guard let result = CGImage(width: width, height: height, bitsPerComponent: deep ? 16 : 8,
                                   bitsPerPixel: bytesPerPixel * 8, bytesPerRow: rowBytes, space: space,
                                   bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true,
                                   intent: .defaultIntent)
        else { throw ConversionError.toolFailed("Couldn’t render the image.") }
        return result
    }

    /// A bitmap context matching `original` (same size, depth, RGB space and alpha) with the image drawn in.
    static func context(like original: CGImage) throws -> CGContext {
        let deep = original.bitsPerComponent > 8
        let alpha: CGImageAlphaInfo = hasAlpha(original) ? .premultipliedLast : .noneSkipLast
        guard let ctx = CGContext(data: nil, width: original.width, height: original.height,
                                  bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0,
                                  space: outputColorSpace(for: original), bitmapInfo: alpha.rawValue)
        else { throw ConversionError.toolFailed("There isn’t enough memory to edit this image.") }
        ctx.interpolationQuality = .high
        ctx.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        return ctx
    }
}

extension ImageEditors {
    /// Generated images for snapshots and self-tests (when no file is given).
    enum TestImages {
        /// A photo-like scene (sky, ground, gray ramp, colored patches) written once to the temporary folder.
        static func sample() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-editor-sample.png")
            if FileManager.default.fileExists(atPath: url.path) { return url }
            let image = scene(width: 1200, height: 800)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw ConversionError.toolFailed("Couldn’t write the sample image.")
            }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { throw ConversionError.toolFailed("Couldn’t write the sample image.") }
            return url
        }

        static func scene(width w: Int, height h: Int) -> CGImage {
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
            let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
            let W = CGFloat(w), H = CGFloat(h)
            let sky = CGGradient(colorsSpace: srgb, colors: [color(0.42, 0.62, 0.86), color(0.86, 0.88, 0.90)] as CFArray,
                                 locations: [0, 1])!
            c.drawLinearGradient(sky, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: H * 0.45), options: [.drawsAfterEndLocation])
            c.setFillColor(color(1, 0.95, 0.78))
            c.fillEllipse(in: CGRect(x: W * 0.74, y: H * 0.70, width: H * 0.14, height: H * 0.14))
            // Hills
            c.setFillColor(color(0.36, 0.48, 0.30))
            c.move(to: CGPoint(x: 0, y: H * 0.42))
            c.addCurve(to: CGPoint(x: W, y: H * 0.50), control1: CGPoint(x: W * 0.3, y: H * 0.62),
                       control2: CGPoint(x: W * 0.6, y: H * 0.30))
            c.addLine(to: CGPoint(x: W, y: 0)); c.addLine(to: .zero); c.closePath(); c.fillPath()
            let ground = CGGradient(colorsSpace: srgb, colors: [color(0.30, 0.40, 0.22), color(0.10, 0.13, 0.07)] as CFArray,
                                    locations: [0, 1])!
            c.saveGState()
            c.clip(to: CGRect(x: 0, y: 0, width: W, height: H * 0.36))
            c.drawLinearGradient(ground, start: CGPoint(x: 0, y: H * 0.36), end: .zero, options: [])
            c.restoreGState()
            for x in 0..<w {
                let v = CGFloat(x) / CGFloat(max(1, w - 1))
                c.setFillColor(color(v, v, v)); c.fill(CGRect(x: CGFloat(x), y: H * 0.36, width: 1, height: H * 0.05))
            }
            let patches: [(CGFloat, CGFloat, CGFloat)] = [(0.80, 0.62, 0.52), (0.62, 0.30, 0.28), (0.25, 0.55, 0.55),
                                                          (0.85, 0.75, 0.35), (0.45, 0.40, 0.60)]
            for (i, p) in patches.enumerated() {
                c.setFillColor(color(p.0, p.1, p.2))
                c.fill(CGRect(x: W * (0.05 + CGFloat(i) * 0.12), y: H * 0.08, width: W * 0.10, height: W * 0.10))
            }
            return c.makeImage()!
        }
    }
}
