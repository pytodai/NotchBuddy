import SwiftUI
import NotchBuddyCore

/// The closed island's live activity for a low battery, bound to the monitor (shows nothing unless
/// `monitor.hasLiveActivity`).
struct BatteryLiveActivity: View {
    let monitor: SystemMonitor
    let metrics: IslandMetrics

    var body: some View {
        if monitor.hasLiveActivity, let battery = monitor.battery {
            BatteryLiveActivityView(state: battery, metrics: metrics, threshold: monitor.preferences.lowBatteryThreshold)
        }
    }
}

/// "▭ Низкий заряд … 14 % · 25 мин": a red battery that glows (and, at the critical level, breathes), what to
/// do, the percent rolling down and the time left. Beside a notch: the battery on the left wing, the percent
/// on the right.
struct BatteryLiveActivityView: View {
    let state: BatteryState
    let metrics: IslandMetrics
    var threshold = 20

    static let minWidth: CGFloat = 220
    static let maxWidth: CGFloat = 360
    static let wingWidth: CGFloat = 66

    private var critical: Bool { state.percent <= min(10, threshold) }
    private var tint: GadgetTint { SystemPalette.batteryLow }

    var body: some View {
        Group {
            switch metrics.style {
            case .floating: floating
            case .notch: notched
            }
        }
        .frame(height: metrics.barHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Низкий заряд батареи: %@ %%", state.percent))
    }

    private var floating: some View {
        HStack(spacing: 0) {
            glyph
                .padding(.leading, 12)
            Text(critical ? L("Подключи зарядку") : L("Низкий заряд"))
                .font(GadgetFont.font(13, .bold))
                .foregroundStyle(IslandPalette.primary)
                .lineLimit(1)
                .contentTransition(.interpolate)
                .padding(.leading, 9)
                .layoutPriority(-1)
            Spacer(minLength: 12)
            percent(size: 13.5)
            if let minutes = state.minutesToEmpty {
                Text(SystemFormat.minutes(minutes))
                    .font(GadgetFont.font(12, .semibold))
                    .foregroundStyle(IslandPalette.secondary)
                    .contentTransition(.numericText(countsDown: true))
                    .padding(.leading, 7)
            }
            Color.clear.frame(width: 13)
        }
        .frame(minWidth: Self.minWidth, maxWidth: Self.maxWidth)
        .fixedSize()
        .offset(y: -1.5)
    }

    private var notched: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                glyph.padding(.leading, 12)
                Spacer(minLength: 0)
            }
            .frame(width: Self.wingWidth)
            Color.clear.frame(width: metrics.notchWidth)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                percent(size: 12.5).padding(.trailing, 12)
            }
            .frame(width: Self.wingWidth)
        }
    }

    private var glyph: some View {
        // A low battery breathes (its fill is the status accent); no glow behind it.
        BatteryGlyph(state: state, width: 25, height: 12.5, threshold: threshold, showsMark: false)
            .modifier(Breathing(active: true, cycles: 7, low: 0.55))
    }

    private func percent(size: CGFloat) -> some View {
        Text(L("%@\u{00A0}%%", state.percent))
            .font(GadgetFont.font(size, .heavy))
            .monospacedDigit()
            .foregroundStyle(tint.hi)
            .contentTransition(.numericText(countsDown: true))
            .animation(GadgetMotion.digits, value: state.percent)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A short notice about power (the island's flash slot): plugged in (the battery fills to its level and a bolt
/// pops), unplugged, full, low, critical.
struct BatteryNoticeView: View {
    let event: BatteryEvent
    let state: BatteryState?
    let metrics: IslandMetrics
    var threshold = 20
    var width: CGFloat = 392

    var body: some View {
        let notch = metrics.style == .notch
        VStack(spacing: 0) {
            if notch { Color.clear.frame(height: metrics.barHeight) }
            HStack(spacing: 16) {
                BatteryGlyph(state: state, width: 50, height: 24, threshold: threshold)
                    .keyframeAnimator(initialValue: CGFloat(1), trigger: event) { content, s in
                        content.scaleEffect(s)
                    } keyframes: { _ in
                        KeyframeTrack {
                            LinearKeyframe(0.8, duration: 0.001)
                            SpringKeyframe(1, duration: IslandMotion.t(0.6), spring: IslandMotion.kspring(0.4, 0.55))
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(GadgetFont.font(15, .bold))
                        .foregroundStyle(IslandPalette.primary)
                        .appearAfter(0.05, style: .rise)
                    Text(subtitle)
                        .font(GadgetFont.font(12, .semibold))
                        .foregroundStyle(tint.hi)
                        .lineLimit(1)
                        .appearAfter(0.08, style: .rise)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let state {
                    Text(L("%@\u{00A0}%%", state.percent))
                        .font(GadgetFont.font(20, .heavy))
                        .monospacedDigit()
                        .foregroundStyle(tint.hi)
                        .appearAfter(0.1, style: .rise)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, notch ? 6 : 14)
            .padding(.bottom, 14)
        }
        .frame(width: width)
    }

    private var tint: GadgetTint {
        switch event {
        case .low, .critical: return SystemPalette.batteryLow
        case .unplugged: return SystemPalette.battery(state, threshold: threshold)
        case .pluggedIn, .full: return SystemPalette.batteryGood
        }
    }

    private var title: String {
        switch event {
        case .low: return L("Низкий заряд")
        case .critical: return L("Батарея почти села")
        case .pluggedIn(_, let charging): return charging ? L("Заряжается") : L("Подключено к сети")
        case .unplugged: return L("От батареи")
        case .full: return L("Заряжен полностью")
        }
    }

    private var subtitle: String {
        switch event {
        case .low, .critical:
            return state?.minutesToEmpty.map { L("осталось %@ · подключи зарядку", SystemFormat.minutes($0)) } ?? L("подключи зарядку")
        case .pluggedIn(_, let charging):
            if !charging { return L("зарядка на паузе") }
            return state?.minutesToFull.map { L("до полной %@", SystemFormat.minutes($0)) } ?? L("идёт зарядка")
        case .unplugged:
            return state?.minutesToEmpty.map { L("хватит на %@", SystemFormat.minutes($0)) } ?? L("оцениваю время работы…")
        case .full:
            return L("можно отключить зарядку")
        }
    }
}
