#!/bin/bash
# governor-test.sh — verify the Governor pauses render when the desktop is occluded.
#
# Procedure:
#   A) Sample Primo Engine with the desktop visible (baseline)
#   B) Cover the desktop with a fullscreen Safari window; sample again
#   C) Quit Safari; sample once more
#
# Expected: B should show ~0% CPU. A and C should match within noise.
#
# Why Safari: it has a stable, scriptable fullscreen toggle (cmd-ctrl-F).
# Anything that fully covers the desktop will trigger NSWindow.occlusionState
# on Primo Engine's window and the Governor should stop the render loop.
set -euo pipefail

OUT_LOG=./governor-test.log
: > "$OUT_LOG"
exec > >(tee -a "$OUT_LOG") 2>&1

if [[ -z "${PRIMO_PID:-}" ]]; then
  PRIMO_PID=$(pgrep -f "Primo Engine\.app/Contents/MacOS/LiveWallpaper" | head -1 || true)
  if [[ -z "$PRIMO_PID" ]]; then
    echo "Primo Engine is not running. Launch it from dist/Primo Engine.app first." >&2
    exit 1
  fi
fi

cd "$(dirname "$0")"

echo "=== Governor occlusion test ==="
echo "Date:  $(date)"
echo "PID:   $PRIMO_PID"
echo

avg() {
  local label=$1
  local total=0 n=0 v
  for i in 1 2 3 4 5; do
    v=$(ps -p "$PRIMO_PID" -o %cpu= 2>/dev/null | tr -d ' ')
    total=$(awk -v t="$total" -v a="$v" 'BEGIN{printf "%.2f", t+a}')
    n=$((n + 1))
    sleep 1
  done
  printf "  %s 5s-avg CPU%%: %s\n" "$label" "$(awk -v t="$total" -v n="$n" 'BEGIN{printf "%.2f", t/n}')"
}

echo "--- (A) baseline, desktop visible ---"
./sample-once.sh "visible-A"
avg "A visible"

echo
echo "--- (B) covering desktop with fullscreen Safari ---"
osascript <<'AS'
tell application "Safari" to activate
delay 0.3
tell application "System Events"
  keystroke "f" using {command down, control down}
end tell
AS
sleep 1
# Belt-and-suspenders: also try plain cmd-F in case the host uses the
# older fullscreen shortcut.
osascript -e 'tell application "System Events" to keystroke "f" using {command down}' 2>/dev/null || true
sleep 1
./sample-once.sh "covered-B"
avg "B covered"

echo
echo "--- (C) uncover (Safari Quit) ---"
osascript -e 'tell application "Safari" to quit' 2>/dev/null || true
sleep 1
./sample-once.sh "uncovered-C"
avg "C uncovered"

echo
echo "=== done ==="
