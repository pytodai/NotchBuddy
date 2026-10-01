import AppKit
import CoreText
import SwiftUI

// MARK: - Registration

/// NotchBuddy's typography: Manrope (SIL OFL 1.1, bundled as a variable font in `Resources/Fonts`)
/// for every word on the island, SF Mono for code. Call `NBTypography.registerBundledFonts()` once at
/// launch, before the first view is built; without the font every token falls back to the system font
/// with the same size, weight and tabular digits, so nothing breaks.
enum NBTypography {
    static let family = "Manrope"
    /// PostScript name of the variable font's default instance; weights are set on its `wght` axis.
    static let basePostScriptName = "Manrope-Regular"
    static let fontFileNames = ["Manrope-Variable.ttf"]

    /// `wght` as an OpenType tag.
    private static let weightAxis = 0x7767_6874

    private static let state = RegistrationState()

    /// Whether Manrope is registered and resolvable (after `registerBundledFonts()`).
    static var isManropeAvailable: Bool { state.available }

    /// Where the font file was found (nil when it was not).
    static var registeredFontURL: URL? { state.url }

    /// Registers the bundled fonts for this process (idempotent, cheap after the first call). Looks in
    /// the app bundle's `Resources/Fonts`, then `NOTCHBUDDY_FONTS_DIR`, then a `Resources/Fonts` next to
    /// the executable or in any of its parent directories (a `swift build` tree inside the checkout).
    @discardableResult
    static func registerBundledFonts() -> Bool {
        state.once {
            for directory in candidateDirectories() {
                for name in fontFileNames {
                    let url = directory.appendingPathComponent(name)
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    var error: Unmanaged<CFError>?
                    let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
                    let alreadyRegistered = (error?.takeRetainedValue()).map {
                        CFErrorGetCode($0) == CTFontManagerError.alreadyRegistered.rawValue
                    } ?? false
                    if ok || alreadyRegistered, resolves() { return url }
                }
            }
            return resolves() ? URL(fileURLWithPath: "/system/\(family)") : nil
        }
        return state.available
    }

    private static func resolves() -> Bool {
        let font = CTFontCreateWithName(basePostScriptName as CFString, 12, nil)
        return (CTFontCopyFamilyName(font) as String) == family
    }

    static func candidateDirectories() -> [URL] {
        var result: [URL] = []
        if let resources = Bundle.main.resourceURL {
            result.append(resources.appendingPathComponent("Fonts", isDirectory: true))
        }
        if let custom = ProcessInfo.processInfo.environment["NOTCHBUDDY_FONTS_DIR"], !custom.isEmpty {
            result.append(URL(fileURLWithPath: custom, isDirectory: true))
        }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            var directory = executable.deletingLastPathComponent()
            for _ in 0..<7 {
                result.append(directory.appendingPathComponent("Resources/Fonts", isDirectory: true))
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        return result
    }

    // MARK: Fonts

    /// Manrope at an exact weight on its variable axis (200 … 800), tabular digits optional. Falls back
    /// to the system font with the nearest weight when Manrope is missing. Cached per (size, weight,
    /// digits): cheap to call from `body`.
    static func font(size: CGFloat, weight: CGFloat, tabular: Bool = false) -> Font {
        let key = FontKey(size: size, weight: weight, tabular: tabular)
        if let hit = state.cached(key) { return hit }
        let font: Font
        if let ct = ctFont(size: size, weight: weight, tabular: tabular) {
            font = Font(ct)
        } else {
            let system = Font.system(size: size, weight: systemWeight(weight))
            font = tabular ? system.monospacedDigit() : system
        }
        state.store(font, for: key)
        return font
    }

    /// The Core Text font behind `font(size:weight:tabular:)` (nil without Manrope), for AppKit text.
    static func ctFont(size: CGFloat, weight: CGFloat, tabular: Bool = false) -> CTFont? {
        guard isManropeAvailable else { return nil }
        var attributes: [CFString: Any] = [
            kCTFontNameAttribute: basePostScriptName,
            kCTFontVariationAttribute: [weightAxis: min(max(weight, 200), 800)],
        ]
        if tabular {
            attributes[kCTFontFeatureSettingsAttribute] = [[
                kCTFontOpenTypeFeatureTag: "tnum",
                kCTFontOpenTypeFeatureValue: 1,
            ]]
        }
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    static func nsFont(size: CGFloat, weight: CGFloat, tabular: Bool = false) -> NSFont {
        if let ct = ctFont(size: size, weight: weight, tabular: tabular) { return ct as NSFont }
        let font = NSFont.systemFont(ofSize: size, weight: nsWeight(weight))
        return tabular ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: nsWeight(weight)) : font
    }

    /// A SwiftUI weight on Manrope's axis (regular 400 … heavy 800), for views that name weights the SwiftUI way.
    static func manropeWeight(_ weight: Font.Weight) -> CGFloat {
        switch weight {
        case .ultraLight, .thin: return 200
        case .light: return 300
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy, .black: return 800
        default: return 400
        }
    }

    /// SF Mono (code, commands, paths).
    static func code(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func systemWeight(_ w: CGFloat) -> Font.Weight {
        switch w {
        case ..<250: return .ultraLight
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        default: return .heavy
        }
    }

    static func nsWeight(_ w: CGFloat) -> NSFont.Weight {
        switch w {
        case ..<250: return .ultraLight
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        default: return .heavy
        }
    }

    // MARK: State

    struct FontKey: Hashable {
        var size: CGFloat
        var weight: CGFloat
        var tabular: Bool
    }

    private final class RegistrationState: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var fontURL: URL?
        private var cache: [FontKey: Font] = [:]

        var available: Bool { lock.withLock { fontURL != nil } }
        var url: URL? { lock.withLock { fontURL } }

        func once(_ body: () -> URL?) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            fontURL = body()
            cache.removeAll()
        }

        func cached(_ key: FontKey) -> Font? { lock.withLock { cache[key] } }
        func store(_ font: Font, for key: FontKey) { lock.withLock { cache[key] = font } }
    }
}

