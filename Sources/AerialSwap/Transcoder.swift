import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import VideoToolbox

/// User-selectable transcode parameters.
struct TranscodeOptions: Sendable {
    var fps: Int = 60
    var trimStart: Double = 0
    var trimEnd: Double? = nil        // nil = until the end of the source
    var freezeSeconds: Double = 0     // hold the last frame for this long
}

/// Basic facts about a source video, shown in the UI.
struct SourceInfo: Sendable {
    var duration: Double
    var width: Int
    var height: Int
    var fps: Float
    var hdr: String?    // "HDR10" (PQ) or "HLG"; nil for SDR
}

enum TranscodeError: LocalizedError {
    case noVideoTrack
    case unsupportedFormat(String)
    case invalidTrim
    case encoderSetup(OSStatus)
    case encode(OSStatus)
    case reader(String)
    case writer(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The file has no video track."
        case .unsupportedFormat(let codec): "macOS has no decoder for this video's codec (\(codec))."
        case .invalidTrim: "Trim range is empty or outside the video."
        case .encoderSetup(let s): "Could not set up the HEVC encoder (OSStatus \(s))."
        case .encode(let s): "HEVC encoding failed (OSStatus \(s))."
        case .reader(let m): "Could not read the source video: \(m)"
        case .writer(let m): "Could not write the output file: \(m)"
        case .cancelled: "Transcode cancelled."
        }
    }
}

/// Converts any video into Apple's Aerial format:
/// HEVC Main 10, hvc1, 3840x2160, aspect-fill center crop, no audio,
/// with hierarchical temporal layers (TSA). The layers are required: without them
/// WallpaperAerialsExtension fails the unlock ramp-down and shows a grey desktop.
final class Transcoder: @unchecked Sendable {
    static let width = 3840
    static let height = 2160
    /// Frame rate of the base temporal layer; higher layers double it up to the output fps.
    static let baseLayerFPS = 15.0

    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// Output frame rate for a source: 60 for normal video (24/30/60), 120 or 240 only when the
    /// source really has that many frames (e.g. iPhone slo-mo), which makes the unlock slow-down smoother.
    /// Thresholds leave headroom for variable-frame-rate averages like 59.94 or 119.88.
    static func autoFPS(forSource fps: Float) -> Int {
        switch fps {
        case 130...: 240
        case 65...: 120
        default: 60
        }
    }

