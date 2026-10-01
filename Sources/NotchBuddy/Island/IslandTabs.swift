import AppKit
import NotchBuddyCore
import SwiftUI

/// The open island's tabs: «Агенты» and every widget switched on in Settings → Островки, in that order.
///
/// With more than one, a strip sits in the header (`IslandTabsChrome`, its own page on the stage that stays while the
/// tabs under it swap): the active tab is a pill with its name that glides to the next one on the island's spring;
/// the others are icons with a dot when something is going on there. A click, or a horizontal swipe on the trackpad
/// while the pointer is on the island, switches tabs; the content slides toward the side the new tab lies on
/// (`IslandEntrance.slide`), the silhouette morphs to the new tab's size.
@MainActor
enum IslandTabs {
    /// The header the strip lives in: the notch's strip beside a notch, else a 46 pt row.
    static func headerHeight(_ metrics: IslandMetrics) -> CGFloat { metrics.style == .notch ? metrics.barHeight : 46 }

    /// The room a tab's content leaves free at its top (the header and its inset).
    static func headerBlock(_ metrics: IslandMetrics) -> CGFloat { headerHeight(metrics) + (metrics.style == .notch ? 0 : 2) }

    /// The tab's icon (the island's own icon set).
    static func icon(_ kind: WidgetKind) -> NBIcon {
        switch kind {
        case .agents: return .agent
        case .music: return .music
        case .calendar: return .calendar
        case .timer: return .timer
        case .system: return .cpu
        case .shelf: return .tray
        }
    }

    /// Whether `to` lies after `from` in the strip (its content comes in from the right).
    static func isForward(from: WidgetKind, to: WidgetKind, in tabs: [WidgetKind]) -> Bool {
        (tabs.firstIndex(of: to) ?? 0) >= (tabs.firstIndex(of: from) ?? 0)
    }

    /// The tab next to `tab` (nil at the strip's ends: a swipe there does nothing).
    static func neighbour(of tab: WidgetKind, in tabs: [WidgetKind], forward: Bool) -> WidgetKind? {
        guard let index = tabs.firstIndex(of: tab) else { return tabs.first }
        let next = index + (forward ? 1 : -1)
        return tabs.indices.contains(next) ? tabs[next] : nil
    }

    // MARK: Strip sizes

    static let itemSize: CGFloat = 26
    static let compactItemSize: CGFloat = 22
    static let itemSpacing: CGFloat = 2
    static let stripPadding: CGFloat = 2
    static let labelFontSize: CGFloat = 12
    static let labelWeight: CGFloat = 680

