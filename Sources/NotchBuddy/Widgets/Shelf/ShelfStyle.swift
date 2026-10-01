import SwiftUI

/// Colors of the shelf on the black island: neutral, like the system's own surfaces. The "accent" that marks
/// the drop target, the badge and selected controls is white/gray, never a hue; color comes only from the
/// files' own pictures (and the red of a destructive confirm).
enum ShelfPalette {
    static let accent = Color.white.opacity(0.92)
    static let accentDeep = Color(white: 0.78)
    /// Practically flat white (kept a gradient for the shape styles that take one).
    static let accentGradient = LinearGradient(colors: [Color(white: 0.96), Color(white: 0.86)], startPoint: .top,
                                               endPoint: .bottom)
    /// The drop target's outline and a switch that is on: quiet white/gray.
    static let target = Color.white.opacity(0.42)
    static let switchOn = Color(red: 0.2, green: 0.78, blue: 0.35)
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.66)
    static let tertiary = Color.white.opacity(0.48)
    static let tile = Color(white: 0.07)
    static let tileHover = Color(white: 0.115)
    static let well = Color(white: 0.045)
    static let hairline = Color.white.opacity(0.075)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.38)
}

/// Every timing of the shelf. Slowed with the rest of the island by `NOTCHBUDDY_SLOWMO`.
enum ShelfMotion {
    /// A dropped file lands on the shelf: falls in from above, a touch of overshoot.
    static let landing = MotionCurve.spring(0.46, 0.70)
    /// Tiles making room (a ghost tile arriving, a tile leaving).
    static let reflow = MotionCurve.spring(0.36, 0.86)
    /// The ghost tile that stands for the files being dragged over.
    static let ghost = MotionCurve.spring(0.34, 0.68)
    static let hover = MotionCurve.spring(0.24, 0.78)
    static let press = MotionCurve.spring(0.18, 0.8)
    static let removal = MotionCurve.spring(0.28, 0.92)
    /// The badge's thumbnail dropping into its tray.
    static let badgeDrop = MotionCurve.spring(0.44, 0.60)
    /// The drop target lighting up.
    static let target = MotionCurve.spring(0.30, 0.82)

    /// Clear-all sweeps the tiles out one after another, this far apart.
    static let clearStagger = 0.028
    /// A landing tile's white outline fades over this long.
    static let landingGlow = 1.1
}

// MARK: - Icons

/// The shelf's mark: an open tray with a file arrow falling into it. Drawn, not a symbol, so the arrow
/// can bob and the tray can open (`lift`) while a drag is over the island.
struct ShelfTrayGlyph: View {
    var size: CGFloat = 18
    /// 0 … 1: the arrow's drop into the tray (0 above, 1 inside) — animatable.
    var arrow: CGFloat = 0.5
    /// 0 … 1: the tray's lip opening wider for an incoming drop.
    var open: CGFloat = 0
    var style: AnyShapeStyle = AnyShapeStyle(ShelfPalette.primary)
    var lineWidth: CGFloat?

