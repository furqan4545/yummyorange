import AppKit
import ImageIO
import Vision

/// "Read QR Code": finds QR codes and every other symbology Vision knows (Aztec, Data Matrix, PDF417,
/// EAN/UPC, Code 128 and more) and saves what they say to "<name> codes.txt".
enum BarcodeReader {
    struct Code: Equatable {
        /// "QR", "EAN13", "Code128"…
        var kind: String
        var payload: String
        /// Vision's normalized box (origin bottom-left), for reading order.
        var box: CGRect

        static func == (a: Code, b: Code) -> Bool { a.kind == b.kind && a.payload == b.payload }
    }

    /// Runs on every image; app mode copies the payloads and shows them in the HUD (copy=false turns
    /// copying off; on the command line copying is off unless copy=true).
    static func run(_ files: [URL], options: ToolOptions, progress: @escaping (Double) -> Void) throws -> [URL] {
        let appMode = MainThread.sync { NSApp != nil && NSApp.activationPolicy() != .prohibited }
        let copy = options.bool("copy", appMode)
        var outputs: [URL] = [], found: [String] = [], empty: [String] = [], failures: [String] = []
        for (i, url) in files.enumerated() {
            do {
                let codes = try read(url)
                if codes.isEmpty {
                    empty.append(url.lastPathComponent)
                } else {
                    let out = outputURL(for: url, ext: "txt", suffix: " codes")
                    try text(codes).write(to: out, atomically: true, encoding: .utf8)
                    outputs.append(out)
                    found += codes.map(\.payload)
                }
            } catch {
                failures.append(files.count == 1 ? error.localizedDescription : "\(url.lastPathComponent): \(error.localizedDescription)")
            }
            progress(Double(i + 1) / Double(files.count))
        }
        if found.isEmpty {
            if let failure = failures.first, empty.isEmpty { throw ConversionError.toolFailed(failure) }
            let what = files.count == 1 ? files[0].lastPathComponent : "these images"
            throw ConversionError.unsupported("No QR code or barcode found in \(what). Try a sharper, straighter picture with the whole code in view.")
        }
        let skipped = empty + failures
        if copy {
            MainThread.sync {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(found.joined(separator: "\n"), forType: .string)
            }
        }
        if appMode {
            let first = found[0].replacingOccurrences(of: "\n", with: " ")
            var message = (copy ? "Copied: " : "Found: ") + (found.count == 1 ? first : "\(found.count) codes — \(first)")
            if !skipped.isEmpty { message += "  (nothing in \(skipped.count == 1 ? skipped[0] : "\(skipped.count) images"))" }
            // After the job's own “Saved …” message.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { HUD.shared.flash(message, seconds: 5) }
        } else if !skipped.isEmpty {
            FileHandle.standardError.write("No codes in: \(skipped.joined(separator: ", "))\n".data(using: .utf8)!)
        }
        return outputs
    }

    /// One payload per line; codes whose text spans several lines are separated by a blank line.
    static func text(_ codes: [Code]) -> String {
        let multiline = codes.contains { $0.payload.contains("\n") }
        return codes.map(\.payload).joined(separator: multiline ? "\n\n" : "\n") + "\n"
    }

    /// Every code in the image (each page or frame of a multi-image file, up to 50), top to bottom.
    static func read(_ url: URL) throws -> [Code] {
        let src = try Converter.source(url)
        let count = min(CGImageSourceGetCount(src), 50)
        var codes: [Code] = []
        for index in 0..<count {
            let image: CGImage
            if index == 0 {
                image = try Converter.orientedImage(src, maxPixels: 4096)
            } else {
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                             kCGImageSourceCreateThumbnailWithTransform: true,
                                             kCGImageSourceThumbnailMaxPixelSize: 4096]
                guard let frame = CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary) else { continue }
                image = frame
            }
            for code in try detect(in: image) where !codes.contains(code) { codes.append(code) }
        }
        return codes
    }

    /// Tries the picture as is (on white, so transparent codes read), then with a quiet zone added and
    /// small codes enlarged without smoothing, then with colours inverted (light codes on dark).
    static func detect(in image: CGImage) throws -> [Code] {
        let plain = try prepared(image, invert: false, quietZone: false)
        var codes = try vision(plain)
        if codes.isEmpty { codes = try vision(try prepared(image, invert: false, quietZone: true)) }
        if codes.isEmpty { codes = try vision(try prepared(image, invert: true, quietZone: true)) }
        return codes.sorted { a, b in
            abs(a.box.midY - b.box.midY) > 0.02 ? a.box.midY > b.box.midY : a.box.minX < b.box.minX
        }
    }

    private static func vision(_ image: CGImage) throws -> [Code] {
        let request = VNDetectBarcodesRequest()
        if let all = try? request.supportedSymbologies(), !all.isEmpty { request.symbologies = all }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var codes: [Code] = []
        for obs in request.results ?? [] {
            guard let payload = payload(of: obs), !payload.isEmpty else { continue }
            let kind = obs.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
            let code = Code(kind: kind, payload: payload, box: obs.boundingBox)
            if !codes.contains(code) { codes.append(code) }
        }
        return codes
    }

    /// The decoded text; binary payloads (macOS 14+) as text when they're UTF-8, else as hex.
    private static func payload(of obs: VNBarcodeObservation) -> String? {
        if let s = obs.payloadStringValue { return s }
        if #available(macOS 14.0, *), let data = obs.payloadData, !data.isEmpty {
            if let s = String(data: data, encoding: .utf8) { return s }
            return "Binary data (\(data.count) bytes): " + data.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        return nil
    }

    /// The image on white, optionally inverted and with a white border of 10% (at least 32 px).
    /// Images under 1000 px get enlarged with nearest-neighbour scaling so module edges stay sharp.
    private static func prepared(_ image: CGImage, invert: Bool, quietZone: Bool) throws -> CGImage {
        let long = max(image.width, image.height)
        let scale = quietZone && long < 1000 ? CGFloat(max(1, 1000 / long)) : 1
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        let pad = quietZone ? max(32, (max(w, h) * 0.1).rounded()) : 0
        let width = Int(w + 2 * pad), height = Int(h + 2 * pad)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConversionError.toolFailed("Not enough memory to read this image.")
        }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = scale > 1 ? .none : .high
        ctx.draw(image, in: CGRect(x: pad, y: pad, width: w, height: h))
        if invert {
            ctx.setBlendMode(.difference)
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let result = ctx.makeImage() else { throw ConversionError.toolFailed("Couldn’t prepare the image.") }
        return result
    }
}
