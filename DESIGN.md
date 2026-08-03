# Primo Engine — Product & Architecture Design

A native macOS animated-wallpaper engine (video / Metal shader / web), in the spirit of
Wallpaper Engine — but built to respect macOS performance and battery rather than fight it.

Target: macOS 26 (Tahoe)+, Apple Silicon first.

> **⚠️ Direction update (2026-08-02).** The product pivoted from a *community upload workshop*
> to **curated freemium + peer-to-peer sharing**. Anything below describing user uploads, a
> moderation queue, or author accounts (notably §8, §9, and the M4/M5 framing in §11) is
> **superseded** by [docs/FREEMIUM.md](docs/FREEMIUM.md), [docs/LICENSING.md](docs/LICENSING.md),
> and [docs/COMPETITIVE.md](docs/COMPETITIVE.md) — those are current truth. The engine design
> (§2–§7, §10) still holds.

---

## 1. Principles (the non-negotiables)

1. **Invisible when unseen.** If no human can see moving pixels, we render nothing. Power
   behaviour is a *feature*, not an afterthought. This is our main advantage over the Windows
   incumbent.
2. **Untrusted by default.** Imported / peer-shared content is strangers' code running on
   people's Macs. Every content type runs in the tightest sandbox its medium allows. (Still
   true under P2P sharing — the validators run on import regardless of file origin.)
3. **One format, many renderers.** A single package spec and a single `WallpaperRenderer`
   protocol. The desktop window never knows whether it's showing video, a shader, or a webview.
4. **Native, not Electron.** SwiftUI + AppKit shell, Metal/AVFoundation/WebKit engines. No
   bundled Chromium.

---

## 2. System overview

```
┌─────────────────────────────────────────────────────────────┐
│  macOS client (SwiftUI + AppKit, menu-bar / LSUIElement)     │
│                                                              │
│  ┌───────────────┐   ┌──────────────────┐   ┌────────────┐  │
│  │ Desktop Window │   │  Render Engine    │   │  Library   │  │
│  │  (per NSScreen)│◄──┤  (renderer proto) │◄──┤  installed │  │
│  └───────────────┘   │  • VideoRenderer  │   │  packages  │  │
│         ▲            │  • MetalRenderer  │   └────────────┘  │
│  ┌──────┴───────┐    │  • WebRenderer    │        ▲         │
│  │ Power/Vis     │    └──────────────────┘        │         │
│  │ Governor      │                                │         │
│  └──────────────┘                                 │         │
│                          ┌────────────────────────┴──────┐  │
│                          │  Premium catalog client (DL)   │  │
│                          └────────────────┬───────────────┘  │
│   Community content: shared peer-to-peer (files), no server  │
└──────────────────────────────────────────┼──────────────────┘
                                            │ HTTPS
                    ┌───────────────────────┴───────────────────┐
                    │  Backend (PRIVATE — our premium only)       │
                    │  • Read-only catalog  • Object store + CDN  │
                    │  • Purchase verify    • Device-bound license │
                    │    (no uploads, no moderation, no auth-to-publish) │
                    └─────────────────────────────────────────────┘
```

---

## 3. Desktop rendering layer

No public animated-wallpaper API exists. We slot a borderless window between the static
desktop picture and the desktop icons.

```swift
let window = NSWindow(contentRect: screen.frame,
                     styleMask: .borderless, backing: .buffered, defer: false)
window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
window.ignoresMouseEvents = true     // clicks fall through to Finder icons
window.isOpaque = true
window.hasShadow = false
window.setFrame(screen.frame, display: true)
```

Rules:
- **One window per `NSScreen`.** Rebuild the whole set on
  `NSApplication.didChangeScreenParametersNotification` (monitor plug/unplug, resolution,
  arrangement changes).
- Level exactly `.desktopWindow`: above the OS wallpaper, below icons → icons remain visible
  and clickable.
- App is `LSUIElement` (menu-bar only, no Dock icon).
- **Interactions to test explicitly:** Mission Control, Stage Manager, Spaces switching,
  fullscreen transitions, and login/logout. These are where the illusion historically breaks.

---

## 4. Power & visibility governor (the crown jewel)

A single `Governor` object owns a target frame-rate / paused state derived from OR-ing signals.
Every renderer subscribes and obeys.

| Signal | API | Action |
|---|---|---|
| Window occluded (fully covered) | `NSWindow.occlusionState` lacks `.visible` | **Pause** (0 fps) |
| Fullscreen app frontmost (every display covered) | `CGWindowListCopyWindowInfo` coverage check (`FullscreenCoverage`), re-run on `activeSpaceDidChange` / `didActivateApplication` | **Pause** |
| Display asleep / screen locked | `NSWorkspace.screensDidSleepNotification`, `com.apple.screenIsLocked` DistributedNotification | **Pause** |
| On battery | `IOPSCopyPowerSourcesInfo` / `IOPSGetProvidingPowerSourceType` | **Throttle** (e.g. cap 30fps) or user-configurable pause |
| Low Power Mode | `ProcessInfo.processInfo.isLowPowerModeEnabled` | **Throttle** |
| Space not active | active-space-change notifications | **Pause** offscreen spaces |
| Thermal pressure | `ProcessInfo.thermalState` | Throttle at `.serious`, pause at `.critical` |

