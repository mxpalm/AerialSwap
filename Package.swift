// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AerialSwap",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(name: "AerialSwap", dependencies: ["SceneEngine"], path: "Sources/AerialSwap"),
        // Wallpaper Engine scenes: reading their packages and rendering them with Metal (see Sources/SceneEngine).
        .target(name: "SceneEngine", dependencies: ["CShaderCompiler", "CSPIRVCross"], path: "Sources/SceneEngine"),
        // glslang's C++ API behind one C function (glslang's own C API can't relax the Vulkan rules).
        .target(
            name: "CShaderCompiler", dependencies: ["CGlslang"], path: "Sources/CShaderCompiler",
            cxxSettings: [.headerSearchPath("../../ThirdParty/glslang")]
        ),
        .testTarget(name: "SceneEngineTests", dependencies: ["SceneEngine"], path: "Tests/SceneEngineTests"),

        // Shader compilers, vendored unchanged from their releases (ThirdParty/*/LICENSE*): glslang turns the
        // scenes' GLSL into SPIR-V, SPIRV-Cross turns SPIR-V into Metal Shading Language.
        .target(
            name: "CGlslang", path: "ThirdParty/glslang",
            exclude: ["LICENSE.txt", "glslang/stub.cpp", "glslang/CInterface", "SPIRV/CInterface"],
            publicHeadersPath: "glslang/Public",
            cxxSettings: [.headerSearchPath("."), .define("ENABLE_HLSL"), .define("GLSLANG_OSINCLUDE_UNIX")]
        ),
        .target(
            name: "CSPIRVCross", path: "ThirdParty/SPIRV-Cross",
            exclude: ["LICENSE", "spirv_cpp.cpp", "spirv_hlsl.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [
                .define("SPIRV_CROSS_C_API_MSL", to: "1"), .define("SPIRV_CROSS_C_API_GLSL", to: "1"),
                .define("SPIRV_CROSS_C_API_REFLECT", to: "1"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
