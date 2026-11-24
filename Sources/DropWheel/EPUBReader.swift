import Foundation

extension EbooksAndPages {
    /// The files of a package document, whether it is a ZIP archive (an `.epub` or `.pages` file) or an
    /// unpacked folder (Apple Books keeps EPUBs as folders; Pages can save packages).
    final class Package {
        let url: URL
        let isFolder: Bool
        private let zip: ZipReader?
        private var folderIndex: [String: String] = [:]   // lower-cased path → real path

        /// `kind` names the format in errors, with its article ("an EPUB book", "a Pages document").
        /// A folder package lists only the regular files inside it: symbolic links are skipped, so a planted
        /// link can't pull in a file from elsewhere on the disk.
        init(_ url: URL, kind: String = "a package") throws {
            self.url = url
            isFolder = Ext.isFolder(url)
            if isFolder {
                zip = nil
                let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
                let root = url.resolvingSymlinksInPath().path + "/"
                if let walker = FileManager.default.enumerator(atPath: url.path) {
                    for case let rel as String in walker {
                        let file = url.appendingPathComponent(rel)
                        guard let values = try? file.resourceValues(forKeys: keys), values.isSymbolicLink != true,
                              values.isRegularFile == true, file.resolvingSymlinksInPath().path.hasPrefix(root) else { continue }
                        folderIndex[rel.lowercased()] = rel
                    }
                }
            } else {
                do { zip = try ZipReader(url: url) } catch ZipError.notZip {
                    throw ConversionError.unsupported("\(url.lastPathComponent) is damaged or isn’t really \(kind) (it isn’t a ZIP archive).")
                }
            }
        }

        var paths: [String] {
            if let zip { return zip.entries.filter { !$0.isDirectory }.map(\.name) }
            return Array(folderIndex.values).sorted()
        }

        private func realPath(_ path: String) -> String? {
            let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
            if let zip { return zip.entry(clean)?.name }
            return folderIndex[clean.lowercased()]
        }

        func exists(_ path: String) -> Bool { realPath(path) != nil }

        func data(_ path: String) throws -> Data {
            guard let real = realPath(path) else { throw ZipError.missing(path) }
            if let zip { return try zip.read(real) }
            let file = url.appendingPathComponent(real)
            // Re-checked at read time: the file may have been swapped for a link since the folder was listed.
            guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { throw ZipError.missing(path) }
            return try Data(contentsOf: file)
        }

        /// Copies every file into `dir` (which must exist).
        func extract(to dir: URL) throws {
            if let zip {
                try zip.extractAll(to: dir)
                return
            }
            for rel in folderIndex.values {
                let target = dir.appendingPathComponent(rel)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url.appendingPathComponent(rel), to: target)
            }
        }

        /// Resolves an href found in `base` (a file inside the package) to a package path:
        /// percent-decoded, "../" folded, fragment and query removed.
        static func resolve(_ href: String, relativeTo base: String) -> String {
            var h = href
            if let hash = h.firstIndex(of: "#") { h = String(h[..<hash]) }
            if let q = h.firstIndex(of: "?") { h = String(h[..<q]) }
            h = h.removingPercentEncoding ?? h
            h = h.replacingOccurrences(of: "\\", with: "/")
            var parts: [Substring] = h.hasPrefix("/") ? [] : base.split(separator: "/").dropLast()
            for p in h.split(separator: "/") {
                if p == "." || p.isEmpty { continue }
                if p == ".." { if !parts.isEmpty { parts.removeLast() } } else { parts.append(p) }
            }
            return parts.joined(separator: "/")
        }

        static func isRemote(_ href: String) -> Bool {
            guard let colon = href.firstIndex(of: ":") else { return false }
            let scheme = href[..<colon].lowercased()
            return scheme.count > 1 && scheme.allSatisfy { $0.isLetter || $0 == "+" || $0 == "-" || $0 == "." }
        }
    }
}

/// An EPUB 2 or 3 book: container.xml → OPF package → manifest, spine and table of contents.
/// Tolerates the usual sloppiness: a missing container.xml, odd case or percent-encoding in hrefs,
/// wrong media types, spine entries that point nowhere, HTML that isn't XML.
final class EPUBBook {
    struct Item {
        let id: String
        let path: String
        let mediaType: String
        let properties: Set<String>
        var isDocument: Bool {
            let ext = (path as NSString).pathExtension.lowercased()
            return mediaType.contains("html") || ["xhtml", "html", "htm"].contains(ext)
                || (mediaType == "application/xml" && ext == "xml")
        }
        var isSVG: Bool { mediaType == "image/svg+xml" || path.lowercased().hasSuffix(".svg") }
    }

