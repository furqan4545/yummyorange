#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import ObjectiveC
import QuartzCore
import ServiceManagement

/// `--selftest menu-latency`: what runs on the main thread while the menu-bar menu opens and while it is open. AppKit
/// shows the menu only once the submenus' `menuNeedsUpdate`, its validation of every item and `menuWillOpen` have
/// returned, and timers in the common modes keep firing while the menu is tracked, so each has a budget:
///   - opening the menu: no Launch at Login status read on the main thread (SMAppService took 5 to 20 ms a read), no
///     image lookup that misses (each one opens the app's asset catalog, which YummyOrange doesn't have, and logs two
///     CoreUI errors), no LaunchServices lookup; a median under 1 ms and a p95 under 5 ms;
///   - building the menu (at launch) under 5 ms once warm, and laying it out under 5 ms after the launch warm-up;
///   - the Settings window (Settings…) builds with no status read on the main thread and no lookup that misses (it
///     made 24, logged as the burst of 48 CoreUI errors);
///   - one tick of each main-thread timer (the drag poll at 20 Hz, the hold-key permission poll every 2 s, the
///     clipboard-screenshot poll at 10 Hz, the updater's, the update notice's moment check, the Clothesline's press
///     poll and pointer handler with 16 cards): a median under 0.2 ms and a p95 under 1 ms;
///   - the hold-key tap follows Finder's pid through NSWorkspace's notifications, with no lookup per poll;
///   - a click on the menu-bar icon (the drag monitor's press, before the menu opens): a median under 1 ms, a p95 under
///     5 ms, with the Dock's preferences read again each time;
///   - once Settings was opened and closed, a change of the updater or the login status costs the open menu nothing
///     (its tabs re-rendered for 10 to 17 ms);
///   - Show Clothesline's validation with 50 cards whose files are all in the Trash, and no look at other volumes.
/// No SMAppService status read happens on the main thread at all (counted with a swizzle, not only timed: from the
/// project folder a read takes 0.2 ms, from elsewhere 20 to 80). A real one is timed off the main thread and reported.
///
/// Settings live in memory, the Launch at Login status comes from a stand-in, nothing is registered with macOS, and no
/// event tap, window on screen or real clipboard is involved.
enum MenuLatencyTests {
    typealias Checker = ResultsShelfTests.Checker

    static func run() -> String {
        let c = Checker()
        let savedDefaults = Settings.defaults
        let savedRead = LaunchAtLogin.readStatus
        let savedMenuUpdater = UpdateMenuTarget.shared.updater
        // The person's setup: new files on the Clothesline (its submenu entry looks at the displays).
        Settings.defaults = SettingsMemoryStore(["resultsDestination": ResultsDestination.clothesline.rawValue])
        defer {
            Settings.defaults = savedDefaults
            LaunchAtLogin.readStatus = savedRead
            UpdateMenuTarget.shared.updater = savedMenuUpdater
        }
        Probe.install()
        let status = StatusStandIn()
        LaunchAtLogin.readStatus = { status.read() }
        // With an update known, so the menu has every row it can have.
        let updater = UpdaterTests.idleUpdater()
        updater.latest = UpdaterTests.item(version: "1.0.1", build: "2")
        UpdateMenuTarget.shared.updater = updater

        statusProbe(c)
        menu(c, status)
        settingsWindow(c, status)
        settingsClosed(c)
        timers(c)
        press(c)
        clotheslineValidation(c)
        finderPID(c)
        realStatusRead(c)
        return c.report("menu-latency")
    }

    // MARK: Counting

    /// Counts from swizzled methods: image lookups by name that found nothing (each opens the app's asset catalog),
    /// asset catalogs opened for the app's own bundle, and running-application lookups by bundle identifier.
    enum Probe {
        private static let lock = NSLock()
        private static var missedNames: [String] = []
        private static var catalogOpens = 0
        private static var appLookups = 0
        private static var statusOnMain = 0
        private static var installed = false

        struct Counts: Equatable {
            var misses = 0, catalogs = 0, lookups = 0, statusReads = 0
            static func - (a: Counts, b: Counts) -> Counts {
                Counts(misses: a.misses - b.misses, catalogs: a.catalogs - b.catalogs, lookups: a.lookups - b.lookups,
                       statusReads: a.statusReads - b.statusReads)
            }
        }

