import AppKit
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers

/// "Compress to…": makes images, videos, audio and PDFs no bigger than a size you choose.
/// Every result is measured, and nothing is saved unless it really is at or under the target.
///
/// - Images: the highest JPEG/HEIC/AVIF quality that fits (binary search), then a smaller picture if even
///   low quality doesn't. PNG and other lossless images become JPEG unless they have transparency, in which
///   case they stay PNG and only shrink in size. WebP goes through cwebp's own `-size` targeting.
/// - Video: H.264 (VideoToolbox) at a bitrate worked out from the target, the length and the audio,
///   with a smaller frame when the bitrate is too low for the picture; retried until it fits.
/// - Audio: AAC (or MP3 for MP3 files) at the bitrate the target allows.
/// - PDFs: images re-compressed at stronger and stronger settings; text and drawings are left alone.
enum TargetSize {
    static var commands: [WheelCommand] {
        [WheelCommand(wheel: .tools, id: "compress-to", title: "Compress to…", symbol: "scalemass",
                      applies: applies, ask: ask,
                      run: { files, options, progress in
                          try files.map { try compress($0, options: options, progress: progress) }
                      })]
    }

    static func applies(_ files: [URL]) -> Bool {
        !files.isEmpty && files.allSatisfy { url in
            switch MoreFormats.kind(url) {
            case .image: return !Ext.svg.contains(Ext.of(url))
            case .pdf: return true
            case .video, .audio: return Capabilities.shared.mediaAvailable
            case .other: return false
            }
        }
    }

    // MARK: Asking

    static func ask(_ files: [URL]) -> ToolOptions? {
        let (message, suggested) = prompt(for: files)
        return Ask.form(title: "Compress to a Size", message: message,
                        fields: [.number(key: "target_mb", label: "At most", value: suggested, unit: "MB")],
                        button: "Compress")
    }

    /// "photo.jpg is 4.2 MB. …" and about half of that to start with (half the smallest file, for several).
    static func prompt(for files: [URL]) -> (message: String, suggested: Double) {
        let sizes = files.map(ByteSize.of)
        let smallest = sizes.min() ?? 0, largest = sizes.max() ?? 0
        let message = files.count == 1
            ? "\(files[0].lastPathComponent) is \(ByteSize.text(largest)). Choose the most it may take up."
            : "These \(files.count) files are \(ByteSize.text(smallest)) to \(ByteSize.text(largest)) each. Each one is made no bigger than this."
        return (message, suggestedTarget(smallest))
    }

    /// The smallest target accepted: 0.001 MB, the smallest size the dialog can show.
    static let minimumTarget = 1000

    /// About half of `bytes`, in MB, rounded to something easy to read (never below `minimumTarget`).
    static func suggestedTarget(_ bytes: Int) -> Double {
        let mb = Double(bytes) / 2 / 1_000_000
        let digits: Double = mb >= 10 ? 1 : mb >= 1 ? 10 : mb >= 0.1 ? 100 : 1000
        return max(Double(minimumTarget) / 1_000_000, (mb * digits).rounded(.down) / digits)
    }

    /// Megabytes → bytes, rounded down (never over what was typed), but 0.001 MB is 1000 bytes even where
    /// the multiplication lands a hair under. Absurdly large sizes (1e20 MB) are capped instead of trapping.
    static func targetBytes(_ mb: Double) -> Int {
        Int(min(max(0, mb * 1_000_000 + 1e-6), 1e18).rounded(.down))
    }

    // MARK: Running

    static func compress(_ url: URL, options: ToolOptions, progress: @escaping (Double) -> Void) throws -> URL {
        let name = url.lastPathComponent
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw ConversionError.unreadable(name) }
        let current = ByteSize.of(url)
        let fallback = Double(current) / 2 / 1_000_000
        let typed = options["target_mb"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let mb = options.double("target_mb", typed.isEmpty ? fallback : .nan)
        guard !mb.isNaN else { throw ConversionError.unsupported("Enter the target size as a number of megabytes, like 2.5.") }
        guard mb.isFinite, mb > 0 else { throw ConversionError.unsupported("Enter a target size above 0 MB.") }
        let target = targetBytes(mb)
        guard target >= minimumTarget else {
            throw ConversionError.unsupported("\(ByteSize.text(target)) is too small for any file. Choose at least 0.001 MB.")
        }
        guard current > target else {
            throw ConversionError.unsupported("\(name) is already \(ByteSize.text(current)), within \(ByteSize.text(target)).")
        }
        switch MoreFormats.kind(url) {
        case .image: return try image(url, target: target, progress: progress)
        case .video: return try video(url, target: target, constantRate: options.bool("constant_bitrate", true), progress: progress)
        case .audio: return try audio(url, target: target, progress: progress)
        case .pdf: return try pdf(url, target: target, progress: progress)
        case .other: throw ConversionError.unsupported("Compress to… works on images, videos, audio and PDFs.")
        }
    }

