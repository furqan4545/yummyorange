import Foundation
import CoreGraphics

/// An opened presentation: its slide size, the slides in order and, for each slide, the layout,
/// master and theme it inherits from.
final class PPTXDeck {
    struct Slide {
        let part: String
        /// 1-based position in the deck, counting hidden slides (what PowerPoint shows as the slide number).
        let number: Int
        let hidden: Bool
    }

    /// The slide's layout, master and theme, with the inherited colour map.
    struct Chain {
        let slide: PPTXNode
        let layout: PPTXNode?
        let master: PPTXNode?
        let layoutPart: String?
        let masterPart: String?
        let themePart: String?
        let theme: PPTXTheme
        let colorMap: [String: String]
    }

    let pkg: PPTXPackage
    let presentationPart: String
    /// Slide size in points.
    let size: CGSize
    let slides: [Slide]
    let defaultTextStyle: PPTXNode?
    let tableStyles: PPTXNode?
    let title: String?
    private var themes: [String: PPTXTheme] = [:]
    private let lock = NSLock()

    static let maxBytes = 1 << 30

    /// Opens a PPTX/PPSX/POTX file. Legacy PPT files are read by `PPTBinary` and opened with `init(parts:)`.
    static func open(_ url: URL) throws -> PPTXDeck {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > maxBytes { throw ConversionError.unsupported("This presentation is too large to convert (over 1 GB).") }
        if PPTBinary.isCompoundFile(url) {
            if PPTBinary.isEncryptedPackage(url) {
                throw ConversionError.unsupported("This presentation is password-protected. Open it in PowerPoint and save a copy without a password first.")
            }
            return try PPTXDeck(parts: PPTBinary.convert(url))
        }
        guard ZipReader.isZip(url) else { throw ConversionError.unreadable(url.lastPathComponent) }
        let zip: ZipReader
        do { zip = try ZipReader(url: url) } catch {
            throw ConversionError.unsupported("\(url.lastPathComponent) is damaged or incomplete, so it can’t be opened.")
        }
        return try PPTXDeck(parts: PPTXZipParts(zip: zip), name: url.lastPathComponent)
    }

    init(parts: PPTXParts, name: String = "The presentation") throws {
        let pkg = PPTXPackage(parts)
        self.pkg = pkg
        let root = pkg.rels("").values.first { $0.kind == "officeDocument" && !$0.external }?.target
        let candidates = [root, "ppt/presentation.xml"].compactMap { $0 }
        guard let part = candidates.first(where: { pkg.xml($0)?.name == "p:presentation" }), let pres = pkg.xml(part) else {
            if parts.names.contains(where: { $0.hasPrefix("word/") }) {
                throw ConversionError.unsupported("This is a Word document, not a presentation.")
            }
            if parts.names.contains(where: { $0.hasPrefix("xl/") }) {
                throw ConversionError.unsupported("This is an Excel workbook, not a presentation.")
            }
            throw ConversionError.unsupported("\(name) isn’t a PowerPoint presentation, or it’s damaged.")
        }
        presentationPart = part

        let sz = pres.child("p:sldSz")
        var cx = Double(sz?.int("cx") ?? 9_144_000), cy = Double(sz?.int("cy") ?? 6_858_000)
        // PowerPoint's limits are 914 400 to 51 206 400 EMU (1 to 56 inches); far outside that is damage.
        if cx <= 0 || cy <= 0 || cx > 1e9 || cy > 1e9 { cx = 9_144_000; cy = 6_858_000 }
        size = CGSize(width: cx / 12700, height: cy / 12700)

        let rels = pkg.rels(part)
        var list: [Slide] = []
        for (i, id) in (pres.child("p:sldIdLst")?.all("p:sldId") ?? []).enumerated() {
            guard let rid = id["r:id"], let rel = rels[rid], !rel.external, rel.kind == "slide" else { continue }
            let hidden = pkg.xml(rel.target)?.bool("show") == false
            list.append(Slide(part: rel.target, number: i + 1, hidden: hidden))
        }
        if list.isEmpty {
            // No slide list (some generators omit it): fall back to the slide relationships in name order.
            let parts = rels.values.filter { $0.kind == "slide" && !$0.external }.map(\.target)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            list = parts.enumerated().map { Slide(part: $1, number: $0 + 1, hidden: pkg.xml($1)?.bool("show") == false) }
        }
        slides = list
        defaultTextStyle = pres.child("p:defaultTextStyle")
        tableStyles = rels.values.first { $0.kind == "tableStyles" && !$0.external }.flatMap { pkg.xml($0.target) }

        let coreTitle = pkg.rels("").values.first { $0.kind == "core-properties" }.flatMap { pkg.xml($0.target) }?
            .child("dc:title")?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        title = (coreTitle?.isEmpty ?? true) ? nil : coreTitle
    }

