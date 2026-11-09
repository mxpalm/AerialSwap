import Foundation

/// Caps on what a wallpaper's files may ask for. Workshop items are uploads from anyone, and the numbers in them
/// decide allocations, loop counts and texture sizes, so every one is bounded before it's used.
public enum SceneLimits {
    /// Largest file read from a package or folder (a 4K video texture fits).
    public static let maxFileBytes = 512 << 20
    /// Files in one package.
    public static let maxPackageEntries = 65_536
    /// Widest texture side, in pixels (Metal's limit on Apple GPUs).
    public static let maxTextureSide = 16_384
    /// Bytes all mips of one texture may decode to (two 8K RGBA atlases).
    public static let maxTextureBytes = 2 * 8192 * 8192 * 4
    /// Images (sprite frames or animation images) in one texture, and frames in its sprite sheet.
    public static let maxTextureImages = 64
    public static let maxSpriteFrames = 4096
    /// Mip levels in one image.
    public static let maxMips = 16
    /// Objects in one scene, effects on one layer, passes in one material or effect.
    public static let maxObjects = 4096
    public static let maxEffects = 64
    public static let maxPasses = 32
    /// Shader source after includes, in bytes, and how deep includes may nest.
    public static let maxShaderBytes = 1 << 20
    public static let maxIncludeDepth = 8
    /// Scripts in one scene, and the size of one.
    public static let maxScripts = 1024
    public static let maxScriptBytes = 256 << 10
    /// Largest puppet-warp model (`.mdl`): its vertices are moved on the CPU every frame.
    public static let maxPuppetBytes = 16 << 20
    /// JSON nesting depth.
    public static let maxJSONDepth = 64
}

public enum SceneError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case missing(String)
    case tooLarge(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .malformed(let what): "\(what) is damaged or in an unknown format"
        case .missing(let what): "\(what) is missing"
        case .tooLarge(let what): "\(what) is larger than AerialSwap accepts"
        case .unsupported(let what): "\(what) isn't supported yet"
        }
    }
}

/// Little-endian reads over a package or texture, each checked against the data's end.
struct BinaryReader {
    let data: Data
    private(set) var offset = 0
    /// What is being read, for error messages.
    let name: String

    init(_ data: Data, name: String) {
        self.data = data
        self.name = name
    }

    var remaining: Int { data.count - offset }

    mutating func uint32() throws -> UInt32 {
        guard remaining >= 4 else { throw SceneError.malformed(name) }
        let start = data.startIndex + offset
        let value = data[start ..< start + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        offset += 4
        return UInt32(littleEndian: value)
    }

    mutating func int32() throws -> Int32 { Int32(bitPattern: try uint32()) }

    mutating func float32() throws -> Float { Float(bitPattern: try uint32()) }

    /// A count or size that must lie in `range`.
    mutating func count(in range: ClosedRange<Int>, _ what: String) throws -> Int {
        let value = Int(try int32())
        guard range.contains(value) else { throw SceneError.malformed("\(name) (\(what) \(value))") }
        return value
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw SceneError.malformed(name) }
        let start = data.startIndex + offset
        offset += count
        return data.subdata(in: start ..< start + count)
    }

    /// A string with a 32-bit length in front (package names and magics).
    mutating func lengthPrefixedString(max: Int = 4096) throws -> String {
        let length = try count(in: 0 ... max, "string length")
        guard let string = String(data: try bytes(length), encoding: .utf8) else { throw SceneError.malformed(name) }
        return string
    }

    /// A NUL-terminated magic like `TEXV0005` (at most 16 bytes).
    mutating func magic() throws -> String {
        let start = data.startIndex + offset
        let end = data.index(start, offsetBy: min(16, remaining))
        guard let nul = data[start ..< end].firstIndex(of: 0),
              let string = String(data: data[start ..< nul], encoding: .ascii) else { throw SceneError.malformed(name) }
        offset += nul - start + 1
        return string
    }
}
