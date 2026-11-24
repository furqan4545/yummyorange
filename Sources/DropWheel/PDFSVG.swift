import AppKit
import CoreGraphics
import PDFKit

/// PDF → SVG. Each page's content stream is walked with CGPDFScanner and written as SVG elements:
/// vector paths, clipping, colours, gradients, tiling patterns, images (with soft masks), form XObjects
/// and positioned text that stays selectable. One SVG per page: "<name> page N.svg", or "<name>.svg"
/// for a one-page PDF.
///
/// Options: `pages` ("1,3-5"; default all), `background` (white | none; default white),
/// `images` (auto | png | jpeg; default auto), `annotations` (true | false; default true).
enum PDFSVG {
    struct Settings {
        var background = true
        var images = "auto"
        var annotations = true

        init(_ options: ToolOptions = [:]) {
            background = !["none", "transparent", "false", "off"].contains(options.string("background", "white").lowercased())
            images = options.string("images", "auto").lowercased()
            if !["auto", "png", "jpeg", "jpg"].contains(images) { images = "auto" }
            if images == "jpg" { images = "jpeg" }
            annotations = options.bool("annotations", true)
        }
    }

    static func convert(_ url: URL, options: ToolOptions, progress: @escaping (Double) -> Void) throws -> [URL] {
        guard let doc = CGPDFDocument(url as CFURL) else { throw ConversionError.unreadable(url.lastPathComponent) }
        if doc.isEncrypted && !doc.isUnlocked { throw PDFExtras.lockedError(url) }
        let count = doc.numberOfPages
        guard count > 0 else { throw ConversionError.unsupported("\(url.lastPathComponent) has no pages.") }
        var numbers = try PDFOrganizer.parseOrder(options.string("pages", ""), count: count)?.map { $0 + 1 } ?? Array(1...count)
        var seen = Set<Int>()
        numbers = numbers.filter { seen.insert($0).inserted }
        let settings = Settings(options)
        let hidden = hiddenLayers(doc)
        var outputs: [URL] = []
        var kitDocument: PDFDocument?
        do {
            for (i, n) in numbers.enumerated() {
                guard let page = doc.page(at: n) else { continue }
                let svg = autoreleasepool { () -> String in
                    let renderer = PDFSVGRenderer(page: page, settings: settings, hiddenLayers: hidden)
                    renderer.textUnder = { rect in
                        if kitDocument == nil { kitDocument = PDFDocument(url: url) }
                        return kitDocument?.page(at: n - 1)?.selection(for: rect)?.string
                    }
                    return renderer.render()
                }
                let out = outputURL(for: url, ext: "svg", suffix: count > 1 ? " page \(n)" : "")
                try Data(svg.utf8).write(to: out, options: .atomic)
                outputs.append(out)
                progress(Double(i + 1) / Double(numbers.count))
            }
        } catch {
            outputs.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
        return outputs
    }

    /// Optional-content groups that are off in the default view (/OCProperties /D /OFF).
    static func hiddenLayers(_ doc: CGPDFDocument) -> Set<UnsafeRawPointer> {
        guard let off = PDFSVGObj.array(PDFSVGObj.dict(PDFSVGObj.dict(doc.catalog, "OCProperties"), "D"), "OFF") else { return [] }
        var set = Set<UnsafeRawPointer>()
        for i in 0..<CGPDFArrayGetCount(off) {
            var d: CGPDFDictionaryRef?
            if CGPDFArrayGetDictionary(off, i, &d), let d { set.insert(PDFSVGObj.key(d)) }
        }
        return set
    }
}

/// Fast, locale-free number formatting for SVG attributes.
enum PDFSVGNumber {
    private static let powers: [Double] = [1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000]

    static func format(_ value: CGFloat, _ decimals: Int = 3) -> String {
        let d = min(8, max(0, decimals))
        let v = Double(value)
        guard v.isFinite else { return "0" }
        let scaled = (v * powers[d]).rounded()
        if abs(scaled) >= 9e15 { return String(format: "%.0f", v) }
        var n = Int64(scaled)
        if n == 0 { return "0" }
        let negative = n < 0
        if negative { n = -n }
        let p = Int64(powers[d])
        var s = negative ? "-" : ""
        s += String(n / p)
        var frac = n % p
        if frac != 0 {
            var digits = d
            while frac % 10 == 0 { frac /= 10; digits -= 1 }
            let f = String(frac)
            s += "." + String(repeating: "0", count: digits - f.count) + f
        }
        return s
    }

    static func matrix(_ m: CGAffineTransform) -> String {
        "matrix(\(format(m.a, 6)) \(format(m.b, 6)) \(format(m.c, 6)) \(format(m.d, 6)) \(format(m.tx, 3)) \(format(m.ty, 3)))"
    }
}

extension CGAffineTransform {
    /// Scale and rotation only (no shear or uneven scale), so lengths scale by one factor.
    var pdfsvgIsSimilarity: Bool {
        let s1 = a * a + b * b, s2 = c * c + d * d
        return abs(s1 - s2) <= 1e-6 * max(s1, s2) && abs(a * c + b * d) <= 1e-6 * max(s1, s2) && s1 > 0
    }
    var pdfsvgScale: CGFloat { sqrt(abs(a * d - b * c)) }
}

/// Renders one page. Everything is written in the SVG's own coordinates (y down, origin top-left of the
/// visible page); a path keeps PDF user-space numbers with a `transform` when its CTM shears or
/// scales unevenly, so stroke widths and dashes stay exact.
final class PDFSVGRenderer {
    private enum Paint {
        case color(String)
        case pattern(PDFSVGPatternUse)
        case none
    }

    private struct GState {
        var ctm: CGAffineTransform = .identity
        var fill = Paint.color("#000000"), stroke = Paint.color("#000000")
        var fillSpace = PDFSVGColorSpace.gray, strokeSpace = PDFSVGColorSpace.gray
        var fillComponents: [CGFloat] = [0], strokeComponents: [CGFloat] = [0]
        var fillAlpha: CGFloat = 1, strokeAlpha: CGFloat = 1
        var lineWidth: CGFloat = 1, cap = 0, join = 0, miter: CGFloat = 10
        var dash: [CGFloat] = [], dashPhase: CGFloat = 0
        var blend: String?
        var font: PDFSVGFont?
        var fontSize: CGFloat = 0
        var charSpacing: CGFloat = 0, wordSpacing: CGFloat = 0, hScale: CGFloat = 1, leading: CGFloat = 0, rise: CGFloat = 0
        var renderMode = 0
        /// `<g>` elements (clips, masks) opened since the matching `q`.
        var groups = 0
    }

    private enum PathPart {
        case move(CGPoint), line(CGPoint), curve(CGPoint, CGPoint, CGPoint), close, rect(CGRect)
    }

    private let page: CGPDFPage
    private let settings: PDFSVG.Settings
    private let hiddenLayers: Set<UnsafeRawPointer>
    private let size: CGSize
    private let base: CGAffineTransform

    private var out = ""
    private var defs = ""
    private var fontClasses: [UnsafeRawPointer: String] = [:]
    private var styles = ""
    private var nextID = 0
    private var gs = GState()
    private var stack: [GState] = []
    private var path: [PathPart] = []
    private var current = CGPoint.zero, subpathStart = CGPoint.zero
    private var pendingClip: Bool? = nil   // even-odd?
    private var textMatrix = CGAffineTransform.identity, lineMatrix = CGAffineTransform.identity
    private var fonts: [UnsafeRawPointer: PDFSVGFont] = [:]
    private var images: [String: String] = [:]
    private var gradients: [UnsafeRawPointer: (String, PDFSVGGradient)?] = [:]
    private var tilings: [String: String] = [:]
    private var running = Set<UnsafeRawPointer>()
    private var depth = 0
    /// Pattern space of the content stream being run: the page's default space, or a form's.
    private var patternBase: CGAffineTransform
    private var marked: [Bool] = []
    private var hiddenDepth = 0
    private var forcedColor: String?   // uncoloured tiling patterns paint in one colour
    private var pageRaster: String?
    private var textRuns = 0
    /// Glyph runs shown with a clipping render mode (Tr 4–7) in each open BT … ET, as `<text>` elements;
    /// at ET they become the clip, as PDF adds the glyph outlines to the clipping path there.
    private var textClips: [[String]] = []
    private lazy var fallbackFont = PDFSVGFont.makeFallback()
    /// Text PDFKit extracts from a rectangle of the page, for glyphs without Unicode.
    var textUnder: ((CGRect) -> String?)?
    /// The page's own content stream (parent for forms and appearances) and resources (for streams that have none).
    private lazy var pageContent: CGPDFContentStreamRef = {
        ownsPageContent = true
        return CGPDFContentStreamCreateWithPage(page)
    }()
    private var ownsPageContent = false
    private let pageResources: CGPDFDictionaryRef

