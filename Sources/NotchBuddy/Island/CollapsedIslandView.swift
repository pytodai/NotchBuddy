import SwiftUI
import NotchBuddyCore

/// The closed island as a "live activity" for the most important session (waiting > working > error >
/// finished): its agent, a live indicator and a short status, the other sessions as "+N" and Claude's
/// 5-hour usage ring.
///
/// Without a notch it is one row, 220–360 pt wide, whose project name gives way first. On a notched
/// screen it is two narrow wings beside the camera housing (the agent and its indicator on the left,
/// the usage ring on the right), so the menus next to the notch stay visible. «Островок» is a compact
/// capsule instead (`IslandCapsuleFace`): the mascot and the live status at its two ends, no text.
struct CollapsedIslandView: View {
    let snapshot: IslandSnapshot
    let metrics: IslandMetrics
    /// «Островок»: Settings → «Ширина капсулы» (an input, so a change re-renders the capsule).
    var capsuleWidth = IslandLayout.capsuleWidth

    var body: some View {
        Group {
            switch metrics.style {
            case .floating: floating
            case .notch: notched
            }
        }
        .frame(height: metrics.barHeight)
        // Its live indicator ignites once the island has landed.
        .environment(\.islandIgniteDelay, 0.18)
    }

    /// Filmstrips: the row's width at the filmed moment (live, SwiftUI interpolates the row's layout).
    @Environment(\.islandFilmPillWidth) private var filmWidth
    @Environment(\.islandFilmTime) private var filmTime
    @Environment(\.islandEntrance) private var entrance
    @Environment(\.islandReduceMotion) private var reduceMotion

    /// The agent mark swapping for another session's (Reduce Motion: a plain cross-fade).
    private var markSwap: AnyTransition {
        reduceMotion ? .opacity.animation(IslandMotion.leaf) : AnyTransition(.blurReplace).animation(IslandMotion.leaf)
    }

    /// Filmstrips of the first session on a notched screen: the wings' insertion at the filmed moment.
    private var filmWing: Double? {
        guard let filmTime, entrance == .pop else { return nil }
        return NotchWingEffect.insertion.progress(filmTime)
    }

    /// The primary session's mascot (`HeroSlot`).
    static let mascotSize: CGFloat = 28

    private var others: Int { max(0, snapshot.sessions.count - 1) }
    /// The usage ring (Settings → Лимиты): the chosen agent's, or with «Авто» the shown session's agent's; Claude's
    /// 5-hour window when only Claude's own reader runs.
    private var usage: Double? {
        guard snapshot.showsUsageRing else { return nil }
        if snapshot.agentUsages.isEmpty { return snapshot.usage.fiveHourUtilization }
        return UsageSelection.ring(snapshot.agentUsages, choice: snapshot.usageChoice, focus: snapshot.primary?.key.source)?.used
    }

    // MARK: Without a notch

