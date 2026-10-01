import Foundation

/// One rate-limit window of an agent's subscription ("5 часов", "Неделя"), the same shape for every agent.
public struct AgentUsageWindow: Codable, Equatable, Sendable, Identifiable {
    /// Stable key, also the footer column: "5h", "7d", "month", or "<n>min" for an unusual length.
    public var id: String
    /// Column title ("5 часов", "Неделя", "Месяц", "2 ч").
    public var label: String
    /// 0...100.
    public var used: Double
    public var resetsAt: Date?
    /// Window length when the agent says it.
    public var minutes: Int?
    /// The reset time passed after the snapshot was taken: `used` was zeroed by `evaluated(at:)`.
    public var didReset: Bool

    public init(id: String, label: String? = nil, used: Double, resetsAt: Date? = nil, minutes: Int? = nil,
                didReset: Bool = false) {
        self.id = id
        self.label = label ?? AgentUsageWindow.label(forID: id)
        self.used = used.isFinite ? min(max(used, 0), 100) : 0
        self.resetsAt = resetsAt
        self.minutes = minutes
        self.didReset = didReset
    }

    /// The column key of a window `minutes` long.
    public static func id(minutes: Int) -> String {
        switch minutes {
        case 300: return "5h"
        case 10080: return "7d"
        case 40320...44640: return "month"
        default: return "\(minutes)min"
        }
    }

    /// "5 часов", "Неделя", "Месяц"; "2 ч" / "3 дн" / "45 мин" for other lengths.
    public static func label(forID id: String) -> String {
        switch id {
        case "5h": return L("5 часов")
        case "7d": return L("Неделя")
        case "month": return L("Месяц")
        default:
            guard id.hasSuffix("min"), let minutes = Int(id.dropLast(3)), minutes > 0 else { return id }
            if minutes % 1440 == 0 { return L("%@\u{00A0}дн", minutes / 1440) }
            if minutes % 60 == 0 { return L("%@\u{00A0}ч", minutes / 60) }
            return L("%@\u{00A0}мин", minutes)
        }
    }

    /// Footer column order: 5 hours, week, month, then the rest by length.
    public static func order(_ id: String) -> Int {
        switch id {
        case "5h": return 0
        case "7d": return 1
        case "month": return 2
        default:
            let minutes = id.hasSuffix("min") ? Int(id.dropLast(3)) ?? Int.max / 2 : Int.max / 2
            return 3 + min(minutes, Int.max / 2)
        }
    }

    public var level: AgentUsageLevel { AgentUsageLevel(used: used) }
}

/// How close to the limit: calm below 70 %, warning below 90 %, danger from 90 % (the island's own thresholds).
public enum AgentUsageLevel: Int, Comparable, Sendable {
    case calm, warn, danger

    public init(used: Double) {
        self = used < 70 ? .calm : used < 90 ? .warn : .danger
    }

    public static func < (a: AgentUsageLevel, b: AgentUsageLevel) -> Bool { a.rawValue < b.rawValue }
}

/// An agent's subscription usage, normalized: Claude (API or statusLine), Codex (rollouts), Kimi (`/usages`), and
/// whatever comes next. `windows` is empty when there is nothing to show; `note` then says why.
public struct AgentUsage: Codable, Equatable, Sendable, Identifiable {
    public var agent: AgentSource
    public var windows: [AgentUsageWindow]
    /// Plan badge ("Plus", "Pro"), when the agent reports one.
    public var plan: String?
    /// When the numbers were produced (the rollout line's stamp for Codex, the response time otherwise).
    public var fetchedAt: Date?
    /// Older than `staleAfter` at the last `evaluated(at:)`: the UI dims it and says how old it is.
    public var stale: Bool
    public var staleAfter: TimeInterval
    /// The agent said the limit is hit (Codex `rate_limit_reached_type`), until every window has reset.
    public var limitReached: Bool
    /// Russian one-liner for the UI when there is nothing (or something noteworthy) to show.
    public var note: String?

