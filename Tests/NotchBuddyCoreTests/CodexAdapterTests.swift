import XCTest
@testable import NotchBuddyCore

/// Fixtures follow payloads captured from a real Codex run.
final class CodexAdapterTests: XCTestCase {
    private let adapter = CodexAdapter()
    private let host = HostContext(termProgram: "iTerm.app", tty: "/dev/ttys003", agentPid: 4242)

    private static let session = "01a0edec-f31e-7fb2-9fec-71f66d1e0851"
    private static let turn = "01a0edec-f39e-7b93-9f98-c0a258005684"
    private static let transcript = "/tmp/home/sessions/2026/09/29/rollout-2026-09-29T19-08-44-01a0edec-f31e-7fb2-9fec-71f66d1e0851.jsonl"
    private static let patch = "*** Begin Patch\n*** Update File: a.txt\n@@\n-old\n+new\n*** End Patch"

    private static let allowJSON =
        #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#

    // MARK: Fixtures

    private func payload(_ event: String, _ fields: [String: JSONValue] = [:], turnScoped: Bool = true) -> JSONValue {
        var o: [String: JSONValue] = [
            "session_id": .string(Self.session),
            "transcript_path": .string(Self.transcript),
            "cwd": "/tmp/proj",
            "hook_event_name": .string(event),
            "model": "mock-model",
            "permission_mode": "default",
        ]
        if turnScoped { o["turn_id"] = .string(Self.turn) }
        for (k, v) in fields { o[k] = v }
        return .object(o)
    }

    private func normalize(_ value: JSONValue) throws -> AgentEvent {
        try adapter.normalize(stdin: value.serialized(), host: host)
    }

    private func normalize(_ text: String) throws -> AgentEvent {
        try adapter.normalize(stdin: Data(text.utf8), host: host)
    }

    private var bashPermission: JSONValue {
        payload("PermissionRequest", [
            "tool_name": "Bash",
            "tool_input": ["command": "touch /tmp/nb_probe_marker_ALLOW", "description": "probe ALLOW justification"],
        ])
    }

    // MARK: Event mapping

    func testSessionStart() throws {
        let e = try normalize(payload("SessionStart", ["source": "startup"], turnScoped: false))
        XCTAssertEqual(e.kind, .sessionStart)
        XCTAssertEqual(e.source, .codex)
        XCTAssertEqual(e.hookEventName, "SessionStart")
        XCTAssertEqual(e.sessionId, Self.session)
        XCTAssertEqual(e.cwd, "/tmp/proj")
        XCTAssertNil(e.toolName)
        XCTAssertNil(e.toolSummary)
        XCTAssertNil(e.message)
        XCTAssertFalse(e.decisionSupported)
        XCTAssertFalse(e.canAlwaysAllow)
        XCTAssertEqual(e.host, host)
        XCTAssertFalse(adapter.expectsDecision(e))
    }

    func testSessionEndHasOnlyCommonFields() throws {
        let raw: JSONValue = [
            "session_id": .string(Self.session), "transcript_path": .string(Self.transcript),
            "cwd": "/tmp/proj", "hook_event_name": "SessionEnd", "reason": "other",
        ]
        let e = try normalize(raw)
        XCTAssertEqual(e.kind, .sessionEnd)
        XCTAssertEqual(e.sessionId, Self.session)
        XCTAssertEqual(e.raw, raw)
        XCTAssertEqual(e.transcriptPath, Self.transcript)
        XCTAssertNil(e.sessionTitle, "Codex names threads in its session index, not in the payload")
    }

    func testUserPromptSubmitCarriesPrompt() throws {
        let e = try normalize(payload("UserPromptSubmit", ["prompt": "Почини тесты"]))
        XCTAssertEqual(e.kind, .promptSubmitted)
        XCTAssertEqual(e.message, "Почини тесты")
        XCTAssertFalse(adapter.expectsDecision(e))
    }

    func testPreToolUse() throws {
        let e = try normalize(payload("PreToolUse", [
            "tool_name": "Bash", "tool_input": ["command": "touch /tmp/nb_probe_marker_ALLOW"],
            "tool_use_id": "call-ALLOW-1",
        ]))
        XCTAssertEqual(e.kind, .toolWillRun)
        XCTAssertEqual(e.toolName, "Bash")
        XCTAssertEqual(e.toolSummary, "touch /tmp/nb_probe_marker_ALLOW")
        XCTAssertFalse(e.decisionSupported)
        XCTAssertFalse(adapter.expectsDecision(e))
    }

