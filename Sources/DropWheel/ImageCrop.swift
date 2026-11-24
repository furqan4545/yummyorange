import AppKit
import ImageIO

/// Crop…, Redact… and Add Background… on the Tools wheel for images.
///
/// Crop and Redact open editor windows from the ImageEditors family (same window, toolbar, status bar and
/// save flow as Adjust and Annotate); Add Background asks with a small form. Every one also runs from the
/// command line with options alone. Files:
/// - ImageCrop.swift: this module, and the crop model and renderer.
/// - ImageCropView.swift: the Crop window.
/// - ImageRedact.swift: redaction (pixels, Vision text and face finding, metadata-free writing).
/// - ImageRedactView.swift: the Redact window.
/// - ImageBackground.swift: Add Background (fill, canvas shapes, subject lifting on macOS 14 and later).
/// - ImageFrameEditing.swift: box geometry, handles and pointers shared by Crop and Redact.
/// - ImageCropRedactTests.swift: `--selftest image-crop-redact`.
enum ImageCropRedact: FeatureModule {
    static var commands: [WheelCommand] {
        [
            WheelCommand(wheel: .tools, id: "crop", title: "Crop…", symbol: "crop",
                         applies: ImageEditors.isImages,
                         present: { files in
                             ImageEditors.EditorWindowController.open(subtitle: "Crop", verb: "crop", files: files) {
                                 ImageEditors.CropEditorView(source: $0)
                             }
                         },
                         run: { files, options, progress in try each(files, progress) { try ImageCrop.save($0, options: options) } }),
            // "text.redaction" rather than "eye.slash": Strip Metadata already uses that one on this wheel.
            WheelCommand(wheel: .tools, id: "redact", title: "Redact…", symbol: "text.redaction",
                         applies: ImageEditors.isImages,
                         present: { files in
                             ImageEditors.EditorWindowController.open(subtitle: "Redact", verb: "redact", files: files) {
                                 ImageEditors.RedactEditorView(source: $0)
                             }
                         },
                         run: { files, options, progress in try each(files, progress) { try ImageRedact.save($0, options: options) } }),
            WheelCommand(wheel: .tools, id: "background", title: "Add Background…", symbol: "photo.on.rectangle",
                         applies: ImageEditors.isImages, ask: ImageBackground.ask,
                         run: { files, options, progress in try each(files, progress) { try ImageBackground.run($0, options: options) } }),
        ]
    }

    /// The command with this id, for editor windows that save through the same code as the command line.
    static func command(_ id: String) -> WheelCommand? { commands.first { $0.id == id } }

    private static func each(_ files: [URL], _ progress: @escaping (Double) -> Void, _ body: (URL) throws -> URL) throws -> [URL] {
        var outputs: [URL] = []
        for (i, url) in files.enumerated() {
            outputs.append(try body(url))
            progress(Double(i + 1) / Double(files.count))
        }
        return outputs
    }

    // MARK: Snapshots and self-tests

    /// `--snapshot crop-image|redact-image <out.png> [image] [--opt k=v]...`
    /// crop-image: x, y, w, h (the crop, image pixels), rotate=0|90|180|270, aspect=<Free|Original|1:1|…>.
    /// redact-image: boxes=x,y,w,h,style;…, find=text|faces|both|none (default both on the built-in sample),
    /// style=black|blur|pixelate for found text, faceStyle= for found faces.
    /// Both: width=, height= (content size), dark=true, window=false (content without the window).
    static func snapshot(_ id: String, files: [URL], options: ToolOptions) -> NSView? {
        guard id == "crop-image" || id == "redact-image" else { return nil }
        do {
            func side(_ key: String, _ fallback: Double) -> CGFloat {
                let v = options.double(key, fallback)
                return CGFloat(v.isFinite ? min(max(v, 200), 4000) : fallback)
            }
            let size = CGSize(width: side("width", 1100), height: side("height", 720))
            let view: ImageEditors.EditorRootView
            let url: URL
            if id == "crop-image" {
                url = try files.first ?? ImageEditors.TestImages.sample()
                view = try ImageEditors.CropEditorView.snapshot(source: try ImageEditors.SourceImage(url), options: options)
            } else {
                url = try files.first ?? RedactSample.write()
                view = try ImageEditors.RedactEditorView.snapshot(source: try ImageEditors.SourceImage(url), options: options,
                                                                   isSample: files.isEmpty)
            }
            view.frame = CGRect(origin: .zero, size: size)
            guard options.bool("window", true) else { return view }
            return ImageEditors.windowSnapshot(view, url: url, subtitle: id == "crop-image" ? "Crop" : "Redact", size: size,
                                               dark: options.bool("dark", false))
        } catch {
            let label = NSTextField(wrappingLabelWithString: "Snapshot failed: \(error.localizedDescription)")
            label.frame = CGRect(x: 0, y: 0, width: 600, height: 80)
            return label
        }
    }

