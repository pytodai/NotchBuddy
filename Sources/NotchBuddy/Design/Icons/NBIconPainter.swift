import SwiftUI

/// The inputs an icon is drawn from.
struct NBIconState: Equatable {
    /// Hover gesture progress (0 rest, 1 hovered; springs may overshoot).
    var hover: Double = 0
    /// The state the icon shows (see `NBIcon.defaultValue`).
    var value: Double = 0
    /// Loop phase 0 ..< 1.
    var phase: Double = 0
}

/// Draws every `NBIcon` on the 24-unit grid. Pure functions of `NBIconState`: the same numbers always
/// give the same picture, which is what lets the design sheet film any in-between frame.
enum NBIconPainter {
    typealias M = NBMath

    static func draw(_ icon: NBIcon, pen: NBIconPen, state s: NBIconState, accent: Color?) {
        switch icon {
        case .terminal: terminal(pen, s)
        case .edit: edit(pen, s)
        case .read: read(pen, s)
        case .search: search(pen, s)
        case .web: web(pen, s)
        case .agent: agent(pen, s)
        case .mcp: mcp(pen, s)
        case .wrench: wrench(pen, s)
        case .plan: plan(pen, s)
        case .question: question(pen, s)
        case .working: working(pen, s)
        case .waiting: waiting(pen, s)
        case .done: done(pen, s)
        case .error: error(pen, s)
        case .idle: idle(pen, s)
        case .settings: gear(pen, s)
        case .soundOn, .soundOff: sound(pen, s)
        case .pin: pin(pen, s)
        case .jump: jump(pen, s)
        case .copy: copy(pen, s)
        case .folder: folder(pen, s)
        case .check: check(pen, s)
        case .close: close(pen, s)
        case .chevron: chevron(pen, s)
        case .bell: bell(pen, s)
        case .sparkle: sparkle(pen, s)
        case .play, .pause: playPause(pen, s)
        case .next: skip(pen, s, forward: true)
        case .previous: skip(pen, s, forward: false)
        case .calendar: calendar(pen, s)
        case .timer: timer(pen, s)
        case .battery: battery(pen, s, accent: accent)
        case .cpu: cpu(pen, s)
        case .tray: tray(pen, s)
        case .music: music(pen, s)
        }
    }

    private static let center = G.pt(12, 12)

    // MARK: Tools

    static func terminal(_ pen: NBIconPen, _ s: NBIconState) {
        pen.duo(G.rect(3, 4.4, 18, 15.2, r: 3.4))
        let dx = 0.9 * CGFloat(s.hover)
        pen.stroke(G.poly([G.pt(7.2 + dx, 9.4), G.pt(10.3 + dx, 12), G.pt(7.2 + dx, 14.6)]))
        let blink = s.phase < 0.55 ? 1.0 : 0.18
        let length = 3.8 + 1.6 * CGFloat(s.hover)
        pen.stroke(G.line(12.4 + dx, 14.6, 12.4 + dx + length, 14.6), opacity: blink)
    }

    static func edit(_ pen: NBIconPen, _ s: NBIconState) {
        let h = s.hover
        // The line it writes, from the tip rightwards.
        let written = 0.34 + 0.66 * M.easeOut(h)
        pen.stroke(G.line(5.2, 20.4, 19.6, 20.4).trimmed(0, written), opacity: 0.55 + 0.45 * h)
        // Pencil drawn horizontally (tip left), then turned to the diagonal.
        var body = Path()
        body.move(to: G.pt(3.9, 12))
        body.addLine(to: G.pt(7.6, 9.5))
        body.addLine(to: G.pt(17.8, 9.5))
        body.addArc(tangent1End: G.pt(20.3, 9.5), tangent2End: G.pt(20.3, 12), radius: 2.2)
        body.addArc(tangent1End: G.pt(20.3, 14.5), tangent2End: G.pt(17.8, 14.5), radius: 2.2)
        body.addLine(to: G.pt(7.6, 14.5))
        body.closeSubpath()
        let ferrule = G.line(16.4, 9.5, 16.4, 14.5)
        let tip = G.poly([G.pt(3.9, 12), G.pt(5.7, 10.8), G.pt(5.7, 13.2)], closed: true)
        let angle = -45 + 9 * M.wobble(h, cycles: 1.5)
        let shift = 2.2 * CGFloat(M.easeOut(h))
        func place(_ p: Path) -> Path { p.rotated(angle, around: center).moved(shift - 0.4, -1.2) }
        pen.duo(place(body))
        pen.stroke(place(ferrule))
        pen.solid(place(tip))
    }

