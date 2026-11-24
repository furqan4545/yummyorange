#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit

/// Checks for selecting a card and taking it off with the keyboard, and for the welcome card (part of `--selftest
/// clothesline`): a click selects a card (the ring, the panel takes the keyboard, the line stays out), Delete takes it
/// off and the selection moves on, ⌘Z puts it back, the arrows move the selection, Esc or a click elsewhere ends it and
/// gives the keyboard back, a double-click still opens and a drag still moves; an empty line holds the welcome card
/// quietly, written to a temporary folder here, until the person takes it off. Each one fails when the code it checks
/// is undone.
extension ClotheslineTests {
    static func selectChecks(_ c: Checker) {
        do { try selectView(c) } catch { c.check(false, "select setup", error.localizedDescription) }
        selectRing(c)
        selectUndo(c)
        selectPanel(c)
        do { try welcomeChecks(c) } catch { c.check(false, "welcome setup", error.localizedDescription) }
        welcomePicture(c)
    }

    // MARK: Helpers

    /// A rig with `n` PNG-named files hung and the line out and still; the files live in `dir`.
    static func selectRig(_ dir: URL, _ n: Int = 4) throws -> (DropRig, [URL]) {
        let urls = (0..<n).map { dir.appendingPathComponent("photo-\($0).png") }
        for u in urls { try Data("png".utf8).write(to: u) }
        let r = DropRig()
        r.ctl.watchDrops()
        r.ctl.hang(urls)
        r.frames(1.5)
        return (r, urls)
    }

    /// A click on card `i` (press and release on the spot, through the monitors and the view), the pointer resting on
    /// it first.
    static func click(_ r: DropRig, _ i: Int, count: Int = 1) {
        guard let p = onCard(r.engine, i) else { return }
        r.ctl.pointerMoved(screen: r.screen(p)); r.frames(0.2)
        r.press(p); r.surface.view.pressDown(at: p, clickCount: count)
        r.release(p); r.surface.view.pressUp(at: p)
        r.frames(1.0 / 60)
    }

    // MARK: Selecting and the keys

    static func selectView(_ c: Checker) throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (r, urls) = try selectRig(dir)
        let e = r.engine, view = r.surface.view
        func id(_ i: Int) -> UUID { e.items[i].id }

        // A click selects: the ring on that card's own layer, the panel takes the keyboard (never before), VoiceOver
        // hears that the card is selected.
        let before = r.surface.keyboardTakes == 0 && !r.surface.hasKeyboard && !view.acceptsFirstResponder
        guard let p = onCard(e, 2) else { c.check(false, "select: setup"); return }
        r.ctl.pointerMoved(screen: r.screen(p)); r.frames(0.2)
        r.press(p); view.pressDown(at: p)
        let notOnPress = e.selectedCard == nil
        r.release(p); view.pressUp(at: p)
        r.frames(1.0 / 60)
        let ring = view.selectionRing.superlayer === view.cardLayerPair(id(2))?.card
        let element = view.accessibilityCardElements.first { $0.id == id(2) }
        c.check(before && notOnPress && e.selectedCard == id(2) && ring && r.surface.hasKeyboard && r.surface.keyboardTakes == 1
                && view.acceptsFirstResponder && element?.isAccessibilitySelected() == true,
                "select: a click (press and release on a card) selects it: the ring on its own layer, the panel takes the keyboard (never before a selection), VoiceOver sees it selected",
                "before \(before), on press \(!notOnPress), selected \(e.selectedCard == id(2)), ring \(ring), keyboard \(r.surface.keyboardTakes)")

        // The line stays out while a card is selected, wherever the pointer goes.
        r.ctl.pointerMoved(screen: r.screen(CGPoint(x: 1300, y: 700)))
        r.frames(5)
        let stayed = e.state == .shown && r.surface.isShown
        c.check(stayed, "select: the line stays out while a card is selected (the pointer away for 5 s)", e.state.rawValue)

        // The arrows move the selection, nothing past either end.
        view.handleKey(124)
        let right = e.selectedCard == id(3)
        view.handleKey(124)
        let end = e.selectedCard == id(3)
        view.handleKey(123); view.handleKey(123)
        c.check(right && end && e.selectedCard == id(1), "select: → and ← move the selection one card; nothing past the end",
                "right \(right), at the end \(end)")

