import Foundation

/// A video wallpaper on Wallpaper Engine's Steam Workshop, from a search. Only what Discover shows; the video itself is
/// downloaded by the user's Steam (see SteamDownloader).
struct WorkshopItem: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var previewURL: URL?
    var size: Int64
    var tags: [String]
    var subscriptions: Int

    var page: URL? { URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)") }

    /// "4K", "1440p", "1080p" from the creator's resolution tag, when it's one of the usual ones.
    var resolutionText: String? {
        let known = ["3840 x 2160": "4K", "2560 x 1440": "1440p", "1920 x 1080": "1080p", "1280 x 720": "720p"]
        return tags.lazy.compactMap { known[$0] }.first
    }

    /// The creator's genre tags, without the type, rating and resolution ones.
    var genres: [String] {
        let technical: Set<String> = ["Video", "Wallpaper", "Everyone", "Approved", "Other resolution"]
        return tags.filter { !technical.contains($0) && !$0.contains(" x ") }
    }
}

enum WorkshopSearchError: LocalizedError {
    case noKey
    case badKey
    case rateLimited
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .noKey: "Workshop search isn't set up in this build: it needs a Steam Web API key or the Discover proxy."
        case .badKey: "Steam didn't accept the Web API key."
        case .rateLimited: "Steam is busy right now. Try again in a minute."
        case .http(let code): "Steam answered with an error (HTTP \(code)). Try again later."
        }
    }
}

/// A row of the Workshop topic picker: a Workshop tag, or the trending list.
struct WorkshopTopic: Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var tag: String?

    static let all: [WorkshopTopic] = [
        WorkshopTopic(id: "trending", title: "Trending"),
        WorkshopTopic(id: "landscape", title: "Landscape", tag: "Landscape"),
        WorkshopTopic(id: "nature", title: "Nature", tag: "Nature"),
        WorkshopTopic(id: "relaxing", title: "Relaxing", tag: "Relaxing"),
        WorkshopTopic(id: "scifi", title: "Sci-Fi", tag: "Sci-Fi"),
        WorkshopTopic(id: "pixel", title: "Pixel Art", tag: "Pixel art"),
        WorkshopTopic(id: "anime", title: "Anime", tag: "Anime"),
    ]
}

/// Searches Wallpaper Engine's Workshop (Steam's IPublishedFileService/QueryFiles) for video wallpapers rated for
/// everyone: through AerialSwap's Discover proxy (Proxy/), which adds the Steam Web API key, or directly with a key of
/// one's own (`defaults write io.github.mxpalm.AerialSwap SteamKey <key>` or STEAM_KEY).
struct WorkshopClient: Sendable {
    static let pageSize = 30
    static let homepage = URL(string: "https://steamcommunity.com/app/431960/workshop/")!

    let key: String?
    let proxy: URL?

    init(proxy: URL?) {
        let candidates = [UserDefaults.standard.string(forKey: "SteamKey"), ProcessInfo.processInfo.environment["STEAM_KEY"]]
        key = candidates.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        self.proxy = proxy
    }

    var isAvailable: Bool { key != nil || proxy != nil }

    /// A search ranks by relevance; a topic shows its tag's best-rated videos, Trending this month's.
    func search(_ text: String, topic: WorkshopTopic, page: Int) async throws -> (total: Int, items: [WorkshopItem]) {
        guard isAvailable else { throw WorkshopSearchError.noKey }
        var items = [URLQueryItem(name: "page", value: "\(page)"), URLQueryItem(name: "numperpage", value: "\(Self.pageSize)")]
        if !text.isEmpty {
            items += [URLQueryItem(name: "search_text", value: String(text.prefix(100))), URLQueryItem(name: "query_type", value: "12")]
        } else if topic.tag == nil {
            items += [URLQueryItem(name: "query_type", value: "3"), URLQueryItem(name: "days", value: "30")]
        } else {
            items.append(URLQueryItem(name: "query_type", value: "0"))
        }
        var components: URLComponents
        if let key {
            // The same request the proxy makes.
            components = URLComponents(string: "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/")!
            let tags = ["Video", "Everyone"] + (topic.tag.map { [$0] } ?? [])
            components.queryItems = items + tags.enumerated().map { URLQueryItem(name: "requiredtags[\($0.offset)]", value: $0.element) } + [
                URLQueryItem(name: "appid", value: SteamDownload.appID), URLQueryItem(name: "match_all_tags", value: "1"),
                URLQueryItem(name: "return_tags", value: "1"), URLQueryItem(name: "key", value: key),
            ]
        } else if let proxy, let viaProxy = URLComponents(url: proxy.appending(path: "workshop"), resolvingAgainstBaseURL: false) {
            components = viaProxy
            components.queryItems = items + (topic.tag.map { [URLQueryItem(name: "tag", value: $0)] } ?? [])
        } else {
            throw WorkshopSearchError.noKey
        }

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 429: throw WorkshopSearchError.rateLimited
        case let status where key != nil && (status == 401 || status == 403): throw WorkshopSearchError.badKey
        case let status: throw WorkshopSearchError.http(status)
        }
        return Self.parse(data)
    }

    /// QueryFiles' answer: `response.total` and `response.publishedfiledetails`. Items that aren't usable (no title,
    /// deleted, previews from elsewhere than Steam) are left out.
    static func parse(_ data: Data) -> (total: Int, items: [WorkshopItem]) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let response = root["response"] as? [String: Any] else { return (0, []) }
        let details = (response["publishedfiledetails"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let items: [WorkshopItem] = details.compactMap { d in
            guard let id = (d["publishedfileid"] as? String), SteamDownload.isValidID(id),
                  let title = (d["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
            else { return nil }
            let preview = (d["preview_url"] as? String).flatMap(URL.init(string:)).flatMap { isSteamImage($0) ? $0 : nil }
            let tags = (d["tags"] as? [[String: Any]] ?? []).compactMap { $0["tag"] as? String }
            return WorkshopItem(id: id, title: String(title.prefix(120)), previewURL: preview,
                                size: Int64(d["file_size"] as? String ?? "") ?? (d["file_size"] as? NSNumber)?.int64Value ?? 0,
                                tags: tags, subscriptions: (d["subscriptions"] as? NSNumber)?.intValue ?? 0)
        }
        return ((response["total"] as? NSNumber)?.intValue ?? items.count, items)
    }

    /// Workshop previews come from Steam's image servers; anything else isn't loaded.
    static func isSteamImage(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return ["steamusercontent.com", "steamstatic.com", "steampowered.com"].contains { host == $0 || host.hasSuffix("." + $0) }
            || host == "steamuserimages-a.akamaihd.net"
    }
}
