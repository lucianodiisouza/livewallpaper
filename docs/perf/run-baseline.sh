#!/bin/bash
# run-baseline.sh — open a heavy WebGL2 page in a real browser (Safari/Chrome/Firefox)
#                   so you can compare Primo Engine's WebRenderer against a full browser.
#
# This is the "what would a Chromium-based wallpaper engine cost you?" baseline.
# The page (baselines/heavy-webgl.html) intentionally has 5,000 animated particles
# + a custom fragment shader + multiple draw passes per frame.
#
# Usage:
#   ./run-baseline.sh safari   15
#   ./run-baseline.sh chrome   15
#   ./run-baseline.sh firefox  15
#
# The first arg is the browser, the second is how long to leave the page running
# before closing the browser. The whole run is non-interactive once the browser
# opens — the script quits the browser after the timeout.
#
# To sample the browser's CPU while it's running, do this in another terminal
# while the browser is up:
#   ps -A -o pid,command | grep -E "Safari.app/Contents/MacOS/Safari$|WebKit|GPU|WebContent" | grep -v grep
#   top -l 1 -pid <pid>
set -euo pipefail

BROWSER=${1:?"usage: $0 safari|chrome|firefox [seconds]"}
SECS=${2:-15}
FILE="$(cd "$(dirname "$0")" && pwd)/baselines/heavy-webgl.html"
URL="file://$FILE"

if [[ ! -f "$FILE" ]]; then
  echo "Baseline HTML not found at: $FILE" >&2
  exit 1
fi

case "$BROWSER" in
  safari)  APP="Safari";           APP_PATH="/Applications/Safari.app" ;;
  chrome)  APP="Google Chrome";    APP_PATH="/Applications/Google Chrome.app" ;;
  firefox) APP="Firefox";          APP_PATH="/Applications/Firefox.app" ;;
  *) echo "Unknown browser: $BROWSER (use safari|chrome|firefox)" >&2; exit 1 ;;
esac

if [[ ! -d "$APP_PATH" ]]; then
  echo "Browser not installed at: $APP_PATH" >&2
  exit 1
fi

echo "Opening $URL in $APP for ${SECS}s..." >&2
/usr/bin/open -a "$APP" "$FILE"
echo "Browser is up. Sample its procs now:" >&2
echo "  ps -A -o pid,%cpu,rss,command | grep -E 'com\\.apple\\.WebKit|Google Chrome Helper|Firefox' | grep -v grep" >&2
sleep "$SECS"
echo "Closing $APP..." >&2
osascript -e "tell application \"$APP\" to quit" 2>/dev/null || true
echo "Done." >&2
