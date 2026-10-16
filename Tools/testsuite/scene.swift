// Renders an original procedural landscape as 4K test footage (ground truth for upscaling tests):
// fBm cloud sky, textured mountain ridges, a rippled lake, thin branches and small text, with a slow pan.
// usage: scene <out.mov> <frames>
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let frameCount = Int(CommandLine.arguments[2]) ?? 30
let W: CGFloat = 3840, H: CGFloat = 2160
let canvas = CGRect(x: 0, y: 0, width: W, height: H)
let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])

/// Fractal (1/f) noise: random noise blurred at several scales and summed, like natural textures.
func fbm(seedOffset: CGFloat, scales: [CGFloat], weights: [CGFloat]) -> CIImage {
    let base = CIFilter.randomGenerator().outputImage!.transformed(by: CGAffineTransform(translationX: seedOffset, y: seedOffset * 0.7))
    var sum: CIImage?
    for (scale, weight) in zip(scales, weights) {
        let layer = base.transformed(by: CGAffineTransform(scaleX: scale, y: scale))   // upscaled noise = coarser detail
            .applyingGaussianBlur(sigma: Double(scale) * 0.6)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: weight, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: weight, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: weight, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        sum = sum.map { layer.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? layer
    }
    return sum!
}

/// Maps a grayscale image to colors with a two-color gradient.
func tint(_ image: CIImage, _ dark: CIColor, _ light: CIColor) -> CIImage {
    image.applyingFilter("CIFalseColor", parameters: ["inputColor0": dark, "inputColor1": light])
}

/// A ridge silhouette mask: white below the jagged line y = base + noise(x).
func ridgeMask(base: CGFloat, amplitude: CGFloat, seed: Int, pan: CGFloat) -> CIImage {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    var x: CGFloat = -40
    var y = base
    var state = UInt64(seed)
    func rand() -> CGFloat { state = state &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(state >> 33) / CGFloat(1 << 31) }
    while x < W + 2000 {
        y += (rand() - 0.5) * amplitude * 0.35
        y = min(max(y, base - amplitude), base + amplitude)
        path.addLine(to: CGPoint(x: x - pan, y: y))
        x += 6 + rand() * 18
    }
    path.addLine(to: CGPoint(x: W, y: 0))
    path.closeSubpath()
    let image = CIImage(color: .white).cropped(to: canvas)
    // Rasterize the path through a CGContext into a mask image.
    let cs = CGColorSpaceCreateDeviceGray()
    let cg = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                       bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    cg.setShouldAntialias(true)
    cg.setFillColor(gray: 1, alpha: 1)
    cg.addPath(path)
    cg.fillPath()
    _ = image
    return CIImage(cgImage: cg.makeImage()!)
}

func render(frame i: Int) -> CIImage {
    let t = CGFloat(i)
    let pan = t * 6            // slow camera pan, pixels per frame at 4K

    // Sky: blue gradient with drifting fBm clouds.
    let skyGradient = CIFilter.linearGradient()
    skyGradient.point0 = CGPoint(x: 0, y: H); skyGradient.color0 = CIColor(red: 0.18, green: 0.36, blue: 0.70)
    skyGradient.point1 = CGPoint(x: 0, y: H * 0.45); skyGradient.color1 = CIColor(red: 0.78, green: 0.86, blue: 0.95)
    let sky = skyGradient.outputImage!.cropped(to: canvas)
    let cloudNoise = fbm(seedOffset: 300, scales: [96, 40, 16, 6, 2], weights: [0.55, 0.25, 0.12, 0.06, 0.03])
        .transformed(by: CGAffineTransform(translationX: -pan * 0.4, y: 0)).cropped(to: canvas)
    let clouds = tint(cloudNoise, CIColor(red: 0, green: 0, blue: 0), CIColor(red: 1, green: 1, blue: 1))
        .applyingFilter("CIColorControls", parameters: ["inputContrast": 1.7, "inputBrightness": -0.18])
        .applyingFilter("CIColorClamp")   // no negative values: they would darken the sky in the screen blend
    var scene = clouds.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: sky]).cropped(to: canvas)

    // Mountains: three ridges, far to near, each filled with its own rock/forest texture.
    let ridges: [(CGFloat, CGFloat, Int, CGFloat, CIColor, CIColor)] = [
        (H * 0.62, 180, 7, 0.5, CIColor(red: 0.30, green: 0.35, blue: 0.48), CIColor(red: 0.55, green: 0.60, blue: 0.72)),
        (H * 0.52, 220, 11, 0.8, CIColor(red: 0.16, green: 0.22, blue: 0.20), CIColor(red: 0.42, green: 0.46, blue: 0.38)),
        (H * 0.40, 160, 23, 1.0, CIColor(red: 0.08, green: 0.12, blue: 0.07), CIColor(red: 0.30, green: 0.40, blue: 0.20)),
    ]
    for (n, (base, amplitude, seed, depth, dark, light)) in ridges.enumerated() {
        let texture = tint(fbm(seedOffset: CGFloat(100 * n + 17), scales: [24, 8, 3, 1], weights: [0.45, 0.3, 0.17, 0.08])
            .transformed(by: CGAffineTransform(translationX: -pan * depth, y: 0)).cropped(to: canvas), dark, light)
        let mask = ridgeMask(base: base, amplitude: amplitude, seed: seed, pan: pan * depth)
        scene = texture.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: scene, kCIInputMaskImageKey: mask])
    }

    // Lake: dark water with horizontal ripples reflecting the sky.
    let ripples = fbm(seedOffset: 900, scales: [12, 4, 1.5], weights: [0.5, 0.35, 0.15])
        .transformed(by: CGAffineTransform(scaleX: 6, y: 0.5)).transformed(by: CGAffineTransform(translationX: -pan * 1.2, y: -t * 2))
        .cropped(to: canvas)
    let water = tint(ripples, CIColor(red: 0.05, green: 0.12, blue: 0.20), CIColor(red: 0.55, green: 0.70, blue: 0.85))
    let lakeTop = H * 0.28
    let lakeMask = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: W, height: lakeTop))
        .composited(over: CIImage(color: .black).cropped(to: canvas))
    scene = water.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: scene, kCIInputMaskImageKey: lakeMask])

    // Fine, sharp details: a few thin branches (1-3 px) and small text.
    let cs = CGColorSpaceCreateDeviceRGB()
    let cg = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    cg.setStrokeColor(CGColor(srgbRed: 0.05, green: 0.04, blue: 0.03, alpha: 1))
    for k in 0..<9 {
        let x0 = 300 + CGFloat(k) * 420 - pan * 1.6
        cg.setLineWidth(1 + CGFloat(k % 3))
        cg.move(to: CGPoint(x: x0, y: H * 0.05))
        cg.addCurve(to: CGPoint(x: x0 + 160, y: H * 0.32), control1: CGPoint(x: x0 - 60, y: H * 0.15), control2: CGPoint(x: x0 + 120, y: H * 0.2))
        cg.strokePath()
    }
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 26, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9)]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Test footage · fine detail 0123456789", attributes: attributes))
    cg.textPosition = CGPoint(x: 120 - pan, y: H * 0.9)
    CTLineDraw(line, cg)
    scene = CIImage(cgImage: cg.makeImage()!).composited(over: scene)
    return scene.cropped(to: canvas)
}

// Write ProRes 422 HQ at 30 fps (near-lossless reference).
try? FileManager.default.removeItem(at: out)
let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.proRes422HQ, AVVideoWidthKey: Int(W), AVVideoHeightKey: Int(H)])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,   // 16-bit: no sky banding kCVPixelBufferWidthKey as String: Int(W),
    kCVPixelBufferHeightKey as String: Int(H), kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
for i in 0..<frameCount {
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    CVBufferSetAttachment(pb!, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pb!, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
    ctx.render(render(frame: i), to: pb!, bounds: canvas, colorSpace: srgb)
    while !input.isReadyForMoreMediaData { usleep(1000) }
    adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
}
input.markAsFinished()
await writer.finishWriting()
print("wrote \(out.lastPathComponent): \(frameCount) frames, \(writer.status == .completed ? "ok" : String(describing: writer.error))")
