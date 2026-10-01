import AppKit
import QuartzCore
import SwiftUI
import NotchBuddyCore

// MARK: - Palette and animation helpers

/// Shared pieces of the effects library: colors, Core Animation builders, and the conversion of the
/// island's silhouette into paths effects can follow.
///
/// Every effect is a `CALayer` subclass that owns its sublayers and plays by adding animations with an
/// explicit `beginTime`: the render server does all the work (no per-frame main-thread code), and the
/// same layer tree renders offline, frame by frame, for the `--render-effects` filmstrips.
enum FX {
    // Status colors of the island (`SessionStatus.tint`) and the lighter tones glows are made of.
    static let green = CGColor(srgbRed: 0.25, green: 0.84, blue: 0.42, alpha: 1)
    static let greenBright = CGColor(srgbRed: 0.42, green: 0.96, blue: 0.58, alpha: 1)
    static let mint = CGColor(srgbRed: 0.80, green: 1.0, blue: 0.87, alpha: 1)
    static let greenDeep = CGColor(srgbRed: 0.10, green: 0.62, blue: 0.30, alpha: 1)
    static let orange = CGColor(srgbRed: 1.0, green: 0.62, blue: 0.10, alpha: 1)
    static let amber = CGColor(srgbRed: 1.0, green: 0.80, blue: 0.42, alpha: 1)
    static let red = CGColor(srgbRed: 1.0, green: 0.33, blue: 0.30, alpha: 1)
    static let redSoft = CGColor(srgbRed: 1.0, green: 0.55, blue: 0.50, alpha: 1)
    static let gold = CGColor(srgbRed: 1.0, green: 0.84, blue: 0.40, alpha: 1)
    static let white = CGColor(gray: 1, alpha: 1)
    static let clear = CGColor(gray: 0, alpha: 0)
    static let black = CGColor(gray: 0, alpha: 1)

    static func a(_ color: CGColor, _ alpha: CGFloat) -> CGColor {
        color.copy(alpha: alpha) ?? color
    }

    /// The layer's local time now (effects are started at `now + delay`).
    static func now(_ layer: CALayer) -> CFTimeInterval {
        layer.convertTime(CACurrentMediaTime(), from: nil)
    }

    /// Sets layer properties without implicit animations.
    static func quietly(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    static let easeOut = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    static let easeInOut = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1)
    static let easeIn = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.9, 0.4)
    static let linear = CAMediaTimingFunction(name: .linear)

    /// A one-shot from → to that holds `from` before it begins and is removed at its end (the model value,
    /// the effect's resting state, shows again).
    static func basic(_ keyPath: String, _ from: Any?, _ to: Any?, duration: Double, begin: CFTimeInterval,
                      timing: CAMediaTimingFunction = easeOut) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.beginTime = begin
        a.fillMode = .backwards
        a.timingFunction = timing
        return a
    }

    /// Keyframes at explicit fractions of `duration`.
    static func keys(_ keyPath: String, _ values: [Any], times: [Double], duration: Double, begin: CFTimeInterval,
                     timings: [CAMediaTimingFunction]? = nil) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.keyTimes = times.map { NSNumber(value: $0) }
        a.duration = duration
        a.beginTime = begin
        a.fillMode = .backwards
        a.timingFunctions = timings ?? Array(repeating: linear, count: max(values.count - 1, 1))
        return a
    }

    /// A scalar that follows `f(t)`, t = 0 … 1 over `duration`, sampled `n` times (linear in between):
    /// any curve, the very same one the filmstrips and tests evaluate.
    static func curve(_ keyPath: String, duration: Double, begin: CFTimeInterval, samples n: Int = 36,
                      _ f: (Double) -> Double) -> CAKeyframeAnimation {
        let values = FXEase.samples(n, f)
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values.map { NSNumber(value: $0) }
        a.keyTimes = values.indices.map { NSNumber(value: Double($0) / Double(max(values.count - 1, 1))) }
        a.duration = duration
        a.beginTime = begin
        a.fillMode = .backwards
        a.calculationMode = .linear
        return a
    }

    /// A loop in a global phase (a remounted effect continues in step), capped at 30 fps: breathing is slow,
    /// the display can idle down while someone is waited for a long time.
    static func loop(_ animation: CAAnimation, period: CFTimeInterval, phase: CFTimeInterval = 0,
                     fps: Float = 30) -> CAAnimation {
        animation.duration = period
        animation.repeatCount = .infinity
        animation.beginTime = 0
        animation.timeOffset = fmod(CACurrentMediaTime() + phase, period)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: fps, preferred: fps)
        return animation
    }

    /// A group of one-shots that ends `duration` after `begin`.
    static func group(_ animations: [CAAnimation], begin: CFTimeInterval, duration: Double) -> CAAnimationGroup {
        let g = CAAnimationGroup()
        g.animations = animations
        g.beginTime = begin
        g.duration = duration
        g.fillMode = .backwards
        return g
    }
}

