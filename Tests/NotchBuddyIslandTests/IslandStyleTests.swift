import AppKit
import NotchBuddyCore
import SwiftUI
import XCTest
@testable import NotchBuddy

/// «Чёлка» vs «Островок» (Settings → Остров → Стиль): the detached capsule's geometry, path, hit shape, and the live
/// switch (a morph of the shape on the stage, never a resize of the panel).
@MainActor
final class IslandStyleTests: XCTestCase {
    private let attached = IslandPreviewRenderer.floating
    private var detached: IslandMetrics {
        var m = IslandPreviewRenderer.floating
        m.gap = IslandLayout.islandGap
        return m
    }

    private func geometry(_ mode: IslandMode, _ metrics: IslandMetrics, content: CGSize = CGSize(width: 300, height: 34),
                          hovering: Bool = false) -> IslandGeometry {
        IslandLayout.geometry(mode: mode, metrics: metrics, content: content, hovering: hovering, pressed: false,
                              lastPillWidth: 300)
    }

    // MARK: Geometry

    /// The capsule floats `gap` below the top edge, has no ears and is as wide as «Чёлка» with its ears (the body takes
    /// their room), its top corners as round as the bottom ones. Closed, its content is the capsule end to end
    /// (Settings → «Ширина капсулы»), so it is the content's width.
    func testDetachedGeometryFloatsBelowTheTopEdge() {
        let open = CGSize(width: 492, height: 360)
        for (mode, content) in [(IslandMode.collapsed, CGSize(width: 300, height: 34)), (.expanded, open),
                                (.permission, open), (.page("settings"), open), (.flash, CGSize(width: 392, height: 76))] {
            for hovering in [false, true] {
                let a = geometry(mode, attached, content: content, hovering: hovering)
                let d = geometry(mode, detached, content: content, hovering: hovering)
                XCTAssertEqual(a.top, 0, "\(mode)")
                XCTAssertEqual(a.crown, 0, "\(mode)")
                XCTAssertEqual(d.top, IslandLayout.islandGap, "\(mode)")
                XCTAssertEqual(d.ear, 0, "\(mode)")
                XCTAssertEqual(d.crown, d.bottom, "\(mode)")
                if mode == .collapsed {
                    XCTAssertEqual(d.width, content.width + (hovering ? 12 : 0), "the capsule is its content")
                } else {
                    XCTAssertEqual(d.width, a.width, "\(mode)")
                }
                XCTAssertEqual(d.height, a.height, "\(mode): it grows downward from its own top")
            }
        }
        // Retracted, the capsule shrinks into its own middle (it never touched the top edge).
        let hidden = geometry(.hidden, detached)
        XCTAssertEqual(hidden.height, 0)
        XCTAssertEqual(hidden.top, detached.gap + detached.barHeight / 2)
    }

    /// Both styles of a screen without a notch share one canvas: a switch is a morph, never a panel resize.
    func testStyleSwitchNeverResizesTheCanvas() {
        XCTAssertEqual(IslandLayout.canvasSize(attached), IslandLayout.canvasSize(detached))
        XCTAssertTrue(detached.differsOnlyInGap(from: attached))
        XCTAssertTrue(attached.differsOnlyInGap(from: detached))
        XCTAssertFalse(attached.differsOnlyInGap(from: attached))
        // A notched screen lays its content out around the camera: «Островок» there is another layout (the island
        // retracts and emerges instead).
        var below = IslandPreviewRenderer.floating
        below.gap = IslandPreviewRenderer.notched.barHeight + IslandLayout.islandGap
        XCTAssertFalse(below.differsOnlyInGap(from: IslandPreviewRenderer.notched))
        XCTAssertGreaterThanOrEqual(IslandLayout.canvasSize(below).height,
                                    IslandLayout.maxOpenHeight + below.gap + IslandLayout.shadowMargin)
    }

    func testStyleResolvesPerKindOfScreen() {
        var settings = NotchSettings()
        XCTAssertEqual(settings.islandStyle(hasNotch: true), .notch, "the default look out of the box")
        XCTAssertEqual(settings.islandStyle(hasNotch: false), .notch)
        settings.setIslandStyle(.island, hasNotch: false)
        XCTAssertEqual(settings.islandStyle(hasNotch: false), .island, "every monitor, whatever its UUID")
        XCTAssertEqual(settings.islandStyle(hasNotch: true), .notch, "the notched screen keeps its own")
    }

