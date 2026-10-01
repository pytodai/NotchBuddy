import SwiftUI
import NotchBuddyCore

// Custom controls of the settings page. None of them needs the keyboard (the island never takes it): every
// control is a click or a drag, so they all work in the island's non-activating panel.

// MARK: - Toggle

/// A switch, as on macOS: a flat accent track and a white knob that slides on a spring and squashes while pressed.
struct SettingsToggle: View {
    @Binding var isOn: Bool
    var enabled = true

    @Environment(\.settingsAccent) private var accent
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var pressed = false
    @State private var hovering = false

    static let width: CGFloat = 38
    static let height: CGFloat = 22

    var body: some View {
        let knob: CGFloat = Self.height - 4
        let squash = pressed && !reduceMotion ? 5 : 0 as CGFloat
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(Color.white.opacity(hovering && enabled ? 0.2 : 0.15))
            Capsule()
                .fill(accent.color)
                .opacity(isOn ? 1 : 0)
            Capsule()
                .fill(Color.white)
                .frame(width: knob + squash, height: knob)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                .padding(2)
        }
        .frame(width: Self.width, height: Self.height)
        .animation(SettingsMotion.control(reduce: reduceMotion), value: isOn)
        .animation(SettingsMotion.press, value: pressed)
        .animation(SettingsMotion.hover, value: hovering)
        .animation(IslandMotion.tint, value: accent)
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if enabled, !pressed { pressed = true } }
                .onEnded { value in
                    pressed = false
                    guard enabled, abs(value.translation.width) < 30, abs(value.translation.height) < 20 else { return }
                    flip()
                }
        )
        .onHover { hovering = $0 }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? L("Вкл") : L("Выкл"))
    }

    private func flip() {
        isOn.toggle()
    }
}

// MARK: - Segmented

/// Choices in a capsule well; the selected pill (a lighter gray, as in macOS's dark segmented control) slides
/// between them.
struct SettingsSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    /// A small picture above a label (the island sizes).
    var picture: ((Value, Bool) -> AnyView)?
    var enabled = true

    @Environment(\.islandReduceMotion) private var reduceMotion
    @Namespace private var namespace

    var body: some View {
        let tall = picture != nil
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    guard option != selection else { return }
                    withAnimation(SettingsMotion.control(reduce: reduceMotion)) { selection = option }
                } label: {
                    VStack(spacing: 4) {
                        if let picture { picture(option, selected) }
                        Text(label(option))
                            .settingsFont(11.5, selected ? .bold : .semibold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(selected ? Color.white : IslandPalette.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: tall ? 50 : 26)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: tall ? 11 : 13, style: .continuous)
                                .fill(SettingsPalette.selection)
                                .overlay(RoundedRectangle(cornerRadius: tall ? 11 : 13, style: .continuous)
                                    .strokeBorder(SettingsPalette.selectionStroke, lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "pill", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.95))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: tall ? 13 : 15, style: .continuous).fill(SettingsPalette.well))
        .opacity(enabled ? 1 : 0.4)
        .allowsHitTesting(enabled)
    }
}

// MARK: - Slider

/// A volume slider as in Control Center: a white fill on a gray track that thickens under the pointer; the knob
/// grows while dragged.
struct SettingsSlider: View {
    @Binding var value: Double
    var enabled = true
    var onRelease: (() -> Void)?

    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let knob: CGFloat = dragging ? 18 : 15
            let track: CGFloat = dragging || hovering ? 7 : 5
            let usable = max(1, geo.size.width - knob)
            let x = usable * CGFloat(min(max(value, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14)).frame(height: track)
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: x + knob / 2, height: track)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .offset(x: x)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard enabled else { return }
                        if !dragging { dragging = true }
                        let raw = Double((g.location.x - knob / 2) / usable)
                        value = (min(max(raw, 0), 1) * 100).rounded() / 100
                    }
                    .onEnded { _ in
                        dragging = false
                        if enabled { onRelease?() }
                    }
            )
        }
        .frame(height: 22)
        .animation(SettingsMotion.press, value: dragging)
        .animation(SettingsMotion.hover, value: hovering)
        .onHover { hovering = $0 }
        .opacity(enabled ? 1 : 0.4)
    }
}

