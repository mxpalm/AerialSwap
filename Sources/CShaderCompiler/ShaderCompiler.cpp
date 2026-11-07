// A small C entry point over glslang's C++ API, which (unlike glslang's own C API) can turn on the relaxed Vulkan
// rules that let Wallpaper Engine's loose uniforms compile.
#include "CShaderCompiler.h"

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "glslang/Public/ResourceLimits.h"
#include "glslang/Public/ShaderLang.h"
#include "SPIRV/GlslangToSpv.h"

static char *copy(const std::string &s) {
    char *p = static_cast<char *>(std::malloc(s.size() + 1));
    if (p) std::memcpy(p, s.c_str(), s.size() + 1);
    return p;
}

int as_compile_spirv(const char *source, int stage, int hlsl, as_spirv *out) {
    static std::once_flag once;
    std::call_once(once, [] { glslang::InitializeProcess(); });
    *out = {nullptr, 0, nullptr};

    const EShLanguage language = stage == 0 ? EShLangVertex : EShLangFragment;
    glslang::TShader shader(language);
    shader.setStrings(&source, 1);
    shader.setEnvInput(hlsl ? glslang::EShSourceHlsl : glslang::EShSourceGlsl, language, glslang::EShClientVulkan, 100);
    shader.setEnvClient(glslang::EShClientVulkan, glslang::EShTargetVulkan_1_2);
    shader.setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_5);
    shader.setEnvInputVulkanRulesRelaxed();
    shader.setAutoMapBindings(true);
    shader.setAutoMapLocations(true);
    if (hlsl) shader.setEntryPoint("main");

    auto messages = static_cast<EShMessages>(EShMsgSpvRules | EShMsgVulkanRules | (hlsl ? EShMsgReadHlsl : 0));
    std::string log;
    bool ok = shader.parse(GetDefaultResources(), 450, false, messages);
    log += shader.getInfoLog();
    glslang::TProgram program;
    if (ok) {
        program.addShader(&shader);
        ok = program.link(messages) && program.mapIO();
        log += program.getInfoLog();
    }
    if (ok) {
        std::vector<unsigned int> spirv;
        glslang::SpvOptions options;
        options.validate = false;
        glslang::GlslangToSpv(*program.getIntermediate(language), spirv, &options);
        out->words = static_cast<uint32_t *>(std::malloc(spirv.size() * sizeof(uint32_t)));
        if (out->words) {
            std::memcpy(out->words, spirv.data(), spirv.size() * sizeof(uint32_t));
            out->count = spirv.size();
        } else {
            ok = false;
        }
    }
    out->log = copy(log);
    return ok ? 1 : 0;
}

void as_spirv_free(as_spirv *result) {
    std::free(result->words);
    std::free(result->log);
    *result = {nullptr, 0, nullptr};
}