    @ViewBuilder
    private var floating: some View {
        if metrics.detached {
            capsule
        } else if let session = snapshot.primary {
            LiveActivityRow(minWidth: filmWidth ?? IslandLayout.collapsedMinWidth,
                            maxWidth: filmWidth ?? IslandLayout.collapsedMaxWidth) {
                // The session's pixel mascot: 28 pt draws it at 3 device pixels per art pixel on a Retina screen
                // (a 30 pt sprite), at 1 on a 1x one (20 pt).
                ZStack {
                    HeroSlot(session: session, size: Self.mascotSize)
                        .id(session.key)
                        .transition(markSwap)
                }
                .frame(width: Self.mascotSize, height: Self.mascotSize)
                .padding(.leading, 6)
                Text(session.title)
                    .font(.manrope(13, weight: 680))
                    .foregroundStyle(IslandPalette.primary)
                    .lineLimit(1)
                    // Cut at the end: a title reads from its start («Сделай графики пла…»), not around a hole.
                    .truncationMode(.tail)
                    .contentTransition(.interpolate)
                    .padding(.leading, 9)
                    .layoutValue(key: RowRole.self, value: .shrinks)
                HStack(spacing: 6) {
                    LiveIndicator(status: session.status, size: 13, episode: session.episode, key: session.key)
                    StatusText(session: session)
                }
                .padding(.leading, 9)
                Color.clear
                    .frame(width: 12)
                    .layoutValue(key: RowRole.self, value: .slack)
                if others > 0 {
                    OthersBadge(count: others)
                        .padding(.trailing, usage == nil ? 0 : 8)
                        .transition(.scale(scale: 0.5).combined(with: .opacity).animation(IslandMotion.pop))
                }
                if let usage {
                    UsageRing(utilization: usage, size: 14)
                        .modifier(UsageRingSlot())
                }
                Color.clear.frame(width: 12)
            }
            // Text centered on the menu bar's text line, not on the taller island.
            .offset(y: -1.5)
        } else {
            // No session (Settings → «Показывать без сессий»): a quiet pill that still shows the usage.
            HStack(spacing: 8) {
                NBIconView(.idle, size: 18, color: IslandPalette.tertiary)
                Text(L("Нет сессий"))
                    .font(.manrope(12.5, weight: 620))
                    .foregroundStyle(IslandPalette.secondary)
                    .lineLimit(1)
                    .fixedSize()
                if let usage {
                    UsageRing(utilization: usage, size: 14)
                        .modifier(UsageRingSlot())
                        .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 16)
            .frame(minWidth: IslandLayout.collapsedMinWidth * 0.7)
            .offset(y: -1.5)
        }
    }

    /// «Островок», closed: the compact capsule at Settings → «Ширина капсулы» — the main session's mascot (or, with no
    /// session, a quiet idle mark) at the leading end, its live status at the trailing end.
    private var capsule: some View {
        let session = snapshot.primary
        return IslandCapsuleFace(width: capsuleWidth, height: metrics.barHeight, status: session?.status,
                                 episode: session?.episode, key: session?.key, usage: usage, others: others) {
            if let session {
                ZStack {
                    HeroSlot(session: session, size: Self.mascotSize)
                        .id(session.key)
                        .transition(markSwap)
                }
            } else {
                NBIconView(.idle, size: 18, color: IslandPalette.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.map { "\($0.title), \($0.status.label)" } ?? L("Нет сессий"))
    }

    // MARK: Notch

    private var notched: some View {
        NotchWingsLayout(notchWidth: metrics.notchWidth, minWing: snapshot.primary == nil ? 0 : 44, maxWing: 64) {
            ZStack(alignment: .leading) {
                if let session = snapshot.primary {
                    HStack(spacing: 6) {
                        ZStack {
                            HeroSlot(session: session, size: Self.mascotSize)
                                .id(session.key)
                                .transition(markSwap)
                        }
                        .frame(width: Self.mascotSize, height: Self.mascotSize)
                        LiveIndicator(status: session.status, size: 12, episode: session.episode, key: session.key)
                    }
                    .padding(.leading, 8)
                    .modifier(NotchWingEffect(p: filmWing ?? 1, dx: NotchWingEffect.slide))
                    // At the silhouette's edge while it is still narrower than the wings.
                    .modifier(NotchWingInset(sign: 1))
                    .transition(.notchWing(edge: .leading, reduce: reduceMotion))
                }
            }
            ZStack(alignment: .trailing) {
                if snapshot.primary != nil {
                    rightWing
                        .padding(.trailing, 10)
                        .modifier(NotchWingEffect(p: filmWing ?? 1, dx: -NotchWingEffect.slide))
                        .modifier(NotchWingInset(sign: -1))
                        .transition(.notchWing(edge: .trailing, reduce: reduceMotion))
                }
            }
        }
    }

    @ViewBuilder
    private var rightWing: some View {
        if let usage {
            UsageRing(utilization: usage, size: 14, showsPercent: false)
                .modifier(UsageRingSlot())
                .overlay(alignment: .topTrailing) {
                    if others > 0 {
                        CountDot(count: others)
                            .offset(x: 6, y: -5)
                            .transition(.scale(scale: 0.4).combined(with: .opacity).animation(IslandMotion.pop))
                    }
                }
        } else if others > 0 {
            OthersBadge(count: others, fontSize: 11)
        } else {
            Color.clear.frame(width: 14, height: 14)
        }
    }
}

// MARK: - «Островок»

/// The capsule's proportions and what its trailing end has room for (`IslandCapsuleFace`).
enum IslandCapsule {
    static var mascotSize: CGFloat { CollapsedIslandView.mascotSize }
    static let indicatorSize: CGFloat = 12
    static let ringSize: CGFloat = 14
    /// Between the ring and the status (room for the count dot on the ring).
    static let ringGap: CGFloat = 10
    /// The least black between the two ends.
    static let minMiddle: CGFloat = 12
    private static let badgeWidth: CGFloat = 28

    /// The mascot's slot from the round end: a touch more than from the top and bottom (the sprite's own transparent
    /// margin then reads as even all around).
    static func leadingInset(_ height: CGFloat) -> CGFloat { max(5, ((height - mascotSize) / 2 + 4).rounded()) }
    /// The last item is concentric with the round end (as the iPhone's trailing glyph is).
    static func trailingInset(_ height: CGFloat, item: CGFloat) -> CGFloat { max(6, ((height - item) / 2).rounded()) }

    /// What the trailing end shows at a width: the ring first, else «+N».
    struct Fit: Equatable {
        var ring: Bool
        var badge: Bool
    }

    static func fit(width: CGFloat, height: CGFloat, status: Bool, usage: Bool, others: Int) -> Fit {
        let last: CGFloat = status ? indicatorSize : ringSize
        var room = width - leadingInset(height) - mascotSize - minMiddle - trailingInset(height, item: last)
        if status { room -= indicatorSize }
        if usage, room >= ringSize + (status ? ringGap : 0) { return Fit(ring: true, badge: false) }
        return Fit(ring: false, badge: others > 0 && room >= badgeWidth + (status ? 7 : 0))
    }
}

/// «Островок», closed: a compact capsule like the iPhone's Dynamic Island with a live activity. The leading end holds
/// the main session's mascot (`leading`), the trailing end its live status; the usage ring sits inward of the status
/// (a dot on it counts the other sessions) when the capsule has room for it, else «+N» when that fits. Nothing in
/// between and no text: the project, the status and its clock are one hover away (the list). Exactly `width` wide, so
/// the silhouette is the capsule the user set (`IslandLayout.capsuleWidth`); the settings' preview draws this very face.
struct IslandCapsuleFace<Leading: View>: View {
    let width: CGFloat
    let height: CGFloat
    /// nil: no session (the quiet capsule shows only the usage).
    var status: SessionStatus?
    var episode: String?
    var key: SessionKey?
    var usage: Double?
    var others = 0
    /// The island's ring reports where it is (a click on it switches whose limits it shows); the preview's does not.
    var reportsRing = true
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        let fit = IslandCapsule.fit(width: width, height: height, status: status != nil, usage: usage != nil, others: others)
        let last: CGFloat = status != nil ? IslandCapsule.indicatorSize : fit.ring ? IslandCapsule.ringSize : 20
        HStack(spacing: 0) {
            leading()
                .frame(width: IslandCapsule.mascotSize, height: IslandCapsule.mascotSize)
                .padding(.leading, IslandCapsule.leadingInset(height))
            Spacer(minLength: IslandCapsule.minMiddle)
            if fit.ring, let usage {
                ring(usage)
                    .padding(.trailing, status == nil ? 0 : IslandCapsule.ringGap)
                    .transition(.scale(scale: 0.5).combined(with: .opacity).animation(IslandMotion.pop))
            } else if fit.badge {
                OthersBadge(count: others, fontSize: 11)
                    .padding(.trailing, status == nil ? 0 : 7)
                    .transition(.scale(scale: 0.5).combined(with: .opacity).animation(IslandMotion.pop))
            }
            if let status {
                LiveIndicator(status: status, size: IslandCapsule.indicatorSize, episode: episode, key: key)
            }
            Color.clear.frame(width: IslandCapsule.trailingInset(height, item: last), height: 1)
        }
        .frame(width: width, height: height)
    }

    @ViewBuilder
    private func ring(_ usage: Double) -> some View {
        let ring = UsageRing(utilization: usage, size: IslandCapsule.ringSize, showsPercent: false)
            .overlay(alignment: .topTrailing) {
                if others > 0 {
                    CountDot(count: others)
                        .offset(x: 6, y: -5)
                        .transition(.scale(scale: 0.4).combined(with: .opacity).animation(IslandMotion.pop))
                }
            }
        if reportsRing { ring.modifier(UsageRingSlot()) } else { ring }
    }
}

/// "2" in a tiny capsule on the notch's usage ring: more sessions than the closed island shows.
private struct CountDot: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.manrope(8.5, weight: 760, tabular: true))
            .monospacedDigit()
            .foregroundStyle(Color.black)
            .contentTransition(.numericText(value: Double(count)))
            .animation(IslandMotion.leaf, value: count)
            .padding(.horizontal, 3)
            .frame(minWidth: 11, minHeight: 11)
            .background(Capsule().fill(Color.white.opacity(0.9)))
            .overlay(Capsule().strokeBorder(Color.black, lineWidth: 1.5))
    }
}

