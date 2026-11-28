import AppKit
import CryptoKit
import WebKit

// Links on the wheel. A YouTube, X, Instagram, TikTok or Threads address dragged out of a browser (its address bar, or
// a link or thumbnail on a page) opens the Convert wheel like a file does, with MP4, MP3, M4A and WAV. Dropping it on
// a petal downloads the post and saves the new file in Downloads.
//
//   the drag    DragMonitor and the wheel read a supported web link off the drag pasteboard when it holds no files,
//               and stand it in as a small .webloc file in the temporary folder (`LinkFiles`), so the wheel, jobs and
//               the command line handle it like any other file. A .webloc dragged from Finder works the same way and
//               saves next to itself.
//   the fetch   Threads: the post page loads in a hidden web view (no sign-in), which gives the video's address
//               (`ThreadsPage`). Everything else: yt-dlp (`YtDlp`), YummyOrange's own copy, downloaded from yt-dlp's
//               GitHub releases once the person agrees and checked against the published SHA-256, or one the person
//               installed. It only fetches; YummyOrange's own ffmpeg recipes make the MP3, M4A and WAV.
//   sign-in     When a site asks for a signed-in visitor, yt-dlp tries once more with the cookies of the browser the
//               link was dragged from (macOS may ask before handing them over).

// MARK: - Sites

/// The sites a dragged link can be downloaded from, recognised by the post's address.
enum LinkSite: String, CaseIterable {
    case youtube = "YouTube", x = "X", instagram = "Instagram", tiktok = "TikTok", threads = "Threads"

    /// The site of a post's address, or nil for anything else (a profile, a search, another site).
    static func of(_ url: URL) -> LinkSite? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = url.host?.lowercased() else { return nil }
        for prefix in ["www.", "m.", "mobile."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
            break
        }
        let parts = url.path.split(separator: "/").map(String.init)
        /// One of `names` with something after it ("/reel/C123").
        func followed(by names: Set<String>) -> Bool {
            guard let i = parts.firstIndex(where: { names.contains($0.lowercased()) }) else { return false }
            return i + 1 < parts.count
        }
        switch host {
        case "youtube.com", "music.youtube.com", "youtube-nocookie.com":
            if parts.first == "watch" {
                let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
                return v?.isEmpty == false ? .youtube : nil
            }
            return followed(by: ["shorts", "live", "embed", "v"]) ? .youtube : nil
        case "youtu.be":
            return parts.isEmpty ? nil : .youtube
        case "x.com", "twitter.com":
            guard let i = parts.firstIndex(of: "status"), i + 1 < parts.count, parts[i + 1].allSatisfy(\.isNumber) else { return nil }
            return .x
        case "instagram.com":
            return followed(by: ["p", "reel", "reels", "tv", "stories"]) ? .instagram : nil
        case "tiktok.com":
            return followed(by: ["video", "photo", "t"]) ? .tiktok : nil
        case "vm.tiktok.com", "vt.tiktok.com":
            return parts.isEmpty ? nil : .tiktok
        case "threads.com", "threads.net":
            return followed(by: ["post", "t"]) ? .threads : nil
        default:
            return nil
        }
    }
}

// MARK: - Link files

/// A supported link stood in as a .webloc file, the way Finder saves links.
enum LinkFiles {
    struct Link {
        var url: URL
        var site: LinkSite
        /// The bundle identifier of the app the link was dragged from (its browser), when known.
        var sourceApp: String?
    }

    private static let urlKey = "URL"
    private static let sourceKey = "YummyOrangeSourceApp"

