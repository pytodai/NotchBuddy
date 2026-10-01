import AppKit
import Observation
import SwiftUI
import NotchBuddyCore

/// The island's timers: owns a `TimerEngine`, wakes up exactly when a timer ends (and on wake from sleep),
/// plays the end sound, reports every finish to `onFinish`, and keeps `now` ticking — only while a view that
/// shows a countdown is on screen, and only when some countdown's shown second changes.
///
/// Wiring: create one at launch, call `start()`, set `onFinish` to show `TimerFinishNoticeView`
/// (and a celebration), put `TimerWidgetView(store:metrics:width:)` on a widget page and
/// `TimerLiveActivityView(store:metrics:)` in the closed island while `hasLiveActivity`.
@Observable
@MainActor
final class TimerStore {
    /// Every timer (read the ordered list through `ordered`).
    private(set) var engine: TimerEngine
    /// The moment views show; ticks while someone looks (`beginViewing`).
    private(set) var now: Moment
    /// The latest finish, for this long after it (the live activity and the widget show "Готово").
    private(set) var recentFinish: TimerFinish?
    /// Bumped on every change a view might animate (a start, +1 мин) with the id it concerns.
    private(set) var lastEvent: TimerEvent?
    let preferences: TimerPreferences

    /// A timer ran out (after the sound). The notice / celebration hangs off this.
    @ObservationIgnored var onFinish: ((TimerFinish) -> Void)?
    /// Anything changed that decides what the closed island shows (a timer started, ended, was cancelled).
    @ObservationIgnored var onChange: (() -> Void)?

    static let celebrationDuration: TimeInterval = 6
    /// A finish noticed this late (the Mac slept through it) shows, but plays no sound.
    static let silentAfter: TimeInterval = 60

    @ObservationIgnored private let clock: AppClock
    @ObservationIgnored private let frozen: Bool
    @ObservationIgnored private var finishTimer: Timer?
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var clearTimer: Timer?
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var hues: [UUID: Int] = [:]
    @ObservationIgnored private var nextHue = 0

    init(clock: AppClock = .system, preferences: TimerPreferences? = nil, restore: Bool = true) {
        self.clock = clock
        let preferences = preferences ?? TimerPreferences()
        self.preferences = preferences
        frozen = false
        let now = clock.now()
        self.now = now
        if restore, let data = preferences.defaults.data(forKey: TimerPreferences.Key.saved),
           let saved = try? JSONDecoder().decode(TimerEngine.Saved.self, from: data) {
            engine = TimerEngine(saved: saved, at: now)
        } else {
            engine = TimerEngine()
        }
        engine.timers.forEach { _ = hue(for: $0.id) }
    }

    /// A store that never moves (previews, filmstrips): fixed timers at a fixed moment.
    init(frozenAt now: Moment, engine: TimerEngine, recentFinish: TimerFinish? = nil,
         preferences: TimerPreferences? = nil) {
        clock = AppClock { now }
        self.preferences = preferences
            ?? TimerPreferences(defaults: UserDefaults(suiteName: "notchbuddy.timer.preview") ?? .standard)
        frozen = true
        self.now = now
        self.engine = engine
        self.recentFinish = recentFinish
        engine.timers.forEach { _ = hue(for: $0.id) }
    }

    // MARK: Lifecycle

