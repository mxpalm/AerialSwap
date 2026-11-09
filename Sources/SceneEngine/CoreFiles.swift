import Foundation

/// AerialSwap's own versions of the files every scene expects from Wallpaper Engine's installation: the base image
/// shader, shader headers, a few built-in effects that packages don't carry, and utility models. All written for
/// AerialSwap from what scenes call and pass; Wallpaper Engine itself is never needed. Paths are the ones scenes use.
/// A wallpaper's own copy of a file always wins over these (see `SceneFiles`).
public enum CoreFiles {
    public static let all: [String: String] = {
        var files: [String: String] = [
            "shaders/common.h": commonH,
            "shaders/common_blending.h": blendingH,
            "shaders/common_blur.h": blurH,
            "shaders/common_composite.h": compositeH,
            "shaders/common_perspective.h": perspectiveH,
            "shaders/common_fragment.h": "#include \"common.h\"\n",
            "shaders/common_vertex.h": "#include \"common.h\"\n",
            "shaders/effects/blur_downsample4.vert": passVertex,
            "shaders/effects/blur_downsample4.frag": downsampleFrag,
            "shaders/effects/blur_gaussian.vert": gaussianVert,
            "shaders/effects/blur_gaussian.frag": gaussianFrag,
            "shaders/effects/blur_combine.vert": combineVert,
            "shaders/effects/blur_combine.frag": combineFrag,
            "models/util/composelayer.json": #"{"material": "materials/util/composelayer.json", "aerialswap": "compose"}"#,
            "models/util/projectlayer.json": #"{"material": "materials/util/composelayer.json", "aerialswap": "compose"}"#,
            "models/util/fullscreenlayer.json":
                #"{"material": "materials/util/composelayer.json", "fullscreen": true, "aerialswap": "compose"}"#,
            "models/util/solidlayer.json": #"{"material": "materials/util/solidlayer.json", "solidlayer": true}"#,
            "materials/util/composelayer.json":
                #"{"passes": [{"shader": "genericimage2", "blending": "translucent", "textures": ["_rt_FullFrameBuffer"]}]}"#,
            "materials/util/solidlayer.json":
                #"{"passes": [{"shader": "genericimage2", "blending": "translucent", "textures": ["util/white"]}]}"#,
        ]
        for i in 0 ..< 16 { files["materials/util/solidlayer_instance_\(i).json"] = files["materials/util/solidlayer.json"] }
        for name in ["aerialswap/particle", "genericparticle"] {
            files["shaders/\(name).vert"] = particleVert
            files["shaders/\(name).frag"] = particleFrag
        }
        files["shaders/aerialswap/bloomextract.vert"] = passVertex
        files["shaders/aerialswap/bloomextract.frag"] = bloomExtractFrag
        files["shaders/aerialswap/blendimage.vert"] = blendImageVert
        files["shaders/aerialswap/blendimage.frag"] = blendImageFrag
        for name in ["aerialswap/image", "genericimage", "genericimage2", "genericimage3", "genericimage4"] {
            files["shaders/\(name).vert"] = imageVert
            files["shaders/\(name).frag"] = imageFrag
        }
        return files
    }()

    // MARK: - Image shaders

    /// AerialSwap's image layer shader, also the one layers are composited with. The renderer passes the texture
    /// rectangle to show (padding, sprite frame) as texture coordinates and sets `g_Color4` (color × brightness, alpha).
    static let imageVert = """
        uniform mat4 g_ModelViewProjectionMatrix;

        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;

        varying vec2 v_TexCoord;

        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
        }
        """

    static let imageFrag = """
        uniform sampler2D g_Texture0;
        uniform vec4 g_Color4;

        varying vec2 v_TexCoord;

        void main() {
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * g_Color4;
        }
        """

    /// Particles: the renderer builds each one's quad in scene units, with its color and alpha per vertex.
    static let particleVert = """
        uniform mat4 g_ModelViewProjectionMatrix;

        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        attribute vec4 a_Color;

        varying vec2 v_TexCoord;
        varying vec4 v_Color;

        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
            v_Color = a_Color;
        }
        """