        // Delete: the card lifts away, the file stays, its neighbours close the gap, VoiceOver hears it, the selection
        // moves to the card that slides into its place and the panel keeps the keyboard.
        let gone = id(1), next = id(2)
        let slot = e.cards[next]?.slot.target ?? 0
        let handled = view.handleKey(51)
        let removed = !e.items.contains { $0.id == gone } && e.cards[gone]?.leaving == true
        let kept = FileManager.default.fileExists(atPath: urls[1].path)
        let closed = (e.cards[next]?.slot.target ?? .infinity) < slot
        c.check(handled && removed && kept && closed && view.lastAnnouncement == "Removed photo-1.png from the Clothesline"
                && e.selectedCard == next && r.surface.hasKeyboard,
                "delete: Delete takes the selected card off the line (it lifts away, the gap closes, the file stays on disk), VoiceOver hears “Removed photo-1.png from the Clothesline”, the selection moves to the card in its place",
                "removed \(removed), file kept \(kept), gap closed \(closed), heard \(view.lastAnnouncement ?? "nothing")")

        // ⌘Z right after puts it back where it was, selected; it comes back down from where it was lifting.
        r.frames(0.1)
        let undone = view.handleKey(6, modifiers: .command)
        let back = e.items.firstIndex { $0.id == gone } == 1 && e.selectedCard == gone && e.cards[gone]?.leaving == false
        r.frames(1)
        let settled = (e.pose(gone)?.alpha ?? 0) > 0.99 && e.isSettled
        let again = view.handleKey(6, modifiers: .command)
        c.check(undone && back && settled && !again && view.lastAnnouncement == "Put photo-1.png back on the Clothesline",
                "delete: ⌘Z right after puts the card back in its place, selected, fading back in from where it was going; a second ⌘Z does nothing",
                "back \(back), settled \(settled), second \(again)")

        // Forward Delete too; then Esc ends the selection, gives the keyboard back, and the line goes by the usual rules.
        let fwd = id(1)
        view.handleKey(117)
        let forward = !e.items.contains { $0.id == fwd }
        view.handleKey(53)
        let ended = e.selectedCard == nil && !r.surface.hasKeyboard && r.surface.keyboardReturns == 1 && view.selectionRing.superlayer == nil
        let went = runFrames(r, 2) { $0.engine.state == .retracting }
        c.check(forward && ended && went.map { $0 > 0.5 && $0 < 0.8 } ?? false,
                "keys: Forward Delete takes the card off too; Esc ends the selection (no ring), gives the keyboard back, and the line goes 0.6 s later (the pointer is away)",
                "forward \(forward), ended \(ended), went after \(went.map { f($0, 2) } ?? "never") s")

        // A press anywhere but on a card (the drag monitors see it) ends the selection, and so does a click in another
        // window (the panel loses the keyboard).
        r.ctl.reveal(); r.frames(1)
        click(r, 0)
        let picked = e.selectedCard == id(0)
        r.press(CGPoint(x: 900, y: 700)); r.release(CGPoint(x: 900, y: 700))
        let elsewhere = e.selectedCard == nil && !r.surface.hasKeyboard
        click(r, 1)
        r.surface.loseKeyboard()
        c.check(picked && elsewhere && e.selectedCard == nil,
                "select: a press anywhere else, or a click in another window (the panel loses the keyboard), ends the selection",
                "picked \(picked), press elsewhere \(elsewhere), lost keyboard \(e.selectedCard == nil)")

