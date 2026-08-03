import CoreGraphics

/// Explicit "is the wallpaper actually visible right now?" check, complementing `NSWindow`
/// occlusion. Our desktop windows use `.canJoinAllSpaces`, so `isOnActiveSpace` is always true and
/// occlusion is the only per-window signal — and it can lag on Space switches (entering a full-screen
/// app). This reads the on-screen window list and asks a simpler question: is every screen fully
/// covered by some normal app window that isn't ours? If so, nothing of the wallpaper shows → pause.
///
/// A full-screen app, a maximized window, or any window that blankets a whole display all count —
/// which is exactly right, since in every case the wallpaper is invisible there. The geometry is
/// kept pure here so it can be unit-tested without a live window server.
enum FullscreenCoverage {
    /// True iff *every* screen rect is fully covered by at least one window rect. All rects must be in
    /// the same coordinate space (the gatherer uses CoreGraphics global coords for both). `tolerance`
    /// shrinks each screen slightly so sub-point rounding doesn't read a real full cover as a miss.
    /// Empty screens ⇒ false (nothing to cover, so never "all covered").
    static func allScreensCovered(screens: [CGRect], windows: [CGRect], tolerance: CGFloat = 2) -> Bool {
        guard !screens.isEmpty else { return false }
        return screens.allSatisfy { screen in
            let target = screen.insetBy(dx: tolerance, dy: tolerance)
            return windows.contains { $0.contains(target) }
        }
    }
}
