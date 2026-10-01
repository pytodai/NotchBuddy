import AppKit
import SwiftUI
import NotchBuddyCore

// MARK: - Live indicators

/// What a session is doing, at a glance, in the status color: equalizer bars while it works, a pulsing
/// ring while it waits, a check drawn on when it finishes, a red mark that shakes once on error.
///
/// The glyph swaps inside a fixed square slot (so a status change never moves its neighbours). Repeating
/// animations run in Core Animation with a shared phase (the app does no per-frame work for them);
/// one-shots play once per status episode (`OneShots`).
struct LiveIndicator: View {
    let status: SessionStatus
    var size: CGFloat = 14
    /// `AgentSession.episode` (key and the monotonic start of the status): identifies the status episode for
    /// one-shots, unchanged when the wall clock is set (nil: play on appear).
    var episode: String?
    /// For filmstrips: the session, to look up the status it had before.
    var key: SessionKey?

    @Environment(\.islandFilmTime) private var filmTime
    @Environment(\.islandFilmPreviousStatus) private var previous
    @Environment(\.islandIgniteDelay) private var mountDelay
    @Environment(\.islandReduceMotion) private var reduceMotion
    /// After the first appearance a new glyph is a status change in place: it ignites at once.
    @State private var mounted = false

    static let outCurve = MotionCurve.curve(.easeIn, 0.12)
    static let loopInCurve = MotionCurve.curve(.easeOut, 0.12).delayed(0.05)
    static let popInCurve = MotionCurve.spring(0.30, 0.62).delayed(0.06)

    var body: some View {
        ZStack {
            if let filmTime, let key, let before = previous[key], before != status {
                let out = min(max(Self.outCurve.progress(filmTime), 0), 1)
                glyph(before)
                    .scaleEffect(1 - 0.5 * out)
                    .opacity(1 - out)
                let loop = status == .working || status == .waitingForUser
                let p = (loop ? Self.loopInCurve : Self.popInCurve).progress(filmTime)
                glyph(status)
                    .scaleEffect(loop ? CoreAnimationIgnite.scale(at: filmTime - 0.06) : 0.3 + 0.7 * p)
                    .opacity(min(max(loop ? p : p * 1.6, 0), 1))
            } else {
                glyph(status)
                    .id(status)
                    .transition(reduceMotion ? Self.reducedTransition : Self.transition(for: status))
            }
        }
        .frame(width: size, height: size)
        .environment(\.islandIgniteDelay, mounted ? 0.06 : mountDelay)
        .onAppear { mounted = true }
        .accessibilityLabel(status.label)
    }

    @ViewBuilder
    private func glyph(_ status: SessionStatus) -> some View {
        switch status {
        case .working:
            EqualizerBars(color: status.tint)
                .frame(width: size * 0.92, height: size * 0.82)
        case .waitingForUser:
            WaitingPulse(color: status.tint, size: size)
        case .finished:
            DrawnCheck(color: status.tint, size: size, episode: episode.map { "check:\($0)" })
        case .error:
            ErrorGlyph(size: size, episode: episode.map { "err:\($0)" })
        case .idle:
            Circle()
                .fill(status.tint)
                .frame(width: size * 0.42, height: size * 0.42)
        }
    }

    private static let reducedTransition: AnyTransition = .opacity.animation(.easeInOut(duration: 0.16).speed(IslandMotion.speed))

    private static func transition(for status: SessionStatus) -> AnyTransition {
        let loop = status == .working || status == .waitingForUser
        // Loop glyphs get their scale from the Core Animation ignite (SwiftUI scale does not reach them).
        let insertion: AnyTransition = loop
            ? .opacity.animation(loopInCurve.animation)
            : .scale(scale: 0.3).combined(with: .opacity).animation(IslandMotion.pop.delay(0.06))
        return .asymmetric(insertion: insertion,
                           removal: .scale(scale: 0.5).combined(with: .opacity).animation(outCurve.animation))
    }
}

/// The spring a Core Animation indicator scales in with (also sampled by the filmstrips).
enum CoreAnimationIgnite {
    static let mass: CGFloat = 1
    static let stiffness: CGFloat = 320
    static let damping: CGFloat = 18

