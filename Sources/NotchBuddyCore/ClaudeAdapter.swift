import Foundation

/// Claude Code hooks: the terminal CLI, Claude Desktop "Code" sessions and the IDE extensions share one
/// hook engine.
public struct ClaudeAdapter: AgentAdapter {
    public init() {}

    public var source: AgentSource { .claude }

    static let permissionEventName = "PermissionRequest"

    /// Deny `message` when the user gave no reason. Claude receives it as the tool-denial reason.
    static var defaultDenyMessage: String { L("Запрещено пользователем в NotchBuddy") }
    /// Claude Code caps hook string outputs at 10 000 characters.
    static let maxOutputString = 10_000

    static let desktopBundleIdentifier = "com.anthropic.claudefordesktop"

    /// Claude Code hook event names (case-sensitive) → NotchBuddy event kinds. Unknown names map to `.other`.
    static let kinds: [String: EventKind] = [
        "SessionStart": .sessionStart,
        "SessionEnd": .sessionEnd,
        "UserPromptSubmit": .promptSubmitted,
        "PreToolUse": .toolWillRun,
        "PostToolUse": .toolDidRun,
        "PostToolUseFailure": .toolFailed,
        "PermissionRequest": .permissionRequest,
        "Notification": .notification,
        "Stop": .stop,
        "StopFailure": .stopFailed,
        "SubagentStart": .subagentStart,
        "SubagentStop": .subagentStop,
        "PreCompact": .compact,
        "PostCompact": .compact,
    ]

    /// `Notification.notification_type`s that mean Claude is blocked on the user. The rest are
    /// informational and map to `.other`: `computer_use_enter`/`_exit`, `elicitation_complete`/`_response`,
    /// `auth_success`, `agent_completed`, `quota_auto_resume_*`, `push_notification` and unknown future types.
    static let attentionNotificationTypes: Set<String> = [
        "permission_prompt", "idle_prompt", "elicitation_dialog", "elicitation_url_dialog",
        "agent_needs_input", "worker_permission_prompt",
    ]

    static func kind(of name: String, raw: JSONValue) -> EventKind {
        guard name == "Notification" else { return kinds[name] ?? .other }
        // Builds without `notification_type` only notified when they needed the user.
        guard let type = nonEmpty(raw["notification_type"]?.string) else { return .notification }
        return attentionNotificationTypes.contains(type) ? .notification : .other
    }

    // MARK: AgentAdapter

    public func normalize(stdin: Data, host: HostContext) throws -> AgentEvent {
        guard let raw = try? JSONValue.parse(stdin), raw.object != nil else { throw AdapterError.invalidJSON }
        guard let name = Self.nonEmpty(raw["hook_event_name"]?.string) else {
            throw AdapterError.missingField("hook_event_name")
        }
        // CLAUDE_CODE_SESSION_ID always equals stdin session_id; it only matters if the payload lacks it.
        guard let sessionId = Self.nonEmpty(raw["session_id"]?.string) ?? Self.nonEmpty(host.extra["CLAUDE_CODE_SESSION_ID"])
        else { throw AdapterError.missingField("session_id") }

        let kind = Self.kind(of: name, raw: raw)
        let toolName = Self.nonEmpty(raw["tool_name"]?.string)
        let toolInput = raw["tool_input"]
        var event = AgentEvent(
            source: source, hookEventName: name, kind: kind, sessionId: sessionId,
            cwd: Self.nonEmpty(raw["cwd"]?.string), toolName: toolName,
            toolSummary: Self.summary(toolName: toolName, input: toolInput),
            message: Self.message(kind: kind, raw: raw),
            host: Self.withHints(host), raw: raw,
            agentId: Self.nonEmpty(raw["agent_id"]?.string),
            transcriptPath: Self.nonEmpty(raw["transcript_path"]?.string),
            sessionTitle: Self.nonEmpty(raw["session_title"]?.string))
        if kind == .permissionRequest {
            event.decisionSupported = Self.islandCanAnswer(toolName: toolName, input: toolInput)
            event.canAlwaysAllow = event.decisionSupported
                && Self.alwaysAllowPermissions(toolName: toolName, raw: raw) != nil
        }
        return event
    }

    public func expectsDecision(_ event: AgentEvent) -> Bool {
        event.kind == .permissionRequest && event.decisionSupported
    }

