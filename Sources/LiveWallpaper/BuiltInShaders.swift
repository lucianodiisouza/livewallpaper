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

    /// Common prelude: the Uniforms struct + a full-screen-triangle vertex function. Exposed so the
    /// AI generator can prepend the exact, fixed contract and only ask the model for `f_main`.
    static let prelude = """
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

    /// Concentric pulsing rings.
    static let rings = prelude + """

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = (fragCoord.xy - 0.5 * u.resolution) / u.resolution.y;
        float d = length(uv);
        float v = 0.5 + 0.5 * sin(d * 40.0 - u.time * u.speed * 3.0);
        return float4(v * u.tint.rgb, 1.0);
    }
    """

    /// Layered sine interference.
    static let interference = prelude + """

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = fragCoord.xy / u.resolution;
        float t = u.time * u.speed;
        float v = 0.0;
        for (int i = 1; i <= 4; i++) {
            float fi = float(i);
            v += sin(uv.x * 10.0 * fi + t * fi + uv.y * 6.0) / fi;
        }
        v = 0.5 + 0.5 * v;
        float3 col = 0.5 + 0.5 * cos(6.28318 * (v + float3(0.0, 0.33, 0.67)));
        return float4(col * u.tint.rgb, 1.0);
    }
    """

    /// Rotating spiral arms.
    static let spiral = prelude + """

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = (fragCoord.xy - 0.5 * u.resolution) / u.resolution.y;
        float a = atan2(uv.y, uv.x);
        float r = length(uv);
        float v = 0.5 + 0.5 * sin(a * 6.0 + r * 20.0 - u.time * u.speed * 2.0);
        return float4(v * u.tint.rgb, 1.0);
    }
    """

    /// Perspective tunnel.
    static let tunnel = prelude + """

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 p = (fragCoord.xy - 0.5 * u.resolution) / u.resolution.y;
        float a = atan2(p.y, p.x);
        float r = max(length(p), 0.001);
        float2 uv = float2(0.3 / r + u.time * u.speed * 0.5, a / 3.14159);
        float v = 0.5 + 0.5 * sin(uv.x * 12.0) * sin(uv.y * 30.0);
        float3 col = v * u.tint.rgb * clamp(r * 2.0, 0.0, 1.0);
        return float4(col, 1.0);
    }
    """

    /// Animated Voronoi cells.
    static let cells = prelude + """

    float2 hash2(float2 p) {
        p = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
        return fract(sin(p) * 43758.5453);
    }

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = fragCoord.xy / u.resolution.y * 8.0;
        float2 g = floor(uv);
        float2 f = fract(uv);
        float md = 1.5;
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                float2 o = float2(x, y);
                float2 c = o + 0.5 + 0.5 * sin(u.time * u.speed + 6.28318 * hash2(g + o));
                md = min(md, length(c - f));
            }
        }
        return float4((1.0 - md) * u.tint.rgb, 1.0);
    }
    """
}
