import AppKit
import Foundation
import ImageIO

/// A video wallpaper from the Steam Workshop of Wallpaper Engine, downloaded by the user's own Steam.
/// AerialSwap only reads what Steam already put on disk: no Steam login, no downloads.
struct WorkshopVideo: Identifiable, Hashable, Sendable {
    var id: String               // the item's folder name (its Workshop ID for Steam downloads)
    var title: String
    var video: URL
    var preview: URL?
    var rating: String?          // Wallpaper Engine's content rating when it isn't "Everyone" ("Questionable", "Mature")
    var size: Int64
    var source: String           // "Sevoflurane", "CrossOver · Steam", "Steam", or the added folder's name

    /// The item's Workshop page, when the folder name is a Workshop ID.
    var page: URL? {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")
    }
}

/// What a scan found: the video wallpapers, how many other wallpapers were skipped (scenes, web and application
/// wallpapers can't become videos here) and which Steam folders were looked at.
struct WorkshopScan: Sendable {
    var videos: [WorkshopVideo] = []
    var skipped = 0
    var sources: [String] = []
}

/// Finds Wallpaper Engine downloads: in the Windows Steam of Sevoflurane, CrossOver and Whisky bottles, in Steam for
/// Mac, and in folders the user added. Everything in a download is untrusted (anyone can upload to the Workshop):
/// only project.json is parsed, with size limits, only video files are used, and every path has to stay inside the
/// item's folder. Nothing in a download is ever run.
enum WallpaperEngine {
    static let appID = "431960"
    /// The Workshop filtered to video wallpapers, in the Steam app when one is registered for steam:// links.
    static let workshopWebPage = URL(string: "https://steamcommunity.com/workshop/browse/?appid=\(appID)&requiredtags[]=Video")!
    static let workshopSteamPage = URL(string: "steam://url/SteamWorkshopPage/\(appID)")!
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv"]
    private static let foldersKey = "WorkshopFolders"
    private static let maxProjectFile = 1 << 20          // project.json is a few KB
    private static let maxItemsPerSource = 5_000

