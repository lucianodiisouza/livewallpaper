import Foundation

/// Built-in Metal fragment shaders, embedded as source strings so they compile at runtime with
/// `device.makeLibrary(source:)` and need no resource bundling (works under `swift run` and in the
/// assembled .app alike). In M2, community `.livewallpaper` bundles will supply their own `.metal`
/// source through the same MetalRenderer path.
///
/// Each shader shares the same pipeline: a full-screen triangle vertex stage + a fragment stage
/// reading a `Uniforms` buffer (resolution, time, speed, tint). The Swift-side layout is mirrored
/// by `MetalUniforms`.
enum BuiltInShaders {

    /// Common prelude: the Uniforms struct + a full-screen-triangle vertex function.
    private static let prelude = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 resolution;
        float  time;
        float  speed;
        float4 tint;      // rgb used; a = unused
    };

    struct VOut { float4 position [[position]]; };

    vertex VOut v_main(uint vid [[vertex_id]]) {
        // Oversized triangle covering the whole clip space.
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }
    """

    /// Classic plasma — cheap, obviously animated, good for eyeballing the occlusion pause.
    static let plasma = prelude + """

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = fragCoord.xy / u.resolution;
        float t = u.time * u.speed;
        float v = sin(uv.x * 10.0 + t)
                + sin(uv.y * 10.0 + t)
                + sin((uv.x + uv.y) * 10.0 + t)
                + sin(length(uv - 0.5) * 20.0 - t * 2.0);
        v *= 0.25;
        float3 col = 0.5 + 0.5 * cos(6.28318 * (v + float3(0.0, 0.33, 0.67)));
        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """

    /// Matrix-style "code rain": columns of faux glyphs falling with a bright head. Used to
    /// generate the importable sample package (`--make-sample`).
    static let matrixRain = prelude + """

    float mrand(float2 p) { return fract(sin(dot(p, float2(41.13, 289.7))) * 43758.5453); }

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float cell = 14.0;
        float2 px = fragCoord.xy;
        float2 id = floor(px / cell);
        float2 cuv = fract(px / cell);
        float rows = max(1.0, u.resolution.y / cell);

        float speed = mix(3.0, 10.0, mrand(float2(id.x, 1.0))) * max(0.05, u.speed);
        float head = fract(u.time * speed * 0.06 + mrand(float2(id.x, 7.0))) * rows;

        float dist = head - id.y;
        if (dist < 0.0) dist += rows;
        float trail = 10.0;
        float b = (dist < trail) ? (1.0 - dist / trail) : 0.0;
        float headGlow = (dist < 1.0) ? 1.0 : 0.0;

        // Faux glyph: a 5x5 bit pattern per cell that flips a few times per second.
        float t = floor(u.time * 6.0) / 6.0;
        float2 g = floor(cuv * 5.0);
        float bit = step(0.5, mrand(id * 1.7 + g * 3.1 + t));

        float3 green = float3(0.15, 1.0, 0.30);
        float3 col = green * b * bit;
        col += float3(0.85, 1.0, 0.9) * headGlow * bit;   // white-hot head
        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """

    /// Soft flowing bands — an aurora-ish gradient.
    static let aurora = prelude + """

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = fragCoord.xy / u.resolution;
        float t = u.time * u.speed * 0.4;
        float3 col = float3(0.0);
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float band = 1.0 - abs(uv.y - 0.5 + 0.18 * sin(uv.x * 6.0 + t + fi * 1.3));
            float w = 0.5 + 0.5 * sin(uv.x * 3.0 + t + fi * 2.1);
            col[i] = smoothstep(0.2, 1.0, band * w);
        }
        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """
}
