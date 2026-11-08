import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import Metal

/// A scene texture on the GPU, with what shaders and the renderer need to know about it.
final class GPUTexture {
    /// One texture per image of the `.tex` (sprite sheets have several).
    let images: [MTLTexture]
    /// The texture's size and the image's size inside it (the rest is padding).
    let width, height, imageWidth, imageHeight: Int
    let format: SceneTexture.Format
    let flags: SceneTexture.Flags
    let frames: [SceneTexture.Frame]
    let hasMips: Bool
    /// A video texture's frames (then `images` holds only a black stand-in).
    let video: VideoTexture?

    var texture: MTLTexture { images[0] }
    /// The texture to draw with at `time`: a video's frame due, or the first image.
    func texture(at time: Double) -> MTLTexture { video?.texture(at: time) ?? images[0] }
    /// `g_TextureNResolution`: texture size, then image size.
    var resolution: SIMD4<Float> { SIMD4(Float(width), Float(height), Float(imageWidth), Float(imageHeight)) }

    init(images: [MTLTexture], width: Int, height: Int, imageWidth: Int, imageHeight: Int,
         format: SceneTexture.Format = .rgba8, flags: SceneTexture.Flags = [], frames: [SceneTexture.Frame] = [],
         video: VideoTexture? = nil) {
        self.images = images
        self.video = video
        self.width = width
        self.height = height
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.format = format
        self.flags = flags
        self.frames = frames
        hasMips = images[0].mipmapLevelCount > 1
    }

    /// The texture and the part of it (UV origin and size) showing at `time`: the image without its padding, or the
    /// sprite frame due.
    func frame(at time: Double) -> (texture: MTLTexture, rect: SIMD4<Float>) {
        let image = SIMD4<Float>(0, 0, Float(imageWidth) / Float(width), Float(imageHeight) / Float(height))
        guard !frames.isEmpty else { return (texture(at: time), image) }
        let total = frames.reduce(0) { $0 + $1.duration }
        var t = total > 0 ? time.truncatingRemainder(dividingBy: total) : 0
        var frame = frames[0]
        for f in frames {
            frame = f
            if t < f.duration { break }
            t -= f.duration
        }
        return rectangle(of: frame)
    }

    /// Sprite-sheet frame `index` (wrapping), or the whole image when there are no frames.
    func frame(index: Int) -> (texture: MTLTexture, rect: SIMD4<Float>) {
        guard !frames.isEmpty else { return frame(at: 0) }
        return rectangle(of: frames[((index % frames.count) + frames.count) % frames.count])
    }

    private func rectangle(of frame: SceneTexture.Frame) -> (texture: MTLTexture, rect: SIMD4<Float>) {
        let texture = images[min(frame.image, images.count - 1)]
        let w = Float(texture.width), h = Float(texture.height)
        return (texture, SIMD4(Float(frame.x) / w, Float(frame.y) / h, Float(frame.width) / w, Float(frame.height) / h))
    }
}

/// Loads a scene's textures (`materials/<name>.tex`) onto the GPU once each, and makes the utility textures
/// (`util/white`, `util/noise`…) that scenes expect from Wallpaper Engine when the package doesn't carry them.
final class TextureStore {
    let device: MTLDevice
    let files: SceneFiles
    private let queue: MTLCommandQueue
    private var cache: [String: GPUTexture?] = [:]
    /// Textures that couldn't be loaded, with why.
    private(set) var problems: [String: String] = [:]
    /// Wallpaper Engine's built-in textures drawn by AerialSwap instead (particle shapes the package doesn't carry).
    private(set) var substituted: Set<String> = []
    private var videos: [VideoTexture] = []

    init(device: MTLDevice, queue: MTLCommandQueue, files: SceneFiles) {
        self.device = device
        self.queue = queue
        self.files = files
    }

