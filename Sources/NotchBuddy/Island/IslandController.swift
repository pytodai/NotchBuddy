import AppKit
import Combine
import NotchBuddyCore
import SwiftUI

/// Owns the island panel: decides what it shows, where it sits and when it takes the mouse.
///
/// Smoothness: the panel is a fixed transparent canvas per screen (`IslandLayout.canvasSize`), placed
/// top-center once. Every change of the island's size is one SwiftUI spring of the silhouette inside
/// that canvas (see `IslandViewState`), so nothing waits for a window resize and nothing can drift away
/// from the top edge. Moving to another screen retracts the island into the top edge, moves the panel
/// while nothing is visible, and lets the island emerge on the new screen.
///
/// Click-through: the panel takes the mouse only while the pointer is on the island itself: its silhouette
/// (`IslandHitShape`: the body and the band where the ears meet the top edge, not the transparent columns
/// under the ears) plus `IslandMotion.enterSlop`. The hover state keeps a few points more on the way out
/// (`exitSlop`), but that band passes clicks, scrolls and drops through and a rest there opens nothing.
/// `IslandPointerTracker` follows the pointer with global and local event monitors (no permissions needed)
/// and this controller flips `ignoresMouseEvents` and drives hover from it: a breathing grow at once,
/// opening once the pointer rests on the island (`IslandMotion.restDwell`, at most `maxDwell`; a pointer
/// sweeping across the top does not open it), closing `closeDelay` after the pointer leaves, and reopening
/// at once when, within `reopenGrace` of the close, it comes back near where it left (`GraceZone`).
/// A click on the closed island only opens it: only 📌 keeps it open after the pointer leaves (`IslandOpenState`
/// holds the rules). While it is open and not pinned a 10 Hz poll (`leaveWatch`) re-checks the pointer, so a leave
/// that no event reported (a fast exit, another display, sleep, a Space switch, another app's window above the panel)
/// still closes it. A notice that appears under a resting pointer takes no click until the pointer moves or
/// `PermissionArming.seconds` pass.
/// Every interval here runs on the monotonic clock (`AppClock.monotonicSeconds`), never the wall clock.
///
/// Permission cards: the island shows `pendingPermissions.first`. Each new front card is "armed" only
/// `PermissionArming.delay` after it appears (again after a move to another screen); until then clicks
/// and shortcuts are ignored, so a double click, a held or repeated ⌘Y, or a click aimed at a card that
/// just went away cannot answer the next request unseen. Every decision names the card it was made on
/// (the id captured when the card was rendered) and is dropped unless that card is still the armed
/// front card; nothing ever answers "whatever is first now".
///
/// Keyboard: the island never takes keyboard focus on its own. ⌘Y / ⌘N / ⌘T work only while the
/// pointer is over the card, when the non-activating panel is key; leaving the card hands the keyboard
/// straight back to the frontmost app. See `IslandKeyFocus`.
///
/// Manual demo: run the app and pipe a hook payload into the bridge, e.g.
/// `echo '{"session_id":"demo","cwd":"/tmp/demo","hook_event_name":"UserPromptSubmit","prompt":"hi"}' |
///  ~/.notchbuddy/bin/notchbuddy-bridge --source claude` (the island appears), then `"hook_event_name":"Stop"`
/// (completion flash), or a `PermissionRequest` with `"tool_name":"Bash","tool_input":{"command":"ls"}`
/// (card; the bridge waits for the answer). `NOTCHBUDDY_SLOWMO=6` slows all island motion down.
@MainActor
final class IslandController {
    private let model: AppModel
    private let state = IslandViewState()
    private let locator = ScreenLocator()
    private let keyFocus = IslandKeyFocus()
    private let pointer = IslandPointerTracker()
    private var panel: IslandPanel?
    private var stage: IslandStage?
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Where the panel is now (frames and hit tests use only this).
    private var applied: IslandPlacement?
    /// The latest placement the locator reported (a move in progress lands here).
    private var latest: IslandPlacement?
    /// Retracting to move to another screen: the island shows nothing and takes no pointer.
    private var moving = false
    private var moveTask: Task<Void, Never>?

    /// The pointer is in the island's hover zone (entered on the island, left a few points beyond it):
    /// breathing, the close delay and the keyboard follow it.
    private var pointerInside = false
    /// The pointer is on the island itself (silhouette + `enterSlop`): only then does the panel take the
    /// mouse and a rest open the list.
    private var pointerOnIsland = false
    /// Why the island is open (hover, click, hotkey, a drop), pinned or not, and since when the pointer has been off it.
    private var openState = IslandOpenState() {
        didSet {
            if state.pinned != openState.pinned { state.pinned = openState.pinned }
            if openState.watchesLeave != oldValue.watchesLeave { updateLeaveWatch() }
        }
    }
    /// Polls the pointer while the island is open and not pinned (`openState.watchesLeave`).
    private var leaveWatch: Timer?
    /// Menus of NotchBuddy that are open (a context menu on the shelf, the menu bar menu): the island waits for them.
    /// A set, not a count: a "begin" without its "end" (or the reverse) cannot drift, and the run loop's mode says
    /// whether one still tracks (`menuOpen`).
    private var menusTracking: Set<ObjectIdentifier> = []
    /// The holds last logged while a due close waited for them (each new set is logged once).
    private var loggedHolds: [String] = []
    /// After an action (jump, decision, flash click) the list stays closed until the pointer leaves.
    private var hoverSuppressedUntilExit = false
    /// When the current dwell started (monotonic seconds).
    private var dwellStart: TimeInterval?
    private var dwellTask: Task<Void, Never>?
    private var restTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    /// Where the pointer left the hover-opened list.
    private var exitPoint: NSPoint?
    /// After a hover close: coming back near where the pointer left reopens the list at once.
    private var grace: GraceZone?
    private var inPointerCheck = false
    private var pointerRecheck = false
    /// When the list was last pinned, or opened by a click (monotonic seconds): the second click of a double click
    /// must not land on the pin.
    private var pinnedAt = -TimeInterval.infinity

    private var lastSeenFlashID: UUID?
    private var suppressedFlashID: UUID?
    private var lastCardCount = 0
    /// Monotonic seconds of the last "finished" notice.
    private var lastFinishedFlashAt = -TimeInterval.infinity
    private var flashDurations: [UUID: TimeInterval] = [:]
    private var quietFlashes: Set<UUID> = []
    /// The notice on screen, when it appeared (monotonic seconds) and where the pointer rested then.
    private var presentedFlashID: UUID?
    private var flashPresentedAt = -TimeInterval.infinity
    private var flashRestingPointer: NSPoint?
    /// When each session started its current turn (for "закончил за 4:12"): measured on the monotonic half,
    /// which setting the wall clock never moves.
    private var workingSince: [SessionKey: Moment] = [:]
    private var previousStatus: [SessionKey: SessionStatus] = [:]
    private var previousOrder: [SessionKey] = []
    private var raisedClearTask: Task<Void, Never>?

    private var updateScheduled = false
    /// A registered page asked for (`showPage`): shown instead of the list while the island is open.
    private var requestedPage: String?
    /// The permission card on screen (captured when the mode was resolved) and its arming timer.
    private var presentedCardID: UUID?
    private var armTask: Task<Void, Never>?
    /// The settings the island last applied (`applySettings`).
    private var settings = NotchSettings()
    /// Effects anchored to the island (celebration, attention, permission rim, hover sheen).
    private var effects: IslandEffectsDirector?
    /// The widgets ("островки"): their services, the closed island's live activities, the usage of every agent.
    private let widgets: WidgetHub
    /// The tab the open island shows, or showed last (it opens there again unless a live activity says otherwise).
    private var activeTab: WidgetKind = .agents
    /// Open because a file is dragged over the island (the shelf opens under it).
    private var dragOpen = false
    /// The benchmark's style (`perfSetStyle`); nil: Settings → Остров → Стиль.
    private var forcedStyle: IslandStyle?
    /// Horizontal trackpad swipes on the open island switch tabs.
    private var scrollMonitor: Any?
    private var swipe = TabSwipeTracker()
    /// The tab whose page was last built ahead, and when (monotonic seconds).
    private var preparedTab: WidgetKind?
    private var preparedAt = -TimeInterval.infinity

