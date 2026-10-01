import Foundation
import Observation

/// The calendar widget's settings (⚙️ in the open island), kept in `UserDefaults`.
@Observable
@MainActor
final class CalendarPreferences {
    enum Key {
        static let showsTomorrow = "calendar.showsTomorrow"
        static let liveActivity = "calendar.liveActivity"
        static let leadMinutes = "calendar.leadMinutes"
        static let hiddenCalendars = "calendar.hiddenCalendarIDs"
    }

    /// Choices offered for "remind this long before".
    static let leadChoices = [5, 10, 15]

    @ObservationIgnored private let defaults: UserDefaults

    /// Tomorrow's events under today's.
    var showsTomorrow: Bool {
        didSet { defaults.set(showsTomorrow, forKey: Key.showsTomorrow) }
    }

    /// The closed island counts down to a meeting that starts soon.
    var liveActivity: Bool {
        didSet { defaults.set(liveActivity, forKey: Key.liveActivity) }
    }

    /// How long before a start the live activity appears.
    var leadMinutes: Int {
        didSet { defaults.set(leadMinutes, forKey: Key.leadMinutes) }
    }

    /// Calendars the user switched off (by `EKCalendar.calendarIdentifier`).
    var hiddenCalendarIDs: Set<String> {
        didSet { defaults.set(Array(hiddenCalendarIDs).sorted(), forKey: Key.hiddenCalendars) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsTomorrow = defaults.object(forKey: Key.showsTomorrow) as? Bool ?? true
        liveActivity = defaults.object(forKey: Key.liveActivity) as? Bool ?? true
        let lead = defaults.object(forKey: Key.leadMinutes) as? Int ?? 10
        leadMinutes = Self.leadChoices.contains(lead) ? lead : 10
        hiddenCalendarIDs = Set(defaults.stringArray(forKey: Key.hiddenCalendars) ?? [])
    }

    var lead: TimeInterval { TimeInterval(leadMinutes * 60) }

    func setCalendar(_ id: String, visible: Bool) {
        if visible { hiddenCalendarIDs.remove(id) } else { hiddenCalendarIDs.insert(id) }
    }
}