    /// Reads basic facts about a source. Throws `unsupportedFormat` when macOS can open the file
    /// but has no decoder for its codec (e.g. AV1 without hardware support).
    static func inspect(_ url: URL) async throws -> SourceInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw TranscodeError.noVideoTrack }
        guard try await track.load(.isDecodable) else {
            let format = try await track.load(.formatDescriptions).first
            throw TranscodeError.unsupportedFormat(format.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown codec")
        }
        let (size, transform, fps, formats) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate,
                                                                    .formatDescriptions)
        let duration = try await asset.load(.duration).seconds
        let shown = CGRect(origin: .zero, size: size).applying(transform)
        let transfer = formats.first.flatMap {
            CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        }
        var hdr: String?
        if transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String { hdr = "HLG" }
        if transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String { hdr = "HDR10" }
        return SourceInfo(duration: duration, width: Int(abs(shown.width)), height: Int(abs(shown.height)), fps: fps, hdr: hdr)
    }

    /// Transcodes `source` into `destination` (which must not be inside the aerials folder).
    func run(source: URL, destination: URL, options: TranscodeOptions,
             progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw TranscodeError.noVideoTrack }
        let (naturalSize, transform, trackRange) = try await track.load(.naturalSize, .preferredTransform, .timeRange)

        let sourceEnd = trackRange.end.seconds
        let start = max(0, options.trimStart)
        let end = min(options.trimEnd ?? sourceEnd, sourceEnd)
        guard end - start >= 0.1 else { throw TranscodeError.invalidTrim }

        let fps = options.fps
        let clipFrames = Int(((end - start) * Double(fps)).rounded())
        let freezeFrames = Int((max(0, options.freezeSeconds) * Double(fps)).rounded())
        let totalFrames = max(1, clipFrames + freezeFrames)
        Log.info("Transcode \(source.lastPathComponent): \(start)-\(end)s @\(fps)fps, freeze \(options.freezeSeconds)s")

        // Frame source. SDR and PQ (HDR10): a video composition does rotation, aspect-fill crop and color
        // conversion; its PQ->SDR mapping is correct (203 nits -> ~90% white). HLG (e.g. iPhone HDR):
        // AVFoundation's conversion comes out ~1.5 stops too dark, so raw frames are rendered with
        // Core Image and our own tone curve instead (see HLGRenderer).
        let fill = Self.fillTransform(naturalSize: naturalSize, preferred: transform)
        let frameSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let output: AVAssetReaderOutput
        let render: (CVPixelBuffer) throws -> CVPixelBuffer
        if try await Self.isHLG(track) {
            Log.info("HLG source: rendering with Core Image tone mapping")
            let renderer = try HLGRenderer(transform: Self.coreImageTransform(fill, sourceHeight: naturalSize.height))
            output = AVAssetReaderTrackOutput(track: track, outputSettings: frameSettings)
            render = renderer.render
        } else {
            let composition = AVMutableVideoComposition()
            composition.renderSize = CGSize(width: Self.width, height: Self.height)
            composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            composition.colorTransferFunction = AVVideoTransferFunction_IEC_sRGB   // Apple aerials are tagged sRGB
            composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(fill, at: .zero)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = trackRange
            instruction.layerInstructions = [layer]
            composition.instructions = [instruction]
            let compositionOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: frameSettings)
            compositionOutput.videoComposition = composition
            output = compositionOutput
            render = { $0 }
        }
        output.alwaysCopiesSampleData = false

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       end: CMTime(seconds: end, preferredTimescale: 600))
        reader.add(output)

        try? FileManager.default.removeItem(at: destination)
        let sink = try WriterSink(url: destination)
        let encoder = try Self.makeEncoder(fps: fps, sink: sink)
        defer { VTCompressionSessionInvalidate(encoder) }

        guard reader.startReading() else { throw TranscodeError.reader(reader.error?.localizedDescription ?? "unknown error") }

        var frameIndex = 0
        func encode(_ pixelBuffer: CVPixelBuffer) throws {
            if isCancelled { throw TranscodeError.cancelled }
            if let error = sink.error { throw error }
            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
            let status = VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                                         duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                                                         frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
            guard status == noErr else { throw TranscodeError.encode(status) }
            frameIndex += 1
            progress(Double(frameIndex) / Double(totalFrames))
        }

        // Source frames are rendered lazily: only when they are actually used, and only once when repeated.
        var lastSource: CVPixelBuffer?
        var lastRendered: CVPixelBuffer?
        func emitLast() throws {
            guard let lastSource else { return }
            if lastRendered == nil { lastRendered = try render(lastSource) }
            try encode(lastRendered!)
        }

        do {
            // Neither source duplicates frames, so map source frames onto the output grid:
            // output frame k (time k/fps) shows the latest source frame with pts <= k/fps.
            // This duplicates frames for up-conversion (30 -> 60) and drops them for down-conversion.
            while let sample = output.copyNextSampleBuffer() {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds - start
                if lastSource != nil {
                    while frameIndex < clipFrames, Double(frameIndex) / Double(fps) < time - 1e-6 {
                        try emitLast()
                    }
                }
                lastSource = pixelBuffer
                lastRendered = nil
            }
            if reader.status == .failed { throw TranscodeError.reader(reader.error?.localizedDescription ?? "unknown error") }
            if lastSource != nil {
                while frameIndex < clipFrames { try emitLast() }   // rest of the clip
                for _ in 0..<freezeFrames { try emitLast() }        // optional hold
            }
            let status = VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
            guard status == noErr else { throw TranscodeError.encode(status) }
            try await sink.finish()
        } catch {
            reader.cancelReading()
            sink.cancel()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        Log.info("Transcode finished: \(frameIndex) frames -> \(destination.path)")
    }

    private static func isHLG(_ track: AVAssetTrack) async throws -> Bool {
        guard let format = try await track.load(.formatDescriptions).first,
              let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
        else { return false }
        return (transfer as? String) == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
    }

    /// Converts a layer-instruction transform (origin top-left, y down) to Core Image (origin bottom-left, y up).
    private static func coreImageTransform(_ transform: CGAffineTransform, sourceHeight: CGFloat) -> CGAffineTransform {
        let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: sourceHeight)
        let flipCanvas = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height))
        return flipSource.concatenating(transform).concatenating(flipCanvas)
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// Maps the (possibly rotated) source onto the 3840x2160 canvas, scaled to fill and centered.
    static func fillTransform(naturalSize: CGSize, preferred: CGAffineTransform) -> CGAffineTransform {
        let shown = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let scale = max(CGFloat(width) / shown.width, CGFloat(height) / shown.height)
        let dx = (CGFloat(width) - shown.width * scale) / 2
        let dy = (CGFloat(height) - shown.height * scale) / 2
        return preferred
            .concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: dx, y: dy))
    }

    private static func makeEncoder(fps: Int, sink: WriterSink) throws -> VTCompressionSession {
        var session: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, _, sample in
                let sink = Unmanaged<WriterSink>.fromOpaque(refcon!).takeUnretainedValue()
                sink.append(status: status, sample: sample)
            },
            refcon: Unmanaged.passUnretained(sink).toOpaque(),   // sink outlives the session (see run())
            compressionSessionOut: &session)
        guard status == noErr, let session else { throw TranscodeError.encoderSetup(status) }

        // Bitrate grows with frame rate; values chosen to stay visually clean for 4K content.
        let bitrate = [30: 20_000_000, 60: 30_000_000, 120: 40_000_000, 240: 50_000_000][fps] ?? 30_000_000
        let properties: [CFString: CFTypeRef] = [
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main10_AutoLevel,
            kVTCompressionPropertyKey_RealTime: kCFBooleanFalse,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps as CFNumber,
            kVTCompressionPropertyKey_AverageBitRate: bitrate as CFNumber,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2.0 as CFNumber,
            // Hierarchical encoding -> HEVC temporal sub-layers + TSA sample groups (needed by macOS).
            kVTCompressionPropertyKey_BaseLayerFrameRate: min(baseLayerFPS, Double(fps) / 2) as CFNumber,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_sRGB,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (key, value) in properties {
            let s = VTSessionSetProperty(session, key: key, value: value)
            guard s == noErr else { throw TranscodeError.encoderSetup(s) }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }
}

