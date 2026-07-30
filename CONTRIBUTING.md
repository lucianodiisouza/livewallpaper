# Contributing to LiveWallpaper

Thanks for your interest! This project is developed largely with AI assistance, so it leans
heavily on clear documentation to stay coherent. Please skim these before diving in:

- [CLAUDE.md](CLAUDE.md) — conventions, scope rules, and the decisions not to reverse
- [DESIGN.md](DESIGN.md) — architecture source of truth

## Ground rules

1. **Respect the phase split.** Phase 1 is the local engine; Phase 2 is the community backend.
   Don't add backend/moderation code until Phase 1 ships. See CLAUDE.md → "Scope discipline".
2. **Native only.** Swift + AppKit/SwiftUI/Metal/AVFoundation/WebKit. No Electron, no bundled
   browser. New third-party dependencies need justification in the PR.
3. **Never loosen a content sandbox** to make something work. Community content is untrusted by
   design (see [SECURITY.md](SECURITY.md)).
4. **Keep docs truthful.** If you change build steps, the package format, or the Governor's
   signals, update the relevant doc in the same PR.

## Workflow

1. Open an issue describing the change (bug or feature) before large work, so we agree on scope.
2. Branch from the default branch.
3. Keep PRs focused — one logical change each.
4. Make sure the app builds and runs; describe how you verified it (which macOS version,
   which monitors/spaces you tested against — the window-management matrix is where things break).
5. Reference the issue your PR closes.

## Commit style

- Short imperative subject lines ("Add MetalRenderer time uniform").
- Explain the *why* in the body when it isn't obvious.

## Reporting bugs

Use the issue templates. For anything security-related (especially around running community
content), follow [SECURITY.md](SECURITY.md) instead of filing a public issue.
