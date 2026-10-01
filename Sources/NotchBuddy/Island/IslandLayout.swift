import NotchBuddyCore
import SwiftUI

/// The silhouette's animated values. The shape is always centered on the canvas and hangs from its top edge
/// («Чёлка», `top` 0) or floats `top` points below it («Островок»), so only these numbers move.
struct IslandGeometry: Equatable {
    var width: CGFloat = 0
    var height: CGFloat = 0
    /// Concave top corners («Чёлка»: the ears flaring into the top edge).
    var ear: CGFloat = 0
    /// Convex bottom corners.
    var bottom: CGFloat = 0
    /// Opacity of the ambient drop shadow (its radius never changes).
    var shadow: Double = 0
    /// Distance of the shape's top from the canvas' top edge (0: flush with it; «Островок»: a few points below).
    var top: CGFloat = 0
    /// Convex top corners («Островок»: rounded all around). Where both this and `ear` are set (mid-morph between the
    /// styles) the larger one wins by their difference, so the corner passes smoothly from concave to convex.
    var crown: CGFloat = 0

    /// Where the shape ends (its bottom edge), from the canvas' top.
    var bottomEdge: CGFloat { top + height }

    /// How detached the shape is from the top edge, 0…1 (0 at the top edge, 1 from 3 points below it).
    var detachment: CGFloat { min(max(top / 3, 0), 1) }

    func interpolated(to other: IslandGeometry, _ p: Double) -> IslandGeometry {
        let k = CGFloat(p)
        return IslandGeometry(width: width + (other.width - width) * k,
                              height: height + (other.height - height) * k,
                              ear: ear + (other.ear - ear) * k,
                              bottom: bottom + (other.bottom - bottom) * k,
                              shadow: shadow + (other.shadow - shadow) * p,
                              top: top + (other.top - top) * k,
                              crown: crown + (other.crown - crown) * k)
    }
}

/// Sizes of the island. Content views take their natural size; the silhouette adds the concave "ears"
/// on both sides and breathes a little under the pointer.
enum IslandLayout {
    /// Room for the drop shadow and the springs' overshoot around the largest island.
    static let shadowMargin: CGFloat = 56

    static let collapsedMinWidth: CGFloat = 220
    static let collapsedMaxWidth: CGFloat = 390
    /// «Островок» closed: a compact capsule like the iPhone's Dynamic Island with a live activity — the main session's
    /// mascot at its leading end, its live status (and the usage ring, room permitting) at the trailing end, nothing in
    /// between. Its width is Settings → Остров → «Ширина капсулы» (`NotchSettings.capsuleWidthRange`, 190 pt out of the
    /// box); the content spans the capsule end to end (it has no ears to leave room for), so at rest the silhouette is
    /// exactly this wide. A change morphs the shape (the closed page lays out again, the data spring follows).
    nonisolated(unsafe) static var capsuleWidth = CGFloat(NotchSettings.defaultCapsuleWidth)
    static let capsuleWidthRange = CGFloat(NotchSettings.capsuleWidthRange.lowerBound)...CGFloat(NotchSettings.capsuleWidthRange.upperBound)
    /// The open list is wide and low (~38 % of the screen's width): this share of the screen, clamped.
    static let listShare: CGFloat = 0.38
    static let minListWidth: CGFloat = 600
    static let maxListWidth: CGFloat = 820
    /// The settings page keeps a readable column.
    private static let baseSettingsWidth: CGFloat = 500
    private static let baseCardWidth: CGFloat = 492
    private static let baseFlashWidth: CGFloat = 392
    /// Tallest open content (list with 5½ rows, the largest permission card). The panel canvas is this tall.
    static let maxOpenHeight: CGFloat = 640

    /// «Островок»: how far below the top edge of a screen without a notch the capsule floats (on a notched screen it
    /// floats this far below the camera housing).
    static let islandGap: CGFloat = 6
    /// «Островок» open: corner radius of the floating panel (the iPhone's expanded Dynamic Island is about this round).
    static let islandOpenRadius: CGFloat = 40

    static let openEar: CGFloat = 16
    /// Concentric with the cards (radius 16 + inset 10) and the card buttons.
    static let openBottom: CGFloat = 28

    /// On a notched screen the list header sits beside the camera housing, so the list is at least this
    /// much wider than the notch on each side; cards and notices start below the notch and only need a rim.
    private static let listWingMin: CGFloat = 158
    private static let rimWingMin: CGFloat = 64

    /// Settings → Остров → Размер (0.9 compact, 1 normal, 1.12 large): the open island's widths. The canvas is always
    /// sized for the largest (`maxWidthScale`), so a change is only a morph of the shape, never a panel resize.
    nonisolated(unsafe) static var widthScale: CGFloat = 1
    static let maxWidthScale: CGFloat = 1.12

