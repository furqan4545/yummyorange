#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit

/// Regression checks for what the verification pass found (part of `--selftest clothesline`).
extension ClotheslineTests {
    static func verifierChecks(_ c: Checker) {
        do { try stillLineResponds(c) } catch { c.check(false, "still-line setup", error.localizedDescription) }
        heldOpenWakeUps(c)
        hangWhileRetracting(c)
        notchEdgePops(c)
    }

    /// Largest change of a visible card's vertical speed between 1/60 s frames (points per frame): a pop.
    static func visiblePop(_ e: ClotheslineEngine, seconds: Double, _ act: ((Int) -> Void)? = nil) -> Double {
        var history: [[UUID: ClotheslineCardPose]] = []
        var worst = 0.0
        for frame in 0..<Int((seconds * 60).rounded()) {
            act?(frame)
            simulate(e, 1.0 / 60)
            history.append(Dictionary(uniqueKeysWithValues: e.poses.map { ($0.id, $0) }))
            if history.count > 3 { history.removeFirst() }
            guard history.count == 3 else { continue }
            for (id, p2) in history[2] {
                guard let p1 = history[1][id], let p0 = history[0][id], min(p0.alpha, p1.alpha, p2.alpha) > 0.3,
                      min(p0.scale, p2.scale) > 0.3 else { continue }
                worst = max(worst, abs(Double(p2.pivot.y - 2 * p1.pivot.y + p0.pivot.y)))
            }
        }
        return worst
    }

    // MARK: Hover and press on a line that has come to rest (the idle shortcut must not swallow them)

    static func stillLineResponds(_ c: Checker) throws {
        let fixtures = ClotheslinePreview.fixturesRoot()?.appendingPathComponent("core")
        let urls = ["photo.png", "clip.mp4", "report.pdf"].compactMap { fixtures?.appendingPathComponent($0) }
        guard urls.count == 3 else { c.check(false, "fixtures"); return }
        ShelfThumbnails.preload(urls, size: ClotheslineView.thumbnailRequest)
        var now = 800.0
        let engine = ClotheslineEngine(geometry: sample, time: now)
        let surface = ClotheslineOffscreenSurface(engine: engine)
        let clock = ClotheslineManualClock()
        let ctl = ClotheslineController(engine: engine, surface: surface, clock: clock, now: { now })
        ctl.usesTimers = false
        /// Like the display link: frames only while the clock runs.
        func frames(_ seconds: Double) {
            let end = now + seconds
            while now < end - 1e-9 { now += 1.0 / 60; if clock.isRunning { ctl.tick(at: now) } }
        }
        ctl.pointerMoved(screen: sample.screenPoint(fromScene: CGPoint(x: 1300, y: 700)))
        ctl.hang(urls)
        frames(1.0)
        // The pointer comes to rest on the bare string (it keeps the line out) until nothing moves.
        let sx = 1000.0
        ctl.pointerMoved(screen: sample.screenPoint(fromScene: CGPoint(x: sx, y: engine.stringY(at: sx, ends: engine.lineEnds()) + 2)))
        frames(4)
        guard let id = engine.items.first?.id, let pose = engine.pose(id) else { c.check(false, "pose"); return }
        let still = engine.state == .shown && engine.isSettled && !clock.isRunning
        ctl.pointerMoved(screen: sample.screenPoint(fromScene: ClotheslineEngine.toScene(pose, CGPoint(x: 0, y: 60))))
        let started = clock.isRunning
        frames(0.4)
        let lift = engine.cards[id]?.lift.value ?? 0
        c.check(still && started && lift > 0.95,
                "a still line: the card under the pointer lifts at once (the clock starts)",
                "still \(still), clock \(started), lift \(String(format: "%.2f", lift))")
        frames(1)
        let before = "\(engine.state.rawValue), still \(engine.isSettled), clock \(clock.isRunning)"
        engine.setPressed(id)
        ctl.clotheslineNeedsUpdate()
        let pressStarted = clock.isRunning
        frames(0.25)
        let scale = engine.pose(id)?.scale ?? 1
        c.check(pressStarted && scale < 1.01, "… and answers a press on the still line (shrinks before release)",
                "clock \(pressStarted), scale \(String(format: "%.3f", scale)) (1.035 lifted; before the press: \(before))")
        engine.setPressed(nil)
        ctl.clotheslineNeedsUpdate()
        frames(0.5)
        c.check(!clock.isRunning && engine.isSettled, "… then the clock stops again", "clock \(clock.isRunning)")
        ctl.shutDown()
    }

    // MARK: A line held open never schedules a wake-up in the past (it would fire every millisecond)

    static func heldOpenWakeUps(_ c: Checker) {
        let e = fakeEngine(3)
        e.holdOpen = true
        simulate(e, 5)
        let deadline = e.nextDeadline
        c.check(e.state == .shown && (deadline == nil || deadline! > e.time),
                "held open past its hold: no wake-up timer due in the past", deadline.map { String(format: "%.3f s from now", $0 - e.time) } ?? "none")
    }

    // MARK: hang() while a scrolled line is going away: the cards glide back to the newest, they never jump

