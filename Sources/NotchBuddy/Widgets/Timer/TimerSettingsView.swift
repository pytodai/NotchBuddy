import AppKit
import SwiftUI
import NotchBuddyCore

/// The timer's block of the island's settings (⚙️): end sound (with a preview), celebration, live activity.
struct TimerSettingsSection: View {
    let preferences: TimerPreferences

    var body: some View {
        @Bindable var prefs = preferences
        VStack(alignment: .leading, spacing: 8) {
            GadgetSettingsHeader(glyph: .stopwatch, tint: TimerPalette.coral, title: L("Таймер"))
            VStack(spacing: 0) {
                GadgetToggleRow(title: L("В свёрнутом острове"), subtitle: L("Обратный отсчёт ближайшего таймера у выреза"),
                                isOn: $prefs.liveActivity)
                GadgetRowDivider()
                GadgetToggleRow(title: L("Празднование"), subtitle: L("Искры и вспышка, когда время вышло"),
                                isOn: $prefs.celebrate)
                GadgetRowDivider()
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Звук в конце"))
                            .font(GadgetFont.font(12.5, .semibold))
                            .foregroundStyle(IslandPalette.primary)
                        Text(L("Играет, когда время вышло"))
                            .font(GadgetFont.font(11, .medium))
                            .foregroundStyle(IslandPalette.tertiary)
                    }
                    Spacer(minLength: 8)
                    TimerSoundPicker(sound: $prefs.sound)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 50)
            }
            .gadgetCard(radius: 14)
        }
    }
}

/// ‹ Фанфары › ▶: steps through the end sounds (playing each), and plays the chosen one again. Pure SwiftUI (the
/// island never opens a menu: it must not take the keyboard).
struct TimerSoundPicker: View {
    @Binding var sound: String
    @State private var forward = true

    private static let names = [""] + TimerPreferences.sounds.map(\.name)

    var body: some View {
        HStack(spacing: 2) {
            arrow(.left) { step(-1) }
            Text(TimerPreferences.soundTitle(sound))
                .font(GadgetFont.font(11.5, .bold))
                .foregroundStyle(sound.isEmpty ? IslandPalette.tertiary : Color.white)
                .lineLimit(1)
                .frame(width: 92)
                .id(sound)
                .transition(.push(from: forward ? .trailing : .leading).combined(with: .opacity))
                .clipped()
            arrow(.right) { step(1) }
            GadgetButton(kind: .roundTinted(TimerPalette.coral), height: 24, action: play) {
                GadgetIcon(glyph: .play, size: 9, color: TimerPalette.coral.hi)
            }
            .disabled(sound.isEmpty)
            .opacity(sound.isEmpty ? 0.4 : 1)
            .help(L("Прослушать"))
            .padding(.leading, 4)
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    private enum Side { case left, right }

    private func arrow(_ side: Side, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: side == .left ? "chevron.left" : "chevron.right")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(IslandPalette.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(GadgetPressStyle(scale: 0.85))
    }

    private func step(_ delta: Int) {
        let names = Self.names
        let index = names.firstIndex(of: sound) ?? 0
        forward = delta > 0
        withAnimation(GadgetMotion.snap) { sound = names[(index + delta + names.count) % names.count] }
        play()
    }

    private func play() {
        guard !sound.isEmpty else { return }
        NSSound(named: NSSound.Name(sound))?.play()
    }
}

// MARK: - Controls

struct GadgetSettingsHeader: View {
    let glyph: GadgetGlyph
    let tint: GadgetTint
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            GadgetIconTile(glyph: glyph, tint: tint, size: 20)
            Text(title)
                .font(GadgetFont.font(13, .bold))
                .foregroundStyle(IslandPalette.primary)
        }
        .padding(.leading, 4)
    }
}

struct GadgetRowDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.7).padding(.leading, 12)
    }
}

/// A settings row with a switch that slides with a spring and glows when on.
struct GadgetToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var tint: GadgetTint = TimerPalette.done

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(GadgetFont.font(12.5, .semibold))
                    .foregroundStyle(IslandPalette.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(GadgetFont.font(11, .medium))
                        .foregroundStyle(IslandPalette.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            GadgetSwitch(isOn: $isOn, tint: tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(GadgetMotion.bouncy) { isOn.toggle() } }
    }
}

struct GadgetSwitch: View {
    @Binding var isOn: Bool
    var tint: GadgetTint = TimerPalette.done

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? tint.hi : Color.white.opacity(0.14))
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                .padding(2.5)
        }
        .frame(width: 36, height: 21)
        .animation(GadgetMotion.bouncy, value: isOn)
        .onTapGesture { isOn.toggle() }
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? L("включено") : L("выключено"))
    }
}

/// A segmented choice whose thumb slides between options.
struct GadgetSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Text(option.title)
                    .font(GadgetFont.font(11.5, .bold))
                    .foregroundStyle(selected ? Color.black.opacity(0.85) : IslandPalette.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background {
                        if selected {
                            Capsule().fill(Color.white).matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(GadgetMotion.bouncy) { selection = option.value } }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .fixedSize()
    }
}