    /// Starts watching the clock: finishes due while the app was away fire now, the next one is scheduled.
    func start() {
        guard !frozen, observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.refresh() }
        }))
        // Timers fire on the wall clock's schedule; a set clock needs a new one.
        observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }))
        refresh()
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        [finishTimer, tickTimer, clearTimer].forEach { $0?.invalidate() }
        finishTimer = nil
        tickTimer = nil
        clearTimer = nil
    }

    // MARK: Reading

    /// Running soonest first, then paused.
    var ordered: [TimerItem] { engine.ordered(at: now) }
    var primary: TimerItem? { engine.primary(at: now) }
    var isEmpty: Bool { engine.isEmpty }

    /// The closed island shows the timer (a countdown, or "Готово" right after one ends).
    var hasLiveActivity: Bool {
        preferences.liveActivity && (primary != nil || recentFinish != nil)
    }

    /// Each timer's own hue, kept for its whole life (the pomodoro is always tomato).
    func tint(for timer: TimerItem) -> GadgetTint {
        if timer.label == TimerPreset.standard.last?.title { return TimerPalette.tomato }
        return TimerPalette.hues[(hues[timer.id] ?? 0) % TimerPalette.hues.count]
    }

    func tint(for finish: TimerFinish) -> GadgetTint { TimerPalette.done }

    // MARK: Intents

    @discardableResult
    func start(preset: TimerPreset) -> TimerItem? { start(seconds: preset.seconds, label: preset.title) }

    /// The custom picker's duration.
    @discardableResult
    func startCustom() -> TimerItem? { start(seconds: preferences.customSeconds, label: TimerItem.customLabel) }

    @discardableResult
    func start(seconds: TimeInterval, label: String) -> TimerItem? {
        let moment = touch()
        guard let item = engine.start(duration: seconds, label: label, at: moment) else { return nil }
        _ = hue(for: item.id)
        lastEvent = TimerEvent(kind: .started, id: item.id, at: moment.monotonic)
        changed()
        return item
    }

    func toggle(_ id: UUID) {
        let moment = touch()
        guard engine.toggle(id, at: moment) else { return }
        lastEvent = TimerEvent(kind: engine.timer(id)?.isRunning == true ? .resumed : .paused, id: id, at: moment.monotonic)
        changed()
    }

    func cancel(_ id: UUID) {
        touch()
        guard engine.cancel(id) != nil else { return }
        hues[id] = nil
        changed()
    }

    /// "+1 мин".
    func addMinute(_ id: UUID) {
        let moment = touch()
        guard engine.extend(id, by: 60, at: moment) else { return }
        lastEvent = TimerEvent(kind: .extended, id: id, at: moment.monotonic)
        changed()
    }

    func restart(_ id: UUID) {
        let moment = touch()
        guard engine.restart(id, at: moment) else { return }
        lastEvent = TimerEvent(kind: .started, id: id, at: moment.monotonic)
        changed()
    }

    /// The finish notice's "Повторить": the same timer again.
    @discardableResult
    func again(_ finish: TimerFinish) -> TimerItem? {
        dismissFinish()
        return start(seconds: finish.duration, label: finish.label)
    }

    /// The finish notice's "+1 мин": one more minute under the same name.
    @discardableResult
    func snooze(_ finish: TimerFinish, minutes: Int = 1) -> TimerItem? {
        dismissFinish()
        return start(seconds: TimeInterval(minutes * 60), label: finish.label)
    }

    func dismissFinish() {
        guard recentFinish != nil else { return }
        recentFinish = nil
        clearTimer?.invalidate()
        clearTimer = nil
        onChange?()
    }

    /// The custom picker: − / +.
    func stepCustom(up: Bool) {
        preferences.customSeconds = TimerFormat.step(from: preferences.customSeconds, up: up)
    }

    // MARK: Viewing

    /// A view that shows a countdown appeared: `now` ticks until the last one goes.
    func beginViewing() {
        viewers += 1
        guard viewers == 1 else { return }
        touch()
        scheduleTick()
    }

    func endViewing() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: Clock

    @discardableResult
    private func touch() -> Moment {
        guard !frozen else { return now }
        let moment = clock.now()
        now = moment
        return moment
    }

    /// Collects finishes, reschedules the wake-up and the tick.
    private func refresh() {
        guard !frozen else { return }
        let moment = touch()
        let finished = engine.collectFinished(at: moment)
        for finish in finished { deliver(finish) }
        if !finished.isEmpty { changed(save: true) } else { schedule() }
    }

    private func deliver(_ finish: TimerFinish) {
        hues[finish.id] = nil
        recentFinish = finish
        lastEvent = TimerEvent(kind: .finished, id: finish.id, at: now.monotonic)
        if finish.lateness < Self.silentAfter { playSound() }
        clearTimer?.invalidate()
        let clear = Timer(timeInterval: Self.celebrationDuration * IslandMotion.slowmo, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.recentFinish?.id == finish.id else { return }
                self.recentFinish = nil
                self.onChange?()
            }
        }
        RunLoop.main.add(clear, forMode: .common)
        clearTimer = clear
        onFinish?(finish)
    }

    private func playSound() {
        let name = preferences.sound
        guard !name.isEmpty, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.8
        sound.play()
    }

    private func changed(save: Bool = true) {
        if save { persist() }
        schedule()
        onChange?()
    }

    private func persist() {
        guard !frozen else { return }
        if engine.isEmpty {
            preferences.defaults.removeObject(forKey: TimerPreferences.Key.saved)
        } else if let data = try? JSONEncoder().encode(engine.saved(at: now)) {
            preferences.defaults.set(data, forKey: TimerPreferences.Key.saved)
        }
    }

    private func schedule() {
        guard !frozen else { return }
        finishTimer?.invalidate()
        finishTimer = nil
        if let deadline = engine.nextDeadline {
            let delay = max(0, deadline - clock.now().monotonic) + 0.003
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            finishTimer = timer
        }
        scheduleTick()
    }

    /// One wake-up when the next shown second changes (not a steady 1 Hz: several timers out of phase each
    /// tick on their own second, a paused one never).
    private func scheduleTick() {
        tickTimer?.invalidate()
        tickTimer = nil
        guard !frozen, viewers > 0, let delay = engine.nextTickDelay(at: clock.now()) else { return }
        let timer = Timer(timeInterval: delay + 0.004, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.touch()
                if let deadline = self.engine.nextDeadline, deadline <= self.now.monotonic {
                    self.refresh()
                } else {
                    self.scheduleTick()
                }
            }
        }
        timer.tolerance = 0.012
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func hue(for id: UUID) -> Int {
        if let hue = hues[id] { return hue }
        // The first hue not already on screen, in order.
        let used = Set(hues.values.map { $0 % TimerPalette.hues.count })
        let free = (0..<TimerPalette.hues.count).map { ($0 + nextHue) % TimerPalette.hues.count }.first { !used.contains($0) }
        let hue = free ?? nextHue % TimerPalette.hues.count
        nextHue = hue + 1
        hues[id] = hue
        return hue
    }
}

/// Something happened to a timer that a view animates once (a ripple on start, "+1:00" floating up).
struct TimerEvent: Equatable {
    enum Kind: Equatable { case started, paused, resumed, extended, finished }
    let kind: Kind
    let id: UUID
    /// Monotonic seconds: two equal events still differ.
    let at: TimeInterval
}

/// Keeps a store's clock ticking while the modified view is on screen.
struct TimerTicking: ViewModifier {
    let store: TimerStore

    func body(content: Content) -> some View {
        content
            .onAppear { store.beginViewing() }
            .onDisappear { store.endViewing() }
    }
}

extension View {
    func timerTicking(_ store: TimerStore) -> some View { modifier(TimerTicking(store: store)) }
}
