import Foundation

/// Optional: yt-dlp (https://github.com/yt-dlp/yt-dlp) downloads videos from YouTube, Vimeo and many other sites.
/// Without it, only direct links to video files can be imported.
enum YTDLP {
    /// Downloading only part of a video needs ffmpeg too (yt-dlp uses it to cut the stream).
    static var canDownloadSections: Bool { find() != nil && FFmpeg.find() != nil }

    static func find() -> URL? { Tool.ytdlp.location }
}

enum URLImportError: LocalizedError {
    case notAWebAddress
    case needsYTDLP
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notAWebAddress: "That isn't a web address. Paste a link that starts with https://."
        case .needsYTDLP: "This link is a web page, not a video file. To import videos from pages like YouTube or Vimeo, "
            + "install yt-dlp (brew install yt-dlp) and try again."
        case .failed(let detail): "The video couldn't be downloaded: \(detail)"
        case .cancelled: "Download cancelled."
        }
    }
}

/// One video at a link that holds several (a playlist, board, channel, collection, or a page with several videos),
/// from yt-dlp's list of it. Picking one downloads it from `info` when the list already had everything about it
/// (e.g. Pinterest boards, whose pin links can't be opened again), otherwise through its own link.
struct LinkVideo: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var url: URL
    var duration: Double?
    var width: Int?
    var height: Int?
    var thumbnail: URL?
    var uploader: String?
    var info: Data?            // yt-dlp's full info about the video (for --load-info-json), when the list had it

    static func == (a: LinkVideo, b: LinkVideo) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var isPortrait: Bool { (height ?? 0) > (width ?? 0) }
    /// "4K", "1080p", "720p" by the longer side (so wide 3840×1634 footage is 4K), when yt-dlp knows the size
    /// (playlists often don't list it).
    var resolutionText: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        let long = max(width, height)
        if long >= 3840 { return "4K" }
        return [(2560, "1440p"), (1920, "1080p"), (1280, "720p")].first { long >= $0.0 }?.1 ?? "\(min(width, height))p"
    }
}

/// The videos yt-dlp found at a link, at most `URLImporter.collectionLimit` of them.
struct LinkCollection: Equatable, Sendable {
    let id = UUID()            // two looks at the same link are different collections
    var title: String
    var link: URL
    var videos: [LinkVideo]
    var total: Int             // how many the site lists, when it says; at least `videos.count`

    static func == (a: LinkCollection, b: LinkCollection) -> Bool { a.id == b.id }

