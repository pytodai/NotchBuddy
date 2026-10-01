import NotchBuddyCore
import Observation
import SwiftUI

/// What the island is showing. Chosen by `IslandController`, rendered by `IslandView`.
enum IslandMode: Equatable {
    /// Nothing to show on a notch-less screen (or moving to another screen): the island retracts into
    /// the top edge and the panel is ordered out.
    case hidden
    /// No sessions on a notched screen: exactly the size of the notch, so it is invisible but still
    /// reacts to hover (to peek at usage).
    case idle
    /// "Live activity": the most important session, the others as "+N", Claude's 5-hour usage.
    case collapsed
    /// Session list with usage footer (hover, or pinned by a click).
    case expanded
    /// The first pending permission request.
    case permission
    /// A short completion / attention notice.
    case flash
    /// A registered page (`IslandPages`: settings, a widget), shown like the list.
    case page(String)

    var isOpen: Bool {
        switch self {
        case .expanded, .permission, .flash, .page: return true
        case .hidden, .idle, .collapsed: return false
        }
    }

    var content: IslandContentKind {
        switch self {
        case .hidden, .idle, .collapsed: return .closed
        case .expanded: return .expanded
        case .permission: return .permission
        case .flash: return .flash
        case .page(let id): return .page(id)
        }
    }
}

extension IslandMode {
    /// The tab an open mode shows (the list is «Агенты», a widget's page its widget); nil for everything else.
    var tab: WidgetKind? {
        switch self {
        case .expanded: return .agents
        case .page(let id): return WidgetKind(pageID: id)
        default: return nil
        }
    }

    /// The open mode that shows `tab`.
    static func tab(_ tab: WidgetKind) -> IslandMode { tab.pageID.map { .page($0) } ?? .expanded }
}

/// Which content view fills the island. The silhouette is sized to the measured size of this content.
enum IslandContentKind: Hashable {
    case closed, expanded, permission, flash
    case page(String)
}

/// The front permission card as the island shows it.
struct PermissionCardInfo: Identifiable, Equatable {
    let id: UUID
    let event: AgentEvent
    let receivedAt: Date
    let projectTitle: String
    /// What the card shows, built once off the main thread when the request arrived (`PendingPermission`).
    let detail: PermissionDetail

    init(id: UUID, event: AgentEvent, receivedAt: Date, projectTitle: String, detail: PermissionDetail? = nil) {
        self.id = id
        self.event = event
        self.receivedAt = receivedAt
        self.projectTitle = projectTitle
        self.detail = detail ?? PermissionDetail(event: event)
    }

    /// A request never changes under its id: comparing the (possibly megabyte-sized) payload and detail on every
    /// snapshot would only cost time.
    static func == (a: PermissionCardInfo, b: PermissionCardInfo) -> Bool {
        a.id == b.id && a.receivedAt == b.receivedAt && a.projectTitle == b.projectTitle
    }
}

/// Everything the island renders, copied from `AppModel` by the controller so that data and mode
/// changes reach the views inside the controller's own animation transactions.
struct IslandSnapshot: Equatable {
    var sessions: [AgentSession] = []
    /// `pendingPermissions.first`.
    var card: PermissionCardInfo?
    var cardCount = 0
    /// Ids of the queued cards in order (the queue dots are keyed by them).
    var cardIDs: [UUID] = []
    var flash: FlashNotice?
    /// «Готово» cards waiting behind the one on screen («ещё N»).
    var flashQueued = 0
    /// How long the agent worked before a "finished" notice (nil when unknown).
    var flashDuration: TimeInterval?
    /// A second "finished" notice right after another: no ping ring, a softer glow.
    var flashQuiet = false
    var usage: UsageState = .unavailable("…")
    /// The closed island shows the usage ring (Settings → Лимиты → «Кольцо на свёрнутом острове»).
    var showsUsageRing = true
    /// Every agent's usage (Claude, Codex, Kimi) and whose the island shows (`UsageSelection`).
    var agentUsages: [AgentUsage] = []
    var usageChoice = UsageProviderChoice.auto
    /// What the closed island shows below the overlays (`IslandActivityArbiter`); nil: the sessions' pill, if any.
    var activity: IslandActivityKind?

