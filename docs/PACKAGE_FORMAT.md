# The `.livewallpaper` package format

**Status: v1 FROZEN (as of M2).** Implemented by `Manifest.swift` / `WallpaperPackage.swift` /
`ZipArchive.swift`. Everything in the app hangs off this spec — treat schema changes as breaking
and bump `schemaVersion`; never mutate v1 in place.

## Checksum algorithm (normative)

`checksum` covers the **`content/` payload only**, computed as:

1. Enumerate every regular file under `content/`; take each path **relative to `content/`**
   (e.g. `shader.metal`, `sub/tex.png`).
2. Sort those relative paths ascending (byte order).
3. For each, update a SHA-256 hash with: the UTF-8 relative path, a single `0x00` byte, then the
   file's bytes.
4. Encode as `"sha256-" + lowercase-hex(digest)`.

Verified on install **and** on every load. A mismatch refuses the package. (The exporter and the
verifier share one implementation, so a freshly exported package always verifies.)

## Bundle layout

A `.livewallpaper` is a zip archive with this structure:

```
mywallpaper.livewallpaper/
  manifest.json         # required — metadata, type, config schema, declared capabilities
  content/              # required — the actual wallpaper payload (see per-type below)
  preview.mp4           # optional but recommended — short looping preview for the workshop UI
  thumbnail.png         # optional but recommended — still image for grids/lists
  signature             # optional in Phase 1; required for workshop publishing (ties to an account)
```

## `manifest.json`

```jsonc
{
  "schemaVersion": 1,
  "id": "b1a7…-uuid",              // stable across versions of the same wallpaper
  "version": "1.2.0",             // semver; bundles are immutable per version
  "title": "Neon Rain",
  "author": { "id": "uuid", "handle": "someone" },
  "type": "video",                // "video" | "metal" | "web"
  "entry": "content/rain.mov",    // path within the bundle to the payload entry point
  "minMacOS": "26.0",
  "checksum": "sha256-…",         // over the content/ payload; verified on install AND every load

  "config": [                     // user-tweakable params → app auto-generates a settings panel
    { "key": "speed", "type": "float", "min": 0.1, "max": 3.0, "default": 1.0, "label": "Speed" },
    { "key": "tint",  "type": "color", "default": "#33AAEE", "label": "Tint" },
    { "key": "audio", "type": "bool",  "default": false, "label": "Play audio" }
  ],

  "capabilities": {               // DECLARED here, ENFORCED by the client — never trusted
    "network": [],                // web only: allowlisted hosts; empty = no network
    "audio": false
  }
}
```

### Field notes

- **`id`** stays constant across versions; **`version`** distinguishes releases. Updates are new
  versions with the same `id`.
- **`type`** selects the renderer. Exactly one payload medium per bundle.
- **`checksum`** is verified at install time and again at every load. Mismatch → refuse to load.
- **`config`** entry types: `float`, `int`, `bool`, `color`, `enum` (with `options`). The app
  renders the corresponding control and passes values to `renderer.apply(config:)`.
- **`capabilities`** is a *contract the client enforces*. `network: []` means the runtime is
  configured so the content physically cannot reach the network — not a promise we take on faith.

## Per-type payload rules

### `video`
- `entry` points to a video file under `content/`.
- Recommended codec: **HEVC/H.265**; **HEVC-with-alpha** for transparent overlays.
- Looped gaplessly via `AVPlayerLooper`. Inert — safest type.

### `metal`
- `entry` points to a `.metal` fragment shader under `content/`.
- **Fragment shaders only.** No compute kernels, no buffer writes. Rejected at import if found.
- Provided uniforms: `resolution` (float2), `time` (float, seconds), `frame` (uint),
  optional `mouse` (float2), plus each `config` value by `key`.

### `web`
- `entry` points to `content/web/index.html`.
- Runs in a locked-down `WKWebView`: no `file://`, network blocked except `capabilities.network`
  allowlist, ephemeral data store, no media-capture/geolocation, top-level navigation blocked.
- Heaviest type — subject to the strictest Governor throttling.

## Validation (client + backend)

On install and on publish, validate:
1. Well-formed zip and `manifest.json` against the schema for `schemaVersion`.
2. `entry` exists and matches `type`.
3. `checksum` matches the `content/` payload.
4. Type-specific static checks (metal: fragment-only/no disallowed ops; web: flag network calls
   and obfuscation for review).
5. Size limits (TBD).

A bundle failing any check is rejected — never partially loaded.