    func testPermissionRequest() throws {
        let e = try normalize(bashPermission)
        XCTAssertEqual(e.kind, .permissionRequest)
        XCTAssertEqual(e.toolName, "Bash")
        // `command` wins over the model's `description`.
        XCTAssertEqual(e.toolSummary, "touch /tmp/nb_probe_marker_ALLOW")
        XCTAssertTrue(e.decisionSupported)
        XCTAssertFalse(e.canAlwaysAllow)
        XCTAssertTrue(adapter.expectsDecision(e))
        XCTAssertNil(e.message)
    }

    func testPostToolUse() throws {
        let e = try normalize(payload("PostToolUse", [
            "tool_name": "Bash", "tool_input": ["command": "touch /tmp/nb_probe_marker_ALLOW"],
            "tool_response": "", "tool_use_id": "call-ALLOW-1",
        ]))
        XCTAssertEqual(e.kind, .toolDidRun)
        XCTAssertEqual(e.toolName, "Bash")
        XCTAssertEqual(e.toolSummary, "touch /tmp/nb_probe_marker_ALLOW")
        XCTAssertFalse(e.decisionSupported)
    }

    func testCompactEvents() throws {
        for name in ["PreCompact", "PostCompact"] {
            let raw: JSONValue = [
                "session_id": .string(Self.session), "turn_id": .string(Self.turn), "transcript_path": .null,
                "cwd": "/tmp/proj", "hook_event_name": .string(name), "model": "mock-model", "trigger": "manual",
            ]
            let e = try normalize(raw)
            XCTAssertEqual(e.kind, .compact, name)
            XCTAssertEqual(e.hookEventName, name)
            XCTAssertNil(e.transcriptPath, "null when the thread has no local rollout")
        }
    }

    func testSubagentStart() throws {
        let e = try normalize(payload("SubagentStart", ["agent_id": "01a0edee-0000", "agent_type": "explorer"]))
        XCTAssertEqual(e.kind, .subagentStart)
        XCTAssertEqual(e.sessionId, Self.session)
        XCTAssertNil(e.message)
        XCTAssertEqual(e.agentId, "01a0edee-0000")
    }

    /// Spawned subagents keep the root session_id and add agent_id; the root thread omits it.
    func testAgentIdFromSubagentEvents() throws {
        var sub = bashPermission
        if case .object(var o) = sub { o["agent_id"] = "01a0edee-0000"; o["agent_type"] = "worker"; sub = .object(o) }
        let e = try normalize(sub)
        XCTAssertEqual(e.agentId, "01a0edee-0000")
        XCTAssertEqual(e.sessionId, Self.session)
        XCTAssertNil(try normalize(bashPermission).agentId)
        XCTAssertNil(try normalize(payload("Stop", ["agent_id": "  "])).agentId)
        XCTAssertEqual(try normalize(payload("UserPromptSubmit", ["prompt": "x", "agent_id": "01a0edee-0000"])).agentId,
                       "01a0edee-0000")
    }

    func testSubagentStopCarriesLastMessage() throws {
        let e = try normalize(payload("SubagentStop", [
            "agent_id": "01a0edee-0000", "agent_type": "explorer",
            "agent_transcript_path": "/tmp/sub.jsonl", "stop_hook_active": false,
            "last_assistant_message": "нашёл 3 файла",
        ]))
        XCTAssertEqual(e.kind, .subagentStop)
        XCTAssertEqual(e.message, "нашёл 3 файла")
    }

    func testStopCarriesLastAssistantMessage() throws {
        let e = try normalize(payload("Stop", ["stop_hook_active": false, "last_assistant_message": "done"]))
        XCTAssertEqual(e.kind, .stop)
        XCTAssertEqual(e.message, "done")
    }

    func testStopWithNullLastAssistantMessage() throws {
        let e = try normalize(payload("Stop", ["stop_hook_active": false, "last_assistant_message": .null]))
        XCTAssertEqual(e.kind, .stop)
        XCTAssertNil(e.message)
    }

    func testInterruptMapsToInterrupted() throws {
        let e = try normalize(payload("Interrupt"))
        XCTAssertEqual(e.kind, .interrupted)
        XCTAssertFalse(adapter.expectsDecision(e))
    }

    func testUnknownEventMapsToOther() throws {
        let e = try normalize(payload("Notification", ["message": "hi"]))
        XCTAssertEqual(e.kind, .other)
        XCTAssertEqual(e.hookEventName, "Notification")
        XCTAssertFalse(e.decisionSupported)
    }

    func testEventNamesAreCaseSensitive() throws {
        XCTAssertEqual(try normalize(payload("permissionrequest")).kind, .other)
    }

    func testRawPayloadIsKeptUntouched() throws {
        let raw = bashPermission
        XCTAssertEqual(try normalize(raw).raw, raw)
    }

    // MARK: Tool summaries

