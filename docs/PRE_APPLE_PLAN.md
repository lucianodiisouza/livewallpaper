# Pre-Apple-subscription work plan

Created: **2026-08-03**. Scope: everything on the roadmap we can ship **without** an Apple
Developer account. Companion to [ROADMAP.md](../ROADMAP.md), [FREEMIUM.md](FREEMIUM.md) and
[LICENSING.md](LICENSING.md) — those remain the source of truth for direction; this doc only
sequences the un-blocked work.

## Why this doc

Several roadmap items are gated on the Apple Developer account (StoreKit purchase, Developer ID
signing/notarization, Sparkle, Mac App Store). But most of the remaining Phase-2 and M6 work is
**not** — and one item (device-bound premium catalog delivery) is a genuine gap, not just a
placeholder. This plan front-loads a shippable release, then finishes the money loop so the only
Apple-gated remainder is the StoreKit trigger + signing.

### Explicitly Apple-gated — NOT in scope here
- StoreKit purchase flipping the server-side `premium` flag (today the admin route does it).
- Phase B: Developer ID signing + notarization.
- Phase C: Sparkle auto-updates (sequenced after B).
- Phase D: Mac App Store (needs the account **and** the M0 sandbox spike).

---

## Track A — Close the freemium core loop (backend + client)

Makes the product monetizable the instant StoreKit lands. Backend lives in the separate
`livewallpaper-workshop` repo (`worker/src/index.ts`); client is `Sources/LiveWallpaper/`.

### A1. Premium catalog delivery — device-bound  ✅  *(deployed + validated 2026-08-03)*
The catalog was served straight from public PocketBase + R2, so premium bundle URLs would be
copyable between Macs — violating the "device-bound, can't copy" promise in
[FREEMIUM.md](FREEMIUM.md) / [LICENSING.md](LICENSING.md). Implemented:

- **Worker:** `POST /catalog/bundle` `{ device_id, item_id, bundle_key }` streams the bundle from a
  **private** R2 bucket (`BUNDLES` binding) **only** when `getDevice(device_id).premium === true`;
  otherwise `402`. Keys are restricted to the `premium/` prefix (no traversal). Free items still
  download straight from their public R2 URL. (`worker/src/index.ts`, `wrangler.jsonc`)
- **PocketBase / seed:** added `tier` (`free`/`premium`) and `bundle_key` fields; `seed-workshop.sh
  --tier premium` uploads to the private bucket and writes them. (`docs/DEPLOY.md`, `.env.example`)
- **Client:** `WorkshopItem` decodes `tier`/`bundle_key` (default free); `WorkshopClient.downloadBundle`
  routes premium through the backend with `Device.id`; `WorkshopUI` shows a Premium lock badge and an
  "Unlock" button that opens the paywall for non-entitled users. Checksum re-verify unchanged.
- Self-test: +5 checks (tier decode + premium-request contract). 40/40 pass; worker `deploy --dry-run`
  clean.
