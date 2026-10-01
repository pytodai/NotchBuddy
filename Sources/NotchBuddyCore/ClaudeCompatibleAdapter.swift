import Foundation

/// Data that describes a Claude-shaped hook protocol: JSON on stdin with an event name, a session id and the
/// usual tool fields, under agent-specific key spellings. Many agents copy Claude Code's contract, so a new one is
/// usually one profile, not a new adapter.
public struct ClaudeCompatibleProfile: Sendable {
    /// Event name → kind. Looked up exactly, then by `normalizedEventName` ("pre_tool_use", "preToolUse" and
    /// "PreToolUse" are the same event). Unknown names map to `.other`.
    public var eventKinds: [String: EventKind]
    /// Payload keys tried in order for each field (first non-empty string wins).
    public var eventNameKeys: [String]
    public var sessionIdKeys: [String]
    public var cwdKeys: [String]
    public var toolNameKeys: [String]
    public var toolInputKeys: [String]
    public var promptKeys: [String]
    public var notificationKeys: [String]
    public var stopMessageKeys: [String]
    public var errorKeys: [String]
    public var agentIdKeys: [String]
    public var transcriptKeys: [String]
    public var titleKeys: [String]
    /// `HostContext.extra` env fallbacks for payloads without the field.
    public var eventNameEnv: String?
    public var sessionIdEnv: String?
    public var cwdEnv: String?
    /// Notification types that mean "waiting for you"; nil = every notification does.
    public var notificationTypeKeys: [String]
    public var attentionNotificationTypes: Set<String>?
    /// The normalized event name the island may answer (`.full` agents), or nil for status only.
    public var permissionEvent: String?
    public var decisionStyle: DecisionStyle
    /// Below the hook timeout the installer writes for `permissionEvent`.
    public var decisionTimeout: TimeInterval

    public enum DecisionStyle: Sendable {
        /// Never answers (print nothing).
        case observeOnly
        /// `{"behavior":"allow"|"deny","message"}` plus the same decision nested the way Claude writes it, so
        /// hosts that expect either shape read it (GitHub Copilot `permissionRequest`).
        case flatAndNestedBehavior
    }

    public init(eventKinds: [String: EventKind], eventNameKeys: [String] = ["hook_event_name"],
                sessionIdKeys: [String] = ["session_id"], cwdKeys: [String] = ["cwd"],
                toolNameKeys: [String] = ["tool_name"], toolInputKeys: [String] = ["tool_input"],
                promptKeys: [String] = ["prompt"], notificationKeys: [String] = ["message", "title"],
                stopMessageKeys: [String] = ["last_assistant_message"], errorKeys: [String] = ["error"],
                agentIdKeys: [String] = ["agent_id"], transcriptKeys: [String] = ["transcript_path"],
                titleKeys: [String] = ["session_title"], eventNameEnv: String? = nil, sessionIdEnv: String? = nil,
                cwdEnv: String? = nil, notificationTypeKeys: [String] = ["notification_type"],
                attentionNotificationTypes: Set<String>? = nil, permissionEvent: String? = nil,
                decisionStyle: DecisionStyle = .observeOnly, decisionTimeout: TimeInterval = 600) {
        self.eventKinds = eventKinds
        self.eventNameKeys = eventNameKeys
        self.sessionIdKeys = sessionIdKeys
        self.cwdKeys = cwdKeys
        self.toolNameKeys = toolNameKeys
        self.toolInputKeys = toolInputKeys
        self.promptKeys = promptKeys
        self.notificationKeys = notificationKeys
        self.stopMessageKeys = stopMessageKeys
        self.errorKeys = errorKeys
        self.agentIdKeys = agentIdKeys
        self.transcriptKeys = transcriptKeys
        self.titleKeys = titleKeys
        self.eventNameEnv = eventNameEnv
        self.sessionIdEnv = sessionIdEnv
        self.cwdEnv = cwdEnv
        self.notificationTypeKeys = notificationTypeKeys
        self.attentionNotificationTypes = attentionNotificationTypes
        self.permissionEvent = permissionEvent
        self.decisionStyle = decisionStyle
        self.decisionTimeout = decisionTimeout
    }

    /// "PreToolUse", "preToolUse", "pre_tool_use" → "pretooluse".
    public static func normalizedEventName(_ name: String) -> String {
        name.lowercased().filter { $0 != "_" && $0 != "-" }
    }