// MARK: - Slots

/// Where an effect's layers sit relative to the island (one `IslandEffectsView` per
/// slot): `.behind` the black silhouette (auras, waves, rings: they show only outside it), `.inside` it
/// (washes clipped to it, under the content), and `.front` of everything (rims, comets, sparkles, sheen).
enum IslandEffectsSlot: CaseIterable {
    case behind
    case inside
    case front
}

// MARK: - Outline

/// The island's silhouette as Core Animation paths, on the fixed canvas (top-left origin, flush with the
/// top edge, centered). Built from `IslandSilhouette`, so effects follow the very shape the island draws,
/// pulses included.
struct FXOutline: Equatable {
    var g: IslandGeometry
    var pulse = IslandPulse()
    var canvasWidth: CGFloat

    /// `IslandSilhouette` only reads the canvas' `midX` and `minY`.
    private var canvas: CGRect { CGRect(x: 0, y: 0, width: canvasWidth, height: 4096) }

    var isEmpty: Bool { g.width < 2 || g.height + pulse.dh < 2 }

    /// The closed silhouette (its flat top runs along the top edge): the stage's own path (`IslandPathBuilder`), so an
    /// effect lies exactly on the island it decorates.
    var closed: CGPath { IslandPathBuilder.path(g, pulse: pulse, canvasWidth: canvasWidth) }

    /// Its bounding box.
    var box: CGRect {
        let h = max(0, g.height + pulse.dh)
        let w = max(0, g.width) + 2 * max(0, pulse.earBoost)
        return CGRect(x: canvasWidth / 2 - w / 2, y: max(0, g.top), width: w, height: h)
    }

    /// The body (without the ears).
    var body: CGRect { box.insetBy(dx: max(0, min(g.ear + max(0, pulse.earBoost), box.width / 4)), dy: 0) }

    var bottomCenter: CGPoint { CGPoint(x: box.midX, y: box.maxY) }

    /// The silhouette grown outward by `d`: sides out by `d`, bottom down by `d`, corners rounder; the ears
    /// spread along the top edge by `ear × d`. Same elements as `closed`, so Core Animation morphs between them.
    func grown(_ d: CGFloat, ear: CGFloat = 0.6) -> CGPath {
        var h = g
        h.ear = g.ear + ear * d
        h.width = g.width + 2 * d + 2 * ear * d
        h.height = g.height + d
        h.bottom = g.bottom + d
        return IslandPathBuilder.path(h, pulse: pulse, canvasWidth: canvasWidth)
    }

    /// The visible edge: the silhouette without its flat top (ear tip → down → bottom → up → ear tip); a detached
    /// island («Островок») has its top edge too.
    var edge: CGPath { IslandPathBuilder.path(g, pulse: pulse, canvasWidth: canvasWidth, closed: false) }

    /// The edge split at the bottom center: from each ear tip down to the middle of the bottom
    /// (left, then right), for light that runs down both sides and meets.
    var halves: (left: CGPath, right: CGPath) {
        let els = FXPathElement.elements(of: closed)
        let kinds = els.map(\.kind)
        let expected: [CGPathElementType] = [.moveToPoint, .addCurveToPoint, .addLineToPoint, .addCurveToPoint,
                                             .addLineToPoint, .addCurveToPoint, .addLineToPoint, .addCurveToPoint,
                                             .closeSubpath]
        guard kinds == expected else { return (edge, CGMutablePath()) }
        let mid = CGPoint(x: (els[3].end.x + els[4].end.x) / 2, y: els[4].end.y)
        let left = CGMutablePath()
        left.move(to: els[0].end)
        left.addCurve(to: els[1].end, control1: els[1].points[0], control2: els[1].points[1])
        left.addLine(to: els[2].end)
        left.addCurve(to: els[3].end, control1: els[3].points[0], control2: els[3].points[1])
        left.addLine(to: mid)
        // The right half, walked backwards from the right ear tip.
        let right = CGMutablePath()
        right.move(to: els[7].end)
        right.addCurve(to: els[6].end, control1: els[7].points[1], control2: els[7].points[0])
        right.addLine(to: els[5].end)
        right.addCurve(to: els[4].end, control1: els[5].points[1], control2: els[5].points[0])
        right.addLine(to: mid)
        return (left, right)
    }

