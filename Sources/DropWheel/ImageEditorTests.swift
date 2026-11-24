#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

extension ImageEditors {
    /// `--selftest image-editors` (or `adjust`, `annotate`): headless checks of the pipelines, the saved files and
    /// the editors' mouse and key handling, on generated images in a temporary folder. Nothing is shown on screen.
    enum EditorTests {
        static func run(adjust: Bool, annotate: Bool) -> String {
            let t = Checker()
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-editor-tests-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                if adjust {
                    adjustDirections(t)
                    try adjustOptions(t)
                    try adjustFiles(t, dir)
                    try adjustEditor(t, dir)
                }
                if annotate {
                    try annotationParsing(t)
                    try annotationPixels(t, dir)
                    try annotationFiles(t, dir)
                    try annotateEditor(t, dir)
                }
            } catch {
                t.check(false, "unexpected error: \(error.localizedDescription)")
            }
            return t.report
        }

        // MARK: Adjust

        /// Every slider moves the pixels the way its name says, on a photo-like scene.
        private static func adjustDirections(_ t: Checker) {
            let scene = TestImages.scene(width: 1200, height: 800)
            let base = Pixels(scene)
            func run(_ options: ToolOptions) -> Pixels? {
                guard let values = try? Adjustments(options: options),
                      let out = try? ImageEditors.render(values.apply(to: CIImage(cgImage: scene), fullLongSide: 1200), like: scene)
                else { return nil }
                return Pixels(out)
            }
            let all = CGRect(x: 0, y: 0, width: 1200, height: 800)
            let sky = CGRect(x: 0, y: 250, width: 800, height: 120)       // bright, near the horizon
            let ground = CGRect(x: 0, y: 760, width: 1200, height: 40)    // darkest
            let patches = CGRect(x: 40, y: 600, width: 720, height: 150)  // edges, for sharpness
            let b = base.stats(all)

            guard let neutral = run([:]) else { t.check(false, "neutral render"); return }
            t.check(neutral.maxDifference(base) <= 1, "neutral values leave every pixel alone (max diff \(neutral.maxDifference(base)))")

            func compare(_ options: ToolOptions, _ label: String, _ test: (Pixels.Stats, Pixels) -> (Bool, String)) {
                guard let out = run(options) else { t.check(false, "\(label): render failed"); return }
                let (ok, detail) = test(out.stats(all), out)
                t.check(ok, "\(label) (\(detail))")
            }
            compare(["exposure": "1"], "exposure +1 brightens") { s, _ in (s.luma > b.luma + 15, "mean \(f(b.luma)) → \(f(s.luma))") }
            compare(["exposure": "-1"], "exposure −1 darkens") { s, _ in (s.luma < b.luma - 15, "mean \(f(b.luma)) → \(f(s.luma))") }
            compare(["contrast": "60"], "contrast +60 spreads tones") { s, _ in
                (s.sd > b.sd + 4 && abs(s.luma - b.luma) < 8, "sd \(f(b.sd)) → \(f(s.sd)), mean \(f(b.luma)) → \(f(s.luma))") }
            compare(["contrast": "-60"], "contrast −60 flattens tones") { s, _ in (s.sd < b.sd - 4, "sd \(f(b.sd)) → \(f(s.sd))") }
            compare(["brightness": "50"], "brightness +50 lifts midtones") { s, _ in (s.luma > b.luma + 8, "mean \(f(b.luma)) → \(f(s.luma))") }
            compare(["brightness": "-50"], "brightness −50 lowers midtones") { s, _ in (s.luma < b.luma - 8, "mean \(f(b.luma)) → \(f(s.luma))") }
            let bSky = base.stats(sky).luma, bGround = base.stats(ground).luma
            compare(["highlights": "-80"], "highlights −80 recovers bright areas") { _, p in
                let v = p.stats(sky).luma; return (v < bSky - 4, "sky \(f(bSky)) → \(f(v))") }
            compare(["highlights": "80"], "highlights +80 brightens bright areas") { _, p in
                let v = p.stats(sky).luma; return (v > bSky + 3, "sky \(f(bSky)) → \(f(v))") }
            compare(["shadows": "80"], "shadows +80 opens dark areas") { _, p in
                let v = p.stats(ground).luma; return (v > bGround + 6, "ground \(f(bGround)) → \(f(v))") }
            compare(["shadows": "-80"], "shadows −80 deepens dark areas") { _, p in
                let v = p.stats(ground).luma; return (v < bGround - 2, "ground \(f(bGround)) → \(f(v))") }
            compare(["warmth": "60"], "warmth +60 warms (red up against blue)") { s, _ in
                (s.r - s.b > b.r - b.b + 8, "R−B \(f(b.r - b.b)) → \(f(s.r - s.b))") }
            compare(["temperature": "-60"], "warmth −60 (as temperature) cools") { s, _ in
                (s.r - s.b < b.r - b.b - 8, "R−B \(f(b.r - b.b)) → \(f(s.r - s.b))") }
            let bTint = b.g - (b.r + b.b) / 2
            compare(["tint": "60"], "tint +60 leans magenta") { s, _ in
                let v = s.g - (s.r + s.b) / 2; return (v < bTint - 4, "G−avg(R,B) \(f(bTint)) → \(f(v))") }
            compare(["tint": "-60"], "tint −60 leans green") { s, _ in
                let v = s.g - (s.r + s.b) / 2; return (v > bTint + 4, "G−avg(R,B) \(f(bTint)) → \(f(v))") }
            compare(["saturation": "-100"], "saturation −100 removes color") { s, _ in (s.chroma < 3, "chroma \(f(b.chroma)) → \(f(s.chroma))") }
            compare(["saturation": "60"], "saturation +60 adds color") { s, _ in (s.chroma > b.chroma + 8, "chroma \(f(b.chroma)) → \(f(s.chroma))") }
            compare(["vibrance": "80"], "vibrance +80 adds color") { s, _ in (s.chroma > b.chroma + 4, "chroma \(f(b.chroma)) → \(f(s.chroma))") }
            compare(["vibrance": "-80"], "vibrance −80 mutes color") { s, _ in (s.chroma < b.chroma - 4, "chroma \(f(b.chroma)) → \(f(s.chroma))") }
            let bEdges = base.laplacian(patches)
            compare(["sharpness": "80"], "sharpness 80 adds edge contrast") { _, p in
                let v = p.laplacian(patches); return (v > bEdges * 1.15, "edge energy \(f(bEdges)) → \(f(v))") }
        }

