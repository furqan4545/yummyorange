import Foundation

/// A parsed XML element. Namespace prefixes are normalised to the usual ones ("p:", "a:", "r:", "c:"),
/// whatever prefixes the writer declared, so transitional and strict OOXML read the same way.
/// `mc:AlternateContent` is resolved while parsing (the `mc:Fallback` branch wins, else the first `mc:Choice`).
final class PPTXNode {
    let name: String
    var attrs: [String: String]
    var children: [PPTXNode] = []
    var text = ""

    init(_ name: String, _ attrs: [String: String] = [:]) {
        self.name = name
        self.attrs = attrs
    }

    subscript(_ key: String) -> String? { attrs[key] }

    func child(_ name: String) -> PPTXNode? { children.first { $0.name == name } }
    func all(_ name: String) -> [PPTXNode] { children.filter { $0.name == name } }
    /// The first child whose name is in `names`.
    func first(of names: Set<String>) -> PPTXNode? { children.first { names.contains($0.name) } }
    /// Follows a chain of child names: `node.at("p:cSld", "p:spTree")`.
    func at(_ path: String...) -> PPTXNode? {
        var node: PPTXNode? = self
        for step in path { node = node?.child(step) }
        return node
    }
    /// Every descendant with this name, depth first.
    func descendants(_ name: String) -> [PPTXNode] {
        var out: [PPTXNode] = []
        func walk(_ n: PPTXNode) { for c in n.children { if c.name == name { out.append(c) }; walk(c) } }
        walk(self)
        return out
    }
    var localName: String { name.split(separator: ":").last.map(String.init) ?? name }

    /// Largest magnitude a numeric attribute may have. OOXML's widest numbers (EMU coordinates) stay below 3e13;
    /// anything beyond is damage, and would trap when converted to Int or overflow later arithmetic.
    static let numericLimit = 1e15

    /// An integer attribute ("12", or "12.0" as some writers put it). NaN, infinities and out-of-range
    /// values ("1e20", "9223372036854775807") read as missing instead of trapping.
    func int(_ key: String) -> Int? {
        guard let raw = attrs[key]?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let v = Int(raw) { return Double(v.magnitude) < Self.numericLimit ? v : nil }
        guard let d = Double(raw), d.isFinite, abs(d) < Self.numericLimit else { return nil }
        return Int(d)
    }
    /// A number attribute; NaN, infinities and out-of-range values read as missing.
    func double(_ key: String) -> Double? {
        guard let d = attrs[key].flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
              d.isFinite, abs(d) < Self.numericLimit else { return nil }
        return d
    }
    func bool(_ key: String) -> Bool? {
        guard let v = attrs[key]?.lowercased() else { return nil }
        if ["1", "true", "on"].contains(v) { return true }
        if ["0", "false", "off"].contains(v) { return false }
        return nil
    }
    /// Concatenated text of every descendant (used for plain-text extraction).
    var allText: String { children.isEmpty ? text : text + children.map(\.allText).joined() }
}

/// SAX parser that builds `PPTXNode` trees. External entities are never resolved.
final class PPTXXMLParser: NSObject, XMLParserDelegate {
    /// Canonical prefixes for the namespaces the PowerPoint code reads.
    private static let canonical: [String: String] = [
        "http://schemas.openxmlformats.org/presentationml/2006/main": "p",
        "http://purl.oclc.org/ooxml/presentationml/main": "p",
        // SmartArt drawings use the same element names as slides, so read them as "p:".
        "http://schemas.microsoft.com/office/drawing/2008/diagram": "p",
        "http://schemas.openxmlformats.org/drawingml/2006/main": "a",
        "http://purl.oclc.org/ooxml/drawingml/main": "a",
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships": "r",
        "http://purl.oclc.org/ooxml/officeDocument/relationships": "r",
        "http://schemas.openxmlformats.org/package/2006/relationships": "pr",
        "http://schemas.openxmlformats.org/package/2006/content-types": "ct",
        "http://schemas.openxmlformats.org/markup-compatibility/2006": "mc",
        "http://schemas.openxmlformats.org/drawingml/2006/chart": "c",
        "http://purl.oclc.org/ooxml/drawingml/chart": "c",
        "http://schemas.openxmlformats.org/drawingml/2006/diagram": "dgm",
        "http://purl.oclc.org/ooxml/drawingml/diagram": "dgm",
        "http://schemas.openxmlformats.org/drawingml/2006/picture": "pic",
        "http://schemas.openxmlformats.org/package/2006/metadata/core-properties": "cp",
        "http://purl.org/dc/elements/1.1/": "dc",
        "http://purl.org/dc/terms/": "dcterms",
        "http://schemas.microsoft.com/office/drawing/2010/main": "a14",
        "http://schemas.microsoft.com/office/powerpoint/2010/main": "p14",
    ]

    private var stack: [(node: PPTXNode, scope: [String: String])] = []
    private var root: PPTXNode?

    static func parse(_ data: Data) -> PPTXNode? {
        let p = PPTXXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = p
        let ok = parser.parse()
        // A truncated or malformed part still yields what was read before the error: close the open elements.
        if !ok, p.root == nil, !p.stack.isEmpty {
            while p.stack.count > 1, let (node, _) = p.stack.popLast() { p.stack[p.stack.count - 1].node.children.append(node) }
            return p.stack.first?.node
        }
        return p.root
    }

    static func parse(_ string: String) -> PPTXNode? { parse(Data(string.utf8)) }

    private func resolve(_ qname: String, scope: [String: String], isAttribute: Bool) -> String {
        let parts = qname.split(separator: ":", maxSplits: 1).map(String.init)
        let prefix = parts.count == 2 ? parts[0] : ""
        let local = parts.count == 2 ? parts[1] : parts[0]
        if prefix == "xml" { return qname }
        // Unprefixed attributes have no namespace; unprefixed elements take the default one.
        if prefix.isEmpty && isAttribute { return local }
        guard let uri = scope[prefix] else { return prefix.isEmpty ? local : qname }
        let canon = Self.canonical[uri] ?? prefix
        return canon.isEmpty ? local : canon + ":" + local
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        var scope = stack.last?.scope ?? [:]
        for (k, v) in attributeDict {
            if k == "xmlns" { scope[""] = v } else if k.hasPrefix("xmlns:") { scope[String(k.dropFirst(6))] = v }
        }
        var attrs: [String: String] = [:]
        for (k, v) in attributeDict where k != "xmlns" && !k.hasPrefix("xmlns:") {
            attrs[resolve(k, scope: scope, isAttribute: true)] = v
        }
        stack.append((PPTXNode(resolve(elementName, scope: scope, isAttribute: false), attrs), scope))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let (node, _) = stack.popLast() else { return }
        var adopted = [node]
        if node.name == "mc:AlternateContent" {
            let branch = node.child("mc:Fallback") ?? node.child("mc:Choice")
            adopted = branch?.children ?? []
        }
        if let parent = stack.last?.node {
            parent.children.append(contentsOf: adopted)
        } else {
            root = adopted.first ?? node
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.node.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.node.text += String(decoding: CDATABlock, as: UTF8.self)
    }
}

extension PPTXNode {
    /// Escapes text for XML element content and attribute values.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                // XML 1.0 forbids most control characters, even escaped.
                if scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r" { continue }
                if scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
