import AppKit
import SwiftUI
import NotchBuddyCore

/// `NotchBuddy --render-calendar <dir>`: draws the calendar widget, its live activity and its settings
/// with made-up events to PNGs (inside the island's silhouette, on a desktop-like backdrop), then exits.
/// No EventKit access, no timers. `calendar-sheet.png` puts every state on one page.
@MainActor
enum CalendarPreviewRenderer {
    nonisolated static let flag = "--render-calendar"

    nonisolated static func requestedDirectory(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        return index + 1 < arguments.count ? arguments[index + 1] : "build/calendar-previews"
    }

    static let floating = IslandMetrics(style: .floating, notchWidth: 0,
                                        barHeight: IslandMetrics.floatingBarHeight(menuBar: 30), menuBarHeight: 30)
    static let notched = IslandMetrics(style: .notch, notchWidth: 188, barHeight: 37, menuBarHeight: 37)
    static let listWidth: CGFloat = 492

    static func run(outputDirectory: String) -> Int32 {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot create \(directory.path): \(error)\n".utf8))
            return 1
        }
        NSApp.setActivationPolicy(.accessory)
        print("manrope: \(CalendarType.registerIfNeeded() ? "registered" : "missing (system font)")")
        // Reads the status only (never prompts): EventKit links and answers without an app bundle.
        print("eventkit access: \(CalendarService.systemAccess())")
        let fake = FakeCalendar()
        var failures = 0
        var sheet: [CGImage] = []

        func save(_ name: String, _ image: CGImage?, inSheet: Bool = true) {
            guard let image else {
                FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
                failures += 1
                return
            }
            if inSheet { sheet.append(image) }
            if !write(image, to: directory.appendingPathComponent("\(name).png")) { failures += 1 }
        }

        for scene in fake.widgetScenes() {
            save("widget-\(scene.name)", render(widget: scene.service, metrics: floating, hover: scene.hover))
        }
        save("widget-now-notch", render(widget: fake.service(.granted, at: fake.at(14, 23)), metrics: notched, hover: nil))
        for scene in fake.liveScenes() {
            save("live-\(scene.name)", render(live: scene.event, now: scene.now, metrics: scene.metrics))
        }
        save("live-countdown-strip", liveStrip(fake), inSheet: false)
        save("motion-open", openStrip(fake), inSheet: false)
        save("widget-soon-sheen", render(widget: fake.service(.granted, at: fake.at(15, 23)), metrics: floating, hover: nil,
                                         sheen: 0.35), inSheet: false)
        save("settings", render(settings: fake.service(.granted, at: fake.at(14, 23))))
        save("calendar-sheet", IslandPreviewRenderer.stitch(sheet, columns: 3, header: nil), inSheet: false)
        return failures == 0 ? 0 : 1
    }

    // MARK: Frames

    private static func image<V: View>(_ view: V) -> CGImage? {
        IslandPreviewRenderer.image(view.environment(\.islandStaticRender, true))
    }

    /// The open island with the widget in it, hanging from the top edge of a desktop.
    private static func render(widget service: CalendarService, metrics: IslandMetrics, hover: String?,
                               sheen: CGFloat? = nil, filmTime: Double? = nil) -> CGImage? {
        let notch = metrics.style == .notch
        let content = CalendarWidgetView(state: service.widgetState, notchWidth: notch ? metrics.notchWidth : 0,
                                         headerHeight: notch ? metrics.barHeight : 46, hoverOverride: hover)
            .padding(.top, notch ? 0 : 2)
            .frame(width: listWidth)
            .environment(\.calendarSheenPhase, sheen)
            .environment(\.islandFilmTime, filmTime)
        return image(IslandBackdrop(metrics: metrics, ear: IslandLayout.openEar, bottom: IslandLayout.openBottom) { content })
    }

    /// The widget's cascade as the island opens (header, hero card, rows 22 ms apart), sampled from the
    /// island's own curves.
    private static func openStrip(_ fake: FakeCalendar) -> CGImage? {
        let frames = [0.03, 0.06, 0.09, 0.12, 0.16, 0.24].compactMap { t in
            render(widget: fake.service(.granted, at: fake.at(14, 23)), metrics: floating, hover: nil, filmTime: t)
        }
        return IslandPreviewRenderer.stitch(frames, columns: 6, header: nil, spacing: 8, padding: 16)
    }

    private static func render(live event: CalendarEvent, now: Date, metrics: IslandMetrics) -> CGImage? {
        let content = CalendarLiveActivityView(event: event, now: now, metrics: metrics,
                                               join: event.meeting == nil ? nil : {})
        return image(IslandBackdrop(metrics: metrics, ear: IslandLayout.closedEar(metrics),
                                    bottom: IslandLayout.closedBottom(metrics), minWidth: 560) { content })
    }

    private static func render(settings service: CalendarService) -> CGImage? {
        let content = CalendarSettingsView(service: service)
            .padding(10)
            .frame(width: listWidth)
        return image(IslandBackdrop(metrics: floating, ear: IslandLayout.openEar, bottom: IslandLayout.openBottom) { content })
    }

    /// The live activity 10, 7, 3 and 1 minute before the start and at the start.
    private static func liveStrip(_ fake: FakeCalendar) -> CGImage? {
        let event = fake.sync
        let frames = [10, 7, 3, 1, 0].compactMap { minutes in
            render(live: event, now: event.start.addingTimeInterval(-Double(minutes) * 60), metrics: floating)
        }
        return IslandPreviewRenderer.stitch(frames, columns: 1, header: nil, spacing: 4, padding: 12)
    }

    private static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            print(url.path)
            return true
        } catch {
            FileHandle.standardError.write(Data("failed to write \(url.path): \(error)\n".utf8))
            return false
        }
    }
}