    init(model: AppModel, widgets: WidgetHub? = nil) {
        self.model = model
        self.widgets = widgets ?? .shared
    }

    func start() {
        guard panel == nil else { return }
        let panel = IslandPanel()
        let container: IslandContainerView
        if IslandStage.enabled {
            // Core Animation draws the island (the render server plays every transition).
            let stage = IslandStage(state: state)
            self.stage = stage
            container = IslandContainerView(host: stage.view)
        } else {
            let host = IslandHostingView(rootView: IslandRootView(state: state))
            host.sizingOptions = []
            container = IslandContainerView(host: host)
        }
        panel.contentView = container
        self.panel = panel
        IslandPerf.shared?.attach(to: container)

        container.onPointerEvent = { [weak self] event in self?.pointer.noteEvent(timestamp: event.timestamp) }
        pointer.onMove = { [weak self] fromEvent in self?.pointerMoved(fromEvent: fromEvent) }
        pointer.onClickElsewhere = { [weak self] in self?.clickedElsewhere() }
        state.onTargetChange = { [weak self] in
            self?.pointerMoved(fromEvent: false)
            self?.widgets.shelf?.detector.islandChanged()
        }
        // The page a hover is about to open is built while the pointer rests (the list, or the tab it would open on).
        state.openTarget = { [weak self] in self.map { IslandMode.tab($0.tabForOpening()) } ?? .expanded }
        state.onRetracted = { [weak self] in self?.retracted() }
        state.onHidden = { [weak self] in self?.orderOutIfHidden() }
        state.actions = IslandActions(
            tappedClosedIsland: { [weak self] in self?.openFromClick() },
            pressClosedIsland: { [weak self] down in self?.pressClosedIsland(down) },
            togglePin: { [weak self] in self?.togglePin() },
            jump: { [weak self] key in self?.jump(to: key) },
            remove: { [weak self] key in self?.remove(key) },
            hoverRow: { [weak self] key, inside in self?.hoverRow(key, inside) },
            tapFlash: { [weak self] notice in self?.tapFlash(notice) },
            flashAction: { [weak self] notice, action in self?.flashAction(notice, action) },
            decide: { [weak self] id, decision in self?.decide(id, decision) },
            showPage: { [weak self] id in self?.showPage(id) },
            selectTab: { [weak self] kind in self?.selectTab(kind) },
            cycleUsage: { [weak self] in self?.cycleUsage() },
            prepareTab: { [weak self] kind in self?.prepareTab(kind) }
        )

        keyFocus.pointerIsOverCard = { [weak self] in
            guard let self, let shape = self.islandHitShape(), let screen = self.applied?.screenFrame else { return false }
            return shape.contains(NSEvent.mouseLocation, within: screen)
        }
        keyFocus.onShortcut = { [weak self] shortcut in
            guard let self, let id = self.presentedCardID else { return }
            self.decide(id, shortcut.decision)
        }
        keyFocus.onKeyboardChange = { [weak self] active in
            guard let self, self.state.keyboardActive != active else { return }
            self.state.keyboardActive = active
        }
        keyFocus.install(on: panel)

        // Settings → Оформление → Анимации: the system's Reduce Motion unless the user chose otherwise.
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyReduceMotion() }
        }
        observers.append((center, token))
        // Settings → «Язык · Language»: SwiftUI pages re-render on their own (every `L(…)` is observed); the snapshot
        // and whatever it derives follow on the next update, the silhouette with the new content's size.
        let languageToken = NotificationCenter.default.addObserver(forName: L10n.didChange, object: nil,
                                                                   queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleUpdate() }
        }
        observers.append((NotificationCenter.default, languageToken))
        // «Авто» follows macOS: re-resolve when the system's languages or region change.
        let localeToken = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification,
                                                                 object: nil, queue: .main) { _ in
            L10n.shared.refresh()
        }
        observers.append((NotificationCenter.default, localeToken))
        observePointerInterruptions()

        IslandSettings.register()
        IslandWidgetPages.register()
        widgets.onChange = { [weak self] in self?.scheduleUpdate() }
        widgets.onTimerFinished = { [weak self] in self?.effects?.widgetFinished() }
        widgets.islandRect = { [weak self] in self?.islandScreenRect() }
        widgets.onShelfDrag = { [weak self] drag in self?.shelfDragChanged(drag) }
        // A tile dragged out of the shelf: its drag loop may keep the mouse events from the monitors, so each move of
        // the drag re-checks the pointer (click-through off the island, held open until the drag ends).
        widgets.onShelfDragOut = { [weak self] in self?.pointerMoved(fromEvent: false) }
        if !IslandPerf.enabled {
            installSwipe()
            // Recording a new hotkey in Settings needs the keyboard, only while the pointer is over the island.
            IslandSettings.model.recorder.onKeyboardRequest = { [weak self] on in self?.keyFocus.setRecording(on) }
            GlobalHotkey.shared.bind(to: .shared) { [weak self] in self?.toggleFromHotkey() }
            locator.preferredScreen = { SettingsScreens.screen(for: SettingsStore.shared.values.screen) }
        }
        // Settings → Остров → Стиль: one for screens with a camera notch, one for monitors (the benchmark's instance
        // picks its own, `perfSetStyle`).
        locator.style = { [weak self] screen in
            if let forced = self?.forcedStyle { return forced }
            return SettingsStore.shared.values.islandStyle(hasNotch: screen.safeAreaInsets.top > 0)
        }
        applySettings(SettingsStore.shared.values, initial: true)
        SettingsStore.shared.$values
            .dropFirst()
            .sink { [weak self] values in
                // `$values` fires before the store holds the new value: apply what it sends.
                self?.applySettings(values, initial: false)
            }
            .store(in: &cancellables)
        if let stage { effects = IslandEffectsDirector(state: state, stage: stage) }

        model.objectWillChange
            .sink { [weak self] _ in self?.scheduleUpdate() }
            .store(in: &cancellables)

        locator.onChange = { [weak self] placement in self?.placementChanged(placement) }
        locator.start()
        update()
        // The glow is rendered once: now, not in the first frame of the first card or notice.
        Task {
            _ = GlowImage.image
            _ = IslandSurfaceImage.shadow
        }
        // Likewise TextKit and the first text view (~40 ms): once launch has settled, not in the first card's
        // opening frames.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            PermissionCardView.warmUpCodeBlock()
            // The first list SwiftUI builds takes several times longer than the next ones: build one now, unseen.
            if let self, !self.state.mode.isOpen { self.stage?.prepare(.expanded) }
        }
    }

    // MARK: State

    /// `objectWillChange` fires before the model mutates; read it on the next turn.
    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        Task { [weak self] in
            self?.updateScheduled = false
            self?.update()
        }
    }

    private func update() {
        noteNewFlash()
        noteNewCards()
        var snapshot = IslandSnapshot(model: model)
        snapshot.showsUsageRing = settings.showsUsageRing
        snapshot.agentUsages = widgets.usage.usages
        snapshot.usageChoice = settings.usageProvider
        snapshot.activity = widgets.activity(sessions: snapshot.sessions)
        let tabsChanged = state.tabs != widgets.tabs
        if tabsChanged { state.tabs = widgets.tabs }
        if let flash = snapshot.flash {
            snapshot.flashDuration = flashDurations[flash.id]
            snapshot.flashQuiet = quietFlashes.contains(flash.id)
        }
        noteStatusChanges(snapshot)
        let mode = resolveMode(snapshot)
        // A page lives only as long as the open island it was asked for in; so does an expanded card.
        if !mode.isOpen {
            requestedPage = nil
            if state.expandedSession != nil { state.expandedSession = nil }
        }
        if mode != state.mode {
            if mode != .hidden { showPanel() }
            // The list shows the usage: a no-login pause of the usage fetcher shrinks back (throttled).
            if mode == .expanded {
                model.refreshUsageForDisplay()
                widgets.usage.islandOpened()
            }
            if let from = state.mode.tab, let to = mode.tab, from != to {
                // Another tab: the content slides toward the side the new tab lies on; the strip's pill glides.
                let forward = IslandTabs.isForward(from: from, to: to, in: state.tabs)
                state.setContent(mode, snapshot: snapshot, entrance: .slide(forward: forward), exit: .slide(forward: forward))
            } else {
                state.setContent(mode, snapshot: snapshot, glow: glow(for: mode, snapshot))
            }
        } else if tabsChanged, mode.isOpen, mode.tab != nil {
            // The strip comes or goes (Settings → Островки) while a tab is open: the pages are laid out again.
            state.setContent(mode, snapshot: snapshot)
        } else if mode == .permission, snapshot.card?.id != state.snapshot.card?.id {
            // The front card changed: the old one is sent up, the silhouette "gulps", the new one rises.
            state.setContent(.permission, snapshot: snapshot, entrance: .deck, pulse: .gulp, glow: .card)
        } else if mode == .flash, snapshot.flash?.id != state.snapshot.flash?.id {
            state.setContent(.flash, snapshot: snapshot, entrance: .deck, pulse: .latch, glow: glow(for: .flash, snapshot))
        } else {
            state.updateData(snapshot)
        }
        presentCard(mode == .permission ? snapshot.card?.id : nil)
        notePresentedFlash(mode == .flash ? snapshot.flash?.id : nil)
        // A notice under the pointer stays (the «Готово» card has text to read).
        model.holdFlash(pointerInside && mode == .flash)
        effects?.update(mode: state.mode, snapshot: state.snapshot)
        state.clock.setRunning((panel?.isVisible ?? false) && showsClock(mode, snapshot))
        breathe(pointerInside)
        updateLeaveWatch()
        pointerMoved(fromEvent: false)
    }

    /// Whether a view on screen reads the 1 Hz clock: the list (row clocks, usage resets), a card ("ждёт 0:20"),
    /// the floating pill of a working or waiting session. The notched pill, an idle notch and notices show none.
    private func showsClock(_ mode: IslandMode, _ snapshot: IslandSnapshot) -> Bool {
        switch mode {
        case .expanded, .permission, .page:
            return true
        case .collapsed:
            return state.metrics.style == .floating && (snapshot.activity ?? .agents) == .agents
                && snapshot.primary?.status.runsClock == true
        case .hidden, .idle, .flash:
            return false
        }
    }

    /// A notice that appears under a resting pointer takes no click until the pointer moves or
    /// `PermissionArming.seconds` pass (see `tapFlash`).
    private func notePresentedFlash(_ id: UUID?) {
        guard id != presentedFlashID else { return }
        presentedFlashID = id
        flashPresentedAt = AppClock.monotonicSeconds()
        flashRestingPointer = id == nil ? nil : NSEvent.mouseLocation
    }

    private func glow(for mode: IslandMode, _ snapshot: IslandSnapshot) -> IslandGlow? {
        switch mode {
        case .flash:
            guard let flash = snapshot.flash else { return nil }
            return flash.kind == .finished ? .finished(quiet: snapshot.flashQuiet) : .attention
        case .permission:
            return .card
        default:
            return nil
        }
    }

    /// Tracks the front card: a new one starts unarmed and arms after `PermissionArming.delay`.
    private func presentCard(_ id: UUID?) {
        if id != presentedCardID {
            presentedCardID = id
            armTask?.cancel()
            if state.armedCardID != nil { state.armedCardID = nil }
            state.cardPresentedAt = id == nil ? nil : AppClock.monotonicSeconds()
            if let id {
                armTask = Task { [weak self] in
                    try? await Task.sleep(for: PermissionArming.delay)
                    guard let self, !Task.isCancelled, self.presentedCardID == id else { return }
                    self.state.armedCardID = id
                }
            }
        }
        keyFocus.setCardVisible(id != nil)
    }

    private func resolveMode(_ snapshot: IslandSnapshot) -> IslandMode {
        if moving { return .hidden }
        // A file dragged over the island opens the shelf; a tile dragged out of it keeps the island open under it.
        let draggingOut = state.mode.isOpen && widgets.shelf?.store.draggingOut != nil
        let open = openState.isOpen || dragOpen || draggingOut
        // Settings → «Показывать запросы сразу» off: a request waits in the closed island (it pulses) until opened.
        if !model.pendingPermissions.isEmpty, settings.openOnPermission || open { return .permission }
        if let flash = model.flash, flash.id != suppressedFlashID { return .flash }
        if open { return requestedPage.map { .page($0) } ?? .tab(currentTab) }
        // A widget's live activity keeps the closed island out, sessions or not.
        if !model.sessions.isEmpty || !model.pendingPermissions.isEmpty || snapshot.activity != nil { return .collapsed }
        if state.metrics.style == .notch { return .idle }
        // Settings → «Показывать без сессий»: a small pill stays on a screen without a notch.
        return settings.showWithoutSessions ? .collapsed : .hidden
    }

    /// A notice arriving while the user already has the list open is not worth covering it (the row shows
    /// the same news), nor is "waits for you" while its card is already on the island. The sound still plays.
    private func noteNewFlash() {
        guard let flash = model.flash, flash.id != lastSeenFlashID else { return }
        lastSeenFlashID = flash.id
        playSound(flash.kind == .finished ? .finished : .attention)
        if flash.kind == .finished { effects?.sessionFinished(flash.id) }
        // Nor a tab the user is looking at (the strip's «Агенты» dot shows it).
        if state.mode.tab != nil { suppressedFlashID = flash.id }
        if flash.kind == .attention, state.mode == .permission || !model.pendingPermissions.isEmpty {
            suppressedFlashID = flash.id
        }
        if flash.kind == .finished {
            let now = AppClock.monotonicSeconds()
            defer { lastFinishedFlashAt = now }
            if flashDurations.count > 20 { flashDurations.removeAll() }
            if quietFlashes.count > 20 { quietFlashes.removeAll() }
            if now - lastFinishedFlashAt < 2 { quietFlashes.insert(flash.id) }
            if let start = workingSince[flash.key], let session = model.store.sessions[flash.key] {
                let duration = session.statusMoment.since(start)
                if duration >= 1, duration < 24 * 3600 { flashDurations[flash.id] = duration }
            }
        }
    }

    /// A new permission request (not the queue moving on) asks for attention.
    private func noteNewCards() {
        let count = model.pendingPermissions.count
        if count > lastCardCount {
            playSound(.permission)
            // Another card joined the queue behind the one on screen: the halo peaks again.
            if lastCardCount > 0, state.mode == .permission,
               model.pendingPermissions.first?.id == state.snapshot.card?.id {
                state.repeakGlow(.cardQueued)
            }
        }
        lastCardCount = count
    }

    /// Error shake, raised rows, turn start times.
    private func noteStatusChanges(_ snapshot: IslandSnapshot) {
        var statuses: [SessionKey: SessionStatus] = [:]
        for session in snapshot.sessions {
            statuses[session.key] = session.status
            switch session.status {
            case .working, .waitingForUser:
                if workingSince[session.key] == nil { workingSince[session.key] = session.statusMoment }
            case .finished, .error, .idle:
                workingSince[session.key] = nil
            }
        }
        for key in workingSince.keys where statuses[key] == nil { workingSince[key] = nil }

        if state.mode == .collapsed, let primary = snapshot.primary, primary.status == .error,
           let before = previousStatus[primary.key], before != .error {
            // Reduce Motion: a red glow fades in and out instead of the shake.
            if state.reduceMotion { state.flashErrorGlow() } else { state.shake() }
            effects?.error()
        }
        if snapshot.sessions.contains(where: { $0.status == .error && previousStatus[$0.key].map { $0 != .error } ?? false }) {
            playSound(.error)
        }

        // Rows that moved up pass above their neighbours.
        let order = snapshot.sessions.map(\.key)
        if state.mode == .expanded, order != previousOrder {
            let oldIndex = Dictionary(uniqueKeysWithValues: previousOrder.enumerated().map { ($1, $0) })
            let raised = Set(order.enumerated().compactMap { index, key in
                (oldIndex[key].map { index < $0 } ?? false) ? key : nil
            })
            if !raised.isEmpty {
                state.raisedRows = raised
                raisedClearTask?.cancel()
                raisedClearTask = Task { [weak self] in
                    try? await Task.sleep(for: IslandMotion.delay(0.5))
                    guard let self, !Task.isCancelled else { return }
                    self.state.raisedRows = []
                }
            }
        }
        previousOrder = order
        previousStatus = statuses
    }

    private func playSound(_ cue: IslandSounds.Cue) {
        // A beat after the island starts moving, so sound and motion land together.
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            IslandSounds.play(cue)
        }
    }

    /// A click or shortcut on card `id`. Ignored unless that card is on screen and armed.
    private func decide(_ id: UUID, _ decision: PermissionDecision) {
        guard state.mode == .permission, id == presentedCardID, id == state.armedCardID else { return }
        state.armedCardID = nil
        // The card closes under the pointer: do not turn it into the list (a pinned list stays).
        cancelDwell()
        if !openState.pinned { openState.close() }
        hoverSuppressedUntilExit = pointerInside
        // The terminal gets the keyboard, and keeps it while the next card of a queue rises under the pointer.
        if case .askInTerminal = decision { keyFocus.releaseUntilExit() }
        model.decide(id, decision)
    }

    // MARK: Pointer

    /// Re-evaluates the pointer against the island's target rect: flips click-through and drives hover.
    /// Called for pointer events (`fromEvent`), watchdog ticks and whenever the island's target changes.
    private func pointerMoved(fromEvent: Bool) {
        if inPointerCheck {
            pointerRecheck = true
            return
        }
        inPointerCheck = true
        checkPointer(fromEvent: fromEvent)
        while pointerRecheck {
            pointerRecheck = false
            checkPointer(fromEvent: false)
        }
        inPointerCheck = false
    }

    private func checkPointer(fromEvent: Bool) {
        guard let panel else { return }
        // The debug benchmark's instance sits over the installed island: it never takes the user's pointer.
        if IslandPerf.enabled {
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            return
        }
        let now = AppClock.monotonicSeconds()
        if let grace, grace.until <= now { self.grace = nil }
        guard panel.isVisible, let shape = islandHitShape(), let screen = applied?.screenFrame else {
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            pointerOnIsland = false
            setPointerInside(false)
            // Moving to another screen or hidden: a leave counts only once the island is back.
            openState.pointer(inside: false, held: true, now: now)
            return
        }
        let p = NSEvent.mouseLocation
        // On the island: its silhouette and a point more (the transparent columns under the ears are not).
        let onIsland = shape.contains(p, slopX: IslandMotion.enterSlop, slopY: IslandMotion.enterSlop, within: screen)
        // The hover state lets go a few points further out, so a pointer on the edge does not flicker. Beside a
        // real notch the zone stays tight: menu bar items sit right next to it.
        var inside = onIsland
        if pointerInside, !onIsland {
            let tight = state.metrics.style == .notch && !state.mode.isOpen
            inside = shape.contains(p, slopX: tight ? 2 : IslandMotion.exitSlop, slopY: IslandMotion.exitSlop,
                                    within: screen)
        }
        // Only the island itself takes the mouse: clicks, scrolls and drops in the band around it reach the apps
        // below. Nor is a drag caught that started elsewhere (its drop belongs to the app it came from), except a file
        // dragged onto the island for the shelf; a tile dragged out of the shelf is let through to the windows under
        // the panel once it leaves the island, and taken back over it (`IslandMouseCapture`).
        let buttonsDown = NSEvent.pressedMouseButtons != 0
        let capture = IslandMouseCapture.takesMouse(onIsland: onIsland, buttonsDown: buttonsDown,
                                                    ignoring: panel.ignoresMouseEvents,
                                                    fileDragWantsDrop: widgets.shelf?.wantsDrop == true,
                                                    shelfDragOut: widgets.shelf?.store.draggingOut != nil)
        if panel.ignoresMouseEvents == capture { panel.ignoresMouseEvents = !capture }
        pointerOnIsland = onIsland
        setPointerInside(inside)
        openState.pointer(inside: inside, held: leaveHeld, now: now)
        // A fast exit can skip the row's own hover-out (the panel may already ignore the mouse when
        // SwiftUI would have seen it): off the island itself, no row is hovered.
        if state.hoveredRowKey != nil, !shape.contains(p, within: screen) { state.hoveredRowKey = nil }
        // Back near where it left, right after a hover close, and not racing past: reopen at once, continuing
        // from mid-close. Anywhere else in the old list's area only a rest on the closed island opens it.
        if let grace, !state.mode.isOpen, !hoverSuppressedUntilExit, !buttonsDown,
           pointer.speed < Self.sweepSpeed, grace.isNearMiss(p, within: screen) {
            self.grace = nil
            exitPoint = nil
            openState.open(.hover, pointerInside: true, pin: settings.pinOnOpen, now: now)
            update()
            return
        }
        // An open island whose pointer is not on it (it came back somewhere else, or with another size, or a leave was
        // missed) closes as if the pointer had just left: the settings page and the widget tabs too.
        if !inside, openState.watchesLeave, openState.visited, state.mode.isOpen, closeTask == nil { scheduleClose() }
        guard inside else { return }
        if state.mode == .permission { keyFocus.pointerMoved() }
        if fromEvent, onIsland { considerHoverOpen() }
    }

    private func setPointerInside(_ inside: Bool) {
        guard inside != pointerInside else { return }
        pointerInside = inside
        if state.pointerOnIsland != inside { state.pointerOnIsland = inside }
        pointer.setWatching(inside)
        keyFocus.pointerChanged(inside: inside)
        model.holdFlash(inside && state.mode == .flash)
        if inside {
            cancelClose()
            breathe(true)
        } else {
            cancelDwell()
            breathe(false)
            if state.pressed { state.setPressed(false) }
            // Recording a hotkey needs the pointer on the island (the keyboard goes back to the app now).
            if !IslandPerf.enabled, IslandSettings.model.recorder.isRecording { IslandSettings.model.recorder.cancel() }
            hoverSuppressedUntilExit = false
            // A pointer that left and comes back to a notice means it.
            flashRestingPointer = nil
            if state.hoveredRowKey != nil { state.hoveredRowKey = nil }
            if openState.watchesLeave {
                exitPoint = NSEvent.mouseLocation
                scheduleClose()
            }
        }
    }

    /// The closed island grows a little under the pointer (not while something is dragged across).
    private func breathe(_ on: Bool) {
        let closed = state.mode == .collapsed || state.mode == .idle
        let want = on && closed && !hoverSuppressedUntilExit && (NSEvent.pressedMouseButtons == 0 || state.pressed)
        let was = state.hovering
        state.setHovering(want)
        // A soft sheen crosses the island as it grows under the pointer.
        if want, !was { effects?.hoverStarted() }
    }

    /// Opens the list once the pointer rests on the closed island (`restDwell` without a fast move),
    /// or `maxDwell` after it entered; a sweep (even a moderate one) restarts that; never while a button
    /// is down.
    private func considerHoverOpen() {
        guard canHoverOpen, let rest = IslandSettings.restDwell, let most = IslandSettings.maxDwell else { return }
        let speed = pointer.speed
        if dwellStart == nil || speed > Self.sweepSpeed {
            dwellStart = AppClock.monotonicSeconds()
            dwellTask?.cancel()
            dwellTask = after(most) { $0.hoverOpenNow() }
        }
        if speed >= 120 || restTask == nil {
            restTask?.cancel()
            restTask = after(rest) { $0.hoverOpenNow() }
        }
    }

    /// Only on the island itself: a rest in the band around it (where the hover state lingers) opens nothing.
    private var canHoverOpen: Bool {
        (state.mode == .collapsed || state.mode == .idle) && pointerInside && pointerOnIsland && !openState.isOpen
            && !hoverSuppressedUntilExit && NSEvent.pressedMouseButtons == 0
    }

    /// A pointer faster than this is passing by, not aiming at the island (points per second).
    private static let sweepSpeed: CGFloat = 350
    /// A pointer still moving faster than this when a dwell timer fires is not resting yet.
    private static let restingSpeed: CGFloat = 250

    private func hoverOpenNow() {
        guard canHoverOpen else {
            cancelDwell()
            return
        }
        if pointer.currentSpeed > Self.restingSpeed {
            // Still on the move (a sweep across the pill): wait for it to rest.
            restTask?.cancel()
            restTask = after(IslandSettings.restDwell ?? IslandMotion.restDwell) { $0.hoverOpenNow() }
            return
        }
        cancelDwell()
        activeTab = tabForOpening()
        // Settings → «Закреплять открытый список»: an opened list stays until unpinned.
        let now = AppClock.monotonicSeconds()
        openState.open(.hover, pointerInside: true, pin: settings.pinOnOpen, now: now)
        if openState.pinned { pinnedAt = now }
        update()
    }

    private func cancelDwell() {
        dwellTask?.cancel()
        restTask?.cancel()
        dwellTask = nil
        restTask = nil
        dwellStart = nil
    }

    private func scheduleClose() {
        closeTask?.cancel()
        closeTask = after(IslandMotion.closeDelay) { controller in
            controller.closeTask = nil
            controller.closeIfLeft()
        }
    }

    /// Closes the island once the pointer has been off it for `closeDelay` (reported by an event or seen by the poll),
    /// unless it is pinned or held (`IslandOpenState.shouldClose`).
    private func closeIfLeft() {
        let now = AppClock.monotonicSeconds()
        guard !pointerInside else { return }
        let holds = holdReasons
        let delay = IslandMotion.t(IslandMotion.closeDelay)
        guard openState.shouldClose(now: now, held: !holds.isEmpty, delay: delay) else {
            // Due but held: say by what, once per set of holds (a report of an island that stays open can be read).
            if !holds.isEmpty, holds != loggedHolds, openState.shouldClose(now: now, held: false, delay: delay) {
                loggedHolds = holds
                Log.info("island: close postponed, held by \(holds.joined(separator: ", ")) (mode \(state.mode))")
            }
            return
        }
        if !loggedHolds.isEmpty { loggedHolds = [] }
        if openState.unvisitedRemoteExpired(now: now) {
            Log.info("island: opened from afar, the pointer never came within \(Int(IslandOpenState.remoteVisitWindow)) s: closing")
        }
        let wasList = state.mode == .expanded
        openState.close()
        cancelClose()
        if wasList, let exit = exitPoint, let shape = islandHitShape() {
            grace = GraceZone(shape: shape, exit: exit, until: now + IslandMotion.reopenGrace)
        }
        exitPoint = nil
        update()
    }

    /// Something keeps the open island for now: a mouse button is down (a drag, a slider pulled past the edge), a menu is
    /// open, a permission card or a file drag is on it, or it is moving to another screen.
    private var leaveHeld: Bool { !holdReasons.isEmpty }

    /// What holds the open island right now (empty: nothing), named for the log.
    private var holdReasons: [String] {
        var holds: [String] = []
        if NSEvent.pressedMouseButtons != 0 { holds.append("mouse button") }
        if menuOpen { holds.append("menu") }
        if state.mode == .permission { holds.append("permission card") }
        if dragOpen { holds.append("file drag") }
        if moving { holds.append("screen move") }
        if state.mode.isOpen, widgets.shelf?.store.draggingOut != nil { holds.append("shelf tile dragged out") }
        return holds
    }

    /// The poll runs while the island is open, not pinned, on screen and not held by a card or a file drag.
    private func updateLeaveWatch() {
        let want = openState.watchesLeave && (panel?.isVisible ?? false) && !IslandPerf.enabled
            && state.mode != .permission && !dragOpen
        guard want != (leaveWatch != nil) else { return }
        leaveWatch?.invalidate()
        leaveWatch = nil
        guard want else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.leaveWatchTick() }
        }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        leaveWatch = timer
    }

    private func leaveWatchTick() {
        guard openState.watchesLeave else {
            updateLeaveWatch()
            return
        }
        // The same check an event makes (click-through, hover, the leave), then the close if it is due.
        pointerMoved(fromEvent: false)
        closeIfLeft()
    }

    /// A click in another app or on the desktop: an island opened from afar (the hotkey, the menu bar) that the pointer
    /// never visited closes (any other one closes on its own once the pointer is off it).
    private func clickedElsewhere() {
        guard openState.clickedElsewhere() else { return }
        cancelClose()
        update()
    }

    /// A menu of NotchBuddy is tracking (a missed "end" cannot hold the island: the run loop says whether one still is).
    private var menuOpen: Bool {
        guard !menusTracking.isEmpty else { return false }
        guard RunLoop.current.currentMode == .eventTracking else {
            // No menu tracks outside the event-tracking mode: whatever is left over lost its "end".
            Log.info("island: \(menusTracking.count) menu(s) without an end of tracking forgotten")
            menusTracking.removeAll()
            return false
        }
        return true
    }

    /// Leaves no event reports: the Mac woke, the screens woke, another Space; a menu opening or closing.
    private func observePointerInterruptions() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pointerMoved(fromEvent: false)
                    self?.closeIfLeft()
                }
            }
            observers.append((workspace, token))
        }
        let center = NotificationCenter.default
        for (name, begins) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let menu = note.object.map { ObjectIdentifier($0 as AnyObject) }
                MainActor.assumeIsolated {
                    guard let self, let menu else { return }
                    if begins {
                        self.menusTracking.insert(menu)
                    } else {
                        self.menusTracking.remove(menu)
                        // Closed: the leave counts from now.
                        self.pointerMoved(fromEvent: false)
                    }
                }
            }
            observers.append((center, token))
        }
        // Another app came to the front (⌘Tab, a click in its window): an island opened from afar that the pointer never
        // reached closes.
        let activation = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                               queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isSelf = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            MainActor.assumeIsolated {
                guard let self, !isSelf, self.openState.frontmostAppChanged() else { return }
                Log.info("island: another app came to the front before the pointer reached the island: closing")
                self.cancelClose()
                self.update()
            }
        }
        observers.append((workspace, activation))
    }

    private func cancelClose() {
        closeTask?.cancel()
        closeTask = nil
    }

    private func after(_ seconds: Double, _ body: @escaping @MainActor (IslandController) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: IslandMotion.delay(seconds))
            guard let self, !Task.isCancelled else { return }
            body(self)
        }
    }

    // MARK: Pages

    /// Shows a registered page (`IslandPages`) in the open island; nil goes back to the list. Unknown ids are ignored.
    /// It closes like the list once the pointer leaves (unless pinned with 📌); opened from afar (the menu bar's
    /// «Настройки…») it waits for the pointer to come and go.
    func showPage(_ id: String?) {
        if let id, let kind = WidgetKind(pageID: id) {
            selectTab(kind)
            return
        }
        if id == IslandSettings.pageID, activeTab != .agents, state.tabsShown, requestedPage == nil {
            // ⚙️ on a widget's tab: its settings are in «Островки».
            if IslandSettings.model.expanded != .widgets { IslandSettings.model.toggle(.widgets) }
        }
        let page = id.flatMap { IslandPages.spec($0) == nil ? nil : $0 }
        guard page != requestedPage else { return }
        requestedPage = page
        if page != nil, !openState.isOpen {
            cancelDwell()
            cancelClose()
            grace = nil
            hoverSuppressedUntilExit = false
            openState.open(pointerOnIsland ? .click : .remote, pointerInside: pointerInside, pin: settings.pinOnOpen,
                           now: AppClock.monotonicSeconds())
        }
        update()
    }

    // MARK: Settings

    /// Applies what the island reads from Settings; called at launch and on every change.
    private func applySettings(_ new: NotchSettings, initial: Bool) {
        let old = settings
        settings = new
        applyReduceMotion()
        if initial || new.widgets != old.widgets { widgets.apply(new.enabledWidgets) }
        let scale = CGFloat(new.size.scale)
        if IslandLayout.widthScale != scale {
            IslandLayout.widthScale = scale
            // The pages lay out at the new width; the silhouette follows their new size on the data spring.
            if !initial { state.layoutRevision &+= 1 }
        }
        let capsule = CGFloat(NotchSettings.clampedCapsuleWidth(new.capsuleWidth))
        if IslandLayout.capsuleWidth != capsule {
            IslandLayout.capsuleWidth = capsule
            // The closed «Островок» lays out at the new width (only the closed pages read it) and the silhouette follows
            // on the data spring; its face slides its two ends on the same spring, so they ride the shape's edges.
            if initial {
                state.capsuleWidth = capsule
            } else {
                withAnimation(state.reduceMotion ? IslandMotion.reduced.animation : IslandMotion.data.animation) {
                    state.capsuleWidth = capsule
                }
            }
        }
        guard !initial else { return }
        if new.screen != old.screen || new.islandStyleNotched != old.islandStyleNotched
            || new.islandStyleMonitors != old.islandStyleMonitors {
            // The locator reads the store, which holds the new value only after this publisher has fired.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { _ = self?.locator.evaluate() }
            }
        }
        if new.claudeUsageViaAPI != old.claudeUsageViaAPI { model.usageSourceChanged() }
        if new.kimiUsageViaAPI != old.kimiUsageViaAPI { widgets.usage.kimiToggleChanged() }
        if new.usageRefresh != old.usageRefresh { model.setUsageRefreshInterval(new.usageRefresh.seconds) }
        if new.showWithoutSessions != old.showWithoutSessions || new.openOnPermission != old.openOnPermission
            || new.widgets != old.widgets || new.usageProvider != old.usageProvider
            || new.showsUsageRing != old.showsUsageRing {
            scheduleUpdate()
        }
    }

    private func applyReduceMotion() {
        let reduce = settings.motion.reduceMotion(system: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if state.reduceMotion != reduce { state.reduceMotion = reduce }
    }

    /// Opens the island on its ⚙️ page (the menu bar's «Настройки…»).
    func showSettings() {
        if state.mode == .flash { model.dismissFlash(all: true) }
        // Opens the island right on the page (one transition, even from a closed or hidden island); it waits for the
        // pointer to come and go.
        showPage(IslandSettings.pageID)
    }

    /// The global hotkey (Settings → Горячая клавиша): opens the list (it closes again once the pointer has come and gone,
    /// on a click elsewhere, or on the hotkey), or closes whatever is open.
    func toggleFromHotkey() {
        if state.mode.isOpen, state.mode != .permission {
            if case .flash = state.mode { model.dismissFlash(all: true) }
            closeAfterAction()
        } else if !state.mode.isOpen {
            // Even with nothing to show on a screen without a notch: the list opens (usage, ⚙️).
            openFromClick(remote: true)
        }
    }

    /// A click on the usage (the header strip, the closed island's ring): the next agent with numbers.
    private func cycleUsage() {
        var usages = widgets.usage.usages
        if usages.isEmpty, model.usage.agentUsage.hasData { usages = [model.usage.agentUsage] }
        let store = SettingsStore.shared
        store.values.usageProvider = UsageSelection.next(after: store.values.usageProvider, usages: usages)
    }

    // MARK: Debug benchmark (`NOTCHBUDDY_PERF=1`)

    /// Opens or closes the list as a resting pointer would (no dwell).
    func perfSetOpen(_ open: Bool) {
        cancelDwell()
        cancelClose()
        grace = nil
        hoverSuppressedUntilExit = false
        if open {
            openState.open(.hover, pointerInside: true, now: AppClock.monotonicSeconds())
        } else {
            openState.close()
        }
        update()
    }

    /// The benchmark's style («Чёлка» / «Островок») on whatever screen it runs, without touching the user's settings.
    func perfSetStyle(_ style: IslandStyle) {
        forcedStyle = style
        _ = locator.evaluate()
    }

    /// The stage and the panel's window, for the benchmark's on-screen check.
    var perfStage: IslandStage? { stage }
    var perfWindowNumber: Int { panel?.windowNumber ?? 0 }
    var perfCanvasHeight: CGFloat { IslandLayout.canvasSize(state.metrics).height }

    /// The closed island's hover grow, on and off.
    func perfToggleHover() {
        perfHover(!state.hovering)
    }

    func perfHover(_ on: Bool) {
        guard state.mode == .collapsed || state.mode == .idle else { return }
        state.setHovering(on)
    }

    /// The benchmark's tabs (its instance reads no widget settings): shows the strip with these tabs.
    func perfSetTabs(_ tabs: [WidgetKind]) {
        widgets.apply(tabs)
        update()
    }

    func perfSelectTab(_ kind: WidgetKind) { selectTab(kind) }

    /// As a pointer resting on a tab of the strip does it: its page is built ahead.
    func perfPrepareTab(_ kind: WidgetKind) { prepareTab(kind) }

    // MARK: Tabs

    /// The tab shown while the island is open without a page (settings) over it.
    private var currentTab: WidgetKind { state.tabs.contains(activeTab) ? activeTab : .agents }

    /// Where the island opens: on the widget whose live activity the closed island shows, else on the last tab.
    private func tabForOpening() -> WidgetKind {
        if !state.mode.isOpen, state.mode == .collapsed, let widget = state.snapshot.activity?.widget,
           state.tabs.contains(widget) {
            return widget
        }
        return currentTab
    }

    /// A tab chosen by a click on the strip or a swipe (a closed island opens on it, pinned).
    private func selectTab(_ kind: WidgetKind) {
        guard state.tabs.contains(kind) else { return }
        guard state.mode.isOpen, state.mode != .permission else {
            if !state.mode.isOpen {
                activeTab = kind
                openFromClick(remote: !pointerOnIsland, tab: kind)
            }
            return
        }
        activeTab = kind
        requestedPage = nil
        cancelClose()
        update()
    }

    /// Builds a tab's page ahead (the pointer rests on it in the strip, or a swipe heads for it).
    private func prepareTab(_ kind: WidgetKind) {
        guard state.mode.isOpen, requestedPage == nil, state.mode.tab != nil, state.mode.tab != kind,
              state.tabs.contains(kind), preparedTab != kind || AppClock.monotonicSeconds() - preparedAt > 1.5 else { return }
        preparedTab = kind
        preparedAt = AppClock.monotonicSeconds()
        stage?.prepareTab(.tab(kind))
    }

    private func installSwipe() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleScroll(event) } ? nil : event
        }
    }

    /// A trackpad scroll over the open island: a clearly horizontal one switches to the neighbouring tab (fingers
    /// to the left: the next one, as pages turn in Safari), once per gesture; it is not passed on. Vertical scrolls
    /// reach the content. On the shelf (its row of files scrolls sideways) only a swipe on the header switches.
    private func handleScroll(_ event: NSEvent) -> Bool {
        guard event.window === panel, state.tabsShown, requestedPage == nil, let tab = state.mode.tab,
              event.hasPreciseScrollingDeltas else {
            swipe.reset()
            return false
        }
        // The momentum after a horizontal swipe belongs to it.
        if !event.momentumPhase.isEmpty { return swipe.axis == .horizontal && swipe.owns }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            swipe.begin(owns: tab != .shelf || pointerOnHeader())
        }
        let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        let step = swipe.add(dx: dx, dy: event.scrollingDeltaY)
        let consume = swipe.axis == .horizontal && swipe.owns
        // Heading sideways: the neighbour's page is built while the fingers travel on.
        if swipe.lean != 0, let next = IslandTabs.neighbour(of: tab, in: state.tabs, forward: swipe.lean > 0) {
            prepareTab(next)
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { swipe.end() }
        if step != 0, let next = IslandTabs.neighbour(of: tab, in: state.tabs, forward: step > 0) {
            selectTab(next)
        } else if step != 0 {
            // At the strip's end: the island nudges instead.
            state.firePulse(.earFlare(2))
        }
        return consume
    }

    /// The pointer is on the open island's header (the tab strip).
    private func pointerOnHeader() -> Bool {
        guard let rect = islandScreenRect() else { return false }
        let p = NSEvent.mouseLocation
        return p.y >= rect.maxY - IslandTabs.headerBlock(state.metrics) && p.x >= rect.minX && p.x <= rect.maxX
    }

    /// The island's rect on screen as it is heading (for the shelf's drag detector): the closed island's place at the
    /// top center while nothing shows, so a file dragged there still finds it.
    private func islandScreenRect() -> NSRect? {
        guard let placement = applied ?? latest, !moving else { return nil }
        var g = state.geometry
        if state.mode == .hidden || g.width < 1 {
            g.width = IslandLayout.collapsedMinWidth
            g.height = state.metrics.barHeight
            g.top = state.metrics.gap
        }
        return NSRect(x: placement.anchor.x - g.width / 2, y: placement.anchor.y - g.top - g.height,
                      width: g.width, height: g.height)
    }

    /// A file drag near the island: over it, the shelf opens under it; dropped (or gone), the island behaves like one
    /// the pointer opened.
    private func shelfDragChanged(_ drag: DragHoverDetector.State) {
        guard let shelf = widgets.shelf else {
            if dragOpen { dragOpen = false; scheduleUpdate() }
            return
        }
        if shelf.opensForDrag, !dragOpen {
            // The shelf takes the drop, even over the settings page (it would bounce back there); a card stays on top.
            if state.mode != .permission {
                activeTab = .shelf
                requestedPage = nil
            }
            dragOpen = true
            cancelDwell()
            cancelClose()
            scheduleUpdate()
        } else if dragOpen, !shelf.opensForDrag {
            dragOpen = false
            // Dropped on the island: it stays while the pointer is on it, like a hover-opened one.
            if pointerInside, !drag.isDragging {
                openState.open(.drop, pointerInside: true, now: AppClock.monotonicSeconds())
            }
            scheduleUpdate()
        }
        pointerMoved(fromEvent: false)
    }

    // MARK: Clicks

    private func pressClosedIsland(_ down: Bool) {
        guard !state.mode.isOpen, state.mode != .hidden else { return }
        state.setPressed(down)
    }

    /// A click on the closed island (or on a tab) opens it — not pinned: it closes once the pointer leaves. `remote`: the
    /// hotkey or the menu bar, the pointer is elsewhere (it may even open with nothing to show on a screen without a
    /// notch).
    private func openFromClick(remote: Bool = false, tab: WidgetKind? = nil) {
        guard !state.mode.isOpen, remote || state.mode != .hidden else { return }
        cancelDwell()
        cancelClose()
        grace = nil
        hoverSuppressedUntilExit = false
        // A click on a widget's live activity opens that widget's tab.
        activeTab = tab ?? tabForOpening()
        let now = AppClock.monotonicSeconds()
        openState.open(remote ? .remote : .click, pointerInside: pointerInside, pin: settings.pinOnOpen, now: now)
        // The second click of a double click must not land on the pin that opens under it.
        pinnedAt = now
        update()
        guard openState.pinned else { return }
        // Settings → «Закреплять открытый список»: the pin settles into place once the list has opened.
        Task { [weak self] in
            try? await Task.sleep(for: IslandMotion.delay(0.42))
            guard let self, self.state.pinned, self.state.mode.tab != nil else { return }
            self.state.pinBounce &+= 1
        }
    }

    /// 📌: the only way (besides «Закреплять открытый список») to keep the island open after the pointer leaves.
    private func togglePin() {
        // The second click of a double click on the closed island lands here.
        let now = AppClock.monotonicSeconds()
        guard now - pinnedAt > 0.4 else { return }
        if openState.pinned {
            // Off the island already (a click that slipped off the pin): it closes now; on it, once the pointer leaves.
            if openState.unpin(pointerInside: pointerInside, now: now) {
                cancelClose()
                update()
            }
        } else {
            if !openState.isOpen { openState.open(.click, pointerInside: pointerInside, now: now) }
            openState.pin()
            pinnedAt = now
            cancelClose()
            state.pinBounce &+= 1
            state.firePulse(.latch)
        }
    }

    /// Leaving row A can be reported after entering row B: only A's own exit clears A.
    private func hoverRow(_ key: SessionKey, _ inside: Bool) {
        if inside {
            if state.hoveredRowKey != key { state.hoveredRowKey = key }
        } else if state.hoveredRowKey == key {
            state.hoveredRowKey = nil
        }
    }

    private func jump(to key: SessionKey) {
        model.jump(to: key)
        closeAfterAction()
    }

    /// × on a row: one render with the swipe-out transition, then the removal.
    private func remove(_ key: SessionKey) {
        state.rowRemoval[key] = .swipe
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.model.removeSession(key) }
        }
        // Long after the row has gone (a session with the same key may come back later).
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.state.rowRemoval[key] = nil
        }
    }

    /// A click on the notice on screen. A notice that appeared under a resting pointer ignores clicks until the
    /// pointer moves or `PermissionArming.seconds` pass: the click was meant for what it now covers (a tab, the
    /// address bar), and must not jump to a terminal. A click aimed at the previous notice while the next one
    /// swaps in is dropped too.
    private func tapFlash(_ notice: FlashNotice) {
        guard state.mode == .flash, notice.id == presentedFlashID else { return }
        let settled = AppClock.monotonicSeconds() - flashPresentedAt >= PermissionArming.seconds
        let p = NSEvent.mouseLocation
        let moved = flashRestingPointer.map { abs(p.x - $0.x) > 1 || abs(p.y - $0.y) > 1 } ?? true
        guard settled || moved else { return }
        model.jump(to: notice.key)
        if model.flash?.id == notice.id { model.dismissFlash() }
        closeAfterAction()
    }

    /// A button of the «Готово» card (armed like a click on the notice: not under a pointer that has not moved).
    private func flashAction(_ notice: FlashNotice, _ action: FlashAction) {
        guard state.mode == .flash, notice.id == presentedFlashID else { return }
        let settled = AppClock.monotonicSeconds() - flashPresentedAt >= PermissionArming.seconds
        let p = NSEvent.mouseLocation
        let moved = flashRestingPointer.map { abs(p.x - $0.x) > 1 || abs(p.y - $0.y) > 1 } ?? true
        guard settled || moved else { return }
        switch action {
        case .jump:
            tapFlash(notice)
        case .copy:
            guard let reply = notice.reply else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(reply, forType: .string)
        case .close:
            model.dismissFlash()
            // The next queued card (if any) comes up under the pointer; with none, the island closes and stays closed
            // until the pointer leaves.
            if model.flash == nil { closeAfterAction() }
        }
    }

    private func closeAfterAction() {
        cancelDwell()
        cancelClose()
        grace = nil
        exitPoint = nil
        openState.close()
        hoverSuppressedUntilExit = pointerInside
        update()
    }

    // MARK: Panel geometry

    private func canvasFrame(_ placement: IslandPlacement) -> NSRect {
        let size = IslandLayout.canvasSize(placement.metrics)
        return NSRect(x: placement.anchor.x - size.width / 2, y: placement.anchor.y - size.height,
                      width: size.width, height: size.height)
    }

    /// The island's silhouette on screen, where it is heading (not where it is mid-spring).
    private func islandHitShape() -> IslandHitShape? {
        guard let applied, !moving, state.mode != .hidden else { return nil }
        let g = state.geometry
        let rect = NSRect(x: applied.anchor.x - g.width / 2, y: applied.anchor.y - g.top - g.height,
                          width: g.width, height: g.height)
        return IslandHitShape(rect: rect, geometry: g, screenTop: applied.anchor.y)
    }

    private func showPanel() {
        guard let panel else { return }
        if !panel.isVisible, let fresh = locator.evaluate(notify: false), fresh != applied {
            // The screen poll pauses while nothing shows: place the panel where the user works now.
            latest = fresh
            adopt(fresh)
        }
        guard let applied else { return }
        let frame = canvasFrame(applied)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        pointer.start()
        locator.setPolling(true)
        guard !panel.isVisible else { return }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// The island has fully retracted: nothing to show, so the panel leaves the screen.
    private func orderOutIfHidden() {
        guard let panel, state.mode == .hidden, !moving else { return }
        panel.orderOut(nil)
        panel.ignoresMouseEvents = true
        pointer.stop()
        locator.setPolling(false)
        pointerOnIsland = false
        setPointerInside(false)
        state.clock.setRunning(false)
        updateLeaveWatch()
    }

    // MARK: Screens

    private func placementChanged(_ next: IslandPlacement) {
        latest = next
        if !moving, let applied, applied.displayID == next.displayID, applied.anchor == next.anchor,
           applied.screenFrame == next.screenFrame, next.metrics.differsOnlyInGap(from: applied.metrics) {
            // The same screen in the other style («Чёлка» ↔ «Островок»): the shape morphs, the panel stays.
            self.applied = next
            state.morph(to: next.metrics)
            pointerMoved(fromEvent: false)
            return
        }
        guard let panel, panel.isVisible, let applied, applied != next else {
            // Not on screen (or the first placement): move silently.
            if !moving { applyNow(next) }
            return
        }
        guard !moving else { return }   // the move in progress lands on `latest`
        if state.reduceMotion {
            fadeMove(panel)
            return
        }
        // Retract into the top edge, move while nothing shows, emerge on the new screen.
        moving = true
        update()
        moveTask?.cancel()
        moveTask = after(0.32) { $0.retracted() }
    }

    private func retracted() {
        guard moving else { return }
        moveTask?.cancel()
        moveTask = nil
        guard let target = latest else {
            moving = false
            update()
            return
        }
        state.jump(to: target.metrics)
        applied = target
        if let panel { panel.setFrame(canvasFrame(target), display: false) }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.moving = false
                // A card that was on screen is presented anew there: it re-arms.
                self.presentedCardID = nil
                self.update()
                if self.state.mode == .hidden { self.orderOutIfHidden() }
            }
        }
    }

    /// Reduce Motion: fade out, jump, fade in.
    private func fadeMove(_ panel: IslandPanel) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let latest = self.latest, let panel = self.panel else { return }
                self.applyNow(latest)
                self.presentedCardID = nil
                self.update()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    panel.animator().alphaValue = 1
                }
            }
        })
    }

    private func applyNow(_ placement: IslandPlacement) {
        adopt(placement)
        if let panel, panel.isVisible {
            let frame = canvasFrame(placement)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
        }
        update()
    }

    /// The panel's placement changes while it is not on screen.
    private func adopt(_ placement: IslandPlacement) {
        applied = placement
        if state.metrics != placement.metrics { state.jump(to: placement.metrics) }
    }
}

