#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import Compression
import ImageIO
import UniformTypeIdentifiers
import Vision

/// `--selftest image-crop-redact`: Crop, Redact, Add Background and BMP conversion on generated images in a
/// temporary folder, measured pixel by pixel (and with Vision for the redaction), plus the Crop and Redact
/// windows driven offscreen by synthesized mouse and key events.
enum CropRedactTests {
    typealias Pixels = ImageEditors.Pixels
    typealias Fixtures = ImageEditors.Fixtures

    final class Check {
        private var lines: [String] = []
        private(set) var failures = 0
        func check(_ ok: Bool, _ what: String) {
            lines.append((ok ? "  ok    " : "  FAIL  ") + what)
            if !ok { failures += 1 }
        }
        func throwsError(_ body: () throws -> Void, containing text: String, _ what: String) {
            do { try body(); check(false, "\(what): no error") }
            catch { check(error.localizedDescription.contains(text), "\(what): “\(error.localizedDescription)”") }
        }
        func note(_ text: String) { lines.append("  note  " + text) }
        var report: String {
            let n = lines.filter { !$0.hasPrefix("  note") }.count
            let head = failures == 0 ? "PASS image crop redact: \(n) checks" : "FAIL image crop redact: \(failures) of \(n) checks failed"
            return ([head] + lines).joined(separator: "\n")
        }
    }

