import Compression
import Foundation

/// A Wallpaper Engine `.tex`: `TEXV0005` and `TEXI0001` magics, the pixel format, flags, the texture's (often padded,
/// power-of-two) size and the image's size inside it, then a `TEXB000N` block with one or more images, each a chain of
/// mips. A mip is raw pixels (maybe LZ4-compressed), or a whole PNG/JPEG file when the block names an image format.
/// Animated textures add a `TEXS000N` sprite sheet: which image and part of it each frame shows, and for how long.
public struct SceneTexture: Sendable {
    /// Wallpaper Engine's pixel formats (shaders see them as `TEXnFORMAT`).
    public enum Format: Int32, Sendable {
        case rgba8 = 0, dxt5 = 4, dxt3 = 6, dxt1 = 7, rg8 = 8, r8 = 9
    }

    public struct Flags: OptionSet, Sendable {
        public let rawValue: Int32
        public init(rawValue: Int32) { self.rawValue = rawValue }
        public static let pointFilter = Flags(rawValue: 1)
        public static let clampUVs = Flags(rawValue: 2)
        public static let sprite = Flags(rawValue: 4)
        /// The mip is a whole MP4 file: a video texture.
        public static let video = Flags(rawValue: 32)
    }

    public struct Mip: Sendable {
        public let width: Int
        public let height: Int
        /// Raw pixels in `format` (decompressed), or a whole PNG, JPEG or MP4 file (see `encoding`).
        public let data: Data
    }

    public enum Encoding: Sendable, Equatable { case raw, png, jpeg, mp4 }

    /// One sprite-sheet frame: an image, a rectangle in it (in pixels of that image), and how long it shows.
    public struct Frame: Sendable, Equatable {
        public let image: Int
        public let duration: Double
        public let x, y, width, height: Double
    }

    public let format: Format
    public let flags: Flags
    public let textureWidth, textureHeight: Int
    public let imageWidth, imageHeight: Int
    public let encoding: Encoding
    /// images[i] = the mips of image i, largest first.
    public let images: [[Mip]]
    public let frames: [Frame]

    public init(data: Data, name: String) throws {
        var r = BinaryReader(data, name: name)
        guard try r.magic() == "TEXV0005", try r.magic() == "TEXI0001" else { throw SceneError.malformed(name) }
        guard let format = Format(rawValue: try r.int32()) else { throw SceneError.unsupported("The texture format of \(name)") }
        self.format = format
        flags = Flags(rawValue: try r.int32())
        let side = 1 ... SceneLimits.maxTextureSide
        textureWidth = try r.count(in: side, "width")
        textureHeight = try r.count(in: side, "height")
        imageWidth = try r.count(in: side, "image width")
        imageHeight = try r.count(in: side, "image height")
        _ = try r.uint32()

        let block = try r.magic()
        guard let blockVersion = ["TEXB0001": 1, "TEXB0002": 2, "TEXB0003": 3, "TEXB0004": 4][block] else {
            throw SceneError.unsupported("Texture block \(block) in \(name)")
        }
        let imageCount = try r.count(in: 1 ... SceneLimits.maxTextureImages, "image count")
        var imageFormat: Int32 = -1
        if blockVersion >= 3 { imageFormat = try r.int32() }
        let isVideo = try (blockVersion >= 4 && r.int32() != 0) || flags.contains(.video)
        // FreeImage's format codes: 13 PNG, 2 JPEG; -1 raw pixels.
        encoding = switch imageFormat {
        case _ where isVideo: .mp4
        case -1: .raw
        case 13: .png
        case 2: .jpeg
        default: throw SceneError.unsupported("Image format \(imageFormat) in \(name)")
        }

        var budget = SceneLimits.maxTextureBytes
        var images: [[Mip]] = []
        for _ in 0 ..< imageCount {
            let mipCount = try r.count(in: 1 ... SceneLimits.maxMips, "mip count")
            var mips: [Mip] = []
            for _ in 0 ..< mipCount {
                let width = try r.count(in: side, "mip width"), height = try r.count(in: side, "mip height")
                var compressed = false, rawSize = 0
                if blockVersion >= 2 {
                    compressed = try r.int32() != 0
                    rawSize = try r.count(in: 0 ... SceneLimits.maxTextureBytes, "decompressed size")
                }
                let size = try r.count(in: 0 ... min(r.remaining, SceneLimits.maxTextureBytes), "mip size")
                var bytes = try r.bytes(size)
                if compressed {
                    guard rawSize <= budget else { throw SceneError.tooLarge(name) }
                    bytes = try Self.lz4(bytes, size: rawSize, name: name)
                }
                if encoding == .raw {
                    guard bytes.count >= Self.byteCount(format, width: width, height: height) else { throw SceneError.malformed(name) }
                }
                budget -= bytes.count
                guard budget >= 0 else { throw SceneError.tooLarge(name) }
                mips.append(Mip(width: width, height: height, data: bytes))
            }
            images.append(mips)
        }
        self.images = images

        var frames: [Frame] = []
        if flags.contains(.sprite), r.remaining > 0 {
            let sheet = try r.magic()
            guard let sheetVersion = ["TEXS0001": 1, "TEXS0002": 2, "TEXS0003": 3][sheet] else {
                throw SceneError.unsupported("Sprite sheet \(sheet) in \(name)")
            }
            let count = try r.count(in: 0 ... SceneLimits.maxSpriteFrames, "frame count")
            if sheetVersion >= 3 { _ = try r.int32(); _ = try r.int32() }   // the sheet's own size
            for _ in 0 ..< count {
                let image = try r.count(in: 0 ... imageCount - 1, "frame image")
                let duration = Double(try r.float32())
                // TEXS0001 stores the rectangle as integers, later versions as floats; each as x, y, width, (skew),
                // (skew), height.
                var values: [Double] = []
                for _ in 0 ..< 6 { values.append(sheetVersion == 1 ? Double(try r.int32()) : Double(try r.float32())) }
                guard duration.isFinite, values.allSatisfy(\.isFinite) else { throw SceneError.malformed(name) }
                frames.append(Frame(image: image, duration: max(0, duration), x: values[0], y: values[1],
                                    width: values[2], height: values[5]))
            }
        }
        self.frames = frames
    }

    /// Bytes a raw mip needs: 4×4 blocks of 8 (DXT1) or 16 (DXT3/5) bytes, else 1, 2 or 4 bytes per pixel.
    public static func byteCount(_ format: Format, width: Int, height: Int) -> Int {
        let blocks = ((width + 3) / 4) * ((height + 3) / 4)
        return switch format {
        case .dxt1: blocks * 8
        case .dxt3, .dxt5: blocks * 16
        case .r8: width * height
        case .rg8: width * height * 2
        case .rgba8: width * height * 4
        }
    }

    private static func lz4(_ input: Data, size: Int, name: String) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, size,
                                          inp.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard written == size else { throw SceneError.malformed(name) }
        return output
    }
}
