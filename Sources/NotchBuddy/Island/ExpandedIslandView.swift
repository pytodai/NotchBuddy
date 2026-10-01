import SwiftUI
import NotchBuddyCore

/// The open island: a wide panel, its header a strip with the usage readout of one agent
/// (`IslandUsageStrip`, a click switches agent) and ⚙️ 🔊 📌; under it dense three-line session rows (expandable).
///
/// Motion: the list as a whole only fades in (the growing silhouette uncovers it); the header and each
/// row drop in one after another, 22 ms apart, as the silhouette uncovers them. A card that
/// arrives later glows once; a removed card swipes out (×) or folds away (expired); cards that move up
/// pass above the others. A click on a card expands it in place (one at a time), the silhouette following it
/// on the same spring.
struct ExpandedIslandView: View {
    let snapshot: IslandSnapshot
    let metrics: IslandMetrics
    let width: CGFloat
    /// The tab strip draws the header (`IslandTabsChrome`): the list leaves its room free.
    var tabbed = false
    let pinned: Bool
    var pinBounce = 0
    var hoveredRowKey: SessionKey?
    var rowRemoval: [SessionKey: RowRemoval] = [:]
    var raisedRows: Set<SessionKey> = []
    /// The expanded card, kept by the island while it stays open (nil: the list keeps its own).
    var expansion: Binding<SessionKey?>?
    let actions: IslandActions

    @Environment(\.islandFilmTime) private var filmTime
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.islandPageModel) private var pageModel
    /// Monotonic seconds (`AppClock.monotonicSeconds`) when the list mounted.
    @State private var mountedAt = AppClock.monotonicSeconds()

    static let sidePadding: CGFloat = 10
    /// Text lines up at 22 pt from the island's edge (cards: 10 inset + 12 content padding).
    static let textInset: CGFloat = 22

    var body: some View {
        let sessions = snapshot.sessions
        // Fresh (its rows cascade in): just mounted, or built ahead and not shown yet.
        let fresh = filmTime != nil || pageModel.map { !$0.revealed } ?? false || AppClock.monotonicSeconds() - mountedAt < 0.4
        VStack(spacing: 0) {
            if tabbed {
                Color.clear.frame(height: IslandTabs.headerBlock(metrics))
                // The strip holds the tabs: the usage readout gets a row of its own on «Агенты».
                HStack(spacing: 8) {
                    IslandUsageStrip(snapshot: snapshot, cycle: actions.cycleUsage)
                    Spacer(minLength: 8)
                    if IslandStatusChips.hasChips(sessions) {
                        IslandStatusChips(sessions: sessions, style: .mini, limit: 3)
                    }
                }
                .padding(.leading, ExpandedIslandView.textInset - 7)
                .padding(.trailing, 16)
                .frame(height: 30)
                .appearAfter(0.02, style: .header)
            } else {
                IslandListHeader(snapshot: snapshot, metrics: metrics, width: width, pinned: pinned, pinBounce: pinBounce,
                                 actions: actions)
                    .appearAfter(0.02, style: .header)
            }
            ZStack(alignment: .top) {
                if sessions.isEmpty {
                    emptyState
                        .appearAfter(0.05, style: .section)
                        .transition(.opacity.animation(.easeOut(duration: 0.15).speed(IslandMotion.speed)))
                } else {
                    SessionCardList(sessions: sessions, metrics: metrics, fresh: fresh, hoveredKey: hoveredRowKey,
                                    rowRemoval: rowRemoval, raisedRows: raisedRows, actions: actions,
                                    expansion: expansion)
                }
            }
        }
        .frame(width: width)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            EmptyStateMark()
                .padding(.bottom, 4)
            Text(L("Пока тихо"))
                .font(.manrope(14, weight: 700))
                .foregroundStyle(IslandPalette.primary)
            Text(L("Запусти Claude Code, Codex или Kimi —\nсессии появятся здесь сами."))
                .font(.manrope(11.5, weight: 520))
                .foregroundStyle(IslandPalette.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
        .padding(.top, metrics.style == .notch ? 14 : 6)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
    }

}

// MARK: - Header

