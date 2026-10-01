import AppKit
import NotchBuddyCore
import SwiftUI
import XCTest
@testable import NotchBuddy

/// The widgets ("островки") on the stage: the tab strip's page stays while tabs swap under it, tabs slide toward their
/// side, the strip fits beside a notch, swipes switch once per gesture.
@MainActor
final class IslandWidgetsTests: XCTestCase {
    private var state: IslandViewState!
    private var stage: IslandStage!
    private var panel: IslandPanel!
    private var now: CFTimeInterval = 1000
    private var jobs: [(at: CFTimeInterval, body: @MainActor () -> Void)] = []
    private var fakes: StageFakes!
    private var savedHub: WidgetHub!

    private let tabs: [WidgetKind] = [.agents, .timer, .system]

    override func setUp() async throws {
        _ = NSApplication.shared
        savedHub = WidgetHub.shared
        WidgetHub.shared = .preview(tabs: tabs, timer: TimerSystemPreviewRenderer.sampleTimerStore(),
                                    system: TimerSystemPreviewRenderer.sampleSystemMonitor())
        IslandWidgetPages.register()
        fakes = StageFakes(now: Date())
        state = IslandViewState()
        stage = IslandStage(state: state)
        stage.timeline.filming = true
        stage.clock = { [unowned self] in self.now }
        stage.later = { [unowned self] seconds, body in self.jobs.append((self.now + max(0, seconds), body)) }
        state.jump(to: IslandPreviewRenderer.floating)
        let canvas = IslandLayout.canvasSize(state.metrics)
        panel = IslandPanel()
        let container = IslandContainerView(host: stage.view)
        panel.contentView = container
        panel.setFrame(NSRect(x: -40_000, y: -40_000, width: canvas.width, height: canvas.height), display: false)
        panel.ignoresMouseEvents = true
        container.layoutSubtreeIfNeeded()
    }

