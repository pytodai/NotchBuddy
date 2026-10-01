import AppKit
import CoreText
import SwiftUI
import NotchBuddyCore

// MARK: - Typography

/// Manrope for the settings page: the design system's one loader (`NBTypography`), falling back to the system font
/// when the file cannot be found (a bundle built without `Resources/Fonts`).
@MainActor
enum SettingsFont {
    enum Weight: String {
        case regular = "Regular", medium = "Medium", semibold = "SemiBold", bold = "Bold", extraBold = "ExtraBold"

        /// On Manrope's weight axis.
        var axis: CGFloat {
            switch self {
            case .regular: return NBWeight.regular
            case .medium: return NBWeight.medium
            case .semibold: return NBWeight.semibold
            case .bold: return NBWeight.bold
            case .extraBold: return NBWeight.heavy
            }
        }
    }

    static func font(_ size: CGFloat, _ weight: Weight = .medium) -> Font {
        NBTypography.font(size: size, weight: weight.axis)
    }

    /// True when Manrope is available.
    @discardableResult
    static func registerIfNeeded() -> Bool { NBTypography.registerBundledFonts() }
}

extension View {
    /// Manrope at `size` / `weight`.
    @MainActor
    func settingsFont(_ size: CGFloat, _ weight: SettingsFont.Weight = .medium) -> some View {
        font(SettingsFont.font(size, weight))
    }
}

// MARK: - Colors

/// Flat, neutral surfaces on the island's black (no gradients, no colored glows). Color comes only from the accent
/// on a few controls and from tiny status marks.
enum SettingsPalette {
    static let card = Color.white.opacity(0.055)
    static let cardHover = Color.white.opacity(0.08)
    static let cardOpen = Color.white.opacity(0.075)
    static let cardStroke = Color.white.opacity(0.06)
    static let well = Color.white.opacity(0.07)
    /// A selected segment / chip: a lighter gray, like macOS's dark segmented control.
    static let selection = Color.white.opacity(0.17)
    static let selectionStroke = Color.white.opacity(0.1)
    static let separator = Color.white.opacity(0.07)
    static let success = SessionStatus.finished.tint
    static let warning = SessionStatus.waitingForUser.tint
    static let danger = IslandPalette.danger
}

extension AccentChoice {
    /// The accent as drawn: macOS's own accent tones, a notch calmer than the stored components.
    var color: Color {
        switch self {
        case .azure: return Color(red: 0.2, green: 0.5, blue: 0.95)
        case .coral: return Color(red: 0.9, green: 0.42, blue: 0.34)
        case .amber: return Color(red: 0.93, green: 0.66, blue: 0.2)
        case .lime: return Color(red: 0.42, green: 0.72, blue: 0.3)
        case .mint: return Color(red: 0.3, green: 0.7, blue: 0.64)
        case .graphite: return Color(red: 0.62, green: 0.63, blue: 0.66)
        }
    }

    /// Text and glyphs on a fill of this accent.
    var onColor: Color {
        switch self {
        case .amber, .lime, .mint, .graphite: return .black
        default: return .white
        }
    }
}

private struct SettingsAccentKey: EnvironmentKey { static let defaultValue = AccentChoice.azure }

extension EnvironmentValues {
    /// The accent of the settings page's controls (follows `NotchSettings.accent`).
    var settingsAccent: AccentChoice {
        get { self[SettingsAccentKey.self] }
        set { self[SettingsAccentKey.self] = newValue }
    }
}

// MARK: - Motion

enum SettingsMotion {
    /// A section opening or closing (the island's own morph spring).
    static func expand(reduce: Bool) -> Animation {
        reduce ? IslandMotion.reduced.animation : .spring(response: 0.42, dampingFraction: 0.86).speed(IslandMotion.speed)
    }
    /// A control changing state (toggle knob, segment pill).
    static func control(reduce: Bool) -> Animation {
        reduce ? .easeInOut(duration: 0.16).speed(IslandMotion.speed) : .spring(response: 0.32, dampingFraction: 0.72).speed(IslandMotion.speed)
    }
    static var hover: Animation { .easeOut(duration: 0.14).speed(IslandMotion.speed) }
    static var press: Animation { .spring(response: 0.22, dampingFraction: 0.7).speed(IslandMotion.speed) }
}
