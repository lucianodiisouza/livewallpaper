import Foundation

/// One entry in the daily wallpaper schedule: at `hour:minute`, switch to `wallpaperID`. The
/// schedule is a repeating daily program (not calendar dates) — the simplest model that covers
/// "morning / afternoon / night" looks. Premium, like rotation.
struct ScheduleEntry: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var hour: Int          // 0–23
    var minute: Int        // 0–59
    var wallpaperID: String

    var minutesOfDay: Int { hour * 60 + minute }
}

/// Pure schedule resolution, kept separate from timers/UI so it's unit-testable.
enum WallpaperScheduleLogic {
    /// The wallpaper id that should be active at `minutesNow` given `entries`. Picks the latest entry
    /// at or before now; if every entry is still later today, it wraps to the last entry of the day
    /// (which has been showing since yesterday). Returns nil for an empty schedule.
    static func activeWallpaperID(entries: [ScheduleEntry], minutesNow: Int) -> String? {
        guard !entries.isEmpty else { return nil }
        let sorted = entries.sorted { $0.minutesOfDay < $1.minutesOfDay }
        let due = sorted.last { $0.minutesOfDay <= minutesNow }
        return (due ?? sorted.last)?.wallpaperID
    }

    /// Minutes-since-midnight for a date, in the current calendar.
    static func minutesOfDay(for date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
