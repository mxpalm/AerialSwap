import Foundation

/// Minimal append-only logger writing to ~/Library/Logs/AerialSwap.log.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/AerialSwap.log")
    private static let lock = NSLock()

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        let line = "\(Date.now.ISO8601Format()) [\(level)] \(message)\n"
        lock.withLock {
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
