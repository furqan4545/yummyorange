import AppKit
import CryptoKit
import Security
import UserNotifications
import os

// The built-in updater. No third-party code: the feed is a small JSON file on the YummyOrange website (yummyorange.com)
// (Website/public/updates/appcast.json, written by Tools/updates/release.sh), the download is a ZIP of the signed and
// notarized app, and every step is checked before anything on disk changes:
//
//   check     the feed and its detached Ed25519 signature (appcast.json.sig) over HTTPS with an ephemeral session
//             (no cookies, no cache, short timeouts); the feed is read only once its signature checks out, and its
//             addresses must stay on the feed's own site
//   offer     a newer build only: a quiet (provisional) notification and a menu item; either opens the update alert
//   download  the ZIP, capped at the length the feed gives, with progress in the HUD
//   verify    length, SHA-256 and an Ed25519 signature made with the release key (public half in DWUpdatePublicKey)
//   unpack    with ditto, into a temporary folder on the same volume as the installed app (the person's own temporary
//             folder on a disk that ignores ownership); nothing in it may be writable by others
//   check     the new app's Info.plist (same bundle identifier, the promised version, a higher build) and its code
//             signature: strict, same team and bundle identifier as the running app, the hardened runtime, and, when
//             the running app is signed with Developer ID, Developer ID, a stapled notarization ticket and Gatekeeper
//   ask       before the restart, when an editor window has unsaved changes
//   replace   the installed bundle in one step (FileManager.replaceItemAt), checked again where it now is and put
//             back if that fails; if its folder can't be changed, the new app goes to Downloads (or ~/Applications,
//             or a temporary folder) and Finder shows it, with instructions
//   relaunch  a tiny /bin/sh helper waits for this process to exit and opens the new app; YummyOrange quits once no
//             conversion is running
//
// Settings › General › Check for updates automatically (on by default) turns the automatic checks off; Check for
// Updates… in the menu-bar menu always works. The self-test is `--selftest updater` (UpdaterTests.swift).

// MARK: - Versions

/// Version and build strings: one to three whole numbers joined by dots ("1.0.1", "7"), as build.sh writes them.
enum UpdateVersion {
    /// The numbers in a version string, or nil when it isn't one.
    static func components(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard (1...9).contains(part.count), part.allSatisfy({ ("0"..."9").contains($0) }), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        return numbers
    }

    /// Orders two version strings, or nil when either isn't one. Missing parts count as zero, so "1.0" equals "1.0.0".
    static func compare(_ a: String, _ b: String) -> ComparisonResult? {
        guard let x = components(a), let y = components(b) else { return nil }
        for i in 0..<3 {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// True only when both are versions and `a` is the higher one.
    static func isNewer(_ a: String, than b: String) -> Bool { compare(a, b) == .orderedDescending }

    static func same(_ a: String, _ b: String) -> Bool { compare(a, b) == .orderedSame }

    /// "13.6.0" for an operating-system version.
    static func string(_ v: OperatingSystemVersion) -> String { "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" }
}

// MARK: - Errors

enum UpdateError: LocalizedError, Equatable {
    /// Updates can't work in this copy of YummyOrange (no app bundle, no key, not signed by its developer).
    case notAvailable(String)
    case badFeed(String)
    /// The feed's detached signature is missing, malformed or not made with the release key.
    case badFeedSignature
    case insecureURL(String)
    case network(String)
    case server(Int)
    case tooLarge
    case wrongLength(expected: Int, actual: Int)
    case wrongChecksum
    case badSignature
    case badArchive(String)
    case badApp(String)
    case notNewer(String)
    case badCodeSignature(String)
    case cannotInstall(String)
    /// The new version was swapped in, failed its check there, and the old one couldn't be put back.
    case damagedInstall(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable(let why): return why
        case .badFeed(let what): return "The update information on the YummyOrange website is damaged: \(what)."
        case .badFeedSignature: return "The update information on the YummyOrange website isn’t signed with YummyOrange’s update key."
        case .insecureURL(let url): return "YummyOrange downloads updates only over a secure connection (HTTPS), and \(url) isn’t one."
        case .network(let message): return message
        case .server(let code): return "The YummyOrange website answered with an error (HTTP \(code))."
        case .tooLarge: return "The download is larger than the update information says."
        case .wrongLength(let expected, let actual):
            return "The download is \(actual) bytes, not the \(expected) bytes the update information says."
        case .wrongChecksum: return "The download’s checksum doesn’t match the update information."
        case .badSignature: return "The download isn’t signed with YummyOrange’s update key."
        case .badArchive(let what): return "The download doesn’t hold a usable copy of YummyOrange: \(what)."
        case .badApp(let what), .notNewer(let what), .badCodeSignature(let what), .cannotInstall(let what): return what
        case .damagedInstall(let what):
            return "\(what) The copy of YummyOrange in its folder may be damaged: download YummyOrange again from yummyorange.com."
        }
    }
}

// MARK: - Feed

/// One release, as the feed describes it.
struct UpdateItem: Equatable {
    var version: String
    var build: String
    var minimumSystemVersion: String?
    /// The ZIP of the signed, notarized and stapled app (absolute, or relative to the feed).
    var url: URL
    var length: Int
    /// Lowercase hex.
    var sha256: String
    /// Ed25519 signature of the ZIP's bytes (64 bytes).
    var signature: Data
    var releaseNotesURL: URL?
    var releaseNotes: String?
    var published: Date?
}

enum UpdateCheckResult: Equatable {
    /// A higher build that runs on this Mac.
    case available(UpdateItem)
    /// The feed's build is this one or a lower one.
    case upToDate(UpdateItem)
    /// A higher build that needs a newer macOS than this Mac has.
    case needsNewerSystem(UpdateItem)
}

enum UpdateFeed {
    static let maxFeedBytes = 64 * 1024
    static let maxSignatureBytes = 1024
    static let maxArchiveBytes = 512 * 1024 * 1024
    static let maxNotesCharacters = 4000

    /// The feed's detached signature: the feed's address with “.sig” added (appcast.json.sig next to appcast.json).
    static func signatureURL(for feedURL: URL) -> URL { feedURL.appendingPathExtension("sig") }

    /// Checks the detached signature (base64 of an Ed25519 signature of the feed's exact bytes, made with the release
    /// key) before anything in the feed is read. Signed this way, the feed's release notes, links and the download's
    /// address can't be changed by whoever can change the website but doesn't hold the key.
    static func checkSignature(of feed: Data, signatureFile: Data, keys: [Curve25519.Signing.PublicKey]) throws {
        guard signatureFile.count <= maxSignatureBytes,
              let text = String(data: signatureFile, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let signature = Data(base64Encoded: text), signature.count == 64,
              keys.contains(where: { $0.isValidSignature(signature, for: feed) }) else { throw UpdateError.badFeedSignature }
    }

    /// The same scheme, host and port: the feed's addresses must stay on the feed's own site.
    static func isSameSite(_ url: URL, as feedURL: URL) -> Bool {
        func port(_ u: URL) -> Int? { u.port ?? (u.scheme?.lowercased() == "https" ? 443 : u.scheme?.lowercased() == "http" ? 80 : nil) }
        return url.scheme?.lowercased() == feedURL.scheme?.lowercased() && url.host?.lowercased() == feedURL.host?.lowercased()
            && port(url) != nil && port(url) == port(feedURL)
    }

    /// Reads the feed. Required: version, build, url, length, sha256 and signature; optional: minimumSystemVersion,
    /// releaseNotesURL, releaseNotes and published. Unknown keys are ignored, so later feeds can add some.
    /// URLs may be relative to the feed; they must be HTTPS (plain HTTP only on this Mac, for a feed that is too) and on
    /// the feed's own site.
    static func parse(_ data: Data, feedURL: URL) throws -> UpdateItem {
        guard data.count <= maxFeedBytes else { throw UpdateError.badFeed("it is larger than 64 KB") }
        guard let object = try? JSONSerialization.jsonObject(with: data), let json = object as? [String: Any] else {
            throw UpdateError.badFeed("it isn’t a JSON object")
        }
        let loopback = UpdateTransport.isLoopback(feedURL)

        func text(_ key: String, required: Bool = true) throws -> String? {
            guard let value = json[key], !(value is NSNull) else {
                if required { throw UpdateError.badFeed("“\(key)” is missing") }
                return nil
            }
            guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw UpdateError.badFeed("“\(key)” isn’t text")
            }
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        /// A whole JSON number (never true or false, which JSONSerialization also hands over as NSNumber).
        func wholeNumber(_ value: Any) -> Int64? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            guard d.isFinite, d == d.rounded(), abs(d) < 9e15 else { return nil }
            return n.int64Value
        }
        func version(_ key: String, required: Bool = true) throws -> String? {
            var value: String?
            if let number = json[key].flatMap(wholeNumber) {
                value = String(number)   // a build number written as a JSON number
            } else {
                value = try text(key, required: required)
            }
            guard let value else { return nil }
            guard UpdateVersion.components(value) != nil else {
                throw UpdateError.badFeed("“\(key)” isn’t a version (up to three numbers joined by dots)")
            }
            return value
        }
        func link(_ key: String, required: Bool = true) throws -> URL? {
            guard let raw = try text(key, required: required) else { return nil }
            guard let url = URL(string: raw, relativeTo: feedURL)?.absoluteURL,
                  UpdateTransport.isAllowed(url, loopbackHTTP: loopback) else {
                throw UpdateError.badFeed("“\(key)” isn’t an HTTPS address")
            }
            guard isSameSite(url, as: feedURL) else {
                throw UpdateError.badFeed("“\(key)” points away from the YummyOrange website")
            }
            return url
        }

        let versionString = try version("version")!
        let build = try version("build")!
        let minimum = try version("minimumSystemVersion", required: false)
        let url = try link("url")!

        guard let lengthValue = json["length"] else { throw UpdateError.badFeed("“length” is missing") }
        guard let length = wholeNumber(lengthValue), length > 0, length <= Int64(maxArchiveBytes) else {
            throw UpdateError.badFeed("“length” isn’t a size between 1 byte and 512 MB")
        }

        let sha = try text("sha256")!.lowercased()
        guard sha.count == 64, sha.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            throw UpdateError.badFeed("“sha256” isn’t 64 hexadecimal digits")
        }

