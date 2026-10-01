import Foundation

/// Codex rate limits as its rollouts record them: `event_msg` / `payload.type == "token_count"` lines carrying
/// `payload.rate_limits`. Read-only: no network, no credentials.
public struct CodexRateLimits: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        /// 0...100.
        public var usedPercent: Double
        /// 300 = 5 hours, 10080 = a week.
        public var windowMinutes: Int?
        public var resetsAt: Date?

        public init(usedPercent: Double, windowMinutes: Int?, resetsAt: Date?) {
            self.usedPercent = usedPercent
            self.windowMinutes = windowMinutes
            self.resetsAt = resetsAt
        }
    }

    /// "codex" for the main bucket; others ("codex_bengalfox", "premium") share the same event.
    public var limitId: String
    public var limitName: String?
    /// `primary` then `secondary`, the non-null ones only.
    public var windows: [Window]
    /// snake_case plan (`plus`, `pro`, `team`…).
    public var planType: String?
    /// Non-nil once the limit is hit (`rate_limit_reached`, `workspace_…`).
    public var reachedType: String?
    public var creditsBalance: String?
    /// The line's own `timestamp`: the data is as fresh as the last model response on this Mac.
    public var capturedAt: Date

    public init(limitId: String, limitName: String? = nil, windows: [Window], planType: String? = nil,
                reachedType: String? = nil, creditsBalance: String? = nil, capturedAt: Date) {
        self.limitId = limitId
        self.limitName = limitName
        self.windows = windows
        self.planType = planType
        self.reachedType = reachedType
        self.creditsBalance = creditsBalance
        self.capturedAt = capturedAt
    }

    public static let mainLimitID = "codex"
    /// The byte pattern a `token_count` line always contains (Codex writes compact JSON).
    public static let needle = Data(#""type":"token_count""#.utf8)

    public var fiveHour: Window? { windows.first { $0.windowMinutes == 300 } }
    public var weekly: Window? { windows.first { $0.windowMinutes == 10080 } }

    /// One rollout line; nil unless it is a `token_count` whose `rate_limits` has at least one window.
    public static func parse(line: Data) -> CodexRateLimits? {
        guard let json = try? JSONValue.parse(line),
              json["type"]?.string == "event_msg",
              json.at("payload", "type")?.string == "token_count",
              let rl = json.at("payload", "rate_limits"), rl.object != nil,
              let stamp = json["timestamp"]?.string, let at = UsageResponse.parseDate(stamp) else { return nil }
        func window(_ v: JSONValue?) -> Window? {
            guard let v, v.object != nil, let used = v["used_percent"]?.double, used.isFinite else { return nil }
            var resets = v["resets_at"]?.double.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            // CLIs before ~0.40 wrote a relative `resets_in_seconds`.
            if resets == nil, let seconds = v["resets_in_seconds"]?.double, seconds.isFinite, seconds >= 0 {
                resets = at.addingTimeInterval(seconds)
            }
            let minutes = v["window_minutes"]?.double.flatMap { $0.isFinite && $0 > 0 && $0 < 1e7 ? Int($0) : nil }
            return Window(usedPercent: min(max(used, 0), 100), windowMinutes: minutes, resetsAt: resets)
        }
        let windows = [window(rl["primary"]), window(rl["secondary"])].compactMap { $0 }
        guard !windows.isEmpty else { return nil }   // e.g. "premium" with both windows null
        let limitId = rl["limit_id"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? mainLimitID   // Codex's own default
        return CodexRateLimits(limitId: limitId,
                               limitName: rl["limit_name"]?.string,
                               windows: windows,
                               planType: rl["plan_type"]?.string,
                               reachedType: rl["rate_limit_reached_type"]?.string,
                               creditsBalance: rl.at("credits", "balance")?.string,
                               capturedAt: at)
    }

    /// "Plus", "Pro"…; nil for plans without a badge.
    public static func planLabel(_ planType: String?) -> String? {
        switch planType?.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "pro_lite": return "Pro Lite"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        case "go": return "Go"
        default: return nil
        }
    }

    /// Codex data is only as fresh as the last model response on this Mac; past this age the UI says how old it is.
    public static let staleAfter: TimeInterval = 6 * 60 * 60

    /// The normalized usage as of `now` (windows by length, reset windows at 0 %).
    public func agentUsage(now: Date) -> AgentUsage {
        let mapped: [AgentUsageWindow] = windows.enumerated().map { i, w in
            let id = w.windowMinutes.map(AgentUsageWindow.id(minutes:)) ?? (i == 0 ? "5h" : "7d")
            return AgentUsageWindow(id: id, used: w.usedPercent, resetsAt: w.resetsAt, minutes: w.windowMinutes)
        }
        var unique: [AgentUsageWindow] = []
        for w in mapped where !unique.contains(where: { $0.id == w.id }) { unique.append(w) }
        return AgentUsage(agent: .codex, windows: unique, plan: Self.planLabel(planType), fetchedAt: capturedAt,
                          staleAfter: Self.staleAfter, limitReached: reachedType != nil)
            .evaluated(at: now)
    }
}

