import AppKit
import NotchBuddyCore
import SwiftUI

// MARK: - Ink

/// The widget's only colors: white ink at a few strengths on the island's black. Color comes from the
/// cover itself (and the small equalizer tinted by it), nothing else.
enum MusicInk {
    static let title = Color.white
    static let subtitle = Color.white.opacity(0.6)
    /// Elapsed / remaining.
    static let time = Color.white.opacity(0.6)
    static let faint = Color.white.opacity(0.4)
    /// The progress bar's groove.
    static let groove = Color.white.opacity(0.2)
    /// A cover-less square, the empty state's square.
    static let well = Color(white: 0.16)
    /// The equalizer when there is no cover to take a color from.
    static let neutralTint = PaletteColor(0.86, 0.86, 0.87)
}

// MARK: - Artwork

/// The cover: a plain rounded square, no halo. A new track's cover slides a little from the side the
/// user skipped to (or cross-fades in, when the track changed by itself); a paused cover eases back.
struct MusicArtworkView: View {
    let artwork: MusicArtwork?
    let trackID: String?
    let playing: Bool
    var size: CGFloat = 52
    var cornerRadius: CGFloat = 11
    var direction = 0
    /// Previews: the track change at this point (0 … 1), with `outgoing` leaving.
    var swap: (progress: Double, outgoing: MusicArtwork?)?
    /// Clickable (opens the player): presses in a touch.
    var onTap: (() -> Void)?

    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        ZStack {
            if let swap {
                if let outgoing = swap.outgoing {
                    MusicCover(artwork: outgoing, cornerRadius: cornerRadius)
                        .modifier(CoverSwap(p: 1 - swap.progress, direction: -direction, size: size, leaving: true))
                }
                MusicCover(artwork: artwork, cornerRadius: cornerRadius)
                    .modifier(CoverSwap(p: swap.progress, direction: direction, size: size, leaving: false))
            } else {
                MusicCover(artwork: artwork, cornerRadius: cornerRadius)
                    .id(trackID ?? "")
                    .transition(transition)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect((playing ? 1 : 0.93) * (pressed ? 0.95 : hovering ? 1.02 : 1))
        .brightness(hovering && !pressed ? 0.03 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.86).speed(IslandMotion.speed), value: hovering)
        .animation(.spring(response: 0.22, dampingFraction: 0.9).speed(IslandMotion.speed), value: pressed)
        .animation(.spring(response: 0.5, dampingFraction: 0.88).speed(IslandMotion.speed), value: playing)
        .animation(.spring(response: 0.46, dampingFraction: 0.92).speed(IslandMotion.speed), value: trackID)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onHover { inside in hovering = onTap != nil && inside && !reduceMotion }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if onTap != nil, !pressed { pressed = true } }
                .onEnded { value in
                    pressed = false
                    if hypot(value.translation.width, value.translation.height) < 8 { onTap?() }
                },
            including: onTap == nil ? .none : .all
        )
    }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: CoverSwap(p: 0, direction: direction, size: size, leaving: false),
                                 identity: CoverSwap(p: 1, direction: direction, size: size, leaving: false)),
            removal: .modifier(active: CoverSwap(p: 0, direction: -direction, size: size, leaving: true),
                               identity: CoverSwap(p: 1, direction: -direction, size: size, leaving: true)))
    }
}

/// A cover coming in (`p` 0 → 1) or going out (`p` 1 → 0). With a direction it glides a short way in
/// from that side; without one the two simply cross-fade, the new one settling from a hair smaller.
struct CoverSwap: ViewModifier, Animatable {
    var p: Double
    let direction: Int
    let size: CGFloat
    let leaving: Bool

    var animatableData: Double {
        get { p }
        set { p = newValue }
    }

    func body(content: Content) -> some View {
        let q = CGFloat(1 - min(max(p, 0), 1.1))
        let d = CGFloat(direction)
        let scale: CGFloat = leaving ? 1 - 0.04 * q : 1 - 0.06 * q
        content
            .scaleEffect(scale)
            .offset(x: d * q * size * 0.2)
            // The old cover clears out quickly, so the two never sit on each other as a double exposure.
            .opacity(Double(max(0, 1 - q * (leaving ? 2.4 : 1))))
    }
}

