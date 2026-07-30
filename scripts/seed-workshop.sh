#!/usr/bin/env bash
#
# Seed the PocketBase workshop with the built-in shaders. For each one it builds a .livewallpaper
# (via the app's real exporter), then creates a published `wallpapers` record with the bundle file.
#
# Prerequisites:
#   • A running PocketBase with a `wallpapers` collection (see docs/M4_PLAN.md §2 for the schema).
#   • .env filled in (copy from .env.example): PB_URL, PB_ADMIN_EMAIL, PB_ADMIN_PASSWORD.
#   • A release build (the script builds one if needed).
#
# Usage: scripts/seed-workshop.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[ -f .env ] || { echo "Missing .env (copy .env.example → .env and fill it in)."; exit 1; }
# shellcheck disable=SC1091
set -a; source .env; set +a
: "${PB_URL:?}"; : "${PB_ADMIN_EMAIL:?}"; : "${PB_ADMIN_PASSWORD:?}"

BIN="${BIN:-$(swift build -c release --show-bin-path)/LiveWallpaper}"
[ -x "$BIN" ] || { echo "Building release binary…"; swift build -c release >/dev/null; }

# Authenticate as a PocketBase superuser (v0.23+). Older PocketBase: /api/admins/auth-with-password.
echo "▶ Authenticating with PocketBase…"
TOKEN=$(curl -sS -X POST "$PB_URL/api/collections/_superusers/auth-with-password" \
    -H 'Content-Type: application/json' \
    -d "{\"identity\":\"$PB_ADMIN_EMAIL\",\"password\":\"$PB_ADMIN_PASSWORD\"}" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')
[ -n "$TOKEN" ] || { echo "Auth failed."; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

seed_one() {
    local id="$1" bundle="$TMP/$1.livewallpaper"
    echo "▶ $id: building package…"
    "$BIN" --export "$id" "$bundle" >/dev/null

    local manifest checksum type size title
    manifest="$(unzip -p "$bundle" manifest.json)"
    checksum="$(printf '%s' "$manifest" | python3 -c 'import sys,json;print(json.load(sys.stdin)["checksum"])')"
    type="$(printf '%s' "$manifest" | python3 -c 'import sys,json;print(json.load(sys.stdin)["type"])')"
    title="$(printf '%s' "$manifest" | python3 -c 'import sys,json;print(json.load(sys.stdin)["title"])')"
    size="$(stat -f%z "$bundle")"

    echo "▶ $id: creating catalog record…"
    curl -sS -X POST "$PB_URL/api/collections/wallpapers/records" \
        -H "Authorization: $TOKEN" \
        -F "title=$title" \
        -F "author_handle=built-in" \
        -F "type=$type" \
        -F "status=published" \
        -F "checksum=$checksum" \
        -F "size_bytes=$size" \
        -F 'tags=["shader","built-in"]' \
        -F "bundle=@$bundle;type=application/zip" \
        -o /dev/null -w "   HTTP %{http_code}\n"
}

for id in plasma aurora matrix; do
    seed_one "$id"
done

echo "✅ Seeded. Open the app → Browse Workshop… to see them."
