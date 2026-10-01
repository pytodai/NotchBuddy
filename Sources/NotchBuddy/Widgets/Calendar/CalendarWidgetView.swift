import SwiftUI
import NotchBuddyCore

/// Everything the calendar widget draws, as a value (previews make it without EventKit).
struct CalendarWidgetState: Equatable {
    var access: CalendarService.Access
    var loaded: Bool
    var requesting: Bool
    var showsTomorrow: Bool
    var agenda: CalendarAgenda

    var now: Date { agenda.now }
}

/// What the widget's buttons do.
struct CalendarActions {
    var connect: () -> Void = {}
    var openSettings: () -> Void = {}
    var join: (CalendarEvent) -> Void = { _ in }
    var reveal: (CalendarEvent) -> Void = { _ in }
    var openCalendar: () -> Void = {}
}

extension CalendarService {
    var widgetState: CalendarWidgetState {
        CalendarWidgetState(access: access, loaded: loaded, requesting: requesting,
                            showsTomorrow: preferences.showsTomorrow, agenda: agenda)
    }

    var actions: CalendarActions {
        CalendarActions(connect: { [weak self] in self?.requestAccess() },
                        openSettings: { [weak self] in self?.openPrivacySettings() },
                        join: { [weak self] in self?.join($0) },
                        reveal: { [weak self] in self?.reveal($0) },
                        openCalendar: { [weak self] in self?.openCalendarApp() })
    }
}

/// The calendar widget bound to the service: its minute clock runs only while this is on screen.
///
/// `notchWidth`: on a notched screen the widget's header sits beside the camera housing (pass the notch
/// width and `headerHeight` = the notch height); 0 lays it out as one block.
struct CalendarWidget: View {
    let service: CalendarService
    var notchWidth: CGFloat = 0
    var headerHeight: CGFloat = 46

    var body: some View {
        CalendarWidgetView(state: service.widgetState, actions: service.actions, notchWidth: notchWidth,
                           headerHeight: headerHeight)
            .modifier(CalendarTicking(service: service))
    }
}

/// Keeps the service's minute clock running while the view is on screen (balanced even if SwiftUI
/// repeats an appearance).
struct CalendarTicking: ViewModifier {
    let service: CalendarService
    @State private var holding = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !holding else { return }
                holding = true
                service.beginTicking()
            }
            .onDisappear {
                guard holding else { return }
                holding = false
                service.endTicking()
            }
    }
}

/// Today and tomorrow at a glance: what is on now (with the time left and a progress line) or what
/// comes next (with a countdown dial), the rest of the agenda with calendar colors, and a one-click
/// "Подключиться" for calls. Before access is granted it explains itself and asks (on click only).
///
/// Motion follows the island's: the header, the hero card and each row drop in 22 ms apart as the
/// silhouette uncovers them; times roll like counters; the progress line fills from zero; a meeting that
/// starts soon sends a sheen across its button once a minute.
struct CalendarWidgetView: View {
    let state: CalendarWidgetState
    var actions = CalendarActions()
    var notchWidth: CGFloat = 0
    var headerHeight: CGFloat = 46
    /// Previews: the row drawn as hovered.
    var hoverOverride: String?

    /// At most this many timed rows below the hero card (the rest: "и ещё N").
    var maxRows = 5
    static let sidePadding: CGFloat = 10

    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var hoveredRow: String?

    private var format: CalendarFormat { .shared }
    private var agenda: CalendarAgenda { state.agenda }

