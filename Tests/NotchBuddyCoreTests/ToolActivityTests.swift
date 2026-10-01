import XCTest
@testable import NotchBuddyCore

/// The session's recent tool calls (`RecentToolCalls`) and last answer (`lastAgentMessage`).
final class ToolActivityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let key = SessionKey(source: .claude, sessionId: "s1")

    private func event(_ kind: EventKind, at offset: TimeInterval = 0, tool: String? = nil, summary: String? = nil,
                       message: String? = nil, callId: String? = nil, agentId: String? = nil,
                       source: AgentSource = .claude, idKey: String = "tool_use_id") -> AgentEvent {
        var raw: [String: JSONValue] = [:]
        if let callId { raw[idKey] = .string(callId) }
        return AgentEvent(source: source, hookEventName: kind.rawValue, kind: kind, sessionId: "s1",
                          cwd: "/Users/u/proj", toolName: tool, toolSummary: summary, message: message,
                          timestamp: t0.addingTimeInterval(offset), raw: raw.isEmpty ? .null : .object(raw),
                          agentId: agentId)
    }

    private func calls(_ store: SessionStore, _ key: SessionKey? = nil) -> [ToolCall] {
        store.sessions[key ?? self.key]?.recentTools.calls ?? []
    }

    // MARK: Start and finish

    func testPreThenPostRecordsOneSucceededCallWithDuration() {
        var store = SessionStore()
        store.apply(event(.promptSubmitted, message: "go"))
        store.apply(event(.toolWillRun, at: 1, tool: "Bash", summary: "swift build", callId: "t1"))
        XCTAssertEqual(calls(store).map(\.outcome), [.running])
        store.apply(event(.toolDidRun, at: 4.5, tool: "Bash", summary: "swift build", callId: "t1"))
        let call = calls(store).first
        XCTAssertEqual(calls(store).count, 1)
        XCTAssertEqual(call?.outcome, .succeeded)
        XCTAssertEqual(call?.name, "Bash")
        XCTAssertEqual(call?.summary, "swift build")
        XCTAssertEqual(call?.duration ?? -1, 3.5, accuracy: 0.001)
        XCTAssertEqual(call?.startedAt, t0.addingTimeInterval(1))
    }

    func testFailureKeepsTheErrorLine() {
        var store = SessionStore()
        store.apply(event(.toolWillRun, tool: "Bash", summary: "npm test", callId: "t1"))
        store.apply(event(.toolFailed, at: 2, tool: "Bash", summary: "npm test", message: "exit 1:\n  3 failing",
                          callId: "t1"))
        XCTAssertEqual(calls(store).map(\.outcome), [.failed])
        XCTAssertEqual(calls(store).first?.error, "exit 1: 3 failing")
        XCTAssertEqual(store.sessions[key]?.recentTools.failures, 1)
    }

    func testResultsMatchByNameAndSummaryWithoutIds() {
        var store = SessionStore()
        store.apply(event(.toolWillRun, tool: "Read", summary: "a.swift"))
        store.apply(event(.toolWillRun, at: 0.1, tool: "Read", summary: "b.swift"))
        store.apply(event(.toolDidRun, at: 0.5, tool: "Read", summary: "a.swift"))
        XCTAssertEqual(calls(store).map(\.summary), ["a.swift", "b.swift"])
        XCTAssertEqual(calls(store).map(\.outcome), [.succeeded, .running])
    }

    func testParallelCallsOfTheSameCommandMatchTheirOwnIds() {
        var store = SessionStore()
        store.apply(event(.toolWillRun, tool: "Bash", summary: "ls", callId: "a"))
        store.apply(event(.toolWillRun, at: 0.1, tool: "Bash", summary: "ls", callId: "b"))
        store.apply(event(.toolFailed, at: 0.5, tool: "Bash", summary: "ls", message: "boom", callId: "b"))
        XCTAssertEqual(calls(store).map(\.callId), ["a", "b"])
        XCTAssertEqual(calls(store).map(\.outcome), [.running, .failed])
    }

    func testKimiToolCallIdIsUsed() {
        var store = SessionStore()
        let kimi = SessionKey(source: .kimi, sessionId: "s1")
        store.apply(event(.toolWillRun, tool: "Bash", summary: "ls", callId: "k1", source: .kimi, idKey: "tool_call_id"))
        store.apply(event(.toolDidRun, at: 1, tool: "Bash", summary: "ls", callId: "k1", source: .kimi,
                          idKey: "tool_call_id"))
        XCTAssertEqual(calls(store, kimi).map(\.callId), ["k1"])
        XCTAssertEqual(calls(store, kimi).map(\.outcome), [.succeeded])
    }

    func testPermissionRequestForARunningCallAddsNothing() {
        var store = SessionStore()
        store.apply(event(.toolWillRun, tool: "Bash", summary: "rm -rf build", callId: "t1"))
        // Codex's PermissionRequest carries no tool_use_id.
        store.apply(event(.permissionRequest, at: 0.2, tool: "Bash", summary: "rm -rf build"))
        XCTAssertEqual(calls(store).count, 1)
        store.apply(event(.toolDidRun, at: 3, tool: "Bash", summary: "rm -rf build", callId: "t1"))
        XCTAssertEqual(calls(store).map(\.outcome), [.succeeded])
    }

    func testPermissionRequestWithoutAStartIsACall() {
        var store = SessionStore()
        store.apply(event(.permissionRequest, tool: "Write", summary: "notes.md"))
        XCTAssertEqual(calls(store).map(\.outcome), [.running])
        XCTAssertEqual(store.sessions[key]?.status, .waitingForUser)
    }

    func testResultWithoutStartIsAnInstantCall() {
        var store = SessionStore()
        store.apply(event(.toolDidRun, at: 2, tool: "Grep", summary: "TODO"))
        XCTAssertEqual(calls(store).map(\.outcome), [.succeeded])
        XCTAssertEqual(calls(store).first?.duration, 0)
    }

    func testDuplicateResultChangesNothing() {
        var store = SessionStore()
        store.apply(event(.toolWillRun, tool: "Bash", summary: "ls", callId: "t1"))
        store.apply(event(.toolDidRun, at: 1, tool: "Bash", summary: "ls", callId: "t1"))
        let before = store
        store.apply(event(.toolFailed, at: 2, tool: "Bash", summary: "ls", message: "late", callId: "t1"))
        XCTAssertEqual(store.sessions[key]?.recentTools, before.sessions[key]?.recentTools)
    }

    // MARK: Out of order

    func testResultOvertakingItsStartIsNotDuplicated() {
        var store = SessionStore()
        store.apply(event(.promptSubmitted, message: "go"))
        // With an id: the late start is recognised.
        store.apply(event(.toolDidRun, at: 2, tool: "Bash", summary: "ls", callId: "t1"))
        store.apply(event(.toolWillRun, at: 1, tool: "Bash", summary: "ls", callId: "t1"))
        // Without one: an older start whose result is already here is dropped.
        store.apply(event(.toolDidRun, at: 4, tool: "Read", summary: "a.swift"))
        store.apply(event(.toolWillRun, at: 3, tool: "Read", summary: "a.swift"))
        XCTAssertEqual(calls(store).map(\.name), ["Bash", "Read"])
        XCTAssertEqual(calls(store).map(\.outcome), [.succeeded, .succeeded])
    }

    func testLateStartIsInsertedInStartOrder() {
        var store = SessionStore()
        store.apply(event(.toolWillRun, at: 2, tool: "Grep", summary: "b", callId: "b"))
        store.apply(event(.toolWillRun, at: 1, tool: "Read", summary: "a", callId: "a"))
        XCTAssertEqual(calls(store).map(\.callId), ["a", "b"])
        XCTAssertEqual(store.sessions[key]?.recentTools.latest?.callId, "b")
        XCTAssertEqual(store.sessions[key]?.recentTools.newestFirst.map(\.callId), ["b", "a"])
    }

    // MARK: Turns

    func testStopAbandonsCallsLeftRunningAndALateResultStillLands() {
        var store = SessionStore()
        store.apply(event(.promptSubmitted, message: "go"))
        store.apply(event(.toolWillRun, at: 1, tool: "Bash", summary: "sleep 1", callId: "t1"))
        store.apply(event(.stop, at: 3, message: "done"))
        XCTAssertEqual(calls(store).map(\.outcome), [.abandoned])
        store.apply(event(.toolDidRun, at: 2, tool: "Bash", summary: "sleep 1", callId: "t1"))
        XCTAssertEqual(calls(store).map(\.outcome), [.succeeded])
    }

    func testMainThreadStopLeavesSubagentCallsRunning() {
        var store = SessionStore()
        store.apply(event(.toolWillRun, at: 1, tool: "Bash", summary: "main", callId: "m"))
        store.apply(event(.toolWillRun, at: 1.5, tool: "Read", summary: "sub", callId: "s", agentId: "agent-1"))
        store.apply(event(.stop, at: 3, message: "done"))
        XCTAssertEqual(calls(store).map(\.outcome), [.abandoned, .running])
        XCTAssertEqual(calls(store).last?.agentId, "agent-1")
        store.apply(event(.subagentStop, at: 4, agentId: "agent-1"))
        XCTAssertEqual(calls(store).map(\.outcome), [.abandoned, .abandoned])
    }

    func testInterruptAndErrorAbandonEveryThread() {
        for kind in [EventKind.interrupted, .stopFailed] {
            var store = SessionStore()
            store.apply(event(.toolWillRun, at: 1, tool: "Bash", summary: "main", callId: "m"))
            store.apply(event(.toolWillRun, at: 1.5, tool: "Read", summary: "sub", callId: "s", agentId: "agent-1"))
            store.apply(event(kind, at: 2, message: "stopped"))
            XCTAssertEqual(calls(store).map(\.outcome), [.abandoned, .abandoned], "\(kind)")
        }
    }

    func testNewPromptAbandonsTheLastTurnsCallsButKeepsTheHistory() {
        var store = SessionStore()
        store.apply(event(.promptSubmitted, message: "one"))
        store.apply(event(.toolWillRun, at: 1, tool: "Bash", summary: "ls"))
        store.apply(event(.toolWillRun, at: 2, tool: "Read", summary: "a", callId: "r"))
        store.apply(event(.toolDidRun, at: 2.5, tool: "Read", summary: "a", callId: "r"))
        store.apply(event(.promptSubmitted, at: 5, message: "two"))
        XCTAssertEqual(calls(store).map(\.outcome), [.abandoned, .succeeded])
        // The same command in the new turn is a new call, not the abandoned one.
        store.apply(event(.toolWillRun, at: 6, tool: "Bash", summary: "ls"))
        XCTAssertEqual(calls(store).map(\.outcome), [.abandoned, .succeeded, .running])
    }

    // MARK: Ring

    func testRingKeepsTheNewestCallsWithStableIds() {
        var store = SessionStore()
        let capacity = RecentToolCalls.defaultCapacity
        for i in 0..<(capacity + 5) {
            store.apply(event(.toolWillRun, at: Double(i), tool: "Read", summary: "f\(i)", callId: "c\(i)"))
            store.apply(event(.toolDidRun, at: Double(i) + 0.5, tool: "Read", summary: "f\(i)", callId: "c\(i)"))
        }
        let kept = calls(store)
        XCTAssertEqual(kept.count, capacity)
        XCTAssertEqual(kept.first?.summary, "f5")
        XCTAssertEqual(kept.last?.summary, "f\(capacity + 4)")
        XCTAssertEqual(Set(kept.map(\.id)).count, capacity, "ids stay unique after old calls fall off")
        XCTAssertEqual(kept.map(\.id), kept.map(\.id).sorted())
    }

    func testRingDirectCapacity() {
        var ring = RecentToolCalls(capacity: 2)
        let m = Moment.wallOnly(t0)
        ring.start(name: "A", summary: nil, callId: "1", agentId: nil, at: m)
        ring.start(name: "B", summary: nil, callId: "2", agentId: nil, at: m.advanced(by: 1))
        ring.start(name: "C", summary: nil, callId: "3", agentId: nil, at: m.advanced(by: 2))
        XCTAssertEqual(ring.calls.map(\.name), ["B", "C"])
        XCTAssertEqual(ring.running.count, 2)
        // A result for a call that fell off is recorded as a new instant call.
        ring.finish(name: "A", summary: nil, callId: "1", agentId: nil, at: m.advanced(by: 3), success: true)
        XCTAssertEqual(ring.calls.map(\.name), ["C", "A"])
    }

    func testWallClockShiftMovesToolTimes() {
        var store = SessionStore()
        store.apply(event(.toolWillRun, at: 1, tool: "Bash", summary: "ls", callId: "t1"))
        store.apply(event(.toolDidRun, at: 2, tool: "Bash", summary: "ls", callId: "t1"))
        store.shiftWallClock(by: 3600)
        let call = calls(store).first
        XCTAssertEqual(call?.startedAt, t0.addingTimeInterval(3601))
        XCTAssertEqual(call?.finishedAt, t0.addingTimeInterval(3602))
        XCTAssertEqual(call?.duration ?? -1, 1, accuracy: 0.001, "durations run on the monotonic clock")
    }

    func testToolEventsChangeWhatTheIslandDraws() {
        var store = SessionStore()
        store.apply(event(.toolWillRun, tool: "Bash", summary: "ls", callId: "t1"))
        let before = store.sessions[key]!
        store.apply(event(.toolDidRun, at: 1, tool: "Bash", summary: "ls", callId: "t1"))
        XCTAssertFalse(store.sessions[key]!.looksTheSame(as: before), "a result re-renders the card's timeline")
    }

    // MARK: Last answer

    func testLastAgentMessageKeepsLinesAndClearsOnNewPrompt() {
        var store = SessionStore()
        store.apply(event(.promptSubmitted, message: "fix"))
        // Claude's adapter sends it as one line with " ⏎ " marks.
        store.apply(event(.stop, at: 2, message: "Готово: ⏎ всё исправлено"))
        XCTAssertEqual(store.sessions[key]?.lastAgentMessage, "Готово:\nвсё исправлено")
        XCTAssertEqual(store.sessions[key]?.lastMessage, "Готово: ⏎ всё исправлено")
        store.apply(event(.promptSubmitted, at: 5, message: "more"))
        XCTAssertNil(store.sessions[key]?.lastAgentMessage)
    }

    func testLastAgentMessageIsCappedAndIgnoresSubagentsAndBlankAnswers() {
        var store = SessionStore()
        store.apply(event(.stop, at: 1, message: String(repeating: "а", count: 5000)))
        let kept = store.sessions[key]?.lastAgentMessage ?? ""
        XCTAssertEqual(kept.count, AgentSession.maxAgentMessageLength)
        XCTAssertTrue(kept.hasSuffix("…"))
        store.apply(event(.stop, at: 2, message: "subagent report", agentId: "agent-1"))
        XCTAssertEqual(store.sessions[key]?.lastAgentMessage, kept)
        store.apply(event(.stop, at: 3, message: "   "))
        XCTAssertEqual(store.sessions[key]?.lastAgentMessage, kept)
    }

    func testOutOfOrderOlderStopDoesNotReplaceTheAnswer() {
        var store = SessionStore()
        store.apply(event(.stop, at: 5, message: "newer"))
        store.apply(event(.stop, at: 4, message: "older"))
        XCTAssertEqual(store.sessions[key]?.lastAgentMessage, "newer")
    }
}
