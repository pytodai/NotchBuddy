import AppKit
import CoreText
import SwiftUI

/// Manrope for the session cards: the design system's one loader (`NBTypography`, registered in `main.swift`), with
/// the system font as the fallback when the file is not found.
@MainActor
enum SessionFont {
    /// Registers the font for this process (idempotent). True when Manrope is available.
    @discardableResult
    static func register() -> Bool { NBTypography.registerBundledFonts() }

    /// Manrope at `size` and `weight` (200…800; 400 regular, 600 semibold).
    static func manrope(_ size: CGFloat, _ weight: CGFloat = 500) -> Font {
        NBTypography.font(size: size, weight: weight)
    }
}

/// The cards' type scale.
@MainActor
enum SessionType {
    static var title: Font { SessionFont.manrope(13.5, 700) }
    static var body: Font { SessionFont.manrope(12, 500) }
    static var bodyStrong: Font { SessionFont.manrope(12, 650) }
    static var meta: Font { SessionFont.manrope(11, 550) }
    static var metaStrong: Font { SessionFont.manrope(11, 700) }
    static var caption: Font { SessionFont.manrope(10, 700) }
    static var pill: Font { SessionFont.manrope(11, 700) }
    static var button: Font { SessionFont.manrope(11.5, 680) }
    static var clock: Font { SessionFont.manrope(11.5, 600) }
    static func code(_ size: CGFloat = 10.5) -> Font { .system(size: size, weight: .regular, design: .monospaced) }
}