    static func run() -> String {
        let t = Check()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-crop-redact-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let trace = ProcessInfo.processInfo.environment["DW_TRACE_TESTS"] != nil
            // DW_TEST_PARTS=review runs only the parts whose name contains it (Vision's first text request in a
            // fresh build can take many minutes on a busy Mac, and only some parts use it). Unset: every part.
            let only = ProcessInfo.processInfo.environment["DW_TEST_PARTS"] ?? ""
            for (name, part) in [("crop files", cropFiles), ("crop editor", cropEditor), ("redact pixels", redactPixels),
                                 ("redact metadata", redactMetadata), ("redact faces", redactFaces), ("redact editor", redactEditor),
                                 ("background", background), ("bmp", bmp), ("review: redact icc", redactICC),
                                 ("review: preview blocks", redactPreviewBlocks), ("review: redact keys", redactKeyboard),
                                 ("review: pages note", firstPictureNote), ("review: overlay look", overlayLook),
                                 ("review: background memory", backgroundMemory), ("verify: background limits", backgroundLimits)]
                as [(String, (Check, URL) throws -> Void)] where only.isEmpty || name.contains(only) {
                let start = Date()
                try part(t, dir)
                if trace { FileHandle.standardError.write("\(name): \(String(format: "%.1f", Date().timeIntervalSince(start))) s\n".data(using: .utf8)!) }
            }

        } catch {
            t.check(false, "unexpected error: \(error.localizedDescription)")
        }
        t.check(ocrFailures == 0, "Vision's text recognizer ran every time (\(ocrFailures) failures)")
        return t.report
    }

    // MARK: Fixtures

    /// Every pixel different: red follows x, green follows y, blue mixes both.
    static func gradient(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                p[i] = UInt8(x * 255 / max(1, width - 1)); p[i + 1] = UInt8(y * 255 / max(1, height - 1))
                p[i + 2] = UInt8((x * 7 + y * 13) % 256); p[i + 3] = 255
            }
        }
        return ctx.makeImage()!
    }

    static func bytes(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }

    /// Text lines drawn black on white; returns the image and each line's box (top-left origin, pixels).
    static func textImage(_ lines: [(String, CGFloat)], width: Int = 1100, height: Int = 420) -> (CGImage, [CGRect]) {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        var boxes: [CGRect] = []
        var top: CGFloat = 50
        for (text, size) in lines {
            let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .bold),
                                                                   .foregroundColor: NSColor.black])
            let sz = s.size()
            s.draw(at: CGPoint(x: 60, y: CGFloat(height) - top - sz.height))
            boxes.append(CGRect(x: 60, y: top, width: ceil(sz.width), height: ceil(sz.height)))
            top += sz.height + 60
        }
        NSGraphicsContext.restoreGraphicsState()
        return (ctx.makeImage()!, boxes)
    }

    /// Everything Vision's text recognizer reads, with boxes in pixels (top-left origin). A failure to run
    /// Vision at all is reported as such, never as "nothing readable".
    static var ocrFailures = 0
    static func ocr(_ image: CGImage) -> [(text: String, box: CGRect)] {
        do { return try ImageRedact.readText(image) }
        catch { ocrFailures += 1; return [("(Vision failed: \(error.localizedDescription))", .zero)] }
    }

    // MARK: Crop

    private static func cropFiles(_ t: Check, _ dir: URL) throws {
        let src = gradient(width: 400, height: 300)
        let url = try Fixtures.write(src, "grad.png", in: dir)
        let before = bytes(url)
        let sp = Pixels(src)

        let out = try ImageCrop.save(url, options: ["x": "50", "y": "40", "w": "200", "h": "100"])
        let o = Fixtures.image(out).map(Pixels.init)
        t.check(out.lastPathComponent == "grad cropped.png" && o?.width == 200 && o?.height == 100,
                "x=50 y=40 w=200 h=100 writes “grad cropped.png”, 200 × 100 (\(out.lastPathComponent), \(o?.width ?? 0) × \(o?.height ?? 0))")
        if let o, let expected = src.cropping(to: CGRect(x: 50, y: 40, width: 200, height: 100)) {
            let diff = o.maxDifference(Pixels(expected))
            t.check(diff == 0, "every cropped pixel matches the source at (x+50, y+40) exactly (max difference \(diff))")
        }

        // Quarter turns: the mapping of every pixel, not just the size.
        let crop = CGRect(x: 50, y: 40, width: 200, height: 100)
        let minX = Int(crop.minX), minY = Int(crop.minY), maxX = Int(crop.maxX), maxY = Int(crop.maxY)
        for degrees in [90, 180, 270] {
            let r = try ImageCrop.save(url, options: ["x": "50", "y": "40", "w": "200", "h": "100", "rotate": "\(degrees)"])
            guard let p = Fixtures.image(r).map(Pixels.init) else { t.check(false, "rotate=\(degrees) output readable"); continue }
            let (ew, eh) = degrees == 180 ? (200, 100) : (100, 200)
            var mismatches = 0
            for y in 0..<p.height {
                for x in 0..<p.width {
                    let s: (Int, Int)
                    switch degrees {
                    case 90: s = (minX + y, maxY - 1 - x)
                    case 180: s = (maxX - 1 - x, maxY - 1 - y)
                    default: s = (maxX - 1 - y, minY + x)
                    }
                    let a = p.at(x, y), b = sp.at(s.0, s.1)
                    if a.r != b.r || a.g != b.g || a.b != b.b { mismatches += 1 }
                }
            }
            t.check(p.width == ew && p.height == eh && mismatches == 0,
                    "rotate=\(degrees): \(p.width) × \(p.height) (expected \(ew) × \(eh)), every pixel turned clockwise (\(mismatches) off)")
        }

        let square = try ImageCrop.save(url, options: ["aspect": "1:1"])
        if let p = Fixtures.image(square).map(Pixels.init) {
            let a = p.at(0, 0), b = sp.at(50, 0)
            t.check(p.width == 300 && p.height == 300 && a.r == b.r && a.g == b.g,
                    "aspect=1:1 crops the centered 300 × 300 square (\(p.width) × \(p.height), starts at x=50)")
        }
        let wide = try ImageCrop.save(url, options: ["aspect": "16:9", "rotate": "90"])
        if let p = Fixtures.image(wide).map(Pixels.init) {
            let ratio = Double(p.width) / Double(p.height)
            t.check(abs(ratio - 16.0 / 9) < 0.02, "aspect=16:9 with rotate=90 gives a 16:9 result after turning (\(p.width) × \(p.height))")
        }

        // An EXIF-rotated JPEG: coordinates are upright, the result is upright, metadata stays.
        let jpeg = try Fixtures.rotatedJPEG(in: dir)
        let jOut = try ImageCrop.save(jpeg, options: ["x": "100", "y": "0", "w": "100", "h": "100"])
        let props = Fixtures.properties(jOut)
        let red = Fixtures.image(jOut).map { Pixels($0).stats(CGRect(x: 10, y: 10, width: 80, height: 80)) }
        t.check(jOut.pathExtension == "jpg" && props.width == 100 && props.height == 100 && props.orientation == 1,
                "an EXIF-rotated JPEG crops in upright pixels and comes out upright JPEG (\(jOut.lastPathComponent), \(props.width) × \(props.height), orientation \(props.orientation))")
        t.check((red?.r ?? 0) > 200 && (red?.g ?? 255) < 70, "the crop is the red block the viewer saw top-right (mean \(Int(red?.r ?? 0)),\(Int(red?.g ?? 0)),\(Int(red?.b ?? 0)))")
        t.check(props.make == "DropWheelCam" && props.hasGPS, "camera make and GPS are kept (make \(props.make ?? "none"))")

        if let dng = fixture("camera.dng") {
            let copy = dir.appendingPathComponent("camera.dng")
            try? FileManager.default.copyItem(at: dng, to: copy)
            let d = try ImageCrop.save(copy, options: ["w": "16", "h": "12", "rotate": "90"])
            let dp = Fixtures.properties(d)
            t.check(dp.width == 12 && dp.height == 16 && d.pathExtension != "dng",
                    "camera.dng (RAW) crops and turns: \(d.lastPathComponent), \(dp.width) × \(dp.height) (the editors’ writable fallback)")
        } else {
            t.note("camera.dng not found next to the binary; the RAW crop is covered by Tests/features.sh")
        }

        t.throwsError({ _ = try ImageCrop.save(url, options: [:]) }, containing: "Nothing to crop", "no box and no turn is refused")
        t.throwsError({ _ = try ImageCrop.save(url, options: ["rotate": "45"]) }, containing: "0, 90, 180 or 270", "rotate=45 is refused")
        t.throwsError({ _ = try ImageCrop.save(url, options: ["x": "5000", "w": "10"]) }, containing: "outside", "a box outside the image is refused")
        t.throwsError({ _ = try ImageCrop.save(url, options: ["w": "0"]) }, containing: "more than 0", "a zero width is refused")
        t.throwsError({ _ = try ImageCrop.save(url, options: ["aspect": "7:3"]) }, containing: "isn’t an aspect", "an unknown aspect is refused")
        t.throwsError({ _ = try ImageCrop.save(url, options: ["x": "ten"]) }, containing: "isn’t a number", "a word for x is refused")
        t.check(bytes(url) == before, "the source file is unchanged")
    }

    static func fixture(_ name: String) -> URL? {
        var dirs: [URL] = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            var d = exe.deletingLastPathComponent()
            for _ in 0..<5 { dirs.append(d); d = d.deletingLastPathComponent() }
        }
        for d in dirs {
            for sub in ["Tests/fixtures/features", "fixtures/features", "."] {
                let u = d.appendingPathComponent(sub).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: u.path) { return u }
            }
        }
        return nil
    }

    private static func cropEditor(_ t: Check, _ dir: URL) throws {
        let url = try Fixtures.write(ImageEditors.TestImages.scene(width: 1200, height: 800), "scene.png", in: dir)
        let editor = ImageEditors.CropEditorView(source: try ImageEditors.SourceImage(url), loadAsync: false)
        let window = Fixtures.offscreenWindow(editor)
        let canvas = editor.canvas
        func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 2.5) -> Bool { abs(a - b) <= tol }
        let full = CGRect(x: 0, y: 0, width: 1200, height: 800)
        t.check(canvas.state.rect == full && !canvas.hasChanges, "the crop starts as the whole picture, nothing to save")
        t.check(canvas.scale < 1 && canvas.scale > 0.3, "a 1200 px picture is shown fitted (\(String(format: "%.2f", canvas.scale)) pt per pixel)")

        // Bottom-right corner to the middle.
        let f = canvas.frameInView
        canvas.simulateDrag(from: CGPoint(x: f.maxX - 2, y: f.maxY - 2), to: CGPoint(x: f.midX, y: f.midY))
        let r = canvas.state.rect
        t.check(near(r.minX, 0) && near(r.minY, 0) && near(r.width, 600, 4) && near(r.height, 400, 4),
                "dragging the bottom-right handle to the middle crops to the top-left quarter (\(Int(r.width)) × \(Int(r.height)))")
        canvas.undo()
        t.check(canvas.state.rect == full, "undo puts the whole picture back")
        canvas.redo()
        t.check(near(canvas.state.rect.width, 600, 4), "redo crops again")

        // Move by dragging inside; a click outside without a drag changes nothing.
        let g = canvas.frameInView
        canvas.simulateDrag(from: CGPoint(x: g.midX, y: g.midY), to: CGPoint(x: g.midX + 100 * canvas.scale, y: g.midY + 50 * canvas.scale))
        let m = canvas.state.rect
        t.check(near(m.minX, 100, 3) && near(m.minY, 50, 3) && near(m.width, 600, 4), "dragging inside moves the frame (to \(Int(m.minX)), \(Int(m.minY)))")
        let beforeClick = canvas.state
        canvas.simulateDrag(from: canvas.toView(CGPoint(x: 1150, y: 750)), to: canvas.toView(CGPoint(x: 1150, y: 750)))
        t.check(canvas.state == beforeClick, "a click outside the frame changes nothing")
        // Dragging outside the frame draws a new one.
        canvas.simulateDrag(from: canvas.toView(CGPoint(x: 900, y: 600)), to: canvas.toView(CGPoint(x: 1100, y: 760)))
        let n = canvas.state.rect
        t.check(near(n.minX, 900, 3) && near(n.minY, 600, 3) && near(n.maxX, 1100, 3) && near(n.maxY, 760, 3),
                "dragging outside the frame draws a new one (\(Int(n.minX)),\(Int(n.minY))–\(Int(n.maxX)),\(Int(n.maxY)))")

        // Edge handle with Free: only that edge moves.
        canvas.reset()
        let e = canvas.frameInView
        canvas.simulateDrag(from: CGPoint(x: e.minX + 1, y: e.midY), to: CGPoint(x: e.minX + 300 * canvas.scale, y: e.midY + 40))
        let er = canvas.state.rect
        t.check(near(er.minX, 300, 3) && er.minY == 0 && er.maxX == 1200 && er.height == 800, "the left edge handle moves only the left edge (x \(Int(er.minX)))")

        // Aspect presets and turning.
        canvas.setAspect(.square)
        var s = canvas.plan.rect
        t.check(abs(s.width - s.height) <= 1 && s.height == 800 && full.contains(s), "1:1 makes the largest square that fits (\(Int(s.width)) × \(Int(s.height)))")
        let corner = canvas.frameInView
        canvas.simulateDrag(from: CGPoint(x: corner.maxX - 1, y: corner.maxY - 1), to: CGPoint(x: corner.maxX - 200, y: corner.maxY - 60))
        s = canvas.plan.rect
        t.check(abs(s.width - s.height) <= 1 && s.width < 800, "resizing keeps 1:1 (\(Int(s.width)) × \(Int(s.height)))")
        canvas.setAspect(.sixteenNine)
        canvas.rotate(by: 1)
        let out = canvas.plan.outputSize
        t.check(canvas.plan.turns == 1 && abs(out.width / out.height - 16.0 / 9) < 0.01,
                "Rotate Right turns a quarter and keeps 16:9 for the result (\(Int(out.width)) × \(Int(out.height)))")
        _ = editor.handleKey(Fixtures.key("l", keyCode: 37, flags: .command, window: window))
        t.check(canvas.plan.turns == 0, "⌘L turns back")
        _ = editor.handleKey(Fixtures.key("r", keyCode: 15, flags: .command, window: window))
        t.check(canvas.plan.turns == 1, "⌘R turns right")

        // Esc cancels a drag in progress, never the window.
        var closed = false
        editor.onFinish = { _ in closed = true }
        canvas.setPlan(ImageCrop.Plan(rect: CGRect(x: 300, y: 300, width: 400, height: 300), turns: 1))
        let held = canvas.state
        let h = canvas.frameInView
        canvas.simulateDrag(from: CGPoint(x: h.midX, y: h.midY), to: CGPoint(x: h.midX - 80, y: h.midY), finish: false)
        let moved = canvas.state != held
        _ = editor.handleKey(Fixtures.key("\u{1b}", keyCode: 53, window: window))
        t.check(moved && canvas.state == held && !canvas.isDragging && !closed, "Esc puts a frame being dragged back and keeps the window open")

        // Keys: arrows move the frame, ⌥ arrows resize it, ⌘Z undoes.
        canvas.reset()
        canvas.setPlan(ImageCrop.Plan(rect: CGRect(x: 200, y: 200, width: 400, height: 300), turns: 0))
        _ = editor.handleKey(Fixtures.key("\u{F703}", keyCode: 124, flags: .shift, window: window))
        let k = canvas.state.rect
        t.check(near(k.minX, 200 + 10 / canvas.scale, 1) && k.width == 400, "⇧→ moves the frame 10 points (\(String(format: "%.1f", k.minX - 200)) px)")
        _ = editor.handleKey(Fixtures.key("\u{F701}", keyCode: 125, flags: [.option, .shift], window: window))
        t.check(near(canvas.state.rect.height, 300 + 10 / canvas.scale, 1), "⌥⇧↓ makes it taller (\(Int(canvas.state.rect.height)) px)")
        _ = editor.handleKey(Fixtures.key("z", keyCode: 6, flags: .command, window: window))
        t.check(canvas.state.rect.height == 300, "⌘Z undoes the resize")

        // What the window saves is exactly what the command line does with the same options.
        let options = editor.saveOptions
        let plan = canvas.plan
        let saved = try ImageCrop.save(url, options: options)
        let sp = Fixtures.properties(saved)
        t.check(options["rotate"] == "0" && sp.width == Int(plan.outputSize.width) && sp.height == Int(plan.outputSize.height),
                "Save’s options (\(["x", "y", "w", "h", "rotate"].map { "\($0)=\(options[$0] ?? "")" }.joined(separator: " "))) give a \(sp.width) × \(sp.height) file, as the status bar says")
        // Return saves (handed to a stand-in for the job runner here).
        var handed: ToolOptions?
        editor.saveHandler = { handed = $0 }
        _ = editor.handleKey(Fixtures.key("\r", keyCode: 36, window: window))
        t.check(handed == options && closed, "Return saves with those options and closes the window")
        editor.tearDown()
        window.contentView = nil
    }

    // MARK: Redact

    private static func redactPixels(_ t: Check, _ dir: URL) throws {
        let (image, lines) = textImage([("SECRET 4417", 72), ("Keep this line", 60)])
        let url = try Fixtures.write(image, "notes.png", in: dir)
        let before = bytes(url)
        let read = ocr(image).map(\.text).joined(separator: " ")
        t.check(read.contains("SECRET") && read.contains("4417") && read.contains("Keep"), "Vision reads the test text before redaction (“\(read)”)")
        let secret = lines[0].insetBy(dx: -10, dy: -8)
        let box = "\(Int(secret.minX)),\(Int(secret.minY)),\(Int(secret.width)),\(Int(secret.height))"
        let src = Pixels(image)
        for style in ImageRedact.Style.allCases {
            let out = try ImageRedact.save(url, options: ["boxes": "\(box),\(style.rawValue)"])
            guard let result = Fixtures.image(out) else { t.check(false, "\(style.rawValue): output readable"); continue }
            let p = Pixels(result)
            let found = ocr(result)
            let text = found.map(\.text).joined(separator: " ")
            let inside = found.filter { secret.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
            t.check(!text.uppercased().contains("SECRET") && !text.contains("4417") && inside.isEmpty && text.contains("Keep"),
                    "\(style.title): Vision can’t read the redacted line any more, and still reads the rest (reads “\(text)”)")
            // Outside the box nothing changes (lossless PNG).
            let below = CGRect(x: 0, y: secret.maxY + 2, width: CGFloat(p.width), height: CGFloat(p.height) - secret.maxY - 2)
            var changed = 0
            for y in Int(below.minY)..<Int(below.maxY) { for x in 0..<p.width where p.at(x, y).r != src.at(x, y).r { changed += 1 } }
            t.check(changed == 0, "\(style.title): pixels outside the box are untouched (\(changed) changed)")
            let ink = p.darkCount(secret), originalInk = src.darkCount(secret)
            switch style {
            case .black:
                let s = p.stats(secret)
                t.check(s.luma < 0.5 && s.sd < 0.5, "Black: every pixel in the box is black (mean \(String(format: "%.2f", s.luma)))")
            case .blur:
                // No letter edges left: what remains is a smooth wash and faint noise.
                let lap = p.laplacian(secret), srcLap = src.laplacian(secret)
                t.check(lap < srcLap * 0.3, "Blur: the box has no sharp edges left (edge energy \(String(format: "%.1f", srcLap)) → \(String(format: "%.1f", lap)); dark pixels \(originalInk) → \(ink))")
            case .pixelate:
                // A true mosaic: every block one colour, blocks a quarter of the box's short side.
                let r = FrameEditing.integral(secret, in: CGRect(x: 0, y: 0, width: p.width, height: p.height))
                let block = ImageRedact.pixelateBlock(width: Int(r.width), height: Int(r.height))
                var mixed = 0, blocks = 0
                var by = Int(r.minY)
                while by < Int(r.maxY) {
                    var bx = Int(r.minX)
                    while bx < Int(r.maxX) {
                        let first = p.at(bx, by)
                        var uniform = true
                        for y in by..<min(by + block, Int(r.maxY)) { for x in bx..<min(bx + block, Int(r.maxX)) where p.at(x, y).r != first.r { uniform = false } }
                        if !uniform { mixed += 1 }
                        blocks += 1
                        bx += block
                    }
                    by += block
                }
                t.check(mixed == 0 && blocks >= 16, "Pixelate: the box is \(blocks) flat \(block) px blocks (\(mixed) not flat; dark pixels \(originalInk) → \(ink))")
            }
        }

        // find=text: every word goes.
        let all = try ImageRedact.save(url, options: ["find": "text", "style": "pixelate"])
        if let result = Fixtures.image(all) {
            let text = ocr(result).map(\.text).joined(separator: " ")
            t.check(!text.contains("SECRET") && !text.contains("4417") && !text.contains("Keep"), "find=text hides every word (Vision reads “\(text)”)")
        }
        // Block size: text-sized boxes get 4 blocks across their short side, faces up to 8.
        t.check(ImageRedact.pixelateBlock(width: 400, height: 80) == 20 && ImageRedact.pixelateBlock(width: 400, height: 400) == 50,
                "pixelate blocks: 4 per short side for an 80 px line (\(ImageRedact.pixelateBlock(width: 400, height: 80)) px), 8 for a 400 px face (\(ImageRedact.pixelateBlock(width: 400, height: 400)) px)")

        t.throwsError({ _ = try ImageRedact.save(url, options: ["boxes": "1,2,3"]) }, containing: "Couldn’t read the box", "a box with 3 numbers is refused")
        t.throwsError({ _ = try ImageRedact.save(url, options: ["boxes": "1,2,3,4,wave"]) }, containing: "isn’t a redaction style", "an unknown style is refused")
        t.throwsError({ _ = try ImageRedact.save(url, options: ["find": "cats"]) }, containing: "isn’t something to find", "find=cats is refused")
        t.throwsError({ _ = try ImageRedact.save(url, options: ["boxes": "5000,5000,10,10"]) }, containing: "outside", "boxes outside the picture are refused")
        t.throwsError({ _ = try ImageRedact.save(url, options: ["find": "faces"]) }, containing: "Found no faces", "find=faces on a page of text says no faces were found")
        let parsed = try ImageRedact.parseBoxes("10,20,30,40,blur; 5.6,7,8,9 ;", size: CGSize(width: 100, height: 100), defaultStyle: .pixelate)
        t.check(parsed == [ImageRedact.Box(rect: CGRect(x: 10, y: 20, width: 30, height: 40), style: .blur),
                           ImageRedact.Box(rect: CGRect(x: 6, y: 7, width: 8, height: 9), style: .pixelate)]
                && ImageRedact.format(parsed) == "10,20,30,40,blur;6,7,8,9,pixelate",
                "boxes= parses, rounds to whole pixels and round-trips (\(ImageRedact.format(parsed)))")
        t.check(bytes(url) == before, "the source file is unchanged")
    }

    /// A JPEG carrying everything that can leak: GPS, camera make, an EXIF comment, an XMP description, an
    /// embedded thumbnail, and EXIF orientation 6.
    private static func leakyJPEG(in dir: URL) throws -> URL {
        let plainURL = dir.appendingPathComponent("leaky-plain.jpg")
        let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 100, width: 100, height: 100))
        guard let dest = CGImageDestinationCreateWithURL(plainURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ConversionError.toolFailed("Couldn’t make the test JPEG.")
        }
        let meta = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(meta, "http://purl.org/dc/elements/1.1/" as CFString, "dc" as CFString, nil)
        CGImageMetadataSetValueWithPath(meta, nil, "dc:description" as CFString, "dropwheel-secret-xmp" as CFString)
        CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFMake, "DropWheelCam" as CFString)
        CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude, 48.85 as CFNumber)
        CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitudeRef, "N" as CFString)
        CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment,
                                                     "dropwheel-secret-comment" as CFString)
        CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 6 as CFNumber)
        CGImageDestinationAddImageAndMetadata(dest, ctx.makeImage()!, meta, [kCGImageDestinationEmbedThumbnail: true,
                                                                             kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.toolFailed("Couldn’t write the test JPEG.") }
        return plainURL
    }

    private static func leaks(_ url: URL) -> [String] {
        var found: [String] = []
        let data = bytes(url)
        for marker in ["DropWheelCam", "dropwheel-secret-xmp", "dropwheel-secret-comment"] where data.range(of: Data(marker.utf8)) != nil {
            found.append(marker)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return found + ["unreadable"] }
        if p[kCGImagePropertyGPSDictionary] != nil { found.append("GPS") }
        if let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any], tiff[kCGImagePropertyTIFFMake] != nil { found.append("camera make") }
        if let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any], exif[kCGImagePropertyExifUserComment] != nil { found.append("EXIF comment") }
        if p[kCGImagePropertyOrientation] != nil, (p[kCGImagePropertyOrientation] as? Int) != 1 { found.append("orientation") }
        if let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil), let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] {
            for tag in tags {
                if let prefix = CGImageMetadataTagCopyPrefix(tag) as String?, prefix == "dc" || prefix == "xmp" { found.append("XMP \(prefix)") }
            }
        }
        // An embedded thumbnail is a second, smaller JPEG (ImageIO hands back the picture itself when there's none).
        let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: false] as CFDictionary)
        let width = p[kCGImagePropertyPixelWidth] as? Int ?? 0, height = p[kCGImagePropertyPixelHeight] as? Int ?? 0
        let starts = zip(data, data.dropFirst()).filter { $0 == 0xFF && $1 == 0xD8 }.count
        if let thumb, max(thumb.width, thumb.height) < max(width, height) { found.append("thumbnail") }
        else if starts > 1 { found.append("thumbnail") }
        return found
    }

    private static func redactMetadata(_ t: Check, _ dir: URL) throws {
        let jpeg = try leakyJPEG(in: dir)
        let had = leaks(jpeg)
        t.check(["DropWheelCam", "dropwheel-secret-xmp", "dropwheel-secret-comment", "GPS", "camera make", "thumbnail"].allSatisfy(had.contains),
                "the test JPEG really carries GPS, make, an EXIF comment, XMP and a thumbnail (\(had.joined(separator: ", ")))")
        let out = try ImageRedact.save(jpeg, options: ["boxes": "10,10,60,60"])
        let left = leaks(out)
        let props = Fixtures.properties(out)
        t.check(left.isEmpty, "the redacted copy has no metadata left: no GPS, make, comment, XMP or thumbnail (found: \(left.isEmpty ? "none" : left.joined(separator: ", ")))")
        t.check(out.lastPathComponent == "leaky-plain redacted.jpg" && props.width == 200 && props.height == 400,
                "it stays a JPEG, upright with the orientation baked in (\(out.lastPathComponent), \(props.width) × \(props.height))")
    }

    private static func redactFaces(_ t: Check, _ dir: URL) throws {
        var card: CGImage?
        for avatar in RedactSample.avatarCandidates {
            let c = RedactSample.card(avatar: avatar)
            if (try? ImageRedact.findFaces(c).count) ?? 0 > 0 { card = c; break }
        }
        guard let card else { t.check(false, "Vision finds the sample’s face (no candidate avatar was detected)"); return }
        let url = try Fixtures.write(card, "card.png", in: dir)
        let faces = try ImageRedact.findFaces(card)
        t.check(faces.count == 1, "Find Faces finds the one face on the sample card (\(faces.count))")
        for style in [ImageRedact.Style.pixelate, .blur] {
            let out = try ImageRedact.save(url, options: ["find": "faces", "style": style.rawValue])
            guard let result = Fixtures.image(out) else { continue }
            let after = (try? ImageRedact.findFaces(result).count) ?? -1
            t.check(after == 0, "\(style.title): Vision finds no face in the redacted copy (\(after))")
        }
        let both = try ImageRedact.save(url, options: [:])
        if let result = Fixtures.image(both) {
            let text = ocr(result).map(\.text).joined(separator: " ")
            let faces = (try? ImageRedact.findFaces(result).count) ?? -1
            t.check(!text.contains("example.com") && !text.contains("555") && !text.contains("Alex") && faces == 0,
                    "no options = find both: no face and none of the card’s text is readable (reads “\(text)”)")
        }
    }

    private static func redactEditor(_ t: Check, _ dir: URL) throws {
        let (image, lines) = textImage([("SECRET 4417", 72), ("Keep this line", 60)])
        let url = try Fixtures.write(image, "editor notes.png", in: dir)
        let editor = ImageEditors.RedactEditorView(source: try ImageEditors.SourceImage(url), loadAsync: false)
        let window = Fixtures.offscreenWindow(editor)
        let canvas = editor.canvas
        canvas.simulateDrag(from: canvas.toView(CGPoint(x: 50, y: 40)), to: canvas.toView(CGPoint(x: 500, y: 150)))
        let b = canvas.boxes.first?.rect ?? .zero
        t.check(canvas.boxes.count == 1 && canvas.selection == [0] && abs(b.minX - 50) <= 2 && abs(b.maxX - 500) <= 2 && abs(b.maxY - 150) <= 2,
                "dragging draws a selected box where the mouse went (\(Int(b.minX)),\(Int(b.minY))–\(Int(b.maxX)),\(Int(b.maxY)))")
        canvas.setStyle(.blur)
        t.check(canvas.boxes[0].style == .blur && canvas.currentStyle == .blur, "choosing Blur restyles the selected box")
        canvas.renderPreviewNow()
        if let preview = canvas.previewImage {
            let k = CGFloat(preview.width) / 1100
            let inside = Pixels(preview).laplacian(CGRect(x: 60 * k, y: 50 * k, width: 400 * k, height: 90 * k))
            let k2 = CGFloat(image.width) / 1100
            let before = Pixels(image).laplacian(CGRect(x: 60 * k2, y: 50 * k2, width: 400 * k2, height: 90 * k2))
            t.check(inside < before * 0.3, "the preview shows the blur the file will get (edge energy \(String(format: "%.1f", before)) → \(String(format: "%.1f", inside)))")
        }
        // Handles resize the selected box.
        let handle = canvas.toView(CGPoint(x: 500, y: 150))
        canvas.simulateDrag(from: handle, to: canvas.toView(CGPoint(x: 700, y: 200)))
        t.check(abs(canvas.boxes[0].rect.maxX - 700) <= 2 && abs(canvas.boxes[0].rect.minX - 50) <= 2, "its corner handle resizes it")
        _ = editor.handleKey(Fixtures.key("\u{7f}", keyCode: 51, window: window))
        t.check(canvas.boxes.isEmpty, "⌫ removes the selected box")
        _ = editor.handleKey(Fixtures.key("z", keyCode: 6, flags: .command, window: window))
        t.check(canvas.boxes.count == 1, "⌘Z brings it back")
        _ = editor.handleKey(Fixtures.key("\u{7f}", keyCode: 51, window: window))   // nothing selected after undo
        t.check(canvas.boxes.count == 1, "⌫ with nothing selected does nothing")
        while canvas.canUndo { canvas.undo() }   // back to no boxes
        t.check(canvas.boxes.isEmpty, "undoing every step leaves no boxes")
        try editor.findNow(.text, style: .black)
        let found = canvas.boxes.count
        t.check(found >= 4 && canvas.selection.count == found, "Find Text suggests a box per word, all selected (\(found))")
        try editor.findNow(.text, style: .black)
        t.check(canvas.boxes.count == found, "finding again doesn’t add the same words twice")
        // Keep “Keep this line” visible: ⇧-click its words out of the selection, then delete the rest… the other way
        // round here: remove the suggestions on the second line.
        let second = lines[1]
        let keep = Set(canvas.boxes.indices.filter { canvas.boxes[$0].rect.midY > second.minY - 10 })
        canvas.select(keep)
        canvas.deleteSelection()
        t.check(canvas.boxes.count == found - keep.count && !keep.isEmpty, "suggestions you don’t want are removed (\(keep.count) on the second line)")
        _ = editor.handleKey(Fixtures.key("a", keyCode: 0, flags: .command, window: window))
        t.check(canvas.selection.count == canvas.boxes.count, "⌘A selects every box")
        canvas.select([])
        // Esc cancels a drag in progress, never the window.
        var closed = false
        editor.onFinish = { _ in closed = true }
        _ = editor.handleKey(Fixtures.key("\u{1b}", keyCode: 53, window: window))
        t.check(!closed, "Esc doesn’t close the window")

        let options = editor.saveOptions
        let out = try ImageRedact.save(url, options: options)
        if let result = Fixtures.image(out) {
            let text = ocr(result).map(\.text).joined(separator: " ")
            t.check(!text.contains("SECRET") && !text.contains("4417") && text.contains("Keep"),
                    "Save’s options (find=none, \(canvas.boxes.count) boxes) redact the first line and keep the second (reads “\(text)”)")
        }
        var handed: ToolOptions?
        editor.saveHandler = { handed = $0 }
        _ = editor.handleKey(Fixtures.key("s", keyCode: 1, flags: .command, window: window))
        t.check(handed == options && closed, "⌘S saves with those options and closes the window")
        editor.tearDown()
        window.contentView = nil
    }

    // MARK: Add Background

    private static func background(_ t: Check, _ dir: URL) throws {
        let alpha = try Fixtures.alphaPNG(in: dir)   // 300 × 200, an 80%-opaque orange ellipse on nothing
        let out = try ImageBackground.run(alpha, options: [:])
        if let p = Fixtures.image(out).map(Pixels.init) {
            let corner = p.at(2, 2), center = p.at(150, 100)
            t.check(out.lastPathComponent == "alpha background.png" && p.width == 300 && p.height == 200,
                    "defaults fill behind the see-through parts at the same size (\(out.lastPathComponent), \(p.width) × \(p.height))")
            t.check(corner.r == 255 && corner.g == 255 && corner.b == 255 && corner.a == 255,
                    "corners are opaque white (\(corner), alpha \(corner.a))")
            t.check(center.a == 255 && center.r > 240 && center.g > 140 && center.g < 190 && center.b > 40 && center.b < 70,
                    "the 80% orange now sits on white (\(center))")
        }
        if let image = Fixtures.image(out) { t.check(!ImageExtras.isTransparent(image), "no see-through pixel is left") }

        let jpeg = try Fixtures.write(Fixtures.solid(width: 400, height: 200, gray: 0.5), "gray.jpg", in: dir)
        let sq = try ImageBackground.run(jpeg, options: ["canvas": "square", "padding": "10", "color": "#FF0000"])
        if let p = Fixtures.image(sq).map(Pixels.init) {
            let c = p.at(3, 3), mid = p.at(240, 240)
            t.check(sq.pathExtension == "jpg" && p.width == 480 && p.height == 480,
                    "square with 10% padding: 400 × 200 + 40 px each side → \(p.width) × \(p.height) JPEG (\(sq.lastPathComponent))")
            t.check(c.r > 230 && c.g < 40 && c.b < 40 && abs(mid.r - 128) < 12 && abs(mid.g - 128) < 12,
                    "the corners are the chosen red (\(c)) and the picture sits in the middle (\(mid))")
        }
        for (canvas, w, h) in [("16:9", 356, 200), ("9:16", 300, 533), ("4:5", 300, 375)] {
            let r = try ImageBackground.run(alpha, options: ["canvas": canvas, "color": "#204060"])
            let props = Fixtures.properties(r)
            let p = Fixtures.image(r).map(Pixels.init)
            let corner = p?.at(1, 1)
            t.check(props.width == w && props.height == h && corner.map { abs($0.r - 0x20) < 3 && abs($0.g - 0x40) < 3 && abs($0.b - 0x60) < 3 } == true,
                    "canvas \(canvas): \(props.width) × \(props.height) (expected \(w) × \(h)), corner filled #204060 (\(corner.map { "\($0)" } ?? "?"))")
        }
        let clear = try ImageBackground.run(jpeg, options: ["canvas": "square", "color": "#00000000"])
        if let p = Fixtures.image(clear).map(Pixels.init) {
            t.check(clear.pathExtension == "png" && p.at(1, 1).a == 0 && p.at(200, 200).a == 255,
                    "a see-through colour leaves transparency, so a JPEG comes out PNG (\(clear.lastPathComponent), corner alpha \(p.at(1, 1).a))")
        }
        let gif = try Fixtures.animatedGIF(in: dir)
        let gOut = try ImageBackground.run(gif, options: ["canvas": "square", "color": "#FFFFFF"])
        let frames = CGImageSourceCreateWithURL(gOut as CFURL, nil).map(CGImageSourceGetCount) ?? 0
        t.check(gOut.pathExtension == "gif" && frames == 2 && Fixtures.properties(gOut).width == 60 && Fixtures.properties(gOut).height == 60,
                "an animated GIF keeps both frames on a 60 × 60 canvas (\(gOut.lastPathComponent), \(frames) frames)")

        t.throwsError({ _ = try ImageBackground.run(jpeg, options: [:]) }, containing: "no see-through pixels", "an opaque picture with nothing to do is refused")
        t.throwsError({ _ = try ImageBackground.run(alpha, options: ["padding": "99"]) }, containing: "0 to 45", "padding 99% is refused")
        t.throwsError({ _ = try ImageBackground.run(alpha, options: ["canvas": "oval"]) }, containing: "isn’t a canvas", "an unknown canvas is refused")
        t.throwsError({ _ = try ImageBackground.run(alpha, options: ["color": "teal"]) }, containing: "isn’t a color", "a colour name is refused")

        // Lifting the subject (macOS 14 and later): a person emoji on a busy background gets a blue one.
        if ImageBackground.canLift {
            let photo = try Fixtures.write(subjectPhoto(), "subject.jpg", in: dir)
            do {
                let lifted = try ImageBackground.run(photo, options: ["lift": "true", "color": "#0000FF"])
                if let p = Fixtures.image(lifted).map(Pixels.init) {
                    let corner = p.at(4, 4), face = p.stats(CGRect(x: 360, y: 260, width: 80, height: 80))
                    t.check(lifted.pathExtension == "jpg" && corner.b > 200 && corner.r < 50 && corner.g < 50 && face.b < 150,
                            "Lift subject first: the background becomes blue (\(corner)) and the subject stays (mean blue \(Int(face.b)))")
                }
            } catch {
                t.check(false, "Lift subject first works on a clear subject: \(error.localizedDescription)")
            }
        }
        // A macOS 13 Mac: no toggle, and lift=true says why.
        ImageBackground.liftOverride = false
        defer { ImageBackground.liftOverride = nil }
        let keys = ImageBackground.fields([:]).map { field -> String in
            switch field {
            case .text(let k, _, _, _), .number(let k, _, _, _), .choice(let k, _, _, _), .toggle(let k, _, _), .color(let k, _, _): return k
            }
        }
        t.check(keys == ["color", "canvas", "padding"], "without subject lifting the form has no toggle (\(keys.joined(separator: ", ")))")
        t.throwsError({ _ = try ImageBackground.run(alpha, options: ["lift": "true"]) }, containing: "needs macOS 14", "lift=true on macOS 13 is refused clearly")
        t.check((try? ImageBackground.run(alpha, options: ["lift": "false"])) != nil, "and filling still works there")
        ImageBackground.liftOverride = nil
        if ImageBackground.canLift {
            let keysNow = ImageBackground.fields([:]).count
            t.check(keysNow == 4, "on this Mac (macOS 14 or later) the form offers “Lift subject first” (\(keysNow) fields)")
        }
    }

    /// A person emoji on a noisy, colourful background: a clear subject for foreground masking.
    static func subjectPhoto() -> CGImage {
        let w = 800, h = 600
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [CGColor(srgbRed: 0.55, green: 0.75, blue: 0.45, alpha: 1),
                                       CGColor(srgbRed: 0.85, green: 0.80, blue: 0.55, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w, y: h), options: [])
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<400 {
            ctx.setFillColor(CGColor(srgbRed: .random(in: 0.4...0.9, using: &rng), green: .random(in: 0.5...0.9, using: &rng),
                                     blue: .random(in: 0.3...0.6, using: &rng), alpha: 0.5))
            ctx.fillEllipse(in: CGRect(x: .random(in: 0...800, using: &rng), y: .random(in: 0...600, using: &rng), width: 14, height: 14))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let emoji = NSAttributedString(string: "🧑🏽", attributes: [.font: NSFont(name: "Apple Color Emoji", size: 300) ?? NSFont.systemFont(ofSize: 300)])
        let size = emoji.size()
        emoji.draw(at: CGPoint(x: (CGFloat(w) - size.width) / 2, y: (CGFloat(h) - size.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    // MARK: BMP

    private static func bmp(_ t: Check, _ dir: URL) throws {
        let alpha = try Fixtures.alphaPNG(in: dir)
        let outs = try Converter.perform(.convert(.bmp), on: alpha) { _ in }
        if let out = outs.first, let image = Fixtures.image(out) {
            let p = Pixels(image)
            let corner = p.at(2, 2), center = p.at(150, 100)
            t.check(out.pathExtension == "bmp" && !ImageExtras.hasAlphaChannel(image) && image.width == 300,
                    "PNG with transparency → BMP without an alpha channel (\(out.lastPathComponent), \(image.bitsPerPixel) bits per pixel)")
            t.check(corner.r == 255 && corner.g == 255 && corner.b == 255 && center.r > 240 && center.g > 140 && center.g < 190,
                    "transparent areas are flattened onto white (corner \(corner), centre \(center))")
        }
        // A two-page TIFF: one BMP per page. An animated GIF: its first frame.
        let tiff = try Fixtures.write(Fixtures.solid(width: 40, height: 30, gray: 0.2), "pages.tiff", in: dir,
                                      frames: [Fixtures.solid(width: 40, height: 30, gray: 0.8)])
        let pages = try Converter.perform(.convert(.bmp), on: tiff) { _ in }
        let grays = pages.compactMap { Fixtures.image($0).map { Pixels($0).at(5, 5).r } }
        t.check(pages.map(\.lastPathComponent) == ["pages page 1.bmp", "pages page 2.bmp"] && grays.count == 2 && grays[0] < 80 && grays[1] > 180,
                "a two-page TIFF gives one BMP per page, in order (\(pages.map(\.lastPathComponent).joined(separator: ", ")))")
        let gif = try Fixtures.animatedGIF(in: dir)
        let first = try Converter.perform(.convert(.bmp), on: gif) { _ in }
        t.check(first.map(\.lastPathComponent) == ["anim first frame.bmp"], "an animated GIF gives its first frame (\(first.map(\.lastPathComponent).joined()))")
        t.check(OutputFormat.targets(for: .image, source: "png").contains(.bmp) && !OutputFormat.targets(for: .image, source: "dib").contains(.bmp)
                && !OutputFormat.targets(for: .image, source: "BMP").contains(.bmp),
                "BMP is offered for images, but not for a .bmp or .dib file")
    }

    // MARK: Review regressions

    /// An ICC profile carries free text (a calibrated display's or a camera's name): the redacted copy must not.
    /// A Display P3 profile whose description says "AlexSecret" (UTF-16, as Apple's mluc tags store it).
    private static func redactICC(_ t: Check, _ dir: URL) throws {
        var icc = CGColorSpace(name: CGColorSpace.displayP3)!.copyICCData()! as Data
        let secret = "AlexSecret".data(using: .utf16BigEndian)!
        if let r = icc.range(of: "Display P3".data(using: .utf16BigEndian)!) { icc.replaceSubrange(r, with: secret) }
        for i in 84..<100 { icc[i] = 0 }   // no profile ID, so nothing matches it to the system's own
        guard let space = CGColorSpace(iccData: icc as CFData) else { t.check(false, "the test profile is valid"); return }
        let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.3, blue: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let image = ctx.makeImage()!
        for (name, type) in [("profiled.jpg", UTType.jpeg), ("profiled.heic", UTType.heic), ("profiled.tiff", UTType.tiff)] {
            let url = try Fixtures.write(image, name, in: dir, type: type)
            t.check(bytes(url).range(of: secret) != nil, "\(name) carries the profile text before redaction")
            let out = try ImageRedact.save(url, options: ["boxes": "10,10,50,50"])
            let props = CGImageSourceCreateWithURL(out as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            let profile = props?[kCGImagePropertyProfileName] as? String ?? "none"
            let before = Fixtures.image(url).map { Pixels($0).at(200, 150) }, after = Fixtures.image(out).map { Pixels($0).at(200, 150) }
            let close = before.flatMap { b in after.map { a in abs(a.r - b.r) <= 6 && abs(a.g - b.g) <= 6 && abs(a.b - b.b) <= 6 } } ?? false
            t.check(bytes(out).range(of: secret) == nil && bytes(out).range(of: Data("AlexSecret".utf8)) == nil && profile != "AlexSecret" && close,
                    "\(name): the redacted copy has no trace of the profile’s text (profile now “\(profile)”) and the colours stay (\(before.map { "\($0)" } ?? "?") → \(after.map { "\($0)" } ?? "?"))")
        }
        // A standard profile is kept as it is.
        let srgb = try Fixtures.write(Fixtures.solid(width: 120, height: 80, gray: 0.5), "srgb.jpg", in: dir)
        let kept = try ImageRedact.save(srgb, options: ["boxes": "1,1,5,5"])
        let keptName = CGImageSourceCreateWithURL(kept as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }?[kCGImagePropertyProfileName] as? String
        t.check(keptName?.contains("sRGB") == true, "an sRGB picture stays sRGB (\(keptName ?? "no profile"))")
    }

    /// The window previews on a downscaled proxy; Blur and Pixelate must show as many blocks as the file gets.
    private static func redactPreviewBlocks(_ t: Check, _ dir: URL) throws {
        let url = try Fixtures.write(gradient(width: 4800, height: 3000), "big gradient.png", in: dir)
        let box = CGRect(x: 1200, y: 900, width: 600, height: 150)
        let fileBlock = ImageRedact.pixelateBlock(width: Int(box.width), height: Int(box.height))
        let editor = ImageEditors.RedactEditorView(source: try ImageEditors.SourceImage(url), loadAsync: false)
        let canvas = editor.canvas
        guard let proxy = canvas.image else { t.check(false, "the redact editor loads its proxy"); return }
        let k = CGFloat(proxy.width) / 4800
        canvas.addSuggested([box], style: .pixelate)
        canvas.renderPreviewNow()
        guard let preview = canvas.previewImage else { t.check(false, "the redact editor renders a preview"); return }
        // A block's height in the preview: the shortest run of identical rows down a few columns of the box.
        let p = Pixels(preview)
        let top = Int((box.minY * k).rounded()), bottom = Int((box.maxY * k).rounded())
        var run = Int.max
        for fx in [0.1, 0.3, 0.5, 0.7, 0.9] {
            let x = Int((box.minX + box.width * fx) * k)
            var length = 1
            for y in (top + 1)..<bottom {
                let a = p.at(x, y), b = p.at(x, y - 1)
                if a.r == b.r && a.g == b.g && a.b == b.b { length += 1 } else { run = min(run, length); length = 1 }
            }
        }
        let expected = CGFloat(fileBlock) * k
        t.check(abs(CGFloat(run) - expected) <= 1.5,
                "Pixelate on a \(proxy.width) px proxy shows the file’s blocks: \(run) px blocks in the preview, \(fileBlock) px in the file (× \(String(format: "%.2f", k)) = \(String(format: "%.1f", expected)))")
        t.check(ImageRedact.blurBlock(width: 300, height: 75, detail: 2) == ImageRedact.blurBlock(width: 600, height: 150) / 2
                || abs(Double(ImageRedact.blurBlock(width: 300, height: 75, detail: 2)) - Double(ImageRedact.blurBlock(width: 600, height: 150)) / 2) <= 1,
                "Blur’s grid scales the same way (\(ImageRedact.blurBlock(width: 300, height: 75, detail: 2)) px on the proxy, \(ImageRedact.blurBlock(width: 600, height: 150)) px in the file)")
        editor.tearDown()

        // Blur works one channel at a time (to keep its memory down): each channel must land in its own place.
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 200 / 255, green: 60 / 255, blue: 30 / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        ctx.clear(CGRect(x: 350, y: 0, width: 50, height: 300))   // a see-through strip down the right side
        let blurred = try ImageRedact.apply([ImageRedact.Box(rect: CGRect(x: 20, y: 20, width: 360, height: 200), style: .blur)],
                                            to: ctx.makeImage()!)
        let bp = Pixels(blurred), mean = bp.stats(CGRect(x: 40, y: 40, width: 210, height: 140))
        let strip = bp.at(370, 100), outside = bp.at(370, 260)
        t.check(abs(mean.r - 200) < 3 && abs(mean.g - 60) < 3 && abs(mean.b - 30) < 3 && strip.a == 255 && outside.a == 0,
                "Blur keeps a flat colour flat, channel by channel (mean rgb(\(Int(mean.r)),\(Int(mean.g)),\(Int(mean.b)))), makes the box opaque (alpha \(strip.a)) and leaves the rest see-through (alpha \(outside.a))")
    }

    /// Keyboard only: Add Box, ⌥ arrows resize, arrows move; what Save passes covers what the window showed.
    private static func redactKeyboard(_ t: Check, _ dir: URL) throws {
        let (image, _) = textImage([("SECRET 4417", 72)])
        let url = try Fixtures.write(image, "keys.png", in: dir)
        let editor = ImageEditors.RedactEditorView(source: try ImageEditors.SourceImage(url), loadAsync: false)
        let window = Fixtures.offscreenWindow(editor)
        let canvas = editor.canvas
        canvas.addBox()
        let added = canvas.boxes.first?.rect ?? .zero
        t.check(canvas.boxes.count == 1 && canvas.selection == [0] && abs(added.midX - 550) <= 1 && abs(added.midY - 210) <= 1
                && abs(added.width - 275) <= 1, "Add Box puts a selected box in the middle of the picture (\(added.integral))")
        _ = editor.handleKey(Fixtures.key("\u{F703}", keyCode: 124, flags: .option, window: window))
        let wider = canvas.boxes.first?.rect ?? .zero
        t.check(wider.minX == added.minX && wider.width > added.width, "⌥→ makes it wider (\(Int(added.width)) → \(String(format: "%.1f", wider.width)) px)")
        _ = editor.handleKey(Fixtures.key("\u{F703}", keyCode: 124, window: window))
        let moved = canvas.boxes.first?.rect ?? .zero
        t.check(moved.minX > wider.minX && abs(moved.width - wider.width) < 0.01, "→ moves it (x \(String(format: "%.2f", moved.minX)))")
        let saved = try ImageRedact.parseBoxes(editor.saveOptions["boxes"] ?? "", size: CGSize(width: 1100, height: 420), defaultStyle: .black)
        t.check(saved.count == 1 && saved[0].rect.contains(moved),
                "Save’s box (\(saved.first.map { "\($0.rect)" } ?? "none")) covers the box shown (\(String(format: "%.2f…%.2f", moved.minX, moved.maxX)))")
        _ = editor.handleKey(Fixtures.key("z", keyCode: 6, flags: .command, window: window))
        _ = editor.handleKey(Fixtures.key("z", keyCode: 6, flags: .command, window: window))
        t.check(canvas.boxes.first?.rect == added, "⌘Z twice undoes the move and the resize")

        // A slow search (Vision's first request in a process took 37 s to over 10 minutes on this Mac): Save waits
        // for it, and Esc stops waiting, after which Save works and the late answer is dropped.
        let gate = DispatchSemaphore(value: 0)
        editor.finder = { _, _ in gate.wait(); return [CGRect(x: 10, y: 10, width: 50, height: 20)] }
        var handed: ToolOptions?
        editor.saveHandler = { handed = $0 }
        editor.find(.text)
        _ = editor.handleKey(Fixtures.key("s", keyCode: 1, flags: .command, window: window))
        let waiting = editor.isFinding && handed == nil
        _ = editor.handleKey(Fixtures.key("\u{1b}", keyCode: 53, window: window))
        let stopped = !editor.isFinding
        gate.signal()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        t.check(waiting && stopped && canvas.boxes.count == 1,
                "Esc stops a slow Find Text (searching \(waiting), stopped \(stopped)); its late answer is dropped (\(canvas.boxes.count) box)")
        _ = editor.handleKey(Fixtures.key("s", keyCode: 1, flags: .command, window: window))
        t.check(handed != nil, "after which ⌘S saves")
        editor.tearDown()
        window.contentView = nil
    }

    /// A small GIF can claim hundreds of big frames; Add Background holds every result frame until it writes
    /// the file, so it must refuse what can't fit before decoding (and still take an ordinary animation).
    private static func backgroundMemory(_ t: Check, _ dir: URL) throws {
        let frame = Fixtures.solid(width: 2000, height: 2000, gray: 0.5)
        let bomb = try Fixtures.write(frame, "huge frames.gif", in: dir, frames: Array(repeating: frame, count: 119))
        let size = (try? Data(contentsOf: bomb).count) ?? 0
        let start = Date()
        t.throwsError({ _ = try ImageBackground.run(bomb, options: ["canvas": "square", "padding": "10"]) },
                      containing: "megapixels in all", "a \(size / 1024) KB GIF of 120 frames of 2000 × 2000 is refused (it would be 691 megapixels, the limit is 400)")
        t.check(Date().timeIntervalSince(start) < 2, "and refused before decoding (\(String(format: "%.2f", Date().timeIntervalSince(start))) s)")
        let gif = try Fixtures.animatedGIF(in: dir)
        t.check((try? ImageBackground.run(gif, options: ["canvas": "square"])) != nil, "an ordinary animation still gets its background")
    }

    /// Add Background takes the result's size from the file's header and refuses before decoding (a PNG of a
    /// few megabytes claiming 60,000 × 60,000 pixels took 7.2 GB when it was decoded first); an icon on a canvas
    /// icons can't have comes out as PNG, as the editors do, instead of failing; and a write that fails (the
    /// icon attempt before that PNG) leaves no hidden ImageIO temporary file in the folder.
    private static func backgroundLimits(_ t: Check, _ dir: URL) throws {
        let folder = dir.appendingPathComponent("limits", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let huge = try zeroPNG(width: 16200, height: 16200, in: folder)
        let kb = bytes(huge).count / 1024
        let start = Date()
        t.throwsError({ _ = try ImageBackground.run(huge, options: ["padding": "10"]) },
                      containing: "with the background it would be 19440 × 19440",
                      "a \(kb) KB PNG of 16200 × 16200 pixels (262 megapixels) is refused from its header")
        let seconds = Date().timeIntervalSince(start)
        t.check(seconds < 1, "and before anything is decoded (\(String(format: "%.2f", seconds)) s)")

        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 4, y: 4, width: 56, height: 56))
        let ico = try Fixtures.write(ctx.makeImage()!, "app.ico", in: folder)
        let same = try? ImageBackground.run(ico, options: [:])
        t.check(same?.pathExtension == "ico", "an icon that stays 64 × 64 stays an icon (\(same?.lastPathComponent ?? "failed"))")
        var wide: URL?
        do { wide = try ImageBackground.run(ico, options: ["canvas": "16:9"]) } catch {
            t.check(false, "an icon on a 16:9 canvas gets its background: “\(error.localizedDescription)”")
        }
        let wideSize = wide.flatMap { Fixtures.image($0) }.map { "\($0.width) × \($0.height)" } ?? "none"
        if let wide {
            t.check(wide.pathExtension == "png" && wideSize == "114 × 64",
                    "an icon on a 16:9 canvas comes out as PNG, since icons can't be that shape (\(wide.lastPathComponent), \(wideSize))")
        }
        let cropped = try ImageCrop.save(ico, options: ["w": "33", "h": "20"])
        t.check(cropped.pathExtension == "png", "a crop to a size icons can't have is saved as PNG (\(cropped.lastPathComponent))")
        let hidden = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(".") }
        t.check(hidden.isEmpty, "no failed write leaves ImageIO's hidden temporary file in the folder (\(hidden.isEmpty ? "none" : hidden.joined(separator: ", ")))")
    }

    /// A black grey-scale PNG of `width` × `height` pixels, compressed as it is written (zlib streams all-zero
    /// rows about 1,000 to 1): a few hundred kilobytes that decode to width × height bytes or more.
    static func zeroPNG(width: Int, height: Int, in dir: URL) throws -> URL {
        var table = [UInt32](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[n] = c
        }
        func crc(_ data: Data) -> UInt32 { ~data.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) } }
        func be(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
        func chunk(_ type: String, _ body: Data) -> Data {
            let typed = Data(type.utf8) + body
            return be(UInt32(body.count)) + typed + be(crc(typed))
        }
        // Every row is a filter byte and one byte per pixel, all zero: raw DEFLATE from the Compression
        // framework, between a zlib header and the Adler-32 of n zero bytes (a = 1, b = n mod 65521).
        let total = (width + 1) * height
        var deflated = Data()
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ConversionError.toolFailed("Couldn’t start the test PNG’s compressor.")
        }
        defer { compression_stream_destroy(stream) }
        let zeros = [UInt8](repeating: 0, count: 1 << 20), outSize = 1 << 16
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outSize)
        defer { buffer.deallocate() }
        var remaining = total, status = COMPRESSION_STATUS_OK
        zeros.withUnsafeBufferPointer { z in
            while status == COMPRESSION_STATUS_OK {
                if stream.pointee.src_size == 0 && remaining > 0 {
                    let n = min(remaining, z.count)
                    stream.pointee.src_ptr = z.baseAddress!
                    stream.pointee.src_size = n
                    remaining -= n
                }
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = outSize
                status = compression_stream_process(stream, remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                deflated.append(buffer, count: outSize - stream.pointee.dst_size)
            }
        }
        guard status == COMPRESSION_STATUS_END else { throw ConversionError.toolFailed("Couldn’t compress the test PNG.") }
        let idat = Data([0x78, 0x5E]) + deflated + be(UInt32(total % 65521) << 16 | 1)
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png += chunk("IHDR", be(UInt32(width)) + be(UInt32(height)) + Data([8, 0, 0, 0, 0]))
        png += chunk("IDAT", idat)
        png += chunk("IEND", Data())
        let url = dir.appendingPathComponent("black \(width) x \(height).png")
        try png.write(to: url)
        return url
    }

    /// A two-page TIFF: the Crop and Redact windows say only page 1 is kept, as PNG.
    private static func firstPictureNote(_ t: Check, _ dir: URL) throws {
        let tiff = try Fixtures.write(Fixtures.solid(width: 80, height: 60, gray: 0.3), "two pages.tiff", in: dir,
                                      frames: [Fixtures.solid(width: 80, height: 60, gray: 0.7)])
        let crop = ImageEditors.CropEditorView(source: try ImageEditors.SourceImage(tiff), loadAsync: false)
        let redact = ImageEditors.RedactEditorView(source: try ImageEditors.SourceImage(tiff), loadAsync: false)
        let c = crop.statusBar.trailing.stringValue, r = redact.statusBar.trailing.stringValue
        t.check(c.contains("page 1 of 2 only") && c.contains("PNG") && r.contains("page 1 of 2 only"),
                "a two-page TIFF says so in both windows (Crop: “\(c)”; Redact: “\(r)”)")
        let out = try ImageCrop.save(tiff, options: ["w": "40"])
        t.check(out.pathExtension == "png", "and the crop is indeed page 1 as PNG (\(out.lastPathComponent))")
        let single = ImageEditors.CropEditorView(source: try ImageEditors.SourceImage(try Fixtures.write(Fixtures.solid(width: 80, height: 60, gray: 0.3), "one.png", in: dir)), loadAsync: false)
        t.check(!single.statusBar.trailing.stringValue.contains("only"), "a single picture says nothing of pages")
        crop.tearDown(); redact.tearDown(); single.tearDown()
    }

    /// The frame editors use the video editors' marks: the app accent for the selected redaction box (not the
    /// system blue), and crop grips drawn inside the frame, so they stay on the picture.
    private static func overlayLook(_ t: Check, _ dir: URL) throws {
        func render(_ view: NSView) -> (Pixels, CGFloat)? {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let image = rep.cgImage else { return nil }
            return (Pixels(image), CGFloat(image.width) / view.bounds.width)
        }
        var accent = (r: 0, g: 0, b: 0)
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            let c = FrameEditing.accent.usingColorSpace(.sRGB) ?? .black
            accent = (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        }
        let dahlia = DWPalette.accent.usingColorSpace(.sRGB)!
        t.check(abs(accent.r - Int(dahlia.redComponent * 255)) <= 2 && abs(accent.g - Int(dahlia.greenComponent * 255)) <= 2,
                "the frame editors’ selection colour is the app accent, dahlia (rgb(\(accent.r),\(accent.g),\(accent.b)))")

        let url = try Fixtures.write(ImageEditors.TestImages.scene(width: 1200, height: 800), "look.png", in: dir)
        let redact = ImageEditors.RedactEditorView(source: try ImageEditors.SourceImage(url), loadAsync: false)
        let window = Fixtures.offscreenWindow(redact)
        window.appearance = NSAppearance(named: .aqua)
        redact.layoutSubtreeIfNeeded()
        let rc = redact.canvas
        rc.addSuggested([CGRect(x: 300, y: 200, width: 400, height: 300)], style: .black)
        rc.renderPreviewNow()
        if let (p, s) = render(rc) {
            let r = rc.toView(rc.boxes[0].rect).integral
            var hits = 0
            var seen: [String] = []
            for dx in -4...4 {
                let q = p.at(Int((r.minX + CGFloat(dx)) * s), Int((r.minY + r.height * 0.25) * s))   // between the knobs
                seen.append("\(q)")
                if abs(q.r - accent.r) <= 20 && abs(q.g - accent.g) <= 20 && abs(q.b - accent.b) <= 20 { hits += 1 }
            }
            let knob = p.at(Int(r.minX * s), Int(r.minY * s))
            t.check(hits > 0, "the selected redaction box is outlined in the app accent (\(hits) accent pixels across its edge: \(seen.joined(separator: " ")))")
            t.check(knob.r > 235 && knob.g > 235 && knob.b > 235, "with a white knob on its corner (\(knob))")
        } else { t.check(false, "the redact canvas renders offscreen") }
        redact.tearDown()
        window.contentView = nil

        let crop = ImageEditors.CropEditorView(source: try ImageEditors.SourceImage(url), loadAsync: false)
        let cropWindow = Fixtures.offscreenWindow(crop)
        cropWindow.appearance = NSAppearance(named: .aqua)
        crop.layoutSubtreeIfNeeded()
        let cc = crop.canvas
        if let (p, s) = render(cc) {
            let f = cc.frameInView.integral
            // The whole picture: a grip just inside the top-left corner is white; just outside it is the canvas.
            let inside = p.at(Int((f.minX + 2) * s), Int((f.minY + 12) * s))
            let outside = p.at(Int((f.minX - 3) * s), Int((f.minY + 12) * s))
            t.check(inside.r > 235 && inside.g > 235 && inside.b > 235 && outside.r < 235,
                    "crop grips sit inside the frame, on the picture (inside \(inside), outside \(outside))")
        } else { t.check(false, "the crop canvas renders offscreen") }
        crop.tearDown()
        cropWindow.contentView = nil

        // Annotate's selected mark uses the same accent (its dashed outline, drawn 5 pt outside the mark).
        let annotate = ImageEditors.AnnotateEditorView(source: try ImageEditors.SourceImage(url), loadAsync: false)
        let annotateWindow = Fixtures.offscreenWindow(annotate)
        annotateWindow.appearance = NSAppearance(named: .aqua)
        annotate.layoutSubtreeIfNeeded()
        let ac = annotate.canvas
        ac.setAnnotations([ImageEditors.Annotation(kind: .rect, points: [CGPoint(x: 300, y: 200), CGPoint(x: 700, y: 500)],
                                                   color: ImageEditors.RGBA(r: 0, g: 0, b: 0), width: 6)])
        ac.select(0)
        if let (p, s) = render(ac) {
            let mark = ac.toView(CGRect(x: 300, y: 200, width: 400, height: 300))
            var hits = 0
            for dx in -9...(-2) {
                for dy in [0.3, 0.4, 0.6] as [CGFloat] {
                    let q = p.at(Int((mark.minX + CGFloat(dx)) * s), Int((mark.minY + mark.height * dy) * s))
                    if abs(q.r - accent.r) <= 24 && abs(q.g - accent.g) <= 24 && abs(q.b - accent.b) <= 24 { hits += 1 }
                }
            }
            t.check(hits > 0, "Annotate outlines the selected mark in the same accent (\(hits) accent pixels beside it)")
        } else { t.check(false, "the annotate canvas renders offscreen") }
        annotate.tearDown()
        annotateWindow.contentView = nil
    }
}
#endif