    static func hangWhileRetracting(_ c: Checker) {
        func scrolledRetracting(reduceMotion: Bool) -> ClotheslineEngine {
            let e = fakeEngine(16)
            e.reduceMotion = reduceMotion
            simulate(e, 1.0)
            e.scroll(ClotheslineScrollInput(phase: .wheel, delta: 300, time: e.time))
            runUntil(e, 5) { $0.state == .retracting }
            return e
        }
        /// Largest move of a card on screen in one 1/240 s substep, hanging one more file `k` substeps in (-1: never).
        /// With `revealOnly`, the line is just brought back out at that moment instead (no new file, no scroll change).
        func largestMove(hangAt k: Int, revealOnly: Bool = false) -> Double {
            let e = scrolledRetracting(reduceMotion: false)
            var last: [UUID: CGPoint] = [:]
            var worst = 0.0
            for i in 0..<Int(1.5 / h) {
                if i == k {
                    if revealOnly { e.reveal() } else { e.hang([URL(fileURLWithPath: "/tmp/cl-verify-new.png")]) }
                }
                e.step(h)
                for p in e.poses where p.alpha > 0.05 && p.scale > 0.2 && p.pivot.x >= 0 && p.pivot.x <= sample.width {
                    if let q = last[p.id] { worst = max(worst, hypot(Double(p.pivot.x - q.x), Double(p.pivot.y - q.y))) }
                }
                last = Dictionary(uniqueKeysWithValues: e.poses.map { ($0.id, $0.pivot) })
            }
            return worst
        }
        // The fastest a card moves anyway: the line gathering into the notch, or the same line turned round and run
        // back out at that moment. hang() mid-retract may move cards as fast as either, never faster.
        let gathering = largestMove(hangAt: -1)
        var worst = 0.0, worstAt = 0, turning = 0.0
        for k in stride(from: 1, to: 150, by: 6) {
            let m = largestMove(hangAt: k)
            if m > worst { worst = m; worstAt = k }
            turning = max(turning, largestMove(hangAt: k, revealOnly: true))
        }
        let baseline = max(gathering, turning)
        // A jump back to the start of the line was ~130 pt in one substep.
        c.check(worst < baseline + 4, "hang() while a scrolled line goes away: no card jumps (largest move on screen per 1/240 s)",
                String(format: "%.1f pt (hang %.3f s into the retract); %.1f pt while it just gathers, %.1f pt when it just turns round",
                       worst, Double(worstAt) * h, gathering, turning))
        // Reduce Motion: cards visible while the line is going away move only while faded out.
        let r = scrolledRetracting(reduceMotion: true)
        simulate(r, 0.05)
        var visibleMoves = 0
        let offsetBefore = r.scroller.offset
        var last: [UUID: (CGPoint, Double)] = Dictionary(uniqueKeysWithValues: r.poses.map { ($0.id, ($0.pivot, $0.alpha)) })
        r.hang([URL(fileURLWithPath: "/tmp/cl-verify-new.png")])
        for _ in 0..<Int(0.6 / h) {
            r.step(h)
            for p in r.poses {
                if let (q, a) = last[p.id], hypot(Double(p.pivot.x - q.x), Double(p.pivot.y - q.y)) > 0.5, min(a, p.alpha) > 0.02 { visibleMoves += 1 }
            }
            last = Dictionary(uniqueKeysWithValues: r.poses.map { ($0.id, ($0.pivot, $0.alpha)) })
        }
        c.check(offsetBefore > 100 && visibleMoves == 0 && r.scroller.offset == 0, "… with Reduce Motion they go back to the newest while faded out",
                "\(visibleMoves) visible moves, offset \(Int(offsetBefore)) → \(r.scroller.offset)")
    }

    // MARK: Cards passing under the notch edge, or the string falling out of the notch, don't pop

    static func notchEdgePops(_ c: Checker) {
        let widths: [CGFloat] = [146, 162, 112, 112, 130, 112, 150, 112, 140, 112, 112, 170, 112, 120, 112, 112]
        var retract = 0.0, reversal = 0.0, ordinary = 0.0
        for n in [5, 8, 12, 16] {
            for shift in 0..<6 {
                func make() -> ClotheslineEngine {
                    let e = fakeEngine(n, widths: Array(widths[shift...] + widths[..<shift]), pointer: CGPoint(x: 1300, y: 600), prefix: "cl-pop")
                    simulate(e, 0.5)
                    runUntil(e, 5) { $0.state == .retracting }
                    return e
                }
                retract = max(retract, visiblePop(make(), seconds: 1))
                // The same line dropping out of the notch from hidden: the fastest change an ordinary reveal makes.
                do {
                    let e = make()
                    runUntil(e, 3) { $0.state == .hidden }
                    ordinary = max(ordinary, visiblePop(e, seconds: 1.4) { f in if f == 0 { e.reveal() } })
                }
                // Turned round at points through the retract: where an 80 ms rest in the notch used to (5 frames after
                // frame k). A notch rest now takes 0.5 s, most of a retract, so Show Clothesline turns it round there.
                for k in stride(from: 4, to: 40, by: 5) {
                    let e = make()
                    reversal = max(reversal, visiblePop(e, seconds: 1.4) { f in if f == k + 5 { e.reveal() } })
                }
            }
        }
        // Before: 11.1 pt (retract) and 18.4 pt (reversal), a card snapping into or out of the notch in one frame. A line
        // turned round mid-retract may change pace as fast as an ordinary drop does (a deeper sag falls further), no faster.
        c.check(retract < 6 && reversal < max(9, ordinary + 2),
                "cards passing the notch's edge rise into it and drop out of it smoothly (largest change per frame)",
                String(format: "retract %.1f pt, reversal %.1f pt (an ordinary drop: %.1f pt)", retract, reversal, ordinary))
    }
}
#endif