    static func selfTest(_ name: String) -> String? {
        #if DEBUG
        name == "image-crop-redact" ? CropRedactTests.run() : nil
        #else
        return nil
        #endif
    }
}

// MARK: - Crop model and renderer

/// Crops in upright pixels (the EXIF orientation applied), then turns the result by quarter turns clockwise.
enum ImageCrop {
    /// Aspect presets, as width : height of the result (after any rotation).
    enum Aspect: String, CaseIterable {
        case free = "Free", original = "Original", square = "1:1", fourFive = "4:5", threeTwo = "3:2", fourThree = "4:3",
             sixteenNine = "16:9", nineSixteen = "9:16"

        var title: String { rawValue }

        /// Width ÷ height, or nil for Free. `original` is the shown picture's own ratio.
        func ratio(original: CGSize) -> CGFloat? {
            switch self {
            case .free: return nil
            case .original: return original.height > 0 ? original.width / original.height : nil
            default:
                let parts = rawValue.split(separator: ":").compactMap { Double($0) }
                return parts.count == 2 && parts[1] > 0 ? CGFloat(parts[0] / parts[1]) : nil
            }
        }

        init?(option: String) {
            let s = option.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "x", with: ":")
                .replacingOccurrences(of: "/", with: ":")
            if s == "square" { self = .square; return }
            guard let match = Aspect.allCases.first(where: { $0.rawValue.lowercased() == s }) else { return nil }
            self = match
        }
    }

    /// A crop of an image `size` (upright pixels): the box in those pixels and the quarter turns after it.
    struct Plan: Equatable {
        var rect: CGRect
        var turns: Int

        /// The result's size in pixels.
        var outputSize: CGSize { turns % 2 == 1 ? CGSize(width: rect.height, height: rect.width) : rect.size }

        var options: ToolOptions {
            ["x": "\(Int(rect.minX))", "y": "\(Int(rect.minY))", "w": "\(Int(rect.width))", "h": "\(Int(rect.height))",
             "rotate": "\(turns * 90)"]
        }
    }

    /// Reads x, y, w, h, rotate and aspect. Missing x and y are 0; a missing w or h runs to the image's edge;
    /// with aspect= and no w or h, the largest centered box of that shape (after rotation) is used.
    static func plan(_ options: ToolOptions, size: CGSize, name: String) throws -> Plan {
        let bounds = CGRect(origin: .zero, size: size)
        let degrees = try number(options, "rotate", 0)
        let normalized = ((Int(degrees.rounded()) % 360) + 360) % 360
        guard degrees == degrees.rounded(), normalized % 90 == 0 else {
            throw ConversionError.unsupported("rotate must be 0, 90, 180 or 270 (degrees clockwise), not \(options["rotate"] ?? "").")
        }
        let turns = normalized / 90
        var rect: CGRect
        let hasBox = ["x", "y", "w", "h"].contains { !(options[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        if !hasBox, let text = options["aspect"], !text.isEmpty {
            guard let aspect = Aspect(option: text) else {
                throw ConversionError.unsupported("“\(text)” isn’t an aspect. Use Free, Original, 1:1, 4:5, 3:2, 4:3, 16:9 or 9:16.")
            }
            let shown = turns % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
            if let r = aspect.ratio(original: shown) {
                // The ratio is of the result; before a quarter turn the box is the other way round.
                let sourceRatio = turns % 2 == 1 ? 1 / r : r
                rect = FrameEditing.largest(ratio: sourceRatio, in: bounds, around: CGPoint(x: bounds.midX, y: bounds.midY))
            } else {
                rect = bounds
            }
        } else {
            let x = try number(options, "x", 0), y = try number(options, "y", 0)
            let w = try number(options, "w", Double(size.width) - x), h = try number(options, "h", Double(size.height) - y)
            guard w > 0, h > 0 else { throw ConversionError.unsupported("The crop’s width and height must be more than 0.") }
            rect = CGRect(x: x, y: y, width: w, height: h)
        }
        rect = FrameEditing.integral(rect, in: bounds)
        guard rect.width >= 1, rect.height >= 1 else {
            throw ConversionError.unsupported("The crop is outside \(name), which is \(Int(size.width)) × \(Int(size.height)) pixels.")
        }
        guard rect != bounds || turns != 0 else {
            throw ConversionError.unsupported("Nothing to crop. Give x, y, w and h in pixels of the upright image, "
                                              + "an aspect such as aspect=1:1, or rotate=90.")
        }
        return Plan(rect: rect, turns: turns)
    }

    private static func number(_ options: ToolOptions, _ key: String, _ fallback: Double) throws -> Double {
        let text = options.string(key, "")
        guard !text.isEmpty else { return fallback }
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-")),
              v.isFinite, abs(v) < 1e7 else {
            throw ConversionError.unsupported("“\(text)” isn’t a number (\(key)).")
        }
        return v
    }

    /// The pixels of `rect` (top-left origin) of an upright image, turned `turns` quarter turns clockwise.
    /// Exact: no resampling happens at any step.
    static func render(_ image: CGImage, plan: Plan) throws -> CGImage {
        let r = plan.rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !r.isNull, r.width >= 1, let cropped = image.cropping(to: r) else {
            throw ConversionError.toolFailed("Couldn’t crop the image.")
        }
        return try rotate(cropped, turns: plan.turns)
    }

    /// Quarter turns clockwise, keeping 16-bit depth and transparency.
    static func rotate(_ image: CGImage, turns: Int) throws -> CGImage {
        let t = ((turns % 4) + 4) % 4
        guard t != 0 else { return image }
        let w = image.width, h = image.height
        let (ow, oh) = t % 2 == 1 ? (h, w) : (w, h)
        let deep = image.bitsPerComponent > 8
        let alpha: CGImageAlphaInfo = ImageEditors.hasAlpha(image) ? .premultipliedLast : .noneSkipLast
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0,
                                  space: ImageEditors.outputColorSpace(for: image), bitmapInfo: alpha.rawValue)
        else { throw ConversionError.toolFailed("There isn’t enough memory to rotate this image.") }
        ctx.interpolationQuality = .none
        // Core Graphics has y up, so a clockwise turn on screen is a negative angle here.
        switch t {
        case 1: ctx.translateBy(x: 0, y: CGFloat(oh)); ctx.rotate(by: -.pi / 2)
        case 2: ctx.translateBy(x: CGFloat(ow), y: CGFloat(oh)); ctx.rotate(by: .pi)
        default: ctx.translateBy(x: CGFloat(ow), y: 0); ctx.rotate(by: .pi / 2)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw ConversionError.toolFailed("Couldn’t rotate the image.") }
        return out
    }

    /// Options: x, y, w, h (pixels of the upright image; default the whole image), rotate=0|90|180|270
    /// (clockwise, default 0), aspect=1:1|4:5|3:2|4:3|16:9|9:16|original (used when no box is given).
    /// Writes "<name> cropped.<ext>" in the source's format with its metadata (orientation set to upright);
    /// formats this Mac can't write (camera RAW) and animations are saved as PNG.
    static func save(_ url: URL, options: ToolOptions) throws -> URL {
        let source = try ImageEditors.SourceImage(url)
        let plan = try plan(options, size: source.size, name: url.lastPathComponent)
        return try save(source, plan: plan)
    }

    static func save(_ source: ImageEditors.SourceImage, plan: Plan) throws -> URL {
        let image = try render(try source.fullImage(), plan: plan)
        return try source.save(image, suffix: " cropped", quality: 0.95)
    }
}
