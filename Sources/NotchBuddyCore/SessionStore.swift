import Foundation

public enum SessionStatus: String, Codable, Sendable {
    case working
    case waitingForUser
    case finished
    case error
    case idle
}

public struct AgentSession: Identifiable, Equatable, Sendable {
    public var key: SessionKey
    public var id: SessionKey { key }
    public var cwd: String?
    public var status: SessionStatus
    /// When the session was first seen, on both clocks.
    public var startMoment: Moment
    /// Its latest event. Staleness and event order compare the monotonic half, so setting the wall clock neither
    /// expires sessions early nor keeps them forever.
    public var lastEventMoment: Moment
    /// When the current status began (the list order within a status group compares its monotonic half).
    /// The island's running clocks read the wall half (`statusSince`), which
    /// the app moves along when the wall clock is set (`SessionStore.shiftWallClock`), so "работает 2:14"
    /// neither goes negative nor leaps by hours.
    public var statusMoment: Moment
    public var lastToolName: String?
    public var lastToolSummary: String?
    public var lastPrompt: String?
    public var lastMessage: String?
    public var host: HostContext
    /// The chat's own name as the agent shows it: Claude's transcript title (`SessionTitleResolver`), Codex's
    /// `thread_name` from its session index, Kimi's `session_title`. nil until known.
    public var chatTitle: String?
    /// The agent's transcript file (`transcript_path` of the main thread's events), where Claude's title is read.
    public var transcriptPath: String?
    /// The first prompt the app saw in this session (the title until the agent names the chat).
    public var firstPrompt: String?
    /// Its last tool calls with their results (a ring of `RecentToolCalls.defaultCapacity`), for the card's timeline.
    public var recentTools = RecentToolCalls()
    /// The agent's last final answer (Stop's `last_assistant_message`, main thread), at most
    /// `AgentSession.maxAgentMessageLength` characters; a new prompt clears it.
    public var lastAgentMessage: String?

    /// Longest `lastAgentMessage` kept (the card shows an excerpt).
    public static let maxAgentMessageLength = 2000

    public var source: AgentSource { key.source }

    /// Wall-clock views of the moments above (display; setting one moves only the wall half).
    public var startedAt: Date {
        get { startMoment.wall }
        set { startMoment.wall = newValue }
    }

    public var lastEventAt: Date {
        get { lastEventMoment.wall }
        set { lastEventMoment.wall = newValue }
    }

    /// Time the current status began (for "working 2m" style display).
    public var statusSince: Date {
        get { statusMoment.wall }
        set { statusMoment.wall = newValue }
    }

    /// Identifies the current status episode (one-shot animations such as the drawn check play once per episode).
    /// Keyed on the monotonic half of `statusMoment`: it changes with every status change, but never when the wall
    /// clock is set (`SessionStore.shiftWallClock` moves only the wall half).
    public var episode: String { "\(key.source.rawValue):\(key.sessionId):\(statusMoment.monotonic)" }

    /// Whether the island would draw both the same: the fields it shows, not the ones only the app reads
    /// (`lastEventMoment`, `startMoment`, `host`), so an event that changes only those re-renders nothing.
    public func looksTheSame(as other: AgentSession) -> Bool {
        key == other.key && status == other.status && statusMoment == other.statusMoment && cwd == other.cwd
            && lastToolName == other.lastToolName && lastToolSummary == other.lastToolSummary
            && lastPrompt == other.lastPrompt && lastMessage == other.lastMessage
            && chatTitle == other.chatTitle && firstPrompt == other.firstPrompt
            && recentTools == other.recentTools && lastAgentMessage == other.lastAgentMessage
    }

    /// What to call the session: the chat's title, else its first prompt
    /// (one line, ≤ `SessionNaming.maxPromptTitleLength` characters), else the project folder's name.
    /// nil when none is known and the cwd is a scratch or temporary folder.
    public var displayTitle: String? {
        SessionNaming.oneLine(chatTitle) ?? SessionNaming.promptTitle(firstPrompt) ?? projectName
    }

    /// The cwd folder's name; nil for scratch and temporary folders (show `SessionNaming.noProjectLabel`).
    public var projectName: String? { SessionNaming.projectName(forCwd: cwd) }

    /// `displayTitle`, or the agent's name when there is none.
    public var title: String { displayTitle ?? key.source.displayName }

