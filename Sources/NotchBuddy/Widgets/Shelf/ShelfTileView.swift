import AppKit
import NotchBuddyCore
import SwiftUI

/// One file on the shelf: its picture, name and size. Drag it out to use it (from anywhere on the tile but its
/// buttons); double-click opens it; right-click for the menu (`ShelfDragSource`).
/// On hover the tile lifts, a remove badge pops up in its corner and the size line gives way to
/// "open" and "show in Finder".
struct ShelfTileView: View {
    let item: ShelfItem
    let thumbnail: ShelfThumbnail?
    var hovering = false
    /// Landed with the last drop: a thin white outline that fades once.
    var justLanded = false
    var actions = ShelfTileActions()
    /// Live tiles: drag out, double-click and the right-click menu (`ShelfDragSource`). Nil in previews.
    var store: ShelfStore?

    static let size = CGSize(width: 90, height: 118)
    static let thumbBox = CGSize(width: 90, height: 58)
    /// The picture's box sits this far below the tile's top.
    static let thumbTop: CGFloat = 6
    static let corner: CGFloat = 14

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var glow = 0.0
    @State private var pressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        VStack(spacing: 0) {
            // The picture, the name and the size take no hits: a press on them reaches the drag source under them
            // (`ShelfDragSource`), only the buttons keep their own clicks.
            ShelfThumbnailView(item: item, thumbnail: thumbnail, box: Self.thumbBox, lifted: hovering)
                .frame(width: Self.thumbBox.width, height: Self.thumbBox.height)
                .padding(.top, Self.thumbTop)
                .allowsHitTesting(false)
            Text(Self.breakable(item.name))
                .font(ShelfTypography.font(10.5, 620))
                .foregroundStyle(ShelfPalette.primary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.9)
                .lineLimit(2)
                .truncationMode(.middle)
                .lineSpacing(-1)
                .frame(width: Self.size.width - 10, height: 28, alignment: .top)
                .padding(.top, 5)
                .allowsHitTesting(false)
            ZStack {
                if hovering {
                    actionRow
                        .transition(.asymmetric(
                            insertion: .offset(y: 7).combined(with: .opacity),
                            removal: .offset(y: 5).combined(with: .opacity)))
                } else {
                    Text(caption)
                        .font(ShelfTypography.digits(9.5, 520))
                        .foregroundStyle(ShelfPalette.tertiary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .transition(.asymmetric(
                            insertion: .offset(y: -6).combined(with: .opacity),
                            removal: .offset(y: -6).combined(with: .opacity)))
                }
            }
            .frame(height: 18)
            Spacer(minLength: 0)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            ZStack {
                shape.fill(hovering ? ShelfPalette.tileHover : ShelfPalette.tile)
                shape.fill(Color.white.opacity(0.05 * glow))
                if let store, !staticRender {
                    // Under the tile's content (which takes no hits), over its fill: takes the press, the drag, the
                    // double-click and the right-click; the buttons above keep their own clicks.
                    ShelfDragSource(item: item, image: thumbnail?.image, imageIsIcon: thumbnail?.isIcon ?? true,
                                    store: store, actions: actions, onPress: { pressed = $0 })
                }
            }
        }
        .overlay {
            ZStack {
                shape.strokeBorder(Color.white.opacity(hovering ? 0.13 : 0.06), lineWidth: 0.6)
                shape.strokeBorder(Color.white.opacity(0.5), lineWidth: 1).opacity(glow)
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            if hovering {
                RemoveBadge(action: actions.remove)
                    .offset(x: -5, y: -5)
                    .transition(.scale(scale: 0.3, anchor: .center).combined(with: .opacity))
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(hovering ? 0.55 : 0), radius: hovering ? 10 : 0, y: hovering ? 5 : 0)
        .scaleEffect(pressed ? 0.96 : (hovering ? 1.035 : 1))
        .offset(y: hovering ? -2 : 0)
        .animation(ShelfMotion.hover.animation, value: hovering)
        .animation(ShelfMotion.press.animation, value: pressed)
        .contentShape(shape)
        .onAppear(perform: landed)
        .help(item.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(item.subtitle)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: L("Открыть"), actions.open)
        .accessibilityAction(named: L("Показать в Finder"), actions.reveal)
        .accessibilityAction(named: L("Убрать с полки"), actions.remove)
    }

    /// A name that wraps at sensible places: before the extension and after `_` / `-` (zero-width spaces),
    /// so "ForecastChart.swift" breaks as "ForecastChart" + ".swift", not "ForecastChart.swi" + "ft".
    static func breakable(_ name: String) -> String {
        let zw = "\u{200B}"
        var base = name
        var ext = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            base = String(name[..<dot])
            ext = String(name[dot...])
        }
        base = base.replacingOccurrences(of: "_", with: "_" + zw).replacingOccurrences(of: "-", with: "-" + zw)
        return ext.isEmpty ? base : base + zw + ext
    }

    /// Size of a file, entries of a folder, else what it is.
    private var caption: String {
        if let byteSize = item.byteSize { return ShelfFormat.size(byteSize) }
        if item.kind == .folder, let children = item.childCount { return ShelfFormat.objects(children) }
        return item.kind.label
    }

    private var actionRow: some View {
        HStack(spacing: 5) {
            TileActionButton(glyph: .open, help: L("Открыть"), action: actions.open)
            TileActionButton(glyph: .reveal, help: L("Показать в Finder"), action: actions.reveal)
        }
    }

    private func landed() {
        guard justLanded else { return }
        if staticRender {
            glow = 0.85
            return
        }
        guard !reduceMotion else { return }
        glow = 1
        withAnimation(.easeOut(duration: ShelfMotion.landingGlow).delay(0.25).speed(IslandMotion.speed)) { glow = 0 }
    }
}

/// What a tile's controls do.
struct ShelfTileActions {
    var open: () -> Void = {}
    var reveal: () -> Void = {}
    var remove: () -> Void = {}
    var copyPath: () -> Void = {}
}

/// The file's picture: a content thumbnail in a thin photo frame, or the Finder icon as is; a small
/// extension tag on content thumbnails.
struct ShelfThumbnailView: View {
    let item: ShelfItem
    let thumbnail: ShelfThumbnail?
    let box: CGSize
    var lifted = false

