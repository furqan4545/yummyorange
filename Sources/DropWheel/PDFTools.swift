import AppKit
import PDFKit
import Quartz
import UniformTypeIdentifiers
import Vision

/// PDF tools built on PDFKit and CoreGraphics, with Vision OCR for pages that have no text layer.
enum PDFTools {
    typealias Progress = Converter.Progress

    static func isEncrypted(_ url: URL) -> Bool {
        PDFDocument(url: url)?.isEncrypted ?? false
    }

    static func run(_ tool: FileTool, on url: URL, kind: FileKind, progress: @escaping Progress) throws -> [URL] {
        switch tool {
        case .compress: return [try compress(url)]
        case .stripMetadata: return [try stripMetadata(url)]
        case .rotate: return [try rotate(url)]
        case .split: return [try split(url, progress: progress)]
        case .extractText: return [try extractText(url, kind: kind, progress: progress)]
        default: throw ConversionError.unsupported("\(tool.rawValue) doesn’t apply to PDFs.")
        }
    }

    // MARK: Helpers

    private static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
        if doc.isLocked {
            throw ConversionError.unsupported("\(url.lastPathComponent) is password-protected. Use Remove Password first.")
        }
        return doc
    }

    private static func save(_ doc: PDFDocument, to out: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        guard doc.write(to: out, withOptions: options) else {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError.toolFailed("Couldn’t save \(out.lastPathComponent).")
        }
    }

    /// Copies every page into a fresh document, so nothing else from the original catalog (XMP, info) comes along.
    /// Internal links and bookmarks are moved onto the copies (PDFKit would point them all at page 1).
    private static func freshCopy(of doc: PDFDocument, clearAnnotationAuthors: Bool = false) -> PDFDocument {
        let copier = PDFPageCopier()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            copier.append(page) { copy in
                guard clearAnnotationAuthors else { return }
                for annotation in copy.annotations {
                    annotation.userName = nil
                    annotation.modificationDate = nil
                }
            }
        }
        return copier.finish()
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    // MARK: Image pages

    /// How many pages an image holds: every page of a multi-page TIFF (a scan, a fax), otherwise 1. The frames
    /// of an animated GIF or PNG are an animation, not pages, and a camera raw's extra images are previews.
    static func imagePageCount(_ src: CGImageSource, url: URL) -> Int {
        guard (CGImageSourceGetType(src) as String?) == UTType.tiff.identifier,
              !Ext.rawImages.contains(Ext.of(url)) else { return 1 }
        return max(1, CGImageSourceGetCount(src))
    }

    /// Page `index` of an image, upright: each TIFF page's own orientation tag is applied.
    static func orientedImage(_ src: CGImageSource, page index: Int, of url: URL) throws -> CGImage {
        if index == 0 { return try Converter.orientedImage(src) }   // the same decoding as everywhere else
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary) else {
            throw ConversionError.unsupported("Couldn’t read page \(index + 1) of \(url.lastPathComponent).")
        }
        return image
    }

    /// Calls `body` with each page of an image file, upright, one at a time, so a long scan is never decoded
    /// all at once. A page that can't be decoded stops the job with an error naming the file and the page.
    static func forEachImagePage(_ url: URL, _ body: (_ image: CGImage, _ index: Int, _ count: Int) throws -> Void) throws {
        let src = try Converter.source(url)
        let count = imagePageCount(src, url: url)
        for i in 0..<count {
            try autoreleasepool {
                let image = try orientedImage(src, page: i, of: url)
                try body(image, i, count)
            }
        }
    }

    /// A4 or US Letter, from the region.
    static var paperSize: CGSize {
        Locale.current.measurementSystem == .us ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
    }

    /// An image as a page on A4 or US Letter, turned to match the image (Merge PDF, Make PDF, Organize…).
    static func imagePDFPage(_ image: CGImage) -> PDFPage? {
        let paper = paperSize
        let box = CGRect(origin: .zero, size: image.width > image.height ? CGSize(width: paper.height, height: paper.width) : paper)
        let ns = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        return PDFPage(image: ns, options: [.mediaBox: NSValue(rect: box), .upscaleIfSmaller: false, .compressionQuality: 0.85])
    }

    /// Every page of an image file as PDF pages: one per TIFF page, one for anything else.
    static func imagePDFPages(_ url: URL, _ body: (_ page: PDFPage, _ index: Int, _ count: Int) throws -> Void) throws {
        try forEachImagePage(url) { image, index, count in
            guard let page = imagePDFPage(image) else {
                throw ConversionError.unreadable(count > 1 ? "\(url.lastPathComponent), page \(index + 1)" : url.lastPathComponent)
            }
            try body(page, index, count)
        }
    }

    /// The title a merged file's bookmark gets for `url`: the PDF's own title, or else the file name.
    private static func bookmarkTitle(_ url: URL, _ doc: PDFDocument?) -> String {
        let title = (doc?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? url.deletingPathExtension().lastPathComponent : title
    }

    /// A folder next to `source` that doesn't exist yet: "name pages", "name pages 2", ...
    private static func newFolder(next source: URL, suffix: String) throws -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + suffix
        var candidate = dir.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        return candidate
    }

    /// Renders a page with its visible annotations (form-field values, stamps, notes, highlights, drawings).
    static func render(_ page: PDFPage, dpi: CGFloat, maxPixels: CGFloat = 6000) -> CGImage? {
        guard let ref = page.pageRef else { return nil }
        return render(ref, dpi: dpi, maxPixels: maxPixels, annotations: page)
    }

    /// Renders a page to pixels, honouring its /Rotate and crop box. The long side is capped at
    /// `maxPixels` so oversized pages (posters, images placed at 72 DPI) don't explode.
    /// Core Graphics draws only the page's content; pass the same page opened with PDFKit as `annotations`
    /// to draw its visible annotations on top, as a viewer shows them.
    static func render(_ page: CGPDFPage, dpi: CGFloat, maxPixels: CGFloat = 6000, annotations: PDFPage? = nil) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let quarterTurns = ((page.rotationAngle % 360) + 360) % 360 / 90
        let pointSize = quarterTurns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
        let scale = min(dpi / 72, maxPixels / max(pointSize.width, pointSize.height, 1))
        let w = Int(pointSize.width * scale), h = Int(pointSize.height * scale)
        guard w > 0, h > 0, w * h < 400_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.saveGState()
        // getDrawingTransform handles rotation and origin but never scales up, so scale first.
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: pointSize),
                                                 rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        ctx.restoreGState()
        if let annotations {
            ctx.clip(to: CGRect(origin: .zero, size: pointSize))
            drawVisibleAnnotations(of: annotations, in: ctx)
        }
        return ctx.makeImage()
    }

    /// Draws a page's annotations as a viewer shows them: form fields with their values, free text, stamps,
    /// notes, highlights and drawings. Links (invisible areas), pop-up windows and annotations flagged Hidden
    /// or NoView are left out. `ctx` is in the upright page's space (the crop box's bottom left at the origin,
    /// /Rotate applied): PDFKit maps each annotation from page space itself.
    static func drawVisibleAnnotations(of page: PDFPage, in ctx: CGContext) {
        for annotation in page.annotations where annotation.shouldDisplay {
            let type = annotation.type ?? ""
            if type == "Link" || type == "Popup" { continue }
            let flags = (annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
            if flags & (2 | 32) != 0 { continue }
            ctx.saveGState()
            annotation.draw(with: .cropBox, in: ctx)
            ctx.restoreGState()
        }
    }

    /// The widest image placed directly on a page (scans have exactly one).
    private static func largestImage(on page: CGPDFPage) -> (width: Int, stream: CGPDFStreamRef)? {
        guard let pageDict = page.dictionary else { return nil }
        var resources: CGPDFDictionaryRef?
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return nil }
        var best: (width: Int, stream: CGPDFStreamRef)?
        CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dict = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<Int8>?
            var width: CGPDFInteger = 0
            if CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image",
               CGPDFDictionaryGetInteger(dict, "Width", &width), Int(width) > (best?.width ?? 0) {
                best = (Int(width), stream)
            }
            return true
        }, nil)
        return best
    }

    /// The best picture of a text-less (scanned) page for OCR.
    /// If the page's image is a JPEG it is read straight from the file, untouched: on a test scan that
    /// got 40 of 54 lines right, while rendering the same page first got 24. Its orientation may not
    /// match the page's /Rotate; recognizeTextAnyOrientation sorts that out.
    /// Anything else is rendered at the image's own resolution (upscaling hurt OCR too: 31 vs 47).
    static func scanImage(_ page: CGPDFPage) -> CGImage? {
        let largest = largestImage(on: page)
        if let largest {
            var format = CGPDFDataFormat.raw
            if let data = CGPDFStreamCopyData(largest.stream, &format), format == .jpegEncoded,
               let src = CGImageSourceCreateWithData(data, nil),
               let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                return image
            }
        }
        var dpi: CGFloat = 300
        if let largest {
            let box = page.getBoxRect(.cropBox)
            let quarterTurns = ((page.rotationAngle % 360) + 360) % 360 / 90
            let widthInches = (quarterTurns % 2 == 1 ? box.height : box.width) / 72
            // Assumes the image spans the page width, which is how scans and Make PDF pages are laid out.
            dpi = min(400, max(150, CGFloat(largest.width) / widthInches))
        }
        return render(page, dpi: dpi)
    }

    // MARK: Tools

    /// A Quartz filter that re-encodes embedded images as JPEG (quality 0.6) at up to 150 DPI.
    /// Text and vector art pass through untouched. (PDFKit's own JPEG/screen write options left
    /// image-heavy test files the same size; this filter cut a 4 MB scan to about 0.5 MB.)
    private static let compressionFilter = QuartzFilter(properties: [
        "Domains": ["Applications": true, "Printing": true],
        "FilterData": ["ColorSettings": ["ImageSettings": [
            "Compression Quality": 0.6,
            "ImageCompression": "ImageJPEGCompress",
            "ImageScaleSettings": ["ImageResolution": 150, "ImageScaleAddNoise": false,
                                   "ImageScaleInterpolate": true, "ImageSizeMax": 0, "ImageSizeMin": 0],
        ]]],
        "FilterType": 1,
        "Name": "YummyOrange Compress",
    ])

    static func compress(_ url: URL) throws -> URL {
        let doc = try open(url)
        let out = outputURL(for: url, ext: "pdf", suffix: " compressed")
        if let filter = compressionFilter {
            try save(doc, to: out, options: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter])
        } else if #available(macOS 13.4, *) {
            try save(doc, to: out, options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
        } else {
            throw ConversionError.unsupported("Couldn’t set up PDF compression on this Mac.")
        }
        if fileSize(out) >= fileSize(url) {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError.unsupported("\(url.lastPathComponent) is already as small as YummyOrange can make it.")
        }
        return out
    }

    static func stripMetadata(_ url: URL) throws -> URL {
        let clean = freshCopy(of: try open(url), clearAnnotationAuthors: true)
        clean.documentAttributes = [:]
        let out = outputURL(for: url, ext: "pdf", suffix: " clean")
        try save(clean, to: out)
        return out
    }

    /// Turns every page 90° clockwise.
    static func rotate(_ url: URL) throws -> URL {
        let doc = try open(url)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            page.rotation = (page.rotation + 90) % 360
        }
        let out = outputURL(for: url, ext: "pdf", suffix: " rotated")
        try save(doc, to: out)
        return out
    }

    /// One PDF per page, collected in a "<name> pages" folder.
    static func split(_ url: URL, progress: @escaping Progress) throws -> URL {
        let doc = try open(url)
        guard doc.pageCount > 1 else { throw ConversionError.unsupported("\(url.lastPathComponent) has only one page.") }
        let folder = try newFolder(next: url, suffix: " pages")
        let base = url.deletingPathExtension().lastPathComponent
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let number = String(repeating: "0", count: max(0, digits - String(i + 1).count)) + String(i + 1)
            try save(single, to: folder.appendingPathComponent("\(base) page \(number).pdf"))
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        return folder
    }

    /// Text layer of a PDF, or OCR for scanned pages and images. Saved as UTF-8 .txt.
    static func extractText(_ url: URL, kind: FileKind, progress: @escaping Progress) throws -> URL {
        var pages: [String] = []
        if kind == .pdf {
            let doc = try open(url)
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                var text = textLayer(of: page)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let ref = page.pageRef,
                   let image = scanImage(ref) {
                    text = try recognizeTextAnyOrientation(in: image)
                }
                pages.append(text)
                progress(Double(i + 1) / Double(doc.pageCount))
            }
        } else if kind == .image {
            try forEachImagePage(url) { image, index, count in   // every page of a multi-page TIFF
                pages.append(try recognizeTextAnyOrientation(in: image))
                progress(Double(index + 1) / Double(count))
            }
        } else {
            throw ConversionError.unsupported("Extract Text works on PDFs and images.")
        }
        let text = pages.joined(separator: "\n\n\u{0C}\n\n")   // form feed between pages
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{0C}"))).isEmpty else {
            throw ConversionError.unsupported("No text found in \(url.lastPathComponent).")
        }
        let out = outputURL(for: url, ext: "txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// The page's text with its line breaks. Some generators (cupsfilter, for one) emit no newline
    /// characters, so `page.string` runs every line together, and PDFKit's selectionsByLine() sees one
    /// line too. Character positions don't lie: a glyph that doesn't vertically overlap the line built
    /// so far starts a new line. (Glyph boxes are tight, so a "." sits low but still overlaps its line.)
    ///
    /// Lines run across the page for most text, but up or down it on sideways pages (a portrait page shown
    /// landscape with /Rotate, a turned table) and in vertical CJK. There the letters of one line share an
    /// x range instead, so the overlap is measured across the direction the text runs.
    private static func textLayer(of page: PDFPage) -> String {
        guard let string = page.string, !string.isEmpty else { return "" }
        let chars = Array(string.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(chars.count + 64)
        var line: (lo: CGFloat, hi: CGFloat)?
        let newline: UInt16 = 0x0A, space: UInt16 = 0x20
        // characterBounds(at:) may not count the line breaks PDFKit puts in page.string; this picks the
        // indexing that matches one-character selections on this page.
        let glyphBox = SpreadsheetsFromPDF.glyphIndexer(page, chars)
        let boxes = chars.indices.map { glyphBox($0) }
        let vertical = textRunsVertically(boxes, chars)
        for (i, c) in chars.enumerated() {
            let r = boxes[i]
            // The glyph's extent across the line.
            let lo = vertical ? r.minX : r.minY, hi = vertical ? r.maxX : r.maxY
            if !r.isNull, hi - lo > 0, c != newline, c != space {
                if let current = line {
                    let overlap = min(hi, current.hi) - max(lo, current.lo)
                    if overlap < 0.25 * min(hi - lo, current.hi - current.lo) {
                        if out.last != newline {
                            if out.last == space { out.removeLast() }
                            out.append(newline)
                        }
                        line = (lo, hi)
                    } else {
                        line = (min(current.lo, lo), max(current.hi, hi))
                    }
                } else {
                    line = (lo, hi)
                }
            }
            if c == newline { line = nil }
            out.append(c)
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// Whether most neighbouring letters on the page follow each other up or down rather than across.
    private static func textRunsVertically(_ boxes: [CGRect], _ chars: [UInt16]) -> Bool {
        let letters = boxes.indices.filter { chars[$0] > 0x20 && !boxes[$0].isNull && boxes[$0].width > 0 && boxes[$0].height > 0 }
        guard letters.count >= 2 else { return false }
        let sizes = letters.map { max(boxes[$0].width, boxes[$0].height) }.sorted()
        let typical = sizes[sizes.count / 2]
        var across = 0, down = 0
        for k in letters.indices.dropFirst() {
            guard letters[k] == letters[k - 1] + 1 else { continue }   // neighbours in the text, nothing between
            let a = boxes[letters[k - 1]], b = boxes[letters[k]]
            guard max(a.width, a.height) < 3 * typical, max(b.width, b.height) < 3 * typical else { continue }
            let dx = b.midX - a.midX, dy = b.midY - a.midY
            guard max(abs(dx), abs(dy)) < 3 * typical else { continue }
            if abs(dx) > 2 * abs(dy) { across += 1 } else if abs(dy) > 2 * abs(dx) { down += 1 }
        }
        return down > across
    }

    /// OCR that also copes with sideways or upside-down scans. Sideways text doesn't come back empty:
    /// Vision reads the turned words one by one, and grouping them into rows then scrambles the text.
    /// So if most word boxes are taller than wide, or the reading is weak, the other orientations are
    /// tried and the strongest reading wins.
    static func recognizeTextAnyOrientation(in image: CGImage) throws -> String {
        var best = try recognize(in: image, orientation: .up)
        let aspect = CGFloat(image.height) / CGFloat(max(image.width, 1))
        let looksSideways = best.verticalFraction(imageAspect: aspect) > 0.5
        guard looksSideways || best.confidence < 0.6 || best.text.filter({ !$0.isWhitespace }).count < 20
        else { return best.text }
        if looksSideways { best = Reading([]) }
        for orientation in [CGImagePropertyOrientation.right, .left, .down] {
            let reading = try recognize(in: image, orientation: orientation)
            if reading.score > best.score { best = reading }
        }
        return best.text
    }

    private struct TextPiece { let text: String; let box: CGRect; let confidence: Float }   // box: normalized, bottom-left

    private struct Reading {
        let text: String
        let confidence: Float      // character-weighted mean of Vision's confidences
        let pieces: [TextPiece]
        var score: Float { confidence * Float(text.count) }

        /// Share of multi-character pieces whose box is taller than wide, in pixels.
        func verticalFraction(imageAspect: CGFloat) -> Double {
            let words = pieces.filter { $0.text.count >= 3 }
            guard !words.isEmpty else { return 0 }
            let tall = words.filter { $0.box.height * imageAspect > $0.box.width }.count
            return Double(tall) / Double(words.count)
        }

        init(_ pieces: [TextPiece]) {
            self.pieces = pieces
            text = PDFTools.readingOrder(pieces)
            let chars = pieces.reduce(0) { $0 + $1.text.count }
            confidence = chars == 0 ? 0 : pieces.reduce(Float(0)) { $0 + $1.confidence * Float($1.text.count) } / Float(chars)
        }
    }

    /// OCR with Vision. On macOS 15+ the Swift `RecognizeTextRequest` is used: on a dense test page it
    /// read 49 of 54 lines where `VNRecognizeTextRequest` (revision 3) read 23.
    private static func recognize(in image: CGImage, orientation: CGImagePropertyOrientation) throws -> Reading {
        if #available(macOS 15.0, *) {
            var pieces: [TextPiece] = []
            var failure: Error?
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    var request = RecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.automaticallyDetectsLanguage = true
                    pieces = try await request.perform(on: image, orientation: orientation).compactMap { obs in
                        obs.topCandidates(1).first.map {
                            TextPiece(text: $0.string, box: obs.boundingBox.cgRect, confidence: $0.confidence)
                        }
                    }
                } catch { failure = error }
                done.signal()
            }
            done.wait()   // callers already run off the main thread
            if let failure { throw failure }
            return Reading(pieces)
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        return Reading((request.results ?? []).compactMap { obs in
            obs.topCandidates(1).first.map { TextPiece(text: $0.string, box: obs.boundingBox, confidence: $0.confidence) }
        })
    }

    /// Vision returns separate boxes for runs of text split by wide gaps ("Line 1:" | "The quick…").
    /// Rebuild reading order: group boxes whose vertical extents overlap into one line, left to right.
    private static func readingOrder(_ unsorted: [TextPiece]) -> String {
        let pieces = unsorted.sorted { $0.box.midY > $1.box.midY }
        var lines: [[TextPiece]] = []
        for piece in pieces {
            if let i = lines.firstIndex(where: { line in
                guard let ref = line.first?.box else { return false }
                let overlap = min(ref.maxY, piece.box.maxY) - max(ref.minY, piece.box.minY)
                return overlap > 0.5 * min(ref.height, piece.box.height)
            }) {
                lines[i].append(piece)
            } else {
                lines.append([piece])
            }
        }
        return lines.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
                    .joined(separator: "\n")
    }

    static func protect(_ url: URL, password: String) throws -> URL {
        let doc = try open(url)
        let out = outputURL(for: url, ext: "pdf", suffix: " protected")
        try save(doc, to: out, options: [.userPasswordOption: password, .ownerPasswordOption: password])
        return out
    }

    static func unlock(_ url: URL, password: String) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
        guard doc.isEncrypted else { throw ConversionError.unsupported("\(url.lastPathComponent) isn’t password-protected.") }
        guard doc.unlock(withPassword: password) else {
            throw ConversionError.unsupported("That password doesn’t open \(url.lastPathComponent).")
        }
        let plain = freshCopy(of: doc)
        plain.documentAttributes = doc.documentAttributes
        let out = outputURL(for: url, ext: "pdf", suffix: " unlocked")
        try save(plain, to: out)
        return out
    }

    /// Merges PDFs and images, in the order given, into one PDF next to the first file.
    /// Images become pages on A4 or US Letter (from the region), turned to match the image; a multi-page TIFF
    /// gives a page for each of its pages. Internal links keep pointing at their own file's pages. When any
    /// PDF has bookmarks, each file gets a bookmark named after it with that file's bookmarks under it.
    static func combine(_ files: [URL], progress: @escaping Progress) throws -> URL {
        guard let first = files.first else { throw ConversionError.unsupported("Nothing to combine.") }
        let copier = PDFPageCopier()
        var documents: [PDFDocument] = []   // the copied pages' links and bookmarks are read from these in finish()
        for (i, url) in files.enumerated() {
            switch FileKind.of(url) {
            case .pdf:
                let doc = try open(url)
                documents.append(doc)
                copier.beginGroup(bookmarkTitle(url, doc))
                for p in 0..<doc.pageCount {
                    guard let page = doc.page(at: p), copier.append(page) else {
                        throw ConversionError.toolFailed("Couldn’t copy page \(p + 1) of \(url.lastPathComponent).")
                    }
                }
            case .image:
                copier.beginGroup(bookmarkTitle(url, nil))
                try imagePDFPages(url) { page, index, count in
                    guard copier.adopt(page) else {
                        throw ConversionError.toolFailed(count > 1 ? "Couldn’t add page \(index + 1) of \(url.lastPathComponent)."
                                                                   : "Couldn’t add \(url.lastPathComponent).")
                    }
                }
            default:
                throw ConversionError.unsupported("\(url.lastPathComponent) isn’t a PDF or an image.")
            }
            progress(Double(i + 1) / Double(files.count))
        }
        let merged = copier.finish()
        withExtendedLifetime(documents) {}
        guard merged.pageCount > 0 else { throw ConversionError.unsupported("No pages to combine.") }
        let allPDF = files.allSatisfy { FileKind.of($0) == .pdf }
        let out = outputURL(for: first, ext: "pdf", suffix: allPDF ? " merged" : " combined")
        try save(merged, to: out)
        return out
    }
}

/// Asks for a PDF password in a small alert. Returns nil if cancelled.
enum PasswordPrompt {
    static func ask(title: String, message: String, confirm: Bool, button: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 260
        let field = NSSecureTextField(frame: CGRect(x: 0, y: confirm ? 32 : 0, width: width, height: 24))
        field.placeholderString = "Password"
        let again = NSSecureTextField(frame: CGRect(x: 0, y: 0, width: width, height: 24))
        again.placeholderString = "Confirm password"
        let box = NSView(frame: CGRect(x: 0, y: 0, width: width, height: confirm ? 56 : 24))
        box.addSubview(field)
        if confirm { box.addSubview(again); field.nextKeyView = again }
        alert.accessoryView = box
        alert.window.initialFirstResponder = field

        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            if field.stringValue.isEmpty {
                alert.informativeText = "Enter a password."
            } else if confirm && field.stringValue != again.stringValue {
                alert.informativeText = "The passwords don’t match. Try again."
                again.stringValue = ""
            } else {
                return field.stringValue
            }
        }
    }
}
