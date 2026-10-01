import AppKit
import SwiftUI
import NotchBuddyCore

/// Recent tool calls, newest on top, strung on a thin line: a spinning node while a call runs (with its own
/// running clock), a green dot once it succeeded, a red one with the error when it failed, a hollow one when
/// its turn ended without a result. A new call slides in from the top; a node that gets its result pops.
struct ToolTimeline: View {
    let calls: [ToolCall]
    /// Older calls not shown ("ещё 3").
    var hidden = 0
    /// The call a permission request is waiting on (drawn in the waiting color, "ждёт 0:45").
    var awaitingId: Int?

    static let rowHeight: CGFloat = 20
    static let nodeColumn: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(calls.enumerated()), id: \.element.id) { index, call in
                ToolTimelineRow(call: call, awaiting: call.id == awaitingId, first: index == 0,
                                last: index == calls.count - 1 && hidden == 0)
                    .appearAfter(0.02 + 0.03 * Double(index), style: .row)
                    .transition(.asymmetric(
                        insertion: .modifier(active: TimelineInsert(q: 0), identity: TimelineInsert(q: 1))
                            .animation(.spring(response: 0.34, dampingFraction: 0.82).speed(IslandMotion.speed)),
                        removal: .opacity.animation(.easeOut(duration: 0.12).speed(IslandMotion.speed))))
            }
            if hidden > 0 {
                HStack(spacing: 8) {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5]))
                        .frame(width: 7, height: 7)
                        .frame(width: Self.nodeColumn)
                    Text(SessionStrings.Card.moreTools(hidden))
                        .font(SessionType.caption)
                        .foregroundStyle(IslandPalette.tertiary)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(hidden)))
                }
                .frame(height: 16)
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86).speed(IslandMotion.speed), value: calls.map(\.id))
    }
}

/// A row sliding in from the top of the timeline.
private struct TimelineInsert: ViewModifier, Animatable {
    var q: Double
    var animatableData: Double {
        get { q }
        set { q = newValue }
    }

    func body(content: Content) -> some View {
        let k = min(max(q, 0), 1)
        content
            .opacity(k)
            .blur(radius: 3 * CGFloat(1 - k))
            .offset(y: -8 * CGFloat(1 - q))
            .scaleEffect(0.96 + 0.04 * CGFloat(q), anchor: .topLeading)
    }
}

private struct ToolTimelineRow: View {
    let call: ToolCall
    let awaiting: Bool
    let first: Bool
    let last: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Node and the line through it.
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(first ? Color.clear : Color.white.opacity(0.14))
                        .frame(width: 1, height: ToolTimeline.rowHeight / 2)
                    Rectangle()
                        .fill(last ? Color.clear : Color.white.opacity(0.14))
                        .frame(width: 1)
                }
                TimelineNode(outcome: call.outcome, awaiting: awaiting)
                    .frame(height: ToolTimeline.rowHeight)
            }
            .frame(width: ToolTimeline.nodeColumn)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    IslandSymbol(SessionStrings.toolSymbol(call.name), size: 9.5, color: Color.white.opacity(0.62))
                        .frame(width: 14)
                    Text(SessionStrings.toolName(call.name))
                        .font(SessionType.metaStrong)
                        .foregroundStyle(Color.white.opacity(call.outcome == .abandoned ? 0.55 : 0.88))
                        .lineLimit(1)
                        .fixedSize()
                    if call.agentId != nil {
                        Text(SessionStrings.Card.subagent)
                            .font(SessionFont.manrope(9, 700))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .padding(.horizontal, 5)
                            .frame(height: 14)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .fixedSize()
                    }
                    if let text = summary {
                        Text(text)
                            .font(SessionStrings.toolSummaryIsCode(call.name) ? SessionType.code(10) : SessionType.meta)
                            .foregroundStyle(Color.white.opacity(0.48))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    ToolCallTime(call: call, awaiting: awaiting)
                }
                .frame(height: ToolTimeline.rowHeight)
                if call.outcome == .failed, let error = call.error {
                    Text(error)
                        .font(SessionType.code(9.5))
                        .foregroundStyle(SessionStatus.error.tint.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 19)
                        .padding(.bottom, 3)
                        .transition(.opacity.combined(with: .offset(y: -3)))
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8).speed(IslandMotion.speed), value: call.outcome)
    }

    private var summary: String? { SessionStrings.toolSummary(call.name, call.summary) }
}

/// "0,4 с" once finished, a running clock while it runs, "прервано" for an abandoned call.
private struct ToolCallTime: View {
    let call: ToolCall
    var awaiting = false
    @Environment(IslandClock.self) private var clock: IslandClock?

    var body: some View {
        let text: String = {
            switch call.outcome {
            case .running:
                let clockText = SessionStrings.clock((clock?.now ?? Date()).timeIntervalSince(call.startedAt))
                return awaiting ? "\(SessionStrings.Card.awaitingApproval) \(clockText)" : clockText
            case .abandoned:
                return SessionStrings.toolOutcome(.abandoned)
            case .succeeded, .failed:
                return SessionStrings.toolDuration(call.duration ?? 0)
            }
        }()
        Text(text)
            .font(SessionFont.manrope(10.5, 600))
            .monospacedDigit()
            .foregroundStyle(awaiting ? SessionStatus.waitingForUser.tint
                             : call.outcome == .running ? SessionStatus.working.tint
                             : call.outcome == .failed ? SessionStatus.error.tint.opacity(0.9)
                             : IslandPalette.tertiary)
            .contentTransition(.numericText(countsDown: false))
            .animation(.snappy(duration: 0.24).speed(IslandMotion.speed), value: text)
            .lineLimit(1)
            .fixedSize()
    }
}

