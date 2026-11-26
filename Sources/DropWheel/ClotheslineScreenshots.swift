import AppKit
import Darwin

// A copied screenshot hangs on the Clothesline (Settings › General › Hang copied screenshots, on by default, while
// Show new files is On the Clothesline), once: one screenshot is one card. YummyOrange takes no screenshots of its own,
// and a screenshot macOS only saves to a file hangs nothing. Copying one does: ⌘C in macOS's floating thumbnail or its
// Markup window, or a screenshot taken with Control held (or with the Screenshot app set to Clipboard).
//
// A cheap poll of the general pasteboard's change count notices it. Only when the count changes while macOS's
// screenshot helper (com.apple.screencaptureui) runs, or has just quit, is the image read: the first image of each
// helper session, never one identical to the last one saved. It is saved as a PNG named the way macOS names
// screenshots, in Pictures › Clothesline, and hung, flying up from the pointer. The clipboard is left as it was.
//
// Turned off (or with another place for new files), nothing watches: the poll timer is invalidated and the helper is
// no longer observed.

// MARK: - The mark

/// macOS's screen-capture mark on a file: the extended attribute com.apple.metadata:kMDItemIsScreenCapture, which
/// screencapture sets on screenshots and screen recordings.
enum ScreenshotMetadata {
    static let attribute = "com.apple.metadata:kMDItemIsScreenCapture"

    /// Marks a file the way macOS marks its screenshots (Spotlight then finds it with them). `screencapture` stores the
    /// mark as a binary property list: the bytes "bplist00" 09 … (09 is true, 08 false), as read from a screenshot on
    /// this Mac with `xattr -px`.
    @discardableResult
    static func mark(_ url: URL, _ value: Bool = true) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) else { return false }
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return data.withUnsafeBytes { setxattr(path, attribute, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) } == 0
        }
    }
}

// MARK: - How macOS names them

enum ScreenshotNaming {
    /// macOS's own pattern, in English.
    static let englishPrefix = "Screenshot", englishPattern = "%@ %@ at %@"

    /// The name macOS gives a screenshot taken at `date`: "Screenshot 2026-11-24 at 10.31.07.png". The date is always
    /// year-month-day; the time is in the locale's own format with dots for colons ("10.31.07 AM" where the clock is
    /// 12-hour). `prefix` and `pattern` are macOS's words for the user's language (systemWords).
    static func fileName(date: Date, locale: Locale, timeZone: TimeZone, prefix: String = englishPrefix,
                         pattern: String = englishPattern, ext: String = "png") -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = Calendar(identifier: .gregorian)
        day.timeZone = timeZone
        day.dateFormat = "yyyy-MM-dd"
        let clock = DateFormatter()
        clock.locale = locale
        clock.timeZone = timeZone
        clock.setLocalizedDateFormatFromTemplate("jms")
        let time = clock.string(from: date).replacingOccurrences(of: ":", with: ".")
        let base = fill(pattern, [prefix, day.string(from: date), time]) ?? fill(englishPattern, [prefix, day.string(from: date), time])!
        // A custom name could hold a slash, which a file name can't.
        return "\(base.replacingOccurrences(of: "/", with: "-")).\(ext)"
    }

    /// "%@ %@ at %@" (or "%1$@ %2$@ um %3$@") with the values in their places; nil unless every place is filled.
    static func fill(_ pattern: String, _ values: [String]) -> String? {
        var p = pattern
        var positional = false
        for (i, v) in values.enumerated() where p.contains("%\(i + 1)$@") {
            p = p.replacingOccurrences(of: "%\(i + 1)$@", with: v)
            positional = true
        }
        if positional { return p.contains("%@") ? nil : p }
        let parts = p.components(separatedBy: "%@")
        guard parts.count == values.count + 1 else { return nil }
        return parts.enumerated().map { $0.element + ($0.offset < values.count ? values[$0.offset] : "") }.joined()
    }

    static let helperPath = "/System/Library/CoreServices/screencaptureui.app"

    /// macOS's words for the user's language: the `com.apple.screencapture name` preference when set (a custom name),
    /// else "Screenshot" and "%@ %@ at %@" from the screenshot helper's own strings; English when those can't be read.
    static func systemWords() -> (prefix: String, pattern: String) {
        let words = helperWords(languages: Locale.preferredLanguages)
        let custom = customName()?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (custom.flatMap { $0.isEmpty ? nil : $0 } ?? words.prefix, words.pattern)
    }

    /// The custom name set for screenshots (`com.apple.screencapture name`), read fresh; nil when there is none.
    static func customName() -> String? {
        let domain = "com.apple.screencapture" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("name" as CFString, domain) as? String
    }

    /// The helper's words in the localization it has that best fits `languages` (the user's, in order). YummyOrange
    /// itself is English only, so the helper's bundle would answer in English: the localization is chosen here. The
    /// helper keeps its strings in one Localizable.loctable (a property list of localizations); older systems had a
    /// Localizable.strings in each .lproj folder.
    static func helperWords(languages: [String], helperPath: String = helperPath) -> (prefix: String, pattern: String) {
        let english = (englishPrefix, englishPattern)
        guard let helper = Bundle(path: helperPath) else { return english }
        func pick(_ available: [String]) -> String? {
            Bundle.preferredLocalizations(from: available, forPreferences: languages).first
        }
        if let url = helper.url(forResource: "Localizable", withExtension: "loctable"), let data = try? Data(contentsOf: url),
           let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            // (Besides the localizations it holds a little metadata, under keys that aren't languages.)
            let languages = table.compactMap { $0.value is [String: Any] ? $0.key : nil }
            guard let lang = pick(languages), let strings = table[lang] as? [String: Any] else { return english }
            return (strings[englishPrefix] as? String ?? englishPrefix, strings[englishPattern] as? String ?? englishPattern)
        }
        guard let lang = pick(helper.localizations), let path = helper.path(forResource: lang, ofType: "lproj"),
              let local = Bundle(path: path) else { return english }
        return (local.localizedString(forKey: englishPrefix, value: englishPrefix, table: "Localizable"),
                local.localizedString(forKey: englishPattern, value: englishPattern, table: "Localizable"))
    }

    /// `name` in `folder`, or "name 2.png", "name 3.png", … when that is taken.
    static func uniqueURL(in folder: URL, name: String, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let first = folder.appendingPathComponent(name)
        guard exists(first) else { return first }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let next = folder.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            if !exists(next) { return next }
            n += 1
        }
    }
}