    // MARK: Path

    private func elements(_ path: CGPath) -> [CGPathElementType] {
        var types: [CGPathElementType] = []
        path.applyWithBlock { types.append($0.pointee.type) }
        return types
    }

    /// Every shape of both styles, and every shape between them, is built from the same elements (Core Animation
    /// interpolates the morph point by point).
    func testBothStylesShareTheTopology() {
        let a = geometry(.collapsed, attached)
        let d = geometry(.collapsed, detached)
        let reference = elements(IslandPathBuilder.path(a, pulse: IslandPulse(), canvasWidth: 700))
        let openReference = elements(IslandPathBuilder.path(a, pulse: IslandPulse(), canvasWidth: 700, closed: false))
        XCTAssertEqual(reference.count, 9)
        XCTAssertEqual(openReference.count, 9)
        for p in stride(from: 0.0, through: 1.0, by: 0.05) {
            let g = a.interpolated(to: d, p)
            for pulse in [IslandPulse(), IslandPulse(earBoost: 4, dh: -3)] {
                XCTAssertEqual(elements(IslandPathBuilder.path(g, pulse: pulse, canvasWidth: 700)), reference, "\(p)")
                XCTAssertEqual(elements(IslandPathBuilder.path(g, pulse: pulse, canvasWidth: 700, closed: false)),
                               openReference, "\(p)")
            }
        }
        XCTAssertEqual(elements(IslandPathBuilder.path(geometry(.hidden, detached), pulse: IslandPulse(),
                                                       canvasWidth: 700)), reference)
    }

    /// «Островок» is round all around and floats below the edge; «Чёлка» touches the edge across its whole width.
    func testCapsuleIsRoundAllAround() {
        let d = geometry(.expanded, detached, content: CGSize(width: 492, height: 360))
        let path = IslandPathBuilder.path(d, pulse: IslandPulse(), canvasWidth: 700)
        let box = path.boundingBoxOfPath
        XCTAssertEqual(box.minY, d.top, accuracy: 0.01)
        XCTAssertEqual(box.height, d.height, accuracy: 0.01)
        XCTAssertEqual(box.width, d.width, accuracy: 0.01)
        XCTAssertTrue(path.contains(CGPoint(x: 350, y: d.top + 1)))
        XCTAssertFalse(path.contains(CGPoint(x: 350, y: d.top - 1)), "a gap above it")
        XCTAssertFalse(path.contains(CGPoint(x: box.minX + 2, y: d.top + 2)), "round top-left corner")
        XCTAssertFalse(path.contains(CGPoint(x: box.maxX - 2, y: d.top + 2)), "round top-right corner")
        XCTAssertTrue(path.contains(CGPoint(x: box.minX + 2, y: box.midY)))

        let a = geometry(.expanded, attached, content: CGSize(width: 492, height: 360))
        let notch = IslandPathBuilder.path(a, pulse: IslandPulse(), canvasWidth: 700)
        XCTAssertEqual(notch.boundingBoxOfPath.minY, 0, accuracy: 0.01)
        XCTAssertTrue(notch.contains(CGPoint(x: notch.boundingBoxOfPath.minX + 8, y: 0.5)), "the ear flares into the edge")
        XCTAssertFalse(notch.contains(CGPoint(x: notch.boundingBoxOfPath.minX + 8, y: 6)), "under the ear: not the island")
    }

    /// The morph between the styles never jumps: between two samples 1/120 s apart of a spring the outline moves by a
    /// fraction of a point.
    func testMorphIsContinuous() {
        let a = geometry(.collapsed, attached)
        let d = geometry(.collapsed, detached)
        var last: CGRect?
        for i in 0...200 {
            let g = a.interpolated(to: d, Double(i) / 200)
            let box = IslandPathBuilder.path(g, pulse: IslandPulse(), canvasWidth: 700).boundingBoxOfPath
            if let last {
                XCTAssertLessThan(abs(box.minY - last.minY), 0.5, "\(i)")
                XCTAssertLessThan(abs(box.maxY - last.maxY), 0.5, "\(i)")
                XCTAssertLessThan(abs(box.width - last.width), 0.6, "\(i)")
            }
            last = box
        }
    }