    /// `path` without its close-subpath elements.
    static func open(_ path: CGPath) -> CGPath {
        let out = CGMutablePath()
        for e in FXPathElement.elements(of: path) {
            switch e.kind {
            case .moveToPoint: out.move(to: e.points[0])
            case .addLineToPoint: out.addLine(to: e.points[0])
            case .addQuadCurveToPoint: out.addQuadCurve(to: e.points[1], control: e.points[0])
            case .addCurveToPoint: out.addCurve(to: e.points[2], control1: e.points[0], control2: e.points[1])
            case .closeSubpath: break
            @unknown default: break
            }
        }
        return out
    }
}

/// A copied `CGPathElement`.
struct FXPathElement {
    var kind: CGPathElementType
    var points: [CGPoint]
    var end: CGPoint { points.last ?? .zero }

    static func elements(of path: CGPath) -> [FXPathElement] {
        var out: [FXPathElement] = []
        path.applyWithBlock { pointer in
            let e = pointer.pointee
            let count: Int
            switch e.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: count = 0
            @unknown default: count = 0
            }
            out.append(FXPathElement(kind: e.type, points: (0..<count).map { e.points[$0] }))
        }
        return out
    }
}

// MARK: - Sprites

/// Particle and glow images, drawn once in code (white: emitter cells and layers tint them).
enum FXSprites {
    /// A soft round glow: bright center, gaussian-like falloff.
    static let glow: CGImage = glow(FX.white)

    private static let glowLock = NSLock()
    nonisolated(unsafe) private static var glows: [String: CGImage] = [:]

    /// A soft round glow of `color` (layer contents cannot be tinted; emitter cells can).
    static func glow(_ color: CGColor, core: CGColor? = nil) -> CGImage {
        let key = "\(color.components ?? [])|\(core?.components ?? [])"
        glowLock.lock()
        defer { glowLock.unlock() }
        if let image = glows[key] { return image }
        let image = draw(64) { ctx, s in
            let colors = [core ?? color, FX.a(color, 0.55), FX.a(color, 0.16), FX.a(color, 0)] as CFArray
            let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.22, 0.55, 1])!
            let c = CGPoint(x: s / 2, y: s / 2)
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: s / 2, options: [])
        }
        glows[key] = image
        return image
    }

    /// A small hard-edged dot with a soft rim.
    static let dot: CGImage = draw(16) { ctx, s in
        let colors = [FX.white, FX.white, FX.a(FX.white, 0)] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1])!
        let c = CGPoint(x: s / 2, y: s / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: s / 2, options: [])
    }

    /// A four-pointed sparkle with a soft core (the glint of a star).
    static let sparkle: CGImage = draw(48) { ctx, s in
        let c = CGPoint(x: s / 2, y: s / 2)
        let glow = CGGradient(colorsSpace: space, colors: [FX.a(FX.white, 0.9), FX.a(FX.white, 0)] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: s * 0.22, options: [])
        let r = s / 2 - 1, w = s * 0.075
        let star = CGMutablePath()
        star.move(to: CGPoint(x: c.x, y: c.y - r))
        star.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
        star.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + w, y: c.y + w))
        star.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
        star.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - w, y: c.y - w))
        star.closeSubpath()
        ctx.addPath(star)
        ctx.setFillColor(FX.white)
        ctx.fillPath()
    }

    /// A confetti strip (rounded).
    static let strip: CGImage = draw(16) { ctx, s in
        ctx.addPath(CGPath(roundedRect: CGRect(x: s * 0.3, y: s * 0.06, width: s * 0.4, height: s * 0.88),
                           cornerWidth: s * 0.12, cornerHeight: s * 0.12, transform: nil))
        ctx.setFillColor(FX.white)
        ctx.fillPath()
    }

    /// A confetti disc.
    static let disc: CGImage = draw(12) { ctx, s in
        ctx.setFillColor(FX.white)
        ctx.fillEllipse(in: CGRect(x: 1, y: 1, width: s - 2, height: s - 2))
    }

    /// `image` (white) recolored to `color`, cached.
    static func tinted(_ image: CGImage, _ color: CGColor) -> CGImage {
        let key = "\(ObjectIdentifier(image).hashValue)|\(color.components ?? [])"
        glowLock.lock()
        defer { glowLock.unlock() }
        if let cached = glows[key] { return cached }
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.clip(to: rect, mask: image)
        ctx.setFillColor(color)
        ctx.fill(rect)
        let out = ctx.makeImage()!
        glows[key] = out
        return out
    }

    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func draw(_ points: CGFloat, scale: CGFloat = 2, _ body: (CGContext, CGFloat) -> Void) -> CGImage {
        let px = Int(points * scale)
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        ctx.setShouldAntialias(true)
        body(ctx, points)
        return ctx.makeImage()!
    }
}