    static func read(_ pen: NBIconPen, _ s: NBIconState) {
        let h = CGFloat(M.clamp01(s.hover))
        let lift = -0.5 * h
        var page = Path()
        page.move(to: G.pt(10, 3))
        page.addLine(to: G.pt(13.6, 3))
        page.addLine(to: G.pt(19, 8.4))
        page.addArc(tangent1End: G.pt(19, 21), tangent2End: G.pt(5, 21), radius: 2.8)
        page.addArc(tangent1End: G.pt(5, 21), tangent2End: G.pt(5, 3), radius: 2.8)
        page.addArc(tangent1End: G.pt(5, 3), tangent2End: G.pt(13.6, 3), radius: 2.8)
        page.closeSubpath()
        pen.duo(page.moved(0, lift))
        var fold = Path()
        fold.move(to: G.pt(13.6, 3))
        fold.addLine(to: G.pt(13.6, 6.4))
        fold.addArc(tangent1End: G.pt(13.6, 8.4), tangent2End: G.pt(15.6, 8.4), radius: 2)
        fold.addLine(to: G.pt(19, 8.4))
        pen.stroke(fold.moved(0, lift))
        pen.stroke(G.line(8.6, 12.4, 15.4, 12.4).moved(0, lift))
        pen.stroke(G.line(8.6, 16.2, 12.4 + 3 * h, 16.2).moved(0, lift))
        pen.stroke(G.line(8.6, 8.6, 10.2 + 0.4 * h, 8.6).moved(0, lift), opacity: 0.9)
    }

    static func search(_ pen: NBIconPen, _ s: NBIconState) {
        let h = s.hover
        let orbit = 2 * Double.pi * s.phase
        let ox = CGFloat(cos(orbit)) * 1.1 * CGFloat(s.phase == 0 ? 0 : 1)
        let oy = CGFloat(sin(orbit)) * 1.1 * CGFloat(s.phase == 0 ? 0 : 1)
        let tilt = -14 * h
        let c = G.pt(10.4, 10.4)
        let lens = G.circle(c.x, c.y, 6.3)
        let handle = G.line(15.1, 15.1, 20.2, 20.2)
        let glint = G.arc(c.x, c.y, 3.5, from: 200, to: 250)
        func place(_ p: Path) -> Path { p.rotated(tilt, around: G.pt(15.1, 15.1)).moved(ox, oy) }
        pen.duo(place(lens))
        pen.stroke(place(handle))
        pen.stroke(place(glint), opacity: 0.7)
    }

    static func web(_ pen: NBIconPen, _ s: NBIconState) {
        let r: CGFloat = 8.7
        pen.duo(G.circle(12, 12, r))
        let spin = 0.5 * M.clamp01(s.hover) + s.phase
        let theta = 0.47 + .pi * spin
        let w1 = r * CGFloat(abs(sin(theta)))
        let w2 = r * CGFloat(abs(sin(theta + .pi / 2)))
        let clip = pen.clipped(to: G.circle(12, 12, r))
        clip.stroke(G.ellipse(12, 12, max(w1, 0.01), r))
        // The second meridian shows only while turning.
        let turning = min(1, 4 * abs(sin(.pi * spin)))
        clip.stroke(G.ellipse(12, 12, max(w2, 0.01), r), opacity: turning * 0.55)
        pen.stroke(G.line(12 - r, 12, 12 + r, 12))
    }

    static func agent(_ pen: NBIconPen, _ s: NBIconState) {
        let h = M.clamp01(s.hover)
        let hop = -1.3 * CGFloat(M.bump(M.segment(s.hover, 0, 1)))
        pen.stroke(G.line(12, 8.2, 12, 5.6 + hop))
        pen.solid(G.circle(12, 4.3 + hop, 1.2))
        pen.duo(G.rect(4.6, 8.2, 14.8, 11.8, r: 4.2))
        // Ears.
        pen.stroke(G.line(2.6, 12.6, 2.6, 15.4))
        pen.stroke(G.line(21.4, 12.6, 21.4, 15.4))
        // Eyes: blink in the loop, smile on hover.
        let blinkWindow = M.segment(s.phase, 0.9, 0.97)
        let open = 1 - 0.85 * M.bump(blinkWindow)
        for x in [9.4, 14.6] as [CGFloat] {
            let half = 1.2 * CGFloat(open)
            pen.stroke(G.line(x, 14 - half, x, 14 + half), opacity: 1 - h)
            var smile = Path()
            smile.move(to: G.pt(x - 1.4, 14.6))
            smile.addQuadCurve(to: G.pt(x + 1.4, 14.6), control: G.pt(x, 12.2))
            pen.stroke(smile, opacity: h)
        }
    }

    static func mcp(_ pen: NBIconPen, _ s: NBIconState) {
        let h = M.clamp01(s.hover)
        let up = -1.4 * CGFloat(h)
        var body = Path()
        body.move(to: G.pt(6, 7.6))
        body.addLine(to: G.pt(18, 7.6))
        body.addLine(to: G.pt(18, 10.6))
        body.addQuadCurve(to: G.pt(12, 16.4), control: G.pt(18, 16.4))
        body.addQuadCurve(to: G.pt(6, 10.6), control: G.pt(6, 16.4))
        body.closeSubpath()
        pen.stroke(G.line(9.6, 3.4, 9.6, 7.6).moved(0, up))
        pen.stroke(G.line(14.4, 3.4, 14.4, 7.6).moved(0, up))
        pen.duo(body.moved(0, up))
        var cable = Path()
        cable.move(to: G.pt(12, 16.4 + up))
        cable.addLine(to: G.pt(12, 18.2))
        cable.addQuadCurve(to: G.pt(15.2, 21.2), control: G.pt(12, 21.2))
        pen.stroke(cable)
        // Contact sparks while plugging in.
        let spark = M.bump(M.segment(s.hover, 0.35, 1))
        if spark > 0.01 {
            pen.stroke(G.line(5.2, 3.2, 6.6, 4.4), opacity: spark)
            pen.stroke(G.line(18.8, 3.2, 17.4, 4.4), opacity: spark)
        }
    }

