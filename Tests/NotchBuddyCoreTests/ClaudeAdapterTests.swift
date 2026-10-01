import XCTest
@testable import NotchBuddyCore

/// Fixtures follow Claude Code 2.1.185's payload builders and the hooks docs' examples.
final class ClaudeAdapterTests: XCTestCase {
    private let adapter = ClaudeAdapter()
    private let common = #""session_id":"abc123","transcript_path":"/Users/u/.claude/projects/-Users-u-proj/abc123.jsonl","cwd":"/Users/u/proj""#

    private func event(_ json: String, host: HostContext = HostContext()) throws -> AgentEvent {
        try adapter.normalize(stdin: Data((json + "\n").utf8), host: host)
    }

    private func payload(_ fields: String) -> String { "{\(common),\(fields)}" }

    private func permission(tool: String, input: String, suggestions: String? = nil) throws -> AgentEvent {
        let extra = suggestions.map { #","permission_suggestions":\#($0)"# } ?? ""
        return try event(payload(
            #""permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"\#(tool)","tool_input":\#(input)\#(extra)"#))
    }

    private func stdoutJSON(_ output: BridgeOutput, file: StaticString = #filePath, line: UInt = #line) throws -> JSONValue {
        let text = try XCTUnwrap(output.stdout, file: file, line: line)
        return try JSONValue.parse(Data(text.utf8))
    }

    // MARK: normalize — every mapped event

    func testSessionStart() throws {
        let e = try event(payload(#""hook_event_name":"SessionStart","source":"startup","model":"claude-opus-5-5""#))
        XCTAssertEqual(e.source, .claude)
        XCTAssertEqual(e.hookEventName, "SessionStart")
        XCTAssertEqual(e.kind, .sessionStart)
        XCTAssertEqual(e.sessionId, "abc123")
        XCTAssertEqual(e.cwd, "/Users/u/proj")
        XCTAssertNil(e.toolName)
        XCTAssertNil(e.toolSummary)
        XCTAssertNil(e.message)
        XCTAssertFalse(e.decisionSupported)
        XCTAssertFalse(adapter.expectsDecision(e))
        XCTAssertEqual(e.raw["source"], "startup")
    }

    func testTranscriptPathAndSessionTitle() throws {
        let e = try event(payload(#""hook_event_name":"SessionStart","source":"resume","session_title":"Игра в змейку""#))
        XCTAssertEqual(e.transcriptPath, "/Users/u/.claude/projects/-Users-u-proj/abc123.jsonl")
        XCTAssertEqual(e.sessionTitle, "Игра в змейку")
        let bare = try event(#"{"session_id":"abc123","hook_event_name":"Stop","transcript_path":""}"#)
        XCTAssertNil(bare.transcriptPath)
        XCTAssertNil(bare.sessionTitle)
    }

    func testSessionEnd() throws {
        let e = try event(payload(#""hook_event_name":"SessionEnd","reason":"prompt_input_exit""#))
        XCTAssertEqual(e.kind, .sessionEnd)
        XCTAssertEqual(e.raw["reason"], "prompt_input_exit")
    }

    func testUserPromptSubmitCarriesPrompt() throws {
        let e = try event(payload(#""permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"fix the build\nplease""#))
        XCTAssertEqual(e.kind, .promptSubmitted)
        XCTAssertEqual(e.message, "fix the build\nplease")
    }

    func testPreToolUse() throws {
        let e = try event(payload(#"""
            "permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"Bash",\#
            "tool_input":{"command":"npm test","description":"Run test suite","timeout":120000,"run_in_background":false},\#
            "tool_use_id":"toolu_01ABC"
            """#))
        XCTAssertEqual(e.kind, .toolWillRun)
        XCTAssertEqual(e.toolName, "Bash")
        XCTAssertEqual(e.toolSummary, "npm test")
        XCTAssertFalse(adapter.expectsDecision(e))
    }

    func testPostToolUse() throws {
        let e = try event(payload(#"""
            "permission_mode":"default","hook_event_name":"PostToolUse","tool_name":"Edit",\#
            "tool_input":{"file_path":"/Users/u/proj/a.swift","old_string":"a","new_string":"b"},\#
            "tool_response":{"filePath":"/Users/u/proj/a.swift","success":true},"tool_use_id":"toolu_02","duration_ms":12
            """#))
        XCTAssertEqual(e.kind, .toolDidRun)
        XCTAssertEqual(e.toolName, "Edit")
        XCTAssertEqual(e.toolSummary, "/Users/u/proj/a.swift")
    }

    func testPostToolUseFailure() throws {
        let e = try event(payload(#"""
            "permission_mode":"default","hook_event_name":"PostToolUseFailure","tool_name":"Bash",\#
            "tool_input":{"command":"false"},"tool_use_id":"toolu_03","error":"Exit code 1\nboom","is_interrupt":false
            """#))
        XCTAssertEqual(e.kind, .toolFailed)
        XCTAssertEqual(e.toolName, "Bash")
        XCTAssertEqual(e.toolSummary, "false")
        XCTAssertEqual(e.message, "Exit code 1 ⏎ boom")
    }

    func testPermissionRequest() throws {
        let e = try permission(tool: "Bash", input: #"{"command":"rm -rf node_modules","description":"Remove node_modules directory"}"#,
                               suggestions: #"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"}],"behavior":"allow","destination":"localSettings"}]"#)
        XCTAssertEqual(e.kind, .permissionRequest)
        XCTAssertEqual(e.hookEventName, "PermissionRequest")
        XCTAssertEqual(e.toolName, "Bash")
        XCTAssertEqual(e.toolSummary, "rm -rf node_modules")
        XCTAssertTrue(e.decisionSupported)
        XCTAssertTrue(e.canAlwaysAllow)
        XCTAssertTrue(adapter.expectsDecision(e))
    }

    func testNotificationCarriesMessage() throws {
        let e = try event(payload(#""hook_event_name":"Notification","message":"Claude needs your permission","title":"Permission needed","notification_type":"permission_prompt""#))
        XCTAssertEqual(e.kind, .notification)
        XCTAssertEqual(e.message, "Claude needs your permission")
    }

    func testNotificationFallsBackToTitle() throws {
        let e = try event(payload(#""hook_event_name":"Notification","message":"","title":"Permission needed","notification_type":"permission_prompt""#))
        XCTAssertEqual(e.message, "Permission needed")
    }

    func testOnlyAttentionNotificationTypesMeanWaiting() throws {
        func notification(_ type: String?) throws -> AgentEvent {
            let typeField = type.map { #","notification_type":"\#($0)""# } ?? ""
            return try event(payload(#""hook_event_name":"Notification","message":"m""# + typeField))
        }
        for type in ["permission_prompt", "idle_prompt", "elicitation_dialog", "elicitation_url_dialog",
                     "agent_needs_input", "worker_permission_prompt"] {
            XCTAssertEqual(try notification(type).kind, .notification, type)
        }
        XCTAssertEqual(try notification(nil).kind, .notification, "older builds send no type")
        XCTAssertEqual(try notification("").kind, .notification)
        for type in ["computer_use_enter", "computer_use_exit", "elicitation_complete", "elicitation_response",
                     "auth_success", "agent_completed", "quota_auto_resume_scheduled", "push_notification", "future_type"] {
            let e = try notification(type)
            XCTAssertEqual(e.kind, .other, type)
            XCTAssertEqual(e.hookEventName, "Notification")
        }
    }

    func testInformationalNotificationDoesNotMarkSessionWaiting() throws {
        var store = SessionStore()
        store.apply(try event(payload(#""permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"go""#)))
        let effects = store.apply(try event(payload(
            #""hook_event_name":"Notification","message":"Claude is using your computer · press Esc to stop","notification_type":"computer_use_enter""#)))
        let key = SessionKey(source: .claude, sessionId: "abc123")
        XCTAssertEqual(effects, [])
        XCTAssertEqual(store.sessions[key]?.status, .working)

        store.apply(try event(payload(#""hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt""#)))
        XCTAssertEqual(store.sessions[key]?.status, .waitingForUser)
    }

    func testStop() throws {
        let e = try event(payload(#""permission_mode":"default","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done. Tests pass.","background_tasks":[],"session_crons":[]"#))
        XCTAssertEqual(e.kind, .stop)
        XCTAssertEqual(e.message, "Done. Tests pass.")
        XCTAssertFalse(adapter.expectsDecision(e))
    }

    func testStopFailure() throws {
        let e = try event(payload(#""hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"API Error: 429 rate limited""#))
        XCTAssertEqual(e.kind, .stopFailed)
        XCTAssertEqual(e.message, "Достигнут лимит запросов — API Error: 429 rate limited")

        let unknown = try event(payload(#""hook_event_name":"StopFailure","error":"teapot""#))
        XCTAssertEqual(unknown.message, "Ошибка API (teapot)")
    }

    func testSubagentStartAndStop() throws {
        let start = try event(payload(#""hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"Explore""#))
        XCTAssertEqual(start.kind, .subagentStart)
        XCTAssertEqual(start.message, "Explore")
        XCTAssertEqual(start.agentId, "a1")

        let stop = try event(payload(#"""
            "permission_mode":"default","hook_event_name":"SubagentStop","stop_hook_active":false,"agent_id":"a1",\#
            "agent_type":"","agent_transcript_path":"/tmp/a1.jsonl","last_assistant_message":"ok"
            """#))
        XCTAssertEqual(stop.kind, .subagentStop)
        XCTAssertNil(stop.message, "internal agents have an empty agent_type")
        XCTAssertEqual(stop.sessionId, "abc123", "subagents carry the parent's session_id")
    }

    func testAgentIdComesFromSubagentPayloadsOnly() throws {
        let sub = try event(payload(#"""
            "permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash",\#
            "tool_input":{"command":"npm test"},"agent_id":"agent-bg-1","agent_type":"general-purpose"
            """#))
        XCTAssertEqual(sub.agentId, "agent-bg-1")
        XCTAssertEqual(sub.sessionId, "abc123")
        XCTAssertNil(try permission(tool: "Bash", input: #"{"command":"ls"}"#).agentId)
        XCTAssertNil(try event(payload(#""hook_event_name":"Stop","agent_id":"""#)).agentId)
        XCTAssertNil(try event(payload(#""hook_event_name":"Stop","agent_type":"reviewer""#)).agentId, "--agent sets agent_type only")
    }

    func testPreAndPostCompact() throws {
        let pre = try event(payload(#""hook_event_name":"PreCompact","trigger":"auto","custom_instructions":null"#))
        let post = try event(payload(#""hook_event_name":"PostCompact","trigger":"manual","compact_summary":"…""#))
        XCTAssertEqual(pre.kind, .compact)
        XCTAssertEqual(post.kind, .compact)
    }

    func testUnknownEventIsOther() throws {
        let e = try event(payload(#""hook_event_name":"CwdChanged","old_cwd":"/a","new_cwd":"/b""#))
        XCTAssertEqual(e.kind, .other)
        XCTAssertEqual(e.hookEventName, "CwdChanged")
        let denied = try event(payload(#""hook_event_name":"PermissionDenied","tool_name":"Bash","tool_input":{"command":"x"},"reason":"auto""#))
        XCTAssertEqual(denied.kind, .other)
        XCTAssertFalse(denied.decisionSupported)
    }

    func testRawIsKeptUntouched() throws {
        let json = payload(#""hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x"},"effort":{"level":"high"}"#)
        let e = try event(json)
        XCTAssertEqual(e.raw, try JSONValue.parse(Data(json.utf8)))
    }

    // MARK: normalize — malformed input

    func testMalformedInputThrowsInvalidJSON() {
        for bad in ["", "not json", "{\"session_id\":", "[1,2]", "\"PreToolUse\"", "42", "null"] {
            XCTAssertThrowsError(try adapter.normalize(stdin: Data(bad.utf8), host: HostContext()), "input: \(bad)") {
                XCTAssertEqual($0 as? AdapterError, .invalidJSON, "input: \(bad)")
            }
        }
    }

    func testMissingFieldsThrow() {
        XCTAssertThrowsError(try event(#"{"session_id":"s"}"#)) {
            XCTAssertEqual($0 as? AdapterError, .missingField("hook_event_name"))
        }
        XCTAssertThrowsError(try event(#"{"hook_event_name":"Stop"}"#)) {
            XCTAssertEqual($0 as? AdapterError, .missingField("session_id"))
        }
    }

    // MARK: host hints

    func testSessionIdFallsBackToEnvCapturedByBridge() throws {
        let host = HostContext(extra: ["CLAUDE_CODE_SESSION_ID": "from-env"])
        let e = try event(#"{"hook_event_name":"Stop"}"#, host: host)
        XCTAssertEqual(e.sessionId, "from-env")
        XCTAssertEqual(try event(payload(#""hook_event_name":"Stop""#), host: host).sessionId, "abc123")
    }

    func testClaudePidFillsAgentPidOnlyWhenMissing() throws {
        let json = payload(#""hook_event_name":"Stop""#)
        XCTAssertEqual(try event(json, host: HostContext(extra: ["CLAUDE_PID": "4242"])).host.agentPid, 4242)
        XCTAssertEqual(try event(json, host: HostContext(agentPid: 7, extra: ["CLAUDE_PID": "4242"])).host.agentPid, 7)
        XCTAssertNil(try event(json, host: HostContext(extra: ["CLAUDE_PID": "garbage"])).host.agentPid)
    }

    func testDesktopCodeSessionHint() throws {
        let json = payload(#""hook_event_name":"Stop""#)
        let desktopEnv = ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop", "CLAUDE_CODE_HOST_SESSION_ID": "local_1234"]
        let desktop = try event(json, host: HostContext(extra: desktopEnv))
        XCTAssertEqual(desktop.host.bundleIdentifier, "com.anthropic.claudefordesktop")
        XCTAssertEqual(desktop.host.extra, desktopEnv, "extra is passed through")

        // Entrypoint is inherited by terminals opened from Desktop: a TTY or a real bundle id wins.
        let terminal = try event(json, host: HostContext(bundleIdentifier: "com.googlecode.iterm2", extra: desktopEnv))
        XCTAssertEqual(terminal.host.bundleIdentifier, "com.googlecode.iterm2")
        XCTAssertNil(try event(json, host: HostContext(tty: "/dev/ttys003", extra: desktopEnv)).host.bundleIdentifier)
        XCTAssertNil(try event(json, host: HostContext(extra: ["CLAUDE_CODE_ENTRYPOINT": "cli"])).host.bundleIdentifier)
    }

    // MARK: decision support

    func testAskUserQuestionIsNotAnswerableFromIsland() throws {
        let e = try permission(tool: "AskUserQuestion",
                               input: #"{"questions":[{"question":"Which DB?","header":"DB","options":[{"label":"Postgres"},{"label":"SQLite"}],"multiSelect":false},{"question":"Tests?","header":"T","options":[],"multiSelect":false}]}"#)
        XCTAssertEqual(e.kind, .permissionRequest)
        XCTAssertFalse(e.decisionSupported)
        XCTAssertFalse(e.canAlwaysAllow)
        XCTAssertFalse(adapter.expectsDecision(e))
        XCTAssertEqual(e.toolSummary, "Which DB? (ещё 1)")
        for d: PermissionDecision in [.allow, .allowAlways, .deny(reason: nil), .askInTerminal] {
            XCTAssertEqual(adapter.render(d, for: e), .passthrough)
        }
    }

    func testCanAlwaysAllowRequiresUsableSuggestion() throws {
        let input = #"{"command":"ls"}"#
        XCTAssertFalse(try permission(tool: "Bash", input: input).canAlwaysAllow)
        XCTAssertFalse(try permission(tool: "Bash", input: input, suggestions: "[]").canAlwaysAllow)
        let unusable = [
            #"[{"type":"addRules","rules":[{"toolName":"Bash"}],"behavior":"allow","destination":"cliArg"}]"#,
            #"[{"type":"addRules","rules":[{"toolName":"Bash"}],"behavior":"deny","destination":"session"}]"#,
            #"[{"type":"addRules","rules":[],"behavior":"allow","destination":"session"}]"#,
            #"[{"type":"addRules","rules":[{"ruleContent":"ls"}],"behavior":"allow","destination":"session"}]"#,
            #"[{"type":"setMode","mode":"manual","destination":"session"}]"#,
            #"[{"type":"setMode","mode":"bypassPermissions","destination":"session"}]"#,
            #"[{"type":"removeRules","rules":[{"toolName":"Bash"}],"behavior":"allow","destination":"session"}]"#,
            #"[{"type":"addDirectories","directories":[],"destination":"session"}]"#,
            #"["garbage",42]"#,
        ]
        for s in unusable {
            XCTAssertFalse(try permission(tool: "Bash", input: input, suggestions: s).canAlwaysAllow, s)
        }
        let usable = [
            #"[{"type":"addRules","rules":[{"toolName":"WebFetch"}],"behavior":"allow","destination":"session"}]"#,
            #"[{"type":"setMode","mode":"acceptEdits","destination":"session"}]"#,
            #"[{"type":"addDirectories","directories":["/tmp/x"],"destination":"session"}]"#,
        ]
        for s in usable {
            XCTAssertTrue(try permission(tool: "Bash", input: input, suggestions: s).canAlwaysAllow, s)
        }
    }

    // MARK: render

    func testRenderAllow() throws {
        let e = try permission(tool: "Bash", input: #"{"command":"npm test"}"#)
        let out = adapter.render(.allow, for: e)
        XCTAssertEqual(out.stdout, #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertNil(out.stderr)
    }

    func testRenderDenyWithMessage() throws {
        let e = try permission(tool: "Bash", input: #"{"command":"rm -rf /"}"#)
        let out = adapter.render(.deny(reason: "Не трогай корень"), for: e)
        XCTAssertEqual(out.stdout, #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Не трогай корень"},"hookEventName":"PermissionRequest"}}"#)
        XCTAssertEqual(out.exitCode, 0)
    }

    func testRenderDenyWithoutReasonUsesDefaultMessage() throws {
        let e = try permission(tool: "Bash", input: #"{"command":"rm -rf /"}"#)
        for reason in [nil, "", "  \n"] as [String?] {
            let json = try stdoutJSON(adapter.render(.deny(reason: reason), for: e))
            XCTAssertEqual(json.at("hookSpecificOutput", "decision"),
                           ["behavior": "deny", "message": "Запрещено пользователем в NotchBuddy"])
        }
    }

    func testRenderDenyCapsMessageLength() throws {
        let e = try permission(tool: "Bash", input: #"{"command":"x"}"#)
        let json = try stdoutJSON(adapter.render(.deny(reason: String(repeating: "я", count: 20_000)), for: e))
        XCTAssertEqual(json.at("hookSpecificOutput", "decision", "message")?.string?.count, 10_000)
    }

    func testRenderAskInTerminalIsPassthrough() throws {
        let e = try permission(tool: "Bash", input: #"{"command":"ls"}"#)
        let out = adapter.render(.askInTerminal, for: e)
        XCTAssertEqual(out, .passthrough)
        XCTAssertNil(out.stdout)
        XCTAssertEqual(out.exitCode, 0)
    }

    func testRenderAllowAlwaysEchoesSuggestion() throws {
        let e = try permission(tool: "Bash", input: #"{"command":"rm -rf node_modules"}"#,
                               suggestions: #"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"}],"behavior":"allow","destination":"localSettings"}]"#)
        let out = adapter.render(.allowAlways, for: e)
        XCTAssertEqual(out.stdout, #"{"hookSpecificOutput":{"decision":{"behavior":"allow","updatedPermissions":[{"behavior":"allow","destination":"localSettings","rules":[{"ruleContent":"rm -rf node_modules","toolName":"Bash"}],"type":"addRules"}]},"hookEventName":"PermissionRequest"}}"#)
        XCTAssertEqual(out.exitCode, 0)
    }

    func testRenderAllowAlwaysEchoesEveryUsableSuggestionBestFirst() throws {
        let setMode: JSONValue = ["type": "setMode", "mode": "acceptEdits", "destination": "session"]
        let dirs: JSONValue = ["type": "addDirectories", "directories": ["/tmp/other"], "destination": "session"]
        let sessionRule: JSONValue = ["type": "addRules", "rules": [["toolName": "Read", "ruleContent": "/tmp/other/**"]],
                                      "behavior": "allow", "destination": "session"]
        let localRule: JSONValue = ["type": "addRules", "rules": [["toolName": "Read", "ruleContent": "/tmp/other/**"]],
                                    "behavior": "allow", "destination": "localSettings"]
        let realPathRule: JSONValue = ["type": "addRules", "rules": [["toolName": "Read", "ruleContent": "/private/tmp/other/**"]],
                                       "behavior": "allow", "destination": "session"]
        let bypass: JSONValue = ["type": "setMode", "mode": "bypassPermissions", "destination": "session"]
        let cases: [([JSONValue], [JSONValue])] = [
            // The same rules for two destinations are written once, to the best one.
            ([dirs, setMode, sessionRule, localRule], [localRule, setMode, dirs]),
            ([dirs, setMode, sessionRule], [sessionRule, setMode, dirs]),
            // Edit outside the working dirs: accept-edits alone would keep prompting there.
            ([setMode, dirs], [setMode, dirs]),
            ([dirs, setMode], [setMode, dirs]),
            ([dirs], [dirs]),
            // One rule per resolved (symlink) path, as Claude sends for Read.
            ([sessionRule, realPathRule], [sessionRule, realPathRule]),
            // Unsafe or unusable entries are never echoed.
            ([bypass, dirs, "garbage"], [dirs]),
        ]
        for (suggestions, expected) in cases {
            let list = String(decoding: JSONValue.array(suggestions).serialized(), as: UTF8.self)
            let e = try permission(tool: "Read", input: #"{"file_path":"/tmp/other/a.txt"}"#, suggestions: list)
            XCTAssertTrue(e.canAlwaysAllow)
            let json = try stdoutJSON(adapter.render(.allowAlways, for: e))
            XCTAssertEqual(json.at("hookSpecificOutput", "decision", "updatedPermissions"), .array(expected), list)
            XCTAssertEqual(json.at("hookSpecificOutput", "decision", "behavior"), "allow")
        }
    }

    func testRenderAllowAlwaysWithoutSuggestionIsPlainAllow() throws {
        let e = try permission(tool: "Bash", input: #"{"command":"ls"}"#,
                               suggestions: #"[{"type":"setMode","mode":"manual","destination":"session"}]"#)
        XCTAssertFalse(e.canAlwaysAllow)
        XCTAssertEqual(adapter.render(.allowAlways, for: e).stdout,
                       #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
    }

    func testExitPlanModeAllowEchoesToolInput() throws {
        let input = ##"{"plan":"# Plan\n1. Do it","planFilePath":"/Users/u/.claude/plans/p.md"}"##
        let e = try permission(tool: "ExitPlanMode", input: input)
        XCTAssertTrue(e.decisionSupported)
        XCTAssertTrue(adapter.expectsDecision(e))
        XCTAssertEqual(e.toolSummary, "# Plan ⏎ 1. Do it")

        let out = adapter.render(.allow, for: e)
        XCTAssertEqual(out.stdout, ##"{"hookSpecificOutput":{"decision":{"behavior":"allow","updatedInput":{"plan":"# Plan\n1. Do it","planFilePath":"/Users/u/.claude/plans/p.md"}},"hookEventName":"PermissionRequest"}}"##)
        let json = try stdoutJSON(out)
        XCTAssertEqual(json.at("hookSpecificOutput", "decision", "updatedInput"), try JSONValue.parse(Data(input.utf8)))

        // Deny needs no updatedInput.
        XCTAssertEqual(try stdoutJSON(adapter.render(.deny(reason: "Доработай план"), for: e)).at("hookSpecificOutput", "decision"),
                       ["behavior": "deny", "message": "Доработай план"])
    }

    func testExitPlanModeAllowAlwaysAcceptsEditsForSession() throws {
        let e = try permission(tool: "ExitPlanMode", input: #"{"plan":"p"}"#)
        XCTAssertTrue(e.canAlwaysAllow)
        XCTAssertEqual(adapter.render(.allowAlways, for: e).stdout,
                       #"{"hookSpecificOutput":{"decision":{"behavior":"allow","updatedInput":{"plan":"p"},"updatedPermissions":[{"destination":"session","mode":"acceptEdits","type":"setMode"}]},"hookEventName":"PermissionRequest"}}"#)
    }

    func testExitPlanModeWithoutObjectInputIsNotAnswerable() throws {
        let e = try event(payload(#""hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode""#))
        XCTAssertFalse(e.decisionSupported)
        XCTAssertEqual(adapter.render(.allow, for: e), .passthrough)
    }

    func testNonPermissionEventsNeverProduceOutput() throws {
        let events = [
            payload(#""hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}"#),
            payload(#""hook_event_name":"UserPromptSubmit","prompt":"hi""#),
            payload(#""hook_event_name":"SessionStart","source":"startup""#),
            payload(#""hook_event_name":"Notification","message":"m","notification_type":"idle_prompt""#),
            payload(#""hook_event_name":"Stop""#),
        ]
        for json in events {
            let e = try event(json)
            for d: PermissionDecision in [.allow, .allowAlways, .deny(reason: "x"), .askInTerminal] {
                XCTAssertEqual(adapter.render(d, for: e), .passthrough, json)
            }
        }
    }

    func testRenderWorksAfterWireRoundTrip() throws {
        let e = try permission(tool: "ExitPlanMode", input: #"{"plan":"p","n":120000,"f":1.5}"#)
        let frame = try Wire.frame(BridgeRequest(event: e, expectsReply: adapter.expectsDecision(e)))
        var buffer = frame
        let payload = try XCTUnwrap(try Wire.takeFrame(from: &buffer))
        let decoded = try Wire.decode(BridgeRequest.self, from: payload)
        XCTAssertTrue(decoded.expectsReply)
        XCTAssertEqual(adapter.render(.allow, for: decoded.event), adapter.render(.allow, for: e))
        XCTAssertEqual(adapter.render(.allow, for: decoded.event).stdout,
                       #"{"hookSpecificOutput":{"decision":{"behavior":"allow","updatedInput":{"f":1.5,"n":120000,"plan":"p"}},"hookEventName":"PermissionRequest"}}"#)
    }

    func testAdapterRegistryReturnsClaudeAdapter() {
        XCTAssertEqual(Adapters.adapter(for: .claude).source, .claude)
        XCTAssertTrue(Adapters.adapter(for: .claude) is ClaudeAdapter)
    }
}
