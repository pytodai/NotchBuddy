import Foundation

/// Which agent an event came from: an open, lower-case string id ("claude", "cursor", ...).
///
/// It used to be a closed `enum`; a struct lets a new agent be added with one `AgentDescriptor` in
/// `AgentCatalog` instead of edits to every `switch`. The Codable form is unchanged (a bare string), so
/// `SessionKey`, wire frames and caches written by older builds still decode. The built-in constants
/// pattern-match in `switch` statements (`case .claude:`), which then need a `default:`.
public struct AgentSource: RawRepresentable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    /// Nil for ids that could not name an agent (empty, or anything but `a-z`, `0-9`, `-`, `_`).
    public init?(rawValue: String) {
        let id = rawValue.lowercased()
        guard !id.isEmpty, id.count <= 40,
              id.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" })
        else { return nil }
        self.rawValue = id
    }

    /// For the compile-time constants below.
    init(_ id: StaticString) { self.rawValue = "\(id)" }

    public static let claude = AgentSource("claude")
    public static let codex = AgentSource("codex")
    public static let kimi = AgentSource("kimi")
    public static let cursor = AgentSource("cursor")
    public static let copilot = AgentSource("copilot")
    public static let cline = AgentSource("cline")
    public static let grok = AgentSource("grok")

    /// The three original agents, in their historical order. Everything that existed before the catalog
    /// (menu bar "Хуки", the first-launch offer, `notchbuddy-bridge hooks … all`, usage providers) iterates
    /// these only, so their behavior is unchanged.
    public static let allCases: [AgentSource] = [.claude, .codex, .kimi]

    public var displayName: String { AgentCatalog.descriptor(for: self)?.displayName ?? rawValue }
    public var description: String { rawValue }

    public static func < (a: AgentSource, b: AgentSource) -> Bool { a.rawValue < b.rawValue }
}

/// Agent-agnostic event kind. Adapters map each agent's hook event name onto this.
public enum EventKind: String, Codable, Sendable {
    case sessionStart
    case sessionEnd
    case promptSubmitted
    case toolWillRun        // PreToolUse
    case toolDidRun         // PostToolUse (success)
    case toolFailed         // PostToolUseFailure
    case permissionRequest  // agent asks the user to approve a tool call
    case permissionResolved // the user answered in the agent's own UI (Kimi PermissionResult)
    case notification       // agent wants attention (idle / needs input)
    case stop               // agent finished its turn
    case stopFailed         // turn ended with an API/model error (StopFailure)
    case interrupted        // user interrupted the turn (Interrupt)
    case subagentStart
    case subagentStop
    case compact            // Pre/PostCompact
    case other
}

/// Where the agent session is running, collected by the bridge from its own
/// environment and process tree. All fields optional; TerminalJumper uses what it can.
public struct HostContext: Codable, Equatable, Sendable {
    public var termProgram: String?        // TERM_PROGRAM
    public var bundleIdentifier: String?   // __CFBundleIdentifier of the launching app
    public var itermSessionId: String?     // ITERM_SESSION_ID
    public var termSessionId: String?      // TERM_SESSION_ID (Terminal.app)
    public var tty: String?                // e.g. /dev/ttys003 of the agent process
    public var tmuxPane: String?           // TMUX_PANE
    public var tmuxSocket: String?         // first component of TMUX
    public var agentPid: Int32?            // the agent process (parent of the hook shell)
    public var appPid: Int32?              // nearest ancestor that is a GUI .app
    public var appBundleIdentifier: String?
    public var appPath: String?            // path to the .app bundle
    public var extra: [String: String]     // other terminal-specific env (KITTY_WINDOW_ID, WEZTERM_PANE, ...)

    public init(termProgram: String? = nil, bundleIdentifier: String? = nil, itermSessionId: String? = nil,
                termSessionId: String? = nil, tty: String? = nil, tmuxPane: String? = nil, tmuxSocket: String? = nil,
                agentPid: Int32? = nil, appPid: Int32? = nil, appBundleIdentifier: String? = nil,
                appPath: String? = nil, extra: [String: String] = [:]) {
        self.termProgram = termProgram
        self.bundleIdentifier = bundleIdentifier
        self.itermSessionId = itermSessionId
        self.termSessionId = termSessionId
        self.tty = tty
        self.tmuxPane = tmuxPane
        self.tmuxSocket = tmuxSocket
        self.agentPid = agentPid
        self.appPid = appPid
        self.appBundleIdentifier = appBundleIdentifier
        self.appPath = appPath
        self.extra = extra
    }
}