/// The list's header strip. Without a notch: the usage readout (`IslandUsageStrip`) on the left, the status chips when
/// there is room (compact or icon-only, whichever fits), then ⚙️ 🔊 📌 on the right. Beside a notch it lives in the strip
/// next to the camera housing, each side fitted to its wing (`NotchWingsLayout`): the usage on the left, the buttons on
/// the right; nothing slides under the camera.
struct IslandListHeader: View {
    let snapshot: IslandSnapshot
    private var sessions: [AgentSession] { snapshot.sessions }
    let metrics: IslandMetrics
    let width: CGFloat
    let pinned: Bool
    var pinBounce = 0
    let actions: IslandActions

    private var notch: Bool { metrics.style == .notch }
    /// Someone works, waits or failed (the chips show only those).
    private var hasChips: Bool { sessions.contains { [.working, .waitingForUser, .error].contains($0.status) } }

    var body: some View {
        Group {
            if notch {
                let wing = max(0, (width - metrics.notchWidth) / 2)
                NotchWingsLayout(notchWidth: metrics.notchWidth, minWing: wing, maxWing: wing) {
                    // The usage (it gives way down to one window) and, when there is room, the most urgent status.
                    HStack(spacing: 8) {
                        usage
                        ViewThatFits(in: .horizontal) {
                            if hasChips { chips(.mini, limit: 1) }
                            Color.clear.frame(width: 0)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, ExpandedIslandView.textInset - 7)
                    .padding(.trailing, 10)
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        buttons
                    }
                    .padding(.trailing, 12)
                    .padding(.leading, 10)
                }
                .frame(height: metrics.barHeight)
            } else {
                HStack(spacing: 8) {
                    usage
                    Spacer(minLength: 8)
                    if hasChips {
                        ViewThatFits(in: .horizontal) {
                            chips(.compact)
                            chips(.mini)
                            Color.clear.frame(width: 0)
                        }
                    }
                    buttons
                        .padding(.leading, 2)
                }
                .padding(.leading, ExpandedIslandView.textInset - 7)
                .padding(.trailing, 12)
                .frame(height: 46)
                .padding(.top, 2)
            }
        }
        .contentShape(Rectangle())
    }

    private var usage: some View {
        IslandUsageStrip(snapshot: snapshot, cycle: actions.cycleUsage)
            .layoutPriority(1)
    }

    private var title: some View {
        HStack(spacing: 7) {
            Text(L("Сессии"))
                .font(.manrope(12.5, weight: 720))
                .foregroundStyle(IslandPalette.secondary)
                .lineLimit(1)
                .fixedSize()
            if !sessions.isEmpty {
                NumberRoll("\(sessions.count)", font: .manrope(11, weight: 720, tabular: true))
                    .foregroundStyle(Color.white.opacity(0.86))
                    .padding(.horizontal, 6)
                    .frame(minWidth: 19)
                    .frame(height: 18)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .fixedSize()
                    .transition(.scale(scale: 0.6).combined(with: .opacity).animation(IslandMotion.pop))
            }
        }
    }

    private func chips(_ style: SummaryChip.Style, limit: Int = 3) -> some View {
        IslandStatusChips(sessions: sessions, style: style, limit: limit)
    }

    private var buttons: some View {
        IslandHeaderButtons(pinned: pinned, pinBounce: pinBounce, actions: actions)
    }
}

/// Status chips, the most urgent first (waiting, failed, working), at most `limit`.
struct IslandStatusChips: View {
    let sessions: [AgentSession]
    let style: SummaryChip.Style
    var limit = 3

    static func hasChips(_ sessions: [AgentSession]) -> Bool {
        sessions.contains { [.working, .waitingForUser, .error].contains($0.status) }
    }

    var body: some View {
        let counts: [(SessionStatus, Int, String)] = [
            // Russian one|few|many forms: the plural key (`Lp`) — English has its own one|other.
            (.waitingForUser, sessions.filter { $0.status == .waitingForUser }.count, "ждёт|ждут|ждут"),
            (.error, sessions.filter { $0.status == .error }.count, "ошибка|ошибки|ошибок"),
            (.working, sessions.filter { $0.status == .working }.count, "работает|работают|работают"),
        ]
        let shown = Array(counts.filter { $0.1 > 0 }.prefix(limit))
        HStack(spacing: style == .mini ? 7 : 5) {
            ForEach(shown, id: \.0) { status, count, forms in
                SummaryChip(count: count, label: Lp(count, forms), status: status, style: style)
            }
        }
        .fixedSize()
    }
}

/// ⚙️ 🔊 📌 on the right of the open island's header (the list's, or the tab strip's).
struct IslandHeaderButtons: View {
    let pinned: Bool
    var pinBounce = 0
    let actions: IslandActions

