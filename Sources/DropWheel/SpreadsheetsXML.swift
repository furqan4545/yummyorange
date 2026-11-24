import Foundation

/// A streaming XML reader for the spreadsheet formats. Element and attribute names arrive without
/// their namespace prefix ("x:c" and "c" are both "c"), because writers pick prefixes freely.
/// Attributes keep their full names too, for the rare clash between prefixes (`Attributes.get`).
/// External entities are never resolved.
final class SheetXML: NSObject, XMLParserDelegate {
    /// An element's attributes, looked up by local name.
    struct Attributes {
        let raw: [String: String]

        /// The value of `local`; when several prefixes carry it, the one in `prefer` wins.
        func get(_ local: String, prefer: String? = nil) -> String? {
            if let prefer, let v = raw["\(prefer):\(local)"] { return v }
            if let v = raw[local] { return v }
            // Any other prefix: "x:local". Compared on bytes, since this runs for every element.
            let n = local.utf8.count
            for (k, v) in raw where k.utf8.count > n && k.hasSuffix(local) {
                if k.utf8[k.utf8.index(k.utf8.endIndex, offsetBy: -n - 1)] == UInt8(ascii: ":") { return v }
            }
            return nil
        }

        func int(_ local: String) -> Int? { get(local).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
    }

    var onStart: ((String, Attributes) -> Void)?
    var onEnd: ((String) -> Void)?
    var onText: ((String) -> Void)?
    private var failure: Error?

    static func local(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    /// Parses `data`, calling the handlers in document order. Throws on malformed XML.
    func parse(_ data: Data, what: String) throws {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        let ok = parser.parse()
        if let failure { throw failure }
        if !ok {
            let detail = parser.parserError.map { " (\(($0 as NSError).code))" } ?? ""
            throw ConversionError.unsupported("The \(what) part of this file is damaged\(detail).")
        }
    }

    /// Lets a handler stop the parse with an error (a size limit, say).
    func abort(_ error: Error) {
        failure = error
        current?.abortParsing()
    }

    private weak var current: XMLParser?

    func parserDidStartDocument(_ parser: XMLParser) { current = parser }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        onStart?(SheetXML.local(elementName), Attributes(raw: attributeDict))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        onEnd?(SheetXML.local(elementName))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { onText?(string) }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        onText?(String(decoding: CDATABlock, as: UTF8.self))
    }

    /// Unescapes OOXML's `_xHHHH_` notation for characters XML can't hold ("_x000D_" is a carriage return,
    /// "_x005F_" a literal underscore).
    static func unescapeOOXML(_ s: String) -> String {
        guard s.contains("_x") else { return s }
        var out = ""
        var u = Substring(s)
        while let r = u.range(of: "_x") {
            out += u[u.startIndex..<r.lowerBound]
            let rest = u[r.upperBound...]
            let hex = rest.prefix(4)
            if hex.count == 4, rest.dropFirst(4).first == "_", let v = UInt32(hex, radix: 16), let scalar = UnicodeScalar(v) {
                out.unicodeScalars.append(scalar)
                u = rest.dropFirst(5)
            } else {
                out += "_x"
                u = rest
            }
        }
        return out + u
    }

    /// The reverse: characters XML 1.0 can't carry become `_xHHHH_`, and an underscore that would
    /// read as the start of such an escape becomes `_x005F_`. The result still needs XML escaping.
    static func escapeOOXML(_ s: String) -> String {
        var needs = false
        for scalar in s.unicodeScalars where (scalar.value < 0x20 && scalar != "\n" && scalar != "\t") || scalar == "_" {
            needs = true; break
        }
        guard needs else { return s }
        var out = ""
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c.value < 0x20 && c != "\n" && c != "\t" {
                out += String(format: "_x%04X_", c.value)
            } else if c == "_", i + 6 < scalars.count, scalars[i + 1] == "x", scalars[i + 6] == "_",
                      scalars[(i + 2)..<(i + 6)].allSatisfy({ $0.properties.isASCIIHexDigit }) {
                // Literal "_x0041_" in the source text must survive a round trip.
                out += "_x005F_"
            } else {
                out.unicodeScalars.append(c)
            }
            i += 1
        }
        return out
    }
}
