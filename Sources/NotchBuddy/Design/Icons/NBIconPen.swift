import SwiftUI

/// Draws grid paths (24 × 24 units) into a `GraphicsContext` at the icon's size, with the set's one
/// stroke weight, round caps and joins.
struct NBIconPen {
    static let grid: CGFloat = 24
    /// Stroke weight in grid units.
    static let weight: CGFloat = 1.8
    /// Thinnest stroke in points (small sizes get relatively heavier lines, for legibility).
    static let minimumLineWidth: CGFloat = 1.25

    var ctx: GraphicsContext
    let unit: CGFloat
    let origin: CGPoint
    let lineWidth: CGFloat
    let ink: Color
    let tone: Color

    init(ctx: GraphicsContext, size: CGSize, ink: Color, tone: Color, weight: CGFloat = NBIconPen.weight) {
        self.ctx = ctx
        let side = min(size.width, size.height)
        unit = side / Self.grid
        origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
        lineWidth = max(Self.minimumLineWidth, weight * unit)
        self.ink = ink
        self.tone = tone
    }

    /// Stroke width in grid units (for geometry that must clear a stroke).
    var lineWidthInGrid: CGFloat { lineWidth / unit }

    private var transform: CGAffineTransform {
        CGAffineTransform(a: unit, b: 0, c: 0, d: unit, tx: origin.x, ty: origin.y)
    }

    func place(_ path: Path) -> Path { path.applying(transform) }

    func stroke(_ path: Path, _ color: Color? = nil, opacity: Double = 1, width: CGFloat = 1) {
        guard opacity > 0.001 else { return }
        ctx.stroke(place(path), with: .color((color ?? ink).opacity(opacity)),
                   style: StrokeStyle(lineWidth: lineWidth * width, lineCap: .round, lineJoin: .round))
    }

    func fill(_ path: Path, _ color: Color? = nil, opacity: Double = 1, evenOdd: Bool = false) {
        guard opacity > 0.001 else { return }
        ctx.fill(place(path), with: .color((color ?? ink).opacity(opacity)), style: FillStyle(eoFill: evenOdd))
    }

    /// Solid shape with rounded corners: fill and stroke in the same color.
    func solid(_ path: Path, _ color: Color? = nil, opacity: Double = 1) {
        fill(path, color, opacity: opacity)
        stroke(path, color, opacity: opacity)
    }

    /// Two-tone: a soft fill under the line.
    func duo(_ path: Path, opacity: Double = 1, evenOdd: Bool = false) {
        fill(path, tone, opacity: opacity, evenOdd: evenOdd)
        stroke(path, opacity: opacity)
    }

    /// A copy whose drawing skips `path` (grid space).
    func excluding(_ path: Path) -> NBIconPen {
        var copy = self
        copy.ctx.clip(to: place(path), options: .inverse)
        return copy
    }

    /// A copy whose drawing stays inside `path` (grid space).
    func clipped(to path: Path) -> NBIconPen {
        var copy = self
        copy.ctx.clip(to: place(path))
        return copy
    }

    func withOpacity(_ opacity: Double) -> NBIconPen {
        var copy = self
        copy.ctx.opacity *= opacity
        return copy
    }
}

// MARK: - Grid geometry

enum G {
    static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    static func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> Path {
        var p = Path()
        p.move(to: pt(x1, y1))
        p.addLine(to: pt(x2, y2))
        return p
    }