    /// The session the collapsed island is about: waiting > working > error > finished > idle
    /// (`SessionStore.ordered`), most recent first within a group.
    var primary: AgentSession? { sessions.first }

    func session(_ key: SessionKey) -> AgentSession? { sessions.first { $0.key == key } }

    /// Equal when the island would draw the same: sessions compare only what it shows
    /// (`AgentSession.looksTheSame`), in order, so a hook event that moves nothing but a session's last-event time
    /// or its terminal identity changes nothing on screen.
    static func == (a: IslandSnapshot, b: IslandSnapshot) -> Bool {
        a.card == b.card && a.cardCount == b.cardCount && a.cardIDs == b.cardIDs && a.flash == b.flash
            && a.flashQueued == b.flashQueued && a.flashDuration == b.flashDuration && a.flashQuiet == b.flashQuiet && a.usage == b.usage
            && a.showsUsageRing == b.showsUsageRing && a.agentUsages == b.agentUsages && a.usageChoice == b.usageChoice
            && a.activity == b.activity
            && a.sessions.count == b.sessions.count
            && zip(a.sessions, b.sessions).allSatisfy { $0.looksTheSame(as: $1) }
    }
}

extension IslandSnapshot {
    @MainActor
    init(model: AppModel) {
        sessions = model.sessions
        if let first = model.pendingPermissions.first {
            card = PermissionCardInfo(id: first.id, event: first.event, receivedAt: first.receivedAt,
                                      projectTitle: Self.projectTitle(for: first.event, sessions: model.store),
                                      detail: first.detail)
        }
        cardCount = model.pendingPermissions.count
        cardIDs = model.pendingPermissions.map(\.id)
        flash = model.flash
        flashQueued = model.flashQueue.count
        usage = model.usage
    }

    static func projectTitle(for event: AgentEvent, sessions store: SessionStore) -> String {
        if let session = store.sessions[event.sessionKey] { return session.title }
        if let cwd = event.cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
        return event.source.displayName
    }
}

/// Callbacks from the SwiftUI views to the controller.
struct IslandActions {
    /// Click on the closed island: open it (not pinned: it closes once the pointer leaves).
    var tappedClosedIsland: () -> Void = {}
    /// The pointer went down (true) or up without a click (false) on the closed island.
    var pressClosedIsland: (Bool) -> Void = { _ in }
    /// The press on the closed island moved, or came up after moving: «Островок» is dragged sideways. Returns whether the
    /// press is a drag (its mouse-up is then no click).
    var dragClosedIsland: (IslandDragEvent) -> Bool = { _ in false }
    /// The pin button in the header: the only way to keep the island open after the pointer leaves.
    var togglePin: () -> Void = {}
    var jump: (SessionKey) -> Void = { _ in }
    var remove: (SessionKey) -> Void = { _ in }
    /// The pointer entered (true) or left (false) a row.
    var hoverRow: (SessionKey, Bool) -> Void = { _, _ in }
    var tapFlash: (FlashNotice) -> Void = { _ in }
    /// A button of the «Готово» card: Перейти, Скопировать, Закрыть.
    var flashAction: (FlashNotice, FlashAction) -> Void = { _, _ in }
    /// A permission card button was clicked. The id is the card's, captured when it was rendered.
    var decide: (UUID, PermissionDecision) -> Void = { _, _ in }
    /// Shows a registered page (`IslandPages`: settings, a widget) in the open island; nil goes back to the list.
    var showPage: (String?) -> Void = { _ in }
    /// A tab of the open island (the tab strip, a swipe).
    var selectTab: (WidgetKind) -> Void = { _ in }
    /// A click on the usage: Авто → Claude → Codex → Kimi.
    var cycleUsage: () -> Void = {}
    /// The pointer rests on a tab of the strip: its page may be built ahead.
    var prepareTab: (WidgetKind) -> Void = { _ in }
}

