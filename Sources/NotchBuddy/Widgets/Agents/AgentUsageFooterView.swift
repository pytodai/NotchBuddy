import SwiftUI
import NotchBuddyCore

// The expanded island's usage footer for every agent: one row per agent, its windows lined up in columns
// ("5 часов", "Неделя", "Месяц") so the bars of Claude, Codex and Kimi read as one table.
//
// Motion (all of it off under Reduce Motion, all of it sampled by `islandFilmTime` in filmstrips):
// - the header and rows cascade in (`appearAfter`), each agent mark pops in;
// - every bar fills on the island's fill spring from what it last showed (from zero the first time), its color
//   warming white → amber → red *as it fills*, the percent counting up with it and a glowing head riding its end;
// - once a bar lands a highlight sweeps along it; crossing into a warmer level flares its head;
// - from 90 % the head breathes; a window that has reset says so in green; stale rows dim and show their age;
// - a row whose numbers are on their way shows shimmering placeholders.

/// Footer of the expanded island: every agent's usage windows, aligned in columns.
struct AgentUsageFooterView: View {
    let usages: [AgentUsage]
    var showsHeader = true
    /// When the header starts to appear; rows and bars follow.
    var delay: Double = 0.12
    var maxColumns = 3
    /// Whose usage this is («Авто», one agent): a small chip beside «Лимиты» (a click on the footer steps through).
    var choice: UsageProviderChoice?
    @Environment(IslandClock.self) private var clock: IslandClock?

    static let nameWidth: CGFloat = 114
    static let spacing: CGFloat = 14

    var body: some View {
        // Whole minutes: reset times and ages change by the minute, so rows are not rebuilt every second.
        let now = Date(timeIntervalSinceReferenceDate: ((clock?.now ?? Date()).timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
        let rows = usages.map { $0.evaluated(at: now) }
        let columns = AgentUsage.columns(rows, limit: maxColumns)
        VStack(alignment: .leading, spacing: 11) {
            if showsHeader {
                AgentUsageHeader(columns: columns, choice: choice)
                    .appearAfter(delay, style: .header)
            }
            ForEach(Array(rows.enumerated()), id: \.element.agent) { index, usage in
                let rowDelay = delay + 0.03 + 0.045 * Double(index)
                AgentUsageRow(usage: usage, columns: columns, now: now, delay: rowDelay)
                    .appearAfter(rowDelay, style: .row)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -6)).animation(IslandMotion.leaf),
                        removal: .opacity.animation(.easeOut(duration: 0.12).speed(IslandMotion.speed))))
            }
        }
        .animation(IslandMotion.leaf, value: rows.map(\.agent))
        .animation(IslandMotion.leaf, value: columns)
    }
}

/// "ЛИМИТЫ · 5 ЧАСОВ · НЕДЕЛЯ".
private struct AgentUsageHeader: View {
    let columns: [String]
    var choice: UsageProviderChoice?

