import AppKit
import SwiftUI
import NotchBuddyCore

// MARK: - Palette

/// Color tokens for the island. The island is always black, so these are fixed values (they do not
/// follow the system appearance). Ink levels are white at an opacity chosen for contrast on black
/// and on `surface1`; accents are tuned to glow on black without buzzing.
enum NBColor {
    // Surfaces, from the island itself up.
    /// The island body.
    static let island = Color.black
    /// Recessed wells (code blocks, tracks).
    static let well = Color.white.opacity(0.045)
    /// Cards and grouped rows.
    static let surface1 = Color.white.opacity(0.065)
    /// Controls at rest, hovered cards.
    static let surface2 = Color.white.opacity(0.10)
    /// Hovered controls, selected pills.
    static let surface3 = Color.white.opacity(0.15)
    /// Pressed controls.
    static let surface4 = Color.white.opacity(0.20)

    // Ink.
    static let ink = Color.white.opacity(0.96)
    /// Second line of a card: ≥ 7:1 on black.
    static let inkSecondary = Color.white.opacity(0.66)
    /// Meta text (times, hints): ≥ 4.5:1 on black and on `surface1`.
    static let inkTertiary = Color.white.opacity(0.50)
    /// Disabled labels, decorative marks only.
    static let inkQuaternary = Color.white.opacity(0.30)
    /// Text on a white (primary) control.
    static let inkInverse = Color(white: 0.04)

    // Lines.
    static let hairline = Color.white.opacity(0.08)
    static let stroke = Color.white.opacity(0.12)
    static let strokeStrong = Color.white.opacity(0.22)
    /// The top edge highlight of raised surfaces.
    static let sheen = Color.white.opacity(0.16)

    /// Opacity pairs used to judge contrast in the design lint (ink over `island` / `surface1`).
    static let inkLevels: [(name: String, opacity: Double, minimumContrast: Double)] = [
        ("ink", 0.96, 7),
        ("inkSecondary", 0.66, 7),
        ("inkTertiary", 0.50, 4.5),
        ("inkQuaternary", 0.30, 1.5),
    ]
}

// MARK: - Accents

/// One accent in every strength the components need.
struct NBAccent: Equatable, Identifiable {
    var id: String
    /// Russian name for the sheet.
    var name: String
    /// The accent itself (icons, dots, fills).
    var base: Color
    /// Lighter tone for text on black (≥ 4.5:1).
    var bright: Color
    /// Darker end of gradients.
    var deep: Color
    /// Label color on a filled accent control.
    var onAccent: Color

    /// Tinted background of chips, pills and toasts.
    var soft: Color { base.opacity(0.16) }
    /// Hovered tinted background.
    var softHover: Color { base.opacity(0.24) }
    /// Border of tinted surfaces.
    var edge: Color { base.opacity(0.32) }
    /// Glow color (use with `nbGlow`).
    var glow: Color { base.opacity(0.55) }

    /// Filled accent (switch tracks, primary tinted buttons, bar fills).
    var fill: LinearGradient {
        LinearGradient(colors: [bright, base, deep], startPoint: .top, endPoint: .bottom)
    }

    /// Horizontal fill for progress bars (dark at the start, bright at the head).
    var sweep: LinearGradient {
        LinearGradient(colors: [deep, base, bright], startPoint: .leading, endPoint: .trailing)
    }

    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