/// The node of one call: its glyph swaps with a pop when the result arrives.
private struct TimelineNode: View {
    let outcome: ToolCall.Outcome
    var awaiting = false

    var body: some View {
        ZStack {
            glyph
                .id(awaiting ? "awaiting" : outcome.rawValue)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.2).combined(with: .opacity).animation(IslandMotion.pop),
                    removal: .scale(scale: 0.5).combined(with: .opacity)
                        .animation(.easeIn(duration: 0.1).speed(IslandMotion.speed))))
        }
        .frame(width: 12, height: 12)
    }

    @ViewBuilder
    private var glyph: some View {
        switch outcome {
        case .running where awaiting:
            WaitingPulse(color: SessionStatus.waitingForUser.tint, size: 10)
        case .running:
            ToolSpinner(color: SessionStatus.working.tint)
                .frame(width: 11, height: 11)
        case .succeeded:
            ZStack {
                Circle().fill(SessionStatus.finished.tint)
                Image(systemName: "checkmark")
                    .font(.system(size: 5.5, weight: .black))
                    .foregroundStyle(.black.opacity(0.8))
            }
            .frame(width: 9, height: 9)
        case .failed:
            ZStack {
                Circle().fill(SessionStatus.error.tint)
                Image(systemName: "xmark")
                    .font(.system(size: 5, weight: .black))
                    .foregroundStyle(.black.opacity(0.8))
            }
            .frame(width: 9, height: 9)
        case .abandoned:
            Circle()
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1.2)
                .frame(width: 8, height: 8)
        }
    }
}

// MARK: - Spinner

/// A small arc turning in Core Animation (no per-frame SwiftUI work); a still arc in images.
struct ToolSpinner: View {
    let color: Color
    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.islandFilmTime) private var filmTime

    var body: some View {
        if staticRender || filmTime != nil || reduceMotion {
            ZStack {
                Circle().stroke(color.opacity(0.22), lineWidth: 1.6)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(filmTime.map { $0 * 400 } ?? -60))
            }
        } else {
            SpinnerLayer(color: NSColor(color))
        }
    }
}

private struct SpinnerLayer: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> ToolSpinnerLayerView {
        let view = ToolSpinnerLayerView()
        view.igniteDelay = context.environment.islandIgniteDelay
        return view
    }

    func updateNSView(_ view: ToolSpinnerLayerView, context: Context) {
        view.color = color
    }
}

final class ToolSpinnerLayerView: LoopLayerView {
    var color: NSColor = .systemBlue {
        didSet { if oldValue != color { applyColor() } }
    }

    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        for layer in [track, arc] {
            layer.fillColor = nil
            layer.lineWidth = 1.6
            layer.lineCap = .round
            stage.addSublayer(layer)
        }
        arc.strokeEnd = 0.3
        applyColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutStage() {
        let scale = window?.backingScaleFactor ?? 2
        for layer in [track, arc] {
            layer.contentsScale = scale
            layer.frame = bounds
            layer.path = CGPath(ellipseIn: bounds.insetBy(dx: 0.8, dy: 0.8), transform: nil)
        }
    }

    private func applyColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.strokeColor = color.withAlphaComponent(0.22).cgColor
        arc.strokeColor = color.cgColor
        CATransaction.commit()
    }

    override func addLoops() {
        guard arc.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        let animation = Self.phased(spin, period: 0.9)
        // A spinner reads as smooth only at the display's rate (it is 11 pt: cheap for the render server).
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        arc.add(animation, forKey: "spin")
    }

    override func removeLoops() {
        arc.removeAnimation(forKey: "spin")
    }
}

// MARK: - Effects

/// A green sheen that sweeps once across a card that just finished.
struct DoneSweep: View {
    let trigger: Int
    let color: Color

    var body: some View {
        Color.clear
            .keyframeAnimator(initialValue: -0.4, trigger: trigger) { content, x in
                content.overlay { DoneSweepBand(x: x, color: color) }
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(-0.4, duration: 0.001)
                    CubicKeyframe(1.15, duration: IslandMotion.t(0.95))
                }
            }
    }
}

/// The sheen at `x` (its center, in card widths; outside -0.35…1.1 nothing is drawn).
struct DoneSweepBand: View {
    let x: CGFloat
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            if x > -0.35, x < 1.1 {
                LinearGradient(stops: [.init(color: color.opacity(0), location: 0),
                                       .init(color: color.opacity(0.24), location: 0.5),
                                       .init(color: color.opacity(0), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: w * 0.45, height: geo.size.height * 2.4)
                    .rotationEffect(.degrees(14))
                    .position(x: w * x, y: geo.size.height / 2)
                    .blendMode(.plusLighter)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The details coming in: they blur and drop in as the card grows over them; going away they fade fast, before
/// the card has shrunk past them.
private struct DetailsReveal: ViewModifier, Animatable {
    var q: Double
    var animatableData: Double {
        get { q }
        set { q = newValue }
    }

    func body(content: Content) -> some View {
        let k = min(max(q, 0), 1)
        content
            .opacity(smoothstep(0, 0.6, k))
            .blur(radius: 6 * CGFloat(1 - smoothstep(0, 0.8, k)))
            .offset(y: -10 * CGFloat(1 - q))
    }
}

extension AnyTransition {
    static var sessionDetails: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: DetailsReveal(q: 0), identity: DetailsReveal(q: 1))
                .animation(.spring(response: 0.36, dampingFraction: 0.9).speed(IslandMotion.speed)),
            removal: .modifier(active: DetailsReveal(q: 0), identity: DetailsReveal(q: 1))
                .animation(.easeOut(duration: 0.13).speed(IslandMotion.speed)))
    }
}
