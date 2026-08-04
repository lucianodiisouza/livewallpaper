# Changelog

All notable changes to Primo Engine are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Sections per release:
- **Added** — new features
- **Changed** — changes in existing functionality
- **Fixed** — bug fixes
- **Removed** — removed features

The release workflow auto-injects the matching section into the GitHub Release notes
on every `v*` tag push — see [`.github/workflows/release.yml`](.github/workflows/release.yml).

## [Unreleased]

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

[Unreleased]: https://github.com/lucianodiisouza/livewallpaper/compare/v0.3.8...HEAD
[0.3.8]: https://github.com/lucianodiisouza/livewallpaper/compare/v0.3.7...v0.3.8
[0.3.7]: https://github.com/lucianodiisouza/livewallpaper/compare/v0.3.6...v0.3.7