    static let particleFrag = """
        uniform sampler2D g_Texture0;
        uniform float g_Overbright; // {"material":"ui_editor_properties_overbright","default":1}

        varying vec2 v_TexCoord;
        varying vec4 v_Color;

        void main() {
            vec4 color = texSample2D(g_Texture0, v_TexCoord) * v_Color;
            gl_FragColor = vec4(color.rgb * g_Overbright, color.a);
        }
        """

    /// Composites a layer with a blend mode (`BLENDMODE`, as in `ApplyBlending`) over a copy of the scene behind it
    /// (`g_Texture1`), which it reads where it lands on screen.
    static let blendImageVert = """
        uniform mat4 g_ModelViewProjectionMatrix;

        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;

        varying vec2 v_TexCoord;
        varying vec2 v_ScreenCoord;

        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
            v_ScreenCoord = vec2(gl_Position.x / gl_Position.w * 0.5 + 0.5, 0.5 - gl_Position.y / gl_Position.w * 0.5);
        }
        """

    static let blendImageFrag = """
        // [COMBO] {"combo":"BLENDMODE","default":0}
        #include "common_blending.h"

        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        uniform vec4 g_Color4;

        varying vec2 v_TexCoord;
        varying vec2 v_ScreenCoord;

        void main() {
            vec4 layer = texSample2D(g_Texture0, v_TexCoord) * g_Color4;
            vec4 behind = texSample2D(g_Texture1, v_ScreenCoord);
            gl_FragColor = vec4(ApplyBlending(BLENDMODE, behind.rgb, layer.rgb, layer.a), behind.a);
        }
        """

    // MARK: - Headers

    static let commonH = """
        #ifndef AS_COMMON_H
        #define AS_COMMON_H
        #define M_PI 3.14159265359
        #define M_PI_HALF 1.57079632679
        #define M_PI_2 6.28318530718
        #define SQRT_2 1.41421356237
        #define SQRT_3 1.73205080757

        vec2 rotateVec2(vec2 v, float r) {
            vec2 cs = vec2(cos(r), sin(r));
            return vec2(v.x * cs.x - v.y * cs.y, v.x * cs.y + v.y * cs.x);
        }

        float greyscale(vec3 color) { return dot(color, vec3(0.11, 0.59, 0.3)); }

        vec3 rgb2hsv(vec3 c) {
            vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
            vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
            vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
            float d = q.x - min(q.w, q.y);
            float e = 1.0e-10;
            return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
        }

        vec3 hsv2rgb(vec3 c) {
            vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
            vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
            return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
        }
        #endif
        """

