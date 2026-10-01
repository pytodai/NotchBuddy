import SwiftUI
import NotchBuddyCore

/// The notice when a timer ends (the island's flash slot): the ring closes in green and bursts, a check is
/// drawn, and the name with "время вышло"; +1 мин, again, or OK. On a notched screen the top strip beside the
/// camera says "Таймер … готово".
struct TimerFinishNoticeView: View {
    let store: TimerStore
    let finish: TimerFinish
    let metrics: IslandMetrics
    var width: CGFloat = 420
    /// Called after any of the buttons (the island closes the notice).
    var onDone: () -> Void = {}

    var body: some View {
        let notch = metrics.style == .notch
        VStack(spacing: 0) {
            if notch { strip }
            HStack(spacing: 14) {
                TimerCelebration(size: 54, lineWidth: 5, bursts: store.preferences.celebrate, episode: "notice-\(finish.id)")
                    .padding(.vertical, -4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(GadgetFont.font(15, .bold))
                        .foregroundStyle(IslandPalette.primary)
                        .lineLimit(1)
                        .appearAfter(0.05, style: .rise)
                    Text(subtitle)
                        .font(GadgetFont.font(12, .semibold))
                        .foregroundStyle(TimerPalette.done.hi)
                        .lineLimit(1)
                        .appearAfter(0.08, style: .rise)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    GadgetButton(kind: .secondary, height: 30, action: {
                        store.snooze(finish)
                        onDone()
                    }) {
                        Text(L("+1 мин")).font(GadgetFont.font(12, .bold))
                    }
                    GadgetButton(kind: .round, height: 30, action: {
                        store.again(finish)
                        onDone()
                    }) {
                        GadgetIcon(glyph: .restart, size: 13, color: .white.opacity(0.9), weight: 2.4)
                    }
                    .help(L("Повторить"))
                    GadgetButton(kind: .primary(TimerPalette.done), height: 30, action: {
                        store.dismissFinish()
                        onDone()
                    }) {
                        Text(L("Ок")).font(GadgetFont.font(12, .bold)).frame(minWidth: 18)
                    }
                }
                .appearAfter(0.1, style: .rise)
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)
            .padding(.top, notch ? 6 : 14)
            .padding(.bottom, 14)
        }
        .frame(width: width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Таймер «%@» закончился", L(finish.label)))
    }

    private var title: String { finish.label == TimerItem.customLabel ? L("Время вышло") : L(finish.label) }

    private var subtitle: String {
        finish.label == TimerItem.customLabel ? L("таймер на %@", TimerFormat.length(finish.duration))
            : L("время вышло · %@", TimerFormat.length(finish.duration))
    }

    private var strip: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                GadgetIcon(glyph: .stopwatch, size: 13, color: TimerPalette.done.hi)
                Text(L("Таймер"))
                    .font(GadgetFont.font(12, .bold))
                    .foregroundStyle(IslandPalette.secondary)
            }
            .padding(.leading, 18)
            Spacer(minLength: metrics.notchWidth + 12)
            Text(L("готово"))
                .font(GadgetFont.font(12, .heavy))
                .foregroundStyle(TimerPalette.done.hi)
                .padding(.trailing, 18)
        }
        .frame(height: metrics.barHeight)
    }
}
