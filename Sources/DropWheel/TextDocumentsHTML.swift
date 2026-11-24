import AppKit
import UniformTypeIdentifiers

/// Writes clean, self-contained HTML5 from a RichDocument: semantic tags (h1–h6, p, ul/ol, table,
/// blockquote, pre), a small stylesheet, and pictures embedded as data: URLs.
enum RichHTMLWriter {
    static func html(_ doc: RichDocument, imageSource: ((RichImage) -> String)? = nil) -> String {
        var body: [String] = []
        var quote = 0
        func setQuote(_ depth: Int) {
            while quote < depth { body.append("<blockquote>"); quote += 1 }
            while quote > depth { body.append("</blockquote>"); quote -= 1 }
        }
        let src = imageSource ?? { "data:\($0.mimeType);base64,\($0.data.base64EncodedString())" }
        let groups = doc.grouped()
        var i = 0
        while i < groups.count {
            let group = groups[i]
            i += 1
            switch group {
            case .list(let items):
                setQuote(items.first?.quoteDepth ?? 0)
                body += RichListNode.build(items).map { list($0, doc, src) }
            case .block(let block):
                switch block {
                case .paragraph(let p):
                    setQuote(p.quoteDepth)
                    if case .code(let lang) = p.kind {
                        var code = [p.text]
                        while i < groups.count, case .block(.paragraph(let next)) = groups[i], p.sameCodeBlock(next) {
                            code.append(next.text); i += 1
                        }
                        let cls = lang.isEmpty ? "" : " class=\"language-\(richXMLEscape(lang, attribute: true))\""
                        body.append("<pre><code\(cls)>" + richXMLEscape(code.joined(separator: "\n").replacingOccurrences(of: "\u{2028}", with: "\n")) + "</code></pre>")
                    } else {
                        body.append(paragraph(p, doc, src))
                    }
                case .table(let t):
                    setQuote(0)
                    body.append(table(t, doc, src))
                case .rule:
                    setQuote(0)
                    body.append("<hr>")
                case .pageBreak:
                    setQuote(0)
                    body.append("<div class=\"page-break\"></div>")
                }
            }
        }
        setQuote(0)
        let family = cssFamily(doc.bodyFamily, mono: doc.monospaced)
        let title = richXMLEscape(doc.title ?? "Document")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="YummyOrange">
        <title>\(title)</title>
        <style>
        body { font-family: \(family); font-size: \(fmt(doc.bodySize))pt; line-height: 1.45; color: #1d1d1f; max-width: 46em; margin: 2em auto; padding: 0 1.2em; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.2em 0 0.4em; }
        p, li, td, th { white-space: pre-wrap; }
        p { margin: 0 0 0.6em; }
        a { color: #0b5ccc; }
        code { font-family: Menlo, Consolas, monospace; font-size: 0.9em; background: #f2f2f4; padding: 0.1em 0.25em; border-radius: 3px; }
        pre { background: #f4f4f6; padding: 0.8em 1em; overflow-x: auto; border-radius: 4px; }
        pre code { background: none; padding: 0; font-size: 0.88em; }
        blockquote { margin: 0 0 0.8em; padding: 0.1em 0 0.1em 1em; border-left: 3px solid #cfcfd4; color: #5c5c66; }
        table { border-collapse: collapse; margin: 0.4em 0 1em; }
        th, td { border: 1px solid #c4c4ca; padding: 0.3em 0.6em; vertical-align: top; }
        th { background: #f0f0f2; }
        hr { border: none; border-top: 1px solid #d0d0d4; margin: 1.2em 0; }
        img { max-width: 100%; height: auto; }
        li.task { list-style: none; }
        li.task input { margin: 0 0.4em 0 -1.3em; }
        .page-break { page-break-after: always; break-after: page; }
        </style>
        </head>
        <body>
        \(body.joined(separator: "\n"))
        </body>
        </html>

        """
    }

    static func fmt(_ v: CGFloat) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    static func cssFamily(_ family: String, mono: Bool) -> String {
        let quoted = family.contains(" ") ? "'\(family.replacingOccurrences(of: "'", with: ""))'" : family
        return quoted + (mono ? ", Menlo, Consolas, monospace" : ", Helvetica, Arial, sans-serif")
    }

    private static func paragraph(_ p: RichParagraph, _ doc: RichDocument, _ src: (RichImage) -> String) -> String {
        let tag = p.headingLevel.map { "h\($0)" } ?? "p"
        var css: [String] = []
        switch p.alignment {
        case .center: css.append("text-align: center")
        case .right: css.append("text-align: right")
        case .justified: css.append("text-align: justify")
        case .left where p.rtl: css.append("text-align: left")
        default: break
        }
        if p.leftIndent > 0.5 { css.append("margin-left: \(fmt(p.leftIndent))pt") }
        if abs(p.firstLineIndent) > 0.5 { css.append("text-indent: \(fmt(p.firstLineIndent))pt") }
        if let bg = p.background { css.append("background-color: #\(bg)") }
        let style = (p.rtl ? " dir=\"rtl\"" : "") + (css.isEmpty ? "" : " style=\"\(css.joined(separator: "; "))\"")
        let content = inline(p.runs, doc, src, heading: p.headingLevel != nil)
        return "<\(tag)\(style)>" + (content.isEmpty ? "<br>" : content) + "</\(tag)>"
    }

    private static func list(_ node: RichListNode, _ doc: RichDocument, _ src: (RichImage) -> String) -> String {
        let level = node.level
        let tag = level.ordered ? "ol" : "ul"
        var attrs = ""
        let start = node.items.first?.paragraphs.first?.itemNumber ?? level.start
        if level.ordered && start != 1 { attrs += " start=\"\(start)\"" }
        switch level.style {
        case .lowerAlpha: attrs += " type=\"a\""
        case .upperAlpha: attrs += " type=\"A\""
        case .lowerRoman: attrs += " type=\"i\""
        case .upperRoman: attrs += " type=\"I\""
        case .circle: attrs += " style=\"list-style-type: circle\""
        case .square: attrs += " style=\"list-style-type: square\""
        default: break
        }
        var out = "<\(tag)\(attrs)>"
        for item in node.items {
            let task = item.paragraphs.first?.task
            let dir = item.paragraphs.first?.rtl == true ? " dir=\"rtl\"" : ""
            out += task == nil ? "<li\(dir)>" : "<li class=\"task\"\(dir)><input type=\"checkbox\" disabled\(task! ? " checked" : "")>"
            for (n, p) in item.paragraphs.enumerated() {
                if case .code = p.kind {
                    out += "<pre><code>" + richXMLEscape(p.text) + "</code></pre>"
                } else if n == 0 {
                    out += inline(p.runs, doc, src, heading: false)
                } else {
                    out += "<p>" + inline(p.runs, doc, src, heading: false) + "</p>"
                }
            }
            out += item.children.map { list($0, doc, src) }.joined()
            out += "</li>"
        }
        return out + "</\(tag)>"
    }

    private static func table(_ t: RichTable, _ doc: RichDocument, _ src: (RichImage) -> String) -> String {
        var out = "<table>"
        for (r, row) in t.rows.enumerated() {
            if r == 0 && t.headerRows > 0 { out += "<thead>" }
            if r == t.headerRows { out += "<tbody>" }
            out += "<tr>"
            let header = r < t.headerRows
            for cell in row where !cell.covered {
                let tag = header ? "th" : "td"
                var attrs = ""
                if cell.colSpan > 1 { attrs += " colspan=\"\(cell.colSpan)\"" }
                if cell.rowSpan > 1 { attrs += " rowspan=\"\(cell.rowSpan)\"" }
                var css: [String] = []
                if let bg = cell.background, bg != "F0F0F2" || !header { css.append("background-color: #\(bg)") }
                switch cell.paragraphs.first?.alignment ?? .natural {
                case .center: css.append("text-align: center")
                case .right: css.append("text-align: right")
                default: break
                }
                if !css.isEmpty { attrs += " style=\"\(css.joined(separator: "; "))\"" }
                if cell.paragraphs.first?.rtl == true { attrs += " dir=\"rtl\"" }
                let parts = cell.paragraphs.map { inline($0.runs, doc, src, heading: header) }
                let content = parts.count <= 1 ? (parts.first ?? "") : parts.map { "<p>\($0)</p>" }.joined()
                out += "<\(tag)\(attrs)>\(content)</\(tag)>"
            }
            out += "</tr>"
            if r == t.headerRows - 1 { out += "</thead>" }
        }
        if t.rows.count > t.headerRows { out += "</tbody>" }
        return out + "</table>"
    }

    /// Runs → inline HTML. Consecutive runs with the same link share one <a>.
    static func inline(_ runs: [RichRun], _ doc: RichDocument, _ src: (RichImage) -> String, heading: Bool) -> String {
        var out = ""
        var openLink: String?
        for run in runs {
            let link = run.link.flatMap { RichDocument.isSafeLink($0) ? $0 : nil }
            if link != openLink {
                if openLink != nil { out += "</a>" }
                if let link { out += "<a href=\"\(richXMLEscape(link, attribute: true))\">" }
                openLink = link
            }
            if let img = run.image {
                let w = Int(img.displaySize.width.rounded()), h = Int(img.displaySize.height.rounded())
                out += "<img src=\"\(src(img))\" alt=\"\(richXMLEscape(img.alt, attribute: true))\" width=\"\(w)\" height=\"\(h)\">"
                continue
            }
            var s = richXMLEscape(run.text).replacingOccurrences(of: "\u{2028}", with: "<br>")
            if run.code { s = "<code>\(s)</code>" }
            if run.script > 0 { s = "<sup>\(s)</sup>" } else if run.script < 0 { s = "<sub>\(s)</sub>" }
            if run.strike { s = "<s>\(s)</s>" }
            if run.underline { s = "<u>\(s)</u>" }
            if run.italic { s = "<em>\(s)</em>" }
            if run.bold && !heading { s = "<strong>\(s)</strong>" }
            var css: [String] = []
            if let c = run.color { css.append("color: #\(c)") }
            if let family = run.family { css.append("font-family: \(cssFamily(family, mono: false))") }
            if !heading, !run.code, run.script == 0, abs(run.size - doc.bodySize) > 0.6 { css.append("font-size: \(fmt(run.size))pt") }
            if let hl = run.highlight { s = "<mark style=\"background-color: #\(hl)\">\(s)</mark>" }
            if !css.isEmpty { s = "<span style=\"\(css.joined(separator: "; "))\">\(s)</span>" }
            out += s
        }
        if openLink != nil { out += "</a>" }
        return out
    }
}

/// Makes HTML safe to import offline: anything that would load from the network (pictures, stylesheets,
/// scripts, frames, CSS url()s, refreshes, <base>) is removed before Cocoa's importer sees it. Links people
/// click (<a href>) are kept. While the importer runs, a URL protocol also refuses http(s) as a backstop.
enum OfflineHTML {
    static let remote = "(?:https?:|ftp:|wss?:|//)"

    static func sanitize(_ html: String) -> String {
        // Linear scans rather than lazy regular expressions, which go quadratic on many unclosed tags.
        var s = MDHTMLScan.removingElements(html, ["script"])   // an unclosed script swallows the rest, as in browsers
        s = MDHTMLScan.removingElements(s, ["iframe", "frame", "frameset", "object", "embed", "applet", "noscript", "portal"], keepUnclosed: true)
        s = MDHTMLScan.rewritingTags(s, ["script", "iframe", "frame", "frameset", "object", "embed", "applet", "base", "portal", "meta"]) { name, tag in
            guard name == "meta" else { return nil }
            return tag.range(of: "http-equiv\\s*=\\s*[\"']?\\s*refresh", options: [.regularExpression, .caseInsensitive]) == nil ? tag : nil
        }
        // CSS in <style> blocks; style attributes are cleaned in rewriteTags.
        s = MDHTMLScan.rewritingContent(s, of: "style", cleanCSS)
        return rewriteTags(s)
    }

    /// Remote url(...) and @import removed from CSS.
    static func cleanCSS(_ css: String) -> String {
        let ci: NSString.CompareOptions = [.regularExpression, .caseInsensitive]
        // The address itself becomes an empty data: URL (no scan to a closing ')' or ';', which can be missing).
        return css.replacingOccurrences(of: "@import\\s+(url\\()?\\s*(&quot;|['\"])?\\s*\(remote)", with: "@import $1$2data:,", options: ci)
            .replacingOccurrences(of: "url\\(\\s*(&quot;|['\"])?\\s*\(remote)", with: "url($1data:,", options: ci)
            .replacingOccurrences(of: "url\\(\\s*(&quot;|['\"])?\\s*file:", with: "url($1data:,", options: ci)
    }

    /// Per-tag attribute cleanup: remote pictures become their alt text, remote stylesheets go, and any
    /// other loading attribute pointing at the network is dropped.
    private static func rewriteTags(_ html: String) -> String {
        guard let tagRE = try? NSRegularExpression(pattern: "<([A-Za-z][A-Za-z0-9:-]*)(\\s[^<>]*)?>"),
              let attrRE = try? NSRegularExpression(pattern: "([A-Za-z_:][-A-Za-z0-9_:.]*)(\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s\"'=<>`]+))?")
        else { return html }
        let loading: Set<String> = ["src", "srcset", "href", "poster", "background", "data", "xlink:href", "action",
                                    "formaction", "lowsrc", "dynsrc", "codebase", "archive", "manifest", "ping", "imagesrcset"]
        let ns = html as NSString
        var out = "", last = 0
        for m in tagRE.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = NSMaxRange(m.range)
            let tag = ns.substring(with: m.range(at: 1)).lowercased()
            guard m.range(at: 2).location != NSNotFound else { out += ns.substring(with: m.range); continue }
            let attrText = ns.substring(with: m.range(at: 2))
            let attrNS = attrText as NSString
            var kept: [String] = []
            var dropTag = false
            var alt = ""
            for a in attrRE.matches(in: attrText, range: NSRange(location: 0, length: attrNS.length)) {
                let name = attrNS.substring(with: a.range(at: 1)).lowercased()
                let raw = attrNS.substring(with: a.range)
                var value = a.range(at: 3).location != NSNotFound ? attrNS.substring(with: a.range(at: 3)) : ""
                if value.hasPrefix("\"") || value.hasPrefix("'") { value = String(value.dropFirst().dropLast()) }
                if name == "alt" { alt = value }
                let decoded = MDInlineParser.decodeEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
                let isRemote = decoded.range(of: "^\(remote)", options: [.regularExpression, .caseInsensitive]) != nil
                    || (name.hasSuffix("srcset") && decoded.range(of: "(^|,)\\s*\(remote)", options: [.regularExpression, .caseInsensitive]) != nil)
                if name == "ping" { continue }
                if (tag == "a" || tag == "area") && name == "href" { kept.append(raw); continue }
                if name.hasPrefix("on") { continue }   // event handlers
                if name == "style" { kept.append("style=\"" + cleanCSS(value).replacingOccurrences(of: "\"", with: "&quot;") + "\""); continue }
                if loading.contains(name) && isRemote {
                    if tag == "img" || tag == "image" || tag == "input" || tag == "link" { dropTag = true }
                    continue
                }
                kept.append(raw)
            }
            if dropTag {
                if tag == "img", !alt.isEmpty { out += "<span>[\(alt)]</span>" }
                continue
            }
            out += "<\(ns.substring(with: m.range(at: 1)))" + (kept.isEmpty ? "" : " " + kept.joined(separator: " ")) + ">"
        }
        out += ns.substring(from: last)
        return out
    }

    /// Imports HTML with Cocoa on the main thread, offline. `base` resolves relative pictures (local files
    /// inside its folder only).
    static func importHTML(_ html: String, base: URL?, sanitizing: Bool = true) throws -> NSAttributedString {
        var clean = sanitizing ? sanitize(html) : html
        clean = inlineLocalPictures(clean, base: base?.isFileURL == true ? base : nil)
        let data = Data(clean.utf8)
        return try MainThread.sync {
            URLProtocol.registerClass(OfflineURLProtocol.self)
            // Local files outside the document's folder are refused too (stylesheets, frames, anything WebKit loads).
            OfflineURLProtocol.allowedFolder = base?.isFileURL == true ? base!.deletingLastPathComponent() : nil
            defer { URLProtocol.unregisterClass(OfflineURLProtocol.self); OfflineURLProtocol.allowedFolder = nil }
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
                .timeout: 20,
            ]
            options[.baseURL] = base ?? FileManager.default.temporaryDirectory
            return try NSAttributedString(data: data, options: options, documentAttributes: nil)
        }
    }

    /// Local pictures become data: URLs: only files inside the document's own folder (`base` is the
    /// document), never file: URLs, absolute paths or ../ escapes. Cocoa's importer loads files
    /// asynchronously, and the first import in a process often returns before they arrive (leaving a
    /// generic icon); data: URLs are decoded in line. A local picture that can't be used (missing, not a
    /// picture, or outside the folder) becomes its alt text, so neither the file nor a "?" icon gets in.
    static func inlineLocalPictures(_ html: String, base: URL?) -> String {
        guard let attrRE = try? NSRegularExpression(pattern: "([A-Za-z_:][-A-Za-z0-9_:.]*)(\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s\"'=<>`]+))?")
        else { return html }
        return MDHTMLScan.rewritingTags(html, ["img", "image", "input", "source"]) { name, tag in
            if tag.hasPrefix("</") { return tag }
            // Attributes in order (quoted values are skipped whole), without srcset: the plain src is what
            // the importer shows, and candidates elsewhere on the disk must not load.
            let inner = (tag as NSString).substring(with: NSRange(location: 1 + name.utf16.count, length: max(0, tag.utf16.count - 2 - name.utf16.count)))
            let ns = inner as NSString
            var kept: [String] = []
            var src: String?
            var srcIndex: Int?
            for m in attrRE.matches(in: inner, range: NSRange(location: 0, length: ns.length)) {
                let attr = ns.substring(with: m.range(at: 1)).lowercased()
                if attr == "/" { continue }
                var value = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : ""
                if value.hasPrefix("\"") || value.hasPrefix("'") { value = String(value.dropFirst().dropLast()) }
                if attr == "srcset" { continue }
                if attr == "src" || (name == "image" && attr.hasSuffix("href")) {
                    if src != nil { continue }
                    src = MDInlineParser.decodeEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
                    srcIndex = kept.count
                }
                kept.append(ns.substring(with: m.range))
            }
            func rebuilt() -> String { "<\(name)" + (kept.isEmpty ? "" : " " + kept.joined(separator: " ")) + ">" }
            guard let src, !src.isEmpty, let srcIndex else { return name == "img" || name == "image" ? altText(tag) : rebuilt() }
            let lower = src.lowercased()
            if lower.hasPrefix("data:") || lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("//") { return rebuilt() }
            guard name == "img" || name == "image" || name == "input" else { return altText(tag) }
            if let file = MDRenderer.localFile(src, base: base),
               let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, size < 40_000_000,
               let data = try? Data(contentsOf: file),
               let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image), let mime = type.preferredMIMEType {
                kept[srcIndex] = "\(name == "image" ? "href" : "src")=\"data:\(mime);base64,\(data.base64EncodedString())\""
                return rebuilt()
            }
            return altText(tag)
        }
    }

    /// An <img> tag's alt text as plain markup (empty when it has none).
    private static func altText(_ tag: String) -> String {
        let alt = MDRenderer.htmlAttributes(tag)["alt"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return alt.isEmpty ? "" : "<span>[\(richXMLEscape(alt))]</span>"
    }

    /// Decodes HTML bytes: BOM, then <meta charset>, then UTF-8, then Windows-1252.
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) || data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return RichPlainText.decode(data).text
        }
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        if let r = head.range(of: "charset\\s*=\\s*[\"']?([A-Za-z0-9_-]+)", options: [.regularExpression, .caseInsensitive]) {
            let name = head[r].components(separatedBy: "=").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) ?? ""
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: enc) { return s }
            }
        }
        return RichPlainText.decode(data).text
    }

    /// A Safari web archive's main page with its saved pictures and stylesheets inlined (as data: URLs
    /// and <style> blocks), so nothing needs fetching.
    static func webArchive(_ url: URL) throws -> NSAttributedString {
        let data = try Data(contentsOf: url)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let main = plist["WebMainResource"] as? [String: Any],
              let mainData = main["WebResourceData"] as? Data else { throw ConversionError.unreadable(url.lastPathComponent) }
        let mime = (main["WebResourceMIMEType"] as? String ?? "text/html").lowercased()
        if mime.hasPrefix("text/plain") { return RichPlainText.attributed(RichPlainText.decode(mainData).text) }
        var html: String
        if let name = main["WebResourceTextEncodingName"] as? String,
           case let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString), cf != kCFStringEncodingInvalidId,
           let s = String(data: mainData, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
            html = s
        } else {
            html = decode(mainData)
        }
        let pageURL = (main["WebResourceURL"] as? String).flatMap(URL.init(string:))
        var resources: [String: (data: Data, mime: String)] = [:]
        for r in plist["WebSubresources"] as? [[String: Any]] ?? [] {
            guard let u = r["WebResourceURL"] as? String, let d = r["WebResourceData"] as? Data else { continue }
            resources[u] = (d, (r["WebResourceMIMEType"] as? String ?? "").lowercased())
        }
        if !resources.isEmpty { html = inlineResources(html, page: pageURL, resources) }
        return try importHTML(html, base: nil)
    }

    private static func inlineResources(_ html: String, page: URL?, _ resources: [String: (data: Data, mime: String)]) -> String {
        func lookup(_ raw: String) -> (data: Data, mime: String)? {
            let v = MDInlineParser.decodeEntities(raw).trimmingCharacters(in: .whitespaces)
            if let r = resources[v] { return r }
            if let abs = URL(string: v, relativeTo: page)?.absoluteString { return resources[abs] }
            return nil
        }
        var s = html
        // <link rel=stylesheet href=…> → <style>…</style>
        if let re = try? NSRegularExpression(pattern: "<link\\b[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>", options: .caseInsensitive) {
            let ns = s as NSString
            var out = "", last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                last = NSMaxRange(m.range)
                if let r = lookup(ns.substring(with: m.range(at: 1))), r.mime.contains("css") {
                    out += "<style>" + String(decoding: r.data, as: UTF8.self) + "</style>"
                }
            }
            s = out + ns.substring(from: last)
        }
        // src="…" and url(…) for saved pictures → data: URLs.
        for pattern in ["(\\ssrc\\s*=\\s*[\"'])([^\"']+)([\"'])", "(url\\(\\s*[\"']?)([^\"')]+)([\"']?\\s*\\))"] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let ns = s as NSString
            var out = "", last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                last = NSMaxRange(m.range)
                if let r = lookup(ns.substring(with: m.range(at: 2))), r.mime.hasPrefix("image/") {
                    out += ns.substring(with: m.range(at: 1)) + "data:\(r.mime);base64,\(r.data.base64EncodedString())" + ns.substring(with: m.range(at: 3))
                } else {
                    out += ns.substring(with: m.range)
                }
            }
            s = out + ns.substring(from: last)
        }
        return s
    }
}

/// Refuses network loads while HTML is imported (second line of defence after OfflineHTML.sanitize).
final class OfflineURLProtocol: URLProtocol {
    static let refused = OfflineLoadCounter()
    private static let lock = NSLock()
    private static var folder: String?
    /// While an import runs: the only folder (and below) local files may load from; nil refuses every file.
    static var allowedFolder: URL? {
        get { lock.lock(); defer { lock.unlock() }; return folder.map { URL(fileURLWithPath: $0) } }
        set {
            lock.lock(); defer { lock.unlock() }
            folder = newValue.map { u in
                let p = u.standardizedFileURL.resolvingSymlinksInPath().path
                return p.hasSuffix("/") ? p : p + "/"
            }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url, let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "file" {
            lock.lock(); let root = folder; lock.unlock()
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard let root else { return true }
            return !(path + "/").hasPrefix(root) && !path.hasPrefix(root)
        }
        return ["http", "https", "ftp", "ws", "wss"].contains(scheme)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        OfflineURLProtocol.refused.increment()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// A thread-safe counter (how many loads the offline protocol refused; used by the self-test).
final class OfflineLoadCounter {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
