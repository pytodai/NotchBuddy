import QuartzCore
import SwiftUI

/// The island's content motion as pure functions of time, shared by the live stage (baked into keyframes) and its
/// film renders. The curves are the island's own (`IslandMotion`, `RevealParams`, `IslandExit`, `AppearAfter`); what
/// Core Animation draws differs from the SwiftUI island only in that nothing is blurred.
enum IslandChoreography {
    /// Seconds on the motion's own clock (`NOTCHBUDDY_SLOWMO` slows it down) at media time `t` of a motion that
    /// started at `start`.
    static func local(_ t: CFTimeInterval, from start: CFTimeInterval) -> Double {
        (t - start) / IslandMotion.slowmo
    }

    /// Media seconds for `seconds` of motion.
    static func media(_ seconds: Double) -> CFTimeInterval { seconds * IslandMotion.slowmo }

    // MARK: Pages

    /// Incoming content `t` seconds after it was mounted (`RevealEffect` without the blur): opaque within the
    /// first 45 % of its curve, scaling and sliding into place from the top center.
    static func reveal(_ e: RevealParams, _ t: Double) -> IslandPose {
        let q = min(max(e.curve.progress(t), 0), 1)
        return IslandPose(opacity: smoothstep(0, 0.45, q), scale: 1 - CGFloat(1 - q) * (1 - e.scale),
                          dx: CGFloat(1 - q) * e.dx, dy: CGFloat(1 - q) * e.dy)
    }

    static func revealDuration(_ e: RevealParams) -> Double { e.delay + e.duration }

    /// Outgoing content `t` seconds after it began to leave (`ExitEffect` without the blur).
    static func exit(_ exit: IslandExit, _ t: Double, reduce: Bool) -> IslandPose {
        if reduce {
            let k = min(max(MotionCurve.curve(.easeOut, 0.08).progress(t), 0), 1)
            return IslandPose(opacity: 1 - k)
        }
        let k = min(max(exit.curve.progress(t), 0), 1)
        let e = exit.params
        return IslandPose(opacity: 1 - k, scale: 1 - CGFloat(k) * (1 - e.scale), dx: CGFloat(k) * e.dx, dy: CGFloat(k) * e.dy)
    }

    static func exitDuration(reduce: Bool) -> Double { reduce ? 0.09 : 0.07 }

    /// How long `exit` takes (the collapse into the closed island is the long one).
    static func exitDuration(_ exit: IslandExit, reduce: Bool) -> Double {
        if !reduce, exit == .collapse { return 0.15 }
        return exitDuration(reduce: reduce)
    }

    // MARK: Blur (content comes out of a blur as the shape opens, and blurs out as it closes)

    /// The open island's content as it comes in: radius 7 → 0 within the first 120 ms of its reveal (after its delay).
    static func revealBlur(_ e: RevealParams, _ t: Double) -> Double {
        let k = min(max((t - e.delay) / 0.12, 0), 1)
        return 7 * (1 - smoothstep(0, 1, k))
    }

    /// Closing (`IslandExit.collapse`): 0 → 8 within 120 ms.
    static func exitBlur(_ t: Double) -> Double {
        8 * smoothstep(0, 1, min(max(t / 0.12, 0), 1))
    }

    static let blurDuration = 0.16

    // MARK: Sections

    /// The curve a section (`AppearAfter`) reveals on, delay included.
    static func appearCurve(delay: Double, curve: MotionCurve, reduce: Bool) -> MotionCurve {
        reduce ? MotionCurve.curve(.easeOut, 0.14).delayed(0.04 + delay) : curve.delayed(delay)
    }

    /// A section's opacity `t` seconds after it was mounted (`AppearEffect`'s: readable early).
    static func appearOpacity(_ curve: MotionCurve, _ t: Double) -> Double {
        min(max(curve.progress(t) * 1.6, 0), 1)
    }

    /// How long a section takes to be fully in (its delay included).
    static func appearDuration(_ curve: MotionCurve) -> Double {
        switch curve.kind {
        case .spring(let spring): return curve.delay + min(spring.settlingDuration, 0.6)
        case .curve(_, let duration): return curve.delay + duration
        }
    }

    // MARK: Hero

    /// Opacity of the flying agent mark `t` seconds after it appeared in place (`IslandMotion.heroIn`) or began to
    /// leave (`IslandMotion.exitOut`), from `from`.
    static func heroOpacity(appearing: Bool, from: Double, _ t: Double) -> Double {
        let curve = appearing ? IslandMotion.heroIn : IslandMotion.exitOut
        let k = min(max(curve.progress(t), 0), 1)
        return appearing ? from + (1 - from) * k : from * (1 - k)
    }

    static let heroFadeDuration = 0.16
}

/// Where the closed island stands against a silhouette narrower than itself (`ClosedContentFit`): scaled with it
/// (no notch) or with each notch wing pulled in toward the camera housing, and how wide the body is in the
/// content's own coordinates (the flying mark stays inside it).
struct IslandClosedFit {
    var scale: CGFloat = 1
    var inset: CGFloat = 0
    var room: CGFloat?

    static func at(bodyWidth: CGFloat, natural: CGFloat, active: Bool, notch: Bool) -> IslandClosedFit {
        let short = active && natural > 1 ? min(max(natural - bodyWidth, 0), natural) : 0
        let scale = notch ? 1 : max(0.3, 1 - short / max(natural, 1))
        return IslandClosedFit(scale: scale, inset: notch ? short / 2 : 0, room: bodyWidth / 2 / scale)
    }
}

extension IslandExit {
    /// How the content of `old` leaves: a card is sent up, a notice swapped out, the rest drawn up into the island (and,
    /// when the island closes, blurred out into the shrinking shape).
    init(leaving old: IslandMode, to new: IslandMode? = nil) {
        switch old {
        case .permission: self = .sent
        case .flash: self = .swap
        case .expanded, .page:
            if let new, !new.isOpen, new != .hidden { self = .collapse } else { self = .out }
        default: self = .out
        }
    }
}
