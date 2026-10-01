import Foundation

/// Kimi Code hooks.
///
/// Kimi's hooks are observe-only for permissions: `PermissionRequest`/`PermissionResult` are
/// fire-and-forget and no stdout can approve or deny. So no Kimi event expects a decision and the
/// bridge must print nothing — any stdout on `UserPromptSubmit` is injected into the model context.
public struct KimiAdapter: AgentAdapter {
    /// `HostContext.extra` keys filled from the payload.
    /// Client type is "kimi_code_cli", "kimi_code_vscode" or "kimi_code_desktop".
    public static let clientTypeKey = "kimi.client_type"
    public static let sessionTitleKey = "kimi.session_title"

    public init() {}
    public var source: AgentSource { .kimi }

    public func normalize(stdin: Data, host: HostContext) throws -> AgentEvent {
        let raw: JSONValue
        do { raw = try JSONValue.parse(stdin) } catch { throw AdapterError.invalidJSON }
        guard raw.object != nil else { throw AdapterError.invalidJSON }
        guard let name = Self.text(raw["hook_event_name"]) else { throw AdapterError.missingField("hook_event_name") }
        guard let sessionId = Self.text(raw["session_id"]) else { throw AdapterError.missingField("session_id") }

        let toolName = Self.text(raw["tool_name"])
        var event = AgentEvent(source: source, hookEventName: name, kind: Self.kinds[name] ?? .other,
                               sessionId: sessionId, cwd: Self.cwd(raw, event: name), toolName: toolName,
                               decisionSupported: false, canAlwaysAllow: false,
                               host: Self.host(host, from: raw), raw: raw, agentId: Self.agentId(raw),
                               sessionTitle: Self.text(raw["session_title"]))

        switch name {
        case "PreToolUse", "PostToolUse", "PostToolUseFailure":
            event.toolSummary = Self.toolSummary(toolName: toolName, input: raw["tool_input"])
            // Kimi has no hook for its questions; a foreground AskUserQuestion means it waits for the user.
            if name == "PreToolUse", toolName == "AskUserQuestion", raw.at("tool_input", "background")?.bool != true {
                event.kind = .permissionRequest
            }
        case "PermissionRequest", "PermissionResult":
            event.toolSummary = Self.permissionSummary(raw, toolName: toolName)
        case "UserPromptSubmit":
            event.message = Self.promptText(raw["prompt"])
        case "Notification":
            let parts = [Self.text(raw["title"]), Self.text(raw["body"])].compactMap { $0 }
            event.message = parts.isEmpty ? nil : parts.joined(separator: " — ")
        case "StopFailure":
            event.message = Self.text(raw["error_message"]) ?? Self.text(raw["error_type"])
        case "SubagentStart", "SubagentStop":
            event.toolSummary = Self.text(raw["agent_name"])
        default:
            break
        }
        return event
    }

    public func expectsDecision(_ event: AgentEvent) -> Bool { false }

    /// Always prints nothing: Kimi ignores permission answers and pastes UserPromptSubmit stdout into the context.
    public func render(_ decision: PermissionDecision, for event: AgentEvent) -> BridgeOutput { .passthrough }

    /// The approval id shared by a `PermissionRequest` and its `PermissionResult`.
    public static func approvalId(of event: AgentEvent) -> String? {
        guard event.source == .kimi, event.hookEventName == "PermissionRequest" || event.hookEventName == "PermissionResult"
        else { return nil }
        return text(event.raw["id"])
    }

    // MARK: - Mapping

    /// The 16 events Kimi's config schema accepts; anything else becomes `.other`.
    static let kinds: [String: EventKind] = [
        "SessionStart": .sessionStart,
        "SessionEnd": .sessionEnd,
        "UserPromptSubmit": .promptSubmitted,
        "PreToolUse": .toolWillRun,
        "PostToolUse": .toolDidRun,
        "PostToolUseFailure": .toolFailed,
        "PermissionRequest": .permissionRequest,
        "PermissionResult": .permissionResolved,
        "Stop": .stop,
        "StopFailure": .stopFailed,
        "Interrupt": .interrupted,
        "SubagentStart": .subagentStart,
        "SubagentStop": .subagentStop,
        // A background-task notice (e.g. task.completed), not "waiting for input" like Claude's:
        // mapping it to `.notification` would mark the session as waiting and flash the island.
        "Notification": .other,
        "PreCompact": .compact,
        "PostCompact": .compact,
    ]