/// The island's silhouette on screen, for hit tests: the body between the ears (full height, round bottom
/// corners) and the band along the top edge where the ears flare into it. The transparent columns under the
/// ears and outside the bottom corners are not the island: clicks there reach the apps below. A detached island
/// («Островок») has round top corners instead of ears, and the strip between it and the screen's top edge counts as
/// the island (a pointer thrown against the top edge lands on it, as on «Чёлка»).
struct IslandHitShape: Equatable {
    /// Screen coordinates (bottom-left origin).
    var body: NSRect
    /// The ears' band, or the strip above a detached island.
    var topBand: NSRect
    /// Radius of the body's bottom corners.
    var corner: CGFloat
    /// Radius of the body's top corners (a detached island).
    var crown: CGFloat = 0

    /// `screenTop`: the screen's top edge (a detached island's strip reaches up to it).
    init(rect: NSRect, geometry g: IslandGeometry, screenTop: CGFloat? = nil) {
        // As `IslandPathBuilder`: detached («Островок») corners are circular, so a closed capsule's ends are half circles
        // (its width can be anything from Settings → «Ширина капсулы»; the round ends never take clicks past the outline).
        let extent = IslandPathBuilder.extent + (1 - IslandPathBuilder.extent) * g.detachment
        let ear = min(max(g.ear, 0), rect.width / 4, rect.height / 2)
        body = NSRect(x: rect.minX + ear, y: rect.minY, width: max(rect.width - 2 * ear, 0), height: rect.height)
        // As `IslandPathBuilder` rounds them; a circle stays within ~1 pt of that smooth corner.
        let k = 0.27 + 0.23 * max(0, 1 - rect.height / 30)
        let shallow = min(IslandLayout.openBottom, rect.height * k)
        let bottom = max(g.bottom, shallow)
        let crownRadius = max(g.crown, shallow * g.detachment)
        let concave = max(0, ear - crownRadius)
        crown = max(0, min(crownRadius - ear, body.width / (2 * extent), rect.height / (2 * extent)))
        corner = max(0, min(bottom, body.width / (2 * extent), (rect.height - max(concave, crown * extent)) / extent))
        if g.top > 0.5, let screenTop, screenTop > rect.maxY {
            topBand = NSRect(x: body.minX + crown, y: rect.maxY, width: max(body.width - 2 * crown, 0),
                             height: screenTop - rect.maxY)
        } else {
            topBand = NSRect(x: rect.minX, y: rect.maxY - ear, width: rect.width, height: ear)
        }
    }