    static func tooBig(_ target: Int, smallest: Int?) -> ConversionError {
        let detail = smallest.map { " The smallest YummyOrange could make was \(ByteSize.text($0))." } ?? ""
        return .unsupported("Couldn’t get this below \(ByteSize.text(target)).\(detail)")
    }

    // MARK: Images

    private enum ImageOutput {
        case lossy(type: String, ext: String)
        case png
        case webp
    }

    static func image(_ url: URL, target: Int, progress: @escaping (Double) -> Void) throws -> URL {
        let src = try Converter.source(url)
        let srcType = (CGImageSourceGetType(src) as String?) ?? ""
        try requireSinglePicture(src, type: srcType, name: url.lastPathComponent)
        let full = try Converter.orientedImage(src)
        let writable = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        let ext = Ext.of(url)

        let output: ImageOutput
        if ext == "webp", Capabilities.shared.cwebp != nil {
            output = .webp
        } else if srcType == UTType.jpeg.identifier {
            output = .lossy(type: srcType, ext: ext == "jpeg" ? "jpeg" : "jpg")
        } else if srcType == UTType.heic.identifier || srcType == UTType.heif.identifier, writable.contains(UTType.heic.identifier) {
            output = .lossy(type: UTType.heic.identifier, ext: "heic")
        } else if srcType == "public.avif", writable.contains("public.avif") {
            output = .lossy(type: "public.avif", ext: "avif")
        } else if hasTransparency(full) {
            output = .png
        } else {
            output = .lossy(type: UTType.jpeg.identifier, ext: "jpg")
        }

        switch output {
        case .webp:
            return try webp(full, source: url, target: target, progress: progress)
        case .png:
            let fit = try fitBySize(src: src, full: full, target: target, progress: progress) { image in
                encode(image, type: UTType.png.identifier, quality: 1, metadata: [:])
            }
            return try save(fit.data, next: url, ext: "png")
        case .lossy(let type, let outExt):
            let metadata = keptMetadata(src)
            let opaque = type == UTType.jpeg.identifier ? try flattenedIfNeeded(full) : full
            // 1. Full size: the best quality that fits.
            if let data = bestQuality(opaque, type: type, metadata: metadata, target: target, from: 0.4, progress: { progress(0.4 * $0) }) {
                return try save(data, next: url, ext: outExt)
            }
            // 2. A smaller picture at a decent quality, then any quality left over at that size.
            let flatten: (CGImage) -> CGImage = { type == UTType.jpeg.identifier ? ((try? flattenedIfNeeded($0)) ?? $0) : $0 }
            let fit = try fitBySize(src: src, full: full, target: target, progress: { progress(0.4 + 0.5 * $0) }) { image in
                encode(flatten(image), type: type, quality: 0.7, metadata: metadata)
            }
            var best = fit.data
            if let better = bestQuality(flatten(fit.image), type: type, metadata: metadata, target: target, from: 0.7, progress: { _ in }),
               better.count > best.count {
                best = better
            }
            return try save(best, next: url, ext: outExt)
        }
    }

    /// Only the first frame or page would be kept, so animated images (GIF, PNG, WebP, HEIC sequences) and
    /// multi-page TIFFs are refused. Icons (one picture in several sizes) and camera RAW files aren't.
    private static func requireSinglePicture(_ src: CGImageSource, type: String, name: String) throws {
        let count = CGImageSourceGetCount(src)
        guard count > 1 else { return }
        if ["com.microsoft.ico", "com.apple.icns"].contains(type) || UTType(type)?.conforms(to: .rawImage) == true { return }
        if type == UTType.gif.identifier {
            throw ConversionError.unsupported("Animated GIFs can’t be compressed to a size. Convert it to a video first.")
        }
        let what = type == UTType.tiff.identifier ? "pages" : "frames"
        throw ConversionError.unsupported("\(name) has \(count) \(what), and Compress to… would keep only the first. "
                                          + "It works on single pictures only.")
    }

