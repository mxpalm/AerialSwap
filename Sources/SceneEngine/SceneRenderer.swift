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
    /// Where the scene is in the output when it shows whole and bars are left around it (pixels from the top left).
    private let wholeRect: SIMD4<Float>?
    private let items: [Item]
    private let objectsByID: [Int: SceneDocument.Object]
    /// The scene's scripts (nil without any), and a second run of them for the frame a loop's crossfade draws.
    private let scripts: SceneScripts?
    private var laterScripts: SceneScripts?
    /// Object values for the frame being drawn, as the scripts set them (empty: the document's).
    private var state: [Int: ObjectState] = [:]
    /// The time of day the scene shows (0…1 from midnight): `g_Daytime` and the scripts' `engine.timeOfDay` and clock.
    public let timeOfDay: Double
    private let clockStart: Date
    private var particleMaterials: [String: SceneDocument.MaterialPass?] = [:]
    private var pool: [SIMD2<Int>: [MTLTexture]] = [:]
    private var samplers: [Int: MTLSamplerState] = [:]
    private var issues: Set<String>
    /// Results of layers others read, by layer id, for the frame being drawn.
    private var composites: [Int: MTLTexture] = [:]

    /// What the renderer had to leave out: passes whose shader didn't compile, textures that didn't load, objects it
    /// doesn't draw yet.
    public var problems: [String] {
        issues.union(textures.problems.map { "Texture \($0.key): \($0.value)" })
            .union(scripts?.problems ?? []).union(laterScripts?.problems ?? []).sorted()
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
    /// `timeOfDay` (0…1 from midnight) is the time the scene shows; its clock stands still at it. `framing` places the
    /// scene in the output.
    public init(document: SceneDocument, files: SceneFiles, width: Int, height: Int, bufferScale: Double = 1,
                particles: Bool = true, timeOfDay: Double = 0.5, framing: SceneFraming = .fill, device: MTLDevice? = nil) throws {
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

        // The canvas where the framing puts it (scene y runs up, from its bottom edge). z is kept (barely) so the matrix
        // stays invertible.
        let place = framing.placement(scene: SIMD2(document.general.width, document.general.height),
                                      width: Double(width), height: Double(height))
        let w = Float(document.general.width), h = Float(document.general.height), scale = Float(place.scale)
        let left = Float(place.x), top = Float(place.y)
        projection = simd_float4x4(columns: (
            SIMD4(2 * scale / Float(width), 0, 0, 0), SIMD4(0, 2 * scale / Float(height), 0, 0),
            SIMD4(0, 0, 1e-6, 0), SIMD4(2 * left / Float(width) - 1, 1 - 2 * (top + h * scale) / Float(height), 0.5, 1)))
        let rect = SIMD4(left, top, w * scale, h * scale)
        let covers = rect.x <= 0.5 && rect.y <= 0.5 && rect.x + rect.z >= Float(width) - 0.5 && rect.y + rect.w >= Float(height) - 0.5
        wholeRect = framing.mode == .whole && !covers ? rect : nil

        var issues = Set<String>()
        objectsByID = Dictionary(document.objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        items = Self.items(of: document, files: files, textures: textures, bufferScale: min(max(bufferScale, 0.05), 1),
                           particles: particles, issues: &issues)
        self.issues = issues
        self.timeOfDay = min(max(timeOfDay, 0), 1)
        clockStart = Calendar.current.startOfDay(for: .now).addingTimeInterval(self.timeOfDay * 86_400)
        scripts = document.scripts.isEmpty ? nil : SceneScripts(document: document, screen: SIMD2(width, height),
                                                                timeOfDay: self.timeOfDay, clockStart: clockStart)
    }

    // MARK: - Layers and particle systems

    private enum Item {
        case layer(Layer)
        case particles(Particles)
    }

    /// Objects are kept whether they show or not: scripts can show and move them from frame to frame (see `placement`).
    private struct Particles {
        let object: SceneDocument.Object
        let system: ParticleSystem
    }

    private struct Layer {
        let object: SceneDocument.Object
        let image: SceneDocument.ImageLayer
        /// Covers the canvas wherever the layer is.
        let fullscreen: Bool
        /// The quad in layer units: top left, top right, bottom left, bottom right.
        let corners: [SIMD2<Float>]
        /// The size of the layer's buffers in pixels.
        let size: SIMD2<Int>
        /// The layer shows the scene behind it (compose, fullscreen and project layers).
        let compose: Bool
        /// Effects with passes, shown or not (scripts can switch them).
        let effects: [SceneDocument.Effect]
        let readsScene: Bool
        /// Another layer reads this one's result (`_rt_imageLayerComposite_<id>_a`), so it's kept until the frame ends.
        let isReferenced: Bool

        var id: Int { object.id }
        var name: String { object.name }
    }

    private static func items(of document: SceneDocument, files: SceneFiles, textures: TextureStore, bufferScale: Double,
                              particles: Bool, issues: inout Set<String>) -> [Item] {
        let byID = Dictionary(document.objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func shows(_ object: SceneDocument.Object, depth: Int = 0) -> Bool {
            guard let id = object.parent, let parent = byID[id], parent.id != object.id, depth < 32 else { return object.visible }
            return object.visible && shows(parent, depth: depth + 1)
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
                var size = image.size ?? SIMD2(image.model.width ?? 0, image.model.height ?? 0)
                if image.model.fullscreen { size = SIMD2(document.general.width, document.general.height) }
                if let text = image.text {
                    // As big as its text, a scene unit per pixel; empty text draws nothing.
                    guard let texture = textures.text(SceneDocument.ImageLayer.textTexture(object.id), text) else { continue }
                    size = SIMD2(Double(texture.imageWidth), Double(texture.imageHeight))
                }
                guard size.x >= 1, size.y >= 1 else {
                    if shows(object) { issues.insert("Layer “\(object.name)” has no size") }
                    continue
                }
                let w = Float(size.x), h = Float(size.y)
                let alignment = image.alignment.lowercased()
                let left: Float = alignment.contains("left") ? 0 : alignment.contains("right") ? -w : -w / 2
                let bottom: Float = alignment.contains("top") ? -h : alignment.contains("bottom") ? 0 : -h / 2
                items.append(.layer(Layer(
                    object: object, image: image, fullscreen: image.model.fullscreen,
                    corners: [SIMD2(left, bottom + h), SIMD2(left + w, bottom + h), SIMD2(left, bottom), SIMD2(left + w, bottom)],
                    size: SIMD2(min(8192, max(1, Int((size.x * bufferScale).rounded()))),
                                min(8192, max(1, Int((size.y * bufferScale).rounded())))),
                    compose: image.model.compose, effects: image.effects.filter { !$0.passes.isEmpty },
                    readsScene: (reads[object.id] ?? []).contains("_rt_FullFrameBuffer"),
                    isReferenced: referenced.contains(object.id))))
            case .particle(let particle):
                guard particles else { continue }
                let system = ParticleSystem(definition: particle.definition, overrides: .init(particle.instanceOverride),
                                            seed: UInt64(UInt32(truncatingIfNeeded: object.id)) &+ 1) { path in
                    (try? files.json(path))?.resolvedDeep(document.properties)
                }
                if shows(object) {
                    for feature in system.unsupported { issues.insert("Particles “\(object.name)”: \(feature) isn't simulated") }
                }
                items.append(.particles(Particles(object: object, system: system)))
            default:
                break
            }
        }
        return items
    }

    /// Where an object is (object units → scene units) and whether it shows this frame: its transform and visibility,
    /// or what scripts set, under its parents'. A hidden parent hides its children.
    private func placement(_ object: SceneDocument.Object, depth: Int = 0) -> (world: simd_float4x4, visible: Bool) {
        let own = state[object.id]
        let local = Self.matrix(own?.transform ?? object.transform)
        let visible = own?.visible ?? object.visible
        guard let id = object.parent, let parent = objectsByID[id], parent.id != object.id, depth < 32 else { return (local, visible) }
        let above = placement(parent, depth: depth + 1)
        return (above.world * local, above.visible && visible)
    }

    private static func matrix(_ t: SceneDocument.Transform) -> simd_float4x4 {
        let c = Float(cos(t.angles.z)), s = Float(sin(t.angles.z))
        let translation = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
                                                   SIMD4(Float(t.origin.x), Float(t.origin.y), Float(t.origin.z), 1)))
        let rotation = simd_float4x4(columns: (SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
        let scale = simd_float4x4(diagonal: SIMD4(Float(t.scale.x), Float(t.scale.y), Float(t.scale.z), 1))
        return translation * rotation * scale
    }

    // MARK: - Frames

    /// Renders the frame at `time` (seconds) and returns the output texture (RGBA8, shared storage).
    @discardableResult
    public func render(time: Double) throws -> MTLTexture {
        guard let commands = queue.makeCommandBuffer() else { throw SceneError.unsupported("Rendering without Metal") }
        if let loop, loop.period > 0 {
            let t = time - (time / loop.period).rounded(.down) * loop.period
            encode(time: t, into: target, commands: commands, scripts: scripts)
            if t < loop.crossfade {
                // Fade in from one period later, which is where the previous period ended. Its scripts run apart, so
                // neither run has to go back in time.
                let later = crossfadeTarget()
                if laterScripts == nil, scripts != nil {
                    laterScripts = SceneScripts(document: document, screen: SIMD2(width, height), timeOfDay: timeOfDay,
                                                clockStart: clockStart)
                }
                encode(time: t + loop.period, into: later, commands: commands, scripts: laterScripts)
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .load
                pass.colorAttachments[0].storeAction = .store
                if let encoder = commands.makeRenderCommandEncoder(descriptor: pass),
                   let pipeline = try? pipelines.pipeline(pipelines.program("aerialswap/image"), combos: [:], blending: .fade) {
                    // By weight alone: where the scene leaves alpha below 1, translucent blending wouldn't fully replace
                    // the frame at weight 1, and the loop would jump there.
                    encoder.setBlendColor(red: 0, green: 0, blue: 0, alpha: Float(1 - t / loop.crossfade))
                    draw(pipeline, encoder: encoder, vertices: clipQuad(rectangle(SIMD4(0, 0, 1, 1))), slots: [0: buffer(later)],
                         system: system(mvp: matrix_identity_float4x4, model: matrix_identity_float4x4, color: .one, time: t))
                    encoder.endEncoding()
                }
            }
        } else {
            encode(time: time, into: target, commands: commands, scripts: scripts)
        }
        commands.commit()
        commands.waitUntilCompleted()
        textures.frameDone()
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

    /// Encodes the scene at `time` into `output`, with the values `scripts` set by then.
    private func encode(time: Double, into output: MTLTexture, commands: MTLCommandBuffer, scripts: SceneScripts?) {
        state = scripts?.advance(to: time) ?? [:]
        let c = document.general.clearColor
        let frame = Frame(commands: commands, target: output,
                          clear: MTLClearColor(red: Double(c.x), green: Double(c.y), blue: Double(c.z), alpha: 1))
        for item in items {
            switch item {
            case .layer(let layer): draw(layer, time: time, frame: frame)
            case .particles(let particles):
                let (world, visible) = placement(particles.object)
                guard visible else { continue }
                particles.system.advance(to: time)
                draw(particles.system, name: particles.object.name, world: world, time: time, frame: frame)
            }
        }
        _ = frame.scene()
        frame.endScene()
        if document.general.bloom { bloom(time: time, frame: frame) }
        if let wholeRect { bars(around: wholeRect, time: time, frame: frame) }
        composites.values.forEach(give)
        composites = [:]
    }

    /// The scene's glow (`general.bloom`): what's brighter than the threshold, blurred at a quarter of the size and
    /// added back `bloomstrength` times.
    private func bloom(time: Double, frame: Frame) {
        guard let blit = frame.commands.makeBlitCommandEncoder() else { return }
        blit.copy(from: frame.target, to: background)
        blit.endEncoding()
        let size = SIMD2(max(1, width / 4), max(1, height / 4))
        let identity = system(mvp: matrix_identity_float4x4, model: matrix_identity_float4x4, color: .one, time: time)
        let whole = clipQuad(rectangle(SIMD4(0, 0, 1, 1)))
        var current = take(size)
        do {
            let threshold = min(max(document.general.bloomThreshold, 0), 1)
            let extract = try pipelines.pipeline(pipelines.program("aerialswap/bloomextract"), combos: [:], blending: .none)
            var encoder = frame.offscreen(current)
            draw(extract, encoder: encoder, vertices: whole, slots: [0: buffer(background)],
                 constants: ["threshold": .number(threshold)], system: identity)
            encoder.endEncoding()
            let gaussian = try pipelines.program("effects/blur_gaussian")
            for vertical in [0, 1] {
                let output = take(size)
                encoder = frame.offscreen(output)
                draw(try pipelines.pipeline(gaussian, combos: ["VERTICAL": vertical], blending: .none), encoder: encoder,
                     vertices: whole, slots: [0: buffer(current)], constants: ["scale": .string("1 1")], system: identity)
                encoder.endEncoding()
                give(current)
                current = output
            }
            let strength = Float(min(max(document.general.bloomStrength, 0), 10))
            let add = try pipelines.pipeline(pipelines.program("aerialswap/image"), combos: [:], blending: .additive)
            draw(add, encoder: frame.scene(), vertices: whole, slots: [0: buffer(current)],
                 system: system(mvp: matrix_identity_float4x4, model: matrix_identity_float4x4,
                                color: SIMD4(strength, strength, strength, 1), time: time))
            frame.endScene()
        } catch {
            issues.insert("Bloom: \(Self.firstLine(error))")
        }
        give(current)
    }

    /// Fills the output around the scene (`rect`, pixels from the top left) with a blurred, darkened copy of it
    /// stretched to cover the output.
    private func bars(around rect: SIMD4<Float>, time: Double, frame: Frame) {
        guard let blit = frame.commands.makeBlitCommandEncoder() else { return }
        blit.copy(from: frame.target, to: background)
        blit.endEncoding()
        let W = Float(width), H = Float(height)
        // The scene in texture coordinates, and the part of it in the output's shape (centered) that the bars blur.
        let scene = SIMD4(rect.x / W, rect.y / H, rect.z / W, rect.w / H)
        let cover = min(rect.z / W, rect.w / H)
        let crop = SIMD4(rect.x + (rect.z - W * cover) / 2, rect.y + (rect.w - H * cover) / 2, W * cover, H * cover)
        let identity = system(mvp: matrix_identity_float4x4, model: matrix_identity_float4x4, color: .one, time: time)
        let size = SIMD2(max(1, width / 8), max(1, height / 8))
        var current = take(size)
        do {
            let copy = try pipelines.pipeline(pipelines.program("aerialswap/image"), combos: [:], blending: .none)
            var encoder = frame.offscreen(current)
            draw(copy, encoder: encoder, vertices: clipQuad(rectangle(SIMD4(crop.x / W, crop.y / H, crop.z / W, crop.w / H))),
                 slots: [0: buffer(background)], system: identity)
            encoder.endEncoding()
            let gaussian = try pipelines.program("effects/blur_gaussian")
            for vertical in [0, 1, 0, 1] {
                let output = take(size)
                encoder = frame.offscreen(output)
                draw(try pipelines.pipeline(gaussian, combos: ["VERTICAL": vertical], blending: .none), encoder: encoder,
                     vertices: clipQuad(rectangle(SIMD4(0, 0, 1, 1))), slots: [0: buffer(current)],
                     constants: ["scale": .string("2 2")], system: identity)
                encoder.endEncoding()
                give(current)
                current = output
            }
            let target = frame.scene()
            draw(copy, encoder: target, vertices: clipQuad(rectangle(SIMD4(0, 0, 1, 1))), slots: [0: buffer(current)],
                 system: system(mvp: matrix_identity_float4x4, model: matrix_identity_float4x4, color: SIMD4(0.6, 0.6, 0.6, 1), time: time))
            // The scene itself back on top, sharp.
            let corners = [SIMD2(scene.x, scene.y), SIMD2(scene.x + scene.z, scene.y), SIMD2(scene.x, scene.y + scene.w),
                           SIMD2(scene.x + scene.z, scene.y + scene.w)].map { SIMD2($0.x * 2 - 1, 1 - $0.y * 2) }
            draw(copy, encoder: target, vertices: quad(corners, rectangle(scene)), slots: [0: buffer(background)], system: identity)
            frame.endScene()
        } catch {
            issues.insert("Framing: \(Self.firstLine(error))")
        }
        give(current)
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
        var (world, visible) = placement(layer.object)
        guard visible else { return }
        if layer.fullscreen {
            world = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
                                            SIMD4(Float(document.general.width / 2), Float(document.general.height / 2), 0, 1)))
        }
        let own = state[layer.id]
        let effects = layer.effects.filter { effect in
            guard let shown = own?.effectsVisible, effect.index < shown.count else { return effect.visible }
            return shown[effect.index]
        }
        // A compose layer without effects would put the scene back onto itself.
        if layer.compose && effects.isEmpty && image.colorBlendMode == 0 { return }
        if (layer.compose && !effects.isEmpty) || image.colorBlendMode != 0 || layer.readsScene {
            frame.endScene()
            if let blit = frame.commands.makeBlitCommandEncoder() {
                blit.copy(from: frame.target, to: background)
                blit.endEncoding()
            }
        }
        let alpha = own?.alpha ?? image.alpha
        let color = SIMD4<Float>(SIMD3<Float>(own?.color ?? image.color) * Float(own?.brightness ?? image.brightness),
                                 Float(min(max(alpha.isFinite ? alpha : 1, 0), 1)))
        let isCoreShader = files.isCore("shaders/\(pass.shader).vert")
        let onScreen = projection * world

        do {
            if !layer.compose && effects.isEmpty && image.colorBlendMode == 0 && isCoreShader {
                guard let base = baseTexture(pass, layer: layer, time: time) else { return }
                let pipeline = try pipelines.pipeline(pipelines.program("aerialswap/image"), combos: [:], blending: SceneBlending(pass.blending))
                let vertices = mesh(layer, uvs: base.uvs, time: time) ?? quad(layer.corners, base.uvs)
                draw(pipeline, encoder: frame.scene(), vertices: vertices, slots: [0: base.binding],
                     system: system(mvp: onScreen, model: world, color: color, time: time))
                return
            }
            guard let result = try renderLayer(layer, pass: pass, world: world, effects: effects, time: time, frame: frame) else { return }
            defer { if layer.isReferenced { composites[layer.id] = result } else { give(result) } }
            // Effects work on the flat image; a puppet bends the result as it goes onto the scene.
            let uvs = rectangle(SIMD4(0, 0, 1, 1))
            let vertices = mesh(layer, uvs: uvs, time: time) ?? quad(layer.corners, uvs)
            let system = system(mvp: onScreen, model: world, color: color, time: time)
            if image.colorBlendMode != 0 {
                let pipeline = try pipelines.pipeline(pipelines.program("aerialswap/blendimage"),
                                                      combos: ["BLENDMODE": image.colorBlendMode], blending: .none)
                draw(pipeline, encoder: frame.scene(), vertices: vertices,
                     slots: [0: buffer(result), 1: buffer(background)], system: system)
            } else {
                let pipeline = try pipelines.pipeline(pipelines.program("aerialswap/image"), combos: [:],
                                                      blending: layer.compose ? .translucent : SceneBlending(pass.blending))
                draw(pipeline, encoder: frame.scene(), vertices: vertices, slots: [0: buffer(result)], system: system)
            }
        } catch {
            issues.insert("Layer “\(layer.name)”: \(Self.firstLine(error))")
        }
    }

    /// Draws the layer's material and runs `effects` in the layer's buffers; returns the buffer holding the result.
    private func renderLayer(_ layer: Layer, pass: SceneDocument.MaterialPass, world: simd_float4x4, effects: [SceneDocument.Effect],
                             time: Double, frame: Frame) throws -> MTLTexture? {
        let size = layer.size
        var current = take(size)
        let identity = system(mvp: matrix_identity_float4x4, model: matrix_identity_float4x4, color: .one, time: time)

        if layer.compose {
            // The scene behind the layer, where the layer's corners land on screen.
            let uvs = layer.corners.map { corner -> SIMD2<Float> in
                let p = projection * world * SIMD4(corner.x, corner.y, 0, 1)
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

        for effect in effects {
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
                         constants: constants(material.constants, object: layer.id, effect: effect.index, pass: effectPass.instance),
                         system: identity)
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

    /// A pass's constants with the values scripts set this frame.
    private func constants(_ base: [String: SceneJSON], object: Int, effect: Int, pass: Int?) -> [String: SceneJSON] {
        guard let pass, let values = state[object]?.values, !values.isEmpty else { return base }
        let prefix = "effects/\(effect)/passes/\(pass)/constantshadervalues/"
        var result = base
        for (path, value) in values where path.hasPrefix(prefix) { result[String(path.dropFirst(prefix.count))] = value }
        return result
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
            if case .rope(let subdivision) = renderer {
                vertices += rope(sprites, subdivision: subdivision, rect: texture.frame(at: 0).rect, world: world)
                continue
            }
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
                case .rope:
                    continue
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
            let binding = Binding(texture: texture.texture(at: time),
                                  sampler: sampler(nearest: texture.flags.contains(.pointFilter), clamp: texture.flags.contains(.clampUVs),
                                                   mips: texture.hasMips),
                                  resolution: texture.resolution, format: texture.format)
            draw(pipeline, encoder: frame.scene(), vertices: vertices, slots: [0: binding], constants: material.constants,
                 system: self.system(mvp: projection, model: matrix_identity_float4x4, color: .one, time: time))
        } catch {
            issues.insert("Particles “\(name)”: \(Self.firstLine(error))")
        }
    }

    /// A rope renderer's ribbon as triangles: a Catmull-Rom curve through the particles (oldest first) with
    /// `subdivision` points between two, as wide as the particles are big; the texture runs along it (u) and across (v).
    private func rope(_ sprites: [ParticleSystem.Sprite], subdivision: Int, rect: SIMD4<Float>, world: simd_float4x4) -> [SceneVertex] {
        guard sprites.count >= 2 else { return [] }
        // The curve's points, with the size and color they carry.
        var points: [(position: SIMD3<Float>, size: Float, color: SIMD4<Float>)] = []
        let steps = subdivision + 1
        for i in 0 ..< sprites.count - 1 {
            let p0 = sprites[max(i - 1, 0)].position, p1 = sprites[i].position, p2 = sprites[i + 1].position
            let p3 = sprites[min(i + 2, sprites.count - 1)].position
            for step in 0 ..< steps {
                let t = Float(step) / Float(steps), t2 = t * t, t3 = t2 * t
                let a = 2 * p1, b = p2 - p0, c = 2 * p0 - 5 * p1 + 4 * p2 - p3, d = 3 * p1 - p0 - 3 * p2 + p3
                let position = 0.5 * (a + b * t + c * t2 + d * t3)
                points.append((position, sprites[i].size + (sprites[i + 1].size - sprites[i].size) * t,
                               sprites[i].color + (sprites[i + 1].color - sprites[i].color) * t))
            }
        }
        let last = sprites[sprites.count - 1]
        points.append((last.position, last.size, last.color))

        func vertex(_ index: Int, side: Float) -> SceneVertex {
            let point = points[index]
            let ahead = points[min(index + 1, points.count - 1)].position, behind = points[max(index - 1, 0)].position
            let tangent = SIMD2(ahead.x - behind.x, ahead.y - behind.y)
            let length = simd_length(tangent)
            let normal = length > 1e-4 ? SIMD2(-tangent.y, tangent.x) / length : SIMD2<Float>(0, 1)
            let local = SIMD2(point.position.x, point.position.y) + normal * point.size / 2 * side
            let p: SIMD4<Float> = world * SIMD4<Float>(local.x, local.y, point.position.z, 1)
            let u = rect.x + rect.z * Float(index) / Float(points.count - 1)
            return SceneVertex(position: SIMD3(p.x, p.y, p.z), texCoord: SIMD2(u, side > 0 ? rect.y : rect.y + rect.w), color: point.color)
        }
        var vertices: [SceneVertex] = []
        vertices.reserveCapacity((points.count - 1) * 6)
        for i in 0 ..< points.count - 1 {
            let a = vertex(i, side: 1), b = vertex(i, side: -1), c = vertex(i + 1, side: 1), d = vertex(i + 1, side: -1)
            vertices += [a, c, b, c, d, b]
        }
        return vertices
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
            return Binding(texture: texture.texture(at: time),
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
            "g_Time": [Float(time)], "g_FrameTime": [1 / 60], "g_Daytime": [Float(timeOfDay)],
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

    /// A puppet-warp layer's mesh as its bones have it at `time`, as triangles in layer units. `uvs` is where the image is
    /// in its texture (top left, top right, bottom left, bottom right). nil for layers without a puppet.
    private func mesh(_ layer: Layer, uvs: [SIMD2<Float>], time: Double) -> [SceneVertex]? {
        guard let puppet = layer.image.puppet, !puppet.indices.isEmpty, uvs.count == 4 else { return nil }
        let positions = puppet.positions(layers: layer.image.puppetAnimations, time: time)
        // Mesh positions are centred on the image, y up; its texture coordinates run from the top left.
        let topLeft = layer.corners[0], bottomRight = layer.corners[3]
        let centre = (topLeft + bottomRight) / 2
        let origin = uvs[0], across = uvs[1] - uvs[0], down = uvs[2] - uvs[0]
        return puppet.indices.map { i in
            let p = centre + positions[i]
            let uv = puppet.vertices[i].uv
            return SceneVertex(position: SIMD3(p.x, p.y, 0), texCoord: origin + uv.x * across + uv.y * down)
        }
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
