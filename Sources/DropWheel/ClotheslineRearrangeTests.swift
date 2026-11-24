#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit

/// Checks for the line's area under a drag and for moving cards along the string (part of `--selftest clothesline`):
/// files dragged over the line keep it out anywhere over its area and the panel takes them there, the line goes a
/// moment after they leave it and comes back for them; a card pressed and dragged follows the pointer 1:1, opens the
/// gap where it will go, leans with the hand, is hung there when let go, goes back with Esc, cross-fades under Reduce
/// Motion, scrolls the line at its ends, becomes a file drag off the line and can be hung again when it comes back;
/// clicks stay clicks; VoiceOver hears the moves and has Move Left and Move Right. Each one fails when the code it
/// checks is undone.
extension ClotheslineTests {
    static func rearrangeChecks(_ c: Checker) {
        areaKeepsDrop(c)
        areaGrace(c)
        areaFirstApproach(c)
        do { try areaRouting(c) } catch { c.check(false, "area routing setup", error.localizedDescription) }
        moveFollows(c)
        moveLean(c)
        moveRelease(c)
        moveEsc(c)
        moveRegrab(c)
        moveReduceMotion(c)
        moveEdgeScroll(c)
        moveOut(c)
        do { try moveView(c) } catch { c.check(false, "move view setup", error.localizedDescription) }
    }

    // MARK: Helpers

