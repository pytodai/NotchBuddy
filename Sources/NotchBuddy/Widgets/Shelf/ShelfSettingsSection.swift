import NotchBuddyCore
import SwiftUI

/// The shelf's block in the island's ⚙️ settings: on/off, open on drag, badge, and which files it copies.
/// Self-contained (its own switch and segmented control, drawn for the black island).
struct ShelfSettingsSection: View {
    @Bindable var settings: ShelfSettings
    var width: CGFloat = 440
    /// Its own on/off switch (off where Settings → Островки already switches the shelf on and off).
    var showsEnableSwitch = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ShelfTrayGlyph(size: 16)
                Text(L("Полка"))
                    .font(ShelfTypography.font(13, 680))
                    .foregroundStyle(ShelfPalette.primary)
                Spacer()
                if showsEnableSwitch { ShelfSwitch(isOn: $settings.enabled) }
            }
            .padding(.bottom, 4)
            Text(L("Перетащи файл к острову — он подождёт на полке, пока не понадобится."))
                .font(ShelfTypography.font(11, 500))
                .foregroundStyle(ShelfPalette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            VStack(spacing: 0) {
                row(L("Открывать полку, когда тащишь файл"), isOn: $settings.opensOnDrag)
                divider
                row(L("Показывать число файлов на острове"), isOn: $settings.showsBadge)
                divider
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Копировать файлы на полку"))
                        .font(ShelfTypography.font(12, 600))
                        .foregroundStyle(ShelfPalette.primary)
                    ShelfSegmented(selection: $settings.copyPolicy)
                    Text(settings.copyPolicy.explanation)
                        .font(ShelfTypography.font(10.5, 500))
                        .foregroundStyle(ShelfPalette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(settings.copyPolicy)
                        .transition(.opacity.combined(with: .offset(y: 3)))
                }
                .padding(.vertical, 10)
                .animation(ShelfMotion.hover.animation, value: settings.copyPolicy)
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ShelfPalette.hairline, lineWidth: 0.6))
            .opacity(settings.enabled ? 1 : 0.4)
            .allowsHitTesting(settings.enabled)
            .animation(ShelfMotion.hover.animation, value: settings.enabled)
        }
        .frame(maxWidth: width, alignment: .leading)
    }

    private func row(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(ShelfTypography.font(12, 560))
                .foregroundStyle(ShelfPalette.primary)
            Spacer(minLength: 8)
            ShelfSwitch(isOn: isOn, small: true)
        }
        .frame(height: 38)
    }

    private var divider: some View {
        Rectangle().fill(ShelfPalette.hairline).frame(height: 0.6)
    }
}

/// An island-styled switch: the knob slides with a spring and stretches while it moves.
struct ShelfSwitch: View {
    @Binding var isOn: Bool
    var small = false
    @State private var pressing = false

    var body: some View {
        let w: CGFloat = small ? 32 : 36, h: CGFloat = small ? 19 : 21
        let knob = h - 4
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? ShelfPalette.switchOn : Color.white.opacity(0.16))
                Capsule()
                    .fill(Color.white)
                    .frame(width: knob + (pressing ? 5 : 0), height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .padding(2)
            }
            .frame(width: w, height: h)
            .contentShape(Capsule())
        }
        .buttonStyle(SwitchPressStyle(pressing: $pressing))
        .animation(.spring(response: 0.3, dampingFraction: 0.72).speed(IslandMotion.speed), value: isOn)
        .animation(ShelfMotion.press.animation, value: pressing)
        .accessibilityValue(isOn ? L("Вкл.") : L("Выкл."))
    }
}

private struct SwitchPressStyle: ButtonStyle {
    @Binding var pressing: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in pressing = pressed }
    }
}

/// Three segments with a highlight that slides between them.
struct ShelfSegmented: View {
    @Binding var selection: ShelfCopyPolicy
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ShelfCopyPolicy.allCases, id: \.self) { policy in
                let selected = policy == selection
                Button {
                    selection = policy
                } label: {
                    Text(policy.title)
                        .font(ShelfTypography.font(11.5, selected ? 680 : 560))
                        .foregroundStyle(selected ? Color.black.opacity(0.85) : ShelfPalette.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color.white.opacity(0.92))
                                    .matchedGeometryEffect(id: "highlight", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(ShelfPressStyle())
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .animation(.spring(response: 0.34, dampingFraction: 0.78).speed(IslandMotion.speed), value: selection)
    }
}
