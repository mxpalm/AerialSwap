import Foundation
import simd

/// A puppet-warp model (`.mdl`, as Wallpaper Engine's editor saves it): a mesh over the layer's image, bones that move
/// its vertices, and the bones' animations. Read from untrusted files, so every count and size is checked against what
/// is left of the file.
///
/// Layout (little endian, version MDLV0023): `MDLVnnnn\0`, three u32, the material path (C string), 28 bytes, the
/// vertex format (u32) and the vertices' byte count, the vertices (80 bytes each: position, normal, tangent, four bone
/// indices, four weights, texture coordinates), the indices' byte count and the indices (u16 triangles). Then
/// `MDLSnnnn\0`: end offset, bone count, and per bone its name (C string), a type, its parent (-1 for none), the
/// matrix size (64) and its bind matrix (model space, column major); physics data follows. Then `MDLAnnnn\0`: end
/// offset, animation count, and per animation its id, a u32, name and mode (C strings), frame rate (f32), length in
/// frames, a u32, the track count, the tracks (bone index, byte count, then length + 1 frames of position, angles and
/// scale: 9 f32) and 35 bytes.
public struct ScenePuppet: Sendable {
    public struct Vertex: Sendable {
        public var position: SIMD2<Float>
        public var bones: SIMD4<UInt32>
        public var weights: SIMD4<Float>
        public var uv: SIMD2<Float>
    }

    public struct Bone: Sendable {
        public var parent: Int?
        /// Where the bone is at rest, in model space.
        public var bind: simd_float4x4
    }

    /// A bone's place in one frame, relative to its parent.
    public struct Pose: Sendable {
        public var position: SIMD3<Float>
        public var angles: SIMD3<Float>
        public var scale: SIMD3<Float>

        var matrix: simd_float4x4 {
            func rotation(_ angle: Float, _ axis: SIMD3<Float>) -> simd_float4x4 {
                simd_float4x4(simd_quatf(angle: angle, axis: axis))
            }
            var m = rotation(angles.z, SIMD3(0, 0, 1)) * rotation(angles.y, SIMD3(0, 1, 0)) * rotation(angles.x, SIMD3(1, 0, 0))
            m.columns.3 = SIMD4(position, 1)
            return m * simd_float4x4(diagonal: SIMD4(scale, 1))
        }

        static func mix(_ a: Pose, _ b: Pose, _ t: Float) -> Pose {
            Pose(position: simd_mix(a.position, b.position, SIMD3(repeating: t)), angles: simd_mix(a.angles, b.angles, SIMD3(repeating: t)),
                 scale: simd_mix(a.scale, b.scale, SIMD3(repeating: t)))
        }
    }

    public struct Animation: Sendable {
        public enum Mode: String, Sendable { case loop, mirror, single }
        public var id: Int
        public var name: String
        public var mode: Mode
        public var fps: Double
        /// Length in frames (each track has one more: the last frame is the first again).
        public var length: Int
        /// Frames by bone index.
        public var tracks: [Int: [Pose]]

        public var duration: Double { fps > 0 ? Double(length) / fps : 0 }

        /// The bone's pose `time` seconds in (loops, plays back and forth, or stops at the end), nil without a track.
        func pose(bone: Int, time: Double) -> Pose? {
            guard let frames = tracks[bone], !frames.isEmpty else { return nil }
            guard length > 0, fps > 0 else { return frames[0] }
            let total = Double(length)
            var f = time * fps
            switch mode {
            case .loop: f = f.truncatingRemainder(dividingBy: total); if f < 0 { f += total }
            case .mirror:
                f = f.truncatingRemainder(dividingBy: 2 * total); if f < 0 { f += 2 * total }
                if f > total { f = 2 * total - f }
            case .single: f = min(max(f, 0), total)
            }
            let i = min(Int(f), frames.count - 1), j = min(i + 1, frames.count - 1)
            return Pose.mix(frames[i], frames[j], Float(f - Double(i)))
        }
    }

    public let vertices: [Vertex]
    /// Triangles, three indices each.
    public let indices: [Int]
    public let bones: [Bone]
    public let animations: [Animation]

    static let maxBones = 1024
    static let maxAnimations = 256

