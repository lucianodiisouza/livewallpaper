# Freemium direction & re-architecture

Decision date: **2026-08-02**. Turns [COMPETITIVE.md](COMPETITIVE.md) into a plan. This
**supersedes the "community workshop / open user submission" framing** in DESIGN.md §1.2, §8,
§11 and ROADMAP Phase 2 — those need the owner's revision (flagged at the end).

> **Monetization model (reconciled 2026-08-03).** Freemium with **plans**, not a single one-time
> unlock: a **7-day free trial** (one-time per machine, no card), **monthly** and **annual**
> subscriptions, and a **lifetime** one-time purchase — sold via **Stripe** (worldwide) and
> **InfinitePay** (Brazil), with **Apple IAP** to come for a future Mac App Store build. Licensing is
> **device-bound, per machine**: trial + subscriptions bind **1 Mac**, lifetime up to **3**.
>
> **AI generation is free and bring-your-own-key** — *not* a paywalled feature, and Primo neither
> hosts nor pays for inference. Users supply their own Anthropic (Claude) / OpenRouter /
> OpenAI-compatible key, or run a local Ollama / LM Studio at no cost. Premium gates the **curated
> catalog** and pro features, not generation.
>
> The prose and table below have been updated to match. **Operational details** (exact prices, caps,
> trial rules, refunds, support flows) live in the **private backend repo** —
> `livewallpaper-workshop/docs/BILLING.md` — never here, since this repo is public.

## The pivot in one paragraph

Primo Engine stops being a *UGC platform* and becomes a *curated freemium app*. Users no
longer submit wallpapers. Instead we ship a curated catalog, give a genuinely useful **free**
tier, and gate the rest behind **Premium** — a 7-day free trial, then a subscription or a lifetime
purchase. Our differentiator vs. the all-video field is **Metal shader + web wallpapers** and
**AI-generated** shader/web wallpapers (free, bring-your-own-key), which no video-only competitor
can copy.

## What changes

- **Kept:** the engine (video/metal/web renderers, Governor, `.livewallpaper` format,
  per-screen assignment). Phase 1 is done and stays the foundation.
- **Dropped:** open user submission, and therefore most of Phase 2 — M5 (auth, in-app upload,
  server-side validation, moderation queue, ratings/reports, DMCA, creator payouts) and M5.5.
- **Community = peer-to-peer, not a server (2026-08-02).** User-created wallpapers stay
  **local**; people share `.livewallpaper` files directly between themselves (AirDrop, etc.).
  **No user content touches our server → zero moderation burden.** Safe because the validators
  (`ShaderValidator`/`WebValidator`/caged WKWebView) run on import regardless of file origin.
- **Server hosts only our premium content**, delivered **device-bound** so it can't be copied
  between Macs. Full scheme + honest DRM limits in [LICENSING.md](LICENSING.md).
- **Video is local-only** — "import your own MP4" (free). We don't host/sell video, so DRM
  applies only to premium shader/web packs.
- **Added:** a paywall/entitlement layer and a device-bound licensing layer (7-day trial +
  monthly/annual subscriptions + lifetime, per machine). **AI shader/web generation** is a headline
  feature but **free and bring-your-own-key** — the un-copyable differentiator, without us hosting
  or paying for inference.

## Free vs. Premium (proposed split — needs owner sign-off)

Goal: free tier is *actually useful* (so people run it daily and hit the gate naturally),
premium is *clearly worth it*.

| Capability | Free | Premium (trial · subscription · lifetime) |
|---|---|---|
| Import your own MP4 (local video) | ✅ | ✅ |
| Import / share community `.livewallpaper` (P2P) | ✅ | ✅ |
| **AI shader/web generation** (bring-your-own-key) | ✅ free | ✅ free |
| Built-in wallpapers | a curated handful (e.g. 2 shaders, 1 web) | full catalog |
| Our premium shader packs (device-bound) | sampler | all |
| Our premium web wallpapers (device-bound) | sampler | all |
| Multi-monitor: assign per display | ✅ | ✅ |
| Multi-monitor: **per-display playlists / rotation** | ❌ | ✅ |
| Power Governor (occlusion/battery/thermal pause) | ✅ (never paywall the good-citizen behavior) | ✅ |
| Config editor (tweak shader/web params) | basic | full |
| Lock-screen / screen-saver video | — (deferred, see below) | — |