/// HDR -> SDR tone curve applied in linear light, where Core Image puts HDR reference white
/// (PQ 203 nits / HLG 75%) at 1.0. Identity up to 0.5, then a soft shoulder: reference white lands at
/// ~90% (matching AVFoundation's PQ conversion) and highlights up to 20x are compressed instead of clipped.
private struct HDRToneMap: Sendable {
    private static let maxInput = 20.0
    private let table: Data

    init() {
        let samples = 2048
        var values = [Float]()
        for i in 0..<samples {
            let v = Float(Self.curve(Double(i) / Double(samples - 1) * Self.maxInput))
            values += [v, v, v]   // same curve for R, G, B
        }
        table = values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func curve(_ x: Double) -> Double {
        let knee = 0.5, strength = 1.38
        guard x > knee else { return x }
        let t = (x - knee) / (1 - knee) * strength
        return knee + (1 - knee) * t / (1 + t)
    }

    func apply(to image: CIImage) -> CIImage {
        let filter = CIFilter.colorCurves()
        filter.inputImage = image
        filter.curvesData = table
        filter.curvesDomain = CIVector(x: 0, y: CGFloat(Self.maxInput))
        filter.colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        return (filter.outputImage ?? image).settingContentHeadroom(1)   // now SDR: no further tone mapping
    }
}

/// Renders HLG frames with Core Image: rotation + aspect-fill crop, the HDR tone curve, and conversion
/// to the output's BT.709 / sRGB colors, into 10-bit 4:2:0 buffers for the encoder.
private final class HLGRenderer {
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .cacheIntermediates: false,
    ])
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!   // BT.709 primaries, sRGB transfer
    private let canvas = CGRect(x: 0, y: 0, width: Transcoder.width, height: Transcoder.height)
    private let transform: CGAffineTransform
    private let toneMap = HDRToneMap()
    private let pool: CVPixelBufferPool

    init(transform: CGAffineTransform) throws {
        self.transform = transform
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: Transcoder.width,
            kCVPixelBufferHeightKey as String: Transcoder.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            throw TranscodeError.reader("could not allocate frame buffers")
        }
        self.pool = pool
    }

    func render(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            throw TranscodeError.reader("could not allocate a frame buffer")
        }
        // Core Image converts RGB -> YCbCr using these attachments; the encoder tags the stream the same way.
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        // CIImage reads the frame's HLG / BT.2020 attachments and decodes to linear light (reference white = 1.0).
        let image = CIImage(cvPixelBuffer: source).transformed(by: transform).cropped(to: canvas)
        context.render(toneMap.apply(to: image), to: buffer, bounds: canvas, colorSpace: outputColorSpace)
        return buffer
    }
}

/// Receives encoded HEVC samples from VideoToolbox and writes them unchanged (passthrough)
/// with AVAssetWriter, which turns the temporal-level sample attachments into tscl/tsas boxes.
private final class WriterSink: @unchecked Sendable {
    private let writer: AVAssetWriter
    private var input: AVAssetWriterInput?
    private let lock = NSLock()
    private var failure: Error?
    private var stopped = false

    init(url: URL) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    }

    var error: Error? { lock.withLock { failure } }

    /// Called on VideoToolbox's callback thread, in decode order.
    func append(status: OSStatus, sample: CMSampleBuffer?) {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil, !stopped else { return }
        guard status == noErr, let sample else { failure = TranscodeError.encode(status); return }
        if input == nil {
            let newInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                              sourceFormatHint: CMSampleBufferGetFormatDescription(sample))
            newInput.expectsMediaDataInRealTime = false
            writer.add(newInput)
            guard writer.startWriting() else {
                failure = TranscodeError.writer(writer.error?.localizedDescription ?? "unknown error"); return
            }
            writer.startSession(atSourceTime: .zero)
            input = newInput
        }
        guard let input else { return }
        while !input.isReadyForMoreMediaData && writer.status == .writing { usleep(500) }
        if !input.append(sample) {
            failure = TranscodeError.writer(writer.error?.localizedDescription ?? "append failed")
        }
    }

    func finish() async throws {
        let input = lock.withLock { () -> AVAssetWriterInput? in stopped = true; return self.input }
        if let failure = error { throw failure }
        guard let input else { throw TranscodeError.writer("no frames were encoded") }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw TranscodeError.writer(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }

    func cancel() {
        lock.withLock { stopped = true }
        if writer.status == .writing { writer.cancelWriting() }
    }
}
