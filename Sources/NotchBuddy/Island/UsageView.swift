import SwiftUI
import NotchBuddyCore

/// Color of a usage level: calm white, then amber, then red close to the limit.
func usageTint(_ utilization: Double) -> Color {
    switch utilization {
    case ..<70: return Color(white: 0.93)
    case ..<90: return Color(red: 1.0, green: 0.72, blue: 0.2)
    default: return Color(red: 1.0, green: 0.36, blue: 0.3)
    }
}

/// 0 below 70 %, 1 below 90 %, 2 above: crossing upward deserves a glance.
private func usageLevel(_ utilization: Double) -> Int { utilization < 70 ? 0 : utilization < 90 ? 1 : 2 }

/// What the usage bars and ring last showed, so a list opened again continues from there instead of
/// filling from zero every time (they fill from zero once per run).
@MainActor
enum UsageMemory {
    static var shown: [String: Double] = [:]
}

/// Footer of the expanded island: Claude's 5-hour and 7-day windows side by side.
struct UsageView: View {
    let usage: UsageState
    /// When the bars start filling (after the footer itself appeared).
    var barDelay: Double = 0.12
    @Environment(IslandClock.self) private var clock: IslandClock?

    var body: some View {
        let now = clock?.now ?? Date()
        ZStack(alignment: .topLeading) {
            switch usage {
            case .loaded(let snapshot):
                HStack(alignment: .top, spacing: 20) {
                    UsageMeter(id: "5h", label: L("5 часов"), window: snapshot.fiveHour, now: now, delay: barDelay)
                    UsageMeter(id: "7d", label: L("7 дней"), window: snapshot.sevenDay, now: now, delay: barDelay + 0.06)
                }
                .transition(.blurReplace.animation(.easeInOut(duration: 0.25).speed(IslandMotion.speed)))
            case .unavailable(let reason):
                HStack(spacing: 8) {
                    Image(systemName: reason.contains("API") ? "gauge.with.dots.needle.0percent" : "gauge.with.dots.needle.33percent")
                        .font(.system(size: 12, weight: .medium))
                    Text(Self.unavailableText(reason))
                        .font(.manrope(11.5, weight: 580))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(IslandPalette.tertiary)
                .transition(.blurReplace.animation(.easeInOut(duration: 0.25).speed(IslandMotion.speed)))
            }
        }
    }

    /// "нет данных (API выключен)" → "Лимиты недоступны: API выключен". `reason` is the model's note: usually the
    /// Russian key (`LKey`), translated here.
    static func unavailableText(_ reason: String) -> String {
        if reason == UsageFetchState.networkOffReason { return L("Лимиты недоступны: API выключен") }
        return L("Лимиты Claude: %@", L(reason))
    }
}

/// One usage window: label, percent, a bar that fills up, when it resets.
private struct UsageMeter: View {
    let id: String
    let label: String
    let window: UsageWindow?
    let now: Date
    let delay: Double

    var body: some View {
        let utilization = window?.utilization ?? 0
        let tint = window.map { usageTint($0.utilization) } ?? IslandPalette.tertiary
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.manrope(11.5, weight: 680))
                    .foregroundStyle(IslandPalette.secondary)
                Spacer(minLength: 4)
                // An odometer: each changed digit rolls, up as the usage grows.
                NumberRoll(window.map { IslandFormat.percent($0.utilization) } ?? "—",
                           font: .manrope(13, weight: 760, tabular: true))
                    .foregroundStyle(tint)
                    .animation(IslandMotion.tint, value: usageLevel(utilization))
            }
            UsageBar(id: id, fraction: utilization / 100, tint: tint, delay: delay)
            Text(IslandFormat.reset(window?.resetsAt, now: now) ?? " ")
                .font(.manrope(10.5, weight: 520))
                .contentTransition(.numericText(countsDown: true))
                .foregroundStyle(IslandPalette.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The bar's fill as one animatable shape (no layout per frame).
struct BarFill: Shape {
    var fraction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in r: CGRect) -> Path {
        let w = r.width * min(max(fraction, 0), 1)
        guard w > 0 else { return Path() }
        return Path(roundedRect: CGRect(x: r.minX, y: r.minY, width: max(w, r.height), height: r.height),
                    cornerRadius: r.height / 2, style: .continuous)
    }
}

/// A bar that fills from what it last showed (from zero the first time) and follows later changes.
private struct UsageBar: View {
    let id: String
    let fraction: Double
    let tint: Color
    let delay: Double
    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandFilmTime) private var filmTime
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var shown: Double?
    @State private var glowTrigger = 0

