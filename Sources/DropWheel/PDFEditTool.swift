import AppKit

/// Edit PDF…: edit a PDF's existing text in place, line by line, and add new text. The app opens an editor
/// window (`present`); the command line runs find/replace or a list of edits headlessly through the same session.
enum PDFEditTool: FeatureModule {
    static var commands: [WheelCommand] {
        [
            WheelCommand(wheel: .tools, id: "editpdf", title: "Edit PDF…", symbol: "character.cursor.ibeam",
                         applies: applies,
                         present: { present($0) },
                         run: { files, options, progress in try files.map { try run($0, options: options, progress: progress) } }),
        ]
    }

    /// Exactly one PDF.
    static func applies(_ files: [URL]) -> Bool { files.count == 1 && Ext.all(files, in: ["pdf"]) }

    /// Opens the editor window (PDFEditWindow); replaceable for tests.
    static var openWindow: ((URL) -> Void)? = { PDFEditWindowController.open($0) }

    static func present(_ files: [URL]) {
        guard let url = files.first else { return }
        if PDFTools.isEncrypted(url) {
            HUD.shared.flash("\(url.lastPathComponent) is password-protected. Remove the password first with Remove Password.", isError: true, seconds: 5)
            return
        }
        if let openWindow { openWindow(url); return }
        HUD.shared.flash("The Edit PDF window isn’t part of this build yet.", isError: true, seconds: 4)
    }

    static func selfTest(_ name: String) -> String? {
        #if DEBUG
        switch name {
        case "pdf-edit", "pdfedit": return PDFEditTests.run()
        case "pdf-edit-ui": return PDFEditUITests.run()
        case "pdf-edit-hostile": return PDFEditTests.runHostile()
        default: return nil
        }
        #else
        return nil
        #endif
    }

    /// `--snapshot editpdf <out.png> <file.pdf>`: the editor window offscreen (see `PDFEditWindowController.snapshotView`).
    static func snapshot(_ id: String, files: [URL], options: ToolOptions) -> NSView? {
        guard id == "editpdf", let url = files.first else { return nil }
        return PDFEditWindowController.snapshotView(url: url, options: options)
    }

    // MARK: Command line

    /// Options:
    /// - `find`, `replace`: replace text (the first match, or every match with `all=true`); `page=N` limits it to page N.
    /// - `spacing=flow|keep|fit` (default flow), `clean=true` (remove replaced text from the file; default false).
    /// - `edits=[…]`: a JSON array of `{"page":1,"find":"…","replace":"…"}`, `{"page":1,"delete":"…"}` (removes that text,
    ///   keeping everything else in place) and `{"page":1,"add":"…","x":72,"y":700,"size":12,"font":"Helvetica","color":"#RRGGBB"}`
    ///   (x and y in PDF points from the page's bottom-left corner, before any page rotation). Each may also set "spacing" and "all".
    /// Writes "<name> edited.pdf" next to the original.
    static func run(_ url: URL, options: ToolOptions, progress: @escaping (Double) -> Void) throws -> URL {
        let session = try PDFEditSession(url: url)
        if session.isReadOnly { throw ConversionError.unsupported("The signature on \(url.lastPathComponent) doesn’t allow changes.") }
        session.removeReplacedText = options.bool("clean", false)
        if session.removeReplacedText && !session.canRemoveReplacedText {
            throw ConversionError.unsupported("\(url.lastPathComponent) is signed, so replaced text can’t be removed from the file.")
        }
        if let json = options["edits"]?.trimmingCharacters(in: .whitespaces), !json.isEmpty {
            guard let list = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else {
                throw ConversionError.unsupported("edits must be a JSON array of objects, for example [{\"page\":1,\"find\":\"old\",\"replace\":\"new\"}].")
            }
            for (k, e) in list.enumerated() {
                try apply(e, session: session, defaults: options)
                progress(Double(k + 1) / Double(list.count + 1))
            }
        } else {
            guard let find = options["find"], !find.isEmpty else {
                throw ConversionError.unsupported("Say what to change with --opt find=… --opt replace=… (or --opt edits=[…]).")
            }
            try replace(find, with: options["replace"] ?? "", page: try checkedPage(options["page"].map { Int($0) ?? 0 }, session: session),
                        all: options.bool("all", false), spacing: try spacing(options["spacing"]), session: session)
        }
        progress(0.9)
        return try session.save()
    }

    static func spacing(_ s: String?) throws -> PDFSpacing {
        guard let s = s?.lowercased(), !s.isEmpty else { return .flow }
        switch s {
        case "flow": return .flow
        case "keep", "keep-position", "keepposition": return .keep
        case "fit", "fit-width", "fitwidth": return .fit
        default: throw ConversionError.unsupported("spacing must be flow, keep or fit.")
        }
    }

    /// A 1-based page number from the command line, checked against the document (a page of -1e30 or
    /// -9223372036854775808 trapped in the arithmetic that turns it into an index).
    static func checkedPage(_ page: Int?, session: PDFEditSession) throws -> Int? {
        guard let page else { return nil }
        guard page >= 1, page <= session.pageCount else {
            let n = session.pageCount
            throw ConversionError.unsupported("Page \(page) doesn’t exist: \(session.url.lastPathComponent) has \(n) \(n == 1 ? "page" : "pages").")
        }
        return page
    }

