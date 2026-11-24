import Foundation
import CoreGraphics
import CoreText
import ImageIO

/// A fill, resolved against the theme and colour map.
enum PPTXFill {
    case none
    case solid(PPTXColor)
    case gradient(PPTXGradient)
    case picture(PPTXPicture)
    case pattern(String, PPTXColor, PPTXColor)
    case group
}

struct PPTXGradient {
    var stops: [(CGFloat, PPTXColor)]
    var linear = true
    var angle: Double = 90
    var scaled = false
    var path = "circle"
    /// The focus rectangle (`a:fillToRect`) as fractions of the box: l, t, r, b insets.
    var focus = (l: CGFloat(0.5), t: CGFloat(0.5), r: CGFloat(0.5), b: CGFloat(0.5))
}

struct PPTXPicture {
    var part: String
    /// Crop insets as fractions (negative values pad).
    var crop = (l: CGFloat(0), t: CGFloat(0), r: CGFloat(0), b: CGFloat(0))
    var fillRect = (l: CGFloat(0), t: CGFloat(0), r: CGFloat(0), b: CGFloat(0))
    var tile: (sx: CGFloat, sy: CGFloat, tx: CGFloat, ty: CGFloat)?
    var alpha: CGFloat = 1
    var grayscale = false
}

/// An outline (`a:ln`) resolved against the theme line style.
struct PPTXLine {
    var width: CGFloat = 0.75
    var color: PPTXColor?
    var dash = "solid"
    var custom: [CGFloat]?
    var cap = CGLineCap.butt
    var join = CGLineJoin.round
    var head: (String, String, String)?
    var tail: (String, String, String)?
}

/// Renders the slides of a deck with Core Graphics and Core Text.
final class PPTXRenderer {
    let deck: PPTXDeck
    let fonts = PPTXFontBook()

    init(_ deck: PPTXDeck) { self.deck = deck }

    /// What's needed while drawing one slide.
    private struct Scene {
        let chain: PPTXDeck.Chain
        let colors: PPTXColors
        let number: Int
        let pixelScale: CGFloat
        let pdf: Bool
        let slidePart: String
    }

    /// The part whose relationships resolve images, and whether its placeholders inherit (slides only).
    private struct Owner {
        let part: String
        let isSlide: Bool
    }

    /// Maps EMU coordinates of a shape tree (including group transforms) to slide points.
    private struct Frame {
        var sx: CGFloat = 1 / 12700, sy: CGFloat = 1 / 12700, tx: CGFloat = 0, ty: CGFloat = 0
        func rect(_ x: Double, _ y: Double, _ cx: Double, _ cy: Double) -> CGRect {
            let x0 = CGFloat(x) * sx + tx, y0 = CGFloat(y) * sy + ty
            let x1 = CGFloat(x + cx) * sx + tx, y1 = CGFloat(y + cy) * sy + ty
            return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        }
        var mirrored: (Bool, Bool) { (sx < 0, sy < 0) }
    }

    private struct Xfrm {
        var x = 0.0, y = 0.0, cx = 0.0, cy = 0.0
        var rot = 0.0
        var flipH = false, flipV = false
        var ch: (x: Double, y: Double, cx: Double, cy: Double)?

        init?(_ n: PPTXNode?) {
            guard let n else { return nil }
            guard let off = n.child("a:off"), let ext = n.child("a:ext") else { return nil }
            x = off.double("x") ?? 0; y = off.double("y") ?? 0
            cx = ext.double("cx") ?? 0; cy = ext.double("cy") ?? 0
            rot = (n.double("rot") ?? 0) / 60000
            flipH = n.bool("flipH") ?? false; flipV = n.bool("flipV") ?? false
            if let o = n.child("a:chOff"), let e = n.child("a:chExt") {
                ch = (o.double("x") ?? 0, o.double("y") ?? 0, e.double("cx") ?? 0, e.double("cy") ?? 0)
            }
        }
    }

    // MARK: Slides

    /// Draws one slide into a y-down context measured in points (the caller flips and scales).
    func draw(_ slide: PPTXDeck.Slide, in ctx: CGContext, pixelScale: CGFloat, pdf: Bool) {
        let size = deck.size
        guard let chain = deck.chain(for: slide) else {
            ctx.setFillColor(.white); ctx.fill(CGRect(origin: .zero, size: size)); return
        }
        let scene = Scene(chain: chain, colors: PPTXColors(theme: chain.theme, map: chain.colorMap), number: slide.number,
                          pixelScale: pixelScale, pdf: pdf, slidePart: slide.part)
        ctx.saveGState()
        ctx.clip(to: CGRect(origin: .zero, size: size))
        drawBackground(scene, ctx: ctx)
        if chain.slide.bool("showMasterSp") != false {
            if chain.layout?.bool("showMasterSp") != false, let master = chain.master, let mp = chain.masterPart {
                drawTree(master.at("p:cSld", "p:spTree"), frame: Frame(), owner: Owner(part: mp, isSlide: false),
                         scene: scene, ctx: ctx, groupFill: nil)
            }
            if let layout = chain.layout, let lp = chain.layoutPart {
                drawTree(layout.at("p:cSld", "p:spTree"), frame: Frame(), owner: Owner(part: lp, isSlide: false),
                         scene: scene, ctx: ctx, groupFill: nil)
            }
        }
        drawTree(chain.slide.at("p:cSld", "p:spTree"), frame: Frame(), owner: Owner(part: slide.part, isSlide: true),
                 scene: scene, ctx: ctx, groupFill: nil)
        ctx.restoreGState()
    }

    private func drawBackground(_ scene: Scene, ctx: CGContext) {
        let rect = CGRect(origin: .zero, size: deck.size)
        let c = scene.chain
        for (node, part) in [(c.slide, scene.slidePart), (c.layout, c.layoutPart), (c.master, c.masterPart)] {
            guard let bg = node?.at("p:cSld", "p:bg"), let part else { continue }
            var fill: PPTXFill?
            if let pr = bg.child("p:bgPr") {
                fill = self.fill(in: pr, colors: scene.colors, owner: part)
            } else if let ref = bg.child("p:bgRef"), let idx = ref.int("idx") {
                fill = styleFill(idx, phClr: scene.colors.colorChild(ref), scene: scene, background: true)
            }
            guard let f = fill else { continue }
            ctx.setFillColor(.white)
            ctx.fill(rect)
            paint(f, path: CGPath(rect: rect, transform: nil), evenOdd: false, box: rect, shade: "norm", scene: scene, ctx: ctx)
            return
        }
        ctx.setFillColor(.white)
        ctx.fill(rect)
    }

    // MARK: Shape trees

    private func drawTree(_ tree: PPTXNode?, frame: Frame, owner: Owner, scene: Scene, ctx: CGContext, groupFill: PPTXFill?) {
        guard let tree else { return }
        for node in tree.children {
            // Placeholders on layouts and masters are templates, never drawn on the slide.
            if !owner.isSlide, PPTXDeck.placeholder(of: node) != nil { continue }
            switch node.name {
            case "p:sp", "p:cxnSp": drawShape(node, frame: frame, owner: owner, scene: scene, ctx: ctx, groupFill: groupFill)
            case "p:pic": drawPicture(node, frame: frame, owner: owner, scene: scene, ctx: ctx)
            case "p:grpSp": drawGroup(node, frame: frame, owner: owner, scene: scene, ctx: ctx, groupFill: groupFill)
            case "p:graphicFrame": drawGraphicFrame(node, frame: frame, owner: owner, scene: scene, ctx: ctx)
            default: break
            }
        }
    }

