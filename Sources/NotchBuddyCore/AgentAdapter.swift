import Foundation

public enum AdapterError: Error, Equatable {
    case invalidJSON
    case missingField(String)
}

/// What the bridge must do after the app (or a timeout) produced a decision.
public struct BridgeOutput: Equatable, Sendable {
    public var stdout: String?
    public var stderr: String?
    public var exitCode: Int32

    public init(stdout: String? = nil, stderr: String? = nil, exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    /// Print nothing, exit 0: the agent behaves as if no hook were installed.
    public static let passthrough = BridgeOutput()
}

/// Per-agent translation between the agent's hook protocol and NotchBuddy's model.
public protocol AgentAdapter: Sendable {
    var source: AgentSource { get }

    /// Parse the hook's stdin payload. `host` is filled in by the bridge.
    func normalize(stdin: Data, host: HostContext) throws -> AgentEvent

    /// Whether this event blocks the agent waiting for a decision from the island.
    func expectsDecision(_ event: AgentEvent) -> Bool

    /// Agent-specific stdout/exit code for a decision on a permission event.
    func render(_ decision: PermissionDecision, for event: AgentEvent) -> BridgeOutput

    /// How long the bridge waits for the island's decision before falling back (printing nothing).
    /// Must stay below the hook timeout the installer registers for the permission event.
    var decisionTimeout: TimeInterval { get }
}

extension AgentAdapter {
    public var decisionTimeout: TimeInterval { 600 }
}

public enum Adapters {
    /// The adapter `AgentCatalog` names for `source` (its `ProtocolFamily`). An id the catalog does not know
    /// gets `UnknownAgentAdapter`, which rejects every payload (the bridge then prints nothing).
    public static func adapter(for source: AgentSource) -> AgentAdapter {
        switch AgentCatalog.descriptor(for: source)?.protocolFamily {
        case .claude: return ClaudeAdapter()
        case .codex: return CodexAdapter()
        case .kimi: return KimiAdapter()
        case .claudeCompatible(let profile): return ClaudeCompatibleAdapter(source: source, profile: profile)
        case .cursor: return CursorAdapter()
        case .cline: return ClineAdapter()
        case nil: return UnknownAgentAdapter(source: source)
        }
    }
}

/// For ids outside `AgentCatalog`: never normalizes, never answers.
public struct UnknownAgentAdapter: AgentAdapter {
    public let source: AgentSource
    public func normalize(stdin: Data, host: HostContext) throws -> AgentEvent {
        throw AdapterError.missingField("source")
    }
    public func expectsDecision(_ event: AgentEvent) -> Bool { false }
    public func render(_ decision: PermissionDecision, for event: AgentEvent) -> BridgeOutput { .passthrough }
}

/// Helpers shared by adapters.
public enum ToolSummary {
    /// Builds a one-line summary of a tool call from common tool_input shapes.
    public static func summarize(toolName: String?, input: JSONValue?) -> String? {
        guard let input else { return nil }
        let keys = ["command", "cmd", "file_path", "path", "filePath", "url", "pattern", "query", "description", "prompt"]
        for k in keys {
            if let v = input[k] {
                if let s = v.string, !s.isEmpty { return oneLine(s) }
                if let a = v.array {
                    let parts = a.compactMap(\.string)
                    if !parts.isEmpty { return oneLine(parts.joined(separator: " ")) }
                }
            }
        }
        if let s = input.string { return oneLine(s) }
        if input.object?.isEmpty == false { return oneLine(input.compactText) }
        return nil
    }

    public static func oneLine(_ s: String, limit: Int = 400) -> String {
        let collapsed = s.replacingOccurrences(of: "\n", with: " ⏎ ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }
}
