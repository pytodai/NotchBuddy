import SwiftUI
import NotchBuddyCore

// MARK: - Calendar page

/// A tear-off calendar page: a red band with two binder rings over a white sheet with the day number.
/// Drawn, not a symbol, so it stays crisp from 16 to 64 pt.
struct CalendarPageGlyph: View {
    var day: Int
    var size: CGFloat
    var band: Color = CalendarPalette.today
    /// Tilt, in degrees (the empty and connect states lean it a little).
    var tilt: Double = 0

    var body: some View {
        let radius = size * 0.24
        let bandHeight = size * 0.3
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.99), Color(white: 0.86)], startPoint: .top, endPoint: .bottom))
            UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                   topTrailingRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [band.calendarBlend(.white, 0.12), band.calendarBlend(.black, 0.12)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: bandHeight)
            // Binder rings.
            HStack(spacing: size * 0.3) {
                ForEach(0..<2, id: \.self) { _ in
                    Capsule()
                        .fill(Color(white: 0.97))
                        .frame(width: max(1.2, size * 0.075), height: size * 0.17)
                        .shadow(color: .black.opacity(0.25), radius: size * 0.01, y: size * 0.01)
                }
            }
            .offset(y: -size * 0.05)
            Text("\(day)")
                .font(CalendarType.font(size * 0.46, .heavy))
                .monospacedDigit()
                .tracking(-size * 0.015)
                .foregroundStyle(Color(white: 0.1))
                .frame(maxHeight: .infinity)
                .padding(.top, bandHeight * 0.95)
                .minimumScaleFactor(0.5)
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
        .rotationEffect(.degrees(tilt))
        .accessibilityHidden(true)
    }
}

// MARK: - Video call

/// A video camera: a rounded body and a lens wedge.
struct VideoCallShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let bodyWidth = r.width * 0.66
        let body = CGRect(x: r.minX, y: r.minY + r.height * 0.18, width: bodyWidth, height: r.height * 0.64)
        p.addRoundedRect(in: body, cornerSize: CGSize(width: r.height * 0.2, height: r.height * 0.2), style: .continuous)
        let x0 = body.maxX + r.width * 0.05
        p.move(to: CGPoint(x: x0, y: r.midY - r.height * 0.1))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.24))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - r.height * 0.24))
        p.addLine(to: CGPoint(x: x0, y: r.midY + r.height * 0.1))
        p.closeSubpath()
        return p
    }
}

/// A call service's badge: a small monochrome camera on a gray tile (the service's name sits beside it).
struct MeetingBadge: View {
    let service: MeetingService
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(Color.white.opacity(0.14))
            VideoCallShape()
                .fill(Color.white.opacity(0.78))
                .frame(width: size * 0.56, height: size * 0.38)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Countdown

/// A ring that empties as a start approaches, around a mark (the call badge, or a small calendar page).
struct CountdownRing: View {
    /// 1 → full ring (far away), 0 → empty (starting now).
    var fraction: Double
    var tint: Color
    var size: CGFloat
    var lineWidth: CGFloat = 2.2

    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(CalendarPalette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0.001), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // Counter-clockwise, like a clock hand winding down.
                .scaleEffect(x: -1, y: 1)
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.7, dampingFraction: 0.82)
                    .speed(IslandMotion.speed), value: fraction)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Sparkles

/// A four-pointed sparkle.
struct SparkleShape: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let w = r.width / 2, h = r.height / 2
        let k: CGFloat = 0.18
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - h))
        p.addQuadCurve(to: CGPoint(x: c.x + w, y: c.y), control: CGPoint(x: c.x + w * k, y: c.y - h * k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + h), control: CGPoint(x: c.x + w * k, y: c.y + h * k))
        p.addQuadCurve(to: CGPoint(x: c.x - w, y: c.y), control: CGPoint(x: c.x - w * k, y: c.y + h * k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - h), control: CGPoint(x: c.x - w * k, y: c.y - h * k))
        p.closeSubpath()
        return p
    }
}

/// A sparkle that pops in once (after `delay`), then rests.
struct PoppingSparkle: View {
    var size: CGFloat
    var color: Color
    var delay: Double

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        let on = shown || staticRender
        SparkleShape()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(on ? 1 : 0.2)
            .rotationEffect(.degrees(on ? 0 : -60))
            .opacity(on ? 1 : 0)
            .onAppear {
                guard !shown, !staticRender else { return }
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.55).delay(delay).speed(IslandMotion.speed)) {
                        shown = true
                    }
                }
            }
    }
}

// MARK: - Illustrations

/// The widget's big picture for the empty, connect and denied states: a leaning calendar page that
/// floats up into place, with small white sparkles (empty, connect), a pale moon (evening) or a lock
/// (denied). No halo, no colored glow.
struct CalendarArt: View {
    enum Accent { case sparkles, moon, lock }

    var day: Int
    var accent: Accent
    var size: CGFloat = 54

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var landed = false

    var body: some View {
        let on = landed || staticRender
        ZStack {
            CalendarPageGlyph(day: day, size: size, tilt: on ? -7 : 4)
                .offset(y: on ? 0 : 10)
                .scaleEffect(on ? 1 : 0.86)
                .opacity(on ? 1 : 0)
            switch accent {
            case .sparkles:
                PoppingSparkle(size: size * 0.2, color: Color.white.opacity(0.85), delay: 0.22)
                    .offset(x: size * 0.62, y: -size * 0.48)
                PoppingSparkle(size: size * 0.13, color: Color.white.opacity(0.55), delay: 0.32)
                    .offset(x: -size * 0.66, y: -size * 0.2)
                PoppingSparkle(size: size * 0.1, color: Color.white.opacity(0.4), delay: 0.4)
                    .offset(x: size * 0.7, y: size * 0.34)
            case .moon:
                MoonShape()
                    .fill(Color(white: 0.86))
                    .frame(width: size * 0.38, height: size * 0.38)
                    .offset(x: size * 0.56, y: -size * 0.46)
                    .scaleEffect(on ? 1 : 0.4)
                    .opacity(on ? 1 : 0)
                PoppingSparkle(size: size * 0.13, color: Color.white.opacity(0.6), delay: 0.3)
                    .offset(x: -size * 0.64, y: -size * 0.3)
                PoppingSparkle(size: size * 0.09, color: Color.white.opacity(0.4), delay: 0.38)
                    .offset(x: -size * 0.5, y: size * 0.42)
            case .lock:
                ZStack {
                    Circle().fill(Color(white: 0.16))
                    Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
                    Image(systemName: "lock.fill")
                        .font(.system(size: size * 0.2, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
                .frame(width: size * 0.46, height: size * 0.46)
                .offset(x: size * 0.46, y: size * 0.4)
                .scaleEffect(on ? 1 : 0.3)
                .opacity(on ? 1 : 0)
            }
        }
        .frame(width: size * 1.9, height: size * 1.5)
        .onAppear {
            guard !landed, !staticRender else { return }
            if reduceMotion {
                landed = true
            } else {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.68).delay(0.08).speed(IslandMotion.speed)) {
                    landed = true
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A crescent moon.
struct MoonShape: Shape {
    func path(in r: CGRect) -> Path {
        let outer = Path(ellipseIn: r)
        let cut = Path(ellipseIn: r.offsetBy(dx: r.width * 0.34, dy: -r.height * 0.18))
        return outer.subtracting(cut)
    }
}

// MARK: - Live dot

/// "Сейчас": a small solid dot in the event's calendar color (no ring, no glow).
struct NowDot: View {
    var tint: Color
    var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: size, height: size)
    }
}
