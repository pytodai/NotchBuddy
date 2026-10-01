import XCTest
@testable import NotchBuddyCore

/// Payload shapes: one JSON object, top-level snake_case keys.
final class KimiAdapterTests: XCTestCase {
    private let adapter = KimiAdapter()
    private static let sid = "session_a3b6a00b-1b26-4821-85c0-7e291197d8ae"
    private static let common = """
    "session_id":"\(sid)","cwd":"/Users/me/code/snake","client_type":"kimi_code_cli"
    """

    private func event(_ name: String, _ fields: String = "", host: HostContext = HostContext()) throws -> AgentEvent {
        let extra = fields.isEmpty ? "" : "," + fields
        let json = "{\"hook_event_name\":\"\(name)\",\(Self.common)\(extra)}"
        return try adapter.normalize(stdin: Data(json.utf8), host: host)
    }

    private static let writeApproval = """
    "session_title":"Сделай змейку","id":"approval_945cd8ed-69c9-4ef4-868c-3c2f6408e436","agent_id":"main",
    "turn_id":1,"tool_call_id":"tool_pVlpubIbZ2nu8Neg0H67mZd1","tool_name":"Write",
    "action":"Writing /Users/me/code/snake/index.html",
    "display":{"kind":"file_io","operation":"write","path":"/Users/me/code/snake/index.html","content":"<!DOCTYPE html>"},
    "tool_input":{"path":"/Users/me/code/snake/index.html","content":"<!DOCTYPE html>"}
    """

