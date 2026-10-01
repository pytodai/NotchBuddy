import AppKit
import NotchBuddyCore
import SwiftUI

/// The shelf ("Полка") in the open island: a header (mark, title, how many files and how big, "clear
/// all") over a well of tiles that scrolls sideways. Files dropped on it land with a little fall; drag a
/// tile out to use the file; double-click opens it.
///
/// While a drag with files hovers, the well lights up quietly: its border marches in gray-white, a faint
/// neutral light follows the pointer, and a ghost tile slides in at the front ("+3") pushing the others aside. The
/// widget's height never changes between states, so the island does not resize under a drop.
struct ShelfWidgetView: View {
    let store: ShelfStore
    var width: CGFloat = 492
    /// Extra room above the header (on a notched screen the header can start below the camera strip).
    var topInset: CGFloat = 0
    /// Whether the pointer is on the island (the controller knows; a fast exit can skip SwiftUI's hover-out,
    /// and no tile stays lifted once it is false).
    var pointerInside = true

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    /// Previews: a hovered tile (by index) and a frozen clock for the time-driven pieces.
    @Environment(\.shelfPreviewHover) private var previewHover
    @Environment(\.shelfPreviewTime) private var previewTime
    @Environment(\.shelfPreviewConfirmClear) private var previewConfirmClear

    @State private var hovered: UUID?
    @State private var confirmClear = false
    @State private var confirmTask: Task<Void, Never>?
    @State private var sweeping = false
    @State private var targetedSince = Date()

