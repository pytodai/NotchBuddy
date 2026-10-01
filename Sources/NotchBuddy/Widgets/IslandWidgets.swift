import AppKit
import Combine
import NotchBuddyCore
import Observation
import SwiftUI

// The island's widgets ("островки") in one place: the services behind them (started only while their widget is on),
// the pages of the open island's tabs, the closed island's live activities and how they rank
// (`IslandActivityArbiter`), and the badges on the tab strip. See the widgets section of docs/island-architecture.md.

// MARK: - Hub

/// Owns every widget's service for the app's lifetime and tells the island when what it shows may have changed.
///
/// A widget's service exists only while the widget is switched on (Settings → Островки): a widget that is off reads no
/// calendar, listens to no player and watches no drags. `apply(_:)` follows the settings; `onChange` fires (coalesced)
/// when anything the closed island's arbitration or the tab strip's badges read changes.
@MainActor
@Observable
final class WidgetHub {
    /// The app's hub (previews and films put their own in).
    static var shared = WidgetHub()

    private(set) var music: NowPlayingService?
    private(set) var calendar: CalendarService?
    private(set) var timer: TimerStore?
    private(set) var system: SystemMonitor?
    private(set) var shelf: ShelfWidget?
    /// The widgets switched on, in the tab strip's order («Агенты» always first unless moved).
    private(set) var tabs: [WidgetKind] = [.agents]
    /// Previews: the music widget's content without a player behind it.
    var musicPreview: MusicWidgetModel?

    /// Every agent's usage (Claude, Codex, Kimi) for the list's footer and the closed island's ring.
    @ObservationIgnored let usage = AgentUsageHub()
    /// Something the island reads changed (coalesced to one call per run-loop turn).
    @ObservationIgnored var onChange: () -> Void = {}
    /// A timer ran out: the island celebrates.
    @ObservationIgnored var onTimerFinished: () -> Void = {}
    /// The island's rect on screen (the shelf's drag detector aims at it).
    @ObservationIgnored var islandRect: () -> NSRect? = { nil }
    /// A file drag's state changed (the controller opens the shelf under it).
    @ObservationIgnored var onShelfDrag: (DragHoverDetector.State) -> Void = { _ in }
    @ObservationIgnored var onShelfDragEvent: (DragHoverMachine.Event) -> Void = { _ in }
    /// A tile's drag out of the shelf began, moved or ended (the controller re-checks the pointer).
    @ObservationIgnored var onShelfDragOut: () -> Void = {}

    /// False for previews and the benchmark: services are handed in, nothing starts.
    @ObservationIgnored private let live: Bool
    @ObservationIgnored private var changeScheduled = false
    @ObservationIgnored private var urgentTimer: Timer?
    @ObservationIgnored private var usageCancellable: AnyCancellable?

    init(live: Bool = true) {
        self.live = live
    }

    /// Previews and films: fixed services, nothing started.
    static func preview(tabs: [WidgetKind], music: MusicWidgetModel? = nil, calendar: CalendarService? = nil,
                        timer: TimerStore? = nil, system: SystemMonitor? = nil, shelf: ShelfWidget? = nil) -> WidgetHub {
        let hub = WidgetHub(live: false)
        hub.tabs = tabs
        hub.musicPreview = music
        hub.calendar = calendar
        hub.timer = timer
        hub.system = system
        hub.shelf = shelf
        return hub
    }

    // MARK: Lifecycle

    /// Starts the usage readers (Codex rollouts, Kimi when allowed) and follows the settings' widgets.
    func start() {
        guard live else { return }
        usage.start()
        usageCancellable = usage.$usages.dropFirst().sink { [weak self] _ in self?.changed() }
        apply(SettingsStore.shared.values.enabledWidgets)
    }

    func stop() {
        guard live else { return }
        usage.stop()
        apply([.agents])
    }

