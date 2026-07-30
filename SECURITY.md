# Security Policy

LiveWallpaper runs animated content on the desktop — and eventually **community-contributed
content**, which is untrusted by design. Security is a first-class concern, not a bolt-on.

## The threat model in one line

Community wallpapers are strangers' code executing on users' Macs. Every content medium runs in
the tightest sandbox it allows. See [DESIGN.md](DESIGN.md) §7 for the full model. Summary:

| Type | Containment |
|---|---|
| **video** | Inert media, decoded by OS codecs. Lowest risk. |
| **metal** | Fragment shaders only — no compute, no buffer writes. Cannot reach filesystem, network, or memory outside its pipeline. Enforced at import. |
| **web** | `WKWebView` with JS caged: no `file://`, network blocked except a manifest allowlist, ephemeral data store, no camera/mic/geolocation, top-level navigation blocked. |

Manifest `capabilities` are **enforced by the client, never trusted**. A package that declares
no network access is *made* unable to reach the network.

## Supported versions

Pre-1.0: only the latest release is supported. Security fixes ship in the next release.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

- Use GitHub's **private vulnerability reporting** (Security → Report a vulnerability) on this
  repository, or
- email the maintainer (add contact here once the repo is public).

Include: affected version, reproduction steps, and — if it involves a malicious `.livewallpaper`
bundle — a sample bundle or the manifest, plus what escaped the intended sandbox.

We aim to acknowledge reports within a few days. Please give us reasonable time to ship a fix
before public disclosure.

## Especially valuable reports

- Any content that escapes its sandbox (a shader reaching outside its pipeline; a web wallpaper
  making a network call or touching the filesystem; a bundle running code the manifest didn't declare).
- Ways to make the desktop window capture input it shouldn't, or read other windows' contents.
- Checksum/signature bypasses in package verification.
