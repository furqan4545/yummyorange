import AppKit

/// A modifier key that can open a wheel, or Off.
enum WheelKey: String, CaseIterable, Identifiable {
    case shift, control, option, command, off

    var id: String { rawValue }

    /// The modifier flag this key sets, nil for Off.
    var flag: NSEvent.ModifierFlags? {
        switch self {
        case .shift: return .shift
        case .control: return .control
        case .option: return .option
        case .command: return .command
        case .off: return nil
        }
    }

    /// "⇧", or "" for Off.
    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .control: return "⌃"
        case .option: return "⌥"
        case .command: return "⌘"
        case .off: return ""
        }
    }

    var name: String {
        switch self {
        case .shift: return "Shift"
        case .control: return "Control"
        case .option: return "Option"
        case .command: return "Command"
        case .off: return "Off"
        }
    }

    /// Short label for a segmented control: the symbol, or "Off".
    var shortTitle: String { self == .off ? "Off" : symbol }
}

/// Which key opens each wheel. One key never opens two wheels; Off can be used by any number of them.
struct WheelKeyMap: Equatable {
    private(set) var convert: WheelKey
    private(set) var tools: WheelKey
    private(set) var actions: WheelKey
    /// Whether ⌃ may stand in for the ⌥ wheel (`controlStandsInFor`). False only for a key map saved before 1.0.1,
    /// when ⌃ was the Actions key: a map saved then without ⌃ was made on purpose (to keep ⌃ for ⌃← and ⌃→ during a
    /// drag, say), so ⌃ keeps opening nothing for that person. Not shown anywhere, so not part of `==`.
    private(set) var controlStandIn: Bool

    /// ⇧ Convert, ⌘ Tools, ⌥ Actions. Until 1.0.1 Actions was ⌃, but macOS reads a ⌃-press as a right-click, so it
    /// could only be tapped mid-drag; ⌥ can also be held before dragging. Only the default changed: a map someone
    /// saved keeps its keys (`Settings.wheelKeys` stores all three together), and ⌃ still opens the ⌥ wheel when no
    /// wheel uses ⌃ (`controlStandsInFor`), so a ⌃ habit keeps working.
    static let defaults = WheelKeyMap(convert: .shift, tools: .command, actions: .option)

    init(convert: WheelKey, tools: WheelKey, actions: WheelKey, controlStandIn: Bool = true) {
        self.convert = convert
        self.tools = tools
        self.actions = actions
        self.controlStandIn = controlStandIn
        repairDuplicates()
    }

    /// Two maps are equal when their keys are, which is all Settings shows (Restore Defaults compares with this).
    static func == (a: WheelKeyMap, b: WheelKeyMap) -> Bool {
        a.convert == b.convert && a.tools == b.tools && a.actions == b.actions
    }

    func key(for mode: WheelMode) -> WheelKey {
        switch mode {
        case .convert: return convert
        case .tools: return tools
        case .actions: return actions
        }
    }

    /// Gives `mode` the key. A wheel that already used that key takes `mode`'s previous key, so the two swap.
    mutating func assign(_ key: WheelKey, to mode: WheelMode) {
        let previous = self.key(for: mode)
        guard previous != key else { return }
        if key != .off, let other = WheelMode.allCases.first(where: { $0 != mode && self.key(for: $0) == key }) {
            set(previous, for: other)
        }
        set(key, for: mode)
    }

    /// The wheel a key pressed during a drag opens: the one whose key is among the newly pressed flags, checked in
    /// wheel order; nil when none. Two keys stand in for each other while only one of them is in use:
    ///   - ⌥ also opens the wheel that uses ⌃ while no wheel uses ⌥: holding ⌃ as the mouse goes down is a
    ///     right-click in macOS, so a ⌃ wheel can only be reached by tapping ⌃ mid-drag, whereas ⌥ can be held
    ///     before dragging.
    ///   - ⌃ also opens the wheel that uses ⌥ while no wheel uses ⌃ (with the default keys, ⌃ opens Actions as it
    ///     did before 1.0.1), except in a map saved before 1.0.1 (`controlStandIn`).
    func mode(newlyPressed flags: NSEvent.ModifierFlags) -> WheelMode? {
        if let mode = ownWheel(flags) { return mode }
        if flags.contains(.option), let mode = optionStandsInFor { return mode }
        if flags.contains(.control), let mode = controlStandsInFor { return mode }
        return nil
    }

