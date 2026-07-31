#!/bin/bash
# capture-powermetrics.sh — Apple-Silicon deep sample (needs sudo).
#
# Runs `powermetrics --show-all` for ~40 seconds at 1Hz and writes the output
# to ./powermetrics.log. This is the only script that requires sudo.
#
# What it captures:
#   - CPU, GPU, ANE power in mW (per-sample and avg)
#   - CPU frequency distribution per cluster
#   - GPU HW active residency + frequency distribution
#   - Per-process task table (so you can grep for LiveWallpaper)
#   - Thermal pressure
#
# Usage:
#   ./capture-powermetrics.sh
#   # password prompt, then ~40s of sampling
#   # output: ./powermetrics.log
#
# After it finishes, parse it like:
#   grep "^GPU Power:" powermetrics.log      # one number per second
#   grep "LiveWallpaper" powermetrics.log    # per-process rows
#   grep "GPU HW active" powermetrics.log    # GPU frequency + residency
#
# Notes:
# - "Second underflow occurred" messages on the terminal are benign — the
#   sampler is reporting that the wall-clock sample was 1037-1051ms instead
#   of exactly 1000ms. All data is still captured.
# - You can also use --show-initial-usage and --show-usage-summary to add
#   boot-to-now and end-of-run rollups.
set -euo pipefail

OUT=./powermetrics.log
echo "Sampling... output: $OUT" >&2
echo "Stop with Ctrl-C to stop early; the file written so far is still valid." >&2
sudo powermetrics \
  --show-all \
  -i 1000 \
  -n 40 \
  -s cpu_power,gpu_power,ane_power,thermal \
  -o "$OUT"
echo "Done. File: $OUT" >&2
echo "Quick checks:" >&2
echo "  grep -E '^(CPU|GPU|ANE) Power:' $OUT" >&2
echo "  grep 'GPU HW active residency' $OUT" >&2
echo "  grep 'LiveWallpaper' $OUT" >&2
