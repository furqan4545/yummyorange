import AppKit

// Small helpers for reading CGPDF objects, plus the colour model the SVG writer needs:
// colour spaces, PDF functions (types 0, 2, 3 and 4) and axial/radial shadings as SVG gradients.

/// Typed reads from CGPDF dictionaries, arrays and streams.
enum PDFSVGObj {
    /// Identity of a CGPDF object (dictionaries, streams), for caches and cycle checks.
    static func key<T>(_ ref: T) -> UnsafeRawPointer { unsafeBitCast(ref, to: UnsafeRawPointer.self) }

    static func number(_ d: CGPDFDictionaryRef?, _ keys: String...) -> CGFloat? {
        guard let d else { return nil }
        for k in keys { var v: CGPDFReal = 0; if CGPDFDictionaryGetNumber(d, k, &v) { return v } }
        return nil
    }
    static func int(_ d: CGPDFDictionaryRef?, _ keys: String...) -> Int? {
        guard let d else { return nil }
        for k in keys { var v: CGPDFReal = 0; if CGPDFDictionaryGetNumber(d, k, &v) { return Int(v.rounded()) } }
        return nil
    }
    static func bool(_ d: CGPDFDictionaryRef?, _ keys: String...) -> Bool? {
        guard let d else { return nil }
        for k in keys { var v: CGPDFBoolean = 0; if CGPDFDictionaryGetBoolean(d, k, &v) { return v != 0 } }
        return nil
    }
    static func name(_ d: CGPDFDictionaryRef?, _ keys: String...) -> String? {
        guard let d else { return nil }
        for k in keys {
            var p: UnsafePointer<Int8>?
            if CGPDFDictionaryGetName(d, k, &p), let p { return String(cString: p) }
        }
        return nil
    }
    static func dict(_ d: CGPDFDictionaryRef?, _ keys: String...) -> CGPDFDictionaryRef? {
        guard let d else { return nil }
        for k in keys {
            var v: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(d, k, &v), let v { return v }
        }
        return nil
    }
    static func array(_ d: CGPDFDictionaryRef?, _ keys: String...) -> CGPDFArrayRef? {
        guard let d else { return nil }
        for k in keys {
            var v: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(d, k, &v), let v { return v }
        }
        return nil
    }
    static func stream(_ d: CGPDFDictionaryRef?, _ keys: String...) -> CGPDFStreamRef? {
        guard let d else { return nil }
        for k in keys {
            var v: CGPDFStreamRef?
            if CGPDFDictionaryGetStream(d, k, &v), let v { return v }
        }
        return nil
    }
    static func object(_ d: CGPDFDictionaryRef?, _ keys: String...) -> CGPDFObjectRef? {
        guard let d else { return nil }
        for k in keys {
            var v: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(d, k, &v), let v, CGPDFObjectGetType(v) != .null { return v }
        }
        return nil
    }
    static func text(_ d: CGPDFDictionaryRef?, _ key: String) -> String? {
        guard let d else { return nil }
        var s: CGPDFStringRef?
        guard CGPDFDictionaryGetString(d, key, &s), let s else { return nil }
        return CGPDFStringCopyTextString(s) as String?
    }
    static func numbers(_ a: CGPDFArrayRef?) -> [CGFloat] {
        guard let a else { return [] }
        return (0..<CGPDFArrayGetCount(a)).map { i in var v: CGPDFReal = 0; return CGPDFArrayGetNumber(a, i, &v) ? v : 0 }
    }
    static func rect(_ a: CGPDFArrayRef?) -> CGRect? {
        let n = numbers(a)
        guard n.count == 4 else { return nil }
        return CGRect(x: min(n[0], n[2]), y: min(n[1], n[3]), width: abs(n[2] - n[0]), height: abs(n[3] - n[1]))
    }
    static func matrix(_ a: CGPDFArrayRef?) -> CGAffineTransform? {
        let n = numbers(a)
        guard n.count == 6 else { return nil }
        return CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
    }
    static func bytes(_ s: CGPDFStringRef) -> [UInt8] {
        guard let p = CGPDFStringGetBytePtr(s) else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: CGPDFStringGetLength(s)))
    }
    static func data(_ s: CGPDFStreamRef) -> Data? {
        var format = CGPDFDataFormat.raw
        return CGPDFStreamCopyData(s, &format) as Data?
    }
    /// The bytes of a string or stream object (Indexed lookup tables can be either).
    static func bytes(of object: CGPDFObjectRef) -> [UInt8]? {
        var s: CGPDFStringRef?
        if CGPDFObjectGetValue(object, .string, &s), let s { return bytes(s) }
        var st: CGPDFStreamRef?
        if CGPDFObjectGetValue(object, .stream, &st), let st, let d = data(st) { return [UInt8](d) }
        return nil
    }
    static func nameValue(_ o: CGPDFObjectRef) -> String? {
        var p: UnsafePointer<Int8>?
        return CGPDFObjectGetValue(o, .name, &p) && p != nil ? String(cString: p!) : nil
    }
    static func dictValue(_ o: CGPDFObjectRef) -> CGPDFDictionaryRef? {
        var d: CGPDFDictionaryRef?
        if CGPDFObjectGetValue(o, .dictionary, &d), let d { return d }
        var s: CGPDFStreamRef?
        if CGPDFObjectGetValue(o, .stream, &s), let s { return CGPDFStreamGetDictionary(s) }
        return nil
    }
    static func streamValue(_ o: CGPDFObjectRef) -> CGPDFStreamRef? {
        var s: CGPDFStreamRef?
        return CGPDFObjectGetValue(o, .stream, &s) ? s : nil
    }
    static func arrayValue(_ o: CGPDFObjectRef) -> CGPDFArrayRef? {
        var a: CGPDFArrayRef?
        return CGPDFObjectGetValue(o, .array, &a) ? a : nil
    }
    static func element(_ a: CGPDFArrayRef, _ i: Int) -> CGPDFObjectRef? {
        var o: CGPDFObjectRef?
        return CGPDFArrayGetObject(a, i, &o) ? o : nil
    }
}