        static var counts: Counts {
            lock.lock(); defer { lock.unlock() }
            return Counts(misses: missedNames.count, catalogs: catalogOpens, lookups: appLookups, statusReads: statusOnMain)
        }

        static func misses(since start: Counts) -> [String] {
            lock.lock(); defer { lock.unlock() }
            return Array(missedNames.dropFirst(start.misses))
        }

        private static func count(_ body: () -> Void) { lock.lock(); body(); lock.unlock() }

        static func install() {
            guard !installed else { return }
            installed = true
            typealias Lookup = @convention(c) (UnsafeRawPointer?, Selector, UnsafeRawPointer?) -> UnsafeRawPointer?
            let named = NSSelectorFromString("imageNamed:")
            if let m = class_getClassMethod(NSImage.self, named) {
                let original = unsafeBitCast(method_getImplementation(m), to: Lookup.self)
                let replacement: @convention(block) (UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer? = { cls, name in
                    let image = original(cls, named, name)
                    if image == nil {
                        let text = name.map { Unmanaged<NSString>.fromOpaque($0).takeUnretainedValue() as String } ?? "nil"
                        count { missedNames.append(text) }
                    }
                    return image
                }
                method_setImplementation(m, imp_implementationWithBlock(replacement))
            }
            let running = NSSelectorFromString("runningApplicationsWithBundleIdentifier:")
            if let m = class_getClassMethod(NSRunningApplication.self, running) {
                let original = unsafeBitCast(method_getImplementation(m), to: Lookup.self)
                let replacement: @convention(block) (UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer? = { cls, id in
                    count { appLookups += 1 }
                    return original(cls, running, id)
                }
                method_setImplementation(m, imp_implementationWithBlock(replacement))
            }
            // -[SMAppService status] on the main thread, however it is reached (LaunchAtLogin.readStatus or directly).
            let status = NSSelectorFromString("status")
            if let m = class_getInstanceMethod(SMAppService.self, status) {
                typealias Getter = @convention(c) (UnsafeRawPointer?, Selector) -> Int
                let original = unsafeBitCast(method_getImplementation(m), to: Getter.self)
                let replacement: @convention(block) (UnsafeRawPointer?) -> Int = { me in
                    if Thread.isMainThread { count { statusOnMain += 1 } }
                    return original(me, status)
                }
                method_setImplementation(m, imp_implementationWithBlock(replacement))
            }
            // CoreUI's catalog (private): counted only for the app's own bundle, the one without an Assets.car.
            let open = NSSelectorFromString("initWithName:fromBundle:error:")
            if let cls = NSClassFromString("CUICatalog"), let m = class_getInstanceMethod(cls, open) {
                typealias Open = @convention(c) (UnsafeRawPointer?, Selector, UnsafeRawPointer?, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> UnsafeRawPointer?
                let original = unsafeBitCast(method_getImplementation(m), to: Open.self)
                let main = Unmanaged.passUnretained(Bundle.main).toOpaque()
                let replacement: @convention(block) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> UnsafeRawPointer? = { me, name, bundle, error in
                    if bundle == UnsafeRawPointer(main) { count { catalogOpens += 1 } }
                    return original(me, open, name, bundle, error)
                }
                method_setImplementation(m, imp_implementationWithBlock(replacement))
            }
        }
    }

    /// The Launch at Login status as `LaunchAtLogin.readStatus` reads it, counting reads and those on the main thread.
    final class StatusStandIn {
        private let lock = NSLock()
        private var value: SMAppService.Status = .notRegistered
        private var reads = 0, onMain = 0
        func read() -> SMAppService.Status {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            if Thread.isMainThread { onMain += 1 }
            return value
        }
        func set(_ status: SMAppService.Status) { lock.lock(); value = status; lock.unlock() }
        var counts: (reads: Int, onMain: Int) { lock.lock(); defer { lock.unlock() }; return (reads, onMain) }
    }

    // MARK: Timing

    struct Timing {
        let median: Double, p95: Double, max: Double
        var text: String { String(format: "median %.3f ms, p95 %.3f, max %.3f", median, p95, max) }
    }

    /// Runs `body` `n` times (after one warm-up run unless `warm` is false) and gives the times in milliseconds.
    static func time(_ n: Int, warm: Bool = true, _ body: () -> Void) -> Timing {
        if warm { body() }
        var ms: [Double] = []
        ms.reserveCapacity(n)
        for _ in 0..<n {
            let t0 = CACurrentMediaTime()
            body()
            ms.append((CACurrentMediaTime() - t0) * 1000)
        }
        ms.sort()
        return Timing(median: ms[ms.count / 2], p95: ms[min(ms.count - 1, Int(Double(ms.count) * 0.95))], max: ms.last ?? 0)
    }

    /// Lets queued work finish: the status reads' main-thread completions.
    static func drain(_ seconds: TimeInterval = 0.2) { UpdaterTests.spin(until: { false }, timeout: seconds) }

    /// The longest stretch the main run loop spends busy (from waking to waiting again) while it runs in `mode` for
    /// `seconds`, `kick` included (it runs first, inside the measurement), in milliseconds. A timer in the common
    /// modes keeps the run loop turning, as the menu's own tracking does.
    static func longestBusyStretch(in mode: RunLoop.Mode, for seconds: TimeInterval, _ kick: () -> Void) -> Double {
        var longest = 0.0
        var start = CACurrentMediaTime()
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { _, activity in
            let now = CACurrentMediaTime()
            switch activity {
            case .entry, .afterWaiting: start = now
            case .beforeWaiting, .exit: longest = max(longest, now - start); start = now
            default: break
            }
        }
        let cfMode = CFRunLoopMode(mode.rawValue as CFString)
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, cfMode)
        let turn = Timer(timeInterval: 0.005, repeats: true) { _ in }
        RunLoop.main.add(turn, forMode: .common)
        let t0 = CACurrentMediaTime()
        kick()
        longest = max(longest, CACurrentMediaTime() - t0)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.02)) }
        turn.invalidate()
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, cfMode)
        return longest * 1000
    }

    /// The swizzle sees a status read on the main thread (so a zero below means none happened).
    static func statusProbe(_ c: Checker) {
        let before = Probe.counts.statusReads
        _ = SMAppService.mainApp.status
        let onMain = Probe.counts.statusReads - before
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = SMAppService.mainApp.status; done.signal() }
        done.wait()
        let offMain = Probe.counts.statusReads - before - onMain
        c.check("the probe counts SMAppService status reads on the main thread (one here), not those off it",
                onMain == 1 && offMain == 0, "\(onMain) on the main thread, \(offMain) off it")
    }

    // MARK: The menu

    /// What AppKit runs on the main thread as the menu opens, before it shows it.
    static func open(_ menu: NSMenu) {
        for item in menu.items {
            guard let sub = item.submenu else { continue }
            sub.delegate?.menuNeedsUpdate?(sub)
            sub.update()
        }
        menu.update()
        AppDelegate.willOpen(menu)
    }

    static func menu(_ c: Checker, _ status: StatusStandIn) {
        let start = Probe.counts
        let readsBefore = status.counts
        let cold = time(1, warm: false) { _ = AppDelegate.makeMenu(target: nil) }
        let menu = AppDelegate.makeMenu(target: nil)
        let coldLayout = time(1, warm: false) { _ = menu.size }   // the app does this right after launch
        let coldOpen = time(1, warm: false) { open(menu) }
        let coldCounts = Probe.counts - start
        c.check("the first build, layout and open look up no image that isn’t there (no asset-catalog open, no CoreUI error)",
                coldCounts.misses == 0 && coldCounts.catalogs == 0,
                "\(coldCounts.misses) misses \(Probe.misses(since: start)), \(coldCounts.catalogs) catalog opens")
        c.notes.append("cold (once per launch): build \(String(format: "%.1f", cold.median)) ms, first layout \(String(format: "%.1f", coldLayout.median)) ms, first open \(String(format: "%.2f", coldOpen.median)) ms")

        let warm = Probe.counts
        let build = time(30) { _ = AppDelegate.makeMenu(target: nil) }
        let layout = time(50) { _ = menu.size }
        let opens = time(50) { open(menu) }
        drain()
        let counts = Probe.counts - warm
        let reads = status.counts
        c.check("opening the menu reads the Launch at Login status only off the main thread (once per open, without waiting for it)",
                reads.onMain == 0 && reads.reads - readsBefore.reads >= 50, "\(reads.reads - readsBefore.reads) reads, \(reads.onMain) on the main thread")
        c.check("opening the menu: no image lookup that misses, no asset-catalog open, no LaunchServices lookup, no SMAppService status read on the main thread",
                counts == Probe.Counts(), "\(counts.misses) misses \(Probe.misses(since: warm).prefix(6)), \(counts.catalogs) catalog opens, \(counts.lookups) app lookups, \(counts.statusReads) status reads")
        c.check("opening the menu takes a median under 1 ms and a p95 under 5 ms on the main thread", opens.median < 1 && opens.p95 < 5, opens.text)
        c.check("building the menu (at launch) takes under 5 ms once warm", build.median < 5, build.text)
        c.check("laying it out takes under 5 ms once warm (the app warms it up right after launch)", layout.median < 5 && layout.p95 < 5, layout.text)
        c.notes.append("open \(opens.text); build \(build.text); layout \(layout.text)")

        // The checkmark follows a change made in System Settings: shown from the last read, fixed when the read is back.
        let login = menu.items.first { $0.title == "Launch at Login" }
        var changes = 0
        let observer = NotificationCenter.default.addObserver(forName: LaunchAtLogin.didChange, object: nil, queue: nil) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        status.set(.enabled)
        AppDelegate.willOpen(menu)
        let atOnce = login?.state
        drain()
        c.check("Launch at Login turned on in System Settings: the open menu shows the last status at once, then the new one",
                atOnce == .off && login?.state == .on && LaunchAtLogin.isEnabled && changes == 1, "at once \(String(describing: atOnce)), then \(String(describing: login?.state)), \(changes) changes")
        status.set(.requiresApproval)
        LaunchAtLogin.refresh()
        drain()
        // (Run as a bare executable, Settings says Launch at Login needs the app instead.)
        c.check("…waiting for approval in Login Items: unchecked, and Settings says where to allow it",
                !LaunchAtLogin.isEnabled && changes == 2
                && (Bundle.main.bundleIdentifier == nil || LaunchAtLogin.note?.contains("Login Items") == true),
                "changes \(changes), note \(LaunchAtLogin.note ?? "none")")
        status.set(.notRegistered)
        LaunchAtLogin.refresh()
        drain()

        // The update item is set when the updater changes, never as the menu opens (a menu that grows a row as it
        // opens can leave the highlight a row off).
        let update = menu.item(withTag: UpdateMenu.updateTag)
        UpdateMenuTarget.shared.updater.latest = nil
        let before = (update?.isHidden, MenuSnapshotView(menu: menu, open: nil).frame.size)
        open(menu)
        let after = (update?.isHidden, MenuSnapshotView(menu: menu, open: nil).frame.size)
        c.check("opening the menu leaves its rows alone (the update row follows the updater, not the open)",
                before.0 == after.0 && before.1 == after.1 && update?.isHidden == false, "\(before) → \(after)")
        AppDelegate.didClose(menu)
        UpdateMenuTarget.shared.updater.latest = UpdaterTests.item(version: "1.0.1", build: "2")
    }

    // MARK: Settings…

    static func settingsWindow(_ c: Checker, _ status: StatusStandIn) {
        func build() {
            let tabs = SettingsTabViewController()
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            for item in tabs.tabViewItems {
                guard let view = item.viewController?.view else { continue }
                view.layoutSubtreeIfNeeded()
                _ = view.fittingSize
            }
            tabs.fitWindowToSelectedTab(animate: false)
            if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
            }
            window.close()
        }
        let start = Probe.counts
        let readsBefore = status.counts
        let first = time(1, warm: false) { build() }
        let again = time(2, warm: false) { build() }
        drain()
        let counts = Probe.counts - start
        let reads = status.counts
        c.check("the Settings window builds with no image lookup that misses and no asset-catalog open (it made 24, logged as 48 CoreUI errors)",
                counts.misses == 0 && counts.catalogs == 0, "\(counts.misses) misses \(Probe.misses(since: start).prefix(6)), \(counts.catalogs) catalog opens")
        c.check("…and reads the Launch at Login status not at all on the main thread (it read it 10 to 12 times, 20 ms each)",
                reads.onMain == readsBefore.onMain && counts.statusReads == 0,
                "\(reads.onMain - readsBefore.onMain) reads on the main thread, \(counts.statusReads) SMAppService reads")
        c.check("…with its tabs’ labels, symbols and identifiers", {
            let tabs = SettingsTabViewController()
            return tabs.tabViewItems.map(\.label) == SettingsSection.allCases.map(\.title) && tabs.tabViewItems.allSatisfy { $0.image != nil }
                && tabs.tabViewItems.map { $0.identifier as? String } == SettingsSection.allCases.map(\.rawValue)
        }())
        c.notes.append("Settings window, four tabs laid out and drawn: first \(String(format: "%.0f", first.median)) ms (helper-tool probes included), then \(String(format: "%.0f", again.median)) ms")
    }

    // MARK: Timers in the common modes

    static func timers(_ c: Checker) {
        func budget(_ name: String, _ t: Timing) {
            c.check("\(name): median under 0.2 ms, p95 under 1 ms", t.median < 0.2 && t.p95 < 1, t.text)
            c.notes.append("\(name): \(t.text)")
        }
        let monitor = DragMonitor()
        budget("the drag poll (20 Hz, button up)", time(1000) { monitor.tick() })
        monitor.stop()

        let start = Probe.counts
        let poll = time(1000) { _ = Settings.holdKeyFirst && HoldKeyTap.shared.trustChanged }
        budget("the hold-key permission poll (every 2 s)", poll)
        c.check("…which looks nothing up in LaunchServices (it looked Finder up every time)", (Probe.counts - start).lookups == 0)

        let name = NSPasteboard.Name("com.yummyorange.app.menu-latency.\(getpid())")
        let pasteboard = NSPasteboard(name: name)
        defer { pasteboard.releaseGlobally() }
        let watcher = ScreenshotClipboardWatcher(pasteboard: PasteboardSource(pasteboard),
                                                 folder: FileManager.default.temporaryDirectory, isHelperActive: { false })
        watcher.usesTimers = false
        watcher.start()
        budget("the clipboard-screenshot poll (10 Hz, nothing copied)", time(1000) { watcher.poll() })
        watcher.stop()

        let updater = UpdaterTests.idleUpdater()
        budget("the updater’s timer (is a check due?)", time(1000) { updater.tick() })
        budget("the update notice’s busy check (default mode only)", time(1000) { _ = UpdateMoment.isBusy() })
        // Not a common-mode timer: it runs from the notice's default-mode timer, every 30 s while an alert waits.
        let presenting = time(20) { _ = UpdateMoment.isPresenting() }
        c.check("the update notice’s on-show check (power assertions and the window list; default mode only, every 30 s while an alert waits): median under 10 ms",
                presenting.median < 10, presenting.text)
        c.notes.append("the update notice’s on-show check: \(presenting.text)")

        do {
            let fixtures = try ClotheslinePerfTests.Fixtures(screenshot: false)
            defer { fixtures.remove() }
            let rig = ClotheslinePerfTests.Rig()
            rig.ctl.watchDrops()
            rig.hangSettled(fixtures.line, hidden: true)
            let g = rig.engine.geometry
            // The pointer along the top of the screen, where a status-item menu is tracked.
            var x = g.screenFrame.maxX - 300
            let y = g.screenFrame.maxY - 60
            func step() { x += 0.5; if x > g.screenFrame.maxX - 20 { x = g.screenFrame.maxX - 300 } }
            budget("the Clothesline’s pointer handler (16 cards, line up)", time(500) { step(); rig.ctl.pointerMoved(screen: CGPoint(x: x, y: y)) })
            rig.button = true
            rig.location = CGPoint(x: x, y: y)
            rig.ctl.mouseEvent(.down, screen: rig.location)
            budget("the Clothesline’s press poll (60 Hz while a button is down)", time(500) {
                step()
                rig.location = CGPoint(x: x, y: y)
                rig.ctl.pollPress()
            })
            rig.button = false
            rig.ctl.pollPress()
            let validate = time(1000) { _ = rig.engine.hasFilesOnDisk }
            c.check("Show Clothesline’s validation (one stat for the first card still there): under 0.05 ms", validate.median < 0.05, validate.text)
        } catch {
            c.check("the Clothesline’s test pictures", false, error.localizedDescription)
        }
    }

    // MARK: A click on the menu-bar icon

    /// The drag monitor's local mouse-down monitor runs before the status item's menu opens: the press, then one poll
    /// with the button down (the keyboard layout's comma keys, the Dock's preferences, the recognizer's step).
    static func press(_ c: Checker) {
        let monitor = DragMonitor()
        var down = false
        monitor.isButtonDown = { down }
        defer { monitor.stop() }
        func click() {
            guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 1200, y: 1100), modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            down = true
            monitor.recordPress(event)
            down = false
            monitor.tick()   // released: the menu opens on the press, the poll sees the button up later
        }
        let start = Probe.counts
        let cached = time(200) { click() }
        let fresh = time(30) { DockGeometry.forgetPreferences(); click() }
        let counts = Probe.counts - start
        c.check("a click on the menu-bar icon (the drag monitor’s press and poll, before the menu opens): median under 1 ms, p95 under 5 ms, Dock preferences read anew each time",
                fresh.median < 1 && fresh.p95 < 5 && cached.median < 1, "anew: \(fresh.text); within 2 s of the last: \(cached.text)")
        c.check("…with no LaunchServices lookup and no status read on the main thread", counts.lookups == 0 && counts.statusReads == 0,
                "\(counts.lookups) lookups, \(counts.statusReads) status reads")
        c.notes.append("click on the icon: Dock preferences read anew \(fresh.text); within 2 s of the last \(cached.text)")
    }

    // MARK: Settings, closed

    /// Once Settings has been opened, its window and four tabs stay built. The updater's and the login status's
    /// changes, which come by themselves (the timer's check, a status read as the menu opens), re-rendered all four
    /// for 10 to 17 ms in the menu's tracking mode; now they reach the tabs only while the window is open.
    static func settingsClosed(_ c: Checker) {
        let saved = SettingsModel.followsLiveChanges
        defer { SettingsModel.followsLiveChanges = saved }
        let tabs = SettingsTabViewController()
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        for item in tabs.tabViewItems { item.viewController?.view.layoutSubtreeIfNeeded() }
        if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        window.close()
        drain()
        func stretch(_ name: Notification.Name) -> Double {
            longestBusyStretch(in: .eventTracking, for: 0.15) { NotificationCenter.default.post(name: name, object: nil) }
        }
        SettingsModel.followsLiveChanges = { true }
        let openUpdater = stretch(Updater.didChange)
        SettingsModel.followsLiveChanges = { false }
        let closed = [stretch(Updater.didChange), stretch(LaunchAtLogin.didChange), stretch(Updater.didChange)]
        c.check("Settings closed: an updater or login-status change costs the open menu under 1 ms (no tab re-renders)",
                closed.allSatisfy { $0 < 1 }, closed.map { String(format: "%.2f", $0) }.joined(separator: ", ") + " ms")
        c.check("…while with the window open the same change does re-render them (so the measurement sees one)", openUpdater > 1,
                String(format: "%.1f ms", openUpdater))
        c.notes.append(String(format: "Settings built, then closed: longest busy stretch in the menu’s tracking mode %@ ms; with it open %.1f ms",
                              closed.map { String(format: "%.2f", $0) }.joined(separator: ", "), openUpdater))
    }

    // MARK: Show Clothesline's validation, at its worst

    static func clotheslineValidation(_ c: Checker) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("YummyOrange latency \(UUID().uuidString.prefix(8))", isDirectory: true)
        let trash = dir.appendingPathComponent(".Trash", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let files = (0..<ClotheslineEngine.capacity).map { dir.appendingPathComponent("card \($0).txt") }
        for file in files { try? Data("x".utf8).write(to: file) }
        let engine = ClotheslineEngine(geometry: .builtInSample)
        engine.hang(files)
        for file in files { try? fm.moveItem(at: file, to: trash.appendingPathComponent(file.lastPathComponent)) }
        let full = engine.urls.count
        let gone = engine.hasFilesOnDisk
        let trashed = time(50) { _ = engine.hasFilesOnDisk }
        c.check("Show Clothesline’s validation with the line full (50 cards) and every file in the Trash: dimmed, under 2 ms",
                full == ClotheslineEngine.capacity && !gone && trashed.median < 2, "\(full) cards, \(trashed.text)")
        c.notes.append("Show Clothesline’s validation, 50 cards all in the Trash: \(trashed.text)")

        // A card for a file on another volume counts as there without a look (a sleeping disk, a server gone).
        let other = ClotheslineEngine(geometry: .builtInSample)
        other.fileExists = { _ in true }
        other.hang([URL(fileURLWithPath: "/Volumes/Backup/clip.mov"), URL(fileURLWithPath: "/Volumes/Server/notes.pdf")])
        var looks = 0
        other.fileExists = { _ in looks += 1; return false }
        c.check("…a file on another volume (/Volumes) counts as there without a look at that disk or server",
                other.urls.count == 2 && other.hasFilesOnDisk && looks == 0 && ClotheslineEngine.isOnOtherVolume(URL(fileURLWithPath: "/Volumes/X/a"))
                && !ClotheslineEngine.isOnOtherVolume(URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/a.png")), "\(looks) looks")
    }

    // MARK: Finder's pid

    static func finderPID(_ c: Checker) {
        let start = Probe.counts
        HoldKeyTap.shared.watchFinder()
        let looked = (Probe.counts - start).lookups
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: HoldKeyTap.finderBundleID).first else {
            c.notes.append("Finder isn’t running: its pid tracking wasn’t checked")
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        let found = HoldKeyTap.shared.finderPID
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: NSWorkspace.shared,
                    userInfo: [NSWorkspace.applicationUserInfoKey: finder])
        let quit = HoldKeyTap.shared.finderPID
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: NSWorkspace.shared,
                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        let other = HoldKeyTap.shared.finderPID
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: NSWorkspace.shared,
                    userInfo: [NSWorkspace.applicationUserInfoKey: finder])
        let back = HoldKeyTap.shared.finderPID
        let before = Probe.counts
        for _ in 0..<100 { _ = HoldKeyTap.shared.trustChanged }
        c.check("the hold-key tap knows Finder’s pid from one lookup, then from NSWorkspace’s launch and quit notifications (other apps ignored), never from a poll",
                looked == 1 && found == finder.processIdentifier && quit == 0 && other == 0 && back == finder.processIdentifier
                && (Probe.counts - before).lookups == 0,
                "lookups \(looked), pid \(found) → quit \(quit) → other app \(other) → relaunch \(back)")
    }

    // MARK: The real status read

    static func realStatusRead(_ c: Checker) {
        let done = DispatchSemaphore(value: 0)
        var ms: [Double] = []
        var result = SMAppService.Status.notFound
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<5 {
                let t0 = CACurrentMediaTime()
                result = SMAppService.mainApp.status
                ms.append((CACurrentMediaTime() - t0) * 1000)
            }
            done.signal()
        }
        let answered = done.wait(timeout: .now() + 20) == .success
        let size = ((try? FileManager.default.attributesOfItem(atPath: CommandLine.arguments[0]))?[.size] as? NSNumber)?.doubleValue ?? 0
        c.check("SMAppService’s status can be read off the main thread", answered)
        let sorted = ms.sorted()
        c.notes.append("real SMAppService status reads, off the main thread: median \(String(format: "%.1f", sorted.isEmpty ? 0 : sorted[sorted.count / 2])) ms, max \(String(format: "%.1f", sorted.last ?? 0)) ms for this \(String(format: "%.0f", size / 1_000_000)) MB executable (status \(result.rawValue)); the menu no longer waits for them")
    }
}
#endif
