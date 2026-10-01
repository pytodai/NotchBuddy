import SwiftUI
import NotchBuddyCore

/// The open island's list of session cards (shown by `ExpandedIslandView`).
///
/// Cards drop in one after another (22 ms apart, the flying hero mark first); one card
/// at a time is expanded (a click on another one moves the expansion there). The list takes its natural height,
/// so the island's silhouette follows an expanding card on its own spring (`IslandMotion.data`, the card's
/// spring too); past `maxHeight` it scrolls, the expanded card scrolled into view, and its bottom edge fades.
struct SessionCardList: View {
    let sessions: [AgentSession]
    let metrics: IslandMetrics
    /// Mounted with the list (cards cascade in), not arriving later (glows once).
    var fresh = true
    var hoveredKey: SessionKey?
    var rowRemoval: [SessionKey: RowRemoval] = [:]
    var raisedRows: Set<SessionKey> = []
    let actions: IslandActions

    @Environment(\.islandFilmTime) private var filmTime
    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandHeroKey) private var heroKey
    @Environment(\.islandEntrance) private var entrance
    @Environment(\.islandHeroFlies) private var heroFlies
    @Environment(\.islandReduceMotion) private var reduceMotion
    /// The expanded card, kept here unless the owner passed `expansion`.
    @State private var ownExpandedKey: SessionKey?
    private let expansion: Binding<SessionKey?>?
    /// The cards' natural height (with paddings), as last laid out.
    @State private var measured: CGFloat?

    init(sessions: [AgentSession], metrics: IslandMetrics, fresh: Bool = true, hoveredKey: SessionKey? = nil,
         rowRemoval: [SessionKey: RowRemoval] = [:], raisedRows: Set<SessionKey> = [], actions: IslandActions,
         expanded: SessionKey? = nil, expansion: Binding<SessionKey?>? = nil) {
        self.sessions = sessions
        self.metrics = metrics
        self.fresh = fresh
        self.hoveredKey = hoveredKey
        self.rowRemoval = rowRemoval
        self.raisedRows = raisedRows
        self.actions = actions
        self.expansion = expansion
        _ownExpandedKey = State(initialValue: expanded)
    }

    /// Which card is expanded: the owner's (`expansion`, e.g. to keep it while the list is closed and reopened),
    /// else the list's own.
    private var expandedKey: SessionKey? {
        get { expansion?.wrappedValue ?? ownExpandedKey }
        nonmutating set {
            if let expansion { expansion.wrappedValue = newValue } else { ownExpandedKey = newValue }
        }
    }

    static let sidePadding: CGFloat = 10
    /// The fading bottom edge of a scrolling list.
    static let fade: CGFloat = 26

    /// Tallest the list gets: five collapsed cards and half of the sixth (as before); with a card expanded,
    /// as much as the island's canvas allows under the header and above the usage footer.
    static func maxHeight(_ metrics: IslandMetrics, expanded: Bool) -> CGFloat {
        let collapsed = IslandLayout.rowsHeight(IslandLayout.maxVisibleRows + 1, metrics: metrics)
        guard expanded else { return collapsed }
        let header: CGFloat = metrics.style == .notch ? 0 : 48   // a notch header sits in the extra canvas strip
        let footer: CGFloat = 0.5 + 12 + 52 + 16
        return max(collapsed, IslandLayout.maxOpenHeight - header - footer - 8)
    }

    /// `n` collapsed cards with the list's top padding (the bottom one comes on top).
    static func collapsedCardsHeight(_ n: Int, _ metrics: IslandMetrics) -> CGFloat {
        let top: CGFloat = metrics.style == .notch ? 8 : 2
        guard n > 0 else { return top }
        return CGFloat(n) * SessionCardView.collapsedHeight + CGFloat(n - 1) * IslandLayout.rowSpacing + top
    }

    private func rowDelay(_ index: Int) -> Double {
        fresh ? 0.035 + 0.022 * Double(min(index, 5)) : 0.06
    }

    private var openKey: SessionKey? {
        guard let expandedKey, sessions.contains(where: { $0.key == expandedKey }) else { return nil }
        return expandedKey
    }

    private func toggle(_ key: SessionKey) {
        let animation = reduceMotion ? IslandMotion.reduced.animation : SessionCardView.expandAnimation
        withAnimation(animation) { expandedKey = expandedKey == key ? nil : key }
    }

    var body: some View {
        let open = openKey
        let cardActions = SessionCardActions(island: actions, toggle: toggle)
        let cards = VStack(spacing: IslandLayout.rowSpacing) {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                let hero = heroKey == session.key
                SessionCardView(
                    session: session,
                    expanded: open == session.key,
                    hovering: hoveredKey == session.key,
                    lateArrival: !fresh,
                    heroTextDelay: hero && fresh
                        ? rowDelay(index) + IslandMotion.heroTextLag(entrance, flies: heroFlies,
                                                                      notch: metrics.style == .notch, card: false)
                        : nil,
                    actions: cardActions
                )
                .equatable()
                .environment(\.islandIgniteDelay, rowDelay(index) + 0.06)
                .appearAfter(rowDelay(index), style: hero ? .heroRow : .row)
                .geometryGroup()
                .zIndex(raisedRows.contains(session.key) ? 1 : 0)
                .transition(.sessionRowRemoval(rowRemoval[session.key] ?? .fold, reduce: reduceMotion))
                .id(session.key)
            }
        }
        .padding(.horizontal, Self.sidePadding)
        .padding(.top, metrics.style == .notch ? 8 : 2)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            guard measured != height else { return }
            measured = height
        }

        // All collapsed, the cards' height is known exactly; with one expanded it is measured (a pass late, which
        // only decides whether the list scrolls: past the cap its height is the cap either way). The height itself
        // settles in the very layout pass of the change: under the content root's `fixedSize` a scroll view is as
        // tall as its content, clamped here to `cap`, so the island's silhouette retargets with the card's spring.
        let natural = open == nil ? Self.collapsedCardsHeight(sessions.count, metrics) + 10
                                  : (measured ?? Self.collapsedCardsHeight(sessions.count, metrics)) + 10
        let cap = Self.maxHeight(metrics, expanded: open != nil)
        let scrolls = natural > cap + 0.5
        // Scrolled to the end, the last card clears the bottom fade: that room is always there under the cards, and the
        // list's height leaves it out unless it scrolls (`ScrollCap`, decided in the same layout pass, so a card that
        // expands or moves its expansion changes the island's height once, not a pass later).
        let rows = cards.padding(.bottom, 10).padding(.bottom, Self.fade - 10)
        return Group {
            if staticRender || filmTime != nil {
                // Images cannot draw the AppKit-backed scroll view; the same cards, cut at the same height.
                ScrollCap(cap: cap, clearance: Self.fade - 10) { rows }
                    .clipped(antialiased: false)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) { rows }
                        .scrollDisabled(!scrolls)
                        // Not scrolling: a collapsing card may draw past the list for a moment (the island's
                        // silhouette, shrinking on the same spring, masks it).
                        .scrollClipDisabled(!scrolls)
                        .onChange(of: open) { _, key in
                            guard let key else { return }
                            // Once the new height has been measured: an expansion may be what makes it scroll.
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(20))
                                withAnimation(SessionCardView.expandAnimation) { proxy.scrollTo(key, anchor: .top) }
                            }
                        }
                }
                .modifier(ScrollCapModifier(cap: cap, clearance: Self.fade - 10))
            }
        }
        .mask(alignment: .top) {
            ZStack(alignment: .top) {
                Color.black.opacity(scrolls ? 0 : 1)
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: Self.fade)
                }
            }
            // Past the list's own bounds while it does not scroll (cards drop in from above, a collapsing card
            // may still reach below).
            .padding(.top, scrolls ? 0 : -40)
            .padding(.bottom, scrolls ? 0 : -600)
            .animation(IslandMotion.leaf, value: scrolls)
        }
    }
}

/// The list's height in one layout pass: its content's natural height without the fade's clearance when it fits under
/// `cap`, else `cap` (it scrolls, and the clearance lets the last card leave the fade).
struct ScrollCap: Layout {
    let cap: CGFloat
    let clearance: CGFloat

    func height(_ natural: CGFloat) -> CGFloat {
        natural - clearance <= cap + 0.5 ? natural - clearance : cap
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: natural.width, height: max(0, height(natural.height)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let natural = child.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        // Not scrolling: the content keeps its natural height (the clearance hangs below, unseen); scrolling: the view
        // is the cap tall.
        let scrolls = natural.height - clearance > cap + 0.5
        child.place(at: bounds.origin, anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: scrolls ? bounds.height : natural.height))
    }
}

/// `ScrollCap` around a view.
struct ScrollCapModifier: ViewModifier {
    let cap: CGFloat
    let clearance: CGFloat

    func body(content: Content) -> some View {
        ScrollCap(cap: cap, clearance: clearance) { content }
    }
}
