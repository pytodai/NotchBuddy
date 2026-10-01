import AppKit
import NotchBuddyCore
import XCTest
@testable import NotchBuddy

/// The controller's own handling of the mouse on a dragged «Островок» (`IslandController.filterMouse`): a double click
/// where the capsule sits re-centers it, and a pull on the open island grabs the capsule only when it is clearly one. On a
/// placement of its own (`start(on:)`: a "screen" far from every real one, nothing global installed), its own settings and
/// a pointer the test moves; the hover opens the island on the real clock, as it does for a user with Settings → Остров →
/// «Открывать при наведении» at «Быстро» (the default: the island opens 0.09 s after the pointer rests).
@MainActor
final class IslandControllerTests: XCTestCase {
    private var controller: IslandController?
    private var store: SettingsStore!
    private var defaults: UserDefaults!
    private var suite = ""
    private var pointer = NSPoint.zero
    private var buttons = 0
    private let displayKey = "test-display"
    private var placement: IslandPlacement!

    override func setUp() async throws {
        _ = NSApplication.shared
        suite = "me.sokolov.notchbuddy.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = SettingsStore(defaults: defaults, launchAtLogin: .disabled, observeDefaults: false)
        store.values.hoverOpen = .quick
        store.values.pinOnOpen = false
        // A capsule with nothing running (no sessions to fake).
        store.values.showWithoutSessions = true
        let frame = NSRect(x: -40_000, y: -40_000, width: 1512, height: 982)
        var metrics = IslandMetrics(style: .floating, notchWidth: 0, barHeight: IslandMetrics.floatingBarHeight(menuBar: 24),
                                    menuBarHeight: 24, gap: IslandLayout.islandGap, screenWidth: frame.width)
        metrics.anchorInset = frame.width / 2
        placement = IslandPlacement(displayID: 0x7E57_0001, anchor: CGPoint(x: frame.midX, y: frame.maxY), metrics: metrics,
                                    screenFrame: frame, displayKey: displayKey)
    }

    override func tearDown() async throws {
        controller?.stop()
        controller = nil
        defaults?.removePersistentDomain(forName: suite)
        IslandLayout.widthScale = 1
        IslandLayout.capsuleWidth = CGFloat(NotchSettings.defaultCapsuleWidth)
    }

    /// The island with the capsule kept at `offset` on this display, closed, the pointer away from it.
    private func start(offset: Double) async throws -> IslandController {
        store.values.setIslandOffset(offset, forDisplay: displayKey)
        pointer = NSPoint(x: placement.screenFrame.midX, y: placement.screenFrame.midY)
        let island = IslandController(model: AppModel(jumper: NoJumps(), usageProvider: IslandPerfUsage()),
                                      widgets: .preview(tabs: [.agents]), store: store)
        island.mouseLocation = { [unowned self] in self.pointer }
        island.mouseButtons = { [unowned self] in self.buttons }
        controller = island
        island.start(on: placement)
        try await waitUntil("the capsule") { island.testMode == .collapsed }
        return island
    }

    /// The pointer comes to rest on the closed capsule: the hover opens the island.
    private func hoverOpen(_ island: IslandController) async throws {
        pointer = try XCTUnwrap(island.testCapsuleCenter)
        island.testPointerMoved()
        try await waitUntil("the hover to open the island") { island.testMode.isOpen }
        XCTAssertEqual(island.testOpenState.opener, .hover)
    }

