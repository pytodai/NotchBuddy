import SwiftUI
import NotchBuddyCore

// MARK: - Arc gauge

/// A 240° gauge: a track with ticks, a gradient arc (low end deep, high end bright — its color says the level),
/// a bloom under it and a glowing cap. It sweeps up from zero once when it appears, then follows the value on
/// a soft spring; the number in the middle rolls.
struct ArcGauge<Center: View>: View {
    let value: Double
    let tint: GadgetTint
    var size: CGFloat = 78
    var lineWidth: CGFloat = 4
    /// The first appearance sweeps from zero after this delay.
    var delay: Double = 0.1
    /// The middle, given the arc's current (animated) value, so a number can count up with the sweep.
    @ViewBuilder let center: (Double) -> Center

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandFilmTime) private var filmTime
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var shown: Double?

    var body: some View {
        let target = min(max(value.isFinite ? value : 0, 0), 1)
        let current: Double = {
            if let filmTime { return target * min(max(Spring(response: 0.9, dampingRatio: 0.82).value(target: 1.0, time: max(filmTime - delay, 0)), 0), 1.1) }
            if staticRender { return target }
            return shown ?? 0
        }()
        ZStack {
            GaugeTicks(sweep: ArcGaugeFace.sweep, inset: lineWidth + 3)
                .stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            Color.clear.modifier(ArcGaugeFace(fraction: current, tint: tint, size: size, lineWidth: lineWidth))
            center(current)
                .offset(y: size * 0.04)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard filmTime == nil, !staticRender, shown == nil else { return }
            if reduceMotion {
                shown = target
            } else {
                shown = 0
                withAnimation(GadgetMotion.gauge.delay(delay)) { shown = target }
            }
        }
        .onChange(of: target) { _, new in
            withAnimation(reduceMotion ? GadgetMotion.fade : GadgetMotion.gauge) { shown = new }
        }
    }
}

struct ArcGaugeFace: ViewModifier, Animatable {
    var fraction: Double
    let tint: GadgetTint
    let size: CGFloat
    let lineWidth: CGFloat

