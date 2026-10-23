import CryptoKit
import Foundation

/// The helper programs AerialSwap can use: yt-dlp (web pages), deno (yt-dlp needs it for YouTube) and ffmpeg
/// (converting formats macOS can't read, downloading part of a video). Each is looked up in Homebrew's folders
/// first, then in AerialSwap's own tools folder, where ToolInstaller puts them on Macs without Homebrew.
enum Tool: String, CaseIterable, Sendable {
    case ytdlp = "yt-dlp", deno, ffmpeg

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/AerialSwap/tools")

    var location: URL? {
        let candidates = ["/opt/homebrew/bin/\(rawValue)", "/usr/local/bin/\(rawValue)"].map { URL(fileURLWithPath: $0) }
            + [Self.directory.appending(path: rawValue)]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var isInstalled: Bool { location != nil }

    /// What the URL import needs: yt-dlp with deno for pages, ffmpeg for parts of videos.
    static var missingForURLImport: [Tool] { allCases.filter { !$0.isInstalled } }
}

enum Homebrew {
    static var location: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

enum ToolInstallError: LocalizedError {
    case failed(String)
    case checksumMismatch(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .failed(let detail): "The helpers couldn't be installed: \(detail)"
        case .checksumMismatch(let file): "The download of \(file) didn't match its published checksum, so it wasn't installed."
        case .cancelled: "Installation cancelled."
        }
    }
}

/// Installs missing helpers: with Homebrew when it's there (it keeps them updated), otherwise by downloading
/// the official yt-dlp and deno builds from GitHub and a signed, notarized ffmpeg build from ffmpeg.martin-riedl.de
/// (there is no official one for macOS). Every download is checked against the SHA-256 its publisher lists.
final class ToolInstaller: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let downloader = VideoDownloader()

    /// One sentence for the confirmation: what gets installed, from where.
    static func plan(for tools: [Tool]) -> String {
        if Homebrew.location != nil {
            let formulas = brewFormulas(for: tools).joined(separator: " ")
            return "Homebrew will install them (brew install \(formulas)). This takes a few minutes the first time."
        }
        var sources: [String] = []
        if tools.contains(.ytdlp) { sources.append("yt-dlp from github.com/yt-dlp") }
        if tools.contains(.deno) { sources.append("deno from github.com/denoland") }
        if tools.contains(.ffmpeg) { sources.append("ffmpeg from ffmpeg.martin-riedl.de (a signed build)") }
        return "AerialSwap will download \(sources.joined(separator: ", ")) into its own folder (about 150 MB) "
            + "and check each file against its published checksum."
    }

    /// Homebrew's yt-dlp depends on deno, so deno is only named when yt-dlp is already there.
    private static func brewFormulas(for tools: [Tool]) -> [String] {
        tools.filter { $0 != .deno || !tools.contains(.ytdlp) }.map(\.rawValue)
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            process?.terminate()
        }
        downloader.cancel()
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// `status` gets a short line about the current step, and a fraction when it's known.
    func install(_ tools: [Tool], status: @escaping @Sendable (String, Double?) -> Void) async throws {
        if let brew = Homebrew.location {
            try await brewInstall(brew, formulas: Self.brewFormulas(for: tools), status: status)
            return
        }
        try FileManager.default.createDirectory(at: Tool.directory, withIntermediateDirectories: true)
        for tool in tools {
            if isCancelled { throw ToolInstallError.cancelled }
            try await download(tool, status: status)
        }
    }

    // MARK: Homebrew