        let signatureText = try text("signature")!
        guard let signature = Data(base64Encoded: signatureText), signature.count == 64 else {
            throw UpdateError.badFeed("“signature” isn’t a base64 Ed25519 signature")
        }

        let notesURL = try link("releaseNotesURL", required: false)
        let notes = try text("releaseNotes", required: false).map { String($0.prefix(maxNotesCharacters)) }
        var published: Date?
        if let stamp = try text("published", required: false) {
            let formatter = ISO8601DateFormatter()
            guard let date = formatter.date(from: stamp) else { throw UpdateError.badFeed("“published” isn’t a date") }
            published = date
        }
        return UpdateItem(version: versionString, build: build, minimumSystemVersion: minimum, url: url, length: Int(length),
                          sha256: sha, signature: signature, releaseNotesURL: notesURL, releaseNotes: notes, published: published)
    }

    /// Whether the feed's release is one to offer. Only a higher build counts, so a lower or equal one is never offered.
    static func evaluate(_ item: UpdateItem, currentBuild: String, system: OperatingSystemVersion) -> UpdateCheckResult {
        guard UpdateVersion.isNewer(item.build, than: currentBuild) else { return .upToDate(item) }
        if let minimum = item.minimumSystemVersion, UpdateVersion.isNewer(minimum, than: UpdateVersion.string(system)) {
            return .needsNewerSystem(item)
        }
        return .available(item)
    }
}

// MARK: - Transport

/// HTTPS requests for the updater, one transfer per instance. The session is ephemeral (no cookies, cache or stored
/// credentials), timeouts are short, redirects must stay on HTTPS, and a body larger than its cap is cancelled as
/// soon as it passes the cap. Calls block the calling thread, so they run on the updater's queue (or a self-test).
final class UpdateTransport: NSObject, URLSessionDataDelegate {
    static func isLoopback(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
    }

    /// HTTPS, or plain HTTP to this Mac itself when `loopbackHTTP` (a feed on localhost, for tests). Never an address
    /// with a user name or password in it.
    static func isAllowed(_ url: URL, loopbackHTTP: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && loopbackHTTP && isLoopback(url)
    }

    /// The headers every request carries besides the User-Agent: the same for every copy, so they say nothing about
    /// this Mac (URLSession would otherwise send the person's preferred languages).
    static let fixedHeaders = ["Accept-Language": "en", "Accept": "*/*"]

    /// The feed (or its signature), at most `maxBytes`.
    static func fetch(_ url: URL, maxBytes: Int = UpdateFeed.maxFeedBytes, userAgent: String) throws -> Data {
        let transport = UpdateTransport(loopbackHTTP: isLoopback(url), userAgent: userAgent, limit: maxBytes, file: nil)
        do {
            try transport.run(url, requestTimeout: 15, resourceTimeout: 30)
        } catch UpdateError.tooLarge {
            throw UpdateError.badFeed("it is larger than \(maxBytes / 1024) KB")
        }
        return transport.buffer
    }

