import SwiftUI
import NotchBuddyCore

/// The settings page's sections, in page order.
enum SettingsSection: String, CaseIterable, Identifiable {
    case island, sounds, agents, usage, hotkey, widgets, appearance, language, launch, privacy, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .island: return L("Остров")
        case .sounds: return L("Звуки")
        case .agents: return L("Агенты и хуки")
        case .usage: return L("Лимиты")
        case .hotkey: return L("Горячая клавиша")
        case .widgets: return L("Островки")
        case .appearance: return L("Оформление")
        // Both names, whatever the language: whoever cannot read the current one still finds it.
        case .language: return L("Язык · Language")
        case .launch: return L("Запуск при входе")
        case .privacy: return L("Приватность и логи")
        case .about: return L("О NotchBuddy")
        }
    }

    /// Launch at login is a switch right in its header; it has nothing to expand.
    var expandable: Bool { self != .launch }

    /// The icon tile's flat fill: muted system tones, like the sidebar of macOS System Settings.
    var tileColor: Color {
        switch self {
        case .island: return Color(red: 0.2, green: 0.46, blue: 0.86)
        case .sounds: return Color(red: 0.84, green: 0.29, blue: 0.33)
        case .agents: return Color(red: 0.3, green: 0.4, blue: 0.7)
        case .usage: return Color(red: 0.17, green: 0.56, blue: 0.56)
        case .hotkey: return Color(white: 0.42)
        case .widgets: return Color(red: 0.86, green: 0.54, blue: 0.18)
        case .appearance: return Color(white: 0.24)
        case .language: return Color(red: 0.23, green: 0.5, blue: 0.62)
        case .launch: return Color(red: 0.24, green: 0.6, blue: 0.33)
        case .privacy: return Color(red: 0.36, green: 0.43, blue: 0.54)
        case .about: return Color(white: 0.34)
        }
    }

    var symbol: String? {
        switch self {
        case .island: return nil  // drawn: `IslandGlyph`
        case .sounds: return "speaker.wave.2.fill"
        case .agents: return "point.3.filled.connected.trianglepath.dotted"
        case .usage: return "gauge.with.dots.needle.67percent"
        case .hotkey: return "command"
        case .widgets: return "square.grid.2x2.fill"
        case .appearance: return "paintpalette.fill"
        case .language: return "globe"
        case .launch: return "power"
        case .privacy: return "lock.shield.fill"
        case .about: return "sparkles"
        }
    }
}

/// A section's icon: a flat rounded tile in the section's muted color with a white glyph, as in macOS System
/// Settings (no sheen, no glow). `lit` (the section is open) is shown by the card itself; `bounce` plays the
/// glyph's bounce.
struct SettingsIconTile: View {
    let section: SettingsSection
    var size: CGFloat = 28
    var lit = false
    var bounce = 0

    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        glyph
            .frame(width: size, height: size)
            .background(shape.fill(section.tileColor))
            // A hairline so the darker tiles still read as tiles on the black island.
            .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    @ViewBuilder
    private var glyph: some View {
        if let symbol = section.symbol {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, options: .speed(1.2), value: reduceMotion ? 0 : bounce)
        } else {
            IslandGlyph(bounce: reduceMotion ? 0 : bounce)
                .frame(width: size * 0.66, height: size * 0.5)
        }
    }
}

/// The island section's own icon: a screen with the island hanging from its top edge (ears and all). On `bounce`
/// the island drops open and springs back, like the real one.
struct IslandGlyph: View {
    var bounce = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let screen = RoundedRectangle(cornerRadius: h * 0.2, style: .continuous)
            ZStack(alignment: .top) {
                screen.strokeBorder(.white.opacity(0.95), lineWidth: max(1.2, h * 0.1))
                // The island, flush with the screen's top edge.
                IslandShape(earRadius: h * 0.12, bottomRadius: h * 0.2)
                    .fill(.white)
                    .keyframeAnimator(initialValue: CGFloat(1), trigger: bounce) { content, grow in
                        content.frame(width: w * 0.58 * (0.8 + 0.2 * grow), height: h * 0.44 * grow)
                    } keyframes: { _ in
                        KeyframeTrack {
                            SpringKeyframe(1.7, duration: IslandMotion.t(0.18), spring: IslandMotion.kspring(0.22, 0.7))
                            SpringKeyframe(1, duration: IslandMotion.t(0.35), spring: IslandMotion.kspring(0.3, 0.6))
                        }
                    }
            }
            .frame(width: w, height: h)
        }
    }
}
