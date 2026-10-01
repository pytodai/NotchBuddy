import SwiftUI

/// The island's button: squishes when pressed and springs back with a small bounce, catches a band of
/// light when the pointer arrives, and plays its icon's hover gesture.
///
/// ```swift
/// NBButton("Разрешить", icon: .done, kind: .primary) { … }
/// NBButton("Запретить", icon: .close, kind: .destructive) { … }
/// NBButton("Перейти", icon: .jump, kind: .accent(.working), size: .small) { … }
/// NBButton(icon: .settings, kind: .ghost) { … }            // icon-only, round
/// Button("…") { … }.buttonStyle(NBButtonStyle(kind: .secondary))
/// ```
struct NBButton: View {
    var title: String?
    var icon: NBIcon?
    var iconValue: Double?
    var kind: NBButtonStyle.Kind = .secondary
    var size: NBButtonStyle.Size = .regular
    var stretches = false
    let action: () -> Void

    init(_ title: String? = nil, icon: NBIcon? = nil, iconValue: Double? = nil,
         kind: NBButtonStyle.Kind = .secondary, size: NBButtonStyle.Size = .regular,
         stretches: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.iconValue = iconValue
        self.kind = kind
        self.size = size
        self.stretches = stretches
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: size.gap) {
                if let icon {
                    NBButtonIcon(icon: icon, value: iconValue, size: size.icon, kind: kind)
                }
                if let title {
                    Text(title)
                }
            }
        }
        .buttonStyle(NBButtonStyle(kind: kind, size: size, stretches: stretches, iconOnly: title == nil))
    }
}

/// Reads the button's label color from the environment so the icon matches the text.
private struct NBButtonIcon: View {
    let icon: NBIcon
    let value: Double?
    let size: CGFloat
    let kind: NBButtonStyle.Kind
    @Environment(\.nbButtonForeground) private var foreground

    var body: some View {
        NBIconView(icon, size: size, color: foreground, value: value)
    }
}

private struct NBButtonForegroundKey: EnvironmentKey { static let defaultValue: Color = NBColor.ink }

extension EnvironmentValues {
    var nbButtonForeground: Color {
        get { self[NBButtonForegroundKey.self] }
        set { self[NBButtonForegroundKey.self] = newValue }
    }
}

struct NBButtonStyle: ButtonStyle {
    enum Kind: Equatable {
        /// White, black label: the one main action.
        case primary
        /// Frosted: ordinary actions.
        case secondary
        /// Red tint: deny, remove.
        case destructive
        /// No fill until hovered: toolbar and header actions.
        case ghost
        /// Filled with an accent (status or brand), for a colored main action.
        case accent(NBAccent)
        /// Accent-tinted soft fill with an accent label.
        case tinted(NBAccent)
    }

    enum Size: CaseIterable {
        case small, regular, large

        var height: CGFloat {
            switch self {
            case .small: return 24
            case .regular: return 30
            case .large: return 38
            }
        }

        var icon: CGFloat {
            switch self {
            case .small: return 13
            case .regular: return 15
            case .large: return 18
            }
        }

        var gap: CGFloat { self == .large ? 7 : 5 }
        var padding: CGFloat {
            switch self {
            case .small: return 9
            case .regular: return 12
            case .large: return 16
            }
        }

        var text: Font {
            switch self {
            case .small: return .manrope(11.5, weight: 660)
            case .regular: return .manrope(12.5, weight: 680)
            case .large: return .manrope(14, weight: 700)
            }
        }
    }

    var kind: Kind = .secondary
    var size: Size = .regular
    var stretches = false
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        NBButtonBody(configuration: configuration, kind: kind, size: size, stretches: stretches, iconOnly: iconOnly)
    }
}

