import CoreImage
import Foundation
import Metal
import SceneEngine
import VideoToolbox

/// What baking a scene made: the loop its video repeats in, and what the renderer had to leave out.
struct SceneBake: Sendable {
    var loop: SceneLoop
    var problems: [String]
}

enum SceneBakeError: LocalizedError {
    case notAScene
    case scene(String)
    case stopped(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notAScene: "This wallpaper isn't a scene."
        case .scene(let message): "The scene can't be turned into a video: \(message)"
        case .stopped(let detail): "AerialSwap's scene renderer stopped (\(detail)). This scene can't be used yet."
        case .cancelled: "Cancelled."
        }
    }
}

/// Turns a Wallpaper Engine scene into an Aerial video: SceneEngine renders one loop period (see SceneLoop.plan) at
/// 3840×2160 and the frames are encoded like Transcoder's output (HEVC Main 10 with temporal layers). The scene draws
/// natively at the output frame rate, so 120 and 240 fps need no interpolation.
enum SceneBaker {
    /// Bakes the scene in `folder` into `destination`, with `properties` changed from the wallpaper's own values.
    /// `progress` gets frames done and the total.
    /// `part` is the part of the scene the user chose to loop; without one the loop is planned (SceneLoop.plan).
    static func bake(folder: URL, destination: URL, fps: Int, properties: [String: SceneJSON] = [:], framing: SceneFraming = .fill,
                     part: (start: Double, length: Double)? = nil, progress: (Int, Int) -> Void) async throws -> SceneBake {
        let document: SceneDocument, files: SceneFiles, loop: SceneLoop, renderer: SceneRenderer
        do {
            let project = try SceneProject(folder: folder)
            guard project.kind == .scene else { throw SceneBakeError.notAScene }
            files = try SceneFiles(folder: folder, entry: project.file)
            document = try SceneDocument(files: files, project: project, overrides: properties)
            if let part {
                // On the 0.1 s grid, so the loop is a whole number of frames.
                loop = try SceneLoop.chosen(start: (part.start * 10).rounded() / 10, period: max(1, (part.length * 10).rounded() / 10),
                                            document: document, files: files)
            } else {
                loop = try SceneLoop.plan(document: document, files: files).loop
            }
            renderer = try SceneRenderer(document: document, files: files, width: Transcoder.width, height: Transcoder.height,
                                         framing: framing)
        } catch let error as SceneError {
            throw SceneBakeError.scene(error.description)
        }
        renderer.loop = loop
        // Periods are on a 0.1 s grid, so this is whole at 30, 60, 120 and 240 fps.
        let frames = max(1, Int((loop.period * Double(fps)).rounded()))
        Log.info("Scene bake \(folder.lastPathComponent): \(loop.period)s loop, crossfade \(loop.crossfade)s @\(fps)fps")

        let converter = try CIFrameRenderer()
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        // Core Image puts a texture's first row at the bottom; the renderer's first row is the top.
        let flip = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(Transcoder.height))

