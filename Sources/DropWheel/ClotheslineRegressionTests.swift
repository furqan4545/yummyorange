#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit

/// Regression checks for the review findings (part of `--selftest clothesline`). Each one reproduces what a reviewer
/// measured and fails on the old behaviour.
extension ClotheslineTests {
    static func regressions(_ c: Checker) {
        stringMotion(c)
        stillPointer(c)
        restingPointer(c)
        newestSwing(c)
        pinOnString(c)
        rideUp(c)
        captions(c)
        pictureWait(c)
        tiltLimit(c)
        tacks(c)
        menuBar(c)
        reduceMotionFades(c)
        notchRest(c)
        scrollGesture(c)
        capacityBatch(c)
        idleCost(c)
        hoverFollows(c)
        voiceOver(c)
        smallFixes(c)
        do { try teardown(c) } catch { c.check(false, "teardown setup", error.localizedDescription) }
        do { try renamedFiles(c) } catch { c.check(false, "rename setup", error.localizedDescription) }
        do { try otherAppDrag(c) } catch { c.check(false, "other-app drag setup", error.localizedDescription) }
        menuReveal(c)
    }

    /// Fake files with picture widths like the fixtures' (photo, video, portrait), hung from hidden.
    static func fakeEngine(_ n: Int, widths: [CGFloat] = [146, 162, 112], pointer: CGPoint? = nil,
                           geometry: ClotheslineGeometry = sample, prefix: String = "cl-fix") -> ClotheslineEngine {
        let e = ClotheslineEngine(geometry: geometry)
        e.fileExists = { _ in true }
        let urls = (0..<n).map { URL(fileURLWithPath: "/tmp/\(prefix)-\($0).png") }
        e.widthFor = { url in widths[(urls.firstIndex(of: url) ?? 0) % widths.count] }
        if let pointer { e.pointerMoved(to: pointer) }
        e.hang(urls)
        return e
    }

    // MARK: The string pulls up into the notch and falls back down (motion finding 1)

    static func stringMotion(_ c: Checker) {
        let g = sample
        let e = shownEngine(3)
        e.holdOpen = false
        let rest = e.middleY
        let ceiling = Double(g.ceilingY)
        e.retract()
        let t0 = e.time
        var firstMove: Double?, mostlyUp: Double?, spreadWhenUp = 0.0
        runUntil(e, 2) { eng in
            let y = eng.middleY
            if firstMove == nil && y < rest - 0.5 { firstMove = eng.time - t0 }
            if mostlyUp == nil && y <= rest - 0.8 * (rest - ceiling) { mostlyUp = eng.time - t0; spreadWhenUp = eng.line.value }
            return eng.state == .hidden
        }
        let pull = (mostlyUp ?? 0) - (firstMove ?? 0)
        c.check(rest - ceiling >= 15, "going away, the middle of the string rises at least 15 pt to the menu bar",
                "y \(f(rest, 1)) → \(f(ceiling, 1)), \(f(rest - ceiling, 1)) pt")
        c.check(pull >= 0.1, "the pull-up can be seen: 80 % of the rise takes at least 100 ms (6 frames at 60 Hz)",
                "\(f(pull * 1000, 0)) ms")
        c.check(spreadWhenUp > 0.97, "the ends are reeled in only once the string is pulled up", "spread \(f(spreadWhenUp, 3)) then")
        c.check(e.state == .hidden, "… and then it is gone into the notch", e.state.rawValue)

        // Coming out: the ends run out along the menu bar, then the string falls into its sag with a small bounce.
        e.reveal()
        let t1 = e.time
        var fallStart: Double?, fallEnd: Double?, spreadAtFall = 0.0, lowest = 0.0
        runUntil(e, 2.5) { eng in
            guard eng.line.value >= 0.1 else { return false }
            let y = eng.middleY
            lowest = max(lowest, y)
            if fallStart == nil && y > ceiling + 2.5 { fallStart = eng.time - t1; spreadAtFall = eng.line.value }
            if fallStart != nil && fallEnd == nil && y >= rest - 1 { fallEnd = eng.time - t1 }
            return eng.state == .shown
        }
        let fallTime = (fallEnd ?? 0) - (fallStart ?? 0)
        c.check(spreadAtFall >= 0.5, "coming out, the ends run out first and then the string falls",
                "spread \(f(spreadAtFall, 2)) when the fall starts")
        c.check(fallTime >= 0.12, "the fall can be seen: from the menu bar to the sag takes at least 120 ms",
                "\(f(fallTime * 1000, 0)) ms")
        c.check(lowest - rest > 0.4 && lowest - rest < 5, "the string falls with a small bounce", "\(f(lowest - rest, 2)) pt past its rest")
        // Never a jump: reversing in either phase keeps the string's middle continuous. The line turns round where an
        // 80 ms rest in the notch used to turn it (80 ms after `cut`); a notch rest now takes 0.5 s and can only start
        // once the retract has, so Show Clothesline turns it round there.
        for cut in [0.06, 0.3] {
            let q = shownEngine(3)
            q.holdOpen = false
            q.retract()
            simulate(q, cut)
            let start = q.time
            var prev = q.middleY, worst = 0.0, turned = false
            for _ in 0..<Int(1.0 / h) {
                if !turned && q.time - start >= 0.08 - 1e-9 { turned = q.state == .retracting; q.reveal() }
                q.step(h)
                worst = max(worst, abs(q.middleY - prev))
                prev = q.middleY
            }
            c.check(turned && worst < 2.5 && q.state != .hidden,
                    "reversing \(Int((cut + 0.08) * 1000)) ms into a retract: the string's middle moves on smoothly",
                    "largest move per 1/240 s \(f(worst, 2)) pt")
        }
    }

    // MARK: A still pointer never makes the line loop (motion 2, systems 1)

