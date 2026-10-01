import XCTest
@testable import NotchBuddyCore

/// The closed island's arbitration of live activities, widget ids, and whose usage the island shows.
final class IslandActivityTests: XCTestCase {
    func testNothingToShow() {
        XCTAssertNil(IslandActivityArbiter.choose(IslandActivitySignals()))
    }

    /// agent waiting > timer finishing/finished > calendar soon > agents working > music > timer running > battery >
    /// shelf badge > any other session; a file dragged toward the island above all of them.
    func testPriorityOrder() {
        let ladder: [(IslandActivitySignals, IslandActivityKind)] = [
            (IslandActivitySignals(agentPresent: true), .agents),
            (IslandActivitySignals(agentPresent: true, shelfBadge: true), .shelf),
            (IslandActivitySignals(agentPresent: true, batteryLow: true, shelfBadge: true), .system),
            (IslandActivitySignals(agentPresent: true, timerRunning: true, batteryLow: true, shelfBadge: true), .timer),
            (IslandActivitySignals(agentPresent: true, musicPlaying: true, timerRunning: true, batteryLow: true), .music),
            (IslandActivitySignals(agentBusy: true, agentPresent: true, musicPlaying: true, timerRunning: true), .agents),
            (IslandActivitySignals(agentBusy: true, calendarSoon: true, musicPlaying: true), .calendar),
            (IslandActivitySignals(agentBusy: true, timerUrgent: true, calendarSoon: true), .timer),
            (IslandActivitySignals(agentWaiting: true, timerUrgent: true, calendarSoon: true), .agents),
            (IslandActivitySignals(agentWaiting: true, timerUrgent: true, shelfDrag: true), .shelfDrag),
        ]
        for (signals, expected) in ladder {
            XCTAssertEqual(IslandActivityArbiter.choose(signals), expected, "\(signals)")
        }
    }

    func testActivityOpensItsWidget() {
        XCTAssertEqual(IslandActivityKind.shelfDrag.widget, .shelf)
        XCTAssertEqual(IslandActivityKind.system.widget, .system)
        XCTAssertEqual(IslandActivityKind.agents.widget, .agents)
    }

    func testWidgetPageIDs() {
        XCTAssertNil(WidgetKind.agents.pageID)
        for kind in WidgetKind.allCases where kind != .agents {
            XCTAssertEqual(WidgetKind(pageID: kind.pageID!), kind)
        }
        XCTAssertNil(WidgetKind(pageID: "settings"))
        XCTAssertNil(WidgetKind(pageID: "widget.agents"))
        XCTAssertNil(WidgetKind(pageID: "widget.weather"))
        XCTAssertEqual(WidgetKind(storedName: "nowPlaying"), .music)
        XCTAssertNil(WidgetKind(storedName: "usage"))
    }

    func testUsageChoiceCycles() {
        XCTAssertEqual(UsageProviderChoice.auto.next, .claude)
        XCTAssertEqual(UsageProviderChoice.claude.next, .codex)
        XCTAssertEqual(UsageProviderChoice.codex.next, .kimi)
        XCTAssertEqual(UsageProviderChoice.kimi.next, .auto)
    }

    private let usages: [AgentUsage] = [
        .claude(fiveHour: (42, nil), sevenDay: (18, nil), fetchedAt: Date()),
        AgentUsage(agent: .codex, windows: [AgentUsageWindow(id: "7d", used: 14), AgentUsageWindow(id: "5h", used: 61)],
                   fetchedAt: Date()),
    ]

    /// «Авто» shows one agent: the main session's when it has numbers, else Claude, else whoever has any.
    func testShownAgent() {
        XCTAssertEqual(UsageSelection.shown(usages, choice: .auto, focus: .codex)?.agent, .codex)
        XCTAssertEqual(UsageSelection.shown(usages, choice: .auto, focus: .kimi)?.agent, .claude, "no Kimi numbers: Claude")
        XCTAssertEqual(UsageSelection.shown(usages, choice: .auto, focus: nil)?.agent, .claude)
        XCTAssertEqual(UsageSelection.rows(usages, choice: .auto, focus: .codex).map(\.agent), [.codex])
        XCTAssertEqual(UsageSelection.rows(usages, choice: .codex).map(\.agent), [.codex])
        let kimi = UsageSelection.rows(usages, choice: .kimi)
        XCTAssertEqual(kimi.map(\.agent), [.kimi])
        XCTAssertFalse(kimi[0].hasData, "a placeholder row, so a stale choice visibly went somewhere")
        XCTAssertNil(UsageSelection.shown([], choice: .auto, focus: .claude))
    }

    /// A click skips agents without numbers.
    func testCycleSkipsAgentsWithoutData() {
        XCTAssertEqual(UsageSelection.next(after: .auto, usages: usages), .claude)
        XCTAssertEqual(UsageSelection.next(after: .claude, usages: usages), .codex)
        XCTAssertEqual(UsageSelection.next(after: .codex, usages: usages), .auto, "Kimi has no numbers: skipped")
        XCTAssertEqual(UsageSelection.next(after: .kimi, usages: usages), .auto)
        let onlyKimi = [AgentUsage(agent: .kimi, windows: [AgentUsageWindow(id: "7d", used: 3)], fetchedAt: Date())]
        XCTAssertEqual(UsageSelection.next(after: .auto, usages: onlyKimi), .kimi)
        XCTAssertEqual(UsageSelection.next(after: .auto, usages: []), .auto, "nobody has numbers: stays")
    }

    func testRingFollowsTheChoiceAndTheSessionShown() {
        XCTAssertEqual(UsageSelection.ring(usages, choice: .auto, focus: .codex)?.used, 61, "the 5-hour window first")
        XCTAssertEqual(UsageSelection.ring(usages, choice: .auto, focus: .kimi)?.agent, .claude, "no Kimi numbers: Claude")
        XCTAssertEqual(UsageSelection.ring(usages, choice: .auto, focus: nil)?.used, 42)
        XCTAssertEqual(UsageSelection.ring(usages, choice: .codex, focus: .claude)?.agent, .codex)
        XCTAssertNil(UsageSelection.ring(usages, choice: .kimi, focus: .claude))
        XCTAssertNil(UsageSelection.ring([], choice: .auto, focus: .claude))
    }
}
