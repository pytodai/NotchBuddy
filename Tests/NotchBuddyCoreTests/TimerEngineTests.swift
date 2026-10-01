import XCTest
@testable import NotchBuddyCore

final class TimerEngineTests: XCTestCase {
    private func moment(_ monotonic: TimeInterval, wall: TimeInterval? = nil) -> Moment {
        Moment(wall: Date(timeIntervalSince1970: 1_800_000_000 + (wall ?? monotonic)), monotonic: monotonic)
    }

    // MARK: Countdown

    func testStartCountsDownOnTheMonotonicClock() throws {
        var engine = TimerEngine()
        let t = try XCTUnwrap(engine.start(duration: 300, label: "Перерыв", at: moment(1000)))
        XCTAssertEqual(t.remaining(at: moment(1000)), 300)
        XCTAssertEqual(t.remaining(at: moment(1060)), 240)
        XCTAssertEqual(t.fractionRemaining(at: moment(1150)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(engine.nextDeadline, 1300)
    }

    func testSettingTheWallClockDoesNotMoveATimer() throws {
        var engine = TimerEngine()
        let t = try XCTUnwrap(engine.start(duration: 60, label: "Минутка", at: moment(1000)))
        // The wall clock jumps an hour ahead, 10 real seconds later.
        let jumped = moment(1010, wall: 1010 + 3600)
        XCTAssertEqual(t.remaining(at: jumped), 50)
        XCTAssertTrue(engine.collectFinished(at: jumped).isEmpty)
    }

    func testDisplayRoundsUpSoTheFirstAndLastSecondsRead5_00And0_01() throws {
        var engine = TimerEngine()
        let t = try XCTUnwrap(engine.start(duration: 300, label: "", at: moment(0)))
        XCTAssertEqual(TimerFormat.clock(t.displaySeconds(at: moment(0))), "5:00")
        XCTAssertEqual(TimerFormat.clock(t.displaySeconds(at: moment(0.4))), "5:00")
        XCTAssertEqual(TimerFormat.clock(t.displaySeconds(at: moment(1))), "4:59")
        XCTAssertEqual(TimerFormat.clock(t.displaySeconds(at: moment(299.2))), "0:01")
        XCTAssertEqual(TimerFormat.clock(t.displaySeconds(at: moment(300))), "0:00")
        XCTAssertEqual(TimerFormat.clock(3723), "1:02:03")
    }

    func testNextTickLandsWhenTheShownSecondChanges() throws {
        var engine = TimerEngine()
        engine.start(duration: 10, label: "", at: moment(0))
        XCTAssertEqual(try XCTUnwrap(engine.nextTickDelay(at: moment(0))), 1, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(engine.nextTickDelay(at: moment(0.3))), 0.7, accuracy: 1e-6)
        // A second timer out of phase ticks in between.
        engine.start(duration: 10.5, label: "", at: moment(0.3))
        XCTAssertEqual(try XCTUnwrap(engine.nextTickDelay(at: moment(0.4))), 0.6, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(engine.nextTickDelay(at: moment(0.95))), 0.05, accuracy: 1e-6)
    }

    func testDurationsAreClampedAndCountLimited() {
        var engine = TimerEngine()
        XCTAssertNil(engine.start(duration: .nan, label: "", at: moment(0)))
        XCTAssertEqual(engine.start(duration: 0, label: "", at: moment(0))?.duration, 1)
        XCTAssertEqual(engine.start(duration: 1e9, label: "", at: moment(0))?.duration, TimerEngine.maxDuration)
        for _ in 0..<10 { engine.start(duration: 60, label: "", at: moment(0)) }
        XCTAssertEqual(engine.timers.count, TimerEngine.maxTimers)
        XCTAssertNil(engine.start(duration: 60, label: "", at: moment(0)))
    }

    // MARK: Pause, resume, extend

    func testPauseFreezesAndResumeContinuesFromThere() throws {
        var engine = TimerEngine()
        let id = try XCTUnwrap(engine.start(duration: 120, label: "", at: moment(0))).id
        XCTAssertTrue(engine.pause(id, at: moment(30)))
        XCTAssertFalse(engine.pause(id, at: moment(31)), "already paused")
        XCTAssertEqual(engine.timer(id)?.remaining(at: moment(500)), 90)
        XCTAssertNil(engine.nextDeadline)
        XCTAssertNil(engine.nextTickDelay(at: moment(500)))
        XCTAssertTrue(engine.collectFinished(at: moment(5000)).isEmpty, "a paused timer never finishes")
        XCTAssertTrue(engine.resume(id, at: moment(600)))
        XCTAssertEqual(engine.nextDeadline, 690)
        XCTAssertTrue(engine.toggle(id, at: moment(650)))
        XCTAssertEqual(engine.timer(id)?.state, .paused(remaining: 40))
    }

    func testPausingAtTheVeryEndLetsItFinish() throws {
        var engine = TimerEngine()
        let id = try XCTUnwrap(engine.start(duration: 5, label: "", at: moment(0))).id
        XCTAssertFalse(engine.pause(id, at: moment(5.2)))
        XCTAssertEqual(engine.collectFinished(at: moment(5.2)).map(\.id), [id])
    }

    func testExtendAddsToRunningAndPausedTimersAndGrowsTheWhole() throws {
        var engine = TimerEngine()
        let a = try XCTUnwrap(engine.start(duration: 60, label: "", at: moment(0))).id
        XCTAssertTrue(engine.extend(a, by: 60, at: moment(50)))
        XCTAssertEqual(engine.timer(a)?.remaining(at: moment(50)), 70)
        XCTAssertEqual(engine.timer(a)?.duration, 120)
        let b = try XCTUnwrap(engine.start(duration: 30, label: "", at: moment(0))).id
        engine.pause(b, at: moment(10))
        XCTAssertTrue(engine.extend(b, by: 60, at: moment(20)))
        XCTAssertEqual(engine.timer(b)?.state, .paused(remaining: 80))
        XCTAssertFalse(engine.extend(b, by: -5, at: moment(20)))
        XCTAssertFalse(engine.extend(UUID(), by: 60, at: moment(20)))
    }

    func testExtendNeverPassesTheMaximum() throws {
        var engine = TimerEngine()
        let id = try XCTUnwrap(engine.start(duration: TimerEngine.maxDuration - 30, label: "", at: moment(0))).id
        XCTAssertTrue(engine.extend(id, by: 3600, at: moment(0)))
        XCTAssertEqual(try XCTUnwrap(engine.timer(id)).remaining(at: moment(0)), TimerEngine.maxDuration, accuracy: 1e-6)
        XCTAssertFalse(engine.extend(id, by: 60, at: moment(0)))
    }

    func testRestartAndCancel() throws {
        var engine = TimerEngine()
        let id = try XCTUnwrap(engine.start(duration: 60, label: "", at: moment(0))).id
        engine.pause(id, at: moment(40))
        XCTAssertTrue(engine.restart(id, at: moment(100)))
        XCTAssertEqual(engine.timer(id)?.state, .running(deadline: 160))
        XCTAssertEqual(engine.cancel(id)?.id, id)
        XCTAssertNil(engine.cancel(id))
        XCTAssertTrue(engine.isEmpty)
    }

    // MARK: Finishing

    func testCollectFinishedReportsDueTimersEarliestFirstWithTheirRealEndTime() throws {
        var engine = TimerEngine()
        let late = try XCTUnwrap(engine.start(duration: 20, label: "B", at: moment(0))).id
        let early = try XCTUnwrap(engine.start(duration: 10, label: "A", at: moment(0))).id
        let later = try XCTUnwrap(engine.start(duration: 100, label: "C", at: moment(0))).id
        XCTAssertTrue(engine.collectFinished(at: moment(9.99)).isEmpty)
        // The Mac slept from 5 s to 30 s.
        let finished = engine.collectFinished(at: moment(30))
        XCTAssertEqual(finished.map(\.id), [early, late])
        XCTAssertEqual(finished.map(\.label), ["A", "B"])
        XCTAssertEqual(finished[0].finishedAt.monotonic, 10, accuracy: 1e-9)
        XCTAssertEqual(finished[0].lateness, 20, accuracy: 1e-9)
        XCTAssertEqual(engine.timers.map(\.id), [later])
        XCTAssertTrue(engine.collectFinished(at: moment(30)).isEmpty, "reported once")
    }

    func testOrderingPutsRunningSoonestFirstThenPaused() throws {
        var engine = TimerEngine()
        let paused = try XCTUnwrap(engine.start(duration: 5, label: "", at: moment(0))).id
        engine.pause(paused, at: moment(1))
        let long = try XCTUnwrap(engine.start(duration: 600, label: "", at: moment(0))).id
        let short = try XCTUnwrap(engine.start(duration: 60, label: "", at: moment(0))).id
        XCTAssertEqual(engine.ordered(at: moment(2)).map(\.id), [short, long, paused])
        XCTAssertEqual(engine.primary(at: moment(2))?.id, short)
    }

    // MARK: Persistence

    func testSavedTimersSurviveARelaunchThroughTheWallClock() throws {
        var engine = TimerEngine()
        let running = try XCTUnwrap(engine.start(duration: 600, label: "Помодоро", at: moment(100))).id
        let paused = try XCTUnwrap(engine.start(duration: 300, label: "Чай", at: moment(100))).id
        engine.pause(paused, at: moment(160))
        let saved = engine.saved(at: moment(200))
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(TimerEngine.Saved.self, from: data)
        // Relaunch 50 wall seconds later on a fresh monotonic clock (a reboot).
        let later = Moment(wall: moment(200).wall.addingTimeInterval(50), monotonic: 7)
        let restored = TimerEngine(saved: decoded, at: later)
        XCTAssertEqual(try XCTUnwrap(restored.timer(running)).remaining(at: later), 450, accuracy: 1e-6)
        XCTAssertEqual(restored.timer(paused)?.state, .paused(remaining: 240))
        XCTAssertEqual(restored.timer(running)?.label, "Помодоро")
    }

    func testATimerThatEndedWhileTheAppWasGoneIsDueAtOnce() throws {
        var engine = TimerEngine()
        let id = try XCTUnwrap(engine.start(duration: 60, label: "", at: moment(0))).id
        let saved = engine.saved(at: moment(10))
        let later = Moment(wall: moment(10).wall.addingTimeInterval(3600), monotonic: 5)
        var restored = TimerEngine(saved: saved, at: later)
        let finished = restored.collectFinished(at: later)
        XCTAssertEqual(finished.map(\.id), [id])
        XCTAssertEqual(finished[0].lateness, 3550, accuracy: 1e-6)
    }

    func testRestoreDropsNonsense() {
        let saved = TimerEngine.Saved(timers: [
            .init(id: UUID(), label: "", duration: .nan, startedAt: Date(), endsAt: Date(), remaining: nil),
            .init(id: UUID(), label: "", duration: 60, startedAt: Date(), endsAt: nil, remaining: nil),
            .init(id: UUID(), label: "", duration: 60, startedAt: Date(), endsAt: nil, remaining: -3),
            .init(id: UUID(), label: "", duration: 60, startedAt: Date(), endsAt: Date().addingTimeInterval(1e9), remaining: nil),
        ])
        XCTAssertTrue(TimerEngine(saved: saved, at: moment(0)).isEmpty)
    }

    // MARK: Format

    func testLengthsReadInRussian() {
        XCTAssertEqual(TimerFormat.length(30), "30\u{00A0}с")
        XCTAssertEqual(TimerFormat.length(60), "1\u{00A0}мин")
        XCTAssertEqual(TimerFormat.length(90), "1\u{00A0}мин 30\u{00A0}с")
        XCTAssertEqual(TimerFormat.length(1500), "25\u{00A0}мин")
        XCTAssertEqual(TimerFormat.length(3600), "1\u{00A0}ч")
        XCTAssertEqual(TimerFormat.length(3900), "1\u{00A0}ч 5\u{00A0}мин")
        XCTAssertEqual(TimerFormat.length(-4), "0\u{00A0}с")
    }

    func testCustomStepsAreFineForShortTimesAndCoarseForLongOnes() {
        XCTAssertEqual(TimerFormat.step(from: 30, up: true), 35)
        XCTAssertEqual(TimerFormat.step(from: 60, up: true), 75)
        XCTAssertEqual(TimerFormat.step(from: 300, up: true), 360)
        XCTAssertEqual(TimerFormat.step(from: 420, up: false), 360)
        XCTAssertEqual(TimerFormat.step(from: 300, up: false), 285)
        XCTAssertEqual(TimerFormat.step(from: 61, up: false), 60)
        XCTAssertEqual(TimerFormat.step(from: 5, up: false), 5, "never below 5 s")
        XCTAssertEqual(TimerFormat.step(from: TimerEngine.maxDuration, up: true), TimerEngine.maxDuration)
        XCTAssertEqual(TimerFormat.stepMinutes(from: 90, by: -5), 5)
        XCTAssertEqual(TimerFormat.stepMinutes(from: 90, by: 5), 390)
    }
}
