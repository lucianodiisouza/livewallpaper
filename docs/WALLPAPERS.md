# Workshop Wallpapers

Curated shader wallpapers shipped as `.livewallpaper` packages. Ready to install locally or upload
to the workshop backend.

## Catalog

The built-in menu only ships a handful of demos (`plasma`, `aurora`, etc.). Everything below is
**exportable inventory** — not in the menu bar, but pre-built and ready to publish.

| ID | Title | Category |
| --- | --- | --- |
| `nebula-orion` | Nebula · Orion | astro / nebula |
| `nebula-milky-way` | Nebula · Milky Way | astro / starfield |
| `planet-jupiter` | Planet · Jupiter | astro / gas planet |
| `planet-saturn` | Planet · Saturn | astro / gas planet |
| `topo-contours` | Topo · Contours | topographic |
| `topo-isometric` | Topo · Isometric | topographic |
| `dev-syntax` | Dev · Soft Syntax | dev / code |
| `dev-git-graph` | Dev · Git Graph | dev / code |
| `dev-terminal` | Dev · Terminal | dev / code |
| `elec-pcb` | Electronic · PCB | electronic |
| `elec-resistor` | Electronic · Resistor | electronic |
| `elec-oscilloscope` | Electronic · Scope | electronic |

Source: `Sources/LiveWallpaper/MoreShaders.swift`.

## Authorship

Every workshop package is signed with the credit `@oprimodev` in
`manifest.author.handle`. The handle lives in one place —
`SampleMaker.workshopAuthorHandle` — so re-publishing the catalog under a
different credit is a one-line change. The original in-app samples
(`--make-sample`, the built-in menu) keep the legacy `"built-in"` tag.

## Generating packages

The package uses the same `Library.exportShader` path as the built-in `--export` command, so
emitted files are guaranteed to compile and render.

```bash
# Build once.
swift build

# Export all 12 into ./samples/ (compile-checks each shader first).
.build/debug/LiveWallpaper --export-batch samples

# Export just one.
.build/debug/LiveWallpaper --export nebula-orion samples/nebula-orion.livewallpaper
```

## Rendering thumbnails

For the workshop grid we render a 1024×640 PNG per package. The renderer uses the same
`ThumbnailRenderer` path the app uses at runtime, so the preview matches what users see when the
wallpaper is installed.

```bash
.build/debug/LiveWallpaper --render-thumbs samples docs/thumbnails
```

Outputs land in `docs/thumbnails/<id>.png`.

## Adding a new shader

1. Add the MSL source to `MoreShaders.swift` (mirror the `prelude + fragment` pattern from
   `BuiltInShaders.swift`).
2. Add it to `SampleMaker.workshop` with an id, title, and reference to the new source.
3. Run `--export-batch` + `--render-thumbs` to verify the package compiles and the preview looks
   right.
