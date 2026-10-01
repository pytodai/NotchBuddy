import AppKit
import NotchBuddyCore
import SwiftUI
import XCTest
@testable import NotchBuddy

/// «Островок» moved sideways on the stage (`IslandStage.slide`, `IslandSlideView`): a drag moves the whole island rigidly
/// without baking anything, a release settles it, and an open near the screen's edge keeps the open island on screen
/// while its content holds still (only the silhouette moves). On a virtual clock (film mode), in a screen-wide panel far
/// off every screen, as the app has it.
@MainActor
final class IslandSlideTests: XCTestCase {
    private var state: IslandViewState!
    private var stage: IslandStage!
    private var panel: IslandPanel!
    private var container: IslandContainerView!
    private var now: CFTimeInterval = 1000
    private var jobs: [(at: CFTimeInterval, body: @MainActor () -> Void)] = []
    private var fakes: StageFakes!
    private var metrics: IslandMetrics!

    override func setUp() async throws {
        _ = NSApplication.shared
        fakes = StageFakes(now: Date())
        var m = IslandPreviewRenderer.floating
        m.gap = IslandLayout.islandGap
        m.screenWidth = 1512
        metrics = m
        state = IslandViewState()
        stage = IslandStage(state: state)
        stage.timeline.filming = true
        stage.clock = { [unowned self] in self.now }
        stage.later = { [unowned self] seconds, body in self.jobs.append((self.now + max(0, seconds), body)) }
        state.jump(to: m)
        let canvas = IslandLayout.canvasSize(m)
        stage.slider.canvasSize = canvas
        panel = IslandPanel()
        container = IslandContainerView(host: stage.slider)
        panel.contentView = container
        panel.setFrame(NSRect(x: -40_000, y: -40_000, width: m.screenWidth, height: canvas.height), display: false)
        panel.ignoresMouseEvents = true
        container.layoutSubtreeIfNeeded()
    }

    override func tearDown() async throws {
        panel.orderOut(nil)
    }

    private func advance(_ seconds: Double) {
        let end = now + seconds
        while let i = jobs.indices.filter({ jobs[$0].at <= end }).min(by: { jobs[$0].at < jobs[$1].at }) {
            let job = jobs.remove(at: i)
            now = max(now, job.at)
            job.body()
        }
        now = end
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
        stage.apply(at: now)
    }

    private func tx(_ layer: CALayer?) -> CGFloat { layer?.sublayerTransform.m41 ?? 0 }

    /// Where the island's center is drawn on the panel: the canvas' frame, plus the slide's transform.
    private var drawnCenter: CGFloat {
        stage.slider.content.frame.midX + tx(stage.slider.layer)
    }

    /// Where a page's content starts on the panel (its pin included).
    private func contentLeft(_ id: IslandPageID) -> CGFloat? {
        guard let page = stage.pages[id] else { return nil }
        let canvas = IslandLayout.canvasSize(metrics).width
        return drawnCenter - canvas / 2 + tx(page.shift.layer) + page.contentOrigin(canvasWidth: canvas).x
    }

    private func settled(at offset: CGFloat) {
        state.islandOffset = offset
        state.setContent(.collapsed, snapshot: fakes.trio)
        advance(1.5)
    }

    /// A drag draws the island at once at the pointer's place: one transform on the slider, no frame moved, nothing
    /// baked; let go, the frame goes to where it rests (AppKit hit-tests there) and the transform carries the rest of
    /// the way, continuously.
    func testDragMovesTheWholeIslandRigidly() {
        settled(at: 0)
        let middle = metrics.screenWidth / 2
        XCTAssertEqual(drawnCenter, middle, accuracy: 0.5)
        let frame = stage.slider.content.frame
        state.dragShift = -200
        stage.dragSlide(to: -200)
        XCTAssertEqual(stage.slider.content.frame, frame, "a drag moves no view")
        XCTAssertEqual(drawnCenter, middle - 200, accuracy: 0.5)
        stage.dragSlide(to: -260)
        XCTAssertEqual(drawnCenter, middle - 260, accuracy: 0.5)
        // Let go 8 pt past the edge's margin's reach: it settles at -240.
        state.dragShift = nil
        state.islandOffset = -240
        stage.settleSlide(spring: IslandMotion.drop)
        stage.apply(at: now)
        XCTAssertEqual(stage.slider.content.frame.midX, middle - 240, accuracy: 0.5, "the frame is where it rests")
        XCTAssertEqual(drawnCenter, middle - 260, accuracy: 0.5, "drawn where it was let go")
        var previous = drawnCenter
        for _ in 0..<60 {
            advance(1.0 / 120)
            XCTAssertLessThan(abs(drawnCenter - previous), 6, "no jump")
            previous = drawnCenter
        }
        XCTAssertEqual(drawnCenter, middle - 240, accuracy: 0.5)
    }