    /// From `yt-dlp -J --flat-playlist` output: nil when it's a single video. Entries without a web address are skipped,
    /// and so are repeats.
    static func parse(_ data: Data, link: URL) -> LinkCollection? {
        guard let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              info["_type"] as? String == "playlist" else { return nil }
        var seen = Set<URL>()
        let videos: [LinkVideo] = (info["entries"] as? [[String: Any]] ?? []).compactMap { entry in
            let address = [entry["webpage_url"], entry["url"]].lazy.compactMap { $0 as? String }
                .compactMap(URLImporter.webAddress).first
            guard let url = address, seen.insert(url).inserted else { return nil }
            let title = (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return LinkVideo(id: url.absoluteString,
                             title: title.flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent,
                             url: url,
                             duration: (entry["duration"] as? NSNumber)?.doubleValue,
                             width: (entry["width"] as? NSNumber)?.intValue,
                             height: (entry["height"] as? NSNumber)?.intValue,
                             thumbnail: thumbnail(of: entry),
                             uploader: (entry["uploader"] ?? entry["channel"]) as? String,
                             info: entry["formats"] != nil ? try? JSONSerialization.data(withJSONObject: entry) : nil)
        }
        let title = (info["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? link.host() ?? "Videos"
        let total = max(videos.count, (info["playlist_count"] as? NSNumber)?.intValue ?? 0)
        return LinkCollection(title: title, link: link, videos: videos, total: total)
    }

    /// The smallest listed thumbnail that is still sharp in a tile (at least 320 px wide), else the largest one.
    private static func thumbnail(of entry: [String: Any]) -> URL? {
        let listed = (entry["thumbnails"] as? [[String: Any]] ?? []).compactMap { t -> (url: URL, width: Int)? in
            guard let address = t["url"] as? String, let url = URL(string: address), url.scheme == "https" else { return nil }
            return (url, (t["width"] as? NSNumber)?.intValue ?? 0)
        }
        let sharp = listed.filter { $0.width >= 320 }.min { $0.width < $1.width }
        return sharp?.url ?? listed.max { $0.width < $1.width }?.url
            ?? (entry["thumbnail"] as? String).flatMap(URL.init(string:))
    }
}

/// What a link holds: one video (with yt-dlp's info about it, so the download doesn't look it up again), or several.
enum LinkContents: Sendable {
    case video(info: URL?)
    case collection(LinkCollection)
}

/// Downloads a video from a web address into a folder: direct links to video files with URLSession,
/// web pages (YouTube, Vimeo, …) with yt-dlp. Only the video track is fetched (the wallpaper has no sound),
/// up to 4K; formats macOS can't decode (e.g. VP9) go through the usual ffmpeg conversion afterwards.
final class URLImporter: @unchecked Sendable {
    /// Links with more videos than this show only the first ones.
    static let collectionLimit = 200

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let downloader = VideoDownloader()

    /// A web address from user input, or nil. Adds https:// when the scheme is missing ("youtu.be/…").
    static func webAddress(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), ["http", "https"].contains(url.scheme?.lowercased()),
              let host = url.host(), host.contains(".") else { return nil }
        return url
    }

    /// "90", "1:30", "1:02:03" or "1:30.5" in seconds; nil for anything else.
    static func seconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0, index == 0 || value < 60 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            process?.terminate()
        }
        downloader.cancel()
    }

    /// Looks at a link before anything is downloaded: one video, or several to pick from (a playlist, board, …).
    /// Links to video files, and every link while yt-dlp isn't installed, count as one video. For one video, yt-dlp's
    /// info is kept in `directory`, so `run` can pass it on instead of looking the page up a second time.
    func inspect(_ url: URL, into directory: URL) async throws -> LinkContents {
        guard let ytdlp = YTDLP.find(), await !Self.isVideoFile(url) else { return .video(info: nil) }
        await updateIfOwnCopy(ytdlp)
        let info = directory.appending(path: "url-\(UUID().uuidString).info.json")
        FileManager.default.createFile(atPath: info.path, contents: nil)
        let output = try FileHandle(forWritingTo: info)
        defer { try? output.close() }
        // --flat-playlist lists a playlist's videos without opening each one; --no-playlist keeps a video that's
        // also in a playlist (YouTube's watch?v=…&list=…) a single video.
        let p = Self.process(ytdlp, [
            "-J", "--flat-playlist", "--no-playlist", "--no-warnings",
            "-I", "1:\(Self.collectionLimit)",
            "--", url.absoluteString,   // never read as an option
        ])
        p.standardOutput = output
        let errors = ResultBox()
        let err = Pipe()
        p.standardError = err
        err.fileHandleForReading.readabilityHandler = { handle in
            errors.appendError(String(decoding: handle.availableData, as: UTF8.self))
        }
        defer { err.fileHandleForReading.readabilityHandler = nil }

        Log.info("yt-dlp: looking at \(url.absoluteString)")
        let status: Int32
        do { status = try await execute(p) } catch {
            try? FileManager.default.removeItem(at: info)
            throw error
        }
        guard status == 0, let data = try? Data(contentsOf: info), !data.isEmpty else {
            try? FileManager.default.removeItem(at: info)
            throw URLImportError.failed(Self.explanation(errors.values.2, status: status))
        }
        if let collection = LinkCollection.parse(data, link: url) {
            try? FileManager.default.removeItem(at: info)
            Log.info("yt-dlp: \(collection.videos.count) of \(collection.total) videos at the link")
            return .collection(collection)
        }
        return .video(info: info)
    }

