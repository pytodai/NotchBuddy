import AppKit
import SwiftUI

/// Where an effect's layers go on the stage.
enum IslandEffectPlacement {
    /// Behind the black silhouette (a ring or a glow around the island).
    case behind
    /// Inside the island, over its content and cut by the silhouette (a shimmer across the island).
    case inside
    /// Over everything and not cut (particles flying out of the island). The canvas is the limit: it reaches
    /// `IslandLayout.shadowMargin` beyond the largest island.
    case above
}

/// What an effect is anchored to, at the moment it starts. Coordinates are the canvas' (top-left origin, the island
/// hangs from the top center).
struct IslandEffectContext {
    let canvas: CGSize
    /// The silhouette where it is heading (the geometry's target).
    let geometry: IslandGeometry
    /// Its body without the ears, where it is heading.
    let body: CGRect
    /// The silhouette's outline where it is heading, without its top edge (for strokes).
    let outline: CGPath
    /// Media time of the start.
    let now: CFTimeInterval
    let reduceMotion: Bool
    /// Bake tracks here (`run`) and the effect is filmed by `--render-perf` too; plain Core Animation works as well.
    let timeline: IslandTimeline
}

/// A one-shot visual effect anchored to the island (a celebration when an agent finishes, a ripple). It runs in the
/// render server like everything else on the stage: build layers into `layer`, animate them, return how long they
/// last; the stage removes them afterwards.
///
///     state.playEffect(IslandCelebration(tint: SessionStatus.finished.tint))
@MainActor
protocol IslandEffect {
    var placement: IslandEffectPlacement { get }
    /// Builds and animates the effect's layers in `layer` (which fills the canvas); returns its duration in media
    /// seconds.
    func play(in layer: CALayer, context: IslandEffectContext) -> CFTimeInterval
}

extension IslandStage {
    /// Plays `effect` over (or behind, or inside) the island now.
    func play(_ effect: IslandEffect) {
        let now = clock()
        let g = state.geometry
        let width = canvas.width
        let bodyWidth = max(0, g.width - 2 * g.ear)
        let context = IslandEffectContext(
            canvas: canvas, geometry: g,
            body: CGRect(x: width / 2 - bodyWidth / 2, y: max(0, g.top), width: bodyWidth, height: max(0, g.height)),
            outline: IslandPathBuilder.path(g, pulse: IslandPulse(), canvasWidth: width, closed: false), now: now,
            reduceMotion: state.reduceMotion, timeline: timeline)
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: canvas)
        container.actions = IslandStage.noActions
        effectsLayer(effect.placement).addSublayer(container)
        let duration = effect.play(in: container, context: context)
        later(duration + 0.05) { [weak self, weak container] in
            guard let container else { return }
            container.removeFromSuperlayer()
            self?.timeline.prune(before: now)
        }
    }
}

extension IslandViewState {
    /// Plays `effect` anchored to the island (nothing without the Core Animation stage).
    func playEffect(_ effect: IslandEffect) {
        (renderer as? IslandStage)?.play(effect)
    }
}

// MARK: - Built-in effects

/// A ring of light leaving the island's outline and fading as it grows (behind the island).
struct IslandRipple: IslandEffect {
    var tint: Color
    var reach: CGFloat = 26
    var duration: Double = 0.7
    /// After the island has (nearly) landed on its new shape.
    var delay: Double = 0.12
    var placement: IslandEffectPlacement { .behind }

