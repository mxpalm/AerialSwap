import AppKit
import Foundation

/// The "AerialSwap" group in System Settings → Wallpaper: every library wallpaper as an Aerial of its own, next to
/// Apple's.
///
/// WallpaperAerialsExtension reads its categories and assets from aerials/manifest/entries.json. The group is one more
/// category there, with an asset per library item (the asset ID is the library item's ID). Each video (an APFS clone)
/// and thumbnail goes into videos/ and thumbnails/ with the `SourceURL` the manifest names, so the extension treats it
/// as already downloaded. Our URLs start with `urlPrefix`, which is how our entries and files are told apart from Apple's.
///
/// The extension carries a manifest of its own too (Contents/Resources/entries.json) and uses whichever of the two
/// has the higher `version`; on a tie, the downloaded one. So the written manifest gets at least the bundled version.
/// Apple's downloaded manifest is kept in group/apple-entries.json: the group is built on it, and syncing an empty
/// library puts it back unchanged. When macOS downloads a new manifest it replaces entries.json; the LaunchAgent
/// (`GroupWatcher`) runs `--sync-group` then, which adds the group again.
struct AerialGroup: Sendable {
    static let urlPrefix = "https://aerialswap.invalid/"
    static let categoryID = "6F2C7A3E-5B1D-4E8A-9C3F-A1E5D7B9C2F4"
    static let subcategoryID = "8D4E1B6A-2C7F-4A9E-B3D5-F6A8C1E4B7D2"
    static let name = "AerialSwap"
    static let bundledManifestURL = URL(fileURLWithPath:
        "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/Resources/entries.json")

    let store = AerialStore()
    let library = WallpaperLibrary()
    var thumbnailsDir: URL { store.aerialsDir.appending(path: "thumbnails") }
    var appleManifestURL: URL { store.supportDir.appending(path: "group/apple-entries.json") }

    static func isOwn(_ url: String?) -> Bool { url?.hasPrefix(urlPrefix) == true }
    static func videoSource(_ id: String) -> String { "\(urlPrefix)\(id).mov" }
    static func thumbnailSource(_ id: String) -> String { "\(urlPrefix)\(id).png" }

