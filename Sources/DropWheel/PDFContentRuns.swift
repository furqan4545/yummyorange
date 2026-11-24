import CoreGraphics
import Foundation

// The content side of Edit PDF: a content-stream interpreter that keeps byte ranges (which stream, which
// operator, which string), the text state of every shown string, glyph quads in page space, marked content
// (MCID, ActualText) and form XObjects, then groups the shown strings into lines in reading order.

/// One decoded content stream of a page: a /Contents stream or a form XObject it draws.
struct PDFContentStream {
    let objectNumber: Int
    let dict: PDFDict
    let data: [UInt8]
    let resources: PDFDict
    /// nil for page content.
    let form: Form?

    struct Form {
        /// The XObject name it was drawn under, in the stream that drew it.
        let name: String
        let parent: Int
        let depth: Int
        /// The form has its own /Resources (inline in its dictionary or an object).
        let ownResources: Bool
        let resourcesObject: Int?
    }

    var isForm: Bool { form != nil }
}

/// A glyph of a shown string. Positions are in text space (font size and horizontal scaling applied), from the
/// start of the show operator.
struct PDFGlyph {
    let element: Int
    let index: Int
    let code: UInt32
    let bytes: [UInt8]
    var text: String
    let x0: Double
    let width: Double
    let advance: Double
    let isSpace: Bool
}

/// One show operator (Tj, TJ, ' or ") and its text state.
struct PDFTextRun {
    let index: Int
    let stream: Int
    let op: String
    /// First operand … end of the operator, in the decoded stream.
    let opRange: Range<Int>
    let operands: [(value: PDFValue, range: Range<Int>)]
    /// TJ array elements, or the one string of Tj ' ".
    let elements: [(value: PDFValue, range: Range<Int>)]
    let fontName: String
    let fontKey: String
    let fontSize: Double
    let fontSizeText: String
    /// The text matrix when the first glyph is shown (after the line move of ' and ").
    let textMatrix: CGAffineTransform
    let ctm: CGAffineTransform
    let hScale: Double
    let charSpacing: Double
    let wordSpacing: Double
    let rise: Double
    let renderMode: Int
    let fill: [Double]
    var glyphs: [PDFGlyph]
    /// Total horizontal displacement in text space.
    let endX: Double
    let mcid: Int?
    let actualText: ActualText?
    /// Serial number of the BT … ET block.
    let textObject: Int
    /// The font came from an ExtGState /Font entry, not a Tf: there is no resource name to switch back to.
    let fontFromGState: Bool

    struct ActualText {
        let stream: Int
        /// The string token inside the BDC's property dictionary.
        let range: Range<Int>
        let bytes: [UInt8]
        let hex: Bool
        /// The BDC operator's own range (to tell spans apart).
        let bdcRange: Range<Int>
    }

    var text: String { glyphs.map(\.text).joined() }
    /// Text space → page space.
    var trm: CGAffineTransform { textMatrix.concatenating(ctm) }

    /// The four corners (bottom-left, bottom-right, top-right, top-left) of glyphs `from..<to` in page space.
    func quad(from: Int, to: Int, ascent: Double, descent: Double) -> [CGPoint] {
        guard !glyphs.isEmpty, from < to, from < glyphs.count else { return [] }
        let a = glyphs[max(0, from)].x0
        let last = glyphs[min(glyphs.count, to) - 1]
        let z = last.x0 + last.width
        return PDFTextRun.corners(x0: a, x1: z, lo: rise + descent * fontSize, hi: rise + ascent * fontSize, m: trm)
    }

    static func corners(x0: Double, x1: Double, lo: Double, hi: Double, m: CGAffineTransform) -> [CGPoint] {
        [CGPoint(x: x0, y: lo), CGPoint(x: x1, y: lo), CGPoint(x: x1, y: hi), CGPoint(x: x0, y: hi)].map { $0.applying(m) }
    }
}

/// A placed image (scanned pages are one big image).
struct PDFImagePlacement {
    let quad: [CGPoint]
    let objectNumber: Int?
    var bounds: CGRect { PDFEditGeometry.bounds(quad) }
}

/// A line the user edits: neighbouring shown strings on one baseline, in one stream.
struct PDFTextLine {
    /// Index in `PDFPageContent.lines` (reading order).
    let index: Int
    let runs: [Int]
    let text: String
    /// The line's characters: each from a glyph (run, glyph) or a gap shown as a space.
    let units: [Unit]
    let quad: [CGPoint]
    /// Baseline start in page space.
    let origin: CGPoint
    /// Unit vector of the baseline in page space.
    let direction: CGVector
    /// Degrees counter-clockwise in page space.
    let angle: Double
    /// Font size in page points (Tf × text matrix × CTM).
    let pointSize: Double
    let stream: Int
    let hidden: Bool