    /// Exactly one schema-exact JSON object; anything malformed would silently become "no decision".
    public func render(_ decision: PermissionDecision, for event: AgentEvent) -> BridgeOutput {
        guard expectsDecision(event) else { return .passthrough }
        let body: JSONValue
        switch decision {
        case .askInTerminal:
            return .passthrough
        case .deny(let reason):
            let text = Self.nonEmpty(reason?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Self.defaultDenyMessage
            body = ["behavior": "deny", "message": .string(String(text.prefix(Self.maxOutputString)))]
        case .allow:
            body = Self.allowBody(for: event, permissions: nil)
        case .allowAlways:
            // No usable rule to remember → a plain allow; never invent a broader rule than Claude offered.
            body = Self.allowBody(for: event, permissions: Self.alwaysAllowPermissions(toolName: event.toolName, raw: event.raw))
        }
        let output: JSONValue = [
            "hookSpecificOutput": ["hookEventName": .string(Self.permissionEventName), "decision": body],
        ]
        return BridgeOutput(stdout: String(decoding: output.serialized(), as: UTF8.self), exitCode: 0)
    }
}

// MARK: - Permission helpers

extension ClaudeAdapter {
    /// Tools whose `requiresUserInteraction()` makes Claude Code ≥2.1.284 ignore an allow without `updatedInput`.
    static func requiresUpdatedInput(_ toolName: String?) -> Bool {
        toolName == "ExitPlanMode"
    }

    /// AskUserQuestion needs the user's answers in `updatedInput.answers`, which the island does not collect.
    /// ExitPlanMode is answerable only if its input can be echoed back as `updatedInput` (an object).
    static func islandCanAnswer(toolName: String?, input: JSONValue?) -> Bool {
        switch toolName {
        case "AskUserQuestion": return false
        case "ExitPlanMode": return input?.object != nil
        default: return true
        }
    }

    static func allowBody(for event: AgentEvent, permissions: [JSONValue]?) -> JSONValue {
        var decision: [String: JSONValue] = ["behavior": "allow"]
        if requiresUpdatedInput(event.toolName), let input = event.raw["tool_input"], input.object != nil {
            decision["updatedInput"] = input
        }
        if let permissions, !permissions.isEmpty {
            decision["updatedPermissions"] = .array(permissions)
        }
        return .object(decision)
    }

    /// The `updatedPermissions` for "always allow": every usable entry of the received `permission_suggestions`,
    /// echoed verbatim and best first. Claude's own "don't ask again" applies the whole list: e.g. an Edit outside
    /// the working dirs offers `setMode acceptEdits` plus `addDirectories`, and accept-edits alone would keep
    /// prompting there. The same change offered for several destinations is written once, to the best-ranked one.
    /// ExitPlanMode without suggestions gets the plan dialog's "auto-accept edits".
    static func alwaysAllowPermissions(toolName: String?, raw: JSONValue) -> [JSONValue]? {
        let suggestions = raw["permission_suggestions"]?.array ?? []
        let ranked = suggestions.enumerated().compactMap { index, entry in
            alwaysAllowRank(entry).map { (rank: $0, index: index, entry: entry) }
        }.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
        var seen = Set<String>()
        let picked = ranked.filter { seen.insert(changeKey($0.entry)).inserted }.map(\.entry)
        if !picked.isEmpty {
            return picked
        }
        if toolName == "ExitPlanMode" {
            return [["type": "setMode", "mode": "acceptEdits", "destination": "session"]]
        }
        return nil
    }

    /// Destinations the 2.1.185 schema accepts, minus `cliArg`.
    static let permissionDestinations: Set<String> = ["localSettings", "session", "projectSettings", "userSettings"]

    /// Lower is better; nil = not an "always allow" entry or would fail Claude Code's schema check.
    /// Allow rules come first (project-local before session), then "accept edits", then extra directories.
    static func alwaysAllowRank(_ entry: JSONValue) -> Int? {
        guard let destination = entry["destination"]?.string, permissionDestinations.contains(destination) else {
            return nil
        }
        switch entry["type"]?.string {
        case "addRules":
            guard entry["behavior"]?.string == "allow", let rules = entry["rules"]?.array, !rules.isEmpty,
                  rules.allSatisfy(isValidRule) else { return nil }
            let order = ["localSettings", "session", "projectSettings", "userSettings"]
            return order.firstIndex(of: destination)
        case "setMode":
            // Never `manual` (≥2.1.200 only) or `bypassPermissions`; only accept-edits means "always allow".
            return entry["mode"]?.string == "acceptEdits" ? 10 : nil
        case "addDirectories":
            guard let dirs = entry["directories"]?.array, !dirs.isEmpty, dirs.allSatisfy(isNonEmptyString) else {
                return nil
            }
            return 20
        default:
            return nil
        }
    }

    /// What a permission update changes, ignoring where it is stored.
    static func changeKey(_ entry: JSONValue) -> String {
        var fields = entry.object ?? [:]
        fields["destination"] = nil
        return String(decoding: JSONValue.object(fields).serialized(), as: UTF8.self)
    }