    // Status accents (the same hues as `SessionStatus.tint`, extended). Names: the design sheet only (not localized).
    // l10n-ignore-begin
    static let working = NBAccent(id: "working", name: "Работает",
                                  base: rgb(0.33, 0.64, 1.0), bright: rgb(0.56, 0.78, 1.0),
                                  deep: rgb(0.16, 0.42, 0.92), onAccent: .white)
    static let waiting = NBAccent(id: "waiting", name: "Ждёт тебя",
                                  base: rgb(1.0, 0.62, 0.10), bright: rgb(1.0, 0.76, 0.38),
                                  deep: rgb(0.92, 0.42, 0.04), onAccent: rgb(0.12, 0.06, 0.0))
    static let done = NBAccent(id: "done", name: "Готово",
                               base: rgb(0.25, 0.84, 0.42), bright: rgb(0.52, 0.93, 0.62),
                               deep: rgb(0.10, 0.62, 0.30), onAccent: rgb(0.0, 0.12, 0.04))
    static let error = NBAccent(id: "error", name: "Ошибка",
                                base: rgb(1.0, 0.33, 0.30), bright: rgb(1.0, 0.56, 0.52),
                                deep: rgb(0.84, 0.16, 0.18), onAccent: .white)
    static let idle = NBAccent(id: "idle", name: "Простаивает",
                               base: Color(white: 0.56), bright: Color(white: 0.72),
                               deep: Color(white: 0.38), onAccent: .black)

    // Interface accents.
    /// The app's own accent: switches, sliders, focus, selection.
    static let brand = NBAccent(id: "brand", name: "Акцент",
                                base: rgb(0.47, 0.52, 1.0), bright: rgb(0.66, 0.70, 1.0),
                                deep: rgb(0.34, 0.33, 0.93), onAccent: .white)
    /// Neutral (white) controls.
    static let neutral = NBAccent(id: "neutral", name: "Нейтральный",
                                  base: Color(white: 0.92), bright: .white,
                                  deep: Color(white: 0.72), onAccent: NBColor.inkInverse)
    /// Celebrations and "new" marks (sparkles).
    static let magic = NBAccent(id: "magic", name: "Магия",
                                base: rgb(0.78, 0.46, 1.0), bright: rgb(0.88, 0.68, 1.0),
                                deep: rgb(0.55, 0.28, 0.96), onAccent: .white)

    // l10n-ignore-end

    // Agent accents (the agent's own color: marks and agent chips only).
    static let claude = NBAccent(id: "claude", name: "Claude",
                                 base: rgb(0.85, 0.47, 0.34), bright: rgb(0.95, 0.64, 0.52),
                                 deep: rgb(0.72, 0.34, 0.23), onAccent: .white)
    static let codex = NBAccent(id: "codex", name: "Codex",
                                base: Color(white: 0.94), bright: .white,
                                deep: Color(white: 0.74), onAccent: Color(white: 0.06))
    static let kimi = NBAccent(id: "kimi", name: "Kimi",
                               base: rgb(0.47, 0.45, 1.0), bright: rgb(0.66, 0.65, 1.0),
                               deep: rgb(0.33, 0.27, 0.86), onAccent: .white)

    static let statuses: [NBAccent] = [.working, .waiting, .done, .error, .idle]
    static let interface: [NBAccent] = [.brand, .neutral, .magic]
    static let agents: [NBAccent] = [.claude, .codex, .kimi]

    static func status(_ status: SessionStatus) -> NBAccent {
        switch status {
        case .working: return .working
        case .waitingForUser: return .waiting
        case .finished: return .done
        case .error: return .error
        case .idle: return .idle
        }
    }

    static func agent(_ source: AgentSource) -> NBAccent {
        switch source {
        case .claude: return .claude
        case .codex: return .codex
        case .kimi: return .kimi
        default: return .neutral
        }
    }

    /// Usage level color: calm below 60 %, amber to 85 %, red above.
    static func usage(_ fraction: Double) -> NBAccent {
        switch fraction {
        case ..<0.6: return .working
        case ..<0.85: return .waiting
        default: return .error
        }
    }
}

// MARK: - Contrast

/// WCAG contrast, used by the design lint (`--render-design`).
enum NBContrast {
    /// Relative luminance of an sRGB color.
    static func luminance(_ color: Color) -> Double {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        func channel(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(ns.redComponent) + 0.7152 * channel(ns.greenComponent) + 0.0722 * channel(ns.blueComponent)
    }

    /// Composite of white at `opacity` over a gray background (`background` 0 … 1).
    static func whiteOver(gray background: Double, opacity: Double) -> Color {
        Color(white: background + (1 - background) * opacity)
    }

    static func ratio(_ a: Color, _ b: Color) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