    /// Folders the user added with Add Folder… (a Steam folder, its steamapps, or any folder of wallpaper folders).
    static var addedFolders: [URL] {
        get { (UserDefaults.standard.stringArray(forKey: foldersKey) ?? []).map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: foldersKey) }
    }

    static func scan() -> WorkshopScan {
        var scan = WorkshopScan()
        var seen = Set<String>()   // item IDs: the same item can be in two Steam installs or library paths
        for (label, content) in contentFolders() {
            scan.sources.append(label)
            for folder in subdirectories(of: content).prefix(maxItemsPerSource) {
                switch item(at: folder, source: label) {
                case .video(let video):
                    if seen.insert(video.id).inserted { scan.videos.append(video) }
                case .other: scan.skipped += 1
                case .none: break
                }
            }
        }
        scan.videos.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return scan
    }

    /// The video wallpaper in one download folder (e.g. right after Steam downloaded it), or nil when it isn't one.
    static func video(in folder: URL) -> WorkshopVideo? {
        if case .video(let video) = item(at: folder, source: "Steam") { return video }
        return nil
    }

    /// The item's video when Steam has already downloaded it (in any library found), so it isn't asked again.
    static func downloadedVideo(id: String) -> WorkshopVideo? {
        guard SteamDownload.isValidID(id) else { return nil }
        return contentFolders().lazy.compactMap { video(in: $0.1.appending(path: id)) }.first
    }

    /// A small preview image, decoded as a thumbnail so a huge or malformed picture can't use much memory.
    static func thumbnail(_ url: URL, maxPixels: Int = 480) -> NSImage? {
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 < 50 << 20 }) == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    // MARK: - Steam folders

    /// Every `workshop/content/431960` folder that exists, with a label for where it is.
    /// The IDs of all items Steam downloaded, in every source (folder names only, no project.json read): for the
    /// "In Steam" badge in Discover.
    static func downloadedIDs() -> Set<String> {
        Set(contentFolders().flatMap { subdirectories(of: $0.1).prefix(maxItemsPerSource).map(\.lastPathComponent) })
    }

    private static func contentFolders() -> [(String, URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var found: [(String, URL)] = []
        func add(_ label: String, _ content: URL) {
            let resolved = content.resolvingSymlinksInPath().path
            guard isDirectory(content), !found.contains(where: { $0.1.resolvingSymlinksInPath().path == resolved }) else { return }
            found.append((label, content))
        }
        let bottleRoots = [("Sevoflurane", home.appending(path: "Library/Application Support/Sevoflurane/Bottles")),
                           ("CrossOver", home.appending(path: "Library/Application Support/CrossOver/Bottles")),
                           ("Whisky", home.appending(path: "Library/Containers/com.isaacmarovitz.Whisky/Bottles"))]
        for (name, root) in bottleRoots {
            for bottle in subdirectories(of: root) {
                for program in ["drive_c/Program Files (x86)/Steam", "drive_c/Program Files/Steam"] {
                    let steam = bottle.appending(path: program)
                    guard isDirectory(steam.appending(path: "steamapps")) else { continue }
                    for library in libraries(steam: steam, bottle: bottle) {
                        add("\(name) · \(bottle.lastPathComponent)", library.appending(path: "steamapps/workshop/content/\(appID)"))
                    }
                }
            }
        }
        let macSteam = home.appending(path: "Library/Application Support/Steam")
        for library in libraries(steam: macSteam, bottle: nil) {
            add("Steam", library.appending(path: "steamapps/workshop/content/\(appID)"))
        }
        for folder in addedFolders {
            let candidates = ["steamapps/workshop/content/\(appID)", "workshop/content/\(appID)", "content/\(appID)", appID]
                .map { folder.appending(path: $0) }
            add(folder.lastPathComponent, candidates.first(where: isDirectory) ?? folder)
        }
        return found
    }

    /// The Steam folder and the other libraries its libraryfolders.vdf lists. Windows paths in a bottle ("D:\\Games")
    /// go through the bottle's dosdevices drive links.
    private static func libraries(steam: URL, bottle: URL?) -> [URL] {
        guard isDirectory(steam) else { return [] }
        var roots = [steam]
        let vdf = steam.appending(path: "steamapps/libraryfolders.vdf")
        guard (try? vdf.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 < maxProjectFile }) == true,
              let text = try? String(contentsOf: vdf, encoding: .utf8) else { return roots }
        for match in text.matches(of: /"path"\s+"([^"]{1,1024})"/) {
            let raw = String(match.output.1).replacingOccurrences(of: "\\\\", with: "\\")
            var url: URL?
            if let bottle, raw.count >= 2, raw.dropFirst().first == ":" {
                let drive = raw.prefix(1).lowercased()
                let rest = raw.dropFirst(2).replacingOccurrences(of: "\\", with: "/").drop { $0 == "/" }
                let device = bottle.appending(path: "dosdevices/\(drive):").resolvingSymlinksInPath()
                let base = isDirectory(device) ? device : (drive == "c" ? bottle.appending(path: "drive_c") : nil)
                url = base?.appending(path: String(rest))
            } else if bottle == nil, raw.hasPrefix("/") {
                url = URL(fileURLWithPath: raw)
            }
            if let url, isDirectory(url), !roots.contains(where: { $0.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) {
                roots.append(url)
            }
        }
        return roots
    }

    // MARK: - Items

    private enum Item { case video(WorkshopVideo), other }

    /// Reads one download's project.json. nil when it isn't a wallpaper (no or unreadable project.json).
    private static func item(at folder: URL, source: String) -> Item? {
        let projectFile = folder.appending(path: "project.json")
        guard (try? projectFile.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 <= maxProjectFile }) == true,
              let data = try? Data(contentsOf: projectFile),
              let project = try? JSONDecoder().decode(Project.self, from: data) else { return nil }
        guard project.type?.lowercased() == "video", let file = project.file,
              let video = contained(file, in: folder), videoExtensions.contains(video.pathExtension.lowercased()),
              let values = try? video.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true
        else { return .other }
        let title = clean(project.title) ?? folder.lastPathComponent
        let rating = clean(project.contentrating).flatMap { $0.lowercased() == "everyone" ? nil : $0 }
        return .video(WorkshopVideo(id: folder.lastPathComponent, title: title, video: video,
                                    preview: project.preview.flatMap { contained($0, in: folder) },
                                    rating: rating, size: Int64(values.fileSize ?? 0), source: source))
    }

    /// `relative` inside `folder`, or nil when it would lead outside it (absolute paths, "..", symlinks out).
    static func contained(_ relative: String, in folder: URL) -> URL? {
        guard !relative.isEmpty, relative.count < 512, !relative.hasPrefix("/"), !relative.contains("\0") else { return nil }
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let target = folder.appending(path: relative).resolvingSymlinksInPath().standardizedFileURL
        return target.path.hasPrefix(base + "/") ? target : nil
    }

    /// Text from project.json for display: no control characters, trimmed, at most 120 characters.
    private static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let printable = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return printable.isEmpty ? nil : String(printable.prefix(120))
    }

    /// The fields of Wallpaper Engine's project.json that are used.
    private struct Project: Decodable {
        var title: String?
        var type: String?
        var file: String?
        var preview: String?
        var contentrating: String?
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func subdirectories(of url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
