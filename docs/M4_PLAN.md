# M4 — Read-only Workshop: implementation plan + setup checklist

Goal: browse a catalog of wallpapers in the app and **install any of them from the cloud**, with no
auth. Seeded with first-party content. Proves the whole download → install path and is useful on its
own. Publishing/auth/moderation are M5.

**Backend: self-hosted PocketBase** (one Go binary + SQLite), files served by PocketBase itself.
**No R2/CDN** — a ~€5/mo VPS with a large bandwidth allowance covers ~10k users comfortably (see
cost recap §8). Parent scope: [PHASE2_BACKEND.md](PHASE2_BACKEND.md).

---

## 0. Architecture — almost no custom server code

PocketBase gives you a REST API + per-collection **API rules** (its RLS equivalent) + a built-in
admin UI. If the `wallpapers` collection's list/view rule is `status = "published"`, the app reads
the catalog directly and downloads bundle files straight from PocketBase — no endpoints to write.

```
 app ──HTTPS GET──► PocketBase /api/collections/wallpapers/records   (rule: read published)
   │                 └─ returns records incl. bundle/thumb filenames
   └──HTTPS GET──► PocketBase /api/files/wallpapers/{id}/{file}       (the .livewallpaper bytes)
        then → Library.install(fromZipAt:)   (verifies checksum + shader gate — Phase 1)
```

**Why this is safe:** installs still run through `Library.install`, which verifies the SHA-256
checksum and the fragment-only shader gate. A compromised catalog **cannot** bypass the client's
safety checks — the backend is convenience, not the trust boundary.

The client is already built (backend-agnostic): `WorkshopConfig`, `WorkshopItem`, `WorkshopClient`,
`WorkshopUI`, the **Browse Workshop…** menu item, and `--export` / `--workshop-smoke` CLIs.

---

## 1. Server-setup checklist (your part)

