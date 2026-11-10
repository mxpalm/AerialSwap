import Metal
import Testing
@testable import SceneEngine

/// The dialect quirks found in real wallpapers, in small made-up shaders.
@Suite struct ShaderTranslatorTests {
    static let vertex = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        varying vec4 v_Samples[2];
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
            v_Samples[0] = vec4(a_TexCoord, 0.0, 0.0);
            v_Samples[1] = vec4(a_TexCoord, 1.0, 1.0);
        }
        """

    static func compile(fragment: String, combos: [String: Int] = [:]) throws {
        let shader = ShaderTranslator.translate(vertex: vertex, fragment: fragment, combos: combos)
        _ = try ShaderTranslator.compile(shader.vertex, stage: .vertex)
        _ = try ShaderTranslator.compile(shader.fragment, stage: .fragment)
    }

    @Test func varyingArraysKeepTheirSize() throws {
        try Self.compile(fragment: """
            uniform sampler2D g_Texture0;
            varying vec2 v_TexCoord;
            varying vec4 v_Samples[2];
            void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord) + v_Samples[0] * v_Samples[1].x; }
            """)
    }

    @Test func commentsOnIfLinesAreNotUndefinedNames() throws {
        let shader = ShaderTranslator.translate(vertex: Self.vertex, fragment: """
            float greyish(vec3 color) { return color.r; }
            void main() {
            #if MODE == 1 // is color RGB
                gl_FragColor = vec4(greyish(vec3(1.0)));
            #else
                gl_FragColor = vec4(0.0);
            #endif
            }
            """, combos: [:])
        #expect(shader.fragment.contains("#define MODE 0"))
        #expect(!shader.fragment.contains("#define color 0"))
        _ = try ShaderTranslator.compile(shader.fragment, stage: .fragment)
    }

    @Test func anExtraEndifIsDropped() throws {
        try Self.compile(fragment: """
            void main() { gl_FragColor = vec4(1.0); }
            #endif
            """)
    }

    @Test func hlslConversionsAreRepaired() throws {
        try Self.compile(fragment: """
            uniform sampler2D g_Texture0;
            uniform float u_Amount;
            varying vec2 v_TexCoord;
            void main() {
                vec3 color = texSample2D(g_Texture0, v_TexCoord);
                float edge = step(u_Amount, 0);
                color = mix(color, 1, edge);
                if (u_Amount) { color *= 0.5; }
                gl_FragColor = vec4(color, 1.0);
            }
            """)
    }

    @Test func fragmentShadersMayChangeTheirInputs() throws {
        try Self.compile(fragment: """
            uniform sampler2D g_Texture0;
            varying vec2 v_TexCoord;
            void main() {
                v_TexCoord.y = 1.0 - v_TexCoord.y;
                gl_FragColor = texSample2D(g_Texture0, v_TexCoord);
            }
            """)
    }

    @Test func vertexShadersMayChangeTheirAttributes() throws {
        let shader = ShaderTranslator.translate(vertex: """
            uniform mat4 g_ModelViewProjectionMatrix;
            attribute vec3 a_Position;
            attribute vec2 a_TexCoord;
            varying vec2 v_TexCoord;
            void main() {
                a_TexCoord.y = 1.0 - a_TexCoord.y;
                gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
                v_TexCoord = a_TexCoord;
            }
            """, fragment: "varying vec2 v_TexCoord;\nvoid main() { gl_FragColor = vec4(v_TexCoord, 0.0, 1.0); }", combos: [:])
        #expect(shader.attributes["a_TexCoord"] == 1)
        _ = try ShaderTranslator.compile(shader.vertex, stage: .vertex)
    }

    @Test func mismatchedVectorsAreTruncated() throws {
        try Self.compile(fragment: """
            uniform vec2 u_Offset;
            varying vec2 v_TexCoord;
            void main() {
                vec3 position = vec3(v_TexCoord, 0.0);
                gl_FragColor = vec4(length(position - u_Offset));
            }
            """)
    }

    /// Metal only links stages whose varyings match in type and are all written; HLSL is looser.
    static func link(vertex: String, fragment: String) throws {
        let shader = ShaderTranslator.translate(vertex: vertex, fragment: fragment, combos: [:])
        let device = try #require(MTLCreateSystemDefaultDevice())
        let v = try ShaderTranslator.compile(shader.vertex, stage: .vertex)
        let f = try ShaderTranslator.compile(shader.fragment, stage: .fragment)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try device.makeLibrary(source: v.source, options: nil).makeFunction(name: "main0")
        descriptor.fragmentFunction = try device.makeLibrary(source: f.source, options: nil).makeFunction(name: "main0")
        let vertices = MTLVertexDescriptor()
        for location in v.attributes.values {
            vertices.attributes[location].format = .float4
            vertices.attributes[location].bufferIndex = 30
        }
        vertices.layouts[30].stride = 16
        descriptor.vertexDescriptor = vertices
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        _ = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    @Test func varyingsOfDifferentTypesLink() throws {
        try Self.link(vertex: """
            attribute vec3 a_Position;
            attribute vec2 a_TexCoord;
            varying vec4 v_TexCoord;
            void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = vec4(a_TexCoord, 0.0, 1.0); }
            """, fragment: """
            varying vec2 v_TexCoord;
            void main() { gl_FragColor = vec4(v_TexCoord.x, v_TexCoord.y, 0.0, 1.0); }
            """)
    }

    @Test func varyingsTheVertexStageLeavesOutLink() throws {
        try Self.link(vertex: """
            attribute vec3 a_Position;
            varying vec2 v_Declared;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """, fragment: """
            varying vec2 v_Declared;
            varying vec4 v_Missing;
            void main() { gl_FragColor = vec4(v_Declared, 0.0, 1.0) + v_Missing; }
            """)
    }
}