    static func stillPointer(_ c: Checker) {
        for (n, spot) in [(3, CGPoint(x: 600, y: 120)), (3, CGPoint(x: 600, y: 50)), (8, CGPoint(x: -1, y: 160)), (16, CGPoint(x: -1, y: 150))] {
            let e = fakeEngine(n)
            var p = spot
            if spot.x < 0 {
                // A gap between two cards left of the notch (off the line at rest; cards sweep over it as they gather).
                e.holdOpen = true
                runUntil(e, 5) { $0.state == .shown && $0.isSettled }
                let xs = stride(from: 300.0, through: 840, by: 1).filter { x in
                    let q = CGPoint(x: x, y: spot.y)
                    return !e.isInBand(q) && e.cardID(at: CGPoint(x: x - 30, y: spot.y)) != nil
                }
                p = CGPoint(x: xs.first ?? 700, y: spot.y)
                e.holdOpen = false
            } else {
                e.step(h)
            }
            e.pointerMoved(to: p)   // and it rests there
            var reveals = 0
            e.onStateChange = { if $0 == .revealing { reveals += 1 } }
            simulate(e, 14)
            c.check(reveals == 0 && e.state == .hidden, "a still pointer at (\(Int(p.x)), \(Int(p.y))) with \(n) cards: the line retracts once and stays in",
                    "\(reveals) more reveals in 14 s, \(e.state.rawValue)")
        }
        // A pointer that moves onto a card during the retract still catches it.
        let m = fakeEngine(3)
        runUntil(m, 4) { $0.state == .retracting }
        simulate(m, 0.03)
        if let pose = m.items.first.flatMap({ m.pose($0.id) }) {
            m.pointerMoved(to: ClotheslineEngine.toScene(pose, CGPoint(x: 0, y: 60)))
        }
        c.check(m.state == .revealing, "a pointer that moves onto a card while the line goes away catches it", m.state.rawValue)
    }

    // MARK: A pointer resting under the menu bar when files are hung doesn't hold the line (motion 3)

    static func restingPointer(_ c: Checker) {
        for p in [CGPoint(x: 1500, y: 62), CGPoint(x: 600, y: 120), CGPoint(x: 100, y: 110)] {
            let e = ClotheslineEngine(geometry: sample)
            e.fileExists = { _ in true }
            e.pointerMoved(to: p)
            e.hang((0..<3).map { URL(fileURLWithPath: "/tmp/cl-rest-\($0).png") })
            var hovered = false, at: Double?
            runUntil(e, 8) { eng in
                if eng.hoveredCard != nil { hovered = true }
                if eng.state == .retracting { at = eng.time; return true }
                return false
            }
            let hold = (at ?? 0) - (e.lastArrival ?? 0)
            c.check(at != nil && abs(hold - 2) <= 2 * h && !hovered,
                    "pointer resting at (\(Int(p.x)), \(Int(p.y))) before the files came: the line still goes after 2 s",
                    at == nil ? "never" : "\(f(hold, 3)) s after the last card, hovered \(hovered)")
        }
        // Once it moves onto the line, it holds it.
        let e = fakeEngine(3)
        runUntil(e, 1.5) { $0.pendingArrivals.isEmpty }
        e.pointerMoved(to: CGPoint(x: 1500, y: 62))
        e.pointerMoved(to: CGPoint(x: 1501, y: 63))
        simulate(e, 5)
        c.check(e.state == .shown, "a pointer that moves along the string keeps the line out", e.state.rawValue)
        // The band is the string (±12 pt), the cards and the notch zone, not a full-width strip under the menu bar.
        var shares: [String] = [], ok = true
        for (n, before) in [(3, 25.5), (16, 57.8)] {
            let b = fakeEngine(n, prefix: "cl-band")
            runUntil(b, 4) { $0.state == .shown && $0.isSettled }
            var inside = 0, total = 0
            for y in stride(from: 41.0, through: 300, by: 4) {
                for x in stride(from: 2.0, through: 1734, by: 8) { total += 1; if b.isInBand(CGPoint(x: x, y: y)) { inside += 1 } }
            }
            let share = 100 * Double(inside) / Double(total)
            if share >= before { ok = false }
            shares.append("\(n) cards \(f(share, 1)) % (was \(f(before, 1)) %)")
        }
        c.check(ok, "the area under the menu bar that holds the line out is smaller than before", shares.joined(separator: ", "))
    }

    // MARK: The newest card swings like the others (motion 4) and at a cloth-like tempo (motion 5)

    /// Peaks of a card's swing after it lands: (time after landing, degrees off rest).
    static func peaks(_ e: ClotheslineEngine, _ id: UUID, seconds: Double) -> [(Double, Double)] {
        var landed: Double?, lastSpin = 0.0, out: [(Double, Double)] = []
        runUntil(e, seconds) { eng in
            guard let card = eng.cards[id] else { return true }
            if landed == nil && card.arrived { landed = eng.time; lastSpin = card.spin; return false }
            guard let l = landed else { return false }
            if (card.spin > 0) != (lastSpin > 0) && lastSpin != 0 {
                out.append((eng.time - l, ClotheslineMath.degrees(card.angle - card.targetAngle)))
            }
            lastSpin = card.spin
            return false
        }
        return out
    }