    /// The list, the tab strip and the widgets' tabs (they share the strip, so they share its width).
    static func listWidth(_ metrics: IslandMetrics) -> CGFloat { width(baseListWidth(metrics), wing: listWingMin, metrics) }
    static func settingsWidth(_ metrics: IslandMetrics) -> CGFloat { width(baseSettingsWidth, wing: listWingMin, metrics) }

    /// The list's width before Settings → Размер: `listShare` of the screen, within `minListWidth…maxListWidth`.
    static func baseListWidth(_ metrics: IslandMetrics) -> CGFloat {
        min(max((metrics.screenWidth * listShare).rounded(), minListWidth), maxListWidth)
    }
    static func cardWidth(_ metrics: IslandMetrics) -> CGFloat { width(baseCardWidth, wing: rimWingMin, metrics) }
    static func flashWidth(_ metrics: IslandMetrics) -> CGFloat { width(baseFlashWidth, wing: rimWingMin, metrics) }
    /// The «Готово» card with the agent's answer: as wide as a permission card.
    static func doneWidth(_ metrics: IslandMetrics) -> CGFloat { width(baseCardWidth, wing: rimWingMin, metrics) }

    private static func width(_ base: CGFloat, wing: CGFloat, _ metrics: IslandMetrics,
                              scale: CGFloat = widthScale) -> CGFloat {
        let scaled = (base * min(max(scale, 0.8), maxWidthScale)).rounded()
        return metrics.style == .notch ? max(scaled, metrics.notchWidth + 2 * wing) : scaled
    }

    // MARK: Shape

    static func closedEar(_ metrics: IslandMetrics) -> CGFloat { metrics.style == .notch ? 9 : 11 }
    static func closedBottom(_ metrics: IslandMetrics) -> CGFloat { min(16, metrics.barHeight * 0.44) }
    static func idleBottom(_ metrics: IslandMetrics) -> CGFloat { min(10, metrics.barHeight * 0.3) }

    /// Where the silhouette is heading for a mode, its content size and the pointer. «Островок» (`metrics.gap` > 0)
    /// takes the same sizes as «Чёлка», detached: `gap` below the top edge, no ears (the body takes their width, so the
    /// content keeps a margin for the round top corners), the top corners as round as the bottom ones.
    static func geometry(mode: IslandMode, metrics: IslandMetrics, content: CGSize, hovering: Bool,
                         pressed: Bool, lastPillWidth: CGFloat) -> IslandGeometry {
        var g = attachedGeometry(mode: mode, metrics: metrics, content: content, hovering: hovering, pressed: pressed,
                                 lastPillWidth: lastPillWidth)
        guard metrics.gap > 0 else { return g }
        g.ear = 0
        if mode == .hidden {
            // Retracted: the capsule shrinks into its own middle (it never touched the top edge).
            g.top = metrics.gap + metrics.barHeight / 2
            g.crown = 0
        } else {
            g.top = metrics.gap
            // Like the Dynamic Island: closed it is a full capsule (the path clamps an oversized radius to the roundest
            // continuous corner the height allows); open it keeps big, soft corners all around.
            g.bottom = mode.isOpen ? max(g.bottom, islandOpenRadius) : max(g.bottom, g.height)
            g.crown = g.bottom
            // Closed, the content is the capsule end to end («Ширина капсулы»; widget faces bring their own margins).
            if mode == .collapsed { g.width = max(0, g.width - 2 * closedEar(metrics)) }
        }
        return g
    }

    /// The «Чёлка» shape (flush with the top edge).
    private static func attachedGeometry(mode: IslandMode, metrics: IslandMetrics, content: CGSize, hovering: Bool,
                                         pressed: Bool, lastPillWidth: CGFloat) -> IslandGeometry {
        let b = metrics.barHeight
        switch mode {
        case .hidden:
            if metrics.style == .notch {
                return IslandGeometry(width: metrics.notchWidth, height: b, ear: 0, bottom: idleBottom(metrics), shadow: 0)
            }
            // Retracted into the top edge: a drop half as wide, of no height (the ears form as it grows).
            return IslandGeometry(width: max(60, lastPillWidth * 0.45), height: 0, ear: 0, bottom: 0, shadow: 0)
        case .idle:
            var g = IslandGeometry(width: metrics.notchWidth, height: b, ear: 0, bottom: idleBottom(metrics), shadow: 0)
            if hovering {
                // The notch sprouts ears (the body stays the notch's width, so it covers no menu items).
                g.width += 10
                g.ear = 5
                g.height += 4
                g.shadow = 0.2
            }
            return g
        case .collapsed:
            let ear = closedEar(metrics)
            var g = IslandGeometry(width: content.width + 2 * ear, height: b, ear: ear, bottom: closedBottom(metrics), shadow: 0.18)
            if hovering || pressed {
                let notch = metrics.style == .notch
                g.width += notch ? 10 : 12
                g.height += notch ? 3 : 4
                g.ear += 2
                g.bottom += 1
                g.shadow = 0.28
            }
            if pressed {
                g.width -= 6
                g.height -= 2
                g.ear -= 1
                g.shadow = 0.22
            }
            return g
        case .flash:
            // A notice that stays in the notch strip keeps the closed island's corners.
            if content.height <= b + 0.5 {
                let ear = closedEar(metrics)
                return IslandGeometry(width: content.width + 2 * ear, height: content.height, ear: ear,
                                      bottom: closedBottom(metrics), shadow: 0.36)
            }
            return IslandGeometry(width: content.width + 2 * openEar, height: content.height, ear: openEar,
                                  bottom: openBottom, shadow: 0.45)
        case .expanded, .page:
            return IslandGeometry(width: content.width + 2 * openEar, height: content.height, ear: openEar,
                                  bottom: openBottom, shadow: 0.55)
        case .permission:
            return IslandGeometry(width: content.width + 2 * openEar, height: content.height, ear: openEar,
                                  bottom: openBottom, shadow: 0.6)
        }
    }

