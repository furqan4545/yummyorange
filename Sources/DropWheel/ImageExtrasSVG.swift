import AppKit
import Compression
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// SVG input for every image conversion and tool. The size comes from the root element (width, height,
/// viewBox); drawing uses the system's own SVG support (NSImage) and switches to an offscreen web view,
/// with every remote load blocked, for features NSImage doesn't draw (markers, tspans, CSS fonts,
/// foreignObject) or when NSImage can't read the file (macOS 13).
enum SVGRenderer {
    /// What the root `<svg>` element says about size, in points. Like NSImage, one user unit (px) is one point.
    struct Info: Equatable {
        var size: CGSize
        var viewBox: CGRect?
    }

    /// Bitmaps are drawn at 2× the SVG's own size (like a Retina screen), long edge at most 4096 px.
    static let rasterScale: CGFloat = 2
    static let maxRasterEdge: CGFloat = 4096

    // MARK: Reading the root element

    /// The SVG text and its size. A gzip-compressed file (.svgz) is unpacked first, so every caller (bitmaps,
    /// vector PDF, sizes) treats it like the plain SVG inside.
    static func load(_ url: URL) throws -> (data: Data, info: Info) {
        guard var data = try? Data(contentsOf: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
        if data.starts(with: [0x1F, 0x8B]) { data = try gunzip(data, name: url.lastPathComponent) }
        return (data, try info(of: data, name: url.lastPathComponent))
    }

    /// The most an .svgz may unpack to: a few kilobytes of gzip can expand to gigabytes.
    static let maxUnpackedSize = 256 << 20

    /// gzip (RFC 1952) → the bytes inside: the header is skipped and the DEFLATE body inflated, stopping
    /// with a clear message past `maxUnpackedSize` or at damaged data.
    static func gunzip(_ data: Data, name: String) throws -> Data {
        let damaged = ConversionError.unsupported("\(name) is a damaged compressed SVG (.svgz) file.")
        let b = [UInt8](data)
        guard b.count >= 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { throw damaged }
        let flags = b[3]
        var p = 10
        if flags & 4 != 0 { guard p + 2 <= b.count else { throw damaged }; p += 2 + (Int(b[p]) | Int(b[p + 1]) << 8) }
        if flags & 8 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }
        if flags & 16 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }
        if flags & 2 != 0 { p += 2 }
        guard p < b.count else { throw damaged }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw damaged
        }
        defer { compression_stream_destroy(stream) }
        let chunk = 1 << 16
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var out = Data()
        try b.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { throw damaged }
            stream.pointee.src_ptr = base + p
            stream.pointee.src_size = src.count - p
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                out.append(buffer, count: produced)
                guard out.count <= maxUnpackedSize else {
                    throw ConversionError.unsupported("\(name) unpacks to more than \(maxUnpackedSize >> 20) MB, too much for an SVG.")
                }
                if status == COMPRESSION_STATUS_END { return }
                // Out of input before the end of the DEFLATE stream: a truncated file.
                guard status == COMPRESSION_STATUS_OK, produced > 0 || stream.pointee.src_size > 0 else { throw damaged }
            }
        }
        return out
    }

    static func info(of data: Data, name: String) throws -> Info {
        guard !data.isEmpty else { throw ConversionError.unsupported("\(name) is empty.") }
        let reader = RootReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        parser.parse()
        guard let attributes = reader.attributes else {
            throw ConversionError.unsupported("\(name) isn’t a valid SVG file.")
        }
        guard reader.element == "svg" else {
            throw ConversionError.unsupported("\(name) isn’t an SVG image (it starts with <\(reader.element)>).")
        }
        let attrs = Dictionary(attributes.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        return info(width: attrs["width"], height: attrs["height"], viewBox: attrs["viewbox"])
    }

    /// The SVG's own size: width and height when both are absolute lengths; a missing one follows the
    /// viewBox's aspect ratio; with neither, the viewBox size; with nothing, 300 × 150 like a browser.
    static func info(width: String?, height: String?, viewBox: String?) -> Info {
        let box = viewBox.flatMap(parseViewBox)
        let w = length(width), h = length(height)
        var size: CGSize
        switch (w, h, box) {
        case let (w?, h?, _): size = CGSize(width: w, height: h)
        case let (w?, nil, box?): size = CGSize(width: w, height: w * box.height / box.width)
        case let (nil, h?, box?): size = CGSize(width: h * box.width / box.height, height: h)
        case let (nil, nil, box?): size = box.size
        default: size = CGSize(width: w ?? 300, height: h ?? 150)
        }
        size.width = min(max(size.width, 1), 100_000)
        size.height = min(max(size.height, 1), 100_000)
        return Info(size: size, viewBox: box)
    }

    /// An absolute SVG length in points (px = pt, like NSImage), or nil for percentages, "auto" and junk.
    static func length(_ text: String?) -> CGFloat? {
        guard var s = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return nil }
        let units: [(String, CGFloat)] = [("px", 1), ("pt", 1), ("pc", 12), ("in", 72), ("cm", 72 / 2.54),
                                         ("mm", 72 / 25.4), ("q", 72 / 101.6), ("em", 16), ("ex", 8)]
        var factor: CGFloat = 1
        if s.hasSuffix("%") { return nil }
        for (unit, f) in units where s.hasSuffix(unit) {
            s.removeLast(unit.count)
            factor = f
            break
        }
        guard let v = Double(s.trimmingCharacters(in: .whitespaces)), v.isFinite, v > 0 else { return nil }
        return CGFloat(v) * factor
    }

    static func parseViewBox(_ text: String) -> CGRect? {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .compactMap { Double($0) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0, parts.allSatisfy(\.isFinite) else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    /// Stops at the first element and keeps its name and attributes.
    private final class RootReader: NSObject, XMLParserDelegate {
        var element = ""
        var attributes: [String: String]?
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            element = (elementName.split(separator: ":").last.map(String.init) ?? elementName).lowercased()
            attributes = attributeDict
            parser.abortParsing()
        }
    }

    // MARK: Bitmaps

    /// The pixel size used when an SVG is converted or handed to an image tool, and its scale.
    static func defaultPixelSize(_ info: Info) -> (width: Int, height: Int, scale: CGFloat) {
        var scale = rasterScale
        let long = max(info.size.width, info.size.height)
        if long * scale > maxRasterEdge { scale = maxRasterEdge / long }
        return (max(1, Int((info.size.width * scale).rounded())), max(1, Int((info.size.height * scale).rounded())), scale)
    }

    /// Draws the SVG into a transparent bitmap of exactly `width` × `height` pixels.
    static func render(_ data: Data, info: Info, width: Int, height: Int, name: String) throws -> CGImage {
        if !needsWebKit(data), let image = try? drawWithNSImage(data, width: width, height: height),
           !isBlank(image) {
            return image
        }
        do {
            return try WebSVG.snapshot(data, pixelWidth: width, pixelHeight: height, name: name)
        } catch {
            // The web view couldn't draw it; NSImage's version (even if blank) is better than nothing, but
            // without linked images, which NSImage would draw as a red cross.
            if let image = try? drawWithNSImage(withoutLinkedImages(data), width: width, height: height) { return image }
            throw error
        }
    }

    /// NSImage's SVG support (CoreSVG). Nil when this macOS can't read SVG through NSImage.
    private static func drawWithNSImage(_ data: Data, width: Int, height: Int) throws -> CGImage? {
        guard let image = NSImage(data: data), image.isValid, image.size.width > 0, image.size.height > 0 else { return nil }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.toolFailed("Not enough memory for a \(width) × \(height) image.")
        }
        ctx.interpolationQuality = .high
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.current = previous
        return ctx.makeImage()
    }

    /// True when every pixel is fully transparent (the renderer drew nothing).
    static func isBlank(_ image: CGImage) -> Bool {
        let w = min(image.width, 256), h = min(image.height, 256)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let pixels = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return false }
        for i in stride(from: 3, to: w * h * 4, by: 4) where pixels[i] != 0 { return false }
        return true
    }

    /// Features NSImage's SVG support skips or gets wrong (checked on macOS 27: markers, tspan colours,
    /// CSS font rules, foreignObject), anything that points at the network, and `<image>`/`<feImage>`
    /// elements that aren't embedded data: NSImage draws a red cross for a linked file it can't show.
    /// Those go to the web view, where nothing outside the SVG loads, so a linked image is left out.
    static func needsWebKit(_ data: Data) -> Bool {
        let text = (String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)).lowercased()
        let tags = ["<marker", "marker-start", "marker-mid", "marker-end", "<tspan", "<foreignobject", "<textpath",
                    "<switch", "@import", "@font-face", "mix-blend-mode"]
        if tags.contains(where: text.contains) { return true }
        if text.contains("<text"), text.contains("<style") || text.contains("font-weight") || text.contains("font:") {
            return true
        }
        if !linkedImageTags(in: text).isEmpty { return true }
        return text.range(of: #"(href\s*=\s*["']\s*|url\(\s*["']?\s*)(https?:|ftp:|//)"#, options: .regularExpression) != nil
    }

    /// `<image>` and `<feImage>` elements (in lowercased SVG text) whose picture isn't a data: URL: a
    /// relative path, an absolute path, file:, a web address, or no href at all. Ranges cover the whole
    /// element, from `<image` to `/>` or to its closing tag.
    static func linkedImageTags(in text: String) -> [Range<String.Index>] {
        guard let element = try? NSRegularExpression(
            pattern: #"<(image|feimage)\b(?:[^>"']|"[^"]*"|'[^']*')*?(?:/>|>(?:[\s\S]*?</\1\s*>)?)"#) else { return [] }
        let embedded = #"\bhref\s*=\s*(["'])\s*data:"#
        let ns = text as NSString
        return element.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let tag = ns.substring(with: match.range)
            let openTag = tag.prefix(while: { $0 != ">" })
            if openTag.range(of: embedded, options: .regularExpression) != nil { return nil }
            return Range(match.range, in: text)
        }
    }

    /// The SVG without its linked (not embedded) `<image>`/`<feImage>` elements, for NSImage, which would
    /// draw each as a red cross. Unchanged when there are none or the text isn't UTF-8.
    static func withoutLinkedImages(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        // Lowercasing ASCII tag names keeps every index, so ranges found in the lowercased copy fit the original.
        let lower = String(text.map { $0.isASCII ? Character($0.lowercased()) : $0 })
        guard lower.utf16.count == text.utf16.count else { return data }
        let ranges = linkedImageTags(in: lower)
        guard !ranges.isEmpty else { return data }
        let original = NSMutableString(string: text)
        for range in ranges.reversed() { original.replaceCharacters(in: NSRange(range, in: lower), with: "") }
        return Data((original as String).utf8)
    }

    // MARK: PDF

    /// Writes the SVG as a vector PDF page of its own size. Returns false when neither renderer could.
    static func writePDF(_ data: Data, info: Info, to out: URL, name: String) -> Bool {
        if !needsWebKit(data), let image = NSImage(data: data), image.isValid, image.size.width > 0 {
            var box = CGRect(origin: .zero, size: info.size)
            if let ctx = CGContext(out as CFURL, mediaBox: &box, nil) {
                ctx.beginPDFPage(nil)
                let previous = NSGraphicsContext.current
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.current = previous
                ctx.endPDFPage()
                ctx.closePDF()
                return true
            }
        }
        guard let pdf = try? WebSVG.pdf(data, size: info.size, name: name) else { return false }
        do { try pdf.write(to: out); return true } catch { return false }
    }
}

