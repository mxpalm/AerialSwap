import AVFoundation
import Foundation

/// One Aerial video that is downloaded on this Mac.
struct AerialAsset: Identifiable, Hashable, Sendable {
    let id: String              // asset UUID, also the file name in videos/
    let name: String            // accessibilityLabel from entries.json
    let manifestURL: String?    // url-4K-SDR-240FPS from entries.json
    let videoURL: URL
    let thumbnailURL: URL       // aerials/thumbnails/<id>.png (may not exist)
}

/// What AerialSwap installed for an asset (persisted in state.json).
struct InstallRecord: Codable, Sendable {
    var installedAt: Date
    var installedSize: Int64
    var sourceName: String
    var protected: Bool
}

enum AerialStatus: Sendable, Equatable {
    case original
    case replaced(sourceName: String, installedAt: Date, protected: Bool)
    case resetByMacOS           // we installed something, but the file has since been replaced
}

enum StoreError: LocalizedError {
    case aerialsFolderMissing(String)
    case videoMissing(String)
    case notAnAppleOriginal(String)
    case backupMissing(String)
    case backupMismatch(expected: Int64, actual: Int64)
    case unexpectedFormat(String)
    case fileOperation(String, Error)

    var errorDescription: String? {
        switch self {
        case .aerialsFolderMissing(let p): "Aerials folder not found at \(p). Select any Aerial wallpaper in System Settings first."
        case .videoMissing(let id): "Video for asset \(id) is not downloaded."
        case .notAnAppleOriginal(let why): "Refusing to back up: the current file does not look like Apple's original (\(why))."
        case .backupMissing(let p): "No backup found at \(p)."
        case .backupMismatch(let e, let a): "Backup size (\(a) bytes) does not match the original (\(e) bytes)."
        case .unexpectedFormat(let m): "Transcoded file has an unexpected format: \(m)"
        case .fileOperation(let what, let error): "\(what) failed: \(error.localizedDescription)"
        }
    }
}

/// Reads Apple's Aerial store and performs backup / install / restore.
/// Only ever writes videos/<id>.mov (plus a temp file next to it) and AerialSwap's own folders.
struct AerialStore: Sendable {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var wallpaperDir: URL { home.appending(path: "Library/Application Support/com.apple.wallpaper") }
    var aerialsDir: URL { wallpaperDir.appending(path: "aerials") }
    var videosDir: URL { aerialsDir.appending(path: "videos") }
    var entriesURL: URL { aerialsDir.appending(path: "manifest/entries.json") }
    var indexURL: URL { wallpaperDir.appending(path: "Store/Index.plist") }
    var supportDir: URL { home.appending(path: "Library/Application Support/AerialSwap") }
    var backupsDir: URL { supportDir.appending(path: "backups") }
    var stateURL: URL { supportDir.appending(path: "state.json") }
    var installedDir: URL { supportDir.appending(path: "installed") }

    // Extended attributes WallpaperAerialsExtension uses to decide whether a file must be re-downloaded.
    static let trackedXattrs = ["SourceURL", "LastETag", "com.apple.quarantine"]
    static let aerialsProvider = "com.apple.wallpaper.choice.aerials"

    func backupURL(for id: String) -> URL { backupsDir.appending(path: "\(id).mov.apple-original") }
    /// Copy of what we installed, so it can be reinstalled after macOS resets the file.
    func installedCopyURL(for id: String) -> URL { installedDir.appending(path: "\(id).mov") }

    // MARK: - Reading

