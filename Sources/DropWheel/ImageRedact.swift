import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision
import CoreML

/// Redaction that can't be undone: the pixels inside each box are replaced (filled black, or rebuilt from a
/// few block averages with noise for Blur and Pixelate, so no detail is left to sharpen back), and the copy is
/// written with no metadata at all (no EXIF, GPS, IPTC, XMP, thumbnails, depth or gain maps).
enum ImageRedact {
    enum Style: String, CaseIterable {
        case black, blur, pixelate

        var title: String { rawValue.capitalized }

        init?(option: String) {
            switch option.trimmingCharacters(in: .whitespaces).lowercased() {
            case "black", "box", "fill", "solid": self = .black
            case "blur", "blurred": self = .blur
            case "pixelate", "pixelated", "pixel", "mosaic": self = .pixelate
            default: return nil
            }
        }
    }

    /// One area to hide, in upright image pixels with a top-left origin.
    struct Box: Equatable {
        var rect: CGRect
        var style: Style
    }

    enum Find: String {
        case none, text, faces, both

        init?(option: String) {
            switch option.trimmingCharacters(in: .whitespaces).lowercased() {
            case "none", "no", "off", "false": self = .none
            case "text", "words": self = .text
            case "faces", "face": self = .faces
            case "both", "all", "text+faces", "faces+text": self = .both
            default: return nil
            }
        }
    }

    // MARK: Options