    /// Switches services on and off to match the widgets that are on (`enabled` in the strip's order).
    func apply(_ enabled: [WidgetKind]) {
        let tabs = enabled.contains(.agents) ? enabled : [.agents] + enabled
        if tabs != self.tabs { self.tabs = tabs }
        guard live else { return }
        let on = Set(tabs)
        if on.contains(.music), music == nil {
            let service = NowPlayingService()
            service.options = Self.loadMusicOptions()
            service.start()
            music = service
        } else if !on.contains(.music), let service = music {
            service.stop()
            music = nil
        }
        if on.contains(.calendar), calendar == nil {
            calendar = CalendarService()
        } else if !on.contains(.calendar), calendar != nil {
            calendar = nil
        }
        if on.contains(.timer), timer == nil {
            let store = TimerStore()
            store.onFinish = { [weak self] _ in self?.onTimerFinished() }
            store.start()
            timer = store
        } else if !on.contains(.timer), let store = timer {
            store.stop()
            timer = nil
        }
        if on.contains(.system), system == nil {
            let monitor = SystemMonitor()
            monitor.start()
            system = monitor
        } else if !on.contains(.system), let monitor = system {
            monitor.stop()
            system = nil
        }
        if on.contains(.shelf), shelf == nil {
            let widget = ShelfWidget()
            // Settings → Островки switches the shelf; its own switch follows.
            if !widget.settings.enabled { widget.settings.enabled = true }
            widget.onDrag = { [weak self] state in
                self?.onShelfDrag(state)
                self?.changed()
            }
            widget.onDragEvent = { [weak self] event in self?.onShelfDragEvent(event) }
            widget.store.onDragOut = { [weak self] in self?.onShelfDragOut() }
            widget.start(islandRect: { [weak self] in self?.islandRect() })
            shelf = widget
        } else if !on.contains(.shelf), let widget = shelf {
            widget.stop()
            shelf = nil
        }
        track()
        changed()
    }

    /// Music options (players, scripting, linger) as the settings page edits them.
    func setMusicOptions(_ options: NowPlayingService.Options) {
        music?.options = options
        if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: Self.musicOptionsKey) }
    }

    static let musicOptionsKey = "music.options"

    static func loadMusicOptions() -> NowPlayingService.Options {
        guard let data = UserDefaults.standard.data(forKey: musicOptionsKey),
              let options = try? JSONDecoder().decode(NowPlayingService.Options.self, from: data) else { return .init() }
        return options
    }

    // MARK: What the island reads

    /// The flags the closed island's arbitration ranks (`IslandActivityArbiter`), for these sessions.
    func signals(sessions: [AgentSession]) -> IslandActivitySignals {
        var s = IslandActivitySignals()
        s.agentWaiting = sessions.contains { $0.status == .waitingForUser }
        s.agentBusy = sessions.contains { $0.status == .working || $0.status == .error }
        s.agentPresent = !sessions.isEmpty
        if let timer, timer.hasLiveActivity {
            let now = AppClock.system.now()
            let primary = timer.engine.primary(at: now)
            s.timerRunning = primary?.isRunning == true
            let finishing = primary.map { $0.isRunning && $0.remaining(at: now) <= IslandActivityArbiter.timerUrgentLead } ?? false
            s.timerUrgent = timer.recentFinish != nil || finishing
        }
        if let calendar { s.calendarSoon = calendar.imminent != nil }
        if let music { s.musicPlaying = music.showsLiveActivity }
        if let musicPreview { s.musicPlaying = musicPreview.nowPlaying != nil }
        if let system { s.batteryLow = system.hasLiveActivity }
        if let shelf {
            s.shelfBadge = shelf.showsBadge
            s.shelfDrag = shelf.drag.isDragging && shelf.drag.proximity > 0.12 && !shelf.opensForDrag
        }
        return s
    }

    /// What the closed island shows for these sessions (nil: nothing, the island may hide).
    func activity(sessions: [AgentSession]) -> IslandActivityKind? {
        IslandActivityArbiter.choose(signals(sessions: sessions))
    }

    /// A small dot on a tab of the strip: something is going on there (the agents' most urgent status, music playing,
    /// a meeting soon, a timer counting, low battery, files on the shelf).
    func badge(_ kind: WidgetKind, sessions: [AgentSession]) -> Color? {
        switch kind {
        case .agents:
            if sessions.contains(where: { $0.status == .waitingForUser }) { return SessionStatus.waitingForUser.tint }
            if sessions.contains(where: { $0.status == .error }) { return SessionStatus.error.tint }
            if sessions.contains(where: { $0.status == .working }) { return SessionStatus.working.tint }
            return nil
        case .music:
            let playing = music?.current?.isPlaying ?? musicPreview?.nowPlaying?.isPlaying ?? false
            return playing ? Color.white.opacity(0.9) : nil
        case .calendar:
            return calendar?.imminent != nil ? SessionStatus.waitingForUser.tint : nil
        case .timer:
            guard let timer else { return nil }
            if timer.recentFinish != nil { return SessionStatus.finished.tint }
            return timer.engine.hasRunning ? Color.white.opacity(0.9) : nil
        case .system:
            return system?.hasLiveActivity == true ? SessionStatus.error.tint : nil
        case .shelf:
            guard let shelf, !shelf.store.isEmpty else { return nil }
            return Color.white.opacity(0.55)
        }
    }

    // MARK: Changes

    /// Re-arms observation of everything `signals` and `badge` read.
    private func track() {
        withObservationTracking {
            _ = signals(sessions: [])
            _ = music?.current?.isPlaying
            _ = timer?.engine
            _ = shelf?.store.items.count
            _ = shelf?.store.draggingOut
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.track()
                    self?.changed()
                }
            }
        }
        scheduleUrgentCheck()
    }

    /// A running timer enters its last seconds at a known moment: re-rank then.
    private func scheduleUrgentCheck() {
        urgentTimer?.invalidate()
        urgentTimer = nil
        guard let timer, let primary = timer.engine.primary(at: AppClock.system.now()), primary.isRunning else { return }
        let lead = primary.remaining(at: AppClock.system.now()) - IslandActivityArbiter.timerUrgentLead
        guard lead > 0 else { return }
        let t = Timer(timeInterval: lead + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        urgentTimer = t
    }

    private func changed() {
        guard !changeScheduled else { return }
        changeScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                self.changeScheduled = false
                self.onChange()
            }
        }
    }
}

