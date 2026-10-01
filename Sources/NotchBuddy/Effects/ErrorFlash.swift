import AppKit
import QuartzCore
import SwiftUI
import NotchBuddyCore

/// A session failed: the island's rim flashes red (`.front`), a red aura bursts around it and fades
/// (`.behind`), and a red wash pulses from its center (`.inside`). Pair it with the island's shake (or
/// `.fxShake` on any view). Reduce Motion: the same, as a slower fade (there is nothing moving).
final class ErrorFlashLayer: FXLayer {
    struct Style: Equatable {
        var tint = FX.red
        var length: Double = 0.75
        var aura: Double = 0.9
        var wash: Double = 0.85
        var rim: Double = 1

        static let standard = Style()
        /// Reduce Motion: slower in and out.
        static let reduced = Style(length: 1.1, aura: 0.7, wash: 0.6, rim: 0.7)
    }

    private var aura: CALayer?
    private var wash: CAGradientLayer?
    private var washMask: CAShapeLayer?
    private var rim: [CAShapeLayer] = []
    private var outline: FXOutline?
    private var plays = 0

    override init(slot: IslandEffectsSlot) {
        super.init(slot: slot)
        isHidden = true
        switch slot {
        case .behind:
            let aura = add(CALayer())
            aura.shadowColor = FX.red
            aura.shadowRadius = 16
            aura.shadowOffset = CGSize(width: 0, height: 3)
            aura.shadowOpacity = 0
            self.aura = aura
        case .inside:
            let wash = add(CAGradientLayer(), canvasSized: false)
            wash.type = .radial
            wash.colors = [FX.a(FX.red, 0.26), FX.a(FX.red, 0.1), FX.a(FX.red, 0)]
            wash.locations = [0, 0.5, 1]
            wash.startPoint = CGPoint(x: 0.5, y: 0.5)
            wash.endPoint = CGPoint(x: 1, y: 1)
            wash.opacity = 0
            let mask = CAShapeLayer.fxFill(FX.black)
            wash.mask = mask
            self.wash = wash
            washMask = mask
        case .front:
            rim = [add(CAShapeLayer.fxStroke(FX.a(FX.red, 0.2), width: 6)),
                   add(CAShapeLayer.fxStroke(FX.redSoft, width: 1.4))]
            for r in rim { r.opacity = 0 }
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func follow(_ outline: FXOutline) {
        self.outline = outline
        guard !isHidden, !outline.isEmpty else { return }
        FX.quietly { apply(outline) }
    }

    private func apply(_ o: FXOutline) {
        aura?.shadowPath = o.closed
        for r in rim { r.path = o.edge }
        if let wash, let washMask {
            let box = o.box
            let r = max(box.width * 0.55, 50)
            let frame = CGRect(x: box.midX - r, y: box.midY - r, width: 2 * r, height: 2 * r)
            wash.frame = frame
            washMask.frame = CGRect(x: -frame.minX, y: -frame.minY, width: bounds.width, height: bounds.height)
            washMask.path = o.closed
        }
    }

    func play(at begin: CFTimeInterval, reduceMotion: Bool = false) {
        guard let o = outline, !o.isEmpty else { return }
        let s = reduceMotion ? Style.reduced : Style.standard
        isHidden = false
        plays &+= 1
        FX.quietly { apply(o) }
        let rise = reduceMotion ? 0.3 : 0.06
        let flash = { (key: String, peak: Double, length: Double) -> CAKeyframeAnimation in
            let a = FX.curve(key, duration: length, begin: begin) { FXEase.flash($0, rise: rise, peak: peak) }
            a.isAdditive = true
            return a
        }
        switch slot {
        case .behind:
            aura?.add(flash("shadowOpacity", s.aura, s.length), forKey: "flash-\(plays)")
            if !reduceMotion {
                aura?.add(FX.basic("shadowRadius", 8, 22, duration: s.length, begin: begin), forKey: "radius")
            }
        case .inside:
            wash?.add(flash("opacity", s.wash, s.length * 0.8), forKey: "flash-\(plays)")
        case .front:
            for r in rim { r.add(flash("opacity", s.rim, s.length * 0.85), forKey: "flash-\(plays)") }
        }
        retire(at: begin + s.length + 0.1)
    }
}

// MARK: - Shake (SwiftUI)

/// A decaying horizontal shake (`DampedShake`) with a hint of rotation, once per `trigger` change: for
/// session cards and rows (the island has its own). Reduce Motion: no shake.
struct FXShakeModifier<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    var shake = DampedShake.error
    /// Degrees of rotation per point of offset.
    var twist: Double = 0.12
    @Environment(\.islandReduceMotion) private var islandReduce
    @Environment(\.accessibilityReduceMotion) private var systemReduce

    func body(content: Content) -> some View {
        if islandReduce || systemReduce {
            content
        } else {
            let shake = shake, twist = twist
            content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, x in
                view
                    .offset(x: x)
                    .rotationEffect(.degrees(x * twist), anchor: .top)
            } keyframes: { _ in
                KeyframeTrack {
                    for sample in Self.samples(shake) {
                        LinearKeyframe(sample, duration: IslandMotion.t(shake.duration / Double(Self.steps)))
                    }
                }
            }
        }
    }

    private static var steps: Int { 30 }

    private static func samples(_ shake: DampedShake) -> [Double] {
        (1...steps).map { shake.offset(at: shake.duration * Double($0) / Double(steps)) }
    }
}

extension View {
    /// Shakes once each time `trigger` changes (a decaying shake, see `DampedShake`).
    func fxShake<T: Equatable>(trigger: T, _ shake: DampedShake = .error) -> some View {
        modifier(FXShakeModifier(trigger: trigger, shake: shake))
    }
}