/// Named points on Manrope's weight axis.
enum NBWeight {
    static let light: CGFloat = 300
    static let regular: CGFloat = 420
    static let medium: CGFloat = 520
    static let semibold: CGFloat = 620
    static let bold: CGFloat = 720
    static let heavy: CGFloat = 800
}

// MARK: - Text styles

/// The type scale of the island. Sizes are tuned for a black surface seen at arm's length: nothing
/// below 9.5 pt, body text at medium weight (Manrope's regular is thin on black), titles tightened.
enum NBTextStyle: String, CaseIterable, Identifiable {
    /// Hero numbers and one-word states ("Готово", "42%").
    case display
    /// Card and sheet titles.
    case title
    /// Session titles, button labels.
    case headline
    /// Running text.
    case body
    /// Emphasis in running text, labels of controls.
    case bodyStrong
    /// Secondary lines (tool, last message).
    case callout
    /// Meta: times, counts, hints.
    case caption
    /// Uppercase section labels ("СЕССИИ", "ЗВУК").
    case eyebrow
    /// Clocks and percentages that tick: tabular digits, never jitter.
    case numeric
    /// Large tabular numbers (usage, timers in widgets).
    case numericLarge
    /// Commands, paths, diffs (SF Mono).
    case code

    var id: String { rawValue }

    var size: CGFloat {
        switch self {
        case .display: return 24
        case .title: return 16
        case .headline: return 13.5
        case .body: return 12.5
        case .bodyStrong: return 12.5
        case .callout: return 11.5
        case .caption: return 10.5
        case .eyebrow: return 9.5
        case .numeric: return 12
        case .numericLarge: return 20
        case .code: return 11
        }
    }

    var weight: CGFloat {
        switch self {
        case .display: return 780
        case .title: return 720
        case .headline: return 660
        case .body: return 520
        case .bodyStrong: return 640
        case .callout: return 540
        case .caption: return 600
        case .eyebrow: return 780
        case .numeric: return 640
        case .numericLarge: return 740
        case .code: return 500
        }
    }

    /// Letter spacing in points (negative tightens large sizes; caps are opened up).
    var tracking: CGFloat {
        switch self {
        case .display: return -0.6
        case .title: return -0.25
        case .headline: return -0.1
        case .body, .bodyStrong: return 0
        case .callout: return 0.05
        case .caption: return 0.1
        case .eyebrow: return 0.9
        case .numeric: return 0
        case .numericLarge: return -0.4
        case .code: return 0
        }
    }

    var lineSpacing: CGFloat {
        switch self {
        case .body, .callout: return 2
        case .code: return 2.5
        default: return 0
        }
    }

    var tabular: Bool { self == .numeric || self == .numericLarge }
    var uppercase: Bool { self == .eyebrow }

    var font: Font {
        if self == .code {
            return NBTypography.code(size: size, weight: .medium)
        }
        return NBTypography.font(size: size, weight: weight, tabular: tabular)
    }

    /// Short name for the design sheet.
    var sheetName: String {
        switch self {
        case .display: return "Display"
        case .title: return "Title"
        case .headline: return "Headline"
        case .body: return "Body"
        case .bodyStrong: return "Body Strong"
        case .callout: return "Callout"
        case .caption: return "Caption"
        case .eyebrow: return "Eyebrow"
        case .numeric: return "Numeric"
        case .numericLarge: return "Numeric L"
        case .code: return "Code · SF Mono"
        }
    }
}

extension Font {
    /// A NotchBuddy text style (`Text("…").font(.nb(.headline))`); prefer `.nbText(_:)`, which also sets
    /// tracking, line spacing and case.
    static func nb(_ style: NBTextStyle) -> Font { style.font }

    /// Manrope at any size and axis weight (200 … 800).
    static func manrope(_ size: CGFloat, weight: CGFloat = NBWeight.medium, tabular: Bool = false) -> Font {
        NBTypography.font(size: size, weight: weight, tabular: tabular)
    }

    /// Tabular Manrope for ticking numbers.
    static func nbNumeric(_ size: CGFloat, weight: CGFloat = NBWeight.semibold) -> Font {
        NBTypography.font(size: size, weight: weight, tabular: true)
    }
}

extension View {
    /// Font, tracking, line spacing and case of a text style.
    func nbText(_ style: NBTextStyle) -> some View {
        font(style.font)
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
            .textCase(style.uppercase ? .uppercase : nil)
    }
}
