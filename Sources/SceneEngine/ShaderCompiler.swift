import CShaderCompiler
import CSPIRVCross
import Foundation

/// A shader stage translated to Metal Shading Language, with where its inputs live in the Metal function's arguments.
public struct MetalShader: Sendable {
    /// One member of the uniform buffer (the loose uniforms, gathered into one block).
    public struct Uniform: Sendable, Equatable {
        public enum Base: Sendable { case float, int, uint, bool }
        public let offset: Int
        public let base: Base
        /// Components per column (1 for scalars) and columns (1 unless a matrix).
        public let vectorSize: Int
        public let columns: Int
        public let matrixStride: Int
        /// Elements (1 unless an array) and the bytes between them.
        public let count: Int
        public let arrayStride: Int
    }

    /// The MSL source; its entry point is `main0`.
    public let source: String
    /// Uniform name → where it lives in the uniform buffer.
    public let uniforms: [String: Uniform]
    /// Size in bytes of that uniform buffer (0 when the stage has no uniforms) and its buffer index.
    public let uniformSize: Int
    public let uniformBufferIndex: Int?
    /// Texture (sampler2D) name → texture index and sampler index.
    public let textures: [String: (texture: Int, sampler: Int)]

    public var uniformOffsets: [String: Int] { uniforms.mapValues(\.offset) }
    /// Vertex attribute name → attribute index (vertex stage only).
    public let attributes: [String: Int]
}

public enum ShaderStage: Int32, Sendable { case vertex = 0, fragment = 1 }

public struct ShaderCompileError: Error, CustomStringConvertible {
    public let description: String
}

/// glslang (via CShaderCompiler) for SPIR-V, then SPIRV-Cross for MSL and reflection.
public enum ShaderCompiler {
    public static func spirv(_ source: String, stage: ShaderStage, hlsl: Bool = false) throws -> [UInt32] {
        var result = as_spirv()
        defer { as_spirv_free(&result) }
        let ok = source.withCString { as_compile_spirv($0, stage.rawValue, hlsl ? 1 : 0, &result) }
        guard ok == 1, let words = result.words else {
            throw ShaderCompileError(description: result.log.map { String(cString: $0) } ?? "glslang failed")
        }
        return Array(UnsafeBufferPointer(start: words, count: result.count))
    }

    public static func metal(_ source: String, stage: ShaderStage, hlsl: Bool = false) throws -> MetalShader {
        try metal(spirv: spirv(source, stage: stage, hlsl: hlsl))
    }

    public static func metal(spirv words: [UInt32]) throws -> MetalShader {
        var context: spvc_context?
        guard spvc_context_create(&context) == SPVC_SUCCESS, let context else { throw error("no SPIRV-Cross context") }
        defer { spvc_context_destroy(context) }
        func check(_ result: spvc_result, _ what: String) throws {
            guard result == SPVC_SUCCESS else {
                throw error("\(what): \(spvc_context_get_last_error_string(context).map { String(cString: $0) } ?? "")")
            }
        }

        var ir: spvc_parsed_ir?
        try words.withUnsafeBufferPointer { try check(spvc_context_parse_spirv(context, $0.baseAddress, $0.count, &ir), "Parsing SPIR-V") }
        var compiler: spvc_compiler?
        try check(spvc_context_create_compiler(context, SPVC_BACKEND_MSL, ir, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &compiler), "MSL compiler")
        guard let compiler else { throw error("no MSL compiler") }

        var options: spvc_compiler_options?
        try check(spvc_compiler_create_compiler_options(compiler, &options), "Options")
        spvc_compiler_options_set_uint(options, SPVC_COMPILER_OPTION_MSL_VERSION, 3 << 16)   // SPVC_MAKE_MSL_VERSION(3, 0, 0)
        try check(spvc_compiler_install_compiler_options(compiler, options), "Options")

        var output: UnsafePointer<CChar>?
        try check(spvc_compiler_compile(compiler, &output), "Translating to MSL")
        guard let output else { throw error("no MSL output") }

        var resources: spvc_resources?
        try check(spvc_compiler_create_shader_resources(compiler, &resources), "Reflection")
        func list(_ type: spvc_resource_type) -> [spvc_reflected_resource] {
            var pointer: UnsafePointer<spvc_reflected_resource>?
            var count = 0
            guard spvc_resources_get_resource_list_for_type(resources, type, &pointer, &count) == SPVC_SUCCESS, let pointer else { return [] }
            return Array(UnsafeBufferPointer(start: pointer, count: count))
        }

        var uniforms: [String: MetalShader.Uniform] = [:]
        var uniformSize = 0
        var uniformIndex: Int?
        if let block = list(SPVC_RESOURCE_TYPE_UNIFORM_BUFFER).first {
            let type = spvc_compiler_get_type_handle(compiler, block.base_type_id)
            for member in 0 ..< spvc_type_get_num_member_types(type) {
                var offset: UInt32 = 0, matrixStride: UInt32 = 0, arrayStride: UInt32 = 0
                spvc_compiler_type_struct_member_offset(compiler, type, member, &offset)
                let memberType = spvc_compiler_get_type_handle(compiler, spvc_type_get_member_type(type, member))
                let columns = Int(spvc_type_get_columns(memberType))
                if columns > 1 { spvc_compiler_type_struct_member_matrix_stride(compiler, type, member, &matrixStride) }
                var count = 1
                if spvc_type_get_num_array_dimensions(memberType) > 0 {
                    count = max(1, Int(spvc_type_get_array_dimension(memberType, 0)))
                    spvc_compiler_type_struct_member_array_stride(compiler, type, member, &arrayStride)
                }
                let base: MetalShader.Uniform.Base? = switch spvc_type_get_basetype(memberType) {
                case SPVC_BASETYPE_FP32: .float
                case SPVC_BASETYPE_INT32: .int
                case SPVC_BASETYPE_UINT32: .uint
                case SPVC_BASETYPE_BOOLEAN: .bool
                default: nil
                }
                guard let base, let name = spvc_compiler_get_member_name(compiler, block.base_type_id, member) else { continue }
                uniforms[String(cString: name)] = MetalShader.Uniform(
                    offset: Int(offset), base: base, vectorSize: Int(spvc_type_get_vector_size(memberType)), columns: columns,
                    matrixStride: Int(matrixStride), count: count, arrayStride: Int(arrayStride))
            }
            var size = 0
            spvc_compiler_get_declared_struct_size(compiler, type, &size)
            uniformSize = size
            uniformIndex = Int(spvc_compiler_msl_get_automatic_resource_binding(compiler, block.id))
        }
        var textures: [String: (texture: Int, sampler: Int)] = [:]
        for texture in list(SPVC_RESOURCE_TYPE_SAMPLED_IMAGE) {
            textures[String(cString: texture.name)] = (Int(spvc_compiler_msl_get_automatic_resource_binding(compiler, texture.id)),
                                                       Int(spvc_compiler_msl_get_automatic_resource_binding_secondary(compiler, texture.id)))
        }
        var attributes: [String: Int] = [:]
        for input in list(SPVC_RESOURCE_TYPE_STAGE_INPUT) where spvc_compiler_get_execution_model(compiler) == SpvExecutionModelVertex {
            attributes[String(cString: input.name)] = Int(spvc_compiler_get_decoration(compiler, input.id, SpvDecorationLocation))
        }
        return MetalShader(source: String(cString: output), uniforms: uniforms, uniformSize: uniformSize,
                           uniformBufferIndex: uniformIndex, textures: textures, attributes: attributes)
    }

    private static func error(_ text: String) -> ShaderCompileError { ShaderCompileError(description: text) }
}
