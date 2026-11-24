import AppKit
import CoreText

// Annotations JSON (the `annotations` option of `--tool annotate`, and of `--snapshot annotate`).
//
// A JSON array of shapes. Coordinates are image pixels of the upright image (EXIF orientation applied),
// origin at the top-left, y growing down. Text the value with "@" in front to read a file instead:
// annotations=@/path/marks.json. Every key except the shape's geometry is optional.
//
//   {"type":"arrow",     "from":[x,y], "to":[x,y]}                  head at "to"
//   {"type":"line",      "from":[x,y], "to":[x,y]}
//   {"type":"rect",      "rect":[x,y,w,h], "fill":"#RRGGBBAA"}      "rectangle" also works
//   {"type":"ellipse",   "rect":[x,y,w,h], "fill":"#RRGGBBAA"}      "oval", "circle" also work
//   {"type":"pen",       "points":[[x,y],[x,y],...]}                freehand, smoothed; "freehand" also works
//   {"type":"highlight", "rect":[x,y,w,h]}                          a marker box, or
//   {"type":"highlight", "points":[[x,y],...]}                      a highlighter stroke; "highlighter" also works
//   {"type":"text",      "at":[x,y], "text":"Hi", "size":48}        "at" is the top-left of the first line; \n breaks lines
//
// Common keys:
//   "color"   "#RRGGBB", "#RRGGBBAA", "#RGB" or red, orange, yellow, green, blue, purple, pink, black, white, gray.
//             Default red (#FF3B30); highlights default to yellow (#FFCC00).
//   "width"   stroke width in pixels. Default: 0.4% of the image's longer side (at least 2 px); highlighter
//             strokes are 3.5 times wider.
//   "opacity" 0…1. Default 1; highlights default to 0.5 and multiply onto the picture like a marker pen.
// Text keys: "size" (pixels; default 2.8% of the longer side), "font" (system, rounded, serif, mono),
//   "weight" (regular, medium, semibold, bold, heavy; default semibold), "background" (a color for a
//   rounded box behind the text).
//
// Example:
//   [{"type":"arrow","from":[40,40],"to":[300,200],"color":"#FF3B30","width":8},
//    {"type":"rect","rect":[320,180,200,120]},
//    {"type":"text","at":[40,260],"text":"Look here","size":48,"color":"white","background":"#000000AA"}]

extension ImageEditors {
    /// A color with sRGB components, as annotations store it.
    struct RGBA: Equatable {
        var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1

        /// Color names the JSON accepts, as hex.
        static let names: [String: String] = [
            "red": "FF3B30", "orange": "FF9500", "yellow": "FFCC00", "green": "34C759", "blue": "007AFF",
            "purple": "AF52DE", "pink": "FF2D55", "black": "000000", "white": "FFFFFF", "gray": "8E8E93", "grey": "8E8E93",
        ]

        static func named(_ name: String) -> RGBA { RGBA(hex: names[name] ?? "000000")! }

        init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

        /// "#RGB", "#RRGGBB", "#RRGGBBAA" (the "#" is optional) or a color name.
        init?(hex: String) {
            var s = hex.trimmingCharacters(in: .whitespaces).lowercased()
            if let named = Self.names[s] { s = named }
            if s.hasPrefix("#") { s.removeFirst() }
            if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
            guard s.count == 6 || s.count == 8, s.allSatisfy(\.isHexDigit), let v = UInt64(s, radix: 16) else { return nil }
            let rgb = s.count == 8 ? v >> 8 : v
            r = CGFloat((rgb >> 16) & 0xFF) / 255
            g = CGFloat((rgb >> 8) & 0xFF) / 255
            b = CGFloat(rgb & 0xFF) / 255
            a = s.count == 8 ? CGFloat(v & 0xFF) / 255 : 1
        }

        init(_ color: NSColor) {
            let c = color.usingColorSpace(.sRGB) ?? NSColor.black
            self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
        }

        var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
        var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    }

    /// One mark on the Annotate canvas, in image pixels with a top-left origin.
    struct Annotation: Equatable {
        enum Kind: String, CaseIterable {
            case arrow, line, rect, ellipse, pen, highlight, text