    struct Unit {
        let run: Int?
        let glyph: Int?
        let text: String
    }

    var bounds: CGRect { PDFEditGeometry.bounds(quad) }
}

enum PDFEditGeometry {
    static func bounds(_ quad: [CGPoint]) -> CGRect {
        guard let f = quad.first else { return .null }
        var r = CGRect(origin: f, size: .zero)
        for p in quad.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    /// Page space → the upright page as shown (crop box at the origin, /Rotate applied), the same mapping
    /// `PDFArchive.pageTransform` gets from Core Graphics.
    static func uprightTransform(crop c: CGRect, rotate: Int) -> CGAffineTransform {
        switch ((rotate % 360) + 360) % 360 {
        case 90: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -c.minY, ty: c.maxX)
        case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: c.maxX, ty: c.maxY)
        case 270: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: c.maxY, ty: -c.minX)
        default: return CGAffineTransform(translationX: -c.minX, y: -c.minY)
        }
    }
}

// MARK: - Content tokens

/// Content-stream syntax: values with ranges, operators, and inline images skipped.
struct PDFContentScanner {
    enum Item {
        case operand(PDFValue, Range<Int>, elements: [(value: PDFValue, range: Range<Int>)]?)
        case op(String, Range<Int>)
    }

    var lx: PDFLexer

    /// Elements kept per array. A TJ array of millions of entries, from a small compressed stream, would
    /// otherwise hold gigabytes; past this the rest of the array is read and dropped, and `truncated` is set.
    static var maxArrayElements = 100_000
    private(set) var truncated = false
    /// Array elements read so far (kept or not), for the page's budget.
    private(set) var elementsRead = 0

    init(_ data: [UInt8]) { lx = PDFLexer(data, at: 0) }

    mutating func next() -> Item? {
        while true {
            let (t, r) = lx.next()
            switch t {
            case .eof: return nil
            case .keyword(let w):
                if w == "BI" { skipInlineImage(); return .op("BI", r.lowerBound..<lx.p) }
                if w == "true" { return .operand(.bool(true), r, elements: nil) }
                if w == "false" { return .operand(.bool(false), r, elements: nil) }
                if w == "null" { return .operand(.null, r, elements: nil) }
                if w == "{" || w == "}" || w == ")" || w == ">" { continue }
                return .op(w, r)
            case .arrayOpen:
                var elems: [(PDFValue, Range<Int>)] = []
                while true {
                    let (et, er) = lx.next()
                    if case .arrayClose = et { break }
                    if case .eof = et { break }
                    if case .keyword = et { continue }
                    guard let v = lx.value(after: et, refs: false) else { continue }
                    elementsRead += 1
                    if elems.count >= PDFContentScanner.maxArrayElements { truncated = true; continue }
                    elems.append((v, er.lowerBound..<lx.p))
                }
                return .operand(.array(elems.map(\.0)), r.lowerBound..<lx.p, elements: elems.map { (value: $0.0, range: $0.1) })
            case .arrayClose, .dictClose:
                continue
            default:
                guard let v = lx.value(after: t, refs: false) else { continue }
                return .operand(v, r.lowerBound..<lx.p, elements: nil)
            }
        }
    }

    /// BI <key value pairs> ID <data> EI. Image data is binary and can itself contain " EI ", so the end is found
    /// from the data's length when the dictionary gives it (/L, or /W /H /BPC /CS with no filter); otherwise at an
    /// "EI" between whitespace that is followed by content-stream text rather than more binary data.
    private mutating func skipInlineImage() {
        let b = lx.b
        var params = PDFDict()
        while true {
            let (t, _) = lx.next()
            if case .eof = t { return }
            if case .keyword("ID") = t { break }
            if case .name(let key) = t {
                let (vt, _) = lx.next()
                if case .keyword("ID") = vt { break }
                if let v = lx.value(after: vt, refs: false) { params[key] = v }
            }
        }
        let dataStart = lx.p + 1
        /// "EI" (after optional whitespace) right at `end`.
        func endsWithEI(at end: Int) -> Int? {
            var k = end
            while k < b.count, PDFLexer.isWhite(b[k]) { k += 1 }
            guard k + 1 < b.count, b[k] == 69, b[k + 1] == 73, k + 2 >= b.count || PDFLexer.isWhite(b[k + 2]) || PDFLexer.isDelimiter(b[k + 2]) else { return nil }
            return k + 2
        }
        if let length = PDFContentScanner.inlineDataLength(params), length >= 0, dataStart + length <= b.count,
           let after = endsWithEI(at: dataStart + length) {
            lx.p = after
            return
        }
        var k = dataStart
        var firstCandidate: Int?
        while k + 1 < b.count {
            if b[k] == 69, b[k + 1] == 73, k > dataStart, PDFLexer.isWhite(b[k - 1]), k + 2 >= b.count || PDFLexer.isWhite(b[k + 2]) {
                if PDFContentScanner.looksLikeContent(b, from: k + 2) { lx.p = k + 2; return }
                if firstCandidate == nil { firstCandidate = k + 2 }
            }
            k += 1
        }
        lx.p = firstCandidate ?? b.count
    }