        private static func adjustOptions(_ t: Checker) throws {
            let a = try Adjustments(options: ["exposure": "9", "contrast": "-500", "temperature": "25", "tint": "−10", "quality": "0.5"])
            t.check(a[.exposure] == 3 && a[.contrast] == -100, "out-of-range values are clamped (\(a.description))")
            t.check(a[.warmth] == 25 && a[.tint] == -10, "aliases and the minus sign are understood (\(a.description))")
            t.check(Adjustments.Key.exposure.format(0.5) == "+0.50" && Adjustments.Key.contrast.format(-20) == "−20",
                    "values display as +0.50 and −20")
            t.throwsError({ _ = try Adjustments(options: ["exposure": "bright"]) }, containing: "must be a number", "a word for exposure is refused")
            t.check(try Adjustments(options: ["exposure": "0", "contrast": " "]).isNeutral, "zero and blank values are neutral")
        }

        /// Saved files: name, format, metadata, orientation, alpha, 16-bit depth, animated sources, refusals.
        private static func adjustFiles(_ t: Checker, _ dir: URL) throws {
            // A JPEG stored sideways (EXIF orientation 6) with camera metadata.
            let jpeg = try Fixtures.rotatedJPEG(in: dir)
            let out = try Adjustments.save(jpeg, options: ["exposure": "0.3"])
            t.check(out.lastPathComponent == "sideways adjusted.jpg", "writes “<name> adjusted.jpg” (\(out.lastPathComponent))")
            let props = Fixtures.properties(out)
            t.check(props.width == 200 && props.height == 400 && props.orientation == 1,
                    "EXIF-rotated source comes out upright \(props.width)×\(props.height), orientation \(props.orientation)")
            t.check(props.make == "DropWheelCam" && props.hasGPS, "camera make and GPS are kept (make \(props.make ?? "none"))")
            if let image = Fixtures.image(out) {
                let p = Pixels(image)
                let red = p.at(150, 50), blue = p.at(50, 350)
                t.check(red.r > 200 && red.g < 90 && blue.b > 200 && blue.r < 90,
                        "the marker blocks land where the viewer saw them (top-right \(red), bottom-left \(blue))")
            }
            let again = try Adjustments.save(jpeg, options: ["exposure": "0.3"])
            t.check(again.lastPathComponent == "sideways adjusted 2.jpg", "a second save doesn’t overwrite the first (\(again.lastPathComponent))")

            let alpha = try Fixtures.alphaPNG(in: dir)
            let alphaOut = try Adjustments.save(alpha, options: ["saturation": "40"])
            if let image = Fixtures.image(alphaOut) {
                let p = Pixels(image)
                t.check(ImageEditors.hasAlpha(image) && p.at(2, 2).a == 0 && p.at(150, 100).a > 100,
                        "transparency survives (corner alpha \(p.at(2, 2).a), center alpha \(p.at(150, 100).a))")
            }
            let deep = try Fixtures.deepPNG(in: dir)
            let deepOut = try Adjustments.save(deep, options: ["contrast": "20"])
            t.check(Fixtures.image(deepOut)?.bitsPerComponent == 16, "16-bit PNG stays 16-bit")

            let gif = try Fixtures.animatedGIF(in: dir)
            let gifOut = try Adjustments.save(gif, options: ["brightness": "20"])
            t.check(gifOut.pathExtension == "png", "an animated GIF is saved as a PNG still (\(gifOut.lastPathComponent))")

            t.throwsError({ _ = try Adjustments.save(jpeg, options: [:]) }, containing: "nothing to save", "all-neutral options are refused")
            let empty = dir.appendingPathComponent("empty.png")
            try Data().write(to: empty)
            t.throwsError({ _ = try Adjustments.save(empty, options: ["exposure": "1"]) }, containing: "Couldn’t read", "an empty file is refused")
        }

