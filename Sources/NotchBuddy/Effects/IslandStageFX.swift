import AppKit
import QuartzCore
import SwiftUI
import NotchBuddyCore

// The effects library (`DoneCelebrationLayer`, `ErrorFlashLayer`, `HoverSheenLayer`) on the Core Animation stage:
// one-shots are `IslandEffect`s laid out on the silhouette the island is heading for, and the loops that must track
// the shape while it moves (the attention rings, the permission rim) are `IslandSilhouetteFollower`s that bake their
// paths from the stage's own motion. Nothing here runs per frame on the main thread; loops are capped at 30 fps.
//
// Look: calm, Apple-like. Thin crisp lines and a whisper of light, no auras behind the island.

// MARK: - One-shots

/// A library effect layer played once on the stage, in one placement.
struct IslandFXOneShot: IslandEffect {
    enum Kind {
        case done(DoneCelebrationStyle, anchor: CGPoint?, intensity: Int)
        case error
        case sheen
    }

    let kind: Kind
    let placement: IslandEffectPlacement
    /// After the island has (nearly) landed on its new shape.
    var delay: Double = 0

    private var slot: IslandEffectsSlot {
        switch placement {
        case .behind: return .behind
        case .inside: return .inside
        case .above: return .front
        }
    }

    func play(in layer: CALayer, context: IslandEffectContext) -> CFTimeInterval {
        let fx: FXLayer
        switch kind {
        case .done: fx = DoneCelebrationLayer(slot: slot)
        case .error: fx = ErrorFlashLayer(slot: slot)
        case .sheen:
            let sheen = HoverSheenLayer(slot: .front)
            sheen.look.peak = 0.085
            fx = sheen
        }
        // `NOTCHBUDDY_SLOWMO` slows the effects with everything else.
        let speed = max(IslandMotion.speed, 0.01)
        fx.speed = Float(speed)
        fx.frame = layer.bounds
        layer.addSublayer(fx)
        fx.setNeedsLayout()
        fx.layoutIfNeeded()
        let outline = FXOutline(g: context.geometry, canvasWidth: context.canvas.width)
        fx.follow(outline)
        let begin = FX.now(fx) + delay
        let length: Double
        switch kind {
        case .done(let style, let anchor, let intensity):
            (fx as? DoneCelebrationLayer)?.play(at: begin, style: style, intensity: intensity, anchor: anchor,
                                                reduceMotion: context.reduceMotion)
            length = context.reduceMotion ? 1.2 : style.length
        case .error:
            (fx as? ErrorFlashLayer)?.play(at: begin, reduceMotion: context.reduceMotion)
            length = context.reduceMotion ? 1.1 : 0.75
        case .sheen:
            guard (fx as? HoverSheenLayer)?.sweep(at: begin, reduceMotion: context.reduceMotion, force: true) == true
            else { return 0 }
            length = 1.0
        }
        return (delay + length + 0.15) / speed
    }
}

// MARK: - Followers

/// Someone is waiting (the closed island): a thin orange rim breathes along the island's edge and a crisp ring
/// leaves the outline every 2.4 s and fades. The rim follows the shape as it moves; the ring pauses while it does.
/// Reduce Motion: the rim alone, steady.
@MainActor
final class IslandAttentionFollower: IslandSilhouetteFollower {
    var placement: IslandEffectPlacement { .above }
    let tint: NSColor
    private let reduce: Bool
    private let group = CALayer()
    private let rim = CAShapeLayer()
    private let ringHolder = CALayer()
    private let ring = CAShapeLayer()
    private var builtFor: CGSize = .zero

    static let period: CFTimeInterval = 2.4

    init(tint: Color, reduceMotion: Bool) {
        self.tint = NSColor(tint).usingColorSpace(.sRGB) ?? .orange
        reduce = reduceMotion
        for layer in [group, rim, ringHolder, ring] { layer.actions = IslandStage.noActions }
        rim.fillColor = nil
        rim.strokeColor = self.tint.withAlphaComponent(0.85).cgColor
        rim.lineWidth = 1.2
        rim.lineCap = .round
        ring.fillColor = nil
        ring.strokeColor = self.tint.withAlphaComponent(0.7).cgColor
        ring.lineWidth = 1.1
        ring.opacity = 0
        group.addSublayer(ringHolder)
        ringHolder.addSublayer(ring)
        group.addSublayer(rim)
    }

