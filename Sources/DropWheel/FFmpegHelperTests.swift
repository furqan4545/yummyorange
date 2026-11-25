#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit

/// `--selftest helper`: YummyOrange's own ffmpeg (FFmpegHelper.swift). The pinned build's checks, the lookup order (the
/// person's own ffmpeg first, then YummyOrange's; one that doesn't run is passed over), the backoff, the HUD's words
/// and the message for each kind of failure, About's ffmpeg row in each state, the petals a Mac without ffmpeg is
/// offered, what the LGPL build lacks and stands in for (boxblur, software AV1), then downloads from a
/// `python3 -m http.server` on 127.0.0.1 serving ZIPs of tiny stand-in programs made here: a good one installs (in a
/// folder or flat, over a damaged copy or a dangling link, the app switching to it before older versions go, a newer
/// copy kept); a wrong SHA-256, a wrong length, a truncated file, HTTP errors, a refused connection, an insecure
/// address, a damaged or empty ZIP, a program that doesn't run, a full disk and an unwritable folder install nothing
/// and leave no file; waiting tasks share one download, a running one isn't started twice, Cancel stops one, the next
/// attempt after a failure starts over, the quiet attempt happens once and backs off; and JobRunner waits for the
/// helper and then converts.
///
/// Nothing here touches the real ~/Library/Application Support/YummyOrange/Helpers, the real preferences or the
/// network beyond 127.0.0.1: every Helpers folder is a temporary one, settings live in memory, and the app's own helper
/// can't download from the command line at all (checked first).
enum FFmpegHelperTests {
    typealias Checker = ResultsShelfTests.Checker

