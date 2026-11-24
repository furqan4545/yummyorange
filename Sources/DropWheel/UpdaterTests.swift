#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import CryptoKit
import Security
import UserNotifications

/// `--selftest updater`: the built-in updater (Updater.swift). Versions, the feed and its detached signature, the
/// download's length, checksum and Ed25519 signature, the code-signature policies and checks on tiny apps built and
/// signed here (with this Mac's Apple Development or Developer ID identity when there is one, and ad hoc), the
/// permissions of an unpacked app, the replace step (with its second check and putting the old app back) on a fake
/// installed app in a temporary folder, Skip This Version and Remind Me Later, the notification's permission and
/// actions, the menu items, the setting, the relaunch helper (waiting on a `sleep`, running `touch`), a full check,
/// download, verify and replace against a `python3 -m http.server` on 127.0.0.1 that the test starts and stops, the
/// release check release.sh runs, and the release scripts' refusals (run on copies in a temporary folder).
///
/// Nothing here launches YummyOrange, signals a YummyOrange process, writes the real preferences, the Keychain, Desktop,
/// Downloads or Pictures, or uses the network beyond 127.0.0.1: settings live in memory, the keys are made here and
/// thrown away, code-signature checks run with network access off (Gatekeeper is never asked: a stand-in answers),
/// and everything on disk is in a temporary folder.
enum UpdaterTests {
    typealias Checker = ResultsShelfTests.Checker

