import AppKit

// Extension points. Each feature lives in its own file as a `FeatureModule` that contributes
// petals (`WheelCommand`s) to the wheels, plus optional launch hooks, menu items, snapshots of
// its windows and self-tests. Registry lists the modules; AppDelegate and the command line read it.

/// Options a command collects before it runs: from `ask` in the app, from `--opt key=value` on the command line.
typealias ToolOptions = [String: String]

extension Dictionary where Key == String, Value == String {
    func string(_ key: String, _ fallback: String) -> String {
        guard let v = self[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return fallback }
        return v
    }
    func double(_ key: String, _ fallback: Double) -> Double {
        self[key].flatMap { Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) } ?? fallback
    }
    func int(_ key: String, _ fallback: Int) -> Int {
        guard let v = self[key].flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), v.isFinite, abs(v) < 1e15
        else { return fallback }
        return Int(v.rounded())
    }
    func bool(_ key: String, _ fallback: Bool) -> Bool {
        guard let v = self[key]?.lowercased() else { return fallback }
        return ["1", "true", "yes", "on"].contains(v) ? true : ["0", "false", "no", "off"].contains(v) ? false : fallback
    }
}

/// One petal on a wheel.
struct WheelCommand {
    let wheel: WheelMode
    /// Stable name for the command line (`--convert <id>` / `--tool <id>`). For conversions, the output extension.
    let id: String
    /// Petal label. Conversions use the format name ("DOCX"); tools that ask first end with "…".
    let title: String
    /// SF Symbol for tool and action petals; nil shows the title in bold (conversions).
    var symbol: String? = nil
    /// true: runs once with every file (merge, collage, archive). false: runs once per file.
    var combinesInputs = false
    /// Whether to show this petal for the dragged files. Keep it cheap: it runs while the wheel opens.
    let applies: ([URL]) -> Bool
    /// Main thread, before running: collect options (usually with `Ask.form`). nil = cancelled.
    var ask: (([URL]) -> ToolOptions?)? = nil
    /// Main thread, instead of `run`: open a window (editors, organizer, shelf). The window saves its own output
    /// and reports it with `JobRunner.report(saved:errors:)`.
    var present: (([URL]) -> Void)? = nil
    /// Background thread (the main thread in command-line mode). Must work from options alone, with defaults
    /// for every missing key, because the command line has no prompts. Returns the files it wrote.
    var run: (([URL], ToolOptions, @escaping (Double) -> Void) throws -> [URL])? = nil

    var plainTitle: String { title.replacingOccurrences(of: "…", with: "") }
}

protocol FeatureModule {
    static var commands: [WheelCommand] { get }
    /// Called once at launch, on the main thread (app mode only).
    static func appDidLaunch()
    /// Extra items for the menu-bar menu.
    static func menuItems() -> [NSMenuItem]
    /// A view to render for `--snapshot <id> <out.png> [files] [--opt k=v]`, so windows can be checked
    /// without the screen. Return nil when the id isn't yours.
    static func snapshot(_ id: String, files: [URL], options: ToolOptions) -> NSView?
    /// Headless checks for `--selftest <name>`. Return nil when the name isn't yours; a report starting
    /// with "FAIL" makes the command exit with status 1.
    static func selfTest(_ name: String) -> String?
}

extension FeatureModule {
    static func appDidLaunch() {}
    static func menuItems() -> [NSMenuItem] { [] }
    static func snapshot(_ id: String, files: [URL], options: ToolOptions) -> NSView? { nil }
    static func selfTest(_ name: String) -> String? { nil }
}

enum Registry {
    /// Order here is the order petals appear in, after the built-in ones.
    static let modules: [any FeatureModule.Type] = [
        ImageExtras.self, ImageEditors.self, ImageCropRedact.self, PDFExtras.self, MoreFormats.self,
        TextDocuments.self, EbooksAndPages.self, Presentations.self, Spreadsheets.self,
        AppShell.self, ShelfAndWelcome.self, HoldKey.self,
        MediaTrim.self, MediaFrameTools.self, MediaTools.self, PDFEditTool.self,
        LinkDownload.self,   // a YouTube, X, Instagram, TikTok or Threads link dragged from a browser → MP4, MP3, M4A, WAV
        ResultsShelf.self,   // no petals: where new files show (`--selftest results-shelf`, `--snapshot menu`)
        ClotheslineModule.self,   // no petals: new files hung under the notch (`--selftest clothesline`, `--snapshot clothesline`)
        MenuBarIcon.self,   // no petals: the menu-bar icon (`--snapshot menubar-icon`)
        FFmpegHelperModule.self,   // no petals: gets YummyOrange’s own ffmpeg on a Mac without one (`--selftest helper`)
        UpdaterModule.self,   // no petals: the built-in updater (`--selftest updater`)
    ]

