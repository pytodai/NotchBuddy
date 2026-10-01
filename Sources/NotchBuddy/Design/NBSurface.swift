import SwiftUI

// MARK: - Elevation

/// How far a surface sits above the black island. On black, shadows barely read, so elevation is
/// mostly light: a brighter fill and a top-edge highlight that fades down the sides. Only
/// `.floating` and `.overlay` add a real shadow (for surfaces that can hang over the desktop).
enum NBElevation: String, CaseIterable, Identifiable {
    /// Recessed: code blocks, tracks, inputs.
    case inset
    /// Flush with the island: grouped rows on hover only.
    case flat
    /// Cards.
    case raised
    /// Popovers and menus inside the island.
    case floating
    /// Toasts and sheets over everything.
    case overlay

    var id: String { rawValue }

    var fill: Color {
        switch self {
        case .inset: return NBColor.well
        case .flat: return .clear
        case .raised: return NBColor.surface1
        case .floating: return Color(white: 0.105)
        case .overlay: return Color(white: 0.14)
        }
    }

    /// Top and bottom colors of the edge stroke.
    var edge: (top: Color, bottom: Color) {
        switch self {
        case .inset: return (Color.black.opacity(0.5), Color.white.opacity(0.07))
        case .flat: return (.clear, .clear)
        case .raised: return (Color.white.opacity(0.15), Color.white.opacity(0.04))
        case .floating: return (Color.white.opacity(0.22), Color.white.opacity(0.06))
        case .overlay: return (Color.white.opacity(0.28), Color.white.opacity(0.08))
        }
    }

    var shadow: (color: Color, radius: CGFloat, y: CGFloat) {
        switch self {
        case .inset, .flat, .raised: return (.clear, 0, 0)
        case .floating: return (Color.black.opacity(0.55), 14, 6)
        case .overlay: return (Color.black.opacity(0.7), 26, 12)
        }
    }

    var sheetName: String {
        switch self {
        case .inset: return "Inset"
        case .flat: return "Flat"
        case .raised: return "Raised"
        case .floating: return "Floating"
        case .overlay: return "Overlay"
        }
    }
}

/// Corner radii (continuous corners everywhere).
enum NBRadius {
    static let chip: CGFloat = 7
    static let control: CGFloat = 9
    static let card: CGFloat = 14
    static let panel: CGFloat = 20
}

/// Spacing scale (4 pt grid with a 2 pt half step).
enum NBSpace {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 8
    static let l: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 24
}

extension View {
    /// A surface at an elevation: fill, edge light, optional accent wash, optional shadow.
    func nbSurface(_ elevation: NBElevation = .raised, radius: CGFloat = NBRadius.card,
                   accent: NBAccent? = nil, highlighted: Bool = false) -> some View {
        modifier(NBSurfaceModifier(elevation: elevation, radius: radius, accent: accent, highlighted: highlighted))
    }

    /// A soft colored glow around the view's own shape (two stacked shadows).
    func nbGlow(_ color: Color, radius: CGFloat = 10, intensity: Double = 1) -> some View {
        shadow(color: color.opacity(0.9 * intensity), radius: radius * 0.35)
            .shadow(color: color.opacity(0.6 * intensity), radius: radius)
    }

    /// A band of light that sweeps across the view once each time `trigger` changes (`forced`: a fixed
    /// band position, for renders).
    func nbSheen<S: Shape, T: Equatable & Sendable>(_ shape: S, trigger: T, forced: Double? = nil, intensity: Double = 0.22) -> some View {
        modifier(NBSheenModifier(shape: shape, trigger: trigger, forced: forced, intensity: intensity))
    }
}

private struct NBSurfaceModifier: ViewModifier {
    let elevation: NBElevation
    let radius: CGFloat
    let accent: NBAccent?
    let highlighted: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let edge = elevation.edge
        let shadow = elevation.shadow
        content
            .background {
                ZStack {
                    shape.fill(highlighted && elevation != .inset ? NBColor.surface2 : elevation.fill)
                    if let accent {
                        shape.fill(LinearGradient(colors: [accent.base.opacity(0.20), accent.base.opacity(0.04)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                }
                .shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [accent?.base.opacity(0.45) ?? edge.top, accent?.base.opacity(0.10) ?? edge.bottom],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: elevation == .flat ? 0 : 0.75)
            }
    }
}

private struct NBSheenModifier<S: Shape, T: Equatable & Sendable>: ViewModifier {
    let shape: S
    let trigger: T
    let forced: Double?
    let intensity: Double
    @Environment(\.islandReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if let forced {
            content.overlay { NBSheenBand(position: forced, shape: shape, intensity: intensity) }
        } else if reduceMotion {
            content
        } else {
            let shape = shape, intensity = intensity
            content.keyframeAnimator(initialValue: -1.0, trigger: trigger) { view, position in
                view.overlay { NBSheenBand(position: position, shape: shape, intensity: intensity) }
            } keyframes: { _ in
                LinearKeyframe(-1.0, duration: 0)
                CubicKeyframe(1.3, duration: NBMotion.sheenDuration * IslandMotion.slowmo)
                LinearKeyframe(-1.0, duration: 0)
            }
        }
    }
}

/// The sheen's band at `position` (−1 … 1.3 across the shape).
private struct NBSheenBand<S: Shape>: View {
    let position: Double
    let shape: S
    let intensity: Double

    nonisolated init(position: Double, shape: S, intensity: Double) {
        self.position = position
        self.shape = shape
        self.intensity = intensity
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let bandWidth = max(28, w * 0.42)
            LinearGradient(stops: [
                .init(color: .white.opacity(0), location: 0),
                .init(color: .white.opacity(intensity), location: 0.5),
                .init(color: .white.opacity(0), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
                .frame(width: bandWidth, height: geo.size.height * 2.2)
                .rotationEffect(.degrees(18))
                .position(x: w / 2 + CGFloat(position) * (w / 2 + bandWidth), y: geo.size.height / 2)
                .opacity(position <= -1 || position >= 1.3 ? 0 : 1)
        }
        .clipShape(shape)
        .allowsHitTesting(false)
        .blendMode(.plusLighter)
    }
}
