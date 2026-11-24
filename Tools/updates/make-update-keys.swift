// Makes YummyOrange's update-signing key pair (Ed25519), once.
//
//   swift Tools/updates/make-update-keys.swift ~/.dropwheel/update-signing-key
//   swift Tools/updates/make-update-keys.swift --no-passphrase <file>     (throwaway keys: release.sh --dry-run)
//
// The private key is written to the path given, readable by you alone (0600), encrypted with a passphrase you choose
// (asked for twice on the terminal, or taken from UPDATE_KEY_PASSPHRASE): PBKDF2-SHA256 makes a key from it and
// AES-GCM seals the Ed25519 key, so a copy of the file (a backup, Time Machine, another program) is no use without the
// passphrase. The file must not exist yet: this never replaces a key, since apps already out there trust only the keys
// they were built with. The public key is printed as base64 on standard output; it goes into
// Tools/updates/release-identity as UPDATE_PUBLIC_KEY.
//
// Nothing goes into the Keychain. The key may not be made inside the project, on the Desktop, in Documents or in
// iCloud Drive (they are synced or committed sooner or later). Make a second key the same way as a backup, keep it off
// this Mac, and list its public half in release-identity too: copies built with both keys accept updates signed with
// either, so a lost or leaked key can be replaced.
import CommonCrypto
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-update-keys: \(message)\n".utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
let plain = arguments.first == "--no-passphrase"
if plain { arguments.removeFirst() }
guard arguments.count == 1, let path = arguments.first, !path.hasPrefix("-") else {
    fail("usage: swift Tools/updates/make-update-keys.swift [--no-passphrase] <private key file to create>")
}
let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL

/// The device and inode of a folder: its identity, whatever letter case or Unicode spelling names it.
func identity(_ path: String) -> (dev_t, ino_t)? {
    var info = stat()
    return stat(path, &info) == 0 ? (info.st_dev, info.st_ino) : nil
}

/// True when `path` (which need not exist yet) is inside `folder`: some existing folder above it is `folder` itself.
func isInside(_ path: String, _ folder: String) -> Bool {
    guard let target = identity(folder) else { return false }
    var current = URL(fileURLWithPath: path).standardizedFileURL
    while true {
        if let id = identity(current.path), id == target { return true }
        if current.path == "/" { return false }
        current.deleteLastPathComponent()
    }
}

// A key inside the website or the project would be published or committed sooner or later; Desktop, Documents and
// iCloud Drive are synced.
let script = URL(fileURLWithPath: #filePath).standardizedFileURL
let project = script.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
if isInside(url.path, project.path) {
    fail("\(url.path) is inside the project (\(project.path)). Choose a path outside it, such as ~/.dropwheel/update-signing-key.")
}
let home = NSHomeDirectory()
for synced in ["Desktop", "Documents", "Library/Mobile Documents"] where isInside(url.path, home + "/" + synced) {
    fail("\(url.path) is in ~/\(synced), which is synced or backed up to other places. Choose a path such as ~/.dropwheel/update-signing-key.")
}

/// A passphrase typed on the terminal without echo, or nil.
func ask(_ prompt: String) -> String? {
    var buffer = [CChar](repeating: 0, count: 1024)
    guard let read = readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) else { return nil }
    let text = String(cString: read)
    _ = buffer.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) }
    return text
}

var passphrase = ""
if !plain {
    if let given = ProcessInfo.processInfo.environment["UPDATE_KEY_PASSPHRASE"], !given.isEmpty {
        passphrase = given
    } else {
        guard let first = ask("Passphrase for the new update key: "), let second = ask("The same passphrase again: ") else {
            fail("no terminal to ask for a passphrase on: set UPDATE_KEY_PASSPHRASE, or use --no-passphrase for a throwaway key")
        }
        guard first == second else { fail("the two passphrases differ") }
        passphrase = first
    }
    guard passphrase.count >= 12 else { fail("the passphrase must be at least 12 characters (a few words is best)") }
}

let folder = url.deletingLastPathComponent()
do {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
} catch {
    fail("can’t create \(folder.path): \(error.localizedDescription)")
}

let header = "dropwheel-update-key 2"
let rounds: UInt32 = 600_000

/// 32 bytes from the passphrase and salt with PBKDF2-HMAC-SHA256.
func derive(_ passphrase: String, salt: Data, rounds: UInt32) -> SymmetricKey? {
    var derived = Data(count: 32)
    let password = Array(passphrase.utf8)
    let status = derived.withUnsafeMutableBytes { out in
        salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.map { CChar(bitPattern: $0) }, password.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                 out.bindMemory(to: UInt8.self).baseAddress, 32)
        }
    }
    return status == kCCSuccess ? SymmetricKey(data: derived) : nil
}

let key = Curve25519.Signing.PrivateKey()
let contents: Data
if plain {
    contents = Data((key.rawRepresentation.base64EncodedString() + "\n").utf8)
} else {
    var salt = Data(count: 16)
    guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess,
          let sealingKey = derive(passphrase, salt: salt, rounds: rounds),
          let sealed = try? AES.GCM.seal(key.rawRepresentation, using: sealingKey, authenticating: Data(header.utf8)).combined else {
        fail("couldn’t encrypt the key")
    }
    contents = Data("\(header)\npbkdf2-sha256 \(rounds) \(salt.base64EncodedString())\n\(sealed.base64EncodedString())\n".utf8)
}

// O_EXCL: never overwrite an existing key; 0600 from the first byte, so the key is never readable by others.
let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
guard fd >= 0 else {
    if errno == EEXIST { fail("\(url.path) already exists. A key is made once; keep using the one you have.") }
    fail("can’t create \(url.path): \(String(cString: strerror(errno)))")
}
let written = contents.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
guard written == contents.count, fchmod(fd, 0o600) == 0, fsync(fd) == 0, close(fd) == 0 else {
    unlink(url.path)
    fail("couldn’t write \(url.path)")
}

// Read it back and check it signs and verifies, so a damaged file is caught now rather than at release time.
func reread() -> Curve25519.Signing.PrivateKey? {
    guard let saved = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let lines = saved.split(separator: "\n").map(String.init)
    if plain {
        return lines.count == 1 ? Data(base64Encoded: lines[0]).flatMap { try? Curve25519.Signing.PrivateKey(rawRepresentation: $0) } : nil
    }
    let parameters = lines.count == 3 ? lines[1].split(separator: " ").map(String.init) : []
    guard lines.first == header, parameters.count == 3, parameters[0] == "pbkdf2-sha256", let n = UInt32(parameters[1]),
          let salt = Data(base64Encoded: parameters[2]), let combined = Data(base64Encoded: lines[2]),
          let sealingKey = derive(passphrase, salt: salt, rounds: n), let box = try? AES.GCM.SealedBox(combined: combined),
          let raw = try? AES.GCM.open(box, using: sealingKey, authenticating: Data(header.utf8)) else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}
guard let back = reread(), let probe = try? back.signature(for: Data("YummyOrange".utf8)),
      key.publicKey.isValidSignature(probe, for: Data("YummyOrange".utf8)) else {
    unlink(url.path)
    fail("the key written to \(url.path) didn’t read back, so it was removed; try again")
}

FileHandle.standardError.write(Data("""
Private key: \(url.path) (only you can read it\(plain ? ", not encrypted" : "; encrypted with your passphrase")). Back it up; never commit or publish it.
Public key (UPDATE_PUBLIC_KEY in Tools/updates/release-identity), also printed below:

""".utf8))
print(key.publicKey.rawRepresentation.base64EncodedString())
