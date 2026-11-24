import AppKit
import AVFoundation

/// Feedback when the highlight moves to a new petal: an alignment haptic timed to the next frame, then a tick
/// for every petal the pointer crossed, each following its setting. Main thread.
enum PetalFeedback {
    private static var lastChange: TimeInterval = 0

    /// `steps`: how many petals the highlight moved by (1 for a neighbour; more when a fast sweep skipped some).
    /// `moveTime`: how long the pointer took for this move (the time since its previous position), which sets
    /// how close together the ticks of skipped petals sound.
    static func petalChanged(steps: Int = 1, moveTime: TimeInterval? = nil) {
        if Settings.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
        }
        let now = ProcessInfo.processInfo.systemUptime
        let interval = now - lastChange
        lastChange = now
        if Settings.petalSounds { PetalSound.shared.play(steps: steps, interval: interval, moveTime: moveTime) }
    }
}

/// The petal sounds. All are made in code (no sound files) to sound mechanical rather than electronic:
/// a contact transient (a burst of noise a millisecond or two long) that rings a few damped resonances.
enum PetalSoundStyle: String, CaseIterable, Identifiable {
    case dial, click, wood, pop, glass
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dial: return "Dial"
        case .click: return "Click"
        case .wood: return "Wood"
        case .pop: return "Pop"
        case .glass: return "Glass"
        }
    }

    /// Relative peak level, so all five sound equally loud: each sweep preview measured within 1 dB of Dial's
    /// −33.7 LUFS with earshot (Glass rings longest, so it peaks lowest).
    var level: Double {
        switch self {
        case .dial: return 1
        case .click: return 1
        case .wood: return 0.74
        case .pop: return 0.75
        case .glass: return 0.39
        }
    }

    var detail: String {
        switch self {
        case .dial: return "The click of a rotary phone dial."
        case .click: return "A short, crisp mechanical tick."
        case .wood: return "A soft knock on wood."
        case .pop: return "A quiet, rounded pop."
        case .glass: return "A small, bright tap on glass."
        }
    }
}

/// Plays petal ticks through AVAudioEngine: eight voices, each through a varispeed, taking turns so a ringing tick
/// is not cut short by the next. A sweep's speed sets the rate (faster sweeps give slightly higher, shorter ticks,
/// the way a dial runs faster when spun harder). A jump across several petals in one move plays a tick for each
/// petal crossed: they are mixed into one buffer at offsets that the voice's varispeed turns into exact gaps, and
/// it goes out like a single tick, so the spacing never depends on the audio device's buffer size.
/// The engine runs while a wheel that plays feedback is on screen (`hold`/`release`) and pauses after 4 s of
/// quiet, which releases the audio device. Everything that touches the engine runs on one serial queue.
final class PetalSound {
    static let shared = PetalSound()

    static let voiceCount = 8
    static let sampleRate = 48_000.0
    /// Peak level of a single tick (about −17 dBFS, like a quiet system click).
    static let peak: Float = 0.14
    /// A move whose first tick would start later than this after the highlight moved is dropped: late feedback
    /// reads as belonging to something else. (Samples asked for in Settings always play.)
    static let maximumDelay: TimeInterval = 0.15
    /// The ticks of one move all start within this time of its first.
    static let maximumSpread: TimeInterval = 0.1
    /// The engine pauses (and lets the audio device go) after this long without a tick and with no wheel open.
    /// A variable only so self-tests can shorten it.
    static var idleStop: TimeInterval = 4

    private let queue = DispatchQueue(label: "com.yummyorange.app.petal-sound", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private var voices: [(player: AVAudioPlayerNode, speed: AVAudioUnitVarispeed)] = []
    private var samplesCache: [PetalSoundStyle: [Float]] = [:]
    private var buffers: [PetalSoundStyle: AVAudioPCMBuffer] = [:]
    private var next = 0
    private var lastPlay: TimeInterval = 0
    /// Wheels on screen that play feedback; while any is, the engine keeps running.
    private var holders = Set<ObjectIdentifier>()
    /// The engine was paused by the idle timer, so its voices are still set up and playing. False after the engine
    /// stopped itself (an output device or sample rate change, an audio server reset): its voices then need a reset.
    private var pausedByIdle = false
    private var configObserver: NSObjectProtocol?
    // Self-test probes.
    private var renderedBuffers = 0
    private var probePeak: Float = 0

    private init() {
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: nil) { [weak self] _ in
            self?.queue.async { self?.pausedByIdle = false }
        }
    }