    static func scale(at t: Double) -> CGFloat {
        guard t > 0 else { return 0.3 }
        let spring = Spring(mass: Double(mass), stiffness: Double(stiffness), damping: Double(damping))
        return 0.3 + 0.7 * CGFloat(spring.value(target: 1.0, time: t))
    }
}

/// Three bars bouncing out of phase.
struct EqualizerBars: View {
    let color: Color
    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.islandFilmTime) private var filmTime

    var body: some View {
        if staticRender || reduceMotion || filmTime != nil {
            // The resting frame.
            GeometryReader { geo in
                let gap = geo.size.width * 0.16
                let w = (geo.size.width - 2 * gap) / 3
                HStack(spacing: gap) {
                    ForEach(Array([0.55, 1.0, 0.72].enumerated()), id: \.offset) { _, level in
                        Capsule().fill(color).frame(width: w, height: geo.size.height * level)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        } else {
            EqualizerLayer(color: NSColor(color))
        }
    }
}

private struct EqualizerLayer: NSViewRepresentable {
    let color: NSColor

    /// The ignite delay is read once, when the view is made: a later update must not move its start.
    func makeNSView(context: Context) -> EqualizerLayerView {
        let view = EqualizerLayerView()
        view.igniteDelay = context.environment.islandIgniteDelay
        return view
    }

    func updateNSView(_ view: EqualizerLayerView, context: Context) {
        view.color = color
    }
}

/// A layer-backed indicator: sublayers live in `stage`, which scales in once ("ignite") when the view
/// first appears in a window. Loops are added with a global phase (a remounted indicator continues in
/// step), capped at 30 fps, and removed while the window is not visible.
class LoopLayerView: NSView {
    let stage = CALayer()
    var igniteDelay: Double = 0.06
    private var ignited = false
    private var occlusionObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        stage.masksToBounds = false
        stage.speed = Float(IslandMotion.speed)
        layer?.addSublayer(stage)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = bounds
        layoutStage()
        CATransaction.commit()
        if window != nil, !ignited {
            ignited = true
            ignite()
        }
        refreshLoops()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            removeLoops()
            return
        }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLoops() }
        }
        refreshLoops()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    private func refreshLoops() {
        guard let window, window.occlusionState.contains(.visible) else {
            removeLoops()
            return
        }
        addLoops()
    }

    private func ignite() {
        let now = stage.convertTime(CACurrentMediaTime(), from: nil)
        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.3
        scale.toValue = 1
        scale.mass = CoreAnimationIgnite.mass
        scale.stiffness = CoreAnimationIgnite.stiffness
        scale.damping = CoreAnimationIgnite.damping
        scale.duration = scale.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.12
        for animation in [scale, fade] as [CAAnimation] {
            animation.beginTime = now + igniteDelay
            animation.fillMode = .backwards
            stage.add(animation, forKey: animation === scale ? "igniteScale" : "igniteFade")
        }
    }

    /// Global phase: the animation's local time at wall time T is T modulo its period.
    static func phased(_ animation: CAAnimation, period: CFTimeInterval) -> CAAnimation {
        animation.duration = period
        animation.repeatCount = .infinity
        animation.timeOffset = fmod(CACurrentMediaTime(), period)
        animation.isRemovedOnCompletion = false
        // Small, slow motion (14 pt bars, 1.9–2.3 s periods): 30 fps is ~1 px a frame and lets the display
        // idle down while an agent works for an hour. One-shots (`ignite`) keep the native rate.
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        return animation
    }

    func layoutStage() {}
    func addLoops() {}
    func removeLoops() {}
}

final class EqualizerLayerView: LoopLayerView {
    var color: NSColor = .white {
        didSet { if oldValue != color { applyColor() } }
    }