    // MARK: Capsule width

    /// Settings → «Ширина капсулы»: the closed face is exactly the width set, from the slider's minimum to its maximum,
    /// with the mascot, the status and the usage ring (and the count of the other sessions on it) at every width.
    func testCapsuleFaceFitsEveryWidth() {
        let height = detached.barHeight
        for width in [IslandLayout.capsuleWidthRange.lowerBound, CGFloat(NotchSettings.defaultCapsuleWidth),
                      IslandLayout.capsuleWidthRange.upperBound] {
            let fit = IslandCapsule.fit(width: width, height: height, status: true, usage: true, others: 2)
            XCTAssertEqual(fit, .init(ring: true, badge: false), "\(width)")
            let face = IslandCapsuleFace(width: width, height: height, status: .working, usage: 42, others: 2) { EmptyView() }
            let size = NSHostingView(rootView: face).fittingSize
            XCTAssertEqual(size.width, width, accuracy: 0.5)
            XCTAssertEqual(size.height, height, accuracy: 0.5)
            let g = geometry(.collapsed, detached, content: size)
            XCTAssertEqual(g.width, width, accuracy: 0.5, "the silhouette is the width set")
        }
        // Narrower than the slider allows (a hand-written default is clamped, but the face copes): the ring gives way
        // first, then «+N».
        XCTAssertEqual(IslandCapsule.fit(width: 90, height: height, status: true, usage: true, others: 2),
                       .init(ring: false, badge: false))
        XCTAssertEqual(IslandCapsule.fit(width: 110, height: height, status: true, usage: false, others: 2),
                       .init(ring: false, badge: true))
        XCTAssertEqual(IslandCapsule.fit(width: 190, height: height, status: true, usage: false, others: 0),
                       .init(ring: false, badge: false))
        // The canvas holds the widest capsule, grown under the pointer.
        let canvas = IslandLayout.canvasSize(detached)
        XCTAssertGreaterThan(canvas.width - 2 * IslandLayout.shadowMargin, IslandLayout.capsuleWidthRange.upperBound + 12)
    }

    /// The capsule's ends are half circles at every width: the hit shape follows the outline (no clicks taken beside
    /// the round ends), and the strip above it still counts as the island.
    func testCapsuleHitShapeFollowsTheWidth() {
        let screen = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let anchor = NSPoint(x: 800, y: 1000)
        for width in [IslandLayout.capsuleWidthRange.lowerBound, 190, IslandLayout.capsuleWidthRange.upperBound] {
            let d = geometry(.collapsed, detached, content: CGSize(width: width, height: detached.barHeight))
            let rect = NSRect(x: anchor.x - d.width / 2, y: anchor.y - d.top - d.height, width: d.width, height: d.height)
            let shape = IslandHitShape(rect: rect, geometry: d, screenTop: anchor.y)
            let r = d.height / 2
            XCTAssertEqual(shape.corner, r, accuracy: 0.01, "\(width): round ends")
            XCTAssertEqual(shape.crown, r, accuracy: 0.01, "\(width)")
            XCTAssertTrue(shape.contains(NSPoint(x: rect.minX + 1, y: rect.midY), within: screen), "\(width): the end's tip")
            XCTAssertTrue(shape.contains(NSPoint(x: rect.maxX - 1, y: rect.midY), within: screen), "\(width)")
            XCTAssertFalse(shape.contains(NSPoint(x: rect.minX + 3, y: rect.maxY - 3), within: screen),
                           "\(width): beside the round end")
            XCTAssertFalse(shape.contains(NSPoint(x: rect.maxX + 2, y: rect.midY), within: screen), "\(width): past it")
            XCTAssertTrue(shape.contains(NSPoint(x: anchor.x, y: anchor.y), within: screen), "\(width): the top edge")
            // The drawn outline agrees with the hit shape.
            let path = IslandPathBuilder.path(d, pulse: IslandPulse(), canvasWidth: 800)
            XCTAssertEqual(path.boundingBoxOfPath.width, width, accuracy: 0.01)
            XCTAssertFalse(path.contains(CGPoint(x: 400 - width / 2 + 3, y: d.top + 3)))
            XCTAssertTrue(path.contains(CGPoint(x: 400 - width / 2 + 1, y: d.top + r)))
        }
    }

