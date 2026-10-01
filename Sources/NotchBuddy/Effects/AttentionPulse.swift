import AppKit
import QuartzCore
import NotchBuddyCore

/// A breathing loop around the island (attention, a permission card): shared start/stop, following and
/// deterministic phase for filmstrips.
class FXLoopLayer: FXLayer {
    private(set) var isRunning = false
    private(set) var reduced = false
    var outline: FXOutline?
    /// Filmstrips: loops start here (layer time) instead of in the global phase.
    var loopOrigin: CFTimeInterval?

    /// Starts (or keeps running) the loop; `false` fades it out.
    func setActive(_ on: Bool, reduceMotion: Bool = false) {
        if on {
            guard !isRunning || reduced != reduceMotion else { return }
            isRunning = true
            reduced = reduceMotion
            isHidden = false
            cancelRetire()
            removeAnimation(forKey: "fadeOut")
            if let outline { FX.quietly { layout(outline) } }
            startLoops(fadeIn: true)
        } else {
            guard isRunning else { return }
            isRunning = false
            let begin = FX.now(self)
            let fade = FX.basic("opacity", presentation()?.opacity ?? 1, 0, duration: 0.28, begin: begin, timing: FX.easeInOut)
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            add(fade, forKey: "fadeOut")
            retire(at: begin + 0.3)
        }
    }

    override func didRetire() {
        removeAnimation(forKey: "fadeOut")
        for sub in sublayers ?? [] { sub.removeAllAnimations() }
    }

    override func stop() {
        isRunning = false
        super.stop()
    }

    /// Size of the box the running loop was built for: rebuilt when the island changes size.
    private var builtFor: CGSize = .zero

    override func follow(_ outline: FXOutline) {
        self.outline = outline
        guard isRunning, !outline.isEmpty else { return }
        FX.quietly { layout(outline) }
        let size = outline.box.size
        if abs(size.width - builtFor.width) > 1 || abs(size.height - builtFor.height) > 1 {
            startLoops(fadeIn: false)
        }
    }

    private func startLoops(fadeIn: Bool) {
        guard let outline, !outline.isEmpty else { return }
        builtFor = outline.box.size
        addLoops(outline, reduced: reduced)
        if fadeIn {
            add(FX.basic("opacity", 0, 1, duration: reduced ? 0.3 : 0.22, begin: FX.now(self) + 0.02, timing: FX.easeOut),
                forKey: "fadeIn")
        }
    }

    /// A loop in the global phase (or from `loopOrigin` in filmstrips).
    func loop(_ animation: CAAnimation, period: CFTimeInterval, phase: CFTimeInterval = 0) -> CAAnimation {
        if let loopOrigin {
            animation.duration = period
            animation.repeatCount = .infinity
            animation.beginTime = loopOrigin - phase
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
            return animation
        }
        return FX.loop(animation, period: period, phase: -phase)
    }

    func layout(_ o: FXOutline) {}
    func addLoops(_ o: FXOutline, reduced: Bool) {}
}

/// Someone is waiting: orange rings leave the island's outline one after another and fade, while its rim
/// breathes in step with them (`.behind` rings, `.front` rim). Reduce Motion: a steady rim that fades in.
final class AttentionPulseLayer: FXLoopLayer {
    struct Style: Equatable {
        var tint = FX.orange
        var period: Double = 2.2
        /// How far a ring grows beyond the outline of a tall island (a closed one gets ~60 %).
        var reach: CGFloat = 15
        var ringPeak: Double = 0.5
        var rim: ClosedRange<Double> = 0.3...0.8

        static let standard = Style()
    }

    var look = Style.standard {
        didSet { applyColors() }
    }

    private var rings: [[CAShapeLayer]] = []
    private var rim: [CAShapeLayer] = []

    override init(slot: IslandEffectsSlot) {
        super.init(slot: slot)
        isHidden = true
        switch slot {
        case .behind:
            rings = (0..<2).map { _ in
                [add(CAShapeLayer.fxStroke(FX.a(look.tint, 0.14), width: 7)),
                 add(CAShapeLayer.fxStroke(FX.a(look.tint, 0.9), width: 1.5))]
            }
            for r in rings.joined() { r.opacity = 0 }
        case .front:
            rim = [add(CAShapeLayer.fxStroke(FX.a(look.tint, 0.16), width: 5)),
                   add(CAShapeLayer.fxStroke(FX.a(look.tint, 0.85), width: 1.2))]
            for r in rim { r.opacity = 0 }
        case .inside:
            break
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyColors() {
        for pair in rings {
            pair.first?.strokeColor = FX.a(look.tint, 0.14)
            pair.last?.strokeColor = FX.a(look.tint, 0.9)
        }
        rim.first?.strokeColor = FX.a(look.tint, 0.16)
        rim.last?.strokeColor = FX.a(look.tint, 0.85)
    }

    override func layout(_ o: FXOutline) {
        for r in rings.joined() { r.path = o.closed }
        for r in rim { r.path = o.edge }
    }

    override func addLoops(_ o: FXOutline, reduced: Bool) {
        let s = look
        let P = s.period
        if reduced {
            for r in rim { r.opacity = Float(s.rim.upperBound * 0.8) }
            return
        }
        let reach = s.reach * min(max(o.box.height / 70, 0.6), 1)
        for (i, pair) in rings.enumerated() {
            for (j, ring) in pair.enumerated() {
                let soft = j == 0
                let grow = CABasicAnimation(keyPath: "path")
                grow.fromValue = o.closed
                grow.toValue = o.grown(reach)
                grow.timingFunction = FX.easeOut
                let width = CABasicAnimation(keyPath: "lineWidth")
                width.fromValue = soft ? 4 : 1.8
                width.toValue = soft ? 10 : 0.6
                width.timingFunction = FX.easeOut
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                // Bright as it leaves the edge, then an ease-out fade (mostly one ring shows at a time).
                fade.values = FXEase.samples(24) { t in
                    s.ringPeak * FXEase.smoothstep(0, 0.08, t) * pow(1 - t, 1.6) * (soft ? 0.8 : 1)
                }
                fade.keyTimes = (0...24).map { NSNumber(value: Double($0) / 24) }
                // A ring lives 60 % of the period; the next leaves half a period later.
                for a in [grow, width, fade] as [CAAnimation] { a.duration = P * 0.6 }
                let group = CAAnimationGroup()
                group.animations = [grow, width, fade]
                ring.add(loop(group, period: P, phase: Double(i) * P / 2), forKey: "ring")
            }
        }
        // The rim peaks as each ring leaves (twice a period).
        let breathe = CAKeyframeAnimation(keyPath: "opacity")
        breathe.values = [s.rim.upperBound, s.rim.lowerBound, s.rim.upperBound]
        breathe.keyTimes = [0, 0.55, 1]
        breathe.timingFunctions = [FX.easeInOut, FX.easeInOut]
        for r in rim { r.add(loop(breathe, period: P / 2), forKey: "breathe") }
    }
}
