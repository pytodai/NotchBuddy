import SwiftUI
import NotchBuddyCore

// MARK: - Ring

/// A countdown ring that sweeps smoothly between the store's ticks.
///
/// The store ticks only when a shown second changes; at each tick the ring animates *linearly* to where it will
/// be at the next tick, over exactly that time, so it moves continuously and is never late (no per-frame work in
/// the store). A small ring (the closed island, shown for hours) steps with a short ease instead, so the display
/// can idle between seconds. Jumps (+1 мин, restart, pause) settle with a spring.
struct TimerRing: View {
    let timer: TimerItem
    let now: Moment
    let tint: GadgetTint
    var size: CGFloat = 92
    var lineWidth: CGFloat = 7
    /// Linear sweep between ticks (false: a short ease on each tick).
    var smooth = true
    var showsHead = true
    /// Show only the last `window` seconds as a full ring (the finale's inner ring).
    var window: TimeInterval?

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandFilmTime) private var filmTime
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var shown: Double?

    private func fraction(at moment: Moment) -> Double {
        guard let window, window > 0 else { return timer.fractionRemaining(at: moment) }
        return min(max(timer.remaining(at: moment) / window, 0), 1)
    }

    var body: some View {
        let current = fraction(at: now)
        Color.clear
            .modifier(TimerRingFace(fraction: staticRender || filmTime != nil ? current : (shown ?? current),
                                    tint: tint, size: size, lineWidth: lineWidth, head: showsHead,
                                    glow: timer.isRunning))
            .frame(width: size, height: size)
            .onAppear { advance(jump: false) }
            .onChange(of: now) { advance(jump: false) }
            .onChange(of: timer.state) { advance(jump: true) }
            .onChange(of: timer.duration) { advance(jump: true) }
    }

    private func advance(jump: Bool) {
        guard !staticRender, filmTime == nil else { return }
        let current = fraction(at: now)
        guard timer.isRunning, !reduceMotion else {
            withAnimation(reduceMotion ? GadgetMotion.fade : GadgetMotion.settle) { shown = current }
            return
        }
        if jump || shown == nil || abs((shown ?? current) - current) > 0.03 {
            if shown == nil {
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { shown = current }
            } else {
                withAnimation(GadgetMotion.settle) { shown = current }
                return
            }
        }
        let left = timer.remaining(at: now)
        let step = min(TimerFormat.untilNextSecond(left), max(left, 0.001))
        let ahead = fraction(at: now.advanced(by: step))
        // Real time: the sweep is the countdown itself, never slowed down with the island.
        withAnimation(smooth ? .linear(duration: step) : .easeOut(duration: min(0.35, step))) { shown = ahead }
    }
}

/// The ring at `fraction` (1 full … 0 empty): a track, the remaining arc from the head (bright, leading
/// clockwise) back to 12 o'clock (deep), a round tail, and a glowing head.
struct TimerRingFace: ViewModifier, Animatable {
    var fraction: Double
    let tint: GadgetTint
    let size: CGFloat
    let lineWidth: CGFloat
    let head: Bool
    var glow = true

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func body(content: Content) -> some View {
        let f = min(max(fraction, 0), 1)
        let start = 1 - f
        let radius = (size - lineWidth) / 2
        ZStack {
            Circle()
                .stroke(TimerPalette.track, lineWidth: lineWidth)
                .frame(width: size - lineWidth, height: size - lineWidth)
            if f > 0.0005 {
                // A flat arc: no bloom, no gradient (the head alone marks where it is).
                Circle()
                    .trim(from: start, to: 1)
                    .stroke(tint.hi, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .frame(width: size - lineWidth, height: size - lineWidth)
                // Round tail at 12 o'clock.
                Circle()
                    .fill(tint.lo)
                    .frame(width: lineWidth, height: lineWidth)
                    .offset(x: radius)
                if head {
                    ZStack {
                        Circle().fill(tint.hi)
                            .frame(width: lineWidth, height: lineWidth)
                        Circle().fill(Color.black.opacity(0.55))
                            .frame(width: lineWidth * 0.4, height: lineWidth * 0.4)
                    }
                    .offset(x: radius)
                    .rotationEffect(.degrees(360 * start))
                }
            }
        }
        .rotationEffect(.degrees(-90))
        .frame(width: size, height: size)
    }
}

/// Sixty marks around the inside of a dial; the five-minute ones longer.
struct DialTicks: Shape {
    var inset: CGFloat
    var count = 60

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2 - inset
        for i in 0..<count {
            let major = i % 5 == 0
            let a = Double(i) / Double(count) * 2 * .pi - .pi / 2
            let inner = outer - (major ? 4.5 : 2.2)
            p.move(to: CGPoint(x: c.x + outer * cos(a), y: c.y + outer * sin(a)))
            p.addLine(to: CGPoint(x: c.x + inner * cos(a), y: c.y + inner * sin(a)))
        }
        return p
    }
}