    static var commands: [WheelCommand] { modules.flatMap { $0.commands } }

    static func commands(for wheel: WheelMode, files: [URL]) -> [WheelCommand] {
        guard !files.isEmpty else { return [] }
        return commands.filter { $0.wheel == wheel && $0.applies(files) }
    }

    /// Finds a command by id or title, preferring one that applies to the files.
    static func command(_ wheel: WheelMode, named name: String, files: [URL]) -> WheelCommand? {
        let named = commands.filter { $0.wheel == wheel && ($0.id == name || $0.title == name || $0.plainTitle == name) }
        return named.first { files.isEmpty || $0.applies(files) }
    }
}

// MARK: - Convert petals for mixed selections

extension Registry {
    /// How one file reaches a Convert id by itself.
    enum Route {
        /// A built-in format (`Converter.perform(.convert(_))`).
        case builtIn(OutputFormat)
        /// The module command at this position in `Registry.commands`.
        case command(Int)
    }

    /// The module petals of the Convert wheel, in wheel order, after the built-in `formats` the wheel already shows
    /// (`OutputFormat.targets(forAll:)`): first the petals for a mixed selection (`mixedConvertCommands`), then every
    /// command that applies to the whole selection. A selection that one command handles gets exactly what it got before.
    static func convertCommands(for files: [URL], besides formats: [OutputFormat]) -> [WheelCommand] {
        // A link dragged from a browser gets only the downloads (not ZIP and the other petals any file gets).
        if !files.isEmpty, files.allSatisfy(LinkFiles.isDragged) { return LinkDownload.commands.filter { $0.applies(files) } }
        let all = commands
        let whole = files.isEmpty ? [] : all.filter { $0.wheel == .convert && $0.applies(files) }
        return mixedConvertCommands(for: files, besides: formats, whole: whole, all: all) + whole
    }

    /// For files that different commands convert (DOCX + PPTX + XLSX + EPUB → PDF), one petal per output id that
    /// every file reaches by itself although nothing converts the selection as a whole. It runs each file through
    /// the built-in format or module command that converts that file (the per-file lookup `--convert` does).
    ///
    /// No petal for an id that is already offered (a built-in format in `formats`, or a command for the whole
    /// selection, by id or title), for an id some file can't reach (a file already in that format, say), or when one
    /// module command would convert every file yet declines them together. Only plain per-file commands take part:
    /// not ones that combine the files, open a window or ask for options first.
    static func mixedConvertCommands(for files: [URL], besides formats: [OutputFormat]) -> [WheelCommand] {
        let all = commands
        let whole = files.isEmpty ? [] : all.filter { $0.wheel == .convert && $0.applies(files) }
        return mixedConvertCommands(for: files, besides: formats, whole: whole, all: all)
    }

