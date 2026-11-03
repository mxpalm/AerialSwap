import AppKit
import CoreImage
import CoreMedia
import VideoToolbox

/// A picture as frames: a GIF's with their durations, a still picture as one frame.
struct PreviewFrames: @unchecked Sendable {   // CGImage is immutable
    let images: [CGImage]
    let delays: [Double]

    init(images: [CGImage], delays: [Double]) {
        self.images = images
        self.delays = delays
    }

    init?(_ image: NSImage) {
        guard let rep = image.representations.lazy.compactMap({ $0 as? NSBitmapImageRep }).first,
              let copy = rep.copy() as? NSBitmapImageRep else { return nil }   // a copy: the shared image keeps its frame
        let count = max(1, copy.value(forProperty: .frameCount) as? Int ?? 1)
        var images: [CGImage] = [], delays: [Double] = []
        for index in 0..<count {
            if count > 1 { copy.setProperty(.currentFrame, withValue: index) }
            guard let frame = copy.cgImage else { continue }
            images.append(frame)
            // As in browsers: a delay under 20 ms means "as fast as possible" and is shown as 100 ms.
            let delay = copy.value(forProperty: .currentFrameDuration) as? Double ?? 0.1
            delays.append(delay < 0.02 ? 0.1 : delay)
        }
        guard !images.isEmpty else { return nil }
        self.init(images: images, delays: delays)
    }

    var pixelWidth: Int { images.first?.width ?? 0 }
    var shortestDelay: Double { delays.min() ?? 0.1 }

    /// The frame to show at `date`, looping.
    func image(at date: Date) -> CGImage {
        let duration = delays.reduce(0, +)
        guard images.count > 1, duration > 0 else { return images[0] }
        var time = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration)
        for (index, delay) in delays.enumerated() {
            if time < delay { return images[index] }
            time -= delay
        }
        return images[images.count - 1]
    }
}

/// Workshop previews are often 160-256 px GIFs. Full-window they're upscaled 4x with Apple's ML upscaler (the one
/// Enhance detail uses), frame by frame: 2-4 s for a typical GIF, smooth instead of blocky.
/// Its image mode, not DetailEnhancer's video mode: that answers NaN for frames this small (macOS 27.2).
enum PreviewUpscaler {
    static let scaleFactor = 4

    /// The upscaled frames, or nil when this Mac can't (or the result would take more than ~400 MB).
    static func upscale(_ frames: PreviewFrames) async -> PreviewFrames? {
        guard let first = frames.images.first, DetailEnhancer.canEnhance(width: first.width, height: first.height),
              frames.images.count * first.width * first.height * scaleFactor * scaleFactor * 4 <= 400_000_000,
              let config = VTSuperResolutionScalerConfiguration(frameWidth: first.width, frameHeight: first.height,
                                                               scaleFactor: scaleFactor, inputType: .image, usePrecomputedFlow: false,
                                                               qualityPrioritization: .normal, revision: .revision1),
              await modelReady(config) else { return nil }
        var sourcePool: CVPixelBufferPool?, destinationPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, config.sourcePixelBufferAttributes as CFDictionary, &sourcePool) == kCVReturnSuccess,
              CVPixelBufferPoolCreate(nil, nil, config.destinationPixelBufferAttributes as CFDictionary, &destinationPool) == kCVReturnSuccess,
              let sourcePool, let destinationPool else { return nil }
        let processor = VTFrameProcessor()
        guard (try? processor.startSession(configuration: config)) != nil else { return nil }
        defer { processor.endSession() }

        let context = CIContext()
        var upscaled: [CGImage] = []
        for image in frames.images {
            guard !Task.isCancelled else { return nil }
            var input: CVPixelBuffer?, output: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, sourcePool, &input) == kCVReturnSuccess, let input,
                  CVPixelBufferPoolCreatePixelBuffer(nil, destinationPool, &output) == kCVReturnSuccess, let output,
                  let source = VTFrameProcessorFrame(buffer: input, presentationTimeStamp: .zero),
                  let destination = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: .zero) else { return nil }
            context.render(CIImage(cgImage: image), to: input)
            guard let parameters = VTSuperResolutionScalerParameters(sourceFrame: source, previousFrame: nil, previousOutputFrame: nil,
                                                                     opticalFlow: nil, submissionMode: .random,
                                                                     destinationFrame: destination) else { return nil }
            // Callback API, as in DetailEnhancer.
            let failure: Error? = await withCheckedContinuation { done in
                processor.process(parameters: parameters) { _, error in done.resume(returning: error) }
            }
            let result = CIImage(cvPixelBuffer: output)
            guard failure == nil, let frame = context.createCGImage(result, from: result.extent) else { return nil }
            upscaled.append(frame)
        }
        return PreviewFrames(images: upscaled, delays: frames.delays)
    }

    /// Apple's model is downloaded once (seconds); Enhance detail may already have done it.
    private static func modelReady(_ config: VTSuperResolutionScalerConfiguration) async -> Bool {
        guard config.configurationModelStatus != .ready else { return true }
        Log.info("Workshop preview: downloading the upscaler's ML model (one-time)")
        let failure: Error? = await withCheckedContinuation { done in config.downloadConfigurationModel { done.resume(returning: $0) } }
        return failure == nil
    }
}
