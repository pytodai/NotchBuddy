import AppKit
import QuartzCore
import SwiftUI
import NotchBuddyCore

/// The pointer arrives: a soft diagonal band of light sweeps once across the island, clipped to it
/// (`.front`, over the content: glass catching the light). At most once per `cooldown`. Reduce Motion:
/// nothing.
final class HoverSheenLayer: FXLayer {
    struct Style: Equatable {
        var peak: CGFloat = 0.15
        /// Seconds per 400 pt of island width (shorter islands sweep quicker, within 0.6 … 1.0 s).
        var pace: Double = 0.95
        var tilt: CGFloat = 0.34
        var cooldown: Double = 1.4

        static let standard = Style()
    }

    var look = Style.standard
    private let clip = CALayer()
    private let clipMask = CAShapeLayer.fxFill(FX.black)
    private let band = CAGradientLayer()
    private var outline: FXOutline?
    private var lastSweep: CFTimeInterval = -.infinity

    override init(slot: IslandEffectsSlot) {
        super.init(slot: slot)
        isHidden = true
        guard slot == .front else { return }
        add(clip)
        clip.mask = clipMask
        band.actions = Self.noActions
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        clip.addSublayer(band)
        applyStyle()
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyStyle() {
        let p = look.peak
        band.colors = [FX.a(FX.white, 0), FX.a(FX.white, p * 0.35), FX.a(FX.white, p), FX.a(FX.white, p * 1.35),
                       FX.a(FX.white, p), FX.a(FX.white, p * 0.35), FX.a(FX.white, 0)]
        band.locations = [0, 0.22, 0.42, 0.5, 0.58, 0.78, 1]
    }

    override func follow(_ outline: FXOutline) {
        self.outline = outline
        guard !isHidden, !outline.isEmpty else { return }
        FX.quietly { clipMask.frame = bounds; clipMask.path = outline.closed }
    }

    /// Sweeps once at `begin` unless one ran within the cooldown. Returns whether it did.
    @discardableResult
    func sweep(at begin: CFTimeInterval, reduceMotion: Bool = false, force: Bool = false) -> Bool {
        guard slot == .front, !reduceMotion, let o = outline, !o.isEmpty else { return false }
        guard force || begin - lastSweep >= look.cooldown else { return false }
        lastSweep = begin
        isHidden = false
        let box = o.box
        let width = max(120, min(box.width * 0.5, 240))
        let height = box.height + width * look.tilt * 2 + 40
        let duration = min(max(look.pace * Double(box.width) / 400, 0.6), 1.0)
        FX.quietly {
            clip.frame = bounds
            clipMask.frame = bounds
            clipMask.path = o.closed
            band.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            band.position = CGPoint(x: box.minX - width, y: box.midY)
            band.transform = CATransform3DMakeAffineTransform(CGAffineTransform(a: 1, b: 0, c: -look.tilt, d: 1, tx: 0, ty: 0))
        }
        let move = FX.basic("position.x", box.minX - width * 0.35, box.maxX + width * 0.35, duration: duration, begin: begin,
                            timing: CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1))
        band.add(move, forKey: "sweep")
        let fade = FX.curve("opacity", duration: duration, begin: begin) { t in
            FXEase.smoothstep(0, 0.18, t) * (1 - FXEase.smoothstep(0.75, 1, t))
        }
        band.add(fade, forKey: "fade")
        band.opacity = 0
        retire(at: begin + duration + 0.05)
        return true
    }
}

// MARK: - SwiftUI sheen for cards

/// The same sweep for any SwiftUI view (session cards): a light band crosses `shape` once each time
/// `trigger` changes (on hover, say). Reduce Motion: nothing.
struct FXSheenModifier<S: Shape, T: Equatable>: ViewModifier {
    let shape: S
    let trigger: T
    var peak: Double = 0.10
    var duration: Double = 0.75
    @Environment(\.islandReduceMotion) private var islandReduce
    @Environment(\.accessibilityReduceMotion) private var systemReduce
    @Environment(\.islandFilmTime) private var filmTime

    func body(content: Content) -> some View {
        if islandReduce || systemReduce {
            content
        } else if let filmTime {
            content.overlay { FXSheenBand(progress: filmTime / duration, peak: peak).clipShape(shape).allowsHitTesting(false) }
        } else {
            content.overlay {
                Color.clear
                    .keyframeAnimator(initialValue: 1.2, trigger: trigger) { view, p in
                        view.overlay { FXSheenBand(progress: p, peak: peak) }
                    } keyframes: { _ in
                        KeyframeTrack {
                            LinearKeyframe(0, duration: 0.001)
                            CubicKeyframe(1.2, duration: IslandMotion.t(duration))
                        }
                    }
                    .clipShape(shape)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// A slanted light band at `progress` (0: off the leading edge … 1: off the trailing edge).
struct FXSheenBand: View {
    var progress: Double
    var peak: Double

    var body: some View {
        GeometryReader { geo in
            let w = max(60, geo.size.width * 0.38)
            let x = -w + (geo.size.width + 2 * w) * CGFloat(min(max(progress, 0), 1))
            LinearGradient(stops: [
                .init(color: .white.opacity(0), location: 0),
                .init(color: .white.opacity(peak * 0.4), location: 0.3),
                .init(color: .white.opacity(peak), location: 0.5),
                .init(color: .white.opacity(peak * 0.4), location: 0.7),
                .init(color: .white.opacity(0), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
            .frame(width: w, height: geo.size.height * 1.6)
            .rotationEffect(.degrees(18))
            .position(x: x, y: geo.size.height / 2)
            .opacity(progress > 0 && progress < 1 ? 1 : 0)
        }
    }
}

extension View {
    /// A light band sweeps across `shape` once each time `trigger` changes.
    func fxSheen<S: Shape, T: Equatable>(_ shape: S, trigger: T, peak: Double = 0.10) -> some View {
        modifier(FXSheenModifier(shape: shape, trigger: trigger, peak: peak))
    }
}