### A. A small VPS
1. Create a VPS (Hetzner CX22-class: 2 vCPU / 4GB / ~20TB traffic, ~€5/mo — the big traffic
   allowance is why we don't need a CDN). Ubuntu is fine.
2. Point a domain/subdomain at it (e.g. `api.yourdomain.com`) and put **HTTPS** in front —
   easiest is a Caddy reverse proxy (auto-TLS) to PocketBase on `:8090`.

### B. PocketBase
1. Download the PocketBase binary for linux/arm64 or amd64, run `./pocketbase serve`
   (behind Caddy). Consider a systemd unit so it restarts on boot.
2. Open the **admin UI** (`/_/`) and create your **superuser** account (email + password → these go
   in `.env` for seeding).
3. Create the **`wallpapers` collection** with the fields + API rules in §2 (via the admin UI, or
   import the schema JSON).
4. **Backups:** schedule a copy of `pb_data/` (SQLite + files) — PocketBase has a built-in Backups
   panel; enable it.

### C. Point the app + env at it
- **App (public):** set `WorkshopConfig.pocketBaseURL` to your host (e.g.
  `https://api.yourdomain.com`). Safe to commit — browsing is governed by the collection rule.
- **Seeding (secret):** copy `.env.example` → `.env` and fill `PB_URL`, `PB_ADMIN_EMAIL`,
  `PB_ADMIN_PASSWORD`. `.env` is gitignored.

---

## 2. `wallpapers` collection (schema + API rules)

Fields:

| field | type | notes |
|---|---|---|
| `title` | text | required |
| `author_handle` | text | default `built-in` |
| `type` | select | `video` / `metal` / `web` |
| `tags` | json | array of strings |
| `status` | select | `draft` / `pending` / `published` / `rejected` / `removed` |
| `bundle` | file | the `.livewallpaper` (single file) |
| `thumb` | file | optional still image |
| `preview` | file | optional short loop |
| `checksum` | text | `sha256-…` (mirrors the manifest) |
| `size_bytes` | number | bundle size |
| `download_count` | number | default 0 |

`id`, `created`, `updated` are automatic.

**API rules** (this is the authorization — set on the collection):
- **List / View:** `status = "published"`  ← public may read only published rows
- **Create / Update / Delete:** *(leave locked in M4 — only the superuser/seed script writes; M5
  opens authenticated create.)*

---

## 3. Download counter (optional hook)

`WorkshopClient.incrementDownload` best-effort POSTs to `/api/lw/increment/:id`. To make it count,
add a PocketBase hook file `pb_hooks/main.pb.js`:

```js
routerAdd("POST", "/api/lw/increment/:id", (c) => {
  const rec = $app.findRecordById("wallpapers", c.pathParam("id"))
  if (rec.get("status") !== "published") return c.json(404, {})
  rec.set("download_count", rec.getInt("download_count") + 1)
  $app.save(rec)
  return c.json(200, { ok: true })
})
```

Skip it and the counter simply stays at seed value — nothing else breaks.

---

## 4. Seeding first-party content

`scripts/seed-workshop.sh` (reads `.env`) authenticates as the superuser and, for each built-in
shader, builds a package with `LiveWallpaper --export <id>` and creates a **published** record with
the bundle file attached. Run it once the collection exists:

```bash
scripts/seed-workshop.sh
```

Result: Plasma / Aurora / Matrix appear in the in-app **Browse Workshop…** window. This same
upload-and-create path is what M5's authenticated publish flow will do.

---

## 5. Client (already implemented)

- `WorkshopConfig.swift` — the public PocketBase URL + `isConfigured`.
- `WorkshopItem.swift` — decodes a record; builds `/api/files/...` URLs for bundle/thumb/preview.
- `WorkshopClient.swift` — `fetchCatalog(search:sort:)`, `downloadBundle(_:)`,
  `incrementDownload(_:)`; plus `WorkshopSmoke` for `--workshop-smoke`.
- `WorkshopUI.swift` — searchable/sortable list with **Install**; shows a friendly "not set up yet"
  until `pocketBaseURL` is filled. Install → `downloadBundle` → **`Library.install`** → renders.
- **Menu:** 🖼️ → **Browse Workshop…**.

No secrets in the app; no new entitlements (uses existing `network.client`).

---

## 6. Acceptance criteria

- [ ] PocketBase reachable over HTTPS; `wallpapers` collection with the §2 rules.
- [ ] Anonymous `GET …/records?filter=status='published'` returns rows; non-published hidden.
- [ ] `scripts/seed-workshop.sh` publishes the three built-in shaders (record + bundle file).
- [ ] `LiveWallpaper --workshop-smoke` prints `OK: 3 published wallpaper(s).`
- [ ] In-app **Browse Workshop…** lists them with thumbnails/search; **Install** downloads →
  `Library.install` verifies + renders.
- [ ] Tampering with a hosted bundle → install rejected by the checksum gate (trust boundary holds).
- [ ] (If hook added) `download_count` increments on install.

---

## 7. Task status

- ✅ Client: config, model, networking, UI, menu entry, `--export` + `--workshop-smoke` CLIs, seed
  script — **built and compiling now** (verified with `--workshop-smoke` unconfigured + `--export`).
- ⬜ **You:** provision the VPS + PocketBase, create the collection (§1–2), fill config + `.env`.
- ⬜ Run `seed-workshop.sh`; verify against §6.
- ⬜ (Optional) add the increment hook (§3).

---

## 8. Cost recap (~10k users, ~100 new wallpapers/month)

- **Storage:** ~1 GB/month → ~12 GB/year. Fits any VPS disk.
- **Bandwidth (installs, not browsing — the UI uses tiny thumbnails):** ~200 GB/month moderate,
  ~900 GB/month heavy. A Hetzner-class ~20 TB/month allowance swallows both → **€0 overage**.
- **Total: ~€5/month flat.** R2/CDN only becomes worthwhile at multi-TB/month or for global
  low-latency — an easy later swap (point file URLs at a CDN), not a day-one need.

---

## 9. Deferred to M5 (don't build in M4)

Sign in with Apple (needs an Apple-token-verify hook in PocketBase), authenticated upload/publish,
server-side validation on upload, moderation (PocketBase's admin UI gives you the queue for free),
ratings/reports, bundle signing. M4 is read + install only.
