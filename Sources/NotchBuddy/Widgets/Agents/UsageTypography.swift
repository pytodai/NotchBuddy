import AppKit
import CoreText
import SwiftUI

/// Manrope (SIL OFL 1.1, `Resources/Fonts/Manrope-Variable.ttf`) for the usage footer, at any weight of its
/// variable axis (200…800), with tabular digits when asked. Falls back to the system font when the file is missing.
/// `NBTypography.font(size:weight:tabular:)` has the same shape.
@MainActor
enum UsageType {
    static let family = "Manrope"

    private static var registered: Bool?
    private static var cache: [String: Font] = [:]

    /// Registers the bundled file for this process once; true when Manrope resolves (also when someone else did it).
    @discardableResult
    static func ensureRegistered() -> Bool {
        if let registered { return registered }
        if !resolves() {
            for url in candidateFiles() where FileManager.default.fileExists(atPath: url.path) {
                var error: Unmanaged<CFError>?
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
                if resolves() { break }
            }
        }
        let ok = resolves()
        registered = ok
        return ok
    }

    private static func resolves() -> Bool {
        (CTFontCopyFamilyName(CTFontCreateWithName("Manrope-Regular" as CFString, 12, nil)) as String) == family
    }

    private static func candidateFiles() -> [URL] {
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL {
            dirs.append(resources.appendingPathComponent("Fonts", isDirectory: true))
            dirs.append(resources)
        }
        // `swift run` / previews from a checkout: <repo>/Resources/Fonts.
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        dirs.append(repo.appendingPathComponent("Resources/Fonts", isDirectory: true))
        return dirs.map { $0.appendingPathComponent("Manrope-Variable.ttf") }
    }

    /// Manrope at `weight` (400 regular, 500 medium, 600 semibold, 700 bold, 800 extra bold).
    static func font(size: CGFloat, weight: CGFloat, tabular: Bool = false) -> Font {
        // One loader for the whole island (NBTypography).
        NBTypography.font(size: size, weight: weight, tabular: tabular)
    }
}
