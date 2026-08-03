# Competitive analysis & strategic direction

Snapshot: **2026-08-02**. Landscape of macOS live-wallpaper apps and where Primo Engine
should play. Companion to [FREEMIUM.md](FREEMIUM.md), which turns this into a plan.

> **Bottom line:** every competitor is a *4K-MP4 player*. Our shader + web renderers are the
> one thing none of them can copy. Don't win their game (video) — win ours (interactive,
> GPU-native, tiny-file wallpapers) and wrap it in a curated freemium catalog.

## The field

| | MacWall (macwall.app) | Wallspace (wallspace.app) | Backdrop (review leader) | **Primo Engine** |
|---|---|---|---|---|
| Price | $7.99 lifetime (reg. $14.99); Pro+ = 3 Macs | Free + Pro $8.99–12.99 lifetime | Paid (n/d) | Free/OSS → **freemium** |
| Model | Pay-once, no subscription | Freemium, no subscription | — | Freemium |
| Wallpaper types | Video (MP4/MOV) | Video (MP4) | Video 4K | **Video + Metal shader + Web** ⭐ |
| Lock-screen video | ✅ macOS 26+ | ✅ Pro | ✅ (heavy marketing) | ❌ (deferred — see below) |
| Multi-monitor | ✅ per display | ✅ per display / mirror | ✅ **per-display playlists** | ✅ per display (engine done) |
| Catalog | 1,000+ curated, 9 categories, community upload | 800+, 100k downloads, 20k users | thousands 4K + built-in editor | ~3 built-ins (gap) |
| AI search | ❌ | ✅ "describe a mood" | ❌ | ❌ (opportunity) |
| Built-in editor | ❌ | ❌ | ✅ | partial (config schema) |
| Performance | Swift/Metal, smart pause | <2% CPU | 0.3% CPU (marketed) | **3% of 1 core, 0% occluded, measured** ⭐ |
| Creator payout | 40% affiliate / refund-by-views | Discord community | — | — |

## Reading

1. **Our moat is shader + web, not video.** Video can't be interactive; shaders and web can.
   That is the "visceral, dynamic, interactive" experience — and it ships as tiny GPU-native
   files, not 300 MB MP4s. Competing on video makes us the 5th MP4 player to market.
2. **The real gap is presentation, not capability.** They sell with vitrine sites, 800–1,000+
   curated wallpapers, categories, like-ranking. We have ~3 built-ins and the differentiator
   (shader/web) has no showroom. Fix: curated catalog + previews + onboarding.
3. **Our performance numbers are wasted marketing.** Backdrop became "the leader" selling
   "0.3% CPU". We have reproducible 3%/0%-occluded/260 mW measurements buried in
   [PERFORMANCE.md](PERFORMANCE.md). Auditable performance is a sales argument — surface it.
4. **Pivoting off open user-submission to curated freemium is correct and market-aligned.**
   Wallspace doesn't let anyone upload; MacWall moderates before publish. Dropping open UGC
   **removes all of Phase 2 (M5 upload/moderation/DMCA/ban)** — the most expensive, riskiest
   part of the roadmap — in exchange for curation + a premium gate, which is cheaper to run.

## Lock-screen video: why it's deferred, not dropped

The two features originally requested were multi-monitor (engine already done) and
lock-screen video. Lock-screen video is the expensive one and it **breaks our sandbox model**:

- The only working path on macOS 26 is Apple's **private `WallpaperExtensionKit`** framework,
  loaded via `dlopen`, with undocumented XPC types read through `Mirror` reflection and a
  runtime swizzle of `WallpaperSnapshotXPC`. No public SDK. Reference implementations:
  [Phosphene](https://github.com/kageroumado/phosphene) and
  [Wallpaper-Sync](https://github.com/GonzaloRojas14/Wallpaper-Sync) (both open source).
- Requires a **two-process architecture**: an **unsandboxed** menu-bar app writing into a
  sandboxed `.appex` extension's container inside the system `WallpaperAgent`.
- **Kills Mac App Store (Phase D)** for this feature — App Store bans private frameworks and
  writing system aerial files. Notarized-direct distribution only.
- **Fragile & recurring cost:** private API breaks on every major OS. The macOS 27 beta broke
  lock-screen video across most competitors; MacWall literally markets "we fixed it first".

**Decision (2026-08-02):** do **not** build this now. Re-evaluate after first revenue lands.
If pursued, gate it behind a technical spike (see [FREEMIUM.md](FREEMIUM.md) → deferred track).

## Sources

- macwall.app, wallspace.app (product pages)
- macwall.app/blog/macwall-vs-wallper
- cindori.com/how-to/best-live-wallpaper-apps-mac
- github.com/kageroumado/phosphene, github.com/GonzaloRojas14/Wallpaper-Sync