    /// Whether `p` is on the island grown by `slopX` / `slopY` (clipped to `screen`). Edges count as inside:
    /// a pointer pushed against the top of the screen sits exactly on it.
    func contains(_ p: NSPoint, slopX: CGFloat = 0, slopY: CGFloat = 0, within screen: NSRect) -> Bool {
        guard Self.contains(screen, p) else { return false }
        if topBand.height > 0 || slopY > 0, Self.contains(topBand.insetBy(dx: -slopX, dy: -slopY), p) { return true }
        guard Self.contains(body.insetBy(dx: -slopX, dy: -slopY), p) else { return false }
        let slop = max(slopX, slopY)
        // Outside the round bottom corners (grown by the slop too).
        if corner > 0, p.y < body.minY + corner, let cx = cornerCenterX(p.x, radius: corner) {
            return hypot(p.x - cx, p.y - (body.minY + corner)) <= corner + slop
        }
        // Outside the round top corners of a detached island.
        if crown > 0, p.y > body.maxY - crown, let cx = cornerCenterX(p.x, radius: crown) {
            return hypot(p.x - cx, p.y - (body.maxY - crown)) <= crown + slop
        }
        return true
    }

    /// The x of the corner circle's center when `x` lies beside a corner of `radius` (nil: between the corners).
    private func cornerCenterX(_ x: CGFloat, radius: CGFloat) -> CGFloat? {
        if x < body.minX + radius { return body.minX + radius }
        if x > body.maxX - radius { return body.maxX - radius }
        return nil
    }