    /// The shape and the layout and master placeholders it inherits from (nearest first).
    private func inheritance(_ node: PPTXNode, owner: Owner, scene: Scene) -> [PPTXNode] {
        guard owner.isSlide, let ph = PPTXDeck.placeholder(of: node) else { return [node] }
        var out = [node]
        let layoutShape = PPTXDeck.match(ph, in: scene.chain.layout?.at("p:cSld", "p:spTree"), master: false)
        if let l = layoutShape { out.append(l) }
        let masterPh = layoutShape.flatMap { PPTXDeck.placeholder(of: $0) } ?? ph
        if let m = PPTXDeck.match(masterPh, in: scene.chain.master?.at("p:cSld", "p:spTree"), master: true) { out.append(m) }
        return out
    }

    private func spPr(_ n: PPTXNode) -> PPTXNode? { n.child("p:spPr") ?? n.child("p:grpSpPr") }

    /// Applies rotation and flips for a shape box, leaving the CTM at the box's top-left.
    private func enter(_ rect: CGRect, rot: Double, flipH: Bool, flipV: Bool, ctx: CGContext) {
        ctx.translateBy(x: rect.midX, y: rect.midY)
        if rot != 0 { ctx.rotate(by: CGFloat(rot * .pi / 180)) }
        if flipH || flipV { ctx.scaleBy(x: flipH ? -1 : 1, y: flipV ? -1 : 1) }
        ctx.translateBy(x: -rect.width / 2, y: -rect.height / 2)
    }

    /// Placement of a shape: its box in slide points plus rotation and flips with group mirroring folded in.
    private func placement(_ xf: Xfrm, frame: Frame) -> (CGRect, Double, Bool, Bool) {
        let rect = frame.rect(xf.x, xf.y, xf.cx, xf.cy)
        let (mx, my) = frame.mirrored
        let flipH = xf.flipH != mx, flipV = xf.flipV != my
        let rot = mx != my ? -xf.rot : xf.rot
        return (rect, rot, flipH, flipV)
    }

    private func drawShape(_ node: PPTXNode, frame: Frame, owner: Owner, scene: Scene, ctx: CGContext, groupFill: PPTXFill?) {
        let chain = inheritance(node, owner: owner, scene: scene)
        guard let xf = chain.lazy.compactMap({ Xfrm(self.spPr($0)?.child("a:xfrm")) }).first else { return }
        let (rect, rot, flipH, flipV) = placement(xf, frame: frame)
        let w = rect.width, h = rect.height
        let style = chain.lazy.compactMap { $0.child("p:style") }.first
        let geoSource = chain.lazy.compactMap { self.spPr($0) }.first { $0.child("a:prstGeom") != nil || $0.child("a:custGeom") != nil }
        let geometry = PPTXShapes.geometry(of: geoSource, w: w, h: h)

        var fill: PPTXFill?
        for n in chain {
            if let f = self.fill(in: spPr(n), colors: scene.colors, owner: owner.part) { fill = f; break }
        }
        if fill == nil, let ref = style?.child("a:fillRef"), let idx = ref.int("idx") {
            fill = styleFill(idx, phClr: scene.colors.colorChild(ref), scene: scene, background: false)
        }
        if case .group? = fill { fill = groupFill ?? PPTXFill.none }
        let line = self.line(chain.lazy.compactMap { self.spPr($0)?.child("a:ln") }.first, style: style, scene: scene)
        let shadow = self.shadow(spPr(node), style: style, scene: scene)

        ctx.saveGState()
        enter(rect, rot: rot, flipH: flipH, flipV: flipV, ctx: ctx)
        drawGeometry(geometry, fill: fill ?? PPTXFill.none, line: line, shadow: shadow, size: CGSize(width: w, height: h),
                     scene: scene, ctx: ctx)
        ctx.restoreGState()

        if let tx = node.child("p:txBody") {
            var textRect = geometry.textRect
            if let t = Xfrm(node.child("p:txXfrm")) {
                // SmartArt drawings give the text box separately.
                let r = frame.rect(t.x, t.y, t.cx, t.cy)
                textRect = CGRect(x: r.minX - rect.minX, y: r.minY - rect.minY, width: r.width, height: r.height)
            } else if flipH != flipV {
                textRect.origin.x = w - textRect.maxX
            }
            ctx.saveGState()
            enter(rect, rot: rot + (flipV ? 180 : 0), flipH: false, flipV: false, ctx: ctx)
            drawText(tx, chain: chain, style: style, box: textRect, scene: scene, ctx: ctx)
            ctx.restoreGState()
        }
        linkAnnotation(node, rect: rect, owner: owner, scene: scene, ctx: ctx)
    }

    private func drawGroup(_ node: PPTXNode, frame: Frame, owner: Owner, scene: Scene, ctx: CGContext, groupFill: PPTXFill?) {
        let props = node.child("p:grpSpPr")
        var child = frame
        var gFill = groupFill
        if let f = fill(in: props, colors: scene.colors, owner: owner.part) {
            if case .group = f {} else { gFill = f }
        }
        ctx.saveGState()
        if let xf = Xfrm(props?.child("a:xfrm")) {
            let (rect, rot, _, _) = placement(xf, frame: frame)
            let ch = xf.ch ?? (xf.x, xf.y, xf.cx, xf.cy)
            let kx = ch.cx != 0 ? xf.cx / ch.cx : 1, ky = ch.cy != 0 ? xf.cy / ch.cy : 1
            // child EMU → group EMU: off + (v - chOff) * k, with the group's own flips mirrored about its centre.
            var ax = kx, bx = xf.x - ch.x * kx, ay = ky, by = xf.y - ch.y * ky
            if xf.flipH { ax = -ax; bx = 2 * xf.x + xf.cx - bx }
            if xf.flipV { ay = -ay; by = 2 * xf.y + xf.cy - by }
            child = Frame(sx: frame.sx * CGFloat(ax), sy: frame.sy * CGFloat(ay),
                          tx: frame.sx * CGFloat(bx) + frame.tx, ty: frame.sy * CGFloat(by) + frame.ty)
            if rot != 0 {
                ctx.translateBy(x: rect.midX, y: rect.midY)
                ctx.rotate(by: CGFloat(rot * .pi / 180))
                ctx.translateBy(x: -rect.midX, y: -rect.midY)
            }
        }
        drawTree(node, frame: child, owner: owner, scene: scene, ctx: ctx, groupFill: gFill)
        ctx.restoreGState()
    }

    // MARK: Pictures

    private func drawPicture(_ node: PPTXNode, frame: Frame, owner: Owner, scene: Scene, ctx: CGContext) {
        let chain = inheritance(node, owner: owner, scene: scene)
        guard let xf = chain.lazy.compactMap({ Xfrm(self.spPr($0)?.child("a:xfrm")) }).first else { return }
        let (rect, rot, flipH, flipV) = placement(xf, frame: frame)
        let style = node.child("p:style")
        let geometry = PPTXShapes.geometry(of: spPr(node), w: rect.width, h: rect.height)
        let pictureFill = node.child("p:blipFill").flatMap { blipFill($0, owner: owner.part) }
        let line = self.line(spPr(node)?.child("a:ln"), style: style, scene: scene)
        let shadow = self.shadow(spPr(node), style: style, scene: scene)
        ctx.saveGState()
        enter(rect, rot: rot, flipH: flipH, flipV: flipV, ctx: ctx)
        let fill: PPTXFill = pictureFill.map { .picture($0) } ?? self.fill(in: spPr(node), colors: scene.colors, owner: owner.part) ?? .none
        drawGeometry(geometry, fill: fill, line: line, shadow: shadow, size: rect.size, scene: scene, ctx: ctx)
        ctx.restoreGState()
        linkAnnotation(node, rect: rect, owner: owner, scene: scene, ctx: ctx)
    }