    static func wrench(_ pen: NBIconPen, _ s: NBIconState) {
        let head = G.pt(17.2, 12)
        let r: CGFloat = 4.3
        let half: CGFloat = 1.75
        let handleStart: CGFloat = 4.9
        let meet = head.x - sqrt(r * r - half * half)
        let meetAngle = Double(atan2(-half, meet - head.x)) * 180 / .pi  // ≈ -156
        var p = Path()
        p.move(to: G.pt(handleStart, 12 - half))
        p.addLine(to: G.pt(meet, 12 - half))
        G.arc(head.x, head.y, r, from: meetAngle + 360, to: 360 - 34, into: &p, move: false)
        p.addLine(to: G.pt(head.x + 0.9, 12 - 1.5))
        p.addLine(to: G.pt(head.x + 0.9, 12 + 1.5))
        G.arc(head.x, head.y, r, from: 34, to: -meetAngle, into: &p, move: false)
        p.addLine(to: G.pt(handleStart, 12 + half))
        G.arc(handleStart, 12, half, from: 90, to: 270, into: &p, move: false)
        p.closeSubpath()
        let twist = 16 * M.wobble(s.hover, cycles: 1.2)
        let placed = p.rotated(-45, around: center).moved(0.4, 0.2)
        let pivot = G.pt(15.6, 8.4)
        pen.duo(placed.rotated(twist, around: pivot))
    }

    static func plan(_ pen: NBIconPen, _ s: NBIconState) {
        let board = G.rect(4.6, 4.6, 14.8, 16.6, r: 3)
        let clip = G.rect(8.6, 2.6, 6.8, 3.8, r: 1.6)
        pen.excluding(clip.scaled(1.25, around: G.pt(12, 4.5))).duo(board)
        pen.duo(clip)
        // Row 1: done.
        pen.stroke(G.poly([G.pt(7.8, 11.2), G.pt(9.1, 12.5), G.pt(11.2, 10.2)]))
        pen.stroke(G.line(13.2, 11.4, 16.6, 11.4))
        // Row 2: a dot that becomes a check.
        let h = M.clamp01(s.hover)
        pen.solid(G.circle(9.4, 16.2, 0.9), opacity: 1 - h)
        pen.stroke(G.poly([G.pt(7.8, 16), G.pt(9.1, 17.3), G.pt(11.2, 15)]).trimmed(0, h))
        pen.stroke(G.line(13.2, 16.2, 15.6 + CGFloat(h), 16.2))
    }

    static func question(_ pen: NBIconPen, _ s: NBIconState) {
        pen.duo(G.circle(12, 12, 8.7))
        var q = Path()
        q.move(to: G.pt(9.5, 9.7))
        q.addCurve(to: G.pt(14.5, 9.6), control1: G.pt(9.5, 6.5), control2: G.pt(14.5, 6.5))
        q.addCurve(to: G.pt(12, 13.4), control1: G.pt(14.5, 11.6), control2: G.pt(12, 11.6))
        q.addLine(to: G.pt(12, 13.8))
        let angle = 16 * M.wobble(s.hover, cycles: 1.5)
        let lift = -0.8 * CGFloat(M.bump(M.segment(s.hover, 0, 0.5)))
        let pivot = G.pt(12, 17)
        pen.stroke(q.rotated(angle, around: pivot).moved(0, lift))
        pen.solid(G.circle(12, 16.9, 1.05).moved(0, lift))
    }

    // MARK: Statuses

    static func working(_ pen: NBIconPen, _ s: NBIconState) {
        let r: CGFloat = 8.2
        pen.stroke(G.circle(12, 12, r), pen.tone.opacity(1), opacity: 1)
        let spin = s.phase * 360 + 120 * s.hover
        let length = 100 + 40 * sin(2 * .pi * s.phase)
        let start = -90 + spin
        pen.stroke(G.arc(12, 12, r, from: start, to: start + length))
        pen.solid(G.circle(12, 12, 1.5), opacity: 0.9)
    }

