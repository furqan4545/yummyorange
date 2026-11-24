#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import ImageIO
import Metal
import QuartzCore
import UniformTypeIdentifiers

/// `--selftest clothesline-perf`: what one frame of the Clothesline's motion costs, measured on the real controller and
/// view (offscreen surfaces, the flight view, a manual clock), with frames paced in real time at 120 Hz so pictures
/// arrive as they do in the app. Three scenes on a line of 16 cards: a screenshot's flight (a 3456 × 2234 PNG, its
/// picture loaded as the app loads it), a card moved along the string, and a file dragged onto the line with the ghost.
/// For each frame it times the main thread (the input events, the tick and the Core Animation commit) and Core
/// Animation's own render of the line's and the flight's layers on the GPU (CARenderer: what the window server does
/// with them, masks, shadows and blurs included). A report; `checks` adds what keeps it fast to `--selftest clothesline`.
enum ClotheslinePerfTests {
    typealias Checker = ShelfAndWelcomeTests.Checker
    static let sample = ClotheslineGeometry.builtInSample
    static let frameRate = 120.0

    // MARK: Report

    static func run() -> String {
        let c = Checker()
        do {
            let fixtures = try Fixtures()
            defer { fixtures.remove() }
            for scene in Scene.allCases {
                let r = try measure(scene, fixtures: fixtures)
                c.check(true, scene.title, r.summary)
            }
            if let still = ProcessInfo.processInfo.environment["DW_PERF_STILL"] { writeStills(c, fixtures: fixtures, base: still) }
            pictureCosts(c, fixtures: fixtures)
            stringCosts(c)
            flightWindowCost(c)
        } catch {
            c.check(false, "performance setup", error.localizedDescription)
        }
        return c.report
    }

    // MARK: Checks (part of --selftest clothesline)

    /// What keeps the motion smooth, checked without timing anything that the machine's load could upset.
    static func checks(_ c: Checker) {
        displayClock(c)
        do {
            let fixtures = try Fixtures(screenshot: false)
            defer { fixtures.remove() }
            pictures(c, fixtures: fixtures)
            flightWindowKept(c, fixtures: fixtures)
        } catch {
            c.check(false, "performance checks setup", error.localizedDescription)
        }
        glowWithoutShadow(c)
    }

    /// The live clock runs while the line's panel is off screen (a screenshot's card flying to a hidden line): the
    /// display's link, not the view's (which delivers nothing in a window that isn't on screen).
    static func displayClock(_ c: Checker) {
        guard let screen = NSScreen.main else { c.check(true, "display clock: no display to tick (skipped)"); return }
        let surface = ClotheslinePanelSurface(engine: ClotheslineEngine(geometry: sample))
        let clock = ClotheslineDisplayClock(view: surface.view)
        clock.screen = { screen }
        var times: [Double] = []
        clock.onTick = { times.append($0) }
        clock.start()
        let end = Date().addingTimeInterval(0.3)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        clock.stop()
        let rate = times.count > 1 ? Double(times.count - 1) / max(1e-6, times.last! - times.first!) : 0
        c.check(!surface.isShown && clock.ticks >= 12 && !clock.isRunning,
                "display clock: frames keep coming while the line's panel is off screen (the view's own link would deliver none)",
                "\(clock.ticks) frames in 0.3 s (\(Int(rate.rounded())) Hz)")
    }

