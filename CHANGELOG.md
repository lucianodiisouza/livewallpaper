# Changelog

All notable changes to Primo Engine are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Sections per release:
- **Added** — new features
- **Changed** — changes in existing functionality
- **Fixed** — bug fixes
- **Removed** — removed features

GitHub Release notes are generated automatically from the commit list since the previous
tag (see [`.github/workflows/release.yml`](.github/workflows/release.yml)) — this file is a
human-readable, curated summary and is **not** the source for the release notes.

## [Unreleased]

## [0.3.13] — 2026-08-04

### Changed
- **Sample wallpaper `now-playing-vinyl` bumped to v0.2.0** — tracks the in-app version surfaced
  to users (no app-code changes; manifest + bundled sample only).

## [0.3.10] — 2026-08-04

### Fixed
- **Explore catalog no longer blinks and scrolls to top on install** — installing a wallpaper
  triggered a full catalog reload, which swapped the grid for a loading spinner and reset the
  scroll position. The tile's installed state is driven by local state, so the reload was
  unnecessary and is gone.

## [0.3.9] — 2026-08-04

### Added
- **Language selector in Preferences + Onboarding** — surfaces the language preference that was
  already wired up in `Preferences.language` / `AppLanguage` (auto / English / Português). A new
  `Language` section in Preferences lets you change it any time, and a dedicated onboarding step
  (between Welcome and Pick) asks for it on first launch, so the rest of the intro shows in the
  chosen language. The picker uses the language's own name ("Português" stays "Português" no
  matter the active UI language) so a translator can recognise the row without switching first.

## [0.3.8] — 2026-08-04

### Added
- **Featured carousel is one card at a time** — replaced the peek-of-next-card layout with
  full-bleed paging so each featured wallpaper owns the row, with no neighbour peeking in.
  New circular, semi-transparent side arrows (left/right) sit on top of the card and
  advance one page per tap. Disabled and dimmed at the ends.
- **App-wide glass buttons (iPad-style)** — all primary CTAs (Install, Apply, Generate,
  Check activation, Start 7-day free trial, Get Started, Continue, Done) and the
  Featured card Install/Unlock now use `.glassProminent` instead of the system
  `.borderedProminent`. The system-accent blue is gone across the app — Install, Apply,
  and the rest are now consistent with the glass treatment already used by the catalog
  sidebar and the Workshop tiles. Premium-gated Unlock keeps its yellow tint as a
  monetisation signal.

### Changed
- **CHANGELOG.md + auto-injected release notes** — the project now keeps a curated
  changelog in `CHANGELOG.md`, and the release workflow extracts the matching section
  and appends it to the GitHub Release notes on every `v*` tag push. Future releases
  should be curated here at cut time.

[Unreleased]: https://github.com/lucianodiisouza/livewallpaper/compare/v0.3.9...HEAD
[0.3.9]: https://github.com/lucianodiisouza/livewallpaper/compare/v0.3.8...v0.3.9
[0.3.8]: https://github.com/lucianodiisouza/livewallpaper/compare/v0.3.7...v0.3.8
[0.3.7]: https://github.com/lucianodiisouza/livewallpaper/compare/v0.3.6...v0.3.7