        /// The Adjust window offscreen: values drive the preview, M holds the original, Reset clears.
        private static func adjustEditor(_ t: Checker, _ dir: URL) throws {
            let source = try SourceImage(try Fixtures.write(TestImages.scene(width: 3000, height: 2000), "big scene.png", in: dir))
            let editor = AdjustEditorView(source: source, loadAsync: false)
            let window = Fixtures.offscreenWindow(editor)
            editor.renderPreviewNow()
            guard let original = editor.previewImage.map(Pixels.init) else { t.check(false, "Adjust preview loads"); return }
            t.check(max(original.width, original.height) <= AdjustEditorView.proxyPixels,
                    "a 3000 px image previews from a \(original.width) px proxy")
            editor.setValues(try Adjustments(options: ["exposure": "1"]))
            editor.renderPreviewNow()
            if let brighter = editor.previewImage.map(Pixels.init) {
                let all = CGRect(x: 0, y: 0, width: brighter.width, height: brighter.height)
                t.check(brighter.stats(all).luma > original.stats(all).luma + 15, "the live preview follows the sliders")
            }
            _ = editor.handleKey(Fixtures.key("m", window: window))
            t.check(editor.isShowingOriginal, "holding M shows the original")
            _ = editor.handleKey(Fixtures.key("m", window: window, up: true))
            t.check(!editor.isShowingOriginal, "releasing M shows the edit again")
            editor.setValues(Adjustments())
            t.check(Adjustments.Key.allCases.allSatisfy { editor.value($0) == 0 }, "Reset returns every slider to zero")

            // One slider row: dragging rounds to whole steps, typing sets exact values, junk reverts, double-click resets.
            let row = AdjustSliderRow(key: .contrast)
            var changes: [Double] = []
            row.onChange = { changes.append($0) }
            row.slider.doubleValue = 23.6
            _ = row.slider.sendAction(row.slider.action, to: row.slider.target)
            row.valueField.stringValue = "−35"
            row.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
            row.setValue(-35)
            row.valueField.stringValue = "lots"
            row.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
            let reverted = row.valueField.stringValue
            row.slider.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                          windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!)
            t.check(changes == [24, -35, 0] && reverted == "−35",
                    "slider rounds (24), typed “−35” applies, “lots” reverts (\(reverted)), double-click resets (\(changes))")