    public init(data: Data, name: String) throws {
        var r = Reader(data: data, name: name)
        guard try r.string().hasPrefix("MDLV") else { throw SceneError.malformed(name) }
        _ = try r.u32(); _ = try r.u32(); _ = try r.u32()
        _ = try r.string()   // the material; the layer's own material is used
        try r.skip(28)
        let format = try r.u32()
        let stride = 80
        guard format == 0x0180_000F else { throw SceneError.unsupported("Puppet meshes of format \(String(format, radix: 16))") }
        let vertexBytes = try r.count(of: 1)
        guard vertexBytes % stride == 0 else { throw SceneError.malformed(name) }
        var vertices: [Vertex] = []
        vertices.reserveCapacity(vertexBytes / stride)
        for _ in 0 ..< vertexBytes / stride {
            let p = SIMD2(try r.f32(), try r.f32())
            try r.skip(4 + 12 + 16)   // z, normal, tangent
            let bones = SIMD4<UInt32>(UInt32(try r.u32()), UInt32(try r.u32()), UInt32(try r.u32()), UInt32(try r.u32()))
            let weights = SIMD4(try r.f32(), try r.f32(), try r.f32(), try r.f32())
            let uv = SIMD2(try r.f32(), try r.f32())
            vertices.append(Vertex(position: p, bones: bones, weights: weights, uv: uv))
        }
        let indexBytes = try r.count(of: 1)
        guard indexBytes % 6 == 0 else { throw SceneError.malformed(name) }
        var indices: [Int] = []
        indices.reserveCapacity(indexBytes / 2)
        for _ in 0 ..< indexBytes / 2 {
            let i = Int(try r.u16())
            guard i < vertices.count else { throw SceneError.malformed(name) }
            indices.append(i)
        }

        // Skeleton.
        try r.seek(toMarker: "MDLS")
        _ = try r.string()
        _ = try r.u32()
        let boneCount = try r.u32()
        guard (1 ... Self.maxBones).contains(boneCount) else { throw SceneError.malformed(name) }
        var bones: [Bone] = []
        for _ in 0 ..< boneCount {
            _ = try r.string()
            _ = try r.u32()
            let parent = Int(Int32(bitPattern: UInt32(try r.u32())))
            guard try r.u32() == 64 else { throw SceneError.malformed(name) }
            var m = simd_float4x4()
            for c in 0 ..< 4 { m[c] = SIMD4(try r.f32(), try r.f32(), try r.f32(), try r.f32()) }
            guard (0 ..< 4).allSatisfy({ c in (0 ..< 4).allSatisfy { m[c][$0].isFinite } }) else { throw SceneError.malformed(name) }
            bones.append(Bone(parent: parent >= 0 && parent < bones.count ? parent : nil, bind: m))
        }
        guard vertices.allSatisfy({ v in (0 ..< 4).allSatisfy { v.weights[$0] == 0 || Int(v.bones[$0]) < bones.count } }) else {
            throw SceneError.malformed(name)
        }

        // Animations: a model without them stays at rest.
        var animations: [Animation] = []
        if (try? r.seek(toMarker: "MDLA")) != nil {
            _ = try r.string()
            _ = try r.u32()
            let count = try r.u32()
            guard count <= Self.maxAnimations else { throw SceneError.malformed(name) }
            for _ in 0 ..< count {
                let id = try r.u32()
                _ = try r.u32()
                let animationName = try r.string()
                let mode = Animation.Mode(rawValue: try r.string().lowercased()) ?? .loop
                let fps = Double(try r.f32())
                let length = try r.u32()
                _ = try r.u32()
                let trackCount = try r.u32()
                guard trackCount <= bones.count, fps.isFinite, fps >= 0, fps <= 1000 else { throw SceneError.malformed(name) }
                var tracks: [Int: [Pose]] = [:]
                for _ in 0 ..< trackCount {
                    let bone = try r.u32()
                    let bytes = try r.count(of: 1)
                    guard bone < bones.count, bytes % 36 == 0 else { throw SceneError.malformed(name) }
                    var frames: [Pose] = []
                    frames.reserveCapacity(bytes / 36)
                    for _ in 0 ..< bytes / 36 {
                        let values = try (0 ..< 9).map { _ in try r.f32() }
                        guard values.allSatisfy(\.isFinite) else { throw SceneError.malformed(name) }
                        frames.append(Pose(position: SIMD3(values[0], values[1], values[2]),
                                           angles: SIMD3(values[3], values[4], values[5]), scale: SIMD3(values[6], values[7], values[8])))
                    }
                    tracks[bone] = frames
                }
                animations.append(Animation(id: id, name: animationName, mode: mode, fps: fps,
                                            length: min(length, (tracks.values.map(\.count).min() ?? 1) - 1), tracks: tracks))
                guard (try? r.skip(35)) != nil else { break }
            }
        }
        self.vertices = vertices
        self.indices = indices
        self.bones = bones
        self.animations = animations
    }

