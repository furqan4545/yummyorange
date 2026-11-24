#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit

/// Checks for dropping files on the line (part of `--selftest clothesline`): the drag watch, the reveal for a file
/// drag, the ghost and the gap, the insertion, cancelling, the retract rules, Reduce Motion, the panel's routing, the
/// NSDraggingDestination methods with a real pasteboard, the monitors following the setting, and dropped files
/// followed when a card moves them. Each one fails when the code it checks is undone.
extension ClotheslineTests {
    static func dropChecks(_ c: Checker) {
        dropWatch(c)
        dropReveal(c)
        dropGap(c)
        dropFreshGhost(c)
        dropEdgeScroll(c)
        dropInsert(c)
        dropCancel(c)
        dropRetract(c)
        dropReduceMotion(c)
        do { try dropRouting(c) } catch { c.check(false, "drop routing setup", error.localizedDescription) }
        do { try dropDestination(c) } catch { c.check(false, "drop destination setup", error.localizedDescription) }
        dropMonitors(c)
        do { try dropFollow(c) } catch { c.check(false, "dropped-file follow setup", error.localizedDescription) }
        dropReviewChecks(c)
    }

    // MARK: Helpers

    /// Four cards 146, 162, 112 and 146 pt wide (slot centres 107, 283, 442, 593), out and still, held open. A dragged
    /// file that isn't on the line gets the first width (146), so the ghost centres are 107, 275, 459, 593 and 761.
    static func dropEngine(reduceMotion: Bool = false, prefix: String = "cl-drop") -> (ClotheslineEngine, [URL]) {
        let e = ClotheslineEngine(geometry: sample, reduceMotion: reduceMotion)
        e.fileExists = { _ in true }
        let urls = (0..<4).map { URL(fileURLWithPath: "/tmp/\(prefix)-\($0).png") }
        let widths: [CGFloat] = [146, 162, 112, 146]
        e.widthFor = { url in widths[urls.firstIndex(of: url) ?? 0] }
        e.holdOpen = true
        e.hang(urls)
        runUntil(e, 4) { $0.state == .shown && $0.pendingArrivals.isEmpty && $0.isSettled }
        return (e, urls)
    }

    /// The screen x of a content position on a still, unscrolled line.
    static func screenX(_ u: Double) -> Double { Double(sample.leftEndX) + u }
    /// A point on the string where it hangs now (its sag depends on the cards it carries).
    static func lineSpot(_ e: ClotheslineEngine, _ x: Double) -> CGPoint {
        CGPoint(x: x, y: e.stringY(at: x, ends: e.lineEnds()))
    }

    static func slotTargets(_ e: ClotheslineEngine) -> [Double] { e.items.map { e.cards[$0.id]?.slot.target ?? -1 } }

    // MARK: The drag watch

    static func dropWatch(_ c: Checker) {
        var w = ClotheslineDragWatch()
        var count = 10, reads = 0
        let files = [URL(fileURLWithPath: "/tmp/cl-watch.png")]
        var payload = files
        func drag(near: Bool, _ t: Double) -> [URL]? {
            w.dragged(nearTop: near, time: t, changeCount: { count }, readFiles: { reads += 1; return payload })
        }
        w.reset(changeCount: count)
        w.press(changeCount: count)
        let still = (0..<10).map { drag(near: true, Double($0) * 0.01) }
        c.check(still.allSatisfy { $0 == nil } && reads == 0,
                "drop watch: a press whose drag never wrote the drag pasteboard (a window moved by its title) is no file drag; nothing is read",
                "\(reads) reads")
        w.release(changeCount: count); w.press(changeCount: count); count += 1
        let far = drag(near: false, 1)
        let near = [drag(near: true, 1.02), drag(near: true, 1.04), drag(near: false, 1.06)]
        c.check(far == nil && near.allSatisfy { $0 == files } && reads == 1,
                "… a real drag session is looked at only near the top of the line's display, and its files are read once per press",
                "\(reads) reads")
        w.release(changeCount: count); w.press(changeCount: count); count += 1
        payload = []
        let text = [drag(near: true, 2), drag(near: true, 2.1)]
        c.check(text.allSatisfy { $0 == nil } && reads == 2, "… a drag of text (no file URLs) is not a file drag: it keeps the other-drag pass-through",
                "\(reads) reads")
        payload = files
        w.release(changeCount: count); count += 1; w.press(changeCount: count)
        c.check(drag(near: true, 3) == files, "… a drag that wrote the pasteboard before its press was handled still counts (baseline: the last release)")
        w.finish()
        c.check(drag(near: true, 3.1) == nil && w.knownFiles == nil, "… after a drop or a cancel over the line the rest of that press is no file drag")
    }

    // MARK: A file drag at the notch drops the line

    static func dropReveal(_ c: Checker) {
        let file = [URL(fileURLWithPath: "/tmp/cl-drop-new.png")]
        let e = ClotheslineEngine(geometry: sample)
        e.fileExists = { _ in true }
        e.setFileDrag(file)
        // Files carried across the notch without stopping (15 pt per frame).
        for i in 0...14 { e.pointerMoved(to: CGPoint(x: 780 + Double(i) * 15, y: 20)); simulate(e, 1.0 / 60) }
        simulate(e, 0.3)
        c.check(e.state == .hidden && e.revealCount == 0, "drop: files dragged across the notch without stopping don't drop the line",
                e.state.rawValue)
        e.pointerMoved(to: CGPoint(x: 868, y: 18))
        let t = runUntil(e, 1) { $0.state != .hidden }
        c.check(t.map { abs($0 - ClotheslineGeometry.notchDwell) <= 2 * h } ?? false && e.items.isEmpty,
                "drop: files resting in the notch drop the line after the notch's 0.5 s rest, even an empty line",
                "\(t.map { f($0 * 1000, 1) } ?? "never") ms")
        // The ghost comes out of the notch with the string and rides it out to the line's first place (where the file
        // will stay: 14 + 34 + 112 / 2 = 104), never faster than the string that carries it.
        var firstSeen: Double?, lastX: Double?, maxStep = 0.0, lastEnd: Double?, endStep = 0.0, slid = 0.0
        runUntil(e, 1.5) { eng in
            if eng.line.value < 0.9, eng.ghostShow.value > 0.01 { slid = max(slid, abs(eng.ghostSlot.value - eng.ghostSlot.target)) }
            let end = Double(eng.lineEnds().left.x)
            if let l = lastEnd { endStep = max(endStep, abs(end - l)) }
            lastEnd = end
            if let g = eng.ghostPose, g.alpha > 0.05 {
                let x = Double(g.pivot.x)
                if firstSeen == nil { firstSeen = x }
                if let l = lastX { maxStep = max(maxStep, abs(x - l)) }
                lastX = x
            }
            return eng.state == .shown && eng.isSettled
        }
        let ghost = e.ghostPose
        let y = e.stringY(at: Double(ghost?.pivot.x ?? 0), ends: e.lineEnds())
        c.check(e.acceptsDrop && e.dropIndex == 0 && (ghost?.alpha ?? 0) > 0.95 && firstSeen.map { abs($0 - 868) < 100 } ?? false
                && abs(Double(ghost?.pivot.x ?? 0) - 104) < 1 && abs(Double(ghost?.pivot.y ?? 0) - y) < 0.5 && maxStep <= endStep + 0.5
                && slid < 0.5,
                "… in the drop state: the ghost comes out of the notch with the string and rides it to where the file will hang (the line's first place)",
                "first seen at \(firstSeen.map { f($0, 1) } ?? "never"), rests at \(f(Double(ghost?.pivot.x ?? 0), 1)), \(f(Double(ghost?.pivot.y ?? 0), 1)); string \(f(y, 1)); largest step \(f(maxStep, 1)) pt (the string's end \(f(endStep, 1))), slid along it \(f(slid, 1)) pt")
        c.check(e.dropGlow.value > 0.98, "… and the string glows brighter", f(e.dropGlow.value))
        // Let go right there at the notch: the card hangs where the ghost showed it and stays (no slide afterwards).
        let ghostX = Double(ghost?.pivot.x ?? 0)
        if let id = e.drop(file).first?.id {
            var xs: [Double] = []
            runUntil(e, 1.5) { eng in if let p = eng.pose(id), p.alpha > 0 { xs.append(Double(p.pivot.x)) }; return false }
            let drift = xs.map { abs($0 - ghostX) }.max() ?? 99
            c.check(!xs.isEmpty && drift < 0.5, "… let go at the notch, the file hangs where the ghost showed it and stays there (no slide)",
                    "drifted \(f(drift, 2)) pt from the ghost")
        } else {
            c.check(false, "drop: release at the notch")
        }
        // In the margin under the notch (menus and window titles live there) a rest never drops it: only the notch does.
        let m = ClotheslineEngine(geometry: sample)
        m.fileExists = { _ in true }
        m.setFileDrag(file)
        m.pointerMoved(to: CGPoint(x: 868, y: 47))
        let tm = runUntil(m, 1.5) { $0.state != .hidden }
        c.check(tm == nil, "drop: files resting in the strip under the notch don't drop the line (1.5 s)",
                tm.map { "dropped after \(f($0 * 1000, 1)) ms" } ?? "hidden")
        // A drag without files (text, a window) is "another drag": it never drops the line, empty or not.
        let o = fakeEngine(3, prefix: "cl-drop-other")
        runUntil(o, 6) { $0.state == .hidden && $0.time > 1 }
        o.otherDrag = true
        o.pointerMoved(to: CGPoint(x: 868, y: 18))
        simulate(o, 0.8)
        c.check(o.state == .hidden && !o.acceptsDrop, "drop: a drag with no files resting at the notch leaves the line alone", o.state.rawValue)
    }

