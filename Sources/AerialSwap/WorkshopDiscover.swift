import Foundation

/// A video wallpaper on Wallpaper Engine's Steam Workshop, from a search. Only what Discover shows; the video itself is
/// downloaded by the user's Steam (see SteamDownloader).
struct WorkshopItem: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var previewURL: URL?
    var screenshotURL: URL?   // the creator's first extra screenshot: full size, unlike GIF previews (160-256 px)
    var size: Int64
    var tags: [String]
    var subscriptions: Int
    var creatorID: String? = nil     // the creator's SteamID64
    var creatorName: String? = nil   // their public Steam profile name

    /// "<name> on the Steam Workshop", for the library's credit.
    var credit: String { creatorName.map { "\($0) on the Steam Workshop" } ?? "a Steam Workshop creator" }

    var page: URL? { URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)") }

    /// The preview for a tile: Steam's image server scales JPG previews (often 1-2K px, up to 1 MB) down to 360 px,
    /// ~16x fewer bytes. GIFs come back unchanged (they're 160-256 px already).
    var thumbnailURL: URL? {
        guard let previewURL, var components = URLComponents(url: previewURL, resolvingAgainstBaseURL: false),
              components.query == nil else { return previewURL }
        components.queryItems = [URLQueryItem(name: "imw", value: "360"), URLQueryItem(name: "imh", value: "360"),
                                 URLQueryItem(name: "ima", value: "fit"), URLQueryItem(name: "impolicy", value: "Letterbox"),
                                 URLQueryItem(name: "letterbox", value: "false")]
        return components.url
    }

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

