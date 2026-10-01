import Foundation

/// Cline (VS Code extension, legacy and Cline 4 runtimes) file hooks: one
/// executable per event; stdin carries `hookName`, `taskId` (the conversation), `workspaceRoots[]` and one
/// sub-object named after the event (`preToolUse{toolName, parameters}`, `taskStart{taskMetadata{initialTask}}`…).
/// A hook can only cancel a tool call, never approve one, so the island observes: nothing waits and nothing
/// is printed (an empty output changes nothing in Cline).
public struct ClineAdapter: AgentAdapter {
    public init() {}
    public var source: AgentSource { .cline }

    /// The hook files the installer writes: the legacy runtime's list plus Cline 4's `TaskError` and
    /// `SessionShutdown` (extra files are ignored by the runtime that does not know them).
    public static let events = [
        "TaskStart", "TaskResume", "TaskCancel", "TaskComplete", "TaskError", "PreToolUse", "PostToolUse",
        "UserPromptSubmit", "Notification", "PreCompact", "SessionShutdown",
    ]

    static let kinds: [String: EventKind] = [
        // A task starts with its prompt and Cline works right away.
        "TaskStart": .promptSubmitted,
        "TaskResume": .sessionStart,
        "TaskCancel": .interrupted,
        "TaskComplete": .stop,
        "TaskError": .stopFailed,
        "PreToolUse": .toolWillRun,
        "PostToolUse": .toolDidRun,
        "UserPromptSubmit": .promptSubmitted,
        "Notification": .notification,
        "PreCompact": .compact,
        "SessionShutdown": .sessionEnd,
    ]

    public func normalize(stdin: Data, host: HostContext) throws -> AgentEvent {
        guard let raw = try? JSONValue.parse(stdin), raw.object != nil else { throw AdapterError.invalidJSON }
        typealias C = ClaudeCompatibleAdapter
        guard let name = C.first(["hookName", "hook_name", "hookEventName"], in: raw) else {
            throw AdapterError.missingField("hookName")
        }
        guard let taskId = C.first(["taskId", "task_id"], in: raw) else { throw AdapterError.missingField("taskId") }

        // Event names are matched case-insensitively (Cline compares lower-cased file names).
        let canonical = Self.events.first { $0.lowercased() == name.lowercased() } ?? name
        var kind = Self.kinds[canonical] ?? .other
        let body = raw[Self.lowerCamel(canonical)] ?? .null
        var toolName: String?
        var input: JSONValue?
        var message: String?
        switch canonical {
        case "TaskStart":
            message = C.first(["initialTask"], in: body["taskMetadata"] ?? .null)
        case "UserPromptSubmit":
            message = C.first(["prompt"], in: body)
        case "PreToolUse", "PostToolUse":
            toolName = C.first(["toolName"], in: body) ?? C.first(["name"], in: raw["tool_call"] ?? .null)
            input = Self.parameters(body["parameters"] ?? raw["tool_call"]?["input"])
            if canonical == "PostToolUse", body["success"]?.bool == false {
                kind = .toolFailed
                message = C.first(["result"], in: body).map { ToolSummary.oneLine($0) }
            }
        case "TaskComplete":
            message = C.first(["result"], in: body["taskMetadata"] ?? .null)
                ?? C.first(["outputText"], in: raw["turn"] ?? .null)
        case "TaskError":
            message = C.errorText(["error"], in: raw) ?? C.errorText(["error"], in: body) ?? L("Ошибка Cline")
        case "Notification":
            message = C.first(["message"], in: body)
            // Only "waiting for you" notifications change the state; the rest are informational.
            if body["waitingForUserInput"]?.bool != true, body["requiresUserAction"]?.bool != true { kind = .other }
        default:
            break
        }
        let cwd = raw["workspaceRoots"]?.array?.first.flatMap { $0.string ?? $0["path"]?.string }.flatMap(C.nonEmpty)
        var fields = raw.object ?? [:]
        fields["userId"] = nil  // defaults to $USER
        return AgentEvent(
            source: source, hookEventName: canonical, kind: kind, sessionId: taskId, cwd: cwd,
            toolName: toolName, toolSummary: ToolSummary.summarize(toolName: toolName, input: input),
            message: message, host: host, raw: .object(fields),
            // Subagents carry their parent's id; the main agent's own `agent_id` is not a subagent.
            agentId: C.first(["parent_agent_id"], in: raw) != nil ? C.first(["agent_id"], in: raw) : nil)
    }

    public func expectsDecision(_ event: AgentEvent) -> Bool { false }

    public func render(_ decision: PermissionDecision, for event: AgentEvent) -> BridgeOutput { .passthrough }

    /// "PreToolUse" → "preToolUse".
    static func lowerCamel(_ name: String) -> String {
        guard let first = name.first else { return name }
        return first.lowercased() + name.dropFirst()
    }

    /// Cline JSON-stringifies parameter values (`{"command":"\"ls\""}` in some builds, plain strings in
    /// others); decode each value that parses.
    static func parameters(_ value: JSONValue?) -> JSONValue? {
        guard let object = value?.object else { return value }
        var result: [String: JSONValue] = [:]
        for (key, v) in object {
            if case .string(let s) = v, s.hasPrefix("\""), let parsed = try? JSONValue.parse(Data(s.utf8)) {
                result[key] = parsed
            } else {
                result[key] = ClaudeCompatibleAdapter.decodedIfJSONString(v)
            }
        }
        return .object(result)
    }
}