    // MARK: The ghost and the gap

    static func dropGap(_ c: Checker) {
        let (e, _) = dropEngine()
        let before = slotTargets(e)
        let dragged = [URL(fileURLWithPath: "/tmp/cl-drop-dragged.png")]
        e.setFileDrag(dragged)
        e.pointerMoved(to: CGPoint(x: screenX(283), y: 120))      // on the second card
        let gapped = slotTargets(e)
        c.check(e.dropIndex == 1 && abs(gapped[0] - before[0]) < 0.01 && (1..<4).allSatisfy { abs(gapped[$0] - before[$0] - 168) < 0.01 }
                && abs(e.ghostSlot.target - 275) < 0.01,
                "gap: over a card the ghost takes its slot; the cards from there on move right by the ghost and a gap (146 + 22 pt)",
                "index \(e.dropIndex.map(String.init) ?? "nil"), targets \(gapped.map { f($0, 0) }.joined(separator: ", "))")
        simulate(e, 1.0)
        if let ghost = e.ghostPose, let left = e.items.first.flatMap({ e.pose($0.id) }), let right = e.items.dropFirst().first.flatMap({ e.pose($0.id) }) {
            let room = Double(ghost.pivot.x - ghost.width / 2) - Double(left.pivot.x + left.width / 2)
            let roomRight = Double(right.pivot.x - right.width / 2) - Double(ghost.pivot.x + ghost.width / 2)
            c.check(abs(room - 22) < 1 && abs(roomRight - 22) < 1, "… the neighbours slide apart: 22 pt on either side of the ghost",
                    "\(f(room, 1)) and \(f(roomRight, 1)) pt")
        } else {
            c.check(false, "gap: poses")
        }
        // The gap follows the pointer along the string.
        e.pointerMoved(to: CGPoint(x: screenX(600), y: 60))
        let moved = slotTargets(e)
        c.check(e.dropIndex == 3 && (0..<3).allSatisfy { abs(moved[$0] - before[$0]) < 0.01 } && abs(moved[3] - before[3] - 168) < 0.01,
                "… it follows the pointer: over the fourth card the first three close up again", moved.map { f($0, 0) }.joined(separator: ", "))
        // Midway between two slots it doesn't flicker: 275 and 459 meet at 367; at 370 the next slot is only 6 pt
        // nearer, at 376 it is 18 pt nearer.
        e.pointerMoved(to: CGPoint(x: screenX(283), y: 60))
        e.pointerMoved(to: CGPoint(x: screenX(370), y: 60))
        let held = e.dropIndex
        e.pointerMoved(to: CGPoint(x: screenX(376), y: 60))
        c.check(held == 1 && e.dropIndex == 2, "… it moves to the next slot only once that slot is 8 pt nearer (no flicker at the midpoint)",
                "\(held.map(String.init) ?? "nil") then \(e.dropIndex.map(String.init) ?? "nil")")
        // Past the last card the ghost rests where the file will stay: the place after the last card.
        e.pointerMoved(to: CGPoint(x: screenX(1100), y: 60))
        simulate(e, 1.0)
        let end = slotTargets(e)
        c.check(e.dropIndex == 4 && abs(e.ghostSlot.target - 761) < 0.01 && abs(Double(e.ghostPose?.pivot.x ?? 0) - screenX(761)) < 0.5
                && (0..<4).allSatisfy { abs(end[$0] - before[$0]) < 0.01 },
                "… past the last card the ghost rests at the place after it, where the file will stay, not under the pointer (no card moves)",
                "ghost at \(f(Double(e.ghostPose?.pivot.x ?? 0), 1)), place \(f(screenX(761), 1)), pointer \(f(screenX(1100), 1))")
    }

    /// On a line already out, a ghost appears under the pointer and glides along the string to its place (the eye is
    /// led there); it never pops up far from the pointer.
    static func dropFreshGhost(_ c: Checker) {
        let (o, _) = dropEngine(prefix: "cl-drop-fresh")
        o.setFileDrag([URL(fileURLWithPath: "/tmp/cl-drop-fresh-new.png")])
        o.pointerMoved(to: CGPoint(x: 1300, y: o.stringY(at: 1300, ends: o.lineEnds())))
        var appeared: Double?
        runUntil(o, 1) { eng in
            if appeared == nil, let g = eng.ghostPose, g.alpha > 0.05 { appeared = Double(g.pivot.x) }
            return false
        }
        let rest = Double(o.ghostPose?.pivot.x ?? 0)
        c.check(appeared.map { abs($0 - 1300) < 40 } ?? false && abs(rest - screenX(761)) < 0.5,
                "gap: on a line already out the ghost appears under the pointer and glides along the string to its place",
                "appeared at \(appeared.map { f($0, 0) } ?? "never"), rests at \(f(rest, 1))")
    }

    /// Near either end of a line with hidden cards, the drag scrolls them into view.
    static func dropEdgeScroll(_ c: Checker) {
        let e = shownEngine(16)
        e.setFileDrag([URL(fileURLWithPath: "/tmp/cl-drop-edge.png")])
        e.pointerMoved(to: CGPoint(x: 1700, y: 60))
        let start = e.scroller.offset
        simulate(e, 0.5)
        let scrolled = e.scroller.offset - start
        e.pointerMoved(to: CGPoint(x: 900, y: 60))
        simulate(e, 1.0)
        c.check(scrolled > 200 && scrolled < 500 && e.scroller.isIdle,
                "drop: held near the end of a full line the drag scrolls the hidden cards into view (≤ 900 pt/s), and stops away from it",
                "\(f(scrolled, 0)) pt in 0.5 s")
    }

    // MARK: Releasing hangs the files at the gap