    /// Writes the body to `destination` (created here), which must come to exactly `length` bytes. `progress` gets
    /// the fraction done, on the transfer's own queue, about once per percent.
    static func download(_ url: URL, to destination: URL, length: Int, loopbackHTTP: Bool, userAgent: String,
                         progress: @escaping (Double) -> Void) throws {
        guard isAllowed(url, loopbackHTTP: loopbackHTTP) else { throw UpdateError.insecureURL(url.absoluteString) }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination) else {
            throw UpdateError.cannotInstall("YummyOrange couldn’t save the download in a temporary folder.")
        }
        defer { try? handle.close() }
        let transport = UpdateTransport(loopbackHTTP: loopbackHTTP, userAgent: userAgent, limit: length, file: handle)
        transport.onProgress = progress
        try transport.run(url, requestTimeout: 30, resourceTimeout: 15 * 60)
        guard transport.received == length else { throw UpdateError.wrongLength(expected: length, actual: transport.received) }
    }

    private let loopbackHTTP: Bool
    private let userAgent: String
    private let limit: Int
    private let file: FileHandle?
    private var onProgress: ((Double) -> Void)?
    private(set) var buffer = Data()
    private(set) var received = 0
    private var reported = -1
    private var redirects = 0
    private var failure: UpdateError?
    private var transportError: Error?
    private let done = DispatchSemaphore(value: 0)

    private init(loopbackHTTP: Bool, userAgent: String, limit: Int, file: FileHandle?) {
        self.loopbackHTTP = loopbackHTTP
        self.userAgent = userAgent
        self.limit = limit
        self.file = file
    }

    private func run(_ url: URL, requestTimeout: TimeInterval, resourceTimeout: TimeInterval) throws {
        guard Self.isAllowed(url, loopbackHTTP: loopbackHTTP) else { throw UpdateError.insecureURL(url.absoluteString) }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        // Only the app's name and version, and headers that are the same for every copy.
        var headers = Self.fixedHeaders
        headers["User-Agent"] = userAgent
        config.httpAdditionalHeaders = headers
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "dropwheel.updates.transfer"
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let task = session.dataTask(with: request)
        task.resume()
        if done.wait(timeout: .now() + resourceTimeout + 10) == .timedOut {
            task.cancel()
            _ = done.wait(timeout: .now() + 5)
        }
        session.finishTasksAndInvalidate()
        if let failure { throw failure }
        if let transportError {
            throw UpdateError.network((transportError as NSError).localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 5, let next = request.url, Self.isAllowed(next, loopbackHTTP: loopbackHTTP) else {
            failure = .insecureURL(request.url?.absoluteString ?? "a redirect")
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard failure == nil, let http = response as? HTTPURLResponse else {
            if failure == nil { failure = .network("The YummyOrange website sent an unexpected answer.") }
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 200 else {
            failure = .server(http.statusCode)
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Int64(limit) {
            failure = .tooLarge
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        received += data.count
        guard received <= limit else {
            failure = .tooLarge
            dataTask.cancel()
            return
        }
        if let file {
            do { try file.write(contentsOf: data) } catch {
                failure = .cannotInstall("YummyOrange couldn’t save the download: \(error.localizedDescription)")
                dataTask.cancel()
                return
            }
        } else {
            buffer.append(data)
        }
        if let onProgress, limit > 0 {
            let percent = Int(Double(received) / Double(limit) * 100)
            if percent > reported {
                reported = percent
                onProgress(Double(received) / Double(limit))
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, failure == nil { transportError = error }
        done.signal()
    }
}

// MARK: - The download's own checks

/// Length, SHA-256 and the Ed25519 signature of the downloaded ZIP. Each check stands alone: the length and checksum
/// tie the file to the feed, the signature ties it to YummyOrange's release key.
enum UpdateArchiveCheck {
    /// Most keys DWUpdatePublicKey may list: the one releases are signed with and a backup or two kept offline, so the
    /// key can be changed later without stranding the copies already installed.
    static let maxKeys = 4

    /// The public key from base64 (32 raw bytes), or nil.
    static func publicKey(base64: String?) -> Curve25519.Signing.PublicKey? {
        guard let text = base64?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let raw = Data(base64Encoded: text), raw.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    /// The keys DWUpdatePublicKey lists, separated by spaces or commas. Empty when there are none, more than `maxKeys`,
    /// or any of them isn't a key, so a damaged list is never half trusted.
    static func publicKeys(base64 list: String?) -> [Curve25519.Signing.PublicKey] {
        let parts = (list ?? "").split(whereSeparator: { $0 == " " || $0 == "," || $0.isNewline || $0 == "\t" })
        guard (1...maxKeys).contains(parts.count) else { return [] }
        let keys = parts.compactMap { publicKey(base64: String($0)) }
        return keys.count == parts.count ? keys : []
    }

    static func checkLength(of file: URL, expected: Int) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? -1
        guard size == expected else { throw UpdateError.wrongLength(expected: expected, actual: max(size, 0)) }
    }

    static func sha256(of file: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            throw UpdateError.cannotInstall("YummyOrange couldn’t read the download.")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func checkChecksum(of file: URL, expected: String) throws {
        guard try sha256(of: file) == expected.lowercased() else { throw UpdateError.wrongChecksum }
    }

    /// Passes when any of `keys` made the signature.
    static func checkSignature(of file: URL, signature: Data, keys: [Curve25519.Signing.PublicKey]) throws {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped),
              keys.contains(where: { $0.isValidSignature(signature, for: data) }) else { throw UpdateError.badSignature }
    }

    static func checkSignature(of file: URL, signature: Data, key: Curve25519.Signing.PublicKey) throws {
        try checkSignature(of: file, signature: signature, keys: [key])
    }

    static func verify(_ file: URL, item: UpdateItem, keys: [Curve25519.Signing.PublicKey]) throws {
        try checkLength(of: file, expected: item.length)
        try checkChecksum(of: file, expected: item.sha256)
        try checkSignature(of: file, signature: item.signature, keys: keys)
    }

    static func verify(_ file: URL, item: UpdateItem, key: Curve25519.Signing.PublicKey) throws {
        try verify(file, item: item, keys: [key])
    }
}

// MARK: - Code signatures

/// Who signed a piece of code, as its signature says (not yet validated).
struct CodeSigner: Equatable {
    var identifier: String?
    var teamID: String?
    var isAdHoc: Bool
    /// Signed with a Developer ID Application certificate (its leaf carries Apple's Developer ID marker), as every copy
    /// from the website is. An Apple Development copy is a developer's own build.
    var isDeveloperID = false

    static let unsigned = CodeSigner(identifier: nil, teamID: nil, isAdHoc: false)
    var isSigned: Bool { identifier != nil }

    /// This process.
    static func running() -> CodeSigner {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unsigned }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return .unsigned }
        return info(staticCode)
    }

    /// A bundle or binary on disk.
    static func of(_ url: URL) -> CodeSigner {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return .unsigned }
        return info(code)
    }

    private static func info(_ code: SecStaticCode) -> CodeSigner {
        var dictionary: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
              let info = dictionary as? [String: Any] else { return .unsigned }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let leaf = (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        return CodeSigner(identifier: info[kSecCodeInfoIdentifier as String] as? String,
                          teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
                          isAdHoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0,
                          isDeveloperID: leaf.map { CodeSignatureCheck.has($0, extension: CodeSignatureCheck.developerIDLeaf) } ?? false)
    }
}

enum CodeSignatureCheck {
    /// Apple's marker on a Developer ID Application certificate, and on the Developer ID intermediate that issues it.
    static let developerIDLeaf = "1.2.840.113635.100.6.1.13"
    static let developerIDIntermediate = "1.2.840.113635.100.6.2.6"

    /// What the new version's signature must satisfy, decided by how the running app is signed.
    struct Policy {
        /// The code requirement: Apple's anchor, the bundle identifier and the team (and Developer ID when asked).
        var requirement: String
        var team: String?
        var developerID: Bool
        /// The new version must be signed with the hardened runtime, as notarization requires.
        var hardenedRuntime: Bool
        /// It must carry a stapled notarization ticket, so it is known to be notarized without asking Apple.
        var stapledTicket: Bool
        /// Gatekeeper's verdict on running it, the one macOS gives a downloaded app: nil when it would run, else why
        /// not. Nil here means Gatekeeper isn't asked.
        var gatekeeper: ((URL) -> String?)?
        /// kSecCSStrictValidate. Off only for the second look at an app already checked strictly, which a synced folder
        /// (iCloud Desktop) may have stamped with Finder information in the meantime.
        var strict = true
    }

    /// The policy for updating `running`: an Apple-issued certificate of its team and its bundle identifier, with the
    /// hardened runtime. A Developer ID copy (every copy from the website) also asks for a Developer ID certificate, a
    /// stapled notarization ticket and Gatekeeper's approval, so a build signed with any other certificate of the team
    /// (an Apple Development one, say, which lives in a developer's keychain) is refused. A running app without a team
    /// (ad hoc or unsigned) can't tell a genuine update from another, so it updates only in the local test mode, which
    /// asks for a valid signature with the same identifier.
    static func policy(bundleID: String, running: CodeSigner, localTestMode: Bool) throws -> Policy {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !bundleID.isEmpty, bundleID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw UpdateError.badCodeSignature("YummyOrange’s bundle identifier can’t be checked.")
        }
        if let team = running.teamID {
            guard team.count == 10, team.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else {
                throw UpdateError.badCodeSignature("YummyOrange’s own signature has an unexpected team identifier.")
            }
            let base = "anchor apple generic and identifier \"\(bundleID)\""
            let teamClause = "certificate leaf[subject.OU] = \"\(team)\""
            if running.isDeveloperID {
                return Policy(requirement: "\(base) and certificate 1[field.\(developerIDIntermediate)] exists and certificate leaf[field.\(developerIDLeaf)] exists and \(teamClause)",
                              team: team, developerID: true, hardenedRuntime: true, stapledTicket: true, gatekeeper: Gatekeeper.assess)
            }
            return Policy(requirement: "\(base) and \(teamClause)", team: team, developerID: false, hardenedRuntime: true,
                          stapledTicket: false, gatekeeper: nil)
        }
        if localTestMode {
            return Policy(requirement: "identifier \"\(bundleID)\"", team: nil, developerID: false, hardenedRuntime: false,
                          stapledTicket: false, gatekeeper: nil)
        }
        throw UpdateError.badCodeSignature("This copy of YummyOrange isn’t signed by its developer, so it can’t tell a genuine update from another app. Download new versions from yummyorange.com.")
    }

    /// Every architecture, nested code, symbolic links only within the bundle, app-like bundles only, and (unless the
    /// policy says otherwise) strict. `network`: false keeps the revocation check off the network (self-tests).
    static func flags(strict: Bool, network: Bool) -> SecCSFlags {
        var raw = UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSCheckNestedCode) | UInt32(kSecCSRestrictSymlinks)
            | UInt32(kSecCSRestrictToAppLike)
        if strict { raw |= UInt32(kSecCSStrictValidate) }
        var flags = SecCSFlags(rawValue: raw)
        if !network { flags.insert(.noNetworkAccess) }
        return flags
    }

    /// Validates the new app against the policy for the running app (see `policy`).
    static func verify(app: URL, bundleID: String, running: CodeSigner, localTestMode: Bool, network: Bool = true) throws {
        try verify(app: app, policy: try policy(bundleID: bundleID, running: running, localTestMode: localTestMode), network: network)
    }

    /// Validates the new app: its whole signature against the policy's requirement, then the hardened runtime, the
    /// stapled ticket and Gatekeeper, as the policy asks.
    static func verify(app: URL, policy: Policy, network: Bool = true) throws {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(policy.requirement as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.badCodeSignature("YummyOrange couldn’t prepare the signature check.")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.badCodeSignature("The new version’s code signature can’t be read.")
        }
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags(strict: policy.strict, network: network), requirement, &error)
        error?.release()
        guard status == errSecSuccess else {
            if status == errSecCSUnsigned { throw UpdateError.badCodeSignature("The new version isn’t signed.") }
            if status == errSecCSReqFailed {
                let signer = CodeSigner.of(app)
                var by = signer.teamID.map { "team \($0)" } ?? (signer.isAdHoc ? "no developer (ad hoc)" : "an unknown developer")
                if signer.teamID != nil { by += signer.isDeveloperID ? " with Developer ID" : " with a certificate that isn’t Developer ID" }
                let expected = policy.team.map { policy.developerID ? "YummyOrange’s developer with Developer ID (team \($0))" : "YummyOrange’s developer (team \($0))" }
                    ?? "YummyOrange"
                throw UpdateError.badCodeSignature("The new version is signed by \(by) as “\(signer.identifier ?? "?")”, not by \(expected).")
            }
            throw UpdateError.badCodeSignature("The new version’s code signature isn’t valid (error \(status)).")
        }
        if policy.hardenedRuntime || policy.stapledTicket {
            guard let details = details(of: code) else {
                throw UpdateError.badCodeSignature("The new version’s code signature can’t be read.")
            }
            if policy.hardenedRuntime && !details.hardenedRuntime {
                throw UpdateError.badCodeSignature("The new version isn’t signed with the hardened runtime, as every YummyOrange release is.")
            }
            if policy.stapledTicket && !details.stapledTicket {
                throw UpdateError.badCodeSignature("The new version isn’t notarized by Apple: it carries no notarization ticket.")
            }
        }
        if let gatekeeper = policy.gatekeeper, let why = gatekeeper(app) {
            throw UpdateError.badCodeSignature("macOS wouldn’t open the new version (\(why)).")
        }
    }

    /// Whether code on disk is signed with the hardened runtime and carries a stapled notarization ticket, as its
    /// signature says (read, not validated), or nil when it can't be read.
    static func details(of app: URL) -> (hardenedRuntime: Bool, stapledTicket: Bool)? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return details(of: code)
    }

    private static func details(of code: SecStaticCode) -> (hardenedRuntime: Bool, stapledTicket: Bool)? {
        var dictionary: CFDictionary?
        let what = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSContentInformation)
        guard SecCodeCopySigningInformation(code, what, &dictionary) == errSecSuccess, let info = dictionary as? [String: Any] else { return nil }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return (flags & SecCodeSignatureFlags.runtime.rawValue != 0, info[kSecCodeInfoStapledNotarizationTicket as String] != nil)
    }

    /// Whether a certificate carries an extension (by its OID).
    static func has(_ certificate: SecCertificate, extension oid: String) -> Bool {
        (SecCertificateCopyValues(certificate, [oid] as CFArray, nil) as? [String: Any])?[oid] != nil
    }
}