    static let sweep: Double = 240
    /// Where the arc starts (degrees, 0 = 3 o'clock, clockwise): the lower left.
    static let start: Double = 150

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func body(content: Content) -> some View {
        let f = min(max(fraction, 0), 1.08)
        let span = Self.sweep / 360
        let d = size - lineWidth
        let radius = d / 2
        ZStack {
            Circle()
                .trim(from: 0, to: span)
                .stroke(TimerPalette.track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .frame(width: d, height: d)
            if f > 0.002 {
                // A thin flat arc in the level's color (white unless the value needs attention): no bloom, no cap glow.
                Circle()
                    .trim(from: 0, to: span * min(f, 1))
                    .stroke(tint.hi, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .frame(width: d, height: d)
            }
        }
        .rotationEffect(.degrees(Self.start))
        .frame(width: size, height: size)
    }
}

/// Ticks every 10 % around a gauge's sweep.
struct GaugeTicks: Shape {
    let sweep: Double
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2 - inset
        for i in 0...20 {
            let major = i % 5 == 0
            let a = (ArcGaugeFace.start + sweep * Double(i) / 20) * .pi / 180
            let inner = outer - (major ? 4 : 2)
            p.move(to: CGPoint(x: c.x + outer * cos(a), y: c.y + outer * sin(a)))
            p.addLine(to: CGPoint(x: c.x + inner * cos(a), y: c.y + inner * sin(a)))
        }
        return p
    }
}

/// A number that follows an animated value frame by frame (a gauge counting up as it sweeps).
struct GaugeValueText: View, Animatable {
    var value: Double
    let format: (Double) -> String
    var size: CGFloat = 16

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        let text = format(min(max(value, 0), 1))
        Text(text)
            .font(GadgetFont.font(text.count > 6 ? size * 0.84 : size, .heavy))
            .monospacedDigit()
            .foregroundStyle(IslandPalette.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

// MARK: - Battery

/// A battery drawn like the menu bar's, large: a rounded body, a cap, and a fill in the level's color. While it
/// charges the fill's top edge is a gentle wave and a bolt shimmers in the middle; a low battery pulses.
struct BatteryGlyph: View {
    let state: BatteryState?
    var width: CGFloat = 84
    var height: CGFloat = 40
    var threshold = 20
    /// Show the bolt / plug mark on power.
    var showsMark = true

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandFilmTime) private var filmTime
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var shown: Double?

    var body: some View {
        let level = Double(state?.percent ?? 0) / 100
        let tint = SystemPalette.battery(state, threshold: threshold)
        let charging = state?.phase == .charging
        let low = !(state?.onAC ?? true) && (state?.percent ?? 100) <= threshold
        let current: Double = staticRender || filmTime != nil ? level : (shown ?? 0)
        let radius = height * 0.3
        let body = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let inset = max(2.5, height * 0.085)
        HStack(spacing: height * 0.06) {
            ZStack(alignment: .leading) {
                body.fill(Color.white.opacity(0.06))
                body.strokeBorder(Color.white.opacity(0.32), lineWidth: max(1.2, height * 0.045))
                Group {
                    if charging && !staticRender && !reduceMotion && filmTime == nil {
                        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { context in
                            BatteryFill(level: current, phase: context.date.timeIntervalSinceReferenceDate / IslandMotion.slowmo,
                                        wave: 1, tint: tint)
                        }
                    } else {
                        BatteryFill(level: current, phase: filmTime ?? 0.6, wave: charging ? 1 : 0, tint: tint)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: radius - inset * 0.8, style: .continuous))
                .padding(inset)
                .modifier(Breathing(active: low && (state?.percent ?? 100) <= 10, cycles: 7, low: 0.45))
                if showsMark, let state, state.onAC {
                    GadgetIcon(glyph: charging ? .bolt : .plug, size: height * 0.62, color: .white, weight: 2.4)
                        .shadow(color: .black.opacity(0.45), radius: 2)
                        .overlay {
                            if charging { BoltShimmer(size: height * 0.62) }
                        }
                        .frame(maxWidth: .infinity)
                        .transition(.scale(scale: 0.3).combined(with: .opacity).animation(GadgetMotion.bouncy))
                }
            }
            .frame(width: width, height: height)
            RoundedRectangle(cornerRadius: height * 0.08, style: .continuous)
                .fill(Color.white.opacity(0.32))
                .frame(width: max(2.5, height * 0.09), height: height * 0.36)
        }
        .onAppear {
            guard filmTime == nil, !staticRender, shown == nil else { return }
            if reduceMotion { shown = level } else {
                shown = 0
                withAnimation(GadgetMotion.gauge.delay(0.1)) { shown = level }
            }
        }
        .onChange(of: level) { _, new in withAnimation(GadgetMotion.gauge) { shown = new } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Батарея %@ %%", state?.percent ?? 0))
    }
}

/// The battery's fill: a gradient block `level` wide with a wavy leading edge while charging.
private struct BatteryFill: View {
    let level: Double
    let phase: Double
    let wave: Double
    let tint: GadgetTint

    var body: some View {
        GeometryReader { geo in
            BatteryFillShape(level: level, phase: phase, amplitude: wave * min(2.2, geo.size.width * 0.03))
                .fill(tint.hi)
        }
    }
}

private struct BatteryFillShape: Shape {
    var level: Double
    var phase: Double
    var amplitude: CGFloat

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width * CGFloat(min(max(level, 0), 1))
        guard w > 0.5 else { return Path() }
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        guard amplitude > 0.01 else {
            p.addRect(CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height))
            return p
        }
        // The leading edge ripples as a vertical wave.
        let steps = 16
        p.addLine(to: CGPoint(x: rect.minX + w + amplitude * CGFloat(sin(phase * 3.2)), y: rect.minY))
        for i in 1...steps {
            let y = rect.minY + rect.height * CGFloat(i) / CGFloat(steps)
            let x = rect.minX + w + amplitude * CGFloat(sin(phase * 3.2 + Double(i) / Double(steps) * 2 * .pi))
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// A light sweeping over the bolt every couple of seconds.
private struct BoltShimmer: View {
    let size: CGFloat
    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        if staticRender || reduceMotion {
            EmptyView()
        } else {
            LinearGradient(colors: [.clear, .white.opacity(0.95), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: size * 0.5)
                .offset(x: sweep ? size : -size)
                .mask(GadgetIcon(glyph: .bolt, size: size, color: .white))
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.3).delay(0.4).repeatForever(autoreverses: false).speed(IslandMotion.speed)) {
                        sweep = true
                    }
                }
        }
    }
}

// MARK: - Sparkline

/// The last minute of CPU load as a smooth line over a soft area; the newest point glows. Each new sample
/// slides the whole line one step left.
struct Sparkline: View {
    let values: [Double]
    /// Counts samples: a change slides the line.
    let tick: Int
    var capacity = SystemMonitor.historyLength
    let tint: GadgetTint

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var shift: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let step = geo.size.width / CGFloat(max(capacity - 1, 1))
            let points = Self.points(values, capacity: capacity, size: geo.size, step: step, shift: shift * step)
            ZStack {
                // Grid: 50 % line.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height * 0.5))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height * 0.5))
                }
                .stroke(Color.white.opacity(0.07), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                if points.count > 1 {
                    Self.area(points, height: geo.size.height)
                        .fill(tint.hi.opacity(0.08))
                    Self.line(points)
                        .stroke(tint.hi, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
                if let last = points.last {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 4, height: 4)
                        .position(last)
                }
            }
            .clipShape(Rectangle().inset(by: -4))
        }
        .onChange(of: tick) {
            guard !staticRender, !reduceMotion else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { shift = 1 }
            withAnimation(.easeInOut(duration: 0.9).speed(IslandMotion.speed)) { shift = 0 }
        }
    }

    static func points(_ values: [Double], capacity: Int, size: CGSize, step: CGFloat, shift: CGFloat) -> [CGPoint] {
        let recent = values.suffix(capacity)
        let n = recent.count
        return recent.enumerated().map { i, v in
            let x = size.width - CGFloat(n - 1 - i) * step + shift
            let y = size.height - CGFloat(min(max(v, 0), 1)) * (size.height - 4) - 2
            return CGPoint(x: x, y: y)
        }
    }

    /// Catmull-Rom through the points.
    static func line(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        for i in 1..<pts.count {
            let p0 = pts[max(i - 2, 0)], p1 = pts[i - 1], p2 = pts[i], p3 = pts[min(i + 1, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            p.addCurve(to: p2, control1: c1, control2: c2)
        }
        return p
    }

    static func area(_ pts: [CGPoint], height: CGFloat) -> Path {
        var p = line(pts)
        guard let first = pts.first, let last = pts.last else { return p }
        p.addLine(to: CGPoint(x: last.x, y: height))
        p.addLine(to: CGPoint(x: first.x, y: height))
        p.closeSubpath()
        return p
    }
}