    /// Where dragged links are written: one folder per link, in the temporary folder.
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("YummyOrange Links", isDirectory: true)
    }

    /// The link a .webloc file holds, when it is a post YummyOrange can download.
    static func read(_ file: URL) -> Link? {
        guard file.isFileURL, file.pathExtension.lowercased() == "webloc",
              let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count < 64 * 1024,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let string = plist[urlKey] as? String, let url = URL(string: string), let site = LinkSite.of(url)
        else { return nil }
        // The browser is trusted only in link files YummyOrange wrote itself (a .webloc from elsewhere could name any).
        return Link(url: url, site: site, sourceApp: isDragged(file) ? plist[sourceKey] as? String : nil)
    }

    static func isLink(_ file: URL) -> Bool { read(file) != nil }

    /// A link written for a drag (not a .webloc the person keeps somewhere).
    static func isDragged(_ file: URL) -> Bool {
        file.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    /// What the progress banner calls a file: a link by its title, without ".webloc".
    static func displayName(_ file: URL) -> String {
        file.pathExtension.lowercased() == "webloc" ? file.deletingPathExtension().lastPathComponent : file.lastPathComponent
    }

    /// The supported web links on a pasteboard (when it holds no files), each written as a link file. Empty when there
    /// are none, so any other drag is left alone.
    static func files(from pasteboard: NSPasteboard, sourceApp: String?) -> [URL] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? [])
            .filter { !$0.isFileURL && LinkSite.of($0) != nil }
        guard !urls.isEmpty else { return [] }
        let titles = titles(on: pasteboard)
        return urls.prefix(20).compactMap { url in
            try? write(url, title: titles[url.absoluteString] ?? (urls.count == 1 ? titles[""] : nil), sourceApp: sourceApp)
        }
    }

    /// Page titles a browser puts with a dragged link: Safari's list of links and titles, and the single title other
    /// browsers write (under the key "").
    private static func titles(on pasteboard: NSPasteboard) -> [String: String] {
        var titles: [String: String] = [:]
        if let list = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType")) as? [[String]],
           list.count == 2 {
            for (url, title) in zip(list[0], list[1]) { titles[url] = title }
        }
        if let name = pasteboard.string(forType: NSPasteboard.PasteboardType("public.url-name")) { titles[""] = name }
        return titles
    }

    /// Writes (or rewrites) the link file for a link, named after the page's title.
    static func write(_ url: URL, title: String?, sourceApp: String?) throws -> URL {
        guard let site = LinkSite.of(url) else { throw ConversionError.unsupported("YummyOrange can’t download this link.") }
        let fm = FileManager.default
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let dir = folder.appendingPathComponent(digest, isDirectory: true)
        let name = fileSafe(cleanTitle(title), fallback: "\(site.rawValue) link")
        let file = dir.appendingPathComponent(name + ".webloc")
        var plist: [String: Any] = [urlKey: url.absoluteString]
        if let sourceApp { plist[sourceKey] = sourceApp }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // A file written under an older title stays: a job still waiting in line may be about to read it.
        try data.write(to: file, options: .atomic)
        return file
    }

    /// A page title without the site's name and the unread count YouTube puts in front ("(3) Title - YouTube").
    static func cleanTitle(_ raw: String?) -> String {
        var title = (raw ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if let m = title.firstMatch(of: #/^\(\d+\)\s+/#) { title.removeSubrange(m.range) }
        for suffix in [" - YouTube Music", " - YouTube", " / X", " / Twitter", " | TikTok", " • Threads"] where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
            break
        }
        if ["YouTube", "X", "Instagram", "TikTok", "Threads", "Twitter"].contains(title) { return "" }
        return title.trimmingCharacters(in: .whitespaces)
    }

    /// A name that is safe as a file name: no slashes or colons, no leading dot, at most 90 characters and 200 UTF-16
    /// units (APFS allows 255; emoji and other scripts take several units per character).
    static func fileSafe(_ raw: String, fallback: String) -> String {
        var name = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if name.count > 90 || name.utf16.count > 200 {
            name = String(name.prefix(90))
            while name.utf16.count > 200 { name.removeLast() }   // whole characters, so an emoji is never split
            name = name.trimmingCharacters(in: .whitespaces)
            if let space = name.lastIndex(of: " "), name.distance(from: name.startIndex, to: space) > 50 {
                name = String(name[..<space])
            }
            name += "…"
        }
        return name.isEmpty ? fallback : name
    }
}

// MARK: - The petals

enum LinkDownload: FeatureModule {
    enum Target: String, CaseIterable {
        case mp4, mp3, m4a, wav

        var format: OutputFormat { OutputFormat(rawValue: rawValue)! }
    }

    /// What a site gave: the file, and the title and artist to name and tag the result with.
    struct Fetched {
        var file: URL
        var title: String
        var artist: String?
    }