    static func dropInsert(_ c: Checker) {
        let (e, urls) = dropEngine()
        let dragged = URL(fileURLWithPath: "/tmp/cl-drop-dragged.png")
        e.setFileDrag([dragged])
        e.pointerMoved(to: CGPoint(x: screenX(459) + 40, y: 120))   // the third slot
        simulate(e, 0.6)
        let gapped = slotTargets(e)
        let ghostAt = e.ghostSlot.value
        let ghostBefore = e.ghostPose
        let added = e.drop([dragged])
        let order = e.urls
        c.check(added.count == 1 && order == [urls[0], urls[1], dragged, urls[2], urls[3]],
                "drop: releasing hangs the file at the gap (third place)", order.map(\.lastPathComponent).joined(separator: ", "))
        let after = slotTargets(e)
        c.check(abs(after[3] - gapped[2]) < 0.01 && abs(after[4] - gapped[3]) < 0.01 && abs((e.cards[added[0].id]?.slot.value ?? 0) - ghostAt) < 0.01,
                "… where the ghost was: the new card starts at the ghost, its neighbours stay where the gap put them",
                "card at \(f(e.cards[added[0].id]?.slot.value ?? 0, 1)), ghost was \(f(ghostAt, 1))")
        c.check(!e.acceptsDrop && e.fileDrag == nil, "… and the drag is over (the panel lets the mouse through again)")
        // The hand-off: the card starts exactly where the ghost hangs (same pivot and tilt; no hop up and no turn), the
        // ghost cross-fades into it in 0.1 s, the pin closing on the string is the landing (the string dips under it,
        // the card swings) and the card never rises above the string.
        var first: ClotheslineCardPose?, ghostAtFirst: ClotheslineCardPose?, landed: Double?, maxSwing = 0.0
        var worstSum = 0.0, worstApart = 0.0, ghostGoneAt: Double?, aboveString = 0.0, deepestDip = 0.0
        let start = e.time
        runUntil(e, 2) { eng in
            guard let card = eng.cards[added[0].id] else { return true }
            if landed == nil && card.arrived { landed = eng.time - start }
            if first == nil, card.startedAt != nil, let p = eng.pose(added[0].id) { first = p; ghostAtFirst = eng.ghostPose }
            if let p = eng.pose(added[0].id), p.alpha > 0 {
                if let g = eng.ghostPose {
                    worstSum = max(worstSum, abs(p.alpha + g.alpha - 1))
                    worstApart = max(worstApart, hypot(Double(p.pivot.x - g.pivot.x), Double(p.pivot.y - g.pivot.y)))
                } else if ghostGoneAt == nil {
                    ghostGoneAt = eng.time - start
                }
            }
            aboveString = max(aboveString, -card.drop.value)
            deepestDip = max(deepestDip, card.dip.value)
            maxSwing = max(maxSwing, abs(ClotheslineMath.degrees(card.angle - card.targetAngle)))
            return false
        }
        // Its first substep on the line: the same x; y only as far down as the string's dip under the closing pin.
        let dx = first.flatMap { p in ghostBefore.map { abs(Double(p.pivot.x - $0.pivot.x)) } } ?? 99
        let dy = first.flatMap { p in ghostBefore.map { Double(p.pivot.y - $0.pivot.y) } } ?? 99
        let turn = first.flatMap { p in ghostBefore.map { abs(ClotheslineMath.degrees(p.angle - $0.angle)) } } ?? 99
        c.check(dx < 0.1 && dy > -0.01 && dy < 1 && turn < 0.3 && (first?.alpha ?? 1) < 0.1 && (ghostAtFirst?.alpha ?? 0) > 0.9,
                "… no hop at the hand-off: the card's first frame is the ghost's place and tilt, and it starts transparent over the ghost",
                "moved \(f(dx, 2)) pt across, \(f(dy, 2)) pt down, turned \(f(turn, 2))°, first alpha \(f(first?.alpha ?? 1, 2)), ghost \(f(ghostAtFirst?.alpha ?? 0, 2))")
        c.check(worstSum < 0.02 && worstApart < 0.5 && ghostGoneAt.map { $0 <= 0.1 + 3 * h } ?? false,
                "… the ghost cross-fades into the card (one place, opacities adding up to 1) and is gone after 0.1 s",
                "sum off by \(f(worstSum, 3)), apart \(f(worstApart, 2)) pt, gone after \(ghostGoneAt.map { f($0 * 1000, 0) } ?? "never") ms")
        c.check(landed.map { $0 < 0.02 } ?? false && aboveString < 0.01 && deepestDip > 0.5 && maxSwing > 3 && maxSwing < 16,
                "… the pin closing on the string is the landing: the string dips under it and the card swings; it never rises above the string",
                "landed after \(landed.map { f($0 * 1000, 0) } ?? "never") ms, dip \(f(deepestDip, 1)) pt, above \(f(aboveString, 2)) pt, swing \(f(maxSwing, 1))°")
        // The hand's speed is handed over: let go moving right, the card's bottom swings on to the right (negative
        // spin), and the other way round; a still hand gives only the pin's catch.
        func startSpin(_ dx: Double) -> Double {
            let (t, _) = dropEngine(prefix: "cl-drop-tilt")
            let file = URL(fileURLWithPath: "/tmp/cl-drop-tilt-new.png")
            t.setFileDrag([file])
            for i in 0..<12 { t.pointerMoved(to: CGPoint(x: 1000 + Double(i) * dx, y: 60)); simulate(t, 1.0 / 60) }
            guard let id = t.drop([file]).first?.id else { return 0 }
            return t.cards[id]?.spin ?? 0
        }
        let right = startSpin(20), left = startSpin(-20), still = startSpin(0)
        c.check(right < -0.3 && left > 0.3 && abs(still) <= ClotheslineEngine.dropSettleSpin + 1e-9,
                "… the hand's speed is handed over: the card swings on the way the hand was going",
                "right \(f(right, 2)), left \(f(left, 2)), still \(f(still, 2)) rad/s")
        // Dropped past the last card: it lands where the ghost rested, at its place after the last card, and stays.
        let (g, _) = dropEngine(prefix: "cl-drop-glide")
        let far = URL(fileURLWithPath: "/tmp/cl-drop-glide-new.png")
        g.setFileDrag([far])
        g.pointerMoved(to: CGPoint(x: screenX(1100), y: 60))
        simulate(g, 0.6)
        guard let glider = g.drop([far]).first?.id else { c.check(false, "drop: glide"); return }
        g.step(h)       // its first frame on the line
        let firstX = g.pose(glider)?.pivot.x ?? 0
        var path: [Double] = [Double(firstX)]
        runUntil(g, 1.5) { eng in path.append(Double(eng.pose(glider)?.pivot.x ?? 0)); return false }
        let maxStep = zip(path.dropFirst(), path).map { abs($0 - $1) }.max() ?? 0
        c.check(abs(Double(firstX) - screenX(761)) < 0.5 && abs((path.last ?? 0) - screenX(761)) < 0.5 && maxStep < 0.5,
                "… past the last card it lands where the ghost rested, its place after the last card, and stays (no slide after landing)",
                "from \(f(Double(firstX), 1)) to \(f(path.last ?? 0, 1)), largest step \(f(maxStep, 2)) pt per 1/240 s")
        let job = URL(fileURLWithPath: "/tmp/cl-drop-job.png")
        e.hang([job])
        c.check(e.urls.first == job && e.urls[3] == dragged, "… a job's new files still arrive at the left, before the dropped one")

        // A file already on the line moves to the drop place instead of hanging twice.
        let (d, durls) = dropEngine(prefix: "cl-drop-dup")
        d.setFileDrag([durls[0]])
        d.pointerMoved(to: CGPoint(x: screenX(593) + 30, y: 120))  // the fourth slot
        let oldID = d.items[0].id
        let moved = d.drop([durls[0]])
        c.check(d.urls == [durls[1], durls[2], durls[0], durls[3]] && moved.count == 1 && d.cards[oldID]?.leaving == true,
                "drop: a file already on the line moves to the drop place (its old card lifts away) instead of hanging twice",
                d.urls.map(\.lastPathComponent).joined(separator: ", "))

        // Capacity: at most 50; the last files drop off, never the dropped ones.
        let full = ClotheslineEngine(geometry: sample)
        full.fileExists = { _ in true }
        let many = (0..<50).map { URL(fileURLWithPath: "/tmp/cl-drop-cap-\($0).png") }
        full.holdOpen = true
        full.hang(many)
        full.settleNow()
        runUntil(full, 3) { $0.state == .shown }
        let two = [URL(fileURLWithPath: "/tmp/cl-drop-capA.png"), URL(fileURLWithPath: "/tmp/cl-drop-capB.png")]
        full.setFileDrag(two)
        full.pointerMoved(to: CGPoint(x: 1690, y: 60))
        simulate(full, 0.2)
        full.pointerMoved(to: CGPoint(x: 400, y: full.stringY(at: 400, ends: full.lineEnds())))
        guard let at = full.dropIndex else {
            c.check(false, "drop: capacity setup", "state \(full.state.rawValue), band \(full.pointerInBand), fresh \(full.pointerFresh)")
            return
        }
        full.drop(two)
        c.check(full.items.count == 50 && full.urls[at] == two[0] && full.urls[at + 1] == two[1] && !full.urls.contains(many[49])
                && !full.urls.contains(many[48]),
                "drop: on a full line the two dropped files stay at the gap and the last two files drop off (50 at most)",
                "\(full.items.count) on the line, dropped at \(at)")
        // … and dropped after the last card of a full line (held at its right end until it has scrolled there).
        runUntil(full, 2) { $0.pendingArrivals.isEmpty }
        let last = URL(fileURLWithPath: "/tmp/cl-drop-capEnd.png")
        let oldest = full.urls[49]
        full.setFileDrag([last])
        for _ in 0..<14 { full.pointerMoved(to: CGPoint(x: 1700, y: full.stringY(at: 1700, ends: full.lineEnds()))); simulate(full, 1) }
        let endIndex = full.dropIndex
        full.drop([last])
        c.check(endIndex == 50 && full.items.count == 50 && full.urls[49] == last && !full.urls.contains(oldest),
                "drop: dropped after the last card of a full line it stays (the file before it drops off instead)",
                "slot \(endIndex.map(String.init) ?? "nil"), last \(full.urls.last?.lastPathComponent ?? "")")
    }

    // MARK: Leaving, cancelling