**AI generation sits in the free column deliberately:** the user brings their own provider key (they
pay their own API costs, or nothing with a local Ollama/LM Studio), so paywalling it would be
charging for something we don't provide. It stays a headline draw for the *product*, not a paid gate.

Pricing (as shipped): after a **7-day free trial** — **monthly $5 / R$5**, **annual $50 / R$50**,
**lifetime $150 / R$150**. Stripe (worldwide) + InfinitePay (Brazil); Apple IAP for a future MAS
build. Canonical figures/caps live in the backend `docs/BILLING.md`.

Entitlement mechanism (built): a device-bound license issued by the backend and verified **offline**
against an embedded public key (`Licensing.swift` / `Entitlement.swift`). The billing rail (Stripe /
InfinitePay / Apple) is just how an *order* gets created; the app stays channel-agnostic behind that
one module. Full scheme in [LICENSING.md](LICENSING.md).

## Build order (post-decision)

Priority reflects "double down on our moat + make the gate exist", cheapest-high-impact first.

1. **Multi-monitor UI sprint** *(low effort, engine already done).* Promote per-screen
   assignment from the menu-bar submenu into a visual grid in MainWindow (card per `NSScreen`
   + thumbnail + dropdown). Generalize the M6 `RotationController` from global to per-`screenID`
   (per-display playlists). Add cached preview thumbnails (video → `AVAssetImageGenerator`;
   metal/web → off-screen snapshot) — reused by the catalog too.
2. **Curated catalog + preview.** Repurpose the M4 workshop client as a read-only feed of **our
   own** premium content (no user uploads). Add preview-before-apply. Add **peer-to-peer share**:
   an "export to share" affordance so users can send local wallpapers to each other.
3. **Entitlement/paywall + device-bound licensing.** One module. Free vs. premium per the table
   above; device-bound activation for premium downloads per [LICENSING.md](LICENSING.md).
4. **AI shader/web generation (free, bring-your-own-key).** The un-copyable differentiator: generate
   Metal/web wallpapers from a prompt (vs. competitors' MP4-search). Users bring their own provider
   key (Anthropic / OpenAI-compatible / local Ollama) — we never proxy or pay for inference. Runs
   through the existing `ShaderValidator`/`WebValidator` gates before install. **Done.**
5. **Surface performance + onboarding.** Turn PERFORMANCE.md into an in-app/marketing claim;
   add the M6 onboarding.

## Deferred track — lock-screen / screen-saver video

Re-evaluate **after first revenue**. If pursued, gate behind a spike (new "M0"):

- **Fase A — spike:** from an unsandboxed process, register a `WallpaperExtensionKit` `.appex`
  and play our own video on the macOS 26.x lock screen. Study Phosphene / Wallpaper-Sync for
  `dlopen`, `Mirror`-reflected XPC types, the `WallpaperSnapshotXPC` swizzle, and the container
  + Darwin-notification contract. Exit: our video appears on the lock screen from our build.
- **Fase B — two-process arch:** unsandboxed companion + `.appex`; distribution becomes
  notarized-direct only (document in DISTRIBUTION.md; kills Phase D for this feature).
- **Fase C — resilience:** wrap all private-framework access behind one `LockScreenBridge.swift`
  with OS-version detection and graceful degradation, so a macOS-27-style break disables only
  this feature instead of crashing the app.

## Docs that now need the owner's revision

These still describe the UGC/workshop model and conflict with this pivot — flagged, **not**
edited unilaterally:

- **DESIGN.md** — §1 principle 2 ("community content is strangers' code"), §8 (community
  backend & workshop), §11 (milestones M4/M5 framing), and the top-line "with a community
  workshop" description.
- **ROADMAP.md** — Phase 2 (M5/M5.5) is now largely out of scope; M4 becomes "curated catalog
  feed" rather than a browse-a-UGC-catalog step.
- **CLAUDE.md** — the "Phase 2 = community/workshop" scope discipline section.