            static let aliases: [String: Kind] = ["rectangle": .rect, "box": .rect, "oval": .ellipse, "circle": .ellipse,
                                                   "freehand": .pen, "draw": .pen, "highlighter": .highlight,
                                                   "marker": .highlight]
        }

        enum FontStyle: String, CaseIterable { case system, rounded, serif, mono }

        enum Weight: String, CaseIterable {
            case regular, medium, semibold, bold, heavy
            var nsWeight: NSFont.Weight {
                switch self {
                case .regular: return .regular
                case .medium: return .medium
                case .semibold: return .semibold
                case .bold: return .bold
                case .heavy: return .heavy
                }
            }
        }

        var kind: Kind
        /// arrow and line: [from, to]. rect, ellipse and highlight boxes: two opposite corners.
        /// pen and highlighter strokes: the path. text: [top-left].
        var points: [CGPoint]
        var color: RGBA
        var width: CGFloat
        var opacity: CGFloat = 1
        var fill: RGBA? = nil
        /// Highlights only: a filled box (true) or a wide stroke along `points` (false).
        var isBox = false
        var text = ""
        var fontSize: CGFloat = 24
        var font: FontStyle = .system
        var weight: Weight = .semibold
        var background: RGBA? = nil

        /// The box spanned by two corner points, whichever way they were dragged.
        var box: CGRect {
            guard points.count >= 2 else { return CGRect(origin: points.first ?? .zero, size: .zero) }
            return CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                          width: abs(points[1].x - points[0].x), height: abs(points[1].y - points[0].y))
        }

        mutating func move(by d: CGVector) {
            points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
        }

        // Defaults scale with the image so marks look the same on a small screenshot and a 50 MP photo.
        static func defaultWidth(for size: CGSize) -> CGFloat { max(2, (max(size.width, size.height) * 0.004).rounded()) }
        static func defaultTextSize(for size: CGSize) -> CGFloat { max(12, (max(size.width, size.height) * 0.028).rounded()) }
        static let defaultColor = RGBA(hex: "#FF3B30")!
        static let highlightColor = RGBA(hex: "#FFCC00")!

        // MARK: JSON

        /// Parses the `annotations` option (see the schema at the top of this file).
        static func parse(_ option: String, imageSize: CGSize) throws -> [Annotation] {
            var json = option.trimmingCharacters(in: .whitespacesAndNewlines)
            if json.hasPrefix("@") {
                let path = (String(json.dropFirst()) as NSString).expandingTildeInPath
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                    throw ConversionError.unsupported("Couldn’t read the annotations file \(path).")
                }
                json = text
            }
            guard !json.isEmpty else { return [] }
            let object: Any
            do {
                object = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
            } catch {
                throw ConversionError.unsupported("The annotations option isn’t valid JSON. Pass an array such as "
                                                  + #"[{"type":"arrow","from":[10,10],"to":[200,120]}]."#)
            }
            let items: [Any]
            if let array = object as? [Any] { items = array }
            else if let single = object as? [String: Any] { items = [single] }
            else { throw ConversionError.unsupported("The annotations option must be a JSON array of shapes.") }
            return try items.enumerated().map { try annotation(from: $0.element, number: $0.offset + 1, imageSize: imageSize) }
        }

