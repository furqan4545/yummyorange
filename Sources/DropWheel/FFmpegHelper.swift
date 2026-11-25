import AppKit
import Network
import SwiftUI
import os

// YummyOrange's own ffmpeg ("ffmpeg for audio and video" in the HUD). Audio and video work runs through an ffmpeg
// program. A Mac that has one (Homebrew's, say) keeps using it. On a Mac without one, YummyOrange downloads its own LGPL
// build from yummyorange.com: quietly about a minute after launch (on a network that isn't metered), or as soon as a task
// needs it (with progress in the HUD, and the task runs once it is there). It lives in
// ~/Library/Application Support/YummyOrange/Helpers/ffmpeg-<version>/, which app updates leave alone, so the app itself
// stays small.
//
//   lookup    the person's own ffmpeg where YummyOrange has always looked (FFmpegLookup.userFolders), then YummyOrange's
//             copy: the pinned version's folder, else the newest other complete ffmpeg-* folder. An ffmpeg of the
//             person's own that doesn't run (Capabilities probes it) is passed over.
//   download  https://yummyorange.com/downloads/helpers/<file> with UpdateTransport (HTTPS only, an ephemeral session, no
//             cookies, the app's User-Agent), never more than the pinned length; Cancel in Settings › About stops it
//   verify    the byte length and SHA-256 pinned in `FFmpegHelper.pinnedBuild`, before anything is unpacked
//   unpack    with ditto (no quarantine), into a staging folder inside Helpers (the same volume as the final folder)
//   check     ffmpeg runs ("-version", 10 s at most) and says it is ffmpeg
//   place     one rename into Helpers/ffmpeg-<version>; the app switches to it, then older ffmpeg-* folders are removed
// Any failure removes the staging folder, so nothing half-installed is left and the next attempt starts over. Automatic
// attempts back off after failures (FFmpegHelperPolicy). The self-test is `--selftest helper` (FFmpegHelperTests.swift).

/// One build of YummyOrange's own ffmpeg as published on yummyorange.com.
struct FFmpegHelperBuild: Equatable {
    /// ffmpeg's version and the helper revision ("9.0.2-2"). The build is kept in Helpers/ffmpeg-<version>.
    var version: String
    /// The ZIP's file name in https://yummyorange.com/downloads/helpers/.
    var fileName: String
    /// The ZIP's exact size in bytes.
    var length: Int
    /// The ZIP's SHA-256: 64 lowercase hexadecimal digits.
    var sha256: String

    var folderName: String { "ffmpeg-\(version)" }

    /// Every field holds a real value (not the placeholder), so the build can be downloaded and checked.
    var isPinned: Bool {
        length > 0 && sha256.count == 64 && sha256.allSatisfy({ "0123456789abcdef".contains($0) })
            && FFmpegLookup.isSafeName(fileName) && fileName.lowercased().hasSuffix(".zip") && !fileName.contains("PLACEHOLDER")
            && FFmpegLookup.isSafeName(version) && !version.contains("PLACEHOLDER")
    }
}

extension FFmpegHelper {
    // ┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
    // │ THE PINNED BUILD: YummyOrange's own ffmpeg, as published at                                                   │
    // │ https://yummyorange.com/downloads/helpers/<fileName> (Website/public/downloads/helpers/ in this repository;   │
    // │ made by Tools/helpers/build-ffmpeg-helper.sh, whose sources and license are at                                │
    // │ https://yummyorange.com/licenses/ffmpeg.html). `length` is the ZIP's size in bytes (`stat -f %z`), `sha256`   │
    // │ its `shasum -a 256` in lowercase, `version` the ffmpeg version plus the helper revision (the install folder   │
    // │ is ffmpeg-<version>, so a new revision of the same ffmpeg replaces the old one). The ZIP holds `ffmpeg`, at   │
    // │ its top or in one folder. A new build gets a new file name: the old one stays on the site for the copies of   │
    // │ YummyOrange that still pin it.                                                                                │
    // └──────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
    static let pinnedBuild = FFmpegHelperBuild(
        version: "9.0.2-2",
        fileName: "YummyOrange-ffmpeg-9.0.2-2-arm64.zip",
        length: 11_489_822,
        sha256: "b8559d118c74ecab50855f92f1f6552af72f3119669a42653e04c7097dd927df")

    /// Where the builds are published.
    static let defaultBaseURL = URL(string: "https://yummyorange.com/downloads/helpers/")!
}

// MARK: - Finding ffmpeg

/// Which ffmpeg YummyOrange uses: the person's own first, then YummyOrange's copy.
enum FFmpegLookup {
    enum Source: Equatable {
        /// Found where YummyOrange has always looked (Homebrew, ~/.local/bin…): the person's own.
        case user
        /// YummyOrange's own copy in Helpers/ffmpeg-<version>.
        case helper(version: String)
    }

    struct Found: Equatable {
        var ffmpeg: URL
        var source: Source
    }