    /// The byte count of inline image data, when its dictionary says it: /L (PDF 2.0), or the size of unfiltered
    /// samples.
    static func inlineDataLength(_ d: PDFDict) -> Int? {
        if let l = (d["L"] ?? d["Length"])?.int { return l }
        if d["F"] != nil || d["Filter"] != nil { return nil }
        guard let w = (d["W"] ?? d["Width"])?.int, let h = (d["H"] ?? d["Height"])?.int, w > 0, h > 0, w < 1 << 20, h < 1 << 20 else { return nil }
        let mask = (d["IM"] ?? d["ImageMask"]).map { if case .bool(true) = $0 { return true }; return false } ?? false
        let bpc = mask ? 1 : ((d["BPC"] ?? d["BitsPerComponent"])?.int ?? 8)
        guard [1, 2, 4, 8, 16].contains(bpc) else { return nil }
        let comps: Int
        if mask { comps = 1 } else {
            switch (d["CS"] ?? d["ColorSpace"])?.name {
            case "G"?, "DeviceGray"?, "I"?, "Indexed"?: comps = 1
            case "RGB"?, "DeviceRGB"?: comps = 3
            case "CMYK"?, "DeviceCMYK"?: comps = 4
            default:
                if case .array(let a)? = d["CS"] ?? d["ColorSpace"], ["I", "Indexed"].contains(a.first?.name ?? "") { comps = 1 } else { return nil }
            }
        }
        return h * ((w * comps * bpc + 7) / 8)
    }

    /// After a candidate "EI": the next bytes are content-stream text (or the end), not more binary image data.
    /// The check stops at the first string, whose bytes may be anything.
    static func looksLikeContent(_ b: [UInt8], from: Int) -> Bool {
        var k = from
        let end = min(b.count, from + 48)
        while k < end {
            let c = b[k]
            if c == 40 || c == 60 { return true }
            if !(c == 9 || c == 10 || c == 12 || c == 13 || (0x20...0x7E).contains(c)) { return false }
            k += 1
        }
        return true
    }
}

// MARK: - The interpreter

/// Everything Edit PDF knows about one page's content.
final class PDFPageContent {
    let file: PDFObjectFile
    let page: PDFObjectFile.Page
    let fonts: PDFEditFontCache
    private(set) var streams: [PDFContentStream] = []
    private(set) var runs: [PDFTextRun] = []
    private(set) var lines: [PDFTextLine] = []
    private(set) var images: [PDFImagePlacement] = []
    /// q operators left open by the page's content streams.
    private(set) var unbalancedSaves = 0
    /// Why some content couldn't be read (an unsupported filter, say).
    private(set) var problems: [String] = []
    /// Forms drawn on this page: object number → number of times.
    private(set) var formUses: [Int: Int] = [:]

    /// Text under a page-space rectangle (PDFKit), for fonts with no Unicode mapping.
    var textUnder: ((CGRect) -> String?)?
    private var textUnderLookups = 0

    init(file: PDFObjectFile, page: PDFObjectFile.Page, fonts: PDFEditFontCache, textUnder: ((CGRect) -> String?)? = nil) {
        self.file = file
        self.page = page
        self.fonts = fonts
        self.textUnder = textUnder
        for n in page.contents {
            guard let o = file.object(n), let d = o.value.dict, o.stream != nil else { continue }
            do {
                let data = try file.decodedStream(n) ?? []
                streams.append(PDFContentStream(objectNumber: n, dict: d, data: data, resources: page.resources, form: nil))
            } catch {
                problems.append(error.localizedDescription)
                streams.append(PDFContentStream(objectNumber: n, dict: d, data: [], resources: page.resources, form: nil))
            }
        }
        interpret()
        buildLines()
    }

    func font(of run: PDFTextRun) -> PDFEditFont? { fonts.font(key: run.fontKey) }

    func quad(_ run: PDFTextRun, from: Int = 0, to: Int? = nil) -> [CGPoint] {
        let f = font(of: run)
        return run.quad(from: from, to: to ?? run.glyphs.count, ascent: f?.ascent ?? 0.8, descent: f?.descent ?? -0.2)
    }

