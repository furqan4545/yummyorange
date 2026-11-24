#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit

/// Headless checks for `--selftest clothesline`.
enum ClotheslineTests {
    typealias Checker = ShelfAndWelcomeTests.Checker

    static func run() -> String {
        let c = Checker()
        physics(c)
        interruption(c)
        scrolling(c)
        timing(c)
        geometry(c)
        files(c)
        do { try controller(c) } catch { c.check(false, "controller setup", error.localizedDescription) }
        reduceMotion(c)
        do { try viewChecks(c) } catch { c.check(false, "view setup", error.localizedDescription) }
        hook(c)
        performance(c)
        ClotheslinePerfTests.checks(c)
        regressions(c)
        verifierChecks(c)
        dropChecks(c)
        rearrangeChecks(c)
        selectChecks(c)
        return c.report
    }

    // MARK: Helpers

    static let h = ClotheslineEngine.substep
    static let sample = ClotheslineGeometry.builtInSample

    /// An engine whose files all "exist" (fake paths), with `n` files already hanging and the line shown and still.
    static func shownEngine(_ n: Int = 3, reduceMotion: Bool = false, keepOpen: Bool = true) -> ClotheslineEngine {
        let e = ClotheslineEngine(geometry: sample, reduceMotion: reduceMotion)
        e.fileExists = { _ in true }
        e.holdOpen = true
        e.hang((0..<n).map { URL(fileURLWithPath: "/tmp/clothesline-test-\($0).png") })
        runUntil(e, 4) { $0.state == .shown && $0.pendingArrivals.isEmpty && $0.isSettled }
        e.holdOpen = keepOpen
        return e
    }

    /// Steps until `done` or `limit` seconds pass; returns the seconds taken (nil when it never happened).
    @discardableResult
    static func runUntil(_ e: ClotheslineEngine, _ limit: Double, _ done: (ClotheslineEngine) -> Bool) -> Double? {
        let start = e.time
        while e.time - start < limit {
            if done(e) { return e.time - start }
            e.step(h)
        }
        return done(e) ? e.time - start : nil
    }

