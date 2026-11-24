import AppKit

/// Text documents: DOCX, DOC, RTF, RTFD, HTML, TXT, Markdown, ODT, text clippings; documents → PDF; PDF → DOCX, TXT, Markdown.
/// Self-tests live in TextDocumentsTests.swift.
enum TextDocuments: FeatureModule {
    /// Convert-wheel targets for text documents: (id = extension, petal title).
    static let targets: [(id: String, title: String)] = [
        ("pdf", "PDF"), ("docx", "DOCX"), ("rtf", "RTF"), ("html", "HTML"), ("txt", "TXT"), ("md", "Markdown"), ("odt", "ODT"),
    ]

    /// A source's format in target terms: "htm" is HTML, "markdown" is MD, "text" is TXT.
    static func format(of url: URL) -> String {
        switch Ext.of(url) {
        case "htm", "xhtml": return "html"
        case "markdown", "mdown", "mkd": return "md"
        case "text": return "txt"
        default: return Ext.of(url)
        }
    }

    static var commands: [WheelCommand] {
        var list = targets.map { target in
            WheelCommand(wheel: .convert, id: target.id, title: target.title,
                         applies: { files in
                             Ext.all(files, in: Ext.textDocuments) && !files.allSatisfy { format(of: $0) == target.id }
                         },
                         run: { files, options, progress in
                             // A petal offered for a mixed selection skips the files already in its format.
                             try files.filter { format(of: $0) != target.id }
                                 .flatMap { try convert($0, to: target.id, options: options, progress: progress) }
                         })
        }
        list.append(WheelCommand(wheel: .convert, id: "docx", title: "DOCX",
                                 applies: { Ext.all($0, in: ["pdf"]) },
                                 run: { files, options, progress in
                                     try files.map { try pdfToDOCX($0, options: options, progress: progress) }
                                 }))
        // PDF → TXT and Markdown (TextDocumentsPDFText.swift), rebuilt by the same reader as DOCX.
        list.append(WheelCommand(wheel: .convert, id: "txt", title: "TXT",
                                 applies: { Ext.all($0, in: ["pdf"]) },
                                 run: { files, options, progress in
                                     try files.map { try pdfToText($0, options: options, progress: progress) }
                                 }))
        list.append(WheelCommand(wheel: .convert, id: "md", title: "Markdown",
                                 applies: { Ext.all($0, in: ["pdf"]) },
                                 run: { files, options, progress in
                                     try files.flatMap { try pdfToMarkdown($0, options: options, progress: progress) }
                                 }))
        return list
    }

    /// Page setup from options: paper = auto | a4 | letter | legal | a5, landscape = true/false,
    /// margin = points (default 72, one inch).
    static func page(_ options: ToolOptions) -> RichPageSetup {
        var page = RichPageSetup.regional
        switch options.string("paper", "auto").lowercased() {
        case "a4": page.size = CGSize(width: 595.28, height: 841.89)
        case "letter", "us": page.size = CGSize(width: 612, height: 792)
        case "legal": page.size = CGSize(width: 612, height: 1008)
        case "a5": page.size = CGSize(width: 419.53, height: 595.28)
        default: break
        }
        if options.bool("landscape", false) { page.size = CGSize(width: page.size.height, height: page.size.width) }
        let m = CGFloat(min(200, max(18, options.double("margin", 72))))
        page.margins = NSEdgeInsets(top: m, left: m, bottom: m, right: m)
        return page
    }

    /// One document to another format, saved next to it.
    static func convert(_ url: URL, to target: String, options: ToolOptions, progress: (Double) -> Void) throws -> [URL] {
        if format(of: url) == target {
            let name = targets.first { $0.id == target }?.title ?? target.uppercased()
            let article = ["HTML", "ODT", "RTF"].contains(name) ? "an" : "a"
            throw ConversionError.unsupported("\(url.lastPathComponent) is already \(article) \(name) file.")
        }
        let text = try DocumentIO.read(url)
        progress(0.5)
        let out = outputURL(for: url, ext: target)
        let written = try DocumentIO.write(text, to: out, ext: target, page: page(options), pageNumbers: options.bool("pageNumbers", true))
        progress(1)
        return written
    }

    /// The PDF reader's options, shared by PDF → DOCX, TXT and Markdown: ocr (default true), images and pageBreaks
    /// (defaults per target), lines = auto | true | false.
    static func pdfReaderOptions(_ options: ToolOptions, images: Bool, pageBreaks: Bool) -> RichPDFReader.Options {
        var opts = RichPDFReader.Options()
        opts.ocr = options.bool("ocr", true)
        opts.images = options.bool("images", images)
        opts.pageBreaks = options.bool("pageBreaks", pageBreaks)
        switch options.string("lines", "auto").lowercased() {
        case "true", "yes", "1", "on": opts.keepLines = true
        case "false", "no", "0", "off": opts.keepLines = false
        default: opts.keepLines = nil
        }
        return opts
    }

    /// PDF → editable Word document. Options: ocr (true), images (true), pageBreaks (true),
    /// lines = auto | true | false (keep every line as its own paragraph; auto does that for monospaced PDFs).
    static func pdfToDOCX(_ url: URL, options: ToolOptions, progress: (Double) -> Void) throws -> URL {
        let opts = pdfReaderOptions(options, images: true, pageBreaks: true)
        let (doc, setup) = try RichPDFReader.document(url, options: opts, progress: progress)
        var document = doc
        if document.title == nil { document.title = url.deletingPathExtension().lastPathComponent }
        let out = outputURL(for: url, ext: "docx")
        do {
            try RichDOCXWriter.write(document, to: out, page: setup)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError.toolFailed("Couldn’t save \(out.lastPathComponent): \(error.localizedDescription)")
        }
        progress(1)
        return out
    }
}