    // MARK: Interpreting

    private struct State {
        var ctm = CGAffineTransform.identity
        var font = ""
        var fontKey = ""
        var fontSize = 0.0
        var fontSizeText = "0"
        var fontFromGState = false
        var tc = 0.0, tw = 0.0, th = 1.0, tl = 0.0, rise = 0.0
        var tr = 0
        var fill: [Double] = [0]
    }

    private struct Marked {
        var mcid: Int?
        var actualText: PDFTextRun.ActualText?
    }

    /// Budgets for one page: form XObjects drawn (counting repeats) and the bytes of form content they run.
    static let maxFormDraws = 20_000
    static let maxDrawnBytes = 512 << 20
    static let tooComplexMessage = "This page draws the same nested content too many times to edit."

    /// Budgets for what one page keeps and runs. A content stream within the decoding limit (256 MB) can still be
    /// tens of millions of tiny show operators, each kept as a run with its glyphs (about 1 KB each): a 360 KB
    /// file reached 3.6 GB. Items are runs, their glyphs and TJ elements, array elements read, and images.
    static var maxItems = 500_000
    static let maxOperators = 10_000_000
    static let maxNesting = 10_000
    static let tooMuchMessage = "This page has more content than Edit PDF can read, so its text can’t be edited."

    private func interpret() {
        var gs = State()
        var stack: [State] = []
        var tm = CGAffineTransform.identity, tlm = CGAffineTransform.identity
        var textObject = 0
        var marked: [Marked] = []
        var formStack: [Int] = []
        var formDraws = 0, drawnBytes = 0
        var tooComplex = false
        var decodedForms: [Int: [UInt8]] = [:]
        var items = 0, operators = 0
        var stopped = false
        func stop() {
            if !stopped { stopped = true; problems.append(PDFPageContent.tooMuchMessage) }
        }

        func run(_ si: Int, depth: Int) {
            let s = streams[si]
            var scanner = PDFContentScanner(s.data)
            var operands: [(value: PDFValue, range: Range<Int>, elements: [(value: PDFValue, range: Range<Int>)]?)] = []
            var saves = 0
            var counted = 0
            while !stopped, let item = scanner.next() {
                items += scanner.elementsRead - counted
                counted = scanner.elementsRead
                if scanner.truncated || items > PDFPageContent.maxItems { stop(); break }
                switch item {
                case .operand(let v, let r, let e):
                    operands.append((v, r, e))
                    if operands.count > 64 { operands.removeFirst() }
                    continue
                case .op(let op, let r):
                    operators += 1
                    if operators > PDFPageContent.maxOperators || stack.count > PDFPageContent.maxNesting
                        || marked.count > PDFPageContent.maxNesting { stop(); break }
                    let nums = operands.compactMap { $0.value.double }
                    func n(_ k: Int) -> Double { k < nums.count ? nums[k] : 0 }
                    switch op {
                    case "q": stack.append(gs); saves += 1
                    case "Q": if let g = stack.popLast() { gs = g }; saves -= 1
                    case "cm" where nums.count == 6:
                        gs.ctm = CGAffineTransform(a: n(0), b: n(1), c: n(2), d: n(3), tx: n(4), ty: n(5)).concatenating(gs.ctm)
                    case "BT": tm = .identity; tlm = .identity; textObject += 1
                    case "ET": break
                    case "Tf":
                        if operands.count >= 2, let name = operands[operands.count - 2].value.name, let size = operands.last?.value.double {
                            gs.font = name
                            gs.fontSize = size
                            gs.fontSizeText = String(decoding: s.data[operands.last!.range], as: UTF8.self)
                            gs.fontFromGState = false
                            gs.fontKey = fontKey(name, stream: si)
                        }
                    case "Tc": gs.tc = n(0)
                    case "Tw": gs.tw = n(0)
                    case "Tz": gs.th = n(0) / 100
                    case "TL": gs.tl = n(0)
                    case "Ts": gs.rise = n(0)
                    case "Tr": gs.tr = PDFNumber.int(n(0), clampedTo: 0...7)
                    case "Td", "TD":
                        if op == "TD" { gs.tl = -n(1) }
                        tlm = CGAffineTransform(translationX: n(0), y: n(1)).concatenating(tlm); tm = tlm
                    case "Tm" where nums.count == 6:
                        tlm = CGAffineTransform(a: n(0), b: n(1), c: n(2), d: n(3), tx: n(4), ty: n(5)); tm = tlm
                    case "T*":
                        tlm = CGAffineTransform(translationX: 0, y: -gs.tl).concatenating(tlm); tm = tlm
                    case "Tj", "TJ", "'", "\"":
                        if op == "\"", nums.count >= 2 { gs.tw = n(0); gs.tc = n(1) }
                        if op == "'" || op == "\"" { tlm = CGAffineTransform(translationX: 0, y: -gs.tl).concatenating(tlm); tm = tlm }
                        let elements: [(value: PDFValue, range: Range<Int>)]
                        if op == "TJ" { elements = operands.last?.elements ?? [] }
                        else if let last = operands.last, last.value.bytes != nil { elements = [(last.value, last.range)] }
                        else { elements = [] }
                        let opStart = op == "TJ" ? (operands.last?.range.lowerBound ?? r.lowerBound)
                            : op == "\"" ? (operands.count >= 3 ? operands[operands.count - 3].range.lowerBound : r.lowerBound)
                            : (operands.last?.range.lowerBound ?? r.lowerBound)
                        let ops = op == "\"" ? Array(operands.suffix(3)).map { (value: $0.value, range: $0.range) }
                            : Array(operands.suffix(1)).map { (value: $0.value, range: $0.range) }
                        // The run, its elements and at most one glyph per string byte.
                        items += 1 + elements.count + elements.reduce(0) { $0 + ($1.value.bytes?.count ?? 0) }
                        if items > PDFPageContent.maxItems { stop(); break }
                        let x = show(op: op, stream: si, opRange: opStart..<r.upperBound, operands: ops, elements: elements,
                                     gs: gs, tm: tm, textObject: textObject, marked: marked)
                        tm = CGAffineTransform(translationX: x, y: 0).concatenating(tm)
                    case "g": gs.fill = [n(0)]
                    case "rg": gs.fill = [n(0), n(1), n(2)]
                    case "k": gs.fill = [n(0), n(1), n(2), n(3)]
                    case "sc", "scn": if !nums.isEmpty { gs.fill = nums }
                    case "cs":
                        switch operands.last?.value.name {
                        case "DeviceGray"?, "G"?: gs.fill = [0]
                        case "DeviceRGB"?, "RGB"?: gs.fill = [0, 0, 0]
                        case "DeviceCMYK"?, "CMYK"?: gs.fill = [0, 0, 0, 1]
                        default: gs.fill = [0]
                        }
                    case "gs":
                        if let name = operands.last?.value.name, let eg = file.resolve(file.resolve(s.resources["ExtGState"])?.dict?[name])?.dict,
                           let fa = file.resolve(eg["Font"])?.array, fa.count == 2, let size = file.resolve(fa[1]).double {
                            gs.font = ""
                            gs.fontSize = size
                            gs.fontSizeText = PDFNumber.format(size)
                            gs.fontFromGState = true
                            gs.fontKey = fonts.font(fa[0], holder: "gs:\(s.objectNumber):\(name)")?.key ?? ""
                        }
                    case "BDC", "BMC":
                        var m = Marked()
                        if op == "BDC", operands.count >= 2 {
                            let props = operands[operands.count - 1]
                            var dict = props.value.dict
                            if dict == nil, let pn = props.value.name {
                                dict = file.resolve(file.resolve(s.resources["Properties"])?.dict?[pn])?.dict
                            }
                            m.mcid = dict?["MCID"]?.int
                            if props.value.dict != nil, let at = actualTextToken(in: s.data, range: props.range) {
                                m.actualText = PDFTextRun.ActualText(stream: si, range: at.range, bytes: at.bytes, hex: at.hex,
                                                                     bdcRange: operands[operands.count - 2].range.lowerBound..<r.upperBound)
                            }
                        }
                        marked.append(m)
                    case "EMC": _ = marked.popLast()
                    case "Do":
                        guard let name = operands.last?.value.name else { break }
                        let xobjects = file.resolve(s.resources["XObject"])?.dict
                        guard let ref = xobjects?[name], let xn = ref.ref?.number, let xo = file.object(xn), let xd = xo.value.dict else { break }
                        let subtype = xd["Subtype"]?.name
                        if subtype == "Image" {
                            items += 1
                            images.append(PDFImagePlacement(quad: PDFTextRun.corners(x0: 0, x1: 1, lo: 0, hi: 1, m: gs.ctm), objectNumber: xn))
                        } else if subtype == "Form", depth < 12, !formStack.contains(xn), xo.stream != nil {
                            // A form that draws another form many times, nested a few levels deep, multiplies into
                            // millions of draws (40⁵ from a 3 KB file): stop at a budget instead of hanging.
                            formDraws += 1
                            if formDraws > PDFPageContent.maxFormDraws || drawnBytes > PDFPageContent.maxDrawnBytes {
                                if !tooComplex { tooComplex = true; problems.append(PDFPageContent.tooComplexMessage) }
                                break
                            }
                            let data: [UInt8]
                            if let cached = decodedForms[xn] { data = cached } else {
                                do { data = try file.decodedStream(xn) ?? [] } catch { problems.append(error.localizedDescription); break }
                                decodedForms[xn] = data
                            }
                            drawnBytes += data.count
                            let own = xd["Resources"].flatMap { file.resolve($0).dict }
                            streams.append(PDFContentStream(objectNumber: xn, dict: xd, data: data, resources: own ?? s.resources,
                                                            form: .init(name: name, parent: si, depth: depth + 1, ownResources: own != nil,
                                                                        resourcesObject: xd["Resources"]?.ref?.number)))
                            formUses[xn, default: 0] += 1
                            let saved = gs
                            let savedStack = stack.count
                            if let m = xd["Matrix"].flatMap({ file.resolve($0).array })?.compactMap({ file.resolve($0).double }), m.count == 6 {
                                gs.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(gs.ctm)
                            }
                            formStack.append(xn)
                            let savedTM = (tm, tlm)
                            run(streams.count - 1, depth: depth + 1)
                            formStack.removeLast()
                            (tm, tlm) = savedTM
                            if stack.count > savedStack { stack.removeLast(stack.count - savedStack) }
                            gs = saved
                        }
                    case "BI":
                        items += 1
                        images.append(PDFImagePlacement(quad: PDFTextRun.corners(x0: 0, x1: 1, lo: 0, hi: 1, m: gs.ctm), objectNumber: nil))
                    default: break
                    }
                    operands.removeAll(keepingCapacity: true)
                }
            }
            if s.form == nil { unbalancedSaves += saves }
        }
        let pageStreams = streams.count
        for si in 0..<pageStreams { run(si, depth: 0) }
        // Codes the page shows count as evidence that they draw.
        for r in runs { if let f = fonts.font(key: r.fontKey) { for g in r.glyphs where !g.text.isEmpty || f.isComposite { f.noteUsed(fontGlyph(g)) } } }
    }