    /// Photoshop-style blend modes. `ApplyBlending(mode, base, blend, opacity)` takes the editor's blend mode index,
    /// in the order Wallpaper Engine's editor lists them. 30 and 31 lie past that list: the tint effect defaults to 30 and
    /// bloom's composite to 31, read here as a multiplying tint and an add (a white tint, its usual default, then changes
    /// nothing, and bloom brightens). Other indices mix normally.
    static let blendingH = """
        #ifndef AS_BLENDING_H
        #define AS_BLENDING_H
        #include "common.h"

        vec3 BlendNormal(vec3 a, vec3 b) { return b; }
        vec3 BlendDarken(vec3 a, vec3 b) { return min(a, b); }
        vec3 BlendMultiply(vec3 a, vec3 b) { return a * b; }
        vec3 BlendColorBurn(vec3 a, vec3 b) { return 1.0 - min(vec3(1.0), (1.0 - a) / max(b, vec3(1e-5))); }
        vec3 BlendLinearBurn(vec3 a, vec3 b) { return max(a + b - 1.0, vec3(0.0)); }
        vec3 BlendLighten(vec3 a, vec3 b) { return max(a, b); }
        vec3 BlendScreen(vec3 a, vec3 b) { return 1.0 - (1.0 - a) * (1.0 - b); }
        vec3 BlendColorDodge(vec3 a, vec3 b) { return min(vec3(1.0), a / max(1.0 - b, vec3(1e-5))); }
        vec3 BlendLinearDodge(vec3 a, vec3 b) { return min(a + b, vec3(1.0)); }
        vec3 BlendOverlay(vec3 a, vec3 b) { return mix(2.0 * a * b, 1.0 - 2.0 * (1.0 - a) * (1.0 - b), step(0.5, a)); }
        vec3 BlendSoftLight(vec3 a, vec3 b) {
            return mix(2.0 * a * b + a * a * (1.0 - 2.0 * b), sqrt(a) * (2.0 * b - 1.0) + 2.0 * a * (1.0 - b), step(0.5, b));
        }
        vec3 BlendHardLight(vec3 a, vec3 b) { return BlendOverlay(b, a); }
        vec3 BlendVividLight(vec3 a, vec3 b) {
            return mix(BlendColorBurn(a, 2.0 * b), BlendColorDodge(a, 2.0 * (b - 0.5)), step(0.5, b));
        }
        vec3 BlendLinearLight(vec3 a, vec3 b) { return clamp(a + 2.0 * b - 1.0, 0.0, 1.0); }
        vec3 BlendPinLight(vec3 a, vec3 b) { return mix(min(a, 2.0 * b), max(a, 2.0 * (b - 0.5)), step(0.5, b)); }
        vec3 BlendHardMix(vec3 a, vec3 b) { return step(1.0, a + b); }
        vec3 BlendDifference(vec3 a, vec3 b) { return abs(a - b); }
        vec3 BlendExclusion(vec3 a, vec3 b) { return a + b - 2.0 * a * b; }
        vec3 BlendSubtract(vec3 a, vec3 b) { return max(a - b, vec3(0.0)); }
        vec3 BlendReflect(vec3 a, vec3 b) { return min(vec3(1.0), a * a / max(1.0 - b, vec3(1e-5))); }
        vec3 BlendGlow(vec3 a, vec3 b) { return BlendReflect(b, a); }
        vec3 BlendPhoenix(vec3 a, vec3 b) { return min(a, b) - max(a, b) + 1.0; }
        vec3 BlendAverage(vec3 a, vec3 b) { return (a + b) * 0.5; }
        vec3 BlendNegation(vec3 a, vec3 b) { return 1.0 - abs(1.0 - a - b); }
        vec3 BlendHue(vec3 a, vec3 b) { vec3 h = rgb2hsv(a); return hsv2rgb(vec3(rgb2hsv(b).x, h.y, h.z)); }
        vec3 BlendSaturation(vec3 a, vec3 b) { vec3 h = rgb2hsv(a); return hsv2rgb(vec3(h.x, rgb2hsv(b).y, h.z)); }
        vec3 BlendColor(vec3 a, vec3 b) { vec3 h = rgb2hsv(b); return hsv2rgb(vec3(h.x, h.y, rgb2hsv(a).z)); }
        vec3 BlendLuminosity(vec3 a, vec3 b) { vec3 h = rgb2hsv(a); return hsv2rgb(vec3(h.x, h.y, rgb2hsv(b).z)); }
        vec3 BlendDarkerColor(vec3 a, vec3 b) { return greyscale(a) < greyscale(b) ? a : b; }
        vec3 BlendLighterColor(vec3 a, vec3 b) { return greyscale(a) > greyscale(b) ? a : b; }
        vec3 BlendAdd(vec3 a, vec3 b) { return a + b; }

        // Brightness scales the color, saturation and contrast push it away from its grey and from mid grey (1 = unchanged).
        vec3 ContrastSaturationBrightness(vec3 color, float brightness, float saturation, float contrast) {
            vec3 c = color * brightness;
            c = mix(vec3(greyscale(c)), c, saturation);
            return mix(vec3(0.5), c, contrast);
        }

        #define BlendOpacity(base, blend, F, opacity) (F(base, blend) * (opacity) + (base) * (1.0 - (opacity)))

        vec3 ApplyBlending(const int mode, const vec3 a, const vec3 b, const float opacity) {
            vec3 r = b;
            if (mode == 1) r = BlendDarken(a, b);
            else if (mode == 2) r = BlendMultiply(a, b);
            else if (mode == 3) r = BlendColorBurn(a, b);
            else if (mode == 4) r = BlendLinearBurn(a, b);
            else if (mode == 5) r = BlendLighten(a, b);
            else if (mode == 6) r = BlendScreen(a, b);
            else if (mode == 7) r = BlendColorDodge(a, b);
            else if (mode == 8) r = BlendLinearDodge(a, b);
            else if (mode == 9) r = BlendOverlay(a, b);
            else if (mode == 10) r = BlendSoftLight(a, b);
            else if (mode == 11) r = BlendHardLight(a, b);
            else if (mode == 12) r = BlendVividLight(a, b);
            else if (mode == 13) r = BlendLinearLight(a, b);
            else if (mode == 14) r = BlendPinLight(a, b);
            else if (mode == 15) r = BlendHardMix(a, b);
            else if (mode == 16) r = BlendDifference(a, b);
            else if (mode == 17) r = BlendExclusion(a, b);
            else if (mode == 18) r = BlendSubtract(a, b);
            else if (mode == 19) r = BlendReflect(a, b);
            else if (mode == 20) r = BlendGlow(a, b);
            else if (mode == 21) r = BlendPhoenix(a, b);
            else if (mode == 22) r = BlendAverage(a, b);
            else if (mode == 23) r = BlendNegation(a, b);
            else if (mode == 24) r = BlendHue(a, b);
            else if (mode == 25) r = BlendSaturation(a, b);
            else if (mode == 26) r = BlendColor(a, b);
            else if (mode == 27) r = BlendLuminosity(a, b);
            else if (mode == 28) r = BlendDarkerColor(a, b);
            else if (mode == 29) r = BlendLighterColor(a, b);
            else if (mode == 30) r = BlendMultiply(a, b);
            else if (mode == 31) r = BlendAdd(a, b);
            return mix(a, r, opacity);
        }
        #endif
        """