            var finished = false
            editor.onFinish = { _ in finished = true }
            _ = editor.handleKey(Fixtures.key("\u{1b}", keyCode: 53, window: window))
            t.check(finished, "Esc cancels")
            editor.tearDown()
            window.contentView = nil
        }

        // MARK: Annotate

        private static func annotationParsing(_ t: Checker) throws {
            let size = CGSize(width: 1000, height: 500)
            let json = ##"[{"type":"arrow","from":[1,2],"to":[3,4],"color":"#FF3B30","width":8},{"type":"rectangle","rect":[10,20,30,40],"fill":"#00FF0080"},"##
                + ##"{"type":"oval","rect":[0,0,5,5]},{"type":"line","from":[0,0],"to":[9,9],"color":"blue"},{"type":"pen","points":[[1,1],[2,2],[3,1]]},"##
                + ##"{"type":"highlight","rect":[5,5,50,10]},{"type":"highlighter","points":[[0,0],[40,0]]},"##
                + ##"{"type":"text","at":[7,8],"text":"Hi\nthere","size":48,"font":"rounded","weight":"bold","background":"#000"}]"##
            let items = try Annotation.parse(json, imageSize: size)
            t.check(items.map(\.kind.rawValue) == ["arrow", "rect", "ellipse", "line", "pen", "highlight", "highlight", "text"],
                    "every shape type and alias parses (\(items.map(\.kind.rawValue).joined(separator: ",")))")
            t.check(items[0].width == 8 && items[3].color == RGBA.named("blue") && items[1].fill?.a ?? 0 > 0.49,
                    "width, color names and #RRGGBBAA fills are read")
            t.check(items[5].isBox && !items[6].isBox && items[5].opacity == 0.5 && items[5].color == Annotation.highlightColor,
                    "highlights default to translucent yellow, as a box or a stroke")
            t.check(items[7].text == "Hi\nthere" && items[7].font == .rounded && items[7].weight == .bold && items[7].fontSize == 48,
                    "text keeps its lines, font, weight and size")
            t.check(items[2].width == Annotation.defaultWidth(for: size), "width defaults scale with the image (\(items[2].width) px)")
            let roundTrip = try Annotation.parse(String(data: try JSONSerialization.data(withJSONObject: items.map(\.jsonObject)), encoding: .utf8)!,
                                                 imageSize: size)
            t.check(roundTrip == items, "marks survive a JSON round trip")
            let refusals: [(String, String)] = [
                ("{oops", "isn’t valid JSON"), (##"[{"from":[0,0]}]"##, "has no “type”"),
                (##"[{"type":"star"}]"##, "unknown type “star”"), (##"[{"type":"arrow","from":[0,0]}]"##, "needs “from” and “to”"),
                (##"[{"type":"rect","rect":[0,0,5]}]"##, "needs “rect”"), (##"[{"type":"pen","points":[]}]"##, "needs “points”"),
                (##"[{"type":"text","at":[0,0],"text":"  "}]"##, "some “text”"), (##"[{"type":"line","from":[0,0],"to":[1,1],"color":"#GGG"}]"##, "color like"),
                (##"[{"type":"line","from":[0,0],"to":[1,1],"width":"wide"}]"##, "isn’t a number"), ("42", "must be a JSON array"),
            ]
            for (bad, message) in refusals {
                t.throwsError({ _ = try Annotation.parse(bad, imageSize: size) }, containing: message, "refuses \(bad)")
            }
        }

        /// Shapes land on the right pixels of a white 400 × 300 image.
        private static func annotationPixels(_ t: Checker, _ dir: URL) throws {
            let white = Fixtures.solid(width: 400, height: 300, gray: 1)
            let json = ##"[{"type":"rect","rect":[40,40,100,80],"width":6,"color":"#FF0000"},"##
                + ##"{"type":"ellipse","rect":[200,40,120,80],"width":6,"color":"#0000FF"},"##
                + ##"{"type":"arrow","from":[20,260],"to":[380,260],"width":8,"color":"#00A000"},"##
                + ##"{"type":"highlight","rect":[40,160,120,30]},"##
                + ##"{"type":"text","at":[220,150],"text":"Hi","size":40,"color":"#000000"},"##
                + ##"{"type":"pen","points":[[300,200],[320,210],[340,200]],"width":6,"color":"#FF00FF"}]"##
            let items = try Annotation.parse(json, imageSize: CGSize(width: 400, height: 300))
            let p = Pixels(try AnnotationRenderer.burn(items, into: white))
            func isColor(_ c: Pixels.RGBA, _ r: Int, _ g: Int, _ b: Int) -> Bool { abs(c.r - r) < 40 && abs(c.g - g) < 40 && abs(c.b - b) < 40 }
            t.check(isColor(p.at(40, 80), 255, 0, 0) && isColor(p.at(140, 80), 255, 0, 0) && isColor(p.at(90, 80), 255, 255, 255),
                    "rectangle edges are red, inside stays white (\(p.at(40, 80)), \(p.at(90, 80)))")
            t.check(isColor(p.at(200, 80), 0, 0, 255) && isColor(p.at(260, 80), 255, 255, 255) && isColor(p.at(205, 45), 255, 255, 255),
                    "ellipse outline is blue, center and corner stay white (\(p.at(200, 80)), \(p.at(260, 80)), \(p.at(205, 45)))")
            t.check(isColor(p.at(100, 260), 0, 160, 0) && isColor(p.at(375, 260), 0, 160, 0) && isColor(p.at(100, 275), 255, 255, 255),
                    "arrow shaft and tip are green, beside it stays white (\(p.at(375, 260)), \(p.at(100, 275)))")
            let head = p.at(365, 268)
            t.check(isColor(head, 0, 160, 0), "the arrowhead is wider than the shaft (\(head) at 8 px off-axis)")
            let hl = p.at(100, 175)
            t.check(hl.r > 240 && hl.g > 215 && hl.b < 175 && hl.b > 90, "highlight tints white to light yellow (\(hl))")
            let textBox = p.darkCount(CGRect(x: 220, y: 150, width: 60, height: 50)), outside = p.darkCount(CGRect(x: 220, y: 205, width: 60, height: 30))
            t.check(textBox > 150 && outside == 0, "text draws below and right of “at” (\(textBox) dark pixels in its box, \(outside) below)")
            t.check(isColor(p.at(320, 207), 255, 0, 255), "pen stroke passes through its points (\(p.at(320, 207)))")
            t.check(isColor(p.at(5, 5), 255, 255, 255) && isColor(p.at(395, 150), 255, 255, 255), "untouched areas stay white")
        }

        private static func annotationFiles(_ t: Checker, _ dir: URL) throws {
            let jpeg = try Fixtures.rotatedJPEG(in: dir)
            let options = ["annotations": ##"[{"type":"rect","rect":[10,10,60,60],"color":"#00FF00","width":6}]"##]
            let out = try AnnotationRenderer.save(jpeg, options: options)
            let props = Fixtures.properties(out)
            t.check(out.lastPathComponent == "sideways annotated.jpg" && props.width == 200 && props.height == 400 && props.orientation == 1,
                    "annotating an EXIF-rotated JPEG writes an upright “<name> annotated.jpg” (\(out.lastPathComponent), \(props.width)×\(props.height))")
            if let image = Fixtures.image(out) {
                let p = Pixels(image)
                t.check(p.at(10, 40).g > 200 && p.at(10, 40).r < 80 && p.at(150, 50).r > 200,
                        "marks use upright coordinates: rectangle at the top-left, red block still top-right")
            }
            t.check(props.make == "DropWheelCam", "metadata is kept")
            let fileJSON = dir.appendingPathComponent("marks.json")
            try options["annotations"]!.write(to: fileJSON, atomically: true, encoding: .utf8)
            let fromFile = try AnnotationRenderer.save(jpeg, options: ["annotations": "@" + fileJSON.path])
            t.check(fromFile.lastPathComponent == "sideways annotated 2.jpg", "annotations=@file.json reads a file")
            t.throwsError({ _ = try AnnotationRenderer.save(jpeg, options: [:]) }, containing: "no annotations", "no annotations is refused")
            let gray = try Fixtures.write(Fixtures.solid(width: 120, height: 80, gray: 0.5, space: CGColorSpaceCreateDeviceGray()), "gray.png", in: dir)
            let grayOut = try AnnotationRenderer.save(gray, options: ["annotations": ##"[{"type":"line","from":[0,40],"to":[120,40],"color":"red","width":10}]"##])
            if let image = Fixtures.image(grayOut) {
                let c = Pixels(image).at(60, 40)
                t.check(c.r > 200 && c.g < 100, "red marks on a grayscale image stay red (\(c))")
            }
        }

        /// The Annotate window offscreen, driven by synthesized mouse and key events.
        private static func annotateEditor(_ t: Checker, _ dir: URL) throws {
            let url = try Fixtures.write(Fixtures.solid(width: 800, height: 600, gray: 1), "canvas.png", in: dir)
            let editor = AnnotateEditorView(source: try SourceImage(url), loadAsync: false)
            let window = Fixtures.offscreenWindow(editor)
            let canvas = editor.canvas
            func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, clicks: Int = 1, shift: Bool = false) -> NSEvent {
                let p = canvas.convert(canvas.toView(CGPoint(x: x, y: y)), to: nil)
                return NSEvent.mouseEvent(with: type, location: p, modifierFlags: shift ? .shift : [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
            }
            func drag(_ from: CGPoint, _ to: CGPoint, shift: Bool = false) {
                canvas.mouseDown(with: mouse(.leftMouseDown, from.x, from.y, shift: shift))
                for step in 1...4 {
                    let k = CGFloat(step) / 4
                    canvas.mouseDragged(with: mouse(.leftMouseDragged, from.x + (to.x - from.x) * k, from.y + (to.y - from.y) * k, shift: shift))
                }
                canvas.mouseUp(with: mouse(.leftMouseUp, to.x, to.y, shift: shift))
            }
            func near(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 2 }

            editor.selectTool(.arrow)
            drag(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200))
            let arrow = canvas.annotations.first
            t.check(canvas.annotations.count == 1 && arrow?.kind == .arrow && near(arrow!.points[0], CGPoint(x: 100, y: 100))
                    && near(arrow!.points[1], CGPoint(x: 300, y: 200)), "dragging with the arrow tool draws an arrow where the mouse went")
            _ = editor.handleKey(Fixtures.key("r", window: window))
            t.check(canvas.tool == .rect, "R picks the rectangle tool")
            drag(CGPoint(x: 500, y: 300), CGPoint(x: 501, y: 300))
            t.check(canvas.annotations.count == 1, "a click without a drag draws nothing")
            drag(CGPoint(x: 400, y: 300), CGPoint(x: 600, y: 420), shift: true)
            let box = canvas.annotations.last?.box ?? .zero
            t.check(canvas.annotations.count == 2 && abs(box.width - box.height) < 1 && box.width > 150,
                    "⇧ makes the rectangle square (\(Int(box.width)) × \(Int(box.height)))")
            editor.selectTool(.pen)
            canvas.mouseDown(with: mouse(.leftMouseDown, 100, 400))
            for (x, y) in [(130, 430), (160, 400), (190, 430), (220, 400)] { canvas.mouseDragged(with: mouse(.leftMouseDragged, CGFloat(x), CGFloat(y))) }
            canvas.mouseUp(with: mouse(.leftMouseUp, 220, 400))
            t.check(canvas.annotations.last?.kind == .pen && (canvas.annotations.last?.points.count ?? 0) >= 4, "the pen records its path")

            editor.selectTool(.select)
            canvas.mouseDown(with: mouse(.leftMouseDown, 200, 150))
            t.check(canvas.selection == 0, "clicking an arrow’s shaft selects it")
            canvas.mouseDragged(with: mouse(.leftMouseDragged, 230, 170))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, 250, 180))
            canvas.mouseUp(with: mouse(.leftMouseUp, 250, 180))
            let moved = canvas.annotations[0].points
            t.check(near(moved[0], CGPoint(x: 150, y: 130)) && near(moved[1], CGPoint(x: 350, y: 230)), "dragging moves the selected mark")
            canvas.undo()
            t.check(near(canvas.annotations[0].points[0], CGPoint(x: 100, y: 100)), "undo puts it back")
            canvas.redo()
            t.check(near(canvas.annotations[0].points[0], CGPoint(x: 150, y: 130)), "redo moves it again")

            canvas.mouseDown(with: mouse(.leftMouseDown, 600, 420))   // the square's right edge
            canvas.mouseUp(with: mouse(.leftMouseUp, 600, 420))
            t.check(canvas.selection == 1, "clicking the square’s edge selects it")
            canvas.mouseDown(with: mouse(.leftMouseDown, 600, 500))   // its bottom-right handle
            canvas.mouseDragged(with: mouse(.leftMouseDragged, 700, 560))
            canvas.mouseUp(with: mouse(.leftMouseUp, 700, 560))
            let reshaped = canvas.annotations[1].box
            t.check(abs(reshaped.maxX - 700) < 2 && abs(reshaped.maxY - 560) < 2 && abs(reshaped.minX - 400) < 2 && abs(reshaped.minY - 300) < 2,
                    "dragging a corner handle reshapes the box, the opposite corner stays (\(Int(reshaped.minX)),\(Int(reshaped.minY))–\(Int(reshaped.maxX)),\(Int(reshaped.maxY)))")
            editor.canvas.setColor(RGBA.named("blue"))
            editor.canvas.setSizeLevel(3)
            t.check(canvas.annotations[1].color == RGBA.named("blue") && canvas.annotations[1].width == canvas.strokeWidth,
                    "color and size apply to the selected mark")
            let before = canvas.annotations[1].box.minX
            _ = editor.handleKey(Fixtures.key("\u{F703}", keyCode: 124, window: window))
            t.check(abs(canvas.annotations[1].box.minX - (before + 1 / canvas.scale)) < 0.01, "→ nudges the selection by one point")
            let count = canvas.annotations.count
            _ = editor.handleKey(Fixtures.key("\u{7f}", keyCode: 51, window: window))
            t.check(canvas.annotations.count == count - 1 && canvas.selection == nil, "⌫ deletes the selected mark")
            _ = editor.handleKey(Fixtures.key("z", flags: .command, window: window))
            t.check(canvas.annotations.count == count, "⌘Z brings it back")
            canvas.select(0)
            _ = editor.handleKey(Fixtures.key("\u{1b}", keyCode: 53, window: window))
            t.check(canvas.selection == nil, "Esc clears the selection first")

            editor.selectTool(.text)
            canvas.mouseDown(with: mouse(.leftMouseDown, 60, 500))
            t.check(canvas.isEditingText, "the text tool opens a text field where you click")
            canvas.typeText("Hello")
            canvas.commitTextEdit()
            let text = canvas.annotations.last
            t.check(text?.kind == .text && text?.text == "Hello" && near(text!.points[0], CGPoint(x: 60, y: 500)), "typed text becomes a mark at the click")
            canvas.mouseDown(with: mouse(.leftMouseDown, 70, 515))
            t.check(canvas.isEditingText, "clicking a text mark edits it")
            canvas.typeText("Hello again")
            canvas.commitTextEdit()
            t.check(canvas.annotations.last?.text == "Hello again" && canvas.annotations.filter { $0.kind == .text }.count == 1,
                    "editing replaces the text instead of adding a mark")
            canvas.mouseDown(with: mouse(.leftMouseDown, 300, 560))
            _ = editor.handleKey(Fixtures.key("\u{1b}", keyCode: 53, window: window))
            t.check(!canvas.isEditingText && canvas.annotations.filter { $0.kind == .text }.count == 1, "Esc abandons a new text field")

            // What the canvas holds is what gets saved.
            let saved = try AnnotationRenderer.save(canvas.annotations, source: try SourceImage(url))
            t.check(saved.lastPathComponent == "canvas annotated.png" && Fixtures.image(saved).map { Pixels($0).inkCount(CGRect(x: 60, y: 500, width: 200, height: 40)) > 50 } == true,
                    "Save writes the marks at full size (\(saved.lastPathComponent))")
            var cancelled = false
            let blank = AnnotateEditorView(source: try SourceImage(url), loadAsync: false)
            blank.onFinish = { _ in cancelled = true }
            blank.requestCancel()
            t.check(cancelled, "Cancel with nothing drawn closes without asking")
            editor.tearDown()
            window.contentView = nil
        }

        private static func f(_ v: Double) -> String { String(format: "%.1f", v) }
    }

    // MARK: - Test helpers

    /// Collects results; the report starts with PASS or FAIL.
    final class Checker {
        private var lines: [String] = []
        private var failures = 0

        func check(_ ok: Bool, _ what: String) {
            lines.append((ok ? "  ok    " : "  FAIL  ") + what)
            if !ok { failures += 1 }
        }

        func throwsError(_ body: () throws -> Void, containing text: String, _ what: String) {
            do {
                try body()
                check(false, "\(what): no error")
            } catch {
                check(error.localizedDescription.contains(text), "\(what): “\(error.localizedDescription)”")
            }
        }

        var report: String {
            let head = failures == 0 ? "PASS image editors: \(lines.count) checks" : "FAIL image editors: \(failures) of \(lines.count) checks failed"
            return ([head] + lines).joined(separator: "\n")
        }
    }

    /// RGBA8 sRGB pixels of an image, addressed from the top-left.
    struct Pixels {
        struct RGBA: CustomStringConvertible {
            let r: Int, g: Int, b: Int, a: Int
            var description: String { "rgb(\(r),\(g),\(b))" }
        }

        struct Stats { let luma, sd, r, g, b, chroma: Double }

        let width: Int, height: Int
        private let data: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            buffer.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            data = buffer
        }

        func at(_ x: Int, _ y: Int) -> RGBA {
            let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
            return RGBA(r: Int(data[i]), g: Int(data[i + 1]), b: Int(data[i + 2]), a: Int(data[i + 3]))
        }

        private func each(_ rect: CGRect, _ body: (RGBA, Int, Int) -> Void) {
            let r = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !r.isNull else { return }
            for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) { body(at(x, y), x, y) } }
        }

        func stats(_ rect: CGRect) -> Stats {
            var n = 0.0, l = 0.0, l2 = 0.0, r = 0.0, g = 0.0, b = 0.0, c = 0.0
            each(rect) { p, _, _ in
                let y = 0.2126 * Double(p.r) + 0.7152 * Double(p.g) + 0.0722 * Double(p.b)
                n += 1; l += y; l2 += y * y; r += Double(p.r); g += Double(p.g); b += Double(p.b)
                c += Double(max(p.r, p.g, p.b) - min(p.r, p.g, p.b))
            }
            n = max(n, 1)
            let mean = l / n
            return Stats(luma: mean, sd: sqrt(max(0, l2 / n - mean * mean)), r: r / n, g: g / n, b: b / n, chroma: c / n)
        }

        /// Mean absolute Laplacian of luma: how much edge contrast a region has.
        func laplacian(_ rect: CGRect) -> Double {
            func luma(_ x: Int, _ y: Int) -> Double { let p = at(x, y); return 0.2126 * Double(p.r) + 0.7152 * Double(p.g) + 0.0722 * Double(p.b) }
            var total = 0.0, n = 0.0
            each(rect.insetBy(dx: 1, dy: 1)) { _, x, y in
                total += abs(4 * luma(x, y) - luma(x - 1, y) - luma(x + 1, y) - luma(x, y - 1) - luma(x, y + 1)); n += 1
            }
            return total / max(n, 1)
        }

        /// Pixels that aren't (nearly) white.
        func inkCount(_ rect: CGRect) -> Int {
            var n = 0
            each(rect) { p, _, _ in if p.r + p.g + p.b < 700 { n += 1 } }
            return n
        }

        func darkCount(_ rect: CGRect) -> Int {
            var n = 0
            each(rect) { p, _, _ in if p.r + p.g + p.b < 300 { n += 1 } }
            return n
        }

        func maxDifference(_ other: Pixels) -> Int {
            guard other.width == width, other.height == height else { return 255 }
            return zip(data, other.data).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
        }
    }

    /// Generated files for the tests.
    enum Fixtures {
        static func solid(width: Int, height: Int, gray: CGFloat, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage {
            let isGray = space.model == .monochrome
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: isGray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(isGray ? CGColor(gray: gray, alpha: 1) : CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return ctx.makeImage()!
        }

        @discardableResult
        static func write(_ image: CGImage, _ name: String, in dir: URL, type: UTType? = nil, frames: [CGImage] = [],
                          properties: [CFString: Any] = [:]) throws -> URL {
            let url = dir.appendingPathComponent(name)
            let type = type ?? UTType(filenameExtension: url.pathExtension) ?? .png
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1 + frames.count, nil) else {
                throw ConversionError.toolFailed("Couldn’t create \(name).")
            }
            for frame in [image] + frames { CGImageDestinationAddImage(dest, frame, properties as CFDictionary) }
            guard CGImageDestinationFinalize(dest) else { throw ConversionError.toolFailed("Couldn’t write \(name).") }
            return url
        }

        /// 400 × 200 pixels stored sideways with EXIF orientation 6 (shown 200 × 400): a red block at the stored
        /// top-left (shown top-right) and a blue block at the stored bottom-right (shown bottom-left).
        static func rotatedJPEG(in dir: URL) throws -> URL {
            let url = dir.appendingPathComponent("sideways.jpg")
            if FileManager.default.fileExists(atPath: url.path) { return url }
            let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 100, width: 100, height: 100))
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 300, y: 0, width: 100, height: 100))
            let plain = try write(ctx.makeImage()!, "plain.jpg", in: dir, properties: [
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "DropWheelCam"],
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N"],
                kCGImageDestinationLossyCompressionQuality: 0.95,
            ])
            // Orientation goes in losslessly afterwards; ImageIO ignores it when encoding.
            guard let src = CGImageSourceCreateWithURL(plain as CFURL, nil), let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
                  let copy = CGImageMetadataCreateMutableCopy(meta),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw ConversionError.toolFailed("Couldn’t make the rotated test image.") }
            CGImageMetadataSetValueMatchingImageProperty(copy, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 6 as CFNumber)
            let options: [CFString: Any] = [kCGImageDestinationMetadata: copy, kCGImageDestinationMergeMetadata: true]
            guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, nil) else {
                throw ConversionError.toolFailed("Couldn’t tag the rotated test image.")
            }
            return url
        }

        static func alphaPNG(in dir: URL) throws -> URL {
            let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 0.8))
            ctx.fillEllipse(in: CGRect(x: 50, y: 25, width: 200, height: 150))
            return try write(ctx.makeImage()!, "alpha.png", in: dir)
        }

        static func deepPNG(in dir: URL) throws -> URL {
            let ctx = CGContext(data: nil, width: 256, height: 32, bitsPerComponent: 16, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            for x in 0..<256 {
                ctx.setFillColor(CGColor(srgbRed: CGFloat(x) / 255, green: 0.5, blue: 1 - CGFloat(x) / 255, alpha: 1))
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: 32))
            }
            return try write(ctx.makeImage()!, "deep.png", in: dir)
        }

        static func animatedGIF(in dir: URL) throws -> URL {
            try write(solid(width: 60, height: 40, gray: 0.3), "anim.gif", in: dir, frames: [solid(width: 60, height: 40, gray: 0.7)])
        }

        static func image(_ url: URL) -> CGImage? {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }

        static func properties(_ url: URL) -> (width: Int, height: Int, orientation: Int, make: String?, hasGPS: Bool) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (0, 0, 0, nil, false) }
            let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            return ((p[kCGImagePropertyPixelWidth] as? Int) ?? 0, (p[kCGImagePropertyPixelHeight] as? Int) ?? 0,
                    (p[kCGImagePropertyOrientation] as? Int) ?? 1, tiff?[kCGImagePropertyTIFFMake] as? String,
                    p[kCGImagePropertyGPSDictionary] != nil)
        }

        /// A borderless window that is never ordered on screen, so views get a window for events and layout.
        static func offscreenWindow(_ view: NSView) -> NSWindow {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            return window
        }

        static func key(_ characters: String, keyCode: UInt16 = 0, flags: NSEvent.ModifierFlags = [], window: NSWindow,
                        up: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        }
    }
}
#endif