/// A press on the closed island, as the stage view reports it.
enum IslandDragEvent: Equatable {
    /// The pointer is at `point` (screen coordinates) with the button down, `dy` points above or below where it went down.
    case moved(NSPoint, dy: CGFloat)
    /// The button came up.
    case ended
}

/// What the «Готово» card's buttons do.
enum FlashAction: Equatable {
    case jump, copy, close
}

/// A new front card ignores clicks and shortcuts for this long, so a double click, a repeated ⌘Y or
/// a click aimed at the previous card cannot answer a request the user has not seen.
enum PermissionArming {
    static let delay: Duration = .milliseconds(500)
    static let seconds: Double = 0.5
}

/// A content view's agent mark that the hero layer can fly to.
struct HeroSlotID: Hashable {
    var kind: IslandContentKind
    var key: SessionKey
}

/// The flying agent mark: which session, and where it sits (canvas coordinates).
struct HeroSubject: Identifiable, Equatable {
    var id: SessionKey
    var rect: CGRect
    /// It flew here from another slot (it is held inside the silhouette on the way, `HeroPlacement`); a
    /// mark that appeared in place is uncovered by the silhouette like the content around it.
    var flies = false
    var source: AgentSource { id.source }
}

/// How a list row leaves.
enum RowRemoval: Equatable {
    /// Removed with ×: slides out to the right.
    case swipe
    /// Expired or ended: folds away in place.
    case fold
}

/// UI-only state owned by `IslandController`.
///
/// Geometry pipeline ("measure, then move"): `setContent` swaps the content in one transaction (the
/// incoming view reveals on its own curve, `RevealParams`) and leaves the silhouette alone; the new view
/// reports its natural size (and the slot of the flying agent mark) during its first layout pass, and
/// `commitGeometry` then moves the silhouette and its shadow in exactly one transaction, in that same
/// pass (the mark flies alongside on its own, quicker spring). Later size changes (data, hover, press)
/// `retarget` at once with the spring that still owns the shape.
@Observable
@MainActor
final class IslandViewState {
    var mode: IslandMode = .hidden
    var metrics: IslandMetrics = .fallback
    var snapshot = IslandSnapshot()
    /// The front permission card once it accepts decisions (`PermissionArming.delay` after it appeared).
    var armedCardID: UUID?
    /// When the front card appeared, in monotonic seconds (`AppClock.monotonicSeconds`; its arming progress runs
    /// from here, and a wall clock set meanwhile does not stall it).
    var cardPresentedAt: TimeInterval?
    /// The panel holds the keyboard (the pointer is over the card): ⌘Y / ⌘N / ⌘T reach the card.
    var keyboardActive = false
    /// The pointer rests on the closed island: it "breathes" a little bigger before opening.
    var hovering = false
    /// The mouse is down on the closed island: it squishes a little.
    var pressed = false
    /// 📌: the island stays open after the pointer leaves, until unpinned.
    var pinned = false
    /// Bumped to bounce the pin icon.
    var pinBounce = 0

    /// Target of the silhouette (the animated model value).
    var geometry = IslandGeometry()
    var entrance: IslandEntrance = .pop
    /// Incoming open content takes clicks only `IslandMotion.interactiveDelay` after it appeared.
    var contentInteractive = true
    /// The closed content rides the silhouette while it is narrower (`ClosedContentFit`): set by a content
    /// swap's commit, cleared when data resizes the closed content (it then lays out with the spring).
    var closedFit = true
    /// Session whose agent mark the hero layer draws (content leaves a hole for it).
    var heroKey: SessionKey?
    /// The current content's hero mark flew in from the content before (`IslandMotion.heroTextLag`).
    var heroFlies = false
    var heroes: [HeroSubject] = []

    var pulseTick = 0
    var pulseKind: IslandPulse.Kind = .earFlare(4)
    var glow: IslandGlow?
    var glowTick = 0
    var errorShake = 0

