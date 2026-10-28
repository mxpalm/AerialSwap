import Foundation

/// A newer release on GitHub.
struct AppUpdate: Equatable, Sendable {
    var version: String
    var page: URL
    /// The release zip and its signature (`<zip>.sig`), when the release has both; Updater installs from them.
    var zip: URL?
    var signature: URL?
}

/// Looks for a newer release of AerialSwap on GitHub (https://github.com/mxpalm/AerialSwap/releases).
/// Updater installs it when the release has a signed zip; otherwise the user downloads it from the release page.
/// Checks at most once a day unless asked; a repo without releases (or a private one) finds nothing.
enum UpdateChecker {
    static let releasesPage = URL(string: "https://github.com/mxpalm/AerialSwap/releases")!
    private static let latestRelease = URL(string: "https://api.github.com/repos/mxpalm/AerialSwap/releases/latest")!
    private static let lastCheckKey = "lastUpdateCheck"

    /// The version build.sh wrote into Info.plist; nil when running the bare binary (swift run, --snapshot).
    static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The newer release, or nil when this is the latest, the check was done in the last 24 hours (unless `force`),
    /// or GitHub couldn't be asked. Throws only for `force`, so a manual check can say what went wrong.
    static func check(force: Bool = false) async throws -> AppUpdate? {
        guard let current = currentVersion else { return nil }
        let defaults = UserDefaults.standard
        if !force, let last = defaults.object(forKey: lastCheckKey) as? Date, Date.now.timeIntervalSince(last) < 86_400 {
            return nil
        }
        do {
            var request = URLRequest(url: latestRelease, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            defaults.set(Date.now, forKey: lastCheckKey)
            if status == 404 { return nil }   // no release published yet
            guard status == 200 else { throw UpdateError.http(status) }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            Log.info("Update check: this is \(current), latest release is \(latest)")
            guard isVersion(latest, newerThan: current) else { return nil }
            // Only ever opens a GitHub page.
            let page = URL(string: release.html_url).flatMap { $0.scheme == "https" && $0.host() == "github.com" ? $0 : nil }
            // The zip and its signature, only from this repository's release downloads.
            func asset(_ name: String) -> URL? {
                release.assets?.first { $0.name == name }.flatMap { URL(string: $0.browser_download_url) }.flatMap {
                    $0.scheme == "https" && $0.host() == "github.com"
                        && $0.path().hasPrefix("/mxpalm/AerialSwap/releases/download/") ? $0 : nil
                }
            }
            let zipName = "AerialSwap-\(latest).zip"
            return AppUpdate(version: latest, page: page ?? releasesPage, zip: asset(zipName), signature: asset(zipName + ".sig"))
        } catch {
            Log.error("Update check failed: \(error.localizedDescription)")
            if force { throw error }
            return nil
        }
    }

    /// Compares dotted versions numerically: "1.10" is newer than "1.9", "1.2" equals "1.2.0".
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// The fields of GitHub's release JSON that are used.
    private struct Release: Decodable {
        var tag_name: String
        var html_url: String
        var assets: [Asset]?
    }

    private struct Asset: Decodable {
        var name: String
        var browser_download_url: String
    }
}

enum UpdateError: LocalizedError {
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .http(let code): "GitHub answered with an error (HTTP \(code)). Try again later."
        }
    }
}
