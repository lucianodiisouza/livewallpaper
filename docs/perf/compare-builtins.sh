#!/bin/bash
# compare-builtins.sh — cycle through the four built-in wallpapers, sampling each.
#
# Output goes to stdout AND ./compare-builtins.log (next to this script).
# Expect ~40s of wall time.
#
# What it measures, per wallpaper:
#   - Single ps snapshot right after the switch
#   - 5 one-second CPU% samples averaged together (5s-avg)
#   - RSS at the end of the 5s window
#   - Final ps snapshot
#
# Run from the same directory as the other scripts (so the relative
# ./sample-once.sh call resolves).
set -euo pipefail

OUT_LOG=./compare-builtins.log
: > "$OUT_LOG"
exec > >(tee -a "$OUT_LOG") 2>&1

if [[ -z "${PRIMO_PID:-}" ]]; then
  PRIMO_PID=$(pgrep -f "Primo Engine\.app/Contents/MacOS/LiveWallpaper" | head -1 || true)
  if [[ -z "$PRIMO_PID" ]]; then
    echo "Primo Engine is not running. Launch it from dist/Primo Engine.app first." >&2
    exit 1
  fi
fi

echo "=== Primo Engine built-in comparison ==="
echo "Date:    $(date)"
printf "Total RAM: %s\n" "$(sysctl -n hw.memsize | awk '{printf "%.2f GB", $2/1024/1024/1024}')"
echo "Arch:    $(uname -m)  macOS: $(sw_vers -productVersion)"
echo "PID:     $PRIMO_PID"
echo

# Move into the script's own directory so ./sample-once.sh resolves.
cd "$(dirname "$0")"

# 5-second average CPU% helper using float-safe arithmetic.
avg5() {
  local label=$1 pid=$2
  local total=0 n=0 v
  for i in 1 2 3 4 5; do
    v=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
    total=$(awk -v t="$total" -v a="$v" 'BEGIN{printf "%.2f", t+a}')
    n=$((n + 1))
    sleep 1
  done
  printf "  %s 5s-avg CPU%%: %s\n" "$label" "$(awk -v t="$total" -v n="$n" 'BEGIN{printf "%.2f", t/n}')"
  printf "  %s RSS at end:   %s KB\n" "$label" "$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ')"
}

for TITLE in "Shader · Plasma" "Shader · Aurora" "Web · Starfield" "Video Loop"; do
  echo "============================================================"
  echo "Switching to: $TITLE"
  echo "============================================================"
  osascript <<AS 2>/dev/null
tell application "System Events"
  tell process "LiveWallpaper"
    click menu bar item 1 of menu bar 1
    delay 0.3
    click menu item "$TITLE" of menu 1 of menu bar item 1 of menu bar 1
  end tell
end tell
AS
  sleep 1
  ./sample-once.sh "post-switch: $TITLE"
  avg5 "$TITLE" "$PRIMO_PID"
  ./sample-once.sh "after 5s: $TITLE"
  echo
done

echo "=== done ==="
