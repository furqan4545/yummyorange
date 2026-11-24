import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The welcome card. While new files go to the Clothesline, an empty line holds one card of its own: a picture drawn
/// here in YummyOrange's colours that says what the line is for ("Drag files up to the notch"), so the line is never a
/// bare string the first time it comes out. It is a real PNG, written once to YummyOrange's folder in Application
/// Support, and it hangs like any file: open it, move it, drag it to a folder (where it is just a file). Taking it off
/// the line (Delete, Remove from Line, Clear Line) is remembered in Settings, and it never comes back. It is never a
/// new file either: it is put on the line quietly while the line is away (no drop, no flight, no announcement).
///
///     ClotheslineWelcome.wanted()   // its file while an empty line should hold it (the live controller asks)
///     ClotheslineWelcome.folder     // where it is written (the command line and self-tests: a temporary folder)
enum ClotheslineWelcome {
    static let fileName = "Welcome to the Clothesline.png"
    /// The picture is laid out on a 1128 × 600 canvas (1.88:1 fills the widest card's well, 158 × 84 pt) and written at
    /// this fraction of it: 752 × 400 px, more than twice the well's size on a Retina display.
    static let canvas = CGSize(width: 1128, height: 600)
    static let scale: CGFloat = 2.0 / 3
    static var pixelSize: (width: Int, height: Int) { (Int(canvas.width * scale), Int(canvas.height * scale)) }

    /// Where the picture is written. Anything run from the command line (self-tests, snapshots) writes to a folder in
    /// the temporary directory, never to the real Application Support; tests set their own.
    static var folder: URL = defaultFolder(arguments: CommandLine.arguments)

