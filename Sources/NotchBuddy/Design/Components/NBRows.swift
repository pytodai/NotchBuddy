import SwiftUI

/// Uppercase section label with an optional trailing accessory ("ЗВУК", "ВИДЖЕТЫ").
struct NBSectionHeader<Accessory: View>: View {
    var title: String
    @ViewBuilder var accessory: () -> Accessory

    init(_ title: String, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .nbText(.eyebrow)
                .foregroundStyle(NBColor.inkTertiary)
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 4)
    }
}

extension NBSectionHeader where Accessory == EmptyView {
    init(_ title: String) {
        self.title = title
        accessory = { EmptyView() }
    }
}

/// One settings line: icon tile, title and hint, trailing control. Group rows in `NBGroup`.
///
/// ```swift
/// NBGroup {
///     NBSettingsRow(icon: .soundOn, accent: .done, title: "Звуки", subtitle: "Готово и «ждёт тебя»") {
///         NBSwitch(isOn: $sounds)
///     }
/// }
/// ```
struct NBSettingsRow<Trailing: View>: View {
    var icon: NBIcon?
    var accent: NBAccent = .brand
    var iconValue: Double?
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.nbForcedState) private var forced
    @State private var hoveringNow = false

    init(icon: NBIcon? = nil, accent: NBAccent = .brand, iconValue: Double? = nil, title: String,
         subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.icon = icon
        self.accent = accent
        self.iconValue = iconValue
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        let hovering = forced?.hovered ?? hoveringNow
        HStack(spacing: 10) {
            if let icon {
                NBIconTile(icon: icon, accent: accent, size: 26, value: iconValue, active: hovering)
            }
            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .nbText(.bodyStrong)
                    .foregroundStyle(NBColor.ink)
                if let subtitle {
                    Text(subtitle)
                        .nbText(.caption)
                        .foregroundStyle(NBColor.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: NBRadius.control, style: .continuous)
            .fill(Color.white.opacity(hovering ? 0.045 : 0)))
        .contentShape(Rectangle())
        .onHover { hoveringNow = $0 }
        .animation(NBMotion.hover.animation, value: hovering)
    }
}

/// A raised group of rows; put `NBRowDivider()` between rows.
struct NBGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(3)
        .nbSurface(.raised, radius: NBRadius.card)
    }
}

/// Hairline between rows of an `NBGroup` (inset past the icon tile).
struct NBRowDivider: View {
    var inset: CGFloat = 46

    var body: some View {
        Rectangle()
            .fill(NBColor.hairline)
            .frame(height: 0.5)
            .padding(.leading, inset)
            .padding(.trailing, 10)
    }
}
