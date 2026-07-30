# LiveWallpaper

Native animated wallpapers for macOS — video, Metal shaders, and web — that stay out of your
way. Free and open-source, built to respect your Mac's battery and GPU rather than fight them.

Inspired by Wallpaper Engine on Windows, rebuilt from scratch for macOS with a hard rule:
**if you can't see it moving, it isn't rendering.**

> ⚠️ **Status: early development.** The engine is being built Phase 1 first (local playback);
> the community "workshop" comes later. Not yet ready for daily use.

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

**Today:** download the latest build from the [Releases](../../releases) page.

Because the app is not yet code-signed, macOS Gatekeeper will warn on first launch. Right-click
the app → **Open**, or allow it in **System Settings → Privacy & Security**. Signed, notarized
builds with in-app auto-updates are planned once an Apple Developer account is in place.

## Build from source

The Xcode project is being scaffolded. Build instructions will land here once it exists; see
[CLAUDE.md](CLAUDE.md) and [DESIGN.md](DESIGN.md) for the current architecture.

## Documentation

- [DESIGN.md](DESIGN.md) — architecture and product design (source of truth)
- [docs/PACKAGE_FORMAT.md](docs/PACKAGE_FORMAT.md) — the `.livewallpaper` bundle spec
- [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) — release, signing, and auto-update plan
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to contribute
- [SECURITY.md](SECURITY.md) — reporting vulnerabilities & the untrusted-content model

## Contributing

Contributions welcome. This project is developed largely with AI assistance — see
[CLAUDE.md](CLAUDE.md) for the conventions and scope rules that keep it coherent.

## License

[MIT](LICENSE) © LiveWallpaper contributors.