    /// The wheel the keys already held as the mouse goes down arm (hold ⌥, then drag). Like `mode(newlyPressed:)`,
    /// except that ⌃ never stands in here: a ⌃-press is a right-click, and with no wheel on ⌃ it stays a plain one
    /// (no wheel armed, no Hold the key first hint after a ⌃-click in Finder).
    func mode(heldAtPress flags: NSEvent.ModifierFlags) -> WheelMode? {
        if let mode = ownWheel(flags) { return mode }
        return flags.contains(.option) ? optionStandsInFor : nil
    }

    /// The first wheel, in wheel order, whose own key is among `flags`.
    private func ownWheel(_ flags: NSEvent.ModifierFlags) -> WheelMode? {
        WheelMode.allCases.first { key(for: $0).flag.map(flags.contains) ?? false }
    }

    /// The wheel ⌥ opens on behalf of ⌃, if any: some wheel uses ⌃ and none uses ⌥.
    var optionStandsInFor: WheelMode? {
        guard !WheelMode.allCases.contains(where: { key(for: $0) == .option }) else { return nil }
        return WheelMode.allCases.first { key(for: $0) == .control }
    }

    /// The wheel ⌃ opens on behalf of ⌥, if any: some wheel uses ⌥ and none uses ⌃ (Actions, with the default keys),
    /// unless the map was saved before 1.0.1 (`controlStandIn`).
    var controlStandsInFor: WheelMode? {
        guard controlStandIn, !WheelMode.allCases.contains(where: { key(for: $0) == .control }) else { return nil }
        return WheelMode.allCases.first { key(for: $0) == .option }
    }

    /// True when every wheel is Off.
    var allOff: Bool { WheelMode.allCases.allSatisfy { key(for: $0) == .off } }

    /// "⇧ Convert · ⌘ Tools · ⌥ Actions", skipping wheels that are off.
    var hint: String {
        WheelMode.allCases.filter { key(for: $0) != .off }
            .map { "\(key(for: $0).symbol) \($0.rawValue)" }
            .joined(separator: " · ")
    }

    /// The keys that open a wheel when held before the press (`mode(heldAtPress:)`), as a sentence says them: each
    /// wheel's own key in wheel order, then ⌥ when it stands in for ⌃. "⇧, ⌘ or ⌥" with the defaults, "⇧, ⌘, ⌃ or ⌥"
    /// with Actions on ⌃, "⇧ or ⌘", "⇧"; nil when every wheel is off. ⌃ standing in for ⌥ isn't listed: it works
    /// only as a tap mid-drag.
    var heldKeyList: String? {
        var keys = WheelMode.allCases.map { key(for: $0) }.filter { $0 != .off }
        if optionStandsInFor != nil { keys.append(.option) }
        let symbols = keys.map(\.symbol)
        guard let last = symbols.last else { return nil }
        return symbols.count == 1 ? last : symbols.dropLast().joined(separator: ", ") + " or " + last
    }

    private mutating func set(_ key: WheelKey, for mode: WheelMode) {
        switch mode {
        case .convert: convert = key
        case .tools: tools = key
        case .actions: actions = key
        }
    }

    /// Values read from defaults may have been edited by hand; a later wheel that repeats a key is turned off.
    private mutating func repairDuplicates() {
        var used = Set<WheelKey>()
        for mode in WheelMode.allCases {
            let k = key(for: mode)
            if k == .off { continue }
            if used.contains(k) { set(.off, for: mode) } else { used.insert(k) }
        }
    }
}

/// How the wheel is drawn.
enum WheelStyle: String, CaseIterable, Identifiable {
    case glass, metallic
    var id: String { rawValue }
    var title: String { self == .glass ? "Glass" : "Metallic" }
}

