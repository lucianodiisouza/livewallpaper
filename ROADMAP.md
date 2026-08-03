# Roadmap & task breakdown

Living checklist of what's done and what isn't. Update the boxes as work lands.
Legend: ✅ done · 🟡 in progress · ⬜ not started · 🔴 blocking risk to de-risk early

Milestones map to [DESIGN.md](DESIGN.md) §11. **Phase 1 = the engine (done).**

> **⚠️ Direction update (2026-08-02).** Phase 2 is **no longer a community upload workshop.**
> The product pivoted to **curated freemium + peer-to-peer sharing**: no user uploads, no
> moderation. M5's upload/moderation/ratings/DMCA/payouts are **dropped**; the new Phase-2 work
> is a paywall + device-bound licensing for our own premium content. Current plan:
> [docs/FREEMIUM.md](docs/FREEMIUM.md) · [docs/LICENSING.md](docs/LICENSING.md) ·
> [docs/COMPETITIVE.md](docs/COMPETITIVE.md).

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
  _(✅ 2026-08-03: explicit full-screen-cover signal added — see M6.)_
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
Everything below was **Phase 2 — the community workshop**, now **repositioned to freemium +
peer-to-peer** (see the direction-update banner at the top). M4 (read-only catalog) is built and
becomes the premium catalog; M5 is re-scoped away from moderation to licensing.

---

## M4 — Backend + workshop (read) ✅ (DONE — live)  ([scope](docs/PHASE2_BACKEND.md) · [plan](docs/M4_PLAN.md))

- ✅ Client (backend-agnostic): `WorkshopConfig`/`Item`/`Client`/`UI`, **Browse Workshop…** menu,
  `--export` + `--workshop-smoke` CLIs
- ✅ Backend deployed: **PocketBase on Railway** + persistent volume; `wallpapers` collection with
  `status = "published"` read rule; download-count hook
- ✅ **Cloudflare R2** serving bundle bytes (zero egress); backend repo `livewallpaper-workshop`
- ✅ Seeded first-party content (Plasma/Aurora/Matrix); verified `--workshop-smoke` → `OK: 3` and
  the in-app workshop lists + installs them

> Decisions locked: **PocketBase on Railway + R2 for files** (~$5/mo). Backend:
> `livewallpaper-workshop` repo (to be made **private**). ~~in-app self-serve submission · Sign in
> with Apple · gate-before-public~~ — **superseded** by the freemium/P2P pivot (no user uploads).

---

## M5 — ~~Publishing + moderation~~ → Freemium + licensing ⬜ · Phase 2  ([plan](docs/FREEMIUM.md))

**Dropped (pivot 2026-08-02):** open upload, Sign-in-to-publish, server-side upload validation,
moderation/review queue, ratings/reports, DMCA, author bans, upload quotas, creator payouts.

New Phase-2 scope instead:
- ✅ Peer-to-peer sharing UX — "Share…" (preview sheet + the per-tile "…" menu) exports a
  wallpaper to a `.livewallpaper` (`Library.exportPackage`, re-zips the unpacked package). Only
  **user-imported** wallpapers are shareable — catalog content isn't (free is re-downloadable,
  premium will be device-bound). Provenance tracked via `Library.isImported`.
- ✅ Preview-before-apply — tapping a wallpaper opens a live-rendered preview sheet (real renderer,
  not a thumbnail) with Apply / Apply-to-display / Share
- 🟡 Read-only premium catalog — the M4 client is repurposed (Explore renamed **Catalog**); points
  at our own PocketBase feed (backend now private). **Premium items are now device-bound**: a
  `tier`/`bundle_key` on each record + a Worker `/catalog/bundle` route stream premium bundles from a
  private R2 bucket only to premium devices (free items stay on the public URL). Client shows a lock
  badge + paywall on locked items. Code landed 2026-08-03; live infra (private bucket + collection
  fields + deploy) **live in production as of 2026-08-03** (validated: premium→200, non-premium→402);
  a 3-item premium showcase is seeded — see [PRE_APPLE_PLAN.md](docs/PRE_APPLE_PLAN.md) A1.
