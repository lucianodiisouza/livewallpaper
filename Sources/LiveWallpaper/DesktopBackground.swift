import AppKit
import os

/// Paints a neutral solid colour as the macOS **system** desktop picture on every screen, so the
/// user never glimpses their own wallpaper behind or around our desktop-level window — at the
/// edges, during Spaces/Mission Control transitions, or in the moment before our window mounts.
///
/// It captures the user's real desktop picture per screen the first time it overrides one, and
/// puts it back on `restore()` (app quit or the preference being turned off). All best-effort:
/// under the App Sandbox `setDesktopImageURL` may be refused — we log and carry on rather than fail.
@MainActor
enum DesktopBackground {

    private static let log = Logger(subsystem: "com.livewallpaper.app", category: "DesktopBackground")
    private static let d = UserDefaults.standard
    private static let originalsKey = "desktopOriginalsByScreen"

    /// A neutral dark backdrop that blends with our black desktop window.
    static let color = NSColor(white: 0.10, alpha: 1)

    /// Override every screen's desktop picture with the solid colour, remembering the originals.
    static func apply() {
        guard let url = solidImageURL() else { return }
        var originals = d.dictionary(forKey: originalsKey) as? [String: String] ?? [:]
        for screen in NSScreen.screens {
            let key = Library.key(for: screen)
            // Remember the user's real wallpaper the first time we override this screen (never
            // record our own solid image as the "original").
            if let current = NSWorkspace.shared.desktopImageURL(for: screen), current != url,
               originals[key] == nil {
                originals[key] = current.path
            }
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            } catch {
                log.error("Solid backdrop refused on \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        d.set(originals, forKey: originalsKey)
    }

    /// Put back each screen's captured original desktop picture (if we still have it).
    static func restore() {
        guard let originals = d.dictionary(forKey: originalsKey) as? [String: String], !originals.isEmpty else { return }
        for screen in NSScreen.screens {
            guard let path = originals[Library.key(for: screen)],
                  FileManager.default.fileExists(atPath: path) else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:])
        }
        d.removeObject(forKey: originalsKey)
    }

    // MARK: - Solid image

    /// A tiny solid-colour PNG in our container, generated once and reused.
    private static func solidImageURL() -> URL? {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("LiveWallpaper", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("backdrop.png")
        if fm.fileExists(atPath: url.path) { return url }

        let size = NSSize(width: 64, height: 64)
        let img = NSImage(size: size)
        img.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        try? png.write(to: url)
        return fm.fileExists(atPath: url.path) ? url : nil
    }
}
