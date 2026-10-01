import AppKit
import NotchBuddyCore
import SwiftUI
import XCTest
@testable import NotchBuddy

/// The Core Animation stage driven like the controller drives it, on a virtual clock (film mode), in a panel far off
/// every screen.
@MainActor
final class IslandStageTests: XCTestCase {
    private var state: IslandViewState!
    private var stage: IslandStage!
    private var panel: IslandPanel!
    private var container: IslandContainerView!
    private var now: CFTimeInterval = 1000
    private var jobs: [(at: CFTimeInterval, body: @MainActor () -> Void)] = []
    private var fakes: StageFakes!

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
        container = IslandContainerView(host: stage.view)
        panel.contentView = container
        panel.setFrame(NSRect(x: -40_000, y: -40_000, width: canvas.width, height: canvas.height), display: false)
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

    /// The silhouette moves in the very call that changes the content (measure, then move, synchronously) and heads
    /// for the measured content.
    func testContentSwapCommitsOnceAtOnce() {
        state.setContent(.collapsed, snapshot: fakes.trio)
        advance(1)
        let commits = state.commitCount
        state.setContent(.expanded, snapshot: fakes.trio)
        XCTAssertEqual(state.commitCount, commits + 1)
        XCTAssertEqual(stage.currentIDs, [.list])
        let list = try? XCTUnwrap(stage.pages[.list])
        XCTAssertEqual(list?.phase, .live)
        let size = state.contentSize(.expanded)
        XCTAssertEqual(list?.contentSize, size)
        XCTAssertEqual(state.geometry.width, size.width + 2 * IslandLayout.openEar)
        XCTAssertEqual(state.geometry.height, size.height)
        XCTAssertEqual(stage.geometry.to, state.geometry.vector)
        advance(1)
        // The closed island is kept, hidden, for the next time.
        XCTAssertEqual(stage.pages[.closed]?.phase, .hidden)
        XCTAssertEqual(Double(stage.presentedGeometry(at: now).height), Double(size.height), accuracy: 0.05)
    }

    /// A change of mind mid-open continues from what is on screen: position and speed.
    func testInterruptionIsContinuous() {
        state.setContent(.collapsed, snapshot: fakes.trio)
        advance(1)
        state.setContent(.expanded, snapshot: fakes.trio)
        advance(0.08)
        let t = now
        let before = stage.presentedGeometry(at: t - 1.0 / 120)
        let at = stage.presentedGeometry(at: t)
        state.setContent(.collapsed, snapshot: fakes.trio)
        let after = stage.presentedGeometry(at: t + 1.0 / 120)
        XCTAssertEqual(Double(stage.presentedGeometry(at: t).height), Double(at.height), accuracy: 1e-6)
        // Still moving the way it was going one frame later (no reversal in a frame).
        XCTAssertGreaterThan(after.height, at.height - 0.01)
        XCTAssertGreaterThan(at.height, before.height)
        advance(1.5)
        XCTAssertEqual(Double(stage.presentedGeometry(at: now).height), Double(state.geometry.height), accuracy: 0.05)
        XCTAssertEqual(stage.currentIDs, [.closed])
        XCTAssertEqual(stage.pages[.closed]?.phase, .live)
        XCTAssertNil(stage.pages[.list], "the list goes once it has left")
    }

    /// The next card of a queue: the old request leaves and goes, the queue chrome stays.
    func testCardAdvanceKeepsChrome() {
        state.setContent(.permission, snapshot: fakes.card, glow: .card)
        advance(1)
        let chrome = stage.pages[.cardChrome]
        XCTAssertNotNil(chrome)
        state.setContent(.permission, snapshot: fakes.nextCard, entrance: .deck, pulse: .gulp, glow: .card)
        XCTAssertEqual(stage.currentIDs, [.card(fakes.codexCard.id), .cardChrome])
        XCTAssertEqual(stage.pages[.card(fakes.claudeCard.id)]?.phase, .leaving)
        XCTAssertTrue(stage.pages[.cardChrome] === chrome)
        advance(1)
        XCTAssertNil(stage.pages[.card(fakes.claudeCard.id)])
        XCTAssertEqual(stage.pages[.card(fakes.codexCard.id)]?.phase, .live)
    }

