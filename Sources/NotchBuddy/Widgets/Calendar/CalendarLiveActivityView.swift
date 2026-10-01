import SwiftUI
import NotchBuddyCore

/// The closed island's live activity for a meeting about to start, bound to the service: shows while
/// `service.imminent` is set (lead time before the start until shortly after it) and keeps the minute
/// clock running while it is on screen.
struct CalendarLiveActivity: View {
    let service: CalendarService
    let metrics: IslandMetrics
    /// Offer "join" right in the pill (the call link is one click away).
    var showsJoin = true

    var body: some View {
        if let event = service.imminent {
            CalendarLiveActivityView(event: event, now: service.now, lead: service.preferences.lead, metrics: metrics,
                                     join: showsJoin && event.meeting != nil ? { service.join(event) } : nil)
                .modifier(CalendarTicking(service: service))
        }
    }
}

/// "Дизайн-ревью · через 7 мин": a thin white ring on a dark-gray track that empties toward the start,
/// around a camera (a call) or a calendar page. On a notched screen it splits into wings beside the camera
/// housing: the ring on the left, the minutes on the right. At the start the ring fills and the text
/// turns to "началась". Everything stays white and gray, like the system's own live activities.
struct CalendarLiveActivityView: View {
    let event: CalendarEvent
    let now: Date
    var lead: TimeInterval = CalendarAgenda.defaultLead
    let metrics: IslandMetrics
    var join: (() -> Void)?

    @Environment(\.islandReduceMotion) private var reduceMotion

    static let minWidth: CGFloat = 220
    static let maxWidth: CGFloat = 360
    static let wingWidth: CGFloat = 66

    private var left: TimeInterval { event.start.timeIntervalSince(now) }
    private var started: Bool { left < 30 }
    /// The ring and its mark stay white; the calendar's color is not used here.
    private var tint: Color { .white }
    private var minute: Int { Int((left / 60).rounded(.up)) }

    var body: some View {
        Group {
            switch metrics.style {
            case .floating: floating
            case .notch: notched
            }
        }
        .frame(height: metrics.barHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.displayTitle), \(CalendarFormat.shared.countdown(to: event.start, now: now))")
    }

    // MARK: Without a notch

    private var floating: some View {
        HStack(spacing: 0) {
            LiveCountdownMark(event: event, fraction: fraction, started: started, tint: tint, size: 22, tick: minute)
                .padding(.leading, 9)
            Text(event.displayTitle)
                .font(CalendarType.font(13, .semibold))
                .foregroundStyle(IslandPalette.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 9)
                .layoutPriority(-1)
            Spacer(minLength: 10)
            countdownText(compact: false)
            if let join {
                LiveJoinButton(tint: tint, action: join)
                    .padding(.leading, 8)
            }
            Color.clear.frame(width: join == nil ? 13 : 7)
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
                LiveCountdownMark(event: event, fraction: fraction, started: started, tint: tint, size: 20, tick: minute)
                    .padding(.leading, 12)
                Spacer(minLength: 0)
            }
            .frame(width: Self.wingWidth)
            Color.clear.frame(width: metrics.notchWidth)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                countdownText(compact: true)
                    .padding(.trailing, 12)
            }
            .frame(width: Self.wingWidth)
        }
    }

    // MARK: Pieces

    /// Full ring `lead` before the start, empty at the start.
    private var fraction: Double { started ? 1 : min(max(left / max(lead, 60), 0), 1) }

    private func countdownText(compact: Bool) -> some View {
        let text: String = {
            if started { return compact ? Lc("meeting", "идёт") : L("началась") }
            return compact ? CalendarFormat.compactSpan(left) : CalendarFormat.shared.countdown(to: event.start, now: now)
        }()
        return Text(text)
            .font(CalendarType.font(compact ? 12 : 12.5, .bold))
            .monospacedDigit()
            .foregroundStyle(started ? IslandPalette.primary : IslandPalette.secondary)
            .contentTransition(started ? .interpolate : .numericText(countsDown: true))
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.8)
                .speed(IslandMotion.speed), value: text)
            .lineLimit(1)
            .fixedSize()
    }
}

/// The ring and its mark. Every minute the mark gives a small tick; once the meeting starts the ring is
/// full.
struct LiveCountdownMark: View {
    let event: CalendarEvent
    let fraction: Double
    let started: Bool
    let tint: Color
    let size: CGFloat
    /// Changes once a minute (the tick).
    let tick: Int

    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            CountdownRing(fraction: fraction, tint: tint, size: size, lineWidth: max(2, size * 0.1))
            Group {
                if event.meeting != nil {
                    VideoCallShape()
                        .fill(Color.white)
                        .frame(width: size * 0.46, height: size * 0.32)
                } else {
                    RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                        .fill(Color.white)
                        .frame(width: size * 0.36, height: size * 0.36)
                        .overlay(alignment: .top) {
                            Rectangle().fill(CalendarPalette.today).frame(height: size * 0.1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.08, style: .continuous))
                }
            }
            .keyframeAnimator(initialValue: CGFloat(1), trigger: tick) { [reduceMotion] content, scale in
                content.scaleEffect(reduceMotion ? 1 : scale)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(1.22, duration: IslandMotion.t(0.14))
                    SpringKeyframe(1, duration: IslandMotion.t(0.4), spring: IslandMotion.kspring(0.35, 0.5))
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// A round camera button in the pill.
private struct LiveJoinButton: View {
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VideoCallShape()
                .fill(Color.black)
                .frame(width: 11, height: 8)
                .frame(width: 24, height: 20)
                .background(Capsule().fill(Color.white.opacity(hovering ? 1 : 0.9)))
                .contentShape(Capsule())
        }
        .buttonStyle(CalendarPressStyle(scale: 0.9))
        .onHover { inside in withAnimation(.spring(response: 0.25, dampingFraction: 0.7).speed(IslandMotion.speed)) { hovering = inside } }
        .help(L("Подключиться к звонку"))
    }
}