    static let sidePadding: CGFloat = 10
    static let textInset: CGFloat = 22
    static let headerHeight: CGFloat = 44
    static let wellPadding: CGFloat = 8
    static let tileSpacing: CGFloat = 8
    static var wellHeight: CGFloat { ShelfTileView.size.height + 2 * wellPadding }
    static let wellCorner: CGFloat = 18
    /// The widget's height (the same empty, full or under a drop).
    static func height(topInset: CGFloat = 0) -> CGFloat { topInset + headerHeight + wellHeight + 10 }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: Self.headerHeight)
                .padding(.top, topInset)
                .appearAfter(0.02, style: .header)
            well
                .padding(.horizontal, Self.sidePadding)
                .padding(.bottom, 10)
                .appearAfter(0.05, style: .section)
        }
        .frame(width: width, height: Self.height(topInset: topInset), alignment: .top)
        .shelfDropTarget(store, enabled: !staticRender)
        .onAppear { store.refresh() }
        .onChange(of: store.dropTargeted) { _, targeted in
            if targeted { targetedSince = Date() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !store.dropTargeted || frozen)) { context in
                let t = time(context.date)
                ShelfTrayGlyph(size: 18,
                               arrow: store.dropTargeted ? 0.55 + 0.45 * CGFloat(sin(t * 2 * .pi / 0.9)) : 0.5,
                               open: store.dropTargeted ? 1 : 0)
            }
            .frame(width: 18, height: 18)
            .animation(ShelfMotion.target.animation, value: store.dropTargeted)
            Text(L("Полка"))
                .font(ShelfTypography.font(13.5, 680))
                .foregroundStyle(ShelfPalette.primary)
            ZStack(alignment: .leading) {
                if store.dropTargeted && !store.isEmpty {
                    Text(dropPrompt)
                        .foregroundStyle(ShelfPalette.primary)
                        .transition(.asymmetric(insertion: .offset(y: 8).combined(with: .opacity),
                                                removal: .offset(y: -8).combined(with: .opacity)))
                } else if !store.isEmpty && !store.dropTargeted {
                    Text(store.summary)
                        .foregroundStyle(ShelfPalette.tertiary)
                        .contentTransition(.numericText(value: Double(store.count)))
                        .transition(.asymmetric(insertion: .offset(y: -8).combined(with: .opacity),
                                                removal: .offset(y: 8).combined(with: .opacity)))
                }
            }
            .font(ShelfTypography.digits(11.5, 560))
            .lineLimit(1)
            .animation(ShelfMotion.target.animation, value: store.dropTargeted)
            .animation(ShelfMotion.reflow.animation, value: store.summary)
            Spacer(minLength: 8)
            if !store.isEmpty {
                HeaderIconButton(glyph: .reveal, help: L("Показать всё в Finder"), action: store.revealAll)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                ClearButton(confirming: confirmClear || previewConfirmClear, action: clearTapped)
                    .transition(.scale(scale: 0.6, anchor: .trailing).combined(with: .opacity))
            }
        }
        .padding(.leading, Self.textInset - 2)
        .padding(.trailing, 14)
        .animation(ShelfMotion.reflow.animation, value: store.isEmpty)
    }

    private var dropPrompt: String {
        let n = store.incomingCount
        return n > 1 ? L("Отпусти — положу %@", ShelfFormat.files(n)) : L("Отпусти — положу на полку")
    }

    private func clearTapped() {
        confirmTask?.cancel()
        if confirmClear {
            confirmClear = false
            sweep()
        } else {
            withAnimation(ShelfMotion.hover.animation) { confirmClear = true }
            confirmTask = Task { @MainActor in
                try? await Task.sleep(for: IslandMotion.delay(2.8))
                guard !Task.isCancelled else { return }
                withAnimation(ShelfMotion.hover.animation) { confirmClear = false }
            }
        }
    }

    /// Clear all: tiles leave one after another, from the front.
    private func sweep() {
        sweeping = true
        let last = Double(min(max(store.count, 1), 8)) * ShelfMotion.clearStagger
        DispatchQueue.main.async {
            withAnimation(ShelfMotion.removal.animation) { store.clear() }
            DispatchQueue.main.asyncAfter(deadline: .now() + (last + 0.32) * IslandMotion.slowmo) {
                withAnimation(ShelfMotion.reflow.animation) { sweeping = false }
            }
        }
    }

    // MARK: Well

    private var well: some View {
        let shape = RoundedRectangle(cornerRadius: Self.wellCorner, style: .continuous)
        let targeted = store.dropTargeted
        return ZStack {
            shape.fill(ShelfPalette.well)
            if targeted {
                dropGlow
                    .clipShape(shape)
                    .transition(.opacity.animation(ShelfMotion.target.animation))
            }
            // While "clear all" sweeps the tiles out, the row stays so each tile can leave in turn.
            if store.isEmpty && store.importing == 0 && !sweeping {
                emptyState
                    .transition(.opacity.combined(with: .scale(scale: 0.97)).animation(ShelfMotion.reflow.animation))
            } else {
                tiles
                    .transition(.opacity.animation(.easeOut(duration: 0.18).speed(IslandMotion.speed)))
            }
        }
        .frame(height: Self.wellHeight)
        .overlay { wellBorder(shape, targeted: targeted) }
        .animation(ShelfMotion.reflow.animation, value: store.isEmpty)
    }

    @ViewBuilder
    private func wellBorder(_ shape: RoundedRectangle, targeted: Bool) -> some View {
        if targeted {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: frozen)) { context in
                MarchingBorder(cornerRadius: Self.wellCorner, phase: CGFloat(-time(context.date) * 22), dash: [8, 6],
                               lineWidth: 1.2)
                    .fill(ShelfPalette.target)
            }
            .transition(.opacity.animation(ShelfMotion.target.animation))
        } else if store.isEmpty {
            MarchingBorder(cornerRadius: Self.wellCorner, phase: 0, dash: [6, 6], lineWidth: 1.1)
                .fill(Color.white.opacity(0.13))
                .transition(.opacity.animation(ShelfMotion.target.animation))
        } else {
            shape.strokeBorder(ShelfPalette.hairline, lineWidth: 0.6)
        }
    }

    /// A faint neutral light under the dragged files, following them across the well (no hue, no glow).
    private var dropGlow: some View {
        GeometryReader { geo in
            let location = store.dropLocation ?? CGPoint(x: geo.size.width * 0.2, y: geo.size.height / 2)
            // The drop target's location is in the widget's space; the well sits below the header.
            let local = CGPoint(x: location.x - Self.sidePadding, y: location.y - Self.headerHeight - topInset)
            ZStack {
                Color.white.opacity(0.03)
                RadialGradient(colors: [Color.white.opacity(0.07), .clear],
                               center: UnitPoint(x: local.x / max(geo.size.width, 1), y: local.y / max(geo.size.height, 1)),
                               startRadius: 0, endRadius: 190)
                    .animation(.smooth(duration: 0.25).speed(IslandMotion.speed), value: location.x)
            }
        }
        .allowsHitTesting(false)
    }

    private var emptyState: some View {
        let targeted = store.dropTargeted
        return HStack(spacing: 14) {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !targeted || frozen)) { context in
                let t = time(context.date)
                ShelfTrayGlyph(size: 44,
                               arrow: targeted ? 0.5 + 0.5 * CGFloat(sin(t * 2 * .pi / 0.9)) : 0.35,
                               open: targeted ? 1 : 0,
                               style: AnyShapeStyle(Color.white.opacity(targeted ? 0.9 : 0.55)),
                               lineWidth: 1.9)
                    .scaleEffect(targeted ? 1.08 : 1)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(targeted ? L("Отпускай — полка подержит") : L("Перетащи сюда файлы"))
                    .font(ShelfTypography.font(13.5, 680))
                    .foregroundStyle(ShelfPalette.primary)
                    .contentTransition(.opacity)
                Text(L("Они полежат здесь, пока не понадобятся. Потом просто вытащи их куда нужно."))
                    .font(ShelfTypography.font(11.5, 500))
                    .foregroundStyle(ShelfPalette.secondary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 290, alignment: .leading)
        }
        .padding(.horizontal, 22)
        .animation(ShelfMotion.target.animation, value: targeted)
    }

    // MARK: Tiles

    private var tiles: some View {
        let items = store.items
        let fresh = store.lastAdded
        let freshOrder = items.filter { fresh.contains($0.id) }.map(\.id)
        let row = HStack(spacing: Self.tileSpacing) {
            if store.dropTargeted {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: frozen)) { context in
                    ShelfGhostTile(count: store.incomingCount, time: time(context.date))
                }
                .frame(width: ShelfTileView.size.width, height: ShelfTileView.size.height)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.4).combined(with: .opacity).animation(ShelfMotion.ghost.animation),
                    removal: .scale(scale: 0.6).combined(with: .opacity).animation(.easeOut(duration: 0.12).speed(IslandMotion.speed))))
            }
            ForEach(0..<store.importing, id: \.self) { _ in
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: frozen)) { context in
                    ShelfImportingTile(time: time(context.date))
                }
                .frame(width: ShelfTileView.size.width, height: ShelfTileView.size.height)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let landingIndex = freshOrder.firstIndex(of: item.id) ?? 0
                ShelfTileView(item: item,
                              thumbnail: store.thumbnails.thumbnail(for: item),
                              hovering: isHovered(item, index: index),
                              justLanded: fresh.contains(item.id),
                              actions: actions(for: item),
                              store: store)
                    // The file being dragged out stays behind as a faint ghost, as in Finder.
                    .opacity(store.draggingOut == item.id ? 0.4 : 1)
                    .animation(.easeOut(duration: 0.16).speed(IslandMotion.speed), value: store.draggingOut)
                    .onHover { inside in
                        if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
                    }
                    .task(id: item.path) { store.thumbnails.load(item) }
                    .transition(sweeping
                        ? .shelfRemoval(delay: Double(min(index, 8)) * ShelfMotion.clearStagger, reduce: reduceMotion)
                        : .shelfLanding(delay: Double(landingIndex) * 0.045, reduce: reduceMotion))
                    .zIndex(hovered == item.id ? 1 : 0)
            }
        }
        .padding(.horizontal, Self.wellPadding)
        .padding(.vertical, Self.wellPadding)
        .animation(ShelfMotion.reflow.animation, value: store.dropTargeted)
        .animation(ShelfMotion.reflow.animation, value: store.importing)
        .animation(ShelfMotion.reflow.animation, value: items.map(\.id))

        let contentWidth = Self.rowWidth(tiles: items.count + store.importing + (store.dropTargeted ? 1 : 0))
        let overflows = contentWidth > width - 2 * Self.sidePadding
        return Group {
            if staticRender {
                // Images cannot draw the AppKit-backed scroll view: the same row, cut at the well's edge.
                row.frame(width: width - 2 * Self.sidePadding, alignment: .leading)
                    .clipped()
            } else {
                ScrollView(.horizontal, showsIndicators: false) { row }
                    .scrollClipDisabled(false)
            }
        }
        .frame(width: width - 2 * Self.sidePadding, height: Self.wellHeight, alignment: .leading)
        .mask {
            // Fade the far edge when the row runs on past it.
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .black.opacity(overflows ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 36)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.wellCorner, style: .continuous))
    }

    static func rowWidth(tiles n: Int) -> CGFloat {
        guard n > 0 else { return 0 }
        return CGFloat(n) * ShelfTileView.size.width + CGFloat(n - 1) * tileSpacing + 2 * wellPadding
    }

    private func isHovered(_ item: ShelfItem, index: Int) -> Bool {
        if let previewHover { return previewHover == index }
        return pointerInside && hovered == item.id && !store.dropTargeted
    }

    private func actions(for item: ShelfItem) -> ShelfTileActions {
        let id = item.id
        return ShelfTileActions(
            open: { store.open(id) },
            reveal: { store.reveal([id]) },
            remove: {
                withAnimation(ShelfMotion.removal.animation) { store.remove(id) }
                if hovered == id { hovered = nil }
            },
            copyPath: { store.copyPath(id) })
    }

    // MARK: Time

    private var frozen: Bool { staticRender || reduceMotion || previewTime != nil }

    private func time(_ date: Date) -> Double {
        if let previewTime { return previewTime }
        return date.timeIntervalSince(targetedSince) / IslandMotion.slowmo
    }
}