// MARK: - Web view renderer

/// Shows the SVG in an offscreen WKWebView as an `<img>` with a data: URL. An SVG used as an image never
/// runs scripts or loads anything, and on top of that JavaScript is off, the page's Content-Security-Policy
/// allows only inline data, any navigation away is cancelled, and nothing is stored on disk.
final class WebSVG: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private let window: NSWindow
    private var loaded: ((Error?) -> Void)?

    /// An offscreen window; never shown.
    private static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -30_000, y: -30_000, width: 100, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// `cssSize` is the image's size on the page, in points.
    private init(data: Data, cssSize: CGSize, window: NSWindow = WebSVG.makeWindow()) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.suppressesIncrementalRendering = true
        let frame = CGRect(origin: .zero, size: cssSize)
        web = WKWebView(frame: frame, configuration: config)
        web.setValue(false, forKey: "drawsBackground")   // keep the SVG's transparency
        if #available(macOS 13.3, *) { web.isInspectable = false }
        self.window = window
        window.setContentSize(cssSize)
        // A subview keeps the exact frame even if the window's size gets limited.
        window.contentView?.addSubview(web)
        web.frame = frame
        super.init()
        web.navigationDelegate = self
        let w = WebSVG.css(cssSize.width), h = WebSVG.css(cssSize.height)
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}
        img{display:block;width:\(w)px;height:\(h)px}</style></head>
        <body><img alt="" src="data:image/svg+xml;base64,\(data.base64EncodedString())"></body></html>
        """
        web.loadHTMLString(html, baseURL: nil)
    }

    private static func css(_ v: CGFloat) -> String { String(format: "%.4f", Double(v)) }

    /// Main thread: waits for the page, then checks that the SVG decoded.
    private func whenReady(_ done: @escaping (Error?) -> Void) {
        loaded = { [weak self] error in
            guard let self else { return }
            if let error { done(error); return }
            // Runs in YummyOrange's own script world, which works even with the page's JavaScript off.
            self.web.callAsyncJavaScript("const i = document.images[0]; await i.decode(); return i.naturalWidth >= 0",
                                         arguments: [:], in: nil, in: .defaultClient) { result in
                if case .failure = result { done(ConversionError.unsupported("The SVG couldn’t be drawn (it may be damaged).")) }
                else { done(nil) }
            }
        }
    }

    private func close() {
        loaded = nil
        web.stopLoading()
        web.navigationDelegate = nil
        web.removeFromSuperview()
        window.close()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loaded?(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?(error)
    }

    /// Only the page itself (about:blank from loadHTMLString) and inline data may load.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? "about"
        decisionHandler(scheme == "about" || scheme == "data" ? .allow : .cancel)
    }

    // MARK: Entry points (any thread)

    /// A transparent bitmap of exactly `pixelWidth` × `pixelHeight`.
    static func snapshot(_ data: Data, pixelWidth: Int, pixelHeight: Int, name: String) throws -> CGImage {
        try MainThread.wait(timeout: 60) { (finish: @escaping (Result<CGImage, Error>) -> Void) in
            // Lay the page out so that one screen pixel of the window is one pixel of the result.
            let window = makeWindow()
            let backing = max(1, window.backingScaleFactor)
            let points = CGSize(width: CGFloat(pixelWidth) / backing, height: CGFloat(pixelHeight) / backing)
            let page = WebSVG(data: data, cssSize: points, window: window)
            page.whenReady { error in
                if let error { page.close(); finish(.failure(error)); return }
                let config = WKSnapshotConfiguration()
                config.rect = CGRect(origin: .zero, size: points)
                config.afterScreenUpdates = true
                page.web.takeSnapshot(with: config) { image, error in
                    defer { page.close() }
                    guard let image else {
                        finish(.failure(error ?? ConversionError.toolFailed("Couldn’t draw \(name).")))
                        return
                    }
                    // Whatever the screen scale was, hand back exactly the size asked for.
                    guard let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                        finish(.failure(ConversionError.toolFailed("Not enough memory for a \(pixelWidth) × \(pixelHeight) image.")))
                        return
                    }
                    var rect = CGRect(origin: .zero, size: image.size)
                    guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                        finish(.failure(ConversionError.toolFailed("Couldn’t draw \(name).")))
                        return
                    }
                    ctx.interpolationQuality = .high
                    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
                    if let result = ctx.makeImage() { finish(.success(result)) }
                    else { finish(.failure(ConversionError.toolFailed("Couldn’t draw \(name)."))) }
                }
            }
        }
    }

    /// A one-page vector PDF of `size` points.
    static func pdf(_ data: Data, size: CGSize, name: String) throws -> Data {
        try MainThread.wait(timeout: 60) { (finish: @escaping (Result<Data, Error>) -> Void) in
            let page = WebSVG(data: data, cssSize: size)
            page.whenReady { error in
                if let error { page.close(); finish(.failure(error)); return }
                let config = WKPDFConfiguration()
                config.rect = CGRect(origin: .zero, size: size)
                page.web.createPDF(configuration: config) { result in
                    page.close()
                    finish(result.mapError { $0 as Error })
                }
            }
        }
    }
}
