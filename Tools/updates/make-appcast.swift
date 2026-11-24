// Writes the update feed (appcast.json) that YummyOrange's updater reads (Sources/DropWheel/Updater.swift):
//
//   swift Tools/updates/make-appcast.swift --version 1.0.1 --build 2 --url ../downloads/YummyOrange-1.0.1.zip \
//       --length 7340032 --sha256 <hex> --signature <base64> [--minimum-system 13.0] \
//       [--notes-url ../release-notes.html] [--notes "What changed."] [--published 2026-11-24T12:00:00Z] <out.json>
//
// Addresses may be relative to the feed; release.sh writes them so, which keeps the feed right whatever the site's
// domain turns out to be. Every value is checked the way the app will check it, so a feed the app would refuse is
// never written. The file is written next to its destination and then moved into place.
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-appcast: \(message)\n".utf8))
    exit(1)
}

func isVersion(_ s: String) -> Bool {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    return (1...3).contains(parts.count) && parts.allSatisfy { (1...9).contains($0.count) && $0.allSatisfy { ("0"..."9").contains($0) } }
}

var values: [String: String] = [:]
var output: String?
var rest = Array(CommandLine.arguments.dropFirst())[...]
let known = ["--version", "--build", "--url", "--length", "--sha256", "--signature", "--minimum-system", "--notes-url", "--notes", "--published"]
while let arg = rest.first {
    rest = rest.dropFirst()
    if known.contains(arg) {
        guard let value = rest.first else { fail("\(arg) needs a value") }
        values[arg] = value
        rest = rest.dropFirst()
    } else if output == nil, !arg.hasPrefix("--") {
        output = arg
    } else {
        fail("unknown argument \(arg)")
    }
}
guard let output else { fail("no output file given") }
for required in ["--version", "--build", "--url", "--length", "--sha256", "--signature"] where values[required] == nil {
    fail("\(required) is required")
}

let version = values["--version"]!, build = values["--build"]!
guard isVersion(version), isVersion(build) else { fail("--version and --build must be up to three numbers joined by dots") }
let minimum = values["--minimum-system"] ?? "13.0"
guard isVersion(minimum) else { fail("--minimum-system must be a version such as 13.0") }
guard let length = Int(values["--length"]!), length > 0, length <= 512 * 1024 * 1024 else { fail("--length must be 1 byte to 512 MB") }
let sha = values["--sha256"]!.lowercased()
guard sha.count == 64, sha.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { fail("--sha256 must be 64 hex digits") }
let signature = values["--signature"]!
guard Data(base64Encoded: signature)?.count == 64 else { fail("--signature must be a base64 Ed25519 signature") }

func checkLink(_ raw: String, _ name: String) {
    guard let url = URL(string: raw) else { fail("\(name) isn’t an address") }
    if url.scheme == nil { return }   // relative to the feed, which is HTTPS
    guard url.scheme == "https", url.host != nil else { fail("\(name) must be https:// or relative to the feed") }
}
checkLink(values["--url"]!, "--url")

var feed: [String: Any] = [
    "version": version, "build": build, "minimumSystemVersion": minimum, "url": values["--url"]!,
    "length": length, "sha256": sha, "signature": signature,
]
if let notesURL = values["--notes-url"], !notesURL.isEmpty {
    checkLink(notesURL, "--notes-url")
    feed["releaseNotesURL"] = notesURL
}
if let notes = values["--notes"]?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
    feed["releaseNotes"] = String(notes.prefix(4000))
}
let published = values["--published"] ?? ISO8601DateFormatter().string(from: Date())
guard ISO8601DateFormatter().date(from: published) != nil else { fail("--published must be like 2026-11-24T12:00:00Z") }
feed["published"] = published

guard let data = try? JSONSerialization.data(withJSONObject: feed, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
      data.count < 64 * 1024 else { fail("the feed couldn’t be written as JSON under 64 KB") }
let destination = URL(fileURLWithPath: output)
let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(getpid())")
do {
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (data + Data("\n".utf8)).write(to: temporary)
    if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    } else {
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
} catch {
    try? FileManager.default.removeItem(at: temporary)
    fail("can’t write \(output): \(error.localizedDescription)")
}
print(destination.path)