    private func blipFill(_ n: PPTXNode, owner: String) -> PPTXPicture? {
        guard let blip = n.child("a:blip"), let rid = blip["r:embed"] ?? blip["r:link"],
              let rel = deck.pkg.rels(owner)[rid], !rel.external else { return nil }
        var pic = PPTXPicture(part: rel.target)
        func frac(_ node: PPTXNode?, _ k: String) -> CGFloat { CGFloat(node?.double(k) ?? 0) / 100000 }
        if let s = n.child("a:srcRect") { pic.crop = (frac(s, "l"), frac(s, "t"), frac(s, "r"), frac(s, "b")) }
        if let f = n.child("a:stretch")?.child("a:fillRect") { pic.fillRect = (frac(f, "l"), frac(f, "t"), frac(f, "r"), frac(f, "b")) }
        if let t = n.child("a:tile") {
            pic.tile = (CGFloat(t.double("sx") ?? 100000) / 100000, CGFloat(t.double("sy") ?? 100000) / 100000,
                        CGFloat(t.double("tx") ?? 0) / 12700, CGFloat(t.double("ty") ?? 0) / 12700)
        }
        if let a = blip.child("a:alphaModFix")?.double("amt") { pic.alpha = CGFloat(a / 100000) }
        pic.grayscale = blip.child("a:grayscl") != nil
        return pic
    }

    // MARK: Graphic frames

    private func drawGraphicFrame(_ node: PPTXNode, frame: Frame, owner: Owner, scene: Scene, ctx: CGContext) {
        let chain = inheritance(node, owner: owner, scene: scene)
        guard let xf = chain.lazy.compactMap({ Xfrm($0.child("p:xfrm")) ?? Xfrm(self.spPr($0)?.child("a:xfrm")) }).first,
              let data = node.at("a:graphic", "a:graphicData") else { return }
        let (rect, rot, flipH, flipV) = placement(xf, frame: frame)
        let uri = data["uri"] ?? ""
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let tbl = data.child("a:tbl") {
            enter(rect, rot: rot, flipH: flipH, flipV: flipV, ctx: ctx)
            drawTable(tbl, size: rect.size, owner: owner, scene: scene, ctx: ctx)
        } else if uri.hasSuffix("/chart"), let rid = data.child("c:chart")?["r:id"], let rel = deck.pkg.rels(owner.part)[rid] {
            enter(rect, rot: rot, flipH: flipH, flipV: flipV, ctx: ctx)
            PPTXChart(deck: deck, part: rel.target, colors: scene.colors, fonts: fonts).draw(size: rect.size, ctx: ctx)
        } else if uri.hasSuffix("/diagram"), let drawing = diagramDrawing(data, owner: owner.part) {
            // SmartArt: Office saves a drawn copy of the diagram; its shapes are relative to the frame.
            enter(rect, rot: rot, flipH: flipH, flipV: flipV, ctx: ctx)
            drawTree(drawing.tree, frame: Frame(), owner: Owner(part: drawing.part, isSlide: false), scene: scene, ctx: ctx, groupFill: nil)
        } else if let ole = data.child("p:oleObj") ?? data.descendants("p:oleObj").first, let pic = ole.child("p:pic") {
            if let px = Xfrm(spPr(pic)?.child("a:xfrm")), px.cx > 0 {
                drawPicture(pic, frame: frame, owner: owner, scene: scene, ctx: ctx)
            } else {
                // The preview picture has no position of its own: fit it to the frame.
                if let pf = pic.child("p:blipFill").flatMap({ blipFill($0, owner: owner.part) }) {
                    enter(rect, rot: rot, flipH: flipH, flipV: flipV, ctx: ctx)
                    let g = PPTXGeometry.rect(rect.width, rect.height)
                    drawGeometry(g, fill: .picture(pf), line: nil, shadow: nil, size: rect.size, scene: scene, ctx: ctx)
                }
            }
        }
    }

    /// The drawn copy of a SmartArt diagram that Office stores next to its data (`dsp:drawing`).
    private func diagramDrawing(_ data: PPTXNode, owner: String) -> (tree: PPTXNode, part: String)? {
        let rels = deck.pkg.rels(owner)
        var target: String?
        if let ids = data.child("dgm:relIds"), let dm = ids["r:dm"], let dataPart = rels[dm]?.target,
           let model = deck.pkg.xml(dataPart),
           let ext = model.descendants("p:dataModelExt").first?["relId"], let rel = rels[ext] {
            target = rel.target
        }
        if target == nil {
            let drawings = rels.values.filter { $0.kind == "diagramDrawing" }
            if drawings.count == 1 { target = drawings[0].target }
        }
        guard let part = target, let root = deck.pkg.xml(part), let tree = root.child("p:spTree") else { return nil }
        return (tree, part)
    }

    // MARK: Fills

    static let fillNames: Set<String> = ["a:noFill", "a:solidFill", "a:gradFill", "a:blipFill", "a:pattFill", "a:grpFill"]

    /// The fill set directly on a properties element (`p:spPr`, `p:bgPr`, `a:tcPr`), or nil when none is set.
    func fill(in props: PPTXNode?, colors: PPTXColors, owner: String) -> PPTXFill? {
        guard let f = props?.first(of: Self.fillNames) else { return nil }
        return parseFill(f, colors: colors, owner: owner)
    }

    func parseFill(_ f: PPTXNode, colors: PPTXColors, owner: String) -> PPTXFill {
        switch f.name {
        case "a:noFill": return .none
        case "a:solidFill": return colors.colorChild(f).map { .solid($0) } ?? .none
        case "a:grpFill": return .group
        case "a:pattFill":
            return .pattern(f["prst"] ?? "pct50", colors.colorChild(f.child("a:fgClr")) ?? .black,
                            colors.colorChild(f.child("a:bgClr")) ?? .white)
        case "a:blipFill": return blipFill(f, owner: owner).map { .picture($0) } ?? .none
        case "a:gradFill":
            var g = PPTXGradient(stops: [])
            for gs in f.child("a:gsLst")?.all("a:gs") ?? [] {
                if let c = colors.colorChild(gs) { g.stops.append((min(1, max(0, CGFloat(gs.double("pos") ?? 0) / 100000)), c)) }
            }
            g.stops.sort { $0.0 < $1.0 }
            if g.stops.isEmpty { return .none }
            if g.stops.count == 1 { return .solid(g.stops[0].1) }
            if let lin = f.child("a:lin") {
                g.angle = (lin.double("ang") ?? 0) / 60000
                g.scaled = lin.bool("scaled") ?? false
            } else if let p = f.child("a:path") {
                g.linear = false
                g.path = p["path"] ?? "circle"
                if let r = p.child("a:fillToRect") {
                    g.focus = (CGFloat(r.double("l") ?? 0) / 100000, CGFloat(r.double("t") ?? 0) / 100000,
                               CGFloat(r.double("r") ?? 0) / 100000, CGFloat(r.double("b") ?? 0) / 100000)
                }
            } else {
                g.angle = 90
            }
            return .gradient(g)
        default: return .none
        }
    }

    /// A fill from the theme's format scheme (`a:fillRef`, `p:bgRef`).
    private func styleFill(_ idx: Int, phClr: PPTXColor?, scene: Scene, background: Bool) -> PPTXFill? {
        let theme = scene.chain.theme
        let list = idx >= 1000 ? theme.bgFillStyles : theme.fillStyles
        let i = idx >= 1000 ? idx - 1001 : idx - 1
        guard idx != 0 else { return PPTXFill.none }
        guard i >= 0, i < list.count else { return phClr.map { .solid($0) } }
        return parseFill(list[i], colors: scene.colors.with(phClr: phClr), owner: scene.chain.themePart ?? "")
    }

