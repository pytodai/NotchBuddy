import SwiftUI
import NotchBuddyCore

/// Brief notice that a session finished (a green check draws onto a disc that pops out, then a ping
/// ring) or needs attention (a bell rings twice). The island pops out with a bounce and a tinted halo
/// for it and collapses by itself; click → jump.
///
/// On a notched screen a "finished" notice stays in the notch strip (it only widens): the check and
/// "Готово" beside the camera on the left, the project and its agent on the right.
struct FlashView: View {
    let notice: FlashNotice
    let session: AgentSession?
    var duration: TimeInterval?
    var quiet = false
    let metrics: IslandMetrics
    let width: CGFloat
    /// «Готово» cards waiting behind this one («ещё N»).
    var queued = 0
    /// The «Готово» card's buttons (Перейти, Скопировать, Закрыть).
    var action: (FlashAction) -> Void = { _ in }
    let onTap: () -> Void

    @State private var pressed = false
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if notice.isDoneCard {
                DoneCard(notice: notice, session: session, duration: duration, quiet: quiet, metrics: metrics,
                         width: width, queued: queued, episode: episode, action: action)
            } else if metrics.style == .notch, notice.kind == .finished {
                notchFinished
            } else {
                standard
            }
        }
        .contentShape(Rectangle())
        .scaleEffect(pressed && !reduceMotion ? 0.97 : 1, anchor: .top)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    withAnimation(IslandMotion.press.animation) { pressed = true }
                }
                .onEnded { value in
                    withAnimation(IslandMotion.press.animation) { pressed = false }
                    if hypot(value.translation.width, value.translation.height) < 8 { onTap() }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var episode: String { "flash:\(notice.id)" }
    /// The agent's pixel mascot, in the notice's own state.
    private var mascot: MascotState { notice.kind == .finished ? .done : .waiting }
    /// The mascot beside the camera: 28 pt draws a 30 pt sprite on a Retina screen (3 device pixels per art pixel).
    static let stripMascot: CGFloat = 28
    private var tint: Color { notice.kind == .finished ? SessionStatus.finished.tint : SessionStatus.waitingForUser.tint }

    // MARK: Standard

    private var standard: some View {
        let notch = metrics.style == .notch
        return VStack(spacing: 0) {
            if notch { notchStrip }
            HStack(alignment: .center, spacing: 13) {
                if !notch {
                    // The agent's mascot: a jump and a sparkle when it finished, a hopping "!" when it waits.
                    IslandMascot(source: notice.key.source, state: mascot, size: 34)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title)
                        .font(.manrope(14.5, weight: 680))
                        .foregroundStyle(IslandPalette.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .appearAfter(0.04, style: .rise)
                    lines
                        .appearAfter(0.06, style: .rise)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if notice.kind == .finished, let duration {
                    Text(L("за %@", IslandFormat.clock(duration)))
                        .font(.manrope(12.5, weight: 580, tabular: true))
                        .monospacedDigit()
                        .foregroundStyle(IslandPalette.secondary)
                        .appearAfter(0.06, style: .rise)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 18)
            .padding(.top, notch ? 8 : 14)
            .padding(.bottom, 15)
        }
        .frame(width: width)
    }

    @ViewBuilder
    private var lines: some View {
        switch notice.kind {
        case .finished:
            Text(L("%@ закончил", notice.key.source.displayName))
                .font(.manrope(12, weight: 520))
                .foregroundStyle(IslandPalette.secondary)
                .lineLimit(1)
        case .attention:
            let detail = SessionStrings.oneLine(notice.detail).flatMap { $0.isEmpty ? nil : $0 }
            let command = detail != nil && (detail == SessionStrings.oneLine(session?.lastToolSummary)
                                            || detail == session?.lastToolName)
            VStack(alignment: .leading, spacing: 2) {
                Text(command ? L("Ждёт подтверждения") : L("Ждёт тебя"))
                    .font(.manrope(12, weight: 580))
                    .foregroundStyle(SessionStatus.waitingForUser.tint)
                if let detail, detail != L("Ждёт тебя") {
                    if command {
                        Text(detail)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(detail)
                            .font(.manrope(12, weight: 520))
                            .foregroundStyle(IslandPalette.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Attention on a notched screen: the bell and "ждёт" beside the camera, the agent on the right.
    private var notchStrip: some View {
        NotchWingsLayout(notchWidth: metrics.notchWidth, minWing: 64, maxWing: 150) {
            HStack(spacing: 7) {
                FlashBadge(kind: notice.kind, source: nil, size: 22, quiet: quiet, episode: episode)
                Text(notice.kind == .finished ? L("Готово") : L("Ждёт"))
                    .font(.manrope(12.5, weight: 680))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
            .padding(.leading, 12)
            IslandMascot(source: notice.key.source, state: mascot, size: Self.stripMascot)
                .padding(.trailing, 8)
        }
        .frame(height: metrics.barHeight)
    }

    // MARK: Notch, finished

    private var notchFinished: some View {
        NotchWingsLayout(notchWidth: metrics.notchWidth, minWing: 96, maxWing: 160) {
            HStack(spacing: 7) {
                FlashBadge(kind: .finished, source: nil, size: 22, quiet: quiet, episode: episode)
                Text(L("Готово"))
                    .font(.manrope(12.5, weight: 680))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .fixedSize()
                    .appearAfter(0.04, style: .rise)
            }
            .padding(.leading, 12)
            HStack(spacing: 7) {
                Text(notice.title)
                    .font(.manrope(12.5, weight: 580))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .appearAfter(0.06, style: .rise)
                IslandMascot(source: notice.key.source, state: mascot, size: Self.stripMascot)
            }
            .padding(.trailing, 8)
        }
        .frame(height: metrics.barHeight)
    }
}

// MARK: - «Готово» card

/// A finished turn with the agent's last answer: the mascot jumping, the chat's title and how long
/// it took; the answer itself (markdown stripped, six lines, the rest scrolls under the pointer); Перейти / Скопировать
/// / Закрыть and «ещё N» when more finished meanwhile. It stays while the pointer is on it (`AppModel.holdFlash`) and
/// goes ~7 s after it appeared otherwise. Beside a notch the check and «Готово» sit in the notch's strip. The green is
/// the one sanctioned colorful moment (the calm celebration plays around it).
private struct DoneCard: View {
    let notice: FlashNotice
    let session: AgentSession?
    let duration: TimeInterval?
    let quiet: Bool
    let metrics: IslandMetrics
    let width: CGFloat
    let queued: Int
    let episode: String
    let action: (FlashAction) -> Void

    @State private var copied = false
    @State private var hovering = false
    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandFilmTime) private var filmTime

    static let replyLines = 6
    private var notch: Bool { metrics.style == .notch }
    private var tint: Color { SessionStatus.finished.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Centered on the camera housing (the card is wider than the strip's wings).
            if notch { strip.frame(maxWidth: .infinity) }
            header
                .padding(.leading, 16)
                .padding(.trailing, 18)
                .padding(.top, notch ? 6 : 14)
                .appearAfter(0.03, style: .rise)
            reply
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .appearAfter(0.06, style: .rise)
            buttons
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .appearAfter(0.09, style: .rise)
        }
        .frame(width: width)
        .onHover { hovering = $0 }
    }

    /// Beside a notch: the drawn check and «Готово» on the left of the camera, the mascot on the right.
    private var strip: some View {
        NotchWingsLayout(notchWidth: metrics.notchWidth, minWing: 64, maxWing: 160) {
            HStack(spacing: 7) {
                FlashBadge(kind: .finished, source: nil, size: 22, quiet: quiet, episode: episode)
                Text(L("Готово"))
                    .font(.manrope(12.5, weight: 680))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, 12)
            IslandMascot(source: notice.key.source, state: .done, size: FlashView.stripMascot)
                .padding(.trailing, 8)
        }
        .frame(height: metrics.barHeight)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if !notch {
                IslandMascot(source: notice.key.source, state: .done, size: 34)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.manrope(14.5, weight: 680))
                    .foregroundStyle(IslandPalette.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 5) {
                    if !notch {
                        NBIconView(.check, size: 11, color: tint)
                    }
                    Text(L("%@ закончил", notice.key.source.displayName))
                        .foregroundStyle(notch ? IslandPalette.secondary : tint)
                    if let duration {
                        Text(L("за %@", IslandFormat.clock(duration)))
                            .monospacedDigit()
                            .foregroundStyle(IslandPalette.secondary)
                    }
                }
                .font(.manrope(12, weight: 580, tabular: true))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The answer in a soft well: six lines; under the pointer the rest scrolls.
    @ViewBuilder
    private var reply: some View {
        let text = SessionCardDetails.replyText(notice.reply ?? "")
            .lineSpacing(1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
        let lineHeight: CGFloat = 17.5
        let cap = lineHeight * CGFloat(Self.replyLines)
        Group {
            if staticRender || filmTime != nil {
                text.lineLimit(Self.replyLines)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.vertical, showsIndicators: hovering) {
                    text.fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 2)
                }
                .scrollDisabled(!hovering)
                .frame(maxHeight: cap)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            Button { action(.jump) } label: {
                HStack(spacing: 4) {
                    Text(SessionStrings.Actions.jump)
                    IslandSymbol("arrow.up.right", size: 9)
                }
            }
            .buttonStyle(SessionPillButtonStyle(kind: .primary, height: 26))
            .help(SessionStrings.Actions.jumpHelp)
            Button {
                action(.copy)
                withAnimation(IslandMotion.leaf) { copied = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.6))
                    withAnimation(IslandMotion.leaf) { copied = false }
                }
            } label: {
                HStack(spacing: 4) {
                    IslandSymbol(copied ? "checkmark" : "doc.on.doc", size: 9)
                    Text(copied ? L("Скопировано") : L("Скопировать"))
                        .contentTransition(.interpolate)
                }
            }
            .buttonStyle(SessionPillButtonStyle(kind: copied ? .success : .secondary, height: 26))
            .help(L("Скопировать ответ агента целиком"))
            Spacer(minLength: 8)
            if queued > 0 {
                Text(L("ещё %@", queued))
                    .font(.manrope(11.5, weight: 650, tabular: true))
                    .foregroundStyle(IslandPalette.tertiary)
                    .transition(.opacity.animation(IslandMotion.leaf))
            }
            Button { action(.close) } label: { Text(queued > 0 ? L("Дальше") : L("Закрыть")) }
                .buttonStyle(SessionPillButtonStyle(kind: .secondary, height: 26))
                .help(queued > 0 ? L("Следующий ответ") : L("Закрыть"))
        }
    }
}

/// The notice's icon: a disc that pops out, then a check stroked onto it and a ping ring (finished),
/// or a bell that rings at 180 ms and again at 1.4 s, each ring sending out a pulse (attention). Plays
/// once per notice; the agent's mark sits on the disc as a small badge.
struct FlashBadge: View {
    let kind: FlashNotice.Kind
    var source: AgentSource?
    var size: CGFloat = 34
    var quiet = false
    var episode: String?

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.islandFilmTime) private var filmTime
    @State private var trigger = 0

    struct Value {
        var disc: CGFloat = 1
        /// The agent's small mark on the disc (it rides the disc and pops a beat after it).
        var badge: CGFloat = 1
        var check: CGFloat = 1
        var pingScale: CGFloat = 1.8
        var pingOpacity: Double = 0
        var glow: CGFloat = 8
        var bell: Double = 0
    }

    static let start = Value(disc: 0.4, badge: 0, check: 0, pingScale: 1, pingOpacity: 0, glow: 2, bell: 0)

    struct Plan {
        var firstPing: Double
        var pingScale: CGFloat
        var pingDuration: Double
        var pingOpacity: Double
        var secondPingOpacity: Double
        var gap: Double
        var angles: [Double]
    }

    static func plan(_ kind: FlashNotice.Kind, quiet: Bool) -> Plan {
        switch kind {
        case .finished:
            return Plan(firstPing: 0.48, pingScale: 1.8, pingDuration: 0.5, pingOpacity: quiet ? 0 : 0.6,
                        secondPingOpacity: 0, gap: 0.01, angles: [0, 0, 0, 0, 0])
        case .attention:
            // Rings at 180 ms and 1.4 s (not forever).
            return Plan(firstPing: 0.18, pingScale: 1.7, pingDuration: 0.6, pingOpacity: 0.5,
                        secondPingOpacity: 0.5, gap: 1.4 - 0.18 - 0.6, angles: [-18, 15, -11, 7, -3])
        }
    }

    @KeyframesBuilder<Value>
    static func keyframes(_ kind: FlashNotice.Kind, quiet: Bool) -> some Keyframes<Value> {
        let p = plan(kind, quiet: quiet)
        // Slowed down with `NOTCHBUDDY_SLOWMO` (keyframe animators take no `.speed`).
        let d = IslandMotion.t
        KeyframeTrack(\.disc) {
            LinearKeyframe(0.4, duration: d(0.06))
            CubicKeyframe(1.10, duration: d(0.20))
            CubicKeyframe(0.97, duration: d(0.10))
            SpringKeyframe(1, duration: d(0.3), spring: IslandMotion.kspring(0.25, 0.7))
        }
        KeyframeTrack(\.badge) {
            LinearKeyframe(0, duration: d(0.10))
            CubicKeyframe(1.12, duration: d(0.16))
            SpringKeyframe(1, duration: d(0.25), spring: IslandMotion.kspring(0.22, 0.7))
        }
        KeyframeTrack(\.check) {
            LinearKeyframe(0, duration: d(0.2))
            LinearKeyframe(1, duration: d(0.32), timingCurve: IslandMotion.checkCurve)
        }
        KeyframeTrack(\.glow) {
            LinearKeyframe(2, duration: d(0.48))
            CubicKeyframe(12, duration: d(0.15))
            CubicKeyframe(8, duration: d(0.5))
        }
        KeyframeTrack(\.pingScale) {
            LinearKeyframe(1, duration: d(p.firstPing))
            LinearKeyframe(p.pingScale, duration: d(p.pingDuration), timingCurve: .easeOut)
            LinearKeyframe(p.pingScale, duration: d(p.gap))
            LinearKeyframe(1, duration: d(0.001))
            LinearKeyframe(p.pingScale, duration: d(p.pingDuration), timingCurve: .easeOut)
        }
        KeyframeTrack(\.pingOpacity) {
            LinearKeyframe(0, duration: d(p.firstPing))
            LinearKeyframe(p.pingOpacity, duration: d(0.001))
            LinearKeyframe(0, duration: d(p.pingDuration), timingCurve: .easeOut)
            LinearKeyframe(0, duration: d(p.gap))
            LinearKeyframe(p.secondPingOpacity, duration: d(0.001))
            LinearKeyframe(0, duration: d(p.pingDuration), timingCurve: .easeOut)
        }
        KeyframeTrack(\.bell) {
            LinearKeyframe(0, duration: d(0.18))
            CubicKeyframe(p.angles[0], duration: d(0.07))
            CubicKeyframe(p.angles[1], duration: d(0.07))
            CubicKeyframe(p.angles[2], duration: d(0.07))
            CubicKeyframe(p.angles[3], duration: d(0.07))
            CubicKeyframe(p.angles[4], duration: d(0.07))
            SpringKeyframe(0, duration: d(0.2), spring: IslandMotion.kspring(0.2, 0.7))
            LinearKeyframe(0, duration: d(1.4 - 0.18 - 0.35 - 0.2))
            CubicKeyframe(p.angles[0], duration: d(0.07))
            CubicKeyframe(p.angles[1], duration: d(0.07))
            CubicKeyframe(p.angles[2], duration: d(0.07))
            CubicKeyframe(p.angles[3], duration: d(0.07))
            CubicKeyframe(p.angles[4], duration: d(0.07))
            SpringKeyframe(0, duration: d(0.2), spring: IslandMotion.kspring(0.2, 0.7))
        }
    }

    static func value(_ kind: FlashNotice.Kind, quiet: Bool, at t: Double) -> Value {
        KeyframeTimeline(initialValue: start) { keyframes(kind, quiet: quiet) }.value(time: max(t, 0))
    }

    var body: some View {
        let kind = kind, source = source, size = size
        if let filmTime {
            FlashBadgeFace(value: Self.value(kind, quiet: quiet, at: filmTime), kind: kind, source: source, size: size)
        } else if staticRender || reduceMotion {
            FlashBadgeFace(value: Value(), kind: kind, source: source, size: size)
        } else {
            let played = episode.map(OneShots.hasPlayed) ?? false
            Color.clear
                .frame(width: size, height: size)
                .keyframeAnimator(initialValue: played ? Value() : Self.start, trigger: trigger) { _, value in
                    FlashBadgeFace(value: value, kind: kind, source: source, size: size)
                } keyframes: { _ in
                    Self.keyframes(kind, quiet: quiet)
                }
                .onAppear {
                    if let episode {
                        if OneShots.claim(episode) { trigger &+= 1 }
                    } else {
                        trigger &+= 1
                    }
                }
        }
    }
}

private struct FlashBadgeFace: View {
    let value: FlashBadge.Value
    let kind: FlashNotice.Kind
    let source: AgentSource?
    let size: CGFloat

    nonisolated init(value: FlashBadge.Value, kind: FlashNotice.Kind, source: AgentSource?, size: CGFloat) {
        self.value = value
        self.kind = kind
        self.source = source
        self.size = size
    }

    var body: some View {
        let v = value
        let tint = kind == .finished ? SessionStatus.finished.tint : SessionStatus.waitingForUser.tint
        ZStack {
            Circle()
                .stroke(tint, lineWidth: 1.5)
                .scaleEffect(v.pingScale)
                .opacity(v.pingOpacity)
            ZStack {
                Circle().fill(tint.opacity(0.18))
                Circle().strokeBorder(tint.opacity(0.45), lineWidth: 1)
                switch kind {
                case .finished:
                    CheckmarkShape()
                        .trim(from: 0, to: v.check)
                        .stroke(tint, style: StrokeStyle(lineWidth: size > 26 ? 2.6 : 2, lineCap: .round, lineJoin: .round))
                        .frame(width: size * 0.46, height: size * 0.35)
                case .attention:
                    NBIconView(.bell, size: size * 0.6, color: tint)
                        .rotationEffect(.degrees(v.bell), anchor: .top)
                }
            }
            .shadow(color: tint.opacity(0.55), radius: v.glow)
            // Before the disc's scale: the badge rides the disc instead of waiting at its final corner.
            .overlay(alignment: .bottomTrailing) {
                if let source {
                    AgentMark(source: source, size: 14)
                        .overlay(RoundedRectangle(cornerRadius: 14 * 0.3, style: .continuous)
                            .strokeBorder(Color.black, lineWidth: 1.5)
                            .padding(-1.5))
                        .scaleEffect(v.badge)
                        .opacity(Double(min(max(v.badge * 2, 0), 1)))
                        .offset(x: 4, y: 4)
                }
            }
            .scaleEffect(v.disc)
        }
        .frame(width: size, height: size)
    }
}
