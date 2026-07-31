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

## Project layout (as built at M0)

Decided at M0: **SwiftPM executable** (not an `.xcodeproj`) — text-based and reproducible from the
CLI, which suits AI-driven development. A shell script assembles the `.app` bundle.

```
Package.swift
Sources/LiveWallpaper/
  main.swift              # NSApplication bootstrap, .accessory activation policy
  AppDelegate.swift       # wiring: per-screen windows, Governor, compact menu bar, AppModel
  AppModel.swift          # shared UI state (available/current/starred) + action callbacks
  MainWindow.swift        # main window: Installed / Explore / Settings tabs
  DesktopWindow.swift     # borderless click-through window at .desktopWindow level
  WallpaperRenderer.swift # renderer protocol (video/metal/web all conform)
  VideoRenderer.swift     # AVPlayerLooper video (+ animated-gradient fallback)
  MetalRenderer.swift     # MSL fragment shader → CAMetalLayer, CADisplayLink-driven (M1)
  BuiltInShaders.swift    # embedded MSL source for demo shaders (Plasma, Aurora)
  WallpaperCatalog.swift  # the built-in wallpapers shown in the menu
  ConfigParameter.swift   # ConfigParameter/ConfigValue model (shared by manifest decode)
  SettingsPanel.swift     # auto-generated SwiftUI settings form + window controller
  Governor.swift          # power/visibility signal aggregation → RenderDirective
  Manifest.swift          # .livewallpaper manifest decode + validation (M2)
  ZipArchive.swift        # native ZIP reader/writer, defensive (M2)
  WallpaperPackage.swift  # load/verify a package (checksum, shader gate) + makeRenderer (M2)
  Library.swift           # installed-package store, import/export, per-screen assignment (M2)
  ShaderValidator.swift   # fragment-only static safety gate for community shaders (M2)
  WebRenderer.swift       # WKWebView wallpaper + lwp:// scheme + network/nav lockdown (M3)
  WebValidator.swift      # static import scan for web wallpapers — flags, doesn't reject (M3)
  BuiltInWeb.swift        # embedded HTML for the built-in web wallpaper (M3)
  Preferences.swift       # app settings: launch-at-login, battery behavior, rotation (M6)
  PreferencesPanel.swift  # SwiftUI preferences window (M6)
  WorkshopConfig.swift    # public PocketBase URL (M4)
  WorkshopItem.swift      # Codable catalog record + file URLs (M4)
  WorkshopClient.swift    # PocketBase REST browse/download + --workshop-smoke (M4)
  WorkshopUI.swift        # SwiftUI workshop browser + window (M4)
  SampleMaker.swift       # --export / --make-sample package generators
  SelfTest.swift          # `--selftest` headless pipeline check (18 checks)
scripts/seed-workshop.sh   # seed built-ins into PocketBase (admin; reads .env)
LiveWallpaper.entitlements # app-sandbox + network.client + user-selected read-write
scripts/build-app.sh       # assemble .app, generate loop.mp4 (ffmpeg), ad-hoc sign
dist/LiveWallpaper.app     # build output (gitignored)
```

**Phase 1 (the engine) is complete** — video/metal/web renderers, Governor, package format +
library. What's left is **Phase 2 — the community workshop** (backend, upload, moderation);
don't scaffold it until intentionally starting Phase 2.

Handy: `swift build -c release && .build/release/LiveWallpaper --selftest` runs the M2 package
pipeline checks with no GUI.

## Build & run

```bash
# Fast compile check
swift build -c release

# Assemble + sign the .app (default: WITH the App Sandbox entitlement — the M0 spike config)
./scripts/build-app.sh                # sandboxed
./scripts/build-app.sh --no-sandbox   # comparison build without sandbox

# Run it
open dist/LiveWallpaper.app           # quit via the 🖼️ menu-bar item → Quit
# Watch the Governor live (info-level os_log isn't persisted; stream it):
log stream --level info --predicate 'subsystem == "com.livewallpaper.app"'
```

M0 verified on macOS 26.5 / Apple Silicon: the **sandboxed** app creates a full-screen window at
exactly the `.desktopWindow` level, and the Governor pauses/resumes it on the occlusion signal.
See ROADMAP.md → M0 findings.

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