    private func brewInstall(_ brew: URL, formulas: [String],
                             status: @escaping @Sendable (String, Double?) -> Void) async throws {
        let p = Process()
        p.executableURL = brew
        p.arguments = ["install"] + formulas
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(brew.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
        environment["NONINTERACTIVE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        p.environment = environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        let tail = Tail()
        // "==> Pouring ffmpeg--9.0.2.arm64_tahoe.bottle.tar.gz" -> "Installing ffmpeg"; other "==>" lines are skipped.
        let verbs = ["Fetching": "Downloading", "Downloading": "Downloading", "Pouring": "Installing",
                     "Installing": "Installing", "Upgrading": "Updating"]
        out.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            tail.append(text)
            for line in text.split(separator: "\n") where line.hasPrefix("==> ") {
                let words = line.dropFirst(4).split(separator: " ")
                guard words.count >= 2, let verb = verbs[String(words[0])], !["dependencies", "downloads"].contains(words[1]) else { continue }
                let name = words[1].components(separatedBy: "--")[0]
                guard !name.hasSuffix(":") else { continue }
                status("\(verb) \(name)", nil)
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            tail.append(String(decoding: handle.availableData, as: UTF8.self))
        }
        defer {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }

        Log.info("brew install \(formulas.joined(separator: " "))")
        status("Starting Homebrew", nil)
        let code = try await run(p)
        if isCancelled { throw ToolInstallError.cancelled }
        guard code == 0 else {
            let message = tail.lastLine(prefix: "Error:") ?? "brew exit code \(code)"
            Log.error("brew install failed (\(code)): \(message)")
            throw ToolInstallError.failed(message)
        }
        Log.info("brew install finished")
    }

    // MARK: Direct downloads

    private func download(_ tool: Tool, status: @escaping @Sendable (String, Double?) -> Void) async throws {
        let work = FileManager.default.temporaryDirectory.appending(path: "AerialSwap-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let destination = Tool.directory.appending(path: tool.rawValue)
        status("Downloading \(tool.rawValue)", 0)
        let report: @Sendable (Double) -> Void = { status("Downloading \(tool.rawValue)", $0) }

        switch tool {
        case .ytdlp:
            // The official macOS build; it updates itself (see URLImporter).
            let file = work.appending(path: "yt-dlp_macos")
            try await fetch("https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos", to: file, progress: report)
            let sums = try await text("https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS")
            try verify(file, expected: Self.checksum(in: sums, for: "yt-dlp_macos"), name: "yt-dlp")
            try place(file, at: destination)
        case .deno:
            let arch = Self.isAppleSilicon ? "aarch64" : "x86_64"
            let base = "https://github.com/denoland/deno/releases/latest/download/deno-\(arch)-apple-darwin.zip"
            let zip = work.appending(path: "deno.zip")
            try await fetch(base, to: zip, progress: report)
            try verify(zip, expected: Self.checksum(in: try await text(base + ".sha256sum"), for: nil), name: "deno")
            try place(try await unzip(zip, file: "deno", in: work), at: destination)
        case .ffmpeg:
            let arch = Self.isAppleSilicon ? "arm64" : "amd64"
            let zip = work.appending(path: "ffmpeg.zip")
            // The "latest" link redirects to the versioned file; its checksum sits next to it.
            let final = try await fetch("https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(arch)/release/ffmpeg.zip",
                                        to: zip, progress: report)
            let sum = try await text(final.absoluteString + ".sha256")
            try verify(zip, expected: Self.checksum(in: sum, for: nil), name: "ffmpeg")
            try place(try await unzip(zip, file: "ffmpeg", in: work), at: destination)
        }
        Log.info("Installed \(tool.rawValue) into \(destination.path)")
    }

    private static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    /// Downloads a file and returns the URL it finally came from (after redirects).
    @discardableResult
    private func fetch(_ address: String, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let url = URL(string: address) else { throw ToolInstallError.failed("bad address \(address)") }
        do {
            return try await downloader.run(url, to: file, progress: progress) ?? url
        } catch DiscoverError.cancelled {
            throw ToolInstallError.cancelled
        }
    }

    private func text(_ address: String) async throws -> String {
        guard let url = URL(string: address) else { throw ToolInstallError.failed("bad address \(address)") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ToolInstallError.failed("couldn't load \(url.lastPathComponent) (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The hash from a "<sha256>  <file name>" list, for `name` (or the first entry when nil).
    private static func checksum(in list: String, for name: String?) -> String? {
        for line in list.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let hash = parts.first, hash.count == 64 else { continue }
            if name == nil || parts.last.map({ String($0).trimmingCharacters(in: CharacterSet(charactersIn: "*")) }) == name {
                return hash.lowercased()
            }
        }
        return nil
    }

    private func verify(_ file: URL, expected: String?, name: String) throws {
        guard let expected else { throw ToolInstallError.failed("no published checksum for \(name)") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            Log.error("Checksum mismatch for \(name): \(actual) != \(expected)")
            throw ToolInstallError.checksumMismatch(name)
        }
    }

    private func unzip(_ zip: URL, file: String, in directory: URL) async throws -> URL {
        let folder = directory.appending(path: "unzipped")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, folder.path]
        guard try await run(p) == 0 else { throw ToolInstallError.failed("couldn't unpack \(zip.lastPathComponent)") }
        let found = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first { $0.lastPathComponent == file }
        guard let found else { throw ToolInstallError.failed("\(file) wasn't in the download") }
        return found
    }

    /// Moves the program into the tools folder (replacing an older copy) and makes it executable.
    private func place(_ file: URL, at destination: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: file, to: destination)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    private func run(_ p: Process) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            p.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try lock.withLock {
                    if cancelled { throw ToolInstallError.cancelled }
                    try p.run()
                    process = p
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// The end of a process's output, for error messages.
    private final class Tail: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func append(_ more: String) { lock.withLock { text = String((text + more).suffix(4000)) } }
        func lastLine(prefix: String) -> String? {
            lock.withLock { text }.split(separator: "\n").last { $0.hasPrefix(prefix) }
                .map { $0.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) }
        }
    }
}