    static func dropCancel(_ c: Checker) {
        let (e, _) = dropEngine()
        let before = slotTargets(e)
        e.setFileDrag([URL(fileURLWithPath: "/tmp/cl-drop-cancel.png")])
        e.pointerMoved(to: CGPoint(x: screenX(283), y: 120))
        simulate(e, 0.5)
        e.setFileDrag(nil)      // Esc, or the source cancelled
        let closed = slotTargets(e)
        simulate(e, 0.6)
        c.check(!e.acceptsDrop && e.dropIndex == nil && zip(closed, before).allSatisfy { abs($0 - $1) < 0.01 } && e.ghostPose == nil
                && e.dropGlow.value < 0.05,
                "cancel: a cancelled drag closes the gap (the cards slide back), the ghost goes and the string dims")
        // Leaving the line's area during the drag closes the gap too, and the line goes 0.35 s later (it was the
        // pointer's 0.6 s: a hand that carried the files away has gone elsewhere with them).
        let (l, _) = dropEngine(prefix: "cl-drop-leave")
        l.holdOpen = false
        l.setFileDrag([URL(fileURLWithPath: "/tmp/cl-drop-leave-x.png")])
        l.pointerMoved(to: CGPoint(x: screenX(283), y: 120))
        simulate(l, 0.5)
        let wasOpen = l.acceptsDrop
        l.pointerMoved(to: CGPoint(x: 700, y: 500))
        let left = runUntil(l, 2) { $0.state == .retracting }
        c.check(wasOpen && !l.acceptsDrop && left.map { abs($0 - ClotheslineEngine.dragLeaveGrace) <= 2 * h } ?? false,
                "leave: dragging off the line's area closes the gap; the line retracts 0.35 s later",
                "\(left.map { f($0, 3) } ?? "never") s")
        simulate(l, 0.05)
        if let card = l.items.first.flatMap({ l.pose($0.id) }) {
            l.pointerMoved(to: ClotheslineEngine.toScene(card, CGPoint(x: 0, y: 40)))
        }
        c.check(l.state == .revealing, "… the same drag coming back onto a card catches the line on its way up", l.state.rawValue)
        // An empty line that came out for the drag: 0.35 s after the drag leaves it, at once when the drag ends.
        let file = [URL(fileURLWithPath: "/tmp/cl-drop-empty.png")]
        let m = ClotheslineEngine(geometry: sample)
        m.fileExists = { _ in true }
        m.setFileDrag(file)
        m.pointerMoved(to: CGPoint(x: 868, y: 18))
        runUntil(m, 1.5) { $0.state == .shown }
        m.pointerMoved(to: CGPoint(x: 868, y: 500))
        let emptyLeft = runUntil(m, 2) { $0.state == .retracting }
        let n = ClotheslineEngine(geometry: sample)
        n.fileExists = { _ in true }
        n.setFileDrag(file)
        n.pointerMoved(to: CGPoint(x: 868, y: 18))
        runUntil(n, 1.5) { $0.state == .shown }
        simulate(n, 3)
        let stayed = n.state == .shown
        n.setFileDrag(nil)
        let ended = runUntil(n, 1) { $0.state == .retracting }
        c.check(emptyLeft.map { abs($0 - ClotheslineEngine.dragLeaveGrace) <= 2 * h } ?? false && stayed && ended.map { $0 <= 2 * h } ?? false,
                "empty line: it stays while the files are over it, goes 0.35 s after they leave, and at once when the drag ends",
                "left \(emptyLeft.map { f($0, 3) } ?? "never") s, ended \(ended.map { f($0, 3) } ?? "never") s")
    }

    // MARK: Retract rules after a drop

    static func dropRetract(_ c: Checker) {
        let e = fakeEngine(3, prefix: "cl-drop-rr")
        runUntil(e, 6) { $0.state == .hidden && $0.time > 1 }
        let file = URL(fileURLWithPath: "/tmp/cl-drop-rr-new.png")
        e.setFileDrag([file])
        e.pointerMoved(to: CGPoint(x: 868, y: 18))
        runUntil(e, 1.5) { $0.state == .shown && $0.isSettled }
        // Held over the ghost's body (at the place after the last card, under the string): the ghost belongs to the band.
        e.pointerMoved(to: CGPoint(x: 1100, y: 60))
        simulate(e, 1)
        if let g = e.ghostPose { e.pointerMoved(to: ClotheslineEngine.toScene(g, CGPoint(x: 0, y: 90))) }
        simulate(e, 4)
        c.check(e.state == .shown && e.acceptsDrop, "after-drop rules: the line never goes while files are held over it (the ghost counts)",
                e.state.rawValue)
        // The button goes up over the line: the drop arrives separately and still lands.
        e.fileDragReleased()
        simulate(e, 0.1)
        let waiting = e.awaitingDrop && e.acceptsDrop
        let added = e.drop([file])
        e.pointerMoved(to: CGPoint(x: 600, y: 600))
        var landedAt: Double?
        let retractAt = runUntil(e, 6) { eng in
            if landedAt == nil, let card = eng.cards[added.first?.id ?? UUID()], card.arrived { landedAt = eng.time }
            return eng.state == .retracting
        }
        let start = e.time - (retractAt ?? 0)
        let hold = landedAt.map { e.time - $0 }
        c.check(waiting && !added.isEmpty && hold.map { abs($0 - 2) <= 2 * h } ?? false,
                "after-drop rules: a release seen before its drop still lands; then the usual hold: 2 s after the card lands, it retracts",
                "landed \(landedAt.map { f($0 - start, 3) } ?? "never") s, retract \(hold.map { f($0, 3) } ?? "?") s after")
        // A release whose drop never comes (the source refused): the drag ends after 0.5 s.
        let g = fakeEngine(3, prefix: "cl-drop-grace")
        runUntil(g, 6) { $0.state == .hidden && $0.time > 1 }
        g.setFileDrag([file])
        g.pointerMoved(to: CGPoint(x: 868, y: 18))
        runUntil(g, 1.5) { $0.state == .shown }
        g.fileDragReleased()
        let ends = runUntil(g, 2) { $0.fileDrag == nil }
        c.check(ends.map { abs($0 - 0.5) <= 2 * h } ?? false && !g.acceptsDrop,
                "… a release over the line whose drop never comes ends the drag 0.5 s later", "\(ends.map { f($0, 3) } ?? "never") s")
    }

    // MARK: Reduce Motion

    static func dropReduceMotion(_ c: Checker) {
        let (e, _) = dropEngine(reduceMotion: true, prefix: "cl-drop-rm")
        let dragged = URL(fileURLWithPath: "/tmp/cl-drop-rm-new.png")
        e.setFileDrag([dragged])
        guard let firstID = e.items.first?.id, let second = e.items.dropFirst().first?.id else { c.check(false, "rm items"); return }
        var visibleSlide = 0.0, last = e.cards[second]?.slot.value ?? 0, dipped = 1.0, stayed = 1.0
        e.pointerMoved(to: CGPoint(x: screenX(283), y: 120))
        runUntil(e, 0.5) { eng in
            let v = eng.cards[second]?.slot.value ?? 0
            if abs(v - last) > 0.01 && eng.reflowAlpha(of: second) > 0.05 { visibleSlide += abs(v - last) }
            last = v
            dipped = min(dipped, eng.reflowAlpha(of: second))
            stayed = min(stayed, eng.reflowAlpha(of: firstID))
            return false
        }
        c.check(visibleSlide == 0 && dipped < 0.05 && abs(last - (283 + 168)) < 0.01 && stayed > 0.999,
                "Reduce Motion: the gap opens as a cross-fade (the cards that make room fade out, change places, fade back in; nothing slides; the card before the gap stays)",
                "visible slide \(f(visibleSlide, 2)) pt, lowest opacity \(f(dipped, 2)), the first card's \(f(stayed, 2)), slot \(f(last, 1)) (target \(f(e.cards[second]?.slot.target ?? 0, 1)))")
        // The ghost fades in at full size (it doesn't grow).
        let (g, _) = dropEngine(reduceMotion: true, prefix: "cl-drop-rmg")
        g.setFileDrag([dragged])
        g.pointerMoved(to: lineSpot(g, screenX(1000)))
        simulate(g, 0.06)
        let half = g.ghostPose
        c.check((half?.alpha ?? 0) > 0.2 && (half?.alpha ?? 1) < 0.8 && half?.scale == 1 && abs(g.ghostSlot.value - 761) < 0.01,
                "… the ghost fades in at full size, at its place (after the last card)", "alpha \(f(half?.alpha ?? 0, 2)), scale \(f(half?.scale ?? 0, 3)), slot \(f(g.ghostSlot.value, 1))")
        // Dropped past the last card: it fades in at its place, the other cards don't blink.
        e.pointerMoved(to: lineSpot(e, screenX(1000)))
        simulate(e, 0.5)
        let added = e.drop([dragged])
        let calm = !e.isReflowing
        var maxSpin = 0.0, maxOff = 0.0
        runUntil(e, 1.5) { eng in
            if let card = eng.cards[added.first?.id ?? UUID()] {
                maxSpin = max(maxSpin, abs(card.spin)); maxOff = max(maxOff, abs(card.angle - card.targetAngle))
            }
            return false
        }
        let slot = e.cards[added.first?.id ?? UUID()]
        c.check(calm && maxSpin == 0 && maxOff < 1e-9 && slot.map { abs($0.slot.value - $0.slot.target) < 0.01 } ?? false,
                "… the dropped card fades in at its place: no swing, no slide, the other cards stay", "spin \(maxSpin), reflow \(!calm)")
    }

    // MARK: Routing: the panel takes the drag only while files are over the line

