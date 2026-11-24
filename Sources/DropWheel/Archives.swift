import Foundation
import Compression
import UniformTypeIdentifiers

/// Creating ZIP, TAR and GZIP archives and extracting every common kind (ZIP, TAR, TGZ, BZ2, XZ, 7Z, RAR).
///
/// Archives are made with the system's bsdtar (libarchive): it writes ZIP as well as TAR, keeps folder
/// structure, permissions and symlinks, skips .DS_Store anywhere in the tree, takes several items from
/// different folders in one pass and handles files over 4 GB (ZIP64). Mac-only metadata (extended
/// attributes, ACLs, resource forks) is left out so the archives unpack cleanly on any system.
/// Single files are gzipped with /usr/bin/gzip. ZIPs are unpacked with ditto, like Archive Utility,
/// and everything else with bsdtar (RAR is read-only: nothing on macOS writes it).
enum Archives {
    static var commands: [WheelCommand] {
        [
            WheelCommand(wheel: .convert, id: "zip", title: "ZIP", combinesInputs: true, applies: offeredOnConvertWheel,
                         run: { files, _, progress in [try create(.zip, from: files, progress: progress)] }),
            WheelCommand(wheel: .convert, id: "tar", title: "TAR", combinesInputs: true, applies: offeredOnConvertWheel,
                         run: { files, _, progress in [try create(.tar, from: files, progress: progress)] }),
            WheelCommand(wheel: .convert, id: "gz", title: "GZIP", combinesInputs: true, applies: offeredOnConvertWheel,
                         run: { files, _, progress in [try create(.gzip, from: files, progress: progress)] }),
            WheelCommand(wheel: .tools, id: "extract", title: "Extract", symbol: "archivebox",
                         applies: { Ext.all($0, in: Ext.archives) },
                         run: { files, _, progress in try files.map { try extract($0, progress: progress) } }),
            WheelCommand(wheel: .actions, id: "zip", title: "Zip", symbol: "doc.zipper", combinesInputs: true,
                         applies: { !$0.isEmpty },
                         run: { files, _, progress in [try create(.zip, from: files, progress: progress)] }),
        ]
    }

    // MARK: When to offer

    /// Extension groups other modules convert. Files in them keep their own Convert wheel uncluttered.
    private static let documentGroups: [(String, Set<String>)] = [
        ("text", Ext.textDocuments), ("ebook", Ext.ebooks), ("pages", Ext.pages), ("slides", Ext.presentations),
        ("sheet", Ext.spreadsheets), ("subtitles", Ext.subtitles), ("svg", Ext.svg), ("raw", Ext.rawImages),
        ("archive", Ext.archives),
    ]

    /// What kind of thing a dropped item is, for deciding whether archive petals belong on the Convert wheel.
    private static func category(_ url: URL) -> String {
        let ext = Ext.of(url)
        if let group = documentGroups.first(where: { $0.1.contains(ext) }) { return group.0 }   // includes .pages/.rtfd bundles
        if Ext.isFolder(url) { return "folder" }
        let kind = MoreFormats.kind(url)
        return kind == .other ? "plain" : kind.rawValue
    }

    /// Convert wheel: only for folders, mixed selections, and files nothing else converts.
    static func offeredOnConvertWheel(_ files: [URL]) -> Bool {
        guard !files.isEmpty else { return false }
        var seen = Set<String>()
        for url in files {
            let c = category(url)
            if c == "folder" { return true }
            seen.insert(c)
            if seen.count > 1 { return true }
        }
        return seen == ["plain"]
    }

    // MARK: Creating

    enum Kind { case zip, tar, gzip }

    /// Archives every item into one file next to the first item: "Name.zip" for one item, "Archive.zip"
    /// for several. GZIP compresses a single file to "name.ext.gz" and anything else to ".tar.gz".
    static func create(_ kind: Kind, from items: [URL], progress: @escaping (Double) -> Void) throws -> URL {
        let fm = FileManager.default
        let items = items.filter { $0.lastPathComponent != ".DS_Store" }
        guard let first = items.first else { throw ConversionError.unsupported("There’s nothing to archive.") }
        var names = Set<String>()
        for item in items {
            guard fm.fileExists(atPath: item.path) else { throw ConversionError.unreadable(item.lastPathComponent) }
            let key = item.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
            guard names.insert(key).inserted else {
                throw ConversionError.unsupported("Two of the items are named “\(item.lastPathComponent)”. Rename one and try again.")
            }
        }

        let single = items.count == 1
        let isFolder = Ext.isFolder(first)
        let dir = first.deletingLastPathComponent()
        if kind == .gzip, single, !isFolder { return try gzipFile(first) }

        var base = single ? (isFolder ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent) : "Archive"
        while base.hasPrefix(".") { base.removeFirst() }   // don't make a hidden archive from a dotfile
        if base.isEmpty { base = "Archive" }
        let ext = kind == .zip ? "zip" : kind == .tar ? "tar" : "tar.gz"
        let out = unique(in: dir, base: base, ext: ext)

        var args = ["-c", "-v", "-f", out.path, "--no-mac-metadata", "--no-xattrs", "--no-acls", "--no-fflags",
                    "--exclude", ".DS_Store"]
        switch kind {
        case .zip: args += ["--format", "zip", "--options", "zip:hdrcharset=UTF-8"]
        case .gzip: args.insert("-z", at: 1)
        case .tar: break
        }
        let optionsEnd = args.count
        var escaped = false
        for item in items {
            var name = item.lastPathComponent
            if name.hasPrefix("-") || name.hasPrefix("@") { name = "./" + name; escaped = true }   // not an option or an @archive
            args += ["-C", item.deletingLastPathComponent().path, name]
        }
        // …and store those names without the "./" (symlink targets are left alone).
        if escaped { args.insert(contentsOf: ["-s", ",^\\./,,S"], at: optionsEnd) }

        let total = max(1, items.reduce(0) { $0 + entryCount($1) })
        var done = 0
        let result = try Tool.run(Tool.tar, args, onStderrLine: { line in
            guard line.hasPrefix("a ") else { return }
            done += 1
            progress(min(1, Double(done) / Double(total)))
        })
        guard result.status == 0, fm.fileExists(atPath: out.path) else {
            try? fm.removeItem(at: out)
            throw ConversionError.toolFailed("Couldn’t create \(out.lastPathComponent): \(Tool.reason(result.stderr))")
        }
        return out
    }