/// The cover image, or a neutral grey square with a note (Apple's "no artwork").
struct MusicCover: View {
    let artwork: MusicArtwork?
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        GeometryReader { geo in
            ZStack {
                if let cover = artwork?.cover {
                    Image(decorative: cover, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity.animation(.easeInOut(duration: 0.35)))
                } else {
                    MusicNoArtwork(side: geo.size.width)
                        .transition(.opacity.animation(.easeInOut(duration: 0.35)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipShape(shape)
        // A hairline so a dark cover keeps its edge on black.
        .overlay { shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5) }
    }
}

/// Grey square, quiet note.
struct MusicNoArtwork: View {
    let side: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.19), MusicInk.well], startPoint: .top, endPoint: .bottom)
            Image(systemName: "music.note")
                .font(.system(size: side * 0.36, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.4))
        }
    }
}

// MARK: - Source

/// The player's real app icon, small and (by default) in grey; a drawn grey mark when the app's icon is
/// not available.
struct MusicSourceBadge: View {
    let player: MusicPlayer
    var size: CGFloat = 16
    var monochrome = true

    var body: some View {
        Group {
            if let icon = MusicPlayerIcon.image(player) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    // App icons carry a transparent margin: draw a little larger to fill `size`.
                    .frame(width: size * 1.22, height: size * 1.22)
                    .frame(width: size, height: size)
                    .grayscale(monochrome ? 1 : 0)
            } else {
                drawn
            }
        }
        .accessibilityLabel(player.displayName)
    }

    @ViewBuilder
    private var drawn: some View {
        let ink = Color.white.opacity(0.72)
        switch player {
        case .spotify:
            Circle()
                .fill(ink)
                .overlay { SpotifyWaves().stroke(Color.black, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round)) }
                .frame(width: size, height: size)
        case .appleMusic:
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(ink)
                .overlay {
                    Image(systemName: "music.note").font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(.black)
                }
                .frame(width: size, height: size)
        }
    }
}

/// Spotify's three arcs.
struct SpotifyWaves: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        for (i, y) in [0.36, 0.52, 0.67].enumerated() {
            let inset = [0.22, 0.27, 0.32][i]
            p.move(to: CGPoint(x: rect.minX + w * inset, y: rect.minY + h * y))
            p.addQuadCurve(to: CGPoint(x: rect.maxX - w * (inset - 0.02), y: rect.minY + h * (y + 0.04)),
                           control: CGPoint(x: rect.midX, y: rect.minY + h * (y - 0.1)))
        }
        return p
    }
}

// MARK: - Marquee

/// One line that, when it does not fit, fades out at the edge instead of an ellipsis, and scrolls its full
/// text in a loop while `active` (the pointer is on the card).
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    var active = false

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.islandStaticRender) private var staticRender

    private let gap: CGFloat = 36
    private var overflows: Bool { boxWidth > 0 && textWidth > boxWidth + 0.5 }
    private var scrolls: Bool { active && overflows && !reduceMotion && !staticRender }

    var body: some View {
        // A plain line sizes the view (never wider than offered); the real text rides on top of it, cut
        // by a mask whose fading edge only ever touches text that runs into it.
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                HStack(spacing: gap) {
                    label
                    if scrolls { label }
                }
                .fixedSize()
                .offset(x: offset)
            }
            .mask(edgeFade(leading: scrolls && offset < 0))
            .background {
                label.hidden().onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .onChange(of: scrolls) { restart() }
            .onChange(of: text) { restart() }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    private func edgeFade(leading: Bool) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: leading ? 10 : 0)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 26)
        }
    }

    private func restart() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { offset = 0 }
        guard scrolls else { return }
        let distance = textWidth + gap
        withAnimation(.linear(duration: Double(distance) / 32).delay(0.8).repeatForever(autoreverses: false)) {
            offset = -distance
        }
    }
}