    /// Moves the pointer from where it is to `b` in 60 Hz steps over `seconds`, calling `each` after every step.
    static func glide(_ e: ClotheslineEngine, to b: CGPoint, seconds: Double, _ each: ((ClotheslineEngine) -> Void)? = nil) {
        let a = e.pointer ?? b
        let n = max(1, Int((seconds * 60).rounded()))
        for i in 1...n {
            let u = CGFloat(i) / CGFloat(n)
            e.pointerMoved(to: CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u))
            simulate(e, 1.0 / 60)
            each?(e)
        }
    }

    /// A point on card `index` (in its own frame: `local`), as it hangs now.
    static func onCard(_ e: ClotheslineEngine, _ index: Int, _ local: CGPoint = CGPoint(x: 0, y: 60)) -> CGPoint? {
        guard index < e.items.count, let pose = e.pose(e.items[index].id) else { return nil }
        return ClotheslineEngine.toScene(pose, local)
    }

    // MARK: The line's area keeps the drop

    /// While files are over the line, anywhere over its area keeps the drop (the ghost, the gap, the routing) and the
    /// line out: well below the string over the cards, over the menu bar beside the notch, out at either end; on lines
    /// of 0, 4 and 50 cards. Below the area it lets go.
    static func areaKeepsDrop(_ c: Checker) {
        var misses: [String] = [], below: [String] = [], gone: [String] = []
        let file = [URL(fileURLWithPath: "/tmp/cl-area-new.png")]
        for n in [0, 4, 50] {
            let e: ClotheslineEngine
            if n == 4 {
                e = dropEngine(prefix: "cl-area").0
            } else if n == 0 {
                e = ClotheslineEngine(geometry: sample)
                e.fileExists = { _ in true }
            } else {
                e = shownEngine(n)
            }
            e.holdOpen = false
            e.setFileDrag(file)
            e.pointerMoved(to: CGPoint(x: 868, y: 20))
            _ = runUntil(e, 2) { $0.state == .shown && $0.isSettled }
            let deep = 0.8 * Double(ClotheslineCardMetrics.matTop + ClotheslineCardMetrics.matHeight)
            let spots = [200.0, 600, 1100, 1500].map { CGPoint(x: $0, y: e.stringY(at: $0, ends: e.lineEnds()) + deep) }
                + [CGPoint(x: 300, y: 10), CGPoint(x: 1500, y: 10)]
                + [20.0, 1716].map { CGPoint(x: $0, y: e.stringY(at: $0, ends: e.lineEnds()) + 40) }
            for p in spots {
                glide(e, to: p, seconds: 0.25)
                if !e.acceptsDrop || e.dropIndex == nil { misses.append("\(n) cards at \(Int(p.x)), \(Int(p.y))") }
            }
            // Held well below the string for 3 s: the line stays out.
            glide(e, to: spots[2], seconds: 0.2)
            simulate(e, 3)
            if e.state != .shown || !e.acceptsDrop { gone.append("\(n) cards: \(e.state.rawValue)") }
            let edge = e.dropArea(holding: true).maxY
            glide(e, to: CGPoint(x: 900, y: edge + 20), seconds: 0.1)
            if e.acceptsDrop { below.append("\(n) cards at y \(Int(edge + 20))") }
        }
        c.check(misses.isEmpty && gone.isEmpty && below.isEmpty,
                "area: files over the line keep the drop anywhere over its area (well below the string over the cards, over the menu bar beside the notch, at either end; 0, 4 and 50 cards) and the line stays out; below the area they don't",
                misses.isEmpty && gone.isEmpty && below.isEmpty ? "all spots in the drop"
                    : "out of the drop at " + (misses + gone + below).joined(separator: "; "))
    }

    /// Leaving the area closes the gap at once and the line goes 0.35 s later; a wobble out and back within that
    /// keeps it; coming back while it goes away catches it; once it has gone, the area doesn't bring it out (only a rest
    /// in the notch does), so a drag on its way to a window under the line isn't caught.
    static func areaGrace(_ c: Checker) {
        let (e, _) = dropEngine(prefix: "cl-grace")
        e.holdOpen = false
        e.setFileDrag([URL(fileURLWithPath: "/tmp/cl-grace-new.png")])
        e.pointerMoved(to: CGPoint(x: screenX(283), y: 120))
        simulate(e, 0.5)
        let wasIn = e.acceptsDrop
        // A wobble: out below the area for 0.2 s, and back in well under the string.
        let edge = e.dropArea(holding: true).maxY
        e.pointerMoved(to: CGPoint(x: 700, y: edge + 10))
        let closed = !e.acceptsDrop && e.dropIndex == nil
        simulate(e, 0.2)
        e.pointerMoved(to: CGPoint(x: 700, y: e.dropArea(holding: false).maxY - 20))
        simulate(e, 2)
        let kept = e.state == .shown && e.acceptsDrop
        c.check(wasIn && closed && kept,
                "area: leaving it closes the gap at once; out and straight back within 0.35 s the line stays and the gap opens again",
                "closed \(closed), kept \(kept) (\(e.state.rawValue))")
        // Back in while it goes away: away from the string and the cards, but in the area.
        e.pointerMoved(to: CGPoint(x: 700, y: 600))
        _ = runUntil(e, 1) { $0.state == .retracting }
        simulate(e, 0.05)
        let back = CGPoint(x: 1300, y: e.dropArea(holding: false).maxY - 30)
        let offString = e.cardID(at: back, inflate: 8, minAlpha: 0.2) == nil && abs(Double(back.y) - e.stringY(at: 1300, ends: e.lineEnds())) > 20
        e.pointerMoved(to: back)
        let caught = e.state == .revealing
        c.check(offString && caught, "area: brought back into the area while the line goes away, the files catch it",
                "\(e.state.rawValue) at \(Int(back.x)), \(Int(back.y))")
        // Gone: the area alone doesn't bring it back, nor does heading up to the notch; resting 0.5 s in the notch does.
        e.pointerMoved(to: CGPoint(x: 700, y: 600))
        _ = runUntil(e, 3) { $0.state == .hidden }
        e.pointerMoved(to: CGPoint(x: 1300, y: 150))
        simulate(e, 0.5)
        let stayedIn = e.state == .hidden
        glide(e, to: CGPoint(x: 1000, y: 60), seconds: 0.1)
        glide(e, to: CGPoint(x: 868, y: 20), seconds: 0.1)
        let arrived = e.state == .hidden
        simulate(e, 0.5)
        c.check(stayedIn && arrived && e.state != .hidden,
                "area: once the line has gone, the area doesn't bring it out (a drag on its way to a window there), nor heading to the notch; resting 0.5 s in it does",
                "stayed in \(stayedIn), on arrival \(arrived ? "hidden" : e.state.rawValue), then \(e.state.rawValue)")
    }

    /// On a line that is out for another reason (a job's files), a file drag passing under it isn't caught by the area:
    /// it has to reach the string or a card first; from then on the whole area keeps it.
    static func areaFirstApproach(_ c: Checker) {
        let (e, _) = dropEngine(prefix: "cl-first")
        // A card moved by hand just before doesn't count as files having been over the line.
        if let grab = onCard(e, 0) {
            e.pointerMoved(to: grab)
            e.pickUp(e.items[0].id, at: grab)
            glide(e, to: CGPoint(x: Double(grab.x) + 150, y: Double(grab.y)), seconds: 0.3)
            e.releaseCard()
            simulate(e, 1)
        }
        // The file drag comes from elsewhere on the screen.
        e.pointerMoved(to: CGPoint(x: 1300, y: 700))
        e.setFileDrag([URL(fileURLWithPath: "/tmp/cl-first-new.png")])
        e.pointerMoved(to: CGPoint(x: 1300, y: 700))
        glide(e, to: CGPoint(x: 1300, y: 190), seconds: 0.3)
        let passing = !e.acceptsDrop
        glide(e, to: CGPoint(x: 1300, y: e.stringY(at: 1300, ends: e.lineEnds())), seconds: 0.2)
        let onString = e.acceptsDrop
        glide(e, to: CGPoint(x: 1300, y: 190), seconds: 0.2)
        c.check(passing && onString && e.acceptsDrop,
                "area: a file drag passing under a line that is out (a card was just moved on it) isn't caught until it reaches the string (or a card); then the whole area keeps it",
                "passing under \(!passing ? "caught" : "let through"), on the string \(onString), back under it \(e.acceptsDrop)")
    }

    // MARK: Routing: the panel takes the drag anywhere over the area

    static func areaRouting(_ c: Checker) throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let olds = (0..<4).map { dir.appendingPathComponent("old\($0).txt") }
        for u in olds { try Data("x".utf8).write(to: u) }
        let file = dir.appendingPathComponent("photo.png")
        try Data("png".utf8).write(to: file)
        let r = DropRig()
        r.ctl.watchDrops()
        r.ctl.hang(olds)
        r.frames(4)
        r.fileDragToNotch([file])
        let e = r.engine, view = r.surface.view
        var misses: [String] = []
        let deep = CGPoint(x: 1500, y: e.stringY(at: 1500, ends: e.lineEnds()) + 95)
        for p in [deep, CGPoint(x: 300, y: 10), CGPoint(x: 20, y: 90), CGPoint(x: 1716, y: 90), CGPoint(x: 600, y: 200)] {
            r.drag(p)
            r.frames(1.0 / 60)
            let local = r.local(p)
            if r.surface.ignoresMouse || !view.acceptsFileDrops || view.hitTest(local) !== view { misses.append("\(Int(p.x)), \(Int(p.y))") }
        }
        let edge = e.dropArea(holding: true).maxY
        r.drag(CGPoint(x: 700, y: edge + 15))
        let passes = r.surface.ignoresMouse && !view.acceptsFileDrops
        r.drag(deep)
        let info = ClotheslineDragInfo(files: [file], at: r.local(deep))
        let op = view.draggingEntered(info)
        r.release(deep)
        let took = view.prepareForDragOperation(info) && view.performDragOperation(info)
        view.draggingEnded(info)
        c.check(misses.isEmpty && passes && op == .link && took && e.urls.contains(file),
                "routing: the panel takes the drag anywhere over the line's area (well below the string, over the menu bar, at both ends) and lets it through below it; let go well below the string the file hangs",
                misses.isEmpty ? "answered \(op.rawValue), took \(took), passes below \(passes)" : "let through at " + misses.joined(separator: "; "))
    }

    // MARK: Moving a card along the string

    /// Picked up, a card's pin keeps the offset from where it was grabbed, frame by frame (no lag: the pose is the
    /// pointer's now), lifted and drawn in the air; nothing moves at the pick-up; the gap follows the card's pin (not
    /// the pointer) to the slot where it will go, its neighbours sliding apart.
    static func moveFollows(_ c: Checker) {
        let (e, urls) = dropEngine(prefix: "cl-move")
        let before = slotTargets(e)
        let id = e.items[3].id
        guard let pose0 = e.pose(id), let grab = onCard(e, 3, CGPoint(x: 40, y: 70)) else { c.check(false, "move: setup"); return }
        let offset = CGPoint(x: grab.x - pose0.pivot.x, y: grab.y - pose0.pivot.y)
        e.pointerMoved(to: grab)
        let picked = e.pickUp(id, at: grab)
        let still = slotTargets(e)
        let othersStill = zip([before[0], before[1], before[2]], [still[0], still[1], still[2]]).allSatisfy { abs($0 - $1) < 0.01 }
        // To the left along the string, 30 pt above it, in 60 Hz steps; checked right after each move.
        var worst = 0.0, airborne = true
        let target = CGPoint(x: screenX(340) + offset.x, y: e.stringY(at: screenX(340), ends: e.lineEnds()) - 30 + offset.y)
        let start = grab
        for i in 1...36 {
            let u = CGFloat(i) / 36
            let p = CGPoint(x: start.x + (target.x - start.x) * u, y: start.y + (target.y - start.y) * u)
            e.pointerMoved(to: p)
            if let q = e.pose(id) {
                worst = max(worst, hypot(Double(q.pivot.x - (p.x - offset.x)), Double(q.pivot.y - (p.y - offset.y))))
                airborne = airborne && q.flying && q.alpha > 0.99
            }
            simulate(e, 1.0 / 60)
        }
        simulate(e, 0.5)
        let lift = e.pose(id)
        c.check(picked && othersStill && worst < 0.01 && airborne && (lift?.lift ?? 0) > 0.95 && (lift?.scale ?? 0) > 1.02,
                "move: a picked-up card follows the pointer 1:1 from where it was grabbed (every frame, no lag), lifted and drawn in the air; nothing moves at the pick-up",
                "off by \(f(worst, 3)) pt at most, in the air \(airborne), lift \(f(lift?.lift ?? 0, 2)), others still \(othersStill)")
        // Its pin is nearer the second slot (ghost centres 107, 275, 459), the pointer 40 pt to its right nearer the third.
        let moved = slotTargets(e)
        let room = 146.0 + 22
        c.check(e.dropIndex == 1 && abs(moved[0] - before[0]) < 0.01 && abs(moved[1] - before[1] - room) < 0.01
                && abs(moved[2] - before[2] - room) < 0.01 && e.urls == urls,
                "move: the gap opens where the card will go (where its pin is, not the pointer): its neighbours slide apart by its width and a gap",
                "slot \(e.dropIndex.map(String.init) ?? "nil"), targets \(moved.map { f($0, 0) }.joined(separator: ", "))")
        // A middle card carried past the last one: the cards after its old place close up (it has no place of its own
        // while it is in the hand), and the gap waits after the last card.
        let (m, _) = dropEngine(prefix: "cl-move-mid")
        let mid = m.items[1].id
        guard let midGrab = onCard(m, 1) else { c.check(false, "move: middle setup"); return }
        m.pointerMoved(to: midGrab)
        m.pickUp(mid, at: midGrab)
        glide(m, to: CGPoint(x: screenX(900), y: Double(midGrab.y)), seconds: 0.5)
        let closed = slotTargets(m)
        // Cards 1, 3 and 4 without the second (162 pt): 107, then 442 − 184 and 593 − 184.
        c.check(m.dropIndex == 3 && abs(closed[0] - 107) < 0.01 && abs(closed[2] - 258) < 0.01 && abs(closed[3] - 409) < 0.01,
                "move: carried away from its place the card leaves no hole there: the cards after it close up, the gap opens where it will go",
                "slot \(m.dropIndex.map(String.init) ?? "nil"), targets \(closed.map { f($0, 0) }.joined(separator: ", "))")
    }

    /// In the hand the card leans with the hand's speed, its foot trailing (moving right: positive), at most 10°, and
    /// hangs plumb again once the hand rests.
    static func moveLean(_ c: Checker) {
        let (e, _) = dropEngine(prefix: "cl-lean")
        let id = e.items[1].id
        guard let grab = onCard(e, 1) else { c.check(false, "lean: setup"); return }
        e.pointerMoved(to: grab)
        e.pickUp(id, at: grab)
        func run(_ dx: Double) -> Double {
            var peak = 0.0
            for _ in 0..<30 {
                guard let p = e.pointer else { break }
                e.pointerMoved(to: CGPoint(x: Double(p.x) + dx, y: Double(p.y)))
                simulate(e, 1.0 / 60)
                if let a = e.cards[id]?.angle { peak = abs(a) > abs(peak) ? a : peak }
            }
            return ClotheslineMath.degrees(e.cards[id]?.angle ?? 0)
        }
        let right = run(10)            // 600 pt/s
        let left = run(-10)
        simulate(e, 1.5)
        let rest = ClotheslineMath.degrees(e.cards[id]?.angle ?? 99)
        c.check(right > 2 && right < 10.5 && left < -2 && left > -10.5 && abs(rest) < 1,
                "move: in the hand the card leans with the hand's speed (its foot trailing, at most 10°) and hangs plumb once the hand rests",
                "moving right \(f(right, 1))°, left \(f(left, 1))°, at rest \(f(rest, 2))°")
    }

    /// Let go over the line, the card is hung at the gap: from exactly where it is, its pin travels to its place and
    /// the string catches it (the string dips, the card swings a little), drawn in the air until then; the new order
    /// stays (a job's new files arrive before it as usual).
    static func moveRelease(_ c: Checker) {
        let (e, urls) = dropEngine(prefix: "cl-rehang")
        let id = e.items[3].id
        guard let grab = onCard(e, 3) else { c.check(false, "rehang: setup"); return }
        e.pointerMoved(to: grab)
        e.pickUp(id, at: grab)
        let offset = e.cardDrag?.grab ?? .zero
        let above = CGPoint(x: screenX(283) + Double(offset.x), y: e.stringY(at: screenX(283), ends: e.lineEnds()) - 25 + Double(offset.y))
        glide(e, to: above, seconds: 0.5)
        simulate(e, 0.4)
        let held = e.pose(id)
        let move = e.releaseCard()
        let first = e.pose(id)
        let jump = held.flatMap { h in first.map { hypot(Double($0.pivot.x - h.pivot.x), Double($0.pivot.y - h.pivot.y)) } } ?? 99
        var caughtAt: Double?, swing = 0.0, dip = 0.0, inAirUntilCaught = true
        let start = e.time
        _ = runUntil(e, 2.5) { eng in
            guard let card = eng.cards[id], let p = eng.pose(id) else { return true }
            if caughtAt == nil && !card.aloft { caughtAt = eng.time - start }
            if caughtAt == nil && !p.flying { inAirUntilCaught = false }
            if caughtAt != nil { swing = max(swing, abs(ClotheslineMath.degrees(card.angle - card.targetAngle))); dip = max(dip, abs(card.dip.value)) }
            return false
        }
        let rest = e.pose(id)
        let onString = rest.map { abs(Double($0.pivot.y) - e.stringY(at: Double($0.pivot.x), ends: e.lineEnds())) < 0.5 } ?? false
        // At the second place, 146 pt wide: 34 + 146 + 22 + 73.
        let atSlot = e.cards[id].map { abs($0.slot.value - $0.slot.target) < 0.1 && abs($0.slot.target - 275) < 0.01 } ?? false
        c.check(move == .init(id: id, from: 3, to: 1) && e.urls == [urls[0], urls[3], urls[1], urls[2]] && jump < 0.5
                && caughtAt.map { $0 < 0.5 } ?? false && inAirUntilCaught && swing > 1 && swing < 12 && dip > 0.3
                && onString && atSlot && rest?.flying == false,
                "move: let go over the line the card is hung at the gap: from where it is, its pin goes to its place and the string catches it (a dip, a small swing)",
                "moved \(move.map { "\($0.from)→\($0.to)" } ?? "no"), first step \(f(jump, 2)) pt, caught after \(caughtAt.map { f($0 * 1000, 0) } ?? "never") ms, swing \(f(swing, 1))°, dip \(f(dip, 1)) pt, on the string \(onString), at its slot \(atSlot)")
        let job = URL(fileURLWithPath: "/tmp/cl-rehang-job.png")
        e.hang([job])
        c.check(e.urls == [job, urls[0], urls[3], urls[1], urls[2]], "move: … the order stays (a job's new file arrives at the left as usual)",
                e.urls.map(\.lastPathComponent).joined(separator: ", "))
    }

    /// Esc while moving: the card goes back to its place (same order, its slot as before), the way it is hung when let go.
    static func moveEsc(_ c: Checker) {
        let (e, urls) = dropEngine(prefix: "cl-esc")
        let before = slotTargets(e)
        let id = e.items[1].id
        guard let grab = onCard(e, 1) else { c.check(false, "esc: setup"); return }
        e.pointerMoved(to: grab)
        e.pickUp(id, at: grab)
        glide(e, to: CGPoint(x: Double(grab.x) + 200, y: Double(grab.y) + 10), seconds: 0.4)
        simulate(e, 0.3)
        let gapMoved = e.dropIndex == 2
        let move = e.cancelCardDrag()
        _ = runUntil(e, 2) { $0.isSettled }
        let after = slotTargets(e)
        let home = e.pose(id).map { abs(Double($0.pivot.x) - screenX(283)) < 0.5 } ?? false
        c.check(gapMoved && move?.moved == false && e.urls == urls && zip(after, before).allSatisfy { abs($0 - $1) < 0.01 } && home
                && e.cardDrag == nil,
                "move: Esc puts the card back in its place (the order and every slot as before)",
                "gap had moved \(gapMoved), back home \(home)")
    }

    /// A card let go and still on its way to its place can be grabbed again, from where it is (nothing jumps).
    static func moveRegrab(_ c: Checker) {
        let (e, _) = dropEngine(prefix: "cl-regrab")
        let id = e.items[2].id
        guard let grab = onCard(e, 2) else { c.check(false, "regrab: setup"); return }
        e.pointerMoved(to: grab)
        e.pickUp(id, at: grab)
        glide(e, to: CGPoint(x: Double(grab.x) - 200, y: Double(grab.y) - 40), seconds: 0.4)
        e.releaseCard()
        simulate(e, 0.05)
        let midway = e.cards[id]?.aloft == true
        guard let pose = e.pose(id) else { c.check(false, "regrab: pose"); return }
        let again = ClotheslineEngine.toScene(pose, CGPoint(x: 0, y: 60))
        e.pointerMoved(to: again)
        let pressedOn = e.cardID(at: again) == id
        let took = e.pickUp(id, at: again)
        let jump = e.pose(id).map { hypot(Double($0.pivot.x - pose.pivot.x), Double($0.pivot.y - pose.pivot.y)) } ?? 99
        c.check(midway && pressedOn && took && jump < 0.5 && e.liftedCard == id,
                "move: a card let go and still on its way to its place can be grabbed again, from where it is",
                "on its way \(midway), under the pointer \(pressedOn), picked up \(took), moved \(f(jump, 2)) pt")
        e.cancelCardDrag()
    }

    /// Reduce Motion: no lean in the hand; let go, the card fades out where it is and in at its place (nothing slides,
    /// no swing); the gap opens as a cross-fade.
    static func moveReduceMotion(_ c: Checker) {
        let (e, urls) = dropEngine(reduceMotion: true, prefix: "cl-move-rm")
        let id = e.items[3].id
        guard let grab = onCard(e, 3) else { c.check(false, "rm move: setup"); return }
        e.pointerMoved(to: grab)
        e.pickUp(id, at: grab)
        var maxLean = 0.0
        glide(e, to: CGPoint(x: screenX(283) + Double(grab.x) - screenX(593), y: Double(grab.y) - 20), seconds: 0.5) { eng in
            maxLean = max(maxLean, abs(eng.cards[id]?.angle ?? 0))
        }
        simulate(e, 0.4)
        e.releaseCard()
        var lastPivot = e.pose(id)?.pivot, slide = 0.0, lowest = 1.0, spin = 0.0
        _ = runUntil(e, 1) { eng in
            guard let p = eng.pose(id) else { return true }
            if let l = lastPivot, p.alpha > 0.05 { slide += hypot(Double(p.pivot.x - l.x), Double(p.pivot.y - l.y)) }
            lastPivot = p.pivot
            lowest = min(lowest, p.alpha)
            spin = max(spin, abs(eng.cards[id]?.spin ?? 0))
            return false
        }
        let atSlot = e.pose(id).map { abs(Double($0.pivot.x) - screenX(275)) < 0.5 && $0.alpha > 0.999 && !$0.flying } ?? false
        c.check(maxLean < 1e-9 && slide < 0.01 && lowest < 0.05 && spin == 0 && atSlot && e.urls == [urls[0], urls[3], urls[1], urls[2]],
                "Reduce Motion: a moved card doesn't lean; let go it fades out where it is and in at its place (no slide, no swing)",
                "lean \(f(ClotheslineMath.degrees(maxLean), 2))°, visible slide \(f(slide, 2)) pt, lowest opacity \(f(lowest, 2)), spin \(spin), at its slot \(atSlot)")
        // Esc (or let go over its own place, where no slot changes): it cross-fades back the same way.
        let (r, _) = dropEngine(reduceMotion: true, prefix: "cl-move-rm-esc")
        let rid = r.items[1].id
        guard let rgrab = onCard(r, 1) else { c.check(false, "rm esc: setup"); return }
        r.pointerMoved(to: rgrab)
        r.pickUp(rid, at: rgrab)
        glide(r, to: CGPoint(x: Double(rgrab.x) + 30, y: Double(rgrab.y) + 50), seconds: 0.3)
        r.cancelCardDrag()
        var dipped = 1.0
        _ = runUntil(r, 1) { eng in dipped = min(dipped, eng.pose(rid)?.alpha ?? 0); return false }
        let home = r.pose(rid).map { abs(Double($0.pivot.x) - screenX(283)) < 0.5 && $0.alpha > 0.999 && !$0.flying } ?? false
        c.check(home && dipped < 0.05 && r.cards[rid]?.aloft == false,
                "Reduce Motion: Esc puts the card back with the same cross-fade (it never stays in the air)",
                "back home \(home), lowest opacity \(f(dipped, 2))")
    }

    /// Held near either end of a line longer than the screen, the card scrolls the hidden cards into view.
    static func moveEdgeScroll(_ c: Checker) {
        let e = shownEngine(16)
        let id = e.items[2].id
        guard let grab = onCard(e, 2) else { c.check(false, "edge: setup"); return }
        e.pointerMoved(to: grab)
        e.pickUp(id, at: grab)
        glide(e, to: CGPoint(x: 1700, y: Double(grab.y)), seconds: 0.4)
        let start = e.scroller.offset
        simulate(e, 0.5)
        let scrolled = e.scroller.offset - start
        let move = e.releaseCard()
        c.check(scrolled > 150 && (move?.to ?? 0) > 10, "move: held near the end of a full line the card scrolls the hidden cards into view, and is hung out there",
                "\(f(scrolled, 0)) pt in 0.5 s, hung at \(move.map { String($0.to) } ?? "nil")")
    }

    /// Down off the line's area the card becomes a file drag: the gap closes, the line goes 0.35 s later; carried back
    /// up to the notch the line comes out with the gap and the ghost, and let go there the same card moves (never a
    /// second card). A drag that ends elsewhere puts the card back in its place, fading in on a line that is out.
    static func moveOut(_ c: Checker) {
        let (e, urls) = dropEngine(prefix: "cl-out")
        e.holdOpen = false
        // The other three cards closed up: 162, 112 and 146 pt wide from 34 pt, 22 pt apart.
        let closedUp: [Double] = [115, 274, 425]
        let id = e.items[0].id
        guard let grab = onCard(e, 0) else { c.check(false, "out: setup"); return }
        e.pointerMoved(to: grab)
        e.pickUp(id, at: grab)
        let offset = e.cardDrag?.grab ?? .zero
        var leftAt: CGPoint?, leftTime = e.time
        for i in 1...40 {
            e.pointerMoved(to: CGPoint(x: Double(grab.x) + 2 * Double(i), y: Double(grab.y) + 10 * Double(i)))
            if e.cardLeftArea { leftAt = e.pointer; leftTime = e.time; break }
            simulate(e, 1.0 / 60)
        }
        e.cardWentOut()
        e.isDragging = true
        let others = slotTargets(e).dropFirst()
        let closed = e.dropIndex == nil && zip(others, closedUp).allSatisfy { abs($0 - $1) < 0.01 } && e.pose(id)?.alpha == 0
        e.pointerMoved(to: CGPoint(x: 700, y: 600))
        let retracting = runUntil(e, 2) { $0.state == .retracting }
        let goneAfter = retracting.map { _ in e.time - leftTime }
        _ = runUntil(e, 2) { $0.state == .hidden }
        c.check(leftAt.map { Double($0.y) > Double(e.geometry.menuBarHeight) + 100 } ?? false && closed
                && goneAfter.map { abs($0 - ClotheslineEngine.dragLeaveGrace) <= 2 * h } ?? false
                && e.state == .hidden,
                "move: dragged down off the line's area the card becomes a file drag: the gap closes, the line goes 0.35 s later",
                "left the area at y \(leftAt.map { String(Int($0.y)) } ?? "never"), gap closed \(closed), gone after \(goneAfter.map { f($0, 3) } ?? "never") s")
        // Back up toward the notch, then along the string to the third place.
        glide(e, to: CGPoint(x: 900, y: 70), seconds: 0.3)
        glide(e, to: CGPoint(x: 880, y: 20), seconds: 0.1)
        _ = runUntil(e, 1.5) { $0.state == .shown }
        let spot = CGPoint(x: screenX(442) + Double(offset.x) + 30, y: 120)
        glide(e, to: spot, seconds: 0.4)
        simulate(e, 0.5)
        let ghosted = e.acceptsDrop && (e.ghostPose?.alpha ?? 0) > 0.9 && e.dropIndex == 2 && e.dropGlow.value > 0.9
        let move = e.dropCard()
        e.isDragging = false
        e.cardDragEnded()
        _ = runUntil(e, 2) { $0.isSettled }
        let one = e.items.filter { $0.url == urls[0] }.count == 1 && e.items.count == 4 && e.items[2].id == id
        c.check(ghosted && move == .init(id: id, from: 0, to: 2) && one && e.urls == [urls[1], urls[2], urls[0], urls[3]],
                "move: carried back to the notch the line comes out with the gap and the ghost; let go there the same card moves (no second card)",
                "ghost and gap \(ghosted), moved \(move.map { "\($0.from)→\($0.to)" } ?? "no"), \(e.urls.map(\.lastPathComponent).joined(separator: ", "))")
        // A drag that ends elsewhere (a Finder folder) while the line is still out: the card fades in at its place.
        let (o, ourls) = dropEngine(prefix: "cl-out-end")
        o.holdOpen = false
        let oid = o.items[1].id
        guard let ograb = onCard(o, 1) else { c.check(false, "out end: setup"); return }
        o.pointerMoved(to: ograb)
        o.pickUp(oid, at: ograb)
        glide(o, to: CGPoint(x: Double(ograb.x), y: 600), seconds: 0.1)
        o.cardWentOut()
        o.isDragging = true
        o.isDragging = false
        o.cardDragEnded()
        let faint = o.pose(oid)?.alpha ?? 1
        simulate(o, 0.4)
        let back = o.pose(oid)
        let home = back.map { abs(Double($0.pivot.x) - screenX(283)) < 0.5 && $0.alpha > 0.99 } ?? false
        c.check(o.state != .hidden && faint < 0.1 && home && o.urls == ourls && o.cardDrag == nil,
                "move: a card's drag that ends elsewhere puts it back in its place (it fades in there on a line that is out)",
                "first \(f(faint, 2)), then home \(home)")
    }

    // MARK: The view and the panel: clicks, moves, Esc, the drag session, VoiceOver

    static func moveView(_ c: Checker) throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = (0..<4).map { dir.appendingPathComponent("photo-\($0).png") }
        for u in urls { try Data("png".utf8).write(to: u) }
        let r = DropRig()
        r.ctl.makeFlightSurface = { ClotheslineFlightOffscreenSurface(geometry: $0) }
        r.ctl.watchDrops()
        r.ctl.hang(urls)
        r.frames(1.5)
        let e = r.engine, view = r.surface.view
        func id(_ i: Int) -> UUID { e.items[i].id }
        func hover(_ p: CGPoint) { r.ctl.pointerMoved(screen: r.screen(p)); r.frames(0.2) }
        // Both of the panel's ways of hearing the mouse: the drag monitors, then the view.
        func down(_ p: CGPoint) { r.press(p); view.pressDown(at: p) }
        func move(_ p: CGPoint) { r.button = true; r.location = r.screen(p); r.drag(p); view.pressMoved(to: p) }
        func up(_ p: CGPoint) { r.button = false; r.location = r.screen(p); r.release(p); view.pressUp(at: p) }

        // A click: less than 3 pt of movement picks nothing up.
        guard let click = onCard(e, 2) else { c.check(false, "view: setup"); return }
        hover(click)
        down(click)
        let pressed = e.pressedCard == id(2) && !r.surface.ignoresMouse
        move(CGPoint(x: click.x + 2, y: click.y + 1))
        up(CGPoint(x: click.x + 2, y: click.y + 1))
        c.check(pressed && e.cardDrag == nil && view.lastDraggingItem == nil && e.urls == urls,
                "move (view): a press that moves less than 3 pt is a click (the card answers the press; nothing is picked up)",
                "pressed \(pressed), picked up \(e.cardDrag != nil)")

        // Pressed and dragged along the string: the panel keeps the mouse, the card is drawn in the flight window;
        // let go, it hangs at the gap and VoiceOver hears where.
        guard let grab = onCard(e, 3) else { return }
        hover(grab)
        down(grab)
        let moved = id(3)
        var keeps = true, inAir = true
        for i in 1...30 {
            move(CGPoint(x: grab.x - 15 * CGFloat(i), y: grab.y - CGFloat(i)))
            r.frames(1.0 / 60)
            keeps = keeps && !r.surface.ignoresMouse && view.hitTest(r.local(CGPoint(x: 1500, y: 280))) === view
            inAir = inAir && (r.ctl.flightSurface?.view.visibleCards == [moved]) && (view.cardLayerPair(moved)?.card.isHidden ?? false)
        }
        let to = e.dropIndex
        up(CGPoint(x: grab.x - 450, y: grab.y - 30))
        r.frames(1)
        let place = e.items.firstIndex { $0.id == moved }
        c.check(keeps && inAir && place == to && place != 3 && view.lastAnnouncement == "Moved photo-3.png to position \((place ?? 0) + 1)"
                && !r.ctl.flightWindowShown && !(view.cardLayerPair(moved)?.card.isHidden ?? true),
                "move (view): pressed and dragged along the string the card is carried in the air (the panel keeps the mouse); let go it hangs at the gap and VoiceOver hears “Moved photo-3.png to position \((place ?? 0) + 1)”",
                "kept the mouse \(keeps), in the air \(inAir), hung at \(place.map(String.init) ?? "nil"), heard \(view.lastAnnouncement ?? "nothing")")

        // Esc (the panel has no keyboard: the poll sees it): the card goes back; the rest of the press does nothing.
        let order = e.urls
        guard let escGrab = onCard(e, 0) else { return }
        hover(escGrab)
        down(escGrab)
        move(CGPoint(x: escGrab.x + 120, y: escGrab.y))
        move(CGPoint(x: escGrab.x + 260, y: escGrab.y))
        let wasMoving = e.liftedCard != nil
        r.escape = true
        r.ctl.pollPress()
        r.escape = false
        move(CGPoint(x: escGrab.x + 400, y: escGrab.y))
        up(CGPoint(x: escGrab.x + 400, y: escGrab.y))
        r.frames(1)
        c.check(wasMoving && e.cardDrag == nil && e.urls == order,
                "move (view): Esc during a move puts the card back (the panel never has the keyboard; the poll sees Esc) and the rest of the press does nothing",
                "moving \(wasMoving), order kept \(e.urls == order)")

        // Down off the line: the card's file goes to a drag session; the panel lets the mouse through; the line goes.
        let outID = id(1)
        let outURL = e.items[1].url
        guard let outGrab = onCard(e, 1) else { return }
        hover(outGrab)
        down(outGrab)
        var wentOut = false
        for i in 1...40 where !wentOut {
            move(CGPoint(x: outGrab.x + CGFloat(i), y: outGrab.y + 12 * CGFloat(i)))
            r.frames(1.0 / 60)
            wentOut = e.cardDrag?.out == true
        }
        let session = wentOut && e.isDragging && view.lastDraggingItem != nil && r.surface.ignoresMouse && !r.ctl.flightWindowShown
        // The session's loop has the mouse: only the poll sees it now.
        func poll(_ p: CGPoint) { r.button = true; r.location = r.screen(p); r.ctl.pollPress(); r.frames(1.0 / 60) }
        for i in 1...20 { poll(CGPoint(x: outGrab.x + 40, y: outGrab.y + 480 + CGFloat(i))) }
        r.frames(1.5)
        let hidden = e.state == .hidden
        // Back up to the notch, then over the string: the line comes out and the panel takes the drag again.
        for i in 0...20 { poll(CGPoint(x: 900 - CGFloat(i), y: 520 - 25 * CGFloat(i))) }
        for _ in 0..<60 { poll(CGPoint(x: 880, y: 20)) }
        let spot = CGPoint(x: 1000, y: 130)
        for i in 0...20 { poll(CGPoint(x: 880 + 6 * CGFloat(i), y: 20 + 5.5 * CGFloat(i))) }
        let takes = !r.surface.ignoresMouse && view.acceptsFileDrops
        let info = ClotheslineDragInfo(files: [outURL], at: r.local(spot))
        info.source = view
        let op = view.draggingEntered(info)
        r.button = false
        r.ctl.pollPress()
        let dropped = view.prepareForDragOperation(info) && view.performDragOperation(info)
        view.draggingEnded(info)
        view.ownDragEnded()
        r.frames(1)
        let place2 = e.items.firstIndex { $0.id == outID }
        let once = e.items.count == 4 && e.urls.filter { $0 == outURL }.count == 1
        let said = place2 == 1 || view.lastAnnouncement == "Moved \(outURL.lastPathComponent) to position \((place2 ?? 0) + 1)"
        c.check(session && hidden && takes && op == .generic && dropped && once && place2 != nil && said,
                "move (view): dragged down off the line the card becomes a file drag (the panel lets the mouse through, the line goes); brought back over the line the panel takes it again and the same card is hung there",
                "session \(session), hidden \(hidden), takes \(takes), answered \(op.rawValue), dropped \(dropped), one card \(once), at \(place2.map(String.init) ?? "nil")")

        // VoiceOver: Move Left and Move Right, and nothing past either end.
        r.frames(0.5)
        let elements = view.accessibilityCardElements
        func action(_ element: ClotheslineCardElement, _ name: String) -> Bool {
            element.accessibilityCustomActions()?.first { $0.name == name }?.handler?() ?? false
        }
        let second = elements[1], secondID = second.id
        let left = action(second, "Move Left")
        let heard = view.lastAnnouncement
        let atFront = e.items.first?.id == secondID
        let past = action(view.accessibilityCardElements[0], "Move Left")
        let right = action(view.accessibilityCardElements[0], "Move Right")
        c.check(left && atFront && heard == "Moved \(second.label) to position 1" && !past && right && e.items[1].id == secondID && view.accessibilityCardElements.contains { $0 === second },
                "VoiceOver: Move Left / Move Right move a card one place and say where (“Moved … to position 1”); nothing past the end; the card keeps its element (and the focus)",
                "left \(left), heard \(heard ?? "nothing"), past the end \(past), right \(right)")
    }
}
#endif