// MARK: - Header buttons

/// "Очистить" that asks once: the first click turns it into a red "Очистить всё?", the second clears;
/// it turns back by itself after a few seconds.
private struct ClearButton: View {
    let confirming: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(confirming ? L("Очистить всё?") : L("Очистить"))
                .font(ShelfTypography.font(11.5, 650))
                .foregroundStyle(confirming ? Color.white : (hover ? ShelfPalette.primary : ShelfPalette.secondary))
                .contentTransition(.interpolate)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    Capsule().fill(confirming ? AnyShapeStyle(ShelfPalette.danger.opacity(0.9))
                                              : AnyShapeStyle(Color.white.opacity(hover ? 0.14 : 0.08))))
                .overlay(Capsule().strokeBorder(Color.white.opacity(confirming ? 0.25 : 0.06), lineWidth: 0.6))
                .contentShape(Capsule())
        }
        .buttonStyle(ShelfPressStyle())
        .onHover { hover = $0 }
        .animation(ShelfMotion.hover.animation, value: hover)
        .animation(ShelfMotion.ghost.animation, value: confirming)
        .help(confirming ? L("Нажми ещё раз, чтобы убрать всё с полки") : L("Убрать всё с полки"))
    }
}

private struct HeaderIconButton: View {
    let glyph: ShelfGlyph.Kind
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ShelfGlyph(kind: glyph).icon(13, hover ? ShelfPalette.primary : ShelfPalette.secondary, weight: 1.4)
                .frame(width: 26, height: 24)
                .background(Capsule().fill(Color.white.opacity(hover ? 0.14 : 0.0)))
                .contentShape(Capsule())
        }
        .buttonStyle(ShelfPressStyle())
        .onHover { hover = $0 }
        .animation(ShelfMotion.hover.animation, value: hover)
        .help(help)
    }
}

struct ShelfPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(ShelfMotion.press.animation, value: configuration.isPressed)
    }
}

// MARK: - Preview environment

private struct ShelfPreviewHoverKey: EnvironmentKey { static let defaultValue: Int? = nil }
private struct ShelfPreviewTimeKey: EnvironmentKey { static let defaultValue: Double? = nil }
private struct ShelfPreviewConfirmClearKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Previews: the tile (by index) drawn hovered.
    var shelfPreviewHover: Int? {
        get { self[ShelfPreviewHoverKey.self] }
        set { self[ShelfPreviewHoverKey.self] = newValue }
    }

    /// Previews: seconds on the time-driven pieces' clock (marching border, ghost, arrow).
    var shelfPreviewTime: Double? {
        get { self[ShelfPreviewTimeKey.self] }
        set { self[ShelfPreviewTimeKey.self] = newValue }
    }

    /// Previews: "clear all" drawn asking for confirmation.
    var shelfPreviewConfirmClear: Bool {
        get { self[ShelfPreviewConfirmClearKey.self] }
        set { self[ShelfPreviewConfirmClearKey.self] = newValue }
    }
}
