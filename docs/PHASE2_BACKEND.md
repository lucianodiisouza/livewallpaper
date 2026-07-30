# Phase 2 — Community Workshop Backend (scope)

The server side that lets people **publish, browse, and install** community wallpapers. The engine
(Phase 1) already renders and sandboxes untrusted content and installs `.livewallpaper` bundles;
Phase 2 is the network + storage + trust layer around it.

> Status: scoping. Nothing here is built yet.
>
> **Decisions locked:**
> - **Submissions:** in-app self-serve upload (creators publish without leaving the app) — chosen to
>   minimize friction over a GitHub-PR flow.
> - **Identity:** **Sign in with Apple** — lowest-friction accountability on macOS (Touch ID, no
>   password). Gates *publishing only*; browsing/installing stays anonymous. (M5.)
> - **Stack:** **PocketBase on Railway** (catalog + API rules + auth + admin UI) **+ Cloudflare R2
>   for the file bytes** (zero egress). Railway *meters egress*, so bundles are served from R2, not
>   Railway — keeps cost ~$5/mo even with video. Chosen over Supabase for cost control.
> - **Hosting:** Railway (managed deploy of PocketBase). **Backend lives in a separate repo:
>   `livewallpaper-workshop`** (schema, hooks, Railway/R2 deploy, seed). This repo is the client only.
> - **Moderation:** **gate-before-public** — validated uploads sit `pending` until approved (M5 uses
>   PocketBase's built-in admin UI as the review queue).
>
> Client plan: [M4_PLAN.md](M4_PLAN.md). Deploy details live in the `livewallpaper-workshop` repo.
> Note: §§2–10 below describe the original Supabase+R2 design as reference/rationale; the **locked**
> choices above supersede them.

## 1. Goals & constraints (these shape every choice)

- **Free & open-source, solo + AI maintainer.** Minimize build effort *and* ops toil.
- **Cheap at rest, cheap to scale.** The dominant cost is **egress bandwidth** (people downloading
  wallpapers — video especially). Choose storage with **zero egress fees**.
- **Untrusted uploads.** Server must **re-validate everything** (never trust the client). Rendering
  is already sandboxed on the client; the backend's job is admission control + takedown.
- **Moderation is the bottleneck**, not code. Design so automation carries the long tail and a human
  reviews little.

## 2. Architecture: two planes

```
                         ┌────────────────────────────────────────────┐
   macOS client          │  CONTROL PLANE  (catalog, auth, moderation) │
  (Workshop UI +         │  Postgres + Auth + RLS + serverless funcs    │
   Phase-1 Library) ─────┤   • catalog/search   • upload finalize       │
        │    ▲           │   • ratings/reports  • validation trigger    │
        │    │ JSON/HTTPS │   • moderation queue + actions               │
        │    │           └───────────────┬──────────────────────────────┘
        │    │                           │ writes rows / reads status
        │    │  presigned PUT            ▼
        │    └──────────────►  CONTENT PLANE  (bundles + previews)
        │   download via CDN   Object store w/ ZERO egress + global CDN
        └──────────────────►   (.livewallpaper, preview.mp4, thumbnail)
```

- **Control plane** = database + auth + API + moderation. Small JSON payloads.
- **Content plane** = the actual bundle/preview/thumbnail bytes, served straight from a CDN-backed
  object store. Keeping bytes *out* of the API path is what keeps it cheap and fast.

## 3. Recommended stack (+ alternative)

**Recommended: Supabase (control plane) + Cloudflare R2 (content plane).**
- **Supabase** — managed Postgres + Auth (Sign in with Apple / GitHub) + Row-Level Security + Edge
  Functions (Deno/TS). Gives auth, DB, authorization, and a place for serverless logic with almost
  nothing to build. Generous free tier.
- **Cloudflare R2** — S3-compatible object storage with **zero egress fees**, fronted by Cloudflare's
  CDN. This is the single most important cost decision: video wallpapers are big and popular, and
  egress is what bankrupts free projects. R2 makes downloads effectively free.

**Alternative: all-Cloudflare** (Workers + D1 + R2 + Access). Cheapest and one vendor, but you build
auth yourself and D1 is SQLite. Prefer this only if avoiding Supabase is worth the extra auth work.

Either way: **content bytes live in R2 behind the CDN; the API only ever moves small JSON + signed
URLs.**

## 4. Data model (Postgres sketch)

```
profiles(id, handle, display_name, created_at, role[user|trusted|admin], banned_at)
wallpapers(id, author_id, title, type[video|metal|web], tags[], status[draft|pending|published|
           rejected|removed], latest_version_id, download_count, rating_avg, rating_count,
           created_at, updated_at)
versions(id, wallpaper_id, semver, r2_key, preview_key, thumb_key, checksum, size_bytes,
         manifest_json, moderation_status[pending|approved|rejected], created_at, signature)
ratings(user_id, wallpaper_id, stars, created_at)          -- one per user per wallpaper
reports(id, wallpaper_id, reporter_id, reason, note, created_at, resolved_at)
moderation_actions(id, version_id, admin_id, action, note, created_at)
```

**RLS**: anyone reads `status=published`; authors read/write their own rows; only `admin` sees the
moderation queue and writes `moderation_actions`. Server (not the client) sets `author_id` from the
authenticated session and computes `signature` — the manifest's self-declared author is
informational only, so takedowns and bans are enforceable.

## 5. API surface (thin)

Most reads are Supabase's auto-generated REST/RPC over the tables (guarded by RLS). A few Edge
Functions cover the side-effectful flows:

- `GET  /wallpapers` — search/browse: `?q=&type=&tag=&sort=new|top|downloads&cursor=`
- `GET  /wallpapers/:id` — detail + versions + preview/thumb CDN URLs
- `POST /uploads` — auth'd; returns a **presigned R2 PUT** (+ rate/quota check)
- `POST /wallpapers` — **finalize**: register the uploaded bundle, enqueue validation
- `POST /wallpapers/:id/download` — increment counter, return the bundle CDN URL
- `POST /wallpapers/:id/rating`, `POST /wallpapers/:id/report`
- `GET  /moderation/queue`, `POST /moderation/:versionId/(approve|reject)` — admin only

## 6. Upload & validation pipeline

```
client packs .livewallpaper ─► POST /uploads ─► presigned PUT to R2 ─► POST /wallpapers (finalize)
                                                                            │
                                                    Edge Function: VALIDATE  ▼
   fetch bundle from R2 → unzip → re-run ALL client checks server-side:
     • manifest schema + required fields + size caps
     • SHA-256 checksum over content/  (must match manifest)
     • metal: fragment-only static gate  (port of ShaderValidator)
     • web:   static scan for network/eval/obfuscation  (port of WebValidator)
     • preview.mp4 / thumbnail.png present + within duration/dimension caps
   pass → versions.moderation_status = 'pending'  (enters human queue)
   fail → 'rejected' with reason; nothing is ever published unvalidated
```

**Never trust the client.** The server re-runs the same gates the app runs. The Swift validators
(`ShaderValidator`, `WebValidator`, `Manifest.validate`, checksum) are the source of truth; the TS
ports must stay in sync — **keep the rules in one documented place** and mirror them (a known
duplication risk; consider a shared JSON rule spec later).

Previews/thumbnails are **required in the bundle** (already in the format), so the server only
*validates* them — no server-side transcode compute to run or pay for in v1.

## 7. Moderation (the actual hard part)

- **Gate before public** (recommended): `pending` → human approve → `published`. Safer for a small
  maintainer; costs latency.
  *Alternative:* publish-then-moderate (faster, riskier; relies on fast takedown + reports).
- **Automation first**: schema/size/static-analysis rejections happen before a human ever looks.
  Flag (don't auto-approve) web bundles and anything with network use for closer review.
- **Human queue**: a minimal admin web view over `moderation/queue` (preview + manifest + flags →
  Approve/Reject). Can start as a Supabase table view / simple protected page.
- **Trust tiers**: `trusted` creators get lighter/async review to keep the queue small.
- **Takedown & bans**: every version is signed + tied to an account → one-click remove + author ban.
  Reports auto-hide a wallpaper past a threshold pending re-review.

## 8. Client integration (reuses Phase 1)

- **Browse/Install**: Workshop UI lists `GET /wallpapers`, shows preview; Install downloads the
  bundle from the CDN and hands it to the **existing `Library.install(fromZipAt:)`** — which already
  verifies checksum + runs the shader gate. No new render path.
- **Publish (in-app, self-serve)**: one-tap **Sign in with Apple** → pack current wallpaper →
  `POST /uploads` → presigned PUT to R2 → finalize. Never leaves the app. Sign-in is required only
  here — not for browsing/installing.
- **Report**: a menu action → `POST /report`.
- The `.livewallpaper` `signature` field (already in the format) becomes **required** for published
  bundles; the server signs the content hash against the author account.

## 9. Security & abuse

- Server-side re-validation (§6) is the core control; render-time sandboxing (Phase 1) is the backstop.
- Per-account **upload quotas + rate limits**; size caps per bundle and per asset.
- Malware/hash check on any binary assets (video/images).
- Signed, expiring upload URLs; downloads are public (it's an open catalog) but counted.
- No secrets in the client; the app only ever holds a user JWT.

## 10. Cost model

- **Storage**: R2 ~free to 10GB, then ~$0.015/GB-mo. **Egress: $0** (the whole point).
- **Control plane**: Supabase free tier (DB + 50k MAU auth) covers early scale.
- **What bites at scale**: total stored bytes — i.e. lots of large *video* wallpapers. Mitigate with
  HEVC encouragement, size caps, and by favoring metal/web wallpapers (kilobytes vs megabytes).
- Realistic early bill: **~$0/mo**, scaling to low tens of dollars well before it's popular.

## 11. Legal / policy (needed before public uploads)

- Terms of Service + content policy (no illegal/NSFW/infringing content), Privacy Policy.
- DMCA takedown process (the signature/account model already supports enforcement).
- A clear license expectation for uploaded content (e.g. creator retains copyright, grants
  distribution rights). Decide this before opening submissions.

## 12. Build plan

**M4 — Workshop (read-only).** Content plane + catalog + browse/search + install from CDN. Seed with
first-party wallpapers. **No auth needed to browse/install.** Proves the whole download path end to
end and is useful on its own.

**M5 — Publishing + moderation.** Auth (Apple/GitHub), upload → presigned PUT → finalize, the
server-side validation Edge Function, the moderation queue + admin view, ratings + reports, bundle
signing + takedown/bans.

**M5.5 — Trust & polish.** Trusted-creator tier, abuse limits, report auto-hide, basic analytics.

## 13. Decisions

**Locked** (see top of doc): in-app self-serve submission · Sign in with Apple · Supabase + R2 ·
gate-before-public moderation.

**Still open (not blocking M4, which is read-only):**
1. **Validator duplication**: accept a TS re-port of the Swift gates (ShaderValidator/WebValidator)
   for M5, or invest early in a shared JSON rule spec both sides read.
2. **Preview generation**: require preview/thumbnail in the bundle (recommended, no server compute)
   vs server-side transcode later.
3. **Content license/policy**: what rights uploaders grant — decide before submissions open (M5).
4. **Friction vs abuse dial**: whether first-time publishers need any extra step beyond Apple
   sign-in (e.g. a cooldown or lower quota) to blunt spam before it hits the review queue.
