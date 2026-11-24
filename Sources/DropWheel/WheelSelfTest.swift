#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import AVFoundation

/// `--selftest wheel`: the drag wheel's geometry, hit-testing, labels, colours, motion, panel and sound.
enum WheelSelfTest {
    typealias Checker = AppShellTests.Checker

    static func run() -> String {
        let c = Checker()
        geometry(c)
        hitTesting(c)
        labels(c)
        colours(c)
        rendering(c)
        motion(c)
        viewAPI(c)
        panel(c)
        sound(c)
        convertPetals(c)
        return c.report("wheel")
    }

    static func fmt(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
    static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
    static func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.01) -> Bool { abs(a - b) <= tolerance }

    // MARK: Geometry

    static func geometry(_ c: Checker) {
        c.check("label radius is 84.53", near(WheelMetrics.labelRadius, 84.5312, 0.001), fmt(WheelMetrics.labelRadius))
        c.check("backdrop reaches 6.4 pt past the petals on both sides",
                near(WheelMetrics.innerRadius - WheelMetrics.backdropInner, 6.4) && near(WheelMetrics.backdropOuter - WheelMetrics.outerRadius, 6.4))
        c.check("panel is 372 pt for up to 8 petals (one ring)", (0...8).allSatisfy { WheelLayout.diameter(for: $0) == 372 })
        c.check("panel margin around the backdrop is 60.08 pt", near(WheelMetrics.panelMargin, 60.08))

        let std = WheelLayout(count: 8, bounds: CGRect(x: 0, y: 0, width: 372, height: 372))
        c.check("standard ring: 48.64…119.52, gap 5, backdrop 42.24…125.92, scale 1",
                std.scale == 1 && near(std.inner, 48.64) && near(std.outer, 119.52) && near(std.gap, 5)
                && near(std.backdropInner, 42.24) && near(std.backdropOuter, 125.92))
        c.check("one ring up to 8 petals, two beyond", (1...24).allSatisfy { n in
            let l = WheelLayout(count: n, bounds: CGRect(x: 0, y: 0, width: 600, height: 600))
            return n <= 8 ? (l.rings.count == 1 && l.rings[0].count == n)
                          : (l.rings.count == 2 && l.rings[0].count + l.rings[1].count == n && l.rings[0].count >= 3 && l.rings[1].count >= 3)
        })

        // The petal at 12 o'clock reaches exactly the inner and outer radius.
        let four = WheelLayout(count: 4, bounds: CGRect(x: 0, y: 0, width: 372, height: 372))
        let petal0 = four.path(0)
        func onRay(_ r: CGFloat) -> Bool { petal0.contains(CGPoint(x: 186, y: 186 + r)) }
        c.check("petal spans 48.64…119.52 from the centre", !onRay(48.4) && onRay(48.9) && onRay(119.3) && !onRay(119.8))
        // Constant 5 pt gap: on the dividing line between petals 0 and 1 (at 45° clockwise of 12 o'clock) nothing
        // is a petal within 2.3 pt; 2.8 pt to either side is.
        var gapOK = true
        for r in stride(from: CGFloat(62), through: 96, by: 2) {
            let a = CGFloat.pi / 4                       // mathematical angle of the dividing line
            let onLine = CGPoint(x: 186 + r * cos(a), y: 186 + r * sin(a))
            let n = CGPoint(x: -sin(a), y: cos(a))      // perpendicular
            func off(_ d: CGFloat) -> CGPoint { CGPoint(x: onLine.x + n.x * d, y: onLine.y + n.y * d) }
            let paths = (0..<4).map(four.path)
            let none = !paths.contains { $0.contains(onLine) || $0.contains(off(2.3)) || $0.contains(off(-2.3)) }
            let both = paths[0].contains(off(2.8)) && paths[1].contains(off(-2.8))
            if !(none && both) { gapOK = false }
        }
        c.check("gap between petals is a constant 5 pt", gapOK)
        // Corner sizes for 8 petals (from the shape's own formula): inner corner 5.97 pt along the arc.
        let sector = 2 * CGFloat.pi / 8, half = asin(2.5 / CGFloat(48.64))
        let ac = min((sector - 2 * half) * 0.18, 0.18)
        c.check("8 petals: inner corner spans 5.97 pt", near(ac * 48.64, 5.97, 0.01), fmt(ac * 48.64))

        // More than 8 petals: a second ring 5 pt outside the first, 66 pt deep; petals in both rings about as wide.
        var twoOK = true, notes: [String] = []
        for n in 9...24 {
            let d = WheelLayout.diameter(for: n)
            let l = WheelLayout(count: n, bounds: CGRect(x: 0, y: 0, width: d, height: d))
            guard l.rings.count == 2, l.scale == 1 else { twoOK = false; continue }
            let a = l.rings[0], b = l.rings[1]
            let wa = (a.inner + a.outer) / 2 * a.sector, wb = (b.inner + b.outer) / 2 * b.sector
            if !near(b.inner, 124.52) || !near(b.outer, 190.52) || max(wa, wb) / min(wa, wb) > 1.6 { twoOK = false }
            if [9, 12, 16, 24].contains(n) { notes.append("\(n): \(a.count)+\(b.count), panel \(Int(d)) pt") }
        }
        c.check("more than 8 petals: two rings, petals in both about as wide", twoOK)
        c.notes.append("rings per count — " + notes.joined(separator: "; "))

        // A smaller view shrinks the wheel to fit its backdrop; a larger one never enlarges it.
        let preview = WheelLayout(count: 6, bounds: CGRect(x: 0, y: 0, width: 232, height: 232))
        c.check("232 pt preview shrinks the wheel to fit", near(preview.scale, 232 / 251.84, 0.001) && preview.backdropRadius * 2 <= 232.01,
                fmt(preview.scale))
        let big = WheelLayout(count: 6, bounds: CGRect(x: 0, y: 0, width: 600, height: 600))
        c.check("a large view keeps full size", big.scale == 1)
        c.check("capsule is 70 × 36", std.capsuleRect.size == CGSize(width: 70, height: 36))
    }

