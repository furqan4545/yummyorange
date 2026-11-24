import AppKit

/// Rich-text document reading and writing, shared by every module that handles text documents
/// (TextDocuments owns this file; EbooksAndPages and others call it).
/// The signatures below are a contract: keep them, extend the bodies.
enum DocumentIO {
    /// Files bigger than this aren't read (no real text document is that large).
    static let maxBytes = 400_000_000

    /// Reads a text document (Ext.textDocuments: docx, doc, rtf, rtfd, html, txt, md, odt, textClipping,
    /// webarchive) into rich text. The format is taken from the file's first bytes where they say more
    /// than its extension does (an RTF named .doc, HTML named .doc, and so on).
    static func read(_ url: URL) throws -> NSAttributedString {
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else { throw ConversionError.unreadable(name) }
        let ext = Ext.of(url)
        if !Ext.isFolder(url) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > maxBytes { throw ConversionError.unsupported("\(name) is too large to open as a document.") }
        }
        do {
            switch sniff(url) ?? ext {
            case "md", "markdown", "mdown", "mkd":
                return MarkdownReader.read(RichPlainText.decode(try Data(contentsOf: url)).text, baseURL: url)
            case "txt", "text":
                return try RichPlainText.read(url)
            case "html", "htm", "xhtml":
                return try OfflineHTML.importHTML(OfflineHTML.decode(try Data(contentsOf: url)), base: url)
            case "webarchive":
                return try OfflineHTML.webArchive(url)
            case "textclipping":
                return try RichPlainText.readClipping(url)
            case "rtf":
                return try RichRTF.read(data: try Data(contentsOf: url))
            case "docx":
                // YummyOrange's own reader; Cocoa's importer only if that fails on something unusual (never for a
                // file refused on purpose, and never for one whose XML declares entities).
                do { return try RichDOCXReader.read(url) } catch let error as ConversionError { throw error } catch {}
                if let why = RichDOCXReader.unsafePart(url) { throw RichDOCXReader.refusal(url, why) }
                return try cocoa(url, .officeOpenXML)
            case "doc":
                return try cocoa(url, .docFormat)
            case "odt":
                return try RichODTReader.read(url)
            case "rtfd":
                return try cocoa(url, .rtfd)
            default:
                return try MainThread.sync { try NSAttributedString(url: url, options: [:], documentAttributes: nil) }
            }
        } catch let error as ConversionError {
            throw error
        } catch {
            throw ConversionError.unreadable(name)
        }
    }

    private static func cocoa(_ url: URL, _ type: NSAttributedString.DocumentType) throws -> NSAttributedString {
        try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
    }

    /// The real format of a file whose first bytes disagree with its extension, or nil to trust the extension.
    static func sniff(_ url: URL) -> String? {
        guard !Ext.isFolder(url), let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 512)) ?? Data()
        let ext = Ext.of(url)
        if head.starts(with: Array("{\\rtf".utf8)) { return ext == "rtf" ? nil : "rtf" }
        if head.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { return ext == "doc" ? nil : "doc" }
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]), ["doc", "docx", "odt"].contains(ext),
           let zip = try? ZipReader(url: url) {
            if zip.contains("word/document.xml") { return "docx" }
            if zip.contains("content.xml") { return "odt" }
        }
        if ["doc", "txt", "text"].contains(ext) {
            let text = String(decoding: head, as: UTF8.self).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if ext == "doc", text.hasPrefix("<html") || text.hasPrefix("<!doctype html") || text.contains("<html") { return "html" }
            if ext == "doc", head.allSatisfy({ $0 >= 0x09 }) { return "txt" }   // plain text saved with a .doc name
        }
        return nil
    }

    /// Writes rich text in the format named by `ext` (docx, doc, rtf, rtfd, html, txt, md, odt, pdf).
    static func write(_ text: NSAttributedString, to url: URL, ext: String) throws {
        _ = try write(text, to: url, ext: ext, page: .regional)
    }

    /// Like `write(_:to:ext:)`, with a page setup for paged formats. Returns every file written
    /// (Markdown also writes a folder for its pictures).
    static func write(_ source: NSAttributedString, to url: URL, ext: String, page: RichPageSetup, pageNumbers: Bool = true) throws -> [URL] {
        let text = safeLinks(source)
        let range = NSRange(location: 0, length: text.length)
        let title = documentTitle(text, url: url)
        do {
            switch ext.lowercased() {
            case "docx":
                try RichDOCXWriter.write(RichDocument(text, title: title), to: url, page: page)
            case "odt":
                try RichODTWriter.write(RichDocument(text, title: title), to: url, page: page)
            case "html", "htm":
                try Data(RichHTMLWriter.html(RichDocument(text, title: title)).utf8).write(to: url, options: .atomic)
            case "md", "markdown":
                return try writeMarkdown(RichDocument(text, title: title), to: url)
            case "txt", "text":
                try Data(RichPlainText.text(RichDocument(text, title: title)).utf8).write(to: url, options: .atomic)
            case "rtf":
                try RichRTF.write(flattenedBlocks(text)).write(to: url, options: .atomic)
            case "rtfd":
                let wrapper = try flattenedBlocks(text).fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
                try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
            case "doc":
                let data = try flattenedBlocks(text).data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.docFormat])
                try data.write(to: url, options: .atomic)
            case "webarchive":
                let data = try MainThread.sync {
                    try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.webArchive])
                }
                try data.write(to: url, options: .atomic)
            case "pdf":
                try RichPDFLayout.write(text, to: url, options: RichPDFLayout.Options(page: page, pageNumbers: pageNumbers, title: title))
            default:
                throw ConversionError.unsupported("Can’t write \(ext.uppercased()) documents.")
            }
        } catch let error as ConversionError {
            try? FileManager.default.removeItem(at: url)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ConversionError.toolFailed("Couldn’t save \(url.lastPathComponent): \(error.localizedDescription)")
        }
        return [url]
    }

    /// The text with links whose scheme could run script (javascript:, vbscript:, data:…) or open local files
    /// turned into plain text, so no output format carries them on.
    static func safeLinks(_ text: NSAttributedString) -> NSAttributedString {
        var unsafe: [NSRange] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let link = (value as? URL)?.absoluteString ?? value as? String
            if let link, !RichDocument.isSafeLink(link) { unsafe.append(range) }
        }
        guard !unsafe.isEmpty else { return text }
        let out = NSMutableAttributedString(attributedString: text)
        let blue = RichDocument.hex(RichStyle.linkColor)
        for r in unsafe {
            out.removeAttribute(.link, range: r)
            // The link look goes with the link.
            out.enumerateAttribute(.foregroundColor, in: r) { v, sub, _ in
                if let c = v as? NSColor, RichDocument.hex(c) == blue { out.removeAttribute(.foregroundColor, range: sub) }
            }
        }
        return out
    }

    /// Markdown plus, when there are pictures, a "<name> images" folder beside it that the text links to.
    /// When anything can't be written (a full disk), the folder goes too: no half-filled folder is left behind.
    static func writeMarkdown(_ doc: RichDocument, to url: URL) throws -> [URL] {
        var folder: URL?
        var used: Set<String> = []
        var failure: Error?
        let markdown = MarkdownWriter.markdown(doc) { image in
            guard failure == nil else { return nil }
            do {
                if folder == nil {
                    let base = url.deletingPathExtension().lastPathComponent + " images"
                    var candidate = url.deletingLastPathComponent().appendingPathComponent(base, isDirectory: true)
                    var n = 2
                    while FileManager.default.fileExists(atPath: candidate.path) {
                        candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n)", isDirectory: true); n += 1
                    }
                    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
                    folder = candidate
                }
                var name = image.name
                var n = 2
                while used.contains(name.lowercased()) {
                    name = (image.name as NSString).deletingPathExtension + "-\(n)." + image.fileExtension; n += 1
                }
                used.insert(name.lowercased())
                try image.data.write(to: folder!.appendingPathComponent(name))
                let rel = folder!.lastPathComponent + "/" + name
                return rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rel
            } catch {
                failure = error
                return nil
            }
        }
        do {
            if let failure { throw failure }
            try Data(markdown.utf8).write(to: url, options: .atomic)
        } catch {
            // The folder was made for this file just now, so it holds nothing else.
            if let folder { try? FileManager.default.removeItem(at: folder) }
            throw error
        }
        return [url] + (folder.map { [$0] } ?? [])
    }

    /// Cocoa's RTF and Word writers turn plain NSTextBlocks (quotes, code, rules) into table rows that swallow
    /// the rest of the document when read back. Only table cells keep their blocks; quotes become indented
    /// paragraphs, code keeps its font, and rules become a marker RTF output turns into a paragraph border.
    static func flattenedBlocks(_ text: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: out.length)
        var changes: [(NSRange, NSParagraphStyle)] = []
        out.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            guard let style = value as? NSParagraphStyle, style.textBlocks.contains(where: { !($0 is NSTextTableBlock) }) else { return }
            let fixed = style.mutableCopy() as! NSMutableParagraphStyle
            fixed.textBlocks = style.textBlocks.filter { $0 is NSTextTableBlock }
            if let depth = out.attribute(.dwQuote, at: range.location, effectiveRange: nil) as? Int {
                fixed.headIndent += 18 * CGFloat(depth)
                fixed.firstLineHeadIndent += 18 * CGFloat(depth)
            }
            changes.append((range, fixed))
        }
        for (range, style) in changes { out.addAttribute(.paragraphStyle, value: style, range: range) }
        var rules: [NSRange] = []
        out.enumerateAttribute(.dwRule, in: full) { value, range, _ in if value != nil { rules.append(range) } }
        for r in rules.reversed() {
            let para = (out.string as NSString).paragraphRange(for: r)
            guard (out.string as NSString).substring(with: para).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var attrs = out.attributes(at: para.location, effectiveRange: nil)
            attrs[.font] = RichStyle.font(size: 6)
            out.replaceCharacters(in: para, with: NSAttributedString(string: RichRTF.ruleToken + "\n", attributes: attrs))
        }
        return out
    }

    /// The first top-level heading, else the file's name.
    static func documentTitle(_ text: NSAttributedString, url: URL) -> String {
        let ns = text.string as NSString
        var title: String?
        var location = 0
        var checked = 0
        while location < ns.length, checked < 60, title == nil {
            let r = ns.paragraphRange(for: NSRange(location: location, length: 0))
            if let style = text.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle, style.headerLevel == 1 {
                let t = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { title = String(t.prefix(200)) }
            }
            location = NSMaxRange(r)
            checked += 1
        }
        return title ?? url.deletingPathExtension().lastPathComponent
    }

    /// Lays rich text out on pages and saves it as a PDF: A4 or US Letter from the region, one-inch
    /// margins, page numbers in the footer, pictures drawn, links clickable.
    static func writePDF(_ text: NSAttributedString, to url: URL) throws {
        _ = try write(text, to: url, ext: "pdf", page: .regional)
    }
}
