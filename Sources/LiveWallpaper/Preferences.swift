import AppKit
import ServiceManagement
import os

/// What the wallpaper should do while on battery.
enum BatteryBehavior: String, CaseIterable, Codable, Sendable {
    case pause      // stop rendering entirely
    case throttle   // cap at 30fps
    case full       // ignore battery, keep full rate

    var label: String {
        switch self {
        case .pause: return "Pause"
        case .throttle: return "Throttle (30fps)"
        case .full: return "Keep full rate"
        }
    }
}

/// App-level settings, persisted in UserDefaults. `onChange` fires after any mutation so the
/// Governor / rotation timer / login item can react.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let log = Logger(subsystem: "com.livewallpaper.app", category: "Preferences")
    private let d = UserDefaults.standard

    /// Called after any setting changes.
    var onChange: (() -> Void)?

    @Published var launchAtLogin: Bool { didSet { applyLoginItem(); persist() } }
    @Published var batteryBehavior: BatteryBehavior { didSet { persist(); onChange?() } }
    @Published var rotationEnabled: Bool { didSet { persist(); onChange?() } }
    @Published var rotationMinutes: Int { didSet { persist(); onChange?() } }
    @Published var checkForUpdatesAutomatically: Bool { didSet { persist() } }
    /// Paint a neutral solid colour as the macOS desktop picture so the user never glimpses their
    /// own wallpaper behind/around our window. Default on; restores the original when turned off.
    @Published var solidBackdrop: Bool { didSet { persist(); onChange?() } }
    /// Whether the first-run onboarding walkthrough has been seen. Set once it's dismissed (any way);
    /// gates the launch-time presentation so it never re-nags. Re-runnable from Settings regardless.
    @Published var hasCompletedOnboarding: Bool { didSet { persist() } }
    /// Time-of-day wallpaper schedule (Premium). When enabled, the app switches wallpapers at each
    /// entry's time. Independent of rotation — both can run.
    @Published var scheduleEnabled: Bool { didSet { persist(); onChange?() } }
    @Published var scheduleEntries: [ScheduleEntry] { didSet { persistSchedule(); onChange?() } }

    private init() {
        launchAtLogin = d.bool(forKey: "launchAtLogin")
        batteryBehavior = BatteryBehavior(rawValue: d.string(forKey: "batteryBehavior") ?? "") ?? .throttle
        rotationEnabled = d.bool(forKey: "rotationEnabled")
        rotationMinutes = max(1, d.object(forKey: "rotationMinutes") as? Int ?? 15)
        // Default on: opt-out, not opt-in — testers should hear about new builds by default.
        checkForUpdatesAutomatically = d.object(forKey: "checkForUpdatesAutomatically") as? Bool ?? true
        solidBackdrop = d.object(forKey: "solidBackdrop") as? Bool ?? true
        hasCompletedOnboarding = d.bool(forKey: Onboarding.completedKey)
        scheduleEnabled = d.bool(forKey: "scheduleEnabled")
        scheduleEntries = Self.loadSchedule(d)
        // Reconcile the actual login-item state with the stored preference on launch.
        syncLoginItemState()
    }

    private func persist() {
        d.set(launchAtLogin, forKey: "launchAtLogin")
        d.set(batteryBehavior.rawValue, forKey: "batteryBehavior")
        d.set(rotationEnabled, forKey: "rotationEnabled")
        d.set(rotationMinutes, forKey: "rotationMinutes")
        d.set(checkForUpdatesAutomatically, forKey: "checkForUpdatesAutomatically")
        d.set(solidBackdrop, forKey: "solidBackdrop")
        d.set(hasCompletedOnboarding, forKey: Onboarding.completedKey)
        d.set(scheduleEnabled, forKey: "scheduleEnabled")
    }

    private func persistSchedule() {
        if let data = try? JSONEncoder().encode(scheduleEntries) {
            d.set(data, forKey: "scheduleEntries")
        }
    }

    private static func loadSchedule(_ d: UserDefaults) -> [ScheduleEntry] {
        guard let data = d.data(forKey: "scheduleEntries"),
              let arr = try? JSONDecoder().decode([ScheduleEntry].self, from: data) else { return [] }
        return arr
    }

    // MARK: - Launch at login (SMAppService)

    private func applyLoginItem() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            log.notice("Login item \(self.launchAtLogin ? "registered" : "unregistered", privacy: .public).")
        } catch {
            log.error("Login item update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// If the system already has us enabled/disabled differently, trust the system state.
    private func syncLoginItemState() {
        let enabled = SMAppService.mainApp.status == .enabled
        if enabled != launchAtLogin { launchAtLogin = enabled }
    }
}
