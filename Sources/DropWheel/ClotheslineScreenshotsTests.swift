#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import SwiftUI

/// Headless checks for `--selftest clothesline-screenshots`: copied screenshots hanging on the Clothesline. Everything
/// runs in temporary folders and on named pasteboards; the real clipboard and Pictures are never touched, and no
/// screenshot is taken.
enum ClotheslineScreenshotsTests {
    typealias Checker = ShelfAndWelcomeTests.Checker

    static func run() -> String {
        let c = Checker()
        metadata(c)
        naming(c)
        do { try clipboardWatcher(c) } catch { c.check(false, "clipboard watcher setup", error.localizedDescription) }
        helper(c)
        do { try switching(c) } catch { c.check(false, "settings setup", error.localizedDescription) }
        do { try clipboardAccess(c) } catch { c.check(false, "clipboard access setup", error.localizedDescription) }
        settingsWindow(c)
        do { try copiedOnly(c) } catch { c.check(false, "copied-only setup", error.localizedDescription) }
        captions(c)
        origin(c)
        flight(c)
        reduceMotion(c)
        do { try handoff(c) } catch { c.check(false, "flight window setup", error.localizedDescription) }
        return c.report
    }

    // MARK: Helpers

    /// A new temporary folder at its real path (/private/var/…, as the watcher sees it).
    static func scratch(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("YummyOrange selftest screenshots \(name) \(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func png(width: Int = 64, height: Int = 40) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 0.3, green: 0.5, blue: 0.9, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.white.setFill()
        CGRect(x: 4, y: 4, width: width / 3, height: height / 3).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// A screenshot file: a PNG carrying macOS's mark (or not).
    @discardableResult
    static func shot(_ url: URL, marked: Bool = true) throws -> URL {
        try png().write(to: url)
        if marked { ScreenshotMetadata.mark(url) }
        return url
    }

    /// A point on another display than the line's (global screen coordinates): a card copied there comes in from the
    /// right edge of the line's display.
    static let otherDisplay = CGPoint(x: -400, y: 300)

    static func pixelSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    // MARK: The mark

    /// The bytes `screencapture` wrote on a screenshot on this Mac (`xattr -px com.apple.metadata:kMDItemIsScreenCapture`).
    static let measuredMark: [UInt8] = [0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30, 0x09, 0x08, 0, 0, 0, 0, 0, 0, 0x01, 0x01, 0, 0, 0, 0, 0, 0,
                                        0, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x09]

    static func metadata(_ c: Checker) {
        do {
            let dir = try scratch("mark")
            defer { try? FileManager.default.removeItem(at: dir) }
            let marked = try shot(dir.appendingPathComponent("a.png"))
            let plain = try shot(dir.appendingPathComponent("b.png"), marked: false)
            let unmarked = try shot(dir.appendingPathComponent("c.png"))
            ScreenshotMetadata.mark(unmarked, false)
            let written = ScreenshotMetadata.attributeData(marked, name: ScreenshotMetadata.attribute).map { [UInt8]($0) }
            c.check(ScreenshotMetadata.isScreenCapture(marked) && !ScreenshotMetadata.isScreenCapture(plain)
                    && !ScreenshotMetadata.isScreenCapture(unmarked),
                    "real files: marked → a screenshot; no mark, or the mark set to false → not")
            c.check(written == measuredMark, "YummyOrange marks a saved clipboard screenshot with exactly the bytes macOS uses",
                    written.map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") } ?? "no attribute")
        } catch { c.check(false, "mark files", error.localizedDescription) }
    }

    // MARK: Names

    static func naming(_ c: Checker) {
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 11, 24, 10, 31, 7)
        var cal = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC")!
        cal.timeZone = utc
        let date = cal.date(from: parts)!
        let gb = ScreenshotNaming.fileName(date: date, locale: Locale(identifier: "en_GB"), timeZone: utc)
        c.check(gb == "Screenshot 2026-11-24 at 10.31.07.png", "named like a macOS screenshot (24-hour clock)", gb)
        let us = ScreenshotNaming.fileName(date: date, locale: Locale(identifier: "en_US"), timeZone: utc)
        c.check(us.hasPrefix("Screenshot 2026-11-24 at 10.31.07") && us.hasSuffix("AM.png") && !us.contains(":"),
                "a 12-hour locale keeps its AM, as macOS does", us)
        let de = ScreenshotNaming.fileName(date: date, locale: Locale(identifier: "de_DE"), timeZone: utc, prefix: "Bildschirmfoto",
                                           pattern: "%@ %@ um %@")
        let fr = ScreenshotNaming.fileName(date: date, locale: Locale(identifier: "fr_FR"), timeZone: utc, prefix: "Capture d’écran",
                                           pattern: "%1$@ %2$@ à %3$@")
        c.check(de == "Bildschirmfoto 2026-11-24 um 10.31.07.png" && fr == "Capture d’écran 2026-11-24 à 10.31.07.png",
                "macOS's words in the user's language (plain and numbered places)", "\(de) | \(fr)")
        let broken = ScreenshotNaming.fileName(date: date, locale: Locale(identifier: "en_GB"), timeZone: utc, prefix: "Shot", pattern: "%@ only")
        c.check(broken == "Shot 2026-11-24 at 10.31.07.png", "a pattern without three places falls back to English", broken)
        let taken: Set<String> = ["/x/a.png", "/x/a 2.png"]
        let next = ScreenshotNaming.uniqueURL(in: URL(fileURLWithPath: "/x"), name: "a.png", exists: { taken.contains($0.path) })
        c.check(next.lastPathComponent == "a 3.png", "a taken name gets the next number", next.lastPathComponent)
        let words = ScreenshotNaming.systemWords()
        c.notes(words: words)
        // YummyOrange is English only, so the helper's own words must be picked for the user's languages.
        if Bundle(path: ScreenshotNaming.helperPath) != nil {
            let german = ScreenshotNaming.helperWords(languages: ["de-DE"])
            let french = ScreenshotNaming.helperWords(languages: ["fr-CA", "fr"])
            let english = ScreenshotNaming.helperWords(languages: ["en-KR", "ko-KR"])
            c.check(german.prefix == "Bildschirmfoto" && german.pattern == "%@ %@ um %@" && french.prefix.hasPrefix("Capture")
                    && english.prefix == "Screenshot",
                    "clipboard screenshots are named in the user's language, from macOS's own words",
                    "\(german.prefix) “\(german.pattern)” | \(french.prefix) | \(english.prefix)")
        }
    }

    // MARK: Clipboard screenshots

    /// A uniquely named pasteboard (never the real clipboard) that counts reads, and can refuse them.
    final class SpyPasteboard: ScreenshotPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("DropWheel selftest \(UUID().uuidString)"))
        var reads = 0
        /// Whether the last read ran on the main thread.
        var readOnMain = false
        var denies = false
        /// The user declined the system's prompt: reads come back empty.
        var declining = false
        /// Runs during a read (the paste prompt is up).
        var onRead: (() -> Void)?
        var changeCount: Int { board.changeCount }
        var types: [NSPasteboard.PasteboardType]? { board.types }
        func data(forType type: NSPasteboard.PasteboardType) -> Data? {
            reads += 1
            readOnMain = Thread.isMainThread
            onRead?()
            return declining ? nil : board.data(forType: type)
        }
        var deniesReading: Bool { denies }
        func put(_ data: Data, _ type: NSPasteboard.PasteboardType, plus extra: [NSPasteboard.PasteboardType] = []) {
            board.clearContents()
            board.declareTypes([type] + extra, owner: nil)
            board.setData(data, forType: type)
            for t in extra { board.setString("x", forType: t) }
        }
        deinit { board.releaseGlobally() }
    }

