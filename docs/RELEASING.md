# Releasing (Phase A — unsigned)

Cutting a test build for people to try, before Apple signing/notarization (Phase B).
The [release workflow](../.github/workflows/release.yml) does the build + publish; you just push a tag.

## Cut a release

1. Make sure `main` is green and self-test passes locally:
   ```
   scripts/build-app.sh && "dist/Primo Engine.app/Contents/MacOS/LiveWallpaper" --selftest
   ```
2. Pick a semver and push the tag (the tag drives the version — no file to bump):
   ```
   git tag v0.1.0
   git push origin v0.1.0
   ```
3. The **Release (unsigned)** workflow builds on a `macos-26` runner, runs the self-test,
   zips `Primo Engine.app` as `PrimoEngine-<version>.zip` (+ `.sha256`), and creates the
   GitHub Release with install/Gatekeeper notes.
4. Confirm the [Releases page](https://github.com/lucianodiisouza/livewallpaper/releases)
   shows the assets, then share the link with testers.

## Dry run (no release published)

Use **Actions → Release (unsigned) → Run workflow** (`workflow_dispatch`). It builds and
uploads the zip as a workflow artifact but does **not** create a public Release — good for
verifying the pipeline without burning a version tag.

## Notes

- Builds are **ad-hoc signed only**. Testers must clear Gatekeeper on first launch
  (right-click → Open). The release notes say so automatically.
- Artifacts live only on the Releases page — never committed (see `.gitignore`).
- When an Apple Developer account lands, extend this same workflow with the Phase B
  sign → notarize → staple steps (secrets go in GitHub Actions secrets). See
  [DISTRIBUTION.md](DISTRIBUTION.md).
