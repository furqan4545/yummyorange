import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// PowerPoint: PPTX (and PPT) → PDF and images; PDF and images → PPTX.
/// Everything is drawn by YummyOrange's own renderer (PPTXRender.swift); nothing needs Office or Keynote.
enum Presentations: FeatureModule {
    /// Decks the renderer reads: the shared presentation extensions plus macro-enabled and template variants.
    static let decks: Set<String> = Ext.presentations.union(["pptm", "ppsm", "potx", "potm", "pot"])
    /// Legacy binary decks (PowerPoint 97–2003).
    static let binaryDecks: Set<String> = ["ppt", "pps", "pot"]

    static var commands: [WheelCommand] {
        [
            WheelCommand(wheel: .convert, id: "pdf", title: "PDF", applies: { Ext.all($0, in: decks) },
                         run: { files, options, progress in try each(files, progress) { try toPDF($0, options: options, progress: $1) } }),
            WheelCommand(wheel: .convert, id: "png", title: "PNG", applies: { Ext.all($0, in: decks) },
                         run: { files, options, progress in
                             try each(files, progress) { try toImages($0, type: .png, options: options, progress: $1) } }),
            WheelCommand(wheel: .convert, id: "jpg", title: "JPG", applies: { Ext.all($0, in: decks) },
                         run: { files, options, progress in
                             try each(files, progress) { try toImages($0, type: .jpeg, options: options, progress: $1) } }),
            WheelCommand(wheel: .convert, id: "pptx", title: "PPTX", applies: { Ext.all($0, in: ["pdf"]) },
                         run: { files, options, progress in try each(files, progress) { [try fromPDF($0, options: options, progress: $1)] } }),
            WheelCommand(wheel: .convert, id: "pptx", title: "PPTX", combinesInputs: true, applies: isImageSelection,
                         run: { files, options, progress in [try fromImages(files, options: options, progress: progress)] }),
            WheelCommand(wheel: .convert, id: "pptx", title: "PPTX", applies: { Ext.all($0, in: binaryDecks) },
                         run: { files, options, progress in try each(files, progress) { [try fromPPT($0, progress: $1)] } }),
            WheelCommand(wheel: .tools, id: "slide-text", title: "Slide Text", symbol: "text.alignleft",
                         applies: { Ext.all($0, in: decks) },
                         run: { files, options, progress in try each(files, progress) { url, _ in [try extractText(url, options: options)] } }),
        ]
    }

    /// Images the image → PPTX petal accepts (ImageIO formats, SVG and camera RAW go through Converter.source).
    private static func isImageSelection(_ files: [URL]) -> Bool {
        !files.isEmpty && files.allSatisfy { FileKind.of($0) == .image || Ext.svg.contains(Ext.of($0)) }
    }

    /// Runs `work` for each file, splitting the progress range between them.
    private static func each(_ files: [URL], _ progress: @escaping (Double) -> Void,
                             _ work: (URL, @escaping (Double) -> Void) throws -> [URL]) throws -> [URL] {
        var out: [URL] = []
        for (i, f) in files.enumerated() {
            let base = Double(i) / Double(files.count), span = 1 / Double(files.count)
            out += try work(f) { progress(base + span * min(1, max(0, $0))) }
        }
        return out
    }

    // MARK: Slide selection

    /// Slides to export: `slides=2-4,7` picks by slide number; hidden slides only with `hidden=true`.
    static func selectedSlides(_ deck: PPTXDeck, options: ToolOptions) throws -> [PPTXDeck.Slide] {
        guard !deck.slides.isEmpty else { throw ConversionError.unsupported("This presentation has no slides.") }
        var list = deck.slides
        if !options.bool("hidden", false) { list = list.filter { !$0.hidden } }
        let spec = options.string("slides", "")
        if !spec.isEmpty, spec.lowercased() != "all" {
            var wanted = Set<Int>()
            for part in spec.split(separator: ",") {
                let bits = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if bits.count == 2 {
                    let lo = Int(bits[0]) ?? 1, hi = Int(bits[1]) ?? deck.slides.count
                    if lo <= hi { wanted.formUnion(lo...hi) }
                } else if let n = Int(bits[0]) { wanted.insert(n) }
            }
            list = list.filter { wanted.contains($0.number) }
        }
        guard !list.isEmpty else {
            throw ConversionError.unsupported(deck.slides.allSatisfy(\.hidden)
                ? "Every slide in this presentation is hidden."
                : "None of the chosen slides are in this presentation.")
        }
        return list
    }

    // MARK: PPTX → PDF / images