    /// Pictures are decoded off the main thread, and a card is drawn once, with its picture (no placeholder first).
    static func pictures(_ c: Checker, fixtures: Fixtures) {
        let rig = Rig()
        let decoded = ClotheslinePictures.decoded
        let before = ClotheslineArt.drawStats
        let files = Array(fixtures.line.prefix(10))
        rig.ctl.hang(files)
        let atHang = ClotheslineArt.drawStats.mainThread - before.mainThread
        // The pictures arrive (decoded off the main thread); the cards wait for them, then drop.
        let end = Date().addingTimeInterval(3)
        while Date() < end && rig.engine.items.contains(where: { !rig.surface.view.hasPicture($0.url) }) {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        for _ in 0..<Int(1.5 * frameRate) { rig.now += 1 / frameRate; rig.ctl.tick(at: rig.now) }
        let drawn = ClotheslineArt.drawStats.mainThread - before.mainThread
        let aspect = rig.surface.view.width(for: files[1])
        c.check(atHang == 0 && drawn == files.count && ClotheslinePictures.decoded - decoded == files.count
                && abs(aspect - ClotheslineCardMetrics.matWidth(aspect: 480.0 / 300)) < 0.5,
                "pictures: hanging 10 files draws nothing yet; each picture is decoded off the main thread and each card drawn once, with it",
                "\(atHang) drawn at the hang, \(drawn) in all, \(ClotheslinePictures.decoded - decoded) decoded, card \(f(Double(aspect), 1)) pt wide")
        rig.ctl.shutDown()
    }

    /// One flight window for every card carried and every flight: it is ordered out between them, not made again.
    static func flightWindowKept(_ c: Checker, fixtures: Fixtures) {
        let rig = Rig()
        rig.ctl.watchDrops()
        rig.hangSettled(Array(fixtures.line.prefix(4)), hidden: false)
        let e = rig.engine, view = rig.surface.view
        var shownBetween = false
        for round in 0..<2 {
            guard let pose = e.pose(e.items[round].id) else { break }
            var p = ClotheslineEngine.toScene(pose, CGPoint(x: 0, y: 60))
            rig.button = true
            rig.ctl.mouseEvent(.down, screen: rig.screen(p))
            view.pressDown(at: p)
            for _ in 0..<30 {
                p.x += 8
                rig.ctl.mouseEvent(.dragged, screen: rig.screen(p))
                view.pressMoved(to: p)
                rig.now += 1 / frameRate; rig.ctl.tick(at: rig.now)
            }
            rig.button = false
            view.pressUp(at: p)
            rig.ctl.mouseEvent(.up, screen: rig.screen(p))
            for _ in 0..<Int(1.2 * frameRate) { rig.now += 1 / frameRate; rig.ctl.tick(at: rig.now) }
            shownBetween = shownBetween || rig.ctl.flightWindowShown
        }
        c.check(rig.flightWindows == 1 && !shownBetween && rig.ctl.flightSurface != nil,
                "two cards carried along the string: one flight window, ordered out in between (made once: about 5 ms each time)",
                "made \(rig.flightWindows)")
        rig.ctl.shutDown()
        c.check(rig.ctl.flightSurface == nil, "the line turned off lets the flight window go")
    }

    /// The glow is the stroke over its blur, drawn small: no Core Animation shadow (an offscreen blur every frame).
    static func glowWithoutShadow(_ c: Checker) {
        let e = ClotheslineTests.shownEngine(3)
        let view = ClotheslineView(engine: e, frame: CGRect(origin: .zero, size: sample.panelFrame.size))
        view.itemsChanged()
        view.render()
        func layers(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(layers) + (l.mask.map(layers) ?? []) }
        let all = view.layer.map(layers) ?? []
        let shadowed = all.filter { $0.shadowOpacity > 0 && $0.contents == nil && $0.shadowPath != nil && $0.superlayer !== view.cardsLayer }
        let blur = view.stringLayers.glow.mask?.sublayers?.first
        let image = blur?.contents.map { $0 as! CGImage }
        c.check(shadowed.isEmpty && image != nil && (image?.height ?? 99) < 60,
                "the string's glow has no Core Animation shadow: its blur is an image a quarter of a point per pixel",
                image.map { "\($0.width) × \($0.height) px" } ?? "no blur")
    }

    // MARK: Fixtures

    /// Sixteen small pictures for the line and a screenshot-sized PNG, in a temporary folder.
    final class Fixtures {
        let dir: URL
        let line: [URL]
        let screenshot: URL
        init(screenshot big: Bool = true) throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("YummyOrange perf \(UUID().uuidString.prefix(8))", isDirectory: true)
            self.dir = dir
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            line = try (0..<16).map { i in
                let url = dir.appendingPathComponent(String(format: "card %02d.png", i))
                try Fixtures.writePNG(width: i % 3 == 0 ? 300 : 480, height: i % 3 == 0 ? 400 : 300, hue: Double(i) / 16, to: url)
                return url
            }
            screenshot = dir.appendingPathComponent("Screenshot 2026-11-24 at 10.31.07.png")
            if big { try Fixtures.writePNG(width: 3456, height: 2234, hue: 0.58, to: screenshot, busy: true) }
        }
        func remove() { try? FileManager.default.removeItem(at: dir) }

        /// A PNG with a window-like picture (a gradient, panels, rows of text and some noise, so it compresses like a
        /// real screenshot does).
        static func writePNG(width: Int, height: Int, hue: Double, to url: URL, busy: Bool = false) throws {
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
            let a = NSColor(hue: hue, saturation: 0.5, brightness: 0.95, alpha: 1).cgColor
            let b = NSColor(hue: hue + 0.1, saturation: 0.7, brightness: 0.55, alpha: 1).cgColor
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [a, b] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: width, y: height), options: [])
            }
            ctx.setFillColor(NSColor(white: 1, alpha: 0.92).cgColor)
            ctx.fill(CGRect(x: width / 10, y: height / 10, width: width * 8 / 10, height: height * 8 / 10))
            if busy {
                var seed: UInt32 = 7
                func next() -> CGFloat { seed = seed &* 1664525 &+ 1013904223; return CGFloat(seed >> 8) / CGFloat(1 << 24) }
                for row in stride(from: height / 10 + 40, to: height * 9 / 10 - 40, by: 34) {
                    var x = width / 10 + 60
                    while x < width * 9 / 10 - 200 {
                        let w = Int(40 + next() * 220)
                        ctx.setFillColor(NSColor(white: 0.1 + 0.4 * next(), alpha: 1).cgColor)
                        ctx.fill(CGRect(x: x, y: row, width: w, height: 16))
                        x += w + 14
                    }
                }
                for _ in 0..<40000 {
                    ctx.setFillColor(NSColor(hue: next(), saturation: 0.6, brightness: 0.8, alpha: 1).cgColor)
                    ctx.fill(CGRect(x: next() * CGFloat(width), y: next() * CGFloat(height), width: 3, height: 3))
                }
            }
            guard let image = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    // MARK: Core Animation's render, on the GPU

    /// Renders layer trees with Core Animation's own renderer into a Metal texture the size of the display (2 pixels
    /// per point), as the window server composites the line's panel (the top 300 pt) and the flight window (all of it).
    final class LayerRenderer {
        let queue: MTLCommandQueue
        let texture: MTLTexture
        let renderer: CARenderer
        let host = CALayer()
        private let lineSlot = CALayer(), flightSlot = CALayer()

        init?(geometry g: ClotheslineGeometry, line: CALayer, flight: CALayer?) {
            let scale: CGFloat = 2
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
            let w = Int(g.width * scale), h = Int(g.screenFrame.height * scale)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            // Readable, for stills (DW_PERF_STILL).
            d.storageMode = device.hasUnifiedMemory ? .shared : .managed
            guard let texture = device.makeTexture(descriptor: d) else { return nil }
            self.queue = queue
            self.texture = texture
            renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue as String: queue])
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Scaled about its corner (a sublayer transform applies about the anchor point).
            host.anchorPoint = .zero
            host.frame = CGRect(x: 0, y: 0, width: w, height: h)
            host.sublayerTransform = CATransform3DMakeScale(scale, scale, 1)
            lineSlot.frame = CGRect(x: 0, y: g.screenFrame.height - ClotheslineGeometry.panelHeight, width: g.width,
                                    height: ClotheslineGeometry.panelHeight)
            flightSlot.frame = CGRect(x: 0, y: 0, width: g.width, height: g.screenFrame.height)
            host.addSublayer(lineSlot)
            host.addSublayer(flightSlot)
            lineSlot.addSublayer(line)
            if let flight { flightSlot.addSublayer(flight) }
            CATransaction.commit()
            renderer.layer = host
            renderer.bounds = host.bounds
        }

        /// One frame of both windows: milliseconds from the start of the render until the GPU has finished it.
        func frame() -> Double {
            CATransaction.flush()
            // Core Animation draws over what is there: the frame starts clear (not timed).
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            if let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
                enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            }
            let t0 = CACurrentMediaTime()
            renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
            if let cb = queue.makeCommandBuffer() { cb.commit(); cb.waitUntilCompleted() }
            return (CACurrentMediaTime() - t0) * 1000
        }

        /// The last frame as an image (sRGB, premultiplied BGRA).
        func image() -> CGImage? {
            if texture.storageMode == .managed, let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
                blit.synchronize(resource: texture); blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            }
            let w = texture.width, h = texture.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }

        /// Gives the layers back (they leave the host).
        func detach() {
            for slot in [lineSlot, flightSlot] { slot.sublayers?.forEach { $0.removeFromSuperlayer() } }
        }
    }

    // MARK: Scenes

    enum Scene: CaseIterable {
        case flight, cardAlongString, fileDrag
        var title: String {
            switch self {
            case .flight: return "a screenshot's flight onto a line of 16 cards (3456 × 2234 PNG)"
            case .cardAlongString: return "a card moved along the string of 16 cards"
            case .fileDrag: return "a file dragged onto the line of 16 cards, with the ghost"
            }
        }
    }

    struct Stats {
        var values: [Double]
        var mean: Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
        func percentile(_ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let s = values.sorted()
            return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
        }
        var max: Double { values.max() ?? 0 }
        var text: String { "mean \(f(mean, 3)) ms, p95 \(f(percentile(0.95), 3)), max \(f(max, 2))" }
    }

    struct Result {
        var main = Stats(values: [])
        var render = Stats(values: [])
        /// Frames whose main-thread work went over a 120 Hz frame (8.3 ms).
        var overBudget = 0
        var picturesOnMain = 0
        var pictureMilliseconds = 0.0
        var flightWindows = 0
        /// How far the drawn card in the hand was from where the pointer holds it (points, largest).
        var heldLag = 0.0
        var notes: [String] = []
        /// What each part of the picture costs on the GPU (DW_PERF_PARTS).
        var parts: [String: [Double]] = [:]
        /// Every frame's main-thread milliseconds, its number and the pictures drawn in it.
        var spikes: [(ms: Double, frame: Int, pictures: Int)] = []
        var worst: String {
            spikes.sorted { $0.ms > $1.ms }.prefix(3).map { "frame \($0.frame) \(f($0.ms, 2)) ms\($0.pictures > 0 ? " (\($0.pictures) picture\($0.pictures == 1 ? "" : "s"))" : "")" }
                .joined(separator: ", ")
        }
        var summary: String {
            ([ "\(main.values.count) frames; main thread per frame \(main.text) (\(overBudget) over 8.3 ms)",
               "render (GPU) per frame \(render.text)",
               "card pictures drawn on the main thread \(picturesOnMain) (\(f(pictureMilliseconds, 1)) ms)",
               "flight windows made \(flightWindows)", "slowest main-thread frames: \(worst)" ] + notes
             + parts.keys.sorted().map { "GPU for \($0): median \(f(Stats(values: parts[$0]!).percentile(0.5), 3)) ms" }).joined(separator: "; ")
        }
    }

    /// A controller as the app has it, on offscreen surfaces, with the drag pasteboard, the button and the pointer
    /// played by the scene.
    final class Rig {
        var now: Double
        let engine: ClotheslineEngine
        let surface: ClotheslineOffscreenSurface
        let ctl: ClotheslineController
        var flight: ClotheslineFlightOffscreenSurface?
        var flightWindows = 0
        var count = 5
        var payload: [URL] = []
        var button = false
        var location = CGPoint.zero

        init() {
            now = CACurrentMediaTime()
            engine = ClotheslineEngine(geometry: sample, time: now)
            surface = ClotheslineOffscreenSurface(engine: engine)
            ctl = ClotheslineController(engine: engine, surface: surface, clock: ClotheslineManualClock(), now: { 0 })
            ctl.now = { [weak self] in self?.now ?? 0 }
            ctl.usesTimers = false
            ctl.visibleFrame = { CGRect(x: 0, y: 0, width: 1736, height: 1093) }
            ctl.dragChangeCount = { [weak self] in self?.count ?? 0 }
            ctl.dragFiles = { [weak self] in self?.payload ?? [] }
            ctl.escapeDown = { false }
            ctl.modifierFlags = { [] }
            ctl.leftButtonDown = { [weak self] in self?.button ?? false }
            ctl.pointerLocation = { [weak self] in self?.location ?? .zero }
            ctl.monitorInstaller = { ["pointer"] }
            ctl.dropMonitorInstaller = { ["drag"] }
            ctl.monitorRemover = { _ in }
            ctl.makeFlightSurface = { [weak self] g in
                let f = ClotheslineFlightOffscreenSurface(geometry: g)
                self?.flight = f
                self?.flightWindows += 1
                return f
            }
        }

        func screen(_ p: CGPoint) -> CGPoint { sample.screenPoint(fromScene: p) }

        /// Brings a line of `files` out and settles it (held open), or hides it again.
        func hangSettled(_ files: [URL], hidden: Bool) {
            ShelfThumbnails.preload(files, size: ClotheslineView.thumbnailRequest)
            ctl.hang(files)
            for _ in 0..<600 where !(engine.state == .shown && engine.pendingArrivals.isEmpty) { now += 1 / frameRate; ctl.tick(at: now) }
            engine.settleNow()
            if hidden {
                ctl.retract()
                for _ in 0..<600 where engine.state != .hidden { now += 1 / frameRate; ctl.tick(at: now) }
            } else {
                engine.holdOpen = true
            }
            ctl.tick(at: now)
        }
    }

    /// Plays a scene in real time and times every frame.
    static func measure(_ scene: Scene, fixtures: Fixtures) throws -> Result {
        let rig = Rig()
        rig.ctl.watchDrops()
        rig.hangSettled(fixtures.line, hidden: scene != .cardAlongString)
        var result = Result()
        let gpu = LayerRenderer(geometry: sample, line: rig.surface.view.layer!, flight: nil)
        defer { gpu?.detach() }
        let period = 1 / frameRate
        var next = CACurrentMediaTime()
        // The clock carries on from where setting up the line left it (that ran faster than real time).
        let offset = rig.now - next
        ClotheslineArt.drawStats = .init()
        var frame = 0
        var script: (Int) -> Bool
        let e = rig.engine, view = rig.surface.view
        var hungAt = 0.0
        var tookOff: Double?, caught: Double?, lineOut: Double?, flyingID: UUID?
        switch scene {
        case .flight:
            script = { frame in
                if frame == 0 {
                    hungAt = rig.now
                    // Copied on another display: the card comes in from this one's right edge (the longest flight).
                    rig.ctl.hang([fixtures.screenshot], from: CGPoint(x: -400, y: 300))
                    flyingID = e.items.first?.id
                }
                if let id = flyingID, let card = e.cards[id] {
                    if tookOff == nil, card.flight?.launchedAt != nil { tookOff = rig.now - hungAt }
                    if caught == nil, tookOff != nil, card.flight == nil { caught = rig.now - hungAt }
                    if lineOut == nil, e.state != .hidden { lineOut = rig.now - hungAt }
                }
                if frame > 0, e.state == .hidden, !e.hasFlights { return false }
                return frame < Int(6 * frameRate)
            }
        case .cardAlongString:
            let id = e.items[2].id
            let pose = e.pose(id)!
            let grab = ClotheslineEngine.toScene(pose, CGPoint(x: 0, y: 60))
            var p = grab
            script = { frame in
                switch frame {
                case 0:
                    rig.button = true
                    rig.location = rig.screen(p)
                    rig.ctl.mouseEvent(.down, screen: rig.location)
                    view.pressDown(at: p)
                case 1...Int(1.3 * frameRate):
                    // 700 pt/s to the right, along the string, as the drop monitors and the view's mouseDragged both see it.
                    p.x += 700 * period
                    p.y = CGFloat(e.stringY(at: Double(p.x), ends: e.lineEnds())) + grab.y - pose.pivot.y
                    rig.location = rig.screen(p)
                    rig.ctl.mouseEvent(.dragged, screen: rig.location)
                    view.pressMoved(to: p)
                    if let pin = e.heldPin, let drawn = e.pose(id), drawn.flying {
                        result.heldLag = max(result.heldLag, Double(hypot(drawn.pivot.x - pin.x, drawn.pivot.y - pin.y)))
                    }
                case Int(1.3 * frameRate) + 1:
                    rig.button = false
                    view.pressUp(at: p)
                    rig.ctl.mouseEvent(.up, screen: rig.location)
                default:
                    break
                }
                return frame < Int(2.6 * frameRate)
            }
        case .fileDrag:
            let files = [fixtures.screenshot]
            var p = CGPoint(x: 1100, y: 700)
            let up = Int(0.35 * frameRate), rest = up + Int(0.45 * frameRate), along = rest + Int(1.2 * frameRate)
            script = { frame in
                switch frame {
                case 0:
                    rig.button = true
                    rig.ctl.mouseEvent(.down, screen: rig.screen(p))
                    rig.count += 1
                    rig.payload = files
                case 1...up:
                    // Up to the notch …
                    let u = Double(frame) / Double(up)
                    p = CGPoint(x: 1100 - (1100 - 868) * u, y: 700 - (700 - 18) * u)
                    rig.ctl.mouseEvent(.dragged, screen: rig.screen(p))
                case (up + 1)...rest:
                    break
                case (rest + 1)...along:
                    // … then along the line to the left, over the panel (AppKit's dragging updates and the monitors).
                    let u = Double(frame - rest) / Double(along - rest)
                    let x = 868 - 620 * u
                    p = CGPoint(x: x, y: e.stringY(at: x, ends: e.lineEnds()) + 30)
                    rig.ctl.mouseEvent(.dragged, screen: rig.screen(p))
                    _ = rig.ctl.clotheslineDragUpdated(at: p, files: files, sourceMask: [.copy, .link, .generic])
                case along + 1:
                    rig.button = false
                    rig.ctl.mouseEvent(.up, screen: rig.screen(p))
                    _ = rig.ctl.clotheslineDrop(files, at: p)
                default:
                    break
                }
                return frame < along + Int(1.2 * frameRate)
            }
        }
        var flightLayerAttached = false
        var drawnBefore = ClotheslineArt.drawStats
        while true {
            next += period
            // Between frames the run loop runs (thumbnails arrive, as in the app).
            while CACurrentMediaTime() < next {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: max(0.0005, next - CACurrentMediaTime())))
            }
            rig.now = next + offset
            // Pictures drawn on the main thread between frames (a thumbnail arriving) count toward this frame.
            let between = max(0, ClotheslineArt.drawStats.mainSeconds - drawnBefore.mainSeconds) * 1000
            let t0 = CACurrentMediaTime()
            let go = script(frame)
            rig.ctl.tick(at: rig.now)
            CATransaction.flush()
            let ms = (CACurrentMediaTime() - t0) * 1000 + between
            let drawn = ClotheslineArt.drawStats
            let pictures = drawn.mainThread - drawnBefore.mainThread
            drawnBefore = drawn
            if !go { break }
            result.main.values.append(ms)
            result.spikes.append((ms, frame, pictures))
            if ms > 1000 / frameRate { result.overBudget += 1 }
            if let gpu {
                if !flightLayerAttached, let f = rig.flight?.view.layer {
                    // The flight window, once made, is rendered over the line from then on (as the window server has it).
                    gpu.host.sublayers?.last?.addSublayer(f)
                    flightLayerAttached = true
                }
                let whole = gpu.frame()
                result.render.values.append(whole)
                if measuresParts {
                    for part in parts(rig) where !part.hide.isEmpty {
                        let was = part.hide.map(\.isHidden)
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        part.hide.forEach { $0.isHidden = true }
                        CATransaction.commit()
                        result.parts[part.name, default: []].append(whole - gpu.frame())
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        zip(part.hide, was).forEach { $0.isHidden = $1 }
                        CATransaction.commit()
                    }
                }
            }
            frame += 1
        }
        // DW_PERF_FRAMES=<folder>: every frame's milliseconds (main thread, GPU) as CSV, one file per scene, so several
        // runs can be combined frame by frame (the least of each frame's runs is the least disturbed by other work).
        if let folder = ProcessInfo.processInfo.environment["DW_PERF_FRAMES"] {
            let rows = zip(result.main.values, result.render.values + Array(repeating: 0, count: max(0, result.main.values.count - result.render.values.count)))
                .map { "\($0),\($1)" }.joined(separator: "\n")
            try? rows.write(toFile: folder + "/\(scene)-\(ProcessInfo.processInfo.processIdentifier).csv", atomically: true, encoding: .utf8)
        }
        let stats = ClotheslineArt.drawStats
        result.picturesOnMain = stats.mainThread
        result.pictureMilliseconds = stats.mainSeconds * 1000
        result.flightWindows = rig.flightWindows
        switch scene {
        case .flight:
            result.notes.append("took off \(f(tookOff ?? -1, 3)) s after it was hung, the line started out at \(f(lineOut ?? -1, 2)) s, caught at \(f(caught ?? -1, 2)) s")
        case .cardAlongString:
            result.notes.append("the card in the hand drawn \(f(result.heldLag, 3)) pt from where the pointer holds it")
        case .fileDrag:
            result.notes.append("dropped \(e.dropCount)")
        }
        rig.ctl.shutDown()
        return result
    }

    /// DW_PERF_PARTS=1: each frame is rendered again without one part at a time (the string's glow, the whole string,
    /// the cards' shadows, the cards in the flight window), and the medians of the differences say what each part costs
    /// on the GPU (paired, so the machine's other work cancels out). A probe for the report, off by default.
    static let measuresParts = ProcessInfo.processInfo.environment["DW_PERF_PARTS"] != nil

    static func parts(_ rig: Rig) -> [(name: String, hide: [CALayer])] {
        let view = rig.surface.view
        let root = view.layer?.sublayers ?? []
        let glow = view.stringLayers.glow
        let string = root.filter { $0 !== view.cardsLayer }
        let shadows = (view.cardsLayer.sublayers ?? []).filter { $0.contents == nil && $0 !== view.ghostLayer }
        let flying = rig.flight?.view.layer?.sublayers ?? []
        return [("the string's glow", [glow]), ("the whole string", string), ("the cards' shadows", shadows),
                ("the cards in the flight window", flying)]
    }

    /// DW_PERF_STILL=<base>: the line of 16 cards as Core Animation renders it on the GPU (as the window server does),
    /// at rest (<base>-line.png) and with a file over it, the string brighter (<base>-boost.png), for side-by-side
    /// looks at the string's light.
    static func writeStills(_ c: Checker, fixtures: Fixtures, base: String) {
        let rig = Rig()
        rig.ctl.watchDrops()
        rig.hangSettled(fixtures.line, hidden: false)
        guard let gpu = LayerRenderer(geometry: sample, line: rig.surface.view.layer!, flight: nil) else { return }
        defer { gpu.detach() }
        func write(_ name: String) {
            // Core Animation's renderer shows the last committed change from the next frame on.
            _ = gpu.frame()
            _ = gpu.frame()
            guard let image = gpu.image(), let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: base + name) as CFURL,
                                                                                       UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, nil)
            c.check(CGImageDestinationFinalize(dest), "still written", base + name)
        }
        write("-line.png")
        // The string alone (the cards' last bit of give differs with the springs' tuning; the string doesn't).
        rig.surface.view.cardsLayer.isHidden = true
        write("-string.png")
        rig.surface.view.cardsLayer.isHidden = false
        let e = rig.engine
        let spot = CGPoint(x: 868 - 280, y: e.stringY(at: 868 - 280, ends: e.lineEnds()) + 20)
        rig.count += 1
        rig.payload = [fixtures.screenshot]
        rig.button = true
        rig.ctl.mouseEvent(.down, screen: rig.screen(CGPoint(x: 868, y: 18)))
        _ = rig.ctl.clotheslineDragUpdated(at: spot, files: [fixtures.screenshot], sourceMask: [.copy, .link, .generic])
        for _ in 0..<Int(1.5 * frameRate) { rig.now += 1 / frameRate; rig.ctl.tick(at: rig.now) }
        write("-boost.png")
        rig.surface.view.cardsLayer.isHidden = true
        write("-boost-string.png")
        rig.ctl.shutDown()
    }

    // MARK: Pictures

    /// How long a card's picture takes: a big screenshot's thumbnail until it arrives (Quick Look's, and ImageIO's off
    /// the main thread as the line loads it), and drawing the card with it.
    static func pictureCosts(_ c: Checker, fixtures: Fixtures) {
        func wait(_ name: String, _ load: (URL, @escaping (ShelfThumbnail) -> Void) -> Void) -> (ms: Double, picture: ShelfThumbnail?) {
            // A fresh copy, so nothing is cached.
            let copy = fixtures.dir.appendingPathComponent("Screenshot \(name).png")
            try? FileManager.default.copyItem(at: fixtures.screenshot, to: copy)
            let started = CACurrentMediaTime()
            var arrived: Double?
            var picture: ShelfThumbnail?
            load(copy) { t in arrived = CACurrentMediaTime(); picture = t }
            let deadline = Date().addingTimeInterval(5)
            while arrived == nil && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002)) }
            return (arrived.map { ($0 - started) * 1000 } ?? -1, picture)
        }
        let ql = wait("ql") { ShelfThumbnails.load($0, size: ClotheslineView.thumbnailRequest, completion: $1) }
        let io = wait("io") { ClotheslinePictures.load($0, size: ClotheslineView.thumbnailRequest, completion: $1) }
        func draw(_ t: ShelfThumbnail?) -> Double {
            guard let t else { return -1 }
            let content = ClotheslineArt.CardContent(name: "Screenshot.png", thumbnail: t.image, isIcon: t.isIcon, duration: nil)
            let t0 = CACurrentMediaTime()
            _ = ClotheslineArt.cardImage(content, width: 150, dark: false, scale: 2)
            return (CACurrentMediaTime() - t0) * 1000
        }
        func size(_ t: ShelfThumbnail?) -> String { t.map { "\(Int($0.image.size.width)) × \(Int($0.image.size.height)) pt" } ?? "none" }
        c.check(true, "a 3456 × 2234 screenshot's picture",
                "Quick Look's thumbnail after \(f(ql.ms, 1)) ms (\(size(ql.picture)); first card drawn with it \(f(draw(ql.picture), 2)) ms), "
                + "ImageIO's off the main thread after \(f(io.ms, 1)) ms (\(size(io.picture)); first card drawn with it \(f(draw(io.picture), 2)) ms)")
    }

    /// The string's own work in a frame: the view's render(), and the glow's blur alone.
    static func stringCosts(_ c: Checker) {
        let e = ClotheslineTests.shownEngine(16)
        let view = ClotheslineView(engine: e, frame: CGRect(origin: .zero, size: sample.panelFrame.size))
        view.itemsChanged()
        let t0 = CACurrentMediaTime()
        for _ in 0..<200 { view.render() }
        let render = (CACurrentMediaTime() - t0) / 200 * 1000
        let points = e.stringPoints().map { CGPoint(x: $0.x, y: 300 - $0.y) }
        let path = CGMutablePath()
        path.addLines(between: points)
        let t1 = CACurrentMediaTime()
        for _ in 0..<200 { _ = ClotheslineView.glowBlurImage(path, lineWidth: 4.5, radius: 6) }
        let blur = (CACurrentMediaTime() - t1) / 200 * 1000
        c.check(true, "the view's render() with 16 still cards", "\(f(render, 3)) ms (the glow's blur alone \(f(blur, 3)) ms)")
    }

    /// Making the real flight window (not shown).
    static func flightWindowCost(_ c: Checker) {
        let t0 = CACurrentMediaTime()
        let s = ClotheslineFlightPanelSurface(geometry: sample)
        let ms = (CACurrentMediaTime() - t0) * 1000
        s.panel.close()
        c.check(true, "making the flight window (1736 × 1133 pt, not shown)", "\(f(ms, 2)) ms")
    }

    static func f(_ x: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", x) }
}
#endif