    var body: some View {
        HStack(spacing: 6) {
            IslandGlyphButton(icon: .settings, help: L("Настройки")) { actions.showPage(IslandSettings.pageID) }
            SoundButton()
            PinButton(pinned: pinned, bounce: pinBounce, action: actions.togglePin)
        }
        .fixedSize()
    }
}

/// The empty list's mark: the idle icon (static: a loop's frames would be committed with every page built).
private struct EmptyStateMark: View {
    var body: some View {
        NBIconView(.idle, size: 26, color: IslandPalette.tertiary)
            .frame(width: 44, height: 44)
            .background(Circle().fill(Color.white.opacity(0.06)))
    }
}

/// Sounds on/off right on the island: the same switch as «Звуки» in the menu bar menu and in Settings.
struct SoundButton: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        let enabled = store.values.soundsEnabled
        IslandGlyphButton(icon: .soundOn, value: enabled ? 1 : 0,
                          help: enabled ? L("Выключить звуки") : L("Включить звуки")) {
            store.values.soundsEnabled.toggle()
        }
    }
}

/// The pin: tilted when free, pushed in when pinned (it bounces as it latches).
struct PinButton: View {
    let pinned: Bool
    let bounce: Int
    let action: () -> Void
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        IslandGlyphButton(icon: .pin, value: pinned ? 1 : 0, active: pinned,
                          help: pinned ? L("Открепить: список закроется, когда уведёшь курсор") : L("Закрепить открытым"),
                          action: action)
            .keyframeAnimator(initialValue: CGFloat(0), trigger: reduceMotion ? 0 : bounce) { view, dy in
                view.offset(y: dy)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(2.5, duration: IslandMotion.t(0.08))
                    SpringKeyframe(0, duration: IslandMotion.t(0.3), spring: IslandMotion.kspring(0.22, 0.5))
                }
            }
    }
}

/// "● 2 работают" in the header; compact: the status icon and the number; mini: the same without a capsule.
struct SummaryChip: View {
    enum Style { case full, compact, mini }

    let count: Int
    let label: String
    let status: SessionStatus
    let style: Style

    var body: some View {
        let tint = status.tint
        HStack(spacing: 4) {
            NBIconView(NBIcon.status(status), size: style == .mini ? 12 : 11, color: tint)
            NumberRoll("\(count)", font: .manrope(11, weight: 700, tabular: true))
            if style == .full {
                Text(label)
                    .font(.manrope(11, weight: 660))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, style == .mini ? 0 : style == .compact ? 7 : 8)
        .frame(height: 24)
        .background(Capsule().fill(tint.opacity(style == .mini ? 0 : 0.13)))
        .transition(.scale(scale: 0.6).combined(with: .opacity).animation(IslandMotion.pop))
    }
}

private struct RowSwipeEffect: ViewModifier, Animatable {
    var q: Double

    var animatableData: Double {
        get { q }
        set { q = newValue }
    }

    func body(content: Content) -> some View {
        content
            .offset(x: 28 * CGFloat(q))
            .scaleEffect(1 - 0.02 * CGFloat(q))
            .blur(radius: 4 * CGFloat(q))
            .opacity(1 - q)
    }
}

private struct RowFoldEffect: ViewModifier, Animatable {
    var q: Double

    var animatableData: Double {
        get { q }
        set { q = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - 0.04 * CGFloat(q))
            .blur(radius: 4 * CGFloat(q))
            .opacity(1 - q)
    }
}

extension AnyTransition {
    /// A row leaving the list; the rows below close the gap with the data spring.
    static func sessionRowRemoval(_ style: RowRemoval, reduce: Bool = false) -> AnyTransition {
        if reduce {
            return .asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.16).speed(IslandMotion.speed)))
        }
        switch style {
        case .swipe:
            return .asymmetric(insertion: .identity,
                               removal: .modifier(active: RowSwipeEffect(q: 1), identity: RowSwipeEffect(q: 0))
                                .animation(.easeIn(duration: 0.16).speed(IslandMotion.speed)))
        case .fold:
            return .asymmetric(insertion: .identity,
                               removal: .modifier(active: RowFoldEffect(q: 1), identity: RowFoldEffect(q: 0))
                                .animation(.easeOut(duration: 0.18).speed(IslandMotion.speed)))
        }
    }
}
