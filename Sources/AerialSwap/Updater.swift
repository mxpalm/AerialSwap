import AppKit
import CryptoKit
import Foundation

/// Installs a release in place: downloads its zip and signature, checks the signature against the release key built
/// in here, unpacks it, checks the new app (same bundle ID, newer version, intact code signature), puts it where this
/// app is and relaunches. Files the app downloads itself get no quarantine flag, so macOS doesn't ask again
/// (tested on 27.2 with an ad-hoc signed app, see docs/TECHNICAL.md).
enum Updater {
    /// Ed25519 public key of the release key. Its private key is in the Keychain of whoever builds releases
    /// ("AerialSwap release key", used by build.sh --zip through Tools/release_key.swift).
    static let releasePublicKey = "Kzku0V6sLJTxjHdG7Vvzwjqs+60FQ4d8Kj2P6n+uJ04="

    /// A copy opened in place from Downloads runs translocated (read-only), and a folder this user can't write to
    /// (an app installed by another account) can't be updated either; those download the update by hand.
    static var canInstall: Bool {
        let app = Bundle.main.bundleURL
        return app.pathExtension == "app" && !GroupWatcher.isTranslocated
            && FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    /// Replaces the running app with the release at `zip` (signed by `signature`) and returns where it now is.
    static func install(zip: URL, signature: URL) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appending(path: "AerialSwap-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let zipFile = work.appending(path: "update.zip")
        try await download(zip, to: zipFile)
        let sigFile = work.appending(path: "update.zip.sig")
        try await download(signature, to: sigFile)
        try verifySignature(of: zipFile, signatureFile: sigFile)

        let unpacked = work.appending(path: "unpacked")
        guard try await run("/usr/bin/ditto", ["-x", "-k", zipFile.path, unpacked.path]) == 0 else { throw UpdateInstallError.unpack }
        let newApp = unpacked.appending(path: "AerialSwap.app")
        let info = Bundle(url: newApp)?.infoDictionary ?? [:]
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw UpdateInstallError.wrongApp }
        let newVersion = info["CFBundleShortVersionString"] as? String ?? ""
        guard let current = UpdateChecker.currentVersion, UpdateChecker.isVersion(newVersion, newerThan: current) else {
            throw UpdateInstallError.notNewer(newVersion)
        }
        guard try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) == 0 else {
            throw UpdateInstallError.codeSignature
        }

        let installed = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: newApp) ?? Bundle.main.bundleURL
        Log.info("Update: installed AerialSwap \(newVersion) at \(installed.path)")
        return installed
    }

    /// Opens `app` once this process has exited, then quits.
    @MainActor static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                       "sh", String(getpid()), app.path]
        do { try p.run() } catch { Log.error("Update: could not schedule the relaunch: \(error)") }
        NSApp.terminate(nil)
    }

    private static func verifySignature(of file: URL, signatureFile: URL) throws {
        let text = (try? String(contentsOf: signatureFile, encoding: .utf8)) ?? ""
        guard let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: releasePublicKey) ?? Data()),
              key.isValidSignature(signature, for: try Data(contentsOf: file)) else {
            throw UpdateInstallError.badSignature
        }
    }

    private static func download(_ url: URL, to destination: URL) async throws {
        let (file, response) = try await URLSession.shared.download(from: url)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 { throw UpdateError.http(status) }
        try FileManager.default.moveItem(at: file, to: destination)
    }

    private static func run(_ path: String, _ arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = arguments
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

enum UpdateInstallError: LocalizedError {
    case badSignature, unpack, wrongApp, notNewer(String), codeSignature, noDownload

    var errorDescription: String? {
        switch self {
        case .badSignature: "The download isn't signed by AerialSwap's release key, so it wasn't installed."
        case .unpack: "The download couldn't be unpacked."
        case .wrongApp: "The download isn't AerialSwap."
        case .notNewer(let version): "The download is version \(version), not newer than this one."
        case .codeSignature: "The downloaded app is damaged (its code signature doesn't match)."
        case .noDownload: "This release has no signed download."
        }
    }
}
