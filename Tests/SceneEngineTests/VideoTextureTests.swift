import AVFoundation
import Metal
import Testing
@testable import SceneEngine

/// Video textures show the frame due at any time, in any order, looping.
@Suite struct VideoTextureTests {
    static let frames = 30, fps = 30

    /// A one-second H.264 clip whose frame k is gray k * 8.
    static func clip() async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(path: "video-texture-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for k in 0 ..< frames {
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try #require(CVPixelBufferGetBaseAddress(pixels))
            memset(base, Int32(k * 8), CVPixelBufferGetBytesPerRow(pixels) * 64)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(k), timescale: CMTimeScale(fps))))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return try Data(contentsOf: url)
    }

    @Test func framesFollowTime() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let video = try VideoTexture(data: try await Self.clip(), name: "test", device: device)
        #expect(video.width == 64 && video.height == 64)
        #expect(abs(video.duration - 1) < 0.01)

        func gray(at time: Double) throws -> Int {
            let texture = try #require(video.texture(at: time))
            var pixel = [UInt8](repeating: 0, count: 4)
            texture.getBytes(&pixel, bytesPerRow: 4 * 64, from: MTLRegionMake2D(32, 32, 1, 1), mipmapLevel: 0)
            video.release()
            return Int(pixel[1])
        }
        // Forward, back (a new reader), far ahead, past the end (looping), and back again.
        for (time, frame) in [(0.0, 0), (0.5, 15), (0.1, 3), (0.12, 3), (0.2, 6), (0.95, 28), (1.2, 6), (2.5, 15), (0.0, 0)] {
            let value = try gray(at: time)
            #expect(abs(value - frame * 8) <= 6, "time \(time): gray \(value), expected frame \(frame) (\(frame * 8))")
        }
    }
}
