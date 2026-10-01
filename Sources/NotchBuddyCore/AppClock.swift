import Darwin
import Foundation

/// One instant, read from both of the app's clocks at once.
///
/// `wall` is for display and for data that crosses process boundaries (bridge event stamps, the statusLine
/// cache, server reset times). It can be set hours either way at any moment (by hand, an NTP step, a bad RTC).
/// `monotonic` is seconds on a clock that is never set and keeps counting through sleep: every duration,
/// timeout, staleness check and ordering the app computes itself compares these.
public struct Moment: Hashable, Sendable {
    public var wall: Date
    /// Seconds from an arbitrary origin (`AppClock.monotonicSeconds`). Only differences mean anything.
    public var monotonic: TimeInterval

    public init(wall: Date, monotonic: TimeInterval) {
        self.wall = wall
        self.monotonic = monotonic
    }

    /// A moment on the single-clock timeline of callers that only have a `Date` (legacy APIs, previews,
    /// tests): its monotonic seconds are the wall clock itself. Never mix these with `AppClock` moments
    /// in one store.
    public static func wallOnly(_ date: Date) -> Moment {
        Moment(wall: date, monotonic: date.timeIntervalSinceReferenceDate)
    }

    /// Seconds from `earlier` to this moment, on the monotonic clock.
    public func since(_ earlier: Moment) -> TimeInterval { monotonic - earlier.monotonic }

    public func advanced(by seconds: TimeInterval) -> Moment {
        Moment(wall: wall.addingTimeInterval(seconds), monotonic: monotonic + seconds)
    }

    /// How long a hook event may plausibly have been in flight from the bridge to the app.
    public static let maxEventTransit: TimeInterval = 2

    /// When a cross-process event stamped `stamp` (the bridge's wall clock) happened, given that it arrived at
    /// this moment. The stamp contributes only the transit delay, clamped to `0...maxTransit`: enough to keep
    /// parallel hook processes that arrive out of order in their real order, while a stamp taken before the
    /// wall clock was set can move the event at most `maxTransit` into the past, and never into the future.
    public func eventMoment(stampedAt stamp: Date, maxTransit: TimeInterval = Moment.maxEventTransit) -> Moment {
        let transit = wall.timeIntervalSince(stamp)
        let limit = maxTransit.isFinite ? max(maxTransit, 0) : 0
        let delay = transit.isFinite ? min(max(transit, 0), limit) : 0
        return advanced(by: -delay)
    }
}

/// The app's source of `Moment`s. Injected, so tests can tick both clocks or set the wall clock alone.
public struct AppClock: Sendable {
    private let read: @Sendable () -> Moment

    public init(_ read: @escaping @Sendable () -> Moment) {
        self.read = read
    }

    public func now() -> Moment { read() }

    public static let system = AppClock { Moment(wall: Date(), monotonic: AppClock.monotonicSeconds()) }

    /// `CLOCK_MONOTONIC_RAW` (mach continuous time, what `ContinuousClock` reads): never set, counts sleep,
    /// like the bridge's own decision deadline (`CLOCK_MONOTONIC`).
    public static func monotonicSeconds() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }
}

/// Notices the wall clock being set: the offset between the wall and monotonic clocks moves.
///
/// The app shows elapsed times as `wall now − statusSince`, so every stored wall-clock date must move with
/// the wall clock (`SessionStore.shiftWallClock(by:)`). The detector keeps the offset those dates are based on
/// and reports the difference once it exceeds `threshold`; oscillator drift below it accumulates until then.
public struct WallClockJumpDetector: Equatable, Sendable {
    public var threshold: TimeInterval
    /// `wall − monotonic` that the app's stored wall-clock dates are based on (nil before the first check).
    public private(set) var baseline: TimeInterval?
    /// Monotonic seconds of the last jump reported.
    public private(set) var lastJump: TimeInterval?

    public init(threshold: TimeInterval = 2) {
        self.threshold = threshold
    }

    /// How far the wall clock moved relative to the monotonic one since the baseline (positive: forward), or
    /// nil while that stays within `threshold`. A reported jump becomes the new baseline.
    public mutating func check(_ now: Moment) -> TimeInterval? {
        let offset = now.wall.timeIntervalSinceReferenceDate - now.monotonic
        guard offset.isFinite else { return nil }
        guard let baseline else {
            self.baseline = offset
            return nil
        }
        let delta = offset - baseline
        guard abs(delta) > threshold else { return nil }
        self.baseline = offset
        lastJump = now.monotonic
        return delta
    }

    /// Whether wall-clock stamps from other processes can be trusted for small transit delays right now:
    /// not within `window` seconds after a jump (a stamp taken just before it would look seconds old).
    public func isSettled(at now: Moment, window: TimeInterval = Moment.maxEventTransit + 1) -> Bool {
        guard let lastJump else { return true }
        return now.monotonic - lastJump > window
    }
}