        try? FileManager.default.removeItem(at: destination)
        let sink = try WriterSink(url: destination)
        // Constant quality, not an average bitrate: on a mostly still picture, rate control starts with soft keyframes and
        // sharpens later ones, so the loop would visibly lose detail where it starts over. 0.75 lands near the 20 Mbps
        // videos get (5–24 Mbps on the scenes tried).
        let encoder = try Transcoder.makeEncoder(fps: fps, sink: sink, quality: 0.75)
        defer { VTCompressionSessionInvalidate(encoder) }
        do {
            for index in 0 ..< frames {
                if let error = sink.error { throw error }
                let texture = try renderer.render(time: Double(index) / Double(fps))
                guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: sRGB]) else {
                    throw SceneBakeError.scene("a frame couldn't be read back")
                }
                // Render waits for Core Image, so the next frame can draw into the same texture.
                let frame = try converter.render(image.transformed(by: flip).settingAlphaOne(in: converter.canvas))
                let status = VTCompressionSessionEncodeFrame(
                    encoder, imageBuffer: frame, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)),
                    duration: CMTime(value: 1, timescale: CMTimeScale(fps)), frameProperties: nil, sourceFrameRefcon: nil,
                    infoFlagsOut: nil)
                guard status == noErr else { throw TranscodeError.encode(status) }
                progress(index + 1, frames)
            }
            let status = VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
            guard status == noErr else { throw TranscodeError.encode(status) }
            try await sink.finish()
        } catch {
            sink.cancel()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        Log.info("Scene bake finished: \(frames) frames -> \(destination.path)")
        return SceneBake(loop: loop, problems: renderer.problems)
    }

    /// `AerialSwap --bake-scene <folder> <out.mov> [--fps 30|60|120|240] [--properties <json>] [--framing <json>] [--loop <start>,<length>]`, run by
    /// SceneBakeProcess. Prints PROGRESS <done> <total>, then LOOP <period> <crossfade> and a PROBLEM line for each
    /// thing left out, or ERROR <message>.
    static func runChild(_ args: [String]) async -> Int32 {
        let usage = "usage: AerialSwap --bake-scene <folder> <out.mov> [--fps 30|60|120|240] [--properties <json>] [--framing <json>] [--loop <start>,<length>]"
        guard args.count >= 3, let options = SceneChildOptions(args.dropFirst(3)) else { print(usage); return 2 }
        let fps = options.fps ?? 60
        guard [30, 60, 120, 240].contains(fps) else { print("ERROR The frame rate must be 30, 60, 120 or 240."); return 2 }
        setvbuf(stdout, nil, _IOLBF, 0)   // a line at a time, also into a pipe
        do {
            var reported = -1
            let bake = try await bake(folder: URL(fileURLWithPath: args[1]), destination: URL(fileURLWithPath: args[2]),
                                      fps: fps, properties: options.properties, framing: options.framing,
                                      part: options.part) { done, total in
                // At most 200 lines, the last one at 100%.
                let step = done * 200 / total
                if step != reported || done == total { print("PROGRESS \(done) \(total)"); reported = step }
            }
            print("LOOP \(bake.loop.period) \(bake.loop.crossfade)")
            for problem in bake.problems { print("PROBLEM \(problem.replacingOccurrences(of: "\n", with: " "))") }
            return 0
        } catch {
            print("ERROR \(error.localizedDescription.replacingOccurrences(of: "\n", with: " "))")
            return 1
        }
    }
}

/// Runs `AerialSwap --bake-scene` in its own process and reports its progress. Scenes bring their own shaders, and a
/// crash while compiling or drawing one then stops only the helper. Cancel stops it.
final class SceneBakeProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.withLock {
            cancelled = true
            process?.terminate()
        }
    }

    func run(folder: URL, destination: URL, fps: Int, properties: [String: SceneJSON] = [:], framing: SceneFraming = .fill,
             part: (start: Double, length: Double)? = nil, progress: @escaping @Sendable (Double) -> Void) async throws -> SceneBake {
        guard let executable = Bundle.main.executableURL else { throw SceneBakeError.stopped("its program wasn't found") }
        let p = Process()
        p.executableURL = executable
        p.arguments = ["--bake-scene", folder.path, destination.path, "--fps", String(fps)]
            + SceneChildOptions.arguments(properties: properties) + SceneChildOptions.arguments(framing: framing)
            + SceneChildOptions.arguments(part: part)
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out

        let lines = Lines()
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { lines.finish(); return }   // end of output
            for line in lines.append(data) where line.hasPrefix("PROGRESS ") {
                let numbers = line.split(separator: " ").dropFirst().compactMap { Double($0) }
                if numbers.count == 2, numbers[1] > 0 { progress(min(1, numbers[0] / numbers[1])) }
            }
        }
        defer { out.fileHandleForReading.readabilityHandler = nil }

        Log.info("Scene bake: \(folder.lastPathComponent) @\(fps)fps")
        let (status, reason): (Int32, Process.TerminationReason) = try await withCheckedThrowingContinuation { continuation in
            p.terminationHandler = { continuation.resume(returning: ($0.terminationStatus, $0.terminationReason)) }
            do {
                try lock.withLock {
                    if cancelled { throw SceneBakeError.cancelled }
                    try p.run()
                    process = p
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        if lock.withLock({ cancelled }) {
            try? FileManager.default.removeItem(at: destination)
            throw SceneBakeError.cancelled
        }
        // The exit can be handled before the last lines are read: wait for the end of the output, at most 2 s.
        Task { try? await Task.sleep(for: .seconds(2)); lines.finish() }
        await lines.ended()

        var loop: SceneLoop?, problems: [String] = [], message: String?
        for line in lines.all {
            if line.hasPrefix("LOOP ") {
                let numbers = line.split(separator: " ").dropFirst().compactMap { Double($0) }
                if numbers.count == 2 { loop = SceneLoop(period: numbers[0], crossfade: numbers[1]) }
            } else if line.hasPrefix("PROBLEM ") {
                problems.append(String(line.dropFirst(8)))
            } else if line.hasPrefix("ERROR ") {
                message = String(line.dropFirst(6))
            }
        }
        guard reason == .exit, status == 0, let loop else {
            try? FileManager.default.removeItem(at: destination)
            if let message { Log.error("Scene bake: \(message)"); throw SceneBakeError.scene(message) }
            let detail = reason == .uncaughtSignal ? "signal \(status)" : "exit code \(status)"
            Log.error("Scene bake: the helper stopped (\(detail))")
            throw SceneBakeError.stopped(detail)
        }
        if !problems.isEmpty { Log.info("Scene bake left out: \(problems.joined(separator: "; "))") }
        return SceneBake(loop: loop, problems: problems)
    }

    /// The helper's output, split into lines as it arrives.
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = ""
        private var lines: [String] = []
        private var finished = false
        private var waiter: CheckedContinuation<Void, Never>?

        /// Adds output and returns the lines it completed.
        func append(_ data: Data) -> [String] {
            lock.withLock {
                pending += String(decoding: data, as: UTF8.self)
                var complete: [String] = []
                while let newline = pending.firstIndex(of: "\n") {
                    complete.append(String(pending[..<newline]))
                    pending.removeSubrange(...newline)
                }
                lines += complete
                return complete
            }
        }

        var all: [String] { lock.withLock { lines } }

        func finish() {
            let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
                finished = true
                defer { self.waiter = nil }
                return self.waiter
            }
            waiter?.resume()
        }

        func ended() async {
            await withCheckedContinuation { continuation in
                let done = lock.withLock {
                    if finished { return true }
                    waiter = continuation
                    return false
                }
                if done { continuation.resume() }
            }
        }
    }
}

