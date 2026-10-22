import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import VideoToolbox

/// "Enhance detail": Apple's on-device ML upscaler (VTSuperResolutionScaler) for sources up to 1920x1080.
/// It only supports 4x, so 1080p becomes 8K and is scaled down to 4K afterwards (one resample, in Core Image).
/// Measured on test footage: visibly sharper text, edges and texture than plain scaling, but ~1.1 s per frame.
/// The model output is ~3% darker than its input, so every frame is brightness-matched to the source.
/// One session needs ~5 GB, so a transcode creates only one and gives each reader its own `Stream`.
final class DetailEnhancer {
    static let scaleFactor = 4

    /// The frame history of one run of consecutive frames: the scaler uses the previous frame and its output.
    final class Stream {
        fileprivate var previous: VTFrameProcessorFrame?
        fileprivate var previousOutput: VTFrameProcessorFrame?
        /// False while frames of several streams are interleaved (the loop crossfade).
        var inOrder = true
    }

    static var isSupported: Bool { VTSuperResolutionScalerConfiguration.isSupported }

    /// The scaler accepts at most 1920x1080 (video input on macOS), in the frame's stored orientation.
    static func canEnhance(width: Int, height: Int) -> Bool {
        isSupported && width > 0 && height > 0 && width <= 1920 && height <= 1080
    }

    private let processor = VTFrameProcessor()
    private let config: VTSuperResolutionScalerConfiguration
    private let pool: CVPixelBufferPool
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                              .cacheIntermediates: false])

    /// The pixel buffer attributes the scaler needs on its input (16-bit half-float RGBA).
    var sourceAttributes: [String: Any] { config.sourcePixelBufferAttributes }

    init(width: Int, height: Int) throws {
        guard let config = VTSuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height,
                                                                scaleFactor: Self.scaleFactor, inputType: .video,
                                                                usePrecomputedFlow: false, qualityPrioritization: .normal,
                                                                revision: .revision1) else {
            throw TranscodeError.enhancement("this video size (\(width)x\(height)) can't be enhanced")
        }
        self.config = config
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, config.destinationPixelBufferAttributes as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else { throw TranscodeError.enhancement("could not allocate frame buffers") }
        self.pool = pool
        try downloadModelIfNeeded()
        try processor.startSession(configuration: config)
    }

    deinit { processor.endSession() }

    /// Whether the ML model is already on this Mac (otherwise the first enhanced conversion downloads it).
    static func isModelReady(width: Int, height: Int) -> Bool {
        VTSuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: scaleFactor, inputType: .video,
                                             usePrecomputedFlow: false, qualityPrioritization: .normal, revision: .revision1)?
            .configurationModelStatus == .ready
    }

    private func downloadModelIfNeeded() throws {
        guard config.configurationModelStatus != .ready else { return }
        Log.info("Enhance detail: downloading the ML model (one-time)")
        // The download is quick (seconds) and runs before any frame work, so waiting synchronously is fine here.
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        config.downloadConfigurationModel { error in failure = error; done.signal() }
        done.wait()
        if let failure { throw TranscodeError.enhancement("model download failed: \(failure.localizedDescription)") }
    }

    /// Upscales one frame 4x and returns it in the source frame's coordinate space (scaled back by 1/4),
    /// so the caller's rotate/crop/fill transform applies unchanged and Core Image resamples only once.
    func enhance(_ frame: CVPixelBuffer, time: CMTime, stream: Stream) async throws -> CIImage {
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output,
              let source = VTFrameProcessorFrame(buffer: frame, presentationTimeStamp: time),
              let destination = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: time),
              let parameters = VTSuperResolutionScalerParameters(sourceFrame: source, previousFrame: stream.previous,
                                                                 previousOutputFrame: stream.previousOutput, opticalFlow: nil,
                                                                 submissionMode: stream.inOrder ? .sequential : .random,
                                                                 destinationFrame: destination)
        else { throw TranscodeError.enhancement("invalid frame parameters") }

        // Callback API on purpose, as in FrameInterpolator: the Swift async overload returned early (macOS 27.0.1).
        let failure: Error? = await withCheckedContinuation { done in
            processor.process(parameters: parameters) { _, error in done.resume(returning: error) }
        }
        if let failure { throw TranscodeError.enhancement(failure.localizedDescription) }
        stream.previous = source
        stream.previousOutput = destination
        CVBufferPropagateAttachments(frame, output)

        let original = CIImage(cvPixelBuffer: frame)
        let upscaled = CIImage(cvPixelBuffer: output)
            .transformed(by: CGAffineTransform(scaleX: 1 / CGFloat(Self.scaleFactor), y: 1 / CGFloat(Self.scaleFactor)))
        return matchBrightness(upscaled, to: original)
    }

    /// Per-channel gain so the enhanced frame has the same average color as the original frame.
    private func matchBrightness(_ image: CIImage, to reference: CIImage) -> CIImage {
        let target = average(reference), current = average(image)
        func gain(_ i: Int) -> CGFloat { current[i] > 1e-4 ? CGFloat(target[i] / current[i]) : 1 }
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: gain(0), y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: gain(1), z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: gain(2), w: 0)
        return filter.outputImage ?? image
    }

    /// Average linear RGB of an image (GPU reduction to one pixel).
    private func average(_ image: CIImage) -> [Float] {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = image.extent
        var pixel = [Float](repeating: 0, count: 4)
        if let output = filter.outputImage {
            context.render(output, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: nil)   // nil: stay in the linear working space
        }
        return pixel
    }
}