    var body: some View {
        let value = min(max(fraction, 0), 1)
        let current: Double = {
            if let filmTime { return value * IslandMotion.fillCurve.delayed(delay).progress(filmTime) }
            if staticRender { return value }
            return shown ?? (UsageMemory.shown[id] ?? 0)
        }()
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.1))
            // The glow is cast by a solid copy underneath (a keyframed modifier directly on a gradient fill
            // loses the shape's clip in some renderers).
            BarFill(fraction: CGFloat(current))
                .fill(tint)
                .keyframeAnimator(initialValue: 0.0, trigger: glowTrigger) { content, glow in
                    // No colored glow: a level-up brightens the bar a touch instead.
                    content.brightness(0.25 * glow)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(0.6, duration: IslandMotion.t(0.15))
                        CubicKeyframe(0.25, duration: IslandMotion.t(0.7))
                    }
                }
            BarFill(fraction: CGFloat(current))
                .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
        }
        .frame(height: 5)
        .onAppear {
            guard filmTime == nil, !staticRender else { return }
            let start = UsageMemory.shown[id] ?? 0
            shown = start
            UsageMemory.shown[id] = value
            guard start != value else { return }
            let animation = reduceMotion ? Animation.easeInOut(duration: 0.2).speed(IslandMotion.speed)
                : IslandMotion.fillCurve.delayed(delay).animation
            withAnimation(animation) { shown = value }
        }
        .onChange(of: value) { old, new in
            UsageMemory.shown[id] = new
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2).speed(IslandMotion.speed) : IslandMotion.fill) { shown = new }
            if usageLevel(new * 100) > usageLevel(old * 100), !reduceMotion { glowTrigger &+= 1 }
        }
    }
}

/// Small ring (+ percent) for the collapsed island. It fills from zero once per run, then shows its
/// value at once and follows changes.
struct UsageRing: View {
    let utilization: Double
    var size: CGFloat = 14
    var showsPercent = true
    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandFilmTime) private var filmTime
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.islandEntrance) private var entrance
    @State private var filled = UsageMemory.shown["ring"] != nil
    @State private var breath = 0

    var body: some View {
        let tint = usageTint(utilization)
        let fraction = min(max(utilization / 100, 0.03), 1)
        let shownFraction: Double = {
            // Filmstrips: the ring fills only when the island first appears.
            if let filmTime, entrance == .pop {
                return fraction * min(max(Spring(response: 0.8, dampingRatio: 0.9).value(target: 1.0, time: filmTime - 0.25), 0), 1.2)
            }
            if filmTime != nil { return fraction }
            return filled || staticRender ? fraction : 0
        }()
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.16), lineWidth: 2.3)
                Circle()
                    .trim(from: 0, to: shownFraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(IslandMotion.fill, value: fraction)
                    .animation(IslandMotion.tint, value: usageLevel(utilization))
            }
            .frame(width: size, height: size)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: breath) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(1.12, duration: IslandMotion.t(0.15))
                    CubicKeyframe(1, duration: IslandMotion.t(0.2))
                }
            }
            if showsPercent {
                Text(IslandFormat.percent(utilization))
                    .font(.manrope(12.5, weight: 580, tabular: true))
                    .monospacedDigit()
                    .foregroundStyle(utilization >= 70 ? tint : Color.white.opacity(0.78))
                    .contentTransition(.numericText(value: utilization))
                    .animation(.smooth(duration: 0.5).speed(IslandMotion.speed), value: utilization)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .onAppear {
            guard !filled, filmTime == nil, !staticRender else { return }
            UsageMemory.shown["ring"] = utilization
            if reduceMotion {
                filled = true
            } else {
                withAnimation(.spring(response: 0.8, dampingFraction: 0.9).delay(0.25).speed(IslandMotion.speed)) { filled = true }
            }
        }
        .onChange(of: usageLevel(utilization)) { old, new in
            if new > old, !reduceMotion { breath &+= 1 }
        }
        .accessibilityLabel(L("Лимит Claude за 5 часов: %@", IslandFormat.percent(utilization)))
    }
}

extension UsageState {
    /// 5-hour utilization when loaded.
    var fiveHourUtilization: Double? {
        if case .loaded(let snapshot) = self { return snapshot.fiveHour?.utilization }
        return nil
    }
}