    static func isTimely(requested: TimeInterval, now: TimeInterval) -> Bool { now - requested <= maximumDelay }

    /// Keeps the engine running while `owner` (a wheel that plays feedback) is on screen, starting it now when
    /// `start` is true so the first tick isn't late. Calling it again for the same owner does nothing new.
    func hold(_ owner: AnyObject, start: Bool) {
        let id = ObjectIdentifier(owner)
        queue.async { [self] in
            holders.insert(id)
            if start { _ = startIfNeeded() }
        }
    }

    /// Ends `owner`'s hold; the engine pauses `idleStop` seconds after the last tick once no wheel holds it.
    func release(_ owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        queue.async { [self] in
            guard holders.remove(id) != nil else { return }
            lastPlay = max(lastPlay, ProcessInfo.processInfo.systemUptime)
            stopWhenIdle()
        }
    }

    /// A single tick in `style` (Settings plays one when the choice changes). It plays even after a slow start.
    func sample(_ style: PetalSoundStyle) { play(steps: 1, interval: 1, style: style, alwaysPlay: true) }

    /// One tick per petal crossed. `interval` is the time since the previous petal change (it sets the rate);
    /// `moveTime` is how long this move took (it sets the gaps between the ticks of skipped petals).
    func play(steps: Int, interval: TimeInterval, moveTime: TimeInterval? = nil,
              style: PetalSoundStyle = Settings.petalSoundStyle, alwaysPlay: Bool = false) {
        let requested = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            guard startIfNeeded() else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard alwaysPlay || Self.isTimely(requested: requested, now: now) else { return }
            let plan = Self.plan(steps: steps, interval: interval, moveTime: moveTime)
            guard let first = plan.first, let buffer = plan.count == 1 ? buffer(style) : moveBuffer(style, plan: plan) else { return }
            let voice = voices[next]
            next = (next + 1) % voices.count
            voice.speed.rate = first.rate
            voice.player.volume = first.volume
            voice.player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionCallbackType: .dataRendered) { [weak self] _ in
                self?.queue.async { self?.renderedBuffers += 1 }
            }
            if !voice.player.isPlaying { voice.player.play() }
            lastPlay = now
            stopWhenIdle()
        }
    }

    /// One scheduled tick: when (seconds after the move's first), how fast (1 = as made) and how loud (0…1).
    struct Tick: Equatable { var delay: Double; var rate: Float; var volume: Float }

    /// The ticks for a move of `steps` petals, made `interval` seconds after the previous petal change and taking
    /// `moveTime` (the interval when not known). Speed is petals per second; the rate rises smoothly from 1.0 (5
    /// petals/s or slower) to 1.3 (20/s or faster), so a fast sweep runs higher and shorter like a dial spun hard,
    /// and the volume eases off by up to a fifth so it never gets louder. Crossed petals are spread over the move,
    /// 12 to 40 ms apart and all within `maximumSpread`, at most 6 per move.
    static func plan(steps: Int, interval: TimeInterval, moveTime: TimeInterval? = nil) -> [Tick] {
        let n = max(1, min(steps, 6))
        let span = interval.isFinite && interval > 0 ? interval : 1
        let pps = Double(max(1, steps)) / span
        let x = min(max((pps - 5) / 15, 0), 1)
        let eased = x * x * (3 - 2 * x)
        let rate = Float(1 + 0.3 * eased)
        let volume = Float(1 - 0.2 * eased)
        let move = moveTime.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? span
        var spacing = min(max(move / Double(n), 0.012), 0.04)
        if n > 1 { spacing = min(spacing, maximumSpread / Double(n - 1)) }
        return (0..<n).map { Tick(delay: Double($0) * spacing, rate: rate, volume: volume) }
    }

    /// The samples of one move: `one` tick at each planned delay. A voice's varispeed at `rate` plays `rate`
    /// source frames per output frame, so a tick placed `delay × rate` seconds in comes out `delay` after the first.
    static func moveSamples(_ one: [Float], plan: [Tick]) -> [Float] {
        guard let rate = plan.first.map({ Double($0.rate) }) else { return [] }
        let offsets = plan.map { Int(($0.delay * rate * sampleRate).rounded()) }
        var out = [Float](repeating: 0, count: (offsets.max() ?? 0) + one.count)
        for o in offsets { for i in one.indices { out[o + i] += one[i] } }
        return out
    }

    /// Builds the voices once, then (re)starts the engine. After an idle pause it simply resumes; after the
    /// engine stopped itself the voices are reset, or they would stay silent. Every start schedules its own
    /// idle pause, so an engine started for a tick that then came too late doesn't keep the device awake.
    private func startIfNeeded() -> Bool {
        if voices.isEmpty {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1) else { return false }
            for _ in 0..<Self.voiceCount {
                let player = AVAudioPlayerNode(), speed = AVAudioUnitVarispeed()
                engine.attach(player); engine.attach(speed)
                engine.connect(player, to: speed, format: format)
                engine.connect(speed, to: engine.mainMixerNode, format: format)
                voices.append((player, speed))
            }
            engine.prepare()
        }
        if engine.isRunning { return true }
        let resume = pausedByIdle
        if !resume { voices.forEach { $0.player.stop() } }
        do { try engine.start() } catch {
            DragMonitor.log.error("petal sound: audio engine didn’t start: \(error.localizedDescription, privacy: .public)")
            return false
        }
        if !resume { voices.forEach { $0.player.play() } }
        pausedByIdle = false
        lastPlay = max(lastPlay, ProcessInfo.processInfo.systemUptime)
        stopWhenIdle()
        return true
    }

    /// Pauses the engine (releasing the audio device) once no wheel holds it and no tick has played for `idleStop`.
    private func stopWhenIdle() {
        queue.asyncAfter(deadline: .now() + Self.idleStop + 0.05) { [self] in
            guard holders.isEmpty, engine.isRunning, ProcessInfo.processInfo.systemUptime - lastPlay >= Self.idleStop else { return }
            engine.pause()
            pausedByIdle = true
        }
    }

    private func samples(cached style: PetalSoundStyle) -> [Float] {
        if let s = samplesCache[style] { return s }
        let s = Self.samples(style)
        samplesCache[style] = s
        return s
    }

    private func buffer(_ style: PetalSoundStyle) -> AVAudioPCMBuffer? {
        if let b = buffers[style] { return b }
        let b = Self.pcmBuffer(samples(cached: style))
        buffers[style] = b
        return b
    }

    private func moveBuffer(_ style: PetalSoundStyle, plan: [Tick]) -> AVAudioPCMBuffer? {
        Self.pcmBuffer(Self.moveSamples(samples(cached: style), plan: plan))
    }

    private static func pcmBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in b.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }
        return b
    }

    // MARK: Self-test hooks

    /// Silences the output and taps every voice, so the live engine can be checked without a sound.
    func startProbe() {
        queue.sync {
            _ = startIfNeeded()
            engine.mainMixerNode.outputVolume = 0
            for v in voices {
                v.speed.removeTap(onBus: 0)
                v.speed.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buf, _ in
                    guard let data = buf.floatChannelData?[0] else { return }
                    var top: Float = 0
                    for i in 0..<Int(buf.frameLength) { top = max(top, abs(data[i])) }
                    self?.queue.async { if let self { self.probePeak = max(self.probePeak, top) } }
                }
            }
        }
    }

    /// Whether the engine runs, how many buffers have been rendered and the loudest sample the voices made since
    /// the last call (which resets it).
    func probe() -> (running: Bool, rendered: Int, peak: Float) {
        queue.sync {
            defer { probePeak = 0 }
            return (engine.isRunning, renderedBuffers, probePeak)
        }
    }

    /// Stops the engine the way an output device change does (not through the idle pause).
    func simulateDeviceChange() { queue.sync { engine.stop(); pausedByIdle = false } }

    // MARK: Synthesis

    /// One damped resonance: frequency (Hz), decay time constant (s), relative amplitude.
    private struct Mode { var f: Double; var decay: Double; var amp: Double }

    /// A contact at time `t0`, scaled by `gain`: a noise burst `burst` seconds long (its own decay), tilted
    /// brighter by `tilt` first differences and softened above `lowpass` Hz (0 = not), ringing `modes`. Both rise
    /// over `rise` seconds (a sine-squared ramp).
    private static func strike(_ out: inout [Double], at t0: Double, gain: Double, rise: Double = 0.0004, burst: Double,
                               noise: Double, tilt: Int = 0, lowpass: Double = 0, highpass: Double = 0, modes: [Mode],
                               seed: inout UInt64) {
        let sr = sampleRate
        let start = Int(t0 * sr)
        let longest = modes.map(\.decay).max() ?? burst
        let length = min(out.count - start, Int((max(longest, burst) * 7) * sr))
        guard length > 0 else { return }
        // White noise in −1…1 from a fixed-seed generator, so every tick is the same.
        func white() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64(1) << 53) * 2 - 1
        }
        var previous = [Double](repeating: 0, count: tilt + 1)
        for k in 0...tilt { previous[k] = k == 0 ? white() : 0 }
        let a = lowpass > 0 ? 1 - exp(-2 * .pi * lowpass / sr) : 1
        let makeUp = lowpass > 0 ? sqrt(1 + 20_000 / lowpass) * 0.5 : 1
        let ah = highpass > 0 ? 1 - exp(-2 * .pi * highpass / sr) : 0
        var smooth = 0.0, highState = 0.0
        for i in 0..<length {
            let t = Double(i) / sr
            var w = white()
            for k in 0..<tilt { let d = (w - previous[k]) * 0.7; previous[k] = w; w = d }
            if highpass > 0 { highState += ah * (w - highState); w -= highState }
            smooth += a * (w - smooth)
            let ramp = rise > 0 && t < rise ? pow(sin(.pi / 2 * t / rise), 2) : 1
            var v = noise * smooth * makeUp * exp(-t / burst) * ramp
            for m in modes {
                v += m.amp * ramp * exp(-t / m.decay) * sin(2 * .pi * m.f * t + m.f * 0.0007)
            }
            out[start + i] += gain * v
        }
    }

    /// A soft body at `t0`: a sine gliding from `f0` to `f1` Hz (time constant `glide`), rising over `rise`
    /// (sine-squared) and decaying with time constant `decay`; rendered for seven time constants.
    private static func thump(_ out: inout [Double], at t0: Double, gain: Double, f0: Double, f1: Double, glide: Double,
                              decay: Double, rise: Double = 0.001) {
        let start = Int(t0 * sampleRate)
        let length = min(out.count - start, Int(decay * 7 * sampleRate))
        guard length > 0 else { return }
        var phase = 0.0
        for i in 0..<length {
            let t = Double(i) / sampleRate
            let f = f1 + (f0 - f1) * exp(-t / glide)
            phase += 2 * .pi * f / sampleRate
            let ramp = rise > 0 && t < rise ? pow(sin(.pi / 2 * t / rise), 2) : 1
            out[start + i] += gain * ramp * exp(-t / decay) * sin(phase)
        }
    }

    /// A tick described as data: contacts and bodies at given times, an optional gentle lowpass over the whole
    /// tick, then the end fade and peak normalisation to `peak × level`. Rendered exactly like the design kit
    /// (softlib.py) that made it, so a sound auditioned there plays identically here.
    struct Recipe {
        enum Call {
            case strike(t0: Double, gain: Double, rise: Double, burst: Double, noise: Double, tilt: Int, lowpass: Double,
                        highpass: Double, modes: [(f: Double, decay: Double, amp: Double)])
            case thump(t0: Double, gain: Double, f0: Double, f1: Double, glide: Double, decay: Double, rise: Double)
        }
        var length: Double
        var level: Double = 1
        var seed: UInt64 = 0x5EED_D1A1
        var calls: [Call]
        var postLowpass: Double = 0
    }

    static func render(_ recipe: Recipe) -> [Float] {
        var seed = recipe.seed
        var out = [Double](repeating: 0, count: Int(recipe.length * sampleRate))
        for call in recipe.calls {
            switch call {
            case let .strike(t0, gain, rise, burst, noise, tilt, lowpass, highpass, modes):
                strike(&out, at: t0, gain: gain, rise: rise, burst: burst, noise: noise, tilt: tilt, lowpass: lowpass,
                       highpass: highpass, modes: modes.map { Mode(f: $0.f, decay: $0.decay, amp: $0.amp) }, seed: &seed)
            case let .thump(t0, gain, f0, f1, glide, decay, rise):
                thump(&out, at: t0, gain: gain, f0: f0, f1: f1, glide: glide, decay: decay, rise: rise)
            }
        }
        if recipe.postLowpass > 0 {
            let a = 1 - exp(-2 * .pi * recipe.postLowpass / sampleRate)
            var y = 0.0
            for i in out.indices { y += a * (out[i] - y); out[i] = y }
        }
        let fade = Int(0.002 * sampleRate)
        for i in 0..<min(fade, out.count) { out[out.count - 1 - i] *= Double(i) / Double(fade) }
        let loudest = out.map(abs).max() ?? 0
        let top: Double = loudest > 0 ? loudest : 1
        let level = Double(peak) * recipe.level
        return out.map { Float($0 / top * level) }
    }

    /// Mono samples of one tick, peak-normalised to `peak` times the style's level (set so all five sound about
    /// equally loud).
    static func samples(_ style: PetalSoundStyle) -> [Float] {
        var seed: UInt64 = 0x5EED_D1A1
        var out: [Double]
        switch style {
        case .dial:
            // One contact of a dial's pulse spring: a soft-edged burst of bright noise ringing three small metal
            // parts, with a faint ring of the body behind it, so fast runs blur into a trill.
            out = [Double](repeating: 0, count: Int(0.075 * sampleRate))
            strike(&out, at: 0, gain: 1, rise: 0.003, burst: 0.004, noise: 1.6, tilt: 1, lowpass: 7_000,
                   modes: [Mode(f: 3_700, decay: 0.012, amp: 0.3), Mode(f: 5_900, decay: 0.007, amp: 0.25),
                           Mode(f: 8_300, decay: 0.004, amp: 0.2), Mode(f: 1_900, decay: 0.03, amp: 0.06)], seed: &seed)
        case .click:
            out = [Double](repeating: 0, count: Int(0.035 * sampleRate))
            strike(&out, at: 0, gain: 1, rise: 0.0008, burst: 0.0008, noise: 1.6, tilt: 1, lowpass: 9_000,
                   modes: [Mode(f: 3_300, decay: 0.005, amp: 0.8), Mode(f: 5_800, decay: 0.0035, amp: 0.5)], seed: &seed)
        case .wood:
            out = [Double](repeating: 0, count: Int(0.07 * sampleRate))
            strike(&out, at: 0, gain: 1, burst: 0.0008, noise: 0.9,
                   modes: [Mode(f: 620, decay: 0.02, amp: 1.0), Mode(f: 1_720, decay: 0.011, amp: 0.5),
                           Mode(f: 3_050, decay: 0.005, amp: 0.25)], seed: &seed)
        case .pop:
            // A small bubble: a short sine whose pitch drops from 1.9 to 0.9 kHz, with a breath of noise at the start.
            out = [Double](repeating: 0, count: Int(0.04 * sampleRate))
            var phase = 0.0
            for i in 0..<out.count {
                let t = Double(i) / sampleRate
                let f = 900 + 1_000 * exp(-t / 0.004)
                phase += 2 * .pi * f / sampleRate
                let env = (t < 0.001 ? t / 0.001 : 1) * exp(-t / 0.008)
                out[i] = env * sin(phase)
            }
            strike(&out, at: 0, gain: 0.2, rise: 0.0005, burst: 0.0005, noise: 1, tilt: 1, modes: [], seed: &seed)
        case .glass:
            out = [Double](repeating: 0, count: Int(0.13 * sampleRate))
            strike(&out, at: 0, gain: 1, burst: 0.0004, noise: 0.6,
                   modes: [Mode(f: 3_150, decay: 0.04, amp: 1.0), Mode(f: 7_420, decay: 0.022, amp: 0.35),
                           Mode(f: 5_190, decay: 0.028, amp: 0.2)], seed: &seed)
        }
        // A 2 ms fade at the end, so no tick ends in a click of its own.
        let fade = Int(0.002 * sampleRate)
        for i in 0..<min(fade, out.count) { out[out.count - 1 - i] *= Double(i) / Double(fade) }
        let top = out.map(abs).max() ?? 1
        let level = Double(peak) * style.level
        return out.map { Float($0 / top * level) }
    }

    /// 16-bit mono PCM WAV of samples (previews and tests).
    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let rate = Int(sampleRate), byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
        samples.forEach { append(Int16((max(-1, min(1, $0)) * 32767).rounded())) }
        return data
    }

    /// A preview of a sweep, mixed offline the way the engine plays it: `moves` are (seconds since the previous
    /// move, petals crossed). Each move's buffer is resampled by its rate (linear interpolation), like the varispeed.
    static func sweep(_ style: PetalSoundStyle, moves: [(interval: Double, steps: Int)]) -> [Float] {
        let one = samples(style)
        var events: [(time: Double, plan: [Tick])] = []
        var t = 0.3
        for move in moves {
            t += move.interval
            events.append((t, plan(steps: move.steps, interval: move.interval)))
        }
        var out = [Float](repeating: 0, count: Int((t + 0.5) * sampleRate))
        for e in events {
            guard let first = e.plan.first else { continue }
            let src = e.plan.count == 1 ? one : moveSamples(one, plan: e.plan)
            let start = Int(e.time * sampleRate)
            var pos = 0.0
            var i = 0
            while Int(pos) + 1 < src.count, start + i < out.count {
                let k = Int(pos), frac = Float(pos - Double(k))
                out[start + i] += (src[k] * (1 - frac) + src[k + 1] * frac) * first.volume
                pos += Double(first.rate)
                i += 1
            }
        }
        return out
    }
}