    /// A controller on an offscreen surface with a fake drag pasteboard (its count and files) and fake monitors.
    final class DropRig {
        var now = 900.0
        let engine: ClotheslineEngine
        let surface: ClotheslineOffscreenSurface
        let ctl: ClotheslineController
        var count = 5
        var payload: [URL] = []
        var escape = false
        /// The left button, the pointer (global) and the modifier keys as the controller polls them.
        var button = false
        var location = CGPoint.zero
        var flags: NSEvent.ModifierFlags = []
        var installs = 0, removed = 0
        init() {
            engine = ClotheslineEngine(geometry: sample, time: now)
            surface = ClotheslineOffscreenSurface(engine: engine)
            ctl = ClotheslineController(engine: engine, surface: surface, clock: ClotheslineManualClock(), now: { 0 })
            // Weak: the controller outlives the rig when a test hands it to Clothesline.shared, and its deinit removes
            // its monitors.
            ctl.now = { [weak self] in self?.now ?? 0 }
            ctl.usesTimers = false
            ctl.dragChangeCount = { [weak self] in self?.count ?? 0 }
            ctl.dragFiles = { [weak self] in self?.payload ?? [] }
            ctl.escapeDown = { [weak self] in self?.escape ?? false }
            ctl.leftButtonDown = { [weak self] in self?.button ?? false }
            ctl.pointerLocation = { [weak self] in self?.location ?? .zero }
            ctl.modifierFlags = { [weak self] in self?.flags ?? [] }
            ctl.monitorInstaller = { [weak self] in self?.installs += 1; return ["pointer-g", "pointer-l"] }
            ctl.dropMonitorInstaller = { [weak self] in self?.installs += 1; return ["drag-g", "drag-l"] }
            ctl.monitorRemover = { [weak self] _ in self?.removed += 1 }
        }
        func frames(_ seconds: Double) { for _ in 0..<Int((seconds * 60).rounded()) { now += 1.0 / 60; ctl.tick(at: now) } }
        func screen(_ p: CGPoint) -> CGPoint { sample.screenPoint(fromScene: p) }
        func press(_ p: CGPoint) { ctl.mouseEvent(.down, screen: screen(p)) }
        func drag(_ p: CGPoint) { ctl.mouseEvent(.dragged, screen: screen(p)) }
        func release(_ p: CGPoint) { ctl.mouseEvent(.up, screen: screen(p)) }
        /// A file drag from the desktop up to the notch, resting there until the line is out.
        func fileDragToNotch(_ files: [URL]) {
            press(CGPoint(x: 1100, y: 700))
            count += 1
            payload = files
            for i in 0...20 { drag(CGPoint(x: 1100 - Double(i) * 11, y: 700 - Double(i) * 33)); frames(1.0 / 60) }
            drag(CGPoint(x: 868, y: 18))
            frames(0.7)
        }
        /// The view's window coordinates for a scene point (offscreen: the view's own, y up).
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: surface.view.bounds.height - p.y) }
    }

    static func dropRouting(_ c: Checker) throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("photo.png")
        try Data("png".utf8).write(to: file)
        let r = DropRig()
        r.ctl.watchDrops()
        c.check(r.ctl.isWatchingDrops && r.installs == 1 && r.ctl.monitors.isEmpty,
                "routing: watching for drops adds only the drag monitors (no pointer monitors before anything hangs)")
        // An unused line and a drag far from the top: nothing is even looked at.
        r.press(CGPoint(x: 400, y: 800))
        r.count += 1
        r.payload = [file]
        let started = CACurrentMediaTime()
        for i in 0..<20000 { r.drag(CGPoint(x: 420 + Double(i % 50), y: 820)) }
        let perEvent = (CACurrentMediaTime() - started) / 20000 * 1e6
        c.check(r.ctl.dragWatch.reads == 0 && r.engine.fileDrag == nil && r.engine.pointer == nil && perEvent < 50,
                "routing: a file drag far from the line's display costs a rectangle test (the pasteboard isn't looked at, an unused line follows nothing)",
                "\(f(perEvent, 2)) µs per drag event")
        r.release(CGPoint(x: 420, y: 820))
        r.fileDragToNotch([file])
        c.check(r.engine.state != .hidden && !r.surface.ignoresMouse && r.surface.view.acceptsFileDrops
                && r.surface.view.registeredDraggedTypes.contains(.fileURL) && r.surface.view.hitTest(CGPoint(x: 868, y: 290)) === r.surface.view,
                "routing: files resting at the notch: the panel takes the drag there and the view is registered for file URLs",
                "state \(r.engine.state.rawValue), ignores \(r.surface.ignoresMouse)")
        r.drag(CGPoint(x: 600, y: 270))
        c.check(r.surface.ignoresMouse && !r.surface.view.acceptsFileDrops && r.surface.view.registeredDraggedTypes.isEmpty
                && r.surface.view.hitTest(CGPoint(x: 600, y: 30)) == nil,
                "routing: the same drag below the line: the mouse passes through and the view isn't registered (drops reach the windows below)")
        r.drag(CGPoint(x: 600, y: 900))
        c.check(r.surface.ignoresMouse && !r.surface.view.acceptsFileDrops, "routing: … and off the panel altogether")
        r.drag(lineSpot(r.engine, 868))
        let back = !r.surface.ignoresMouse
        r.escape = true
        r.drag(lineSpot(r.engine, 870))
        r.escape = false
        c.check(back && r.engine.fileDrag == nil && r.surface.ignoresMouse && r.ctl.dragWatch.finished,
                "routing: Esc over the line (the drag is cancelled) closes the gap and lets the mouse through at once")
        r.release(lineSpot(r.engine, 870))
        r.frames(1.5)
        // A drag with no files at the notch: today's pass-through.
        r.press(CGPoint(x: 1100, y: 700))
        r.count += 1
        r.payload = []
        r.drag(CGPoint(x: 868, y: 18))
        r.frames(0.5)
        c.check(r.surface.ignoresMouse && !r.surface.view.acceptsFileDrops && r.engine.fileDrag == nil && r.engine.state == .hidden,
                "routing: a drag without files at the notch passes through (no drop state, the panel takes no mouse)",
                r.engine.state.rawValue)
        r.release(CGPoint(x: 868, y: 18))
    }

    // MARK: The NSDraggingDestination methods, with a real named pasteboard

    static func dropDestination(_ c: Checker) throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("photo.png")
        try Data("png".utf8).write(to: file)
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let r = DropRig()
        r.ctl.watchDrops()
        r.fileDragToNotch([file])
        let view = r.surface.view
        var onString: CGPoint { lineSpot(r.engine, 700) }
        let info = ClotheslineDragInfo(files: [file], at: r.local(onString))
        let op = view.draggingEntered(info)
        let read = ClotheslineController.fileURLs(on: info.draggingPasteboard)
        c.check(read == [file] && op == .link, "destination: a real pasteboard with the file: the line answers link (the file stays put; no “+”)",
                "\(read.map(\.lastPathComponent)), op \(op.rawValue)")
        info.mask = [.copy, .generic]
        let generic = view.draggingUpdated(info)
        info.mask = [.copy, .move]
        let refused = view.draggingUpdated(info)
        let prepared = view.prepareForDragOperation(info)
        c.check(generic == .generic && refused == [] && !prepared, "destination: generic when the source offers no link; never copy or move",
                "\(generic.rawValue), \(refused.rawValue)")
        info.mask = [.copy, .move, .link, .generic]
        let text = ClotheslineDragInfo(files: [], at: r.local(onString), text: "hello")
        c.check(view.draggingUpdated(text) == [], "destination: a pasteboard with no file URLs is refused")
        info.location = r.local(CGPoint(x: 600, y: 280))
        let away = view.draggingUpdated(info)
        let passes = r.surface.ignoresMouse
        info.location = r.local(onString)
        _ = view.draggingUpdated(info)
        c.check(away == [] && passes && !r.surface.ignoresMouse, "destination: away from the string it answers nothing and lets the mouse through")
        // The release reaches YummyOrange before the drop (as can happen): the drop still lands.
        r.release(onString)
        let ok = view.prepareForDragOperation(info) && view.performDragOperation(info)
        view.draggingEnded(info)
        let after = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        c.check(ok && r.engine.urls == [file] && view.lastAnnouncement == "Added photo.png to the Clothesline",
                "destination: dropping hangs the file and VoiceOver hears “Added photo.png to the Clothesline”",
                view.lastAnnouncement ?? "nothing")
        c.check(after == before && FileManager.default.fileExists(atPath: file.path),
                "destination: the file is neither moved nor copied (its folder is unchanged)", after.joined(separator: ", "))
        c.check(r.ctl.monitors.count == 2 && !r.surface.view.acceptsFileDrops,
                "… the line now has a file: the pointer monitors come on (rest on the notch drops it again)")
        // An exit AppKit sends while the files are still over the line (another window came over the panel) is no
        // cancel: the line stays under them and still takes the drop. (It used to count as one, and the line could go
        // from under the files.)
        r.frames(4)
        let second = dir.appendingPathComponent("second.png")
        try Data("2".utf8).write(to: second)
        r.release(CGPoint(x: 868, y: 18))
        r.fileDragToNotch([second])
        r.drag(onString)
        let hovering = r.engine.acceptsDrop
        let exit = ClotheslineDragInfo(files: [second], at: r.local(onString))
        _ = view.draggingEntered(exit)
        view.draggingExited(exit)
        r.frames(1)
        let stays = r.engine.fileDrag != nil && r.engine.acceptsDrop && !r.surface.ignoresMouse && r.engine.state == .shown
        r.release(onString)
        let landed = view.prepareForDragOperation(exit) && view.performDragOperation(exit) && r.engine.urls.contains(second)
        view.draggingEnded(exit)
        c.check(hovering && stays && landed,
                "destination: an exit while the files are still over the line (no Esc) is no cancel: the line stays and takes the drop",
                "hovering \(hovering), stays \(stays), landed \(landed)")
    }

    // MARK: The monitors follow Show New Files

    static func dropMonitors(_ c: Checker) {
        let savedDefaults = Settings.defaults, savedController = Clothesline.shared.controller
        let savedTurnOff = ClotheslineMenuTarget.turnOffLine, savedRestore = ClotheslineMenuTarget.restoreLine
        Settings.defaults = SettingsMemoryStore()
        defer {
            ClotheslineMenuTarget.stopObservingSettings()
            Clothesline.shared.controller = savedController
            ClotheslineMenuTarget.turnOffLine = savedTurnOff
            ClotheslineMenuTarget.restoreLine = savedRestore
            Settings.defaults = savedDefaults
        }
        let r = DropRig()
        Clothesline.shared.controller = r.ctl
        ClotheslineMenuTarget.turnOffLine = { Clothesline.shared.turnOff() }
        ClotheslineMenuTarget.restoreLine = { Clothesline.shared.hang($0) }
        Settings.resultsDestination = .shelf
        if ProcessInfo.processInfo.environment["DW_SELFCHECK_LINE"] == nil { ClotheslineModule.appDidLaunch() }
        let shelfAtLaunch = Clothesline.shared.isWatchingDrops
        Settings.resultsDestination = .clothesline   // the launch hook's observer: settingsChanged()
        let on = Clothesline.shared.isWatchingDrops && r.ctl.dropMonitors.count == 2
        Settings.resultsDestination = .finder
        let off = !Clothesline.shared.isWatchingDrops && r.removed == 2
        c.check(!shelfAtLaunch && on && off,
                "monitors: none On a Shelf; choosing On the Clothesline adds the drag monitors; another place removes them",
                "shelf \(shelfAtLaunch), clothesline \(on), finder \(off)")
        ClotheslineMenuTarget.stopObservingSettings()
        let fresh = DropRig()
        Clothesline.shared.controller = fresh.ctl
        Settings.defaults = SettingsMemoryStore(["resultsDestination": ResultsDestination.clothesline.rawValue])
        if ProcessInfo.processInfo.environment["DW_SELFCHECK_LINE"] == nil { ClotheslineModule.appDidLaunch() }
        c.check(Settings.resultsDestination == .clothesline && fresh.ctl.isWatchingDrops,
                "monitors: launched On the Clothesline, the line listens for dropped files at once (before any job)")
    }

    // MARK: Dropped files are followed when a card moves them

    static func dropFollow(_ c: Checker) throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dropped.txt")
        try Data("x".utf8).write(to: file)
        let folder = dir.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = ClotheslineEngine(geometry: sample)
        let view = ClotheslineView(engine: engine, frame: CGRect(origin: .zero, size: sample.panelFrame.size))
        engine.onItemsChange = { view.itemsChanged() }
        engine.setFileDrag([file])
        engine.pointerMoved(to: CGPoint(x: 868, y: 18))
        runUntil(engine, 1.5) { $0.state == .shown }
        guard let id = engine.drop([file]).first?.id else { c.check(false, "follow: drop"); return }
        runUntil(engine, 1) { $0.pendingArrivals.isEmpty }
        // The drag is over; the pointer leaves, the line goes; resting on the notch (no button) drops it again.
        engine.pointerMoved(to: CGPoint(x: 600, y: 600))
        let gone = runUntil(engine, 4) { $0.state == .hidden }
        engine.pointerMoved(to: CGPoint(x: 868, y: 18))
        let back = runUntil(engine, 1) { $0.state != .hidden }
        c.check(gone != nil && back.map { abs($0 - ClotheslineGeometry.notchDwell) <= 2 * h } ?? false && engine.urls == [file],
                "follow: a line holding only a dropped file goes, and resting 0.5 s in the notch drops it again",
                "back after \(back.map { f($0 * 1000, 1) } ?? "never") ms")
        runUntil(engine, 1.5) { $0.state == .shown }
        engine.holdOpen = true
        let out = view.draggingItem(for: id)
        let pb = NSPasteboard(name: NSPasteboard.Name("DropWheel.clothesline.dropfollow.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        if let item = out?.item as? NSPasteboardWriting { pb.writeObjects([item]) }
        let dragged = ClotheslineController.fileURLs(on: pb)
        // What Finder does with the drag (same disk: a move), then the line looks again as after a drag out.
        let moved = folder.appendingPathComponent("dropped.txt")
        try FileManager.default.moveItem(at: file, to: moved)
        engine.pruneMissing()
        c.check(dragged == [file] && engine.item(id)?.url.standardizedFileURL == moved.standardizedFileURL && engine.items.count == 1,
                "follow: a dropped file dragged out to a folder (moved there) keeps its card, which follows it",
                engine.item(id)?.url.path ?? "gone")
    }
}