// MARK: - Layer helpers

extension CAShapeLayer {
    /// A stroke-only shape layer that follows paths in the canvas' coordinates.
    static func fxStroke(_ color: CGColor, width: CGFloat, cap: CAShapeLayerLineCap = .round) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.fillColor = nil
        l.strokeColor = color
        l.lineWidth = width
        l.lineCap = cap
        l.lineJoin = .round
        l.actions = FXLayer.noActions
        return l
    }

    static func fxFill(_ color: CGColor) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.fillColor = color
        l.strokeColor = nil
        l.actions = FXLayer.noActions
        return l
    }
}

/// Base of every effect: a canvas-sized container that never animates implicitly and never takes hits.
class FXLayer: CALayer {
    static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "path": NSNull(), "opacity": NSNull(),
        "hidden": NSNull(), "transform": NSNull(), "contents": NSNull(), "shadowPath": NSNull(),
        "sublayers": NSNull(), "strokeEnd": NSNull(), "strokeStart": NSNull(), "shadowOpacity": NSNull(),
        "lineWidth": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull(), "backgroundColor": NSNull(),
        "emitterPosition": NSNull(), "emitterSize": NSNull(), "birthRate": NSNull(), "colors": NSNull(),
        "startPoint": NSNull(), "endPoint": NSNull(), "mask": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
    ]

    let slot: IslandEffectsSlot

    init(slot: IslandEffectsSlot) {
        self.slot = slot
        super.init()
        actions = Self.noActions
        masksToBounds = false
    }

    override init(layer: Any) {
        slot = (layer as? FXLayer)?.slot ?? .front
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Adds `sublayer` (canvas-sized) and returns it.
    @discardableResult
    func add<L: CALayer>(_ sublayer: L, canvasSized: Bool = true) -> L {
        sublayer.actions = Self.noActions
        if canvasSized {
            sublayer.frame = bounds
            canvasLayers.append(sublayer)
        }
        addSublayer(sublayer)
        return sublayer
    }

    /// Sublayers that span the canvas (the others are placed by their effect).
    private var canvasLayers: [CALayer] = []

    override func layoutSublayers() {
        super.layoutSublayers()
        FX.quietly {
            for sub in canvasLayers where sub.frame != bounds {
                sub.frame = bounds
            }
        }
    }

    /// Follows the island's current silhouette (called every frame while it springs; must be cheap).
    func follow(_ outline: FXOutline) {}

    /// Stops everything at once (the island hid, the window went off screen).
    func stop() {
        retireToken &+= 1
        retirePending = false
        removeAllAnimations()
        for sub in sublayers ?? [] { Self.removeAnimations(sub) }
        FX.quietly {
            isHidden = true
            didRetire()
        }
    }

    private var retireToken = 0
    private var retirePending = false
    private var retireAt: CFTimeInterval = 0

    /// Hides the layer (nothing left to composite) once its last one-shot has ended at `localTime` (this
    /// layer's time). A later play or retire supersedes it.
    func retire(at localTime: CFTimeInterval) {
        // Overlapping one-shots: hide after the one that ends last.
        let now = FX.now(self)
        let end = retirePending ? max(localTime, retireAt) : localTime
        retireAt = end
        retirePending = true
        retireToken &+= 1
        let token = retireToken
        let delay = max(0, end - now) / Double(max(speedChain, 0.01))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.retireToken == token else { return }
            self.retirePending = false
            FX.quietly {
                self.isHidden = true
                self.didRetire()
            }
        }
    }

    /// Cancels a pending `retire` (the effect was started again before it hid).
    func cancelRetire() {
        retireToken &+= 1
        retirePending = false
    }

    /// Called when the layer hides after its last one-shot (emitters drop their cells here).
    func didRetire() {}

    /// The product of this layer's and its ancestors' speeds (slow motion).
    var speedChain: Float {
        var s: Float = 1
        var layer: CALayer? = self
        while let l = layer {
            s *= l.speed
            layer = l.superlayer
        }
        return s
    }

    private static func removeAnimations(_ layer: CALayer) {
        layer.removeAllAnimations()
        for sub in layer.sublayers ?? [] { removeAnimations(sub) }
    }
}