    static let feedURL = URL(string: "https://yummyorange.com/updates/appcast.json")!
    static let system = OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0)

    static func run() -> String {
        let c = Checker()
        let savedDefaults = Settings.defaults
        Settings.defaults = SettingsMemoryStore()
        let savedMenuUpdater = UpdateMenuTarget.shared.updater
        defer {
            Settings.defaults = savedDefaults
            UpdateMenuTarget.shared.updater = savedMenuUpdater
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("YummyOrange updater \(UUID().uuidString.prefix(8))", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { unlockAll(dir); try? fm.removeItem(at: dir) }

        versions(c)
        feed(c)
        feedSignature(c)
        archive(c, dir)
        transport(c)
        let kit = TestApps(dir.appendingPathComponent("kit", isDirectory: true))
        c.notes += kit.notes
        codeSignature(c, kit)
        permissions(c, kit)
        replace(c, kit)
        policy(c)
        notifications(c)
        menu(c)
        settings(c)
        relauncher(c, dir)
        fullRun(c, kit)
        releaseCheck(c, kit)
        scripts(c, kit, dir)
        return c.report("updater")
    }

    // MARK: Helpers

    static func item(version: String = "1.0.1", build: String = "2", minimum: String? = "13.0") -> UpdateItem {
        UpdateItem(version: version, build: build, minimumSystemVersion: minimum,
                   url: URL(string: "https://yummyorange.com/downloads/YummyOrange-\(version).zip")!, length: 1234,
                   sha256: String(repeating: "ab", count: 32), signature: Data(repeating: 7, count: 64),
                   releaseNotesURL: nil, releaseNotes: nil, published: nil)
    }

    /// An updater that can't do anything that needs the network or the app (its environment says why).
    static func idleUpdater(ui: RecordingUI = RecordingUI()) -> Updater {
        let env = Updater.Environment(feedURL: nil, publicKeys: [], appURL: URL(fileURLWithPath: "/nonexistent/YummyOrange.app"),
                                      bundleID: "com.yummyorange.app", version: "1.0.0", build: "1", signer: .unsigned,
                                      fallbackFolders: [FileManager.default.temporaryDirectory], system: system,
                                      unavailableReason: "test: no network here")
        let updater = Updater(environment: env)
        updater.ui = ui
        return updater
    }

    /// Base64 of an Ed25519 signature of `data`, as appcast.json.sig holds it.
    static func feedSignatureFile(_ data: Data, _ key: Curve25519.Signing.PrivateKey) -> Data {
        Data(((try? key.signature(for: data)) ?? Data()).base64EncodedString().utf8)
    }

    static func error(_ body: () throws -> Void) -> UpdateError? {
        do { try body(); return nil } catch let e as UpdateError { return e } catch { return .network("other: \(error)") }
    }

    static func isBadFeed(_ e: UpdateError?, mentioning key: String) -> Bool {
        if case .badFeed(let what) = e { return what.contains(key) }
        return false
    }

    /// Restores write permission everywhere under `dir`, so it can be removed after a check made a folder read-only.
    static func unlockAll(_ dir: URL) {
        _ = TestApps.run("/bin/chmod", ["-R", "u+w", dir.path])
    }

    /// Spins the run loop until `done` or the timeout; main-queue blocks run meanwhile.
    @discardableResult
    static func spin(until done: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        return done()
    }

    // MARK: Versions

    static func versions(_ c: Checker) {
        c.check("versions: “1.0.1”, “7” and “10.2” read as numbers",
                UpdateVersion.components("1.0.1") == [1, 0, 1] && UpdateVersion.components("7") == [7] && UpdateVersion.components("10.2") == [10, 2])
        let bad = ["", "1.", ".1", "1..2", "1.2.3.4", "a", "1.a", "-1", "1 ", " 1", "1,0", "１", "1234567890", "1.0-beta"]
        c.check("versions: anything else isn’t one (empty, a trailing dot, four parts, letters, a sign, spaces, other digits, ten digits)",
                bad.allSatisfy { UpdateVersion.components($0) == nil }, bad.filter { UpdateVersion.components($0) != nil }.joined(separator: " | "))
        let order: [(String, String, ComparisonResult)] = [
            ("1.0.1", "1.0.0", .orderedDescending), ("1.10", "1.9", .orderedDescending), ("2", "1.9.9", .orderedDescending),
            ("1.0", "1.0.0", .orderedSame), ("1.0.0", "1.0.1", .orderedAscending), ("9", "10", .orderedAscending), ("007", "7", .orderedSame),
        ]
        c.check("versions compare number by number (1.10 after 1.9, 2 after 1.9.9, 1.0 the same as 1.0.0, 9 before 10)",
                order.allSatisfy { UpdateVersion.compare($0.0, $0.1) == $0.2 },
                order.filter { UpdateVersion.compare($0.0, $0.1) != $0.2 }.map { "\($0.0) vs \($0.1)" }.joined(separator: ", "))
        c.check("an unreadable version is never newer, nor older",
                UpdateVersion.compare("1.x", "1") == nil && !UpdateVersion.isNewer("2.a", than: "1") && !UpdateVersion.isNewer("2", than: "1.b"))
    }

    // MARK: Feed

    static func goodFeed() -> [String: Any] {
        ["version": "1.0.1", "build": "2", "minimumSystemVersion": "13.0",
         "url": "https://yummyorange.com/downloads/YummyOrange-1.0.1.zip", "length": 1234,
         "sha256": String(repeating: "AB", count: 32), "signature": Data(repeating: 7, count: 64).base64EncodedString(),
         "releaseNotesURL": "../release-notes.html", "releaseNotes": "Faster PDF export.", "published": "2026-11-24T12:00:00Z",
         "somethingNew": ["later feeds may add keys"]]
    }

    static func parse(_ json: Any, feed: URL = feedURL) -> (UpdateItem?, UpdateError?) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return (nil, .network("unencodable")) }
        do { return (try UpdateFeed.parse(data, feedURL: feed), nil) } catch let e as UpdateError { return (nil, e) } catch { return (nil, nil) }
    }

    static func feed(_ c: Checker) {
        let (good, goodError) = parse(goodFeed())
        c.check("a good feed reads: version, build, minimum macOS, the ZIP’s address, length, checksum (lowercased), signature, notes and date",
                good?.version == "1.0.1" && good?.build == "2" && good?.minimumSystemVersion == "13.0"
                && good?.url.absoluteString == "https://yummyorange.com/downloads/YummyOrange-1.0.1.zip" && good?.length == 1234
                && good?.sha256 == String(repeating: "ab", count: 32) && good?.signature == Data(repeating: 7, count: 64)
                && good?.releaseNotes == "Faster PDF export." && good?.published == ISO8601DateFormatter().date(from: "2026-11-24T12:00:00Z"),
                "\(String(describing: good)) \(goodError?.localizedDescription ?? "")")
        c.check("addresses may be relative to the feed (release notes at ../release-notes.html)",
                good?.releaseNotesURL?.absoluteString == "https://yummyorange.com/release-notes.html")
        var relative = goodFeed()
        relative["url"] = "../downloads/YummyOrange-1.0.1.zip"
        c.check("a relative ZIP address resolves against the feed’s", parse(relative).0?.url.absoluteString == "https://yummyorange.com/downloads/YummyOrange-1.0.1.zip")
        var numeric = goodFeed()
        numeric["build"] = 2
        c.check("a build written as a JSON number reads as one", parse(numeric).0?.build == "2")
        var minimal = goodFeed()
        ["minimumSystemVersion", "releaseNotesURL", "releaseNotes", "published", "somethingNew"].forEach { minimal[$0] = nil }
        let (min, _) = parse(minimal)
        c.check("minimum macOS, release notes and date may be left out", min != nil && min?.minimumSystemVersion == nil && min?.releaseNotes == nil && min?.published == nil)

        for key in ["version", "build", "url", "length", "sha256", "signature"] {
            var missing = goodFeed()
            missing[key] = nil
            let e = parse(missing).1
            c.check("a feed without “\(key)” is refused, and says so", isBadFeed(e, mentioning: key), e?.localizedDescription ?? "accepted")
        }
        let badValues: [(String, Any, String)] = [
            ("version", "1.0.x", "a version with a letter"), ("build", "two", "a build in words"), ("build", true, "a build that is true"),
            ("version", NSNull(), "a null version"), ("length", "1234", "a length in quotes"), ("length", 0, "a length of 0"),
            ("length", -5, "a negative length"), ("length", 1.5, "a fractional length"), ("length", 600 * 1024 * 1024, "a length over 512 MB"),
            ("length", false, "a length that is false"),
            ("sha256", String(repeating: "a", count: 63), "a 63-digit checksum"), ("sha256", String(repeating: "zz", count: 32), "a checksum with non-hex digits"),
            ("signature", "not base64!", "a signature that isn’t base64"), ("signature", Data(count: 63).base64EncodedString(), "a 63-byte signature"),
            ("url", "http://yummyorange.com/downloads/x.zip", "a plain-HTTP ZIP address"), ("url", "file:///tmp/x.zip", "a file: address"),
            ("url", "https://user:secret@yummyorange.com/x.zip", "an address with a password"), ("url", "http://127.0.0.1:8000/x.zip", "a localhost ZIP from an HTTPS feed"),
            ("releaseNotesURL", "http://example.com/notes", "plain-HTTP release notes"), ("published", "yesterday", "a date that isn’t one"),
            ("minimumSystemVersion", "thirteen", "a minimum macOS in words"), ("releaseNotes", 5, "notes that aren’t text"),
        ]
        for (key, value, label) in badValues {
            var bad = goodFeed()
            bad[key] = value
            let e = parse(bad).1
            c.check("refused: \(label)", isBadFeed(e, mentioning: key), e?.localizedDescription ?? "accepted")
        }
        let notJSON = (try? UpdateFeed.parse(Data("<html>".utf8), feedURL: feedURL)) == nil
        let array = parse([goodFeed()]).1
        let huge = error { _ = try UpdateFeed.parse(Data(repeating: 0x20, count: UpdateFeed.maxFeedBytes + 1), feedURL: feedURL) }
        c.check("refused: a page that isn’t JSON, a JSON array, a feed over 64 KB",
                notJSON && isBadFeed(array, mentioning: "JSON object") && isBadFeed(huge, mentioning: "64 KB"))
        var local = goodFeed()
        local["url"] = "http://127.0.0.1:8000/downloads/YummyOrange-1.0.1.zip"
        c.check("a feed on this Mac (http://127.0.0.1, for tests) may point at a ZIP there too",
                parse(local, feed: URL(string: "http://127.0.0.1:8000/updates/appcast.json")!).0 != nil)
        var long = goodFeed()
        long["releaseNotes"] = String(repeating: "x", count: 10_000)
        c.check("long release notes are cut to 4,000 characters", parse(long).0?.releaseNotes?.count == UpdateFeed.maxNotesCharacters)
        // The feed's addresses stay on its own site: the download and the release notes link.
        let away: [(String, String, String)] = [
            ("url", "https://downloads.example.com/YummyOrange-1.0.1.zip", "a ZIP on another site"),
            ("url", "https://yummyorange.com:8443/downloads/YummyOrange-1.0.1.zip", "a ZIP on another port of the same host"),
            ("releaseNotesURL", "https://phishing.example/notes", "release notes on another site"),
        ]
        for (key, value, label) in away {
            var bad = goodFeed()
            bad[key] = value
            let e = parse(bad).1
            c.check("refused: \(label)", isBadFeed(e, mentioning: key) && isBadFeed(e, mentioning: "away"), e?.localizedDescription ?? "accepted")
        }
        var sameSite = goodFeed()
        sameSite["url"] = "https://YummyOrange.COM/downloads/YummyOrange-1.0.1.zip"
        c.check("an absolute address on the feed’s own site (any letter case) is fine", parse(sameSite).0 != nil)

        // Which builds count.
        let higher = item(build: "2"), same = item(build: "1"), lower = item(build: "0.9"), unreadable = item(build: "1")
        c.check("a higher build is offered", UpdateFeed.evaluate(higher, currentBuild: "1", system: system) == .available(higher))
        c.check("the same build or a lower one is not (never install a lower build)",
                UpdateFeed.evaluate(same, currentBuild: "1", system: system) == .upToDate(same)
                && UpdateFeed.evaluate(lower, currentBuild: "1", system: system) == .upToDate(lower)
                && UpdateFeed.evaluate(higher, currentBuild: "2.0", system: system) == .upToDate(higher))
        c.check("a running build that isn’t a version is never offered anything", UpdateFeed.evaluate(unreadable, currentBuild: "dev", system: system) == .upToDate(unreadable))
        let needs14 = item(minimum: "14.0"), needs13_6 = item(minimum: "13.6"), noMinimum = item(minimum: nil)
        c.check("minimumSystemVersion: a release for macOS 14 isn’t offered on 13.6; one for 13.6 or with no minimum is",
                UpdateFeed.evaluate(needs14, currentBuild: "1", system: system) == .needsNewerSystem(needs14)
                && UpdateFeed.evaluate(needs13_6, currentBuild: "1", system: system) == .available(needs13_6)
                && UpdateFeed.evaluate(noMinimum, currentBuild: "1", system: system) == .available(noMinimum))
    }

    // MARK: The feed's signature

    static func feedSignature(_ c: Checker) {
        let key = Curve25519.Signing.PrivateKey(), other = Curve25519.Signing.PrivateKey(), backup = Curve25519.Signing.PrivateKey()
        guard let feed = try? JSONSerialization.data(withJSONObject: goodFeed(), options: [.sortedKeys]) else {
            c.check("a feed to sign", false)
            return
        }
        func check(_ data: Data, _ signature: Data, keys: [Curve25519.Signing.PublicKey] = [key.publicKey]) -> UpdateError? {
            error { try UpdateFeed.checkSignature(of: data, signatureFile: signature, keys: keys) }
        }
        let good = feedSignatureFile(feed, key)
        c.check("the feed’s signature is appcast.json.sig next to it",
                UpdateFeed.signatureURL(for: feedURL).absoluteString == "https://yummyorange.com/updates/appcast.json.sig")
        c.check("a feed signed with the release key passes (also with a newline after the signature)",
                check(feed, good) == nil && check(feed, good + Data("\n".utf8)) == nil)
        var changed = feed
        changed[changed.count / 2] ^= 0x01
        c.check("a feed changed after signing is refused (its release notes, links or download could be anyone’s)",
                check(changed, good) == .badFeedSignature)
        c.check("a feed signed with another key is refused", check(feed, feedSignatureFile(feed, other)) == .badFeedSignature)
        c.check("a missing, empty, non-base64, short or oversized signature file is refused",
                check(feed, Data()) == .badFeedSignature && check(feed, Data("not base64!".utf8)) == .badFeedSignature
                && check(feed, Data(Data(count: 63).base64EncodedString().utf8)) == .badFeedSignature
                && check(feed, good + Data(repeating: 0x20, count: UpdateFeed.maxSignatureBytes)) == .badFeedSignature)
        c.check("with two trusted keys (the release key and a backup), a feed signed with either passes",
                check(feed, feedSignatureFile(feed, backup), keys: [key.publicKey, backup.publicKey]) == nil
                && check(feed, good, keys: [key.publicKey, backup.publicKey]) == nil
                && check(feed, feedSignatureFile(feed, other), keys: [key.publicKey, backup.publicKey]) == .badFeedSignature)
        c.check("no trusted key at all passes nothing", check(feed, good, keys: []) == .badFeedSignature)
    }

    // MARK: Length, checksum, signature

    static func archive(_ c: Checker, _ dir: URL) {
        let key = Curve25519.Signing.PrivateKey(), otherKey = Curve25519.Signing.PrivateKey()
        var bytes = Data(count: 200_000)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 2_654_435_761 >> 13) }
        let file = dir.appendingPathComponent("archive.zip"), tampered = dir.appendingPathComponent("tampered.zip")
        try? bytes.write(to: file)
        var flipped = bytes
        flipped[100_000] ^= 0x01
        try? flipped.write(to: tampered)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard let signature = try? key.signature(for: bytes), let otherSignature = try? otherKey.signature(for: bytes) else {
            c.check("signing works", false)
            return
        }
        var good = item()
        good.length = bytes.count
        good.sha256 = sha
        good.signature = signature

        c.check("SHA-256 of a file matches CryptoKit’s over its bytes", (try? UpdateArchiveCheck.sha256(of: file)) == sha)
        c.check("a good download passes length, checksum and signature", error { try UpdateArchiveCheck.verify(file, item: good, key: key.publicKey) } == nil)
        c.check("the length check refuses a file of another size",
                error { try UpdateArchiveCheck.checkLength(of: file, expected: bytes.count + 1) } == .wrongLength(expected: bytes.count + 1, actual: bytes.count))
        c.check("the checksum check refuses a file with one byte changed", error { try UpdateArchiveCheck.checkChecksum(of: tampered, expected: sha) } == .wrongChecksum)
        c.check("the signature check refuses a file with one byte changed",
                error { try UpdateArchiveCheck.checkSignature(of: tampered, signature: signature, key: key.publicKey) } == .badSignature)
        c.check("the signature check refuses a signature made with another key",
                error { try UpdateArchiveCheck.checkSignature(of: file, signature: otherSignature, key: key.publicKey) } == .badSignature)
        var wrongSHA = good
        wrongSHA.sha256 = String(repeating: "0", count: 64)
        c.check("verify: the intact file with a wrong checksum in the feed is refused (by the checksum)",
                error { try UpdateArchiveCheck.verify(file, item: wrongSHA, key: key.publicKey) } == .wrongChecksum)
        var wrongLength = good
        wrongLength.length = bytes.count - 1
        c.check("verify: the intact file with a wrong length in the feed is refused (by the length)",
                error { try UpdateArchiveCheck.verify(file, item: wrongLength, key: key.publicKey) } == .wrongLength(expected: bytes.count - 1, actual: bytes.count))
        var forged = good
        forged.sha256 = SHA256.hash(data: flipped).map { String(format: "%02x", $0) }.joined()
        c.check("verify: a changed file whose feed was changed to match is refused (by the signature)",
                error { try UpdateArchiveCheck.verify(tampered, item: forged, key: key.publicKey) } == .badSignature)
        var otherSigned = good
        otherSigned.signature = otherSignature
        c.check("verify: the right file signed with the wrong key is refused",
                error { try UpdateArchiveCheck.verify(file, item: otherSigned, key: key.publicKey) } == .badSignature)
        let raw = key.publicKey.rawRepresentation.base64EncodedString()
        c.check("the public key reads from base64 (32 bytes); anything else is no key",
                UpdateArchiveCheck.publicKey(base64: raw)?.rawRepresentation == key.publicKey.rawRepresentation
                && UpdateArchiveCheck.publicKey(base64: " \(raw)\n") != nil
                && UpdateArchiveCheck.publicKey(base64: Data(count: 31).base64EncodedString()) == nil
                && UpdateArchiveCheck.publicKey(base64: "garbage") == nil && UpdateArchiveCheck.publicKey(base64: nil) == nil
                && UpdateArchiveCheck.publicKey(base64: "") == nil)
        let second = otherKey.publicKey.rawRepresentation.base64EncodedString()
        let five = (0..<5).map { _ in Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString() }
        c.check("DWUpdatePublicKey may list up to four keys (spaces or commas); a list with a bad key, or five, is no key at all",
                UpdateArchiveCheck.publicKeys(base64: "\(raw) \(second)").count == 2 && UpdateArchiveCheck.publicKeys(base64: "\(raw),\(second)").count == 2
                && UpdateArchiveCheck.publicKeys(base64: raw).count == 1 && UpdateArchiveCheck.publicKeys(base64: "\(raw) garbage").isEmpty
                && UpdateArchiveCheck.publicKeys(base64: five.joined(separator: " ")).isEmpty
                && UpdateArchiveCheck.publicKeys(base64: "").isEmpty && UpdateArchiveCheck.publicKeys(base64: nil).isEmpty)
        c.check("a download signed with the backup key passes when both keys are trusted",
                error { try UpdateArchiveCheck.verify(file, item: otherSigned, keys: [key.publicKey, otherKey.publicKey]) } == nil)
    }

    // MARK: Transport rules (no network)

    static func transport(_ c: Checker) {
        func ok(_ s: String, _ loopback: Bool) -> Bool { UpdateTransport.isAllowed(URL(string: s)!, loopbackHTTP: loopback) }
        c.check("HTTPS is allowed; plain HTTP, file:, ftp: and addresses with a password are not",
                ok("https://yummyorange.com/updates/appcast.json", false) && !ok("http://yummyorange.com/x", false)
                && !ok("http://yummyorange.com/x", true) && !ok("file:///tmp/x", true) && !ok("ftp://yummyorange.com/x", true)
                && !ok("https://a:b@yummyorange.com/x", false) && !ok("https:///nohost", false))
        c.check("plain HTTP only to this Mac, and only when allowed (a feed on localhost)",
                ok("http://127.0.0.1:8000/x", true) && ok("http://localhost:8000/x", true) && ok("http://[::1]:8000/x", true)
                && !ok("http://127.0.0.1:8000/x", false) && !ok("http://192.168.1.2/x", true) && !ok("http://localhost.example.com/x", true))
        let fetched = error { _ = try UpdateTransport.fetch(URL(string: "http://example.com/appcast.json")!, userAgent: "test") }
        let downloaded = error {
            try UpdateTransport.download(URL(string: "http://127.0.0.1:9/x.zip")!, to: FileManager.default.temporaryDirectory.appendingPathComponent("dw-never-\(UUID().uuidString)"),
                                         length: 10, loopbackHTTP: false, userAgent: "test") { _ in }
        }
        c.check("a plain-HTTP feed or download is refused before any request is made",
                fetched == .insecureURL("http://example.com/appcast.json") && downloaded == .insecureURL("http://127.0.0.1:9/x.zip"),
                "\(String(describing: fetched)) \(String(describing: downloaded))")
        c.check("requests carry a fixed Accept-Language (en), never the person’s languages",
                UpdateTransport.fixedHeaders["Accept-Language"] == "en")
    }

    // MARK: Code signatures

    static func codeSignature(_ c: Checker, _ kit: TestApps) {
        let folder = kit.dir.appendingPathComponent("sign", isDirectory: true)
        let adHocRunning = CodeSigner(identifier: "com.yummyorange.app", teamID: nil, isAdHoc: true)
        func verify(_ app: URL, _ running: CodeSigner, test: Bool = false) -> UpdateError? {
            error { try CodeSignatureCheck.verify(app: app, bundleID: "com.yummyorange.app", running: running, localTestMode: test, network: false) }
        }
        guard let adHoc = kit.make("adhoc", in: folder, version: "1.0.1", build: "2", signing: .adHoc),
              let unsigned = kit.make("unsigned", in: folder, version: "1.0.1", build: "2", signing: .none),
              let adHocOtherID = kit.make("adhoc-other-id", in: folder, version: "1.0.1", build: "2", signing: .adHoc, identifier: "local.other") else {
            c.check("tiny test apps build and sign ad hoc", false, kit.notes.joined(separator: "; "))
            return
        }
        c.check("an ad-hoc app reads as ad hoc, with no team", CodeSigner.of(adHoc).isAdHoc && CodeSigner.of(adHoc).teamID == nil
                && CodeSigner.of(adHoc).identifier == "com.yummyorange.app")
        c.check("an unsigned app reads as unsigned", !CodeSigner.of(unsigned).isSigned)
        c.check("a running app without a team refuses every update outside the local test mode",
                { if case .badCodeSignature(let m) = verify(adHoc, adHocRunning) { return m.contains("isn’t signed by its developer") }; return false }())
        c.check("local test mode: an ad-hoc running app takes an ad-hoc update with the same identifier", verify(adHoc, adHocRunning, test: true) == nil)
        c.check("local test mode still refuses an unsigned update, and one signed under another identifier",
                verify(unsigned, adHocRunning, test: true) == .badCodeSignature("The new version isn’t signed.")
                && verify(adHocOtherID, adHocRunning, test: true) != nil)
        c.check("this test process is not an app, so its updater is off and says why",
                Updater.Environment.app().unavailableReason?.contains("runs as an app") == true)

        // Which policy a running app applies, by how it is signed.
        let developerID = CodeSigner(identifier: "com.yummyorange.app", teamID: "ABCDE12345", isAdHoc: false, isDeveloperID: true)
        let development = CodeSigner(identifier: "com.yummyorange.app", teamID: "ABCDE12345", isAdHoc: false, isDeveloperID: false)
        let strictest = try? CodeSignatureCheck.policy(bundleID: "com.yummyorange.app", running: developerID, localTestMode: false)
        c.check("a Developer ID copy asks for Developer ID (leaf and intermediate), its team, the hardened runtime, a stapled ticket and Gatekeeper",
                strictest.map { $0.requirement.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists")
                    && $0.requirement.contains("certificate 1[field.1.2.840.113635.100.6.2.6] exists")
                    && $0.requirement.contains("leaf[subject.OU] = \"ABCDE12345\"") && $0.requirement.contains("identifier \"com.yummyorange.app\"")
                    && $0.hardenedRuntime && $0.stapledTicket && $0.gatekeeper != nil && $0.strict } == true,
                strictest?.requirement ?? "no policy")
        let devPolicy = try? CodeSignatureCheck.policy(bundleID: "com.yummyorange.app", running: development, localTestMode: false)
        c.check("an Apple Development copy (a developer’s own build) asks for its team and the hardened runtime, not Developer ID",
                devPolicy.map { !$0.requirement.contains("6.1.13") && $0.requirement.contains("leaf[subject.OU] = \"ABCDE12345\"")
                    && $0.hardenedRuntime && !$0.stapledTicket && $0.gatekeeper == nil } == true, devPolicy?.requirement ?? "no policy")
        let flags = CodeSignatureCheck.flags(strict: true, network: false).rawValue, loose = CodeSignatureCheck.flags(strict: false, network: true).rawValue
        c.check("the check validates strictly, every architecture and nested code, symbolic links only inside the bundle, app-like bundles only",
                flags & UInt32(kSecCSStrictValidate) != 0 && flags & UInt32(kSecCSCheckAllArchitectures) != 0 && flags & UInt32(kSecCSCheckNestedCode) != 0
                && flags & UInt32(kSecCSRestrictSymlinks) != 0 && flags & UInt32(kSecCSRestrictToAppLike) != 0
                && flags & SecCSFlags.noNetworkAccess.rawValue != 0
                && loose & UInt32(kSecCSStrictValidate) == 0 && loose & UInt32(kSecCSRestrictSymlinks) != 0 && loose & SecCSFlags.noNetworkAccess.rawValue == 0)
        // A notarized, stapled Developer ID app on this Mac, when there is one: proof that the ticket and Developer ID
        // are read the way a real release carries them (read only; nothing is validated or sent anywhere).
        if let notarized = stapledDeveloperIDApp() {
            let details = CodeSignatureCheck.details(of: notarized)
            c.check("a notarized app on this Mac (\(notarized.lastPathComponent)) reads as Developer ID, with the hardened runtime and a stapled ticket",
                    CodeSigner.of(notarized).isDeveloperID && details?.hardenedRuntime == true && details?.stapledTicket == true,
                    "\(CodeSigner.of(notarized)) \(String(describing: details))")
        } else {
            c.notes.append("no stapled Developer ID app in /Applications: the stapled-ticket reading was checked only on apps without one")
        }

        guard let team = kit.team, let signed = kit.make("signed", in: folder, version: "1.0.1", build: "2", signing: .identity) else {
            c.notes.append("no Apple Development or Developer ID identity on this Mac: the team checks were skipped")
            return
        }
        let running = CodeSigner(identifier: "com.yummyorange.app", teamID: team, isAdHoc: false)
        c.check("a freshly built app signed with \(kit.identityName ?? "this Mac’s identity") reads its team (\(team)) and identifier",
                CodeSigner.of(signed) == CodeSigner(identifier: "com.yummyorange.app", teamID: team, isAdHoc: false))
        c.check("an update signed by the running app’s team, with its identifier, passes the strict check", verify(signed, running) == nil,
                verify(signed, running)?.localizedDescription ?? "")
        let otherTeam = CodeSigner(identifier: "com.yummyorange.app", teamID: "AAAAAAAAAA", isAdHoc: false)
        c.check("the same update is refused by an app of another team (an update from another identity, as that app sees it)",
                { if case .badCodeSignature(let m) = verify(signed, otherTeam) { return m.contains(team) && m.contains("AAAAAAAAAA") }; return false }(),
                verify(signed, otherTeam)?.localizedDescription ?? "accepted")
        c.check("an ad-hoc update is refused by a signed app", verify(adHoc, running) != nil)
        c.check("an unsigned update is refused by a signed app", verify(unsigned, running) == .badCodeSignature("The new version isn’t signed."))
        if let otherID = kit.make("other-id", in: folder, version: "1.0.1", build: "2", signing: .identity, identifier: "local.other") {
            c.check("an update signed by the same team under another identifier is refused", verify(otherID, running) != nil)
        }
        if let plistLies = kit.make("plist-other", in: folder, bundleID: "local.other", version: "1.0.1", build: "2", signing: .identity,
                                    identifier: "com.yummyorange.app") {
            var claim = item()
            claim.version = "1.0.1"
            c.check("an app whose Info.plist names another bundle identifier is refused by the Info.plist check",
                    { if case .badApp = error({ try UpdateInstaller.checkInfo(of: plistLies, item: claim, bundleID: "com.yummyorange.app", installedBuild: "1", system: system) }) { return true }; return false }())
        }
        // Changed after signing: a sealed resource, then the Info.plist (a build number bumped by hand).
        if let resource = kit.make("tampered-resource", in: folder, version: "1.0.1", build: "2", signing: .identity),
           let plist = kit.make("tampered-plist", in: folder, version: "1.0.1", build: "2", signing: .identity) {
            try? Data("changed".utf8).write(to: resource.appendingPathComponent("Contents/Resources/marker.txt"))
            let info = plist.appendingPathComponent("Contents/Info.plist")
            if let dict = NSMutableDictionary(contentsOf: info) {
                dict["CFBundleVersion"] = "99"
                dict.write(to: info, atomically: true)
            }
            c.check("an app changed after signing is refused (a resource, the Info.plist)",
                    verify(resource, running) != nil && verify(plist, running) != nil,
                    "resource \(verify(resource, running)?.localizedDescription ?? "accepted"), plist \(verify(plist, running)?.localizedDescription ?? "accepted")")
        }

        // What a Developer ID copy refuses: anything this Mac's development identity signs, however valid.
        let asDeveloperID = CodeSigner(identifier: "com.yummyorange.app", teamID: team, isAdHoc: false, isDeveloperID: true)
        let notDevID = verify(signed, asDeveloperID)
        c.check("a Developer ID copy refuses an update of its own team signed with a certificate that isn’t Developer ID",
                { if case .badCodeSignature(let m) = notDevID { return m.contains("Developer ID") && m.contains(team) }; return false }(),
                notDevID?.localizedDescription ?? "accepted")
        c.check("this Mac’s \(kit.identityName ?? "identity") signs as not Developer ID", !CodeSigner.of(signed).isDeveloperID || kit.identityName?.hasPrefix("Developer ID") == true)
        if let plain = kit.make("no-runtime", in: folder, version: "1.0.1", build: "2", signing: .identity, runtime: false) {
            let e = verify(plain, running)
            c.check("an update without the hardened runtime is refused", { if case .badCodeSignature(let m) = e { return m.contains("hardened runtime") }; return false }(),
                    e?.localizedDescription ?? "accepted")
        }
        // The ticket and Gatekeeper steps on their own: the team's requirement passes, then each step decides.
        guard var teamOnly = try? CodeSignatureCheck.policy(bundleID: "com.yummyorange.app", running: running, localTestMode: false) else {
            c.check("the team’s policy", false)
            return
        }
        var ticket = teamOnly
        ticket.stapledTicket = true
        let unstapled = error { try CodeSignatureCheck.verify(app: signed, policy: ticket, network: false) }
        c.check("an update without a stapled notarization ticket is refused when the policy asks for one",
                { if case .badCodeSignature(let m) = unstapled { return m.contains("notarized") }; return false }(), unstapled?.localizedDescription ?? "accepted")
        var asked: [URL] = []
        teamOnly.gatekeeper = { asked.append($0); return "rejected by the stand-in" }
        let rejected = error { try CodeSignatureCheck.verify(app: signed, policy: teamOnly, network: false) }
        teamOnly.gatekeeper = { asked.append($0); return nil }
        let accepted = error { try CodeSignatureCheck.verify(app: signed, policy: teamOnly, network: false) }
        c.check("Gatekeeper is asked about the new app, and its rejection refuses the update (a stand-in answers here)",
                { if case .badCodeSignature(let m) = rejected { return m.contains("rejected by the stand-in") }; return false }()
                && accepted == nil && asked.count == 2 && asked.first?.standardizedFileURL == signed.standardizedFileURL,
                "\(String(describing: rejected)) \(String(describing: accepted)) \(asked)")
    }

    /// The first app in /Applications with a stapled ticket that reads as Developer ID, if any.
    static func stapledDeveloperIDApp() -> URL? {
        let apps = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil)) ?? []
        return apps.sorted { $0.path < $1.path }.first {
            $0.pathExtension == "app" && FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/CodeResources").path)
                && CodeSigner.of($0).isDeveloperID
        }
    }

    // MARK: Permissions of an unpacked app

    static func permissions(_ c: Checker, _ kit: TestApps) {
        let fm = FileManager.default
        let root = kit.dir.appendingPathComponent("modes", isDirectory: true)
        guard let app = kit.make("YummyOrange", in: root.appendingPathComponent("loose"), version: "1.0.1", build: "2", signing: .none) else {
            c.check("a test app for the permission check", false)
            return
        }
        let tool = app.appendingPathComponent("Contents/Resources/marker.txt"), resources = app.appendingPathComponent("Contents/Resources")
        chmod(tool.path, 0o777)
        chmod(resources.path, 0o2777)
        let zip = root.appendingPathComponent("loose.zip")
        _ = TestApps.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
        func mode(_ url: URL) -> mode_t { var s = stat(); lstat(url.path, &s); return s.st_mode & 0o7777 }
        let raw = root.appendingPathComponent("raw")
        try? fm.createDirectory(at: raw, withIntermediateDirectories: true)
        _ = TestApps.run("/usr/bin/ditto", ["-x", "-k", zip.path, raw.path])
        let rawTool = raw.appendingPathComponent("YummyOrange.app/Contents/Resources/marker.txt")
        let unpacked = Result { try UpdateInstaller.expand(zip, into: root.appendingPathComponent("expanded")) }
        guard case .success(let expanded) = unpacked else {
            c.check("a ZIP with loose permissions unpacks", false, String(describing: unpacked))
            return
        }
        let expandedTool = expanded.appendingPathComponent("Contents/Resources/marker.txt")
        let expandedResources = expanded.appendingPathComponent("Contents/Resources")
        c.check("unpacked, nothing in the new app is writable by others or set-group-ID (ditto alone keeps the ZIP’s \(String(mode(rawTool), radix: 8)))",
                mode(rawTool) & 0o022 != 0 && mode(expandedTool) & 0o022 == 0 && mode(expandedResources) & 0o7022 == 0
                && mode(expandedTool) & 0o700 == 0o700,
                "file \(String(mode(expandedTool), radix: 8)), folder \(String(mode(expandedResources), radix: 8))")
    }

    // MARK: Replace

    static func replace(_ c: Checker, _ kit: TestApps) {
        let fm = FileManager.default
        let root = kit.dir.appendingPathComponent("replace", isDirectory: true)
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let signing: TestApps.Signing = kit.team == nil ? .adHoc : .identity
        guard let installed = kit.make("YummyOrange", in: apps, version: "1.0.0", build: "1", signing: signing, marker: "old"),
              let new = kit.make("new", in: root.appendingPathComponent("new"), version: "1.0.1", build: "2", signing: signing, marker: "new") else {
            c.check("test apps for the replace step", false, kit.notes.joined(separator: "; "))
            return
        }
        func marker(_ app: URL) -> String? { try? String(contentsOf: app.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8) }
        func build(_ app: URL) -> String? { NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String }

        let upgrade = item(version: "1.0.1", build: "2")
        c.check("Info.plist check: YummyOrange 1.0.1 (2) over build 1 passes",
                error { try UpdateInstaller.checkInfo(of: new, item: upgrade, bundleID: "com.yummyorange.app", installedBuild: "1", system: system) } == nil)
        c.check("Info.plist check: refused over build 2 or 3 (never a lower or equal build)",
                { if case .notNewer = error({ try UpdateInstaller.checkInfo(of: new, item: upgrade, bundleID: "com.yummyorange.app", installedBuild: "3", system: system) }) { return true }; return false }()
                && error({ try UpdateInstaller.checkInfo(of: new, item: upgrade, bundleID: "com.yummyorange.app", installedBuild: "2", system: system) }) != nil)
        c.check("Info.plist check: refused when the app isn’t the version and build the feed promised (a feed saying build 5 for build 2)",
                { if case .badApp = error({ try UpdateInstaller.checkInfo(of: new, item: item(version: "1.0.1", build: "5"), bundleID: "com.yummyorange.app", installedBuild: "1", system: system) }) { return true }; return false }()
                && error({ try UpdateInstaller.checkInfo(of: new, item: item(version: "1.0.2", build: "2"), bundleID: "com.yummyorange.app", installedBuild: "1", system: system) }) != nil)
        c.check("Info.plist check: refused for another bundle identifier",
                { if case .badApp = error({ try UpdateInstaller.checkInfo(of: new, item: upgrade, bundleID: "local.other", installedBuild: "1", system: system) }) { return true }; return false }())
        if let needs99 = kit.make("needs99", in: root.appendingPathComponent("new99"), version: "1.0.1", build: "2", signing: .none, minimumSystem: "99.0") {
            c.check("Info.plist check: refused when the app needs a newer macOS",
                    { if case .badApp(let m) = error({ try UpdateInstaller.checkInfo(of: needs99, item: upgrade, bundleID: "com.yummyorange.app", installedBuild: "1", system: system) }) { return m.contains("99.0") }; return false }())
        }

        c.check("a fake installed app in a writable folder can be replaced", UpdateInstaller.blocker(for: installed) == nil,
                UpdateInstaller.blocker(for: installed) ?? "")
        let result = error { _ = try UpdateInstaller.replace(installed, with: new) }
        let leftovers = (try? fm.contentsOfDirectory(atPath: apps.path)) ?? []
        c.check("replace: the installed bundle is now the new one, in the same place, and the new copy is gone from where it was",
                result == nil && marker(installed) == "new" && build(installed) == "2" && !fm.fileExists(atPath: new.path) && leftovers == ["YummyOrange.app"],
                "\(result?.localizedDescription ?? "") marker \(marker(installed) ?? "-"), build \(build(installed) ?? "-"), folder \(leftovers)")
        if let team = kit.team {
            let running = CodeSigner(identifier: "com.yummyorange.app", teamID: team, isAdHoc: false)
            c.check("replace: the swapped-in app’s signature is still valid", error {
                try CodeSignatureCheck.verify(app: installed, bundleID: "com.yummyorange.app", running: running, localTestMode: false, network: false)
            } == nil)
        }

        // The second check, where the new app now is: when it fails, the old app is put back.
        if let before = kit.make("YummyOrange", in: root.appendingPathComponent("Rollback"), version: "1.0.0", build: "1", signing: signing, marker: "old"),
           let bad = kit.make("bad", in: root.appendingPathComponent("bad"), version: "1.0.1", build: "2", signing: signing, marker: "swapped") {
            var checked: [URL] = []
            let refused = error {
                _ = try UpdateInstaller.replace(before, with: bad) { placed in
                    checked.append(placed)
                    throw UpdateError.badCodeSignature("changed after the first check (test)")
                }
            }
            let folder = (try? fm.contentsOfDirectory(atPath: before.deletingLastPathComponent().path)) ?? []
            c.check("replace: a new app that fails its check where it was installed is swapped out again, and the old one is back",
                    refused == .badCodeSignature("changed after the first check (test)") && checked.count == 1 && marker(before) == "old"
                    && build(before) == "1" && folder == ["YummyOrange.app"],
                    "\(String(describing: refused)) marker \(marker(before) ?? "-") folder \(folder)")
        }
        // The same through place(): an app that isn't what the feed promised once it is in place goes back out.
        if let current = kit.make("YummyOrange", in: root.appendingPathComponent("Placed"), version: "1.0.0", build: "1", signing: signing, marker: "old"),
           let wrong = kit.make("wrong", in: root.appendingPathComponent("wrong"), version: "1.0.1", build: "3", signing: signing, marker: "wrong") {
            let running = kit.team.map { CodeSigner(identifier: "com.yummyorange.app", teamID: $0, isAdHoc: false) }
                ?? CodeSigner(identifier: "com.yummyorange.app", teamID: nil, isAdHoc: true)
            var env = Updater.Environment(feedURL: nil, publicKeys: [], appURL: current, bundleID: "com.yummyorange.app", version: "1.0.0", build: "1",
                                          signer: running, fallbackFolders: [root.appendingPathComponent("Unused")], system: system)
            env.localTestMode = kit.team == nil
            env.networkForCodeChecks = false
            let outcome = Result { try Updater(environment: env).place(Updater.Prepared(folder: wrong.deletingLastPathComponent(), app: wrong), upgrade) }
            c.check("place: the installed app is checked again once swapped in (here: build 3 where the feed said 2), and the old one put back",
                    { if case .failure(UpdateError.badApp) = outcome { return true }; return false }() && marker(current) == "old" && build(current) == "1",
                    String(describing: outcome))
        }
        let blockedByOwnership = UpdateInstaller.blocker(for: installed, ignoresOwnership: true)
        c.check("an app on a disk that ignores ownership (exFAT, say) isn’t replaced in place, and the reason says why",
                blockedByOwnership?.contains("ownership") == true && UpdateInstaller.blocker(for: installed, ignoresOwnership: false) == nil,
                blockedByOwnership ?? "nil")
        let ownStaging = UpdateInstaller.stagingFolder(for: installed, ignoresOwnership: true)
        c.check("…and its download is checked in the person’s own temporary folder, not on that disk",
                ownStaging.path.hasPrefix(fm.temporaryDirectory.path) && ownStaging.lastPathComponent.hasPrefix("YummyOrange update "), ownStaging.path)
        try? fm.removeItem(at: ownStaging)

        // A folder the person can't change: the new app goes to the fallback folder, and the installed one stays.
        let locked = root.appendingPathComponent("Locked", isDirectory: true)
        guard let stays = kit.make("YummyOrange", in: locked, version: "1.0.0", build: "1", signing: signing, marker: "old"),
              let parkedNew = kit.make("staged", in: root.appendingPathComponent("staged"), version: "1.0.1", build: "2", signing: signing, marker: "new") else { return }
        _ = TestApps.run("/bin/chmod", ["555", locked.path])
        let blocked = UpdateInstaller.blocker(for: stays)
        c.check("a folder without write permission is reported, naming it", blocked?.contains("permission") == true && blocked?.contains("Locked") == true, blocked ?? "nil")
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        var env = Updater.Environment(feedURL: nil, publicKeys: [], appURL: stays, bundleID: "com.yummyorange.app", version: "1.0.0", build: "1",
                                      signer: .unsigned, fallbackFolders: [downloads], system: system)
        env.unavailableReason = nil
        let updater = Updater(environment: env)
        let outcome = try? updater.place(Updater.Prepared(folder: parkedNew.deletingLastPathComponent(), app: parkedNew), upgrade)
        let parked = downloads.appendingPathComponent("YummyOrange 1.0.1.app")
        if case .manual(let url, let reason)? = outcome {
            c.check("place: with the folder locked, the new app goes to the fallback folder as “YummyOrange 1.0.1.app”, and the installed one is untouched",
                    url.standardizedFileURL == parked.standardizedFileURL && marker(parked) == "new" && marker(stays) == "old" && reason.contains("permission"),
                    "\(url.path) \(reason)")
        } else {
            c.check("place: with the folder locked, the update is handed over instead", false, String(describing: outcome))
        }
        _ = TestApps.run("/bin/chmod", ["755", locked.path])
        if let again = kit.make("again", in: root.appendingPathComponent("again"), version: "1.0.1", build: "2", signing: .none) {
            let second = try? UpdateInstaller.park(again, version: "1.0.1", in: downloads)
            c.check("a second copy is parked beside the first as “YummyOrange 1.0.1 2.app”", second?.lastPathComponent == "YummyOrange 1.0.1 2.app")
        }
        // Downloads refused (as macOS's privacy prompt can): the next folder takes it, and nothing is lost.
        let deniedDownloads = root.appendingPathComponent("Denied Downloads", isDirectory: true)
        let userApplications = root.appendingPathComponent("Applications (user)", isDirectory: true)
        try? fm.createDirectory(at: deniedDownloads, withIntermediateDirectories: true)
        _ = TestApps.run("/bin/chmod", ["555", deniedDownloads.path])
        if let third = kit.make("third", in: root.appendingPathComponent("third"), version: "1.0.1", build: "2", signing: .none, marker: "third") {
            let parkedThere = try? UpdateInstaller.park(third, version: "1.0.1", in: [deniedDownloads, userApplications])
            c.check("when the first fallback folder can’t be written, the new app goes to the next one (~/Applications, then a temporary folder)",
                    parkedThere?.deletingLastPathComponent().standardizedFileURL == userApplications.standardizedFileURL
                    && parkedThere.flatMap(marker) == "third" && Updater.Environment.app().fallbackFolders.count >= 2,
                    parkedThere?.path ?? "nil")
        }
        _ = TestApps.run("/bin/chmod", ["755", deniedDownloads.path])
        let translocated = URL(fileURLWithPath: "/private/var/folders/zz/T/AppTranslocation/0A1B/d/YummyOrange.app")
        c.check("an app macOS runs from a translocated copy can’t replace itself, and the reason says to move it to Applications",
                UpdateInstaller.blocker(for: translocated)?.contains("Applications") == true)
    }

    // MARK: Skip, snooze, schedule

    static func policy(_ c: Checker) {
        Settings.defaults = SettingsMemoryStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        c.check("a check is due with none before, 6 h after the last, or when the clock went back; not after 5 h",
                UpdatePolicy.isDue(lastCheck: nil, now: now, every: UpdatePolicy.interval)
                && UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-6 * 3600), now: now, every: UpdatePolicy.interval)
                && UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(3600), now: now, every: UpdatePolicy.interval)
                && !UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-5 * 3600), now: now, every: UpdatePolicy.interval))
        c.check("after a check that got no answer, the next is tried 15 minutes later, not 6 hours (nor at once, over and over)",
                !UpdatePolicy.isDue(lastCheck: nil, lastAttempt: now.addingTimeInterval(-10 * 60), now: now, every: UpdatePolicy.interval)
                && UpdatePolicy.isDue(lastCheck: nil, lastAttempt: now.addingTimeInterval(-15 * 60), now: now, every: UpdatePolicy.interval)
                && UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-7 * 3600), lastAttempt: now.addingTimeInterval(-16 * 60), now: now, every: UpdatePolicy.interval)
                && !UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-3600), lastAttempt: now.addingTimeInterval(-3600), now: now, every: UpdatePolicy.interval)
                && UpdatePolicy.isDue(lastCheck: nil, lastAttempt: now.addingTimeInterval(3600), now: now, every: UpdatePolicy.interval)
                && UpdatePolicy.retry == 15 * 60)
        c.check("the schedule: 10 s after launch, every 6 h, on wake if the last check is an hour old, a 24-hour snooze",
                UpdatePolicy.launchDelay == 10 && UpdatePolicy.interval == 6 * 3600 && UpdatePolicy.wakeGap == 3600 && UpdatePolicy.snooze == 24 * 3600
                && UpdatePolicy.tick <= 15 * 60)
        let two = item(build: "2"), three = item(version: "1.0.2", build: "3")
        c.check("a new update is announced", UpdatePolicy.shouldNotify(two, now: now) && UpdatePolicy.showsMenuItem(two))
        UpdatePreferences.notifiedBuild = "2"
        c.check("…once: not again for the same build", !UpdatePolicy.shouldNotify(two, now: now))
        UpdatePreferences.notifiedBuild = nil

        let updater = idleUpdater()
        var clock = now
        updater.now = { clock }
        updater.skip("2")
        c.check("Skip This Version: that build is neither announced nor in the menu", !UpdatePolicy.shouldNotify(two, now: now) && !UpdatePolicy.showsMenuItem(two)
                && UpdatePreferences.skippedBuild == "2")
        c.check("…but a later build is", UpdatePolicy.shouldNotify(three, now: now) && UpdatePolicy.showsMenuItem(three))
        UpdatePreferences.skippedBuild = nil

        UpdatePreferences.notifiedBuild = "2"
        updater.remindLater("2")
        c.check("Remind Me Later: quiet for 24 hours, still in the menu", !UpdatePolicy.shouldNotify(two, now: now.addingTimeInterval(23 * 3600))
                && UpdatePolicy.showsMenuItem(two) && UpdatePreferences.snoozedUntil == now.addingTimeInterval(24 * 3600))
        c.check("…announced again once the 24 hours are over", UpdatePolicy.shouldNotify(two, now: now.addingTimeInterval(24 * 3600 + 1)))
        c.check("…and a later build isn’t held back by the snooze", UpdatePolicy.shouldNotify(three, now: now.addingTimeInterval(3600)))
        clock = now.addingTimeInterval(10)
        updater.remindLater("2")
        c.check("Remind Me Later again starts a new 24 hours", UpdatePreferences.snoozedUntil == clock.addingTimeInterval(24 * 3600))
        Settings.defaults = SettingsMemoryStore()
    }

    // MARK: Notifications

    final class RecordingNotifier: UpdateNotifying {
        var grant = true
        var requests = 0, checks = 0
        var requestedOptions: [UNAuthorizationOptions] = []
        var posted: [String] = []
        var withdrawn = 0
        func requestPermission(_ options: UNAuthorizationOptions, _ done: @escaping (Bool) -> Void) {
            requests += 1
            requestedOptions.append(options)
            done(grant)
        }
        func checkPermission(_ done: @escaping (Bool) -> Void) { checks += 1; done(grant) }
        func post(_ item: UpdateItem) { posted.append(item.build) }
        func withdraw() { withdrawn += 1 }
    }

    final class RecordingUI: UpdateUI {
        var choice: UpdateChoice = .later
        var offers: [String] = []
        var told: [(String, String)] = []
        var progress: [(String, Double?)] = []
        var ended: [String?] = []
        var revealed: [URL] = []
        var relaunched: [URL] = []
        /// The answer to the restart alert, and what it was asked about.
        var restart = true
        var restartAsked: [[String]] = []
        /// Whether the relaunch helper starts.
        var helperStarts = true
        func offer(_ item: UpdateItem, current: String) -> UpdateChoice { offers.append(item.build); return choice }
        func tell(_ title: String, _ message: String) { told.append((title, message)) }
        func progress(_ title: String, _ fraction: Double?) { progress.append((title, fraction)) }
        func endProgress(_ text: String?) { ended.append(text) }
        func reveal(_ url: URL) { revealed.append(url) }
        func confirmRestart(_ unsaved: [String], version: String) -> Bool { restartAsked.append(unsaved); return restart }
        func relaunch(_ app: URL) -> Bool { relaunched.append(app); return helperStarts }
    }

    static func notifications(_ c: Checker) {
        Settings.defaults = SettingsMemoryStore()
        let ui = RecordingUI()
        let updater = idleUpdater(ui: ui)
        let notifier = RecordingNotifier()
        updater.notifier = notifier
        updater.announce(item(build: "2"))
        c.check("the first update found asks for notification permission, then posts", notifier.requests == 1 && notifier.posted == ["2"]
                && UpdatePreferences.askedForNotifications)
        c.check("…provisionally, so macOS delivers it quietly and never shows a permission prompt nobody asked for",
                notifier.requestedOptions == [[.alert, .provisional]], "\(notifier.requestedOptions.map(\.rawValue))")
        updater.announce(item(build: "2"))
        c.check("the same update isn’t announced twice", notifier.posted == ["2"])
        updater.announce(item(version: "1.0.2", build: "3"))
        c.check("a later update doesn’t ask again: it checks the permission and posts", notifier.requests == 1 && notifier.checks == 1 && notifier.posted == ["2", "3"])
        notifier.grant = false
        updater.announce(item(version: "1.0.3", build: "4"))
        c.check("with notifications turned off, nothing is posted (the menu item remains)", notifier.posted == ["2", "3"] && notifier.requests == 1)

        Settings.defaults = SettingsMemoryStore()
        let fresh = RecordingNotifier()
        fresh.grant = false
        updater.notifier = fresh
        updater.announce(item(build: "2"))
        updater.announce(item(version: "1.0.2", build: "3"))
        c.check("permission is asked for only once, even when it was declined", fresh.requests == 1 && fresh.checks == 1 && fresh.posted.isEmpty)

        updater.respond(to: .skip, build: "3")
        c.check("the notification’s Skip This Version skips that build and withdraws it", UpdatePreferences.skippedBuild == "3" && fresh.withdrawn >= 1)
        updater.respond(to: .later, build: "3")
        c.check("its Remind Me Later snoozes it", UpdatePreferences.snoozedBuild == "3" && UpdatePreferences.snoozedUntil != nil)
        updater.latest = item(version: "1.0.2", build: "3")
        ui.choice = .later
        let toldBefore = ui.told.count
        updater.respond(to: .show, build: "3")
        c.check("clicking it opens the update alert with the release notes, and installs nothing by itself",
                ui.offers == ["3"] && ui.told.count == toldBefore, "offers \(ui.offers), told \(ui.told.map(\.0))")
        ui.choice = .install
        updater.respond(to: .show, build: "3")
        c.check("…Install Update there starts the update (here: the install step, which says this updater can’t)",
                ui.offers == ["3", "3"] && ui.told.last?.0 == "YummyOrange can’t install updates.", "\(ui.told.map(\.0))")
        updater.respond(to: .show, build: "9")
        c.check("clicking one about an update no longer known checks again instead", ui.told.last?.0 == "YummyOrange can’t check for updates.", "\(ui.told.map(\.0))")
        updater.latest = nil
        Settings.defaults = SettingsMemoryStore()
    }

    // MARK: Menu

    static func menu(_ c: Checker) {
        Settings.defaults = SettingsMemoryStore()
        let ui = RecordingUI()
        let updater = idleUpdater(ui: ui)
        UpdateMenuTarget.shared.updater = updater
        let menu = AppDelegate.makeMenu(target: nil)
        let update = menu.item(withTag: UpdateMenu.updateTag), separator = menu.item(withTag: UpdateMenu.separatorTag)
        let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        c.check("the update item heads the menu, hidden while no update is known (and the separator under it)",
                menu.items.first === update && menu.items.dropFirst().first === separator && update?.isHidden == true && separator?.isHidden == true)
        let check = menu.item(withTag: UpdateMenu.checkTag)
        let checkIndex = check.map { menu.index(of: $0) } ?? -1
        c.check("“Check for Updates…” is always there, right above Settings…",
                check?.title == "Check for Updates…" && check?.isHidden == false && checkIndex >= 0
                && checkIndex + 1 < menu.items.count && menu.items[checkIndex + 1].title == "Settings…", titles.joined(separator: " | "))
        let before = MenuSnapshotView(menu: menu, open: nil).frame.size
        updater.latest = item(version: "1.0.1", build: "2")
        UpdateMenu.refresh(menu, updater: updater)
        c.check("with an update known: “Update to YummyOrange 1.0.1…” shows at the top, with the separator",
                update?.isHidden == false && update?.title == "Update to YummyOrange 1.0.1…" && separator?.isHidden == false)
        let after = MenuSnapshotView(menu: menu, open: nil).frame.size
        c.check("the menu snapshot leaves hidden items out (it grows by a row and a separator once the update shows)",
                after.height == before.height + 24 + 11, "\(before) → \(after)")
        c.check("both items have the updater’s target and are available while it is idle",
                [update, check].allSatisfy { $0?.target === UpdateMenuTarget.shared && $0?.action != nil
                    && UpdateMenuTarget.shared.validateMenuItem($0!) && !($0?.toolTip ?? "").isEmpty })
        ui.choice = .later
        if let update { menu.performActionForItem(at: menu.index(of: update)) }
        c.check("choosing the update item shows the update alert (Remind Me Later chosen here)",
                ui.offers == ["2"] && UpdatePreferences.snoozedBuild == "2", "\(ui.offers)")
        ui.choice = .skip
        if let update { menu.performActionForItem(at: menu.index(of: update)) }
        UpdateMenu.refresh(menu, updater: updater)
        c.check("…Skip This Version there hides it from the menu", update?.isHidden == true && UpdatePreferences.skippedBuild == "2")
        if let check { menu.performActionForItem(at: menu.index(of: check)) }
        c.check("choosing “Check for Updates…” checks by hand (here it says why this copy can’t)",
                ui.told.last?.0 == "YummyOrange can’t check for updates." && ui.told.last?.1 == "test: no network here")
        updater.latest = nil
        Settings.defaults = SettingsMemoryStore()
    }

    // MARK: Setting

    static func settings(_ c: Checker) {
        let store = SettingsMemoryStore()
        Settings.defaults = store
        c.check("Check for updates automatically is on by default", Settings.checkForUpdatesAutomatically)
        Settings.checkForUpdatesAutomatically = false
        c.check("turning it off is saved", !Settings.checkForUpdatesAutomatically && store.object(forKey: "checkForUpdatesAutomatically") as? Bool == false)
        let updater = idleUpdater()
        Settings.checkForUpdatesAutomatically = true
        updater.reschedule(launch: false)
        let on = updater.isScheduled
        Settings.checkForUpdatesAutomatically = false
        updater.reschedule(launch: false)
        c.check("the automatic checks follow the setting (on: scheduled; off: stopped)", on && !updater.isScheduled)
        c.check("Settings explains it, or says why this copy can’t update",
                UpdateSetting.detail(nil).contains("Nothing is installed until you choose") && UpdateSetting.detail("Not here.") == "Not here.")
        Settings.defaults = SettingsMemoryStore()
    }

    // MARK: Relaunch helper

    static func relauncher(_ c: Checker, _ dir: URL) {
        let args = Relauncher.arguments(waitingFor: 4321, run: "/usr/bin/open", "/Applications/YummyOrange.app")
        c.check("the helper is /bin/sh waiting for this process, then opening the app",
                args.count == 6 && args[0] == "-c" && args[3] == "4321" && args[4] == "/usr/bin/open" && args[5] == "/Applications/YummyOrange.app"
                && args[1].contains("kill -0") && args[1].contains("exec"))
        c.check("the helper has no time limit: it waits for as long as YummyOrange takes to quit, then opens the new app",
                !Relauncher.script.contains("-lt") && !Relauncher.script.contains("i=") && Relauncher.script.hasPrefix("while kill -0"))
        // Live, without opening anything: it waits on a `sleep`, then runs `touch`.
        let marker = dir.appendingPathComponent("relaunched")
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["1"]
        do {
            try sleeper.run()
            let helper = try Relauncher.start(waitingFor: sleeper.processIdentifier, run: "/usr/bin/touch", marker.path)
            Thread.sleep(forTimeInterval: 0.4)
            let early = FileManager.default.fileExists(atPath: marker.path)
            sleeper.waitUntilExit()
            let deadline = Date().addingTimeInterval(5)
            while helper.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            c.check("the helper waits while the process runs, and runs its command once it has exited",
                    !early && FileManager.default.fileExists(atPath: marker.path) && !helper.isRunning, "early \(early)")
        } catch {
            c.check("the relaunch helper runs", false, error.localizedDescription)
        }
    }

    // MARK: Full run against a server on 127.0.0.1

    /// `python3 -m http.server` on a free port of 127.0.0.1, serving `folder`. `redirecting`: python's http.server
    /// with three more rules: `/redirect-to/<address>` answers 302 with that address (the redirect checks),
    /// `/echo-headers` answers the request's headers as JSON, and `/slow/<path>` serves `<path>` after 1.5 s.
    final class LocalServer {
        let process = Process()
        let port: Int

        static let redirector = """
        import http.server, json, sys, time
        class H(http.server.SimpleHTTPRequestHandler):
            def do_GET(self):
                if self.path.startswith('/redirect-to/'):
                    self.send_response(302)
                    self.send_header('Location', self.path[len('/redirect-to/'):])
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                if self.path == '/echo-headers':
                    body = json.dumps(dict(self.headers.items())).encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                if self.path.startswith('/slow/'):
                    time.sleep(1.5)
                    self.path = self.path[len('/slow'):]
                return super().do_GET()
            def log_message(self, *args):
                pass
        http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), lambda *a, **k: H(*a, directory=sys.argv[2], **k)).serve_forever()
        """

        init?(serving folder: URL, redirecting: Bool = false) {
            guard let free = LocalServer.freePort() else { return nil }
            port = free
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = redirecting ? ["-I", "-c", LocalServer.redirector, String(port), folder.path]
                : ["-I", "-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", folder.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline && process.isRunning && !LocalServer.accepts(port) { Thread.sleep(forTimeInterval: 0.1) }
            guard LocalServer.accepts(port) else { stop(); return nil }
        }

        func stop() {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        static func freePort() -> Int? {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
            }
            return bound ? Int(UInt16(bigEndian: address.sin_port)) : nil
        }

        static func accepts(_ port: Int) -> Bool {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = UInt16(port).bigEndian
            return withUnsafePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
            }
        }
    }

    static func fullRun(_ c: Checker, _ kit: TestApps) {
        let fm = FileManager.default
        let root = kit.dir.appendingPathComponent("full", isDirectory: true)
        let site = root.appendingPathComponent("site", isDirectory: true)
        let downloads = site.appendingPathComponent("downloads", isDirectory: true)
        try? fm.createDirectory(at: site.appendingPathComponent("updates"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let signing: TestApps.Signing = kit.team == nil ? .adHoc : .identity
        guard let new = kit.make("YummyOrange", in: root.appendingPathComponent("release"), version: "1.0.1", build: "2", signing: signing, marker: "new"),
              let adHocNew = kit.make("YummyOrange", in: root.appendingPathComponent("release-adhoc"), version: "1.0.1", build: "2", signing: .adHoc, marker: "adhoc") else {
            c.check("test apps for the full run", false, kit.notes.joined(separator: "; "))
            return
        }
        let zip = downloads.appendingPathComponent("YummyOrange-1.0.1.zip")
        let adHocZip = downloads.appendingPathComponent("YummyOrange-adhoc.zip")
        let zipped = TestApps.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", new.path, zip.path]).status == 0
            && TestApps.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", adHocNew.path, adHocZip.path]).status == 0
        guard zipped, let bytes = try? Data(contentsOf: zip), let adHocBytes = try? Data(contentsOf: adHocZip) else {
            c.check("the release ZIP is made with ditto -c -k --keepParent", false)
            return
        }
        let key = Curve25519.Signing.PrivateKey(), otherKey = Curve25519.Signing.PrivateKey()
        func entry(_ data: Data, file: String, build: String = "2", length: Int? = nil, signer: Curve25519.Signing.PrivateKey? = nil) -> [String: Any] {
            ["version": "1.0.1", "build": build, "minimumSystemVersion": "13.0", "url": "../downloads/\(file)",
             "length": length ?? data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
             "signature": ((try? (signer ?? key).signature(for: data)) ?? Data()).base64EncodedString(),
             "releaseNotes": "Test release.", "releaseNotesURL": "../release-notes.html", "published": "2026-11-24T12:00:00Z"]
        }
        let feedFile = site.appendingPathComponent("updates/appcast.json")
        let signatureFile = site.appendingPathComponent("updates/appcast.json.sig")
        /// Writes the feed and its detached signature (made with `feedSigner`, or none at all).
        func publish(_ json: [String: Any], feedSigner: Curve25519.Signing.PrivateKey?? = .some(nil)) {
            guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? data.write(to: feedFile)
            switch feedSigner {
            case .none: try? fm.removeItem(at: signatureFile)
            case .some(let signer): try? feedSignatureFile(data, signer ?? key).write(to: signatureFile)
            }
        }
        publish(entry(bytes, file: "YummyOrange-1.0.1.zip"))

        guard let server = LocalServer(serving: site) else {
            c.check("python3 -m http.server starts on 127.0.0.1 (needs /usr/bin/python3)", false)
            return
        }
        defer { server.stop() }
        let feed = URL(string: "http://127.0.0.1:\(server.port)/updates/appcast.json")!
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        func freshInstall() -> URL? {
            try? fm.removeItem(at: apps)
            return kit.make("YummyOrange", in: apps, version: "1.0.0", build: "1", signing: signing, marker: "old")
        }
        guard let installed = freshInstall() else { c.check("a fake installed YummyOrange 1.0.0", false); return }
        func marker(_ app: URL) -> String? { try? String(contentsOf: app.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8) }
        let signer = CodeSigner.of(installed)
        var env = Updater.Environment(feedURL: feed, publicKeys: [key.publicKey], appURL: installed, bundleID: "com.yummyorange.app",
                                      version: "1.0.0", build: "1", signer: signer, fallbackFolders: [root.appendingPathComponent("Downloads")])
        env.localTestMode = signer.teamID == nil
        env.networkForCodeChecks = false
        let updater = Updater(environment: env)
        let ui = RecordingUI()
        updater.ui = ui
        updater.unsavedWork = { [] }

        // Check → download → verify → replace, step by step.
        let checked = Result { try updater.fetch() }
        guard case .success(.available(let release)) = checked else {
            c.check("check: the feed on 127.0.0.1 offers build 2", false, String(describing: checked))
            return
        }
        c.check("check: the signed feed on 127.0.0.1 offers YummyOrange 1.0.1 (build 2), its ZIP resolved next to it",
                release.url.absoluteString == "http://127.0.0.1:\(server.port)/downloads/YummyOrange-1.0.1.zip" && release.length == bytes.count)
        var fractions: [Double] = []
        let lock = NSLock()
        let prepared = Result { try updater.prepare(release) { f in lock.lock(); fractions.append(f); lock.unlock() } }
        guard case .success(let ready) = prepared else {
            c.check("download and verify", false, String(describing: prepared))
            return
        }
        c.check("download: progress rises to 100 %", !fractions.isEmpty && fractions == fractions.sorted() && fractions.last == 1.0, "\(fractions.prefix(5))… \(fractions.count)")
        c.check("verify and unpack: the new app waits in a temporary folder; the installed one is unchanged",
                fm.fileExists(atPath: ready.app.path) && marker(ready.app) == "new" && marker(installed) == "old"
                && !ready.folder.path.hasPrefix(apps.path))
        let placed = Result { try updater.place(ready, release) }
        c.check("replace: the installed YummyOrange is now 1.0.1, checked again where it is, and the temporary folder and the old copy are gone",
                (try? placed.get()) == .replaced(installed) && marker(installed) == "new" && !fm.fileExists(atPath: ready.folder.path)
                && ((try? fm.contentsOfDirectory(atPath: apps.path)) ?? []) == ["YummyOrange.app"],
                String(describing: placed))
        updater.environment.build = "2"
        c.check("check again as build 2: up to date", { if case .success(.upToDate) = Result(catching: { try updater.fetch() }) { return true }; return false }())
        updater.environment.build = "1"

        // The feed's own signature, end to end: nothing in an unsigned or changed feed is read.
        func fetchError() -> UpdateError? { error { _ = try updater.fetch() } }
        publish(entry(bytes, file: "YummyOrange-1.0.1.zip"), feedSigner: .some(otherKey))
        let otherSigned = fetchError()
        publish(entry(bytes, file: "YummyOrange-1.0.1.zip"), feedSigner: .none)
        let unsigned = fetchError()
        publish(entry(bytes, file: "YummyOrange-1.0.1.zip"))
        if var tampered = try? Data(contentsOf: feedFile), let range = tampered.range(of: Data("Test release.".utf8)) {
            tampered.replaceSubrange(range, with: Data("Call 555-0100".utf8))
            try? tampered.write(to: feedFile)
        }
        let changedNotes = fetchError()
        c.check("end to end: a feed signed with another key, a feed without its signature, and release notes changed after signing are all refused",
                otherSigned == .badFeedSignature && unsigned == .server(404) && changedNotes == .badFeedSignature,
                "\(String(describing: otherSigned)) \(String(describing: unsigned)) \(String(describing: changedNotes))")

        // What the checks refuse, end to end. The installed app must stay as it was each time.
        func refuses(_ label: String, _ json: [String: Any], _ expected: (UpdateError) -> Bool) {
            guard let app = freshInstall() else { return }
            updater.environment.appURL = app
            publish(json)
            let item: UpdateItem
            switch Result(catching: { try updater.fetch() }) {
            case .success(.available(let found)): item = found
            case let other: c.check("end to end: \(label)", false, "check gave \(other)"); return
            }
            let outcome = Result { try updater.place(try updater.prepare(item), item) }
            if case .failure(let e as UpdateError) = outcome {
                c.check("end to end: \(label), and the installed app is unchanged", expected(e) && marker(app) == "old", e.localizedDescription)
            } else {
                c.check("end to end: \(label)", false, "\(outcome)")
            }
        }
        var flippedBytes = bytes
        flippedBytes[bytes.count / 2] ^= 0xFF
        try? flippedBytes.write(to: downloads.appendingPathComponent("YummyOrange-flipped.zip"))
        var flippedEntry = entry(bytes, file: "YummyOrange-flipped.zip")   // the feed describes the intact file
        refuses("a ZIP changed on the server is refused (checksum)", flippedEntry) { $0 == .wrongChecksum }
        flippedEntry = entry(flippedBytes, file: "YummyOrange-flipped.zip")
        flippedEntry["signature"] = entry(bytes, file: "x")["signature"]   // feed rewritten to match, signature can't be
        refuses("a changed ZIP with a feed changed to match is refused (signature)", flippedEntry) { $0 == .badSignature }
        refuses("a ZIP signed with another key is refused", entry(bytes, file: "YummyOrange-1.0.1.zip", signer: otherKey)) { $0 == .badSignature }
        refuses("a ZIP longer than the feed says is cut off", entry(bytes, file: "YummyOrange-1.0.1.zip", length: bytes.count - 100)) { $0 == .tooLarge }
        refuses("a feed promising build 3 for a ZIP of build 2 is refused", entry(bytes, file: "YummyOrange-1.0.1.zip", build: "3")) {
            if case .badApp = $0 { return true }; return false
        }
        refuses("a ZIP that isn’t on the server gives the server’s answer", entry(bytes, file: "missing.zip")) { $0 == .server(404) }
        if signing == .identity {
            refuses("an ad-hoc app, correctly signed with the update key, is refused by its code signature", entry(adHocBytes, file: "YummyOrange-adhoc.zip")) {
                if case .badCodeSignature = $0 { return true }; return false
            }
        }
        // Redirects: followed while they stay allowed, refused (before any request) when they leave HTTPS. The refused
        // one points at ftp:// on this Mac, so even a broken check reaches no other machine. The same server echoes the
        // headers a request carries, and serves files slowly under /slow/.
        publish(entry(bytes, file: "YummyOrange-1.0.1.zip"))
        guard let redirector = LocalServer(serving: site, redirecting: true) else {
            c.check("the redirecting test server starts on 127.0.0.1", false)
            return
        }
        defer { redirector.stop() }
        let base = "http://127.0.0.1:\(redirector.port)"
        let followed = Result { try UpdateTransport.fetch(URL(string: "\(base)/redirect-to/\(base)/updates/appcast.json")!, userAgent: "test") }
        let away = error { _ = try UpdateTransport.fetch(URL(string: "\(base)/redirect-to/ftp://127.0.0.1:9/appcast.json")!, userAgent: "test") }
        c.check("redirects are followed while they stay allowed, and refused when they leave HTTPS",
                (try? followed.get()).flatMap { try? UpdateFeed.parse($0, feedURL: feed) } != nil && away == .insecureURL("ftp://127.0.0.1:9/appcast.json"),
                "followed \(followed), away \(String(describing: away))")
        let echoed = (try? UpdateTransport.fetch(URL(string: "\(base)/echo-headers")!, userAgent: "YummyOrange/1.0.0"))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        let header = { (name: String) in echoed.first { $0.key.lowercased() == name.lowercased() }?.value }
        c.check("a request names the app and its version, with a fixed Accept-Language (en), and no cookie",
                header("User-Agent") == "YummyOrange/1.0.0" && header("Accept-Language") == "en" && header("Cookie") == nil,
                "\(echoed)")

        var lowerFeed = entry(bytes, file: "YummyOrange-1.0.1.zip")
        lowerFeed["build"] = "0.5"
        publish(lowerFeed)
        c.check("a feed with a lower build offers nothing, and prepare refuses it before downloading",
                { if case .success(.upToDate) = Result(catching: { try updater.fetch() }) { return true }; return false }()
                && { if case .notNewer = error({ _ = try updater.prepare(item(build: "0.5")) }) { return true }; return false }())

        // Unsaved changes in an editor window: asked before the download, and again before the swap.
        guard let app = freshInstall() else { return }
        updater.environment.appURL = app
        publish(entry(bytes, file: "YummyOrange-1.0.1.zip"))
        guard case .success(.available(let offered)) = Result(catching: { try updater.fetch() }) else {
            c.check("the feed offers build 2 again", false)
            return
        }
        ui.restart = false
        updater.unsavedWork = { ["An editor window has changes that haven’t been saved."] }
        updater.install(offered)
        c.check("with unsaved changes, Install Update asks first; Not Now downloads nothing and changes nothing",
                ui.restartAsked == [["An editor window has changes that haven’t been saved."]] && updater.phase == .idle
                && ui.progress.isEmpty && marker(app) == "old", "asked \(ui.restartAsked), phase \(updater.phase)")
        var asks = 0
        updater.unsavedWork = { asks += 1; return asks == 1 ? [] : ["An editor window has changes that haven’t been saved."] }
        updater.install(offered)
        spin(until: { updater.phase == .idle && asks >= 2 }, timeout: 60)
        c.check("…changes made during the download are asked about before the swap; Not Now leaves the installed app as it was",
                asks == 2 && marker(app) == "old" && ui.relaunched.isEmpty && updater.phase == .idle && ui.ended.last == .some(nil),
                "asks \(asks), marker \(marker(app) ?? "-"), phase \(updater.phase)")
        updater.unsavedWork = { [] }
        ui.restart = true
        ui.restartAsked = []
        ui.progress = []
        ui.ended = []

        // The same, as the app runs it: Check for Updates… by hand, then Install Update in the alert.
        ui.choice = .install
        updater.check(manual: true)
        let finished = spin(until: { !ui.relaunched.isEmpty || !ui.told.isEmpty }, timeout: 60)
        let downloadsShown = ui.progress.filter { $0.0 == "Downloading YummyOrange 1.0.1…" }.compactMap(\.1)
        c.check("by hand: Check for Updates… shows the alert, Install Update downloads with progress, installs and relaunches the new app",
                finished && ui.offers == ["2"] && ui.relaunched.map(\.standardizedFileURL) == [app.standardizedFileURL] && marker(app) == "new"
                && downloadsShown.last == 1.0 && ui.progress.contains { $0.0 == "Installing YummyOrange 1.0.1…" }
                && ui.ended.last == "Restarting YummyOrange…" && updater.latest == nil && ui.restartAsked.isEmpty,
                "offers \(ui.offers), told \(ui.told.map(\.0)), relaunched \(ui.relaunched.map(\.path)), progress \(ui.progress.map(\.0).uniqued())")
        c.check("…and the menu stays dimmed until YummyOrange quits", updater.phase == .installing)

        // The relaunch helper doesn't start: the menu comes back, and the person is told to reopen YummyOrange.
        if let again = freshInstall() {
            let stuck = Updater(environment: env)
            let stuckUI = RecordingUI()
            stuckUI.helperStarts = false
            stuck.ui = stuckUI
            stuck.unsavedWork = { [] }
            stuck.environment.appURL = again
            stuck.install(release)
            spin(until: { !stuckUI.told.isEmpty }, timeout: 60)
            c.check("if the relaunch helper can’t start, the menu isn’t left dimmed, and checks count the installed build",
                    stuck.phase == .idle && stuckUI.told.first?.0 == "YummyOrange was updated, but couldn’t restart itself."
                    && stuck.environment.build == "2" && marker(again) == "new", "\(stuckUI.told.map(\.0)) \(stuck.phase)")
        }

        // An automatic check that finds it: a notification and the menu item, no alert.
        let quiet = Updater(environment: updater.environment)
        let quietUI = RecordingUI(), notifier = RecordingNotifier()
        quiet.ui = quietUI
        quiet.notifier = notifier
        quiet.environment.appURL = app
        Settings.defaults = SettingsMemoryStore()
        quiet.check(manual: false)
        spin(until: { quiet.phase == .idle }, timeout: 20)
        c.check("automatic: an update found is announced (permission asked once) and offered in the menu, without an alert",
                notifier.requests == 1 && notifier.posted == ["2"] && quiet.menuUpdate?.build == "2" && quietUI.offers.isEmpty && quietUI.told.isEmpty
                && UpdatePreferences.lastCheck != nil)
        publish(lowerFeed)
        quiet.check(manual: true)
        spin(until: { !quietUI.told.isEmpty }, timeout: 20)
        c.check("by hand, with nothing newer: “You’re up to date.”", quietUI.told.first?.0 == "You’re up to date." && quiet.latest == nil,
                "\(quietUI.told.map(\.0))")

        // The notification clicked while the timer's check is still running: that check ends in the alert.
        publish(entry(bytes, file: "YummyOrange-1.0.1.zip"))
        let slow = Updater(environment: updater.environment)
        let slowUI = RecordingUI()
        slow.ui = slowUI
        slow.environment.feedURL = URL(string: "\(base)/slow/updates/appcast.json")
        slow.environment.appURL = app
        slow.check(manual: false)
        slow.respond(to: .show, build: "2")
        spin(until: { slow.phase == .idle }, timeout: 30)
        c.check("clicking the notification during an automatic check shows the update alert once the check is done",
                slowUI.offers == ["2"], "offers \(slowUI.offers), told \(slowUI.told.map(\.0))")

        // A check that gets no answer: not counted as a check, so the next is tried 15 minutes later.
        Settings.defaults = SettingsMemoryStore()
        let offline = Updater(environment: updater.environment)
        offline.ui = RecordingUI()
        offline.environment.feedURL = URL(string: "http://127.0.0.1:9/updates/appcast.json")
        let started = Date()
        offline.now = { started }
        offline.check(manual: false)
        spin(until: { offline.phase == .idle }, timeout: 20)
        c.check("an automatic check that fails (no server) isn’t saved as the last check, only as the last attempt",
                UpdatePreferences.lastCheck == nil && abs((UpdatePreferences.lastAttempt ?? .distantPast).timeIntervalSince(started)) < 0.01,
                "\(String(describing: UpdatePreferences.lastCheck)) \(String(describing: UpdatePreferences.lastAttempt))")
        Settings.defaults = SettingsMemoryStore()
    }

    // MARK: release.sh's output

    /// What release.sh's check of a release is told: what the copies already installed trust.
    struct ReleaseCheck {
        /// The staged Website/public folder.
        var folder: URL
        var feedURL: URL
        /// The keys installed copies trust (the published release's, or the pinned ones for the first release).
        var keys: [Curve25519.Signing.PublicKey]
        /// The team installed copies trust (pinned in Tools/updates/release-identity), never the new app's own.
        var team: String?
        /// Installed copies are Developer ID ones, so the new app must pass their policy: Developer ID, notarized and
        /// stapled, Gatekeeper.
        var developerID = false
        /// A dry run on a Mac without a signing identity: only the local test mode's check.
        var allowAdHoc = false
        var network = false
        /// The build installed copies have (the published release's, "0" before the first), which the new one must be
        /// above; nil for a test release (release.sh --test-release), which is meant for no installed copy.
        var installedBuild: String? = "0"
    }

    /// `--selftest updater-release:<folder>`: release.sh's check, with what installed copies trust from the
    /// environment: DW_RELEASE_PUBLIC_KEY (their keys), DW_RELEASE_TEAM (their team), DW_RELEASE_DEVELOPER_ID=1 (they
    /// are Developer ID copies: also notarization and Gatekeeper, with the network allowed), DW_RELEASE_ALLOW_ADHOC=1,
    /// DW_RELEASE_FEED_URL (default the built-in one) and DW_RELEASE_INSTALLED_BUILD (the build installed copies have,
    /// default 0; "none" for a test release).
    static func checkRelease(folder path: String) -> String {
        let c = Checker()
        let env = ProcessInfo.processInfo.environment
        let keys = UpdateArchiveCheck.publicKeys(base64: env["DW_RELEASE_PUBLIC_KEY"])
        guard !keys.isEmpty else {
            c.check("DW_RELEASE_PUBLIC_KEY holds the keys installed copies trust", false)
            return c.report("updater-release")
        }
        let developerID = env["DW_RELEASE_DEVELOPER_ID"] == "1"
        let installed = env["DW_RELEASE_INSTALLED_BUILD"].flatMap { $0.isEmpty ? nil : $0 } ?? "0"
        checkRelease(ReleaseCheck(folder: URL(fileURLWithPath: path, isDirectory: true),
                                  feedURL: URL(string: env["DW_RELEASE_FEED_URL"] ?? "") ?? feedURL, keys: keys,
                                  team: env["DW_RELEASE_TEAM"].flatMap { $0.isEmpty ? nil : $0 }, developerID: developerID,
                                  allowAdHoc: env["DW_RELEASE_ALLOW_ADHOC"] == "1", network: developerID,
                                  installedBuild: installed == "none" ? nil : installed), c)
        return c.report("updater-release")
    }

    /// Reads `<folder>/updates/appcast.json` as an installed copy would, once its signature (appcast.json.sig) checks
    /// out with the trusted keys; checks the ZIP it names (named with its version and build) with those keys; unpacks
    /// it; and checks the app inside: Info.plist, and its code signature under the policy of an installed copy of the
    /// trusted team.
    static func checkRelease(_ r: ReleaseCheck, _ c: Checker) {
        guard let data = try? Data(contentsOf: r.folder.appendingPathComponent("updates/appcast.json")) else {
            c.check("updates/appcast.json is there", false, r.folder.path)
            return
        }
        let signature = (try? Data(contentsOf: r.folder.appendingPathComponent("updates/appcast.json.sig"))) ?? Data()
        let signed = error { try UpdateFeed.checkSignature(of: data, signatureFile: signature, keys: r.keys) }
        c.check("the feed’s signature (appcast.json.sig) is made with a key installed copies trust", signed == nil, signed?.localizedDescription ?? "")
        guard signed == nil else { return }
        let parsed = Result { try UpdateFeed.parse(data, feedURL: r.feedURL) }
        guard case .success(let item) = parsed else {
            c.check("the feed reads", false, String(describing: parsed))
            return
        }
        c.check("the feed reads: YummyOrange \(item.version) (build \(item.build)), \(item.length) bytes", true)
        let name = "YummyOrange-\(item.version)-\(item.build).zip"
        c.check("the ZIP is named \(name), so a new build never reuses an address caches and older feeds point at",
                item.url.lastPathComponent == name, item.url.lastPathComponent)
        let siteRoot = r.feedURL.deletingLastPathComponent().deletingLastPathComponent().path
        guard item.url.host == r.feedURL.host, item.url.path.hasPrefix(siteRoot) else {
            c.check("the ZIP is on the same site as the feed", false, item.url.absoluteString)
            return
        }
        let local = r.folder.appendingPathComponent(String(item.url.path.dropFirst(siteRoot.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        let verified = error { try UpdateArchiveCheck.verify(local, item: item, keys: r.keys) }
        c.check("length, checksum and signature of \(local.lastPathComponent)", verified == nil, verified?.localizedDescription ?? "")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("YummyOrange release check \(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            let app = try UpdateInstaller.expand(local, into: scratch)
            let system = ProcessInfo.processInfo.operatingSystemVersion
            if let installed = r.installedBuild {
                try UpdateInstaller.checkInfo(of: app, item: item, bundleID: "com.yummyorange.app", installedBuild: installed, system: system)
                c.check("it unpacks to YummyOrange.app, version and build as the feed says, above the installed build \(installed)",
                        app.lastPathComponent == "YummyOrange.app")
            } else {
                // A test release: the same Info.plist checks against a build below its own, when it has one. Build 0
                // has none, which is what keeps it from every installed copy: they refuse it as not newer.
                let below = UpdateVersion.isNewer(item.build, than: "0") ? "0" : nil
                let e = error { try UpdateInstaller.checkInfo(of: app, item: item, bundleID: "com.yummyorange.app", installedBuild: below ?? "0", system: system) }
                if below != nil {
                    c.check("it unpacks to YummyOrange.app, version and build as the feed says (a test release)",
                            e == nil && app.lastPathComponent == "YummyOrange.app", e?.localizedDescription ?? "")
                } else {
                    let notNewer: Bool
                    if case .notNewer? = e { notNewer = true } else { notNewer = false }
                    c.check("it unpacks to YummyOrange.app, version and build as the feed says; build 0, so every installed copy refuses it as not newer (a test release)",
                            notNewer && app.lastPathComponent == "YummyOrange.app", e?.localizedDescription ?? "accepted")
                }
                c.notes.append("a test release: signed with throwaway update keys, never to be published")
            }
            let signer = CodeSigner.of(app)
            if r.team == nil && r.allowAdHoc {
                // A dry run on a Mac without a signing identity: the local test mode's check.
                let e = error { try CodeSignatureCheck.verify(app: app, bundleID: "com.yummyorange.app", running: .unsigned, localTestMode: true, network: false) }
                c.check("its ad-hoc signature is valid (a dry run without a signing identity)", e == nil, e?.localizedDescription ?? "")
                c.notes.append("ad hoc: a real release is signed with Developer ID")
                return
            }
            // The team comes from what installed copies trust, never from the new app itself, which would prove nothing.
            c.check("the team installed copies trust is given (DW_RELEASE_TEAM)", r.team != nil)
            c.check("the app is signed by a team (not ad hoc)", signer.teamID != nil && !signer.isAdHoc, String(describing: signer))
            if let team = r.team {
                let running = CodeSigner(identifier: "com.yummyorange.app", teamID: team, isAdHoc: false, isDeveloperID: r.developerID)
                let e = error { try CodeSignatureCheck.verify(app: app, bundleID: "com.yummyorange.app", running: running, localTestMode: false, network: r.network) }
                c.check("its code signature passes the check of an installed \(r.developerID ? "Developer ID" : "development") copy of team \(team)",
                        e == nil, e?.localizedDescription ?? "")
            }
        } catch {
            c.check("it unpacks and its Info.plist matches", false, error.localizedDescription)
        }
    }

    /// release.sh's check on a release made here: it passes as is, and fails for each thing an installed copy refuses.
    static func releaseCheck(_ c: Checker, _ kit: TestApps) {
        guard let team = kit.team else {
            c.notes.append("no signing identity: release.sh’s check was not run on a test release")
            return
        }
        let fm = FileManager.default
        let site = kit.dir.appendingPathComponent("release-check/public", isDirectory: true)
        try? fm.createDirectory(at: site.appendingPathComponent("updates"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: site.appendingPathComponent("downloads"), withIntermediateDirectories: true)
        guard let app = kit.make("YummyOrange", in: kit.dir.appendingPathComponent("release-check/build"), version: "1.0.1", build: "2", signing: .identity),
              let zero = kit.make("YummyOrange", in: kit.dir.appendingPathComponent("release-check/build-0"), version: "0.9.9", build: "0", signing: .identity) else {
            c.check("a test release app", false)
            return
        }
        let key = Curve25519.Signing.PrivateKey(), other = Curve25519.Signing.PrivateKey()
        func stage(zipName: String, app: URL = app, version: String = "1.0.1", build: String = "2") {
            let zip = site.appendingPathComponent("downloads/\(zipName)")
            try? fm.removeItem(at: zip)
            _ = TestApps.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
            guard let bytes = try? Data(contentsOf: zip) else { return }
            let feed: [String: Any] = ["version": version, "build": build, "minimumSystemVersion": "13.0", "url": "../downloads/\(zipName)",
                                       "length": bytes.count, "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                                       "signature": ((try? key.signature(for: bytes)) ?? Data()).base64EncodedString(),
                                       "published": "2026-11-24T12:00:00Z"]
            guard let data = try? JSONSerialization.data(withJSONObject: feed, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? data.write(to: site.appendingPathComponent("updates/appcast.json"))
            try? feedSignatureFile(data, key).write(to: site.appendingPathComponent("updates/appcast.json.sig"))
        }
        func passes(_ r: ReleaseCheck) -> (Bool, String) {
            let sub = Checker()
            checkRelease(r, sub)
            return (sub.failures == 0, sub.report("release").split(separator: "\n").filter { $0.contains("✗") }.joined(separator: "; "))
        }
        let good = ReleaseCheck(folder: site, feedURL: URL(string: "https://yummyorange.example/updates/appcast.json")!, keys: [key.publicKey], team: team)
        stage(zipName: "YummyOrange-1.0.1-2.zip")
        let (ok, okDetail) = passes(good)
        c.check("release check: a release made right passes, as an installed copy of team \(team) would take it", ok, okDetail)
        var noTeam = good
        noTeam.team = nil
        c.check("release check: without the team installed copies trust it fails (never the app’s own team)", !passes(noTeam).0)
        var otherTeam = good
        otherTeam.team = "AAAAAAAAAA"
        c.check("release check: a release signed by another team than the trusted one fails", !passes(otherTeam).0)
        var otherKey = good
        otherKey.keys = [other.publicKey]
        c.check("release check: a release whose feed and ZIP aren’t signed with a trusted key fails", !passes(otherKey).0)
        var asDeveloperID = good
        asDeveloperID.developerID = true
        c.check("release check: for Developer ID copies, a release that isn’t Developer ID fails", !passes(asDeveloperID).0)
        var publishedSame = good
        publishedSame.installedBuild = "2"
        c.check("release check: a release whose build isn’t above the published one fails", !passes(publishedSame).0)
        var asTest = good
        asTest.installedBuild = nil
        let (testOK, testDetail) = passes(asTest)
        c.check("release check: a test release (release.sh --test-release) above build 0 passes the same checks", testOK, testDetail)
        stage(zipName: "YummyOrange-0.9.9-0.zip", app: zero, version: "0.9.9", build: "0")
        let (zeroOK, zeroDetail) = passes(asTest)
        c.check("release check: a test release of build 0 passes, refused by every installed copy as not newer", zeroOK, zeroDetail)
        c.check("release check: build 0 never passes as a real release", !passes(good).0)
        try? fm.removeItem(at: site.appendingPathComponent("downloads/YummyOrange-0.9.9-0.zip"))
        stage(zipName: "YummyOrange-1.0.1-2.zip")
        try? fm.removeItem(at: site.appendingPathComponent("updates/appcast.json.sig"))
        c.check("release check: a feed without its signature fails", !passes(good).0)
        for stale in (try? fm.contentsOfDirectory(at: site.appendingPathComponent("downloads"), includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: stale)
        }
        stage(zipName: "YummyOrange-1.0.1.zip")
        c.check("release check: a ZIP named without its build fails", !passes(good).0)
    }

    // MARK: The release scripts' refusals

    /// The project's Tools/updates and build.sh, from where this file was compiled.
    static var projectFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Runs a zsh script or `swift <script>` with only `env` (and PATH, HOME, TMPDIR) in its environment.
    static func runScript(_ command: [String], env: [String: String], tmp: URL, timeout: TimeInterval = 240) -> (status: Int32, output: String) {
        let base = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=\(NSHomeDirectory())", "TMPDIR=\(tmp.path)/"]
        return TestApps.run("/usr/bin/env", ["-i"] + base + env.map { "\($0.key)=\($0.value)" } + command, timeout: timeout)
    }

    /// release.sh, build.sh and make-update-keys.swift refuse what would strand installed copies or expose the key.
    /// They run as copies in a temporary tree with their own release-identity, and every case is refused before
    /// anything is built, signed or sent (each also carries a later refusal, so a broken check still stops early).
    static func scripts(_ c: Checker, _ kit: TestApps, _ dir: URL) {
        let fm = FileManager.default
        let project = projectFolder
        let sources = ["build.sh", "Tools/updates/release.sh", "Tools/updates/make-update-keys.swift", "Tools/updates/sign-update.swift"]
        guard sources.allSatisfy({ fm.fileExists(atPath: project.appendingPathComponent($0).path) }) else {
            c.notes.append("the release scripts aren’t at \(project.path): their checks were skipped")
            return
        }
        // A folder name with an accent, so the inside-the-project checks also face another Unicode spelling.
        let tree = dir.appendingPathComponent("release tree \u{e9}", isDirectory: true)
        let tmp = dir.appendingPathComponent("tmp", isDirectory: true), keys = dir.appendingPathComponent("keys", isDirectory: true)
        for folder in [tree.appendingPathComponent("Tools/updates"), tmp, keys] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        for source in sources { try? fm.copyItem(at: project.appendingPathComponent(source), to: tree.appendingPathComponent(source)) }
        let team = kit.team ?? "ABCDE12345"
        let pinned = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let feed = "https://yummyorange.example/updates/appcast.json"
        let identity = tree.appendingPathComponent("Tools/updates/release-identity")
        func pin(feed pinnedFeed: String) {
            try? "TEAM_ID=\(team)\nUPDATE_PUBLIC_KEY=\(pinned)\nFEED_URL=\(pinnedFeed)\n".write(to: identity, atomically: true, encoding: .utf8)
        }
        pin(feed: feed)
        let keyFile = keys.appendingPathComponent("update-signing-key")
        try? Data((Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString() + "\n").utf8).write(to: keyFile)
        chmod(keyFile.path, 0o600)
        let release = tree.appendingPathComponent("Tools/updates/release.sh").path
        let real: [String: String] = ["VERSION": "1.0.1", "BUILD_NUMBER": "2", "UPDATE_FEED_URL": feed, "NOTARY_PROFILE": "test-profile",
                                      "SIGN_IDENTITY": "Developer ID Application: Test (\(team))", "UPDATE_PRIVATE_KEY": keys.appendingPathComponent("missing").path]
        func refuses(_ label: String, _ command: [String], _ env: [String: String], _ expected: String) {
            let result = runScript(command, env: env, tmp: tmp)
            c.check(label, result.status != 0 && result.output.contains(expected), "status \(result.status): \(result.output.suffix(300))")
        }
        refuses("release.sh --dry-run refuses the release key (it signs with throwaway keys only)", ["/bin/zsh", release, "--dry-run"],
                ["VERSION": "1.0.1", "BUILD_NUMBER": "2", "UPDATE_PRIVATE_KEY": keys.appendingPathComponent("missing").path],
                "--dry-run signs with throwaway update keys only")
        refuses("release.sh --test-release refuses the release key too (it is notarized, but signed with throwaway keys only)",
                ["/bin/zsh", release, "--test-release"],
                ["VERSION": "0.9.9", "BUILD_NUMBER": "0", "UPDATE_PRIVATE_KEY": keys.appendingPathComponent("missing").path],
                "--test-release signs with throwaway update keys only")
        let website = tree.appendingPathComponent("Website/public", isDirectory: true)
        try? fm.createDirectory(at: website, withIntermediateDirectories: true)
        refuses("release.sh --test-release refuses to write into the website folder, however its path is spelled",
                ["/bin/zsh", release, "--test-release", "--out", website.appendingPathComponent("test").path
                    .decomposedStringWithCanonicalMapping.replacingOccurrences(of: "release tree", with: "RELEASE TREE")],
                ["VERSION": "0.9.9", "BUILD_NUMBER": "0"], "--out must not be the website folder or around it")
        try? fm.removeItem(at: tree.appendingPathComponent("Website"))
        var env = real
        env["SIGNING"] = "cloud"
        refuses("release.sh refuses SIGNING=cloud (Xcode) together with this Mac’s SIGN_IDENTITY and NOTARY_PROFILE", ["/bin/zsh", release], env,
                "SIGNING=cloud signs and notarizes with Xcode")
        env = real
        env["SIGN_IDENTITY"] = "Developer ID Application: Someone Else (BBBBBBBBBB)"
        refuses("release.sh refuses a Developer ID identity of another team than the pinned one", ["/bin/zsh", release], env,
                "isn't of the team \(team) pinned in Tools/updates/release-identity")
        env = real
        env["UPDATE_PUBLIC_KEY"] = other
        refuses("release.sh refuses an update key that isn’t the pinned one", ["/bin/zsh", release], env,
                "UPDATE_PUBLIC_KEY isn't the update key pinned in Tools/updates/release-identity")
        env = real
        env["UPDATE_FEED_URL"] = nil
        pin(feed: "")
        refuses("release.sh refuses to guess the feed’s address (no UPDATE_FEED_URL and none pinned)", ["/bin/zsh", release], env,
                "set UPDATE_FEED_URL to the site's real feed address")
        pin(feed: feed)
        env = real
        env["UPDATE_FEED_URL"] = "https://yummyorange.example/other/appcast.json"
        refuses("release.sh refuses a feed address other than the pinned one", ["/bin/zsh", release], env, "isn't the FEED_URL pinned")
        // The key inside the project, spelled in other letter case and Unicode form where this volume allows it.
        let plainSpelling = tree.appendingPathComponent("Website").path
        let variant = [plainSpelling.decomposedStringWithCanonicalMapping.replacingOccurrences(of: "release tree", with: "RELEASE TREE"),
                       plainSpelling.decomposedStringWithCanonicalMapping, plainSpelling]
            .first { fm.fileExists(atPath: URL(fileURLWithPath: $0).deletingLastPathComponent().path) } ?? plainSpelling
        env = real
        env["UPDATE_PRIVATE_KEY"] = variant + "/update-signing-key"
        refuses("release.sh refuses a private key inside the project, however its path is spelled", ["/bin/zsh", release], env,
                "the private key must not be inside")
        // The release already published was made with another key, or by another team.
        if kit.team != nil {
            let published = tree.appendingPathComponent("Website/public", isDirectory: true)
            try? fm.createDirectory(at: published.appendingPathComponent("updates"), withIntermediateDirectories: true)
            try? fm.createDirectory(at: published.appendingPathComponent("downloads"), withIntermediateDirectories: true)
            try? Data(#"{"build": "1", "version": "1.0.0", "url": "../downloads/YummyOrange-1.0.0-1.zip"}"#.utf8)
                .write(to: published.appendingPathComponent("updates/appcast.json"))
            env = real
            env["UPDATE_PRIVATE_KEY"] = keyFile.path
            for (label, signing, key, expected) in [("with another update key", TestApps.Signing.identity, other, "trusts none of the update keys pinned"),
                                                    ("by another team (ad hoc)", .adHoc, pinned, "the published release is signed by team")] {
                guard let old = kit.make("YummyOrange", in: dir.appendingPathComponent("published \(label)"), version: "1.0.0", build: "1",
                                         signing: signing, extraInfo: ["DWUpdatePublicKey": key]) else { continue }
                let zip = published.appendingPathComponent("downloads/YummyOrange-1.0.0-1.zip")
                try? fm.removeItem(at: zip)
                _ = TestApps.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", old.path, zip.path])
                refuses("release.sh refuses when the published release was made \(label): its copies would refuse this one",
                        ["/bin/zsh", release], env, expected)
            }
            try? fm.removeItem(at: published)
        }
        let build = tree.appendingPathComponent("build.sh").path
        refuses("build.sh refuses an update key that isn’t the pinned one", ["/bin/zsh", build], ["UPDATE_PUBLIC_KEY": other],
                "UPDATE_PUBLIC_KEY isn't the update key pinned in Tools/updates/release-identity")
        refuses("build.sh refuses a Developer ID identity of another team than the pinned one", ["/bin/zsh", build],
                ["SIGN_IDENTITY": "Developer ID Application: Someone Else (BBBBBBBBBB)"], "isn't of the team \(team) pinned")

        // make-update-keys.swift: never inside the project, however the path is spelled; encrypted with a passphrase.
        let insideKey = variant + "/new-key"
        refuses("make-update-keys.swift refuses a key inside the project, however its path is spelled",
                ["/usr/bin/xcrun", "swift", tree.appendingPathComponent("Tools/updates/make-update-keys.swift").path, "--no-passphrase", insideKey],
                [:], "is inside the project")
        c.check("…and writes nothing there", !fm.fileExists(atPath: insideKey) && !fm.fileExists(atPath: plainSpelling + "/new-key"))
        let encrypted = keys.appendingPathComponent("encrypted-key")
        let made = runScript(["/usr/bin/xcrun", "swift", project.appendingPathComponent("Tools/updates/make-update-keys.swift").path, encrypted.path],
                             env: ["UPDATE_KEY_PASSPHRASE": "a test passphrase only"], tmp: tmp)
        let publicKey = made.output.split(separator: "\n").last.map(String.init) ?? ""
        let fileText = (try? String(contentsOf: encrypted, encoding: .utf8)) ?? ""
        c.check("make-update-keys.swift encrypts the key with the passphrase (PBKDF2 and AES-GCM): the file doesn’t hold the raw key",
                made.status == 0 && fileText.hasPrefix("dropwheel-update-key 2\npbkdf2-sha256 ") && UpdateArchiveCheck.publicKey(base64: publicKey) != nil,
                "status \(made.status): \(made.output.suffix(300))")
        let probe = keys.appendingPathComponent("probe")
        try? Data("YummyOrange".utf8).write(to: probe)
        let sign = project.appendingPathComponent("Tools/updates/sign-update.swift").path
        let signedRun = runScript(["/usr/bin/xcrun", "swift", sign, "--public-key", "\(other) \(publicKey)", encrypted.path, probe.path],
                                  env: ["UPDATE_KEY_PASSPHRASE": "a test passphrase only"], tmp: tmp)
        let signatureText = signedRun.output.split(separator: "\n").first { $0.hasPrefix("signature ") }.map { String($0.dropFirst("signature ".count)) }
        let valid = signatureText.flatMap { Data(base64Encoded: $0) }.map { UpdateArchiveCheck.publicKey(base64: publicKey)?.isValidSignature($0, for: Data("YummyOrange".utf8)) == true } ?? false
        c.check("sign-update.swift opens it with the passphrase and signs (its key is one of the --public-key list)", signedRun.status == 0 && valid,
                "status \(signedRun.status): \(signedRun.output.suffix(300))")
        refuses("sign-update.swift refuses a wrong passphrase", ["/usr/bin/xcrun", "swift", sign, encrypted.path, probe.path], ["UPDATE_KEY_PASSPHRASE": "not the passphrase"],
                "is wrong")
        refuses("sign-update.swift refuses a key that isn’t in the --public-key list", ["/usr/bin/xcrun", "swift", sign, "--public-key", other, encrypted.path, probe.path],
                ["UPDATE_KEY_PASSPHRASE": "a test passphrase only"], "isn’t one of the keys given with --public-key")
    }
}

// MARK: - Tiny test apps

extension UpdaterTests {
    /// Builds tiny app bundles (a compiled `int main` that returns 0, an Info.plist, a marker file) and signs them with
    /// this Mac's Apple Development or Developer ID identity, ad hoc, or not at all.
    final class TestApps {
        enum Signing { case identity, adHoc, none }
        let dir: URL
        private(set) var notes: [String] = []
        private var executable: URL?
        /// The identity's SHA-1 hash and name, and the team its signatures carry.
        private(set) var identity: String?
        private(set) var identityName: String?
        private(set) var team: String?

        init(_ dir: URL) {
            self.dir = dir
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let source = dir.appendingPathComponent("main.c")
            let binary = dir.appendingPathComponent("YummyOrange-test-binary")
            try? Data("int main(void) { return 0; }\n".utf8).write(to: source)
            let compiled = Self.run("/usr/bin/xcrun", ["clang", "-Os", source.path, "-o", binary.path], timeout: 120)
            if compiled.status == 0 { executable = binary } else { notes.append("couldn’t compile the test binary: \(compiled.output.prefix(200))") }
            findIdentity()
            if identity != nil, let probe = make("probe", in: dir.appendingPathComponent("probe"), version: "1.0.0", build: "1", signing: .identity) {
                team = CodeSigner.of(probe).teamID
                if team == nil { notes.append("signing with \(identityName ?? "the identity") gave no team"); identity = nil }
            }
        }

        /// DW_TEST_SIGN_IDENTITY, else the first Apple Development or Developer ID Application identity that
        /// `security find-identity` lists (read only).
        private func findIdentity() {
            if let forced = ProcessInfo.processInfo.environment["DW_TEST_SIGN_IDENTITY"], !forced.isEmpty {
                if forced != "none" { identity = forced; identityName = forced }
                return
            }
            let listed = Self.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"], timeout: 30)
            for line in listed.output.split(separator: "\n") where line.contains("Apple Development") || line.contains("Developer ID Application") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 3, parts[1].count == 40 else { continue }
                identity = String(parts[1])
                identityName = line.split(separator: "\"").dropFirst().first.map(String.init)
                return
            }
        }

        /// `runtime`: sign with the hardened runtime, as releases are (identity and ad hoc). `extraInfo`: more
        /// Info.plist keys (a DWUpdatePublicKey, say).
        func make(_ name: String, in folder: URL, bundleID: String = "com.yummyorange.app", version: String, build: String,
                  signing: Signing, identifier: String? = nil, marker: String? = nil, minimumSystem: String = "13.0",
                  runtime: Bool = true, extraInfo: [String: String] = [:]) -> URL? {
            guard let executable else { return nil }
            let fm = FileManager.default
            let app = folder.appendingPathComponent("\(name).app", isDirectory: true)
            try? fm.removeItem(at: app)
            let contents = app.appendingPathComponent("Contents")
            do {
                try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
                try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
                try fm.copyItem(at: executable, to: contents.appendingPathComponent("MacOS/YummyOrange"))
                try Data((marker ?? name).utf8).write(to: contents.appendingPathComponent("Resources/marker.txt"))
                var keys: [String: String] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "YummyOrange", "CFBundleName": "YummyOrange",
                                              "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": build,
                                              "LSMinimumSystemVersion": minimumSystem]
                keys.merge(extraInfo) { _, extra in extra }
                guard (keys as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true) else { return nil }
            } catch {
                notes.append("couldn’t build \(name).app: \(error.localizedDescription)")
                return nil
            }
            var args = ["--force", "--timestamp=none"]
            if runtime { args += ["--options", "runtime"] }
            switch signing {
            case .none:
                // The linker signs every arm64 binary ad hoc; an unsigned app has that signature taken off.
                let removed = Self.run("/usr/bin/codesign", ["--remove-signature", contents.appendingPathComponent("MacOS/YummyOrange").path])
                if removed.status != 0 { notes.append("couldn’t unsign \(name).app: \(removed.output.prefix(200))") }
                return app
            case .adHoc: args += ["--sign", "-"]
            case .identity:
                guard let identity else { return nil }
                args += ["--sign", identity]
            }
            if let identifier { args += ["-i", identifier] }
            let signed = Self.run("/usr/bin/codesign", args + [app.path], timeout: 60)
            guard signed.status == 0 else {
                notes.append("codesign \(name).app failed: \(signed.output.prefix(200))")
                return nil
            }
            return app
        }

        /// Runs a tool with a time limit (a codesign that waits on a Keychain prompt must not hang the test).
        @discardableResult
        static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 60) -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return (-1, error.localizedDescription) }
            var data = Data()
            let reading = DispatchGroup()
            reading.enter()
            DispatchQueue.global().async { data = pipe.fileHandleForReading.readDataToEndOfFile(); reading.leave() }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { usleep(20_000) }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            reading.wait()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
#endif
