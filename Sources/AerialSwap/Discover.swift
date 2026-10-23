import CryptoKit
import Foundation

/// One video from Pixabay's video search. Only the fields AerialSwap shows or downloads.
struct DiscoverVideo: Codable, Identifiable, Hashable, Sendable {
    struct File: Codable, Hashable, Sendable {
        var url: String
        var width: Int
        var height: Int
        var size: Int64
        var thumbnail: String?
    }

    struct Files: Codable, Hashable, Sendable {
        var large: File?        // usually 3840x2160; Pixabay sends an empty url when there is no 4K version
        var medium: File        // 1920x1080 on older videos, 2560 px on newer ones
        var small: File
        var tiny: File
    }

    var id: Int
    var pageURL: String
    var tags: String
    var duration: Double
    var videos: Files
    var user: String

    /// What gets downloaded: 4K when Pixabay has it, otherwise 1080p.
    var download: File { videos.large.flatMap { $0.url.isEmpty ? nil : $0 } ?? videos.medium }
    var is4K: Bool { download.width >= 3840 }
    /// The full-window preview streams the smallest file that still looks sharp behind the scrim (at least 1280 px wide):
    /// on newer videos "tiny" is already 1280 px (~15 MB), while "medium" can be 2560 px and 80+ MB.
    var previewURL: URL? {
        URL(string: ([videos.tiny, videos.small, videos.medium].first { $0.width >= 1280 } ?? videos.medium).url)
    }
    var thumbnailURL: URL? { URL(string: videos.medium.thumbnail ?? videos.small.thumbnail ?? "") }
    var largeThumbnailURL: URL? { URL(string: download.thumbnail ?? videos.medium.thumbnail ?? "") }
    var page: URL? { URL(string: pageURL) }

    /// "Mountain, Lake, Sunrise" from Pixabay's comma-separated tags.
    var title: String {
        let words = tags.split(separator: ",").prefix(3).map { $0.trimmingCharacters(in: .whitespaces).capitalized }
        return words.isEmpty ? "Pixabay video \(id)" : words.joined(separator: ", ")
    }

    var credit: String { "\(user) on Pixabay" }
}

/// A row of the topic picker: a curated search that tends to give calm, wallpaper-like footage.
struct DiscoverTopic: Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var query: String
    var editorsChoice = false

    static let all: [DiscoverTopic] = [
        DiscoverTopic(id: "featured", title: "Featured", query: "landscape", editorsChoice: true),
        DiscoverTopic(id: "aerial", title: "From Above", query: "aerial drone"),
        DiscoverTopic(id: "mountains", title: "Mountains", query: "mountains"),
        DiscoverTopic(id: "ocean", title: "Ocean", query: "ocean waves"),
        DiscoverTopic(id: "sky", title: "Sky", query: "clouds timelapse"),
        DiscoverTopic(id: "space", title: "Space", query: "earth space"),
        DiscoverTopic(id: "cities", title: "Cities", query: "city night"),
        DiscoverTopic(id: "forest", title: "Forest", query: "forest"),
    ]
}

enum DiscoverError: LocalizedError {
    case noKey
    case badKey
    case rateLimited
    case http(Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noKey: "Discover needs a Pixabay API key. See the README (Discover) for where to put it."
        case .badKey: "Pixabay didn't accept the API key."
        case .rateLimited: "Pixabay is busy right now. Try again in a minute."
        case .http(let code): "Pixabay answered with an error (HTTP \(code)). Try again later."
        case .cancelled: "Download cancelled."
        }
    }
}

/// Pixabay's video search (https://pixabay.com/api/docs/). Pixabay asks that results are cached for 24 hours,
/// so every response is kept in ~/Library/Caches/AerialSwap/discover and reused until it is a day old.
/// When Pixabay can't be reached, older cached results are shown instead of an error.
struct PixabayClient: Sendable {
    static let homepage = URL(string: "https://pixabay.com/")!
    static let license = URL(string: "https://pixabay.com/service/license-summary/")!
    static let cacheLifetime: TimeInterval = 24 * 3600
    static let pageSize = 30

    struct Page: Codable, Sendable {
        var totalHits: Int
        var hits: [DiscoverVideo]
    }