    /// The highest quality in `from`…0.92 whose encoding fits, or nil when even `from` doesn't.
    private static func bestQuality(_ image: CGImage, type: String, metadata: [CFString: Any], target: Int, from low: Double,
                                    progress: (Double) -> Void) -> Data? {
        guard let floor = encode(image, type: type, quality: low, metadata: metadata), floor.count <= target else { return nil }
        if let top = encode(image, type: type, quality: 0.92, metadata: metadata), top.count <= target { return top }
        var best = floor, lo = low, hi = 0.92
        for step in 0..<6 {
            let mid = (lo + hi) / 2
            if let d = encode(image, type: type, quality: mid, metadata: metadata), d.count <= target { best = d; lo = mid } else { hi = mid }
            progress(Double(step + 1) / 6)
        }
        return best
    }

    /// Binary search on the long side for the largest picture whose encoding fits. Returns the encoding
    /// and the scaled picture it came from (so a better quality can be tried without re-compressing).
    private static func fitBySize(src: CGImageSource, full: CGImage, target: Int, progress: (Double) -> Void,
                                  encoder: (CGImage) -> Data?) throws -> (data: Data, image: CGImage) {
        if let d = encoder(full), d.count <= target { return (d, full) }
        var lo = 16, hi = max(full.width, full.height) - 1
        var best: (data: Data, image: CGImage)?
        var smallest: Int?
        for step in 0..<12 where lo <= hi {
            let mid = (lo + hi + 1) / 2
            guard let scaled = try? Converter.orientedImage(src, maxPixels: mid), let d = encoder(scaled) else { break }
            smallest = min(smallest ?? .max, d.count)
            if d.count <= target { best = (d, scaled); lo = mid + 1 } else { hi = mid - 1 }
            progress(Double(step + 1) / 12)
            if let b = best, Double(b.data.count) > Double(target) * 0.97 { break }   // close enough
        }
        guard let best else { throw tooBig(target, smallest: smallest) }
        return best
    }

