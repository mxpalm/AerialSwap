// Generates a 2 s, 30 fps HDR test clip with 8 neutral-gray patches of known signal level.
// usage: hdrgen <out.mov> pq|hlg <width> <height>
//   pq:  0, 1, 10, 50, 100, 203, 1000, 4000 nits (HDR10, BT.2020)
//   hlg: signal 0, 0.1, 0.25, 0.5, 0.6, 0.75, 0.9, 1.0 (0.75 = reference white, BT.2020)
import AVFoundation
import VideoToolbox

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
let mode = args[2]
let W = Int(args[3])!, H = Int(args[4])!
let fps: Int32 = 30

/// PQ inverse EOTF (SMPTE ST 2084): nits -> signal 0...1
func pq(_ nits: Double) -> Double {
    let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
    let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
    let y = pow(nits / 10000, m1)
    return pow((c1 + c2 * y) / (1 + c3 * y), m2)
}
let signals: [Double] = mode == "pq" ? [0, 1, 10, 50, 100, 203, 1000, 4000].map(pq) : [0, 0.1, 0.25, 0.5, 0.6, 0.75, 0.9, 1.0]
let transfer = mode == "pq" ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_2100_HLG

var session: VTCompressionSession?
VTCompressionSessionCreate(allocator: nil, width: Int32(W), height: Int32(H), codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
                           imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                           compressionSessionOut: &session)
let vt = session!
VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main10_AutoLevel)
VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_AverageBitRate, value: 20_000_000 as CFNumber)
VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_2020)
VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_TransferFunction, value: transfer)
VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_2020)

try? FileManager.default.removeItem(at: out)
let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
var input: AVAssetWriterInput?
for i in 0..<Int(fps * 2) {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    let buf = pb!
    CVPixelBufferLockBaseAddress(buf, [])
    let y = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!.assumingMemoryBound(to: UInt16.self)
    let ys = CVPixelBufferGetBytesPerRowOfPlane(buf, 0) / 2
    for r in 0..<H { for c in 0..<W { y[r * ys + c] = UInt16(64 + Int((876 * signals[c * 8 / W]).rounded())) << 6 } }   // 10-bit limited range
    let uv = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!.assumingMemoryBound(to: UInt16.self)
    let uvs = CVPixelBufferGetBytesPerRowOfPlane(buf, 1) / 2
    for r in 0..<(H / 2) { for c in 0..<W { uv[r * uvs + c] = 512 << 6 } }   // neutral chroma
    CVPixelBufferUnlockBaseAddress(buf, [])
    CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
    CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
    CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    VTCompressionSessionEncodeFrame(vt, imageBuffer: buf, presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: fps),
                                    duration: CMTime(value: 1, timescale: fps), frameProperties: nil, infoFlagsOut: nil) { _, _, sb in
        guard let sb else { return }
        if input == nil {
            input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: CMSampleBufferGetFormatDescription(sb))
            writer.add(input!); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        }
        while !input!.isReadyForMoreMediaData { usleep(500) }
        input!.append(sb)
    }
}
VTCompressionSessionCompleteFrames(vt, untilPresentationTimeStamp: .invalid)
input!.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print("wrote \(out.lastPathComponent): \(writer.status == .completed ? "ok" : String(describing: writer.error))")