    private func line(_ ln: PPTXNode?, style: PPTXNode?, scene: Scene) -> PPTXLine? {
        var result: PPTXLine?
        var colors = scene.colors
        var source: [PPTXNode] = []
        if let ref = style?.child("a:lnRef"), let idx = ref.int("idx"), idx > 0, idx <= scene.chain.theme.lineStyles.count {
            colors = colors.with(phClr: colors.colorChild(ref))
            source.append(scene.chain.theme.lineStyles[idx - 1])
        }
        if let ln { source.append(ln) }
        for (i, n) in source.enumerated() {
            let c = i == source.count - 1 && ln != nil ? scene.colors : colors
            var l = result ?? PPTXLine()
            if let w = n.double("w") { l.width = CGFloat(w) / 12700 }
            if let cap = n["cap"] { l.cap = cap == "rnd" ? .round : cap == "sq" ? .square : .butt }
            if n.child("a:noFill") != nil { l.color = nil; result = l; result?.width = -1; continue }
            if let s = n.child("a:solidFill") { l.color = c.colorChild(s) }
            else if let g = n.child("a:gradFill") { l.color = c.colorChild(g.child("a:gsLst")?.child("a:gs")) }
            else if let p = n.child("a:pattFill") { l.color = c.colorChild(p.child("a:fgClr")) }
            if let d = n.child("a:prstDash")?["val"] { l.dash = d; l.custom = nil }
            if let cd = n.child("a:custDash") {
                l.custom = cd.all("a:ds").flatMap { [CGFloat($0.double("d") ?? 100000) / 100000, CGFloat($0.double("sp") ?? 100000) / 100000] }
            }
            if n.child("a:round") != nil { l.join = .round }
            if n.child("a:bevel") != nil { l.join = .bevel }
            if n.child("a:miter") != nil { l.join = .miter }
            if let he = n.child("a:headEnd") { l.head = (he["type"] ?? "none", he["w"] ?? "med", he["len"] ?? "med") }
            if let te = n.child("a:tailEnd") { l.tail = (te["type"] ?? "none", te["w"] ?? "med", te["len"] ?? "med") }
            result = l
        }
        guard let r = result, r.width >= 0, r.color != nil else { return nil }
        return r
    }

    private func shadow(_ spPr: PPTXNode?, style: PPTXNode?, scene: Scene) -> PPTXShadow? {
        if let fx = spPr?.child("a:effectLst") { return PPTXShadow(fx, colors: scene.colors) }
        if spPr?.child("a:effectDag") != nil { return nil }
        if let ref = style?.child("a:effectRef"), let idx = ref.int("idx"), idx > 0, idx <= scene.chain.theme.effectStyles.count {
            let fx = scene.chain.theme.effectStyles[idx - 1].child("a:effectLst")
            return PPTXShadow(fx, colors: scene.colors.with(phClr: scene.colors.colorChild(ref)))
        }
        return nil
    }

    // MARK: Painting

    private func shaded(_ c: PPTXColor, _ shade: String) -> PPTXColor {
        func mix(_ t: PPTXColor, _ k: Double) -> PPTXColor {
            PPTXColor(r: c.r + (t.r - c.r) * k, g: c.g + (t.g - c.g) * k, b: c.b + (t.b - c.b) * k, a: c.a)
        }
        switch shade {
        case "lighten": return mix(.white, 0.4)
        case "lightenLess": return mix(.white, 0.2)
        case "darken": return mix(.black, 0.4)
        case "darkenLess": return mix(.black, 0.2)
        default: return c
        }
    }

