import AppKit
import NotchBuddyCore
import Observation
import SwiftUI

/// Identity of one content page on the stage (`IslandStage`). Every page is a SwiftUI view in its own
/// layer-backed hosting view, laid out once at its final size and moved only by Core Animation.
enum IslandPageID: Hashable {
    /// The closed island without a notch (one row).
    case closed
    /// Beside a notch the closed island is two wings, each drawn by its own copy of the closed content (cut at the
    /// canvas' center) so each can follow its edge of the silhouette.
    case closedLeft, closedRight
    /// The session list.
    case list
    /// One permission request.
    case card(UUID)
    /// The card's queue indicator (and, beside a notch, its strip): it stays while the requests swap.
    case cardChrome
    /// One notice.
    case flash(UUID)
    /// A registered page (`IslandPages`): settings, a widget.
    case custom(String)
    /// The open island's tab strip (and its buttons): it stays while the tabs under it swap.
    case tabs

    /// Which kind of content this page shows (the silhouette is sized to the measured content of that kind).
    var kind: IslandContentKind {
        switch self {
        case .closed, .closedLeft, .closedRight: return .closed
        case .list, .tabs: return .expanded
        case .card, .cardChrome: return .permission
        case .flash: return .flash
        case .custom(let id): return .page(id)
        }
    }

    /// Its measurements count for the silhouette (a notch wing's twin and the card chrome only draw).
    var measures: Bool {
        switch self {
        case .closedRight, .cardChrome, .tabs: return false
        default: return true
        }
    }

    /// Kept (hidden) when it leaves, rather than rebuilt next time.
    var persists: Bool {
        switch self {
        case .closed, .closedLeft, .closedRight, .cardChrome, .tabs: return true
        default: return false
        }
    }
}

// MARK: - Custom pages

/// A page the island can show besides its built-in ones: a settings page, a widget ("островок").
///
/// Register once at launch (`IslandPages.register`), then show it with `IslandController.showPage(id)` (or the
/// `IslandActions.showPage` callback from a button inside the island) and go back with `showPage(nil)`. The page is
/// an open mode (`IslandMode.page(id)`): the silhouette grows to the page's measured size with the open spring,
/// the page reveals like the list does, and its `.appearAfter(...)` sections cascade in.
struct IslandPageSpec {
    let id: String
    /// The page's content at its natural size (it is measured; keep it `width(metrics)` wide).
    let content: @MainActor (IslandPageContext) -> AnyView
    /// Width of the page on a screen (the list's by default, so pages swap without the island changing width).
    var width: @MainActor (IslandMetrics) -> CGFloat = { IslandLayout.listWidth($0) }

    init(id: String, width: @escaping @MainActor (IslandMetrics) -> CGFloat = { IslandLayout.listWidth($0) },
         content: @escaping @MainActor (IslandPageContext) -> AnyView) {
        self.id = id
        self.width = width
        self.content = content
    }
}

/// What a custom page gets to draw with: the island's live state (observed: reading it re-renders the page) and
/// the callbacks into the controller.
@MainActor
struct IslandPageContext {
    let state: IslandViewState
    var metrics: IslandMetrics { state.metrics }
    var snapshot: IslandSnapshot { state.snapshot }
    var actions: IslandActions { state.actions }
    var width: CGFloat
}

@MainActor
enum IslandPages {
    private static var specs: [String: IslandPageSpec] = [:]

    static func register(_ spec: IslandPageSpec) { specs[spec.id] = spec }
    static func spec(_ id: String) -> IslandPageSpec? { specs[id] }
}

// MARK: - Page

/// What a page's SwiftUI content reads besides `IslandViewState`: set by the stage while the page is the one on
/// screen, frozen once it leaves (a leaving page keeps showing what it showed).
@Observable
@MainActor
final class IslandPageModel {
    var entrance: IslandEntrance = .pop
    var heroKey: SessionKey?
    var heroFlies = false
    /// Off screen (a kept page hidden, or not shown yet): the icons' loops stop (`nbLoopsPaused`).
    var paused = false
    /// The page has been on screen (set by the stage as it reveals it). A page built ahead and not shown yet counts as
    /// fresh however long it waited (its rows still cascade in), so it can be kept and reused across hovers.
    @ObservationIgnored var revealed = false
    /// Film renders (`--render-promo`): seconds since the page was revealed, so time-driven pieces (usage bars, rolls)
    /// draw that moment instead of running SwiftUI animations the offscreen film never ticks. nil live.
    var filmTime: Double?
    /// The request a card page shows, the notice a notice page shows (they never change under a page).
    @ObservationIgnored var card: PermissionCardInfo?
    @ObservationIgnored var notice: FlashNotice?
}

