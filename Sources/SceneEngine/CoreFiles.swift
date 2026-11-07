import Foundation

/// AerialSwap's own versions of the files every scene expects from Wallpaper Engine's installation (base shaders,
/// shader headers, utility models), written for AerialSwap; Wallpaper Engine itself is never needed. Paths are the
/// ones scenes use. The renderer's phase fills in the rest of the core.
public enum CoreFiles {
    public static let all: [String: String] = [
        "shaders/common.h": commonH,
    ]

    /// Helpers shaders call that GLSL lacks.
    static let commonH = """
        #define M_PI 3.14159265359
        #define M_PI_HALF 1.57079632679
        #define M_PI_2 6.28318530718
        #define SQRT_2 1.41421356237

        vec2 rotateVec2(vec2 v, float r) {
            vec2 cs = vec2(cos(r), sin(r));
            return vec2(v.x * cs.x - v.y * cs.y, v.x * cs.y + v.y * cs.x);
        }

        float greyscale(vec3 color) { return dot(color, vec3(0.11, 0.59, 0.3)); }
        """
}