    /// Session events carry the session's work dir. Agent events carry the Kimi process cwd, which in
    /// VS Code is the extension host's (not the project), so it is dropped there to keep SessionStart's.
    private static func cwd(_ raw: JSONValue, event: String) -> String? {
        let sessionScoped: Set<String> = ["SessionStart", "SessionEnd", "SessionHeartbeat", "SubagentStart", "SubagentStop"]
        if text(raw["client_type"]) == "kimi_code_vscode", !sessionScoped.contains(event) { return nil }
        return text(raw["cwd"])
    }

    private static func host(_ host: HostContext, from raw: JSONValue) -> HostContext {
        var h = host
        if let v = text(raw["client_type"]) { h.extra[clientTypeKey] = v }
        if let v = text(raw["session_title"]) { h.extra[sessionTitleKey] = v }
        return h
    }

    private static func toolSummary(toolName: String?, input: JSONValue?) -> String? {
        switch toolName {
        case "Glob", "Grep":
            if let pattern = text(input?["pattern"]) { return ToolSummary.oneLine(pattern) }
        case "AskUserQuestion":
            let questions = input?["questions"]?.array?.compactMap { text($0["question"]) } ?? []
            if !questions.isEmpty { return ToolSummary.oneLine(questions.joined(separator: " / ")) }
        case "Skill":
            if let skill = text(input?["skill"]) {
                return ToolSummary.oneLine([skill, text(input?["args"])].compactMap { $0 }.joined(separator: " "))
            }
        default:
            break
        }
        return ToolSummary.summarize(toolName: toolName, input: input)
    }

    /// Prefers the full detail from `display` (e.g. the whole command, which `action` cuts at 50 chars),
    /// then Kimi's human-readable `action`, then `tool_input`.
    private static func permissionSummary(_ raw: JSONValue, toolName: String?) -> String? {
        let display = raw["display"]
        let action = text(raw["action"])
        var detail: String?
        switch display?["kind"]?.string {
        case "command":
            detail = text(display?["command"])
        case "file_io":
            let op = display?["operation"]?.string
            // For glob/grep `path` is only the search root; `action` names the pattern.
            detail = op == "glob" || op == "grep" ? action : text(display?["path"])
        case "search":
            detail = text(display?["query"])
        case "url_fetch":
            detail = text(display?["url"])
        case "skill_call":
            let parts = [text(display?["skill_name"]), text(display?["args"])].compactMap { $0 }
            detail = parts.isEmpty ? nil : parts.joined(separator: " ")
        case "agent_call":
            let parts = [text(display?["agent_name"]), text(display?["prompt"])].compactMap { $0 }
            detail = parts.isEmpty ? nil : parts.joined(separator: ": ")
        case "plan_review":
            detail = text(display?["plan"])
        default:
            detail = nil // "generic" repeats `action` as its summary
        }
        if let s = detail ?? action { return ToolSummary.oneLine(s) }
        return toolSummary(toolName: toolName, input: raw["tool_input"])
    }

    /// `prompt` is an array of content parts; only text parts are joined (as Kimi's matcher does).
    private static func promptText(_ prompt: JSONValue?) -> String? {
        if let s = prompt?.string { return text(.string(s)) }
        let texts = prompt?.array?.compactMap { part -> String? in
            let type = part["type"]?.string
            return type == nil || type == "text" ? part["text"]?.string : nil
        } ?? []
        return text(.string(texts.joined(separator: " ")))
    }

    /// Only permission and Notification payloads carry `agent_id`; the main agent's is "main", which maps to nil
    /// like the main thread of the other agents.
    private static func agentId(_ raw: JSONValue) -> String? {
        guard let id = text(raw["agent_id"]), id != "main" else { return nil }
        return id
    }

    /// Non-empty trimmed string value, or nil.
    private static func text(_ value: JSONValue?) -> String? {
        guard let s = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