// MARK: - Reading rollouts

public enum CodexRollouts {
    /// Newest `rollout-*.jsonl` files under `sessions/` by modification time (a resumed session keeps writing into
    /// its original day folder, so the path's date means nothing). Compressed `.jsonl.zst` files are at least a
    /// week cold and are skipped, as are guardian `auto-review-rollout-*` files.
    public static func newest(in sessionsDir: URL, limit: Int = 8,
                              fileManager: FileManager = .default) -> [(url: URL, modified: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = fileManager.enumerator(at: sessionsDir, includingPropertiesForKeys: keys,
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [(url: URL, modified: Date)] = []
        for case let url as URL in walker {
            guard isRollout(url),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            found.append((url, modified))
        }
        found.sort { $0.modified > $1.modified }
        return Array(found.prefix(max(limit, 0)))
    }

    public static func isRollout(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    /// Newest snapshot per `limit_id` from the end of the file: the last 64 KB first, growing ×4 up to `maxBytes`
    /// (single lines can be megabytes). Partial lines at either end are skipped; stops once "codex" is found.
    public static func readTail(of url: URL, initialBytes: UInt64 = 64 << 10,
                                maxBytes: UInt64 = 8 << 20) -> [String: CodexRateLimits] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return [:] }
        var window = max(min(initialBytes, maxBytes), 1)
        var found: [String: CodexRateLimits] = [:]
        while true {
            found.removeAll()
            let start = size > window ? size - window : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let chunk = try? handle.read(upToCount: Int(size - start)), !chunk.isEmpty else { break }
            var lines = chunk.split(separator: 0x0A, omittingEmptySubsequences: false)
            if chunk.last != 0x0A, !lines.isEmpty { lines.removeLast() }   // the writer is mid-line
            if start > 0, !lines.isEmpty { lines.removeFirst() }           // cut by the window
            for line in lines.reversed() where line.range(of: CodexRateLimits.needle) != nil {
                guard let snapshot = CodexRateLimits.parse(line: Data(line)) else { continue }
                if found[snapshot.limitId] == nil { found[snapshot.limitId] = snapshot }
                if snapshot.limitId == CodexRateLimits.mainLimitID { return found }
            }
            if start == 0 || window >= maxBytes { break }
            window = min(window * 4, maxBytes)
        }
        return found
    }
}

/// Where Codex keeps its data. A launchd-started app does not see the shell's `CODEX_HOME`, so a hook's
/// `transcript_path` (…/sessions/YYYY/MM/DD/rollout-….jsonl) is the best witness.
public enum CodexHome {
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               transcriptPath: String? = nil, home: URL = Paths.home) -> URL {
        if let path = transcriptPath, let root = root(ofTranscript: path) { return root }
        if let env = environment["CODEX_HOME"], !env.isEmpty { return URL(fileURLWithPath: env, isDirectory: true) }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    /// `/x/.codex/sessions/2026/09/21/rollout-….jsonl` → `/x/.codex`; nil for anything else.
    public static func root(ofTranscript path: String) -> URL? {
        let url = URL(fileURLWithPath: path)
        guard CodexRollouts.isRollout(url) else { return nil }
        var dir = url.deletingLastPathComponent()
        for _ in 0..<6 {
            if dir.lastPathComponent == "sessions" { return dir.deletingLastPathComponent() }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    public static func sessions(_ home: URL) -> URL { home.appendingPathComponent("sessions", isDirectory: true) }
}
