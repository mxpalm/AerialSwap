import Foundation

/// One Aerial video that is downloaded on this Mac.
struct AerialAsset: Identifiable, Hashable, Sendable {
    let id: String              // asset UUID, also the file name in videos/
    let name: String            // accessibilityLabel from entries.json
    let manifestURL: String?    // url-4K-SDR-240FPS from entries.json
    let videoURL: URL
    let thumbnailURL: URL       // aerials/thumbnails/<id>.png (may not exist)
    var isOwn = false           // one of our wallpapers in the AerialSwap group (see AerialGroup), not Apple's
}

enum StoreError: LocalizedError {
    case aerialsFolderMissing(String)
    case fileOperation(String, Error)

    var errorDescription: String? {
        switch self {
        case .aerialsFolderMissing(let p): "Aerials folder not found at \(p). Select any Aerial wallpaper in System Settings first."
        case .fileOperation(let what, let error): "\(what) failed: \(error.localizedDescription)"
        }
    }
}

/// Reads Apple's Aerial store and switches which Aerial the desktop and screen saver show: only the assetID inside
/// Store/Index.plist's existing Aerial choices is written. The AerialSwap group (entries.json and our own videos and
/// thumbnails) is written by AerialGroup.
struct AerialStore: Sendable {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var wallpaperDir: URL { home.appending(path: "Library/Application Support/com.apple.wallpaper") }
    var aerialsDir: URL { wallpaperDir.appending(path: "aerials") }
    var videosDir: URL { aerialsDir.appending(path: "videos") }
    var entriesURL: URL { aerialsDir.appending(path: "manifest/entries.json") }
    var indexURL: URL { wallpaperDir.appending(path: "Store/Index.plist") }
    var supportDir: URL { home.appending(path: "Library/Application Support/AerialSwap") }

    // Extended attributes WallpaperAerialsExtension uses to decide whether a file must be re-downloaded.
    static let trackedXattrs = ["SourceURL", "LastETag", "com.apple.quarantine"]
    static let aerialsProvider = "com.apple.wallpaper.choice.aerials"
    /// Index.plist keys whose choices belong to the desktop, the screen saver, or both ("Linked").
    static let roleKeys: Set<String> = ["Desktop", "Idle", "Linked"]
    /// macOS's own fallback wallpaper in Index.plist, which is neither read nor changed.
    static let systemDefaultKey = "SystemDefault"

    /// The macOS major version the group was verified on (see README, "How it works"). A newer one may have changed
    /// the internals AerialSwap relies on (manifest, xattrs, temporal layers).
    static let testedMajorVersion = 27

    /// A sentence for the Set as Wallpaper confirmation when this Mac runs a newer macOS than was tested, else nil.
    static var untestedSystemWarning: String? {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion > testedMajorVersion else { return nil }
        return "This Mac runs macOS \(version.majorVersion).\(version.minorVersion), and AerialSwap was tested on macOS "
            + "\(testedMajorVersion). Apple may have changed how Aerials work, so the AerialSwap group might not show up."
    }

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
                                   thumbnailURL: aerialsDir.appending(path: "thumbnails/\(id).png"),
                                   isOwn: AerialGroup.isOwn(xattrString(url, "SourceURL")))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Currently selected Aerial IDs from Store/Index.plist. Each choice's "Configuration"
    /// is a nested binary plist like {assetID = "..."}. A "Linked" entry (Type = linked: the screen saver shows the
    /// desktop's wallpaper) counts for both.
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
                    if context == "Desktop" || context == "Linked", desktop == nil { desktop = id }
                    if context == "Idle" || context == "Linked", idle == nil { idle = id }
                }
                for (key, value) in dict where key != Self.systemDefaultKey {
                    walk(value, context: Self.roleKeys.contains(key) ? key : context)
                }
            } else if let array = node as? [Any] {
                for value in array { walk(value, context: context) }
            }
        }
        walk(root, context: "")
        return (desktop, idle)
    }

    /// Points every existing Aerial choice for the desktop and/or screen saver at `assetID`, on all displays and
    /// Spaces, then restarts WallpaperAgent so it reads the change. Choices that aren't Aerials (photos, colors) are
    /// left alone, so a slot can only be switched when it already shows an Aerial. A "Linked" choice serves both, so it
    /// changes for either. Returns how many choices changed.
    /// The previous file is kept as Index.plist.before-change in AerialSwap's folder.
    @discardableResult
    func setSelection(_ assetID: String, desktop: Bool, idle: Bool) throws -> Int {
        let data: Data
        var format = PropertyListSerialization.PropertyListFormat.binary
        let root: Any
        do {
            data = try Data(contentsOf: indexURL)
            root = try PropertyListSerialization.propertyList(from: data, format: &format)
        } catch {
            throw StoreError.fileOperation("Reading the wallpaper settings", error)
        }
        let configuration = try PropertyListSerialization.data(fromPropertyList: ["assetID": assetID], format: .binary, options: 0)
        var changed = 0
        func rewrite(_ node: Any, context: String) -> Any {
            if var dict = node as? [String: Any] {
                if dict["Provider"] as? String == Self.aerialsProvider, dict["Configuration"] is Data,
                   (context == "Desktop" && desktop) || (context == "Idle" && idle) || (context == "Linked" && (desktop || idle)) {
                    dict["Configuration"] = configuration
                    changed += 1
                }
                for (key, value) in dict where key != Self.systemDefaultKey {
                    dict[key] = rewrite(value, context: Self.roleKeys.contains(key) ? key : context)
                }
                return dict
            }
            if let array = node as? [Any] { return array.map { rewrite($0, context: context) } }
            return node
        }
        let updated = rewrite(root, context: "")
        guard changed > 0 else { return 0 }

        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let backup = supportDir.appending(path: "Index.plist.before-change")
        try? fm.removeItem(at: backup)
        try data.write(to: backup)
        do {
            let out = try PropertyListSerialization.data(fromPropertyList: updated, format: format, options: 0)
            try out.write(to: indexURL, options: .atomic)
        } catch {
            throw StoreError.fileOperation("Saving the wallpaper settings", error)
        }
        Log.info("Selection: \(assetID) for \([desktop ? "desktop" : nil, idle ? "screen saver" : nil].compactMap { $0 }.joined(separator: " + ")) (\(changed) choices)")
        restartWallpaperAgent()
        return changed
    }

    /// Also ends WallpaperAerialsExtension, which only reads entries.json when it starts.
    func restartWallpaperAgent() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["WallpaperAerialsExtension", "WallpaperAgent"]
        do { try p.run(); p.waitUntilExit() } catch { Log.error("killall WallpaperAgent failed: \(error)") }
    }

    // MARK: - Helpers

    func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
    }

    func xattr(_ url: URL, _ name: String) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let length = getxattr(path, name, nil, 0, 0, 0)
            guard length >= 0 else { return nil }
            var data = Data(count: length)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, 0) }
            return read == length ? data : nil
        }
    }

    func xattrString(_ url: URL, _ name: String) -> String? {
        xattr(url, name).flatMap { String(data: $0, encoding: .utf8) }
    }

    func setXattr(_ url: URL, _ name: String, _ value: Data) throws {
        let result = url.withUnsafeFileSystemRepresentation { path in
            value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, 0) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func removeXattr(_ url: URL, _ name: String) {
        _ = url.withUnsafeFileSystemRepresentation { removexattr($0, name, 0) }
    }
}
