# Distribution, signing & auto-updates

How LiveWallpaper is shipped — now (unsigned, GitHub Releases) and later (signed, notarized,
auto-updating) once an Apple Developer account is available.

## Phase A — now: GitHub Releases, unsigned

- Build the `.app`, zip it, attach to a **GitHub Release** with a semver tag (`v0.x.y`).
- The app is a menu-bar `LSUIElement` (no Dock icon).
- Because it isn't code-signed, Gatekeeper blocks the first launch. Document the workaround in
  the release notes and README: right-click → **Open**, or allow via
  **System Settings → Privacy & Security**.
- Keep the release checklist simple: bump version, build Release config, zip, draft release,
  attach artifact, write notes.

### Release artifact naming
`LiveWallpaper-<version>.zip` (and later `.dmg`). Artifacts are **not** committed to git
(see `.gitignore`); they live only on the Releases page.

## Phase B — later: Developer ID signing + notarization

Gated on an **Apple Developer Program** account ($99/yr). Once available:

1. **Sign** with a *Developer ID Application* certificate:
   `codesign --deep --force --options runtime --sign "Developer ID Application: …" LiveWallpaper.app`
   - Enable **Hardened Runtime** (`--options runtime`). Audit entitlements (see DESIGN.md §10):
     `network.client`, `files.user-selected.read-only`, app-container access.
2. **Notarize** with `notarytool`:
   `xcrun notarytool submit LiveWallpaper.zip --apple-id … --team-id … --wait`
3. **Staple** the ticket: `xcrun stapler staple LiveWallpaper.app`.

Result: no Gatekeeper warning on launch. Ship the signed+stapled build via GitHub Releases as
before.

## Phase C — later: auto-updates via Sparkle

[Sparkle](https://sparkle-project.org) is the standard updater for notarized non-App-Store Mac
apps. It requires signed builds, so it lands with (or after) Phase B.

- Host an **appcast** XML feed (can be a file in the repo / GitHub Pages / a release asset).
- Each release: sign the update with an **EdDSA** key, add an `<item>` to the appcast with the
  artifact URL, length, and signature.
- The app checks the appcast on a schedule and offers in-place updates.
- **Keep the Sparkle EdDSA private key out of the repo** (see `.gitignore` → secrets).

## Phase D — optional: Mac App Store

A possible *second* channel, **pending the sandbox spike** (DESIGN.md §12): confirm an
App-Sandbox build can still create the desktop-level window on the target macOS. If it can't,
stay notarized-direct only. The MAS build would use StoreKit for updates instead of Sparkle.

## CI/CD

**Phase A is live**: [.github/workflows/release.yml](../.github/workflows/release.yml) builds on a
`vX.Y.Z` tag push (macos-26 runner), runs the headless self-test, zips the `.app` as
`PrimoEngine-<version>.zip` (+ `.sha256`), and publishes a GitHub Release with install/Gatekeeper
notes. `workflow_dispatch` gives a no-publish dry run. See [RELEASING.md](RELEASING.md).

Later phases extend the **same** workflow: (Phase B) sign + notarize + staple after the build →
(Phase C) update the appcast. Secrets (certificates, notarization creds, Sparkle key) live in
GitHub Actions secrets, never in the repo.