        private static func annotation(from item: Any, number n: Int, imageSize: CGSize) throws -> Annotation {
            guard let d = item as? [String: Any] else {
                throw ConversionError.unsupported("Annotation \(n) isn’t an object like {\"type\":\"arrow\", …}.")
            }
            guard let typeName = (d["type"] as? String)?.lowercased() else {
                throw ConversionError.unsupported("Annotation \(n) has no “type”.")
            }
            guard let kind = Kind(rawValue: typeName) ?? Kind.aliases[typeName] else {
                throw ConversionError.unsupported("Annotation \(n) has an unknown type “\(typeName)”. "
                                                  + "Use arrow, line, rect, ellipse, pen, highlight or text.")
            }
            func color(_ key: String) throws -> RGBA? {
                guard let value = d[key] else { return nil }
                guard let s = value as? String, let c = RGBA(hex: s) else {
                    throw ConversionError.unsupported("Annotation \(n) has a “\(key)” YummyOrange doesn’t understand "
                                                      + "(\(value)). Use a color like #FF3B30 or “blue”.")
                }
                return c
            }
            func number(_ key: String) throws -> CGFloat? {
                guard let value = d[key] else { return nil }
                guard let v = (value as? NSNumber)?.doubleValue, v.isFinite else {
                    throw ConversionError.unsupported("Annotation \(n) has a “\(key)” that isn’t a number.")
                }
                return CGFloat(v)
            }
            let defaultWidth = defaultWidth(for: imageSize)
            var a = Annotation(kind: kind, points: [], color: try color("color") ?? (kind == .highlight ? highlightColor : defaultColor),
                               width: max(0.5, try number("width") ?? (kind == .highlight ? defaultWidth * 3.5 : defaultWidth)))
            a.opacity = min(1, max(0, try number("opacity") ?? (kind == .highlight ? 0.5 : 1)))
            a.fill = try color("fill")
            let label = "Annotation \(n) (\(kind.rawValue))"
            switch kind {
            case .arrow, .line:
                guard let from = point(d["from"]), let to = point(d["to"]) else {
                    throw ConversionError.unsupported("\(label) needs “from” and “to” as [x, y].")
                }
                a.points = [from, to]
            case .rect, .ellipse:
                guard let r = rect(d["rect"]) else {
                    throw ConversionError.unsupported("\(label) needs “rect” as [x, y, width, height].")
                }
                a.points = [r.origin, CGPoint(x: r.maxX, y: r.maxY)]
            case .pen:
                guard let pts = pointList(d["points"]) else {
                    throw ConversionError.unsupported("\(label) needs “points” as [[x, y], …].")
                }
                a.points = pts
            case .highlight:
                if let r = rect(d["rect"]) {
                    a.isBox = true
                    a.points = [r.origin, CGPoint(x: r.maxX, y: r.maxY)]
                } else if let pts = pointList(d["points"]) {
                    a.points = pts
                } else {
                    throw ConversionError.unsupported("\(label) needs “rect” as [x, y, width, height] "
                                                      + "or “points” as [[x, y], …].")
                }
            case .text:
                guard let at = point(d["at"]), let text = d["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ConversionError.unsupported("\(label) needs “at” as [x, y] and some “text”.")
                }
                a.points = [at]
                a.text = text
                a.fontSize = max(4, try number("size") ?? defaultTextSize(for: imageSize))
                if let f = d["font"] as? String {
                    guard let style = FontStyle(rawValue: f.lowercased()) else {
                        throw ConversionError.unsupported("\(label) has an unknown font “\(f)”. Use system, rounded, serif or mono.")
                    }
                    a.font = style
                }
                if let w = d["weight"] as? String {
                    guard let weight = Weight(rawValue: w.lowercased()) else {
                        throw ConversionError.unsupported("\(label) has an unknown weight “\(w)”. "
                                                          + "Use regular, medium, semibold, bold or heavy.")
                    }
                    a.weight = weight
                }
                a.background = try color("background")
            }
            return a
        }

        private static func numbers(_ value: Any?) -> [CGFloat]? {
            guard let array = value as? [Any] else { return nil }
            let nums = array.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard nums.count == array.count, nums.allSatisfy(\.isFinite) else { return nil }
            return nums.map { CGFloat($0) }
        }

        private static func point(_ value: Any?) -> CGPoint? {
            guard let n = numbers(value), n.count == 2 else { return nil }
            return CGPoint(x: n[0], y: n[1])
        }

        private static func rect(_ value: Any?) -> CGRect? {
            guard let n = numbers(value), n.count == 4 else { return nil }
            return CGRect(x: n[0], y: n[1], width: n[2], height: n[3]).standardized
        }

        private static func pointList(_ value: Any?) -> [CGPoint]? {
            guard let array = value as? [Any], !array.isEmpty else { return nil }
            let pts = array.compactMap(point)
            return pts.count == array.count ? pts : nil
        }