    /// Assets that actually exist in videos/, named via entries.json.
    func listAssets() throws -> [AerialAsset] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: videosDir.path) else { throw StoreError.aerialsFolderMissing(videosDir.path) }
        var names: [String: (String, String?)] = [:]
        if let data = try? Data(contentsOf: entriesURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let assets = json["assets"] as? [[String: Any]] {
            for a in assets {
                guard let id = a["id"] as? String else { continue }
                names[id] = (a["accessibilityLabel"] as? String ?? id, a["url-4K-SDR-240FPS"] as? String)
            }
        } else {
            Log.error("Could not parse \(entriesURL.path); showing raw asset IDs")
        }
        let files = try fm.contentsOfDirectory(at: videosDir, includingPropertiesForKeys: nil)
        return files
            .filter { $0.pathExtension == "mov" && !$0.lastPathComponent.hasPrefix(".") }
            .map { url in
                let id = url.deletingPathExtension().lastPathComponent
                return AerialAsset(id: id, name: names[id]?.0 ?? id, manifestURL: names[id]?.1, videoURL: url,
                                   thumbnailURL: aerialsDir.appending(path: "thumbnails/\(id).png"))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Currently selected Aerial IDs from Store/Index.plist. Each choice's "Configuration"
    /// is a nested binary plist like {assetID = "..."}.
    func detectSelection() -> (desktop: String?, idle: String?) {
        guard let data = try? Data(contentsOf: indexURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            Log.error("Could not read \(indexURL.path) for selection detection")
            return (nil, nil)
        }
        var desktop: String?, idle: String?
        func walk(_ node: Any, context: String) {
            if let dict = node as? [String: Any] {
                if dict["Provider"] as? String == Self.aerialsProvider,
                   let config = dict["Configuration"] as? Data,
                   let decoded = try? PropertyListSerialization.propertyList(from: config, format: nil) as? [String: Any],
                   let id = decoded["assetID"] as? String {
                    if context == "Desktop", desktop == nil { desktop = id }
                    if context == "Idle", idle == nil { idle = id }
                }
                for (key, value) in dict {
                    walk(value, context: (key == "Desktop" || key == "Idle") ? key : context)
                }
            } else if let array = node as? [Any] {
                for value in array { walk(value, context: context) }
            }
        }
        walk(root, context: "")
        return (desktop, idle)
    }

    func loadState() -> [String: InstallRecord] {
        guard let data = try? Data(contentsOf: stateURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: InstallRecord].self, from: data)) ?? [:]
    }

    func status(of asset: AerialAsset) -> AerialStatus {
        guard let record = loadState()[asset.id] else { return .original }
        if fileSize(asset.videoURL) == record.installedSize {
            return .replaced(sourceName: record.sourceName, installedAt: record.installedAt, protected: record.protected)
        }
        return .resetByMacOS
    }

    func hasBackup(_ asset: AerialAsset) -> Bool {
        FileManager.default.fileExists(atPath: backupURL(for: asset.id).path)
    }

    func canReinstall(_ asset: AerialAsset) -> Bool {
        loadState()[asset.id] != nil && FileManager.default.fileExists(atPath: installedCopyURL(for: asset.id).path)
    }

    // MARK: - Writing

    /// Copies Apple's original to our backups folder once. Never overwrites an existing backup.
    func ensureBackup(of asset: AerialAsset) throws {
        let fm = FileManager.default
        let backup = backupURL(for: asset.id)
        if fm.fileExists(atPath: backup.path) { return }
        guard fm.fileExists(atPath: asset.videoURL.path) else { throw StoreError.videoMissing(asset.id) }
        if case .replaced = status(of: asset) {
            throw StoreError.notAnAppleOriginal("AerialSwap's state says it is a replacement")
        }
        let sourceURL = xattrString(asset.videoURL, "SourceURL")
        guard let sourceURL, sourceURL == asset.manifestURL else {
            throw StoreError.notAnAppleOriginal("SourceURL attribute is \(sourceURL ?? "missing")")
        }
        try perform("Creating backups folder") { try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true) }
        let temp = backupsDir.appending(path: ".\(asset.id).partial")
        try? fm.removeItem(at: temp)
        // copyItem clones on APFS and keeps extended attributes.
        try perform("Backing up original") { try fm.copyItem(at: asset.videoURL, to: temp) }
        let expected = fileSize(asset.videoURL), actual = fileSize(temp)
        guard expected == actual, expected > 0 else {
            try? fm.removeItem(at: temp)
            throw StoreError.backupMismatch(expected: expected, actual: actual)
        }
        try perform("Finalizing backup") { try fm.moveItem(at: temp, to: backup) }
        Log.info("Backed up \(asset.id) (\(asset.name)) to \(backup.path)")
    }

    /// Installs a transcoded file as videos/<id>.mov atomically and restarts WallpaperAgent.
    func install(_ transcoded: URL, sourceName: String, over asset: AerialAsset, protect: Bool) async throws {
        try await validate(transcoded)
        try ensureBackup(of: asset)

        // Verify the backup before touching the live file.
        let backup = backupURL(for: asset.id)
        guard FileManager.default.fileExists(atPath: backup.path) else { throw StoreError.backupMissing(backup.path) }
        if status(of: asset) == .original {
            let live = fileSize(asset.videoURL), saved = fileSize(backup)
            guard live == saved else { throw StoreError.backupMismatch(expected: live, actual: saved) }
        }

        let attrs = carriedXattrs(for: asset)
        try replaceLiveFile(of: asset, with: transcoded, xattrs: attrs)
        if protect { try setImmutable(asset.videoURL, true) }

        var state = loadState()
        state[asset.id] = InstallRecord(installedAt: .now, installedSize: fileSize(asset.videoURL),
                                        sourceName: sourceName, protected: protect)
        try saveState(state)
        Log.info("Installed \(sourceName) over \(asset.id) (\(asset.name)), protected=\(protect)")
        keepInstalledCopy(of: transcoded, for: asset.id)
        restartWallpaperAgent()
    }

    /// Installs the kept copy again, e.g. after a macOS update put Apple's video back.
    func reinstall(_ asset: AerialAsset) async throws {
        let copy = installedCopyURL(for: asset.id)
        guard let record = loadState()[asset.id], FileManager.default.fileExists(atPath: copy.path) else {
            throw StoreError.backupMissing(copy.path)
        }
        try await install(copy, sourceName: record.sourceName, over: asset, protect: record.protected)
    }

    /// Non-fatal: the install already succeeded; without the copy only "Reinstall" is unavailable.
    private func keepInstalledCopy(of file: URL, for id: String) {
        let fm = FileManager.default
        let copy = installedCopyURL(for: id)
        guard file.standardizedFileURL != copy.standardizedFileURL else { return }   // reinstalling from the copy
        let temp = installedDir.appending(path: ".\(id).partial")
        do {
            try fm.createDirectory(at: installedDir, withIntermediateDirectories: true)
            try? fm.removeItem(at: temp)
            try fm.copyItem(at: file, to: temp)
            _ = try fm.replaceItemAt(copy, withItemAt: temp)
        } catch {
            try? fm.removeItem(at: temp)
            Log.error("Could not keep a copy for reinstalling \(id): \(error.localizedDescription)")
        }
    }

    /// Puts Apple's original back from our backup and restarts WallpaperAgent.
    func restore(_ asset: AerialAsset) throws {
        let backup = backupURL(for: asset.id)
        guard FileManager.default.fileExists(atPath: backup.path) else { throw StoreError.backupMissing(backup.path) }
        var attrs = carriedXattrs(for: asset)
        for name in Self.trackedXattrs { if let v = xattr(backup, name) { attrs[name] = v } }
        if let url = asset.manifestURL { attrs["SourceURL"] = Data(url.utf8) }
        try replaceLiveFile(of: asset, with: backup, xattrs: attrs)

        var state = loadState()
        state[asset.id] = nil
        try saveState(state)
        try? FileManager.default.removeItem(at: installedCopyURL(for: asset.id))
        Log.info("Restored original for \(asset.id) (\(asset.name))")
        restartWallpaperAgent()
    }

    func restartWallpaperAgent() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["WallpaperAgent"]
        do { try p.run(); p.waitUntilExit() } catch { Log.error("killall WallpaperAgent failed: \(error)") }
    }

    // MARK: - Helpers

    /// Copies `source` next to the live file, applies xattrs, then rename(2)s it into place.
    private func replaceLiveFile(of asset: AerialAsset, with source: URL, xattrs: [String: Data]) throws {
        let fm = FileManager.default
        let live = asset.videoURL
        if fm.fileExists(atPath: live.path) { try setImmutable(live, false) }
        let temp = videosDir.appending(path: ".\(asset.id).aerialswap-tmp")
        try? fm.removeItem(at: temp)
        try perform("Copying file into the aerials folder") { try fm.copyItem(at: source, to: temp) }
        do {
            for name in Self.trackedXattrs { removeXattr(temp, name) }
            for (name, value) in xattrs { try setXattr(temp, name, value) }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            guard rename(temp.path, live.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? fm.removeItem(at: temp)
            throw StoreError.fileOperation("Replacing \(live.lastPathComponent)", error)
        }
    }

    /// The xattrs that make WallpaperAerialsExtension accept the file as already downloaded.
    private func carriedXattrs(for asset: AerialAsset) -> [String: Data] {
        var result: [String: Data] = [:]
        let backup = backupURL(for: asset.id)
        for name in Self.trackedXattrs {
            if let v = xattr(asset.videoURL, name) ?? xattr(backup, name) { result[name] = v }
        }
        if let url = asset.manifestURL { result["SourceURL"] = Data(url.utf8) }
        return result
    }

    /// Checks the transcoded file matches what macOS expects before it goes near the aerials folder.
    private func validate(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw StoreError.unexpectedFormat("no video track")
        }
        let (size, formats) = try await track.load(.naturalSize, .formatDescriptions)
        guard Int(size.width) == Transcoder.width, Int(size.height) == Transcoder.height else {
            throw StoreError.unexpectedFormat("size is \(Int(size.width))x\(Int(size.height))")
        }
        guard let format = formats.first, CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC else {
            throw StoreError.unexpectedFormat("codec is not HEVC (hvc1)")
        }
        if try await !asset.loadTracks(withMediaType: .audio).isEmpty {
            throw StoreError.unexpectedFormat("file contains audio")
        }
    }

    private func saveState(_ state: [String: InstallRecord]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try perform("Saving state") {
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try encoder.encode(state).write(to: stateURL, options: .atomic)
        }
    }

    /// `chflags uchg` / `chflags nouchg`.
    func setImmutable(_ url: URL, _ on: Bool) throws {
        try perform(on ? "Protecting file (uchg)" : "Removing file protection (nouchg)") {
            try FileManager.default.setAttributes([.immutable: on], ofItemAtPath: url.path)
        }
    }

    func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func perform(_ what: String, _ body: () throws -> Void) throws {
        do { try body() } catch { throw StoreError.fileOperation(what, error) }
    }

    private func xattr(_ url: URL, _ name: String) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let length = getxattr(path, name, nil, 0, 0, 0)
            guard length >= 0 else { return nil }
            var data = Data(count: length)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, 0) }
            return read == length ? data : nil
        }
    }

    private func xattrString(_ url: URL, _ name: String) -> String? {
        xattr(url, name).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func setXattr(_ url: URL, _ name: String, _ value: Data) throws {
        let result = url.withUnsafeFileSystemRepresentation { path in
            value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, 0) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func removeXattr(_ url: URL, _ name: String) {
        _ = url.withUnsafeFileSystemRepresentation { removexattr($0, name, 0) }
    }
}
