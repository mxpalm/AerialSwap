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

/// Downloads a video from a web address into a folder: direct links to video files with URLSession,
/// web pages (YouTube, Vimeo, …) with yt-dlp. Only the video track is fetched (the wallpaper has no sound),
/// up to 4K; formats macOS can't decode (e.g. VP9) go through the usual ffmpeg conversion afterwards.
final class URLImporter: @unchecked Sendable {
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

    /// Returns the downloaded file and a name for it (the page title, or the file name).
    /// `section` (seconds; nil = from the start / to the end) downloads only that part, via yt-dlp and ffmpeg.
    /// Progress is only reported for whole downloads: yt-dlp reports a section only when it's done.
    func run(_ url: URL, section: (start: Double?, end: Double?)? = nil, into directory: URL,
             progress: @escaping @Sendable (Double) -> Void) async throws -> (file: URL, title: String) {
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
        return try await runYTDLP(ytdlp, url: url, section: section, directory: directory, progress: progress)
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

    private func runYTDLP(_ ytdlp: URL, url: URL, section: (start: Double?, end: Double?)?, directory: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> (file: URL, title: String) {
        await updateIfOwnCopy(ytdlp)
        let p = Process()
        p.executableURL = ytdlp
        // Only that part: ffmpeg copies the streams from the nearest keyframe (no re-encode, so it's fast).
        let sectionArguments = section.map { ["--download-sections", "*\($0.start ?? 0)-\($0.end.map { "\($0)" } ?? "inf")"] } ?? []
        // Helpers from AerialSwap's tools folder aren't on PATH: deno (YouTube's challenges) and ffmpeg (cutting).
        let helperArguments = (Tool.deno.location.map { ["--js-runtimes", "deno:\($0.path)"] } ?? [])
            + (Tool.ffmpeg.location.map { ["--ffmpeg-location", $0.path] } ?? [])
        p.arguments = sectionArguments + helperArguments + [
            "--no-playlist", "--no-warnings", "--newline", "--progress",
            // Best video-only stream up to 4K (no audio, so nothing has to be merged), else the best combined one.
            "-f", "bv*[height<=2160]/b[height<=2160]/bv*/b",
            "-o", directory.appending(path: "url-\(UUID().uuidString).%(ext)s").path,
            "--progress-template", "download:PROGRESS %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s",
            "--print", "after_move:FILE %(filepath)s",
            "--print", "after_move:TITLE %(title)s",
            "--", url.absoluteString,   // never read as an option
        ]
        // Homebrew's folders, so yt-dlp finds its helpers (deno for YouTube, ffmpeg) like in a terminal.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(Tool.directory.path):/usr/bin:/bin"
        // The downloaded (static) ffmpeg has no root certificates of its own: use macOS's bundle for https.
        if environment["SSL_CERT_FILE"] == nil { environment["SSL_CERT_FILE"] = "/etc/ssl/cert.pem" }
        p.environment = environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

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

        Log.info("yt-dlp \(url.absoluteString)")
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
        let (file, title, errors) = result.values
        guard status == 0, let file, FileManager.default.fileExists(atPath: file.path) else {
            // yt-dlp's own explanation, e.g. "ERROR: [youtube] abc: Video unavailable".
            let message = errors.split(separator: "\n").last { $0.hasPrefix("ERROR:") }
                .map { $0.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces) } ?? "yt-dlp exit code \(status)"
            Log.error("yt-dlp failed (\(status)): \(message)")
            throw URLImportError.failed(message)
        }
        Log.info("yt-dlp finished: \(file.lastPathComponent)")
        return (file, title ?? file.deletingPathExtension().lastPathComponent)
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
