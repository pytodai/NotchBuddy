import AppKit
import CoreText
import SwiftUI
import NotchBuddyCore

/// Manrope for the timer and system widgets. The font ships in `Resources/Fonts` (SIL OFL 1.1) and is
/// registered for this process on first use, from the app bundle or, when run from a checkout (`swift run`,
/// `--render-timer-system`), from the repository. Without it the system font stands in, weight for weight.
@MainActor
enum GadgetFont {
    private static var registered: Bool?
    private static var cache: [String: Font] = [:]

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        // One loader for the whole island (NBTypography).
        NBTypography.font(size: size, weight: NBTypography.manropeWeight(weight))
    }

    private static func postScriptName(_ weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin: return "Manrope-ExtraLight"
        case .light: return "Manrope-Light"
        case .medium: return "Manrope-Medium"
        case .semibold: return "Manrope-SemiBold"
        case .bold: return "Manrope-Bold"
        case .heavy, .black: return "Manrope-ExtraBold"
        default: return "Manrope-Regular"
        }
    }

    @discardableResult
    static func registerIfNeeded() -> Bool {
        if let registered { return registered }
        if NSFont(name: "Manrope-Regular", size: 12) != nil {
            registered = true
            return true
        }
        let ok = fontURL().map { CTFontManagerRegisterFontsForURL($0 as CFURL, .process, nil) } ?? false
        registered = ok && NSFont(name: "Manrope-Regular", size: 12) != nil
        return registered ?? false
    }

    private static func fontURL() -> URL? {
        let file = "Manrope-Variable.ttf"
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates += [resources.appendingPathComponent("Fonts/\(file)"), resources.appendingPathComponent(file)]
        }
        // A checkout: the executable sits in `.build/<triple>/<config>/`.
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<6 {
            guard let current = dir else { break }
            candidates.append(current.appendingPathComponent("Resources/Fonts/\(file)"))
            dir = current.deletingLastPathComponent()
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Fonts/\(file)"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// A two-stop tint: `hi` is the bright head of an arc or the top of a fill, `lo` its deeper tail.
struct GadgetTint: Equatable {
    var hi: Color
    var lo: Color

    var gradient: [Color] { [lo, hi] }
}

/// Colors of the timer widget on the black island: like the Dynamic Island, rings and bars are thin and white;
/// color is only a small status accent: the last ten seconds, done, paused.
enum TimerPalette {
    /// One flat color (`hi` == `lo`): no gradients.
    static func flat(_ color: Color) -> GadgetTint { GadgetTint(hi: color, lo: color) }

    static let white = flat(Color.white.opacity(0.92))
    /// Kept as names for the timers' slots: all white now (several timers read apart by their labels and rows).
    static let coral = white
    static let tomato = white
    static let violet = white
    static let aqua = white
    static let rose = white
    static let lime = white
    static let done = flat(SessionStatus.finished.tint)
    /// The last ten seconds.
    static let urgent = flat(Color(red: 1.0, green: 0.42, blue: 0.36))
    static let paused = flat(Color(white: 0.6))

    static let hues: [GadgetTint] = [white]

    static let card = Color.white.opacity(0.055)
    static let cardHover = Color.white.opacity(0.085)
    static let track = Color.white.opacity(0.09)
    static let stroke = Color.white.opacity(0.07)
}

/// Colors of the system widget: thin white rings and bars (no gradients, no glow); amber and red only when a value
/// needs attention (a low battery, a nearly full disk or memory).
enum SystemPalette {
    static let cpu = TimerPalette.white
    static let memory = TimerPalette.white
    static let disk = TimerPalette.white
    static let batteryGood = TimerPalette.white
    static let batteryMid = TimerPalette.flat(Color(red: 1.0, green: 0.78, blue: 0.3))
    static let batteryLow = TimerPalette.flat(Color(red: 1.0, green: 0.42, blue: 0.36))
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.22)
    static let critical = Color(red: 1.0, green: 0.36, blue: 0.32)

    static func battery(_ state: BatteryState?, threshold: Int = 20) -> GadgetTint {
        guard let state else { return batteryGood }
        if state.onAC { return batteryGood }
        if state.percent <= threshold { return batteryLow }
        if state.percent <= max(threshold + 20, 40) { return batteryMid }
        return batteryGood
    }

    /// A usage gauge turns amber, then red, as it fills.
    static func load(_ fraction: Double, base: GadgetTint) -> GadgetTint {
        if fraction >= 0.9 { return TimerPalette.flat(critical) }
        if fraction >= 0.75 { return TimerPalette.flat(warning) }
        return base
    }
}

