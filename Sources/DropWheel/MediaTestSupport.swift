#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit

/// Helpers for media self-tests (Trim's, and the tools built on the kit): the fixture folder, a scratch copy of
/// fixtures, a checker whose report starts with PASS or FAIL, an editor window that is never shown, and synthesized
/// key and mouse events.
enum MediaTestSupport {
    /// Collects results; `report` starts with "PASS <suite>" or "FAIL <suite>", which test.sh reads.
    final class Checker {
        let suite: String
        private(set) var lines: [String] = []
        private(set) var failures = 0

        init(_ suite: String) { self.suite = suite }

        func check(_ ok: Bool, _ what: String) {
            lines.append((ok ? "  ok    " : "  FAIL  ") + what)
            if !ok { failures += 1 }
        }

        /// `body` must throw an error whose message contains `text`.
        func throwsError(_ what: String, containing text: String, _ body: () throws -> Void) {
            do {
                try body()
                check(false, "\(what): no error")
            } catch {
                check(error.localizedDescription.contains(text), "\(what): “\(error.localizedDescription)”")
            }
        }

        var report: String {
            let head = failures == 0 ? "PASS \(suite): \(lines.count) checks" : "FAIL \(suite): \(failures) of \(lines.count) checks failed"
            return ([head] + lines).joined(separator: "\n")
        }
    }

    /// Tests/fixtures/features: from $DW_FIXTURES, the current folder, or a folder above the binary
    /// (.build/debug/DropWheel sits three or four levels below the project).
    static func fixturesFolder() -> URL? {
        let fm = FileManager.default
        func ok(_ url: URL) -> Bool { fm.fileExists(atPath: url.appendingPathComponent("clip.mp4").path) }
        if let env = ProcessInfo.processInfo.environment["DW_FIXTURES"], ok(URL(fileURLWithPath: env)) { return URL(fileURLWithPath: env) }
        var candidates = [URL(fileURLWithPath: fm.currentDirectoryPath)]
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 { candidates.append(dir); dir = dir.deletingLastPathComponent() }
        for base in candidates {
            let url = base.appendingPathComponent("Tests/fixtures/features")
            if ok(url) { return url }
        }
        return nil
    }