    /// Returns the downloaded file and a name for it (the page title, or the file name).
    /// `section` (seconds; nil = from the start / to the end) downloads only that part, via yt-dlp and ffmpeg.
    /// `info` is what `inspect` kept about the video; it's deleted afterwards.
    /// Progress is only reported for whole downloads: yt-dlp reports a section only when it's done.
    func run(_ url: URL, section: (start: Double?, end: Double?)? = nil, info: URL? = nil, into directory: URL,
             progress: @escaping @Sendable (Double) -> Void) async throws -> (file: URL, title: String) {
        defer { if let info { try? FileManager.default.removeItem(at: info) } }
        if section == nil, await Self.isVideoFile(url) {
            let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
            let destination = directory.appending(path: "url-\(UUID().uuidString).\(ext)")
            do {
                try await downloader.run(url, to: destination, progress: progress)
            } catch DiscoverError.cancelled {
                throw URLImportError.cancelled
            }
            let name = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? "Video"
            return (destination, name)
        }
        guard let ytdlp = YTDLP.find() else { throw URLImportError.needsYTDLP }
        return try await runYTDLP(ytdlp, url: url, section: section, info: info, directory: directory, progress: progress)
    }

    /// A link to a video file: by its extension, or (for links without one) by the server's content type.
    private static func isVideoFile(_ url: URL) async -> Bool {
        if ["mp4", "mov", "m4v", "webm", "mkv"].contains(url.pathExtension.lowercased()) { return true }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") else { return false }
        return type.lowercased().hasPrefix("video/")
    }

    private func runYTDLP(_ ytdlp: URL, url: URL, section: (start: Double?, end: Double?)?, info: URL?, directory: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> (file: URL, title: String) {
        if info == nil { await updateIfOwnCopy(ytdlp) }   // inspect already did
        // Only that part: ffmpeg copies the streams from the nearest keyframe (no re-encode, so it's fast).
        let sectionArguments = section.map { ["--download-sections", "*\($0.start ?? 0)-\($0.end.map { "\($0)" } ?? "inf")"] } ?? []
        // The page as inspect saw it, or the link itself.
        let source = info.map { ["--load-info-json", $0.path] } ?? ["--", url.absoluteString]   // "--": never read as an option
        let p = Self.process(ytdlp, sectionArguments + [
            // One video, also when the link is a playlist (--no-playlist alone still downloads a whole playlist).
            "--no-playlist", "-I", "1", "--no-warnings", "--newline", "--progress",
            // Best video-only stream up to 4K (no audio, so nothing has to be merged), else the best combined one.
            "-f", "bv*[height<=2160]/b[height<=2160]/bv*/b",
            "-o", directory.appending(path: "url-\(UUID().uuidString).%(ext)s").path,
            "--progress-template", "download:PROGRESS %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s",
            "--print", "after_move:FILE %(filepath)s",
            "--print", "after_move:TITLE %(title)s",
        ] + source)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        nonisolated(unsafe) var pending = ""                 // only touched by the stdout handler
        let result = ResultBox()
        out.fileHandleForReading.readabilityHandler = { handle in
            pending += String(decoding: handle.availableData, as: UTF8.self)
            while let newline = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newline])
                pending.removeSubrange(...newline)
                if line.hasPrefix("PROGRESS ") {
                    let numbers = line.split(separator: " ").dropFirst().map { Double($0) }
                    if numbers.count == 3, let done = numbers[0], let total = numbers[1] ?? numbers[2], total > 0 {
                        progress(min(1, done / total))
                    }
                } else if line.hasPrefix("FILE ") {
                    result.set(file: URL(fileURLWithPath: String(line.dropFirst(5))))
                } else if line.hasPrefix("TITLE ") {
                    result.set(title: String(line.dropFirst(6)))
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            result.appendError(String(decoding: handle.availableData, as: UTF8.self))
        }
        defer {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }

        Log.info("yt-dlp \(url.absoluteString)\(info == nil ? "" : " (from its info)")")
        let status = try await execute(p)
        let (file, title, errors) = result.values
        guard status == 0, let file, FileManager.default.fileExists(atPath: file.path) else {
            throw URLImportError.failed(Self.explanation(errors, status: status))
        }
        Log.info("yt-dlp finished: \(file.lastPathComponent)")
        return (file, title ?? file.deletingPathExtension().lastPathComponent)
    }

