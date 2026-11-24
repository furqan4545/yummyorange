import AppKit

/// Reads Word documents (DOCX) into rich text. Cocoa's importer ignores styles (every heading comes in
/// as 12-point Times), list formats, hyperlinks and pictures; this reader resolves the style hierarchy,
/// theme fonts and numbering, and keeps headings, lists, tables (merged cells too), links, pictures
/// (DrawingML and VML), fields, footnotes, page breaks, code and quote styles.
enum RichDOCXReader {
    static func read(_ url: URL) throws -> NSAttributedString {
        let zip = try ZipReader(url: url)
        do {
            var reader = try Reader(zip: zip)
            return try reader.document()
        } catch let refused as RichXMLSafety.Refused {
            throw refusal(url, refused)
        }
    }

    static func refusal(_ url: URL, _ why: RichXMLSafety.Refused = RichXMLSafety.Refused()) -> ConversionError {
        why.tooDeep
            ? .unsupported("\(url.lastPathComponent) nests its contents more than \(RichLimits.xmlParseDepth) levels deep, which no real document does. YummyOrange won’t open it.")
            : .unsupported("\(url.lastPathComponent) declares XML entities (in a <!DOCTYPE>), which Word files never do. YummyOrange won’t open it.")
    }

    /// Why some XML part of the package can't be read safely (a DTD, absurd nesting), checked before
    /// another reader is tried; nil when all parts are fine.
    static func unsafePart(_ url: URL) -> RichXMLSafety.Refused? {
        guard let zip = try? ZipReader(url: url) else { return nil }
        for entry in zip.entries where !entry.isDirectory {
            let n = entry.name.lowercased()
            guard n.hasSuffix(".xml") || n.hasSuffix(".rels") || !n.contains(".") else { continue }
            guard let data = try? zip.read(entry) else { continue }
            do { _ = try RichXMLSafety.checked(data) } catch let refused as RichXMLSafety.Refused { return refused } catch {}
        }
        return nil
    }

    /// Picks a namespace-agnostic attribute by local name (w:val, r:id…). For `id`, the relationships
    /// namespace wins when both are present.
    fileprivate static func attr(_ e: XMLElement, _ name: String) -> String? {
        guard let attrs = e.attributes else { return nil }
        if name == "id", let r = attrs.first(where: { $0.localName == "id" && ($0.uri ?? "").hasSuffix("/relationships") }) {
            return r.stringValue
        }
        return attrs.first { $0.localName == name }?.stringValue
    }

    fileprivate static func kids(_ e: XMLElement) -> [XMLElement] { e.children?.compactMap { $0 as? XMLElement } ?? [] }

    /// Every element below `e` in document order, without recursion (documents can nest thousands deep).
    /// `skip`: elements whose insides aren't visited.
    fileprivate static func descendants(_ e: XMLElement, skip: (XMLElement) -> Bool = { _ in false }) -> [XMLElement] {
        var out: [XMLElement] = []
        var stack: [XMLElement] = kids(e).reversed()
        while let x = stack.popLast() {
            out.append(x)
            if !skip(x) { stack.append(contentsOf: kids(x).reversed()) }
        }
        return out
    }
    fileprivate static func child(_ e: XMLElement?, _ name: String) -> XMLElement? { e.flatMap { kids($0).first { $0.localName == name } } }

    /// On/off properties: `<w:b/>` is on, `<w:b w:val="0"/>` (or false/off) is off.
    fileprivate static func flag(_ e: XMLElement?) -> Bool? {
        guard let e else { return nil }
        guard let v = attr(e, "val")?.lowercased() else { return true }
        return !["0", "false", "off", "none"].contains(v)
    }

    fileprivate static func twips(_ s: String?) -> CGFloat? { s.flatMap { Double($0) }.map { CGFloat($0) / 20 } }

    // MARK: Properties

    /// Character properties; nil means "not set here", so styles can be layered.
    fileprivate struct RunProps {
        var bold: Bool?, italic: Bool?, underline: Bool?, strike: Bool?, caps: Bool?, smallCaps: Bool?, hidden: Bool?
        var size: CGFloat?, color: String?, background: String?, font: String?, script: Int?, styleID: String?

        mutating func merge(_ o: RunProps) {
            bold = o.bold ?? bold; italic = o.italic ?? italic; underline = o.underline ?? underline
            strike = o.strike ?? strike; caps = o.caps ?? caps; smallCaps = o.smallCaps ?? smallCaps; hidden = o.hidden ?? hidden
            size = o.size ?? size; color = o.color ?? color; background = o.background ?? background
            font = o.font ?? font; script = o.script ?? script
        }
    }

    /// Paragraph properties; nil means "not set here", so styles can be layered.
    fileprivate struct ParaProps {
        var alignment: NSTextAlignment?
        var left: CGFloat?, right: CGFloat?, firstLine: CGFloat?
        var before: CGFloat?, after: CGFloat?
        var line: CGFloat?, lineRule: String?
        var numID: String?, level: Int?
        var outline: Int?
        var pageBreakBefore: Bool?
        var shading: String?
        var leftBorder: Bool?
        var bottomBorder: Bool?
        /// Right-to-left paragraph (w:bidi), and the raw w:jc value, which then means start/end.
        var bidi: Bool?
        var jc: String?

        mutating func merge(_ o: ParaProps) {
            alignment = o.alignment ?? alignment
            bidi = o.bidi ?? bidi; jc = o.jc ?? jc
            left = o.left ?? left; right = o.right ?? right; firstLine = o.firstLine ?? firstLine
            before = o.before ?? before; after = o.after ?? after
            if o.line != nil { line = o.line; lineRule = o.lineRule }
            numID = o.numID ?? numID; level = o.level ?? level; outline = o.outline ?? outline
            pageBreakBefore = o.pageBreakBefore ?? pageBreakBefore; shading = o.shading ?? shading
            leftBorder = o.leftBorder ?? leftBorder; bottomBorder = o.bottomBorder ?? bottomBorder
        }
    }

    /// One entry of styles.xml.
    fileprivate struct Style {
        var name = "", basedOn: String?, type = ""
        var run = RunProps(), para = ParaProps()
    }

    /// One level of a numbering definition.
    fileprivate struct Level {
        var format = "decimal", text = "%1.", start = 1
        var left: CGFloat?, hanging: CGFloat?
    }

