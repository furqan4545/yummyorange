import Foundation

// Reading HTML and XHTML (EPUB chapters, .html documents) into the document model, plus an HTML
// serializer for the single-file EPUB → HTML export. Parsing goes through Foundation's XMLDocument:
// strict XML first (after turning HTML named entities into numeric ones), then its HTML tidy mode
// for tag soup. External entities and DTDs are never loaded.

private typealias Run = EbooksAndPages.Run
private typealias Block = EbooksAndPages.Block

extension EbooksAndPages {
    /// Parses markup into an XML tree, tolerating HTML that isn't well-formed XML.
    static func parseMarkup(_ data: Data) -> XMLDocument? {
        let fixed = numericEntities(safeMarkupString(decodeText(data)))
        let doc: XMLDocument?
        if let d = try? XMLDocument(xmlString: fixed, options: [.nodeLoadExternalEntitiesNever, .nodePreserveWhitespace]),
           d.rootElement() != nil {
            doc = d
        } else {
            // Tidy from a string, not bytes: given bytes it guesses the encoding (and drops or mangles
            // anything outside ASCII), while a string is already decoded. An XML declaration makes the HTML
            // tidier give up, so it goes; XML tidying is the last resort.
            let html = fixed.replacingOccurrences(of: #"^\s*<\?xml[^>]*\?>"#, with: "", options: .regularExpression)
            if let d = try? XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever, .nodePreserveWhitespace]),
               d.rootElement() != nil {
                doc = d
            } else {
                doc = try? XMLDocument(xmlString: fixed, options: [.documentTidyXML, .nodeLoadExternalEntitiesNever, .nodePreserveWhitespace])
            }
        }
        if let doc { flattenDeepNesting(doc) }
        return doc
    }

    /// Markup text made safe to hand to an XML parser that was given an already decoded string:
    /// the XML declaration and `<meta charset>` say UTF-8 (the string reaches the parser as UTF-8, so an
    /// old `encoding="iso-8859-1"` would decode it a second time), the DOCTYPE goes (it could ask for a
    /// download), and any entity declaration left over is defused (no "billion laughs").
    static func safeMarkupString(_ text: String) -> String {
        var s = text.replacingOccurrences(of: #"^(\s*<\?xml[^>]*?encoding\s*=\s*["'])[^"']*"#, with: "$1utf-8",
                                          options: .regularExpression)
        if s.range(of: "charset", options: .caseInsensitive) != nil {
            s = s.replacingOccurrences(of: #"(?i)(<meta\b[^>]*?charset\s*=\s*["']?)[A-Za-z0-9_:.\-]+"#, with: "$1utf-8",
                                       options: .regularExpression)
        }
        s = stripDoctype(s)
        if s.range(of: "<!ENTITY", options: .caseInsensitive) != nil, s.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil {
            s = s.replacingOccurrences(of: "<!ENTITY", with: "&lt;!ENTITY", options: .caseInsensitive)
        }
        return s
    }

    /// Whether markup parses as XML as it is (WebKit shows an error page for broken .xhtml files).
    /// Markup that declares entities never counts: WebKit would expand them, so it is re-serialized instead.
    static func isWellFormedXML(_ data: Data) -> Bool {
        if declaresEntities(data) { return false }
        guard let doc = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]) else { return false }
        flattenDeepNesting(doc)   // so releasing the tree can't run out of stack
        return true
    }

    /// Whether the bytes contain an `<!ENTITY` declaration (ASCII-compatible encodings and UTF-16).
    static func declaresEntities(_ data: Data) -> Bool {
        if data.range(of: Data("<!ENTITY".utf8)) != nil || data.range(of: Data("<!entity".utf8)) != nil { return true }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return decodeText(data).range(of: "<!ENTITY", options: .caseInsensitive) != nil
        }
        return false
    }

    /// Deepest element nesting kept as it is. Deeper content becomes plain text in the element at this depth,
    /// so the recursive walks over the tree (and Foundation's own release of it, which recurses too) stay
    /// well inside a 512 KB background-thread stack.
    static let maxMarkupDepth = 128

    /// Flattens everything nested deeper than `limit` into a text node, without recursion.
    static func flattenDeepNesting(_ doc: XMLDocument, limit: Int = maxMarkupDepth) {
        var stack: [(XMLNode, Int)] = [(doc, 0)]
        var cuts: [XMLElement] = []
        while let (node, depth) = stack.popLast() {
            guard let children = node.children, !children.isEmpty else { continue }
            if depth >= limit, let e = node as? XMLElement { cuts.append(e); continue }
            for child in children where child.kind == .element { stack.append((child, depth + 1)) }
        }
        for e in cuts {
            // Text in document order, gathered with an explicit stack (stringValue recurses).
            var text = ""
            var pending: [XMLNode] = Array((e.children ?? []).reversed())
            var all: [XMLNode] = []
            while let n = pending.popLast() {
                all.append(n)
                if n.kind == .text { text += n.stringValue ?? "" }
                if let kids = n.children { pending.append(contentsOf: kids.reversed()) }
            }
            // Children before parents in reverse pre-order: every node is a leaf when it is let go.
            for n in all.reversed() { n.detach() }
            e.setChildren([XMLNode.text(withStringValue: text) as! XMLNode])
        }
    }

    /// UTF-8 (or UTF-16 with a BOM), else the charset the markup declares, else Latin-1.
    static func decodeText(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let s = String(data: data, encoding: .utf16) { return s }
        }
        if let s = String(data: data, encoding: .utf8) { return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        if let r = head.range(of: #"charset\s*=\s*["']?([a-z0-9_\-]+)"#, options: .regularExpression) {
            let name = head[r].split(separator: "=").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) } ?? ""
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: enc) { return s }
            }
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// Drops the DOCTYPE (with an internal subset or external DTD); it isn't needed and could ask for a
    /// download. It is looked for in the whole prolog, however many comments or PIs come first, and quoted
    /// strings and comments inside the internal subset are skipped over.
    static func stripDoctype(_ s: String) -> String {
        let b = Array(s.utf8)
        func at(_ k: Int, _ p: String, caseInsensitive: Bool = false) -> Bool {
            let u = Array(p.utf8)
            guard k + u.count <= b.count else { return false }
            for j in 0..<u.count {
                var c = b[k + j]
                if caseInsensitive, c >= 0x61, c <= 0x7A { c -= 0x20 }
                if c != u[j] { return false }
            }
            return true
        }
        func find(_ p: String, from k: Int) -> Int? {
            var i = k
            while i < b.count { if at(i, p) { return i }; i += 1 }
            return nil
        }
        var i = 0
        if at(0, "\u{FEFF}") { i = 3 }
        while i < b.count {
            let c = b[i]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1; continue }
            if at(i, "<?") { guard let e = find("?>", from: i + 2) else { return s }; i = e + 2; continue }
            if at(i, "<!--") { guard let e = find("-->", from: i + 4) else { return s }; i = e + 3; continue }
            guard at(i, "<!DOCTYPE", caseInsensitive: true) else { return s }   // the root element: no DOCTYPE
            var k = i + 9, depth = 0
            var quote: UInt8 = 0
            while k < b.count {
                let ch = b[k]
                if quote != 0 {
                    if ch == quote { quote = 0 }
                } else if ch == 0x22 || ch == 0x27 {
                    quote = ch
                } else if depth > 0, at(k, "<!--") {
                    guard let e = find("-->", from: k + 4) else { break }
                    k = e + 3
                    continue
                } else if ch == 0x5B {
                    depth += 1
                } else if ch == 0x5D {
                    depth -= 1
                } else if ch == 0x3E && depth <= 0 {
                    var out = b[..<i]
                    out += b[(k + 1)...]
                    return String(decoding: out, as: UTF8.self)
                }
                k += 1
            }
            return s   // never closed: left alone (external DTDs are never loaded; entities are defused later)
        }
        return s
    }

    /// HTML named entities become numeric references, which plain XML understands.
    static func numericEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                if ["amp", "lt", "gt", "quot", "apos"].contains(name) || name.hasPrefix("#") {
                    out += s[i...semi]
                } else if let code = htmlEntities[name] {
                    out += "&#\(code);"
                } else if name.allSatisfy({ $0.isLetter || $0.isNumber }) {
                    out += "&amp;" + name + ";"   // unknown entity: keep it readable
                } else {
                    out += "&amp;"
                    i = s.index(after: i)
                    continue
                }
                i = s.index(after: semi)
                continue
            }
            if c == "&" {
                out += "&amp;"
            } else {
                out.append(c)
            }
            i = s.index(after: i)
        }
        return out
    }

    static let htmlEntities: [String: Int] = [
        "nbsp": 160, "iexcl": 161, "cent": 162, "pound": 163, "curren": 164, "yen": 165, "brvbar": 166, "sect": 167,
        "uml": 168, "copy": 169, "ordf": 170, "laquo": 171, "not": 172, "shy": 173, "reg": 174, "macr": 175, "deg": 176,
        "plusmn": 177, "sup2": 178, "sup3": 179, "acute": 180, "micro": 181, "para": 182, "middot": 183, "cedil": 184,
        "sup1": 185, "ordm": 186, "raquo": 187, "frac14": 188, "frac12": 189, "frac34": 190, "iquest": 191,
        "Agrave": 192, "Aacute": 193, "Acirc": 194, "Atilde": 195, "Auml": 196, "Aring": 197, "AElig": 198, "Ccedil": 199,
        "Egrave": 200, "Eacute": 201, "Ecirc": 202, "Euml": 203, "Igrave": 204, "Iacute": 205, "Icirc": 206, "Iuml": 207,
        "ETH": 208, "Ntilde": 209, "Ograve": 210, "Oacute": 211, "Ocirc": 212, "Otilde": 213, "Ouml": 214, "times": 215,
        "Oslash": 216, "Ugrave": 217, "Uacute": 218, "Ucirc": 219, "Uuml": 220, "Yacute": 221, "THORN": 222, "szlig": 223,
        "agrave": 224, "aacute": 225, "acirc": 226, "atilde": 227, "auml": 228, "aring": 229, "aelig": 230, "ccedil": 231,
        "egrave": 232, "eacute": 233, "ecirc": 234, "euml": 235, "igrave": 236, "iacute": 237, "icirc": 238, "iuml": 239,
        "eth": 240, "ntilde": 241, "ograve": 242, "oacute": 243, "ocirc": 244, "otilde": 245, "ouml": 246, "divide": 247,
        "oslash": 248, "ugrave": 249, "uacute": 250, "ucirc": 251, "uuml": 252, "yacute": 253, "thorn": 254, "yuml": 255,
        "OElig": 338, "oelig": 339, "Scaron": 352, "scaron": 353, "Yuml": 376, "fnof": 402, "circ": 710, "tilde": 732,
        "Alpha": 913, "Beta": 914, "Gamma": 915, "Delta": 916, "Omega": 937, "alpha": 945, "beta": 946, "gamma": 947,
        "delta": 948, "epsilon": 949, "lambda": 955, "mu": 956, "pi": 960, "sigma": 963, "omega": 969,
        "ensp": 8194, "emsp": 8195, "thinsp": 8201, "zwnj": 8204, "zwj": 8205, "lrm": 8206, "rlm": 8207,
        "ndash": 8211, "mdash": 8212, "lsquo": 8216, "rsquo": 8217, "sbquo": 8218, "ldquo": 8220, "rdquo": 8221,
        "bdquo": 8222, "dagger": 8224, "Dagger": 8225, "bull": 8226, "hellip": 8230, "permil": 8240, "prime": 8242,
        "Prime": 8243, "lsaquo": 8249, "rsaquo": 8250, "oline": 8254, "frasl": 8260, "euro": 8364, "trade": 8482,
        "larr": 8592, "uarr": 8593, "rarr": 8594, "darr": 8595, "harr": 8596, "minus": 8722, "infin": 8734,
        "ne": 8800, "le": 8804, "ge": 8805, "asymp": 8776, "loz": 9674, "spades": 9824, "clubs": 9827, "hearts": 9829,
        "diams": 9830,
    ]

    static func localName(_ node: XMLNode) -> String {
        (node.localName ?? node.name ?? "").lowercased()
    }

    /// An attribute by local name, ignoring any prefix ("xlink:href", "epub:type").
    static func attribute(_ element: XMLElement, _ name: String) -> String? {
        if let v = element.attribute(forName: name)?.stringValue { return v }
        for a in element.attributes ?? [] where (a.localName ?? a.name ?? "").lowercased() == name.lowercased() {
            return a.stringValue
        }
        return nil
    }

    static func firstElement(_ node: XMLNode, named name: String) -> XMLElement? {
        if let e = node as? XMLElement, localName(e) == name { return e }
        for child in node.children ?? [] {
            if let found = firstElement(child, named: name) { return found }
        }
        return nil
    }

    static func elements(_ node: XMLNode, named name: String) -> [XMLElement] {
        var out: [XMLElement] = []
        func walk(_ n: XMLNode) {
            if let e = n as? XMLElement, localName(e) == name { out.append(e) }
            n.children?.forEach(walk)
        }
        walk(node)
        return out
    }

    static func textContent(_ node: XMLNode) -> String {
        (node.stringValue ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - CSS (just enough)

extension EbooksAndPages {
    /// The few CSS properties that change the model: weight, style, decoration, alignment, display, script.
    struct CSSProps {
        var bold: Bool?
        var italic: Bool?
        var underline: Bool?
        var strike: Bool?
        var align: Align?
        var hidden: Bool?
        var script: Int?
        var mono: Bool?

        mutating func merge(_ o: CSSProps) {
            bold = o.bold ?? bold; italic = o.italic ?? italic; underline = o.underline ?? underline
            strike = o.strike ?? strike; align = o.align ?? align; hidden = o.hidden ?? hidden
            script = o.script ?? script; mono = o.mono ?? mono
        }

        init() {}

        init(declarations: String) {
            for decl in declarations.split(separator: ";") {
                let parts = decl.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = parts[1].replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces).lowercased()
                switch key {
                case "font-weight":
                    if let n = Int(value) { bold = n >= 600 } else { bold = value == "bold" || value == "bolder" }
                case "font-style": italic = value == "italic" || value == "oblique"
                case "text-decoration", "text-decoration-line":
                    if value.contains("underline") { underline = true }
                    if value.contains("line-through") { strike = true }
                    if value == "none" { underline = false; strike = false }
                case "text-align":
                    align = ["center": .center, "right": .right, "justify": .justify, "left": .left, "start": .natural][value]
                case "display": hidden = value == "none"
                case "visibility": if value == "hidden" { hidden = true }
                case "vertical-align": script = value == "super" ? 1 : value == "sub" ? -1 : 0
                case "font-family": if value.contains("mono") || value.contains("courier") || value.contains("menlo") { mono = true }
                case "font":
                    if value.contains("bold") { bold = true }
                    if value.contains("italic") { italic = true }
                default: break
                }
            }
        }
    }

    /// Rules with simple selectors only (`tag`, `.class`, `tag.class`, `#id`); anything with combinators
    /// or pseudo-classes is skipped rather than applied too widely.
    struct CSSRules {
        var rules: [String: CSSProps] = [:]

        mutating func add(_ css: String) {
            var text = css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
            // Drop @media/@font-face/@page blocks (nested braces) in a simple way.
            text = text.replacingOccurrences(of: #"@[a-zA-Z\-]+[^{;]*\{([^{}]*\{[^{}]*\})*[^{}]*\}"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"@[a-zA-Z\-]+[^{;]*;"#, with: "", options: .regularExpression)
            for chunk in text.split(separator: "}") {
                let parts = chunk.split(separator: "{", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let props = CSSProps(declarations: String(parts[1]))
                for sel in parts[0].split(separator: ",") {
                    let s = sel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !s.isEmpty, s.range(of: #"^[a-z0-9_\-]*([.#][a-z0-9_\-]+)*$"#, options: .regularExpression) != nil else { continue }
                    rules[s, default: CSSProps()].merge(props)
                }
            }
        }

        func props(tag: String, classes: [String], id: String?) -> CSSProps {
            var p = CSSProps()
            if rules.isEmpty { return p }
            if let r = rules[tag] { p.merge(r) }
            for c in classes {
                if let r = rules["." + c] { p.merge(r) }
                if let r = rules[tag + "." + c] { p.merge(r) }
            }
            if classes.count > 1, let r = rules["." + classes.joined(separator: ".")] { p.merge(r) }
            if let id, let r = rules["#" + id] { p.merge(r) }
            return p
        }
    }
}

// MARK: - DOM → blocks

extension EbooksAndPages {
    /// Walks an (X)HTML tree into blocks. `image` resolves an image reference (relative to the document)
    /// to a picture id in the target Doc, or nil when it can't be found.
    struct HTMLImporter {
        var css = CSSRules()
        var image: (String) -> String? = { _ in nil }
        private(set) var blocks: [Block] = []
        private var runs: [Run] = []
        private var align: Align = .natural
        private var listDepth = -1
        private var listOrdered: [Bool] = []
        private var inItem = false
        private var itemStarted = false
        private var quoteDepth = 0
        /// Element nesting below the body. Past `maxDepth` an element's content goes in as plain text
        /// (the walk is recursive, and a 512 KB background-thread stack must hold it).
        private var depth = 0
        static let maxDepth = 40

        init(css: CSSRules = CSSRules(), image: @escaping (String) -> String? = { _ in nil }) {
            self.css = css
            self.image = image
        }

        private struct Style {
            var bold = false, italic = false, underline = false, strike = false, code = false
            var script = 0
            var link: String?
            var pre = false
        }

        mutating func importBody(of doc: XMLDocument) -> [Block] {
            guard let root = doc.rootElement() else { return [] }
            for style in EbooksAndPages.elements(root, named: "style") { css.add(style.stringValue ?? "") }
            let body = EbooksAndPages.firstElement(root, named: "body") ?? root
            walk(body, Style())
            flush()
            return blocks
        }

        private mutating func flush(role: Role = .body) {
            let r = EbooksAndPages.trimmed(runs)
            runs = []
            guard !r.isEmpty else { return }
            if inItem && !itemStarted {
                blocks.append(.item(runs: r, ordered: listOrdered.last ?? false, level: max(0, listDepth)))
                itemStarted = true
            } else {
                blocks.append(.paragraph(runs: r, align: align, role: quoteDepth > 0 ? .quote : role))
            }
        }

        private mutating func text(_ s: String, _ st: Style) {
            var t = s
            if !st.pre {
                t = t.replacingOccurrences(of: #"[ \t\r\n\f]+"#, with: " ", options: .regularExpression)
                if t.hasPrefix(" "), let last = runs.last?.text.last, last == " " || last == "\n" { t.removeFirst() }
                if t.hasPrefix(" "), runs.isEmpty { t.removeFirst() }
            }
            guard !t.isEmpty else { return }
            runs.append(Run(text: t, bold: st.bold, italic: st.italic, underline: st.underline, strike: st.strike,
                            code: st.code, script: st.script, link: st.link))
        }

        private static let skipped: Set<String> = ["head", "script", "style", "title", "noscript", "template", "iframe",
                                                   "object", "embed", "video", "audio", "canvas", "map", "rt", "rp",
                                                   "button", "input", "select", "textarea", "form", "meta", "link"]
        private static let blockTags: Set<String> = ["p", "div", "section", "article", "header", "footer", "aside", "nav",
                                                     "main", "address", "figure", "center", "dl", "dt", "dd", "body",
                                                     "details", "summary", "hgroup", "caption", "fieldset", "legend"]

        private mutating func walk(_ node: XMLNode, _ inherited: Style) {
            switch node.kind {
            case .text:
                text(node.stringValue ?? "", inherited)
                return
            case .element:
                break
            default:
                return
            }
            guard let e = node as? XMLElement else { return }
            let tag = EbooksAndPages.localName(e)
            if Self.skipped.contains(tag) { return }
            if depth >= Self.maxDepth {
                text(e.stringValue ?? "", inherited)
                return
            }
            let classes = (EbooksAndPages.attribute(e, "class") ?? "").lowercased().split(separator: " ").map(String.init)
            var props = css.props(tag: tag, classes: classes, id: EbooksAndPages.attribute(e, "id")?.lowercased())
            if let inline = EbooksAndPages.attribute(e, "style") { props.merge(CSSProps(declarations: inline)) }
            if props.hidden == true { return }
            let epubType = (EbooksAndPages.attribute(e, "type") ?? "").lowercased()
            if epubType.contains("pagebreak") { return }   // page-number markers from print editions

            var st = inherited
            switch tag {
            case "b", "strong": st.bold = true
            case "i", "em", "cite", "var", "dfn": st.italic = true
            case "u", "ins": st.underline = true
            case "s", "strike", "del": st.strike = true
            case "sup": st.script = 1
            case "sub": st.script = -1
            case "code", "tt", "kbd", "samp": st.code = true
            case "a":
                if let href = EbooksAndPages.attribute(e, "href"), !href.isEmpty,
                   href.hasPrefix("http") || href.hasPrefix("mailto:") { st.link = href }
            default: break
            }
            if let b = props.bold { st.bold = b }
            if let i = props.italic { st.italic = i }
            if let u = props.underline { st.underline = u }
            if let s = props.strike { st.strike = s }
            if let s = props.script, s != 0 { st.script = s }
            if props.mono == true { st.code = true }

            switch tag {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                walkChildren(e, st)
                let r = EbooksAndPages.trimmed(runs).map { r -> Run in var r = r; r.bold = false; return r }
                runs = []
                if !r.isEmpty { blocks.append(.heading(level: Int(String(tag.last!)) ?? 1, runs: r)) }
            case "br":
                runs.append(Run(text: "\n"))
            case "hr":
                flush()
                blocks.append(.rule)
            case "img":
                if let src = EbooksAndPages.attribute(e, "src"), let id = image(src) {
                    flush()
                    let width = EbooksAndPages.attribute(e, "width")
                        .flatMap { Double($0.replacingOccurrences(of: "px", with: "").trimmingCharacters(in: .whitespaces)) }
                    blocks.append(.image(id: id, alt: EbooksAndPages.attribute(e, "alt") ?? "", width: EbooksAndPages.usableWidth(width)))
                } else if let alt = EbooksAndPages.attribute(e, "alt"), !alt.isEmpty,
                          !EbooksAndPages.Package.isRemote(EbooksAndPages.attribute(e, "src") ?? "") {
                    text(" " + alt + " ", st)   // a missing local picture: keep what it showed in words
                }
            case "image":   // SVG <image xlink:href="cover.jpg"/>, the usual EPUB cover page
                if let href = EbooksAndPages.attribute(e, "href"), let id = image(href) {
                    flush()
                    blocks.append(.image(id: id, alt: "", width: nil))
                }
            case "svg":
                for img in EbooksAndPages.elements(e, named: "image") { walk(img, st) }
            case "math":
                text(EbooksAndPages.attribute(e, "alttext") ?? EbooksAndPages.textContent(e), st)
            case "ul", "ol":
                flush()
                let savedItem = (inItem, itemStarted)
                listDepth += 1
                listOrdered.append(tag == "ol")
                inItem = false
                walkChildren(e, st)
                flush()
                listOrdered.removeLast()
                listDepth -= 1
                (inItem, itemStarted) = savedItem
            case "li":
                flush()
                let saved = (inItem, itemStarted)
                inItem = true
                itemStarted = false
                walkChildren(e, st)
                flush()
                (inItem, itemStarted) = saved
            case "pre":
                flush()
                var p = st
                p.pre = true
                walkChildren(e, p)
                let code = runs.map(\.text).joined().trimmingCharacters(in: .newlines)
                runs = []
                if !code.isEmpty { blocks.append(.code(code)) }
            case "blockquote":
                flush()
                quoteDepth += 1
                walkChildren(e, st)
                flush()
                quoteDepth -= 1
            case "table":
                flush()
                blocks.append(contentsOf: table(e, st))
            case "figcaption":
                flush()
                walkChildren(e, st)
                flush(role: .caption)
            default:
                if Self.blockTags.contains(tag) || tag == "td" || tag == "th" {
                    flush()
                    let savedAlign = align
                    if let a = props.align { align = a } else if let a = EbooksAndPages.attribute(e, "align")?.lowercased(),
                                                                 let al = Align(rawValue: a) { align = al }
                    if tag == "center" { align = .center }
                    walkChildren(e, tag == "dt" ? { var s = st; s.bold = true; return s }() : st)
                    flush()
                    align = savedAlign
                } else {
                    walkChildren(e, st)
                }
            }
        }

        private mutating func walkChildren(_ e: XMLElement, _ st: Style) {
            depth += 1
            defer { depth -= 1 }
            for child in e.children ?? [] { walk(child, st) }
        }

        /// A table's rows of cells; nested blocks inside a cell are flattened to its text.
        private mutating func table(_ e: XMLElement, _ st: Style) -> [Block] {
            var rows: [[[Run]]] = []
            var header = false
            for (i, tr) in EbooksAndPages.elements(e, named: "tr").enumerated() {
                var row: [[Run]] = []
                for cell in tr.children ?? [] {
                    guard let ce = cell as? XMLElement else { continue }
                    let name = EbooksAndPages.localName(ce)
                    guard name == "td" || name == "th" else { continue }
                    if i == 0 && name == "th" { header = true }
                    var sub = HTMLImporter(css: css, image: image)
                    sub.depth = depth + 3   // table, row, cell
                    sub.walk(ce, st)
                    sub.flush()
                    var cellRuns: [Run] = []
                    for b in sub.blocks {
                        if !cellRuns.isEmpty { cellRuns.append(Run(text: "\n")) }
                        cellRuns += b.runs
                    }
                    row.append(cellRuns)
                }
                if !row.isEmpty { rows.append(row) }
            }
            return rows.isEmpty ? [] : [.table(rows: rows, header: header)]
        }
    }
}

// MARK: - HTML serializer

extension EbooksAndPages {
    static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
                                            "source", "track", "wbr", "param"]

    /// Elements never written: anything that runs code, embeds another document, submits or redirects
    /// (scripts, frames, plug-ins, forms, `<base>`, SVG animation that can rewrite links).
    static let unsafeElements: Set<String> = ["script", "iframe", "frame", "frameset", "object", "embed", "applet", "base",
                                              "form", "input", "button", "select", "textarea", "portal", "fencedframe",
                                              "animate", "set", "animatemotion", "animatetransform", "handler", "listener"]
    /// Attributes never written (besides `on…` event handlers).
    static let unsafeAttributes: Set<String> = ["srcdoc", "formaction", "action", "ping", "xml:base", "http-equiv"]

    /// Writes a node as HTML5: void elements self-close, every other element gets an end tag (so an XHTML
    /// `<div/>` doesn't swallow what follows). Scripts, frames, plug-ins, forms, `<base>`, refreshing
    /// `<meta>`, SVG animation and event handlers are left out. `forExport` (a standalone HTML file) also
    /// leaves out `<meta>`, `<link>` and `<style>` (the caller collects the styles). Nesting deeper than
    /// `maxMarkupDepth` is written as its text.
    /// `rewrite` may change an attribute's value (links, image sources) given (element, attribute, value).
    static func serializeHTML(_ node: XMLNode, forExport: Bool = false,
                              rewrite: (String, String, String) -> String? = { _, _, v in v }) -> String {
        var out = ""
        func write(_ n: XMLNode, _ depth: Int) {
            switch n.kind {
            case .text:
                out += escapeXML(n.stringValue ?? "")
            case .element:
                guard let e = n as? XMLElement else { return }
                let tag = localName(e)
                if unsafeElements.contains(tag) { return }
                if tag == "meta", forExport || attribute(e, "http-equiv") != nil { return }
                if forExport, tag == "link" || tag == "style" { return }
                if depth > maxMarkupDepth {
                    out += escapeXML(textContent(e))
                    return
                }
                var name = tag
                if let prefix = e.prefix, !prefix.isEmpty, prefix != "html" { name = (e.name ?? tag) }
                out += "<" + name
                for a in e.attributes ?? [] {
                    let attrName = a.name ?? ""
                    let lower = attrName.lowercased()
                    if lower.hasPrefix("on") || unsafeAttributes.contains(lower) { continue }
                    if lower == "xmlns" || lower.hasPrefix("xmlns:") && !lower.hasPrefix("xmlns:xlink") { continue }
                    guard attrName.allSatisfy({ $0.isLetter || $0.isNumber || "-_:.".contains($0) }),
                          let value = rewrite(tag, lower, a.stringValue ?? "") else { continue }
                    out += " \(attrName)=\"\(escapeXML(value, attribute: true))\""
                }
                if tag == "svg" && e.attribute(forName: "xmlns") == nil { out += " xmlns=\"http://www.w3.org/2000/svg\"" }
                if voidElements.contains(tag) {
                    out += "/>"
                    return
                }
                out += ">"
                e.children?.forEach { write($0, depth + 1) }
                out += "</\(name)>"
            case .comment, .processingInstruction:
                return
            default:
                n.children?.forEach { write($0, depth + 1) }
            }
        }
        write(node, 0)
        return out
    }

    /// A link target that is safe to keep in exported HTML: http(s) or mailto, nothing that runs or
    /// embeds (javascript:, data:, file:, vbscript: ...). Leading and trailing spaces are ignored, as
    /// browsers do. nil when the link has some other scheme; relative links are returned as they are.
    static func safeLink(_ value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = String(v.lowercased().filter { $0 != "\t" && $0 != "\n" && $0 != "\r" })
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") { return v }
        if Package.isRemote(v) || lower.hasPrefix("data:") || lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") { return nil }
        return v
    }

    /// A data: URI that only carries a picture, font or media file (never a document that could run script).
    static func isPassiveDataURI(_ value: String) -> Bool {
        let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["data:image/", "data:font/", "data:audio/", "data:video/", "data:application/font", "data:application/x-font"]
            .contains { lower.hasPrefix($0) }
    }
}