// MARK: - Bursts

/// A burst of sprites flying out from a point and slowing down like sparks (ease-out), with a little
/// gravity, spin, a pop in scale and a fade. Each sprite is a plain layer with explicit animations, laid
/// out by a seeded generator: crisp, cheap (a dozen or two layers for a second), and deterministic.
struct FXBurst {
    struct Kind {
        var image: CGImage
        var size: CGFloat
        var colors: [CGColor]
        var count: Int
        var distance: ClosedRange<Double>
        var duration: ClosedRange<Double>
        var spin: Double = 0
    }

    var origin: CGPoint
    /// Directions (radians, canvas coordinates: π/2 points down).
    var angles: ClosedRange<Double> = 0...(2 * .pi)
    /// Sprites start this far from the origin (around a badge rather than on its center).
    var startRadius: Double = 0
    /// Sprites start anywhere on a horizontal line this long through the origin (a spray off an edge).
    var spread: Double = 0
    var gravity: Double = 0
    var kinds: [Kind]
    var seed: UInt64

    /// Adds the sprites to `host` and starts them at `begin`; returns them (the caller removes them later).
    @discardableResult
    func play(in host: CALayer, begin: CFTimeInterval, scale k: Double = 1) -> [CALayer] {
        var rng = FXRandom(seed: seed)
        var made: [CALayer] = []
        for kind in kinds {
            let count = Int((Double(kind.count) * k).rounded())
            for i in 0..<count {
                // Spread evenly with jitter, so a small burst still fills its fan.
                let slot = (Double(i) + rng.range(0.15, 0.85)) / Double(max(count, 1))
                let angle = angles.lowerBound + (angles.upperBound - angles.lowerBound) * slot
                let distance = rng.range(kind.distance.lowerBound, kind.distance.upperBound) * (0.85 + 0.15 * k)
                let duration = rng.range(kind.duration.lowerBound, kind.duration.upperBound)
                let size = kind.size * CGFloat(rng.range(0.7, 1.15))
                let color = kind.colors[Int(rng.unit() * Double(kind.colors.count)) % kind.colors.count]
                let dir = CGVector(dx: cos(angle), dy: sin(angle))
                let along = spread > 0 ? rng.range(-spread / 2, spread / 2) : 0
                let p0 = CGPoint(x: origin.x + along + dir.dx * startRadius, y: origin.y + dir.dy * startRadius)
                let p1 = CGPoint(x: p0.x + dir.dx * distance, y: p0.y + dir.dy * distance + gravity)
                let control = CGPoint(x: p0.x + dir.dx * distance * 0.7, y: p0.y + dir.dy * distance * 0.7)

                let sprite = CALayer()
                sprite.actions = FXLayer.noActions
                sprite.contents = FXSprites.tinted(kind.image, color)
                sprite.bounds = CGRect(x: 0, y: 0, width: size, height: size)
                sprite.position = p1
                sprite.opacity = 0
                host.addSublayer(sprite)
                made.append(sprite)

                let delay = rng.range(0, 0.04)
                let path = CGMutablePath()
                path.move(to: p0)
                path.addQuadCurve(to: p1, control: control)
                let move = CAKeyframeAnimation(keyPath: "position")
                move.path = path
                move.calculationMode = .paced
                move.timingFunction = CAMediaTimingFunction(controlPoints: 0.12, 0.8, 0.3, 1)
                let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                pop.values = [0.2, 1.15, 0.9, 0.25]
                pop.keyTimes = [0, 0.18, 0.55, 1]
                pop.timingFunctions = [FX.easeOut, FX.easeInOut, FX.easeIn]
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 1, 1, 0]
                fade.keyTimes = [0, 0.08, 0.45, 1]
                fade.timingFunctions = [FX.linear, FX.linear, FX.easeInOut]
                var parts: [CAAnimation] = [move, pop, fade]
                if kind.spin != 0 {
                    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                    spin.fromValue = 0
                    spin.toValue = kind.spin * (rng.unit() < 0.5 ? -1 : 1) * rng.range(0.5, 1)
                    spin.timingFunction = move.timingFunction
                    parts.append(spin)
                }
                for part in parts { part.duration = duration }
                sprite.add(FX.group(parts, begin: begin + delay, duration: duration), forKey: "burst")
            }
        }
        return made
    }
}