private struct NBButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: NBButtonStyle.Kind
    let size: NBButtonStyle.Size
    let stretches: Bool
    let iconOnly: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.nbForcedState) private var forced
    @State private var hoveringNow = false
    @State private var sheenCount = 0

    private var hovering: Bool { isEnabled && (forced?.hovered ?? hoveringNow) }
    private var pressed: Bool { isEnabled && (forced?.pressed ?? configuration.isPressed) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: iconOnly ? size.height / 2 : size.height * 0.34, style: .continuous)
        let colors = palette
        configuration.label
            .font(size.text)
            .lineLimit(1)
            .foregroundStyle(colors.foreground)
            .environment(\.nbButtonForeground, colors.foreground)
            .environment(\.nbControlHovered, hovering)
            .padding(.horizontal, iconOnly ? 0 : size.padding)
            .frame(width: iconOnly ? size.height : nil, height: size.height)
            .frame(maxWidth: stretches && !iconOnly ? .infinity : nil)
            .background {
                ZStack {
                    shape.fill(colors.fill)
                    // Top light: a raised, glassy edge.
                    shape.fill(LinearGradient(colors: [.white.opacity(colors.topLight), .white.opacity(0)],
                                              startPoint: .top, endPoint: .center))
                }
                // Under the label, so the band never washes the text out.
                .nbSheen(shape, trigger: sheenCount, forced: forced?.sheen, intensity: colors.sheen)
            }
            .overlay(shape.strokeBorder(colors.border, lineWidth: 0.75))
            .contentShape(shape)
            .shadow(color: colors.glow.opacity(hovering ? 0.55 : 0.0), radius: hovering ? 10 : 4)
            .scaleEffect(x: pressed ? 0.965 : 1, y: pressed ? 0.92 : 1)
            .offset(y: pressed ? 0.5 : 0)
            .brightness(pressed ? -0.05 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(NBMotion.animation(pressed ? NBMotion.press : NBMotion.release, reduced: reduceMotion), value: pressed)
            .animation(NBMotion.animation(NBMotion.hover, reduced: reduceMotion), value: hovering)
            .onHover { inside in
                hoveringNow = inside
                if inside && isEnabled { sheenCount += 1 }
            }
    }

    private struct Palette {
        var foreground: Color
        var fill: AnyShapeStyle
        var border: Color
        var topLight: Double
        var glow: Color
        var sheen: Double
    }

    private var palette: Palette {
        let h = hovering
        switch kind {
        case .primary:
            return Palette(foreground: NBColor.inkInverse,
                           fill: AnyShapeStyle(LinearGradient(colors: [.white, Color(white: h ? 0.9 : 0.86)],
                                                              startPoint: .top, endPoint: .bottom)),
                           border: .white.opacity(0.6), topLight: 0, glow: .white, sheen: 0.55)
        case .secondary:
            return Palette(foreground: NBColor.ink,
                           fill: AnyShapeStyle(Color.white.opacity(h ? 0.17 : 0.11)),
                           border: .white.opacity(h ? 0.16 : 0.09), topLight: 0.07, glow: .clear, sheen: 0.18)
        case .destructive:
            let red = NBAccent.error
            return Palette(foreground: red.bright,
                           fill: AnyShapeStyle(red.base.opacity(h ? 0.26 : 0.16)),
                           border: red.base.opacity(h ? 0.4 : 0.24), topLight: 0.04, glow: red.base, sheen: 0.2)
        case .ghost:
            return Palette(foreground: h ? NBColor.ink : NBColor.inkSecondary,
                           fill: AnyShapeStyle(Color.white.opacity(h ? 0.1 : 0)),
                           border: .clear, topLight: 0, glow: .clear, sheen: 0.12)
        case .accent(let a):
            return Palette(foreground: a.onAccent,
                           fill: AnyShapeStyle(LinearGradient(colors: [h ? a.bright : a.base, a.deep],
                                                              startPoint: .top, endPoint: .bottom)),
                           border: a.bright.opacity(0.5), topLight: 0.18, glow: a.base, sheen: 0.4)
        case .tinted(let a):
            return Palette(foreground: a.bright,
                           fill: AnyShapeStyle(a.base.opacity(h ? 0.26 : 0.16)),
                           border: a.base.opacity(h ? 0.42 : 0.26), topLight: 0.04, glow: a.base, sheen: 0.22)
        }
    }
}
