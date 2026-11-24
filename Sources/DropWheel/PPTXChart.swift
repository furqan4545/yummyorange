import Foundation
import CoreGraphics
import CoreText

/// Draws a chart part (`c:chartSpace`) from the values cached inside it: column/bar, line, area,
/// pie/doughnut and scatter charts, with title, legend, value axis, gridlines and data labels.
/// It's a faithful-enough picture of the chart, not a full charting engine.
struct PPTXChart {
    let deck: PPTXDeck
    let part: String
    let colors: PPTXColors
    let fonts: PPTXFontBook

    private struct Series {
        var name: String
        var values: [Double?]
        var xValues: [Double?]
        var fill: PPTXColor
        var line: PPTXColor?
        var pointFills: [Int: PPTXColor]
        var smooth: Bool
        var marker: Bool
    }

    private struct Plot {
        var kind: String          // bar, line, area, pie, doughnut, scatter
        var horizontal = false
        var grouping = "clustered"
        var series: [Series] = []
        var categories: [String] = []
        var gap: Double = 150
        var overlap: Double = 0
        var hole: Double = 50
        var firstAngle: Double = 0
        var varyColors = false
        var showValues = false
        var showPercent = false
    }

    // MARK: Data

    private static func cache(_ ref: PPTXNode?) -> PPTXNode? {
        guard let ref else { return nil }
        for name in ["c:numRef", "c:strRef", "c:multiLvlStrRef"] {
            if let r = ref.child(name) {
                return r.child("c:numCache") ?? r.child("c:strCache") ?? r.child("c:multiLvlStrCache")?.child("c:lvl")
            }
        }
        return ref.child("c:numLit") ?? ref.child("c:strLit")
    }

    private static func strings(_ ref: PPTXNode?) -> [String] {
        guard let c = cache(ref) else { return [] }
        let count = c.child("c:ptCount")?.int("val") ?? 0
        var out = [String](repeating: "", count: max(0, min(count, 10000)))
        for pt in c.all("c:pt") {
            guard let i = pt.int("idx"), i >= 0, i < 10000 else { continue }
            if i >= out.count { out += [String](repeating: "", count: i - out.count + 1) }
            out[i] = pt.child("c:v")?.text ?? ""
        }
        return out
    }

