#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The result of `as_compile_spirv`: SPIR-V words on success, the compiler's log either way. Free with `as_spirv_free`.
typedef struct {
    uint32_t *words;
    size_t count;
    char *log;
} as_spirv;

/// Compiles one shader stage (0 vertex, 1 fragment) to Vulkan SPIR-V with glslang. `hlsl` reads it as HLSL (entry point
/// `main`) instead of GLSL. Loose uniforms are allowed (relaxed Vulkan rules: they become one uniform block), and
/// bindings and locations are assigned automatically. Returns 1 on success.
int as_compile_spirv(const char *source, int stage, int hlsl, as_spirv *out);
void as_spirv_free(as_spirv *result);

#ifdef __cplusplus
}
#endif