    var hoveredRowKey: SessionKey?
    var rowRemoval: [SessionKey: RowRemoval] = [:]
    /// Rows that moved up; drawn above their neighbours while they pass them.
    var raisedRows: Set<SessionKey> = []
    /// The expanded session card; kept while the island stays open (list → settings → list), forgotten when it closes.
    var expandedSession: SessionKey?
    /// Bumped when the open island's widths change (Settings → Размер): the pages lay out again.
    var layoutRevision = 0
    /// Settings → Остров → «Ширина капсулы» (`IslandLayout.capsuleWidth`): read by the closed pages only, so a slider
    /// drag lays out nothing else; the closed island's new size morphs the shape like any data change.
    var capsuleWidth = IslandLayout.capsuleWidth
    /// The open island's tabs in order (Settings → Островки); a strip shows them when there is more than one.
    var tabs: [WidgetKind] = [.agents]
    /// The tab the strip marks: the one on screen, or the last one while settings are open.
    var activeTab: WidgetKind = .agents
    var tabsShown: Bool { tabs.count > 1 }
    /// The pointer is on the island (the shelf lets go of a lifted tile once it is not).
    var pointerOnIsland = false
    var reduceMotion = false

    /// The closed island's usage ring (closed content coordinates), when it shows one: a click there switches agent.
    @ObservationIgnored var closedRingRect: CGRect?
    /// «Островок» dragged sideways: where the user put it on this screen (`NotchSettings.islandOffsets`), its center's
    /// offset from the anchor in points. Clamped to the screen where it is used (`targetShift`).
    @ObservationIgnored var islandOffset: CGFloat = 0
    /// While the capsule is being dragged: where it is drawn (rubber band included); nil otherwise.
    @ObservationIgnored var dragShift: CGFloat?

    @ObservationIgnored let clock = IslandClock()
    @ObservationIgnored var actions = IslandActions()
    /// Draws the island (the Core Animation stage, `IslandStage`). Without one, the SwiftUI island (`IslandRootView`)
    /// follows this state's own animated values.
    @ObservationIgnored weak var renderer: IslandRenderer?
    /// The target geometry changed (the controller re-checks the pointer against it).
    @ObservationIgnored var onTargetChange: () -> Void = {}
    /// The island has retracted into the top edge (`.hidden` settled logically / completely).
    @ObservationIgnored var onRetracted: () -> Void = {}
    @ObservationIgnored var onHidden: () -> Void = {}
    /// What a hover on the closed island would open (built ahead while the pointer rests): the list, or a widget's tab.
    @ObservationIgnored var openTarget: () -> IslandMode = { .expanded }

    /// Natural size of each content view, reported by the views themselves. Never cleared: a view whose
    /// size did not change reports nothing, and its old measurement is still right.
    @ObservationIgnored private(set) var measured: [IslandContentKind: CGSize] = [:]
    @ObservationIgnored private var slots: [HeroSlotID: CGRect] = [:]
    /// The generation (content swap) in which each kind last reported its size.
    @ObservationIgnored private var measuredGeneration: [IslandContentKind: Int] = [:]
    @ObservationIgnored private var pending: (spring: GeoSpring, pulse: IslandPulse.Kind?)?
    /// The spring that owns the shape and until when (monotonic seconds).
    @ObservationIgnored private var owner: (spring: GeoSpring, until: TimeInterval)?
    @ObservationIgnored private(set) var generation = 0
    /// Geometry commits so far (the preview's live timing check counts them).
    @ObservationIgnored private(set) var commitCount = 0
    @ObservationIgnored private var commitScheduled = false
    @ObservationIgnored private var fallbackTask: Task<Void, Never>?
    @ObservationIgnored private var interactiveTask: Task<Void, Never>?
    @ObservationIgnored private var hiddenSafety: Task<Void, Never>?
    @ObservationIgnored private var errorGlowTask: Task<Void, Never>?
    /// Monotonic seconds of the last pulse.
    @ObservationIgnored private var lastPulseAt = -TimeInterval.infinity
    @ObservationIgnored private var lastPillWidth: CGFloat = 300