    var body: some View {
        VStack(spacing: 0) {
            header
                .appearAfter(0.02, style: .header)
            ZStack(alignment: .top) {
                content
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                                            removal: .opacity)
                        .animation(.smooth(duration: 0.28).speed(IslandMotion.speed)))
            }
            .animation(.smooth(duration: 0.32).speed(IslandMotion.speed), value: phase)
            // Below the camera housing, the first card keeps a little air from the strip.
            .padding(.top, notchWidth > 0 ? 6 : 0)
        }
        .padding(.bottom, 10)
        .environment(\.colorScheme, .dark)
    }

    /// Which of the widget's faces shows (a change cross-fades).
    private var phase: String {
        switch state.access {
        case .granted: return !state.loaded ? "loading" : (agenda.isEmpty ? "empty" : "agenda")
        default: return "\(state.access)"
        }
    }

    // MARK: Header

    private var header: some View {
        let notch = notchWidth > 0
        let title = notch ? format.shortWeekdayAndDate(state.now) : format.weekdayAndDate(state.now)
        return HStack(spacing: 10) {
            CalendarPageGlyph(day: Calendar.current.component(.day, from: state.now), size: notch ? 22 : 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.prefix(1).uppercased() + title.dropFirst())
                    .font(CalendarType.font(notch ? 13 : 14, .bold))
                    .foregroundStyle(IslandPalette.primary)
                    .lineLimit(1)
                if !notch, let subtitle {
                    Text(subtitle)
                        .font(CalendarType.font(11, .medium))
                        .foregroundStyle(IslandPalette.tertiary)
                        .contentTransition(.numericText())
                        .animation(IslandMotion.leaf, value: subtitle)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: notch ? notchWidth + 12 : 8)
            if state.access == .granted {
                Button(action: actions.openCalendar) {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(IslandIconButtonStyle(size: 24))
                .help(L("Открыть Календарь"))
            }
        }
        .padding(.leading, notch ? 14 : 16)
        .padding(.trailing, 12)
        .frame(height: headerHeight)
    }

    private var subtitle: String? {
        switch state.access {
        case .notDetermined: return L("Календарь не подключён")
        case .denied, .writeOnly, .restricted: return L("Нет доступа к календарю")
        case .granted: if !state.loaded { return L("Загружаю события…") }
        }
        let left = agenda.today.timed.count
        if left == 0 { return agenda.today.ended > 0 ? L("На сегодня встречи позади") : L("Сегодня без встреч") }
        let ongoing = agenda.current.count
        if ongoing > 0, left == ongoing { return L("Последняя встреча дня") }
        return L("Сегодня ещё %@", CalendarFormat.meetings(left))
    }

    // MARK: Faces

    @ViewBuilder
    private var content: some View {
        switch state.access {
        case .notDetermined:
            CalendarConnectView(day: day, requesting: state.requesting, connect: actions.connect)
                .appearAfter(0.05, style: .section)
        case .denied, .writeOnly, .restricted:
            // Add-only access may still be upgraded once by asking; otherwise it is System Settings.
            CalendarAccessProblemView(access: state.access, day: day,
                                      openSettings: state.access == .writeOnly ? actions.connect : actions.openSettings)
                .appearAfter(0.05, style: .section)
        case .granted:
            if !state.loaded {
                CalendarSkeleton()
                    .padding(.horizontal, Self.sidePadding)
                    .appearAfter(0.05, style: .section)
            } else if agenda.isEmpty {
                CalendarEmptyView(agenda: agenda, day: day, showsTomorrow: state.showsTomorrow)
                    .appearAfter(0.05, style: .section)
            } else {
                agendaView
            }
        }
    }

    private var day: Int { Calendar.current.component(.day, from: state.now) }

    // MARK: Agenda

    private struct Section: Identifiable {
        var id: CalendarAgenda.DayKind { kind }
        var kind: CalendarAgenda.DayKind
        var title: String
        var detail: String?
        var allDay: [CalendarEvent]
        var rows: [CalendarEvent]
    }

    private func sections(excluding hero: CalendarEvent?) -> (sections: [Section], hidden: Int) {
        var budget = maxRows
        var hidden = 0
        var result: [Section] = []
        for day in agenda.days {
            let timed = day.timed.filter { $0.id != hero?.id }
            let shown = Array(timed.prefix(budget))
            budget -= shown.count
            hidden += timed.count - shown.count
            guard !shown.isEmpty || !day.allDay.isEmpty else { continue }
            switch day.kind {
            case .today:
                let detail = day.ended > 0
                    ? "\(day.ended) \(CalendarFormat.plural(day.ended, "прошла", "прошли", "прошло"))" : nil
                result.append(Section(kind: .today, title: L("Сегодня"), detail: detail, allDay: day.allDay, rows: shown))
            case .tomorrow:
                result.append(Section(kind: .tomorrow, title: L("Завтра"), detail: format.shortWeekdayAndDate(day.date),
                                      allDay: day.allDay, rows: shown))
            }
        }
        return (result, hidden)
    }

    /// One line of the agenda below the hero card, in order (so each gets a fixed place in the cascade).
    private enum Item: Identifiable {
        case header(Section)
        case allDay(Section)
        case row(CalendarEvent)
        case more(Int)

        var id: String {
            switch self {
            case .header(let s): return "header-\(s.kind)"
            case .allDay(let s): return "allday-\(s.kind)"
            case .row(let e): return e.id
            case .more: return "more"
            }
        }
    }

    private func items(excluding hero: CalendarEvent?) -> [Item] {
        let (sections, hidden) = sections(excluding: hero)
        var items: [Item] = []
        for section in sections {
            items.append(.header(section))
            if !section.allDay.isEmpty { items.append(.allDay(section)) }
            items += section.rows.map(Item.row)
        }
        if hidden > 0 { items.append(.more(hidden)) }
        return items
    }

    /// Rows drop in 18 ms apart after the hero card, as the opening silhouette uncovers them.
    private static func rowDelay(_ index: Int) -> Double { 0.05 + 0.018 * Double(min(index, 8)) }

    private var agendaView: some View {
        let hero = agenda.hero
        let items = items(excluding: hero)
        return VStack(spacing: 0) {
            if let hero {
                CalendarHeroCard(event: hero, agenda: agenda, live: agenda.current.first?.id == hero.id,
                                 actions: actions)
                    .padding(.horizontal, Self.sidePadding)
                    .padding(.bottom, 4)
                    .appearAfter(0.04, style: .section)
                    .id("hero-\(hero.id)")
                    .transition(.opacity.combined(with: .scale(scale: 0.97)).animation(IslandMotion.leaf))
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                itemView(item)
                    .appearAfter(Self.rowDelay(index), style: .row)
                    .transition(.opacity.combined(with: .move(edge: .top)).animation(IslandMotion.leaf))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : IslandMotion.leaf, value: items.map(\.id))
    }

    @ViewBuilder
    private func itemView(_ item: Item) -> some View {
        switch item {
        case .header(let section):
            sectionHeader(section)
        case .allDay(let section):
            AllDayStrip(events: section.allDay, reveal: actions.reveal)
                .padding(.horizontal, 22)
                .padding(.bottom, 4)
        case .row(let event):
            CalendarAgendaRow(event: event, agenda: agenda, hovering: (hoverOverride ?? hoveredRow) == event.id,
                              actions: actions)
                .onHover { inside in
                    withAnimation(.smooth(duration: 0.18).speed(IslandMotion.speed)) {
                        if inside { hoveredRow = event.id } else if hoveredRow == event.id { hoveredRow = nil }
                    }
                }
                .padding(.horizontal, Self.sidePadding)
        case .more(let hidden):
            Button(action: actions.openCalendar) {
                HStack(spacing: 4) {
                    Text(L("и ещё %@", CalendarFormat.meetings(hidden)))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .font(CalendarType.font(11.5, .semibold))
                .foregroundStyle(IslandPalette.secondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .contentShape(Capsule())
            }
            .buttonStyle(CalendarPressStyle())
            .padding(.top, 4)
            .help(L("Открыть Календарь"))
        }
    }

    private func sectionHeader(_ section: Section) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(section.title.uppercased())
                .font(CalendarType.font(10.5, .heavy))
                .tracking(0.9)
                .foregroundStyle(section.kind == .today ? IslandPalette.primary.opacity(0.9) : IslandPalette.secondary)
            if let detail = section.detail {
                Text(detail)
                    .font(CalendarType.font(11, .semibold))
                    .foregroundStyle(IslandPalette.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

// MARK: - Hero card

/// The event that matters now: the one going on (time left, a thin white progress line) or the next one
/// (a countdown dial). A plain dark card; the calendar's color shows only as a small dot. Click shows it
/// in Calendar.
struct CalendarHeroCard: View {
    let event: CalendarEvent
    let agenda: CalendarAgenda
    let live: Bool
    let actions: CalendarActions

    @State private var hovering = false

    private var format: CalendarFormat { .shared }

    var body: some View {
        let tint = CalendarPalette.tint(event.color)
        let soon = !live && agenda.isSoon(event)
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Button { actions.reveal(event) } label: {
            Group {
                if live { liveBody(tint) } else { nextBody(tint, soon: soon) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(hovering ? CalendarPalette.cardHover : CalendarPalette.card))
            .overlay(shape.strokeBorder(CalendarPalette.stroke, lineWidth: 0.6))
            .contentShape(shape)
        }
        .buttonStyle(CalendarPressStyle(scale: 0.985))
        .onHover { inside in withAnimation(.smooth(duration: 0.18).speed(IslandMotion.speed)) { hovering = inside } }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let when = live ? format.remaining(until: event.end, now: agenda.now)
            : format.countdown(to: event.start, now: agenda.now)
        return "\(live ? L("Сейчас") : L("Далее")): \(event.displayTitle), \(format.range(event)), \(when)"
    }

    // Now

    private func liveBody(_ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                NowDot(tint: tint, size: 7)
                Text(L("Сейчас"))
                    .font(CalendarType.font(11.5, .bold))
                    .foregroundStyle(IslandPalette.primary)
                Text(format.remaining(until: event.end, now: agenda.now))
                    .font(CalendarType.font(11.5, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(IslandPalette.secondary)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(IslandMotion.leaf, value: agenda.now)
                Spacer(minLength: 8)
                if let meeting = event.meeting {
                    // A gleam once a minute while joining late is still likely.
                    JoinCallButton(meeting: meeting, prominent: true, tint: tint,
                                   pulseKey: agenda.now < event.start.addingTimeInterval(300) ? agenda.now : nil) {
                        actions.join(event)
                    }
                }
            }
            .frame(height: 26)
            Text(event.displayTitle)
                .font(CalendarType.font(17, .bold))
                .foregroundStyle(IslandPalette.primary)
                .lineLimit(2)
                .padding(.top, 6)
            detailLine(tint)
                .padding(.top, 4)
            EventProgressLine(id: event.id, progress: agenda.progress(of: event), tint: tint)
                .padding(.top, 12)
            HStack {
                Text(format.time(event.start))
                Spacer()
                Text(format.time(event.end))
            }
            .font(CalendarType.font(10, .semibold))
            .monospacedDigit()
            .foregroundStyle(IslandPalette.tertiary)
            .padding(.top, 5)
        }
    }

    // Next

    private func nextBody(_ tint: Color, soon: Bool) -> some View {
        HStack(alignment: .center, spacing: 13) {
            CountdownDial(event: event, now: agenda.now, window: soon ? agenda.lead : CountdownDial.hour,
                          tint: .white)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                    Text(soon ? L("Скоро") : L("Далее"))
                        .font(CalendarType.font(11.5, .bold))
                        .foregroundStyle(IslandPalette.primary)
                    Text(format.countdown(to: event.start, now: agenda.now))
                        .font(CalendarType.font(11.5, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(IslandPalette.secondary)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(IslandMotion.leaf, value: agenda.now)
                }
                Text(event.displayTitle)
                    .font(CalendarType.font(15.5, .bold))
                    .foregroundStyle(IslandPalette.primary)
                    .lineLimit(2)
                detailLine(tint)
            }
            Spacer(minLength: 6)
            if let meeting = event.meeting {
                JoinCallButton(meeting: meeting, prominent: soon, tint: tint, pulseKey: soon ? agenda.now : nil) {
                    actions.join(event)
                }
            }
        }
    }

    /// "14:00–15:00 · Zoom · Переговорка".
    private func detailLine(_ tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(format.range(event))
                .monospacedDigit()
            if let meeting = event.meeting {
                Dot()
                MeetingBadge(service: meeting.service, size: 13)
                Text(meeting.service.displayName)
                    .layoutPriority(-1)
            }
            if let place = event.displayLocation {
                Dot()
                Text(place)
                    .layoutPriority(-2)
            }
        }
        .font(CalendarType.font(12, .medium))
        .foregroundStyle(IslandPalette.secondary)
        .lineLimit(1)
    }
}

private struct Dot: View {
    var body: some View {
        Circle().fill(Color.white.opacity(0.3)).frame(width: 2.5, height: 2.5)
    }
}

/// The event's progress: a thin white line on a dark-gray track that grows from zero when it first shows
/// (`tint` is kept for callers; the line itself stays white).
struct EventProgressLine: View {
    let id: String
    let progress: Double
    let tint: Color

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var shown: Double?

    var body: some View {
        let value = min(max(progress, 0), 1)
        let current = staticRender ? value : (shown ?? 0)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(CalendarPalette.track)
                BarFill(fraction: CGFloat(current))
                    .fill(Color.white.opacity(0.92))
                    .frame(width: geo.size.width)
            }
        }
        .frame(height: 4)
        .padding(.vertical, 2)
        .onAppear {
            guard !staticRender, shown == nil else { return }
            shown = 0
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.9, dampingFraction: 0.86)
                .delay(0.15).speed(IslandMotion.speed)) { shown = value }
        }
        .onChange(of: value) { _, new in
            withAnimation(.spring(response: 0.7, dampingFraction: 0.9).speed(IslandMotion.speed)) { shown = new }
        }
    }
}

/// Minutes to the next event inside a ring that empties over `window` (the last hour; the lead time once
/// the meeting is close, so the ring refills and winds down again); the start time for later today; a
/// small calendar page for tomorrow.
struct CountdownDial: View {
    let event: CalendarEvent
    let now: Date
    let window: TimeInterval
    let tint: Color

    static let hour: TimeInterval = 3600

    var body: some View {
        let left = event.start.timeIntervalSince(now)
        let calendar = Calendar.current
        let tomorrow = !calendar.isDate(event.start, inSameDayAs: now)
        ZStack {
            if tomorrow {
                CalendarPageGlyph(day: calendar.component(.day, from: event.start), size: 34)
            } else {
                CountdownRing(fraction: min(max(left / max(window, 60), 0), 1), tint: tint, size: 46, lineWidth: 2.5)
                if left < Self.hour {
                    VStack(spacing: -2) {
                        Text("\(max(1, Int((left / 60).rounded(.up))))")
                            .font(CalendarType.font(16, .heavy))
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                            .animation(IslandMotion.leaf, value: Int(left / 60))
                        Text(L("мин"))
                            .font(CalendarType.font(8.5, .bold))
                            .foregroundStyle(IslandPalette.secondary)
                    }
                    .foregroundStyle(IslandPalette.primary)
                } else {
                    Text(CalendarFormat.shared.time(event.start))
                        .font(CalendarType.font(11.5, .heavy))
                        .monospacedDigit()
                        .foregroundStyle(IslandPalette.primary)
                }
            }
        }
        .frame(width: 46, height: 46)
    }
}

// MARK: - Rows

/// One event in the agenda: start and end times, the calendar's color bar, title, call service or place.
/// "идёт" or "через 7 мин" at the end when it matters; hover offers the call.
struct CalendarAgendaRow: View {
    let event: CalendarEvent
    let agenda: CalendarAgenda
    let hovering: Bool
    let actions: CalendarActions

    private var format: CalendarFormat { .shared }

    var body: some View {
        let tint = CalendarPalette.tint(event.color)
        let ongoing = event.start <= agenda.now && event.end > agenda.now
        let soon = agenda.isSoon(event) && !ongoing
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        Button { actions.reveal(event) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(format.time(event.start))
                        .font(CalendarType.font(12.5, .bold))
                        .foregroundStyle(Color.white.opacity(0.92))
                    Text(format.time(event.end))
                        .font(CalendarType.font(10.5, .semibold))
                        .foregroundStyle(IslandPalette.tertiary)
                }
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.displayTitle)
                        .font(CalendarType.font(13.5, .semibold))
                        .foregroundStyle(IslandPalette.primary)
                        .lineLimit(1)
                    subtitle
                }
                Spacer(minLength: 6)
                trailing(tint: tint, ongoing: ongoing, soon: soon)
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .frame(height: 48)
            .background(shape.fill(Color.white.opacity(hovering ? 0.06 : 0)))
            .contentShape(shape)
        }
        .buttonStyle(CalendarPressStyle())
    }

    @ViewBuilder
    private var subtitle: some View {
        HStack(spacing: 5) {
            if let meeting = event.meeting {
                MeetingBadge(service: meeting.service, size: 12)
                Text(meeting.service.displayName)
            }
            if let place = event.displayLocation {
                if event.meeting != nil { Text("·") }
                Text(place)
            } else if event.meeting == nil {
                Text(event.calendarTitle.isEmpty ? L("Календарь") : event.calendarTitle)
            }
        }
        .font(CalendarType.font(11, .medium))
        .foregroundStyle(IslandPalette.tertiary)
        .lineLimit(1)
    }

    @ViewBuilder
    private func trailing(tint: Color, ongoing: Bool, soon: Bool) -> some View {
        ZStack(alignment: .trailing) {
            if hovering, let meeting = event.meeting {
                JoinCallButton(meeting: meeting, prominent: false, compact: true) { actions.join(event) }
                    .transition(.scale(scale: 0.7).combined(with: .opacity).animation(IslandMotion.pop))
            } else if ongoing {
                StatusChip(text: Lc("meeting", "идёт"), tint: tint)
                    .transition(.opacity.animation(IslandMotion.leaf))
            } else if soon {
                StatusChip(text: format.countdown(to: event.start, now: agenda.now), tint: .white)
                    .transition(.opacity.animation(IslandMotion.leaf))
            } else if hovering {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(IslandPalette.tertiary)
                    .transition(.opacity.animation(IslandMotion.leaf))
            }
        }
    }
}