    /// Where YummyOrange has always looked for its command-line tools, in order (also cwebp and img2webp).
    static func userFolders() -> [URL] {
        var dirs: [URL] = []
        if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent("Tools")) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        dirs += [home.appendingPathComponent(".local/bin"),
                 URL(fileURLWithPath: "/opt/homebrew/bin"),
                 URL(fileURLWithPath: "/usr/local/bin"),
                 URL(fileURLWithPath: "/usr/bin")]
        return dirs
    }

    /// ~/Library/Application Support/YummyOrange/Helpers. Reading it is all the lookup does; only the app writes it.
    /// DEBUG only: DW_HELPER_ROOT=/some/folder stands in for it (`--selftest helper-live` installs there, so the real
    /// Application Support is never touched).
    static func defaultRoot(environment env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        #if DEBUG
        if let path = env["DW_HELPER_ROOT"], path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        #endif
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("YummyOrange/Helpers", isDirectory: true)
    }

    /// DEBUG only: DW_HELPER_HIDE_USER_FFMPEG=1 (or the default DWHelperHideUserFFmpeg) ignores the person's own ffmpeg,
    /// so the download can be tried on a Mac that has one.
    static func hidesUserFFmpeg(environment env: [String: String] = ProcessInfo.processInfo.environment,
                                defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
        return env["DW_HELPER_HIDE_USER_FFMPEG"] == "1" || defaults.bool(forKey: "DWHelperHideUserFFmpeg")
        #else
        return false
        #endif
    }

    static func find(userFolders: [URL], hideUser: Bool, helpers root: URL, pinned: String) -> Found? {
        candidates(userFolders: userFolders, hideUser: hideUser, helpers: root, pinned: pinned).first
    }

    /// Every ffmpeg in the order YummyOrange would use them: the person's own (each folder of `userFolders` that has
    /// one), then YummyOrange's copy. Capabilities takes the first that runs.
    static func candidates(userFolders: [URL], hideUser: Bool, helpers root: URL, pinned: String) -> [Found] {
        let fm = FileManager.default
        var found: [Found] = []
        if !hideUser {
            for dir in userFolders {
                let ffmpeg = dir.appendingPathComponent("ffmpeg")
                if fm.isExecutableFile(atPath: ffmpeg.path) { found.append(Found(ffmpeg: ffmpeg, source: .user)) }
            }
        }
        if let ours = helper(in: root, pinned: pinned) { found.append(ours) }
        return found
    }

    /// The candidates on this Mac now.
    static func currentCandidates() -> [Found] {
        candidates(userFolders: userFolders(), hideUser: hidesUserFFmpeg(), helpers: defaultRoot(), pinned: FFmpegHelper.pinnedBuild.version)
    }

    /// YummyOrange's copy: the pinned version when it is installed, else the newest other complete one.
    static func helper(in root: URL, pinned: String) -> Found? {
        let versions = installedVersions(in: root)
        guard let version = versions.contains(pinned) ? pinned : versions.max(by: isOlder) else { return nil }
        let folder = root.appendingPathComponent("ffmpeg-\(version)", isDirectory: true)
        return Found(ffmpeg: folder.appendingPathComponent("ffmpeg"), source: .helper(version: version))
    }

    /// The versions in Helpers whose folder holds a runnable ffmpeg. A folder without one is ignored.
    static func installedVersions(in root: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name in
            guard name.hasPrefix("ffmpeg-") else { return nil }
            let version = String(name.dropFirst("ffmpeg-".count))
            guard isSafeName(version), isComplete(root.appendingPathComponent(name, isDirectory: true)) else { return nil }
            return version
        }
    }

    static func isComplete(_ folder: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: folder.appendingPathComponent("ffmpeg").path)
    }

    /// "1.0" < "9.9" < "10.0", digits compared as numbers.
    static func isOlder(_ a: String, _ b: String) -> Bool { a.compare(b, options: .numeric) == .orderedAscending }

    /// A plain file or folder name: letters, digits, dot, dash and underscore, not starting with a dot, 1 to 64 long.
    static func isSafeName(_ name: String) -> Bool {
        (1...64).contains(name.count) && !name.hasPrefix(".")
            && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
    }
}

// MARK: - Policy and words

enum FFmpegHelperPolicy {
    /// The quiet download starts this long after launch.
    static let launchDelay: TimeInterval = 60
    /// ffmpeg gets this long to answer "-version" before the download counts as broken.
    static let runTimeout: TimeInterval = 10
    /// A staging folder this old belongs to an attempt that never finished (YummyOrange quit during it).
    static let staleStaging: TimeInterval = 3600
    /// The download may take this long in all (an app update gets 15 minutes): 11.5 MB at 4 KB/s. A connection that
    /// stops sending for 30 seconds fails sooner.
    static let downloadTimeout: TimeInterval = 60 * 60

    /// Free space an install needs in Helpers: the ZIP, what it unpacks to (about twice its size) and a damaged copy of
    /// the same version moved aside, with room to spare.
    static func spaceNeeded(forDownload length: Int) -> Int64 { Int64(length) * 6 }