// MARK: - Dial

/// The big dial of the widget: ticks, the ring and the time inside it. The last ten seconds turn it urgent
/// (red, a heartbeat each second); a paused timer's time breathes.
struct TimerDial: View {
    let timer: TimerItem
    let now: Moment
    let tint: GadgetTint
    var size: CGFloat = 96
    var lineWidth: CGFloat = 7.5

    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        let seconds = timer.displaySeconds(at: now)
        let urgent = timer.isRunning && seconds <= 10
        let tint = urgent ? TimerPalette.urgent : (timer.isRunning ? self.tint : TimerPalette.paused)
        let still = reduceMotion
        ZStack {
            if urgent {
                // A red heartbeat behind the dial, once a second.
                // A thin red ring beats once a second around the dial (no glow).
                Circle()
                    .stroke(TimerPalette.urgent.hi.opacity(0.5), lineWidth: 1)
                    .frame(width: size * 1.08, height: size * 1.08)
                    .keyframeAnimator(initialValue: RippleValue(scale: 1, opacity: 0.5), trigger: seconds) { content, v in
                        content.scaleEffect(still ? 1 : v.scale).opacity(v.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            CubicKeyframe(1.08, duration: IslandMotion.t(0.12))
                            CubicKeyframe(0.94, duration: IslandMotion.t(0.7))
                        }
                        KeyframeTrack(\.opacity) {
                            CubicKeyframe(1, duration: IslandMotion.t(0.12))
                            CubicKeyframe(0.35, duration: IslandMotion.t(0.7))
                        }
                    }
                    .transition(.opacity.animation(GadgetMotion.fade))
            }
            DialTicks(inset: lineWidth + 3.5)
                .stroke(Color.white.opacity(0.13), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .opacity(urgent ? 0 : 1)
            if urgent {
                // The finale: the last ten seconds as a ring of their own, inside.
                TimerRing(timer: timer, now: now, tint: TimerPalette.urgent, size: size - 2 * lineWidth - 5,
                          lineWidth: 2.6, window: 10)
                    .transition(.scale(scale: 1.15).combined(with: .opacity).animation(GadgetMotion.bouncy))
            }
            TimerRing(timer: timer, now: now, tint: tint, size: size, lineWidth: lineWidth)
            VStack(spacing: 1) {
                TimerDigits(seconds: seconds, size: seconds >= 3600 ? size * 0.16 : size * 0.215, urgent: urgent)
                    .modifier(Breathing(active: timer.isPaused))
                Text(timer.isPaused ? L("пауза") : L("из %@", TimerFormat.length(timer.duration)))
                    .font(GadgetFont.font(size * 0.1, .semibold))
                    .foregroundStyle(timer.isPaused ? TimerPalette.paused.hi.opacity(0.8) : IslandPalette.tertiary)
                    .contentTransition(.interpolate)
                    .animation(GadgetMotion.fade, value: timer.isPaused)
                    .lineLimit(1)
            }
            .offset(y: size * 0.02)
        }
        .frame(width: size, height: size)
        .animation(GadgetMotion.fade, value: urgent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("%@: осталось %@%@", L(timer.label), TimerFormat.clock(seconds), timer.isPaused ? L(", пауза") : ""))
    }
}

