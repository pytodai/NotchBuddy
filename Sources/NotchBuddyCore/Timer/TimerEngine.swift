import Foundation

/// One countdown on the island ("Помодоро 24:13").
///
/// Every duration runs on the monotonic clock (`Moment.monotonic`): setting the Mac's clock never moves a
/// timer, and a timer keeps counting through sleep (the finish is then delivered on wake).
public struct TimerItem: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Counting down; ends at `deadline` (monotonic seconds).
        case running(deadline: TimeInterval)
        /// Stopped with this much left.
        case paused(remaining: TimeInterval)
    }

    public let id: UUID
    /// The Russian key of its name ("Помодоро", "Таймер"): shown as `L(label)`.
    public var label: String

    /// The label of a timer started with its own time (not a preset).
    public static let customLabel = LKey("Таймер")
    /// The whole length, including every "+1 мин" (the ring is a fraction of it).
    public var duration: TimeInterval
    public var state: State
    /// When it was started (wall clock, for display only).
    public var startedAt: Date

    public init(id: UUID = UUID(), label: String, duration: TimeInterval, state: State, startedAt: Date) {
        self.id = id
        self.label = label
        self.duration = duration
        self.state = state
        self.startedAt = startedAt
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    public var isPaused: Bool { !isRunning }

    /// Seconds left at `now` (never negative).
    public func remaining(at now: Moment) -> TimeInterval {
        switch state {
        case .running(let deadline): return max(0, deadline - now.monotonic)
        case .paused(let remaining): return max(0, remaining)
        }
    }

    /// Fraction of the whole still to go: 1 at the start, 0 at the end.
    public func fractionRemaining(at now: Moment) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(remaining(at: now) / duration, 0), 1)
    }

    /// The whole seconds a clock shows at `now`: rounded up, so a fresh 5-minute timer reads "5:00" for its
    /// first second and "0:01" for its last one.
    public func displaySeconds(at now: Moment) -> Int {
        TimerFormat.displaySeconds(remaining(at: now))
    }

    /// When it ends on the wall clock, if it is running.
    public func endsAt(_ now: Moment) -> Date? {
        guard isRunning else { return nil }
        return now.wall.addingTimeInterval(remaining(at: now))
    }
}

/// A timer that ran out: what the celebration and the notice show.
public struct TimerFinish: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let duration: TimeInterval
    /// When it ended (the deadline, not when the app noticed: a Mac that slept through it reports the real time).
    public let finishedAt: Moment
    /// How late the app noticed (asleep, busy): a finish far in the past plays no sound.
    public let lateness: TimeInterval

    public init(id: UUID, label: String, duration: TimeInterval, finishedAt: Moment, lateness: TimeInterval) {
        self.id = id
        self.label = label
        self.duration = duration
        self.finishedAt = finishedAt
        self.lateness = lateness
    }
}

/// A quick-start duration.
public struct TimerPreset: Identifiable, Equatable, Sendable {
    public var id: Int { minutes }
    public let minutes: Int
    /// Name of a timer started from it.
    public let title: String

    public init(minutes: Int, title: String) {
        self.minutes = minutes
        self.title = title
    }

    public var seconds: TimeInterval { TimeInterval(minutes * 60) }

    /// Titles are Russian keys (`LKey`): a timer keeps its preset's key as its label and shows `L(label)`, so the
    /// label follows a language switch and still matches its preset.
    public static let standard: [TimerPreset] = [
        TimerPreset(minutes: 1, title: LKey("Минутка")),
        TimerPreset(minutes: 5, title: LKey("Перерыв")),
        TimerPreset(minutes: 10, title: LKey("Десять минут")),
        TimerPreset(minutes: 25, title: LKey("Помодоро")),
    ]
}

/// Every timer on the island, as a value: the app's `TimerStore` owns one and asks it what to show and when
/// to wake up. Pure (no clocks of its own), so every rule is unit-tested.
public struct TimerEngine: Equatable, Sendable {
    /// In start order.
    public private(set) var timers: [TimerItem] = []

    public static let maxTimers = 8
    public static let minDuration: TimeInterval = 1
    /// 23:59:59.
    public static let maxDuration: TimeInterval = 24 * 3600 - 1

    public init(timers: [TimerItem] = []) {
        self.timers = timers
    }

    public var isEmpty: Bool { timers.isEmpty }
    public var hasRunning: Bool { timers.contains { $0.isRunning } }

    public func timer(_ id: UUID) -> TimerItem? { timers.first { $0.id == id } }

    // MARK: Changes

    /// Starts a countdown; nil when there are already `maxTimers` or the duration is not a real one.
    @discardableResult
    public mutating func start(duration: TimeInterval, label: String, at now: Moment, id: UUID = UUID()) -> TimerItem? {
        guard duration.isFinite, timers.count < Self.maxTimers else { return nil }
        let length = min(max(duration.rounded(), Self.minDuration), Self.maxDuration)
        let item = TimerItem(id: id, label: label, duration: length,
                             state: .running(deadline: now.monotonic + length), startedAt: now.wall)
        timers.append(item)
        return item
    }

