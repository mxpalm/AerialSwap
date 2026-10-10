import Foundation

/// Optional fallback for formats macOS can't decode (e.g. WebM/VP9, AV1 on chips without an AV1 decoder).
/// Uses a locally installed ffmpeg; AerialSwap works without it for MP4/MOV with H.264/HEVC.
enum FFmpeg {
    static func find() -> URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

enum ConvertError: LocalizedError {
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .failed(let detail): "ffmpeg could not convert the file: \(detail)"
        case .cancelled: "Conversion cancelled."
        }
    }
}

/// Converts any ffmpeg-readable video into a high-bitrate HEVC 10-bit intermediate (video only,
/// original size and fps) that AVFoundation can read. The normal Transcoder then takes over.
final class FFmpegConverter: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var duration: Double?
    private var stderrTail = ""

    func cancel() {
        lock.withLock {
            cancelled = true
            process?.terminate()
        }
    }

    func run(ffmpeg: URL, source: URL, destination: URL,
             progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: destination)
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = [
            "-hide_banner", "-nostdin", "-y", "-i", source.path,
            "-map", "0:v:0", "-an", "-sn", "-dn",
            // Hardware HEVC at a high bitrate keeps generation loss small before the final encode.
            "-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-pix_fmt", "p010le",
            "-b:v", "80M", "-tag:v", "hvc1",
            "-progress", "pipe:1", "-nostats",
            destination.path,
        ]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        // -progress writes "out_time_us=<n>" lines; the total comes from "Duration:" on stderr.
        out.fileHandleForReading.readabilityHandler = { [self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                guard let micros = Double(line.dropFirst("out_time_us=".count)),
                      let total = lock.withLock({ duration }), total > 0 else { continue }
                progress(min(1, micros / 1_000_000 / total))
            }
        }
        err.fileHandleForReading.readabilityHandler = { [self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            lock.withLock {
                stderrTail = String((stderrTail + text).suffix(4000))
                if duration == nil { duration = Self.parseDuration(stderrTail) }
            }
        }
        defer {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }

        Log.info("ffmpeg convert \(source.path) -> \(destination.path)")
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            p.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try lock.withLock {
                    if cancelled { throw ConvertError.cancelled }
                    try p.run()
                    process = p
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }

        if lock.withLock({ cancelled }) {
            try? FileManager.default.removeItem(at: destination)
            throw ConvertError.cancelled
        }
        guard status == 0 else {
            try? FileManager.default.removeItem(at: destination)
            let lastLine = lock.withLock { stderrTail }
                .split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "exit code \(status)"
            Log.error("ffmpeg failed (\(status)): \(lastLine)")
            throw ConvertError.failed(String(lastLine))
        }
        Log.info("ffmpeg convert finished")
    }

    /// Parses "Duration: HH:MM:SS.xx" from ffmpeg's banner.
    private static func parseDuration(_ text: String) -> Double? {
        guard let range = text.range(of: #"Duration: (\d+):(\d+):(\d+(\.\d+)?)"#, options: .regularExpression) else { return nil }
        let parts = text[range].dropFirst("Duration: ".count).split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}