/// "работает 2:14", "ждёт тебя 0:45", "готово".
private struct StatusText: View {
    let session: AgentSession
    @Environment(IslandClock.self) private var clock: IslandClock?
    @Environment(\.islandFilmTime) private var filmTime
    @Environment(\.islandFilmPreviousStatus) private var previous

    var body: some View {
        if let filmTime, let before = previous[session.key], before != session.status {
            // Filmstrips: the old status gives way to the new one (live: an interpolated text change).
            let p = min(max(IslandMotion.leafCurve.progress(filmTime), 0), 1)
            label(session.status, since: session.statusSince)
                .opacity(p)
                .blur(radius: 3 * (1 - p))
                .overlay(alignment: .leading) {
                    label(before, since: session.statusSince.addingTimeInterval(-134))
                        .opacity(1 - p)
                        .blur(radius: 3 * p)
                }
        } else {
            label(session.status, since: session.statusSince)
        }
    }

    private func label(_ status: SessionStatus, since: Date) -> some View {
        HStack(spacing: 4) {
            Text(status.shortLabel)
                .foregroundStyle(Self.labelColor(status))
                .contentTransition(.interpolate)
            if status.runsClock {
                Text(IslandFormat.clock((clock?.now ?? Date()).timeIntervalSince(since)))
                    .font(.manrope(12.5, weight: 600, tabular: true))
                    .foregroundStyle(Color.white.opacity(0.88))
                    // Room for "00:00": the island does not twitch as the clock ticks.
                    .frame(minWidth: 36, alignment: .leading)
                    .transition(.opacity.animation(IslandMotion.leaf))
            }
        }
        .font(.manrope(12.5, weight: 580))
        .lineLimit(1)
        .fixedSize()
    }

