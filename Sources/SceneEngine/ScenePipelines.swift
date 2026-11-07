import Metal
import simd

/// How a pass's output meets what's already in its target, by the names materials use.
enum SceneBlending: Hashable {
    case none, translucent, additive

    init(_ name: String) {
        self = switch name {
        case "translucent", "premultiplied": .translucent
        case "additive": .additive
        default: .none
        }
    }
}

/// A shader's sources (includes expanded) and annotations, before combos pick a variant.
struct ShaderProgram {
    let name: String
    let vertex: String
    let fragment: String
    let annotations: ShaderAnnotations
}

/// One compiled variant of a shader, ready to draw with.
final class ScenePipeline {
    let state: MTLRenderPipelineState
    let vertex: MetalShader
    let fragment: MetalShader
    let program: ShaderProgram

    init(state: MTLRenderPipelineState, vertex: MetalShader, fragment: MetalShader, program: ShaderProgram) {
        self.state = state
        self.vertex = vertex
        self.fragment = fragment
        self.program = program
    }
}

/// The vertex every pass draws with: a position (layer units, or clip space for passes into a layer's buffers) and a
/// texture coordinate. Attributes a shader declares beyond these read as constants (see `PipelineCache`).
struct SceneVertex {
    var position: SIMD3<Float>
    var texCoord: SIMD2<Float>
}

/// Compiles scene shaders once per variant (shader, combos) and makes pipeline states per blending and target format.
final class PipelineCache {
    static let vertexBufferIndex = 30
    /// Constant values for attributes the renderer doesn't feed: zero, or white for `a_Color`.
    static let constantBufferIndex = 29

    let device: MTLDevice
    let files: SceneFiles
    private var programs: [String: Result<ShaderProgram, Error>] = [:]
    private var functions: [String: Result<(MTLFunction, MTLFunction, MetalShader, MetalShader), Error>] = [:]
    private var states: [String: ScenePipeline] = [:]
    let constants: MTLBuffer

    init(device: MTLDevice, files: SceneFiles) {
        self.device = device
        self.files = files
        let values: [Float] = [0, 0, 0, 0, 1, 1, 1, 1]
        constants = device.makeBuffer(bytes: values, length: values.count * 4)!
    }

    func program(_ shader: String) throws -> ShaderProgram {
        if let cached = programs[shader] { return try cached.get() }
        let result = Result {
            let sources = try ShaderTranslator.sources(shader, files: files)
            return ShaderProgram(name: shader, vertex: sources.vertex, fragment: sources.fragment,
                                 annotations: ShaderTranslator.annotations(vertex: sources.vertex, fragment: sources.fragment))
        }
        programs[shader] = result
        return try result.get()
    }

    func pipeline(_ program: ShaderProgram, combos: [String: Int], blending: SceneBlending,
                  format: MTLPixelFormat = .rgba8Unorm) throws -> ScenePipeline {
        let variant = program.name + "|" + combos.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let key = "\(variant)|\(blending)|\(format.rawValue)"
        if let cached = states[key] { return cached }

        if functions[variant] == nil {
            functions[variant] = Result {
                let translated = ShaderTranslator.translate(vertex: program.vertex, fragment: program.fragment, combos: combos)
                let vertex = try ShaderTranslator.compile(translated.vertex, stage: .vertex)
                let fragment = try ShaderTranslator.compile(translated.fragment, stage: .fragment)
                func function(_ shader: MetalShader) throws -> MTLFunction {
                    let library = try device.makeLibrary(source: shader.source, options: nil)
                    guard let function = library.makeFunction(name: "main0") else {
                        throw ShaderCompileError(description: "no main0 in \(program.name)")
                    }
                    return function
                }
                return (try function(vertex), try function(fragment), vertex, fragment)
            }
        }
        let (vertexFunction, fragmentFunction, vertex, fragment) = try functions[variant]!.get()

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.vertexDescriptor = Self.vertexDescriptor(vertex.attributes)
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = format
        switch blending {
        case .none:
            color.isBlendingEnabled = false
        case .translucent:
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .sourceAlpha
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .one
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .additive:
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .sourceAlpha
            color.destinationRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one
            color.destinationAlphaBlendFactor = .one
        }
        let pipeline = ScenePipeline(state: try device.makeRenderPipelineState(descriptor: descriptor),
                                     vertex: vertex, fragment: fragment, program: program)
        states[key] = pipeline
        return pipeline
    }

    /// Position and texture coordinate from the vertex buffer; any other attribute from the constant buffer.
    private static func vertexDescriptor(_ attributes: [String: Int]) -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        for (name, location) in attributes {
            let attribute = descriptor.attributes[location]!
            switch name {
            case "a_Position":
                attribute.format = .float3
                attribute.offset = 0
                attribute.bufferIndex = vertexBufferIndex
            case "a_TexCoord":
                attribute.format = .float2
                attribute.offset = MemoryLayout<SceneVertex>.offset(of: \.texCoord)!
                attribute.bufferIndex = vertexBufferIndex
            default:
                attribute.format = .float4
                attribute.offset = name == "a_Color" ? 16 : 0
                attribute.bufferIndex = constantBufferIndex
            }
        }
        // Metal rejects layouts no attribute uses.
        if attributes.keys.contains(where: { $0 == "a_Position" || $0 == "a_TexCoord" }) {
            descriptor.layouts[vertexBufferIndex].stride = MemoryLayout<SceneVertex>.stride
        }
        if attributes.keys.contains(where: { $0 != "a_Position" && $0 != "a_TexCoord" }) {
            descriptor.layouts[constantBufferIndex].stepFunction = .constant
            descriptor.layouts[constantBufferIndex].stepRate = 0
            descriptor.layouts[constantBufferIndex].stride = 16
        }
        return descriptor
    }
}

/// A stage's uniform buffer, filled member by member from the shader's reflection.
struct UniformBlock {
    private(set) var bytes: [UInt8]

    init(size: Int) { bytes = [UInt8](repeating: 0, count: max(size, 16)) }

    /// Writes `values` (matrices column by column, arrays element by element) as the member's type; missing
    /// components stay zero.
    mutating func set(_ uniform: MetalShader.Uniform, _ values: [Float]) {
        var index = 0
        for element in 0 ..< uniform.count {
            for column in 0 ..< uniform.columns {
                for row in 0 ..< uniform.vectorSize {
                    defer { index += 1 }
                    guard index < values.count else { return }
                    let offset = uniform.offset + element * uniform.arrayStride + column * uniform.matrixStride + row * 4
                    guard offset + 4 <= bytes.count else { return }
                    let value = values[index]
                    let word: UInt32 = switch uniform.base {
                    case .float: value.bitPattern
                    case .int: UInt32(bitPattern: Int32(clamping: Int(value.rounded())))
                    case .uint: UInt32(clamping: max(0, Int(value.rounded())))
                    case .bool: value != 0 ? 1 : 0
                    }
                    withUnsafeBytes(of: word.littleEndian) { bytes.replaceSubrange(offset ..< offset + 4, with: $0) }
                }
            }
        }
    }
}

extension simd_float4x4 {
    /// Column-major floats, the order `UniformBlock.set` takes matrices in.
    var floats: [Float] { [columns.0, columns.1, columns.2, columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] } }
}
