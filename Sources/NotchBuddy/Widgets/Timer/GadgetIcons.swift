import SwiftUI

/// The widgets' own icons, drawn on a 24-point grid with round caps and joins (one stroke weight across the
/// set), so they sit with Manrope instead of looking borrowed from SF Symbols.
enum GadgetGlyph: Equatable {
    case stopwatch, play, pause, plus, minus, xmark, restart, bell, bolt, plug, chip, memory, disk, gauge, check, sparkle
}

struct GadgetIcon: View {
    let glyph: GadgetGlyph
    var size: CGFloat = 14
    var color: Color = .white
    /// Stroke weight on the 24-point grid.
    var weight: CGFloat = 2.1

    var body: some View {
        let k = size / 24
        let style = StrokeStyle(lineWidth: weight * k, lineCap: .round, lineJoin: .round)
        ZStack {
            GadgetGlyphStroke(glyph: glyph).stroke(color, style: style)
            GadgetGlyphFill(glyph: glyph).fill(color)
            // Filled glyphs get the same round joins as the stroked ones.
            GadgetGlyphFill(glyph: glyph).stroke(color, style: StrokeStyle(lineWidth: 1.6 * k, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The stroked part of a glyph, on a 24 × 24 grid scaled to the rect.
struct GadgetGlyphStroke: Shape {
    let glyph: GadgetGlyph

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch glyph {
        case .stopwatch:
            p.addEllipse(in: CGRect(x: 4, y: 5.5, width: 16, height: 16))
            p.move(to: CGPoint(x: 12, y: 5.5)); p.addLine(to: CGPoint(x: 12, y: 3.2))
            p.move(to: CGPoint(x: 9.8, y: 2.6)); p.addLine(to: CGPoint(x: 14.2, y: 2.6))
            p.move(to: CGPoint(x: 18.1, y: 7.2)); p.addLine(to: CGPoint(x: 19.7, y: 5.6))
            p.move(to: CGPoint(x: 12, y: 13.5)); p.addLine(to: CGPoint(x: 14.6, y: 9.8))
        case .plus:
            p.move(to: CGPoint(x: 12, y: 5)); p.addLine(to: CGPoint(x: 12, y: 19))
            p.move(to: CGPoint(x: 5, y: 12)); p.addLine(to: CGPoint(x: 19, y: 12))
        case .minus:
            p.move(to: CGPoint(x: 5, y: 12)); p.addLine(to: CGPoint(x: 19, y: 12))
        case .xmark:
            p.move(to: CGPoint(x: 6.5, y: 6.5)); p.addLine(to: CGPoint(x: 17.5, y: 17.5))
            p.move(to: CGPoint(x: 17.5, y: 6.5)); p.addLine(to: CGPoint(x: 6.5, y: 17.5))
        case .restart:
            let c = CGPoint(x: 12, y: 12.5), r: CGFloat = 7
            let start = Angle.degrees(-80), end = Angle.degrees(215)
            p.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: false)
            // Arrowhead at the start, pointing along the arc's direction of travel backwards (a "go again").
            let a = start.radians
            let tip = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            let back = CGPoint(x: sin(a), y: -cos(a))   // against the direction of increasing angle
            for turn in [0.75, -0.75] {
                let dx = back.x * cos(turn) - back.y * sin(turn), dy = back.x * sin(turn) + back.y * cos(turn)
                p.move(to: tip); p.addLine(to: CGPoint(x: tip.x - dx * 3.6, y: tip.y - dy * 3.6))
            }
        case .bell:
            p.move(to: CGPoint(x: 5.5, y: 16.8)); p.addLine(to: CGPoint(x: 18.5, y: 16.8))
            p.move(to: CGPoint(x: 7.2, y: 16.8))
            p.addCurve(to: CGPoint(x: 12, y: 6), control1: CGPoint(x: 7.2, y: 11.2), control2: CGPoint(x: 7.4, y: 6))
            p.addCurve(to: CGPoint(x: 16.8, y: 16.8), control1: CGPoint(x: 16.6, y: 6), control2: CGPoint(x: 16.8, y: 11.2))
            p.move(to: CGPoint(x: 12, y: 6)); p.addLine(to: CGPoint(x: 12, y: 4.4))
            p.move(to: CGPoint(x: 10.2, y: 19.4))
            p.addQuadCurve(to: CGPoint(x: 13.8, y: 19.4), control: CGPoint(x: 12, y: 21.2))
        case .chip:
            p.addRoundedRect(in: CGRect(x: 6.5, y: 6.5, width: 11, height: 11), cornerSize: CGSize(width: 2.4, height: 2.4))
            for v in [9.4, 12.0, 14.6] as [CGFloat] {
                p.move(to: CGPoint(x: v, y: 6.5)); p.addLine(to: CGPoint(x: v, y: 4))
                p.move(to: CGPoint(x: v, y: 17.5)); p.addLine(to: CGPoint(x: v, y: 20))
                p.move(to: CGPoint(x: 6.5, y: v)); p.addLine(to: CGPoint(x: 4, y: v))
                p.move(to: CGPoint(x: 17.5, y: v)); p.addLine(to: CGPoint(x: 20, y: v))
            }
        case .memory:
            p.addRoundedRect(in: CGRect(x: 3.5, y: 7, width: 17, height: 9.5), cornerSize: CGSize(width: 1.8, height: 1.8))
            for x in [6.5, 9, 15, 17.5] as [CGFloat] {
                p.move(to: CGPoint(x: x, y: 16.5)); p.addLine(to: CGPoint(x: x, y: 19))
            }
        case .disk:
            p.addRoundedRect(in: CGRect(x: 3.5, y: 6, width: 17, height: 12.5), cornerSize: CGSize(width: 2.8, height: 2.8))
            p.move(to: CGPoint(x: 3.8, y: 13.2)); p.addLine(to: CGPoint(x: 20.2, y: 13.2))
            p.move(to: CGPoint(x: 7, y: 15.9)); p.addLine(to: CGPoint(x: 10.5, y: 15.9))
        case .gauge:
            p.addArc(center: CGPoint(x: 12, y: 14), radius: 8.2, startAngle: .degrees(150), endAngle: .degrees(30), clockwise: false)
            p.move(to: CGPoint(x: 12, y: 14)); p.addLine(to: CGPoint(x: 16.2, y: 9.2))
        case .plug:
            p.move(to: CGPoint(x: 9.4, y: 2.8)); p.addLine(to: CGPoint(x: 9.4, y: 7))
            p.move(to: CGPoint(x: 14.6, y: 2.8)); p.addLine(to: CGPoint(x: 14.6, y: 7))
            p.move(to: CGPoint(x: 6.4, y: 7)); p.addLine(to: CGPoint(x: 17.6, y: 7))
            p.addLine(to: CGPoint(x: 17.6, y: 10.5))
            p.addCurve(to: CGPoint(x: 12, y: 16.4), control1: CGPoint(x: 17.6, y: 13.8), control2: CGPoint(x: 15.2, y: 16.4))
            p.addCurve(to: CGPoint(x: 6.4, y: 10.5), control1: CGPoint(x: 8.8, y: 16.4), control2: CGPoint(x: 6.4, y: 13.8))
            p.closeSubpath()
            p.move(to: CGPoint(x: 12, y: 16.4)); p.addLine(to: CGPoint(x: 12, y: 21.2))
        case .check:
            p.move(to: CGPoint(x: 5.8, y: 12.6)); p.addLine(to: CGPoint(x: 10.1, y: 16.8)); p.addLine(to: CGPoint(x: 18.4, y: 7.4))
        case .play, .pause, .bolt, .sparkle:
            break
        }
        return p.applying(Self.scale(rect))
    }

    static func scale(_ rect: CGRect) -> CGAffineTransform {
        CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: rect.width / 24, y: rect.height / 24)
    }
}

/// The filled part of a glyph.
struct GadgetGlyphFill: Shape {
    let glyph: GadgetGlyph

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch glyph {
        case .stopwatch:
            p.addEllipse(in: CGRect(x: 10.7, y: 12.2, width: 2.6, height: 2.6))
        case .play:
            p.move(to: CGPoint(x: 8, y: 5.6)); p.addLine(to: CGPoint(x: 18.8, y: 12)); p.addLine(to: CGPoint(x: 8, y: 18.4))
            p.closeSubpath()
        case .pause:
            p.addRoundedRect(in: CGRect(x: 6.6, y: 5.4, width: 3.8, height: 13.2), cornerSize: CGSize(width: 1.5, height: 1.5))
            p.addRoundedRect(in: CGRect(x: 13.6, y: 5.4, width: 3.8, height: 13.2), cornerSize: CGSize(width: 1.5, height: 1.5))
        case .bolt:
            p.move(to: CGPoint(x: 13.6, y: 2.6)); p.addLine(to: CGPoint(x: 5.8, y: 13.6)); p.addLine(to: CGPoint(x: 11.2, y: 13.6))
            p.addLine(to: CGPoint(x: 10.2, y: 21.4)); p.addLine(to: CGPoint(x: 18.2, y: 10.2)); p.addLine(to: CGPoint(x: 12.7, y: 10.2))
            p.closeSubpath()
        case .chip:
            p.addRoundedRect(in: CGRect(x: 9.6, y: 9.6, width: 4.8, height: 4.8), cornerSize: CGSize(width: 1, height: 1))
        case .memory:
            for x in [6, 10.5, 15] as [CGFloat] {
                p.addRoundedRect(in: CGRect(x: x, y: 9.6, width: 3, height: 4.2), cornerSize: CGSize(width: 0.6, height: 0.6))
            }
        case .disk:
            p.addEllipse(in: CGRect(x: 15.3, y: 14.8, width: 2.2, height: 2.2))
        case .gauge:
            p.addEllipse(in: CGRect(x: 10.6, y: 12.6, width: 2.8, height: 2.8))
        case .sparkle:
            // A four-point star with concave sides.
            let c = CGPoint(x: 12, y: 12)
            p.move(to: CGPoint(x: 12, y: 2.5))
            p.addQuadCurve(to: CGPoint(x: 21.5, y: 12), control: c)
            p.addQuadCurve(to: CGPoint(x: 12, y: 21.5), control: c)
            p.addQuadCurve(to: CGPoint(x: 2.5, y: 12), control: c)
            p.addQuadCurve(to: CGPoint(x: 12, y: 2.5), control: c)
            p.closeSubpath()
        default:
            break
        }
        return p.applying(GadgetGlyphStroke.scale(rect))
    }
}

/// A glyph in a softly lit rounded tile (widget headers, settings rows).
struct GadgetIconTile: View {
    let glyph: GadgetGlyph
    let tint: GadgetTint
    var size: CGFloat = 22

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        GadgetIcon(glyph: glyph, size: size * 0.66, color: .white, weight: 2.3)
            .frame(width: size, height: size)
            .background(shape.fill(Color.white.opacity(0.12)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6))
    }
}

