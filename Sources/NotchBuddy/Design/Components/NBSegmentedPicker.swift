import SwiftUI

/// Segmented control: a raised pill slides to the chosen segment (one shared geometry, so it travels
/// rather than cross-fades), squishes while pressed, and the chosen segment's icon plays its gesture.
///
/// ```swift
/// NBSegmentedPicker(selection: $mode, options: [
///     .init(.compact, "Компактно", icon: .tray),
///     .init(.full, "Подробно", icon: .read),
/// ])
/// ```
struct NBSegmentedPicker<Value: Hashable>: View {
    struct Option: Identifiable {
        var value: Value
        var title: String?
        var icon: NBIcon?
        var id: Value { value }

        init(_ value: Value, _ title: String? = nil, icon: NBIcon? = nil) {
            self.value = value
            self.title = title
            self.icon = icon
        }
    }

    @Binding var selection: Value
    let options: [Option]
    var accent: NBAccent?
    var height: CGFloat = 28

    @Namespace private var pill
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.nbForcedState) private var forced
    @State private var pressed: Value?
    @State private var hovered: Value?

    var body: some View {
        let outer = RoundedRectangle(cornerRadius: height * 0.36, style: .continuous)
        HStack(spacing: 2) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(2.5)
        .frame(height: height)
        .background(outer.fill(NBColor.well))
        .overlay(outer.strokeBorder(Color.white.opacity(0.07), lineWidth: 0.75))
        .animation(NBMotion.animation(NBMotion.pill, reduced: reduceMotion), value: selection)
        .animation(NBMotion.animation(NBMotion.press, reduced: reduceMotion), value: pressed)
        .animation(NBMotion.animation(NBMotion.hover, reduced: reduceMotion), value: hovered)
    }

    private func segment(_ option: Option) -> some View {
        let selected = option.value == selection
        let isPressed = pressed == option.value || (selected && forced?.pressed == true)
        let isHovered = hovered == option.value || (!selected && forced?.hovered == true && option.value == options.last?.value)
        let shape = RoundedRectangle(cornerRadius: (height - 5) * 0.34, style: .continuous)
        let foreground: Color = selected ? (accent == nil ? NBColor.ink : accent!.onAccent)
            : (isHovered ? NBColor.ink : NBColor.inkTertiary)
        return HStack(spacing: 5) {
            if let icon = option.icon {
                NBIconView(icon, size: 13, color: foreground, active: selected)
            }
            if let title = option.title {
                Text(title)
                    .font(.manrope(11.5, weight: selected ? 700 : 600))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, option.title == nil ? 8 : 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if selected {
                shape
                    .fill(accent.map { AnyShapeStyle($0.fill) } ?? AnyShapeStyle(LinearGradient(
                        colors: [Color.white.opacity(0.2), Color.white.opacity(0.13)], startPoint: .top, endPoint: .bottom)))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .shadow(color: (accent?.base ?? .clear).opacity(0.4), radius: 6)
                    .matchedGeometryEffect(id: "pill", in: pill)
            } else if isHovered {
                shape.fill(Color.white.opacity(0.06))
            }
        }
        .scaleEffect(isPressed ? 0.94 : 1)
        .contentShape(shape)
        .onHover { inside in
            if inside { hovered = option.value } else if hovered == option.value { hovered = nil }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if pressed != option.value { pressed = option.value } }
                .onEnded { _ in
                    pressed = nil
                    selection = option.value
                }
        )
        .accessibilityElement()
        .accessibilityLabel(option.title ?? option.icon?.title ?? "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
