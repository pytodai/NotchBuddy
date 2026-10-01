import Foundation
import NotchBuddyCore

/// Every agent's usage in one list for the island (Claude, Codex, Kimi; more agents plug in the same way).
///
/// Wiring:
/// - `start()` once at launch; `stop()` at quit.
/// - `updateClaude(_:)` with `AppModel.usage` whenever it changes (Claude's own fetcher is untouched).
/// - `handle(_:)` with every hook event (Codex: read the rollout after a turn; Kimi: try a fetch after a turn).
/// - `islandOpened()` when the list opens (cheap re-checks).
/// - `kimiToggleChanged()` after the «Лимиты Kimi» setting flips.
/// Views read `usages` (already evaluated for resets and staleness each minute).
@MainActor
final class AgentUsageHub: ObservableObject {
    /// The rows to show, in agent order; agents with nothing to say are left out.
    @Published private(set) var usages: [AgentUsage] = []

    let codex: CodexUsageReader
    let kimi: KimiUsageFetcher
    /// Show the Claude row (the settings may hide it).
    var showsClaude = true { didSet { rebuild() } }
    var showsCodex = true { didSet { rebuild() } }

    private var claude: AgentUsage?
    private var timer: Timer?
    private var running = false

    init(codex: CodexUsageReader? = nil, kimi: KimiUsageFetcher? = nil) {
        let codex = codex ?? CodexUsageReader()
        let kimi = kimi ?? KimiUsageFetcher()
        self.codex = codex
        self.kimi = kimi
        codex.onChange = { [weak self] _ in self?.rebuild() }
        kimi.onChange = { [weak self] _ in self?.rebuild() }
    }

    func start() {
        guard !running else { return }
        running = true
        codex.start()
        kimi.start()
        // Resets and staleness move with the clock, not with new data.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
        timer?.tolerance = 5
        rebuild()
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        codex.stop()
        kimi.stop()
    }

    func updateClaude(_ state: UsageState) {
        let usage = state.agentUsage
        guard usage != claude else { return }
        claude = usage
        rebuild()
    }

    func handle(_ event: AgentEvent) {
        switch event.source {
        case .codex:
            codex.noteHookEvent(event)
        case .kimi:
            if [.stop, .stopFailed, .sessionEnd, .sessionStart].contains(event.kind) { kimi.nudge() }
        default:
            break  // Claude (usage comes from the statusLine / API) and catalog agents (no usage source)
        }
    }

    func islandOpened() {
        codex.refresh()
        kimi.nudge()
    }

    func kimiToggleChanged() {
        kimi.enabledChanged()
    }

    private func rebuild() {
        let now = Date()
        var rows: [AgentUsage] = []
        if showsClaude, let claude { rows.append(claude.evaluated(at: now)) }
        if showsCodex {
            if let snapshot = codex.snapshot {
                rows.append(snapshot.agentUsage(now: now))
            } else if codex.codexPresent {
                rows.append(.unavailable(.codex, LKey("лимиты появятся после ответа Codex")))
            }
        }
        if let kimi = kimi.usage { rows.append(kimi.evaluated(at: now)) }
        if rows != usages { usages = rows }
    }
}

extension UsageState {
    /// Claude's usage in the shared shape (the adapter for `AgentUsageHub` and the footer).
    var agentUsage: AgentUsage {
        switch self {
        case .loaded(let snapshot):
            return .claude(fiveHour: snapshot.fiveHour.map { ($0.utilization, $0.resetsAt) },
                           sevenDay: snapshot.sevenDay.map { ($0.utilization, $0.resetsAt) },
                           fetchedAt: snapshot.fetchedAt)
        case .unavailable(let reason):
            return .unavailable(.claude, reason == "…" ? AgentUsage.loadingNote : reason)
        }
    }
}

extension AgentUsage {
    /// A row whose numbers are on their way: the footer draws shimmering placeholders.
    static let loadingNote = "…"

    var isLoading: Bool { windows.isEmpty && note == Self.loadingNote }
}
