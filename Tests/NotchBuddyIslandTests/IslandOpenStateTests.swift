import XCTest
@testable import NotchBuddy

/// The open island's rules as pure logic (`IslandOpenState`). Times are monotonic seconds; a poll tick is a
/// `pointer(inside:)` sample without an event.
final class IslandOpenStateTests: XCTestCase {
    private let delay = IslandOpenState.leaveDelay

    /// A click opens, but does not pin: once the pointer is off the island for the delay, it closes.
    func testClickOpensButNeverPins() {
        var open = IslandOpenState()
        open.open(.click, pointerInside: true, now: 10)
        XCTAssertTrue(open.isOpen)
        XCTAssertFalse(open.pinned)
        XCTAssertTrue(open.watchesLeave)
        open.pointer(inside: false, now: 11)
        XCTAssertFalse(open.shouldClose(now: 11 + delay - 0.05))
        XCTAssertTrue(open.shouldClose(now: 11 + delay))
    }

    /// Hover opens the same way.
    func testHoverOpenClosesOnLeave() {
        var open = IslandOpenState()
        open.open(.hover, pointerInside: true, now: 0)
        open.pointer(inside: false, now: 2)
        XCTAssertTrue(open.shouldClose(now: 2 + delay))
        open.close()
        XCTAssertFalse(open.isOpen)
        XCTAssertNil(open.outsideSince)
        XCTAssertFalse(open.shouldClose(now: 100), "closed: nothing left to close")
    }

    /// Only 📌 keeps it open after the pointer leaves; unpinned on the island, it closes once the pointer leaves;
    /// unpinned off it, at once.
    func testPinKeepsItOpen() {
        var open = IslandOpenState()
        open.open(.click, pointerInside: true, now: 0)
        open.pin()
        XCTAssertTrue(open.pinned)
        XCTAssertFalse(open.watchesLeave, "no poll while pinned")
        open.pointer(inside: false, now: 1)
        XCTAssertFalse(open.shouldClose(now: 60))
        open.pointer(inside: true, now: 61)
        XCTAssertFalse(open.unpin(pointerInside: true, now: 61))
        XCTAssertTrue(open.isOpen)
        open.pointer(inside: false, now: 62)
        XCTAssertTrue(open.shouldClose(now: 62 + delay))

        var away = IslandOpenState()
        away.open(.click, pointerInside: true, now: 0)
        away.pin()
        away.pointer(inside: false, now: 1)
        XCTAssertTrue(away.unpin(pointerInside: false, now: 2), "unpinned off the island: closes at once")
        XCTAssertFalse(away.isOpen)
    }

    /// Settings → «Закреплять открытый список»: whatever opens it pins it.
    func testPinOnOpenSettingIsAnExplicitOptIn() {
        for opener in [IslandOpenState.Opener.hover, .click, .remote] {
            var open = IslandOpenState()
            open.open(opener, pointerInside: opener != .remote, pin: true, now: 0)
            XCTAssertTrue(open.pinned, "\(opener)")
            open.pointer(inside: false, now: 1)
            XCTAssertFalse(open.shouldClose(now: 30), "\(opener)")
        }
    }

    /// A leave no event reported (a fast exit, another display, sleep, a Space switch): the poll's first sample off
    /// the island starts the clock, and it closes within the delay after that (the poll runs at 10 Hz).
    func testMissedExitIsCaughtByThePoll() {
        var open = IslandOpenState()
        open.open(.hover, pointerInside: true, now: 0)
        // Events stopped while the pointer was on the island; the poll sees it off the island from t = 5.
        var closedAt: Double?
        var t = 5.0
        while t < 7, closedAt == nil {
            open.pointer(inside: false, now: t)
            if open.shouldClose(now: t) { closedAt = t }
            t += 0.1
        }
        XCTAssertNotNil(closedAt)
        XCTAssertGreaterThanOrEqual(closedAt ?? 0, 5 + delay - 0.001)
        XCTAssertLessThanOrEqual(closedAt ?? 99, 5 + 0.45 + 0.001, "closes within 0.35–0.45 s of the leave")
    }

    /// Repeated samples off the island do not restart the clock; a sample back on it does.
    func testBriefExitDoesNotClose() {
        var open = IslandOpenState()
        open.open(.hover, pointerInside: true, now: 0)
        open.pointer(inside: false, now: 1.0)
        open.pointer(inside: false, now: 1.1)
        XCTAssertEqual(open.outsideSince, 1.0)
        open.pointer(inside: true, now: 1.2)
        XCTAssertFalse(open.shouldClose(now: 1.5))
        open.pointer(inside: false, now: 1.6)
        XCTAssertFalse(open.shouldClose(now: 1.6 + delay - 0.05))
        XCTAssertTrue(open.shouldClose(now: 1.6 + delay))
    }

    /// A permission card, a drag or an open menu holds the island: the leave counts from the moment it lets go.
    func testHeldPostponesTheLeave() {
        var open = IslandOpenState()
        open.open(.hover, pointerInside: true, now: 0)
        for t in stride(from: 1.0, through: 3.0, by: 0.1) {
            open.pointer(inside: false, held: true, now: t)
            XCTAssertFalse(open.shouldClose(now: t, held: true))
        }
        // Let go at 3.1: not a stale 2-second-old leave, a fresh one.
        open.pointer(inside: false, held: false, now: 3.1)
        XCTAssertFalse(open.shouldClose(now: 3.2))
        XCTAssertTrue(open.shouldClose(now: 3.1 + delay))
    }