    static var commands: [WheelCommand] {
        Target.allCases.map { target in
            WheelCommand(wheel: .convert, id: target.rawValue, title: target.rawValue.uppercased(),
                         applies: { files in files.allSatisfy(LinkFiles.isLink) },
                         ask: { files in YtDlp.askToGet(for: files) },
                         run: { files, options, progress in
                             try files.flatMap { try download($0, as: target, options: options, progress: progress) }
                         })
        }
    }

    static func selfTest(_ name: String) -> String? {
        #if DEBUG
        return name == "links" ? LinkDownloadTests.run() : nil
        #else
        return nil
        #endif
    }

    /// Where a dragged link's file goes.
    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Downloads one link as `target`. Background thread (the main thread on the command line).
    static func download(_ file: URL, as target: Target, options: ToolOptions,
                         progress: @escaping (Double) -> Void) throws -> [URL] {
        guard let link = LinkFiles.read(file) else { throw ConversionError.unreadable(file.lastPathComponent) }
        guard let ffmpeg = FFmpeg.shared else { throw ConversionError.missingTool("ffmpeg") }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("YummyOrange Download \(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let fetched: Fetched
        if link.site == .threads {
            fetched = try ThreadsPage.fetch(link.url, into: work) { progress($0 * 0.85) }
        } else {
            let tool = try YtDlp.tool(getIfMissing: options.bool("getYtDlp", false), progress: progress)
            fetched = try YtDlp.fetch(link, target: target, tool: tool, ffmpeg: ffmpeg.tool, into: work, options: options) { progress($0 * 0.85) }
        }
        let folder = LinkFiles.isDragged(file) ? downloadsFolder : file.deletingLastPathComponent()
        let kind = target == .mp4 ? "video" : "sound"
        // Instagram calls every post "Video by <name>": the page's own title, when the browser gave one, says more.
        var title = fetched.title
        let pageTitle = LinkFiles.displayName(file)
        if link.site == .instagram, title.isEmpty || title.hasPrefix("Video by "), pageTitle != "\(link.site.rawValue) link" {
            title = pageTitle
        }
        let name = LinkFiles.fileSafe(title, fallback: "\(link.site.rawValue) \(kind)")
        let out = outputURL(for: folder.appendingPathComponent(name + "." + target.rawValue), ext: target.rawValue)
        try finish(fetched, as: target, ffmpeg: ffmpeg, to: out) { progress(0.85 + $0 * 0.15) }
        return [out]
    }

    /// Turns what was fetched into the chosen format at `out`: moved as it is when it already is one, otherwise
    /// copied into an MP4 or converted with YummyOrange's own audio recipes.
    private static func finish(_ fetched: Fetched, as target: Target, ffmpeg: FFmpeg, to out: URL,
                               progress: @escaping (Double) -> Void) throws {
        let info = ffmpeg.probe(fetched.file)
        guard info.opened else { throw ConversionError.toolFailed("The download isn’t a video or sound YummyOrange can read.") }
        var tags = ["-metadata", "title=\(fetched.title)"]
        if let artist = fetched.artist, !artist.isEmpty { tags += ["-metadata", "artist=\(artist)"] }
        if target == .mp4 {
            guard info.hasVideo else {
                throw ConversionError.toolFailed("This post has sound but no video. Drop it on MP3, M4A or WAV instead.")
            }
            if fetched.file.pathExtension.lowercased() == "mp4" {
                try FileManager.default.moveItem(at: fetched.file, to: out)
                // A download's temporary file is private (0600); the saved video gets a normal file's permissions.
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: out.path)
            } else {
                try ffmpeg.run(input: fetched.file, output: out, args: ["-map", "0:v:0", "-map", "0:a?", "-c", "copy", "-movflags", "+faststart"],
                               duration: info.duration, progress: progress)
            }
            return
        }
        guard info.hasAudio else { throw ConversionError.toolFailed("This post has no sound.") }
        var args = ["-vn", "-map", "0:a:0"]
        if target == .m4a, info.audioCodec == "aac" {
            args += ["-c:a", "copy", "-movflags", "+faststart"]   // already AAC: kept as it is
        } else {
            args += FFmpeg.audioArgs(for: target.format)
            if target == .m4a { args += ["-movflags", "+faststart"] }
        }
        try ffmpeg.run(input: fetched.file, output: out, args: args + tags, duration: info.duration, progress: progress)
    }
}

// MARK: - yt-dlp