extension Color {
    /// `self` moved `t` (0…1) of the way toward `other` (`Color.mix` needs macOS 15).
    func gadgetBlend(_ other: Color, _ t: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .white
        return Color(nsColor: a.blended(withFraction: CGFloat(min(max(t, 0), 1)), of: b) ?? a)
    }
}

// MARK: - Motion

/// The widgets' own springs and loops, all slowed down with the island (`NOTCHBUDDY_SLOWMO`).
enum GadgetMotion {
    static var snap: Animation { .spring(response: 0.32, dampingFraction: 0.78).speed(IslandMotion.speed) }
    static var bouncy: Animation { .spring(response: 0.42, dampingFraction: 0.62).speed(IslandMotion.speed) }
    static var settle: Animation { .spring(response: 0.55, dampingFraction: 0.86).speed(IslandMotion.speed) }
    static var gauge: Animation { .spring(response: 0.9, dampingFraction: 0.82).speed(IslandMotion.speed) }
    static var hover: Animation { .spring(response: 0.26, dampingFraction: 0.72).speed(IslandMotion.speed) }
    static var digits: Animation { .spring(response: 0.36, dampingFraction: 0.84).speed(IslandMotion.speed) }
    static var fade: Animation { .easeInOut(duration: 0.22).speed(IslandMotion.speed) }
    static var breathe: Animation { .easeInOut(duration: 1.1).repeatForever(autoreverses: true).speed(IslandMotion.speed) }
}

/// Press squish + hover lift for the widgets' buttons and tiles.
struct GadgetPressStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(IslandMotion.press.animation, value: configuration.isPressed)
    }
}

/// A capsule button of the widgets: filled with a tint (primary), glassy (secondary), or a round icon.
struct GadgetButton<Label: View>: View {
    enum Kind { case primary(GadgetTint), secondary, round, roundTinted(GadgetTint) }

    let kind: Kind
    var height: CGFloat = 30
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .foregroundStyle(foreground)
                .padding(.horizontal, isRound ? 0 : 13)
                .frame(width: isRound ? height : nil, height: height)
                .background { background }
                .overlay { border }
                .scaleEffect(hovering ? 1.035 : 1)
                .contentShape(Capsule())
        }
        .buttonStyle(GadgetPressStyle())
        .onHover { inside in withAnimation(GadgetMotion.hover) { hovering = inside } }
    }

    private var isRound: Bool {
        switch kind {
        case .round, .roundTinted: return true
        default: return false
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Color.black.opacity(0.88)
        case .secondary, .round: return hovering ? .white : Color.white.opacity(0.86)
        case .roundTinted(let tint): return tint.hi
        }
    }

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .primary(let tint):
            // A flat fill (white for most; a status color stays a calm, solid one).
            Capsule().fill(tint.hi)
                .overlay(Capsule().fill(Color.white.opacity(hovering ? 0.14 : 0)))
        case .secondary, .round:
            Capsule().fill(Color.white.opacity(hovering ? 0.16 : 0.09))
        case .roundTinted(let tint):
            Capsule().fill(Color.white.opacity(hovering ? 0.16 : 0.09))
        }
    }

    @ViewBuilder
    private var border: some View {
        switch kind {
        case .primary:
            EmptyView()
        default:
            Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6)
        }
    }
}

/// A card on the black island: a soft glass slab with a hairline catching the light at its top.
struct GadgetCard: ViewModifier {
    var radius: CGFloat = 16
    var tint: Color?
    var hovering = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(hovering ? TimerPalette.cardHover : TimerPalette.card)
                    // A tint is a whisper, not a glow.
                    if let tint { shape.fill(tint.opacity(0.05)) }
                }
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.13), .white.opacity(0.03)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 0.7)
            }
    }
}

extension View {
    func gadgetCard(radius: CGFloat = 16, tint: Color? = nil, hovering: Bool = false) -> some View {
        modifier(GadgetCard(radius: radius, tint: tint, hovering: hovering))
    }
}

/// A section caption: "БЫСТРЫЙ СТАРТ".
struct GadgetCaption: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(GadgetFont.font(10, .bold))
            .tracking(0.9)
            .foregroundStyle(IslandPalette.tertiary)
    }
}