    func kind(of name: String) -> EventKind {
        if let kind = eventKinds[name] { return kind }
        let normalized = Self.normalizedEventName(name)
        return eventKinds.first { Self.normalizedEventName($0.key) == normalized }?.value ?? .other
    }

    /// Claude Code's event names, the base of every profile.
    public static let claudeEventKinds: [String: EventKind] = [
        "SessionStart": .sessionStart, "SessionEnd": .sessionEnd, "UserPromptSubmit": .promptSubmitted,
        "PreToolUse": .toolWillRun, "PostToolUse": .toolDidRun, "PostToolUseFailure": .toolFailed,
        "PermissionRequest": .permissionRequest, "Notification": .notification, "Stop": .stop,
        "StopFailure": .stopFailed, "SubagentStart": .subagentStart, "SubagentStop": .subagentStop,
        "PreCompact": .compact, "PostCompact": .compact,
    ]

    /// GitHub Copilot, PascalCase registration: VS Code's `ChatHookService` and the
    /// CLI both send snake_case `hook_event_name`, `session_id`, `tool_name`, `tool_input`, `cwd`.
    public static let copilot = ClaudeCompatibleProfile(
        eventKinds: claudeEventKinds.merging([
            "ErrorOccurred": .other,  // `recoverable == false` is refined to `.stopFailed` by the adapter
            "SubagentEnd": .subagentStop,
        ]) { $1 },
        eventNameKeys: ["hook_event_name", "hookEventName"],
        sessionIdKeys: ["session_id", "sessionId"],
        toolNameKeys: ["tool_name", "toolName"], toolInputKeys: ["tool_input", "toolArgs"],
        notificationKeys: ["message", "title"], stopMessageKeys: ["last_assistant_message"],
        errorKeys: ["error"], agentIdKeys: ["agent_id", "agentId"],
        permissionEvent: "permissionrequest", decisionStyle: .flatAndNestedBehavior, decisionTimeout: 600)

    /// xAI Grok CLI (~/.grok/docs/user-guide/10-hooks.md): camelCase payload, snake_case event names
    /// (`"hookEventName": "pre_tool_use"`), runner env `GROK_HOOK_EVENT` / `GROK_SESSION_ID`.
    public static let grok = ClaudeCompatibleProfile(
        eventKinds: claudeEventKinds.merging(["SubagentEnd": .subagentStop, "PermissionDenied": .other]) { $1 },
        eventNameKeys: ["hookEventName", "hook_event_name"],
        sessionIdKeys: ["sessionId", "session_id"],
        cwdKeys: ["cwd", "workspaceRoot", "workspace_root"],
        toolNameKeys: ["toolName", "tool_name"], toolInputKeys: ["toolInput", "tool_input"],
        promptKeys: ["prompt", "userPrompt", "user_prompt"],
        notificationKeys: ["message", "title", "body"],
        stopMessageKeys: ["lastAssistantMessage", "last_assistant_message"],
        errorKeys: ["error", "errorMessage", "error_message"],
        agentIdKeys: ["agentId", "agent_id", "subagentId"],
        transcriptKeys: ["transcriptPath", "transcript_path"],
        titleKeys: ["sessionTitle", "session_title"],
        eventNameEnv: "GROK_HOOK_EVENT", sessionIdEnv: "GROK_SESSION_ID", cwdEnv: "GROK_WORKSPACE_ROOT",
        notificationTypeKeys: ["notificationType", "notification_type"])
}

/// Adapter for every `ClaudeCompatibleProfile` agent.
public struct ClaudeCompatibleAdapter: AgentAdapter {
    public let source: AgentSource
    public let profile: ClaudeCompatibleProfile

    public init(source: AgentSource, profile: ClaudeCompatibleProfile) {
        self.source = source
        self.profile = profile
    }

    static var defaultDenyMessage: String { L("Запрещено пользователем в NotchBuddy") }
    public var decisionTimeout: TimeInterval { profile.decisionTimeout }