/// Gatekeeper's verdict on running an app: SecAssessment with the execute operation, what `spctl --assess --type
/// execute` asks. SecAssessment.h isn't in the command-line SDK, so its functions and keys are looked up in
/// Security.framework when needed.
enum Gatekeeper {
    private typealias Create = @convention(c) (CFURL, UInt64, CFDictionary?, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFTypeRef>?
    private typealias CopyResult = @convention(c) (CFTypeRef, UInt64) -> Unmanaged<CFDictionary>?

    /// Nil when Gatekeeper would let `app` run, else why not.
    static func assess(_ app: URL) -> String? {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let createSymbol = dlsym(security, "SecAssessmentCreate"), let copySymbol = dlsym(security, "SecAssessmentCopyResult"),
              let operationKey = constant(security, "kSecAssessmentContextKeyOperation"),
              let execute = constant(security, "kSecAssessmentOperationTypeExecute"),
              let verdictKey = constant(security, "kSecAssessmentAssessmentVerdict") else {
            return "Gatekeeper can’t be asked on this Mac"
        }
        let create = unsafeBitCast(createSymbol, to: Create.self)
        let copyResult = unsafeBitCast(copySymbol, to: CopyResult.self)
        var error: Unmanaged<CFError>?
        let context = [operationKey as String: execute as String] as CFDictionary
        guard let assessment = create(app as CFURL, 0, context, &error)?.takeRetainedValue() else {
            return error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "Gatekeeper rejected it"
        }
        let result = copyResult(assessment, 0)?.takeRetainedValue() as? [String: Any]
        return result?[verdictKey as String] as? Bool == true ? nil : "Gatekeeper rejected it"
    }

    private static func constant(_ handle: UnsafeMutableRawPointer, _ name: String) -> CFString? {
        dlsym(handle, name).map { $0.assumingMemoryBound(to: Unmanaged<CFString>.self).pointee.takeUnretainedValue() }
    }
}

// MARK: - Installing

enum UpdateInstaller {
    enum Outcome: Equatable {
        /// The installed bundle was replaced; this is the new one.
        case replaced(URL)
        /// It couldn't be: the new app is here instead, and `reason` says why.
        case manual(URL, reason: String)
    }

    /// Unpacks the ZIP into `folder` with ditto and returns the one app at its top.
    static func expand(_ zip: URL, into folder: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let result: ProcessResult
        do {
            result = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, folder.path])
        } catch {
            throw UpdateError.badArchive("ditto couldn’t run (\(error.localizedDescription))")
        }
        guard result.status == 0 else {
            throw UpdateError.badArchive("it couldn’t be unpacked (\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))")
        }
        let items = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" }
        guard items.count == 1, let app = items.first, app.pathExtension == "app" else {
            throw UpdateError.badArchive("it should hold one app and nothing else")
        }
        let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw UpdateError.badArchive("its app isn’t a folder")
        }
        try securePermissions(of: app)
        return app
    }

    /// Code signatures don't cover file modes, so a ZIP made under a loose umask could install an app that other people
    /// using this Mac can change (its ffmpeg, say, which YummyOrange runs). Everything unpacked must belong to this user;
    /// group and other write permission and the set-user-ID, set-group-ID and sticky bits are taken off.
    static func securePermissions(of app: URL) throws {
        let fm = FileManager.default
        var paths = [app.path]
        if let walker = fm.enumerator(atPath: app.path) {
            while let relative = walker.nextObject() as? String { paths.append(app.path + "/" + relative) }
        }
        let me = getuid()
        for path in paths {
            var info = stat()
            guard lstat(path, &info) == 0 else { throw UpdateError.badArchive("part of it can’t be read") }
            guard info.st_uid == me else { throw UpdateError.badArchive("part of it belongs to another user") }
            if info.st_mode & S_IFMT == S_IFLNK { continue }   // a link's own mode means nothing; its target is checked
            let mode = info.st_mode & 0o7777
            let safe = mode & ~mode_t(0o7022)
            if safe != mode && chmod(path, safe) != 0 {
                throw UpdateError.badArchive("its permissions can’t be made safe (\(String(cString: strerror(errno))))")
            }
        }
    }

    /// Whether the volume holding `url` ignores file ownership (exFAT and other disks mounted that way): there,
    /// anything on it, a temporary folder included, can be changed by everyone using this Mac.
    static func ignoresOwnership(_ url: URL) -> Bool {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return false }
        return info.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0
    }

    /// Where the download is unpacked and checked: a new temporary folder on the installed app's volume, so the swap is
    /// a rename. On a volume that ignores ownership (or when there is none), the person's own temporary folder instead,
    /// which only they can open.
    static func stagingFolder(for app: URL, ignoresOwnership: Bool) -> URL {
        let fm = FileManager.default
        let own = fm.temporaryDirectory.appendingPathComponent("YummyOrange update \(UUID().uuidString)", isDirectory: true)
        guard !ignoresOwnership else { return own }
        return (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)) ?? own
    }

    /// The new app's Info.plist: YummyOrange's bundle identifier, the version and build the feed promised, a build
    /// higher than the installed one, and a minimum macOS this Mac meets.
    static func checkInfo(of app: URL, item: UpdateItem, bundleID: String, installedBuild: String,
                          system: OperatingSystemVersion) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            throw UpdateError.badArchive("its app has no Info.plist")
        }
        let identifier = info["CFBundleIdentifier"] as? String ?? "?"
        guard identifier == bundleID else {
            throw UpdateError.badApp("The download is another app (\(identifier)), not YummyOrange.")
        }
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        guard UpdateVersion.same(version, item.version), UpdateVersion.same(build, item.build) else {
            throw UpdateError.badApp("The download is YummyOrange \(version) (build \(build)), not \(item.version) (build \(item.build)) as the update information says.")
        }
        guard UpdateVersion.isNewer(build, than: installedBuild) else {
            throw UpdateError.notNewer("The download (build \(build)) isn’t newer than the YummyOrange you have (build \(installedBuild)).")
        }
        if let minimum = info["LSMinimumSystemVersion"] as? String, UpdateVersion.isNewer(minimum, than: UpdateVersion.string(system)) {
            throw UpdateError.badApp("YummyOrange \(version) needs macOS \(minimum) or later.")
        }
    }

    /// Why the installed app can't be replaced where it is, or nil when it can. `ignoresOwnership` stands in for the
    /// volume's own answer (self-tests).
    static func blocker(for app: URL, ignoresOwnership: Bool? = nil) -> String? {
        if app.path.contains("/AppTranslocation/") {
            return "macOS is running YummyOrange from a temporary, read-only copy because it hasn’t been moved to the Applications folder."
        }
        if (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return "YummyOrange is running from a read-only disk, such as its disk image."
        }
        if ignoresOwnership ?? Self.ignoresOwnership(app) {
            return "YummyOrange is on a disk that ignores file ownership, where anyone using this Mac could change it."
        }
        let fm = FileManager.default
        let folder = app.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: folder.path), fm.isWritableFile(atPath: app.path),
              fm.isWritableFile(atPath: app.appendingPathComponent("Contents").path) else {
            return "You don’t have permission to change the folder “\(fm.displayName(atPath: folder.path))” that YummyOrange is in."
        }
        return nil
    }

    /// Swaps the new bundle into the installed one's place in one step. The old one is kept beside it, hidden, as
    /// `backup` until `check` has passed on the swapped-in copy, then removed; when the check fails it is put back and
    /// the check's error thrown (`damagedInstall` if it can't be put back). The new bundle's own metadata is kept, so
    /// nothing of the old one's (a Finder flag, say) sticks to it.
    static func replace(_ installed: URL, with new: URL, check: (URL) throws -> Void = { _ in }) throws -> URL {
        let fm = FileManager.default
        let backupName = ".YummyOrange update backup \(UUID().uuidString.prefix(8)).app"
        let backup = installed.deletingLastPathComponent().appendingPathComponent(backupName)
        let placed: URL
        do {
            placed = try fm.replaceItemAt(installed, withItemAt: new, backupItemName: backupName,
                                          options: [.usingNewMetadataOnly, .withoutDeletingBackupItem]) ?? installed
        } catch {
            throw SwapFailure(underlying: UpdateError.cannotInstall("YummyOrange couldn’t replace itself: \(error.localizedDescription)"))
        }
        do {
            try check(placed)
        } catch {
            guard fm.fileExists(atPath: backup.path),
                  (try? fm.replaceItemAt(placed, withItemAt: backup, backupItemName: nil, options: .usingNewMetadataOnly)) != nil else {
                throw UpdateError.damagedInstall("The new version failed its check once installed (\(error.localizedDescription)), and the old one couldn’t be put back.")
            }
            throw error
        }
        try? fm.removeItem(at: backup)
        return placed
    }

    /// The swap itself failed, which leaves the installed app as it was (replaceItemAt then changes nothing).
    struct SwapFailure: Error { let underlying: UpdateError }

    /// Moves the new app into the first of `folders` that takes it, as “YummyOrange 1.0.1.app” (or “YummyOrange 1.0.1
    /// 2.app”, and so on). Downloads comes first; when macOS doesn't let YummyOrange in there, ~/Applications or a
    /// temporary folder does, so the checked update is never thrown away for want of a place.
    static func park(_ app: URL, version: String, in folders: [URL]) throws -> URL {
        var failure: Error = UpdateError.cannotInstall("YummyOrange has no folder to put the new version in.")
        for folder in folders {
            do { return try park(app, version: version, in: folder) } catch { failure = error }
        }
        throw failure
    }

    static func park(_ app: URL, version: String, in folder: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appendingPathComponent("YummyOrange \(version).app")
        var n = 2
        while fm.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("YummyOrange \(version) \(n).app")
            n += 1
        }
        do { try fm.moveItem(at: app, to: destination) } catch {
            throw UpdateError.cannotInstall("YummyOrange couldn’t move the new version to \(fm.displayName(atPath: folder.path)): \(error.localizedDescription)")
        }
        return destination
    }
}

