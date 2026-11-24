import Foundation

/// A spring described the way Apple describes them (WWDC 2018 "Designing Fluid Interfaces"): a damping ratio
/// (1 = no overshoot, lower = bouncier) and a response in seconds (how quickly it gets there), unit mass.
/// It always moves on from its current value and velocity, so changing `target` mid-flight never jumps.
struct ClotheslineSpring: Equatable {
    var value: Double
    var velocity: Double = 0
    var target: Double
    var damping: Double
    var response: Double

    init(_ value: Double, target: Double? = nil, damping: Double, response: Double) {
        self.value = value
        self.target = target ?? value
        self.damping = damping
        self.response = response
    }

    var stiffness: Double { pow(2 * .pi / response, 2) }
    var friction: Double { 4 * .pi * damping / response }

    /// One semi-implicit Euler step (stable for these stiffnesses at the 240 Hz substep), with an extra force.
    mutating func step(_ h: Double, force: Double = 0) {
        let a = -stiffness * (value - target) - friction * velocity + force
        velocity += a * h
        value += velocity * h
    }

    func isSettled(position: Double, speed: Double) -> Bool {
        abs(value - target) < position && abs(velocity) < speed
    }

    mutating func snap() { value = target; velocity = 0 }
}

/// Apple's scroll physics: momentum projection with a per-millisecond deceleration rate and rubber-banding.
enum ClotheslineScrollMath {
    /// Normal scroll feel (UIScrollView.DecelerationRate.normal).
    static let deceleration = 0.998

    /// How far a release at `velocity` (points per second) travels before it stops:
    /// `(v / 1000) · d / (1 − d)` (the sample code of "Designing Fluid Interfaces").
    static func project(_ velocity: Double, deceleration d: Double = deceleration) -> Double {
        (velocity / 1000) * d / (1 - d)
    }

    /// The rubber band: past a bound, the content follows less and less. `dimension` is the visible size.
    static func rubberband(_ overshoot: Double, dimension: Double, constant c: Double = 0.55) -> Double {
        guard dimension > 0 else { return 0 }
        let x = abs(overshoot)
        let r = (x * dimension * c) / (dimension + c * x)
        return overshoot < 0 ? -r : r
    }

    /// The presented offset for a raw (finger) offset, rubber-banded outside `0…maxOffset`.
    static func banded(_ raw: Double, maxOffset: Double, dimension: Double) -> Double {
        if raw < 0 { return rubberband(raw, dimension: dimension) }
        if raw > maxOffset { return maxOffset + rubberband(raw - maxOffset, dimension: dimension) }
        return raw
    }

    /// The raw offset that presents as `presented` (inverse of `banded`), so a new touch picks up where the content is.
    static func unbanded(_ presented: Double, maxOffset: Double, dimension: Double, constant c: Double = 0.55) -> Double {
        func inverse(_ r: Double) -> Double {
            let y = abs(r)
            guard y < dimension else { return r < 0 ? -1e6 : 1e6 }
            let x = y * dimension / (c * (dimension - y))
            return r < 0 ? -x : x
        }
        if presented < 0 { return inverse(presented) }
        if presented > maxOffset { return maxOffset + inverse(presented - maxOffset) }
        return presented
    }
}

/// One scroll input, already reduced from an NSEvent: the horizontal content delta in points (positive moves the
/// cards left, toward later ones), the gesture phase and a timestamp in seconds.
struct ClotheslineScrollInput: Equatable {
    enum Phase: Equatable { case began, changed, ended, cancelled, wheel, momentum }
    var phase: Phase
    var delta: Double
    var time: Double
}

/// Horizontal scrolling of the cards along the line: 1:1 while the fingers move, Apple's momentum on release,
/// rubber-banding past either end, and a critically damped spring for mouse-wheel steps.
struct ClotheslineScroller {
    enum Mode: Equatable { case idle, tracking, decelerating, bouncing, wheel }
    private(set) var mode: Mode = .idle
    /// What the cards show (rubber-banded).
    private(set) var offset: Double = 0
    /// Points per second of `offset`.
    private(set) var velocity: Double = 0
    private var raw: Double = 0
    private var samples: [(time: Double, delta: Double)] = []
    private var spring = ClotheslineSpring(0, damping: 1, response: 0.4)
    /// The largest offset (content wider than the line), and the visible line length for the rubber band.
    var maxOffset: Double = 0
    var dimension: Double = 1000
    /// The velocity at the last release, for tests.
    private(set) var releaseVelocity: Double = 0
    /// Where the last release was projected to come to rest (before clamping to the bounds), for tests.
    private(set) var projectedRest: Double = 0

    static let bounceResponse = 0.4
    static let wheelResponse = 0.22
    /// Velocity is the average of the deltas in this window before the release.
    static let velocityWindow = 0.08

    var isIdle: Bool { mode == .idle }