    func testApplyPatchSummariesMatchDespiteTrailingNewline() throws {
        // PermissionRequest drops the patch's trailing "\n" that PreToolUse/PostToolUse keep.
        let pre = try normalize(payload("PreToolUse", [
            "tool_name": "apply_patch", "tool_input": ["command": .string(Self.patch + "\n")], "tool_use_id": "call-1",
        ]))
        let permission = try normalize(payload("PermissionRequest", [
            "tool_name": "apply_patch", "tool_input": ["command": .string(Self.patch)],
        ]))
        let post = try normalize(payload("PostToolUse", [
            "tool_name": "apply_patch", "tool_input": ["command": .string(Self.patch + "\n")],
            "tool_response": "Success", "tool_use_id": "call-1",
        ]))
        XCTAssertEqual(permission.toolName, "apply_patch")
        XCTAssertEqual(permission.toolSummary, pre.toolSummary)
        XCTAssertEqual(permission.toolSummary, post.toolSummary)
        XCTAssertEqual(permission.toolSummary, ToolSummary.oneLine(Self.patch))
        XCTAssertFalse(permission.toolSummary?.hasSuffix("⏎ ") ?? true)
    }

    func testMcpToolSummaryUsesArguments() throws {
        let e = try normalize(payload("PermissionRequest", [
            "tool_name": "mcp__github__create_issue", "tool_input": ["query": "  crash on launch\n"],
        ]))
        XCTAssertEqual(e.toolName, "mcp__github__create_issue")
        XCTAssertEqual(e.toolSummary, "crash on launch")
    }

    func testMcpToolWithEmptyArgumentsHasNoSummary() throws {
        let e = try normalize(payload("PermissionRequest", ["tool_name": "mcp__x__ping", "tool_input": [:]]))
        XCTAssertNil(e.toolSummary)
    }

    func testWriteStdinSummaryUsesChars() throws {
        let e = try normalize(payload("PermissionRequest", [
            "tool_name": "write_stdin",
            "tool_input": ["session_id": 7, "chars": "yes\n", "tty": true, "cwd": "/tmp/proj"],
        ]))
        XCTAssertEqual(e.toolSummary, "yes")
    }

    func testRequestPermissionsSummaryUsesReason() throws {
        let e = try normalize(payload("PermissionRequest", [
            "tool_name": "request_permissions",
            "tool_input": ["reason": "нужен доступ к сети", "permissions": ["network": true]],
        ]))
        XCTAssertEqual(e.toolSummary, "нужен доступ к сети")
    }