    // MARK: Phase 1: content

    /// Swaps the content (and data) in one transaction; the silhouette follows in `commitGeometry` once
    /// the new content has reported its size. Same-mode swaps (next card, next notice) come here too.
    func setContent(_ new: IslandMode, snapshot: IslandSnapshot, entrance: IslandEntrance? = nil,
                    exit: IslandExit? = nil, pulse: IslandPulse.Kind? = nil, glow newGlow: IslandGlow? = nil) {
        let old = mode
        IslandPerf.shared?.transition(IslandPerf.name(from: old, to: new))
        let spring = old == new ? (reduceMotion ? IslandMotion.reduced : IslandMotion.morph)
            : IslandMotion.geometry(from: old, to: new, reduce: reduceMotion)
        generation &+= 1
        let gen = generation
        self.entrance = entrance ?? IslandEntrance(from: old, to: new)
        let hero = Self.heroKey(for: new, snapshot, reduce: reduceMotion)
        // The mark flies in only from content that shows it too; otherwise it fades in place.
        heroFlies = hero != nil && heroes.contains { $0.id == hero }
        heroKey = hero
        if let newGlow {
            glow = newGlow
            glowTick &+= 1
        } else if !new.isOpen || new == .expanded {
            glow = nil
        }
        withAnimation(spring.animation) {
            mode = new
            self.snapshot = snapshot
            if new.isOpen || new == .hidden {
                hovering = false
                pressed = false
                hoveredRowKey = nil
            }
            contentInteractive = !new.isOpen
            // The strip's pill glides to the new tab on the same spring as the silhouette.
            if let tab = new.tab, tab != activeTab { activeTab = tab }
        }
        pending = (spring, reduceMotion ? nil : (pulse ?? spring.pulse))
        pruneSlots()
        interactiveTask?.cancel()
        if new.isOpen {
            interactiveTask = Task { [weak self] in
                try? await Task.sleep(for: IslandMotion.delay(IslandMotion.interactiveDelay))
                guard let self, !Task.isCancelled, gen == self.generation else { return }
                self.contentInteractive = true
            }
        }
        fallbackTask?.cancel()
        if let renderer {
            // The stage lays the new content out now and commits the geometry once (`commitPending`).
            renderer.showContent(from: old, to: new, exit: exit ?? IslandExit(leaving: old, to: new))
            renderer.glowChanged(retrigger: newGlow != nil)
            return
        }
        if new == .hidden || new == .idle {
            // The target does not depend on a measurement.
            commitGeometry()
            return
        }
        fallbackTask = Task { [weak self] in
            try? await Task.sleep(for: IslandMotion.delay(IslandMotion.commitFallback))
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.commitGeometry()
        }
    }

    /// Data changed inside the same mode: animated with the spring that owns the shape right now.
    /// A snapshot the island would draw the same (`IslandSnapshot.==` compares only what it shows: a tool call's
    /// new last-event time, a terminal's identity) is not assigned, so no view re-renders for it.
    func updateData(_ new: IslandSnapshot) {
        let hero = Self.heroKey(for: mode, new, reduce: reduceMotion)
        guard new != snapshot || hero != heroKey else { return }
        withAnimation(ownerSpring.animation) {
            snapshot = new
            if hero != heroKey { heroKey = hero }
        }
        renderer?.snapshotChanged()
        pruneSlots()
        let subjects = heroSubjects()
        guard subjects != heroes else { return }
        if let renderer {
            heroes = subjects
            renderer.geometryRetargeted(spring: ownerSpring)
        } else {
            withAnimation(IslandMotion.hero.animation) { heroes = subjects }
        }
    }