    /// How long automatic attempts wait after `failures` failed attempts in a row: none after none, then 15 minutes,
    /// 1 hour, 4 hours, 16 hours, at most 3 days. A task that needs ffmpeg, or Download in Settings, always tries.
    static func backoff(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(15 * 60 * pow(4, Double(min(failures, 10) - 1)), 3 * 24 * 3600)
    }

    /// Whether an automatic attempt may start now (the clock set back counts as due).
    static func automaticIsDue(failures: Int, lastFailure: Date?, now: Date) -> Bool {
        guard failures > 0, let lastFailure, lastFailure <= now else { return true }
        return now.timeIntervalSince(lastFailure) >= backoff(afterFailures: failures)
    }
}

/// What the HUD and Settings › About say about YummyOrange's own ffmpeg. One name for it everywhere, "ffmpeg" (what
/// About's row is called), said with what it is for, since many people have never heard of it.
enum FFmpegHelperText {
    static let getting = "Downloading ffmpeg for audio and video…"
    /// Only for an error that slipped past the waiting (missingTool("ffmpeg") while the helper can be downloaded).
    static let notYet = "YummyOrange hasn’t downloaded ffmpeg yet. Download it in Settings › About, then try again."

    // Why a download failed, each with what to do about it (FFmpegHelperText.message(for:) picks one).
    static let offline = "Couldn’t download ffmpeg for audio and video. Check your internet connection and try again."
    static let damaged = "Couldn’t download ffmpeg for audio and video from yummyorange.com. Try again later."
    static let noSpace = "There isn’t enough space on this Mac to download ffmpeg for audio and video. Free up some space, then try again."
    static let cannotSave = "YummyOrange couldn’t save ffmpeg in ~/Library/Application Support/YummyOrange. "
        + "Check that you can write to that folder, then try again."
    static let canceled = "The ffmpeg download was canceled."

    /// "Downloading ffmpeg for audio and video…", then "… 42%" once the size is known.
    static func progress(_ fraction: Double?) -> String {
        guard let fraction else { return getting }
        return "\(getting) \(percent(fraction))%"
    }

    /// Whole percent done, rounded down, so 100 means done.
    static func percent(_ fraction: Double) -> Int { Int((min(max(fraction, 0), 1) * 100).rounded(.down)) }

    /// What a failed attempt says: no connection, a full disk, a folder that can't be written, a download that came
    /// back wrong (a server error, a wrong checksum, a damaged ZIP, an ffmpeg that won't run), or Cancel.
    static func message(for error: Error) -> String {
        if let helper = error as? FFmpegHelperError {
            switch helper {
            case .canceled: return canceled
            case .noSpace: return noSpace
            default: break
            }
        }
        if isOutOfSpace(error) { return noSpace }
        if case .network? = error as? UpdateError { return offline }
        if case .cannotInstall? = error as? UpdateError { return cannotSave }
        if case .cannotPlace? = error as? FFmpegHelperError { return cannotSave }
        return damaged
    }

    /// A full disk, in whatever words the step that met it used (FileManager, a write, ditto).
    static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
        let text = error.localizedDescription
        return ["No space left", "out of space", "enough space"].contains { text.localizedCaseInsensitiveContains($0) }
    }
}

enum FFmpegHelperError: LocalizedError, Equatable {
    case notAvailable
    case badArchive(String)
    case doesNotRun(String)
    case cannotPlace(String)
    case noSpace
    case canceled

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "This copy of YummyOrange has no ffmpeg to download."
        case .badArchive(let what): return "The ffmpeg download is damaged: \(what)."
        case .doesNotRun(let name): return "The downloaded \(name) doesn’t run on this Mac."
        case .cannotPlace(let what): return "ffmpeg couldn’t be put in place: \(what)."
        case .noSpace: return FFmpegHelperText.noSpace
        case .canceled: return FFmpegHelperText.canceled
        }
    }
}

// MARK: - The installer

/// Gets YummyOrange's own ffmpeg. Its state lives on the main thread; the work runs on a queue of its own.
final class FFmpegHelper {
    /// The app's. Self-tests make their own instances (and swap this one when they check the wheel).
    static var shared = FFmpegHelper(config: .app())
    /// Posted on the main thread when `phase` changes or a new copy is in place.
    static let didChange = Notification.Name("YummyOrangeFFmpegHelperDidChange")
    static let log = Logger(subsystem: "com.yummyorange.app", category: "ffmpeg-helper")

    struct UI {
        /// A task is waiting: the text and the fraction done (nil until the size is known).
        var progress: (String, Double?) -> Void
        /// Getting it failed while a task waited.
        var failed: (String) -> Void
        /// It arrived while a task waited, just before the task goes on (a job puts its own title up; an editor opens).
        var ready: () -> Void