// MARK: - Relaunch

/// The helper that opens the new app once this process has gone: /bin/sh, detached. It waits for as long as the process
/// runs (YummyOrange first lets a running conversion finish), so a slow quit never ends with the new version unopened.
enum Relauncher {
    /// $1 is the process to wait for; then it runs $2 with $3 (/usr/bin/open and the app).
    static let script = "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec \"$2\" \"$3\""

    static func arguments(waitingFor pid: Int32, run tool: String, _ argument: String) -> [String] {
        ["-c", script, "yummyorange-relaunch", String(pid), tool, argument]
    }

    @discardableResult
    static func start(waitingFor pid: Int32, run tool: String = "/usr/bin/open", _ argument: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(waitingFor: pid, run: tool, argument)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}

// MARK: - What the person chose

/// Skip This Version, Remind Me Later, and what the automatic checks remember. In Settings.defaults, so self-tests
/// keep them in memory.
enum UpdatePreferences {
    private enum Key {
        static let skipped = "updateSkippedBuild"
        static let snoozedBuild = "updateSnoozedBuild"
        static let snoozedUntil = "updateSnoozedUntil"
        static let notified = "updateNotifiedBuild"
        static let asked = "updateAskedForNotifications"
        static let lastCheck = "updateLastCheck"
        static let lastAttempt = "updateLastAttempt"
    }
    private static var defaults: UserDefaults { Settings.defaults }

    static var skippedBuild: String? {
        get { defaults.string(forKey: Key.skipped) }
        set { defaults.set(newValue, forKey: Key.skipped) }
    }
    static var snoozedBuild: String? {
        get { defaults.string(forKey: Key.snoozedBuild) }
        set { defaults.set(newValue, forKey: Key.snoozedBuild) }
    }
    static var snoozedUntil: Date? {
        get { (defaults.object(forKey: Key.snoozedUntil) as? Double).map(Date.init(timeIntervalSince1970:)) }
        set { defaults.set(newValue?.timeIntervalSince1970, forKey: Key.snoozedUntil) }
    }
    /// The build the last notification was about, so the same update is announced once (again after a snooze).
    static var notifiedBuild: String? {
        get { defaults.string(forKey: Key.notified) }
        set { defaults.set(newValue, forKey: Key.notified) }
    }
    /// Notification permission has been asked for (the first time an update was found).
    static var askedForNotifications: Bool {
        get { defaults.object(forKey: Key.asked) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.asked) }
    }
    /// The last check that got an answer from the website (an update or none).
    static var lastCheck: Date? {
        get { (defaults.object(forKey: Key.lastCheck) as? Double).map(Date.init(timeIntervalSince1970:)) }
        set { defaults.set(newValue?.timeIntervalSince1970, forKey: Key.lastCheck) }
    }
    /// The last check started, answered or not (offline, say), so a failed one is tried again soon, not in 6 hours.
    static var lastAttempt: Date? {
        get { (defaults.object(forKey: Key.lastAttempt) as? Double).map(Date.init(timeIntervalSince1970:)) }
        set { defaults.set(newValue?.timeIntervalSince1970, forKey: Key.lastAttempt) }
    }
}

enum UpdatePolicy {
    static let launchDelay: TimeInterval = 10
    static let interval: TimeInterval = 6 * 3600
    /// How often the timer looks whether a check is due (a 6-hour timer would drift while the Mac sleeps).
    static let tick: TimeInterval = 15 * 60
    /// After a check that failed (no network, say), the next one is tried this much later.
    static let retry: TimeInterval = 15 * 60
    /// On wake, a check waits for the network a little, and only if the last one is an hour old or more.
    static let wakeDelay: TimeInterval = 30
    static let wakeGap: TimeInterval = 3600
    static let snooze: TimeInterval = 24 * 3600

    /// True when there was no answered check yet, the last one is `every` old, or the clock was set back past it, and
    /// no check was started in the last `retry` (15 minutes).
    static func isDue(lastCheck: Date?, lastAttempt: Date? = nil, now: Date, every: TimeInterval) -> Bool {
        if let lastAttempt, lastAttempt <= now, now.timeIntervalSince(lastAttempt) < retry { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= every || lastCheck > now
    }

    /// Notification permission for update notices: provisional, so macOS delivers them quietly to Notification Center
    /// without ever putting up a permission prompt the person didn't ask for.
    static let notificationOptions: UNAuthorizationOptions = [.alert, .provisional]

    static func isSkipped(_ item: UpdateItem) -> Bool {
        UpdatePreferences.skippedBuild.map { UpdateVersion.same($0, item.build) } ?? false
    }

    static func isSnoozed(_ item: UpdateItem, now: Date) -> Bool {
        guard let build = UpdatePreferences.snoozedBuild, UpdateVersion.same(build, item.build),
              let until = UpdatePreferences.snoozedUntil else { return false }
        return now < until
    }

    /// An automatic check announces an update once: not a skipped one, not while it is snoozed, not twice.
    static func shouldNotify(_ item: UpdateItem, now: Date) -> Bool {
        !isSkipped(item) && !isSnoozed(item, now: now)
            && !(UpdatePreferences.notifiedBuild.map { UpdateVersion.same($0, item.build) } ?? false)
    }

    /// The menu offers every known update except a skipped one.
    static func showsMenuItem(_ item: UpdateItem) -> Bool { !isSkipped(item) }
}

// MARK: - Notifications

enum UpdateNotificationAction: String {
    /// A click on the notification: the update alert, with the release notes (never an install without it).
    case show
    case skip = "com.yummyorange.app.update.skip"
    case later = "com.yummyorange.app.update.later"
}

protocol UpdateNotifying: AnyObject {
    func requestPermission(_ options: UNAuthorizationOptions, _ done: @escaping (Bool) -> Void)
    func checkPermission(_ done: @escaping (Bool) -> Void)
    func post(_ item: UpdateItem)
    func withdraw()
}

/// UNUserNotificationCenter. Only in the app (the center needs a bundle); self-tests use a stand-in.
final class SystemUpdateNotifier: NSObject, UpdateNotifying, UNUserNotificationCenterDelegate {
    static let category = "com.yummyorange.app.update"
    static let identifier = "com.yummyorange.app.update.available"
    weak var updater: Updater?

    private var center: UNUserNotificationCenter { .current() }

    func install() {
        center.delegate = self
        let later = UNNotificationAction(identifier: UpdateNotificationAction.later.rawValue, title: "Remind Me Later", options: [],
                                         icon: UNNotificationActionIcon(systemImageName: "clock"))
        let skip = UNNotificationAction(identifier: UpdateNotificationAction.skip.rawValue, title: "Skip This Version", options: [],
                                        icon: UNNotificationActionIcon(systemImageName: "forward.end"))
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [later, skip],
                                                                 intentIdentifiers: [], options: [])])
    }

    func requestPermission(_ options: UNAuthorizationOptions, _ done: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: options) { granted, _ in done(granted) }
    }

    func checkPermission(_ done: @escaping (Bool) -> Void) {
        center.getNotificationSettings { settings in
            done(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
        }
    }

    func post(_ item: UpdateItem) {
        let content = UNMutableNotificationContent()
        content.title = "YummyOrange \(item.version) is available"
        content.body = "Click to see what’s new and install it."
        content.categoryIdentifier = Self.category
        content.userInfo = ["build": item.build]
        content.interruptionLevel = .active
        center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
    }

    func withdraw() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let build = response.notification.request.content.userInfo["build"] as? String
        let action: UpdateNotificationAction?
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier: action = .show
        case UpdateNotificationAction.skip.rawValue: action = .skip
        case UpdateNotificationAction.later.rawValue: action = .later
        default: action = nil   // dismissed
        }
        if let action, let build {
            // From the run loop, not the main queue: responding may show an alert (MainThread.async explains why).
            MainThread.async { [weak self] in self?.updater?.respond(to: action, build: build) }
        }
        completionHandler()
    }
}

// MARK: - The updater's windows

enum UpdateChoice { case install, later, skip }