    func play(in layer: CALayer, context: IslandEffectContext) -> CFTimeInterval {
        guard !context.reduceMotion else { return 0 }
        let ring = CAShapeLayer()
        // Transforms about the canvas' top-left corner, like everything on the stage.
        ring.anchorPoint = .zero
        ring.frame = layer.bounds
        ring.actions = IslandStage.noActions
        ring.path = context.outline
        ring.fillColor = nil
        ring.strokeColor = NSColor(tint).cgColor
        ring.lineWidth = 2
        ring.shadowColor = NSColor(tint).cgColor
        ring.shadowRadius = 6
        ring.shadowOpacity = 0.9
        ring.shadowOffset = .zero
        layer.addSublayer(ring)
        let body = context.body
        let anchor = CGPoint(x: body.midX, y: body.minY)
        let start = context.now + IslandChoreography.media(delay)
        let length = IslandChoreography.media(duration)
        let grow = MotionCurve.curve(.easeOut, duration)
        let reach = reach
        ring.opacity = 0
        context.timeline.run(ring, "transform", from: context.now, until: start + length) { t in
            let k = CGFloat(min(max(grow.progress(IslandChoreography.local(t, from: start)), 0), 1))
            // Grows by `reach` points on each side (and below), about the top center.
            let sx = (body.width + 2 * reach * k) / max(body.width, 1)
            let sy = (body.height + reach * k) / max(body.height, 1)
            var m = CATransform3DMakeTranslation(anchor.x, anchor.y, 0)
            m = CATransform3DScale(m, sx, sy, 1)
            return IslandTimeline.transform(CATransform3DTranslate(m, -anchor.x, -anchor.y, 0))
        }
        context.timeline.run(ring, "opacity", from: context.now, until: start + length) { t in
            let x = IslandChoreography.local(t, from: start) / max(duration, 0.01)
            guard x > 0 else { return IslandTimeline.number(0) }
            return IslandTimeline.number(x < 0.12 ? x / 0.12 * 0.9 : 0.9 * pow(max(0, 1 - (x - 0.12) / 0.88), 1.6))
        }
        return start + length - context.now
    }
}

/// The "done" celebration: a ripple, then a burst of small sparks thrown out of the island's lower edge that arc and
/// fade. Deterministic (seeded), so it films the same every time.
struct IslandCelebration: IslandEffect {
    var tint: Color
    var sparks = 26
    var seed: UInt64 = 7
    /// After the island has (nearly) landed on its new shape.
    var delay: Double = 0.1
    var placement: IslandEffectPlacement { .above }

    func play(in layer: CALayer, context: IslandEffectContext) -> CFTimeInterval {
        guard !context.reduceMotion else { return 0 }
        let body = context.body
        let start = context.now
        var rng = SplitMix(seed: seed)
        let colors: [NSColor] = [NSColor(tint), NSColor(tint).blended(withFraction: 0.45, of: .white) ?? .white,
                                 NSColor(white: 1, alpha: 0.95)]
        var longest: CFTimeInterval = 0
        for i in 0..<sparks {
            let dot = CALayer()
            let size = CGFloat(rng.next(2.2, 4.6))
            dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            dot.cornerRadius = size / 2
            dot.backgroundColor = colors[i % colors.count].cgColor
            dot.actions = IslandStage.noActions
            dot.opacity = 0
            layer.addSublayer(dot)
            // From a point along the lower edge, out and down, with a little gravity.
            let u = CGFloat(rng.next(0.08, 0.92))
            let origin = CGPoint(x: body.minX + u * body.width, y: body.maxY - 4)
            let spread = (u - 0.5) * 2
            let vx = spread * CGFloat(rng.next(60, 170)) + CGFloat(rng.next(-30, 30))
            let vy = CGFloat(rng.next(60, 190))
            let life = rng.next(0.55, 0.95)
            let begin = start + IslandChoreography.media(delay + rng.next(0.0, 0.08))
            let end = begin + IslandChoreography.media(life)
            longest = max(longest, end - start)
            context.timeline.run(dot, "position", from: start, until: end) { t in
                let s = max(0, IslandChoreography.local(t, from: begin))
                // Drag slows the throw; gravity pulls it down.
                let drag = (1 - exp(-3.2 * s)) / 3.2
                return IslandTimeline.point(CGPoint(x: origin.x + vx * CGFloat(drag),
                                                    y: origin.y + vy * CGFloat(drag) + CGFloat(90 * s * s)))
            }
            context.timeline.run(dot, "opacity", from: start, until: end) { t in
                let s = IslandChoreography.local(t, from: begin)
                guard s > 0 else { return IslandTimeline.number(0) }
                let x = s / life
                return IslandTimeline.number(x < 0.1 ? x / 0.1 : max(0, 1 - pow((x - 0.1) / 0.9, 1.5)))
            }
        }
        return longest
    }
}