    /// Gaussian kernels along a direction, as macros so they read the shader's own `g_Texture0`.
    static let blurH = """
        #define AS_BLUR_TAP(uv, d, w, o) (texSample2D(g_Texture0, (uv) + (d) * (o)) + texSample2D(g_Texture0, (uv) - (d) * (o))) * (w)
        #define blur3a(uv, d) (texSample2D(g_Texture0, uv) * 0.5 + AS_BLUR_TAP(uv, d, 0.25, 1.0))
        #define blur7a(uv, d) (texSample2D(g_Texture0, uv) * 0.2270270270 + AS_BLUR_TAP(uv, d, 0.3162162162, 1.3846153846) \\
            + AS_BLUR_TAP(uv, d, 0.0702702703, 3.2307692308))
        #define blur13a(uv, d) (texSample2D(g_Texture0, uv) * 0.1964825501 + AS_BLUR_TAP(uv, d, 0.2969069647, 1.4117647059) \\
            + AS_BLUR_TAP(uv, d, 0.0944703979, 3.2941176471) + AS_BLUR_TAP(uv, d, 0.0103813624, 5.1764705882))
        """

    /// How a blurred result goes back over the original (`COMPOSITE`: 0 replace, 1 blend, 2 under, 3 cut out).
    static let compositeH = """
        #include "common_blending.h"
        vec2 ApplyCompositeOffset(vec2 coords, vec2 resolution) { return coords; }
        vec4 ApplyComposite(vec4 original, vec4 blurred) {
        #if COMPOSITE == 1
            return vec4(ApplyBlending(BLENDMODE, original.rgb, blurred.rgb, blurred.a), max(original.a, blurred.a));
        #elif COMPOSITE == 2
            return vec4(mix(blurred.rgb, original.rgb, original.a), max(original.a, blurred.a));
        #elif COMPOSITE == 3
            return vec4(blurred.rgb, blurred.a * (1.0 - original.a));
        #else
            return blurred;
        #endif
        }
        """

    /// The projective map taking the unit square to the quad p0 p1 p2 p3 (Heckbert's square-to-quad).
    static let perspectiveH = """
        mat3 squareToQuad(vec2 p0, vec2 p1, vec2 p2, vec2 p3) {
            vec2 d1 = p1 - p2, d2 = p3 - p2, s = p0 - p1 + p2 - p3;
            float den = d1.x * d2.y - d2.x * d1.y;
            float g = abs(den) < 1e-8 ? 0.0 : (s.x * d2.y - d2.x * s.y) / den;
            float h = abs(den) < 1e-8 ? 0.0 : (d1.x * s.y - s.x * d1.y) / den;
            return mat3(p1.x - p0.x + g * p1.x, p1.y - p0.y + g * p1.y, g,
                        p3.x - p0.x + h * p3.x, p3.y - p0.y + h * p3.y, h,
                        p0.x, p0.y, 1.0);
        }
        """