    func attach(to layer: CALayer) {
        group.frame = layer.bounds
        for l in [rim, ringHolder, ring] { l.frame = group.bounds }
        // Rings scale about the canvas' top center (the island hangs from it).
        ring.anchorPoint = CGPoint(x: 0.5, y: 0)
        ring.position = CGPoint(x: group.bounds.midX, y: 0)
        layer.addSublayer(group)
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = 0.25 / IslandMotion.speed
        group.add(fadeIn, forKey: "in")
        if reduce {
            rim.opacity = 0.6
        } else {
            let breathe = CAKeyframeAnimation(keyPath: "opacity")
            breathe.values = [0.8, 0.3, 0.8]
            breathe.keyTimes = [0, 0.55, 1]
            breathe.timingFunctions = [FX.easeInOut, FX.easeInOut]
            rim.add(FX.loop(breathe, period: Self.period / 2 / IslandMotion.speed), forKey: "breathe")
        }
    }

    func follow(_ motion: IslandSilhouetteMotion, timeline: IslandTimeline, from start: CFTimeInterval,
                until end: CFTimeInterval) {
        timeline.run(rim, "path", from: start, until: end) { t in motion.outline(at: t, closed: false) }
        guard !reduce else { return }
        timeline.run(ring, "path", from: start, until: end) { t in motion.outline(at: t, closed: true) }
        // The ring rests while the shape moves (a ring grown from a moving outline would wobble).
        let moving = end - start > 0.05
        timeline.run(ringHolder, "opacity", from: start, until: end) { t in
            IslandTimeline.number(moving && t < end ? 0 : 1)
        }
        let body = motion.body(at: end)
        let size = CGSize(width: body.width, height: body.height)
        guard abs(size.width - builtFor.width) > 1 || abs(size.height - builtFor.height) > 1 else { return }
        builtFor = size
        let reach: CGFloat = 12 * min(max(size.height / 60, 0.6), 1)
        let target = motion.target
        let sx = (target.width + 2 * reach) / max(target.width, 1)
        let sy = (target.height + reach) / max(target.height, 1)
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = CATransform3DIdentity
        grow.toValue = CATransform3DMakeScale(sx, sy, 1)
        grow.timingFunction = FX.easeOut
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = FXEase.samples(24) { t in 0.75 * FXEase.smoothstep(0, 0.08, t) * pow(1 - t, 1.6) }
        fade.keyTimes = (0...24).map { NSNumber(value: Double($0) / 24) }
        let life = Self.period * 0.62 / IslandMotion.speed
        grow.duration = life
        fade.duration = life
        let pulse = CAAnimationGroup()
        pulse.animations = [grow, fade]
        ring.add(FX.loop(pulse, period: Self.period / IslandMotion.speed), forKey: "ring")
    }

    func detach() {
        group.removeAllAnimations()
        for l in [rim, ring, ringHolder] { l.removeAllAnimations() }
        group.removeFromSuperlayer()
    }
}

/// A permission card is up: a thin rim of the card's tint breathes slowly along the island's edge (the card's own
/// halo stays as it is). Reduce Motion: steady.
@MainActor
final class IslandPermissionRim: IslandSilhouetteFollower {
    var placement: IslandEffectPlacement { .above }
    private let line = CAShapeLayer()
    private let reduce: Bool

    init(tint: Color, reduceMotion: Bool) {
        reduce = reduceMotion
        line.actions = IslandStage.noActions
        line.fillColor = nil
        line.strokeColor = (NSColor(tint).usingColorSpace(.sRGB) ?? .orange).withAlphaComponent(0.7).cgColor
        line.lineWidth = 1
        line.lineCap = .round
        line.opacity = 0.5
    }

    func attach(to layer: CALayer) {
        line.frame = layer.bounds
        layer.addSublayer(line)
        guard !reduce else { return }
        let breathe = CAKeyframeAnimation(keyPath: "opacity")
        breathe.values = [0.2, 0.65, 0.2]
        breathe.keyTimes = [0, 0.5, 1]
        breathe.timingFunctions = [FX.easeInOut, FX.easeInOut]
        line.add(FX.loop(breathe, period: 2.8 / IslandMotion.speed), forKey: "breathe")
    }

    func follow(_ motion: IslandSilhouetteMotion, timeline: IslandTimeline, from start: CFTimeInterval,
                until end: CFTimeInterval) {
        timeline.run(line, "path", from: start, until: end) { t in motion.outline(at: t, closed: false) }
    }

    func detach() {
        line.removeAllAnimations()
        line.removeFromSuperlayer()
    }
}

// MARK: - Director

