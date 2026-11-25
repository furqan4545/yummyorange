#if DEBUG
// Debug builds only; the shipped app leaves it out. Not part of ./test.sh, because it needs the website served.
import Foundation

/// `--selftest helper-live`: the real helper ZIP, end to end, through the app's own code. The app's helper
/// configuration (FFmpegHelper.Config.app, as the menu-bar app makes it) downloads the pinned build from a server
/// standing in for yummyorange.com, checks its length and SHA-256, unpacks, runs and places it, then JobRunner
/// converts with it. Run it a second time with the same Helpers folder: it then downloads nothing.
///
///     cd Website/public && python3 -m http.server 8765 --bind 127.0.0.1
///     DW_HELPER_BASE_URL=http://127.0.0.1:8765/downloads/helpers/ \
///     DW_HELPER_ROOT=/tmp/somewhere/Helpers DW_HELPER_HIDE_USER_FFMPEG=1 \
///     DW_HELPER_LIVE_WORK=/tmp/somewhere/work .build/debug/DropWheel --selftest helper-live
///
/// DW_HELPER_ROOT must not be the real ~/Library/Application Support/YummyOrange/Helpers; settings stay in memory.
/// The test files (a tone made here, a clip made with the installed ffmpeg) and the converted files are left in
/// DW_HELPER_LIVE_WORK (default: a new folder in the temporary folder), one folder per run.
enum FFmpegHelperLiveTest {
    typealias Checker = ResultsShelfTests.Checker

