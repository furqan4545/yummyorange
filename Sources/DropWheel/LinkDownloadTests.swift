#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit

/// `--selftest links`: which addresses count as posts, the link file a drag writes, and the petals it gets. Offline.
enum LinkDownloadTests {
    static func run() -> String {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

        let posts: [(String, LinkSite)] = [
            ("https://www.youtube.com/watch?v=jNQXAC9IVRw", .youtube),
            ("https://m.youtube.com/watch?v=jNQXAC9IVRw&t=4s", .youtube),
            ("https://youtu.be/jNQXAC9IVRw?si=abc", .youtube),
            ("https://www.youtube.com/shorts/abc123DEF45", .youtube),
            ("https://music.youtube.com/watch?v=jNQXAC9IVRw", .youtube),
            ("https://x.com/captainamerica/status/719944021058060289", .x),
            ("https://twitter.com/LisPower1/status/1001551623938805763?s=20", .x),
            ("https://x.com/i/status/1001551623938805763", .x),
            ("https://mobile.twitter.com/a/status/1001551623938805763", .x),
            ("https://www.instagram.com/reel/Chunk8-jurw/", .instagram),
            ("https://www.instagram.com/p/BQ0eAlwhDrw/?igsh=x", .instagram),
            ("https://www.instagram.com/someone/reel/Chunk8-jurw/", .instagram),
            ("https://www.tiktok.com/@barudakhb_/video/6984138651336838402", .tiktok),
            ("https://vm.tiktok.com/ZMabc123/", .tiktok),
            ("https://www.tiktok.com/t/ZTabc123/", .tiktok),
            ("https://www.threads.com/@nasa/post/Df-IxZ8AgOO", .threads),
            ("https://www.threads.net/@nasa/post/Df-IxZ8AgOO?xmt=1", .threads),
            ("https://www.threads.com/t/Df-IxZ8AgOO", .threads),
        ]
        for (string, site) in posts { check(LinkSite.of(URL(string: string)!) == site, "\(string) is a \(site.rawValue) post") }
        let notPosts = [
            "https://www.youtube.com/", "https://www.youtube.com/watch", "https://www.youtube.com/@nasa",
            "https://x.com/nasa", "https://x.com/nasa/status/notanumber", "https://www.instagram.com/nasa/",
            "https://www.tiktok.com/@nasa", "https://www.threads.com/@nasa", "https://example.com/watch?v=1",
            "ftp://youtube.com/watch?v=1", "file:///Users/me/watch?v=1",
        ]
        for string in notPosts { check(URL(string: string).flatMap(LinkSite.of) == nil, "\(string) isn’t a post") }

        check(LinkFiles.cleanTitle("(3) Me at the zoo - YouTube") == "Me at the zoo", "YouTube's title suffix and count go")
        check(LinkFiles.cleanTitle("Instagram") == "", "a bare site name is no title")
        check(LinkFiles.fileSafe("a/b: c", fallback: "x") == "a-b - c", "slashes and colons are made safe")
        check(LinkFiles.fileSafe("...", fallback: "X link") == "X link", "an empty name falls back")
        check(LinkFiles.fileSafe(String(repeating: "word ", count: 40), fallback: "x").count <= 91, "long names are cut")

        // A drag from a browser: a link and its page title on the drag pasteboard.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.yummyorange.selftest.links"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("https://www.youtube.com/watch?v=jNQXAC9IVRw", forType: .URL)
        item.setString("Me at the zoo - YouTube", forType: NSPasteboard.PasteboardType("public.url-name"))
        pasteboard.writeObjects([item])
        let files = LinkFiles.files(from: pasteboard, sourceApp: "com.google.Chrome")
        check(files.count == 1, "a dragged YouTube link becomes one link file (got \(files.count))")
        if let file = files.first {
            check(file.lastPathComponent == "Me at the zoo.webloc", "the link file is named after the page (\(file.lastPathComponent))")
            check(LinkFiles.isDragged(file), "it is in the dragged-links folder")
            let link = LinkFiles.read(file)
            check(link?.url.absoluteString == "https://www.youtube.com/watch?v=jNQXAC9IVRw", "it holds the link")
            check(link?.sourceApp == "com.google.Chrome", "it remembers the browser")
            check(LinkFiles.displayName(file) == "Me at the zoo", "the banner shows the title")
            let convert = OutputFormat.targets(forAll: files).map(\.rawValue) + Registry.convertCommands(for: files, besides: []).map(\.id)
            check(convert == ["mp4", "mp3", "m4a", "wav"], "the Convert wheel offers MP4, MP3, M4A, WAV (got \(convert))")
            check(FileTool.tools(for: files).isEmpty && Registry.commands(for: .tools, files: files).isEmpty,
                  "the Tools wheel offers nothing for a link")
            check(!LinkDownload.commands.contains { $0.applies([file, URL(fileURLWithPath: "/tmp/photo.jpg")]) },
                  "link petals need every file to be a link")
            // The same link with no title: named after the site; the file under the older name stays (a job may use it).
            let again = try? LinkFiles.write(URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")!, title: nil, sourceApp: nil)
            check(again?.lastPathComponent == "YouTube link.webloc", "no title: named after the site")
            check(FileManager.default.fileExists(atPath: file.path), "the file under the older name stays")
            // A .webloc from elsewhere can name any browser: that is ignored.
            let outside = FileManager.default.temporaryDirectory.appendingPathComponent("yo-selftest-\(UUID().uuidString).webloc")
            try? FileManager.default.copyItem(at: file, to: outside)
            check(LinkFiles.read(outside)?.sourceApp == nil && LinkFiles.read(outside)?.site == .youtube,
                  "a .webloc outside the dragged-links folder works but names no browser")
            try? FileManager.default.removeItem(at: outside)
        }
        let emoji = LinkFiles.fileSafe(String(repeating: "🎵", count: 89), fallback: "x")
        check(emoji.utf16.count <= 201 && emoji.unicodeScalars.allSatisfy { $0.value != 0xFFFD }, "emoji titles fit APFS's limit, whole")
        check(YtDlp.cookieBrowsers["com.apple.Safari"] == nil, "Safari's cookies are never asked for")
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/page", forType: .URL)
        check(LinkFiles.files(from: pasteboard, sourceApp: nil).isEmpty, "a link to another site is left alone")
        pasteboard.clearContents()
        pasteboard.setString("just some text", forType: .string)
        check(LinkFiles.files(from: pasteboard, sourceApp: nil).isEmpty, "a text drag is left alone")
        pasteboard.releaseGlobally()

        check(YtDlp.message("WARNING: x\nERROR: [Instagram] Df-Ix: Instagram sent an empty media response. Check if this post is accessible") ==
              "Instagram sent an empty media response. Check if this post is accessible", "yt-dlp's error loses its prefix")
        check(YtDlp.needsSignIn("ERROR: [youtube] x: Sign in to confirm you’re not a bot"), "a bot check asks for sign-in")
        check(!YtDlp.needsSignIn("ERROR: [youtube] x: Video unavailable. This video has been removed"), "a removed video doesn’t")

        return failures.isEmpty ? "PASS links: \(posts.count + notPosts.count) addresses, link files, petals"
                                : "FAIL links:\n  " + failures.joined(separator: "\n  ")
    }
}
#endif