    /// One fixture per config-supported event plus an unknown one.
    private func allFixtures() throws -> [AgentEvent] {
        [
            try event("SessionStart", #""source":"startup","model":"kimi-code/k3","profile":"default""#),
            try event("SessionEnd", #""reason":"exit","session_title":"Сделай змейку""#),
            try event("UserPromptSubmit", #""prompt":[{"type":"text","text":"fix the login page"}],"is_steer":false"#),
            try event("PreToolUse", #""tool_name":"Bash","tool_input":{"command":"git status"},"tool_call_id":"tool_1""#),
            try event("PostToolUse", #""tool_name":"Read","tool_input":{"path":"/a.swift"},"tool_call_id":"tool_2","tool_output":"ok""#),
            try event("PostToolUseFailure", #""tool_name":"Bash","tool_input":{"command":"false"},"tool_call_id":"tool_3","error":{"code":"x","message":"exit 1"}"#),
            try event("PermissionRequest", Self.writeApproval),
            try event("PermissionResult", Self.writeApproval + #","decision":"approved","scope":"session""#),
            try event("Stop", #""stop_hook_active":false"#),
            try event("StopFailure", #""error_type":"APIError","error_message":"rate limited""#),
            try event("Interrupt", #""turn_id":2,"reason":"cancelled""#),
            try event("SubagentStart", #""agent_name":"coder","prompt":"write tests""#),
            try event("SubagentStop", #""agent_name":"coder","response":"done""#),
            try event("Notification", #""sink":"context","notification_type":"task.completed","title":"Task done","body":"build ok","severity":"info""#),
            try event("PreCompact", #""trigger":"auto","token_count":120000"#),
            try event("PostCompact", #""trigger":"auto","estimated_token_count":30000"#),
            try event("TurnStarted", #""turn_id":3,"origin_kind":"user""#),
        ]
    }

    // MARK: Event mapping

    func testEveryEventMapsToItsKind() throws {
        let kinds = try allFixtures().map(\.kind)
        XCTAssertEqual(kinds, [
            .sessionStart, .sessionEnd, .promptSubmitted, .toolWillRun, .toolDidRun, .toolFailed,
            .permissionRequest, .permissionResolved, .stop, .stopFailed, .interrupted,
            .subagentStart, .subagentStop, .other, .compact, .compact, .other,
        ])
    }

    func testCommonFieldsAreFilled() throws {
        for e in try allFixtures() {
            XCTAssertEqual(e.source, .kimi)
            XCTAssertEqual(e.sessionId, Self.sid)
            XCTAssertEqual(e.sessionKey, SessionKey(source: .kimi, sessionId: Self.sid))
            XCTAssertEqual(e.cwd, "/Users/me/code/snake")
            XCTAssertEqual(e.host.extra[KimiAdapter.clientTypeKey], "kimi_code_cli")
            XCTAssertEqual(e.raw["hook_event_name"]?.string, e.hookEventName)
        }
    }

    func testSessionStartHasNoMessage() throws {
        let e = try event("SessionStart", #""source":"startup","model":"kimi-code/k3""#)
        XCTAssertEqual(e.hookEventName, "SessionStart")
        XCTAssertNil(e.message)
        XCTAssertNil(e.toolName)
        XCTAssertNil(e.host.extra[KimiAdapter.sessionTitleKey])
    }

    func testSessionTitleGoesToHostExtraNotMessage() throws {
        let e = try event("SessionEnd", #""reason":"exit","session_title":"Сделай змейку""#)
        XCTAssertEqual(e.sessionTitle, "Сделай змейку")
        XCTAssertEqual(e.kind, .sessionEnd)
        XCTAssertEqual(e.host.extra[KimiAdapter.sessionTitleKey], "Сделай змейку")
        XCTAssertNil(e.message)
    }

    func testVSCodeClientTypeAndBridgeHostArePreserved() throws {
        let json = #"{"hook_event_name":"Stop","session_id":"s1","cwd":"/","client_type":"kimi_code_vscode"}"#
        let host = HostContext(termProgram: "vscode", agentPid: 42, extra: ["KITTY_WINDOW_ID": "7"])
        let e = try adapter.normalize(stdin: Data(json.utf8), host: host)
        XCTAssertEqual(e.host.termProgram, "vscode")
        XCTAssertEqual(e.host.agentPid, 42)
        XCTAssertEqual(e.host.extra["KITTY_WINDOW_ID"], "7")
        XCTAssertEqual(e.host.extra[KimiAdapter.clientTypeKey], "kimi_code_vscode")
    }

    func testVSCodeAgentEventsDropTheExtensionHostCwd() throws {
        func cwd(_ name: String, client: String) throws -> String? {
            let json = #"{"hook_event_name":"\#(name)","session_id":"s1","cwd":"/wd","client_type":"\#(client)"}"#
            return try adapter.normalize(stdin: Data(json.utf8), host: HostContext()).cwd
        }
        XCTAssertEqual(try cwd("SessionStart", client: "kimi_code_vscode"), "/wd")
        XCTAssertEqual(try cwd("SubagentStart", client: "kimi_code_vscode"), "/wd")
        XCTAssertNil(try cwd("PreToolUse", client: "kimi_code_vscode"))
        XCTAssertNil(try cwd("PermissionRequest", client: "kimi_code_vscode"))
        XCTAssertEqual(try cwd("PreToolUse", client: "kimi_code_cli"), "/wd", "CLI agent-event cwd is the launch dir")
    }

    func testVSCodeSessionKeepsProjectCwdInStore() throws {
        var store = SessionStore()
        for (name, cwd) in [("SessionStart", "/Users/me/proj"), ("PreToolUse", "/")] {
            let json = #"{"hook_event_name":"\#(name)","session_id":"s1","cwd":"\#(cwd)","client_type":"kimi_code_vscode"}"#
            store.apply(try adapter.normalize(stdin: Data(json.utf8), host: HostContext()))
        }
        XCTAssertEqual(store.sessions[SessionKey(source: .kimi, sessionId: "s1")]?.cwd, "/Users/me/proj")
    }

    func testUserPromptJoinsTextPartsOnly() throws {
        let e = try event("UserPromptSubmit", #"""
        "prompt":[{"type":"text","text":"fix the login page"},{"type":"image_url","imageUrl":{"url":"data:x"}},{"type":"text","text":"and tests\n"}],"is_steer":false
        """#)
        XCTAssertEqual(e.kind, .promptSubmitted)
        XCTAssertEqual(e.message, "fix the login page and tests")
        XCTAssertNil(e.toolSummary)
    }

    func testUserPromptAcceptsPlainString() throws {
        let e = try event("UserPromptSubmit", #""prompt":"  hello  ""#)
        XCTAssertEqual(e.message, "hello")
    }

    func testUserPromptWithOnlyImageHasNoMessage() throws {
        let e = try event("UserPromptSubmit", #""prompt":[{"type":"image_url","imageUrl":{"url":"data:x"}}]"#)
        XCTAssertNil(e.message)
    }

    func testToolEventsCarryToolNameAndSummary() throws {
        let pre = try event("PreToolUse", #""tool_name":"Bash","tool_input":{"command":"git status","description":"Show status"},"tool_call_id":"t""#)
        XCTAssertEqual(pre.toolName, "Bash")
        XCTAssertEqual(pre.toolSummary, "git status")
        XCTAssertNil(pre.message)

        let post = try event("PostToolUse", #""tool_name":"Edit","tool_input":{"path":"/p/a.swift","old_string":"a","new_string":"b"},"tool_output":"ok""#)
        XCTAssertEqual(post.kind, .toolDidRun)
        XCTAssertEqual(post.toolSummary, "/p/a.swift")

        let fail = try event("PostToolUseFailure", #""tool_name":"Grep","tool_input":{"pattern":"TODO","path":"/p"},"error":{"code":"e","message":"boom"}"#)
        XCTAssertEqual(fail.kind, .toolFailed)
        XCTAssertEqual(fail.toolSummary, "TODO", "Grep/Glob show the pattern, not the search root")
        XCTAssertNil(fail.message)
    }

    func testSkillToolSummary() throws {
        let e = try event("PreToolUse", #""tool_name":"Skill","tool_input":{"skill":"review","args":"--fast"}"#)
        XCTAssertEqual(e.toolSummary, "review --fast")
    }

    func testForegroundAskUserQuestionIsAnObserveOnlyQuestion() throws {
        let e = try event("PreToolUse", #"""
        "tool_name":"AskUserQuestion","tool_call_id":"t9","tool_input":{"questions":[{"question":"Which DB?","options":[{"label":"SQLite"},{"label":"Postgres"}]},{"question":"Add tests?","options":[{"label":"Yes"},{"label":"No"}]}]}
        """#)
        XCTAssertEqual(e.kind, .permissionRequest)
        XCTAssertEqual(e.hookEventName, "PreToolUse")
        XCTAssertEqual(e.toolSummary, "Which DB? / Add tests?")
        XCTAssertFalse(e.decisionSupported)
        XCTAssertFalse(adapter.expectsDecision(e))
    }

    func testBackgroundAskUserQuestionStaysAToolEvent() throws {
        let e = try event("PreToolUse", #""tool_name":"AskUserQuestion","tool_input":{"background":true,"questions":[{"question":"Later?"}]}"#)
        XCTAssertEqual(e.kind, .toolWillRun)
    }

    // MARK: Permissions (observe-only)

    func testPermissionRequestWrite() throws {
        let e = try event("PermissionRequest", Self.writeApproval)
        XCTAssertEqual(e.kind, .permissionRequest)
        XCTAssertEqual(e.toolName, "Write")
        XCTAssertEqual(e.toolSummary, "/Users/me/code/snake/index.html")
        XCTAssertFalse(e.decisionSupported)
        XCTAssertFalse(e.canAlwaysAllow)
        XCTAssertFalse(adapter.expectsDecision(e))
        XCTAssertNil(e.message)
        XCTAssertEqual(e.host.extra[KimiAdapter.sessionTitleKey], "Сделай змейку")
        XCTAssertEqual(KimiAdapter.approvalId(of: e), "approval_945cd8ed-69c9-4ef4-868c-3c2f6408e436")
    }

    func testAgentIdMainMeansMainThread() throws {
        XCTAssertNil(try event("PermissionRequest", Self.writeApproval).agentId, "\"main\" is the main agent")
        let sub = Self.writeApproval.replacingOccurrences(of: #""agent_id":"main""#, with: #""agent_id":"agent_7""#)
        XCTAssertEqual(try event("PermissionRequest", sub).agentId, "agent_7")
        XCTAssertNil(try event("Stop", #""stop_hook_active":false"#).agentId)
    }

    func testPermissionResultMatchesRequestById() throws {
        let e = try event("PermissionResult", Self.writeApproval + #","decision":"rejected","feedback":"no""#)
        XCTAssertEqual(e.kind, .permissionResolved)
        XCTAssertEqual(e.toolName, "Write")
        XCTAssertEqual(e.toolSummary, "/Users/me/code/snake/index.html")
        XCTAssertEqual(KimiAdapter.approvalId(of: e), "approval_945cd8ed-69c9-4ef4-868c-3c2f6408e436")
        XCTAssertEqual(e.raw["decision"]?.string, "rejected")
        XCTAssertFalse(e.decisionSupported)
        XCTAssertNil(e.message)
    }

    func testApprovalIdOnlyForPermissionEvents() throws {
        let e = try event("PreToolUse", #""id":"x","tool_name":"Bash","tool_input":{"command":"ls"}"#)
        XCTAssertNil(KimiAdapter.approvalId(of: e))
    }

    func testPermissionCommandShowsFullCommandNotTruncatedAction() throws {
        let cmd = "xcodebuild -scheme NotchBuddy -destination 'platform=macOS' -configuration Release build"
        let e = try event("PermissionRequest", """
        "id":"approval_1","tool_name":"Bash","action":"Running: \(cmd.prefix(50))…",
        "display":{"kind":"command","command":"\(cmd)","cwd":"/p","language":"bash"},"tool_input":{"command":"\(cmd)"}
        """)
        XCTAssertEqual(e.toolSummary, cmd)
    }

    func testPermissionSummaryPerDisplayKind() throws {
        func summary(_ display: String, action: String = "Doing it", input: String = "{}") throws -> String? {
            try event("PermissionRequest", #""id":"a","tool_name":"T","action":"\#(action)","display":\#(display),"tool_input":\#(input)"#).toolSummary
        }
        XCTAssertEqual(try summary(#"{"kind":"search","query":"swift actors"}"#), "swift actors")
        XCTAssertEqual(try summary(#"{"kind":"url_fetch","url":"https://example.com"}"#), "https://example.com")
        XCTAssertEqual(try summary(#"{"kind":"file_io","operation":"grep","path":"/p"}"#, action: "Searching for 'x' in /p"),
                       "Searching for 'x' in /p")
        XCTAssertEqual(try summary(#"{"kind":"file_io","operation":"edit","path":"/p/a.swift","before":"a","after":"b"}"#),
                       "/p/a.swift")
        XCTAssertEqual(try summary(#"{"kind":"skill_call","skill_name":"review","args":"--fast"}"#), "review --fast")
        XCTAssertEqual(try summary(#"{"kind":"agent_call","agent_name":"coder","prompt":"write tests"}"#), "coder: write tests")
        XCTAssertEqual(try summary(##"{"kind":"plan_review","plan":"# Plan\n1. Do","path":"/p/plan.md"}"##), "# Plan ⏎ 1. Do")
        XCTAssertEqual(try summary(#"{"kind":"generic","summary":"Doing it","detail":{}}"#), "Doing it")
        XCTAssertEqual(try summary(#"{"kind":"future_kind"}"#), "Doing it")
    }

    func testPermissionWithoutDisplayOrActionFallsBackToToolInput() throws {
        let e = try event("PermissionRequest", #""id":"a","tool_name":"Bash","tool_input":{"command":"rm -rf build"}"#)
        XCTAssertEqual(e.toolSummary, "rm -rf build")
    }

    // MARK: Other events

    func testStopFailureCarriesErrorMessage() throws {
        let e = try event("StopFailure", #""error_type":"APIError","error_message":"rate limited""#)
        XCTAssertEqual(e.kind, .stopFailed)
        XCTAssertEqual(e.message, "rate limited")
        XCTAssertEqual(try event("StopFailure", #""error_type":"APIError""#).message, "APIError")
    }

    func testStopAndInterruptHaveNoMessage() throws {
        XCTAssertNil(try event("Stop", #""stop_hook_active":false"#).message)
        let i = try event("Interrupt", #""turn_id":2,"reason":"cancelled""#)
        XCTAssertEqual(i.kind, .interrupted)
        XCTAssertNil(i.message)
    }

    func testSubagentEventsNameTheAgentWithoutOverwritingTheTool() throws {
        let start = try event("SubagentStart", #""agent_name":"coder","prompt":"write tests""#)
        XCTAssertEqual(start.kind, .subagentStart)
        XCTAssertNil(start.toolName)
        XCTAssertEqual(start.toolSummary, "coder")
        XCTAssertNil(start.message)
        XCTAssertEqual(try event("SubagentStop", #""agent_name":"coder","response":"done""#).kind, .subagentStop)
    }

    func testNotificationMessageJoinsTitleAndBody() throws {
        let e = try event("Notification", #""notification_type":"task.completed","title":"Task done","body":"build ok""#)
        XCTAssertEqual(e.kind, .other, "background-task notice, not a request for input")
        XCTAssertEqual(e.message, "Task done — build ok")
        XCTAssertEqual(try event("Notification", #""title":"Only title""#).message, "Only title")
        XCTAssertNil(try event("Notification", #""notification_type":"x""#).message)
    }

    func testCompactEvents() throws {
        XCTAssertEqual(try event("PreCompact", #""trigger":"manual","token_count":1"#).kind, .compact)
        XCTAssertEqual(try event("PostCompact", #""trigger":"auto""#).kind, .compact)
    }

    func testUnknownEventIsOtherAndKeepsItsName() throws {
        let e = try event("SessionHeartbeat", #""uptime_ms":60000"#)
        XCTAssertEqual(e.kind, .other)
        XCTAssertEqual(e.hookEventName, "SessionHeartbeat")
    }

    func testRawPayloadIsKept() throws {
        let json = #"{"hook_event_name":"Stop","session_id":"s1","stop_hook_active":false,"nested":{"imageUrl":"x"}}"#
        let e = try adapter.normalize(stdin: Data(json.utf8), host: HostContext())
        XCTAssertEqual(e.raw, try JSONValue.parse(Data(json.utf8)))
        XCTAssertNil(e.cwd)
    }

    func testEmptyCwdBecomesNil() throws {
        let json = #"{"hook_event_name":"Stop","session_id":"s1","cwd":""}"#
        XCTAssertNil(try adapter.normalize(stdin: Data(json.utf8), host: HostContext()).cwd)
    }

    // MARK: Errors

    func testInvalidInputThrows() {
        func normalize(_ s: String) throws -> AgentEvent { try adapter.normalize(stdin: Data(s.utf8), host: HostContext()) }
        XCTAssertThrowsError(try normalize("not json")) { XCTAssertEqual($0 as? AdapterError, .invalidJSON) }
        XCTAssertThrowsError(try normalize("[1,2]")) { XCTAssertEqual($0 as? AdapterError, .invalidJSON) }
        XCTAssertThrowsError(try normalize(#"{"session_id":"s"}"#)) {
            XCTAssertEqual($0 as? AdapterError, .missingField("hook_event_name"))
        }
        XCTAssertThrowsError(try normalize(#"{"hook_event_name":"Stop","session_id":""}"#)) {
            XCTAssertEqual($0 as? AdapterError, .missingField("session_id"))
        }
    }

    // MARK: Decisions: never, print nothing

    func testNothingExpectsADecisionAndRenderIsAlwaysPassthrough() throws {
        let decisions: [PermissionDecision] = [.allow, .allowAlways, .deny(reason: "нет"), .deny(reason: nil), .askInTerminal]
        for e in try allFixtures() {
            XCTAssertFalse(adapter.expectsDecision(e), e.hookEventName)
            XCTAssertFalse(e.decisionSupported, e.hookEventName)
            XCTAssertFalse(e.canAlwaysAllow, e.hookEventName)
            for d in decisions {
                let out = adapter.render(d, for: e)
                XCTAssertEqual(out, .passthrough, "\(e.hookEventName) \(d)")
                XCTAssertNil(out.stdout)
                XCTAssertNil(out.stderr)
                XCTAssertEqual(out.exitCode, 0)
            }
        }
    }

    func testFactoryReturnsKimiAdapter() {
        XCTAssertEqual(Adapters.adapter(for: .kimi).source, .kimi)
    }

    // MARK: Store integration

    func testObserveOnlyApprovalFlowThroughSessionStore() throws {
        var store = SessionStore()
        store.apply(try event("SessionStart", #""source":"startup""#))
        let effects = store.apply(try event("PermissionRequest", Self.writeApproval))
        let key = SessionKey(source: .kimi, sessionId: Self.sid)
        XCTAssertEqual(store.sessions[key]?.status, .waitingForUser)
        XCTAssertEqual(effects, [.needsAttention(key, message: "/Users/me/code/snake/index.html")])
        store.apply(try event("PermissionResult", Self.writeApproval + #","decision":"approved""#))
        XCTAssertEqual(store.sessions[key]?.status, .working)
        XCTAssertEqual(store.sessions[key]?.host.extra[KimiAdapter.sessionTitleKey], "Сделай змейку")
        XCTAssertEqual(store.sessions[key]?.chatTitle, "Сделай змейку")
        XCTAssertEqual(store.sessions[key]?.displayTitle, "Сделай змейку")
    }
}
