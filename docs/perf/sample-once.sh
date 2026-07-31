#!/bin/bash
# sample-once.sh — single-process snapshot for Primo Engine.
#
# Prints the process row from `ps` (CPU%, MEM%, RSS, elapsed, state) plus
# a thread count, for a quick "what's it doing right now" check.
#
# Usage:
#   ./sample-once.sh                  # uses default PID (autodetected)
#   ./sample-once.sh "my label"       # adds a label and timestamp
#   PRIMO_PID=12345 ./sample-once.sh  # override the PID
#
# The default PID is discovered by looking for the app under dist/Primo Engine.app.
# This is robust across rebuilds (the PID changes, but the path doesn't).
set -euo pipefail

LABEL=${1:-sample}

# Auto-detect the running Primo Engine PID if not provided.
if [[ -z "${PRIMO_PID:-}" ]]; then
  PRIMO_PID=$(pgrep -f "Primo Engine\.app/Contents/MacOS/LiveWallpaper" | head -1 || true)
  if [[ -z "$PRIMO_PID" ]]; then
    echo "Primo Engine is not running. Launch it from dist/Primo Engine.app first." >&2
    exit 1
  fi
fi

ps -o pid,%cpu,%mem,rss,etime,state,command -p "$PRIMO_PID"
echo "Threads: $(ps -M -p "$PRIMO_PID" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
echo "Label: $LABEL @ $(date +%H:%M:%S)"
