import AppKit
import QuartzCore
import NotchBuddyCore

/// The island drips out of the top edge: as the closed island grows from the edge (its own `appear`
/// spring), a black drop runs ahead of it, hangs a moment below it on a thinning neck, springs back and is
/// absorbed (`.behind`: the same black as the island, so the two read as one liquid body). Only the drop
/// shows; the island's motion is untouched. Reduce Motion: nothing (the island fades in on its own).
final class AppearDripLayer: FXLayer {
    struct Style: Equatable {
        /// How far the drop hangs below the closed island's bottom at its longest.
        var hang: CGFloat = 6
        var radius: CGFloat = 5.5
        var length: Double = 0.46

        static let standard = Style()
    }

    var look = Style.standard
    private let drop = CAShapeLayer.fxFill(FX.black)

    override init(slot: IslandEffectsSlot) {
        super.init(slot: slot)
        isHidden = true
        if slot == .behind { add(drop) }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// One keyframe of the drop: `top` half-width where it leaves the top edge, the neck at `neckY` with
    /// half-width `neck`, and a round bulb of radius `r` centered at `bulbY`.
    struct Pose {
        var top: CGFloat
        var neckY: CGFloat
        var neck: CGFloat
        var bulbY: CGFloat
        var r: CGFloat
    }

    /// The drop's outline for a pose: the same seven curves for every pose (so Core Animation morphs
    /// between them), concave from the top edge into the neck, round around the bulb.
    static func path(_ p: Pose, centerX cx: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let neckY = min(p.neckY, p.bulbY - p.r * 0.2)
        let neck = min(p.neck, p.r)
        path.move(to: CGPoint(x: cx - p.top, y: 0))
        path.addCurve(to: CGPoint(x: cx - neck, y: neckY),
                      control1: CGPoint(x: cx - p.top * 0.35, y: 0),
                      control2: CGPoint(x: cx - neck, y: neckY * 0.45))
        path.addCurve(to: CGPoint(x: cx - p.r, y: p.bulbY),
                      control1: CGPoint(x: cx - neck, y: neckY + (p.bulbY - neckY) * 0.35),
                      control2: CGPoint(x: cx - p.r, y: p.bulbY - p.r * 0.75))
        path.addCurve(to: CGPoint(x: cx, y: p.bulbY + p.r),
                      control1: CGPoint(x: cx - p.r, y: p.bulbY + p.r * 0.55),
                      control2: CGPoint(x: cx - p.r * 0.55, y: p.bulbY + p.r))
        path.addCurve(to: CGPoint(x: cx + p.r, y: p.bulbY),
                      control1: CGPoint(x: cx + p.r * 0.55, y: p.bulbY + p.r),
                      control2: CGPoint(x: cx + p.r, y: p.bulbY + p.r * 0.55))
        path.addCurve(to: CGPoint(x: cx + neck, y: neckY),
                      control1: CGPoint(x: cx + p.r, y: p.bulbY - p.r * 0.75),
                      control2: CGPoint(x: cx + neck, y: neckY + (p.bulbY - neckY) * 0.35))
        path.addCurve(to: CGPoint(x: cx + p.top, y: 0),
                      control1: CGPoint(x: cx + neck, y: neckY * 0.45),
                      control2: CGPoint(x: cx + p.top * 0.35, y: 0))
        path.closeSubpath()
        return path
    }

    /// The drop's poses for a closed island `height` tall and `width` wide, and when each is reached.
    func poses(height h: CGFloat, width w: CGFloat) -> [(t: Double, pose: Pose)] {
        let s = look
        let top = min(w * 0.2, 60)
        return [
            (0.00, Pose(top: top * 0.5, neckY: 0.5, neck: 3, bulbY: 1, r: 2)),
            (0.06, Pose(top: top * 0.8, neckY: h * 0.3, neck: 8, bulbY: h * 0.6, r: s.radius * 1.05)),
            (0.13, Pose(top: top, neckY: h * 0.85, neck: 5, bulbY: h + s.hang * 0.8, r: s.radius)),
            (0.19, Pose(top: top, neckY: h * 0.95, neck: 4.2, bulbY: h + s.hang, r: s.radius * 0.92)),
            (0.28, Pose(top: top, neckY: h * 0.9, neck: 6, bulbY: h + s.hang * 0.2, r: s.radius * 0.95)),
            (0.36, Pose(top: top, neckY: h * 0.8, neck: 6.5, bulbY: h - 3, r: s.radius * 0.85)),
            (0.46, Pose(top: top, neckY: h * 0.6, neck: 5, bulbY: h - 12, r: s.radius * 0.6)),
        ]
    }

    /// Plays the drip for the closed island `outline` is heading to (its target geometry), at `begin`.
    func play(at begin: CFTimeInterval, target: FXOutline, reduceMotion: Bool = false) {
        guard slot == .behind, !reduceMotion, !target.isEmpty else { return }
        isHidden = false
        let cx = target.box.midX
        let keys = poses(height: target.box.height, width: target.body.width)
        let length = keys.last?.t ?? look.length
        FX.quietly {
            drop.frame = bounds
            drop.path = Self.path(keys.last!.pose, centerX: cx)
        }
        let a = CAKeyframeAnimation(keyPath: "path")
        a.values = keys.map { Self.path($0.pose, centerX: cx) }
        a.keyTimes = keys.map { NSNumber(value: $0.t / length) }
        a.timingFunctions = Array(repeating: FX.easeInOut, count: keys.count - 1)
        a.duration = length
        a.beginTime = begin
        a.fillMode = .backwards
        drop.add(a, forKey: "drip")
        retire(at: begin + length)
    }
}
