import AppKit
import CoreText
import SwiftUI
import NotchBuddyCore

/// Manrope for the calendar widget. The font ships in `Resources/Fonts` (SIL OFL 1.1); it is registered
/// for this process on first use, from the app bundle or, when run from a checkout (`swift run`,
/// `--render-calendar`), from the repository. Without it the system font stands in, weight for weight.
@MainActor
enum CalendarType {
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
        return registered!
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

/// Colors of the widget on the black island. The surface is neutral (black, dark grays, white text); the
/// only color is the calendars' own, and only as small dots and bars.
enum CalendarPalette {
    /// Calendar red (the page glyph's band, like the Calendar app icon).
    static let today = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let card = Color(white: 0.095)
    static let cardHover = Color(white: 0.125)
    static let stroke = Color.white.opacity(0.07)
    /// A progress track / ring track: dark gray on the black island.
    static let track = Color.white.opacity(0.16)
    /// Neutral chips (status, all-day events).
    static let chip = Color.white.opacity(0.09)
    static let soon = Color(red: 1.0, green: 0.62, blue: 0.1)

    /// A calendar's own color, lifted so a dark one (navy, brown) still reads on black.
    static func tint(_ rgb: CalendarRGB) -> Color {
        let color = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(min(s, 0.82)), brightness: Double(max(b, 0.86)))
    }

    /// A deeper shade of the same hue for gradients.
    static func deep(_ rgb: CalendarRGB) -> Color {
        let color = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(min(max(s, 0.5), 0.9)), brightness: Double(min(max(b, 0.5), 0.62)))
    }

    /// Brand-ish tint of a call service's glyph.
    static func service(_ service: MeetingService) -> Color {
        switch service {
        case .zoom: return Color(red: 0.18, green: 0.55, blue: 1.0)
        case .googleMeet: return Color(red: 0.13, green: 0.73, blue: 0.45)
        case .teams: return Color(red: 0.42, green: 0.45, blue: 0.95)
        case .telemost: return Color(red: 1.0, green: 0.36, blue: 0.3)
        case .jazz: return Color(red: 0.2, green: 0.78, blue: 0.52)
        case .kontur: return Color(red: 0.98, green: 0.45, blue: 0.2)
        case .vkCalls: return Color(red: 0.2, green: 0.5, blue: 1.0)
        case .mtsLink: return Color(red: 0.95, green: 0.2, blue: 0.3)
        case .webex: return Color(red: 0.2, green: 0.75, blue: 0.9)
        case .facetime: return Color(red: 0.25, green: 0.84, blue: 0.42)
        case .whereby: return Color(red: 0.55, green: 0.5, blue: 1.0)
        case .jitsi: return Color(red: 0.3, green: 0.6, blue: 1.0)
        case .slack: return Color(red: 0.88, green: 0.3, blue: 0.62)
        case .discord: return Color(red: 0.4, green: 0.45, blue: 0.98)
        }
    }
}

extension CalendarFormat {
    @MainActor static let shared = CalendarFormat()
}

extension Color {
    /// `self` moved `t` (0…1) of the way toward `other` (`Color.mix` needs macOS 15).
    func calendarBlend(_ other: Color, _ t: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .white
        return Color(nsColor: a.blended(withFraction: CGFloat(t), of: b) ?? a)
    }
}