    private static func mixedConvertCommands(for files: [URL], besides formats: [OutputFormat],
                                             whole: [WheelCommand], all: [WheelCommand]) -> [WheelCommand] {
        guard files.count > 1 else { return [] }
        let takenIDs = Set(formats.map(\.rawValue)).union(whole.map(\.id))
        var takenTitles = Set(formats.map(\.label)).union(whole.map(\.title))
        var candidates: [String] = []
        var seen = Set<String>()
        for id in OutputFormat.allCases.map(\.rawValue) + all.filter(isPerFileConversion).map(\.id)
        where seen.insert(id).inserted && !takenIDs.contains(id) {
            candidates.append(id)
        }
        guard !candidates.isEmpty else { return [] }

        var builtInCache: [Int: [OutputFormat]] = [:]
        var found: [(key: Int, command: WheelCommand)] = []
        for id in candidates {
            var routes: [Route] = []
            for (n, file) in files.enumerated() {
                let hit = route(id, for: file, in: all) {
                    if let cached = builtInCache[n] { return cached }
                    let targets = builtInTargets(file)
                    builtInCache[n] = targets
                    return targets
                }
                guard let hit else { break }
                routes.append(hit)
            }
            guard routes.count == files.count else { continue }
            // One module command for every file that still declines them together: keep its decision.
            if case .command(let first)? = routes.first,
               routes.allSatisfy({ if case .command(let i) = $0 { return i == first } else { return false } }) { continue }
            let key = routes.map(sortKey).min() ?? 0
            let name = title(of: routes.min { sortKey($0) < sortKey($1) }!, in: all)
            guard takenTitles.insert(name).inserted else { continue }
            found.append((key, mixedCommand(id: id, title: name, all: all)))
        }
        return found.sorted { $0.key < $1.key }.map(\.command)
    }

    /// A Convert command that converts each file on its own, without combining, prompting or opening a window.
    private static func isPerFileConversion(_ c: WheelCommand) -> Bool {
        c.wheel == .convert && !c.combinesInputs && c.present == nil && c.ask == nil && c.run != nil
    }

    /// The built-in formats one file converts to (the same list `--convert` checks).
    private static func builtInTargets(_ file: URL) -> [OutputFormat] {
        OutputFormat.targets(for: FileKind.of(file), source: file.pathExtension)
    }

    /// How `file` alone reaches `id`: a built-in format first (as the wheel shows those first), else the first
    /// per-file module command, in petal order, that converts it.
    static func route(_ id: String, for file: URL, in all: [WheelCommand],
                      builtIn: () -> [OutputFormat]) -> Route? {
        if let format = OutputFormat(rawValue: id), builtIn().contains(format) { return .builtIn(format) }
        if let i = all.indices.first(where: { all[$0].id == id && isPerFileConversion(all[$0]) && all[$0].applies([file]) }) {
            return .command(i)
        }
        return nil
    }

    /// Built-in formats sort ahead of module commands, as on the wheel; each in its own order.
    private static func sortKey(_ route: Route) -> Int {
        switch route {
        case .builtIn(let f): return (OutputFormat.allCases.firstIndex(of: f) ?? 0) - OutputFormat.allCases.count
        case .command(let i): return i
        }
    }

    private static func title(of route: Route, in all: [WheelCommand]) -> String {
        switch route {
        case .builtIn(let f): return f.label
        case .command(let i): return all[i].title
        }
    }

    /// The petal itself. JobRunner and `--convert` call `run` once per file (on the job thread), and the file's route
    /// is looked up again then, among the commands `all` captured when the wheel opened.
    private static func mixedCommand(id: String, title: String, all: [WheelCommand]) -> WheelCommand {
        WheelCommand(wheel: .convert, id: id, title: title,
                     applies: { files in
                         !files.isEmpty && files.allSatisfy { f in route(id, for: f, in: all) { builtInTargets(f) } != nil }
                     },
                     run: { files, options, progress in
                         var outputs: [URL] = []
                         for (i, file) in files.enumerated() {
                             let part: (Double) -> Void = { progress((Double(i) + min(1, max(0, $0))) / Double(files.count)) }
                             switch route(id, for: file, in: all, builtIn: { builtInTargets(file) }) {
                             case .builtIn(let format)?:
                                 outputs += try Converter.perform(.convert(format), on: file, progress: part)
                             case .command(let n)?:
                                 guard let run = all[n].run else { throw ConversionError.unsupported("\(all[n].plainTitle) has nothing to run.") }
                                 outputs += try run([file], options, part)
                             case nil:
                                 throw ConversionError.unsupported("\(file.lastPathComponent) can’t be converted to \(title).")
                             }
                         }
                         return outputs
                     })
    }
}

/// Lower-cased file extensions shared by the modules, so two modules don't claim the same file differently.
enum Ext {
    static func of(_ url: URL) -> String { url.pathExtension.lowercased() }
    static func all(_ urls: [URL], in set: Set<String>) -> Bool { !urls.isEmpty && urls.allSatisfy { set.contains(of($0)) } }
    static func isFolder(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false }