    struct TOCEntry {
        let title: String
        let path: String
        let fragment: String?
        let depth: Int
    }

    typealias Doc = EbooksAndPages.Doc
    typealias Package = EbooksAndPages.Package

    let package: Package
    let opfPath: String
    private(set) var title: String?
    private(set) var authors: [String] = []
    private(set) var language: String?
    private(set) var identifier: String?
    private(set) var manifest: [String: Item] = [:]
    private(set) var spine: [Item] = []
    private(set) var toc: [TOCEntry] = []
    private(set) var coverImagePath: String?

    convenience init(url: URL) throws {
        try self.init(package: try Package(url, kind: "an EPUB book"), name: url.lastPathComponent)
    }

    init(package: Package, name: String) throws {
        self.package = package
        try Self.checkDRM(package, name: name)

        // 1. container.xml → the OPF path; without it, any .opf in the package.
        var opf: String?
        if let data = try? package.data("META-INF/container.xml"), let doc = EbooksAndPages.parseMarkup(data) {
            for rootfile in EbooksAndPages.elements(doc, named: "rootfile") {
                guard let path = EbooksAndPages.attribute(rootfile, "full-path"), package.exists(path) else { continue }
                let type = EbooksAndPages.attribute(rootfile, "media-type") ?? ""
                if type.isEmpty || type.contains("oebps-package") { opf = path; break }
            }
        }
        if opf == nil { opf = package.paths.first { $0.lowercased().hasSuffix(".opf") } }
        guard let opfPath = opf, let opfData = try? package.data(opfPath), let opfDoc = EbooksAndPages.parseMarkup(opfData) else {
            if package.paths.contains(where: { $0.lowercased().hasSuffix(".xhtml") || $0.lowercased().hasSuffix(".html") }) {
                throw ConversionError.unsupported("\(name) is missing its package file (content.opf), so its chapters can’t be found.")
            }
            throw ConversionError.unsupported("\(name) doesn’t look like an EPUB book.")
        }
        self.opfPath = opfPath

        // 2. Metadata.
        let root = opfDoc.rootElement()!
        let metadata = EbooksAndPages.firstElement(root, named: "metadata") ?? root
        title = EbooksAndPages.elements(metadata, named: "title").map(EbooksAndPages.textContent).first { !$0.isEmpty }
        authors = EbooksAndPages.elements(metadata, named: "creator").map(EbooksAndPages.textContent).filter { !$0.isEmpty }
        language = EbooksAndPages.elements(metadata, named: "language").map(EbooksAndPages.textContent).first { !$0.isEmpty }
        let uidName = EbooksAndPages.attribute(root, "unique-identifier")
        let ids = EbooksAndPages.elements(metadata, named: "identifier")
        identifier = (ids.first { uidName != nil && EbooksAndPages.attribute($0, "id") == uidName } ?? ids.first)
            .map(EbooksAndPages.textContent)
        var coverID: String?
        for meta in EbooksAndPages.elements(metadata, named: "meta") where EbooksAndPages.attribute(meta, "name") == "cover" {
            coverID = EbooksAndPages.attribute(meta, "content")
        }

        // 3. Manifest.
        var navPath: String?
        for item in EbooksAndPages.elements(root, named: "item") {
            guard let id = EbooksAndPages.attribute(item, "id"), let href = EbooksAndPages.attribute(item, "href"),
                  !Package.isRemote(href) else { continue }
            let props = Set((EbooksAndPages.attribute(item, "properties") ?? "").split(separator: " ").map(String.init))
            let entry = Item(id: id, path: Package.resolve(href, relativeTo: opfPath),
                             mediaType: (EbooksAndPages.attribute(item, "media-type") ?? "").lowercased(), properties: props)
            manifest[id] = entry
            if props.contains("nav") { navPath = entry.path }
            if props.contains("cover-image") { coverImagePath = entry.path }
        }
        if coverImagePath == nil, let coverID, let item = manifest[coverID], item.mediaType.hasPrefix("image") {
            coverImagePath = item.path
        }

        // 4. Spine (manifest order if the spine is missing or empty).
        let spineElement = EbooksAndPages.firstElement(root, named: "spine")
        for ref in spineElement.map({ EbooksAndPages.elements($0, named: "itemref") }) ?? [] {
            guard let idref = EbooksAndPages.attribute(ref, "idref"), let item = manifest[idref],
                  item.isDocument || item.isSVG, package.exists(item.path) else { continue }
            if !spine.contains(where: { $0.path == item.path }) { spine.append(item) }
        }
        if spine.isEmpty {
            let orderedItems = EbooksAndPages.elements(root, named: "item").compactMap { EbooksAndPages.attribute($0, "id") }
                .compactMap { manifest[$0] }
            spine = orderedItems.filter { $0.isDocument && $0.path != navPath && package.exists($0.path) }
        }

        // 5. Table of contents: EPUB 3 nav document, else EPUB 2 NCX.
        if let navPath, let data = try? package.data(navPath), let nav = EbooksAndPages.parseMarkup(data) {
            toc = Self.navEntries(nav, base: navPath)
        }
        if toc.isEmpty {
            let ncxID = spineElement.flatMap { EbooksAndPages.attribute($0, "toc") }
            let ncxPath = ncxID.flatMap { manifest[$0]?.path }
                ?? manifest.values.first { $0.mediaType == "application/x-dtbncx+xml" || $0.path.lowercased().hasSuffix(".ncx") }?.path
            if let ncxPath, let data = try? package.data(ncxPath), let ncx = EbooksAndPages.parseMarkup(data) {
                toc = Self.ncxEntries(ncx, base: ncxPath)
            }
        }
    }

