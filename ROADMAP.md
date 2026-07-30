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

## M0 — Illusion spike ✅ (DONE — approach validated)

The only real technical unknown. Proven on real hardware (macOS 26.5, Apple Silicon, 3440×1440).

- ✅ Create the project — **SwiftPM executable chosen** (text-based, CLI/AI-reproducible) +
  `scripts/build-app.sh` assembles & signs the `.app`
- ✅ Menu-bar app shell (`.accessory`/`LSUIElement`, no Dock icon, 🖼️ status-bar item + Quit)
- ✅ One borderless desktop-level `NSWindow` per `NSScreen` (level `.desktopWindow`)
- ✅ Rebuild window set on `didChangeScreenParametersNotification`
- ✅ Looping video via `AVQueuePlayer` + `AVPlayerLooper` (bundled `loop.mp4`; gradient fallback)
- ✅ Occlusion pausing (`NSWindow.occlusionState`) — pipeline verified: Governor flips
  PAUSED↔RUNNING on the `visible` signal. _(Still worth eyeballing ~0% GPU with `powermetrics`
  under a full cover; the mechanism is confirmed working.)_
- ✅ Battery / Low Power / thermal / screen-lock / sleep signals in the Governor
- 🟢 ✅ **RESOLVED — YES: a sandboxed build creates the desktop-level window on macOS 26.**
  Sandbox container was created (`~/Library/Containers/com.livewallpaper.app`), and the
  WindowServer reports our on-screen window at layer `-2147483623` = exactly `.desktopWindow`,
  full-screen, alpha 1. **→ Mac App Store (Phase D) stays viable.**
- ✅ Updated CLAUDE.md "Build & run" with real commands
- ✅ Updated README with build-from-source instructions

**Exit criteria met:** a looping video wallpaper renders full-screen from a *sandboxed* app, and
the Governor pauses/resumes it via the occlusion signal.

### M0 findings (for the record)
- The desktop-window trick works under App Sandbox — no special entitlement needed for it.
- `.info`-level `os_log` is not persisted to disk; use `log stream --level info` to watch the
  Governor live. Key lifecycle lines were bumped to `.notice`.
- Video: pausing the player is the real power lever (frame-rate throttle is a no-op for video;
  it becomes meaningful for Metal/web in M1/M3).

---

## M1 — Renderer abstraction + Metal ✅ (DONE)

- ✅ `WallpaperRenderer` protocol (configSchema/start/pause/resume/setFrameRate/apply(config:)/stop)
- ✅ Video path conforms
- ✅ The **Governor** aggregates occlusion, battery, Low Power Mode, thermal, screen-lock, sleep.
  _(Explicit fullscreen-app / active-space signals still ⬜ — occlusion already covers the common
  case: a fullscreen app fully covers the wallpaper → PAUSED. Add dedicated signals in M6 polish.)_
- ✅ `MetalRenderer` driven by a view-synced `CADisplayLink` (ProMotion-adaptive via
  `preferredFrameRateRange`); pausing the link → ~0% GPU
- ✅ `MetalRenderer`: MSL fragment shader compiled at runtime → `CAMetalLayer`, uniforms
  (resolution/time/speed/tint)
- ✅ Bundled demo shaders (Plasma, Aurora) — embedded MSL source, no resource bundling
- ✅ Auto-generated SwiftUI config panel from a wallpaper's `configSchema` (float/bool/color)
- ✅ Menu-bar **wallpaper switcher** (Video / Plasma / Aurora) with persisted selection

**Verified:** Plasma shader renders full-screen at 3440×1440 from the sandboxed app, RUNNING @
60fps via the display link, window at exact `.desktopWindow` level.

### M1 notes
- `ConfigParameter`/`ConfigValue` are the shared config model M2's manifest decode will reuse.
- Config values are reset to schema defaults each launch (only the wallpaper *selection* persists);
  wiring per-wallpaper value persistence is a small follow-up.

---

## M2 — Package format + local library ✅ (DONE)

- ✅ Froze `.livewallpaper` v1 (Manifest.swift; checksum algorithm normative in PACKAGE_FORMAT.md)
- ✅ Manifest decode + schema validation (schemaVersion, required fields, minMacOS gate)
- ✅ Native ZIP reader/writer (ZipArchive.swift — stored+deflate read, stored write; defensive:
  bounds-checked, size-capped, path-traversal-rejecting) — no third-party dependency
- ✅ Checksum verify (SHA-256 over `content/`) on install **and** every load
- ✅ Import a local `.livewallpaper` via file picker (NSOpenPanel) → extract, validate, store unpacked
- ✅ Export a sample `.livewallpaper` (NSSavePanel) — full round-trip, self-consistent checksum
- ✅ Installed-library store (unpacked under app-container Application Support)
- ✅ Per-screen wallpaper assignment (model + apply; per-display submenus when >1 screen)
- ✅ Metal static checks at import (fragment-only; rejects compute kernels, writable device
  buffers, atomics, local includes — ShaderValidator.swift)
- ✅ Headless self-test (`LiveWallpaper --selftest`, 11 checks) covering the whole pipeline +
  tamper detection + the shader gate

**Verified:** self-test 11/11; sandboxed app initializes the library in its container and renders.
Import/export are the two GUI-panel actions to try by hand.