    var body: some View {
        ZStack {
            if let thumbnail {
                if thumbnail.isIcon {
                    Image(nsImage: thumbnail.image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: box.height - 4, height: box.height - 4)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                        .transition(.opacity)
                } else {
                    contentThumbnail(thumbnail.image)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: box.height - 14, height: box.height - 8)
            }
        }
        .frame(width: box.width, height: box.height)
        .animation(.easeOut(duration: 0.22).speed(IslandMotion.speed), value: thumbnail?.isIcon)
    }

    private func contentThumbnail(_ image: NSImage) -> some View {
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        // Fit inside the box, leaving air around the frame.
        let maxW = box.width - 20, maxH = box.height - 6
        let w = min(maxW, maxH * aspect), h = min(maxH, maxW / max(aspect, 0.01))
        let frame = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: w, height: h)
            .clipShape(frame)
            .overlay(frame.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
            .overlay(alignment: .bottomTrailing) {
                if let tag = item.extensionTag {
                    Text(tag)
                        .font(ShelfTypography.font(7, 800))
                        .tracking(0.3)
                        .foregroundStyle(Color.white.opacity(0.92))
                        .padding(.horizontal, 3.5)
                        .frame(height: 11)
                        .background(Capsule().fill(Color.black.opacity(0.62)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                        .offset(x: 5, y: 3)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: lifted ? 6 : 3, y: lifted ? 3 : 1.5)
            .rotationEffect(.degrees(lifted ? -1.5 : 0))
    }
}

/// The corner × that takes a file off the shelf.
private struct RemoveBadge: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ShelfGlyph(kind: .remove).icon(8, Color.white.opacity(hover ? 1 : 0.86), weight: 1.5)
                .frame(width: 19, height: 19)
                .background(Circle().fill(hover ? ShelfPalette.danger : Color(white: 0.2)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6))
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .scaleEffect(hover ? 1.1 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(ShelfMotion.hover.animation, value: hover)
        .help(L("Убрать с полки"))
    }
}

/// A small round action under a hovered tile's name.
private struct TileActionButton: View {
    let glyph: ShelfGlyph.Kind
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ShelfGlyph(kind: glyph).icon(10.5, hover ? Color.black.opacity(0.85) : Color.white.opacity(0.9), weight: 1.35)
                .frame(width: 30, height: 18)
                .background(Capsule().fill(Color.white.opacity(hover ? 0.9 : 0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(ShelfMotion.hover.animation, value: hover)
        .help(help)
    }
}

/// The tile that stands for files being dragged over the shelf: a dashed gray outline, a white plus that
/// breathes and "+N".
struct ShelfGhostTile: View {
    let count: Int
    /// Seconds since the ghost appeared (drives the breathing; fixed in previews).
    var time: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ShelfTileView.corner, style: .continuous)
        let breath = 0.5 + 0.5 * sin(time * 2 * .pi / 1.3)
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 28, height: 28)
                ShelfGlyph(kind: .plus).icon(13, Color.black.opacity(0.82), weight: 2)
            }
            .scaleEffect(0.97 + 0.04 * breath)
            Text(count > 1 ? "+\(count)" : L("Сюда"))
                .font(ShelfTypography.digits(11, 700))
                .foregroundStyle(ShelfPalette.secondary)
        }
        .frame(width: ShelfTileView.size.width, height: ShelfTileView.size.height)
        .background(shape.fill(Color.white.opacity(0.05)))
        .overlay(
            MarchingBorder(cornerRadius: ShelfTileView.corner, phase: CGFloat(-time * 18), dash: [5, 4], lineWidth: 1)
                .fill(ShelfPalette.target)
        )
    }
}

