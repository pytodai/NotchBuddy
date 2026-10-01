import SwiftUI
import NotchBuddyCore

/// The system widget's block of the island's settings (⚙️): which gauges show, the low-battery live activity and
/// its level, power notices.
struct SystemSettingsSection: View {
    let preferences: SystemPreferences

    var body: some View {
        @Bindable var prefs = preferences
        VStack(alignment: .leading, spacing: 8) {
            GadgetSettingsHeader(glyph: .gauge, tint: SystemPalette.cpu, title: L("Система"))
            VStack(spacing: 0) {
                GadgetToggleRow(title: L("Низкий заряд у выреза"), subtitle: L("Свёрнутый остров покажет батарею, когда она садится"),
                                isOn: $prefs.lowBatteryLiveActivity)
                GadgetRowDivider()
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Порог заряда"))
                            .font(GadgetFont.font(12.5, .semibold))
                            .foregroundStyle(IslandPalette.primary)
                        Text(L("Ниже — уведомление"))
                            .font(GadgetFont.font(11, .medium))
                            .foregroundStyle(IslandPalette.tertiary)
                    }
                    Spacer(minLength: 8)
                    GadgetSegmented(options: SystemPreferences.thresholds.map { ($0, L("%@\u{00A0}%%", $0)) },
                                    selection: $prefs.lowBatteryThreshold)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 50)
                GadgetRowDivider()
                GadgetToggleRow(title: L("Питание"), subtitle: L("Уведомлять о зарядке и отключении"),
                                isOn: $prefs.powerNotices)
                GadgetRowDivider()
                HStack(spacing: 10) {
                    Text(L("Показывать"))
                        .font(GadgetFont.font(12.5, .semibold))
                        .foregroundStyle(IslandPalette.primary)
                    Spacer(minLength: 8)
                    GadgetChipToggle(title: L("ЦП"), glyph: .chip, tint: SystemPalette.cpu, isOn: $prefs.showsCPU)
                    GadgetChipToggle(title: L("Память"), glyph: .memory, tint: SystemPalette.memory, isOn: $prefs.showsMemory)
                    GadgetChipToggle(title: L("Диск"), glyph: .disk, tint: SystemPalette.disk, isOn: $prefs.showsDisk)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 50)
            }
            .gadgetCard(radius: 14)
        }
    }
}

/// A chip that lights up in its hue when on.
struct GadgetChipToggle: View {
    let title: String
    let glyph: GadgetGlyph
    let tint: GadgetTint
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(GadgetMotion.bouncy) { isOn.toggle() }
        } label: {
            HStack(spacing: 5) {
                GadgetIcon(glyph: glyph, size: 12, color: isOn ? tint.hi : IslandPalette.tertiary)
                Text(title)
                    .font(GadgetFont.font(11.5, .bold))
                    .foregroundStyle(isOn ? Color.white : IslandPalette.tertiary)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Capsule().fill(isOn ? tint.lo.opacity(0.22) : Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(isOn ? tint.hi.opacity(0.35) : Color.white.opacity(0.06), lineWidth: 0.7))
            .contentShape(Capsule())
        }
        .buttonStyle(GadgetPressStyle(scale: 0.92))
        .accessibilityValue(isOn ? L("включено") : L("выключено"))
    }
}
