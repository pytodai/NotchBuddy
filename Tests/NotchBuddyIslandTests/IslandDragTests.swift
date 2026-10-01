import AppKit
import NotchBuddyCore
import XCTest
@testable import NotchBuddy

/// «Островок» dragged sideways (`IslandDrag`, `IslandDragMath`, `IslandLayout.shift`): the threshold that tells a drag
/// from a click, following without a jump, the screen's edges, the snap to the center, where an open island goes, and
/// what opens (nothing) while a drag runs.
@MainActor
final class IslandDragTests: XCTestCase {
    /// A 1512 pt screen without a notch, «Островок».
    private var island: IslandMetrics {
        var m = IslandPreviewRenderer.floating
        m.gap = IslandLayout.islandGap
        m.screenWidth = 1512
        return m
    }

    private var range: ClosedRange<CGFloat> { IslandLayout.shiftRange(width: 190, metrics: island) }

    // MARK: Threshold

    /// A press becomes a drag only after 4 pt sideways; up and down alone never does (the capsule moves only sideways).
    func testThresholdTellsADragFromAClick() {
        XCTAssertFalse(IslandDragMath.begins(dx: 3.9, dy: 0))
        XCTAssertFalse(IslandDragMath.begins(dx: 0, dy: 30), "vertical travel is no drag")
        XCTAssertTrue(IslandDragMath.begins(dx: 4, dy: 0))
        XCTAssertTrue(IslandDragMath.begins(dx: -4, dy: 12))

        var press = IslandDrag(pressX: 500, start: 0, range: range)
        XCTAssertFalse(press.pointer(x: 503, dy: 5))
        XCTAssertFalse(press.active, "3 pt: still a click")
        XCTAssertEqual(press.x, 0)
        XCTAssertTrue(press.pointer(x: 504, dy: 5), "the drag begins")
        XCTAssertTrue(press.active)
        // Once a drag, it stays one even back under the threshold.
        _ = press.pointer(x: 501, dy: 0)
        XCTAssertTrue(press.active)
    }

    /// A press on an open island grabs its capsule only after a clear sideways pull: 12 pt (above the closed capsule's
    /// 8 pt click slop, so a sloppy click on a tab or a header button there stays a click), and more sideways than up or
    /// down. The capsule then starts from where it rests, without a jump.
    func testGrabNeedsAClearSidewaysPull() {
        XCTAssertGreaterThan(IslandDragMath.grabThreshold, 8, "above the click slop")
        XCTAssertFalse(IslandDragMath.grabBegins(dx: 8, dy: 0), "a sloppy click")
        XCTAssertFalse(IslandDragMath.grabBegins(dx: 11.9, dy: 0))
        XCTAssertTrue(IslandDragMath.grabBegins(dx: 12, dy: 3))
        XCTAssertTrue(IslandDragMath.grabBegins(dx: -14, dy: 6))
        XCTAssertFalse(IslandDragMath.grabBegins(dx: 13, dy: 13), "not clearly sideways")
        XCTAssertFalse(IslandDragMath.grabBegins(dx: 0, dy: 40))

        var grab = IslandDrag(pressX: 500, start: -600, range: range, threshold: IslandDragMath.grabThreshold)
        XCTAssertFalse(grab.pointer(x: 511, dy: 0))
        XCTAssertFalse(grab.active)
        XCTAssertTrue(grab.pointer(x: 512, dy: 0), "the grab begins")
        XCTAssertEqual(grab.x, -600, "where the capsule rests: no jump")
        _ = grab.pointer(x: 600, dy: 0)
        XCTAssertEqual(grab.x, -600 + 100, accuracy: 1, "caught up with the pointer")
    }

    // MARK: Following

    /// No jump when the drag begins (the capsule starts where it was, at rest), then it catches up with the pointer —
    /// never more than 1.5× its speed — within about seven times the threshold (~30 pt on the capsule, ~85 pt for a grab
    /// out of the open island) and follows it 1:1, monotonic all the way.
    func testFollowsWithoutAJump() {
        let wide = -1000.0...1000.0 as ClosedRange<CGFloat>
        for threshold in [IslandDragMath.threshold, IslandDragMath.grabThreshold] {
            XCTAssertEqual(IslandDragMath.follow(start: 100, dx: threshold, range: wide, threshold: threshold), 100, accuracy: 0.001)
            XCTAssertEqual(IslandDragMath.follow(start: 100, dx: -threshold, range: wide, threshold: threshold), 100, accuracy: 0.001)
            let step: CGFloat = 0.05
            XCTAssertLessThan(IslandDragMath.follow(start: 0, dx: threshold + step, range: wide, threshold: threshold), step * 0.1,
                              "it leaves its place at (almost) zero speed")
            var previous = IslandDragMath.follow(start: 0, dx: threshold, range: wide, threshold: threshold)
            var dx: CGFloat = threshold + step
            while dx < 200 {
                let x = IslandDragMath.follow(start: 0, dx: dx, range: wide, threshold: threshold)
                XCTAssertGreaterThanOrEqual(x, previous, "monotonic at \(dx) (threshold \(threshold))")
                XCTAssertLessThan(x - previous, step * 1.5, "catching up, at most 1.5× the pointer's speed at \(dx)")
                previous = x
                dx += step
            }
            XCTAssertEqual(IslandDragMath.follow(start: 0, dx: 7.5 * threshold, range: wide, threshold: threshold), 7.5 * threshold,
                           accuracy: 0.5, "caught up")
            XCTAssertEqual(IslandDragMath.follow(start: 0, dx: -150, range: wide, threshold: threshold), -150, accuracy: 0.01,
                           "1:1 to the left")
        }
        XCTAssertEqual(IslandDragMath.follow(start: 0, dx: 30, range: wide), 30, accuracy: 0.1, "a press: caught up at 30 pt")
    }