    var body: some View {
        HStack(spacing: AgentUsageFooterView.spacing) {
            HStack(spacing: 6) {
                label(L("Лимиты"))
                if let choice { UsageChoiceChip(choice: choice) }
            }
            .frame(width: AgentUsageFooterView.nameWidth, alignment: .leading)
            ForEach(columns, id: \.self) { id in
                label(AgentUsageWindow.label(forID: id))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .help(L("Claude и Kimi — по данным их серверов, Codex — по журналам Codex на этом Mac"))
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(UsageType.font(size: 9.5, weight: 760))
            .tracking(0.9)
            .foregroundStyle(IslandPalette.tertiary)
            .lineLimit(1)
    }
}

// MARK: - Row

struct AgentUsageRow: View {
    let usage: AgentUsage
    let columns: [String]
    let now: Date
    let delay: Double

    var body: some View {
        HStack(alignment: .center, spacing: AgentUsageFooterView.spacing) {
            AgentUsageIdentity(usage: usage, now: now, delay: delay)
                .frame(width: AgentUsageFooterView.nameWidth, alignment: .leading)
            if usage.hasData, !columns.isEmpty {
                ForEach(Array(columns.enumerated()), id: \.element) { column, id in
                    cell(id, column: column)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if usage.isLoading {
                ForEach(0..<max(columns.count, 2), id: \.self) { column in
                    UsageSkeletonMeter(delay: delay + 0.06 * Double(column))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                AgentUsageNote(note: usage.note ?? LKey("нет данных"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: 32)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func cell(_ id: String, column: Int) -> some View {
        if let window = usage.window(id) {
            AgentUsageMeter(key: "\(usage.agent.rawValue).\(id)", window: window, now: now, stale: usage.stale,
                            delay: delay + 0.05 + 0.06 * Double(column))
        } else {
            UsageEmptyMeter()
        }
    }
}

/// Agent mark, short name, plan badge; below: "лимит исчерпан" or how old the numbers are.
private struct AgentUsageIdentity: View {
    let usage: AgentUsage
    let now: Date
    let delay: Double

    var body: some View {
        HStack(spacing: 8) {
            AgentMark(source: usage.agent, size: 20)
                .overlay(alignment: .topTrailing) {
                    if usage.limitReached { LimitBadge().offset(x: 3, y: -3).transition(.scale.combined(with: .opacity)) }
                }
                .modifier(UsagePopIn(delay: delay))
            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 5) {
                    Text(Self.name(usage.agent))
                        .font(UsageType.font(size: 12.5, weight: 700))
                        .foregroundStyle(IslandPalette.primary)
                        .lineLimit(1)
                        .fixedSize()
                    if let plan = usage.plan { UsagePlanBadge(text: plan) }
                }
                subtitle
            }
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if usage.limitReached {
            Text(L("лимит исчерпан"))
            .font(UsageType.font(size: 9.5, weight: 650))
            .foregroundStyle(AgentUsagePalette.danger)
            .lineLimit(1)
            .transition(.blurReplace)
        } else if usage.stale, let fetchedAt = usage.fetchedAt {
            HStack(spacing: 3) {
                Image(systemName: "clock")
                    .font(.system(size: 8.5, weight: .semibold))
                Text(Self.age(now.timeIntervalSince(fetchedAt)))
            }
            .font(UsageType.font(size: 10, weight: 560))
            .foregroundStyle(IslandPalette.tertiary)
            .lineLimit(1)
            .help(L("Обновлено %@", Self.age(now.timeIntervalSince(fetchedAt))))
            .transition(.blurReplace)
        }
    }

    static func name(_ agent: AgentSource) -> String {
        switch agent {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .kimi: return "Kimi"
        default: return AgentCatalog.descriptor(for: agent)?.shortName ?? agent.rawValue
        }
    }

    /// "3 ч назад", "2 д назад" (coarse: the exact minute does not matter for a stale value).
    static func age(_ seconds: TimeInterval) -> String {
        let s = seconds.isFinite ? max(seconds, 0) : 0
        if s < 3600 { return L("%@\u{00A0}мин назад", max(Int(s / 60), 1)) }
        if s < 86400 { return L("%@\u{00A0}ч назад", Int(s / 3600)) }
        return L("%@\u{00A0}д назад", Int(s / 86400))
    }
}

/// A red dot on the agent mark while its limit is hit; it pulses once when it appears.
private struct LimitBadge: View {
    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var ping = false

    var body: some View {
        Circle()
            .fill(AgentUsagePalette.danger)
            .frame(width: 7, height: 7)
            .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5).padding(-1.5))
            .background {
                Circle()
                    .stroke(AgentUsagePalette.danger, lineWidth: 1.2)
                    .scaleEffect(ping ? 2.6 : 1)
                    .opacity(ping ? 0 : 0.8)
            }
            .onAppear {
                guard !staticRender, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.9).delay(0.35).speed(IslandMotion.speed)) { ping = true }
            }
    }
}

/// "PLUS" in a small glassy capsule.
private struct UsagePlanBadge: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(UsageType.font(size: 8, weight: 800))
            .tracking(0.5)
            .foregroundStyle(Color.white.opacity(0.78))
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            .overlay(Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                lineWidth: 0.5))
            .fixedSize()
    }
}

/// A row with nothing to show: why, in one line ("Откройте Kimi Code, чтобы обновить"). `note` is what the model keeps:
/// usually the Russian key (`LKey`), translated here so it follows a language switch.
private struct AgentUsageNote: View {
    let note: String

