import AppKit
import CoreImage
import Foundation
import SceneEngine

/// The live preview of a scene in Configure: `AerialSwap --preview-scene` renders it small and in real time in its own
/// process (scenes bring their own shaders and scripts, see SceneBakeProcess) and sends JPEG frames through a pipe.
/// Frames show the whole canvas in its own shape; Configure frames them as the screen will.
enum ScenePreview {
    /// Frames cover 1920×1080, sharp on a Retina preview even where a wide scene is cut, with their longer side at most
    /// 2560 pixels. The size costs little: the layers' own buffers, drawn at the scene's size, are most of the work.
    static let cover = SIMD2(1920.0, 1080.0)
    static let maxSide = 2560.0
    static let fps = 30.0

    /// What goes through the pipe: a type byte ('F' frame, 'E' error), the payload's length (4 bytes, big endian),
    /// then the payload (JPEG data, or the error's text).
    static func message(_ type: UInt8, _ payload: Data) -> Data {
        var data = Data([type])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
        return data + payload
    }

    /// `AerialSwap --preview-scene <folder> [--properties <json>]`, run by ScenePreviewProcess. Renders until its
    /// output or input closes.
    static func runChild(_ args: [String]) -> Int32 {
        guard args.count >= 2, let options = SceneChildOptions(args.dropFirst(2)) else {
            print("usage: AerialSwap --preview-scene <folder> [--properties <json>]"); return 2
        }
        signal(SIGPIPE, SIG_IGN)   // a closed pipe ends the loop below instead of killing the process
        // The app closes the pipe to stop it (and it closes when the app quits).
        Thread.detachNewThread {
            var byte: UInt8 = 0
            while read(0, &byte, 1) > 0 {}
            exit(0)
        }
        let output = FileHandle.standardOutput
        func send(_ type: UInt8, _ payload: Data) -> Bool {
            (try? output.write(contentsOf: message(type, payload))) != nil
        }

        let folder = URL(fileURLWithPath: args[1])
        let renderer: SceneRenderer
        let width: Int, height: Int
        do {
            let project = try SceneProject(folder: folder)
            let files = try SceneFiles(folder: folder, entry: project.file)
            let document = try SceneDocument(files: files, project: project, overrides: options.properties)
            let raw = document.general.width / max(document.general.height, 1)
            let aspect = raw.isFinite ? min(max(raw, 0.1), 10) : 16.0 / 9
            var w = max(cover.x, cover.y * aspect), h = w / aspect
            let shrink = min(1, maxSide / max(w, h))
            w *= shrink; h *= shrink
            (width, height) = (max(1, Int(w.rounded())), max(1, Int(h.rounded())))
            renderer = try SceneRenderer(document: document, files: files, width: width, height: height)
        } catch {
            _ = send(UInt8(ascii: "E"), Data("\(error)".utf8))
            return 1
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        // Core Image puts a texture's first row at the bottom; the renderer's first row is the top.
        let flip = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(height))
        let start = Date.now
        var frame = 0
        while true {
            let time = Double(frame) / fps
            frame += 1
            let jpeg = autoreleasepool { () -> Data? in
                guard let texture = try? renderer.render(time: time),
                      let image = CIImage(mtlTexture: texture, options: [.colorSpace: sRGB]) else { return nil }
                return context.jpegRepresentation(of: image.transformed(by: flip), colorSpace: sRGB,
                                                  options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.85])
            }
            guard let jpeg else {
                _ = send(UInt8(ascii: "E"), Data("a frame couldn't be drawn".utf8))
                return 1
            }
            guard send(UInt8(ascii: "F"), jpeg) else { return 0 }
            // Real time; a slow scene drops frames instead of slowing down.
            let due = start.addingTimeInterval(Double(frame) / fps)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { Thread.sleep(forTimeInterval: wait) } else { frame = Int(-start.timeIntervalSinceNow * fps) }
        }
    }
}

/// Runs `AerialSwap --preview-scene` and hands its frames to the app. Stop (or a new start) ends it.
final class ScenePreviewProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var input: Pipe?

    /// `frame` and `failed` are called on the main actor.
    func start(folder: URL, properties: [String: SceneJSON], frame: @escaping @MainActor (NSImage) -> Void,
               failed: @escaping @MainActor (String) -> Void) {
        stop()
        guard let executable = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = executable
        p.arguments = ["--preview-scene", folder.path] + SceneChildOptions.arguments(properties: properties)
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice

        let reader = MessageReader()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            for (type, payload) in reader.append(data) {
                if type == UInt8(ascii: "F") {
                    // Only the newest frame matters; decoding happens here, off the main thread.
                    guard let image = NSImage(data: payload) else { continue }
                    Task { @MainActor in frame(image) }
                } else if type == UInt8(ascii: "E") {
                    let text = String(decoding: payload.prefix(500), as: UTF8.self)
                    Task { @MainActor in failed(text) }
                }
            }
        }
        p.terminationHandler = { process in
            guard process.terminationReason == .uncaughtSignal else { return }
            Task { @MainActor in failed("the preview stopped (signal \(process.terminationStatus))") }
        }
        do {
            try p.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in failed(error.localizedDescription) }
            return
        }
        lock.withLock { process = p; self.input = input }
    }

    func stop() {
        let (p, input): (Process?, Pipe?) = lock.withLock {
            defer { process = nil; self.input = nil }
            return (process, self.input)
        }
        p?.terminationHandler = nil
        (p?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if p?.isRunning == true { p?.terminate() }
    }

    deinit { stop() }

    /// Splits the pipe's bytes into messages (see ScenePreview.message).
    private final class MessageReader: @unchecked Sendable {
        private var buffer = Data()
        private static let maxPayload = 32 << 20

        func append(_ data: Data) -> [(UInt8, Data)] {
            buffer.append(data)
            var messages: [(UInt8, Data)] = []
            while buffer.count >= 5 {
                let start = buffer.startIndex
                let length = buffer[(start + 1)..<(start + 5)].reduce(0) { $0 << 8 | Int($1) }
                guard length <= Self.maxPayload else { buffer.removeAll(); break }
                guard buffer.count >= 5 + length else { break }
                messages.append((buffer[start], Data(buffer[(start + 5)..<(start + 5 + length)])))
                buffer.removeSubrange(start..<(start + 5 + length))
            }
            return messages
        }
    }
}