    static func clipboardWatcher(_ c: Checker) throws {
        let dir = try scratch("clipboard")
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = SpyPasteboard()
        var helperActive = false
        let w = ScreenshotClipboardWatcher(pasteboard: spy, folder: dir, isHelperActive: { helperActive })
        w.usesTimers = false
        w.readsInline = true
        w.locale = Locale(identifier: "en_GB")
        w.timeZone = TimeZone(identifier: "UTC")!
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 11, 24, 10, 31, 7)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = w.timeZone
        let taken = cal.date(from: parts)!
        w.now = { taken }
        w.words = { (ScreenshotNaming.englishPrefix, ScreenshotNaming.englishPattern) }
        var found: [URL] = []
        w.onScreenshot = { found.append($0) }
        w.start()
        func saved() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

        // An image copied in another app (the helper isn't running): never read.
        spy.put(png(), .png)
        w.poll()
        c.check(spy.reads == 0 && found.isEmpty && saved().isEmpty, "an image copied in another app isn't read or hung", "\(spy.reads) reads")

        // A screenshot copied to the clipboard: read once, saved as a PNG with macOS's name, marked, hung.
        helperActive = true
        let image = png(width: 120, height: 80)
        spy.put(image, .png)
        let count = spy.board.changeCount
        let typesBefore = spy.board.types
        w.poll()
        let url = dir.appendingPathComponent("Screenshot 2026-11-24 at 10.31.07.png")
        c.check(spy.reads == 1 && found == [url] && saved() == [url.lastPathComponent],
                "a clipboard screenshot (helper running) is saved as “Screenshot 2026-11-24 at 10.31.07.png” and hung",
                "\(spy.reads) reads, saved \(saved())")
        c.check(pixelSize(url) == CGSize(width: 120, height: 80) && ScreenshotMetadata.isScreenCapture(url),
                "the saved file is the image as a PNG, marked as a screenshot", "\(pixelSize(url).map { "\($0)" } ?? "unreadable")")
        c.check(spy.board.changeCount == count && spy.board.data(forType: .png) == image && spy.board.types == typesBefore,
                "the clipboard is left as it was (⌘V still pastes the image)")
        w.poll()
        c.check(spy.reads == 1 && found.count == 1, "the same clipboard isn't read twice")

        // More changes in the same helper session are copies (⌘C while the helper is still at work), not screenshots.
        spy.put(png(width: 60, height: 40), .png)
        w.poll()
        spy.put(png(width: 64, height: 40), .png)
        w.poll()
        c.check(found.count == 1 && saved().count == 1 && w.sessionTaken,
                "one screenshot is one image: later images in the same helper session are copies and aren't hung", "\(found.count) hung")
        // A new screenshot (the helper starts again) counts again, but not the same image as the last one saved.
        w.newSession()
        spy.put(image, .png)
        w.poll()
        c.check(found.count == 1 && saved().count == 1, "an image identical to the last screenshot isn't saved or hung twice")
        w.newSession()
        // TIFF only: saved as PNG. A second one in the same second gets " 2".
        let tiff = NSBitmapImageRep(data: image)!.tiffRepresentation!
        spy.put(tiff, .tiff)
        w.poll()
        let second = dir.appendingPathComponent("Screenshot 2026-11-24 at 10.31.07 2.png")
        let head = (try? Data(contentsOf: second))?.prefix(4)
        c.check(found.last == second && head == Data([0x89, 0x50, 0x4E, 0x47]),
                "a TIFF screenshot is saved as PNG; the same second gets “… 2.png”", found.last?.lastPathComponent ?? "none")