    /// WebP through cwebp's size targeting, retried smaller (and then scaled down) until it fits.
    private static func webp(_ image: CGImage, source: URL, target: Int, progress: (Double) -> Void) throws -> URL {
        guard let cwebp = Capabilities.shared.cwebp else { throw ConversionError.missingTool("cwebp") }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("dropwheel-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let png = tmp.appendingPathComponent("in.png")
        guard let data = encode(image, type: UTType.png.identifier, quality: 1, metadata: [:]) else {
            throw ConversionError.toolFailed("Couldn’t prepare the image.")
        }
        try data.write(to: png)
        var aim = Double(target) * 0.97
        var scale = 1.0
        var smallest: Int?
        for attempt in 0..<8 {
            let out = tmp.appendingPathComponent("try\(attempt).webp")
            var args = ["-quiet", "-mt", "-size", String(Int(aim)), "-pass", "6", "-metadata", "none"]
            if scale < 1 { args += ["-resize", String(max(16, Int(Double(image.width) * scale))), "0"] }
            let r = try ProcessRunner.run(cwebp, args + [png.path, "-o", out.path])
            guard r.status == 0 else { throw ConversionError.toolFailed("cwebp: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
            let size = ByteSize.of(out)
            smallest = min(smallest ?? .max, size)
            if size <= target { return try save(try Data(contentsOf: out), next: source, ext: "webp") }
            progress(Double(attempt + 1) / 8)
            // cwebp ran out of quality: shrink the picture; otherwise aim a little lower.
            if Double(size) > aim * 1.15 || attempt >= 2 { scale *= 0.75 } else { aim *= 0.9 }
        }
        throw tooBig(target, smallest: smallest)
    }

    private static func encode(_ image: CGImage, type: String, quality: Double, metadata: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        var props = metadata
        props[kCGImageDestinationLossyCompressionQuality] = quality
        props[kCGImagePropertyOrientation] = 1   // the pixels are already upright
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// EXIF, GPS, TIFF and IPTC from the original (minus the orientation, which is baked into the pixels).
    private static func keptMetadata(_ src: CGImageSource) -> [CFString: Any] {
        guard let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
        var keep: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let v = p[key] { keep[key] = v }
        }
        if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nil
            keep[kCGImagePropertyTIFFDictionary] = tiff
        }
        return keep
    }

    /// True when any pixel is at least partly transparent (checked on a copy at most 1024 px across).
    static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let scale = min(1, 1024 / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buffer = ctx.data else { return true }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = buffer.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in stride(from: 3, to: w * h * 4, by: 4) where bytes[i] < 255 { return true }
        return false
    }

    /// JPEG has no transparency: composite onto white so see-through areas don't turn black.
    private static func flattenedIfNeeded(_ image: CGImage) throws -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ConversionError.toolFailed("Couldn’t flatten the image.") }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white); ctx.fill(rect); ctx.draw(image, in: rect)
        guard let flat = ctx.makeImage() else { throw ConversionError.toolFailed("Couldn’t flatten the image.") }
        return flat
    }

    private static func save(_ data: Data, next source: URL, ext: String) throws -> URL {
        let out = outputURL(for: source, ext: ext, suffix: " compressed")
        try data.write(to: out, options: .withoutOverwriting)
        return out
    }

    // MARK: Video

    /// Bits per pixel per frame below which VideoToolbox's H.264 starts to fall apart (or ignores the bitrate).
    private static let minBitsPerPixel = 0.05

    /// `constantRate`: try VideoToolbox's constant-bitrate mode first (option `constant_bitrate`, default on).
    /// Where the Mac can't do it, or with it off, a capped average bitrate (-maxrate/-bufsize) is used.
    static func video(_ url: URL, target: Int, constantRate cbr: Bool = true, progress: @escaping (Double) -> Void) throws -> URL {
        guard let ff = FFmpeg.shared else { throw ConversionError.missingTool("ffmpeg") }
        guard Capabilities.shared.has("h264_videotoolbox") else {
            throw ConversionError.unsupported("This copy of ffmpeg can’t encode H.264 with VideoToolbox.")
        }
        let info = Probe.of(url, ffmpeg: ff)
        try info.requireReadable(url)
        guard info.hasVideo else {
            // A movie file holding only sound (an .mp4 podcast, say) is compressed as audio.
            if info.hasAudio { return try audio(url, target: target, progress: progress) }
            throw ConversionError.unsupported("\(url.lastPathComponent) has no video or audio track.")
        }
        let duration = try usableDuration(info, url)
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("dropwheel-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // MP4 overhead: about 1.5% for the index plus a few KB of headers.
        let budget = Double(target) * 0.975 - 4096
        var done = 0.0

        // The soundtrack first, so the picture gets exactly what's left.
        var audioFile: URL?
        var audioBytes = 0
        if info.hasAudio {
            let totalKbps = budget * 8 / duration / 1000
            let kbps = [128, 96, 64, 48, 32, 24].first { Double($0) <= totalKbps * 0.15 } ?? 24
            let a = tmp.appendingPathComponent("audio.m4a")
            try ff.run(input: url, output: a, args: ["-vn", "-map", "0:a:0"] + aacArgs(kbps: kbps, info: info),
                       duration: duration) { progress(0.1 * $0) }
            audioFile = a
            audioBytes = ByteSize.of(a)
            done = 0.1
        }
        var videoKbps = (budget - Double(audioBytes)) * 8 / duration / 1000
        guard videoKbps >= 16 else { throw tooBig(target, smallest: nil) }

        // A frame size the bitrate can carry.
        let fps = min(max(info.fps ?? 30, 10), 60)
        let shortSide = Double(max(1, min(info.width, info.height)))
        let minScale = min(1, 144 / shortSide)
        var scale = 1.0
        if info.width > 0, info.height > 0 {
            let bpp = videoKbps * 1000 / (Double(info.width * info.height) * fps)
            if bpp < minBitsPerPixel { scale = max(minScale, (bpp / minBitsPerPixel).squareRoot()) }
        }

        var constantRate = cbr
        var best: (url: URL, size: Int)?
        var smallest: Int?
        var attempt = 0
        while attempt < 5 {
            let out = tmp.appendingPathComponent("try\(attempt).mp4")
            var args = ["-map", "0:v:0"] + (audioFile != nil ? ["-map", "1:a:0", "-c:a", "copy"] : ["-an"])
            args += ["-c:v", "h264_videotoolbox", "-b:v", "\(Int(videoKbps))k"]
            args += constantRate ? ["-constant_bit_rate", "1"]
                                 : ["-maxrate", "\(Int(videoKbps))k", "-bufsize", "\(Int(videoKbps * 2))k"]
            args += ["-allow_sw", "1", "-pix_fmt", "yuv420p", "-tag:v", "avc1",
                     "-vf", "scale=trunc(iw*\(scale)/2)*2:trunc(ih*\(scale)/2)*2", "-sn", "-dn", "-movflags", "+faststart"]
            let lo = done, hi = done + (0.99 - done) * 0.75
            do {
                try ff.run(input: url, output: out, args: args, duration: duration,
                           extraInputs: audioFile.map { ["-i", $0.path] } ?? []) { progress(lo + (hi - lo) * $0) }
            } catch where constantRate {
                constantRate = false   // older Macs and Intel chips can't do constant bitrate; use a capped average
                continue
            }
            done = hi
            let size = ByteSize.of(out)
            smallest = min(smallest ?? .max, size)
            attempt += 1
            if size <= target {
                if size > best?.size ?? 0 { best = (out, size) }
                if Double(size) >= Double(target) * 0.8 { break }
                // Well under: spend more of the budget.
                videoKbps *= min(1.5, Double(target) * 0.95 / Double(size))
                continue
            }
            if best != nil { break }   // a lower attempt already fits; this one overshot
            let videoBytes = Double(size - audioBytes)
            let ratio = videoBytes / max(1, budget - Double(audioBytes))
            if ratio > 1.3, scale > minScale {
                // The encoder couldn't go that low at this size: shrink the picture.
                scale = max(minScale, scale / ratio.squareRoot())
            } else {
                videoKbps = videoKbps / ratio * 0.95
            }
            guard videoKbps >= 16 else { break }
        }
        guard let best else { throw tooBig(target, smallest: smallest) }
        let final = outputURL(for: url, ext: "mp4", suffix: " compressed")
        try fm.moveItem(at: best.url, to: final)
        progress(1)
        return final
    }

    /// The length the bitrate is worked out from: known, and long enough to divide by.
    private static func usableDuration(_ info: Probe, _ url: URL) throws -> Double {
        guard let duration = info.duration else {
            throw ConversionError.unsupported("Couldn’t tell how long \(url.lastPathComponent) is.")
        }
        guard duration >= 0.1 else {
            throw ConversionError.unsupported("\(url.lastPathComponent) is too short (\(String(format: "%.2f", duration)) s) "
                                              + "to compress to a size.")
        }
        return duration
    }

    private static func aacArgs(kbps: Int, info: Probe) -> [String] {
        let encoder = Capabilities.shared.has("aac_at") ? "aac_at" : "aac"
        var args = ["-c:a", encoder, "-b:a", "\(kbps)k"]
        if kbps < 64 || info.channels == 1 { args += ["-ac", "1"] } else if (info.channels ?? 2) > 2 { args += ["-ac", "2"] }
        if kbps < 32 { args += ["-ar", "24000"] } else if (info.sampleRate ?? 48_000) > 48_000 { args += ["-ar", "48000"] }
        return args
    }

    // MARK: Audio

    static func audio(_ url: URL, target: Int, progress: @escaping (Double) -> Void) throws -> URL {
        guard let ff = FFmpeg.shared else { throw ConversionError.missingTool("ffmpeg") }
        let info = Probe.of(url, ffmpeg: ff)
        try info.requireReadable(url)
        guard info.hasAudio else { throw ConversionError.unsupported("\(url.lastPathComponent) has no audio track.") }
        let duration = try usableDuration(info, url)
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("dropwheel-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let mp3Rates = [320, 256, 224, 192, 160, 128, 112, 96, 80, 64, 56, 48, 40, 32]
        let wantsMP3 = Ext.of(url) == "mp3" && Capabilities.shared.has("libmp3lame")
        var kbps = (Double(target) * 0.97 - 4096) * 8 / duration / 1000
        var smallest: Int?
        for attempt in 0..<4 {
            let useMP3 = wantsMP3 && kbps >= 32
            let rate: Int
            if useMP3 {
                rate = mp3Rates.first { Double($0) <= kbps } ?? 32
            } else {
                rate = min(256, Int(kbps.rounded(.down)))
                guard rate >= 12 else { break }
            }
            let out = tmp.appendingPathComponent("try\(attempt).\(useMP3 ? "mp3" : "m4a")")
            let args = ["-vn", "-map", "0:a:0", "-map_metadata", "0"]
                + (useMP3 ? ["-c:a", "libmp3lame", "-b:a", "\(rate)k"] + (info.channels ?? 2 > 2 ? ["-ac", "2"] : [])
                    + ((info.sampleRate ?? 44_100) > 48_000 ? ["-ar", "48000"] : [])
                    : aacArgs(kbps: rate, info: info))
            try ff.run(input: url, output: out, args: args, duration: duration) { p in progress((Double(attempt) + p) / 4) }
            let size = ByteSize.of(out)
            smallest = min(smallest ?? .max, size)
            if size <= target {
                let final = outputURL(for: url, ext: useMP3 ? "mp3" : "m4a", suffix: " compressed")
                try fm.moveItem(at: out, to: final)
                progress(1)
                return final
            }
            kbps = Double(rate) * Double(target) / Double(size) * 0.95
        }
        throw tooBig(target, smallest: smallest)
    }

    // MARK: PDF

    /// Stronger and stronger image settings: JPEG quality and the resolution images are scaled down to.
    private static let pdfLevels: [(quality: Double, dpi: Int)] = [(0.75, 200), (0.6, 150), (0.5, 120), (0.4, 96),
                                                                   (0.3, 72), (0.2, 50), (0.1, 36)]

    private static func pdfFilter(quality: Double, dpi: Int) -> QuartzFilter? {
        QuartzFilter(properties: [
            "Domains": ["Applications": true, "Printing": true],
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": quality,
                "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": ["ImageResolution": dpi, "ImageScaleAddNoise": false,
                                       "ImageScaleInterpolate": true, "ImageSizeMax": 0, "ImageSizeMin": 0],
            ]]],
            "FilterType": 1,
            "Name": "YummyOrange Compress to Size",
        ])
    }

    static func pdf(_ url: URL, target: Int, progress: @escaping (Double) -> Void) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
        if doc.isLocked {
            throw ConversionError.unsupported("\(url.lastPathComponent) is password-protected. Use Remove Password first.")
        }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("dropwheel-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        var smallest: Int?
        for (i, level) in pdfLevels.enumerated() {
            guard let filter = pdfFilter(quality: level.quality, dpi: level.dpi) else {
                throw ConversionError.unsupported("Couldn’t set up PDF compression on this Mac.")
            }
            let out = tmp.appendingPathComponent("level\(i).pdf")
            guard doc.write(to: out, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) else {
                throw ConversionError.toolFailed("Couldn’t save the compressed PDF.")
            }
            let size = ByteSize.of(out)
            progress(Double(i + 1) / Double(pdfLevels.count))
            if size <= target, PDFDocument(url: out)?.pageCount == doc.pageCount {
                let final = outputURL(for: url, ext: "pdf", suffix: " compressed")
                try fm.moveItem(at: out, to: final)
                return final
            }
            try? fm.removeItem(at: out)
            // Text and drawings don't shrink: stop once a stronger setting stops helping.
            if let s = smallest, Double(size) > Double(s) * 0.98 { break }
            smallest = min(smallest ?? .max, size)
        }
        throw tooBig(target, smallest: smallest)
    }

    // MARK: Self-test

    /// `--selftest target-size`: suggestions, transparency detection, and an image squeezed to a size.
    static func selfTest() -> String {
        var failures: [String] = []
        if suggestedTarget(4_200_000) != 2.1 { failures.append("suggest 4.2 MB → \(suggestedTarget(4_200_000))") }
        if suggestedTarget(31_000_000) != 15 { failures.append("suggest 31 MB → \(suggestedTarget(31_000_000))") }
        if suggestedTarget(150_000) != 0.075 { failures.append("suggest 150 KB → \(suggestedTarget(150_000))") }
        // The smallest suggestion is a target that is accepted.
        if targetBytes(suggestedTarget(1500)) < minimumTarget { failures.append("suggest 1.5 KB → \(suggestedTarget(1500)) is refused") }
        for (mb, bytes) in [(0.001, 1000), (0.0015, 1500), (0.3, 300_000), (2.5, 2_500_000), (0.00103, 1030), (1e20, 1_000_000_000_000_000_000)] where targetBytes(mb) != bytes {
            failures.append("\(mb) MB → \(targetBytes(mb)) bytes")
        }

        // A noisy 1600×1000 picture as PNG, with and without transparency.
        func noise(alpha: Bool) -> CGImage? {
            let w = 1600, h = 1000
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let p = ctx.data else { return nil }
            let px = p.bindMemory(to: UInt8.self, capacity: w * h * 4)
            var seed: UInt32 = 12345
            for i in 0..<(w * h) {
                for c in 0..<3 { seed = seed &* 1_664_525 &+ 1_013_904_223; px[i * 4 + c] = UInt8(truncatingIfNeeded: seed >> 24) }
                px[i * 4 + 3] = 255
            }
            if alpha { for i in 0..<(w * 50) { px[i * 4] = 0; px[i * 4 + 1] = 0; px[i * 4 + 2] = 0; px[i * 4 + 3] = 0 } }
            return ctx.makeImage()
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("dropwheel-target-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for alpha in [false, true] {
                guard let img = noise(alpha: alpha), let png = encode(img, type: UTType.png.identifier, quality: 1, metadata: [:]) else {
                    failures.append("couldn’t make test image"); continue
                }
                if hasTransparency(img) != alpha { failures.append("transparency \(alpha) misread") }
                let src = dir.appendingPathComponent(alpha ? "clear.png" : "opaque.png")
                try png.write(to: src)
                let target = 300_000
                if !alpha {
                    let (message, suggested) = prompt(for: [src])
                    let expected = "opaque.png is \(ByteSize.text(png.count)). Choose the most it may take up."
                    if message != expected || suggested != suggestedTarget(png.count) { failures.append("prompt: \(message) \(suggested)") }
                }
                let out = try compress(src, options: ["target_mb": "0.3"], progress: { _ in })
                let size = ByteSize.of(out)
                if size > target { failures.append("\(src.lastPathComponent) → \(size) bytes, over \(target)") }
                if out.pathExtension != (alpha ? "png" : "jpg") { failures.append("\(src.lastPathComponent) → .\(out.pathExtension)") }
            }
            // A 3-page TIFF and an animated PNG are refused: only the first page or frame would be kept.
            if let img = noise(alpha: false) {
                for (type, ext) in [(UTType.tiff.identifier, "tif"), (UTType.png.identifier, "png")] {
                    let file = dir.appendingPathComponent("several.\(ext)")
                    guard let dest = CGImageDestinationCreateWithURL(file as CFURL, type as CFString, 3, nil) else {
                        failures.append("couldn’t write several.\(ext)"); continue
                    }
                    let apng = ext == "png"
                    if apng {
                        CGImageDestinationSetProperties(dest, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
                    }
                    let frame: [CFString: Any] = apng ? [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.2]] : [:]
                    for _ in 0..<3 { CGImageDestinationAddImage(dest, img, frame as CFDictionary) }
                    guard CGImageDestinationFinalize(dest) else { failures.append("couldn’t write several.\(ext)"); continue }
                    do {
                        let out = try compress(file, options: ["target_mb": "0.3"], progress: { _ in })
                        failures.append("several.\(ext) → \(out.lastPathComponent) instead of a refusal")
                    } catch {
                        let message = error.localizedDescription
                        if !message.contains("has 3 \(apng ? "frames" : "pages")") { failures.append("several.\(ext): \(message)") }
                    }
                }
            }
        } catch {
            failures.append("error: \(error.localizedDescription)")
        }
        return failures.isEmpty ? "OK target-size: prompt, suggestions, minimum, transparency, PNG→JPEG and PNG→PNG under 300 KB, multi-frame refusal"
                                : "FAIL target-size:\n" + failures.joined(separator: "\n")
    }
}

private typealias ByteSize = MoreFormats.ByteSize
private typealias Probe = MoreFormats.MediaProbe