    static let svg: Set<String> = ["svg", "svgz"]
    static let rawImages: Set<String> = ["dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
                                          "rw2", "pef", "srw", "erf", "3fr", "mos", "iiq", "rwl", "fff", "dcr", "kdc", "mrw", "raw"]
    /// Rich and plain text documents (TextDocuments). Not subtitles, not spreadsheets. Every one of them is read by
    /// DocumentIO.read and named by TextDocuments.format (.mdown and .mkd are Markdown, .xhtml is HTML).
    static let textDocuments: Set<String> = ["docx", "doc", "rtf", "rtfd", "html", "htm", "xhtml", "txt", "text", "md",
                                              "markdown", "mdown", "mkd", "odt", "textclipping", "webarchive"]
    static let ebooks: Set<String> = ["epub"]
    static let pages: Set<String> = ["pages"]
    static let presentations: Set<String> = ["pptx", "ppt", "ppsx", "pps", "pptm", "ppsm", "potx", "potm", "pot"]
    /// Workbooks the Spreadsheets module reads: Excel (also macro-enabled and templates), OpenDocument (also flat XML), text.
    static let spreadsheets: Set<String> = ["xlsx", "xlsm", "xltx", "xltm", "xls", "ods", "fods", "csv", "tsv"]
    static let subtitles: Set<String> = ["srt", "vtt"]
    static let archives: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "rar", "7z"]
}

// MARK: - Prompts

/// A small options form shown in an alert. Main thread only.
enum Ask {
    enum Field {
        case text(key: String, label: String, value: String = "", placeholder: String = "")
        case number(key: String, label: String, value: Double, unit: String = "")
        case choice(key: String, label: String, options: [String], selected: String)
        case toggle(key: String, label: String, on: Bool)
        case color(key: String, label: String, hex: String)
    }

    /// Returns the values keyed by field key, or nil when cancelled.
    static func form(title: String, message: String = "", fields: [Field], button: String = "OK") -> ToolOptions? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        var readers: [(String, () -> String)] = []
        var firstField: NSView?
        for field in fields {
            switch field {
            case let .text(key, label, value, placeholder):
                let tf = NSTextField(string: value)
                tf.placeholderString = placeholder
                tf.widthAnchor.constraint(equalToConstant: 200).isActive = true
                grid.addRow(with: [NSTextField(labelWithString: label), tf])
                readers.append((key, { tf.stringValue }))
                firstField = firstField ?? tf
            case let .number(key, label, value, unit):
                let tf = NSTextField(string: formatNumber(value))
                tf.alignment = .right
                tf.widthAnchor.constraint(equalToConstant: 90).isActive = true
                let row = NSStackView(views: [tf, NSTextField(labelWithString: unit)])
                row.spacing = 6
                grid.addRow(with: [NSTextField(labelWithString: label), row])
                readers.append((key, { tf.stringValue }))
                firstField = firstField ?? tf
            case let .choice(key, label, options, selected):
                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.addItems(withTitles: options)
                popup.selectItem(withTitle: selected)
                grid.addRow(with: [NSTextField(labelWithString: label), popup])
                readers.append((key, { popup.titleOfSelectedItem ?? selected }))
            case let .toggle(key, label, on):
                let box = NSButton(checkboxWithTitle: label, target: nil, action: nil)
                box.state = on ? .on : .off
                grid.addRow(with: [NSGridCell.emptyContentView, box])
                readers.append((key, { box.state == .on ? "true" : "false" }))
            case let .color(key, label, hex):
                let well = NSColorWell(frame: CGRect(x: 0, y: 0, width: 44, height: 24))
                well.color = NSColor(hex: hex) ?? .white
                well.widthAnchor.constraint(equalToConstant: 44).isActive = true
                grid.addRow(with: [NSTextField(labelWithString: label), well])
                readers.append((key, { well.color.hexString }))
            }
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.layoutSubtreeIfNeeded()
        grid.frame = CGRect(origin: .zero, size: grid.fittingSize)
        alert.accessoryView = grid
        if let firstField { alert.window.initialFirstResponder = firstField }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Dictionary(readers.map { ($0.0, $0.1()) }, uniquingKeysWith: { a, _ in a })
    }

