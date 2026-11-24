import PDFKit

/// Copies pages into a new document (Organize…, Strip Metadata, Remove Password, Merge PDF) and keeps what
/// points at pages working.
///
/// A copied page's links name the source document's pages. PDFKit resolves them lazily, and once the copy is
/// in another document it can't any more: it writes them as links to page 1. So each internal link (a /Dest
/// or a GoTo action) is read before the copy is inserted, then moved onto the first copy of its target page,
/// or removed when that page wasn't copied. The bookmarks (outline) of every source document are rebuilt the
/// same way; a bookmark whose page is gone is dropped and its surviving children move up a level.
///
/// Merge PDF starts a group per input file (`beginGroup`): when any input has bookmarks, each file then gets a
/// top-level bookmark named after it that opens its first page, with that file's own bookmarks under it.
final class PDFPageCopier {
    let document = PDFDocument()
    private var sources: [PDFPage] = []
    private struct Group { let title: String; let start: Int }
    private var groups: [Group] = []
    private struct Target { let page: PDFPage; let point: CGPoint; let zoom: CGFloat }
    private struct Link { let annotation: PDFAnnotation; let page: PDFPage; let direct: Bool; let goTo: Bool; let target: Target? }
    private var links: [Link] = []

    /// Copies `source` to the end of the new document. `adjust` changes the copy first (rotation, authors).
    /// False when PDFKit can't copy the page.
    @discardableResult
    func append(_ source: PDFPage, adjust: (PDFPage) -> Void = { _ in }) -> Bool {
        guard let copy = source.copy() as? PDFPage else { return false }
        for annotation in copy.annotations {
            let direct = annotation.destination
            let goTo = (annotation.action as? PDFActionGoTo)?.destination
            guard let dest = goTo ?? direct else { continue }
            let target = dest.page.map { Target(page: $0, point: dest.point, zoom: dest.zoom) }
            links.append(Link(annotation: annotation, page: copy, direct: direct != nil, goTo: goTo != nil, target: target))
        }
        adjust(copy)
        document.insert(copy, at: document.pageCount)
        sources.append(source)
        return true
    }

    /// Adds a page made for this document (an image turned into a page) as it is: it belongs to no other
    /// document and has no links, so it needn't be copied. A page that already has a document is copied.
    func adopt(_ page: PDFPage) -> Bool {
        guard page.document == nil else { return append(page) }
        document.insert(page, at: document.pageCount)
        sources.append(page)
        return true
    }

    /// Pages appended from now on come from one input file called `title` (see the type's note).
    func beginGroup(_ title: String) {
        groups.append(Group(title: title, start: sources.count))
    }

    /// Where a bookmark to the top of `page` points: the top-left corner as the page is shown (after /Rotate).
    static func top(of page: PDFPage) -> PDFDestination {
        let box = page.bounds(for: .cropBox)
        let corner: CGPoint
        switch ((page.rotation % 360) + 360) % 360 {
        case 90: corner = CGPoint(x: box.minX, y: box.minY)
        case 180: corner = CGPoint(x: box.maxX, y: box.minY)
        case 270: corner = CGPoint(x: box.maxX, y: box.maxY)
        default: corner = CGPoint(x: box.minX, y: box.maxY)
        }
        return PDFDestination(page: page, at: corner)
    }

    /// Moves links and bookmarks onto the copies and returns the new document.
    func finish(keepOutline: Bool = true) -> PDFDocument {
        var copyOf: [ObjectIdentifier: PDFPage] = [:]
        for (i, source) in sources.enumerated() where copyOf[ObjectIdentifier(source)] == nil {
            if let copy = document.page(at: i) { copyOf[ObjectIdentifier(source)] = copy }
        }
        func moved(_ target: Target?) -> PDFDestination? {
            guard let target, let copy = copyOf[ObjectIdentifier(target.page)] else { return nil }
            let out = PDFDestination(page: copy, at: target.point)
            out.zoom = target.zoom
            return out
        }

        for link in links {
            if let dest = moved(link.target) {
                if link.direct { link.annotation.destination = dest }
                if link.goTo { link.annotation.action = PDFActionGoTo(destination: dest) }
            } else if link.annotation.type == "Link" {
                link.page.removeAnnotation(link.annotation)   // its page was left out
            } else {
                link.annotation.destination = nil   // a button keeps working as a form field
                if link.goTo { link.annotation.action = nil }
            }
        }
        guard keepOutline else { return document }

        /// The source documents of `range` (indices into `sources`), each once, in order.
        func documents(_ range: Range<Int>) -> [PDFDocument] {
            var found: [PDFDocument] = []
            for source in sources[range] {
                guard let d = source.document, d !== document, !found.contains(where: { $0 === d }) else { continue }
                found.append(d)
            }
            return found
        }
        let root = PDFOutline()
        var budget = 100_000   // damaged files can have absurd outlines
        func copyChildren(of item: PDFOutline, into parent: PDFOutline, depth: Int) {
            guard depth < 64 else { return }
            for k in 0..<item.numberOfChildren {
                guard budget > 0, let child = item.child(at: k) else { continue }
                budget -= 1
                var target: PDFDestination?
                if let dest = (child.action as? PDFActionGoTo)?.destination ?? child.destination {
                    target = moved(dest.page.map { Target(page: $0, point: dest.point, zoom: dest.zoom) })
                    if target == nil {
                        copyChildren(of: child, into: parent, depth: depth + 1)   // its page is gone
                        continue
                    }
                }
                let copy = PDFOutline()
                copy.label = child.label
                if let target { copy.destination = target }
                else if let action = child.action?.copy() as? PDFAction { copy.action = action }
                parent.insertChild(copy, at: parent.numberOfChildren)
                copyChildren(of: child, into: copy, depth: depth + 1)
                copy.isOpen = child.isOpen
            }
        }
        let all = documents(0..<sources.count)
        let hasOutline = all.contains { ($0.outlineRoot?.numberOfChildren ?? 0) > 0 }
        if groups.count > 1, hasOutline {
            for d in documents(0..<groups[0].start) {   // pages appended before the first group
                if let outline = d.outlineRoot { copyChildren(of: outline, into: root, depth: 0) }
            }
            for (k, group) in groups.enumerated() {
                let end = k + 1 < groups.count ? groups[k + 1].start : sources.count
                guard group.start < end, let first = document.page(at: group.start) else { continue }
                let item = PDFOutline()
                item.label = group.title
                item.destination = Self.top(of: first)
                root.insertChild(item, at: root.numberOfChildren)
                for d in documents(group.start..<end) {
                    if let outline = d.outlineRoot { copyChildren(of: outline, into: item, depth: 1) }
                }
                item.isOpen = true
            }
        } else {
            for d in all { if let outline = d.outlineRoot { copyChildren(of: outline, into: root, depth: 0) } }
        }
        if root.numberOfChildren > 0 { document.outlineRoot = root }
        return document
    }
}
