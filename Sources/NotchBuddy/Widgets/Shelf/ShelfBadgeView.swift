import AppKit
import NotchBuddyCore
import SwiftUI

/// The shelf's compact live activity for the closed island: a little fan of the newest files' pictures
/// with a count bubble. A file landing drops into the fan (the fan dips and the count ticks); a file dragged
/// toward the island spreads the fan and outlines it in white.
///
/// About 30 × 22 pt; it sits in the closed island (beside the usage ring, or as a wing).
struct ShelfBadgeView: View {
    /// Newest first; at most three are drawn.
    let pictures: [ShelfThumbnail?]
    let count: Int
    /// Bumps when files land (`ShelfStore.addToken`).
    var addToken = 0
    /// 0 … 1 from `DragHoverDetector.State.proximity`.
    var proximity: Double = 0
    var height: CGFloat = 22

    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.islandStaticRender) private var staticRender
    /// Previews: 0 … 1 through the landing ("gulp"); nil live.
    @Environment(\.shelfBadgeLanding) private var filmLanding

    var body: some View {
        let cards = Array(pictures.prefix(3))
        let spread = CGFloat(proximity)
        HStack(spacing: 5) {
            ZStack {
                if cards.isEmpty {
                    ShelfTrayGlyph(size: height * 0.9, arrow: 0.35 + 0.65 * spread, open: spread,
                                   style: AnyShapeStyle(Color.white.opacity(0.7 + 0.25 * proximity)))
                } else {
                    ForEach(Array(cards.enumerated()).reversed(), id: \.offset) { index, picture in
                        MiniCard(picture: picture, height: height * 0.74, accent: proximity)
                            .rotationEffect(.degrees(angle(index, of: cards.count, spread: spread)), anchor: .bottom)
                            .offset(x: offset(index, of: cards.count, spread: spread), y: index == 0 ? -1.5 * spread : 0)
                            .modifier(BadgeDropEffect(progress: index == 0 ? landing : 1))
                    }
                }
            }
            .frame(width: height * 1.05, height: height)
            if count > 0 {
                Text("\(count)")
                    .font(ShelfTypography.digits(height * 0.52, 720))
                    .foregroundStyle(ShelfPalette.primary)
                    .contentTransition(.numericText(value: Double(count)))
                    .modifier(CountBumpEffect(progress: landing))
            }
        }
        .animation(ShelfMotion.target.animation, value: proximity)
        .animation(ShelfMotion.badgeDrop.animation, value: count)
        .onChange(of: addToken) { _, _ in land() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count > 0 ? L("На полке %@", ShelfFormat.files(count)) : L("Полка пуста"))
    }

    @State private var liveLanding: Double = 1

    private var landing: Double { filmLanding ?? liveLanding }

    private func land() {
        guard !reduceMotion, !staticRender else { return }
        liveLanding = 0
        withAnimation(ShelfMotion.badgeDrop.animation) { liveLanding = 1 }
    }

    private func angle(_ index: Int, of n: Int, spread: CGFloat) -> Double {
        guard n > 1 else { return 0 }
        let base: [Double] = n == 2 ? [5, -9] : [6, -7, -18]
        return base[index] * Double(1 + 0.5 * spread)
    }

    private func offset(_ index: Int, of n: Int, spread: CGFloat) -> CGFloat {
        guard n > 1 else { return 0 }
        let base: [CGFloat] = n == 2 ? [2.5, -2.5] : [3.5, -1, -4.5]
        return base[index] * (1 + 0.6 * spread)
    }
}

/// A file's picture as a tiny card.
private struct MiniCard: View {
    let picture: ShelfThumbnail?
    let height: CGFloat
    let accent: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: height * 0.18, style: .continuous)
        let width = height * 0.8
        ZStack {
            shape.fill(Color(white: 0.16))
            if let picture {
                Image(nsImage: picture.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: picture.isIcon ? .fit : .fill)
                    .frame(width: picture.isIcon ? width * 0.96 : width, height: picture.isIcon ? width * 0.96 : height)
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
        .overlay(shape.strokeBorder(Color.white.opacity(0.6), lineWidth: 0.8).opacity(accent))
        .shadow(color: .black.opacity(0.6), radius: 1.5, y: 0.5)
    }
}

/// The newest card dropping into the fan: from above, turning, with a small squash on landing.
private struct BadgeDropEffect: ViewModifier, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = progress
        let q = min(max(p, 0), 1)
        content
            .offset(y: -16 * (1 - p))
            .rotationEffect(.degrees(22 * (1 - p)))
            .scaleEffect(x: 1 + 0.12 * max(0, p - 1) * 8, y: 1 - 0.12 * max(0, p - 1) * 8, anchor: .bottom)
            .opacity(min(1, q * 2.2))
    }
}

/// The count swells as a file lands.
private struct CountBumpEffect: ViewModifier, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let q = min(max(progress, 0), 1)
        // 1 → 1.35 around the middle of the drop → 1.
        let bump = 0.35 * sin(q * .pi)
        content.scaleEffect(1 + bump)
    }
}

/// The badge fed from the store (and the drag detector's state).
struct ShelfBadge: View {
    let store: ShelfStore
    var proximity: Double = 0
    var height: CGFloat = 22

    var body: some View {
        ShelfBadgeView(pictures: store.items.prefix(3).map { store.thumbnails.thumbnail(for: $0) },
                       count: store.count, addToken: store.addToken, proximity: proximity, height: height)
            .task(id: store.items.prefix(3).map(\.id)) {
                for item in store.items.prefix(3) { store.thumbnails.load(item) }
            }
    }
}

/// What the closed island says while a file is dragged toward it: an opening tray with a bobbing arrow and
/// "Брось на полку" (closer: brighter; over the island: "Отпускай"). For the collapsed island's content
/// while `DragHoverDetector.state.isDragging`.
struct ShelfDropHint: View {
    var proximity: Double
    var over: Bool
    var count = 0
    var height: CGFloat = 22

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.shelfPreviewTime) private var previewTime
    @State private var since = Date()

    var body: some View {
        let lit = over ? 1 : proximity
        HStack(spacing: 7) {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: staticRender || reduceMotion || previewTime != nil)) { context in
                let t = previewTime ?? context.date.timeIntervalSince(since) / IslandMotion.slowmo
                let bob = 0.5 + 0.5 * sin(t * 2 * .pi / (over ? 0.7 : 1.1))
                ShelfTrayGlyph(size: height, arrow: CGFloat(0.2 + 0.8 * bob), open: CGFloat(lit),
                               style: AnyShapeStyle(Color.white.opacity(0.6 + 0.35 * lit)))
            }
            .frame(width: height, height: height)
            Text(over ? (count > 1 ? L("Отпускай — %@", ShelfFormat.files(count)) : L("Отпускай!")) : L("Брось на полку"))
                .font(ShelfTypography.font(height * 0.56, 650))
                .foregroundStyle(Color.white.opacity(0.6 + 0.35 * lit))
                .contentTransition(.interpolate)
                .lineLimit(1)
        }
        .animation(ShelfMotion.target.animation, value: over)
        .animation(ShelfMotion.target.animation, value: proximity)
    }
}

private struct ShelfBadgeLandingKey: EnvironmentKey { static let defaultValue: Double? = nil }

extension EnvironmentValues {
    /// Previews: how far the badge's landing is (0 … 1, may overshoot).
    var shelfBadgeLanding: Double? {
        get { self[ShelfBadgeLandingKey.self] }
        set { self[ShelfBadgeLandingKey.self] = newValue }
    }
}
