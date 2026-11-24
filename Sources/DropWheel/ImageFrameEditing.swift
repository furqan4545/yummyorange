import AppKit
import UniformTypeIdentifiers

extension ImageEditors.SourceImage {
    /// "  ·  page 1 of 3 only, saved as PNG" when the file holds several pictures (TIFF pages, animation frames):
    /// the Crop and Redact windows show and save the first one alone, as PNG (SourceImage.outputFormat), and
    /// the status bar says so rather than letting the other pages vanish unannounced. Empty for one picture.
    var firstPictureNote: String {
        guard frameCount > 1 else { return "" }
        let pages = UTType(typeIdentifier)?.conforms(to: .tiff) ?? false
        return "  ·  \(pages ? "page" : "frame") 1 of \(frameCount) only, saved as PNG"
    }
}

/// Geometry, hit testing, cursors and drawing shared by the frame editors (Crop and Redact). Boxes live in
/// full-resolution upright image pixels with a top-left origin, like every other image edit.
enum FrameEditing {
    /// Fits `size` in `area`, centered: big pictures are never shown above 100%; small ones are enlarged
    /// (with crisp pixels) until their long side is 400 points, so handles stay usable on a 32-pixel image.
    static func fit(_ size: CGSize, in area: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return .zero }
        let fitScale = min(area.width / size.width, area.height / size.height)
        let enlarge = max(1, 400 / max(size.width, size.height))
        let s = min(fitScale, enlarge)
        let w = (size.width * s).rounded(), h = (size.height * s).rounded()
        return CGRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w, height: h)
    }

    /// The eight resize handles of a box, clockwise from the top-left corner.
    enum Handle: Int, CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
        var movesMinX: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
        var movesMaxX: Bool { [.topRight, .right, .bottomRight].contains(self) }
        var movesMinY: Bool { [.topLeft, .top, .topRight].contains(self) }
        var movesMaxY: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }

        /// Where the handle sits on `r` (top-left origin).
        func point(in r: CGRect) -> CGPoint {
            CGPoint(x: movesMinX ? r.minX : movesMaxX ? r.maxX : r.midX, y: movesMinY ? r.minY : movesMaxY ? r.maxY : r.midY)
        }

        /// The pointer for dragging this handle: the system's frame-resize pointers on macOS 15 and later.
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

        /// Accessibility and tooltip name.
        var name: String {
            switch self {
            case .topLeft: return "top-left corner"
            case .top: return "top edge"
            case .topRight: return "top-right corner"
            case .right: return "right edge"
            case .bottomRight: return "bottom-right corner"
            case .bottom: return "bottom edge"
            case .bottomLeft: return "bottom-left corner"
            case .left: return "left edge"
            }
        }
    }

    /// Half the side of a corner's hit square, and half the width of an edge's hit band, in points: 24 × 24
    /// at corners and a 20-point band along edges (HIG minimum control size on the Mac is 20 × 20).
    static let cornerReach: CGFloat = 12
    static let edgeReach: CGFloat = 10

    /// The handle under `p` for a box shown at `r` (both in view points), or nil. Corners win over edges;
    /// deep inside a box (farther than the edge band) is a move, not a resize.
    static func handle(at p: CGPoint, of r: CGRect, corners: Bool = true, edges: Bool = true) -> Handle? {
        if corners {
            for h in Handle.allCases where h.isCorner {
                let c = h.point(in: r)
                if abs(p.x - c.x) <= cornerReach && abs(p.y - c.y) <= cornerReach { return h }
            }
        }
        guard edges else { return nil }
        // Keep a grabbable middle in small boxes: the bands shrink to a quarter of the side inside the box.
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

    /// A box grown from the fixed corner `anchor` in the direction (sx, sy) (each ±1) to cover `w` × `h`,
    /// kept to `ratio` (width ÷ height) when given and inside `bounds`.
    static func fromAnchor(_ anchor: CGPoint, sx: CGFloat, sy: CGFloat, width: CGFloat, height: CGFloat,
                           ratio: CGFloat?, bounds: CGRect, minSize: CGFloat) -> CGRect {
        var w = max(width, minSize), h = max(height, minSize)
        let availW = sx > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
        let availH = sy > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
        if let ratio, ratio > 0 {
            if w / h > ratio { h = w / ratio } else { w = h * ratio }
            if w > availW { w = availW; h = w / ratio }
            if h > availH { h = availH; w = h * ratio }
        } else {
            w = min(w, availW)
            h = min(h, availH)
        }
        return CGRect(x: sx > 0 ? anchor.x : anchor.x - w, y: sy > 0 ? anchor.y : anchor.y - h, width: w, height: h)
    }

    /// `start` resized by dragging `handle` to `p` (all in image pixels), inside `bounds`, at least `minSize`
    /// on each side, keeping `ratio` when given. The box never flips over its fixed side.
    static func resize(_ start: CGRect, handle: Handle, to point: CGPoint, ratio: CGFloat?, bounds: CGRect,
                       minSize: CGFloat) -> CGRect {
        let p = clamp(point, to: bounds)
        if handle.isCorner {
            let sx: CGFloat = handle.movesMaxX ? 1 : -1, sy: CGFloat = handle.movesMaxY ? 1 : -1
            let anchor = CGPoint(x: sx > 0 ? start.minX : start.maxX, y: sy > 0 ? start.minY : start.maxY)
            return fromAnchor(anchor, sx: sx, sy: sy, width: sx * (p.x - anchor.x), height: sy * (p.y - anchor.y),
                              ratio: ratio, bounds: bounds, minSize: minSize)
        }
        var r = start
        if let ratio, ratio > 0 {
            if handle == .left || handle == .right {
                let anchorX = handle == .right ? start.minX : start.maxX
                var w = max(minSize, handle == .right ? p.x - anchorX : anchorX - p.x)
                w = min(w, handle == .right ? bounds.maxX - anchorX : anchorX - bounds.minX, bounds.height * ratio)
                let h = w / ratio
                let y = min(max(start.midY - h / 2, bounds.minY), bounds.maxY - h)
                r = CGRect(x: handle == .right ? anchorX : anchorX - w, y: y, width: w, height: h)
            } else {
                let anchorY = handle == .bottom ? start.minY : start.maxY
                var h = max(minSize, handle == .bottom ? p.y - anchorY : anchorY - p.y)
                h = min(h, handle == .bottom ? bounds.maxY - anchorY : anchorY - bounds.minY, bounds.width / ratio)
                let w = h * ratio
                let x = min(max(start.midX - w / 2, bounds.minX), bounds.maxX - w)
                r = CGRect(x: x, y: handle == .bottom ? anchorY : anchorY - h, width: w, height: h)
            }
            return r
        }
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if handle.movesMinX { minX = min(p.x, maxX - minSize) }
        if handle.movesMaxX { maxX = max(p.x, minX + minSize) }
        if handle.movesMinY { minY = min(p.y, maxY - minSize) }
        if handle.movesMaxY { maxY = max(p.y, minY + minSize) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(bounds)
    }

    /// The box `r` moved by `d`, stopped at the edges of `bounds`.
    static func moved(_ r: CGRect, by d: CGVector, in bounds: CGRect) -> CGRect {
        var out = r.offsetBy(dx: d.dx, dy: d.dy)
        out.origin.x = min(max(out.minX, bounds.minX), bounds.maxX - out.width)
        out.origin.y = min(max(out.minY, bounds.minY), bounds.maxY - out.height)
        return out
    }

    /// The largest box with `ratio` (width ÷ height) inside `bounds`, centered on `center` as far as it can be.
    static func largest(ratio: CGFloat, in bounds: CGRect, around center: CGPoint) -> CGRect {
        var w = bounds.width, h = w / ratio
        if h > bounds.height { h = bounds.height; w = h * ratio }
        return moved(CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h), by: .zero, in: bounds)
    }

    /// Whole pixels: each edge rounded to the nearest pixel, inside `bounds`.
    static func integral(_ r: CGRect, in bounds: CGRect) -> CGRect {
        let x0 = max(bounds.minX, r.minX.rounded()), y0 = max(bounds.minY, r.minY.rounded())
        let x1 = min(bounds.maxX, r.maxX.rounded()), y1 = min(bounds.maxY, r.maxY.rounded())
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    // MARK: Drawing
    // The same marks as the video frame editors (MediaRedactEditor, MediaCropEditor), so the app's editors
    // look like one family: the app's accent (dahlia, lighter in dark mode) for the selection, white for the
    // rest, a soft dark shadow under both so they read over light and dark pictures alike.

    /// The selection colour: the video editors' accent.
    static var accent: NSColor { MediaColors.accent }

    /// A box's outline: 1 pt white for a box, 2 pt accent for a selected one.
    static func outline(_ r: CGRect, selected: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 2
        shadow.set()
        let path = NSBezierPath(rect: r.insetBy(dx: selected ? 1 : 0.5, dy: selected ? 1 : 0.5))
        path.lineWidth = selected ? 2 : 1
        (selected ? accent : NSColor.white.withAlphaComponent(0.9)).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Round handles (white with an accent ring and a soft shadow) at the corners, and at the edge midpoints of
    /// a box big enough to show them apart. Used for a selected redaction box.
    static func drawKnobs(for r: CGRect, edges: Bool) {
        MediaFrameOverlayView.drawKnobs(r, edges: edges, ring: accent)
    }

    /// The crop frame: a white border and L-shaped corner grips with short edge bars, just inside the frame
    /// (so they stay on the picture, never on the canvas around it), as the video Crop editor draws them.
    static func drawCropFrame(_ r: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 2
        shadow.set()
        let border = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        NSColor.white.withAlphaComponent(0.9).setStroke()
        border.stroke()
        let grips = NSBezierPath()
        let t: CGFloat = 4, arm = min(22, r.width / 3, r.height / 3)
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.maxX, r.maxY, -1.0, -1.0),
                               (r.minX, r.maxY, 1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            grips.append(NSBezierPath(rect: CGRect(x: dx > 0 ? x : x - arm, y: dy > 0 ? y : y - t, width: arm, height: t)))
            grips.append(NSBezierPath(rect: CGRect(x: dx > 0 ? x : x - t, y: dy > 0 ? y : y - arm, width: t, height: arm)))
        }
        if r.width >= 90 {
            grips.append(NSBezierPath(rect: CGRect(x: r.midX - 11, y: r.minY, width: 22, height: t)))
            grips.append(NSBezierPath(rect: CGRect(x: r.midX - 11, y: r.maxY - t, width: 22, height: t)))
        }
        if r.height >= 90 {
            grips.append(NSBezierPath(rect: CGRect(x: r.minX, y: r.midY - 11, width: t, height: 22)))
            grips.append(NSBezierPath(rect: CGRect(x: r.maxX - t, y: r.midY - 11, width: t, height: 22)))
        }
        NSColor.white.setFill()
        grips.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