    /// DRM-protected books can't be read. Font obfuscation (IDPF and Adobe) is fine: it only hides fonts.
    private static func checkDRM(_ package: Package, name: String) throws {
        let protected = ConversionError.unsupported("\(name) is protected with DRM, so it can’t be converted.")
        if package.exists("META-INF/sinf.xml") { throw protected }
        guard let data = try? package.data("META-INF/encryption.xml"), let doc = EbooksAndPages.parseMarkup(data) else { return }
        for encrypted in EbooksAndPages.elements(doc, named: "encrypteddata") {
            let method = EbooksAndPages.firstElement(encrypted, named: "encryptionmethod")
                .flatMap { EbooksAndPages.attribute($0, "algorithm") } ?? ""
            if method == "http://www.idpf.org/2008/embedding" || method == "http://ns.adobe.com/pdf/enc#RC" { continue }
            let uri = EbooksAndPages.firstElement(encrypted, named: "cipherreference")
                .flatMap { EbooksAndPages.attribute($0, "uri") }?.lowercased() ?? ""
            let fontLike = [".otf", ".ttf", ".woff", ".woff2"].contains { uri.hasSuffix($0) }
            if !fontLike { throw protected }
        }
    }

    private static func navEntries(_ nav: XMLDocument, base: String) -> [TOCEntry] {
        let navs = EbooksAndPages.elements(nav, named: "nav")
        guard let tocNav = navs.first(where: { (EbooksAndPages.attribute($0, "type") ?? "").contains("toc") }) ?? navs.first,
              let list = EbooksAndPages.firstElement(tocNav, named: "ol") else { return [] }
        var out: [TOCEntry] = []
        func walk(_ ol: XMLElement, depth: Int) {
            for li in ol.children ?? [] {
                guard let li = li as? XMLElement, EbooksAndPages.localName(li) == "li" else { continue }
                for child in li.children ?? [] {
                    guard let c = child as? XMLElement else { continue }
                    let name = EbooksAndPages.localName(c)
                    if name == "a", let href = EbooksAndPages.attribute(c, "href"), !Package.isRemote(href) {
                        let frag = href.firstIndex(of: "#").map { String(href[href.index(after: $0)...]) }
                        out.append(TOCEntry(title: EbooksAndPages.textContent(c), path: Package.resolve(href, relativeTo: base),
                                            fragment: frag, depth: depth))
                    } else if name == "ol" {
                        walk(c, depth: depth + 1)
                    }
                }
            }
        }
        walk(list, depth: 0)
        return out
    }