    /// An answer as kept in `lastAgentMessage`: the adapters' " ⏎ " line marks back to newlines, trimmed, at most
    /// `maxAgentMessageLength` characters (cut ones end in "…"); nil when blank.
    static func agentMessage(_ text: String) -> String? {
        let lines = text.replacingOccurrences(of: " ⏎ ", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lines.isEmpty else { return nil }
        guard lines.count > maxAgentMessageLength else { return lines }
        return String(lines.prefix(maxAgentMessageLength - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

/// Side effects the UI should play after applying an event.
public enum SessionEffect: Equatable, Sendable {
    case finished(SessionKey)
    case needsAttention(SessionKey, message: String?)
    case ended(SessionKey)
}

/// Pure reducer over agent events. Owned by the app's main-actor model.
///
/// Time comes in as `Moment`s: the app passes when each event happened on its own clocks
/// (`Moment.eventMoment(stampedAt:)` of its arrival), never the bridge's wall-clock stamp alone. The `Date`
/// overloads put everything on the single-clock `Moment.wallOnly` timeline (previews, tests); a store must
/// use one timeline or the other.
public struct SessionStore: Equatable, Sendable {
    public private(set) var sessions: [SessionKey: AgentSession] = [:]
    /// Sessions with no events for this long are dropped.
    public var staleAfter: TimeInterval
    /// A session "working" without any event for this long is shown as idle
    /// (some agents send no Stop when a turn dies on an API error).
    public var workingTimeout: TimeInterval

    public init(staleAfter: TimeInterval = 30 * 60, workingTimeout: TimeInterval = 10 * 60) {
        self.staleAfter = staleAfter
        self.workingTimeout = workingTimeout
    }

    /// Sessions ordered: waiting first, then working, then the rest; within a group the most recent status change
    /// first (then the most recently started, then by key). Events that change nothing but the session's last-event
    /// time (every tool call of a working agent) never reorder it, so two agents working side by side do not trade
    /// places, and the collapsed island's primary session, on every hook event.
    public var ordered: [AgentSession] { Self.ordered(sessions.values) }

    /// `sessions` in the store's order (see `ordered`).
    public static func ordered<S: Sequence>(_ sessions: S) -> [AgentSession] where S.Element == AgentSession {
        func rank(_ s: SessionStatus) -> Int {
            switch s {
            case .waitingForUser: return 0
            case .working: return 1
            case .error: return 2
            case .finished: return 3
            case .idle: return 4
            }
        }
        return sessions.sorted { a, b in
            if rank(a.status) != rank(b.status) { return rank(a.status) < rank(b.status) }
            if a.statusMoment.monotonic != b.statusMoment.monotonic {
                return a.statusMoment.monotonic > b.statusMoment.monotonic
            }
            if a.startMoment.monotonic != b.startMoment.monotonic { return a.startMoment.monotonic > b.startMoment.monotonic }
            return a.key.description < b.key.description
        }
    }

    /// Applies an event at its own bridge timestamp (`Moment.wallOnly` timeline).
    @discardableResult
    public mutating func apply(_ e: AgentEvent) -> [SessionEffect] {
        apply(e, at: .wallOnly(e.timestamp))
    }

    /// Applies an event that happened at `moment` on the app's clocks.
    @discardableResult
    public mutating func apply(_ e: AgentEvent, at moment: Moment) -> [SessionEffect] {
        let key = e.sessionKey
        if e.kind == .sessionEnd {
            return sessions.removeValue(forKey: key) != nil ? [.ended(key)] : []
        }

        var s = sessions[key] ?? AgentSession(
            key: key, cwd: e.cwd, status: .idle, startMoment: moment, lastEventMoment: moment,
            statusMoment: moment, host: e.host)
        // Events can arrive out of order (parallel hook processes); only the latest one describes the terminal now.
        let isLatest = moment.monotonic >= s.lastEventMoment.monotonic
        if isLatest { s.lastEventMoment = moment }
        // The first cwd names the project; later events may report a subdirectory or a host process's cwd.
        if s.cwd?.isEmpty ?? true, let cwd = e.cwd, !cwd.isEmpty { s.cwd = cwd }
        s.host = Self.merge(s.host, e.host, newIsLatest: isLatest)
        // Subagent events may carry their own transcript: the main thread's names the session.
        if let path = e.transcriptPath, !path.isEmpty, e.agentId == nil ? isLatest : s.transcriptPath == nil {
            s.transcriptPath = path
        }
        if let title = SessionNaming.oneLine(e.sessionTitle ?? Self.kimiTitle(e.host)), isLatest || s.chatTitle == nil {
            s.chatTitle = title
        }

        var effects: [SessionEffect] = []
        func set(_ status: SessionStatus) {
            if s.status != status { s.status = status; s.statusMoment = moment }
        }

        switch e.kind {
        case .sessionStart:
            // SessionStart(source: compact) is the same conversation being compacted, not a new start.
            if s.status == .finished, e.raw["source"]?.string != "compact" { set(.idle) }
        case .promptSubmitted:
            s.lastPrompt = e.message
            if s.firstPrompt == nil, SessionNaming.oneLine(e.message) != nil { s.firstPrompt = e.message }
            s.lastMessage = nil
            if isLatest { s.lastAgentMessage = nil }
            // Whatever that thread still ran belongs to the previous turn.
            s.recentTools.endTurn(agentId: e.agentId, at: moment)
            set(.working)
        case .toolWillRun, .toolDidRun, .subagentStart, .subagentStop:
            if let t = e.toolName { s.lastToolName = t; s.lastToolSummary = e.toolSummary }
            if let t = e.toolName, e.kind == .toolWillRun {
                s.recentTools.start(name: t, summary: e.toolSummary, callId: e.toolCallId, agentId: e.agentId,
                                    at: moment, isLatest: isLatest)
            } else if let t = e.toolName, e.kind == .toolDidRun {
                s.recentTools.finish(name: t, summary: e.toolSummary, callId: e.toolCallId, agentId: e.agentId,
                                     at: moment, success: true)
            } else if e.kind == .subagentStop, e.agentId != nil {
                s.recentTools.endTurn(agentId: e.agentId, at: moment)
            }
            // A tool running after a permission prompt means the user answered (maybe in the terminal).
            set(.working)
        case .compact:
            // A manual /compact is not a model turn: no Stop follows it, so it must not turn a finished or idle
            // session into "working" (until workingTimeout). Auto compaction runs inside a turn, already working.
            if e.raw["trigger"]?.string != "manual" { set(.working) }
        case .toolFailed:
            if let t = e.toolName {
                s.lastToolName = t; s.lastToolSummary = e.toolSummary
                s.recentTools.finish(name: t, summary: e.toolSummary, callId: e.toolCallId, agentId: e.agentId,
                                     at: moment, success: false, error: e.message)
            }
            set(.working)
        case .permissionRequest:
            if let t = e.toolName {
                s.lastToolName = t; s.lastToolSummary = e.toolSummary
                // Its PreToolUse usually came first (then this is the same call); a request is a call all the same.
                s.recentTools.start(name: t, summary: e.toolSummary, callId: e.toolCallId, agentId: e.agentId,
                                    at: moment, isLatest: isLatest)
            }
            set(.waitingForUser)
            if !e.decisionSupported {
                effects.append(.needsAttention(key, message: e.toolSummary ?? e.toolName))
            }
        case .permissionResolved:
            if s.status == .waitingForUser { set(.working) }
        case .stopFailed:
            s.lastMessage = e.message
            s.recentTools.endTurn(agentId: nil, all: true, at: moment)
            set(.error)
        case .interrupted:
            s.recentTools.endTurn(agentId: nil, all: true, at: moment)
            set(.idle)
        case .notification:
            s.lastMessage = e.message
            // Notifications while a tool is pending are attention requests.
            if s.status != .finished { set(.waitingForUser) }
            effects.append(.needsAttention(key, message: e.message))
        case .stop:
            // The agent's final answer, when it sends one (Claude, Codex).
            if let m = e.message, !m.isEmpty {
                s.lastMessage = ToolSummary.oneLine(m)
                if e.agentId == nil, isLatest || s.lastAgentMessage == nil, let answer = AgentSession.agentMessage(m) {
                    s.lastAgentMessage = answer
                }
            }
            s.recentTools.endTurn(agentId: e.agentId, at: moment)
            set(.finished)
            effects.append(.finished(key))
        case .sessionEnd, .other:
            break
        }
        sessions[key] = s
        return effects
    }

    /// Resolves a permission wait that was answered from the island.
    public mutating func permissionAnswered(_ key: SessionKey, at moment: Moment) {
        guard var s = sessions[key], s.status == .waitingForUser else { return }
        s.status = .working
        s.statusMoment = moment
        sessions[key] = s
    }

    /// `permissionAnswered(_:at:)` on the `Moment.wallOnly` timeline.
    public mutating func permissionAnswered(_ key: SessionKey, at date: Date = Date()) {
        permissionAnswered(key, at: .wallOnly(date))
    }

    /// Keeps a session "waiting" while the island still shows one of its permission requests, e.g. a background
    /// subagent's request after the main agent's Stop or prompt.
    public mutating func markWaiting(_ key: SessionKey, at moment: Moment) {
        guard var s = sessions[key], s.status != .waitingForUser else { return }
        s.status = .waitingForUser
        s.statusMoment = moment
        sessions[key] = s
    }

    /// `markWaiting(_:at:)` on the `Moment.wallOnly` timeline.
    public mutating func markWaiting(_ key: SessionKey, at date: Date = Date()) {
        markWaiting(key, at: .wallOnly(date))
    }

    /// Drops sessions without events for `staleAfter` and shows sessions "working" without events for
    /// `workingTimeout` as idle, by the monotonic clock. Returns removed keys.
    @discardableResult
    public mutating func expire(at now: Moment) -> [SessionKey] {
        let dead = sessions.values.filter { now.since($0.lastEventMoment) > staleAfter }.map(\.key)
        for k in dead { sessions.removeValue(forKey: k) }
        for (k, s) in sessions where s.status == .working && now.since(s.lastEventMoment) > workingTimeout {
            sessions[k]?.status = .idle
            sessions[k]?.statusMoment = now
        }
        return dead
    }

    /// `expire(at:)` on the `Moment.wallOnly` timeline.
    @discardableResult
    public mutating func expire(now: Date = Date()) -> [SessionKey] {
        expire(at: .wallOnly(now))
    }

    /// The wall clock was set by `delta` seconds: moves every stored wall-clock date along with it, so
    /// `wall now − statusSince` keeps showing the real elapsed time. Monotonic halves are untouched.
    public mutating func shiftWallClock(by delta: TimeInterval) {
        guard delta != 0, delta.isFinite else { return }
        for k in Array(sessions.keys) {
            sessions[k]?.startMoment.wall.addTimeInterval(delta)
            sessions[k]?.lastEventMoment.wall.addTimeInterval(delta)
            sessions[k]?.statusMoment.wall.addTimeInterval(delta)
            sessions[k]?.recentTools.shiftWall(by: delta)
        }
    }

    public mutating func remove(_ key: SessionKey) {
        sessions.removeValue(forKey: key)
    }

    /// Sets the chat's title found outside the hook events (transcript, session index). Blank titles clear it.
    /// Returns whether anything changed (an unknown session or the same title changes nothing).
    @discardableResult
    public mutating func setChatTitle(_ title: String?, for key: SessionKey) -> Bool {
        guard var s = sessions[key] else { return false }
        let title = SessionNaming.oneLine(title)
        guard s.chatTitle != title else { return false }
        s.chatTitle = title
        sessions[key] = s
        return true
    }

    /// Kimi's title as its adapter stores it in `host.extra` (events decoded from before `sessionTitle`).
    static func kimiTitle(_ host: HostContext) -> String? {
        host.extra[KimiAdapter.sessionTitleKey]
    }

    /// Terminal identity is one snapshot of the bridge's probe (env + process tree), so the latest event's
    /// snapshot replaces the old one as a unit: a field the new probe no longer sees (TMUX_PANE after resuming
    /// the session outside tmux) must be cleared, not kept from the old terminal. Keys adapters add to `extra`
    /// (Kimi's client type and title) are not on every event, so those are merged instead.
    static func merge(_ old: HostContext, _ new: HostContext, newIsLatest: Bool) -> HostContext {
        // An event without identity, or an out-of-order older one, leaves the current snapshot alone.
        let takeNew = new.hasTerminalIdentity && (newIsLatest || !old.hasTerminalIdentity)
        var r = takeNew ? new : old
        let (earlier, later) = newIsLatest ? (old, new) : (new, old)
        let adapterExtra = earlier.extra.merging(later.extra) { _, latest in latest }
            .filter { !probeExtraKeys.contains($0.key) }
        r.extra = r.extra.filter { probeExtraKeys.contains($0.key) }.merging(adapterExtra) { _, adapter in adapter }
        return r
    }

    static let probeExtraKeys = Set(HostProbe.extraAllowlist)
}

extension HostContext {
    /// Whether the bridge's probe found anything about the terminal or the agent process.
    var hasTerminalIdentity: Bool {
        termProgram != nil || bundleIdentifier != nil || itermSessionId != nil || termSessionId != nil || tty != nil
            || tmuxPane != nil || tmuxSocket != nil || agentPid != nil || appPid != nil || appBundleIdentifier != nil
            || appPath != nil || extra.keys.contains(where: SessionStore.probeExtraKeys.contains)
    }
}