    /// "x,y,w,h[,style];…" → boxes inside an image of `size` (boxes outside it are dropped).
    static func parseBoxes(_ text: String, size: CGSize, defaultStyle: Style) throws -> [Box] {
        let bounds = CGRect(origin: .zero, size: size)
        var boxes: [Box] = []
        for part in text.split(whereSeparator: { $0 == ";" || $0 == "\n" }) {
            let fields = part.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 4 || fields.count == 5 else { throw badBox(String(part)) }
            let numbers = fields.prefix(4).map { Double($0.replacingOccurrences(of: "−", with: "-")) }
            guard numbers.allSatisfy({ $0 != nil && $0!.isFinite && abs($0!) < 1e7 }) else { throw badBox(String(part)) }
            let v = numbers.map { CGFloat($0!) }
            guard v[2] > 0, v[3] > 0 else { throw badBox(String(part)) }
            var style = defaultStyle
            if fields.count == 5 {
                guard let s = Style(option: fields[4]) else {
                    throw ConversionError.unsupported("“\(fields[4])” isn’t a redaction style. Use black, blur or pixelate.")
                }
                style = s
            }
            let rect = FrameEditing.integral(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]), in: bounds)
            if rect.width >= 1, rect.height >= 1 { boxes.append(Box(rect: rect, style: style)) }
        }
        return boxes
    }

    private static func badBox(_ text: String) -> ConversionError {
        .unsupported("Couldn’t read the box “\(text)”. Write boxes=x,y,w,h,style;… in pixels of the upright image "
                     + "(style is black, blur or pixelate).")
    }

    /// The option string for boxes: what the Redact window passes to the command. Whole pixels rounded
    /// outwards, so a box moved by a fraction of a pixel (arrow keys move by points) still covers everything
    /// the window showed covered.
    static func format(_ boxes: [Box]) -> String {
        boxes.map { b in
            let x0 = Int(b.rect.minX.rounded(.down)), y0 = Int(b.rect.minY.rounded(.down))
            let x1 = Int(b.rect.maxX.rounded(.up)), y1 = Int(b.rect.maxY.rounded(.up))
            return "\(x0),\(y0),\(x1 - x0),\(y1 - y0),\(b.style.rawValue)"
        }.joined(separator: ";")
    }

    // MARK: Running

    /// Options: boxes=x,y,w,h[,style];… (upright pixels), find=text|faces|both|none (default: none when boxes
    /// are given, otherwise both), style=black|blur|pixelate (default black, for found boxes and boxes without
    /// one). Writes "<name> redacted.<ext>" in the source's format (PNG for RAW and animations) with no metadata.
    static func save(_ url: URL, options: ToolOptions) throws -> URL {
        let name = url.lastPathComponent
        let source = try ImageEditors.SourceImage(url)
        guard let style = Style(option: options.string("style", "black")) else {
            throw ConversionError.unsupported("“\(options["style"] ?? "")” isn’t a redaction style. Use black, blur or pixelate.")
        }
        let given = try parseBoxes(options.string("boxes", ""), size: source.size, defaultStyle: style)
        let hasBoxOption = !options.string("boxes", "").isEmpty
        guard let find = Find(option: options.string("find", hasBoxOption ? "none" : "both")) else {
            throw ConversionError.unsupported("“\(options["find"] ?? "")” isn’t something to find. Use text, faces, both or none.")
        }
        if hasBoxOption && given.isEmpty && find == .none {
            throw ConversionError.unsupported("Every box is outside \(name), which is \(Int(source.size.width)) × \(Int(source.size.height)) pixels.")
        }
        let image = try source.fullImage()
        var boxes = given
        if find != .none {
            let look = try Converter.orientedImage(source.source, maxPixels: min(4096, Int(source.longSide)))
            var found: [CGRect] = []
            if find == .text || find == .both { found += try findText(look) }
            if find == .faces || find == .both { found += try findFaces(look) }
            let k = source.size.width / CGFloat(look.width)
            boxes += found.map { Box(rect: scaled($0, by: k, in: source.size), style: style) }
        }
        guard !boxes.isEmpty else {
            let what = find == .text ? "text" : find == .faces ? "faces" : "text or faces"
            throw ConversionError.unsupported("Found no \(what) to redact in \(name). Draw boxes in the Redact window, "
                                              + "or pass boxes=x,y,w,h;…")
        }
        let redacted = try apply(boxes, to: image)
        return try writeWithoutMetadata(redacted, like: source, suffix: " redacted")
    }

    static func scaled(_ r: CGRect, by k: CGFloat, in size: CGSize) -> CGRect {
        FrameEditing.integral(CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k),
                              in: CGRect(origin: .zero, size: size))
    }

    // MARK: Pixels

    /// The image with every box's pixels replaced. 8 bits per channel in a standard RGB space (see
    /// `cleanColorSpace`); transparency is kept outside the boxes, and boxes become opaque.
    /// `detail` is how many pixels of the saved file one pixel of `image` stands for: the editor previews on a
    /// downscaled proxy and passes its scale, so Blur and Pixelate pick the same number of blocks per box as
    /// the file will get (a smaller picture would otherwise get coarser blocks than the saved copy).
    static func apply(_ boxes: [Box], to image: CGImage, detail: CGFloat = 1) throws -> CGImage {
        let w = image.width, h = image.height
        let alpha = ImageEditors.hasAlpha(image)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cleanColorSpace(for: image),
                                  bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue),
              let data = ctx.data else {
            throw ConversionError.toolFailed("There isn’t enough memory to redact this image.")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        var rng = Noise()
        let detail = detail.isFinite && detail > 0 ? Double(detail) : 1
        for box in boxes {
            let r = FrameEditing.integral(box.rect, in: bounds)
            guard r.width >= 1, r.height >= 1 else { continue }
            let region = Region(x0: Int(r.minX), y0: Int(r.minY), width: Int(r.width), height: Int(r.height))
            switch box.style {
            case .black: fillBlack(pixels, stride: w, region)
            case .pixelate: pixelate(pixels, stride: w, region, detail: detail, &rng)
            case .blur: blur(pixels, stride: w, region, detail: detail, &rng)
            }
        }
        guard let out = ctx.makeImage() else { throw ConversionError.toolFailed("Couldn’t redact the image.") }
        return out
    }

    /// The colour space a redacted copy is written in. An ICC profile is metadata too: besides colours it holds
    /// free text (its description, copyright, maker and model), and a calibrated display's or a camera's profile
    /// can name the person, the machine or the serial number; macOS screenshots carry the display's profile.
    /// So only the system's own standard profiles are kept (ImageIO names the ones it recognises, and the copy
    /// gets the system's bytes, not the file's); any other RGB profile is converted to Display P3, and grey,
    /// CMYK and indexed pictures to sRGB.
    static func cleanColorSpace(for image: CGImage) -> CGColorSpace {
        // Extended-range and HDR (PQ, HLG) spaces don't fit 8 bits per channel; they take the Display P3 path.
        if let space = image.colorSpace, space.model == .rgb, let name = space.name as String?,
           !["extended", "pq", "hlg"].contains(where: { name.lowercased().contains($0) }),
           let standard = CGColorSpace(name: name as CFString), standard.model == .rgb {
            return standard
        }
        if image.colorSpace?.model == .rgb { return CGColorSpace(name: CGColorSpace.displayP3)! }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// A fast generator for the faint noise Blur and Pixelate add (seeded from the system's): SplitMix64.
    /// The system generator costs a kernel call per number, which made Blur take seconds on a big box.
    struct Noise: RandomNumberGenerator {
        private var state: UInt64

        init() {
            var system = SystemRandomNumberGenerator()
            state = system.next()
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Uniform in -amplitude...amplitude.
        mutating func unit(_ amplitude: Float) -> Float {
            Float(next() >> 40) * (2 * amplitude / Float(1 << 24)) - amplitude
        }
    }

    private struct Region { let x0, y0, width, height: Int }

    private static func fillBlack(_ p: UnsafeMutablePointer<UInt8>, stride: Int, _ r: Region) {
        for y in r.y0..<(r.y0 + r.height) {
            var i = (y * stride + r.x0) * 4
            for _ in 0..<r.width { p[i] = 0; p[i + 1] = 0; p[i + 2] = 0; p[i + 3] = 255; i += 4 }
        }
    }

    /// Block averages over a grid with `n` blocks along the region's short side: all that survives.
    private static func blockAverages(_ p: UnsafeMutablePointer<UInt8>, stride: Int, _ r: Region, block: Int)
        -> (cols: Int, rows: Int, values: [[Double]]) {
        let cols = (r.width + block - 1) / block, rows = (r.height + block - 1) / block
        var values = [[Double]](repeating: [0, 0, 0], count: cols * rows)
        for by in 0..<rows {
            for bx in 0..<cols {
                var sum = [0.0, 0.0, 0.0], n = 0.0
                for y in (r.y0 + by * block)..<min(r.y0 + r.height, r.y0 + (by + 1) * block) {
                    var i = (y * stride + r.x0 + bx * block) * 4
                    for _ in (bx * block)..<min(r.width, (bx + 1) * block) {
                        // Un-premultiply, so see-through areas don't come out dark.
                        let a = max(Double(p[i + 3]), 1) / 255
                        sum[0] += Double(p[i]) / a; sum[1] += Double(p[i + 1]) / a; sum[2] += Double(p[i + 2]) / a
                        n += 1; i += 4
                    }
                }
                values[by * cols + bx] = sum.map { $0 / max(n, 1) }
            }
        }
        return (cols, rows, values)
    }

    private static func store(_ p: UnsafeMutablePointer<UInt8>, _ i: Int, _ rgb: (Double, Double, Double)) {
        p[i] = UInt8(min(255, max(0, rgb.0.rounded())))
        p[i + 1] = UInt8(min(255, max(0, rgb.1.rounded())))
        p[i + 2] = UInt8(min(255, max(0, rgb.2.rounded())))
        p[i + 3] = 255
    }

    /// Blocks per short side: 4 for text-sized boxes up to 8 for big ones (faces), whatever the image size.
    /// `detail` (pixels of the saved file per pixel here) makes a preview pick the saved file's block count.
    static func pixelateBlock(width: Int, height: Int, detail: Double = 1) -> Int {
        let short = Double(min(width, height))
        let n = min(8, max(4, (short * detail / 24).rounded()))
        return max(2, Int((short / n).rounded(.up)))
    }

    /// Blur's grid: 3 to 8 blocks per short side, chosen like `pixelateBlock`.
    static func blurBlock(width: Int, height: Int, detail: Double = 1) -> Int {
        let short = Double(min(width, height))
        let n = min(8, max(3, (short * detail / 28).rounded()))
        return max(2, Int((short / n).rounded(.up)))
    }

    /// Mosaic: each block one colour (its average, with a little random noise against pattern matching).
    private static func pixelate(_ p: UnsafeMutablePointer<UInt8>, stride: Int, _ r: Region, detail: Double, _ rng: inout Noise) {
        let block = pixelateBlock(width: r.width, height: r.height, detail: detail)
        let grid = blockAverages(p, stride: stride, r, block: block)
        for by in 0..<grid.rows {
            for bx in 0..<grid.cols {
                let v = grid.values[by * grid.cols + bx]
                let c = (v[0] + Double(rng.unit(6)), v[1] + Double(rng.unit(6)), v[2] + Double(rng.unit(6)))
                for y in (r.y0 + by * block)..<min(r.y0 + r.height, r.y0 + (by + 1) * block) {
                    var i = (y * stride + r.x0 + bx * block) * 4
                    for _ in (bx * block)..<min(r.width, (bx + 1) * block) { store(p, i, c); i += 4 }
                }
            }
        }
    }

    /// Blur: rebuilt smoothly from a coarse grid of block averages (3 to 8 per short side), then softened and
    /// sprinkled with noise. Looks like a heavy blur; holds no more detail than the grid, so it can't be
    /// sharpened back. One channel at a time in 32-bit floats: 8 bytes per pixel of the box at most (a box
    /// over a whole 48-megapixel photo needed 2.3 GB more in doubles, three channels at once).
    private static func blur(_ p: UnsafeMutablePointer<UInt8>, stride: Int, _ r: Region, detail: Double, _ rng: inout Noise) {
        let block = blurBlock(width: r.width, height: r.height, detail: detail)
        let grid = blockAverages(p, stride: stride, r, block: block)
        // Bilinear between block centres, clamped at the edges: the two grid columns (rows) and the weight for
        // every x (y), worked out once.
        func axis(_ length: Int, _ cells: Int) -> (lo: [Int], hi: [Int], f: [Float]) {
            var lo = [Int](repeating: 0, count: length), hi = lo, f = [Float](repeating: 0, count: length)
            for i in 0..<length {
                let g = min(max((Double(i) + 0.5) / Double(block) - 0.5, 0), Double(cells - 1))
                lo[i] = Int(g); hi[i] = min(lo[i] + 1, cells - 1); f[i] = Float(g - Double(lo[i]))
            }
            return (lo, hi, f)
        }
        let ax = axis(r.width, grid.cols), ay = axis(r.height, grid.rows)
        let radius = max(1, block / 2)
        var plane = [Float](repeating: 0, count: r.width * r.height)
        var scratch = [Float](repeating: 0, count: max(r.width, r.height))
        for k in 0..<3 {
            let g = grid.values.map { Float($0[k]) }
            plane.withUnsafeMutableBufferPointer { out in
                for y in 0..<r.height {
                    let fy = ay.f[y], top = ay.lo[y] * grid.cols, bottom = ay.hi[y] * grid.cols
                    for x in 0..<r.width {
                        let fx = ax.f[x], x0 = ax.lo[x], x1 = ax.hi[x]
                        let upper = g[top + x0] * (1 - fx) + g[top + x1] * fx
                        let lower = g[bottom + x0] * (1 - fx) + g[bottom + x1] * fx
                        out[y * r.width + x] = upper * (1 - fy) + lower * fy
                    }
                }
            }
            // Two box-blur passes (radius half a block) smooth the bilinear creases.
            for _ in 0..<2 { boxBlur(&plane, &scratch, width: r.width, height: r.height, radius: radius) }
            plane.withUnsafeBufferPointer { values in
                for y in 0..<r.height {
                    var i = ((r.y0 + y) * stride + r.x0) * 4 + k
                    for x in 0..<r.width {
                        p[i] = UInt8(min(255, max(0, (values[y * r.width + x] + rng.unit(2)).rounded())))
                        if k == 0 { p[i + 3] = 255 }
                        i += 4
                    }
                }
            }
        }
    }

    /// A box blur of one channel, in place: each row, then each column, through a one-line scratch buffer
    /// (edges repeat the last pixel).
    private static func boxBlur(_ plane: inout [Float], _ scratch: inout [Float], width w: Int, height h: Int, radius: Int) {
        let n = Double(2 * radius + 1)
        plane.withUnsafeMutableBufferPointer { v in
            scratch.withUnsafeMutableBufferPointer { line in
                // Rows: copy the row out, then write the running mean back.
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w { line[x] = v[row + x] }
                    var sum = 0.0
                    for x in -radius...radius { sum += Double(line[min(max(x, 0), w - 1)]) }
                    for x in 0..<w {
                        v[row + x] = Float(sum / n)
                        sum += Double(line[min(x + radius + 1, w - 1)]) - Double(line[max(x - radius, 0)])
                    }
                }
                // Columns, the same way.
                for x in 0..<w {
                    for y in 0..<h { line[y] = v[y * w + x] }
                    var sum = 0.0
                    for y in -radius...radius { sum += Double(line[min(max(y, 0), h - 1)]) }
                    for y in 0..<h {
                        v[y * w + x] = Float(sum / n)
                        sum += Double(line[min(y + radius + 1, h - 1)]) - Double(line[max(y - radius, 0)])
                    }
                }
            }
        }
    }

    // MARK: Writing

    /// Writes `image` next to the source as "<name><suffix>.<ext>" in the source's format (PNG when it can't
    /// be written or is an animation) with nothing but the pixels and their colour profile: no EXIF, GPS,
    /// TIFF, IPTC or XMP, no thumbnail, no orientation tag (the pixels are upright).
    static func writeWithoutMetadata(_ image: CGImage, like source: ImageEditors.SourceImage, suffix: String) throws -> URL {
        let format = source.outputFormat
        func write(_ type: String, _ ext: String) throws -> URL {
            let out = outputURL(for: source.url, ext: ext, suffix: suffix)
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, 1, nil) else {
                throw ConversionError.unsupported("This Mac can’t write \(ext.uppercased()) images.")
            }
            var props: [CFString: Any] = [kCGImageDestinationEmbedThumbnail: false]
            if ImageEditors.lossyTypes.contains(type) { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            guard ImageEditors.finalize(dest, at: out) else {
                throw ConversionError.toolFailed("Couldn’t save \(out.lastPathComponent).")
            }
            return out
        }
        do { return try write(format.type, format.ext) }
        catch where format.type != UTType.png.identifier { return try write(UTType.png.identifier, "png") }
    }

    // MARK: Finding (Vision)

    /// One line Vision read: its text and box, and a box per word (split at spaces), all normalized with a
    /// bottom-left origin.
    struct ReadLine {
        let text: String
        let box: CGRect
        let words: [CGRect]
    }

    /// Text recognition with VNRecognizeTextRequest, run on the CPU first. Measured on this Mac (macOS 27,
    /// M5 Pro): the CPU reads a 4800 × 3000 picture in 0.2 s with the same words as the Neural Engine, and the
    /// default device failed outright (an e5rt error) in a process that had editor windows open. (The very first
    /// request of a freshly built binary waits about 24 s for Vision to prepare its model on either device.)
    /// Fallbacks: the default device, then (macOS 15 and later) RecognizeTextRequest.
    static func recognize(_ image: CGImage) throws -> [ReadLine] {
        do { return try recognizeLegacy(image, cpuOnly: true) } catch {}
        do { return try recognizeLegacy(image, cpuOnly: false) } catch {
            if #available(macOS 15.0, *) { return try recognizeNew(image) }
            throw error
        }
    }

    /// Splits `text` at whitespace and asks `box` for each word's box.
    private static func wordBoxes(_ text: String, _ box: (Range<String.Index>) -> CGRect?) -> [CGRect] {
        var boxes: [CGRect] = []
        var start: String.Index?
        var i = text.startIndex
        while true {
            let atEnd = i == text.endIndex
            if atEnd || text[i].isWhitespace {
                if let s = start, let b = box(s..<i) { boxes.append(b) }
                start = nil
            } else if start == nil {
                start = i
            }
            if atEnd { break }
            i = text.index(after: i)
        }
        return boxes
    }

    @available(macOS 15.0, *)
    private static func recognizeNew(_ image: CGImage) throws -> [ReadLine] {
        var failure: Error?
        var results: [RecognizedTextObservation] = []
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                var request = RecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.automaticallyDetectsLanguage = true
                results = try await request.perform(on: image)
            } catch { failure = error }
            done.signal()
        }
        done.wait()   // Vision runs on its own threads, so this is safe on the main thread too
        if let failure { throw failure }
        return results.compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            return ReadLine(text: top.string, box: obs.boundingBox.cgRect,
                            words: wordBoxes(top.string) { top.boundingBox(for: $0)?.boundingBox.cgRect })
        }
    }

    private static func recognizeLegacy(_ image: CGImage, cpuOnly: Bool) throws -> [ReadLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        if cpuOnly {
            if #available(macOS 14.0, *) {
                if let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { return true } else { return false } }) {
                    request.setComputeDevice(cpu, for: .main)
                }
            } else {
                request.usesCPUOnly = true
            }
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            return ReadLine(text: top.string, box: obs.boundingBox,
                            words: wordBoxes(top.string) { (try? top.boundingBox(for: $0))?.boundingBox })
        }
    }

    /// Normalized (bottom-left) → pixels (top-left).
    private static func pixels(_ b: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: b.minX * size.width, y: (1 - b.maxY) * size.height, width: b.width * size.width, height: b.height * size.height)
    }

    /// Every line Vision reads, with its box in pixels (top-left origin). For checking a redaction.
    static func readText(_ image: CGImage) throws -> [(text: String, box: CGRect)] {
        let size = CGSize(width: image.width, height: image.height)
        return try recognize(image).map { ($0.text, pixels($0.box, size)) }
    }

    /// Word boxes (split at spaces, so “alex@example.com” stays one box) in image pixels with a top-left
    /// origin, a little larger than Vision's so ascenders and descenders are covered.
    static func findText(_ image: CGImage) throws -> [CGRect] {
        let size = CGSize(width: image.width, height: image.height)
        return try recognize(image).flatMap(\.words).map { b in
            let r = pixels(b, size)
            // Taller than Vision's box for ascenders and descenders; barely wider, so neighbouring words don't overlap.
            return FrameEditing.integral(r.insetBy(dx: -r.height * 0.06, dy: -r.height * 0.18), in: CGRect(origin: .zero, size: size))
        }.filter { $0.width >= 2 && $0.height >= 2 }
    }

    /// Face boxes in image pixels (top-left origin), grown to take in the forehead, hair and chin. Big pictures
    /// are also searched in four overlapping tiles, which finds small faces the whole-picture pass misses.
    static func findFaces(_ image: CGImage) throws -> [CGRect] {
        let size = CGSize(width: image.width, height: image.height)
        var faces = try detectFaces(image, offset: .zero)
        if max(size.width, size.height) >= 800 {
            let tw = (size.width * 0.6).rounded(), th = (size.height * 0.6).rounded()
            for (fx, fy) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
                let tile = CGRect(x: ((size.width - tw) * fx).rounded(), y: ((size.height - th) * fy).rounded(), width: tw, height: th)
                guard let part = image.cropping(to: tile) else { continue }
                for face in try detectFaces(part, offset: tile.origin) where !faces.contains(where: { overlaps($0, face) }) {
                    faces.append(face)
                }
            }
        }
        return faces.map { r in
            let grown = CGRect(x: r.minX - r.width * 0.2, y: r.minY - r.height * 0.35, width: r.width * 1.4, height: r.height * 1.55)
            return FrameEditing.integral(grown, in: CGRect(origin: .zero, size: size))
        }.filter { $0.width >= 2 && $0.height >= 2 }
    }

    private static func detectFaces(_ image: CGImage, offset: CGPoint) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return (request.results ?? []).map { obs in
            let b = obs.boundingBox
            return CGRect(x: offset.x + b.minX * w, y: offset.y + (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
        }
    }

    /// The same face found twice: the boxes share at least a third of the smaller one.
    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        guard !i.isNull else { return false }
        return i.width * i.height >= min(a.width * a.height, b.width * b.height) / 3
    }
}