    private static func labelColor(_ status: SessionStatus) -> Color {
        switch status {
        case .working: return IslandPalette.secondary
        case .idle: return IslandPalette.tertiary
        default: return status.tint
        }
    }
}

/// A notch wing's own entrance: a short slide and an unblur. Its position mostly comes from the
/// silhouette's edge it rides (`NotchWingInset`), so it can start at once.
struct NotchWingEffect: ViewModifier, Animatable {
    var p: Double
    let dx: CGFloat

    static let slide: CGFloat = 8
    static let insertion = MotionCurve.spring(0.26, 0.9).delayed(0.03)
    static let removal = MotionCurve.curve(.easeIn, 0.12)

    var animatableData: Double {
        get { p }
        set { p = newValue }
    }

    func body(content: Content) -> some View {
        let k = min(max(p, 0), 1)
        content
            .offset(x: dx * CGFloat(1 - p))
            .blur(radius: 3 * CGFloat(1 - k))
            .opacity(k)
    }
}

extension AnyTransition {
    /// A notch wing comes out from behind the camera housing and slides back into it.
    static func notchWing(edge: HorizontalEdge, reduce: Bool = false) -> AnyTransition {
        if reduce { return .opacity.animation(.easeInOut(duration: 0.16).speed(IslandMotion.speed)) }
        let dx: CGFloat = edge == .leading ? NotchWingEffect.slide : -NotchWingEffect.slide
        return .asymmetric(
            insertion: .modifier(active: NotchWingEffect(p: 0, dx: dx), identity: NotchWingEffect(p: 1, dx: dx))
                .animation(NotchWingEffect.insertion.animation),
            removal: .modifier(active: NotchWingEffect(p: 0, dx: dx), identity: NotchWingEffect(p: 1, dx: dx))
                .animation(NotchWingEffect.removal.animation))
    }
}

// MARK: - Layouts

/// Role of a view in `LiveActivityRow`.
enum RowRole: LayoutValueKey {
    enum Kind { case fixed, shrinks, slack }
    static let defaultValue = Kind.fixed
}

/// One row at its natural width clamped to `minWidth...maxWidth`. When it would be too wide, the
/// `.shrinks` view (the project name) gives up the difference and truncates; when narrower than the
/// minimum, the `.slack` view takes the rest, pushing everything after it to the trailing edge.
struct LiveActivityRow: Layout {
    var minWidth: CGFloat
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let total = sizes.reduce(0) { $0 + $1.width }
        let height = proposal.height ?? sizes.map(\.height).max() ?? 0
        return CGSize(width: min(max(total, minWidth), maxWidth).rounded(.up), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        var extra = bounds.width - widths.reduce(0, +)
        if extra < 0, let i = subviews.firstIndex(where: { $0[RowRole.self] == .shrinks }) {
            let give = min(-extra, widths[i])
            widths[i] -= give
            extra += give
        }
        if extra > 0, let i = subviews.firstIndex(where: { $0[RowRole.self] == .slack }) {
            widths[i] += extra
        }
        var x = bounds.minX
        for (i, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: widths[i], height: bounds.height))
            x += widths[i]
        }
    }
}

/// Two wings of equal width beside the camera housing (so the island stays centered on it): the first
/// subview hugs the left edge, the second the right edge.
struct NotchWingsLayout: Layout {
    var notchWidth: CGFloat
    var minWing: CGFloat
    var maxWing: CGFloat

    private func wing(_ subviews: Subviews) -> CGFloat {
        let widest = subviews.prefix(2).map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return min(max(widest, minWing), maxWing).rounded(.up)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = proposal.height ?? subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: notchWidth + 2 * wing(subviews), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = wing(subviews)
        if subviews.count > 0 {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: w, height: bounds.height))
        }
        if subviews.count > 1 {
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                              proposal: ProposedViewSize(width: w, height: bounds.height))
        }
    }
}