/// yt-dlp, the open-source downloader YummyOrange fetches YouTube, X, Instagram and TikTok posts with.
enum YtDlp {
    static let releaseBase = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/")!
    static let assetName = "yt-dlp_macos"

    /// YummyOrange's own copy: Application Support/YummyOrange/Helpers/yt-dlp/yt-dlp_macos.
    static var ownTool: URL {
        FFmpegLookup.defaultRoot().appendingPathComponent("yt-dlp", isDirectory: true).appendingPathComponent(assetName)
    }

    struct Tool {
        var url: URL
        /// YummyOrange's own copy, which it may update.
        var own: Bool
    }

    /// YummyOrange's own copy first (it keeps it current), then one the person installed.
    static func find() -> Tool? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: ownTool.path) { return Tool(url: ownTool, own: true) }
        for dir in FFmpegLookup.userFolders() {
            let candidate = dir.appendingPathComponent("yt-dlp")
            if fm.isExecutableFile(atPath: candidate.path) { return Tool(url: candidate, own: false) }
        }
        return nil
    }

    /// Main thread, before the job runs: on a Mac without yt-dlp, asks once per drop whether to download it.
    /// nil = Cancel.
    static func askToGet(for files: [URL]) -> ToolOptions? {
        guard files.contains(where: { LinkFiles.read($0)?.site != .threads }), find() == nil else { return [:] }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Links from YouTube, X, Instagram and TikTok need yt-dlp."
        alert.informativeText = "yt-dlp is a free, open-source downloader from github.com/yt-dlp (about 37 MB). "
            + "YummyOrange keeps it in its own folder and uses it only for links you drop on the wheel."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? ["getYtDlp": "1"] : nil
    }

    static func tool(getIfMissing: Bool, progress: @escaping (Double) -> Void) throws -> Tool {
        if let found = find() { return found }
        guard getIfMissing else {
            throw ConversionError.toolFailed("Links from YouTube, X, Instagram and TikTok need yt-dlp. Drop the link on the wheel again and choose Download.")
        }
        return Tool(url: try install(progress: progress), own: true)
    }

    /// Downloads yt-dlp's macOS build and its published checksums, and keeps the build only when they match.
    static func install(progress: @escaping (Double) -> Void) throws -> URL {
        let fm = FileManager.default
        let folder = ownTool.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".download-\(UUID().uuidString)")
        let sumsFile = folder.appendingPathComponent(".sums-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging); try? fm.removeItem(at: sumsFile) }
        do {
            try Fetch.file(releaseBase.appendingPathComponent("SHA2-256SUMS"), to: sumsFile, progress: nil)
            try Fetch.file(releaseBase.appendingPathComponent(assetName), to: staging, progress: progress)
        } catch {
            throw ConversionError.toolFailed("Couldn’t download yt-dlp: \(error.localizedDescription)")
        }
        let sums = (try? String(contentsOf: sumsFile, encoding: .utf8)) ?? ""
        let expected = sums.split(separator: "\n").lazy.compactMap { line -> String? in
            let fields = line.split(separator: " ")
            return fields.count == 2 && fields[1] == assetName ? fields[0].lowercased() : nil
        }.first
        let actual = SHA256.hash(data: try Data(contentsOf: staging, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard let expected, expected == actual else {
            throw ConversionError.toolFailed("The yt-dlp download didn’t match its published checksum, so YummyOrange didn’t keep it. Try again later.")
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        try? fm.removeItem(at: ownTool)
        try fm.moveItem(at: staging, to: ownTool)
        DragMonitor.log.notice("yt-dlp installed at \(ownTool.path, privacy: .public)")
        return ownTool
    }

    /// yt-dlp's names for the browsers it reads cookies from, by bundle identifier. Not Safari: its cookies need Full
    /// Disk Access, which YummyOrange doesn't ask for.
    static let cookieBrowsers: [String: String] = [
        "com.google.Chrome": "chrome", "com.google.Chrome.beta": "chrome", "com.brave.Browser": "brave",
        "com.microsoft.edgemac": "edge", "org.mozilla.firefox": "firefox",
        "com.vivaldi.Vivaldi": "vivaldi", "com.operasoftware.Opera": "opera", "org.chromium.Chromium": "chromium",
    ]
    static let browserNames = ["chrome": "Chrome", "brave": "Brave", "edge": "Edge", "firefox": "Firefox",
                               "vivaldi": "Vivaldi", "opera": "Opera", "chromium": "Chromium"]

    /// Asks before yt-dlp reads a browser's cookies, every time. On the command line (no prompts) only with
    /// `--opt cookies=1`. Any thread.
    static func mayUseCookies(of browser: String, site: LinkSite, options: ToolOptions) -> Bool {
        let name = browserNames[browser] ?? browser
        let answer: Bool? = try? MainThread.wait(timeout: 600) { finish in
            guard NSApp.activationPolicy() != .prohibited else { finish(.success(options.bool("cookies", false))); return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "\(site.rawValue) shows this post only to signed-in visitors."
            alert.informativeText = "YummyOrange can download it with your \(site.rawValue) sign-in from \(name). yt-dlp reads "
                + "\(name)’s cookies for this one download and sends them only to \(site.rawValue). macOS may ask first."
            alert.addButton(withTitle: "Use \(name) Sign-In")
            alert.addButton(withTitle: "Cancel")
            finish(.success(alert.runModal() == .alertFirstButtonReturn))
        }
        return answer ?? false
    }

    /// yt-dlp's errors that a signed-in visitor wouldn't get.
    static func needsSignIn(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return ["sign in to confirm", "login required", "log in", "--cookies", "empty media response", "rate-limit",
                "requires authentication", "age-restricted", "nsfw", "private"].contains { text.contains($0) }
    }

    /// The last error yt-dlp printed, without its "ERROR: [site] id:" prefix.
    static func message(_ stderr: String) -> String? {
        guard let line = stderr.split(separator: "\n").last(where: { $0.hasPrefix("ERROR:") }) else { return nil }
        var text = String(line.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces)
        if let m = text.firstMatch(of: #/^\[[^\]]+\]\s+[^:\s]+:\s+/#) { text.removeSubrange(m.range) }
        if let cut = text.range(of: ". Use --cookies") ?? text.range(of: " Use --cookies") ?? text.range(of: ". See  https") {
            text = String(text[..<cut.lowerBound]) + "."
        }
        return text
    }

    /// Fetches one post: the video with its sound for MP4, otherwise the best sound (AAC first, so M4A can keep it).
    static func fetch(_ link: LinkFiles.Link, target: LinkDownload.Target, tool: Tool, ffmpeg: URL, into work: URL,
                      options: ToolOptions = [:], progress: @escaping (Double) -> Void) throws -> LinkDownload.Fetched {
        var args = ["--ignore-config", "--no-playlist", "--no-mtime", "--newline", "--progress",
                    "--progress-template", "download:DWPROG %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s",
                    "--print", "after_move:DWDONE %(.{filepath,title,track,artist,uploader,channel,creator})j",
                    "--no-simulate", "--ffmpeg-location", ffmpeg.path, "-P", work.path, "-o", "%(id).80B.%(ext)s"]
        switch target {
        case .mp4: args += ["-f", "bv*+ba/b", "-S", "vcodec:h264,lang,quality,res,fps,hdr:12,acodec:aac", "--merge-output-format", "mp4"]
        case .m4a: args += ["-f", "ba[acodec^=mp4a]/ba/b"]
        case .mp3, .wav: args += ["-f", "ba/b"]
        }
        args.append(link.url.absoluteString)

        func attempt(_ extra: [String]) throws -> (ProcessResult, LinkDownload.Fetched?) {
            var stage = 0, last = 0.0
            var done: LinkDownload.Fetched?
            let result = try ProcessRunner.run(tool.url, extra + args) { line in
                if line.hasPrefix("DWPROG ") {
                    let numbers = line.split(separator: " ").dropFirst().map { Double($0) }
                    guard numbers.count == 3, let got = numbers[0], let total = numbers[1] ?? numbers[2], total > 0 else { return }
                    let f = min(1, got / total)
                    if f < last - 0.5 { stage += 1 }   // the second stream (a video's sound) started
                    last = f
                    // A video comes first and is the big part; its sound follows.
                    progress(target == .mp4 ? (stage == 0 ? f * 0.85 : 0.85 + f * 0.15) : f)
                } else if line.hasPrefix("DWDONE "), let data = line.dropFirst("DWDONE ".count).data(using: .utf8),
                          let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let path = info["filepath"] as? String {
                    func text(_ key: String) -> String? { (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
                    done = LinkDownload.Fetched(file: URL(fileURLWithPath: path),
                                                title: text("track") ?? text("title") ?? "",
                                                artist: text("artist") ?? text("uploader") ?? text("channel") ?? text("creator"))
                }
            }
            return (result, done)
        }

        var (result, done) = try attempt([])
        // Sites change often and yt-dlp follows: YummyOrange's own copy updates itself (at most every six hours) and
        // tries again.
        if result.status != 0, tool.own, !needsSignIn(result.stderr), mayUpdate() {
            _ = try? ProcessRunner.run(tool.url, ["-U"])
            (result, done) = try attempt([])
        }
        // A post only signed-in visitors see: once more with the cookies of the browser it came from, if the person agrees.
        if result.status != 0, needsSignIn(result.stderr), let browser = link.sourceApp.flatMap({ cookieBrowsers[$0] }),
           mayUseCookies(of: browser, site: link.site, options: options) {
            DragMonitor.log.notice("yt-dlp: \(link.site.rawValue, privacy: .public) asks for sign-in; trying \(browser, privacy: .public)’s cookies")
            (result, done) = try attempt(["--cookies-from-browser", browser])
        }
        guard result.status == 0 else {
            let detail = message(result.stderr) ?? "yt-dlp stopped (status \(result.status))."
            if needsSignIn(result.stderr) {
                throw ConversionError.toolFailed("\(link.site.rawValue) shows this post only to signed-in visitors. Sign in to \(link.site.rawValue) in Chrome, Firefox, Edge or Brave, then drag the link from there again. (\(detail))")
            }
            throw ConversionError.toolFailed("Couldn’t download from \(link.site.rawValue): \(detail)")
        }
        if let done, FileManager.default.fileExists(atPath: done.file.path) { return done }
        // No final path printed (an older yt-dlp): the one finished file in the folder.
        let files = (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        guard let file = files.first(where: { !["part", "ytdl", "json"].contains($0.pathExtension) }) else {
            throw ConversionError.toolFailed("yt-dlp finished without saving a file.")
        }
        return LinkDownload.Fetched(file: file, title: done?.title ?? "", artist: done?.artist)
    }

    private static let updateKey = "YtDlpLastSelfUpdate"

    private static func mayUpdate() -> Bool {
        let last = UserDefaults.standard.double(forKey: updateKey)
        let now = Date().timeIntervalSince1970
        guard now - last > 6 * 3600 else { return false }
        UserDefaults.standard.set(now, forKey: updateKey)
        return true
    }
}

// MARK: - Threads

/// Finds a Threads post's video the way a browser does: the post page loads in a hidden web view (with no sign-in and
/// nothing kept on disk), and the post's data on the page gives the video's address. Main thread.
final class ThreadsPage: NSObject, WKNavigationDelegate {
    struct Found {
        var video: URL
        var caption: String
        var user: String?
    }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    static let timeout: TimeInterval = 30

    /// Background thread (or the command line's main thread): finds the video, then downloads it.
    static func fetch(_ url: URL, into work: URL, progress: @escaping (Double) -> Void) throws -> LinkDownload.Fetched {
        let found: Found = try MainThread.wait(timeout: timeout + 5) { finish in ThreadsPage.find(url, finish: finish) }
        let file = work.appendingPathComponent("threads.mp4")
        do { try Fetch.file(found.video, to: file, progress: progress) } catch {
            throw ConversionError.toolFailed("Couldn’t download the Threads video: \(error.localizedDescription)")
        }
        let caption = found.caption.split(separator: "\n").first.map(String.init) ?? ""
        let title = caption.isEmpty ? "Threads video" + (found.user.map { " by @\($0)" } ?? "") : caption
        return LinkDownload.Fetched(file: file, title: title, artist: found.user.map { "@\($0)" })
    }

    private static var live: Set<ThreadsPage> = []

    static func find(_ url: URL, finish: @escaping (Result<Found, Error>) -> Void) {
        let page = ThreadsPage(finish: finish)
        live.insert(page)
        page.web.load(URLRequest(url: url))
    }

    private let web: WKWebView
    private let window: NSWindow
    private let finish: (Result<Found, Error>) -> Void
    private var timer: Timer?
    private let started = Date()
    private var finished = false

    private init(finish: @escaping (Result<Found, Error>) -> Void) {
        self.finish = finish
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all   // never plays anything
        config.suppressesIncrementalRendering = true
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 1200), configuration: config)
        web.customUserAgent = Self.userAgent
        window = NSWindow(contentRect: CGRect(x: -30_000, y: -30_000, width: 1000, height: 1200), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init()
        window.contentView?.addSubview(web)
        web.navigationDelegate = self
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        guard !finished else { return }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed < Self.timeout else {
            complete(.failure(ConversionError.toolFailed("Threads didn’t show a video for this post. Check that the post has a video and is public.")))
            return
        }
        // After a while, the first video on the page (the post's own) will do.
        web.evaluateJavaScript(Self.script(anyVideo: elapsed > 12)) { [weak self] result, _ in
            guard let self, !self.finished, let text = result as? String, let data = text.data(using: .utf8),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if info["novideo"] as? Bool == true {
                guard elapsed > 6 else { return }   // the page may still be adding the post's media
                self.complete(.failure(ConversionError.toolFailed("This Threads post has no video.")))
                return
            }
            guard let string = info["url"] as? String, let video = URL(string: string), video.scheme == "https" else { return }
            let user = (info["user"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            self.complete(.success(Found(video: video, caption: info["caption"] as? String ?? "", user: user)))
        }
    }

    private func complete(_ result: Result<Found, Error>) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        web.stopLoading()
        web.navigationDelegate = nil
        web.removeFromSuperview()
        Self.live.remove(self)
        finish(result)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

    private func failed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }   // a redirect, or the page moving on
        complete(.failure(ConversionError.toolFailed("Couldn’t open the Threads post: \(error.localizedDescription)")))
    }

    /// Looks through the post data on the page for the post whose code is in the address and returns its largest video
    /// as JSON ({url, caption, user}), {novideo: true} when the post has none, or null when it isn't there yet.
    static func script(anyVideo: Bool) -> String {
        """
        (function (anyVideo) {
          const m = location.pathname.match(/\\/(?:post|t)\\/([A-Za-z0-9_-]+)/);
          const code = m && m[1];
          let best = null, noVideo = false;
          const largest = (x) => (x && x.video_versions || []).slice()
            .sort((a, b) => (b.width * b.height) - (a.width * a.height))[0];
          const walk = (o, depth) => {
            if (best || !o || typeof o !== 'object' || depth > 150) return;
            if (code && o.code === code) {
              const v = largest(o) || (o.carousel_media || []).map(largest).find(Boolean);
              if (v && v.url) {
                best = { url: v.url, user: (o.user && o.user.username) || '', caption: (o.caption && o.caption.text) || '' };
                return;
              }
              if (o.media_type !== undefined || o.image_versions2) noVideo = true;
            }
            for (const k in o) walk(o[k], depth + 1);
          };
          for (const s of document.querySelectorAll('script[type="application/json"]')) {
            const t = s.textContent;
            if (!code || !t.includes(code)) continue;
            try { walk(JSON.parse(t), 0); } catch (e) {}
            if (best) break;
          }
          if (!best && anyVideo) {
            const v = document.querySelector('video');
            if (v && (v.currentSrc || v.src || '').startsWith('https:')) best = { url: v.currentSrc || v.src, user: '', caption: '' };
          }
          if (best) return JSON.stringify(best);
          return noVideo ? JSON.stringify({ novideo: true }) : null;
        })(\(anyVideo))
        """
    }
}

// MARK: - Downloads

enum Fetch {
    /// Downloads `url` to `destination` (replacing it), reporting 0…1. Waits; call it off the main thread in the app.
    static func file(_ url: URL, to destination: URL, progress: ((Double) -> Void)?) throws {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(ThreadsPage.userAgent, forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        let task = URLSession.shared.downloadTask(with: request) { temporary, response, error in
            defer { done.signal() }
            if let error { failure = error; return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let temporary else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                failure = ConversionError.toolFailed("The server answered \(status).")
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch { failure = error }
        }
        let observation = task.progress.observe(\.fractionCompleted) { p, _ in progress?(p.fractionCompleted) }
        task.resume()
        done.wait()
        observation.invalidate()
        if let failure { throw failure }
    }
}