/// User preferences, persisted in UserDefaults. Setters post `Settings.didChange` when a value changes.
enum Settings {
    /// Where settings live. Self-tests swap in a throwaway suite so they never touch real preferences.
    static var defaults: UserDefaults = .standard
    static let didChange = Notification.Name("DropWheelSettingsDidChange")

    private enum Key {
        static let results = "resultsDestination"
        /// The on/off "Reveal results in Finder" that `results` replaced. Read only to migrate it.
        static let legacyReveal = "revealResults"
        static let hud = "showProgressHUD"
        static let style = "wheelStyle"
        static let sounds = "petalSounds"
        static let soundStyle = "petalSound"
        static let haptics = "haptics"
        static let holdKey = "holdKeyFirst"
        static let screenshots = "hangScreenshots"
        static let welcomeCard = "clotheslineWelcomeRemoved"
        static let autoUpdate = "checkForUpdatesAutomatically"
        static func wheel(_ mode: WheelMode) -> String { "wheelKey.\(mode.rawValue.lowercased())" }
        /// `WheelKeyMap.controlStandIn`, saved with the keys since 1.0.1. A map saved before has keys but no value here.
        static let controlStandIn = "wheelKey.controlStandIn"
    }

    /// Where a finished job's new files appear (Show New Files): a new shelf, the Clothesline, Finder, or nowhere but
    /// the HUD.
    /// Before this choice there was an on/off "Reveal results in Finder": someone who had turned it off still sees
    /// nothing; everyone else (on, or never touched) gets the shelf. The old value is only read, never written.
    static var resultsDestination: ResultsDestination {
        get {
            if let saved = defaults.string(forKey: Key.results).flatMap(ResultsDestination.init(rawValue:)) { return saved }
            return defaults.object(forKey: Key.legacyReveal) as? Bool == false ? .none : .shelf
        }
        set { store(newValue.rawValue, Key.results) }
    }

    /// A screenshot copied to the clipboard hangs on the Clothesline too (only while new files go there; Settings ›
    /// General › Hang copied screenshots, under Show new files, and the menu's Hang Copied Screenshots).
    static var hangScreenshots: Bool {
        get { bool(Key.screenshots, true) }
        set { store(newValue, Key.screenshots) }
    }

    /// The person took the Clothesline's welcome card off the line: an empty line no longer gets it (ClotheslineWelcome).
    static var clotheslineWelcomeRemoved: Bool {
        get { bool(Key.welcomeCard, false) }
        set { store(newValue, Key.welcomeCard) }
    }

    /// Look for a new version at launch, every hour and on wake (Settings › General). Check for Updates… in the
    /// menu works either way.
    static var checkForUpdatesAutomatically: Bool {
        get { bool(Key.autoUpdate, true) }
        set { store(newValue, Key.autoUpdate) }
    }

    /// Show the progress panel and success messages. Errors are always shown.
    static var showProgressHUD: Bool {
        get { bool(Key.hud, true) }
        set { store(newValue, Key.hud) }
    }

    static var wheelStyle: WheelStyle {
        get { defaults.string(forKey: Key.style).flatMap(WheelStyle.init(rawValue:)) ?? .glass }
        set { store(newValue.rawValue, Key.style) }
    }

    /// A soft tick when the highlighted petal changes.
    static var petalSounds: Bool {
        get { bool(Key.sounds, true) }
        set { store(newValue, Key.sounds) }
    }

    /// Which tick plays (Settings › Look › Sound).
    static var petalSoundStyle: PetalSoundStyle {
        get { defaults.string(forKey: Key.soundStyle).flatMap(PetalSoundStyle.init(rawValue:)) ?? .pop }
        set { store(newValue.rawValue, Key.soundStyle) }
    }

    /// A haptic tap on Force Touch trackpads when the highlighted petal changes.
    static var haptics: Bool {
        get { bool(Key.haptics, false) }
        set { store(newValue, Key.haptics) }
    }