    /// Retracting into the top edge tells the controller when it is gone (it orders the panel out then).
    func testHiddenReportsRetraction() {
        var retracted = false, hidden = false
        state.onRetracted = { retracted = true }
        state.onHidden = { hidden = true }
        state.setContent(.collapsed, snapshot: fakes.trio)
        advance(1)
        state.setContent(.hidden, snapshot: IslandSnapshot(usage: fakes.usage))
        XCTAssertFalse(retracted)
        advance(0.1)
        XCTAssertFalse(hidden)
        advance(1)
        XCTAssertTrue(retracted)
        XCTAssertTrue(hidden)
        XCTAssertLessThan(stage.presentedGeometry(at: now).height, 0.5)
    }

    /// Sections of a page that comes in cascade (a mask whose parts fade in), and the mask goes once they are in.
    func testSectionsCascadeThenMaskGoes() throws {
        state.setContent(.collapsed, snapshot: fakes.trio)
        advance(1)
        state.setContent(.expanded, snapshot: fakes.trio)
        let list = try XCTUnwrap(stage.pages[.list])
        XCTAssertGreaterThanOrEqual(list.sink.sections.count, 5, "header, rows, footer")
        XCTAssertNotNil(list.cascade.layer?.mask)
        advance(1)
        XCTAssertNil(list.cascade.layer?.mask)
    }

    /// Clicks reach a page only once it is in and interactive.
    func testPageTakesClicksOnlyWhenInteractive() throws {
        state.setContent(.collapsed, snapshot: fakes.trio)
        advance(1)
        state.setContent(.expanded, snapshot: fakes.trio)
        let list = try XCTUnwrap(stage.pages[.list])
        let origin = list.contentOrigin(canvasWidth: stage.canvas.width)
        // A point inside the first row, in the page view's superview's coordinates (flipped, top-left).
        let point = NSPoint(x: origin.x + 60, y: 80)
        state.contentInteractive = false
        XCTAssertNil(list.view.hitTest(point))
        state.contentInteractive = true
        XCTAssertNotNil(list.view.hitTest(point))
        // Outside the content: nothing.
        XCTAssertNil(list.view.hitTest(NSPoint(x: 2, y: 80)))
    }

    /// A registered page is shown like the list: its own page, the silhouette sized to it.
    func testCustomPage() throws {
        IslandPages.register(IslandPageSpec(id: "test-page", width: { _ in 400 }) { context in
            AnyView(Text("Настройки").frame(width: context.width, height: 180))
        })
        state.setContent(.collapsed, snapshot: fakes.trio)
        advance(1)
        state.setContent(.page("test-page"), snapshot: fakes.trio)
        let page = try XCTUnwrap(stage.pages[.custom("test-page")])
        XCTAssertEqual(page.contentSize, CGSize(width: 400, height: 180))
        XCTAssertEqual(state.geometry.width, 400 + 2 * IslandLayout.openEar)
        XCTAssertEqual(state.geometry.height, 180)
    }

    /// The flying agent mark ends on its slot in the list.
    func testHeroLandsOnSlot() {
        state.setContent(.collapsed, snapshot: fakes.trio)
        advance(1)
        state.setContent(.expanded, snapshot: fakes.trio)
        XCTAssertEqual(state.heroes.count, 1)
        advance(1)
        let hero = state.heroes[0]
        let slot = state.slot(HeroSlotID(kind: .expanded, key: hero.id))
        XCTAssertNotNil(slot)
        XCTAssertEqual(hero.rect.size, slot?.size)
    }

    /// The flying mark is the primary session's pixel mascot (the sprite strip on the hero layer, sized to the slot's
    /// crisp square) and follows its session's state without a content swap.
    func testHeroPlaysItsSessionsMascot() throws {
        state.setContent(.collapsed, snapshot: fakes.trio)
        advance(1)
        let primary = try XCTUnwrap(fakes.trio.primary)
        let hero = try XCTUnwrap(stage.hero(primary.key))
        XCTAssertEqual(hero.mascot, MascotState(session: primary))
        let sheet = MascotSpriteSheet.shared(MascotCharacter(agent: primary.source))
        XCTAssertTrue((hero.layer.contents as AnyObject?) === sheet.image)
        XCTAssertEqual(hero.layer.magnificationFilter, .nearest)
        let side = hero.layer.bounds.width * 2 / CGFloat(PixelArt.canvasSize)
        XCTAssertEqual(side, side.rounded(), accuracy: 0.001, "whole device pixels per art pixel at rest")

        var finished = fakes.trio
        finished.sessions[0].status = .finished
        state.updateData(finished)
        XCTAssertEqual(stage.hero(primary.key)?.mascot, .done)
    }