// MARK: - Buttons

/// Scales down while pressed.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(SettingsMotion.press, value: configuration.isPressed)
    }
}

/// Small capsule buttons of the page.
struct SettingsButtonStyle: ButtonStyle {
    enum Kind { case accent, neutral, danger, dangerFilled, ghost }
    var kind: Kind = .neutral
    var height: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        SettingsButtonBody(configuration: configuration, kind: kind, height: height)
    }
}

private struct SettingsButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: SettingsButtonStyle.Kind
    let height: CGFloat
    @Environment(\.settingsAccent) private var accent
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .settingsFont(11.5, .bold)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .frame(height: height)
            .background(Capsule().fill(background))
            .overlay(Capsule().strokeBorder(border, lineWidth: 0.5))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(SettingsMotion.press, value: configuration.isPressed)
            .animation(SettingsMotion.hover, value: hovering)
            .animation(SettingsMotion.control(reduce: false), value: kind)
            .onHover { hovering = $0 && isEnabled }
    }

    private var foreground: Color {
        switch kind {
        case .accent: return accent.onColor
        case .neutral: return .white
        case .danger: return SettingsPalette.danger
        case .dangerFilled: return .white
        case .ghost: return hovering ? .white : IslandPalette.secondary
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .accent: return AnyShapeStyle(accent.color.opacity(hovering ? 1 : 0.9))
        case .neutral: return AnyShapeStyle(Color.white.opacity(hovering ? 0.18 : 0.11))
        case .danger: return AnyShapeStyle(SettingsPalette.danger.opacity(hovering ? 0.24 : 0.14))
        case .dangerFilled: return AnyShapeStyle(SettingsPalette.danger.opacity(hovering ? 1 : 0.9))
        case .ghost: return AnyShapeStyle(Color.white.opacity(hovering ? 0.1 : 0))
        }
    }

    private var border: Color {
        switch kind {
        case .accent, .dangerFilled: return .clear
        case .neutral: return .white.opacity(0.08)
        case .danger: return SettingsPalette.danger.opacity(0.22)
        case .ghost: return .clear
        }
    }
}

/// A destructive action that asks once: the first click turns the button red ("Точно?"), a second click within
/// three seconds does it.
struct ConfirmButton: View {
    let title: String
    var confirmTitle = L("Точно?")
    var symbol: String?
    let action: () -> Void

    @State private var armed = false
    @State private var disarm: Task<Void, Never>?
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            if armed {
                disarm?.cancel()
                armed = false
                action()
            } else {
                withAnimation(SettingsMotion.control(reduce: reduceMotion)) { armed = true }
                disarm = Task {
                    try? await Task.sleep(for: IslandMotion.delay(3))
                    guard !Task.isCancelled else { return }
                    withAnimation(SettingsMotion.control(reduce: reduceMotion)) { armed = false }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: armed ? "exclamationmark.triangle.fill" : symbol)
                        .font(.system(size: 10, weight: .bold))
                        .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                }
                Text(armed ? confirmTitle : title)
                    .contentTransition(.interpolate)
            }
        }
        .buttonStyle(SettingsButtonStyle(kind: armed ? .dangerFilled : .danger))
        .onDisappear { disarm?.cancel() }
    }
}

// MARK: - Small pieces