    /// A press starts its drag from where the capsule is drawn as the drag begins (asked only then): a capsule pressed
    /// again while it still settles after a drop is caught there, under the pointer.
    func testDragStartsWhereTheCapsuleIsDrawn() {
        var asked = 0
        var press = IslandDrag(pressX: 0, start: 0, range: range)
        XCTAssertFalse(press.pointer(x: 2, dy: 0, drawn: { asked += 1; return 9.6 }))
        XCTAssertEqual(asked, 0, "not a drag yet")
        XCTAssertTrue(press.pointer(x: 4, dy: 0, drawn: { asked += 1; return 9.6 }))
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(press.start, 10)
        XCTAssertEqual(press.x, 10, "where it was drawn (whole points)")
        _ = press.pointer(x: 60, dy: 0, drawn: { asked += 1; return -500 })
        XCTAssertEqual(asked, 1, "asked once")
        XCTAssertEqual(press.x, 10 + 60, accuracy: 1)
    }

    /// Past the screen's margin the capsule rubber-bands: it keeps moving, ever slower, and never more than 8 pt beyond.
    func testRubberBandsAtTheEdges() {
        let r = range
        XCTAssertEqual(IslandDragMath.rubberBanded(r.upperBound, range: r), r.upperBound)
        let a = IslandDragMath.rubberBanded(r.upperBound + 10, range: r)
        let b = IslandDragMath.rubberBanded(r.upperBound + 100, range: r)
        let c = IslandDragMath.rubberBanded(r.upperBound + 10_000, range: r)
        XCTAssertGreaterThan(a, r.upperBound)
        XCTAssertGreaterThan(b, a)
        XCTAssertLessThanOrEqual(c, r.upperBound + IslandDragMath.rubberBand)
        XCTAssertLessThan(a - r.upperBound, 10, "with resistance")
        XCTAssertGreaterThanOrEqual(IslandDragMath.rubberBanded(r.lowerBound - 10_000, range: r),
                                    r.lowerBound - IslandDragMath.rubberBand)
        // Even rubber-banded as far as it goes, the 190 pt capsule stays on the screen.
        XCTAssertLessThan(r.upperBound + IslandDragMath.rubberBand + 95, island.roomRight)
        XCTAssertGreaterThan(r.lowerBound - IslandDragMath.rubberBand - 95, -island.roomLeft)
    }

    // MARK: Letting go

    /// Let go, it settles inside the screen; within 24 pt of the center it snaps onto it.
    func testSettlesInsideAndSnapsToTheCenter() {
        let r = range
        XCTAssertEqual(IslandDragMath.settle(r.upperBound + 7, range: r), r.upperBound)
        XCTAssertEqual(IslandDragMath.settle(r.lowerBound - 7, range: r), r.lowerBound)
        XCTAssertEqual(IslandDragMath.settle(23.6, range: r), 0, "magnetic snap")
        XCTAssertEqual(IslandDragMath.settle(-24, range: r), 0)
        XCTAssertEqual(IslandDragMath.settle(24.5, range: r), 25, "beyond the snap: whole points where dropped")
        XCTAssertEqual(IslandDragMath.settle(-311.4, range: r), -311)
        XCTAssertEqual(IslandDragMath.settle(10, range: 40...300), 40, "no center to snap to: the nearest place")

        var press = IslandDrag(pressX: 0, start: 200, range: r)
        _ = press.pointer(x: -190, dy: 0)
        XCTAssertEqual(press.rest, 0, "dropped 10 pt from the center")
        var far = IslandDrag(pressX: 0, start: 0, range: r)
        _ = far.pointer(x: -5000, dy: 0)
        XCTAssertLessThan(far.x, r.lowerBound, "rubber-banded while held")
        XCTAssertEqual(far.rest, r.lowerBound, "springs back inside when let go")
    }

