# M4 — Read-only Workshop: implementation plan + setup checklist

Goal: browse a catalog of wallpapers in the app and **install any of them from the cloud**, with no
auth. Seeded with first-party content. This proves the whole download → install path and is useful
on its own. Publishing/auth/moderation are M5.

Parent scope: [PHASE2_BACKEND.md](PHASE2_BACKEND.md). Decisions locked there (Supabase + R2,
gate-before-public, Sign in with Apple for M5).

---

## 0. Why M4 needs almost no server code

Supabase exposes an **auto-generated REST API** (PostgREST) over your tables, guarded by
**Row-Level Security**. If the only rule is "anyone may read rows where `status = 'published'`", the
app can query the catalog directly — no custom endpoints to write. R2 serves the bundle/preview/
thumbnail bytes over its CDN. So M4 is: **SQL + a seed script + a Workshop UI in the app.**

```
 app  ──HTTPS GET (anon key)──►  Supabase PostgREST  ──►  wallpapers table (RLS: read published)
   │                                                          returns rows incl. R2 keys
   └──HTTPS GET (public)────────►  Cloudflare R2 / CDN  ──►  bundle .livewallpaper + preview + thumb
        then → Library.install(fromZipAt:)  (verifies checksum + shader gate — Phase 1)
```

**Security note that makes this safe:** installs still go through `Library.install`, which verifies
the SHA-256 checksum and runs the fragment-only shader gate. A compromised catalog or CDN **cannot**
bypass the client's safety checks — the backend is convenience, not the trust boundary.

---

## 1. Account-setup checklist (your part — needs account creation + keys)

I can't create accounts or hold your keys, so do this once. UI labels may shift slightly.

### A. Supabase (catalog + API)
1. Create an account at **supabase.com** → **New project**.
2. Pick a **region** near your users; set a strong **database password** (store in your password manager).
3. When it's ready, go to **Project Settings → API** and copy:
   - **Project URL** — e.g. `https://abcd1234.supabase.co`  *(public — safe to ship)*
   - **anon public** key  *(public by design — RLS protects the data; safe to ship in the app)*
   - **service_role** key  *(SECRET — seeding/admin only; never in the app or git)*
4. Open **SQL Editor** and run the schema in §2 (creates the table + RLS policies).