    static func simulate(_ e: ClotheslineEngine, _ seconds: Double) {
        let steps = Int((seconds / h).rounded())
        for _ in 0..<steps { e.step(h) }
    }

    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("YummyOrange selftest clothesline \(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func f(_ x: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", x) }

    // MARK: Physics

    static func physics(_ c: Checker) {
        let e = ClotheslineEngine(geometry: sample)
        e.fileExists = { _ in true }
        e.hang([URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.mov"), URL(fileURLWithPath: "/tmp/c.pdf")])
        var peak = 0.0
        let out = runUntil(e, 2) { peak = max(peak, $0.line.value); return abs($0.line.value - 1) < 0.001 && abs($0.line.velocity) < 0.01 }
        c.check(out.map { $0 < 0.9 } ?? false, "line drops out of the notch and settles within 0.9 s (damping 0.85, response 0.45)",
                "settled in \(out.map { f($0) } ?? "never") s, overshoot \(f((peak - 1) * 100, 2)) %")
        c.check(peak < 1.02, "line overshoot under 2 %", f(peak, 4))
        runUntil(e, 3) { $0.state == .shown && $0.isSettled }
        let back = runUntil(e, 2) { _ in true }
        _ = back
        e.retract()
        let gone = runUntil(e, 2) { $0.state == .hidden }
        c.check(gone.map { $0 < 1.0 } ?? false, "line retracts into the notch within 1.0 s", "\(gone.map { f($0) } ?? "never") s")

        // Pendulum: a card knocked 10° off its rest angle.
        let s = shownEngine(3)
        guard let id = s.items.first?.id, var card = s.cards[id] else { c.check(false, "pendulum setup"); return }
        let rest = card.targetAngle
        card.angle = rest + ClotheslineMath.radians(10)
        card.spin = 0
        s.setCardForTesting(card)
        var lastSign = 0.0, swings = 0, lastBig = 0.0, maxAmp = 0.0
        let total = runUntil(s, 4) { eng in
            guard let a = eng.cards[id] else { return true }
            let d = ClotheslineMath.degrees(a.angle - a.targetAngle)
            maxAmp = max(maxAmp, abs(d))
            if abs(d) > 0.5 {
                lastBig = eng.time
                let sign = d > 0 ? 1.0 : -1.0
                if sign != lastSign { swings += 1; lastSign = sign }
            }
            return eng.isSettled
        }
        let calm = lastBig - (s.time - (total ?? 0))
        c.check(swings >= 3 && swings <= 6, "pendulum: 2–3 visible swings each way (|angle| > 0.5°)", "\(swings) half-swings over 0.5°")
        c.check(calm <= 2.0, "pendulum: within 0.5° in 2 s", "last 0.5° excursion at \(f(calm, 2)) s")
        c.check(total.map { $0 < 3.0 } ?? false, "pendulum fully at rest (0.09°) within 3 s, then the clock may stop",
                "\(total.map { f($0, 2) } ?? "never") s")

        // Secondary motion: cards swing out when the line drops (pin acceleration) and follow the slope at rest.
        let d = ClotheslineEngine(geometry: sample)
        d.fileExists = { _ in true }
        d.hang((0..<6).map { URL(fileURLWithPath: "/tmp/s\($0).png") })
        d.settleNow(); runUntil(d, 4) { $0.state == .shown && $0.isSettled }
        d.retract(); runUntil(d, 2) { $0.state == .hidden }
        d.pointerMoved(to: CGPoint(x: 868, y: 20))
        var maxSwing = 0.0
        runUntil(d, 1.2) { eng in
            for card in eng.cards.values { maxSwing = max(maxSwing, abs(ClotheslineMath.degrees(card.angle - card.targetAngle))) }
            return false
        }
        c.check(maxSwing > 2 && maxSwing < 16, "cards swing with the line's acceleration as it drops (secondary motion)",
                "max \(f(maxSwing, 1))° off rest")
        let left = d.items.last.flatMap { d.cards[$0.id] }, leftmost = d.items.first.flatMap { d.cards[$0.id] }
        c.check((leftmost?.targetAngle ?? 0) > 0 && (left?.targetAngle ?? 0) > 0,
                "cards on the left half tilt with the string's downward slope (clockwise)",
                "\(f(ClotheslineMath.degrees(leftmost?.targetAngle ?? 0), 2))°")
    }

    // MARK: Interruption

    static func interruption(_ c: Checker) {
        // Hover the notch mid-retract (the line half in): the line goes on in, and comes back out only once the pointer
        // has rested 0.5 s in the notch (most of a retract, so by then it is all but gone).
        let e = shownEngine(4)
        e.retract()
        runUntil(e, 2) { $0.line.value < 0.5 }
        let before = (value: e.line.value, velocity: e.line.velocity)
        e.pointerMoved(to: CGPoint(x: 868, y: 18))
        c.check(e.line.value == before.value && e.line.velocity == before.velocity, "hovering mid-retract doesn't move the line by itself",
                "value \(f(before.value, 4))")
        var backAt: Double?
        let entered = e.time
        for _ in 0..<Int(1.2 / h) {
            let target = e.line.target
            e.step(h)
            if backAt == nil && target == 0 && e.line.target == 1 { backAt = e.time - entered }
        }
        let dwell = ClotheslineGeometry.notchDwell
        c.check(backAt.map { $0 >= dwell - 1e-6 && $0 <= dwell + 2 * h } ?? false,
                "hovering the notch mid-retract: the line comes back out only after the 0.5 s rest",
                "at \(backAt.map { f($0 * 1000, 1) } ?? "never") ms")
        c.check(e.state == .revealing || e.state == .shown, "the line comes back out", e.state.rawValue)

        // Turning round mid-retract is continuous. The notch rest (0.5 s, and it can only start once the retract has)
        // can no longer turn the line round at this point, so Show Clothesline does, where the old 80 ms rest used to:
        // 80 ms after the line was half in.
        let r = shownEngine(4)
        r.retract()
        runUntil(r, 2) { $0.line.value < 0.5 }
        var values: [Double] = [r.line.value]
        var reversedAt: Double?, turnedAt: Double?
        var maxSecond = 0.0, maxPivotStep = 0.0
        var lastPivots: [UUID: CGPoint] = [:]
        for p in r.poses { lastPivots[p.id] = p.pivot }
        let start = r.time
        for _ in 0..<Int(1.2 / h) {
            let target = r.line.target
            if turnedAt == nil && r.time - start >= 0.08 - 1e-9 { turnedAt = r.line.value; r.reveal() }
            r.step(h)
            if reversedAt == nil && target == 0 && r.line.target == 1 { reversedAt = r.time - start }
            values.append(r.line.value)
            if values.count >= 3 {
                let n = values.count
                maxSecond = max(maxSecond, abs((values[n - 1] - values[n - 2]) - (values[n - 2] - values[n - 3])))
            }
            for p in r.poses {
                if let q = lastPivots[p.id] { maxPivotStep = max(maxPivotStep, hypot(Double(p.pivot.x - q.x), Double(p.pivot.y - q.y))) }
                lastPivots[p.id] = p.pivot
            }
        }
        c.check(reversedAt != nil && (turnedAt ?? 0) > 0.1, "turned round 80 ms after the line was half in, mid-retract",
                "at \(reversedAt.map { f($0 * 1000, 1) } ?? "never") ms, line \(turnedAt.map { f($0, 3) } ?? "?")")
        c.check(maxSecond < 0.01, "reversal is continuous: no step in position or velocity (max Δ² per 1/240 s)",
                "max Δ² \(f(maxSecond, 5)) (a restart would be ≈ \(f(turnedAt ?? before.value, 2)))")
        c.check(maxPivotStep < 30, "card pivots move continuously through the reversal (max per substep)", "\(f(maxPivotStep, 2)) pt")
        c.check(r.state == .revealing || r.state == .shown, "… and the line comes back out", r.state.rawValue)

        // Retract → caught → retract again quickly: still continuous. (The pointer catches it on a card, at the point
        // where an 80 ms rest in the notch used to: 0.23 s into the retract.)
        let q = shownEngine(2)
        q.retract(); simulate(q, 0.23)
        let caught: Bool
        if let pose = q.items.first.flatMap({ q.pose($0.id) }) {
            q.pointerMoved(to: ClotheslineEngine.toScene(pose, CGPoint(x: 0, y: 60)))
            caught = q.state == .revealing
        } else {
            caught = false
        }
        simulate(q, 0.1)
        q.pointerMoved(to: CGPoint(x: 1300, y: 600))
        q.holdOpen = false
        var prev = q.line.value, prevD: Double?, worst = 0.0, again = false
        for _ in 0..<Int(1.5 / h) {
            q.step(h)
            if q.state == .retracting { again = true }
            let d = q.line.value - prev
            if let prevD { worst = max(worst, abs(d - prevD)) }
            prev = q.line.value; prevD = d
        }
        c.check(caught && again && worst < 0.006, "back-and-forth (retract, caught on a card, leave) stays continuous (no step in position or velocity)",
                "caught \(caught), went again \(again), max Δ² \(f(worst, 5))")
    }

    // MARK: Scrolling

    static func scrolling(_ c: Checker) {
        typealias M = ClotheslineScrollMath
        let projected = M.project(1500)
        c.check(abs(projected - 1500.0 / 1000 * 0.998 / 0.002) < 1e-9, "projection is (v/1000)·d/(1−d) with d = 0.998", f(projected, 1))
        var s = ClotheslineScroller()
        s.maxOffset = 3000; s.dimension = 1700
        s.scroll(to: 200, animated: false)
        var t = 0.0
        s.handle(.init(phase: .began, delta: 0, time: t))
        for _ in 0..<8 { t += 1.0 / 60; s.handle(.init(phase: .changed, delta: 25, time: t)) }
        s.handle(.init(phase: .ended, delta: 0, time: t + 0.004))
        let start = s.offset, v = s.releaseVelocity
        c.check(abs(v - 1500) < 60, "release velocity from the last 80 ms of deltas", "\(f(v, 0)) pt/s (25 pt per 1/60 s)")
        var steps = 0
        while !s.isIdle && steps < 4000 { s.step(h, now: t + Double(steps) * h); steps += 1 }
        let expected = start + M.project(v)
        c.check(abs(s.offset - expected) / max(1, M.project(v)) < 0.015, "momentum comes to rest at the projected point (±1.5 %)",
                "rest \(f(s.offset, 1)), projected \(f(expected, 1))")

        // Past the end: a spring back with the velocity handed over, bounded overshoot, no undershoot.
        var b = ClotheslineScroller()
        b.maxOffset = 400; b.dimension = 1700
        b.scroll(to: 300, animated: false)
        t = 0
        b.handle(.init(phase: .began, delta: 0, time: t))
        for _ in 0..<6 { t += 1.0 / 60; b.handle(.init(phase: .changed, delta: 60, time: t)) }
        let bandedPeak = b.offset
        b.handle(.init(phase: .ended, delta: 0, time: t + 0.004))
        var peak = b.offset, minAfter = Double.infinity, settledAt: Double?
        for i in 0..<Int(3 / h) {
            b.step(h, now: t + Double(i) * h)
            peak = max(peak, b.offset)
            if b.offset < b.maxOffset + 50 { minAfter = min(minAfter, b.offset) }
            if b.isIdle { settledAt = Double(i) * h; break }
        }
        let rawPast = 300 + 360 - 400.0
        c.check(bandedPeak - 400 < rawPast && bandedPeak - 400 > 0, "dragging past the end rubber-bands (follows less than the finger)",
                "\(f(bandedPeak - 400, 1)) pt shown for \(f(rawPast, 0)) pt dragged")
        c.check(peak - 400 < 320, "overshoot past the end stays bounded", "\(f(peak - 400, 1)) pt")
        c.check(abs(b.offset - 400) < 0.06 && minAfter >= 400 - 0.5, "springs back exactly to the end without undershoot",
                "rest \(f(b.offset, 2)), lowest \(f(minAfter, 2))")
        c.check(settledAt.map { $0 < 1.6 } ?? false, "the rubber band settles within 1.6 s", "\(settledAt.map { f($0, 2) } ?? "never") s")

        // Flick toward the end from inside: momentum, then the bounce at the bound.
        var m = ClotheslineScroller()
        m.maxOffset = 300; m.dimension = 1700
        m.scroll(to: 100, animated: false)
        m.release(velocity: 2500)
        var mPeak = 0.0
        for i in 0..<Int(4 / h) { m.step(h, now: Double(i) * h); mPeak = max(mPeak, m.offset); if m.isIdle { break } }
        c.check(mPeak > 300 && mPeak < 300 + 2500 / (2 * .pi / ClotheslineScroller.bounceResponse * M_E) + 2 && abs(m.offset - 300) < 0.06,
                "a flick into the end overshoots by at most v/(ω·e) and returns", "peak +\(f(mPeak - 300, 1)) pt")

        // Rubber band function.
        let r1 = M.rubberband(100, dimension: 1700), r2 = M.rubberband(200, dimension: 1700), rBig = M.rubberband(1e7, dimension: 1700)
        c.check(r1 < 100 && r2 > r1 && rBig < 1700 && abs(M.unbanded(M.banded(520, maxOffset: 400, dimension: 1700), maxOffset: 400, dimension: 1700) - 520) < 1e-6,
                "rubber band: less than the overshoot, increasing, below the line length, invertible",
                "\(f(r1, 1)), \(f(r2, 1)), ∞→\(f(rBig, 0))")

        // Tilt against the scroll velocity, clamped, and the swing back.
        let e = shownEngine(16)
        let lineLength = Double(sample.rightEndX - sample.leftEndX)
        c.check(e.scroller.maxOffset > 0, "16 document cards overflow the line (cards run off the right edge)",
                "content \(f(e.contentWidth, 0)) pt for \(f(lineLength, 0)) pt")
        var tilt = 0.0
        let t0 = e.time
        e.scroll(.init(phase: .began, delta: 0, time: t0))
        for i in 1...10 {
            e.step(1.0 / 60 - 3 * h); e.step(h); e.step(h); e.step(h)
            e.scroll(.init(phase: .changed, delta: 40, time: e.time))
            if i == 10 { tilt = abs(e.scrollTilt) }
        }
        c.check(tilt > 6 && tilt <= ClotheslineEngine.maxScrollTilt + 0.6, "cards tilt against the scroll velocity, clamped near 12°",
                "\(f(tilt, 1))° at 2400 pt/s")
        e.scroll(.init(phase: .ended, delta: 0, time: e.time))
        let past = runUntil(e, 6) { $0.isSettled }
        c.check(past != nil && abs(e.scroller.offset - e.scroller.maxOffset) < 0.06,
                "released past the end, the cards spring back to it and settle", "\(past.map { f($0, 2) } ?? "never") s")

        // A gentle flick inside the bounds: the cards glide on with the release velocity, then stop at the end.
        let g = shownEngine(16)
        let cardID = g.items[3].id
        g.scroll(.init(phase: .began, delta: 0, time: g.time))
        for _ in 1...8 {
            for _ in 0..<4 { g.step(h) }
            g.scroll(.init(phase: .changed, delta: 9, time: g.time))
        }
        let firstX = g.cards[cardID]?.pivotX ?? 0
        let releasedAt = g.scroller.offset
        g.scroll(.init(phase: .ended, delta: 0, time: g.time + 0.004))
        let gv = g.scroller.releaseVelocity
        let rest = runUntil(g, 6) { $0.isSettled }
        let moved = g.scroller.offset - releasedAt
        let cardMoved = firstX - (g.cards[cardID]?.pivotX ?? 0)
        let glide = min(g.scroller.maxOffset, releasedAt + ClotheslineScrollMath.project(gv)) - releasedAt
        c.check(rest != nil && moved > 0 && abs(moved - glide) < 1.2 && abs(cardMoved - moved) < 10, "after the flick the cards glide on, stop and swing back to rest",
                "glided \(f(moved, 1)) pt (expected \(f(glide, 1))) at \(f(gv, 0)) pt/s, rest in \(rest.map { f($0, 2) } ?? "never") s")
        c.check(g.scroller.offset >= -0.01 && g.scroller.offset <= g.scroller.maxOffset + 0.01, "the offset ends inside its bounds",
                "\(f(g.scroller.offset, 1)) of \(f(g.scroller.maxOffset, 1))")
    }

    // MARK: Timing

    static func timing(_ c: Checker) {
        // 2 s after the last card arrives, pointer away.
        let e = ClotheslineEngine(geometry: sample)
        e.fileExists = { _ in true }
        e.pointerMoved(to: CGPoint(x: 1200, y: 700))
        e.hang((0..<3).map { URL(fileURLWithPath: "/tmp/t\($0).png") })
        var retractAt: Double?
        runUntil(e, 6) { eng in
            if eng.state == .retracting && retractAt == nil { retractAt = eng.time }
            return retractAt != nil
        }
        let hold = (retractAt ?? 0) - (e.lastArrival ?? 0)
        c.check(abs(hold - 2.0) <= 2 * h, "the line stays 2.0 s after the last card arrives, then retracts", "\(f(hold, 3)) s")
        let cascade = e.items.count == 3
        c.check(cascade, "three cards hung")

        // Not while the pointer is over the band; 0.6 s after it leaves.
        let p = ClotheslineEngine(geometry: sample)
        p.fileExists = { _ in true }
        p.hang((0..<3).map { URL(fileURLWithPath: "/tmp/p\($0).png") })
        runUntil(p, 1.5) { $0.pendingArrivals.isEmpty }
        guard let pose = p.items.first.flatMap({ p.pose($0.id) }) else { c.check(false, "pose"); return }
        let onCard = ClotheslineEngine.toScene(pose, CGPoint(x: 0, y: 60))
        p.pointerMoved(to: onCard)
        c.check(p.hoveredCard == p.items.first?.id && p.pointerInBand, "pointer on a card is in the band and hovers it")
        simulate(p, 5)
        c.check(p.state == .shown, "no retract while the pointer is over the line band (5 s)", p.state.rawValue)
        p.pointerMoved(to: CGPoint(x: 1200, y: 700))
        let left = p.time
        var at: Double?
        runUntil(p, 2) { eng in if eng.state == .retracting { at = eng.time; return true }; return false }
        c.check(at.map { abs($0 - left - 0.6) <= 2 * h } ?? false, "retracts 0.6 s after the pointer leaves",
                "\(at.map { f($0 - left, 3) } ?? "never") s")

        // Not while a card is held over the line; a moment after it is dragged off it. (This used to be "no retract
        // while a card is being dragged", wherever the drag went: now a card taken away from the line lets it go, as
        // files taken away from it do.)
        let d = shownEngine(2)
        d.holdOpen = false
        guard let held = d.items.first?.id, let heldPose = d.pose(held) else { c.check(false, "held pose"); return }
        let grab = ClotheslineEngine.toScene(heldPose, CGPoint(x: 0, y: 60))
        d.pointerMoved(to: grab)
        d.pickUp(held, at: grab)
        d.pointerMoved(to: CGPoint(x: grab.x + 300, y: grab.y + 20))
        simulate(d, 4)
        c.check(d.state == .shown, "no retract while a card is held over the line (4 s)", d.state.rawValue)
        d.pointerMoved(to: CGPoint(x: grab.x + 300, y: 600))
        d.cardWentOut()
        d.isDragging = true
        let dragAway = d.time
        var dAt: Double?
        runUntil(d, 2) { eng in if eng.state == .retracting { dAt = eng.time; return true }; return false }
        c.check(dAt.map { abs($0 - dragAway - ClotheslineEngine.dragLeaveGrace) <= 2 * h } ?? false,
                "a card dragged off the line: the line goes 0.35 s after it left (not only once the drag ends)",
                "\(dAt.map { f($0 - dragAway, 3) } ?? "never") s")
        d.isDragging = false
        d.cardDragEnded()

        // Notch dwell: the pointer has to stay in the notch for 0.5 s.
        let n = shownEngine(2, keepOpen: false)
        n.retract(); runUntil(n, 2) { $0.state == .hidden }
        n.pointerMoved(to: CGPoint(x: 868, y: 30))
        simulate(n, 0.05)
        n.pointerMoved(to: CGPoint(x: 600, y: 300))
        simulate(n, 0.2)
        c.check(n.state == .hidden, "a pass through the notch (50 ms, well under its 0.5 s rest) does nothing", n.state.rawValue)
        // Arriving along the menu bar, the pointer has to rest.
        n.pointerMoved(to: CGPoint(x: 300, y: 30))
        n.pointerMoved(to: CGPoint(x: 868, y: 30))
        let entered = n.time
        var revealAt: Double?
        runUntil(n, 1) { eng in if eng.state == .revealing { revealAt = eng.time; return true }; return false }
        c.check(revealAt.map { $0 - entered >= 0.5 - 1e-6 && $0 - entered <= 0.5 + 2 * h } ?? false,
                "resting 0.5 s in the notch drops the line", "\(revealAt.map { f(($0 - entered) * 1000, 1) } ?? "never") ms")
        notchDwell(c)
        // Stays while the pointer stays at the notch, retracts 0.6 s after it leaves.
        runUntil(n, 2) { $0.state == .shown }
        simulate(n, 3)
        c.check(n.state == .shown, "stays while the pointer rests at the notch", n.state.rawValue)
        n.pointerMoved(to: CGPoint(x: 400, y: 600))
        let gone = n.time
        var nAt: Double?
        runUntil(n, 2) { eng in if eng.state == .retracting { nAt = eng.time; return true }; return false }
        c.check(nAt.map { abs($0 - gone - 0.6) <= 2 * h } ?? false, "hover reveal: retracts 0.6 s after the pointer leaves",
                "\(nAt.map { f($0 - gone, 3) } ?? "never") s")

        // Empty line: hovering does nothing.
        let empty = ClotheslineEngine(geometry: sample)
        empty.pointerMoved(to: CGPoint(x: 868, y: 20))
        simulate(empty, 0.5)
        empty.reveal()
        simulate(empty, 0.2)
        c.check(empty.state == .hidden && empty.revealCount == 0, "nothing happens when the line is empty", empty.state.rawValue)

        // Explicit retract with the pointer at the notch: it waits for the pointer to leave and come back.
        let r = shownEngine(2)
        r.pointerMoved(to: CGPoint(x: 868, y: 20))
        simulate(r, 0.2)
        r.retract()
        simulate(r, 1.2)
        c.check(r.state == .hidden, "retract() wins over a pointer resting at the notch", r.state.rawValue)

        // Hanging more while it retracts turns it round.
        let m = shownEngine(2)
        m.retract(); simulate(m, 0.12)
        let v0 = m.line.value
        m.hang([URL(fileURLWithPath: "/tmp/late.png")])
        c.check(m.state == .revealing && m.line.value == v0, "hang() during a retract reverses from where the line is", f(v0, 3))
    }

    // MARK: The notch rest

    /// Only the notch itself brings the line out under the pointer, and only once the pointer has stayed inside it for
    /// 0.5 s: heading up toward it (fast, slow, with files) does nothing on the way; moving about inside a real notch
    /// still counts; leaving it starts over; on a display without a notch (menus live there) the pointer has to keep
    /// still too.
    static func notchDwell(_ c: Checker) {
        let dwell = ClotheslineGeometry.notchDwell
        let plain = ClotheslineGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeAreaTop: 0,
                                        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055), leftArea: nil, rightArea: nil)
        func hiddenLine(_ g: ClotheslineGeometry = sample) -> ClotheslineEngine {
            let e = fakeEngine(2, geometry: g, prefix: "cl-dwell")
            runUntil(e, 6) { $0.state == .hidden && $0.revealCount == 1 && $0.time > 1 }
            return e
        }
        /// Runs `seconds` in 1/60 s frames, calling `each(frame)` before every frame; returns when the line began to drop.
        func drive(_ e: ClotheslineEngine, _ seconds: Double, _ each: (Int) -> Void = { _ in }) -> Double? {
            var at: Double?
            e.onStateChange = { [unowned e] s in if s == .revealing && at == nil { at = e.time } }
            defer { e.onStateChange = nil }
            for frame in 0..<Int((seconds * 60).rounded()) {
                each(frame)
                simulate(e, 1.0 / 60)
            }
            return at
        }
        func onTime(_ delay: Double?) -> Bool { delay.map { $0 >= dwell - 1e-6 && $0 <= dwell + 2 * h } ?? false }
        func ms(_ delay: Double?) -> String { delay.map { "\(f($0 * 1000, 1)) ms" } ?? "never" }
        /// Moves the pointer from `a` to `b` at `speed` pt/s in 120 Hz steps. Returns where the line began to drop on the
        /// way (nil: it didn't) and when the pointer entered the notch.
        func sweep(_ e: ClotheslineEngine, from a: CGPoint, to b: CGPoint, speed: Double) -> (dropAt: CGPoint?, entered: Double?) {
            let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / (speed / 120)))
            var entered: Double?
            e.pointerMoved(to: a)
            for i in 1...n {
                let k = CGFloat(i) / CGFloat(n)
                let p = CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
                e.advance(to: e.time + 1.0 / 120)
                e.pointerMoved(to: p)
                if entered == nil && e.geometry.notchCore.contains(p) { entered = e.time }
                if e.state == .revealing { return (p, entered) }
            }
            return (nil, entered)
        }
        /// With the pointer left where it is: seconds from `entered` until the line starts to drop (nil: not within 1 s).
        func restDelay(_ e: ClotheslineEngine, since entered: Double?) -> Double? {
            guard let entered else { return nil }
            var at: Double?
            runUntil(e, 1) { eng in if eng.state == .revealing { at = eng.time; return true }; return false }
            return at.map { $0 - entered }
        }

        // Heading up toward the notch, slow or fast, from below or either side, no longer drops the line on the way (nor
        // as the pointer arrives); then left in the notch, it drops 0.5 s after the pointer went in.
        let nx = sample.notch.midX
        var early: [String] = [], late: [String] = []
        for speed in [300.0, 800, 2000] {
            for (label, from) in [("straight up", CGPoint(x: nx, y: 500)), ("from the lower left", CGPoint(x: nx - 400, y: 400)),
                                  ("from the lower right", CGPoint(x: nx + 420, y: 380))] {
                let e = hiddenLine()
                let run = sweep(e, from: from, to: CGPoint(x: nx, y: 10), speed: speed)
                if let at = run.dropAt { early.append("\(label) \(Int(speed)) pt/s: at (\(Int(at.x)), \(Int(at.y)))") }
                let delay = restDelay(e, since: run.entered)
                if !onTime(delay) { late.append("\(label) \(Int(speed)) pt/s: \(ms(delay))") }
            }
        }
        c.check(early.isEmpty, "heading up toward the notch no longer drops the line (on the way or on arrival), at any speed or angle",
                early.isEmpty ? "9 approaches" : early.joined(separator: "; "))
        c.check(late.isEmpty, "… left in the notch after the approach, it drops 0.5 s after the pointer went in (the moves inside count)",
                late.isEmpty ? "9 approaches" : late.joined(separator: "; "))
        do {
            let e = hiddenLine()
            let at = sweep(e, from: CGPoint(x: nx, y: 30), to: CGPoint(x: nx, y: 300), speed: 600).dropAt
            let flat = hiddenLine()
            let level = sweep(flat, from: CGPoint(x: nx - 300, y: 70), to: CGPoint(x: nx + 300, y: 66), speed: 600).dropAt
            let far = hiddenLine()
            let away = sweep(far, from: CGPoint(x: nx - 500, y: 400), to: CGPoint(x: nx - 300, y: 20), speed: 600).dropAt
            c.check(at == nil && level == nil && away == nil,
                    "moving down from the notch, level under it, or up toward the menu bar far to its side doesn't drop it",
                    "down \(at.map { "\($0)" } ?? "no"), level \(level.map { "\($0)" } ?? "no"), far \(away.map { "\($0)" } ?? "no")")
        }
        do {
            let e = hiddenLine()
            e.otherDrag = true
            let at = sweep(e, from: CGPoint(x: nx, y: 400), to: CGPoint(x: nx, y: 10), speed: 800).dropAt
            simulate(e, 1)
            c.check(at == nil && e.state == .hidden, "another app's drag heading to the notch and resting there 1 s doesn't drop it",
                    at.map { "\($0)" } ?? e.state.rawValue)
        }
        do {
            let e = ClotheslineEngine(geometry: sample)
            e.setFileDrag([URL(fileURLWithPath: "/tmp/cl-approach-drag.png")])
            let run = sweep(e, from: CGPoint(x: nx, y: 500), to: CGPoint(x: nx, y: 10), speed: 800)
            let delay = run.dropAt == nil ? restDelay(e, since: run.entered) : nil
            c.check(run.dropAt == nil && onTime(delay) && e.items.isEmpty,
                    "files carried up toward the notch don't drop the line on the way; resting 0.5 s in the notch drops even an empty line",
                    run.dropAt.map { "dropped on the way at y \(Int($0.y))" } ?? ms(delay))
        }

        // 0.49 s in the notch does nothing; 0.5 s drops it.
        do {
            let e = hiddenLine()
            e.pointerMoved(to: CGPoint(x: 868, y: 20))
            let entered = e.time
            simulate(e, 0.49)
            let short = e.state == .hidden
            let delay = restDelay(e, since: entered)
            c.check(short && onTime(delay), "0.49 s at rest in the notch doesn't drop the line; 0.5 s does",
                    "after 0.49 s \(short ? "hidden" : e.state.rawValue), dropped at \(ms(delay))")
        }
        // Moving about inside a real notch still counts (on a display without one, the same moves start over every time).
        do {
            let ring = (0..<12).map { i -> CGPoint in
                let a = Double(i) / 12 * 2 * .pi
                return CGPoint(x: 868 + 22 * cos(a), y: 20 + 14 * sin(a))
            }
            let e = hiddenLine()
            e.pointerMoved(to: CGPoint(x: 868, y: 20))
            let entered = e.time
            let at = drive(e, 1) { e.pointerMoved(to: ring[$0 % ring.count]) }
            let delay = at.map { $0 - entered }
            c.check(onTime(delay), "moving around inside the notch still counts: the line drops 0.5 s after the pointer went in",
                    ms(delay))
        }
        // Leaving the notch starts the rest over: 0.4 s in, out to the strip under it (window titles) and back in.
        do {
            let e = hiddenLine()
            e.pointerMoved(to: CGPoint(x: 868, y: 20))
            simulate(e, 0.4)
            e.pointerMoved(to: CGPoint(x: 868, y: 46))
            simulate(e, 1.0 / 60)
            e.pointerMoved(to: CGPoint(x: 868, y: 22))
            let back = e.time
            simulate(e, 0.49)
            let waited = e.state == .hidden
            let delay = restDelay(e, since: back)
            c.check(waited && onTime(delay), "leaving the notch starts the rest over: 0.4 s, out and back in, needs 0.5 s again",
                    "0.49 s after coming back \(waited ? "hidden" : e.state.rawValue), dropped at \(ms(delay)) after it")
        }
        // Without a notch: at rest 0.49 s does nothing and 0.5 s drops it; a hand's tremor (within 4 pt) is still at rest;
        // moving along the bar starts the rest over (menus live there), and the line drops 0.5 s after it stops.
        do {
            let rest = hiddenLine(plain)
            rest.pointerMoved(to: CGPoint(x: 960, y: 12))
            let entered = rest.time
            simulate(rest, 0.49)
            let short = rest.state == .hidden
            let delay = restDelay(rest, since: entered)
            let shaky = hiddenLine(plain)
            shaky.pointerMoved(to: CGPoint(x: 960, y: 12))
            let shakyIn = shaky.time
            let shook = drive(shaky, 1) { shaky.pointerMoved(to: CGPoint(x: 960 + ($0 % 2 == 0 ? 2 : -1), y: 12 + ($0 % 3 == 0 ? 1.5 : 0))) }
            let shakyDelay = shook.map { $0 - shakyIn }
            c.check(short && onTime(delay) && onTime(shakyDelay),
                    "without a notch, 0.49 s at rest in the virtual notch doesn't drop the line, 0.5 s does (a tremor within 4 pt still rests)",
                    "after 0.49 s \(short ? "hidden" : rest.state.rawValue), dropped at \(ms(delay)); trembling \(ms(shakyDelay))")
            let moving = hiddenLine(plain)
            moving.pointerMoved(to: CGPoint(x: 900, y: 12))
            var lastMove = moving.time
            let during = drive(moving, 2) { frame in
                guard frame > 0, frame % 15 == 0 else { return }
                moving.pointerMoved(to: CGPoint(x: 900 + Double(frame / 15) * 8, y: 12))
                lastMove = moving.time
            }
            let stopped = during == nil ? restDelay(moving, since: lastMove) : nil
            c.check(during == nil && onTime(stopped),
                    "without a notch, moving 8 pt every 0.25 s inside the virtual notch never drops it (2 s); 0.5 s after it stops, it does",
                    during.map { "dropped while moving at \(f($0 - lastMove, 3)) s" } ?? "dropped \(ms(stopped)) after the last move")
        }
    }

    // MARK: Geometry

    static func geometry(_ c: Checker) {
        let g = sample
        c.check(g.hasNotch && g.notch == CGRect(x: 838.5, y: 0, width: 59, height: 40) && g.menuBarHeight == 40,
                "notch = gap between the auxiliary top areas (838.5…897.5, 40 pt)", "\(g.notch)")
        c.check(g.hoverZone == CGRect(x: 826.5, y: 0, width: 83, height: 52), "hover zone: notch + 12 pt around and below",
                "\(g.hoverZone)")
        let inside: [CGPoint] = [CGPoint(x: 868, y: 20), CGPoint(x: 868, y: 51.9), CGPoint(x: 826.6, y: 5), CGPoint(x: 909.4, y: 45)]
        let outside: [CGPoint] = [CGPoint(x: 868, y: 52.1), CGPoint(x: 826.4, y: 5), CGPoint(x: 909.6, y: 5), CGPoint(x: 400, y: 10)]
        c.check(inside.allSatisfy(g.hoverZone.contains) && !outside.contains(where: g.hoverZone.contains),
                "hover zone edges (in: 4 points, out: 4 points)")
        let p = g.scenePoint(fromScreen: CGPoint(x: 868, y: 1133 - 20))
        c.check(p == CGPoint(x: 868, y: 20) && g.screenPoint(fromScene: p) == CGPoint(x: 868, y: 1113), "screen ↔ scene points")
        c.check(g.panelFrame == CGRect(x: 0, y: 833, width: 1736, height: 300) && g.lineY == 52 && g.leftEndX == 14 && g.rightEndX == 1722,
                "panel: full width, top 300 pt; line 12 pt under the menu bar, ends 14 pt inside the edges", "\(g.panelFrame)")
        let hidden = ClotheslineEngine.ends(spread: 0, fall: 0, sag: 0, geometry: g)
        let full = ClotheslineEngine.ends(spread: 1, fall: 1, sag: 0, geometry: g)
        c.check(hidden.left.y < g.menuBarHeight && hidden.right.y < g.menuBarHeight && g.notch.contains(hidden.left) && g.notch.contains(hidden.right),
                "hidden: both ends wait inside the notch", "\(hidden.left) … \(hidden.right)")
        c.check(full.left == CGPoint(x: 14, y: 52) && full.right == CGPoint(x: 1722, y: 52), "shown: the line spans the display")
        // The string never crosses the menu bar outside the notch, for any mix of spread, fall and sag.
        let probe = ClotheslineEngine(geometry: g)
        var highest = Double.infinity, worstAt = ""
        for s in stride(from: 0.0, through: 1.04, by: 0.02) {
            for fl in stride(from: -0.05, through: 1.15, by: 0.05) {
                for sag in [0.0, 6, 14, 30] {
                    let e = ClotheslineEngine.ends(spread: s, fall: fl, sag: sag, geometry: g)
                    for x in stride(from: Double(e.left.x), through: Double(e.right.x), by: 1.5)
                    where abs(x - Double(g.notchCenterX)) >= Double(g.notchHalf) {
                        let y = probe.stringY(at: x, ends: e)
                        if y < highest { highest = y; worstAt = "spread \(f(s, 2)), fall \(f(fl, 2)), x \(f(x, 1))" }
                    }
                }
            }
        }
        c.check(highest >= Double(g.menuBarHeight) + 1, "outside the notch the string stays under the menu bar (every spread, fall, sag)",
                "highest point y \(f(highest, 2)) at \(worstAt)")
        let pulled = ClotheslineEngine.ends(spread: 1, fall: 0, sag: 14, geometry: g)
        let beside = probe.stringY(at: Double(g.notch.minX) - 4, ends: pulled), centre = probe.stringY(at: Double(g.notchCenterX), ends: pulled)
        c.check(centre < Double(g.menuBarHeight) - 4 && beside <= Double(g.ceilingY) + 1.5,
                "pulled up: the string runs up to the menu bar's edge and its middle goes into the notch",
                "beside the notch y \(f(beside, 1)), centre y \(f(centre, 1))")

        // No notch: a 180 pt virtual notch at the top centre of the menu bar.
        let plain = ClotheslineGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeAreaTop: 0,
                                        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055), leftArea: nil, rightArea: nil)
        c.check(!plain.hasNotch && plain.notch == CGRect(x: 870, y: 0, width: 180, height: 25) && plain.hoverZone == CGRect(x: 858, y: 0, width: 204, height: 37),
                "no notch: virtual 180 pt zone in a 25 pt menu bar", "\(plain.notch), zone \(plain.hoverZone)")
        let side = ClotheslineGeometry(screenFrame: CGRect(x: 1736, y: 200, width: 2560, height: 1440), safeAreaTop: 0,
                                       visibleFrame: CGRect(x: 1736, y: 200, width: 2560, height: 1416), leftArea: nil, rightArea: nil)
        c.check(side.scenePoint(fromScreen: CGPoint(x: 1736 + 1280, y: 1640 - 10)) == CGPoint(x: 1280, y: 10) && side.hoverZone.contains(CGPoint(x: 1280, y: 10)),
                "a second display's origin is respected", "\(side.panelFrame)")
        let notchedSecond = ClotheslineGeometry(screenFrame: CGRect(x: 1920, y: 0, width: 1736, height: 1133), safeAreaTop: 40,
                                                leftArea: CGRect(x: 1920, y: 1093, width: 838.5, height: 40),
                                                rightArea: CGRect(x: 1920 + 897.5, y: 1093, width: 838.5, height: 40))
        let notchedRelative = ClotheslineGeometry(screenFrame: CGRect(x: 1920, y: 0, width: 1736, height: 1133), safeAreaTop: 40,
                                                  leftArea: CGRect(x: 0, y: 1093, width: 838.5, height: 40),
                                                  rightArea: CGRect(x: 897.5, y: 1093, width: 838.5, height: 40))
        c.check(notchedSecond.notch == g.notch && notchedRelative.notch == g.notch,
                "a notched display right of the main one: same notch from global or screen-relative areas",
                "\(notchedSecond.notch), \(notchedRelative.notch)")
        let rm = ClotheslineEngine(geometry: plain)
        c.check(rm.lineAlpha == 0, "without a notch the string is invisible while gathered (it would show on the menu bar)")
        // This Mac, for the record.
        if let screen = ClotheslineGeometry.preferredScreen() {
            let live = ClotheslineGeometry(screen: screen)
            c.check(true, "this Mac's line display", "\(Int(live.width))×\(Int(screen.frame.height)) pt, notch \(live.hasNotch ? "\(live.notch.minX)…\(live.notch.maxX)" : "virtual"), menu bar \(live.menuBarHeight) pt")
        }
    }

    // MARK: Files

    static func files(_ c: Checker) {
        let e = ClotheslineEngine(geometry: sample)
        e.fileExists = { _ in true }
        let first = (0..<30).map { URL(fileURLWithPath: "/tmp/cap-a\($0).png") }
        let second = (0..<30).map { URL(fileURLWithPath: "/tmp/cap-b\($0).png") }
        e.hang(first)
        e.hang(second)
        c.check(e.items.count == 50, "keeps the last 50 files", "\(e.items.count)")
        c.check(e.urls.first?.lastPathComponent == "cap-b0.png" && e.urls[29].lastPathComponent == "cap-b29.png" && e.urls[30].lastPathComponent == "cap-a0.png",
                "newest first from the left (a batch keeps its order)", e.urls.prefix(2).map(\.lastPathComponent).joined(separator: ", "))
        c.check(e.urls.last?.lastPathComponent == "cap-a19.png" && !e.urls.contains(where: { $0.lastPathComponent == "cap-a29.png" }),
                "the oldest drop off the right end", e.urls.last?.lastPathComponent ?? "")
        c.check(e.cards.count == 50, "one card per file", "\(e.cards.count)")
        e.hang([URL(fileURLWithPath: "/tmp/cap-a5.png")])
        c.check(e.items.count == 50 && e.urls.first?.lastPathComponent == "cap-a5.png" && e.urls.filter { $0.lastPathComponent == "cap-a5.png" }.count == 1,
                "hanging a file again moves it to the front, once")
        e.hang([URL(fileURLWithPath: "/tmp/dup.png"), URL(fileURLWithPath: "/tmp/dup.png")])
        c.check(e.urls.filter { $0.lastPathComponent == "dup.png" }.count == 1, "a repeat within one batch hangs once")

        // While the line is out, cards leaving (pruned, re-hung) lift away instead of vanishing.
        let out = shownEngine(3)
        let goneURL = out.items[1].url, goneID = out.items[1].id
        out.fileExists = { $0 != goneURL }
        out.reveal()
        c.check(out.items.count == 2 && out.cards[goneID]?.leaving == true, "a file deleted while the line is out lifts away (no jump)")
        runUntil(out, 1.5) { $0.cards[goneID] == nil }
        c.check(out.cards[goneID] == nil && out.cards.count == 2, "… and is gone once it has faded")
        let firstID = out.items[0].id, firstURL = out.items[0].url
        out.hang([firstURL])
        c.check(out.cards[firstID]?.leaving == true && out.items.first?.url == firstURL && out.items.first?.id != firstID,
                "re-hanging a visible file: the old card lifts away, a new one drops in at the front")

        // Missing files are pruned when the line reveals.
        do {
            let dir = try scratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            let urls = (0..<3).map { dir.appendingPathComponent("f\($0).txt") }
            try urls.forEach { try Data("x".utf8).write(to: $0) }
            let p = ClotheslineEngine(geometry: sample)
            p.hang(urls)
            runUntil(p, 4) { $0.state == .shown && $0.isSettled }
            p.retract(); runUntil(p, 2) { $0.state == .hidden }
            try FileManager.default.removeItem(at: urls[1])
            c.check(p.items.count == 3, "a deleted file stays until the next reveal")
            p.pointerMoved(to: CGPoint(x: 868, y: 20)); simulate(p, 0.55)
            c.check(p.items.count == 2 && !p.urls.contains(urls[1]) && p.state == .revealing, "files that no longer exist are removed when the line reveals",
                    "\(p.items.count) left")
            let missing = dir.appendingPathComponent("never.txt")
            p.hang([missing])
            c.check(p.items.count == 2, "a file that doesn't exist isn't hung")
            p.clear()
            c.check(p.items.isEmpty, "Clear Line empties it")
            let cleared = runUntil(p, 2) { $0.state == .hidden }
            c.check(cleared != nil, "an emptied line retracts by itself", "\(cleared.map { f($0, 2) } ?? "never") s")
        } catch {
            c.check(false, "prune setup", error.localizedDescription)
        }
    }

    // MARK: Controller (clock, panel, click-through)

    static func controller(_ c: Checker) throws {
        let fixtures = ClotheslinePreview.fixturesRoot()?.appendingPathComponent("core")
        let urls = ["photo.png", "clip.mp4", "report.pdf"].compactMap { fixtures?.appendingPathComponent($0) }
        guard urls.count == 3, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            c.check(false, "fixtures found", fixtures?.path ?? "no Tests/fixtures"); return
        }
        var now = 100.0
        let engine = ClotheslineEngine(geometry: sample, time: now)
        let surface = ClotheslineOffscreenSurface(engine: engine)
        let clock = ClotheslineManualClock()
        let ctl = ClotheslineController(engine: engine, surface: surface, clock: clock, now: { now })
        ctl.usesTimers = false
        func frames(_ seconds: Double) { for _ in 0..<Int((seconds * 60).rounded()) { now += 1.0 / 60; ctl.tick(at: now) } }
        c.check(!clock.isRunning && !surface.isShown && surface.ignoresMouse, "before anything is hung: no clock, no window")
        ctl.pointerMoved(screen: sample.screenPoint(fromScene: CGPoint(x: 1300, y: 700)))
        ctl.hang(urls)
        c.check(clock.isRunning && surface.isShown, "hang() shows the panel and starts the display-synced clock")
        frames(1.6)
        c.check(engine.state == .shown, "shown after the drop", engine.state.rawValue)
        // Click-through: only cards take clicks.
        guard let pose = engine.items.first.flatMap({ engine.pose($0.id) }) else { c.check(false, "pose"); return }
        let card = ClotheslineEngine.toScene(pose, CGPoint(x: 0, y: 60))
        ctl.pointerMoved(screen: sample.screenPoint(fromScene: card))
        c.check(!surface.ignoresMouse, "over a card the panel takes the mouse")
        ctl.pointerMoved(screen: sample.screenPoint(fromScene: CGPoint(x: 1500, y: 49)))
        c.check(surface.ignoresMouse, "on the bare string clicks pass through")
        ctl.pointerMoved(screen: sample.screenPoint(fromScene: CGPoint(x: 600, y: 260)))
        c.check(surface.ignoresMouse, "below the cards clicks pass through")
        ctl.pointerMoved(screen: sample.screenPoint(fromScene: CGPoint(x: 100, y: 15)))
        c.check(surface.ignoresMouse, "the menu bar keeps working")
        frames(3.5)
        c.check(engine.state == .hidden, "retracted after the hold", engine.state.rawValue)
        c.check(!clock.isRunning && !surface.isShown && surface.ignoresMouse && ctl.scheduledDeadline == nil,
                "hidden: no display link running, panel ordered out, nothing scheduled",
                "clock \(clock.isRunning), shown \(surface.isShown), deadline \(String(describing: ctl.scheduledDeadline))")
        let starts = clock.starts
        ctl.pointerMoved(screen: sample.screenPoint(fromScene: CGPoint(x: 300, y: 600)))
        ctl.pointerMoved(screen: sample.screenPoint(fromScene: CGPoint(x: 1400, y: 500)))
        c.check(clock.starts == starts && !clock.isRunning, "pointer moving elsewhere while hidden doesn't start the clock")
        ctl.pointerMoved(screen: sample.screenPoint(fromScene: CGPoint(x: 300, y: 20)))
        ctl.pointerMoved(screen: sample.screenPoint(fromScene: CGPoint(x: 870, y: 20)))
        c.check(ctl.scheduledDeadline.map { abs($0 - now - ClotheslineGeometry.notchDwell) < 1e-6 } ?? false && !clock.isRunning,
                "pointer arriving at the notch along the menu bar: a single 0.5 s wake-up, no frames yet",
                "\(ctl.scheduledDeadline.map { f(($0 - now) * 1000, 1) } ?? "none") ms")
        frames(0.55)
        c.check(engine.state == .revealing || engine.state == .shown, "then the line drops", engine.state.rawValue)
        // Out and still while the pointer rests at the notch: no frames and nothing scheduled.
        frames(3.0)
        c.check(engine.state == .shown && engine.isSettled && !clock.isRunning && ctl.scheduledDeadline == nil,
                "shown and still (pointer at the notch): the display link stops, nothing is scheduled",
                "state \(engine.state.rawValue), clock \(clock.isRunning)")
        ctl.pointerMoved(screen: sample.screenPoint(fromScene: CGPoint(x: 1300, y: 700)))
        c.check(!clock.isRunning && ctl.scheduledDeadline.map { abs($0 - now - 0.6) < 1e-6 } ?? false,
                "pointer leaves: one timer for 0.6 s later, still no frames",
                "deadline in \(ctl.scheduledDeadline.map { f($0 - now, 3) } ?? "none") s")
        frames(0.65)
        c.check(engine.state == .retracting && clock.isRunning, "the timer starts the retract and the clock with it", engine.state.rawValue)
        c.check(surface.view.layer?.sublayers?.count == 6 && surface.view.cardLayerCount == 2 * 3,
                "layers: halo, the string's glow and core, cards (a shadow and a card per file), 2 tacks",
                "\(surface.view.layer?.sublayers?.count ?? 0) + \(surface.view.cardLayerCount)")
        c.check(surface.view.cardsLayer.masksToBounds && abs(surface.view.cardsLayer.frame.maxY - (300 - 40)) < 0.01,
                "cards are clipped at the menu bar's lower edge (they come out from under it; only the string goes into the notch)",
                "\(surface.view.cardsLayer.frame)")
    }

    // MARK: Reduce Motion

    static func reduceMotion(_ c: Checker) {
        let e = ClotheslineEngine(geometry: sample, reduceMotion: true)
        e.fileExists = { _ in true }
        e.hang((0..<3).map { URL(fileURLWithPath: "/tmp/rm\($0).png") })
        c.check(e.line.value == 1, "Reduce Motion: the line doesn't travel (it is in place at once)")
        let inT = runUntil(e, 1) { $0.fade >= 1 }
        c.check(inT.map { abs($0 - 0.2) <= 2 * h } ?? false, "… and fades in over 0.2 s", "\(inT.map { f($0, 3) } ?? "never") s")
        var maxSpin = 0.0, maxDrop = 0.0, maxOff = 0.0
        runUntil(e, 3) { eng in
            for card in eng.cards.values {
                maxSpin = max(maxSpin, abs(card.spin)); maxDrop = max(maxDrop, abs(card.drop.value))
                maxOff = max(maxOff, abs(card.angle - card.targetAngle))
            }
            return eng.state == .retracting
        }
        c.check(maxSpin == 0 && maxDrop == 0 && maxOff < 1e-9, "no swinging and no drop; cards just follow the string",
                "spin \(maxSpin), drop \(maxDrop)")
        let outT = runUntil(e, 1) { $0.state == .hidden }
        c.check(outT.map { abs($0 - 0.2) <= 3 * h } ?? false && e.line.value == 0, "… and fades out over 0.2 s",
                "\(outT.map { f($0, 3) } ?? "never") s")
        let scaleOK = e.poses.allSatisfy { $0.scale == 1 }
        c.check(scaleOK, "no scaling in Reduce Motion")
    }

    // MARK: View (drag, menu, accessibility, scroll events)

    static func viewChecks(_ c: Checker) throws {
        let fixtures = ClotheslinePreview.fixturesRoot()?.appendingPathComponent("core")
        let urls = ["photo.png", "clip.mp4", "report.pdf"].compactMap { fixtures?.appendingPathComponent($0) }
        ShelfThumbnails.preload(urls, size: ClotheslineView.thumbnailRequest)
        ClotheslineArt.preloadDurations(urls)
        let engine = ClotheslineEngine(geometry: sample)
        let view = ClotheslineView(engine: engine, frame: CGRect(origin: .zero, size: sample.panelFrame.size))
        engine.onItemsChange = { view.itemsChanged() }
        engine.hang(urls)
        runUntil(engine, 3) { $0.state == .shown && $0.pendingArrivals.isEmpty }
        view.render()
        let widths = engine.items.map { engine.cards[$0.id]?.width ?? 0 }
        c.check(abs(widths[0] - (84 * 1.6 + 12)) < 1 && abs(widths[1] - min(84 * 16 / 9 + 12, 170)) < 1 && widths[2] == ClotheslineCardMetrics.minMatWidth,
                "card width follows the thumbnail (16:10 photo, 16:9 video), 112…170 pt (a portrait PDF gets the 112 pt minimum)",
                widths.map { f(Double($0), 0) }.joined(separator: ", "))

        guard let id = engine.items.first?.id, let video = engine.items.dropFirst().first?.id else { c.check(false, "items"); return }
        // Drag: the pasteboard carries the file URL.
        guard let drag = view.draggingItem(for: id) else { c.check(false, "dragging item"); return }
        let pb = NSPasteboard(name: NSPasteboard.Name("DropWheel.clothesline.selftest.\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects([drag.item as! NSPasteboardWriting])
        let read = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        c.check(read?.first?.standardizedFileURL == urls[0].standardizedFileURL, "drag pasteboard has the file URL",
                read?.first?.lastPathComponent ?? "nothing")
        c.check(drag.draggingFrame.width > 50 && drag.imageComponents?.isEmpty == false, "the drag image is the card",
                "\(drag.draggingFrame.size)")
        // Copy.
        view.copy(id, to: pb)
        let copied = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        c.check(copied?.first?.lastPathComponent == "photo.png", "Copy puts the file on the pasteboard")
        pb.releaseGlobally()

        // Context menu.
        let menu = view.menu(for: id)
        let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        c.check(titles == ["Open", "Show in Finder", "Copy", "—", "Remove from Line", "Clear Line"], "context menu items",
                titles.joined(separator: " | "))
        c.check(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.target === view && $0.action != nil },
                "every menu item is wired to the view")

        // Accessibility.
        c.check(view.accessibilityRole() == .group && view.accessibilityLabel() == "Clothesline, 3 files",
                "VoiceOver: the line is a group “Clothesline, 3 files”", view.accessibilityLabel() ?? "")
        let elements = view.accessibilityCardElements
        let labels = elements.map { $0.accessibilityLabel() ?? "" }
        c.check(elements.count == 3 && labels[0] == "photo.png" && labels[1].hasPrefix("clip.mp4, video, 0:0") && labels[2] == "report.pdf",
                "each card is an element named after its file (videos say their length)", labels.joined(separator: " | "))
        let actions = elements[0].accessibilityCustomActions()?.map(\.name) ?? []
        c.check(elements.allSatisfy { $0.accessibilityRole() == .button }
                && actions == ["Show in Finder", "Copy", "Move Left", "Move Right", "Remove from Line"],
                "cards press to open and offer the menu's actions, and Move Left / Move Right", actions.joined(separator: ", "))
        let frame = elements[0].accessibilityFrame()
        c.check(frame.width > 60 && frame.height > 100, "card elements have frames", "\(frame)")
        _ = video

        // Hit testing through the rotated, scaled card.
        if let pose = engine.pose(id) {
            let inside = ClotheslineEngine.toScene(pose, CGPoint(x: 0, y: 100))
            let pin = ClotheslineEngine.toScene(pose, CGPoint(x: 0, y: -6))
            let beside = ClotheslineEngine.toScene(pose, CGPoint(x: Double(pose.width) / 2 + 6, y: 60))
            c.check(engine.cardID(at: inside) == id && engine.cardID(at: pin) == id && engine.cardID(at: beside) != id,
                    "hit test follows the card's rotation (mat and pin, not beside it)")
        }

        // Scroll events.
        let wheel = ClotheslineView.scrollInput(dx: 0, dy: -3, precise: false, phase: [], momentum: [], time: 1)
        let swipe = ClotheslineView.scrollInput(dx: 12, dy: 1, precise: true, phase: .changed, momentum: [], time: 1)
        let began = ClotheslineView.scrollInput(dx: 0, dy: 0, precise: true, phase: .began, momentum: [], time: 1)
        let momentum = ClotheslineView.scrollInput(dx: 30, dy: 0, precise: true, phase: [], momentum: .changed, time: 1)
        c.check(wheel == .init(phase: .wheel, delta: 30, time: 1) && swipe == .init(phase: .changed, delta: -12, time: 1)
                && began?.phase == .began && momentum?.phase == .momentum,
                "scroll events: wheel steps ×10, fingers right move the cards right, the system's momentum is ignored")

        // Removing a card: its neighbours close the gap; the layer goes once it has lifted away.
        let before = engine.cards[video]?.slot.target ?? 0
        view.removeCard(id)
        c.check(engine.items.count == 2 && (engine.cards[video]?.slot.target ?? 0) < before, "Remove from Line closes the gap",
                "\(f(before, 0)) → \(f(engine.cards[video]?.slot.target ?? 0, 0))")
        runUntil(engine, 1.5) { $0.cards[id] == nil }
        view.render()
        c.check(engine.cards[id] == nil && view.cardLayerCount == 2 * 2, "the removed card's layers are gone",
                "\(view.cardLayerCount) card layers")

        // Light and dark pictures differ, and the string colour follows.
        let content = ClotheslineArt.CardContent(name: "photo.png", thumbnail: nil, isIcon: true, duration: nil)
        let light = ClotheslineArt.cardImage(content, width: 96, dark: false, scale: 2)
        let dark = ClotheslineArt.cardImage(content, width: 96, dark: true, scale: 2)
        c.check(light != nil && dark != nil && light!.width == Int((ClotheslineArt.imageRect(width: 96).width * 2).rounded(.up)),
                "card pictures render at 2x in light and dark", "\(light?.width ?? 0)×\(light?.height ?? 0) px")
        if let l = light, let d = dark, let lp = pixel(l, x: l.width / 2, y: l.height - 20), let dp = pixel(d, x: d.width / 2, y: d.height - 20) {
            c.check(lp.0 > 0.95 && dp.0 < 0.25, "light: white mat; dark: softened charcoal mat",
                    "light \(f(lp.0, 2)), dark \(f(dp.0, 2))")
        }
    }

    /// One pixel's (r, g, b) from a premultiplied BGRA image, y from the top.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (Double, Double, Double)? {
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }

    // MARK: Hook

    static func hook(_ c: Checker) {
        let files = Clothesline.selfCheckFiles(["DW_SELFCHECK_LINE": "/tmp/a.png| /tmp/b c.mov |~/x.pdf|"])
        c.check(files?.map(\.path) == ["/tmp/a.png", "/tmp/b c.mov", NSHomeDirectory() + "/x.pdf"],
                "DW_SELFCHECK_LINE parses “a|b|…” (spaces trimmed, ~ expanded, empties skipped)",
                files?.map(\.lastPathComponent).joined(separator: ", ") ?? "nil")
        c.check(Clothesline.selfCheckFiles([:]) == nil, "no DW_SELFCHECK_LINE: no hook")
        c.check(Registry.modules.contains { $0 == ClotheslineModule.self }, "the module is registered")
    }

    // MARK: Performance

    static func performance(_ c: Checker) {
        let e = shownEngine(16)
        e.retract(); runUntil(e, 2) { $0.state == .hidden }
        e.pointerMoved(to: CGPoint(x: 868, y: 20))
        let view = ClotheslineView(engine: e, frame: CGRect(origin: .zero, size: sample.panelFrame.size))
        view.itemsChanged()
        let started = CACurrentMediaTime()
        let frames = 120
        for _ in 0..<frames { for _ in 0..<4 { e.step(h) }; view.render() }
        let ms = (CACurrentMediaTime() - started) / Double(frames) * 1000
        c.check(ms < 4, "one frame (4 physics substeps + layer update) with 16 cards", "\(f(ms, 3)) ms")
    }
}
#endif