    func testCrossingTheCenter() {
        XCTAssertTrue(IslandDragMath.crossesCenter(from: -3, to: 2))
        XCTAssertTrue(IslandDragMath.crossesCenter(from: 5, to: 0))
        XCTAssertFalse(IslandDragMath.crossesCenter(from: 0, to: 5), "leaving the center is no crossing")
        XCTAssertFalse(IslandDragMath.crossesCenter(from: 3, to: 9))
    }

    // MARK: Where the island sits

    /// «Чёлка» never moves; «Островок» may go anywhere that keeps the whole shape 10 pt inside the screen, measured from
    /// the anchor (which need not be the middle).
    func testShiftRange() {
        XCTAssertEqual(IslandLayout.shiftRange(width: 190, metrics: IslandPreviewRenderer.floating), 0...0)
        XCTAssertEqual(IslandLayout.shiftRange(width: 190, metrics: IslandPreviewRenderer.notched), 0...0)
        let r = IslandLayout.shiftRange(width: 190, metrics: island)
        XCTAssertEqual(r.lowerBound, -(756 - 95 - 10))
        XCTAssertEqual(r.upperBound, 756 - 95 - 10)
        var offCenter = island
        offCenter.anchorInset = 700
        let o = IslandLayout.shiftRange(width: 190, metrics: offCenter)
        XCTAssertEqual(o.lowerBound, -(700 - 105))
        XCTAssertEqual(o.upperBound, 812 - 105)
        // A shape too wide for the screen stays centered on the screen.
        let wide = IslandLayout.shiftRange(width: 1600, metrics: offCenter)
        XCTAssertEqual(wide.lowerBound, wide.upperBound)
        XCTAssertEqual(wide.lowerBound, 56, "the screen's middle (756) from the anchor (700)")
    }

    /// The open list opens from wherever the capsule is, kept on screen: near an edge it sits as far out as it can.
    func testOpenIslandStaysOnScreen() {
        let list: CGFloat = 820
        let farLeft = range.lowerBound
        XCTAssertEqual(IslandLayout.shift(offset: farLeft, width: 190, metrics: island), farLeft, "the capsule where dropped")
        let open = IslandLayout.shift(offset: farLeft, width: list, metrics: island)
        XCTAssertEqual(open, -(756 - 410 - 10))
        XCTAssertGreaterThanOrEqual(756 + open - list / 2, IslandLayout.edgeMargin, "its left edge stays on screen")
        XCTAssertEqual(IslandLayout.shift(offset: 120, width: list, metrics: island), 120, "room enough: right under it")
        XCTAssertEqual(IslandLayout.shift(offset: 300, width: 190, metrics: IslandPreviewRenderer.floating), 0,
                       "«Чёлка» stays on the notch")
    }

    /// The state's target: the dragged position while a drag runs; otherwise the offset clamped with the resting
    /// capsule's width when closed (a hover grow never nudges it) and with the open shape's width when open.
    func testTargetShiftFollowsTheMode() {
        let state = IslandViewState()
        state.jump(to: island)
        state.islandOffset = range.upperBound
        state.mode = .collapsed
        state.geometry = IslandGeometry(width: 190 + 12, height: 38, top: island.gap)
        XCTAssertEqual(state.targetShift(), range.upperBound, "hovered: the capsule stays where it was dropped")
        state.dragShift = range.upperBound + 5
        XCTAssertEqual(state.targetShift(), range.upperBound + 5, "dragging: where it is drawn")
        state.dragShift = nil
        state.mode = .expanded
        state.geometry = IslandGeometry(width: 820, height: 300, top: island.gap)
        XCTAssertEqual(state.targetShift(), 756 - 410 - 10)
        state.mode = .hidden
        XCTAssertEqual(state.targetShift(), range.upperBound, "retracting: it shrinks where it was")
    }

    // MARK: Open rules during a drag

    /// A drag never opens the island (hover or click) and never pins it; once let go, it opens as before. Only the
    /// closed capsule is dragged, and closing does not end a drag.
    func testNothingOpensDuringADrag() {
        var open = IslandOpenState()
        XCTAssertTrue(open.mayOpen)
        XCTAssertTrue(open.beginDrag())
        XCTAssertTrue(open.dragging)
        XCTAssertFalse(open.mayOpen)
        open.open(.hover, pointerInside: true, now: 1)
        XCTAssertFalse(open.isOpen, "a rest under the dragged capsule opens nothing")
        open.open(.click, pointerInside: true, pin: true, now: 1.1)
        XCTAssertFalse(open.isOpen, "nor does a click")
        XCTAssertFalse(open.pinned)
        open.pin()
        XCTAssertFalse(open.pinned)
        open.close()
        XCTAssertTrue(open.dragging, "closing does not end the drag")
        open.endDrag()
        XCTAssertTrue(open.mayOpen)
        open.open(.click, pointerInside: true, now: 2)
        XCTAssertTrue(open.isOpen)
        XCTAssertFalse(open.pinned, "a click still never pins")
        XCTAssertFalse(open.beginDrag(), "an open island is not dragged")
        XCTAssertFalse(open.dragging)
    }
}
