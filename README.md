# LiveWallpaper

Native animated wallpapers for macOS — video, Metal shaders, and web — that stay out of your
way. Free and open-source, built to respect your Mac's battery and GPU rather than fight them.

Inspired by Wallpaper Engine on Windows, rebuilt from scratch for macOS with a hard rule:
**if you can't see it moving, it isn't rendering.**

> **Status: Phase 1 (the engine) is complete.** Video, Metal-shader, and web wallpapers render
> from a sandboxed app with a power-aware pause engine, plus a `.livewallpaper` package format with
> import/export. The community "workshop" (sharing/discovery) is Phase 2, in progress. Signed
> notarized builds land once an Apple Developer account is set up.

> **Performance, measured on Apple Silicon (M4 Pro, 12 cores, Metal 4):** renders at desktop
> refresh rate using **3% of one CPU core, 260 mW of GPU power at 338 MHz (the lowest
> frequency bin), 130 MB of RAM**, and drops to **0% CPU when occluded**. Energy impact is
> effectively zero. Full breakdown + reproduction scripts in [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Features (planned)

- 🎬 **Video wallpapers** — looping HEVC, including transparency.
- ✨ **Metal shader wallpapers** — Shadertoy-style, tiny files, GPU-native.
- 🌐 **Web wallpapers** — Canvas / WebGL / Three.js in a locked-down WebView.
- 🔋 **Actually respects your Mac** — pauses when covered, on battery, in Low Power Mode,
  when a fullscreen app is up, or when the display sleeps. Rides ProMotion adaptively.
- 🖥️ **Multi-monitor** — a different wallpaper per screen.
- 🧩 **Community workshop** _(later)_ — browse and share wallpapers.

## Requirements

- macOS 26 (Tahoe) or later
- Apple Silicon

## Install

**Today:** download the latest `PrimoEngine-<version>.zip` from the [Releases](../../releases)
page and unzip it.

These test builds are **not yet notarized by Apple**, so macOS Gatekeeper blocks the first launch
("Apple could not verify… is free of malware"). This is expected for an unsigned app — here's how
to run it:

1. Move **Primo Engine.app** to your `/Applications` folder.
2. **Right-click** (or Control-click) the app → **Open**.
3. In the dialog that appears, click **Open** again. macOS remembers this choice, so future
   launches open normally.

If you don't see an **Open** button (newer macOS sometimes only offers *Done* the first time):

- Open **System Settings → Privacy & Security**, scroll to the **Security** section, and click
  **Open Anyway** next to the Primo Engine message, then confirm.

Prefer the terminal? Clear the quarantine flag in one command, then open normally:

```bash
xattr -dr com.apple.quarantine "/Applications/Primo Engine.app"
```

Once it's running, look for the 🖼️ icon in the menu bar — that's where you switch wallpapers and
quit. Signed, notarized builds with in-app auto-updates will remove this step entirely once an
Apple Developer account is in place.

### Verify your download (optional)

Each release includes a `PrimoEngine-<version>.zip.sha256`. Confirm the zip is intact:

```bash
shasum -a 256 PrimoEngine-<version>.zip
```

The output should match the value in the `.sha256` file.

## Build from source

Requires Xcode 26+ and `ffmpeg` (for the bundled test loop; `brew install ffmpeg`).

```bash
git clone https://github.com/lucianodiisouza/livewallpaper.git
cd livewallpaper
./scripts/build-app.sh          # builds & assembles "dist/Primo Engine.app"
open "dist/Primo Engine.app"    # runs it — quit from the 🖼️ menu-bar item
```

The project is a SwiftPM executable; `swift build` compiles it, and `scripts/build-app.sh`
assembles the signed `.app`. See [CLAUDE.md](CLAUDE.md) and [DESIGN.md](DESIGN.md) for
architecture.

## Documentation

- [DESIGN.md](DESIGN.md) — architecture and product design (source of truth)
- [docs/PACKAGE_FORMAT.md](docs/PACKAGE_FORMAT.md) — the `.livewallpaper` bundle spec
- [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) — release, signing, and auto-update plan
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md) — measured CPU/GPU/power profile with
  the scripts to reproduce it on your own Mac ([how-to](docs/PERFORMANCE_REPRODUCE.md),
  scripts in `docs/perf/`)
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to contribute
- [SECURITY.md](SECURITY.md) — reporting vulnerabilities & the untrusted-content model
- **Backend:** the community workshop server lives in a separate repo —
  [livewallpaper-workshop](https://github.com/lucianodiisouza/livewallpaper-workshop)
  (PocketBase on Railway + Cloudflare R2)

## Contributing

Contributions welcome. This project is developed largely with AI assistance — see
[CLAUDE.md](CLAUDE.md) for the conventions and scope rules that keep it coherent.

## License

[MIT](LICENSE) © LiveWallpaper contributors.