Drive frames with `CADisplayLink` so we naturally ride ProMotion's adaptive 1–120Hz instead of
hard-coding 60. Occlusion pausing is the biggest single win — most of the day the wallpaper is
behind other windows and should cost ~0% GPU. **Acceptance target: measurable 0% GPU when any
window fully covers the wallpaper.**

---

## 5. Content engine

### Renderer abstraction

```swift
protocol WallpaperRenderer: AnyObject {
    init(package: InstalledPackage, layer: CALayer) throws
    func start()
    func pause()
    func resume()
    func setFrameRate(_ fps: Int)     // Governor-driven
    func apply(config: [String: Value]) // user parameter tweaks
    func stop()
}
```

Each window hosts a backing `CALayer`/`CAMetalLayer`/`WKWebView` chosen by package type.

### 5.1 VideoRenderer
- `AVPlayer` + `AVPlayerLooper` for gapless loops; decode on GPU via VideoToolbox.
- Preferred codec: **HEVC/H.265**; support **HEVC-with-alpha** for transparent/overlay wallpapers.
- Cheapest to author → will dominate community volume. Inert = safest content type.

### 5.2 MetalRenderer  *(the differentiator)*
- Shadertoy-style single MSL fragment shader per frame into a `CAMetalLayer`.
- Uniforms: resolution, time, frame, mouse (optional), user config values.
- Tiny files, GPU-native performance, **sandboxed by construction** (a fragment shader can't
  touch the filesystem, network, or memory outside its pipeline).
- Restriction: **fragment shaders only.** Reject compute shaders / buffer writes at import.

### 5.3 WebRenderer  *(most creator reach, most risk)*
- `WKWebView` running Canvas/WebGL/Three.js bundles.
- Locked down hard (see §7): no outbound network except an explicit allowlist, no file scheme,
  no local storage escape, JS enabled but caged.
- Heaviest CPU/GPU; Governor throttling matters most here.

---

## 6. Package format — `.livewallpaper`

Design this **first**; everything hangs off it. A `.livewallpaper` is a zip bundle:

```
mywallpaper.livewallpaper/
  manifest.json
  content/            # video file | shader.metal | web/ (index.html + assets)
  preview.mp4         # short looping preview for the workshop
  thumbnail.png
  signature           # detached signature over a canonical hash of all files
```

`manifest.json`:
```jsonc
{
  "schemaVersion": 1,
  "id": "uuid",
  "title": "Neon Rain",
  "author": { "id": "uuid", "handle": "someone" },
  "type": "video | metal | web",
  "entry": "content/rain.mov",       // or shader.metal / web/index.html
  "minMacOS": "26.0",
  "checksum": "sha256-…",            // over content, verified on install & load
  "config": [                         // user-tweakable parameters → UI is generated
    { "key": "speed", "type": "float", "min": 0.1, "max": 3, "default": 1, "label": "Speed" },
    { "key": "tint",  "type": "color", "default": "#3AE" }
  ],
  "capabilities": {                   // declared + enforced, not trusted
    "network": [],                    // web only: allowlisted hosts, default empty
    "audio": false
  }
}
```