    func testMissingOrOddToolInput() throws {
        XCTAssertNil(try normalize(payload("PermissionRequest", ["tool_name": "Bash"])).toolSummary)
        XCTAssertEqual(try normalize(payload("PreToolUse", ["tool_name": "Bash", "tool_input": "ls -la\n"])).toolSummary,
                       "ls -la")
        XCTAssertNil(try normalize(payload("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "  \n"]])).toolSummary)
    }

    // MARK: Malformed input

    func testMalformedInputThrows() {
        let cases: [(String, AdapterError)] = [
            ("", .invalidJSON),
            ("not json", .invalidJSON),
            (#"{"session_id": "s", "hook_event_name": "Stop""#, .invalidJSON),
            (#"[{"hook_event_name":"Stop"}]"#, .invalidJSON),
            (#""Stop""#, .invalidJSON),
            ("null", .invalidJSON),
            (#"{"session_id":"s"}"#, .missingField("hook_event_name")),
            (#"{"session_id":"s","hook_event_name":""}"#, .missingField("hook_event_name")),
            (#"{"session_id":"s","hook_event_name":null}"#, .missingField("hook_event_name")),
            (#"{"hook_event_name":"Stop"}"#, .missingField("session_id")),
            (#"{"hook_event_name":"Stop","session_id":"  "}"#, .missingField("session_id")),
            (#"{"hook_event_name":"Stop","session_id":{}}"#, .missingField("session_id")),
        ]
        for (input, expected) in cases {
            XCTAssertThrowsError(try normalize(input), input) { error in
                XCTAssertEqual(error as? AdapterError, expected, input)
            }
        }
    }

    func testMinimalPayloadIsAccepted() throws {
        let e = try normalize(#"{"session_id":"s1","hook_event_name":"PermissionRequest"}"#)
        XCTAssertEqual(e.kind, .permissionRequest)
        XCTAssertNil(e.cwd)
        XCTAssertNil(e.toolName)
        XCTAssertNil(e.toolSummary)
        XCTAssertTrue(adapter.expectsDecision(e))
    }

    func testWrongFieldTypesDegradeToNil() throws {
        let e = try normalize(#"{"session_id":"s1","hook_event_name":"Stop","cwd":["x"],"last_assistant_message":{"a":1}}"#)
        XCTAssertNil(e.cwd)
        XCTAssertNil(e.message)
    }

    // MARK: Rendering

    func testRenderAllowExactStdout() throws {
        let out = adapter.render(.allow, for: try normalize(bashPermission))
        XCTAssertEqual(out, BridgeOutput(stdout: Self.allowJSON, stderr: nil, exitCode: 0))
        try assertValidCodexOutput(out.stdout, behavior: "allow", message: nil)
    }

    func testRenderAllowAlwaysDegradesToPlainAllow() throws {
        let out = adapter.render(.allowAlways, for: try normalize(bashPermission))
        XCTAssertEqual(out.stdout, Self.allowJSON)
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertNil(out.stderr)
        for forbidden in ["updatedPermissions", "updatedInput", "interrupt"] {
            XCTAssertFalse(out.stdout?.contains(forbidden) ?? true, forbidden)
        }
    }

    func testRenderDenyWithReason() throws {
        let out = adapter.render(.deny(reason: "Denied from NotchBuddy"), for: try normalize(bashPermission))
        XCTAssertEqual(out.stdout,
                       #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from NotchBuddy"}}}"#)
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertNil(out.stderr)
        try assertValidCodexOutput(out.stdout, behavior: "deny", message: "Denied from NotchBuddy")
    }

    func testRenderDenyWithoutReasonUsesDefaultMessage() throws {
        let event = try normalize(bashPermission)
        for reason in [nil, "", "  \n"] as [String?] {
            let out = adapter.render(.deny(reason: reason), for: event)
            try assertValidCodexOutput(out.stdout, behavior: "deny", message: CodexAdapter.defaultDenyMessage)
        }
    }

    func testRenderDenyEscapesMessage() throws {
        let reason = "rm -rf \"/tmp/x\"\n\\ опасно\t✓"
        let out = adapter.render(.deny(reason: reason), for: try normalize(bashPermission))
        XCTAssertFalse(out.stdout?.contains("\n") ?? true, "stdout must be a single line")
        try assertValidCodexOutput(out.stdout, behavior: "deny", message: reason)
    }

    func testRenderAskInTerminalIsPassthrough() throws {
        XCTAssertEqual(adapter.render(.askInTerminal, for: try normalize(bashPermission)), .passthrough)
    }

    func testRenderForNonPermissionEventsIsPassthrough() throws {
        let events = try ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Interrupt",
                          "SessionEnd", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "Unknown"]
            .map { try normalize(payload($0)) }
        let decisions: [PermissionDecision] = [.allow, .allowAlways, .deny(reason: "нет"), .askInTerminal]
        for event in events {
            for decision in decisions {
                XCTAssertEqual(adapter.render(decision, for: event), .passthrough, "\(event.hookEventName) \(decision)")
            }
        }
    }

    // MARK: Misc

    func testDecisionTimeoutStaysBelowCodexDefaultHookTimeout() {
        XCTAssertLessThan(adapter.decisionTimeout, 600)
        XCTAssertGreaterThan(adapter.decisionTimeout, 60)
    }

    func testRegisteredInAdapters() {
        XCTAssertTrue(Adapters.adapter(for: .codex) is CodexAdapter)
        XCTAssertEqual(adapter.source, .codex)
    }

    // MARK: Helpers

    /// Checks the stdout against Codex's strict parser: a JSON object with only the allowed keys.
    private func assertValidCodexOutput(_ stdout: String?, behavior: String, message: String?,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try XCTUnwrap(stdout, file: file, line: line)
        XCTAssertEqual(text, text.trimmingCharacters(in: .whitespacesAndNewlines), "no surrounding text", file: file, line: line)
        let json = try JSONValue.parse(Data(text.utf8))
        XCTAssertEqual(Set(json.object.map { Array($0.keys) } ?? []), ["hookSpecificOutput"], file: file, line: line)
        let specific = try XCTUnwrap(json["hookSpecificOutput"]?.object, file: file, line: line)
        XCTAssertEqual(Set(specific.keys), ["hookEventName", "decision"], file: file, line: line)
        XCTAssertEqual(specific["hookEventName"], "PermissionRequest", file: file, line: line)
        let decision = try XCTUnwrap(specific["decision"]?.object, file: file, line: line)
        XCTAssertEqual(decision["behavior"], .string(behavior), file: file, line: line)
        XCTAssertEqual(decision["message"]?.string, message, file: file, line: line)
        XCTAssertEqual(Set(decision.keys), message == nil ? ["behavior"] : ["behavior", "message"], file: file, line: line)
    }
}