    /// The label's width in the active pill.
    static func labelWidth(_ kind: WidgetKind) -> CGFloat {
        let font = NBTypography.nsFont(size: labelFontSize, weight: labelWeight)
        return ceil((kind.title as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The widest strip that fits `available` points: the active tab named, icons alone, or smaller icons.
    static func style(tabs: [WidgetKind], active: WidgetKind, available: CGFloat) -> IslandTabStrip.Style {
        let n = CGFloat(tabs.count)
        let chrome = 2 * stripPadding + (n - 1) * itemSpacing
        let labeled = chrome + n * itemSize + 5 + 16 + labelWidth(active)
        if labeled <= available { return .labeled }
        if chrome + n * itemSize <= available { return .icons }
        return .compact
    }
}

// MARK: - Swipes

/// One trackpad gesture over the open island: decides early whether it is horizontal and, once the fingers have
/// travelled `threshold` sideways, asks for the neighbouring tab once. Deltas are in finger direction (negative:
/// fingers to the left, which asks for the next tab).
struct TabSwipeTracker {
    enum Axis { case undecided, horizontal, vertical }

    private(set) var axis: Axis = .undecided
    /// This gesture may switch tabs (on the shelf only one that started on the header does).
    private(set) var owns = true
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0
    private var fired = false
    private var ended = false

    static let threshold: CGFloat = 38
    /// Travel before the axis is decided.
    static let decideAfter: CGFloat = 8

    mutating func begin(owns: Bool) {
        self = TabSwipeTracker()
        self.owns = owns
    }

    mutating func reset() { self = TabSwipeTracker() }

    /// The fingers lifted: the axis stays (its momentum belongs to it) until the next gesture begins.
    mutating func end() { ended = true }

    /// Which way a sideways gesture that has not switched yet is heading (+1 next, −1 previous), for building ahead.
    var lean: Int {
        guard axis == .horizontal, owns, !fired, !ended, dx != 0 else { return 0 }
        return dx < 0 ? 1 : -1
    }

    /// Adds one scroll delta; +1 (next tab) or −1 (previous) once per gesture, else 0.
    mutating func add(dx: CGFloat, dy: CGFloat) -> Int {
        guard !ended else { return 0 }
        self.dx += dx
        self.dy += dy
        if axis == .undecided, abs(self.dx) + abs(self.dy) >= Self.decideAfter {
            axis = abs(self.dx) > abs(self.dy) * 1.3 ? .horizontal : .vertical
        }
        guard axis == .horizontal, owns, !fired, abs(self.dx) >= Self.threshold else { return 0 }
        fired = true
        return self.dx < 0 ? 1 : -1
    }
}

// MARK: - Chrome

/// The header of a tabbed open island: the strip on the left (beside a notch: in the left wing), the agents' status
/// chips next to it on «Агенты» when there is room, and ⚙️ 🔊 📌 on the right.
struct IslandTabsChrome: View {
    let state: IslandViewState
    let width: CGFloat

    var body: some View {
        let metrics = state.metrics
        let actions = state.actions
        let sessions = state.snapshot.sessions
        let active = state.activeTab
        let hub = WidgetHub.shared
        let badge: (WidgetKind) -> Color? = { hub.badge($0, sessions: sessions) }
        Group {
            if metrics.style == .notch {
                let wing = max(0, (width - metrics.notchWidth) / 2)
                NotchWingsLayout(notchWidth: metrics.notchWidth, minWing: wing, maxWing: wing) {
                    HStack(spacing: 0) {
                        IslandTabStrip(tabs: state.tabs, active: active,
                                       style: IslandTabs.style(tabs: state.tabs, active: active, available: wing - 20),
                                       badge: badge, select: actions.selectTab, hover: actions.prepareTab)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 8)
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        IslandHeaderButtons(pinned: state.pinned, pinBounce: state.pinBounce, actions: actions)
                    }
                    .padding(.trailing, 12)
                    .padding(.leading, 10)
                }
                .frame(height: metrics.barHeight)
            } else {
                HStack(spacing: 10) {
                    IslandTabStrip(tabs: state.tabs, active: active, style: .labeled, badge: badge,
                                   select: actions.selectTab, hover: actions.prepareTab)
                    if active == .agents, IslandStatusChips.hasChips(sessions) {
                        ViewThatFits(in: .horizontal) {
                            IslandStatusChips(sessions: sessions, style: .compact)
                            IslandStatusChips(sessions: sessions, style: .mini)
                            IslandStatusChips(sessions: sessions, style: .mini, limit: 1)
                            Color.clear.frame(width: 0, height: 0)
                        }
                        .transition(.opacity.animation(.easeOut(duration: 0.14).speed(IslandMotion.speed)))
                    }
                    Spacer(minLength: 6)
                    IslandHeaderButtons(pinned: state.pinned, pinBounce: state.pinBounce, actions: actions)
                        .padding(.leading, 2)
                }
                .padding(.leading, 12)
                .padding(.trailing, 12)
                .frame(height: 46)
                .padding(.top, 2)
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .appearAfter(0.02, style: .header)
    }
}

/// The tabs: a track with one pill (the active tab, named when there is room) that glides between them.
struct IslandTabStrip: View {
    enum Style { case labeled, icons, compact }

    let tabs: [WidgetKind]
    let active: WidgetKind
    let style: Style
    var badge: (WidgetKind) -> Color? = { _ in nil }
    let select: (WidgetKind) -> Void
    /// The pointer rests on a tab (its page is built ahead, so a click switches at once).
    var hover: (WidgetKind) -> Void = { _ in }

    @Namespace private var pill

    var body: some View {
        HStack(spacing: style == .compact ? 0 : IslandTabs.itemSpacing) {
            ForEach(tabs, id: \.self) { kind in
                IslandTabButton(kind: kind, active: kind == active, showsLabel: style == .labeled && kind == active,
                                size: style == .compact ? IslandTabs.compactItemSize : IslandTabs.itemSize,
                                badge: badge(kind), pill: pill, hover: { hover(kind) }) { select(kind) }
            }
        }
        .padding(IslandTabs.stripPadding)
        .background(Capsule().fill(Color.white.opacity(0.055)))
        .fixedSize()
    }
}

/// One tab: its icon (and, active, its name on the pill); a dot when its widget has something going on.
private struct IslandTabButton: View {
    let kind: WidgetKind
    let active: Bool
    let showsLabel: Bool
    let size: CGFloat
    let badge: Color?
    let pill: Namespace.ID
    var hover: () -> Void = {}
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                NBIconView(IslandTabs.icon(kind), size: size * 0.62,
                           color: active ? .white : hovering ? Color.white.opacity(0.86) : IslandPalette.secondary,
                           active: hovering && !active)
                if showsLabel {
                    Text(kind.title)
                        .font(.manrope(IslandTabs.labelFontSize, weight: IslandTabs.labelWeight))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(labelTransition)
                }
            }
            .padding(.leading, showsLabel ? 7 : 0)
            .padding(.trailing, showsLabel ? 9 : 0)
            .frame(minWidth: size, minHeight: size)
            .background {
                if active {
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
                        .matchedGeometryEffect(id: "pill", in: pill)
                } else if hovering {
                    Capsule().fill(Color.white.opacity(0.07))
                }
            }
            .overlay(alignment: .topTrailing) {
                if let badge, !active {
                    Circle()
                        .fill(badge)
                        .frame(width: 5.5, height: 5.5)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.9), lineWidth: 1))
                        .offset(x: -2.5, y: 3)
                        .transition(.scale(scale: 0.3).combined(with: .opacity).animation(IslandMotion.pop))
                }
            }
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.14).speed(IslandMotion.speed), value: hovering)
        }
        .buttonStyle(SquishButtonStyle(amount: 0.1))
        .focusable(false)
        .onHover { inside in
            hovering = inside
            if inside, !active { hover() }
        }
        .help(kind.title)
        .accessibilityLabel(kind.title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// The name comes in after the pill has started to move, and leaves at once.
    private var labelTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: -5)).animation(IslandMotion.leaf.delay(0.05)),
                           removal: .opacity.animation(.easeOut(duration: 0.06).speed(IslandMotion.speed)))
    }
}

// MARK: - Usage footer

/// The list's usage: every agent's rows (`AgentUsageFooterView`) for the chosen provider, and a click steps through
/// Авто → Claude → Codex → Kimi. Without the multi-agent readers (previews, the benchmark) it is Claude's own
/// `UsageView`.
struct IslandUsageFooter: View {
    let snapshot: IslandSnapshot
    let barDelay: Double
    let cycle: () -> Void

    var body: some View {
        if snapshot.agentUsages.isEmpty, snapshot.usageChoice == .auto {
            UsageView(usage: snapshot.usage, barDelay: barDelay)
        } else {
            AgentUsageFooterView(usages: UsageSelection.rows(snapshot.agentUsages, choice: snapshot.usageChoice),
                                 delay: barDelay - 0.1, choice: snapshot.usageChoice)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(IslandMotion.data.animation) { cycle() }
                }
                .help(L("Чьи лимиты: %@. Клик — следующий (Авто → Claude → Codex → Kimi)", snapshot.usageChoice.label))
        }
    }
}