    /// Opening from a capsule at the left edge: the open island stays on screen (its left edge never passes the margin),
    /// and the list does not move while the silhouette slides and grows around it.
    func testOpenFromTheEdgeKeepsTheContentStill() throws {
        let range = IslandLayout.shiftRange(width: IslandLayout.capsuleWidth, metrics: metrics)
        settled(at: range.lowerBound)
        XCTAssertEqual(drawnCenter, metrics.screenWidth / 2 + range.lowerBound, accuracy: 0.5)
        state.setContent(.expanded, snapshot: fakes.trio)
        let finalShift = state.targetShift()
        XCTAssertGreaterThan(finalShift, range.lowerBound, "the open island sits further in")
        let left = try XCTUnwrap(contentLeft(.list))
        var t = 0.0
        while t < 0.8 {
            advance(1.0 / 60)
            t += 1.0 / 60
            XCTAssertEqual(try XCTUnwrap(contentLeft(.list)), left, accuracy: 0.5, "the list holds still at \(Int(t * 1000)) ms")
            let g = stage.presentedGeometry(at: now)
            let silhouetteLeft = drawnCenter - g.width / 2
            XCTAssertGreaterThan(silhouetteLeft, IslandLayout.edgeMargin - 2, "on screen at \(Int(t * 1000)) ms")
        }
        advance(1)
        XCTAssertEqual(drawnCenter, metrics.screenWidth / 2 + finalShift, accuracy: 0.5)
        XCTAssertEqual(stage.slider.content.frame.midX, metrics.screenWidth / 2 + finalShift, accuracy: 0.5,
                       "clicks land where the list is")
        XCTAssertEqual(tx(stage.pages[.list]?.shift.layer), 0, "nothing left pinned once it settled")
        XCTAssertEqual(tx(stage.slider.layer), 0, "the island rests exactly on its frame (no blur)")
    }

    /// Closing back to the capsule at the edge: the list fades where it was, the capsule's content waits at its place.
    func testCloseToTheEdgeKeepsTheContentStill() throws {
        let range = IslandLayout.shiftRange(width: IslandLayout.capsuleWidth, metrics: metrics)
        state.islandOffset = range.lowerBound
        state.setContent(.expanded, snapshot: fakes.trio)
        advance(1.5)
        let listLeft = try XCTUnwrap(contentLeft(.list))
        state.setContent(.collapsed, snapshot: fakes.trio)
        let closedLeft = try XCTUnwrap(contentLeft(.closed))
        for _ in 0..<12 {
            advance(1.0 / 120)
            XCTAssertEqual(try XCTUnwrap(contentLeft(.list)), listLeft, accuracy: 0.5)
            XCTAssertEqual(try XCTUnwrap(contentLeft(.closed)), closedLeft, accuracy: 0.5)
        }
        advance(1.5)
        XCTAssertEqual(drawnCenter, metrics.screenWidth / 2 + range.lowerBound, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(contentLeft(.closed)), closedLeft, accuracy: 0.5)
    }

    /// The open island grabbed and pulled (it folds back into its capsule, which follows the pointer): the list fades
    /// out where it was while the capsule and its content go with the drag.
    func testGrabbedIslandFoldsWhereItIs() throws {
        let range = IslandLayout.shiftRange(width: IslandLayout.capsuleWidth, metrics: metrics)
        state.islandOffset = range.lowerBound
        state.setContent(.expanded, snapshot: fakes.trio)
        advance(1.5)
        let listLeft = try XCTUnwrap(contentLeft(.list))
        state.setContent(.collapsed, snapshot: fakes.trio)
        let closedLeft = try XCTUnwrap(contentLeft(.closed))
        advance(1.0 / 60)
        for (i, x) in [range.lowerBound, range.lowerBound + 20, range.lowerBound + 60].enumerated() {
            state.dragShift = x
            stage.dragSlide(to: x)
            // The fold is still under way: the drag's remainder is baked (film mode draws a moment with `apply`).
            stage.apply(at: now)
            XCTAssertEqual(try XCTUnwrap(contentLeft(.list)), listLeft, accuracy: 0.5, "the leaving list holds still (\(i))")
            XCTAssertEqual(try XCTUnwrap(contentLeft(.closed)), closedLeft + (x - range.lowerBound), accuracy: 0.5,
                           "the capsule's content goes with the drag (\(i))")
            advance(1.0 / 60)
        }
    }