    /// How many archive entries an item makes (itself plus everything inside), for progress.
    private static func entryCount(_ url: URL) -> Int {
        guard Ext.isFolder(url),
              let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return 1 }
        var n = 1
        for case let file as URL in walker where file.lastPathComponent != ".DS_Store" { n += 1 }
        return n
    }


    /// One file → "name.ext.gz" (gzip keeps the name and date inside, so gunzip restores it exactly). A
    /// second copy is "name 2.ext.gz", which still unpacks to a file with the right extension anywhere.
    private static func gzipFile(_ url: URL) throws -> URL {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw ConversionError.unreadable(url.lastPathComponent) }
        let ext = url.pathExtension
        let out = ext.isEmpty
            ? unique(in: url.deletingLastPathComponent(), base: url.lastPathComponent, ext: "gz")
            : unique(in: url.deletingLastPathComponent(), base: url.deletingPathExtension().lastPathComponent, ext: ext + ".gz")
        let result = try Tool.run(Tool.gzip, ["-c", "-6", url.path], stdoutTo: out)
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError.toolFailed("Couldn’t compress \(url.lastPathComponent): \(Tool.reason(result.stderr))")
        }
        return out
    }

    // MARK: Extracting

    /// Unpacks into a new folder next to the archive and returns it. An archive holding a single folder
    /// unpacks as that folder (no "photos/photos"); anything else goes into a folder named after the archive.
    /// A compressed single file ("notes.txt.gz", "report.docx.gz") comes back as that file.
    /// Archives with absolute paths or ".." in them are refused before anything is written.
    static func extract(_ archive: URL, progress: @escaping (Double) -> Void) throws -> URL {
        let fm = FileManager.default
        let name = archive.lastPathComponent
        guard fm.isReadableFile(atPath: archive.path) else { throw ConversionError.unreadable(name) }
        guard ByteSize.of(archive) > 0 else { throw ConversionError.unsupported("\(name) is empty.") }
        if let codec = singleFileCodec(archive), starts(archive, with: codec.magic) {
            return try extractCompressedFile(archive, codec: codec, progress: progress)
        }
        return try unpack(archive, name: name, folder: archiveBaseName(name), into: archive.deletingLastPathComponent(),
                          quarantineFrom: archive, progress: progress)
    }

    /// Lists, checks and unpacks `file` (the archive itself, or a tarball just decompressed from it).
    /// `name` is what the user dropped, for messages; `folder` names the result when there's no single top folder.
    private static func unpack(_ file: URL, name: String, folder: String, into dir: URL, quarantineFrom original: URL,
                               progress: @escaping (Double) -> Void) throws -> URL {
        let fm = FileManager.default
        let isZip = ZipReader.isZip(file) || Ext.of(file) == "zip"
        // A ZIP's own directory answers what tool messages can't: whether anything is encrypted, and whether
        // names are in a legacy code page (no UTF-8 flag, not valid UTF-8) that only bsdtar can convert.
        let zipEntries = isZip ? try? ZipReader.directory(of: file) : nil
        if zipEntries?.contains(where: \.isEncrypted) == true { throw passwordProtected(name) }
        let legacy = zipEntries?.filter(\.hasLegacyName).map(\.rawName) ?? []
        let legacyNames = !legacy.isEmpty
        let readOptions = legacyNames ? ["--options", "zip:hdrcharset=\(legacyCharset(legacy))"] : []

        // A dummy passphrase stops bsdtar from prompting on a terminal when entries are encrypted.
        let listing = try Tool.run(Tool.tar, ["-t", "--passphrase", Tool.noPassphrase] + readOptions + ["-f", file.path])
        let listed = listing.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let entries = listed.map(decodeListedName)
        var known = [file.path, original.path, dir.path, name] + listed + entries
        guard listing.status == 0 else { throw failure(name, listing.stderr, known: known, mayBeEncrypted: zipEntries == nil) }
        if entries.isEmpty { throw ConversionError.unsupported("\(name) is empty.") }
        if let bad = entries.first(where: { !isSafe($0) }) {
            throw ConversionError.unsupported("\(name) wasn’t extracted: it would write outside its folder (“\(bad)”).")
        }
        let caseSensitive = (try? dir.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? false
        let renamed = try collisionRenames(isZip ? entries.filter { !$0.hasPrefix("__MACOSX/") } : entries,
                                           caseSensitive: caseSensitive, archive: name)
        let renames = renamePatterns(renamed)
        known += renamed.map(\.new)
        if let zipEntries, let twice = normalizationClash(zipEntries) {
            throw ConversionError.unsupported("\(name) wasn’t extracted: it holds “\(twice)” twice, with the accents written two different ways, and this disk can’t keep both.")
        }

        // Unpack into a hidden folder beside the archive (same volume, so the final move is a rename).
        let staging = try makeStaging(in: dir, for: name)
        defer { removeTree(staging) }
        known.append(staging.path)

        let total = Double(entries.count)
        var done = 0.0
        let count: (String) -> Void = { line in
            if line.hasPrefix("x ") || line.hasPrefix("copying ") {
                done += 1
                progress(min(0.99, done / total))
            }
        }
        let bsdtar = ["-x", "-v", "--passphrase", Tool.noPassphrase] + readOptions + renames.flatMap { ["-s", $0] }
            + ["-f", file.path, "-C", staging.path]
        var result: Tool.Result
        if isZip && renames.isEmpty && !legacyNames {
            result = try Tool.run(Tool.ditto, ["-x", "-k", "-V", file.path, staging.path], onStderrLine: count)
            if result.status != 0 && !(zipEntries == nil && isPasswordError(result.stderr, known: known)) {
                // Methods ditto doesn't know (Deflate64, LZMA, bzip2…): bsdtar may.
                try clear(staging)
                done = 0
                result = try Tool.run(Tool.tar, bsdtar, onStderrLine: count)
                try? fm.removeItem(at: staging.appendingPathComponent("__MACOSX"))
            }
        } else {
            result = try Tool.run(Tool.tar, bsdtar, onStderrLine: count)
            if isZip { try? fm.removeItem(at: staging.appendingPathComponent("__MACOSX")) }
        }
        guard result.status == 0 else { throw failure(name, result.stderr, known: known, mayBeEncrypted: zipEntries == nil) }
        Quarantine.propagate(from: original, to: staging)

        let top = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent != ".DS_Store" }
        let out: URL
        if top.count == 1, let only = top.first, Ext.isFolder(only),
           (try? only.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true {
            out = unique(in: dir, base: only.lastPathComponent, ext: "")
            try moveFolder(only, to: out)
        } else {
            out = unique(in: dir, base: folder, ext: "")
            try fm.moveItem(at: staging, to: out)
        }
        progress(1)
        return out
    }

    /// "notes.txt.gz" → "notes.txt" and "report.docx.gz" → "report.docx" next to the archive: whatever was
    /// compressed comes back as it was, even when it is itself a ZIP. Only a tarball behind a plain
    /// ".gz", ".bz2" or ".xz" name ("backup.gz") is unpacked further, like "backup.tar.gz".
    private static func extractCompressedFile(_ archive: URL, codec: Codec, progress: @escaping (Double) -> Void) throws -> URL {
        let dir = archive.deletingLastPathComponent()
        let staging = try makeStaging(in: dir, for: archive.lastPathComponent)
        defer { removeTree(staging) }
        let payload = staging.appendingPathComponent("payload")
        try decompress(archive, codec: codec, to: payload, progress: { progress($0 / 2) })
        if isTar(payload) {
            let name = archive.lastPathComponent
            return try unpack(payload, name: name, folder: archiveBaseName(name), into: dir, quarantineFrom: archive,
                              progress: { progress(0.5 + $0 / 2) })
        }
        var name = (archive.lastPathComponent as NSString).deletingPathExtension
        if codec == .gzip, (name as NSString).pathExtension.isEmpty, let stored = gzipStoredName(archive) { name = stored }
        if name.isEmpty || name.hasPrefix(".") { name = "Extracted" + name }
        let ext = (name as NSString).pathExtension
        let out = URL(fileURLWithPath: unique(in: dir, base: (name as NSString).deletingPathExtension, ext: ext).path)
        try FileManager.default.moveItem(at: payload, to: out)
        Quarantine.propagate(from: archive, to: out)
        progress(1)
        return out
    }

    /// No absolute paths, no ".." steps (with either slash). A leading "~" is an ordinary name (Office lock
    /// files are "~$Budget.xlsx"): neither ditto nor bsdtar expands it.
    static func isSafe(_ entry: String) -> Bool {
        if entry.hasPrefix("/") || entry.hasPrefix("\\") { return false }
        let parts = entry.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return !parts.contains("..")
    }

    /// The code page for ZIP names stored without the UTF-8 flag. Windows writes them in the OEM code page
    /// of the PC's language, so the one for this Mac's language is tried first and used when every name
    /// decodes in it; otherwise CP437, the ZIP default (which decodes anything).
    static func legacyCharset(_ names: [[UInt8]], languages: [String] = Locale.preferredLanguages) -> String {
        let lang = (languages.first ?? "en").lowercased()
        let pages: [(prefixes: [String], charset: String, encoding: CFStringEncodings)] = [
            (["ja"], "CP932", .dosJapanese), (["zh-hant", "zh-tw", "zh-hk", "zh-mo"], "CP950", .dosChineseTrad),
            (["zh"], "CP936", .dosChineseSimplif), (["ko"], "CP949", .dosKorean),
            (["ru", "uk", "be", "bg", "sr"], "CP866", .dosRussian), (["el"], "CP737", .dosGreek),
            (["tr"], "CP857", .dosTurkish), (["he"], "CP862", .dosHebrew),
        ]
        if let page = pages.first(where: { $0.prefixes.contains { lang == $0 || lang.hasPrefix($0 + "-") } }) {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(page.encoding.rawValue)))
            if names.allSatisfy({ String(bytes: $0, encoding: encoding) != nil }) { return page.charset }
        }
        return "CP437"
    }

    /// A name as `bsdtar -t` prints it, with its escapes undone: "\232bersicht.txt" is the byte 0x9A then
    /// "bersicht.txt" (a name in a legacy code page), not an absolute Windows path; "\\" is one backslash.
    static func decodeListedName(_ line: String) -> String {
        guard line.contains("\\") else { return line }
        let b = Array(line.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        func octal(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x37 }
        while i < b.count {
            guard b[i] == 0x5C, i + 1 < b.count else { out.append(b[i]); i += 1; continue }
            let c = b[i + 1]
            if i + 3 < b.count, octal(c), octal(b[i + 2]), octal(b[i + 3]) {
                out.append(UInt8(truncatingIfNeeded: Int(c - 0x30) << 6 | Int(b[i + 2] - 0x30) << 3 | Int(b[i + 3] - 0x30)))
                i += 4
                continue
            }
            let simple: [UInt8: UInt8] = [0x61: 0x07, 0x62: 0x08, 0x66: 0x0C, 0x6E: 0x0A, 0x72: 0x0D, 0x74: 0x09, 0x76: 0x0B, 0x5C: 0x5C]
            if let v = simple[c] { out.append(v); i += 2 } else { out.append(b[i]); i += 1 }
        }
        return String(bytes: out, encoding: .utf8) ?? String(decoding: out, as: UTF8.self)
    }

    /// bsdtar `-s` renames that keep entries whose names differ only in letter case or Unicode
    /// normalization ("xt_TCPMSS.c" / "xt_tcpmss.c", NFC / NFD "Café.txt"): this Mac's disk sees them as
    /// one name, so without them the later entry silently replaces the earlier one. The first keeps its
    /// name; the others become "name 2.ext", "name 3.ext"… Throws when a name can't be expressed as a rename.
    static func collisionRenames(_ entries: [String], caseSensitive: Bool, archive: String) throws -> [(old: String, new: String)] {
        func fold(_ s: String) -> String {
            let d = s.decomposedStringWithCanonicalMapping
            return caseSensitive ? d : d.folding(options: [.caseInsensitive], locale: nil)
        }
        func parts(_ s: String) -> [Substring] { s.split(separator: "/").filter { $0 != "." } }

        // Swift's String == treats NFC and NFD as equal; spellings are told apart by their bytes.
        func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
        func add(_ s: String, to list: inout [String]) { if !list.contains(where: { same($0, s) }) { list.append(s) } }
        var files: [String: [(stored: String, path: String)]] = [:]   // folded path → distinct file spellings, in order
        var folders: [String: [String]] = [:]                         // folded path → folder spellings (explicit or implied)
        var order: [String] = []
        var taken = Set<String>()                                     // every folded path in the archive
        for entry in entries {
            let comps = parts(entry)
            guard !comps.isEmpty else { continue }
            for depth in 1..<max(1, comps.count) {
                let folder = comps[0..<depth].joined(separator: "/")
                add(folder, to: &folders[fold(folder), default: []])
            }
            let path = comps.joined(separator: "/")
            let key = fold(path)
            taken.insert(key)
            if entry.hasSuffix("/") { add(path, to: &folders[key, default: []]); continue }
            if files[key] == nil { files[key] = []; order.append(key) }
            if !files[key]!.contains(where: { same($0.path, path) }) { files[key]!.append((entry, path)) }
        }
        for key in folders.keys { taken.insert(key) }

        var renames: [(old: String, new: String)] = []
        for key in order {
            guard let names = files[key] else { continue }
            let spellings = folders[key] ?? []
            // Beside a folder of another spelling every file moves aside (the folder keeps the name). A file
            // and a folder spelled exactly alike are not a case clash; bsdtar decides those as before
            // (for example refusing to write through a symlink).
            let clash = spellings.isEmpty ? Array(names.dropFirst())
                : names.filter { name in !spellings.contains { same($0, name.path) } }
            for old in clash {
                let comps = parts(old.path)
                let last = String(comps.last ?? "")
                let parent = comps.dropLast().joined(separator: "/")
                let base = (last as NSString).deletingPathExtension, ext = (last as NSString).pathExtension
                var n = 2, candidate = ""
                repeat {
                    let leaf = ext.isEmpty || base.isEmpty ? "\(last) \(n)" : "\(base) \(n).\(ext)"
                    candidate = parent.isEmpty ? leaf : parent + "/" + leaf
                    n += 1
                } while taken.contains(fold(candidate))
                taken.insert(fold(candidate))
                renames.append((old.stored, candidate))
            }
        }
        guard !renames.isEmpty else { return [] }

        let blocked = renames.first { r in
            r.old.unicodeScalars.contains { $0.value < 0x20 || $0 == "\u{FFFD}" || $0.value == 0x7F }
        }
        if renames.count > 1000 || blocked != nil {
            let example = blocked?.old ?? renames[0].old
            throw ConversionError.unsupported("\(archive) wasn’t extracted: some names, like “\(example)”, differ from others only in letter case or accents, and this disk can’t keep both.")
        }
        return renames
    }

    /// `-s` arguments for `collisionRenames`, each anchored to one whole stored name.
    static func renamePatterns(_ renames: [(old: String, new: String)]) -> [String] {
        // BRE specials in the pattern; "~" (the match) and "\" in the replacement.
        func pattern(_ s: String) -> String {
            var out = ""
            for ch in s { if "\\.[]*^$".contains(ch) { out.append("\\") }; out.append(ch) }
            return out
        }
        func replacement(_ s: String) -> String {
            var out = ""
            for ch in s { if ch == "\\" || ch == "~" { out.append("\\") }; out.append(ch) }
            return out
        }
        return renames.map { r in
            let old = pattern(r.old), new = replacement(r.new)
            let delimiter = [",", "|", "#", "!", ":", ";", "%", "=", "\u{1}"].first { !old.contains($0) && !new.contains($0) } ?? "\u{1}"
            return delimiter + "^" + old + "$" + delimiter + new + delimiter
        }
    }

    /// A name stored twice with different bytes but the same characters (NFC and NFD "Café.txt"). bsdtar on
    /// macOS shows both as one NFD name, so no rename can single one out; the disk would keep only the last.
    static func normalizationClash(_ entries: [ZipReader.Entry]) -> String? {
        var seen: [String: [UInt8]] = [:]   // String keys compare by canonical equivalence: NFC == NFD
        for e in entries where !e.isDirectory && !e.name.hasPrefix("__MACOSX/") {
            if let raw = seen[e.name] { if raw != e.rawName { return e.name.precomposedStringWithCanonicalMapping } } else { seen[e.name] = e.rawName }
        }
        return nil
    }

    /// The folder an archive unpacks into: "photos.tar.gz" → "photos", "data.tgz" → "data". A file type
    /// left over is dropped too ("report.pdf.zip" → "report", "Tool.app.zip" → "Tool"), so the folder
    /// doesn't look like a document or an app to Finder; version numbers stay ("v1.2.zip" → "v1.2").
    static func archiveBaseName(_ name: String) -> String {
        let lower = name.lowercased()
        var base = (name as NSString).deletingPathExtension
        for double in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.lzma", ".tar.z", ".tar.zst"] where lower.hasSuffix(double) {
            base = String(name.dropLast(double.count))
        }
        let inner = (base as NSString).pathExtension
        if !inner.isEmpty, let type = UTType(filenameExtension: inner), !type.isDynamic {
            base = (base as NSString).deletingPathExtension
        }
        while base.hasPrefix(".") { base.removeFirst() }
        return base.isEmpty ? "Archive" : base
    }

    private enum Codec {
        case gzip, bzip2, xz
        var magic: [UInt8] {
            switch self {
            case .gzip: return [0x1F, 0x8B]
            case .bzip2: return Array("BZh".utf8)
            case .xz: return XZ.magic
            }
        }
    }

    /// A compressed single file rather than a compressed tarball: "notes.txt.gz", not "notes.tar.gz" or ".tgz".
    private static func singleFileCodec(_ url: URL) -> Codec? {
        let lower = url.lastPathComponent.lowercased()
        if lower.contains(".tar.") { return nil }
        switch Ext.of(url) {
        case "gz": return .gzip
        case "bz2": return .bzip2
        case "xz": return .xz
        default: return nil
        }
    }

    private static func starts(_ url: URL, with magic: [UInt8]) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return [UInt8]((try? h.read(upToCount: magic.count)) ?? Data()) == magic
    }

    /// Decompresses `archive` into `out` (a new file).
    private static func decompress(_ archive: URL, codec: Codec, to out: URL, progress: @escaping (Double) -> Void) throws {
        switch codec {
        case .gzip, .bzip2:
            let result = try Tool.run(codec == .gzip ? Tool.gzip : Tool.bzip2, ["-d", "-c", archive.path], stdoutTo: out)
            guard result.status == 0 else { throw failure(archive.lastPathComponent, result.stderr) }
        case .xz:
            try XZ.decompress(archive, to: out, progress: progress)
        }
    }

    /// A tar header: "ustar" at offset 257, or (old v7 archives) a header checksum that adds up.
    static func isTar(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return isTarHeader([UInt8]((try? h.read(upToCount: 512)) ?? Data()))
    }

    static func isTarHeader(_ head: [UInt8]) -> Bool {
        guard head.count == 512, head[0] != 0 else { return false }
        if Array(head[257..<262]) == Array("ustar".utf8) { return true }
        let field = head[148..<156].drop { $0 == 0x20 }.prefix { $0 >= 0x30 && $0 <= 0x37 }
        guard !field.isEmpty, let stored = Int(String(decoding: field, as: UTF8.self), radix: 8) else { return false }
        var sum = 0
        for (i, byte) in head.enumerated() { sum += (148..<156).contains(i) ? 0x20 : Int(byte) }
        return sum == stored
    }

    /// The FNAME field of a gzip header, if present and a plain file name.
    private static func gzipStoredName(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = [UInt8]((try? h.read(upToCount: 4096)) ?? Data())
        guard head.count > 10, head[0] == 0x1F, head[1] == 0x8B, head[3] & 0x08 != 0 else { return nil }
        var i = 10
        if head[3] & 0x04 != 0 {   // FEXTRA
            guard head.count > 12 else { return nil }
            i += 2 + (Int(head[10]) | Int(head[11]) << 8)
        }
        guard i < head.count, let end = head[i...].firstIndex(of: 0) else { return nil }
        let name = String(decoding: head[i..<end], as: UTF8.self)
        let last = (name as NSString).lastPathComponent
        return last.isEmpty || last == "." || last == ".." || last.hasPrefix(".") ? nil : last
    }

    /// Whether a tool's error output is about a password. Progress lines ("x name", "copying file …") and
    /// the archive's own names and paths are not looked at, so a folder called "Password Manager Export"
    /// doesn't turn an ordinary failure into this message.
    static func isPasswordError(_ stderr: String, known: [String] = []) -> Bool {
        let keys = ["passphrase", "password", "encrypt"]
        let exact = Set(known)
        let names = known.filter { !$0.isEmpty }
        for raw in stderr.split(separator: "\n") {
            let line = String(raw)
            guard keys.contains(where: line.lowercased().contains) else { continue }
            if line.hasPrefix(">>>") || line.hasPrefix("copying ") || line.contains(" bytes for ") { continue }
            if line.hasPrefix("x "), exact.contains(String(line.dropFirst(2))) { continue }
            // What the tool says comes after the last name or path it quotes ("x name: message").
            var message = line[...]
            for n in names {
                var from = line.startIndex
                while from < line.endIndex, let r = line.range(of: n, range: from..<line.endIndex) {
                    let before: Character = r.lowerBound == line.startIndex ? " " : line[line.index(before: r.lowerBound)]
                    let endsName = r.upperBound == line.endIndex || line[r.upperBound] == ":"
                    if endsName, before == " " || before == "/", r.upperBound > message.startIndex { message = line[r.upperBound...] }
                    from = line.index(after: r.lowerBound)
                }
            }
            if keys.contains(where: message.lowercased().contains) { return true }
        }
        return false
    }

    private static func passwordProtected(_ name: String) -> ConversionError {
        .unsupported("\(name) is password-protected. YummyOrange can’t open protected archives.")
    }

    private static func failure(_ name: String, _ stderr: String, known: [String] = [], mayBeEncrypted: Bool = true) -> ConversionError {
        if mayBeEncrypted && isPasswordError(stderr, known: known) { return passwordProtected(name) }
        // bsdtar strips a leading "/" (hard-link targets too) and refuses "..", symlinked parents, absolute paths.
        if stderr.contains("through symlink") || stderr.contains("Path contains '..'") || stderr.contains("Removing leading '/'")
            || stderr.contains("Path is absolute") {
            return .unsupported("\(name) wasn’t extracted: it would write outside its folder.")
        }
        guard let reason = Tool.reasonLine(stderr) else { return .unsupported("\(name) is damaged or incomplete.") }
        let lower = reason.lowercased()
        if lower.contains("unrecognized archive format") {
            return .unsupported("\(name) isn’t an archive YummyOrange can open, or it’s damaged.")
        }
        if ["truncated", "unexpected end", "unexpectedly", "premature end", "crc error", "integrity", "damaged", "corrupt",
            "invalid compressed data"].contains(where: lower.contains) {
            return .unsupported("\(name) is damaged or incomplete.")
        }
        return .toolFailed("Couldn’t extract \(name): \(reason)")
    }

    // MARK: Staging folders

    private static func makeStaging(in dir: URL, for name: String) throws -> URL {
        let staging = dir.appendingPathComponent(".YummyOrange-extract-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false) } catch {
            throw ConversionError.unsupported("Couldn’t extract \(name): its folder can’t be written to.")
        }
        return staging
    }

    /// Gives the owner write access to every folder in `url` (read-only folders from an archive can't be
    /// emptied otherwise), without following symlinks.
    private static func makeWritable(_ url: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeDirectory else { return }
        let mode = (attrs[.posixPermissions] as? Int) ?? 0o755
        if mode & 0o700 != 0o700 { try? fm.setAttributes([.posixPermissions: mode | 0o700], ofItemAtPath: url.path) }
        for child in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] { makeWritable(url.appendingPathComponent(child)) }
    }

    /// Removes a staging folder completely, whatever modes the archive gave its contents.
    private static func removeTree(_ url: URL) {
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: url.path)) != nil else { return }
        if (try? fm.removeItem(at: url)) == nil {
            makeWritable(url)
            try? fm.removeItem(at: url)
        }
    }

    /// Moves a folder to a new parent. That rewrites the folder's ".." entry, which needs write access to
    /// the folder itself, so a read-only one (0555) is opened up for the move and given its mode back after.
    private static func moveFolder(_ folder: URL, to out: URL) throws {
        let fm = FileManager.default
        let mode = (try? fm.attributesOfItem(atPath: folder.path))?[.posixPermissions] as? Int
        let locked = mode.map { $0 & 0o200 == 0 } ?? false
        if locked, let mode { try fm.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: folder.path) }
        try fm.moveItem(at: folder, to: out)
        if locked, let mode { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: out.path) }
    }

    private static func clear(_ dir: URL) throws {
        makeWritable(dir)
        for item in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: item)
        }
    }

    /// "base.ext", then "base 2.ext", … in `dir`. An empty `ext` names a folder.
    static func unique(in dir: URL, base: String, ext: String) -> URL {
        func make(_ b: String) -> URL {
            ext.isEmpty ? dir.appendingPathComponent(b, isDirectory: true) : dir.appendingPathComponent("\(b).\(ext)")
        }
        var candidate = make(base)
        var n = 2
        // attributesOfItem doesn't follow symlinks, so a dangling link counts as taken too.
        while (try? FileManager.default.attributesOfItem(atPath: candidate.path)) != nil {
            candidate = make("\(base) \(n)")
            n += 1
        }
        return candidate
    }

    // MARK: Self-test

    #if DEBUG
    /// `--selftest archives`: makes a small tree, archives it three ways, unpacks each and compares; then
    /// the extraction edge cases (compressed documents, collisions, read-only folders, legacy names, XZ) and
    /// the ZIP reader's hardening checks.
    static func selfTest() -> String {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dropwheel-archives-\(UUID().uuidString)")
        defer { removeTree(root) }
        var failures: [String] = []
        do {
            let tree = root.appendingPathComponent("Tree", isDirectory: true)
            try fm.createDirectory(at: tree.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
            try fm.createDirectory(at: tree.appendingPathComponent("empty"), withIntermediateDirectories: true)
            try "hello\n".write(to: tree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "#!/bin/sh\necho hi\n".write(to: tree.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tree.appendingPathComponent("run.sh").path)
            try "x".write(to: tree.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
            try "x".write(to: tree.appendingPathComponent("sub/.DS_Store"), atomically: true, encoding: .utf8)
            try "Ünïcødé ✓\n".write(to: tree.appendingPathComponent("sub/deeper/Café ✓.txt"), atomically: true, encoding: .utf8)
            try fm.createSymbolicLink(atPath: tree.appendingPathComponent("link").path, withDestinationPath: "a.txt")

            for kind in [Kind.zip, .tar, .gzip] {
                let archive = try create(kind, from: [tree], progress: { _ in })
                let folder = try extract(archive, progress: { _ in })
                let expected = ["a.txt", "empty", "link", "run.sh", "sub", "sub/deeper", "sub/deeper/Café ✓.txt"]
                let found = (fm.enumerator(atPath: folder.path)?.allObjects as? [String] ?? [])
                    .map { $0.precomposedStringWithCanonicalMapping }.sorted()
                if found != expected { failures.append("\(kind): entries \(found)") }
                let mode = (try? fm.attributesOfItem(atPath: folder.appendingPathComponent("run.sh").path)[.posixPermissions]) as? Int
                if mode != 0o755 { failures.append("\(kind): run.sh mode \(String(mode ?? 0, radix: 8))") }
                if (try? fm.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("link").path)) != "a.txt" {
                    failures.append("\(kind): symlink lost")
                }
                if folder.lastPathComponent != "Tree 2" && folder.lastPathComponent != "Tree 3" && folder.lastPathComponent != "Tree 4" {
                    failures.append("\(kind): folder named \(folder.lastPathComponent)")
                }
            }
            let gz = try create(.gzip, from: [tree.appendingPathComponent("a.txt")], progress: { _ in })
            if gz.lastPathComponent != "a.txt.gz" { failures.append("gzip name \(gz.lastPathComponent)") }
            let gz2 = try create(.gzip, from: [tree.appendingPathComponent("a.txt")], progress: { _ in })
            if gz2.lastPathComponent != "a 2.txt.gz" { failures.append("second gzip name \(gz2.lastPathComponent)") }
            let back = try extract(gz, progress: { _ in })
            if back.lastPathComponent != "a 2.txt" || (try? String(contentsOf: back)) != "hello\n" {
                failures.append("gunzip gave \(back.lastPathComponent)")
            }
            let several = try create(.zip, from: [tree.appendingPathComponent("a.txt"), tree.appendingPathComponent("sub")],
                                     progress: { _ in })
            if several.lastPathComponent != "Archive.zip" { failures.append("several → \(several.lastPathComponent)") }
            for bad in ["../x", "/etc/passwd", "a/../../b", "..\\x"] where isSafe(bad) { failures.append("unsafe accepted: \(bad)") }
            for good in ["a/b", "..a/b", "a..b", "./a", "~$Budget.xlsx", "~backup/x"] where !isSafe(good) { failures.append("safe refused: \(good)") }
            if decodeListedName("\\232bersicht.txt") != String(decoding: [0x9A] + Array("bersicht.txt".utf8), as: UTF8.self)
                || decodeListedName("a\\\\b") != "a\\b" || decodeListedName("Caf\\303\\251") != "Café" {
                failures.append("listing escapes decoded wrong")
            }
            let names = ["photos.tar.gz": "photos", "data.tgz": "data", "report.pdf.zip": "report", "Tool.app.zip": "Tool",
                         "v1.2.3.zip": "v1.2.3", ".hidden.zip": "hidden", "notes.ZIP": "notes", "x.tar.bz2": "x"]
            for (archive, folder) in names where archiveBaseName(archive) != folder {
                failures.append("folder for \(archive): \(archiveBaseName(archive))")
            }
            failures += try edgeCaseFailures(root)
        } catch {
            failures.append("error: \(error.localizedDescription)")
        }
        failures += ZipReader.selfTestFailures()
        return failures.isEmpty ? "OK archives: zip, tar, tar.gz, gz round trips; extraction edge cases; ZIP reader hardening"
            : "FAIL archives:\n" + failures.joined(separator: "\n")
    }
    #endif

    #if DEBUG
    private static func edgeCaseFailures(_ root: URL) throws -> [String] {
        let fm = FileManager.default
        var failures: [String] = []
        let work = root.appendingPathComponent("edge", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        // A compressed document comes back as the document, not as its ZIP parts.
        let doc = work.appendingPathComponent("report.docx")
        let w = ZipWriter()
        try w.add("[Content_Types].xml", string: "<Types/>")
        try w.add("word/document.xml", string: String(repeating: "<w:p/>", count: 50))
        try w.write(to: doc)
        let docGz = try create(.gzip, from: [doc], progress: { _ in })
        let docBack = try extract(docGz, progress: { _ in })
        if docBack.lastPathComponent != "report 2.docx" || (try? Data(contentsOf: docBack)) != (try? Data(contentsOf: doc)) {
            failures.append("report.docx.gz gave \(docBack.lastPathComponent)")
        }

        // Names that differ only in letter case are all kept ("notes 2.txt"), a file beside a folder of the
        // same name too; a name stored twice as NFC and NFD is refused rather than half lost.
        let src = work.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        for (file, text) in [("one", "upper"), ("two", "lower"), ("three", "file"), ("four", "inside"), ("five", "café")] {
            try text.write(to: src.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let clash = work.appendingPathComponent("clash.tar")
        let made = try Tool.run(Tool.tar, ["-c", "-f", clash.path, "--no-mac-metadata", "-C", src.path,
                                           "-s", ",^one$,d/Notes.TXT,", "-s", ",^two$,d/notes.txt,",
                                           "-s", ",^three$,d/README,", "-s", ",^four$,d/readme/x,", "-s", ",^five$,d/Caf\u{E9}.txt,",
                                           "one", "two", "three", "four", "five"])
        if made.status == 0 {
            let out = try extract(clash, progress: { _ in })
            let kept = ((fm.enumerator(atPath: out.path)?.allObjects as? [String]) ?? []).map { $0.precomposedStringWithCanonicalMapping }
            let texts = Set(kept.compactMap { try? String(contentsOf: out.appendingPathComponent($0)) })
            if texts != ["upper", "lower", "file", "inside", "café"] { failures.append("collisions kept \(kept.sorted())") }
        } else { failures.append("couldn’t make clash.tar: \(Tool.reason(made.stderr))") }
        let twice = work.appendingPathComponent("twice.zip")
        try ZipReader.testArchive([.init(name: Array("Caf\u{E9}.txt".utf8), data: Data("nfc".utf8), method: 0),
                                   .init(name: Array("Cafe\u{301}.txt".utf8), data: Data("nfd".utf8), method: 0)]).write(to: twice)
        do {
            let out = try extract(twice, progress: { _ in })
            failures.append("NFC/NFD pair extracted as \(out.lastPathComponent)")
        } catch {
            if !error.localizedDescription.contains("Café.txt") { failures.append("NFC/NFD refusal: \(error.localizedDescription)") }
        }

        // A read-only top folder unpacks with its mode and leaves nothing hidden behind.
        let ro = work.appendingPathComponent("ro", isDirectory: true)
        try fm.createDirectory(at: ro.appendingPathComponent("ReadOnly"), withIntermediateDirectories: true)
        try "a\n".write(to: ro.appendingPathComponent("ReadOnly/a.txt"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.appendingPathComponent("ReadOnly").path)
        let roTar = try create(.tar, from: [ro.appendingPathComponent("ReadOnly")], progress: { _ in })
        let roOut = try extract(roTar, progress: { _ in })
        let roMode = (try? fm.attributesOfItem(atPath: roOut.path)[.posixPermissions]) as? Int
        if roMode != 0o555 || !fm.fileExists(atPath: roOut.appendingPathComponent("a.txt").path) {
            failures.append("read-only folder gave \(roOut.lastPathComponent) mode \(String(roMode ?? 0, radix: 8))")
        }
        if ((try? fm.contentsOfDirectory(atPath: ro.path)) ?? []).contains(where: { $0.hasPrefix(".YummyOrange-extract-") }) {
            failures.append("read-only folder left a staging copy")
        }

        // A CP437 name without the UTF-8 flag, and names starting with "~".
        let legacy = work.appendingPathComponent("Windows Export.zip")
        try ZipReader.testArchive([.init(name: [0x9A] + Array("bersicht.txt".utf8), data: Data("u\n".utf8), method: 0, flags: 0),
                                   .init(name: Array("~$Budget.xlsx".utf8), data: Data("x".utf8), method: 0, flags: 0)])
            .write(to: legacy)
        let legacyOut = try extract(legacy, progress: { _ in })
        let legacyNames = ((try? fm.contentsOfDirectory(atPath: legacyOut.path)) ?? []).map { $0.precomposedStringWithCanonicalMapping }.sorted()
        let cp437Here = legacyCharset([[0x9A] + Array("bersicht.txt".utf8)]) == "CP437"
        if legacyNames.count != 2 || !legacyNames.contains("~$Budget.xlsx") || (cp437Here && !legacyNames.contains("Übersicht.txt")) {
            failures.append("CP437 zip gave \(legacyNames)")
        }
        let sjis: [UInt8] = [0x83, 0x65, 0x83, 0x58, 0x83, 0x67, 0x2E, 0x74, 0x78, 0x74]   // テスト.txt
        if legacyCharset([sjis], languages: ["ja-JP"]) != "CP932" || legacyCharset([sjis], languages: ["en-US"]) != "CP437"
            || legacyCharset([Array("Caf".utf8) + [0x82, 0x2E, 0x74]], languages: ["ja"]) != "CP437" {
            failures.append("legacy code page guessed wrong")
        }

        // Two concatenated .xz streams decode in full.
        let chapters = (0..<2).map { Data(String(repeating: "chapter \($0)\n", count: 400).utf8) }
        var xz = Data()
        for part in chapters {
            guard let stream = XZ.compress(part) else { failures.append("couldn’t make an XZ stream"); break }
            xz.append(stream)
            xz.append(Data(count: 4))   // stream padding
        }
        let log = work.appendingPathComponent("log.txt.xz")
        try xz.write(to: log)
        let logOut = try extract(log, progress: { _ in })
        if (try? Data(contentsOf: logOut)) != chapters[0] + chapters[1] {
            failures.append("multi-stream xz gave \((try? Data(contentsOf: logOut))?.count ?? -1) bytes")
        }

        // Error wording.
        if Tool.reasonLine("tar: (null)\n") != nil { failures.append("“(null)” used as a reason") }
        if Tool.reasonLine("tar: Removing leading '/' from member names\nx h: Hard-link target 'a' does not exist.\n")?
            .hasPrefix("Hard-link target") != true { failures.append("warning used as a reason") }
        let progressOnly = ">>> Copying Export.zip\ncopying file 1 Password Manager Export/readme.txt\n"
            + "ditto: /x/Password Manager Export/vault.csv: Unknown compression type\n"
        if isPasswordError(progressOnly, known: ["Password Manager Export/vault.csv", "Password Manager Export/readme.txt"]) {
            failures.append("a folder named Password… read as a password error")
        }
        if !isPasswordError("x s.txt: Incorrect passphrase: Unknown error: -1\n", known: ["s.txt"]) {
            failures.append("a passphrase error missed")
        }
        return failures
    }
    #endif
}

// MARK: - Running tools

extension Archives {
    /// A command-line tool run with stdout optionally going straight to a file (for gzip -c) and stderr
    /// read line by line (bsdtar and ditto report each file there).
    enum Tool {
        static let tar = URL(fileURLWithPath: "/usr/bin/tar")
        static let gzip = URL(fileURLWithPath: "/usr/bin/gzip")
        static let bzip2 = URL(fileURLWithPath: "/usr/bin/bzip2")
        static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
        static let noPassphrase = "dropwheel-no-passphrase"

        struct Result {
            let status: Int32
            let stdout: String
            let stderr: String
        }

        static func run(_ tool: URL, _ args: [String], stdoutTo file: URL? = nil,
                        onStderrLine: ((String) -> Void)? = nil) throws -> Result {
            let process = Process()
            process.executableURL = tool
            process.arguments = args
            process.standardInput = FileHandle.nullDevice
            // bsdtar needs a UTF-8 locale to store non-ASCII names properly; apps don't get one by default.
            var env = ProcessInfo.processInfo.environment
            env["LC_ALL"] = "en_US.UTF-8"
            process.environment = env

            var outHandle: FileHandle?
            let outPipe = Pipe()
            if let file {
                guard FileManager.default.createFile(atPath: file.path, contents: nil),
                      let h = try? FileHandle(forWritingTo: file) else {
                    throw ConversionError.toolFailed("Couldn’t write \(file.lastPathComponent).")
                }
                outHandle = h
                process.standardOutput = h
            } else {
                process.standardOutput = outPipe
            }
            let errPipe = Pipe()
            process.standardError = errPipe

            let lock = NSLock()
            var outData = Data(), errData = Data(), lineBuffer = Data()
            if file == nil {
                outPipe.fileHandleForReading.readabilityHandler = { h in
                    let chunk = h.availableData
                    lock.lock(); outData.append(chunk); lock.unlock()
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                guard !chunk.isEmpty else { return }
                lock.lock()
                errData.append(chunk)
                lineBuffer.append(chunk)
                var lines: [String] = []
                while let nl = lineBuffer.firstIndex(of: 0x0A) {
                    lines.append(String(decoding: lineBuffer[lineBuffer.startIndex..<nl], as: UTF8.self))
                    lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
                }
                lock.unlock()
                if let onStderrLine { lines.forEach(onStderrLine) }
            }

            do { try process.run() } catch {
                try? outHandle?.close()
                throw ConversionError.missingTool(tool.lastPathComponent)
            }
            process.waitUntilExit()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            if file == nil { let rest = outPipe.fileHandleForReading.readDataToEndOfFile(); lock.lock(); outData.append(rest); lock.unlock() }
            let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); errData.append(restErr); lock.unlock()
            try? outHandle?.close()
            return Result(status: process.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
                          stderr: String(decoding: errData, as: UTF8.self))
        }

        /// The most useful line of a tool's error output, without the tool's own prefix or the
        /// per-file progress lines ("x name", "copying file …") that -v mixes in.
        static func reason(_ stderr: String) -> String {
            reasonLine(stderr) ?? "it stopped with an error."
        }

        /// Like `reason`, but nil when the tool gave nothing useful (no message, or libarchive's "(null)").
        /// Warnings that don't explain a failure ("Removing leading '/' from member names") are skipped.
        static func reasonLine(_ stderr: String) -> String? {
            for raw in stderr.split(separator: "\n") {
                var line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.contains("Error exit delayed") || line.hasPrefix(">>>") || line.hasPrefix("copying")
                    || line.contains(" bytes for ") || line.contains("Removing leading") { continue }
                if line.hasPrefix("x ") || line.hasPrefix("a ") {
                    // "x name: what went wrong" — keep the part after the name.
                    guard let colon = line.range(of: ": ") else { continue }
                    line = String(line[colon.upperBound...])
                }
                for prefix in ["tar: ", "ditto: ", "gzip: ", "bzip2: "] where line.hasPrefix(prefix) { line.removeFirst(prefix.count) }
                line = line.replacingOccurrences(of: ": Unknown error: -1", with: "")
                    .replacingOccurrences(of: ": Undefined error: 0", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line == "(null)" { continue }
                return line
            }
            return nil
        }
    }

    /// Files unpacked from a downloaded archive stay marked as downloaded (as Archive Utility does), so
    /// Gatekeeper still checks an app that came inside a ZIP. bsdtar doesn't do this by itself.
    enum Quarantine {
        static let name = "com.apple.quarantine"

        static func propagate(from archive: URL, to root: URL) {
            let size = getxattr(archive.path, name, nil, 0, 0, 0)
            guard size > 0 else { return }
            var value = [UInt8](repeating: 0, count: size)
            guard getxattr(archive.path, name, &value, size, 0, 0) == size else { return }
            func mark(_ path: String) { _ = setxattr(path, name, value, size, 0, XATTR_NOFOLLOW) }
            mark(root.path)
            guard Ext.isFolder(root), let walker = FileManager.default.enumerator(atPath: root.path) else { return }
            for case let rel as String in walker { mark(root.appendingPathComponent(rel).path) }
        }
    }

    /// .xz single files, decoded with the Compression framework (macOS has no xz command). A file may hold
    /// several streams one after another (with zero padding between them), as `xz` and `cat` make them;
    /// every one is decoded.
    enum XZ {
        static let magic: [UInt8] = [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]

        static func decompress(_ src: URL, to dst: URL, progress: @escaping (Double) -> Void) throws {
            let name = src.lastPathComponent
            guard let input = try? FileHandle(forReadingFrom: src) else { throw ConversionError.unreadable(name) }
            defer { try? input.close() }
            guard FileManager.default.createFile(atPath: dst.path, contents: nil), let output = try? FileHandle(forWritingTo: dst) else {
                throw ConversionError.toolFailed("Couldn’t write \(dst.lastPathComponent).")
            }
            defer { try? output.close() }
            let damaged = ConversionError.unsupported("\(name) is damaged or uses an XZ feature macOS can’t decode.")
            let total = max(1, ByteSize.of(src))
            let chunk = 1 << 20

            let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { stream.deallocate() }
            var open = false
            defer { if open { compression_stream_destroy(stream) } }
            let outBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
            defer { outBuffer.deallocate() }

            var pending = Data()   // read from the file, not yet decoded
            var eof = false
            var readSoFar = 0
            var streams = 0
            func fill(_ minimum: Int) {
                while pending.count < minimum && !eof {
                    let data = (try? input.read(upToCount: chunk)) ?? Data()
                    if data.isEmpty { eof = true } else { pending.append(data); readSoFar += data.count }
                }
            }

            while true {
                if !open {
                    // Between streams: zero padding, then another stream's magic or the end of the file.
                    fill(1)
                    while !pending.isEmpty, let first = pending.first, first == 0 {
                        if let nonzero = pending.firstIndex(where: { $0 != 0 }) {
                            pending.removeSubrange(pending.startIndex..<nonzero)
                        } else {
                            pending.removeAll()
                            fill(1)
                        }
                    }
                    if pending.isEmpty {
                        guard streams > 0 else { throw damaged }
                        return
                    }
                    fill(magic.count)
                    guard pending.count >= magic.count, Array(pending.prefix(magic.count)) == magic else {
                        if streams == 0 { throw damaged }
                        throw ConversionError.unsupported("\(name) has unexpected data after its end. It may be damaged.")
                    }
                    guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
                        throw ConversionError.toolFailed("Couldn’t start the XZ decoder.")
                    }
                    open = true
                    streams += 1
                }

                fill(1)
                let finalize = eof
                var status = COMPRESSION_STATUS_OK
                var produced = 0
                let used: Int = try pending.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                    stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(outBuffer)
                    stream.pointee.src_size = raw.count
                    repeat {
                        let before = stream.pointee.src_size
                        stream.pointee.dst_ptr = outBuffer
                        stream.pointee.dst_size = chunk
                        status = compression_stream_process(stream, finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                        guard status != COMPRESSION_STATUS_ERROR else { throw damaged }
                        let n = chunk - stream.pointee.dst_size
                        if n > 0 { output.write(Data(bytes: outBuffer, count: n)); produced += n }
                        if status == COMPRESSION_STATUS_END { break }
                        if n == 0 && stream.pointee.src_size == before { break }   // needs more input
                    } while stream.pointee.src_size > 0 || stream.pointee.dst_size == 0
                    return raw.count - stream.pointee.src_size
                }
                pending.removeSubrange(pending.startIndex..<(pending.startIndex + used))
                if status == COMPRESSION_STATUS_END {
                    compression_stream_destroy(stream)
                    open = false
                    continue
                }
                if used == 0 && produced == 0 {
                    // No progress: the decoder wants more than what's buffered, or the file ends mid-stream.
                    if finalize { throw ConversionError.unsupported("\(name) ends too soon. It may be incomplete.") }
                    fill(pending.count + 1)
                }
                progress(min(0.99, Double(readSoFar - pending.count) / Double(total)))
            }
        }

        /// One XZ stream (used by the self-test; the Compression framework writes the .xz container).
        static func compress(_ data: Data) -> Data? {
            let capacity = data.count + data.count / 2 + 4096
            var out = [UInt8](repeating: 0, count: capacity)
            let n = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                out.withUnsafeMutableBufferPointer { dst in
                    compression_encode_buffer(dst.baseAddress!, capacity, src.bindMemory(to: UInt8.self).baseAddress!,
                                              data.count, nil, COMPRESSION_LZMA)
                }
            }
            return n > 0 ? Data(out[0..<n]) : nil
        }
    }
}

private typealias ByteSize = MoreFormats.ByteSize