/// A tiny deterministic random generator (the celebration looks the same every time).
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * Double(next() >> 11) / Double(1 << 53)
    }
}

// MARK: - Followers

/// The silhouette's motion as the stage baked it: its geometry and pulse at any media time.
struct IslandSilhouetteMotion {
    let canvasWidth: CGFloat
    /// Where the silhouette is heading.
    let target: IslandGeometry
    let sample: (CFTimeInterval) -> (IslandGeometry, IslandPulse)

    func geometry(at t: CFTimeInterval) -> IslandGeometry { sample(t).0 }

    /// The outline at `t` (`closed` false: without the top edge, for strokes).
    func outline(at t: CFTimeInterval, closed: Bool = true) -> CGPath {
        let (g, p) = sample(t)
        return IslandPathBuilder.path(g, pulse: p, canvasWidth: canvasWidth, closed: closed)
    }

    /// The body (without the ears) at `t`, canvas coordinates.
    func body(at t: CFTimeInterval) -> CGRect {
        let (g, p) = sample(t)
        let width = max(0, g.width - 2 * g.ear)
        return CGRect(x: canvasWidth / 2 - width / 2, y: max(0, g.top), width: width, height: max(0, g.height + p.dh))
    }
}

/// An effect that stays and follows the shape (an attention rim, a permission aura, a sheen that must track the
/// body): the stage gives it a layer in `placement` and, whenever the silhouette's motion changes (a transition, a
/// hover, data), the motion and the span to bake. It bakes its own tracks with `timeline.run`, so it moves with the
/// shape in the render server and costs the main thread nothing per frame.
///
///     let rim = IslandOutlineGlow(tint: SessionStatus.waitingForUser.tint)
///     stage.addFollower(rim)       // … and later stage.removeFollower(rim)
@MainActor
protocol IslandSilhouetteFollower: AnyObject {
    var placement: IslandEffectPlacement { get }
    func attach(to layer: CALayer)
    func follow(_ motion: IslandSilhouetteMotion, timeline: IslandTimeline, from start: CFTimeInterval,
                until end: CFTimeInterval)
    func detach()
}

/// A soft line of light along the island's outline that breathes (behind the island: only its outer half shows).
/// Two strokes, no layer shadow: nothing for the render server to blur per frame.
@MainActor
final class IslandOutlineGlow: IslandSilhouetteFollower {
    let tint: Color
    var placement: IslandEffectPlacement { .behind }
    private let group = CALayer()
    private let halo = CAShapeLayer()
    private let line = CAShapeLayer()

    init(tint: Color) {
        self.tint = tint
        for (layer, width, alpha) in [(halo, CGFloat(9), 0.22), (line, CGFloat(2.5), 0.9)] {
            layer.fillColor = nil
            layer.strokeColor = NSColor(tint).withAlphaComponent(alpha).cgColor
            layer.lineWidth = width
            layer.lineCap = .round
            layer.actions = IslandStage.noActions
            group.addSublayer(layer)
        }
        group.actions = IslandStage.noActions
    }

    func attach(to layer: CALayer) {
        group.frame = layer.bounds
        halo.frame = group.bounds
        line.frame = group.bounds
        layer.addSublayer(group)
        // Breathes in the render server on its own clock.
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.45
        breathe.toValue = 1
        breathe.duration = 1.1 * IslandMotion.slowmo
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.add(breathe, forKey: "breathe")
    }

    func follow(_ motion: IslandSilhouetteMotion, timeline: IslandTimeline, from start: CFTimeInterval,
                until end: CFTimeInterval) {
        for layer in [halo, line] {
            timeline.run(layer, "path", from: start, until: end) { t in motion.outline(at: t, closed: false) }
        }
    }

    func detach() {
        group.removeAllAnimations()
        group.removeFromSuperlayer()
    }
}