// MARK: - Pages

/// The widgets' pages on the stage (`IslandPages`, ids `widget.<kind>`): each is the list's width, leaves the tab
/// strip's room free at its top and draws its widget below it.
@MainActor
enum IslandWidgetPages {
    static func register() {
        for kind in WidgetKind.allCases {
            guard let id = kind.pageID else { continue }
            IslandPages.register(IslandPageSpec(id: id) { context in
                AnyView(IslandWidgetPage(kind: kind, state: context.state, width: context.width))
            })
        }
    }
}

/// One widget's page: the strip's room, then the widget.
struct IslandWidgetPage: View {
    let kind: WidgetKind
    let state: IslandViewState
    let width: CGFloat

    var body: some View {
        let metrics = state.metrics
        let hub = WidgetHub.shared
        VStack(spacing: 0) {
            Color.clear.frame(height: IslandTabs.headerBlock(metrics))
            content(hub: hub, metrics: metrics)
        }
        .frame(width: width)
    }

    /// The widget's header already sits in the strip beside a notch; below it the page is laid out as one block.
    private var blockMetrics: IslandMetrics {
        var m = state.metrics
        m.style = .floating
        return m
    }

    @ViewBuilder
    private func content(hub: WidgetHub, metrics: IslandMetrics) -> some View {
        switch kind {
        case .agents:
            EmptyView()
        case .music:
            Group {
                if let preview = hub.musicPreview {
                    MusicWidgetView(model: preview, width: width - 2 * 14)
                } else if let music = hub.music {
                    MusicWidget(service: music, width: width - 2 * 14)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 14)
            .appearAfter(0.04, style: .section)
        case .calendar:
            if let calendar = hub.calendar {
                CalendarWidget(service: calendar, notchWidth: 0, headerHeight: 44)
            } else {
                WidgetUnavailable(kind: kind)
            }
        case .timer:
            if let timer = hub.timer {
                TimerWidgetView(store: timer, metrics: blockMetrics, width: width, openSettings: nil, showsHeader: false)
                    .padding(.top, 2)
            } else {
                WidgetUnavailable(kind: kind)
            }
        case .system:
            if let system = hub.system {
                SystemWidgetView(monitor: system, metrics: blockMetrics, width: width, openSettings: nil, showsHeader: false)
                    .padding(.top, 2)
            } else {
                WidgetUnavailable(kind: kind)
            }
        case .shelf:
            if let shelf = hub.shelf {
                ShelfWidgetView(store: shelf.store, width: width, topInset: 0, pointerInside: state.pointerOnIsland)
            } else {
                WidgetUnavailable(kind: kind)
            }
        }
    }
}

/// A widget whose service is not running (it was just switched off, or a preview without it).
private struct WidgetUnavailable: View {
    let kind: WidgetKind