Notes:
- `config` drives an **auto-generated settings panel** — creators expose knobs without shipping UI.
- `capabilities` is a *declaration the client enforces*, never a grant we take on faith.
- `checksum` verified at install and at every load. `signature` is now used for **premium
  device-bound licensing** (binding a downloaded bundle to the buyer's Mac), not author/account
  moderation — see [LICENSING.md](docs/LICENSING.md). Premium licensing is layered as an additive
  envelope so the frozen v1 format is not mutated.

---

## 7. Security & sandbox model

Threat: arbitrary community content executing on user machines. Defense is **per-medium**:

| Type | Attack surface | Containment |
|---|---|---|
| **video** | codec bugs only | Inert. Rely on OS decoders (already hardened). Lowest risk. |
| **metal** | GPU pipeline | Fragment-only, no buffer writes, no compute. Can't reach FS/net/memory. Compile-check at import; reject disallowed constructs. |
| **web** | full JS/WebGL | `WKWebView` with: JS on but no `file://`, `WKContentRuleList` blocking all network except manifest-allowlisted hosts, no camera/mic/geo, ephemeral data store (no persistent cookies/storage), navigation delegate that blocks top-level navigations. |

App-level:
- Ship with **App Sandbox + Hardened Runtime**, notarized. Aim for Mac App Store distribution
  (forces sandbox discipline); optionally also a notarized direct download.
- Downloaded content lives in a sandboxed container; the client verifies `checksum` before load.
- No content type gets a code-signing exception or `com.apple.security.cs.allow-jit` beyond what
  WebKit itself needs.
- **No pre-publish content review** (there is no publish step) — safety comes from the per-medium
  sandboxes + import-time validators running on every file, server- or peer-sourced (§9).

---

## 8. Premium content backend  *(superseded model below — see [FREEMIUM.md](docs/FREEMIUM.md))*

> **No user uploads.** Users never publish to a server. The backend hosts **only our own
> premium content**, and it is a **private** repo/service (the client stays open; the backend
> does not). See [LICENSING.md](docs/LICENSING.md).

- **Object store + CDN** for our premium bundles, previews, thumbnails.
- **Read-only catalog API**: list/browse our premium wallpapers. No publish, no ratings-by-upload.
- **Purchase + activation**: verify purchase, bind a download to the buyer's Mac
  (`IOPlatformUUID`, device cap), issue a signed device-bound license + wrapped content key.
- **Client catalog UI**: browse our premium content, one-click purchase/install → device-bound
  bundle drops into the local library.
- **Community content is not here at all** — it's shared peer-to-peer between users (§9).

Versioning: bundles are immutable per version; updates are new versions with the same `id`.

---

## 9. Community sharing — peer-to-peer, no moderation

> **Superseded model.** There is **no moderation queue** because there is no user-upload
> server. Users create wallpapers locally and share `.livewallpaper` files directly with each
> other (AirDrop, messaging, etc.). This removes the moderation burden entirely — critical if
> the app grows faster than we can staff review.

- **Safety without moderation:** the per-medium sandboxes and the import-time validators
  (`ShaderValidator` fragment-only gate, `WebValidator`, caged `WKWebView`) run on **every**
  import regardless of where the file came from (§7). A peer-shared bundle is contained exactly
  like a server-delivered one, so dropping moderation opens no security hole.
- **Premium DRM (not moderation):** the `signature` / license binds *our premium* bundles to the
  buyer's Mac so they can't be copied between machines — see [LICENSING.md](docs/LICENSING.md).
  This is device-binding, not content review.

---

## 10. Distribution & entitlements

- `LSUIElement = true` (menu-bar app).
- App Sandbox entitlements needed:
  - `com.apple.security.network.client` (premium catalog downloads + license activation).
  - `com.apple.security.files.user-selected.read-write` (import **and** export/share local
    `.livewallpaper` for peer-to-peer sharing).
  - Read/write to app container for the library.
- Hardened Runtime + notarization. Verify desktop-level window creation is permitted under
  sandbox on the target OS **early** (spike this before committing to App Store as the only channel).
- Login-item registration (`SMAppService`) so wallpapers resume at login.

---

## 11. Milestones

**M0 — Illusion spike (days).** Menu-bar app, one desktop-level window per screen, looping video,
occlusion + battery pausing. Verify ~0% GPU when covered. *Go/no-go on the whole approach.*

**M1 — Renderer abstraction + Metal.** `WallpaperRenderer` protocol; add MetalRenderer with a few
bundled shaders; auto-generated config panel from `manifest.config`.

**M2 — Package format + local library.** Freeze `.livewallpaper` v1; install/verify/load from disk;
multi-monitor per-screen assignment.

**M3 — Web renderer + sandbox.** WKWebView path with the full lockdown from §7.

**M4 — Backend + catalog (read).** Browse/install from a hosted catalog of **our own** content.
Seeded with first-party content. *(Built; being repurposed as the read-only premium catalog.)*

**M5 — ~~Publishing + moderation~~ → Freemium + licensing.** Dropped: open upload, moderation
queue, ratings, DMCA, payouts. Replaced by: paywall/entitlement layer + device-bound licensing
for premium downloads, and peer-to-peer sharing for user content. See
[FREEMIUM.md](docs/FREEMIUM.md) / [LICENSING.md](docs/LICENSING.md).

**M6 — Polish.** Multi-monitor UI + per-display playlists/rotation, per-space wallpapers,
schedules, energy dashboard, onboarding.

**M7 (deferred) — Lock-screen / screen-saver video.** Gated on a spike; re-evaluate after first
revenue. Private `WallpaperExtensionKit` path — see [COMPETITIVE.md](docs/COMPETITIVE.md).

---

## 12. Open questions / risks

- **Sandbox vs. desktop window on current macOS.** Highest-priority unknown — spike in M0.
  If App Store sandbox blocks it, fall back to notarized direct distribution.
- **Web content power cost.** May need a stricter default throttle for `web` type, or a per-package
  energy budget shown to users.
- **Premium DRM is deterrence, not prevention.** The client is open-source and must decode
  content to display it, so a determined user can extract premium content on their own licensed
  Mac. Goal is to stop casual file-copy sharing between Macs, not to be uncrackable — keep signing
  keys server-side and don't over-invest. See [LICENSING.md](docs/LICENSING.md).
- **HEVC-with-alpha authoring friction** — most creators won't know how; may need a small export guide/tool.
- **Stage Manager / Spaces edge cases** — budget real time for the window-management matrix.
```