// MARK: - Clipboard screenshots

/// What the clipboard watcher needs of a pasteboard (the general one in the app; a named one in tests, never the real
/// clipboard).
protocol ScreenshotPasteboard: AnyObject {
    var changeCount: Int { get }
    var types: [NSPasteboard.PasteboardType]? { get }
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
    /// The user set YummyOrange to Deny in System Settings' paste-from-other-apps list (macOS 15.4 and later): reading
    /// would only fail, so it isn't tried.
    var deniesReading: Bool { get }
}

final class PasteboardSource: ScreenshotPasteboard {
    let pasteboard: NSPasteboard
    init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
    var changeCount: Int { pasteboard.changeCount }
    var types: [NSPasteboard.PasteboardType]? { pasteboard.types }
    func data(forType type: NSPasteboard.PasteboardType) -> Data? { pasteboard.data(forType: type) }
    var deniesReading: Bool {
        if #available(macOS 15.4, *) { return Self.denies(pasteboard.accessBehavior) }
        return false
    }

    /// Only Deny stops reading; Ask (the prompt comes in context), Allow and the default all read.
    @available(macOS 15.4, *)
    static func denies(_ behavior: NSPasteboard.AccessBehavior) -> Bool { behavior == .alwaysDeny }
}

/// Notices screenshots copied to the clipboard. Every 0.1 s it compares the pasteboard's change count (a number; the
/// contents are not touched). When the count changed while macOS's screenshot helper is active, and only then, it
/// reads the image. One screenshot is one image: only the first image of a helper session counts (pressing ⌘C again
/// adds nothing), and an image identical to the last one saved isn't saved again. Recent macOS asks once before
/// YummyOrange may paste from other apps, so the prompt appears right after the first copied screenshot, in context. The
/// image is saved as a PNG in `folder` under macOS's screenshot name and marked as a screenshot; the clipboard itself is
/// left exactly as it was, so ⌘V still pastes the image.
final class ScreenshotClipboardWatcher {
    let pasteboard: ScreenshotPasteboard
    let folder: URL
    /// Whether macOS's screenshot helper runs or has just quit (ScreenshotHelperMonitor).
    var isHelperActive: () -> Bool
    var onScreenshot: ((URL) -> Void)?
    var now: () -> Date = Date.init
    var locale: Locale = .autoupdatingCurrent
    var timeZone: TimeZone = .autoupdatingCurrent
    var words: () -> (prefix: String, pattern: String) = { ScreenshotNaming.systemWords() }
    var usesTimers = true
    /// Reading can wait on the system's paste prompt, so it runs off the main thread; tests run it inline.
    var readsInline = false
    /// Called when a read comes back empty and no more are tried (the Settings caption says so).
    var onDeclined: (() -> Void)?