    static func isValidRule(_ rule: JSONValue) -> Bool {
        guard let tool = rule["toolName"], isNonEmptyString(tool) else { return false }
        guard let content = rule["ruleContent"] else { return true }
        if case .string = content { return true }
        return false
    }

    /// Strict check: `JSONValue.string` would also accept numbers and booleans.
    static func isNonEmptyString(_ value: JSONValue) -> Bool {
        if case .string(let s) = value { return !s.isEmpty }
        return false
    }
}

// MARK: - Event text

extension ClaudeAdapter {
    /// Claude tools whose input has no key `ToolSummary` knows, or where it would pick a worse one.
    static func summary(toolName: String?, input: JSONValue?) -> String? {
        switch toolName {
        case "ExitPlanMode":
            if let plan = nonEmpty(input?["plan"]?.string) { return ToolSummary.oneLine(plan) }
        case "AskUserQuestion":
            if let questions = input?["questions"]?.array, let first = nonEmpty(questions.first?["question"]?.string) {
                let more = questions.count > 1 ? L(" (ещё %@)", questions.count - 1) : ""
                return ToolSummary.oneLine(first + more)
            }
        case "NotebookEdit":
            if let path = nonEmpty(input?["notebook_path"]?.string) { return ToolSummary.oneLine(path) }
        default:
            break
        }
        return ToolSummary.summarize(toolName: toolName, input: input)
    }

    static func message(kind: EventKind, raw: JSONValue) -> String? {
        switch kind {
        case .promptSubmitted:
            return raw["prompt"]?.string
        case .notification:
            return nonEmpty(raw["message"]?.string) ?? nonEmpty(raw["title"]?.string)
        case .stop:
            return nonEmpty(raw["last_assistant_message"]?.string).map { ToolSummary.oneLine($0) }
        case .stopFailed:
            return stopFailureMessage(raw)
        case .toolFailed:
            return nonEmpty(raw["error"]?.string).map { ToolSummary.oneLine($0) }
        case .subagentStart, .subagentStop:
            return nonEmpty(raw["agent_type"]?.string)
        default:
            return nil
        }
    }

    static var stopFailureLabels: [String: String] {
        [
            "rate_limit": L("Достигнут лимит запросов"),
            "overloaded": L("API перегружен"),
            "authentication_failed": L("Ошибка авторизации"),
            "billing_error": L("Проблема с оплатой"),
            "invalid_request": L("Некорректный запрос к API"),
            "model_not_found": L("Модель не найдена"),
            "server_error": L("Ошибка сервера API"),
            "max_output_tokens": L("Превышен лимит длины ответа"),
        ]
    }

    /// "<label> — <API error text>" for StopFailure (`error`, `error_details?`, `last_assistant_message?`).
    static func stopFailureMessage(_ raw: JSONValue) -> String {
        let code = nonEmpty(raw["error"]?.string)
        let label = code.flatMap { stopFailureLabels[$0] }
            ?? (code.map { $0 == "unknown" ? L("Ошибка API") : L("Ошибка API (%@)", $0) } ?? L("Ошибка API"))
        let detailsValue = raw["error_details"].flatMap { $0.isNull ? nil : $0 }
        let details = nonEmpty(detailsValue?.compactText) ?? nonEmpty(raw["last_assistant_message"]?.string)
        return ToolSummary.oneLine(details.map { "\(label) — \($0)" } ?? label)
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

// MARK: - Host hints

extension ClaudeAdapter {
    /// Fills gaps in the bridge's `HostContext` from Claude-specific env the bridge copied into `extra`.
    /// Never overrides what the bridge found itself (process tree beats inherited env).
    static func withHints(_ host: HostContext) -> HostContext {
        var host = host
        // Claude Code ≥2.1.284 exports its own PID to hooks.
        if host.agentPid == nil, let pid = host.extra["CLAUDE_PID"].flatMap({ Int32($0) }), pid > 1 {
            host.agentPid = pid
        }
        // A Desktop "Code" session runs without a TTY or terminal; the host session id is set only by Desktop.
        // CLAUDE_CODE_ENTRYPOINT alone is inherited by shells started from Desktop, hence the extra checks.
        if host.bundleIdentifier == nil, host.tty == nil, host.termProgram == nil,
           host.extra["CLAUDE_CODE_ENTRYPOINT"] == "claude-desktop",
           nonEmpty(host.extra["CLAUDE_CODE_HOST_SESSION_ID"]) != nil {
            host.bundleIdentifier = desktopBundleIdentifier
        }
        return host
    }
}
