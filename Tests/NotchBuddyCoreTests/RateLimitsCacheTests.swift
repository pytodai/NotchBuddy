import XCTest
@testable import NotchBuddyCore

final class RateLimitsCacheTests: XCTestCase {
    private let hour: TimeInterval = 3600
    private let freshFor: TimeInterval = 15 * 60

    private func cache(capturedAt: Date) -> RateLimitsCache {
        RateLimitsCache(fiveHour: .init(usedPercentage: 42, resetsAt: nil), sevenDay: nil, capturedAt: capturedAt)
    }

    // MARK: Parsing and storage

    func testParsesStatusLineRateLimits() throws {
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":1759150000},"seven_day":{"used_percentage":3}}}
        """#.utf8))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let parsed = try XCTUnwrap(RateLimitsCache.fromStatusLine(payload, now: now))
        XCTAssertEqual(parsed.fiveHour, .init(usedPercentage: 12.5, resetsAt: Date(timeIntervalSince1970: 1_759_150_000)))
        XCTAssertEqual(parsed.sevenDay, .init(usedPercentage: 3, resetsAt: nil))
        XCTAssertEqual(parsed.capturedAt, now)
        XCTAssertNil(RateLimitsCache.fromStatusLine(try JSONDecoder().decode(JSONValue.self, from: Data(#"{"model":{}}"#.utf8))))
    }

    func testWriteReadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nb-ratelimits-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rate-limits.json")
        XCTAssertNil(RateLimitsCache.read(from: url))
        let original = cache(capturedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try original.write(to: url)
        XCTAssertEqual(RateLimitsCache.read(from: url), original)
    }

    // MARK: Freshness across wall-clock jumps

    func testAgeFollowsTheWallClockWithoutJumps() {
        let clock = TestClock()
        var freshness = RateLimitsFreshness()
        let snapshot = cache(capturedAt: clock.now.wall.addingTimeInterval(-120))
        XCTAssertEqual(freshness.observe(snapshot, now: clock.now) ?? -1, 120, accuracy: 1e-6)
        clock.advance(60)
        XCTAssertEqual(freshness.observe(snapshot, now: clock.now) ?? -1, 180, accuracy: 1e-6)
    }

    func testCacheFromTheFutureOnFirstReadIsNeverFresh() {
        let clock = TestClock()
        var freshness = RateLimitsFreshness()
        // Written at 22:xx, then the clock was set back to 07:44 before the app read it.
        let snapshot = cache(capturedAt: clock.now.wall.addingTimeInterval(14 * hour))
        XCTAssertNil(freshness.observe(snapshot, now: clock.now))
        for _ in 0..<3 {
            clock.advance(15 * 60)
            XCTAssertNil(freshness.observe(snapshot, now: clock.now), "unknown age stays unknown: never fresh")
        }
        // A small skew between the bridge and the app is not "the future".
        let skewed = cache(capturedAt: clock.now.wall.addingTimeInterval(20))
        var other = RateLimitsFreshness()
        XCTAssertEqual(other.observe(skewed, now: clock.now), 0)
    }

    func testCacheWrittenJustBeforeTheClockWasSetBackAgesOnTheMonotonicClock() {
        let clock = TestClock()
        var freshness = RateLimitsFreshness()
        XCTAssertNil(freshness.observe(nil, now: clock.now), "no file yet")
        clock.advance(30)
        let snapshot = cache(capturedAt: clock.now.wall)
        clock.advance(10)
        clock.setWall(by: -11 * hour)
        clock.advance(20)
        // Appeared since the previous read (60 s ago): no older than that, though its stamp is 11 h ahead.
        let first = freshness.observe(snapshot, now: clock.now)
        XCTAssertEqual(first ?? -1, 0, accuracy: 1e-6)
        clock.advance(freshFor - 1)
        XCTAssertLessThanOrEqual(freshness.observe(snapshot, now: clock.now) ?? .infinity, freshFor)
        clock.advance(2)
        XCTAssertGreaterThan(freshness.observe(snapshot, now: clock.now) ?? .infinity, freshFor,
                             "stale after 15 real minutes, not when the wall clock catches up 11 h later")
    }

    func testCacheSeenBeforeAForwardJumpDoesNotAgeByTheJump() {
        let clock = TestClock()
        var freshness = RateLimitsFreshness()
        let snapshot = cache(capturedAt: clock.now.wall.addingTimeInterval(-60))
        XCTAssertEqual(freshness.observe(snapshot, now: clock.now) ?? -1, 60, accuracy: 1e-6)
        clock.advance(60)
        clock.setWall(by: 5 * hour)
        XCTAssertEqual(freshness.observe(snapshot, now: clock.now) ?? -1, 120, accuracy: 1e-6)
    }

    func testNewSnapshotAfterAForwardJumpIsBoundedByTheReadInterval() {
        let clock = TestClock()
        var freshness = RateLimitsFreshness()
        let old = cache(capturedAt: clock.now.wall.addingTimeInterval(-60))
        _ = freshness.observe(old, now: clock.now)
        clock.advance(10)
        let written = cache(capturedAt: clock.now.wall)   // stamped before the jump
        clock.setWall(by: 5 * hour)
        clock.advance(50)
        XCTAssertEqual(freshness.observe(written, now: clock.now) ?? -1, 60, accuracy: 1e-6,
                       "at most the 60 s since the previous read, not 5 h")
    }

    func testMissingFileForgetsTheSnapshot() {
        let clock = TestClock()
        var freshness = RateLimitsFreshness()
        let snapshot = cache(capturedAt: clock.now.wall)
        XCTAssertEqual(freshness.observe(snapshot, now: clock.now), 0)
        clock.advance(60)
        XCTAssertNil(freshness.observe(nil, now: clock.now))
        clock.advance(60)
        XCTAssertEqual(freshness.observe(snapshot, now: clock.now) ?? -1, 60, accuracy: 1e-6,
                       "reappeared: bounded by the previous read")
    }
}