    static let interval = 0.1
    /// An image was already taken in this helper session: later changes in it are copies, not screenshots.
    private(set) var sessionTaken = false
    /// The last PNG saved (an identical image copied again isn't saved twice).
    private var lastSaved: Data?

    /// macOS's screenshot helper started: the next image is a new screenshot.
    func newSession() { sessionTaken = false }

    private var lastCount: Int
    private var timer: Timer?
    /// A read in the screenshot case came back empty although the clipboard said it held an image: the user declined
    /// the system's prompt (or the read failed). No more reads until the setting is turned off and on again, so the
    /// prompt doesn't come back after every screenshot.
    private(set) var declined = false
    private(set) var isWatching = false
    /// Whether the 0.1 s poll is scheduled.
    var isPolling: Bool { timer?.isValid ?? false }
    /// Changes whenever the watcher starts or stops: a read that began before is dropped (not saved, not hung), since
    /// the setting may have been turned off while the paste prompt was up.
    private var generation = 0
    private let generationLock = NSLock()
    private func isCurrent(_ g: Int) -> Bool {
        generationLock.lock(); defer { generationLock.unlock() }
        return g == generation
    }
    private func nextGeneration() -> Int {
        generationLock.lock(); defer { generationLock.unlock() }
        generation += 1
        return generation
    }

    init(pasteboard: ScreenshotPasteboard, folder: URL, isHelperActive: @escaping () -> Bool) {
        self.pasteboard = pasteboard
        self.folder = folder
        self.isHelperActive = isHelperActive
        lastCount = pasteboard.changeCount
    }

    deinit { timer?.invalidate() }

    func start() {
        lastCount = pasteboard.changeCount
        isWatching = true
        _ = nextGeneration()
        guard usesTimers, timer == nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isWatching = false
        _ = nextGeneration()
    }

    /// One look at the change count.
    func poll() {
        guard isWatching else { return }
        let count = pasteboard.changeCount
        guard count != lastCount else { return }
        lastCount = count
        // Not a screenshot (an image copied in any app while the helper is idle): never read.
        guard isHelperActive() else { sessionTaken = false; return }
        guard !declined, !pasteboard.deniesReading else { return }
        // One image per screenshot: later ones in the same helper session are copies of it (⌘C pressed again).
        guard !sessionTaken else { return }
        guard let types = pasteboard.types, let type = Self.imageType(types) else { return }
        sessionTaken = true
        let taken = now()
        let words = self.words()
        let gen = nextGeneration()
        let work = { [weak self] in
            guard let self else { return }
            let data = self.pasteboard.data(forType: type)
            // Read the moment it changed: something copied in between would be another app's.
            let current = self.pasteboard.changeCount == count
            // Turned off (or another place chosen for new files) while the read waited: nothing is saved.
            let wanted = current && self.isCurrent(gen)
            let png = wanted ? data.flatMap { Self.pngData($0, type: type) } : nil
            let fresh = png.map { $0 != self.lastSaved } ?? false
            let saved = fresh ? png.flatMap { try? self.save($0, taken: taken, words: words) } : nil
            if saved != nil { self.lastSaved = png }
            let finish = {
                guard self.isCurrent(gen) else { return }
                if data == nil && current && !self.declined { self.declined = true; self.onDeclined?() }
                if let saved { self.onScreenshot?(saved) }
            }
            if self.readsInline { finish() } else { DispatchQueue.main.async(execute: finish) }
        }
        if readsInline { work() } else { DispatchQueue.global(qos: .userInitiated).async(execute: work) }
    }

