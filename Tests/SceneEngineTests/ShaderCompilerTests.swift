import Metal
import Testing
@testable import SceneEngine

@Suite struct ShaderCompilerTests {
    static let fragment = """
        #version 450
        uniform sampler2D g_Texture0;
        uniform float g_Time;
        uniform vec2 g_Offset;
        layout(location = 0) in vec2 v_TexCoord;
        layout(location = 0) out vec4 fragColor;
        void main() { fragColor = texture(g_Texture0, v_TexCoord + g_Offset * g_Time); }
        """

    @Test func glslBecomesMetalThatCompiles() throws {
        let shader = try ShaderCompiler.metal(Self.fragment, stage: .fragment)
        #expect(shader.uniformOffsets.keys.sorted() == ["g_Offset", "g_Time"])
        #expect(shader.textures["g_Texture0"] != nil)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: shader.source, options: nil)
        #expect(library.makeFunction(name: "main0") != nil)
    }

    @Test func vertexAttributesAreReflected() throws {
        let shader = try ShaderCompiler.metal("""
            #version 450
            uniform mat4 g_ModelViewProjectionMatrix;
            in vec3 a_Position;
            in vec2 a_TexCoord;
            out vec2 v_TexCoord;
            void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }
            """, stage: .vertex)
        #expect(Set(shader.attributes.keys) == ["a_Position", "a_TexCoord"])
        #expect(shader.uniformSize == 64)
    }

    @Test func errorsCarryTheLog() {
        #expect(throws: ShaderCompileError.self) { try ShaderCompiler.spirv("void main() { nope; }", stage: .fragment) }
    }
}