extension PetalSound.Recipe {
    /// A recipe from the design kit's JSON (softlib.py): {"length", "level", "seed", "post_lowpass", "calls": [
    /// {"fn": "strike", "t0", "gain", "rise", "burst", "noise", "tilt", "lowpass", "highpass", "modes": [[f, decay, amp]]},
    /// {"fn": "thump", "t0", "gain", "f0", "f1", "ftau", "decay", "rise"}]}, with softlib's defaults.
    init?(json data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let length = (root["length"] as? NSNumber)?.doubleValue,
              let list = root["calls"] as? [[String: Any]] else { return nil }
        func num(_ d: [String: Any], _ k: String, _ fallback: Double? = nil) -> Double? { (d[k] as? NSNumber)?.doubleValue ?? fallback }
        var calls: [Call] = []
        for c in list {
            switch c["fn"] as? String {
            case "strike":
                guard let t0 = num(c, "t0"), let gain = num(c, "gain"), let burst = num(c, "burst"), let noise = num(c, "noise")
                else { return nil }
                let modes = (c["modes"] as? [[NSNumber]] ?? []).compactMap { m -> (f: Double, decay: Double, amp: Double)? in
                    m.count == 3 ? (m[0].doubleValue, m[1].doubleValue, m[2].doubleValue) : nil
                }
                calls.append(.strike(t0: t0, gain: gain, rise: num(c, "rise", 0.0004)!, burst: burst, noise: noise,
                                     tilt: Int(num(c, "tilt", 0)!), lowpass: num(c, "lowpass", 0)!,
                                     highpass: num(c, "highpass", 0)!, modes: modes))
            case "thump":
                guard let t0 = num(c, "t0"), let gain = num(c, "gain"), let f0 = num(c, "f0"), let f1 = num(c, "f1"),
                      let glide = num(c, "ftau"), let decay = num(c, "decay") else { return nil }
                calls.append(.thump(t0: t0, gain: gain, f0: f0, f1: f1, glide: glide, decay: decay, rise: num(c, "rise", 0.001)!))
            default:
                return nil
            }
        }
        self.init(length: length, level: num(root, "level", 1)!,
                  seed: (root["seed"] as? NSNumber)?.uint64Value ?? 0x5EED_D1A1, calls: calls,
                  postLowpass: num(root, "post_lowpass", 0)!)
    }
}