    static func defaultFolder(arguments: [String]) -> URL {
        let fm = FileManager.default
        if arguments.dropFirst().first?.hasPrefix("--") ?? false {
            return fm.temporaryDirectory.appendingPathComponent("YummyOrange Clothesline", isDirectory: true)
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("YummyOrange/Clothesline", isDirectory: true)
    }

    static var url: URL { folder.appendingPathComponent(fileName) }

    /// Whether a file is the welcome picture where YummyOrange keeps it (a copy dragged elsewhere is just a file).
    static func isWelcome(_ file: URL) -> Bool { ClotheslineEngine.identity(file) == ClotheslineEngine.identity(url) }

    /// The welcome card's file while an empty line should hold it: new files go to the Clothesline and the person never
    /// took the card off. The picture is written the first time (nil when it can't be).
    static func wanted() -> URL? {
        guard Settings.resultsDestination == .clothesline, !Settings.clotheslineWelcomeRemoved else { return nil }
        return write()
    }

    /// Writes the picture once: a file already there is kept as it is. Its extension is hidden, so the card's caption
    /// reads "Welcome to the Clothesline". Returns its URL (nil when it can't be written).
    @discardableResult
    static func write() -> URL? {
        let url = self.url
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let data = pngData(),
              (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        var hidden = URLResourceValues()
        hidden.hasHiddenExtension = true
        var file = url
        try? file.setResourceValues(hidden)
        return url
    }

    // MARK: The picture

    static func pngData() -> Data? {
        guard let image = image() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// The picture, opaque sRGB: the welcome page's dahlia-to-butter sky, the notch at the top with the glowing string
    /// coming out of it and two little cards pinned to it, an arrow up to the notch and the words under it.
    static func image() -> CGImage? {
        let (w, h) = pixelSize
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        // Top-down coordinates on the canvas.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw(size: canvas, in: ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// The words' colour: the accent taken deep, toward plum (about 9:1 on the butter where they sit).
    static let ink = DWPalette.blend(DWPalette.accentDeep, .black, 0.5)

    static func draw(size s: CGSize, in ctx: CGContext) {
        let full = CGRect(origin: .zero, size: s)
        // The sky: dahlia pink at the top into the butter glow, one flat colour per pixel row (a drawn gradient is
        // dithered, which would make the PNG several times bigger).
        let rows = Int(s.height * scale), row = s.height / CGFloat(rows)
        let middle = DWPalette.blend(DWPalette.base, DWPalette.glow, 0.55)
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        for i in 0..<rows {
            let t = (CGFloat(i) + 0.5) / CGFloat(rows)
            (t < 0.5 ? DWPalette.blend(DWPalette.base, middle, t * 2) : DWPalette.blend(middle, DWPalette.glow, t * 2 - 1)).setFill()
            CGRect(x: full.minX, y: CGFloat(i) * row, width: full.width, height: row + 0.01).fill()
        }
        ctx.restoreGState()
        let mid = s.width / 2
        // The string: two halves sagging from the edges up into the notch, a strand of cream light.
        let left = Curve(a: CGPoint(x: -10, y: 66), b: CGPoint(x: 170, y: 214), c: CGPoint(x: 400, y: 160), d: CGPoint(x: mid - 40, y: 24))
        let right = left.mirrored(about: mid)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 9, color: DWPalette.cream.withAlphaComponent(0.9).cgColor)
        DWPalette.cream.setStroke()
        for half in [left, right] {
            let path = NSBezierPath()
            path.move(to: half.a)
            path.curve(to: half.d, controlPoint1: half.b, controlPoint2: half.c)
            path.lineWidth = 6
            path.lineCapStyle = .round
            path.stroke()
        }
        ctx.restoreGState()
        // The notch, flush with the top edge.
        let notch = CGRect(x: mid - 112, y: -30, width: 224, height: 78)
        NSColor(white: 0.07, alpha: 1).setFill()
        NSBezierPath(roundedRect: notch, xRadius: 26, yRadius: 26).fill()
        // A photo on the left half, a document on the right, each on its pin.
        drawCard(on: left, atX: 262, tilt: 1, photo: true, in: ctx)
        drawCard(on: right, atX: s.width - 262, tilt: -1, photo: false, in: ctx)
        // An arrow from under the words up to the notch.
        let arrow = NSBezierPath()
        arrow.move(to: CGPoint(x: mid, y: 318))
        arrow.line(to: CGPoint(x: mid, y: 92))
        arrow.move(to: CGPoint(x: mid - 34, y: 126))
        arrow.line(to: CGPoint(x: mid, y: 92))
        arrow.line(to: CGPoint(x: mid + 34, y: 126))
        arrow.lineWidth = 13
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        DWPalette.cream.setStroke()
        arrow.stroke()
        // The words, two lines, centred.
        let font = NSFont.systemFont(ofSize: 92, weight: .bold)
        let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 92) } ?? font
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.maximumLineHeight = 104
        style.minimumLineHeight = 104
        let text = NSAttributedString(string: "Drag files up\nto the notch", attributes: [
            .font: rounded, .foregroundColor: ink, .paragraphStyle: style, .kern: -0.5,
        ])
        text.draw(with: CGRect(x: 0, y: 356, width: s.width, height: 220), options: [.usesLineFragmentOrigin])
    }

    /// A small polaroid hanging from its clothespin where the string passes `x`, turned a little with the string.
    private static func drawCard(on half: Curve, atX x: CGFloat, tilt: CGFloat, photo: Bool, in ctx: CGContext) {
        let (p, slope) = half.point(atX: x)
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: atan(slope) * 0.5 + tilt * 0.04)
        let mat = CGRect(x: -62, y: 14, width: 124, height: 140)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 5), blur: 8, color: NSColor(white: 0, alpha: 0.2).cgColor)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: mat, xRadius: 10, yRadius: 10).fill()
        ctx.restoreGState()
        let well = CGRect(x: mat.minX + 8, y: mat.minY + 8, width: mat.width - 16, height: 98)
        let wellPath = NSBezierPath(roundedRect: well, xRadius: 5, yRadius: 5)
        if photo {
            // A sunset: butter sun over pink hills.
            NSGradient(colors: [DWPalette.glow, DWPalette.button])?.draw(in: wellPath, angle: 90)
            DWPalette.cream.setFill()
            NSBezierPath(ovalIn: CGRect(x: well.midX - 2, y: well.minY + 18, width: 30, height: 30)).fill()
            let hills = NSBezierPath()
            hills.move(to: CGPoint(x: well.minX, y: well.maxY - 26))
            hills.curve(to: CGPoint(x: well.maxX, y: well.maxY - 34), controlPoint1: CGPoint(x: well.minX + 40, y: well.maxY - 58),
                        controlPoint2: CGPoint(x: well.maxX - 40, y: well.maxY - 8))
            hills.line(to: CGPoint(x: well.maxX, y: well.maxY))
            hills.line(to: CGPoint(x: well.minX, y: well.maxY))
            hills.close()
            NSGraphicsContext.saveGraphicsState()
            wellPath.addClip()
            DWPalette.accent.setFill()
            hills.fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            // A page: lines of text on cream.
            DWPalette.cream.setFill()
            wellPath.fill()
            DWPalette.accentLight.setFill()
            for (i, f) in [0.8, 0.62, 0.74, 0.5].enumerated() {
                NSBezierPath(roundedRect: CGRect(x: well.minX + 14, y: well.minY + 18 + CGFloat(i) * 19, width: (well.width - 28) * f, height: 8),
                             xRadius: 4, yRadius: 4).fill()
            }
        }
        // The caption line under the picture.
        NSColor(white: 0, alpha: 0.12).setFill()
        NSBezierPath(roundedRect: CGRect(x: mat.midX - 30, y: well.maxY + 14, width: 60, height: 7), xRadius: 3.5, yRadius: 3.5).fill()
        // The clothespin: two prongs of light wood over the string.
        for side in [-1.0, 1.0] as [CGFloat] {
            let prong = CGRect(x: side < 0 ? -11 : 1, y: -16, width: 10, height: 44)
            ClotheslineArt.woodLight.blended(withFraction: side < 0 ? 0 : 0.25, of: ClotheslineArt.woodDark)?.setFill()
            NSBezierPath(roundedRect: prong, xRadius: 3.5, yRadius: 3.5).fill()
        }
        NSColor(white: 0.78, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: -12.5, y: 4, width: 25, height: 7), xRadius: 2.5, yRadius: 2.5).fill()
        ctx.restoreGState()
    }

    /// One half of the string: a cubic from `a` to `d`.
    private struct Curve {
        let a, b, c, d: CGPoint
        func at(_ t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(x: u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x,
                           y: u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y)
        }
        func mirrored(about m: CGFloat) -> Curve {
            func f(_ p: CGPoint) -> CGPoint { CGPoint(x: 2 * m - p.x, y: p.y) }
            return Curve(a: f(a), b: f(b), c: f(c), d: f(d))
        }
        /// The point where the curve passes `x`, and its slope there (dy/dx).
        func point(atX x: CGFloat) -> (CGPoint, CGFloat) {
            var best: CGFloat = 0
            for i in 0...400 {
                let t = CGFloat(i) / 400
                if abs(at(t).x - x) < abs(at(best).x - x) { best = t }
            }
            let p = at(best), q = at(min(1, best + 0.01)), o = at(max(0, best - 0.01))
            return (p, (q.y - o.y) / max(abs(q.x - o.x), 0.001) * (q.x >= o.x ? 1 : -1))
        }
    }
}