// MARK: - Review fixes

extension ClotheslineTests {
    /// Checks for what the motion and systems reviews of dropping found; each fails when its fix is undone.
    static func dropReviewChecks(_ c: Checker) {
        dropGhostOnTop(c)
        dropBandContinuity(c)
        dropReduceMotionSwap(c)
        dropGhostArt(c)
        do { try dropExitEdge(c) } catch { c.check(false, "exit edge setup", error.localizedDescription) }
        do { try dropRefusedCopy(c) } catch { c.check(false, "refused drag setup", error.localizedDescription) }
        do { try dropOwnWindow(c) } catch { c.check(false, "own-window drag setup", error.localizedDescription) }
        do { try dropPromised(c) } catch { c.check(false, "promised files setup", error.localizedDescription) }
        do { try dropStaleBaseline(c) } catch { c.check(false, "stale baseline setup", error.localizedDescription) }
    }

    /// How much of the ghost the card pictures drawn above it cover (the largest share by one card, by frame).
    static func ghostCoverage(_ view: ClotheslineView) -> Double {
        let ghost = view.ghostLayer
        guard !ghost.isHidden, ghost.opacity > 0.05, let layers = view.cardsLayer.sublayers,
              let gi = layers.firstIndex(where: { $0 === ghost }) else { return 0 }
        let g = ghost.frame
        guard g.width > 0, g.height > 0 else { return 0 }
        var worst = 0.0
        for l in layers[(gi + 1)...] where !l.isHidden && l.opacity > 0.3 && l.contents != nil {
            let i = g.intersection(l.frame)
            if !i.isNull { worst = max(worst, Double(i.width * i.height / (g.width * g.height))) }
        }
        return worst
    }

    /// The ghost glides past the card that changes sides each time the gap moves: it is drawn over the cards, so it is
    /// never hidden behind one, and the sweep along the cards never drops out of the drop in the gaps between them
    /// (HIG Drag and drop: clear and continuous feedback).
    static func dropGhostOnTop(_ c: Checker) {
        let (e, _) = dropEngine(prefix: "cl-drop-top")
        let view = ClotheslineView(engine: e, frame: CGRect(origin: .zero, size: sample.panelFrame.size))
        e.onItemsChange = { view.itemsChanged() }
        view.itemsChanged()
        e.setFileDrag([URL(fileURLWithPath: "/tmp/cl-drop-top-new.png")])
        e.pointerMoved(to: CGPoint(x: screenX(283), y: 120))
        simulate(e, 0.6)
        var worst = 0.0, changes = 0, last = e.dropIndex, out = 0, outAt: [String] = []
        // Along the cards and back at 600 pt/s: slot after slot.
        let xs = Array(stride(from: 283.0, through: 700, by: 10)) + Array(stride(from: 700.0, through: 283, by: -10))
        for x in xs {
            e.pointerMoved(to: CGPoint(x: screenX(x), y: 120))
            for _ in 0..<4 { e.step(h) }
            if e.dropIndex != last { changes += 1; last = e.dropIndex }
            if !e.acceptsDrop { out += 1; outAt.append("\(Int(x))") }
            view.render()
            worst = max(worst, ghostCoverage(view))
        }
        c.check(changes >= 4 && out == 0 && worst <= 0.3 && view.cardsLayer.sublayers?.last === view.ghostLayer,
                "ghost: while the gap moves slot after slot the ghost glides over the card changing sides, never hidden behind it",
                "\(changes) slot changes, at most \(f(worst * 100, 0)) % covered, \(out) frames out of the drop" + (outAt.isEmpty ? "" : " (at \(outAt.joined(separator: ", ")))"))
    }

