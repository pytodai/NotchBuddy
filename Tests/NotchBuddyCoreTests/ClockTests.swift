import XCTest
@testable import NotchBuddyCore

/// A clock for tests: `advance` lets real time pass (both clocks), `setWall` moves the wall clock alone,
/// like setting the Mac's clock by hand or an NTP step.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Moment

    init(wall: Date = Date(timeIntervalSince1970: 1_800_000_000), monotonic: TimeInterval = 1_000) {
        current = Moment(wall: wall, monotonic: monotonic)
    }

    var now: Moment { lock.withLock { current } }

    var appClock: AppClock { AppClock { [self] in now } }

    @discardableResult
    func advance(_ seconds: TimeInterval) -> Moment {
        lock.withLock {
            current = current.advanced(by: seconds)
            return current
        }
    }

    @discardableResult
    func setWall(by seconds: TimeInterval) -> Moment {
        lock.withLock {
            current.wall.addTimeInterval(seconds)
            return current
        }
    }
}

final class ClockTests: XCTestCase {
    private let hours: TimeInterval = 3600

    // MARK: Moment

    func testEventMomentKeepsSmallTransitSoOutOfOrderArrivalsStayOrdered() {
        let arrival = Moment(wall: Date(timeIntervalSince1970: 1_800_000_000), monotonic: 500)
        let early = arrival.eventMoment(stampedAt: arrival.wall.addingTimeInterval(-0.300))
        let late = arrival.advanced(by: 0.010).eventMoment(stampedAt: arrival.wall.addingTimeInterval(-0.200))
        XCTAssertEqual(early.monotonic, 499.7, accuracy: 1e-6)
        XCTAssertEqual(early.wall.timeIntervalSince(arrival.wall), -0.3, accuracy: 1e-6)
        XCTAssertLessThan(early.monotonic, late.monotonic)
    }

    func testEventMomentStampFromBeforeAForwardJumpMovesAtMostMaxTransit() {
        let arrival = Moment(wall: Date(timeIntervalSince1970: 1_800_000_000), monotonic: 500)
        // Stamped, then the clock was set 5 h forward, then it arrived.
        let moment = arrival.eventMoment(stampedAt: arrival.wall.addingTimeInterval(-5 * hours))
        XCTAssertEqual(arrival.since(moment), Moment.maxEventTransit, accuracy: 1e-9)
        XCTAssertEqual(arrival.eventMoment(stampedAt: arrival.wall.addingTimeInterval(-5 * hours), maxTransit: 0), arrival)
    }

    func testEventMomentStampFromTheFutureNeverMovesForward() {
        let arrival = Moment(wall: Date(timeIntervalSince1970: 1_800_000_000), monotonic: 500)
        // Stamped, then the clock was set 9 h back, then it arrived.
        XCTAssertEqual(arrival.eventMoment(stampedAt: arrival.wall.addingTimeInterval(9 * hours)), arrival)
        XCTAssertEqual(arrival.eventMoment(stampedAt: .distantFuture), arrival)
        XCTAssertEqual(arrival.eventMoment(stampedAt: .distantPast).monotonic, 500 - Moment.maxEventTransit)
    }

    func testWallOnlyMomentsMeasureWithTheWallClock() {
        let a = Moment.wallOnly(Date(timeIntervalSince1970: 1_800_000_000))
        let b = Moment.wallOnly(Date(timeIntervalSince1970: 1_800_000_090))
        XCTAssertEqual(b.since(a), 90, accuracy: 1e-9)
    }

    // MARK: AppClock

    func testSystemClockIsMonotonicAndReadsTheWallClock() {
        let a = AppClock.system.now()
        let b = AppClock.system.now()
        XCTAssertGreaterThanOrEqual(b.monotonic, a.monotonic)
        XCTAssertLessThan(abs(a.wall.timeIntervalSinceNow), 5)
        XCTAssertGreaterThan(a.monotonic, 0)
    }

    func testTestClockSetsTheWallClockAlone() {
        let clock = TestClock()
        let start = clock.now
        clock.advance(10)
        clock.setWall(by: -3 * hours)
        let now = clock.appClock.now()
        XCTAssertEqual(now.since(start), 10, accuracy: 1e-9)
        XCTAssertEqual(now.wall.timeIntervalSince(start.wall), 10 - 3 * hours, accuracy: 1e-6)
    }

    // MARK: WallClockJumpDetector

    func testDetectorIgnoresTicksAndSmallDriftButReportsJumps() {
        let clock = TestClock()
        var detector = WallClockJumpDetector(threshold: 2)
        XCTAssertNil(detector.check(clock.now), "the first reading sets the baseline")
        XCTAssertNil(detector.check(clock.advance(60)))
        XCTAssertNil(detector.check(clock.setWall(by: 0.5)), "drift below the threshold")
        XCTAssertTrue(detector.isSettled(at: clock.now))

        // The Mac's clock is set 11 h back (22:xx → 07:44).
        clock.advance(1)
        let jump = detector.check(clock.setWall(by: -11 * hours))
        XCTAssertEqual(jump ?? 0, -11 * hours + 0.5, accuracy: 1e-6, "including the drift since the baseline")
        XCTAssertNil(detector.check(clock.advance(1)), "reported once; the jump is the new baseline")
        XCTAssertFalse(detector.isSettled(at: clock.now), "bridge stamps are not trusted right after a jump")
        XCTAssertTrue(detector.isSettled(at: clock.advance(10)))

        // ... and forward again.
        let forward = detector.check(clock.setWall(by: 12 * hours))
        XCTAssertEqual(forward ?? 0, 12 * hours, accuracy: 1e-6)
    }

    func testDetectorReportsAccumulatedDriftOnceItExceedsTheThreshold() {
        let clock = TestClock()
        var detector = WallClockJumpDetector(threshold: 2)
        _ = detector.check(clock.now)
        XCTAssertNil(detector.check(clock.setWall(by: 1.5)))
        let reported = detector.check(clock.setWall(by: 1.0))
        XCTAssertEqual(reported ?? 0, 2.5, accuracy: 1e-6, "measured from the baseline the dates are based on")
    }
}