    private func drawGeometry(_ g: PPTXGeometry, fill: PPTXFill, line: PPTXLine?, shadow: PPTXShadow?, size: CGSize,
                              scene: Scene, ctx: CGContext) {
        let box = CGRect(origin: .zero, size: size)
        let hasFill: Bool = { if case .none = fill { return false }; return true }()
        guard hasFill || line != nil else { return }
        ctx.saveGState()
        if let s = shadow {
            let rad = s.direction * .pi / 180
            // Shadow offsets are in device space: undo the y flip, scale to pixels, ignore the shape's rotation.
            let t = ctx.ctm
            let dx = CGFloat(cos(rad)) * s.distance, dy = CGFloat(sin(rad)) * s.distance
            let flipY: CGFloat = t.a * t.d - t.b * t.c < 0 ? -1 : 1
            ctx.setShadow(offset: CGSize(width: dx * scene.pixelScale, height: dy * scene.pixelScale * flipY),
                          blur: s.blur * scene.pixelScale, color: s.color.cgColor)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        func strokeAll() {
            guard let line else { return }
            for p in g.paths where p.stroke { stroke(p, line: line, scene: scene, ctx: ctx) }
        }
        if g.strokeUnderFill { strokeAll() }
        if hasFill {
            for p in g.paths where p.fill {
                paint(fill, path: p.path, evenOdd: p.evenOdd, box: box, shade: p.shade, scene: scene, ctx: ctx)
            }
        }
        if !g.strokeUnderFill { strokeAll() }
        if shadow != nil { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    private func paint(_ fill: PPTXFill, path: CGPath, evenOdd: Bool, box: CGRect, shade: String, scene: Scene, ctx: CGContext) {
        let rule: CGPathFillRule = evenOdd ? .evenOdd : .winding
        switch fill {
        case .none, .group:
            return
        case .solid(let c):
            ctx.setFillColor(shaded(c, shade).cgColor)
            ctx.addPath(path)
            ctx.fillPath(using: rule)
        case .pattern(let prst, let fg, let bg):
            paintPattern(prst, fg: shaded(fg, shade), bg: shaded(bg, shade), path: path, rule: rule, ctx: ctx)
        case .gradient(let g):
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip(using: rule)
            paintGradient(g, box: box, shade: shade, ctx: ctx)
            ctx.restoreGState()
        case .picture(let p):
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip(using: rule)
            paintPicture(p, box: box, scene: scene, ctx: ctx)
            ctx.restoreGState()
        }
    }

    private func paintGradient(_ g: PPTXGradient, box: CGRect, shade: String, ctx: CGContext) {
        let colors = g.stops.map { shaded($0.1, shade).cgColor } as CFArray
        var locations = g.stops.map { $0.0 }
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: &locations)
        else { return }
        let opts: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        if g.linear {
            let t = g.angle * .pi / 180
            let c = CGFloat(cos(t)), s = CGFloat(sin(t))
            if g.scaled {
                ctx.translateBy(x: box.minX, y: box.minY)
                ctx.scaleBy(x: max(box.width, 0.01), y: max(box.height, 0.01))
                let half = (abs(c) + abs(s)) / 2
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0.5 - c * half, y: 0.5 - s * half),
                                       end: CGPoint(x: 0.5 + c * half, y: 0.5 + s * half), options: opts)
            } else {
                let half = (box.width * abs(c) + box.height * abs(s)) / 2
                ctx.drawLinearGradient(gradient, start: CGPoint(x: box.midX - c * half, y: box.midY - s * half),
                                       end: CGPoint(x: box.midX + c * half, y: box.midY + s * half), options: opts)
            }
            return
        }
        let f = g.focus
        let focus = CGRect(x: f.l, y: f.t, width: max(0, 1 - f.l - f.r), height: max(0, 1 - f.t - f.b))
        ctx.translateBy(x: box.minX, y: box.minY)
        ctx.scaleBy(x: max(box.width, 0.01), y: max(box.height, 0.01))
        if g.path == "circle" {
            let center = CGPoint(x: focus.midX, y: focus.midY)
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
            let radius = corners.map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? 1
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                                   options: opts)
        } else {
            // Rectangular gradient: nested rectangles from the outer box (end colour) to the focus (start).
            let steps = 96
            for i in 0...steps {
                let k = CGFloat(i) / CGFloat(steps)
                let r = CGRect(x: focus.minX * k, y: focus.minY * k,
                               width: 1 - k + focus.width * k, height: 1 - k + focus.height * k)
                ctx.setFillColor(color(at: 1 - k, g.stops.map { ($0.0, shaded($0.1, shade)) }).cgColor)
                ctx.fill(r)
            }
        }
    }

    private func color(at t: CGFloat, _ stops: [(CGFloat, PPTXColor)]) -> PPTXColor {
        guard let first = stops.first, let last = stops.last else { return .black }
        if t <= first.0 { return first.1 }
        if t >= last.0 { return last.1 }
        for i in 1..<stops.count where t <= stops[i].0 {
            let (p0, c0) = stops[i - 1], (p1, c1) = stops[i]
            let k = Double((t - p0) / max(0.0001, p1 - p0))
            return PPTXColor(r: c0.r + (c1.r - c0.r) * k, g: c0.g + (c1.g - c0.g) * k, b: c0.b + (c1.b - c0.b) * k,
                             a: c0.a + (c1.a - c0.a) * k)
        }
        return last.1
    }

    private func paintPattern(_ prst: String, fg: PPTXColor, bg: PPTXColor, path: CGPath, rule: CGPathFillRule, ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip(using: rule)
        let bounds = path.boundingBoxOfPath
        if prst.hasPrefix("pct") || prst.hasPrefix("dot") || ["trellis", "sphere", "weave", "plaid", "divot", "shingle",
                                                               "wave", "zigZag", "smGrid", "lgGrid", "dotGrid"].contains(prst) {
            // Dotted patterns read as a blend of the two colours at slide size.
            let k = prst.hasPrefix("pct") ? (Double(prst.dropFirst(3)) ?? 50) / 100 : 0.4
            ctx.setFillColor(PPTXColor(r: bg.r + (fg.r - bg.r) * k, g: bg.g + (fg.g - bg.g) * k,
                                       b: bg.b + (fg.b - bg.b) * k, a: max(fg.a, bg.a)).cgColor)
            ctx.fill(bounds)
            ctx.restoreGState()
            return
        }
        ctx.setFillColor(bg.cgColor)
        ctx.fill(bounds)
        ctx.setStrokeColor(fg.cgColor)
        let dense = prst.hasPrefix("dk") || prst.hasPrefix("wd")
        let light = prst.hasPrefix("lt") || prst.hasPrefix("nar")
        let step: CGFloat = light ? 3 : 5
        ctx.setLineWidth(dense ? 1.6 : 0.8)
        let lower = prst.lowercased()
        var dirs: [(CGFloat, CGFloat)] = []
        if lower.contains("horz") || lower.contains("cross") && !lower.contains("diag") { dirs.append((1, 0)) }
        if lower.contains("vert") || lower.contains("cross") && !lower.contains("diag") { dirs.append((0, 1)) }
        if lower.contains("dndiag") || lower.contains("diagcross") || lower.contains("diagbrick") { dirs.append((1, 1)) }
        if lower.contains("updiag") || lower.contains("diagcross") { dirs.append((1, -1)) }
        if dirs.isEmpty { dirs = [(1, 0)] }
        let span = bounds.width + bounds.height
        for (dx, dy) in dirs {
            var o: CGFloat = -span
            while o < span {
                if dx == 1 && dy == 0 {
                    ctx.move(to: CGPoint(x: bounds.minX, y: bounds.minY + o)); ctx.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY + o))
                } else if dx == 0 {
                    ctx.move(to: CGPoint(x: bounds.minX + o, y: bounds.minY)); ctx.addLine(to: CGPoint(x: bounds.minX + o, y: bounds.maxY))
                } else {
                    ctx.move(to: CGPoint(x: bounds.minX + o, y: bounds.minY))
                    ctx.addLine(to: CGPoint(x: bounds.minX + o + span * dy, y: bounds.minY + span))
                }
                o += step
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func paintPicture(_ p: PPTXPicture, box: CGRect, scene: Scene, ctx: CGContext) {
        // Destination box after the stretch insets, then grown so the cropped part lands on it.
        let dest = CGRect(x: box.minX + box.width * p.fillRect.l, y: box.minY + box.height * p.fillRect.t,
                          width: box.width * (1 - p.fillRect.l - p.fillRect.r),
                          height: box.height * (1 - p.fillRect.t - p.fillRect.b))
        let visW = max(0.0001, 1 - p.crop.l - p.crop.r), visH = max(0.0001, 1 - p.crop.t - p.crop.b)
        let full = CGRect(x: dest.minX - dest.width / visW * p.crop.l, y: dest.minY - dest.height / visH * p.crop.t,
                          width: dest.width / visW, height: dest.height / visH)
        // Device pixels the image covers (capped near 300 dpi for PDFs).
        let t = ctx.ctm
        let deviceScale = max(0.01, (abs(t.a * t.d - t.b * t.c)).squareRoot())
        let need = Int(min(8192, max(full.width, full.height) * (scene.pdf ? 300 / 72 : deviceScale) * 1.05))
        guard var image = deck.pkg.image(p.part, maxPixels: max(64, need)) else { return }
        if p.grayscale, let g = grayscale(image) { image = g }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        if p.alpha < 1 { ctx.setAlpha(p.alpha) }
        if let tile = p.tile {
            let tw = CGFloat(image.width) * 72 / 96 * tile.sx, th = CGFloat(image.height) * 72 / 96 * tile.sy
            if tw > 0.5, th > 0.5, (box.width / tw) * (box.height / th) < 40_000 {
                var y = box.minY + tile.ty.truncatingRemainder(dividingBy: th) - (tile.ty > 0 ? th : 0)
                while y < box.maxY {
                    var x = box.minX + tile.tx.truncatingRemainder(dividingBy: tw) - (tile.tx > 0 ? tw : 0)
                    while x < box.maxX {
                        drawImage(image, in: CGRect(x: x, y: y, width: tw, height: th), ctx: ctx)
                        x += tw
                    }
                    y += th
                }
            }
        } else {
            drawImage(image, in: full, ctx: ctx)
        }
        ctx.restoreGState()
    }

    private func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    private func grayscale(_ image: CGImage) -> CGImage? {
        guard let g = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        g.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return g.makeImage()
    }

    // MARK: Outlines

    private func stroke(_ p: PPTXPath, line: PPTXLine, scene: Scene, ctx: CGContext) {
        guard let color = line.color else { return }
        let w = max(line.width, 0.5)
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(w)
        ctx.setLineCap(line.cap)
        ctx.setLineJoin(line.join)
        let pattern: [CGFloat]? = line.custom ?? {
            switch line.dash {
            case "dot": return [1, 3]
            case "dash": return [4, 3]
            case "lgDash": return [8, 3]
            case "dashDot": return [4, 3, 1, 3]
            case "lgDashDot": return [8, 3, 1, 3]
            case "lgDashDotDot": return [8, 3, 1, 3, 1, 3]
            case "sysDash": return [3, 1]
            case "sysDot": return [1, 1]
            case "sysDashDot": return [3, 1, 1, 1]
            case "sysDashDotDot": return [3, 1, 1, 1, 1, 1]
            default: return nil
            }
        }()
        if let pattern { ctx.setLineDash(phase: 0, lengths: pattern.map { $0 * w }) }
        ctx.addPath(p.path)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        if let head = line.head, head.0 != "none", let (tip, toward) = p.start { arrow(head, tip: tip, from: toward, width: w, color: color, ctx: ctx) }
        if let tail = line.tail, tail.0 != "none", let (tip, toward) = p.end { arrow(tail, tip: tip, from: toward, width: w, color: color, ctx: ctx) }
        ctx.restoreGState()
    }

    private func arrow(_ spec: (String, String, String), tip: CGPoint, from: CGPoint, width: CGFloat, color: PPTXColor, ctx: CGContext) {
        func factor(_ s: String) -> CGFloat { s == "sm" ? 2 : s == "lg" ? 5 : 3 }
        let lw = max(width, 1)
        let len = factor(spec.2) * lw, half = factor(spec.1) * lw / 2
        let dx = tip.x - from.x, dy = tip.y - from.y
        let d = max(0.0001, hypot(dx, dy))
        let ux = dx / d, uy = dy / d
        let nx = -uy, ny = ux
        let base = CGPoint(x: tip.x - ux * len, y: tip.y - uy * len)
        let left = CGPoint(x: base.x + nx * half, y: base.y + ny * half)
        let right = CGPoint(x: base.x - nx * half, y: base.y - ny * half)
        ctx.setFillColor(color.cgColor)
        switch spec.0 {
        case "arrow":
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.move(to: left); ctx.addLine(to: tip); ctx.addLine(to: right); ctx.strokePath()
        case "oval":
            ctx.fillEllipse(in: CGRect(x: tip.x - half, y: tip.y - half, width: 2 * half, height: 2 * half))
        case "diamond":
            let mid = CGPoint(x: tip.x - ux * len / 2, y: tip.y - uy * len / 2)
            ctx.move(to: CGPoint(x: tip.x + ux * len / 2, y: tip.y + uy * len / 2))
            ctx.addLine(to: CGPoint(x: mid.x + nx * half, y: mid.y + ny * half))
            ctx.addLine(to: base); ctx.addLine(to: CGPoint(x: mid.x - nx * half, y: mid.y - ny * half))
            ctx.closePath(); ctx.fillPath()
        case "stealth":
            let notch = CGPoint(x: tip.x - ux * len * 0.6, y: tip.y - uy * len * 0.6)
            ctx.move(to: tip); ctx.addLine(to: left); ctx.addLine(to: notch); ctx.addLine(to: right); ctx.closePath(); ctx.fillPath()
        default:
            ctx.move(to: tip); ctx.addLine(to: left); ctx.addLine(to: right); ctx.closePath(); ctx.fillPath()
        }
    }

    // MARK: Text

    private func listStyles(_ chain: [PPTXNode], type: String?, scene: Scene) -> [PPTXNode?] {
        var out: [PPTXNode?] = chain.map { $0.child("p:txBody")?.child("a:lstStyle") }
        out.append(PPTXDeck.masterTextStyle(type, master: scene.chain.master))
        out.append(deck.defaultTextStyle)
        return out
    }

    private func drawText(_ tx: PPTXNode, chain: [PPTXNode], style: PPTXNode?, box: CGRect, scene: Scene, ctx: CGContext) {
        var props = PPTXBodyProps()
        for n in chain.reversed() { props.apply(n.child("p:txBody")?.child("a:bodyPr")) }
        let type = PPTXDeck.placeholder(of: chain[0])?.type
        var styleRun: PPTXRunStyle?
        if let fontRef = style?.child("a:fontRef") {
            var r = PPTXRunStyle()
            r.color = scene.colors.colorChild(fontRef)
            if let idx = fontRef["idx"], idx != "none" { r.latin = idx == "major" ? "+mj-lt" : "+mn-lt" }
            styleRun = r
        }
        let source = PPTXTextSource(body: tx, listStyles: listStyles(chain, type: type, scene: scene), styleRun: styleRun,
                                    props: props, colors: scene.colors, theme: scene.chain.theme, slideNumber: scene.number)
        drawTextBody(source, box: box, pixelScale: scene.pixelScale, ctx: ctx)
    }

    /// Lays out and draws a text body inside `box` (local, y-down), honouring insets, anchoring,
    /// vertical text, rotation and shrink-to-fit.
    func drawTextBody(_ source: PPTXTextSource, box: CGRect, pixelScale: CGFloat, ctx: CGContext) {
        let layout = PPTXTextLayout(source, fonts: fonts)
        if layout.isEmpty { return }
        let p = source.props
        var area = box
        let vertical = p.vert == "vert" || p.vert == "eaVert" || p.vert == "vert270" || p.vert == "mongolianVert"
        ctx.saveGState()
        if p.rotation != 0 || vertical {
            let angle = p.rotation + (p.vert == "vert270" ? -90 : vertical ? 90 : 0)
            ctx.translateBy(x: box.midX, y: box.midY)
            ctx.rotate(by: CGFloat(angle * .pi / 180))
            if vertical { area = CGRect(x: -box.height / 2, y: -box.width / 2, width: box.height, height: box.width) }
            else { area = CGRect(x: -box.width / 2, y: -box.height / 2, width: box.width, height: box.height) }
        }
        let inner = CGRect(x: area.minX + p.insets.l, y: area.minY + p.insets.t,
                           width: max(1, area.width - p.insets.l - p.insets.r), height: area.height - p.insets.t - p.insets.b)
        var scale = 1.0, reduction = 0.0
        var shrink = false
        if case .normal(let fs, let lr) = p.autofit { scale = fs; reduction = lr; shrink = true }
        var height = layout.layout(width: inner.width, scale: scale, lineReduction: reduction)
        if shrink {
            // The saved scale was computed with the original fonts; shrink further if ours still overflow.
            var tries = 0
            while height > inner.height * 1.02, scale > 0.3, tries < 12 {
                scale *= 0.92
                reduction = min(0.2, reduction + 0.02)
                height = layout.layout(width: inner.width, scale: scale, lineReduction: reduction)
                tries += 1
            }
        }
        var y = inner.minY
        switch p.anchor {
        case "ctr": y = inner.minY + (inner.height - height) / 2
        case "b": y = inner.maxY - height
        default: break
        }
        layout.draw(in: ctx, origin: CGPoint(x: inner.minX, y: y), pixelScale: pixelScale)
        ctx.restoreGState()
    }

    // MARK: Tables

    private func drawTable(_ tbl: PPTXNode, size: CGSize, owner: Owner, scene: Scene, ctx: CGContext) {
        let cols = (tbl.child("a:tblGrid")?.all("a:gridCol") ?? []).map { CGFloat($0.double("w") ?? 0) / 12700 }
        let rows = tbl.all("a:tr")
        guard !cols.isEmpty, !rows.isEmpty else { return }
        let pr = tbl.child("a:tblPr")
        let flags = (first: pr?.bool("firstRow") ?? false, last: pr?.bool("lastRow") ?? false,
                     firstCol: pr?.bool("firstCol") ?? false, lastCol: pr?.bool("lastCol") ?? false,
                     bandRow: pr?.bool("bandRow") ?? false, bandCol: pr?.bool("bandCol") ?? false)
        let style = PPTXTableStyles.style(id: pr?.child("a:tableStyleId")?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                          deck: deck)
        let tableFill = fill(in: pr, colors: scene.colors, owner: owner.part)

        // Grow rows to fit their text, like PowerPoint does when it lays the table out.
        var heights = rows.map { CGFloat($0.double("h") ?? 0) / 12700 }
        var xs: [CGFloat] = [0]
        for w in cols { xs.append(xs.last! + w) }
        func cellParts(_ r: Int, _ c: Int) -> [PPTXNode] {
            guard let style else { return [] }
            var parts: [String] = ["a:wholeTbl"]
            let bodyRow = r - (flags.first ? 1 : 0)
            if flags.bandCol { parts.append((c - (flags.firstCol ? 1 : 0)) % 2 == 0 ? "a:band1V" : "a:band2V") }
            if flags.bandRow, !(flags.first && r == 0), !(flags.last && r == rows.count - 1) {
                parts.append(bodyRow % 2 == 0 ? "a:band1H" : "a:band2H")
            }
            if flags.lastCol && c == cols.count - 1 { parts.append("a:lastCol") }
            if flags.firstCol && c == 0 { parts.append("a:firstCol") }
            if flags.last && r == rows.count - 1 { parts.append("a:lastRow") }
            if flags.first && r == 0 { parts.append("a:firstRow") }
            return parts.compactMap { style.child($0) }
        }
        func textStyle(_ parts: [PPTXNode]) -> PPTXRunStyle {
            var run = PPTXRunStyle()
            for part in parts.reversed() {
                guard let t = part.child("a:tcTxStyle") else { continue }
                if run.bold == nil, let b = t["b"] { run.bold = b == "on" }
                if run.italic == nil, let i = t["i"] { run.italic = i == "on" }
                if run.color == nil, let c = scene.colors.colorChild(t) ?? scene.colors.colorChild(t.child("a:fontRef")) { run.color = c }
                if run.latin == nil, let f = t.child("a:fontRef")?["idx"] { run.latin = f == "major" ? "+mj-lt" : "+mn-lt" }
                if run.latin == nil, let face = t.child("a:font")?.child("a:latin")?["typeface"] { run.latin = face }
            }
            return run
        }
        func source(_ tc: PPTXNode, _ r: Int, _ c: Int) -> PPTXTextSource? {
            guard let body = tc.child("a:txBody") else { return nil }
            let tcPr = tc.child("a:tcPr")
            var props = PPTXBodyProps()
            props.insets = (CGFloat(tcPr?.double("marL") ?? 91440) / 12700, CGFloat(tcPr?.double("marT") ?? 45720) / 12700,
                            CGFloat(tcPr?.double("marR") ?? 91440) / 12700, CGFloat(tcPr?.double("marB") ?? 45720) / 12700)
            props.anchor = tcPr?["anchor"] ?? "t"
            if let v = tcPr?["vert"] { props.vert = v }
            return PPTXTextSource(body: body, listStyles: [body.child("a:lstStyle"),
                                                           PPTXDeck.masterTextStyle(nil, master: scene.chain.master),
                                                           deck.defaultTextStyle],
                                  styleRun: textStyle(cellParts(r, c)), props: props, colors: scene.colors,
                                  theme: scene.chain.theme, slideNumber: scene.number)
        }
        for (r, row) in rows.enumerated() {
            var c = 0
            for tc in row.all("a:tc") {
                // Every grid column has its own a:tc; merged-over ones are marked hMerge / vMerge.
                defer { c += 1 }
                if tc.bool("hMerge") == true || tc.bool("vMerge") == true || (tc.int("rowSpan") ?? 1) > 1 { continue }
                guard c < cols.count, let src = source(tc, r, c) else { continue }
                let span = min(cols.count - c, max(1, tc.int("gridSpan") ?? 1))
                let width = xs[c + span] - xs[c] - src.props.insets.l - src.props.insets.r
                let layout = PPTXTextLayout(src, fonts: fonts)
                if layout.isEmpty { continue }
                let need = layout.layout(width: max(1, width)) + src.props.insets.t + src.props.insets.b
                heights[r] = max(heights[r], need)
            }
        }
        var ys: [CGFloat] = [0]
        for h in heights { ys.append(ys.last! + h) }

        if let tf = tableFill {
            paint(tf, path: CGPath(rect: CGRect(x: 0, y: 0, width: xs.last!, height: ys.last!), transform: nil),
                  evenOdd: false, box: CGRect(x: 0, y: 0, width: xs.last!, height: ys.last!), shade: "norm", scene: scene, ctx: ctx)
        }

        struct Cell { let tc: PPTXNode; let r: Int; let c: Int; let rect: CGRect; let rowSpan: Int; let colSpan: Int }
        var cells: [Cell] = []
        for (r, row) in rows.enumerated() {
            var c = 0
            for tc in row.all("a:tc") {
                let span = max(1, tc.int("gridSpan") ?? 1)
                defer { c += 1 }
                if tc.bool("hMerge") == true || tc.bool("vMerge") == true { continue }
                guard c < cols.count else { continue }
                let cs = min(cols.count - c, span), rs = min(rows.count - r, max(1, tc.int("rowSpan") ?? 1))
                cells.append(Cell(tc: tc, r: r, c: c, rect: CGRect(x: xs[c], y: ys[r], width: xs[c + cs] - xs[c], height: ys[r + rs] - ys[r]),
                                  rowSpan: rs, colSpan: cs))
            }
        }
        // Fills.
        for cell in cells {
            let tcPr = cell.tc.child("a:tcPr")
            var f = fill(in: tcPr, colors: scene.colors, owner: owner.part)
            if f == nil {
                for part in cellParts(cell.r, cell.c).reversed() {
                    guard let tcStyle = part.child("a:tcStyle") else { continue }
                    if let ff = tcStyle.child("a:fill"), let inner = ff.first(of: Self.fillNames) {
                        f = parseFill(inner, colors: scene.colors, owner: owner.part); break
                    }
                    if let ref = tcStyle.child("a:fillRef"), let idx = ref.int("idx") {
                        f = styleFill(idx, phClr: scene.colors.colorChild(ref), scene: scene, background: false); break
                    }
                }
            }
            if let f { paint(f, path: CGPath(rect: cell.rect, transform: nil), evenOdd: false, box: cell.rect, shade: "norm", scene: scene, ctx: ctx) }
        }
        // Text.
        for cell in cells {
            guard let src = source(cell.tc, cell.r, cell.c) else { continue }
            drawTextBody(src, box: cell.rect, pixelScale: scene.pixelScale, ctx: ctx)
        }
        // Borders: explicit cell borders win over the table style's.
        for cell in cells {
            let tcPr = cell.tc.child("a:tcPr")
            let lastRow = cell.r + cell.rowSpan - 1 == rows.count - 1, lastCol = cell.c + cell.colSpan - 1 == cols.count - 1
            let sides: [(String, String, CGPoint, CGPoint)] = [
                ("a:lnT", cell.r == 0 ? "a:top" : "a:insideH", CGPoint(x: cell.rect.minX, y: cell.rect.minY), CGPoint(x: cell.rect.maxX, y: cell.rect.minY)),
                ("a:lnB", lastRow ? "a:bottom" : "a:insideH", CGPoint(x: cell.rect.minX, y: cell.rect.maxY), CGPoint(x: cell.rect.maxX, y: cell.rect.maxY)),
                ("a:lnL", cell.c == 0 ? "a:left" : "a:insideV", CGPoint(x: cell.rect.minX, y: cell.rect.minY), CGPoint(x: cell.rect.minX, y: cell.rect.maxY)),
                ("a:lnR", lastCol ? "a:right" : "a:insideV", CGPoint(x: cell.rect.maxX, y: cell.rect.minY), CGPoint(x: cell.rect.maxX, y: cell.rect.maxY)),
            ]
            for (own, styleSide, a, b) in sides {
                var ln: PPTXLine?
                var explicit = false
                if let node = tcPr?.child(own) {
                    explicit = true
                    ln = line(node, style: nil, scene: scene)
                }
                if !explicit {
                    let parts = cellParts(cell.r, cell.c)
                    for part in parts.reversed() {
                        let name = part.name
                        // Row parts own their top/bottom edges, column parts their left/right edges.
                        var side = styleSide
                        if ["a:firstRow", "a:lastRow", "a:band1H", "a:band2H"].contains(name) {
                            if own == "a:lnT" { side = "a:top" }
                            if own == "a:lnB" { side = "a:bottom" }
                        }
                        if ["a:firstCol", "a:lastCol", "a:band1V", "a:band2V"].contains(name) {
                            if own == "a:lnL" { side = "a:left" }
                            if own == "a:lnR" { side = "a:right" }
                        }
                        guard let bdr = part.child("a:tcStyle")?.child("a:tcBdr")?.child(side) else { continue }
                        if let l = bdr.child("a:ln") { ln = line(l, style: nil, scene: scene) }
                        else if let ref = bdr.child("a:lnRef"), let idx = ref.int("idx"), idx > 0,
                                idx <= scene.chain.theme.lineStyles.count {
                            ln = line(scene.chain.theme.lineStyles[idx - 1], style: nil,
                                      scene: Scene(chain: scene.chain, colors: scene.colors.with(phClr: scene.colors.colorChild(ref)),
                                                   number: scene.number, pixelScale: scene.pixelScale, pdf: scene.pdf, slidePart: scene.slidePart))
                        }
                        break
                    }
                }
                guard let l = ln, let color = l.color else { continue }
                ctx.saveGState()
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(max(0.5, l.width))
                ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
                ctx.restoreGState()
            }
        }
    }

    // MARK: Links

    private func linkAnnotation(_ node: PPTXNode, rect: CGRect, owner: Owner, scene: Scene, ctx: CGContext) {
        guard scene.pdf, let nv = node.children.first(where: { $0.name.hasPrefix("p:nv") }),
              let rid = nv.child("p:cNvPr")?.child("a:hlinkClick")?["r:id"],
              let rel = deck.pkg.rels(owner.part)[rid], rel.external,
              let url = URL(string: rel.target), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        // PDF contexts start with an identity CTM, so the current CTM maps straight to page space.
        ctx.setURL(url as CFURL, for: rect.applying(ctx.ctm))
    }
}