    /// From the notch down to the string, straight and diagonally, on lines of 0 to 50 cards: the drop never drops out
    /// (a full line's sag puts its string 40 pt under the notch zone).
    static func dropBandContinuity(_ c: Checker) {
        var report: [String] = [], total = 0, offAt: [String] = []
        let file = [URL(fileURLWithPath: "/tmp/cl-drop-band-new.png")]
        for n in [0, 1, 4, 12, 50] {
            let e: ClotheslineEngine
            if n == 0 {
                e = ClotheslineEngine(geometry: sample)
                e.fileExists = { _ in true }
                e.setFileDrag(file)
                e.pointerMoved(to: CGPoint(x: 868, y: 20))
                runUntil(e, 2) { $0.state == .shown && $0.isSettled }
            } else {
                e = shownEngine(n)
                e.setFileDrag(file)
                e.pointerMoved(to: CGPoint(x: 868, y: 20))
                simulate(e, 0.5)
            }
            var off = 0
            // Straight down from the notch, and diagonally both ways from the zone's lower part (not across the menu
            // bar beside the notch, which isn't the line's).
            for (startY, targetX) in [(21.0, 868.0), (46, 700), (46, 1040)] {
                e.pointerMoved(to: CGPoint(x: 868, y: startY))
                simulate(e, 0.3)
                let endY = e.stringY(at: targetX, ends: e.lineEnds())
                for i in 0...60 {
                    let u = Double(i) / 60
                    e.pointerMoved(to: CGPoint(x: 868 + (targetX - 868) * u, y: startY + (endY - startY) * u))
                    simulate(e, 1.0 / 120)
                    if !e.acceptsDrop { off += 1; if offAt.count < 4 { offAt.append("\(n) cards at \(Int(868 + (targetX - 868) * u)), \(Int(startY + (endY - startY) * u))") } }
                }
            }
            total += off
            report.append("\(n) cards: \(off)")
        }
        c.check(total == 0, "band: from the notch down to the string (straight and diagonally, 0 to 50 cards) the drop never drops out",
                "steps out of the drop: " + report.joined(separator: ", ") + (offAt.isEmpty ? "" : " (\(offAt.joined(separator: "; ")))"))
    }

    /// Reduce Motion, the gap moving on one slot: only the card that changes sides fades out and back in; the other
    /// cards and the ghost stay fully shown, and the ghost moves while that card is faded out.
    static func dropReduceMotionSwap(_ c: Checker) {
        let (e, _) = dropEngine(reduceMotion: true, prefix: "cl-drop-rms")
        e.setFileDrag([URL(fileURLWithPath: "/tmp/cl-drop-rms-new.png")])
        e.pointerMoved(to: CGPoint(x: screenX(283), y: 120))
        simulate(e, 0.6)
        let ids = e.items.map(\.id)
        var lowest = [Double](repeating: 1, count: ids.count), ghostLowest = 1.0, moved = false, movedInSight = false
        var lastGhost = e.ghostSlot.value
        e.pointerMoved(to: CGPoint(x: screenX(459) + 10, y: 120))
        runUntil(e, 0.5) { eng in
            for (i, id) in ids.enumerated() { lowest[i] = min(lowest[i], eng.pose(id)?.alpha ?? 0) }
            ghostLowest = min(ghostLowest, eng.ghostPose?.alpha ?? 0)
            if abs(eng.ghostSlot.value - lastGhost) > 0.5 {
                moved = true
                if (eng.pose(ids[1])?.alpha ?? 0) > 0.05 { movedInSight = true }
                lastGhost = eng.ghostSlot.value
            }
            return false
        }
        let calm = [0, 2, 3].allSatisfy { lowest[$0] > 0.999 }
        c.check(e.dropIndex == 2 && calm && lowest[1] < 0.05 && ghostLowest > 0.999 && moved && !movedInSight,
                "Reduce Motion: when the gap moves on, only the card changing sides fades out and back in; the other cards and the ghost stay, and the ghost moves while that card is faded out",
                "lowest opacities \(lowest.map { f($0, 2) }.joined(separator: ", ")), ghost \(f(ghostLowest, 2)), ghost moved \(moved) (in sight \(movedInSight))")
    }

    /// The ghost is the card to be: its picture in the well at half strength over a translucent mat (a tray glyph
    /// only while the picture loads); a promised file shows its type.
    static func dropGhostArt(_ c: Checker) {
        let red = NSImage(size: CGSize(width: 120, height: 84), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
        // A point in the well's upper left, away from the tray glyph in its middle (image pixels at 2x, from the top).
        func pixel(_ thumbnail: NSImage?) -> (r: Double, g: Double, a: Double) {
            let content = ClotheslineArt.CardContent(name: "red.png", thumbnail: thumbnail, isIcon: false, duration: nil)
            guard let image = ClotheslineArt.ghostImage(width: 146, content: content, palette: .light, scale: 2),
                  let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let data = ctx.data else { return (0, 0, 0) }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let rect = ClotheslineArt.imageRect(width: 146)
            let x = Int((-40 - rect.minX) * 2), y = Int((30 - rect.minY) * 2)
            let p = data.assumingMemoryBound(to: UInt8.self) + y * image.width * 4 + x * 4
            let a = Double(p[3]) / 255
            return (Double(p[0]) / 255 / max(a, 0.001), Double(p[1]) / 255 / max(a, 0.001), a)
        }
        let picture = pixel(red), tray = pixel(nil)
        let promise = ClotheslineController.promiseURL(index: 0, type: "public.jpeg")
        let view = ClotheslineView(engine: ClotheslineEngine(geometry: sample), frame: CGRect(origin: .zero, size: sample.panelFrame.size))
        let promised = view.ghostContent([promise])
        c.check(picture.r - picture.g > 0.25 && picture.a < 0.98 && tray.r - tray.g < 0.15 && promised.name == "JPEG image"
                && promised.thumbnail != nil && view.ghostContent([promise, promise]).name == "2 files",
                "ghost art: the card to be, its picture at half strength on a translucent mat (a glyph only while it loads); a promised file shows its type",
                "picture pixel r \(f(picture.r, 2)) g \(f(picture.g, 2)) a \(f(picture.a, 2)); without one r \(f(tray.r, 2)) g \(f(tray.g, 2)); promise “\(promised.name)”")
    }

    /// A drag that steps 1 pt out of the line's area and straight back: the panel stops taking it at the first step,
    /// and AppKit's exit arrives with the next event's location, back inside. That is no cancel (no exit is, without
    /// Esc). Esc down when an exit arrives is one. (This stepped out of the notch zone when the zone was the edge.)
    static func dropExitEdge(_ c: Checker) throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("photo.png")
        try Data("png".utf8).write(to: file)
        var results: [String] = [], ok = true
        for monitorFirst in [false, true] {
            let r = DropRig()
            r.ctl.watchDrops()
            r.fileDragToNotch([file])
            let view = r.surface.view
            let inside = CGPoint(x: 700, y: 120)
            r.drag(inside)
            let info = ClotheslineDragInfo(files: [file], at: r.local(inside))
            _ = view.draggingEntered(info)
            r.frames(0.3)
            let edge = r.engine.dropArea(holding: true).maxY
            let a = CGPoint(x: 700, y: edge + 1), b = CGPoint(x: 700, y: edge - 1)
            info.location = r.local(a)
            _ = view.draggingUpdated(info)
            r.drag(a)
            let letGo = r.surface.ignoresMouse
            if monitorFirst { r.drag(b) }
            info.location = r.local(b)
            view.draggingExited(info)
            if !monitorFirst { r.drag(b) }
            r.drag(CGPoint(x: 700, y: 120))
            r.frames(0.5)
            let alive = r.engine.fileDrag != nil && r.engine.acceptsDrop && !r.ctl.dragWatch.finished && r.engine.state != .hidden
                && !r.surface.ignoresMouse
            ok = ok && letGo && alive
            results.append("exit \(monitorFirst ? "after" : "before") the move back: \(alive ? "still dropping" : "cancelled")")
            r.release(CGPoint(x: 700, y: 120))
        }
        c.check(ok, "exit: 1 pt out of the line's area and straight back is no cancel (the panel's own exit), in either order",
                results.joined(separator: "; "))
        let r = DropRig()
        r.ctl.watchDrops()
        r.fileDragToNotch([file])
        var onString: CGPoint { lineSpot(r.engine, 700) }
        r.drag(onString)
        let info = ClotheslineDragInfo(files: [file], at: r.local(onString))
        _ = r.surface.view.draggingEntered(info)
        r.drag(CGPoint(x: 600, y: 280))
        r.escape = true
        r.surface.view.draggingExited(info)
        r.escape = false
        c.check(r.engine.fileDrag == nil && r.ctl.dragWatch.finished, "exit: … but an exit with Esc down is a cancel, wherever it happens")
        r.release(CGPoint(x: 600, y: 280))
    }