    var body: some View {
        VStack(spacing: 6) {
            NBIconView(IslandTabs.icon(kind), size: 24, color: IslandPalette.tertiary)
            Text(L("%@ выключен", kind.title))
                .font(.manrope(12.5, weight: 650))
                .foregroundStyle(IslandPalette.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .appearAfter(0.04, style: .section)
    }
}

// MARK: - Closed island

/// The closed island: the live activity the arbitration chose (`IslandSnapshot.activity`), or the sessions' pill.
/// Beside a notch it is drawn twice (one copy per wing): every branch reads only the snapshot and the hub, so both
/// copies are the same.
struct ClosedIslandContent: View {
    let snapshot: IslandSnapshot
    let metrics: IslandMetrics
    /// «Островок»: Settings → «Ширина капсулы».
    var capsuleWidth = IslandLayout.capsuleWidth
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        let activity = snapshot.activity ?? .agents
        ZStack {
            face(activity)
                .id(activity)
                .transition(swap)
        }
        .frame(height: metrics.barHeight)
    }

    /// One face gives way to the next without overlap: out in 80 ms, in from 60 ms.
    private var swap: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeOut(duration: 0.14).speed(IslandMotion.speed)) }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.94)).animation(IslandMotion.leaf.delay(0.06)),
            removal: .opacity.combined(with: .scale(scale: 0.97)).animation(.easeOut(duration: 0.08).speed(IslandMotion.speed)))
    }

    @ViewBuilder
    private func face(_ activity: IslandActivityKind) -> some View {
        let hub = WidgetHub.shared
        switch activity {
        case .music:
            if let model = hub.musicPreview ?? hub.music?.model { margin(MusicLiveActivityView(model: model, metrics: metrics)) } else { agents }
        case .calendar:
            // The pill takes no clicks (a click opens the calendar's tab, where «Подключиться» is).
            if let calendar = hub.calendar { margin(CalendarLiveActivity(service: calendar, metrics: metrics, showsJoin: false)) } else { agents }
        case .timer:
            if let timer = hub.timer { margin(TimerLiveActivity(store: timer, metrics: metrics)) } else { agents }
        case .system:
            if let system = hub.system { margin(BatteryLiveActivity(monitor: system, metrics: metrics)) } else { agents }
        case .shelf:
            if let shelf = hub.shelf { margin(ShelfLiveActivityView(store: shelf.store, proximity: shelf.drag.proximity, metrics: metrics)) } else { agents }
        case .shelfDrag:
            if let shelf = hub.shelf {
                margin(ShelfDragActivityView(proximity: shelf.drag.proximity, over: shelf.drag.isOverIsland,
                                             count: shelf.drag.itemCount, metrics: metrics))
            } else { agents }
        case .agents:
            agents
        }
    }

    private var agents: some View { CollapsedIslandView(snapshot: snapshot, metrics: metrics, capsuleWidth: capsuleWidth) }

    /// «Островок»: the agents' capsule spans the shape end to end (`IslandLayout.capsuleWidth`); a widget's face keeps
    /// the margin the ears give it elsewhere.
    private func margin(_ face: some View) -> some View {
        face.padding(.horizontal, metrics.detached ? IslandLayout.closedEar(metrics) : 0)
    }
}