/// What the updater shows. The app's version uses alerts, the HUD, Finder and the relaunch helper; self-tests record.
protocol UpdateUI: AnyObject {
    /// The update alert: Install Update, Remind Me Later or Skip This Version.
    func offer(_ item: UpdateItem, current: String) -> UpdateChoice
    func tell(_ title: String, _ message: String)
    /// Progress in the HUD: a fraction, or nil for a spinner-style bar.
    func progress(_ title: String, _ fraction: Double?)
    /// Ends the progress, showing `text` for a moment when there is one.
    func endProgress(_ text: String?)
    func reveal(_ url: URL)
    /// Before the restart: `unsaved` describes editor windows whose changes would be lost. True to go ahead.
    func confirmRestart(_ unsaved: [String], version: String) -> Bool
    /// Opens `app` once this process has exited, then quits (once no conversion is running). False when the helper
    /// that opens it couldn't start, and YummyOrange keeps running.
    func relaunch(_ app: URL) -> Bool
}

final class SystemUpdateUI: UpdateUI {
    private var progressTitle: String?

    func offer(_ item: UpdateItem, current: String) -> UpdateChoice {
        let alert = NSAlert()
        alert.messageText = "A new version of YummyOrange is available."
        alert.informativeText = "YummyOrange \(item.version) is ready to install. You have \(current). YummyOrange restarts once it’s installed."
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Remind Me Later").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Skip This Version")
        alert.accessoryView = Self.notesView(item)
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .install
        case .alertThirdButtonReturn: return .skip
        default: return .later
        }
    }

    /// The release notes (if the feed has any) in a small scrolling text view, with a link to the full notes.
    static func notesView(_ item: UpdateItem) -> NSView? {
        let text = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                                   .foregroundColor: NSColor.labelColor]
        if let notes = item.releaseNotes { text.append(NSAttributedString(string: notes, attributes: body)) }
        if let url = item.releaseNotesURL {
            if text.length > 0 { text.append(NSAttributedString(string: "\n\n", attributes: body)) }
            var link = body
            link[.link] = url
            text.append(NSAttributedString(string: "Read the release notes", attributes: link))
        }
        guard text.length > 0 else { return nil }
        let width: CGFloat = 300
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: width, height: 10))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = CGSize(width: 0, height: 2)
        textView.textStorage?.setAttributedString(text)
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 40
        let height = min(max(used + 6, 20), 140)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = used + 6 > 140
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = textView
        textView.frame = CGRect(x: 0, y: 0, width: width, height: max(used + 6, height))
        textView.setAccessibilityLabel("Release notes")
        return scroll
    }

    func tell(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func progress(_ title: String, _ fraction: Double?) {
        if title != progressTitle {
            progressTitle = title
            HUD.shared.begin(title, always: true)
        }
        if let fraction { HUD.shared.update(progress: fraction) }
    }

    func endProgress(_ text: String?) {
        progressTitle = nil
        if let text { HUD.shared.flash(text, always: true, seconds: 3) } else { HUD.shared.hide() }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func confirmRestart(_ unsaved: [String], version: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restart YummyOrange to install version \(version)?"
        alert.informativeText = "\(unsaved.joined(separator: " ")) Restarting closes them without saving. To keep your changes, choose Not Now, save them, then choose Update to YummyOrange \(version)… in the menu again."
        alert.addButton(withTitle: "Not Now")
        let restart = alert.addButton(withTitle: "Restart and Install")
        restart.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    func relaunch(_ app: URL) -> Bool {
        do {
            try Relauncher.start(waitingFor: ProcessInfo.processInfo.processIdentifier, app.path)
        } catch {
            return false
        }
        // A moment for “Restarting YummyOrange…” to show, then quit; the helper opens the new app once this has gone.
        quitWhenNoJobRuns(after: 0.6)
        return true
    }

    /// Quits once no conversion is running, so a restart never cuts one off halfway (and leaves a partial file).
    private func quitWhenNoJobRuns(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            if JobRunner.runningCount > 0 { quitWhenNoJobRuns(after: 0.5) } else { NSApp.terminate(nil) }
        }
    }
}

/// Work a restart would lose: editor windows with unsaved changes. The updater asks before restarting over them.
enum PendingWork {
    /// One sentence per kind of window, for the restart alert; empty when nothing would be lost.
    static func unsavedEditors() -> [String] {
        let count = ImageEditors.EditorWindowController.unsavedCount + MediaEditorWindowController.unsavedCount
            + PDFEditWindowController.unsavedCount + PDFOrganizerController.unsavedCount
        switch count {
        case 0: return []
        case 1: return ["An editor window has changes that haven’t been saved."]
        default: return ["\(count) editor windows have changes that haven’t been saved."]
        }
    }
}

// MARK: - The updater

final class Updater {
    static let didChange = Notification.Name("DropWheelUpdaterDidChange")
    static let log = Logger(subsystem: "com.yummyorange.app", category: "updates")
    static let shared = Updater(environment: .app())

    /// What the updater works on. The app's comes from its bundle; self-tests make their own.
    struct Environment {
        var feedURL: URL?
        /// The release keys this copy trusts (DWUpdatePublicKey): for the feed's signature and the download's.
        var publicKeys: [Curve25519.Signing.PublicKey]
        /// The installed bundle the update replaces.
        var appURL: URL
        var bundleID: String
        var version: String
        var build: String
        var signer: CodeSigner
        /// Lets an ad-hoc or unsigned app update from a feed on this Mac (see CodeSignatureCheck).
        var localTestMode = false
        /// Revocation checks of the new app's certificate may use the network (off in self-tests).
        var networkForCodeChecks = true
        /// Where the new app goes when the installed one can't be replaced, tried in order.
        var fallbackFolders: [URL]
        var system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
        /// Why updates can't work in this copy, or nil when it can.
        var unavailableReason: String?

        var userAgent: String { "YummyOrange/\(version)" }

        /// This app: Info.plist's DWUpdateFeedURL and DWUpdatePublicKey (set by build.sh), its version and build,
        /// and its own code signature.
        static func app(bundle: Bundle = .main, environment env: [String: String] = ProcessInfo.processInfo.environment) -> Environment {
            let info = bundle.infoDictionary ?? [:]
            let feed = (info["DWUpdateFeedURL"] as? String).flatMap(URL.init(string:))
            let keys = UpdateArchiveCheck.publicKeys(base64: info["DWUpdatePublicKey"] as? String)
            let signer = CodeSigner.running()
            let fm = FileManager.default
            // Downloads first (where people look); ~/Applications when macOS keeps YummyOrange out of Downloads; last, a
            // temporary folder, which is always there.
            var fallbacks = [fm.urls(for: .downloadsDirectory, in: .userDomainMask).first].compactMap { $0 }
            let userApplications = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            if fm.isWritableFile(atPath: userApplications.path) { fallbacks.append(userApplications) }
            fallbacks.append(fm.temporaryDirectory.appendingPathComponent("YummyOrange Update", isDirectory: true))
            var result = Environment(feedURL: feed, publicKeys: keys, appURL: bundle.bundleURL,
                                     bundleID: bundle.bundleIdentifier ?? "", version: info["CFBundleShortVersionString"] as? String ?? "?",
                                     build: info["CFBundleVersion"] as? String ?? "0", signer: signer, fallbackFolders: fallbacks)
            var debug = false
            #if DEBUG
            debug = true
            #endif
            let loopbackFeed = feed.map(UpdateTransport.isLoopback) ?? false
            result.localTestMode = signer.teamID == nil && loopbackFeed && (debug || env["DW_UPDATE_LOCAL_TEST"] == "1")
            if bundle.bundleURL.pathExtension != "app" || bundle.bundleIdentifier == nil {
                result.unavailableReason = "Updates are available when YummyOrange runs as an app."
            } else if let feed, !UpdateTransport.isAllowed(feed, loopbackHTTP: true) {
                result.unavailableReason = "This copy of YummyOrange has an update address that isn’t secure (\(feed.absoluteString))."
            } else if feed == nil {
                result.unavailableReason = "This copy of YummyOrange has no update address. Download new versions from yummyorange.com."
            } else if keys.isEmpty {
                result.unavailableReason = "This copy of YummyOrange was built without an update key, so it can’t check for updates. Download new versions from yummyorange.com."
            } else if signer.teamID == nil && !result.localTestMode {
                result.unavailableReason = "This copy of YummyOrange isn’t signed by its developer, so it can’t tell a genuine update from another app. Download new versions from yummyorange.com."
            }
            return result
        }
    }

    enum Phase: Equatable { case idle, checking(manual: Bool), downloading, installing }

    /// A downloaded, verified and unpacked update, waiting to replace the installed app.
    struct Prepared {
        let folder: URL
        let app: URL
    }

    var environment: Environment
    var ui: UpdateUI = SystemUpdateUI()
    var notifier: UpdateNotifying?
    var now: () -> Date = Date.init
    /// Editor windows a restart would close without saving (see PendingWork); self-tests make their own.
    var unsavedWork: () -> [String] = PendingWork.unsavedEditors
    /// The newest higher build the last check found (nil when up to date).
    var latest: UpdateItem? { didSet { if latest != oldValue { changed() } } }
    private(set) var phase: Phase = .idle { didSet { if phase != oldValue { changed() } } }
    private let queue = DispatchQueue(label: "dropwheel.updates", qos: .utility)
    private var timer: Timer?
    private var launchCheck: DispatchWorkItem?
    private var settingsObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var scheduledAutomatic: Bool?

    init(environment: Environment) {
        self.environment = environment
    }

    var isAvailable: Bool { environment.unavailableReason == nil }

    /// The automatic checks' timer is running.
    var isScheduled: Bool { timer != nil }

    /// The update the menu offers: the latest, unless it was skipped.
    var menuUpdate: UpdateItem? { latest.flatMap { UpdatePolicy.showsMenuItem($0) ? $0 : nil } }

    private func changed() {
        let post = { NotificationCenter.default.post(name: Updater.didChange, object: self) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    // MARK: Scheduling (app only)

    /// From the app's launch: notifications, the 10-second launch check, the timer and the wake check.
    func start() {
        guard isAvailable else {
            Self.log.notice("updates are off: \(self.environment.unavailableReason ?? "", privacy: .public)")
            return
        }
        if notifier == nil, Bundle.main.bundleIdentifier != nil {
            let system = SystemUpdateNotifier()
            system.updater = self
            system.install()
            notifier = system
        }
        if settingsObserver == nil {
            settingsObserver = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
                self?.reschedule(launch: false)
            }
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                             queue: .main) { [weak self] _ in self?.didWake() }
        }
        reschedule(launch: true)
    }

    /// Starts or stops the automatic checks to follow Settings › General › Check for updates automatically.
    func reschedule(launch: Bool) {
        let automatic = Settings.checkForUpdatesAutomatically
        guard launch || automatic != scheduledAutomatic else { return }
        scheduledAutomatic = automatic
        timer?.invalidate()
        timer = nil
        launchCheck?.cancel()
        launchCheck = nil
        guard automatic else { return }
        let first = DispatchWorkItem { [weak self] in
            guard Settings.checkForUpdatesAutomatically else { return }
            self?.check(manual: false)
        }
        launchCheck = first
        // At launch, after 10 s; turned on later, at once if a check is due.
        if launch {
            DispatchQueue.main.asyncAfter(deadline: .now() + UpdatePolicy.launchDelay, execute: first)
        } else if isDue(every: UpdatePolicy.interval) {
            DispatchQueue.main.async(execute: first)
        }
        let timer = Timer(timeInterval: UpdatePolicy.tick, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// An answered check is `every` old (or there was none), and no check started in the last 15 minutes.
    private func isDue(every: TimeInterval) -> Bool {
        UpdatePolicy.isDue(lastCheck: UpdatePreferences.lastCheck, lastAttempt: UpdatePreferences.lastAttempt, now: now(), every: every)
    }

    private func tick() {
        guard Settings.checkForUpdatesAutomatically, isDue(every: UpdatePolicy.interval) else { return }
        check(manual: false)
    }

    private func didWake() {
        guard Settings.checkForUpdatesAutomatically, isDue(every: UpdatePolicy.wakeGap) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + UpdatePolicy.wakeDelay) { [weak self] in
            guard Settings.checkForUpdatesAutomatically else { return }
            self?.check(manual: false)
        }
    }

    // MARK: The steps (blocking; run on the updater's queue or in a self-test)

    /// Reads the feed, once its detached signature shows it was made with the release key, and says whether it offers
    /// a higher build.
    func fetch() throws -> UpdateCheckResult {
        if let reason = environment.unavailableReason { throw UpdateError.notAvailable(reason) }
        guard let feedURL = environment.feedURL else { throw UpdateError.notAvailable("No update address.") }
        guard !environment.publicKeys.isEmpty else { throw UpdateError.notAvailable("No update key.") }
        let data = try UpdateTransport.fetch(feedURL, userAgent: environment.userAgent)
        let signature = try UpdateTransport.fetch(UpdateFeed.signatureURL(for: feedURL), maxBytes: UpdateFeed.maxSignatureBytes,
                                                  userAgent: environment.userAgent)
        try UpdateFeed.checkSignature(of: data, signatureFile: signature, keys: environment.publicKeys)
        let item = try UpdateFeed.parse(data, feedURL: feedURL)
        return UpdateFeed.evaluate(item, currentBuild: environment.build, system: environment.system)
    }

    /// The code-signature policy for a new version, from how this copy is signed.
    func signaturePolicy() throws -> CodeSignatureCheck.Policy {
        try CodeSignatureCheck.policy(bundleID: environment.bundleID, running: environment.signer, localTestMode: environment.localTestMode)
    }

    /// Downloads the update next to the installed app (a temporary folder on its volume), verifies the ZIP, unpacks
    /// it and checks the new app. Nothing installed changes here.
    func prepare(_ item: UpdateItem, progress: @escaping (Double) -> Void = { _ in }) throws -> Prepared {
        if let reason = environment.unavailableReason { throw UpdateError.notAvailable(reason) }
        guard !environment.publicKeys.isEmpty else { throw UpdateError.notAvailable("No update key.") }
        guard UpdateFeed.evaluate(item, currentBuild: environment.build, system: environment.system) == .available(item) else {
            throw UpdateError.notNewer("YummyOrange \(item.version) (build \(item.build)) isn’t newer than the version you have, or needs a newer macOS.")
        }
        let policy = try signaturePolicy()
        let fm = FileManager.default
        let folder = UpdateInstaller.stagingFolder(for: environment.appURL, ignoresOwnership: UpdateInstaller.ignoresOwnership(environment.appURL))
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let zip = folder.appendingPathComponent("YummyOrange-\(item.version)-\(item.build).zip")
            let loopback = environment.feedURL.map(UpdateTransport.isLoopback) ?? false
            try UpdateTransport.download(item.url, to: zip, length: item.length, loopbackHTTP: loopback,
                                         userAgent: environment.userAgent, progress: progress)
            try UpdateArchiveCheck.verify(zip, item: item, keys: environment.publicKeys)
            let app = try UpdateInstaller.expand(zip, into: folder.appendingPathComponent("expanded", isDirectory: true))
            try? fm.removeItem(at: zip)
            try UpdateInstaller.checkInfo(of: app, item: item, bundleID: environment.bundleID,
                                          installedBuild: environment.build, system: environment.system)
            try CodeSignatureCheck.verify(app: app, policy: policy, network: environment.networkForCodeChecks)
            return Prepared(folder: folder, app: app)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    /// Puts the prepared app in place of the installed one, checks it again there (its Info.plist and its code
    /// signature, so nothing swapped in after the first check gets opened) and puts the old one back if that fails;
    /// when the installed app's folder can't be changed, the new app goes to a fallback folder for the person to move.
    func place(_ prepared: Prepared, _ item: UpdateItem) throws -> UpdateInstaller.Outcome {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: prepared.folder) }
        let environment = self.environment
        func parkIt(_ reason: String) throws -> UpdateInstaller.Outcome {
            .manual(try UpdateInstaller.park(prepared.app, version: item.version, in: environment.fallbackFolders), reason: reason)
        }
        if let reason = UpdateInstaller.blocker(for: environment.appURL) { return try parkIt(reason) }
        var policy = try signaturePolicy()
        // The second look: the same signature, not strict (a synced folder may stamp the bundle with Finder
        // information as soon as it lands), and without asking Gatekeeper again.
        policy.strict = false
        policy.gatekeeper = nil
        do {
            let installed = try UpdateInstaller.replace(environment.appURL, with: prepared.app) { placed in
                try UpdateInstaller.checkInfo(of: placed, item: item, bundleID: environment.bundleID,
                                              installedBuild: environment.build, system: environment.system)
                try CodeSignatureCheck.verify(app: placed, policy: policy, network: environment.networkForCodeChecks)
            }
            return .replaced(installed)
        } catch let failure as UpdateInstaller.SwapFailure {
            // The swap failed as a whole (replaceItemAt leaves the original alone then): hand the new app over instead.
            guard fm.fileExists(atPath: prepared.app.path) else { throw failure.underlying }
            return try parkIt(failure.underlying.localizedDescription)
        }
    }

    // MARK: The flow (main thread)

    /// A check: by hand (Check for Updates…), it always ends in an alert; automatic ones only announce an update.
    /// Results come back through MainThread.async rather than the main queue: they may run an alert, which must not
    /// hold up the main queue (see MainThread in Extensions.swift), and they stay in order with the progress.
    func check(manual: Bool) {
        if case .checking(let wasManual) = phase {
            if manual && !wasManual {   // an automatic check is running: report its result
                phase = .checking(manual: true)
                ui.progress("Checking for updates…", nil)
            }
            return
        }
        guard phase == .idle else { return }
        if let reason = environment.unavailableReason {
            if manual { ui.tell("YummyOrange can’t check for updates.", reason) }
            return
        }
        phase = .checking(manual: manual)
        UpdatePreferences.lastAttempt = now()
        if manual { ui.progress("Checking for updates…", nil) }
        queue.async {
            let result = Result { try self.fetch() }
            MainThread.async { self.finishCheck(result) }
        }
    }

    private func finishCheck(_ result: Result<UpdateCheckResult, Error>) {
        let manual = phase == .checking(manual: true)
        phase = .idle
        if manual { ui.endProgress(nil) }
        // Only an answer counts as a check: after a failure the timer tries again in 15 minutes, not 6 hours.
        if case .success = result { UpdatePreferences.lastCheck = now() }
        switch result {
        case .success(.available(let item)):
            latest = item
            if manual { offer(item) } else { announce(item) }
        case .success(.upToDate):
            latest = nil
            if manual {
                ui.tell("You’re up to date.", "YummyOrange \(environment.version) is the newest version.")
            }
        case .success(.needsNewerSystem(let item)):
            latest = nil
            if manual {
                ui.tell("YummyOrange \(item.version) needs macOS \(item.minimumSystemVersion ?? "") or later.",
                        "This Mac has macOS \(UpdateVersion.string(environment.system)), so YummyOrange \(environment.version) stays as it is.")
            }
        case .failure(let error):
            Self.log.error("update check failed: \(error.localizedDescription, privacy: .public)")
            if manual { ui.tell("YummyOrange couldn’t check for updates.", error.localizedDescription) }
        }
    }

    /// An automatic check found an update: a notification, once. Permission is asked for the first time only, and
    /// provisionally, so macOS shows no prompt for it.
    func announce(_ item: UpdateItem) {
        guard UpdatePolicy.shouldNotify(item, now: now()), let notifier else { return }
        UpdatePreferences.notifiedBuild = item.build
        if !UpdatePreferences.askedForNotifications {
            UpdatePreferences.askedForNotifications = true
            notifier.requestPermission(UpdatePolicy.notificationOptions) { granted in if granted { notifier.post(item) } }
        } else {
            notifier.checkPermission { allowed in if allowed { notifier.post(item) } }
        }
    }

    /// The menu's “Update to YummyOrange 1.0.1…”: the alert, then what was chosen.
    func offerLatest() {
        guard phase == .idle else { return }
        guard let item = latest else { check(manual: true); return }
        offer(item)
    }

    private func offer(_ item: UpdateItem) {
        switch ui.offer(item, current: environment.version) {
        case .install: install(item)
        case .later: remindLater(item.build)
        case .skip: skip(item.build)
        }
    }

    func skip(_ build: String) {
        UpdatePreferences.skippedBuild = build
        notifier?.withdraw()
        changed()
    }

    func remindLater(_ build: String) {
        UpdatePreferences.snoozedBuild = build
        UpdatePreferences.snoozedUntil = now().addingTimeInterval(UpdatePolicy.snooze)
        UpdatePreferences.notifiedBuild = nil   // announce it again once the snooze is over
        notifier?.withdraw()
        changed()
    }

    /// A notification was clicked, or one of its actions chosen.
    func respond(to action: UpdateNotificationAction, build: String) {
        switch action {
        case .show:
            // While a check runs (the timer's, say), it becomes one that shows its result: the alert, if it finds this.
            if case .checking = phase { check(manual: true); return }
            guard phase == .idle else { return }   // already downloading or installing
            if let item = latest, UpdateVersion.same(item.build, build) { offer(item) } else { check(manual: true) }
        case .skip: skip(build)
        case .later: remindLater(build)
        }
    }

    /// Asks before a restart would close editor windows with unsaved changes. True to go ahead.
    private func mayRestart(for item: UpdateItem) -> Bool {
        let unsaved = unsavedWork()
        return unsaved.isEmpty || ui.confirmRestart(unsaved, version: item.version)
    }

    /// Downloads, verifies and installs the update, then restarts YummyOrange. When an editor window has unsaved
    /// changes it asks first, before the download and again before the swap (one may have been opened meanwhile).
    func install(_ item: UpdateItem) {
        guard phase == .idle else { return }
        if let reason = environment.unavailableReason {
            ui.tell("YummyOrange can’t install updates.", reason)
            return
        }
        guard mayRestart(for: item) else { return }
        phase = .downloading
        notifier?.withdraw()
        let title = "Downloading YummyOrange \(item.version)…"
        ui.progress(title, 0)
        queue.async {
            let prepared: Prepared
            do {
                prepared = try self.prepare(item) { fraction in
                    MainThread.async { self.ui.progress(title, fraction) }
                }
            } catch {
                MainThread.async { self.finishInstall(.failure(error), item) }
                return
            }
            MainThread.async {
                guard self.mayRestart(for: item) else {
                    try? FileManager.default.removeItem(at: prepared.folder)
                    self.phase = .idle
                    self.ui.endProgress(nil)
                    return
                }
                self.phase = .installing
                self.ui.progress("Installing YummyOrange \(item.version)…", nil)
                self.queue.async {
                    let outcome = Result { try self.place(prepared, item) }
                    MainThread.async { self.finishInstall(outcome, item) }
                }
            }
        }
    }

    private func finishInstall(_ result: Result<UpdateInstaller.Outcome, Error>, _ item: UpdateItem) {
        switch result {
        case .success(.replaced(let app)):
            latest = nil
            ui.endProgress("Restarting YummyOrange…")
            // The phase stays .installing, so the menu stays dimmed until YummyOrange quits.
            guard ui.relaunch(app) else {
                // The new version is in place but this process keeps running: checks now compare with what's installed.
                phase = .idle
                environment.version = item.version
                environment.build = item.build
                ui.tell("YummyOrange was updated, but couldn’t restart itself.", "Quit YummyOrange and open it again to use version \(item.version).")
                return
            }
        case .success(.manual(let app, let reason)):
            phase = .idle
            ui.endProgress(nil)
            ui.reveal(app)
            ui.tell("YummyOrange can’t replace itself.",
                    "\(reason) The new version is in \(FileManager.default.displayName(atPath: app.deletingLastPathComponent().path)), shown in Finder. Quit YummyOrange, then drag the new version into the Applications folder, choosing Replace if asked.")
        case .failure(let error):
            phase = .idle
            Self.log.error("update failed: \(error.localizedDescription, privacy: .public)")
            ui.endProgress(nil)
            if let updateError = error as? UpdateError, case .damagedInstall = updateError {
                ui.tell("YummyOrange couldn’t install the update.", error.localizedDescription)
            } else {
                ui.tell("YummyOrange couldn’t install the update.", "\(error.localizedDescription) The version you have is unchanged.")
            }
        }
    }
}

// MARK: - Menu

/// “Update to YummyOrange 1.0.1…” at the top of the menu-bar menu (hidden while there is none), and “Check for
/// Updates…” above Settings…. AppDelegate.makeMenu adds them and refreshes them each time the menu opens.
enum UpdateMenu {
    static let checkTitle = "Check for Updates…"
    static let updateTag = 4801, separatorTag = 4802, checkTag = 4803

    static func title(for item: UpdateItem) -> String { "Update to YummyOrange \(item.version)…" }

    /// The update item and the separator under it, hidden until `refresh` finds an update.
    static func topItems() -> [NSMenuItem] {
        let item = NSMenuItem(title: "Update to YummyOrange…", action: #selector(UpdateMenuTarget.installUpdate), keyEquivalent: "")
        item.target = UpdateMenuTarget.shared
        item.tag = updateTag
        item.isHidden = true
        item.toolTip = "Shows what’s new, then installs the new version and restarts YummyOrange."
        let separator = NSMenuItem.separator()
        separator.tag = separatorTag
        separator.isHidden = true
        return [item, separator]
    }

    static func checkItem() -> NSMenuItem {
        let item = NSMenuItem(title: checkTitle, action: #selector(UpdateMenuTarget.checkForUpdates), keyEquivalent: "")
        item.target = UpdateMenuTarget.shared
        item.tag = checkTag
        item.toolTip = "Looks for a new version of YummyOrange now."
        return item
    }

    /// Shows the update item with its version, or hides it.
    static func refresh(_ menu: NSMenu, updater: Updater = UpdateMenuTarget.shared.updater) {
        let update = updater.menuUpdate
        if let item = menu.item(withTag: updateTag) {
            item.isHidden = update == nil
            if let update { item.title = title(for: update) }
        }
        menu.item(withTag: separatorTag)?.isHidden = update == nil
    }
}

final class UpdateMenuTarget: NSObject, NSMenuItemValidation {
    /// Menu items hold their target weakly, so it lives here for good.
    static let shared = UpdateMenuTarget()
    /// Self-tests swap in their own updater.
    var updater: Updater = .shared

    @objc func installUpdate() { updater.offerLatest() }
    @objc func checkForUpdates() { updater.check(manual: true) }

    /// Both are dimmed while a check, download or install is under way.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { updater.phase == .idle }
}

// MARK: - Module

/// No petals: the launch hook starts the automatic checks; `--selftest updater`.
enum UpdaterModule: FeatureModule {
    static var commands: [WheelCommand] { [] }

    static func appDidLaunch() { Updater.shared.start() }

    static func selfTest(_ name: String) -> String? {
        #if DEBUG
        if name == "updater" { return UpdaterTests.run() }
        // `--selftest updater-release:<Website/public folder>`: release.sh's output, read by this updater's own code.
        if name.hasPrefix("updater-release:") { return UpdaterTests.checkRelease(folder: String(name.dropFirst("updater-release:".count))) }
        #endif
        return nil
    }
}