    var body: some View {
        let text = L(note)
        let sentence = text.prefix(1).uppercased() + text.dropFirst()
        HStack(spacing: 6) {
            Image(systemName: Self.symbol(for: note))
                .font(.system(size: 10, weight: .semibold))
            Text(sentence)
                .font(UsageType.font(size: 11, weight: 560))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(IslandPalette.tertiary)
        .help(sentence)
    }

    /// The glyph for a note, by its Russian key (or its text, for a note made already translated).
    static func symbol(for note: String) -> String {
        // l10n-ignore-begin (matching words, not copy)
        let s = note.lowercased()
        func any(_ words: String...) -> Bool { words.contains { s.contains($0) } }
        if any("вход", "войдите", "sign in", "log in", "login", "signed") { return "person.crop.circle.badge.exclamationmark" }
        if any("откройте", "open kimi") { return "arrow.clockwise" }
        if any("появятся", "will appear") { return "hourglass" }
        if s.contains("api") { return "gauge.with.dots.needle.0percent" }
        if any("не удалось", "ошибка", "лимит запросов", "error", "couldn’t", "couldn't", "rate limit") {
            return "exclamationmark.triangle"
        }
        // l10n-ignore-end
        return "gauge.with.dots.needle.33percent"
    }
}

// MARK: - Meter

/// One window: its bar with the percent, and when it resets.
private struct AgentUsageMeter: View {
    let key: String
    let window: AgentUsageWindow
    let now: Date
    let stale: Bool
    let delay: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4.5) {
            AgentUsageBar(key: key, used: window.used, didReset: window.didReset, delay: delay)
            resetLine
                .font(UsageType.font(size: 10, weight: 560, tabular: true))
                .lineLimit(1)
                .contentTransition(.numericText(countsDown: true))
                .animation(IslandMotion.leaf, value: resetText)
        }
        .opacity(stale ? 0.55 : 1)
        .saturation(stale ? 0.3 : 1)
        .animation(IslandMotion.tint, value: stale)
        .help(helpText)
    }

    private var resetText: String {
        if window.didReset { return L("сброшено") }
        guard let resets = window.resetsAt else { return "" }
        let left = resets.timeIntervalSince(now)
        return left < 60 ? L("<1\u{00A0}мин") : IslandFormat.duration(left + 59)
    }

    @ViewBuilder
    private var resetLine: some View {
        if window.didReset {
            HStack(spacing: 3) {
                Image(systemName: "sparkles").font(.system(size: 8.5, weight: .semibold))
                Text(resetText)
            }
            .foregroundStyle(AgentUsagePalette.fresh)
            .transition(.blurReplace)
        } else if window.resetsAt != nil {
            HStack(spacing: 3) {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 8, weight: .bold))
                Text(resetText)
            }
            .foregroundStyle(window.used >= 100 ? AgentUsagePalette.danger.opacity(0.9) : IslandPalette.tertiary)
        } else {
            Text(" ")
        }
    }

    private var helpText: String {
        var parts = ["\(window.label): \(IslandFormat.percent(window.used))"]
        if window.didReset { parts.append(L("лимит уже сброшен")) }
        if let resets = window.resetsAt { parts.append(IslandFormat.reset(resets, now: now) ?? "") }
        return parts.joined(separator: ", ")
    }
}

/// The agent has no such window (Codex on a weekly-only plan): a dotted track.
private struct UsageEmptyMeter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4.5) {
            HStack(spacing: 8) {
                DottedTrack()
                    .stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [0.01, 4.5]))
                    .frame(height: AgentUsageBar.height)
                Text("—")
                    .font(UsageType.font(size: 12, weight: 700))
                    .foregroundStyle(Color.white.opacity(0.22))
                    .frame(width: AgentUsageBar.percentWidth, alignment: .trailing)
            }
            Text(" ").font(UsageType.font(size: 10, weight: 560))
        }
        .help(L("Такого лимита у этого агента нет"))
    }
}

private struct DottedTrack: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 1, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX - 1, y: r.midY))
        return p
    }
}

// MARK: - Bar

/// What each bar last showed, so a list opened again continues from there (bars fill from zero once per run).
@MainActor
enum AgentUsageMemory {
    static var shown: [String: Double] = [:]
}

enum AgentUsageMotion {
    static let fill = IslandMotion.fillCurve
    /// The sweep waits for the fill to land (≈ 0.4 s of a 0.6 s spring), then crosses in 0.7 s.
    static let sweepHold = 0.42
    static let sweepRun = 0.7