- 🟡 Paywall / entitlement layer — `Entitlement` (single `isPremium` source of truth) + gating:
  premium built-ins (lock badge → paywall on apply), rotation is Premium-gated, a `PaywallSheet`
  upsell, and a Premium section in Settings. **Activation is a pre-release local placeholder**
  (`unlockForNow`) — real StoreKit purchase + device-bound activation land with the backend
  ([LICENSING.md](docs/LICENSING.md)). +2 self-test checks.
- 🟡 Device-bound licensing — **core built**: the backend Worker issues an **Ed25519-signed license**
  bound to the device (`POST /license`); the client verifies it **offline** with the embedded public
  key and checks the id matches this machine (`Licensing`, `Device` = `IOPlatformUUID`). `Entitlement`
  now derives premium from a valid device-bound license (dev override kept for UI testing). Validated
  end-to-end (Worker Web-Crypto sign ↔ CryptoKit verify) + 3 self-test checks.
  - ✅ **Orders + device cap + activation** (2026-08-03): an *order* = one purchase owning a capped
    device set (default 3). `/admin/order` provisions, `/activate {device_id, order_id}` binds a Mac
    (409 when the cap is hit), `/deactivate` frees a slot. In-app **Settings → Premium**: enter a
    license code to Activate, or Deactivate this device — a real sales path before StoreKit. License
    TTL shortened to 14 days with silent near-expiry auto-renew (`Licensing.refreshIfNeeded`).
    +5 self-test checks. See [LICENSING.md](docs/LICENSING.md).
  - Remaining (Apple-gated): **StoreKit purchase** auto-creates the order (today an admin provisions
    it via `/admin/order`); needs the Developer account. See [PRE_APPLE_PLAN.md](docs/PRE_APPLE_PLAN.md) A2.
- ✅ Make the backend repo **private** (client stays MIT) — done; git history scanned, no secrets
- ✅ AI shader **and web** generation (marquee premium feature), provider-agnostic: prompt →
  selected provider → generate → validate → package + install + apply. Premium-gated; keys in the
  Keychain (`AIConfig`). Generated wallpapers are the user's own (shareable).
  - **Shader:** prepend the fixed MSL prelude so only `f_main` is model-authored → `ShaderValidator`
    + real compile gate. **Web:** offline HTML/Canvas/WebGL → `WebValidator` gate (rejects any
    network/eval use, since the renderer is caged). One repair retry each.
  - Providers: **Anthropic** (Messages API) and **OpenAI-compatible** (`/chat/completions`, base-URL
    configurable) — covers OpenAI, OpenRouter, Groq, and **local Ollama/LM Studio** (offline,
    unblockable; ATS `NSAllowsLocalNetworking` set). Not vendor-locked.
  - **Pre-release calls the provider directly with the user's key; production routes through the
    backend** (keys server-side, server picks/falls-back across providers, region-block-proof).
  - +4 self-test checks (reply parsing + web packaging round-trip).

---

## M6 — Polish 🟡 (first slice DONE)

Done in the first polish slice:
- ✅ Config-value persistence (per-wallpaper values survive relaunch — ConfigValue is Codable)
- ✅ Launch at login (SMAppService, reconciled with system state on launch)
- ✅ Configurable battery behavior (Pause / Throttle / Keep full rate) wired into the Governor
- ✅ Wallpaper rotation (cycle through all wallpapers every N minutes) — now **per-display**:
  each monitor advances independently from its own current wallpaper
- ✅ **Multi-monitor UI** — a to-scale, horizontally-scrollable **monitor strip** at the top of
  Installed (drawn from real `NSScreen.frame`s, with gaps + a static preview of each screen's
  wallpaper + names). Tap a monitor to target it; a "…" menu next to every Set/Install (Installed
  and Explore) applies a wallpaper straight to a named display. The per-screen assignment engine
  existed since M2; this exposes it intuitively (replaced the earlier dropdown-grid "Displays" tab)