    /// The texture a material names (`"masks/foo"`, `"util/white"`), or nil when it's missing or unreadable.
    func texture(_ name: String) -> GPUTexture? {
        if let cached = cache[name] { return cached }
        var path = name.hasPrefix("materials/") ? name : "materials/" + name
        if !path.hasSuffix(".tex") { path += ".tex" }
        var texture: GPUTexture?
        if let data = files.data(path) {
            do {
                texture = try load(SceneTexture(data: data, name: path), name: path)
            } catch {
                problems[name] = "\(error)"
            }
        } else if let utility = utility(name) {
            texture = utility
        } else if name.hasPrefix("particle/"), let shape = particle(name) {
            texture = shape
            substituted.insert(name)
        } else {
            problems[name] = "missing"
        }
        cache[name] = texture
        return texture
    }

    /// A text layer's texture, drawn now and then found under `name` like any texture; nil when there's nothing to draw.
    func text(_ name: String, _ text: SceneText) -> GPUTexture? {
        if let cached = cache[name] { return cached }
        var texture: GPUTexture?
        if let raster = text.raster(files: files) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: raster.width,
                                                                      height: raster.height, mipmapped: true)
            descriptor.usage = .shaderRead
            if let image = device.makeTexture(descriptor: descriptor) {
                image.replace(region: MTLRegionMake2D(0, 0, raster.width, raster.height), mipmapLevel: 0,
                              withBytes: raster.pixels, bytesPerRow: raster.width * 4)
                if let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
                    blit.generateMipmaps(for: image)
                    blit.endEncoding()
                    commands.commit()
                }
                texture = GPUTexture(images: [image], width: raster.width, height: raster.height,
                                     imageWidth: raster.width, imageHeight: raster.height, flags: [.clampUVs])
            }
        }
        cache[name] = texture
        return texture
    }

    /// Lets go of the video frames drawn so far; call once the GPU has finished the frame.
    func frameDone() {
        for video in videos { video.release() }
    }

    /// A 1×1 texture of one color, for empty slots.
    lazy var white = solid([255, 255, 255, 255])
    lazy var black = solid([0, 0, 0, 255])

    // MARK: - Loading

    private func load(_ tex: SceneTexture, name: String) throws -> GPUTexture {
        let images: [MTLTexture]
        switch tex.encoding {
        case .raw: images = try tex.images.map { try raw($0, format: tex.format) }
        case .png, .jpeg: images = try tex.images.map { try encoded($0[0], width: tex.textureWidth, height: tex.textureHeight) }
        case .mp4:
            let video = try VideoTexture(data: tex.images[0][0].data, name: name, device: device)
            videos.append(video)
            return GPUTexture(images: [black.texture], width: video.width, height: video.height, imageWidth: video.width,
                              imageHeight: video.height, flags: tex.flags, video: video)
        }
        // A raw texture's first mip is the whole texture; encoded images may come without padding.
        let width = images[0].width, height = images[0].height
        return GPUTexture(images: images, width: width, height: height,
                          imageWidth: min(tex.imageWidth, width), imageHeight: min(tex.imageHeight, height),
                          format: tex.encoding == .raw ? tex.format : .rgba8, flags: tex.flags, frames: tex.frames)
    }

    private func raw(_ mips: [SceneTexture.Mip], format: SceneTexture.Format) throws -> MTLTexture {
        let pixelFormat: MTLPixelFormat = switch format {
        case .rgba8: .rgba8Unorm
        case .rg8: .rg8Unorm
        case .r8: .r8Unorm
        case .dxt1: .bc1_rgba
        case .dxt3: .bc2_rgba
        case .dxt5: .bc3_rgba
        }
        let base = mips[0]
        // Only a full chain of halving mips can be uploaded as Metal mip levels.
        var levels = 1
        while levels < mips.count, mips[levels].width == max(1, base.width >> levels),
              mips[levels].height == max(1, base.height >> levels) { levels += 1 }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: base.width, height: base.height,
                                                                  mipmapped: false)
        descriptor.mipmapLevelCount = levels
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw SceneError.tooLarge("A texture") }
        for (level, mip) in mips.prefix(levels).enumerated() {
            let isBlock = [.dxt1, .dxt3, .dxt5].contains(format)
            let rowBytes = isBlock ? ((mip.width + 3) / 4) * (format == .dxt1 ? 8 : 16)
                : mip.width * (format == .rgba8 ? 4 : format == .rg8 ? 2 : 1)
            mip.data.withUnsafeBytes { bytes in
                texture.replace(region: MTLRegionMake2D(0, 0, mip.width, mip.height), mipmapLevel: level,
                                withBytes: bytes.baseAddress!, bytesPerRow: rowBytes)
            }
        }
        return texture
    }

    /// A PNG or JPEG image, decoded with straight alpha (shaders expect it) into a texture of at least the `.tex`'s size.
    private func encoded(_ mip: SceneTexture.Mip, width: Int, height: Int) throws -> MTLTexture {
        guard let source = CGImageSourceCreateWithData(mip.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width <= SceneLimits.maxTextureSide, image.height <= SceneLimits.maxTextureSide,
              var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue))
        else { throw SceneError.malformed("An image in a texture") }
        var buffer = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            throw SceneError.malformed("An image in a texture")
        }
        defer { free(buffer.data) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: max(width, image.width), height: max(height, image.height), mipmapped: true)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw SceneError.tooLarge("A texture") }
        texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                        withBytes: buffer.data, bytesPerRow: buffer.rowBytes)
        if let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
        }
        return texture
    }

    // MARK: - Utility textures

    /// AerialSwap's own versions of Wallpaper Engine's `materials/util` textures.
    private func utility(_ name: String) -> GPUTexture? {
        switch name {
        case "util/white": white
        case "util/black": black
        case "util/transparent": solid([0, 0, 0, 0])
        case "util/noflow": solid([128, 128, 0, 255])
        case "util/noise": pixels(256, 256) { _, _, random in [random(), random(), random(), random()] }
        case "util/clouds_256": clouds(256)
        case let n where n.hasPrefix("gradient/gradient_fire"):
            // Black through red, orange and yellow to white.
            pixels(256, 1) { x, _, _ in
                let t = Double(x) / 255
                return [UInt8(min(1, t * 2.5) * 255), UInt8(max(0, min(1, t * 2.5 - 0.8)) * 255), UInt8(max(0, t * 3 - 2) * 255), 255]
            }
        case let n where n.hasPrefix("util/gradient") || n.hasPrefix("gradient/"):
            pixels(256, 1) { x, _, _ in let v = UInt8(x); return [v, v, v, 255] }
        default: nil
        }
    }

    /// A stand-in for one of Wallpaper Engine's particle textures, by what its name says it is: fog and smoke are soft
    /// noisy clouds, drops and rain are streaks, leaves are leaves, halos are rings, and anything else is a soft dot.
    private func particle(_ name: String) -> GPUTexture? {
        let n = name.lowercased()
        let size = 128
        func shape(_ alpha: @escaping (Float, Float) -> Float, color: @escaping (Float, Float) -> SIMD3<Float> = { _, _ in .one }) -> GPUTexture? {
            pixels(size, size) { x, y, _ in
                // -1…1 across the texture.
                let u = (Float(x) + 0.5) / Float(size) * 2 - 1, v = (Float(y) + 0.5) / Float(size) * 2 - 1
                let a = min(max(alpha(u, v), 0), 1), c = color(u, v)
                return [UInt8(min(max(c.x, 0), 1) * 255), UInt8(min(max(c.y, 0), 1) * 255), UInt8(min(max(c.z, 0), 1) * 255), UInt8(a * 255)]
            }
        }
        if ["fog", "cloud", "smoke", "mist", "vapor", "steam", "dust"].contains(where: n.contains) {
            var lattice: [Float] = []
            var random = RandomSource(seed: 77)
            for _ in 0 ..< 16 * 16 { lattice.append(random.next()) }
            func noise(_ x: Float, _ y: Float, _ cells: Int) -> Float {
                let fx = (x * 0.5 + 0.5) * Float(cells), fy = (y * 0.5 + 0.5) * Float(cells)
                let ix = Int(fx), iy = Int(fy), tx = fx - Float(ix), ty = fy - Float(iy)
                func at(_ i: Int, _ j: Int) -> Float { lattice[(j % cells) * 16 + (i % cells)] }
                let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
                let top = at(ix, iy) + (at(ix + 1, iy) - at(ix, iy)) * sx
                return top + (at(ix, iy + 1) + (at(ix + 1, iy + 1) - at(ix, iy + 1)) * sx - top) * sy
            }
            return shape { u, v in
                let falloff = max(0, 1 - (u * u + v * v))
                let cloud = noise(u, v, 4) * 0.55 + noise(u, v, 8) * 0.3 + noise(u, v, 16) * 0.15
                return falloff * falloff * (0.35 + cloud)
            }
        }
        if ["drop", "rain", "streak", "line"].contains(where: n.contains) {
            return shape { u, v in max(0, 1 - abs(u) * 6) * max(0, 1 - v * v) }
        }
        if ["leaf", "leaves", "petal"].contains(where: n.contains) {
            // A pointed leaf along the diagonal with a darker middle vein.
            return shape({ u, v in
                let a = (u + v) * 0.7071, b = (v - u) * 0.7071
                let width = 0.45 * max(0, 1 - a * a)
                return (abs(b) < width ? 1 : 0) * (abs(a) < 0.95 ? 1 : 0)
            }, color: { u, v in
                let b = (v - u) * 0.7071
                return SIMD3(0.85, 0.45, 0.12) * (abs(b) < 0.03 ? 0.6 : 1)
            })
        }
        if n.contains("halo") || n.contains("ring") {
            return shape { u, v in let r = (u * u + v * v).squareRoot(); return max(0, 1 - abs(r - 0.8) * 8) }
        }
        return shape { u, v in let r = min(1, (u * u + v * v).squareRoot()); return (1 - r) * (1 - r) }
    }

    private func solid(_ color: [UInt8]) -> GPUTexture {
        pixels(1, 1) { _, _, _ in color }!
    }

    /// A texture from a per-pixel function (x, y, a seeded random byte source) → RGBA.
    private func pixels(_ width: Int, _ height: Int, _ pixel: (Int, Int, () -> UInt8) -> [UInt8]) -> GPUTexture? {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> UInt8 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 56)
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for y in 0 ..< height { for x in 0 ..< width { bytes += pixel(x, y, random) } }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return GPUTexture(images: [texture], width: width, height: height, imageWidth: width, imageHeight: height)
    }

    /// Soft tiling value noise in a few octaves, grey with full alpha.
    private func clouds(_ size: Int) -> GPUTexture? {
        var lattice: [[Double]] = []
        var state: UInt64 = 12345
        for _ in 0 ..< 5 {
            lattice.append((0 ..< 64 * 64).map { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Double(state >> 11) / Double(1 << 53)
            })
        }
        func noise(_ octave: Int, _ x: Double, _ y: Double, cells: Int) -> Double {
            let fx = x * Double(cells), fy = y * Double(cells)
            let x0 = Int(fx), y0 = Int(fy), tx = fx - Double(x0), ty = fy - Double(y0)
            func at(_ i: Int, _ j: Int) -> Double { lattice[octave][(j % cells) * 64 + (i % cells)] }
            let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
            let top = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * sx
            let bottom = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * sx
            return top + (bottom - top) * sy
        }
        return pixels(size, size) { x, y, _ in
            var value = 0.0, weight = 0.5, total = 0.0
            for octave in 0 ..< 5 {
                value += noise(octave, Double(x) / Double(size), Double(y) / Double(size), cells: 4 << octave) * weight
                total += weight
                weight *= 0.5
            }
            let v = UInt8(max(0, min(255, value / total * 255)))
            return [v, v, v, 255]
        }
    }
}