    /// Offset of closed content inside a grown (hovered / pressed) silhouette, so it stays centered.
    static func closedContentOffset(mode: IslandMode, metrics: IslandMetrics, geometry: IslandGeometry) -> CGFloat {
        guard !mode.isOpen, mode != .hidden else { return 0 }
        return max(0, (geometry.height - metrics.barHeight) / 2)
    }

    // MARK: Estimates (used only until a content view reports its size)

    static let rowHeight: CGFloat = 62
    static let rowSpacing: CGFloat = 2
    static let maxVisibleRows = 5

    /// Height of the list's rows block (with its paddings) for `n` sessions.
    static func rowsHeight(_ n: Int, metrics: IslandMetrics) -> CGFloat {
        let top: CGFloat = metrics.style == .notch ? 8 : 2
        guard n > 0 else { return 0 }
        let visible = CGFloat(min(n, maxVisibleRows))
        let natural = visible * rowHeight + (visible - 1) * rowSpacing + top + 10
        // Past five rows half of the next one peeks out to hint that the list scrolls.
        return n > maxVisibleRows ? natural + rowSpacing + rowHeight / 2 : natural
    }

    static func listHeight(n: Int, usageLoaded: Bool, metrics: IslandMetrics) -> CGFloat {
        let header: CGFloat = metrics.style == .notch ? metrics.barHeight : 48
        let rows = n == 0 ? 96 : rowsHeight(n, metrics: metrics)
        return header + rows
    }

    static func estimatedContentSize(_ kind: IslandContentKind, metrics: IslandMetrics, sessions: Int,
                                     usageLoaded: Bool) -> CGSize {
        switch kind {
        case .closed:
            if metrics.detached { return CGSize(width: capsuleWidth, height: metrics.barHeight) }
            return CGSize(width: metrics.style == .notch ? metrics.notchWidth + 2 * 56 : collapsedMinWidth + 60,
                          height: metrics.barHeight)
        case .expanded:
            return CGSize(width: listWidth(metrics), height: listHeight(n: sessions, usageLoaded: usageLoaded, metrics: metrics))
        case .permission: return CGSize(width: cardWidth(metrics), height: 330 + (metrics.style == .notch ? metrics.barHeight : 0))
        case .flash: return CGSize(width: flashWidth(metrics), height: 76 + (metrics.style == .notch ? metrics.barHeight : 0))
        case .page(let id):
            let width = id == "settings" ? settingsWidth(metrics) : listWidth(metrics)   // IslandSettings.pageID
            return CGSize(width: width, height: listHeight(n: 0, usageLoaded: usageLoaded, metrics: metrics))
        }
    }

    // MARK: Panel

    /// The panel's fixed size on a screen: the widest and tallest island plus shadow room. The panel is
    /// never resized while the island animates, only while it is retracted during a move to another screen.
    static func canvasSize(_ metrics: IslandMetrics) -> CGSize {
        let widestContent = max(width(baseListWidth(metrics), wing: listWingMin, metrics, scale: maxWidthScale),
                                width(baseSettingsWidth, wing: listWingMin, metrics, scale: maxWidthScale),
                                width(baseCardWidth, wing: rimWingMin, metrics, scale: maxWidthScale),
                                width(baseFlashWidth, wing: rimWingMin, metrics, scale: maxWidthScale),
                                metrics.style == .notch ? metrics.notchWidth + 2 * 160
                                    : max(collapsedMaxWidth, capsuleWidthRange.upperBound))
        let width = widestContent + 2 * openEar + 2 * shadowMargin
        // Room above for «Островок» (the same on both styles of a screen without a notch, so a switch between them is
        // a morph of the shape, never a resize of the panel).
        let above = max(metrics.gap, metrics.style == .notch ? 0 : islandGap)
        let height = maxOpenHeight + (metrics.style == .notch ? metrics.barHeight : 0) + above + shadowMargin
        // Even width: the canvas is centered on a whole-point anchor.
        return CGSize(width: (width / 2).rounded(.up) * 2, height: height.rounded(.up))
    }
}