/// "24:13" rolling down a digit at a time; in the last ten seconds every second gives a small heartbeat.
struct TimerDigits: View {
    let seconds: Int
    let size: CGFloat
    var urgent = false
    var weight: Font.Weight = .bold
    var color: Color = .white

    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        let still = reduceMotion
        return Text(TimerFormat.clock(seconds))
            .font(GadgetFont.font(size, weight))
            .monospacedDigit()
            .foregroundStyle(urgent ? TimerPalette.urgent.hi : color)
            .contentTransition(.numericText(countsDown: true))
            .animation(GadgetMotion.digits, value: seconds)
            .lineLimit(1)
            .fixedSize()
            .keyframeAnimator(initialValue: CGFloat(1), trigger: urgent ? seconds : -1) { content, scale in
                content.scaleEffect(still ? 1 : scale)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(urgent ? 1.12 : 1, duration: IslandMotion.t(0.09))
                    SpringKeyframe(1, duration: IslandMotion.t(0.35), spring: IslandMotion.kspring(0.3, 0.5))
                }
            }
    }
}

/// A paused countdown's time softly fades in and out (Reduce Motion: it just dims). In the closed island, which
/// can show it for hours, pass `cycles`: it breathes a few times and rests dimmed (no endless per-frame work).
struct Breathing: ViewModifier {
    let active: Bool
    /// Odd, so the last cycle ends dimmed; nil breathes for as long as it is shown.
    var cycles: Int?
    var low: Double = 0.4

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(active ? (reduceMotion || staticRender ? 0.6 : (dim ? low : 1)) : 1)
            .onAppear { restart() }
            .onChange(of: active) { restart() }
    }

    private func restart() {
        guard active, !reduceMotion, !staticRender else {
            withAnimation(GadgetMotion.fade) { dim = false }
            return
        }
        dim = false
        let base = Animation.easeInOut(duration: 1.1)
        let animation = cycles.map { base.repeatCount(max(1, $0 | 1), autoreverses: true) } ?? base.repeatForever(autoreverses: true)
        withAnimation(animation.speed(IslandMotion.speed)) { dim = true }
    }
}

// MARK: - Celebration