    /// The parts of one package (relationships, styles, numbering, notes) and the text being built.
    private struct Reader {
        let zip: ZipReader
        let mainPart: String
        var rels: [String: (type: String, target: String, external: Bool)] = [:]
        var styles: [String: Style] = [:]
        var defaultParagraphStyle: String?
        var defaults = (run: RunProps(), para: ParaProps())
        var theme: (major: String?, minor: String?) = (nil, nil)
        var abstracts: [String: [Int: Level]] = [:]
        var nums: [String: (abstract: String, starts: [Int: Int])] = [:]
        var footnoteText: [String: String] = [:]
        var endnoteText: [String: String] = [:]

        // Output state
        let out = NSMutableAttributedString()
        var lists: [String: NSTextList] = [:]
        var counters: [String: [Int]] = [:]
        var notes: [String] = []
        var fontCache: [String: NSFont] = [:]
        var blockStack: [NSTextBlock] = []
        var codeBlock: NSTextBlock?
        var quoteBlock: NSTextBlock?
        var resolved: [String: (RunProps, ParaProps)] = [:]
        /// How deep blockContent / inline / tables are nested right now (bounded: see RichLimits).
        var nesting = 0
        var tableNesting = 0
        /// Numbers code blocks, so two blocks in a row stay two.
        var codeBlocks = 0

        init(zip: ZipReader) throws {
            self.zip = zip
            var main = "word/document.xml"
            if let rootRels = try? Reader.relationships(zip, "_rels/.rels", base: ""),
               let office = rootRels.values.first(where: { $0.type.hasSuffix("/officeDocument") }) {
                main = office.target
            }
            guard zip.contains(main) else { throw ZipError.missing(main) }
            mainPart = main
            let dir = (main as NSString).deletingLastPathComponent
            let relsPath = (dir.isEmpty ? "" : dir + "/") + "_rels/" + (main as NSString).lastPathComponent + ".rels"
            rels = (try? Reader.relationships(zip, relsPath, base: dir)) ?? [:]
            loadTheme()
            loadStyles()
            loadNumbering()
            footnoteText = loadNotes("/footnotes", element: "footnote")
            endnoteText = loadNotes("/endnotes", element: "endnote")
        }