/// Decides which effects play on the stage: the green "done" celebration when a notice says a session finished
/// (coalesced: several at once make one, then smaller encores), the attention rings on the closed island while a
/// session waits, the permission rim while a card is up, a red rim flash when the closed island's session fails,
/// and a sheen across the closed island when the pointer arrives.
@MainActor
final class IslandEffectsDirector {
    unowned let state: IslandViewState
    unowned let stage: IslandStage
    private var attention: IslandAttentionFollower?
    private var permission: IslandPermissionRim?
    private var pendingCelebration: UUID?
    private var celebrated: UUID?
    private var coalescer = CelebrationCoalescer()
    private var lastSheen = -TimeInterval.infinity

    init(state: IslandViewState, stage: IslandStage) {
        self.state = state
        self.stage = stage
    }

    /// After every update of the island (the mode and its geometry are committed by now).
    func update(mode: IslandMode, snapshot: IslandSnapshot) {
        let reduce = state.reduceMotion
        // Attention: the closed island's session waits for the user (a request held closed, a question).
        let waits = mode == .collapsed && (snapshot.activity ?? .agents) == .agents && snapshot.primary?.status == .waitingForUser
        setAttention(waits, reduce: reduce)
        setPermission(mode == .permission, reduce: reduce)
        if let id = pendingCelebration, mode == .flash, snapshot.flash?.id == id {
            pendingCelebration = nil
            celebrate(snapshot: snapshot)
        } else if let id = pendingCelebration, snapshot.flash?.id != id {
            // The notice never showed (the list was open): its card sheens instead.
            pendingCelebration = nil
        }
    }

    /// A "finished" notice arrived; it celebrates once it is on the island.
    func sessionFinished(_ id: UUID) {
        guard id != celebrated else { return }
        pendingCelebration = id
    }

    /// A widget finished something (a timer ran out): the calm celebration on the island as it is now.
    func widgetFinished() {
        guard !state.reduceMotion || state.mode != .hidden else { return }
        switch coalescer.register(count: 1, at: AppClock.monotonicSeconds()) {
        case .play, .encore:
            for placement in [IslandEffectPlacement.behind, .inside, .above] {
                state.playEffect(IslandFXOneShot(kind: .done(.calmEncore, anchor: nil, intensity: 1), placement: placement,
                                                 delay: 0.05))
            }
        case .absorb:
            break
        }
    }

    /// The closed island's session failed (with the shake).
    func error() {
        // The rim only: a red haze over the content would hide it.
        state.playEffect(IslandFXOneShot(kind: .error, placement: .above))
    }

    /// The pointer arrived on the closed island (at most every 1.4 s).
    func hoverStarted() {
        // Only the pill (an idle notch is the camera housing itself: nothing to catch the light).
        guard !state.reduceMotion, state.mode == .collapsed else { return }
        let now = AppClock.monotonicSeconds()
        guard now - lastSheen >= 1.4 else { return }
        lastSheen = now
        state.playEffect(IslandFXOneShot(kind: .sheen, placement: .inside, delay: 0.04))
    }

    private func celebrate(snapshot: IslandSnapshot) {
        guard let flash = snapshot.flash else { return }
        celebrated = flash.id
        let style: DoneCelebrationStyle
        let intensity: Int
        switch coalescer.register(count: 1, at: AppClock.monotonicSeconds()) {
        case .play(let n):
            style = .calm
            intensity = n
        case .encore:
            style = .calmEncore
            intensity = 1
        case .absorb:
            return
        }
        let canvas = IslandLayout.canvasSize(state.metrics)
        let anchor = IslandEffects.noticeBadge(metrics: state.metrics, canvasWidth: canvas.width,
                                               contentSize: state.contentSize(.flash))
        // The notice pops out on its spring first: the lines start as it lands, the sparks with the badge's check.
        let delay = state.reduceMotion ? 0 : 0.14
        var shifted = style
        shifted.anchorBurst = max(0.3, style.anchorBurst - delay)
        for placement in [IslandEffectPlacement.behind, .inside, .above] {
            state.playEffect(IslandFXOneShot(kind: .done(shifted, anchor: anchor, intensity: intensity),
                                             placement: placement, delay: delay))
        }
    }

    private func setAttention(_ on: Bool, reduce: Bool) {
        if on, attention == nil {
            let follower = IslandAttentionFollower(tint: SessionStatus.waitingForUser.tint, reduceMotion: reduce)
            attention = follower
            stage.addFollower(follower)
        } else if !on, let follower = attention {
            attention = nil
            stage.removeFollower(follower)
        }
    }

    private func setPermission(_ on: Bool, reduce: Bool) {
        if on, permission == nil {
            let follower = IslandPermissionRim(tint: SessionStatus.waitingForUser.tint, reduceMotion: reduce)
            permission = follower
            stage.addFollower(follower)
        } else if !on, let follower = permission {
            permission = nil
            stage.removeFollower(follower)
        }
    }
}