    private let bars = (0..<3).map { _ in CALayer() }
    private static let levels: [[Double]] = [
        [0.35, 0.90, 0.50, 1.00, 0.42, 0.78, 0.35],
        [0.60, 0.30, 1.00, 0.55, 0.85, 0.40, 0.60],
        [0.45, 0.80, 0.38, 0.70, 1.00, 0.50, 0.45],
    ]
    private static let periods: [CFTimeInterval] = [1.9, 2.3, 2.1]

    override init(frame: NSRect) {
        super.init(frame: frame)
        bars.forEach { stage.addSublayer($0) }
        applyColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutStage() {
        let gap = bounds.width * 0.16
        let width = max(1, (bounds.width - 2 * gap) / 3)
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(i) * (width + gap) + width / 2, y: bounds.midY)
            bar.cornerRadius = width / 2
        }
    }

    private func applyColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.forEach { $0.backgroundColor = color.cgColor }
        CATransaction.commit()
    }

    override func addLoops() {
        for (i, bar) in bars.enumerated() where bar.animation(forKey: "level") == nil {
            let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
            a.values = Self.levels[i]
            a.keyTimes = (0..<7).map { NSNumber(value: Double($0) / 6) }
            a.calculationMode = .cubic
            bar.add(Self.phased(a, period: Self.periods[i]), forKey: "level")
        }
    }

    override func removeLoops() {
        bars.forEach { $0.removeAnimation(forKey: "level") }
    }
}

/// A glowing dot with a ring that keeps pulsing out of it.
struct WaitingPulse: View {
    let color: Color
    let size: CGFloat
    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.islandFilmTime) private var filmTime

    var body: some View {
        ZStack {
            if staticRender || reduceMotion || filmTime != nil {
                Circle()
                    .stroke(color.opacity(0.45), lineWidth: 1.2)
                    .frame(width: size * 0.95, height: size * 0.95)
            } else {
                PulseLayer(color: NSColor(color))
                    .frame(width: size * 2.2, height: size * 2.2)
            }
            Circle()
                .fill(color)
                .frame(width: size * 0.5, height: size * 0.5)
        }
        .frame(width: size, height: size)
    }
}

private struct PulseLayer: NSViewRepresentable {
    let color: NSColor

    /// The ignite delay is read once, when the view is made: a later update must not move its start.
    func makeNSView(context: Context) -> PulseLayerView {
        let view = PulseLayerView()
        view.igniteDelay = context.environment.islandIgniteDelay
        return view
    }

    func updateNSView(_ view: PulseLayerView, context: Context) {
        view.color = color
    }
}

final class PulseLayerView: LoopLayerView {
    var color: NSColor = .orange {
        didSet { if oldValue != color { applyColor() } }
    }

    private let ring = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        ring.fillColor = nil
        ring.lineWidth = 1.3
        ring.opacity = 0
        stage.addSublayer(ring)
        applyColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutStage() {
        // A shape layer draws its path at this scale; keep it sharp on Retina screens.
        ring.contentsScale = window?.backingScaleFactor ?? 2
        // The ring starts at the dot's size (a quarter of this view) and grows out of it.
        let base = bounds.width * 0.26
        ring.bounds = CGRect(x: 0, y: 0, width: base, height: base)
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 0.65, dy: 0.65), transform: nil)
    }

    private func applyColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeColor = color.cgColor
        CATransaction.commit()
    }

    override func addLoops() {
        guard ring.animation(forKey: "pulse") == nil else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 3.2
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 0.9, 0.0]
        fade.keyTimes = [0, 0.12, 1]
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(Self.phased(group, period: 1.5), forKey: "pulse")
    }

    override func removeLoops() {
        ring.removeAnimation(forKey: "pulse")
    }
}

