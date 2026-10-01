import SwiftUI
import NotchBuddyCore

/// The closed island's live activity for timers, bound to the store: the soonest timer counting down, or
/// "Готово" for a few seconds after one ends. Shows nothing when there is neither (check `store.hasLiveActivity`).
struct TimerLiveActivity: View {
    let store: TimerStore
    let metrics: IslandMetrics

    var body: some View {
        if store.preferences.liveActivity, store.recentFinish != nil || store.primary != nil {
            TimerLiveActivityView(timer: store.recentFinish == nil ? store.primary : nil, finish: store.recentFinish,
                                  now: store.now, tint: store.primary.map(store.tint(for:)) ?? TimerPalette.coral,
                                  others: max(0, store.engine.timers.count - (store.recentFinish == nil ? 1 : 0)),
                                  metrics: metrics, celebrate: store.preferences.celebrate)
                .timerTicking(store)
        }
    }
}

/// "Помодоро ◔ 24:13": a small ring that closes clockwise, the name, the time rolling down. Paused: a pause
/// mark in the ring and a breathing time; the last ten seconds: red with a heartbeat; done: the ring closes in
/// green around a check with a burst. Beside a notch: the ring on the left wing, the time on the right.
struct TimerLiveActivityView: View {
    let timer: TimerItem?
    var finish: TimerFinish?
    let now: Moment
    let tint: GadgetTint
    var others = 0
    let metrics: IslandMetrics
    var celebrate = true

    static let minWidth: CGFloat = 220
    static let maxWidth: CGFloat = 360
    static let wingWidth: CGFloat = 66

    var body: some View {
        Group {
            switch metrics.style {
            case .floating: floating
            case .notch: notched
            }
        }
        .frame(height: metrics.barHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var seconds: Int { timer?.displaySeconds(at: now) ?? 0 }
    private var urgent: Bool { (timer?.isRunning ?? false) && seconds <= 10 }
    private var ringTint: GadgetTint {
        guard let timer else { return TimerPalette.done }
        if urgent { return TimerPalette.urgent }
        return timer.isRunning ? tint : TimerPalette.paused
    }

    // MARK: Without a notch

    private var floating: some View {
        HStack(spacing: 0) {
            mark(size: 21)
                .padding(.leading, 10)
            Text(title)
                .font(GadgetFont.font(13, .bold))
                .foregroundStyle(finish != nil ? TimerPalette.done.hi : IslandPalette.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.interpolate)
                .padding(.leading, 9)
                .layoutPriority(-1)
            Spacer(minLength: 12)
            trailing(compact: false)
            if others > 0 {
                Text("+\(others)")
                    .font(GadgetFont.font(11.5, .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.8))
                    .contentTransition(.numericText(value: Double(others)))
                    .padding(.horizontal, 6)
                    .frame(height: 19)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .padding(.leading, 8)
                    .transition(.scale(scale: 0.5).combined(with: .opacity).animation(GadgetMotion.bouncy))
            }
            Color.clear.frame(width: 13)
        }
        .frame(minWidth: Self.minWidth, maxWidth: Self.maxWidth)
        .fixedSize()
        // Text centered on the menu bar's text line, like the agents' live activity.
        .offset(y: -1.5)
    }

    // MARK: Notch

    private var notched: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                mark(size: 20)
                    .padding(.leading, 12)
                Spacer(minLength: 0)
            }
            .frame(width: Self.wingWidth)
            Color.clear.frame(width: metrics.notchWidth)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                trailing(compact: true)
                    .padding(.trailing, 12)
            }
            .frame(width: Self.wingWidth)
        }
    }

    // MARK: Pieces

    private var title: String {
        if let finish { return finish.label == TimerItem.customLabel ? L("Время вышло") : L(finish.label) }
        return timer.map { L($0.label) } ?? ""
    }

    @ViewBuilder
    private func mark(size: CGFloat) -> some View {
        ZStack {
            if let finish {
                TimerCelebration(size: size, lineWidth: 2.8, bursts: celebrate, episode: "live-\(finish.id)")
                    .transition(.scale(scale: 0.6).combined(with: .opacity).animation(GadgetMotion.bouncy))
            } else if let timer {
                TimerRing(timer: timer, now: now, tint: ringTint, size: size, lineWidth: 2.8, smooth: false, showsHead: true)
                if timer.isPaused {
                    GadgetIcon(glyph: .pause, size: size * 0.42, color: TimerPalette.paused.hi)
                        .transition(.scale(scale: 0.4).combined(with: .opacity).animation(GadgetMotion.bouncy))
                } else {
                    Circle()
                        .fill(ringTint.hi)
                        .frame(width: size * 0.2, height: size * 0.2)
                        .transition(.scale(scale: 0.4).combined(with: .opacity).animation(GadgetMotion.bouncy))
                }
            }
        }
        .frame(width: size, height: size)
        .animation(GadgetMotion.snap, value: timer?.isPaused)
    }

    @ViewBuilder
    private func trailing(compact: Bool) -> some View {
        if finish != nil {
            Text(compact ? L("готово") : L("готово"))
                .font(GadgetFont.font(compact ? 12 : 12.5, .heavy))
                .foregroundStyle(TimerPalette.done.hi)
                .transition(.scale(scale: 0.7).combined(with: .opacity).animation(GadgetMotion.bouncy))
        } else if let timer {
            TimerDigits(seconds: seconds, size: compact ? (seconds >= 3600 ? 11 : 13) : 13.5, urgent: urgent,
                        weight: .bold, color: timer.isRunning ? .white : Color.white.opacity(0.6))
                .modifier(Breathing(active: timer.isPaused, cycles: 5, low: 0.5))
        }
    }

    private var accessibilityText: String {
        if let finish { return L("Таймер «%@» закончился", L(finish.label)) }
        guard let timer else { return "" }
        return L("%@: осталось %@%@", L(timer.label), TimerFormat.clock(seconds), timer.isPaused ? L(", пауза") : "")
    }
}
