import AppKit
import EventKit
import NotchBuddyCore
import Observation

/// Today's and tomorrow's events from EventKit, for the calendar widget and the "meeting soon" live
/// activity.
///
/// - Access is asked for only when the user clicks "Подключить календарь" (`requestAccess`); until then
///   nothing touches EventKit beyond reading the authorization status.
/// - Events are fetched off the main thread and refetched on `EKEventStoreChanged` (coalesced), at
///   midnight, on clock / time-zone changes and after sleep.
/// - `now` advances once a minute (on whole minutes) only while a view that shows times is on screen
///   (`beginTicking` / `endTicking`, done by the views themselves). Otherwise a single one-shot timer wakes
///   the service at the next moment `imminent` can change (an event entering its lead time or leaving
///   its tail), so the live activity appears on time with no polling.
/// - Titles, places and notes are never logged.
@Observable
@MainActor
final class CalendarService {
    enum Access: Equatable {
        case notDetermined, denied, restricted, writeOnly, granted
    }

    let preferences: CalendarPreferences
    private(set) var access: Access
    /// Every fetched occurrence of today and tomorrow (hidden calendars included; see `visibleEvents`).
    private(set) var events: [CalendarEvent] = []
    /// The user's event calendars (settings).
    private(set) var calendars: [CalendarSource] = []
    /// The first fetch after access was granted has finished.
    private(set) var loaded = false
    /// The system access prompt is up.
    private(set) var requesting = false
    /// The widget's notion of now: whole minutes while ticking, else the last wake-up.
    private(set) var now: Date

    @ObservationIgnored private let live: Bool
    @ObservationIgnored private var store: EKEventStore?
    @ObservationIgnored private var storeObserver: NSObjectProtocol?
    @ObservationIgnored private var systemObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var boundaryTimer: Timer?
    @ObservationIgnored private var tickDemand = 0
    @ObservationIgnored private var fetchGeneration = 0
    @ObservationIgnored private var reloadPending = false
    @ObservationIgnored private var askedUpgrade = false
    @ObservationIgnored private let queue = DispatchQueue(label: "me.sokolov.notchbuddy.calendar", qos: .userInitiated)

    init(preferences: CalendarPreferences? = nil) {
        self.preferences = preferences ?? CalendarPreferences()
        live = true
        now = Date()
        access = Self.systemAccess()
        observeSystem()
        observePreferences()
        if access == .granted { openStore() }
    }

    /// Fixed data for previews: no EventKit, no timers.
    init(previewAccess access: Access, events: [CalendarEvent], calendars: [CalendarSource] = [], now: Date,
         loaded: Bool = true, requesting: Bool = false, preferences: CalendarPreferences) {
        self.preferences = preferences
        live = false
        self.requesting = requesting
        self.access = access
        self.events = events
        self.calendars = calendars
        self.now = now
        self.loaded = loaded
    }

    // MARK: What the views show

    var visibleEvents: [CalendarEvent] {
        let hidden = preferences.hiddenCalendarIDs
        return hidden.isEmpty ? events : events.filter { !hidden.contains($0.calendarID) }
    }

    var agenda: CalendarAgenda {
        CalendarAgenda(events: visibleEvents, now: now, includeTomorrow: preferences.showsTomorrow,
                       lead: preferences.lead)
    }

    /// The meeting the closed island counts down to: it starts within the lead time (or has just started).
    /// Nil without access or with the live activity switched off.
    var imminent: CalendarEvent? {
        guard access == .granted, preferences.liveActivity else { return nil }
        // Soon is soon even across midnight, whatever the widget shows.
        return CalendarAgenda(events: visibleEvents, now: now, includeTomorrow: true, lead: preferences.lead).imminent
    }

    // MARK: Access

    static func systemAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// The user clicked "Подключить календарь": asks macOS for full access the first time (and once to
    /// upgrade add-only access), otherwise opens the Calendars pane of Privacy & Security (a denial can
    /// only be undone there).
    func requestAccess() {
        guard live, !requesting else { return }
        let mayAsk = access == .notDetermined || (access == .writeOnly && !askedUpgrade)
        guard mayAsk else {
            openPrivacySettings()
            return
        }
        // Without the usage description (a bare `swift run` binary) macOS would kill the app on the request.
        guard Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil else {
            Log.error("calendar: no NSCalendarsFullAccessUsageDescription in Info.plist; not asking for access")
            return
        }
        if access == .writeOnly { askedUpgrade = true }
        requesting = true
        // Stores are costly: the one that asks becomes the one that reads.
        let store = self.store ?? EKEventStore()
        self.store = store
        Task { @MainActor in
            do {
                let granted = try await store.requestFullAccessToEvents()
                Log.info("calendar: access \(granted ? "granted" : "not granted")")
            } catch {
                Log.error("calendar: access request failed: \(error.localizedDescription)")
            }
            requesting = false
            refreshAccess()
        }
    }

    /// Reads the authorization status again (the user may have changed it in System Settings).
    func refreshAccess() {
        guard live else { return }
        let current = Self.systemAccess()
        guard current != access else { return }
        access = current
        if current == .granted {
            openStore()
        } else {
            closeStore()
        }
    }