/// A timer ending: the ring closes in green, a flash and a shock wave leave it, sparks fly out and a check is
/// drawn in the middle. Time-driven (`t` seconds since the end), so filmstrips draw any frame of it; live it runs
/// on a `TimelineView` for its 1.6 s and then rests. Reduce Motion: the ring and check fade in.
struct TimerCelebration: View {
    var size: CGFloat = 96
    var lineWidth: CGFloat = 7.5
    /// Sparks and shock wave (the settings' "Празднование").
    var bursts = true
    /// Keys the one-shot (a finish id); nil plays on every appearance.
    var episode: String?

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandFilmTime) private var filmTime
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var start: Date?

    static let length: Double = 1.6

    var body: some View {
        Group {
            if let filmTime {
                TimerCelebrationFrame(t: filmTime, size: size, lineWidth: lineWidth, bursts: bursts)
            } else if staticRender || reduceMotion || start == nil {
                TimerCelebrationFrame(t: staticRender || reduceMotion || start == nil && played ? Self.length : 0,
                                      size: size, lineWidth: lineWidth, bursts: bursts && !reduceMotion)
            } else if let start {
                TimelineView(.animation(minimumInterval: nil, paused: false)) { context in
                    let t = context.date.timeIntervalSince(start) / IslandMotion.slowmo
                    TimerCelebrationFrame(t: min(t, Self.length), size: size, lineWidth: lineWidth, bursts: bursts)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard filmTime == nil, !staticRender, !reduceMotion else { return }
            if let episode, !OneShots.claim("timer-done:\(episode)") { return }
            start = Date()
            // Stop the timeline once the burst has settled.
            Task { @MainActor in
                try? await Task.sleep(for: IslandMotion.delay(Self.length + 0.1))
                start = nil
            }
        }
    }

    private var played: Bool { episode.map { OneShots.hasPlayed("timer-done:\($0)") } ?? false }
}

/// One frame of the celebration, `t` seconds in.
struct TimerCelebrationFrame: View {
    let t: Double
    let size: CGFloat
    let lineWidth: CGFloat
    var bursts = true

    private static let sparkColors: [Color] = [
        TimerPalette.done.hi, Color(red: 1.0, green: 0.86, blue: 0.4), TimerPalette.aqua.hi, TimerPalette.rose.hi,
        TimerPalette.lime.hi, .white,
    ]

    var body: some View {
        let close = ease(t / 0.34)                     // ring closes
        let flash = bell((t - 0.30) / 0.36)            // inner flash
        let wave = ease((t - 0.30) / 0.62)             // shock wave
        let check = ease((t - 0.42) / 0.30)            // check drawn
        let pop = t < 0.72 ? 1 + 0.18 * bell((t - 0.62) / 0.2) : 1.0
        let ringPop = 1 + 0.07 * bell((t - 0.26) / 0.34)
        let radius = (size - lineWidth) / 2
        ZStack {
            Circle()
                .stroke(TimerPalette.track, lineWidth: lineWidth)
                .frame(width: size - lineWidth, height: size - lineWidth)
            Circle()
                .fill(TimerPalette.done.hi.opacity(0.14 * flash + 0.05 * check))
            Circle()
                .trim(from: 0, to: close)
                .stroke(TimerPalette.done.hi, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: size - lineWidth, height: size - lineWidth)
                .scaleEffect(ringPop)
            if bursts {
                Circle()
                    .stroke(TimerPalette.done.hi.opacity(0.7 * (1 - wave)), lineWidth: max(0.5, lineWidth * 0.5 * (1 - wave)))
                    .frame(width: (size - lineWidth) * (1 + 0.55 * wave), height: (size - lineWidth) * (1 + 0.55 * wave))
                    .opacity(t > 0.3 ? 1 : 0)
                Canvas { context, canvas in
                    let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                    let p = min(max((t - 0.32) / 1.1, 0), 1)
                    guard p > 0, p < 1 else { return }
                    let travel = 1 - pow(1 - p, 3)
                    for i in 0..<20 {
                        let seed = Double(i)
                        let angle = seed / 20 * 2 * .pi + 0.37 * sin(seed * 12.9898)
                        let reach = radius * (0.95 + 0.75 * (0.5 + 0.5 * sin(seed * 78.233))) * CGFloat(travel)
                        let from = radius * 0.92
                        let point = CGPoint(x: c.x + (from + reach * 0.62) * cos(angle), y: c.y + (from + reach * 0.62) * sin(angle) + 6 * p * p)
                        let fade = 1 - pow(p, 1.6)
                        let color = Self.sparkColors[i % Self.sparkColors.count].opacity(fade)
                        let s = CGFloat(i % 3 == 0 ? 5.5 : 3.2) * CGFloat(1 - 0.5 * p) * size / 96
                        if i % 3 == 0 {
                            let star = GadgetGlyphFill(glyph: .sparkle).path(in: CGRect(x: point.x - s, y: point.y - s, width: 2 * s, height: 2 * s))
                            context.fill(star, with: .color(color))
                        } else {
                            context.fill(Path(ellipseIn: CGRect(x: point.x - s / 2, y: point.y - s / 2, width: s, height: s)), with: .color(color))
                        }
                    }
                }
                .frame(width: size * 1.9, height: size * 1.9)
                .allowsHitTesting(false)
            }
            CheckmarkShape()
                .trim(from: 0, to: check)
                .stroke(Color.white, style: StrokeStyle(lineWidth: max(2, size * 0.055), lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.3, height: size * 0.22)
                .scaleEffect(pop)
        }
        .frame(width: size, height: size)
    }

    private func ease(_ x: Double) -> Double {
        let k = min(max(x, 0), 1)
        return 1 - pow(1 - k, 3)
    }

    /// 0 → 1 → 0 over x in 0…1.
    private func bell(_ x: Double) -> Double {
        guard x > 0, x < 1 else { return 0 }
        return sin(x * .pi)
    }
}