    // MARK: Hit shape

    /// A pointer thrown against the top edge above the capsule is on the island (as on «Чёлка»); the columns beside
    /// its round corners are not.
    func testDetachedHitShape() {
        let d = geometry(.collapsed, detached)
        let screen = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let anchor = NSPoint(x: 800, y: 1000)
        let rect = NSRect(x: anchor.x - d.width / 2, y: anchor.y - d.top - d.height, width: d.width, height: d.height)
        let shape = IslandHitShape(rect: rect, geometry: d, screenTop: anchor.y)
        XCTAssertTrue(shape.contains(NSPoint(x: 800, y: 1000), within: screen), "top edge above the middle")
        XCTAssertTrue(shape.contains(NSPoint(x: 800, y: rect.midY), within: screen))
        XCTAssertFalse(shape.contains(NSPoint(x: rect.minX + 1, y: 999), within: screen), "above a round corner")
        XCTAssertFalse(shape.contains(NSPoint(x: rect.minX + 1, y: rect.maxY - 1), within: screen), "outside the corner")
        XCTAssertFalse(shape.contains(NSPoint(x: rect.minX - 5, y: rect.midY), within: screen))
        XCTAssertTrue(shape.contains(NSPoint(x: rect.minX - 5, y: rect.midY), slopX: 10, slopY: 10, within: screen),
                      "the hover state's slop")
        XCTAssertFalse(shape.contains(NSPoint(x: 800, y: rect.minY - 3), within: screen))
    }
}

/// The live switch on the real stage (virtual clock, a panel far off every screen).
@MainActor
final class IslandStyleStageTests: XCTestCase {
    private var state: IslandViewState!
    private var stage: IslandStage!
    private var panel: IslandPanel!
    private var now: CFTimeInterval = 1000
    private var jobs: [(at: CFTimeInterval, body: @MainActor () -> Void)] = []
    private var fakes: StageFakes!