/// Table styles: the deck's own (`ppt/tableStyles.xml`) or the common built-in ones PowerPoint doesn't store.
enum PPTXTableStyles {
    private static let mediumStyle2: [String: String] = [
        "{073A0DAA-6AF3-43AB-8588-CEC1D06C72B9}": "dk1",
        "{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}": "accent1", "{21E4AEA4-8DFA-4A89-87EB-49C32662AFE8}": "accent2",
        "{F5AB1C69-6EDB-4FF4-983F-18BD219EF322}": "accent3", "{00A15C55-8517-42AA-B614-E9B94910E393}": "accent4",
        "{7DF18680-E054-41AD-8BC1-D1AEF772440D}": "accent5", "{93296810-A885-4BE3-A3E7-6D5BEEA58F35}": "accent6",
    ]

    private static func mediumStyle2XML(_ accent: String) -> String {
        let ns = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\""
        let lt1 = "<a:ln w=\"12700\"><a:solidFill><a:schemeClr val=\"lt1\"/></a:solidFill></a:ln>"
        let thick = "<a:ln w=\"38100\"><a:solidFill><a:schemeClr val=\"lt1\"/></a:solidFill></a:ln>"
        let head = "<a:tcTxStyle b=\"on\"><a:fontRef idx=\"minor\"><a:prstClr val=\"black\"/></a:fontRef><a:schemeClr val=\"lt1\"/></a:tcTxStyle>"
        let solid = "<a:fill><a:solidFill><a:schemeClr val=\"\(accent)\"/></a:solidFill></a:fill>"
        return """
        <a:tblStyle \(ns) styleId="builtin" styleName="Medium Style 2">
        <a:wholeTbl><a:tcTxStyle><a:fontRef idx="minor"><a:prstClr val="black"/></a:fontRef><a:schemeClr val="dk1"/></a:tcTxStyle>
        <a:tcStyle><a:tcBdr><a:left>\(lt1)</a:left><a:right>\(lt1)</a:right><a:top>\(lt1)</a:top><a:bottom>\(lt1)</a:bottom>
        <a:insideH>\(lt1)</a:insideH><a:insideV>\(lt1)</a:insideV></a:tcBdr>
        <a:fill><a:solidFill><a:schemeClr val="\(accent)"><a:tint val="20000"/></a:schemeClr></a:solidFill></a:fill></a:tcStyle></a:wholeTbl>
        <a:band1H><a:tcStyle><a:tcBdr/><a:fill><a:solidFill><a:schemeClr val="\(accent)"><a:tint val="40000"/></a:schemeClr></a:solidFill></a:fill></a:tcStyle></a:band1H>
        <a:band2H><a:tcStyle><a:tcBdr/></a:tcStyle></a:band2H>
        <a:band1V><a:tcStyle><a:tcBdr/><a:fill><a:solidFill><a:schemeClr val="\(accent)"><a:tint val="40000"/></a:schemeClr></a:solidFill></a:fill></a:tcStyle></a:band1V>
        <a:band2V><a:tcStyle><a:tcBdr/></a:tcStyle></a:band2V>
        <a:lastCol>\(head)<a:tcStyle><a:tcBdr/>\(solid)</a:tcStyle></a:lastCol>
        <a:firstCol>\(head)<a:tcStyle><a:tcBdr/>\(solid)</a:tcStyle></a:firstCol>
        <a:lastRow>\(head)<a:tcStyle><a:tcBdr><a:top>\(thick)</a:top></a:tcBdr>\(solid)</a:tcStyle></a:lastRow>
        <a:firstRow>\(head)<a:tcStyle><a:tcBdr><a:bottom>\(thick)</a:bottom></a:tcBdr>\(solid)</a:tcStyle></a:firstRow>
        </a:tblStyle>
        """
    }

