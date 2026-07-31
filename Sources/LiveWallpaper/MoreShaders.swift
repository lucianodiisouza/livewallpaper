import Foundation

/// Phase-2 workshop inventory: 7 fragment shaders covering astro, topographic, and electronic-component
/// looks. Same `Uniforms` contract as `BuiltInShaders` (resolution, time, speed,
/// tint) so they drop into the existing renderer without changes.
///
/// These are intentionally **not** in `WallpaperCatalog.all` (the built-in menu) — they're shipped
/// as exportable `.livewallpaper` packages (see `SampleMaker.batchExport`) so the workshop gets
/// fresh inventory without bloating the in-app menu.
enum MoreShaders {

    /// Common prelude: the Uniforms struct + a full-screen-triangle vertex function.
    /// Kept byte-for-byte compatible with `BuiltInShaders.prelude` so `MTLDevice.makeLibrary(source:)`
    /// produces a pipeline that plugs straight into `MetalRenderer` / `ThumbnailRenderer`.
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
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }
    """

    /// Shared value-noise / fBm toolkit. Same organic domain-warp machinery that makes `nebulaOrion`
    /// read as *depth* rather than flat geometry — reused by every redesigned shader below so they all
    /// share that atmospheric quality instead of drawing hard clip-art shapes.
    private static let noise = """

    float hash11(float p) { return fract(sin(p * 91.345) * 47453.5453); }
    float hash21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
    float vnoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float a = hash21(i);
        float b = hash21(i + float2(1, 0));
        float c = hash21(i + float2(0, 1));
        float d = hash21(i + float2(1, 1));
        float2 uu = f * f * (3.0 - 2.0 * f);
        return mix(mix(a, b, uu.x), mix(c, d, uu.x), uu.y);
    }
    float fbm(float2 p) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 6; i++) { v += a * vnoise(p); p = p * 2.02 + float2(37.1, 17.7); a *= 0.5; }
        return v;
    }
    // Distance from point p to the segment (0,0)→b. Handy for traces / graph connectors.
    float segd(float2 p, float2 b) {
        float h = clamp(dot(p, b) / dot(b, b), 0.0, 1.0);
        return length(p - b * h);
    }
    """

    // MARK: - Starfields & nebulas (2)

    /// Diffuse emission nebula: layered fractal noise + a hot core, dust lane sweeping through.
    /// Two-octave value noise warped by a slow flow field; tinted hot→cool across the field.
    static let nebulaOrion = prelude + """

    float hash11(float p) { return fract(sin(p * 91.345) * 47453.5453); }
    float vnoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float a = hash11(dot(i, float2(1.0, 57.0)));
        float b = hash11(dot(i + float2(1,0), float2(1.0, 57.0)));
        float c = hash11(dot(i + float2(0,1), float2(1.0, 57.0)));
        float d = hash11(dot(i + float2(1,1), float2(1.0, 57.0)));
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }
    float fbm(float2 p) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 5; i++) {
            v += a * vnoise(p);
            p *= 2.03;
            a *= 0.5;
        }
        return v;
    }

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = (fragCoord.xy - 0.5 * u.resolution) / u.resolution.y;
        float t = u.time * u.speed * 0.05;

        // Warp the sample point through a slow flow field.
        float2 q = float2(fbm(uv * 1.5 + t), fbm(uv * 1.5 - t + 5.2));
        float2 r = float2(fbm(uv * 3.0 + 4.0 * q + t * 1.7),
                          fbm(uv * 3.0 + 4.0 * q + t * 1.7 + 9.1));
        float n = fbm(uv * 2.0 + 4.0 * r);

        // Hot pinkish core → cooler blue edge.
        float3 hot  = float3(1.0, 0.45, 0.65);
        float3 cool = float3(0.15, 0.25, 0.65);
        float3 col  = mix(cool, hot, smoothstep(0.25, 0.75, n));

        // Bright core highlight.
        col += float3(1.0, 0.85, 0.7) * pow(smoothstep(0.55, 0.85, n), 4.0) * 0.8;

        // Dust lane across the middle.
        float lane = exp(-pow((uv.y - 0.05 * sin(uv.x * 3.0 + t * 6.0)) * 6.0, 2.0));
        col *= 1.0 - 0.6 * lane;

        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """

    /// Milky-Way: a glowing galactic core band carved by fbm dust lanes, over a deep-space gradient
    /// with three parallax star layers and a few bright hero stars. Warm core → cool edges.
    static let nebulaMilkyWay = prelude + noise + """

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 res = u.resolution;
        float2 uv = (fragCoord.xy - 0.5 * res) / res.y;
        float t = u.time * u.speed;

        // Deep-space base: very dark, faint vertical shift.
        float3 col = mix(float3(0.015, 0.02, 0.05), float3(0.03, 0.02, 0.06), uv.y * 0.5 + 0.5);

        // Galactic band: a soft glowing ridge, slightly tilted, thick with fbm nebulosity.
        float2 bp = float2(uv.x, uv.y - 0.14 * uv.x);
        float band = exp(-bp.y * bp.y * 5.0);
        float2 w = float2(fbm(uv * 2.0 + 0.05 * t), fbm(uv * 2.0 - 0.05 * t + 4.0));
        float cloud = fbm(uv * 3.0 + 1.6 * w);
        float glow = band * (0.45 + 0.95 * cloud);
        float3 core = float3(1.0, 0.86, 0.62);
        float3 edge = float3(0.32, 0.34, 0.72);
        col += mix(edge, core, band * band) * glow * 0.65;

        // Dark dust lanes cutting through the band.
        float dust = smoothstep(0.42, 0.72, fbm(uv * 4.5 + 8.0 + 0.03 * t));
        col *= 1.0 - 0.6 * dust * band;

        // Parallax star layers.
        for (int L = 0; L < 3; L++) {
            float fl = float(L);
            float scale = 55.0 + fl * 75.0;
            float2 p = uv * scale + float2(17.0 * fl, -9.0 * fl);
            float2 ip = floor(p), fp = fract(p) - 0.5;
            float r = hash21(ip + 31.0 * fl);
            float thr = 0.973 - 0.004 * fl;
            if (r > thr) {
                float b = (r - thr) / (1.0 - thr);
                float star = pow(smoothstep(0.5, 0.0, length(fp)), 3.0);
                float tw = 0.6 + 0.4 * sin(t * 3.0 + r * 40.0);
                float3 sc = mix(float3(0.8, 0.85, 1.0), float3(1.0, 0.95, 0.85), hash11(r * 7.0));
                col += sc * star * b * tw * (1.2 - 0.3 * fl);
            }
        }

        // A handful of bright hero stars with a soft diffraction cross.
        for (int i = 0; i < 5; i++) {
            float fi = float(i);
            float2 sp = (float2(hash11(fi * 2.1), hash11(fi * 5.7)) - 0.5) * float2(3.0, 1.6);
            float d = length(uv - sp);
            float coreDot = pow(smoothstep(0.04, 0.0, d), 2.0);
            float cross = smoothstep(0.0025, 0.0, abs(uv.x - sp.x)) * smoothstep(0.13, 0.0, abs(uv.y - sp.y))
                        + smoothstep(0.0025, 0.0, abs(uv.y - sp.y)) * smoothstep(0.13, 0.0, abs(uv.x - sp.x));
            col += float3(0.9, 0.95, 1.0) * (coreDot * 1.4 + cross * 0.35);
        }

        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """

    // MARK: - Gas planet wave forms (1)

    /// Jupiter: full-frame turbulent gas driven by domain-warped fbm along latitude lines, with a real
    /// vortex — the domain is rotated around the Great Red Spot so the bands *wrap* into the storm
    /// instead of a stamped-on ellipse. This is the `orion` flow trick applied to banded gas.
    static let planetJupiter = prelude + noise + """

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 res = u.resolution;
        float2 uv = fragCoord.xy / res;
        float aspect = res.x / res.y;
        float t = u.time * u.speed * 0.15;

        // Great Red Spot: swirl the sampling domain around it, strongest at the centre.
        float2 c = float2(0.68, 0.40);
        float2 d = (uv - c) * float2(aspect, 1.0);
        float rad = length(d);
        float swirl = exp(-rad * 6.0) * 2.6;
        float ca = cos(swirl), sa = sin(swirl);
        float2 dr = float2(ca * d.x - sa * d.y, sa * d.x + ca * d.y) / float2(aspect, 1.0);
        float2 uvs = c + dr;

        // Domain-warped latitudinal bands.
        float2 warp = float2(fbm(float2(uvs.x * 3.0, uvs.y * 6.0) + 0.3 * t),
                             fbm(float2(uvs.x * 3.0, uvs.y * 6.0) + 10.0 - 0.2 * t));
        float y = uvs.y + 0.06 * warp.x;
        float turb = fbm(float2(uvs.x * 4.0 + 2.0 * warp.y, uvs.y * 10.0));
        float bands = 0.5 + 0.5 * sin(y * 26.0 + 3.0 * turb + sin(uvs.x * 3.0));

        // Cream → ochre → rust → brown.
        float3 c1 = float3(0.96, 0.90, 0.78);
        float3 c2 = float3(0.85, 0.62, 0.35);
        float3 c3 = float3(0.62, 0.34, 0.18);
        float3 c4 = float3(0.35, 0.18, 0.12);
        float3 col = mix(c4, c3, smoothstep(0.0, 0.4, bands));
        col = mix(col, c2, smoothstep(0.35, 0.7, bands));
        col = mix(col, c1, smoothstep(0.65, 1.0, bands));

        // GRS warm tint + darker eye.
        float grs = exp(-rad * 7.0);
        col = mix(col, float3(0.82, 0.34, 0.20), grs * 0.7);
        col *= 1.0 - 0.30 * exp(-rad * 34.0);

        // Depth vignette.
        float vig = smoothstep(1.25, 0.2, length((uv - 0.5) * float2(aspect, 1.0)));
        col *= 0.78 + 0.22 * vig;

        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """

    // MARK: - Topographic / generative (2)

    /// Contour map: a real fbm height field sliced into many fine, evenly-spaced contour lines
    /// (crisp via `fwidth`), tinted by elevation from deep teal → sand. Reads like a topographic
    /// survey / wind-carved dunes; the field breathes slowly.
    static let topoContours = prelude + noise + """

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = (fragCoord.xy - 0.5 * u.resolution) / u.resolution.y;
        float t = u.time * u.speed * 0.05;

        // Layered fbm height field.
        float h = fbm(uv * 2.2 + float2(0.0, t));
        h += 0.5 * fbm(uv * 4.6 - float2(t, 0.0));

        // Many contour rings.
        float e = h * 11.0;
        float f = fract(e);
        float dist = min(f, 1.0 - f);
        float w = fwidth(e) * 1.2;
        float line = 1.0 - smoothstep(0.0, w, dist);

        // Elevation palette.
        float3 lo  = float3(0.06, 0.10, 0.16);
        float3 mid = float3(0.14, 0.32, 0.34);
        float3 hi  = float3(0.86, 0.70, 0.44);
        float3 bg = mix(lo, mid, smoothstep(0.2, 0.55, h));
        bg = mix(bg, hi, smoothstep(0.55, 0.95, h));
        float3 col = mix(bg, float3(0.98, 0.95, 0.88), line * 0.85);

        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """

    /// Shaded relief: a continuous fbm terrain lit by a low sun. The surface normal comes from the
    /// height gradient, so ridges and valleys catch light like a real relief map; an elevation palette
    /// (water → sand → grass → rock → snow) plus faint contour lines. Drifts slowly.
    static let topoIsometric = prelude + noise + """

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 res = u.resolution;
        float2 uv = fragCoord.xy / res;
        float aspect = res.x / res.y;
        float2 p = (uv - 0.5) * float2(aspect, 1.0) * 3.0 + float2(0.0, u.time * u.speed * 0.03);

        float eps = 0.008;
        float h  = fbm(p);
        float hx = fbm(p + float2(eps, 0.0));
        float hy = fbm(p + float2(0.0, eps));
        float3 n = normalize(float3((h - hx) / eps, (h - hy) / eps, 1.4));
        float3 lightDir = normalize(float3(-0.6, 0.7, 0.7));
        float diff = clamp(dot(n, lightDir), 0.0, 1.0);

        // Elevation palette.
        float3 water = float3(0.09, 0.22, 0.40);
        float3 sand  = float3(0.80, 0.72, 0.48);
        float3 grass = float3(0.26, 0.46, 0.25);
        float3 rock  = float3(0.46, 0.39, 0.33);
        float3 snow  = float3(0.93, 0.94, 0.97);
        float3 col = water;
        col = mix(col, sand,  smoothstep(0.38, 0.44, h));
        col = mix(col, grass, smoothstep(0.46, 0.56, h));
        col = mix(col, rock,  smoothstep(0.62, 0.72, h));
        col = mix(col, snow,  smoothstep(0.80, 0.88, h));

        // Hillshade.
        col *= 0.35 + 0.85 * diff;

        // Faint contour lines for the topo feel.
        float e = h * 15.0, ff = fract(e), dd = min(ff, 1.0 - ff);
        float w = fwidth(e) * 1.5;
        float line = 1.0 - smoothstep(0.0, w, dd);
        col = mix(col, col * 0.55, line * 0.35);

        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """

    // MARK: - Electronic components (2)

    /// PCB: a Manhattan-routed circuit maze. Each grid cell picks a trace piece (straight or elbow)
    /// so copper runs snake across a green solder-mask substrate; some cells host ringed vias, and a
    /// light pulse travels diagonally across the board. Dead-end stubs read as real test points.
    static let elecPCB = prelude + noise + """

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 res = u.resolution;
        float2 uv = fragCoord.xy / res;
        float ar = res.x / res.y;
        float t = u.time * u.speed * 0.4;

        // Solder-mask substrate with a faint fbm mottle.
        float tex = fbm(float2(uv.x * ar, uv.y) * 9.0);
        float3 col = float3(0.04, 0.22, 0.10) * (0.85 + 0.3 * tex);

        // Square cell grid.
        float N = 11.0;
        float2 gc = float2(uv.x * ar, uv.y) * N;
        float2 cell = floor(gc);
        float2 f = fract(gc) - 0.5;

        // Trace piece for this cell → distance field.
        const float2 R = float2(0.5, 0.0), U = float2(0.0, 0.5), L = float2(-0.5, 0.0), D = float2(0.0, -0.5);
        int type = int(hash21(cell) * 6.0);
        float d = 1e9;
        if (type == 0)      d = min(segd(f, R), segd(f, L));   // horizontal
        else if (type == 1) d = min(segd(f, U), segd(f, D));   // vertical
        else if (type == 2) d = min(segd(f, R), segd(f, U));   // ┌ elbow
        else if (type == 3) d = min(segd(f, U), segd(f, L));   // ┐
        else if (type == 4) d = min(segd(f, L), segd(f, D));   // ┘
        else                d = min(segd(f, D), segd(f, R));   // └

        // Copper trace with a bright core, plus a diagonal light pulse.
        float pulse = 0.65 + 0.35 * sin(t * 3.0 - (cell.x + cell.y) * 0.8);
        float3 copper = float3(0.85, 0.6, 0.26);
        float trace = smoothstep(0.075, 0.045, d);
        float coreLine = smoothstep(0.03, 0.0, d);
        col = mix(col, copper * pulse, trace * 0.9);
        col += copper * coreLine * 0.4 * pulse;

        // Vias: ringed pad at the cell centre on some cells.
        if (hash21(cell + 3.0) > 0.86) {
            float r = length(f);
            float ring = (1.0 - smoothstep(0.20, 0.23, r)) * smoothstep(0.12, 0.15, r);
            float hole = 1.0 - smoothstep(0.10, 0.12, r);
            col = mix(col, float3(0.95, 0.86, 0.45), ring);
            col = mix(col, float3(0.03, 0.10, 0.06), hole);
        }

        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """

    /// Oscilloscope: a continuous glowing CRT trace. We densely sample a parametric Lissajous curve
    /// (distance-to-curve field, so it's a real line, not a 2D function), give it a bright core plus a
    /// wide phosphor bloom, add a graticule with brighter centre axes, and slowly morph the frequency
    /// ratio so the figure keeps redrawing.
    static let elecOscilloscope = prelude + noise + """

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = (fragCoord.xy - 0.5 * u.resolution) / u.resolution.y;
        float t = u.time * u.speed;

        // Phosphor background + graticule with brighter centre cross.
        float3 col = float3(0.015, 0.045, 0.035);
        float2 g = abs(fract(uv * 8.0) - 0.5);
        float grid = smoothstep(0.48, 0.5, max(g.x, g.y));
        col += float3(0.08, 0.18, 0.14) * grid * 0.5;
        float axes = smoothstep(0.006, 0.0, abs(uv.x)) + smoothstep(0.006, 0.0, abs(uv.y));
        col += float3(0.10, 0.22, 0.16) * axes;

        // Slowly morphing frequency ratio.
        float fx = 3.0 + 0.5 * sin(t * 0.13);
        float fy = 2.0;
        float phase = t * 0.35;

        // Distance to the *curve* — sample points and measure to each segment so the trace is a
        // continuous line rather than a dotted set of samples.
        const int N = 180;
        float mind = 1e9;
        float2 prev = float2(0.62 * sin(phase), 0.44 * sin(1.1));
        for (int i = 1; i <= N; i++) {
            float s = float(i) / float(N) * 6.28318;
            float2 cur = float2(0.62 * sin(fx * s + phase), 0.44 * sin(fy * s + 1.1));
            mind = min(mind, segd(uv - prev, cur - prev));
            prev = cur;
        }

        // Bright core + wide bloom.
        float core  = exp(-mind * 220.0);
        float bloom = exp(-mind * 40.0);
        col += float3(0.30, 1.0, 0.5) * core;
        col += float3(0.15, 0.7, 0.35) * bloom * 0.5;

        // Live head dot sweeping the curve.
        float hs = fract(t * 0.15) * 6.28318;
        float2 head = float2(0.62 * sin(fx * hs + phase), 0.44 * sin(fy * hs + 1.1));
        col += float3(0.9, 1.0, 0.92) * exp(-length(uv - head) * 160.0) * 0.9;

        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """
}