    /// A source that only copies (⌥): no ghost, gap or glow, and letting go ends the drag at once; ⌥ held from the
    /// start is another drag for the line until it goes up.
    static func dropRefusedCopy(_ c: Checker) throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("photo.png")
        try Data("png".utf8).write(to: file)
        let r = DropRig()
        r.ctl.watchDrops()
        r.fileDragToNotch([file])
        let view = r.surface.view
        var onString: CGPoint { lineSpot(r.engine, 700) }
        r.drag(onString)
        let info = ClotheslineDragInfo(files: [file], at: r.local(onString), mask: [.copy])
        let op = view.draggingEntered(info)
        _ = view.draggingUpdated(info)
        r.frames(0.5)
        let quiet = (r.engine.ghostPose?.alpha ?? 0) < 0.01 && r.engine.dropGlow.value < 0.02 && !r.engine.showsGap
        let listens = !r.surface.ignoresMouse
        r.release(onString)
        let over = r.engine.fileDrag == nil && !r.engine.awaitingDrop && r.surface.ignoresMouse
        c.check(op == [] && quiet && listens && over,
                "refused: a copy-only drag shows no ghost, gap or glow (the panel still listens), and letting go ends it at once (no clicks held for 0.5 s)",
                "answered \(op.rawValue), quiet \(quiet), listening \(listens), over at once \(over)")
        r.frames(1)
        r.fileDragToNotch([file])
        r.drag(onString)
        let again = ClotheslineDragInfo(files: [file], at: r.local(onString), mask: [.copy])
        _ = view.draggingEntered(again)
        r.frames(0.3)
        again.mask = [.copy, .link, .generic]
        let op2 = view.draggingUpdated(again)
        r.frames(0.5)
        c.check(op2 == .link && (r.engine.ghostPose?.alpha ?? 0) > 0.9, "refused: … once the source offers a link again, the ghost comes back",
                "answered \(op2.rawValue)")
        r.release(onString)
        let o = DropRig()
        o.ctl.watchDrops()
        o.flags = [.option]
        o.fileDragToNotch([file])
        let ignored = o.engine.state == .hidden && o.engine.fileDrag == nil && o.engine.otherDrag && o.surface.ignoresMouse
        o.flags = []
        o.drag(CGPoint(x: 869, y: 18))
        o.frames(0.5)
        let heard = o.engine.state != .hidden && o.engine.fileDrag != nil
        c.check(ignored && heard, "refused: … ⌥ held from the start is another drag for the line (it stays in the notch) until ⌥ goes up",
                "ignored \(ignored), heard \(heard)")
        o.release(CGPoint(x: 869, y: 18))
    }

    /// A drag started in one of YummyOrange's own windows (a Float shelf): AppKit's drag loop keeps its events from the
    /// monitors, so only the poll of the button and the pointer sees it; it reaches the line all the same.
    static func dropOwnWindow(_ c: Checker) throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("shelf.png")
        try Data("png".utf8).write(to: file)
        let r = DropRig()
        r.ctl.watchDrops()
        r.button = true
        r.location = r.screen(CGPoint(x: 1100, y: 700))
        r.ctl.mouseEvent(.down, screen: r.location)      // the local monitor sees the press in the shelf
        r.count += 1                                    // the shelf's drag session writes the drag pasteboard
        r.payload = [file]
        for i in 0...20 {
            r.location = r.screen(CGPoint(x: 1100 - Double(i) * 11, y: 700 - Double(i) * 33))
            r.ctl.pollPress()
            r.frames(1.0 / 60)
        }
        r.location = r.screen(CGPoint(x: 868, y: 18))
        for _ in 0..<40 { r.ctl.pollPress(); r.frames(1.0 / 60) }
        let reached = r.engine.fileDrag == [file] && r.engine.state != .hidden && r.engine.acceptsDrop && !r.surface.ignoresMouse
        r.button = false
        r.ctl.pollPress()
        let released = !r.ctl.pressOpen && !r.ctl.dragWatch.pressed && r.engine.awaitingDrop
        c.check(reached && released,
                "own window: a drag from a Float shelf (its events never reach the monitors) reaches the line through the poll, and its release is seen",
                "reached \(reached), released \(released)")
    }

    /// Files an app only promises (Photos, Mail, Safari images): the drag counts as a file drag, the ghost names the
    /// type, the drop answers copy (the app writes a new file), and the gap waits until the file is written, then it
    /// hangs there.
    static func dropPromised(_ c: Checker) throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let olds = (0..<3).map { dir.appendingPathComponent("old\($0).txt") }
        for u in olds { try Data("x".utf8).write(to: u) }
        let r = DropRig()
        r.ctl.watchDrops()
        r.ctl.hang(olds)
        r.frames(4)
        let info = ClotheslineDragInfo(files: [], at: .zero, mask: [.copy], promises: ["public.jpeg"])
        let items = ClotheslineController.dragItems(on: info.pasteboard)
        let named = items.count == 1 && items.allSatisfy(ClotheslineController.isPromise) && r.surface.view.ghostContent(items).name == "JPEG image"
        r.fileDragToNotch(items)
        let out = r.engine.state != .hidden && r.engine.fileDrag == items
        r.frames(0.6)
        let second = r.engine.items.dropFirst().first.flatMap { r.engine.pose($0.id) }
        let onCard = second.map { ClotheslineEngine.toScene($0, CGPoint(x: 0, y: 40)) } ?? CGPoint(x: 300, y: 100)
        r.drag(onCard)
        r.frames(0.3)
        info.location = r.local(onCard)
        let op = r.surface.view.draggingEntered(info)
        let index = r.engine.dropIndex
        var deliver: ((URL?) -> Void)?, folder: URL?
        r.ctl.receivePromises = { _, f, done in folder = f; deliver = done }
        r.release(onCard)
        let took = r.surface.view.prepareForDragOperation(info) && r.surface.view.performDragOperation(info)
        r.surface.view.draggingEnded(info)
        r.drag(CGPoint(x: 1300, y: 700))
        r.frames(2)
        let waiting = r.engine.awaitingPromisedFiles && r.engine.showsGap && r.engine.state == .shown && (r.engine.ghostPose?.alpha ?? 0) > 0.9
        let written = (folder ?? dir).appendingPathComponent("Promised.jpeg")
        try Data("jpeg".utf8).write(to: written)
        deliver?(written)
        let hung = index.map { $0 < r.engine.urls.count && r.engine.urls[$0] == written } ?? false
        c.check(named && out && op == .copy && took && waiting && hung && (folder?.path.contains("YummyOrange Clothesline") ?? false)
                && r.surface.view.lastAnnouncement == "Added Promised.jpeg to the Clothesline",
                "promised files: a Photos-style drag drops the line, the ghost names the type, the drop is a copy, the gap waits while the file is written, then it hangs there",
                "named \(named), out \(out), answered \(op.rawValue), took \(took), waiting \(waiting), hung at \(index.map(String.init) ?? "nil") \(hung)")
        try? FileManager.default.removeItem(at: folder ?? dir)
    }

    /// After a card is dragged off the line (its own drag session keeps the mouse-up from the monitors), a window
    /// dragged by its title to the notch must not count as a drag of that card's file.
    static func dropStaleBaseline(_ c: Checker) throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("card.png")
        try Data("png".utf8).write(to: file)
        var results: [String] = [], ok = true
        for heard in [false, true] {
            let r = DropRig()
            r.ctl.watchDrops()
            r.ctl.hang([file])
            r.frames(1.5)
            guard let id = r.engine.items.first?.id, let pose = r.engine.pose(id) else { c.check(false, "stale baseline: no card"); return }
            let onCard = ClotheslineEngine.toScene(pose, CGPoint(x: 0, y: 60))
            r.press(onCard)
            r.engine.setPressed(id)
            r.count += 1
            r.payload = [file]
            r.engine.setPressed(nil)
            r.engine.isDragging = true
            for i in 0..<10 { r.drag(CGPoint(x: onCard.x + Double(i) * 30, y: onCard.y + Double(i) * 40)); r.frames(1.0 / 60) }
            r.engine.isDragging = false
            // The session ends; its mouse-up never reaches the monitors. With `heard` the view tells the controller.
            if heard { r.ctl.clotheslineOwnDragEnded() }
            let pressOver = !r.ctl.dragWatch.pressed
            r.frames(4)
            r.press(CGPoint(x: 1100, y: 700))
            for i in 0...20 { r.drag(CGPoint(x: 1100 - Double(i) * 11, y: 700 - Double(i) * 33)); r.frames(1.0 / 60) }
            r.drag(CGPoint(x: 868, y: 18))
            r.frames(0.7)
            let left = r.engine.fileDrag == nil && r.engine.otherDrag && r.engine.state == .hidden && r.surface.ignoresMouse
            ok = ok && left && (pressOver == heard)
            results.append("\(heard ? "told" : "not told"): \(left ? "another drag" : "taken for the card's file")")
            r.release(CGPoint(x: 868, y: 18))
        }
        c.check(ok, "stale baseline: after a card's own drag out, a window dragged to the notch is another drag (told the session ended or not)",
                results.joined(separator: "; "))
    }
}
#endif