    override func tearDown() async throws {
        panel.orderOut(nil)
        WidgetHub.shared = savedHub
        IslandLayout.widthScale = 1
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

    /// Without another widget there is no strip; with one, the strip is its own page over the tab's content, and it
    /// stays (the same page, never re-revealed) while the tabs swap under it.
    func testStripStaysWhileTabsSwap() throws {
        state.setContent(.expanded, snapshot: fakes.trio)
        XCTAssertEqual(stage.currentIDs, [.list], "agents only: no strip")
        advance(1)
        state.tabs = tabs
        state.setContent(.expanded, snapshot: fakes.trio)
        XCTAssertEqual(stage.currentIDs, [.tabs, .list])
        advance(1)
        let strip = try XCTUnwrap(stage.pages[.tabs])
        let revealed = strip.revealStart
        state.setContent(.tab(.timer), snapshot: fakes.trio, entrance: .slide(forward: true), exit: .slide(forward: true))
        XCTAssertEqual(stage.currentIDs, [.tabs, .custom("widget.timer")])
        XCTAssertTrue(stage.pages[.tabs] === strip)
        XCTAssertEqual(strip.phase, .live)
        XCTAssertEqual(strip.revealStart, revealed, "the strip is not revealed again")
        XCTAssertEqual(state.activeTab, .timer)
        // The strip draws above the tab under it.
        let views = strip.view.superview?.subviews ?? []
        let content = try XCTUnwrap(stage.pages[.custom("widget.timer")])
        XCTAssertLessThan(try XCTUnwrap(views.firstIndex(of: content.view)), try XCTUnwrap(views.firstIndex(of: strip.view)))
        advance(1)
        // Settings are not a tab: the strip leaves with the tab.
        IslandSettings.register()
        state.setContent(.page(IslandSettings.pageID), snapshot: fakes.trio)
        XCTAssertEqual(stage.currentIDs, [.custom(IslandSettings.pageID)])
        XCTAssertEqual(state.activeTab, .timer, "the strip remembers the tab settings were opened from")
    }

    /// A tab slides toward its side: the old content leaves to the left and is gone by ~70 ms, the new one comes in
    /// from the right after ~40 ms; the two never show at once.
    func testSlideIsDirectionalAndNeverOverlaps() throws {
        state.tabs = tabs
        state.setContent(.expanded, snapshot: fakes.trio)
        advance(1)
        let start = now
        state.setContent(.tab(.system), snapshot: fakes.trio, entrance: .slide(forward: true), exit: .slide(forward: true))
        let old = try XCTUnwrap(stage.pages[.list])
        let new = try XCTUnwrap(stage.pages[.custom("widget.system")])
        var t = 0.0
        while t <= 0.3 {
            let a = old.pose(start + t), b = new.pose(start + t)
            XCTAssertFalse(a.opacity > 0.12 && b.opacity > 0.12, "both visible at \(Int(t * 1000)) ms")
            if t > 0.005, a.opacity > 0.01 { XCTAssertLessThan(a.dx, 0, "the old tab leaves to the left") }
            if b.opacity > 0.01, t < 0.15 { XCTAssertGreaterThan(b.dx, 0, "the new tab comes from the right") }
            t += 1.0 / 120
        }
        XCTAssertLessThan(old.pose(start + 0.075).opacity, 0.02)
        XCTAssertEqual(new.pose(start + 0.5).dx, 0, accuracy: 0.01)
        XCTAssertEqual(new.pose(start + 0.5).opacity, 1, accuracy: 0.01)
        // Backwards: from the left.
        advance(1)
        let back = now
        state.setContent(.expanded, snapshot: fakes.trio, entrance: .slide(forward: false), exit: .slide(forward: false))
        let list = try XCTUnwrap(stage.pages[.list])
        XCTAssertLessThan(list.pose(back + 0.07).dx, 0)
        XCTAssertGreaterThan(new.pose(back + 0.03).dx, 0, "the old tab leaves to the right")
    }

    /// Beside a notch the strip (six tabs) fits its wing at every island size; without a notch the named pill fits.
    func testStripFitsBesideTheNotch() {
        let notched = IslandPreviewRenderer.notched
        let all = WidgetKind.allCases
        for size in IslandSize.allCases {
            IslandLayout.widthScale = CGFloat(size.scale)
            let wing = (IslandLayout.listWidth(notched) - notched.notchWidth) / 2
            for active in all {
                let available = wing - 20
                let style = IslandTabs.style(tabs: all, active: active, available: available)
                let n = CGFloat(all.count)
                let width: CGFloat
                switch style {
                case .labeled: width = 4 + (n - 1) * 2 + n * 26 + 21 + IslandTabs.labelWidth(active)
                case .icons: width = 4 + (n - 1) * 2 + n * 26
                case .compact: width = 4 + n * 22
                }
                XCTAssertLessThanOrEqual(width, available + 0.5, "\(size) \(active) \(style)")
            }
        }
        IslandLayout.widthScale = 1
        XCTAssertEqual(IslandTabs.style(tabs: all, active: .calendar, available: 370), .labeled)
    }

    func testSwipeSwitchesOncePerGesture() {
        var swipe = TabSwipeTracker()
        swipe.begin(owns: true)
        var steps: [Int] = []
        for _ in 0..<20 { steps.append(swipe.add(dx: -6, dy: 0.5)) }
        XCTAssertEqual(steps.filter { $0 != 0 }, [1], "fingers to the left: the next tab, once")
        XCTAssertEqual(swipe.axis, .horizontal)
        swipe.end()
        XCTAssertEqual(swipe.add(dx: -60, dy: 0), 0, "momentum after the fingers lift does not switch again")

        swipe.begin(owns: true)
        XCTAssertEqual((0..<20).map { _ in swipe.add(dx: 5, dy: 0) }.filter { $0 != 0 }, [-1])

        swipe.begin(owns: true)
        XCTAssertEqual((0..<20).map { _ in swipe.add(dx: -2, dy: 8) }.filter { $0 != 0 }, [], "vertical scrolls the content")
        XCTAssertEqual(swipe.axis, .vertical)

        swipe.begin(owns: false)
        XCTAssertEqual((0..<20).map { _ in swipe.add(dx: -6, dy: 0) }.filter { $0 != 0 }, [], "the shelf's row scrolls")
    }

    func testNeighboursAndDirection() {
        XCTAssertEqual(IslandTabs.neighbour(of: .agents, in: tabs, forward: true), .timer)
        XCTAssertNil(IslandTabs.neighbour(of: .agents, in: tabs, forward: false))
        XCTAssertNil(IslandTabs.neighbour(of: .system, in: tabs, forward: true))
        XCTAssertTrue(IslandTabs.isForward(from: .agents, to: .system, in: tabs))
        XCTAssertFalse(IslandTabs.isForward(from: .system, to: .timer, in: tabs))
        XCTAssertEqual(IslandMode.tab(.agents), .expanded)
        XCTAssertEqual(IslandMode.tab(.timer), .page("widget.timer"))
        XCTAssertEqual(IslandMode.page("widget.timer").tab, .timer)
        XCTAssertNil(IslandMode.page("settings").tab)
    }

    /// A widget's live activity has no agent mark to fly; the sessions' pill keeps it.
    func testHeroOnlyForTheAgentsActivity() {
        var snapshot = fakes.trio
        XCTAssertNotNil(IslandViewState.heroKey(for: .collapsed, snapshot, reduce: false))
        snapshot.activity = .music
        XCTAssertNil(IslandViewState.heroKey(for: .collapsed, snapshot, reduce: false))
        snapshot.activity = .agents
        XCTAssertNotNil(IslandViewState.heroKey(for: .collapsed, snapshot, reduce: false))
    }
}
