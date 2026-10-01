import SwiftUI

/// Chip: a status or filter label in a capsule. Pops in, counts roll (numeric content transition),
/// hover lifts the tint, an optional × removes.
///
/// ```swift
/// NBChip("работает", icon: .working, accent: .working, count: 2)
/// NBChip("Claude", accent: .claude, selected: true)
/// NBChip("Bash", style: .outline)
/// ```
struct NBChip: View {
    enum Style { case tinted, filled, outline, neutral }

    var title: String
    var icon: NBIcon?
    var accent: NBAccent = .neutral
    var style: Style = .tinted
    var count: Int?
    /// Status dot before the title (a small glowing dot).
    var dot = false
    var selected = false
    var loops = false
    var onRemove: (() -> Void)?

    init(_ title: String, icon: NBIcon? = nil, accent: NBAccent = .neutral, style: Style = .tinted,
         count: Int? = nil, dot: Bool = false, selected: Bool = false, loops: Bool = false,
         onRemove: (() -> Void)? = nil) {
        self.title = title
        self.icon = icon
        self.accent = accent
        self.style = style
        self.count = count
        self.dot = dot
        self.selected = selected
        self.loops = loops
        self.onRemove = onRemove
    }

    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.nbForcedState) private var forced
    @State private var hoveringNow = false

    private var hovering: Bool { forced?.hovered ?? hoveringNow }

    var body: some View {
        let shape = Capsule(style: .continuous)
        let colors = palette
        HStack(spacing: 4.5) {
            if dot {
                Circle().fill(accent.base)
                    .frame(width: 6, height: 6)
                    .shadow(color: accent.base.opacity(0.8), radius: 3)
            }
            if let icon {
                NBIconView(icon, size: 12, color: colors.icon, active: hovering, loops: loops)
            }
            Text(title)
                .font(.manrope(11, weight: 660))
                .tracking(0.05)
                .lineLimit(1)
            if let count {
                Text("\(count)")
                    .font(.nbNumeric(10.5, weight: 760))
                    .contentTransition(.numericText(value: Double(count)))
                    .padding(.horizontal, 4.5)
                    .frame(minWidth: 16, minHeight: 15)
                    .background(Capsule().fill(colors.countFill))
            }
            if let onRemove {
                Button(action: onRemove) {
                    NBIconView(.close, size: 10, color: colors.foreground.opacity(0.8), active: hovering)
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(colors.foreground)
        .padding(.leading, dot || icon != nil ? 7 : 9)
        .padding(.trailing, count != nil ? 3.5 : (onRemove != nil ? 6 : 9))
        .frame(height: 22)
        .background(shape.fill(colors.fill))
        .overlay(shape.strokeBorder(colors.border, lineWidth: 0.75))
        .scaleEffect(hovering ? 1.03 : 1)
        .animation(NBMotion.animation(NBMotion.hover, reduced: reduceMotion), value: hovering)
        .animation(NBMotion.animation(NBMotion.pop, reduced: reduceMotion), value: count)
        .animation(NBMotion.animation(NBMotion.pill, reduced: reduceMotion), value: selected)
        .onHover { hoveringNow = $0 }
        .transition(.nbPop)
    }

    private struct Palette {
        var foreground: Color
        var icon: Color
        var fill: AnyShapeStyle
        var border: Color
        var countFill: Color
    }

    private var palette: Palette {
        let h = hovering
        switch style {
        case .tinted:
            return Palette(foreground: accent.bright, icon: accent.base,
                           fill: AnyShapeStyle(accent.base.opacity(selected ? 0.3 : (h ? 0.24 : 0.15))),
                           border: accent.base.opacity(selected ? 0.55 : 0.22), countFill: accent.base.opacity(0.28))
        case .filled:
            return Palette(foreground: accent.onAccent, icon: accent.onAccent,
                           fill: AnyShapeStyle(accent.fill), border: accent.bright.opacity(0.4),
                           countFill: accent.onAccent.opacity(0.16))
        case .outline:
            return Palette(foreground: h ? NBColor.ink : NBColor.inkSecondary, icon: NBColor.inkSecondary,
                           fill: AnyShapeStyle(Color.white.opacity(h ? 0.06 : 0)),
                           border: Color.white.opacity(h ? 0.3 : 0.18), countFill: Color.white.opacity(0.12))
        case .neutral:
            return Palette(foreground: NBColor.ink, icon: NBColor.inkSecondary,
                           fill: AnyShapeStyle(Color.white.opacity(selected ? 0.2 : (h ? 0.14 : 0.09))),
                           border: Color.white.opacity(0.08), countFill: Color.white.opacity(0.14))
        }
    }
}

extension AnyTransition {
    /// Pops in from 60 % with a bouncy spring, fades out quickly.
    static var nbPop: AnyTransition {
        .asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity).animation(NBMotion.pop.animation),
                    removal: .scale(scale: 0.85).combined(with: .opacity).animation(NBMotion.fade.animation))
    }
}

/// A small count badge (unread, queue size) that pops when the number changes.
struct NBBadge: View {
    var count: Int
    var accent: NBAccent = .error

    var body: some View {
        Text("\(count)")
            .font(.nbNumeric(10, weight: 780))
            .foregroundStyle(accent.onAccent)
            .contentTransition(.numericText(value: Double(count)))
            .padding(.horizontal, 4.5)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(accent.fill))
            .overlay(Capsule().strokeBorder(Color.black, lineWidth: 1.5).padding(-1.5))
            .shadow(color: accent.base.opacity(0.6), radius: 4)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: count) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                CubicKeyframe(1.28, duration: 0.1 * IslandMotion.slowmo)
                SpringKeyframe(1, duration: 0.4 * IslandMotion.slowmo, spring: Spring(response: 0.3, dampingRatio: 0.5))
            }
    }
}

/// A keyboard shortcut cap ("⌘Y").
struct NBKeycap: View {
    var text: String
    var highlighted = false

    var body: some View {
        Text(text)
            .font(.manrope(10, weight: 700))
            .foregroundStyle(highlighted ? NBColor.inkInverse : NBColor.inkSecondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 17)
            .background {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(highlighted ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.1)))
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .fill(Color.black.opacity(0.25))
                            .frame(height: 1.5)
                            .offset(y: 0)
                            .mask(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                    }
            }
            .overlay(RoundedRectangle(cornerRadius: 4.5, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}