    static func toPDF(_ url: URL, options: ToolOptions, progress: @escaping (Double) -> Void) throws -> [URL] {
        let deck = try PPTXDeck.open(url)
        let slides = try selectedSlides(deck, options: options)
        let renderer = PPTXRenderer(deck)
        let out = outputURL(for: url, ext: "pdf")
        var box = CGRect(origin: .zero, size: deck.size)
        let info: [CFString: Any] = [kCGPDFContextTitle: deck.title ?? url.deletingPathExtension().lastPathComponent,
                                     kCGPDFContextCreator: "YummyOrange"]
        guard let ctx = CGContext(out as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw ConversionError.toolFailed("Couldn’t create \(out.lastPathComponent).")
        }
        for (i, slide) in slides.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: deck.size.height)
            ctx.scaleBy(x: 1, y: -1)
            renderer.draw(slide, in: ctx, pixelScale: 2, pdf: true)
            ctx.restoreGState()
            ctx.endPDFPage()
            progress(Double(i + 1) / Double(slides.count))
        }
        ctx.closePDF()
        return [out]
    }

    /// Renders one slide to a bitmap at `scale` pixels per point (on white).
    static func renderImage(_ renderer: PPTXRenderer, _ slide: PPTXDeck.Slide, scale: CGFloat) throws -> CGImage {
        let size = renderer.deck.size
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.toolFailed("Not enough memory to render a \(w) × \(h) slide.")
        }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.setShouldSmoothFonts(false)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(w) / size.width, y: -CGFloat(h) / size.height)
        renderer.draw(slide, in: ctx, pixelScale: scale, pdf: false)
        guard let image = ctx.makeImage() else { throw ConversionError.toolFailed("Couldn’t render the slide.") }
        return image
    }

    static func toImages(_ url: URL, type: UTType, options: ToolOptions, progress: @escaping (Double) -> Void) throws -> [URL] {
        let deck = try PPTXDeck.open(url)
        let slides = try selectedSlides(deck, options: options)
        let renderer = PPTXRenderer(deck)
        // 144 dpi by default (1920 px wide for a 16:9 slide); `width=` sets the pixel width instead.
        var scale = CGFloat(min(600, max(18, options.double("dpi", 144)))) / 72
        if let w = options["width"].flatMap(Double.init), w > 0 { scale = CGFloat(w) / deck.size.width }
        let longest = max(deck.size.width, deck.size.height) * scale
        if longest > 10000 { scale *= 10000 / longest }
        let ext = type == .png ? "png" : "jpg"
        var outputs: [URL] = []
        for (i, slide) in slides.enumerated() {
            let image = try renderImage(renderer, slide, scale: scale)
            let suffix = slides.count > 1 || deck.slides.count > 1 ? " slide \(slide.number)" : ""
            let out = outputURL(for: url, ext: ext, suffix: suffix)
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
                throw ConversionError.toolFailed("Couldn’t create \(out.lastPathComponent).")
            }
            let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: options.double("quality", 0.9),
                                          kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw ConversionError.toolFailed("Couldn’t save \(out.lastPathComponent).") }
            outputs.append(out)
            progress(Double(i + 1) / Double(slides.count))
        }
        return outputs
    }

    // MARK: Text

    static func extractText(_ url: URL, options: ToolOptions) throws -> URL {
        let deck = try PPTXDeck.open(url)
        var out = ""
        for slide in deck.slides where options.bool("hidden", true) || !slide.hidden {
            out += "Slide \(slide.number)\(slide.hidden ? " (hidden)" : "")\n"
            let text = deck.text(of: slide)
            out += text.isEmpty ? "" : text + "\n"
            if options.bool("notes", true), let notes = deck.pkg.rel(slide.part, kind: "notesSlide"),
               let root = deck.pkg.xml(notes.target) {
                // Speaker notes live in the notes slide's body placeholder.
                let body = root.descendants("p:sp").filter { PPTXDeck.placeholder(of: $0)?.type == "body" }
                let lines = body.flatMap { $0.descendants("a:p") }.map { p in
                    p.children.map { $0.name == "a:br" ? "\n" : ($0.child("a:t")?.text ?? "") }.joined()
                }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if !lines.isEmpty { out += "Notes:\n" + lines.joined(separator: "\n") + "\n" }
            }
            out += "\n"
        }
        let dest = outputURL(for: url, ext: "txt")
        try out.write(to: dest, atomically: true, encoding: .utf8)
        return dest
    }

    // MARK: → PPTX

    /// One slide per page, each page a full-slide picture rendered at about 200 dpi.
    static func fromPDF(_ url: URL, options: ToolOptions, progress: @escaping (Double) -> Void) throws -> URL {
        guard let doc = CGPDFDocument(url as CFURL) else { throw ConversionError.unreadable(url.lastPathComponent) }
        if doc.isEncrypted && !doc.isUnlocked && !doc.unlockWithPassword("") {
            throw ConversionError.unsupported("This PDF is password-protected. Remove the password first.")
        }
        guard doc.numberOfPages > 0, let first = doc.page(at: 1) else { throw ConversionError.unsupported("This PDF has no pages.") }
        let dpi = CGFloat(min(400, max(72, options.double("dpi", 200))))
        // image=auto (default) keeps PNG for text and drawings and switches to JPEG for photo-like pages.
        let format = options.string("image", "auto").lowercased()
        func pageSize(_ p: CGPDFPage) -> CGSize {
            let box = p.getBoxRect(.cropBox)
            let turns = ((p.rotationAngle % 360) + 360) % 360 / 90
            return turns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
        }
        let firstSize = pageSize(first)
        // The same file through PDFKit, for the annotations (filled-in form fields, stamps, notes, highlights)
        // that Core Graphics leaves out when it draws a page.
        let annotated = PDFDocument(url: url)
        let writer = PPTXWriter(width: Int(firstSize.width * 12700), height: Int(firstSize.height * 12700))
        writer.title = url.deletingPathExtension().lastPathComponent
        let slideW = CGFloat(writer.width), slideH = CGFloat(writer.height)
        for i in 1...doc.numberOfPages {
            guard let page = doc.page(at: i) else { continue }
            let slide = writer.addSlide()
            let size = pageSize(page)
            // Pages of another size are fitted into the deck's slide size.
            let k = min(slideW / max(1, size.width), slideH / max(1, size.height))
            let frame = CGRect(x: (slideW - size.width * k) / 2, y: (slideH - size.height * k) / 2,
                               width: size.width * k, height: size.height * k)
            guard let image = PDFTools.render(page, dpi: dpi, maxPixels: 8000, annotations: annotated?.page(at: i - 1)) else { continue }
            var data: Data
            var jpeg = format.hasPrefix("j")
            if format.hasPrefix("p") || format.hasPrefix("j") {
                data = try encode(image, jpeg: jpeg)
            } else {
                data = try encode(image, jpeg: false)
                let alt = try encode(image, jpeg: true, quality: 0.85)
                if data.count > 600_000 && data.count > alt.count * 3 { data = alt; jpeg = true }
            }
            writer.addPicture(slide, data: data, ext: jpeg ? "jpeg" : "png", frame: frame, name: "Page \(i)",
                              description: "Page \(i) of \(url.lastPathComponent)")
            progress(Double(i) / Double(doc.numberOfPages))
        }
        let out = outputURL(for: url, ext: "pptx")
        try writer.write(to: out)
        return out
    }

    private static func encode(_ image: CGImage, jpeg: Bool, quality: Double = 0.9) throws -> Data {
        let data = NSMutableData()
        let type = jpeg ? UTType.jpeg.identifier : UTType.png.identifier
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw ConversionError.toolFailed("Couldn’t encode the image.")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.toolFailed("Couldn’t encode the image.") }
        return data as Data
    }

    /// Several images → one deck, one image per slide, fitted (`fit=fill` crops to fill the slide instead).
    /// `size=16:9` (default), `4:3` or `image` (the first image's shape).
    static func fromImages(_ files: [URL], options: ToolOptions, progress: @escaping (Double) -> Void) throws -> URL {
        guard let firstURL = files.first else { throw ConversionError.unsupported("No images to put in a deck.") }
        struct Picture { let data: Data; let ext: String; let width: Int; let height: Int; let name: String }
        var pictures: [Picture] = []
        var errors: [String] = []
        for (i, url) in files.enumerated() {
            do {
                let src = try Converter.source(url)
                let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
                let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
                let type = CGImageSourceGetType(src) as String? ?? ""
                let pw = props[kCGImagePropertyPixelWidth] as? Int ?? 0, ph = props[kCGImagePropertyPixelHeight] as? Int ?? 0
                let raw = try? Data(contentsOf: url, options: .mappedIfSafe)
                // JPEG, PNG and GIF go in untouched when they're upright; everything else is re-encoded.
                if orientation == 1, pw > 0, ph > 0, let raw, !Ext.svg.contains(Ext.of(url)),
                   [UTType.jpeg.identifier, UTType.png.identifier, UTType.gif.identifier].contains(type) {
                    let ext = type == UTType.jpeg.identifier ? "jpeg" : type == UTType.png.identifier ? "png" : "gif"
                    pictures.append(Picture(data: raw, ext: ext, width: pw, height: ph, name: url.lastPathComponent))
                } else {
                    let image = try Converter.orientedImage(src, maxPixels: 8000)
                    let alpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
                    pictures.append(Picture(data: try encode(image, jpeg: !alpha), ext: alpha ? "png" : "jpeg",
                                            width: image.width, height: image.height, name: url.lastPathComponent))
                }
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            progress(Double(i + 1) / Double(files.count) * 0.8)
        }
        guard let first = pictures.first else {
            throw ConversionError.unsupported(errors.first ?? "None of the images could be read.")
        }
        var w = 12_192_000.0, h = 6_858_000.0
        switch options.string("size", "16:9").lowercased() {
        case "4:3": w = 9_144_000
        case "image", "first", "auto":
            let aspect = Double(first.width) / Double(max(1, first.height))
            if aspect >= 1 { w = 12_192_000; h = w / aspect } else { h = 6_858_000; w = h * aspect }
        default: break
        }
        let fill = options.string("fit", "fit").lowercased() == "fill"
        let writer = PPTXWriter(width: Int(w), height: Int(h))
        writer.title = firstURL.deletingPathExtension().lastPathComponent
        let sw = CGFloat(writer.width), sh = CGFloat(writer.height)
        let background = options["background"].map { $0.replacingOccurrences(of: "#", with: "").uppercased() }
            .flatMap { PPTXColor(hex: $0) != nil ? $0 : nil }
        for p in pictures {
            let slide = writer.addSlide(background: background)
            let iw = CGFloat(p.width), ih = CGFloat(p.height)
            if fill {
                // Crop the picture (srcRect) so it covers the whole slide.
                let slideAspect = sw / sh, imageAspect = iw / ih
                var crop = (l: 0.0, t: 0.0, r: 0.0, b: 0.0)
                if imageAspect > slideAspect {
                    let keep = slideAspect / imageAspect
                    crop.l = Double(1 - keep) / 2; crop.r = crop.l
                } else {
                    let keep = imageAspect / slideAspect
                    crop.t = Double(1 - keep) / 2; crop.b = crop.t
                }
                writer.addPicture(slide, data: p.data, ext: p.ext, frame: CGRect(x: 0, y: 0, width: sw, height: sh),
                                  name: p.name, description: p.name, crop: crop)
            } else {
                let k = min(sw / iw, sh / ih)
                let frame = CGRect(x: (sw - iw * k) / 2, y: (sh - ih * k) / 2, width: iw * k, height: ih * k)
                writer.addPicture(slide, data: p.data, ext: p.ext, frame: frame, name: p.name, description: p.name)
            }
        }
        let out = outputURL(for: firstURL, ext: "pptx", suffix: files.count > 1 ? " combined" : "")
        try writer.write(to: out)
        progress(1)
        if !errors.isEmpty {
            // The deck is still worth having, but a missing slide must not go unnoticed.
            let left = errors.count == 1 ? errors[0] : "\(errors.count) images: " + errors.joined(separator: "; ")
            PDFExtras.note("\(out.lastPathComponent) has \(pictures.count) of \(files.count) slides. Left out \(left)")
        }
        return out
    }

    /// PowerPoint 97–2003 → PPTX, through the same slide model the renderer uses.
    static func fromPPT(_ url: URL, progress: @escaping (Double) -> Void) throws -> URL {
        let out = outputURL(for: url, ext: "pptx")
        if ZipReader.isZip(url) {
            // Already a PPTX with an old extension: check it opens, then copy it under the right name.
            _ = try PPTXDeck.open(url)
            try FileManager.default.copyItem(at: url, to: out)
            return out
        }
        let parts = try PPTBinary.convert(url)
        let z = ZipWriter()
        let order = ["[Content_Types].xml", "_rels/.rels"]
        for name in order { if let d = parts.files[name] { try z.add(name, data: d) } }
        for name in parts.files.keys.sorted() where !order.contains(name) { try z.add(name, data: parts.files[name]!) }
        try z.write(to: out)
        progress(1)
        return out
    }

    // MARK: Self-test

    static func selfTest(_ name: String) -> String? {
        #if DEBUG
        guard name == "presentations" || name == "pptx" else { return nil }
        return PresentationsTests.run()
        #else
        return nil
        #endif
    }
}