    @KeyframesBuilder<Double>
    static func sweep(hold: Double) -> some Keyframes<Double> {
        KeyframeTrack {
            LinearKeyframe(0, duration: IslandMotion.t(max(hold, 0.001)))
            CubicKeyframe(1, duration: IslandMotion.t(sweepRun))
        }
    }

    static func sweepValue(hold: Double, at t: Double) -> Double {
        guard t > 0 else { return 0 }
        return KeyframeTimeline(initialValue: 0.0) { sweep(hold: hold) }.value(time: t)
    }

    /// A head flare when the bar crosses into a warmer level.
    @KeyframesBuilder<Double>
    static func flare() -> some Keyframes<Double> {
        KeyframeTrack {
            CubicKeyframe(1, duration: IslandMotion.t(0.14))
            CubicKeyframe(0, duration: IslandMotion.t(0.8))
        }
    }
}

/// Level colors, blended smoothly so a filling bar warms up as it passes 70 % and 90 %.
enum AgentUsagePalette {
    static let calm = (r: 0.93, g: 0.93, b: 0.93)
    static let warn = (r: 1.0, g: 0.72, b: 0.2)
    static let hot = (r: 1.0, g: 0.36, b: 0.3)
    static let danger = Color(red: hot.r, green: hot.g, blue: hot.b)
    static let fresh = Color(red: 0.36, green: 0.86, blue: 0.52)

    static func tint(_ used: Double) -> Color {
        func mix(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double), _ t: Double) -> Color {
            let k = smoothstep(0, 1, t)
            return Color(red: a.r + (b.r - a.r) * k, green: a.g + (b.g - a.g) * k, blue: a.b + (b.b - a.b) * k)
        }
        if used < 90 { return mix(calm, warn, (used - 64) / 8) }
        return mix(warn, hot, (used - 86) / 6)
    }
}

/// A bar that fills from what it last showed and follows later changes. One animatable value drives the fill,
/// its color, the head riding its end and the percent beside it, so they never drift apart.
struct AgentUsageBar: View {
    let key: String
    /// 0...100.
    let used: Double
    var didReset = false
    let delay: Double
    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandFilmTime) private var filmTime
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var shown: Double?
    @State private var sweep = 0
    @State private var flare = 0.0

    static let height: CGFloat = 6
    static let percentWidth: CGFloat = 36
    static let breathPeriod = 1.6

    var body: some View {
        let target = min(max(used / 100, 0), 1)
        let current: Double = {
            if let filmTime { return target * AgentUsageMotion.fill.delayed(delay).progress(filmTime) }
            if staticRender { return target }
            return shown ?? (AgentUsageMemory.shown[key] ?? 0)
        }()
        let moving = !staticRender && !reduceMotion
        let breathes = AgentUsageLevel(used: used) == .danger && !reduceMotion && (moving || filmTime != nil)
        HStack(spacing: 8) {
            Color.clear
                .frame(height: Self.height)
                .modifier(AgentUsageBarBody(value: current, target: target, didReset: didReset))
                .overlay { sweepOverlay(current: current, moving: moving) }
                .overlay { head(current: current, target: target, breathes: breathes) }
            Color.clear
                .frame(width: Self.percentWidth, height: 14)
                .modifier(AgentUsagePercent(value: current, target: target, didReset: didReset))
        }
        .onAppear {
            guard filmTime == nil, !staticRender else { return }
            let start = AgentUsageMemory.shown[key] ?? 0
            shown = start
            AgentUsageMemory.shown[key] = target
            guard start != target else { return }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2).speed(IslandMotion.speed)
                          : AgentUsageMotion.fill.delayed(delay).animation) { shown = target }
            if moving, target > 0.02 { sweep &+= 1 }
        }
        .onChange(of: target) { old, new in
            AgentUsageMemory.shown[key] = new
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2).speed(IslandMotion.speed) : IslandMotion.fill) { shown = new }
            guard moving else { return }
            if AgentUsageLevel(used: new * 100) > AgentUsageLevel(used: old * 100) {
                withAnimation(.easeOut(duration: 0.14).speed(IslandMotion.speed)) { flare = 1 }
                withAnimation(.easeInOut(duration: 0.8).delay(0.14).speed(IslandMotion.speed)) { flare = 0 }
            }
            if new > old + 0.005 { sweep &+= 1 }
        }
    }

    /// A soft highlight crossing the filled part once, after the fill lands (and after each rise).
    @ViewBuilder
    private func sweepOverlay(current: Double, moving: Bool) -> some View {
        if let filmTime {
            SweepBand(phase: AgentUsageMotion.sweepValue(hold: delay + AgentUsageMotion.sweepHold, at: filmTime),
                      fraction: current)
        } else if moving {
            Color.clear
                .keyframeAnimator(initialValue: 0.0, trigger: sweep) { content, phase in
                    content.overlay { SweepBand(phase: phase, fraction: current) }
                } keyframes: { _ in
                    AgentUsageMotion.sweep(hold: sweep <= 1 ? delay + AgentUsageMotion.sweepHold : 0.35)
                }
        }
    }

    /// The glowing head: flares on a level-up, breathes from 90 %.
    @ViewBuilder
    private func head(current: Double, target: Double, breathes: Bool) -> some View {
        if let filmTime {
            Color.clear.modifier(AgentUsageHead(
                value: current, flare: 0, target: target, didReset: didReset,
                glow: breathes ? Self.breath(filmTime) : 0))
        } else if breathes {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { context in
                Color.clear.modifier(AgentUsageHead(
                    value: current, flare: flare, target: target, didReset: didReset,
                    glow: Self.breath(context.date.timeIntervalSinceReferenceDate / IslandMotion.slowmo)))
            }
        } else {
            Color.clear.modifier(AgentUsageHead(value: current, flare: flare, target: target, didReset: didReset, glow: 0))
        }
    }

    static func breath(_ t: Double) -> Double { 0.5 + 0.5 * sin(t * 2 * .pi / breathPeriod) }
}