        /// The annotation as a JSON object (the same schema `parse` reads).
        var jsonObject: [String: Any] {
            func pt(_ p: CGPoint) -> [Double] { [Double(p.x), Double(p.y)] }
            func hex(_ c: RGBA) -> String {
                let v = [c.r, c.g, c.b, c.a].map { Int(($0 * 255).rounded()) }
                return v[3] == 255 ? String(format: "#%02X%02X%02X", v[0], v[1], v[2])
                                   : String(format: "#%02X%02X%02X%02X", v[0], v[1], v[2], v[3])
            }
            var d: [String: Any] = ["type": kind.rawValue, "color": hex(color), "width": Double(width)]
            if opacity != (kind == .highlight ? 0.5 : 1) { d["opacity"] = Double(opacity) }
            if let fill { d["fill"] = hex(fill) }
            let r = box
            switch kind {
            case .arrow, .line: d["from"] = pt(points[0]); d["to"] = pt(points[1])
            case .rect, .ellipse: d["rect"] = [r.minX, r.minY, r.width, r.height].map(Double.init)
            case .pen: d["points"] = points.map(pt)
            case .highlight:
                if isBox { d["rect"] = [r.minX, r.minY, r.width, r.height].map(Double.init) } else { d["points"] = points.map(pt) }
            case .text:
                d["at"] = pt(points[0]); d["text"] = text; d["size"] = Double(fontSize)
                if font != .system { d["font"] = font.rawValue }
                if weight != .semibold { d["weight"] = weight.rawValue }
                if let background { d["background"] = hex(background) }
            }
            return d
        }
    }

    // MARK: - Renderer

    /// Draws annotations with Core Graphics and Core Text, so it runs on any thread. The same code draws the
    /// editor's canvas and the saved file, so what you see is what gets saved.
    enum AnnotationRenderer {
        /// Draws into a context whose user space is image pixels with a top-left origin (y grows down).
        static func draw(_ items: [Annotation], in ctx: CGContext) {
            for item in items { draw(item, in: ctx) }
        }

        static func draw(_ a: Annotation, in ctx: CGContext) {
            guard !a.points.isEmpty else { return }
            ctx.saveGState()
            defer { ctx.restoreGState() }
            // Translucent marks draw into a layer first, so overlapping parts (an arrow's shaft and head, a
            // stroke crossing itself) don't double up. Highlights multiply onto the picture like a marker.
            let layered = a.opacity < 1 || a.kind == .highlight
            if layered {
                ctx.clip(to: bounds(of: a).insetBy(dx: -2, dy: -2))
                ctx.setAlpha(a.opacity)
                if a.kind == .highlight { ctx.setBlendMode(.multiply) }
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            defer { if layered { ctx.endTransparencyLayer() } }
            ctx.setLineWidth(a.width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setFillColor(a.color.cgColor)
            switch a.kind {
            case .line:
                ctx.strokeLineSegments(between: [a.points[0], a.points[a.points.count > 1 ? 1 : 0]])
            case .arrow:
                drawArrow(a, in: ctx)
            case .rect, .ellipse:
                let r = a.box
                let path = a.kind == .rect ? CGPath(rect: r, transform: nil) : CGPath(ellipseIn: r, transform: nil)
                if let fill = a.fill {
                    ctx.setFillColor(fill.cgColor)
                    ctx.addPath(path); ctx.fillPath()
                }
                ctx.addPath(path); ctx.strokePath()
            case .pen:
                drawStroke(a.points, width: a.width, in: ctx)
            case .highlight:
                if a.isBox {
                    ctx.fill(a.box)
                } else {
                    drawStroke(a.points, width: a.width, in: ctx)
                }
            case .text:
                drawText(a, in: ctx)
            }
        }

        /// A smooth stroke through the points (quadratic curves through midpoints); one point is a dot.
        private static func drawStroke(_ pts: [CGPoint], width: CGFloat, in ctx: CGContext) {
            if pts.count == 1 || pts.dropFirst().allSatisfy({ $0 == pts[0] }) {
                ctx.fillEllipse(in: CGRect(x: pts[0].x - width / 2, y: pts[0].y - width / 2, width: width, height: width))
                return
            }
            ctx.addPath(smoothPath(pts))
            ctx.strokePath()
        }

        static func smoothPath(_ pts: [CGPoint]) -> CGPath {
            let path = CGMutablePath()
            path.move(to: pts[0])
            if pts.count == 2 { path.addLine(to: pts[1]); return path }
            for i in 1..<(pts.count - 1) {
                let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
                path.addQuadCurve(to: mid, control: pts[i])
            }
            path.addLine(to: pts[pts.count - 1])
            return path
        }

        /// Arrow geometry: a swept head whose size follows the stroke width, shrinking for very short arrows.
        static func arrowHead(_ a: Annotation) -> (tip: CGPoint, left: CGPoint, notch: CGPoint, right: CGPoint)? {
            guard a.points.count >= 2 else { return nil }
            let from = a.points[0], to = a.points[1]
            let dx = to.x - from.x, dy = to.y - from.y
            let length = hypot(dx, dy)
            guard length > 0.5 else { return nil }
            let ux = dx / length, uy = dy / length
            let headLength = min(max(a.width * 3.6, 10), length * 0.7)
            let halfWidth = headLength * 0.58
            let base = CGPoint(x: to.x - ux * headLength, y: to.y - uy * headLength)
            return (to,
                    CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth),
                    CGPoint(x: to.x - ux * headLength * 0.72, y: to.y - uy * headLength * 0.72),
                    CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth))
        }

        private static func drawArrow(_ a: Annotation, in ctx: CGContext) {
            guard let head = arrowHead(a) else {
                drawStroke([a.points[0]], width: a.width, in: ctx)
                return
            }
            ctx.strokeLineSegments(between: [a.points[0], head.notch])
            let path = CGMutablePath()
            path.addLines(between: [head.tip, head.left, head.notch, head.right])
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setLineWidth(max(1, a.width * 0.35))
            ctx.drawPath(using: .fillStroke)   // the thin stroke rounds the head's corners
        }

        // MARK: Text

        static func font(for a: Annotation) -> CTFont {
            let size = max(1, a.fontSize)
            var font: NSFont = a.font == .mono ? .monospacedSystemFont(ofSize: size, weight: a.weight.nsWeight)
                                               : .systemFont(ofSize: size, weight: a.weight.nsWeight)
            if a.font == .rounded || a.font == .serif,
               let descriptor = font.fontDescriptor.withDesign(a.font == .rounded ? .rounded : .serif),
               let designed = NSFont(descriptor: descriptor, size: size) {
                font = designed
            }
            return font as CTFont
        }

        /// Lines of text with their metrics; the box's origin is the annotation's top-left.
        static func textLayout(_ a: Annotation) -> (lines: [CTLine], ascent: CGFloat, lineHeight: CGFloat, size: CGSize) {
            let font = font(for: a)
            let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
            let lineHeight = ceil(ascent + descent + max(leading, a.fontSize * 0.08))
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): a.color.cgColor,
            ]
            let lines = a.text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map {
                CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes))
            }
            let width = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
            return (lines, ascent, lineHeight, CGSize(width: ceil(width), height: lineHeight * CGFloat(lines.count)))
        }

        static func textPadding(_ a: Annotation) -> CGFloat { a.background == nil ? 0 : (a.fontSize * 0.3).rounded() }

        private static func drawText(_ a: Annotation, in ctx: CGContext) {
            let layout = textLayout(a)
            let origin = a.points[0]
            if let background = a.background {
                let pad = textPadding(a)
                let box = CGRect(origin: origin, size: layout.size).insetBy(dx: -pad, dy: -pad * 0.6)
                ctx.setFillColor(background.cgColor)
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: pad, cornerHeight: pad, transform: nil))
                ctx.fillPath()
            }
            for (i, line) in layout.lines.enumerated() {
                ctx.saveGState()
                // The context is y-down; flip locally around the baseline so glyphs stand upright.
                ctx.translateBy(x: origin.x, y: origin.y + layout.ascent + layout.lineHeight * CGFloat(i))
                ctx.scaleBy(x: 1, y: -1)
                ctx.textMatrix = .identity
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
        }

        // MARK: Geometry

        /// Where the mark paints, in image pixels, including stroke width and arrow heads.
        static func bounds(of a: Annotation) -> CGRect {
            switch a.kind {
            case .text:
                let size = textLayout(a).size
                let pad = textPadding(a)
                return CGRect(origin: a.points.first ?? .zero, size: size).insetBy(dx: -pad, dy: -pad * 0.6)
            case .highlight where a.isBox:
                return a.box
            default:
                var pts = a.points
                if a.kind == .arrow, let head = arrowHead(a) { pts += [head.left, head.right] }
                guard let first = pts.first else { return .zero }
                var r = CGRect(origin: first, size: .zero)
                for p in pts.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
                return r.insetBy(dx: -a.width / 2, dy: -a.width / 2)
            }
        }

        /// Whether a point (image pixels) touches the mark. `slop` widens the target. With `interior`, the
        /// inside of rectangles and ellipses counts too.
        static func hit(_ a: Annotation, at p: CGPoint, slop: CGFloat, interior: Bool) -> Bool {
            let reach = a.width / 2 + slop
            switch a.kind {
            case .line, .arrow:
                if a.kind == .arrow, let head = arrowHead(a),
                   CGRect(origin: head.tip, size: .zero).union(CGRect(origin: head.left, size: .zero))
                    .union(CGRect(origin: head.right, size: .zero)).insetBy(dx: -slop, dy: -slop).contains(p) { return true }
                return distance(p, a.points[0], a.points[min(1, a.points.count - 1)]) <= reach
            case .pen:
                return polylineDistance(p, a.points) <= reach
            case .highlight:
                return a.isBox ? a.box.insetBy(dx: -slop, dy: -slop).contains(p) : polylineDistance(p, a.points) <= reach
            case .text:
                return bounds(of: a).insetBy(dx: -slop, dy: -slop).contains(p)
            case .rect:
                let r = a.box
                if (interior || a.fill != nil) && r.contains(p) { return true }
                let outer = r.insetBy(dx: -reach, dy: -reach), inner = r.insetBy(dx: reach, dy: reach)
                return outer.contains(p) && (inner.isNull || inner.isEmpty || !inner.contains(p))
            case .ellipse:
                let r = a.box
                let rx = max(r.width / 2, 0.5), ry = max(r.height / 2, 0.5)
                let nx = (p.x - r.midX) / rx, ny = (p.y - r.midY) / ry
                let d = sqrt(nx * nx + ny * ny)
                if (interior || a.fill != nil) && d <= 1 { return true }
                return abs(d - 1) * min(rx, ry) <= reach
            }
        }

        private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
            return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
        }

        private static func polylineDistance(_ p: CGPoint, _ pts: [CGPoint]) -> CGFloat {
            guard pts.count > 1 else { return pts.first.map { hypot(p.x - $0.x, p.y - $0.y) } ?? .infinity }
            return zip(pts, pts.dropFirst()).map { distance(p, $0, $1) }.min() ?? .infinity
        }

        // MARK: Saving

        /// Burns the marks into a full-resolution copy of `image` (same size, depth, RGB space and alpha).
        /// `coordinateSize` is the size the marks were placed against, when the decoded image differs from
        /// what the file's header said (some camera raw files do).
        static func burn(_ items: [Annotation], into image: CGImage, coordinateSize: CGSize? = nil) throws -> CGImage {
            let ctx = try ImageEditors.context(like: image)
            ctx.translateBy(x: 0, y: CGFloat(image.height))
            ctx.scaleBy(x: 1, y: -1)
            if let size = coordinateSize, size.width > 0, size.height > 0 {
                ctx.scaleBy(x: CGFloat(image.width) / size.width, y: CGFloat(image.height) / size.height)
            }
            draw(items, in: ctx)
            guard let result = ctx.makeImage() else { throw ConversionError.toolFailed("Couldn’t draw the annotations.") }
            return result
        }

        /// Headless entry point (`--tool annotate --opt annotations='[…]' photo.png`): writes "<name> annotated.<ext>".
        static func save(_ url: URL, options: ToolOptions) throws -> URL {
            let source = try SourceImage(url)
            let items = try Annotation.parse(options["annotations"] ?? "", imageSize: source.size)
            guard !items.isEmpty else {
                throw ConversionError.unsupported("There are no annotations to draw. Pass them as JSON, for example "
                                                  + #"annotations=[{"type":"arrow","from":[40,40],"to":[300,200]}]."#)
            }
            return try save(items, source: source, quality: options.double("quality", 0.92))
        }

        static func save(_ items: [Annotation], source: SourceImage, quality: Double = 0.92) throws -> URL {
            let full = try source.fullImage()
            return try source.save(try burn(items, into: full, coordinateSize: source.size), suffix: " annotated", quality: quality)
        }
    }
}