    /// Makes the group match `items`: adds missing videos and thumbnails, rewrites entries.json when it differs, and
    /// deletes our files for items that are gone. Restarts WallpaperAgent when anything changed (unless `restart` is
    /// false). Returns whether anything changed. With no items, Apple's manifest is put back as it was.
    @discardableResult
    func sync(_ items: [LibraryItem], restart: Bool = true) async throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: store.entriesURL.path) else {
            throw StoreError.aerialsFolderMissing(store.entriesURL.deletingLastPathComponent().path)
        }
        let current = try readManifest(store.entriesURL)
        let apple = try appleManifest(current: current)

        // Files first, so the manifest never names a video that isn't there.
        var changed = false
        var published: [LibraryItem] = []
        for item in items where fm.fileExists(atPath: library.videoURL(item).path) {
            do {
                if try placeVideo(of: item) { changed = true }
                if await placeThumbnail(of: item) { changed = true }
                published.append(item)
            } catch {
                Log.error("Group: could not add \(item.name) (\(item.id)): \(error.localizedDescription)")
            }
        }

        if let first = published.first, placeGroupPreview(of: first) { changed = true }

        let desired = published.isEmpty ? apple : manifest(apple, with: published)
        if !NSDictionary(dictionary: current).isEqual(to: desired) {
            try writeManifest(desired)
            changed = true
            Log.info("Group: manifest now lists \(published.count) wallpaper(s)")
        }
        let keep = Set(published.map(\.id) + (published.isEmpty ? [] : [Self.subcategoryID]))
        if removeStaleFiles(keeping: keep) { changed = true }
        if changed && restart { store.restartWallpaperAgent() }
        return changed
    }

    /// Removes the group: Apple's manifest goes back and our videos and thumbnails are deleted.
    func remove() async throws {
        try await sync([])
        try? FileManager.default.removeItem(at: appleManifestURL)
    }

    /// Whether entries.json lists the group right now.
    var isInstalled: Bool {
        guard let manifest = try? readManifest(store.entriesURL) else { return false }
        return Self.containsOwn(manifest)
    }

    // MARK: - Manifest

    /// Apple's manifest: entries.json itself when the group isn't in it (macOS just downloaded it; it's kept), else
    /// the kept copy, or entries.json without our entries when the copy is missing.
    private func appleManifest(current: [String: Any]) throws -> [String: Any] {
        if !Self.containsOwn(current) {
            if (try? readManifest(appleManifestURL)).map({ NSDictionary(dictionary: $0).isEqual(to: current) }) != true {
                try FileManager.default.createDirectory(at: appleManifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]).write(to: appleManifestURL, options: .atomic)
            }
            return current
        }
        if let kept = try? readManifest(appleManifestURL), !Self.containsOwn(kept) { return kept }
        Log.error("Group: no copy of Apple's manifest; using entries.json without the group")
        return Self.withoutOwn(current)
    }

    /// Apple's manifest plus the group, with a version the extension prefers over its bundled manifest.
    private func manifest(_ apple: [String: Any], with items: [LibraryItem]) -> [String: Any] {
        var result = Self.withoutOwn(apple)
        var categories = result["categories"] as? [[String: Any]] ?? []
        var assets = result["assets"] as? [[String: Any]] ?? []
        for (index, item) in items.enumerated() {
            let name = prettyName(item.name)
            assets.append([
                "accessibilityLabel": name, "categories": [Self.categoryID], "id": item.id,
                "includeInShuffle": false, "localizedNameKey": name, "pointsOfInterest": [String: Any](),
                "preferredOrder": index, "previewImage": Self.thumbnailSource(item.id), "shotID": "AERIALSWAP_\(index)",
                "showInTopLevel": true, "subcategories": [Self.subcategoryID], "url-4K-SDR-240FPS": Self.videoSource(item.id),
            ])
        }
        let first = items[0].id
        let order = (categories.compactMap { $0["preferredOrder"] as? Int }.max() ?? -1) + 1
        categories.append([
            "id": Self.categoryID, "localizedNameKey": Self.name,
            "localizedDescriptionKey": "Your own videos, added with AerialSwap.",
            "preferredOrder": order, "previewImage": Self.thumbnailSource(first), "representativeAssetID": first,
            "subcategories": [[
                "id": Self.subcategoryID, "localizedNameKey": Self.name, "localizedDescriptionKey": Self.name,
                "preferredOrder": 0, "previewImage": Self.thumbnailSource(first), "representativeAssetID": first,
            ]],
        ])
        result["categories"] = categories
        result["assets"] = assets
        let bundled = (try? readManifest(Self.bundledManifestURL))?["version"] as? Int ?? 0
        result["version"] = max(apple["version"] as? Int ?? 1, bundled)
        return result
    }

    private static func containsOwn(_ manifest: [String: Any]) -> Bool {
        let categories = manifest["categories"] as? [[String: Any]] ?? []
        let assets = manifest["assets"] as? [[String: Any]] ?? []
        return categories.contains { isOwn($0["previewImage"] as? String) || $0["id"] as? String == categoryID }
            || assets.contains { isOwn($0["url-4K-SDR-240FPS"] as? String) }
    }

    private static func withoutOwn(_ manifest: [String: Any]) -> [String: Any] {
        var result = manifest
        result["categories"] = (manifest["categories"] as? [[String: Any]] ?? [])
            .filter { !isOwn($0["previewImage"] as? String) && $0["id"] as? String != categoryID }
        result["assets"] = (manifest["assets"] as? [[String: Any]] ?? [])
            .filter { !isOwn($0["url-4K-SDR-240FPS"] as? String) }
        return result
    }

    private func readManifest(_ url: URL) throws -> [String: Any] {
        do {
            guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            return json
        } catch {
            throw StoreError.fileOperation("Reading \(url.lastPathComponent)", error)
        }
    }

    /// Writes next to entries.json, keeps its extended attributes, then rename(2)s it into place.
    private func writeManifest(_ manifest: [String: Any]) throws {
        let live = store.entriesURL
        // A unique name: the app and the LaunchAgent's --sync-group may write at the same time.
        let temp = live.deletingLastPathComponent().appending(path: ".entries-\(UUID().uuidString).aerialswap-tmp")
        do {
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: temp)
            for name in AerialStore.trackedXattrs {
                if let value = store.xattr(live, name) { try store.setXattr(temp, name, value) }
            }
            guard rename(temp.path, live.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw StoreError.fileOperation("Saving the Aerials manifest", error)
        }
    }

    // MARK: - Files

    /// Clones the library video into videos/<id>.mov unless it's already there. Returns whether it copied.
    private func placeVideo(of item: LibraryItem) throws -> Bool {
        let source = library.videoURL(item)
        let live = store.videosDir.appending(path: "\(item.id).mov")
        let url = Self.videoSource(item.id)
        if store.xattrString(live, "SourceURL") == url, store.fileSize(live) == store.fileSize(source) { return false }
        try place(source, at: live, sourceURL: url)
        return true
    }

    /// Saves a frame of the video as thumbnails/<id>.png (the tile in System Settings) unless it's already there.
    private func placeThumbnail(of item: LibraryItem) async -> Bool {
        let live = thumbnailsDir.appending(path: "\(item.id).png")
        let url = Self.thumbnailSource(item.id)
        if store.xattrString(live, "SourceURL") == url { return false }
        // Apple's thumbnails are 214x130; twice that for Retina.
        let frame = await WallpaperLibrary.middleFrame(of: library.videoURL(item), maxSize: CGSize(width: 428, height: 260))
        let image = frame ?? NSImage(contentsOf: library.thumbnailURL(item))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            Log.error("Group: no thumbnail for \(item.id)")
            return false
        }
        let temp = store.supportDir.appending(path: ".\(item.id).png")
        do {
            try FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
            try png.write(to: temp)
            try place(temp, at: live, sourceURL: url)
        } catch {
            Log.error("Group: could not save the thumbnail for \(item.id): \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: temp)
        return true
    }

    /// The group's tile in System Settings: the extension keeps a subcategory's preview image as
    /// thumbnails/<subcategory id>.png (it doesn't reuse the asset's), so the first wallpaper's thumbnail is copied there.
    private func placeGroupPreview(of item: LibraryItem) -> Bool {
        let live = thumbnailsDir.appending(path: "\(Self.subcategoryID).png")
        let url = Self.thumbnailSource(item.id)
        let source = thumbnailsDir.appending(path: "\(item.id).png")
        guard store.xattrString(live, "SourceURL") != url, FileManager.default.fileExists(atPath: source.path) else { return false }
        do {
            try place(source, at: live, sourceURL: url)
            return true
        } catch {
            Log.error("Group: could not save the group's preview: \(error.localizedDescription)")
            return false
        }
    }

    /// Copies `source` next to `live`, tags it like a file the extension downloaded, then rename(2)s it into place.
    private func place(_ source: URL, at live: URL, sourceURL: String) throws {
        let fm = FileManager.default
        let temp = live.deletingLastPathComponent().appending(path: ".\(live.lastPathComponent)-\(UUID().uuidString).aerialswap-tmp")
        do {
            try fm.copyItem(at: source, to: temp)   // clones on APFS
            for name in AerialStore.trackedXattrs { store.removeXattr(temp, name) }
            let quarantine = String(format: "0086;%08x;WallpaperAerialsExtension;", Int(Date.now.timeIntervalSince1970))
            try store.setXattr(temp, "SourceURL", Data(sourceURL.utf8))
            try store.setXattr(temp, "LastETag", Data("\"aerialswap-\(store.fileSize(temp))\"".utf8))
            try store.setXattr(temp, "com.apple.quarantine", Data(quarantine.utf8))
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            guard rename(temp.path, live.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? fm.removeItem(at: temp)
            throw StoreError.fileOperation("Adding \(live.lastPathComponent) to the aerials folder", error)
        }
    }

    /// Deletes our videos and thumbnails (tagged with `urlPrefix`) that aren't in `keeping`. Apple's files are never touched.
    private func removeStaleFiles(keeping ids: Set<String>) -> Bool {
        let fm = FileManager.default
        var removed = false
        for dir in [store.videosDir, thumbnailsDir] {
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                guard Self.isOwn(store.xattrString(file, "SourceURL")),
                      !ids.contains(file.deletingPathExtension().lastPathComponent) else { continue }
                do {
                    try fm.removeItem(at: file)
                    removed = true
                    Log.info("Group: removed \(file.lastPathComponent)")
                } catch {
                    Log.error("Group: could not remove \(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return removed
    }
}

/// A LaunchAgent that runs `AerialSwap --sync-group` at login and whenever the Aerials manifest changes, so the group
/// comes back after macOS downloads a new manifest. It is not a background process: launchd starts it, it syncs, it exits.
enum GroupWatcher {
    static let label = "local.aerialswap.group"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")
    }

    /// Installs or updates the agent for this copy of the app (e.g. after it moved to /Applications).
    static func install() {
        guard let executable = Bundle.main.executableURL, Bundle.main.bundleURL.pathExtension == "app" else { return }
        // A downloaded copy opened in place runs from a temporary, read-only path that is gone after quitting.
        guard !isTranslocated else {
            Log.info("Group: running from a translocated copy; the LaunchAgent is installed once AerialSwap is in /Applications")
            return
        }
        let manifest = AerialStore().entriesURL
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "--sync-group"],
            "WatchPaths": [manifest.path, manifest.deletingLastPathComponent().path],
            "RunAtLoad": true,
            "ThrottleInterval": 10,
            "ProcessType": "Background",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        if (try? Data(contentsOf: plistURL)) == data { return }
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            launchctl(["bootout", domain, plistURL.path])
            try data.write(to: plistURL, options: .atomic)
            launchctl(["bootstrap", domain, plistURL.path])
            Log.info("Group: LaunchAgent installed for \(executable.path)")
        } catch {
            Log.error("Group: could not install the LaunchAgent: \(error.localizedDescription)")
        }
    }

    static func uninstall() {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        launchctl(["bootout", domain, plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
        Log.info("Group: LaunchAgent removed")
    }

    /// Gatekeeper's App Translocation (a quarantined app opened where it was downloaded).
    static var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    private static var domain: String { "gui/\(getuid())" }

    private static func launchctl(_ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { Log.error("launchctl \(arguments.first ?? "") failed: \(error)") }
    }
}
