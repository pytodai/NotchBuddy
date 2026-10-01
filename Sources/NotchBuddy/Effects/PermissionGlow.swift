import AppKit
import QuartzCore
import NotchBuddyCore

/// While a permission card waits: a tinted aura around the island breathes slowly (`.behind`), and a
/// hairline of the same tint lines its lower edge, brightest at the bottom and gone toward the ears
/// (`.front`). Starts with a short bloom. Reduce Motion: a steady aura and rim that fade in.
final class PermissionGlowLayer: FXLoopLayer {
    struct Style: Equatable {
        var tint = FX.orange
        var period: Double = 2.8
        var aura: ClosedRange<Double> = 0.42...0.8
        var radius: CGFloat = 18
        var rim: ClosedRange<Double> = 0.5...0.9

        static let standard = Style()
    }

    var look = Style.standard {
        didSet { applyColors() }
    }

    private var aura: CALayer?
    private var rimGradient: CAGradientLayer?
    private var rimMask: CAShapeLayer?

    override init(slot: IslandEffectsSlot) {
        super.init(slot: slot)
        isHidden = true
        switch slot {
        case .behind:
            let aura = add(CALayer())
            aura.shadowRadius = look.radius
            aura.shadowOffset = CGSize(width: 0, height: 5)
            aura.shadowOpacity = 0
            self.aura = aura
        case .front:
            // A stroke cannot fade along its length: a vertical gradient seen through the stroked edge.
            let gradient = add(CAGradientLayer(), canvasSized: false)
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            let mask = CAShapeLayer.fxStroke(FX.black, width: 1.3)
            gradient.mask = mask
            gradient.opacity = 0
            rimGradient = gradient
            rimMask = mask
        case .inside:
            break
        }
        applyColors()
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyColors() {
        aura?.shadowColor = look.tint
        aura?.shadowRadius = look.radius
        rimGradient?.colors = [FX.a(look.tint, 0), FX.a(look.tint, 0.15), FX.a(look.tint, 0.95)]
        rimGradient?.locations = [0, 0.35, 1]
    }

    override func layout(_ o: FXOutline) {
        aura?.shadowPath = o.closed
        if let rimGradient, let rimMask {
            let frame = o.box.insetBy(dx: -2, dy: 0).offsetBy(dx: 0, dy: 1)
            rimGradient.frame = CGRect(x: frame.minX, y: 0, width: frame.width, height: frame.maxY + 1)
            rimMask.frame = CGRect(x: -rimGradient.frame.minX, y: 0, width: bounds.width, height: bounds.height)
            rimMask.path = o.edge
        }
    }

    override func addLoops(_ o: FXOutline, reduced: Bool) {
        let s = look
        if reduced {
            aura?.shadowOpacity = Float(s.aura.upperBound * 0.8)
            rimGradient?.opacity = Float(s.rim.upperBound)
            return
        }
        let breathe = { (range: ClosedRange<Double>) -> CAKeyframeAnimation in
            let a = CAKeyframeAnimation()
            a.values = [range.lowerBound, range.upperBound, range.lowerBound]
            a.keyTimes = [0, 0.5, 1]
            a.timingFunctions = [FX.easeInOut, FX.easeInOut]
            return a
        }
        if let aura {
            let a = breathe(s.aura)
            a.keyPath = "shadowOpacity"
            aura.add(loop(a, period: s.period), forKey: "breathe")
            let r = breathe(Double(s.radius * 0.85)...Double(s.radius * 1.2))
            r.keyPath = "shadowRadius"
            aura.add(loop(r, period: s.period), forKey: "radius")
            // The bloom: a brighter swell as the card arrives, on top of the loop.
            let bloom = FX.curve("shadowOpacity", duration: 0.9, begin: loopOrigin ?? FX.now(self)) {
                FXEase.flash($0, rise: 0.25, peak: 0.45)
            }
            bloom.isAdditive = true
            aura.add(bloom, forKey: "bloom")
        }
        if let rimGradient {
            let a = breathe(s.rim)
            a.keyPath = "opacity"
            rimGradient.add(loop(a, period: s.period), forKey: "breathe")
        }
    }
}