    public var id: AgentSource { agent }

    public init(agent: AgentSource, windows: [AgentUsageWindow], plan: String? = nil, fetchedAt: Date?,
                stale: Bool = false, staleAfter: TimeInterval = AgentUsage.defaultStaleAfter, limitReached: Bool = false,
                note: String? = nil) {
        self.agent = agent
        self.windows = windows.sorted { AgentUsageWindow.order($0.id) < AgentUsageWindow.order($1.id) }
        self.plan = plan
        self.fetchedAt = fetchedAt
        self.stale = stale
        self.staleAfter = staleAfter
        self.limitReached = limitReached
        self.note = note
    }

    public static let defaultStaleAfter: TimeInterval = 30 * 60

    /// Nothing to show, with the reason.
    public static func unavailable(_ agent: AgentSource, _ note: String) -> AgentUsage {
        AgentUsage(agent: agent, windows: [], fetchedAt: nil, note: note)
    }

    public var hasData: Bool { !windows.isEmpty }

    /// The fullest window (the one a compact indicator shows).
    public var headline: AgentUsageWindow? { windows.max { $0.used < $1.used } }

    public func window(_ id: String) -> AgentUsageWindow? { windows.first { $0.id == id } }

    /// As of `now`: a window whose reset time has passed shows 0 % (`didReset`), the limit is no longer hit once
    /// every window has reset, and `stale` follows the snapshot's age. Idempotent.
    public func evaluated(at now: Date) -> AgentUsage {
        var copy = self
        copy.windows = windows.map { w in
            guard let resets = w.resetsAt, now >= resets else { return w }
            var reset = w
            reset.used = 0
            reset.resetsAt = nil
            reset.didReset = true
            return reset
        }
        if copy.limitReached, !windows.isEmpty, copy.windows.allSatisfy(\.didReset) { copy.limitReached = false }
        if let fetchedAt { copy.stale = now.timeIntervalSince(fetchedAt) > staleAfter }
        return copy
    }

    /// Claude's two windows (the app's `UsageSnapshot`, already rolled over by its fetcher).
    public static func claude(fiveHour: (used: Double, resetsAt: Date?)?, sevenDay: (used: Double, resetsAt: Date?)?,
                              fetchedAt: Date?) -> AgentUsage {
        var windows: [AgentUsageWindow] = []
        if let w = fiveHour { windows.append(AgentUsageWindow(id: "5h", used: w.used, resetsAt: w.resetsAt, minutes: 300)) }
        if let w = sevenDay { windows.append(AgentUsageWindow(id: "7d", used: w.used, resetsAt: w.resetsAt, minutes: 10080)) }
        guard !windows.isEmpty else { return .unavailable(.claude, LKey("нет данных")) }
        return AgentUsage(agent: .claude, windows: windows, fetchedAt: fetchedAt, staleAfter: 60 * 60)
    }
}

extension AgentUsage {
    /// Footer columns for several agents: every window id any of them has, in `AgentUsageWindow.order`, at most `limit`.
    public static func columns(_ usages: [AgentUsage], limit: Int = 3) -> [String] {
        var ids: [String] = []
        for usage in usages {
            for w in usage.windows where !ids.contains(w.id) { ids.append(w.id) }
        }
        return Array(ids.sorted { AgentUsageWindow.order($0) < AgentUsageWindow.order($1) }.prefix(limit))
    }
}

/// NotchBuddy's own copy of an agent's last usage (`~/.notchbuddy/run/<agent>-usage.json`, 0600): numbers only,
/// never a credential. Lets the island show the last value (with its age) after a restart.
public enum AgentUsageCache {
    public static func url(for agent: AgentSource, runDir: URL = Paths.runDir) -> URL {
        runDir.appendingPathComponent("\(agent.rawValue)-usage.json")
    }

    public static func write(_ usage: AgentUsage, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Wire.encoder.encode(usage).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func read(from url: URL) -> AgentUsage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Wire.decoder.decode(AgentUsage.self, from: data)
    }
}
