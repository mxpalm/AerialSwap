import CoreGraphics
import Foundation
import Metal
import simd

/// Draws a scene's frames with Metal. Image layers and particle systems draw in scene order onto the canvas, scaled
/// to fill the output.
/// A layer without effects draws straight onto the scene; one with effects is drawn into a buffer of its own size,
/// runs its effects' passes there (ping-ponging between two buffers, plus the buffers effects declare), and the result
/// is composited onto the scene with the layer's blending, color and alpha.
///
/// Conventions (Metal's match Direct3D's, which Wallpaper Engine's shaders are written for): scene units have y up
/// with the origin at the canvas's bottom left; texture coordinates start at the top left; passes into a layer's
/// buffers draw a clip-space quad with an identity model-view-projection matrix.
public final class SceneRenderer {
    public let width: Int
    public let height: Int

    private let document: SceneDocument
    private let files: SceneFiles
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let textures: TextureStore
    private let pipelines: PipelineCache
    private let target: MTLTexture
    private let background: MTLTexture
    private let projection: simd_float4x4
    private let items: [Item]
    private var particleMaterials: [String: SceneDocument.MaterialPass?] = [:]
    private var pool: [SIMD2<Int>: [MTLTexture]] = [:]
    private var samplers: [Int: MTLSamplerState] = [:]
    private var issues: Set<String>
    /// Results of layers others read, by layer id, for the frame being drawn.
    private var composites: [Int: MTLTexture] = [:]

    /// What the renderer had to leave out: passes whose shader didn't compile, textures that didn't load, objects it
    /// doesn't draw yet.
    public var problems: [String] {
        (issues.union(textures.problems.map { "Texture \($0.key): \($0.value)" })).sorted()
    }

    /// The loop the frames repeat in: times wrap around its period, particles repeat exactly, and the start of each
    /// period crossfades from the frame one period later (for effects that never repeat). Nil: the scene runs freely.
    public var loop: SceneLoop? {
        didSet {
            guard loop != oldValue else { return }
            for case .particles(let particles) in items { particles.system.loop(every: loop?.period) }
        }
    }

    /// `bufferScale` sizes the layers' buffers relative to their size in scene units (below 1 for quick previews; effects
    /// that measure in pixels then look a little different). Without `particles`, particle systems aren't drawn.
    public init(document: SceneDocument, files: SceneFiles, width: Int, height: Int, bufferScale: Double = 1,
                particles: Bool = true, device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw SceneError.unsupported("Rendering without Metal")
        }
        guard (1 ... 8192).contains(width), (1 ... 8192).contains(height) else { throw SceneError.tooLarge("The output size") }
        self.width = width
        self.height = height
        self.document = document
        self.files = files
        self.device = device
        self.queue = queue
        textures = TextureStore(device: device, queue: queue, files: files)
        pipelines = PipelineCache(device: device, files: files)