/// A check mark stroked on (once per episode), then a small pop.
struct DrawnCheck: View {
    let color: Color
    let size: CGFloat
    var lineWidth: CGFloat?
    var delay: Double = 0.2
    /// One-shot key; nil plays on every appearance.
    var episode: String?

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.islandFilmTime) private var filmTime
    @State private var trigger = 0

    struct Value {
        var trim: CGFloat
        var scale: CGFloat
    }

    static let rest = Value(trim: 1, scale: 1)
    static let start = Value(trim: 0, scale: 1)

    @KeyframesBuilder<Value>
    static func keyframes(delay: Double) -> some Keyframes<Value> {
        KeyframeTrack(\.trim) {
            LinearKeyframe(0, duration: IslandMotion.t(delay))
            LinearKeyframe(1, duration: IslandMotion.t(0.30), timingCurve: IslandMotion.checkCurve)
        }
        KeyframeTrack(\.scale) {
            LinearKeyframe(1, duration: IslandMotion.t(delay + 0.30))
            CubicKeyframe(1.15, duration: IslandMotion.t(0.08))
            SpringKeyframe(1, duration: IslandMotion.t(0.3), spring: IslandMotion.kspring(0.25, 0.55))
        }
    }

    static func value(delay: Double, at t: Double) -> Value {
        KeyframeTimeline(initialValue: start) { keyframes(delay: delay) }.value(time: max(t, 0))
    }

    var body: some View {
        let color = color, size = size, lineWidth = lineWidth
        if let filmTime {
            CheckFace(value: Self.value(delay: delay, at: filmTime), color: color, size: size, lineWidth: lineWidth)
        } else if staticRender || reduceMotion {
            CheckFace(value: Self.rest, color: color, size: size, lineWidth: lineWidth)
        } else {
            let played = episode.map(OneShots.hasPlayed) ?? false
            Color.clear
                .frame(width: size, height: size)
                .keyframeAnimator(initialValue: played ? Self.rest : Self.start, trigger: trigger) { _, value in
                    CheckFace(value: value, color: color, size: size, lineWidth: lineWidth)
                } keyframes: { _ in
                    Self.keyframes(delay: delay)
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

private struct CheckFace: View {
    let value: DrawnCheck.Value
    let color: Color
    let size: CGFloat
    let lineWidth: CGFloat?

    nonisolated init(value: DrawnCheck.Value, color: Color, size: CGFloat, lineWidth: CGFloat?) {
        self.value = value
        self.color = color
        self.size = size
        self.lineWidth = lineWidth
    }

    var body: some View {
        CheckmarkShape()
            .trim(from: 0, to: value.trim)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth ?? max(1.6, size * 0.16), lineCap: .round, lineJoin: .round))
            .frame(width: size * 0.74, height: size * 0.56)
            .scaleEffect(value.scale)
            .frame(width: size, height: size)
    }
}

struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.54))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.37, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