    // MARK: - Built-in blur effect (for packages that don't carry its shaders)

    static let passVertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = vec4(a_Position, 1.0);
            v_TexCoord = a_TexCoord;
        }
        """

    static let downsampleFrag = """
        uniform sampler2D g_Texture0; // {"hidden":true}
        uniform vec4 g_Texture0Resolution;
        varying vec2 v_TexCoord;
        void main() {
            vec2 t = 1.0 / g_Texture0Resolution.zw;
            gl_FragColor = (texSample2D(g_Texture0, v_TexCoord + t * vec2(-1.0, -1.0)) + texSample2D(g_Texture0, v_TexCoord + t * vec2(1.0, -1.0))
                + texSample2D(g_Texture0, v_TexCoord + t * vec2(-1.0, 1.0)) + texSample2D(g_Texture0, v_TexCoord + t * vec2(1.0, 1.0))) * 0.25;
        }
        """

    /// Scene bloom's first step: the frame at a quarter of its size (four taps), only what's brighter than the threshold.
    static let bloomExtractFrag = """
        uniform sampler2D g_Texture0; // {"hidden":true}
        uniform vec4 g_Texture0Resolution;
        uniform float g_Threshold; // {"material":"threshold","default":0.65}
        varying vec2 v_TexCoord;
        void main() {
            vec2 t = 1.0 / g_Texture0Resolution.zw;
            vec3 c = (texSample2D(g_Texture0, v_TexCoord + t * vec2(-1.0, -1.0)).rgb + texSample2D(g_Texture0, v_TexCoord + t * vec2(1.0, -1.0)).rgb
                + texSample2D(g_Texture0, v_TexCoord + t * vec2(-1.0, 1.0)).rgb + texSample2D(g_Texture0, v_TexCoord + t * vec2(1.0, 1.0)).rgb) * 0.25;
            gl_FragColor = vec4(max(c - vec3(g_Threshold, g_Threshold, g_Threshold), vec3(0.0, 0.0, 0.0)), 1.0);
        }
        """

    static let gaussianVert = """
        uniform vec2 g_Scale; // {"material":"scale","default":"1 1"}
        uniform vec4 g_Texture0Resolution;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec4 v_TexCoord;
        void main() {
            gl_Position = vec4(a_Position, 1.0);
            v_TexCoord.xy = a_TexCoord;
        #if VERTICAL
            v_TexCoord.zw = vec2(0.0, g_Scale.y / g_Texture0Resolution.w);
        #else
            v_TexCoord.zw = vec2(g_Scale.x / g_Texture0Resolution.z, 0.0);
        #endif
        }
        """

    static let gaussianFrag = """
        #include "common_blur.h"
        varying vec4 v_TexCoord;
        uniform sampler2D g_Texture0; // {"hidden":true}
        void main() { gl_FragColor = blur13a(v_TexCoord.xy, v_TexCoord.zw); }
        """

    static let combineVert = """
        uniform vec4 g_Texture1Resolution;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec4 v_TexCoord;
        void main() {
            gl_Position = vec4(a_Position, 1.0);
            v_TexCoord.xy = a_TexCoord;
            v_TexCoord.zw = a_TexCoord * g_Texture1Resolution.zw / max(g_Texture1Resolution.xy, vec2(1.0));
        }
        """

    static let combineFrag = """
        // [COMBO] {"combo":"COMPOSITE","default":0}
        // [COMBO] {"combo":"BLENDMODE","default":0}
        // [COMBO] {"combo":"BLURALPHA","default":1}
        #include "common_composite.h"
        varying vec4 v_TexCoord;
        uniform sampler2D g_Texture0; // {"hidden":true}
        uniform sampler2D g_Texture1; // {"combo":"MASK","default":"util/white"}
        uniform sampler2D g_Texture2; // {"hidden":true}
        void main() {
            vec4 blurred = texSample2D(g_Texture0, v_TexCoord.xy);
            vec4 original = texSample2D(g_Texture2, v_TexCoord.xy);
            float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
            blurred = mix(original, ApplyComposite(original, blurred), mask);
        #if BLURALPHA == 0
            blurred.a = original.a;
        #endif
            gl_FragColor = blurred;
        }
        """
}