    /// The image type a screenshot puts on the clipboard (PNG, or TIFF), or nil for anything else: a file, a link, a
    /// web page, text, a PDF, an item from another device (Universal Clipboard) or one marked transient or concealed.
    static func imageType(_ types: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType? {
        let others: Set<String> = ["public.file-url", "public.url", "public.html", "public.rtf", "public.utf8-plain-text",
                                   "com.adobe.pdf", "com.apple.is-remote-clipboard", "org.nspasteboard.TransientType",
                                   "org.nspasteboard.ConcealedType"]
        if types.contains(where: { others.contains($0.rawValue) }) { return nil }
        if types.contains(.png) { return .png }
        if types.contains(.tiff) { return .tiff }
        return nil
    }

    /// PNG bytes for the clipboard's image (PNG as it is; TIFF converted).
    static func pngData(_ data: Data, type: NSPasteboard.PasteboardType) -> Data? {
        if type == .png, data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    /// Writes the PNG under macOS's screenshot name (atomically, so it never appears half-written) and marks it.
    func save(_ png: Data, taken: Date, words: (prefix: String, pattern: String)) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = ScreenshotNaming.fileName(date: taken, locale: locale, timeZone: timeZone, prefix: words.prefix, pattern: words.pattern)
        let url = ScreenshotNaming.uniqueURL(in: folder, name: name)
        try png.write(to: url, options: .atomic)
        ScreenshotMetadata.mark(url)
        return url
    }
}

// MARK: - macOS's screenshot helper

/// Whether macOS's screenshot helper (com.apple.screencaptureui) is at work. On this Mac it isn't running while idle
/// and starts for each screenshot (it draws the selection, the floating thumbnail and the Screenshot app's toolbar).
/// Launches and quits come from the running-applications list (key-value observing, no polling); a helper that quit
/// less than 2 s ago still counts, so a clipboard write it made just before quitting is still recognised.
final class ScreenshotHelperMonitor {
    static let bundleID = "com.apple.screencaptureui"
    static let grace = 2.0

    var isRunning: () -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: ScreenshotHelperMonitor.bundleID).isEmpty }
    var now: () -> Double = { CACurrentMediaTime() }
    /// Called when the helper starts (a new screenshot) or quits.
    var onChange: ((_ launched: Bool) -> Void)?
    private(set) var lastSeen: Double?
    private var observation: NSKeyValueObservation?
    var isObserving: Bool { observation != nil }

    func start() {
        guard observation == nil else { return }
        observation = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { [weak self] _, change in
            let ids = { (apps: [NSRunningApplication]?) in (apps ?? []).contains { $0.bundleIdentifier == ScreenshotHelperMonitor.bundleID } }
            let launched = ids(change.newValue), quit = ids(change.oldValue)
            guard launched || quit else { return }
            let note: () -> Void = { self?.helperChanged(launched: launched) }
            if Thread.isMainThread { note() } else { DispatchQueue.main.async(execute: note) }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        lastSeen = nil
    }

    func helperChanged(launched: Bool) {
        lastSeen = now()
        onChange?(launched)
    }

    /// The helper runs, or quit (or was last seen) less than 2 s ago.
    var isActive: Bool {
        if isRunning() { lastSeen = now(); return true }
        return lastSeen.map { now() - $0 <= Self.grace } ?? false
    }
}

// MARK: - The switch

/// Runs the clipboard watcher while Hang copied screenshots is on and new files go to the Clothesline, and hangs what
/// it finds.
final class ClotheslineScreenshots {
    static let shared = ClotheslineScreenshots()
    /// Posted when reading clipboard screenshots stops being possible (the paste prompt declined), for the caption in
    /// Settings.
    static let clipboardAccessDidChange = Notification.Name("ClotheslineScreenshots.clipboardAccessDidChange")

    /// Whether clipboard screenshots can be read: yes, no because the paste prompt was declined (until the switch is
    /// turned off and on), or no because YummyOrange is set to Deny in System Settings.
    enum ClipboardAccess: Equatable { case allowed, declined, denied }