    static func newestSwing(_ c: Checker) {
        let e = fakeEngine(3)
        let id = e.items[0].id
        let p = peaks(e, id, seconds: 4)
        let visible = p.filter { abs($0.1) >= 1 }.count
        c.check((p.first.map { abs($0.1) } ?? 0) >= 5 && visible >= 2,
                "the newest card swings when the pin catches the line (first swing ≥ 5°, 2–3 swings ≥ 1°)",
                p.prefix(5).map { "\(f($0.1, 1))°" }.joined(separator: " → "))
        let later = shownEngine(2)
        later.hang([URL(fileURLWithPath: "/tmp/cl-fix-late.png")])
        let q = peaks(later, later.items[0].id, seconds: 4)
        c.check((q.first.map { abs($0.1) } ?? 0) >= 5, "… whatever was hung before it (a card added to a line that is out)",
                q.prefix(4).map { "\(f($0.1, 1))°" }.joined(separator: " → "))
        // Tempo: the time between swings to the same side.
        let s = shownEngine(3)
        guard let card0 = s.items.first.flatMap({ s.cards[$0.id] }) else { return }
        var kicked = card0
        kicked.angle = card0.targetAngle + ClotheslineMath.radians(10)
        s.setCardForTesting(kicked)
        var times: [Double] = [], last = 0.0
        runUntil(s, 3) { eng in
            guard let k = eng.cards[card0.id] else { return true }
            if last != 0 && (k.spin > 0) != (last > 0) { times.append(eng.time) }   // a peak (either side)
            last = k.spin
            return false
        }
        let period = times.count >= 3 ? 2 * (times[2] - times[1]) : 0
        c.check(period >= 0.8 && period <= 1.0, "a card swings with a period of 0.8–1.0 s (not twitchy)", "\(f(period, 3)) s")
    }

    // MARK: The pin stays on the string; the string dips under it (motion 6)

    static func pinOnString(_ c: Checker) {
        let e = fakeEngine(3)
        let id = e.items[0].id
        var overshoot = 0.0, dip = 0.0, landed = false
        runUntil(e, 1.5) { eng in
            guard let card = eng.cards[id] else { return true }
            if card.arrived { landed = true }
            if landed { overshoot = max(overshoot, card.drop.value); dip = max(dip, card.dip.value) }
            return false
        }
        c.check(overshoot <= 2.5, "landing, the pin overshoots the string by at most 2.5 pt (its jaws stay on it)", "\(f(overshoot, 2)) pt")
        c.check(dip >= 2.5 && dip <= 8, "the string dips under the landing pin instead", "\(f(dip, 2)) pt")
    }

    // MARK: Cards ride up with the string and gather without piling up (motion 7)

    static func rideUp(_ c: Checker) {
        let e = fakeEngine(6)
        runUntil(e, 4) { $0.state == .shown && $0.isSettled }
        e.holdOpen = true
        let near = e.items.min { abs((e.cards[$0.id]?.pivotX ?? 0) - 868) < abs((e.cards[$1.id]?.pivotX ?? 0) - 868) }!.id
        let restY = e.cards[near]?.pivotY ?? 0
        e.retract()
        var minAlphaWhileUp = 1.0, topY = restY, ratio = 0.0
        runUntil(e, 2) { eng in
            if eng.line.value > 0.98 {
                topY = min(topY, eng.cards[near]?.pivotY ?? topY)
                minAlphaWhileUp = min(minAlphaWhileUp, eng.poses.map(\.alpha).min() ?? 1)
            }
            if ratio == 0 && eng.line.value <= 0.1 {
                let ps = eng.items.compactMap { eng.pose($0.id) }
                for (a, b) in zip(ps, ps.dropFirst()) {
                    let overlap = (Double(a.width) * a.scale + Double(b.width) * b.scale) / 2 / max(0.01, abs(Double(b.pivot.x - a.pivot.x)))
                    ratio = max(ratio, overlap)
                }
            }
            return eng.state == .hidden
        }
        c.check(restY - topY >= 8 && minAlphaWhileUp > 0.95, "cards ride up with the string as it is pulled (and stay opaque)",
                "the card nearest the notch rises \(f(restY - topY, 1)) pt, lowest opacity \(f(minAlphaWhileUp, 2))")
        c.check(ratio > 0 && ratio <= 1.3, "gathering into the notch, neighbouring cards don't pile up (width / spacing ≤ 1.3 at spread 0.1)",
                f(ratio, 2))
    }

    // MARK: Narrow cards keep readable names (motion 8)