// MARK: - Colour spaces

/// A PDF colour space reduced to what SVG needs: turning components into sRGB.
/// Device spaces are mapped directly, ICC-based and Lab colours go through ColorSync.
final class PDFSVGColorSpace {
    indirect enum Kind {
        case gray, rgb, cmyk
        case managed(CGColorSpace)
        case indexed(PDFSVGColorSpace, hival: Int, table: [UInt8])
        /// Separation and DeviceN: tints turned into the alternate space by the tint transform.
        case tint(PDFSVGColorSpace, PDFSVGFunction?, none: Bool)
        case pattern(PDFSVGColorSpace?)
    }

    let kind: Kind
    let components: Int
    private var cache: [[Int]: String] = [:]

    init(_ kind: Kind, components: Int) {
        self.kind = kind
        self.components = components
    }

    static let gray = PDFSVGColorSpace(.gray, components: 1)
    static let rgb = PDFSVGColorSpace(.rgb, components: 3)
    static let cmyk = PDFSVGColorSpace(.cmyk, components: 4)
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let genericCMYK = CGColorSpaceCreateDeviceCMYK()

    var isPattern: Bool { if case .pattern = kind { return true } else { return false } }
    /// A Separation called /None paints nothing.
    var paintsNothing: Bool { if case .tint(_, _, true) = kind { return true } else { return false } }

    var initial: [CGFloat] {
        switch kind {
        case .cmyk: return [0, 0, 0, 1]
        case .tint: return Array(repeating: 1, count: components)
        case .pattern: return []
        default: return Array(repeating: 0, count: components)
        }
    }

    /// "#RRGGBB" for the components (cached).
    func hex(_ c: [CGFloat]) -> String {
        let key = c.map { Int(($0 * 1000).rounded()) }
        if let hit = cache[key] { return hit }
        let (r, g, b) = rgb(c)
        let s = PDFSVGColorSpace.hex(r, g, b)
        if cache.count < 4096 { cache[key] = s }
        return s
    }