        func canvas(_ storage: MTLStorageMode) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                                      mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = storage
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw SceneError.tooLarge("The output size") }
            return texture
        }
        target = try canvas(.shared)
        background = try canvas(.private)

        // Aspect fill: the canvas covers the output, centered. z is kept (barely) so the matrix stays invertible.
        let w = Float(document.general.width), h = Float(document.general.height)
        let scale = max(Float(width) / w, Float(height) / h)
        projection = simd_float4x4(columns: (
            SIMD4(2 * scale / Float(width), 0, 0, 0), SIMD4(0, 2 * scale / Float(height), 0, 0),
            SIMD4(0, 0, 1e-6, 0), SIMD4(-w * scale / Float(width), -h * scale / Float(height), 0.5, 1)))

        var issues = Set<String>()
        items = Self.items(of: document, files: files, bufferScale: min(max(bufferScale, 0.05), 1), particles: particles,
                           issues: &issues)
        self.issues = issues
    }

    // MARK: - Layers and particle systems

    private enum Item {
        case layer(Layer)
        case particles(Particles)
    }

    private struct Particles {
        let name: String
        let system: ParticleSystem
        /// System units → scene units.
        let world: simd_float4x4
    }

    private struct Layer {
        let id: Int
        let name: String
        let image: SceneDocument.ImageLayer
        /// Layer units → scene units.
        let world: simd_float4x4
        /// The quad in layer units: top left, top right, bottom left, bottom right.
        let corners: [SIMD2<Float>]
        /// The size of the layer's buffers in pixels.
        let size: SIMD2<Int>
        /// The layer shows the scene behind it (compose, fullscreen and project layers).
        let compose: Bool
        let effects: [SceneDocument.Effect]
        let needsBackground: Bool
        /// Another layer reads this one's result (`_rt_imageLayerComposite_<id>_a`), so it's kept until the frame ends.
        let isReferenced: Bool
    }

    private static func items(of document: SceneDocument, files: SceneFiles, bufferScale: Double, particles: Bool,
                              issues: inout Set<String>) -> [Item] {
        let byID = Dictionary(document.objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func local(_ t: SceneDocument.Transform) -> simd_float4x4 {
            let c = Float(cos(t.angles.z)), s = Float(sin(t.angles.z))
            let translation = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
                                                       SIMD4(Float(t.origin.x), Float(t.origin.y), Float(t.origin.z), 1)))
            let rotation = simd_float4x4(columns: (SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
            let scale = simd_float4x4(diagonal: SIMD4(Float(t.scale.x), Float(t.scale.y), Float(t.scale.z), 1))
            return translation * rotation * scale
        }
        // Parents' transforms apply to their children; a hidden parent hides them.
        func placement(_ object: SceneDocument.Object, depth: Int = 0) -> (world: simd_float4x4, visible: Bool) {
            let own = local(object.transform)
            guard let id = object.parent, let parent = byID[id], parent.id != object.id, depth < 32 else { return (own, object.visible) }
            let above = placement(parent, depth: depth + 1)
            return (above.world * own, above.visible && object.visible)
        }

        // Names of the textures and buffers each image layer's passes read.
        var reads: [Int: [String]] = [:]
        for object in document.objects {
            guard case .image(let image) = object.kind else { continue }
            reads[object.id] = image.material.passes.flatMap(\.textures).compactMap { $0 }
                + image.effects.flatMap { $0.passes.flatMap { ($0.material?.passes.flatMap(\.textures).compactMap { $0 } ?? []) + $0.binds.map(\.name) } }
        }
        var referenced = Set<Int>()
        for (id, names) in reads {
            for name in names {
                guard let match = ShaderTranslator.matches(#"^_rt_imageLayerComposite_(\d+)_"#, in: name).first,
                      let other = Int(match[1]), other != id else { continue }
                referenced.insert(other)
            }
        }

        var items: [Item] = []
        for object in document.objects {
            switch object.kind {
            case .image(let image):
                var (world, visible) = placement(object)
                guard visible else { continue }
                var size = image.size ?? SIMD2(image.model.width ?? 0, image.model.height ?? 0)
                if image.model.fullscreen {
                    size = SIMD2(document.general.width, document.general.height)
                    world = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
                                                    SIMD4(Float(size.x / 2), Float(size.y / 2), 0, 1)))
                }
                guard size.x >= 1, size.y >= 1 else {
                    issues.insert("Layer “\(object.name)” has no size")
                    continue
                }
                let w = Float(size.x), h = Float(size.y)
                let alignment = image.alignment.lowercased()
                let left: Float = alignment.contains("left") ? 0 : alignment.contains("right") ? -w : -w / 2
                let bottom: Float = alignment.contains("top") ? -h : alignment.contains("bottom") ? 0 : -h / 2
                let effects = image.effects.filter { $0.visible && !$0.passes.isEmpty }
                let names = reads[object.id] ?? []
                let compose = image.model.compose
                items.append(.layer(Layer(
                    id: object.id, name: object.name, image: image, world: world,
                    corners: [SIMD2(left, bottom + h), SIMD2(left + w, bottom + h), SIMD2(left, bottom), SIMD2(left + w, bottom)],
                    size: SIMD2(min(8192, max(1, Int((size.x * bufferScale).rounded()))),
                                min(8192, max(1, Int((size.y * bufferScale).rounded())))),
                    compose: compose, effects: effects,
                    needsBackground: (compose && !effects.isEmpty) || image.colorBlendMode != 0 || names.contains("_rt_FullFrameBuffer"),
                    isReferenced: referenced.contains(object.id))))
            case .particle(let particle):
                let (world, visible) = placement(object)
                guard visible, particles else { continue }
                let system = ParticleSystem(definition: particle.definition, overrides: .init(particle.instanceOverride),
                                            seed: UInt64(UInt32(truncatingIfNeeded: object.id)) &+ 1) { path in
                    (try? files.json(path))?.resolvedDeep(document.properties)
                }
                for feature in system.unsupported { issues.insert("Particles “\(object.name)”: \(feature) isn't simulated") }
                items.append(.particles(Particles(name: object.name, system: system, world: world)))
            default:
                break
            }
        }
        return items
    }

    // MARK: - Frames

    /// Renders the frame at `time` (seconds) and returns the output texture (RGBA8, shared storage).
    @discardableResult
    public func render(time: Double) throws -> MTLTexture {
        guard let commands = queue.makeCommandBuffer() else { throw SceneError.unsupported("Rendering without Metal") }
        if let loop, loop.period > 0 {
            let t = time - (time / loop.period).rounded(.down) * loop.period
            encode(time: t, into: target, commands: commands)
            if t < loop.crossfade {
                // Fade in from one period later, which is where the previous period ended.
                let later = crossfadeTarget()
                encode(time: t + loop.period, into: later, commands: commands)
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .load
                pass.colorAttachments[0].storeAction = .store
                if let encoder = commands.makeRenderCommandEncoder(descriptor: pass),
                   let pipeline = try? pipelines.pipeline(pipelines.program("aerialswap/image"), combos: [:], blending: .translucent) {
                    let weight = Float(1 - t / loop.crossfade)
                    draw(pipeline, encoder: encoder, vertices: clipQuad(rectangle(SIMD4(0, 0, 1, 1))), slots: [0: buffer(later)],
                         system: system(mvp: matrix_identity_float4x4, model: matrix_identity_float4x4,
                                        color: SIMD4(1, 1, 1, weight), time: t))
                    encoder.endEncoding()
                }
            }
        } else {
            encode(time: time, into: target, commands: commands)
        }
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
        return target
    }

    private var crossfadeCanvas: MTLTexture?

    private func crossfadeTarget() -> MTLTexture {
        if let crossfadeCanvas { return crossfadeCanvas }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)!
        crossfadeCanvas = texture
        return texture
    }

    /// Encodes the scene at `time` into `output`.
    private func encode(time: Double, into output: MTLTexture, commands: MTLCommandBuffer) {
        let c = document.general.clearColor
        let frame = Frame(commands: commands, target: output,
                          clear: MTLClearColor(red: Double(c.x), green: Double(c.y), blue: Double(c.z), alpha: 1))
        for item in items {
            switch item {
            case .layer(let layer): draw(layer, time: time, frame: frame)
            case .particles(let particles):
                particles.system.advance(to: time)
                draw(particles.system, name: particles.name, world: particles.world, time: time, frame: frame)
            }
        }
        _ = frame.scene()
        frame.endScene()
        composites.values.forEach(give)
        composites = [:]
    }

    /// The frame at `time` as an opaque image.
    public func image(time: Double) throws -> CGImage {
        let texture = try render(time: time)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw SceneError.unsupported("Reading the frame back") }
        return image
    }

    /// The scene's render pass, opened when needed (the first one clears the output).
    private final class Frame {
        let commands: MTLCommandBuffer
        let target: MTLTexture
        private var encoder: MTLRenderCommandEncoder?
        private var clear: MTLClearColor?

        init(commands: MTLCommandBuffer, target: MTLTexture, clear: MTLClearColor) {
            self.commands = commands
            self.target = target
            self.clear = clear
        }

        func scene() -> MTLRenderCommandEncoder {
            if let encoder { return encoder }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = clear == nil ? .load : .clear
            pass.colorAttachments[0].clearColor = clear ?? MTLClearColor()
            pass.colorAttachments[0].storeAction = .store
            clear = nil
            let encoder = commands.makeRenderCommandEncoder(descriptor: pass)!
            self.encoder = encoder
            return encoder
        }

        /// Ends the scene's pass so others can run (it reopens on the next `scene()`); the clear still happens first.
        func endScene() {
            if clear != nil { _ = scene() }
            encoder?.endEncoding()
            encoder = nil
        }

        /// A pass into one of a layer's buffers, cleared to transparent.
        func offscreen(_ texture: MTLTexture) -> MTLRenderCommandEncoder {
            endScene()
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            return commands.makeRenderCommandEncoder(descriptor: pass)!
        }
    }

    // MARK: - Drawing a layer

    private func draw(_ layer: Layer, time: Double, frame: Frame) {
        let image = layer.image
        guard let pass = image.material.passes.first else { return }
        // A compose layer without effects would put the scene back onto itself.
        if layer.compose && layer.effects.isEmpty && image.colorBlendMode == 0 { return }
        if layer.needsBackground {
            frame.endScene()
            if let blit = frame.commands.makeBlitCommandEncoder() {
                blit.copy(from: frame.target, to: background)
                blit.endEncoding()
            }
        }
        let color = SIMD4<Float>(SIMD3<Float>(image.color) * Float(image.brightness), Float(min(max(image.alpha, 0), 1)))
        let isCoreShader = files.isCore("shaders/\(pass.shader).vert")
        let onScreen = projection * layer.world

        do {
            if !layer.compose && layer.effects.isEmpty && image.colorBlendMode == 0 && isCoreShader {
                guard let base = baseTexture(pass, layer: layer, time: time) else { return }
                let pipeline = try pipelines.pipeline(pipelines.program("aerialswap/image"), combos: [:], blending: SceneBlending(pass.blending))
                draw(pipeline, encoder: frame.scene(), vertices: quad(layer.corners, base.uvs), slots: [0: base.binding],
                     system: system(mvp: onScreen, model: layer.world, color: color, time: time))
                return
            }
            guard let result = try renderLayer(layer, pass: pass, time: time, frame: frame) else { return }
            defer { if layer.isReferenced { composites[layer.id] = result } else { give(result) } }
            let uvs = rectangle(SIMD4(0, 0, 1, 1))
            let system = system(mvp: onScreen, model: layer.world, color: color, time: time)
            if image.colorBlendMode != 0 {
                let pipeline = try pipelines.pipeline(pipelines.program("aerialswap/blendimage"),
                                                      combos: ["BLENDMODE": image.colorBlendMode], blending: .none)
                draw(pipeline, encoder: frame.scene(), vertices: quad(layer.corners, uvs),
                     slots: [0: buffer(result), 1: buffer(background)], system: system)
            } else {
                let pipeline = try pipelines.pipeline(pipelines.program("aerialswap/image"), combos: [:],
                                                      blending: layer.compose ? .translucent : SceneBlending(pass.blending))
                draw(pipeline, encoder: frame.scene(), vertices: quad(layer.corners, uvs), slots: [0: buffer(result)], system: system)
            }
        } catch {
            issues.insert("Layer “\(layer.name)”: \(Self.firstLine(error))")
        }
    }

    /// Draws the layer's material and runs its effects in the layer's buffers; returns the buffer holding the result.
    private func renderLayer(_ layer: Layer, pass: SceneDocument.MaterialPass, time: Double, frame: Frame) throws -> MTLTexture? {
        let size = layer.size
        var current = take(size)
        let identity = system(mvp: matrix_identity_float4x4, model: matrix_identity_float4x4, color: .one, time: time)

        if layer.compose {
            // The scene behind the layer, where the layer's corners land on screen.
            let uvs = layer.corners.map { corner -> SIMD2<Float> in
                let p = projection * layer.world * SIMD4(corner.x, corner.y, 0, 1)
                return SIMD2((p.x / p.w + 1) / 2, (1 - p.y / p.w) / 2)
            }
            let pipeline = try pipelines.pipeline(pipelines.program("aerialswap/image"), combos: [:], blending: .none)
            let encoder = frame.offscreen(current)
            draw(pipeline, encoder: encoder, vertices: clipQuad(uvs), slots: [0: buffer(background)], system: identity)
            encoder.endEncoding()
        } else {
            guard let base = baseTexture(pass, layer: layer, time: time) else {
                give(current)
                return nil
            }
            let program = try pipelines.program(files.isCore("shaders/\(pass.shader).vert") ? "aerialswap/image" : pass.shader)
            var inputs = inputs(pass, program: program, binds: [], previous: nil, buffers: [:], time: time)
            inputs.slots[0] = base.binding
            inputs.combos["TEX0FORMAT"] = Int(base.texture.format.rawValue)
            let pipeline = try pipelines.pipeline(program, combos: inputs.combos, blending: .none)
            let encoder = frame.offscreen(current)
            draw(pipeline, encoder: encoder, vertices: clipQuad(base.uvs), slots: inputs.slots, constants: pass.constants, system: identity)
            encoder.endEncoding()
        }

        for effect in layer.effects {
            var declared: [String: MTLTexture] = [:]
            for b in effect.buffers {
                declared[b.name] = take(SIMD2(max(1, Int(Double(size.x) / b.scale)), max(1, Int(Double(size.y) / b.scale))))
            }
            // A layer's own composite buffers hold its image as the effect started; other layers' hold their results.
            let input = current
            var buffers = declared
            for (id, texture) in composites.merging([layer.id: input], uniquingKeysWith: { _, own in own }) {
                buffers["_rt_imageLayerComposite_\(id)_a"] = texture
                buffers["_rt_imageLayerComposite_\(id)_b"] = texture
            }
            defer {
                declared.values.forEach(give)
                if current !== input { give(input) }
            }
            for effectPass in effect.passes {
                if effectPass.command == "copy" {
                    guard let source = effectPass.source == "previous" ? current : effectPass.source.flatMap({ buffers[$0] }),
                          let destination = effectPass.target.flatMap({ buffers[$0] }) else { continue }
                    let pipeline = try pipelines.pipeline(pipelines.program("aerialswap/image"), combos: [:], blending: .none)
                    let encoder = frame.offscreen(destination)
                    draw(pipeline, encoder: encoder, vertices: clipQuad(rectangle(SIMD4(0, 0, 1, 1))), slots: [0: buffer(source)],
                         system: identity)
                    encoder.endEncoding()
                    continue
                }
                guard let material = effectPass.material?.passes.first else { continue }
                do {
                    let program = try pipelines.program(material.shader)
                    let inputs = inputs(material, program: program, binds: effectPass.binds, previous: current, buffers: buffers, time: time)
                    let pipeline = try pipelines.pipeline(program, combos: inputs.combos, blending: SceneBlending(material.blending))
                    let named = effectPass.target.flatMap { buffers[$0] }
                    let output = named ?? take(size)
                    let encoder = frame.offscreen(output)
                    draw(pipeline, encoder: encoder, vertices: clipQuad(rectangle(SIMD4(0, 0, 1, 1))), slots: inputs.slots,
                         constants: material.constants, system: identity)
                    encoder.endEncoding()
                    if named == nil {
                        if current !== input { give(current) }
                        current = output
                    }
                } catch {
                    issues.insert("Effect “\(effect.name)” (\(material.shader)): \(Self.firstLine(error))")
                }
            }
        }
        return current
    }

    /// The layer's own texture (its material's first slot) as it shows at `time`, and the texture coordinates of its
    /// image (padding left out, or the sprite frame due).
    private func baseTexture(_ pass: SceneDocument.MaterialPass, layer: Layer, time: Double)
        -> (texture: GPUTexture, binding: Binding, uvs: [SIMD2<Float>])?
    {
        guard let name = pass.textures.first ?? nil, let texture = textures.texture(name) else {
            issues.insert("Layer “\(layer.name)” has no texture")
            return nil
        }
        let (image, rect) = texture.frame(at: time)
        let binding = Binding(texture: image,
                              sampler: sampler(nearest: layer.image.pointFilter || texture.flags.contains(.pointFilter),
                                               clamp: layer.image.clampUVs || texture.flags.contains(.clampUVs), mips: texture.hasMips),
                              resolution: texture.resolution, format: texture.format)
        return (texture, binding, rectangle(rect))
    }

    // MARK: - Drawing particles

    /// Draws a system's particles as quads in scene units (sprites turned by their rotation, trails along their
    /// velocity), then its children.
    private func draw(_ system: ParticleSystem, name: String, world: simd_float4x4, time: Double, frame: Frame) {
        defer {
            for child in system.children {
                let offset = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(child.origin, 1)))
                draw(child.system, name: name, world: world * offset, time: time, frame: frame)
            }
        }
        let sprites = system.sprites()
        guard !sprites.isEmpty, !system.renderers.isEmpty else { return }
        guard let path = system.materialPath, let material = particleMaterial(path),
              let textureName = material.textures.first ?? nil, let texture = textures.texture(textureName) else {
            issues.insert("Particles “\(name)” have no material or texture")
            return
        }
        // Refraction bends the scene behind through a normal map; drawn plainly it would show the map itself.
        if material.combos["REFRACT"] == 1 {
            issues.insert("Particles “\(name)”: refraction isn't drawn")
            return
        }
        guard files.isCore("shaders/\(material.shader).vert") else {
            issues.insert("Particles “\(name)”: shader \(material.shader) isn't supported")
            return
        }

        let frameCount = max(1, texture.frames.count)
        var vertices: [SceneVertex] = []
        vertices.reserveCapacity(sprites.count * 6 * system.renderers.count)
        for renderer in system.renderers {
            for sprite in sprites {
                let index = switch system.animation {
                case .randomFrame: sprite.frame
                case .sequence(let multiplier): Int((sprite.life * multiplier).truncatingRemainder(dividingBy: 1) * Float(frameCount))
                }
                let rect = texture.frames.isEmpty ? texture.frame(at: 0).rect : texture.frame(index: index).rect
                // The quad's half axes: across and along.
                let half = sprite.size / 2
                var across: SIMD2<Float>, along: SIMD2<Float>
                switch renderer {
                case .sprite:
                    let c = cos(sprite.rotation), s = sin(sprite.rotation)
                    across = SIMD2(c, s) * half
                    along = SIMD2(-s, c) * half
                case .trail(let length, let minimum, let maximum):
                    let velocity = SIMD2(sprite.velocity.x, sprite.velocity.y)
                    let speed = simd_length(velocity)
                    let direction = speed > 1e-4 ? velocity / speed : SIMD2<Float>(0, 1)
                    across = SIMD2(direction.y, -direction.x) * half
                    along = direction * half * min(max(speed * length, minimum), maximum)
                }
                let center = SIMD2(sprite.position.x, sprite.position.y)
                func corner(_ x: Float, _ y: Float, _ uv: SIMD2<Float>) -> SceneVertex {
                    let local: SIMD2<Float> = center + across * x + along * y
                    let p: SIMD4<Float> = world * SIMD4<Float>(local.x, local.y, sprite.position.z, 1)
                    return SceneVertex(position: SIMD3(p.x, p.y, p.z), texCoord: uv, color: sprite.color)
                }
                let topLeft = corner(-1, 1, SIMD2(rect.x, rect.y)), topRight = corner(1, 1, SIMD2(rect.x + rect.z, rect.y))
                let bottomLeft = corner(-1, -1, SIMD2(rect.x, rect.y + rect.w)), bottomRight = corner(1, -1, SIMD2(rect.x + rect.z, rect.y + rect.w))
                vertices += [topLeft, topRight, bottomLeft, topRight, bottomRight, bottomLeft]
            }
        }

        do {
            let pipeline = try pipelines.pipeline(pipelines.program("aerialswap/particle"), combos: [:], blending: SceneBlending(material.blending))
            let binding = Binding(texture: texture.texture,
                                  sampler: sampler(nearest: texture.flags.contains(.pointFilter), clamp: texture.flags.contains(.clampUVs),
                                                   mips: texture.hasMips),
                                  resolution: texture.resolution, format: texture.format)
            draw(pipeline, encoder: frame.scene(), vertices: vertices, slots: [0: binding], constants: material.constants,
                 system: self.system(mvp: projection, model: matrix_identity_float4x4, color: .one, time: time))
        } catch {
            issues.insert("Particles “\(name)”: \(Self.firstLine(error))")
        }
    }

    private func particleMaterial(_ path: String) -> SceneDocument.MaterialPass? {
        if let cached = particleMaterials[path] { return cached }
        let pass = (try? files.json(path)).map { SceneDocument.Material(json: $0.resolvedDeep(document.properties)) }?.passes.first
        particleMaterials[path] = pass
        return pass
    }

    // MARK: - Passes

    private struct Binding {
        let texture: MTLTexture
        let sampler: MTLSamplerState
        /// `g_TextureNResolution`: texture size, then image size.
        let resolution: SIMD4<Float>
        let format: SceneTexture.Format
    }

    /// A pass's textures by slot and its combos: the shader's defaults, the material's, a texture combo for each slot
    /// the material or a bind fills, and each slot's format.
    private func inputs(_ material: SceneDocument.MaterialPass, program: ShaderProgram, binds: [(name: String, index: Int)],
                        previous: MTLTexture?, buffers: [String: MTLTexture], time: Double)
        -> (slots: [Int: Binding], combos: [String: Int])
    {
        func binding(_ name: String) -> Binding? {
            if name == "previous" { return previous.map(buffer) }
            if let named = buffers[name] { return buffer(named) }
            if name == "_rt_FullFrameBuffer" { return buffer(background) }
            if name.hasPrefix("_rt_") {
                issues.insert("Render target \(name) isn't supported")
                return nil
            }
            guard let texture = textures.texture(name) else { return nil }
            return Binding(texture: texture.texture,
                           sampler: sampler(nearest: texture.flags.contains(.pointFilter), clamp: texture.flags.contains(.clampUVs),
                                            mips: texture.hasMips),
                           resolution: texture.resolution, format: texture.format)
        }

        var slots: [Int: Binding] = [:]
        var combos = program.annotations.combos
        for (name, value) in material.combos { combos[name.uppercased()] = value }
        var filled = Set<Int>()
        for (slot, name) in material.textures.enumerated() {
            guard let name, let b = binding(name) else { continue }
            slots[slot] = b
            filled.insert(slot)
        }
        for bind in binds {
            guard let b = binding(bind.name) else { continue }
            slots[bind.index] = b
            filled.insert(bind.index)
        }
        if slots[0] == nil, let previous { slots[0] = buffer(previous) }
        for (slot, annotation) in program.annotations.textures where slots[slot] == nil {
            if let name = annotation.defaultTexture, let b = binding(name) { slots[slot] = b }
        }
        for slot in filled { if let combo = program.annotations.textures[slot]?.combo { combos[combo] = 1 } }
        for (slot, b) in slots { combos["TEX\(slot)FORMAT"] = Int(b.format.rawValue) }
        return (slots, combos)
    }

    private func draw(_ pipeline: ScenePipeline, encoder: MTLRenderCommandEncoder, vertices: [SceneVertex], slots: [Int: Binding],
                      constants: [String: SceneJSON] = [:], system: [String: [Float]]) {
        encoder.setRenderPipelineState(pipeline.state)
        let length = MemoryLayout<SceneVertex>.stride * vertices.count
        if length <= 4096 {
            encoder.setVertexBytes(vertices, length: length, index: PipelineCache.vertexBufferIndex)
        } else if let buffer = device.makeBuffer(bytes: vertices, length: length) {
            encoder.setVertexBuffer(buffer, offset: 0, index: PipelineCache.vertexBufferIndex)
        } else {
            return
        }
        encoder.setVertexBuffer(pipelines.constants, offset: 0, index: PipelineCache.constantBufferIndex)
        var system = system
        for (slot, b) in slots { system["g_Texture\(slot)Resolution"] = [b.resolution.x, b.resolution.y, b.resolution.z, b.resolution.w] }
        if let first = slots[0] {
            let texel = SIMD2(1 / first.resolution.x, 1 / first.resolution.y)
            system["g_TexelSize"] = [texel.x, texel.y]
            system["g_TexelSizeHalf"] = [texel.x / 2, texel.y / 2]
        }
        let annotations = pipeline.program.annotations
        let fallback = buffer(textures.black.texture)

        for (shader, isVertex) in [(pipeline.vertex, true), (pipeline.fragment, false)] {
            if let index = shader.uniformBufferIndex {
                var block = UniformBlock(size: shader.uniformSize)
                for (name, uniform) in shader.uniforms {
                    if let values = value(name, uniform, annotations: annotations, constants: constants, system: system) {
                        block.set(uniform, values)
                    }
                }
                block.bytes.withUnsafeBytes { bytes in
                    if bytes.count <= 4096 {
                        if isVertex { encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: index) }
                        else { encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: index) }
                    } else if let buffer = device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count) {
                        if isVertex { encoder.setVertexBuffer(buffer, offset: 0, index: index) }
                        else { encoder.setFragmentBuffer(buffer, offset: 0, index: index) }
                    }
                }
            }
            for (name, binding) in shader.textures {
                let b = Int(name.dropFirst("g_Texture".count)).flatMap { slots[$0] } ?? fallback
                if isVertex {
                    encoder.setVertexTexture(b.texture, index: binding.texture)
                    encoder.setVertexSamplerState(b.sampler, index: binding.sampler)
                } else {
                    encoder.setFragmentTexture(b.texture, index: binding.texture)
                    encoder.setFragmentSamplerState(b.sampler, index: binding.sampler)
                }
            }
        }
        // Quads are 4-vertex strips; particles come as triangles.
        encoder.drawPrimitives(type: vertices.count == 4 ? .triangleStrip : .triangle, vertexStart: 0, vertexCount: vertices.count)
    }

    /// A uniform's value: the material's (through the shader's annotation), else the renderer's, else the
    /// annotation's default; matrices nobody sets are identities, anything else zero.
    private func value(_ name: String, _ uniform: MetalShader.Uniform, annotations: ShaderAnnotations,
                       constants: [String: SceneJSON], system: [String: [Float]]) -> [Float]? {
        // The translator renames uniforms that collide with GLSL's reserved words.
        let key = name.hasPrefix("as_") ? String(name.dropFirst(3)) : name
        func floats(_ json: SceneJSON?) -> [Float]? {
            guard let json else { return nil }
            return json.vector?.map { Float($0) } ?? json.bool.map { [$0 ? 1 : 0] }
        }
        let annotation = annotations.uniforms[key]
        if let material = annotation?.material, let values = floats(constants[material]) { return values }
        if let values = system[key] { return values }
        if let values = floats(annotation?.defaultValue) { return values }
        if uniform.columns == 4, uniform.vectorSize == 4 { return matrix_identity_float4x4.floats }
        if uniform.columns == 3, uniform.vectorSize == 3 { return [1, 0, 0, 0, 1, 0, 0, 0, 1] }
        return nil
    }

    /// The values every pass can read.
    private func system(mvp: simd_float4x4, model: simd_float4x4, color: SIMD4<Float>, time: Double) -> [String: [Float]] {
        let w = Float(width), h = Float(height)
        return [
            "g_ModelViewProjectionMatrix": mvp.floats, "g_ModelViewProjectionMatrixInverse": mvp.inverse.floats,
            "g_ModelMatrix": model.floats, "g_ModelMatrixInverse": model.inverse.floats,
            "g_ViewProjectionMatrix": projection.floats,
            "g_Time": [Float(time)], "g_FrameTime": [1 / 60], "g_Daytime": [0.5],
            "g_Color4": [color.x, color.y, color.z, color.w], "g_Color": [color.x, color.y, color.z],
            "g_Alpha": [color.w], "g_UserAlpha": [color.w], "g_Brightness": [1],
            "g_PointerPosition": [0.5, 0.5], "g_PointerPositionLast": [0.5, 0.5], "g_ParallaxPosition": [0.5, 0.5],
            "g_Screen": [w, h, w / h],
            "g_Texture0Rotation": [1, 0, 0, 1], "g_Texture0Translation": [0, 0],
        ]
    }

    // MARK: - Geometry, buffers, samplers

    /// Texture coordinates of a rectangle (origin, size) in quad order: top left, top right, bottom left, bottom right.
    private func rectangle(_ r: SIMD4<Float>) -> [SIMD2<Float>] {
        [SIMD2(r.x, r.y), SIMD2(r.x + r.z, r.y), SIMD2(r.x, r.y + r.w), SIMD2(r.x + r.z, r.y + r.w)]
    }

    private func quad(_ corners: [SIMD2<Float>], _ uvs: [SIMD2<Float>]) -> [SceneVertex] {
        zip(corners, uvs).map { SceneVertex(position: SIMD3($0.x, $0.y, 0), texCoord: $1) }
    }

    private func clipQuad(_ uvs: [SIMD2<Float>]) -> [SceneVertex] {
        quad([SIMD2(-1, 1), SIMD2(1, 1), SIMD2(-1, -1), SIMD2(1, -1)], uvs)
    }

    private func buffer(_ texture: MTLTexture) -> Binding {
        let w = Float(texture.width), h = Float(texture.height)
        return Binding(texture: texture, sampler: sampler(nearest: false, clamp: true, mips: false),
                       resolution: SIMD4(w, h, w, h), format: .rgba8)
    }

    /// A layer buffer from the pool (they're kept between frames).
    private func take(_ size: SIMD2<Int>) -> MTLTexture {
        if let texture = pool[size]?.popLast() { return texture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size.x, height: size.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)!
    }

    private func give(_ texture: MTLTexture) {
        pool[SIMD2(texture.width, texture.height), default: []].append(texture)
    }

    private func sampler(nearest: Bool, clamp: Bool, mips: Bool) -> MTLSamplerState {
        let key = (nearest ? 1 : 0) | (clamp ? 2 : 0) | (mips ? 4 : 0)
        if let cached = samplers[key] { return cached }
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = nearest ? .nearest : .linear
        descriptor.magFilter = nearest ? .nearest : .linear
        descriptor.mipFilter = mips ? (nearest ? .nearest : .linear) : .notMipmapped
        let address: MTLSamplerAddressMode = clamp ? .clampToEdge : .repeat
        descriptor.sAddressMode = address
        descriptor.tAddressMode = address
        let state = device.makeSamplerState(descriptor: descriptor)!
        samplers[key] = state
        return state
    }

    private static func firstLine(_ error: Error) -> String {
        String("\(error)".split(separator: "\n").first ?? "").prefix(200).description
    }
}