    func theme(_ part: String?) -> PPTXTheme {
        guard let part else { return PPTXTheme() }
        lock.lock(); defer { lock.unlock() }
        if let t = themes[part] { return t }
        let t = PPTXTheme(pkg.xml(part))
        themes[part] = t
        return t
    }

    /// Resolves the slide's layout, master, theme and colour map.
    func chain(for slide: Slide) -> Chain? {
        guard let node = pkg.xml(slide.part) else { return nil }
        let layoutPart = pkg.rel(slide.part, kind: "slideLayout")?.target
        let layout = layoutPart.flatMap { pkg.xml($0) }
        let masterPart = layoutPart.flatMap { pkg.rel($0, kind: "slideMaster")?.target }
        let master = masterPart.flatMap { pkg.xml($0) }
        let themePart = masterPart.flatMap { pkg.rel($0, kind: "theme")?.target }
            ?? pkg.rels(presentationPart).values.first { $0.kind == "theme" }?.target
        var map: [String: String] = ["bg1": "lt1", "tx1": "dk1", "bg2": "lt2", "tx2": "dk2"]
        if let m = master?.child("p:clrMap") { for (k, v) in m.attrs { map[k] = v } }
        for over in [layout?.child("p:clrMapOvr"), node.child("p:clrMapOvr")] {
            if let o = over?.child("a:overrideClrMapping") { for (k, v) in o.attrs { map[k] = v } }
        }
        return Chain(slide: node, layout: layout, master: master, layoutPart: layoutPart, masterPart: masterPart,
                     themePart: themePart, theme: theme(themePart), colorMap: map)
    }

    // MARK: Placeholders

    /// A placeholder's type (with "obj" for none given, like the spec) and index.
    struct Placeholder {
        let type: String
        let idx: String?
    }

    static func placeholder(of shape: PPTXNode) -> Placeholder? {
        guard let nv = shape.children.first(where: { $0.name.hasPrefix("p:nv") }),
              let ph = nv.child("p:nvPr")?.child("p:ph") else { return nil }
        return Placeholder(type: ph["type"] ?? "obj", idx: ph["idx"])
    }

    private static let titleTypes: Set<String> = ["title", "ctrTitle"]
    private static let bodyTypes: Set<String> = ["body", "obj", "subTitle", "pic", "tbl", "chart", "dgm", "media", "clipArt"]

    private static func compatible(_ a: String, _ b: String) -> Bool {
        a == b || (titleTypes.contains(a) && titleTypes.contains(b)) || (bodyTypes.contains(a) && bodyTypes.contains(b))
    }

    /// The layout (or master) shape a slide placeholder inherits from.
    static func match(_ ph: Placeholder, in tree: PPTXNode?, master: Bool) -> PPTXNode? {
        guard let tree else { return nil }
        var candidates: [(Placeholder, PPTXNode)] = []
        func collect(_ n: PPTXNode) {
            for c in n.children {
                if c.name == "p:grpSp" { collect(c); continue }
                if let p = placeholder(of: c) { candidates.append((p, c)) }
            }
        }
        collect(tree)
        if master {
            let wanted: String
            switch ph.type {
            case "ctrTitle", "title": wanted = "title"
            case "dt", "ftr", "sldNum", "hdr": wanted = ph.type
            default: wanted = "body"
            }
            return candidates.first { $0.0.type == wanted }?.1
        }
        if let idx = ph.idx, let hit = candidates.first(where: { $0.0.idx == idx && compatible($0.0.type, ph.type) }) { return hit.1 }
        if let hit = candidates.first(where: { $0.0.type == ph.type && (ph.type != "obj" || ph.idx == nil) }) { return hit.1 }
        if let idx = ph.idx, let hit = candidates.first(where: { $0.0.idx == idx }) { return hit.1 }
        if ph.idx == nil, let hit = candidates.first(where: { compatible($0.0.type, ph.type) }) { return hit.1 }
        return nil
    }

    /// The master text style a placeholder type draws from.
    static func masterTextStyle(_ type: String?, master: PPTXNode?) -> PPTXNode? {
        let styles = master?.child("p:txStyles")
        guard let type else { return styles?.child("p:otherStyle") }
        switch type {
        case "title", "ctrTitle": return styles?.child("p:titleStyle")
        case "dt", "ftr", "sldNum", "hdr": return styles?.child("p:otherStyle")
        default: return styles?.child("p:bodyStyle")
        }
    }

    // MARK: Text

    /// The plain text of each slide (titles first), for search and extraction.
    func text(of slide: Slide) -> String {
        guard let root = pkg.xml(slide.part) else { return "" }
        var paragraphs: [String] = []
        for p in root.descendants("a:p") {
            var line = ""
            for r in p.children {
                switch r.name {
                case "a:r", "a:fld": line += r.child("a:t")?.text ?? ""
                case "a:br": line += "\n"
                default: break
                }
            }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { paragraphs.append(line) }
        }
        return paragraphs.joined(separator: "\n")
    }
}
