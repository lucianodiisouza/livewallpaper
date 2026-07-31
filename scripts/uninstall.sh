#!/usr/bin/env bash
#
# Uninstall Primo Engine and remove all of its data from this Mac.
#
# Removes: the app bundle(s), the sandbox container, preferences, caches, WebKit data
# (compiled content-rule lists), saved state, and the non-sandbox Application Support library.
# It does NOT touch the source repository — only the built app and per-user data.
#
# Usage:
#   scripts/uninstall.sh            # list what exists, then ask before deleting
#   scripts/uninstall.sh --yes      # delete without prompting (for automation)
#   scripts/uninstall.sh --dry-run  # only list what would be removed
set -euo pipefail

BUNDLE_ID="com.livewallpaper.app"
APP_NAME="Primo Engine"      # display name → the .app bundle in Finder
PROC_NAME="LiveWallpaper"    # unchanged: executable/process name and Application Support dir
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ASSUME_YES=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        *) echo "Unknown option: $arg"; exit 2 ;;
    esac
done

shopt -s nullglob

# Must run as the normal user (NOT sudo): ~/Library/Containers is TCC-protected, so deletion needs
# the user's Finder (or Full Disk Access) — sudo/root does not override TCC.
if [ "$(id -u)" -eq 0 ]; then
    echo "Do not run this with sudo. Run it as your normal user:"
    echo "    scripts/uninstall.sh"
    exit 1
fi

# Remove a path. Plain rm first; if the OS protects it (~/Library/Containers is TCC-protected and
# rm/sudo get "Operation not permitted"), fall back to having Finder move it to the Trash.
remove_path() {
    local p="$1"
    chflags -R noschg,nouchg "$p" 2>/dev/null || true
    rm -rf "$p" 2>/dev/null || true
    if [ ! -e "$p" ]; then echo "  removed:  $p"; return 0; fi

    echo "  protected — moving to Trash via Finder: $p"
    osascript -e "tell application \"Finder\" to delete (POSIX file \"$p\" as alias)" >/dev/null 2>&1 || true
    if [ ! -e "$p" ]; then echo "  trashed:  $p"; return 0; fi

    echo "  ⚠ could NOT remove: $p"
    return 1
}

# Candidate locations (globs expand to existing files only via nullglob).
CANDIDATES=(
    "/Applications/$APP_NAME.app"
    "$HOME/Applications/$APP_NAME.app"
    "$REPO_ROOT/dist/$APP_NAME.app"                       # local dev build output
    "$HOME/Library/Containers/$BUNDLE_ID"                 # sandbox container (holds its own prefs/library/WebKit)
    "$HOME/Library/Application Support/$PROC_NAME"        # non-sandbox library (from bare-binary runs)
    "$HOME/Library/Caches/$BUNDLE_ID"
    "$HOME/Library/HTTPStorages/$BUNDLE_ID"
    "$HOME/Library/WebKit/$BUNDLE_ID"
    "$HOME/Library/Preferences/$BUNDLE_ID.plist"
    "$HOME/Library/Preferences/ByHost/$BUNDLE_ID".*.plist
    "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
    "$HOME/Library/Group Containers/"*"$BUNDLE_ID"*
)

# Keep only paths that actually exist.
EXISTING=()
for p in "${CANDIDATES[@]}"; do
    [ -e "$p" ] && EXISTING+=("$p")
done

echo "Primo Engine uninstaller"
echo "========================="

# 1) Stop any running instance.
if pgrep -x "$PROC_NAME" >/dev/null 2>&1; then
    echo "• Quitting running ${APP_NAME}…"
    [ "$DRY_RUN" -eq 0 ] && pkill -x "$PROC_NAME" 2>/dev/null || true
    sleep 1
fi

if [ "${#EXISTING[@]}" -eq 0 ]; then
    echo "Nothing found — Primo Engine data is already gone."
else
    echo "The following will be removed:"
    for p in "${EXISTING[@]}"; do echo "    $p"; done
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "(dry run — nothing deleted)"
    exit 0
fi

# 2) Confirm.
if [ "${#EXISTING[@]}" -gt 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
    printf "Proceed with deletion? [y/N] "
    read -r answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) echo "Aborted."; exit 1 ;;
    esac
fi

# 3) Delete (with Finder fallback for protected paths).
FAILED=0
for p in "${EXISTING[@]}"; do
    remove_path "$p" || FAILED=1
done

# 4) Flush the preferences daemon's cache of our domain.
defaults delete "$BUNDLE_ID" 2>/dev/null || true

echo
if [ "$FAILED" -eq 1 ]; then
    echo "⚠ Some items could not be removed automatically."
    echo "  ~/Library/Containers is protected by macOS privacy (TCC) — only Finder or a"
    echo "  process with Full Disk Access may delete it (sudo does NOT override this)."
    echo "  Fix it with any ONE of these:"
    echo "    • Run this script from your own Terminal and approve the one-time"
    echo "      'Terminal wants to control Finder' prompt, then it will Trash it; or"
    echo "    • In Finder: Shift-Cmd-G → ~/Library/Containers →"
    echo "      drag 'com.livewallpaper.app' to the Trash; or"
    echo "    • Grant your terminal Full Disk Access (System Settings → Privacy &"
    echo "      Security → Full Disk Access), then re-run this script."
else
    echo "✅ Done. (Items moved to Trash still occupy space until you empty it.)"
fi
echo
echo "Note on 'Launch at login':"
echo "  If you had enabled it, macOS may still list $APP_NAME under"
echo "  System Settings → General → Login Items → 'Allow in the Background'."
echo "  With the app now deleted, that leftover entry is inert and typically"
echo "  disappears after the next login. To force it: toggle it off there,"
echo "  or run 'sfltool resetbtm' (clears ALL background-item registrations)."
