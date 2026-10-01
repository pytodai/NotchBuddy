import SwiftUI
import NotchBuddyCore

/// The system widget ("островок" Система) for a page of the open island: the battery (a large glyph, the
/// percent, time left, the power state), then CPU / memory / disk gauges and the last minute of CPU load.
/// Gauges sweep up as the page opens and follow new samples (every 2 s, only while this is on screen).
struct SystemWidgetView: View {
    let monitor: SystemMonitor
    let metrics: IslandMetrics
    var width: CGFloat = 492
    var openSettings: (() -> Void)?
    /// Its own title row (off on the island, where the tab strip names the tab).
    var showsHeader = true

    static let sidePadding: CGFloat = 10

    var body: some View {
        let prefs = monitor.preferences
        let tiles = [prefs.showsCPU, prefs.showsMemory, prefs.showsDisk].filter { $0 }.count
        VStack(spacing: 8) {
            if showsHeader {
                header
                    .appearAfter(0.02, style: .header)
            }
            if let battery = monitor.battery {
                BatteryCard(state: battery, threshold: prefs.lowBatteryThreshold)
                    .padding(.horizontal, Self.sidePadding)
                    .appearAfter(0.04, style: .section)
            }
            if tiles > 0 {
                HStack(spacing: 8) {
                    if prefs.showsCPU {
                        GaugeTile(title: L("ЦП"), glyph: .chip, value: monitor.cpu ?? 0,
                                  tint: SystemPalette.load(monitor.cpu ?? 0, base: SystemPalette.cpu),
                                  format: { monitor.cpu == nil ? "—" : SystemFormat.percent($0) },
                                  detail: "\(CPULoad.coreCount) \(IslandFormat.plural(CPULoad.coreCount, "ядро", "ядра", "ядер"))",
                                  delay: 0.12)
                    }
                    if prefs.showsMemory {
                        let memory = monitor.memory
                        GaugeTile(title: L("Память"), glyph: .memory, value: memory?.fraction ?? 0,
                                  tint: memoryTint(memory),
                                  format: { f in memory.map { SystemFormat.bytes(UInt64(Double($0.total) * f), binary: true) } ?? "—" },
                                  detail: memory.map { memoryDetail($0) } ?? " ", delay: 0.16)
                    }
                    if prefs.showsDisk {
                        let disk = monitor.disk
                        GaugeTile(title: L("Диск"), glyph: .disk, value: disk?.fraction ?? 0,
                                  tint: SystemPalette.load(disk?.fraction ?? 0, base: SystemPalette.disk),
                                  format: { f in disk.map { SystemFormat.bytes(Int64(Double($0.total) * (1 - f)), binary: false) } ?? "—" },
                                  detail: disk.map { L("свободно из %@", SystemFormat.bytes($0.total, binary: false)) } ?? " ",
                                  delay: 0.2)
                    }
                }
                .padding(.horizontal, Self.sidePadding)
                .appearAfter(0.065, style: .section)
            }
            if prefs.showsCPU {
                CPUHistoryCard(values: monitor.cpuHistory, tick: monitor.sampleCount, current: monitor.cpu)
                    .padding(.horizontal, Self.sidePadding)
                    .appearAfter(0.09, style: .section)
            }
        }
        .padding(.bottom, 14)
        .frame(width: width)
        .systemSampling(monitor)
    }

    private func memoryTint(_ memory: MemoryUsage?) -> GadgetTint {
        switch memory?.pressure ?? .normal {
        case .critical: return GadgetTint(hi: Color(red: 1.0, green: 0.52, blue: 0.40), lo: SystemPalette.critical)
        case .warning: return GadgetTint(hi: Color(red: 1.0, green: 0.84, blue: 0.40), lo: SystemPalette.warning)
        case .normal: return SystemPalette.memory
        }
    }

    private func memoryDetail(_ memory: MemoryUsage) -> String {
        switch memory.pressure {
        case .critical: return L("нагрузка высокая")
        case .warning: return L("нагрузка повышена")
        case .normal: return L("из %@", SystemFormat.bytes(memory.total, binary: true))
        }
    }

    // MARK: Header

