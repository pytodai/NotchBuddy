import AppKit
import CoreText
import SwiftUI

/// Checks the design system can keep its promises (run by `--render-design`; any problem makes the
/// run exit non-zero): the font is registered and its weight axis and tabular digits work, text tokens
/// meet their contrast, and every icon draws something sensible in every state without leaving its box.
@MainActor
enum NBDesignLint {
    struct Result {
        var report: [String] = []
        var problems: [String] = []
    }

    static func run() -> Result {
        var result = Result()
        checkFont(&result)
        checkContrast(&result)
        checkIcons(&result)
        return result
    }

    // MARK: Font

    private static func advance(_ text: String, _ font: CTFont) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: font as NSFont])
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func checkFont(_ r: inout Result) {
        guard NBTypography.isManropeAvailable,
              let light = NBTypography.ctFont(size: 20, weight: 300),
              let heavy = NBTypography.ctFont(size: 20, weight: 800),
              let tabular = NBTypography.ctFont(size: 20, weight: 600, tabular: true),
              let proportional = NBTypography.ctFont(size: 20, weight: 600) else {
            r.problems.append("Manrope is not registered (looked in \(NBTypography.candidateDirectories().map(\.path)))")
            return
        }
        r.report.append("font: Manrope from \(NBTypography.registeredFontURL?.path ?? "?")")
        let sample = "Почини падающие тесты"
        let wLight = advance(sample, light), wHeavy = advance(sample, heavy)
        if wHeavy <= wLight * 1.03 {
            r.problems.append("weight axis has no effect (300: \(wLight), 800: \(wHeavy))")
        } else {
            r.report.append(String(format: "font: weight axis ok (300 → 800 widens by %.1f%%)", (wHeavy / wLight - 1) * 100))
        }
        let ones = advance("1111", tabular), eights = advance("8888", tabular)
        let pOnes = advance("1111", proportional), pEights = advance("8888", proportional)
        if abs(ones - eights) > 0.01 {
            r.problems.append("tabular digits are not tabular (1111: \(ones), 8888: \(eights))")
        } else {
            r.report.append(String(format: "font: tabular digits ok (proportional 1111/8888 differ by %.1f pt)", pEights - pOnes))
        }
        let cyrillic = "ЁЖЩЫЪэюя"
        let glyphCount = cyrillic.utf16.count
        var chars = Array(cyrillic.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
        if !CTFontGetGlyphsForCharacters(proportional, &chars, &glyphs, glyphCount) || glyphs.contains(0) {
            r.problems.append("Manrope lacks some Cyrillic glyphs")
        } else {
            r.report.append("font: Cyrillic coverage ok")
        }
    }

    // MARK: Contrast

    private static func checkContrast(_ r: inout Result) {
        for level in NBColor.inkLevels {
            for (surface, gray) in [("island", 0.0), ("surface1", 0.065)] {
                let ratio = NBContrast.ratio(NBContrast.whiteOver(gray: gray, opacity: level.opacity), Color(white: gray))
                if ratio < level.minimumContrast {
                    r.problems.append(String(format: "%@ on %@: %.2f:1 < %.1f:1", level.name, surface, ratio, level.minimumContrast))
                }
            }
        }
        for accent in NBAccent.statuses + NBAccent.interface + NBAccent.agents {
            let ratio = NBContrast.ratio(accent.bright, .black)
            if ratio < 4.5 {
                r.problems.append(String(format: "%@.bright on black: %.2f:1 < 4.5:1", accent.id, ratio))
            }
        }
        r.report.append("contrast: \(NBColor.inkLevels.count) ink levels × 2 surfaces, \(NBAccent.statuses.count + NBAccent.interface.count + NBAccent.agents.count) accents checked")
    }

    // MARK: Icons

    /// Coverage of an icon drawn at 48 pt: fraction of pixels painted, and whether ink touches the
    /// outer 1 px ring (drawing that leaves the box gets clipped in the live UI).
    private static func measure(_ icon: NBIcon, _ state: NBIconState) -> (coverage: Double, edge: Bool)? {
        let side = 48
        let view = NBIconGlyph(icon: icon, color: .white, tone: .white.opacity(0.22), accent: nil,
                               hover: state.hover, value: state.value, phase: state.phase)
            .frame(width: CGFloat(side), height: CGFloat(side))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var painted = 0
        var edge = false
        for y in 0..<side {
            for x in 0..<side {
                let alpha = pixels[(y * side + x) * 4 + 3]
                if alpha > 24 {
                    painted += 1
                    if x == 0 || y == 0 || x == side - 1 || y == side - 1 { edge = true }
                }
            }
        }
        return (Double(painted) / Double(side * side), edge)
    }

    private static func checkIcons(_ r: inout Result) {
        var checked = 0
        for icon in NBIcon.allCases {
            var states = [NBIconState(hover: 0, value: icon.defaultValue, phase: icon.restPhase)]
            for h in [0.25, 0.5, 0.75, 1.0, 1.08] {
                states.append(NBIconState(hover: h, value: icon.defaultValue, phase: icon.restPhase))
            }
            for v in [0.0, 0.5, 1.0] {
                states.append(NBIconState(hover: 0, value: v, phase: icon.restPhase))
            }
            if icon.loops {
                for p in stride(from: 0.0, to: 1.0, by: 0.125) {
                    states.append(NBIconState(hover: 0, value: icon.defaultValue, phase: p))
                }
            }
            for state in states {
                checked += 1
                guard let m = measure(icon, state) else {
                    r.problems.append("icon .\(icon.rawValue) failed to render")
                    continue
                }
                // A check or a stroke that has not started drawing may legitimately be empty.
                let mayBeEmpty = (icon == .check || icon == .done) && state.value < 0.05
                if m.coverage < 0.02 && !mayBeEmpty {
                    r.problems.append(String(format: "icon .%@ nearly empty (%.1f%%) at hover %.2f value %.2f phase %.2f",
                                             icon.rawValue, m.coverage * 100, state.hover, state.value, state.phase))
                }
                if m.coverage > 0.72 {
                    r.problems.append(String(format: "icon .%@ too heavy (%.0f%%)", icon.rawValue, m.coverage * 100))
                }
                if m.edge {
                    r.problems.append(String(format: "icon .%@ touches its box edge at hover %.2f value %.2f phase %.2f",
                                             icon.rawValue, state.hover, state.value, state.phase))
                }
            }
        }
        r.report.append("icons: \(NBIcon.allCases.count) icons, \(checked) states drawn, inside their box")
        let t0 = CACurrentMediaTime()
        var frames = 0
        for i in 0..<60 {
            let renderer = ImageRenderer(content: NBIconGlyph(icon: .working, color: .white, tone: .white.opacity(0.22), accent: nil,
                                                              hover: 0, value: 0, phase: Double(i) / 60).frame(width: 18, height: 18))
            renderer.scale = 2
            if renderer.cgImage != nil { frames += 1 }
        }
        r.report.append(String(format: "icons: 60 sprite frames rendered in %.1f ms", (CACurrentMediaTime() - t0) * 1000))
    }
}