        /// The HUD, even with Show progress off: the person started a task and would otherwise see nothing happen.
        static let hud = UI(progress: { HUD.shared.progress($0, fraction: $1, always: true) },
                            failed: { HUD.shared.flash($0, isError: true, seconds: 6) },
                            ready: { HUD.shared.hide() })
    }

    struct Config {
        var build: FFmpegHelperBuild
        var baseURL: URL
        /// Helpers: where the ffmpeg-<version> folders go.
        var root: URL
        var userAgent: String
        /// Downloads happen at all: in the app (never from the command line), on Apple silicon.
        var enabled: Bool
        /// Plain HTTP to 127.0.0.1 (a DEBUG base URL or a self-test's server).
        var allowsLoopbackHTTP: Bool
        /// Where failed attempts are counted for the backoff.
        var defaults: () -> UserDefaults
        /// The ffmpeg in use now (nil: none).
        var current: () -> FFmpegLookup.Found?
        /// Bytes free on the volume of a folder (nil: unknown, so not checked).
        var freeSpace: (URL) -> Int64? = FFmpegHelper.freeSpace
        /// On the helper's queue, once a new copy is in place and before any waiting task runs: the app points
        /// Capabilities at it.
        var didInstall: (URL) -> Void
        /// A job may be running an ffmpeg right now (its folder then stays until the next launch).
        var jobsRunning: () -> Bool
        var ui: UI
        /// Calls back on the main thread once a network that isn't metered is reachable (the quiet attempt only).
        var whenOnline: (@escaping () -> Void) -> Void
        var now: () -> Date = Date.init

        static func app(arguments: [String] = CommandLine.arguments,
                        environment env: [String: String] = ProcessInfo.processInfo.environment) -> Config {
            var base = FFmpegHelper.defaultBaseURL
            var loopback = false
            #if DEBUG
            // DW_HELPER_BASE_URL=http://127.0.0.1:8000/ (or the default DWHelperBaseURL): a local server stands in for
            // yummyorange.com/downloads/helpers/ (the pinned length and checksum still apply).
            if let text = env["DW_HELPER_BASE_URL"] ?? UserDefaults.standard.string(forKey: "DWHelperBaseURL"),
               let url = URL(string: text), url.host != nil {
                base = url
                loopback = UpdateTransport.isLoopback(url)
            }
            #endif
            var arm = false
            #if arch(arm64)
            arm = true
            #endif
            let commandLine = arguments.dropFirst().first?.hasPrefix("--") ?? false
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            return Config(build: FFmpegHelper.pinnedBuild, baseURL: base, root: FFmpegLookup.defaultRoot(),
                          userAgent: "YummyOrange/\(version)", enabled: arm && !commandLine, allowsLoopbackHTTP: loopback,
                          defaults: { Settings.defaults }, current: { Capabilities.shared.liveFFmpegFound },
                          didInstall: { _ in Capabilities.shared.refreshFFmpeg() },
                          jobsRunning: { JobRunner.runningCount > 0 }, ui: .hud, whenOnline: FFmpegHelper.whenOnline)
        }
    }

    enum Phase: Equatable {
        case idle
        /// Downloading, with the fraction done once the first bytes are in.
        case downloading(Double?)
        /// Checking, unpacking and putting it in place.
        case installing
        /// The last attempt failed (`failure` says why); the next one starts over.
        case failed
    }

