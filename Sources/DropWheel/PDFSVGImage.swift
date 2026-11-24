import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Turns PDF image XObjects (and inline images) into data URIs for SVG `<image>` elements.
/// JPEG data is passed through untouched when browsers can show it as is; everything else is decoded
/// with Core Graphics and written as PNG, or JPEG for large photographic images. Soft masks, stencil masks,
/// explicit masks and colour-key masks become transparency.
enum PDFSVGImage {
    struct Encoded {
        let href: String
        /// A separate alpha mask (white with alpha) when the colour stays JPEG.
        let maskHref: String?
    }

    /// The largest image side embedded; bigger images are scaled down.
    static let maxSide = 8000

    static func encode(_ stream: CGPDFStreamRef, inline: Bool, spaces: (CGPDFObjectRef) -> PDFSVGColorSpace?,
                       fill: (CGFloat, CGFloat, CGFloat), mode: String) -> Encoded? {
        guard let dict = CGPDFStreamGetDictionary(stream),
              let width = PDFSVGObj.int(dict, "Width", "W"), let height = PDFSVGObj.int(dict, "Height", "H"),
              width > 0, height > 0, width < 100_000, height < 100_000 else { return nil }
        let isStencil = PDFSVGObj.bool(dict, "ImageMask", "IM") ?? false
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }
        let decode = PDFSVGObj.numbers(PDFSVGObj.array(dict, "Decode", "D"))

        if isStencil {
            let inverted = decode.count >= 2 && decode[0] > decode[1]
            guard let alpha = bits(data, width: width, height: height, paintedValue: inverted ? 1 : 0) else { return nil }
            return png(rgba: solid(fill, alpha: alpha), width: width, height: height).map { Encoded(href: $0, maskHref: nil) }
        }

        let space = PDFSVGObj.object(dict, "ColorSpace", "CS").flatMap(spaces)
        let bpc = PDFSVGObj.int(dict, "BitsPerComponent", "BPC") ?? 8
        let softMask = PDFSVGObj.stream(dict, "SMask")
        let maskStream = PDFSVGObj.stream(dict, "Mask")
        let colorKey = PDFSVGObj.numbers(PDFSVGObj.array(dict, "Mask"))
        let hasAlpha = softMask != nil || maskStream != nil || !colorKey.isEmpty

        // JPEG that a browser shows the same way: gray or RGB, default decode, no colour key.
        if format == .jpegEncoded, colorKey.isEmpty, decode.isEmpty || isDefaultDecode(decode),
           let src = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let model = props[kCGImagePropertyColorModel] as? String,
           model == (kCGImagePropertyColorModelRGB as String) || model == (kCGImagePropertyColorModelGray as String),
           max(width, height) <= maxSide {
            let href = "data:image/jpeg;base64," + data.base64EncodedString()
            guard hasAlpha else { return Encoded(href: href, maskHref: nil) }
            guard let alpha = alphaChannel(dict, width: width, height: height, samples: nil, bpc: bpc, components: 0),
                  let mask = png(rgba: solid((1, 1, 1), alpha: alpha), width: width, height: height) else {
                return Encoded(href: href, maskHref: nil)
            }
            return Encoded(href: href, maskHref: mask)
        }

        // Decode to a CGImage.
        var image: CGImage?
        var samples: [UInt8]?   // 8-bit samples, for colour keys
        var components = space?.components ?? 3
        switch format {
        case .jpegEncoded, .JPEG2000:
            if let src = CGImageSourceCreateWithData(data as CFData, nil) { image = CGImageSourceCreateImageAtIndex(src, 0, nil) }
            components = image?.colorSpace?.numberOfComponents ?? components
        default:
            guard let space else { return nil }
            components = space.components
            let unpacked = unpack(data, width: width, height: height, components: components, bpc: bpc,
                                  keepIndices: { if case .indexed = space.kind { return true }; return false }())
            samples = unpacked
            image = makeImage(unpacked, width: width, height: height, space: space, bpc: bpc, decode: decode)
        }
        guard let image else { return nil }

