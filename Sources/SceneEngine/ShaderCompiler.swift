import CShaderCompiler
import CSPIRVCross
import Foundation

/// A shader stage translated to Metal Shading Language, with where its inputs live in the Metal function's arguments.
public struct MetalShader: Sendable {
    /// The MSL source; its entry point is `main0`.
    public let source: String
    /// Uniform name → byte offset in the single uniform buffer (the loose uniforms, gathered into one block).
    public let uniformOffsets: [String: Int]
    /// Size in bytes of that uniform buffer (0 when the stage has no uniforms) and its buffer index.
    public let uniformSize: Int
    public let uniformBufferIndex: Int?
    /// Texture (sampler2D) name → texture index; its sampler has the same index.
    public let textures: [String: Int]
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

        var offsets: [String: Int] = [:]
        var uniformSize = 0
        var uniformIndex: Int?
        if let block = list(SPVC_RESOURCE_TYPE_UNIFORM_BUFFER).first {
            let type = spvc_compiler_get_type_handle(compiler, block.base_type_id)
            for member in 0 ..< spvc_type_get_num_member_types(type) {
                var offset: UInt32 = 0
                spvc_compiler_type_struct_member_offset(compiler, type, member, &offset)
                if let name = spvc_compiler_get_member_name(compiler, block.base_type_id, member) {
                    offsets[String(cString: name)] = Int(offset)
                }
            }
            var size = 0
            spvc_compiler_get_declared_struct_size(compiler, type, &size)
            uniformSize = size
            uniformIndex = Int(spvc_compiler_msl_get_automatic_resource_binding(compiler, block.id))
        }
        var textures: [String: Int] = [:]
        for texture in list(SPVC_RESOURCE_TYPE_SAMPLED_IMAGE) {
            textures[String(cString: texture.name)] = Int(spvc_compiler_msl_get_automatic_resource_binding(compiler, texture.id))
        }
        var attributes: [String: Int] = [:]
        for input in list(SPVC_RESOURCE_TYPE_STAGE_INPUT) where spvc_compiler_get_execution_model(compiler) == SpvExecutionModelVertex {
            attributes[String(cString: input.name)] = Int(spvc_compiler_get_decoration(compiler, input.id, SpvDecorationLocation))
        }
        return MetalShader(source: String(cString: output), uniformOffsets: offsets, uniformSize: uniformSize,
                           uniformBufferIndex: uniformIndex, textures: textures, attributes: attributes)
    }

    private static func error(_ text: String) -> ShaderCompileError { ShaderCompileError(description: text) }
}