    init(page: CGPDFPage, settings: PDFSVG.Settings, hiddenLayers: Set<UnsafeRawPointer>) {
        self.page = page
        self.settings = settings
        self.hiddenLayers = hiddenLayers
        let crop = page.getBoxRect(.cropBox)
        let turns = ((page.rotationAngle % 360) + 360) % 360 / 90
        size = turns % 2 == 1 ? CGSize(width: crop.height, height: crop.width) : crop.size
        let upright = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
        base = upright.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height))
        gs.ctm = base
        patternBase = base
        var node = page.dictionary
        var resources: CGPDFDictionaryRef?
        for _ in 0..<32 {
            guard let current = node else { break }
            if let r = PDFSVGObj.dict(current, "Resources") { resources = r; break }
            node = PDFSVGObj.dict(current, "Parent")
        }
        pageResources = resources ?? page.dictionary!
    }

    deinit { if ownsPageContent { CGPDFContentStreamRelease(pageContent) } }

    func render() -> String {
        if settings.background {
            out += "<rect width=\"100%\" height=\"100%\" fill=\"#FFFFFF\"/>\n"
        }
        // A page without /Contents is blank (and Core Graphics would log an error for it).
        if PDFSVGObj.object(page.dictionary, "Contents") != nil { run(pageContent) }
        while !stack.isEmpty { pop() }
        closeGroups()
        if settings.annotations { drawAnnotations() }

        let w = PDFSVGNumber.format(size.width), h = PDFSVGNumber.format(size.height)
        var svg = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        svg += "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" version=\"1.1\" "
        svg += "width=\"\(w)pt\" height=\"\(h)pt\" viewBox=\"0 0 \(w) \(h)\" xml:space=\"preserve\">\n"
        if textRuns > 0 || !styles.isEmpty { svg += "<style>text{white-space:pre}\(styles)</style>\n" }
        if !defs.isEmpty { svg += "<defs>\n\(defs)</defs>\n" }
        svg += out
        svg += "</svg>\n"
        return svg
    }

    // MARK: Running content

    private func run(_ stream: CGPDFContentStreamRef) {
        let scanner = CGPDFScannerCreate(stream, PDFSVGRenderer.table, Unmanaged.passUnretained(self).toOpaque())
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }

    private func newID(_ prefix: String) -> String {
        nextID += 1
        return "\(prefix)\(nextID)"
    }

    private var visible: Bool { hiddenDepth == 0 }

    private func push() {
        stack.append(gs)
        gs.groups = 0
    }

    private func pop() {
        closeGroups()
        if let last = stack.popLast() { gs = last }
    }

    private func closeGroups() {
        if gs.groups > 0 { out += String(repeating: "</g>", count: gs.groups) + "\n" }
        gs.groups = 0
    }

    // MARK: Operands

    private enum Operand {
        case number(CGFloat), name(String), string([UInt8]), array(CGPDFArrayRef), dictionary(CGPDFDictionaryRef)
        case stream(CGPDFStreamRef), other

        var number: CGFloat? { if case .number(let n) = self { return n }; return nil }
        var name: String? { if case .name(let n) = self { return n }; return nil }
    }

    /// The last `count` operands of the current operator, in order. (Popping past the first operand
    /// makes Core Graphics log an error, so each operator pops exactly what it takes.)
    private static func operands(_ scanner: CGPDFScannerRef, _ count: Int) -> [Operand] {
        var list: [Operand] = []
        var object: CGPDFObjectRef?
        for _ in 0..<count {
            guard CGPDFScannerPopObject(scanner, &object), let o = object else { break }
            list.append(operand(o))
        }
        return list.reversed()
    }

    private static func operand(_ o: CGPDFObjectRef) -> Operand {
        switch CGPDFObjectGetType(o) {
        case .integer, .real:
            var v: CGPDFReal = 0
            return CGPDFObjectGetValue(o, .real, &v) ? .number(v) : .other
        case .name:
            return PDFSVGObj.nameValue(o).map { .name($0) } ?? .other
        case .string:
            var s: CGPDFStringRef?
            return CGPDFObjectGetValue(o, .string, &s) && s != nil ? .string(PDFSVGObj.bytes(s!)) : .other
        case .array:
            return PDFSVGObj.arrayValue(o).map { .array($0) } ?? .other
        case .dictionary:
            var d: CGPDFDictionaryRef?
            return CGPDFObjectGetValue(o, .dictionary, &d) && d != nil ? .dictionary(d!) : .other
        case .stream:
            return PDFSVGObj.streamValue(o).map { .stream($0) } ?? .other
        default:
            return .other
        }
    }

    private static func numbers(_ s: CGPDFScannerRef, _ count: Int) -> [CGFloat] { operands(s, count).compactMap(\.number) }

    private static func resource(_ s: CGPDFScannerRef, _ category: String, _ name: String) -> CGPDFObjectRef? {
        CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(s), category, name)
    }

    private static func resource(in content: CGPDFContentStreamRef, _ category: String, _ name: String) -> CGPDFObjectRef? {
        CGPDFContentStreamGetResource(content, category, name)
    }

    // MARK: Operator table

    private static func me(_ info: UnsafeMutableRawPointer?) -> PDFSVGRenderer {
        Unmanaged<PDFSVGRenderer>.fromOpaque(info!).takeUnretainedValue()
    }

    private static let table: CGPDFOperatorTableRef = {
        let t = CGPDFOperatorTableCreate()!
        func on(_ op: String, _ callback: @escaping CGPDFOperatorCallback) { CGPDFOperatorTableSetCallback(t, op, callback) }
        // Graphics state
        on("q") { _, i in me(i).push() }
        on("Q") { _, i in me(i).pop() }
        on("cm") { s, i in me(i).concat(numbers(s, 6)) }
        on("w") { s, i in if let v = numbers(s, 1).last { me(i).gs.lineWidth = v } }
        on("J") { s, i in if let v = numbers(s, 1).last { me(i).gs.cap = Int(v) } }
        on("j") { s, i in if let v = numbers(s, 1).last { me(i).gs.join = Int(v) } }
        on("M") { s, i in if let v = numbers(s, 1).last { me(i).gs.miter = v } }
        on("d") { s, i in me(i).setDash(operands(s, 2)) }
        on("gs") { s, i in if let n = operands(s, 1).last?.name { me(i).extGState(s, n) } }
        // Paths
        on("m") { s, i in me(i).moveTo(numbers(s, 2)) }
        on("l") { s, i in me(i).lineTo(numbers(s, 2)) }
        on("c") { s, i in me(i).curveTo(numbers(s, 6), kind: 0) }
        on("v") { s, i in me(i).curveTo(numbers(s, 4), kind: 1) }
        on("y") { s, i in me(i).curveTo(numbers(s, 4), kind: 2) }
        on("h") { _, i in me(i).closePath() }
        on("re") { s, i in me(i).rect(numbers(s, 4)) }
        // Painting and clipping
        on("S") { _, i in me(i).paint(fill: false, evenOdd: false, stroke: true, close: false) }
        on("s") { _, i in me(i).paint(fill: false, evenOdd: false, stroke: true, close: true) }
        on("f") { _, i in me(i).paint(fill: true, evenOdd: false, stroke: false, close: false) }
        on("F") { _, i in me(i).paint(fill: true, evenOdd: false, stroke: false, close: false) }
        on("f*") { _, i in me(i).paint(fill: true, evenOdd: true, stroke: false, close: false) }
        on("B") { _, i in me(i).paint(fill: true, evenOdd: false, stroke: true, close: false) }
        on("B*") { _, i in me(i).paint(fill: true, evenOdd: true, stroke: true, close: false) }
        on("b") { _, i in me(i).paint(fill: true, evenOdd: false, stroke: true, close: true) }
        on("b*") { _, i in me(i).paint(fill: true, evenOdd: true, stroke: true, close: true) }
        on("n") { _, i in me(i).paint(fill: false, evenOdd: false, stroke: false, close: false) }
        on("W") { _, i in me(i).pendingClip = false }
        on("W*") { _, i in me(i).pendingClip = true }
        // Colour
        on("g") { s, i in me(i).setColor(fill: true, space: .gray, numbers(s, 1)) }
        on("G") { s, i in me(i).setColor(fill: false, space: .gray, numbers(s, 1)) }
        on("rg") { s, i in me(i).setColor(fill: true, space: .rgb, numbers(s, 3)) }
        on("RG") { s, i in me(i).setColor(fill: false, space: .rgb, numbers(s, 3)) }
        on("k") { s, i in me(i).setColor(fill: true, space: .cmyk, numbers(s, 4)) }
        on("K") { s, i in me(i).setColor(fill: false, space: .cmyk, numbers(s, 4)) }
        on("cs") { s, i in if let n = operands(s, 1).last?.name { me(i).setSpace(s, n, fill: true) } }
        on("CS") { s, i in if let n = operands(s, 1).last?.name { me(i).setSpace(s, n, fill: false) } }
        on("sc") { s, i in me(i).setComponents(s, fill: true) }
        on("scn") { s, i in me(i).setComponents(s, fill: true) }
        on("SC") { s, i in me(i).setComponents(s, fill: false) }
        on("SCN") { s, i in me(i).setComponents(s, fill: false) }
        // Text
        on("BT") { _, i in me(i).textMatrix = .identity; me(i).lineMatrix = .identity; me(i).textClips.append([]) }
        on("ET") { _, i in me(i).endText() }
        on("Tc") { s, i in if let v = numbers(s, 1).last { me(i).gs.charSpacing = v } }
        on("Tw") { s, i in if let v = numbers(s, 1).last { me(i).gs.wordSpacing = v } }
        on("Tz") { s, i in if let v = numbers(s, 1).last { me(i).gs.hScale = v / 100 } }
        on("TL") { s, i in if let v = numbers(s, 1).last { me(i).gs.leading = v } }
        on("Ts") { s, i in if let v = numbers(s, 1).last { me(i).gs.rise = v } }
        on("Tr") { s, i in if let v = numbers(s, 1).last { me(i).gs.renderMode = Int(v) } }
        on("Tf") { s, i in me(i).setFont(s, operands(s, 2)) }
        on("Td") { s, i in let n = numbers(s, 2); if n.count >= 2 { me(i).moveText(n[n.count - 2], n[n.count - 1]) } }
        on("TD") { s, i in
            let n = numbers(s, 2)
            if n.count >= 2 { me(i).gs.leading = -n[n.count - 1]; me(i).moveText(n[n.count - 2], n[n.count - 1]) }
        }
        on("Tm") { s, i in
            let n = numbers(s, 6)
            if n.count >= 6 {
                let m = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
                me(i).textMatrix = m; me(i).lineMatrix = m
            }
        }
        on("T*") { _, i in me(i).nextLine() }
        on("Tj") { s, i in if case .string(let b)? = operands(s, 1).last { me(i).show(s, [.string(b)]) } }
        on("'") { s, i in
            me(i).nextLine()
            if case .string(let b)? = operands(s, 1).last { me(i).show(s, [.string(b)]) }
        }
        on("\"") { s, i in
            let ops = operands(s, 3)
            if ops.count >= 3, let aw = ops[0].number, let ac = ops[1].number, case .string(let b) = ops[2] {
                me(i).gs.wordSpacing = aw; me(i).gs.charSpacing = ac
                me(i).nextLine()
                me(i).show(s, [.string(b)])
            }
        }
        on("TJ") { s, i in
            guard case .array(let a)? = operands(s, 1).last else { return }
            var items: [Operand] = []
            for k in 0..<CGPDFArrayGetCount(a) {
                if let o = PDFSVGObj.element(a, k) { items.append(operand(o)) }
            }
            me(i).show(s, items)
        }
        // XObjects, shadings, inline images
        on("Do") { s, i in if let n = operands(s, 1).last?.name { me(i).doXObject(s, n) } }
        on("sh") { s, i in if let n = operands(s, 1).last?.name { me(i).shade(s, n) } }
        on("EI") { s, i in
            var stream: CGPDFStreamRef?
            if CGPDFScannerPopStream(s, &stream), let stream { me(i).drawImage(stream, scanner: s, inline: true) }
        }
        // Marked content (optional content)
        on("BMC") { _, i in me(i).marked.append(false) }
        on("BDC") { s, i in me(i).beginMarked(s, operands(s, 2)) }
        on("EMC") { _, i in
            let r = me(i)
            if let last = r.marked.popLast(), last { r.hiddenDepth -= 1 }
        }
        return t
    }()

    // MARK: Graphics state

    private func concat(_ n: [CGFloat]) {
        guard n.count >= 6 else { return }
        gs.ctm = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(gs.ctm)
    }

    private func setDash(_ ops: [Operand]) {
        guard ops.count >= 2, case .array(let a) = ops[ops.count - 2] else { return }
        let values = PDFSVGObj.numbers(a)
        gs.dash = values.contains(where: { $0 < 0 }) || values.allSatisfy({ $0 == 0 }) ? [] : values
        gs.dashPhase = ops.last?.number ?? 0
    }

    private func extGState(_ s: CGPDFScannerRef, _ name: String) {
        guard let object = Self.resource(s, "ExtGState", name), let d = PDFSVGObj.dictValue(object) else { return }
        if let v = PDFSVGObj.number(d, "LW") { gs.lineWidth = v }
        if let v = PDFSVGObj.int(d, "LC") { gs.cap = v }
        if let v = PDFSVGObj.int(d, "LJ") { gs.join = v }
        if let v = PDFSVGObj.number(d, "ML") { gs.miter = v }
        if let v = PDFSVGObj.number(d, "CA") { gs.strokeAlpha = min(1, max(0, v)) }
        if let v = PDFSVGObj.number(d, "ca") { gs.fillAlpha = min(1, max(0, v)) }
        if let dash = PDFSVGObj.array(d, "D"), CGPDFArrayGetCount(dash) == 2 {
            var a: CGPDFArrayRef?
            var phase: CGPDFReal = 0
            if CGPDFArrayGetArray(dash, 0, &a) {
                let values = PDFSVGObj.numbers(a)
                gs.dash = values.allSatisfy({ $0 == 0 }) ? [] : values
            }
            if CGPDFArrayGetNumber(dash, 1, &phase) { gs.dashPhase = phase }
        }
        var bm = PDFSVGObj.name(d, "BM")
        if bm == nil, let arr = PDFSVGObj.array(d, "BM") {
            var p: UnsafePointer<Int8>?
            if CGPDFArrayGetName(arr, 0, &p), let p { bm = String(cString: p) }
        }
        if let bm {
            let map = ["Multiply": "multiply", "Screen": "screen", "Overlay": "overlay", "Darken": "darken",
                       "Lighten": "lighten", "ColorDodge": "color-dodge", "ColorBurn": "color-burn",
                       "HardLight": "hard-light", "SoftLight": "soft-light", "Difference": "difference",
                       "Exclusion": "exclusion", "Hue": "hue", "Saturation": "saturation", "Color": "color",
                       "Luminosity": "luminosity"]
            gs.blend = map[bm]
        }
        if let entry = PDFSVGObj.array(d, "Font"), CGPDFArrayGetCount(entry) == 2 {
            var fd: CGPDFDictionaryRef?
            var size: CGPDFReal = 0
            if CGPDFArrayGetDictionary(entry, 0, &fd), let fd { gs.font = font(for: fd) }
            if CGPDFArrayGetNumber(entry, 1, &size) { gs.fontSize = size }
        }
        if let smask = PDFSVGObj.dict(d, "SMask") { applySoftMask(s, smask) }
    }

    /// A soft mask from an ExtGState: its group is drawn into an SVG `<mask>` that applies to what follows,
    /// until the matching `Q`.
    private func applySoftMask(_ s: CGPDFScannerRef, _ smask: CGPDFDictionaryRef) {
        guard visible, let group = PDFSVGObj.stream(smask, "G"), depth < 12 else { return }
        let luminosity = PDFSVGObj.name(smask, "S") != "Alpha"
        let id = newID("m")
        let saved = out
        let savedPath = (path, current, subpathStart, pendingClip, textMatrix, lineMatrix)
        defer { (path, current, subpathStart, pendingClip, textMatrix, lineMatrix) = savedPath }
        path = []
        pendingClip = nil
        out = ""
        let savedState = gs, savedStack = stack
        stack = []
        gs.groups = 0
        gs.fillAlpha = 1; gs.strokeAlpha = 1; gs.blend = nil
        let groupInfo = PDFSVGObj.dict(CGPDFStreamGetDictionary(group), "Group")
        if luminosity, let bc = PDFSVGObj.array(smask, "BC"), let spaceObject = PDFSVGObj.object(groupInfo, "CS"),
           let space = PDFSVGColorSpace.parse(spaceObject, lookup: { Self.resource(s, "ColorSpace", $0) }) {
            out += "<rect x=\"-1e5\" y=\"-1e5\" width=\"2e5\" height=\"2e5\" fill=\"\(space.hex(PDFSVGObj.numbers(bc)))\"/>\n"
        }
        let savedHidden = hiddenDepth
        hiddenDepth = 0
        drawForm(group, scanner: s, groupOpacity: false)
        hiddenDepth = savedHidden
        while !stack.isEmpty { pop() }
        closeGroups()
        let content = out
        out = saved
        gs = savedState
        stack = savedStack
        let type = luminosity ? "luminance" : "alpha"
        defs += "<mask id=\"\(id)\" maskUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"\(PDFSVGNumber.format(size.width))\" "
        defs += "height=\"\(PDFSVGNumber.format(size.height))\" style=\"mask-type:\(type)\" color-interpolation=\"sRGB\">\n\(content)</mask>\n"
        out += "<g mask=\"url(#\(id))\">\n"
        gs.groups += 1
    }

    // MARK: Paths

    private func moveTo(_ n: [CGFloat]) {
        guard n.count >= 2 else { return }
        current = CGPoint(x: n[n.count - 2], y: n[n.count - 1])
        subpathStart = current
        path.append(.move(current))
    }

    private func lineTo(_ n: [CGFloat]) {
        guard n.count >= 2 else { return }
        if path.isEmpty { path.append(.move(current)) }
        current = CGPoint(x: n[n.count - 2], y: n[n.count - 1])
        path.append(.line(current))
    }

    /// c (kind 0), v (first control point is the current point), y (second control point is the end).
    private func curveTo(_ n: [CGFloat], kind: Int) {
        if path.isEmpty { path.append(.move(current)) }
        switch kind {
        case 0:
            guard n.count >= 6 else { return }
            let end = CGPoint(x: n[4], y: n[5])
            path.append(.curve(CGPoint(x: n[0], y: n[1]), CGPoint(x: n[2], y: n[3]), end))
            current = end
        case 1:
            guard n.count >= 4 else { return }
            let end = CGPoint(x: n[2], y: n[3])
            path.append(.curve(current, CGPoint(x: n[0], y: n[1]), end))
            current = end
        default:
            guard n.count >= 4 else { return }
            let end = CGPoint(x: n[2], y: n[3])
            path.append(.curve(CGPoint(x: n[0], y: n[1]), end, end))
            current = end
        }
    }

    private func closePath() {
        if !path.isEmpty { path.append(.close) }
        current = subpathStart
    }

    private func rect(_ n: [CGFloat]) {
        guard n.count >= 4 else { return }
        path.append(.rect(CGRect(x: n[0], y: n[1], width: n[2], height: n[3])))
        current = CGPoint(x: n[0], y: n[1])
        subpathStart = current
    }

    /// The path data, either already in SVG space (`direct`) or in user space for a `transform`.
    private func pathData(_ parts: [PathPart], direct: Bool, ctm: CGAffineTransform) -> String {
        let scale = max(ctm.pdfsvgScale, 1e-9)
        let decimals = direct ? 3 : min(8, max(1, 3 + Int((-log10(scale)).rounded(.up))))
        var d = ""
        d.reserveCapacity(parts.count * 16)
        func p(_ point: CGPoint) {
            let q = direct ? point.applying(ctm) : point
            d += PDFSVGNumber.format(q.x, decimals); d += " "; d += PDFSVGNumber.format(q.y, decimals)
        }
        for part in parts {
            switch part {
            case .move(let a): d += "M"; p(a)
            case .line(let a): d += "L"; p(a)
            case .curve(let a, let b, let c): d += "C"; p(a); d += " "; p(b); d += " "; p(c)
            case .close: d += "Z"
            case .rect(let r):
                if direct {
                    d += "M"; p(r.origin); d += "L"; p(CGPoint(x: r.maxX, y: r.minY)); d += "L"; p(CGPoint(x: r.maxX, y: r.maxY))
                    d += "L"; p(CGPoint(x: r.minX, y: r.maxY)); d += "Z"
                } else {
                    d += "M"; p(r.origin)
                    d += "h\(PDFSVGNumber.format(r.width, decimals))v\(PDFSVGNumber.format(r.height, decimals))h\(PDFSVGNumber.format(-r.width, decimals))Z"
                }
            }
        }
        return d
    }

    private func paint(fill: Bool, evenOdd: Bool, stroke: Bool, close: Bool) {
        if close && !path.isEmpty { path.append(.close) }
        // Building a pattern runs other content, which uses `path`; keep this one.
        let path = self.path
        self.path.removeAll(keepingCapacity: true)
        let clipRule = pendingClip
        pendingClip = nil
        if !path.isEmpty && (fill || stroke) && visible {
            let direct = gs.ctm.pdfsvgIsSimilarity
            let scale = direct ? gs.ctm.pdfsvgScale : 1
            let elementTransform: CGAffineTransform = direct ? .identity : gs.ctm
            let fillPaint = fill ? paintAttribute(gs.fill, space: gs.fillSpace, element: elementTransform) : nil
            let strokePaint = stroke ? paintAttribute(gs.stroke, space: gs.strokeSpace, element: elementTransform) : nil
            if fillPaint != nil || strokePaint != nil {
                var attrs = "d=\"\(pathData(path, direct: direct, ctm: gs.ctm))\""
                if let fillPaint {
                    attrs += " fill=\"\(fillPaint)\""
                    if gs.fillAlpha < 1 { attrs += " fill-opacity=\"\(PDFSVGNumber.format(gs.fillAlpha))\"" }
                    if evenOdd { attrs += " fill-rule=\"evenodd\"" }
                } else {
                    attrs += " fill=\"none\""
                }
                if let strokePaint {
                    attrs += " stroke=\"\(strokePaint)\"" + strokeAttributes(scale: scale, direct: direct)
                    if gs.strokeAlpha < 1 { attrs += " stroke-opacity=\"\(PDFSVGNumber.format(gs.strokeAlpha))\"" }
                }
                if !direct { attrs += " transform=\"\(PDFSVGNumber.matrix(gs.ctm))\"" }
                if let blend = gs.blend { attrs += " style=\"mix-blend-mode:\(blend)\"" }
                out += "<path \(attrs)/>\n"
            }
        }
        if let clipRule { clip(path, evenOdd: clipRule, ctm: gs.ctm) }
    }

    /// `scale`: user space → SVG length factor when the path is written directly, else 1.
    private func strokeAttributes(scale: CGFloat, direct: Bool) -> String {
        var a = ""
        // Width 0 is the thinnest line a device can draw; use half a point.
        let width = gs.lineWidth > 0 ? gs.lineWidth * scale : direct ? 0.5 : 0.5 / max(gs.ctm.pdfsvgScale, 1e-6)
        if abs(width - 1) > 1e-6 { a += " stroke-width=\"\(PDFSVGNumber.format(width, 4))\"" }
        if gs.cap == 1 { a += " stroke-linecap=\"round\"" } else if gs.cap == 2 { a += " stroke-linecap=\"square\"" }
        if gs.join == 1 { a += " stroke-linejoin=\"round\"" } else if gs.join == 2 { a += " stroke-linejoin=\"bevel\"" }
        else if abs(gs.miter - 4) > 1e-6 { a += " stroke-miterlimit=\"\(PDFSVGNumber.format(max(1, gs.miter)))\"" }
        if !gs.dash.isEmpty {
            a += " stroke-dasharray=\"\(gs.dash.map { PDFSVGNumber.format($0 * scale, 3) }.joined(separator: " "))\""
            if gs.dashPhase != 0 { a += " stroke-dashoffset=\"\(PDFSVGNumber.format(gs.dashPhase * scale))\"" }
        }
        return a
    }

    /// Intersects the clip with a path by opening a clipped group. A rectangle covering the whole page is skipped.
    private func clip(_ parts: [PathPart], evenOdd: Bool, ctm: CGAffineTransform) {
        if parts.count == 1, case .rect(let r) = parts[0], ctm.b == 0, ctm.c == 0 {
            let box = r.applying(ctm)
            if box.minX <= 0.01 && box.minY <= 0.01 && box.maxX >= size.width - 0.01 && box.maxY >= size.height - 0.01 { return }
        }
        let id = newID("c")
        let direct = ctm.pdfsvgIsSimilarity
        var d = parts.isEmpty ? "M0 0" : pathData(parts, direct: direct, ctm: ctm)
        if d.isEmpty { d = "M0 0" }
        defs += "<clipPath id=\"\(id)\" clipPathUnits=\"userSpaceOnUse\"><path d=\"\(d)\""
        if !direct { defs += " transform=\"\(PDFSVGNumber.matrix(ctm))\"" }
        if evenOdd { defs += " clip-rule=\"evenodd\"" }
        defs += "/></clipPath>\n"
        out += "<g clip-path=\"url(#\(id))\">\n"
        gs.groups += 1
    }

    private func clipRect(_ r: CGRect, ctm: CGAffineTransform) {
        clip([.rect(r)], evenOdd: false, ctm: ctm)
    }

    // MARK: Colour

    private func setColor(fill: Bool, space: PDFSVGColorSpace, _ n: [CGFloat]) {
        guard n.count >= space.components else { return }
        let comps = Array(n.suffix(space.components))
        if fill {
            gs.fillSpace = space; gs.fillComponents = comps; gs.fill = .color(space.hex(comps))
        } else {
            gs.strokeSpace = space; gs.strokeComponents = comps; gs.stroke = .color(space.hex(comps))
        }
    }

    private func setSpace(_ s: CGPDFScannerRef, _ name: String, fill: Bool) {
        let lookup: (String) -> CGPDFObjectRef? = { Self.resource(s, "ColorSpace", $0) }
        let space: PDFSVGColorSpace
        switch name {
        case "DeviceGray", "G", "CalGray": space = .gray
        case "DeviceRGB", "RGB", "CalRGB": space = .rgb
        case "DeviceCMYK", "CMYK": space = .cmyk
        case "Pattern": space = PDFSVGColorSpace(.pattern(nil), components: 0)
        default:
            guard let object = lookup(name), let parsed = PDFSVGColorSpace.parse(object, lookup: lookup) else { return }
            space = parsed
        }
        let initial = space.initial
        if fill {
            gs.fillSpace = space; gs.fillComponents = initial
            gs.fill = space.isPattern ? .none : space.paintsNothing ? .none : .color(space.hex(initial))
        } else {
            gs.strokeSpace = space; gs.strokeComponents = initial
            gs.stroke = space.isPattern ? .none : space.paintsNothing ? .none : .color(space.hex(initial))
        }
    }

    private func setComponents(_ s: CGPDFScannerRef, fill: Bool) {
        let space = fill ? gs.fillSpace : gs.strokeSpace
        var count = space.components
        if case .pattern(let underlying) = space.kind { count = 1 + (underlying?.components ?? 0) }
        let ops = Self.operands(s, count)
        let comps = ops.compactMap(\.number)
        let paint: Paint
        if case .pattern(let underlying) = space.kind {
            guard let name = ops.last?.name, let use = patternUse(s, name, components: comps, underlying: underlying) else {
                paint = .none
                if fill { gs.fill = paint } else { gs.stroke = paint }
                return
            }
            paint = .pattern(use)
        } else {
            guard comps.count >= space.components else { return }
            let c = Array(comps.prefix(space.components))
            if fill { gs.fillComponents = c } else { gs.strokeComponents = c }
            paint = space.paintsNothing ? .none : .color(space.hex(c))
        }
        if fill { gs.fill = paint } else { gs.stroke = paint }
    }

    /// The SVG paint for an element whose own coordinates map to the page through `element`.
    private func paintAttribute(_ paint: Paint, space: PDFSVGColorSpace, element: CGAffineTransform) -> String? {
        if let forcedColor { return forcedColor }
        switch paint {
        case .none: return nil
        case .color(let hex): return hex
        case .pattern(let use): return patternPaint(use, element: element)
        }
    }

    // MARK: Patterns and shadings

    private func patternUse(_ s: CGPDFScannerRef, _ name: String, components: [CGFloat], underlying: PDFSVGColorSpace?) -> PDFSVGPatternUse? {
        guard let object = Self.resource(s, "Pattern", name), let dict = PDFSVGObj.dictValue(object) else { return nil }
        let matrix = (PDFSVGObj.matrix(PDFSVGObj.array(dict, "Matrix")) ?? .identity).concatenating(patternBase)
        let type = PDFSVGObj.int(dict, "PatternType") ?? 1
        if type == 2 {
            guard let shadingObject = PDFSVGObj.object(dict, "Shading"), let shading = PDFSVGObj.dictValue(shadingObject) else { return nil }
            return PDFSVGPatternUse(kind: .shading(shading), matrix: matrix, color: nil, content: CGPDFScannerGetContentStream(s))
        }
        guard let stream = PDFSVGObj.streamValue(object) else { return nil }
        var color: String?
        if PDFSVGObj.int(dict, "PaintType") == 2 {
            let space = underlying ?? .gray
            color = space.hex(Array(components.prefix(space.components)))
        }
        return PDFSVGPatternUse(kind: .tiling(stream), matrix: matrix, color: color, content: CGPDFScannerGetContentStream(s))
    }

    private func patternPaint(_ use: PDFSVGPatternUse, element: CGAffineTransform) -> String? {
        let toElement = use.matrix.concatenating(element.inverted())
        switch use.kind {
        case .shading(let shading):
            guard let (baseID, gradient) = gradientBase(shading, content: use.content) else { return "#808080" }
            let id = newID("g")
            defs += "<\(gradient.linear ? "linearGradient" : "radialGradient") id=\"\(id)\" xlink:href=\"#\(baseID)\" "
            defs += "gradientTransform=\"\(PDFSVGNumber.matrix(toElement))\"/>\n"
            return "url(#\(id))"
        case .tiling(let stream):
            guard let baseID = tilingBase(stream, color: use.color, content: use.content) else { return use.color ?? "#808080" }
            let id = newID("p")
            defs += "<pattern id=\"\(id)\" xlink:href=\"#\(baseID)\" patternTransform=\"\(PDFSVGNumber.matrix(toElement))\"/>\n"
            return "url(#\(id))"
        }
    }

    /// A gradient's stops and geometry, defined once per shading.
    private func gradientBase(_ shading: CGPDFDictionaryRef, content: CGPDFContentStreamRef) -> (String, PDFSVGGradient)? {
        let key = PDFSVGObj.key(shading)
        if let hit = gradients[key] { return hit }
        guard let g = PDFSVGGradient.make(shading, lookup: { Self.resource(in: content, "ColorSpace", $0) }) else {
            gradients[key] = .some(nil)
            return nil
        }
        let id = newID("g")
        let c = g.coords.map { PDFSVGNumber.format($0, 4) }
        if g.linear {
            defs += "<linearGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" x1=\"\(c[0])\" y1=\"\(c[1])\" x2=\"\(c[2])\" y2=\"\(c[3])\">"
        } else {
            // SVG's focal circle is PDF's start circle.
            defs += "<radialGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" fx=\"\(c[0])\" fy=\"\(c[1])\" fr=\"\(c[2])\" cx=\"\(c[3])\" cy=\"\(c[4])\" r=\"\(c[5])\">"
        }
        for stop in g.stops { defs += "<stop offset=\"\(PDFSVGNumber.format(stop.offset, 4))\" stop-color=\"\(stop.color)\"/>" }
        defs += g.linear ? "</linearGradient>\n" : "</radialGradient>\n"
        gradients[key] = (id, g)
        return (id, g)
    }

    /// A tiling pattern's cell, rendered once (per colour, for uncoloured patterns).
    private func tilingBase(_ stream: CGPDFStreamRef, color: String?, content parent: CGPDFContentStreamRef) -> String? {
        let key = "\(UInt(bitPattern: PDFSVGObj.key(stream)))-\(color ?? "")"
        if let hit = tilings[key] { return hit }
        guard let dict = CGPDFStreamGetDictionary(stream), let bbox = PDFSVGObj.rect(PDFSVGObj.array(dict, "BBox")),
              depth < 10 else { return nil }
        let xStep = PDFSVGObj.number(dict, "XStep") ?? bbox.width, yStep = PDFSVGObj.number(dict, "YStep") ?? bbox.height
        guard abs(xStep) > 1e-6, abs(yStep) > 1e-6 else { return nil }
        let id = newID("p")
        tilings[key] = id
        let saved = out, savedState = gs, savedStack = stack, savedForced = forcedColor, savedBase = patternBase
        let savedPath = (path, current, subpathStart, pendingClip, textMatrix, lineMatrix)
        defer { (path, current, subpathStart, pendingClip, textMatrix, lineMatrix) = savedPath }
        path = []
        pendingClip = nil
        out = ""
        stack = []
        gs = GState()
        gs.ctm = .identity
        patternBase = .identity
        forcedColor = color
        let resources = PDFSVGObj.dict(dict, "Resources")
        let content = CGPDFContentStreamCreateWithStream(stream, resources ?? pageResources, parent)
        depth += 1
        run(content)
        depth -= 1
        CGPDFContentStreamRelease(content)
        while !stack.isEmpty { pop() }
        closeGroups()
        let cell = out
        out = saved; gs = savedState; stack = savedStack; forcedColor = savedForced; patternBase = savedBase
        defs += "<pattern id=\"\(id)\" patternUnits=\"userSpaceOnUse\" x=\"\(PDFSVGNumber.format(bbox.minX))\" y=\"\(PDFSVGNumber.format(bbox.minY))\" "
        defs += "width=\"\(PDFSVGNumber.format(abs(xStep)))\" height=\"\(PDFSVGNumber.format(abs(yStep)))\">\n\(cell)</pattern>\n"
        return id
    }

    /// `sh`: paints a shading over the current clip.
    private func shade(_ s: CGPDFScannerRef, _ name: String) {
        guard visible, let object = Self.resource(s, "Shading", name), let shading = PDFSVGObj.dictValue(object),
              gs.ctm.pdfsvgScale > 1e-9 else { return }
        let viewport = CGRect(origin: .zero, size: size).applying(gs.ctm.inverted())
        guard let (baseID, g) = gradientBase(shading, content: CGPDFScannerGetContentStream(s)) else {
            rasterFallback()
            return
        }
        // Area to paint, in shading space: the visible page, or the band an axial shading covers when it
        // doesn't extend past its ends.
        var polygon: [CGPoint]
        if g.linear && !(g.extendStart && g.extendEnd) {
            let p0 = CGPoint(x: g.coords[0], y: g.coords[1]), p1 = CGPoint(x: g.coords[2], y: g.coords[3])
            let dx = p1.x - p0.x, dy = p1.y - p0.y
            let length = max(hypot(dx, dy), 1e-9)
            let big = (hypot(viewport.width, viewport.height) + abs(viewport.midX) + abs(viewport.midY)) * 4 / length + 2
            let n = CGPoint(x: -dy * big, y: dx * big)
            let t0: CGFloat = g.extendStart ? -big : 0, t1: CGFloat = g.extendEnd ? 1 + big : 1
            let a = CGPoint(x: p0.x + dx * t0, y: p0.y + dy * t0), b = CGPoint(x: p0.x + dx * t1, y: p0.y + dy * t1)
            polygon = [CGPoint(x: a.x + n.x, y: a.y + n.y), CGPoint(x: b.x + n.x, y: b.y + n.y),
                       CGPoint(x: b.x - n.x, y: b.y - n.y), CGPoint(x: a.x - n.x, y: a.y - n.y)]
        } else if !g.linear && !g.extendEnd {
            let r = max(g.coords[2], g.coords[5])
            let c = g.coords[5] >= g.coords[2] ? CGPoint(x: g.coords[3], y: g.coords[4]) : CGPoint(x: g.coords[0], y: g.coords[1])
            polygon = (0..<64).map { k in
                let t = CGFloat(k) / 64 * 2 * .pi
                return CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t))
            }
        } else {
            polygon = [viewport.origin, CGPoint(x: viewport.maxX, y: viewport.minY),
                       CGPoint(x: viewport.maxX, y: viewport.maxY), CGPoint(x: viewport.minX, y: viewport.maxY)]
        }
        if let bbox = g.bbox { push(); clipRect(bbox, ctm: gs.ctm) }
        let d = "M" + polygon.map { "\(PDFSVGNumber.format($0.x, 4)) \(PDFSVGNumber.format($0.y, 4))" }.joined(separator: "L") + "Z"
        var attrs = "d=\"\(d)\" fill=\"url(#\(baseID))\" transform=\"\(PDFSVGNumber.matrix(gs.ctm))\""
        if gs.fillAlpha < 1 { attrs += " fill-opacity=\"\(PDFSVGNumber.format(gs.fillAlpha))\"" }
        if let blend = gs.blend { attrs += " style=\"mix-blend-mode:\(blend)\"" }
        out += "<path \(attrs)/>\n"
        if g.bbox != nil { pop() }
    }

    /// For shadings SVG can't express (meshes, function-based): the page rendered by Quartz, shown
    /// through the current clip.
    private func rasterFallback() {
        if pageRaster == nil, let image = PDFTools.render(page, dpi: 150),
           let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            let id = newID("r")
            defs += "<image id=\"\(id)\" width=\"\(PDFSVGNumber.format(size.width))\" height=\"\(PDFSVGNumber.format(size.height))\" "
            defs += "preserveAspectRatio=\"none\" xlink:href=\"data:image/png;base64,\(data.base64EncodedString())\"/>\n"
            pageRaster = id
        }
        if let id = pageRaster { out += "<use xlink:href=\"#\(id)\"/>\n" }
    }

    // MARK: XObjects

    private func doXObject(_ s: CGPDFScannerRef, _ name: String) {
        guard let object = Self.resource(s, "XObject", name), let stream = PDFSVGObj.streamValue(object),
              let dict = CGPDFStreamGetDictionary(stream) else { return }
        if let oc = PDFSVGObj.dict(dict, "OC"), isHidden(oc) { return }
        switch PDFSVGObj.name(dict, "Subtype") {
        case "Image": drawImage(stream, scanner: s, inline: false)
        case "Form": drawForm(stream, scanner: s)
        default: break
        }
    }

    /// A form XObject: its matrix and bounding box applied, its content run in a saved state.
    private func drawForm(_ stream: CGPDFStreamRef, scanner: CGPDFScannerRef?, groupOpacity: Bool = true) {
        guard depth < 16, visible, let dict = CGPDFStreamGetDictionary(stream) else { return }
        push()
        gs.ctm = (PDFSVGObj.matrix(PDFSVGObj.array(dict, "Matrix")) ?? .identity).concatenating(gs.ctm)
        if let bbox = PDFSVGObj.rect(PDFSVGObj.array(dict, "BBox")) { clipRect(bbox, ctm: gs.ctm) }
        // A transparency group with group opacity: fade the group as a whole.
        if groupOpacity, PDFSVGObj.dict(dict, "Group") != nil, gs.fillAlpha < 1 || gs.blend != nil {
            var attrs = ""
            if gs.fillAlpha < 1 { attrs += " opacity=\"\(PDFSVGNumber.format(gs.fillAlpha))\"" }
            if let blend = gs.blend { attrs += " style=\"mix-blend-mode:\(blend)\"" }
            out += "<g\(attrs)>\n"
            gs.groups += 1
            gs.fillAlpha = 1; gs.strokeAlpha = 1; gs.blend = nil
        }
        runForm(stream, scanner: scanner)
        pop()
    }

    /// Runs a form's content with its resources, in the current state.
    private func runForm(_ stream: CGPDFStreamRef, scanner: CGPDFScannerRef?) {
        let key = PDFSVGObj.key(stream)
        guard !running.contains(key), depth < 16, let dict = CGPDFStreamGetDictionary(stream) else { return }
        running.insert(key)
        depth += 1
        let savedBase = patternBase, savedText = (textMatrix, lineMatrix)
        patternBase = gs.ctm
        let content = CGPDFContentStreamCreateWithStream(stream, PDFSVGObj.dict(dict, "Resources") ?? pageResources,
                                                         scanner.map { CGPDFScannerGetContentStream($0) } ?? pageContent)
        run(content)
        CGPDFContentStreamRelease(content)
        patternBase = savedBase
        (textMatrix, lineMatrix) = savedText
        depth -= 1
        running.remove(key)
    }

    private func drawImage(_ stream: CGPDFStreamRef, scanner: CGPDFScannerRef, inline: Bool) {
        guard visible, gs.ctm.pdfsvgScale > 1e-9 else { return }
        let dict = CGPDFStreamGetDictionary(stream)
        let stencil = PDFSVGObj.bool(dict, "ImageMask", "IM") ?? false
        var fill: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        if stencil {
            if case .none = gs.fill { return }
            if case .color = gs.fill { fill = gs.fillSpace.rgb(gs.fillComponents) }
            if let forcedColor, let c = NSColor(hex: forcedColor) { fill = (c.redComponent, c.greenComponent, c.blueComponent) }
        }
        let key = inline ? "" : "\(UInt(bitPattern: PDFSVGObj.key(stream)))\(stencil ? "-\(fill)" : "")"
        var id = inline ? nil : images[key]
        if id == nil {
            let lookup: (String) -> CGPDFObjectRef? = { Self.resource(scanner, "ColorSpace", $0) }
            guard let encoded = PDFSVGImage.encode(stream, inline: inline,
                                                   spaces: { PDFSVGColorSpace.parse($0, lookup: lookup) },
                                                   fill: fill, mode: settings.images) else { return }
            let newImage = newID("i")
            var maskAttr = ""
            if let mask = encoded.maskHref {
                let maskID = newID("m")
                defs += "<mask id=\"\(maskID)\" maskUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"1\" height=\"1\">"
                defs += "<image width=\"1\" height=\"1\" preserveAspectRatio=\"none\" xlink:href=\"\(mask)\"/></mask>\n"
                maskAttr = " mask=\"url(#\(maskID))\""
            }
            defs += "<image id=\"\(newImage)\" width=\"1\" height=\"1\" preserveAspectRatio=\"none\"\(maskAttr) xlink:href=\"\(encoded.href)\"/>\n"
            if !inline { images[key] = newImage }
            id = newImage
        }
        guard let id else { return }
        // Image space: the unit square with its first row at the top.
        let m = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1).concatenating(gs.ctm)
        var attrs = "xlink:href=\"#\(id)\" transform=\"\(PDFSVGNumber.matrix(m))\""
        if gs.fillAlpha < 1 { attrs += " opacity=\"\(PDFSVGNumber.format(gs.fillAlpha))\"" }
        if let blend = gs.blend { attrs += " style=\"mix-blend-mode:\(blend)\"" }
        out += "<use \(attrs)/>\n"
    }

    // MARK: Optional content

    private func isHidden(_ oc: CGPDFDictionaryRef) -> Bool {
        if hiddenLayers.contains(PDFSVGObj.key(oc)) { return true }
        if PDFSVGObj.name(oc, "Type") == "OCMD" {
            var groups: [CGPDFDictionaryRef] = []
            if let d = PDFSVGObj.dict(oc, "OCGs") { groups = [d] }
            if let a = PDFSVGObj.array(oc, "OCGs") {
                for i in 0..<CGPDFArrayGetCount(a) {
                    var d: CGPDFDictionaryRef?
                    if CGPDFArrayGetDictionary(a, i, &d), let d { groups.append(d) }
                }
            }
            guard !groups.isEmpty else { return false }
            let off = groups.map { hiddenLayers.contains(PDFSVGObj.key($0)) }
            switch PDFSVGObj.name(oc, "P") ?? "AnyOn" {
            case "AllOn": return off.contains(true)
            case "AnyOff": return off.contains(true)
            case "AllOff": return !off.contains(true)
            default: return !off.contains(false)
            }
        }
        return false
    }

    private func beginMarked(_ s: CGPDFScannerRef, _ ops: [Operand]) {
        var hide = false
        if ops.first?.name == "OC", ops.count >= 2 {
            var props: CGPDFDictionaryRef?
            if let n = ops[1].name, let o = Self.resource(s, "Properties", n) { props = PDFSVGObj.dictValue(o) }
            if case .dictionary(let d) = ops[1] { props = d }
            if let props { hide = isHidden(props) }
        }
        marked.append(hide)
        if hide { hiddenDepth += 1 }
    }

    // MARK: Text

    private func font(for dict: CGPDFDictionaryRef) -> PDFSVGFont {
        let key = PDFSVGObj.key(dict)
        if let hit = fonts[key] { return hit }
        let f = PDFSVGFont(dict)
        fonts[key] = f
        return f
    }

    private func setFont(_ s: CGPDFScannerRef, _ ops: [Operand]) {
        guard ops.count >= 2 else { return }
        if let size = ops.last?.number { gs.fontSize = size }
        if let name = ops[ops.count - 2].name, let object = Self.resource(s, "Font", name), let dict = PDFSVGObj.dictValue(object) {
            gs.font = font(for: dict)
        }
    }

    private func moveText(_ tx: CGFloat, _ ty: CGFloat) {
        lineMatrix = CGAffineTransform(translationX: tx, y: ty).concatenating(lineMatrix)
        textMatrix = lineMatrix
    }

    private func nextLine() { moveText(0, -gs.leading) }

    private func cssClass(for font: PDFSVGFont) -> String {
        let key = Unmanaged.passUnretained(font).toOpaque()
        if let hit = fontClasses[UnsafeRawPointer(key)] { return hit }
        let name = "f\(fontClasses.count + 1)"
        fontClasses[UnsafeRawPointer(key)] = name
        styles += ".\(name){\(font.css)}"
        return name
    }

    /// Tj, TJ, ' and ": positions every glyph, advances the text matrix and writes one `<text>`.
    private func show(_ scanner: CGPDFScannerRef, _ items: [Operand]) {
        let font = gs.font ?? fallbackFont
        let fs = gs.fontSize, th = gs.hScale
        let start = textMatrix
        var x: CGFloat = 0, y: CGFloat = 0
        var placed: [(x: CGFloat, y: CGFloat, text: String)] = []
        var type3: [(code: UInt32, x: CGFloat, y: CGFloat)] = []
        for item in items {
            switch item {
            case .number(let n):
                let shift = -n / 1000 * fs
                if font.vertical { y += shift } else {
                    // A wide gap stands for a space in text that has none, so copied text keeps its words apart.
                    if n <= -250, let last = placed.last, last.text != " ", !last.text.isEmpty {
                        placed.append((x, y, " "))
                    }
                    x += shift * th
                }
            case .string(let bytes):
                for g in font.glyphs(bytes) {
                    if font.isType3 { type3.append((g.code, x, y)) }
                    let advance = g.width * fs + gs.charSpacing + (g.isSpace ? gs.wordSpacing : 0)
                    let chars = Array(g.text)
                    if chars.count > 1 {
                        for (k, ch) in chars.enumerated() {
                            let f = CGFloat(k) / CGFloat(chars.count)
                            placed.append(font.vertical ? (x, y + advance * f, String(ch)) : (x + advance * th * f, y, String(ch)))
                        }
                    } else {
                        placed.append((x, y, g.text))
                    }
                    if font.vertical { y += advance } else { x += advance * th }
                }
            default:
                break
            }
        }
        textMatrix = CGAffineTransform(translationX: x, y: y).concatenating(start)
        guard visible, fs != 0, th != 0 else { return }

        if font.isType3 { drawType3(font, glyphs: type3, start: start, scanner: scanner) }

        let m = start.concatenating(gs.ctm)
        let q = hypot(m.c, m.d)
        guard q > 1e-9 else { return }
        let sign: CGFloat = fs < 0 ? -1 : 1
        let fontSize = abs(fs) * q
        let a = CGAffineTransform(a: sign * th / q, b: 0, c: 0, d: -sign / q, tx: 0, ty: 0)
        // No Unicode for these codes (for example a CJK font without a ToUnicode map): ask PDFKit,
        // whose text extraction knows the standard character collections, for the text under the run.
        if !placed.isEmpty, placed.allSatisfy({ $0.text.isEmpty || $0.text == " " }), let textUnder,
           let found = textUnder(runRect(placed, end: CGPoint(x: x, y: y), start: start, fontSize: fs, vertical: font.vertical)) {
            let chars = Array(found.filter { !$0.isNewline })
            let slots = placed.indices.filter { placed[$0].text.isEmpty }
            if !chars.isEmpty && !slots.isEmpty {
                for (k, ch) in chars.enumerated() {
                    let slot = slots[min(slots.count - 1, k * slots.count / chars.count)]
                    if chars.count == slots.count || placed[slot].text.isEmpty {
                        placed[slot].text = String(ch)
                    } else {
                        placed.append((placed[slot].x, placed[slot].y, String(ch)))
                    }
                }
            }
        }
        var glyphs = placed.compactMap { g -> (x: CGFloat, y: CGFloat, text: String)? in
            let clean = PDFSVGRenderer.xmlText(g.text)
            return clean.isEmpty ? nil : (g.x * q / (sign * th), -(g.y + gs.rise) * q / sign, clean)
        }
        // Runs of nothing but spaces draw nothing (some generators pad every line to the page width).
        guard glyphs.contains(where: { $0.text != " " }) else { return }
        // A plain translation goes into the positions instead of a transform.
        var t = a.concatenating(m)
        if abs(t.a - 1) < 1e-9 && abs(t.b) < 1e-9 && abs(t.c) < 1e-9 && abs(t.d - 1) < 1e-9 {
            glyphs = glyphs.map { ($0.x + t.tx, $0.y + t.ty, $0.text) }
            t = .identity
        }

        var mode = gs.renderMode % 4
        if gs.renderMode == 7 || font.isType3 { mode = 3 }
        var attrs = "class=\"\(cssClass(for: font))\" font-size=\"\(PDFSVGNumber.format(fontSize, 3))\""
        if t.a != 1 || t.b != 0 || t.c != 0 || t.d != 1 || t.tx != 0 || t.ty != 0 { attrs += " transform=\"\(PDFSVGNumber.matrix(t))\"" }
        let fillPaint = paintAttribute(gs.fill, space: gs.fillSpace, element: t)
        switch mode {
        case 1, 2:
            if mode == 1 { attrs += " fill=\"none\"" }
            else if let fillPaint {
                if fillPaint != "#000000" { attrs += " fill=\"\(fillPaint)\"" }
                if gs.fillAlpha < 1 { attrs += " fill-opacity=\"\(PDFSVGNumber.format(gs.fillAlpha))\"" }
            }
            if let strokePaint = paintAttribute(gs.stroke, space: gs.strokeSpace, element: t) {
                // Line width is in user space; one SVG unit here is 1/q of text space.
                let width = gs.lineWidth > 0 ? gs.lineWidth * q / max(start.pdfsvgScale, 1e-9) : 0.5 / max(t.pdfsvgScale, 1e-9)
                attrs += " stroke=\"\(strokePaint)\" stroke-width=\"\(PDFSVGNumber.format(width, 4))\""
                if gs.strokeAlpha < 1 { attrs += " stroke-opacity=\"\(PDFSVGNumber.format(gs.strokeAlpha))\"" }
            }
        case 3:
            attrs += " fill-opacity=\"0\""
        default:
            if let fillPaint {
                if fillPaint != "#000000" { attrs += " fill=\"\(fillPaint)\"" }
                if gs.fillAlpha < 1 { attrs += " fill-opacity=\"\(PDFSVGNumber.format(gs.fillAlpha))\"" }
            } else {
                attrs += " fill=\"none\""
            }
        }
        if let blend = gs.blend { attrs += " style=\"mix-blend-mode:\(blend)\"" }
        let ys = Set(glyphs.map { PDFSVGNumber.format($0.y, 3) })
        let xList = glyphs.map { PDFSVGNumber.format($0.x, 3) }.joined(separator: " ")
        let yList = ys.count == 1 ? ys.first! : glyphs.map { PDFSVGNumber.format($0.y, 3) }.joined(separator: " ")
        out += "<text \(attrs) x=\"\(xList)\" y=\"\(yList)\">\(glyphs.map(\.text).joined())</text>\n"
        textRuns += 1
        if (4...7).contains(gs.renderMode), !textClips.isEmpty {
            var clip = "<text class=\"\(cssClass(for: font))\" font-size=\"\(PDFSVGNumber.format(fontSize, 3))\""
            if t.a != 1 || t.b != 0 || t.c != 0 || t.d != 1 || t.tx != 0 || t.ty != 0 { clip += " transform=\"\(PDFSVGNumber.matrix(t))\"" }
            clip += " x=\"\(xList)\" y=\"\(yList)\">\(glyphs.map(\.text).joined())</text>"
            textClips[textClips.count - 1].append(clip)
        }
    }

    /// ET: text shown in a clipping mode since BT now clips what follows, until the next Q.
    private func endText() {
        guard let clips = textClips.popLast(), !clips.isEmpty else { return }
        let id = newID("c")
        defs += "<clipPath id=\"\(id)\" clipPathUnits=\"userSpaceOnUse\">\n" + clips.joined(separator: "\n") + "\n</clipPath>\n"
        out += "<g clip-path=\"url(#\(id))\">\n"
        gs.groups += 1
    }

    /// A band through the middle of a text run, in the page's own (PDF) coordinates.
    private func runRect(_ placed: [(x: CGFloat, y: CGFloat, text: String)], end: CGPoint, start: CGAffineTransform,
                         fontSize fs: CGFloat, vertical: Bool) -> CGRect {
        let toPage = start.concatenating(gs.ctm).concatenating(base.inverted())
        let first = placed.first.map { CGPoint(x: $0.x, y: $0.y) } ?? .zero
        let corners: [CGPoint]
        if vertical {
            let x0 = -0.25 * abs(fs), x1 = 0.25 * abs(fs)
            corners = [CGPoint(x: x0, y: first.y), CGPoint(x: x1, y: first.y), CGPoint(x: x0, y: end.y), CGPoint(x: x1, y: end.y)]
        } else {
            let inset = (end.x - first.x) / CGFloat(max(placed.count, 1)) * 0.25
            let y0 = gs.rise + 0.2 * fs, y1 = gs.rise + 0.5 * fs
            corners = [CGPoint(x: first.x + inset, y: y0), CGPoint(x: end.x - inset, y: y0),
                       CGPoint(x: first.x + inset, y: y1), CGPoint(x: end.x - inset, y: y1)]
        }
        let mapped = corners.map { $0.applying(toPage) }
        let xs = mapped.map(\.x), ys = mapped.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Type 3 glyphs are little content streams: run each one at its position.
    private func drawType3(_ font: PDFSVGFont, glyphs: [(code: UInt32, x: CGFloat, y: CGFloat)], start: CGAffineTransform,
                           scanner: CGPDFScannerRef) {
        guard depth < 12 else { return }
        let size = CGAffineTransform(a: gs.fontSize * gs.hScale, b: 0, c: 0, d: gs.fontSize, tx: 0, ty: gs.rise)
        for g in glyphs {
            guard let proc = font.charProc(g.code) else { continue }
            let key = PDFSVGObj.key(proc)
            guard !running.contains(key) else { continue }
            push()
            gs.ctm = font.fontMatrix.concatenating(size).concatenating(CGAffineTransform(translationX: g.x, y: g.y))
                .concatenating(start).concatenating(gs.ctm)
            let saved = (textMatrix, lineMatrix)
            running.insert(key)
            depth += 1
            let content = CGPDFContentStreamCreateWithStream(proc, font.resources ?? pageResources, CGPDFScannerGetContentStream(scanner))
            run(content)
            CGPDFContentStreamRelease(content)
            depth -= 1
            running.remove(key)
            (textMatrix, lineMatrix) = saved
            pop()
        }
    }

    /// XML-escaped text with characters XML can't hold removed.
    static func xmlText(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out += " "
            default:
                let v = scalar.value
                if v < 0x20 || (0xFFFE...0xFFFF).contains(v) || (0xD800...0xDFFF).contains(v) { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func xmlAttribute(_ s: String) -> String { xmlText(s).replacingOccurrences(of: "'", with: "&apos;") }

    // MARK: Annotations

    /// Annotation appearances (form fields, stamps, notes as printed) and clickable web links.
    private func drawAnnotations() {
        guard let annots = PDFSVGObj.array(page.dictionary, "Annots") else { return }
        for i in 0..<CGPDFArrayGetCount(annots) {
            var a: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annots, i, &a), let a, let rect = PDFSVGObj.rect(PDFSVGObj.array(a, "Rect")) else { continue }
            let flags = PDFSVGObj.int(a, "F") ?? 0
            let subtype = PDFSVGObj.name(a, "Subtype") ?? ""
            if flags & 2 != 0 || flags & 32 != 0 || subtype == "Popup" { continue }
            if let oc = PDFSVGObj.dict(a, "OC"), isHidden(oc) { continue }
            if subtype == "Link" {
                if let action = PDFSVGObj.dict(a, "A"), PDFSVGObj.name(action, "S") == "URI",
                   let uri = PDFSVGObj.text(action, "URI") ?? PDFSVGObj.text(action, "URI"),
                   ["http:", "https:", "mailto:"].contains(where: { uri.lowercased().hasPrefix($0) }) {
                    let box = rect.applying(base)
                    out += "<a xlink:href=\"\(Self.xmlAttribute(uri))\"><rect x=\"\(PDFSVGNumber.format(box.minX))\" y=\"\(PDFSVGNumber.format(box.minY))\" "
                    out += "width=\"\(PDFSVGNumber.format(box.width))\" height=\"\(PDFSVGNumber.format(box.height))\" fill=\"#FFFFFF\" fill-opacity=\"0\"/></a>\n"
                }
                continue
            }
            guard let ap = PDFSVGObj.dict(a, "AP") else { continue }
            var appearance = PDFSVGObj.stream(ap, "N")
            if appearance == nil, let states = PDFSVGObj.dict(ap, "N"), let state = PDFSVGObj.name(a, "AS") {
                appearance = PDFSVGObj.stream(states, state)
            }
            guard let appearance, let ad = CGPDFStreamGetDictionary(appearance),
                  let bbox = PDFSVGObj.rect(PDFSVGObj.array(ad, "BBox")), bbox.width > 0, bbox.height > 0 else { continue }
            // Map the appearance's transformed box onto the annotation rectangle (PDF 32000 12.5.5).
            let matrix = PDFSVGObj.matrix(PDFSVGObj.array(ad, "Matrix")) ?? .identity
            let box = bbox.applying(matrix)
            guard box.width > 0, box.height > 0 else { continue }
            let fit = CGAffineTransform(translationX: -box.minX, y: -box.minY)
                .concatenating(CGAffineTransform(scaleX: rect.width / box.width, y: rect.height / box.height))
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
            gs = GState()
            gs.ctm = fit.concatenating(base)
            stack = []
            patternBase = gs.ctm
            push()
            gs.ctm = (PDFSVGObj.matrix(PDFSVGObj.array(ad, "Matrix")) ?? .identity).concatenating(gs.ctm)
            clipRect(bbox, ctm: gs.ctm)
            let key = PDFSVGObj.key(appearance)
            depth += 1
            running.insert(key)
            let content = CGPDFContentStreamCreateWithStream(appearance, PDFSVGObj.dict(ad, "Resources") ?? pageResources, pageContent)
            run(content)
            CGPDFContentStreamRelease(content)
            running.remove(key)
            depth -= 1
            while !stack.isEmpty { pop() }
            closeGroups()
        }
    }
}

/// A pattern chosen as a fill or stroke colour, with the matrix from pattern space to the SVG page.
/// It keeps the content stream it came from, whose resources its cell or colour space may need.
final class PDFSVGPatternUse {
    enum Kind { case shading(CGPDFDictionaryRef), tiling(CGPDFStreamRef) }
    let kind: Kind
    let matrix: CGAffineTransform
    /// Uncoloured tiling patterns: the colour they paint in.
    let color: String?
    let content: CGPDFContentStreamRef

    init(kind: Kind, matrix: CGAffineTransform, color: String?, content: CGPDFContentStreamRef) {
        self.kind = kind
        self.matrix = matrix
        self.color = color
        self.content = CGPDFContentStreamRetain(content)
    }

    deinit { CGPDFContentStreamRelease(content) }
}