    var body: some View {
        let w = lineWidth ?? max(1.2, size * 0.085)
        ZStack {
            TrayWell(open: open)
                .fill(Color.white.opacity(0.1))
            TrayOutline(open: open)
                .stroke(style, style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
            TrayArrow(drop: arrow)
                .stroke(style, style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

/// Outline of the tray on a 24 × 24 grid: walls and floor, and the lip with its slot.
struct TrayOutline: Shape {
    var open: CGFloat

    var animatableData: CGFloat {
        get { open }
        set { open = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let o = rect.origin
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        let spread = 1.1 * open
        var path = Path()
        // Walls and floor.
        path.move(to: p(3 - spread * 0.4, 12.2 - spread))
        path.addLine(to: p(3, 17.4))
        path.addQuadCurve(to: p(6.1, 20.6), control: p(3, 20.6))
        path.addLine(to: p(17.9, 20.6))
        path.addQuadCurve(to: p(21, 17.4), control: p(21, 20.6))
        path.addLine(to: p(21 + spread * 0.4, 12.2 - spread))
        // The lip, dipping into a slot in the middle.
        let depth = 2.7 + 0.5 * open
        path.move(to: p(3 - spread * 0.4, 12.2 - spread))
        path.addLine(to: p(7.4, 12.2))
        path.addQuadCurve(to: p(8.7, 13.0), control: p(8.3, 12.2))
        path.addLine(to: p(9.2, 12.2 + depth - 0.4))
        path.addQuadCurve(to: p(10.5, 12.2 + depth), control: p(9.6, 12.2 + depth))
        path.addLine(to: p(13.5, 12.2 + depth))
        path.addQuadCurve(to: p(14.8, 12.2 + depth - 0.4), control: p(14.4, 12.2 + depth))
        path.addLine(to: p(15.3, 13.0))
        path.addQuadCurve(to: p(16.6, 12.2), control: p(15.7, 12.2))
        path.addLine(to: p(21 + spread * 0.4, 12.2 - spread))
        return path
    }
}

/// The inside of the tray (a soft fill under the lip).
struct TrayWell: Shape {
    var open: CGFloat

    var animatableData: CGFloat {
        get { open }
        set { open = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let o = rect.origin
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        var path = Path()
        path.move(to: p(3, 12.2))
        path.addLine(to: p(3, 17.4))
        path.addQuadCurve(to: p(6.1, 20.6), control: p(3, 20.6))
        path.addLine(to: p(17.9, 20.6))
        path.addQuadCurve(to: p(21, 17.4), control: p(21, 20.6))
        path.addLine(to: p(21, 12.2))
        path.closeSubpath()
        return path
    }
}

/// The arrow falling into the tray: `drop` 0 hangs above, 1 sits in the slot.
struct TrayArrow: Shape {
    var drop: CGFloat

    var animatableData: CGFloat {
        get { drop }
        set { drop = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let o = rect.origin
        let dy = -1.6 + 3.2 * drop
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + (y + dy) * s) }
        var path = Path()
        path.move(to: p(12, 2.6))
        path.addLine(to: p(12, 11.2))
        path.move(to: p(8.7, 8.1))
        path.addLine(to: p(12, 11.4))
        path.addLine(to: p(15.3, 8.1))
        return path
    }
}

/// Small line glyphs for the tile actions, drawn on a 16 × 16 grid.
struct ShelfGlyph: Shape {
    enum Kind { case open, reveal, remove, plus, copyPath }
    let kind: Kind

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        let o = CGPoint(x: rect.midX - 8 * s, y: rect.midY - 8 * s)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        var path = Path()
        switch kind {
        case .open:
            // An arrow leaving a rounded box.
            path.move(to: p(8.6, 3.2))
            path.addLine(to: p(12.8, 3.2))
            path.addLine(to: p(12.8, 7.4))
            path.move(to: p(12.6, 3.4))
            path.addLine(to: p(7.2, 8.8))
            path.move(to: p(11.2, 9.6))
            path.addLine(to: p(11.2, 11.4))
            path.addQuadCurve(to: p(9.4, 13.2), control: p(11.2, 13.2))
            path.addLine(to: p(4.6, 13.2))
            path.addQuadCurve(to: p(2.8, 11.4), control: p(2.8, 13.2))
            path.addLine(to: p(2.8, 6.6))
            path.addQuadCurve(to: p(4.6, 4.8), control: p(2.8, 4.8))
            path.addLine(to: p(6.4, 4.8))
        case .reveal:
            // A folder with a magnifier.
            path.move(to: p(2.4, 11.6))
            path.addLine(to: p(2.4, 4.4))
            path.addQuadCurve(to: p(3.6, 3.2), control: p(2.4, 3.2))
            path.addLine(to: p(6.0, 3.2))
            path.addLine(to: p(7.4, 4.8))
            path.addLine(to: p(12.4, 4.8))
            path.addQuadCurve(to: p(13.6, 6.0), control: p(13.6, 4.8))
            path.addLine(to: p(13.6, 7.4))
            path.move(to: p(7.4, 12.8))
            path.addLine(to: p(3.6, 12.8))
            path.addQuadCurve(to: p(2.4, 11.6), control: p(2.4, 12.8))
            path.addEllipse(in: CGRect(x: o.x + 8.3 * s, y: o.y + 8.1 * s, width: 4.4 * s, height: 4.4 * s))
            path.move(to: p(12.1, 11.9))
            path.addLine(to: p(14.0, 13.8))
        case .remove:
            path.move(to: p(4.6, 4.6))
            path.addLine(to: p(11.4, 11.4))
            path.move(to: p(11.4, 4.6))
            path.addLine(to: p(4.6, 11.4))
        case .plus:
            path.move(to: p(8, 3.4))
            path.addLine(to: p(8, 12.6))
            path.move(to: p(3.4, 8))
            path.addLine(to: p(12.6, 8))
        case .copyPath:
            path.addRoundedRect(in: CGRect(x: o.x + 5.4 * s, y: o.y + 5.4 * s, width: 7.6 * s, height: 7.6 * s),
                                cornerSize: CGSize(width: 1.8 * s, height: 1.8 * s))
            path.move(to: p(3.0, 9.8))
            path.addLine(to: p(3.0, 4.6))
            path.addQuadCurve(to: p(4.6, 3.0), control: p(3.0, 3.0))
            path.addLine(to: p(9.8, 3.0))
        }
        return path
    }
}

extension ShelfGlyph {
    func icon(_ size: CGFloat, _ color: Color, weight: CGFloat? = nil) -> some View {
        stroke(color, style: StrokeStyle(lineWidth: weight ?? max(1.2, size * 0.1), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

/// A dashed rounded border whose dashes march (a drop target). `phase` is animatable.
struct MarchingBorder: Shape {
    var cornerRadius: CGFloat
    var phase: CGFloat
    var dash: [CGFloat] = [7, 5]
    var lineWidth: CGFloat = 1.4

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        return Path(roundedRect: inset, cornerRadius: cornerRadius, style: .continuous)
            .strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: dash, dashPhase: phase))
    }
}
