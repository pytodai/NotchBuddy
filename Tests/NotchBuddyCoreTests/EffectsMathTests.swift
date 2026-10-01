import XCTest
@testable import NotchBuddyCore

final class EffectsMathTests: XCTestCase {
    // MARK: Random

    func testRandomIsDeterministicPerSeed() {
        var a = FXRandom(seed: 42), b = FXRandom(seed: 42), c = FXRandom(seed: 43)
        let xs = (0..<8).map { _ in a.next() }
        XCTAssertEqual(xs, (0..<8).map { _ in b.next() })
        XCTAssertNotEqual(xs, (0..<8).map { _ in c.next() })
    }

    func testRandomUnitStaysInRange() {
        var r = FXRandom(seed: 7)
        for _ in 0..<10_000 {
            let u = r.unit()
            XCTAssertGreaterThanOrEqual(u, 0)
            XCTAssertLessThan(u, 1)
            let v = r.range(-3, 5)
            XCTAssertGreaterThanOrEqual(v, -3)
            XCTAssertLessThan(v, 5)
        }
    }

    // MARK: Easing

    func testEasingEndpoints() {
        for f in [FXEase.outCubic, FXEase.outQuart, FXEase.inCubic, FXEase.inOutCubic, FXEase.inOutSine] {
            XCTAssertEqual(f(0), 0, accuracy: 1e-9)
            XCTAssertEqual(f(1), 1, accuracy: 1e-9)
            XCTAssertEqual(f(-1), 0, accuracy: 1e-9, "clamped below")
            XCTAssertEqual(f(2), 1, accuracy: 1e-9, "clamped above")
        }
        XCTAssertEqual(FXEase.outBack(1), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(FXEase.samples(40) { FXEase.outBack($0) }.max()!, 1, "outBack overshoots")
    }

    func testFlashEnvelopePeaksThenReturnsToZero() {
        XCTAssertEqual(FXEase.flash(0, rise: 0.2), 0)
        XCTAssertEqual(FXEase.flash(0.2, rise: 0.2, peak: 0.8), 0.8, accuracy: 1e-9)
        XCTAssertEqual(FXEase.flash(1, rise: 0.2), 0)
        XCTAssertLessThan(FXEase.flash(0.9, rise: 0.2), FXEase.flash(0.5, rise: 0.2))
    }

    func testSpringSettlesAtOne() {
        XCTAssertEqual(FXEase.spring(0, response: 0.4, damping: 0.8), 0)
        XCTAssertEqual(FXEase.spring(3, response: 0.4, damping: 0.8), 1, accuracy: 1e-4)
        XCTAssertEqual(FXEase.spring(3, response: 0.4, damping: 1.0), 1, accuracy: 1e-4)
        let under = FXEase.samples(200) { FXEase.spring($0, response: 0.4, damping: 0.5) }.max()!
        XCTAssertGreaterThan(under, 1, "an underdamped spring overshoots")
    }

    // MARK: Shake

    func testShakeStartsAndEndsAtRestAndDecays() {
        let shake = DampedShake.error
        XCTAssertEqual(shake.offset(at: 0), 0)
        XCTAssertEqual(shake.offset(at: shake.duration), 0)
        XCTAssertEqual(shake.offset(at: shake.duration + 1), 0)
        let early = (1...20).map { abs(shake.offset(at: Double($0) * 0.005)) }.max()!
        let late = (60...90).map { abs(shake.offset(at: Double($0) * 0.005)) }.max()!
        XCTAssertGreaterThan(early, late * 2)
        XCTAssertLessThanOrEqual(early, shake.amplitude)
    }

    // MARK: Coalescing

    func testFirstFinishPlaysInFull() {
        var c = CelebrationCoalescer()
        XCTAssertEqual(c.register(at: 10), .play(intensity: 1))
    }

    func testSimultaneousFinishesRaiseIntensityCappedAtThree() {
        var c = CelebrationCoalescer()
        XCTAssertEqual(c.register(count: 2, at: 10), .play(intensity: 2))
        var d = CelebrationCoalescer()
        XCTAssertEqual(d.register(count: 7, at: 10), .play(intensity: 3))
    }

    func testQuickSuccessionBecomesEncoresThenIsAbsorbed() {
        var c = CelebrationCoalescer(quiet: 1.6, encoreGap: 0.35, maxEncores: 2)
        XCTAssertEqual(c.register(at: 0), .play(intensity: 1))
        XCTAssertEqual(c.register(at: 0.1), .absorb, "too soon after the start")
        XCTAssertEqual(c.register(at: 0.5), .encore(total: 3))
        XCTAssertEqual(c.register(at: 0.9), .encore(total: 4))
        XCTAssertEqual(c.register(at: 1.3), .absorb, "encores are capped")
        // A stream of finishes keeps the episode open (quiet counts from the last finish).
        XCTAssertEqual(c.register(at: 2.5), .absorb)
        XCTAssertEqual(c.register(at: 4.2), .play(intensity: 1), "after a quiet pause it plays in full again")
    }

    // MARK: Number roll

    func testColumnsAlignOnTheRight() {
        let cols = NumberRollPlan.columns(from: "9", to: "10")
        XCTAssertEqual(cols.count, 2)
        XCTAssertEqual(cols[0].old, nil)
        XCTAssertEqual(cols[0].new, "1")
        XCTAssertEqual(cols[0].index, 1)
        XCTAssertEqual(cols[1].old, "9")
        XCTAssertEqual(cols[1].new, "0")
        XCTAssertEqual(cols[1].index, 0)
        XCTAssertTrue(cols.allSatisfy(\.changes))
    }

    func testClockKeepsSeparatorsInPlace() {
        let cols = NumberRollPlan.columns(from: "2:59", to: "3:00")
        XCTAssertEqual(cols.map(\.changes), [true, false, true, true])
        XCTAssertFalse(cols[1].isDigit)
        XCTAssertTrue(cols[0].isDigit)
    }

    func testDirection() {
        XCTAssertEqual(NumberRollPlan.direction(from: "9", to: "10"), .up)
        XCTAssertEqual(NumberRollPlan.direction(from: "73 %", to: "71 %"), .down)
        XCTAssertEqual(NumberRollPlan.direction(from: "2:59", to: "3:00"), .up)
        XCTAssertEqual(NumberRollPlan.direction(from: "100", to: "99"), .down)
    }

    func testColumnProgressStaggersFromTheRight() {
        let first = NumberRollPlan.columnProgress(0.3, index: 0, count: 3)
        let second = NumberRollPlan.columnProgress(0.3, index: 1, count: 3)
        XCTAssertGreaterThan(first, second)
        for i in 0..<3 {
            XCTAssertEqual(NumberRollPlan.columnProgress(0, index: i, count: 3), 0)
            XCTAssertEqual(NumberRollPlan.columnProgress(1, index: i, count: 3), 1, accuracy: 1e-9)
        }
    }
}