    let key: String?
    let cacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Caches/AerialSwap/discover")

    /// The key comes from (first match): `defaults write local.aerialswap PixabayKey <key>`, the PIXABAY_KEY
    /// environment variable, or pixabay.key in the app bundle (build.sh copies Resources/pixabay.key).
    init() {
        let candidates = [
            UserDefaults.standard.string(forKey: "PixabayKey"),
            ProcessInfo.processInfo.environment["PIXABAY_KEY"],
            Bundle.main.url(forResource: "pixabay", withExtension: "key").flatMap { try? String(contentsOf: $0, encoding: .utf8) },
        ]
        key = candidates.lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    var hasKey: Bool { key != nil }

    /// Landscape-friendly real footage, at least 1080p, most popular first.
    func search(_ query: String, editorsChoice: Bool = false, page: Int = 1) async throws -> Page {
        guard let key else { throw DiscoverError.noKey }
        var items = [
            URLQueryItem(name: "q", value: String(query.prefix(100))),
            URLQueryItem(name: "video_type", value: "film"),
            URLQueryItem(name: "min_width", value: "1920"),
            URLQueryItem(name: "safesearch", value: "true"),
            URLQueryItem(name: "order", value: "popular"),
            URLQueryItem(name: "per_page", value: "\(Self.pageSize)"),
            URLQueryItem(name: "page", value: "\(page)"),
        ]
        if editorsChoice { items.append(URLQueryItem(name: "editors_choice", value: "true")) }
        var components = URLComponents(string: "https://pixabay.com/api/videos/")!
        components.queryItems = items
        let cacheFile = cacheDir.appending(path: Self.cacheName(for: components.url!.absoluteString) + ".json")
        components.queryItems = [URLQueryItem(name: "key", value: key)] + items

        if let cached = readCache(cacheFile, maxAge: Self.cacheLifetime) { return cached }
        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: break
            case 429: throw DiscoverError.rateLimited
            case 400 where String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("key"): throw DiscoverError.badKey
            default: throw DiscoverError.http(status)
            }
            let page = try JSONDecoder().decode(Page.self, from: data)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
            return page
        } catch {
            if case DiscoverError.badKey = error { throw error }
            if let stale = readCache(cacheFile, maxAge: .infinity) {
                Log.info("Discover: Pixabay unavailable (\(error.localizedDescription)), showing cached results")
                return stale
            }
            throw error
        }
    }

    private func readCache(_ file: URL, maxAge: TimeInterval) -> Page? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
              Date.now.timeIntervalSince(modified) < maxAge,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Page.self, from: data)
    }

    /// The cache file name: a hash of the request without the key.
    private static func cacheName(for request: String) -> String {
        SHA256.hash(data: Data(request.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Deletes cached responses older than the 24 hours they may be kept for (called on launch).
    func pruneCache() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date.now.timeIntervalSince(modified) > Self.cacheLifetime { try? fm.removeItem(at: file) }
        }
    }
}

/// Downloads one file with progress and returns the address it finally came from (after redirects).
/// Cancel stops the transfer.
final class VideoDownloader: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var cancelled = false

    func cancel() {
        lock.withLock {
            cancelled = true
            task?.cancel()
        }
    }

    @discardableResult
    func run(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL? {
        try? FileManager.default.removeItem(at: destination)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { [weak self] temp, response, error in
                self?.lock.withLock { self?.observation = nil }
                if let error {
                    let cancelled = (error as? URLError)?.code == .cancelled
                    continuation.resume(throwing: cancelled ? DiscoverError.cancelled : error)
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let temp, status == 200 else {
                    continuation.resume(throwing: status == 429 ? DiscoverError.rateLimited : DiscoverError.http(status))
                    return
                }
                // The temp file is deleted when this handler returns, so move it now.
                do {
                    try FileManager.default.moveItem(at: temp, to: destination)
                    continuation.resume(returning: response?.url)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            let started: Bool = lock.withLock {
                guard !cancelled else { return false }
                self.task = task
                observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
                return true
            }
            if started { task.resume() } else { continuation.resume(throwing: DiscoverError.cancelled) }
        }
    }
}
