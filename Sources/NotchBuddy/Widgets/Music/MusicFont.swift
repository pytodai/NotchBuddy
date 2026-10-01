import AppKit
import CoreText
import SwiftUI

/// Manrope (Resources/Fonts/Manrope-Variable.ttf, SIL OFL) at any weight, straight from the variable font
/// file: no process-wide registration, so it cannot clash with another part of the app registering it.
/// Falls back to the system font when the file is not bundled.
@MainActor
enum MusicFont {
    private struct Key: Hashable {
        let size: CGFloat
        let weight: CGFloat
    }

    private static var cache: [Key: Font] = [:]

    /// The variable font's default instance, or nil.
    private static let descriptor: CTFontDescriptor? = {
        for url in candidates() where FileManager.default.fileExists(atPath: url.path) {
            if let list = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let first = list.first {
                return first
            }
        }
        return nil
    }()

    static var isAvailable: Bool { NBTypography.isManropeAvailable }

    /// `weight` on the font's own axis: 200 (ExtraLight) … 800 (ExtraBold).
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        // One loader for the whole island (NBTypography).
        NBTypography.font(size: size, weight: NBTypography.manropeWeight(weight))
    }

    private static func axis(_ weight: Font.Weight) -> CGFloat {
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

    /// The app bundle (Contents/Resources[/Fonts]); in a development build, the checkout's Resources/Fonts
    /// found above the executable (.build/debug/NotchBuddy).
    private static func candidates() -> [URL] {
        let name = "Manrope-Variable"
        var urls: [URL] = []
        if let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") { urls.append(url) }
        if let url = Bundle.main.url(forResource: name, withExtension: "ttf") { urls.append(url) }
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<7 {
            guard let current = dir else { break }
            urls.append(current.appendingPathComponent("Resources/Fonts/\(name).ttf"))
            dir = current.deletingLastPathComponent()
        }
        return urls
    }
}