    static func waiting(_ pen: NBIconPen, _ s: NBIconState) {
        // 0 … 0.8: sand runs; 0.8 … 1: the glass turns over.
        let run = M.easeInOut(M.segment(s.phase, 0.0, 0.8))
        let flip = M.easeInOut(M.segment(s.phase, 0.8, 1.0))
        let angle = 180 * flip + 10 * M.wobble(s.hover, cycles: 1)
        var glass = Path()
        glass.move(to: G.pt(7.6, 4))
        glass.addQuadCurve(to: G.pt(11, 12), control: G.pt(7.6, 9.2))
        glass.addQuadCurve(to: G.pt(7.6, 20), control: G.pt(7.6, 14.8))
        glass.addLine(to: G.pt(16.4, 20))
        glass.addQuadCurve(to: G.pt(13, 12), control: G.pt(16.4, 14.8))
        glass.addQuadCurve(to: G.pt(16.4, 4), control: G.pt(16.4, 9.2))
        glass.closeSubpath()
        func place(_ p: Path) -> Path { p.rotated(angle, around: center) }
        pen.fill(place(glass), pen.tone)
        let inside = pen.clipped(to: place(glass))
        let top = 1 - run
        if top > 0.01 {
            let level = 12 - 6.8 * CGFloat(top)
            inside.fill(place(G.rect(4, level, 16, 12 - level + 0.3, r: 0)), pen.ink, opacity: 0.85)
        }
        if run > 0.01 {
            // A mound: higher in the middle.
            let height = 6.6 * CGFloat(run)
            var mound = Path()
            mound.move(to: G.pt(5, 20.5))
            mound.addLine(to: G.pt(5, 20.4 - height * 0.55))
            mound.addQuadCurve(to: G.pt(19, 20.4 - height * 0.55), control: G.pt(12, 20.4 - height * 1.45))
            mound.addLine(to: G.pt(19, 20.5))
            mound.closeSubpath()
            inside.fill(place(mound), pen.ink, opacity: 0.85)
        }
        if run > 0.02 && run < 0.98 && flip == 0 {
            pen.stroke(place(G.line(12, 12.4, 12, 19.6 - 5 * CGFloat(run))), opacity: 0.85, width: 0.55)
        }
        pen.stroke(place(glass))
        pen.stroke(place(G.line(6, 4, 18, 4)))
        pen.stroke(place(G.line(6, 20, 18, 20)))
    }

    static func done(_ pen: NBIconPen, _ s: NBIconState) {
        let v = s.value
        let grow = 0.55 + 0.45 * M.easeOut(M.segment(v, 0, 0.45))
        let overshoot = 0.08 * M.bump(M.segment(v, 0.3, 0.7))
        let bounce = 0.07 * M.bump(M.clamp01(s.hover))
        let scale = CGFloat(grow + overshoot + bounce)
        let circle = G.circle(12, 12, 8.7).scaled(scale, around: center)
        pen.duo(circle, opacity: M.clamp01(v * 3))
        let check = G.poly([G.pt(7.8, 12.4), G.pt(10.7, 15.2), G.pt(16.3, 9.2)]).scaled(scale, around: center)
        pen.stroke(check.trimmed(0, M.easeOut(M.segment(v, 0.3, 0.8))))
        // Burst: eight rays fly out and fade.
        let burst = M.segment(v, 0.5, 1.0)
        if burst > 0 && burst < 1 {
            let alpha = 1 - burst
            let inner = 9.6 + 2.2 * CGFloat(M.easeOut(burst))
            let outer = inner + 1.6 * CGFloat(1 - burst) + 0.4
            for i in 0..<8 {
                let a = Double(i) * 45 - 90 + 22.5
                pen.stroke(G.poly([G.polar(12, 12, inner, a), G.polar(12, 12, outer, a)]), opacity: alpha)
            }
        }
    }

    static func error(_ pen: NBIconPen, _ s: NBIconState) {
        let shake = CGFloat(1.8 * M.wobble(s.hover, cycles: 3))
        let triangle = G.roundedPoly([G.pt(12, 3.6), G.pt(21, 19.6), G.pt(3, 19.6)], r: 2.2).moved(shake, 0)
        pen.duo(triangle)
        pen.stroke(G.line(12, 9.4, 12, 13.4).moved(shake, 0))
        pen.solid(G.circle(12, 16.4, 1.05).moved(shake, 0))
    }