    private static func ncxEntries(_ ncx: XMLDocument, base: String) -> [TOCEntry] {
        guard let navMap = EbooksAndPages.firstElement(ncx, named: "navmap") else { return [] }
        var out: [TOCEntry] = []
        func walk(_ e: XMLElement, depth: Int) {
            for child in e.children ?? [] {
                guard let point = child as? XMLElement, EbooksAndPages.localName(point) == "navpoint" else { continue }
                let label = EbooksAndPages.firstElement(point, named: "navlabel").map(EbooksAndPages.textContent) ?? ""
                if let content = (point.children ?? []).compactMap({ $0 as? XMLElement }).first(where: { EbooksAndPages.localName($0) == "content" }),
                   let src = EbooksAndPages.attribute(content, "src") {
                    let frag = src.firstIndex(of: "#").map { String(src[src.index(after: $0)...]) }
                    out.append(TOCEntry(title: label, path: Package.resolve(src, relativeTo: base), fragment: frag, depth: depth))
                }
                walk(point, depth: depth + 1)
            }
        }
        walk(navMap, depth: 0)
        return out
    }

    // MARK: Chapters

    /// A title for each spine item: its table-of-contents entry, else its <title> or first heading.
    func chapterTitles() -> [String] {
        spine.enumerated().map { i, item in
            if let entry = toc.first(where: { $0.path == item.path && !$0.title.isEmpty }) { return entry.title }
            if item.isDocument, let data = try? package.data(item.path), let doc = EbooksAndPages.parseMarkup(data) {
                for tag in ["h1", "h2", "title"] {
                    if let e = EbooksAndPages.firstElement(doc, named: tag) {
                        let t = EbooksAndPages.textContent(e)
                        if !t.isEmpty && t.count < 120 { return t }
                    }
                }
            }
            return i == 0 && item.path == coverImagePath ? "Cover" : "Chapter \(i + 1)"
        }
    }

    private var cssCache: [String: String] = [:]

    private func stylesheets(for doc: XMLDocument, at path: String) -> EbooksAndPages.CSSRules {
        var rules = EbooksAndPages.CSSRules()
        for link in EbooksAndPages.elements(doc, named: "link") {
            guard (EbooksAndPages.attribute(link, "rel") ?? "").lowercased().contains("stylesheet"),
                  let href = EbooksAndPages.attribute(link, "href"), !Package.isRemote(href) else { continue }
            let cssPath = Package.resolve(href, relativeTo: path)
            if cssCache[cssPath] == nil {
                cssCache[cssPath] = (try? package.data(cssPath)).map { EbooksAndPages.decodeText($0) } ?? ""
            }
            rules.add(cssCache[cssPath] ?? "")
        }
        return rules
    }

    /// The whole book in the document model, chapters in spine order separated by page breaks.
    func document(progress: (Double) -> Void = { _ in }) throws -> Doc {
        var doc = Doc(title: title, author: authors.isEmpty ? nil : authors.joined(separator: ", "), language: language)
        var pictureIDs: [String: String] = [:]
        for (i, item) in spine.enumerated() {
            defer { progress(Double(i + 1) / Double(max(spine.count, 1))) }
            let before = doc.blocks.count
            if item.isSVG {
                if let data = try? package.data(item.path), let id = doc.addPicture(data, ext: "svg") {
                    doc.blocks.append(.image(id: id, alt: "", width: nil))
                }
            } else {
                guard let data = try? package.data(item.path), let markup = EbooksAndPages.parseMarkup(data) else { continue }
                var importer = EbooksAndPages.HTMLImporter(css: stylesheets(for: markup, at: item.path)) { [package] src in
                    guard !Package.isRemote(src) || src.hasPrefix("data:") else { return nil }
                    if src.hasPrefix("data:") { return nil }
                    let path = Package.resolve(src, relativeTo: item.path)
                    if let id = pictureIDs[path] { return id }
                    guard let bytes = try? package.data(path),
                          let id = doc.addPicture(bytes, ext: (path as NSString).pathExtension) else { return nil }
                    pictureIDs[path] = id
                    return id
                }
                let blocks = importer.importBody(of: markup)
                doc.blocks += blocks
            }
            if doc.blocks.count > before, i < spine.count - 1 { doc.blocks.append(.pageBreak) }
        }
        doc.blocks = EbooksAndPages.tidyPageBreaks(doc.blocks)
        guard doc.hasText || doc.blocks.contains(where: { if case .image = $0 { return true } else { return false } }) else {
            throw ConversionError.unsupported("This book has no readable text.")
        }
        return doc
    }
}