    @discardableResult
    public mutating func pause(_ id: UUID, at now: Moment) -> Bool {
        guard let i = index(id), case .running = timers[i].state else { return false }
        let left = timers[i].remaining(at: now)
        // A timer paused in its very last instant is as good as finished: let it finish.
        guard left > 0 else { return false }
        timers[i].state = .paused(remaining: left)
        return true
    }

    @discardableResult
    public mutating func resume(_ id: UUID, at now: Moment) -> Bool {
        guard let i = index(id), case .paused(let left) = timers[i].state else { return false }
        timers[i].state = .running(deadline: now.monotonic + max(left, 0))
        return true
    }

    /// Pause ↔ resume.
    @discardableResult
    public mutating func toggle(_ id: UUID, at now: Moment) -> Bool {
        guard let timer = timer(id) else { return false }
        return timer.isRunning ? pause(id, at: now) : resume(id, at: now)
    }

    @discardableResult
    public mutating func cancel(_ id: UUID) -> TimerItem? {
        guard let i = index(id) else { return nil }
        return timers.remove(at: i)
    }

    public mutating func cancelAll() { timers.removeAll() }

    /// "+1 мин": more time on a running or paused timer (the whole grows with it, so the ring steps back).
    @discardableResult
    public mutating func extend(_ id: UUID, by seconds: TimeInterval, at now: Moment) -> Bool {
        guard let i = index(id), seconds.isFinite, seconds > 0 else { return false }
        let left = timers[i].remaining(at: now)
        let room = Self.maxDuration - left
        guard room >= 1 else { return false }
        let add = min(seconds, room)
        switch timers[i].state {
        case .running(let deadline): timers[i].state = .running(deadline: deadline + add)
        case .paused(let remaining): timers[i].state = .paused(remaining: remaining + add)
        }
        // The ring shows what is left of the whole: never more than full.
        timers[i].duration = min(max(timers[i].duration + add, left + add), Self.maxDuration)
        return true
    }

    /// From the top, running.
    @discardableResult
    public mutating func restart(_ id: UUID, at now: Moment) -> Bool {
        guard let i = index(id) else { return false }
        timers[i].state = .running(deadline: now.monotonic + timers[i].duration)
        timers[i].startedAt = now.wall
        return true
    }

    /// Removes every running timer whose deadline has passed and reports them, earliest first.
    public mutating func collectFinished(at now: Moment) -> [TimerFinish] {
        var finished: [TimerFinish] = []
        timers.removeAll { timer in
            guard case .running(let deadline) = timer.state, deadline <= now.monotonic else { return false }
            let late = max(0, now.monotonic - deadline)
            finished.append(TimerFinish(id: timer.id, label: timer.label, duration: timer.duration,
                                        finishedAt: now.advanced(by: -late), lateness: late))
            return true
        }
        return finished.sorted { $0.finishedAt.monotonic < $1.finishedAt.monotonic }
    }

    // MARK: Reading

    /// The earliest deadline of a running timer (monotonic seconds): when the store must wake up next.
    public var nextDeadline: TimeInterval? {
        timers.compactMap { timer -> TimeInterval? in
            if case .running(let deadline) = timer.state { return deadline }
            return nil
        }.min()
    }