    private static let gridXML = """
    <a:tblStyle xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" styleId="grid" styleName="Table Grid">
    <a:wholeTbl><a:tcTxStyle><a:schemeClr val="tx1"/></a:tcTxStyle><a:tcStyle><a:tcBdr>
    <a:left><a:ln w="12700"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill></a:ln></a:left>
    <a:right><a:ln w="12700"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill></a:ln></a:right>
    <a:top><a:ln w="12700"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill></a:ln></a:top>
    <a:bottom><a:ln w="12700"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill></a:ln></a:bottom>
    <a:insideH><a:ln w="12700"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill></a:ln></a:insideH>
    <a:insideV><a:ln w="12700"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill></a:ln></a:insideV>
    </a:tcBdr></a:tcStyle></a:wholeTbl></a:tblStyle>
    """

    private static let cacheLock = NSLock()
    private static var cache: [String: PPTXNode] = [:]

    static func style(id: String?, deck: PPTXDeck) -> PPTXNode? {
        guard let id, !id.isEmpty else { return nil }
        if let own = deck.tableStyles?.all("a:tblStyle").first(where: { $0["styleId"]?.uppercased() == id.uppercased() }) {
            return own
        }
        let key = id.uppercased()
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = cache[key] { return c }
        let xml: String?
        if key == "{2D5ABB26-0587-4C30-8999-92F81FD0307C}" { xml = nil }
        else if key == "{5940675A-B579-460E-94D1-54222C63F5DA}" { xml = gridXML }
        else { xml = mediumStyle2XML(mediumStyle2[key] ?? "accent1") }
        guard let xml, let node = PPTXXMLParser.parse(xml) else { return nil }
        cache[key] = node
        return node
    }
}