        // Not a screenshot's contents: text, a file from Finder, an item from another device. Not read at all.
        let reads = spy.reads
        spy.board.clearContents()
        spy.board.setString("hello", forType: .string)
        w.poll()
        spy.put(png(), .png, plus: [.fileURL])
        w.poll()
        spy.put(png(), .png, plus: [NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")])
        w.poll()
        c.check(spy.reads == reads && found.count == 2, "text, a copied file or another device's clipboard isn't read, even mid-screenshot",
                "\(spy.reads - reads) reads")

        // YummyOrange set to Deny in System Settings: nothing is read, nothing fails.
        spy.denies = true
        spy.put(png(), .png)
        w.poll()
        c.check(spy.reads == reads && found.count == 2, "paste access set to Deny: no read is tried (no prompt, no error)")
        spy.denies = false

        // The user declines the system's prompt: one read comes back empty, then no more reads (no prompt after every shot).
        w.newSession()
        spy.declining = true
        spy.put(png(), .png)
        w.poll()
        let afterDecline = spy.reads
        spy.put(png(), .png)
        w.poll()
        c.check(w.declined && afterDecline == reads + 1 && spy.reads == afterDecline && found.count == 2,
                "a declined prompt isn't asked again: after one empty read, clipboard screenshots aren't read",
                "declined \(w.declined), reads \(spy.reads - reads)")

        // Turned off while the read waited (on the paste prompt): nothing is saved or hung.
        let late = ScreenshotClipboardWatcher(pasteboard: spy, folder: dir, isHelperActive: { true })
        late.usesTimers = false
        late.readsInline = true
        late.words = w.words
        var lateFound = 0
        late.onScreenshot = { _ in lateFound += 1 }
        late.start()
        spy.declining = false
        let filesBefore = saved().count
        spy.onRead = { late.stop() }
        spy.put(png(), .png)
        late.poll()
        spy.onRead = nil
        c.check(lateFound == 0 && saved().count == filesBefore && !late.declined,
                "turned off while the clipboard was being read: the screenshot isn't saved or hung", "\(saved().count - filesBefore) saved")
        var declines = 0
        let asked = ScreenshotClipboardWatcher(pasteboard: spy, folder: dir, isHelperActive: { true })
        asked.usesTimers = false
        asked.readsInline = true
        asked.onDeclined = { declines += 1 }
        asked.start()
        spy.declining = true
        for _ in 0..<2 { spy.put(png(), .png); asked.poll() }
        spy.declining = false
        c.check(declines == 1 && asked.declined, "a declined prompt is reported once (Settings then says why clipboard screenshots are skipped)")

        // Stopped: nothing happens.
        let stopped = ScreenshotClipboardWatcher(pasteboard: spy, folder: dir, isHelperActive: { true })
        stopped.readsInline = true
        stopped.usesTimers = false
        spy.declining = false
        let r = spy.reads
        spy.put(png(), .png)
        stopped.poll()
        c.check(spy.reads == r, "a watcher that isn't started never reads")

        // Off the main thread (the app's way): the read happens on a background queue, the hang on the main thread.
        let bg = ScreenshotClipboardWatcher(pasteboard: spy, folder: dir, isHelperActive: { true })
        bg.usesTimers = false
        var onMain = false
        var hung = 0
        bg.onScreenshot = { _ in onMain = Thread.isMainThread; hung += 1 }
        bg.start()
        spy.put(png(), .png)
        bg.poll()
        let until = Date().addingTimeInterval(2)
        while hung == 0 && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        c.check(hung == 1 && onMain && !spy.readOnMain, "the read runs in the background and the screenshot is hung on the main thread",
                "read on main \(spy.readOnMain), hung on main \(onMain)")
        bg.stop()
    }

    // MARK: The helper

    static func helper(_ c: Checker) {
        let m = ScreenshotHelperMonitor()
        var running = false
        var now = 100.0
        var changes: [Bool] = []
        m.isRunning = { running }
        m.now = { now }
        m.onChange = { changes.append($0) }
        let idle = m.isActive
        running = true
        let busy = m.isActive
        running = false
        now += 1.5
        let justQuit = m.isActive
        now += 0.6
        let later = m.isActive
        c.check(!idle && busy && justQuit && !later, "the helper counts while it runs and for 2 s after it quits",
                "idle \(idle), running \(busy), 1.5 s after \(justQuit), 2.1 s after \(later)")
        m.helperChanged(launched: true)
        let launchedActive = m.isActive
        m.helperChanged(launched: false)
        c.check(changes == [true, false] && launchedActive, "a launch or quit seen in the running apps is passed on (a launch starts a new screenshot)")
        c.check(ScreenshotHelperMonitor.bundleID == "com.apple.screencaptureui", "the helper is com.apple.screencaptureui")
    }

    // MARK: The switch

    static func switching(_ c: Checker) throws {
        let saved = Settings.defaults
        let store = SettingsMemoryStore()
        Settings.defaults = store
        defer { Settings.defaults = saved }
        c.check(Settings.hangScreenshots, "Hang copied screenshots is on by default")
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: nil) { _ in posted += 1 }
        Settings.hangScreenshots = false
        Settings.hangScreenshots = false
        c.check(!Settings.hangScreenshots && store.object(forKey: "hangScreenshots") as? Bool == false && posted == 1,
                "it saves (one notification)", "posted \(posted)")
        NotificationCenter.default.removeObserver(token)
        Settings.hangScreenshots = true

        let dir = try scratch("switch")
        let pictures = try scratch("pictures")
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: pictures) }
        let spy = SpyPasteboard()
        let co = ClotheslineScreenshots()
        co.clipboardFolder = { pictures }
        co.makePasteboard = { spy }
        var hung: [(String, CGPoint)] = []
        co.hang = { hung.append(($0.lastPathComponent, $1)) }
        var onLine: [URL] = []
        co.lineFiles = { onLine }
        let pointer = CGPoint(x: 300, y: 500)
        co.pointer = { pointer }
        // Live: real timers and the helper observed (the pasteboard is still the named one).
        co.live = true
        Settings.resultsDestination = .finder
        co.start()
        func state() -> String { "clipboard \(co.clipboardWatcher?.isPolling ?? false), helper \(co.helper.isObserving)" }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        c.check(!co.isWatching && co.clipboardWatcher == nil, "new files in Finder: nothing watches (no poll, no helper observer)", state())
        Settings.resultsDestination = .shelf
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        c.check(co.clipboardWatcher?.isPolling == true && co.helper.isObserving,
                "On a Shelf: copied screenshots are watched too (they go on your shelf)", state())
        Settings.resultsDestination = .clothesline
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        c.check(co.clipboardWatcher?.isPolling == true && co.helper.isObserving,
                "On the Clothesline: the change count is polled and the helper observed", state())
        Settings.hangScreenshots = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        c.check(co.clipboardWatcher == nil && !co.helper.isObserving && !co.isWatching,
                "Hang copied screenshots off: the poll stopped, the helper no longer observed", state())
        Settings.hangScreenshots = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let back = co.isWatching
        Settings.resultsDestination = .finder
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        c.check(back && !co.isWatching, "on again it watches; another place for new files stops it again", state())

        // A screenshot reported twice (under any name), or one already on the line, is hung once.
        Settings.resultsDestination = .clothesline
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let a = try shot(dir.appendingPathComponent("Screenshot a.png"))
        co.found(a, from: pointer)
        co.found(a, from: pointer)
        let alias = dir.appendingPathComponent("Screenshot a renamed.png")
        try FileManager.default.moveItem(at: a, to: alias)
        co.found(alias, from: .zero)
        let b = try shot(dir.appendingPathComponent("Screenshot b.png"))
        onLine = [b]
        co.found(b, from: pointer)
        c.check(hung.map(\.0) == ["Screenshot a.png"] && hung.first?.1 == pointer,
                "each screenshot is hung once (by file, whatever its name), never one already on the line", "\(hung.map(\.0))")

        // Turned off: something the watcher still reports isn't hung.
        Settings.hangScreenshots = false
        let c1 = try shot(dir.appendingPathComponent("Screenshot after off.png"))
        co.found(c1, from: pointer)
        Settings.hangScreenshots = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        c.check(hung.count == 1, "a screenshot reported after the switch was turned off isn't hung", "\(hung.map(\.0))")

        // A copied screenshot, live: saved in the Clothesline folder and hung from the pointer, without being asked.
        hung = []
        co.helper.isRunning = { true }
        co.helper.helperChanged(launched: true)
        spy.put(png(), .png)
        let clip = Date().addingTimeInterval(3)
        while hung.isEmpty && Date() < clip { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        c.check(hung.count == 1 && hung.first?.1 == pointer && hung.first?.0.hasPrefix("Screenshot ") == true,
                "live: a copied screenshot is saved in the Clothesline folder and hung from the pointer", "\(hung.map(\.0))")
        co.stop()
        c.check(!co.isWatching, "stop() leaves nothing watching")
        Settings.resultsDestination = .shelf
    }

    /// Whether clipboard screenshots can be read, for the caption under the switch.
    static func clipboardAccess(_ c: Checker) throws {
        let savedDefaults = Settings.defaults
        Settings.defaults = SettingsMemoryStore()
        defer { Settings.defaults = savedDefaults }
        Settings.resultsDestination = .clothesline
        let pictures = try scratch("pictures-again")
        defer { try? FileManager.default.removeItem(at: pictures) }
        let co = ClotheslineScreenshots()
        co.clipboardFolder = { pictures }
        let spy = SpyPasteboard()
        co.makePasteboard = { spy }
        co.live = false
        co.hang = { _, _ in }
        co.lineFiles = { [] }
        var running = false
        co.helper.isRunning = { running }
        co.start()
        defer { co.stop(); Settings.resultsDestination = .shelf }
        if #available(macOS 15.4, *) {
            c.check(PasteboardSource.denies(.alwaysDeny) && !PasteboardSource.denies(.ask) && !PasteboardSource.denies(.alwaysAllow)
                    && !PasteboardSource.denies(.default),
                    "only Deny in Paste from Other Apps stops reading (Ask brings the prompt in context)")
        }
        spy.denies = true
        let denied = co.clipboardAccess
        spy.denies = false
        var notes = 0
        let token = NotificationCenter.default.addObserver(forName: ClotheslineScreenshots.clipboardAccessDidChange, object: nil, queue: nil) { _ in notes += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        // A copied screenshot whose read the user declines (the system's paste prompt).
        running = true
        co.helper.helperChanged(launched: true)
        spy.declining = true
        spy.put(png(), .png)
        co.clipboardWatcher?.poll()
        spy.declining = false
        running = false
        let declined = co.clipboardAccess
        Settings.hangScreenshots = false
        Settings.hangScreenshots = true
        c.check(denied == .denied && declined == .declined && notes >= 1 && co.clipboardAccess == .allowed,
                "the caption learns why clipboard screenshots are skipped (Deny, or a declined prompt until turned off and on)",
                "denied \(denied), declined \(declined), \(notes) notices, then \(co.clipboardAccess)")
    }

    /// The app's rule (since 24 Nov 2026): taking a screenshot hangs nothing; copying it does, once per screenshot.
    static func copiedOnly(_ c: Checker) throws {
        let saved = Settings.defaults
        Settings.defaults = SettingsMemoryStore()
        defer { Settings.defaults = saved }
        Settings.resultsDestination = .clothesline
        Settings.hangScreenshots = true
        let pictures = try scratch("copied-only pictures")
        defer { try? FileManager.default.removeItem(at: pictures) }
        let spy = SpyPasteboard()
        let co = ClotheslineScreenshots()
        co.live = false
        co.clipboardFolder = { pictures }
        co.makePasteboard = { spy }
        var hung: [String] = []
        co.hang = { url, _ in hung.append(url.lastPathComponent) }
        co.lineFiles = { [] }
        var running = false
        co.helper.isRunning = { running }
        co.start()
        defer { co.stop() }
        c.check(co.isWatching && co.clipboardWatcher != nil, "On the Clothesline the clipboard is watched")
        // A screenshot is taken (the helper starts): nothing hangs.
        running = true
        co.helperChanged(launched: true)
        c.check(hung.isEmpty, "taking a screenshot hangs nothing", "\(hung)")
        // ⌘C in its preview: hung once; ⌘C again (twice more) adds nothing.
        spy.put(png(width: 90, height: 60), .png)
        co.clipboardWatcher?.poll()
        spy.put(png(width: 90, height: 61), .png)
        co.clipboardWatcher?.poll()
        spy.put(png(width: 90, height: 62), .png)
        co.clipboardWatcher?.poll()
        c.check(hung.count == 1 && hung.first?.hasPrefix("Screenshot") == true,
                "copying the screenshot hangs it once, however many times ⌘C is pressed", "\(hung)")
        // The next screenshot, copied: hung once more.
        co.helperChanged(launched: false)
        co.helperChanged(launched: true)
        spy.put(png(width: 120, height: 60), .png)
        co.clipboardWatcher?.poll()
        c.check(hung.count == 2, "the next screenshot, copied, hangs once more", "\(hung)")
        // An image copied when no screenshot is on screen (the helper long gone): never.
        running = false
        co.helper.now = { CACurrentMediaTime() + 60 }
        spy.put(png(width: 140, height: 60), .png)
        co.clipboardWatcher?.poll()
        c.check(hung.count == 2, "an image copied anywhere else hangs nothing", "\(hung)")
    }

    /// The words under the switch and on the cards.
    static func captions(_ c: Checker) {
        let on = ScreenshotsSetting.detail(for: .clothesline)
        let declined = ScreenshotsSetting.detail(for: .clothesline, clipboard: .declined)
        let denied = ScreenshotsSetting.detail(for: .clothesline, clipboard: .denied)
        c.check(on.contains("hangs on the Clothesline") && on.contains("⌘C") && on.contains("Pictures › Clothesline") && on.contains("macOS asks")
                && !on.contains("fly") && !on.contains("Ones "),
                "the caption says what it does (copying a screenshot hangs it; no motion words) and that macOS asks before YummyOrange can paste", on)
        c.check(declined.contains("skipped") && declined.contains("Turn this off and on") && denied.contains("Paste from Other Apps")
                && !denied.contains("Turn this off"),
                "after a declined prompt, or with Deny set, it says clipboard screenshots are skipped and how to get them back")

        // A dimmed row dims its name too (the explanation stays readable).
        func darkest(enabled: Bool) -> Int {
            let label = SettingLabel("Hang copied screenshots").disabled(!enabled).padding(6).background(Color.white)
                .environment(\.colorScheme, .light)
            let hosted = AppShellTests.hosted(label)
            hosted.window.appearance = NSAppearance(named: .aqua)
            hosted.settle()
            let v = hosted.host
            defer { hosted.window.contentView = nil }
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return -1 }
            v.cacheDisplay(in: v.bounds, to: rep)
            var m = 255
            for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
                if let px = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), px.alphaComponent > 0.9 { m = min(m, Int(px.brightnessComponent * 255)) }
            } }
            return m
        }
        let lit = darkest(enabled: true), dim = darkest(enabled: false)
        c.check(lit >= 0 && lit < 80 && dim > lit + 50, "a dimmed setting's name is dimmed, not only its switch",
                "darkest pixel \(lit) enabled, \(dim) dimmed (of 255)")

        // A screenshot's name keeps its time on the card; other names lose their middle.
        let shots = ["Screenshot 2026-11-24 at 10.31.07.png", "Screenshot 2026-11-24 at 10.31.07 AM.png",
                     "Bildschirmfoto 2026-11-24 um 10.31.07.png", "Screen Recording 2026-11-24 at 10.40.00.mov"]
        let others = ["Quarterly report, final version.pdf", "IMG_2026.HEIC", "2026-11-24 notes.txt"]
        c.check(shots.allSatisfy { ClotheslineArt.captionTruncation($0) == .byTruncatingHead }
                && others.allSatisfy { ClotheslineArt.captionTruncation($0) == .byTruncatingMiddle },
                "a screenshot card's name is cut at its head, so the time stays whole (“…11-24 at 10.31.07.png”)")
    }

    /// Settings › General: the switch sits under Show new files, on, and dimmed unless new files go to the Clothesline.
    static func settingsWindow(_ c: Checker) {
        let saved = Settings.defaults
        Settings.defaults = SettingsMemoryStore()
        defer { Settings.defaults = saved }
        func switches(_ destination: ResultsDestination) -> (count: Int, disabled: Int) {
            Settings.resultsDestination = destination
            let hosted = AppShellTests.hosted(SettingsSectionView(section: .general, snapshot: true))
            var all: [NSSwitch] = []
            func walk(_ v: NSView) { if let s = v as? NSSwitch { all.append(s) }; v.subviews.forEach(walk) }
            walk(hosted.host)
            hosted.window.contentView = nil
            return (all.count, all.filter { !$0.isEnabled }.count)
        }
        // Launch at login and Check for updates automatically are dimmed in a self-test (no bundle), so they count in both.
        let shelf = switches(.shelf), line = switches(.clothesline), finder = switches(.finder)
        c.check(shelf.count == 4 && line.count == 4 && finder.count == 4 && shelf.disabled == line.disabled
                && finder.disabled == line.disabled + 1,
                "the copied-screenshots switch is shown with Show new files, on for a shelf or the Clothesline and dimmed (not hidden) otherwise",
                "shelf: \(shelf.disabled) of \(shelf.count) dimmed; clothesline: \(line.disabled); finder: \(finder.disabled)")
        c.check(ScreenshotsSetting.detail(for: .clothesline).contains("Clothesline") && ScreenshotsSetting.detail(for: .shelf).contains("your shelf")
                && ScreenshotsSetting.detail(for: .finder).contains("On a Shelf or On the Clothesline")
                && ScreenshotsSetting.detail(for: .clothesline).hasSuffix(".") && ScreenshotsSetting.detail(for: .none).hasSuffix("."),
                "its explanation says what it does, or how to turn it on")
    }

    // MARK: Where a flight starts

    static func origin(_ c: Checker) {
        let g = ClotheslineGeometry.builtInSample
        let visible = CGRect(x: 0, y: 0, width: 1736, height: 1093)
        let w = ClotheslineCardMetrics.maxMatWidth
        let mat = ClotheslineCardMetrics.matRect(width: w)
        let edge = ClotheslineFlightGeometry.start(from: otherDisplay, geometry: g, visibleFrame: visible)
        let center = CGPoint(x: edge.x, y: edge.y + mat.midY)
        c.check(edge.x - w / 2 >= g.width + ClotheslineFlightGeometry.offEdge - 0.01 && abs(center.y - (1133 - 20 - 55)) < 0.01,
                "a screenshot copied on another display starts just past this one's right edge, near its bottom", "\(center)")
        let p = ClotheslineFlightGeometry.start(from: CGPoint(x: 900, y: 400), geometry: g, visibleFrame: visible)
        c.check(abs(p.x - 900) < 0.01 && abs(p.y + mat.midY - (1133 - 400)) < 0.01, "a copied screenshot starts at the pointer", "\(p)")
        let away = ClotheslineFlightGeometry.start(from: CGPoint(x: 3000, y: 400), geometry: g, visibleFrame: visible)
        let top = ClotheslineFlightGeometry.start(from: CGPoint(x: 5, y: 1130), geometry: g, visibleFrame: visible)
        c.check(away == edge && top.y + mat.minY >= g.menuBarHeight && top.x - w / 2 >= 0,
                "a pointer on any other display starts from this one's edge; one at the edge starts fully on screen", "\(away) \(top)")
    }

    // MARK: The flight

    /// A hidden line holding `older` files, as the app has it most of the time.
    static func hiddenLine(older: Int = 4, reduceMotion: Bool = false, geometry: ClotheslineGeometry = .builtInSample) -> ClotheslineEngine {
        let e = ClotheslineEngine(geometry: geometry, reduceMotion: reduceMotion)
        e.fileExists = { _ in true }
        e.hang((0..<older).map { URL(fileURLWithPath: "/tmp/older-\($0).pdf") })
        e.settleNow()
        e.retract()
        for _ in 0..<1200 where e.state != .hidden { e.step(ClotheslineEngine.substep) }
        e.settleNow()
        return e
    }

    struct Sample {
        var t: Double
        var pivot: CGPoint
        var flying: Bool
        var alpha: Double
        var scale: Double
        var angle: Double
        var state: ClotheslineEngine.State
        var line: Double
        /// How far out the line is: the smaller of its spread and its fall.
        var out: Double
        /// The string's dip under the card's pin (down; negative: bowed up).
        var dip: Double
    }

    static func record(_ e: ClotheslineEngine, _ id: UUID, seconds: Double) -> [Sample] {
        var out: [Sample] = []
        let t0 = e.time
        while e.time - t0 < seconds {
            e.step(ClotheslineEngine.substep)
            guard let p = e.pose(id) else { continue }
            out.append(Sample(t: e.time - t0, pivot: p.pivot, flying: p.flying, alpha: p.alpha, scale: p.scale, angle: p.angle,
                              state: e.state, line: e.line.value, out: min(e.line.value, e.fall.value), dip: e.cards[id]?.dip.value ?? 0))
        }
        return out
    }

    static func f(_ x: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", x) }

    /// The fastest the card moves in the air, in points per second.
    static func topSpeed(_ s: [Sample]) -> Double {
        zip(s, s.dropFirst()).filter { $0.0.flying }.map { hypot($1.pivot.x - $0.pivot.x, $1.pivot.y - $0.pivot.y) }.max().map { $0 / ClotheslineEngine.substep } ?? 0
    }

    static func flight(_ c: Checker) {
        let g = ClotheslineGeometry.builtInSample
        let visible = CGRect(x: 0, y: 0, width: 1736, height: 1093)
        let h = ClotheslineEngine.substep
        let e = hiddenLine()
        let start = ClotheslineFlightGeometry.start(from: otherDisplay, geometry: g, visibleFrame: visible)
        e.hang([URL(fileURLWithPath: "/tmp/Screenshot 2026-11-24 at 10.31.07.png")], from: start)
        guard let id = e.items.first?.id else { c.check(false, "flight setup"); return }
        let width = Double(e.cards[id]?.width ?? 0)
        let s = record(e, id, seconds: 7)
        guard let catchIndex = s.firstIndex(where: { !$0.flying }), catchIndex > 2 else {
            c.check(false, "the card flies and lands", "\(s.count) samples"); return
        }
        let caught = s[catchIndex], lastAir = s[catchIndex - 1]
        // In from the right edge: whole from the start (it was only out of view), moving at once.
        let first = s[0]
        let entry = s.firstIndex { Double($0.pivot.x) - width / 2 < Double(g.width) } ?? 0
        // (It leaves from rest, off the display; in view it never stands still.)
        let away = s.first { hypot($0.pivot.x - start.x, $0.pivot.y - start.y) > 1 }?.t ?? 99
        let still = zip(s[entry..<catchIndex], s[(entry + 1)...]).filter { hypot($1.pivot.x - $0.pivot.x, $1.pivot.y - $0.pivot.y) < 0.2 }.count
        let a0 = s[max(0, entry - 12)], a1 = s[min(s.count - 1, entry + 12)]
        let across = abs(a1.pivot.x - a0.pivot.x), up = abs(a1.pivot.y - a0.pivot.y)
        c.check(Double(first.pivot.x) - width / 2 > Double(g.width) && s[..<catchIndex].allSatisfy { $0.alpha > 0.999 && $0.scale > 0.999 }
                && away < 0.1 && still == 0 && across > 3 * up && a1.pivot.x < a0.pivot.x,
                "copied on another display, it comes in from this one's right edge: whole (no fading in), never still, sliding left",
                "starts at x \(Int(first.pivot.x)) (edge \(Int(g.width))), on screen after \(f(s[entry].t)) s, \(f(across)) pt across to \(f(up)) up there")
        // Never too fast: the speed is capped here, and on a wide display too (the flight is slowed as a whole).
        let fastest = topSpeed(Array(s[..<catchIndex]))
        let wideGeometry = ClotheslineGeometry(screenFrame: CGRect(x: 0, y: 0, width: 3008, height: 1692), safeAreaTop: 40,
                                               leftArea: CGRect(x: 0, y: 1652, width: 1474, height: 40),
                                               rightArea: CGRect(x: 1534, y: 1652, width: 1474, height: 40))
        let wide = hiddenLine(geometry: wideGeometry)
        wide.hang([URL(fileURLWithPath: "/tmp/Screenshot wide.png")], from: ClotheslineFlightGeometry.start(from: otherDisplay, geometry: wideGeometry, visibleFrame: nil))
        let ws = record(wide, wide.items[0].id, seconds: 7)
        let wideTop = topSpeed(ws), wideLanded = ws.firstIndex { !$0.flying }.map { ws[$0].t }
        c.check(fastest <= ClotheslineEngine.flightTopSpeed * 1.02 && fastest > ClotheslineEngine.flightTopSpeed * 0.8
                && wideTop <= ClotheslineEngine.flightTopSpeed * 1.02 && wideLanded != nil,
                "never faster than \(Int(ClotheslineEngine.flightTopSpeed)) pt/s, on a 3008 pt display too (a long flight is slowed as a whole)",
                "\(Int(fastest)) pt/s here, \(Int(wideTop)) pt/s wide (landed after \(wideLanded.map { f($0) } ?? "never") s)")
        let flightTime = caught.t
        c.check(flightTime > 0.3 && flightTime < 0.65 && caught.out > 0.95,
                "the pin catches the line about 0.45 s after the card comes in, with the line out", "\(f(flightTime, 3)) s, line \(f(caught.out, 3))")
        // The line drops to meet it: it comes out as the card arrives, instead of landing first and waiting.
        let reveal = s.first { $0.state != .hidden }?.t ?? 99
        let outAt = s.first { $0.out >= 0.95 }?.t ?? 99
        c.check(caught.t - outAt >= 0 && caught.t - outAt < 0.22 && reveal > 0.1,
                "the hidden line comes out to meet the card, arriving shortly before it does (still for its last approach)", "line starts \(f(reveal)) s, out \(f(outAt)) s, catch \(f(caught.t)) s")
        // An arc: the path bows away from the straight line, below it (it passes under the line's cards).
        let a = s[entry].pivot, b = caught.pivot
        let len = hypot(b.x - a.x, b.y - a.y)
        let deviations = s[entry..<catchIndex].map { p in Double(((p.pivot.x - a.x) * (b.y - a.y) - (p.pivot.y - a.y) * (b.x - a.x)) / len) }
        // (Positive: the lower-left side of the line from the edge to the pin, y growing downward.)
        let bow = deviations.max() ?? 0, other = -(deviations.min() ?? 0)
        c.check(bow > 100 && other < 5, "the path is an arc, bowing under the straight line", "\(Int(bow)) pt below, \(Int(other)) pt above")
        // The last 0.1 s: moving up, more up than across, and still rising at the catch (no creeping into the string).
        let approach = Array(s[max(0, catchIndex - 24)...catchIndex])
        let rising = zip(approach, approach.dropFirst()).allSatisfy { $1.pivot.y <= $0.pivot.y + 0.01 }
        let rise = approach.first!.pivot.y - approach.last!.pivot.y, side = abs(approach.first!.pivot.x - approach.last!.pivot.x)
        let speedUp = Double(s[catchIndex - 2].pivot.y - lastAir.pivot.y) / h
        c.check(rising && rise > side && speedUp > 150, "it rises into its spot from below and meets the string still rising",
                "last 0.1 s: \(f(rise)) pt up, \(f(side)) pt across; \(Int(speedUp)) pt/s up at the catch")
        // The string takes the pin's speed: it bows up under the pin, then springs back.
        let after = s[catchIndex..<min(s.count, catchIndex + Int(0.6 / h))]
        let bowed = -(after.map(\.dip).min() ?? 0)
        let settled = s.last { $0.state == .shown } ?? s.last!
        c.check(bowed > 3 && abs(after.last?.dip ?? 9) < 1 && abs(s[catchIndex - 1].dip) < 0.01,
                "the string gives under the catch, bowing up with the pin, and springs back", "\(f(bowed)) pt up")
        // The path ends at the card's pin: where it is caught is where it then hangs, and nothing jumps.
        let jumps = zip(s, s.dropFirst()).map { hypot($1.pivot.x - $0.pivot.x, $1.pivot.y - $0.pivot.y) }
        // The steps into and out of the catch: the last one in the air, and the first one on the line, against the
        // one before (the card keeps its speed through the catch).
        let jumpAtCatch = max(abs(jumps[catchIndex - 1] - jumps[catchIndex - 2]), abs(jumps[catchIndex] - jumps[catchIndex - 1]))
        let restSpot = CGPoint(x: Double(g.leftEndX) + Double(ClotheslineCardMetrics.leadingPad) + Double(ClotheslineCardMetrics.iconMatWidth) / 2, y: 0)
        // (Caught by a string still falling into its sag, it is then carried down a little with it.)
        c.check(abs(caught.pivot.x - settled.pivot.x) < 2 * ClotheslineEngine.catchSide && settled.pivot.y - caught.pivot.y > -2
                && settled.pivot.y - caught.pivot.y < 30 && abs(settled.pivot.x - restSpot.x) < 1 && jumpAtCatch < 0.15,
                "the flight ends at the card's pin on the string (caught \(Int(caught.pivot.x)),\(Int(caught.pivot.y)); hangs at \(Int(settled.pivot.x)),\(Int(settled.pivot.y)))",
                "speed change at the catch \(f(jumpAtCatch)) pt per substep")
        let retractAt = s.firstIndex { $0.state == .retracting } ?? s.count - 1
        let largest = jumps[..<retractAt].max() ?? 0
        c.check(largest < ClotheslineEngine.flightTopSpeed * 1.02 * h, "no jumps anywhere in the flight or the catch (largest 1/240 s step \(f(largest)) pt)")
        let angles = s[catchIndex...].prefix(480).map(\.angle)
        let turns = zip(angles, angles.dropFirst()).filter { ($0 - angles.last!) * ($1 - angles.last!) < 0 }.count
        // The pin catching the line kicks the swing: the card's turning speed jumps in the substep it is caught
        // (gravity alone changes it by a few hundredths of a radian per second in a substep).
        let spinBefore = (s[catchIndex - 1].angle - s[catchIndex - 2].angle) / h
        let spinAfter = (s[catchIndex + 1].angle - s[catchIndex].angle) / h
        c.check(turns >= 2 && abs(spinAfter - spinBefore) > 0.5, "the pin catches it and it swings",
                "\(turns) swings; the catch changes its turning speed by \(f(abs(spinAfter - spinBefore))) rad/s")
        let hidden = s.firstIndex { $0.t > caught.t && $0.state == .retracting }.map { s[$0].t - caught.t }
        c.check(hidden.map { $0 > 1.9 && $0 < 2.6 } ?? false, "then the line holds 2 s and is pulled back in",
                "retract \(hidden.map { f($0) } ?? "never") s after the catch")
        c.check(s[entry..<catchIndex].allSatisfy { $0.pivot.y <= g.screenFrame.height + 1 && $0.pivot.y >= g.menuBarHeight && $0.alpha <= 1 },
                "once in view the card stays on the display, under the menu bar")
        // While in the air it can't be clicked, and the line's view doesn't draw it.
        let f2 = hiddenLine()
        f2.hang([URL(fileURLWithPath: "/tmp/Screenshot b.png")], from: start)
        let airborne = f2.items[0].id
        // Late in the flight, with the line already coming out (hit-testing is off altogether while it is hidden).
        for _ in 0..<Int(2 / h) where f2.state == .hidden || f2.line.value < 0.5 { f2.step(h) }
        let pose = f2.pose(airborne)
        let local = pose.map { ClotheslineEngine.toScene($0, CGPoint(x: 0, y: 60)) } ?? .zero
        c.check(pose?.flying == true && f2.state != .hidden && local.y > g.menuBarHeight
                && f2.cardID(at: local, minAlpha: 0) == nil && f2.flyingCards == [airborne],
                "a card in the air isn't hit-tested by the line's panel", "state \(f2.state.rawValue), at \(local)")

        // A screenshot copied on this display (from the pointer): there is no edge to come from, so it fades in there,
        // then flies.
        let p = hiddenLine()
        let pointer = ClotheslineFlightGeometry.start(from: CGPoint(x: 900, y: 400), geometry: g, visibleFrame: visible)
        p.hang([URL(fileURLWithPath: "/tmp/Screenshot p.png")], from: pointer)
        let ps = record(p, p.items[0].id, seconds: 4)
        let seen = ps.first { $0.alpha > 0.001 }
        let left = ps.first { hypot($0.pivot.x - pointer.x, $0.pivot.y - pointer.y) > 0.01 }?.t ?? 0
        let pLanded = ps.firstIndex { !$0.flying }.map { ps[$0].t }
        c.check(seen.map { hypot($0.pivot.x - pointer.x, $0.pivot.y - pointer.y) < 0.5 && $0.scale < 0.98 && $0.alpha < 0.2 } ?? false
                && abs(left - ClotheslineEngine.flightAppear) < 0.03 && pLanded.map { $0 < 1.6 } ?? false,
                "a copied screenshot's card fades in at the pointer, takes off after \(f(ClotheslineEngine.flightAppear)) s and lands",
                "take-off \(f(left, 3)) s, landed \(pLanded.map { f($0) } ?? "never") s")

        // A line that is already out: no reveal needed, the card flies straight to its spot; the others make room.
        let out = ClotheslineTests.shownEngine(3)
        out.hang([URL(fileURLWithPath: "/tmp/Screenshot c.png")], from: start)
        let newest = out.items[0].id
        let neighbour = out.items[1].id
        let before = out.pose(neighbour)?.pivot.x ?? 0
        let s2 = record(out, newest, seconds: 2.5)
        let landed = s2.firstIndex { !$0.flying }.map { s2[$0].t }
        c.check(landed.map { $0 > 0.25 && $0 < 1.0 } ?? false && (out.pose(neighbour)?.pivot.x ?? 0) > before + 50,
                "on a line that is out, it lands at the front while the others slide over", "landed \(landed.map { f($0) } ?? "never")")
    }

    static func reduceMotion(_ c: Checker) {
        let g = ClotheslineGeometry.builtInSample
        let e = hiddenLine(reduceMotion: true)
        let start = ClotheslineFlightGeometry.start(from: otherDisplay, geometry: g, visibleFrame: nil)
        e.hang([URL(fileURLWithPath: "/tmp/Screenshot rm.png")], from: start)
        let id = e.items[0].id
        let s = record(e, id, seconds: 1)
        let visible = s.filter { $0.alpha > 0.001 }
        let full = s.first { $0.alpha >= 0.999 }?.t ?? 99
        c.check(!e.hasFlights && s.allSatisfy { !$0.flying && $0.pivot.y < g.cardsBottom } && !visible.isEmpty && full < 0.45,
                "Reduce Motion: no flight; the card fades in on the line (opaque after \(f(full)) s)",
                "lowest pivot \(Int(s.map(\.pivot.y).max() ?? 0))")
        // Reduce Motion turned on mid-flight: the card is put on the line at once.
        let m = hiddenLine()
        m.hang([URL(fileURLWithPath: "/tmp/Screenshot rm2.png")], from: start)
        for _ in 0..<60 { m.step(ClotheslineEngine.substep) }
        let wasFlying = m.hasFlights
        m.reduceMotion = true
        for _ in 0..<120 { m.step(ClotheslineEngine.substep) }
        let p = m.pose(m.items[0].id)
        c.check(wasFlying && !m.hasFlights && (p?.pivot.y ?? 999) < g.cardsBottom && m.state != .hidden,
                "Reduce Motion turned on during a flight puts the card on the line, which comes out")
    }

    // MARK: The flight window

    static func handoff(_ c: Checker) throws {
        let g = ClotheslineGeometry.builtInSample
        let panel = ClotheslineFlightPanel(geometry: g)
        c.check(panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain && panel.styleMask.contains(.nonactivatingPanel)
                && panel.level.rawValue > NSWindow.Level.statusBar.rawValue && panel.level.rawValue < NSWindow.Level.popUpMenu.rawValue
                && panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary)
                && !panel.isOpaque && panel.frame == g.screenFrame && !panel.isVisible && panel.sharingType == .none,
                "the flight window: click-through, never key or active, just above the line (under menus), over the whole display, never captured")
        let lineSurface = ClotheslinePanelSurface(engine: ClotheslineEngine(geometry: g))
        let capturable = lineSurface.panel.sharingType != .none
        lineSurface.excludedFromCapture = true
        let excluded = lineSurface.panel.sharingType == .none
        lineSurface.excludedFromCapture = false
        c.check(capturable && excluded && lineSurface.panel.sharingType == .readOnly,
                "the line's panel can be captured like any window, and left out of captures when asked")

        guard let photo = ClotheslinePreview.fixturesRoot()?.appendingPathComponent("core/photo.png"),
              FileManager.default.fileExists(atPath: photo.path) else { c.check(false, "fixture photo.png"); return }
        var now = 50.0
        let engine = ClotheslineEngine(geometry: g, time: now)
        let surface = ClotheslineOffscreenSurface(engine: engine)
        let ctl = ClotheslineController(engine: engine, surface: surface, clock: ClotheslineManualClock(), now: { now })
        ctl.usesTimers = false
        var made = 0
        var current: ClotheslineFlightOffscreenSurface?
        ctl.makeFlightSurface = { geometry in made += 1; let f = ClotheslineFlightOffscreenSurface(geometry: geometry); current = f; return f }
        ctl.visibleFrame = { CGRect(x: 0, y: 0, width: 1736, height: 1093) }
        ShelfThumbnails.preload([photo], size: ClotheslineView.thumbnailRequest)
        ctl.hang([photo], from: otherDisplay)
        guard let id = engine.items.first?.id else { c.check(false, "hang"); return }
        var both = 0, inAir = 0, onLine = 0, neither = 0, seen = false
        var shownWhileFlying = true
        var excludedWhileOut = true
        for _ in 0..<(60 * 6) {
            now += 1.0 / 60
            ctl.tick(at: now)
            let air = current.map { $0.isShown && $0.view.visibleCards.contains(id) } ?? false
            let line = surface.view.cardLayerPair(id).map { !$0.card.isHidden && surface.isShown } ?? false
            // (Until the line goes back into the notch at the end, where nothing is drawn.)
            guard engine.state == .revealing || engine.state == .shown || engine.hasFlights else { continue }
            if air && line { both += 1 } else if air { inAir += 1; seen = true } else if line { onLine += 1; seen = true } else if seen { neither += 1 }
            if engine.hasFlights && engine.pose(id)?.alpha ?? 0 > 0.01 && !(current?.isShown ?? false) { shownWhileFlying = false }
            if !surface.excludedFromCapture { excludedWhileOut = false }
        }
        c.check(made == 1 && inAir > 20 && onLine > 30 && both == 0 && neither == 0 && shownWhileFlying,
                "the card is drawn by the flight window while in the air and by the line from the frame it is caught: never both, never neither",
                "air \(inAir), line \(onLine), both \(both), gap \(neither) frames")
        c.check(!ctl.flightWindowShown && ctl.flightSurface === current && !(current?.isShown ?? true),
                "the flight window is ordered out once the card has landed (and kept for the next flight)")
        // Out for a screenshot, the line stays out of the next screenshot; once it has gone back it can be captured, and
        // out for anything else it can be captured too.
        for _ in 0..<(60 * 2) where engine.state != .hidden { now += 1.0 / 60; ctl.tick(at: now) }
        let afterwards = surface.excludedFromCapture
        ctl.hang([photo])
        for _ in 0..<30 { now += 1.0 / 60; ctl.tick(at: now) }
        c.check(excludedWhileOut && engine.state != .hidden && !afterwards && !surface.excludedFromCapture,
                "out for a screenshot the line is left out of screen captures; gone back, or out for other files, it isn't",
                "excluded while out \(excludedWhileOut), after \(afterwards), other files \(surface.excludedFromCapture)")
        ctl.shutDown()
    }
}

/// Reading macOS's screen-capture mark back (the app only writes it).
extension ScreenshotMetadata {
    /// Whether `url` carries the mark set to true.
    static func isScreenCapture(_ url: URL) -> Bool {
        attributeData(url, name: attribute).map(isTrue) ?? false
    }

    /// Whether the attribute's bytes say true (a property-list Boolean, or a number other than 0).
    static func isTrue(_ data: Data) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return false }
        if let number = plist as? NSNumber { return number.intValue != 0 }
        return false
    }

    static func attributeData(_ url: URL, name: String) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0, size <= 4096 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            return read == size ? data : nil
        }
    }
}

private extension ShelfAndWelcomeTests.Checker {
    /// Notes which words this Mac's macOS uses for screenshot names (no check: they depend on the language).
    func notes(words: (prefix: String, pattern: String)) {
        check(!words.prefix.isEmpty && words.pattern.contains("%"), "macOS's own words for screenshot names are read",
              "“\(words.prefix)”, “\(words.pattern)”")
    }
}
#endif