    private func fontGlyph(_ g: PDFGlyph) -> PDFEditFont.Glyph {
        PDFEditFont.Glyph(code: g.code, bytes: g.bytes, text: g.text, width: 0, isSpace: g.isSpace)
    }

    private func fontKey(_ name: String, stream si: Int) -> String {
        let s = streams[si]
        if let v = file.resolve(s.resources["Font"])?.dict?[name] {
            return fonts.font(v, holder: "inline:\(s.objectNumber):\(name)")?.key ?? ""
        }
        // A form without the font in its own resources: readers fall back to the page's.
        if let v = file.resolve(page.resources["Font"])?.dict?[name] {
            return fonts.font(v, holder: "inline:page\(page.number):\(name)")?.key ?? ""
        }
        return ""
    }

    private func show(op: String, stream si: Int, opRange: Range<Int>, operands: [(value: PDFValue, range: Range<Int>)],
                      elements: [(value: PDFValue, range: Range<Int>)], gs: State, tm: CGAffineTransform, textObject: Int,
                      marked: [Marked]) -> Double {
        let f = fonts.font(key: gs.fontKey)
        var x = 0.0
        var glyphs: [PDFGlyph] = []
        for (ei, e) in elements.enumerated() {
            if let num = e.value.double { x += -num / 1000 * gs.fontSize * gs.th; continue }
            guard let bytes = e.value.bytes, let f else { continue }
            for (gi, g) in f.glyphs(bytes).enumerated() {
                let spacing = g.isSpace && !f.isComposite ? gs.tw : 0
                let adv = (g.width * gs.fontSize + gs.tc + spacing) * gs.th
                glyphs.append(PDFGlyph(element: ei, index: gi, code: g.code, bytes: g.bytes, text: g.text, x0: x,
                                       width: g.width * gs.fontSize * gs.th, advance: adv, isSpace: g.isSpace))
                x += adv
            }
        }
        // No Unicode for these codes (a CID font on a standard collection that Quartz wrote without ToUnicode):
        // learn them from PDFKit's text under the run.
        // At most a few thousand lookups a page: each asks PDFKit for a selection, and a page of 100,000 such runs
        // would stall the window for minutes.
        if let f, !glyphs.isEmpty, glyphs.allSatisfy({ $0.text.isEmpty }), let under = textUnder, textUnderLookups < 5_000 {
            textUnderLookups += 1
            let m = tm.concatenating(gs.ctm)
            let rect = PDFEditGeometry.bounds(PDFTextRun.corners(x0: glyphs[0].x0, x1: x, lo: gs.rise + f.descent * gs.fontSize,
                                                                 hi: gs.rise + f.ascent * gs.fontSize, m: m))
            let chars = Array((under(rect) ?? "").filter { !$0.isWhitespace })
            if chars.count == glyphs.count {
                for k in glyphs.indices {
                    glyphs[k].text = String(chars[k])
                    f.learn(glyphs[k].code, bytes: glyphs[k].bytes, text: String(chars[k]))
                }
            }
        }
        var mcid: Int?
        var actual: PDFTextRun.ActualText?
        for m in marked.reversed() {
            if mcid == nil { mcid = m.mcid }
            if actual == nil { actual = m.actualText }
        }
        runs.append(PDFTextRun(index: runs.count, stream: si, op: op, opRange: opRange, operands: operands, elements: elements,
                               fontName: gs.font, fontKey: gs.fontKey, fontSize: gs.fontSize, fontSizeText: gs.fontSizeText,
                               textMatrix: tm, ctm: gs.ctm, hScale: gs.th, charSpacing: gs.tc, wordSpacing: gs.tw, rise: gs.rise,
                               renderMode: gs.tr, fill: gs.fill, glyphs: glyphs, endX: x, mcid: mcid, actualText: actual,
                               textObject: textObject, fontFromGState: gs.fontFromGState))
        return x
    }