    /// The open island at the left edge grabbed where its capsule sits, as `IslandController.beginGrab` does it (the
    /// close, then a drag from where the capsule rests): the island is drawn where it was at the grab and never jumps —
    /// the fold carries it on around the drag — it stays on screen, the leaving list holds still, and once the fold is
    /// over the capsule is right where the drag has it.
    func testGrabbingTheOpenIslandAtTheEdgeDoesNotJump() {
        let range = IslandLayout.shiftRange(width: IslandLayout.capsuleWidth, metrics: metrics)
        state.islandOffset = range.lowerBound
        state.setContent(.expanded, snapshot: fakes.trio)
        advance(1.5)
        let open = drawnCenter
        XCTAssertGreaterThan(open, metrics.screenWidth / 2 + range.lowerBound + 100, "the open island sits further in")
        let listLeft = contentLeft(.list)
        state.setContent(.collapsed, snapshot: fakes.trio)
        var x = state.targetShift()
        XCTAssertEqual(x, range.lowerBound, "the capsule rests at the edge")
        state.dragShift = x
        state.setHovering(true, riding: true)
        stage.dragSlide(to: x)
        stage.apply(at: now)
        XCTAssertEqual(drawnCenter, open, accuracy: 0.5, "drawn where it was at the grab")
        var previous = drawnCenter
        for i in 0..<72 {
            advance(1.0 / 120)
            if i % 2 == 1 {
                x += 3
                state.dragShift = x
                stage.dragSlide(to: x)
                stage.apply(at: now)
            }
            XCTAssertLessThan(abs(drawnCenter - previous), 20, "no jump at \(i)")
            let g = stage.presentedGeometry(at: now)
            XCTAssertGreaterThan(drawnCenter - g.width / 2, IslandLayout.edgeMargin - 8, "on screen at \(i)")
            if let listLeft, let left = contentLeft(.list), stage.pages[.list]?.phase == .leaving {
                XCTAssertEqual(left, listLeft, accuracy: 0.5, "the leaving list holds still at \(i)")
            }
            previous = drawnCenter
        }
        advance(1)
        XCTAssertEqual(drawnCenter, metrics.screenWidth / 2 + x, accuracy: 0.5, "where the drag has it once the fold is over")
    }

    /// The capsule pressed again while it still settles after a drop: the drag starts where it is drawn (as
    /// `IslandController.dragClosedIsland` starts it), so it is caught there, under the pointer, and carried from there.
    func testPressWhileSettlingCatchesTheCapsule() {
        settled(at: 240)
        state.dragShift = 18
        stage.dragSlide(to: 18)
        state.dragShift = nil
        state.islandOffset = 0
        stage.settleSlide(spring: IslandMotion.drop)
        advance(0.05)
        let caught = drawnCenter
        XCTAssertGreaterThan(caught - metrics.screenWidth / 2, 1, "still on its way to the center")
        let x = stage.presentedShiftNow.rounded()
        state.dragShift = x
        stage.holdSlide(at: x)
        stage.dragSlide(to: x)
        stage.apply(at: now)
        XCTAssertEqual(drawnCenter, caught, accuracy: 0.6, "no jump")
        advance(0.1)
        XCTAssertEqual(drawnCenter, caught, accuracy: 0.6, "held under the pointer: it does not settle on in the hand")
        stage.dragSlide(to: x + 30)
        stage.apply(at: now)
        XCTAssertEqual(drawnCenter, caught + 30, accuracy: 0.6)
    }

    /// «Сбросить положение» with the island open: the whole open island slides home, its content with it.
    func testResetMovesTheOpenIslandWithItsContent() throws {
        state.islandOffset = 200
        state.setContent(.expanded, snapshot: fakes.trio)
        advance(1.5)
        let before = try XCTUnwrap(contentLeft(.list))
        state.islandOffset = 0
        stage.settleSlide(spring: IslandMotion.drop)
        advance(1.5)
        XCTAssertEqual(drawnCenter, metrics.screenWidth / 2, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(contentLeft(.list)), before - 200, accuracy: 0.5)
    }

    /// «Островок» → «Чёлка» on the same screen: the capsule slides back to the top center as it morphs.
    func testStyleSwitchSlidesHome() {
        settled(at: 300)
        XCTAssertEqual(drawnCenter, metrics.screenWidth / 2 + 300, accuracy: 0.5)
        var attached = metrics!
        attached.gap = 0
        state.morph(to: attached)
        advance(1.5)
        XCTAssertEqual(drawnCenter, metrics.screenWidth / 2, accuracy: 0.5)
    }
}