    let config: Config
    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { NotificationCenter.default.post(name: Self.didChange, object: self) } }
    }
    /// Why the last attempt failed, in words for the HUD and About (nil once one succeeds or is canceled).
    private(set) var failure: String?
    /// Downloads started (the self-test counts them).
    private(set) var attempts = 0
    /// The quiet automatic attempt of this launch was made (or is waiting for the network).
    private(set) var triedAutomatically = false
    private struct Waiter {
        let ready: () -> Void
        let otherwise: ((String) -> Void)?
    }
    private var waiters: [Waiter] = []
    private var shownPercent: Int?
    private var cancellation: TransferCancellation?
    private let queue = DispatchQueue(label: "com.yummyorange.app.ffmpeg-helper", qos: .utility)

    init(config: Config) {
        self.config = config
    }

    /// This copy can download its ffmpeg (the app, on Apple silicon, with a pinned build). Cheap: wheels ask it.
    var canFetch: Bool { config.enabled && config.build.isPinned }

    /// Whether a download should happen: no ffmpeg at all, or only an older copy of YummyOrange's own. A newer copy
    /// (put there by a newer YummyOrange) is good enough, so two copies of the app never undo each other's download.
    var isNeeded: Bool {
        guard canFetch else { return false }
        guard let found = config.current() else { return true }
        if case .helper(let version) = found.source { return FFmpegLookup.isOlder(version, config.build.version) }
        return false
    }

    private static let failuresKey = "ffmpegHelperFailures"
    private static let lastFailureKey = "ffmpegHelperLastFailure"

    /// Failed attempts in a row, and when the last one failed (for the backoff of automatic attempts).
    var failures: Int { config.defaults().object(forKey: Self.failuresKey) as? Int ?? 0 }
    var lastFailure: Date? {
        (config.defaults().object(forKey: Self.lastFailureKey) as? Double).map(Date.init(timeIntervalSince1970:))
    }

    // MARK: Asking for it (main thread)

    /// Runs `body` once ffmpeg is here: at once when it is (or when this copy can't download it, so `body` meets the
    /// usual "isn't installed" error), else when YummyOrange's own copy has arrived, with its progress in the HUD
    /// meanwhile. Waiting tasks share one download. When it fails, `otherwise` gets the message; waiters without one
    /// leave it to the HUD.
    func whenAvailable(_ body: @escaping () -> Void, otherwise: ((String) -> Void)? = nil) {
        guard canFetch, config.current() == nil else { body(); return }
        waiters.append(Waiter(ready: body, otherwise: otherwise))
        shownPercent = nil   // shown again: a job that joins has just put its own title in the HUD
        showProgress()
        fetch()
    }

    /// Starts a download unless one is already under way (Settings › About's Download, a waiting task, the quiet
    /// attempt). `automatic`: counts toward this launch's one quiet attempt.
    func fetch(automatic: Bool = false) {
        guard canFetch else { return }
        switch phase {
        case .downloading, .installing: return
        case .idle, .failed: break
        }
        if automatic { triedAutomatically = true }
        attempts += 1
        failure = nil
        phase = .downloading(nil)
        let config = self.config
        let cancellation = TransferCancellation()
        self.cancellation = cancellation
        queue.async { [weak self] in
            let result = Result {
                try Self.install(config, cancellation: cancellation, progress: { fraction in
                    DispatchQueue.main.async { self?.progressed(fraction) }
                }, unpacking: {
                    DispatchQueue.main.async { if self?.phase != .idle { self?.phase = .installing } }
                })
            }
            DispatchQueue.main.async { self?.finished(result) }
        }
    }

    /// Settings › About's Cancel: stops the download under way. The few seconds of checking and unpacking after it
    /// always finish. Tasks waiting for it are told it was canceled; nothing counts toward the backoff.
    func cancel() {
        guard case .downloading = phase else { return }
        cancellation?.cancel()
    }

    #if DEBUG
    /// `--snapshot helper-about`: the row in a given state, without a download.
    func stage(_ phase: Phase, failure: String? = nil) {
        self.failure = failure
        self.phase = phase
    }
    #endif

    private func progressed(_ fraction: Double) {
        guard case .downloading = phase else { return }
        phase = .downloading(fraction)
        showProgress()
    }

    /// The HUD line for waiting tasks, once per whole percent.
    private func showProgress() {
        guard !waiters.isEmpty else { return }
        var fraction: Double?
        switch phase {
        case .downloading(let f): fraction = f
        case .installing: fraction = 1
        case .idle, .failed: fraction = nil
        }
        let percent = fraction.map(FFmpegHelperText.percent) ?? -1
        guard percent != shownPercent else { return }
        shownPercent = percent
        config.ui.progress(FFmpegHelperText.progress(fraction), fraction)
    }

    private func finished(_ result: Result<URL, Error>) {
        let waiting = waiters
        waiters = []
        shownPercent = nil
        cancellation = nil
        let defaults = config.defaults()
        switch result {
        case .success(let folder):
            Self.log.notice("installed ffmpeg in \(folder.path, privacy: .public)")
            defaults.removeObject(forKey: Self.failuresKey)
            defaults.removeObject(forKey: Self.lastFailureKey)
            failure = nil
            phase = .idle   // posts didChange: About shows the new copy (Capabilities already uses it)
            if !waiting.isEmpty { config.ui.ready() }
            waiting.forEach { $0.ready() }
        case .failure(let error):
            let message = FFmpegHelperText.message(for: error)
            if (error as? FFmpegHelperError) == .canceled {
                // The person's choice: not a failure to back off from, and About offers Download again as before.
                Self.log.notice("the ffmpeg download was canceled")
                failure = nil
                phase = .idle
            } else {
                Self.log.error("couldn’t get ffmpeg: \(error.localizedDescription, privacy: .public)")
                defaults.set(failures + 1, forKey: Self.failuresKey)
                defaults.set(config.now().timeIntervalSince1970, forKey: Self.lastFailureKey)
                failure = message
                phase = .failed
            }
            if waiting.contains(where: { $0.otherwise == nil }) { config.ui.failed(message) }
            waiting.forEach { $0.otherwise?(message) }
        }
    }

    // MARK: The quiet attempt (app only)

    /// From the app's launch: tidies Helpers, then about a minute later gets ffmpeg if this Mac has none.
    func start() {
        guard canFetch else { return }
        let config = self.config
        queue.async { Self.tidy(config.root, keeping: config.current(), jobsRunning: false, now: config.now()) }
        DispatchQueue.main.asyncAfter(deadline: .now() + FFmpegHelperPolicy.launchDelay) { [weak self] in self?.attemptAutomatically() }
    }

    /// Once per launch, when a download is needed, automatic attempts aren't backing off, and a network that isn't
    /// metered is reachable (it waits for one, so a Mac that wakes up offline or on a phone's hotspot gets it later).
    func attemptAutomatically() {
        guard !triedAutomatically, isNeeded,
              FFmpegHelperPolicy.automaticIsDue(failures: failures, lastFailure: lastFailure, now: config.now()) else { return }
        triedAutomatically = true
        config.whenOnline { [weak self] in
            guard let self, self.isNeeded else { return }
            self.fetch(automatic: true)
        }
    }

    /// Calls `then` on the main thread the first time a network is reachable that isn't metered: not Low Data Mode
    /// (`isConstrained`) and not a personal hotspot or other link macOS counts as expensive. A download someone asks for
    /// (a task, About's Download) doesn't wait for this.
    static func whenOnline(_ then: @escaping () -> Void) {
        let monitor = NWPathMonitor()
        var fired = false
        monitor.pathUpdateHandler = { path in
            guard isUnmetered(satisfied: path.status == .satisfied, constrained: path.isConstrained, expensive: path.isExpensive),
                  !fired else { return }
            fired = true
            monitor.cancel()
            monitor.pathUpdateHandler = nil
            DispatchQueue.main.async(execute: then)
        }
        monitor.start(queue: DispatchQueue(label: "com.yummyorange.app.ffmpeg-helper.network", qos: .utility))
    }

    /// A network the quiet download may use: up, not in Low Data Mode, not counted as expensive.
    static func isUnmetered(satisfied: Bool, constrained: Bool, expensive: Bool) -> Bool { satisfied && !constrained && !expensive }

    // MARK: Tasks and wheels

    /// An error the helper would cure: a missing ffmpeg (or cwebp, which its libwebp stands in for) on a Mac without
    /// ffmpeg, in a copy that can download it. Any thread.
    static func canProvide(_ error: Error) -> Bool {
        guard let conversion = error as? ConversionError, case .missingTool(let tool) = conversion,
              tool == "ffmpeg" || tool == "cwebp" else { return false }
        let helper = shared
        return helper.canFetch && helper.config.current() == nil
    }

    /// A petal that opens a window or asks for options on audio or video needs ffmpeg before it does either (an editor
    /// reads the file with it, Visualize lists its filters). Petals that just run go to JobRunner, which waits by itself
    /// when the run meets a missing ffmpeg. Actions (Zip, Float…) never need it.
    static func mustWaitBefore(_ command: WheelCommand, files: [URL]) -> Bool {
        guard command.wheel != .actions, command.present != nil || command.ask != nil,
              files.contains(where: { [.video, .audio].contains(MoreFormats.kind($0)) }) else { return false }
        let helper = shared
        return helper.canFetch && helper.config.current() == nil
    }

    /// Encoders YummyOrange's build has besides ffmpeg's own: lame, libwebp, libvpx's VP9 (not VP8), Opus and Vorbis
    /// (plus Apple's AudioToolbox and VideoToolbox encoders, which every macOS build has). It has none of the GPL or
    /// non-free ones.
    static let externalEncoders: Set<String> = ["libmp3lame", "libwebp", "libwebp_anim", "libvpx-vp9", "libopus", "libvorbis"]

    /// Whether YummyOrange's build has `encoder`, for offering petals before it is downloaded.
    static func buildIncludes(encoder: String) -> Bool {
        !encoder.hasPrefix("lib") || externalEncoders.contains(encoder)
    }

    // MARK: The steps (blocking: the helper's queue, or a self-test)

    /// Downloads, verifies, unpacks, checks and places `config.build`, has the app use it, then removes older copies.
    /// Returns the new folder. Nothing is left in Helpers when it throws but what was there before.
    static func install(_ config: Config, cancellation: TransferCancellation? = nil, progress: @escaping (Double) -> Void = { _ in },
                        unpacking: @escaping () -> Void = {}) throws -> URL {
        let build = config.build
        guard config.enabled, build.isPinned else { throw FFmpegHelperError.notAvailable }
        let fm = FileManager.default
        do { try fm.createDirectory(at: config.root, withIntermediateDirectories: true) } catch {
            if FFmpegHelperText.isOutOfSpace(error) { throw FFmpegHelperError.noSpace }
            throw FFmpegHelperError.cannotPlace(error.localizedDescription)
        }
        // A full disk is said as such before a byte is fetched, not as a failed write halfway through.
        if let free = config.freeSpace(config.root), free < FFmpegHelperPolicy.spaceNeeded(forDownload: build.length) {
            throw FFmpegHelperError.noSpace
        }
        let staging = config.root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: staging, withIntermediateDirectories: false) } catch {
            if FFmpegHelperText.isOutOfSpace(error) { throw FFmpegHelperError.noSpace }
            throw FFmpegHelperError.cannotPlace(error.localizedDescription)
        }
        defer { try? fm.removeItem(at: staging) }

        let url = config.baseURL.appendingPathComponent(build.fileName)
        let zip = staging.appendingPathComponent(build.fileName)
        do {
            try UpdateTransport.download(url, to: zip, length: build.length,
                                         loopbackHTTP: config.allowsLoopbackHTTP && UpdateTransport.isLoopback(url),
                                         userAgent: config.userAgent, resourceTimeout: FFmpegHelperPolicy.downloadTimeout,
                                         cancellation: cancellation, progress: progress)
        } catch {
            if cancellation?.isCancelled == true { throw FFmpegHelperError.canceled }
            throw error
        }
        if cancellation?.isCancelled == true { throw FFmpegHelperError.canceled }
        // Both checks before ditto sees a byte of it.
        try UpdateArchiveCheck.checkLength(of: zip, expected: build.length)
        try UpdateArchiveCheck.checkChecksum(of: zip, expected: build.sha256)
        unpacking()

        // --noqtn: the files must never carry quarantine (macOS stops a quarantined program that isn't notarized);
        // the checksum above already vouches for them.
        let expanded = staging.appendingPathComponent("expanded", isDirectory: true)
        let ditto: ProcessResult
        do {
            ditto = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", "--noqtn", zip.path, expanded.path])
        } catch {
            throw FFmpegHelperError.badArchive("ditto couldn’t run (\(error.localizedDescription))")
        }
        guard ditto.status == 0 else {
            let said = ditto.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if said.localizedCaseInsensitiveContains("No space left") { throw FFmpegHelperError.noSpace }
            throw FFmpegHelperError.badArchive(said.isEmpty ? "ditto couldn’t unpack it" : said)
        }
        try? fm.removeItem(at: zip)
        let program = try programFolder(in: expanded)
        let version = try checkProgram(in: program)

        let final = config.root.appendingPathComponent(build.folderName, isDirectory: true)
        let previous = config.current()
        try place(program, at: final, aside: staging.appendingPathComponent("previous", isDirectory: true))
        AboutInfo.remember(ffmpegVersionOutput: version, path: final.appendingPathComponent("ffmpeg").path)
        // The app switches to the new copy first, so no job starts on an old one that tidy is about to remove.
        config.didInstall(final)
        tidy(config.root, keeping: FFmpegLookup.Found(ffmpeg: final.appendingPathComponent("ffmpeg"), source: .helper(version: build.version)),
             inUse: previous, jobsRunning: config.jobsRunning(), now: config.now())
        return final
    }

    /// Bytes free for important files (what macOS would make room for) on the volume of `folder`.
    static func freeSpace(_ folder: URL) -> Int64? {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// The folder holding ffmpeg: the ZIP's top, or the one folder at its top.
    static func programFolder(in expanded: URL) throws -> URL {
        if hasProgram(expanded) { return expanded }
        let fm = FileManager.default
        let entries = ((try? fm.contentsOfDirectory(atPath: expanded.path)) ?? []).filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
        if entries.count == 1 {
            let inner = expanded.appendingPathComponent(entries[0], isDirectory: true)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: inner.path, isDirectory: &isDirectory), isDirectory.boolValue,
               (try? fm.destinationOfSymbolicLink(atPath: inner.path)) == nil, hasProgram(inner) {
                return inner
            }
        }
        throw FFmpegHelperError.badArchive("it holds no ffmpeg")
    }

    /// ffmpeg is a plain file (not a link that could point anywhere).
    private static func hasProgram(_ folder: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("ffmpeg").path)
        return attributes?[.type] as? FileAttributeType == .typeRegular
    }

    /// Makes ffmpeg executable and runs it with "-version". Returns its answer (for About).
    static func checkProgram(in folder: URL, timeout: TimeInterval = FFmpegHelperPolicy.runTimeout) throws -> String {
        let tool = folder.appendingPathComponent("ffmpeg")
        do { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path) } catch {
            throw FFmpegHelperError.badArchive("ffmpeg can’t be made runnable")
        }
        guard let answer = run(tool, ["-version"], timeout: timeout), answer.status == 0,
              answer.output.hasPrefix("ffmpeg version") else { throw FFmpegHelperError.doesNotRun("ffmpeg") }
        return answer.output
    }

    /// Runs a program for at most `timeout` seconds; nil when it couldn't start or took longer (it is then stopped).
    /// Its output goes to a file, not a pipe: a child process that kept a pipe open would hold the wait past the timeout.
    static func run(_ tool: URL, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String)? {
        let fm = FileManager.default
        let outputFile = fm.temporaryDirectory.appendingPathComponent("yummyorange-helper-\(UUID().uuidString).txt")
        guard fm.createFile(atPath: outputFile.path, contents: nil), let output = try? FileHandle(forWritingTo: outputFile) else { return nil }
        defer {
            try? output.close()
            try? fm.removeItem(at: outputFile)
        }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = output
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
            return nil
        }
        guard let reader = try? FileHandle(forReadingFrom: outputFile) else { return (process.terminationStatus, "") }
        defer { try? reader.close() }
        let data = reader.readData(ofLength: 1 << 20)
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Renames the checked folder to `final` in one step (both are in Helpers, on one volume). Whatever is already
    /// there (a damaged copy, one another YummyOrange put there meanwhile, a link, even one to nothing) is moved aside
    /// first and put back on failure.
    static func place(_ folder: URL, at final: URL, aside: URL) throws {
        let fm = FileManager.default
        var movedAside = false
        // attributesOfItem doesn't follow links: a dangling one counts as something in the way, as it is.
        if (try? fm.attributesOfItem(atPath: final.path)) != nil {
            do { try fm.moveItem(at: final, to: aside); movedAside = true } catch {
                throw FFmpegHelperError.cannotPlace(error.localizedDescription)
            }
        }
        do {
            try fm.moveItem(at: folder, to: final)
        } catch {
            if movedAside { try? fm.moveItem(at: aside, to: final) }
            throw FFmpegHelperError.cannotPlace(error.localizedDescription)
        }
        if movedAside { try? fm.removeItem(at: aside) }
    }

    /// Removes staging folders left by attempts that never finished (whatever ffmpeg is in use, or none). With
    /// YummyOrange's own copy kept, also the ffmpeg-* folders older than it and broken ones; a newer one stays (a newer
    /// YummyOrange put it there and uses it). The folder of the ffmpeg in use stays while a job may be running it (the
    /// next launch removes it).
    static func tidy(_ root: URL, keeping: FFmpegLookup.Found?, inUse: FFmpegLookup.Found? = nil, jobsRunning: Bool, now: Date) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name.hasPrefix(".staging-") {
            let url = root.appendingPathComponent(name, isDirectory: true)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > FFmpegHelperPolicy.staleStaging { try? fm.removeItem(at: url) }
        }
        guard let keeping, case .helper(let kept) = keeping.source else { return }
        let keep = keeping.ffmpeg.deletingLastPathComponent().standardizedFileURL.path
        let busy = jobsRunning ? inUse.map { $0.ffmpeg.deletingLastPathComponent().standardizedFileURL.path } : nil
        for name in names where name.hasPrefix("ffmpeg-") {
            let url = root.appendingPathComponent(name, isDirectory: true)
            let path = url.standardizedFileURL.path
            guard path != keep, path != busy else { continue }
            let version = String(name.dropFirst("ffmpeg-".count))
            let broken = !FFmpegLookup.isSafeName(version) || !FFmpegLookup.isComplete(url)
            if broken || FFmpegLookup.isOlder(version, kept) { try? fm.removeItem(at: url) }
        }
    }
}

