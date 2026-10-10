import AppKit
import AVFoundation

/// A finished wallpaper (already in Aerial format) kept for one-click reuse.
struct LibraryItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String            // the user's original file name
    var addedAt: Date
    var duration: Double
    var bytes: Int64
}

/// Finished wallpapers in ~/Library/Application Support/AerialSwap/library: <id>.mov, <id>.jpg, library.json.
/// Files are cloned (APFS), so keeping them next to the Reinstall copy costs no extra disk space.
struct WallpaperLibrary: Sendable {
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/AerialSwap/library")
    private var indexURL: URL { directory.appending(path: "library.json") }

    var exists: Bool { FileManager.default.fileExists(atPath: indexURL.path) }

    func videoURL(_ item: LibraryItem) -> URL { directory.appending(path: "\(item.id).mov") }
    func thumbnailURL(_ item: LibraryItem) -> URL { directory.appending(path: "\(item.id).jpg") }

    /// Newest first.
    func load() -> [LibraryItem] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([LibraryItem].self, from: data)) ?? []).sorted { $0.addedAt > $1.addedAt }
    }

    /// Clones a finished wallpaper into the library and saves a thumbnail.
    func add(_ file: URL, name: String) async throws -> LibraryItem {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let destination = directory.appending(path: "\(id).mov")
        try fm.copyItem(at: file, to: destination)
        // Apple's tags belong only on the live file in the aerials folder.
        for name in AerialStore.trackedXattrs { _ = destination.withUnsafeFileSystemRepresentation { removexattr($0, name, 0) } }

        let asset = AVURLAsset(url: destination)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let bytes = ((try? fm.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let item = LibraryItem(id: id, name: name, addedAt: .now, duration: duration, bytes: bytes)
        if let frame = await Self.middleFrame(of: destination),
           let jpeg = NSBitmapImageRep(cgImage: frame).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            try? jpeg.write(to: thumbnailURL(item))
        }
        try save(load() + [item])
        Log.info("Library: added \(name) as \(id)")
        return item
    }

    func remove(_ item: LibraryItem) throws {
        try save(load().filter { $0.id != item.id })
        try? FileManager.default.removeItem(at: videoURL(item))
        try? FileManager.default.removeItem(at: thumbnailURL(item))
        Log.info("Library: removed \(item.name) (\(item.id))")
    }

    /// Creates an empty index, so the one-time import of an older install only happens once.
    func createIfMissing() throws {
        if !exists { try save([]) }
    }

    private func save(_ items: [LibraryItem]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(items).write(to: indexURL, options: .atomic)
    }

    /// A frame from the middle of a video, used for thumbnails.
    static func middleFrame(of url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 480, height: 270)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: duration.seconds / 2, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}
