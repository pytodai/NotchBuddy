import Foundation

/// What the calendar widget shows at a moment: today and tomorrow, what is on now, what comes next and
/// what starts soon. Pure (events + now + calendar in, values out), so it is tested without EventKit.
public struct CalendarAgenda: Equatable, Sendable {
    public enum DayKind: Equatable, Sendable { case today, tomorrow }

    public struct Day: Equatable, Sendable {
        public var kind: DayKind
        /// Midnight at the start of the day.
        public var date: Date
        public var allDay: [CalendarEvent]
        /// Timed events of the day still to come or going on now (today), by start.
        public var timed: [CalendarEvent]
        /// Today's timed events that are over.
        public var ended: Int
    }

    /// Before its start an event counts as "soon" this long (the island's live activity).
    public static let defaultLead: TimeInterval = 10 * 60
    /// …and it still counts as just started this long after.
    public static let defaultTail: TimeInterval = 2 * 60

    public let now: Date
    public let days: [Day]
    /// Timed events going on now; the most specific first (latest start, then earliest end).
    public let current: [CalendarEvent]
    /// The first timed event that has not started yet.
    public let next: CalendarEvent?
    /// Starts within `lead` or started less than `tail` ago (the earliest such event).
    public let imminent: CalendarEvent?
    public let lead: TimeInterval
    public let tail: TimeInterval

    public init(events: [CalendarEvent], now: Date, calendar: Calendar = .current, includeTomorrow: Bool = true,
                lead: TimeInterval = CalendarAgenda.defaultLead, tail: TimeInterval = CalendarAgenda.defaultTail) {
        self.now = now
        self.lead = lead
        self.tail = tail
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        let dayAfter = calendar.date(byAdding: .day, value: 1, to: tomorrow) ?? tomorrow.addingTimeInterval(86_400)
        let sorted = events.sorted(by: Self.chronological)
        let timed = sorted.filter { !$0.isAllDay }

        func overlaps(_ e: CalendarEvent, _ from: Date, _ to: Date) -> Bool {
            // A zero-length event occupies its start.
            e.end > e.start ? (e.start < to && e.end > from) : (e.start >= from && e.start < to)
        }

        let todayTimed = timed.filter { overlaps($0, today, tomorrow) }
        var days = [Day(kind: .today, date: today,
                        allDay: sorted.filter { $0.isAllDay && overlaps($0, today, tomorrow) },
                        timed: todayTimed.filter { $0.end > now || ($0.end == $0.start && $0.start >= now) },
                        ended: todayTimed.filter { !($0.end > now || ($0.end == $0.start && $0.start >= now)) }.count)]
        if includeTomorrow {
            days.append(Day(kind: .tomorrow, date: tomorrow,
                            allDay: sorted.filter { $0.isAllDay && overlaps($0, tomorrow, dayAfter) },
                            // Something already going on stays under today.
                            timed: timed.filter { $0.start >= tomorrow && $0.start < dayAfter },
                            ended: 0))
        }
        self.days = days

        let horizon = includeTomorrow ? dayAfter : tomorrow
        current = timed.filter { $0.start <= now && $0.end > now }
            .sorted { a, b in a.start != b.start ? a.start > b.start : (a.end != b.end ? a.end < b.end : a.id < b.id) }
        next = timed.first { $0.start > now && $0.start < horizon }
        imminent = timed.first { e in
            e.start < horizon && e.end > now && e.start - lead <= now && now < e.start + tail
        }
    }

    /// Today, then tomorrow, then the rest by start; all-day events first within a start.
    static func chronological(_ a: CalendarEvent, _ b: CalendarEvent) -> Bool {
        if a.start != b.start { return a.start < b.start }
        if a.isAllDay != b.isAllDay { return a.isAllDay }
        if a.end != b.end { return a.end < b.end }
        return a.id < b.id
    }

    public var today: Day { days[0] }
    public var tomorrow: Day? { days.count > 1 ? days[1] : nil }

    /// The event the widget puts first: the one going on, else the next one.
    public var hero: CalendarEvent? { current.first ?? next }

    /// Nothing timed or all-day left today, and nothing tomorrow either (when shown).
    public var isEmpty: Bool { days.allSatisfy { $0.allDay.isEmpty && $0.timed.isEmpty } }

    /// How far an event has run, 0...1.
    public func progress(of event: CalendarEvent) -> Double {
        guard event.duration > 0 else { return now >= event.start ? 1 : 0 }
        return min(max(now.timeIntervalSince(event.start) / event.duration, 0), 1)
    }

    /// Whether `event` starts within the lead time (or just started).
    public func isSoon(_ event: CalendarEvent) -> Bool {
        !event.isAllDay && event.start - lead <= now && now < event.start + tail && event.end > now
    }

    /// The next moment after `now` at which `imminent` can change (an event entering its lead time or
    /// leaving its tail), so a single timer can wake the app for it instead of ticking every minute.
    public static func nextBoundary(events: [CalendarEvent], after now: Date,
                                    lead: TimeInterval = defaultLead, tail: TimeInterval = defaultTail) -> Date? {
        var best: Date?
        for e in events where !e.isAllDay {
            for t in [e.start - lead, e.start + tail, e.end] where t > now {
                if best == nil || t < best! { best = t }
            }
        }
        return best
    }
}