    static func run() -> String {
        let c = Checker()
        let savedDefaults = Settings.defaults
        // In memory only; the progress panel stays hidden while the job test runs.
        Settings.defaults = SettingsMemoryStore(["showProgressHUD": false])
        defer { Settings.defaults = savedDefaults }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("YummyOrange helper \(UUID().uuidString.prefix(8))", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        c.check("the app’s own helper never downloads from the command line (self-tests can’t reach yummyorange.com)",
                !FFmpegHelper.shared.canFetch && !FFmpegHelper.shared.config.enabled)
        pin(c)
        lookup(c, dir)
        policy(c)
        words(c)
        aboutRows(c)
        config(c)
        probes(c, dir)
        lgplBuild(c, dir)
        wheel(c, dir)
        guard let kit = Kit(dir.appendingPathComponent("kit", isDirectory: true)) else {
            c.check("stand-in ZIPs and python3 -m http.server on 127.0.0.1 (needs /usr/bin/python3)", false)
            return c.report("helper")
        }
        defer { kit.server.stop() }
        installs(c, kit)
        refusals(c, kit)
        sharing(c, kit)
        cancel(c, kit)
        automatic(c, kit)
        jobs(c, kit)
        return c.report("helper")
    }

    // MARK: Pinned build

    static func pin(_ c: Checker) {
        let good = FFmpegHelperBuild(version: "8.0.1", fileName: "ffmpeg-8.0.1-arm64.zip", length: 15_000_000, sha256: String(repeating: "ab", count: 32))
        c.check("a filled-in build counts as pinned", good.isPinned)
        var bad = good; bad.length = 0
        c.check("no length: not pinned", !bad.isPinned)
        bad = good; bad.sha256 = "PLACEHOLDER"
        c.check("a placeholder checksum: not pinned", !bad.isPinned)
        bad = good; bad.sha256 = String(repeating: "AB", count: 32)
        c.check("an uppercase checksum: not pinned (the constant is lowercase)", !bad.isPinned)
        bad = good; bad.fileName = "../ffmpeg.zip"
        c.check("a file name with a path: not pinned", !bad.isPinned)
        bad = good; bad.fileName = "ffmpeg.tar.gz"
        c.check("not a ZIP: not pinned", !bad.isPinned)
        bad = good; bad.version = "../8"
        c.check("a version that isn’t a plain folder name: not pinned", !bad.isPinned)
        bad = good; bad.version = "PLACEHOLDER"
        c.check("a placeholder version: not pinned", !bad.isPinned)
        c.check("the folder is ffmpeg-<version>", good.folderName == "ffmpeg-8.0.1")
        let pinned = FFmpegHelper.pinnedBuild
        if pinned.isPinned {
            c.notes.append("pinnedBuild: \(pinned.fileName), \(pinned.length) bytes, ffmpeg \(pinned.version)")
        } else {
            c.notes.append("pinnedBuild is still the placeholder: this copy downloads nothing until it is filled in")
        }
        c.check("the helpers come from https://yummyorange.com/downloads/helpers/",
                FFmpegHelper.defaultBaseURL.absoluteString == "https://yummyorange.com/downloads/helpers/")
    }

    // MARK: Lookup

    static func lookup(_ c: Checker, _ dir: URL) {
        let fm = FileManager.default
        let base = dir.appendingPathComponent("lookup", isDirectory: true)
        let brew = base.appendingPathComponent("brew", isDirectory: true)
        let local = base.appendingPathComponent("local", isDirectory: true)
        let empty = base.appendingPathComponent("empty", isDirectory: true)
        let notRunnable = base.appendingPathComponent("plain", isDirectory: true) // ffmpeg without the x bit
        let root = base.appendingPathComponent("Helpers", isDirectory: true)
        for folder in [brew, local, empty, notRunnable, root] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        script(brew.appendingPathComponent("ffmpeg"), "echo brew")
        script(local.appendingPathComponent("ffmpeg"), "echo local")
        script(notRunnable.appendingPathComponent("ffmpeg"), "echo plain", executable: false)
        Kit.programs(in: root.appendingPathComponent("ffmpeg-9.9-test", isDirectory: true), version: "9.9-test")
        Kit.programs(in: root.appendingPathComponent("ffmpeg-1.0", isDirectory: true), version: "1.0")
        Kit.programs(in: root.appendingPathComponent("ffmpeg-10.0", isDirectory: true), version: "10.0", complete: false)
        Kit.programs(in: root.appendingPathComponent(".staging-x", isDirectory: true), version: "99")
        Kit.programs(in: root.appendingPathComponent("ffmpeg-..", isDirectory: true), version: "..")

        let user = FFmpegLookup.find(userFolders: [empty, notRunnable, brew, local], hideUser: false, helpers: root, pinned: "9.9-test")
        c.check("the person’s own ffmpeg comes first, in the order YummyOrange always looked (a file that can’t run is skipped)",
                user?.ffmpeg == brew.appendingPathComponent("ffmpeg") && user?.source == .user, "\(String(describing: user))")
        let all = FFmpegLookup.candidates(userFolders: [empty, notRunnable, brew, local], hideUser: false, helpers: root, pinned: "9.9-test")
        c.check("every candidate in order: each folder’s own ffmpeg, then YummyOrange’s copy (for passing over one that doesn’t run)",
                all.map(\.ffmpeg) == [brew.appendingPathComponent("ffmpeg"), local.appendingPathComponent("ffmpeg"),
                                      root.appendingPathComponent("ffmpeg-9.9-test/ffmpeg")], "\(all.map(\.ffmpeg.path))")
        let ours = FFmpegLookup.find(userFolders: [empty], hideUser: false, helpers: root, pinned: "9.9-test")
        let pinnedFolder = root.appendingPathComponent("ffmpeg-9.9-test", isDirectory: true)
        c.check("with none of the person’s own: YummyOrange’s copy of the pinned version",
                ours?.ffmpeg == pinnedFolder.appendingPathComponent("ffmpeg") && ours?.source == .helper(version: "9.9-test"), "\(String(describing: ours))")
        let hidden = FFmpegLookup.find(userFolders: [brew], hideUser: true, helpers: root, pinned: "9.9-test")
        c.check("hiding the person’s own ffmpeg (the DEBUG seam) leaves YummyOrange’s", hidden?.source == .helper(version: "9.9-test"))
        let newest = FFmpegLookup.find(userFolders: [], hideUser: false, helpers: root, pinned: "2.0")
        c.check("the pinned version missing: the newest complete other copy (9.9 over 1.0; 10.0 has no runnable ffmpeg)",
                newest?.source == .helper(version: "9.9-test"), "\(String(describing: newest))")
        c.check("installed versions list only complete, plainly named folders (no staging, no ffmpeg-..)",
                Set(FFmpegLookup.installedVersions(in: root)) == ["9.9-test", "1.0"], "\(FFmpegLookup.installedVersions(in: root))")
        c.check("nothing anywhere: no ffmpeg", FFmpegLookup.find(userFolders: [empty], hideUser: false,
                                                                 helpers: base.appendingPathComponent("none"), pinned: "1") == nil)
        c.check("versions compare as numbers", FFmpegLookup.isOlder("9.9", "10.0") && !FFmpegLookup.isOlder("10.0", "9.9")
                    && FFmpegLookup.isOlder("8.0", "8.0.1") && FFmpegLookup.isOlder("9.0.2-2", "9.0.2-10") && !FFmpegLookup.isOlder("9.0.2-2", "9.0.2-2"))
        c.check("the DEBUG seam that hides the person’s ffmpeg reads DW_HELPER_HIDE_USER_FFMPEG=1",
                FFmpegLookup.hidesUserFFmpeg(environment: ["DW_HELPER_HIDE_USER_FFMPEG": "1"], defaults: SettingsMemoryStore())
                    && !FFmpegLookup.hidesUserFFmpeg(environment: [:], defaults: SettingsMemoryStore())
                    && FFmpegLookup.hidesUserFFmpeg(environment: [:], defaults: SettingsMemoryStore(["DWHelperHideUserFFmpeg": true])))
        let folders = FFmpegLookup.userFolders().map(\.path)
        let home = fm.homeDirectoryForCurrentUser.path
        c.check("the person’s own ffmpeg is looked for where it always was (~/.local/bin, /opt/homebrew/bin, /usr/local/bin)",
                Array(folders.suffix(4)) == [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"], "\(folders)")
        c.check("YummyOrange’s copies live in ~/Library/Application Support/YummyOrange/Helpers",
                FFmpegLookup.defaultRoot().path == home + "/Library/Application Support/YummyOrange/Helpers", FFmpegLookup.defaultRoot().path)
    }

    // MARK: Policy and words

    static func policy(_ c: Checker) {
        let backoffs = (0...6).map { FFmpegHelperPolicy.backoff(afterFailures: $0) }
        c.check("automatic attempts back off: none, 15 min, 1 h, 4 h, 16 h, 64 h, then at most 3 days",
                backoffs == [0, 900, 3600, 14_400, 57_600, 230_400, 259_200], "\(backoffs)")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        c.check("no failures: due", FFmpegHelperPolicy.automaticIsDue(failures: 0, lastFailure: nil, now: now))
        c.check("2 failures, the last 10 minutes ago: not due (1 hour)",
                !FFmpegHelperPolicy.automaticIsDue(failures: 2, lastFailure: now.addingTimeInterval(-600), now: now))
        c.check("2 failures, the last 2 hours ago: due",
                FFmpegHelperPolicy.automaticIsDue(failures: 2, lastFailure: now.addingTimeInterval(-7200), now: now))
        c.check("a last failure in the future (the clock set back): due",
                FFmpegHelperPolicy.automaticIsDue(failures: 5, lastFailure: now.addingTimeInterval(3600), now: now))
        c.check("the quiet download waits a minute after launch", FFmpegHelperPolicy.launchDelay == 60)
    }

    static func words(_ c: Checker) {
        c.check("HUD before the size is known: one name for it, said with what it is for",
                FFmpegHelperText.progress(nil) == "Downloading ffmpeg for audio and video…", FFmpegHelperText.progress(nil))
        c.check("HUD with progress: “Downloading ffmpeg for audio and video… 42%”",
                FFmpegHelperText.progress(0.42) == "Downloading ffmpeg for audio and video… 42%", FFmpegHelperText.progress(0.42))
        c.check("percent rounds down, so 100% means done", FFmpegHelperText.progress(0.999) == "Downloading ffmpeg for audio and video… 99%"
                    && FFmpegHelperText.progress(1) == "Downloading ffmpeg for audio and video… 100%" && FFmpegHelperText.percent(-1) == 0)
        let all = [FFmpegHelperText.offline, FFmpegHelperText.damaged, FFmpegHelperText.noSpace, FFmpegHelperText.cannotSave,
                   FFmpegHelperText.canceled, FFmpegHelperText.notYet, FFmpegHelperText.getting]
        c.check("every message names ffmpeg, and none says “we” or “helper”",
                all.allSatisfy { $0.contains("ffmpeg") && !$0.lowercased().contains("helper") && !$0.contains(" we ") && !$0.hasPrefix("We ") }, "\(all)")
        // Each kind of failure gets its own message, with what to do about it.
        let message = FFmpegHelperText.message
        c.check("no connection: check the internet connection",
                message(UpdateError.network("The Internet connection appears to be offline.")) == FFmpegHelperText.offline
                    && FFmpegHelperText.offline.contains("Check your internet connection"))
        c.check("a server error, a wrong checksum, a damaged ZIP or an ffmpeg that won’t run: try again later (not the connection)",
                ([UpdateError.server(404), UpdateError.server(503), UpdateError.wrongChecksum, UpdateError.tooLarge,
                  UpdateError.wrongLength(expected: 2, actual: 1), FFmpegHelperError.badArchive("x"), FFmpegHelperError.doesNotRun("ffmpeg")] as [Error])
                    .allSatisfy { message($0) == FFmpegHelperText.damaged } && FFmpegHelperText.damaged.contains("Try again later"))
        c.check("a full disk, however the step that met it said it: free up space",
                message(FFmpegHelperError.noSpace) == FFmpegHelperText.noSpace
                    && message(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) == FFmpegHelperText.noSpace
                    && message(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) == FFmpegHelperText.noSpace
                    && message(UpdateError.cannotInstall("YummyOrange couldn’t save the download: No space left on device")) == FFmpegHelperText.noSpace
                    && message(FFmpegHelperError.badArchive("ditto: No space left on device")) == FFmpegHelperText.noSpace)
        c.check("a folder that can’t be written: says which folder",
                message(FFmpegHelperError.cannotPlace("Permission denied")) == FFmpegHelperText.cannotSave
                    && message(UpdateError.cannotInstall("YummyOrange couldn’t save the download in a temporary folder.")) == FFmpegHelperText.cannotSave
                    && FFmpegHelperText.cannotSave.contains("~/Library/Application Support/YummyOrange"))
        c.check("Cancel: “The ffmpeg download was canceled.”", message(FFmpegHelperError.canceled) == "The ffmpeg download was canceled.")
        c.check("the quiet download only on a network that isn’t metered",
                FFmpegHelper.isUnmetered(satisfied: true, constrained: false, expensive: false)
                    && !FFmpegHelper.isUnmetered(satisfied: true, constrained: true, expensive: false)
                    && !FFmpegHelper.isUnmetered(satisfied: true, constrained: false, expensive: true)
                    && !FFmpegHelper.isUnmetered(satisfied: false, constrained: false, expensive: false))
        c.check("the download may take an hour (11.5 MB on a slow line), an update’s 15 minutes",
                FFmpegHelperPolicy.downloadTimeout == 3600)
    }

    // MARK: About

    static func aboutRows(_ c: Checker) {
        let brew = FFmpegLookup.Found(ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), source: .user)
        let ours = FFmpegLookup.Found(ffmpeg: URL(fileURLWithPath: "/x/Helpers/ffmpeg-8.0.1/ffmpeg"), source: .helper(version: "8.0.1"))
        let gpl = AboutInfo.Tool(path: brew.ffmpeg.path, version: "version 7.1", license: "GPL 3 build")
        let lgpl = AboutInfo.Tool(path: ours.ffmpeg.path, version: "version 8.0.1", license: "LGPL 3 build")
        let size = 11_489_831
        let user = FFmpegRow.make(found: brew, tool: gpl, phase: .idle, canFetch: true, downloadSize: size)
        c.check("About, the person’s own ffmpeg: its path, version and license",
                user == FFmpegRow(detail: "Audio and video · version 7.1 · GPL 3 build", trailing: .path("/opt/homebrew/bin/ffmpeg")), "\(user)")
        let installed = FFmpegRow.make(found: ours, tool: lgpl, phase: .idle, canFetch: true, downloadSize: size)
        c.check("About, YummyOrange’s copy: “Installed by YummyOrange”, with its version",
                installed == FFmpegRow(detail: "Audio and video · version 8.0.1 · LGPL 3 build", trailing: .installed(path: ours.ffmpeg.path))
                    && FFmpegRow.installedByYummyOrange == "Installed by YummyOrange", "\(installed)")
        let missing = FFmpegRow.make(found: nil, tool: AboutInfo.Tool(), phase: .idle, canFetch: true, downloadSize: size)
        c.check("About, none yet: a Download button, and that it comes by itself (no promise of when)",
                missing.trailing == .download
                    && missing.status == "Not installed yet. YummyOrange downloads it by itself (11.5 MB), or click Download to get it now."
                    && !missing.isProblem && missing.detail == "Audio and video", "\(String(describing: missing.status))")
        let started = FFmpegRow.make(found: nil, tool: AboutInfo.Tool(), phase: .downloading(nil), canFetch: true, downloadSize: size)
        let halfway = FFmpegRow.make(found: nil, tool: AboutInfo.Tool(), phase: .downloading(0.42), canFetch: true, downloadSize: size)
        c.check("About, downloading: a bar (indeterminate until the size is known, then 42%) and Cancel",
                started.trailing == .progress(nil, cancel: true) && halfway.trailing == .progress(0.42, cancel: true)
                    && halfway.status == "Downloading…", "\(halfway)")
        let placing = FFmpegRow.make(found: nil, tool: AboutInfo.Tool(), phase: .installing, canFetch: true, downloadSize: size)
        c.check("About, putting it in place: a full bar, “Installing…”, nothing to cancel",
                placing.trailing == .progress(1, cancel: false) && placing.status == "Installing…")
        let failed = FFmpegRow.make(found: nil, tool: AboutInfo.Tool(), phase: .failed, failure: FFmpegHelperText.noSpace, canFetch: true,
                                    downloadSize: size)
        c.check("About, after a failed attempt: Download again, and why it failed (a full disk here), marked as a problem",
                failed.trailing == .download && failed.isProblem && failed.status == FFmpegHelperText.noSpace, "\(failed)")
        let unknown = FFmpegRow.make(found: nil, tool: AboutInfo.Tool(), phase: .failed, canFetch: true, downloadSize: size)
        c.check("…with no reason kept, the connection", unknown.status == FFmpegHelperText.offline)
        let unavailable = FFmpegRow.make(found: nil, tool: AboutInfo.Tool(), phase: .idle, canFetch: false, downloadSize: 0)
        c.check("About, a copy that can’t download one: as before",
                unavailable.trailing == .missing("Not found. Audio and video conversions are off."), "\(unavailable)")
        let upgrading = FFmpegRow.make(found: ours, tool: lgpl, phase: .downloading(0.5), canFetch: true, downloadSize: size)
        c.check("About, a newer copy on its way: the bar", upgrading.trailing == .progress(0.5, cancel: true))
        let note = AboutInfo.licenseNote
        c.check("the license note: YummyOrange’s own ffmpeg is an LGPL 2.1 build of FFmpeg, its license and source at yummyorange.com/licenses/ffmpeg.html, a Mac’s own ffmpeg under its own license",
                note == "YummyOrange’s own ffmpeg is an LGPL 2.1 build of FFmpeg; its license and source code are at yummyorange.com/licenses/ffmpeg.html. "
                    + "An ffmpeg already on this Mac is used instead, under its own license.", note)
        let text = AboutInfo.licenseNoteText
        let linked = text.runs.contains { $0.link == AboutInfo.licenseURL && String(text[$0.range].characters) == "yummyorange.com/licenses/ffmpeg.html" }
        c.check("the address in the note is a link to https://yummyorange.com/licenses/ffmpeg.html", linked)
        let tool = AboutInfo.ffmpegTool(path: "/p/ffmpeg", versionOutput: "ffmpeg version 8.0.1 Copyright (c) 2000-2025 the FFmpeg developers\nconfiguration: --enable-version3 --enable-libmp3lame\n")
        c.check("About reads the version and license from “-version”", tool.version == "version 8.0.1" && tool.license == "LGPL 3 build",
                "\(tool)")
    }

    static func config(_ c: Checker) {
        let app = FFmpegHelper.Config.app(arguments: ["YummyOrange"], environment: [:])
        var arm = false
        #if arch(arm64)
        arm = true
        #endif
        c.check("the app’s helper: downloads in the app on Apple silicon, from yummyorange.com over HTTPS, with the app’s User-Agent",
                app.enabled == arm && app.baseURL == FFmpegHelper.defaultBaseURL && !app.allowsLoopbackHTTP
                    && app.userAgent.hasPrefix("YummyOrange/") && app.build == FFmpegHelper.pinnedBuild, "\(app.baseURL) \(app.userAgent)")
        let commandLine = FFmpegHelper.Config.app(arguments: ["DropWheel", "--convert", "mp3"], environment: [:])
        c.check("from the command line: never", !commandLine.enabled)
        let local = FFmpegHelper.Config.app(arguments: ["YummyOrange"], environment: ["DW_HELPER_BASE_URL": "http://127.0.0.1:8123/helpers/"])
        c.check("DEBUG: DW_HELPER_BASE_URL points it at a local server (plain HTTP to 127.0.0.1 only)",
                local.baseURL.absoluteString == "http://127.0.0.1:8123/helpers/" && local.allowsLoopbackHTTP)
        let remote = FFmpegHelper.Config.app(arguments: ["YummyOrange"], environment: ["DW_HELPER_BASE_URL": "http://example.com/helpers/"])
        c.check("…and an address elsewhere still needs HTTPS", !remote.allowsLoopbackHTTP)
        let before = Capabilities.shared.ffmpegFound
        let encoders = Capabilities.shared.has("aac")
        Capabilities.shared.refreshFFmpeg()   // what an install does once its copy is in place
        c.check("looking again (after an install) finds the same ffmpeg on this Mac and probes it again",
                Capabilities.shared.ffmpegFound == before && Capabilities.shared.has("aac") == encoders,
                "\(String(describing: before?.ffmpeg.path))")
        c.check("YummyOrange’s build covers the encoders the wheels ask about",
                ["libmp3lame", "libopus", "libvorbis", "libvpx-vp9", "libwebp", "libwebp_anim", "aac_at", "h264_videotoolbox", "mpeg4", "wmv2", "wmav2"]
                    .allSatisfy(FFmpegHelper.buildIncludes) && !FFmpegHelper.buildIncludes(encoder: "libx264")
                    && !FFmpegHelper.buildIncludes(encoder: "libfdk_aac") && !FFmpegHelper.buildIncludes(encoder: "libvpx"))
    }

    // MARK: Probing: an ffmpeg that doesn't run, or has gone

    static func probes(_ c: Checker, _ dir: URL) {
        let fm = FileManager.default
        let base = dir.appendingPathComponent("probes", isDirectory: true)
        let broken = base.appendingPathComponent("broken", isDirectory: true), works = base.appendingPathComponent("works", isDirectory: true)
        for folder in [broken, works] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        // Homebrew's ffmpeg with one of its libraries gone: dyld stops it before it prints anything.
        script(broken.appendingPathComponent("ffmpeg"), "echo 'dyld: Library not loaded: libx265.215.dylib' >&2; exit 134")
        script(works.appendingPathComponent("ffmpeg"), "echo 'Encoders:'; echo ' A....D aac                  AAC (Advanced Audio Coding)'")
        let bad = FFmpegLookup.Found(ffmpeg: broken.appendingPathComponent("ffmpeg"), source: .user)
        let good = FFmpegLookup.Found(ffmpeg: works.appendingPathComponent("ffmpeg"), source: .user)
        let chosen = Capabilities.FFmpegProbe.first(of: [bad, good])
        c.check("an ffmpeg of the person’s own that doesn’t run is passed over for the next one",
                chosen.found == good && chosen.encoders == ["aac"], "\(String(describing: chosen.found)) \(chosen.encoders)")
        c.check("…and when none runs there is none, so YummyOrange gets its own", Capabilities.FFmpegProbe.first(of: [bad]).found == nil)

        // The ffmpeg in use gone (Helpers deleted, a copy replaced by a newer YummyOrange, Homebrew's uninstalled).
        let gone = FFmpegLookup.Found(ffmpeg: base.appendingPathComponent("gone/ffmpeg"), source: .helper(version: "0.1"))
        let saved = Capabilities.shared.swapFFmpegProbe(Capabilities.FFmpegProbe(found: gone, encoders: ["aac"], filters: []))
        let live = Capabilities.shared.liveFFmpegFound
        Capabilities.shared.swapFFmpegProbe(saved)
        let expected = Capabilities.FFmpegProbe.first(of: FFmpegLookup.currentCandidates()).found
        c.check("an ffmpeg whose file has gone is looked for again before a job uses it (this Mac’s own now)",
                live != gone && live == expected, "\(String(describing: live)) expected \(String(describing: expected))")
        c.check("…while it is there, nothing is looked for", Capabilities.shared.liveFFmpegFound == Capabilities.shared.ffmpegFound)
    }

    // MARK: What the LGPL build lacks, and what stands in for it

    static func lgplBuild(_ c: Checker, _ dir: URL) {
        // boxblur is GPL-only: Redact's Blur and Visualize's Spectrum use avgblur where it is missing.
        let gplBlur = BoxBlur.filter(radius: 9, passes: 3, chroma: "'min(cw,ch)/6'", boxblur: true)
        let lgplBlur = BoxBlur.filter(radius: 9, passes: 3, chroma: "'min(cw,ch)/6'", boxblur: false)
        c.check("a box blur: boxblur where ffmpeg has it (as before), else avgblur three times on planes of one size",
                gplBlur == "boxblur=luma_radius=9:luma_power=3:chroma_radius='min(cw,ch)/6':chroma_power=3"
                    && lgplBlur == "format=pix_fmts=\(BoxBlur.fullPlanes),avgblur=sizeX=9,avgblur=sizeX=9,avgblur=sizeX=9", lgplBlur)
        let spectrum = MediaVisualize.graph(.spectrum, size: .square, boxblur: false)
        c.check("Visualize’s Spectrum without boxblur: avgblur twice", spectrum.contains("avgblur=sizeX=6,avgblur=sizeX=6") && !spectrum.contains("boxblur"))
        let common = Set(MediaVisualize.commonFilters + ["showwaves", "showcqt", "drawgrid"])
        let found = Capabilities.shared.ffmpegFound
        let saved = Capabilities.shared.swapFFmpegProbe(Capabilities.FFmpegProbe(found: found, encoders: [], filters: common.union(["avgblur"])))
        let withAvgblur = MediaVisualize.availableStyles
        Capabilities.shared.swapFFmpegProbe(Capabilities.FFmpegProbe(found: found, encoders: [], filters: common))
        let withNeither = MediaVisualize.availableStyles
        Capabilities.shared.swapFFmpegProbe(saved)
        c.check("an ffmpeg with avgblur and no boxblur (YummyOrange’s own) draws all three styles; one with neither, no Spectrum",
                withAvgblur == [.waveform, .spectrum, .bars] && withNeither == [.waveform, .bars], "\(withAvgblur) \(withNeither)")

        // AV1: YummyOrange's copy has no dav1d, so it decodes AV1 only with the Mac's hardware (M3 and later).
        let report = "  Stream #0:0[0x1](und): Video: av1 (Main) (av01 / 0x31307661), yuv420p(tv, progressive), 640x360, 30 fps\n"
        c.check("ffmpeg’s stream report names the video codec", FFmpeg.parse(report).videoCodec == "av1")
        c.check("an AV1 video on a Mac that can’t decode it: a plain sentence, not ffmpeg’s",
                FFmpeg.failureMessage("[av1 @ 0x12ab] Your platform doesn't support hardware accelerated AV1 decoding.\n"
                                      + "[vist#0:0/av1 @ 0x34cd] Error while decoding\nConversion failed!\n") == FFmpeg.av1Unsupported)
        guard let ff = FFmpeg.shared, let encoder = ["libsvtav1", "libaom-av1", "librav1e"].first(where: Capabilities.shared.has) else {
            c.notes.append("AV1 input check skipped: this Mac’s ffmpeg can’t write AV1")
            return
        }
        let av1 = dir.appendingPathComponent("av1.mp4"), mpeg4 = dir.appendingPathComponent("mpeg4.mp4")
        let source = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc2=s=320x240:r=25:d=0.4", "-an"]
        let madeAV1 = (try? ProcessRunner.run(ff.tool, source + ["-c:v", encoder] + (encoder == "libaom-av1" ? ["-cpu-used", "8"] : [])
                                              + ["-pix_fmt", "yuv420p", av1.path]))?.status == 0
        let madeMPEG4 = (try? ProcessRunner.run(ff.tool, source + ["-c:v", "mpeg4", mpeg4.path]))?.status == 0
        guard madeAV1, madeMPEG4 else { c.check("AV1 and MPEG-4 test clips (\(encoder))", false); return }
        let real = Capabilities.shared.swapFFmpegProbe(Capabilities.FFmpegProbe(found: found, encoders: saved.encoders, filters: [],
                                                                                decoders: ["av1", "mpeg4", "h264"]))
        let hardware = (ff.decodeOptions(for: av1), ff.decodeOptions(for: mpeg4))
        Capabilities.shared.swapFFmpegProbe(Capabilities.FFmpegProbe(found: found, encoders: saved.encoders, filters: [],
                                                                     decoders: ["av1", "libdav1d", "mpeg4", "h264"]))
        let software = ff.decodeOptions(for: av1)
        Capabilities.shared.swapFFmpegProbe(real)
        c.check("an AV1 video read by an ffmpeg without dav1d gets -hwaccel videotoolbox; other videos, and an ffmpeg with dav1d, nothing",
                hardware.0 == ["-hwaccel", "videotoolbox"] && hardware.1.isEmpty && software.isEmpty, "\(hardware) \(software)")
    }

    // MARK: Wheels on a Mac without ffmpeg

    static func wheel(_ c: Checker, _ dir: URL) {
        let none = Capabilities.FFmpegProbe(found: nil, encoders: [], filters: [])
        let saved = Capabilities.shared.swapFFmpegProbe(none)
        let savedHelper = FFmpegHelper.shared
        defer { Capabilities.shared.swapFFmpegProbe(saved); FFmpegHelper.shared = savedHelper }
        let clip = dir.appendingPathComponent("clip.mp4"), song = dir.appendingPathComponent("song.wav")
        let photo = dir.appendingPathComponent("photo.png"), sheet = dir.appendingPathComponent("doc.pdf")

        let quiet = Recorder()
        FFmpegHelper.shared = FFmpegHelper(config: testConfig(root: dir.appendingPathComponent("unused"), base: URL(string: "http://127.0.0.1:9/")!,
                                                              build: Kit.sampleBuild, ui: quiet))
        let audio = OutputFormat.targets(for: .audio, source: "wav"), video = OutputFormat.targets(for: .video, source: "mov")
        c.check("no ffmpeg, but it can be fetched: sounds still get MP3, M4A, FLAC, OGG and Opus",
                [.mp3, .m4a, .flac, .ogg, .opus].allSatisfy(audio.contains), "\(audio)")
        c.check("…videos MP4, WebM, GIF and MP3", [.mp4, .webm, .gif, .mp3].allSatisfy(video.contains), "\(video)")
        c.check("…the built-in video tools", FileTool.tools(for: [clip]) == [.compress, .stripMetadata, .mute, .extractAudio, .normalize])
        let tools = Registry.commands(for: .tools, files: [clip]).map(\.id)
        c.check("…and the media petals (Trim, Crop, Split…)", ["trim", "crop-video", "split", "speed"].allSatisfy(tools.contains), "\(tools)")
        c.check("…WMA, AVI and WMV", ["wma"].allSatisfy(Registry.commands(for: .convert, files: [song]).map(\.id).contains)
                    && ["avi", "wmv"].allSatisfy(Registry.commands(for: .convert, files: [clip]).map(\.id).contains))
        c.check("WebP is offered for pictures (cwebp, or the helper’s libwebp)", Capabilities.shared.canWrite(.webp, from: .image))
        let trim = Registry.commands.first { $0.id == "trim" }!, channels = Registry.commands.first { $0.id == "channels" }!
        let zip = Registry.commands.first { $0.id == "zip" && $0.wheel == .convert }!, float = Registry.commands.first { $0.id == "float" }!
        let resize = Registry.commands.first { $0.id == "resize" }!
        c.check("an editor (Trim) or a question (Channels) on audio or video waits for the helper first",
                FFmpegHelper.mustWaitBefore(trim, files: [clip]) && FFmpegHelper.mustWaitBefore(channels, files: [song]))
        c.check("ZIP, Float and picture tools never wait for it",
                !FFmpegHelper.mustWaitBefore(zip, files: [clip]) && !FFmpegHelper.mustWaitBefore(float, files: [clip])
                    && !FFmpegHelper.mustWaitBefore(resize, files: [photo]))
        c.check("a missing ffmpeg is what the helper cures; other errors aren’t",
                FFmpegHelper.canProvide(ConversionError.missingTool("ffmpeg")) && FFmpegHelper.canProvide(ConversionError.missingTool("cwebp"))
                    && !FFmpegHelper.canProvide(ConversionError.missingTool("img2webp")) && !FFmpegHelper.canProvide(ConversionError.unreadable("x")))
        c.check("an error that slips past says the helper isn’t here yet, not “install it with Homebrew”",
                ConversionError.missingTool("ffmpeg").localizedDescription == FFmpegHelperText.notYet)

        FFmpegHelper.shared = FFmpegHelper(config: FFmpegHelper.Config.app(arguments: ["DropWheel", "--selftest"], environment: [:]))
        c.check("no ffmpeg and none to fetch: no audio or video petals, as before",
                OutputFormat.targets(for: .audio, source: "wav").isEmpty && FileTool.tools(for: [clip]).isEmpty
                    && !Registry.commands(for: .tools, files: [clip]).contains { $0.id == "trim" })
        c.check("…and the old message", ConversionError.missingTool("ffmpeg").localizedDescription.contains("Homebrew")
                    && !FFmpegHelper.mustWaitBefore(trim, files: [clip]))
        c.check("PDFs keep their petals either way", !FileTool.tools(for: [sheet]).isEmpty)
    }

    // MARK: Snapshots

    private static let snapshotRecorder = Recorder()

    /// Puts the ffmpeg row of About in `state` for `--snapshot helper-about` (in memory only; the process ends after).
    static func stage(_ state: String, fraction: Double, reason: String = "offline") {
        let build = FFmpegHelperBuild(version: "8.0.1", fileName: "ffmpeg-8.0.1-macos-arm64.zip", length: 11_489_831,
                                      sha256: String(repeating: "0", count: 64))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YummyOrange helper snapshot", isDirectory: true)
        var config = testConfig(root: root, base: URL(string: "http://127.0.0.1:9/")!, build: build, ui: snapshotRecorder, current: { nil })
        config.enabled = state != "unavailable"
        let helper = FFmpegHelper(config: config)
        FFmpegHelper.shared = helper
        let none = Capabilities.FFmpegProbe(found: nil, encoders: [], filters: [])
        switch state {
        case "user":
            if let found = FFmpegLookup.find(userFolders: FFmpegLookup.userFolders(), hideUser: false, helpers: root, pinned: "x") {
                Capabilities.shared.swapFFmpegProbe(Capabilities.FFmpegProbe(found: found, encoders: [], filters: []))
            }
        case "ours":
            let folder = FFmpegLookup.defaultRoot().appendingPathComponent(build.folderName, isDirectory: true)
            let found = FFmpegLookup.Found(ffmpeg: folder.appendingPathComponent("ffmpeg"), source: .helper(version: build.version))
            AboutInfo.remember(ffmpegVersionOutput: "ffmpeg version 8.0.1 Copyright (c) 2000-2025 the FFmpeg developers\nconfiguration: --enable-version3\n",
                               path: found.ffmpeg.path)
            Capabilities.shared.swapFFmpegProbe(Capabilities.FFmpegProbe(found: found, encoders: ["libwebp"], filters: []))
        case "downloading":
            Capabilities.shared.swapFFmpegProbe(none)
            helper.stage(.downloading(fraction < 0 ? nil : fraction))
        case "installing":
            Capabilities.shared.swapFFmpegProbe(none)
            helper.stage(.installing)
        case "failed":
            Capabilities.shared.swapFFmpegProbe(none)
            let reasons = ["offline": FFmpegHelperText.offline, "damaged": FFmpegHelperText.damaged, "space": FFmpegHelperText.noSpace,
                           "folder": FFmpegHelperText.cannotSave]
            helper.stage(.failed, failure: reasons[reason] ?? FFmpegHelperText.offline)
        default:   // missing, unavailable
            Capabilities.shared.swapFFmpegProbe(none)
        }
    }

    // MARK: Downloads

    /// Records what a waiting task would see in the HUD.
    final class Recorder {
        var progress: [String] = []
        var failures: [String] = []
        var ready = 0
        var ui: FFmpegHelper.UI {
            FFmpegHelper.UI(progress: { [weak self] text, _ in self?.progress.append(text) },
                            failed: { [weak self] text in self?.failures.append(text) },
                            ready: { [weak self] in self?.ready += 1 })
        }
    }

    static func testConfig(root: URL, base: URL, build: FFmpegHelperBuild, ui: Recorder, defaults: UserDefaults = SettingsMemoryStore(),
                           current: (() -> FFmpegLookup.Found?)? = nil, jobsRunning: Bool = false) -> FFmpegHelper.Config {
        FFmpegHelper.Config(build: build, baseURL: base, root: root, userAgent: "YummyOrange/selftest", enabled: true,
                            allowsLoopbackHTTP: true, defaults: { defaults },
                            current: current ?? { FFmpegLookup.helper(in: root, pinned: build.version) },
                            didInstall: { _ in }, jobsRunning: { jobsRunning }, ui: ui.ui, whenOnline: { $0() })
    }

    /// Stand-in programs, their ZIPs, and a server for them.
    final class Kit {
        let dir: URL
        let helpers: URL
        let server: UpdaterTests.LocalServer
        let good: FFmpegHelperBuild, flat: FFmpegHelperBuild, broken: FFmpegHelperBuild, noFFmpeg: FFmpegHelperBuild
        let notZip: FFmpegHelperBuild, truncated: FFmpegHelperBuild
        static let sampleBuild = FFmpegHelperBuild(version: "9.9-test", fileName: "good.zip", length: 1, sha256: String(repeating: "0", count: 64))

        var base: URL { URL(string: "http://127.0.0.1:\(server.port)/downloads/helpers/")! }
        /// The same files, each after 1.5 s (the server's /slow/ rule), so a download is still running when more ask.
        var slowBase: URL { URL(string: "http://127.0.0.1:\(server.port)/slow/downloads/helpers/")! }

        init?(_ dir: URL) {
            self.dir = dir
            let fm = FileManager.default
            let site = dir.appendingPathComponent("site", isDirectory: true)
            let helpers = site.appendingPathComponent("downloads/helpers", isDirectory: true)
            self.helpers = helpers
            let work = dir.appendingPathComponent("work", isDirectory: true)
            try? fm.createDirectory(at: helpers, withIntermediateDirectories: true)
            try? fm.createDirectory(at: work, withIntermediateDirectories: true)
            let version = "9.9-test"
            func zip(_ name: String, keepParent: Bool, ffmpegRuns: Bool = true, hasFFmpeg: Bool = true) -> FFmpegHelperBuild? {
                let folder = work.appendingPathComponent(name, isDirectory: true).appendingPathComponent("ffmpeg-\(version)", isDirectory: true)
                if hasFFmpeg {
                    Kit.programs(in: folder, version: version, runs: ffmpegRuns)
                } else {
                    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                }
                fm.createFile(atPath: folder.appendingPathComponent("LICENSE.md").path, contents: Data("# Licences\n".utf8))
                let out = Kit.dirZip(folder, to: helpers.appendingPathComponent("\(name).zip"), keepParent: keepParent)
                return out.flatMap { Kit.build(of: $0, version: version) }
            }
            guard let good = zip("good", keepParent: true), let flat = zip("flat", keepParent: false),
                  let broken = zip("broken", keepParent: true, ffmpegRuns: false), let noFFmpeg = zip("noffmpeg", keepParent: true, hasFFmpeg: false),
                  let goodBytes = fm.contents(atPath: helpers.appendingPathComponent("good.zip").path) else { return nil }
            let junk = helpers.appendingPathComponent("junk.zip")
            guard fm.createFile(atPath: junk.path, contents: Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })),
                  let notZip = Kit.build(of: junk, version: version) else { return nil }
            guard fm.createFile(atPath: helpers.appendingPathComponent("truncated.zip").path, contents: goodBytes.prefix(goodBytes.count / 2)) else { return nil }
            var truncated = good
            truncated.fileName = "truncated.zip"
            (self.good, self.flat, self.broken, self.noFFmpeg, self.notZip, self.truncated) = (good, flat, broken, noFFmpeg, notZip, truncated)
            guard let server = UpdaterTests.LocalServer(serving: site, redirecting: true) else { return nil }
            self.server = server
        }

        /// An ffmpeg that answers "-version" like the real one (or, `runs: false`, one that fails; `complete: false`, one
        /// without its x bit, as a damaged copy may have).
        static func programs(in folder: URL, version: String, runs: Bool = true, complete: Bool = true) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let answer = """
                if [ "$1" = "-version" ]; then
                  echo "ffmpeg version \(version) Copyright (c) the YummyOrange self-test"
                  echo "configuration: --enable-version3 --enable-libmp3lame"
                  exit 0
                fi
                exit 1
                """
            script(folder.appendingPathComponent("ffmpeg"), runs ? answer : "exit 3", executable: complete)
        }

