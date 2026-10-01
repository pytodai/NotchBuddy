import AppKit
import Combine
import NotchBuddyCore

/// A permission request waiting for the user's decision on the island.
struct PendingPermission: Identifiable {
    var id: UUID { event.id }
    let event: AgentEvent
    /// When the request happened on the app's clocks (ordering against later events).
    var eventMoment: Moment
    /// When the app received it: the timeout runs on the monotonic half, the card's "ждёт 0:20" on the wall half.
    var received: Moment
    let reply: ReplyHandle
    /// What the card shows (built before the request reached the main thread).
    let detail: PermissionDetail

    var receivedAt: Date { received.wall }
}

struct UsageWindow: Equatable {
    /// 0...100
    var utilization: Double
    var resetsAt: Date?
}

struct UsageSnapshot: Equatable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var fetchedAt: Date
}

enum UsageState: Equatable {
    case unavailable(String)   // reason shown in the UI ("нет входа в Claude", "ошибка сети")
    case loaded(UsageSnapshot)
}

/// Short-lived notice shown by the island (completion / attention). A completion with the agent's last answer is the
/// «Готово» card (`reply`; Settings → «Показывать ответ агента при завершении»).
struct FlashNotice: Identifiable, Equatable {
    enum Kind: Equatable { case finished, attention }
    let id = UUID()
    let key: SessionKey
    let kind: Kind
    let title: String
    let detail: String?
    /// The agent's final answer (Claude / Codex `last_assistant_message`), as kept by the session; nil: a plain notice.
    var reply: String?
    /// When it was made (monotonic seconds): a queued card older than `AppModel.doneQueueLifetime` is dropped.
    var madeAt: TimeInterval = AppClock.monotonicSeconds()

    var isDoneCard: Bool { kind == .finished && reply != nil }
}

protocol TerminalJumping {
    /// Brings the session's terminal tab / host app to front. Returns false if nothing could be activated.
    @MainActor @discardableResult func jump(to session: AgentSession) -> Bool
}

protocol UsageProviding: Sendable {
    /// Called every 60 s. Must be cheap: prefer the statusLine cache, throttle network calls internally.
    func fetch() async -> UsageState
    /// Claude is in use, or someone is about to look at the usage (the menu, the list): a long pause taken
    /// because there was no usable Claude login shrinks back to the normal interval.
    func nudge() async
}