    // MARK: Hit-testing

    static func hitTesting(_ c: Checker) {
        for count in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 16, 24] {
            for side in [WheelLayout.diameter(for: count), 232] {
                let layout = WheelLayout(count: count, bounds: CGRect(x: 0, y: 0, width: side, height: side))
                let paths = (0..<count).map(layout.path)
                var drawn = 0, mismatched = 0, overlaps = 0, extra = 0
                var hits = [Int](repeating: 0, count: count)
                let step: CGFloat = 2
                var y: CGFloat = 0.5
                while y < side {
                    var x: CGFloat = 0.5
                    while x < side {
                        let p = CGPoint(x: x, y: y)
                        let inside = paths.indices.filter { paths[$0].contains(p) }
                        let hit = layout.index(at: p)
                        if inside.count > 1 { overlaps += 1 }
                        if let d = inside.first { drawn += 1; if hit != d { mismatched += 1 } } else if hit != nil { extra += 1 }
                        if let hit { hits[hit] += 1 }
                        x += step
                    }
                    y += step
                }
                let label = "\(count) petals at \(Int(side)) pt"
                c.check("\(label): drawn points hit their own petal", mismatched == 0, "\(mismatched) of \(drawn)")
                c.check("\(label): gaps and edges are no petal", extra == 0, "\(extra) points")
                c.check("\(label): petals never overlap", overlaps == 0, "\(overlaps) points")
                c.check("\(label): every petal can be hit", hits.allSatisfy { $0 > 0 })
                c.check("\(label): the centre and capsule are no petal", layout.index(at: layout.center) == nil
                        && layout.index(at: CGPoint(x: layout.center.x + layout.centerRadius - 1, y: layout.center.y)) == nil)
                c.check("\(label): outside the ring is no petal",
                        layout.index(at: CGPoint(x: layout.center.x, y: layout.center.y + layout.outer + 0.5)) == nil)
                for i in 0..<count where layout.index(at: layout.labelAnchors(i)[0]) != i {
                    c.check("\(label): label point of petal \(i) is in petal \(i)", false)
                }
            }
        }
        // Order: petal 0 at 12 o'clock, then clockwise; three petals start at 9 o'clock.
        let five = WheelLayout(count: 5, bounds: CGRect(x: 0, y: 0, width: 372, height: 372))
        func at(_ l: WheelLayout, _ deg: CGFloat) -> Int? { l.index(at: l.point(radius: 84, clockAngle: deg * .pi / 180)) }
        c.check("petal 0 is centred at 12 o'clock", at(five, 0) == 0 && at(five, -25) == 0 && at(five, 25) == 0)
        c.check("petals run clockwise", at(five, 72) == 1 && at(five, 144) == 2 && at(five, 288) == 4)
        let three = WheelLayout(count: 3, bounds: CGRect(x: 0, y: 0, width: 372, height: 372))
        c.check("three petals start at 9 o'clock", at(three, 270) == 0 && at(three, 30) == 1 && at(three, 150) == 2)
        let turned = WheelLayout(count: 4, bounds: CGRect(x: 0, y: 0, width: 372, height: 372), rotation: .pi / 2)
        c.check("rotation turns the ring clockwise", at(turned, 90) == 0 && at(turned, 180) == 1)
    }

    // MARK: Labels

    static func labels(_ c: Checker) {
        for mode in WheelMode.allCases {
            let samples = AppShell.sampleItems(mode)
            for count in [4, 6, 8, 10, 12, 16] {
                let items = Array(samples.prefix(count))
                let d = WheelLayout.diameter(for: count)
                let layout = WheelLayout(count: count, bounds: CGRect(x: 0, y: 0, width: d, height: d))
                let labels = items.indices.map { PetalLabel.fit(items[$0], petal: $0, in: layout) }
                let cut = labels.indices.filter { labels[$0].truncated }.map { items[$0].title }
                // Up to 12 petals every name fits whole; 16 is a stress case where the longest may be cut.
                if count <= 12 { c.check("\(mode.rawValue) × \(count): no label is cut short", cut.isEmpty, cut.joined(separator: ", ")) }
                else if !cut.isEmpty { c.notes.append("\(mode.rawValue) × \(count): cut short: \(cut.joined(separator: ", "))") }
                c.check("\(mode.rawValue) × \(count): symbols kept",
                        items.indices.allSatisfy { (items[$0].symbol == nil) == (labels[$0].symbol == nil) })
                for (i, l) in labels.enumerated() where !l.truncated {
                    let pad = PetalLabel.padding(layout, overhang: l.overhangs) - 0.01
                    c.check("\(mode.rawValue) × \(count): label \(i) stays on its petal",
                            !l.parts.isEmpty && l.parts.allSatisfy { layout.fits($0.size, at: CGPoint(x: $0.midX, y: $0.midY), in: i, padding: pad) })
                }
                let overhanging = labels.indices.filter { labels[$0].overhangs }.map { items[$0].title }
                let sizes = labels.map { $0.font.pointSize }
                let isFormat = mode == .convert
                let floor: CGFloat = isFormat ? 9 : PetalLabel.toolSize * 0.75
                c.check("\(mode.rawValue) × \(count): text at least \(fmt(floor)) pt", (sizes.min() ?? floor) >= floor - 0.01)
                let full = labels.filter { abs($0.font.pointSize - (isFormat ? PetalLabel.formatSize : PetalLabel.toolSize)) < 0.01 }.count
                let twoLine = labels.indices.filter { labels[$0].lines.count == 2 }.map { items[$0].title }
                c.notes.append("\(mode.rawValue) × \(count): \(full)/\(count) at full size, text \(fmt(sizes.min() ?? 0))–\(fmt(sizes.max() ?? 0)) pt"
                               + (twoLine.isEmpty ? "" : ", two lines: \(twoLine.joined(separator: ", "))")
                               + (overhanging.isEmpty ? "" : ", reaching into the gap: \(overhanging.joined(separator: ", "))"))
            }
        }
        // Standard settings.
        let layout = WheelLayout(count: 6, bounds: CGRect(x: 0, y: 0, width: 372, height: 372))
        let jpg = PetalLabel.fit(WheelItem(title: "JPG", symbol: nil, handler: { _ in }), petal: 0, in: layout)
        c.check("format label: 10.5 pt medium, +0.5 tracking, upper case, at radius 84.53",
                near(jpg.font.pointSize, 10.5) && near(jpg.kern, 0.5) && jpg.lines == ["JPG"]
                && near(hypot(jpg.anchor.x - 186, jpg.anchor.y - 186), 84.53, 0.01)
                && (jpg.font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])
                    .flatMap { $0[.weight] as? CGFloat }.map { abs($0 - NSFont.Weight.medium.rawValue) < 0.01 } == true)
        let tool = PetalLabel.fit(WheelItem(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", handler: { _ in }), petal: 0, in: layout)
        c.check("tool label: 11.5 pt symbol in a 13 pt box, 3 pt gap, 8.25 pt upper-case text with +0.45 tracking",
                near(tool.symbolPointSize, 11.5) && near(tool.symbolHeight, 13) && near(tool.spacing, 3)
                && near(tool.font.pointSize, 8.25) && near(tool.kern, 0.45) && tool.symbol != nil && tool.lines == ["COMPRESS"])
        let long = WheelItem(title: "Supercalifragilisticexpialidocious Conversion", symbol: "star", handler: { _ in })
        let crowded = WheelLayout(count: 16, bounds: CGRect(x: 0, y: 0, width: 474, height: 474))
        let fitted = PetalLabel.fit(long, petal: 3, in: crowded)
        c.check("an impossible title is cut, not overflowing", fitted.truncated)
        c.check("two-line splits are balanced", PetalLabel.twoLineSplits("Read QR Code").first == ["Read", "QR Code"]
                && PetalLabel.twoLineSplits("Strip Metadata").first == ["Strip", "Metadata"]
                && PetalLabel.twoLineSplits("Markdown").isEmpty)

        // Centre capsule text.
        let convert = WheelCenterLabel.fit("Convert", scale: 1)
        c.check("centre text: 9.5 pt medium, +0.35 tracking, one line", near(convert.font.pointSize, 9.5) && near(convert.kern, 0.35)
                && convert.lines == ["Convert"] && !convert.compact)
        let nothing = WheelCenterLabel.fit("Nothing for these files", scale: 1)
        c.check("long centre text goes compact on two lines, inside 58 × 28", nothing.compact && nothing.lines.count == 2
                && CGFloat(nothing.lines.count) * nothing.lineHeight <= 28.5
                && nothing.lines.allSatisfy { PetalLabel.textWidth($0, nothing.font, nothing.kern) <= 58 },
                "\(nothing.lines) at \(fmt(nothing.font.pointSize)) pt")

        let started = ProcessInfo.processInfo.systemUptime
        let timed = WheelView(frame: CGRect(x: 0, y: 0, width: 474, height: 474))
        timed.items = AppShell.sampleItems(.tools)
        _ = timed.labels
        let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
        c.check("laying out 16 petals takes under 50 ms", ms < 50, fmt(ms))
        c.notes.append("layout of 16 petals with label fitting: \(fmt(ms)) ms")
    }

    // MARK: Colours

    static func colours(_ c: Checker) {
        c.check("brand base is dahlia #E2669C", DWPalette.hex(DWPalette.base) == "#E2669C")
        c.check("brand glow is butter #FFE1A1", DWPalette.hex(DWPalette.glow) == "#FFE1A1")
        c.check("the wheel highlights in the brand colour", DWPalette.hex(DWPalette.wheelAccent) == "#E2669C")
        // The derivation (42 % toward white, and the deep shade) reproduces the reference orange stops from their
        // accent, so ours are derived the same way.
        let orange = NSColor(srgbRed: 1, green: 82 / 255.0, blue: 0, alpha: 1)
        let ref = [DWPalette.mix(orange, .white, 0.42), DWPalette.srgb(orange), DWPalette.deep(orange)]
        func close(_ a: NSColor, _ hex: String) -> Bool {
            guard let b = NSColor(hex: hex)?.usingColorSpace(.sRGB) else { return false }
            let x = DWPalette.srgb(a)
            return abs(x.redComponent - b.redComponent) <= 4 / 255 && abs(x.greenComponent - b.greenComponent) <= 4 / 255
                && abs(x.blueComponent - b.blueComponent) <= 4 / 255
        }
        c.check("gradient rule matches the reference (#FF9B6B, #FF5200, #BD3D00)",
                close(ref[0], "#FF9B6B") && close(ref[1], "#FF5200") && close(ref[2], "#BD3D00"),
                ref.map { DWPalette.hex($0) }.joined(separator: " "))

        let layout = WheelLayout(count: 8, bounds: CGRect(x: 0, y: 0, width: 372, height: 372))
        let light = NSAppearance(named: .aqua)!, dark = NSAppearance(named: .darkAqua)!
        let gl = WheelPainter(style: .glass, appearance: light, layout: layout)
        let gd = WheelPainter(style: .glass, appearance: dark, layout: layout)
        let ml = WheelPainter(style: .metallic, appearance: light, layout: layout)
        func is_(_ a: NSColor, white w: CGFloat, alpha: CGFloat) -> Bool {
            let s = DWPalette.srgb(a)
            return near(s.redComponent, w) && near(s.greenComponent, w) && near(s.blueComponent, w) && near(s.alphaComponent, alpha)
        }
        c.check("glass light: dark grey labels (#3A3A3C), white on the highlight", DWPalette.hex(gl.labelColor(highlighted: false)) == "#3A3A3C"
                && is_(gl.labelColor(highlighted: true), white: 1, alpha: 0.96))
        c.check("glass dark: white labels", is_(gd.labelColor(highlighted: false), white: 1, alpha: 0.96)
                && is_(gd.labelColor(highlighted: true), white: 1, alpha: 0.96))
        c.check("metallic: white labels, black on the highlight", is_(ml.labelColor(highlighted: false), white: 1, alpha: 0.96)
                && is_(ml.labelColor(highlighted: true), white: 0, alpha: 1))
        c.check("centre text: dark grey on light glass, white on metal", DWPalette.hex(gl.centerTextColor) == "#3A3A3C"
                && is_(ml.centerTextColor, white: 1, alpha: 1) && is_(gd.centerTextColor, white: 1, alpha: 0.96))
    }

    // MARK: Rendering

    struct Rendered {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let scale: CGFloat

        /// The sRGB colour at a point (origin bottom-left, in points).
        func color(at p: CGPoint) -> NSColor {
            let x = min(max(Int(p.x * scale), 0), width - 1)
            let row = min(max(height - 1 - Int(p.y * scale), 0), height - 1)
            let o = (row * width + x) * 4
            let a = CGFloat(pixels[o + 3]) / 255
            guard a > 0 else { return .clear }
            return NSColor(srgbRed: CGFloat(pixels[o]) / 255 / a, green: CGFloat(pixels[o + 1]) / 255 / a,
                           blue: CGFloat(pixels[o + 2]) / 255 / a, alpha: a)
        }
    }

    /// Renders the wheel the way `--snapshot wheel` does (glass painted by hand, over the desktop gradient).
    static func render(style: WheelStyle, dark: Bool, count: Int, highlight: Int?, mode: WheelMode = .tools,
                       background: Bool = true, opening: CFTimeInterval? = nil) -> Rendered? {
        let size = WheelLayout.diameter(for: count)
        let container = background ? AppShellSnapshotBackground(color: nil) : NSView()
        container.frame = CGRect(x: 0, y: 0, width: size, height: size)
        let wheel = WheelView(frame: container.bounds)
        wheel.style = style
        wheel.playsFeedback = false
        wheel.modeTitle = mode.rawValue
        wheel.items = Array(AppShell.sampleItems(mode).prefix(count))
        wheel.setHighlight(highlight)
        if let opening { wheel.pauseIntro(at: opening) }
        container.addSubview(wheel)
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        let w = Int(size * 2), h = Int(size * 2)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: 2, y: 2)
        container.displayIgnoringOpacity(container.bounds, in: NSGraphicsContext(cgContext: ctx, flipped: false))
        guard let data = ctx.data else { return nil }
        return Rendered(pixels: Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4)),
                        width: w, height: h, scale: 2)
    }

    static func rendering(_ c: Checker) {
        let layout = WheelLayout(count: 8, bounds: CGRect(x: 0, y: 0, width: 372, height: 372))
        let brandHue = DWPalette.srgb(DWPalette.base).hueComponent
        for dark in [false, true] {
            let name = "glass \(dark ? "dark" : "light")"
            guard let r = render(style: .glass, dark: dark, count: 8, highlight: 0) else { c.check("\(name): renders", false); continue }
            let hub = r.color(at: layout.point(radius: 52, clockAngle: 0))
            let rim = r.color(at: layout.point(radius: 116, clockAngle: 0))
            let mid = r.color(at: layout.point(radius: 96, clockAngle: 0.12))
            let dh = abs(mid.hueComponent - brandHue)
            c.check("\(name): highlighted petal is the brand colour", min(dh, 1 - dh) < 0.04 && mid.saturationComponent > 0.45,   // dahlia pink is a softer colour than a pure blue
                    "hue \(fmt(mid.hueComponent)) vs \(fmt(brandHue))")
            c.check("\(name): highlight is lighter at the hub than at the rim", hub.brightnessComponent > rim.brightnessComponent + 0.15
                    && hub.saturationComponent < rim.saturationComponent, "hub \(DWPalette.hex(hub)) rim \(DWPalette.hex(rim))")
            // White label on the highlight, sampled around the label away from its glyphs.
            var worst = 99.0
            // Beside the (smaller) symbol and name.
            for (radius, da) in [(CGFloat(60), CGFloat(0.0)), (110, 0), (84.5, 0.28), (84.5, -0.28)] {
                worst = min(worst, WheelPainter.contrast(.white, r.color(at: layout.point(radius: radius, clockAngle: da))))
            }
            c.notes.append("\(name): white label on the highlight at the label ring ≥ \(fmt(worst)):1; hub \(DWPalette.hex(hub)), rim \(DWPalette.hex(rim))")
            c.check("\(name): highlighted label readable (≥ 3:1 around it)", worst >= 3, fmt(worst))
            // A plain petal is not the brand colour.
            let plain = r.color(at: layout.point(radius: 84.5, clockAngle: .pi))
            c.check("\(name): plain petals stay neutral", plain.saturationComponent < 0.35, DWPalette.hex(plain))
        }
        if let m = render(style: .metallic, dark: false, count: 8, highlight: 0) {
            let plain = m.color(at: layout.point(radius: 84.5, clockAngle: .pi + 0.2))
            c.check("metallic: plain petals are graphite #242424", DWPalette.hex(plain) == "#242424", DWPalette.hex(plain))
            let ring = m.color(at: layout.point(radius: 45.5, clockAngle: 0.4))
            c.check("metallic: backdrop is black", DWPalette.hex(ring) == "#000000", DWPalette.hex(ring))
            let rim = m.color(at: layout.point(radius: 114, clockAngle: 0.15)), hub = m.color(at: layout.point(radius: 54, clockAngle: 0.15))
            c.check("metallic: highlight is steel, darker at the rim", rim.saturationComponent < 0.05 && hub.brightnessComponent > rim.brightnessComponent,
                    "rim \(DWPalette.hex(rim)) hub \(DWPalette.hex(hub))")
            c.check("metallic: black label on steel ≥ 4.5:1", WheelPainter.contrast(.black, rim) >= 4.5)
            let capsule = m.color(at: CGPoint(x: 186 + 30, y: 186))
            c.check("metallic: centre capsule is black", DWPalette.hex(capsule) == "#000000", DWPalette.hex(capsule))
        } else {
            c.check("metallic renders", false)
        }
        // No shadow: with no background, nothing outside the backdrop is painted.
        if let bare = render(style: .metallic, dark: false, count: 8, highlight: nil, background: false) {
            var painted = 0
            for k in 0..<72 {
                let a = CGFloat(k) * .pi / 36
                if bare.color(at: CGPoint(x: 186 + 129 * cos(a), y: 186 + 129 * sin(a))).alphaComponent > 0.01 { painted += 1 }
            }
            c.check("no shadow outside the wheel", painted == 0, "\(painted) of 72 points painted")
        }
        // Opening: at the start every petal is a slice of one 50.4 pt disc.
        if let early = render(style: .metallic, dark: false, count: 8, highlight: nil, background: false, opening: 0) {
            let inside = early.color(at: CGPoint(x: 186 + 30, y: 186 + 20)).alphaComponent > 0.9
            let outside = early.color(at: CGPoint(x: 186 + 60, y: 186)).alphaComponent < 0.01
            c.check("opening starts as a 50.4 pt disc", inside && outside)
        }
    }

    // MARK: Motion

    static func motion(_ c: Checker) {
        let start = WheelMotion.state(at: 0), end = WheelMotion.state(at: WheelMotion.total)
        c.check("opening starts closed and ends open", start == .closed && end == .open)
        let s1 = WheelMotion.state(at: 0.1).shape, s2 = WheelMotion.state(at: 0.2).shape
        let s0 = WheelMotion.state(at: 0.03).shape
        c.check("bloom: a critically damped spring with a push (≈30% at 30 ms, ≈75% at 0.1 s, ≈95% at 0.2 s)",
                s0 > 0.25 && s0 < 0.36 && s1 > 0.7 && s1 < 0.8 && s2 > 0.93 && s2 < 0.98, "\(fmt(s0)) \(fmt(s1)) \(fmt(s2))")
        c.check("edges and colours show while the petals grow (full by 0.07 s)",
                WheelMotion.state(at: 0.03).borders > 0.2 && WheelMotion.state(at: 0.07).borders == 1)
        c.check("labels fade in during the second half of the growth",
                WheelMotion.state(at: 0.03).labels == 0 && WheelMotion.state(at: 0.12).labels > 0.5 && WheelMotion.state(at: 0.3).labels == 1)
        var monotonic = true, overshoot = false, last: CGFloat = -1
        for k in 0...200 {
            let v = WheelMotion.spring(Double(k) / 200 * WheelMotion.total)
            if v < last - 1e-6 { monotonic = false }
            if v > 1 { overshoot = true }
            last = v
        }
        c.check("bloom rises steadily and never overshoots", monotonic && !overshoot)
        c.check("the last step to fully open is too small to see (< 0.3%)", 1 - WheelMotion.spring(WheelMotion.total - 1.0 / 120) < 0.003)
        c.check("panel fades in over 0.04 s", WheelMotion.panelFade == 0.04)

        // The opening plays on a live view and ends fully open.
        let view = WheelView(frame: CGRect(x: 0, y: 0, width: 372, height: 372))
        view.items = Array(AppShell.sampleItems(.convert).prefix(8))
        view.playIntro()
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        c.check("opening starts closed (or open with Reduce Motion)", view.bloom == (reduce ? .open : .closed))
        let until = Date().addingTimeInterval((WheelMotion.total + 0.1) * WheelView.motionScale)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        c.check("opening ends fully open", view.bloom == .open)
    }

    // MARK: View API

    static func viewAPI(_ c: Checker) {
        let view = WheelView(frame: CGRect(x: 0, y: 0, width: 372, height: 372))
        view.playsFeedback = false
        view.items = Array(AppShell.sampleItems(.tools).prefix(6))
        view.setHighlight(9)
        c.check("out-of-range highlight is ignored", view.highlighted == nil)
        view.setHighlight(2)
        c.check("setHighlight", view.highlighted == 2 && view.centerText == view.items[2].title)
        view.items = Array(view.items.prefix(5))
        c.check("new items clear the highlight", view.highlighted == nil && view.centerText == view.modeTitle)
        let l = view.layout
        view.track(l.point(radius: 84, clockAngle: 0))
        c.check("tracking highlights the petal under the pointer", view.highlighted == 0)
        let gapAngle = CGFloat.pi / 5   // the line between petals 0 and 1 of five
        view.track(l.point(radius: 84, clockAngle: gapAngle))
        c.check("in a gap the highlight stays on the petal it came from", view.highlighted == 0 && l.index(at: l.point(radius: 84, clockAngle: gapAngle)) == nil)
        view.track(l.center)
        c.check("the centre clears the highlight", view.highlighted == nil)
        view.track(l.point(radius: 84, clockAngle: 0))
        view.track(l.point(radius: l.outer + 3, clockAngle: 0))
        c.check("outside the ring clears the highlight", view.highlighted == nil)
        c.check("preferred sizes", WheelView.preferredDiameter(for: 8) == 372 && WheelView.preferredDiameter(for: 0) == 372
                && WheelView.preferredDiameter(for: 16) > 372)
        c.check("hit-testing follows a resized view", {
            view.setFrameSize(CGSize(width: 200, height: 200))
            defer { view.setFrameSize(CGSize(width: 372, height: 372)) }
            return view.index(at: CGPoint(x: 100, y: 100 + 60)) == 0 && view.index(at: CGPoint(x: 100, y: 100)) == nil
        }())
        let empty = WheelView(frame: CGRect(x: 0, y: 0, width: 372, height: 372))
        c.check("an empty wheel says so", empty.centerText == "Nothing for these files" && empty.index(at: CGPoint(x: 186, y: 260)) == nil)
    }

    // MARK: Panel

    static func panel(_ c: Checker) {
        let overlay = OverlayController()
        let p = overlay.panel
        c.check("panel: 372 pt, clear, shadowless, pop-up level", p.frame.size == CGSize(width: 372, height: 372) && !p.isOpaque
                && !p.hasShadow && p.backgroundColor == .clear && p.level == .popUpMenu)
        c.check("panel: non-activating, never hides on deactivate, no window animation",
                p.styleMask.contains(.nonactivatingPanel) && !p.hidesOnDeactivate && p.animationBehavior == .none && !p.canBecomeKey)
        let wanted: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .transient, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        c.check("panel: joins all spaces, transient, stationary, full-screen auxiliary", p.collectionBehavior == wanted,
                String(p.collectionBehavior.rawValue, radix: 16))
        overlay.hide()
        c.check("hiding a hidden wheel is harmless", !overlay.isVisible)

        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let mid = OverlayController.panelFrame(anchor: CGPoint(x: 700, y: 400), diameter: 372, visibleFrame: screen)
        c.check("panel is centred on the cursor", mid.midX == 700 && mid.midY == 400 && mid.width == 372)
        let corner = OverlayController.panelFrame(anchor: CGPoint(x: 10, y: 870), diameter: 474, visibleFrame: screen)
        c.check("panel stays on screen in a corner", corner.minX == 0 && corner.maxY == 875)
        let right = OverlayController.panelFrame(anchor: CGPoint(x: 1439, y: 5), diameter: 372, visibleFrame: screen)
        c.check("panel stays on screen at the bottom right", right.maxX == 1440 && right.minY == 0)
        let tiny = OverlayController.panelFrame(anchor: CGPoint(x: 50, y: 50), diameter: 474,
                                                visibleFrame: CGRect(x: 0, y: 0, width: 300, height: 300))
        c.check("a screen smaller than the wheel pins it to the corner", tiny.origin == .zero)
        let second = OverlayController.panelFrame(anchor: CGPoint(x: 1500, y: -300), diameter: 372,
                                                  visibleFrame: CGRect(x: 1440, y: -1080, width: 1920, height: 1055))
        c.check("works on a screen with negative coordinates", second.minX == 1440 && second.midY == -300)
    }

    // MARK: Sound

    static func sound(_ c: Checker) {
        func db(_ v: Double) -> Double { 20 * log10(max(v, 1e-9)) }
        var rendered: [PetalSoundStyle: [Float]] = [:]
        for style in PetalSoundStyle.allCases {
            let x = PetalSound.samples(style)
            rendered[style] = x
            let ms = Double(x.count) / 48
            let peak = Double(x.map(abs).max() ?? 0)
            let onset = x.firstIndex { Double(abs($0)) > peak * 0.3 } ?? x.count
            let tail = Double(x.suffix(48).map(abs).max() ?? 0)
            let name = style.title
            c.check("\(name): 30–130 ms long", ms >= 30 && ms <= 130, fmt(ms))
            c.check("\(name): peaks at −17 dBFS or lower, and is audible", db(peak) <= -16.9 && db(peak) > -26, fmt(db(peak)))
            c.check("\(name): starts within 1.5 ms (no lag behind the highlight)", Double(onset) / 48 <= 1.5, fmt(Double(onset) / 48))
            c.check("\(name): ends in silence", tail < 0.002, fmt(tail))
            c.check("\(name): has a title and a description", !style.title.isEmpty && style.detail.hasSuffix("."))
            c.notes.append("\(name): \(fmt(ms)) ms, peak \(fmt(db(peak))) dBFS")
        }
        let distinct = Set(PetalSoundStyle.allCases.map { rendered[$0]!.prefix(400).map { Int($0 * 1000) } }).count
        c.check("every sound is different", distinct == PetalSoundStyle.allCases.count, "\(distinct)")
        c.check("the same sound renders identically every time", PetalSound.samples(.dial) == rendered[.dial]!)

        let wav = PetalSound.wav(rendered[.dial]!)
        func u32(_ o: Int) -> UInt32 { wav[o..<o + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
        func u16(_ o: Int) -> UInt16 { wav[o..<o + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian }
        let header = String(decoding: wav.prefix(4), as: UTF8.self) + String(decoding: wav[8..<12], as: UTF8.self)
        c.check("preview WAV is RIFF/WAVE, 16-bit mono at 48 kHz", header == "RIFFWAVE" && u16(20) == 1 && u16(22) == 1
                && u32(24) == 48_000 && u16(34) == 16)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-tick-\(ProcessInfo.processInfo.processIdentifier).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        if (try? wav.write(to: tmp)) != nil, let file = try? AVAudioFile(forReading: tmp) {
            c.check("AVAudioFile reads it back", file.fileFormat.sampleRate == 48_000 && file.length == AVAudioFramePosition(rendered[.dial]!.count))
        } else {
            c.check("AVAudioFile reads it back", false)
        }

        // Speed: one tick per petal crossed; faster sweeps run higher, shorter and a little quieter.
        let slow = PetalSound.plan(steps: 1, interval: 0.5)
        c.check("a slow move plays one tick as made", slow == [PetalSound.Tick(delay: 0, rate: 1, volume: 1)], "\(slow)")
        let fast = PetalSound.plan(steps: 1, interval: 0.04)
        c.check("a fast sweep (25 petals/s) runs at 1.3×, 20% quieter", fast.count == 1 && abs(fast[0].rate - 1.3) < 0.001
                && abs(fast[0].volume - 0.8) < 0.001, "\(fast)")
        let rates = [0.4, 0.2, 0.12, 0.09, 0.07, 0.05].map { PetalSound.plan(steps: 1, interval: $0)[0].rate }
        c.check("the rate rises steadily with speed", zip(rates, rates.dropFirst()).allSatisfy { $0 <= $1 } && rates.last! > rates.first!,
                rates.map { fmt(Double($0)) }.joined(separator: " "))
        let skip = PetalSound.plan(steps: 3, interval: 0.06)
        let gaps = zip(skip, skip.dropFirst()).map { $1.delay - $0.delay }
        c.check("skipping petals plays a tick for each, spread out", skip.count == 3 && skip[0].delay == 0
                && gaps.allSatisfy { $0 >= 0.012 && $0 <= 0.04 }, gaps.map { fmt($0 * 1000) }.joined(separator: " "))
        let quick = PetalSound.plan(steps: 3, interval: 0.6, moveTime: 0.016)
        c.check("a quick jump after a pause is spread by the move's own time (12 ms), not the pause",
                quick.map(\.delay).last.map { abs($0 - 0.024) < 1e-9 } == true, quick.map { fmt($0.delay * 1000) }.joined(separator: " "))
        let wide = PetalSound.plan(steps: 6, interval: 2, moveTime: 2)
        c.check("a move's ticks all start within 0.1 s", wide.count == 6 && (wide.last?.delay ?? 1) <= PetalSound.maximumSpread + 1e-9,
                fmt((wide.last?.delay ?? 0) * 1000))
        c.check("at most 6 ticks per move", PetalSound.plan(steps: 40, interval: 0.02).count == 6)
        c.check("a zero or endless interval is safe", PetalSound.plan(steps: 2, interval: 0).count == 2
                && PetalSound.plan(steps: 1, interval: .infinity) == slow && PetalSound.plan(steps: 2, interval: 0.1, moveTime: .nan).count == 2)
        c.check("eight voices take turns", PetalSound.voiceCount == 8)
        c.check("a tick more than 0.15 s late is dropped", PetalSound.isTimely(requested: 10, now: 10.149)
                && !PetalSound.isTimely(requested: 10, now: 10.151))

        // A move is one buffer: tick k sits delay × rate in, so the varispeed plays the ticks exactly delay apart.
        let one: [Float] = [1] + Array(repeating: 0, count: 99)
        let movePlan = PetalSound.plan(steps: 3, interval: 0.03, moveTime: 0.04)
        let moved = PetalSound.moveSamples(one, plan: movePlan)
        let onsets = moved.indices.filter { moved[$0] > 0.5 }
        let expected = movePlan.map { Int(($0.delay * Double($0.rate) * 48_000).rounded()) }
        c.check("a move's buffer holds each tick at delay × rate", onsets == expected && movePlan.allSatisfy { $0.rate == movePlan[0].rate },
                "\(onsets) vs \(expected), rate \(movePlan[0].rate)")
        c.check("a single tick's move is the tick itself", PetalSound.moveSamples(one, plan: [PetalSound.Tick(delay: 0, rate: 1.2, volume: 1)]) == one)

        // Petals crossed, counted the short way round, within one ring.
        let eight = WheelLayout(count: 8, bounds: CGRect(x: 0, y: 0, width: 372, height: 372))
        c.check("neighbours are one step; across is the short way round", eight.steps(from: 0, to: 1) == 1
                && eight.steps(from: 0, to: 3) == 3 && eight.steps(from: 0, to: 7) == 1 && eight.steps(from: 1, to: 6) == 3)
        c.check("entering from the centre is one step", eight.steps(from: nil, to: 5) == 1)
        let twelve = WheelLayout(count: 12, bounds: CGRect(x: 0, y: 0, width: 600, height: 600))
        let k = WheelMetrics.innerCount(for: 12)
        c.check("changing ring is one step", twelve.steps(from: 0, to: k) == 1 && twelve.steps(from: k, to: k + 2) == 2)

        // The live engine, muted, with taps on the voices: ticks really render; it pauses when idle and no wheel
        // holds it, resumes on the next tick, and comes back after the engine stops itself (a device change).
        let live = PetalSound.shared
        let savedIdle = PetalSound.idleStop
        PetalSound.idleStop = 0.4
        defer { PetalSound.idleStop = savedIdle }
        live.startProbe()
        _ = live.probe()
        let before = live.probe().rendered
        live.play(steps: 1, interval: 0.3, style: .dial)
        live.play(steps: 3, interval: 0.05, moveTime: 0.03, style: .dial)
        Thread.sleep(forTimeInterval: 0.35)
        let first = live.probe()
        c.check("the live engine renders each move (one buffer each), audibly", first.running && first.rendered - before == 2
                && first.peak > 0.05, "\(first.rendered - before) buffers, peak \(fmt(Double(first.peak)))")
        let owner = NSObject()
        live.hold(owner, start: true)
        Thread.sleep(forTimeInterval: 0.7)
        c.check("a held engine keeps running past the idle time", live.probe().running)
        live.release(owner)
        Thread.sleep(forTimeInterval: 0.7)
        c.check("released and idle, the engine pauses (the audio device is let go)", !live.probe().running)
        live.play(steps: 1, interval: 0.3, style: .click)
        Thread.sleep(forTimeInterval: 0.25)
        let resumed = live.probe()
        c.check("after an idle pause the next tick resumes it and plays", resumed.running && resumed.peak > 0.05, fmt(Double(resumed.peak)))
        live.simulateDeviceChange()
        live.play(steps: 1, interval: 0.3, style: .wood)
        Thread.sleep(forTimeInterval: 0.25)
        let changed = live.probe()
        c.check("after the engine stops itself (device change) ticks still play", changed.running && changed.peak > 0.03, fmt(Double(changed.peak)))
        Thread.sleep(forTimeInterval: 0.7)
        c.check("an engine started only for a tick still pauses when idle", !live.probe().running)
        c.notes.append("live engine: \(first.rendered - before) moves rendered, peak \(fmt(Double(first.peak))); after idle pause peak "
                       + "\(fmt(Double(resumed.peak))); after a device change peak \(fmt(Double(changed.peak)))")

        // The sweep preview mixes the same plan.
        let sweep = PetalSound.sweep(.dial, moves: Array(repeating: (interval: 0.05, steps: 1), count: 10))
        let peak = Double(sweep.map(abs).max() ?? 0)
        c.check("a fast sweep doesn't clip", peak < 0.5, fmt(peak))
    }

    // MARK: Built-in Convert petals

    /// The formats valid for every file, whatever order the files came in (what the wheel is given to show).
    static func convertPetals(_ c: Checker) {
        let dir = URL(fileURLWithPath: "/tmp/YummyOrange selftest", isDirectory: true)
        let png = dir.appendingPathComponent("photo.png"), dng = dir.appendingPathComponent("camera.dng")
        let jpg = dir.appendingPathComponent("b.jpeg"), png2 = dir.appendingPathComponent("other.png")
        let mp4 = dir.appendingPathComponent("clip.mp4"), mkv = dir.appendingPathComponent("odd.mkv")
        let names: ([URL]) -> [String] = { OutputFormat.targets(forAll: $0).map(\.rawValue) }
        let builtIn: ([URL]) -> [String] = { files in
            AppDelegate.items(for: .convert, files: files).filter { $0.symbol == nil }.map(\.title)
        }
        c.check("one file: same petals as before", names([png]) == OutputFormat.targets(for: .image, source: "png").map(\.rawValue)
                && names([dng]) == OutputFormat.targets(for: .image, source: "dng").map(\.rawValue))
        c.check("[PNG, DNG] and [DNG, PNG] offer the same formats", names([png, dng]) == names([dng, png]))
        c.check("[PNG, DNG] offers no PNG but JPG", !names([dng, png]).contains("png") && names([png, dng]).contains("jpg"))
        c.check("the wheel itself agrees in both orders", builtIn([png, dng]) == builtIn([dng, png]) && !builtIn([dng, png]).contains("PNG"))
        c.check("[PNG, JPEG, PNG] offers neither PNG nor JPG", !names([png, jpg, png2]).contains("png")
                && !names([png, jpg, png2]).contains("jpg") && names([png, jpg, png2]) == names([jpg, png2, png]))
        c.check("[MP4, MKV] and [MKV, MP4] offer the same formats, neither MP4 nor MKV",
                names([mp4, mkv]) == names([mkv, mp4]) && !names([mp4, mkv]).contains("mp4") && !names([mkv, mp4]).contains("mkv"))
        c.check("mixed kinds offer no built-in format", names([png, mp4]).isEmpty)
        for ext in ["xlsm", "xltx", "xltm", "fods"] {
            let ids = Registry.commands(for: .convert, files: [dir.appendingPathComponent("book.\(ext)")]).map(\.id)
            c.check(".\(ext) gets spreadsheet petals", ids.contains("xlsx") && ids.contains("csv") && ids.contains("pdf"), ids.joined(separator: " "))
        }
        // Real petal sets: every petal the app offers is on the wheel, none dropped, and every label fits.
        var worst = 0
        for (name, files) in [("PNG", [png]), ("MP4", [mp4]), ("DOCX", [dir.appendingPathComponent("a.docx")]),
                              ("PDF", [dir.appendingPathComponent("a.pdf")]), ("XLSX", [dir.appendingPathComponent("a.xlsx")])] {
            for mode in WheelMode.allCases {
                let items = AppDelegate.items(for: mode, files: files)
                worst = max(worst, items.count)
                let d = WheelLayout.diameter(for: items.count)
                let view = WheelView(frame: CGRect(x: 0, y: 0, width: d, height: d))
                view.items = items
                let cut = view.labels.indices.filter { view.labels[$0].truncated }.map { items[$0].title }
                c.check("\(name) \(mode.rawValue): all \(items.count) petals shown, none cut", view.layout.count == items.count && cut.isEmpty,
                        cut.joined(separator: ", "))
            }
        }
        c.notes.append("largest real wheel in these samples: \(worst) petals")
    }
}
#endif