/// One page of content on the stage: its views, its sections and where it is in its life.
///
/// Views, outermost first (all fill the canvas; the content hangs from its top center):
/// - `view`: the reveal / exit (opacity and `sublayerTransform`) and, for a notch wing, the cut at the canvas' center;
/// - `shift`: a notch wing following its edge of the silhouette (`sublayerTransform`);
/// - `cascade`: the section cascade (a mask whose parts fade in one after another);
/// - `host`: the SwiftUI content.
@MainActor
final class IslandPage {
    enum Phase { case building, live, leaving, hidden }

    let id: IslandPageID
    let view = IslandPageView()
    let shift = IslandFlippedView()
    let cascade = IslandFlippedView()
    let host: IslandPageHostingView
    let model = IslandPageModel()
    let sink = IslandSectionSink()
    var phase: Phase = .building
    /// Natural size of the content (reported by the content itself).
    var contentSize: CGSize = .zero
    /// When the current reveal started (media time).
    var revealStart: CFTimeInterval?
    /// The page's reveal / exit pose as a function of media time.
    var pose: (CFTimeInterval) -> IslandPose = { _ in .identity }
    /// Bumped on every reveal and exit (delayed tidying checks it).
    var generation = 0
    /// When it was made (media time).
    var builtAt: CFTimeInterval = 0
    var receiver: IslandPageReceiver?
    /// When each section's cascade started (sections still coming in).
    var sectionStarts: [UUID: CFTimeInterval] = [:]
    /// Bumped with every cascade mask (the mask's removal checks it).
    var cascadeGeneration = 0
    /// Bumped with every blur (the filter's removal checks it).
    var blurGeneration = 0
    /// While the island slides sideways in a content swap (an open near the screen's edge), the page holds its place on
    /// screen: this offset (points, a function of media time) cancels the slide on `shift`'s `sublayerTransform`, and
    /// `pinUntil` is when it is 0 again for good (`IslandStage.pinPages`). nil: the page rides with the island.
    var pin: ((CFTimeInterval) -> Double)?
    var pinUntil: CFTimeInterval = 0
    /// A leaving page's place on screen (from the anchor), which its pin holds.
    var pinScreen: Double?

    init(id: IslandPageID, state: IslandViewState, receiver: IslandContentReceiver) {
        self.id = id
        let root = IslandPageRoot(id: id, state: state, model: model, sink: sink, receiver: receiver)
        host = IslandPageHostingView(rootView: AnyView(root))
        host.sizingOptions = []
        // The blur in and out of the open island (`IslandStage.bakeBlur`) is a Core Image filter on this view's layer.
        view.layerUsesCoreImageFilters = true
        view.addSubview(shift)
        shift.addSubview(cascade)
        cascade.addSubview(host)
        host.page = self
        view.page = self
        sink.page = self
    }

    /// Top-left of the content in the page's (canvas) coordinates.
    func contentOrigin(canvasWidth: CGFloat) -> CGPoint {
        CGPoint(x: (canvasWidth - contentSize.width) / 2, y: 0)
    }

    /// `top`: where the island's top edge is on the canvas («Островок» floats below it): the page is laid out (and takes
    /// clicks) there. Its size never changes with it, so a switch of style lays out nothing.
    func layout(in bounds: CGRect, top: CGFloat = 0) {
        let outer = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height)
        if view.frame != outer { view.frame = outer }
        let inner = CGRect(origin: .zero, size: bounds.size)
        for v in [shift, cascade, host] as [NSView] where v.frame != inner { v.frame = inner }
    }
}

/// The page's content, with everything it reads from the island.
private struct IslandPageRoot: View {
    let id: IslandPageID
    let state: IslandViewState
    let model: IslandPageModel
    let sink: IslandSectionSink
    let receiver: IslandContentReceiver

