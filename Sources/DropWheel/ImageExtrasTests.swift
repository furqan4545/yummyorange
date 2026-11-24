#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `--selftest image-extras-files`: the image tools run on generated files in a temporary folder.
/// Regression checks for animations and multi-page TIFFs (every frame kept, upright pages), huge option
/// values (refused, never a crash), SVG resizing, small frames, collage errors and locked PDFs.
enum ImageExtrasTests {
    static func run() -> String {
        var lines: [String] = [], failed = 0
        func expect(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            lines.append((ok ? "ok    " : "FAIL  ") + what + (ok ? "" : "  " + detail()))
            if !ok { failed += 1 }
        }
        /// The error message when `body` throws, nil when it succeeds.
        func failure(_ body: () throws -> Any) -> String? {
            do { _ = try body(); return nil } catch { return error.localizedDescription }
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-image-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            // Animated GIF with a transparent background: 3 frames, 0.2 s each, looping forever.
            let gif = dir.appendingPathComponent("sticker.gif")
            try write((0..<3).map { dotFrame($0) }, to: gif, type: UTType.gif.identifier,
                      frame: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]],
                      file: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]])

            let framed = try ImageExtras.frame(gif, options: [:])
            let f = info(framed)
            expect("frame on animated GIF keeps GIF and 3 frames", f.type == UTType.gif.identifier && f.frames == 3, "got \(f)")
            expect("frame on animated GIF keeps delay and loop", abs(f.delay - 0.2) < 0.01 && f.loop == 0, "got \(f)")
            let partly = try ImageExtras.frame(gif, options: ["color": "#FF000080"])
            let p = info(partly)
            expect("see-through frame on animated GIF is an animated PNG with 3 frames",
                   p.type == UTType.png.identifier && p.frames == 3 && abs(p.delay - 0.2) < 0.01 && p.loop == 0, "got \(p)")

            for (tool, w, h) in [(FileTool.rotate, 40, 60), (.halfSize, 30, 20), (.stripMetadata, 60, 40)] {
                let out = try Converter.perform(.tool(tool), on: gif, progress: { _ in })
                let r = info(out[0])
                expect("\(tool.rawValue) on animated GIF keeps 3 frames, delay and loop",
                       r.frames == 3 && r.width == w && r.height == h && abs(r.delay - 0.2) < 0.01 && r.loop == 0, "got \(r)")
            }

            // Two-page TIFF, each page tagged orientation 6 (stored 60×40, shown 40×60 with blue at the top left).
            let tiff = dir.appendingPathComponent("scan.tif")
            try write([quadrants(), quadrants()], to: tiff, type: UTType.tiff.identifier,
                      frame: [kCGImagePropertyOrientation: 6], file: [:])
            let resized = try ImageExtras.resize(tiff, options: ["value": "50"])
            let rs = info(resized)
            expect("resize keeps oriented TIFF pages upright", rs.frames == 2 && rs.width == 20 && rs.height == 30, "got \(rs)")
            expect("resized TIFF page 1 has blue at the top left", topLeft(resized) == "blue", "got \(topLeft(resized))")
            let rotatedTIFF = try Converter.perform(.tool(.rotate), on: tiff, progress: { _ in })[0]
            let rt = info(rotatedTIFF)
            expect("Rotate 90° keeps both TIFF pages", rt.frames == 2 && rt.width == 60 && rt.height == 40, "got \(rt)")

            // 16-bit greyscale stays 16-bit greyscale when rotated.
            let gray = dir.appendingPathComponent("gray16.png")
            try write([gray16()], to: gray, type: UTType.png.identifier, frame: [:], file: [:])
            let g = info(try Converter.perform(.tool(.rotate), on: gray, progress: { _ in })[0])
            expect("Rotate 90° keeps 16-bit grey", g.depth == 16 && g.model == "Gray" && g.width == 8 && g.height == 16, "got \(g)")

            // A 9 × 9 image still gets a frame at the default 5%.
            let tiny = dir.appendingPathComponent("tiny.png")
            try write([solid(9, 9)], to: tiny, type: UTType.png.identifier, frame: [:], file: [:])
            let t = info(try ImageExtras.frame(tiny, options: [:]))
            expect("frame on a 9 px image is at least 1 px", t.width == 11 && t.height == 11, "got \(t)")

            // Huge numbers are refused with a message, never a crash.
            let photo = dir.appendingPathComponent("photo.png")
            try write([solid(40, 30)], to: photo, type: UTType.png.identifier, frame: [:], file: [:])
            let huge: [(String, () throws -> Any)] = [
                ("resize width 1e20", { try ImageExtras.resize(photo, options: ["mode": "width", "value": "99999999999999999999"]) }),
                ("resize 1e19 %", { try ImageExtras.resize(photo, options: ["value": "1e19", "upscale": "true"]) }),
                ("frame 5e9 px", { try ImageExtras.frame(photo, options: ["width": "5000000000", "unit": "px"]) }),
                ("frame 1e300 %", { try ImageExtras.frame(photo, options: ["width": "1e300"]) }),
                ("collage width 1e19", { try ImageExtras.collage([photo, tiny], options: ["width": "1e19"], progress: { _ in }) }),
                ("collage spacing 1e300", { try ImageExtras.collage([photo, tiny], options: ["spacing": "1e300"], progress: { _ in }) }),
            ]
            for (what, body) in huge {
                let message = failure(body)
                expect("\(what) is refused", message != nil, "it succeeded")
            }
            expect("collage with 1e19 columns is one row",
                   failure { try ImageExtras.collage([photo, tiny], options: ["columns": "1e19", "width": "400"], progress: { _ in }) } == nil)

            // Collage names the file it can't decode.
            let broken = dir.appendingPathComponent("broken.png")
            var bytes = try Data(contentsOf: photo)
            bytes.replaceSubrange(60..<bytes.count, with: Data(repeating: 0, count: bytes.count - 60))
            try bytes.write(to: broken)
            let message = failure { try ImageExtras.collage([photo, broken], options: [:], progress: { _ in }) } ?? ""
            expect("collage error names broken.png", message.contains("broken.png"), "got “\(message)”")

            // SVG: any size is drawn fresh, enlarging included.
            let svg = dir.appendingPathComponent("icon.svg")
            try Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><circle cx="12" cy="12" r="10" fill="#08f"/></svg>"##.utf8)
                .write(to: svg)
            for width in [512, 48] {
                let out = try? ImageExtras.resize(svg, options: ["mode": "width", "value": "\(width)"])
                expect("resize SVG to \(width) px", out.map { info($0).width == width } ?? false, "got \(out.map { "\(info($0))" } ?? "an error")")
            }

            // A PDF that needs a password to open is refused by name instead of writing nothing.
            let locked = dir.appendingPathComponent("locked.pdf")
            var box = CGRect(x: 0, y: 0, width: 200, height: 200)
            if let ctx = CGContext(locked as CFURL, mediaBox: &box,
                                   [kCGPDFContextUserPassword: "user1", kCGPDFContextOwnerPassword: "owner1"] as CFDictionary) {
                ctx.beginPDFPage(nil); ctx.setFillColor(.black); ctx.fill(CGRect(x: 20, y: 20, width: 50, height: 50))
                ctx.endPDFPage(); ctx.closePDF()
            }
            let pdfMessage = failure { try Converter.renderPDF(locked, to: .png) } ?? ""
            expect("PNG of a locked PDF says it's password-protected", pdfMessage.contains("password-protected"), "got “\(pdfMessage)”")
        } catch {
            expect("fixtures and tools ran", false, error.localizedDescription)
        }
        return (failed == 0 ? "PASS" : "FAIL: \(failed) failed") + "\n" + lines.joined(separator: "\n")
    }

    // MARK: Fixtures

    private static func context(_ w: Int, _ h: Int, bits: Int = 8, gray: Bool = false) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: bits, bytesPerRow: 0,
                  space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// 60 × 40, transparent, with a red dot that moves each frame.
    private static func dotFrame(_ i: Int) -> CGImage {
        let ctx = context(60, 40)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 5 + i * 15, y: 10, width: 20, height: 20))
        return ctx.makeImage()!
    }

    /// 60 × 40 stored: red top left, green top right, blue bottom left, white bottom right.
    private static func quadrants() -> CGImage {
        let ctx = context(60, 40)
        let quads: [(CGFloat, CGFloat, CGFloat, CGRect)] = [
            (1, 0, 0, CGRect(x: 0, y: 20, width: 30, height: 20)), (0, 1, 0, CGRect(x: 30, y: 20, width: 30, height: 20)),
            (0, 0, 1, CGRect(x: 0, y: 0, width: 30, height: 20)), (1, 1, 1, CGRect(x: 30, y: 0, width: 30, height: 20)),
        ]
        for (r, g, b, rect) in quads { ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1)); ctx.fill(rect) }
        return ctx.makeImage()!
    }

    private static func gray16() -> CGImage {
        let ctx = context(16, 8, bits: 16, gray: true)
        ctx.setFillColor(gray: 0.25, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        ctx.setFillColor(gray: 0.75, alpha: 1); ctx.fill(CGRect(x: 8, y: 0, width: 8, height: 8))
        return ctx.makeImage()!
    }

    private static func solid(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private static func write(_ images: [CGImage], to url: URL, type: String, frame: [CFString: Any], file: [CFString: Any]) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, images.count, nil) else {
            throw ConversionError.toolFailed("Couldn’t write \(url.lastPathComponent).")
        }
        if !file.isEmpty { CGImageDestinationSetProperties(dest, file as CFDictionary) }
        for image in images { CGImageDestinationAddImage(dest, image, frame as CFDictionary) }
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.toolFailed("Couldn’t write \(url.lastPathComponent).") }
    }

    // MARK: Reading results

    struct Info: CustomStringConvertible {
        var type = "", frames = 0, width = 0, height = 0, depth = 0, model = "", delay = 0.0, loop = -1
        var description: String { "\(type) \(frames) frames \(width)×\(height) \(depth)-bit \(model) delay \(delay) loop \(loop)" }
    }

    /// Type, frame count, upright size of the first frame, depth, colour model, first delay and loop count.
    static func info(_ url: URL) -> Info {
        var i = Info()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return i }
        i.type = CGImageSourceGetType(src) as String? ?? ""
        i.frames = CGImageSourceGetCount(src)
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        i.width = p[kCGImagePropertyPixelWidth] as? Int ?? 0
        i.height = p[kCGImagePropertyPixelHeight] as? Int ?? 0
        if (p[kCGImagePropertyOrientation] as? Int ?? 1) >= 5 { swap(&i.width, &i.height) }
        i.depth = p[kCGImagePropertyDepth] as? Int ?? 0
        i.model = p[kCGImagePropertyColorModel] as? String ?? ""
        let gif = p[kCGImagePropertyGIFDictionary] as? [CFString: Any], png = p[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        i.delay = (gif?[kCGImagePropertyGIFDelayTime] ?? png?[kCGImagePropertyAPNGDelayTime]) as? Double ?? 0
        let file = CGImageSourceCopyProperties(src, nil) as? [CFString: Any] ?? [:]
        let fileGIF = file[kCGImagePropertyGIFDictionary] as? [CFString: Any], filePNG = file[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        i.loop = (fileGIF?[kCGImagePropertyGIFLoopCount] ?? filePNG?[kCGImagePropertyAPNGLoopCount]) as? Int ?? -1
        return i
    }

    /// The main colour of the first frame's top-left corner as shown (orientation applied).
    static func topLeft(_ url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = try? Converter.orientedImage(src) else { return "?" }
        let ctx = context(image.width, image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data?.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * image.height) else { return "?" }
        let o = 2 * 4 + 2 * ctx.bytesPerRow   // two pixels in from the top-left corner (row 0 is the top)
        let (r, g, b) = (data[o], data[o + 1], data[o + 2])
        switch (r > 128, g > 128, b > 128) {
        case (true, false, false): return "red"
        case (false, true, false): return "green"
        case (false, false, true): return "blue"
        case (true, true, true): return "white"
        default: return "(\(r),\(g),\(b))"
        }
    }
}
#endif