    static func hex(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> String {
        let digits = Array("0123456789ABCDEF")
        var s = "#"
        for v in [r, g, b] {
            let i = Int((min(1, max(0, v.isFinite ? v : 0)) * 255).rounded())
            s.append(digits[i >> 4]); s.append(digits[i & 15])
        }
        return s
    }

    func rgb(_ c: [CGFloat]) -> (CGFloat, CGFloat, CGFloat) {
        func at(_ i: Int) -> CGFloat { i < c.count ? min(1, max(0, c[i])) : 0 }
        switch kind {
        case .gray: return (at(0), at(0), at(0))
        case .rgb: return (at(0), at(1), at(2))
        case .cmyk: return Self.convert([at(0), at(1), at(2), at(3)], from: Self.genericCMYK)
        case .managed(let space):
            let n = space.numberOfComponents
            let comps = (0..<n).map { i in i < c.count ? c[i] : 0 }
            return Self.convert(comps, from: space)
        case .indexed(let base, let hival, let table):
            let index = min(hival, max(0, Int((c.first ?? 0).rounded())))
            let n = base.components
            let comps = (0..<n).map { j -> CGFloat in
                let k = index * n + j
                return k < table.count ? CGFloat(table[k]) / 255 : 0
            }
            return base.rgb(comps)
        case .tint(let alternate, let function, _):
            if let function { return alternate.rgb(function.evaluate(c)) }
            let t = c.first ?? 1
            return (1 - t, 1 - t, 1 - t)
        case .pattern:
            return (0.5, 0.5, 0.5)
        }
    }

    private static func convert(_ comps: [CGFloat], from space: CGColorSpace) -> (CGFloat, CGFloat, CGFloat) {
        guard let color = CGColor(colorSpace: space, components: comps + [1]),
              let converted = color.converted(to: srgb, intent: .relativeColorimetric, options: nil),
              let out = converted.components, out.count >= 3 else {
            let v = comps.first ?? 0
            return (v, v, v)
        }
        return (out[0], out[1], out[2])
    }

    /// A Core Graphics colour space for decoding image samples, when one exists.
    var cgSpace: CGColorSpace? {
        switch kind {
        case .gray: return CGColorSpaceCreateDeviceGray()
        case .rgb: return Self.srgb
        case .cmyk: return Self.genericCMYK
        case .managed(let space): return space
        case .indexed(let base, let hival, let table):
            guard let baseSpace = base.cgSpace, base.components == baseSpace.numberOfComponents else { return nil }
            var padded = table
            let need = (hival + 1) * base.components
            if padded.count < need { padded += Array(repeating: 0, count: need - padded.count) }
            return padded.withUnsafeBufferPointer { CGColorSpace(indexedBaseSpace: baseSpace, last: hival, colorTable: $0.baseAddress!) }
        default: return nil
        }
    }

    /// Reads a colour space from a name or array. `lookup` resolves names in the ColorSpace resources.
    static func parse(_ object: CGPDFObjectRef, lookup: (String) -> CGPDFObjectRef?, depth: Int = 0) -> PDFSVGColorSpace? {
        guard depth < 8 else { return nil }
        if let name = PDFSVGObj.nameValue(object) {
            switch name {
            case "DeviceGray", "G", "CalGray": return .gray
            case "DeviceRGB", "RGB", "CalRGB": return .rgb
            case "DeviceCMYK", "CMYK": return .cmyk
            case "Pattern": return PDFSVGColorSpace(.pattern(nil), components: 0)
            default:
                guard let resolved = lookup(name) else { return nil }
                return parse(resolved, lookup: lookup, depth: depth + 1)
            }
        }
        guard let array = PDFSVGObj.arrayValue(object), CGPDFArrayGetCount(array) > 0 else { return nil }
        var family: UnsafePointer<Int8>?
        guard CGPDFArrayGetName(array, 0, &family), let family else { return nil }
        func sub(_ i: Int) -> PDFSVGColorSpace? {
            PDFSVGObj.element(array, i).flatMap { parse($0, lookup: lookup, depth: depth + 1) }
        }
        switch String(cString: family) {
        case "DeviceGray", "CalGray", "G": return .gray
        case "DeviceRGB", "CalRGB", "RGB": return .rgb
        case "DeviceCMYK", "CMYK": return .cmyk
        case "ICCBased":
            var stream: CGPDFStreamRef?
            guard CGPDFArrayGetStream(array, 1, &stream), let stream else { return nil }
            let dict = CGPDFStreamGetDictionary(stream)
            let n = PDFSVGObj.int(dict, "N") ?? 3
            if let data = PDFSVGObj.data(stream), let space = CGColorSpace(iccData: data as CFData),
               space.numberOfComponents == n {
                return PDFSVGColorSpace(.managed(space), components: n)
            }
            if let alt = PDFSVGObj.object(dict, "Alternate"), let parsed = parse(alt, lookup: lookup, depth: depth + 1) { return parsed }
            return n == 1 ? .gray : n == 4 ? .cmyk : .rgb
        case "Lab":
            var dict: CGPDFDictionaryRef?
            _ = CGPDFArrayGetDictionary(array, 1, &dict)
            var white = PDFSVGObj.numbers(PDFSVGObj.array(dict, "WhitePoint")); if white.count != 3 { white = [0.9505, 1, 1.089] }
            var black = PDFSVGObj.numbers(PDFSVGObj.array(dict, "BlackPoint")); if black.count != 3 { black = [0, 0, 0] }
            var range = PDFSVGObj.numbers(PDFSVGObj.array(dict, "Range")); if range.count != 4 { range = [-100, 100, -100, 100] }
            guard let space = CGColorSpace(labWhitePoint: white, blackPoint: black, range: range) else { return .rgb }
            return PDFSVGColorSpace(.managed(space), components: 3)
        case "Indexed", "I":
            guard let base = sub(1) else { return nil }
            var hival: CGPDFInteger = 0
            _ = CGPDFArrayGetInteger(array, 2, &hival)
            let table = PDFSVGObj.element(array, 3).flatMap { PDFSVGObj.bytes(of: $0) } ?? []
            return PDFSVGColorSpace(.indexed(base, hival: max(0, Int(hival)), table: table), components: 1)
        case "Separation":
            var colorant: UnsafePointer<Int8>?
            _ = CGPDFArrayGetName(array, 1, &colorant)
            let alternate = sub(2) ?? .gray
            let function = PDFSVGObj.element(array, 3).flatMap { PDFSVGFunction.parse($0) }
            let isNone = colorant.map { String(cString: $0) } == "None"
            return PDFSVGColorSpace(.tint(alternate, function, none: isNone), components: 1)
        case "DeviceN":
            var names: CGPDFArrayRef?
            _ = CGPDFArrayGetArray(array, 1, &names)
            let n = max(1, names.map { CGPDFArrayGetCount($0) } ?? 1)
            let alternate = sub(2) ?? .gray
            let function = PDFSVGObj.element(array, 3).flatMap { PDFSVGFunction.parse($0) }
            return PDFSVGColorSpace(.tint(alternate, function, none: false), components: n)
        case "Pattern":
            return PDFSVGColorSpace(.pattern(CGPDFArrayGetCount(array) > 1 ? sub(1) : nil), components: 0)
        default:
            return nil
        }
    }
}

// MARK: - Functions

/// A PDF function (sampled, exponential, stitching or PostScript calculator).
final class PDFSVGFunction {
    private enum Kind {
        case sampled(size: [Int], bits: Int, encode: [CGFloat], decode: [CGFloat], samples: [UInt8])
        case exponential(c0: [CGFloat], c1: [CGFloat], n: CGFloat)
        case stitching(functions: [PDFSVGFunction], bounds: [CGFloat], encode: [CGFloat])
        case postscript([PDFSVGPSOp])
        /// An array of one-input functions, one per output (allowed for shadings).
        case list([PDFSVGFunction])
    }

