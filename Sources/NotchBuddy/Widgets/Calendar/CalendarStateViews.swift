import SwiftUI
import NotchBuddyCore

/// Before access: what the widget does, and one button that asks macOS (the only place access is asked).
struct CalendarConnectView: View {
    let day: Int
    let requesting: Bool
    let connect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CalendarArt(day: day, accent: .sparkles, size: 50)
            Text(L("Встречи — прямо на острове"))
                .font(CalendarType.font(15.5, .bold))
                .foregroundStyle(IslandPalette.primary)
                .padding(.top, 2)
            Text(L("Ближайшая встреча, отсчёт до начала и звонок в один клик."))
                .font(CalendarType.font(12, .medium))
                .foregroundStyle(IslandPalette.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
            HStack(spacing: 6) {
                FeaturePill(symbol: "timer", text: L("Минуты до начала"), delay: 0.12)
                FeaturePill(symbol: "video.fill", text: L("Zoom, Meet, Телемост"), delay: 0.17)
                FeaturePill(symbol: "lock.fill", text: L("Только на этом Mac"), delay: 0.22)
            }
            .padding(.top, 12)
            CalendarPrimaryButton(title: requesting ? L("Ждём ответа macOS…") : L("Подключить календарь"),
                                  symbol: "calendar.badge.plus", busy: requesting, action: connect)
                .padding(.top, 14)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }
}

private struct FeaturePill: View {
    let symbol: String
    let text: String
    let delay: Double

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(IslandPalette.secondary)
            Text(text)
                .font(CalendarType.font(11, .semibold))
                .foregroundStyle(Color.white.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6))
        .fixedSize()
        .appearAfter(delay, style: .row)
    }
}

/// Access was refused, restricted, or is add-only.
struct CalendarAccessProblemView: View {
    let access: CalendarService.Access
    let day: Int
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CalendarArt(day: day, accent: .lock, size: 50)
            Text(title)
                .font(CalendarType.font(15.5, .bold))
                .foregroundStyle(IslandPalette.primary)
                .padding(.top, 2)
            Text(message)
                .font(CalendarType.font(12, .medium))
                .foregroundStyle(IslandPalette.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
            if access != .restricted {
                CalendarPrimaryButton(title: L("Открыть настройки"), symbol: "gearshape.fill", prominent: false,
                                      action: openSettings)
                    .padding(.top, 14)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        switch access {
        case .writeOnly: return L("Нужен полный доступ")
        case .restricted: return L("Календарь недоступен")
        default: return L("Нет доступа к календарю")
        }
    }

    private var message: String {
        switch access {
        case .writeOnly:
            return L("Сейчас NotchBuddy может только добавлять события, а острову нужно их видеть. Выбери «Полный доступ» в разделе «Календари».")
        case .restricted:
            return L("Доступ к календарям на этом Mac ограничен профилем управления.")
        default:
            return L("Разреши NotchBuddy доступ: Системные настройки → Конфиденциальность и безопасность → Календари.")
        }
    }
}

/// Nothing left today (and tomorrow): a calm picture instead of an empty list.
struct CalendarEmptyView: View {
    let agenda: CalendarAgenda
    let day: Int
    let showsTomorrow: Bool

    var body: some View {
        let hour = Calendar.current.component(.hour, from: agenda.now)
        let evening = hour >= 18 || hour < 5
        VStack(spacing: 0) {
            CalendarArt(day: day, accent: evening ? .moon : .sparkles, size: 50)
            Text(title)
                .font(CalendarType.font(15.5, .bold))
                .foregroundStyle(IslandPalette.primary)
                .padding(.top, 2)
            Text(message(evening: evening))
                .font(CalendarType.font(12, .medium))
                .foregroundStyle(IslandPalette.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        if agenda.today.ended > 0 { return L("На сегодня всё") }
        return showsTomorrow ? L("Два свободных дня") : L("Свободный день")
    }

    private func message(evening: Bool) -> String {
        let ended = agenda.today.ended
        switch (ended > 0, showsTomorrow) {
        case (true, true): return L("%@, и завтра ничего нет. %@", ended == 1 ? L("Встреча позади") : L("Все встречи позади"), evening ? L("Хорошего вечера!") : L("Время для глубокой работы."))
        case (true, false): return ended == 1 ? L("Встреча позади — дальше свободно.") : L("Все встречи позади — дальше свободно.")
        case (false, true): return L("Ни одной встречи ни сегодня, ни завтра. Самое время для глубокой работы.")
        case (false, false): return L("Сегодня ни одной встречи — время для глубокой работы.")
        }
    }
}

/// While the first fetch runs: rows of soft placeholders with a light passing over them.
struct CalendarSkeleton: View {
    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(height: 76)
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)).frame(width: 34, height: 11)
                    Capsule().fill(Color.white.opacity(0.1)).frame(width: 3.5, height: 28)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.09))
                            .frame(width: [180, 140, 200][i], height: 11)
                        RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06))
                            .frame(width: [90, 120, 70][i], height: 9)
                    }
                    Spacer()
                }
                .padding(.leading, 12)
                .frame(height: 44)
            }
        }
        .overlay {
            GeometryReader { geo in
                LinearGradient(colors: [.clear, .white.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: phase * geo.size.width * 1.5)
            }
            .allowsHitTesting(false)
            .opacity(staticRender || reduceMotion ? 0 : 1)
        }
        .mask(VStack(spacing: 0) { Color.black })
        .onAppear {
            guard !staticRender, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false).speed(IslandMotion.speed)) { phase = 1 }
        }
    }
}