/// The options the scene helpers take after their paths: `--fps <n>` and `--properties <json>` (property values that
/// differ from the wallpaper's own, as a JSON object).
struct SceneChildOptions {
    var fps: Int?
    var properties: [String: SceneJSON] = [:]
    var framing = SceneFraming.fill
    /// The part of the scene to loop (start and length in seconds), when the user chose one.
    var part: (start: Double, length: Double)?

    /// nil when an option is unknown or its value unreadable.
    init?(_ args: ArraySlice<String>) {
        var rest = args
        while let option = rest.popFirst() {
            guard let value = rest.popFirst() else { return nil }
            switch option {
            case "--fps":
                guard let n = Int(value) else { return nil }
                fps = n
            case "--properties":
                guard let json = try? SceneJSON(data: Data(value.utf8), name: "properties"), let object = json.object else { return nil }
                properties = object
            case "--loop":
                let numbers = value.split(separator: ",").compactMap { Double($0) }
                guard numbers.count == 2, numbers[0].isFinite, numbers[1].isFinite, numbers[0] >= 0, numbers[0] <= 3600,
                      (1 ... SceneChildOptions.maxPart).contains(numbers[1]) else { return nil }
                part = (numbers[0], numbers[1])
            case "--framing":
                guard let decoded = try? JSONDecoder().decode(SceneFraming.self, from: Data(value.utf8)) else { return nil }
                framing = decoded
            default: return nil
            }
        }
    }

    static func arguments(properties: [String: SceneJSON]) -> [String] {
        guard !properties.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: properties.mapValues(\.foundation), options: [.sortedKeys])
        else { return [] }
        return ["--properties", String(decoding: data, as: UTF8.self)]
    }

    /// The longest part of a scene that can be chosen (seconds).
    static let maxPart = 600.0

    static func arguments(part: (start: Double, length: Double)?) -> [String] {
        guard let part else { return [] }
        return ["--loop", "\(part.start),\(part.length)"]
    }

    static func arguments(framing: SceneFraming) -> [String] {
        guard framing != .fill, let data = try? JSONEncoder().encode(framing) else { return [] }
        return ["--framing", String(decoding: data, as: UTF8.self)]
    }
}
