#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit

/// `--selftest results-shelf`: what a finished job shows, through `ResultsPresenter.hook` and stand-ins for its three
/// openers (no real shelf, line or Finder window opens). Covers the plain decision, which opener each choice reaches,
/// the Show Clothesline item and the real line on an offscreen controller, where the progress panel goes,
/// `JobRunner.report` (editors' Save), real jobs through `JobRunner.run` (a conversion, a failing input, Split's
/// parts, Zip), the command-line guard, and the panel a new shelf uses.
enum ResultsShelfTests {
    typealias Presentation = ResultsPresenter.Presentation

    /// Like AppShellTests.Checker, but the report lists every check, passed or not.
    final class Checker {
        private(set) var lines: [String] = []
        private(set) var failures = 0
        var notes: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if !ok { failures += 1 }
            lines.append(ok ? "  ok  \(name)" : "  ✗ \(name)\(detail().isEmpty ? "" : ": \(detail())")")
        }
        func report(_ title: String) -> String {
            let head = "\(failures == 0 ? "PASS" : "FAIL") \(title): \(lines.count - failures)/\(lines.count) checks passed"
            return ([head] + lines + notes.map { "  · \($0)" }).joined(separator: "\n")
        }
    }

    static func run() -> String {
        let c = Checker()
        let savedDefaults = Settings.defaults
        let savedHook = ResultsPresenter.hook
        let savedCanPresent = ResultsPresenter.canPresent
        let savedHUD = JobRunner.reportToHUD
        // In memory only; the progress panel stays hidden while jobs run (it is ordered out when this is off).
        Settings.defaults = SettingsMemoryStore(["showProgressHUD": false])
        var shown: [Presentation] = []
        var hud: [(saved: [URL], errors: [String])] = []
        ResultsPresenter.hook = { shown.append($0) }
        JobRunner.reportToHUD = { hud.append(($0, $1)) }
        defer {
            Settings.defaults = savedDefaults
            ResultsPresenter.hook = savedHook
            ResultsPresenter.canPresent = savedCanPresent
            JobRunner.reportToHUD = savedHUD
        }
        let shelvesBefore = ShelfManager.shared.shelves.count

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("YummyOrange results-shelf \(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            c.check("scratch folder", false, error.localizedDescription)
            return c.report("results-shelf")
        }
        func file(_ name: String) -> URL {
            let url = dir.appendingPathComponent(name)
            try? Data("YummyOrange \(name)".utf8).write(to: url)
            return url
        }
        let a = file("a.png"), b = file("b.txt"), d = file("d.pdf")
        func reset() { shown = []; hud = [] }

        // Command line, self-tests and snapshots: nothing opens (this process runs with the .prohibited policy).
        c.check("this self-test runs like the command line", NSApp.activationPolicy() == .prohibited && !ResultsPresenter.canPresent())
        JobRunner.report(saved: [a])
        c.check("command line: nothing opens, the HUD is still told", shown.isEmpty && hud.count == 1 && hud[0].saved == [a],
                "\(shown)")
        c.check("the menu-bar app (.accessory) shows results; only the command line (.prohibited) doesn't",
                ResultsPresenter.showsWindows(.accessory) && ResultsPresenter.showsWindows(.regular)
                && !ResultsPresenter.showsWindows(.prohibited))

        // In the app (as if: the policy check says yes).
        ResultsPresenter.canPresent = { true }
        c.check("default: On a Shelf", Settings.resultsDestination == .shelf)

        reset()
        JobRunner.report(saved: [a, b])
        c.check("a job with two files opens one new shelf with exactly those two", shown == [.shelf([a, b])], "\(shown)")
        c.check("the HUD still says what was saved", hud.count == 1 && hud[0].saved == [a, b] && hud[0].errors.isEmpty
                && HUD.finishText(saved: [a, b], errors: []) == "Saved 2 files" && HUD.finishText(saved: [a], errors: []) == "Saved a.png")

        reset()
        JobRunner.report(saved: [d, a, b])
        c.check("files keep the job's order", shown == [.shelf([d, a, b])], "\(shown)")

        reset()
        JobRunner.report(saved: [a])
        JobRunner.report(saved: [b, d])
        c.check("two jobs: two shelves, never one merged shelf", shown == [.shelf([a]), .shelf([b, d])], "\(shown)")

        reset()
        JobRunner.report(saved: [d], errors: ["e.pdf: Couldn’t read it."])
        c.check("errors and files: the shelf still shows what was made", shown == [.shelf([d])] && hud.first?.errors.count == 1,
                "\(shown)")
        c.check("the HUD names what was saved before the error",
                HUD.finishText(saved: [d], errors: ["e.pdf: Couldn’t read it."]) == "Saved 1. e.pdf: Couldn’t read it.")
        c.check("the banner: quick jobs stay silent by default, long ones show after 1.5 s, and asked-for work shows at once",
                HUD.revealDelay(always: false, showProgress: false) == 1.5 && HUD.revealDelay(always: false, showProgress: true) == 0
                && HUD.revealDelay(always: true, showProgress: false) == 0
                && HUD.finishLines(saved: [], errors: ["x"], job: "Compress").title == "Compress didn’t finish")

        reset()
        JobRunner.report(saved: [], errors: ["Couldn’t read it."])
        JobRunner.report(saved: [])
        JobRunner.report(saved: [dir.appendingPathComponent("gone.png")])
        c.check("no files (failed, empty, or no longer there): no shelf", shown.isEmpty && hud.count == 3, "\(shown)")

        reset()
        JobRunner.report(saved: [a, a, URL(fileURLWithPath: dir.path + "/./a.png")])
        c.check("a file listed twice is shown once", shown == [.shelf([a])], "\(shown)")

        // The other choices.
        reset()
        Settings.resultsDestination = .finder
        JobRunner.report(saved: [a, b])
        c.check("In Finder: the Finder reveal gets the job's files, no shelf", shown == [.finder([a, b])], "\(shown)")
        reset()
        Settings.resultsDestination = .clothesline
        JobRunner.report(saved: [a, b])
        JobRunner.report(saved: [d])
        c.check("On the Clothesline: each job's files go to the line, in order, no shelf",
                shown == [.clothesline([a, b]), .clothesline([d])], "\(shown)")
        reset()
        Settings.resultsDestination = .none
        JobRunner.report(saved: [a, b])
        c.check("Don't Show: nothing opens, the HUD is still told", shown.isEmpty && hud.count == 1, "\(shown)")
        c.check("the decision itself", ResultsPresenter.presentation(for: [a], destination: .shelf) == .shelf([a])
                && ResultsPresenter.presentation(for: [a], destination: .finder) == .finder([a])
                && ResultsPresenter.presentation(for: [a, a], destination: .clothesline) == .clothesline([a])
                && ResultsPresenter.presentation(for: [], destination: .clothesline) == nil
                && ResultsPresenter.presentation(for: [a], destination: ResultsDestination.none) == nil
                && ResultsPresenter.presentation(for: [], destination: .shelf) == nil)
        Settings.resultsDestination = .shelf

        // Past the hook: each choice reaches its own opener (stand-ins here, so no real shelf or Finder window).
        do {
            let savedOpen = ResultsPresenter.openShelf, savedReveal = ResultsPresenter.revealInFinder
            let savedHang = ResultsPresenter.hangOnLine
            var opened: [[URL]] = [], revealed: [[URL]] = [], hung: [[URL]] = []
            ResultsPresenter.hook = nil
            ResultsPresenter.openShelf = { opened.append($0) }
            ResultsPresenter.revealInFinder = { revealed.append($0) }
            ResultsPresenter.hangOnLine = { hung.append($0) }
            defer {
                ResultsPresenter.openShelf = savedOpen
                ResultsPresenter.revealInFinder = savedReveal
                ResultsPresenter.hangOnLine = savedHang
                ResultsPresenter.hook = { shown.append($0) }
                Settings.resultsDestination = .shelf
            }
            JobRunner.report(saved: [b, a])
            c.check("On a Shelf opens a new shelf with the job's files (and no Finder window or line)",
                    opened == [[b, a]] && revealed.isEmpty && hung.isEmpty, "shelf \(opened), Finder \(revealed), line \(hung)")
            opened = []; revealed = []
            Settings.resultsDestination = .clothesline
            JobRunner.report(saved: [b, a])
            c.check("On the Clothesline hangs the job's files on the line (and opens no shelf or Finder window)",
                    hung == [[b, a]] && opened.isEmpty && revealed.isEmpty, "shelf \(opened), Finder \(revealed), line \(hung)")
            hung = []
            opened = []; revealed = []
            Settings.resultsDestination = .finder
            JobRunner.report(saved: [d])
            c.check("In Finder selects the job's files in Finder (and opens no shelf)",
                    revealed == [[d]] && opened.isEmpty, "shelf \(opened), Finder \(revealed)")
            opened = []; revealed = []
            Settings.resultsDestination = .none
            JobRunner.report(saved: [d])
            c.check("Don't Show calls none of them", opened.isEmpty && revealed.isEmpty && hung.isEmpty,
                    "shelf \(opened), Finder \(revealed), line \(hung)")
        }

        // Show Clothesline in the menu-bar menu, and turning the line off when another place is chosen.
        do {
            let savedFiles = ClotheslineMenuTarget.lineFiles, savedOff = ClotheslineMenuTarget.turnOffLine
            let savedReveal = ClotheslineMenuTarget.revealLine, savedHas = ClotheslineMenuTarget.lineHasFiles
            let savedRestore = ClotheslineMenuTarget.restoreLine
            var lineFiles: [URL] = [], offs = 0, reveals = 0, restored: [[URL]] = []
            ClotheslineMenuTarget.lineFiles = { lineFiles }
            ClotheslineMenuTarget.lineHasFiles = { !lineFiles.isEmpty }
            ClotheslineMenuTarget.turnOffLine = { offs += 1; lineFiles = [] }
            ClotheslineMenuTarget.revealLine = { reveals += 1 }
            ClotheslineMenuTarget.restoreLine = { restored.append($0); lineFiles = $0 }
            defer {
                ClotheslineMenuTarget.lineFiles = savedFiles
                ClotheslineMenuTarget.lineHasFiles = savedHas
                ClotheslineMenuTarget.turnOffLine = savedOff
                ClotheslineMenuTarget.revealLine = savedReveal
                ClotheslineMenuTarget.restoreLine = savedRestore
                Settings.resultsDestination = .shelf
            }
            let menu = AppDelegate.makeMenu(target: nil)
            let item = menu.items.first { $0.title == ClotheslineMenuTarget.title }
            c.check("the menu-bar menu has Show Clothesline, with a target and an explanation",
                    item?.target === ClotheslineMenuTarget.shared && item?.action != nil && !(item?.toolTip ?? "").isEmpty,
                    menu.items.map(\.title).joined(separator: " | "))
            if let item {
                Settings.resultsDestination = .clothesline
                let emptyEnabled = ClotheslineMenuTarget.shared.validateMenuItem(item)
                let emptyDrawn = MenuSnapshotView.isDrawnEnabled(item, in: menu)
                lineFiles = [a]
                let fullEnabled = ClotheslineMenuTarget.shared.validateMenuItem(item)
                let fullDrawn = MenuSnapshotView.isDrawnEnabled(item, in: menu)
                c.check("Show Clothesline is dimmed while the line is empty, and available once it holds files",
                        !emptyEnabled && fullEnabled)
                // `--snapshot menu` draws what the live menu shows (AppKit asks the target before opening it).
                let others = menu.items.filter { ["Launch at Login", "Settings…", ResultsMenu.title].contains($0.title) }
                c.check("the menu snapshot draws Show Clothesline dimmed while the line is empty (as the real menu does), "
                        + "and still draws Launch at Login, Settings… and Show New Files available",
                        !emptyDrawn && fullDrawn && others.count == 3 && others.allSatisfy { MenuSnapshotView.isDrawnEnabled($0, in: menu) },
                        "empty \(emptyDrawn), full \(fullDrawn), others \(others.map { "\($0.title) \(MenuSnapshotView.isDrawnEnabled($0, in: menu))" })")
                menu.performActionForItem(at: menu.index(of: item))
                c.check("choosing it drops the line", reveals == 1, "\(reveals) reveals")
            }
            lineFiles = [a]
            Settings.resultsDestination = .clothesline
            ClotheslineMenuTarget.settingsChanged()
            c.check("staying On the Clothesline (another setting changed) keeps the line", offs == 0 && lineFiles == [a] && restored.isEmpty)
            for choice in [ResultsDestination.shelf, .finder, .none] {
                offs = 0; lineFiles = [a]
                Settings.resultsDestination = choice
                ClotheslineMenuTarget.settingsChanged()
                c.check("choosing \(choice.title) turns the line off", offs == 1 && lineFiles.isEmpty, "\(offs) turn-offs")
            }
            // Trying another place and coming back keeps the line's files.
            Settings.resultsDestination = .clothesline
            ClotheslineMenuTarget.settingsChanged()
            restored = []
            lineFiles = [b, a]
            Settings.resultsDestination = .finder
            ClotheslineMenuTarget.settingsChanged()
            Settings.resultsDestination = .shelf          // a second change away keeps what was put aside
            ClotheslineMenuTarget.settingsChanged()
            let away = lineFiles
            Settings.resultsDestination = .clothesline
            ClotheslineMenuTarget.settingsChanged()
            ClotheslineMenuTarget.settingsChanged()       // another setting changed: nothing hung twice
            c.check("choosing In Finder, then On a Shelf, then On the Clothesline again hangs the line's files back, in order, once",
                    away.isEmpty && restored == [[b, a]] && lineFiles == [b, a] && ClotheslineMenuTarget.parked.isEmpty,
                    "away \(away), restored \(restored)")
            lineFiles = []
            restored = []
            Settings.resultsDestination = .finder
            ClotheslineMenuTarget.settingsChanged()
            Settings.resultsDestination = .clothesline
            ClotheslineMenuTarget.settingsChanged()
            c.check("a line emptied with Clear Line stays empty when you come back", restored.isEmpty, "\(restored)")
        }

        realLine(c, dir: dir, file: file)
        hudPlacement(c)

        // Float opens its own shelf and returns no files, so a Float job never opens a second one.
        if let float = Registry.commands.first(where: { $0.id == "float" }) {
            reset()
            let outs = (try? float.run?([a, b], [:], { _ in })) ?? nil
            JobRunner.report(saved: outs ?? [])
            c.check("Float: its own shelf (present), no files returned, so no second shelf",
                    float.present != nil && outs?.isEmpty == true && shown.isEmpty, "\(String(describing: outs)) \(shown)")
        } else {
            c.check("Float is registered", false)
        }

        realJobs(c, dir: dir, shown: { shown }, hud: { hud }, reset: reset)

        // The panel a new shelf opens in: holds exactly the files, in order; floats on the current Space (it
        // joins every Space and full-screen apps) without activating YummyOrange. Built here but never shown.
        let shelf = ShelfController(files: [d, a, b], mode: .stack)
        c.check("a shelf made from a job's files holds exactly them, in order",
                shelf.model.urls == [d, a, b].map(\.standardizedFileURL), shelf.model.urls.map(\.lastPathComponent).joined(separator: ", "))
        let p = shelf.panel
        c.check("the shelf panel shows on the current Space while another app is active",
                p.collectionBehavior.contains(.canJoinAllSpaces) && p.collectionBehavior.contains(.fullScreenAuxiliary)
                && p.styleMask.contains(.nonactivatingPanel) && !p.hidesOnDeactivate && p.level == .floating)
        c.check("no real shelf was opened by this test", ShelfManager.shared.shelves.count == shelvesBefore)
        return c.report("results-shelf")
    }

    /// The real line on an offscreen controller (no panel, display link or pointer monitors): the defaults behind
    /// each stand-in above, the Settings observer appDidLaunch adds, and Show Clothesline once the files are gone.
    private static func realLine(_ c: Checker, dir: URL, file: (String) -> URL) {
        var now = 1000.0
        let engine = ClotheslineEngine(geometry: .builtInSample, time: now)
        let surface = ClotheslineOffscreenSurface(engine: engine)
        let ctl = ClotheslineController(engine: engine, surface: surface, clock: ClotheslineManualClock(), now: { now })
        ctl.usesTimers = false
        func frames(_ seconds: Double) { for _ in 0..<Int((seconds * 60).rounded()) { now += 1.0 / 60; ctl.tick(at: now) } }
        let line = Clothesline.shared
        let savedController = line.controller, savedHook = ResultsPresenter.hook
        line.controller = ctl
        ResultsPresenter.hook = nil
        defer {
            ClotheslineMenuTarget.stopObservingSettings()
            line.controller = savedController
            ResultsPresenter.hook = savedHook
            Settings.resultsDestination = .shelf
        }
        // The app's launch hook adds the observer (DW_SELFCHECK_LINE would also hang files 0.5 s later: not here).
        if ProcessInfo.processInfo.environment["DW_SELFCHECK_LINE"] == nil {
            ClotheslineModule.appDidLaunch()
        } else {
            ClotheslineMenuTarget.observeSettings()
        }
        c.check("the app's launch hook watches Settings for the line", ClotheslineMenuTarget.settingsObserver != nil)
        // The real screenshot watcher would list the real Desktop and read the real clipboard's change count as soon as
        // the line is chosen below: in a self-test the launch hook leaves it alone.
        let screenshots = ClotheslineScreenshots.shared.isFollowingSettings
        if screenshots { ClotheslineScreenshots.shared.stop() }
        c.check("in a self-test the launch hook doesn't start watching screenshots (the real Desktop and clipboard stay untouched)",
                !screenshots && !ClotheslineScreenshots.shared.isWatching)
        guard let item = AppDelegate.makeMenu(target: nil).items.first(where: { $0.title == ClotheslineMenuTarget.title }) else {
            c.check("Show Clothesline is in the menu", false)
            return
        }
        let p = file("line-p.png"), q = file("line-q.txt")
        Settings.resultsDestination = .clothesline
        JobRunner.report(saved: [p, q])
        c.check("On the Clothesline a job's files reach the real line, and Show Clothesline is available",
                line.files == [p, q] && surface.isShown && ClotheslineMenuTarget.shared.validateMenuItem(item),
                "line \(line.files.map(\.lastPathComponent)), shown \(surface.isShown)")
        frames(4.5)
        let hidden = engine.state == .hidden
        ClotheslineMenuTarget.shared.showLine()
        c.check("choosing Show Clothesline drops the real line and tells VoiceOver how many files it holds",
                hidden && engine.state == .revealing && surface.view.lastAnnouncement == "Clothesline, 2 files",
                "hidden before \(hidden), now \(engine.state.rawValue), heard \(surface.view.lastAnnouncement ?? "nothing")")
        frames(1)
        Settings.resultsDestination = .finder       // posts Settings.didChange; the observer runs at once
        c.check("choosing In Finder turns the real line off through the observer (empty, ordered out, Show Clothesline dimmed)",
                line.files.isEmpty && !surface.isShown && !ClotheslineMenuTarget.shared.validateMenuItem(item)
                && ClotheslineMenuTarget.parked == [p, q], "line \(line.files.count), shown \(surface.isShown)")
        Settings.resultsDestination = .clothesline
        c.check("choosing On the Clothesline again hangs the same files back on the real line, in order",
                line.files == [p, q] && surface.isShown && ClotheslineMenuTarget.parked.isEmpty,
                "\(line.files.map(\.lastPathComponent))")
        frames(4.5)
        // Deleted files stay on the line until it next drops (that takes them off), so the item asks the disk.
        try? FileManager.default.removeItem(at: p)
        try? FileManager.default.removeItem(at: q)
        let available = ClotheslineMenuTarget.shared.validateMenuItem(item)
        c.check("every file on the line deleted: Show Clothesline is dimmed, and asking takes nothing off the line",
                !available && engine.items.count == 2 && engine.state == .hidden, "available \(available), \(engine.items.count) on the line")
        let r = file("line-r.txt")
        JobRunner.report(saved: [r])
        frames(4.5)
        try? FileManager.default.moveItem(at: r, to: dir.appendingPathComponent("line-r renamed.txt"))
        c.check("a file renamed after it was hung is followed: Show Clothesline stays available",
                ClotheslineMenuTarget.shared.validateMenuItem(item) && engine.items.count == 1)
        line.turnOff()
    }

    /// On the Clothesline the progress panel goes under the cards: the line drops at the end of every job, at the
    /// same window level, and its cards would otherwise cover "Saved…" and the errors in the top-right corner.
    private static func hudPlacement(_ c: Checker) {
        let g = ClotheslineGeometry.builtInSample
        let vis = CGRect(x: 0, y: 0, width: g.screenFrame.width, height: g.screenFrame.height - g.menuBarHeight)
        let size = CGSize(width: 320, height: 62)
        let corner = HUD.origin(size: size, visibleFrame: vis, line: nil)
        let under = HUD.origin(size: size, visibleFrame: vis, line: g)
        /// The panel in the line's scene coordinates (top-left origin, y down).
        func scene(_ o: CGPoint) -> CGRect {
            CGRect(x: o.x - g.screenFrame.minX, y: g.screenFrame.maxY - o.y - size.height, width: size.width, height: size.height)
        }
        // A full line: 50 files with wide and narrow cards, dropping and swinging, hovered, flung to the end and back.
        let e = ClotheslineEngine(geometry: g)
        e.fileExists = { _ in true }
        e.holdOpen = true
        let urls = (0..<50).map { URL(fileURLWithPath: "/tmp/results-shelf-hud-\($0).png") }
        e.widthFor = { url in [170, 112, 146][(urls.firstIndex(of: url) ?? 0) % 3] }
        e.hang(urls)
        var lowest: CGFloat = 0, overCorner = false, overUnder = false
        func run(_ steps: Int) {
            for i in 0..<steps {
                e.step(ClotheslineEngine.substep)
                guard i % 2 == 0 else { continue }
                for pose in e.poses where pose.alpha > 0.02 {
                    let b = ClotheslineEngine.bounds(pose)
                    lowest = max(lowest, b.maxY)
                    if b.intersects(scene(corner)) { overCorner = true }
                    if b.intersects(scene(under)) { overUnder = true }
                }
            }
        }
        run(5 * 240)
        for x in stride(from: 1400.0, through: 1720, by: 40) { e.pointerMoved(to: CGPoint(x: x, y: 120)); run(24) }
        for direction in [1.0, -1.0] {
            e.pointerMoved(to: CGPoint(x: 900, y: 120))
            e.scroll(.init(phase: .began, delta: 0, time: e.time))
            for _ in 0..<12 { e.scroll(.init(phase: .changed, delta: 120 * direction, time: e.time)); run(2) }
            e.scroll(.init(phase: .ended, delta: 0, time: e.time))
            run(4 * 240)
        }
        c.check("without the Clothesline the progress panel sits in the top-right corner, 12 pt under the menu bar",
                corner == CGPoint(x: vis.maxX - 16 - size.width, y: vis.maxY - 12 - size.height), "\(corner)")
        c.check("On the Clothesline it sits under the cards: a full line (50 files, swinging, hovered, scrolled) covers the "
                + "corner but never the panel", overCorner && !overUnder && scene(under).minY >= lowest + 4,
                "cards reach \(Int(lowest)) pt from the top, the panel starts at \(Int(scene(under).minY)) pt")
        let savedDestination = Settings.resultsDestination
        defer { Settings.resultsDestination = savedDestination }
        if let lineScreen = ClotheslineGeometry.preferredScreen() {
            Settings.resultsDestination = .shelf
            let away = NSScreen.screens.allSatisfy { HUD.line(on: $0) == nil }
            Settings.resultsDestination = .clothesline
            let here = NSScreen.screens.filter { HUD.line(on: $0) != nil }.map(\.frame)
            c.check("… only on the display the line hangs on, and only while new files go to it",
                    away && here == [lineScreen.frame], "\(here)")
        }
    }

    /// Real jobs through `JobRunner.run` (background thread, then `finish` on the main thread).
    private static func realJobs(_ c: Checker, dir: URL, shown: () -> [Presentation],
                                 hud: () -> [(saved: [URL], errors: [String])], reset: () -> Void) {
        guard let fixtures = MediaTestSupport.fixturesFolder() else {
            c.check("fixtures (Tests/fixtures/features)", false, "not found; run from the project folder or set DW_FIXTURES")
            return
        }
        let fm = FileManager.default
        for name in ["photo.png", "clip.mp4"] {
            try? fm.copyItem(at: fixtures.appendingPathComponent(name), to: dir.appendingPathComponent(name))
        }
        let photo = dir.appendingPathComponent("photo.png"), clip = dir.appendingPathComponent("clip.mp4")
        let broken = dir.appendingPathComponent("broken.png")
        try? Data("not a picture".utf8).write(to: broken)

        /// Runs one job and waits (up to `limit` seconds) for what it shows.
        func job(_ op: Operation, _ files: [URL], limit: TimeInterval = 60) -> (shown: [Presentation], hud: [(saved: [URL], errors: [String])]) {
            reset()
            JobRunner.run(op, on: files)
            let end = Date().addingTimeInterval(limit)
            while hud().isEmpty && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            return (shown(), hud())
        }

        func size(_ url: URL) -> String {
            ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map { "\($0) bytes" } ?? "missing"
        }
        var r = job(.convert(.jpg), [photo])
        let jpg = r.hud.first?.saved ?? []
        c.notes.append("convert photo.png → \(jpg.map { "\($0.lastPathComponent) (\(size($0)))" }.joined(separator: ", ")); shown: \(r.shown.count) shelf")
        c.check("a real conversion: one new shelf with the JPG it made",
                jpg.count == 1 && jpg[0].pathExtension == "jpg" && fm.fileExists(atPath: jpg[0].path) && r.shown == [.shelf(jpg)],
                "\(r.shown)")

        r = job(.convert(.jpg), [photo, broken])
        let made = r.hud.first?.saved ?? []
        c.notes.append("convert photo.png + broken.png → \(made.map(\.lastPathComponent)), errors: \(r.hud.first?.errors ?? [])")
        c.check("a conversion where one file fails: the shelf has the file that was made",
                made.count == 1 && r.hud.first?.errors.count == 1 && r.shown == [.shelf(made)], "\(r.shown) \(r.hud.first?.errors ?? [])")

        if let split = Registry.commands.first(where: { $0.id == "split" }), FFmpeg.shared != nil {
            r = job(.command(split, ["parts": "3"]), [clip], limit: 120)
            let parts = r.hud.first?.saved ?? []
            let ff = FFmpeg.shared
            c.notes.append("split clip.mp4 parts=3 → " + parts.map { p in
                "\(p.lastPathComponent) \(ff?.probe(p).duration.map { String(format: "%.2f s", $0) } ?? "?")" }.joined(separator: ", "))
            c.check("Split: one shelf with its three parts, in order",
                    parts.count == 3 && parts.map(\.lastPathComponent) == ["clip part 1.mp4", "clip part 2.mp4", "clip part 3.mp4"]
                    && r.shown == [.shelf(parts)], "\(parts.map(\.lastPathComponent)) \(r.shown)")
        } else {
            c.notes.append("Split skipped: no ffmpeg or no split command")
        }

        if let zip = Registry.command(.actions, named: "zip", files: [photo, clip]) {
            r = job(.command(zip, [:]), [photo, clip])
            let archive = r.hud.first?.saved ?? []
            c.notes.append("zip photo.png + clip.mp4 → \(archive.map { "\($0.lastPathComponent) (\(size($0)))" }.joined(separator: ", "))")
            c.check("Zip (one job for both files): one shelf with the archive",
                    archive.count == 1 && archive[0].pathExtension == "zip" && r.shown == [.shelf(archive)], "\(r.shown)")
        } else {
            c.check("Zip is registered", false)
        }
    }
}
#endif