    var body: some View {
        IslandPageContent(id: id, state: state, model: model)
            .islandContentRoot(id.kind, state: receiver)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .environment(\.islandEntrance, model.entrance)
            .environment(\.islandHeroKey, model.heroKey)
            .environment(\.islandHeroFlies, model.heroFlies)
            .environment(\.islandSectionSink, sink)
            .environment(\.islandPageModel, model)
            .environment(\.islandReduceMotion, state.reduceMotion)
            .environment(\.nbLoopsPaused, model.paused)
            .environment(\.islandFilmTime, model.filmTime)
            // Film renders: SwiftUI's own animations never tick offscreen; data changes land at once (the stage's
            // Core Animation motion is untouched).
            .transaction { [model] t in
                if model.filmTime != nil {
                    t.animation = nil
                    t.disablesAnimations = true
                }
            }
            .environment(state.clock)
            .environment(\.colorScheme, .dark)
    }
}

/// Which view each page shows (the same views, with the same inputs, as the SwiftUI island's `IslandContentLayer`).
private struct IslandPageContent: View {
    let id: IslandPageID
    let state: IslandViewState
    let model: IslandPageModel

    var body: some View {
        let metrics = state.metrics
        let snapshot = state.snapshot
        let actions = state.actions
        // Widths follow Settings → Размер (`IslandLayout.widthScale`): read so a change lays the page out again.
        let _ = state.layoutRevision
        switch id {
        case .closed, .closedLeft, .closedRight:
            // «Ширина капсулы»: an input of the view (not only the static), so a change lays the capsule out again.
            ClosedIslandContent(snapshot: snapshot, metrics: metrics, capsuleWidth: state.capsuleWidth)
                .allowsHitTesting(false)
        case .tabs:
            IslandTabsChrome(state: state, width: IslandLayout.listWidth(metrics))
        case .list:
            ExpandedIslandView(snapshot: snapshot, metrics: metrics, width: IslandLayout.listWidth(metrics),
                               tabbed: state.tabsShown,
                               pinned: state.pinned, pinBounce: state.pinBounce, hoveredRowKey: state.hoveredRowKey,
                               rowRemoval: state.rowRemoval, raisedRows: state.raisedRows,
                               expansion: Binding(get: { state.expandedSession }, set: { state.expandedSession = $0 }),
                               actions: actions)
        case .card(let cardID):
            if let card = model.card {
                let front = snapshot.card?.id == cardID
                PermissionCardView(
                    card: card,
                    total: front ? snapshot.cardCount : 1,
                    queue: front ? snapshot.cardIDs : [cardID],
                    metrics: metrics,
                    width: IslandLayout.cardWidth(metrics),
                    armed: state.armedCardID == cardID,
                    presentedAt: front ? state.cardPresentedAt : nil,
                    keyboardActive: front && state.keyboardActive,
                    // Bound to this card's id: the controller drops it unless this card is still in front.
                    decide: { decision in actions.decide(cardID, decision) }
                )
                .equatable()
            }
        case .cardChrome:
            PermissionQueueChrome(queue: snapshot.cardIDs, total: snapshot.cardCount, metrics: metrics,
                                  width: IslandLayout.cardWidth(metrics))
        case .flash(let noticeID):
            if let notice = model.notice {
                let current = snapshot.flash?.id == noticeID
                FlashView(notice: notice, session: snapshot.session(notice.key),
                          duration: current ? snapshot.flashDuration : nil, quiet: current && snapshot.flashQuiet,
                          metrics: metrics,
                          width: notice.isDoneCard ? IslandLayout.doneWidth(metrics) : IslandLayout.flashWidth(metrics),
                          queued: current ? snapshot.flashQueued : 0,
                          action: { actions.flashAction(notice, $0) }) {
                    actions.tapFlash(notice)
                }
            }
        case .custom(let pageID):
            if let spec = IslandPages.spec(pageID) {
                spec.content(IslandPageContext(state: state, width: spec.width(metrics)))
            }
        }
    }
}

// MARK: - Views