/// A slice of desktop (wallpaper and menu bar) with the island's silhouette hanging from its top edge
/// around `content`.
private struct IslandBackdrop<Content: View>: View {
    let metrics: IslandMetrics
    let ear: CGFloat
    let bottom: CGFloat
    var minWidth: CGFloat = 0
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, ear)
            .background(alignment: .top) {
                IslandShape(earRadius: ear, bottomRadius: bottom)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 40)
            .frame(minWidth: minWidth, alignment: .top)
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    // A calm, photo-like wallpaper in muted natural tones (slate sky over warm gray).
                    LinearGradient(colors: [Color(red: 0.34, green: 0.37, blue: 0.41), Color(red: 0.46, green: 0.47, blue: 0.48),
                                            Color(red: 0.55, green: 0.53, blue: 0.5)],
                                   startPoint: .top, endPoint: .bottom)
                    Rectangle().fill(Color.white.opacity(0.1)).frame(height: metrics.menuBarHeight)
                }
            }
    }
}

// MARK: - Fake data

@MainActor
private struct FakeCalendar {
    let calendar = Calendar.current
    let today: Date
    let prefs = CalendarPreferences(defaults: UserDefaults(suiteName: "me.sokolov.notchbuddy.calendar-previews") ?? .standard)

    init() {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 30
        today = Calendar.current.date(from: c) ?? Date()
    }

    func at(_ hour: Int, _ minute: Int = 0, days: Int = 0) -> Date {
        calendar.date(byAdding: DateComponents(day: days, hour: hour, minute: minute), to: today) ?? today
    }

    static let work = CalendarRGB(red: 0.12, green: 0.52, blue: 0.98)
    static let team = CalendarRGB(red: 0.2, green: 0.78, blue: 0.4)
    static let personal = CalendarRGB(red: 1.0, green: 0.58, blue: 0.0)
    static let birthdays = CalendarRGB(red: 0.8, green: 0.36, blue: 0.95)
    static let family = CalendarRGB(red: 0.35, green: 0.2, blue: 0.55)

    func link(_ service: MeetingService, _ url: String) -> MeetingLink { MeetingLink(service: service, url: URL(string: url)!) }

    var review: CalendarEvent {
        CalendarEvent(id: "review", title: "Дизайн-ревью", start: at(14), end: at(15), calendarID: "work",
                      calendarTitle: "Работа", color: Self.work, location: "Переговорка «Байкал»",
                      meeting: link(.googleMeet, "https://meet.google.com/abc-defg-hij"))
    }

    var sync: CalendarEvent {
        CalendarEvent(id: "sync", title: "Синк с командой Codex", start: at(15, 30), end: at(16), calendarID: "team",
                      calendarTitle: "Команда", color: Self.team, meeting: link(.zoom, "https://acme.zoom.us/j/81234567890"))
    }