private struct StatusChip: View {
    let text: String
    let tint: Color

    var body: some View {
        // Neutral: white text on a gray capsule (`tint` is kept for callers).
        Text(text)
            .font(CalendarType.font(11, .semibold))
            .monospacedDigit()
            .foregroundStyle(IslandPalette.primary.opacity(0.88))
            .contentTransition(.numericText(countsDown: true))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(CalendarPalette.chip))
            .fixedSize()
    }
}

/// All-day events as neutral chips with a small dot in the calendar's color (three, then "+N").
private struct AllDayStrip: View {
    let events: [CalendarEvent]
    let reveal: (CalendarEvent) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(events.prefix(3)) { event in
                let tint = CalendarPalette.tint(event.color)
                Button { reveal(event) } label: {
                    HStack(spacing: 5) {
                        Circle().fill(tint).frame(width: 6, height: 6)
                        Text(event.displayTitle)
                            .lineLimit(1)
                    }
                    .font(CalendarType.font(11.5, .semibold))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule().fill(CalendarPalette.chip))
                    .contentShape(Capsule())
                }
                .buttonStyle(CalendarPressStyle())
            }
            if events.count > 3 {
                Text("+\(events.count - 3)")
                    .font(CalendarType.font(11.5, .bold))
                    .foregroundStyle(IslandPalette.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Capsule().fill(CalendarPalette.chip))
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Buttons

/// "Подключиться": joins the call. Prominent (white) when the meeting is on or about to start; then a
/// faint gray sheen crosses it when it appears and again on every `pulseKey` change (once a minute).
struct JoinCallButton: View {
    let meeting: MeetingLink
    var prominent: Bool
    /// Kept for callers; the button and its gleam stay neutral.
    var tint: Color = .blue
    var compact = false
    var pulseKey: Date?
    let action: () -> Void

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var sheen = 0

    var body: some View {
        let foreground = prominent ? Color.black : Color.white
        Button(action: action) {
            HStack(spacing: 6) {
                VideoCallShape()
                    .fill(foreground)
                    .frame(width: 13, height: 9)
                if !compact {
                    Text(L("Подключиться"))
                        .font(CalendarType.font(12, .bold))
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 0 : 11)
            .frame(width: compact ? 28 : nil, height: compact ? 24 : 27)
            // The gleam passes under the label.
            .background {
                ZStack {
                    Capsule().fill(prominent ? Color.white.opacity(hovering ? 1 : 0.94)
                                   : Color.white.opacity(hovering ? 0.2 : 0.13))
                    if prominent {
                        SheenSweep(trigger: sheen, color: .black).opacity(0.18).clipShape(Capsule())
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(CalendarPressStyle(scale: 0.94))
        .onHover { inside in withAnimation(.spring(response: 0.25, dampingFraction: 0.7).speed(IslandMotion.speed)) { hovering = inside } }
        .onAppear {
            guard prominent, !staticRender, !reduceMotion else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45 / IslandMotion.speed) { sheen &+= 1 }
        }
        .onChange(of: pulseKey) { _, _ in
            guard prominent, !reduceMotion else { return }
            sheen &+= 1
        }
        .help(L("Подключиться к звонку в %@", meeting.service.displayName))
        .accessibilityLabel(L("Подключиться, %@", meeting.service.displayName))
    }
}

/// A diagonal band of light that crosses its container once per trigger (on a white button it is drawn
/// faint and gray: white on white would not show).
struct SheenSweep: View {
    let trigger: Int
    var color: Color

    @Environment(\.calendarSheenPhase) private var fixedPhase

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let band = LinearGradient(stops: [.init(color: color.opacity(0), location: 0),
                                              .init(color: color.opacity(0.45), location: 0.5),
                                              .init(color: color.opacity(0), location: 1)],
                                      startPoint: .leading, endPoint: .trailing)
                .frame(width: max(28, w * 0.4), height: geo.size.height * 2)
                .rotationEffect(.degrees(20))
                .offset(y: -geo.size.height / 2)
            if let fixedPhase {
                band.offset(x: fixedPhase * w * 1.4)
            } else {
                band.keyframeAnimator(initialValue: CGFloat(-1), trigger: trigger) { content, x in
                    content.offset(x: x * w * 1.4)
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(CGFloat(-1), duration: 0)
                        CubicKeyframe(CGFloat(1.2), duration: IslandMotion.t(0.9))
                    }
                }
            }
        }
    }
}

private struct CalendarSheenPhaseKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }

extension EnvironmentValues {
    /// Previews: the sheen frozen at this position (-1 … 1.2) instead of animating.
    var calendarSheenPhase: CGFloat? {
        get { self[CalendarSheenPhaseKey.self] }
        set { self[CalendarSheenPhaseKey.self] = newValue }
    }
}

/// A plain press: a small squeeze and a quick release.
struct CalendarPressStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(IslandMotion.press.animation, value: configuration.isPressed)
    }
}

