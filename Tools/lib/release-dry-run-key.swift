// Disposable Sparkle signing material. Never reads or writes the Keychain.
import CryptoKit
import Foundation

let key = Curve25519.Signing.PrivateKey()
let path = URL(fileURLWithPath: CommandLine.arguments[1])
try key.rawRepresentation.base64EncodedData().write(to: path, options: .atomic)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
print(key.publicKey.rawRepresentation.base64EncodedString())
