# CLAUDE.md — operating manual for AI contributors

This repository is built **primarily with AI assistance**. Read this file first, every session.
It encodes decisions that are expensive to rediscover. When something here conflicts with a
one-off request, surface the conflict rather than silently drifting.

## What this is

**LiveWallpaper** — a native macOS animated-wallpaper engine (video / Metal shader / web),
free and open-source, in the spirit of Wallpaper Engine but built to respect macOS
performance and battery. Full design: [DESIGN.md](DESIGN.md).

- Platform: **macOS 26 (Tahoe)+, Apple Silicon first.**
- Language/stack: **Swift, SwiftUI + AppKit**. Metal, AVFoundation, WebKit for engines.
- **No Electron. No bundled Chromium.** Native only.
- Third-party deps: avoid. The only sanctioned one is **Sparkle** (auto-updates, later).

## Scope discipline (read this before adding anything)

The project is deliberately split into two phases. **Do not build phase 2 work while phase 1
is unproven.**

- **Phase 1 — the engine (current focus).** A local single-user app: install a
  `.livewallpaper` bundle, it renders on the desktop, it pauses when unseen. Small-to-medium.
- **Phase 2 — the community/workshop (later).** Backend, uploads, ratings, moderation. This is
  a *platform*, not a feature. Do not scaffold backend/moderation code until Phase 1 ships.

When in doubt, prefer the smallest change that advances Phase 1.

## The one real risk — verify early

**Can an App-Sandbox'd build create a desktop-level window on macOS 26?** This is the only
genuine technical unknown (see DESIGN.md §12). The M0 spike must answer it before we commit to
Mac App Store as a distribution channel. Everything downstream assumes the desktop-window
illusion holds. If sandbox blocks it → distribution stays notarized-direct only.

## Load-bearing decisions (don't quietly reverse these)

1. **`.livewallpaper` package format is frozen-first.** Everything hangs off it. Spec lives in
   [docs/PACKAGE_FORMAT.md](docs/PACKAGE_FORMAT.md). Changing v1 breaks published wallpapers —
   version the schema, don't mutate it.
2. **One power `Governor` owns render state.** Every renderer obeys it. Never let a renderer
   run frames on its own clock. Occlusion pausing (`NSWindow.occlusionState`) is the headline
   feature — target **0% GPU when the wallpaper is fully covered.**
3. **Untrusted-by-default content.** Community content is strangers' code. Each medium runs in
   the tightest sandbox it allows (video=inert, metal=fragment-only, web=caged WKWebView).
   See DESIGN.md §7. Never loosen a sandbox for convenience.
4. **`capabilities` in a manifest are enforced, never trusted.** A package declaring
   `network: []` must be *made* unable to reach the network, not asked nicely.

## Intended project layout (create as you build)

```
LiveWallpaper/            # app target (Xcode project or SwiftPM — TBD at M0)
  App/                    # menu-bar shell (LSUIElement), AppDelegate, DesktopWindow
  Engine/                 # WallpaperRenderer protocol + VideoRenderer, MetalRenderer, WebRenderer
  Governor/               # power/visibility signal aggregation
  Package/                # .livewallpaper parsing, manifest decode, checksum/signature verify
  Library/                # installed-package store, per-screen assignment
  Shaders/                # bundled MSL shaders
  Workshop/               # backend client — PHASE 2, do not populate yet
  Resources/
docs/                     # PACKAGE_FORMAT.md, DISTRIBUTION.md, …
DESIGN.md                 # architecture source of truth
```

> The Xcode/SwiftPM project does not exist yet. Do not fabricate build commands that assume it.
> When you scaffold it, update the "Build & run" section below with the real commands.

## Build & run

_Not scaffolded yet._ Expected once the project exists:

- Xcode project: `xcodebuild -scheme LiveWallpaper -configuration Debug build`
- or SwiftPM: `swift build` / `swift run`
- Run the actual app via the `/run` skill once a launch config exists.

Keep this section truthful — update it the moment the project is created.

## Conventions

- Match surrounding code style; follow standard Swift API design guidelines.
- Prefer `async/await` and structured concurrency over callbacks for new code.
- No force-unwraps in shipping paths involving user/community content — that content is hostile.
- Comment the *why*, not the *what*. Wallpaper/desktop-window edge cases deserve comments.
- Keep the Governor's signal list in code in sync with DESIGN.md §4.

## Distribution (see docs/DISTRIBUTION.md)

- **Now:** unsigned/ad-hoc builds shipped via **GitHub Releases**. Users download the `.app`/zip.
- **Later (gated on Apple Developer account):** Developer ID signing + notarization + **Sparkle**
  auto-updates. Possibly Mac App Store as a second channel (pending the sandbox spike).

## Don't

- Don't add third-party dependencies without a note in the PR explaining why native won't do.
- Don't build Phase 2 (backend/moderation) infrastructure yet.
- Don't relax a content sandbox to make a demo work.
- Don't invent APIs — if unsure an AppKit/WebKit call exists on macOS 26, verify it.