/// The widget's primary action: a white capsule (a spinner while `busy`).
struct CalendarPrimaryButton: View {
    let title: String
    let symbol: String
    var busy = false
    var prominent = true
    let action: () -> Void

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var sheen = 0

    var body: some View {
        let foreground = prominent ? Color.black : Color.white
        Button(action: action) {
            HStack(spacing: 7) {
                ZStack {
                    if busy {
                        CalendarSpinner(color: foreground)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 12.5, weight: .bold))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 16, height: 16)
                Text(title)
                    .font(CalendarType.font(13, .bold))
                    .contentTransition(.interpolate)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background {
                ZStack {
                    Capsule().fill(prominent ? Color.white.opacity(hovering ? 1 : 0.94)
                                   : Color.white.opacity(hovering ? 0.18 : 0.12))
                    if prominent {
                        SheenSweep(trigger: sheen, color: .black).opacity(0.18)
                            .clipShape(Capsule())
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Capsule())
            .animation(.smooth(duration: 0.25).speed(IslandMotion.speed), value: busy)
        }
        .buttonStyle(CalendarPressStyle(scale: 0.95))
        .disabled(busy)
        .onHover { inside in withAnimation(.spring(response: 0.25, dampingFraction: 0.7).speed(IslandMotion.speed)) { hovering = inside } }
        .onAppear {
            guard prominent, !staticRender, !reduceMotion else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55 / IslandMotion.speed) { sheen &+= 1 }
        }
    }
}

/// An arc that spins (still in images).
struct CalendarSpinner: View {
    var color: Color
    @Environment(\.islandStaticRender) private var staticRender
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.8)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                guard !staticRender else { return }
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spinning = true }
            }
    }
}