/// A tomato for the pomodoro preset: a round body with a green calyx.
struct TomatoIcon: View {
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            Ellipse()
                .fill(RadialGradient(colors: [Color(red: 1.0, green: 0.52, blue: 0.40), Color(red: 0.86, green: 0.16, blue: 0.18)],
                                     center: UnitPoint(x: 0.35, y: 0.35), startRadius: 0, endRadius: size * 0.6))
                .frame(width: size * 0.92, height: size * 0.8)
                .offset(y: size * 0.08)
            Ellipse()
                .fill(Color.white.opacity(0.45))
                .frame(width: size * 0.2, height: size * 0.12)
                .rotationEffect(.degrees(-30))
                .offset(x: -size * 0.2, y: -size * 0.06)
            CalyxShape()
                .fill(Color(red: 0.36, green: 0.82, blue: 0.36))
                .frame(width: size * 0.56, height: size * 0.3)
                .offset(y: -size * 0.3)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct CalyxShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.maxY * 0.62)
        let tips: [CGPoint] = [CGPoint(x: r.minX, y: r.maxY * 0.7), CGPoint(x: r.midX - r.width * 0.2, y: r.minY),
                               CGPoint(x: r.midX + r.width * 0.2, y: r.minY), CGPoint(x: r.maxX, y: r.maxY * 0.7),
                               CGPoint(x: r.midX, y: r.maxY)]
        for tip in tips {
            let dx = tip.x - c.x, dy = tip.y - c.y
            let n = CGPoint(x: -dy * 0.28, y: dx * 0.28)
            p.move(to: CGPoint(x: c.x + n.x, y: c.y + n.y))
            p.addQuadCurve(to: tip, control: CGPoint(x: c.x + dx * 0.5 + n.x, y: c.y + dy * 0.5 + n.y))
            p.addQuadCurve(to: CGPoint(x: c.x - n.x, y: c.y - n.y), control: CGPoint(x: c.x + dx * 0.5 - n.x, y: c.y + dy * 0.5 - n.y))
            p.closeSubpath()
        }
        p.addRect(CGRect(x: r.midX - r.width * 0.05, y: r.minY - r.height * 0.1, width: r.width * 0.1, height: r.height * 0.6))
        return p
    }
}

/// Play ↔ pause that morphs: the triangle's right half folds into the second bar.
struct TimerPlayPause: View {
    /// True shows pause (the timer runs), false shows play.
    let running: Bool
    var size: CGFloat = 14
    var color: Color = .white

    var body: some View {
        ZStack {
            GadgetIcon(glyph: .pause, size: size, color: color)
                .scaleEffect(running ? 1 : 0.4)
                .opacity(running ? 1 : 0)
                .rotationEffect(.degrees(running ? 0 : -90))
            GadgetIcon(glyph: .play, size: size, color: color)
                .scaleEffect(running ? 0.4 : 1)
                .opacity(running ? 0 : 1)
                .rotationEffect(.degrees(running ? 90 : 0))
        }
        .animation(GadgetMotion.bouncy, value: running)
    }
}
