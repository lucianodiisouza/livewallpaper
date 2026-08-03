import AppKit
import IOKit.ps
import os

/// What the renderers should be doing right now.
struct RenderDirective: Equatable {
    var paused: Bool
    var fps: Int

    var description: String { paused ? "PAUSED" : "RUNNING @ \(fps)fps" }
}

/// The single source of truth for whether — and how fast — wallpapers render.
///
/// It OR-s together a set of signals (see CLAUDE.md §4 / DESIGN.md §4) into one directive and
/// notifies a listener on change. The headline signal is **occlusion**: when every wallpaper
/// window is covered, we pause and the GPU cost drops to ~0. Renderers must obey; they never run
/// frames on their own clock.
@MainActor
final class Governor {

    private let log = Logger(subsystem: "com.livewallpaper.app", category: "Governor")

    /// Called whenever the effective directive changes.
    var onChange: ((RenderDirective) -> Void)?

    // Signals ---------------------------------------------------------------
    private var anyWindowVisible = true   // occlusion: at least one wallpaper window on-screen
    private var fullscreenCoversAll = false // explicit: every screen covered by a non-Primo window
    private var screensAsleep = false
    private var locked = false
    private var onBattery = false
    private var lowPower = false
    private var thermal: ProcessInfo.ThermalState = .nominal

    private(set) var current = RenderDirective(paused: false, fps: 60)
    private var batteryTimer: Timer?

    func start() {
        refreshPowerState()
        wireNotifications()
        // Poll battery/AC periodically; the power-source notification below covers most changes,
        // but a timer catches anything the notification misses.
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPowerState() }
        }
        recompute()
    }

    /// Called by AppDelegate when window occlusion changes.
    func setAnyWindowVisible(_ visible: Bool) {
        guard anyWindowVisible != visible else { return }
        anyWindowVisible = visible
        recompute()
    }

    /// Re-evaluate the explicit full-screen-cover signal. AppDelegate calls this on active-Space and
    /// app-activation changes — the moments occlusion is slowest to report — so we pause promptly
    /// when a full-screen app takes over every display.
    func updateFullscreenCoverage() {
        let covered = Self.allScreensCoveredByForeignWindow()
        guard fullscreenCoversAll != covered else { return }
        fullscreenCoversAll = covered
        recompute()
    }

    /// Read the on-screen window list (public CoreGraphics API) and decide whether every display is
    /// fully covered by a normal window that isn't ours. Both screen and window rects come back in
    /// CoreGraphics global coordinates (`CGDisplayBounds` ↔ `kCGWindowBounds`), so no flipping.
    private static func allScreensCoveredByForeignWindow() -> Bool {
        let screens = NSScreen.screens.compactMap { s -> CGRect? in
            (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDisplayBounds(CGDirectDisplayID($0.uint32Value)) }
        }
        guard !screens.isEmpty else { return false }

        let mine = ProcessInfo.processInfo.processIdentifier
        let infos = (CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var windows: [CGRect] = []
        for w in infos {
            guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }   // normal app windows
            if (w[kCGWindowOwnerPID as String] as? Int32) == mine { continue }    // never ours
            if let bounds = w[kCGWindowBounds as String] as? [String: Any],
               let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
                windows.append(rect)
            }
        }
        return FullscreenCoverage.allScreensCovered(screens: screens, windows: windows)
    }

    // MARK: - Signal wiring

    private func wireNotifications() {
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(ws, NSWorkspace.screensDidWakeNotification)  { $0.screensAsleep = false }

        // Screen lock/unlock is only available via the distributed center.
        let dnc = DistributedNotificationCenter.default()
        observeName(dnc, "com.apple.screenIsLocked")   { $0.locked = true }
        observeName(dnc, "com.apple.screenIsUnlocked")  { $0.locked = false }

        let nc = NotificationCenter.default
        observe(nc, ProcessInfo.thermalStateDidChangeNotification) { $0.thermal = ProcessInfo.processInfo.thermalState }
        observe(nc, .NSProcessInfoPowerStateDidChange) { $0.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ apply: @escaping @MainActor @Sendable (Governor) -> Void) {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                apply(self)
                self.recompute()
            }
        }
    }

    private func observeName(_ center: DistributedNotificationCenter, _ raw: String, _ apply: @escaping @MainActor @Sendable (Governor) -> Void) {
        center.addObserver(forName: Notification.Name(raw), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                apply(self)
                self.recompute()
            }
        }
    }

    private func refreshPowerState() {
        onBattery = Self.isOnBattery()
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermal = ProcessInfo.processInfo.thermalState
        recompute()
    }

    // MARK: - Decision

    /// Recompute after a preference change (e.g. battery behavior).
    func preferencesChanged() { recompute() }

    private func recompute() {
        let behavior = Preferences.shared.batteryBehavior
        let batteryPause = onBattery && behavior == .pause
        let batteryThrottle = onBattery && behavior == .throttle

        let paused = !anyWindowVisible || fullscreenCoversAll || screensAsleep || locked
            || thermal == .critical || batteryPause
        let throttled = batteryThrottle || lowPower || thermal == .serious
        let fps = throttled ? 30 : 60
        let next = RenderDirective(paused: paused, fps: fps)

        guard next != current else { return }
        current = next
        log.notice("Directive → \(next.description, privacy: .public) [visible:\(self.anyWindowVisible) fullscreen:\(self.fullscreenCoversAll) sleep:\(self.screensAsleep) lock:\(self.locked) battery:\(self.onBattery) lowPower:\(self.lowPower)]")
        onChange?(next)
    }

    /// A short, human explanation of the current directive — why we're paused or throttled — for the
    /// energy panel. Mirrors the precedence in `recompute()`.
    var statusReason: String {
        if !anyWindowVisible { return "Paused — the desktop is covered" }
        if fullscreenCoversAll { return "Paused — a full-screen app is in front" }
        if screensAsleep { return "Paused — the display is asleep" }
        if locked { return "Paused — the screen is locked" }
        if thermal == .critical { return "Paused — the device is too hot" }
        if onBattery && Preferences.shared.batteryBehavior == .pause { return "Paused — on battery" }

        var reasons: [String] = []
        if onBattery && Preferences.shared.batteryBehavior == .throttle { reasons.append("on battery") }
        if lowPower { reasons.append("Low Power Mode") }
        if thermal == .serious { reasons.append("running warm") }
        if reasons.isEmpty { return "Running at full frame rate" }
        return "Throttled — " + reasons.joined(separator: ", ")
    }

    // MARK: - Battery

    private static func isOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let state = desc[kIOPSPowerSourceStateKey] as? String
            else { continue }
            return state == kIOPSBatteryPowerValue
        }
        return false
    }
}
