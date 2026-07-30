import AppKit

// LiveWallpaper — M0 illusion spike.
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// .accessory == LSUIElement at runtime: no Dock icon, no menu bar, lives in the status bar.
app.setActivationPolicy(.accessory)
app.run()