    mutating func handle(_ input: ClotheslineScrollInput) {
        switch input.phase {
        case .began:
            raw = ClotheslineScrollMath.unbanded(offset, maxOffset: maxOffset, dimension: dimension)
            samples = [(input.time, 0)]
            mode = .tracking
            if input.delta != 0 { track(input) }
        case .changed:
            if mode != .tracking {
                raw = ClotheslineScrollMath.unbanded(offset, maxOffset: maxOffset, dimension: dimension)
                samples = []
                mode = .tracking
            }
            track(input)
        case .ended, .cancelled:
            guard mode == .tracking else { return }
            if input.delta != 0 { track(input) }
            // Release velocity: the deltas of the last 80 ms over the time they took. A finger that rested before
            // lifting has no recent samples, so it lets go with no velocity.
            let recent = samples.filter { input.time - $0.time <= Self.velocityWindow }
            var v = 0.0
            if input.phase == .ended, let first = recent.first, let last = recent.last, recent.count >= 2 {
                let span = max(last.time - first.time, 1.0 / 120)
                v = recent.dropFirst().reduce(0) { $0 + $1.delta } / span
            }
            v = max(-8000, min(8000, v))
            release(velocity: v)
        case .wheel:
            if mode != .wheel {
                spring = ClotheslineSpring(offset, damping: 1, response: Self.wheelResponse)
                spring.velocity = velocity
                mode = .wheel
            }
            spring.target = max(0, min(maxOffset, spring.target + input.delta))
        case .momentum:
            break   // the system's own momentum is ignored; ours follows the release
        }
    }

    private mutating func track(_ input: ClotheslineScrollInput) {
        raw += input.delta
        offset = ClotheslineScrollMath.banded(raw, maxOffset: maxOffset, dimension: dimension)
        samples.append((input.time, input.delta))
        if samples.count > 24 { samples.removeFirst(samples.count - 24) }
    }

    /// Hands the release velocity over: momentum when inside the bounds, a spring back when past one.
    mutating func release(velocity v: Double) {
        releaseVelocity = v
        velocity = v
        projectedRest = offset + ClotheslineScrollMath.project(v)
        if offset < 0 || offset > maxOffset {
            startBounce()
        } else if abs(v) > 1 {
            mode = .decelerating
        } else {
            mode = .idle
            velocity = 0
        }
    }

    private mutating func startBounce() {
        spring = ClotheslineSpring(offset, target: offset < 0 ? 0 : maxOffset, damping: 1, response: Self.bounceResponse)
        spring.velocity = max(-5000, min(5000, velocity))
        mode = .bouncing
    }

    /// Jumps to an offset (programmatic, e.g. showing the newest card), springing there unless `animated` is false.
    mutating func scroll(to target: Double, animated: Bool) {
        let t = max(0, min(maxOffset, target))
        if !animated { offset = t; velocity = 0; mode = .idle; return }
        if mode == .tracking { return }
        spring = ClotheslineSpring(offset, target: t, damping: 1, response: Self.bounceResponse)
        spring.velocity = velocity
        mode = .wheel
    }

    /// Keeps the offset inside new bounds (content changed), springing back when it is now past one.
    mutating func boundsChanged() {
        if mode == .idle && (offset < 0 || offset > maxOffset) { velocity = 0; startBounce() }
        if mode == .wheel { spring.target = max(0, min(maxOffset, spring.target)) }
    }

    mutating func step(_ h: Double, now: Double) {
        switch mode {
        case .idle, .tracking:
            if mode == .tracking {
                // Velocity while tracking, for the tilt: the deltas of the recent window (none: the fingers rest).
                let recent = samples.filter { now - $0.time <= Self.velocityWindow }
                velocity = recent.reduce(0) { $0 + $1.delta } / Self.velocityWindow
            }
        case .decelerating:
            // v(t) = v0 · d^(1000 t): exact over the step.
            let d = ClotheslineScrollMath.deceleration
            let k = pow(d, 1000 * h)
            offset += velocity * (k - 1) / (1000 * log(d))
            velocity *= k
            if offset < 0 || offset > maxOffset {
                startBounce()
            } else if abs(velocity) < 2 {
                velocity = 0
                mode = .idle
            }
        case .bouncing, .wheel:
            spring.step(h)
            offset = spring.value
            velocity = spring.velocity
            if spring.isSettled(position: 0.05, speed: 1) {
                spring.snap()
                offset = spring.value
                velocity = 0
                mode = .idle
            }
        }
    }

    /// Called when the pointer has stopped feeding a gesture for a while (a lost .ended): let go with no velocity.
    mutating func abandonTracking() {
        if mode == .tracking { release(velocity: 0) }
    }

    /// Stops at once where it is, inside the bounds (the line went away: nothing is left to watch).
    mutating func settle() {
        offset = max(0, min(maxOffset, offset))
        raw = offset
        velocity = 0
        samples = []
        mode = .idle
    }
}

/// Small numeric helpers.
enum ClotheslineMath {
    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }
    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        guard b != a else { return x < a ? 0 : 1 }
        let t = clamp((x - a) / (b - a), 0, 1)
        return t * t * (3 - 2 * t)
    }
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    static func degrees(_ r: Double) -> Double { r * 180 / .pi }
    static func radians(_ d: Double) -> Double { d * .pi / 180 }
}