/// A row of the Workshop topic picker: a Workshop tag, a search (for subjects that aren't tags), or the trending list.
struct WorkshopTopic: Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var tag: String?
    var search: String? = nil

    static let all: [WorkshopTopic] = [
        WorkshopTopic(id: "trending", title: "Trending"),
        WorkshopTopic(id: "landscape", title: "Landscape", tag: "Landscape"),
        WorkshopTopic(id: "nature", title: "Nature", tag: "Nature"),
        WorkshopTopic(id: "relaxing", title: "Relaxing", tag: "Relaxing"),
        // Subjects that aren't Workshop tags are searches.
        WorkshopTopic(id: "space", title: "Space", search: "space"),
        WorkshopTopic(id: "city", title: "City", search: "city"),
        WorkshopTopic(id: "rain", title: "Rain", search: "rain"),
        WorkshopTopic(id: "ocean", title: "Ocean", search: "ocean"),
        WorkshopTopic(id: "scifi", title: "Sci-Fi", tag: "Sci-Fi"),
        WorkshopTopic(id: "fantasy", title: "Fantasy", tag: "Fantasy"),
        WorkshopTopic(id: "cyberpunk", title: "Cyberpunk", tag: "Cyberpunk"),
        WorkshopTopic(id: "abstract", title: "Abstract", tag: "Abstract"),
        WorkshopTopic(id: "retro", title: "Retro", tag: "Retro"),
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
    /// What Wallpaper Engine is, and where to buy it.
    static let storePage = URL(string: "https://store.steampowered.com/app/431960/Wallpaper_Engine/")!

    let key: String?
    let proxy: URL?

    init(proxy: URL?) {
        let candidates = [UserDefaults.standard.string(forKey: "SteamKey"), ProcessInfo.processInfo.environment["STEAM_KEY"]]
        key = candidates.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        self.proxy = proxy
    }

    var isAvailable: Bool { key != nil || proxy != nil }

    /// Popular: a search ranks by relevance, a tag topic by votes, Trending by this month's trend. Newest: by date.
    func search(_ text: String, topic: WorkshopTopic, page: Int,
                options: DiscoverOptions = DiscoverOptions()) async throws -> (total: Int, items: [WorkshopItem]) {
        guard isAvailable else { throw WorkshopSearchError.noKey }
        var items = [URLQueryItem(name: "page", value: "\(page)"), URLQueryItem(name: "numperpage", value: "\(Self.pageSize)")]
        let newest = options.sort == .newest
        if let search = text.isEmpty ? topic.search : text {
            items += [URLQueryItem(name: "search_text", value: String(search.prefix(100))),
                      URLQueryItem(name: "query_type", value: newest ? "1" : "12")]
        } else if topic.tag == nil {
            items += newest ? [URLQueryItem(name: "query_type", value: "1")]
                : [URLQueryItem(name: "query_type", value: "3"), URLQueryItem(name: "days", value: "30")]
        } else {
            items.append(URLQueryItem(name: "query_type", value: newest ? "1" : "0"))
        }
        let topicTag = text.isEmpty ? topic.tag : nil
        var components: URLComponents
        if let key {
            // The same request the proxy makes.
            components = URLComponents(string: "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/")!
            let tags = ["Video", "Everyone"] + (topicTag.map { [$0] } ?? []) + (options.only4K ? [Self.tag4K] : [])
            components.queryItems = items + tags.enumerated().map { URLQueryItem(name: "requiredtags[\($0.offset)]", value: $0.element) } + [
                URLQueryItem(name: "appid", value: SteamDownload.appID), URLQueryItem(name: "match_all_tags", value: "1"),
                URLQueryItem(name: "return_tags", value: "1"), URLQueryItem(name: "return_previews", value: "1"),
                URLQueryItem(name: "key", value: key),
            ]
        } else if let proxy, let viaProxy = URLComponents(url: proxy.appending(path: "workshop"), resolvingAgainstBaseURL: false) {
            components = viaProxy
            components.queryItems = items + (topicTag.map { [URLQueryItem(name: "tag", value: $0)] } ?? [])
                + (options.only4K ? [URLQueryItem(name: "resolution", value: "4k")] : [])
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
        var result = Self.parse(data)
        // The proxy adds the creators' names; with a key of one's own they're asked for here.
        if let key, result.items.contains(where: { $0.creatorName == nil && $0.creatorID != nil }) {
            let names = await Self.creatorNames(Set(result.items.compactMap(\.creatorID)), key: key)
            for index in result.items.indices where result.items[index].creatorName == nil {
                result.items[index].creatorName = result.items[index].creatorID.flatMap { names[$0] }
            }
        }
        return result
    }

    static let tag4K = "3840 x 2160"

    /// Public profile names (ISteamUser/GetPlayerSummaries) by SteamID64; empty when Steam doesn't answer.
    private static func creatorNames(_ ids: Set<String>, key: String) async -> [String: String] {
        var components = URLComponents(string: "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/")!
        components.queryItems = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "steamids", value: ids.prefix(100).joined(separator: ","))]
        guard let (data, _) = try? await URLSession.shared.data(from: components.url!),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let players = (root["response"] as? [String: Any])?["players"] as? [[String: Any]] else { return [:] }
        return Dictionary(players.compactMap { player in
            guard let id = player["steamid"] as? String, let name = player["personaname"] as? String else { return nil }
            return (id, name)
        }, uniquingKeysWith: { first, _ in first })
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
            let creator = (d["creator"] as? String).flatMap { SteamDownload.isValidID($0) ? $0 : nil }
            let creatorName = (d["creator_name"] as? String).map(Self.cleanName).flatMap { $0.isEmpty ? nil : $0 }
            // Extra previews: type 0 is a picture, 1 a YouTube video.
            let screenshot = (d["previews"] as? [[String: Any]] ?? []).lazy
                .filter { ($0["preview_type"] as? NSNumber)?.intValue == 0 }
                .compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }
                .first(where: isSteamImage)
            return WorkshopItem(id: id, title: String(title.prefix(120)), previewURL: preview, screenshotURL: screenshot,
                                size: Int64(d["file_size"] as? String ?? "") ?? (d["file_size"] as? NSNumber)?.int64Value ?? 0,
                                tags: tags, subscriptions: (d["subscriptions"] as? NSNumber)?.intValue ?? 0,
                                creatorID: creator, creatorName: creatorName)
        }
        return ((response["total"] as? NSNumber)?.intValue ?? items.count, items)
    }

    /// A profile name as shown: without control characters, at most 64 characters.
    static func cleanName(_ name: String) -> String {
        String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).trimmingCharacters(in: .whitespaces)
            .prefix(64).description
    }

    /// Workshop previews come from Steam's image servers; anything else isn't loaded.
    static func isSteamImage(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return ["steamusercontent.com", "steamstatic.com", "steampowered.com"].contains { host == $0 || host.hasSuffix("." + $0) }
            || host == "steamuserimages-a.akamaihd.net"
    }
}
