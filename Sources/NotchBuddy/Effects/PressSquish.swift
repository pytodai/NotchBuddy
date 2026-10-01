import SwiftUI
import NotchBuddyCore

/// A press squishes a control like something soft: under the finger it flattens a little and spreads
/// sideways (volume is kept), on release it springs back past its shape and settles, jelly-like.
/// Reduce Motion: it dims instead.
struct PressSquish: ViewModifier {
    var pressed: Bool
    /// How much it flattens (0.06: 6 % shorter, ~2 % wider).
    var amount: CGFloat = 0.06
    var anchor: UnitPoint = .center
    @Environment(\.islandReduceMotion) private var islandReduce
    @Environment(\.accessibilityReduceMotion) private var systemReduce

    /// Down: quick and firm. Up: bouncy.
    static let down = MotionCurve.spring(0.16, 0.9)
    static let up = MotionCurve.spring(0.42, 0.42)

    func body(content: Content) -> some View {
        // Scoped animations: only the squish (or the dim) animates, not whatever else changes inside.
        if islandReduce || systemReduce {
            content.animation(.easeOut(duration: 0.12).speed(IslandMotion.speed)) {
                $0.opacity(pressed ? 0.78 : 1)
            }
        } else {
            content.animation((pressed ? Self.down : Self.up).animation) {
                $0.modifier(PressSquishFace(squish: pressed ? 1 : 0, amount: amount, anchor: anchor))
            }
        }
    }
}

/// The squish at `squish` (0 at rest, 1 fully pressed; the release spring swings below 0 = stretched).
struct PressSquishFace: ViewModifier, Animatable {
    var squish: Double
    var amount: CGFloat
    var anchor: UnitPoint = .center

    var animatableData: Double {
        get { squish }
        set { squish = newValue }
    }

    func body(content: Content) -> some View {
        let k = CGFloat(squish) * amount
        content.scaleEffect(x: 1 + k * 0.35, y: 1 - k, anchor: anchor)
    }

    /// Filmstrips: the squish `t` seconds after the press (`down`) or after the release (`up`, from pressed).
    static func value(afterPress t: Double) -> Double { PressSquish.down.progress(t) }
    static func value(afterRelease t: Double) -> Double { 1 - PressSquish.up.progress(t) }
}

/// A button style that squishes (the island's buttons, the ⚙️ button).
struct SquishButtonStyle: ButtonStyle {
    var amount: CGFloat = 0.07

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(PressSquish(pressed: configuration.isPressed, amount: amount))
    }
}

extension View {
    /// Squishes while `pressed` (drive it from your own gesture or `ButtonStyle`).
    func pressSquish(_ pressed: Bool, amount: CGFloat = 0.06, anchor: UnitPoint = .center) -> some View {
        modifier(PressSquish(pressed: pressed, amount: amount, anchor: anchor))
    }

    /// Squishes under the mouse and calls `action` on a click (a release within 8 pt of the press). It
    /// never takes keyboard focus.
    func pressSquish(amount: CGFloat = 0.06, anchor: UnitPoint = .center, action: @escaping () -> Void) -> some View {
        modifier(PressSquishTap(amount: amount, anchor: anchor, action: action))
    }
}

private struct PressSquishTap: ViewModifier {
    let amount: CGFloat
    let anchor: UnitPoint
    let action: () -> Void
    @State private var pressed = false

    func body(content: Content) -> some View {
        content
            .pressSquish(pressed, amount: amount, anchor: anchor)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true } }
                    .onEnded { value in
                        pressed = false
                        if hypot(value.translation.width, value.translation.height) < 8 { action() }
                    }
            )
    }
}