/// One normalized hook invocation.
public struct AgentEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var source: AgentSource
    /// The agent's own event name, e.g. "PreToolUse".
    public var hookEventName: String
    public var kind: EventKind
    public var sessionId: String
    /// The subagent that produced the event (`agent_id`: Claude/Codex subagents share the parent's `session_id`).
    /// nil for the main thread. Decoded with `decodeIfPresent`, so older encodings without it still parse.
    public var agentId: String?
    public var cwd: String?
    public var toolName: String?
    /// Human-readable one-liner of what the tool will do (command, file path, URL...).
    public var toolSummary: String?
    /// Prompt text (promptSubmitted) or notification message.
    public var message: String?
    /// Whether the island can answer this permission request (the bridge waits for a decision).
    /// False for agents whose hooks are observe-only (Kimi) or tools the island can't answer (AskUserQuestion).
    public var decisionSupported: Bool
    /// Whether the agent offers a persistent "always allow" for this permission request.
    public var canAlwaysAllow: Bool
    public var timestamp: Date
    public var host: HostContext
    /// The untouched stdin payload.
    public var raw: JSONValue
    /// The agent's transcript file (`transcript_path`: Claude's session JSONL, Codex's rollout JSONL), where the
    /// app reads the chat's title from (`SessionTitleResolver`). Kept outside `raw`, which the bridge drops from
    /// oversized frames. Decoded with `decodeIfPresent`, so older encodings without it still parse.
    public var transcriptPath: String?
    /// The chat's title when the payload carries one (Claude `SessionStart.session_title`, Kimi `session_title`).
    public var sessionTitle: String?

    public init(id: UUID = UUID(), source: AgentSource, hookEventName: String, kind: EventKind, sessionId: String,
                cwd: String? = nil, toolName: String? = nil, toolSummary: String? = nil, message: String? = nil,
                decisionSupported: Bool = false, canAlwaysAllow: Bool = false, timestamp: Date = Date(), host: HostContext = HostContext(),
                raw: JSONValue = .null, agentId: String? = nil, transcriptPath: String? = nil,
                sessionTitle: String? = nil) {
        self.id = id
        self.source = source
        self.hookEventName = hookEventName
        self.kind = kind
        self.sessionId = sessionId
        self.cwd = cwd
        self.toolName = toolName
        self.toolSummary = toolSummary
        self.message = message
        self.decisionSupported = decisionSupported
        self.canAlwaysAllow = canAlwaysAllow
        self.timestamp = timestamp
        self.host = host
        self.raw = raw
        self.agentId = agentId
        self.transcriptPath = transcriptPath
        self.sessionTitle = sessionTitle
    }

    public var sessionKey: SessionKey { SessionKey(source: source, sessionId: sessionId) }
}

/// Decides when a permission request still waiting on the island has been answered elsewhere (in the agent's
/// own UI) or can no longer be answered, judging by a later event. Pure, so the app's drop logic is testable.
public enum PendingPermissionPolicy {
    /// A PreToolUse this soon after a pending request is treated as a parallel sibling call, not as evidence.
    public static let siblingToolWindow: TimeInterval = 2
    /// Whether `later` makes the pending permission request `pending` stale, judged by their bridge timestamps
    /// (`Moment.wallOnly` timeline).
    public static func isSuperseded(_ pending: AgentEvent, by later: AgentEvent) -> Bool {
        isSuperseded(pending, at: .wallOnly(pending.timestamp), by: later, at: .wallOnly(later.timestamp))
    }

    /// Whether `later` makes the pending permission request `pending` stale.
    /// `pendingAt` / `laterAt`: when the app saw each event happen (`Moment.eventMoment(stampedAt:)` of its
    /// arrival). Only their monotonic halves are compared: the wall clock set between the two events must not
    /// make a parallel sibling look seconds late (dropping its live card) or a Stop look older than the card.
    /// Evidence counts only for the same session and, except for session-wide ends, the same agent thread:
    /// subagents share the parent's `session_id`, so the main thread's Stop or prompt must not close a
    /// background subagent's request (and vice versa).
    public static func isSuperseded(_ pending: AgentEvent, at pendingAt: Moment,
                                    by later: AgentEvent, at laterAt: Moment) -> Bool {
        guard pending.id != later.id, pending.sessionKey == later.sessionKey else { return false }
        let sameAgent = pending.agentId == later.agentId
        let gap = laterAt.since(pendingAt)
        let notNewer = gap >= 0
        switch later.kind {
        case .sessionEnd, .stopFailed, .interrupted:
            // The session or the whole turn is over.
            return notNewer
        case .promptSubmitted, .stop:
            // That thread moved on.
            return sameAgent && notNewer
        case .subagentStop:
            return later.agentId != nil && sameAgent && notNewer
        case .toolDidRun, .toolFailed:
            // The very same tool call completed.
            return sameAgent && notNewer
                && pending.toolName == later.toolName && pending.toolSummary == later.toolSummary
        case .toolWillRun:
            // Claude: the thread's next tool call means the prompt was answered in the terminal (e.g. "No, and tell
            // Claude what to do differently" does not abort the turn, so the bridge lingers). A call's own
            // PreToolUse fires before its PermissionRequest, hence strictly later and a different call only.
            // Parallel (concurrency-safe) siblings start within moments of each other, while an answer typed in
            // the terminal plus a new model call takes longer: dropping a sibling's live card would silently deny
            // a background subagent's call, which has no terminal dialog to fall back to.
            // Both gaps must reach the window: the moments' gap (a wall clock set between the two stamps cannot
            // fake it) and the bridges' own stamps (a sibling that sat behind a stalled main thread for more than
            // `Moment.maxEventTransit` looks later than it was by its moment alone). A clock set back between
            // them makes the stamp gap negative: the card stays until a stronger sign closes it (the safe side).
            let stampGap = later.timestamp.timeIntervalSince(pending.timestamp)
            return later.source == .claude && sameAgent
                && min(gap, stampGap) >= siblingToolWindow
                && (pending.toolName != later.toolName || pending.toolSummary != later.toolSummary)
        default:
            return false
        }
    }
}

public struct SessionKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public var source: AgentSource
    public var sessionId: String
    public init(source: AgentSource, sessionId: String) {
        self.source = source
        self.sessionId = sessionId
    }
    public var description: String { "\(source.rawValue):\(sessionId)" }
}

/// The user's answer to a permission request.
public enum PermissionDecision: Codable, Equatable, Sendable {
    case allow
    /// Allow and ask the agent to remember it (agent-native rule), if supported.
    case allowAlways
    case deny(reason: String?)
    /// Do not answer: the agent shows its own prompt in the terminal.
    case askInTerminal
}
