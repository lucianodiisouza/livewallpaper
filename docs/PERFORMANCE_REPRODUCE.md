# How to reproduce the Primo Engine performance profile

This guide walks through running the same measurements that produced
[`PERFORMANCE.md`](PERFORMANCE.md) on your own machine. Every script lives
in `docs/perf/` and is self-contained — no dependencies beyond the macOS
command-line tools already on your Mac.

## What you'll need

- macOS (any version, but Apple Silicon for the `powermetrics` data)
- Primo Engine **already running** (built and launched from `dist/Primo Engine.app`)
- `sudo` access (only for `capture-powermetrics.sh`)
- ~5 minutes of wall time total
- Optionally, Safari / Chrome / Firefox installed (for the WebView baseline)

## Quick start

```bash
# 1. Make sure Primo Engine is running.
open dist/Primo\ Engine.app

# 2. From the scripts directory, run whichever test you want.
cd docs/perf
./sample-once.sh                                  # ~1s: single snapshot
./sample-wallpaper.sh "Shader · Plasma" 5         # ~10s: switch + sample
./compare-builtins.sh                             # ~40s: 4-way comparison
./governor-test.sh                                # ~30s: occlusion test
./run-baseline.sh safari 15                       # ~15s: open heavy page in Safari
sudo ./capture-powermetrics.sh                    # ~40s: Apple-Silicon deep sample
```

Each script writes its log to a file in the same directory and prints
to stdout. If you want fresh data, just re-run.

## What each script measures

### `sample-once.sh` — single ps snapshot