    static func run() -> String {
        let c = Checker()
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        let pinned = FFmpegHelper.pinnedBuild

        // Only ever against a stand-in Helpers folder and a base URL chosen on purpose.
        let realRoot = FFmpegLookup.defaultRoot(environment: [:]).standardizedFileURL.path
        let root = FFmpegLookup.defaultRoot()
        guard env["DW_HELPER_BASE_URL"] != nil, env["DW_HELPER_ROOT"] != nil, root.standardizedFileURL.path != realRoot,
              FFmpegLookup.hidesUserFFmpeg() else {
            c.check("needs DW_HELPER_BASE_URL, DW_HELPER_ROOT (not the real Application Support) and DW_HELPER_HIDE_USER_FFMPEG=1", false)
            return c.report("helper-live")
        }
        c.check("the pinned build is filled in", pinned.isPinned, "\(pinned)")

        let savedDefaults = Settings.defaults
        Settings.defaults = SettingsMemoryStore(["showProgressHUD": false])
        let savedHUD = JobRunner.reportToHUD
        var reports: [(saved: [URL], errors: [String])] = []
        JobRunner.reportToHUD = { reports.append(($0, $1)) }
        let savedHelper = FFmpegHelper.shared
        defer {
            Settings.defaults = savedDefaults
            JobRunner.reportToHUD = savedHUD
            FFmpegHelper.shared = savedHelper
        }

        // The app's own configuration, as if launched as the menu-bar app (not from the command line); only the
        // backoff counter (in memory) and the HUD (a log here) differ.
        var config = FFmpegHelper.Config.app(arguments: ["YummyOrange"])
        let memory = SettingsMemoryStore()
        config.defaults = { memory }
        var progress: [String] = []
        let started = Date()
        config.ui = FFmpegHelper.UI(progress: { text, _ in
            progress.append(text)
            log(String(format: "%6.2f s  HUD: %@", Date().timeIntervalSince(started), text))
        }, failed: { text in log("HUD error: \(text)") }, ready: { log(String(format: "%6.2f s  HUD: helper ready", Date().timeIntervalSince(started))) })
        let helper = FFmpegHelper(config: config)
        FFmpegHelper.shared = helper

        log("base URL  \(config.baseURL.absoluteString)")
        log("Helpers   \(config.root.path)")
        log("pinned    \(pinned.fileName), \(pinned.length) bytes, SHA-256 \(pinned.sha256)")
        c.check("the app’s configuration: enabled, the DEBUG base URL, the stand-in Helpers folder",
                config.enabled && config.root.standardizedFileURL.path == root.standardizedFileURL.path && helper.canFetch,
                "enabled \(config.enabled) root \(config.root.path)")

        let before = Capabilities.shared.ffmpegFound
        let fresh = before == nil
        log("before    \(before.map { "\($0.ffmpeg.path) (\($0.source))" } ?? "no ffmpeg on this Mac (the user’s own is hidden)")")
        if fresh {
            c.check("no ffmpeg yet, so the helper is needed", helper.isNeeded)
        } else {
            c.check("YummyOrange’s copy is already here, so nothing is needed",
                    before?.source == .helper(version: pinned.version) && !helper.isNeeded, "\(String(describing: before))")
        }

        // One folder per run for the test files and what the jobs make.
        let workBase = env["DW_HELPER_LIVE_WORK"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fm.temporaryDirectory.appendingPathComponent("YummyOrange helper-live", isDirectory: true)
        let work = workBase.appendingPathComponent("run-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ""))-\(UUID().uuidString.prefix(4))", isDirectory: true)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        log("work      \(work.path)")
        let tone = work.appendingPathComponent("tone.wav")
        c.check("a 3-second test tone (written here, no ffmpeg needed)", writeTone(to: tone))

        // Two conversions at once, before any ffmpeg is here: both wait for one download, then run.
        JobRunner.run(.convert(.mp3), on: [tone])
        JobRunner.run(.convert(.ogg), on: [tone])
        let audioDone = FFmpegHelperTests.spin(15 * 60) { reports.count == 2 }
        let downloadTime = Date().timeIntervalSince(started)
        c.check("MP3 and OGG from the tone: both done, no errors",
                audioDone && reports.allSatisfy { $0.errors.isEmpty } && reports.flatMap(\.saved).count == 2,
                "\(reports.map { "\($0.saved.map(\.lastPathComponent)) \($0.errors)" })")
        if fresh {
            c.check("…after exactly one download of the helper, with its progress shown",
                    helper.attempts == 1 && progress.first == FFmpegHelperText.getting, "attempts \(helper.attempts), HUD \(progress.prefix(3))")
            log(String(format: "download, check and install took %.2f s (both jobs included)", downloadTime))
        } else {
            c.check("…with no download at all", helper.attempts == 0 && progress.isEmpty, "attempts \(helper.attempts)")
        }

        // What is installed now, and that the app uses it.
        let found = Capabilities.shared.ffmpegFound
        let folder = root.appendingPathComponent(pinned.folderName, isDirectory: true)
        c.check("the app now uses YummyOrange’s copy in Helpers/\(pinned.folderName)",
                found?.source == .helper(version: pinned.version)
                    && found?.ffmpeg.standardizedFileURL.path == folder.appendingPathComponent("ffmpeg").standardizedFileURL.path,
                "\(String(describing: found))")
        let contents = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        c.check("the folder holds ffmpeg and its LICENSE.md and BUILD.md", contents == ["BUILD.md", "LICENSE.md", "ffmpeg"], "\(contents)")
        let license = (try? String(contentsOf: folder.appendingPathComponent("LICENSE.md"), encoding: .utf8)) ?? ""
        c.check("LICENSE.md: LGPL 2.1, the IJG credit, the source address and the notices of FFmpeg’s files under other licenses",
                license.contains("GNU Lesser General Public License") && license.contains("based in part on the work of the Independent JPEG Group")
                    && license.contains("https://yummyorange.com/licenses/ffmpeg.html")
                    && license.contains("## Notices for FFmpeg files under other licenses") && license.contains("libavfilter/vf_gblur.c"))
        let rootContents = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        c.check("nothing else is left in Helpers (no staging folder, no ZIP)", rootContents == [pinned.folderName], "\(rootContents)")
        let quarantined = ["ffmpeg", "LICENSE.md"].filter { getxattr(folder.appendingPathComponent($0).path, "com.apple.quarantine", nil, 0, 0, 0) >= 0 }
        c.check("nothing installed is quarantined", quarantined.isEmpty, "\(quarantined)")
        c.check("nothing more is needed", !helper.isNeeded)
        let version = (try? ProcessRunner.run(folder.appendingPathComponent("ffmpeg"), ["-version"]))?.stdout ?? ""
        let tool = AboutInfo.ffmpegTool(path: folder.appendingPathComponent("ffmpeg").path, versionOutput: version)
        log("installed \(version.split(separator: "\n").first ?? "?")")
        let row = FFmpegRow.make(found: found, tool: tool, phase: helper.phase, canFetch: helper.canFetch, downloadSize: pinned.length)
        log("About     \(row.detail) | \(row.trailing)")
        c.check("Settings › About: “Installed by YummyOrange”, LGPL", row.trailing == .installed(path: folder.appendingPathComponent("ffmpeg").path)
                    && tool.license?.hasPrefix("LGPL") == true, "\(row)")

        // Video, with a clip made by the installed ffmpeg: GIF and WebM (VP9 and Opus) through JobRunner.
        let clip = work.appendingPathComponent("clip.mp4")
        let made = try? ProcessRunner.run(folder.appendingPathComponent("ffmpeg"),
                                          ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=3",
                                           "-f", "lavfi", "-i", "sine=frequency=330:duration=3", "-c:v", "mpeg4", "-q:v", "4", "-c:a", "aac", "-shortest", clip.path])
        c.check("a 3-second test clip (MPEG-4 and AAC, made with the installed ffmpeg)", made?.status == 0 && fm.fileExists(atPath: clip.path), made?.stderr ?? "")
        reports = []
        JobRunner.run(.convert(.gif), on: [clip])
        JobRunner.run(.convert(.webm), on: [clip])
        let videoDone = FFmpegHelperTests.spin(5 * 60) { reports.count == 2 }
        c.check("GIF and WebM from the clip: both done, no errors",
                videoDone && reports.allSatisfy { $0.errors.isEmpty } && reports.flatMap(\.saved).count == 2,
                "\(reports.map { "\($0.saved.map(\.lastPathComponent)) \($0.errors)" })")
        c.check("still one download in all", helper.attempts == (fresh ? 1 : 0), "attempts \(helper.attempts)")

        // Every output, as the installed ffmpeg reads it (its stream report).
        for name in ["tone.mp3", "tone.ogg", "clip.gif", "clip.webm"] {
            let out = work.appendingPathComponent(name)
            let report = (try? ProcessRunner.run(folder.appendingPathComponent("ffmpeg"), ["-hide_banner", "-nostdin", "-i", out.path]))?.stderr ?? ""
            let streams = report.split(separator: "\n").filter { $0.contains("Stream #") || $0.contains("Duration:") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let size = (try? fm.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.intValue ?? 0
            let expected = ["tone.mp3": ["Audio: mp3"], "tone.ogg": ["Audio: vorbis"], "clip.gif": ["Video: gif"],
                            "clip.webm": ["Video: vp9", "Audio: opus"]][name]!
            c.check("\(name): \(expected.joined(separator: ", "))", size > 0 && expected.allSatisfy(report.contains), streams.joined(separator: " | "))
            log("output    \(name) \(size) bytes  \(streams.joined(separator: " | "))")
        }
        c.check("nothing counted as running afterwards", FFmpegHelperTests.spin(5) { JobRunner.runningCount == 0 })
        return c.report("helper-live")
    }

    /// The run's log, as it happens (the report comes at the end).
    static func log(_ line: String) {
        FileHandle.standardError.write(Data("[helper-live] \(line)\n".utf8))
    }

    /// 3 s of 440 Hz, 44.1 kHz 16-bit stereo PCM.
    static func writeTone(to url: URL) -> Bool {
        let rate = 44_100, seconds = 3, channels = 2
        let frames = rate * seconds
        var pcm = Data(capacity: frames * channels * 2)
        for i in 0..<frames {
            let value = Int16(sin(2 * Double.pi * 440 * Double(i) / Double(rate)) * 12_000)
            for _ in 0..<channels { withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) } }
        }
        func le32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(v).littleEndian) { [UInt8]($0) } }
        func le16(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt16(v).littleEndian) { [UInt8]($0) } }
        var wav = Data("RIFF".utf8) + le32(36 + pcm.count) + Data("WAVEfmt ".utf8)
        wav += le32(16) + le16(1) + le16(channels) + le32(rate) + le32(rate * channels * 2) + le16(channels * 2) + le16(16)
        wav += Data("data".utf8) + le32(pcm.count)
        wav += pcm
        return FileManager.default.createFile(atPath: url.path, contents: wav)
    }
}
#endif
