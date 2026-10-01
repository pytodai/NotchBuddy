import Foundation

// What a session did lately: its recent tool calls (a small ring buffer) for the expanded session card.

/// One tool call as the hooks reported it: PreToolUse starts it, PostToolUse / PostToolUseFailure finish it.
public struct ToolCall: Identifiable, Equatable, Sendable {
    public enum Outcome: String, Equatable, Sendable {
        /// Started, no result yet.
        case running
        case succeeded
        case failed
        /// Its turn ended (Stop, interrupt, a new prompt) without a result; a late result still finishes it.
        case abandoned
    }

    /// Sequence number within its session (stable across updates; the UI keys rows by it).
    public var id: Int
    /// The agent's own id of the call (`tool_use_id`: Claude, Codex; `tool_call_id`: Kimi), when it sent one.
    public var callId: String?
    /// The subagent that made the call (nil: the main thread).
    public var agentId: String?
    /// The agent's tool name as sent (`Bash`, `exec_command`, `mcp__github__create_issue`…).
    public var name: String
    /// One line of what it does (command, path, URL…), as the adapter summarized it.
    public var summary: String?
    public var started: Moment
    public var finished: Moment?
    public var outcome: Outcome
    /// PostToolUseFailure's error text, one line.
    public var error: String?

    public init(id: Int, callId: String? = nil, agentId: String? = nil, name: String, summary: String? = nil,
                started: Moment, finished: Moment? = nil, outcome: Outcome = .running, error: String? = nil) {
        self.id = id
        self.callId = callId
        self.agentId = agentId
        self.name = name
        self.summary = summary
        self.started = started
        self.finished = finished
        self.outcome = outcome
        self.error = error
    }

    public var startedAt: Date { started.wall }
    public var finishedAt: Date? { finished?.wall }
    /// How long it ran (monotonic), once it has a result.
    public var duration: TimeInterval? { finished.map { max(0, $0.since(started)) } }
    public var isRunning: Bool { outcome == .running }
    public var isFinished: Bool { outcome == .succeeded || outcome == .failed }
}

/// The last `capacity` tool calls of one session, oldest first. Pure and `Equatable`, kept inside `AgentSession`.
///
/// Matching a result to its call: by the agent's call id when both carry one, else the newest unfinished call
/// with the same tool, summary and agent thread. Hook processes run in parallel, so a result can arrive before
/// its own start: it is then recorded as a finished call, and the late start is dropped.
public struct RecentToolCalls: Equatable, Sendable {
    public static let defaultCapacity = 12

    public let capacity: Int
    /// Oldest first.
    public private(set) var calls: [ToolCall] = []
    private var nextId = 0

    public init(capacity: Int = RecentToolCalls.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public var isEmpty: Bool { calls.isEmpty }
    public var count: Int { calls.count }
    public var latest: ToolCall? { calls.last }
    /// Newest first (the card's timeline).
    public var newestFirst: [ToolCall] { calls.reversed() }
    public var running: [ToolCall] { calls.filter(\.isRunning) }
    public var failures: Int { calls.filter { $0.outcome == .failed }.count }

    /// A call started (PreToolUse; a permission request for a call not seen yet). `isLatest`: no later event of
    /// the session has arrived yet (an out-of-order start whose result is already here is dropped).
    public mutating func start(name: String, summary: String?, callId: String?, agentId: String?, at moment: Moment,
                               isLatest: Bool = true) {
        if let callId, calls.contains(where: { $0.callId == callId }) { return }
        // Already running (PreToolUse, then its permission request without the call's id): nothing new.
        if callId == nil, unfinishedIndex(name: name, summary: summary, agentId: agentId, runningOnly: true) != nil {
            return
        }
        if !isLatest, callId == nil,
           calls.contains(where: { $0.isFinished && $0.name == name && $0.summary == summary
                                    && $0.agentId == agentId && ($0.finished?.monotonic ?? 0) >= moment.monotonic }) {
            return
        }
        insert(ToolCall(id: takeId(), callId: callId, agentId: agentId, name: name, summary: summary, started: moment))
    }

    /// A call's result (PostToolUse: `success`; PostToolUseFailure: not, with its `error`).
    public mutating func finish(name: String, summary: String?, callId: String?, agentId: String?, at moment: Moment,
                                success: Bool, error: String? = nil) {
        let outcome: ToolCall.Outcome = success ? .succeeded : .failed
        let index: Int? = {
            if let callId, let i = calls.lastIndex(where: { $0.callId == callId }) { return i }
            return unfinishedIndex(name: name, summary: summary, agentId: agentId, callId: callId)
        }()
        if let i = index {
            if calls[i].isFinished { return }   // a duplicate result
            calls[i].outcome = outcome
            calls[i].finished = moment
            calls[i].error = success ? nil : Self.clean(error)
            if calls[i].callId == nil { calls[i].callId = callId }
            return
        }
        // No start seen (it arrived late, or the start hook is not installed): a call that took no time.
        insert(ToolCall(id: takeId(), callId: callId, agentId: agentId, name: name, summary: summary, started: moment,
                        finished: moment, outcome: outcome, error: success ? nil : Self.clean(error)))
    }

    /// The turn of `agentId` (nil: the main thread; `all`: every thread) ended at `moment`: its calls still running
    /// will get no result in this turn.
    public mutating func endTurn(agentId: String?, all: Bool = false, at moment: Moment) {
        for i in calls.indices where calls[i].isRunning && (all || calls[i].agentId == agentId)
            && calls[i].started.monotonic <= moment.monotonic {
            calls[i].outcome = .abandoned
        }
    }

    /// The wall clock was set by `delta` seconds (see `SessionStore.shiftWallClock`).
    public mutating func shiftWall(by delta: TimeInterval) {
        for i in calls.indices {
            calls[i].started.wall.addTimeInterval(delta)
            calls[i].finished?.wall.addTimeInterval(delta)
        }
    }

    // MARK: Internals

    private mutating func takeId() -> Int {
        defer { nextId &+= 1 }
        return nextId
    }

    /// In start order (a late start of an older call goes before newer ones); the oldest fall off past `capacity`.
    private mutating func insert(_ call: ToolCall) {
        let at = calls.lastIndex { $0.started.monotonic <= call.started.monotonic }.map { $0 + 1 } ?? 0
        calls.insert(call, at: at)
        if calls.count > capacity { calls.removeFirst(calls.count - capacity) }
    }

    /// The newest call of this tool, summary and thread without a result (`runningOnly`: not abandoned either);
    /// with a `callId`, only among calls recorded without one.
    private func unfinishedIndex(name: String, summary: String?, agentId: String?, callId: String? = nil,
                                 runningOnly: Bool = false) -> Int? {
        calls.lastIndex {
            (runningOnly ? $0.isRunning : !$0.isFinished) && $0.name == name && $0.summary == summary
                && $0.agentId == agentId && (callId == nil || $0.callId == nil)
        }
    }

    private static func clean(_ error: String?) -> String? {
        guard let line = SessionNaming.oneLine(error) else { return nil }
        return line.count > 300 ? String(line.prefix(299)) + "…" : line
    }
}

extension AgentEvent {
    /// The agent's id of this tool call: `tool_use_id` (Claude, Codex), `tool_call_id` (Kimi).
    var toolCallId: String? {
        for key in ["tool_use_id", "tool_call_id"] {
            if case .string(let id)? = raw[key], !id.isEmpty { return id }
        }
        return nil
    }
}