    /// Opened from afar (the hotkey, «Настройки…» in the menu bar), the pointer is elsewhere: it waits for the pointer
    /// to come and go, a click elsewhere, another app coming to the front — or `remoteVisitWindow` (4 s) without a visit.
    func testRemoteOpenWaitsForTheVisit() {
        let window = IslandOpenState.remoteVisitWindow
        var open = IslandOpenState()
        open.open(.remote, pointerInside: false, now: 0)
        for t in stride(from: 0.0, to: window - 0.01, by: 0.5) {
            open.pointer(inside: false, now: t)
            XCTAssertFalse(open.shouldClose(now: t), "waiting for the visit at \(t)")
        }
        XCTAssertTrue(open.shouldClose(now: window), "never visited: it closes on its own")
        XCTAssertFalse(open.shouldClose(now: window, held: true), "a hold (a menu, a drag) still postpones it")

        var visiting = IslandOpenState()
        visiting.open(.remote, pointerInside: false, now: 0)
        visiting.pointer(inside: true, now: 3)
        XCTAssertTrue(visiting.visited)
        XCTAssertFalse(visiting.shouldClose(now: 30), "the pointer is on it")
        visiting.pointer(inside: false, now: 31)
        XCTAssertFalse(visiting.shouldClose(now: 31.1))
        XCTAssertTrue(visiting.shouldClose(now: 31 + delay))

        var clicked = IslandOpenState()
        clicked.open(.remote, pointerInside: false, now: 0)
        XCTAssertTrue(clicked.clickedElsewhere())
        XCTAssertFalse(clicked.isOpen)

        var switched = IslandOpenState()
        switched.open(.remote, pointerInside: false, now: 0)
        XCTAssertTrue(switched.frontmostAppChanged(), "⌘Tab to another app closes it")
        XCTAssertFalse(switched.isOpen)

        var pinned = IslandOpenState()
        pinned.open(.remote, pointerInside: false, pin: true, now: 0)
        XCTAssertFalse(pinned.shouldClose(now: 60), "pinned stays")
        XCTAssertFalse(pinned.frontmostAppChanged())

        var hover = IslandOpenState()
        hover.open(.hover, pointerInside: true, now: 0)
        XCTAssertFalse(hover.frontmostAppChanged(), "the pointer is on it: another app's activation leaves it")
        XCTAssertFalse(hover.shouldClose(now: 10))
    }

    /// A click elsewhere closes only an unvisited remote open (a hover- or click-opened island closes by itself once
    /// the pointer is off it; a pinned one stays).
    func testClickElsewhereLeavesOthersAlone() {
        var hover = IslandOpenState()
        hover.open(.hover, pointerInside: true, now: 0)
        XCTAssertFalse(hover.clickedElsewhere())
        XCTAssertTrue(hover.isOpen)

        var pinned = IslandOpenState()
        pinned.open(.remote, pointerInside: false, now: 0)
        pinned.pin()
        XCTAssertFalse(pinned.clickedElsewhere())
        XCTAssertTrue(pinned.isOpen)

        var visited = IslandOpenState()
        visited.open(.remote, pointerInside: false, now: 0)
        visited.pointer(inside: true, now: 1)
        XCTAssertFalse(visited.clickedElsewhere())
    }

    /// Opening again while open (the settings page from the list, a tab click) keeps the visit and the running leave;
    /// opening after a close starts fresh: no stale leave closes the new island at once.
    func testReopeningNeverInheritsAStaleLeave() {
        var open = IslandOpenState()
        open.open(.hover, pointerInside: true, now: 0)
        open.pointer(inside: false, now: 1)
        open.open(.click, pointerInside: false, now: 1.2)
        XCTAssertEqual(open.outsideSince, 1, "the leave keeps counting")
        XCTAssertTrue(open.visited)
        XCTAssertTrue(open.shouldClose(now: 1 + delay))

        open.close()
        open.open(.hover, pointerInside: true, now: 50)
        XCTAssertNil(open.outsideSince)
        XCTAssertFalse(open.shouldClose(now: 50.5))
        XCTAssertFalse(open.pinned, "a close unpins")
    }

    /// Pointer samples while closed leave nothing behind (a grace or dwell elsewhere cannot revive an old leave).
    func testSamplesWhileClosedAreIgnored() {
        var open = IslandOpenState()
        open.pointer(inside: false, now: 1)
        XCTAssertNil(open.outsideSince)
        XCTAssertFalse(open.watchesLeave)
        open.pin()
        XCTAssertFalse(open.pinned, "nothing to pin while closed")
    }

    /// The settings page or a widget tab is just another open mode: the same rules (no pin from opening it).
    func testSettingsPageClosesOnLeaveUnlessPinned() {
        // ⚙️ in the open list: the island stays open by the pointer, the page comes in, the pointer leaves.
        var open = IslandOpenState()
        open.open(.hover, pointerInside: true, now: 0)
        open.pointer(inside: false, now: 3)
        XCTAssertTrue(open.shouldClose(now: 3 + delay))
        // «Настройки…» in the menu bar: waits for the visit, then closes on leave.
        var remote = IslandOpenState()
        remote.open(.remote, pointerInside: false, now: 0)
        remote.pointer(inside: true, now: 1)
        remote.pointer(inside: false, now: 2)
        XCTAssertTrue(remote.shouldClose(now: 2 + delay))
    }
}
