import XCTest
@testable import NotchBuddyCore

final class CalendarAgendaTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }()

    /// 2026-09-30 at `hour:minute` Moscow time (+ `days`).
    private func at(_ hour: Int, _ minute: Int = 0, days: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 30 + days; c.hour = hour; c.minute = minute
        return calendar.date(from: c)!
    }

    private func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, title: id, start: start, end: end, isAllDay: allDay)
    }

    func testSplitsTodayAndTomorrowAndDropsEndedEvents() {
        let events = [
            event("morning", at(9), at(10)),
            event("lunch", at(13), at(14)),
            event("review", at(15), at(16)),
            event("standup", at(10, days: 1), at(10, 15, days: 1)),
            event("holiday", at(0, days: 1), at(0, days: 2), allDay: true),
            event("later", at(10, days: 3), at(11, days: 3)),
        ]
        let agenda = CalendarAgenda(events: events, now: at(13, 20), calendar: calendar)
        XCTAssertEqual(agenda.today.timed.map(\.id), ["lunch", "review"])
        XCTAssertEqual(agenda.today.ended, 1)
        XCTAssertEqual(agenda.today.allDay, [])
        XCTAssertEqual(agenda.tomorrow?.timed.map(\.id), ["standup"])
        XCTAssertEqual(agenda.tomorrow?.allDay.map(\.id), ["holiday"])
        XCTAssertEqual(agenda.current.map(\.id), ["lunch"])
        XCTAssertEqual(agenda.next?.id, "review")
        XCTAssertEqual(agenda.hero?.id, "lunch")
        XCTAssertEqual(agenda.progress(of: events[1]), 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertFalse(agenda.isEmpty)
    }

    func testMostSpecificCurrentEventComesFirst() {
        let focus = event("focus", at(12), at(18))
        let meeting = event("meeting", at(14), at(14, 30))
        let agenda = CalendarAgenda(events: [focus, meeting], now: at(14, 10), calendar: calendar)
        XCTAssertEqual(agenda.current.map(\.id), ["meeting", "focus"])
        XCTAssertEqual(agenda.hero?.id, "meeting")
    }

    func testImminentWindowOpensTenMinutesBeforeAndClosesTwoMinutesAfterStart() {
        let call = event("call", at(15), at(15, 30))
        XCTAssertNil(CalendarAgenda(events: [call], now: at(14, 49), calendar: calendar).imminent)
        XCTAssertEqual(CalendarAgenda(events: [call], now: at(14, 50), calendar: calendar).imminent?.id, "call")
        XCTAssertEqual(CalendarAgenda(events: [call], now: at(15, 1), calendar: calendar).imminent?.id, "call")
        XCTAssertNil(CalendarAgenda(events: [call], now: at(15, 2), calendar: calendar).imminent)
        // All-day events never count as starting soon.
        let allDay = event("day", at(0, days: 1), at(0, days: 2), allDay: true)
        XCTAssertNil(CalendarAgenda(events: [allDay], now: at(23, 55), calendar: calendar).imminent)
    }

    func testCustomLeadTime() {
        let call = event("call", at(15), at(15, 30))
        let agenda = CalendarAgenda(events: [call], now: at(14, 46), calendar: calendar, lead: 15 * 60)
        XCTAssertEqual(agenda.imminent?.id, "call")
        XCTAssertTrue(agenda.isSoon(call))
    }

    func testWithoutTomorrow() {
        let events = [event("standup", at(10, days: 1), at(11, days: 1))]
        let agenda = CalendarAgenda(events: events, now: at(20), calendar: calendar, includeTomorrow: false)
        XCTAssertNil(agenda.tomorrow)
        XCTAssertNil(agenda.next)
        XCTAssertTrue(agenda.isEmpty)
    }

    func testEventRunningPastMidnightStaysUnderToday() {
        let party = event("party", at(22), at(2, days: 1))
        let agenda = CalendarAgenda(events: [party], now: at(23), calendar: calendar)
        XCTAssertEqual(agenda.today.timed.map(\.id), ["party"])
        XCTAssertEqual(agenda.tomorrow?.timed, [])
    }

    func testNextBoundary() {
        let call = event("call", at(15), at(15, 30))
        XCTAssertEqual(CalendarAgenda.nextBoundary(events: [call], after: at(12)), at(14, 50))
        XCTAssertEqual(CalendarAgenda.nextBoundary(events: [call], after: at(14, 50)), at(15, 2))
        XCTAssertEqual(CalendarAgenda.nextBoundary(events: [call], after: at(15, 2)), at(15, 30))
        XCTAssertNil(CalendarAgenda.nextBoundary(events: [call], after: at(15, 30)))
    }

    func testEmptyAgenda() {
        let agenda = CalendarAgenda(events: [], now: at(9), calendar: calendar)
        XCTAssertTrue(agenda.isEmpty)
        XCTAssertNil(agenda.hero)
        XCTAssertNil(agenda.imminent)
    }
}

