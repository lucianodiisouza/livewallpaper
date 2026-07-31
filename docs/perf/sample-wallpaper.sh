#!/bin/bash
# sample-wallpaper.sh — switch to a built-in wallpaper via the menu bar, sample N ticks.
#
# Drives the menu bar item via AppleScript (no need to touch the mouse) and then
# snapshots Primo Engine's CPU/RSS over a few seconds.
#
# Usage:
#   ./sample-wallpaper.sh "Shader · Plasma" 5
#
# The exact menu item titles are listed in WallpaperCatalog.swift and currently are:
#   "Video Loop"          (kind: video)
#   "Shader · Plasma"     (kind: metal)
#   "Shader · Aurora"     (kind: metal)
#   "Web · Starfield"     (kind: web)
# plus any user-installed third-party .livewallpaper packages.
set -euo pipefail

TITLE=${1:?"usage: $0 '<menu item title>' [seconds]"}
SECS=${2:-3}

if [[ -z "${PRIMO_PID:-}" ]]; then
  PRIMO_PID=$(pgrep -f "Primo Engine\.app/Contents/MacOS/LiveWallpaper" | head -1 || true)
  if [[ -z "$PRIMO_PID" ]]; then
    echo "Primo Engine is not running. Launch it from dist/Primo Engine.app first." >&2
    exit 1
  fi
fi

echo "--- pre-switch: $TITLE (PID $PRIMO_PID) ---"
./sample-once.sh "pre  $TITLE"

# Open the menu and click the named item. The middle dot (·) is a non-ASCII
# char; AppleScript handles it fine over the System Events IPC.
osascript <<AS
tell application "System Events"
  tell process "LiveWallpaper"
    click menu bar item 1 of menu bar 1
    delay 0.3
    click menu item "$TITLE" of menu 1 of menu bar item 1 of menu bar 1
  end tell
end tell
AS

echo "--- post-switch: $TITLE ---"
for i in $(seq 1 "$SECS"); do
  ./sample-once.sh "tick $i ($TITLE)"
  sleep 1
done