    /// A follower gets a layer and bakes along with the shape; removing it removes the layer.
    func testFollowerFollowsTheShape() {
        state.setContent(.collapsed, snapshot: fakes.trio)
        advance(1)
        let glow = IslandOutlineGlow(tint: SessionStatus.waitingForUser.tint)
        let behind = stage.effectsLayer(.behind)
        let before = behind.sublayers?.count ?? 0
        stage.addFollower(glow)
        XCTAssertEqual(behind.sublayers?.count ?? 0, before + 1)
        state.setContent(.expanded, snapshot: fakes.trio)
        advance(1)
        // The glow's line ends on the open island's outline.
        let line = behind.sublayers?.last?.sublayers?.first?.sublayers?.last as? CAShapeLayer
        let box = line?.path?.boundingBoxOfPath ?? .zero
        XCTAssertEqual(Double(box.height), Double(state.geometry.height), accuracy: 0.5)
        stage.removeFollower(glow)
        XCTAssertEqual(behind.sublayers?.count ?? 0, before)
    }

    /// An effect plays in its layer and is removed once it is over.
    func testEffectIsRemovedWhenDone() {
        state.setContent(.collapsed, snapshot: fakes.trio)
        advance(1)
        let layer = stage.effectsLayer(.above)
        let before = layer.sublayers?.count ?? 0
        stage.play(IslandCelebration(tint: SessionStatus.finished.tint))
        XCTAssertEqual(layer.sublayers?.count ?? 0, before + 1)
        advance(2)
        XCTAssertEqual(layer.sublayers?.count ?? 0, before)
    }
}

/// A real click (window events) on a SwiftUI button of a stage page reaches the controller's callback.
@MainActor
final class IslandStageClickTests: XCTestCase {
    func testClickOnCardButtonReachesDecide() throws {
        _ = NSApplication.shared
        let fakes = StageFakes(now: Date())
        let state = IslandViewState()
        let stage = IslandStage(state: state)
        var decided: [(UUID, PermissionDecision)] = []
        state.actions.decide = { id, decision in decided.append((id, decision)) }
        state.jump(to: IslandPreviewRenderer.floating)
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

        // «Разрешить» is the right end of the buttons row, above the footer ("В терминал", "ждёт 0:03"):
        // the card's bottom padding (12), the footer (~16) and its gap (10), then half a button (~17).
        let origin = page.contentOrigin(canvasWidth: canvas.width)
        let local = NSPoint(x: origin.x + page.contentSize.width * 0.82, y: page.contentSize.height - 12 - 16 - 10 - 17)
        // The stage view is flipped and fills the panel.
        let point = stage.view.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                         windowNumber: panel.windowNumber, context: nil,
                                                         eventNumber: 0, clickCount: 1, pressure: 1))
            panel.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(decided.count, 1)
        XCTAssertEqual(decided.first?.0, fakes.claudeCard.id)
        // Before the page is interactive the same click does nothing.
        state.contentInteractive = false
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                         windowNumber: panel.windowNumber, context: nil,
                                                         eventNumber: 0, clickCount: 1, pressure: 1))
            panel.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(decided.count, 1)
        if case .allow = decided.first?.1 {} else { XCTFail("expected allow, got \(String(describing: decided.first?.1))") }
    }
}

extension IslandStageClickTests {
    /// A click on the closed island squishes it and opens the list (the stage view takes it).
    func testClickOnClosedIsland() throws {
        _ = NSApplication.shared
        let fakes = StageFakes(now: Date())
        let state = IslandViewState()
        let stage = IslandStage(state: state)
        var pressed: [Bool] = []
        var tapped = 0
        state.actions.pressClosedIsland = { pressed.append($0) }
        state.actions.tappedClosedIsland = { tapped += 1 }
        state.jump(to: IslandPreviewRenderer.floating)
        let canvas = IslandLayout.canvasSize(state.metrics)
        let panel = IslandPanel()
        panel.contentView = IslandContainerView(host: stage.view)
        panel.setFrame(NSRect(x: -40_000, y: -40_000, width: canvas.width, height: canvas.height), display: false)
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        state.setContent(.collapsed, snapshot: fakes.trio)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let point = stage.view.convert(NSPoint(x: canvas.width / 2, y: 12), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                         windowNumber: panel.windowNumber, context: nil,
                                                         eventNumber: 0, clickCount: 1, pressure: 1))
            panel.sendEvent(event)
        }
        XCTAssertEqual(pressed, [true])
        XCTAssertEqual(tapped, 1)
    }
}