        static func xml(_ raw: Data) throws -> XMLElement {
            // No DTD, so no entity is ever expanded or loaded (a file on disk, the network, a billion laughs).
            var data = try RichXMLSafety.checked(raw)
            // XMLDocument drops text nodes that are only white space, even when asked to keep it, and
            // Word often writes the space between two differently styled words as its own run.
            // Such spaces are swapped for private-use characters here and back in `append`.
            if let text = String(data: data, encoding: .utf8), text.contains("preserve") {
                let ns = text as NSString
                if let re = try? NSRegularExpression(pattern: "(<(?:[A-Za-z0-9]+:)?t(?:\\s[^>]*)?>)([ \\t]+)(</(?:[A-Za-z0-9]+:)?t>)") {
                    var out = "", last = 0
                    for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                        out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                        let spaces = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: " ", with: "\u{E000}").replacingOccurrences(of: "\t", with: "\u{E001}")
                        out += ns.substring(with: m.range(at: 1)) + spaces + ns.substring(with: m.range(at: 3))
                        last = NSMaxRange(m.range)
                    }
                    if last > 0 { data = Data((out + ns.substring(from: last)).utf8) }
                }
            }
            let doc = try XMLDocument(data: data, options: [.nodePreserveWhitespace, .nodeLoadExternalEntitiesNever])
            guard let root = doc.rootElement() else { throw ZipError.corrupt("empty XML part") }
            return root
        }

        static func relationships(_ zip: ZipReader, _ path: String, base: String) throws -> [String: (type: String, target: String, external: Bool)] {
            let root = try xml(try zip.read(path))
            var out: [String: (type: String, target: String, external: Bool)] = [:]
            for r in RichDOCXReader.kids(root) where r.localName == "Relationship" {
                guard let id = RichDOCXReader.attr(r, "Id"), let target = RichDOCXReader.attr(r, "Target") else { continue }
                let external = RichDOCXReader.attr(r, "TargetMode") == "External"
                var path = target
                if !external {
                    if path.hasPrefix("/") { path.removeFirst() }
                    else if !base.isEmpty { path = base + "/" + path }
                    path = (path as NSString).standardizingPath
                    if path.hasPrefix("/") { path.removeFirst() }
                }
                out[id] = (RichDOCXReader.attr(r, "Type") ?? "", path, external)
            }
            return out
        }

        func part(_ typeSuffix: String) -> String? { rels.values.first { $0.type.hasSuffix(typeSuffix) && !$0.external }?.target }

        mutating func loadTheme() {
            guard let path = part("/theme"), let data = try? zip.read(path), let root = try? Reader.xml(data) else { return }
            for e in [root] + RichDOCXReader.descendants(root) where e.localName == "majorFont" || e.localName == "minorFont" {
                if let latin = RichDOCXReader.child(e, "latin"), let face = RichDOCXReader.attr(latin, "typeface"), !face.isEmpty {
                    if e.localName == "majorFont" { theme.major = face } else { theme.minor = face }
                }
            }
        }

        func runProps(_ rPr: XMLElement?) -> RunProps {
            var p = RunProps()
            guard let rPr else { return p }
            for e in RichDOCXReader.kids(rPr) {
                switch e.localName {
                case "b": p.bold = RichDOCXReader.flag(e)
                case "i": p.italic = RichDOCXReader.flag(e)
                case "strike", "dstrike": p.strike = RichDOCXReader.flag(e)
                case "caps": p.caps = RichDOCXReader.flag(e)
                case "smallCaps": p.smallCaps = RichDOCXReader.flag(e)
                case "vanish": p.hidden = RichDOCXReader.flag(e)
                case "u": p.underline = (RichDOCXReader.attr(e, "val") ?? "single") != "none"
                case "sz": p.size = RichDOCXReader.attr(e, "val").flatMap(Double.init).map { CGFloat($0) / 2 }
                case "color":
                    if let v = RichDOCXReader.attr(e, "val"), v.lowercased() != "auto", v.count == 6 { p.color = v.uppercased() }
                case "highlight":
                    if let v = RichDOCXReader.attr(e, "val"), let hex = Reader.highlightColors[v] { p.background = hex }
                case "shd":
                    if let v = RichDOCXReader.attr(e, "fill"), v.count == 6, v.lowercased() != "auto", v.uppercased() != "FFFFFF" { p.background = v.uppercased() }
                case "vertAlign":
                    let v = RichDOCXReader.attr(e, "val")
                    p.script = v == "superscript" ? 1 : v == "subscript" ? -1 : 0
                case "rStyle": p.styleID = RichDOCXReader.attr(e, "val")
                case "rFonts":
                    if let f = RichDOCXReader.attr(e, "ascii") ?? RichDOCXReader.attr(e, "hAnsi") { p.font = f }
                    else if let t = RichDOCXReader.attr(e, "asciiTheme") ?? RichDOCXReader.attr(e, "hAnsiTheme") {
                        p.font = t.hasPrefix("major") ? theme.major : theme.minor
                    } else if let f = RichDOCXReader.attr(e, "eastAsia") ?? RichDOCXReader.attr(e, "cs") { p.font = f }
                default: break
                }
            }
            return p
        }

        static let highlightColors: [String: String] = [
            "yellow": "FFFF00", "green": "00FF00", "cyan": "00FFFF", "magenta": "FF00FF", "blue": "0000FF", "red": "FF0000",
            "darkBlue": "000080", "darkCyan": "008080", "darkGreen": "008000", "darkMagenta": "800080", "darkRed": "800000",
            "darkYellow": "808000", "darkGray": "808080", "lightGray": "C0C0C0", "black": "000000",
        ]

        func paraProps(_ pPr: XMLElement?) -> ParaProps {
            var p = ParaProps()
            guard let pPr else { return p }
            for e in RichDOCXReader.kids(pPr) {
                switch e.localName {
                case "bidi": p.bidi = RichDOCXReader.flag(e)
                case "jc":
                    p.jc = RichDOCXReader.attr(e, "val") ?? ""
                    switch RichDOCXReader.attr(e, "val") ?? "" {
                    case "center": p.alignment = .center
                    case "right", "end": p.alignment = .right
                    case "both", "distribute", "lowKashida", "mediumKashida", "highKashida", "thaiDistribute": p.alignment = .justified
                    default: p.alignment = .left
                    }
                case "ind":
                    p.left = RichDOCXReader.twips(RichDOCXReader.attr(e, "left") ?? RichDOCXReader.attr(e, "start"))
                    p.right = RichDOCXReader.twips(RichDOCXReader.attr(e, "right") ?? RichDOCXReader.attr(e, "end"))
                    // "first-line" is how Cocoa's own writer spells it.
                    if let f = RichDOCXReader.twips(RichDOCXReader.attr(e, "firstLine") ?? RichDOCXReader.attr(e, "first-line")) { p.firstLine = f }
                    if let h = RichDOCXReader.twips(RichDOCXReader.attr(e, "hanging")) { p.firstLine = -h }
                case "spacing":
                    if RichDOCXReader.attr(e, "beforeAutospacing").flatMap({ RichDOCXReader.flag(e) == true && $0 == "1" ? true : nil }) == true { p.before = 14 }
                    else if let v = RichDOCXReader.twips(RichDOCXReader.attr(e, "before")) { p.before = v }
                    if RichDOCXReader.attr(e, "afterAutospacing") == "1" { p.after = 14 }
                    else if let v = RichDOCXReader.twips(RichDOCXReader.attr(e, "after")) { p.after = v }
                    if let v = RichDOCXReader.attr(e, "line").flatMap(Double.init) { p.line = CGFloat(v); p.lineRule = RichDOCXReader.attr(e, "lineRule") ?? "auto" }
                case "numPr":
                    if let id = RichDOCXReader.child(e, "numId").flatMap({ RichDOCXReader.attr($0, "val") }) { p.numID = id }
                    if let l = RichDOCXReader.child(e, "ilvl").flatMap({ RichDOCXReader.attr($0, "val") }).flatMap(Int.init) { p.level = l }
                case "outlineLvl": p.outline = RichDOCXReader.attr(e, "val").flatMap(Int.init)
                case "pageBreakBefore": p.pageBreakBefore = RichDOCXReader.flag(e)
                case "shd":
                    if let v = RichDOCXReader.attr(e, "fill"), v.count == 6, v.lowercased() != "auto", v.uppercased() != "FFFFFF" { p.shading = v.uppercased() }
                case "pBdr":
                    if let left = RichDOCXReader.child(e, "left"), (RichDOCXReader.attr(left, "val") ?? "none") != "none" { p.leftBorder = true }
                    if let bottom = RichDOCXReader.child(e, "bottom"), (RichDOCXReader.attr(bottom, "val") ?? "none") != "none" { p.bottomBorder = true }
                default: break
                }
            }
            return p
        }

        mutating func loadStyles() {
            guard let path = part("/styles"), let data = try? zip.read(path), let root = try? Reader.xml(data) else { return }
            for e in RichDOCXReader.kids(root) {
                if e.localName == "docDefaults" {
                    defaults.run = runProps(RichDOCXReader.child(RichDOCXReader.child(e, "rPrDefault"), "rPr"))
                    defaults.para = paraProps(RichDOCXReader.child(RichDOCXReader.child(e, "pPrDefault"), "pPr"))
                }
                guard e.localName == "style", let id = RichDOCXReader.attr(e, "styleId") else { continue }
                var s = Style()
                s.type = RichDOCXReader.attr(e, "type") ?? "paragraph"
                s.name = RichDOCXReader.child(e, "name").flatMap { RichDOCXReader.attr($0, "val") } ?? id
                s.basedOn = RichDOCXReader.child(e, "basedOn").flatMap { RichDOCXReader.attr($0, "val") }
                s.run = runProps(RichDOCXReader.child(e, "rPr"))
                s.para = paraProps(RichDOCXReader.child(e, "pPr"))
                styles[id] = s
                if s.type == "paragraph", RichDOCXReader.attr(e, "default") == "1" { defaultParagraphStyle = id }
            }
        }

        /// A style's properties with everything it's based on applied first.
        mutating func resolve(_ id: String?) -> (RunProps, ParaProps) {
            guard let id, styles[id] != nil else { return (RunProps(), ParaProps()) }
            if let r = resolved[id] { return r }
            var chain: [Style] = []
            var cursor: String? = id
            var seen: Set<String> = []
            while let c = cursor, let s = styles[c], !seen.contains(c), chain.count < 20 {
                chain.insert(s, at: 0); seen.insert(c); cursor = s.basedOn
            }
            var run = RunProps(), para = ParaProps()
            for s in chain { run.merge(s.run); para.merge(s.para) }
            resolved[id] = (run, para)
            return (run, para)
        }

        mutating func loadNumbering() {
            guard let path = part("/numbering"), let data = try? zip.read(path), let root = try? Reader.xml(data) else { return }
            var styleLinks: [String: String] = [:]   // abstractNum id → numbering style it follows
            for e in RichDOCXReader.kids(root) {
                if e.localName == "abstractNum", let id = RichDOCXReader.attr(e, "abstractNumId") {
                    var levels: [Int: Level] = [:]
                    for lvl in RichDOCXReader.kids(e) where lvl.localName == "lvl" {
                        guard let i = RichDOCXReader.attr(lvl, "ilvl").flatMap(Int.init) else { continue }
                        var l = Level()
                        l.format = RichDOCXReader.child(lvl, "numFmt").flatMap { RichDOCXReader.attr($0, "val") } ?? "decimal"
                        l.text = RichDOCXReader.child(lvl, "lvlText").flatMap { RichDOCXReader.attr($0, "val") } ?? ""
                        l.start = RichDOCXReader.child(lvl, "start").flatMap { RichDOCXReader.attr($0, "val") }.flatMap(Int.init) ?? 1
                        if let ind = RichDOCXReader.child(RichDOCXReader.child(lvl, "pPr"), "ind") {
                            l.left = RichDOCXReader.twips(RichDOCXReader.attr(ind, "left") ?? RichDOCXReader.attr(ind, "start"))
                            l.hanging = RichDOCXReader.twips(RichDOCXReader.attr(ind, "hanging"))
                        }
                        levels[i] = l
                    }
                    abstracts[id] = levels
                    if let link = RichDOCXReader.child(e, "numStyleLink").flatMap({ RichDOCXReader.attr($0, "val") }) { styleLinks[id] = link }
                } else if e.localName == "num", let id = RichDOCXReader.attr(e, "numId"),
                          let abstract = RichDOCXReader.child(e, "abstractNumId").flatMap({ RichDOCXReader.attr($0, "val") }) {
                    var starts: [Int: Int] = [:]
                    for o in RichDOCXReader.kids(e) where o.localName == "lvlOverride" {
                        if let l = RichDOCXReader.attr(o, "ilvl").flatMap(Int.init),
                           let s = RichDOCXReader.child(o, "startOverride").flatMap({ RichDOCXReader.attr($0, "val") }).flatMap(Int.init) {
                            starts[l] = s
                        }
                    }
                    nums[id] = (abstract, starts)
                }
            }
            // An abstract list that only points at a numbering style borrows that style's list.
            for (abstract, styleID) in styleLinks where abstracts[abstract]?.isEmpty ?? true {
                if let numID = styles[styleID]?.para.numID, let target = nums[numID]?.abstract, let levels = abstracts[target] {
                    abstracts[abstract] = levels
                }
            }
        }

        func loadNotes(_ type: String, element: String) -> [String: String] {
            guard let path = part(type), let data = try? zip.read(path), let root = try? Reader.xml(data) else { return [:] }
            var out: [String: String] = [:]
            for n in RichDOCXReader.kids(root) where n.localName == element {
                guard let id = RichDOCXReader.attr(n, "id"), (Int(id) ?? 0) > 0 else { continue }
                var paragraphs: [String] = []
                for p in RichDOCXReader.kids(n) where p.localName == "p" {
                    paragraphs.append(Reader.plainText(p).trimmingCharacters(in: .whitespaces))
                }
                out[id] = paragraphs.filter { !$0.isEmpty }.joined(separator: " ")
            }
            return out
        }

        static func plainText(_ e: XMLElement) -> String {
            var s = ""
            let skip: (XMLElement) -> Bool = { ["t", "tab", "br", "cr", "del", "instrText", "delText"].contains($0.localName ?? "") }
            for k in RichDOCXReader.descendants(e, skip: skip) {
                switch k.localName {
                case "t": s += (k.stringValue ?? "").replacingOccurrences(of: "\u{E000}", with: " ").replacingOccurrences(of: "\u{E001}", with: "\t")
                case "tab": s += "\t"
                case "br", "cr": s += " "
                default: break
                }
            }
            return s
        }

        // MARK: Body

        mutating func document() throws -> NSAttributedString {
            let root = try Reader.xml(try zip.read(mainPart))
            guard let body = RichDOCXReader.child(root, "body") else { throw ZipError.corrupt("document has no body") }
            blockContent(body)
            if !notes.isEmpty {
                let ruleStyle = NSMutableParagraphStyle()
                let rule = NSTextBlock()
                rule.setContentWidth(100, type: .percentageValueType)
                rule.setWidth(0.75, type: .absoluteValueType, for: .border, edge: .maxY)
                rule.setBorderColor(RichStyle.rule, for: .maxY)
                rule.setWidth(12, type: .absoluteValueType, for: .margin, edge: .minY)
                rule.setWidth(8, type: .absoluteValueType, for: .margin, edge: .maxY)
                ruleStyle.textBlocks = [rule]
                out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: ruleStyle, .dwRule: true, .font: RichStyle.font(size: 2)]))
                for (i, note) in notes.enumerated() {
                    let ps = NSMutableParagraphStyle()
                    ps.paragraphSpacing = 3
                    out.append(NSAttributedString(string: "\(i + 1). \(note)\n", attributes: [.paragraphStyle: ps, .font: font(nil, size: 9, bold: false, italic: false)]))
                }
            }
            // A document's last paragraph mark adds nothing.
            if out.string.hasSuffix("\n"), out.length > 0,
               (out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.isEmpty ?? true {
                out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
            }
            return out
        }

        /// Body-level content: paragraphs, tables, and the wrappers around them (content controls, custom XML).
        mutating func blockContent(_ parent: XMLElement) {
            nesting += 1
            defer { nesting -= 1 }
            if nesting > RichLimits.xmlDepth {
                // Wrappers nested absurdly deep: keep their paragraphs' text, one after another.
                for p in RichDOCXReader.descendants(parent) where p.localName == "p" {
                    let text = Reader.plainText(p).trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { out.append(NSAttributedString(string: text + "\n", attributes: [.font: RichStyle.font(size: 11)])) }
                }
                return
            }
            for e in RichDOCXReader.kids(parent) {
                switch e.localName {
                case "p": paragraph(e)
                case "tbl": table(e)
                case "sdt": if let c = RichDOCXReader.child(e, "sdtContent") { blockContent(c) }
                case "customXml", "smartTag", "ins": blockContent(e)
                case "AlternateContent": if let branch = Reader.branch(e) { blockContent(branch) }
                default: break
                }
            }
        }

        /// mc:AlternateContent: the first Choice (DrawingML), or the Fallback.
        static func branch(_ e: XMLElement) -> XMLElement? {
            RichDOCXReader.child(e, "Choice") ?? RichDOCXReader.child(e, "Fallback")
        }

        /// The document's font where installed; RichStyle falls back to Helvetica otherwise (the family name
        /// itself travels in .dwFontFamily, so writers keep it).
        func font(_ family: String?, size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
            RichStyle.font(family: family ?? RichStyle.bodyFamily, size: size, bold: bold, italic: italic)
        }

        mutating func cachedFont(_ family: String?, size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
            let key = "\(family ?? "")|\(size)|\(bold)|\(italic)"
            if let f = fontCache[key] { return f }
            let f = font(family, size: size, bold: bold, italic: italic)
            fontCache[key] = f
            return f
        }

        static func isCode(_ name: String) -> Bool {
            let n = name.lowercased()
            return n.contains("code") || n.contains("preformatted") || n == "plain text" || n.contains("source")
        }

        static func isQuote(_ name: String) -> Bool {
            let n = name.lowercased()
            return n == "quote" || n == "intense quote" || n == "block text" || n.hasSuffix(" quote") || n == "quotations"
        }

        mutating func paragraph(_ p: XMLElement) {
            let pPr = RichDOCXReader.child(p, "pPr")
            let styleID = RichDOCXReader.child(pPr, "pStyle").flatMap { RichDOCXReader.attr($0, "val") } ?? defaultParagraphStyle
            let styleName = styleID.flatMap { styles[$0]?.name } ?? ""
            let (styleRun, stylePara) = resolve(styleID)
            var para = defaults.para
            para.merge(stylePara)
            let direct = paraProps(pPr)
            // Numbering indents sit between the style and the paragraph's own.
            var numbering: (id: String, level: Int, info: Level)?
            let numID = direct.numID ?? stylePara.numID
            if let numID, numID != "0", let num = nums[numID], let levels = abstracts[num.abstract] {
                let lvl = direct.level ?? stylePara.level ?? 0
                if var info = levels[lvl], info.format != "none" {
                    if let s = num.starts[lvl] { info.start = s }
                    numbering = (numID, lvl, info)
                    if let l = info.left { para.left = l }
                    if let h = info.hanging { para.firstLine = -h }
                }
            }
            para.merge(direct)
            para.numID = numID

            var baseRun = defaults.run
            baseRun.merge(styleRun)
            if baseRun.size == nil { baseRun.size = 11 }

            let ps = NSMutableParagraphStyle()
            ps.alignment = para.alignment ?? .natural
            if para.bidi == true {
                // A right-to-left paragraph: Word's "left" and "start" mean its leading (right) edge.
                ps.baseWritingDirection = .rightToLeft
                switch para.jc ?? "" {
                case "", "left", "start": ps.alignment = .natural
                case "right", "end": ps.alignment = .left
                default: break
                }
            }
            let left = max(0, para.left ?? 0)
            ps.headIndent = left
            ps.firstLineHeadIndent = max(0, left + (para.firstLine ?? 0))
            if let r = para.right, r > 0 { ps.tailIndent = -r }
            ps.paragraphSpacingBefore = max(0, para.before ?? 0)
            ps.paragraphSpacing = max(0, para.after ?? 0)
            if let line = para.line {
                switch para.lineRule ?? "auto" {
                case "exact": ps.minimumLineHeight = line / 20; ps.maximumLineHeight = line / 20
                case "atLeast": ps.minimumLineHeight = line / 20
                default: ps.lineHeightMultiple = max(0.5, min(4, line / 240))
                }
            }
            var level = 0
            let lowered = styleName.lowercased()
            if lowered.hasPrefix("heading "), let n = Int(lowered.dropFirst(8)) { level = n }
            else if lowered == "title" { level = 1 }
            else if let o = para.outline, o < 9 { level = o + 1 }
            if level > 0 { ps.headerLevel = min(6, level) }

            var extra: [NSAttributedString.Key: Any] = [:]
            var blocks = blockStack
            if Reader.isCode(styleName) && level == 0 {
                extra[.dwCodeBlock] = ""
                // YummyOrange marks where each code block starts (two blocks in a row stay two).
                if RichDOCXReader.kids(p).contains(where: { $0.localName == "bookmarkStart" && (RichDOCXReader.attr($0, "name") ?? "").hasPrefix("_DWCode") }) {
                    codeBlock = nil
                }
                if codeBlock == nil {
                    codeBlocks += 1
                    let b = NSTextBlock()
                    b.setContentWidth(100, type: .percentageValueType)
                    b.backgroundColor = RichStyle.codeBackground
                    b.setWidth(6, type: .absoluteValueType, for: .padding)
                    codeBlock = b
                }
                extra[.dwCodeBlockID] = codeBlocks
                blocks.append(codeBlock!)
            } else { codeBlock = nil }
            if (Reader.isQuote(styleName) || (para.leftBorder == true && level == 0 && numbering == nil)) && blockStack.isEmpty {
                extra[.dwQuote] = 1
                if quoteBlock == nil {
                    let b = NSTextBlock()
                    b.setContentWidth(100, type: .percentageValueType)
                    b.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                    b.setBorderColor(RichStyle.rule, for: .minX)
                    b.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                    quoteBlock = b
                }
                blocks.append(quoteBlock!)
            } else { quoteBlock = nil }
            ps.textBlocks = blocks

            var prefix = ""
            if let numbering {
                let (marker, textLists) = listMarker(numbering.id, numbering.level, numbering.info)
                ps.textLists = textLists
                let markerX = max(0, left + (para.firstLine ?? -18))
                ps.firstLineHeadIndent = markerX
                ps.tabStops = [NSTextTab(textAlignment: .left, location: max(left, markerX + 12))]
                prefix = marker + "\t"
            }
            var paraAttrs: [NSAttributedString.Key: Any] = extra
            paraAttrs[.paragraphStyle] = ps
            paraAttrs[.font] = cachedFont(baseRun.font, size: baseRun.size ?? 11, bold: baseRun.bold ?? false, italic: baseRun.italic ?? false)

            let start = out.length
            if para.pageBreakBefore == true && start > 0 { out.append(NSAttributedString(string: "\u{0C}", attributes: paraAttrs)) }
            if !prefix.isEmpty {
                var a = paraAttrs
                a[.font] = cachedFont(baseRun.font, size: baseRun.size ?? 11, bold: false, italic: false)
                out.append(NSAttributedString(string: prefix, attributes: a))
            }
            // An empty paragraph with only a bottom border is how Word draws a horizontal rule.
            if para.bottomBorder == true, numbering == nil, Reader.plainText(p).trimmingCharacters(in: .whitespaces).isEmpty,
               !RichDOCXReader.kids(p).contains(where: { $0.localName == "r" && Reader.hasPicture($0) }) {
                let rule = NSTextBlock()
                rule.setContentWidth(100, type: .percentageValueType)
                rule.setWidth(0.75, type: .absoluteValueType, for: .border, edge: .maxY)
                rule.setBorderColor(RichStyle.rule, for: .maxY)
                rule.setWidth(6, type: .absoluteValueType, for: .margin, edge: .minY)
                rule.setWidth(10, type: .absoluteValueType, for: .margin, edge: .maxY)
                let rs = NSMutableParagraphStyle()
                rs.textBlocks = blockStack + [rule]
                out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: rs, .dwRule: true, .font: RichStyle.font(size: 2)]))
                return
            }
            var field = FieldState()
            inline(p, baseRun: baseRun, paraAttrs: paraAttrs, link: nil, field: &field)
            out.append(NSAttributedString(string: "\n", attributes: paraAttrs))
            // Paragraph-level attributes (style, quote and code markers) cover the whole paragraph.
            let range = NSRange(location: start, length: out.length - start)
            out.addAttribute(.paragraphStyle, value: ps, range: range)
            for (k, v) in extra { out.addAttribute(k, value: v, range: range) }
        }

        /// The marker text for this item and the NSTextList chain for its level, advancing the counters.
        mutating func listMarker(_ numID: String, _ level: Int, _ info: Level) -> (String, [NSTextList]) {
            let levels = nums[numID].flatMap { abstracts[$0.abstract] } ?? [:]
            var c = counters[numID] ?? []
            func start(_ l: Int) -> Int { nums[numID]?.starts[l] ?? levels[l]?.start ?? 1 }
            while c.count <= level { c.append(start(c.count) - 1) }
            c[level] += 1
            for deeper in (level + 1)..<max(level + 1, c.count) { c[deeper] = start(deeper) - 1 }
            counters[numID] = c
            var chain: [NSTextList] = []
            for l in 0...level {
                let key = "\(numID)/\(l)"
                if let existing = lists[key] { chain.append(existing); continue }
                let lv = levels[l] ?? info
                let list = NSTextList(markerFormat: Reader.markerFormat(lv, level: l), options: 0)
                list.startingItemNumber = nums[numID]?.starts[l] ?? lv.start
                lists[key] = list
                chain.append(list)
            }
            var text = info.text
            if info.format == "bullet" {
                return (Reader.bulletGlyph(text), chain)
            }
            for l in 0...level {
                let lv = levels[l] ?? info
                text = text.replacingOccurrences(of: "%\(l + 1)", with: Reader.format(c[l], lv.format))
            }
            return (text.isEmpty ? Reader.format(c[level], info.format) + "." : text, chain)
        }

        static func bulletGlyph(_ raw: String) -> String {
            guard let scalar = raw.unicodeScalars.first else { return "•" }
            switch scalar.value {
            case 0xF0B7, 0xF06C, 0xF09F, 0x2022, 0x25CF: return "•"
            case 0xF0A7, 0xF06E, 0x25AA, 0x25A0, 0xF0A8: return "▪"
            case 0x6F, 0x25CB, 0x25E6, 0xF0A1: return "◦"
            case 0x2013, 0x2D, 0xF02D: return "–"
            case 0xF0FC, 0x2713, 0x2714: return "✓"
            case 0xF0D8, 0x27A2, 0xF0E8: return "➢"
            default: return scalar.value >= 0xF000 && scalar.value <= 0xF0FF ? "•" : String(raw.prefix(1))
            }
        }

        static func markerFormat(_ level: Level, level index: Int) -> NSTextList.MarkerFormat {
            if level.format == "bullet" {
                switch bulletGlyph(level.text) {
                case "◦": return .circle
                case "▪": return .square
                case "–": return .hyphen
                case "✓": return .check
                default: return .disc
                }
            }
            let placeholder: String
            switch level.format {
            case "lowerLetter": placeholder = "{lower-alpha}"
            case "upperLetter": placeholder = "{upper-alpha}"
            case "lowerRoman": placeholder = "{lower-roman}"
            case "upperRoman": placeholder = "{upper-roman}"
            default: placeholder = "{decimal}"
            }
            // Keep what follows the level's own number in lvlText ("%1." → ".", "%1)" → ")").
            var suffix = "."
            if let r = level.text.range(of: "%\(index + 1)") { suffix = String(level.text[r.upperBound...]) }
            return NSTextList.MarkerFormat(placeholder + suffix)
        }

        static func format(_ n: Int, _ fmt: String) -> String {
            switch fmt {
            case "lowerLetter": return RichListLevel.alpha(n).lowercased()
            case "upperLetter": return RichListLevel.alpha(n)
            case "lowerRoman": return RichListLevel.roman(n).lowercased()
            case "upperRoman": return RichListLevel.roman(n)
            case "decimalZero": return n < 10 ? "0\(n)" : "\(n)"
            default: return "\(n)"
            }
        }

        /// A complex field (fldChar begin/separate/end) being read: its instruction, and whether its result shows.
        struct FieldState {
            var depth = 0
            var instr = ""
            var showing = true
            var link: String?
        }

        /// Runs, links, fields and the wrappers around them inside a paragraph.
        mutating func inline(_ parent: XMLElement, baseRun: RunProps, paraAttrs: [NSAttributedString.Key: Any], link: String?, field: inout FieldState) {
            nesting += 1
            defer { nesting -= 1 }
            if nesting > RichLimits.xmlDepth {
                append(Reader.plainText(parent), props: baseRun, paraAttrs: paraAttrs, link: link)
                return
            }
            for e in RichDOCXReader.kids(parent) {
                switch e.localName {
                case "r": run(e, baseRun: baseRun, paraAttrs: paraAttrs, link: link ?? field.link, field: &field)
                case "hyperlink":
                    var target = link
                    if let id = RichDOCXReader.attr(e, "id"), let rel = rels[id] { target = rel.target }
                    else if let anchor = RichDOCXReader.attr(e, "anchor") { target = "#" + anchor }
                    inline(e, baseRun: baseRun, paraAttrs: paraAttrs, link: target, field: &field)
                case "fldSimple":
                    let instr = RichDOCXReader.attr(e, "instr") ?? ""
                    inline(e, baseRun: baseRun, paraAttrs: paraAttrs, link: Reader.hyperlinkTarget(instr) ?? link, field: &field)
                case "ins", "smartTag", "customXml", "bdo", "dir": inline(e, baseRun: baseRun, paraAttrs: paraAttrs, link: link, field: &field)
                case "sdt": if let c = RichDOCXReader.child(e, "sdtContent") { inline(c, baseRun: baseRun, paraAttrs: paraAttrs, link: link, field: &field) }
                case "AlternateContent": if let b = Reader.branch(e) { inline(b, baseRun: baseRun, paraAttrs: paraAttrs, link: link, field: &field) }
                case "oMath", "oMathPara":
                    let text = Reader.mathText(e)
                    if !text.isEmpty { append(text, props: baseRun, paraAttrs: paraAttrs, link: link) }
                default: break
                }
            }
        }

        static func hasPicture(_ e: XMLElement) -> Bool {
            ["drawing", "pict", "object"].contains(e.localName ?? "")
                || RichDOCXReader.descendants(e).contains { ["drawing", "pict", "object"].contains($0.localName ?? "") }
        }

        static func mathText(_ e: XMLElement) -> String {
            RichDOCXReader.descendants(e, skip: { $0.localName == "t" }).filter { $0.localName == "t" }.map { $0.stringValue ?? "" }.joined()
        }

        static func hyperlinkTarget(_ instr: String) -> String? {
            let t = instr.trimmingCharacters(in: .whitespaces)
            guard t.uppercased().hasPrefix("HYPERLINK") else { return nil }
            if let r = t.range(of: "\"[^\"]+\"", options: .regularExpression) {
                let url = String(t[r].dropFirst().dropLast())
                return t.contains("\\l") ? "#" + url : url
            }
            return nil
        }

        mutating func run(_ r: XMLElement, baseRun: RunProps, paraAttrs: [NSAttributedString.Key: Any], link: String?, field: inout FieldState) {
            var props = baseRun
            let direct = runProps(RichDOCXReader.child(r, "rPr"))
            if let rs = direct.styleID { props.merge(resolve(rs).0) }
            props.merge(direct)
            if props.hidden == true { return }
            for e in RichDOCXReader.kids(r) {
                switch e.localName {
                case "fldChar":
                    switch RichDOCXReader.attr(e, "fldCharType") {
                    case "begin": field.depth += 1; field.instr = ""; field.showing = false
                    case "separate": field.showing = true; if field.depth == 1 { field.link = Reader.hyperlinkTarget(field.instr) }
                    case "end": field.depth = max(0, field.depth - 1); field.showing = true; if field.depth == 0 { field.link = nil }
                    default: break
                    }
                case "instrText": field.instr += e.stringValue ?? ""
                case "t" where field.showing: append(e.stringValue ?? "", props: props, paraAttrs: paraAttrs, link: link ?? field.link)
                case "tab", "ptab": if field.showing { append("\t", props: props, paraAttrs: paraAttrs, link: link) }
                case "br":
                    let type = RichDOCXReader.attr(e, "type")
                    append(type == "page" ? "\u{0C}" : "\u{2028}", props: props, paraAttrs: paraAttrs, link: nil)
                case "cr": append("\u{2028}", props: props, paraAttrs: paraAttrs, link: nil)
                case "noBreakHyphen": append("\u{2011}", props: props, paraAttrs: paraAttrs, link: link)
                case "softHyphen": append("\u{00AD}", props: props, paraAttrs: paraAttrs, link: link)
                case "sym":
                    if let hex = RichDOCXReader.attr(e, "char"), let v = UInt32(hex, radix: 16) {
                        append(Reader.bulletGlyph(String(UnicodeScalar(v).map(Character.init) ?? "•")), props: props, paraAttrs: paraAttrs, link: link)
                    }
                case "drawing", "pict", "object":
                    picture(e, paraAttrs: paraAttrs, link: link)
                case "AlternateContent":
                    if let b = Reader.branch(e), nesting < RichLimits.xmlDepth {
                        let wrapper = XMLElement(name: "w:r")
                        for k in RichDOCXReader.kids(b) { wrapper.addChild(k.copy() as! XMLNode) }
                        nesting += 1
                        run(wrapper, baseRun: props, paraAttrs: paraAttrs, link: link, field: &field)
                        nesting -= 1
                    }
                case "footnoteReference", "endnoteReference":
                    let id = RichDOCXReader.attr(e, "id") ?? ""
                    let text = (e.localName == "footnoteReference" ? footnoteText : endnoteText)[id] ?? ""
                    notes.append(text)
                    var sup = props
                    sup.script = 1
                    append("\(notes.count)", props: sup, paraAttrs: paraAttrs, link: nil)
                default: break
                }
            }
        }

        mutating func append(_ text: String, props: RunProps, paraAttrs: [NSAttributedString.Key: Any], link: String?) {
            guard !text.isEmpty else { return }
            var s = text.replacingOccurrences(of: "\u{E000}", with: " ").replacingOccurrences(of: "\u{E001}", with: "\t")
            var size = props.size ?? 11
            if props.caps == true { s = s.uppercased() }
            if props.smallCaps == true { s = s.uppercased(); size *= 0.8 }
            if props.script != nil && props.script != 0 { size *= 0.75 }
            var a = paraAttrs
            a[.font] = cachedFont(props.font, size: size, bold: props.bold ?? false, italic: props.italic ?? false)
            if let f = props.font { a[.dwFontFamily] = f }
            if props.underline == true { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if props.strike == true { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let c = props.color, let color = NSColor(hex: "#" + c) { a[.foregroundColor] = color }
            if let b = props.background, let color = NSColor(hex: "#" + b) { a[.backgroundColor] = color }
            if let sc = props.script, sc != 0 { a[.superscript] = sc }
            if let link, let url = URL(string: link) ?? URL(string: link.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") {
                a[.link] = url
                if props.color == nil { a[.foregroundColor] = RichStyle.linkColor }
            }
            out.append(NSAttributedString(string: s, attributes: a))
        }

        /// DrawingML pictures (inline or floating) and VML ones (older documents and OLE previews).
        mutating func picture(_ e: XMLElement, paraAttrs: [NSAttributedString.Key: Any], link: String?) {
            var blip: String?, size: CGSize?, alt = ""
            var textBoxes: [XMLElement] = []
            for x in [e] + RichDOCXReader.descendants(e, skip: { $0.localName == "txbxContent" }) {
                switch x.localName {
                case "blip": blip = blip ?? RichDOCXReader.attr(x, "embed") ?? RichDOCXReader.attr(x, "link")
                case "imagedata": blip = blip ?? RichDOCXReader.attr(x, "id")
                case "extent":
                    if size == nil, let cx = RichDOCXReader.attr(x, "cx").flatMap(Double.init), let cy = RichDOCXReader.attr(x, "cy").flatMap(Double.init) {
                        size = CGSize(width: cx / 12700, height: cy / 12700)
                    }
                case "docPr": alt = RichDOCXReader.attr(x, "descr") ?? RichDOCXReader.attr(x, "title") ?? ""
                case "shape":
                    if size == nil, let style = RichDOCXReader.attr(x, "style") { size = Reader.vmlSize(style) }
                case "txbxContent": textBoxes.append(x)
                default: break
                }
            }
            if let blip, let rel = rels[blip], !rel.external, let data = try? zip.read(rel.target),
               let image = RichImage.from(data: data, name: (rel.target as NSString).lastPathComponent, alt: alt, display: size) {
                let wrapper = FileWrapper(regularFileWithContents: image.data)
                wrapper.preferredFilename = image.name
                let attachment = NSTextAttachment(fileWrapper: wrapper)
                attachment.bounds = CGRect(origin: .zero, size: image.displaySize)
                var a = paraAttrs
                a[.attachment] = attachment
                a[.dwImageAlt] = alt
                if let link, let url = URL(string: link) { a[.link] = url }
                out.append(NSAttributedString(string: "\u{FFFC}", attributes: a))
            }
            // Text boxes: their text continues inline, a line each.
            for box in textBoxes {
                for p in RichDOCXReader.descendants(box, skip: { $0.localName == "p" }) where p.localName == "p" {
                    let text = Reader.plainText(p).trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { append("\u{2028}" + text, props: defaults.run, paraAttrs: paraAttrs, link: nil) }
                }
            }
        }

        static func vmlSize(_ style: String) -> CGSize? {
            var w: CGFloat?, h: CGFloat?
            for part in style.split(separator: ";") {
                let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2 else { continue }
                let v = kv[1]
                let number = CGFloat(Double(v.trimmingCharacters(in: CharacterSet.letters)) ?? 0)
                let pt = v.hasSuffix("in") ? number * 72 : v.hasSuffix("cm") ? number * 72 / 2.54 : v.hasSuffix("mm") ? number * 72 / 25.4
                    : v.hasSuffix("px") ? number * 0.75 : number
                if kv[0] == "width" { w = pt } else if kv[0] == "height" { h = pt }
            }
            if let w, let h, w > 0, h > 0 { return CGSize(width: w, height: h) }
            return nil
        }

        // MARK: Tables

        mutating func table(_ tbl: XMLElement) {
            if tableNesting >= RichLimits.tableDepth {
                // Tables nested deeper than any real document: their cells' content follows on, unboxed.
                for tr in RichDOCXReader.kids(tbl) where tr.localName == "tr" {
                    for tc in RichDOCXReader.kids(tr) where tc.localName == "tc" { blockContent(tc) }
                }
                return
            }
            tableNesting += 1
            defer { tableNesting -= 1 }
            let grid = RichDOCXReader.child(tbl, "tblGrid").map { RichDOCXReader.kids($0).filter { $0.localName == "gridCol" }
                .map { RichDOCXReader.twips(RichDOCXReader.attr($0, "w")) ?? 72 } } ?? []
            let rows = RichDOCXReader.kids(tbl).filter { $0.localName == "tr" }
            // Each row's cells with their grid columns and spans.
            /// A cell with the grid column it starts in.
            struct Cell { let element: XMLElement; let column: Int; let span: Int; let merge: String? }
            var layout: [[Cell]] = []
            for tr in rows {
                var column = 0
                var cells: [Cell] = []
                if let before = RichDOCXReader.child(RichDOCXReader.child(tr, "trPr"), "gridBefore").flatMap({ RichDOCXReader.attr($0, "val") }).flatMap(Int.init) {
                    column += before
                }
                var items: [XMLElement] = []
                for k in RichDOCXReader.kids(tr) {
                    if k.localName == "tc" { items.append(k) }
                    else if k.localName == "sdt", let c = RichDOCXReader.child(k, "sdtContent") { items += RichDOCXReader.kids(c).filter { $0.localName == "tc" } }
                }
                for tc in items {
                    let tcPr = RichDOCXReader.child(tc, "tcPr")
                    let span = RichDOCXReader.child(tcPr, "gridSpan").flatMap { RichDOCXReader.attr($0, "val") }.flatMap(Int.init) ?? 1
                    var merge: String?
                    if let vm = RichDOCXReader.child(tcPr, "vMerge") { merge = RichDOCXReader.attr(vm, "val") ?? "continue" }
                    cells.append(Cell(element: tc, column: column, span: max(1, span), merge: merge))
                    column += max(1, span)
                }
                layout.append(cells)
            }
            let columns = max(grid.count, layout.map { ($0.last.map { $0.column + $0.span }) ?? 0 }.max() ?? 1, 1)
            let table = NSTextTable()
            table.numberOfColumns = columns
            table.collapsesBorders = true
            table.hidesEmptyCells = false
            table.setContentWidth(100, type: .percentageValueType)
            let total = grid.reduce(0, +)
            let saved = (codeBlock, quoteBlock)
            codeBlock = nil; quoteBlock = nil
            for (r, cells) in layout.enumerated() {
                for cell in cells where cell.merge != "continue" {
                    var rowSpan = 1
                    if cell.merge == "restart" {
                        var k = r + 1
                        while k < layout.count, layout[k].contains(where: { $0.column == cell.column && $0.merge == "continue" }) { rowSpan += 1; k += 1 }
                    }
                    let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: rowSpan, startingColumn: min(cell.column, columns - 1),
                                                 columnSpan: max(1, min(cell.span, columns - cell.column)))
                    block.setWidth(0.75, type: .absoluteValueType, for: .border)
                    block.setBorderColor(RichStyle.tableBorder)
                    block.setWidth(4, type: .absoluteValueType, for: .padding)
                    if total > 0, cell.column + cell.span <= grid.count {
                        let w = grid[cell.column..<(cell.column + cell.span)].reduce(0, +)
                        block.setContentWidth(w / total * 100, type: .percentageValueType)
                    }
                    if let fill = RichDOCXReader.child(RichDOCXReader.child(cell.element, "tcPr"), "shd").flatMap({ RichDOCXReader.attr($0, "fill") }),
                       fill.count == 6, fill.lowercased() != "auto", let color = NSColor(hex: "#" + fill) {
                        block.backgroundColor = color
                    }
                    blockStack.append(block)
                    let before = out.length
                    blockContent(cell.element)
                    if out.length == before {
                        let ps = NSMutableParagraphStyle()
                        ps.textBlocks = blockStack
                        out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: ps, .font: RichStyle.font(size: 11)]))
                    }
                    blockStack.removeLast()
                }
            }
            (codeBlock, quoteBlock) = saved
        }
    }
}

extension NSAttributedString.Key {
    /// String: the font family a document asked for, kept even when that font isn't installed here.
    static let dwFontFamily = NSAttributedString.Key("DropWheel.fontFamily")
}