/// Track and fill at the animated `value` (0…1), colored by the level it has reached so far.
private struct AgentUsageBarBody: ViewModifier, Animatable {
    var value: Double
    let target: Double
    let didReset: Bool

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    func body(content: Content) -> some View {
        let tint = didReset ? AgentUsagePalette.fresh : AgentUsagePalette.tint(min(value, target) * 100)
        content.background {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)
                BarFill(fraction: CGFloat(value))
                    .fill(LinearGradient(colors: [tint.opacity(0.5), tint], startPoint: .leading, endPoint: .trailing))
                // A glassy top edge.
                BarFill(fraction: CGFloat(value))
                    .fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
                    .blendMode(.plusLighter)
            }
        }
    }
}

/// The bright dot riding the end of the fill, with a halo in the fill's color. `flare` (0…1) swells it after a
/// level-up, `glow` (0…1) is the breathing from 90 %.
private struct AgentUsageHead: ViewModifier, Animatable {
    var value: Double
    var flare: Double
    let target: Double
    let didReset: Bool
    let glow: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(value, flare) }
        set {
            value = newValue.first
            flare = newValue.second
        }
    }

    func body(content: Content) -> some View {
        let tint = didReset ? AgentUsagePalette.fresh : AgentUsagePalette.tint(min(value, target) * 100)
        let x = CGFloat(min(max(value, 0), 1))
        let heat = min(max(glow + flare, 0), 1.4)
        content.overlay {
            HeadDot(fraction: x)
                .fill(Color.white.opacity(0.95))
                // No halo (no colored glows on the island): `heat` only swells the dot a little.
                .scaleEffect(1 + 0.12 * CGFloat(heat), anchor: UnitPoint(x: x, y: 0.5))
                .scaleEffect(1 + 0.55 * CGFloat(flare), anchor: UnitPoint(x: x, y: 0.5))
                .opacity(value > 0.015 ? 1 : 0)
                .allowsHitTesting(false)
        }
    }
}