/// Red mark that shakes once per error episode.
struct ErrorGlyph: View {
    let size: CGFloat
    var episode: String?
    var amplitude: CGFloat = 1

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.islandFilmTime) private var filmTime
    @State private var trigger = 0

    @KeyframesBuilder<CGFloat>
    static func keyframes(amplitude a: CGFloat) -> some Keyframes<CGFloat> {
        KeyframeTrack {
            LinearKeyframe(0, duration: IslandMotion.t(0.1))
            CubicKeyframe(-2.5 * a, duration: IslandMotion.t(0.06))
            CubicKeyframe(2.5 * a, duration: IslandMotion.t(0.06))
            CubicKeyframe(-1.8 * a, duration: IslandMotion.t(0.06))
            CubicKeyframe(1.2 * a, duration: IslandMotion.t(0.06))
            CubicKeyframe(-0.6 * a, duration: IslandMotion.t(0.06))
            CubicKeyframe(0, duration: IslandMotion.t(0.06))
        }
    }

    var body: some View {
        if let filmTime {
            glyph.offset(x: KeyframeTimeline(initialValue: CGFloat(0)) { Self.keyframes(amplitude: amplitude) }
                .value(time: max(filmTime, 0)))
        } else if staticRender || reduceMotion {
            glyph
        } else {
            glyph
                .keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { content, x in
                    content.offset(x: x)
                } keyframes: { _ in
                    Self.keyframes(amplitude: amplitude)
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

    private var glyph: some View {
        ZStack {
            Circle().fill(SessionStatus.error.tint)
            Text("!")
                .font(.system(size: size * 0.68, weight: .heavy, design: .rounded))
                .foregroundStyle(.black.opacity(0.85))
                .offset(y: -size * 0.02)
        }
        .frame(width: size * 0.86, height: size * 0.86)
    }
}

// MARK: - Agent mark

/// The agent's real app icon when its app is installed; otherwise a rounded square with a drawn mark
/// (Claude's spark, Codex's prompt, Kimi's letter). The agent's color lives only here; everything else
/// is colored by status.
struct AgentMark: View {
    let source: AgentSource
    var size: CGFloat = 26

    var body: some View {
        if let icon = AgentAppIcon.image(for: source) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size * AgentAppIcon.bodyScale, height: size * AgentAppIcon.bodyScale)
                .frame(width: size, height: size)
                .accessibilityLabel(source.displayName)
        } else {
            drawnMark
        }
    }

    private var drawnMark: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        return shape
            .fill(LinearGradient(colors: [AgentStyle.tint(source), AgentStyle.tintDeep(source)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay { glyph }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.6)
            }
            .frame(width: size, height: size)
            .accessibilityLabel(source.displayName)
    }

    @ViewBuilder
    private var glyph: some View {
        switch source {
        case .claude:
            ClaudeSpark()
                .stroke(AgentStyle.glyphColor(source), style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round))
                .frame(width: size * 0.62, height: size * 0.62)
        case .codex:
            Text(">_")
                .font(.system(size: size * 0.4, weight: .heavy, design: .monospaced))
                .foregroundStyle(AgentStyle.glyphColor(source))
                .offset(x: size * 0.01, y: -size * 0.02)
        case .kimi:
            Text("K")
                .font(.system(size: size * 0.54, weight: .black, design: .rounded))
                .foregroundStyle(AgentStyle.glyphColor(source))
        default:
            Text(AgentCatalog.descriptor(for: source)?.glyph ?? String(source.rawValue.prefix(1)).uppercased())
                .font(.system(size: size * 0.46, weight: .black, design: .rounded))
                .foregroundStyle(AgentStyle.glyphColor(source))
        }
    }
}

/// A burst of rays of alternating length, after Claude's spark.
struct ClaudeSpark: Shape {
    var rays = 10

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var p = Path()
        for i in 0..<rays {
            let angle = Double(i) / Double(rays) * 2 * .pi - .pi / 2 + 0.12
            let outer = radius * (i.isMultiple(of: 2) ? 1.0 : 0.8)
            let inner = radius * 0.16
            p.move(to: CGPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
            p.addLine(to: CGPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
        }
        return p
    }
}

// MARK: - Small pieces

/// Status in a tinted capsule, with its live indicator.
struct StatusPill: View {
    let session: AgentSession

    var body: some View {
        let tint = session.status.tint
        HStack(spacing: 5) {
            LiveIndicator(status: session.status, size: 11, episode: session.episode, key: session.key)
            Text(session.status.label)
                .font(.manrope(11, weight: 680))
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.interpolate)
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 20)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.2), lineWidth: 0.5))
    }
}

/// "+2": more sessions than the collapsed island shows.
struct OthersBadge: View {
    let count: Int
    var fontSize: CGFloat = 12.5

    var body: some View {
        Text("+\(count)")
            .font(.manrope(fontSize, weight: 580, tabular: true))
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(0.86))
            .contentTransition(.numericText(value: Double(count)))
            .animation(IslandMotion.leaf, value: count)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(Color.white.opacity(0.13)))
    }
}

/// Keyboard shortcut hint drawn inside a button ("⌘Y"). Hidden (its width kept) while the shortcut is not
/// live: the permission card has the keyboard only while the pointer is over it.
struct KeyHint: View {
    let text: String
    var active = true

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.primary.opacity(0.16)))
            .opacity(active ? 0.95 : 0)
            .animation(.easeOut(duration: 0.15).speed(IslandMotion.speed), value: active)
    }
}

/// Button look for the island's controls.
struct IslandButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive, ghost }
    var kind: Kind
    var height: CGFloat = 30
    /// Stretch to share the row with sibling buttons (ghost buttons always hug their label).
    var stretches = true
    /// Primary only: how far a not-yet-armed button has filled (nil = armed).
    var arming: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        IslandButtonBody(configuration: configuration, kind: kind, height: height,
                         stretches: stretches && kind != .ghost, arming: arming)
    }
}

