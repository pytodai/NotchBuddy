import Foundation

/// The calendar widget's wording, localized: "через 7 мин" / "in 7 min", "14:00–15:00", "среда, 30 сентября" /
/// "Wednesday, September 30".
/// Units are joined with non-breaking spaces so "7 мин" never wraps apart.
public struct CalendarFormat: Sendable {
    public let calendar: Calendar
    private static let nbsp = "\u{00A0}"
    private let formatters = FormatterCache()

    /// `.autoupdatingCurrent` follows time-zone changes.
    public init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    /// Russian keeps the exact pattern ("d MMMM" → "30 сентября"); English orders it the English way
    /// ("September 30").
    private func formatter(_ template: String) -> DateFormatter {
        let language = L10n.shared.language
        return formatters.formatter("\(language.rawValue):\(template)", timeZone: calendar.timeZone) {
            let f = DateFormatter()
            f.locale = language.locale
            f.calendar = calendar
            if language == .ru {
                f.dateFormat = template
            } else {
                // "EEEEEE" is "Th" in English; "Thu" reads better.
                f.setLocalizedDateFormatFromTemplate(template.replacingOccurrences(of: "EEEEEE", with: "EEE"))
            }
            return f
        }
    }

    /// "9:05", "14:30".
    public func time(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "14:00–15:00"; a zero-length event is just its start.
    public func range(_ event: CalendarEvent) -> String {
        event.end > event.start ? "\(time(event.start))–\(time(event.end))" : time(event.start)
    }

    /// "среда, 30 сентября".
    public func weekdayAndDate(_ date: Date) -> String { formatter("EEEE, d MMMM").string(from: date) }

    /// "чт, 1 октября".
    public func shortWeekdayAndDate(_ date: Date) -> String {
        formatter("EEEEEE, d MMMM").string(from: date)
    }

    /// "Среда".
    public func weekday(_ date: Date) -> String { formatter("EEEE").string(from: date).capitalizedFirst }

    /// "7 мин", "1 ч 5 мин", "2 ч" — whole minutes, rounded up (never "0 мин" before a start).
    public static func span(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((max(seconds, 0) / 60).rounded(.up)))
        if minutes < 60 { return L("%@\u{00A0}мин", minutes) }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? L("%@\u{00A0}ч", hours) : L("%@\u{00A0}ч %@\u{00A0}мин", hours, rest)
    }

    /// Compact form for tight spots (the notch wing): "7 мин", "2 ч", "2,5 ч".
    public static func compactSpan(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((max(seconds, 0) / 60).rounded(.up)))
        if minutes < 60 { return L("%@\u{00A0}мин", minutes) }
        let halves = Int((Double(minutes) / 30).rounded())
        return halves % 2 == 0 ? L("%@\u{00A0}ч", halves / 2) : L("%@,5\u{00A0}ч", halves / 2)
    }

    /// Until an event starts: "через 7 мин", "через 1 ч 30 мин"; from tomorrow on "завтра в 10:00";
    /// under half a minute "сейчас".
    public func countdown(to start: Date, now: Date) -> String {
        let left = start.timeIntervalSince(now)
        if left < 30 { return L("сейчас") }
        let startDay = calendar.startOfDay(for: start)
        let today = calendar.startOfDay(for: now)
        if startDay > today, left >= 6 * 3600 {
            let days = calendar.dateComponents([.day], from: today, to: startDay).day ?? 1
            let prefix = days == 1 ? L("завтра") : shortWeekdayAndDate(start)
            return L("%@ в\u{00A0}%@", prefix, time(start))
        }
        return L("через\u{00A0}%@", Self.span(left))
    }

    /// While an event runs: "ещё 25 мин"; in its last half minute "заканчивается".
    public func remaining(until end: Date, now: Date) -> String {
        let left = end.timeIntervalSince(now)
        return left < 30 ? L("заканчивается") : L("ещё\u{00A0}%@", Self.span(left))
    }

    /// Localized plural, by its Russian forms: plural(2, "встреча", "встречи", "встреч") → "встречи" / "…s" (key "встреча|встречи|встреч", see `Lp`).
    public static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        Lp(n, one, few, many)
    }

    /// "3 встречи".
    public static func meetings(_ n: Int) -> String { "\(n)\(nbsp)\(plural(n, "встреча", "встречи", "встреч"))" }
}

/// Date formatters are costly to make: one per template, its time zone brought up to date on every use
/// (an autoupdating calendar follows the Mac's zone).
private final class FormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var formatters: [String: DateFormatter] = [:]

    func formatter(_ template: String, timeZone: TimeZone, make: () -> DateFormatter) -> DateFormatter {
        lock.withLock {
            let f = formatters[template] ?? make()
            formatters[template] = f
            if f.timeZone != timeZone { f.timeZone = timeZone }
            return f
        }
    }
}

fileprivate extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
