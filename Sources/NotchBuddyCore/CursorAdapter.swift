import Foundation

/// Cursor IDE and `cursor-agent` hooks: flat JSON handlers in
/// `~/.cursor/hooks.json`, camelCase event names, `conversation_id` as the session id and no `cwd` in the
/// common fields. Cursor has no "waiting for you" / PermissionRequest event, and its approval hooks
/// (`beforeShellExecution` → `allow|deny|ask`) fire for every command, so the island only observes:
/// nothing waits and nothing is printed (Cursor then behaves as if no hook were installed).
public struct CursorAdapter: AgentAdapter {
    public init() {}
    public var source: AgentSource { .cursor }

    /// Event → kind. `stop` is refined by its `status`.
    static let kinds: [String: EventKind] = [
        "sessionStart": .sessionStart,
        "sessionEnd": .sessionEnd,
        "beforeSubmitPrompt": .promptSubmitted,
        "preToolUse": .toolWillRun,
        "beforeShellExecution": .toolWillRun,
        "beforeMCPExecution": .toolWillRun,
        "postToolUse": .toolDidRun,
        "afterShellExecution": .toolDidRun,
        "afterMCPExecution": .toolDidRun,
        "afterFileEdit": .toolDidRun,
        "postToolUseFailure": .toolFailed,
        "subagentStart": .subagentStart,
        "subagentStop": .subagentStop,
        "preCompact": .compact,
        "stop": .stop,
    ]

    public func normalize(stdin: Data, host: HostContext) throws -> AgentEvent {
        guard let raw = try? JSONValue.parse(stdin), raw.object != nil else { throw AdapterError.invalidJSON }
        typealias C = ClaudeCompatibleAdapter
        guard let name = C.first(["hook_event_name"], in: raw) else { throw AdapterError.missingField("hook_event_name") }
        guard let sessionId = C.first(["conversation_id", "session_id"], in: raw) else {
            throw AdapterError.missingField("conversation_id")
        }
        var kind = Self.kinds[name] ?? .other
        var message: String?
        var toolName = C.first(["tool_name"], in: raw)
        var input = raw["tool_input"].map(C.decodedIfJSONString)
        switch name {
        case "beforeShellExecution", "afterShellExecution":
            toolName = toolName ?? "Shell"
            input = ["command": raw["command"] ?? .null]
        case "afterFileEdit":
            toolName = toolName ?? "Edit"
            input = ["file_path": raw["file_path"] ?? .null]
        case "beforeSubmitPrompt":
            message = C.first(["prompt"], in: raw)
        case "postToolUseFailure":
            message = C.errorText(["error_message", "error"], in: raw)
        case "subagentStart", "subagentStop":
            message = C.first(["subagent_type", "task"], in: raw)
        case "stop":
            switch raw["status"]?.string {
            case "aborted": kind = .interrupted
            case "error":
                kind = .stopFailed
                message = C.errorText(["error_message", "error"], in: raw) ?? L("Ошибка Cursor")
            default: break
            }
        default:
            break
        }
        let cwd = C.first(["cwd"], in: raw)
            ?? raw["workspace_roots"]?.array?.first?.string.flatMap(C.nonEmpty)
            ?? C.nonEmpty(host.extra["CURSOR_PROJECT_DIR"])
        let isSubagentEvent = name == "subagentStart" || name == "subagentStop"
        return AgentEvent(
            source: source, hookEventName: name, kind: kind, sessionId: sessionId, cwd: cwd,
            toolName: toolName, toolSummary: ToolSummary.summarize(toolName: toolName, input: input),
            message: message, host: host, raw: Self.withoutFileContents(raw),
            agentId: isSubagentEvent ? C.first(["subagent_id"], in: raw) : nil,
            transcriptPath: C.first(["transcript_path"], in: raw))
    }

    public func expectsDecision(_ event: AgentEvent) -> Bool { false }

    public func render(_ decision: PermissionDecision, for event: AgentEvent) -> BridgeOutput { .passthrough }

    /// `beforeReadFile`/`afterFileEdit` can carry whole files; the island never needs them, and `user_email`
    /// is personal data.
    static func withoutFileContents(_ raw: JSONValue) -> JSONValue {
        guard var fields = raw.object else { return raw }
        for key in ["content", "edits", "attachments", "user_email"] { fields[key] = nil }
        return .object(fields)
    }
}
