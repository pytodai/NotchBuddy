import SwiftUI
import NotchBuddyCore

/// The calendar's section of the island's settings (⚙️): access, tomorrow, the "meeting soon" live
/// activity and its lead time, and which calendars show. Drawn with plain shapes, so it renders to
/// images and matches the island.
struct CalendarSettingsView: View {
    let service: CalendarService

    var body: some View {
        @Bindable var prefs = service.preferences
        VStack(alignment: .leading, spacing: 0) {
            accessRow
            divider
            CalendarToggleRow(title: L("Показывать завтра"), subtitle: L("События следующего дня под сегодняшними"),
                              isOn: $prefs.showsTomorrow)
            divider
            CalendarToggleRow(title: L("Встреча скоро — на острове"),
                              subtitle: L("Свёрнутый остров считает минуты до начала"),
                              isOn: $prefs.liveActivity)
            HStack {
                Text(L("Заранее"))
                    .font(CalendarType.font(12.5, .semibold))
                    .foregroundStyle(IslandPalette.secondary)
                Spacer()
                SegmentedChoice(options: CalendarPreferences.leadChoices.map { ($0, L("%@ мин", $0)) },
                                selection: $prefs.leadMinutes)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .opacity(prefs.liveActivity ? 1 : 0.4)
            .disabled(!prefs.liveActivity)
            .animation(IslandMotion.leaf, value: prefs.liveActivity)
            if service.access == .granted, !service.calendars.isEmpty {
                divider
                calendarsList(prefs)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(CalendarPalette.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(CalendarPalette.stroke, lineWidth: 0.6))
        .environment(\.colorScheme, .dark)
    }

    private var divider: some View {
        Rectangle().fill(IslandPalette.hairline).frame(height: 0.5).padding(.leading, 14)
    }

    private var accessRow: some View {
        HStack(spacing: 10) {
            CalendarPageGlyph(day: Calendar.current.component(.day, from: service.now), size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Календарь"))
                    .font(CalendarType.font(13, .bold))
                    .foregroundStyle(IslandPalette.primary)
                HStack(spacing: 5) {
                    Circle().fill(accessColor).frame(width: 6, height: 6)
                    Text(accessText)
                        .font(CalendarType.font(11, .medium))
                        .foregroundStyle(IslandPalette.tertiary)
                }
            }
            Spacer()
            switch service.access {
            case .notDetermined:
                SmallCapsuleButton(title: L("Подключить"), prominent: true, action: service.requestAccess)
            case .denied, .writeOnly:
                SmallCapsuleButton(title: L("Настройки"), prominent: false, action: service.openPrivacySettings)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
    }

    private var accessText: String {
        switch service.access {
        case .granted:
            let n = service.calendars.count
            return L("Подключён · %@ %@", n, CalendarFormat.plural(n, "календарь", "календаря", "календарей"))
        case .notDetermined: return L("Не подключён")
        case .denied: return L("Доступ запрещён")
        case .writeOnly: return L("Только добавление событий")
        case .restricted: return L("Ограничен профилем")
        }
    }

    private var accessColor: Color {
        switch service.access {
        case .granted: return Color(red: 0.25, green: 0.84, blue: 0.42)
        case .notDetermined: return Color(white: 0.6)
        default: return CalendarPalette.soon
        }
    }

    private func calendarsList(_ prefs: CalendarPreferences) -> some View {
        let groups = Dictionary(grouping: service.calendars, by: \.account)
        let accounts = groups.keys.sorted()
        return VStack(alignment: .leading, spacing: 2) {
            Text(L("Календари"))
                .font(CalendarType.font(12.5, .semibold))
                .foregroundStyle(IslandPalette.secondary)
                .padding(.bottom, 4)
            ForEach(accounts, id: \.self) { account in
                if accounts.count > 1 || !account.isEmpty {
                    Text(account.isEmpty ? L("На этом Mac") : account)
                        .font(CalendarType.font(10.5, .heavy))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(IslandPalette.tertiary)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .leading),
                                    GridItem(.flexible(), spacing: 12, alignment: .leading)],
                          alignment: .leading, spacing: 2) {
                    ForEach(groups[account] ?? []) { source in
                        CalendarCheckRow(source: source, visible: !prefs.hiddenCalendarIDs.contains(source.id)) {
                            prefs.setCalendar(source.id, visible: prefs.hiddenCalendarIDs.contains(source.id))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - Controls

/// A label with a switch drawn in SwiftUI (renders to images; springs like the island).
struct CalendarToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(CalendarType.font(13, .semibold))
                        .foregroundStyle(IslandPalette.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(CalendarType.font(11, .medium))
                            .foregroundStyle(IslandPalette.tertiary)
                    }
                }
                Spacer(minLength: 8)
                IslandSwitch(isOn: isOn)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? L("включено") : L("выключено"))
    }
}

struct IslandSwitch: View {
    let isOn: Bool
    var tint = Color(red: 0.25, green: 0.84, blue: 0.42)

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? tint : Color.white.opacity(0.16))
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .padding(2)
        }
        .frame(width: 36, height: 21)
        .animation(.spring(response: 0.3, dampingFraction: 0.7).speed(IslandMotion.speed), value: isOn)
    }
}

/// A row of choices with a sliding highlight.
struct SegmentedChoice<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let selected = value == selection
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78).speed(IslandMotion.speed)) { selection = value }
                } label: {
                    Text(label)
                        .font(CalendarType.font(11.5, .bold))
                        .foregroundStyle(selected ? Color.black : Color.white.opacity(0.7))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background {
                            if selected {
                                Capsule().fill(Color.white)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }
}

private struct SmallCapsuleButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(CalendarType.font(12, .bold))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(prominent ? Color.white.opacity(hovering ? 1 : 0.92)
                                           : Color.white.opacity(hovering ? 0.2 : 0.13)))
                .contentShape(Capsule())
        }
        .buttonStyle(CalendarPressStyle(scale: 0.94))
        .onHover { inside in withAnimation(.smooth(duration: 0.18).speed(IslandMotion.speed)) { hovering = inside } }
    }
}

private struct CalendarCheckRow: View {
    let source: CalendarSource
    let visible: Bool
    let toggle: () -> Void

    var body: some View {
        let tint = CalendarPalette.tint(source.color)
        Button(action: toggle) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(visible ? tint : Color.clear)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(visible ? tint : Color.white.opacity(0.3), lineWidth: 1.2)
                    if visible {
                        CheckmarkShape()
                            .stroke(Color.black.opacity(0.85), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                            .frame(width: 9, height: 7)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                }
                .frame(width: 16, height: 16)
                .animation(.spring(response: 0.28, dampingFraction: 0.65).speed(IslandMotion.speed), value: visible)
                Text(source.title)
                    .font(CalendarType.font(12.5, .semibold))
                    .foregroundStyle(visible ? IslandPalette.primary : IslandPalette.tertiary)
                    .lineLimit(1)
                Spacer()
            }
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(visible ? L("показан") : L("скрыт"))
    }
}
