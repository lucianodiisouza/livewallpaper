import AppKit

/// A borderless, click-through window pinned to one screen at desktop level.
///
/// Level `.desktopWindow` places it *above* the static OS wallpaper but *below* the desktop
/// icons, so Finder icons stay visible and clickable (`ignoresMouseEvents` lets clicks fall
/// through). This is the core of the "animated wallpaper" illusion — there is no public API for
/// it, so this window trick is how every app in this space does it.
final class DesktopWindow: NSWindow {

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.ignoresMouseEvents = true
        self.isOpaque = true
        self.hasShadow = false
        self.backgroundColor = .black
        self.isReleasedWhenClosed = false

        // A layer-backed content view gives renderers a CALayer to draw into.
        let view = NSView(frame: screen.frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        self.contentView = view

        setFrame(screen.frame, display: true)
    }

    /// The layer renderers attach their content to.
    var renderLayer: CALayer? { contentView?.layer }
}