final class CalendarFormatTests: XCTestCase {
    private let format: CalendarFormat = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return CalendarFormat(calendar: c)
    }()

    private func at(_ hour: Int, _ minute: Int = 0, days: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 30 + days; c.hour = hour; c.minute = minute
        return format.calendar.date(from: c)!
    }

    func testSpans() {
        XCTAssertEqual(CalendarFormat.span(7 * 60), "7\u{00A0}мин")
        XCTAssertEqual(CalendarFormat.span(6 * 60 + 10), "7\u{00A0}мин")
        XCTAssertEqual(CalendarFormat.span(5), "1\u{00A0}мин")
        XCTAssertEqual(CalendarFormat.span(3600), "1\u{00A0}ч")
        XCTAssertEqual(CalendarFormat.span(95 * 60), "1\u{00A0}ч 35\u{00A0}мин")
        XCTAssertEqual(CalendarFormat.compactSpan(150 * 60), "2,5\u{00A0}ч")
        XCTAssertEqual(CalendarFormat.compactSpan(120 * 60), "2\u{00A0}ч")
    }

    func testCountdownAndRemaining() {
        XCTAssertEqual(format.countdown(to: at(15), now: at(14, 53)), "через\u{00A0}7\u{00A0}мин")
        XCTAssertEqual(format.countdown(to: at(15), now: at(14, 59, days: 0).addingTimeInterval(45)), "сейчас")
        XCTAssertEqual(format.countdown(to: at(1, days: 1), now: at(23)), "через\u{00A0}2\u{00A0}ч")
        XCTAssertEqual(format.countdown(to: at(10, days: 1), now: at(20)), "завтра в\u{00A0}10:00")
        XCTAssertEqual(format.countdown(to: at(10, days: 1), now: at(9)), "завтра в\u{00A0}10:00")
        XCTAssertEqual(format.remaining(until: at(15, 30), now: at(15, 5)), "ещё\u{00A0}25\u{00A0}мин")
        XCTAssertEqual(format.remaining(until: at(15, 30), now: at(15, 29, days: 0).addingTimeInterval(40)), "заканчивается")
    }

    func testTimesAndDates() {
        XCTAssertEqual(format.time(at(9, 5)), "9:05")
        XCTAssertEqual(format.range(CalendarEvent(id: "a", title: "a", start: at(14), end: at(15, 30))), "14:00–15:30")
        XCTAssertEqual(format.weekdayAndDate(at(12)), "среда, 30 сентября")
        XCTAssertEqual(format.weekday(at(12)), "Среда")
        XCTAssertEqual(CalendarFormat.meetings(3), "3\u{00A0}встречи")
        XCTAssertEqual(CalendarFormat.meetings(5), "5\u{00A0}встреч")
        XCTAssertEqual(CalendarFormat.meetings(21), "21\u{00A0}встреча")
    }

    func testDisplayTitleAndLocation() {
        let meeting = MeetingLink(service: .zoom, url: URL(string: "https://acme.zoom.us/j/123")!)
        var e = CalendarEvent(id: "a", title: "  ", start: at(9), end: at(10), location: "https://acme.zoom.us/j/123",
                              meeting: meeting)
        XCTAssertEqual(e.displayTitle, "Без названия")
        XCTAssertNil(e.displayLocation)
        e.location = "Переговорка «Байкал»\nэтаж 3"
        XCTAssertEqual(e.displayLocation, "Переговорка «Байкал», этаж 3")
    }
}

final class MeetingLinkTests: XCTestCase {
    func testRecognizesServices() {
        let cases: [(String, MeetingService)] = [
            ("https://us02web.zoom.us/j/81234567890?pwd=abc", .zoom),
            ("https://meet.google.com/abc-defg-hij", .googleMeet),
            ("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d", .teams),
            ("https://telemost.yandex.ru/j/12345678901234", .telemost),
            ("https://telemost.360.yandex.ru/j/12345678901234", .telemost),
            ("https://salutejazz.ru/calls/abc?psw=xyz", .jazz),
            ("https://acme.ktalk.ru/room123", .kontur),
            ("https://facetime.apple.com/join#v=1&p=abc", .facetime),
            ("https://meet.jit.si/SomeRoom", .jitsi),
            ("https://acme.webex.com/meet/jdoe", .webex),
        ]
        for (url, service) in cases {
            XCTAssertEqual(MeetingLinkDetector.detect(url: url, location: nil, notes: nil)?.service, service, url)
        }
    }

    func testIgnoresHelpLinksAndForeignHosts() {
        XCTAssertNil(MeetingLinkDetector.detect(url: nil, location: nil,
                                                notes: "Find your local number: https://zoom.us/u/abcdef"))
        XCTAssertNil(MeetingLinkDetector.detect(url: nil, location: nil,
                                                notes: "https://teams.microsoft.com/meetingOptions/?organizerId=1"))
        XCTAssertNil(MeetingLinkDetector.detect(url: "https://zoom.us.evil.example/j/1", location: nil, notes: nil))
        XCTAssertNil(MeetingLinkDetector.detect(url: "http://meet.google.com/abc-defg-hij", location: nil, notes: nil))
        XCTAssertNil(MeetingLinkDetector.detect(url: "https://user:pw@meet.google.com/abc-defg-hij", location: nil, notes: nil))
        XCTAssertNil(MeetingLinkDetector.detect(url: nil, location: "Переговорка 3", notes: "Обсудим план"))
    }

    func testFindsLinkInsideNotesAndTrimsPunctuation() {
        let notes = """
        Присоединиться: <https://meet.google.com/xyz-abcd-efg>.
        Справка: https://support.google.com/a/users/answer/9282720
        """
        let link = MeetingLinkDetector.detect(url: nil, location: "Офис", notes: notes)
        XCTAssertEqual(link?.service, .googleMeet)
        XCTAssertEqual(link?.url.absoluteString, "https://meet.google.com/xyz-abcd-efg")
    }

    func testEventURLWinsOverNotes() {
        let link = MeetingLinkDetector.detect(url: "https://telemost.yandex.ru/j/555",
                                              location: nil, notes: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(link?.service, .telemost)
    }

    func testSkipsHelpLinkBeforeRealLink() {
        let notes = "Help https://zoom.us/u/xyz then join (https://acme.zoom.us/j/999?pwd=1)"
        XCTAssertEqual(MeetingLinkDetector.detect(url: nil, location: nil, notes: notes)?.url.absoluteString,
                       "https://acme.zoom.us/j/999?pwd=1")
    }
}