### B. Cloudflare R2 (bundle storage + CDN)
1. Create a **Cloudflare** account → **R2** → **Create bucket**, name it `lw-wallpapers`.
2. **Public access:** for M4, enable the bucket's **r2.dev public URL** (Settings → Public access).
   Copy the public base URL — e.g. `https://pub-xxxx.r2.dev`. *(Production: attach a custom domain
   behind Cloudflare's CDN later — same bytes, nicer URL.)*
3. **API token for seeding:** R2 → **Manage API Tokens** → create a token with **Object Read & Write**
   for this bucket. Copy the **Access Key ID**, **Secret Access Key**, and the **S3 endpoint**
   (`https://<accountid>.r2.cloudflarestorage.com`). *(SECRET — seeding only.)*

### C. Put the values where they belong
- **App config (public):** `Project URL`, `anon key`, and the **R2 public base URL** →
  `Sources/LiveWallpaper/WorkshopConfig.swift` (see §4). These are safe to commit.
- **Secrets (never commit):** `service_role` key + R2 API keys/endpoint → a local **`.env`**
  (already gitignored). Copy `.env.example` → `.env` and fill it in. Used only by the seed script.

---

## 2. Database schema (run in Supabase SQL Editor)

M4 keeps one flat table (a `versions` table is added in M5 when updates/moderation matter).

```sql
create table wallpapers (
  id             uuid primary key default gen_random_uuid(),
  title          text not null,
  author_handle  text default 'built-in',
  type           text not null check (type in ('video','metal','web')),
  tags           text[] not null default '{}',
  status         text not null default 'published'
                   check (status in ('draft','pending','published','rejected','removed')),
  bundle_key     text not null,          -- R2 object key of the .livewallpaper
  preview_key    text,                   -- R2 object key of preview.mp4 (optional)
  thumb_key      text,                   -- R2 object key of thumbnail.png (optional)
  checksum       text not null,          -- sha256- ... (matches manifest)
  size_bytes     bigint,
  download_count bigint not null default 0,
  created_at     timestamptz not null default now()
);

-- Row-Level Security: the public may read ONLY published rows; no writes for anon.
alter table wallpapers enable row level security;
create policy "read published" on wallpapers
  for select using (status = 'published');

-- Safe, rate-limitable download counter callable by anyone (no row write access needed).
create function increment_download(wp uuid) returns void
  language sql security definer as $$
    update wallpapers set download_count = download_count + 1
    where id = wp and status = 'published';
  $$;
grant execute on function increment_download(uuid) to anon;

-- Helpful indexes for browse/search.
create index on wallpapers (created_at desc);
create index on wallpapers (download_count desc);
create index on wallpapers using gin (tags);
```

Seeding uses the **service_role** key, which bypasses RLS — so no insert policy is needed for anon.

---

## 3. Seeding first-party content (admin script, not shipped)

`scripts/seed-workshop.sh` (reads `.env`) will, for each built-in wallpaper:
1. Build a `.livewallpaper` (reuse the app's exporter — generalize `--make-sample` into
   `--export <builtin-id> <path>`).
2. Upload bundle (+ optional preview/thumbnail) to R2 via the **S3-compatible** API
   (`aws s3 cp --endpoint-url <r2-endpoint>` or `rclone`).
3. `INSERT` a catalog row via PostgREST using the **service_role** key
   (`curl -H "apikey: $SERVICE_ROLE" -H "Authorization: Bearer $SERVICE_ROLE" ... /rest/v1/wallpapers`).

Result: the seeded shaders appear in the in-app Workshop immediately. This same upload+insert path is
what M5's authenticated upload flow will do server-side.

---

## 4. Client implementation (in the app)

New files under `Sources/LiveWallpaper/`:

- **`WorkshopConfig.swift`** — public constants (commit these):
  ```swift
  enum WorkshopConfig {
      static let supabaseURL = "https://YOUR-PROJECT.supabase.co"
      static let supabaseAnonKey = "YOUR-ANON-KEY"   // public by design (RLS enforced)
      static let r2PublicBase = "https://pub-XXXX.r2.dev"
  }
  ```
- **`WorkshopItem.swift`** — `Codable` mapping a catalog row; computed `bundleURL`, `previewURL`,
  `thumbURL` = `r2PublicBase + "/" + key`.
- **`WorkshopClient.swift`** — `URLSession` calls to PostgREST:
  - `fetchCatalog(query:sort:) async throws -> [WorkshopItem]`
    → `GET {url}/rest/v1/wallpapers?status=eq.published&select=*&order=created_at.desc`
      (search: `&title=ilike.*term*`), header `apikey: <anon>`.
  - `downloadBundle(_:) async throws -> URL` → download to a temp file; then call
    `increment_download` via `POST {url}/rest/v1/rpc/increment_download`.
- **`WorkshopView.swift` + `WorkshopWindowController.swift`** — a SwiftUI window: searchable grid of
  thumbnails (title, type badge, download count) with an **Install** button.
  Install → `downloadBundle` → **`Library.install(fromZipAt:)`** → success toast + it appears in the
  🖼️ switcher. Errors surfaced via the existing alert helper.
- **Menu:** add **"Browse Workshop…"** to the status-bar menu (opens the window).

No new entitlements — `network.client` is already present. All content still verified by
`Library.install` on the way in.

---

## 5. Secrets & config policy

- **Committed (public):** Supabase URL, anon key, R2 public base. These are inherently public in a
  shipped app; RLS is the actual guard. `WorkshopConfig.swift` ships with placeholders.
- **Never committed:** `service_role` key, R2 API keys/endpoint → `.env` (gitignored). Used only by
  `scripts/seed-workshop.sh` on your machine.
- `.gitignore` already excludes `.env`; a committed **`.env.example`** documents the required vars.

---

## 6. Acceptance criteria

- [ ] `wallpapers` table + RLS live in Supabase; anon can read published rows, cannot write.
- [ ] R2 bucket serves a seeded `.livewallpaper` over its public URL.
- [ ] Seed script publishes the built-in shaders (bundle + row) end to end.
- [ ] In-app **Browse Workshop…** lists seeded wallpapers with thumbnails + search.
- [ ] **Install** downloads a bundle, `Library.install` verifies + stores it, and it renders.
- [ ] Tampering with a hosted bundle → install rejected by the checksum gate (proves trust boundary).
- [ ] `download_count` increments on install.

---

## 7. Task order & rough effort

1. **You:** provision Supabase + R2, fill `.env` and `WorkshopConfig.swift` (§1). *(~30–45 min)*
2. Run schema SQL (§2). *(minutes)*
3. `--export <builtin>` CLI + `scripts/seed-workshop.sh`; seed the built-ins (§3). *(half day)*
4. `WorkshopClient` + `WorkshopItem` + config (§4). *(half day)*
5. `WorkshopView` + window + menu entry; wire Install → `Library.install` (§4). *(~day)*
6. End-to-end test against acceptance criteria (§6); add a `--workshop-smoke` CLI that fetches the
   catalog and prints the count for CI-free verification. *(~half day)*

---

## 8. Deferred to M5 (don't build in M4)

Auth (Sign in with Apple), the upload/publish flow, server-side validation Edge Function, the
`versions` table, moderation queue, ratings/reports, bundle signing. M4 is read + install only.