        // Draw into sRGB at (at most) the embedded size and apply transparency.
        let scale = min(1, CGFloat(maxSide) / CGFloat(max(width, height)))
        let w = max(1, Int(CGFloat(width) * scale)), h = max(1, Int(CGFloat(height) * scale))
        var alpha: [UInt8]? = nil
        if hasAlpha { alpha = alphaChannel(dict, width: w, height: h, samples: scale == 1 ? samples : nil, bpc: bpc, components: components) }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else { return nil }
        let pixels = base.bindMemory(to: UInt8.self, capacity: w * h * 4)
        if let alpha {
            for i in 0..<(w * h) {
                let a = UInt16(alpha[i])
                if a == 255 { continue }
                pixels[i * 4] = UInt8(UInt16(pixels[i * 4]) * a / 255)
                pixels[i * 4 + 1] = UInt8(UInt16(pixels[i * 4 + 1]) * a / 255)
                pixels[i * 4 + 2] = UInt8(UInt16(pixels[i * 4 + 2]) * a / 255)
                pixels[i * 4 + 3] = UInt8(a)
            }
        }
        guard let final = ctx.makeImage() else { return nil }
        return encodeFinal(final, opaque: alpha == nil, mode: mode).map { Encoded(href: $0, maskHref: nil) }
    }

    private static func isDefaultDecode(_ d: [CGFloat]) -> Bool {
        stride(from: 0, to: d.count - 1, by: 2).allSatisfy { d[$0] == 0 && d[$0 + 1] == 1 }
    }

    /// PNG, or JPEG for big photographic images (PNG over a byte per pixel and JPEG under half of it).
    private static func encodeFinal(_ image: CGImage, opaque: Bool, mode: String) -> String? {
        let pixels = image.width * image.height
        if opaque && mode == "jpeg", let jpeg = write(image, type: UTType.jpeg.identifier, quality: 0.9) {
            return "data:image/jpeg;base64," + jpeg.base64EncodedString()
        }
        guard let pngData = write(opaque ? flatten(image) ?? image : image, type: UTType.png.identifier) else { return nil }
        if opaque && mode == "auto" && pixels > 250_000 && pngData.count > pixels,
           let jpeg = write(image, type: UTType.jpeg.identifier, quality: 0.9), jpeg.count * 2 < pngData.count {
            return "data:image/jpeg;base64," + jpeg.base64EncodedString()
        }
        return "data:image/png;base64," + pngData.base64EncodedString()
    }

    /// Opaque images as RGB (no alpha channel) so their PNGs are smaller.
    private static func flatten(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    private static func write(_ image: CGImage, type: String, quality: Double = 1) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static func png(rgba: [UInt8], width: Int, height: Int) -> String? {
        var buffer = rgba
        let image: CGImage? = buffer.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let image, let data = write(image, type: UTType.png.identifier) else { return nil }
        return "data:image/png;base64," + data.base64EncodedString()
    }

    /// Premultiplied RGBA of one colour with per-pixel alpha.
    private static func solid(_ c: (CGFloat, CGFloat, CGFloat), alpha: [UInt8]) -> [UInt8] {
        let r = UInt16(min(255, max(0, c.0 * 255))), g = UInt16(min(255, max(0, c.1 * 255))), b = UInt16(min(255, max(0, c.2 * 255)))
        var out = [UInt8](repeating: 0, count: alpha.count * 4)
        for (i, a8) in alpha.enumerated() where a8 > 0 {
            let a = UInt16(a8)
            out[i * 4] = UInt8(r * a / 255); out[i * 4 + 1] = UInt8(g * a / 255)
            out[i * 4 + 2] = UInt8(b * a / 255); out[i * 4 + 3] = a8
        }
        return out
    }

    /// 1-bit samples → alpha: 255 where the sample equals `paintedValue`.
    private static func bits(_ data: Data, width: Int, height: Int, paintedValue: UInt8) -> [UInt8]? {
        let rowBytes = (width + 7) / 8
        let bytes = [UInt8](data)
        var alpha = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * rowBytes + x / 8
                let bit = index < bytes.count ? (bytes[index] >> (7 - UInt8(x % 8))) & 1 : 1
                if bit == paintedValue { alpha[y * width + x] = 255 }
            }
        }
        return alpha
    }

    /// Samples as one byte each. Values below 8 bits are scaled to 0…255 (or kept as palette indices);
    /// 16-bit samples keep their high byte.
    private static func unpack(_ data: Data, width: Int, height: Int, components: Int, bpc: Int, keepIndices: Bool) -> [UInt8] {
        let count = width * height * components
        let bytes = [UInt8](data)
        if bpc == 8 {
            return bytes.count >= count ? Array(bytes.prefix(count)) : bytes + [UInt8](repeating: 0, count: count - bytes.count)
        }
        var out = [UInt8](repeating: 0, count: count)
        let rowBits = width * components * bpc
        let rowBytes = (rowBits + 7) / 8
        let maxValue = (1 << min(bpc, 16)) - 1
        for y in 0..<height {
            for i in 0..<(width * components) {
                let bitOffset = y * rowBytes * 8 + i * bpc
                var v = 0
                if bpc == 16 {
                    let byte = bitOffset / 8
                    v = byte < bytes.count ? Int(bytes[byte]) : 0
                    out[y * width * components + i] = UInt8(v)
                    continue
                }
                for b in 0..<bpc {
                    let bit = bitOffset + b
                    let byte = bit / 8
                    let value = byte < bytes.count ? (Int(bytes[byte]) >> (7 - bit % 8)) & 1 : 0
                    v = (v << 1) | value
                }
                out[y * width * components + i] = keepIndices ? UInt8(min(255, v)) : UInt8(v * 255 / max(1, maxValue))
            }
        }
        return out
    }

    /// 8-bit samples → CGImage. Spaces Core Graphics can't take (Separation, DeviceN) go through
    /// their tint transform pixel by pixel, with a lookup table for single-channel tints.
    private static func makeImage(_ samples: [UInt8], width: Int, height: Int, space: PDFSVGColorSpace, bpc: Int,
                                  decode: [CGFloat]) -> CGImage? {
        let n = space.components
        var decodeArray: [CGFloat]? = nil
        if !decode.isEmpty && decode.count == n * 2 {
            if case .indexed = space.kind {
                if bpc < 8 || decode != [0, CGFloat((1 << bpc) - 1)] {
                    // Index decode arrays only shift indices; keep the default unless inverted.
                    if decode[0] > decode[1] { decodeArray = [255, 0] }
                }
            } else if !isDefaultDecode(decode) {
                decodeArray = decode
            }
        }
        if let cg = space.cgSpace {
            let provider = CGDataProvider(data: Data(samples) as CFData)!
            return decodeArray.pdfsvgWithBuffer { ptr in
                CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * n, bytesPerRow: width * n,
                        space: cg, bitmapInfo: [], provider: provider, decode: ptr, shouldInterpolate: true, intent: .defaultIntent)
            }
        }
        // Manual conversion to RGB.
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        var table: [[UInt8]] = []
        if n == 1 {
            table = (0..<256).map { v in
                var t = CGFloat(v) / 255
                if let d = decodeArray, d.count == 2 { t = d[0] + t * (d[1] - d[0]) }
                let c = space.rgb([t])
                return [UInt8(c.0 * 255), UInt8(c.1 * 255), UInt8(c.2 * 255)]
            }
        }
        var cache: [[UInt8]: [UInt8]] = [:]
        for i in 0..<(width * height) {
            let px: [UInt8]
            if n == 1 {
                px = table[Int(samples[i])]
            } else {
                let key = Array(samples[(i * n)..<(i * n + n)])
                if let hit = cache[key] { px = hit } else {
                    let c = space.rgb(key.map { CGFloat($0) / 255 })
                    px = [UInt8(c.0 * 255), UInt8(c.1 * 255), UInt8(c.2 * 255)]
                    if cache.count < 65536 { cache[key] = px }
                }
            }
            rgb[i * 3] = px[0]; rgb[i * 3 + 1] = px[1]; rgb[i * 3 + 2] = px[2]
        }
        let provider = CGDataProvider(data: Data(rgb) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: [], provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Alpha for `width`×`height` pixels from /SMask, a /Mask stencil or a /Mask colour-key array.
    private static func alphaChannel(_ dict: CGPDFDictionaryRef, width: Int, height: Int, samples: [UInt8]?, bpc: Int,
                                     components: Int) -> [UInt8]? {
        func gray(_ image: CGImage) -> [UInt8]? {
            var out = [UInt8](repeating: 0, count: width * height)
            let ok: Bool = out.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            return ok ? out : nil
        }
        if let smask = PDFSVGObj.stream(dict, "SMask"), let md = CGPDFStreamGetDictionary(smask),
           let mw = PDFSVGObj.int(md, "Width"), let mh = PDFSVGObj.int(md, "Height"), mw > 0, mh > 0 {
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(smask, &format) as Data? else { return nil }
            var image: CGImage?
            if format != .raw, let src = CGImageSourceCreateWithData(data as CFData, nil) {
                image = CGImageSourceCreateImageAtIndex(src, 0, nil)
            } else {
                let mbpc = PDFSVGObj.int(md, "BitsPerComponent") ?? 8
                let samples = unpack(data, width: mw, height: mh, components: 1, bpc: mbpc, keepIndices: false)
                let decode = PDFSVGObj.numbers(PDFSVGObj.array(md, "Decode"))
                let provider = CGDataProvider(data: Data(samples) as CFData)!
                let d: [CGFloat]? = decode.count == 2 && decode[0] > decode[1] ? [1, 0] : nil
                image = d.pdfsvgWithBuffer { ptr in
                    CGImage(width: mw, height: mh, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: mw,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: ptr,
                            shouldInterpolate: true, intent: .defaultIntent)
                }
            }
            return image.flatMap(gray)
        }
        if let mask = PDFSVGObj.stream(dict, "Mask"), let md = CGPDFStreamGetDictionary(mask),
           let mw = PDFSVGObj.int(md, "Width"), let mh = PDFSVGObj.int(md, "Height"), mw > 0, mh > 0,
           let data = PDFSVGObj.data(mask) {
            let decode = PDFSVGObj.numbers(PDFSVGObj.array(md, "Decode"))
            let inverted = decode.count >= 2 && decode[0] > decode[1]
            guard let alpha = bits(data, width: mw, height: mh, paintedValue: inverted ? 1 : 0) else { return nil }
            let provider = CGDataProvider(data: Data(alpha) as CFData)!
            guard let image = CGImage(width: mw, height: mh, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: mw,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil,
                                      shouldInterpolate: false, intent: .defaultIntent) else { return nil }
            return gray(image)
        }
        let key = PDFSVGObj.numbers(PDFSVGObj.array(dict, "Mask"))
        if let samples, key.count == components * 2, components > 0 {
            let scale: CGFloat = bpc < 8 ? 255 / CGFloat((1 << bpc) - 1) : bpc == 16 ? 1 / 256 : 1
            var alpha = [UInt8](repeating: 255, count: width * height)
            for i in 0..<(width * height) {
                var inside = true
                for c in 0..<components {
                    let v = CGFloat(samples[i * components + c])
                    if v < (key[2 * c] * scale).rounded(.down) || v > (key[2 * c + 1] * scale).rounded(.up) { inside = false; break }
                }
                if inside { alpha[i] = 0 }
            }
            return alpha
        }
        return nil
    }
}

extension Optional where Wrapped == [CGFloat] {
    /// Calls `body` with a pointer to the array's storage, or nil.
    func pdfsvgWithBuffer<R>(_ body: (UnsafePointer<CGFloat>?) -> R) -> R {
        switch self {
        case .some(let array): return array.withUnsafeBufferPointer { body($0.baseAddress) }
        case .none: return body(nil)
        }
    }
}