    private static func numbers(_ ref: PPTXNode?) -> [Double?] {
        strings(ref).map { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func seriesColor(_ i: Int) -> PPTXColor {
        let accents = ["accent1", "accent2", "accent3", "accent4", "accent5", "accent6"]
        var c = colors.theme.colors[accents[i % 6]] ?? .black
        if i >= 6 { c.apply("lumMod", i >= 12 ? 0.8 : 0.6) }
        return c
    }

    private func fillColor(_ spPr: PPTXNode?) -> PPTXColor? {
        guard let spPr else { return nil }
        if let s = spPr.child("a:solidFill") { return colors.colorChild(s) }
        if let g = spPr.child("a:gradFill") { return colors.colorChild(g.child("a:gsLst")?.child("a:gs")) }
        return nil
    }

    private func parsePlots(_ area: PPTXNode) -> [Plot] {
        var plots: [Plot] = []
        var seriesIndex = 0
        for node in area.children {
            let name = node.localName
            var plot: Plot
            switch name {
            case "barChart", "bar3DChart": plot = Plot(kind: "bar")
            case "lineChart", "line3DChart", "stockChart", "radarChart": plot = Plot(kind: "line")
            case "areaChart", "area3DChart": plot = Plot(kind: "area")
            case "pieChart", "pie3DChart", "ofPieChart": plot = Plot(kind: "pie")
            case "doughnutChart": plot = Plot(kind: "doughnut")
            case "scatterChart", "bubbleChart": plot = Plot(kind: "scatter")
            default: continue
            }
            plot.horizontal = node.child("c:barDir")?["val"] == "bar"
            plot.grouping = node.child("c:grouping")?["val"] ?? (plot.kind == "bar" ? "clustered" : "standard")
            plot.gap = node.child("c:gapWidth")?.double("val") ?? 150
            plot.overlap = node.child("c:overlap")?.double("val") ?? (plot.grouping.contains("tacked") ? 100 : 0)
            plot.hole = node.child("c:holeSize")?.double("val") ?? 50
            plot.firstAngle = node.child("c:firstSliceAng")?.double("val") ?? 0
            plot.varyColors = node.child("c:varyColors")?.bool("val") ?? false
            if let labels = node.child("c:dLbls") {
                plot.showValues = labels.child("c:showVal")?.bool("val") ?? false
                plot.showPercent = labels.child("c:showPercent")?.bool("val") ?? false
            }
            for ser in node.all("c:ser") {
                let fill = fillColor(ser.child("c:spPr")) ?? seriesColor(seriesIndex)
                var line = ser.child("c:spPr")?.child("a:ln").flatMap { ln -> PPTXColor? in
                    ln.child("a:noFill") != nil ? nil : colors.colorChild(ln.child("a:solidFill"))
                }
                if plot.kind == "line" || plot.kind == "scatter" { line = line ?? fill }
                var pointFills: [Int: PPTXColor] = [:]
                for dPt in ser.all("c:dPt") {
                    if let i = dPt.child("c:idx")?.int("val"), let c = fillColor(dPt.child("c:spPr")) { pointFills[i] = c }
                }
                let name = Self.strings(ser.child("c:tx")).first ?? ser.child("c:tx")?.child("c:v")?.text ?? "Series \(seriesIndex + 1)"
                let values = Self.numbers(ser.child("c:val") ?? ser.child("c:yVal"))
                let xs = Self.numbers(ser.child("c:xVal"))
                if plot.categories.isEmpty { plot.categories = Self.strings(ser.child("c:cat") ?? ser.child("c:xVal")) }
                if let lbl = ser.child("c:dLbls") {
                    plot.showValues = plot.showValues || (lbl.child("c:showVal")?.bool("val") ?? false)
                    plot.showPercent = plot.showPercent || (lbl.child("c:showPercent")?.bool("val") ?? false)
                }
                plot.series.append(Series(name: name, values: values, xValues: xs, fill: fill, line: line, pointFills: pointFills,
                                          smooth: ser.child("c:smooth")?.bool("val") ?? false,
                                          marker: ser.child("c:marker")?.child("c:symbol")?["val"] != "none"))
                seriesIndex += 1
            }
            if !plot.series.isEmpty { plots.append(plot) }
        }
        return plots
    }

    // MARK: Text

    private func textSize(_ base: CGFloat, _ node: PPTXNode?) -> CGFloat {
        let sz = node?.child("c:txPr")?.descendants("a:defRPr").first?.double("sz")
            ?? node?.descendants("a:rPr").first?.double("sz")
        return sz.map { CGFloat($0) / 100 } ?? base
    }

    private func line(_ text: String, size: CGFloat, bold: Bool = false, color: PPTXColor = PPTXColor(hex: "595959")!) -> CTLine {
        let pick = fonts.pick(face: colors.theme.minorLatin, size: max(4, size), bold: bold, italic: false, pitch: nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): pick.font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    private func width(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }

    /// Draws a line of text with its centre-left, centre or centre-right at `p` (y-down context).
    private func draw(_ l: CTLine, at p: CGPoint, align: Int, ctx: CGContext) {
        var asc: CGFloat = 0, desc: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(l, &asc, &desc, nil))
        let x = align == 0 ? p.x : align == 1 ? p.x - w / 2 : p.x - w
        ctx.saveGState()
        ctx.translateBy(x: x, y: p.y + (asc - desc) / 2)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        CTLineDraw(l, ctx)
        ctx.restoreGState()
    }

    private static func label(_ v: Double, percent: Bool = false) -> String {
        if percent { return String(format: "%.0f%%", v * 100) }
        if abs(v) >= 1e6 || (abs(v) < 0.001 && v != 0) { return String(format: "%.2g", v) }
        if v == v.rounded() { return String(Int(v)) }
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private static func niceScale(_ lo: Double, _ hi: Double) -> (Double, Double, Double) {
        var lo = lo, hi = hi
        if lo == hi { hi = lo + 1 }
        if lo > 0 && lo < hi * 0.8 { lo = 0 }
        if hi < 0 && hi > lo * 0.8 { hi = 0 }
        let raw = (hi - lo) / 6
        let mag = pow(10, floor(log10(raw)))
        let step = [1.0, 2, 2.5, 5, 10].map { $0 * mag }.first { $0 >= raw } ?? raw
        return (floor(lo / step) * step, ceil(hi / step) * step, step)
    }

    // MARK: Drawing

    func draw(size: CGSize, ctx: CGContext) {
        guard size.width > 4, size.height > 4, let root = deck.pkg.xml(part), let chart = root.child("c:chart"),
              let area = chart.child("c:plotArea") else { return }
        let plots = parsePlots(area)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        var box = CGRect(origin: .zero, size: size)
        ctx.clip(to: box)
        // Chart area background (white unless the chart says otherwise).
        let spaceFill = root.child("c:spPr").flatMap { $0.child("a:noFill") != nil ? nil : fillColor($0) }
        if root.child("c:spPr")?.child("a:noFill") == nil {
            ctx.setFillColor((spaceFill ?? .white).cgColor)
            ctx.fill(box)
        }
        let base = textSize(min(12, max(7, size.height / 28)), root)
        box = box.insetBy(dx: 8, dy: 8)

        // Title.
        let deleted = chart.child("c:autoTitleDeleted")?.bool("val") ?? false
        var titleText: String?
        if let t = chart.child("c:title") {
            let rich = t.descendants("a:p").map { $0.descendants("a:t").map(\.text).joined() }.joined(separator: " ")
            titleText = rich.isEmpty ? Self.strings(t.child("c:tx")).first : rich
            if titleText == nil || titleText!.isEmpty, plots.count == 1, plots[0].series.count == 1 { titleText = plots[0].series[0].name }
        } else if !deleted, plots.count == 1, plots[0].series.count == 1, ["pie", "doughnut"].contains(plots[0].kind) {
            titleText = plots[0].series[0].name
        }
        if let title = titleText, !title.isEmpty {
            let size = textSize(base * 1.2, chart.child("c:title"))
            let l = line(title, size: size, color: PPTXColor(hex: "404040")!)
            draw(l, at: CGPoint(x: box.midX, y: box.minY + size * 0.7), align: 1, ctx: ctx)
            box.origin.y += size * 1.6; box.size.height -= size * 1.6
        }
        guard !plots.isEmpty else { return }

        // Legend.
        if let legend = chart.child("c:legend") {
            let pos = legend.child("c:legendPos")?["val"] ?? "r"
            let pie = ["pie", "doughnut"].contains(plots[0].kind)
            let entries: [(String, PPTXColor)] = pie
                ? plots[0].categories.enumerated().map { ($1, plots[0].series[0].pointFills[$0] ?? seriesColor($0)) }
                : plots.flatMap { $0.series.map { ($0.name, $0.fill) } }
            let ls = textSize(base * 0.9, legend)
            let lines = entries.map { (line($0.0, size: ls), $0.1) }
            let sw = ls * 0.7
            if pos == "b" || pos == "t" {
                let total = lines.reduce(0) { $0 + width($1.0) + sw + ls * 1.2 }
                var x = box.midX - total / 2
                let y = pos == "b" ? box.maxY - ls * 0.6 : box.minY + ls * 0.6
                for (l, c) in lines {
                    ctx.setFillColor(c.cgColor)
                    ctx.fill(CGRect(x: x, y: y - sw / 2, width: sw, height: sw))
                    draw(l, at: CGPoint(x: x + sw + 3, y: y), align: 0, ctx: ctx)
                    x += width(l) + sw + ls * 1.2
                }
                if pos == "b" { box.size.height -= ls * 1.8 } else { box.origin.y += ls * 1.8; box.size.height -= ls * 1.8 }
            } else {
                let maxW = min(box.width * 0.35, (lines.map { width($0.0) }.max() ?? 0) + sw + 6)
                let x = pos == "l" ? box.minX : box.maxX - maxW
                var y = box.midY - CGFloat(lines.count) * ls * 1.4 / 2 + ls * 0.7
                for (l, c) in lines {
                    ctx.setFillColor(c.cgColor)
                    ctx.fill(CGRect(x: x, y: y - sw / 2, width: sw, height: sw))
                    draw(l, at: CGPoint(x: x + sw + 4, y: y), align: 0, ctx: ctx)
                    y += ls * 1.4
                }
                if pos == "l" { box.origin.x += maxW + 8 }
                box.size.width -= maxW + 8
            }
        }

        for plot in plots {
            switch plot.kind {
            case "pie", "doughnut": drawPie(plot, in: box, base: base, ctx: ctx)
            default: drawAxes(plot, in: box, area: area, base: base, ctx: ctx)
            }
        }
    }

    private func drawPie(_ plot: Plot, in box: CGRect, base: CGFloat, ctx: CGContext) {
        guard let s = plot.series.first else { return }
        let values = s.values.map { max(0, $0 ?? 0) }
        let total = values.reduce(0, +)
        guard total > 0 else { return }
        let r = min(box.width, box.height) / 2 * 0.92
        let c = CGPoint(x: box.midX, y: box.midY)
        var angle = (plot.firstAngle - 90) * .pi / 180
        let hole = plot.kind == "doughnut" ? r * CGFloat(plot.hole / 100) : 0
        for (i, v) in values.enumerated() where v > 0 {
            let sweep = v / total * 2 * .pi
            let path = CGMutablePath()
            if hole > 0 {
                path.addArc(center: c, radius: r, startAngle: CGFloat(angle), endAngle: CGFloat(angle + sweep), clockwise: false)
                path.addArc(center: c, radius: hole, startAngle: CGFloat(angle + sweep), endAngle: CGFloat(angle), clockwise: true)
            } else {
                path.move(to: c)
                path.addArc(center: c, radius: r, startAngle: CGFloat(angle), endAngle: CGFloat(angle + sweep), clockwise: false)
            }
            path.closeSubpath()
            let fill = s.pointFills[i] ?? (plot.varyColors || plot.series.count == 1 ? seriesColor(i) : s.fill)
            ctx.setFillColor(fill.cgColor)
            ctx.addPath(path); ctx.fillPath()
            ctx.setStrokeColor(CGColor.white); ctx.setLineWidth(1)
            ctx.addPath(path); ctx.strokePath()
            if plot.showValues || plot.showPercent {
                let mid = angle + sweep / 2
                let rr = hole > 0 ? (r + hole) / 2 : r * 0.65
                let text = plot.showPercent ? Self.label(v / total, percent: true) : Self.label(v)
                draw(line(text, size: base * 0.9, color: .white), at: CGPoint(x: c.x + rr * CGFloat(cos(mid)), y: c.y + rr * CGFloat(sin(mid))),
                     align: 1, ctx: ctx)
            }
            angle += sweep
        }
    }

    private func drawAxes(_ plot: Plot, in box0: CGRect, area: PPTXNode, base: CGFloat, ctx: CGContext) {
        let count = max(plot.categories.count, plot.series.map(\.values.count).max() ?? 0)
        guard count > 0 else { return }
        let stacked = plot.grouping == "stacked" || plot.grouping == "percentStacked"
        let percent = plot.grouping == "percentStacked"
        // Value range.
        var lo = 0.0, hi = 0.0
        if plot.kind == "scatter" {
            let ys = plot.series.flatMap { $0.values.compactMap { $0 } }
            lo = ys.min() ?? 0; hi = ys.max() ?? 1
        } else if stacked {
            for i in 0..<count {
                var pos = 0.0, neg = 0.0
                for s in plot.series { let v = i < s.values.count ? s.values[i] ?? 0 : 0; if v >= 0 { pos += v } else { neg += v } }
                hi = max(hi, pos); lo = min(lo, neg)
            }
            if percent { lo = min(0, lo); hi = 1 }
        } else {
            let all = plot.series.flatMap { $0.values.compactMap { $0 } }
            lo = min(0, all.min() ?? 0); hi = all.max() ?? 1
        }
        let valAx = area.child("c:valAx")
        if let mn = valAx?.child("c:scaling")?.child("c:min")?.double("val") { lo = mn }
        if let mx = valAx?.child("c:scaling")?.child("c:max")?.double("val") { hi = mx }
        let (vmin, vmax, step) = percent ? (0, 1, 0.2) : Self.niceScale(lo, hi)
        let labelSize = base * 0.85
        let tickLabels = stride(from: vmin, through: vmax + step / 2, by: step).map { Self.label($0, percent: percent) }
        let labelWidth = (tickLabels.map { width(line($0, size: labelSize)) }.max() ?? 20) + 6
        var box = box0
        let valueAxisShown = valAx?.child("c:delete")?.bool("val") != true
        let catAxisShown = area.child("c:catAx")?.child("c:delete")?.bool("val") != true
        if plot.horizontal {
            if catAxisShown { let cw = min(box.width * 0.3, (plot.categories.map { width(line($0, size: labelSize)) }.max() ?? 0) + 8); box.origin.x += cw; box.size.width -= cw }
            if valueAxisShown { box.size.height -= labelSize * 1.6 }
        } else {
            if valueAxisShown { box.origin.x += labelWidth; box.size.width -= labelWidth }
            if catAxisShown { box.size.height -= labelSize * 1.8 }
        }
        guard box.width > 4, box.height > 4 else { return }
        func valuePos(_ v: Double) -> CGFloat {
            let t = CGFloat((v - vmin) / max(1e-12, vmax - vmin))
            return plot.horizontal ? box.minX + t * box.width : box.maxY - t * box.height
        }
        // Gridlines and value labels.
        ctx.setLineWidth(0.75)
        var v = vmin
        while v <= vmax + step / 2 {
            let p = valuePos(v)
            ctx.setStrokeColor(PPTXColor(hex: "D9D9D9")!.cgColor)
            if plot.horizontal {
                ctx.move(to: CGPoint(x: p, y: box.minY)); ctx.addLine(to: CGPoint(x: p, y: box.maxY))
            } else {
                ctx.move(to: CGPoint(x: box.minX, y: p)); ctx.addLine(to: CGPoint(x: box.maxX, y: p))
            }
            ctx.strokePath()
            if valueAxisShown {
                let l = line(Self.label(v, percent: percent), size: labelSize)
                if plot.horizontal { draw(l, at: CGPoint(x: p, y: box.maxY + labelSize), align: 1, ctx: ctx) }
                else { draw(l, at: CGPoint(x: box.minX - 4, y: p), align: 2, ctx: ctx) }
            }
            v += step
        }
        // Category axis line and labels.
        let slot = (plot.horizontal ? box.height : box.width) / CGFloat(count)
        ctx.setStrokeColor(PPTXColor(hex: "BFBFBF")!.cgColor)
        let zero = valuePos(max(vmin, min(vmax, 0)))
        if plot.horizontal { ctx.move(to: CGPoint(x: zero, y: box.minY)); ctx.addLine(to: CGPoint(x: zero, y: box.maxY)) }
        else { ctx.move(to: CGPoint(x: box.minX, y: zero)); ctx.addLine(to: CGPoint(x: box.maxX, y: zero)) }
        ctx.strokePath()
        if catAxisShown, plot.kind != "scatter" {
            let every = max(1, Int(ceil(CGFloat(count) * labelSize * 2.5 / max(1, plot.horizontal ? box.height * 2 : box.width))))
            for (i, name) in plot.categories.enumerated() where i % every == 0 {
                let l = line(name, size: labelSize)
                if plot.horizontal {
                    // PowerPoint draws a bar chart's first category at the bottom.
                    let y = box.maxY - (CGFloat(i) + 0.5) * slot
                    draw(l, at: CGPoint(x: box.minX - 4, y: y), align: 2, ctx: ctx)
                } else {
                    draw(l, at: CGPoint(x: box.minX + (CGFloat(i) + 0.5) * slot, y: box.maxY + labelSize), align: 1, ctx: ctx)
                }
            }
        }
        // Data.
        switch plot.kind {
        case "bar":
            let n = CGFloat(stacked ? 1 : plot.series.count)
            let groupWidth = slot / (1 + CGFloat(plot.gap) / 100)
            let barWidth = stacked ? groupWidth : groupWidth / max(1, n - (n - 1) * CGFloat(plot.overlap) / 100)
            let advance = barWidth * (1 - CGFloat(plot.overlap) / 100)
            var pos = [Double](repeating: 0, count: count), neg = [Double](repeating: 0, count: count)
            var totals = [Double](repeating: 0, count: count)
            if percent {
                for i in 0..<count { totals[i] = plot.series.reduce(0) { $0 + abs(i < $1.values.count ? $1.values[i] ?? 0 : 0) } }
            }
            for (si, s) in plot.series.enumerated() {
                for i in 0..<count {
                    guard i < s.values.count, var value = s.values[i] else { continue }
                    if percent { value = totals[i] > 0 ? value / totals[i] : 0 }
                    var start = 0.0
                    if stacked { start = value >= 0 ? pos[i] : neg[i]; if value >= 0 { pos[i] += value } else { neg[i] += value } }
                    let a = valuePos(start), b = valuePos(start + value)
                    let catStart = (CGFloat(i) + 0.5) * slot - groupWidth / 2
                    let offset = stacked ? 0 : CGFloat(si) * advance
                    let r: CGRect
                    if plot.horizontal {
                        let y = box.maxY - catStart - offset - barWidth
                        r = CGRect(x: min(a, b), y: y, width: abs(b - a), height: barWidth)
                    } else {
                        r = CGRect(x: box.minX + catStart + offset, y: min(a, b), width: barWidth, height: abs(b - a))
                    }
                    ctx.setFillColor((s.pointFills[i] ?? (plot.varyColors && plot.series.count == 1 ? seriesColor(i) : s.fill)).cgColor)
                    ctx.fill(r)
                    if let lc = s.line { ctx.setStrokeColor(lc.cgColor); ctx.setLineWidth(0.75); ctx.stroke(r) }
                    if plot.showValues {
                        let l = line(Self.label(value, percent: percent), size: labelSize * 0.95, color: PPTXColor(hex: "404040")!)
                        if plot.horizontal { draw(l, at: CGPoint(x: r.maxX + 3, y: r.midY), align: 0, ctx: ctx) }
                        else { draw(l, at: CGPoint(x: r.midX, y: r.minY - labelSize * 0.7), align: 1, ctx: ctx) }
                    }
                }
            }
        case "line", "area", "scatter":
            var running = [Double](repeating: 0, count: count)
            let xs = plot.series.first?.xValues.compactMap { $0 } ?? []
            let xmin = xs.min() ?? 0, xmax = xs.max() ?? 1
            for s in (plot.kind == "area" ? plot.series : plot.series) {
                var pts: [CGPoint?] = []
                for i in 0..<count {
                    guard i < s.values.count, var value = s.values[i] else { pts.append(nil); continue }
                    if stacked { running[i] += value; value = running[i] }
                    var x = box.minX + (CGFloat(i) + 0.5) * slot
                    if plot.kind == "scatter", i < s.xValues.count, let xv = s.xValues[i], xmax > xmin {
                        x = box.minX + CGFloat((xv - xmin) / (xmax - xmin)) * box.width
                    }
                    pts.append(CGPoint(x: x, y: valuePos(value)))
                }
                let valid = pts.compactMap { $0 }
                guard !valid.isEmpty else { continue }
                if plot.kind == "area" {
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: valid[0].x, y: zero))
                    for p in valid { path.addLine(to: p) }
                    path.addLine(to: CGPoint(x: valid.last!.x, y: zero))
                    path.closeSubpath()
                    ctx.setFillColor(s.fill.with(alpha: 0.85).cgColor)
                    ctx.addPath(path); ctx.fillPath()
                    continue
                }
                if let lc = s.line {
                    ctx.setStrokeColor(lc.cgColor)
                    ctx.setLineWidth(max(1.5, min(3, box.height / 120)))
                    ctx.setLineJoin(.round); ctx.setLineCap(.round)
                    var started = false
                    for p in pts {
                        guard let p else { started = false; continue }
                        if started { ctx.addLine(to: p) } else { ctx.move(to: p); started = true }
                    }
                    ctx.strokePath()
                }
                if s.marker || plot.kind == "scatter" {
                    ctx.setFillColor((s.line ?? s.fill).cgColor)
                    let m = max(3, min(7, box.height / 50))
                    for p in valid { ctx.fillEllipse(in: CGRect(x: p.x - m / 2, y: p.y - m / 2, width: m, height: m)) }
                }
                if plot.showValues {
                    for (i, p) in pts.enumerated() {
                        guard let p, i < s.values.count, let value = s.values[i] else { continue }
                        draw(line(Self.label(value), size: labelSize * 0.95, color: PPTXColor(hex: "404040")!),
                             at: CGPoint(x: p.x, y: p.y - labelSize), align: 1, ctx: ctx)
                    }
                }
            }
        default:
            break
        }
    }
}