// MARK: - Sample picture

/// A made-up contact card with an avatar, for `--snapshot redact-image` and the self-test: clearly fictional
/// text (example.com, a 555 number) and a person emoji Vision reads as a face.
enum RedactSample {
    static let avatarCandidates = ["🧑🏽", "🧑🏾", "🧑🏻", "👩🏽"]

    static func write(to dir: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = dir.appendingPathComponent("dropwheel-redact-sample.png")
        let image = card(avatar: avatarCandidates[0])
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ConversionError.toolFailed("Couldn’t write the sample image.")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.toolFailed("Couldn’t write the sample image.") }
        return url
    }

    static func card(avatar: String, width: Int = 1600, height: Int = 1000) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let W = CGFloat(width), H = CGFloat(height)
        let backdrop = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  colors: [CGColor(srgbRed: 0.80, green: 0.86, blue: 0.93, alpha: 1),
                                           CGColor(srgbRed: 0.93, green: 0.90, blue: 0.86, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(backdrop, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
        let card = CGRect(x: W * 0.1, y: H * 0.14, width: W * 0.8, height: H * 0.72)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 30, color: CGColor(gray: 0, alpha: 0.18))
        ctx.addPath(CGPath(roundedRect: card, cornerWidth: 36, cornerHeight: 36, transform: nil))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        // Avatar disc with the emoji face.
        let disc = CGRect(x: card.minX + 70, y: card.maxY - 70 - 380, width: 380, height: 380)
        ctx.setFillColor(CGColor(srgbRed: 0.86, green: 0.91, blue: 0.97, alpha: 1))
        ctx.fillEllipse(in: disc)
        // Sized so Vision's face detector reliably sees the emoji as a face.
        let emoji = NSAttributedString(string: avatar, attributes: [.font: NSFont(name: "Apple Color Emoji", size: 260)
                                                                     ?? NSFont.systemFont(ofSize: 260)])
        let es = emoji.size()
        emoji.draw(at: CGPoint(x: disc.midX - es.width / 2, y: disc.midY - es.height / 2 + 8))
        func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ gray: CGFloat, _ y: CGFloat) {
            NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                       .foregroundColor: NSColor(white: gray, alpha: 1)])
                .draw(at: CGPoint(x: disc.maxX + 70, y: y))
        }
        text("Alex Example", 76, .bold, 0.1, card.maxY - 170)
        text("Product designer", 44, .regular, 0.4, card.maxY - 240)
        text("alex@example.com", 46, .medium, 0.15, card.maxY - 360)
        text("+1 555 0100", 46, .medium, 0.15, card.maxY - 430)
        NSAttributedString(string: "Member since 2019 · Order 4417 ships Tuesday",
                           attributes: [.font: NSFont.systemFont(ofSize: 40, weight: .regular), .foregroundColor: NSColor(white: 0.35, alpha: 1)])
            .draw(at: CGPoint(x: card.minX + 70, y: card.minY + 70))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
}