/// Top-left origin, layer-backed, never redrawn (it only holds layers).
class IslandFlippedView: NSView {
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Only subviews take hits (an empty stretch of the canvas passes them on).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// A view whose layer tree belongs to the stage (AppKit never touches its sublayers). Takes no hits.
final class IslandLayerHostView: NSView {
    let hostedLayer = CALayer()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        layer = hostedLayer
        wantsLayer = true
        hostedLayer.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A page's outermost view: takes hits only while its page is the one on screen, interactive, and the point is on its
/// content.
final class IslandPageView: IslandFlippedView {
    weak var page: IslandPage?
    /// Whether the page takes clicks right now (set by the stage).
    var accepts: () -> Bool = { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let page, page.phase == .live, accepts() else { return nil }
        let local = convert(point, from: superview)
        let origin = page.contentOrigin(canvasWidth: bounds.width)
        guard CGRect(origin: origin, size: page.contentSize).contains(local) else { return nil }
        return super.hitTest(point)
    }
}

/// The page's hosting view: takes the first click even though the panel is never key.
final class IslandPageHostingView: NSHostingView<AnyView> {
    weak var page: IslandPage?

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Sections

/// Collects a page's staggered sections (`.appearAfter(...)`): on the stage they do not animate in SwiftUI;
/// each reports where it is and when it should appear, and the stage reveals it with Core Animation.
@MainActor
final class IslandSectionSink {
    struct Section {
        /// In the content's coordinates.
        var rect: CGRect
        var delay: Double
        var style: AppearStyle
        var curve: MotionCurve
    }

    weak var page: IslandPage?
    private(set) var sections: [UUID: Section] = [:]
    /// Media time (the stage's clock).
    var clock: () -> CFTimeInterval = CACurrentMediaTime

    /// Whether a section appearing now comes in with its page (the page is being built, or its reveal just began):
    /// then the stage reveals it; a later one (a row arriving in the open list) animates in SwiftUI.
    var takesNewSections: Bool {
        guard let page else { return false }
        switch page.phase {
        case .building: return true
        case .live: return page.revealStart.map { clock() - $0 < IslandChoreography.media(0.05) } ?? false
        case .leaving, .hidden: return false
        }
    }

    func update(_ id: UUID, rect: CGRect, delay: Double, style: AppearStyle, curve: MotionCurve) {
        if var section = sections[id] {
            section.rect = rect
            section.delay = delay
            section.style = style
            section.curve = curve
            sections[id] = section
            return
        }
        sections[id] = Section(rect: rect, delay: delay, style: style, curve: curve)
    }

    func remove(_ id: UUID) { sections[id] = nil }
}

private struct IslandSectionSinkKey: EnvironmentKey { static let defaultValue: IslandSectionSink? = nil }
private struct IslandPageModelKey: EnvironmentKey { static let defaultValue: IslandPageModel? = nil }

extension EnvironmentValues {
    /// Set on the stage's pages: staggered sections report to it instead of animating in SwiftUI.
    /// The stage's model of the page a view is on (nil off the stage: previews, the SwiftUI island).
    var islandPageModel: IslandPageModel? {
        get { self[IslandPageModelKey.self] }
        set { self[IslandPageModelKey.self] = newValue }
    }

    var islandSectionSink: IslandSectionSink? {
        get { self[IslandSectionSinkKey.self] }
        set { self[IslandSectionSinkKey.self] = newValue }
    }
}

/// A section on the stage: drawn as is, reporting its rect, delay and style to the page's sink.
struct StagedSection: ViewModifier {
    let sink: IslandSectionSink
    let delay: Double
    let style: AppearStyle
    let curve: MotionCurve
    /// False: shown as is (`AppearAfter.enabled`); the modifier stays, so toggling it never remounts the content.
    var enabled = true
    @State private var id = UUID()
    @State private var rect: CGRect?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(IslandContentSpace.name))
            } action: { new in
                rect = new
                report(new)
            }
            .onChange(of: enabled) { report(rect) }
            .onDisappear { sink.remove(id) }
    }

    private func report(_ rect: CGRect?) {
        if enabled, let rect {
            sink.update(id, rect: rect, delay: delay, style: style, curve: curve)
        } else {
            sink.remove(id)
        }
    }
}
