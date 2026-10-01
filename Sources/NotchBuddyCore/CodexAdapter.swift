import Foundation

/// OpenAI Codex hooks. The CLI, the desktop app and the IDE extension share one hook engine.
public struct CodexAdapter: AgentAdapter {
    public init() {}

    public var source: AgentSource { .codex }

    /// Codex's default hook timeout is 600 s; stay below it in case the hook was registered without one,
    /// so the bridge hands the decision back to the terminal before Codex SIGKILLs it.
    public var decisionTimeout: TimeInterval { 590 }

    static let permissionEventName = "PermissionRequest"

    /// Deny `message` when the user gave no reason. Codex shows it in the UI and passes it to the model.
    static var defaultDenyMessage: String { L("Запрещено пользователем в NotchBuddy") }
    /// Codex hook event names (case-sensitive) → NotchBuddy event kinds. Unknown names map to `.other`.
    static let kinds: [String: EventKind] = [
        "SessionStart": .sessionStart,
        "SessionEnd": .sessionEnd,
        "UserPromptSubmit": .promptSubmitted,
        "PreToolUse": .toolWillRun,
        "PermissionRequest": .permissionRequest,
        "PostToolUse": .toolDidRun,
        "PreCompact": .compact,
        "PostCompact": .compact,
        "SubagentStart": .subagentStart,
        "SubagentStop": .subagentStop,
        "Stop": .stop,
        "Interrupt": .interrupted,
    ]

    /// Tools whose `tool_input` has no `command`: the field that best describes the call.
    static let summaryKeys: [String: String] = [
        "write_stdin": "chars",
        "request_permissions": "reason",
    ]

    // MARK: Normalize

    public func normalize(stdin: Data, host: HostContext) throws -> AgentEvent {
        let raw: JSONValue
        do { raw = try JSONValue.parse(stdin) } catch { throw AdapterError.invalidJSON }
        guard raw.object != nil else { throw AdapterError.invalidJSON }
        guard let eventName = Self.nonEmpty(raw["hook_event_name"]?.string) else {
            throw AdapterError.missingField("hook_event_name")
        }
        guard let sessionId = Self.nonEmpty(raw["session_id"]?.string) else {
            throw AdapterError.missingField("session_id")
        }

        let kind = Self.kinds[eventName] ?? .other
        let toolName = Self.nonEmpty(raw["tool_name"]?.string)
        let isPermission = kind == .permissionRequest

        return AgentEvent(
            source: source,
            hookEventName: eventName,
            kind: kind,
            sessionId: sessionId,
            cwd: Self.nonEmpty(raw["cwd"]?.string),
            toolName: toolName,
            toolSummary: Self.summary(toolName: toolName, input: raw["tool_input"]),
            message: Self.message(kind: kind, raw: raw),
            decisionSupported: isPermission,
            // Codex has no hook-level "always allow": it rejects `updatedPermissions`.
            canAlwaysAllow: false,
            host: host,
            raw: raw,
            // Spawned subagents keep the root session_id and add their thread id as agent_id.
            agentId: Self.nonEmpty(raw["agent_id"]?.string),
            // A string, or null when the thread has no local rollout. The title comes from the session index.
            transcriptPath: Self.nonEmpty(raw["transcript_path"]?.string))
    }

    /// Prompt text for UserPromptSubmit; the final answer (nullable in Codex) for Stop / SubagentStop.
    static func message(kind: EventKind, raw: JSONValue) -> String? {
        switch kind {
        case .promptSubmitted: return nonEmpty(raw["prompt"]?.string)
        case .stop, .subagentStop: return nonEmpty(raw["last_assistant_message"]?.string)
        default: return nil
        }
    }

    /// One-line summary of `tool_input`. Strings are trimmed first: for `apply_patch` the PermissionRequest
    /// command lacks the trailing newline that PreToolUse/PostToolUse carry, and the summaries must match.
    static func summary(toolName: String?, input: JSONValue?) -> String? {
        guard let input else { return nil }
        if let toolName, let key = summaryKeys[toolName],
           let value = nonEmpty(input[key]?.string.map(trimmed)) {
            return ToolSummary.oneLine(value)
        }
        return nonEmpty(ToolSummary.summarize(toolName: toolName, input: trimmingStrings(input)))
    }

    private static func trimmingStrings(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s): return .string(trimmed(s))
        case .object(let o):
            // Blank strings are dropped so that e.g. `{"command":"  "}` yields no summary at all.
            return .object(o.compactMapValues { value in
                guard case .string(let s) = value else { return value }
                let t = trimmed(s)
                return t.isEmpty ? nil : .string(t)
            })
        default: return value
        }
    }

    // MARK: Decision

    public func expectsDecision(_ event: AgentEvent) -> Bool {
        event.kind == .permissionRequest && event.decisionSupported
    }

    /// The exact stdout Codex accepts. It rejects unknown fields and Claude-style `updatedPermissions` /
    /// `updatedInput` / `interrupt`, so the output carries only `hookEventName` and `decision`.
    public func render(_ decision: PermissionDecision, for event: AgentEvent) -> BridgeOutput {
        guard expectsDecision(event) else { return .passthrough }
        switch decision {
        case .allow, .allowAlways:
            // No native "always allow" in Codex: degrade to a one-shot allow.
            return BridgeOutput(stdout: Self.permissionOutput(decision: #"{"behavior":"allow"}"#))
        case .deny(let reason):
            let message = Self.nonEmpty(reason.map(Self.trimmed)) ?? Self.defaultDenyMessage
            return BridgeOutput(stdout: Self.permissionOutput(
                decision: #"{"behavior":"deny","message":"# + Self.jsonString(message) + "}"))
        case .askInTerminal:
            // No decision: Codex shows its own approval prompt.
            return .passthrough
        }
    }

    /// Built by hand to keep the documented key order; `decision` is already-encoded JSON.
    private static func permissionOutput(decision: String) -> String {
        #"{"hookSpecificOutput":{"hookEventName":""# + permissionEventName + #"","decision":"# + decision + "}}"
    }

    private static func jsonString(_ s: String) -> String {
        String(decoding: JSONValue.string(s).serialized(), as: UTF8.self)
    }
}

extension CodexAdapter {
    fileprivate static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// nil for missing, empty or whitespace-only strings.
    fileprivate static func nonEmpty(_ s: String?) -> String? {
        guard let s, !trimmed(s).isEmpty else { return nil }
        return s
    }
}