/// "42%", counting with the fill; colored like it.
private struct AgentUsagePercent: ViewModifier, Animatable {
    var value: Double
    let target: Double
    let didReset: Bool

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    func body(content: Content) -> some View {
        let shown = min(max(value, 0), target) * 100
        let level = AgentUsageLevel(used: shown)
        content.overlay(alignment: .trailing) {
            Text(IslandFormat.percent(shown))
                .font(UsageType.font(size: 12, weight: 720, tabular: true))
                .foregroundStyle(didReset ? AgentUsagePalette.fresh
                    : level == .calm ? Color.white.opacity(0.9) : AgentUsagePalette.tint(shown))
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// A band of light at `phase` (0 = before the start, 1 = past the end) of the filled part, clipped to it.
private struct SweepBand: View {
    let phase: Double
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            let filled = geo.size.width * CGFloat(min(max(fraction, 0), 1))
            let band: CGFloat = max(22, min(filled * 0.45, 44))
            LinearGradient(colors: [.clear, .white.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .offset(x: -band + (filled + band) * CGFloat(phase))
                .opacity(phase > 0 && phase < 1 ? 1 : 0)
        }
        .mask(BarFill(fraction: CGFloat(fraction)))
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

private struct HeadDot: Shape {
    var fraction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in r: CGRect) -> Path {
        let d = r.height
        let x = min(max(r.minX + r.width * min(max(fraction, 0), 1) - d / 2, r.minX), r.maxX - d)
        return Path(ellipseIn: CGRect(x: x, y: r.minY, width: d, height: d).insetBy(dx: 0.6, dy: 0.6))
    }
}

// MARK: - Loading

/// A placeholder bar with light travelling along it while the numbers load.
private struct UsageSkeletonMeter: View {
    let delay: Double
    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandFilmTime) private var filmTime
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                bar(width: nil)
                bar(width: 26)
            }
            bar(width: 54).frame(height: 5)
        }
        .accessibilityLabel(L("Загрузка лимитов"))
    }

    private func bar(width: CGFloat?) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.07))
            .overlay { shimmer }
            .clipShape(Capsule())
            .frame(width: width, height: AgentUsageBar.height)
    }

    @ViewBuilder
    private var shimmer: some View {
        if let filmTime {
            SkeletonGlint(phase: ((filmTime - delay) / 1.3).truncatingRemainder(dividingBy: 1))
        } else if !staticRender, !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate / IslandMotion.slowmo - delay
                SkeletonGlint(phase: (t / 1.3).truncatingRemainder(dividingBy: 1))
            }
        }
    }
}

private struct SkeletonGlint: View {
    let phase: Double

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(0.14), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: max(geo.size.width * 0.6, 20))
                .offset(x: -geo.size.width * 0.6 + geo.size.width * 1.6 * CGFloat(max(phase, 0)))
        }
    }
}

// MARK: - Small motion

/// The agent mark springs in (scale and a small turn) as its row appears.
private struct UsagePopIn: ViewModifier {
    let delay: Double
    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandFilmTime) private var filmTime
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var shown = false

    static let spring = Spring(response: 0.42, dampingRatio: 0.58)

    func body(content: Content) -> some View {
        let s: Double = {
            if reduceMotion { return 1 }
            if let filmTime { return filmTime > delay ? Self.spring.value(target: 1.0, time: filmTime - delay) : 0 }
            return shown || staticRender ? 1 : 0
        }()
        content
            .scaleEffect(0.62 + 0.38 * CGFloat(s))
            .rotationEffect(.degrees(-14 * (1 - min(s, 1.2))))
            .opacity(min(max(s * 1.8, 0), 1))
            .onAppear {
                guard !shown, !staticRender, filmTime == nil, !reduceMotion else { return }
                withAnimation(.spring(Self.spring).delay(delay).speed(IslandMotion.speed)) { shown = true }
            }
    }
}

/// «АВТО» / «CLAUDE» beside «Лимиты»: whose usage the footer shows. A new choice rolls in from below.
struct UsageChoiceChip: View {
    let choice: UsageProviderChoice

    var body: some View {
        Text(choice.label.uppercased())
            .font(UsageType.font(size: 8.5, weight: 780))
            .tracking(0.7)
            .foregroundStyle(Color.white.opacity(0.78))
            .lineLimit(1)
            .fixedSize()
            .id(choice)
            .transition(.asymmetric(insertion: .offset(y: 7).combined(with: .opacity),
                                    removal: .offset(y: -7).combined(with: .opacity)))
            .padding(.horizontal, 5)
            .frame(height: 14)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            .clipShape(Capsule())
            .animation(.spring(response: 0.32, dampingFraction: 0.82).speed(IslandMotion.speed), value: choice)
    }
}
