import AppKit
import CoreText
import SwiftUI

/// Manrope (SIL OFL 1.1, `Resources/Fonts/Manrope-Variable.ttf`) for the shelf, at exact weights of its
/// variable `wght` axis (200…800). Registered for this process on first use, from the app bundle
/// (`Contents/Resources/Fonts`) or, in a development build, from the repository's `Resources/Fonts`; without
/// it the system font stands in with the nearest weight.
@MainActor
enum ShelfTypography {
    static let family = "Manrope"

    /// `size` in points, `weight` on Manrope's 200…800 axis (400 regular, 600 semibold, 700 bold).
    static func font(_ size: CGFloat, _ weight: CGFloat = 500) -> Font {
        // One loader for the whole island (NBTypography).
        NBTypography.font(size: size, weight: weight)
    }

    /// Tabular figures (counts, sizes that tick).
    static func digits(_ size: CGFloat, _ weight: CGFloat = 600) -> Font {
        font(size, weight).monospacedDigit()
    }

    static var isAvailable: Bool { registered }

    // MARK: Private

    private struct Key: Hashable {
        let size: CGFloat
        let weight: CGFloat
    }

    private static var cache: [Key: Font] = [:]
    private static var didTryRegistering = false
    private static var registered = false
    private static let weightAxis = 0x7767_6874 as NSNumber   // 'wght'

    private static func ctFont(_ size: CGFloat, _ weight: CGFloat) -> CTFont? {
        registerIfNeeded()
        guard registered else { return nil }
        let base = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let varied = CTFontDescriptorCreateCopyWithVariation(base, weightAxis as CFNumber, min(max(weight, 200), 800))
        let font = CTFontCreateWithFontDescriptor(varied, size, nil)
        return CTFontCopyFamilyName(font) as String == family ? font : nil
    }

    private static func registerIfNeeded() {
        guard !didTryRegistering else { return }
        didTryRegistering = true
        if NSFont(name: "Manrope-Regular", size: 12) != nil {
            registered = true
            return
        }
        for url in candidateURLs() where FileManager.default.fileExists(atPath: url.path) {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) || NSFont(name: "Manrope-Regular", size: 12) != nil {
                registered = true
                return
            }
        }
    }

    private static func candidateURLs() -> [URL] {
        let file = "Manrope-Variable.ttf"
        var urls: [URL] = []
        if let resources = Bundle.main.resourceURL {
            urls.append(resources.appendingPathComponent("Fonts/\(file)"))
            urls.append(resources.appendingPathComponent(file))
        }
        // A development build (`.build/<config>/NotchBuddy`): walk up to the repository.
        var directory = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<6 {
            guard let current = directory else { break }
            urls.append(current.appendingPathComponent("Resources/Fonts/\(file)"))
            directory = current.deletingLastPathComponent()
        }
        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Fonts/\(file)"))
        return urls
    }

    private static func systemWeight(_ weight: CGFloat) -> Font.Weight {
        switch weight {
        case ..<250: return .ultraLight
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        default: return .heavy
        }
    }
}