    /// One animation a layer plays (scene.json's `animationlayers`).
    public struct Layer: Sendable, Equatable {
        public var animation: Int
        public var rate: Double
        public var blend: Double
        public var additive: Bool
        public var visible: Bool
    }

    /// Vertex positions (model space) `time` seconds into the layers' animations. Bones no layer moves stay at rest.
    public func positions(layers: [Layer], time: Double) -> [SIMD2<Float>] {
        let byID = Dictionary(animations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let playing = layers.compactMap { layer in byID[layer.animation].map { ($0, layer) } }.filter { $0.1.visible && $0.1.blend > 0 }
        var global = [simd_float4x4](repeating: matrix_identity_float4x4, count: bones.count)
        for (index, bone) in bones.enumerated() {
            let parentGlobal = bone.parent.map { global[$0] } ?? matrix_identity_float4x4
            let parentBind = bone.parent.map { bones[$0].bind } ?? matrix_identity_float4x4
            var local = parentBind.inverse * bone.bind   // at rest
            var total: Float = 0
            var blended: Pose?
            for (animation, layer) in playing where !layer.additive {
                guard let pose = animation.pose(bone: index, time: time * layer.rate) else { continue }
                let w = Float(min(layer.blend, 1))
                blended = blended.map { Pose.mix($0, pose, w / (total + w)) } ?? pose
                total += w
            }
            if let blended {
                local = total >= 1 ? blended.matrix : Self.mix(local, blended.matrix, total)
            }
            global[index] = parentGlobal * local
        }
        var skin: [simd_float4x4] = []
        skin.reserveCapacity(bones.count)
        for (index, bone) in bones.enumerated() { skin.append(global[index] * bone.bind.inverse) }
        return vertices.map { v in
            let rest = SIMD4<Float>(v.position.x, v.position.y, 0, 1)
            var p = SIMD4<Float>.zero
            var weight: Float = 0
            for i in 0 ..< 4 where v.weights[i] > 0 {
                let moved: SIMD4<Float> = skin[Int(v.bones[i])] * rest
                p += v.weights[i] * moved
                weight += v.weights[i]
            }
            guard weight > 0 else { return v.position }
            return SIMD2<Float>(p.x, p.y) / weight
        }
    }

    private static func mix(_ a: simd_float4x4, _ b: simd_float4x4, _ t: Float) -> simd_float4x4 {
        simd_float4x4(columns: (simd_mix(a.columns.0, b.columns.0, SIMD4(repeating: t)), simd_mix(a.columns.1, b.columns.1, SIMD4(repeating: t)),
                                simd_mix(a.columns.2, b.columns.2, SIMD4(repeating: t)), simd_mix(a.columns.3, b.columns.3, SIMD4(repeating: t))))
    }

    /// Bounds-checked little-endian reads.
    private struct Reader {
        let data: Data
        let name: String
        var offset: Int

        init(data: Data, name: String) {
            self.data = data
            self.name = name
            offset = data.startIndex
        }

        mutating func bytes(_ n: Int) throws -> Data {
            guard n >= 0, offset + n <= data.endIndex else { throw SceneError.malformed(name) }
            defer { offset += n }
            return data[offset ..< offset + n]
        }

        mutating func skip(_ n: Int) throws { _ = try bytes(n) }

        mutating func u16() throws -> UInt16 { try bytes(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian } }
        mutating func u32() throws -> Int { Int(try bytes(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }) }
        mutating func f32() throws -> Float { Float(bitPattern: UInt32(try u32())) }

        /// A byte count that has to fit in what's left of the file.
        mutating func count(of size: Int) throws -> Int {
            let n = try u32()
            guard n * size <= data.endIndex - offset else { throw SceneError.malformed(name) }
            return n
        }

        mutating func string() throws -> String {
            guard let end = data[offset...].prefix(1024).firstIndex(of: 0) else { throw SceneError.malformed(name) }
            defer { offset = end + 1 }
            return String(decoding: data[offset ..< end], as: UTF8.self)
        }

        /// Moves to the next section marker (`MDLS`, `MDLA`).
        mutating func seek(toMarker marker: String) throws {
            guard let range = data[offset...].firstRange(of: Data(marker.utf8)) else { throw SceneError.malformed(name) }
            offset = range.lowerBound
        }
    }
}
