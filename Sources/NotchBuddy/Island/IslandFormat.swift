import Foundation
import NotchBuddyCore

/// Russian short-form durations for the island ("12 с", "5 мин", "2 ч 10 мин", "3 д 4 ч").
enum IslandFormat {
    private static let nbsp = "\u{00A0}"

    static func duration(_ interval: TimeInterval) -> String {
        // Clamped before converting: `Int(_:)` traps on NaN/∞ and past Int.max (a reset time is another tool's number).
        let seconds = interval.isFinite ? Int(min(max(interval, 0), 1e12)) : 0
        if seconds < 60 { return L("%@\u{00A0}с", seconds) }
        let minutes = seconds / 60
        if minutes < 60 { return L("%@\u{00A0}мин", minutes) }
        let hours = minutes / 60, restMinutes = minutes % 60
        if hours < 24 {
            return restMinutes == 0 ? L("%@\u{00A0}ч", hours) : L("%@\u{00A0}ч %@\u{00A0}мин", hours, restMinutes)
        }
        let days = hours / 24, restHours = hours % 24
        return restHours == 0 ? L("%@\u{00A0}д", days) : L("%@\u{00A0}д %@\u{00A0}ч", days, restHours)
    }

    /// "сброс через 2 ч 10 мин"; nil when the reset time is unknown.
    static func reset(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let left = date.timeIntervalSince(now)
        if left < 60 { return L("сброс меньше чем через минуту") }
        // Round up so "59 с" reads as "1 мин", not "0 мин".
        return L("сброс через %@", duration(left + 59))
    }

    /// Running clock for a live status: "0:07", "2:14", "1:02:03".
    static func clock(_ interval: TimeInterval) -> String {
        let seconds = interval.isFinite ? Int(min(max(interval, 0), 1e9)) : 0
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Elapsed time of a session's current status: a running clock while it works or waits,
    /// "5 мин назад" once it has stopped.
    static func elapsed(_ status: SessionStatus, since: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(since)
        if status.runsClock { return clock(interval) }
        return interval < 60 ? L("только что") : L("%@ назад", duration(interval))
    }

    /// Localized plural, by its Russian forms: plural(2, "сессия", "сессии", "сессий") → "сессии" / "…s" (key "сессия|сессии|сессий", see `Lp`).
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        Lp(n, one, few, many)
    }

    static func percent(_ utilization: Double) -> String {
        "\(percentValue(utilization))%"
    }

    /// Whole percent, 0...100; never traps on NaN/∞.
    static func percentValue(_ utilization: Double) -> Int {
        utilization.isFinite ? Int(min(max(utilization, 0), 100).rounded()) : 0
    }
}