    private var detached: IslandMetrics {
        var m = IslandPreviewRenderer.floating
        m.gap = IslandLayout.islandGap
        return m
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        fakes = StageFakes(now: Date())
        state = IslandViewState()
        stage = IslandStage(state: state)
        stage.timeline.filming = true
        stage.clock = { [unowned self] in self.now }
        stage.later = { [unowned self] seconds, body in self.jobs.append((self.now + max(0, seconds), body)) }
        state.jump(to: IslandPreviewRenderer.floating)
        let canvas = IslandLayout.canvasSize(state.metrics)
        panel = IslandPanel()
        panel.contentView = IslandContainerView(host: stage.view)
        panel.setFrame(NSRect(x: -40_000, y: -40_000, width: canvas.width, height: canvas.height), display: false)
        panel.ignoresMouseEvents = true
        panel.contentView?.layoutSubtreeIfNeeded()
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

    /// «Чёлка» → «Островок» with the list open: no content swap, the shape moves to its new place on one spring, the
    /// pages move to where it floats (and take clicks there), the way back is the same.
    func testLiveSwitchMorphsTheShape() {
        state.setContent(.expanded, snapshot: fakes.trio)
        advance(1)
        let commits = state.commitCount
        let before = stage.presentedGeometry(at: now)
        XCTAssertEqual(before.top, 0, accuracy: 0.01)
        state.morph(to: detached)
        XCTAssertEqual(state.commitCount, commits, "no content swap")
        XCTAssertEqual(stage.presentedGeometry(at: now).top, 0, accuracy: 0.01, "starts where it was")
        var last = stage.presentedGeometry(at: now)
        for _ in 0..<120 {
            advance(1.0 / 120)
            let g = stage.presentedGeometry(at: now)
            XCTAssertLessThan(abs(g.top - last.top), 1, "no jump")
            XCTAssertLessThan(abs(g.width - last.width), 2, "no jump")
            last = g
        }
        let after = stage.presentedGeometry(at: now)
        XCTAssertEqual(after.top, IslandLayout.islandGap, accuracy: 0.05)
        XCTAssertEqual(after.ear, 0, accuracy: 0.05)
        XCTAssertEqual(after.width, before.width, accuracy: 0.5)
        let list = stage.pages[.list]
        XCTAssertEqual(list?.view.frame.minY ?? -1, IslandLayout.islandGap, accuracy: 0.01)

        state.morph(to: IslandPreviewRenderer.floating)
        advance(1.5)
        XCTAssertEqual(stage.presentedGeometry(at: now).top, 0, accuracy: 0.05)
        XCTAssertEqual(list?.view.frame.minY ?? -1, 0, accuracy: 0.01)
    }

    /// Settings → «Ширина капсулы», live: the closed capsule is exactly the width set and a change morphs the shape to
    /// the new one on a spring (no content swap, no jump); the hover grows it a little, as before.
    func testCapsuleWidthMorphsTheShape() {
        let saved = IslandLayout.capsuleWidth
        defer {
            IslandLayout.capsuleWidth = saved
            state.capsuleWidth = saved
        }
        IslandLayout.capsuleWidth = 190
        state.capsuleWidth = 190
        state.jump(to: detached)
        state.setContent(.collapsed, snapshot: fakes.trio)
        advance(1)
        XCTAssertEqual(stage.presentedGeometry(at: now).width, 190, accuracy: 0.5)
        for target in [IslandLayout.capsuleWidthRange.upperBound, IslandLayout.capsuleWidthRange.lowerBound] {
            let commits = state.commitCount
            IslandLayout.capsuleWidth = target
            state.capsuleWidth = target
            var last = stage.presentedGeometry(at: now)
            for _ in 0..<120 {
                advance(1.0 / 120)
                let g = stage.presentedGeometry(at: now)
                XCTAssertLessThan(abs(g.width - last.width), 12, "no jump")
                XCTAssertEqual(g.height, last.height, accuracy: 0.01, "only the width moves")
                last = g
            }
            XCTAssertEqual(state.commitCount, commits, "a data change: no content swap")
            XCTAssertEqual(stage.presentedGeometry(at: now).width, target, accuracy: 0.5)
            XCTAssertEqual(state.target().width, target, accuracy: 0.5)
        }
        state.setHovering(true)
        advance(1)
        XCTAssertEqual(stage.presentedGeometry(at: now).width, IslandLayout.capsuleWidthRange.lowerBound + 12, accuracy: 0.5)
    }
}

/// A real click on a card button of the floating capsule reaches the controller: pages are laid out (and hit-tested)
/// where the capsule floats, not only drawn there.
@MainActor
final class IslandStyleClickTests: XCTestCase {
    func testClickOnCardButtonOfTheCapsule() throws {
        _ = NSApplication.shared
        let fakes = StageFakes(now: Date())
        let state = IslandViewState()
        let stage = IslandStage(state: state)
        var decided: [UUID] = []
        state.actions.decide = { id, _ in decided.append(id) }
        var metrics = IslandPreviewRenderer.floating
        metrics.gap = IslandLayout.islandGap
        state.jump(to: metrics)
        let canvas = IslandLayout.canvasSize(state.metrics)
        let panel = IslandPanel()
        let container = IslandContainerView(host: stage.view)
        panel.contentView = container
        panel.setFrame(NSRect(x: -40_000, y: -40_000, width: canvas.width, height: canvas.height), display: false)
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        container.layoutSubtreeIfNeeded()

        state.cardPresentedAt = AppClock.monotonicSeconds()
        state.setContent(.permission, snapshot: fakes.card, glow: .card)
        state.armedCardID = fakes.claudeCard.id
        state.contentInteractive = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let page = try XCTUnwrap(stage.pages[.card(fakes.claudeCard.id)])
        XCTAssertEqual(page.view.frame.minY, metrics.gap, accuracy: 0.01)

        // «Разрешить», as in `testClickOnCardButtonReachesDecide`, `gap` lower.
        let origin = page.contentOrigin(canvasWidth: canvas.width)
        let local = NSPoint(x: origin.x + page.contentSize.width * 0.82,
                            y: metrics.gap + page.contentSize.height - 12 - 16 - 10 - 17)
        let point = stage.view.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                         windowNumber: panel.windowNumber, context: nil,
                                                         eventNumber: 0, clickCount: 1, pressure: 1))
            panel.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(decided, [fakes.claudeCard.id])
    }
}