    /// Hold a wheel key before pressing on a file in Finder, even a selected one (needs Accessibility).
    static var holdKeyFirst: Bool {
        get { bool(Key.holdKey, true) }
        set { store(newValue, Key.holdKey) }
    }

    /// The keys, all three saved together on the first change (only the default changes between versions). Whether
    /// ⌃ stands in for the ⌥ wheel is saved with them: nothing saved yet means it does (a ⌃ habit from before 1.0.1
    /// keeps working, and keeps working after a later change); keys saved before 1.0.1, which have no such value,
    /// mean it doesn't (with ⌃ then the Actions key, a map without ⌃ was made on purpose). Reading writes nothing.
    static var wheelKeys: WheelKeyMap {
        get {
            func read(_ mode: WheelMode) -> WheelKey {
                defaults.string(forKey: Key.wheel(mode)).flatMap(WheelKey.init(rawValue:))
                    ?? WheelKeyMap.defaults.key(for: mode)
            }
            let standIn = defaults.object(forKey: Key.controlStandIn) as? Bool
                ?? !WheelMode.allCases.contains { defaults.object(forKey: Key.wheel($0)) != nil }
            return WheelKeyMap(convert: read(.convert), tools: read(.tools), actions: read(.actions), controlStandIn: standIn)
        }
        set {
            var changed = false
            for mode in WheelMode.allCases {
                let value = newValue.key(for: mode).rawValue
                if defaults.string(forKey: Key.wheel(mode)) != value {
                    defaults.set(value, forKey: Key.wheel(mode))
                    changed = true
                }
            }
            if defaults.object(forKey: Key.controlStandIn) as? Bool != newValue.controlStandIn {
                defaults.set(newValue.controlStandIn, forKey: Key.controlStandIn)
                changed = true
            }
            if changed { notify() }
        }
    }

    /// Assigns a key to one wheel, swapping with any wheel that already used it.
    static func setKey(_ key: WheelKey, for mode: WheelMode) {
        var map = wheelKeys
        map.assign(key, to: mode)
        wheelKeys = map
    }

    /// The default keys, ⌃ standing in for ⌥ again (also for a map saved before 1.0.1).
    static func resetWheelKeys() { wheelKeys = .defaults }

    // MARK: Storage

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    private static func store(_ value: Bool, _ key: String) {
        guard defaults.object(forKey: key) as? Bool != value else { return }
        defaults.set(value, forKey: key)
        notify()
    }

    private static func store(_ value: String, _ key: String) {
        guard defaults.string(forKey: key) != value else { return }
        defaults.set(value, forKey: key)
        notify()
    }

    private static func notify() {
        let post = { NotificationCenter.default.post(name: didChange, object: nil) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }
}

/// Preferences kept only in memory: self-tests and snapshots use it so they never read or write
/// the real preference files.
final class SettingsMemoryStore: UserDefaults {
    private var values: [String: Any]

    init(_ values: [String: Any] = [:]) {
        self.values = values
        super.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}

#if DEBUG
/// Preferences for a self-test that needs a UserDefaults of its own (Settings' tests swap in SettingsMemoryStore the
/// same way): in memory, never a real suite. A suite made with
/// `UserDefaults(suiteName:)` leaves ~/Library/Preferences/<suite>.plist behind even after `removePersistentDomain`
/// and deleting the file: cfprefsd writes the emptied domain out a moment later, after the delete (measured: the
/// file came back seconds after the self-test had removed it). 130-odd YummyOrange.selftest.<UUID>.plist and
/// DropWheel.selftest.<UUID>.plist files had piled up that way.
enum SelfTestDefaults {
    /// Fresh, empty preferences kept only in memory (optionally seeded).
    static func scratch(_ values: [String: Any] = [:]) -> UserDefaults { SettingsMemoryStore(values) }

    /// Whether `defaults` stays off disk, as every self-test's preferences must.
    static func isScratch(_ defaults: UserDefaults) -> Bool { defaults is SettingsMemoryStore }
}
#endif