/// Stops a transfer from another thread (Settings › About's Cancel for YummyOrange's own ffmpeg).
final class TransferCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionTask?

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    /// The transfer to stop; false when it was canceled before it started (it is then not to be started).
    func attach(_ task: URLSessionTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.task = task
        return !cancelled
    }
}

// MARK: - Module

/// No petals: the launch hook schedules the quiet download; `--selftest helper`.
enum FFmpegHelperModule: FeatureModule {
    static var commands: [WheelCommand] { [] }

    static func appDidLaunch() { FFmpegHelper.shared.start() }

    static func selfTest(_ name: String) -> String? {
        #if DEBUG
        if name == "helper" { return FFmpegHelperTests.run() }
        // Not in test.sh: it needs the site served locally (FFmpegHelperLiveTest.swift says how).
        if name == "helper-live" { return FFmpegHelperLiveTest.run() }
        #endif
        return nil
    }

    /// DEBUG: `--snapshot helper-about --opt state=user|ours|missing|downloading|installing|failed|unavailable
    /// [--opt reason=offline|damaged|space|folder] [--opt dark=1] [--opt window=0]`:
    /// Settings › About with the ffmpeg row in that state (staged in memory; nothing is downloaded or written).
    static func snapshot(_ id: String, files: [URL], options: ToolOptions) -> NSView? {
        #if DEBUG
        guard id == "helper-about" else { return nil }
        AppShell.useSnapshotSettings(options)
        FFmpegHelperTests.stage(options.string("state", "missing"), fraction: options.double("fraction", 0.42),
                                reason: options.string("reason", "offline"))
        if options.bool("window", true) { return SettingsWindowController.snapshotView(section: .about, dark: options.bool("dark", false)) }
        // window=0: the pane alone, laid out by SwiftUI (as `--snapshot settings --opt section=about` draws it).
        let host = NSHostingView(rootView: SettingsSectionView(section: .about, snapshot: true))
        host.setFrameSize(host.fittingSize)
        let container = AppShellSnapshotBackground(color: .windowBackgroundColor)
        container.addSubview(host)
        container.setFrameSize(host.fittingSize)
        return container
        #else
        return nil
        #endif
    }
}