/// A spinning arc (busy). Static in renders.
struct BusySpinner: View {
    var size: CGFloat = 12
    var color: Color = .white
    @Environment(\.islandStaticRender) private var staticRender
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.8)
            .stroke(color, style: StrokeStyle(lineWidth: size * 0.16, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(staticRender ? nil : .linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
            .onAppear { if !staticRender { spinning = true } }
    }
}

/// "скоро": a small, quiet gray capsule.
struct SoonBadge: View {
    var text = L("скоро")

    var body: some View {
        Text(text)
            .settingsFont(9.5, .bold)
            .textCase(.uppercase)
            .kerning(0.4)
            .foregroundStyle(Color.white.opacity(0.55))
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

/// A key as drawn on a keyboard: a flat gray top over a darker lip. `lit` (the combo is on) makes the top a
/// little lighter.
struct Keycap: View {
    let text: String
    var size: CGFloat = 26
    var lit = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Text(text)
            .settingsFont(text.count > 1 ? size * 0.4 : size * 0.5, .bold)
            .foregroundStyle(Color.white.opacity(lit ? 1 : 0.8))
            .padding(.horizontal, text.count > 1 ? size * 0.3 : 0)
            .frame(minWidth: size)
            .frame(height: size)
            .background {
                ZStack {
                    // The key's side, seen below its top.
                    shape.fill(Color.black.opacity(0.55)).offset(y: 1.5)
                    shape.fill(Color(white: lit ? 0.27 : 0.2))
                }
            }
            .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
    }
}

/// A status dot; `pulsing` rings it softly.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7
    var pulsing = false
    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var ring = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                if pulsing, !staticRender, !reduceMotion {
                    Circle()
                        .stroke(color.opacity(ring ? 0 : 0.6), lineWidth: 1.2)
                        .frame(width: size, height: size)
                        .scaleEffect(ring ? 2.6 : 1)
                        .onAppear {
                            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false).speed(IslandMotion.speed)) { ring = true }
                        }
                }
            }
    }
}

/// Lays chips out in lines, wrapping at the proposed width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for (index, x) in zip(row.indices, row.xs) {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y),
                                      anchor: .topLeading, proposal: .unspecified)
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var xs: [CGFloat] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + lineSpacing)
            }
            let x = row.indices.isEmpty ? 0 : row.width + spacing
            row.indices.append(index)
            row.xs.append(x)
            row.width = x + size.width
            row.height = max(row.height, size.height)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - Rows

/// Title (and an optional hint under it) on the left, a control on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var hint: String?
    var enabled = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .settingsFont(12.5, .semibold)
                    .foregroundStyle(Color.white.opacity(0.92))
                if let hint {
                    Text(hint)
                        .settingsFont(11, .medium)
                        .foregroundStyle(IslandPalette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .opacity(enabled ? 1 : 0.45)
    }
}

/// A row whose whole width flips the switch.
struct SettingsToggleRow: View {
    let title: String
    var hint: String?
    @Binding var isOn: Bool
    var enabled = true
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        SettingsRow(title: title, hint: hint, enabled: enabled) {
            SettingsToggle(isOn: $isOn, enabled: enabled)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard enabled else { return }
            withAnimation(SettingsMotion.control(reduce: reduceMotion)) { isOn.toggle() }
        }
    }
}

/// A caption above a control that takes the full width.
struct SettingsCaption: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(text)
                .settingsFont(12.5, .semibold)
                .foregroundStyle(Color.white.opacity(0.92))
            Spacer()
            if let trailing {
                Text(trailing)
                    .settingsFont(11.5, .semibold)
                    .monospacedDigit()
                    .foregroundStyle(IslandPalette.secondary)
                    .contentTransition(.numericText())
            }
        }
    }
}

/// A one-line note with a glyph (info, warning, success).
struct SettingsNote: View {
    enum Tone { case info, success, warning, error }
    let text: String
    var tone: Tone = .info
    var symbol: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol ?? defaultSymbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .settingsFont(11, .medium)
                .foregroundStyle(tone == .info || tone == .success ? IslandPalette.secondary : tint.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    private var tint: Color {
        switch tone {
        case .info: return Color.white.opacity(0.7)
        case .success: return SettingsPalette.success
        case .warning: return SettingsPalette.warning
        case .error: return SettingsPalette.danger
        }
    }

    private var defaultSymbol: String {
        switch tone {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

/// Hairline between rows inside a section.
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(SettingsPalette.separator).frame(height: 0.5)
    }
}