    static func captions(_ c: Checker) {
        let portrait = ClotheslineCardMetrics.matWidth(aspect: 0.75)
        let caption = portrait - 2 * ClotheslineCardMetrics.inset - 2
        let name = NSAttributedString(string: "Portrait shot.png", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)])
        c.check(portrait >= 112 && name.size().width <= caption, "a portrait card is wide enough for “Portrait shot.png” in full",
                "mat \(f(Double(portrait), 0)) pt, caption \(f(Double(caption), 0)) pt, name \(f(Double(name.size().width), 1)) pt")
    }

    // MARK: A card waits for its picture before it drops (motion 9)

    static func pictureWait(_ c: Checker) {
        let e = ClotheslineEngine(geometry: sample)
        e.fileExists = { _ in true }
        var ready: Set<String> = ["cl-pic-b.png", "cl-pic-c.png"]
        e.pictureReady = { ready.contains($0.lastPathComponent) }
        e.hang(["a.png", "b.png", "c.png"].map { URL(fileURLWithPath: "/tmp/cl-pic-\($0)") })
        _ = ready
        ready = []
        let ids = e.items.map(\.id)
        let t0 = e.time
        simulate(e, 0.3)
        c.check(ids.allSatisfy { e.cards[$0]?.startedAt == nil }, "a card waits for its thumbnail (and the cards after it keep their order)")
        e.pictureArrived(for: ids[0])
        simulate(e, 0.2)
        let a = (e.cards[ids[0]]?.startedAt ?? 0) - t0, b = (e.cards[ids[1]]?.startedAt ?? 0) - t0
        c.check(abs(a - 0.3) <= 2 * h && abs(b - a - ClotheslineEngine.cascade) <= 2 * h,
                "it drops as soon as the picture is there, the next one 40 ms later", "\(f(a, 3)) s, \(f(b, 3)) s")
        let late = ClotheslineEngine(geometry: sample)
        late.fileExists = { _ in true }
        late.pictureReady = { _ in false }
        late.hang([URL(fileURLWithPath: "/tmp/cl-pic-never.png")])
        let lt0 = late.time
        simulate(late, 0.6)
        let started = (late.items.first.flatMap { late.cards[$0.id]?.startedAt } ?? 0) - lt0
        c.check(abs(started - ClotheslineEngine.pictureWait) <= 2 * h, "with no picture it waits at most 0.35 s, then drops with a placeholder",
                "\(f(started, 3)) s")
        // The view: a picture that comes after the drop cross-fades in, and the card widens on a spring.
        do {
            let dir = try scratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("late picture.png")
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            try rep?.representation(using: .png, properties: [:])?.write(to: url)
            let engine = ClotheslineEngine(geometry: sample)
            let view = ClotheslineView(engine: engine, frame: CGRect(origin: .zero, size: sample.panelFrame.size))
            engine.onItemsChange = { view.itemsChanged() }
            let waits = !view.hasPicture(url)
            engine.hang([url])
            runUntil(engine, 1.5) { $0.state == .shown && $0.pendingArrivals.isEmpty }
            guard let id = engine.items.first?.id else { c.check(false, "late picture card"); return }
            let before = engine.cards[id]?.width ?? 0
            view.thumbnailArrived(ShelfThumbnail(image: NSImage(size: NSSize(width: 320, height: 200)), isIcon: false), url: url)
            let slotMoving = !(engine.cards[id]?.slot.isSettled(position: 0.1, speed: 1) ?? true)
            c.check(waits && view.crossFades == 1 && (engine.cards[id]?.width ?? 0) > before && slotMoving,
                    "a picture that arrives after the drop cross-fades in and the card widens smoothly",
                    "\(f(Double(before), 0)) → \(f(Double(engine.cards[id]?.width ?? 0), 0)) pt, cross-fades \(view.crossFades)")
        } catch {
            c.check(false, "late picture setup", error.localizedDescription)
        }
    }

    // MARK: Shown tilts stay in bounds; cards swing at their own tempos (motion 10)

    static func tiltLimit(_ c: Checker) {
        let limited = ClotheslineMath.degrees(ClotheslineEngine.softLimit(ClotheslineMath.radians(18)))
        let small = ClotheslineMath.degrees(ClotheslineEngine.softLimit(ClotheslineMath.radians(9)))
        c.check(limited <= 15 && abs(small - 9) < 1e-9, "shown angles: unchanged up to 11°, softly limited below 15°",
                "18° shows as \(f(limited, 2))°")
        let e = fakeEngine(12)
        runUntil(e, 4) { $0.state == .shown && $0.isSettled }
        e.holdOpen = true
        var maxShown = 0.0, maxRaw = 0.0
        func flick(_ peak: Double) {
            e.scroll(.init(phase: .began, delta: 0, time: e.time))
            for i in 1...9 {
                for _ in 0..<4 { e.step(h) }
                e.scroll(.init(phase: .changed, delta: peak * (0.35 + 0.65 * Double(i) / 9), time: e.time))
            }
            e.scroll(.init(phase: .ended, delta: 0, time: e.time))
            runUntil(e, 3.5) { eng in
                for p in eng.poses { maxShown = max(maxShown, abs(ClotheslineMath.degrees(p.angle))) }
                for k in eng.cards.values { maxRaw = max(maxRaw, abs(ClotheslineMath.degrees(k.angle))) }
                return false
            }
        }
        flick(34)
        flick(-46)
        c.check(maxShown <= 15, "flicks like the preview's: no card shows more than 15°", "shown \(f(maxShown, 1))°, physics \(f(maxRaw, 1))°")
        let factors = Set(e.items.compactMap { e.cards[$0.id] }.map { ($0.jitter * ClotheslineEngine.swingFactor(width: $0.width) * 1000).rounded() })
        c.check(factors.count >= 6, "cards swing at slightly different tempos (by size and name), not as one comb", "\(factors.count) tempos for 12 cards")
    }

    // MARK: Cards never hang beyond the string's tacks (motion 11)

    static func tacks(_ c: Checker) {
        let e = fakeEngine(16)
        runUntil(e, 4) { $0.state == .shown && $0.isSettled }
        e.holdOpen = true
        var bad = 0, checked = 0, note = ""
        for fraction in [0.0, 0.5, 1.0] {
            e.scroller.scroll(to: e.scroller.maxOffset * fraction, animated: false)
            e.step(h)
            runUntil(e, 3) { $0.isSettled }
            let ends = e.lineEnds()
            for p in e.poses where p.alpha > 0.5 && p.pivot.x >= 0 && p.pivot.x <= sample.width {
                checked += 1
                if p.pivot.x < ends.left.x - 0.5 || p.pivot.x > ends.right.x + 0.5 { bad += 1; note = "pin \(f(Double(p.pivot.x), 0)) vs \(f(Double(ends.left.x), 0))…\(f(Double(ends.right.x), 0))" }
            }
            if fraction == 0 {
                c.check(abs(ends.left.x - sample.leftEndX) < 1 && ends.right.x > sample.width,
                        "with cards hidden to the right, the string runs off that edge (its tack too); the left tack stays",
                        "\(f(Double(ends.left.x), 0)) … \(f(Double(ends.right.x), 0))")
            }
        }
        c.check(bad == 0 && checked > 20, "no visible pin hangs beyond the string's ends (start, middle, end of the scroll)",
                bad == 0 ? "\(checked) pins checked" : note)
    }

    // MARK: Nothing over the menu bar (motion 12, systems 12)

    static func menuBar(_ c: Checker) {
        let e = fakeEngine(16)
        runUntil(e, 4) { $0.state == .shown && $0.isSettled }
        var top = Double.infinity
        for p in e.poses {
            for x in [-6.0, 6.0] { top = min(top, Double(ClotheslineEngine.toScene(p, CGPoint(x: x, y: -11)).y)) }
        }
        c.check(top >= Double(sample.menuBarHeight) - 0.5, "resting pins stay under the menu bar", "highest pin top y \(f(top, 1))")
        // A dropping card never takes a click on the menu bar.
        let d = fakeEngine(3)
        var hits = 0
        runUntil(d, 1) { eng in
            for y in stride(from: 2.0, through: 39.5, by: 2.5) {
                for x in stride(from: 30.0, through: 500, by: 10) where eng.cardID(at: CGPoint(x: x, y: y)) != nil { hits += 1 }
            }
            return false
        }
        c.check(hits == 0, "while cards drop in, none takes a click on the menu bar", "\(hits) hits")
    }

    // MARK: Reduce Motion: every change is a fade (motion 13)

    static func reduceMotionFades(_ c: Checker) {
        let e = ClotheslineEngine(geometry: sample, reduceMotion: true)
        e.fileExists = { _ in true }
        e.hang((0..<3).map { URL(fileURLWithPath: "/tmp/cl-rmf-\($0).png") })
        let third = e.items[2].id
        var prev = 0.0, jump = 0.0
        runUntil(e, 0.6) { eng in
            let a = eng.pose(third)?.alpha ?? 0
            jump = max(jump, a - prev)
            prev = a
            return false
        }
        c.check(jump <= 0.05 && prev > 0.99, "Reduce Motion: each new card fades in (no pop)", "largest step per 1/240 s \(f(jump, 3))")
        runUntil(e, 2) { $0.isSettled }
        e.holdOpen = true
        let first = e.items[0].id
        var moves = 0, minAlpha = 1.0
        var lastX = e.pose(first)?.pivot.x ?? 0
        e.hang([URL(fileURLWithPath: "/tmp/cl-rmf-new.png")])
        runUntil(e, 0.6) { eng in
            guard let p = eng.pose(first) else { return true }
            minAlpha = min(minAlpha, p.alpha)
            if abs(p.pivot.x - lastX) > 0.5 && p.alpha > 0.05 { moves += 1 }
            lastX = p.pivot.x
            return false
        }
        c.check(moves == 0 && minAlpha < 0.05, "Reduce Motion: cards making room fade out, move, fade in (never slide)",
                "\(moves) visible moves, faded to \(f(minAlpha, 2))")
    }

    // MARK: The notch zone needs a rest (systems 4)

    static func notchRest(_ c: Checker) {
        let plain = ClotheslineGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeAreaTop: 0,
                                        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055), leftArea: nil, rightArea: nil)
        var drops: [String] = []
        for (label, geo, ys) in [("notch", sample, [12.0, 30, 46]), ("no notch", plain, [12.0, 20])] {
            for y in ys {
                for speed in [300.0, 600, 1000] {
                    let e = fakeEngine(5, geometry: geo, prefix: "cl-sweep")
                    runUntil(e, 5) { $0.state == .hidden && $0.revealCount == 1 && $0.time > 1 }
                    var t = e.time, x = 200.0
                    while x < Double(geo.width) - 200 {
                        t += 1.0 / 120; e.advance(to: t)
                        x += speed / 120
                        e.pointerMoved(to: CGPoint(x: x, y: y))
                    }
                    e.advance(to: t + 0.3)
                    if e.revealCount > 1 { drops.append("\(label) y \(Int(y)) \(Int(speed)) pt/s") }
                }
            }
        }
        c.check(drops.isEmpty, "moving across the menu bar through the notch zone (300–1000 pt/s) never drops the line",
                drops.isEmpty ? "15 sweeps" : drops.joined(separator: "; "))
        func rest(_ geo: ClotheslineGeometry, _ p: CGPoint, _ seconds: Double) -> Bool {
            let e = fakeEngine(3, geometry: geo, prefix: "cl-rest")
            runUntil(e, 5) { $0.state == .hidden && $0.time > 1 }
            e.pointerMoved(to: p)
            simulate(e, seconds)
            return e.revealCount > 1
        }
        let margin = CGPoint(x: 868, y: 47), beside = CGPoint(x: 905, y: 20), inNotch = CGPoint(x: 868, y: 20)
        c.check(!rest(sample, margin, 2) && !rest(sample, beside, 2) && !rest(sample, inNotch, 0.49) && rest(sample, inNotch, 0.51),
                "under the notch (the window-title strip) and just beside it a rest never drops the line (2 s); in the notch 0.5 s does, 0.49 s doesn't")
        c.check(!rest(plain, CGPoint(x: 960, y: 10), 0.49) && rest(plain, CGPoint(x: 960, y: 10), 0.51)
                && !rest(plain, CGPoint(x: 960, y: 32), 2),
                "without a notch the virtual notch needs a 0.5 s rest (and the strip under it none at all)")
        // Pushing against the top edge (the same position again and again) is a rest, with a notch and without.
        var pushed: [String] = []
        for (label, geo) in [("notch", sample), ("no notch", plain)] {
            let push = fakeEngine(3, geometry: geo, prefix: "cl-push")
            runUntil(push, 5) { $0.state == .hidden && $0.time > 1 }
            var early = false
            for i in 0..<64 {
                push.pointerMoved(to: CGPoint(x: geo.notch.midX, y: 0)); simulate(push, 1.0 / 120)
                if i == 57 { early = push.revealCount > 1 }
            }
            if early || push.revealCount < 2 { pushed.append("\(label): \(early ? "before 0.48 s" : "never")") }
        }
        c.check(pushed.isEmpty, "pushing the pointer up into the notch (or the virtual one) is a rest: it drops the line after 0.5 s",
                pushed.isEmpty ? "both" : pushed.joined(separator: "; "))
    }

    // MARK: Scroll gestures hold the line; a lost "ended" lets go (systems 5)

    static func scrollGesture(_ c: Checker) {
        let e = fakeEngine(3)
        runUntil(e, 2) { $0.state == .shown }
        e.pointerMoved(to: CGPoint(x: 420, y: 150))
        e.scroll(.init(phase: .began, delta: 0, time: e.time))
        var hiddenWhileTracking = false
        for _ in 0..<240 {
            for _ in 0..<4 { e.step(h) }
            e.scroll(.init(phase: .changed, delta: 3, time: e.time))
            if e.state != .shown { hiddenWhileTracking = true }
        }
        e.pointerMoved(to: CGPoint(x: 1300, y: 600))
        c.check(!hiddenWhileTracking, "no retract during a scroll gesture (4 s of pulling against the end)", e.state.rawValue)
        // The fingers lift but "ended" never comes.
        let lost = e.time
        var idleAt: Double?, retractAt: Double?
        runUntil(e, 3) { eng in
            if idleAt == nil && eng.scroller.mode != .tracking { idleAt = eng.time - lost }
            if eng.state == .retracting { retractAt = eng.time; return true }
            return false
        }
        c.check((idleAt ?? 9) <= 0.3 + 2 * h && retractAt != nil, "a gesture whose “ended” is lost is let go after 0.3 s, then the line goes",
                "let go at \(idleAt.map { f($0, 3) } ?? "never") s, retract \(retractAt.map { f($0 - lost, 2) } ?? "never") s")
        // Retract right after a flick: once hidden, nothing keeps moving.
        let g = fakeEngine(16)
        runUntil(g, 4) { $0.state == .shown && $0.isSettled }
        g.scroller.release(velocity: 3000)
        g.retract()
        runUntil(g, 2) { $0.state == .hidden }
        c.check(g.state == .hidden && !g.needsFrames, "a flick followed by a retract: hidden means still (no frames)",
                "needs frames \(g.needsFrames), scroller \(g.scroller.mode)")
    }

    // MARK: Hanging more than 50 at once (systems 8)

    static func capacityBatch(_ c: Checker) {
        let e = ClotheslineEngine(geometry: sample)
        e.fileExists = { _ in true }
        e.hang((0..<60).map { URL(fileURLWithPath: "/tmp/cl-cap-\($0).png") })
        simulate(e, 10)
        e.hang((60..<120).map { URL(fileURLWithPath: "/tmp/cl-cap-\($0).png") })
        simulate(e, 10)
        c.check(e.items.count == 50 && e.cards.count == 50 && e.pendingArrivals.isEmpty,
                "hanging 60 files at once (twice): 50 cards, no orphans", "items \(e.items.count), cards \(e.cards.count)")
    }

    // MARK: Hidden and still: mouse moves cost no physics (systems 9)

    static func idleCost(_ c: Checker) {
        let e = fakeEngine(50, prefix: "cl-idle")
        runUntil(e, 6) { $0.state == .hidden && $0.time > 1 }
        let before = e.substepCount
        var t = e.time
        for i in 0..<240 { t += 1.0 / 120; e.advance(to: t); e.pointerMoved(to: CGPoint(x: 100 + Double(i), y: 500)) }
        c.check(e.substepCount == before && e.time == t, "hidden with 50 files: 2 s of mouse moves run no physics",
                "\(e.substepCount - before) substeps")
    }

    // MARK: Hover follows cards gliding under a still pointer (systems 10)

    static func hoverFollows(_ c: Checker) {
        let e = fakeEngine(16)
        runUntil(e, 4) { $0.state == .shown && $0.isSettled }
        e.holdOpen = true
        guard let pose = e.items.first.flatMap({ e.pose($0.id) }) else { return }
        let p = ClotheslineEngine.toScene(pose, CGPoint(x: 0, y: 60))
        e.pointerMoved(to: p)
        e.scroller.release(velocity: 1300)   // glides about 650 pt: another card ends up under the pointer
        runUntil(e, 4) { $0.isSettled }
        let under = e.cardID(at: p)
        c.check(under != nil && e.hoveredCard == under && e.hoveredCard != e.items.first?.id,
                "after cards glide under a still pointer, the hovered card is the one under it",
                "hovered \(e.items.firstIndex { $0.id == e.hoveredCard }.map(String.init) ?? "none"), under \(e.items.firstIndex { $0.id == under }.map(String.init) ?? "none")")
    }

    // MARK: VoiceOver (systems 7)

    static func voiceOver(_ c: Checker) {
        let e = shownEngine(3)
        e.holdOpen = false
        e.pointerMoved(to: CGPoint(x: 1300, y: 600))
        e.accessibilityFocus = e.items[1].id
        simulate(e, 5)
        c.check(e.state == .shown, "the line stays out while VoiceOver is on a card", e.state.rawValue)
        e.accessibilityFocus = nil
        runUntil(e, 3) { $0.state == .retracting }
        c.check(e.state == .retracting, "… and goes once it moves away", e.state.rawValue)
        let v = ClotheslineEngine(geometry: sample)
        v.fileExists = { _ in true }
        v.voiceOverRunning = { true }
        v.hang([URL(fileURLWithPath: "/tmp/cl-vo.png")])
        var at: Double?
        runUntil(v, 10) { eng in if eng.state == .retracting { at = eng.time; return true }; return false }
        c.check(abs((at ?? 0) - (v.lastArrival ?? 0) - 6) <= 2 * h, "with VoiceOver running the line stays 6 s after new files",
                "\(f((at ?? 0) - (v.lastArrival ?? 0), 3)) s")
    }

    // MARK: Small ones (systems 2, 3, 13, 15, 16, 17)

    static func smallFixes(_ c: Checker) {
        var far = sample
        far.screenFrame = far.screenFrame.offsetBy(dx: 200_000, dy: 200_000)
        let panel = ClotheslinePanel(geometry: far)
        c.check(panel.level == .statusBar && panel.isFloatingPanel && !panel.isVisible, "the panel's window level is .statusBar (above the menu bar)",
                "level \(panel.level.rawValue), never shown")

        // Increase Contrast.
        let normal = ClotheslineArt.Palette.current(dark: false), strong = ClotheslineArt.Palette.current(dark: false, contrast: true)
        let darkStrong = ClotheslineArt.Palette.current(dark: true, contrast: true)
        c.check(strong.edgeWidth == 1 && strong.matEdge.alphaComponent >= 0.35 && strong.stringColors.allSatisfy({ $0.alphaComponent == 1 }) && strong.glowOpacity == 0
                && darkStrong.matEdge.alphaComponent >= 0.45 && normal.edgeWidth == 0.5,
                "Increase Contrast: solid 1 pt card edges and an opaque string with no glow (light and dark)")
        let content = ClotheslineArt.CardContent(name: "a.png", thumbnail: nil, isIcon: true, duration: nil)
        let plainImage = ClotheslineArt.cardImage(content, width: 104, dark: false, scale: 2)
        let strongImage = ClotheslineArt.cardImage(content, width: 104, dark: false, contrast: true, scale: 2)
        if let a = plainImage, let b = strongImage, let pa = pixel(a, x: 5, y: a.height / 2), let pb = pixel(b, x: 5, y: b.height / 2) {
            c.check(pb.0 < pa.0 - 0.1, "… the card's edge is visibly darker", "edge pixel \(f(pa.0, 2)) → \(f(pb.0, 2))")
        }

        // Reduce Motion switched on while hidden.
        let rm = fakeEngine(3, prefix: "cl-rmtoggle")
        runUntil(rm, 5) { $0.state == .hidden && $0.time > 1 }
        rm.reduceMotion = true
        simulate(rm, 0.1)
        c.check(rm.line.value == 0 && rm.lineAlpha == 0 && !rm.needsFrames, "Reduce Motion turned on while hidden: nothing shows, nothing runs")

        // A new video written later to the same name gets its own duration (the cache key has the modification date).
        do {
            let dir = try scratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            let video = dir.appendingPathComponent("render.mp4")
            try Data("x".utf8).write(to: video)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: video.path)
            let first = ClotheslineArt.durationKey(video)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_060)], ofItemAtPath: video.path)
            let second = ClotheslineArt.durationKey(video)
            c.check(first != second && first.hasPrefix(video.path), "video durations are cached by path and modification date",
                    "\(first.split(separator: "|").last ?? "") → \(second.split(separator: "|").last ?? "")")
        } catch {
            c.check(false, "duration key setup", error.localizedDescription)
        }

        // DW_SELFCHECK_LINE with newlines (names with “|”).
        let files = Clothesline.selfCheckFiles(["DW_SELFCHECK_LINE": "/tmp/with | pipe.png\n/tmp/b.png\n"])
        c.check(files?.map(\.path) == ["/tmp/with | pipe.png", "/tmp/b.png"], "DW_SELFCHECK_LINE also takes one path per line",
                files?.map(\.lastPathComponent).joined(separator: ", ") ?? "nil")
    }

    // MARK: Turning the line off; announcements; click-through during a drag (systems 6, 7, 3)

    static func teardown(_ c: Checker) throws {
        let fixtures = ClotheslinePreview.fixturesRoot()?.appendingPathComponent("core")
        let urls = ["photo.png", "clip.mp4", "report.pdf"].compactMap { fixtures?.appendingPathComponent($0) }
        guard urls.count == 3 else { c.check(false, "fixtures"); return }
        ShelfThumbnails.preload(urls, size: ClotheslineView.thumbnailRequest)
        var now = 500.0
        let engine = ClotheslineEngine(geometry: sample, time: now)
        let surface = ClotheslineOffscreenSurface(engine: engine)
        let clock = ClotheslineManualClock()
        let ctl = ClotheslineController(engine: engine, surface: surface, clock: clock, now: { now })
        ctl.usesTimers = false
        var installs = 0, removed = 0
        ctl.monitorInstaller = { installs += 1; return ["global", "local"] }
        ctl.monitorRemover = { _ in removed += 1 }
        func frames(_ seconds: Double) { for _ in 0..<Int((seconds * 60).rounded()) { now += 1.0 / 60; ctl.tick(at: now) } }
        ctl.pointerMoved(screen: sample.screenPoint(fromScene: CGPoint(x: 1300, y: 700)))
        ctl.hang([urls[0]])
        c.check(surface.view.lastAnnouncement == "photo.png added to the Clothesline", "VoiceOver hears which file was hung",
                surface.view.lastAnnouncement ?? "nothing")
        ctl.hang(Array(urls.dropFirst()))
        c.check(surface.view.lastAnnouncement == "2 files added to the Clothesline" && installs == 1,
                "… or how many; the pointer monitors are added once", "\(surface.view.lastAnnouncement ?? "nothing"), \(installs) installs")
        frames(1.2)
        guard let pose = engine.items.first.flatMap({ engine.pose($0.id) }) else { c.check(false, "pose"); return }
        ctl.pointerMoved(screen: sample.screenPoint(fromScene: ClotheslineEngine.toScene(pose, CGPoint(x: 0, y: 60))))
        let overCard = !surface.ignoresMouse
        engine.isDragging = true
        ctl.clotheslineNeedsUpdate()
        let duringDrag = surface.ignoresMouse
        engine.isDragging = false
        ctl.clotheslineNeedsUpdate()
        c.check(overCard && duringDrag && !surface.ignoresMouse,
                "while a card is dragged out the panel lets the mouse through (drops land on the windows below)")
        ctl.shutDown()
        c.check(engine.items.isEmpty && engine.cards.isEmpty && engine.state == .hidden && !clock.isRunning && !surface.isShown
                && ctl.monitors.isEmpty && removed == 2 && ctl.scheduledDeadline == nil && surface.view.cardLayerCount == 0,
                "Clothesline off: empty, panel ordered out, clock stopped, monitors removed, card layers freed",
                "items \(engine.items.count), monitors removed \(removed), layers \(surface.view.cardLayerCount)")
        ctl.pointerMoved(screen: sample.screenPoint(fromScene: CGPoint(x: 868, y: 10)))
        frames(0.8)
        c.check(engine.state == .hidden && !clock.isRunning, "… the notch does nothing after that")
        ctl.hang([urls[0]])
        c.check(installs == 2 && ctl.monitors.count == 2 && surface.isShown, "the next hang() turns it on again")
        ctl.shutDown()
    }

    // MARK: Renamed and deleted files (systems 11)

    static func renamedFiles(_ c: Checker) throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = (0..<3).map { dir.appendingPathComponent("file \($0).txt") }
        try urls.forEach { try Data("x".utf8).write(to: $0) }
        let engine = ClotheslineEngine(geometry: sample)
        let view = ClotheslineView(engine: engine, frame: CGRect(origin: .zero, size: sample.panelFrame.size))
        engine.onItemsChange = { view.itemsChanged() }
        engine.hang(urls)
        runUntil(engine, 4) { $0.state == .shown && $0.pendingArrivals.isEmpty }
        engine.holdOpen = true
        let ids = engine.items.map(\.id)
        let renamed = dir.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: urls[1], to: renamed)
        let pb = NSPasteboard(name: NSPasteboard.Name("DropWheel.clothesline.rename.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let copied = view.copy(ids[1], to: pb)
        let read = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        let label = view.accessibilityCardElements.first { $0.id == ids[1] }?.accessibilityLabel()
        c.check(copied && read?.first?.lastPathComponent == "renamed.txt" && engine.item(ids[1])?.url.lastPathComponent == "renamed.txt"
                && label == "renamed.txt", "a renamed file is followed (Copy gives its new path; its name updates)",
                "\(read?.first?.lastPathComponent ?? "nothing"), label \(label ?? "")")
        try FileManager.default.removeItem(at: urls[0])
        let gone = view.copy(ids[0], to: pb)
        c.check(!gone && engine.item(ids[0]) == nil && engine.cards[ids[0]]?.leaving == true,
                "acting on a deleted file does nothing and its card lifts away")
    }

    // MARK: A drag from another app leaves the line alone (integration review)

    static func otherAppDrag(_ c: Checker) throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = (0..<8).map { dir.appendingPathComponent("drag \($0).txt") }
        try urls.forEach { try Data("x".utf8).write(to: $0) }
        var now = 700.0
        let engine = ClotheslineEngine(geometry: sample, time: now)
        let surface = ClotheslineOffscreenSurface(engine: engine)
        let ctl = ClotheslineController(engine: engine, surface: surface, clock: ClotheslineManualClock(), now: { now })
        ctl.usesTimers = false
        func frames(_ seconds: Double) { for _ in 0..<Int((seconds * 60).rounded()) { now += 1.0 / 60; ctl.tick(at: now) } }
        /// A pointer event at a scene point: a plain move, or a drag (a button held).
        func at(_ p: CGPoint, held: Bool) { ctl.pointerMoved(screen: sample.screenPoint(fromScene: p), buttonHeld: held) }
        at(CGPoint(x: 1300, y: 700), held: false)
        ctl.hang(urls)
        frames(4.5)
        guard engine.state == .hidden else { c.check(false, "other-app drag: the line retracts first", engine.state.rawValue); return }
        // A file dragged from Finder pauses in the notch, then in the strip under it (aiming at something there).
        at(CGPoint(x: 868, y: 20), held: true)
        frames(0.7)
        at(CGPoint(x: 868, y: 47), held: true)
        frames(0.4)
        c.check(engine.state == .hidden && ctl.scheduledDeadline == nil && engine.revealCount == 1,
                "a drag from another app that pauses at the notch doesn't drop the line (no wake-up is even scheduled)",
                "\(engine.state.rawValue), \(engine.revealCount - 1) reveals")
        at(CGPoint(x: 868, y: 21), held: false)
        frames(0.55)
        c.check(engine.state != .hidden, "… the same rest with no button held drops it", engine.state.rawValue)
        frames(1.2)
        guard let pose = engine.items.first.flatMap({ engine.pose($0.id) }) else { c.check(false, "other-app drag: pose"); return }
        let onCard = ClotheslineEngine.toScene(pose, CGPoint(x: 0, y: 60))
        at(onCard, held: true)
        c.check(surface.ignoresMouse && engine.hoveredCard == nil,
                "that drag over a card passes through to the windows below (no hover; the panel takes no mouse)")
        at(CGPoint(x: onCard.x + 1, y: onCard.y), held: false)
        c.check(!surface.ignoresMouse && engine.hoveredCard != nil, "… the pointer alone on the card is taken, as before")
        engine.setPressed(engine.hoveredCard)
        at(CGPoint(x: onCard.x + 2, y: onCard.y), held: true)
        c.check(!surface.ignoresMouse && !engine.otherDrag,
                "a press that began on a card keeps the mouse (so the card can be dragged out)")
        engine.setPressed(nil)
        // A retracting line isn't caught by another app's drag.
        at(CGPoint(x: 1300, y: 700), held: false)
        ctl.retract()
        frames(0.05)
        if let moving = engine.items.first.flatMap({ engine.pose($0.id) }) {
            let card = ClotheslineEngine.toScene(moving, CGPoint(x: 0, y: 40))
            at(card, held: true)
            frames(0.05)
            c.check(engine.state == .retracting, "a drag from another app across a retracting line doesn't catch it",
                    engine.state.rawValue)
        }
        ctl.shutDown()
    }

    // MARK: Show Clothesline holds the line as long as new files do (integration review)

    static func menuReveal(_ c: Checker) {
        func hold(voiceOver: Bool) -> Double? {
            let e = fakeEngine(3, prefix: "cl-menureveal")
            e.voiceOverRunning = { voiceOver }
            runUntil(e, 12) { $0.state == .hidden && $0.time > 1 }
            e.reveal()
            return runUntil(e, 10) { $0.state == .retracting }
        }
        let plain = hold(voiceOver: false), spoken = hold(voiceOver: true)
        c.check(plain.map { abs($0 - 2) <= 0.02 } ?? false && spoken.map { abs($0 - 6) <= 0.02 } ?? false,
                "Show Clothesline keeps the line out 2 s, and 6 s while VoiceOver runs (as for new files)",
                "\(plain.map { f($0) } ?? "never") s, VoiceOver \(spoken.map { f($0) } ?? "never") s")
    }
}
#endif