- **Infra — LIVE (2026-08-03):** private `lw-wallpapers-premium` bucket created; Worker deployed with
  the `BUNDLES` binding + `LICENSE_PRIVATE_KEY`/`ADMIN_TOKEN` secrets (private key verified to match
  the client's embedded public key); PocketBase `tier`/`bundle_key` fields added. Validated in
  production: premium device → 200 + exact bytes, non-premium → 402, traversal → 400, missing → 404.
  A 3-item premium showcase is seeded (see the workshop repo `docs/CATALOG.md`).
- Optional later hardening: swap the worker-proxied stream for short-lived signed R2 URLs.

### A2. Licensing backend hardening — the non-StoreKit remainder  ✅  *(done 2026-08-03)*
All testable **now** via `POST /admin/order`; StoreKit later just auto-creates the order.

- **Orders + device cap (default 3):** an order owns a capped device set in KV. `/admin/order
  {order_id, cap?}` provisions; `POST /activate {device_id, order_id}` binds a Mac and enforces the
  cap (`409 device_cap_reached`); `canActivate` is a pure, testable helper. (`worker/src/index.ts`)
- **Self-serve deactivation:** `POST /deactivate {device_id}` frees the slot. In-app **Settings →
  Premium → Deactivate this device**.
- **Activation UX:** **Settings → Premium → License code → Activate** — a real pre-StoreKit sales
  path (sell an order code; buyer activates ≤3 Macs). `Licensing.activate/deactivate` +
  `Entitlement.activate(code:)`.
- **Short TTL + auto-renew:** license TTL 30→**14 days**; client renews silently only when missing or
  within ~5 days of expiry (`Licensing.refreshIfNeeded`, called on launch), bounding the offline
  window after deactivation.
- Self-test +5 (renew decision + activate/deactivate request contracts); **45/45** pass; worker
  `deploy --dry-run` clean.
- **Remaining (Apple-gated only):** the StoreKit purchase that auto-creates an order — today an admin
  runs `/admin/order`.

---

## Track B — M6 polish (100% client-side, no Apple)

Ordered by leverage.

### B1. Onboarding / first-run flow  ✅  *(done 2026-08-03)*
Four-step walkthrough (welcome → pick a first wallpaper live → multi-monitor + rotation → Premium),
skippable, shown once on first launch and re-runnable from Settings → "Show welcome again". Gated on
`Preferences.hasCompletedOnboarding`; any dismissal marks it complete so it never re-nags; force with
`LW_ONBOARDING=1`. Implemented in `Onboarding.swift` (`OnboardingView` + `OnboardingWindowController`),
wired in `AppDelegate`, `+1` self-test check. Compiles clean; 35/35 self-test checks pass.

### B2. Schedules — time-of-day wallpaper changes  ✅  *(done 2026-08-03)*
A daily program of "at HH:MM → wallpaper" rows (**Settings → Schedule**), Premium-gated, applied by a
30s timer that switches at each entry's time and holds a manual override until the next one.
Independent of rotation (both can run). Pure resolver `WallpaperScheduleLogic.activeWallpaperID`
(wraps to the last entry before the day's first). `Schedule.swift` + `Preferences` persistence +
`AppDelegate` timer; +5 self-test checks. 50/50 pass.

### B3. Energy dashboard  ✅  *(done 2026-08-03)*
**Correction to the original assumption:** the `Governor` does *not* measure GPU/energy — it only
computes the render directive (paused/fps). Real numbers come from external `powermetrics`
(docs/PERFORMANCE.md). So the dashboard (**Settings → Energy**) shows two honest things: (1) the
**live** render state from the Governor — running/paused + the reason (covered, on battery, Low Power,
warm) — which is real; and (2) a coarse per-medium cost **estimate** (`EnergyModel`, ordered
video < web < metal and scaled by fps + rendered pixels, grounded in the measured profile), clearly
labelled an estimate with a pointer to `docs/PERFORMANCE_REPRODUCE.md`. Free (a trust feature, not
paywalled). +6 self-test checks; 55/55 pass.

### B4. Per-space wallpapers  ⬜  *(heavier — Spaces APIs are fiddly)*
Do after B1–B3.

### B5. Explicit fullscreen-app / active-space Governor signal  ✅  *(done 2026-08-03)*
The desktop windows use `.canJoinAllSpaces`, so `isOnActiveSpace` is useless and occlusion was the
only per-window signal — and it can lag entering a full-screen app. Added `FullscreenCoverage`: a
public-API check (`CGWindowListCopyWindowInfo` + `CGDisplayBounds`, same coord space, no flipping)
that pauses when *every* display is fully covered by a non-Primo normal window. Re-evaluated on
`activeSpaceDidChange` + `didActivateApplication`; OR-ed into the Governor alongside occlusion, so
it's multi-monitor correct. DESIGN.md §4 table synced. +4 self-test checks; 59/59 pass.

---

## Track C — Release readiness (no Apple)

### C1. Cut a tagged release  🟡  *(correction: releases already exist)*
The premise was stale — the pipeline **has** fired: **v0.1.0** and **v0.2.0** are live on the
Releases page (v0.2.0 = commit `4ec7d8a`). The real action is cutting **v0.3.0** to ship this
session's freemium work (B1/A1/A2/B2/B3), which is currently **uncommitted** on top of v0.2.0.
Steps: commit the work → push `main` → `git tag v0.3.0 && git push origin v0.3.0` → the workflow
builds/self-tests/publishes. **Outward-facing + public — needs the owner's explicit go-ahead.** A
safer first pass: Actions → Release (unsigned) → Run workflow (dry-run artifact, no public Release).

### C2. (Optional) M0 sandbox spike  ⬜
Pure engineering; answers the one real technical unknown (App-Sandbox desktop window on macOS 26 —
CLAUDE.md "one real risk"). **Unblocks** the Apple/MAS track for later at no Apple cost now.

---

## Suggested sequence

1. **B1 Onboarding** + **C1 first release** — get a shippable, welcoming build out fast.
2. **A1 + A2** — complete the paywall's backend so only StoreKit remains Apple-gated.
3. **B2 Schedules → B3 Energy dashboard** — depth features.
4. **B4, B5, C2** — as time allows.

This front-loads a usable release, then finishes the money loop, leaving a clean, minimal
Apple-gated remainder (StoreKit trigger + signing/notarization).
