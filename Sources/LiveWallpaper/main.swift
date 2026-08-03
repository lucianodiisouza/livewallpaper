import AppKit

// Primo Engine — M0 illusion spike.
// A menu-bar (accessory) app that paints an animated wallpaper into a desktop-level
// window on every screen, and pauses rendering whenever nothing can be seen.
//
// The whole point of M0 is to prove two things on real hardware:
//   1. A borderless window slotted at `.desktopWindow` level shows above the OS wallpaper
//      but below the Finder icons — and keeps working under sandboxing.
//   2. The Governor drives that render to ~0% GPU whenever the window is covered, on battery, etc.

// Headless package-pipeline check: `LiveWallpaper --selftest` (no GUI, no desktop window).
if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run())
}

// Generate an importable sample package: `LiveWallpaper --make-sample <path.livewallpaper>`.
// Compile-checks the shader first so the emitted package is guaranteed to render.
if let i = CommandLine.arguments.firstIndex(of: "--make-sample"), i + 1 < CommandLine.arguments.count {
    exit(SampleMaker.run(path: CommandLine.arguments[i + 1]))
}

// Export a built-in as a package (for workshop seeding): `--export <id> <path.livewallpaper>`.
if let i = CommandLine.arguments.firstIndex(of: "--export"), i + 2 < CommandLine.arguments.count {
    exit(SampleMaker.export(id: CommandLine.arguments[i + 1], path: CommandLine.arguments[i + 2]))
}

// Export the full workshop inventory at once: `--export-batch <dir>`.
if let i = CommandLine.arguments.firstIndex(of: "--export-batch"), i + 1 < CommandLine.arguments.count {
    exit(SampleMaker.batchExport(dir: CommandLine.arguments[i + 1]))
}

// Render 1024px PNG previews for every package in a folder: `--render-thumbs <in> <out>`.
if let i = CommandLine.arguments.firstIndex(of: "--render-thumbs"), i + 2 < CommandLine.arguments.count {
    exit(SampleMaker.renderThumbs(inDir: CommandLine.arguments[i + 1], outDir: CommandLine.arguments[i + 2]))
}

// Verify the workshop catalog is reachable: `--workshop-smoke` (no GUI).
if CommandLine.arguments.contains("--workshop-smoke") {
    exit(WorkshopSmoke.run())
}

// Check GitHub for a newer release, print current vs latest: `--check-updates` (no GUI).
if CommandLine.arguments.contains("--check-updates") {
    exit(UpdateCheckSmoke.run())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// .accessory == LSUIElement at runtime: no Dock icon, no menu bar, lives in the status bar.
app.setActivationPolicy(.accessory)
app.run()
