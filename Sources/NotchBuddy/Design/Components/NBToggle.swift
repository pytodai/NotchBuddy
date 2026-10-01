import SwiftUI
import NotchBuddyCore

/// Switch: the knob springs across with a small overshoot, stretches while it travels (and while
/// pressed), the track floods with the accent and glows.
///
/// ```swift
/// Toggle("Звуки", isOn: $sounds).toggleStyle(NBToggleStyle())
/// NBSwitch(isOn: $sounds, accent: .done)
/// ```
struct NBToggleStyle: ToggleStyle {
    var accent: NBAccent = .brand

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: NBSpace.l) {
            configuration.label
                .nbText(.bodyStrong)
                .foregroundStyle(NBColor.ink)
            Spacer(minLength: NBSpace.m)
            NBSwitch(isOn: configuration.$isOn, accent: accent)
        }
    }
}

struct NBSwitch: View {
    @Binding var isOn: Bool
    var accent: NBAccent = .brand
    var width: CGFloat = 36
    var height: CGFloat = 21

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.nbForcedState) private var forced
    @State private var hoveringNow = false
    @State private var pressedNow = false

    private var hovering: Bool { forced?.hovered ?? hoveringNow }
    private var pressed: Bool { forced?.pressed ?? pressedNow }

    var body: some View {
        let inset: CGFloat = 2.5
        let knob = height - 2 * inset
        let stretch: CGFloat = pressed ? 5 : 0
        let track = Capsule(style: .continuous)
        ZStack(alignment: isOn ? .trailing : .leading) {
            track.fill(Color.white.opacity(hovering ? 0.2 : 0.14))
            track.fill(accent.fill)
                .opacity(isOn ? 1 : 0)
            track.fill(LinearGradient(colors: [.black.opacity(0.18), .clear], startPoint: .top, endPoint: .center))
            track.strokeBorder(Color.white.opacity(isOn ? 0.22 : 0.08), lineWidth: 0.5)
            // The knob: stretches while pressed and during the switch (keyframes).
            NBSwitchKnob(diameter: knob, stretch: stretch, isOn: isOn, reduceMotion: reduceMotion || forced != nil)
                .padding(inset)
        }
        .frame(width: width, height: height)
        .shadow(color: accent.base.opacity(isOn ? (hovering ? 0.6 : 0.4) : 0), radius: isOn ? 7 : 0)
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(track)
        .animation(NBMotion.animation(NBMotion.knob, reduced: reduceMotion), value: isOn)
        .animation(NBMotion.animation(NBMotion.press, reduced: reduceMotion), value: pressed)
        .animation(NBMotion.animation(NBMotion.hover, reduced: reduceMotion), value: hovering)
        .onHover { hoveringNow = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressedNow { pressedNow = true } }
                .onEnded { value in
                    pressedNow = false
                    guard isEnabled else { return }
                    // A drag across the track sets the side it ends on; a tap toggles.
                    if abs(value.translation.width) > 6 {
                        isOn = value.translation.width > 0
                    } else {
                        isOn.toggle()
                    }
                }
        )
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? L("включено") : L("выключено"))
    }
}

private struct NBSwitchKnob: View {
    let diameter: CGFloat
    let stretch: CGFloat
    let isOn: Bool
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            face.frame(width: diameter + stretch, height: diameter)
        } else {
            // Travelling: the knob stretches toward where it goes, then snaps back round.
            face.keyframeAnimator(initialValue: CGFloat(0), trigger: isOn) { view, travel in
                view.frame(width: diameter + max(stretch, travel), height: diameter)
            } keyframes: { _ in
                CubicKeyframe(7, duration: 0.11 * IslandMotion.slowmo)
                SpringKeyframe(0, duration: 0.36 * IslandMotion.slowmo, spring: Spring(response: 0.3, dampingRatio: 0.58))
            }
        }
    }

    private var face: some View {
        Capsule(style: .continuous)
            .fill(LinearGradient(colors: [.white, Color(white: 0.88)], startPoint: .top, endPoint: .bottom))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}