    func openPrivacySettings() {
        guard live else { return }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Actions

    /// Opens the event's call link (only https links on known call services ever get here).
    func join(_ event: CalendarEvent) {
        guard live, let url = event.meeting?.url, url.scheme?.lowercased() == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    /// Shows the event in Calendar (or at least opens Calendar).
    func reveal(_ event: CalendarEvent) {
        guard live else { return }
        if let id = event.eventIdentifier,
           let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more"),
           NSWorkspace.shared.open(url) {
            return
        }
        openCalendarApp()
    }

    func openCalendarApp() {
        guard live, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Minute ticks

    /// A view that shows times appeared: `now` advances on every whole minute until the last one leaves.
    func beginTicking() {
        tickDemand += 1
        guard live, tickDemand == 1 else { return }
        refreshAccess()
        now = Date()
        let next = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 + 60)
        let timer = Timer(fire: next, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func endTicking() {
        tickDemand = max(0, tickDemand - 1)
        guard tickDemand == 0 else { return }
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: Store

    private func openStore() {
        guard live else { return }
        if storeObserver == nil {
            let store = self.store ?? EKEventStore()
            self.store = store
            storeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReload() }
            }
        }
        reload()
    }

    private func closeStore() {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = nil
        store = nil
        fetchGeneration += 1
        events = []
        calendars = []
        loaded = false
        boundaryTimer?.invalidate()
        boundaryTimer = nil
    }

    /// Store changes come in bursts (a sync touches many events): one fetch per 0.3 s.
    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadPending = false
                self.reload()
            }
        }
    }

    private func reload() {
        guard let store, access == .granted else { return }
        fetchGeneration += 1
        let generation = fetchGeneration
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 2, to: start) ?? start.addingTimeInterval(2 * 86_400)
        let box = StoreBox(store: store)
        queue.async {
            let result = Self.fetch(box.store, from: start, to: end)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, generation == self.fetchGeneration else { return }
                    if self.events != result.events { self.events = result.events }
                    if self.calendars != result.calendars { self.calendars = result.calendars }
                    self.loaded = true
                    self.now = Date()
                    self.armBoundary()
                    Log.debug("calendar: \(result.events.count) events, \(result.calendars.count) calendars")
                }
            }
        }
    }

    private final class StoreBox: @unchecked Sendable {
        let store: EKEventStore
        init(store: EKEventStore) { self.store = store }
    }

    nonisolated private static func fetch(_ store: EKEventStore, from start: Date,
                                          to end: Date) -> (events: [CalendarEvent], calendars: [CalendarSource]) {
        let calendars = store.calendars(for: .event)
            .map { CalendarSource(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "",
                                  color: rgb($0.color)) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).compactMap(convert)
        return (events, calendars)
    }

    nonisolated private static func convert(_ event: EKEvent) -> CalendarEvent? {
        guard let start = event.startDate, let end = event.endDate, event.status != .canceled else { return nil }
        // Invitations the user declined are not on their day.
        if let me = event.attendees?.first(where: { $0.isCurrentUser }), me.participantStatus == .declined { return nil }
        let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        return CalendarEvent(
            id: "\(identifier)@\(Int(start.timeIntervalSince1970))",
            eventIdentifier: event.eventIdentifier,
            title: event.title ?? "",
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            calendarID: event.calendar?.calendarIdentifier ?? "",
            calendarTitle: event.calendar?.title ?? "",
            color: rgb(event.calendar?.color),
            location: event.location,
            meeting: MeetingLinkDetector.detect(url: event.url?.absoluteString, location: event.location,
                                                notes: event.notes))
    }

    nonisolated private static func rgb(_ color: NSColor?) -> CalendarRGB {
        guard let srgb = color?.usingColorSpace(.sRGB) else { return .fallback }
        return CalendarRGB(red: Double(srgb.redComponent), green: Double(srgb.greenComponent),
                           blue: Double(srgb.blueComponent))
    }

    // MARK: Wake-ups

    /// One timer at the next moment the imminent meeting (or what is on now) can change.
    private func armBoundary() {
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        guard live, access == .granted,
              let at = CalendarAgenda.nextBoundary(events: visibleEvents, after: Date(), lead: preferences.lead) else { return }
        // Timers never fire early; a hair late makes "starts within 10 min" true when it fires.
        let timer = Timer(fire: at.addingTimeInterval(0.05), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.now = Date()
                self?.armBoundary()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        boundaryTimer = timer
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            systemObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.now = Date()
                    self?.reload()
                }
            })
        }
        systemObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.now = Date()
                self.refreshAccess()
                // Remote calendars may have changed while asleep (the store posts a change if they did).
                if let store = self.store, self.access == .granted {
                    let box = StoreBox(store: store)
                    self.queue.async { box.store.refreshSourcesIfNecessary() }
                }
                self.reload()
            }
        })
    }

    /// A changed lead time or calendar selection moves the next wake-up.
    private func observePreferences() {
        withObservationTracking {
            _ = preferences.leadMinutes
            _ = preferences.hiddenCalendarIDs
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.armBoundary()
                self?.observePreferences()
            }
        }
    }
}