### M2 notes
- `web` packages decode & install but render is deferred to M3 (makeRenderer falls back with a log).
- Config *values* still reset per launch (only selection/assignment persists) — small follow-up.
- ZipArchive is intentionally minimal (no ZIP64/encryption/multi-disk); fine for wallpaper bundles.

---

## M3 — Web renderer + sandbox ✅ (DONE — Phase 1 complete)

- ✅ `WebRenderer` via `WKWebView` (Canvas/WebGL/Three.js) — built-in "Web · Starfield" demo
- ✅ No `file://`: content served over a private `lwp://` scheme scoped to the package's web dir
  (WebSchemeHandler, traversal-rejecting)
- ✅ `WKContentRuleList` blocks all network except the manifest allowlist (empty = fully offline)
- ✅ Ephemeral data store; top-level navigation cancelled; media-capture permission denied
- ✅ Enforce `capabilities.network` allowlist (compiled into the rule list at load)
- ✅ Web static import scan flags fetch/XHR/WebSocket/eval/external URLs (WebValidator, logged)
- ✅ Self-test extended to 16 checks (web install/load/makeRenderer, rule JSON, validator flag)

**Verified:** self-test 16/16; runtime log confirms the WebRenderer compiles the rule list, serves
over `lwp://`, and the Governor pauses/resumes it.

### M3 notes
- Web pause is best-effort (hide + suspend media; WebKit throttles hidden content) vs. the hard
  stop for video/metal — noted for a future true-pause hook.
- Delegate signatures must be `@escaping @MainActor @Sendable` to actually satisfy WKNavigation/UI
  delegate optionals — otherwise the callbacks silently never fire.

---

## 🏁 Phase 1 (the engine) is COMPLETE

A local, sandboxed macOS wallpaper engine: video + Metal-shader + web wallpapers, a power-aware
Governor, a frozen `.livewallpaper` package format with import/export, and per-screen assignment.
Everything below is **Phase 2 — the community workshop** (deliberately deferred until now).

---

## M4 — Backend + workshop (read) ⬜ · Phase 2  ([scope](docs/PHASE2_BACKEND.md) · [plan](docs/M4_PLAN.md))

- ⬜ Content plane: object store with **zero egress** + CDN (R2) for bundles/previews/thumbnails
- ⬜ Control plane: Postgres catalog + `GET /wallpapers` search/browse + `/wallpapers/:id`
- ⬜ Download endpoint (counts) → install via the existing `Library.install`
- ⬜ In-app Workshop UI: browse → preview → one-click install (verified, no auth needed)
- ⬜ Seed with first-party content

> Decisions locked: in-app self-serve submission · Sign in with Apple · Supabase + R2 ·
> gate-before-public (see [PHASE2_BACKEND.md](docs/PHASE2_BACKEND.md)).

---

## M5 — Publishing + moderation ⬜ · Phase 2  ([scope](docs/PHASE2_BACKEND.md))

- ⬜ Auth: Sign in with Apple (Supabase Auth) — one-tap, gates publishing only
- ⬜ In-app self-serve upload: `POST /uploads` → presigned R2 PUT → `POST /wallpapers` finalize
- ⬜ **Server-side validation** Edge Function — re-runs manifest/checksum/size + the metal & web
  static gates (TS ports of ShaderValidator/WebValidator; keep rules in sync)
- ⬜ Moderation: gate-before-public queue + minimal admin review view + `moderation_actions`
- ⬜ Ratings + reports (report auto-hide past threshold)
- ⬜ Bundle signing (server signs content hash to account) → enforceable takedown + author ban
- ⬜ ToS / content policy / DMCA + upload license terms (before submissions open)

## M5.5 — Trust & polish ⬜ · Phase 2

- ⬜ Trusted-creator tier (lighter review), upload quotas + rate limits, basic analytics

---

## M6 — Polish 🟡 (first slice DONE)

Done in the first polish slice:
- ✅ Config-value persistence (per-wallpaper values survive relaunch — ConfigValue is Codable)
- ✅ Launch at login (SMAppService, reconciled with system state on launch)
- ✅ Configurable battery behavior (Pause / Throttle / Keep full rate) wired into the Governor
- ✅ Wallpaper rotation (cycle through all wallpapers every N minutes)
- ✅ Preferences window (SwiftUI) — general / power / rotation
- ✅ Self-test extended to 18 checks (config Codable round-trip, battery-behavior parse)

Still open (future polish):
- ⬜ Per-space wallpapers
- ⬜ Schedules (time-of-day wallpaper changes)
- ⬜ Energy dashboard (show measured cost per wallpaper)
- ⬜ Explicit fullscreen-app / active-space Governor signal (occlusion covers the common case)
- ⬜ Onboarding

---

## Distribution track (parallel, gated externally)

- ✅ Phase A: unsigned builds via GitHub Releases (plan documented)
- ⬜ Phase A: first actual release artifact + release checklist
- ⬜ Phase B: Developer ID signing + notarization — **gated on Apple Developer account**
- ⬜ Phase C: Sparkle auto-updates (appcast + EdDSA signing) — after Phase B
- ⬜ Phase D: Mac App Store — pending the M0 sandbox spike
- ⬜ CI: GitHub Actions build-on-tag → (later) sign/notarize/staple/release