private struct IslandButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: IslandButtonStyle.Kind
    let height: CGFloat
    let stretches: Bool
    let arming: CGFloat?
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: height * 0.36, style: .continuous)
        let armed = arming == nil
        let settle = Animation.easeOut(duration: 0.18).speed(IslandMotion.speed)
        configuration.label
            .font(.manrope(12.5, weight: 680))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .environment(\.islandInk, foreground)
            .environment(\.nbControlHovered, hovering && armed)
            .opacity(armed ? 1 : 0.45 + 0.35 * Double(arming ?? 0))
            .animation(settle, value: armed)
            .padding(.horizontal, stretches ? 10 : 14)
            .frame(height: height)
            .frame(maxWidth: stretches ? .infinity : nil)
            .fixedSize(horizontal: !stretches, vertical: false)
            .background {
                ZStack(alignment: .leading) {
                    shape.fill(background)
                        .opacity(armed ? 1 : 0)
                    if kind == .primary {
                        // Not armed yet: the fill sweeps across once (an animatable shape, no layout per
                        // frame), then gives way to the solid button.
                        ZStack(alignment: .leading) {
                            shape.fill(Color.white.opacity(0.38))
                            ArmingFill(fraction: min(max(arming ?? 1, 0), 1))
                                .fill(Color.white.opacity(0.72))
                                .clipShape(shape)
                        }
                        .opacity(armed ? 0 : 1)
                    }
                }
                .animation(settle, value: armed)
            }
            .overlay(shape.strokeBorder(border, lineWidth: 0.5))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(IslandMotion.press.animation, value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12).speed(IslandMotion.speed), value: hovering)
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .black
        case .secondary: return .white
        case .destructive: return IslandPalette.danger
        case .ghost: return hovering ? .white : IslandPalette.secondary
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return hovering ? Color(white: 0.88) : .white
        case .secondary: return .white.opacity(hovering ? 0.19 : 0.12)
        case .destructive: return IslandPalette.danger.opacity(hovering ? 0.24 : 0.15)
        case .ghost: return .white.opacity(hovering ? 0.1 : 0)
        }
    }

    private var border: Color {
        switch kind {
        case .primary, .ghost: return .clear
        case .secondary: return .white.opacity(0.08)
        case .destructive: return IslandPalette.danger.opacity(0.2)
        }
    }
}

/// The arming sweep of "Разрешить": a rect from the leading edge, `fraction` of the width.
struct ArmingFill: Shape {
    var fraction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width * min(max(fraction, 0), 1), height: rect.height))
    }
}

/// Round icon button (pin, remove).
struct IslandIconButtonStyle: ButtonStyle {
    var size: CGFloat = 24
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, active: active)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let active: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.manrope(size * 0.44, weight: 760))
            .foregroundStyle(active || hovering ? Color.white : IslandPalette.secondary)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white.opacity(active ? 0.2 : hovering ? 0.16 : 0.09)))
            .animation(IslandMotion.leaf, value: active)
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(IslandMotion.press.animation, value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12).speed(IslandMotion.speed), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// A round header button with an icon from the set (⚙️, 🔊, 📌): the icon plays its gesture while the button is
/// hovered (the gear turns a tooth, the pin tilts, the waves pulse), the button squishes under the mouse and never
/// takes keyboard focus.
struct IslandGlyphButton: View {
    let icon: NBIcon
    var value: Double?
    var active = false
    var size: CGFloat = 26
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            NBIconView(icon, size: size * 0.6, color: active || hovering ? .white : IslandPalette.secondary,
                       value: value, active: hovering)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(active ? 0.2 : hovering ? 0.15 : 0.08)))
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.14).speed(IslandMotion.speed), value: hovering)
                .animation(IslandMotion.leaf, value: active)
        }
        .buttonStyle(SquishButtonStyle(amount: 0.12))
        .focusable(false)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