    static func idle(_ pen: NBIconPen, _ s: NBIconState) {
        let rock = 8 * M.wobble(s.hover, cycles: 1)
        let moon = G.crescent(c1: G.pt(11, 13.2), r1: 7.6, c2: G.pt(15.6, 8.6), r2: 6.2)
        pen.duo(moon.rotated(rock, around: G.pt(11, 13.2)))
        // "z" floats up and fades; a second one follows.
        for k in 0..<2 {
            let p = (s.phase + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
            let size: CGFloat = k == 0 ? 3.1 : 2.2
            let x: CGFloat = k == 0 ? 15.8 : 18.9
            let y: CGFloat = (k == 0 ? 8.2 : 6.2) - 1.6 * CGFloat(p)
            let alpha = p < 0.15 ? p / 0.15 : (p > 0.7 ? (1 - p) / 0.3 : 1)
            let z = G.poly([G.pt(x, y - size), G.pt(x + size, y - size), G.pt(x, y), G.pt(x + size, y)])
            pen.stroke(z, opacity: alpha, width: k == 0 ? 0.85 : 0.75)
        }
    }

    // MARK: Actions

    static func gear(_ pen: NBIconPen, _ s: NBIconState, teeth: Int = 7) {
        let rOut: CGFloat = 9.6, rIn: CGFloat = 7.3
        let step = 360.0 / Double(teeth)
        let baseHalf = step * 0.25, topHalf = step * 0.15
        let rotation = step * s.hover + 360 * s.phase
        var p = Path()
        for i in 0..<teeth {
            let c = Double(i) * step - 90 + rotation
            let a0 = G.polar(12, 12, rIn, c - baseHalf)
            if i == 0 { p.move(to: a0) } else { p.addLine(to: a0) }
            p.addLine(to: G.polar(12, 12, rOut, c - topHalf))
            p.addLine(to: G.polar(12, 12, rOut, c + topHalf))
            p.addLine(to: G.polar(12, 12, rIn, c + baseHalf))
            G.arc(12, 12, rIn, from: c + baseHalf, to: c + step - baseHalf, into: &p, move: false)
        }
        p.closeSubpath()
        var body = p
        body.addPath(G.circle(12, 12, 3.1))
        pen.fill(body, pen.tone, evenOdd: true)
        pen.stroke(p)
        pen.stroke(G.circle(12, 12, 3.1))
    }

    static func sound(_ pen: NBIconPen, _ s: NBIconState) {
        let on = M.clamp01(s.value)
        var speaker = Path()
        speaker.move(to: G.pt(3.4, 9.4))
        speaker.addLine(to: G.pt(7, 9.4))
        speaker.addLine(to: G.pt(11.6, 5))
        speaker.addLine(to: G.pt(11.6, 19))
        speaker.addLine(to: G.pt(7, 14.6))
        speaker.addLine(to: G.pt(3.4, 14.6))
        speaker.closeSubpath()
        pen.duo(speaker)
        // Waves: ripple on hover, breathe in the loop, shrink away when muted.
        for (k, radius) in [(0, 4.4), (1, 8.0)] as [(Int, CGFloat)] {
            let ripple = 1.3 * M.bump(M.segment(s.hover, 0.18 * Double(k), 0.62 + 0.18 * Double(k)))
            let breathe = s.phase == 0 ? 1 : 0.45 + 0.55 * (0.5 + 0.5 * cos(2 * .pi * (s.phase - 0.2 * Double(k))))
            let shrink = 0.5 + 0.5 * on
            let r = (radius + CGFloat(ripple)) * CGFloat(shrink)
            let appear = M.segment(on, 0.25 * Double(k), 0.6 + 0.4 * Double(k))
            pen.stroke(G.arc(11.6, 12, r, from: -46, to: 46), opacity: appear * breathe)
        }
        // The cross draws in as the waves leave.
        let off = 1 - on
        if off > 0.01 {
            let x = G.line(15.8, 9.6, 20.4, 14.2).trimmed(0, M.segment(off, 0.2, 0.7))
            let y = G.line(20.4, 9.6, 15.8, 14.2).trimmed(0, M.segment(off, 0.45, 1))
            pen.stroke(x)
            pen.stroke(y)
        }
    }

    static func pin(_ pen: NBIconPen, _ s: NBIconState) {
        let pinned = s.value
        let h = M.clamp01(s.hover)
        // Unpinned: tilted 40°; hover straightens it a bit; pinned: upright and pressed in.
        let angle = (1 - pinned) * (40 - 14 * h)
        let press = CGFloat(0.9 * pinned) - CGFloat(0.6 * h * (1 - pinned))
        var body = Path()
        body.move(to: G.pt(9.4, 5.8))
        body.addLine(to: G.pt(9.1, 10.3))
        body.addLine(to: G.pt(6.4, 13.6))
        body.addLine(to: G.pt(17.6, 13.6))
        body.addLine(to: G.pt(14.9, 10.3))
        body.addLine(to: G.pt(14.6, 5.8))
        body.closeSubpath()
        let cap = G.rect(7.6, 2.6, 8.8, 3.4, r: 1.7)
        let needleEnd = 21 - 1.6 * CGFloat(pinned)
        func place(_ p: Path) -> Path { p.moved(0, press).rotated(angle, around: center) }
        pen.stroke(place(G.line(12, 13.6, 12, needleEnd)))
        pen.duo(place(body))
        pen.duo(place(cap))
    }

    static func jump(_ pen: NBIconPen, _ s: NBIconState) {
        var box = Path()
        box.move(to: G.pt(10.4, 4.6))
        box.addLine(to: G.pt(7.4, 4.6))
        box.addArc(tangent1End: G.pt(4.6, 4.6), tangent2End: G.pt(4.6, 12), radius: 2.8)
        box.addArc(tangent1End: G.pt(4.6, 19.4), tangent2End: G.pt(12, 19.4), radius: 2.8)
        box.addArc(tangent1End: G.pt(19.4, 19.4), tangent2End: G.pt(19.4, 12), radius: 2.8)
        box.addLine(to: G.pt(19.4, 13.6))
        pen.fill(G.rect(4.6, 4.6, 14.8, 14.8, r: 2.8), pen.tone)
        pen.stroke(box)
        // The arrow flies out to the top right and comes back in from the box.
        let h = s.hover
        let travel: CGFloat = 5.5
        let d: CGFloat = h < 0.5 ? CGFloat(2 * h) * travel : CGFloat(2 * h - 2) * travel
        let alpha = h < 0.5 ? 1 - M.segment(h, 0.25, 0.5) : M.segment(h, 0.5, 0.75)
        let clipped = pen.clipped(to: G.rect(-2, -2, 25.5, 28, r: 0))
        clipped.stroke(G.line(11.2, 12.8, 19.2, 4.8).moved(d, -d), opacity: alpha)
        clipped.stroke(G.poly([G.pt(13.6, 4.8), G.pt(19.2, 4.8), G.pt(19.2, 10.4)]).moved(d, -d), opacity: alpha)
    }

    static func copy(_ pen: NBIconPen, _ s: NBIconState) {
        let copied = M.clamp01(s.value)
        let h = CGFloat(M.clamp01(s.hover)) * CGFloat(1 - copied)
        let merge = CGFloat(M.easeInOut(copied))
        let frontSide = 11 + 4 * merge
        let frontOrigin = 8.8 + 0.7 * h - (8.8 - 12 + frontSide / 2) * merge
        let front = G.rect(frontOrigin, frontOrigin, frontSide, frontSide, r: 2.8 + 0.6 * merge)
        let back = G.rect(4.2 - 0.4 * h + 2.2 * merge, 4.2 - 0.4 * h + 2.2 * merge, 11, 11, r: 2.8)
        pen.excluding(front).stroke(back, opacity: 1 - Double(merge))
        pen.duo(front)
        let check = G.poly([G.pt(8.6, 12.2), G.pt(10.9, 14.5), G.pt(15.4, 9.6)])
        pen.stroke(check.trimmed(0, M.segment(copied, 0.4, 1)))
    }

    static func folder(_ pen: NBIconPen, _ s: NBIconState) {
        let h = CGFloat(M.clamp01(s.hover))
        var back = Path()
        back.move(to: G.pt(3.4, 12))
        back.addArc(tangent1End: G.pt(3.4, 4.8), tangent2End: G.pt(9.2, 4.8), radius: 2.4)
        back.addLine(to: G.pt(9.2, 4.8))
        back.addLine(to: G.pt(11.2, 7))
        back.addArc(tangent1End: G.pt(20.6, 7), tangent2End: G.pt(20.6, 12), radius: 2.4)
        back.addArc(tangent1End: G.pt(20.6, 19.8), tangent2End: G.pt(12, 19.8), radius: 2.4)
        back.addArc(tangent1End: G.pt(3.4, 19.8), tangent2End: G.pt(3.4, 12), radius: 2.4)
        back.closeSubpath()
        pen.fill(back, pen.tone)
        pen.stroke(back)
        // A sheet peeks out as the lid opens.
        if h > 0.01 {
            pen.stroke(G.rect(6.6, 8.6 - 1.6 * h, 10.8, 7, r: 1.2), opacity: Double(h))
        }
        let top = 10.8 + 2.2 * h
        let lid = G.roundedPoly([G.pt(3.4 + 2.2 * h, top), G.pt(20.6 + 1.2 * h, top),
                                 G.pt(20.6, 19.8), G.pt(3.4, 19.8)], r: 1.8)
        pen.fill(lid, pen.tone)
        pen.fill(lid, pen.tone)
        pen.stroke(lid)
    }

    static func check(_ pen: NBIconPen, _ s: NBIconState) {
        let scale = CGFloat(1 + 0.1 * M.bump(M.clamp01(s.hover)))
        let mark = G.poly([G.pt(5.4, 12.6), G.pt(9.8, 17), G.pt(18.6, 7.4)]).scaled(scale, around: center)
        pen.stroke(mark.trimmed(0, M.easeOut(s.value)), width: 1.08)
    }

    static func close(_ pen: NBIconPen, _ s: NBIconState) {
        let angle = 90 * s.hover
        pen.stroke(G.line(7.2, 7.2, 16.8, 16.8).rotated(angle, around: center))
        pen.stroke(G.line(16.8, 7.2, 7.2, 16.8).rotated(angle, around: center))
    }

    static func chevron(_ pen: NBIconPen, _ s: NBIconState) {
        let angle = 180 * s.value
        let nudge = CGFloat(1.1 * M.clamp01(s.hover)) * (s.value < 0.5 ? 1 : -1)
        pen.stroke(G.poly([G.pt(6.6, 9.6), G.pt(12, 15), G.pt(17.4, 9.6)]).rotated(angle, around: center).moved(0, nudge))
    }

    static func bell(_ pen: NBIconPen, _ s: NBIconState) {
        let ringLoop = s.phase == 0 ? 0 : M.wobble(M.segment(s.phase, 0, 0.45), cycles: 2)
        let angle = 18 * (M.wobble(s.hover, cycles: 2) + ringLoop)
        let pivot = G.pt(12, 3.6)
        var body = Path()
        body.move(to: G.pt(4.4, 17.4))
        body.addQuadCurve(to: G.pt(6.4, 14.4), control: G.pt(6.4, 16.6))
        body.addLine(to: G.pt(6.4, 11))
        body.addCurve(to: G.pt(17.6, 11), control1: G.pt(6.4, 3.8), control2: G.pt(17.6, 3.8))
        body.addLine(to: G.pt(17.6, 14.4))
        body.addQuadCurve(to: G.pt(19.6, 17.4), control: G.pt(17.6, 16.6))
        body.closeSubpath()
        var clapper = Path()
        clapper.move(to: G.pt(9.8, 19.6))
        clapper.addQuadCurve(to: G.pt(14.2, 19.6), control: G.pt(12, 22))
        let swing = CGFloat(-1.2 * (M.wobble(s.hover, cycles: 2) + ringLoop))
        pen.stroke(clapper.rotated(angle, around: pivot).moved(swing, 0))
        pen.duo(body.rotated(angle, around: pivot))
        pen.stroke(G.line(12, 3, 12, 4.8).rotated(angle, around: pivot))
    }

    static func sparkle(_ pen: NBIconPen, _ s: NBIconState) {
        let spin = 90 * s.hover
        let breathe = s.phase == 0 ? 1 : 0.9 + 0.1 * cos(2 * .pi * s.phase)
        let big = G.star(10.4, 13.4, 8.2, pinch: 0.14)
            .rotated(spin, around: G.pt(10.4, 13.4))
            .scaled(CGFloat(breathe), around: G.pt(10.4, 13.4))
        pen.duo(big)
        let twinkle = s.phase == 0 ? 1 : 0.55 + 0.45 * (0.5 + 0.5 * cos(2 * .pi * (s.phase - 0.5)))
        let small = G.star(18.6, 5.4, 3.1, pinch: 0.16)
            .rotated(-spin, around: G.pt(18.6, 5.4))
            .scaled(CGFloat(0.75 + 0.25 * twinkle), around: G.pt(18.6, 5.4))
        pen.solid(small, opacity: twinkle)
    }

    // MARK: Media & widgets

    static func playPause(_ pen: NBIconPen, _ s: NBIconState) {
        let v = M.clamp01(s.value)
        let play: [[CGPoint]] = [
            [G.pt(7.6, 5.2), G.pt(13.1, 8.6), G.pt(13.1, 15.4), G.pt(7.6, 18.8)],
            [G.pt(13.1, 8.6), G.pt(18.6, 12), G.pt(18.6, 12), G.pt(13.1, 15.4)],
        ]
        let pause: [[CGPoint]] = [
            [G.pt(6.6, 5.2), G.pt(10.2, 5.2), G.pt(10.2, 18.8), G.pt(6.6, 18.8)],
            [G.pt(13.8, 5.2), G.pt(17.4, 5.2), G.pt(17.4, 18.8), G.pt(13.8, 18.8)],
        ]
        let scale = CGFloat(1 + 0.06 * M.clamp01(s.hover))
        var shape = Path()
        for i in 0..<2 {
            shape.addPath(G.poly((0..<4).map { G.lerp(play[i][$0], pause[i][$0], v) }, closed: true))
        }
        pen.solid(shape.scaled(scale, around: center))
    }

    static func skip(_ pen: NBIconPen, _ s: NBIconState, forward: Bool) {
        let h = CGFloat(M.clamp01(s.hover))
        let mirror: (Path) -> Path = { p in
            forward ? p : p.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 24, ty: 0))
        }
        let triangle = G.poly([G.pt(5.6, 6.4), G.pt(14.6, 12), G.pt(5.6, 17.6)], closed: true)
        pen.solid(mirror(triangle.moved(1.3 * h, 0)))
        // A ghost of the triangle trails behind while stepping.
        if h > 0.01 {
            pen.solid(mirror(triangle.moved(1.3 * h - 3.6, 0)), opacity: 0.28 * Double(h))
        }
        pen.stroke(mirror(G.line(18.2, 6.4, 18.2, 17.6)))
    }

    static func calendar(_ pen: NBIconPen, _ s: NBIconState) {
        let h = M.clamp01(s.hover)
        pen.duo(G.rect(3.6, 5.4, 16.8, 15.2, r: 3.2))
        pen.stroke(G.line(3.6, 10, 20.4, 10))
        let ring = -0.9 * CGFloat(M.bump(M.segment(s.hover, 0, 0.6)))
        pen.stroke(G.line(8.4, 3.2 + ring, 8.4, 7))
        pen.stroke(G.line(15.6, 3.2 + ring, 15.6, 7))
        let cells: [CGPoint] = [G.pt(7.8, 13.6), G.pt(12, 13.6), G.pt(16.2, 13.6),
                                G.pt(7.8, 17.2), G.pt(12, 17.2), G.pt(16.2, 17.2)]
        let from = cells[1], to = cells[2]
        let at = G.lerp(from, to, h)
        let hop = -1.4 * CGFloat(M.bump(h))
        for cell in cells where cell != from && cell != to {
            pen.fill(G.circle(cell.x, cell.y, 0.75), opacity: 0.55)
        }
        pen.fill(G.circle(from.x, from.y, 0.75), opacity: 0.55 * h)
        pen.fill(G.circle(to.x, to.y, 0.75), opacity: 0.55 * (1 - h))
        pen.solid(G.rect(at.x - 1.3, at.y - 1.3 + hop, 2.6, 2.6, r: 0.8))
    }

    static func timer(_ pen: NBIconPen, _ s: NBIconState) {
        let c = G.pt(12, 13.4)
        let r: CGFloat = 7.6
        pen.duo(G.circle(c.x, c.y, r))
        pen.stroke(G.line(10, 2.8, 14, 2.8))
        pen.stroke(G.line(12, 2.8, 12, 5.8))
        pen.stroke(G.line(18.1, 6.6, 19.4, 7.9))
        let fraction = s.phase > 0 ? s.phase : M.clamp01(s.value)
        let angle = -90 + 360 * fraction
        if fraction > 0.005 {
            pen.fill(G.wedge(c.x, c.y, r - 2.4, from: -90, to: angle), opacity: 0.2)
        }
        pen.stroke(G.poly([c, G.polar(c.x, c.y, 4.6, angle)]))
        pen.solid(G.circle(c.x, c.y, 0.9))
    }

    static func battery(_ pen: NBIconPen, _ s: NBIconState, accent: Color?) {
        let level = M.clamp01(s.value)
        pen.stroke(G.rect(2.6, 7.2, 17, 9.6, r: 3))
        pen.stroke(G.line(21.4, 10.6, 21.4, 13.4))
        let full: CGFloat = 12.6
        let width = max(0.01, full * CGFloat(level))
        let color = accent ?? (level > 0.5 ? NBAccent.done.base : level > 0.2 ? NBAccent.waiting.base : NBAccent.error.base)
        let glow = 0.75 + 0.25 * M.bump(M.clamp01(s.hover))
        pen.fill(G.rect(4.8, 9.4, width, 5.2, r: 1.3), color, opacity: glow)
    }

    static func cpu(_ pen: NBIconPen, _ s: NBIconState) {
        pen.duo(G.rect(6.2, 6.2, 11.6, 11.6, r: 2.6))
        let pulse = 1 + 0.22 * M.bump(M.clamp01(s.hover))
        pen.solid(G.rect(9.8, 9.8, 4.4, 4.4, r: 1).scaled(CGFloat(pulse), around: center))
        let offsets: [CGFloat] = [9.2, 12, 14.8]
        var index = 0
        for side in 0..<4 {
            for o in offsets {
                let wave = s.phase == 0 ? 1 : 0.3 + 0.7 * M.bump((s.phase - Double(index) / 12 + 1).truncatingRemainder(dividingBy: 1) * 2.5)
                let line: Path
                switch side {
                case 0: line = G.line(o, 6.2, o, 3.4)
                case 1: line = G.line(17.8, o, 20.6, o)
                case 2: line = G.line(24 - o, 17.8, 24 - o, 20.6)
                default: line = G.line(6.2, 24 - o, 3.4, 24 - o)
                }
                pen.stroke(line, opacity: wave)
                index += 1
            }
        }
    }

    static func tray(_ pen: NBIconPen, _ s: NBIconState) {
        let h = M.clamp01(s.hover)
        var outline = Path()
        outline.move(to: G.pt(3.4, 13.4))
        outline.addLine(to: G.pt(6, 6.2))
        outline.addLine(to: G.pt(18, 6.2))
        outline.addLine(to: G.pt(20.6, 13.4))
        outline.addArc(tangent1End: G.pt(20.6, 19.8), tangent2End: G.pt(12, 19.8), radius: 2.4)
        outline.addArc(tangent1End: G.pt(3.4, 19.8), tangent2End: G.pt(3.4, 13.4), radius: 2.4)
        outline.closeSubpath()
        var tub = Path()
        tub.move(to: G.pt(3.4, 13.4))
        tub.addLine(to: G.pt(8.4, 13.4))
        tub.addLine(to: G.pt(9.6, 15.6))
        tub.addLine(to: G.pt(14.4, 15.6))
        tub.addLine(to: G.pt(15.6, 13.4))
        tub.addLine(to: G.pt(20.6, 13.4))
        var bottom = tub
        bottom.addArc(tangent1End: G.pt(20.6, 19.8), tangent2End: G.pt(12, 19.8), radius: 2.4)
        bottom.addArc(tangent1End: G.pt(3.4, 19.8), tangent2End: G.pt(3.4, 13.4), radius: 2.4)
        bottom.closeSubpath()
        pen.fill(bottom, pen.tone)
        pen.fill(bottom, pen.tone)
        // Something drops onto the shelf.
        if h > 0.01 {
            let y = 1.6 + 8 * CGFloat(M.easeOut(h))
            let clip = pen.clipped(to: G.rect(0, 1.4, 24, 11.8, r: 0)).withOpacity(M.segment(h, 0, 0.3))
            clip.stroke(G.line(12, y - 4.4, 12, y))
            clip.stroke(G.poly([G.pt(9.6, y - 2.4), G.pt(12, y), G.pt(14.4, y - 2.4)]))
        }
        pen.stroke(outline)
        pen.stroke(tub)
    }

    /// Two beamed eighth notes; on hover they hop one after the other.
    static func music(_ pen: NBIconPen, _ s: NBIconState) {
        let h = M.clamp01(s.hover)
        let hopLeft = -1.3 * CGFloat(M.bump(M.segment(h, 0, 0.6)))
        let hopRight = -1.3 * CGFloat(M.bump(M.segment(h, 0.3, 1)))
        // The beam, between the tops of the stems (slanted up to the right).
        var beam = Path()
        beam.move(to: G.pt(9.4, 6.6 + hopLeft))
        beam.addLine(to: G.pt(19.2, 4.4 + hopRight))
        beam.addLine(to: G.pt(19.2, 7.6 + hopRight))
        beam.addLine(to: G.pt(9.4, 9.8 + hopLeft))
        beam.closeSubpath()
        pen.fill(beam, pen.tone)
        pen.stroke(beam)
        pen.stroke(G.line(9.4, 7.4 + hopLeft, 9.4, 16.8 + hopLeft))
        pen.stroke(G.line(19.2, 5.2 + hopRight, 19.2, 14.8 + hopRight))
        pen.solid(G.ellipse(6.9, 17.3 + hopLeft, 2.5, 2.0).rotated(-18, around: G.pt(6.9, 17.3 + hopLeft)))
        pen.solid(G.ellipse(16.7, 15.3 + hopRight, 2.5, 2.0).rotated(-18, around: G.pt(16.7, 15.3 + hopRight)))
    }
}
