import SwiftUI
import NotchBuddyCore

// MARK: - Glyphs

/// Play ▶ morphing into pause ❚❚: each half of the triangle becomes a bar (`progress` 0 play … 1 pause).
/// Drawn with rounded joins (`MusicGlyph`), in a unit box optically centered.
struct PlayPauseGlyph: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    // Quads as top-left, top-right, bottom-right, bottom-left, in a unit square.
    private static let playLeft: [CGPoint] = [.init(x: 0.24, y: 0.14), .init(x: 0.57, y: 0.325),
                                              .init(x: 0.57, y: 0.675), .init(x: 0.24, y: 0.86)]
    private static let playRight: [CGPoint] = [.init(x: 0.57, y: 0.325), .init(x: 0.90, y: 0.5),
                                               .init(x: 0.90, y: 0.5), .init(x: 0.57, y: 0.675)]
    private static let pauseLeft: [CGPoint] = [.init(x: 0.22, y: 0.16), .init(x: 0.42, y: 0.16),
                                               .init(x: 0.42, y: 0.84), .init(x: 0.22, y: 0.84)]
    private static let pauseRight: [CGPoint] = [.init(x: 0.58, y: 0.16), .init(x: 0.78, y: 0.16),
                                                .init(x: 0.78, y: 0.84), .init(x: 0.58, y: 0.84)]

    func path(in rect: CGRect) -> Path {
        let p = min(max(progress, -0.1), 1.1)
        var path = Path()
        for (a, b) in [(Self.playLeft, Self.pauseLeft), (Self.playRight, Self.pauseRight)] {
            let points = zip(a, b).map { from, to in
                CGPoint(x: rect.minX + (from.x + (to.x - from.x) * p) * rect.width,
                        y: rect.minY + (from.y + (to.y - from.y) * p) * rect.height)
            }
            path.addLines(points)
            path.closeSubpath()
        }
        return path
    }
}

/// ⏩ / ⏪ as two triangles. On a tap they roll forward one slot (`phase` 0 → 1): the leading one leaves
/// shrinking, the other takes its place and a new one grows in behind; phase 1 looks exactly like 0, so
/// the animation can restart any time.
struct SkipGlyph: Shape {
    var forward: Bool
    var phase: CGFloat

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w: CGFloat = 0.43, h: CGFloat = 0.6
        let slots: [CGFloat] = [0.07 - w, 0.07, 0.50, 0.50 + w]  // leading edges: entering, rest 1, rest 2, leaving
        let p = min(max(phase, 0), 1)
        var path = Path()
        func triangle(_ x: CGFloat, _ scale: CGFloat) {
            guard scale > 0.01 else { return }
            let cx = x + w / 2, cy: CGFloat = 0.5
            let sw = w * scale, sh = h * scale
            let pts = [CGPoint(x: cx - sw / 2, y: cy - sh / 2), CGPoint(x: cx + sw / 2, y: cy),
                       CGPoint(x: cx - sw / 2, y: cy + sh / 2)]
            path.addLines(pts.map { pt in
                let ux = forward ? pt.x : 1 - pt.x
                return CGPoint(x: rect.minX + ux * rect.width, y: rect.minY + pt.y * rect.height)
            })
            path.closeSubpath()
        }
        triangle(slots[0] + (slots[1] - slots[0]) * p, p)
        triangle(slots[1] + (slots[2] - slots[1]) * p, 1)
        triangle(slots[2] + (slots[3] - slots[2]) * p, 1 - p)
        return path
    }
}

/// A filled glyph with softly rounded corners (fill plus a round-joined stroke of the same color).
struct MusicGlyph<S: Shape>: View {
    let shape: S
    let color: Color
    var rounding: CGFloat = 2

    var body: some View {
        shape.fill(color)
            .overlay(shape.stroke(color, style: StrokeStyle(lineWidth: rounding, lineCap: .round, lineJoin: .round)))
            // One layer, so a fade (hover, press, disabled) does not show where fill and stroke overlap.
            .compositingGroup()
    }
}

// MARK: - Buttons

/// A bare white glyph: under the pointer it comes up to full white; pressed, it shrinks a touch over a
/// faint grey disc (the way iOS transport buttons answer a touch) and springs back without overshoot.
struct MusicGlyphButtonStyle: ButtonStyle {
    /// The hit area (a circle).
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        MusicGlyphButtonBody(configuration: configuration, size: size)
    }
}

private struct MusicGlyphButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .opacity(pressed ? 0.7 : hovering ? 1 : 0.92)
            .scaleEffect(pressed ? 0.86 : 1)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(Color.white.opacity(pressed ? 0.1 : 0))
                    .scaleEffect(pressed ? 1 : 0.8)
            }
            .contentShape(Circle())
            .animation(.spring(response: 0.24, dampingFraction: 0.9).speed(IslandMotion.speed), value: pressed)
            .animation(.easeOut(duration: 0.15).speed(IslandMotion.speed), value: hovering)
            .onHover { hovering = $0 && enabled }
    }
}

/// Play/pause: the triangle parts into two bars (and back) with a short, settled spring.
struct MusicPlayButton: View {
    let playing: Bool
    /// The hit area; the glyph is about 60 % of it.
    var size: CGFloat = 44
    let action: () -> Void
    /// Previews: the morph at this point instead of `playing`.
    var morph: CGFloat?

    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            MusicGlyph(shape: PlayPauseGlyph(progress: morph ?? (playing ? 1 : 0)), color: .white, rounding: size * 0.05)
                .frame(width: size * 0.6, height: size * 0.6)
                .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.86)
                    .speed(IslandMotion.speed), value: playing)
        }
        .buttonStyle(MusicGlyphButtonStyle(size: size))
        .accessibilityLabel(playing ? L("Пауза") : L("Играть"))
    }
}

/// Previous / next: the triangles roll one slot on each tap.
struct MusicSkipButton: View {
    let forward: Bool
    var size: CGFloat = 40
    let action: () -> Void
    /// Previews: the roll at this phase.
    var phase: CGFloat?

    @State private var taps = 0
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            taps &+= 1
            action()
        } label: {
            Group {
                if let phase {
                    glyph(phase)
                } else if reduceMotion {
                    glyph(0)
                } else {
                    KeyframeAnimator(initialValue: CGFloat(0), trigger: taps) { value in glyph(value) } keyframes: { _ in
                        KeyframeTrack {
                            LinearKeyframe(0, duration: 0.001)
                            CubicKeyframe(1, duration: IslandMotion.t(0.32))
                        }
                    }
                }
            }
            .frame(width: size * 0.62, height: size * 0.62)
        }
        .buttonStyle(MusicGlyphButtonStyle(size: size))
        .accessibilityLabel(forward ? L("Следующий трек") : L("Предыдущий трек"))
    }

    private func glyph(_ phase: CGFloat) -> some View {
        MusicGlyph(shape: SkipGlyph(forward: forward, phase: phase), color: .white, rounding: size * 0.04)
    }
}

/// ⏮ ⏯ ⏭, white on black, evenly spaced.
struct MusicTransport: View {
    let playing: Bool
    var actions = MusicWidgetActions()
    var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: 18 * scale) {
            MusicSkipButton(forward: false, size: 40 * scale, action: actions.previous)
            MusicPlayButton(playing: playing, size: 44 * scale, action: actions.playPause)
            MusicSkipButton(forward: true, size: 40 * scale, action: actions.next)
        }
    }
}