    private let kind: Kind
    private let domain: [CGFloat]
    private let range: [CGFloat]

    private init(_ kind: Kind, domain: [CGFloat], range: [CGFloat]) {
        self.kind = kind
        self.domain = domain
        self.range = range
    }

    /// Stitching bounds, mapped into the outer domain, for placing gradient stops exactly.
    var breakpoints: [CGFloat] {
        if case .stitching(_, let bounds, _) = kind { return bounds }
        return []
    }

    static func parse(_ object: CGPDFObjectRef, depth: Int = 0) -> PDFSVGFunction? {
        guard depth < 8 else { return nil }
        if let array = PDFSVGObj.arrayValue(object) {
            let parts = (0..<CGPDFArrayGetCount(array)).compactMap { PDFSVGObj.element(array, $0).flatMap { parse($0, depth: depth + 1) } }
            return parts.isEmpty ? nil : PDFSVGFunction(.list(parts), domain: [0, 1], range: [])
        }
        let stream = PDFSVGObj.streamValue(object)
        guard let dict = PDFSVGObj.dictValue(object), let type = PDFSVGObj.int(dict, "FunctionType") else { return nil }
        let domain = PDFSVGObj.numbers(PDFSVGObj.array(dict, "Domain"))
        let range = PDFSVGObj.numbers(PDFSVGObj.array(dict, "Range"))
        switch type {
        case 0:
            guard let stream, let data = PDFSVGObj.data(stream) else { return nil }
            let size = PDFSVGObj.numbers(PDFSVGObj.array(dict, "Size")).map { max(1, Int($0)) }
            let bits = PDFSVGObj.int(dict, "BitsPerSample") ?? 8
            guard !size.isEmpty, [1, 2, 4, 8, 12, 16, 24, 32].contains(bits), range.count >= 2 else { return nil }
            var encode = PDFSVGObj.numbers(PDFSVGObj.array(dict, "Encode"))
            if encode.count != size.count * 2 { encode = size.flatMap { [0, CGFloat($0 - 1)] } }
            var decode = PDFSVGObj.numbers(PDFSVGObj.array(dict, "Decode"))
            if decode.count != range.count { decode = range }
            return PDFSVGFunction(.sampled(size: size, bits: bits, encode: encode, decode: decode, samples: [UInt8](data)),
                                  domain: domain, range: range)
        case 2:
            var c0 = PDFSVGObj.numbers(PDFSVGObj.array(dict, "C0")); if c0.isEmpty { c0 = [0] }
            var c1 = PDFSVGObj.numbers(PDFSVGObj.array(dict, "C1")); if c1.isEmpty { c1 = [1] }
            return PDFSVGFunction(.exponential(c0: c0, c1: c1, n: PDFSVGObj.number(dict, "N") ?? 1), domain: domain, range: range)
        case 3:
            guard let list = PDFSVGObj.array(dict, "Functions") else { return nil }
            let functions = (0..<CGPDFArrayGetCount(list)).compactMap { PDFSVGObj.element(list, $0).flatMap { parse($0, depth: depth + 1) } }
            guard functions.count == CGPDFArrayGetCount(list), !functions.isEmpty else { return nil }
            return PDFSVGFunction(.stitching(functions: functions, bounds: PDFSVGObj.numbers(PDFSVGObj.array(dict, "Bounds")),
                                             encode: PDFSVGObj.numbers(PDFSVGObj.array(dict, "Encode"))),
                                  domain: domain, range: range)
        case 4:
            guard let stream, let data = PDFSVGObj.data(stream), let program = PDFSVGPSOp.parse(data) else { return nil }
            return PDFSVGFunction(.postscript(program), domain: domain, range: range)
        default:
            return nil
        }
    }