    /// A fresh scratch folder holding copies of the named fixtures (so outputs never land next to the originals).
    static func scratchCopy(of names: [String], from fixtures: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-media-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: dir.appendingPathComponent(name))
        }
        return dir
    }

    /// An editor built as for a snapshot (no player, never on screen), laid out at `size`, with its strip and
    /// waveform loaded when `loadLanes` is set.
    static func editor<T: MediaEditorWindowController>(_ type: T.Type, url: URL, size: CGSize = CGSize(width: 1000, height: 660),
                                                       loadLanes: Bool = false) throws -> T {
        let controller = type.init(source: try MediaSource.load(url), snapshot: true)
        controller.window.setContentSize(size)
        if loadLanes {
            controller.timeline.strip = MediaKit.filmStrip(controller.source)
            controller.timeline.peaks = MediaKit.peaks(controller.source)
        }
        controller.content.layoutSubtreeIfNeeded()
        return controller
    }

    static func key(_ characters: String, keyCode: UInt16 = 0, flags: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    /// Key codes for `key`.
    enum Code {
        static let space: UInt16 = 49, left: UInt16 = 123, right: UInt16 = 124, home: UInt16 = 115, end: UInt16 = 119
        static let escape: UInt16 = 53, delete: UInt16 = 51, i: UInt16 = 34, o: UInt16 = 31, z: UInt16 = 6
    }

    /// A mouse event at `point` in `view`'s coordinates.
    static func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// The toolbar's layout, leading to trailing, as identifiers ("flex", "space", or the item's own), and whether
    /// the tool's items (`tools`) are the centred ones: the conventions put a tool's controls in the centre, as the
    /// image and Edit PDF editors do, with Undo, Redo and Save on the trailing edge.
    static func toolbarLayout(_ window: NSWindow, tools: [String]) -> (items: [String], centred: Bool) {
        guard let toolbar = window.toolbar else { return ([], false) }
        let items = toolbar.items.map { item -> String in
            switch item.itemIdentifier {
            case .flexibleSpace: return "flex"
            case .space: return "space"
            default: return item.itemIdentifier.rawValue
            }
        }
        let centred = Set(toolbar.centeredItemIdentifiers.map(\.rawValue)) == Set(tools)
        return (items, centred)
    }

    // MARK: Sound that starts after the picture

    /// Writes `name` (mp4, mkv, wmv…): 4 s of black video at 30 fps with a white flash on frames 75–77 (2.5 s), and
    /// sound that starts at 0.5 s on the file's clock — a quiet 300 Hz hum with a 20 ms 1 kHz burst at 2.5 s, under
    /// the flash. Many recordings start their sound a little after the picture; this one makes the gap obvious.
    static func makeLateSoundClip(_ url: URL) -> Bool {
        guard let ff = FFmpeg.shared else { return false }
        let codecs: [String]
        switch Ext.of(url) {
        case "wmv": codecs = ["-c:v", "wmv2", "-q:v", "3", "-g", "15", "-c:a", "wmav2"]
        case "webm": codecs = ["-c:v", "libvpx-vp9", "-g", "15", "-b:v", "200k", "-deadline", "realtime", "-c:a", "libopus"]
        default: codecs = ["-c:v", "libx264", "-bf", "2", "-g", "15", "-pix_fmt", "yuv420p", "-c:a", "aac"]
        }
        let args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                    "-f", "lavfi", "-i", "color=black:s=320x240:r=30:d=4,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='between(t,2.49,2.59)'",
                    "-itsoffset", "0.5", "-f", "lavfi", "-i",
                    "aevalsrc='0.05*sin(2*PI*300*t)+if(between(t,2.0,2.02),0.9*sin(2*PI*1000*(t-2)),0)':s=48000:d=3.5",
                    "-map", "0:v", "-map", "1:a"] + codecs + [url.path]
        return (try? ProcessRunner.run(ff.tool, args))?.status == 0
    }

    /// When the flash (the first bright frame) shows and when the burst (the first sample over 0.3) sounds, both on
    /// the file's clock; nil when either is missing.
    static func flashAndBurst(_ url: URL) -> (flash: Double, burst: Double)? {
        guard let ff = FFmpeg.shared,
              let r = try? ProcessRunner.run(ff.tool, ["-hide_banner", "-nostdin", "-i", url.path, "-map", "0:v:0",
                                                       "-vf", "scale=16:12,format=gray,showinfo", "-f", "null", "-"]) else { return nil }
        // showinfo: "pts_time:2.5 … mean:[235]" (gray: one plane).
        var flash: Double?
        for line in r.stderr.split(separator: "\n") where line.contains("pts_time:") {
            guard let t = line.firstMatch(of: #/pts_time:(-?[0-9.]+)/#).flatMap({ Double($0.1) }),
                  let mean = line.firstMatch(of: #/mean:\[(\d+)/#).flatMap({ Int($0.1) }) else { continue }
            if mean > 128 { flash = t; break }
        }
        let samples = MediaMeasure.pcm(url, rate: 48_000, channels: 1, fileClock: true)
        guard let flash, let i = samples.firstIndex(where: { abs(Int($0)) > 9_830 }) else { return nil }
        return (flash, Double(i) / 48_000)
    }

    /// Presses at `from`, drags in four steps to `to` and lets go (Esc before letting go when `cancel` is set).
    static func drag(_ view: NSView, from: CGPoint, to: CGPoint, cancel: (() -> Void)? = nil) {
        view.mouseDown(with: mouse(.leftMouseDown, at: from, in: view))
        for step in 1...4 {
            let k = CGFloat(step) / 4
            view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k), in: view))
        }
        cancel?()
        view.mouseUp(with: mouse(.leftMouseUp, at: to, in: view))
    }
}
#endif