    /// Running timers first, soonest first; then paused ones, least left first.
    public func ordered(at now: Moment) -> [TimerItem] {
        timers.enumerated().sorted { a, b in
            if a.element.isRunning != b.element.isRunning { return a.element.isRunning }
            let ra = a.element.remaining(at: now), rb = b.element.remaining(at: now)
            if ra != rb { return ra < rb }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The timer the closed island shows: the one that ends soonest, else the paused one with least left.
    public func primary(at now: Moment) -> TimerItem? { ordered(at: now).first }

    /// Seconds until the clock of some running timer shows a different number (its remaining time crosses a
    /// whole second), so a view ticks exactly when it has something new to show; nil when nothing runs.
    public func nextTickDelay(at now: Moment) -> TimeInterval? {
        timers.compactMap { timer -> TimeInterval? in
            guard timer.isRunning else { return nil }
            let left = timer.remaining(at: now)
            guard left > 0 else { return 0 }
            return TimerFormat.untilNextSecond(left)
        }.min()
    }

    private func index(_ id: UUID) -> Int? { timers.firstIndex { $0.id == id } }
}

// MARK: - Persistence

extension TimerEngine {
    /// What survives a relaunch: running timers by their wall-clock deadline (the monotonic clock restarts with
    /// the Mac), paused ones by what they had left.
    public struct Saved: Codable, Equatable, Sendable {
        public struct Entry: Codable, Equatable, Sendable {
            public var id: UUID
            public var label: String
            public var duration: TimeInterval
            public var startedAt: Date
            /// Running: when it ends on the wall clock.
            public var endsAt: Date?
            /// Paused: what was left.
            public var remaining: TimeInterval?
        }

        public var version = 1
        public var timers: [Entry]
    }

    public func saved(at now: Moment) -> Saved {
        Saved(timers: timers.map { timer in
            switch timer.state {
            case .running:
                return .init(id: timer.id, label: timer.label, duration: timer.duration, startedAt: timer.startedAt,
                             endsAt: now.wall.addingTimeInterval(timer.remaining(at: now)), remaining: nil)
            case .paused(let left):
                return .init(id: timer.id, label: timer.label, duration: timer.duration, startedAt: timer.startedAt,
                             endsAt: nil, remaining: left)
            }
        })
    }

    /// Rebuilds the timers saved before a relaunch. A running timer's deadline moves onto this run's monotonic
    /// clock through the wall clock (the one clock both runs share); one that ended meanwhile is due at once and
    /// comes out of the next `collectFinished`. Entries that make no sense are dropped.
    public init(saved: Saved, at now: Moment) {
        var restored: [TimerItem] = []
        for entry in saved.timers.prefix(Self.maxTimers) {
            guard entry.duration.isFinite, entry.duration >= Self.minDuration, entry.duration <= Self.maxDuration else { continue }
            if let endsAt = entry.endsAt {
                let left = endsAt.timeIntervalSince(now.wall)
                guard left.isFinite, left <= Self.maxDuration else { continue }
                restored.append(TimerItem(id: entry.id, label: entry.label, duration: entry.duration,
                                          state: .running(deadline: now.monotonic + left), startedAt: entry.startedAt))
            } else if let left = entry.remaining, left.isFinite, left > 0 {
                restored.append(TimerItem(id: entry.id, label: entry.label, duration: entry.duration,
                                          state: .paused(remaining: min(left, entry.duration)), startedAt: entry.startedAt))
            }
        }
        self.init(timers: restored)
    }
}

// MARK: - Format

/// How timers read: "4:59", "1:02:03", "25 мин", "1 ч 30 мин".
public enum TimerFormat {
    private static let nbsp = "\u{00A0}"

    /// Whole seconds a countdown shows (rounded up; 0 only at the very end).
    public static func displaySeconds(_ remaining: TimeInterval) -> Int {
        guard remaining.isFinite, remaining > 0 else { return 0 }
        return Int(min((remaining - 1e-9).rounded(.up), 1e9))
    }

    /// Seconds until `displaySeconds` changes for a countdown with `remaining` left.
    public static func untilNextSecond(_ remaining: TimeInterval) -> TimeInterval {
        guard remaining.isFinite, remaining > 0 else { return 0 }
        let below = (remaining - 1e-9).rounded(.down)
        return max(remaining - below, 0.001)
    }

    /// "4:59", "25:00", "1:02:03".
    public static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }

    /// The clock of a countdown with `remaining` left.
    public static func clock(remaining: TimeInterval) -> String { clock(displaySeconds(remaining)) }

    /// A length in words: "30 с", "1 мин", "1 мин 30 с", "25 мин", "1 ч", "1 ч 5 мин".
    public static func length(_ interval: TimeInterval) -> String {
        let s = interval.isFinite ? Int(min(max(interval.rounded(), 0), 1e9)) : 0
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        var parts: [String] = []
        if h > 0 { parts.append(L("%@\u{00A0}ч", h)) }
        if m > 0 { parts.append(L("%@\u{00A0}мин", m)) }
        if r > 0 && h == 0 { parts.append(L("%@\u{00A0}с", r)) }
        return parts.isEmpty ? L("0\u{00A0}с") : parts.joined(separator: " ")
    }

    /// Custom duration steps: seconds under a minute go by 5 s (so "30 с" is reachable), then 15 s up to
    /// 5 minutes, then whole minutes.
    public static func step(from seconds: TimeInterval, up: Bool) -> TimeInterval {
        let s = Int(max(0, seconds.rounded()))
        let unit: Int
        if up {
            unit = s < 60 ? 5 : s < 300 ? 15 : 60
            let next = (s / unit + 1) * unit
            return TimeInterval(min(next, Int(TimerEngine.maxDuration)))
        } else {
            unit = s <= 60 ? 5 : s <= 300 ? 15 : 60
            let prev = s % unit == 0 ? s - unit : (s / unit) * unit
            return TimeInterval(max(prev, 5))
        }
    }

    /// A step of whole minutes (the minutes wheel of the custom picker), kept within 0…23:59 and above 5 s.
    public static func stepMinutes(from seconds: TimeInterval, by minutes: Int) -> TimeInterval {
        let s = Int(max(0, seconds.rounded()))
        let next = s + minutes * 60
        return TimeInterval(min(max(next, 5), Int(TimerEngine.maxDuration)))
    }
}
