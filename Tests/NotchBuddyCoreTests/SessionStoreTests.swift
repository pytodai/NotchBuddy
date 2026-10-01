import XCTest
@testable import NotchBuddyCore

final class SessionStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private let key = SessionKey(source: .claude, sessionId: "s1")

    private func event(_ kind: EventKind, session: String = "s1", cwd: String? = "/Users/u/proj", at offset: TimeInterval = 0,
                       message: String? = nil, toolName: String? = nil, toolSummary: String? = nil,
                       decisionSupported: Bool = false, source: AgentSource = .claude, agentId: String? = nil,
                       host: HostContext = HostContext(), raw: JSONValue = .null,
                       transcriptPath: String? = nil, sessionTitle: String? = nil) -> AgentEvent {
        AgentEvent(source: source, hookEventName: kind.rawValue, kind: kind, sessionId: session, cwd: cwd,
                   toolName: toolName, toolSummary: toolSummary, message: message, decisionSupported: decisionSupported,
                   timestamp: t0.addingTimeInterval(offset), host: host, raw: raw, agentId: agentId,
                   transcriptPath: transcriptPath, sessionTitle: sessionTitle)
    }

    func testPromptThenStopFinishesAndFlashes() {
        var store = SessionStore()
        XCTAssertEqual(store.apply(event(.promptSubmitted, message: "fix it")), [])
        XCTAssertEqual(store.sessions.values.first?.status, .working)
        let effects = store.apply(event(.stop, at: 5, message: "Готово:\nвсё исправлено"))
        let key = SessionKey(source: .claude, sessionId: "s1")
        XCTAssertEqual(effects, [.finished(key)])
        XCTAssertEqual(store.sessions[key]?.status, .finished)
        XCTAssertEqual(store.sessions[key]?.lastMessage, "Готово: ⏎ всё исправлено")
        // Until the agent names the chat, its first prompt is the title and the folder the project.
        XCTAssertEqual(store.sessions[key]?.title, "fix it")
        XCTAssertEqual(store.sessions[key]?.projectName, "proj")
    }

    func testFirstCwdNamesTheSession() {
        var store = SessionStore()
        store.apply(event(.sessionStart, cwd: "/Users/u/proj"))
        store.apply(event(.toolWillRun, cwd: "/Users/u/proj/sub", at: 1, toolName: "Bash"))
        XCTAssertEqual(store.sessions.values.first?.cwd, "/Users/u/proj")
        XCTAssertEqual(store.sessions.values.first?.title, "proj")
    }

    func testCwdFilledWhenFirstEventHasNone() {
        var store = SessionStore()
        store.apply(event(.toolWillRun, cwd: nil, toolName: "Bash"))
        store.apply(event(.toolDidRun, cwd: "/Users/u/late", at: 1, toolName: "Bash"))
        XCTAssertEqual(store.sessions.values.first?.cwd, "/Users/u/late")
    }

    func testPermissionWaitsAndAnswerResumes() {
        var store = SessionStore()
        let key = SessionKey(source: .claude, sessionId: "s1")
        XCTAssertEqual(store.apply(event(.permissionRequest, toolName: "Bash", decisionSupported: true)), [])
        XCTAssertEqual(store.sessions[key]?.status, .waitingForUser)
        store.permissionAnswered(key, at: t0.addingTimeInterval(1))
        XCTAssertEqual(store.sessions[key]?.status, .working)
    }

    func testUnanswerablePermissionAsksForAttention() {
        var store = SessionStore()
        let effects = store.apply(event(.permissionRequest, toolName: "AskUserQuestion"))
        XCTAssertEqual(effects, [.needsAttention(SessionKey(source: .claude, sessionId: "s1"), message: "AskUserQuestion")])
    }

    func testSessionEndRemovesAndStaleSessionsExpire() {
        var store = SessionStore(staleAfter: 60, workingTimeout: 30)
        store.apply(event(.promptSubmitted, session: "a"))
        store.apply(event(.promptSubmitted, session: "b", at: 50))
        XCTAssertEqual(store.apply(event(.sessionEnd, session: "b", at: 51)), [.ended(SessionKey(source: .claude, sessionId: "b"))])
        store.apply(event(.promptSubmitted, session: "c", at: 55))
        XCTAssertEqual(store.expire(now: t0.addingTimeInterval(80)), [SessionKey(source: .claude, sessionId: "a")])
        XCTAssertEqual(store.sessions[SessionKey(source: .claude, sessionId: "c")]?.status, .working)
        store.expire(now: t0.addingTimeInterval(100))
        XCTAssertEqual(store.sessions[SessionKey(source: .claude, sessionId: "c")]?.status, .idle)
    }

    func testWireRoundTrip() throws {
        let request = BridgeRequest(event: event(.permissionRequest, toolName: "Bash", decisionSupported: true), expectsReply: true)
        var buffer = try Wire.frame(request)
        buffer.append(try Wire.frame(BridgeReply(eventId: request.event.id, decision: .deny(reason: "нет"))))
        let first = try XCTUnwrap(Wire.takeFrame(from: &buffer))
        XCTAssertEqual(try Wire.decode(BridgeRequest.self, from: first), request)
        let second = try XCTUnwrap(Wire.takeFrame(from: &buffer))
        XCTAssertEqual(try Wire.decode(BridgeReply.self, from: second).decision, .deny(reason: "нет"))
        XCTAssertTrue(buffer.isEmpty)
        var partial = try Wire.frame(request).prefix(10)
        XCTAssertNil(try Wire.takeFrame(from: &partial))
    }

    func testAgentIdRoundTripsAndIsOptionalOnTheWire() throws {
        let sub = event(.permissionRequest, toolName: "Bash", decisionSupported: true, agentId: "agent-bg-1")
        var buffer = try Wire.frame(BridgeRequest(event: sub, expectsReply: true))
        let payload = try XCTUnwrap(Wire.takeFrame(from: &buffer))
        XCTAssertEqual(try Wire.decode(BridgeRequest.self, from: payload).event.agentId, "agent-bg-1")

        // An encoding without the key (older bridge) still decodes, as the main thread.
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        var eventObject = try XCTUnwrap(object["event"] as? [String: Any])
        eventObject["agentId"] = nil
        object["event"] = eventObject
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try Wire.decode(BridgeRequest.self, from: legacy).event.agentId)
    }

    // MARK: Compaction

    /// /compact is a local command: PreCompact(manual), SessionStart(compact), PostCompact(manual), and no Stop.
    func testManualCompactOfAFinishedSessionDoesNotLookWorking() {
        var store = SessionStore()
        store.apply(event(.promptSubmitted))
        store.apply(event(.stop, at: 1))
        store.apply(event(.compact, at: 5, raw: ["hook_event_name": "PreCompact", "trigger": "manual"]))
        store.apply(event(.sessionStart, at: 6, raw: ["hook_event_name": "SessionStart", "source": "compact"]))
        store.apply(event(.compact, at: 7, raw: ["hook_event_name": "PostCompact", "trigger": "manual"]))
        XCTAssertEqual(store.sessions[key]?.status, .finished)
    }

    func testManualCompactOfAnIdleSessionStaysIdle() {
        var store = SessionStore()
        store.apply(event(.sessionStart, raw: ["source": "startup"]))
        store.apply(event(.compact, at: 1, raw: ["trigger": "manual"]))
        store.apply(event(.compact, at: 2, raw: ["trigger": "manual"]))
        XCTAssertEqual(store.sessions[key]?.status, .idle)
    }

    func testAutoCompactStillCountsAsWork() {
        var store = SessionStore()
        store.apply(event(.sessionStart, raw: ["source": "startup"]))
        store.apply(event(.compact, at: 1, raw: ["trigger": "auto"]))
        XCTAssertEqual(store.sessions[key]?.status, .working)
        store.apply(event(.stop, at: 2))
        store.apply(event(.sessionStart, at: 3, raw: ["source": "resume"]))
        XCTAssertEqual(store.sessions[key]?.status, .idle, "a real (re)start still resets finished")
    }

    // MARK: Host context

    func testNewerHostSnapshotClearsStaleTmuxPane() {
        var store = SessionStore()
        store.apply(event(.promptSubmitted, host: HostContext(termProgram: "tmux", tty: "/dev/ttys001", tmuxPane: "%3",
                                                               tmuxSocket: "/private/tmp/tmux-501/default", agentPid: 100,
                                                               extra: ["TMUX": "/private/tmp/tmux-501/default,1,0"])))
        store.apply(event(.promptSubmitted, at: 60, host: HostContext(
            termProgram: "iTerm.app", itermSessionId: "w0t1p0:ABC", tty: "/dev/ttys009", agentPid: 200, appPid: 300,
            appBundleIdentifier: "com.googlecode.iterm2", extra: ["LC_TERMINAL": "iTerm2"])))
        let host = store.sessions[key]?.host
        XCTAssertNil(host?.tmuxPane)
        XCTAssertNil(host?.tmuxSocket)
        XCTAssertNil(host?.extra["TMUX"])
        XCTAssertEqual(host?.tty, "/dev/ttys009")
        XCTAssertEqual(host?.agentPid, 200)
        XCTAssertEqual(host?.appBundleIdentifier, "com.googlecode.iterm2")
        XCTAssertEqual(host?.extra["LC_TERMINAL"], "iTerm2")
    }

    func testHostWithoutIdentityOrOutOfOrderKeepsSnapshotButMergesAdapterKeys() {
        var store = SessionStore()
        let iterm = HostContext(termProgram: "iTerm.app", tty: "/dev/ttys009", agentPid: 200,
                                extra: [KimiAdapter.sessionTitleKey: "Игра", KimiAdapter.clientTypeKey: "kimi_code_cli"])
        store.apply(event(.promptSubmitted, at: 10, source: .kimi, host: iterm))
        let kimiKey = SessionKey(source: .kimi, sessionId: "s1")

        // No terminal identity at all: keep the snapshot.
        store.apply(event(.toolWillRun, at: 11, source: .kimi, host: HostContext()))
        XCTAssertEqual(store.sessions[kimiKey]?.host, iterm)

        // An older event (parallel hook delivered late) from the previous terminal must not win.
        store.apply(event(.toolDidRun, at: 5, source: .kimi,
                          host: HostContext(tmuxPane: "%3", agentPid: 100, extra: [KimiAdapter.sessionTitleKey: "Старое"])))
        XCTAssertEqual(store.sessions[kimiKey]?.host, iterm)

        // A newer snapshot without Kimi's keys keeps them; a newer title replaces the old one.
        store.apply(event(.stop, at: 12, source: .kimi,
                          host: HostContext(termProgram: "iTerm.app", tty: "/dev/ttys009", agentPid: 201)))
        XCTAssertEqual(store.sessions[kimiKey]?.host.agentPid, 201)
        XCTAssertEqual(store.sessions[kimiKey]?.host.extra[KimiAdapter.sessionTitleKey], "Игра")
        XCTAssertEqual(store.sessions[kimiKey]?.host.extra[KimiAdapter.clientTypeKey], "kimi_code_cli")
        XCTAssertEqual(store.sessions[kimiKey]?.chatTitle, "Игра", "an older event's title must not win either")
        store.apply(event(.promptSubmitted, at: 13, source: .kimi,
                          host: HostContext(agentPid: 201, extra: [KimiAdapter.sessionTitleKey: "Новая игра"])))
        XCTAssertEqual(store.sessions[kimiKey]?.host.extra[KimiAdapter.sessionTitleKey], "Новая игра")
        XCTAssertEqual(store.sessions[kimiKey]?.chatTitle, "Новая игра")
        XCTAssertNil(store.sessions[kimiKey]?.host.tty, "the newer snapshot replaced the terminal fields as a unit")
    }

    func testMarkWaitingKeepsSessionWaiting() {
        var store = SessionStore()
        store.apply(event(.stop))
        store.markWaiting(key, at: t0.addingTimeInterval(3))
        XCTAssertEqual(store.sessions[key]?.status, .waitingForUser)
        XCTAssertEqual(store.sessions[key]?.statusSince, t0.addingTimeInterval(3))
        store.markWaiting(key, at: t0.addingTimeInterval(9))
        XCTAssertEqual(store.sessions[key]?.statusSince, t0.addingTimeInterval(3), "already waiting: unchanged")
        store.markWaiting(SessionKey(source: .codex, sessionId: "nope"))
        XCTAssertEqual(store.sessions.count, 1)
    }

    // MARK: Pending permission cards

    private func superseded(_ pending: AgentEvent, by later: AgentEvent) -> Bool {
        PendingPermissionPolicy.isSuperseded(pending, by: later)
    }

    /// Mirrors AppModel.handle: drop superseded cards, then queue a new answerable request.
    private func queue(_ events: [AgentEvent]) -> [AgentEvent] {
        var pending: [AgentEvent] = []
        for e in events {
            pending.removeAll { superseded($0, by: e) }
            if e.kind == .permissionRequest, e.decisionSupported { pending.append(e) }
        }
        return pending
    }

    func testBackgroundSubagentCardSurvivesMainThreadStopAndPrompt() {
        let card = event(.permissionRequest, at: 1, toolName: "Bash", toolSummary: "npm test", decisionSupported: true,
                         agentId: "agent-bg-1")
        XCTAssertFalse(superseded(card, by: event(.promptSubmitted, at: 2, message: "ещё")))
        XCTAssertFalse(superseded(card, by: event(.stop, at: 3)))
        XCTAssertFalse(superseded(card, by: event(.toolDidRun, at: 4, toolName: "Bash", toolSummary: "npm test")),
                       "the main thread running the same command is another call")
        XCTAssertFalse(superseded(card, by: event(.toolWillRun, at: 4, toolName: "Read", toolSummary: "/a")))
        XCTAssertFalse(superseded(card, by: event(.subagentStop, at: 5, agentId: "agent-other")))

        XCTAssertTrue(superseded(card, by: event(.subagentStop, at: 6, agentId: "agent-bg-1")))
        XCTAssertTrue(superseded(card, by: event(.toolDidRun, at: 6, toolName: "Bash", toolSummary: "npm test",
                                                agentId: "agent-bg-1")))
        XCTAssertTrue(superseded(card, by: event(.toolWillRun, at: 6, toolName: "Read", toolSummary: "/a",
                                                agentId: "agent-bg-1")))
        XCTAssertFalse(superseded(card, by: event(.toolWillRun, at: 1.5, toolName: "Read", toolSummary: "/b",
                                                 agentId: "agent-bg-1")), "its parallel sibling keeps the card alive")
        for kind in [EventKind.sessionEnd, .stopFailed, .interrupted] {
            XCTAssertTrue(superseded(card, by: event(kind, at: 7)), "\(kind) is session-wide")
        }
    }

    func testMainThreadCardIsDroppedByMainThreadEventsOnly() {
        let card = event(.permissionRequest, at: 1, toolName: "Bash", toolSummary: "rm -rf build", decisionSupported: true)
        XCTAssertTrue(superseded(card, by: event(.stop, at: 2)))
        XCTAssertTrue(superseded(card, by: event(.promptSubmitted, at: 2)))
        XCTAssertFalse(superseded(card, by: event(.stop, at: 2, agentId: "sub")), "a subagent's own Stop")
        XCTAssertFalse(superseded(card, by: event(.promptSubmitted, at: 2, agentId: "sub")), "a subagent's own prompt (Codex)")
        XCTAssertFalse(superseded(card, by: event(.subagentStop, at: 2)))
        XCTAssertFalse(superseded(card, by: event(.stop, at: 0)), "an older event says nothing about the card")
        XCTAssertFalse(superseded(card, by: event(.stop, session: "s2", at: 2)))
    }

    /// "No, and tell Claude what to do differently" keeps the turn (and the bridge) alive; the next PreToolUse
    /// shows the card was answered in the terminal.
    func testClaudeNextPreToolUseDropsCardAnsweredInTerminal() {
        let pre1 = event(.toolWillRun, at: 0, toolName: "Bash", toolSummary: "rm -rf build")
        let card1 = event(.permissionRequest, at: 1, toolName: "Bash", toolSummary: "rm -rf build", decisionSupported: true)
        let pre2 = event(.toolWillRun, at: 5, toolName: "Bash", toolSummary: "make clean")
        let card2 = event(.permissionRequest, at: 6, toolName: "Bash", toolSummary: "make clean", decisionSupported: true)
        XCTAssertEqual(queue([pre1, card1, pre2, card2]).map(\.id), [card2.id])

        XCTAssertFalse(superseded(card1, by: pre1), "its own, earlier PreToolUse")
        XCTAssertFalse(superseded(card1, by: event(.toolWillRun, at: 1, toolName: "Bash", toolSummary: "make clean")),
                       "not later than the card")
        XCTAssertFalse(superseded(card1, by: event(.toolWillRun, at: 2.5, toolName: "Read", toolSummary: "/b")),
                       "a parallel sibling call starting right after the card")
        XCTAssertFalse(superseded(card1, by: event(.toolWillRun, at: 10, toolName: "Bash", toolSummary: "rm -rf build")),
                       "the same call")
        XCTAssertFalse(superseded(card1, by: event(.toolWillRun, at: 10, toolName: "Read", toolSummary: "/a", agentId: "sub")),
                       "another thread's tool call")
    }

    func testCodexPreToolUseDoesNotDropCards() {
        let card = event(.permissionRequest, at: 1, toolName: "Bash", toolSummary: "ls", decisionSupported: true, source: .codex)
        XCTAssertFalse(superseded(card, by: event(.toolWillRun, at: 10, toolName: "Bash", toolSummary: "pwd", source: .codex)))
        XCTAssertTrue(superseded(card, by: event(.toolDidRun, at: 2, toolName: "Bash", toolSummary: "ls", source: .codex)))
        XCTAssertFalse(superseded(card, by: event(.stop, at: 2, source: .claude)), "another agent's session")
    }

    // MARK: Wall-clock jumps

    private let hour: TimeInterval = 3600

    /// An event the bridge stamped with the (possibly just set) wall clock `stampDelay` before it arrives at
    /// `clock.now`, and the moment the app assigns it (as AppModel.handle does).
    private func arriving(_ kind: EventKind, _ clock: TestClock, stampDelay: TimeInterval = 0.05, session: String = "s1",
                          toolName: String? = nil, toolSummary: String? = nil, decisionSupported: Bool = false,
                          agentId: String? = nil, host: HostContext = HostContext()) -> (AgentEvent, Moment) {
        let now = clock.now
        var e = event(kind, session: session, toolName: toolName, toolSummary: toolSummary,
                      decisionSupported: decisionSupported, agentId: agentId, host: host)
        e.timestamp = now.wall.addingTimeInterval(-stampDelay)
        return (e, now.eventMoment(stampedAt: e.timestamp))
    }

    private func receive(_ kind: EventKind, _ clock: TestClock, into store: inout SessionStore, session: String = "s1",
                         host: HostContext = HostContext()) {
        let (e, at) = arriving(kind, clock, session: session, host: host)
        store.apply(e, at: at)
    }

    func testClockSetForwardNeitherExpiresNorIdlesALiveSession() {
        let clock = TestClock()
        var store = SessionStore(staleAfter: 30 * 60, workingTimeout: 10 * 60)
        receive(.promptSubmitted, clock, into: &store)
        clock.advance(60)
        clock.setWall(by: 5 * hour)
        XCTAssertEqual(store.expire(at: clock.now), [])
        XCTAssertEqual(store.sessions[key]?.status, .working)

        // Real time still counts, whatever the wall clock says.
        clock.advance(10 * 60)
        XCTAssertEqual(store.expire(at: clock.now), [])
        XCTAssertEqual(store.sessions[key]?.status, .idle)
        clock.advance(20 * 60)
        XCTAssertEqual(store.expire(at: clock.now), [key])
    }

    func testClockSetBackStillIdlesAndExpires() {
        let clock = TestClock()
        var store = SessionStore(staleAfter: 30 * 60, workingTimeout: 10 * 60)
        receive(.promptSubmitted, clock, into: &store)
        clock.setWall(by: -11 * hour)   // 22:xx → 11:xx: every stored date is now "in the future"
        clock.advance(11 * 60)
        XCTAssertEqual(store.expire(at: clock.now), [])
        XCTAssertEqual(store.sessions[key]?.status, .idle, "not 'working' until the wall clock catches up")
        clock.advance(20 * 60)
        XCTAssertEqual(store.expire(at: clock.now), [key], "not kept for 11 hours")
    }

    func testEventsStampedAcrossAJumpKeepTheirArrivalOrder() {
        let clock = TestClock()
        var store = SessionStore()
        let tmux = HostContext(termProgram: "tmux", tty: "/dev/ttys001", tmuxPane: "%3", agentPid: 100)
        let iterm = HostContext(termProgram: "iTerm.app", tty: "/dev/ttys009", agentPid: 200)
        receive(.sessionStart, clock, into: &store, host: tmux)
        receive(.promptSubmitted, clock, into: &store, session: "other")
        clock.advance(1)
        clock.setWall(by: -11 * hour)
        clock.advance(1)
        receive(.promptSubmitted, clock, into: &store, host: iterm)
        XCTAssertEqual(store.sessions[key]?.host, iterm, "the later event wins although its stamp is 11 h older")
        XCTAssertEqual(store.ordered.map(\.key.sessionId), ["s1", "other"],
                       "most recent status change first, by arrival (its stamp is 11 h older)")
    }

    // MARK: Order

    /// Two agents working side by side: their tool calls (which only move `lastEventMoment`) must not make them
    /// trade places, or the collapsed island's primary session would flip on every hook event.
    func testToolEventsDoNotReorderSessionsWithinAGroup() {
        let clock = TestClock()
        var store = SessionStore()
        receive(.promptSubmitted, clock, into: &store, session: "api")
        clock.advance(5)
        receive(.promptSubmitted, clock, into: &store)
        XCTAssertEqual(store.ordered.map(\.key.sessionId), ["s1", "api"])
        for _ in 0..<3 {
            clock.advance(1)
            let (e, at) = arriving(.toolWillRun, clock, session: "api", toolName: "Read", toolSummary: "/a")
            store.apply(e, at: at)
            XCTAssertEqual(store.ordered.map(\.key.sessionId), ["s1", "api"], "a tool call is not a status change")
            clock.advance(1)
            let (d, dAt) = arriving(.toolDidRun, clock, session: "api", toolName: "Read", toolSummary: "/a")
            store.apply(d, at: dAt)
            XCTAssertEqual(store.ordered.map(\.key.sessionId), ["s1", "api"])
        }
        // A real status change still moves it: "api" asks for permission, then goes back to work.
        clock.advance(1)
        let (ask, askAt) = arriving(.permissionRequest, clock, session: "api", toolName: "Bash", decisionSupported: true)
        store.apply(ask, at: askAt)
        XCTAssertEqual(store.ordered.map(\.key.sessionId), ["api", "s1"], "waiting outranks working")
        let answered = clock.advance(1)
        store.permissionAnswered(SessionKey(source: .claude, sessionId: "api"), at: answered)
        XCTAssertEqual(store.ordered.map(\.key.sessionId), ["api", "s1"], "the most recent status change first")
    }

    func testOrderTieBreaksAreStable() {
        let clock = TestClock()
        var store = SessionStore()
        // The same moment for all three: the most recently started first, then by key.
        for id in ["b", "a", "c"] { receive(.promptSubmitted, clock, into: &store, session: id) }
        let once = store.ordered.map(\.key.sessionId)
        XCTAssertEqual(once, ["a", "b", "c"])
        for _ in 0..<5 { XCTAssertEqual(store.ordered.map(\.key.sessionId), once, "no dictionary-order flicker") }

        // The same status moment: the most recently started first (not the key, which would put "early" first).
        var started = SessionStore()
        receive(.sessionStart, clock, into: &started, session: "early")
        clock.advance(10)
        receive(.sessionStart, clock, into: &started, session: "late")
        let same = clock.advance(1)
        for id in ["early", "late"] { started.markWaiting(SessionKey(source: .claude, sessionId: id), at: same) }
        XCTAssertEqual(started.ordered.map(\.key.sessionId), ["late", "early"])
    }

    // MARK: Episodes

    func testEpisodeSurvivesAWallClockShiftButNotAStatusChange() {
        let clock = TestClock()
        var store = SessionStore()
        receive(.promptSubmitted, clock, into: &store)
        clock.advance(30)
        receive(.stop, clock, into: &store)
        let finished = store.sessions[key]!.episode

        store.shiftWallClock(by: -11 * hour)
        XCTAssertEqual(store.sessions[key]?.episode, finished, "setting the clock does not replay the check")
        store.shiftWallClock(by: 5 * hour)
        XCTAssertEqual(store.sessions[key]?.episode, finished)

        clock.advance(1)
        receive(.toolWillRun, clock, into: &store)
        XCTAssertEqual(store.sessions[key]?.status, .working)
        let working = store.sessions[key]!.episode
        XCTAssertNotEqual(working, finished, "a new status is a new episode")
        clock.advance(1)
        receive(.toolDidRun, clock, into: &store)
        XCTAssertEqual(store.sessions[key]?.episode, working, "more events of the same status are the same episode")
    }

    func testLooksTheSameIgnoresWhatTheIslandDoesNotShow() {
        let clock = TestClock()
        var store = SessionStore()
        receive(.promptSubmitted, clock, into: &store)
        let before = store.sessions[key]!
        clock.advance(2)
        receive(.promptSubmitted, clock, into: &store, host: HostContext(termProgram: "iTerm.app", tty: "/dev/ttys002"))
        let after = store.sessions[key]!
        XCTAssertNotEqual(before, after, "the event did change the session")
        XCTAssertTrue(before.looksTheSame(as: after), "but nothing the island draws")

        clock.advance(1)
        let (tool, at) = arriving(.toolWillRun, clock, toolName: "Bash", toolSummary: "ls")
        store.apply(tool, at: at)
        XCTAssertFalse(after.looksTheSame(as: store.sessions[key]!), "a new tool line shows")
        var shifted = store
        shifted.shiftWallClock(by: 60)
        XCTAssertFalse(store.sessions[key]!.looksTheSame(as: shifted.sessions[key]!), "running clocks follow the wall clock")
    }

    func testShiftWallClockKeepsTheElapsedDisplayTrue() {
        let clock = TestClock()
        var detector = WallClockJumpDetector()
        var store = SessionStore()
        /// What AppModel does on every clock read.
        func sync() { if let delta = detector.check(clock.now) { store.shiftWallClock(by: delta) } }
        /// What the island shows: wall now − statusSince.
        func shown() -> TimeInterval { clock.now.wall.timeIntervalSince(store.sessions[key]!.statusSince) }

        sync()
        let (prompt, at) = arriving(.promptSubmitted, clock)
        store.apply(prompt, at: at)
        clock.advance(90)
        XCTAssertEqual(shown(), 90.05, accuracy: 0.001)

        clock.setWall(by: -11 * hour)
        XCTAssertLessThan(shown(), 0, "unsynced, the display would go negative")
        sync()
        XCTAssertEqual(shown(), 90.05, accuracy: 0.001)

        clock.advance(30)
        clock.setWall(by: 12 * hour)
        sync()
        XCTAssertEqual(shown(), 120.05, accuracy: 0.001, "not 12 hours")
        XCTAssertEqual(store.sessions[key]?.statusMoment.monotonic, at.monotonic, "monotonic halves never move")
        XCTAssertEqual(clock.now.wall.timeIntervalSince(store.sessions[key]!.startedAt), 120.05, accuracy: 0.001)
    }

    func testMomentAPIsSetStatusMoments() {
        let clock = TestClock()
        var store = SessionStore()
        let (request, at) = arriving(.permissionRequest, clock, toolName: "Bash", decisionSupported: true)
        store.apply(request, at: at)
        let answered = clock.advance(5)
        store.permissionAnswered(key, at: answered)
        XCTAssertEqual(store.sessions[key]?.status, .working)
        XCTAssertEqual(store.sessions[key]?.statusMoment, answered)
        let waiting = clock.advance(5)
        store.markWaiting(key, at: waiting)
        XCTAssertEqual(store.sessions[key]?.statusMoment, waiting)
        XCTAssertEqual(store.sessions[key]?.lastEventMoment, at, "answering is not an agent event")
    }

    func testSiblingWindowIsMeasuredOnTheMonotonicClock() {
        let clock = TestClock()
        let (card, cardAt) = arriving(.permissionRequest, clock, toolName: "Bash", toolSummary: "npm test",
                                      decisionSupported: true, agentId: "agent-bg-1")
        clock.advance(0.5)
        clock.setWall(by: 3 * hour)
        let (sibling, siblingAt) = arriving(.toolWillRun, clock, toolName: "Read", toolSummary: "/b", agentId: "agent-bg-1")
        XCTAssertFalse(PendingPermissionPolicy.isSuperseded(card, at: cardAt, by: sibling, at: siblingAt),
                       "a parallel sibling 0.5 s later keeps the card, though its stamp is 3 h later")
        XCTAssertTrue(PendingPermissionPolicy.isSuperseded(card, by: sibling), "(stamps alone would drop it)")

        clock.advance(3)
        let (next, nextAt) = arriving(.toolWillRun, clock, toolName: "Read", toolSummary: "/c", agentId: "agent-bg-1")
        XCTAssertTrue(PendingPermissionPolicy.isSuperseded(card, at: cardAt, by: next, at: nextAt))
    }

    /// A sibling's delivery delayed past `Moment.maxEventTransit` (the app's main thread stalled) makes its moment
    /// look later than it was; the bridges' own stamps, 0.1 s apart, keep the live card.
    func testSiblingDelayedBehindAStalledMainThreadKeepsTheCard() {
        let t: TimeInterval = 5_000
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        var card = event(.permissionRequest, toolName: "Bash", toolSummary: "npm test", decisionSupported: true,
                         agentId: "agent-bg-1")
        card.timestamp = stamp
        let cardAt = Moment(wall: stamp, monotonic: t)
        var sibling = event(.toolWillRun, toolName: "Read", toolSummary: "/b", agentId: "agent-bg-1")
        sibling.timestamp = stamp.addingTimeInterval(0.1)
        // Received 4.2 s after its stamp: the transit clamp (2 s) puts its moment at T + 2.3.
        let received = Moment(wall: stamp.addingTimeInterval(4.3), monotonic: t + 4.3)
        let siblingAt = received.eventMoment(stampedAt: sibling.timestamp)
        XCTAssertEqual(siblingAt.since(cardAt), 2.3, accuracy: 0.001)
        XCTAssertFalse(PendingPermissionPolicy.isSuperseded(card, at: cardAt, by: sibling, at: siblingAt),
                       "stamped 0.1 s after the card: a parallel sibling, however late it was delivered")

        // A real next call, stamped seconds later, still closes it.
        var next = event(.toolWillRun, toolName: "Read", toolSummary: "/c", agentId: "agent-bg-1")
        next.timestamp = stamp.addingTimeInterval(4)
        let nextAt = Moment(wall: stamp.addingTimeInterval(4.05), monotonic: t + 4.05).eventMoment(stampedAt: next.timestamp)
        XCTAssertTrue(PendingPermissionPolicy.isSuperseded(card, at: cardAt, by: next, at: nextAt))
    }

    func testClockSetBackBetweenCardAndNextCallKeepsTheCard() {
        let clock = TestClock()
        let (card, cardAt) = arriving(.permissionRequest, clock, toolName: "Bash", toolSummary: "npm test",
                                      decisionSupported: true)
        clock.advance(5)
        clock.setWall(by: -11 * hour)
        let (next, nextAt) = arriving(.toolWillRun, clock, toolName: "Read", toolSummary: "/c")
        XCTAssertFalse(PendingPermissionPolicy.isSuperseded(card, at: cardAt, by: next, at: nextAt),
                       "a stamp gap of −11 h is no evidence: the card waits for Stop, the call's own PostToolUse or a prompt")
        let (stop, stopAt) = arriving(.stop, clock)
        XCTAssertTrue(PendingPermissionPolicy.isSuperseded(card, at: cardAt, by: stop, at: stopAt))
    }

    func testStopAfterTheClockWasSetBackStillDropsTheCard() {
        let clock = TestClock()
        let (card, cardAt) = arriving(.permissionRequest, clock, toolName: "Bash", toolSummary: "rm -rf build",
                                      decisionSupported: true)
        clock.advance(5)
        clock.setWall(by: -11 * hour)
        let (stop, stopAt) = arriving(.stop, clock)
        XCTAssertTrue(PendingPermissionPolicy.isSuperseded(card, at: cardAt, by: stop, at: stopAt))
        XCTAssertFalse(PendingPermissionPolicy.isSuperseded(card, by: stop), "(stamps alone would keep it)")
        XCTAssertFalse(PendingPermissionPolicy.isSuperseded(card, at: stopAt, by: stop, at: cardAt),
                       "an event from before the card says nothing about it")
    }

    // MARK: Titles

    func testDisplayTitlePrefersChatTitleThenFirstPromptThenFolder() {
        var store = SessionStore()
        store.apply(event(.sessionStart, cwd: "/Users/u/weather-app"))
        XCTAssertNil(store.sessions[key]?.chatTitle)
        XCTAssertEqual(store.sessions[key]?.displayTitle, "weather-app")
        XCTAssertEqual(store.sessions[key]?.title, "weather-app")

        store.apply(event(.promptSubmitted, at: 1, message: "  Почини сборку\n\nи прогони   тесты, пожалуйста, там что-то упало "))
        XCTAssertEqual(store.sessions[key]?.firstPrompt?.hasPrefix("  Почини"), true)
        let promptTitle = store.sessions[key]?.displayTitle
        XCTAssertEqual(promptTitle, "Почини сборку и прогони тесты, пожалуйс…")
        XCTAssertEqual(promptTitle?.count, SessionNaming.maxPromptTitleLength)

        // Later prompts do not rename the session.
        store.apply(event(.promptSubmitted, at: 2, message: "ещё"))
        XCTAssertEqual(store.sessions[key]?.displayTitle, promptTitle)
        XCTAssertEqual(store.sessions[key]?.lastPrompt, "ещё")

        XCTAssertTrue(store.setChatTitle("Починка сборки", for: key))
        XCTAssertEqual(store.sessions[key]?.displayTitle, "Починка сборки")
        XCTAssertEqual(store.sessions[key]?.title, "Починка сборки")
        XCTAssertEqual(store.sessions[key]?.projectName, "weather-app")
    }

    func testBlankPromptIsNotTheFirstPrompt() {
        var store = SessionStore()
        store.apply(event(.promptSubmitted, message: " \n "))
        XCTAssertNil(store.sessions[key]?.firstPrompt)
        store.apply(event(.promptSubmitted, at: 1, message: "привет"))
        XCTAssertEqual(store.sessions[key]?.firstPrompt, "привет")
    }

    func testScratchAndTempFoldersAreNotProjects() {
        let scratch = "/Users/u/Library/Application Support/Claude/scratch-workspaces/0f3a/9c1d/scratch-2026-01-02-a1b2c3"
        var store = SessionStore()
        store.apply(event(.sessionStart, cwd: scratch))
        XCTAssertNil(store.sessions[key]?.projectName)
        XCTAssertNil(store.sessions[key]?.displayTitle)
        XCTAssertEqual(store.sessions[key]?.title, "Claude Code", "no title and no folder: the agent's name")
        store.apply(event(.promptSubmitted, at: 1, message: "напиши змейку"))
        XCTAssertEqual(store.sessions[key]?.title, "напиши змейку")
        XCTAssertNil(store.sessions[key]?.projectName)

        for path in ["/tmp/proj", "/private/tmp", "/private/var/folders/xy/T/abc", "/var/folders/xy", "/Users/u/scratch-2026-01-02-abcdef"] {
            XCTAssertTrue(SessionNaming.isScratchOrTemp(path), path)
            XCTAssertNil(SessionNaming.projectName(forCwd: path), path)
        }
        for path in ["/Users/u/proj", "/Users/u/tmpfiles", "/Users/u/scratch-notes", "/Users/u/Claude/app"] {
            XCTAssertFalse(SessionNaming.isScratchOrTemp(path), path)
        }
        XCTAssertEqual(SessionNaming.projectName(forCwd: "/Users/u/proj/"), "proj")
        XCTAssertNil(SessionNaming.projectName(forCwd: "/"))
        XCTAssertNil(SessionNaming.projectName(forCwd: ""))
        XCTAssertNil(SessionNaming.projectName(forCwd: nil))
    }

    func testPromptTitleRules() {
        XCTAssertNil(SessionNaming.promptTitle(nil))
        XCTAssertNil(SessionNaming.promptTitle("  \n\t "))
        XCTAssertEqual(SessionNaming.promptTitle("a\nb"), "a b")
        let exact = String(repeating: "я", count: 40)
        XCTAssertEqual(SessionNaming.promptTitle(exact), exact)
        XCTAssertEqual(SessionNaming.promptTitle(exact + "!"), String(repeating: "я", count: 39) + "…")
    }

    func testEventTitleAndTranscriptPath() {
        var store = SessionStore()
        store.apply(event(.sessionStart, transcriptPath: "/Users/u/.claude/projects/p/s1.jsonl", sessionTitle: "Имя чата"))
        XCTAssertEqual(store.sessions[key]?.transcriptPath, "/Users/u/.claude/projects/p/s1.jsonl")
        XCTAssertEqual(store.sessions[key]?.chatTitle, "Имя чата")

        // A subagent's own transcript never replaces the main thread's; events without one keep it.
        store.apply(event(.toolWillRun, at: 1, toolName: "Bash", agentId: "a1", transcriptPath: "/tmp/sub.jsonl"))
        store.apply(event(.toolDidRun, at: 2, toolName: "Bash"))
        XCTAssertEqual(store.sessions[key]?.transcriptPath, "/Users/u/.claude/projects/p/s1.jsonl")
        XCTAssertEqual(store.sessions[key]?.chatTitle, "Имя чата", "events without a title keep it")

        // A subagent event may still fill a session the app has no path for yet.
        let other = SessionKey(source: .claude, sessionId: "s2")
        store.apply(event(.toolWillRun, session: "s2", toolName: "Bash", agentId: "a1", transcriptPath: "/tmp/sub.jsonl"))
        XCTAssertEqual(store.sessions[other]?.transcriptPath, "/tmp/sub.jsonl")
        store.apply(event(.toolWillRun, session: "s2", at: 1, toolName: "Bash", transcriptPath: "/p/s2.jsonl"))
        XCTAssertEqual(store.sessions[other]?.transcriptPath, "/p/s2.jsonl")
    }

    func testSetChatTitle() {
        var store = SessionStore()
        XCTAssertFalse(store.setChatTitle("x", for: key), "unknown session")
        store.apply(event(.sessionStart))
        XCTAssertTrue(store.setChatTitle("  Игра\nв змейку ", for: key))
        XCTAssertEqual(store.sessions[key]?.chatTitle, "Игра в змейку")
        XCTAssertFalse(store.setChatTitle("Игра в змейку", for: key), "same title changes nothing")
        let before = store.sessions[key]!
        XCTAssertTrue(store.setChatTitle("Другое", for: key))
        XCTAssertFalse(store.sessions[key]!.looksTheSame(as: before), "a new title re-renders the island")
        XCTAssertTrue(store.setChatTitle("   ", for: key))
        XCTAssertNil(store.sessions[key]?.chatTitle)
        XCTAssertEqual(store.sessions[key]?.title, "proj")
    }

    func testEventCodableKeepsTitleFieldsAndReadsOldEncodings() throws {
        let e = event(.sessionStart, transcriptPath: "/p/s1.jsonl", sessionTitle: "Имя")
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(decoded, e)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as? [String: Any])
        object.removeValue(forKey: "transcriptPath")
        object.removeValue(forKey: "sessionTitle")
        let old = try JSONDecoder().decode(AgentEvent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.transcriptPath)
        XCTAssertNil(old.sessionTitle)
        XCTAssertEqual(old.sessionId, "s1")
    }
}