    /// The /ActualText string inside a BDC property dictionary.
    private func actualTextToken(in data: [UInt8], range: Range<Int>) -> (range: Range<Int>, bytes: [UInt8], hex: Bool)? {
        var lx = PDFLexer(data, at: range.lowerBound)
        var depth = 0
        while lx.p < range.upperBound {
            let (t, _) = lx.next()
            switch t {
            case .dictOpen: depth += 1
            case .dictClose: depth -= 1
            case .name("ActualText") where depth == 1:
                let (v, vr) = lx.next()
                if case .string(let b, let hex) = v { return (vr, b, hex) }
                return nil
            case .eof: return nil
            default: break
            }
        }
        return nil
    }

    // MARK: Lines

    private func buildLines() {
        struct Building {
            var runs: [Int]
            var units: [PDFTextLine.Unit]
            var dir: CGVector
            var up: CGVector
            var perp: Double
            var start: Double
            var visibleEnd: Double
            var end: Double
            var size: Double
            var stream: Int
            var lo: Double
            var hi: Double
            var hidden: Bool
        }
        var built: [Building] = []
        var current: Building?

        func measures(_ r: PDFTextRun) -> (dir: CGVector, up: CGVector, perp: Double, s0: Double, s1: Double, visible: Double, size: Double, lo: Double, hi: Double)? {
            let m = r.trm
            let len = hypot(m.a, m.b)
            guard len > 1e-9, r.fontSize != 0 else { return nil }
            let dir = CGVector(dx: m.a / len, dy: m.b / len)
            let up = CGVector(dx: -dir.dy, dy: dir.dx)
            let f = font(of: r)
            let origin = CGPoint(x: 0, y: r.rise).applying(m)
            func along(_ x: Double) -> Double { let p = CGPoint(x: x, y: r.rise).applying(m); return p.x * dir.dx + p.y * dir.dy }
            let s0 = along(r.glyphs.first?.x0 ?? 0)
            let s1 = along(r.endX)
            let lastVisible = r.glyphs.lastIndex { !$0.isSpace && !$0.text.allSatisfy(\.isWhitespace) }
            let visible = lastVisible.map { along(r.glyphs[$0].x0 + r.glyphs[$0].width) } ?? s0
            let size = abs(r.fontSize) * hypot(m.c, m.d)
            let perp = origin.x * up.dx + origin.y * up.dy
            let asc = (f?.ascent ?? 0.8) * r.fontSize, desc = (f?.descent ?? -0.2) * r.fontSize
            let hiPoint = CGPoint(x: 0, y: r.rise + asc).applying(m), loPoint = CGPoint(x: 0, y: r.rise + desc).applying(m)
            let hi = hiPoint.x * up.dx + hiPoint.y * up.dy, lo = loPoint.x * up.dx + loPoint.y * up.dy
            // Text placed with absurd numbers (a 1e300 pt font, a 1e30 scale) is never on the page; leaving it out
            // keeps infinities and NaN away from hit-testing, the window and the gate's pixel arithmetic.
            guard [perp, s0, s1, visible, size, lo, hi].allSatisfy({ $0.isFinite && abs($0) < 1e7 }) else { return nil }
            return (dir, up, perp, s0, s1, visible, size, min(lo, hi), max(lo, hi))
        }

        func unitsOf(_ r: PDFTextRun) -> [PDFTextLine.Unit] {
            var u: [PDFTextLine.Unit] = []
            var lastElement = -1
            for (gi, g) in r.glyphs.enumerated() {
                // A wide kerning gap inside a TJ reads as a space.
                if gi > 0, g.element != lastElement, lastElement >= 0 {
                    var gap = 0.0
                    for e in (lastElement + 1)..<g.element { if let n = r.elements[e].value.double { gap += -n / 1000 } }
                    if gap > 0.18, !(u.last?.text.last?.isWhitespace ?? true), !g.text.hasPrefix(" ") {
                        u.append(.init(run: nil, glyph: nil, text: " "))
                    }
                }
                u.append(.init(run: r.index, glyph: gi, text: g.text))
                lastElement = g.element
            }
            return u
        }

        for r in runs where !r.glyphs.isEmpty {
            guard let m = measures(r) else { continue }
            let hidden = r.renderMode == 3 || r.renderMode == 7
            let joins = current.map { c in
                c.stream == r.stream && c.dir.dx * m.dir.dx + c.dir.dy * m.dir.dy > 0.999
                    && abs(m.perp - c.perp) < 0.35 * max(m.size, c.size) && m.s0 >= c.end - 0.6 * max(m.size, c.size)
                    && m.s0 <= c.visibleEnd + 1.5 * max(m.size, c.size)
            } ?? false
            if joins {
                // Changed in place: copying the line out and back copied its units for every run it gained, which
                // is quadratic (a line of 600,000 runs never finished).
                let gap = m.s0 - current!.visibleEnd
                let newUnits = unitsOf(r)
                if gap > 0.15 * m.size, !(current!.units.last?.text.last?.isWhitespace ?? true), !(newUnits.first?.text.first?.isWhitespace ?? true) {
                    current!.units.append(.init(run: nil, glyph: nil, text: " "))
                }
                current!.runs.append(r.index)
                current!.units += newUnits
                current!.end = max(current!.end, m.s1)
                current!.visibleEnd = max(current!.visibleEnd, m.visible)
                current!.lo = min(current!.lo, m.lo); current!.hi = max(current!.hi, m.hi)
                current!.size = max(current!.size, m.size)
                current!.hidden = current!.hidden && hidden
            } else {
                if let c = current { built.append(c) }
                current = Building(runs: [r.index], units: unitsOf(r), dir: m.dir, up: m.up, perp: m.perp, start: m.s0,
                                   visibleEnd: m.visible, end: m.s1, size: m.size, stream: r.stream, lo: m.lo, hi: m.hi, hidden: hidden)
            }
        }
        if let c = current { built.append(c) }

        let upright = PDFEditGeometry.uprightTransform(crop: page.cropBox, rotate: page.rotate)
        var made: [(line: PDFTextLine, top: Double, left: Double, content: Int)] = []
        for (k, b) in built.enumerated() {
            let endS = max(b.visibleEnd, b.start + 0.01)
            func point(_ s: Double, _ h: Double) -> CGPoint {
                CGPoint(x: b.dir.dx * s + b.up.dx * h, y: b.dir.dy * s + b.up.dy * h)
            }
            let quad = [point(b.start, b.lo), point(endS, b.lo), point(endS, b.hi), point(b.start, b.hi)]
            let origin = point(b.start, b.perp)
            let text = b.units.map(\.text).joined()
            let line = PDFTextLine(index: 0, runs: b.runs, text: text, units: b.units, quad: quad, origin: origin,
                                   direction: b.dir, angle: atan2(b.dir.dy, b.dir.dx) * 180 / .pi, pointSize: b.size,
                                   stream: b.stream, hidden: b.hidden)
            let r = PDFEditGeometry.bounds(quad).applying(upright)
            made.append((line, Double(r.maxY), Double(r.minX), k))
        }
        // Reading order: top to bottom in bands of half a line, then left to right; content order breaks ties.
        made.sort { a, b in
            let band = 0.5 * min(a.line.pointSize, b.line.pointSize)
            if abs(a.top - b.top) > max(band, 0.5) { return a.top > b.top }
            if abs(a.left - b.left) > 0.5 { return a.left < b.left }
            return a.content < b.content
        }
        lines = made.enumerated().map { i, m in
            let l = m.line
            return PDFTextLine(index: i, runs: l.runs, text: l.text, units: l.units, quad: l.quad, origin: l.origin,
                               direction: l.direction, angle: l.angle, pointSize: l.pointSize, stream: l.stream, hidden: l.hidden)
        }
    }

    /// The line that shows run `r`.
    func line(containingRun r: Int) -> PDFTextLine? { lines.first { $0.runs.contains(r) } }
}