        /// `folder` zipped by ditto, as the release step does: with the folder at the top, or its contents.
        static func dirZip(_ folder: URL, to zip: URL, keepParent: Bool) -> URL? {
            let args = ["-c", "-k"] + (keepParent ? ["--keepParent"] : []) + [folder.path, zip.path]
            guard (try? ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), args))?.status == 0 else { return nil }
            return zip
        }

        static func build(of zip: URL, version: String) -> FFmpegHelperBuild? {
            guard let sha = try? UpdateArchiveCheck.sha256(of: zip),
                  let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.intValue else { return nil }
            return FFmpegHelperBuild(version: version, fileName: zip.lastPathComponent, length: size, sha256: sha)
        }

        /// A fresh, empty Helpers folder.
        func root(_ name: String) -> URL {
            let url = dir.appendingPathComponent("roots/\(name)/Helpers", isDirectory: true)
            try? FileManager.default.removeItem(at: url)
            return url
        }
    }

    static func script(_ url: URL, _ body: String, executable: Bool = true) {
        FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n\(body)\n".utf8),
                                       attributes: [.posixPermissions: executable ? 0o755 : 0o644])
    }

    /// What a Helpers folder holds.
    static func contents(_ root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    static func installs(_ c: Checker, _ kit: Kit) {
        let fm = FileManager.default
        let root = kit.root("good")
        let recorder = Recorder()
        var fractions: [Double] = []
        var unpacked = false
        do {
            let folder = try FFmpegHelper.install(testConfig(root: root, base: kit.base, build: kit.good, ui: recorder),
                                                  progress: { fractions.append($0) }, unpacking: { unpacked = true })
            c.check("a good download installs into Helpers/ffmpeg-<version>, with nothing else left",
                    folder.lastPathComponent == "ffmpeg-9.9-test" && contents(root) == ["ffmpeg-9.9-test"] && FFmpegLookup.isComplete(folder),
                    "\(contents(root))")
            c.check("…found there by the lookup, with the ZIP’s license file beside it",
                    FFmpegLookup.helper(in: root, pinned: "9.9-test")?.ffmpeg == folder.appendingPathComponent("ffmpeg")
                        && FileManager.default.fileExists(atPath: folder.appendingPathComponent("LICENSE.md").path))
            c.check("…progress reached the whole file, and unpacking came after", fractions.last == 1 && unpacked, "\(fractions)")
            let about = AboutInfo.ffmpeg(atPath: folder.appendingPathComponent("ffmpeg").path)
            c.check("…and About already knows its version and license", about?.version == "version 9.9-test" && about?.license == "LGPL 3 build",
                    "\(String(describing: about))")
        } catch {
            c.check("a good download installs", false, error.localizedDescription)
        }

        let flatRoot = kit.root("flat")
        c.check("a ZIP with the programs at its top installs too",
                (try? FFmpegHelper.install(testConfig(root: flatRoot, base: kit.base, build: kit.flat, ui: recorder)))
                    .map(FFmpegLookup.isComplete) == true && contents(flatRoot) == ["ffmpeg-9.9-test"], "\(contents(flatRoot))")

        // Older versions and leftovers go.
        let upgrade = kit.root("upgrade")
        Kit.programs(in: upgrade.appendingPathComponent("ffmpeg-0.1", isDirectory: true), version: "0.1")
        Kit.programs(in: upgrade.appendingPathComponent("ffmpeg-0.2", isDirectory: true), version: "0.2", complete: false)
        let stale = upgrade.appendingPathComponent(".staging-old", isDirectory: true)
        let fresh = upgrade.appendingPathComponent(".staging-fresh", isDirectory: true)
        try? fm.createDirectory(at: stale, withIntermediateDirectories: true)
        try? fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: stale.path)
        _ = try? FFmpegHelper.install(testConfig(root: upgrade, base: kit.base, build: kit.good, ui: recorder))
        c.check("after a good install the older version folders are gone (and a staging folder left 2 hours ago; a fresh one stays)",
                contents(upgrade) == [".staging-fresh", "ffmpeg-9.9-test"], "\(contents(upgrade))")

        // The folder of the ffmpeg in use stays while a job may be running it.
        let busy = kit.root("busy")
        Kit.programs(in: busy.appendingPathComponent("ffmpeg-0.1", isDirectory: true), version: "0.1")
        let inUse = FFmpegLookup.helper(in: busy, pinned: "0.1")
        _ = try? FFmpegHelper.install(testConfig(root: busy, base: kit.base, build: kit.good, ui: recorder, current: { inUse }, jobsRunning: true))
        c.check("an older copy a running job may be using stays…", contents(busy) == ["ffmpeg-0.1", "ffmpeg-9.9-test"], "\(contents(busy))")
        FFmpegHelper.tidy(busy, keeping: FFmpegLookup.helper(in: busy, pinned: "9.9-test"), jobsRunning: false, now: Date())
        c.check("…until the next launch tidies it away", contents(busy) == ["ffmpeg-9.9-test"], "\(contents(busy))")
        let user = FFmpegLookup.Found(ffmpeg: URL(fileURLWithPath: "/usr/local/bin/ffmpeg"), source: .user)
        FFmpegHelper.tidy(busy, keeping: user, jobsRunning: false, now: Date())
        c.check("the person’s own ffmpeg in use: YummyOrange’s copy is kept", contents(busy) == ["ffmpeg-9.9-test"])

        // Staging folders an attempt left when YummyOrange quit go at the next launch, whichever ffmpeg is in use.
        let sweep = kit.root("sweep")
        for (name, age) in [(".staging-old", -7200.0), (".staging-fresh", -60.0)] {
            let url = sweep.appendingPathComponent(name, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(age)], ofItemAtPath: url.path)
        }
        FFmpegHelper.tidy(sweep, keeping: nil, jobsRunning: false, now: Date())
        let afterNone = contents(sweep)
        let older = sweep.appendingPathComponent(".staging-older", isDirectory: true)
        try? fm.createDirectory(at: older, withIntermediateDirectories: true)
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: older.path)
        FFmpegHelper.tidy(sweep, keeping: user, jobsRunning: false, now: Date())
        c.check("a staging folder left over an hour ago goes with no ffmpeg in use, or the person’s own (a fresh one stays)",
                afterNone == [".staging-fresh"] && contents(sweep) == [".staging-fresh"], "\(afterNone) then \(contents(sweep))")

        // A damaged copy of the same version is replaced.
        let damaged = kit.root("damaged")
        Kit.programs(in: damaged.appendingPathComponent("ffmpeg-9.9-test", isDirectory: true), version: "9.9-test", complete: false)
        let replaced = try? FFmpegHelper.install(testConfig(root: damaged, base: kit.base, build: kit.good, ui: recorder))
        c.check("a damaged copy of the same version is replaced in one step", replaced.map(FFmpegLookup.isComplete) == true
                    && contents(damaged) == ["ffmpeg-9.9-test"], "\(contents(damaged))")

        // A link at the install path, even one to nothing (a folder on a drive that is gone), is moved aside too.
        let dangling = kit.root("dangling")
        try? fm.createDirectory(at: dangling, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: dangling.appendingPathComponent("ffmpeg-9.9-test").path, withDestinationPath: "/nonexistent/YummyOrange/ffmpeg")
        let overLink = try? FFmpegHelper.install(testConfig(root: dangling, base: kit.base, build: kit.good, ui: recorder))
        let isFolder = (try? fm.attributesOfItem(atPath: dangling.appendingPathComponent("ffmpeg-9.9-test").path)[.type] as? FileAttributeType) == .typeDirectory
        c.check("a dangling link where the copy goes is replaced by the real folder", overLink.map(FFmpegLookup.isComplete) == true && isFolder
                    && contents(dangling) == ["ffmpeg-9.9-test"], "\(contents(dangling))")

        // The app switches to the new copy before the old one goes, so no job starts on a folder about to vanish.
        let switching = kit.root("switch")
        let old = switching.appendingPathComponent("ffmpeg-0.1", isDirectory: true)
        Kit.programs(in: old, version: "0.1")
        var oldThereAtSwitch = false
        var switchConfig = testConfig(root: switching, base: kit.base, build: kit.good, ui: recorder)
        switchConfig.didInstall = { _ in oldThereAtSwitch = fm.fileExists(atPath: old.path) }
        _ = try? FFmpegHelper.install(switchConfig)
        c.check("upgrading: the app uses the new copy first, then the old one is removed",
                oldThereAtSwitch && contents(switching) == ["ffmpeg-9.9-test"], "\(contents(switching))")

        // A newer copy (a newer YummyOrange put it there) stays; an older or broken one goes.
        let newer = kit.root("newer")
        Kit.programs(in: newer.appendingPathComponent("ffmpeg-99.0", isDirectory: true), version: "99.0")
        Kit.programs(in: newer.appendingPathComponent("ffmpeg-100.0", isDirectory: true), version: "100.0", complete: false)
        Kit.programs(in: newer.appendingPathComponent("ffmpeg-1.0", isDirectory: true), version: "1.0")
        var newerConfig = testConfig(root: newer, base: kit.base, build: kit.good, ui: recorder)
        newerConfig.current = { nil }
        _ = try? FFmpegHelper.install(newerConfig)
        c.check("a newer copy is kept beside this one’s; older and broken ones go",
                contents(newer) == ["ffmpeg-9.9-test", "ffmpeg-99.0"], "\(contents(newer))")
    }

    static func refusals(_ c: Checker, _ kit: Kit) {
        let recorder = Recorder()
        /// `says`: the message the HUD and About give for it.
        func refuses(_ name: String, _ build: FFmpegHelperBuild, base: URL? = nil, loopback: Bool = true, root: URL? = nil,
                     says: String = FFmpegHelperText.damaged, tweak: (inout FFmpegHelper.Config) -> Void = { _ in },
                     _ expected: (Error) -> Bool) {
            let root = root ?? kit.root(name.filter(\.isLetter))
            var config = testConfig(root: root, base: base ?? kit.base, build: build, ui: recorder)
            config.allowsLoopbackHTTP = loopback
            tweak(&config)
            do {
                _ = try FFmpegHelper.install(config)
                c.check(name, false, "it installed")
            } catch {
                let message = FFmpegHelperText.message(for: error)
                c.check(name, expected(error) && contents(root).isEmpty && message == says,
                        "\(error.localizedDescription); says “\(message)”; left \(contents(root))")
            }
        }
        var wrongSum = kit.good
        wrongSum.sha256 = String(wrongSum.sha256.reversed())
        refuses("a wrong SHA-256 installs nothing and leaves no file", wrongSum) { ($0 as? UpdateError) == .wrongChecksum }
        var longer = kit.good
        longer.length += 1
        refuses("a file shorter than the pinned length installs nothing", longer) {
            ($0 as? UpdateError) == .wrongLength(expected: longer.length, actual: kit.good.length)
        }
        var shorter = kit.good
        shorter.length -= 1
        refuses("a file longer than the pinned length is cut off and installs nothing", shorter) { ($0 as? UpdateError) == .tooLarge }
        refuses("a truncated download installs nothing", kit.truncated) {
            if case .wrongLength(let expected, let actual)? = $0 as? UpdateError { return expected == kit.good.length && actual < expected }
            return false
        }
        var missing = kit.good
        missing.fileName = "missing.zip"
        refuses("an HTTP error (404) installs nothing", missing) { ($0 as? UpdateError) == .server(404) }
        let nobody = URL(string: "http://127.0.0.1:\(UpdaterTests.LocalServer.freePort() ?? 9)/downloads/helpers/")!
        refuses("no server at all installs nothing, and says to check the connection", kit.good, base: nobody, says: FFmpegHelperText.offline) {
            if case .network? = $0 as? UpdateError { return true }
            return false
        }
        refuses("plain HTTP elsewhere is refused before connecting", kit.good, base: URL(string: "http://yummyorange.invalid/downloads/helpers/")!,
                loopback: false) { ($0 as? UpdateError) == .insecureURL("http://yummyorange.invalid/downloads/helpers/good.zip") }
        refuses("a file that isn’t a ZIP (checksum right) installs nothing", kit.notZip) {
            if case .badArchive? = $0 as? FFmpegHelperError { return true }
            return false
        }
        refuses("a ZIP without ffmpeg installs nothing", kit.noFFmpeg) { ($0 as? FFmpegHelperError) == .badArchive("it holds no ffmpeg") }
        refuses("an ffmpeg that doesn’t run installs nothing", kit.broken) { ($0 as? FFmpegHelperError) == .doesNotRun("ffmpeg") }
        var placeholder = kit.good
        placeholder.sha256 = "PLACEHOLDER"
        refuses("the placeholder build downloads nothing", placeholder) { ($0 as? FFmpegHelperError) == .notAvailable }
        refuses("too little free space: nothing is fetched, and it says to free up space", kit.good, says: FFmpegHelperText.noSpace,
                tweak: { $0.freeSpace = { _ in FFmpegHelperPolicy.spaceNeeded(forDownload: kit.good.length) - 1 } }) {
            ($0 as? FFmpegHelperError) == .noSpace
        }
        let blocker = kit.dir.appendingPathComponent("not-a-folder")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        refuses("a Helpers folder that can’t be made: nothing is fetched, and it names the folder", kit.good,
                root: blocker.appendingPathComponent("Helpers", isDirectory: true), says: FFmpegHelperText.cannotSave) {
            if case .cannotPlace? = $0 as? FFmpegHelperError { return true }
            return false
        }

        let hang = kit.dir.appendingPathComponent("hang", isDirectory: true)
        try? FileManager.default.createDirectory(at: hang, withIntermediateDirectories: true)
        script(hang.appendingPathComponent("ffmpeg"), "sleep 30")
        let start = Date()
        var timedOut = false
        do { _ = try FFmpegHelper.checkProgram(in: hang, timeout: 1) } catch { timedOut = (error as? FFmpegHelperError) == .doesNotRun("ffmpeg") }
        let took = Date().timeIntervalSince(start)
        c.check("a program that doesn’t answer “-version” in time counts as not running (and is stopped)", timedOut && took < 6,
                String(format: "%.1f s", took))
        // A program that answers and exits but leaves a child holding its output open: the answer comes at once.
        let forks = kit.dir.appendingPathComponent("forks", isDirectory: true)
        try? FileManager.default.createDirectory(at: forks, withIntermediateDirectories: true)
        script(forks.appendingPathComponent("ffmpeg"), "sleep 6 &\necho \"ffmpeg version 1 Copyright (c) the YummyOrange self-test\"\nexit 0")
        let forkStart = Date()
        let answer = FFmpegHelper.run(forks.appendingPathComponent("ffmpeg"), ["-version"], timeout: 3)
        let forkTook = Date().timeIntervalSince(forkStart)
        c.check("a child process left holding the output doesn’t hold the check past its time limit",
                answer?.status == 0 && answer?.output.hasPrefix("ffmpeg version 1") == true && forkTook < 2.5, String(format: "%.1f s", forkTook))
    }

    /// Spins the main run loop until `done` or `timeout` seconds.
    @discardableResult
    static func spin(_ timeout: TimeInterval, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        return done()
    }

    static func sharing(_ c: Checker, _ kit: Kit) {
        let root = kit.root("shared")
        let recorder = Recorder()
        let defaults = SettingsMemoryStore(["ffmpegHelperFailures": 1, "ffmpegHelperLastFailure": Date().timeIntervalSince1970])
        let helper = FFmpegHelper(config: testConfig(root: root, base: kit.slowBase, build: kit.good, ui: recorder, defaults: defaults))
        var first = 0, second = 0
        helper.whenAvailable { first += 1 }
        helper.whenAvailable { second += 1 }
        let startedOnce = helper.attempts == 1
        helper.fetch(automatic: true)
        helper.fetch()
        c.check("two waiting tasks share one download, and asking again while it runs starts no second one",
                startedOnce && helper.attempts == 1 && first == 0 && second == 0, "attempts \(helper.attempts)")
        c.check("the HUD says so at once", recorder.progress.first == "Downloading ffmpeg for audio and video…", "\(recorder.progress)")
        spin(30) { first + second == 2 }
        c.check("both run once it is installed, after the HUD line is put away (once)", first == 1 && second == 1 && helper.phase == .idle
                    && contents(root) == ["ffmpeg-9.9-test"] && recorder.ready == 1,
                "first \(first), second \(second), \(helper.phase), \(contents(root)), HUD put away \(recorder.ready)×")
        // Each task that joins shows the line again (its own job title had just replaced it in the HUD).
        c.check("the HUD showed the percentage as it came in",
                recorder.progress.allSatisfy { $0 == FFmpegHelperText.getting || ($0.hasPrefix(FFmpegHelperText.getting + " ") && $0.hasSuffix("%")) }
                    && recorder.progress.last == "Downloading ffmpeg for audio and video… 100%", "\(recorder.progress)")
        c.check("a good install clears the failure count", helper.failures == 0 && helper.lastFailure == nil)
        var third = 0
        helper.whenAvailable { third += 1 }
        c.check("once it is here, a task runs at once without a download", third == 1 && helper.attempts == 1)

        // A failed download: waiting tasks don't run, the HUD says what to do, nothing is left, the next attempt retries.
        let badRoot = kit.root("shared-bad")
        var wrong = kit.good
        wrong.sha256 = String(wrong.sha256.reversed())
        let badRecorder = Recorder()
        let badDefaults = SettingsMemoryStore()
        let bad = FFmpegHelper(config: testConfig(root: badRoot, base: kit.slowBase, build: wrong, ui: badRecorder, defaults: badDefaults))
        var ran = 0
        var told: [String] = []
        bad.whenAvailable({ ran += 1 }, otherwise: { told.append($0) })
        bad.whenAvailable { ran += 1 }
        spin(30) { bad.phase == .failed }
        c.check("a failed download (a wrong checksum) runs neither task; the one that asked gets the message, the HUD says it once for the other",
                ran == 0 && told == [FFmpegHelperText.damaged] && badRecorder.failures == [FFmpegHelperText.damaged] && bad.attempts == 1
                    && badRecorder.ready == 0,
                "ran \(ran), told \(told), HUD \(badRecorder.failures)")
        let badRow = FFmpegRow.make(found: nil, tool: AboutInfo.Tool(), phase: bad.phase, failure: bad.failure, canFetch: true,
                                    downloadSize: wrong.length)
        c.check("…About says the same, as a problem", bad.failure == FFmpegHelperText.damaged && badRow.status == FFmpegHelperText.damaged
                    && badRow.isProblem && badRow.trailing == .download, "\(badRow)")
        c.check("…nothing is left in Helpers", contents(badRoot).isEmpty, "\(contents(badRoot))")
        c.check("…and the failure is counted for the backoff", bad.failures == 1 && bad.lastFailure != nil)
        bad.whenAvailable { ran += 1 }
        c.check("the next attempt starts over", bad.attempts == 2)
        spin(30) { bad.phase == .failed }
        c.check("…and is counted too", bad.failures == 2 && ran == 0)
    }

    static func cancel(_ c: Checker, _ kit: Kit) {
        let root = kit.root("cancel")
        let recorder = Recorder()
        let helper = FFmpegHelper(config: testConfig(root: root, base: kit.slowBase, build: kit.good, ui: recorder))
        var ran = 0
        var told: [String] = []
        helper.whenAvailable({ ran += 1 }, otherwise: { told.append($0) })
        var downloading = false
        if case .downloading = helper.phase { downloading = true }
        helper.cancel()
        spin(30) { helper.phase == .idle }
        c.check("Cancel stops the download: the waiting task is told it was canceled, nothing is installed or left",
                downloading && ran == 0 && told == [FFmpegHelperText.canceled] && helper.phase == .idle && contents(root).isEmpty,
                "ran \(ran), told \(told), \(helper.phase), left \(contents(root))")
        c.check("…it isn’t a failure: nothing counted for the backoff, no problem shown",
                helper.failures == 0 && helper.lastFailure == nil && helper.failure == nil)
        let row = FFmpegRow.make(found: nil, tool: AboutInfo.Tool(), phase: helper.phase, failure: helper.failure, canFetch: true,
                                 downloadSize: kit.good.length)
        c.check("…and About offers Download again", row.trailing == .download && !row.isProblem, "\(row)")
        helper.whenAvailable { ran += 1 }
        spin(30) { ran == 1 }
        c.check("the next download after a cancel installs", ran == 1 && contents(root) == ["ffmpeg-9.9-test"] && helper.attempts == 2,
                "ran \(ran), \(contents(root))")
        helper.cancel()
        c.check("Cancel with no download under way does nothing", helper.phase == .idle && helper.attempts == 2)
    }

    static func automatic(_ c: Checker, _ kit: Kit) {
        let root = kit.root("auto")
        let recorder = Recorder()
        let helper = FFmpegHelper(config: testConfig(root: root, base: kit.base, build: kit.good, ui: recorder))
        helper.attemptAutomatically()
        helper.attemptAutomatically()
        c.check("the quiet attempt starts once per launch", helper.attempts == 1 && helper.triedAutomatically)
        spin(30) { helper.phase == .idle }
        c.check("…installs without a word in the HUD", contents(root) == ["ffmpeg-9.9-test"] && recorder.progress.isEmpty && recorder.failures.isEmpty
                    && recorder.ready == 0,
                "\(contents(root)) \(recorder.progress)")
        c.check("…and isn’t needed any more", !helper.isNeeded)

        let now = Date()
        let backingOff = FFmpegHelper(config: testConfig(root: kit.root("auto-wait"), base: kit.base, build: kit.good, ui: recorder,
                                                         defaults: SettingsMemoryStore(["ffmpegHelperFailures": 2,
                                                                                        "ffmpegHelperLastFailure": now.addingTimeInterval(-600).timeIntervalSince1970])))
        backingOff.attemptAutomatically()
        c.check("after 2 failures, the last 10 minutes ago, the quiet attempt waits", backingOff.attempts == 0)
        let user = FFmpegLookup.Found(ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), source: .user)
        let hasOwn = FFmpegHelper(config: testConfig(root: kit.root("auto-own"), base: kit.base, build: kit.good, ui: recorder, current: { user }))
        hasOwn.attemptAutomatically()
        c.check("a Mac with its own ffmpeg downloads nothing", hasOwn.attempts == 0 && !hasOwn.isNeeded)
        let old = FFmpegLookup.Found(ffmpeg: URL(fileURLWithPath: "/x/ffmpeg-0.1/ffmpeg"), source: .helper(version: "0.1"))
        let outdated = FFmpegHelper(config: testConfig(root: kit.root("auto-old"), base: kit.base, build: kit.good, ui: recorder, current: { old }))
        c.check("an older copy of YummyOrange’s own is replaced quietly", outdated.isNeeded)
        let newer = FFmpegLookup.Found(ffmpeg: URL(fileURLWithPath: "/x/ffmpeg-99.0/ffmpeg"), source: .helper(version: "99.0"))
        let later = FFmpegHelper(config: testConfig(root: kit.root("auto-newer"), base: kit.base, build: kit.good, ui: recorder, current: { newer }))
        c.check("a newer copy (from a newer YummyOrange) is good enough: nothing is downloaded over it", !later.isNeeded)
        var offline: (() -> Void)?
        var waitingConfig = testConfig(root: kit.root("auto-offline"), base: kit.base, build: kit.good, ui: recorder)
        waitingConfig.whenOnline = { offline = $0 }
        let waitsForNetwork = FFmpegHelper(config: waitingConfig)
        waitsForNetwork.attemptAutomatically()
        let heldBack = waitsForNetwork.attempts == 0
        offline?()
        c.check("offline, the quiet attempt waits for the network, then starts", heldBack && waitsForNetwork.attempts == 1)
        spin(30) { waitsForNetwork.phase == .idle }
    }

    /// JobRunner on a Mac without ffmpeg: the job waits for the helper, then converts (with the person's real ffmpeg
    /// standing in for the downloaded one, as the stand-in programs can't convert anything).
    static func jobs(_ c: Checker, _ kit: Kit) {
        guard let real = FFmpegLookup.find(userFolders: FFmpegLookup.userFolders(), hideUser: false, helpers: kit.root("none"), pinned: "x"),
              case .user = real.source else {
            c.notes.append("JobRunner check skipped: this Mac has no ffmpeg of its own to stand in for the helper")
            return
        }
        let fm = FileManager.default
        let media = kit.dir.appendingPathComponent("media", isDirectory: true)
        try? fm.createDirectory(at: media, withIntermediateDirectories: true)
        let tones = ["tone-a.wav", "tone-b.wav", "tone-c.wav"].map { media.appendingPathComponent($0) }
        for tone in tones {
            _ = try? ProcessRunner.run(real.ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "lavfi",
                                                     "-i", "sine=frequency=440:duration=0.4", tone.path])
        }
        guard tones.allSatisfy({ fm.fileExists(atPath: $0.path) }) else {
            c.check("test sounds made with ffmpeg", false)
            return
        }
        let realProbe = Capabilities.FFmpegProbe(real)
        let saved = Capabilities.shared.swapFFmpegProbe(Capabilities.FFmpegProbe(found: nil, encoders: [], filters: []))
        let savedHelper = FFmpegHelper.shared
        let savedHUD = JobRunner.reportToHUD
        var reports: [(saved: [URL], errors: [String])] = []
        JobRunner.reportToHUD = { reports.append(($0, $1)) }
        defer {
            Capabilities.shared.swapFFmpegProbe(saved)
            FFmpegHelper.shared = savedHelper
            JobRunner.reportToHUD = savedHUD
        }

        let recorder = Recorder()
        var config = testConfig(root: kit.root("jobs"), base: kit.slowBase, build: kit.good, ui: recorder, current: { Capabilities.shared.ffmpegFound })
        config.didInstall = { _ in Capabilities.shared.swapFFmpegProbe(realProbe) }   // "installed": the real ffmpeg is now in use
        let helper = FFmpegHelper(config: config)
        FFmpegHelper.shared = helper
        JobRunner.run(.convert(.mp3), on: [tones[0]])
        JobRunner.run(.convert(.mp3), on: [tones[1]])
        spin(60) { reports.count == 2 }
        let outputs = reports.flatMap(\.saved)
        c.check("two conversions started without ffmpeg wait for one download, then both run",
                reports.count == 2 && reports.allSatisfy { $0.errors.isEmpty } && outputs.count == 2
                    && outputs.allSatisfy { $0.pathExtension == "mp3" && fm.fileExists(atPath: $0.path) } && helper.attempts == 1,
                "\(reports.map { "\($0.saved.map(\.lastPathComponent)) \($0.errors)" }) attempts \(helper.attempts)")
        c.check("…with the helper’s progress shown meanwhile", recorder.progress.first == FFmpegHelperText.getting, "\(recorder.progress)")
        c.check("…and nothing counted as running afterwards", spin(5) { JobRunner.runningCount == 0 })

        // The download fails: the job reports it like any error and saves nothing.
        Capabilities.shared.swapFFmpegProbe(Capabilities.FFmpegProbe(found: nil, encoders: [], filters: []))
        var wrong = kit.good
        wrong.sha256 = String(wrong.sha256.reversed())
        let badRecorder = Recorder()
        FFmpegHelper.shared = FFmpegHelper(config: testConfig(root: kit.root("jobs-bad"), base: kit.base, build: wrong, ui: badRecorder,
                                                              current: { Capabilities.shared.ffmpegFound }))
        reports = []
        JobRunner.run(.convert(.mp3), on: [tones[2]])
        spin(60) { reports.count == 1 }
        c.check("when the helper can’t be got, the job says so and saves nothing",
                reports.count == 1 && reports[0].saved.isEmpty && reports[0].errors == [FFmpegHelperText.damaged]
                    && badRecorder.failures.isEmpty && spin(5) { JobRunner.runningCount == 0 },
                "\(reports.map { "\($0.saved) \($0.errors)" }) HUD \(badRecorder.failures)")
    }
}
#endif
