# Licensing, DRM & peer-to-peer sharing

Decision date: **2026-08-02**. Companion to [FREEMIUM.md](FREEMIUM.md). Defines how content
is distributed and protected now that there is **no user-upload server**.

## Two content worlds

| | **Community (local, P2P)** | **Premium (our server)** |
|---|---|---|
| Origin | user-created / user-imported in-app | downloaded from our store |
| Types | video (local MP4), shader, web | shader + web (our IP) |
| Sharing | freely shareable file-to-file (AirDrop, etc.) | device-bound, non-shareable |
| Moderation | **none** — no server, no queue | we author it, so trivially "moderated" |
| Manifest | `origin: local` | `origin: premium` + license |

**No user content ever hits our server.** People share `.livewallpaper` files between
themselves. This removes the moderation burden entirely — critical if the app grows faster
than we can staff review.

### Why P2P sharing is safe without moderation

The security model already assumes **hostile content** (DESIGN.md §7, CLAUDE.md decision 3):
`ShaderValidator` (fragment-only), `WebValidator`, and the caged WKWebView run **on import,
regardless of where the file came from**. A wallpaper received via AirDrop passes the exact same
gates as one from a server. So dropping moderation does **not** open a security hole.

### Video is local-only

We do **not** host or sell video. Video support = "import your own MP4" (free, local). Therefore
**DRM applies only to premium shader/web packs** — small files, our own IP. No need to DRM large
MP4s. This is a deliberate simplifier.

## DRM: goals and honest limits

**Goal:** a premium wallpaper bought/downloaded on Mac A must not run on Mac B. Stop piracy via
file copy.

**Honest limit (must stay documented):** Primo Engine is **open-source (MIT)** and the client
renders the content itself, so **client-side DRM is deterrence, not prevention.** A technical user
can patch the MIT client and dump decrypted content **on their own licensed machine**. That is
unavoidable with an open client that must decode to display.

What the scheme *does* achieve — and what actually matters — is stopping the easy, common attack:
copying a `.livewallpaper` to a friend. It won't load (wrong device). Don't over-invest past that;
these are ~$8 wallpapers and premium content is cheap for us to keep producing.

**Load-bearing principle:** the **private signing/encryption keys live only on the server.**
Open-sourcing the client leaks nothing that lets anyone forge a license — the client only carries
the **public** verification key.

**Decided (2026-08-02):** the **client stays 100% MIT/open**; the **backend server repo goes
private**. DRM security rests on server-side private keys, not client obscurity — so there's no
security reason to close any client code, and an open client is the trust story for a
"respects your Mac" app. All secrets live only on the private backend. (Reversible — nobody has
installed or forked yet.) Before flipping the `livewallpaper-workshop` repo to private, scrub the
git history for committed secrets (`.env`, `.wrangler/cache/wrangler-account.json`) and rotate any
key that was ever pushed.

## Scheme

Respects the **frozen v1 package format** (PACKAGE_FORMAT.md): a premium bundle is an **outer
encrypted envelope** wrapping a standard v1 bundle, plus a **license sidecar** — the inner bundle,
once decrypted, is ordinary v1 and flows through the normal validators. v1 is not mutated.

1. **Package classes** (additive manifest field): `origin: local | premium`. `premium` requires a
   valid device-bound license to decrypt/load.
2. **Activation:** on purchase, client reads a stable device id (`IOPlatformUUID` via IOKit) and
   sends `{purchase receipt, deviceID}` to the server. Server verifies the purchase, records the
   device (enforce a **device cap**, e.g. 3 Macs), and returns:
   - a **signed license token** — `sign(serverPrivKey, {deviceID, wallpaperID, purchaseID})`, and
   - the **content key wrapped to that device**.
3. **On load (client):** read local deviceID → verify license signature against the **embedded
   server public key** → check `license.deviceID == localDeviceID` (mismatch ⇒ refuse) → decrypt.
   License is **cached locally** after first activation (no server round-trip on every boot /
   works offline).
4. **Legit-user friction to handle:** new Mac / migration ⇒ device cap + **self-serve
   deactivation** (deactivate old Mac to free a slot). Without this, every new Mac is a support
   ticket. Consider reinstall / logic-board-replacement edge cases.

### Device identifier notes

- `IOPlatformUUID` is readable and stable per machine — good enough for device binding.
- True hardware serial needs more entitlement; not worth it. Don't use a Keychain-stored random
  UUID as the binding (it's per-install and copyable — defeats the point).

## Implemented so far (pre-StoreKit)

Landed 2026-08-03 in the Worker (`livewallpaper-workshop/worker/src/index.ts`) and client
(`Licensing.swift` / `Entitlement.swift`). Everything here works **without** an Apple Developer
account — StoreKit only replaces how an *order* is created.

- **Orders + device cap.** An **order** = one purchase; it owns a capped device set
  (`DEFAULT_DEVICE_CAP = 3`). `POST /admin/order {order_id, cap?}` provisions one (bearer
  `ADMIN_TOKEN`). Later a StoreKit webhook creates the same record keyed on Apple's
  `originalTransactionId`.
- **Activation.** `POST /activate {device_id, order_id}` binds this Mac to an order, enforcing the
  cap (`409 device_cap_reached` when full), then premium is granted. In the app: **Settings →
  Premium → enter a license code → Activate**. This is a real sales path before StoreKit — sell an
  order code, the buyer activates up to 3 Macs.
- **Self-serve deactivation.** `POST /deactivate {device_id}` frees the device's slot so a user can
  move to another Mac. In the app: **Settings → Premium → Deactivate this device**.
- **Short TTL + auto-renew.** Licenses now expire in **`LICENSE_TTL_DAYS = 14`** (was 30). The
  client silently renews on launch only when the cached token is missing or within ~5 days of expiry
  (`Licensing.refreshIfNeeded`). This bounds how long a deactivated/over-cap device keeps premium
  **offline** — the deliberate offline-DRM window (deactivation isn't instant offline; it takes
  effect once the cached license lapses).

**Still gated on Apple:** the StoreKit purchase that *creates* an order automatically (today an admin
provisions it), plus signing/notarization. See [PRE_APPLE_PLAN.md](PRE_APPLE_PLAN.md) A2.

## Relationship to the old roadmap

ROADMAP M5 already listed *"Bundle signing (server signs content hash to account)"* — conceived
for author accountability/takedown. That mechanism is **repurposed here for device-bound DRM**.
The rest of M5 (open upload, moderation queue, DMCA, payouts) stays **dropped** — see
[FREEMIUM.md](FREEMIUM.md).
