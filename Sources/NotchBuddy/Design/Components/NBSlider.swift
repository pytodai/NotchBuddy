import SwiftUI

/// Slider: a glowing accent fill, a knob that grows under the pointer and while dragged, and a value
/// bubble that rises above the knob during the drag. Optional step snaps with a spring.
///
/// ```swift
/// NBSlider(value: $volume)                                      // 0 … 1
/// NBSlider(value: $delay, range: 0...10, step: 1, format: { "\(Int($0)) с" })
/// ```
struct NBSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double?
    var accent: NBAccent = .brand
    /// Label in the bubble while dragging (nil: percent).
    var format: ((Double) -> String)?
    /// Icons at the ends (e.g. quiet / loud).
    var minimumIcon: NBIcon?
    var maximumIcon: NBIcon?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.nbForcedState) private var forced
    @State private var hoveringNow = false
    @State private var draggingNow = false

    private var hovering: Bool { forced?.hovered ?? hoveringNow }
    private var dragging: Bool { forced?.pressed ?? draggingNow }

    private var fraction: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return NBMath.clamp01((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    var body: some View {
        HStack(spacing: 8) {
            if let minimumIcon {
                NBIconView(minimumIcon, size: 13, color: NBColor.inkTertiary, value: 0)
            }
            track
            if let maximumIcon {
                NBIconView(maximumIcon, size: 13, color: NBColor.inkTertiary, value: 1, active: dragging)
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var track: some View {
        GeometryReader { geo in
            let knob: CGFloat = dragging ? 17 : (hovering ? 15 : 13)
            let w = geo.size.width
            let x = CGFloat(fraction) * (w - 13) + 6.5
            let trackHeight: CGFloat = hovering || dragging ? 5 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(NBColor.well)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
                    .frame(height: trackHeight)
                if let step, step > 0, range.upperBound > range.lowerBound {
                    let count = Int(((range.upperBound - range.lowerBound) / step).rounded())
                    if count <= 20 {
                        ForEach(0...count, id: \.self) { i in
                            Circle().fill(Color.white.opacity(0.22))
                                .frame(width: 2.5, height: 2.5)
                                .position(x: CGFloat(i) / CGFloat(count) * (w - 13) + 6.5, y: geo.size.height / 2)
                        }
                    }
                }
                Capsule().fill(accent.sweep)
                    .frame(width: max(trackHeight, x), height: trackHeight)
                    .shadow(color: accent.base.opacity(0.6), radius: 5)
                Circle()
                    .fill(LinearGradient(colors: [.white, Color(white: 0.88)], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .shadow(color: accent.base.opacity(dragging ? 0.7 : 0), radius: 8)
                    .position(x: x, y: geo.size.height / 2)
                // Value bubble.
                Text(label)
                    .font(.nbNumeric(10.5, weight: 740))
                    .foregroundStyle(accent.onAccent)
                    .contentTransition(.numericText(value: value))
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Capsule().fill(accent.fill))
                    .shadow(color: accent.base.opacity(0.5), radius: 5)
                    .scaleEffect(dragging ? 1 : 0.4, anchor: .bottom)
                    .opacity(dragging ? 1 : 0)
                    .position(x: x, y: geo.size.height / 2 - 20)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !draggingNow { draggingNow = true }
                        set(fraction: Double((g.location.x - 6.5) / max(w - 13, 1)))
                    }
                    .onEnded { _ in draggingNow = false }
            )
            .onHover { hoveringNow = $0 }
            .animation(NBMotion.animation(NBMotion.knob, reduced: reduceMotion), value: dragging)
            .animation(NBMotion.animation(NBMotion.hover, reduced: reduceMotion), value: hovering)
            .animation(step == nil ? nil : NBMotion.animation(NBMotion.press, reduced: reduceMotion), value: value)
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityValue(label)
        .accessibilityAdjustableAction { direction in
            let delta = step ?? (range.upperBound - range.lowerBound) / 10
            value = min(max(value + (direction == .increment ? delta : -delta), range.lowerBound), range.upperBound)
        }
    }

    private var label: String {
        format?(value) ?? "\(Int((fraction * 100).rounded()))%"
    }

    private func set(fraction f: Double) {
        guard isEnabled else { return }
        var v = range.lowerBound + NBMath.clamp01(f) * (range.upperBound - range.lowerBound)
        if let step, step > 0 {
            v = (v / step).rounded() * step
        }
        value = min(max(v, range.lowerBound), range.upperBound)
    }
}
