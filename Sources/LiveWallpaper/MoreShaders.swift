import Foundation

/// Phase-2 workshop inventory: 12 new fragment shaders covering astro, topographic, dev/code, and
/// electronic-component looks. Same `Uniforms` contract as `BuiltInShaders` (resolution, time, speed,
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

    /// Procedural starfield: tiny point stars on a slow parallax, plus a faint Milky-Way band.
    static let nebulaMilkyWay = prelude + """

    float h2(float2 p) {
        return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
    }

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = (fragCoord.xy - 0.5 * u.resolution) / u.resolution.y;
        float t = u.time * u.speed;

        // Deep gradient background.
        float3 bg = mix(float3(0.02, 0.03, 0.08), float3(0.04, 0.02, 0.10), uv.y + 0.5);
        // Milky-Way band — soft diagonal.
        float band = exp(-pow(uv.y - 0.18 * sin(uv.x * 1.5), 2.0) * 5.0);
        bg += float3(0.18, 0.14, 0.25) * band;
        bg += float3(0.30, 0.22, 0.15) * band * band * 0.6;

        // Stars: layered cells, three sizes, parallax via time-shifted UV.
        float3 col = bg;
        for (int layer = 0; layer < 3; layer++) {
            float fl = float(layer);
            float2 p = uv * (40.0 + fl * 30.0) + float2(t * (0.02 + 0.01 * fl), 0.0);
            float2 ip = floor(p);
            float2 fp = fract(p) - 0.5;
            float r = h2(ip + fl * 17.0);
            if (r > 0.985) {
                float bright = (r - 0.985) / 0.015;
                float d = length(fp);
                float s = smoothstep(0.05 + 0.02 * fl, 0.0, d);
                col += float3(0.9, 0.95, 1.0) * s * bright * (1.0 - 0.25 * fl);
            }
        }
        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """

    // MARK: - Gas planet wave forms (2)

    /// Jupiter-style horizontal bands with a slow Great-Red-Spot swirl and gentle turbulence.
    static let planetJupiter = prelude + """

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
    float fbm2(float2 p) {
        return vnoise(p) + 0.5 * vnoise(p * 2.07) + 0.25 * vnoise(p * 4.13);
    }

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = fragCoord.xy / u.resolution;
        float t = u.time * u.speed * 0.4;

        // Latitudinal bands, heavily warped with two-octave noise so they don't look like wood grain.
        float warp = 0.18 * fbm2(float2(uv.x * 4.0, t * 0.4));
        float y = uv.y + warp;
        float bands = 0.5 + 0.5 * sin(y * 32.0
                                    + fbm2(float2(uv.x * 3.0, t * 0.7)) * 4.0
                                    + 1.2 * sin(uv.x * 2.0 + t * 0.3));

        // Palette: cream, ochre, rust, deep brown.
        float3 c1 = float3(0.95, 0.86, 0.70);
        float3 c2 = float3(0.78, 0.55, 0.30);
        float3 c3 = float3(0.55, 0.22, 0.12);
        float3 c4 = float3(0.20, 0.10, 0.08);
        float3 col = mix(c4, c3, smoothstep(0.0, 0.4, bands));
        col = mix(col, c2, smoothstep(0.35, 0.7, bands));
        col = mix(col, c1, smoothstep(0.65, 1.0, bands));

        // Add a thin turbulent dark storm belt at one latitude for visual interest.
        float belt = exp(-pow((uv.y - 0.32 - 0.02 * sin(uv.x * 5.0 + t)) * 18.0, 2.0));
        col *= 1.0 - 0.45 * belt;

        // Great Red Spot: a stretched ellipse of saturated red-orange.
        float2 p = uv - float2(0.62, 0.65);
        p.x *= 3.5;                      // squash horizontally
        float r = length(p);
        float spot = smoothstep(0.12, 0.0, r) * (0.85 + 0.15 * sin(t * 2.0 + uv.x * 8.0));
        col = mix(col, float3(0.95, 0.30, 0.20), spot);

        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """

    /// Saturn-style planet with smooth pastel bands and a thick ring slicing across the middle.
    static let planetSaturn = prelude + """

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

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = fragCoord.xy / u.resolution;
        float t = u.time * u.speed * 0.3;

        // Smoother pastel bands than Jupiter, with some warp.
        float y = uv.y + 0.10 * vnoise(float2(uv.x * 3.0, t * 0.5));
        float bands = 0.5 + 0.5 * sin(y * 22.0 + 1.0 * vnoise(float2(uv.x * 2.0, t * 0.6)));

        float3 cream = float3(0.93, 0.84, 0.66);
        float3 gold  = float3(0.82, 0.66, 0.36);
        float3 tan   = float3(0.60, 0.42, 0.22);
        float3 col = mix(tan, gold, bands);
        col = mix(col, cream, smoothstep(0.7, 1.0, bands));

        // The ring: an oblique band across the middle with a clear gap (Cassini Division).
        float ang = 0.45;                                  // tilt
        float yRing = (uv.x - 0.5) * sin(ang) + 0.50;      // ring midline
        float d = abs(uv.y - yRing);
        // Three-band ring: outer band, gap (dark), inner band.
        float bandA = (1.0 - smoothstep(0.080, 0.085, d)) * smoothstep(0.060, 0.065, d);
        float bandB = (1.0 - smoothstep(0.040, 0.045, d)) * smoothstep(0.025, 0.030, d);
        float ring  = max(bandA, bandB);
        // Ring in front of the planet is darker, behind is brighter (simple Z test).
        float front = (uv.y < yRing) ? 0.55 : 1.0;
        col = mix(col, float3(0.95, 0.85, 0.65) * front, ring);

        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """

    // MARK: - Topographic / generative (2)

    /// Contour-line topographic map; lines breathe outward from the center.
    static let topoContours = prelude + """

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = (fragCoord.xy - 0.5 * u.resolution) / u.resolution.y;
        float t = u.time * u.speed * 0.4;

        // FBM-ish height field from sin layers; cheap and well-behaved for contouring.
        float h = 0.0;
        h += sin(uv.x * 4.0 + t) * cos(uv.y * 4.0 - t * 0.7);
        h += 0.5 * sin(uv.x * 8.0 - t * 0.5) * cos(uv.y * 8.0 + t * 0.3);
        h += 0.25 * sin(uv.x * 16.0 + t * 0.9) * cos(uv.y * 16.0 - t * 0.4);

        // Contour lines: distance to nearest integer in h.
        float lines = abs(fract(h * 0.5 + 0.5) - 0.5);
        float w = fwidth(h) * 0.6 + 0.005;
        float line = 1.0 - smoothstep(w, w * 2.0, lines);

        // Background gradient by elevation.
        float3 lo = float3(0.05, 0.08, 0.18);
        float3 hi = float3(0.85, 0.55, 0.25);
        float3 bg = mix(lo, hi, 0.5 + 0.5 * h);
        float3 col = mix(bg, float3(1.0, 0.95, 0.85), line);

        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """

    /// Isometric terrain: 3-band shaded mesh drifting horizontally, the classic map-lover look.
    static let topoIsometric = prelude + """

    float hash21(float2 p) {
        return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
    }

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = fragCoord.xy / u.resolution;
        float t = u.time * u.speed * 0.1;

        // Isometric basis (30° tile).
        float2 iso = float2(uv.x - uv.y * 0.5, uv.y * 0.866);
        // Cell grid + slowly drifting noise per cell for height.
        float2 g = floor(iso * 14.0 + float2(t, -t * 0.5));
        float h = hash21(g);
        float h2 = hash21(g + 17.0);
        float elev = floor(h * 4.0) / 3.0;     // 0..3 bands

        // Inside-cell shading: brighter top, darker bottom-right of each tile. Clamp to a
        // brighter minimum so the green grass palette doesn't get dragged to brown.
        float2 f = fract(iso * 14.0 + float2(t, -t * 0.5)) - 0.5;
        float shade = clamp(0.75 + 0.30 * (0.5 - f.y) + 0.15 * (h2 - 0.5), 0.7, 1.05);

        // Palette by elevation: water → sand → grass → rock. Use vivid greens so grass tiles
        // read at thumbnail size.
        float3 c0 = float3(0.10, 0.30, 0.55);   // water
        float3 c1 = float3(0.85, 0.75, 0.50);   // sand
        float3 c2 = float3(0.25, 0.65, 0.30);   // grass
        float3 c3 = float3(0.55, 0.42, 0.30);   // rock
        float3 col;
        if (elev < 0.25)      col = c0;
        else if (elev < 0.50) col = c1;
        else if (elev < 0.75) col = c2;
        else                  col = c3;
        col *= shade;

        // Faint grid.
        float grid = smoothstep(0.02, 0.0, min(abs(f.x), abs(f.y)));
        col = mix(col, float3(0.0, 0.0, 0.0), grid * 0.15);

        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """

    // MARK: - Dev / coding styles (3)

    /// Soft Syntax: pastel-colored code listing with line numbers, gently scrolling up.
    /// Pure visual; not actual syntax highlighting — it's a vibe.
    static let devSyntax = prelude + """

    float h11(float x) { return fract(sin(x * 78.233) * 43758.5453); }

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = fragCoord.xy / u.resolution;
        float t = u.time * u.speed * 0.3;

        // Page scroll: continuous upward.
        float lineH = 24.0;
        float yPx = uv.y * u.resolution.y + t * 40.0;
        float line = floor(yPx / lineH);
        float ly = fract(yPx / lineH);    // 0..1 within line

        // Editor background gradient.
        float3 bg = mix(float3(0.07, 0.09, 0.13), float3(0.10, 0.12, 0.18),
                        smoothstep(0.0, 1.0, uv.y));
        // Gutter.
        if (uv.x < 0.07) bg = mix(bg, float3(0.05, 0.06, 0.10), 0.7);

        // Indent per line (mock-up of nested blocks).
        float indent = floor(h11(line) * 4.0) * 0.03;
        float lineX = uv.x - 0.08 - indent;
        if (lineX < 0.0) { float3 c = bg; c *= u.tint.rgb; return float4(c, 1.0); }

        // Token runs along the line: varying widths & colors.
        float3 col = bg;
        float x = lineX;
        float seed = h11(line * 1.7);
        for (int i = 0; i < 5; i++) {
            float fi = float(i);
            float w = (0.04 + 0.10 * h11(seed + fi * 3.1)) * (1.0 - 0.4 * ly);   // taper end
            if (x > 0.0 && x < w && ly > 0.3) {
                float3 a = float3(0.55, 0.75, 1.00);   // soft blue
                float3 b = float3(0.90, 0.55, 0.75);   // pink
                float3 c = float3(0.65, 0.90, 0.65);   // mint
                float3 d = float3(0.95, 0.85, 0.55);   // amber
                int k = int(h11(seed * 13.0 + fi) * 4.0);
                float3 tok;
                if (k == 0) tok = a; else if (k == 1) tok = b;
                else if (k == 2) tok = c; else tok = d;
                col = tok;
            }
            x -= w + 0.02;
            if (x < -0.05) break;
        }

        // Line number text-as-blocks in the gutter.
        float nCol = floor(h11(line + 99.0) * 2.0);
        float modLine3 = line - 3.0 * floor(line / 3.0);
        if (uv.x < 0.06 && ly > 0.35 && ly < 0.65 &&
            modLine3 < 1.0 && nCol > 0.5) {
            col = float3(0.40, 0.45, 0.55);
        }

        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """

    /// Git-graph: a commit graph with branches, dots, and lane lines drifting horizontally.
    static let devGitGraph = prelude + """

    float h11(float x) { return fract(sin(x * 78.233) * 43758.5453); }

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = fragCoord.xy / u.resolution;
        float t = u.time * u.speed * 0.4;

        // Dark editor background.
        float3 bg = float3(0.06, 0.08, 0.11);

        // Rows of commits scrolling upward; a fixed 5-lane graph.
        const int N_LANES = 5;
        float lineH = 0.10;                          // 10% of height per row
        float scrollY = uv.y / lineH + t * 1.2;      // rows per second
        float row = floor(scrollY);
        float ry = fract(scrollY);                   // 0..1 within the row

        float3 col = bg;
        // Lane colors.
        const float3 laneColors[5] = {
            float3(0.35, 0.78, 0.95),
            float3(0.95, 0.55, 0.30),
            float3(0.55, 0.85, 0.50),
            float3(0.95, 0.45, 0.75),
            float3(0.75, 0.55, 0.95)
        };

        // Draw the lane vertical lines first (faint).
        for (int lane = 0; lane < N_LANES; lane++) {
            float fl = float(lane);
            float x = 0.12 + fl * 0.16;
            float laneLine = smoothstep(0.010, 0.0, abs(uv.x - x));
            col += laneColors[lane] * laneLine * 0.18;
        }

        // For each lane, decide if THIS row is owned by that lane; if so, draw a commit dot at
        // (laneX, row). The "owner" hash is per-(row, lane) so the same lane gets multiple rows.
        for (int lane = 0; lane < N_LANES; lane++) {
            float fl = float(lane);
            float x = 0.12 + fl * 0.16;
            // Bias each lane so commits are spread: lane 0 commits most often, lane 4 least.
            float threshold = 0.30 + fl * 0.13;
            if (h11(row * 7.0 + fl * 31.0) > threshold) {
                float2 d2 = float2((uv.x - x) * u.resolution.y / u.resolution.x, ry - 0.5);
                float dist = length(d2);
                float dot1 = 1.0 - smoothstep(0.025, 0.030, dist);
                // Outer ring.
                float ring = (1.0 - smoothstep(0.030, 0.034, dist)) * smoothstep(0.025, 0.030, dist);
                col = mix(col, laneColors[lane], dot1);
                col = mix(col, float3(0.0, 0.0, 0.0), ring);
            }
        }

        // Faint "diff" highlights: a colored strip on some rows.
        if (h11(row * 0.7) > 0.7) {
            float strip = smoothstep(0.35, 0.0, abs(ry - 0.5)) *
                          smoothstep(0.95, 0.30, abs(uv.x - 0.5));
            float3 dc = float3(0.20, 0.55, 0.30);
            if (h11(row * 1.3) > 0.5) dc = float3(0.55, 0.20, 0.20);
            col = mix(col, dc, strip * 0.35);
        }

        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """

    /// Terminal cursor: a black panel with a soft amber caret blink and a slow vertical scroll of
    /// single-line "output" rows — like a long-running build log.
    static let devTerminal = prelude + """

    float h11(float x) { return fract(sin(x * 78.233) * 43758.5453); }

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = fragCoord.xy / u.resolution;
        float t = u.time * u.speed;

        // Panel.
        float3 panel = float3(0.04, 0.04, 0.05);
        float3 col = panel;

        // Title bar.
        if (uv.y > 0.93) {
            col = float3(0.10, 0.10, 0.12);
            // Three "buttons".
            float bx = uv.x;
            if (bx > 0.03 && bx < 0.045) col = float3(0.95, 0.30, 0.30);
            else if (bx > 0.05 && bx < 0.065) col = float3(0.95, 0.80, 0.20);
            else if (bx > 0.07 && bx < 0.085) col = float3(0.30, 0.85, 0.40);
        }

        // Scrolling rows of dim green-amber "text". scrollY is monotonically increasing so a
        // plain fract() gives us 0..1 within the current line.
        float lineH = 0.035;
        float scrollY = uv.y - 0.06 - 0.5 * sin(t * 0.4) * lineH  // gentle bob
                                 + t * 0.05;                       // slow scroll up
        float row = floor(scrollY / lineH);
        float ry = fract(scrollY / lineH);

        // Decide if this row is "active" and where its content lies.
        float seed = h11(row * 1.7);
        if (seed > 0.3) {
            // Width of the text run.
            float w = 0.2 + 0.6 * h11(row * 3.1);
            float x0 = 0.05;
            if (uv.x > x0 && uv.x < x0 + w && ry > 0.25 && ry < 0.75) {
                // Glyph flicker: cell-based bit pattern.
                float gx = floor((uv.x - x0) * 80.0);
                float gy = floor(ry * 6.0);
                float bit = step(0.55, h11(gx * 7.0 + gy * 11.0 + floor(t * 4.0)));
                if (bit > 0.5) {
                    col = mix(float3(0.20, 0.55, 0.25), float3(0.95, 0.75, 0.30), seed);
                }
            }
        }

        // Blinking cursor at a "current prompt" position.
        float cursorX = 0.05 + 0.4 * h11(floor(t * 0.5));
        float cursorY = 0.10;
        float cursor = step(abs(uv.x - cursorX), 0.008) *
                       step(abs(uv.y - cursorY), 0.018);
        // Blink: half the time.
        float on = step(0.5, fract(t * 1.2));
        col = mix(col, float3(0.95, 0.85, 0.50), cursor * on);

        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """

    // MARK: - Electronic components (3)

    /// PCB: green substrate with copper traces that branch, and a few bright SMD pads.
    static let elecPCB = prelude + """

    float h21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
    float seg(float2 p, float2 a, float2 b, float w) {
        float2 pa = p - a, ba = b - a;
        float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        return length(pa - ba * h) - w;
    }

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = fragCoord.xy / u.resolution;
        float t = u.time * u.speed * 0.3;

        // Green substrate (kept as the base, with a subtle silkscreen grid that doesn't override it).
        float3 substrate = float3(0.06, 0.30, 0.12);
        float2 grid = abs(fract(uv * 36.0) - 0.5);
        float gMask = smoothstep(0.49, 0.5, max(grid.x, grid.y));
        float3 bg = mix(substrate, float3(0.12, 0.40, 0.18), gMask * 0.4);

        // Traces: a few polylines that pulse subtly.
        float3 trace = float3(0.92, 0.62, 0.25);
        float3 col = bg;
        for (int i = 0; i < 4; i++) {
            float fi = float(i);
            float2 a = float2(0.08 + 0.18 * h21(float2(fi, 1.0)), 0.08 + 0.18 * h21(float2(fi, 2.0)));
            float2 b = float2(0.40 + 0.45 * h21(float2(fi, 3.0)), 0.55 + 0.30 * h21(float2(fi, 4.0)));
            float2 c = float2(b.x + 0.20 * h21(float2(fi, 5.0)), a.y);
            float d1 = seg(uv, a, b, 0.005);
            float d2 = seg(uv, b, c, 0.005);
            float d = min(d1, d2);
            float pulse = 0.6 + 0.4 * sin(t * 2.0 + fi * 1.7);
            float traceMask = 1.0 - smoothstep(0.0, 0.0035, d);
            col = mix(col, trace, traceMask * pulse);
        }

        // SMD pads (small bright squares with a thin dark outline).
        for (int i = 0; i < 6; i++) {
            float fi = float(i);
            float2 c = float2(0.15 + 0.7 * h21(float2(fi, 11.0)),
                              0.15 + 0.7 * h21(float2(fi, 17.0)));
            float2 d = abs(uv - c);
            float m = max(d.x, d.y);
            float pad = 1.0 - smoothstep(0.014, 0.016, m);
            float ring = (1.0 - smoothstep(0.018, 0.020, m)) * smoothstep(0.014, 0.016, m);
            col = mix(col, float3(0.95, 0.85, 0.40), pad);
            col = mix(col, float3(0.0, 0.0, 0.0), ring);
        }

        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """

    /// Resistor color bands: a long horizontal resistor drawn at slight angle, color-code stripes
    /// repeating on a black background — minimal, technical, and very on-brand.
    static let elecResistor = prelude + """

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = fragCoord.xy / u.resolution;
        float t = u.time * u.speed * 0.4;

        // Slight tilt.
        float ang = 0.18;
        float2 p = float2(uv.x * cos(ang) - uv.y * sin(ang),
                          uv.x * sin(ang) + uv.y * cos(ang));

        // Background — dark slate.
        float3 bg = float3(0.05, 0.06, 0.08);
        float3 col = bg;

        // Resistor body — soft tan cylinder shading.
        float yc = 0.5;
        float x0 = 0.05, x1 = 0.95;
        float bodyH = 0.10;
        if (p.x > x0 && p.x < x1 && abs(p.y - yc) < bodyH) {
            // Bulge shading: brighter in the middle vertically.
            float sh = 1.0 - pow(abs(p.y - yc) / bodyH, 2.0);
            float3 body = mix(float3(0.45, 0.30, 0.18), float3(0.78, 0.58, 0.34), sh);
            col = body;
        }

        // Lead wires on each end.
        float leadY = yc;
        if (p.x < x0 && abs(p.y - leadY) < 0.012) col = float3(0.85, 0.85, 0.88);
        if (p.x > x1 && abs(p.y - leadY) < 0.012) col = float3(0.85, 0.85, 0.88);

        // Color bands — classic E12 set, repeated in a slow loop.
        // (Metal rejects stack-initialized arrays; use a chain of selects instead.)
        if (p.x > x0 && p.x < x1 && abs(p.y - yc) < bodyH) {
            // Band positions drift slowly.
            float drift = 0.10 * sin(t);
            float bx = (p.x - 0.30 + drift);
            float band = floor(bx * 5.0);
            float within = fract(bx * 5.0);
            int idx = int(band) - 10 * (int(band) / 10);  // mod 10, integer-only
            if (within < 0.35) {
                float3 bandColor = float3(0.0);
                bandColor = select(bandColor, float3(0.0,  0.0,  0.0),  idx == 0);
                bandColor = select(bandColor, float3(0.55, 0.27, 0.07), idx == 1);
                bandColor = select(bandColor, float3(0.95, 0.10, 0.10), idx == 2);
                bandColor = select(bandColor, float3(0.95, 0.50, 0.10), idx == 3);
                bandColor = select(bandColor, float3(0.95, 0.85, 0.10), idx == 4);
                bandColor = select(bandColor, float3(0.10, 0.55, 0.20), idx == 5);
                bandColor = select(bandColor, float3(0.10, 0.30, 0.85), idx == 6);
                bandColor = select(bandColor, float3(0.55, 0.10, 0.55), idx == 7);
                bandColor = select(bandColor, float3(0.55, 0.55, 0.55), idx == 8);
                bandColor = select(bandColor, float3(0.95, 0.95, 0.95), idx == 9);
                col = bandColor;
            }
        }

        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """

    /// Oscilloscope: a glowing CRT trace. Each frame we sweep a parameter and plot a real
    /// Lissajous-style curve (parametric in `s`), so the field is the *distance to the curve*,
    /// not a 2D function value. Phosphor green + faint graticule grid.
    static let elecOscilloscope = prelude + """

    fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = (fragCoord.xy - 0.5 * u.resolution) / u.resolution.y;
        float t = u.time * u.speed;

        // Phosphor background.
        float3 bg = float3(0.02, 0.05, 0.04);
        // Graticule.
        float2 g = abs(fract(uv * 8.0) - 0.5);
        float grid = smoothstep(0.49, 0.5, max(g.x, g.y));
        bg += float3(0.10, 0.20, 0.16) * grid * 0.5;

        // Parametric Lissajous: x(s), y(s) over s in [0, 1]. We pick a pair of integer frequency
        // ratios that produce a closed curve, then animate a slow phase shift.
        const int N = 96;
        float mind = 1e9;
        for (int i = 0; i < N; i++) {
            float s = float(i) / float(N);
            float x = 0.40 * sin(3.0 * 6.28318 * s + t * 0.7);
            float y = 0.30 * sin(2.0 * 6.28318 * s + 1.1 + t * 0.4);
            float d = length(uv - float2(x, y));
            mind = min(mind, d);
        }
        // Phosphor falloff: distance squared inside a thin band.
        float trace = exp(-mind * 180.0);
        // Head dot: a slightly brighter "live" point on the curve.
        float2 head = float2(0.40 * sin(3.0 * 6.28318 * fract(t * 0.5) + t * 0.7),
                             0.30 * sin(2.0 * 6.28318 * fract(t * 0.5) + 1.1 + t * 0.4));
        float headMask = exp(-length(uv - head) * 220.0);

        float3 col = bg + float3(0.25, 0.95, 0.45) * trace;
        col += float3(0.85, 1.00, 0.90) * headMask * 0.8;

        col *= u.tint.rgb;
        return float4(col, 1.0);
    }
    """
}