    func evaluate(_ input: [CGFloat]) -> [CGFloat] {
        var x = input
        for i in 0..<min(x.count, domain.count / 2) { x[i] = min(max(x[i], domain[2 * i]), domain[2 * i + 1]) }
        var out: [CGFloat]
        switch kind {
        case .list(let parts):
            out = parts.flatMap { $0.evaluate(x) }
        case let .exponential(c0, c1, n):
            let t = x.first ?? 0
            let p = n == 1 ? t : pow(max(t, 0), n)
            out = (0..<max(c0.count, c1.count)).map { j in
                let a = j < c0.count ? c0[j] : 0, b = j < c1.count ? c1[j] : 1
                return a + p * (b - a)
            }
        case let .stitching(functions, bounds, encode):
            let t = x.first ?? 0
            let d0 = domain.first ?? 0, d1 = domain.count > 1 ? domain[1] : 1
            var k = 0
            while k < bounds.count && t >= bounds[k] { k += 1 }
            k = min(k, functions.count - 1)
            let lo = k == 0 ? d0 : bounds[k - 1]
            let hi = k < bounds.count ? bounds[k] : d1
            let e0 = 2 * k < encode.count ? encode[2 * k] : 0, e1 = 2 * k + 1 < encode.count ? encode[2 * k + 1] : 1
            let mapped = hi == lo ? e0 : e0 + (t - lo) * (e1 - e0) / (hi - lo)
            out = functions[k].evaluate([mapped])
        case let .sampled(size, bits, encode, decode, samples):
            out = Self.sample(x, size: size, bits: bits, encode: encode, decode: decode, samples: samples,
                              domain: domain, outputs: range.count / 2)
        case .postscript(let program):
            // Outputs are the top of the stack (extra values below are ignored, as Quartz does).
            let stack = PDFSVGPSOp.run(program, input: x).map { CGFloat($0) }
            out = range.count >= 2 ? Array(stack.suffix(range.count / 2)) : stack
        }
        if range.count >= 2 {
            for j in 0..<min(out.count, range.count / 2) { out[j] = min(max(out[j], range[2 * j]), range[2 * j + 1]) }
        }
        return out
    }

