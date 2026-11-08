import AVFoundation
import CoreVideo
import Metal

/// A video texture (an MP4 inside a `.tex`), decoded while it plays; decoded up front, a 30-second 720p clip would
/// take gigabytes. Wallpaper Engine loops it, so time `t` shows the frame at `t` modulo its length. A few readers stay
/// open at different points (a loop's crossfade draws two times in each frame), each moving forward through the file;
/// going back, or far ahead, opens another one.
final class VideoTexture {
    let width: Int
    let height: Int
    /// Seconds until the clip starts over.
    let duration: Double

    /// AVFoundation reads files, not data.
    private let file: URL
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let cache: CVMetalTextureCache
    /// Presentation time of each frame, ascending.
    private let times: [Double]
    private var cursors: [Cursor] = []
    /// Frames handed out since `release()`: the GPU may still be reading them.
    private var inFlight: [CVMetalTexture] = []
    private var uses = 0

    /// Readers kept open at once, and how many frames a reader decodes to move forward before a new one is opened
    /// at the frame instead.
    private static let maxCursors = 3
    private static let maxSkip = 90
    /// Frames as Metal can read them without a copy.
    private static var decoded: [String: Any] { [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ] }

    private final class Cursor {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        /// The frame `texture` shows; -1 before the first.
        var index = -1
        var texture: CVMetalTexture?
        var lastUse = 0

        init(reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
            self.reader = reader
            self.output = output
        }
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }

    init(data: Data, name: String, device: MTLDevice) throws {
        file = FileManager.default.temporaryDirectory.appending(path: "AerialSwap-video-\(UUID().uuidString).mp4")
        try data.write(to: file)
        asset = AVURLAsset(url: file)
        do {
            // The completion-handler form, so a renderer on any thread can wait for it.
            let loaded = Box<AVAssetTrack>(), done = DispatchSemaphore(value: 0)
            asset.loadTracks(withMediaType: .video) { tracks, _ in
                loaded.value = tracks?.first
                done.signal()
            }
            done.wait()
            guard let track = loaded.value else { throw SceneError.malformed(name) }
            self.track = track

            // The frames' times and size, from the compressed samples (nothing is decoded).
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            guard reader.startReading() else { throw SceneError.malformed(name) }
            var times: [Double] = [], end = 0.0, size: CMVideoDimensions?
            while let sample = output.copyNextSampleBuffer() {
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard time.isFinite else { continue }
                times.append(time)
                let length = CMSampleBufferGetDuration(sample).seconds
                end = max(end, time + (length.isFinite ? length : 0))
                if size == nil, let format = CMSampleBufferGetFormatDescription(sample) {
                    size = CMVideoFormatDescriptionGetDimensions(format)
                }
                guard times.count <= 1 << 20 else { throw SceneError.tooLarge(name) }
            }
            guard reader.status == .completed, let size, !times.isEmpty,
                  (1 ... SceneLimits.maxTextureSide).contains(Int(size.width)),
                  (1 ... SceneLimits.maxTextureSide).contains(Int(size.height))
            else { throw SceneError.malformed(name) }
            // Compressed samples keep the file's edit-list offset (B-frames delay them by a frame or two); decoded frames
            // start where the track does. The first decoded frame tells the shift.
            let first = try AVAssetReader(asset: asset)
            let firstOutput = AVAssetReaderTrackOutput(track: track, outputSettings: Self.decoded)
            first.add(firstOutput)
            guard first.startReading(), let sample = firstOutput.copyNextSampleBuffer() else { throw SceneError.malformed(name) }
            let shift = times.min()! - CMSampleBufferGetPresentationTimeStamp(sample).seconds
            first.cancelReading()
            guard shift.isFinite else { throw SceneError.malformed(name) }
            self.times = times.map { $0 - shift }.sorted()
            width = Int(size.width)
            height = Int(size.height)
            duration = max(end - shift, self.times.last!)

            var cache: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
                throw SceneError.unsupported("Video textures on this GPU")
            }
            self.cache = cache
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    deinit {
        for cursor in cursors { cursor.reader.cancelReading() }
        try? FileManager.default.removeItem(at: file)
    }

    /// The frame showing at `time`, or nil when the video can't be decoded.
    func texture(at time: Double) -> MTLTexture? {
        guard duration > 0 else { return nil }
        var t = time.truncatingRemainder(dividingBy: duration)
        if t < 0 { t += duration }
        let target = index(at: t)
        uses += 1

        let usable = cursors.filter { $0.index <= target && target - $0.index <= Self.maxSkip }
        guard let cursor = usable.max(by: { $0.index < $1.index }) ?? open(at: target) else { return nil }
        while cursor.index < target, read(cursor) {}
        cursor.lastUse = uses
        guard let texture = cursor.texture, let metal = CVMetalTextureGetTexture(texture) else { return nil }
        inFlight.append(texture)
        return metal
    }

    /// Lets go of the frames handed out so far; the renderer calls it once the GPU has finished with them.
    func release() {
        inFlight.removeAll()
        CVMetalTextureCacheFlush(cache, 0)
    }

    /// The frame at `time`: the last one starting at or before it.
    private func index(at time: Double) -> Int {
        var low = 0, high = times.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if times[middle] <= time + 1e-6 { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// A reader starting at frame `index`, replacing the one used longest ago when there are enough.
    private func open(at index: Int) -> Cursor? {
        if cursors.count >= Self.maxCursors, let oldest = cursors.min(by: { $0.lastUse < $1.lastUse }) {
            oldest.reader.cancelReading()
            cursors.removeAll { $0 === oldest }
        }
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.decoded)
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: times[index], preferredTimescale: 600),
                                       end: CMTime(seconds: duration + 1, preferredTimescale: 600))
        guard reader.startReading() else { return nil }
        let cursor = Cursor(reader: reader, output: output)
        cursors.append(cursor)
        return cursor
    }

    /// Moves the reader to its next frame; false at the end of the clip or on an error.
    private func read(_ cursor: Cursor) -> Bool {
        while let sample = cursor.output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            var texture: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, CVPixelBufferGetWidth(buffer),
                                                            CVPixelBufferGetHeight(buffer), 0, &texture) == kCVReturnSuccess
            else { return false }
            cursor.texture = texture
            cursor.index = max(cursor.index + 1, index(at: CMSampleBufferGetPresentationTimeStamp(sample).seconds))
            return true
        }
        return false
    }
}
