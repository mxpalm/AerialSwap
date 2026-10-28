// AerialSwap's release key (Ed25519). The private key lives in the Keychain as "AerialSwap release key"; the app
// has the public key built in (Updater.releasePublicKey) and installs only zips signed with it.
//   release_key generate         prints a new private key (base64), for `security add-generic-password`
//   release_key public           reads a private key on stdin, prints its public key
//   release_key sign <file>      reads a private key on stdin, prints the file's signature (base64)
// build.sh --zip compiles this and signs the release zip. See docs/TECHNICAL.md, "Releases and updates".
import CryptoKit
import Foundation

func privateKey() -> Curve25519.Signing.PrivateKey {
    let text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        FileHandle.standardError.write(Data("release_key: no valid private key on stdin\n".utf8)); exit(1)
    }
    return key
}

let args = CommandLine.arguments.dropFirst()
switch (args.first, args.count) {
case ("generate", 1):
    print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())
case ("public", 1):
    print(privateKey().publicKey.rawRepresentation.base64EncodedString())
case ("sign", 2):
    let key = privateKey()
    guard let data = FileManager.default.contents(atPath: args.last!) else {
        FileHandle.standardError.write(Data("release_key: can't read \(args.last!)\n".utf8)); exit(1)
    }
    print(try! key.signature(for: data).base64EncodedString())
default:
    FileHandle.standardError.write(Data("usage: release_key generate | public | sign <file>\n".utf8)); exit(2)
}
