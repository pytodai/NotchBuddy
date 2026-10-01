import XCTest
@testable import NotchBuddyCore

final class UsageCodexTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nb-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Lines

    private func line(ts: String = "2026-09-21T17:24:40.507Z", limitID: String? = "codex", primary: String,
                      secondary: String = "null", plan: String = "\"plus\"", reached: String = "null") -> String {
        let id = limitID.map { "\"limit_id\":\"\($0)\"," } ?? ""
        return #"{"timestamp":"\#(ts)","ordinal":45,"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{\#(id)"limit_name":null,"primary":\#(primary),"secondary":\#(secondary),"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"spend_control_reached":null,"plan_type":\#(plan),"rate_limit_reached_type":\#(reached)}}}"#
    }

    private let weekly = #"{"used_percent":14.0,"window_minutes":10080,"resets_at":1790508279}"#
    private let fiveHour = #"{"used_percent":37.5,"window_minutes":300,"resets_at":1790400000}"#

    func testParsesWeeklyOnlyPlan() throws {
        let parsed = try XCTUnwrap(CodexRateLimits.parse(line: Data(line(primary: weekly).utf8)))
        XCTAssertEqual(parsed.limitId, "codex")
        XCTAssertEqual(parsed.windows.count, 1)
        XCTAssertEqual(parsed.weekly?.usedPercent, 14)
        XCTAssertEqual(parsed.weekly?.resetsAt, Date(timeIntervalSince1970: 1_790_508_279))
        XCTAssertNil(parsed.fiveHour)
        XCTAssertEqual(parsed.planType, "plus")
        XCTAssertEqual(parsed.creditsBalance, "0")
        XCTAssertEqual(parsed.capturedAt, UsageResponse.parseDate("2026-09-21T17:24:40.507Z"))
    }

    func testParsesFiveHourAndWeekAndOldShapes() throws {
        let both = try XCTUnwrap(CodexRateLimits.parse(line: Data(line(limitID: nil, primary: fiveHour, secondary: weekly,
                                                                          plan: "null").utf8)))
        XCTAssertEqual(both.limitId, "codex", "a missing limit_id is Codex's own default")
        XCTAssertEqual(both.fiveHour?.usedPercent, 37.5)
        XCTAssertEqual(both.weekly?.usedPercent, 14)
        XCTAssertNil(both.planType)

        // Pre-0.40 CLIs: relative reset.
        let relative = try XCTUnwrap(CodexRateLimits.parse(line: Data(line(
            primary: #"{"used_percent":120,"window_minutes":300,"resets_in_seconds":600}"#).utf8)))
        XCTAssertEqual(relative.fiveHour?.usedPercent, 100, "clamped")
        XCTAssertEqual(relative.fiveHour?.resetsAt, relative.capturedAt.addingTimeInterval(600))
    }

    func testRejectsLinesWithoutWindows() {
        XCTAssertNil(CodexRateLimits.parse(line: Data(line(limitID: "premium", primary: "null").utf8)))
        XCTAssertNil(CodexRateLimits.parse(line: Data(#"{"timestamp":"2026-09-21T17:24:40.507Z","type":"event_msg","payload":{"type":"agent_message","message":"hi"}}"#.utf8)))
        XCTAssertNil(CodexRateLimits.parse(line: Data(#"{"timestamp":"2026-09-21T17:24:40.507Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":null}}"#.utf8)))
        XCTAssertNil(CodexRateLimits.parse(line: Data(#"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":1}}}}"#.utf8)), "no timestamp")
        XCTAssertNil(CodexRateLimits.parse(line: Data("{\"timestamp\":\"2026-09-21T17:24".utf8)), "partial line")
    }

    func testAgentUsageMapping() throws {
        let parsed = try XCTUnwrap(CodexRateLimits.parse(line: Data(line(primary: fiveHour, secondary: weekly, plan: "\"pro\"",
                                                                          reached: "\"rate_limit_reached\"").utf8)))
        let captured = parsed.capturedAt
        let fresh = parsed.agentUsage(now: captured.addingTimeInterval(60))
        XCTAssertEqual(fresh.agent, .codex)
        XCTAssertEqual(fresh.windows.map(\.id), ["5h", "7d"])
        XCTAssertEqual(fresh.windows.map(\.label), ["5 часов", "Неделя"])
        XCTAssertEqual(fresh.plan, "Pro")
        XCTAssertTrue(fresh.limitReached)
        XCTAssertFalse(fresh.stale)
        XCTAssertEqual(fresh.fetchedAt, captured)

        let old = parsed.agentUsage(now: captured.addingTimeInterval(7 * 3600))
        XCTAssertTrue(old.stale)

        let afterReset = parsed.agentUsage(now: Date(timeIntervalSince1970: 1_790_600_000))
        XCTAssertEqual(afterReset.windows.map(\.used), [0, 0])
        XCTAssertTrue(afterReset.windows.allSatisfy(\.didReset))
        XCTAssertFalse(afterReset.limitReached)

        XCTAssertNil(CodexRateLimits.planLabel("free"))
        XCTAssertEqual(CodexRateLimits.planLabel("business"), "Business")
    }

    // MARK: Tail

    private func write(_ lines: [String], name: String = "rollout-2026-09-21T20-21-56-x.jsonl", trailingNewline: Bool = true,
                       in folder: URL? = nil) throws -> URL {
        let url = (folder ?? dir).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).utf8).write(to: url)
        return url
    }

    func testTailFindsNewestMainBucketPastOtherBuckets() throws {
        let other = line(ts: "2026-09-21T17:30:00.000Z", limitID: "codex_bengalfox", primary: fiveHour)
        let url = try write([
            line(ts: "2026-09-21T17:00:00.000Z", primary: #"{"used_percent":5,"window_minutes":10080,"resets_at":1}"#),
            line(ts: "2026-09-21T17:10:00.000Z", primary: weekly),
            #"{"timestamp":"2026-09-21T17:20:00.000Z","type":"response_item","payload":{"type":"message"}}"#,
            other, other,
        ])
        let found = CodexRollouts.readTail(of: url)
        XCTAssertEqual(found["codex"]?.weekly?.usedPercent, 14, "the newest codex line, not the older one")
        XCTAssertEqual(found["codex_bengalfox"]?.fiveHour?.usedPercent, 37.5)
    }

    func testTailSkipsAPartialLastLine() throws {
        let complete = line(ts: "2026-09-21T17:10:00.000Z", primary: weekly)
        let partial = String(line(ts: "2026-09-21T17:20:00.000Z", primary: fiveHour).prefix(120))
        let url = try write([complete, partial], trailingNewline: false)
        XCTAssertEqual(CodexRollouts.readTail(of: url)["codex"]?.weekly?.usedPercent, 14)
    }

    func testTailGrowsPastHugeLines() throws {
        let huge = #"{"timestamp":"2026-09-21T17:20:00.000Z","type":"response_item","payload":{"blob":""# +
            String(repeating: "x", count: 300_000) + #""}}"#
        let url = try write([line(primary: weekly), huge])
        XCTAssertEqual(CodexRollouts.readTail(of: url, initialBytes: 1024)["codex"]?.weekly?.usedPercent, 14)
        XCTAssertTrue(CodexRollouts.readTail(of: url, initialBytes: 1024, maxBytes: 4096).isEmpty, "capped")
    }

    func testTailOfFilesWithoutRateLimits() throws {
        XCTAssertTrue(CodexRollouts.readTail(of: try write([#"{"type":"session_meta"}"#], name: "rollout-a.jsonl")).isEmpty)
        XCTAssertTrue(CodexRollouts.readTail(of: try write([], name: "rollout-b.jsonl", trailingNewline: false)).isEmpty)
        XCTAssertTrue(CodexRollouts.readTail(of: dir.appendingPathComponent("missing.jsonl")).isEmpty)
    }

    // MARK: Discovery

    func testNewestByModificationTimeNotPath() throws {
        let sessions = dir.appendingPathComponent("sessions")
        let resumed = try write([line(primary: weekly)], name: "rollout-2026-08-06T00-08-41-a.jsonl",
                                in: sessions.appendingPathComponent("2026/08/06"))
        let newer = try write([line(primary: weekly)], name: "rollout-2026-09-01T10-00-00-b.jsonl",
                              in: sessions.appendingPathComponent("2026/09/01"))
        _ = try write(["{}"], name: "auto-review-rollout-2026-09-02.jsonl", in: sessions.appendingPathComponent("2026/09/02"))
        _ = try write(["{}"], name: "rollout-2026-07-01T00-00-00-c.jsonl.zst", in: sessions.appendingPathComponent("2026/07/01"))
        let fm = FileManager.default
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_790_000_000)], ofItemAtPath: newer.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_790_100_000)], ofItemAtPath: resumed.path)

        let newest = CodexRollouts.newest(in: sessions)
        XCTAssertEqual(newest.map(\.url.lastPathComponent), [resumed.lastPathComponent, newer.lastPathComponent])
        XCTAssertEqual(CodexRollouts.newest(in: sessions, limit: 1).count, 1)
        XCTAssertTrue(CodexRollouts.newest(in: dir.appendingPathComponent("nope")).isEmpty)
    }

    func testCodexHomeResolution() {
        let home = URL(fileURLWithPath: "/Users/u", isDirectory: true)
        XCTAssertEqual(CodexHome.resolve(environment: [:], home: home).path, "/Users/u/.codex")
        XCTAssertEqual(CodexHome.resolve(environment: ["CODEX_HOME": "/opt/cx"], home: home).path, "/opt/cx")
        XCTAssertEqual(CodexHome.resolve(environment: ["CODEX_HOME": "/opt/cx"],
                                         transcriptPath: "/data/cx/sessions/2026/09/21/rollout-2026-09-21T20-21-56-x.jsonl",
                                         home: home).path, "/data/cx")
        XCTAssertNil(CodexHome.root(ofTranscript: "/Users/u/.claude/projects/x/abc.jsonl"))
        XCTAssertNil(CodexHome.root(ofTranscript: "/tmp/rollout-x.jsonl"))
        XCTAssertEqual(CodexHome.sessions(home).path, "/Users/u/sessions")
    }
}