    private static func apply(_ e: [String: Any], session: PDFEditSession, defaults: ToolOptions) throws {
        func double(_ k: String) -> Double? { (e[k] as? NSNumber)?.doubleValue ?? (e[k] as? String).flatMap { Double($0) } }
        func int(_ k: String) -> Int? { e[k] == nil ? nil : double(k).flatMap { PDFNumber.int($0) } ?? 0 }
        let page = try checkedPage(int("page"), session: session)
        let sp = try spacing((e["spacing"] as? String) ?? defaults["spacing"])
        let all = (e["all"] as? Bool) ?? defaults.bool("all", false)
        if let find = e["find"] as? String {
            try replace(find, with: (e["replace"] as? String) ?? "", page: page, all: all, spacing: sp, session: session)
        } else if let text = e["delete"] as? String {
            try delete(text, page: page, session: session)
        } else if let text = e["add"] as? String {
            let p = (page ?? 1) - 1
            guard p >= 0, p < session.pageCount else { throw ConversionError.unsupported("Page \(p + 1) doesn’t exist.") }
            // The same range as the inspector's size stepper; text outside the page would never show.
            let size = double("size") ?? 12
            guard (1...400).contains(size) else { throw ConversionError.unsupported("size must be from 1 to 400 points.") }
            var style = PDFTextStyle(fontName: (e["font"] as? String) ?? "Helvetica", size: size)
            if let hex = e["color"] as? String {
                let c = try ImageExtras.hexColor(hex).cgColor
                style = PDFTextStyle(fontName: style.fontName, size: style.size, color: c)
            }
            let crop = session.pages[p].cropBox
            let at = CGPoint(x: double("x") ?? crop.minX + 72, y: double("y") ?? crop.maxY - 72)
            guard crop.insetBy(dx: -0.5, dy: -0.5).contains(at) else {
                func f(_ v: CGFloat) -> String { PDFNumber.format(Double(v)) }
                throw ConversionError.unsupported("x and y must be on page \(p + 1): x from \(f(crop.minX)) to \(f(crop.maxX)) and y from \(f(crop.minY)) to \(f(crop.maxY)) points.")
            }
            try session.addText(text, page: p, at: at, style: style)
        } else {
            throw ConversionError.unsupported("Each edit needs find, delete or add.")
        }
    }

    /// Replaces `find` in the current text of the matching lines.
    static func replace(_ find: String, with replacement: String, page: Int?, all: Bool, spacing: PDFSpacing, session: PDFEditSession) throws {
        let needle = find.precomposedStringWithCanonicalMapping
        let matches = currentMatches(needle, page: page, session: session)
        guard !matches.isEmpty else { throw notFound(find, page: page, session: session) }
        for (id, text) in all ? matches : [matches[0]] {
            let new: String
            if all { new = text.replacingOccurrences(of: needle, with: replacement) }
            else if let r = text.range(of: needle) { new = text.replacingCharacters(in: r, with: replacement) }
            else { continue }
            try session.setText(new, for: id, spacing: spacing, scope: all ? .allPages : .thisPage)
        }
    }

    static func delete(_ text: String, page: Int?, session: PDFEditSession) throws {
        let needle = text.precomposedStringWithCanonicalMapping
        guard let (id, current) = currentMatches(needle, page: page, session: session).first else {
            throw notFound(text, page: page, session: session)
        }
        if current.trimmingCharacters(in: .whitespaces) == needle.trimmingCharacters(in: .whitespaces) {
            try session.deleteLine(id)
        } else if let r = current.range(of: needle) {
            try session.setText(current.replacingCharacters(in: r, with: ""), for: id, spacing: .keep)
        }
    }

    /// "Not found", with the reason when the text is there but can't be edited or a page couldn't be read (a
    /// damaged or oversized part), so the message says why instead of only that the text is missing.
    static func notFound(_ text: String, page: Int?, session: PDFEditSession) -> ConversionError {
        let needle = text.precomposedStringWithCanonicalMapping
        let name = session.url.lastPathComponent
        let pages = page.map { [$0 - 1] } ?? Array(0..<session.pageCount)
        for p in pages where p >= 0 && p < session.pageCount {
            for l in session.lines(page: p) where l.text.precomposedStringWithCanonicalMapping.contains(needle) {
                if let why = session.availability(PDFLineID(page: p, line: l.index)).reason {
                    return .unsupported("“\(text)” on page \(p + 1) of \(name) can’t be edited: \(why)")
                }
            }
        }
        for p in pages where p >= 0 && p < session.pageCount {
            if let why = session.content(page: p).problems.first {
                return .unsupported("“\(text)” wasn’t found in \(name). Page \(p + 1) couldn’t be read: \(why)")
            }
        }
        return .unsupported("“\(text)” isn’t in \(name)\(page.map { " on page \($0)" } ?? "").")
    }

    /// Lines whose current text (after earlier edits) contains `needle`.
    private static func currentMatches(_ needle: String, page: Int?, session: PDFEditSession) -> [(PDFLineID, String)] {
        var out: [(PDFLineID, String)] = []
        let pages = page.map { [$0 - 1] } ?? Array(0..<session.pageCount)
        for p in pages where p >= 0 && p < session.pageCount {
            for l in session.lines(page: p) {
                let id = PDFLineID(page: p, line: l.index)
                guard let info = session.info(id), !info.isDeleted, info.availability.isEditable else { continue }
                let t = info.text.precomposedStringWithCanonicalMapping
                if t.contains(needle) { out.append((id, t)) }
            }
        }
        return out
    }
}
