import CoreMedia
import CoreVideo
import VideoToolbox

/// Generates in-between frames with VideoToolbox's optical-flow frame rate conversion, so low frame rate
/// sources (24/30 fps) get real 60 fps motion instead of repeated frames. This also keeps the unlock
/// slow-down fluid. Works on the finished 3840x2160 output frames (10-bit 4:2:0 in and out); the processor
/// itself needs 16-bit half-float RGBA, so frames are converted with VTPixelTransferSession around it.
final class FrameInterpolator {
    static var isSupported: Bool { VTFrameRateConversionConfiguration.isSupported }

    private let processor = VTFrameProcessor()
    private let toRGBA: VTPixelTransferSession
    private let toYUV: VTPixelTransferSession
    private let rgbaPool: CVPixelBufferPool
    private let yuvPool: CVPixelBufferPool
    // The last converted frames, reused while several in-between frames come from the same pair.
    private var cache: [(source: CVPixelBuffer, rgba: CVPixelBuffer)] = []

    init(width: Int, height: Int) throws {
        guard let config = VTFrameRateConversionConfiguration(frameWidth: width, frameHeight: height,
                                                              usePrecomputedFlow: false, qualityPrioritization: .normal,
                                                              revision: .revision1) else {
            throw TranscodeError.interpolation("frame rate conversion is not available on this Mac")
        }
        try processor.startSession(configuration: config)
        rgbaPool = try Self.makePool(config.destinationPixelBufferAttributes)
        yuvPool = try Self.makePool([
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        var a: VTPixelTransferSession?, b: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &a) == noErr, let a,
              VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &b) == noErr, let b else {
            throw TranscodeError.interpolation("could not create pixel transfer sessions")
        }
        toRGBA = a
        toYUV = b
    }

    deinit {
        processor.endSession()
        VTPixelTransferSessionInvalidate(toRGBA)
        VTPixelTransferSessionInvalidate(toYUV)
    }

    /// Returns the frames at `phases` (each 0...1) between `from` and `to`, as 10-bit 4:2:0 buffers.
    /// All in-between frames of a pair come from one call, so the optical flow is computed once per pair.
    /// `inOrder`: the pair follows the previous one (lets the processor reuse work from it).
    func interpolate(from: CVPixelBuffer, to: CVPixelBuffer, phases: [Double], inOrder: Bool) async throws -> [CVPixelBuffer] {
        guard !phases.isEmpty else { return [] }
        let a = try rgba(from), b = try rgba(to)
        let destinations = try phases.map { _ in try Self.buffer(from: rgbaPool) }
        // The processor only needs relative timing; place the pair 1 s apart and the targets at their phases.
        let timescale: CMTimeScale = 100_000
        let targets = zip(destinations, phases).compactMap { buffer, phase in
            VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: CMTime(value: CMTimeValue(phase * Double(timescale)), timescale: timescale))
        }
        guard targets.count == phases.count,
              let source = VTFrameProcessorFrame(buffer: a, presentationTimeStamp: CMTime(value: 0, timescale: timescale)),
              let next = VTFrameProcessorFrame(buffer: b, presentationTimeStamp: CMTime(value: CMTimeValue(timescale), timescale: timescale)),
              let parameters = VTFrameRateConversionParameters(sourceFrame: source, nextFrame: next, opticalFlow: nil,
                                                               interpolationPhase: phases.map { Float($0) },
                                                               submissionMode: inOrder ? .sequential : .random,
                                                               destinationFrames: targets)
        else { throw TranscodeError.interpolation("invalid frame parameters") }

        // The callback API is used on purpose: the Swift async overload returned before the work was done
        // (tested on macOS 27.0.1), which produced black frames.
        let failure: Error? = await withCheckedContinuation { done in
            processor.process(parameters: parameters) { _, error in done.resume(returning: error) }
        }
        if let failure { throw TranscodeError.interpolation(failure.localizedDescription) }

        return try destinations.map { destination in
            let output = try Self.buffer(from: yuvPool)
            copyColorAttachments(from: from, to: output)
            let status = VTPixelTransferSessionTransferImage(toYUV, from: destination, to: output)
            guard status == noErr else { throw TranscodeError.interpolation("pixel transfer failed (\(status))") }
            return output
        }
    }

    private func rgba(_ frame: CVPixelBuffer) throws -> CVPixelBuffer {
        if let hit = cache.first(where: { $0.source === frame }) { return hit.rgba }
        let converted = try Self.buffer(from: rgbaPool)
        copyColorAttachments(from: frame, to: converted)
        let status = VTPixelTransferSessionTransferImage(toRGBA, from: frame, to: converted)
        guard status == noErr else { throw TranscodeError.interpolation("pixel transfer failed (\(status))") }
        cache.append((frame, converted))
        if cache.count > 2 { cache.removeFirst() }
        return converted
    }

    /// Keeps the BT.709 / sRGB tags so the round trip doesn't change colors.
    private func copyColorAttachments(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey] {
            if let value = CVBufferCopyAttachment(source, key, nil) {
                CVBufferSetAttachment(destination, key, value, .shouldPropagate)
            }
        }
    }

    private static func makePool(_ attributes: [String: Any]) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            throw TranscodeError.interpolation("could not allocate frame buffers")
        }
        return pool
    }

    private static func buffer(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            throw TranscodeError.interpolation("could not allocate a frame buffer")
        }
        return buffer
    }
}