    private var header: some View {
        let notch = metrics.style == .notch
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                GadgetIconTile(glyph: .gauge, tint: SystemPalette.cpu, size: 22)
                Text(L("Система"))
                    .font(GadgetFont.font(13.5, .bold))
                    .foregroundStyle(IslandPalette.primary)
            }
            Spacer(minLength: notch ? metrics.notchWidth + 12 : 8)
            HStack(spacing: 6) {
                if monitor.thermal == .serious || monitor.thermal == .critical {
                    TimerSummaryChip(text: monitor.thermal == .critical ? L("перегрев") : L("греется"),
                                     tint: SystemPalette.batteryLow, live: true)
                }
                if !notch || monitor.thermal == .nominal || monitor.thermal == .fair {
                    Text(L("работает %@", SystemFormat.uptime(monitor.uptime)))
                        .font(GadgetFont.font(11, .semibold))
                        .foregroundStyle(IslandPalette.tertiary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                if let openSettings {
                    GadgetSettingsButton(action: openSettings)
                }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .frame(height: notch ? metrics.barHeight : 44)
        .padding(.top, notch ? 0 : 2)
    }
}

// MARK: - Battery card

/// The battery, wide: the glyph, the percent rolling, what it is doing and for how long.
struct BatteryCard: View {
    let state: BatteryState
    var threshold = 20

    var body: some View {
        let tint = SystemPalette.battery(state, threshold: threshold)
        HStack(spacing: 18) {
            BatteryGlyph(state: state, width: 86, height: 40, threshold: threshold)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(state.percent)")
                        .font(GadgetFont.font(28, .heavy))
                        .monospacedDigit()
                        .foregroundStyle(IslandPalette.primary)
                        .contentTransition(.numericText(value: Double(state.percent)))
                        .animation(GadgetMotion.digits, value: state.percent)
                    Text("%")
                        .font(GadgetFont.font(15, .bold))
                        .foregroundStyle(IslandPalette.secondary)
                }
                Text(SystemFormat.batteryDetail(state).gadgetCapitalized)
                    .font(GadgetFont.font(12.5, .semibold))
                    .foregroundStyle(tint.hi.opacity(0.95))
                    .contentTransition(.interpolate)
                    .animation(GadgetMotion.fade, value: state.phase)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                PowerChip(state: state, tint: tint)
                if state.lowPowerMode {
                    TimerSummaryChip(text: L("энергосбережение"), tint: SystemPalette.batteryMid, live: false)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 76)
        .gadgetCard(radius: 18, tint: tint.lo)
        .animation(GadgetMotion.snap, value: state.lowPowerMode)
    }
}

/// "От батареи" / "Заряжается" / "Подключено" / "Заряжен".
private struct PowerChip: View {
    let state: BatteryState
    let tint: GadgetTint

    var body: some View {
        let text: String = {
            switch state.phase {
            case .discharging: return L("от батареи")
            case .charging: return L("заряжается")
            case .onHold: return L("подключено")
            case .full: return L("заряжен")
            }
        }()
        HStack(spacing: 5) {
            if state.onAC {
                GadgetIcon(glyph: state.phase == .charging ? .bolt : .plug, size: 11, color: tint.hi, weight: 2.4)
            } else {
                Circle().fill(tint.hi).frame(width: 5, height: 5)
            }
            Text(text)
                .font(GadgetFont.font(11, .semibold))
                .foregroundStyle(tint.hi.opacity(0.95))
                .contentTransition(.interpolate)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(tint.lo.opacity(0.14)))
        .overlay(Capsule().strokeBorder(tint.hi.opacity(0.16), lineWidth: 0.6))
        .animation(GadgetMotion.snap, value: state.phase)
    }
}

// MARK: - Gauge tiles

/// One gauge in a tile: the arc with the number (counting up with the sweep) and the title inside it, a detail
/// line under it. It lifts and brightens under the pointer.
struct GaugeTile: View {
    let title: String
    let glyph: GadgetGlyph
    let value: Double
    let tint: GadgetTint
    /// The number for a gauge value (0…1), so it can count with the arc.
    let format: (Double) -> String
    let detail: String
    var delay: Double = 0.1
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            ArcGauge(value: value, tint: tint, size: 92, lineWidth: 7.5, delay: delay) { current in
                VStack(spacing: 3) {
                    GaugeValueText(value: current, format: format, size: 17)
                        .frame(maxWidth: 62)
                    HStack(spacing: 4) {
                        GadgetIcon(glyph: glyph, size: 11, color: tint.hi, weight: 2.3)
                        Text(title)
                            .font(GadgetFont.font(10.5, .bold))
                            .foregroundStyle(IslandPalette.secondary)
                    }
                }
            }
            .scaleEffect(hovering ? 1.04 : 1)
            // The arc is open at the bottom: the detail sits in its mouth.
            .padding(.bottom, -13)
            Text(detail)
                .font(GadgetFont.font(10.5, .medium))
                .foregroundStyle(IslandPalette.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.interpolate)
                .padding(.horizontal, 6)
        }
        .padding(.top, 10)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity)
        .gadgetCard(radius: 16, tint: hovering ? tint.lo : nil, hovering: hovering)
        .offset(y: hovering ? -1.5 : 0)
        .onHover { inside in withAnimation(GadgetMotion.hover) { hovering = inside } }
    }
}

// MARK: - CPU history

/// "ЦП за минуту": the sparkline with the current value beside it.
struct CPUHistoryCard: View {
    let values: [Double]
    let tick: Int
    let current: Double?

    var body: some View {
        let tint = SystemPalette.load(current ?? 0, base: SystemPalette.cpu)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                GadgetCaption(text: L("ЦП за минуту"))
                Text(peakText)
                    .font(GadgetFont.font(11, .medium))
                    .foregroundStyle(IslandPalette.tertiary)
                    .contentTransition(.numericText())
            }
            .frame(width: 100, alignment: .leading)
            Sparkline(values: values, tick: tick, tint: tint)
                .frame(height: 34)
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .gadgetCard(radius: 16)
    }

    private var peakText: String {
        guard let peak = values.max() else { return L("собираю…") }
        return L("пик %@", SystemFormat.percent(peak))
    }
}

extension String {
    /// "осталось 3 ч" → "Осталось 3 ч".
    var gadgetCapitalized: String { prefix(1).uppercased() + dropFirst() }
}