/// A file still being copied in (a promised file, a big temporary one): a shimmering blank tile.
struct ShelfImportingTile: View {
    var time: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ShelfTileView.corner, style: .continuous)
        let x = CGFloat((time / 1.2).truncatingRemainder(dividingBy: 1)) * 2.4 - 1.2
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 46, height: 44)
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 2)
                    .frame(width: 18, height: 18)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(time * 400))
            }
            Capsule().fill(Color.white.opacity(0.08)).frame(width: 52, height: 7)
            Capsule().fill(Color.white.opacity(0.06)).frame(width: 30, height: 6)
        }
        .frame(width: ShelfTileView.size.width, height: ShelfTileView.size.height)
        .background(shape.fill(ShelfPalette.tile))
        .overlay {
            LinearGradient(colors: [.clear, Color.white.opacity(0.06), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 34)
                .rotationEffect(.degrees(14))
                .offset(x: x * ShelfTileView.size.width / 2)
                .blendMode(.plusLighter)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.06), lineWidth: 0.6))
    }
}

/// How a landing tile comes in: from above, small, blurred and tilted, settling with the landing spring.
struct ShelfLandingEffect: ViewModifier, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = progress
        let q = min(max(p, 0), 1)
        content
            .scaleEffect(0.62 + 0.38 * p, anchor: .bottom)
            .offset(y: -30 * (1 - p))
            .rotationEffect(.degrees(-7 * (1 - p)))
            .blur(radius: 5 * (1 - q))
            .opacity(min(1, q * 1.8))
    }
}

/// How a tile leaves: shrinks and fades toward its center, a little blur.
struct ShelfRemovalEffect: ViewModifier, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let q = min(max(progress, 0), 1)
        content
            .scaleEffect(1 - 0.4 * q)
            .blur(radius: 4 * q)
            .opacity(1 - q)
    }
}

extension AnyTransition {
    /// A file landing on the shelf (`delay` staggers a drop of several).
    static func shelfLanding(delay: Double, reduce: Bool) -> AnyTransition {
        if reduce { return .opacity.animation(.easeOut(duration: 0.18).speed(IslandMotion.speed)) }
        return .asymmetric(
            insertion: .modifier(active: ShelfLandingEffect(progress: 0), identity: ShelfLandingEffect(progress: 1))
                .animation(ShelfMotion.landing.delayed(delay).animation),
            removal: .shelfRemoval(delay: 0, reduce: reduce))
    }

    static func shelfRemoval(delay: Double, reduce: Bool) -> AnyTransition {
        if reduce { return .opacity.animation(.easeOut(duration: 0.14).speed(IslandMotion.speed)) }
        return .modifier(active: ShelfRemovalEffect(progress: 1), identity: ShelfRemovalEffect(progress: 0))
            .animation(ShelfMotion.removal.delayed(delay).animation)
    }
}