/// The shelf's live activity: the fan of the newest files with their count, «Полка» and the newest file's name.
/// Beside a notch: the fan on the left wing, the tray on the right.
struct ShelfLiveActivityView: View {
    let store: ShelfStore
    var proximity: Double = 0
    let metrics: IslandMetrics

    var body: some View {
        switch metrics.style {
        case .floating:
            HStack(spacing: 9) {
                ShelfBadge(store: store, proximity: proximity, height: 20)
                Text(L("Полка"))
                    .font(.manrope(13, weight: 680))
                    .foregroundStyle(IslandPalette.primary)
                    .lineLimit(1)
                    .fixedSize()
                if let newest = store.items.first {
                    Text(newest.name)
                        .font(.manrope(12, weight: 560))
                        .foregroundStyle(IslandPalette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 150, alignment: .leading)
                        .id(newest.id)
                        .transition(.opacity.combined(with: .offset(y: 5)))
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 14)
            .frame(minWidth: IslandLayout.collapsedMinWidth, maxWidth: 320)
            .offset(y: -1.5)
            .animation(IslandMotion.leaf, value: store.items.first?.id)
        case .notch:
            NotchWingsLayout(notchWidth: metrics.notchWidth, minWing: 44, maxWing: 64) {
                HStack {
                    ShelfBadge(store: store, proximity: proximity, height: 18)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10)
                .modifier(NotchWingInset(sign: 1))
                HStack {
                    Spacer(minLength: 0)
                    NBIconView(.tray, size: 15, color: IslandPalette.secondary)
                }
                .padding(.trailing, 12)
                .modifier(NotchWingInset(sign: -1))
            }
        }
    }
}

/// A file dragged toward the island: «Брось на полку», then «Отпускай!» once it is over it.
struct ShelfDragActivityView: View {
    let proximity: Double
    let over: Bool
    let count: Int
    let metrics: IslandMetrics

    var body: some View {
        switch metrics.style {
        case .floating:
            ShelfDropHint(proximity: proximity, over: over, count: count, height: 22)
                .padding(.horizontal, 16)
                .frame(minWidth: IslandLayout.collapsedMinWidth)
                .offset(y: -1.5)
        case .notch:
            NotchWingsLayout(notchWidth: metrics.notchWidth, minWing: 44, maxWing: 64) {
                HStack {
                    NBIconView(.tray, size: 16, color: .white, value: nil, active: over)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 12)
                .modifier(NotchWingInset(sign: 1))
                HStack {
                    Spacer(minLength: 0)
                    Text(over ? L("Бросай") : L("Сюда"))
                        .font(.manrope(11.5, weight: 700))
                        .foregroundStyle(IslandPalette.primary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.trailing, 12)
                .modifier(NotchWingInset(sign: -1))
            }
        }
    }
}

// MARK: - Settings

/// «Музыка» in Settings → Островки: which players, and whether NotchBuddy may control them.
struct MusicSettingsSection: View {
    let hub: WidgetHub
    @State private var options = WidgetHub.loadMusicOptions()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                NBIconView(.music, size: 16, color: IslandPalette.secondary)
                Text(L("Музыка"))
                    .font(.manrope(13, weight: 680))
                    .foregroundStyle(IslandPalette.primary)
            }
            VStack(spacing: 10) {
                ForEach(MusicPlayer.allCases, id: \.self) { player in
                    SettingsToggleRow(title: player.displayName, hint: nil, isOn: binding(player))
                }
                SettingsDivider()
                SettingsToggleRow(title: L("Обложка, перемотка и кнопки"),
                                  hint: L("Через Apple Events: macOS спросит разрешение при первом нажатии"),
                                  isOn: Binding(get: { options.allowsScripting },
                                                set: { options.allowsScripting = $0; save() }))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.06)))
        }
    }

    private func binding(_ player: MusicPlayer) -> Binding<Bool> {
        Binding(get: { options.players.contains(player) },
                set: { on in
                    if on { options.players.insert(player) } else { options.players.remove(player) }
                    save()
                })
    }

    private func save() { hub.setMusicOptions(options) }
}