        // A drag is no click: it moves the card and selects nothing; picking up another card ends a selection, the
        // keyboard going back only once the press is over.
        click(r, 0)
        let order = e.urls
        guard let grab = onCard(e, 1) else { return }
        r.ctl.pointerMoved(screen: r.screen(grab)); r.frames(0.2)
        r.press(grab); view.pressDown(at: grab)
        var heldKeys = true
        for i in 1...20 {
            let q = CGPoint(x: grab.x + 12 * CGFloat(i), y: grab.y)
            r.button = true; r.location = r.screen(q); r.drag(q); view.pressMoved(to: q)
            r.frames(1.0 / 60)
            heldKeys = heldKeys && r.surface.hasKeyboard
        }
        let end2 = CGPoint(x: grab.x + 240, y: grab.y)
        r.button = false; r.location = r.screen(end2); r.release(end2); view.pressUp(at: end2)
        r.frames(1)
        c.check(e.urls != order && e.selectedCard == nil && heldKeys && !r.surface.hasKeyboard,
                "select: dragging a card along the string still moves it and selects nothing; it ends the selection, the keyboard going back once the press is over",
                "moved \(e.urls != order), selected \(e.selectedCard.map { _ in "a card" } ?? "none"), keyboard kept during the press \(heldKeys)")

        // A double-click still opens the file (and ends the selection: its app takes the keyboard).
        var opened: [URL] = []
        view.openFile = { opened.append($0) }
        r.ctl.reveal(); r.frames(1)
        guard e.items.count > 2 else { c.check(false, "select: double-click setup", "\(e.items.count) cards"); return }
        click(r, 2)
        let url = e.items[2].url
        click(r, 2, count: 2)
        c.check(opened == [url] && e.selectedCard == nil, "select: a double-click still opens the file (the first click selected it; opening ends the selection)",
                opened.map(\.lastPathComponent).joined(separator: ", "))

