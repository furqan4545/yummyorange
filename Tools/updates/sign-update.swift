// Signs a file (an update ZIP, or the feed itself) with YummyOrange's private update key and prints what the feed needs:
//
//   swift Tools/updates/sign-update.swift [--public-key "<base64> [<base64>…]"] <private key file> <file>
//
//   sha256 <64 hex digits>
//   length <bytes>
//   signature <base64 Ed25519 signature of the file's bytes>
//
// --public-key: the keys the app trusts (UPDATE_PUBLIC_KEY, one or more separated by spaces). When the private key's
// own public half isn't one of them, nothing is printed and the exit status is 1, so a release can't be signed with a
// key the app doesn't trust. The signature is checked against the public key before it is printed. The private key
// file must be readable by you alone. An encrypted key (make-update-keys.swift's usual kind) needs its passphrase:
// from UPDATE_KEY_PASSPHRASE, or asked for on the terminal.
import CommonCrypto
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sign-update: \(message)\n".utf8))
    exit(1)
}

var rest = Array(CommandLine.arguments.dropFirst())
var expectedPublic: [String]?
if rest.first == "--public-key" {
    guard rest.count >= 2 else { fail("--public-key needs a value") }
    expectedPublic = rest[1].split(whereSeparator: { $0 == " " || $0 == "," || $0.isNewline }).map(String.init)
    rest.removeFirst(2)
}
guard rest.count == 2 else {
    fail("usage: swift Tools/updates/sign-update.swift [--public-key <base64>] <private key file> <file>")
}
let keyURL = URL(fileURLWithPath: (rest[0] as NSString).expandingTildeInPath)
let fileURL = URL(fileURLWithPath: (rest[1] as NSString).expandingTildeInPath)

var info = stat()
guard stat(keyURL.path, &info) == 0 else { fail("can’t read the private key \(keyURL.path)") }
guard info.st_mode & 0o077 == 0 else {
    fail("\(keyURL.path) can be read by other users; run chmod 600 on it first")
}
guard let text = try? String(contentsOf: keyURL, encoding: .utf8) else { fail("can’t read the private key \(keyURL.path)") }

let header = "dropwheel-update-key 2"

/// 32 bytes from the passphrase and salt with PBKDF2-HMAC-SHA256 (as make-update-keys.swift makes them).
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

func passphrase() -> String {
    if let given = ProcessInfo.processInfo.environment["UPDATE_KEY_PASSPHRASE"], !given.isEmpty { return given }
    var buffer = [CChar](repeating: 0, count: 1024)
    guard let read = readpassphrase("Passphrase for \(keyURL.lastPathComponent): ", &buffer, buffer.count, RPP_REQUIRE_TTY) else {
        fail("\(keyURL.path) is encrypted: set UPDATE_KEY_PASSPHRASE, or run this on a terminal")
    }
    let typed = String(cString: read)
    _ = buffer.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) }
    return typed
}

let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
let raw: Data
if lines.first == header {
    let parameters = lines.count == 3 ? lines[1].split(separator: " ").map(String.init) : []
    guard parameters.count == 3, parameters[0] == "pbkdf2-sha256", let rounds = UInt32(parameters[1]), rounds >= 100_000,
          let salt = Data(base64Encoded: parameters[2]), let combined = Data(base64Encoded: lines[2]),
          let box = try? AES.GCM.SealedBox(combined: combined) else {
        fail("\(keyURL.path) isn’t a key made by make-update-keys.swift")
    }
    guard let sealingKey = derive(passphrase(), salt: salt, rounds: rounds),
          let opened = try? AES.GCM.open(box, using: sealingKey, authenticating: Data(header.utf8)) else {
        fail("the passphrase for \(keyURL.path) is wrong")
    }
    raw = opened
} else {
    guard lines.count == 1, let plain = Data(base64Encoded: lines[0]) else { fail("\(keyURL.path) isn’t a key made by make-update-keys.swift") }
    raw = plain
}
guard raw.count == 32, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    fail("\(keyURL.path) isn’t a key made by make-update-keys.swift")
}
let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
if let expectedPublic, !expectedPublic.contains(publicKey) {
    fail("the private key isn’t one of the keys given with --public-key (its public key is \(publicKey))")
}

guard let data = try? Data(contentsOf: fileURL, options: .alwaysMapped), !data.isEmpty else {
    fail("can’t read \(fileURL.path)")
}
guard let signature = try? key.signature(for: data), key.publicKey.isValidSignature(signature, for: data) else {
    fail("signing failed")
}
let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
print("sha256 \(sha)")
print("length \(data.count)")
print("signature \(signature.base64EncodedString())")