    /// Reduce Motion's stand-in for the closed island's error shake: a red glow fades in and out.
    func flashErrorGlow() {
        guard glow == nil || glow == .error else { return }
        glow = .error
        glowTick &+= 1
        renderer?.glowChanged(retrigger: true)
        errorGlowTask?.cancel()
        errorGlowTask = Task { [weak self] in
            try? await Task.sleep(for: IslandMotion.delay(0.45))
            guard let self, !Task.isCancelled, self.glow == .error else { return }
            self.glow = nil
            self.renderer?.glowChanged(retrigger: false)
        }
    }

    /// A glow re-peak without a content change (another card joined the queue).
    func repeakGlow(_ newGlow: IslandGlow) {
        glow = newGlow
        glowTick &+= 1
        renderer?.glowChanged(retrigger: true)
    }

    /// The whole closed island shakes once (its session failed).
    func shake() {
        errorShake &+= 1
        renderer?.shake()
    }

    // MARK: Measurement

    func contentMeasured(_ kind: IslandContentKind, _ size: CGSize) {
        let r = CGSize(width: size.width.rounded(), height: size.height.rounded())
        guard r.width > 0, r.height > 0 else { return }
        let changed = measured[kind] != r
        measured[kind] = r
        measuredGeneration[kind] = generation
        if kind == .closed, mode == .collapsed {
            // The silhouette's width at rest («Островок»: the capsule is its content, end to end).
            lastPillWidth = r.width + (metrics.detached ? 0 : 2 * IslandLayout.closedEar(metrics))
        }
        guard kind == mode.content, mode != .hidden else { return }
        // The stage is laying out new content: it commits once everything is measured.
        if renderer?.isLayingOut == true { return }
        if kind == .closed, changed, pending == nil, closedFit { closedFit = false }
        if pending != nil {
            // The new content's first layout pass: move now (not a frame later), unless the flying mark's
            // slot is still to be reported in this pass.
            if let heroKey, slots[HeroSlotID(kind: kind, key: heroKey)] == nil { scheduleCommit() } else { commitGeometry() }
        } else if changed {
            // A data change: follow the content in this very pass (no frame of clipped edges).
            retarget()
        }
    }

    func heroSlotMeasured(_ id: HeroSlotID, _ rect: CGRect) {
        guard slots[id] != rect else { return }
        slots[id] = rect
        guard id.key == heroKey, id.kind == mode.content else { return }
        if renderer?.isLayingOut == true { return }
        if pending == nil {
            // A slot moving with a SwiftUI animation reports every frame: the stage follows a few times a second.
            if let renderer { renderer.heroSlotMoved() } else { retarget() }
        } else if measuredGeneration[id.kind] == generation {
            commitGeometry()
        } else {
            scheduleCommit()   // the size report of this pass is on its way
        }
    }

    func contentSize(_ kind: IslandContentKind) -> CGSize {
        measured[kind] ?? IslandLayout.estimatedContentSize(kind, metrics: metrics, sessions: snapshot.sessions.count,
                                                            usageLoaded: snapshot.usage.isLoaded)
    }

