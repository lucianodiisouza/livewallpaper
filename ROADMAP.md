# Roadmap & task breakdown

Living checklist of what's done and what isn't. Update the boxes as work lands.
Legend: ✅ done · 🟡 in progress · ⬜ not started · 🔴 blocking risk to de-risk early

Milestones map to [DESIGN.md](DESIGN.md) §11. **Phase 1 = the engine (current). Phase 2 = the
community workshop (deferred until the engine ships).**

---

## Phase 0 — Foundations ✅ (done)

- ✅ Product & architecture design ([DESIGN.md](DESIGN.md))
- ✅ `.livewallpaper` package format v1 draft ([docs/PACKAGE_FORMAT.md](docs/PACKAGE_FORMAT.md))
- ✅ Distribution/signing/auto-update plan ([docs/DISTRIBUTION.md](docs/DISTRIBUTION.md))
- ✅ AI operating manual ([CLAUDE.md](CLAUDE.md))
- ✅ OSS meta: README, LICENSE (MIT), CONTRIBUTING, SECURITY, CODE_OF_CONDUCT
- ✅ `.gitignore`, GitHub issue/PR templates
- ✅ Git repo initialized + pushed to public GitHub

---

## M0 — Illusion spike 🔴 (next — go/no-go on the whole approach)

The only real technical unknown. Prove the desktop-window illusion + power model before building more.

- ⬜ Create the Xcode/SwiftPM project; decide project structure per CLAUDE.md layout
- ⬜ Menu-bar app shell (`LSUIElement`, no Dock icon, status-bar item)
- ⬜ One borderless desktop-level `NSWindow` per `NSScreen` (level `.desktopWindow`)
- ⬜ Rebuild window set on `didChangeScreenParametersNotification` (monitor/resolution changes)
- ⬜ Looping video via `AVPlayer` + `AVPlayerLooper` in the window
- ⬜ Occlusion pausing (`NSWindow.occlusionState`) — **verify ~0% GPU when covered**
- ⬜ Battery pause/throttle (`IOPSCopyPowerSourcesInfo`)
- 🔴 ⬜ **Spike: does an App-Sandbox build allow the desktop-level window on macOS 26?**
  → decides whether Mac App Store is ever a channel (DESIGN.md §12)
- ⬜ Update CLAUDE.md "Build & run" with the real build/run commands
- ⬜ Update README with build-from-source instructions

**Exit criteria:** a looping video wallpaper renders across all screens and costs ~0% GPU when
covered, and we know whether sandbox permits it.

---

## M1 — Renderer abstraction + Metal ⬜

- ⬜ `WallpaperRenderer` protocol (start/pause/resume/setFrameRate/apply(config:)/stop)
- ⬜ Refactor video path to conform
- ⬜ The **Governor**: aggregate all signals (occlusion, battery, Low Power Mode, thermal,
  screen-lock, fullscreen-app, active-space) into one target-fps/paused state
- ⬜ Drive frames with `CADisplayLink` (ProMotion-adaptive)
- ⬜ `MetalRenderer`: MSL fragment shader → `CAMetalLayer`, standard uniforms (resolution/time/frame)
- ⬜ Bundle a few first-party demo shaders
- ⬜ Auto-generated config panel from `manifest.config`

---

## M2 — Package format + local library ⬜

- ⬜ Freeze `.livewallpaper` v1 (lock the schema)
- ⬜ Manifest decode + schema validation
- ⬜ Zip bundle open + checksum verify (on install and every load)
- ⬜ Import a local `.livewallpaper` (drag-drop / file picker)
- ⬜ Installed-library store + per-screen wallpaper assignment
- ⬜ Metal static checks at import (fragment-only, reject compute/buffer writes)

---

## M3 — Web renderer + sandbox ⬜

- ⬜ `WebRenderer` via `WKWebView` (Canvas/WebGL/Three.js)
- ⬜ Lockdown: no `file://`, `WKContentRuleList` blocking network except manifest allowlist
- ⬜ Ephemeral data store, no media-capture/geolocation, block top-level navigation
- ⬜ Enforce `capabilities.network` allowlist
- ⬜ Web static checks at import (flag network calls / obfuscation)

---

## M4 — Backend + workshop (read) ⬜ · Phase 2

- ⬜ Object store + CDN for bundles/previews/thumbnails
- ⬜ Catalog API (search, browse-by-tag, ratings, downloads, versioning)
- ⬜ In-app workshop UI: browse → one-click install (verified)
- ⬜ Seed with first-party content

---

## M5 — Publishing + moderation ⬜ · Phase 2

- ⬜ Auth (Sign in with Apple + email fallback)
- ⬜ Upload + server-side validation pipeline (manifest, size, static analysis)
- ⬜ Preview/thumbnail transcode pipeline
- ⬜ Moderation queue (gate before public) + reporting + takedown via signature
- ⬜ Bundle signing (ties every package to an account)

---

## M6 — Polish ⬜

- ⬜ Playlists / rotation / schedules
- ⬜ Per-space wallpapers
- ⬜ Energy dashboard (show cost per wallpaper)
- ⬜ Onboarding

---

## Distribution track (parallel, gated externally)

- ✅ Phase A: unsigned builds via GitHub Releases (plan documented)
- ⬜ Phase A: first actual release artifact + release checklist
- ⬜ Phase B: Developer ID signing + notarization — **gated on Apple Developer account**
- ⬜ Phase C: Sparkle auto-updates (appcast + EdDSA signing) — after Phase B
- ⬜ Phase D: Mac App Store — pending the M0 sandbox spike
- ⬜ CI: GitHub Actions build-on-tag → (later) sign/notarize/staple/release
