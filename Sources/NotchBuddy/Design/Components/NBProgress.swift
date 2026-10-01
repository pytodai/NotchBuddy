import SwiftUI
import NotchBuddyCore

/// Progress bar: the fill springs to its value with a glowing head; `active` sends a light band along
/// the fill (something is still happening; a Core Animation loop, no per-frame app work). Fill color follows `accent`, or the usage thresholds
/// (`NBAccent.usage`) when `accent` is nil.
///
/// ```swift
/// NBProgressBar(value: 0.42)                          // usage: calm / amber / red by level
/// NBProgressBar(value: p, accent: .working, active: true)
/// ```
struct NBProgressBar: View {
    var value: Double
    var accent: NBAccent?
    var height: CGFloat = 6
    var active = false
    /// Tick marks at these fractions (e.g. the 80 % warning line).
    var marks: [Double] = []

    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.nbLoopsPaused) private var loopsPaused

    var body: some View {
        let v = NBMath.clamp01(value)
        let tint = accent ?? NBAccent.usage(v)
        NBProgressBarBody(fraction: v, tint: tint, height: height, marks: marks,
                          shimmer: active && !reduceMotion && !staticRender && !loopsPaused)
            .frame(height: height)
            .animation(NBMotion.animation(NBMotion.fill, reduced: reduceMotion), value: v)
            .animation(NBMotion.animation(NBMotion.fade, reduced: reduceMotion), value: tint.id)
            .accessibilityElement()
            .accessibilityValue(L("%@\u{00A0}%%", Int((v * 100).rounded())))
    }
}

private struct NBProgressBarBody: View, Animatable {
    var fraction: Double
    let tint: NBAccent
    let height: CGFloat
    let marks: [Double]
    let shimmer: Bool

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fillWidth = max(fraction > 0.001 ? height : 0, w * CGFloat(fraction))
            let track = Capsule(style: .continuous)
            ZStack(alignment: .leading) {
                track.fill(NBColor.well)
                    .overlay(track.strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
                ForEach(marks, id: \.self) { mark in
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 1, height: height)
                        .offset(x: w * CGFloat(mark))
                }
                ZStack {
                    track.fill(tint.sweep)
                    track.fill(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0)],
                                              startPoint: .top, endPoint: .center))
                    if shimmer {
                        NBShimmerLayer()
                    }
                }
                .frame(width: fillWidth)
                .shadow(color: tint.base.opacity(0.55), radius: height * 0.9)
                // Glowing head.
                if fraction > 0.02 {
                    Circle()
                        .fill(tint.bright)
                        .frame(width: height * 0.7, height: height * 0.7)
                        .shadow(color: tint.bright, radius: height * 0.8)
                        .offset(x: fillWidth - height * 0.85)
                }
            }
        }
    }
}

/// Progress ring: an angular-gradient arc with rounded caps and a glowing head dot; the value springs.
/// Put a label inside with the trailing closure.
///
/// ```swift
/// NBProgressRing(value: 0.42, lineWidth: 3) { Text("42").font(.nbNumeric(9)) }
/// ```
struct NBProgressRing<Label: View>: View {
    var value: Double
    var accent: NBAccent?
    var lineWidth: CGFloat = 3
    var size: CGFloat = 28
    @ViewBuilder var label: () -> Label

    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        let v = NBMath.clamp01(value)
        let tint = accent ?? NBAccent.usage(v)
        ZStack {
            NBRingShape(fraction: v, lineWidth: lineWidth, tint: tint)
            label()
        }
        .frame(width: size, height: size)
        .animation(NBMotion.animation(NBMotion.fill, reduced: reduceMotion), value: v)
    }
}

extension NBProgressRing where Label == EmptyView {
    init(value: Double, accent: NBAccent? = nil, lineWidth: CGFloat = 3, size: CGFloat = 28) {
        self.init(value: value, accent: accent, lineWidth: lineWidth, size: size) { EmptyView() }
    }
}

private struct NBRingShape: View, Animatable {
    var fraction: Double
    let lineWidth: CGFloat
    let tint: NBAccent

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let r = (side - lineWidth) / 2
            let f = CGFloat(NBMath.clamp01(fraction))
            ZStack {
                Circle()
                    .stroke(NBColor.well, lineWidth: lineWidth)
                Circle()
                    .stroke(Color.white.opacity(0.06), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: f)
                    .stroke(AngularGradient(colors: [tint.deep, tint.base, tint.bright],
                                            center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * Double(max(f, 0.01)))),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.base.opacity(0.5), radius: lineWidth)
                if f > 0.02 {
                    let angle = Double(f) * 2 * .pi - .pi / 2
                    Circle()
                        .fill(Color.white)
                        .frame(width: lineWidth * 0.62, height: lineWidth * 0.62)
                        .shadow(color: tint.bright, radius: lineWidth)
                        .position(x: side / 2 + r * CGFloat(cos(angle)), y: side / 2 + r * CGFloat(sin(angle)))
                }
            }
            .frame(width: side, height: side)
        }
    }
}