- ✅ **Disguised switch** — changing one monitor swaps just that screenlet's renderer in its
  existing window with a crossfade, instead of rebuilding every screen (no flash on the others)
- ✅ **Static previews** — shader frames (rendered) and video frames (`AVAssetImageGenerator`)
- ✅ **Solid backdrop** — optionally replaces the macOS desktop picture with a neutral colour so
  the user never glimpses their own wallpaper behind/around ours; captures + restores the original
  (`DesktopBackground`), toggle in Settings, on by default
- ✅ Preferences window (SwiftUI) — general / power / rotation
- ✅ Self-test extended to 59 checks (config Codable round-trip, battery-behavior parse, update
  version-compare)
- ✅ Update notifications — lightweight GitHub Releases check (`UpdateChecker`): auto-check on
  launch (throttled, opt-out in Preferences) lights up a menu banner + "Check for Updates…";
  `--check-updates` CLI. Phase-A bridge until Sparkle (Phase C) does real in-place updates.

Still open (future polish):
- ⬜ Per-space wallpapers
- ✅ Schedules (time-of-day wallpaper changes) — a daily program of "at HH:MM → wallpaper" rows
  (Settings → Schedule), Premium-gated, applied by a 30s timer; independent of rotation. Pure
  resolver `WallpaperScheduleLogic` (+5 self-test checks). (`Schedule.swift`)
- ✅ Energy dashboard (Settings → Energy) — shows the **live** render state from the Governor
  (running/paused + why) plus a coarse per-medium cost **estimate** (video < web < metal, scaled by
  fps + resolution), honestly labelled *not* a live measurement and pointing at
  `docs/PERFORMANCE_REPRODUCE.md` for real numbers. The app can't read per-process GPU energy
  cheaply on Apple Silicon, so this is a model grounded in `docs/PERFORMANCE.md`, not fabricated
  telemetry. Pure `EnergyModel` (+6 self-test checks). Free (a trust feature).
- ✅ Explicit fullscreen-app / active-space Governor signal — a public-API coverage check
  (`FullscreenCoverage`): every display fully covered by a non-Primo normal window ⇒ pause, so we
  react even when `NSWindow` occlusion lags on a Space switch into a full-screen app. Re-evaluated on
  `activeSpaceDidChange` + `didActivateApplication`; composes with occlusion (multi-monitor correct).
  +4 self-test checks. (`FullscreenCoverage.swift`, `Governor.swift`)
- ✅ Onboarding — first-run walkthrough (welcome → pick a first wallpaper live → multi-monitor &
  rotation → Premium), skippable, re-runnable from Settings. Gated on `hasCompletedOnboarding`;
  force with `LW_ONBOARDING=1`. (`Onboarding.swift`, +1 self-test check)

---

## Distribution track (parallel, gated externally)

- ✅ Phase A: unsigned builds via GitHub Releases (plan documented)
- ✅ Phase A: release pipeline + checklist ([RELEASING.md](docs/RELEASING.md),
  [.github/workflows/release.yml](.github/workflows/release.yml)) — push a `vX.Y.Z` tag → build,
  self-test, zip, publish Release with Gatekeeper notes. _(Live: **v0.1.0** and **v0.2.0** are
  published on the Releases page. v0.2.0 = commit `4ec7d8a`; the freemium work from 2026-08-03
  (onboarding, device-bound catalog, licensing hardening, schedules, energy panel) is unreleased —
  next tag **v0.3.0**.)_
- ⬜ Phase B: Developer ID signing + notarization — **gated on Apple Developer account**
- ⬜ Phase C: Sparkle auto-updates (appcast + EdDSA signing) — after Phase B
- ⬜ Phase D: Mac App Store — pending the M0 sandbox spike
- ✅ CI: GitHub Actions build-on-tag → self-test → zip → release (Phase A);
  sign/notarize/staple to be added with Phase B