    private static func contains(_ r: NSRect, _ p: NSPoint) -> Bool {
        r.width >= 0 && r.height >= 0 && p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY
    }
}

/// Right after a hover close (`IslandMotion.reopenGrace`), a pointer that comes back near where it left the
/// list, or along the old list's edges, and is not racing past reopens the list at once: it only just missed.
/// Anywhere else in the old list's area it is on its way to what the list covered (a tab, a link), so only
/// the usual rest on the closed island opens it. The zone never takes the mouse.
private struct GraceZone {
    var shape: IslandHitShape
    /// Where the pointer left the list.
    var exit: NSPoint
    /// Monotonic seconds.
    var until: TimeInterval

    static let exitRadius: CGFloat = 40
    static let edgeBand: CGFloat = 24

    func isNearMiss(_ p: NSPoint, within screen: NSRect) -> Bool {
        // Only where the reopened list will be under the pointer again.
        guard shape.contains(p, slopX: IslandMotion.enterSlop, slopY: IslandMotion.enterSlop, within: screen) else {
            return false
        }
        if hypot(p.x - exit.x, p.y - exit.y) <= Self.exitRadius { return true }
        let b = shape.body
        return p.x - b.minX <= Self.edgeBand || b.maxX - p.x <= Self.edgeBand || p.y - b.minY <= Self.edgeBand
    }
}

private extension IslandKeyFocus.Shortcut {
    var decision: PermissionDecision {
        switch self {
        case .allow: return .allow
        case .deny: return .deny(reason: nil)
        case .terminal: return .askInTerminal
        }
    }
}
