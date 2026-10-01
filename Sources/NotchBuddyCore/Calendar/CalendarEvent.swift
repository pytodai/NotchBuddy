import Foundation

/// A calendar color as sRGB components (0...1), so the model stays free of AppKit.
public struct CalendarRGB: Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Apple Calendar's default blue.
    public static let fallback = CalendarRGB(red: 0.20, green: 0.55, blue: 1.0)
}

/// One occurrence of a calendar event, copied out of EventKit (or made up for previews and tests).
public struct CalendarEvent: Equatable, Hashable, Identifiable, Sendable {
    /// Unique per occurrence: EventKit gives every occurrence of a repeating event the same identifier.
    public var id: String
    /// `EKEvent.eventIdentifier` (opens the event in Calendar); nil for made-up events.
    public var eventIdentifier: String?
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendarID: String
    public var calendarTitle: String
    public var color: CalendarRGB
    public var location: String?
    public var meeting: MeetingLink?

    public init(id: String, eventIdentifier: String? = nil, title: String, start: Date, end: Date,
                isAllDay: Bool = false, calendarID: String = "default", calendarTitle: String = "",
                color: CalendarRGB = .fallback, location: String? = nil, meeting: MeetingLink? = nil) {
        self.id = id
        self.eventIdentifier = eventIdentifier
        self.title = title
        self.start = start
        self.end = max(end, start)
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.color = color
        self.location = location
        self.meeting = meeting
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// The title to show ("Без названия" for an empty one).
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L("Без названия") : trimmed
    }

    /// Where it happens, when that is a place rather than the call link itself.
    public var displayLocation: String? {
        guard let location = location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty else { return nil }
        if let meeting, location.contains(meeting.url.host ?? "\u{0}") { return nil }
        if location.lowercased().hasPrefix("http://") || location.lowercased().hasPrefix("https://") { return nil }
        // Multi-line addresses read best on one line.
        return location.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

/// A calendar the user can show or hide (settings).
public struct CalendarSource: Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// The account it belongs to ("iCloud", "Google", "На Mac").
    public var account: String
    public var color: CalendarRGB

    public init(id: String, title: String, account: String, color: CalendarRGB) {
        self.id = id
        self.title = title
        self.account = account
        self.color = color
    }
}
