import Foundation

/// What the closed island shows when nothing asks for more (a permission card and a notice always come first): the
/// agents' live activity, or one widget's.
public enum IslandActivityKind: String, CaseIterable, Sendable {
    /// The sessions' pill (the most important session, "+N", the usage ring).
    case agents
    case timer
    case calendar
    case music
    /// Low battery.
    case system
    /// The shelf's fan of files.
    case shelf
    /// A file is being dragged toward the island: "Брось на полку".
    case shelfDrag

    /// The tab that opens when the closed island showing this is clicked.
    public var widget: WidgetKind {
        switch self {
        case .agents: return .agents
        case .timer: return .timer
        case .calendar: return .calendar
        case .music: return .music
        case .system: return .system
        case .shelf, .shelfDrag: return .shelf
        }
    }
}

/// Everything the closed island's arbitration looks at, as flags (the services fill them in).
public struct IslandActivitySignals: Equatable, Sendable {
    /// A session waits for the user.
    public var agentWaiting = false
    /// A session works (or just failed).
    public var agentBusy = false
    /// Any session at all (finished, idle…).
    public var agentPresent = false
    /// A timer is in its last seconds, or one has just finished.
    public var timerUrgent = false
    /// A meeting starts soon (the calendar's reminder window).
    public var calendarSoon = false
    /// Music plays (or was paused a moment ago).
    public var musicPlaying = false
    /// A timer counts down.
    public var timerRunning = false
    /// The battery is low.
    public var batteryLow = false
    /// The shelf holds files and shows its badge.
    public var shelfBadge = false
    /// A file drag comes near the island.
    public var shelfDrag = false

    public init(agentWaiting: Bool = false, agentBusy: Bool = false, agentPresent: Bool = false, timerUrgent: Bool = false,
                calendarSoon: Bool = false, musicPlaying: Bool = false, timerRunning: Bool = false, batteryLow: Bool = false,
                shelfBadge: Bool = false, shelfDrag: Bool = false) {
        self.agentWaiting = agentWaiting
        self.agentBusy = agentBusy
        self.agentPresent = agentPresent
        self.timerUrgent = timerUrgent
        self.calendarSoon = calendarSoon
        self.musicPlaying = musicPlaying
        self.timerRunning = timerRunning
        self.batteryLow = batteryLow
        self.shelfBadge = shelfBadge
        self.shelfDrag = shelfDrag
    }
}

/// Which live activity the closed island shows. Permission cards and notices are overlays and never reach this; below
/// them: a file dragged toward the island (the user is doing it right now) > an agent waiting > a timer finishing or
/// just finished > a meeting soon > agents working > music playing > a timer running > low battery > the shelf's badge
/// > any other session. Nil: nothing to show.
public enum IslandActivityArbiter {
    public static func choose(_ s: IslandActivitySignals) -> IslandActivityKind? {
        if s.shelfDrag { return .shelfDrag }
        if s.agentWaiting { return .agents }
        if s.timerUrgent { return .timer }
        if s.calendarSoon { return .calendar }
        if s.agentBusy { return .agents }
        if s.musicPlaying { return .music }
        if s.timerRunning { return .timer }
        if s.batteryLow { return .system }
        if s.shelfBadge { return .shelf }
        if s.agentPresent { return .agents }
        return nil
    }

    /// How many seconds before its end a running timer counts as "finishing" (it takes over the closed island).
    public static let timerUrgentLead: TimeInterval = 10
}

// MARK: - Usage

public enum UsageSelection {
    /// The one agent whose limits the island shows (the header strip): the chosen
    /// agent, or with «Авто» the agent of the most important session (`focus`) when it has numbers, else Claude, else
    /// the first agent with numbers. A chosen agent with nothing (yet) shows a «нет данных» row, so a click always
    /// shows where it went. Nil: nobody has anything to show.
    public static func shown(_ usages: [AgentUsage], choice: UsageProviderChoice, focus: AgentSource?) -> AgentUsage? {
        if let agent = choice.agent {
            return usages.first { $0.agent == agent } ?? .unavailable(agent, LKey("нет данных"))
        }
        func withData(_ agent: AgentSource?) -> AgentUsage? {
            agent.flatMap { a in usages.first { $0.agent == a && $0.hasData } }
        }
        return withData(focus) ?? withData(.claude) ?? usages.first(where: \.hasData) ?? usages.first
    }

    /// The rows of the usage list: the agent `shown` picks (one row; empty when there is nothing).
    public static func rows(_ usages: [AgentUsage], choice: UsageProviderChoice, focus: AgentSource? = nil) -> [AgentUsage] {
        shown(usages, choice: choice, focus: focus).map { [$0] } ?? []
    }

    /// What a click on the usage switches to: Авто → Claude → Codex → Kimi → Авто, skipping agents without numbers
    /// (nobody has any: it stays on «Авто»).
    public static func next(after choice: UsageProviderChoice, usages: [AgentUsage]) -> UsageProviderChoice {
        let all = UsageProviderChoice.allCases
        let start = all.firstIndex(of: choice) ?? 0
        for step in 1...all.count {
            let candidate = all[(start + step) % all.count]
            guard let agent = candidate.agent else { return candidate }
            if usages.contains(where: { $0.agent == agent && $0.hasData }) { return candidate }
        }
        return .auto
    }

    /// The closed island's ring: the chosen agent's first window (5 hours before the week); «Авто»: the agent of the
    /// session the island shows when it has numbers, else Claude, else whoever has any.
    public static func ring(_ usages: [AgentUsage], choice: UsageProviderChoice, focus: AgentSource?) -> (agent: AgentSource, used: Double)? {
        func first(_ agent: AgentSource) -> (AgentSource, Double)? {
            guard let usage = usages.first(where: { $0.agent == agent }),
                  let window = usage.windows.min(by: { AgentUsageWindow.order($0.id) < AgentUsageWindow.order($1.id) })
            else { return nil }
            return (agent, window.used)
        }
        if let agent = choice.agent { return first(agent) }
        if let focus, let hit = first(focus) { return hit }
        if let hit = first(.claude) { return hit }
        for usage in usages { if let hit = first(usage.agent) { return hit } }
        return nil
    }
}