    var events: [CalendarEvent] {
        [
            CalendarEvent(id: "standup", title: "Стендап", start: at(10), end: at(10, 15), calendarID: "work",
                          calendarTitle: "Работа", color: Self.work),
            CalendarEvent(id: "lunch", title: "Обед с Олей", start: at(13), end: at(13, 45), calendarID: "personal",
                          calendarTitle: "Личное", color: Self.personal),
            review,
            sync,
            CalendarEvent(id: "masha", title: "Созвон с Машей про релиз", start: at(17), end: at(17, 30),
                          calendarID: "personal", calendarTitle: "Личное", color: Self.personal,
                          meeting: link(.telemost, "https://telemost.yandex.ru/j/12345678901234")),
            CalendarEvent(id: "gym", title: "Спортзал", start: at(19), end: at(20, 30), calendarID: "personal",
                          calendarTitle: "Личное", color: Self.personal, location: "Фитнес-клуб, ул. Садовая"),
            CalendarEvent(id: "bday", title: "День рождения Лёши", start: at(0, days: 1), end: at(0, days: 2),
                          isAllDay: true, calendarID: "birthdays", calendarTitle: "Дни рождения", color: Self.birthdays),
            CalendarEvent(id: "vacation", title: "Аня в отпуске", start: at(0, days: 1), end: at(0, days: 3),
                          isAllDay: true, calendarID: "family", calendarTitle: "Семья", color: Self.family),
            CalendarEvent(id: "standup2", title: "Стендап", start: at(10, days: 1), end: at(10, 15, days: 1),
                          calendarID: "work", calendarTitle: "Работа", color: Self.work,
                          meeting: link(.teams, "https://teams.microsoft.com/l/meetup-join/19%3ameeting")),
            CalendarEvent(id: "one", title: "1:1 с Денисом", start: at(12, days: 1), end: at(13, days: 1),
                          calendarID: "work", calendarTitle: "Работа", color: Self.work),
            CalendarEvent(id: "demo", title: "Демо для команды", start: at(16, days: 1), end: at(17, days: 1),
                          calendarID: "team", calendarTitle: "Команда", color: Self.team,
                          meeting: link(.zoom, "https://acme.zoom.us/j/1")),
        ]
    }

    var sources: [CalendarSource] {
        [CalendarSource(id: "work", title: "Работа", account: "iCloud", color: Self.work),
         CalendarSource(id: "personal", title: "Личное", account: "iCloud", color: Self.personal),
         CalendarSource(id: "family", title: "Семья", account: "iCloud", color: Self.family),
         CalendarSource(id: "team", title: "Команда", account: "Google", color: Self.team),
         CalendarSource(id: "birthdays", title: "Дни рождения", account: "Другие", color: Self.birthdays)]
    }

    func service(_ access: CalendarService.Access, at now: Date, events: [CalendarEvent]? = nil,
                 loaded: Bool = true, requesting: Bool = false) -> CalendarService {
        CalendarService(previewAccess: access, events: events ?? self.events, calendars: sources, now: now,
                        loaded: loaded, requesting: requesting, preferences: prefs)
    }

    struct WidgetScene {
        let name: String
        let service: CalendarService
        var hover: String?
    }

    func widgetScenes() -> [WidgetScene] {
        [
            WidgetScene(name: "now", service: service(.granted, at: at(14, 23))),
            WidgetScene(name: "now-hover", service: service(.granted, at: at(14, 23)), hover: "masha"),
            WidgetScene(name: "soon", service: service(.granted, at: at(15, 23))),
            WidgetScene(name: "evening-tomorrow", service: service(.granted, at: at(21, 10))),
            WidgetScene(name: "empty", service: service(.granted, at: at(11, 5), events: [])),
            WidgetScene(name: "empty-evening", service: service(.granted, at: at(20, 40), events: Array(events.prefix(2)))),
            WidgetScene(name: "connect", service: service(.notDetermined, at: at(14, 23), events: [])),
            WidgetScene(name: "connect-waiting", service: service(.notDetermined, at: at(14, 23), events: [], requesting: true)),
            WidgetScene(name: "denied", service: service(.denied, at: at(14, 23), events: [])),
            WidgetScene(name: "write-only", service: service(.writeOnly, at: at(14, 23), events: [])),
            WidgetScene(name: "loading", service: service(.granted, at: at(14, 23), events: [], loaded: false)),
        ]
    }

    struct LiveScene {
        let name: String
        let event: CalendarEvent
        let now: Date
        let metrics: IslandMetrics
    }

    func liveScenes() -> [LiveScene] {
        let plain = CalendarEvent(id: "dentist", title: "Стоматолог", start: at(18), end: at(19), calendarID: "personal",
                                  calendarTitle: "Личное", color: Self.personal)
        return [
            LiveScene(name: "7min", event: sync, now: at(15, 23), metrics: CalendarPreviewRenderer.floating),
            LiveScene(name: "started", event: sync, now: at(15, 30, days: 0).addingTimeInterval(20),
                      metrics: CalendarPreviewRenderer.floating),
            LiveScene(name: "no-call", event: plain, now: at(17, 52), metrics: CalendarPreviewRenderer.floating),
            LiveScene(name: "7min-notch", event: sync, now: at(15, 23), metrics: CalendarPreviewRenderer.notched),
            LiveScene(name: "started-notch", event: sync, now: at(15, 30, days: 0).addingTimeInterval(20),
                      metrics: CalendarPreviewRenderer.notched),
        ]
    }
}

extension CalendarPreviewRenderer {
    /// The fake day at `hour:minute` (15:23: «Синк с командой Codex» in 7 minutes), for the island's widget films.
    static func sampleService(hour: Int = 15, minute: Int = 23) -> CalendarService {
        let fake = FakeCalendar()
        return fake.service(.granted, at: fake.at(hour, minute))
    }
}
