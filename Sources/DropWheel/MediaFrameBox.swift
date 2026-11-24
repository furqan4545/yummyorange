import AppKit
import AVFoundation
import CoreImage

// Pieces the video frame editors share (Crop and Redact): box geometry in video pixels, handles with 20-point hit
// areas and the system's resize pointers, the overlay view base class, and the picture the Redact preview reads
// (the player's current frame, or the still before the player is ready and in snapshots).

/// Box geometry in video pixels (top-left origin) and hit testing in view points.
enum MediaBoxGeometry {
    /// The eight resize handles of a box, clockwise from the top-left corner.
    enum Handle: Int, CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
        var movesMinX: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
        var movesMaxX: Bool { [.topRight, .right, .bottomRight].contains(self) }
        var movesMinY: Bool { [.topLeft, .top, .topRight].contains(self) }
        var movesMaxY: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }

        func point(in r: CGRect) -> CGPoint {
            CGPoint(x: movesMinX ? r.minX : movesMaxX ? r.maxX : r.midX, y: movesMinY ? r.minY : movesMaxY ? r.maxY : r.midY)
        }

        /// The system's frame-resize pointer for this handle (macOS 15 and later), else the closest older one.
        var cursor: NSCursor {
            if #available(macOS 15.0, *) {
                let position: NSCursor.FrameResizePosition
                switch self {
                case .topLeft: position = .topLeft
                case .top: position = .top
                case .topRight: position = .topRight
                case .right: position = .right
                case .bottomRight: position = .bottomRight
                case .bottom: position = .bottom
                case .bottomLeft: position = .bottomLeft
                case .left: position = .left
                }
                return NSCursor.frameResize(position: position, directions: .all)
            }
            switch self {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            default: return .crosshair
            }
        }
    }

    /// Half the side of a corner's hit square and half the width of an edge's hit band, in points: 24 × 24 at the
    /// corners and a 20-point band along the edges (the 20 × 20 minimum for Mac controls).
    static let cornerReach: CGFloat = 12
    static let edgeReach: CGFloat = 10

    /// The handle under `p` for a box shown at `r` (view points). Corners win over edges; deep inside is a move.
    static func handle(at p: CGPoint, of r: CGRect, edges: Bool = true) -> Handle? {
        for h in Handle.allCases where h.isCorner {
            let c = h.point(in: r)
            if abs(p.x - c.x) <= cornerReach && abs(p.y - c.y) <= cornerReach { return h }
        }
        guard edges else { return nil }
        // Small boxes keep a grabbable middle: inside the box the bands shrink to a quarter of the side.
        let insideX = min(edgeReach, r.width / 4), insideY = min(edgeReach, r.height / 4)
        let withinY = p.y > r.minY + cornerReach / 2 && p.y < r.maxY - cornerReach / 2
        let withinX = p.x > r.minX + cornerReach / 2 && p.x < r.maxX - cornerReach / 2
        if withinY && p.x >= r.minX - edgeReach && p.x <= r.minX + insideX { return .left }
        if withinY && p.x <= r.maxX + edgeReach && p.x >= r.maxX - insideX { return .right }
        if withinX && p.y >= r.minY - edgeReach && p.y <= r.minY + insideY { return .top }
        if withinX && p.y <= r.maxY + edgeReach && p.y >= r.maxY - insideY { return .bottom }
        return nil
    }

    static func clamp(_ p: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    /// A box grown from `anchor` towards (sx, sy) (each ±1) to `width` × `height`, kept to `ratio` (width ÷ height
    /// in pixels) when given, at least `minSide` and inside `bounds`.
    static func fromAnchor(_ anchor: CGPoint, sx: CGFloat, sy: CGFloat, width: CGFloat, height: CGFloat,
                           ratio: CGFloat?, bounds: CGRect, minSide: CGFloat) -> CGRect {
        var w = max(width, minSide), h = max(height, minSide)
        let availW = sx > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
        let availH = sy > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
        if let ratio, ratio > 0 {
            if w / h > ratio { h = w / ratio } else { w = h * ratio }
            if w > availW { w = availW; h = w / ratio }
            if h > availH { h = availH; w = h * ratio }
        } else {
            w = min(w, availW); h = min(h, availH)
        }
        return CGRect(x: sx > 0 ? anchor.x : anchor.x - w, y: sy > 0 ? anchor.y : anchor.y - h, width: w, height: h)
    }

    /// `start` resized by dragging `handle` to `point` (video pixels), inside `bounds`, keeping `ratio` when given.
    /// The box never flips over its fixed side.
    static func resize(_ start: CGRect, handle: Handle, to point: CGPoint, ratio: CGFloat?, bounds: CGRect, minSide: CGFloat) -> CGRect {
        let p = clamp(point, to: bounds)
        if handle.isCorner {
            let sx: CGFloat = handle.movesMaxX ? 1 : -1, sy: CGFloat = handle.movesMaxY ? 1 : -1
            let anchor = CGPoint(x: sx > 0 ? start.minX : start.maxX, y: sy > 0 ? start.minY : start.maxY)
            return fromAnchor(anchor, sx: sx, sy: sy, width: sx * (p.x - anchor.x), height: sy * (p.y - anchor.y),
                              ratio: ratio, bounds: bounds, minSide: minSide)
        }
        if let ratio, ratio > 0 {
            if handle == .left || handle == .right {
                let anchorX = handle == .right ? start.minX : start.maxX
                var w = max(minSide, handle == .right ? p.x - anchorX : anchorX - p.x)
                w = min(w, handle == .right ? bounds.maxX - anchorX : anchorX - bounds.minX, bounds.height * ratio)
                let h = w / ratio
                let y = min(max(start.midY - h / 2, bounds.minY), bounds.maxY - h)
                return CGRect(x: handle == .right ? anchorX : anchorX - w, y: y, width: w, height: h)
            }
            let anchorY = handle == .bottom ? start.minY : start.maxY
            var h = max(minSide, handle == .bottom ? p.y - anchorY : anchorY - p.y)
            h = min(h, handle == .bottom ? bounds.maxY - anchorY : anchorY - bounds.minY, bounds.width / ratio)
            let w = h * ratio
            let x = min(max(start.midX - w / 2, bounds.minX), bounds.maxX - w)
            return CGRect(x: x, y: handle == .bottom ? anchorY : anchorY - h, width: w, height: h)
        }
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if handle.movesMinX { minX = min(p.x, maxX - minSide) }
        if handle.movesMaxX { maxX = max(p.x, minX + minSide) }
        if handle.movesMinY { minY = min(p.y, maxY - minSide) }
        if handle.movesMaxY { maxY = max(p.y, minY + minSide) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(bounds)
    }

    /// A new box dragged from `a` to `b` (video pixels), kept to `ratio` and inside `bounds`.
    static func drawn(from a: CGPoint, to b: CGPoint, ratio: CGFloat?, bounds: CGRect, minSide: CGFloat) -> CGRect {
        let a = clamp(a, to: bounds), b = clamp(b, to: bounds)
        let sx: CGFloat = b.x >= a.x ? 1 : -1, sy: CGFloat = b.y >= a.y ? 1 : -1
        return fromAnchor(a, sx: sx, sy: sy, width: abs(b.x - a.x), height: abs(b.y - a.y), ratio: ratio, bounds: bounds, minSide: minSide)
    }

    /// `r` moved by `d`, stopped at the edges of `bounds`.
    static func moved(_ r: CGRect, by d: CGVector, in bounds: CGRect) -> CGRect {
        var out = r.offsetBy(dx: d.dx, dy: d.dy)
        out.origin.x = min(max(out.minX, bounds.minX), bounds.maxX - out.width)
        out.origin.y = min(max(out.minY, bounds.minY), bounds.maxY - out.height)
        return out
    }

    /// The largest box of `ratio` inside `bounds`, centred on `center` as far as it can be.
    static func largest(ratio: CGFloat, in bounds: CGRect, around center: CGPoint) -> CGRect {
        var w = bounds.width, h = w / ratio
        if h > bounds.height { h = bounds.height; w = h * ratio }
        return moved(CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h), by: .zero, in: bounds)
    }
}

