import XCTest
@testable import NotchBuddyCore

/// Fixtures for the catalog agents' adapters, shaped after the hook docs of Cursor, Copilot and Cline and
/// ~/.grok/docs/user-guide/10-hooks.md (installed bundles and docs; none recorded from a live run yet).
final class CatalogAdapterTests: XCTestCase {
    private func event(_ adapter: AgentAdapter, _ json: String, host: HostContext = HostContext()) throws -> AgentEvent {
        try adapter.normalize(stdin: Data(json.utf8), host: host)
    }

    // MARK: Cursor

    private let cursor = CursorAdapter()

    func testCursorSessionAndPrompt() throws {
        let start = try event(cursor, #"""
            {"hook_event_name":"sessionStart","conversation_id":"conv-1","session_id":"conv-1","generation_id":"g",
             "cursor_version":"3.15.6","workspace_roots":["/Users/me/proj"],"user_email":"me@example.com",
             "composer_mode":"agent","is_background_agent":false,"transcript_path":null}
            """#)
        XCTAssertEqual(start.source, .cursor)
        XCTAssertEqual(start.kind, .sessionStart)
        XCTAssertEqual(start.sessionId, "conv-1")
        XCTAssertEqual(start.cwd, "/Users/me/proj")
        XCTAssertNil(start.raw["user_email"], "personal data is not forwarded")
        XCTAssertFalse(cursor.expectsDecision(start))

        let prompt = try event(cursor, #"""
            {"hook_event_name":"beforeSubmitPrompt","conversation_id":"conv-1","prompt":"fix the tests",
             "attachments":[{"type":"file","file_path":"/a"}],"workspace_roots":["/Users/me/proj"]}
            """#)
        XCTAssertEqual(prompt.kind, .promptSubmitted)
        XCTAssertEqual(prompt.message, "fix the tests")
        XCTAssertNil(prompt.raw["attachments"])
    }

    func testCursorTools() throws {
        let pre = try event(cursor, #"""
            {"hook_event_name":"preToolUse","conversation_id":"c","tool_name":"Shell","tool_use_id":"t1",
             "tool_input":{"command":"npm test"},"cwd":"/p/sub","workspace_roots":["/p"]}
            """#)
        XCTAssertEqual(pre.kind, .toolWillRun)
        XCTAssertEqual(pre.toolName, "Shell")
        XCTAssertEqual(pre.toolSummary, "npm test")
        XCTAssertEqual(pre.cwd, "/p/sub")

        let mcp = try event(cursor, #"""
            {"hook_event_name":"beforeMCPExecution","conversation_id":"c","tool_name":"query",
             "tool_input":"{\"query\":\"select 1\"}","mcp_server_name":"db"}
            """#, host: HostContext(extra: ["CURSOR_PROJECT_DIR": "/env/proj"]))
        XCTAssertEqual(mcp.toolSummary, "select 1", "stringified MCP input is decoded")
        XCTAssertEqual(mcp.cwd, "/env/proj", "no cwd or workspace roots: the hook env's project dir")

        let failed = try event(cursor, #"""
            {"hook_event_name":"postToolUseFailure","conversation_id":"c","tool_name":"Shell",
             "tool_input":{"command":"false"},"error_message":"exit 1"}
            """#)
        XCTAssertEqual(failed.kind, .toolFailed)
        XCTAssertEqual(failed.message, "exit 1")

        let shell = try event(cursor, #"{"hook_event_name":"afterShellExecution","conversation_id":"c","command":"ls -la"}"#)
        XCTAssertEqual(shell.kind, .toolDidRun)
        XCTAssertEqual(shell.toolName, "Shell")
        XCTAssertEqual(shell.toolSummary, "ls -la")
    }

    func testCursorStopStatuses() throws {
        func stop(_ status: String) throws -> AgentEvent {
            try event(cursor, #"{"hook_event_name":"stop","conversation_id":"c","status":"\#(status)","loop_count":0}"#)
        }
        XCTAssertEqual(try stop("completed").kind, .stop)
        XCTAssertEqual(try stop("aborted").kind, .interrupted)
        XCTAssertEqual(try stop("error").kind, .stopFailed)
        XCTAssertEqual(try event(cursor, #"{"hook_event_name":"sessionEnd","conversation_id":"c","reason":"closed"}"#).kind,
                       .sessionEnd)
        let sub = try event(cursor, #"""
            {"hook_event_name":"subagentStop","conversation_id":"c","subagent_id":"sa1","subagent_type":"explore"}
            """#)
        XCTAssertEqual(sub.kind, .subagentStop)
        XCTAssertEqual(sub.agentId, "sa1")
        XCTAssertEqual(try event(cursor, #"{"hook_event_name":"afterAgentThought","conversation_id":"c"}"#).kind, .other)
    }

    func testCursorRejectsPayloadsWithoutConversation() {
        XCTAssertThrowsError(try event(cursor, #"{"hook_event_name":"stop"}"#))
        XCTAssertThrowsError(try event(cursor, #"{"conversation_id":"c"}"#))
        XCTAssertThrowsError(try event(cursor, "[]"))
        let e = AgentEvent(source: .cursor, hookEventName: "preToolUse", kind: .toolWillRun, sessionId: "c")
        XCTAssertEqual(cursor.render(.deny(reason: nil), for: e), .passthrough)
    }

    // MARK: GitHub Copilot

    private let copilot = Adapters.adapter(for: .copilot)

    func testCopilotVSCodePayloads() throws {
        let prompt = try event(copilot, #"""
            {"timestamp":"2026-09-30T12:00:00.000Z","hook_event_name":"UserPromptSubmit","session_id":"vs-1",
             "transcript_path":"/tmp/t.jsonl","cwd":"/Users/me/app","prompt":"add a README"}
            """#)
        XCTAssertEqual(prompt.source, .copilot)
        XCTAssertEqual(prompt.kind, .promptSubmitted)
        XCTAssertEqual(prompt.message, "add a README")
        XCTAssertEqual(prompt.transcriptPath, "/tmp/t.jsonl")

        let tool = try event(copilot, #"""
            {"hook_event_name":"PreToolUse","session_id":"vs-1","tool_name":"run_in_terminal",
             "tool_input":{"command":"git status"},"tool_use_id":"call_1","cwd":"/Users/me/app"}
            """#)
        XCTAssertEqual(tool.kind, .toolWillRun)
        XCTAssertEqual(tool.toolSummary, "git status")
        XCTAssertFalse(copilot.expectsDecision(tool), "VS Code has no PermissionRequest: PreToolUse is observed")

        XCTAssertEqual(try event(copilot, #"{"hook_event_name":"Stop","session_id":"vs-1","stopReason":"end_turn"}"#).kind, .stop)
        let fatal = try event(copilot, #"""
            {"hook_event_name":"ErrorOccurred","session_id":"vs-1","error":{"message":"rate limited"},"recoverable":false}
            """#)
        XCTAssertEqual(fatal.kind, .stopFailed)
        XCTAssertEqual(fatal.message, "rate limited")
        XCTAssertEqual(try event(copilot, #"{"hook_event_name":"ErrorOccurred","session_id":"s","recoverable":true}"#).kind,
                       .other)
    }

    func testCopilotCLIPermissionRequestIsAnsweredFromTheIsland() throws {
        let request = try event(copilot, #"""
            {"hook_event_name":"PermissionRequest","session_id":"cli-1","tool_name":"bash",
             "tool_input":{"command":"rm -rf build"},"cwd":"/p"}
            """#)
        XCTAssertEqual(request.kind, .permissionRequest)
        XCTAssertTrue(request.decisionSupported)
        XCTAssertFalse(request.canAlwaysAllow)
        XCTAssertTrue(copilot.expectsDecision(request))
        XCTAssertLessThan(copilot.decisionTimeout, 900)

        let allow = try XCTUnwrap(copilot.render(.allow, for: request).stdout)
        let allowJSON = try JSONValue.parse(Data(allow.utf8))
        XCTAssertEqual(allowJSON["behavior"]?.string, "allow")
        XCTAssertEqual(allowJSON.at("hookSpecificOutput", "hookEventName")?.string, "PermissionRequest")
        XCTAssertEqual(allowJSON.at("hookSpecificOutput", "decision", "behavior")?.string, "allow")
        XCTAssertEqual(copilot.render(.allowAlways, for: request).stdout, allow, "no remember flag: a plain allow")

        let deny = try JSONValue.parse(Data(try XCTUnwrap(copilot.render(.deny(reason: nil), for: request).stdout).utf8))
        XCTAssertEqual(deny["behavior"]?.string, "deny")
        XCTAssertEqual(deny["message"]?.string, ClaudeCompatibleAdapter.defaultDenyMessage)
        XCTAssertEqual(copilot.render(.askInTerminal, for: request), .passthrough)
        XCTAssertEqual(copilot.render(.askInTerminal, for: request).exitCode, 0)
    }

    // MARK: Grok

    private let grok = Adapters.adapter(for: .grok)

    func testGrokCamelCasePayloads() throws {
        let pre = try event(grok, #"""
            {"hookEventName":"pre_tool_use","sessionId":"g-1","cwd":"/Users/me/proj","workspaceRoot":"/Users/me/proj",
             "toolName":"run_terminal_command","toolInput":{"command":"npm test"},"toolUseId":"t1",
             "toolInputTruncated":false,"timestamp":"2026-04-14T12:00:00Z"}
            """#)
        XCTAssertEqual(pre.source, .grok)
        XCTAssertEqual(pre.kind, .toolWillRun)
        XCTAssertEqual(pre.sessionId, "g-1")
        XCTAssertEqual(pre.toolName, "run_terminal_command")
        XCTAssertEqual(pre.toolSummary, "npm test")
        XCTAssertFalse(grok.expectsDecision(pre), "Grok can only gate every call: observe")
        XCTAssertEqual(grok.render(.deny(reason: "x"), for: pre), .passthrough)

        for (name, kind) in [("session_start", EventKind.sessionStart), ("user_prompt_submit", .promptSubmitted),
                             ("post_tool_use_failure", .toolFailed), ("stop", .stop), ("stop_failure", .stopFailed),
                             ("SubagentEnd", .subagentStop), ("session_end", .sessionEnd), ("PermissionDenied", .other)] {
            let e = try event(grok, #"{"hookEventName":"\#(name)","sessionId":"g-1"}"#)
            XCTAssertEqual(e.kind, kind, name)
        }
        let note = try event(grok, #"{"hookEventName":"notification","sessionId":"g-1","message":"Grok needs input"}"#)
        XCTAssertEqual(note.kind, .notification)
        XCTAssertEqual(note.message, "Grok needs input")
    }

    func testGrokFallsBackToRunnerEnvironment() throws {
        let host = HostContext(extra: ["GROK_HOOK_EVENT": "stop", "GROK_SESSION_ID": "g-9", "GROK_WORKSPACE_ROOT": "/w"])
        let e = try event(grok, "{}", host: host)
        XCTAssertEqual(e.kind, .stop)
        XCTAssertEqual(e.sessionId, "g-9")
        XCTAssertEqual(e.cwd, "/w")
        XCTAssertThrowsError(try event(grok, #"{"hookEventName":"stop"}"#), "no session id anywhere")
    }

    // MARK: Cline

    private let cline = ClineAdapter()

    func testClineTaskLifecycle() throws {
        let start = try event(cline, #"""
            {"clineVersion":"4.1.20","hookName":"TaskStart","timestamp":"1759230000000","taskId":"1759230000000",
             "workspaceRoots":["/Users/me/site"],"userId":"me","model":{"provider":"anthropic","slug":"claude"},
             "taskStart":{"taskMetadata":{"taskId":"1759230000000","ulid":"01K","initialTask":"Build the landing page"}}}
            """#)
        XCTAssertEqual(start.source, .cline)
        XCTAssertEqual(start.kind, .promptSubmitted, "a task starts working at once")
        XCTAssertEqual(start.message, "Build the landing page")
        XCTAssertEqual(start.sessionId, "1759230000000")
        XCTAssertEqual(start.cwd, "/Users/me/site")
        XCTAssertNil(start.raw["userId"])
        XCTAssertFalse(cline.expectsDecision(start))

        let done = try event(cline, #"""
            {"hookName":"TaskComplete","taskId":"1","workspaceRoots":["/w"],
             "taskComplete":{"taskMetadata":{"taskId":"1","ulid":"u","result":"Page built.","command":""}}}
            """#)
        XCTAssertEqual(done.kind, .stop)
        XCTAssertEqual(done.message, "Page built.")
        XCTAssertEqual(try event(cline, #"{"hookName":"TaskCancel","taskId":"1"}"#).kind, .interrupted)
        XCTAssertEqual(try event(cline, #"{"hookName":"SessionShutdown","taskId":"1"}"#).kind, .sessionEnd)
        let error = try event(cline, #"{"hookName":"TaskError","taskId":"1","error":{"name":"ApiError","message":"429"}}"#)
        XCTAssertEqual(error.kind, .stopFailed)
        XCTAssertEqual(error.message, "429")
    }

    func testClineTools() throws {
        let pre = try event(cline, #"""
            {"hookName":"PreToolUse","taskId":"1","workspaceRoots":["/w"],
             "preToolUse":{"toolName":"execute_command","parameters":{"command":"\"npm run build\"","requires_approval":"false"}}}
            """#)
        XCTAssertEqual(pre.kind, .toolWillRun)
        XCTAssertEqual(pre.toolName, "execute_command")
        XCTAssertEqual(pre.toolSummary, "npm run build", "JSON-stringified parameter values are decoded")

        let post = try event(cline, #"""
            {"hookName":"PostToolUse","taskId":"1","postToolUse":{"toolName":"write_to_file",
             "parameters":{"path":"src/a.ts"},"result":"permission denied","success":false,"executionTimeMs":3}}
            """#)
        XCTAssertEqual(post.kind, .toolFailed)
        XCTAssertEqual(post.toolSummary, "src/a.ts")
        XCTAssertEqual(post.message, "permission denied")
    }

    func testClineNotificationsOnlyWaitWhenClineSaysSo() throws {
        let waiting = try event(cline, #"""
            {"hookName":"Notification","taskId":"1","notification":{"event":"ask","message":"Approve command?",
             "waitingForUserInput":true,"requiresUserAction":true}}
            """#)
        XCTAssertEqual(waiting.kind, .notification)
        XCTAssertEqual(waiting.message, "Approve command?")
        let info = try event(cline, #"""
            {"hookName":"Notification","taskId":"1","notification":{"event":"say","message":"Checkpoint saved"}}
            """#)
        XCTAssertEqual(info.kind, .other)
        XCTAssertThrowsError(try event(cline, #"{"hookName":"TaskStart"}"#))
    }
}