    public func normalize(stdin: Data, host: HostContext) throws -> AgentEvent {
        guard let raw = try? JSONValue.parse(stdin), raw.object != nil else { throw AdapterError.invalidJSON }
        let p = profile
        guard let name = Self.first(p.eventNameKeys, in: raw) ?? p.eventNameEnv.flatMap({ Self.nonEmpty(host.extra[$0]) })
        else { throw AdapterError.missingField(p.eventNameKeys.first ?? "hook_event_name") }
        guard let sessionId = Self.first(p.sessionIdKeys, in: raw) ?? p.sessionIdEnv.flatMap({ Self.nonEmpty(host.extra[$0]) })
        else { throw AdapterError.missingField(p.sessionIdKeys.first ?? "session_id") }

        var kind = p.kind(of: name)
        let toolName = Self.first(p.toolNameKeys, in: raw)
        let toolInput = p.toolInputKeys.lazy.compactMap { raw[$0] }.first.map(Self.decodedIfJSONString)
        var message: String?
        switch kind {
        case .promptSubmitted:
            message = Self.first(p.promptKeys, in: raw)
        case .notification:
            message = Self.first(p.notificationKeys, in: raw)
            if let attention = p.attentionNotificationTypes, let type = Self.first(p.notificationTypeKeys, in: raw),
               !attention.contains(type) {
                kind = .other
            }
        case .stop:
            message = Self.first(p.stopMessageKeys, in: raw).map { ToolSummary.oneLine($0) }
        case .stopFailed, .toolFailed:
            message = Self.errorText(p.errorKeys, in: raw)
        default:
            break
        }
        // Copilot `errorOccurred`: an unrecoverable error ends the turn.
        if kind == .other, ClaudeCompatibleProfile.normalizedEventName(name) == "erroroccurred",
           raw["recoverable"]?.bool == false {
            kind = .stopFailed
            message = Self.errorText(p.errorKeys, in: raw)
        }

        var event = AgentEvent(
            source: source, hookEventName: name, kind: kind, sessionId: sessionId,
            cwd: Self.first(p.cwdKeys, in: raw) ?? p.cwdEnv.flatMap { Self.nonEmpty(host.extra[$0]) },
            toolName: toolName, toolSummary: ToolSummary.summarize(toolName: toolName, input: toolInput),
            message: message, host: host, raw: raw, agentId: Self.first(p.agentIdKeys, in: raw),
            transcriptPath: Self.first(p.transcriptKeys, in: raw), sessionTitle: Self.first(p.titleKeys, in: raw))
        if kind == .permissionRequest {
            event.decisionSupported = p.decisionStyle != .observeOnly
                && p.permissionEvent == ClaudeCompatibleProfile.normalizedEventName(name)
        }
        return event
    }

    public func expectsDecision(_ event: AgentEvent) -> Bool {
        event.kind == .permissionRequest && event.decisionSupported
    }

    public func render(_ decision: PermissionDecision, for event: AgentEvent) -> BridgeOutput {
        guard expectsDecision(event), profile.decisionStyle == .flatAndNestedBehavior else { return .passthrough }
        let body: JSONValue
        switch decision {
        case .askInTerminal:
            return .passthrough
        case .allow, .allowAlways:  // no "remember" in Copilot's hook output
            body = ["behavior": "allow"]
        case .deny(let reason):
            let text = Self.nonEmpty(reason?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Self.defaultDenyMessage
            body = ["behavior": "deny", "message": .string(String(text.prefix(10_000)))]
        }
        var output = body.object ?? [:]
        output["hookSpecificOutput"] = ["hookEventName": .string(event.hookEventName), "decision": body]
        return BridgeOutput(stdout: String(decoding: JSONValue.object(output).serialized(), as: UTF8.self), exitCode: 0)
    }

    // MARK: Helpers

    static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// The first key holding a non-empty string (strictly a string: numbers and booleans are skipped).
    static func first(_ keys: [String], in raw: JSONValue) -> String? {
        for key in keys {
            if case .string(let s)? = raw[key], !s.isEmpty { return s }
        }
        return nil
    }

    /// Error text from a string or an `{message}` / `{name, message}` object.
    static func errorText(_ keys: [String], in raw: JSONValue) -> String? {
        for key in keys {
            guard let value = raw[key] else { continue }
            if let s = nonEmpty(value.string) { return ToolSummary.oneLine(s) }
            if let m = nonEmpty(value["message"]?.string) { return ToolSummary.oneLine(m) }
        }
        return nil
    }

    /// Some hosts send tool arguments as a JSON string (Copilot `toolArgs`, Cursor MCP `tool_input`).
    static func decodedIfJSONString(_ value: JSONValue) -> JSONValue {
        guard case .string(let s) = value, let first = s.first, first == "{" || first == "[",
              let parsed = try? JSONValue.parse(Data(s.utf8)) else { return value }
        return parsed
    }
}