    /// The commit waits for the rest of this layout pass (the size, or the hero slot, still to come).
    private func scheduleCommit() {
        guard !commitScheduled else { return }
        commitScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.commitScheduled = false
                if self.pending != nil { self.commitGeometry() } else { self.retarget() }
            }
        }
    }

    // MARK: Phase 2: geometry

    /// The renderer has laid out the new content: the silhouette moves now.
    func commitPending() {
        commitGeometry()
    }

    private func commitGeometry() {
        guard let (spring, pulse) = pending else { return }
        pending = nil
        fallbackTask?.cancel()
        commitCount &+= 1
        let gen = generation
        owner = (spring, AppClock.monotonicSeconds() + spring.settle)
        let fired = pulse.map { firePulse($0, render: false) } ?? false
        var transaction = Transaction(animation: spring.animation)
        if mode == .hidden {
            hiddenSafety?.cancel()
            hiddenSafety = Task { [weak self] in
                try? await Task.sleep(for: IslandMotion.delay(0.6))
                guard let self, !Task.isCancelled, gen == self.generation, self.mode == .hidden else { return }
                self.onRetracted()
                self.onHidden()
            }
        }
        if let renderer {
            geometry = target()
            heroes = heroSubjects()
            if !closedFit { closedFit = true }
            renderer.geometryCommitted(spring: spring, pulse: fired ? pulse : nil)
            onTargetChange()
            return
        }
        if mode == .hidden {
            transaction.addAnimationCompletion(criteria: .logicallyComplete) { [weak self] in
                guard let self, gen == self.generation, self.mode == .hidden else { return }
                self.onRetracted()
            }
            transaction.addAnimationCompletion(criteria: .removed) { [weak self] in
                guard let self, gen == self.generation, self.mode == .hidden else { return }
                self.hiddenSafety?.cancel()
                self.onHidden()
            }
        }
        let target = target()
        let subjects = heroSubjects()
        if !closedFit { closedFit = true }
        withTransaction(transaction) { geometry = target }
        IslandPerf.shared?.motionCommitted()
        // The mark flies on its own, quicker spring: it lands before the text next to it appears.
        if subjects != heroes { withAnimation(IslandMotion.hero.animation) { heroes = subjects } }
        onTargetChange()
    }

    /// Data, hover and press: the spring that currently owns the shape, else `explicit` or `data`.
    func retarget(with explicit: GeoSpring? = nil) {
        guard pending == nil else { return }   // the commit on its way reads the new target anyway
        let spring = explicit ?? ownerSpring
        let target = target()
        let subjects = heroSubjects()
        guard target != geometry || subjects != heroes else { return }
        if let renderer {
            geometry = target
            heroes = subjects
            renderer.geometryRetargeted(spring: spring)
            onTargetChange()
            return
        }
        if target != geometry { withAnimation(spring.animation) { geometry = target } }
        if subjects != heroes { withAnimation(IslandMotion.hero.animation) { heroes = subjects } }
        onTargetChange()
    }

    private var ownerSpring: GeoSpring {
        if reduceMotion { return IslandMotion.reduced }
        if let owner, owner.until > AppClock.monotonicSeconds() { return owner.spring }
        return IslandMotion.data
    }

    func target() -> IslandGeometry {
        // Reduce Motion: no breathing or squish (the shadow alone says "hover").
        var g = IslandLayout.geometry(mode: mode, metrics: metrics, content: contentSize(mode.content),
                                      hovering: hovering && !reduceMotion, pressed: pressed && !reduceMotion,
                                      lastPillWidth: lastPillWidth)
        if reduceMotion, hovering || pressed, mode == .collapsed || mode == .idle { g.shadow = 0.28 }
        return g
    }

    /// Where the island's center is heading, from the anchor: the dragged position while a drag runs, else the user's
    /// offset clamped so the target silhouette stays on screen (`IslandLayout.shift`; 0 for «Чёлка»). An open island
    /// therefore opens from wherever the capsule is and stays on screen near an edge.
    func targetShift() -> CGFloat {
        if let dragShift { return dragShift }
        return IslandLayout.shift(offset: islandOffset, width: shiftWidth, metrics: metrics)
    }

    /// The width the island's place is clamped with: the target silhouette's when open, the resting closed island's
    /// otherwise (so neither the hover grow nor the retract ever nudges it sideways).
    var shiftWidth: CGFloat {
        mode.isOpen ? geometry.width : closedRestWidth
    }

    /// The closed island at rest (not hovered): the capsule end to end on «Островок» («Ширина капсулы», or a widget's
    /// face), with its ears otherwise.
    var closedRestWidth: CGFloat {
        let content = contentSize(.closed).width
        return metrics.detached ? content : content + 2 * IslandLayout.closedEar(metrics)
    }

    /// `riding`: the grow rides the transition under way, on its spring (a capsule grabbed out of the open island lifts
    /// as it folds back, not on a quicker spring of its own).
    func setHovering(_ on: Bool, riding: Bool = false) {
        guard hovering != on else { return }
        if !riding { IslandPerf.shared?.transition(on ? "hover-in" : "hover-out", window: 0.3) }
        defer { IslandPerf.shared?.motionCommitted() }
        withAnimation(IslandMotion.hover.animation) { hovering = on }
        retarget(with: riding ? nil : reduceMotion ? IslandMotion.reduced : IslandMotion.hover)
        // The list is likely next: the stage builds it now, while the pointer rests.
        if on, mode == .collapsed || mode == .idle { renderer?.prepare(openTarget()) }
    }

    func setPressed(_ on: Bool) {
        guard pressed != on else { return }
        withAnimation(IslandMotion.press.animation) { pressed = on }
        renderer?.pressChanged()
        retarget(with: reduceMotion ? IslandMotion.reduced : IslandMotion.press)
    }

    /// Moves to another screen while retracted: new metrics and the new seed, without animation.
    func jump(to metrics: IslandMetrics) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.metrics = metrics
            geometry = target()
            heroes = []
        }
        pending = nil
        owner = nil
        renderer?.metricsChanged()
    }

    /// The same screen in the other style («Чёлка» ↔ «Островок», only `gap` differs): the content stays laid out, the
    /// silhouette morphs to its new place and shape on one spring.
    func morph(to metrics: IslandMetrics) {
        guard metrics != self.metrics else { return }
        self.metrics = metrics
        renderer?.gapChanged()
        retarget(with: reduceMotion ? IslandMotion.reduced : IslandMotion.morph)
    }

    // MARK: Pulses

    /// Returns whether it fired (pulses closer than 0.35 s apart are dropped, except the card's gulp).
    @discardableResult
    func firePulse(_ kind: IslandPulse.Kind, render: Bool = true) -> Bool {
        guard !reduceMotion else { return false }
        let now = AppClock.monotonicSeconds()
        if kind != .gulp, now - lastPulseAt < 0.35 { return false }
        lastPulseAt = now
        pulseKind = kind
        pulseTick &+= 1
        if render { renderer?.pulseFired(kind) }
        return true
    }

    // MARK: Hero

    static func heroKey(for mode: IslandMode, _ snapshot: IslandSnapshot, reduce: Bool) -> SessionKey? {
        guard IslandMotion.heroes, !reduce, let primary = snapshot.primary else { return nil }
        switch mode {
        // A widget's live activity has no agent mark to fly.
        case .collapsed: return (snapshot.activity ?? .agents) == .agents ? primary.key : nil
        case .expanded: return snapshot.sessions.count <= IslandLayout.maxVisibleRows ? primary.key : nil
        case .permission: return snapshot.card?.event.sessionKey == primary.key ? primary.key : nil
        case .hidden, .idle, .flash, .page: return nil
        }
    }

    private func heroSubjects() -> [HeroSubject] {
        guard let key = heroKey, let size = measured[mode.content],
              let slot = slots[HeroSlotID(kind: mode.content, key: key)] else { return [] }
        let canvas = IslandLayout.canvasSize(metrics)
        let dx = (canvas.width - size.width) / 2
        // Pages are laid out where the island's top is («Островок» floats `gap` below the canvas' edge).
        let rect = slot.offsetBy(dx: dx, dy: metrics.gap)
        let current = heroes.first { $0.id == key }
        return [HeroSubject(id: key, rect: rect, flies: current.map { $0.flies || $0.rect != rect } ?? false)]
    }

    /// Slot rects of content that is not on screen (filmstrips read them).
    func slot(_ id: HeroSlotID) -> CGRect? { slots[id] }

    /// Forgets the slots of sessions no longer shown (at most (sessions + card) × kinds entries stay).
    private func pruneSlots() {
        guard !slots.isEmpty else { return }
        var live = Set(snapshot.sessions.map(\.key))
        if let card = snapshot.card { live.insert(card.event.sessionKey) }
        guard slots.keys.contains(where: { !live.contains($0.key) }) else { return }
        slots = slots.filter { live.contains($0.key.key) }
    }
}

extension UsageState {
    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}