        // Remove from Line (the menu, the pointer) on the selected card hides the ring: nothing else gets selected.
        click(r, 0)
        let first = id(0)
        view.removeCard(first)
        r.frames(1.0 / 60)
        c.check(e.selectedCard == nil && !r.surface.hasKeyboard && view.lastAnnouncement?.hasPrefix("Removed ") == true,
                "select: Remove from Line on the selected card ends the selection (the focus isn't moved for a pointer action); VoiceOver hears the removal",
                view.lastAnnouncement ?? "nothing")
    }

    /// Ticks the rig until `done` or `limit` seconds; the seconds taken.
    static func runFrames(_ r: DropRig, _ limit: Double, _ done: (DropRig) -> Bool) -> Double? {
        var t = 0.0
        while t < limit {
            if done(r) { return t }
            r.frames(1.0 / 60); t += 1.0 / 60
        }
        return done(r) ? t : nil
    }

    // MARK: The ring's colours

    static func selectRing(_ c: Checker) {
        let mat = ClotheslineArt.Palette.dark.mat
        let light = WheelPainter.contrast(ClotheslineView.ringColor(dark: false, contrast: false), .white)
        let dark = WheelPainter.contrast(ClotheslineView.ringColor(dark: true, contrast: false), mat)
        let lightHigh = WheelPainter.contrast(ClotheslineView.ringColor(dark: false, contrast: true), .white)
        let darkHigh = WheelPainter.contrast(ClotheslineView.ringColor(dark: true, contrast: true), mat)
        c.check(light >= 3 && dark >= 3 && lightHigh >= 4.5 && darkHigh >= 4.5,
                "ring: YummyOrange's accent stands out from a white card and wallpaper (3:1) and from the dark card; Increase Contrast 4.5:1",
                "light \(f(light, 2)), dark \(f(dark, 2)), contrast \(f(lightHigh, 2)) / \(f(darkHigh, 2))")
        // Drawn: the accent, and with Increase Contrast an edge in the contrasting colour under it.
        let e = shownEngine(2)
        let view = ClotheslineView(engine: e, frame: CGRect(origin: .zero, size: sample.panelFrame.size))
        // Light mode first, whatever the Mac's appearance is now (it may switch to dark at sunset).
        view.forcedDark = false
        e.onItemsChange = { view.itemsChanged() }
        view.itemsChanged()
        e.select(e.items[0].id)
        func stroke(_ i: Int) -> NSColor? {
            ((view.selectionRing.sublayers?[i] as? CAShapeLayer)?.strokeColor).flatMap { NSColor(cgColor: $0) }
        }
        view.render()
        func same(_ a: NSColor?, _ b: NSColor) -> Bool {
            guard let x = a?.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
            return abs(x.redComponent - y.redComponent) + abs(x.greenComponent - y.greenComponent) + abs(x.blueComponent - y.blueComponent) < 0.01
        }
        let plain = same(stroke(1), DWPalette.accent) && stroke(0)?.alphaComponent == 0
        view.forcedDark = true
        view.increaseContrast = true
        view.render()
        let high = stroke(1).map { WheelPainter.contrast($0, mat) >= 4.5 } ?? false && (stroke(0)?.alphaComponent ?? 0) > 0.5
        let width = (view.selectionRing.sublayers?[1] as? CAShapeLayer)?.lineWidth ?? 0
        c.check(plain && high && width == 3 && view.selectionRing.superlayer === view.cardLayerPair(e.items[0].id)?.card,
                "ring: drawn on the selected card's layer, 3 pt in the accent; dark with Increase Contrast, the light accent over a dark edge",
                "plain \(plain), contrast \(high), \(width) pt")
    }

    /// ⌘Z puts a card back the way it went, reversed: one already gone comes down from where it went, fading in; under
    /// Reduce Motion it only fades back in at its place.
    static func selectUndo(_ c: Checker) {
        let e = shownEngine(3)
        let item = e.items[1]
        e.remove(item.id)
        runUntil(e, 2) { $0.cards[item.id] == nil }
        let gone = e.cards[item.id] == nil
        let back = e.restore(item, at: 1)
        let start = (e.pose(item.id)?.alpha ?? 1, e.cards[item.id]?.drop.value ?? 0)
        runUntil(e, 2) { $0.isSettled }
        let landed = e.items[1].id == item.id && (e.pose(item.id)?.alpha ?? 0) > 0.999 && abs(e.cards[item.id]?.drop.value ?? 1) < 0.06
        let r = shownEngine(3, reduceMotion: true)
        let still = r.items[1]
        r.remove(still.id)
        simulate(r, 0.1)
        r.restore(still, at: 1)
        var drop = 0.0, spin = 0.0
        let faded = runUntil(r, 1) { eng in
            drop = max(drop, abs(eng.cards[still.id]?.drop.value ?? 0)); spin = max(spin, abs(eng.cards[still.id]?.spin ?? 0))
            return (eng.pose(still.id)?.alpha ?? 0) > 0.999
        }
        c.check(gone && back && start.0 < 0.05 && start.1 < -30 && landed && drop == 0 && spin == 0 && faded.map { $0 < 0.25 } ?? false,
                "undo: a card already gone comes back down from where it went, fading in, to its old place; Reduce Motion: it only fades back in there (no drop, no swing)",
                "from alpha \(f(start.0, 2)) at \(f(start.1, 0)) pt, landed \(landed), Reduce Motion in \(faded.map { f($0, 2) } ?? "never") s")
    }

    /// The panel can become key (take the keyboard) only while a card is selected.
    static func selectPanel(_ c: Checker) {
        let panel = ClotheslinePanel(geometry: sample)
        let never = !panel.canBecomeKey && !panel.canBecomeMain && panel.styleMask.contains(.nonactivatingPanel)
        panel.takesKeyboard = true
        c.check(never && panel.canBecomeKey && !panel.canBecomeMain,
                "panel: it can become key only while a card is selected, never main, and it is non-activating (YummyOrange stays in the background)")
    }

    // MARK: The welcome card

    static func welcomeChecks(_ c: Checker) throws {
        let dir = try scratch()
        let savedFolder = ClotheslineWelcome.folder, savedDefaults = Settings.defaults
        defer {
            ClotheslineWelcome.folder = savedFolder
            Settings.defaults = savedDefaults
            try? FileManager.default.removeItem(at: dir)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? "/nowhere"
        let cli = ClotheslineWelcome.defaultFolder(arguments: ["YummyOrange", "--selftest", "clothesline"])
        let app = ClotheslineWelcome.defaultFolder(arguments: ["YummyOrange"])
        c.check(!savedFolder.path.hasPrefix(support) && !cli.path.hasPrefix(support) && app.path == support + "/YummyOrange/Clothesline",
                "welcome: written to ~/Library/Application Support/YummyOrange/Clothesline by the app, to a temporary folder from the command line (self-tests never touch the real one)",
                savedFolder.path)
        ClotheslineWelcome.folder = dir.appendingPathComponent("Support", isDirectory: true)
        let store = SettingsMemoryStore(["resultsDestination": ResultsDestination.clothesline.rawValue])
        Settings.defaults = store
        func rig() -> DropRig {
            let r = DropRig()
            r.ctl.welcomeFile = { ClotheslineWelcome.wanted() }
            r.engine.onWelcomeRemoval = { Settings.clotheslineWelcomeRemoved = $0 }
            return r
        }

        // Not while new files go elsewhere.
        Settings.resultsDestination = .shelf
        let off = rig()
        off.ctl.watchDrops(); off.frames(0.5)
        let none = off.engine.items.isEmpty && ClotheslineWelcome.wanted() == nil
            && !FileManager.default.fileExists(atPath: ClotheslineWelcome.url.path)
        Settings.resultsDestination = .clothesline
        c.check(none, "welcome: no welcome card while Show New Files isn't On the Clothesline (nothing written either)")

        // On the Clothesline, an empty line holds it from the start, quietly: no reveal, no flight, no announcement.
        let r = rig()
        r.ctl.watchDrops()
        r.frames(0.5)
        let e = r.engine, view = r.surface.view
        let url = ClotheslineWelcome.url
        let quiet = e.state == .hidden && e.revealCount == 0 && view.lastAnnouncement == nil && !e.hasFlights
            && e.pendingArrivals.isEmpty && !r.surface.isShown
        let name = FileManager.default.displayName(atPath: url.path)
        c.check(e.urls == [url] && e.welcomeID == e.items.first?.id && quiet && r.ctl.monitors.count == 2 && name == "Welcome to the Clothesline",
                "welcome: an empty line On the Clothesline holds the welcome card (written once, its extension hidden), quietly: the line stays away, no flight, nothing announced; resting on the notch will show it",
                "\(e.urls.map(\.lastPathComponent)), quiet \(quiet), monitors \(r.ctl.monitors.count), caption \(name)")

        // Resting on the notch shows it; a job's files hang in front of it and only they are announced.
        r.ctl.pointerMoved(screen: r.screen(CGPoint(x: 868, y: 18)))
        r.frames(1.2)
        let shown = e.state == .shown && e.revealCount == 1
        let jobs = (0..<2).map { dir.appendingPathComponent("job-\($0).png") }
        for u in jobs { try Data("png".utf8).write(to: u) }
        r.ctl.hang(jobs)
        r.frames(1.5)
        c.check(shown && e.urls == jobs + [url] && view.lastAnnouncement == "2 files added to the Clothesline",
                "welcome: resting on the notch shows it; new files hang in front of it like any card's, and only they count as new",
                "shown \(shown), \(e.urls.map(\.lastPathComponent)), heard \(view.lastAnnouncement ?? "nothing")")

        // Selected and deleted with the keyboard: remembered (Settings), the file stays; ⌘Z puts it back and forgets.
        click(r, 2)
        let selected = e.selectedCard == e.welcomeID && e.welcomeID != nil
        view.handleKey(51)
        let removed = Settings.clotheslineWelcomeRemoved && !e.urls.contains(url) && FileManager.default.fileExists(atPath: url.path)
        view.handleKey(6, modifiers: .command)
        let undone = !Settings.clotheslineWelcomeRemoved && e.urls.last == url && e.welcomeID != nil
        c.check(selected && removed && undone,
                "welcome: selected and deleted it is remembered in Settings (its file stays); ⌘Z puts it back and forgets",
                "selected \(selected), removed \(removed), undone \(undone)")

        // Remove from Line and Clear Line take it off for good too; an empty line no longer gets it.
        view.removeCard(e.welcomeID ?? UUID())
        let byMenu = Settings.clotheslineWelcomeRemoved
        Settings.clotheslineWelcomeRemoved = false
        view.handleKey(6, modifiers: .command)  // nothing to undo after a menu removal
        r.ctl.shutDown(); r.ctl.watchDrops()
        let backAfterOff = e.urls == [url]
        r.ctl.reveal(); r.frames(1.2)
        view.clearLine()
        let byClear = Settings.clotheslineWelcomeRemoved
        r.frames(2)
        r.ctl.pointerMoved(screen: r.screen(CGPoint(x: 400, y: 700))); r.frames(0.5)
        c.check(byMenu && backAfterOff && byClear && e.items.isEmpty && e.state == .hidden,
                "welcome: Remove from Line and Clear Line take it off for good (the line turned off and on again brings it back only while it was never taken off)",
                "menu \(byMenu), back after off/on \(backAfterOff), clear \(byClear), then \(e.urls.map(\.lastPathComponent))")

        // Never taken off: it comes back whenever the line is empty and away (its file gone and the last card removed).
        Settings.clotheslineWelcomeRemoved = false
        let s = rig()
        s.ctl.watchDrops()
        try FileManager.default.removeItem(at: url)
        let other = dir.appendingPathComponent("other.png")
        try Data("png".utf8).write(to: other)
        s.ctl.hang([other])
        s.frames(1.5)
        let pruned = s.engine.urls == [other] && !Settings.clotheslineWelcomeRemoved
        s.surface.view.clearLine()
        s.ctl.pointerMoved(screen: s.screen(CGPoint(x: 400, y: 700)))
        s.frames(2)
        c.check(pruned && s.engine.state == .hidden && s.engine.urls == [url] && FileManager.default.fileExists(atPath: url.path),
                "welcome: a welcome card that went without being taken off (its file deleted) comes back, written again, once the line is empty and away",
                "pruned \(pruned), then \(s.engine.urls.map(\.lastPathComponent)) (\(s.engine.state.rawValue))")

        // Another choice for new files keeps the person's files aside, not the welcome card.
        let saved = (ClotheslineMenuTarget.lineFiles, ClotheslineMenuTarget.turnOffLine, ClotheslineMenuTarget.restoreLine, ClotheslineMenuTarget.watchLine)
        defer { (ClotheslineMenuTarget.lineFiles, ClotheslineMenuTarget.turnOffLine, ClotheslineMenuTarget.restoreLine, ClotheslineMenuTarget.watchLine) = saved }
        var restored: [URL] = []
        ClotheslineMenuTarget.lineFiles = { [other, url] }
        ClotheslineMenuTarget.turnOffLine = {}
        ClotheslineMenuTarget.restoreLine = { restored = $0 }
        ClotheslineMenuTarget.watchLine = {}
        Settings.defaults = SettingsMemoryStore(["resultsDestination": ResultsDestination.shelf.rawValue])
        ClotheslineMenuTarget.settingsChanged()
        Settings.resultsDestination = .clothesline
        ClotheslineMenuTarget.settingsChanged()
        c.check(restored == [other] && ClotheslineMenuTarget.parked.isEmpty,
                "welcome: choosing another place for new files keeps the person's files aside, not the welcome card (it comes back by itself)",
                restored.map(\.lastPathComponent).joined(separator: ", "))
    }

    /// The picture: small, original, in YummyOrange's colours, the words legible.
    static func welcomePicture(_ c: Checker) {
        guard let data = ClotheslineWelcome.pngData(), let rep = NSBitmapImageRep(data: data), let image = rep.cgImage else {
            c.check(false, "welcome: the picture renders"); return
        }
        let top = pixel(image, x: 30, y: 4), bottom = pixel(image, x: 30, y: image.height - 4)
        let pink = top.map { $0.0 > 0.8 && $0.0 - $0.1 > 0.3 } ?? false
        let butter = bottom.map { $0.0 > 0.95 && $0.1 > 0.8 && $0.2 < 0.75 } ?? false
        let behind = DWPalette.blend(DWPalette.base, DWPalette.glow, 0.55)
        let words = WheelPainter.contrast(ClotheslineWelcome.ink, behind)
        c.check(data.count < 60_000 && rep.pixelsWide <= 1200 && !rep.hasAlpha && pink && butter && words >= 4.5,
                "welcome: the picture is a small opaque PNG (under 60 KB, at most 1200 px wide) from dahlia pink to butter, its words at least 4.5:1",
                "\(data.count / 1024) KB, \(rep.pixelsWide)×\(rep.pixelsHigh) px, words \(f(words, 1)):1")
    }
}
#endif
