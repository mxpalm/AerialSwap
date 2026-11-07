import Foundation

/// A `scene.pkg`: a `PKGV00NN` magic, a table of (path, offset, size) entries, then the files' bytes. Offsets count
/// from the end of the table.
public struct ScenePackage: Sendable {
    public let version: String
    private let data: Data
    private let entries: [String: Range<Int>]

    public init(data: Data) throws {
        var reader = BinaryReader(data, name: "scene.pkg")
        version = try reader.lengthPrefixedString(max: 32)
        guard version.hasPrefix("PKGV") else { throw SceneError.malformed("scene.pkg") }
        let count = try reader.count(in: 0 ... SceneLimits.maxPackageEntries, "entry count")
        var table: [(String, Int, Int)] = []
        table.reserveCapacity(count)
        for _ in 0 ..< count {
            let path = try reader.lengthPrefixedString()
            let offset = Int(try reader.uint32()), size = Int(try reader.uint32())
            table.append((path, offset, size))
        }
        let base = reader.offset
        var entries: [String: Range<Int>] = [:]
        for (path, offset, size) in table {
            let start = base + offset
            guard size <= SceneLimits.maxFileBytes, start + size <= data.count else { throw SceneError.malformed("scene.pkg") }
            entries[SceneFiles.normalized(path)] = start ..< start + size
        }
        self.data = data
        self.entries = entries
    }

    public var paths: [String] { entries.keys.sorted() }

    public func file(_ path: String) -> Data? {
        entries[SceneFiles.normalized(path)].map { data.subdata(in: data.startIndex + $0.lowerBound ..< data.startIndex + $0.upperBound) }
    }
}

/// Finds a scene's files the way Wallpaper Engine resolves them: the wallpaper's package first, then its folder, then
/// the shared core every scene relies on (AerialSwap's own versions of the base shaders and utility files, `CoreFiles`).
/// Paths never leave the wallpaper's folder.
public struct SceneFiles: Sendable {
    public let folder: URL
    public let package: ScenePackage?
    private let core: [String: String]

    /// `entry` is the project's entry file: its package is named after it (`scene.json` → `scene.pkg`,
    /// `gifscene.json` → `gifscene.pkg`).
    public init(folder: URL, entry: String = "scene.json", core: [String: String] = CoreFiles.all) throws {
        self.folder = folder.standardizedFileURL
        let name = ((entry as NSString).lastPathComponent as NSString).deletingPathExtension + ".pkg"
        let pkg = [name, "scene.pkg"].map { folder.appending(path: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
        package = try pkg.map { try ScenePackage(data: try Self.read($0, name: $0.lastPathComponent)) }
        self.core = core
    }

    /// Forward slashes, no leading `./` or `/`, no empty parts: the form package tables use.
    static func normalized(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").filter { $0 != "." && !$0.isEmpty }
            .joined(separator: "/")
    }

    public func data(_ path: String) -> Data? {
        let path = Self.normalized(path)
        if let file = package?.file(path) { return file }
        if let url = contained(path), let file = try? Self.read(url, name: path) { return file }
        return core[path].map { Data($0.utf8) }
    }

    public func exists(_ path: String) -> Bool { data(path) != nil }

    /// Whether `path` comes from AerialSwap's own core instead of the wallpaper.
    public func isCore(_ path: String) -> Bool {
        let path = Self.normalized(path)
        let inFolder = contained(path).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return package?.file(path) == nil && !inFolder && core[path] != nil
    }

    public func json(_ path: String) throws -> SceneJSON {
        guard let data = data(path) else { throw SceneError.missing(path) }
        return try SceneJSON(data: data, name: path)
    }

    /// A text file with `\r\n` turned into `\n`.
    public func text(_ path: String) -> String? {
        data(path).flatMap { String(data: $0, encoding: .utf8) }?.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// The file inside the wallpaper's folder, or nil when the path would lead out of it (`..`, symlinks).
    public func contained(_ path: String) -> URL? {
        guard !path.split(separator: "/").contains("..") else { return nil }
        let url = folder.appending(path: path).resolvingSymlinksInPath().standardizedFileURL
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        return url.path.hasPrefix(root + "/") ? url : nil
    }

    static func read(_ url: URL, name: String) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= SceneLimits.maxFileBytes else { throw SceneError.tooLarge(name) }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw SceneError.missing(name)
        }
    }
}
