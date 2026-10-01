import XCTest
@testable import NotchBuddyCore

final class UsageModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testWindowIDsAndLabels() {
        XCTAssertEqual(AgentUsageWindow.id(minutes: 300), "5h")
        XCTAssertEqual(AgentUsageWindow.id(minutes: 10080), "7d")
        XCTAssertEqual(AgentUsageWindow.id(minutes: 43200), "month")
        XCTAssertEqual(AgentUsageWindow.id(minutes: 120), "120min")
        XCTAssertEqual(AgentUsageWindow.label(forID: "5h"), "5 часов")
        XCTAssertEqual(AgentUsageWindow.label(forID: "7d"), "Неделя")
        XCTAssertEqual(AgentUsageWindow.label(forID: "month"), "Месяц")
        XCTAssertEqual(AgentUsageWindow.label(forID: "120min"), "2\u{00A0}ч")
        XCTAssertEqual(AgentUsageWindow.label(forID: "2880min"), "2\u{00A0}дн")
        XCTAssertEqual(AgentUsageWindow.label(forID: "45min"), "45\u{00A0}мин")
    }

    func testWindowClampsAndSortsByLength() {
        XCTAssertEqual(AgentUsageWindow(id: "5h", used: 140).used, 100)
        XCTAssertEqual(AgentUsageWindow(id: "5h", used: -3).used, 0)
        XCTAssertEqual(AgentUsageWindow(id: "5h", used: .nan).used, 0)
        let usage = AgentUsage(agent: .codex, windows: [AgentUsageWindow(id: "month", used: 1),
                                                        AgentUsageWindow(id: "7d", used: 2),
                                                        AgentUsageWindow(id: "5h", used: 3)], fetchedAt: now)
        XCTAssertEqual(usage.windows.map(\.id), ["5h", "7d", "month"])
        XCTAssertEqual(usage.headline?.id, "5h")
    }

    func testLevels() {
        XCTAssertEqual(AgentUsageLevel(used: 69.9), .calm)
        XCTAssertEqual(AgentUsageLevel(used: 70), .warn)
        XCTAssertEqual(AgentUsageLevel(used: 90), .danger)
        XCTAssertLessThan(AgentUsageLevel.calm, AgentUsageLevel.danger)
    }

    func testEvaluatedRollsOverAndMarksStale() {
        let usage = AgentUsage(agent: .codex,
                               windows: [AgentUsageWindow(id: "5h", used: 80, resetsAt: now.addingTimeInterval(-10)),
                                         AgentUsageWindow(id: "7d", used: 30, resetsAt: now.addingTimeInterval(3600))],
                               fetchedAt: now.addingTimeInterval(-7 * 3600), staleAfter: 6 * 3600, limitReached: true)
        let later = usage.evaluated(at: now)
        XCTAssertEqual(later.window("5h")?.used, 0)
        XCTAssertEqual(later.window("5h")?.didReset, true)
        XCTAssertNil(later.window("5h")?.resetsAt)
        XCTAssertEqual(later.window("7d")?.used, 30)
        XCTAssertEqual(later.window("7d")?.didReset, false)
        XCTAssertTrue(later.stale)
        XCTAssertTrue(later.limitReached, "one window still counts")
        XCTAssertEqual(later.evaluated(at: now), later, "idempotent")

        let allReset = usage.evaluated(at: now.addingTimeInterval(7200))
        XCTAssertFalse(allReset.limitReached)
        XCTAssertFalse(usage.evaluated(at: now.addingTimeInterval(-7 * 3600 + 60)).stale)
    }

    func testClaudeAdapterAndColumns() {
        let claude = AgentUsage.claude(fiveHour: (42, now.addingTimeInterval(600)), sevenDay: (18, nil), fetchedAt: now)
        XCTAssertEqual(claude.windows.map(\.id), ["5h", "7d"])
        XCTAssertEqual(claude.window("5h")?.used, 42)
        XCTAssertEqual(claude.window("5h")?.minutes, 300)
        XCTAssertEqual(AgentUsage.claude(fiveHour: nil, sevenDay: nil, fetchedAt: nil).note, "нет данных")

        let codex = AgentUsage(agent: .codex, windows: [AgentUsageWindow(id: "7d", used: 14)], fetchedAt: now)
        let kimi = AgentUsage(agent: .kimi, windows: [AgentUsageWindow(id: "month", used: 5),
                                                      AgentUsageWindow(id: "5h", used: 1),
                                                      AgentUsageWindow(id: "60min", used: 1)], fetchedAt: now)
        XCTAssertEqual(AgentUsage.columns([codex, kimi, claude]), ["5h", "7d", "month"])
        XCTAssertEqual(AgentUsage.columns([codex]), ["7d"])
        XCTAssertEqual(AgentUsage.columns([kimi], limit: 2), ["5h", "month"])
        XCTAssertEqual(AgentUsage.columns([.unavailable(.kimi, "x")]), [])
    }

    func testCacheRoundTripIsPrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nb-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = AgentUsageCache.url(for: .kimi, runDir: dir)
        XCTAssertEqual(url.lastPathComponent, "kimi-usage.json")
        XCTAssertNil(AgentUsageCache.read(from: url))
        let usage = AgentUsage(agent: .kimi, windows: [AgentUsageWindow(id: "5h", used: 42, resetsAt: now, minutes: 300)],
                               plan: nil, fetchedAt: now, staleAfter: 3600)
        try AgentUsageCache.write(usage, to: url)
        XCTAssertEqual(AgentUsageCache.read(from: url), usage)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}
