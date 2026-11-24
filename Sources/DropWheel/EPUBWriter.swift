import Foundation
import NaturalLanguage

/// Writes a document as an EPUB 3 book that EPUB 2 readers can also open: `mimetype` stored first,
/// an OPF package with a unique identifier and dcterms:modified, a nav.xhtml table of contents plus a
/// toc.ncx, one XHTML file per chapter, a stylesheet and the images.
enum EPUBWriter {
    typealias Doc = EbooksAndPages.Doc

    static func write(_ doc: Doc, to url: URL, fallbackTitle: String) throws {
        let chapters = EbooksAndPages.chapters(of: doc).filter { !$0.blocks.isEmpty }
        guard !chapters.isEmpty else { throw ConversionError.unsupported("There’s nothing to put in the book.") }

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("dropwheel-epub-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let oebps = dir.appendingPathComponent("OEBPS")
        try fm.createDirectory(at: oebps.appendingPathComponent("text"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("META-INF"), withIntermediateDirectories: true)

        let title = clean(doc.title).isEmpty ? fallbackTitle : clean(doc.title)
        let author = clean(doc.author)
        let language = doc.language.flatMap { $0.isEmpty ? nil : $0 } ?? detectLanguage(doc)
        let identifier = "urn:uuid:" + UUID().uuidString.lowercased()
        let modified = ISO8601DateFormatter().string(from: Date())   // e.g. 2026-11-23T10:15:00Z
        let esc = { (s: String) in EbooksAndPages.escapeXML(s, attribute: true) }

        try Data("application/epub+zip".utf8).write(to: dir.appendingPathComponent("mimetype"))
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>

        """.write(to: dir.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        try EbooksAndPages.bookCSS.write(to: oebps.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)

        // Images actually used, in order of first use.
        var used: [String] = []
        for chapter in chapters {
            for case let .image(id, _, _) in chapter.blocks where doc.pictures[id] != nil && !used.contains(id) { used.append(id) }
        }
        if !used.isEmpty { try fm.createDirectory(at: oebps.appendingPathComponent("images"), withIntermediateDirectories: true) }
        for id in used {
            let pic = doc.pictures[id]!
            try pic.data.write(to: oebps.appendingPathComponent("images/\(id).\(pic.ext)"))
        }
        // A book that opens with a picture uses it as the cover.
        var coverID: String?
        if let firstBlock = chapters.first?.blocks.first(where: { if case .pageBreak = $0 { return false }; return true }),
           case let .image(id, _, _) = firstBlock, let pic = doc.pictures[id], pic.ext != "svg" {
            coverID = id
        }

        // Chapters.
        var manifest = ""
        var spine = ""
        var navItems = ""
        var ncxPoints = ""
        for (i, chapter) in chapters.enumerated() {
            let name = String(format: "chapter-%03d", i + 1)
            let body = EbooksAndPages.xhtmlBody(chapter.blocks, imageSrc: { id in
                doc.pictures[id].map { "../images/\(id).\($0.ext)" }
            })
            let xhtml = EbooksAndPages.xhtmlDocument(title: chapter.title, language: language, body: body,
                                                     stylesheetHref: "../style.css", epub: true)
            try xhtml.write(to: oebps.appendingPathComponent("text/\(name).xhtml"), atomically: true, encoding: .utf8)
            manifest += "    <item id=\"\(name)\" href=\"text/\(name).xhtml\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "    <itemref idref=\"\(name)\"/>\n"
            navItems += "      <li><a href=\"text/\(name).xhtml\">\(esc(chapter.title))</a></li>\n"
            ncxPoints += """
                <navPoint id="nav-\(i + 1)" playOrder="\(i + 1)">
                  <navLabel><text>\(esc(chapter.title))</text></navLabel>
                  <content src="text/\(name).xhtml"/>
                </navPoint>

            """
        }
        for id in used {
            let pic = doc.pictures[id]!
            let props = id == coverID ? " properties=\"cover-image\"" : ""
            manifest += "    <item id=\"\(id)\" href=\"images/\(id).\(pic.ext)\" media-type=\"\(pic.mime)\"\(props)/>\n"
        }

        try EbooksAndPages.xhtmlDocument(title: title, language: language, body: """
        <nav epub:type="toc" id="toc">
          <h1>Contents</h1>
          <ol>
        \(navItems)  </ol>
        </nav>
        <nav epub:type="landmarks" id="landmarks" hidden="hidden">
          <ol>
            <li><a epub:type="toc" href="nav.xhtml">Contents</a></li>
            <li><a epub:type="bodymatter" href="text/chapter-001.xhtml">Start</a></li>
          </ol>
        </nav>

        """, stylesheetHref: "style.css", epub: true).write(to: oebps.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1" xml:lang="\(esc(language))">
          <head>
            <meta name="dtb:uid" content="\(esc(identifier))"/>
            <meta name="dtb:depth" content="1"/>
            <meta name="dtb:totalPageCount" content="0"/>
            <meta name="dtb:maxPageNumber" content="0"/>
          </head>
          <docTitle><text>\(esc(title))</text></docTitle>
        \(author.isEmpty ? "" : "  <docAuthor><text>\(esc(author))</text></docAuthor>\n")  <navMap>
        \(ncxPoints)  </navMap>
        </ncx>

        """.write(to: oebps.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)

        let creator = author.isEmpty ? "" : "    <dc:creator id=\"creator\">\(esc(author))</dc:creator>\n"
        let coverMeta = coverID.map { "    <meta name=\"cover\" content=\"\($0)\"/>\n" } ?? ""
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="\(esc(language))">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">\(esc(identifier))</dc:identifier>
            <dc:title>\(esc(title))</dc:title>
        \(creator)    <dc:language>\(esc(language))</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
        \(coverMeta)  </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>
        \(manifest)  </manifest>
          <spine toc="ncx"\(EbooksAndPages.isRightToLeft(language) ? " page-progression-direction=\"rtl\"" : "")>
        \(spine)  </spine>
        </package>

        """.write(to: oebps.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        try ZipWriter.zipDirectory(dir, to: url, storedFirst: ["mimetype"])
    }

    private static func clean(_ s: String?) -> String {
        (s ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The main language of the text as a BCP 47 tag, "en" when unsure.
    static func detectLanguage(_ doc: Doc) -> String {
        var sample = ""
        for block in doc.blocks {
            sample += block.plainText + " "
            if sample.count > 4000 { break }
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let lang = recognizer.dominantLanguage, lang != .undetermined,
              (recognizer.languageHypotheses(withMaximum: 1)[lang] ?? 0) > 0.5 else { return "en" }
        return lang.rawValue
    }
}