    private func mouse(_ type: NSEvent.EventType, clicks: Int = 1, _ island: IslandController) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: island.perfWindowNumber,
                                         context: nil, eventNumber: 0, clickCount: clicks,
                                         pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func waitUntil(_ what: String, timeout: Double = 3, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < end else {
                XCTFail("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The capsule moved aside: the pointer rests on it, the hover opens the island long before a double click is done,
    /// and the double click — both clicks on the open island where the capsule sits — re-centers it: the second press and
    /// its mouse-up are swallowed, the island closes as the capsule slides home, and the place is kept.
    func testDoubleClickRecentersACapsuleTheHoverOpened() async throws {
        let island = try await start(offset: -600)
        XCTAssertEqual(try XCTUnwrap(island.testCapsuleCenter).x, placement.anchor.x - 600)
        try await hoverOpen(island)

        buttons = 1
        XCTAssertFalse(island.filterMouse(try mouse(.leftMouseDown, island)), "the first click is the content's")
        buttons = 0
        XCTAssertFalse(island.filterMouse(try mouse(.leftMouseUp, island)))
        buttons = 1
        XCTAssertTrue(island.filterMouse(try mouse(.leftMouseDown, clicks: 2, island)), "the second press re-centers")
        buttons = 0
        XCTAssertTrue(island.filterMouse(try mouse(.leftMouseUp, clicks: 2, island)), "its mouse-up is swallowed too")

        XCTAssertEqual(island.testIslandOffset, 0)
        XCTAssertEqual(store.values.islandOffset(forDisplay: displayKey), 0, "kept for this display")
        XCTAssertFalse(island.testMode.isOpen, "the island closes as the capsule slides home")
        try await waitUntil("the capsule to get home") { abs(island.testPresentedShift ?? .infinity) < 0.5 }
        XCTAssertFalse(island.testMode.isOpen, "and stays closed")
        // The next click goes through again.
        buttons = 1
        XCTAssertFalse(island.filterMouse(try mouse(.leftMouseDown, island)))
        buttons = 0
        XCTAssertFalse(island.filterMouse(try mouse(.leftMouseUp, island)))
    }

    /// A capsule already at the center: its double click stays two clicks (nothing swallowed, nothing closes: no blip).
    func testDoubleClickOnACenteredCapsuleIsTwoClicks() async throws {
        let island = try await start(offset: 0)
        try await hoverOpen(island)
        for clicks in [1, 2] {
            buttons = 1
            XCTAssertFalse(island.filterMouse(try mouse(.leftMouseDown, clicks: clicks, island)))
            buttons = 0
            XCTAssertFalse(island.filterMouse(try mouse(.leftMouseUp, clicks: clicks, island)))
        }
        XCTAssertTrue(island.testMode.isOpen)
        XCTAssertEqual(island.testIslandOffset, 0)
    }

    /// The hover opened the island over a capsule at the left edge (the open island sits further in). A press there that
    /// drifts 8 pt is still a click on what is under it; a clear pull grabs the capsule: the island folds back into it,
    /// drawn where it was at the grab (no jump), and the fold brings it under the pointer.
    func testGrabNeedsAClearPullAndStartsWhereTheIslandIsDrawn() async throws {
        let island = try await start(offset: -2000)
        let capsule = try XCTUnwrap(island.testCapsuleCenter).x - placement.anchor.x
        try await hoverOpen(island)
        try await Task.sleep(for: .milliseconds(700))
        let drawn = try XCTUnwrap(island.testPresentedShift)
        XCTAssertGreaterThan(drawn, capsule + 100, "the open island sits further in than its capsule")

        buttons = 1
        XCTAssertFalse(island.filterMouse(try mouse(.leftMouseDown, island)))
        pointer.x += 8
        XCTAssertFalse(island.filterMouse(try mouse(.leftMouseDragged, island)), "8 pt: still a click")
        XCTAssertTrue(island.testMode.isOpen)
        XCTAssertFalse(island.testDragging)
        pointer.x += 6
        let grabbedAt = CACurrentMediaTime()
        XCTAssertTrue(island.filterMouse(try mouse(.leftMouseDragged, island)), "14 pt sideways: the capsule is grabbed")
        XCTAssertFalse(island.testMode.isOpen, "the island folds back into its capsule")
        XCTAssertTrue(island.testDragging)
        // What the island is drawn on from the grab on starts where it was drawn (the fold, carried on around the drag),
        // and a moment later it is still on its way there, not already at the capsule.
        XCTAssertEqual(try XCTUnwrap(island.testPresentedShift(at: grabbedAt)), drawn, accuracy: 3, "drawn where it was: no jump")
        let now = try XCTUnwrap(island.testPresentedShift)
        XCTAssertLessThan(abs(now - drawn), abs(now - capsule), "the fold carries it from there")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(try XCTUnwrap(island.testPresentedShift), capsule, accuracy: 2, "the fold brought it to the pointer")
        // 114 pt from the press: the drag's lag has played out, the capsule follows the pointer 1:1.
        pointer.x += 100
        XCTAssertTrue(island.filterMouse(try mouse(.leftMouseDragged, island)))
        XCTAssertEqual(try XCTUnwrap(island.testPresentedShift), capsule + 114, accuracy: 1, "it follows the pointer")
        buttons = 0
        XCTAssertTrue(island.filterMouse(try mouse(.leftMouseUp, island)))
        XCTAssertFalse(island.testDragging)
        XCTAssertEqual(store.values.islandOffset(forDisplay: displayKey), Double(capsule + 114), accuracy: 1,
                       "dropped there, kept for this display")
    }
}

private struct NoJumps: TerminalJumping {
    func jump(to session: AgentSession) -> Bool { false }
}
