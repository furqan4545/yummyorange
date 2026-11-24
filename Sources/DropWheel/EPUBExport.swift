import AppKit
import PDFKit

extension EPUBBook {
    // MARK: Single-file HTML

    /// The whole book as one HTML file that keeps its own markup and styles: chapters become sections,
    /// ids are made unique per chapter and links between chapters follow, images and fonts are embedded
    /// as data URIs, scripts and remote references are left out.
    func singleHTML(progress: (Double) -> Void = { _ in }) throws -> String {
        var chapterIDs: [String: String] = [:]
        for (i, item) in spine.enumerated() { chapterIDs[item.path] = "chapter-\(i + 1)" }
        var css = ""
        var seenCSS = Set<String>()
        var body = ""
        var dataURIs: [String: String] = [:]

        func dataURI(_ path: String) -> String? {
            if let cached = dataURIs[path] { return cached }
            guard let data = try? package.data(path) else { return nil }
            let ext = (path as NSString).pathExtension.lowercased()
            let mime = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "svg": "image/svg+xml",
                        "webp": "image/webp", "otf": "font/otf", "ttf": "font/ttf", "woff": "font/woff", "woff2": "font/woff2",
                        "css": "text/css"][ext] ?? "application/octet-stream"
            let uri = "data:\(mime);base64,\(data.base64EncodedString())"
            dataURIs[path] = uri
            return uri
        }
        func rewriteCSS(_ text: String, base: String) -> String {
            var out = text.replacingOccurrences(of: #"@import[^;]*;"#, with: "", options: .regularExpression)
            let regex = try! NSRegularExpression(pattern: #"url\(\s*['"]?([^'")]+)['"]?\s*\)"#)
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let ref = ns.substring(with: m.range(at: 1))
                if ref.hasPrefix("data:") {
                    result += ns.substring(with: m.range)
                } else if !EbooksAndPages.Package.isRemote(ref), let uri = dataURI(EbooksAndPages.Package.resolve(ref, relativeTo: base)) {
                    result += "url(\"\(uri)\")"
                } else {
                    result += "none"   // remote or missing: never fetched
                }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
            return out.replacingOccurrences(of: "</style", with: "<\\/style", options: .caseInsensitive)
        }

        for (i, item) in spine.enumerated() {
            defer { progress(Double(i + 1) / Double(max(spine.count, 1))) }
            let cid = chapterIDs[item.path]!
            if item.isSVG {
                if let uri = dataURI(item.path) { body += "<section class=\"chapter\" id=\"\(cid)\"><img src=\"\(uri)\" alt=\"\"/></section>\n" }
                continue
            }
            guard let data = try? package.data(item.path), let doc = EbooksAndPages.parseMarkup(data),
                  let root = doc.rootElement() else { continue }
            for link in EbooksAndPages.elements(root, named: "link") {
                guard (EbooksAndPages.attribute(link, "rel") ?? "").lowercased().contains("stylesheet"),
                      let href = EbooksAndPages.attribute(link, "href"), !EbooksAndPages.Package.isRemote(href) else { continue }
                let path = EbooksAndPages.Package.resolve(href, relativeTo: item.path)
                if seenCSS.insert(path).inserted, let cssData = try? package.data(path) {
                    css += "/* \(path) */\n" + rewriteCSS(EbooksAndPages.decodeText(cssData), base: path) + "\n"
                }
            }
            for style in EbooksAndPages.elements(root, named: "style") {
                let text = rewriteCSS(style.stringValue ?? "", base: item.path)
                if seenCSS.insert("inline:" + text).inserted { css += text + "\n" }
            }
            guard let bodyElement = EbooksAndPages.firstElement(root, named: "body") else { continue }
            // Links only to other chapters, the web or mail; pictures, fonts and media only as embedded
            // data URIs; CSS anywhere in an attribute loses its remote url()s. Everything else is dropped.
            let rewrite: (String, String, String) -> String? = { tag, attr, value in
                switch attr {
                case "id", "xml:id":
                    return "\(cid)-\(value)"
                case "href" where tag == "a" || tag == "area", "xlink:href" where tag == "a":
                    guard let link = EbooksAndPages.safeLink(value) else { return nil }
                    if link.hasPrefix("#") { return "#\(cid)-\(link.dropFirst())" }
                    if EbooksAndPages.Package.isRemote(link) { return link }   // http(s) or mailto
                    let target = EbooksAndPages.Package.resolve(link, relativeTo: item.path)
                    guard let tid = chapterIDs[target] else { return "#" }
                    if let hash = link.firstIndex(of: "#") { return "#\(tid)-\(link[link.index(after: hash)...])" }
                    return "#\(tid)"
                case "src", "href", "xlink:href", "poster", "background", "data":
                    let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if v.lowercased().hasPrefix("data:") { return EbooksAndPages.isPassiveDataURI(v) ? v : nil }
                    if v.isEmpty || EbooksAndPages.Package.isRemote(v) { return nil }
                    if v.hasPrefix("#") { return "#\(cid)-\(v.dropFirst())" }   // <use href="#shape">
                    return dataURI(EbooksAndPages.Package.resolve(v, relativeTo: item.path))
                case "srcset", "imagesrcset", "lowsrc", "dynsrc", "codebase", "archive", "manifest":
                    return nil
                default:
                    // style="background:url(…)", SVG fill="url(…)" and the like.
                    if value.range(of: #"url\s*\("#, options: [.regularExpression, .caseInsensitive]) != nil {
                        return rewriteCSS(value, base: item.path)
                    }
                    return value
                }
            }
            let classes = EbooksAndPages.attribute(bodyElement, "class").map { " " + EbooksAndPages.escapeXML($0, attribute: true) } ?? ""
            body += "<section class=\"chapter\(classes)\" id=\"\(cid)\">\n"
            for child in bodyElement.children ?? [] { body += EbooksAndPages.serializeHTML(child, forExport: true, rewrite: rewrite) }
            body += "\n</section>\n"
        }
        guard !body.isEmpty else { throw ConversionError.unsupported("This book has no readable chapters.") }
        let lang = EbooksAndPages.escapeXML(language ?? "en", attribute: true)
        let author = authors.isEmpty ? "" : "<meta name=\"author\" content=\"\(EbooksAndPages.escapeXML(authors.joined(separator: ", "), attribute: true))\"/>\n"
        return """
        <!DOCTYPE html>
        <html lang="\(lang)">
        <head>
        <meta charset="utf-8"/>
        <meta http-equiv="Content-Security-Policy" content="\(Self.exportCSP)"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <title>\(EbooksAndPages.escapeXML(title ?? "Book"))</title>
        \(author)<style>
        \(css)
        section.chapter { page-break-before: always; break-before: page; }
        section.chapter:first-of-type { page-break-before: auto; break-before: auto; }
        img, svg { max-width: 100%; height: auto; }
        </style>
        </head>
        <body>
        \(body)</body>
        </html>

        """
    }

    /// The exported page may show only what it carries: no scripts, frames, plug-ins or remote loads, even
    /// if something slipped past the serializer.
    static let exportCSP = "default-src 'none'; img-src data:; font-src data:; media-src data:; style-src 'unsafe-inline'; "
        + "base-uri 'none'; form-action 'none'"

    // MARK: PDF

    static let printCSS = """
    img { max-width: 100% !important; height: auto !important; page-break-inside: avoid; break-inside: avoid; }
    svg, video, table { max-width: 100% !important; }
    pre { white-space: pre-wrap !important; }
    h1, h2, h3, h4, h5, h6 { page-break-after: avoid; break-after: avoid; }
    """

    /// The book laid out as a PDF through WebKit, chapter by chapter, with bookmarks from the table of contents.
    func renderPDF(page: EbooksAndPagesRenderer.Page, progress: @escaping (Double) -> Void) throws -> PDFDocument {
        guard !spine.isEmpty else { throw ConversionError.unsupported("This book has no readable chapters.") }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("dropwheel-epub-pdf-\(UUID().uuidString)")
        let root = scratch.appendingPathComponent("book")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        try package.extract(to: root)

        let allTitles = chapterTitles()
        var files: [URL] = []
        var titles: [String] = []
        for (i, item) in spine.enumerated() {
            let file = root.appendingPathComponent(item.path)
            guard fm.fileExists(atPath: file.path) else { continue }
            if item.isSVG {
                let page = file.deletingPathExtension().appendingPathExtension("dropwheel.html")
                let src = EbooksAndPages.escapeXML(file.lastPathComponent, attribute: true)
                try "<!DOCTYPE html><html><head><meta charset=\"utf-8\"/></head><body style=\"margin:0\"><img src=\"\(src)\" style=\"max-width:100%;max-height:95vh\"/></body></html>"
                    .write(to: page, atomically: true, encoding: .utf8)
                files.append(page)
            } else {
                files.append(try Self.preparedForPrint(file))
            }
            titles.append(i < allTitles.count ? allTitles[i] : "")
        }
        let pdf = try EbooksAndPagesRenderer.render(files, titles: titles, readAccess: root, page: page, progress: progress)
        var attrs: [AnyHashable: Any] = [PDFDocumentAttribute.creatorAttribute: "YummyOrange"]
        if let title { attrs[PDFDocumentAttribute.titleAttribute] = title }
        if !authors.isEmpty { attrs[PDFDocumentAttribute.authorAttribute] = authors.joined(separator: ", ") }
        pdf.documentAttributes = attrs
        return pdf
    }

    /// Adds the print stylesheet to a chapter (a scratch copy). XHTML that isn't well-formed would show
    /// WebKit's XML error page, so it is re-serialized as HTML next to the original instead.
    static func preparedForPrint(_ file: URL) throws -> URL {
        var data = try Data(contentsOf: file)
        let ext = file.pathExtension.lowercased()
        // An XSLT stylesheet would replace the chapter with whatever it generates (a blank page, or files
        // it reads); the chapter is printed as written.
        if data.range(of: Data("xml-stylesheet".utf8)) != nil {
            let text = EbooksAndPages.decodeText(data)
            let cleaned = text.replacingOccurrences(of: #"<\?xml-stylesheet\b[^>]*?(xsl|xslt)\b[^>]*\?>"#, with: "",
                                                    options: [.regularExpression, .caseInsensitive])
            if cleaned != text { data = Data(cleaned.utf8) }
        }
        let style = "<style type=\"text/css\">\n\(printCSS)\n</style>\n"
        if ["xhtml", "xml", "xht"].contains(ext), !EbooksAndPages.isWellFormedXML(data) {
            guard let doc = EbooksAndPages.parseMarkup(data), let root = doc.rootElement() else {
                throw ConversionError.unsupported("\(file.lastPathComponent) can’t be read.")
            }
            var html = EbooksAndPages.serializeHTML(root)
            if let r = html.range(of: "</head>", options: .caseInsensitive) { html.insert(contentsOf: style, at: r.lowerBound) }
            else { html = style + html }
            let fixed = file.deletingPathExtension().appendingPathExtension("dropwheel.html")
            try ("<!DOCTYPE html>\n<meta charset=\"utf-8\"/>\n" + html).write(to: fixed, atomically: true, encoding: .utf8)
            return fixed
        }
        // Written back as UTF-8, so every charset declaration has to say so too.
        var text = EbooksAndPages.decodeText(data)
            .replacingOccurrences(of: #"(?i)(charset\s*=\s*["']?)[A-Za-z0-9_:\-]+"#, with: "$1utf-8", options: .regularExpression)
            .replacingOccurrences(of: #"^(\s*<\?xml[^>]*encoding\s*=\s*["'])[^"']+"#, with: "$1utf-8", options: .regularExpression)
        if !["xhtml", "xml", "xht"].contains(ext), text.range(of: "charset", options: .caseInsensitive) == nil {
            text = "<meta charset=\"utf-8\"/>\n" + text   // HTML without a declaration isn't read as UTF-8
        }
        if let r = text.range(of: "</head>", options: .caseInsensitive) {
            text.insert(contentsOf: style, at: r.lowerBound)
        } else if let r = text.range(of: "<body", options: .caseInsensitive) {
            text.insert(contentsOf: "<head>\(style)</head>", at: r.lowerBound)
        } else if !["xhtml", "xml", "xht"].contains(ext) {
            text = style + text
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

extension EbooksAndPages {
    /// A document laid out as a PDF through WebKit (Pages documents, generated books).
    static func renderPDF(_ doc: Doc, page: EbooksAndPagesRenderer.Page, progress: @escaping (Double) -> Void) throws -> PDFDocument {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("dropwheel-doc-pdf-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for (id, pic) in doc.pictures { try pic.data.write(to: dir.appendingPathComponent("\(id).\(pic.ext)")) }
        let body = xhtmlBody(doc.blocks, imageSrc: { id in doc.pictures[id].map { "\(id).\($0.ext)" } }, rich: true)
        let css = bookCSS.replacingOccurrences(of: "margin: 0 5%;", with: "margin: 0;")
        let html = xhtmlDocument(title: doc.title ?? "Document", language: doc.language, body: body, css: css)
        let file = dir.appendingPathComponent("document.html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        let pdf = try EbooksAndPagesRenderer.render([file], titles: [], readAccess: dir, page: page, progress: progress)
        var attrs: [AnyHashable: Any] = [PDFDocumentAttribute.creatorAttribute: "YummyOrange"]
        if let t = doc.title { attrs[PDFDocumentAttribute.titleAttribute] = t }
        if let a = doc.author { attrs[PDFDocumentAttribute.authorAttribute] = a }
        pdf.documentAttributes = attrs
        return pdf
    }

    /// A standalone HTML file with the images embedded.
    static func standaloneHTML(_ doc: Doc) -> String {
        let body = xhtmlBody(doc.blocks, imageSrc: { id in
            doc.pictures[id].map { "data:\($0.mime);base64,\($0.data.base64EncodedString())" }
        }, rich: true)
        let html = xhtmlDocument(title: doc.title ?? "Document", language: doc.language, body: body,
                                 css: bookCSS + "\nbody { max-width: 46em; margin: 2em auto; padding: 0 1em; }")
        // Served as text/html, so drop the XML declaration.
        return html.replacingOccurrences(of: "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n", with: "")
    }
}