Prints the process row from `ps` plus a thread count, with a label and
timestamp. Useful as a sanity check ("is Primo Engine still running and
how much is it using?") or for scripting your own measurements.

```bash
./sample-once.sh                  # auto-detect PID
./sample-once.sh "before"         # label appears in the output
PRIMO_PID=12345 ./sample-once.sh  # override the PID
```

Output:

```
  PID  %CPU %MEM    RSS ELAPSED STAT COMMAND
20932   2.2  0.5 133472   39:30 S    .../Primo Engine.app/Contents/MacOS/LiveWallpaper
Threads: 16
Label: smoke test @ 12:25:48
```

### `sample-wallpaper.sh` — switch + sample

Switches to a built-in wallpaper via the menu bar (driven by AppleScript)
and samples Primo Engine for N seconds.

```bash
./sample-wallpaper.sh "Shader · Plasma" 5
```

The exact menu item titles you can use are in
`Sources/LiveWallpaper/WallpaperCatalog.swift` and currently include:

| Title | Kind |
|---|---|
| `Video Loop` | video (AVPlayer hardware decode) |
| `Shader · Plasma` | metal (fragment shader) |
| `Shader · Aurora` | metal (fragment shader, slightly heavier) |
| `Web · Starfield` | web (sandboxed WKWebView) |

Plus any user-imported third-party `.livewallpaper` packages.

### `compare-builtins.sh` — 4-way comparison

Cycles through all four built-in wallpapers, sampling each for 5 seconds,
and writes a summary to `compare-builtins.log`. This is the script that
produced the table in `PERFORMANCE.md` §2.

What you should see, roughly:

```
Shader · Plasma  5s-avg CPU%: ~6
Shader · Aurora  5s-avg CPU%: ~9
Web · Starfield  5s-avg CPU%: ~5
Video Loop       5s-avg CPU%: ~2
```

The exact numbers will vary with your Mac's CPU, ProMotion state, and
what other apps are running. The **shape** of the result should match.

### `governor-test.sh` — verify the 0%-when-covered claim

This is the headline test. It makes Safari fullscreen over the desktop
and measures Primo Engine's CPU before, during, and after.

```bash
./governor-test.sh
```

Expected output:

```
--- (A) baseline, desktop visible ---
  A visible 5s-avg CPU%: 2-4

--- (B) covering desktop with fullscreen Safari ---
  B covered 5s-avg CPU%: 0.00   ← the Governor is working

--- (C) uncover (Safari Quit) ---
  C uncovered 5s-avg CPU%: 2-4
```

If `B` is not 0.00% the Governor is broken. The script writes the full
log to `governor-test.log`.

> Note: Safari may ask for permission the first time to control another
> app. Grant it once and re-run.

### `capture-powermetrics.sh` — Apple-Silicon deep sample (sudo)

The only script that needs `sudo`. Runs `powermetrics --show-all` for
40 one-second samples and writes to `powermetrics.log`. This is the
script that produced the GPU power / frequency / residency data in
`PERFORMANCE.md` §7.

```bash
sudo ./capture-powermetrics.sh
```

You'll see "Second underflow occurred" messages — those are harmless,
they just mean the wall-clock sample was 1037-1051ms instead of exactly
1000ms. The data is still captured correctly.

After it finishes, useful greps:

```bash
# Power over time (mW per second)
grep -E "^(CPU|GPU|ANE) Power:" powermetrics.log

# GPU frequency + active residency (the "is the GPU ramping up?" check)
grep "GPU HW active" powermetrics.log

# Primo Engine's own per-process rows
grep "LiveWallpaper" powermetrics.log
```

To compute the GPU power average across the run:

```bash
grep "^GPU Power:" powermetrics.log | awk '{s+=$3; n++} END {printf "GPU avg: %.0f mW over %d samples\n", s/n, n}'
grep "^CPU Power:" powermetrics.log | awk '{s+=$3; n++} END {printf "CPU avg: %.0f mW over %d samples\n", s/n, n}'
```

To compute GPU active residency average:

```bash
grep "GPU HW active residency:" powermetrics.log | awk -F':  *' '{print $2}' | awk '{print $1}' | sed 's/%//' | awk '{s+=$1; n++} END {printf "GPU active residency avg: %.2f%%\n", s/n}'
```

### `run-baseline.sh` — open the heavy WebGL2 page in a real browser

This is the "what if Primo Engine had used Chromium/Electron?"
comparison. Opens `baselines/heavy-webgl.html` (5,000 animated
particles + custom fragment shader + multiple draw passes per frame)
in Safari, Chrome, or Firefox and leaves it running for N seconds.

```bash
./run-baseline.sh safari  15
./run-baseline.sh chrome  15
./run-baseline.sh firefox 15
```

While the browser is up, sample it in another terminal:

```bash
# Safari
ps -A -o pid,%cpu,%mem,rss,command | grep -E "Safari\.app/Contents/MacOS/Safari$|com\.apple\.WebKit" | grep -v grep

# Chrome
ps -A -o pid,%cpu,%mem,rss,command | grep -E "Google Chrome Helper|Google Chrome" | grep -v grep

# Firefox
ps -A -o pid,%cpu,%mem,rss,command | grep -E "Firefox\.app/Contents/MacOS/firefox" | grep -v grep
```

What you should see (numbers from a recent M4 Pro run):

| Browser | Main process CPU% | Helper procs total | Total RSS |
|---|---|---|---|
| Safari + heavy WebGL | ~10% | ~32% (one WebKit.GPU pinned at 24%) | 376 MB across 8 procs |
| Chrome + heavy WebGL | varies, often higher | 3+ renderer procs each at 5-20% | 400-600 MB |

vs Primo Engine's WebRenderer running the same workload shape:

| Process | CPU% | RSS | Notes |
|---|---|---|---|
| Primo Engine (one process) | 5-7% | 132 MB | Includes menu bar, SwiftUI window, and the WKWebView |
| (no helpers) | – | – | WebKit is in-process |

The point of the comparison is the *cost shape*: Primo Engine hosts
the same WebView technology in one process with no IPC overhead, and
the Governor can pause it. A real browser can't pause on occlusion,
spins up multiple processes per page, and pins helper processes at
high CPU% continuously.

## What's in this directory

```
docs/perf/
├── sample-once.sh             # single ps snapshot
├── sample-wallpaper.sh        # switch wallpaper + sample N seconds
├── compare-builtins.sh        # 4-way built-in comparison
├── governor-test.sh           # A/B/C occlusion test
├── capture-powermetrics.sh    # Apple-Silicon deep sample (sudo)
├── run-baseline.sh            # open heavy WebGL page in a real browser
├── baselines/
│   └── heavy-webgl.html       # the deliberately heavy page
├── examples/
│   └── powermetrics-excerpt.txt   # 3 representative samples from a real run
├── compare-builtins.log       # log from a recent 4-way run
├── governor-test.log          # log from a recent A/B/C run
└── powermetrics.log           # written by capture-powermetrics.sh
```

## Expected results vs reality

If your numbers are wildly different from what's in `PERFORMANCE.md`,
that itself is a useful signal:

| Symptom | Possible cause |
|---|---|
| CPU% is 3-5x higher across the board | Another app is dominating system load; close Chrome/Safari and re-run |
| `governor-test` shows non-zero CPU when covered | Something is preventing the display link from stopping; check whether another window is *partially* over the desktop |
| `powermetrics` shows GPU at >500 MHz | A user-installed `.livewallpaper` has a heavier shader; check which one is active via the menu bar |
| LiveWallpaper doesn't show up in `ps` | The PID changed or the app quit; rerun the script (it auto-detects) |
| `powermetrics` requires Touch ID / password | That's expected the first time; subsequent runs in the same session will remember |

## What the scripts do NOT measure

- **Battery impact over time.** That requires a longer test on battery
  with `pmset` logging. Not automated here.
- **Multi-monitor.** The Governor logic differs slightly for secondary
  displays; the scripts assume a single screen.
- **CPU thermals / throttling.** Long runs (10+ minutes) might hit
  thermal limits and reduce frequency; the scripts run for under a
  minute each so this is not an issue.
- **Sleep/wake behavior.** Not tested. The README claims the engine
  pauses on sleep; the code path is in `Governor.swift` but
  reproducing it requires a script that can suspend the host.

## Contributing new tests

If you write a new measurement (e.g. memory pressure over time, or
multi-monitor behavior), please:

1. Add the script to `docs/perf/` with a header comment block matching
   the existing style (purpose, usage, expected output).
2. Add the script name to the table above.
3. Add a sample log to this directory so reviewers can see the format
   without running it.
4. Update `PERFORMANCE.md` with a new section that references the new
   script and includes a one-paragraph interpretation.