    static func poly(_ points: [CGPoint], closed: Bool = false) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first)
        for point in points.dropFirst() { p.addLine(to: point) }
        if closed { p.closeSubpath() }
        return p
    }

    static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
    }

    static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry))
    }

    static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: min(r, w / 2, h / 2), style: .continuous)
    }

    /// Point on a circle; angle in degrees, 0 = right, clockwise on screen (y down).
    static func polar(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ degrees: Double) -> CGPoint {
        let a = degrees * .pi / 180
        return pt(cx + r * CGFloat(cos(a)), cy + r * CGFloat(sin(a)))
    }

    /// Arc as a sampled polyline (exact direction control), degrees clockwise on screen.
    static func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, from a0: Double, to a1: Double, into path: inout Path, move: Bool) {
        let steps = max(4, Int(abs(a1 - a0) / 4))
        for i in 0...steps {
            let a = a0 + (a1 - a0) * Double(i) / Double(steps)
            let point = polar(cx, cy, r, a)
            if i == 0 && move { path.move(to: point) } else { path.addLine(to: point) }
        }
    }

    static func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, from a0: Double, to a1: Double) -> Path {
        var p = Path()
        arc(cx, cy, r, from: a0, to: a1, into: &p, move: true)
        return p
    }

    /// Pie wedge from `a0` to `a1` (degrees, clockwise on screen).
    static func wedge(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, from a0: Double, to a1: Double) -> Path {
        var p = Path()
        p.move(to: pt(cx, cy))
        arc(cx, cy, r, from: a0, to: a1, into: &p, move: false)
        p.closeSubpath()
        return p
    }

    /// Rounded polygon through `points` (each corner rounded by `r`).
    static func roundedPoly(_ points: [CGPoint], r: CGFloat) -> Path {
        var p = Path()
        let n = points.count
        guard n > 2 else { return poly(points) }
        let start = mid(points[n - 1], points[0])
        p.move(to: start)
        for i in 0..<n {
            p.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % n], radius: r)
        }
        p.closeSubpath()
        return p
    }

    static func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { pt((a.x + b.x) / 2, (a.y + b.y) / 2) }

    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        pt(a.x + (b.x - a.x) * CGFloat(t), a.y + (b.y - a.y) * CGFloat(t))
    }

    /// Crescent: circle 1 minus circle 2 (sampled).
    static func crescent(c1: CGPoint, r1: CGFloat, c2: CGPoint, r2: CGFloat) -> Path {
        let dx = c2.x - c1.x, dy = c2.y - c1.y
        let d = sqrt(dx * dx + dy * dy)
        guard d > abs(r1 - r2), d < r1 + r2 else { return circle(c1.x, c1.y, r1) }
        let a = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
        let h = sqrt(max(r1 * r1 - a * a, 0))
        let base = pt(c1.x + a * dx / d, c1.y + a * dy / d)
        let p1 = pt(base.x + h * dy / d, base.y - h * dx / d)
        let p2 = pt(base.x - h * dy / d, base.y + h * dx / d)
        func angle(_ c: CGPoint, _ p: CGPoint) -> Double { Double(atan2(p.y - c.y, p.x - c.x)) * 180 / .pi }
        func norm(_ x: Double) -> Double { let v = x.truncatingRemainder(dividingBy: 360); return v < 0 ? v + 360 : v }
        // Outer arc on circle 1, p1 → p2, the way that does not pass circle 2.
        let t1 = angle(c1, p1)
        let span = norm(angle(c1, p2) - t1)
        let outerEnd = norm(angle(c1, c2) - t1) < span ? t1 - (360 - span) : t1 + span
        var path = Path()
        arc(c1.x, c1.y, r1, from: t1, to: outerEnd, into: &path, move: true)
        // Inner arc on circle 2, p2 → p1, the way that passes inside circle 1.
        let u0 = angle(c2, p2)
        let spanU = norm(angle(c2, p1) - u0)
        let innerEnd = norm(angle(c2, c1) - u0) < spanU ? u0 + spanU : u0 - (360 - spanU)
        arc(c2.x, c2.y, r2, from: u0, to: innerEnd, into: &path, move: false)
        path.closeSubpath()
        return path
    }

    /// Four-point star (concave sides).
    static func star(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, pinch: CGFloat = 0.16) -> Path {
        let k = r * pinch
        var p = Path()
        p.move(to: pt(cx, cy - r))
        p.addQuadCurve(to: pt(cx + r, cy), control: pt(cx + k, cy - k))
        p.addQuadCurve(to: pt(cx, cy + r), control: pt(cx + k, cy + k))
        p.addQuadCurve(to: pt(cx - r, cy), control: pt(cx - k, cy + k))
        p.addQuadCurve(to: pt(cx, cy - r), control: pt(cx - k, cy - k))
        p.closeSubpath()
        return p
    }
}

extension Path {
    func rotated(_ degrees: Double, around c: CGPoint) -> Path {
        guard degrees != 0 else { return self }
        let t = CGAffineTransform(translationX: c.x, y: c.y)
            .rotated(by: CGFloat(degrees * .pi / 180))
            .translatedBy(x: -c.x, y: -c.y)
        return applying(t)
    }

    func moved(_ dx: CGFloat, _ dy: CGFloat) -> Path {
        guard dx != 0 || dy != 0 else { return self }
        return applying(CGAffineTransform(translationX: dx, y: dy))
    }

    func scaled(_ s: CGFloat, around c: CGPoint) -> Path {
        scaled(s, s, around: c)
    }

    func scaled(_ sx: CGFloat, _ sy: CGFloat, around c: CGPoint) -> Path {
        guard sx != 1 || sy != 1 else { return self }
        let t = CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: sx, y: sy).translatedBy(x: -c.x, y: -c.y)
        return applying(t)
    }

    func trimmed(_ from: Double, _ to: Double) -> Path {
        trimmedPath(from: CGFloat(NBMath.clamp01(from)), to: CGFloat(NBMath.clamp01(to)))
    }
}