/// Central main-actor state. Services feed it; SwiftUI views observe it.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var store = SessionStore()
    /// FIFO; the island shows `pendingPermissions.first`.
    @Published private(set) var pendingPermissions: [PendingPermission] = []
    @Published private(set) var usage: UsageState = .unavailable("…")
    @Published private(set) var flash: FlashNotice?
    /// «Готово» cards waiting behind the one on screen, newest first (the card says «ещё N»).
    @Published private(set) var flashQueue: [FlashNotice] = []

    var sessions: [AgentSession] { store.ordered }

    let jumper: TerminalJumping
    let usageProvider: UsageProviding
    /// Reads the chat titles hook events don't carry (Claude transcripts, the Codex session index).
    let titleResolver: SessionTitleResolver
    /// How long the bridge waits for a decision; the app auto-releases the card slightly earlier.
    static let permissionTimeout: TimeInterval = 10 * 60

    /// Every duration, timeout and ordering here runs on `clock`'s monotonic half; wall-clock dates are for display
    /// and are moved along when the wall clock is set (`syncWallClock`).
    private let clock: AppClock
    private var wallClock = WallClockJumpDetector()
    private var timers: [Timer] = []
    private var clockObserver: NSObjectProtocol?
    private var flashTask: Task<Void, Never>?
    /// Monotonic seconds of the last usage nudge from a Claude event, and of the last refresh for display.
    private var lastUsageNudge = -TimeInterval.infinity
    private var lastDisplayRefresh = -TimeInterval.infinity
    private var usageTimer: Timer?
    /// How long a notice stays (Settings → Остров → «Уведомление держится»).
    var flashSeconds: () -> TimeInterval = { 5 }
    /// Settings → «Показывать ответ агента при завершении».
    var showsAgentReply: () -> Bool = { true }
    /// A «Готово» card stays at least this long (it has text to read).
    static let doneCardSeconds: TimeInterval = 7
    /// A queued card older than this is not shown any more.
    static let doneQueueLifetime: TimeInterval = 90
    /// The pointer is on the notice: it does not go away under it.
    private var flashHeld = false
    /// Every hook event, after the model applied it (the other agents' usage readers look at them).
    var onEvent: (AgentEvent) -> Void = { _ in }

    init(jumper: TerminalJumping, usageProvider: UsageProviding, clock: AppClock = .system) {
        self.jumper = jumper
        self.usageProvider = usageProvider
        self.clock = clock
        titleResolver = SessionTitleResolver(clock: clock)
        _ = now()
        titleResolver.sessions = { [weak self] in self.map { Array($0.store.sessions.values) } ?? [] }
        titleResolver.onTitle = { [weak self] title, key in self?.setChatTitle(title, for: key) }
    }

    func start() {
        // Setting the clock (by hand, NTP) posts this; the timer catches anything it misses.
        clockObserver = NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncWallClock() }
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncWallClock() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.housekeeping() }
        })
        // None of these needs to be punctual: loose deadlines let the system coalesce the wake-ups.
        for timer in timers { timer.tolerance = timer.timeInterval / 10 }
        setUsageRefreshInterval(usageInterval)
        Task { await refreshUsage() }
        titleResolver.start()
    }

    // MARK: Events from the socket server (call on main actor)

    /// `detail`: the permission card's content, built off the main thread for a permission request (built here
    /// when missing).
    func handle(_ request: BridgeRequest, reply: ReplyHandle?, detail: PermissionDetail? = nil) {
        let event = request.event
        // The bridge's stamp is another process's wall clock: it only orders events that arrive out of order,
        // and not right after the clock was set (a stamp from before the jump would look seconds old).
        let received = now()
        let moment = received.eventMoment(stampedAt: event.timestamp,
                                          maxTransit: wallClock.isSettled(at: received) ? Moment.maxEventTransit : 0)
        // Signs that a pending card was answered elsewhere (in the terminal): that agent thread moved on
        // (Stop / prompt / its next tool call), the very same tool call completed, or the session ended.
        // Matched per (session, agent_id): a background subagent's card survives the main agent's Stop.
        dropPending { PendingPermissionPolicy.isSuperseded($0.event, at: $0.eventMoment, by: event, at: moment) }

        if event.source == .claude { nudgeUsage(at: received) }

        let waitingSince = store.sessions[event.sessionKey].flatMap { $0.status == .waitingForUser ? $0.statusMoment : nil }
        var effects = store.apply(event, at: moment)
        if let session = store.sessions[event.sessionKey] { titleResolver.sessionUpdated(session) }

        if event.kind == .permissionRequest, event.decisionSupported, let reply {
            let pending = PendingPermission(event: event, eventMoment: moment, received: received, reply: reply,
                                            detail: detail ?? PermissionDetail(event: event))
            reply.onPeerClosed = { [weak self] in
                Task { @MainActor in self?.dropPending { $0.id == event.id } }
            }
            pendingPermissions.append(pending)
        } else {
            reply?.close()
        }

        // A card still on the island (e.g. a subagent's after the main agent's Stop) keeps its session waiting.
        if event.kind != .sessionEnd, hasPending(event.sessionKey) {
            store.markWaiting(event.sessionKey, at: waitingSince ?? moment)
            effects.removeAll { $0 == .finished(event.sessionKey) }
        }

        onEvent(event)

        for effect in effects {
            switch effect {
            case .finished(let key):
                if let s = store.sessions[key] {
                    let reply = showsAgentReply() ? s.lastAgentMessage : nil
                    showFlash(FlashNotice(key: key, kind: .finished, title: s.title,
                                          detail: L("%@ — готово", key.source.displayName), reply: reply))
                }
            case .needsAttention(let key, let message):
                if let s = store.sessions[key] {
                    showFlash(FlashNotice(key: key, kind: .attention, title: s.title, detail: message ?? L("Ждёт тебя")))
                }
            case .ended:
                break
            }
        }
    }

    // MARK: User actions

    func decide(_ id: UUID, _ decision: PermissionDecision) {
        guard let idx = pendingPermissions.firstIndex(where: { $0.id == id }) else { return }
        let p = pendingPermissions.remove(at: idx)
        if p.reply.isOpen {
            p.reply.send(BridgeReply(eventId: id, decision: decision))
        }
        if case .askInTerminal = decision {
            jump(to: p.event.sessionKey)
        } else if !hasPending(p.event.sessionKey) {
            store.permissionAnswered(p.event.sessionKey, at: now())
        }
    }

    func jump(to key: SessionKey) {
        guard let s = store.sessions[key] else { return }
        jumper.jump(to: s)
        flashQueue.removeAll { $0.key == key }
        if flash?.key == key { dismissFlash() }
    }

    /// The notice goes; the next queued «Готово» card (if any is still fresh) comes up, unless `all`.
    func dismissFlash(all: Bool = false) {
        flashTask?.cancel()
        if all { flashQueue.removeAll() }
        let now = AppClock.monotonicSeconds()
        flashQueue.removeAll { now - $0.madeAt > Self.doneQueueLifetime || store.sessions[$0.key] == nil }
        guard !flashQueue.isEmpty else {
            flash = nil
            return
        }
        let next = flashQueue.removeFirst()
        present(next)
    }

    /// The pointer rests on the notice (true): it stays; leaves (false): it goes a few seconds later.
    func holdFlash(_ hold: Bool) {
        guard hold != flashHeld else { return }
        flashHeld = hold
        guard let notice = flash else { return }
        if hold {
            flashTask?.cancel()
        } else {
            scheduleFlashEnd(notice, after: notice.isDoneCard ? 3 : 1.5)
        }
    }

    /// Names a session's chat (`AgentSession.chatTitle`, shown through `displayTitle`). Blank clears it.
    /// Publishes only when the title actually changed.
    func setChatTitle(_ title: String?, for key: SessionKey) {
        var updated = store
        guard updated.setChatTitle(title, for: key) else { return }
        store = updated
    }

    func removeSession(_ key: SessionKey) {
        dropPending { $0.event.sessionKey == key }
        store.remove(key)
    }

    func refreshUsage() async {
        usage = await usageProvider.fetch()
    }

    /// How often the usage is re-read (Settings → Лимиты → «Обновлять»). Cheap: the provider reads the statusLine
    /// cache and throttles its own network calls.
    private(set) var usageInterval: TimeInterval = 60

    func setUsageRefreshInterval(_ seconds: TimeInterval) {
        usageInterval = max(seconds, 30)
        usageTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: usageInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshUsage() }
        }
        timer.tolerance = usageInterval / 10
        usageTimer = timer
    }

    /// Settings → «Лимиты Claude через API» changed: re-read at once (the fetcher reads the switch itself).
    func usageSourceChanged() {
        lastDisplayRefresh = -TimeInterval.infinity
        let provider = usageProvider
        Task { [weak self] in
            await provider.nudge()
            await self?.refreshUsage()
        }
    }

    /// The usage is about to be looked at (the menu opens, the list opens): a no-login pause shrinks back to the
    /// normal interval and the figure is re-read (the provider still throttles the network). At most every 30 s.
    func refreshUsageForDisplay() {
        let now = clock.now().monotonic
        guard now - lastDisplayRefresh >= 30 else { return }
        lastDisplayRefresh = now
        let provider = usageProvider
        Task { [weak self] in
            await provider.nudge()
            await self?.refreshUsage()
        }
    }

    /// A Claude session is active: signing in to Claude shows up within the normal interval. At most once a minute.
    private func nudgeUsage(at moment: Moment) {
        guard moment.monotonic - lastUsageNudge >= 60 else { return }
        lastUsageNudge = moment.monotonic
        let provider = usageProvider
        Task { await provider.nudge() }
    }

    // MARK: Relaunching

    /// How long every session must have been silent before the app may relaunch on its own (to install an update).
    nonisolated static let quietSessionAge: TimeInterval = 20 * 60

    /// Relaunching now would take nothing away from the user. Sessions live in memory only, so a relaunch forgets
    /// them, their last answers and any «Готово» card: no permission card, no notice on screen or waiting in the
    /// queue, no agent working or waiting, and no session with an event in the last `quietSessionAge`.
    func canRelaunchQuietly(quietSessionAge: TimeInterval = AppModel.quietSessionAge) -> Bool {
        guard pendingPermissions.isEmpty, flash == nil, flashQueue.isEmpty else { return false }
        let moment = now()
        return !store.sessions.values.contains {
            $0.status == .working || $0.status == .waitingForUser || moment.since($0.lastEventMoment) < quietSessionAge
        }
    }

    // MARK: Internals

    private func hasPending(_ key: SessionKey) -> Bool {
        pendingPermissions.contains { $0.event.sessionKey == key }
    }

    private func dropPending(where predicate: (PendingPermission) -> Bool) {
        let (drop, keep) = pendingPermissions.reduce(into: ([PendingPermission](), [PendingPermission]())) {
            predicate($1) ? $0.0.append($1) : $0.1.append($1)
        }
        guard !drop.isEmpty else { return }
        drop.forEach { $0.reply.close() }
        pendingPermissions = keep
    }

    private func housekeeping() {
        let moment = now()
        dropPending { !$0.reply.isOpen || moment.since($0.received) > Self.permissionTimeout }
        let removed = Set(store.expire(at: moment))
        if !removed.isEmpty { dropPending { removed.contains($0.event.sessionKey) } }
    }

    // MARK: Clock

    /// The current moment, after moving every displayed wall-clock date along if the wall clock was set.
    private func now() -> Moment {
        let moment = clock.now()
        if let delta = wallClock.check(moment) { shiftWallClock(by: delta) }
        return moment
    }

    private func syncWallClock() {
        _ = now()
    }

    /// Keeps `wall now − statusSince` (the island's "работает 2:14") and the cards' waiting clocks true.
    private func shiftWallClock(by delta: TimeInterval) {
        store.shiftWallClock(by: delta)
        if !pendingPermissions.isEmpty {
            pendingPermissions = pendingPermissions.map {
                var p = $0
                p.received.wall.addTimeInterval(delta)
                p.eventMoment.wall.addTimeInterval(delta)
                return p
            }
        }
        Log.info("clock: wall clock moved by \(Int(delta.rounded())) s; displayed times follow it")
    }

    /// A new notice. Several quick completions queue: the newest «Готово» card shows, the one it covers waits behind it
    /// (one per session); an attention notice covers a card the same way.
    private func showFlash(_ notice: FlashNotice) {
        if let current = flash, current.isDoneCard {
            flashQueue.removeAll { $0.key == current.key || $0.key == notice.key }
            flashQueue.insert(current, at: 0)
            if flashQueue.count > 8 { flashQueue.removeLast(flashQueue.count - 8) }
        } else {
            flashQueue.removeAll { $0.key == notice.key }
        }
        present(notice)
    }

    private func present(_ notice: FlashNotice) {
        flash = notice
        flashTask?.cancel()
        guard !flashHeld else { return }
        let seconds = max(1, flashSeconds())
        scheduleFlashEnd(notice, after: notice.isDoneCard ? max(seconds, Self.doneCardSeconds) : seconds)
    }

    private func scheduleFlashEnd(_ notice: FlashNotice, after seconds: TimeInterval) {
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.flash?.id == notice.id, !self.flashHeld else { return }
                self.dismissFlash()
            }
        }
    }
}