    /// Multilinear interpolation in a sampled function.
    private static func sample(_ x: [CGFloat], size: [Int], bits: Int, encode: [CGFloat], decode: [CGFloat],
                               samples: [UInt8], domain: [CGFloat], outputs: Int) -> [CGFloat] {
        let m = size.count
        var lowIndex = [Int](repeating: 0, count: m), frac = [CGFloat](repeating: 0, count: m)
        for i in 0..<m {
            let xi = i < x.count ? x[i] : 0
            let d0 = 2 * i < domain.count ? domain[2 * i] : 0, d1 = 2 * i + 1 < domain.count ? domain[2 * i + 1] : 1
            let e = d1 == d0 ? encode[2 * i] : encode[2 * i] + (xi - d0) * (encode[2 * i + 1] - encode[2 * i]) / (d1 - d0)
            let clamped = min(max(e, 0), CGFloat(size[i] - 1))
            lowIndex[i] = min(Int(clamped), max(0, size[i] - 2))
            frac[i] = size[i] == 1 ? 0 : clamped - CGFloat(lowIndex[i])
        }
        let maxValue = CGFloat((UInt64(1) << UInt64(bits)) - 1)
        func value(_ index: Int, _ j: Int) -> CGFloat {
            let bitOffset = (index * outputs + j) * bits
            var v: UInt64 = 0
            for b in 0..<bits {
                let bit = bitOffset + b
                let byte = bit >> 3
                guard byte < samples.count else { return 0 }
                v = (v << 1) | UInt64((samples[byte] >> (7 - UInt8(bit & 7))) & 1)
            }
            return CGFloat(v)
        }
        var result = [CGFloat](repeating: 0, count: outputs)
        for corner in 0..<(1 << min(m, 8)) {
            var weight: CGFloat = 1, index = 0, stride = 1
            for i in 0..<m {
                let high = (corner >> i) & 1 == 1
                weight *= high ? frac[i] : 1 - frac[i]
                index += (lowIndex[i] + (high && size[i] > 1 ? 1 : 0)) * stride
                stride *= size[i]
            }
            if weight == 0 { continue }
            for j in 0..<outputs { result[j] += weight * value(index, j) }
        }
        return (0..<outputs).map { j in
            let d0 = 2 * j < decode.count ? decode[2 * j] : 0, d1 = 2 * j + 1 < decode.count ? decode[2 * j + 1] : 1
            return d0 + result[j] * (d1 - d0) / maxValue
        }
    }
}

/// A PostScript calculator function (FunctionType 4): a small stack machine.
indirect enum PDFSVGPSOp {
    case number(Double)
    case op(String)
    case branch([PDFSVGPSOp], [PDFSVGPSOp]?)   // if / ifelse
    case block([PDFSVGPSOp])

    static func parse(_ data: Data) -> [PDFSVGPSOp]? {
        let text = String(decoding: data, as: UTF8.self)
        var tokens: [String] = []
        var current = ""
        for ch in text {
            if ch == "{" || ch == "}" {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(String(ch))
            } else if ch.isWhitespace {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        var i = 0
        func block() -> [PDFSVGPSOp]? {
            var ops: [PDFSVGPSOp] = []
            while i < tokens.count {
                let t = tokens[i]; i += 1
                if t == "{" {
                    guard let inner = block() else { return nil }
                    ops.append(.block(inner))
                } else if t == "}" {
                    return ops
                } else if t == "if" || t == "ifelse" {
                    // Fold the preceding block(s) into a branch.
                    if t == "if", case .block(let body)? = ops.last {
                        ops.removeLast(); ops.append(.branch(body, nil))
                    } else if t == "ifelse", ops.count >= 2, case .block(let b2) = ops[ops.count - 1], case .block(let b1) = ops[ops.count - 2] {
                        ops.removeLast(2); ops.append(.branch(b1, b2))
                    } else { return nil }
                } else if let n = Double(t) {
                    ops.append(.number(n))
                } else {
                    ops.append(.op(t))
                }
            }
            return ops
        }
        guard let first = tokens.first, first == "{" else { return nil }
        i = 1
        return block()
    }

    static func run(_ program: [PDFSVGPSOp], input: [CGFloat]) -> [Double] {
        var stack = input.map(Double.init)
        var steps = 0
        func pop() -> Double { stack.popLast() ?? 0 }
        func exec(_ ops: [PDFSVGPSOp]) {
            for op in ops {
                steps += 1
                if steps > 100_000 || stack.count > 1000 { return }
                switch op {
                case .number(let n): stack.append(n)
                case .block: break
                case let .branch(yes, no):
                    let condition = pop() != 0
                    if condition { exec(yes) } else if let no { exec(no) }
                case .op(let name):
                    switch name {
                    case "add": let b = pop(), a = pop(); stack.append(a + b)
                    case "sub": let b = pop(), a = pop(); stack.append(a - b)
                    case "mul": let b = pop(), a = pop(); stack.append(a * b)
                    case "div": let b = pop(), a = pop(); stack.append(b == 0 ? 0 : a / b)
                    case "idiv": let b = pop(), a = pop(); stack.append(b == 0 ? 0 : Double(Int(a) / Int(b)))
                    case "mod": let b = pop(), a = pop(); stack.append(b == 0 ? 0 : Double(Int(a) % Int(b)))
                    case "neg": stack.append(-pop())
                    case "abs": stack.append(abs(pop()))
                    case "ceiling": stack.append(pop().rounded(.up))
                    case "floor": stack.append(pop().rounded(.down))
                    case "round": stack.append(pop().rounded())
                    case "truncate": stack.append(pop().rounded(.towardZero))
                    case "cvi": stack.append(pop().rounded(.towardZero))
                    case "cvr": break
                    case "sqrt": stack.append(pop().squareRoot())
                    case "sin": stack.append(sin(pop() * .pi / 180))
                    case "cos": stack.append(cos(pop() * .pi / 180))
                    case "atan":
                        let b = pop(), a = pop()
                        var d = atan2(a, b) * 180 / .pi
                        if d < 0 { d += 360 }
                        stack.append(d)
                    case "exp": let b = pop(), a = pop(); stack.append(pow(a, b))
                    case "ln": stack.append(log(max(pop(), 1e-30)))
                    case "log": stack.append(log10(max(pop(), 1e-30)))
                    case "eq": let b = pop(), a = pop(); stack.append(a == b ? 1 : 0)
                    case "ne": let b = pop(), a = pop(); stack.append(a != b ? 1 : 0)
                    case "gt": let b = pop(), a = pop(); stack.append(a > b ? 1 : 0)
                    case "ge": let b = pop(), a = pop(); stack.append(a >= b ? 1 : 0)
                    case "lt": let b = pop(), a = pop(); stack.append(a < b ? 1 : 0)
                    case "le": let b = pop(), a = pop(); stack.append(a <= b ? 1 : 0)
                    case "and": let b = Int(pop()), a = Int(pop()); stack.append(Double(a & b))
                    case "or": let b = Int(pop()), a = Int(pop()); stack.append(Double(a | b))
                    case "xor": let b = Int(pop()), a = Int(pop()); stack.append(Double(a ^ b))
                    case "not":
                        let a = pop()
                        stack.append(a == 0 ? 1 : (a == 1 ? 0 : Double(~Int(a))))
                    case "bitshift":
                        let s = Int(pop()), a = Int(pop())
                        stack.append(Double(s >= 0 ? a << s : a >> -s))
                    case "true": stack.append(1)
                    case "false": stack.append(0)
                    case "dup": let a = pop(); stack.append(a); stack.append(a)
                    case "pop": _ = pop()
                    case "exch": let b = pop(), a = pop(); stack.append(b); stack.append(a)
                    case "copy":
                        let n = Int(pop())
                        if n > 0 && n <= stack.count { stack.append(contentsOf: stack.suffix(n)) }
                    case "index":
                        let n = Int(pop())
                        if n >= 0 && n < stack.count { stack.append(stack[stack.count - 1 - n]) }
                    case "roll":
                        let j = Int(pop()), n = Int(pop())
                        if n > 0 && n <= stack.count {
                            var part = Array(stack.suffix(n))
                            stack.removeLast(n)
                            let shift = ((j % n) + n) % n
                            part = Array(part[(n - shift)...] + part[..<(n - shift)])
                            stack.append(contentsOf: part)
                        }
                    default: break
                    }
                }
            }
        }
        exec(program)
        return stack
    }
}

// MARK: - Shadings

/// An axial or radial shading as an SVG gradient: its geometry in shading space and sampled stops.
struct PDFSVGGradient {
    let linear: Bool
    /// x0 y0 x1 y1 (axial) or x0 y0 r0 x1 y1 r1 (radial).
    let coords: [CGFloat]
    let stops: [(offset: CGFloat, color: String)]
    let extendStart: Bool
    let extendEnd: Bool
    let bbox: CGRect?

    /// nil for shading types SVG can't express (function-based and mesh shadings).
    static func make(_ shading: CGPDFDictionaryRef, lookup: (String) -> CGPDFObjectRef?) -> PDFSVGGradient? {
        guard let type = PDFSVGObj.int(shading, "ShadingType"), type == 2 || type == 3,
              let spaceObject = PDFSVGObj.object(shading, "ColorSpace", "CS"),
              let space = PDFSVGColorSpace.parse(spaceObject, lookup: lookup),
              let functionObject = PDFSVGObj.object(shading, "Function"),
              let function = PDFSVGFunction.parse(functionObject) else { return nil }
        let coords = PDFSVGObj.numbers(PDFSVGObj.array(shading, "Coords"))
        guard coords.count == (type == 2 ? 4 : 6) else { return nil }
        var domain = PDFSVGObj.numbers(PDFSVGObj.array(shading, "Domain"))
        if domain.count != 2 { domain = [0, 1] }
        var extend: [Bool] = [false, false]
        if let a = PDFSVGObj.array(shading, "Extend"), CGPDFArrayGetCount(a) == 2 {
            for i in 0..<2 { var b: CGPDFBoolean = 0; if CGPDFArrayGetBoolean(a, i, &b) { extend[i] = b != 0 } }
        }
        // Sample the function, add its stitching points, then drop stops a straight blend reproduces.
        var ts = (0...32).map { CGFloat($0) / 32 }
        for b in function.breakpoints where b > domain[0] && b < domain[1] {
            let t = (b - domain[0]) / (domain[1] - domain[0])
            ts += [max(0, t - 0.0005), t, min(1, t + 0.0005)]
        }
        ts = Array(Set(ts.map { ($0 * 10000).rounded() / 10000 })).sorted()
        var samples: [(CGFloat, (CGFloat, CGFloat, CGFloat))] = ts.map { t in
            (t, space.rgb(function.evaluate([domain[0] + t * (domain[1] - domain[0])])))
        }
        var i = 1
        while i < samples.count - 1 {
            let (t0, a) = samples[i - 1], (t1, b) = samples[i], (t2, c) = samples[i + 1]
            let f = t2 == t0 ? 0 : (t1 - t0) / (t2 - t0)
            let close = abs(a.0 + (c.0 - a.0) * f - b.0) < 0.004 && abs(a.1 + (c.1 - a.1) * f - b.1) < 0.004
                && abs(a.2 + (c.2 - a.2) * f - b.2) < 0.004
            if close { samples.remove(at: i) } else { i += 1 }
        }
        let stops = samples.map { (offset: $0.0, color: PDFSVGColorSpace.hex($0.1.0, $0.1.1, $0.1.2)) }
        return PDFSVGGradient(linear: type == 2, coords: coords, stops: stops, extendStart: extend[0],
                              extendEnd: extend[1], bbox: PDFSVGObj.rect(PDFSVGObj.array(shading, "BBox")))
    }
}
