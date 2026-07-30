import AppKit

/// Everything the desktop window can display sits behind this protocol, so the window and the
/// Governor never care whether the content is video, a Metal shader, or a web view.
///
/// Load-bearing rule (see CLAUDE.md): a renderer must never run frames on its own clock — it
/// obeys the Governor's directive via `apply(directive:)`. `setFrameRate` exists for renderers
/// that can throttle (Metal/web); video mostly toggles play/pause.
@MainActor
protocol WallpaperRenderer: AnyObject {
    /// Attach content to `layer` and begin (respecting the initial directive applied afterward).
    func start(in layer: CALayer)
    func pause()
    func resume()
    func setFrameRate(_ fps: Int)
    func stop()
}

extension WallpaperRenderer {
    /// Convenience: translate a Governor directive into renderer calls.
    func apply(_ directive: RenderDirective) {
        if directive.paused {
            pause()
        } else {
            resume()
            setFrameRate(directive.fps)
        }
    }
}