// MARK: - Keys of a focused control

extension MediaEditorWindowController {
    /// Whether `event` belongs to the control that has the keyboard focus rather than to the editor. With Full
    /// Keyboard Access, Tab moves the focus to buttons, pop-ups and segmented controls (the inspector's, the
    /// toolbar's): Space presses the focused one, and ← → move along a segmented control. The kit's keys would play
    /// or step frames instead. Without it a click doesn't focus these, so mouse users keep Space for play.
    func keyBelongsToFocusedControl(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let control = window.firstResponder as? NSControl, !(control is NSTextField), !(control is NSTableView)
        else { return false }
        switch event.keyCode {
        case 49: return true                                    // Space
        case 123, 124: return control is NSSegmentedControl     // ← →
        default: return false
        }
    }
}

// MARK: - Overlay base

/// A view over the whole preview for one frame tool: it takes clicks on the picture (and the handle reach around
/// it), and maps between view points and video pixels through the preview.
class MediaFrameOverlayView: NSView {
    weak var preview: MediaPreviewView?
    /// How far outside the picture a press still counts (handles sit on the picture's edge).
    var reach: CGFloat = MediaBoxGeometry.cornerReach + 2

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let preview, !isHidden else { return nil }
        let p = convert(point, from: superview)
        return preview.pictureRect.insetBy(dx: -reach, dy: -reach).contains(p) ? self : nil
    }

    var pictureRect: CGRect { preview?.pictureRect ?? .zero }
    func viewRect(_ pixels: CGRect) -> CGRect { preview?.viewRect(fromPixel: pixels) ?? .zero }
    func pixelPoint(_ view: CGPoint) -> CGPoint { preview?.pixelPoint(fromView: view) ?? .zero }
    func location(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    /// White knobs with a dark rim at a box's corners (and edge midpoints when the box is big enough): visible over
    /// any picture.
    static func drawKnobs(_ r: CGRect, edges: Bool, ring: NSColor) {
        let showEdges = edges && r.width >= 64 && r.height >= 64
        for h in MediaBoxGeometry.Handle.allCases where h.isCorner || showEdges {
            let c = h.point(in: r)
            let knob = NSBezierPath(ovalIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = CGSize(width: 0, height: -0.5)
            shadow.set()
            NSColor.white.setFill()
            knob.fill()
            NSGraphicsContext.restoreGraphicsState()
            knob.lineWidth = 1.5
            ring.setStroke()
            knob.stroke()
        }
    }
}

// MARK: - The picture under the boxes (Redact's live preview)

/// The frame the editor shows, as an upright Core Image image covering the whole picture: from the player (an
/// AVPlayerItemVideoOutput, rotated as the track says when the player plays the original) once it is ready, else
/// from the preview's still (ffmpeg or AVFoundation, already upright).
final class MediaFrameGrabber {
    private var output: AVPlayerItemVideoOutput?
    private weak var player: AVPlayer?
    private var timer: Timer?
    private var orientation: CGImagePropertyOrientation = .up
    private(set) var playerFrame: CIImage?
    /// When the player shows `playerFrame` (item time, seconds).
    private(set) var playerFrameTime: Double?
    /// The player's time when `playerFrame` was taken (the frame is the one on screen there).
    private(set) var playerItemTime: Double?
    /// Called on the main thread after a new player frame arrives.
    var onFrame: (() -> Void)?

    /// Starts reading the player's frames (30 times a second it asks whether a new one is ready; cheap when paused).
    /// `rotation` is the clockwise turn the stored picture needs (0 for proxies, which are upright).
    func attach(_ player: AVPlayer, rotation: Int) {
        stop()
        guard let item = player.currentItem else { return }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        self.output = output
        self.player = player
        switch rotation {
        case 90: orientation = .right
        case 180: orientation = .down
        case 270: orientation = .left
        default: orientation = .up
        }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Takes the newest frame for the player's current time, if one is waiting. Returns true when it got one.
    @discardableResult
    func poll() -> Bool {
        guard let output, let player else { return false }
        let t = player.currentTime()
        var shown = CMTime.invalid
        guard output.hasNewPixelBuffer(forItemTime: t), let buffer = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown) else { return false }
        playerFrameTime = shown.isValid ? shown.seconds : nil
        playerItemTime = t.seconds
        var image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        playerFrame = image
        onFrame?()
        return true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let output, let item = player?.currentItem, item.outputs.contains(where: { $0 === output }) { item.remove(output) }
        output = nil
        player = nil
        onFrame = nil
    }

    deinit { timer?.invalidate() }
}

/// Draws a redaction box's effect from the picture, the way ffmpeg will write it: Pixelate as the same blocks (each
/// the average of the pixels in it, the grid starting at the box's corner), Blur as a Gaussian of the three-pass box
/// blur's strength, Black as black. Values stay in the picture's own colour space.
enum MediaRedactRenderer {
    /// No colour management: filters work on the encoded values, as ffmpeg's do (a blur in linear light would come
    /// out lighter than the saved file).
    static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])

    /// Draws `box` (video pixels) into `viewRect` from `frame` (upright, covering the picture, origin zero). Without a
    /// frame, Blur and Pixelate draw a neutral stand-in so the box still reads as covered.
    static func draw(_ box: MediaRedact.Box, frame: CIImage?, pixelSize: CGSize, in viewRect: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, viewRect.width >= 1, viewRect.height >= 1 else { return }
        if box.style == .black {
            NSColor.black.setFill()
            viewRect.fill()
            return
        }
        guard let frame, pixelSize.width > 0, pixelSize.height > 0 else {
            NSColor(white: 0.5, alpha: 0.92).setFill()
            viewRect.fill()
            return
        }
        let ext = frame.extent
        let sx = ext.width / pixelSize.width, sy = ext.height / pixelSize.height
        let r = box.rect
        // Core Image's origin is at the bottom left.
        let region = CGRect(x: r.minX * sx, y: (pixelSize.height - r.maxY) * sy, width: r.width * sx, height: r.height * sy)
            .integral.intersection(ext)
        guard region.width >= 1, region.height >= 1 else { return }
        let space = frame.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        ctx.saveGState()
        ctx.clip(to: viewRect)
        switch box.style {
        case .blur:
            // A three-pass box blur of radius r is close to a Gaussian of sigma r (32 dB against the saved file).
            let sigma = Double(MediaRedact.blurRadius(r)) * Double(sx)
            let blurred = frame.cropped(to: region).clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: region)
            if let image = context.createCGImage(blurred, from: region, format: .RGBA8, colorSpace: space) {
                ctx.interpolationQuality = .high
                drawFlipped(image, in: viewRect, ctx: ctx)
            }
        case .pixelate:
            let block = CGFloat(MediaRedact.blockSize(r)) * sx
            if let (image, cover) = pixelated(frame, region: region, block: block, space: space) {
                // The blocks cover `cover` of the region (the last row and column may be partly outside the box).
                ctx.interpolationQuality = .none
                drawFlipped(image, in: CGRect(x: viewRect.minX, y: viewRect.minY, width: viewRect.width * cover.width,
                                              height: viewRect.height * cover.height), ctx: ctx)
            }
        case .black:
            break
        }
        ctx.restoreGState()
    }

    /// One pixel per block: the average of the region's pixels in it (blocks start at the top-left corner; the last
    /// ones average only what is inside). Returns the image and how much of the region its blocks span (≥ 1).
    static func pixelated(_ frame: CIImage, region: CGRect, block: CGFloat, space: CGColorSpace) -> (CGImage, CGSize)? {
        let w = Int(region.width), h = Int(region.height)
        guard w > 0, h > 0, block > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        // Rows come out top first.
        context.render(frame, toBitmap: &bytes, rowBytes: w * 4, bounds: region, format: .RGBA8, colorSpace: space)
        let cols = max(1, Int((CGFloat(w) / block).rounded(.up))), rows = max(1, Int((CGFloat(h) / block).rounded(.up)))
        var sums = [Int](repeating: 0, count: cols * rows * 3), counts = [Int](repeating: 0, count: cols * rows)
        let colOf = (0..<w).map { min(cols - 1, Int(CGFloat($0) / block)) }
        for y in 0..<h {
            let row = min(rows - 1, Int(CGFloat(y) / block)) * cols
            for x in 0..<w {
                let i = (y * w + x) * 4, b = row + colOf[x]
                sums[b * 3] += Int(bytes[i]); sums[b * 3 + 1] += Int(bytes[i + 1]); sums[b * 3 + 2] += Int(bytes[i + 2])
                counts[b] += 1
            }
        }
        var out = [UInt8](repeating: 255, count: cols * rows * 4)
        for b in 0..<(cols * rows) where counts[b] > 0 {
            for c in 0..<3 { out[b * 4 + c] = UInt8((sums[b * 3 + c] + counts[b] / 2) / counts[b]) }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let image = CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return (image, CGSize(width: CGFloat(cols) * block / CGFloat(w), height: CGFloat(rows) * block / CGFloat(h)))
    }

    private static func drawFlipped(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }
}