    /// yt-dlp with AerialSwap's helpers and environment; the caller connects its output.
    private static func process(_ ytdlp: URL, _ arguments: [String]) -> Process {
        let p = Process()
        p.executableURL = ytdlp
        // Helpers from AerialSwap's tools folder aren't on PATH: deno (YouTube's challenges) and ffmpeg (cutting).
        let helperArguments = (Tool.deno.location.map { ["--js-runtimes", "deno:\($0.path)"] } ?? [])
            + (Tool.ffmpeg.location.map { ["--ffmpeg-location", $0.path] } ?? [])
        p.arguments = helperArguments + arguments
        // Homebrew's folders, so yt-dlp finds its helpers (deno for YouTube, ffmpeg) like in a terminal.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(Tool.directory.path):/usr/bin:/bin"
        // The downloaded (static) ffmpeg has no root certificates of its own: use macOS's bundle for https.
        if environment["SSL_CERT_FILE"] == nil { environment["SSL_CERT_FILE"] = "/etc/ssl/cert.pem" }
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        return p
    }

    /// Runs the process until it exits (or `cancel` stops it) and returns its exit code.
    private func execute(_ p: Process) async throws -> Int32 {
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            p.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try lock.withLock {
                    if cancelled { throw URLImportError.cancelled }
                    try p.run()
                    process = p
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        if lock.withLock({ cancelled }) { throw URLImportError.cancelled }
        return status
    }

    /// yt-dlp's own explanation, e.g. "ERROR: [youtube] abc: Video unavailable".
    private static func explanation(_ errors: String, status: Int32) -> String {
        let message = errors.split(separator: "\n").last { $0.hasPrefix("ERROR:") }
            .map { $0.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces) } ?? "yt-dlp exit code \(status)"
        Log.error("yt-dlp failed (\(status)): \(message)")
        return message
    }

    /// The copy in AerialSwap's tools folder has no package manager, so it updates itself once a week
    /// (YouTube changes often and old versions stop working). Homebrew's copy is left to Homebrew.
    private func updateIfOwnCopy(_ ytdlp: URL) async {
        guard ytdlp.deletingLastPathComponent().path == Tool.directory.path else { return }
        let stamp = Tool.directory.appending(path: ".yt-dlp-checked")
        let checked = (try? FileManager.default.attributesOfItem(atPath: stamp.path))?[.modificationDate] as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(checked) > 7 * 86_400 else { return }
        let p = Process()
        p.executableURL = ytdlp
        p.arguments = ["--update"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        Log.info("yt-dlp: checking for an update")
        let status: Int32? = try? await withCheckedThrowingContinuation { continuation in
            p.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { continuation.resume(throwing: error) }
        }
        Log.info("yt-dlp update check finished (\(status.map(String.init) ?? "didn't run"))")
        FileManager.default.createFile(atPath: stamp.path, contents: nil)
    }

    /// What yt-dlp printed, collected from its output handlers.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var file: URL?
        private var title: String?
        private var errors = ""

        func set(file: URL) { lock.withLock { self.file = file } }
        func set(title: String) { lock.withLock { self.title = title } }
        func appendError(_ text: String) { lock.withLock { errors = String((errors + text).suffix(4000)) } }
        var values: (URL?, String?, String) { lock.withLock { (file, title, errors) } }
    }
}