    var isEnabled: () -> Bool = { Settings.screenshotsHaveAPlace && Settings.hangScreenshots }
    /// The pasteboard to watch (the real clipboard only in the app; tests pass a named one).
    var makePasteboard: () -> ScreenshotPasteboard = { PasteboardSource(.general) }
    /// Where clipboard screenshots are saved.
    var clipboardFolder: () -> URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Clothesline", isDirectory: true)
    }
    /// Hangs a screenshot, flying up from a point in global screen coordinates (the pointer); On a Shelf it goes on
    /// your shelf instead, quietly (it is there when the shelf is open or next opens).
    var hang: (URL, CGPoint) -> Void = { url, point in
        if Settings.resultsDestination == .shelf { ShelfManager.shared.addToMine([url], show: false) }
        else { Clothesline.shared.hangScreenshot(url, from: point) }
    }
    /// The line's files (a file already on it isn't hung again); On a Shelf, your shelf's.
    var lineFiles: () -> [URL] = {
        Settings.resultsDestination == .shelf ? ShelfManager.shared.savedFiles : Clothesline.shared.files
    }
    var pointer: () -> CGPoint = { NSEvent.mouseLocation }
    var now: () -> Date = Date.init
    /// Tests: no timers, no key-value observing, inline reads.
    var live = true
    let helper = ScreenshotHelperMonitor()

    private(set) var clipboardWatcher: ScreenshotClipboardWatcher?
    private var settingsObserver: NSObjectProtocol?
    /// Files hung this session (device and inode), so no file is hung twice.
    private var hung: Set<String> = []

    var isWatching: Bool { clipboardWatcher?.isWatching ?? false || helper.isObserving }
    /// Whether it follows Settings (from launch).
    var isFollowingSettings: Bool { settingsObserver != nil }

    var clipboardAccess: ClipboardAccess {
        guard let w = clipboardWatcher else { return .allowed }
        if w.pasteboard.deniesReading { return .denied }
        return w.declined ? .declined : .allowed
    }

    /// Follows Settings for as long as the app runs (launch).
    func start() {
        if settingsObserver == nil {
            settingsObserver = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
                self?.update()
            }
        }
        update()
    }

    /// Stops following Settings and stops watching (tests).
    func stop() {
        settingsObserver.map(NotificationCenter.default.removeObserver)
        settingsObserver = nil
        stopWatching()
    }

    /// Starts or stops watching to match Settings.
    func update() {
        if isEnabled() { startWatching() } else { stopWatching() }
    }

    private func startWatching() {
        helper.onChange = { [weak self] launched in self?.helperChanged(launched: launched) }
        if live && !helper.isObserving { helper.start() }
        guard clipboardWatcher == nil else { return }
        let w = ScreenshotClipboardWatcher(pasteboard: makePasteboard(), folder: clipboardFolder(),
                                           isHelperActive: { [weak self] in self?.helper.isActive ?? false })
        w.usesTimers = live
        w.readsInline = !live
        w.now = now
        w.onScreenshot = { [weak self] url in self?.found(url, from: self?.pointer() ?? .zero) }
        w.onDeclined = { NotificationCenter.default.post(name: Self.clipboardAccessDidChange, object: nil) }
        clipboardWatcher = w
        w.start()
    }

    /// Turned off: nothing watches any more (and a later turn-on starts afresh, prompt back-off included).
    func stopWatching() {
        let declined = clipboardWatcher?.declined ?? false
        clipboardWatcher?.stop()
        clipboardWatcher = nil
        helper.stop()
        helper.onChange = nil
        if declined { NotificationCenter.default.post(name: Self.clipboardAccessDidChange, object: nil) }
    }

    /// macOS's screenshot helper started (a new screenshot: its first copied image counts) or quit. Either way a
    /// clipboard write it made just before is looked at now.
    func helperChanged(launched: Bool) {
        if launched { clipboardWatcher?.newSession() }
        clipboardWatcher?.poll()
    }

    /// A copied screenshot: hung once (never a file hung before or already on the line), and only while the setting is
    /// on. Its card flies up from `point` (global screen coordinates).
    func found(_ url: URL, from point: CGPoint) {
        guard isEnabled() else { return }
        let id = Self.identity(url)
        guard hung.insert(id).inserted else { return }
        let path = ClotheslineEngine.identity(url)
        guard !lineFiles().contains(where: { ClotheslineEngine.identity($0) == path }) else { return }
        hang(url, point)
    }

    /// The file's device and inode (the same file under any name), or its path when it can't be read.
    static func identity(_ url: URL) -> String {
        var st = Darwin.stat()
        guard lstat(url.path, &st) == 0 else { return ClotheslineEngine.identity(url) }
        return "\(st.st_dev):\(st.st_ino)"
    }
}