    static func formatNumber(_ v: Double) -> String {
        v.isFinite && abs(v) < 1e15 && v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }
}

extension NSColor {
    /// "#RRGGBB" or "#RRGGBBAA".
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let a = s.count == 8 ? CGFloat(v & 0xFF) / 255 : 1
        let rgb = s.count == 8 ? v >> 8 : v
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: a)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded()), a = Int((c.alphaComponent * 255).rounded())
        return a == 255 ? String(format: "#%02X%02X%02X", r, g, b) : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}

// MARK: - Main-thread work

/// For APIs that need the main thread or a running run loop (WebKit, HTML import, printing).
/// Works from the job queue (the app's run loop keeps going) and in command-line mode, where the
/// caller already is the main thread and the run loop has to be spun by hand.
///
/// The main dispatch queue runs one block at a time: while code runs inside a `DispatchQueue.main.async`
/// block, no other main-queue block (WebKit's callbacks, `asyncAfter`) can run, however long the run loop
/// is spun. So main-thread code that may wait (`wait`, modal prompts, editors that load SVG) is started with
/// `MainThread.async`, from the run loop, never from a main-queue block.
enum MainThread {
    static func sync<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }

    /// Runs `block` on the main thread on a later turn of the main run loop (in every common mode, so also
    /// while a menu, a drag or a modal prompt runs the loop). Unlike `DispatchQueue.main.async`, the block
    /// isn't a main-queue block, so it may wait on main-thread work (`wait`) or run a modal prompt while the
    /// main queue keeps draining.
    static func async(_ block: @escaping () -> Void) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(main)
    }

    /// How long `wait` on the main thread gives the main dispatch queue to show it is draining. When it isn't
    /// (the caller is inside a `DispatchQueue.main` block), the work's callbacks can never arrive, so `wait`
    /// fails at once instead of freezing the app until the timeout.
    static let blockedQueueGrace: TimeInterval = 1.0

    static let blockedQueueMessage = "YummyOrange’s main thread was busy with another task, so this step couldn’t run. Try again."

    /// Starts `work` on the main thread and waits until it calls `finish` (once).
    static func wait<T>(timeout: TimeInterval = 180,
                        _ work: @escaping (_ finish: @escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
        let box = ResultBox<T>()
        if Thread.isMainThread {
            // A probe block shows whether nested turns of the run loop drain the main queue here.
            let probe = ResultBox<Bool>()
            DispatchQueue.main.async { probe.result = .success(true) }
            work { r in if box.result == nil { box.result = r } }
            let start = Date()
            let deadline = start.addingTimeInterval(timeout)
            while box.result == nil && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
                if box.result == nil, probe.result == nil, Date().timeIntervalSince(start) >= blockedQueueGrace {
                    throw ConversionError.toolFailed(blockedQueueMessage)
                }
            }
        } else {
            let done = DispatchSemaphore(value: 0)
            // From the run loop rather than the main queue, so the work starts even while the main thread sits in
            // a nested loop, and isn't itself a main-queue block that would hold up the callbacks it waits for.
            MainThread.async {
                work { r in
                    guard box.result == nil else { return }
                    box.result = r
                    done.signal()
                }
            }
            _ = done.wait(timeout: .now() + timeout)
        }
        guard let result = box.result else { throw ConversionError.toolFailed("Timed out after \(Int(timeout)) s.") }
        return try result.get()
    }
}

private final class ResultBox<T> { var result: Result<T, Error>? }

// MARK: - Snapshots

enum Snapshot {
    /// Renders a view offscreen to PNG (used by `--snapshot`). Views with a zero frame get their fitting size.
    static func writePNG(_ view: NSView, to out: URL, dark: Bool = false) throws {
        if view.frame.size == .zero { view.setFrameSize(view.fittingSize) }
        if view.frame.size == .zero { view.setFrameSize(CGSize(width: 600, height: 400)) }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: view.frame.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))   // let SwiftUI and layers settle
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw ConversionError.toolFailed("Couldn’t render the view.")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw ConversionError.toolFailed("Couldn’t encode the snapshot.")
        }
        try png.write(to: out)
    }
}
