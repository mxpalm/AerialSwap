import AppKit
import Foundation
import Security

/// Downloads a Wallpaper Engine Workshop item with the user's own Steam for Mac: no Windows, no console, no login in
/// AerialSwap. It asks the running Steam app through Valve's Steamworks library (ISteamUGC::DownloadItem), the way
/// Wallpaper Engine itself does, so Steam needs to be logged in to an account that owns Wallpaper Engine.
///
/// The library is the copy inside the user's Steam (AerialSwap ships none) and is only loaded when it's signed by Valve.
/// It runs in a child process (`AerialSwap --steam-download <id>`) that tells Steam it's Wallpaper Engine (SteamAppId);
/// the app itself never does, and Steam shows "playing Wallpaper Engine" only while the child runs.
enum SteamDownload {
    static let appID = WallpaperEngine.appID
    /// Valve's Developer ID team.
    static let valveTeam = "MXGJJ98X76"
    static let steamBundleID = "com.valvesoftware.steam"
    static let getSteamPage = URL(string: "https://store.steampowered.com/about/")!

    static var steamRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Steam")
    }

    /// Steam for Mac is installed and has set itself up (its runtime lives in Steam.AppBundle). Both are needed: the
    /// runtime stays behind when Steam.app is deleted, and without the app Steam can't be started for a download.
    static var isInstalled: Bool {
        // Test builds only: `defaults write io.github.mxpalm.AerialSwap SimulateNoSteam -bool YES` shows the app as without Steam.
        if Bundle.main.object(forInfoDictionaryKey: "AerialSwapTestBuild") as? Bool == true,
           UserDefaults.standard.bool(forKey: "SimulateNoSteam") { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: steamBundleID) != nil
            && FileManager.default.fileExists(atPath: steamRoot.appending(path: "Steam.AppBundle").path)
    }

    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: steamBundleID).isEmpty }

    /// Starts Steam in the background (hidden, without taking focus), so a download doesn't need the user to open it.
    static func launchIfNeeded() async {
        guard !isRunning, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: steamBundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        Log.info("Steam: starting it for a Workshop download")
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    /// Steam's libsteam_api.dylib: the known place first, else wherever a Steam update moved it. Only Valve-signed copies.
    static func library() -> URL? {
        let bundle = steamRoot.appending(path: "Steam.AppBundle")
        let known = bundle.appending(path: "Steam/Contents/MacOS/Frameworks/Steam Helper.app/Contents/MacOS/libsteam_api.dylib")
        if FileManager.default.fileExists(atPath: known.path), isSignedByValve(known) { return known }
        var candidates: [URL] = []
        if let walker = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil) {
            var seen = 0
            while let url = walker.nextObject() as? URL, seen < 50_000 {
                seen += 1
                if url.lastPathComponent == "libsteam_api.dylib" { candidates.append(url) }
            }
        }
        return candidates.first(where: isSignedByValve)
    }

    /// The file's code signature is valid and from Valve's Developer ID.
    static func isSignedByValve(_ url: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(valveTeam)\"" as CFString
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }

    // MARK: - Keeping it gentle

    /// At most one download every 30 s, 10 an hour and 30 a day: what a person picking wallpapers does, never a bulk
    /// download. Returns why not, or nil when a download may start.
    static func limitReason(now: Date = .now) -> String? {
        let times = recentDownloads(now: now)
        if let last = times.max(), now.timeIntervalSince(last) < 30 {
            return "Wait \(Int(30 - now.timeIntervalSince(last)) + 1) seconds before the next Steam download."
        }
        if times.filter({ now.timeIntervalSince($0) < 3600 }).count >= 10 {
            return "That's 10 Steam downloads this hour. AerialSwap keeps it at that, so Steam sees normal use. Try again later."
        }
        if times.count >= 30 { return "That's 30 Steam downloads today. AerialSwap keeps it at that. Try again tomorrow." }
        return nil
    }

    static func recordDownload(now: Date = .now) {
        UserDefaults.standard.set((recentDownloads(now: now) + [now]).map(\.timeIntervalSince1970), forKey: downloadTimesKey)
    }

    private static let downloadTimesKey = "SteamDownloadTimes"

    /// Download start times of the last 24 hours.
    private static func recentDownloads(now: Date) -> [Date] {
        (UserDefaults.standard.array(forKey: downloadTimesKey) as? [Double] ?? [])
            .map(Date.init(timeIntervalSince1970:))
            .filter { now.timeIntervalSince($0) < 86_400 && $0 <= now }
    }

    /// The Discover proxy can switch Steam downloads off for everyone (`WORKSHOP_DOWNLOADS = "off"`), e.g. if Valve or
    /// Wallpaper Engine's developer object, without an app update. Nothing about the user is sent. When the proxy can't
    /// be reached, downloads stay on.
    static func downloadsAllowed(proxy: URL?) async -> Bool {
        guard let proxy else { return true }
        var request = URLRequest(url: proxy.appending(path: "workshop-status"), timeoutInterval: 5)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let status = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let allowed = status["downloads"] as? Bool else { return true }
        return allowed
    }

    /// A Workshop ID: digits only.
    static func isValidID(_ id: String) -> Bool { !id.isEmpty && id.count <= 20 && id.allSatisfy(\.isASCII) && id.allSatisfy(\.isNumber) }

    // MARK: - Child process

    /// `AerialSwap --steam-download <id>`, started by SteamDownloader with SteamAppId set. Prints one line per event:
    /// "WAITING" while Steam is still starting or logging in, "STARTED" once Steam accepted the download,
    /// "PROGRESS <done> <total>", then "FOLDER <path>" when the item is installed, or "ERROR <message>".
    static func runChild(_ args: [String]) -> Int32 {
        guard args.count == 2, isValidID(args[1]), let id = UInt64(args[1]) else { emit("ERROR usage: --steam-download <id>"); return 2 }
        guard let path = library()?.path else {
            emit("ERROR Steam's Steamworks library wasn't found, or isn't signed by Valve. Update Steam and try again.")
            return 1
        }
        guard let lib = dlopen(path, RTLD_NOW) else { emit("ERROR Steam's library couldn't be loaded."); return 1 }
        func symbol<T>(_ name: String, as type: T.Type) -> T? { dlsym(lib, name).map { unsafeBitCast($0, to: type) } }
        typealias Bool0 = @convention(c) () -> Bool
        typealias Void0 = @convention(c) () -> Void
        guard let isSteamRunning = symbol("SteamAPI_IsSteamRunning", as: Bool0.self),
              let initFlat = symbol("SteamAPI_InitFlat", as: (@convention(c) (UnsafeMutablePointer<CChar>) -> Int32).self),
              let runCallbacks = symbol("SteamAPI_RunCallbacks", as: Void0.self),
              let shutdown = symbol("SteamAPI_Shutdown", as: Void0.self),
              let downloadItem = symbol("SteamAPI_ISteamUGC_DownloadItem",
                                        as: (@convention(c) (OpaquePointer, UInt64, Bool) -> Bool).self),
              let itemState = symbol("SteamAPI_ISteamUGC_GetItemState", as: (@convention(c) (OpaquePointer, UInt64) -> UInt32).self),
              let downloadInfo = symbol("SteamAPI_ISteamUGC_GetItemDownloadInfo",
                                        as: (@convention(c) (OpaquePointer, UInt64, UnsafeMutablePointer<UInt64>,
                                                             UnsafeMutablePointer<UInt64>) -> Bool).self),
              let installInfo = symbol("SteamAPI_ISteamUGC_GetItemInstallInfo",
                                       as: (@convention(c) (OpaquePointer, UInt64, UnsafeMutablePointer<UInt64>,
                                                            UnsafeMutablePointer<CChar>, UInt32, UnsafeMutablePointer<UInt32>) -> Bool).self),
              // The interface's version changes with Steam's SDK (v020, v021, …): the newest one this copy has.
              let ugcAccessor = (14...40).reversed().lazy
                .compactMap({ symbol(String(format: "SteamAPI_SteamUGC_v%03d", $0), as: (@convention(c) () -> OpaquePointer?).self) })
                .first,
              let appsAccessor = (5...20).reversed().lazy
                .compactMap({ symbol(String(format: "SteamAPI_SteamApps_v%03d", $0), as: (@convention(c) () -> OpaquePointer?).self) })
                .first,
              let isSubscribed = symbol("SteamAPI_ISteamApps_BIsSubscribed", as: (@convention(c) (OpaquePointer) -> Bool).self)
        else { emit("ERROR This version of Steam isn't supported yet."); return 1 }

        // Steam may still be starting (SteamDownloader launches it): wait up to 90 s for it.
        var error = [CChar](repeating: 0, count: 1024)
        var started = Date.now
        var waiting = false
        while true {
            if isSteamRunning(), initFlat(&error) == 0 { break }
            if !waiting { emit("WAITING"); waiting = true }
            if Date.now.timeIntervalSince(started) > 90 {
                let detail = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                emit("ERROR Steam isn't running or not logged in\(detail.isEmpty ? "" : " (\(detail))"). Open Steam, log in and try again.")
                return 1
            }
            Thread.sleep(forTimeInterval: 1)
        }
        defer { shutdown() }
        // Nothing is asked of the Workshop for an account that doesn't own Wallpaper Engine.
        guard let apps = appsAccessor(), isSubscribed(apps) else {
            emit("ERROR This Steam account doesn't own Wallpaper Engine, so Steam can't download its wallpapers.")
            return 1
        }
        guard let ugc = ugcAccessor() else { emit("ERROR Steam's Workshop isn't available."); return 1 }
        guard downloadItem(ugc, id, true) else {
            emit("ERROR Steam didn't accept the download. Does this Steam account own Wallpaper Engine?")
            return 1
        }
        emit("STARTED")
        // Item states: installed 4, needs update 8, downloading 16, download pending 32.
        var lastDone: UInt64 = 0
        started = Date.now
        var lastChange = Date.now
        while Date.now.timeIntervalSince(started) < 3600 {
            runCallbacks()
            let state = itemState(ugc, id)
            var done: UInt64 = 0, total: UInt64 = 0
            _ = downloadInfo(ugc, id, &done, &total)
            // Waiting in Steam's queue (e.g. behind a game update) isn't a stall.
            if done != lastDone || state & 32 != 0 { lastDone = done; lastChange = .now }
            emit("PROGRESS \(done) \(total)")
            if state & 4 != 0, state & (8 | 16 | 32) == 0 {
                var size: UInt64 = 0, timestamp: UInt32 = 0
                var folder = [CChar](repeating: 0, count: 4096)
                guard installInfo(ugc, id, &size, &folder, UInt32(folder.count), &timestamp) else {
                    emit("ERROR Steam downloaded the wallpaper but didn't say where to.")
                    return 1
                }
                emit("FOLDER " + String(decoding: folder.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                return 0
            }
            if Date.now.timeIntervalSince(lastChange) > 180 {
                emit("ERROR Steam stopped downloading (nothing new for 3 minutes). Check Steam's Downloads and try again.")
                return 1
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        emit("ERROR The download took longer than an hour.")
        return 1
    }

    private static func emit(_ line: String) {
        print(line)
        fflush(stdout)
    }
}

enum SteamDownloadError: LocalizedError {
    case notInstalled
    case failed(String)
    case notAVideo
    case notForEveryone
    case paused
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notInstalled: "Downloading Workshop wallpapers needs Steam for Mac, logged in to an account that owns Wallpaper Engine."
        case .failed(let message): message
        case .notAVideo: "Steam downloaded it, but it isn't a video wallpaper AerialSwap can use."
        case .notForEveryone: "This wallpaper isn't rated for everyone, so AerialSwap doesn't use it."
        case .paused: "Downloading Workshop wallpapers with Steam is paused for now. Try again in a few days."
        case .cancelled: "Download cancelled."
        }
    }
}

/// Runs `AerialSwap --steam-download <id>` and reports its progress. Cancel stops it (Steam may finish the download).
final class SteamDownloader: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.withLock {
            cancelled = true
            process?.terminate()
        }
    }

    /// The downloaded wallpaper's folder (inside Steam's workshop/content/431960). `started` is called once Steam has
    /// accepted the download (the account owns Wallpaper Engine), so only real downloads count toward the limits.
    func run(id: String, waiting: @escaping @Sendable () -> Void, started: @escaping @Sendable () -> Void,
             progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard SteamDownload.isValidID(id) else { throw SteamDownloadError.failed("That isn't a Workshop item.") }
        guard SteamDownload.isInstalled else { throw SteamDownloadError.notInstalled }
        await SteamDownload.launchIfNeeded()
        guard let executable = Bundle.main.executableURL else { throw SteamDownloadError.failed("AerialSwap's own program wasn't found.") }

        let p = Process()
        p.executableURL = executable
        p.arguments = ["--steam-download", id]
        var environment = ProcessInfo.processInfo.environment
        environment["SteamAppId"] = SteamDownload.appID
        environment["SteamGameId"] = SteamDownload.appID
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out

        nonisolated(unsafe) var pending = ""     // only touched by the stdout handler
        let result = Result()
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { result.finishOutput(); return }   // end of output
            pending += String(decoding: data, as: UTF8.self)
            while let newline = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newline])
                pending.removeSubrange(...newline)
                if line == "WAITING" {
                    waiting()
                } else if line == "STARTED" {
                    started()
                } else if line.hasPrefix("PROGRESS ") {
                    let numbers = line.split(separator: " ").dropFirst().compactMap { Double($0) }
                    if numbers.count == 2, numbers[1] > 0 { progress(min(1, numbers[0] / numbers[1])) }
                } else if line.hasPrefix("FOLDER ") {
                    result.set(folder: String(line.dropFirst(7)))
                } else if line.hasPrefix("ERROR ") {
                    result.set(error: String(line.dropFirst(6)))
                }
            }
        }
        defer { out.fileHandleForReading.readabilityHandler = nil }

        Log.info("Steam: downloading Workshop item \(id)")
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            p.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try lock.withLock {
                    if cancelled { throw SteamDownloadError.cancelled }
                    try p.run()
                    process = p
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        if lock.withLock({ cancelled }) { throw SteamDownloadError.cancelled }
        // The exit can be handled before the last lines (FOLDER) are read: wait for the end of the output, at most 2 s.
        Task { try? await Task.sleep(for: .seconds(2)); result.finishOutput() }
        await result.outputEnded()
        let (folder, error) = result.values
        guard status == 0, let folder else {
            let message = error ?? "Steam's download helper stopped (exit code \(status))."
            Log.error("Steam: \(message)")
            throw SteamDownloadError.failed(message)
        }
        // Only a folder for this item in a Wallpaper Engine content folder is accepted.
        let url = URL(fileURLWithPath: folder).standardizedFileURL
        guard url.lastPathComponent == id, url.deletingLastPathComponent().lastPathComponent == SteamDownload.appID else {
            throw SteamDownloadError.failed("Steam put the wallpaper somewhere unexpected.")
        }
        Log.info("Steam: Workshop item \(id) is in \(url.path)")
        return url
    }

    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var folder: String?
        private var error: String?
        func set(folder: String) { lock.withLock { self.folder = folder } }
        func set(error: String) { lock.withLock { self.error = error } }
        var values: (String?, String?) { lock.withLock { (folder, error) } }

        private var outputFinished = false
        private var waiter: CheckedContinuation<Void, Never>?

        func finishOutput() {
            let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
                outputFinished = true
                defer { self.waiter = nil }
                return self.waiter
            }
            waiter?.resume()
        }

        func outputEnded() async {
            await withCheckedContinuation { continuation in
                let finished = lock.withLock {
                    if !outputFinished { waiter = continuation }
                    return outputFinished
                }
                if finished { continuation.resume() }
            }
        }
    }
}
