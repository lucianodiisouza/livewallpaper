# M4 — Read-only Workshop: client plan + how it connects

Goal: browse a catalog of wallpapers in the app and **install any of them**, no auth. Proves the
download → install path. Publishing/auth/moderation are M5.

**The backend lives in a separate repo: `livewallpaper-workshop`.** This doc covers the **client**
side (in this repo) and how it connects. Server setup (PocketBase on Railway, R2, schema, seeding)
is in that repo's `docs/DEPLOY.md`.

---

## Architecture

- **Catalog/metadata + API + auth (M5) + admin:** **PocketBase on Railway** — one service, cheap,
  built-in admin UI (which becomes the M5 moderation queue).
- **Bundle/preview/thumbnail bytes:** **Cloudflare R2** (zero egress). Chosen because **Railway
  meters egress** — keeping big downloads off Railway keeps cost ~$5/mo even with video. Each
  PocketBase record stores the file's **R2 URL**.

```
 app ──GET──► PocketBase (Railway) /api/collections/wallpapers/records   (rule: read published)
   │           └─ records carry bundle_url / thumb_url (→ R2)
   └──GET──► Cloudflare R2 (bundle_url)  ──►  the .livewallpaper bytes
        then → Library.install(fromZipAt:)   (verifies checksum + shader gate — Phase 1)
```

**Trust boundary:** installs still run through `Library.install` (checksum + fragment-only shader
gate), so a compromised catalog or CDN can't bypass the client's safety checks.

---

## Client (this repo — built & compiling)

- `WorkshopConfig.swift` — the public Railway PocketBase URL + `isConfigured`.
- `WorkshopItem.swift` — decodes a record; `bundle_url` / `thumb_url` are full R2 URLs.
- `WorkshopClient.swift` — `fetchCatalog(search:sort:)`, `downloadBundle(_:)`,
  `incrementDownload(_:)`; plus `WorkshopSmoke` for `--workshop-smoke`.
- `WorkshopUI.swift` — searchable/sortable list + **Install**; friendly "not set up yet" until
  configured. Install → `downloadBundle` → **`Library.install`** → renders.
- **Menu:** 🖼️ → **Browse Workshop…**. No secrets in the app; no new entitlements.

The only client task left is to set `WorkshopConfig.pocketBaseURL` to your Railway URL once the
backend is deployed.

---

## Record shape the client expects (defined server-side in the backend repo)

`wallpapers` collection, list/view rule `status = "published"`, fields:
`title, author_handle, type(video|metal|web), tags(json), status, bundle_url, thumb_url,
preview_url, checksum, size_bytes, download_count`. Full schema + Railway/R2 deploy + seed script
live in **`livewallpaper-workshop`**.

---

## Acceptance criteria (end to end)

- [ ] Backend deployed (see `livewallpaper-workshop`); anonymous read returns only `published`.
- [ ] Seed publishes the built-in shaders (bundle in R2, record in PocketBase).
- [ ] `LiveWallpaper --workshop-smoke` prints `OK: N published wallpaper(s).`
- [ ] **Browse Workshop…** lists them; **Install** downloads from R2 → `Library.install` → renders.
- [ ] Tampering with a hosted bundle → install rejected by the checksum gate.

---

## Deferred to M5

Sign in with Apple (Apple-token-verify hook in PocketBase), authenticated upload/publish,
server-side validation on upload, moderation (PocketBase admin UI), ratings/reports, signing.
