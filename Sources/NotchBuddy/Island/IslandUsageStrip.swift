import NotchBuddyCore
import SwiftUI

/// The open island's usage readout, in its header: whose limits these are (the agent's mark
/// and name) and every window in one compact line, tabular digits — "Claude  5ч 46% · 35м │ 7д 69% · 1д11ч". A click
/// switches agent (Авто → Claude → Codex → Kimi → Авто, skipping agents without numbers, `UsageSelection.next`); the
/// numbers roll and the mark cross-fades. «Авто» shows the agent of the most important session (else Claude).
/// It gives way gracefully: without the reset times, then the first window alone.
struct IslandUsageStrip: View {
    let snapshot: IslandSnapshot
    let cycle: () -> Void
    @Environment(IslandClock.self) private var clock: IslandClock?
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.islandFilmTime) private var filmTime
    @State private var hovering = false

    /// The agent shown and its numbers (Claude's own reader when the multi-agent hub has nothing: previews, the bench).
    static func usage(_ snapshot: IslandSnapshot) -> AgentUsage? {
        let usages = snapshot.agentUsages.isEmpty ? [snapshot.usage.agentUsage] : snapshot.agentUsages
        return UsageSelection.shown(usages, choice: snapshot.usageChoice, focus: snapshot.primary?.key.source)
    }

    var body: some View {
        let usage = Self.usage(snapshot)
        Button {
            withAnimation(IslandMotion.data.animation) { cycle() }
        } label: {
            HStack(spacing: 7) {
                if let usage {
                    ZStack {
                        AgentMark(source: usage.agent, size: 13)
                            .id(usage.agent)
                            // Films never tick SwiftUI's own animations: the mark swaps at once there.
                            .transition(filmTime != nil ? .identity
                                        : .opacity.combined(with: .scale(scale: 0.7)).animation(IslandMotion.leaf))
                    }
                    .frame(width: 13, height: 13)
                }
                ViewThatFits(in: .horizontal) {
                    line(usage, resets: true, name: true)
                    line(usage, resets: false, name: false)
                    line(usage, resets: false, name: false, windows: 1)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.08 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12).speed(IslandMotion.speed)) { hovering = inside } }
        .animation(reduceMotion ? nil : IslandMotion.leaf, value: usage?.agent)
        .help(L("Чьи лимиты: %@. Клик — следующий агент с данными", snapshot.usageChoice.label))
        .accessibilityLabel(L("Лимиты %@", usage.map { AgentUsageIdentityName.name($0.agent) } ?? ""))
    }

    @ViewBuilder
    private func line(_ usage: AgentUsage?, resets: Bool, name: Bool, windows limit: Int = 2) -> some View {
        HStack(spacing: 7) {
            if let usage, name {
                Text(AgentUsageIdentityName.name(usage.agent))
                    .font(.manrope(11.5, weight: 700))
                    .foregroundStyle(IslandPalette.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let usage, usage.hasData {
                let shown = Array(usage.windows.prefix(limit))
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, window in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 1, height: 10)
                    }
                    windowText(window, resets: resets, stale: usage.stale)
                }
            } else {
                Text(usage.flatMap(\.note).map { $0 == AgentUsage.loadingNote ? L("лимиты…") : L($0) } ?? L("нет лимитов"))
                    .font(.manrope(11.5, weight: 600))
                    .foregroundStyle(IslandPalette.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .fixedSize()
    }

    private func windowText(_ window: AgentUsageWindow, resets: Bool, stale: Bool) -> some View {
        let used = IslandFormat.percentValue(window.used)
        let tint = stale ? IslandPalette.tertiary : AgentUsagePalette.tint(window.used)
        let reset = resets ? window.resetsAt.flatMap { IslandFormat.compactLeft($0.timeIntervalSince(clock?.now ?? Date())) } : nil
        return HStack(spacing: 4) {
            Text(IslandFormat.windowShort(window.id, label: window.label))
                .foregroundStyle(IslandPalette.secondary)
            NumberRoll(L("%@%%", used), font: .manrope(11.5, weight: 760, tabular: true))
                .foregroundStyle(tint)
            if let reset {
                Text("· \(reset)")
                    .foregroundStyle(IslandPalette.tertiary)
            }
        }
        .font(.manrope(11.5, weight: 620, tabular: true))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
}

/// Agent names as the usage readouts write them («Claude», «Codex», «Kimi»).
enum AgentUsageIdentityName {
    static func name(_ agent: AgentSource) -> String {
        switch agent {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .kimi: return "Kimi"
        default: return agent.displayName
        }
    }
}

extension IslandFormat {
    /// "35м", "4ч10м", "1д11ч" (English: "35m", "4h10m", "1d11h"); nil when it is over.
    static func compactLeft(_ interval: TimeInterval) -> String? {
        guard interval.isFinite, interval > 0 else { return nil }
        let minutes = Int(min(interval + 59, 1e9)) / 60
        if minutes < 60 { return L("%@м", minutes) }
        let hours = minutes / 60, restMinutes = minutes % 60
        if hours < 24 { return restMinutes == 0 ? L("%@ч", hours) : L("%@ч%@м", hours, restMinutes) }
        let days = hours / 24, restHours = hours % 24
        return restHours == 0 ? L("%@д", days) : L("%@д%@ч", days, restHours)
    }

    /// A window's short name: "5ч", "7д", "мес" (else its own label).
    static func windowShort(_ id: String, label: String) -> String {
        switch id {
        case "5h": return L("5ч")
        case "7d": return L("7д")
        case "month": return L("мес")
        default: return label
        }
    }
}
