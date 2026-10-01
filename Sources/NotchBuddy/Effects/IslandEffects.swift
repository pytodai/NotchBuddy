import AppKit
import QuartzCore
import SwiftUI
import NotchBuddyCore

// MARK: - Model

/// What the island's effects show, as a value the island state owns and mutates:
///
///     state.effects.celebrate()            // a session finished (coalesced)
///     state.effects.attention = true       // someone waits
///     state.effects.permission = .orange   // a card is up (nil: off)
///     state.effects.flashError()           // the primary session failed
///     state.effects.hover = hovering       // a sheen sweeps on each hover start
///     state.effects.dripIn()               // hidden → closed
///     state.effects.confetti()             // a milestone
///
/// and the island draws it with three `IslandEffectsView`s (one per `IslandEffectsSlot`, see there).
struct IslandEffects: Equatable {
    /// False while the island is hidden: loops stop and one-shots are skipped.
    var visible = true
    var reduceMotion = false
    /// Orange rings and a breathing rim: someone waits.
    var attention = false
    /// A breathing aura of this tint while a permission card is up.
    var permission: Color?
    /// Pointer over the island: each false → true sweeps a sheen across it (with a cooldown).
    var hover = false
    /// Where the celebration's sparkles burst, in canvas points (the notice's badge,
    /// `IslandEffects.noticeBadge`); nil: from the bottom center, downward.
    var celebrationAnchor: CGPoint?

    struct Celebration: Equatable {
        var id = 0
        var intensity = 1
        var encore = false
        var quiet = false
    }

    private(set) var celebration = Celebration()
    private(set) var error = 0
    private(set) var appear = 0
    private(set) var milestone = 0
    private var coalescer = CelebrationCoalescer()

    /// `count` sessions finished now. The first plays in full; more within the coalescing window add
    /// encores or are absorbed (`CelebrationCoalescer`). `quiet`: a notice that stays in the notch strip.
    /// Returns whether anything will play.
    @discardableResult
    mutating func celebrate(count: Int = 1, quiet: Bool = false,
                            now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        switch coalescer.register(count: count, at: now) {
        case .play(let intensity):
            celebration = Celebration(id: celebration.id &+ 1, intensity: intensity, encore: false, quiet: quiet)
            return true
        case .encore:
            celebration = Celebration(id: celebration.id &+ 1, intensity: 1, encore: true, quiet: quiet)
            return true
        case .absorb:
            return false
        }
    }

    mutating func flashError() { error &+= 1 }
    mutating func dripIn() { appear &+= 1 }
    mutating func confetti() { milestone &+= 1 }

    /// The finished notice's badge (its check) on the canvas, for `celebrationAnchor`: `FlashView` puts a
    /// 34 pt badge 16 pt in from the left, vertically centered (floating), or a 22 pt one 12 pt into the
    /// left wing of the notch strip.
    static func noticeBadge(metrics: IslandMetrics, canvasWidth: CGFloat, contentSize: CGSize) -> CGPoint {
        let left = canvasWidth / 2 - contentSize.width / 2
        if metrics.style == .notch {
            return CGPoint(x: left + 12 + 11, y: metrics.barHeight / 2)
        }
        return CGPoint(x: left + 16 + 17, y: contentSize.height / 2 - 0.5)
    }
}

// MARK: - SwiftUI

/// The island's effects in one slot. Put three in `IslandBody`'s ZStack, sharing the silhouette's
/// animated geometry so every glow follows the shape frame by frame:
///
///     IslandEffectsView(geometry: g, effects: state.effects, slot: .behind)   // before IslandSurface
///     IslandSurface(...)
///     IslandEffectsView(geometry: g, effects: state.effects, slot: .inside)   // right after it
///     IslandPressArea(...) / content ZStack (masked) ...
///     IslandEffectsView(geometry: g, effects: state.effects, slot: .front)    // last
///
/// Canvas-sized, transparent, never hit-tested, never focused. Reads `islandPulse` from the environment.
struct IslandEffectsView: View, Animatable {
    var geometry: IslandGeometry
    let effects: IslandEffects
    let slot: IslandEffectsSlot
    @Environment(\.islandPulse) private var pulse

    /// Where the silhouette is heading (the drip needs the closed island's final size); the geometry itself
    /// is interpolated by SwiftUI along with the silhouette's.
    private let target: IslandGeometry

    init(geometry: IslandGeometry, effects: IslandEffects, slot: IslandEffectsSlot) {
        self.geometry = geometry
        self.target = geometry
        self.effects = effects
        self.slot = slot
    }

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(geometry.width, geometry.height), AnimatablePair(geometry.ear, geometry.bottom)) }
        set {
            geometry.width = newValue.first.first
            geometry.height = newValue.first.second
            geometry.ear = newValue.second.first
            geometry.bottom = newValue.second.second
        }
    }

    var body: some View {
        IslandEffectsRepresentable(geometry: geometry, target: target, pulse: pulse, effects: effects, slot: slot)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct IslandEffectsRepresentable: NSViewRepresentable {
    let geometry: IslandGeometry
    let target: IslandGeometry
    let pulse: IslandPulse
    let effects: IslandEffects
    let slot: IslandEffectsSlot

    func makeNSView(context: Context) -> IslandEffectsHostView {
        IslandEffectsHostView(slot: slot, effects: effects)
    }

    func updateNSView(_ view: IslandEffectsHostView, context: Context) {
        view.update(geometry: geometry, target: target, pulse: pulse, effects: effects)
    }
}

// MARK: - Host

/// Hosts one slot's effect layers on the canvas and turns changes of `IslandEffects` into plays: one-shots
/// fire when their counter moves (never for the value the view was created with), loops follow their flags,
/// nothing runs while the island is hidden or its window is off screen.
final class IslandEffectsHostView: NSView {
    let slot: IslandEffectsSlot
    private let stage = CALayer()
    private let celebration: DoneCelebrationLayer
    private let attention: AttentionPulseLayer
    private let permission: PermissionGlowLayer
    private let error: ErrorFlashLayer
    private let sheen: HoverSheenLayer
    private let drip: AppearDripLayer
    private let confetti: ConfettiLayer
    private var all: [FXLayer] { [drip, permission, attention, celebration, error, sheen, confetti] }

    private var effects: IslandEffects
    private var geometry = IslandGeometry()
    private var target = IslandGeometry()
    private var pulse = IslandPulse()
    private var occlusionObserver: NSObjectProtocol?
    private var permissionTint: Color?
    /// The offline wiring check (`EffectsLiveCheck`): windows off screen count as visible.
    static var assumeOnScreen = false

    /// The effect layers, for the offline wiring check.
    var effectLayers: [FXLayer] { all }

    init(slot: IslandEffectsSlot, effects: IslandEffects) {
        self.slot = slot
        self.effects = effects
        celebration = DoneCelebrationLayer(slot: slot)
        attention = AttentionPulseLayer(slot: slot)
        permission = PermissionGlowLayer(slot: slot)
        error = ErrorFlashLayer(slot: slot)
        sheen = HoverSheenLayer(slot: slot)
        drip = AppearDripLayer(slot: slot)
        confetti = ConfettiLayer(slot: slot)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        stage.actions = FXLayer.noActions
        stage.masksToBounds = false
        // `NOTCHBUDDY_SLOWMO` slows the effects with everything else.
        stage.speed = Float(IslandMotion.speed)
        layer?.addSublayer(stage)
        for l in all { stage.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        FX.quietly {
            stage.frame = bounds
            // Effects draw in top-left canvas coordinates, whatever the backing layer's own flipping is.
            // (Inside an NSHostingView the flipped view's backing layer already draws top-down.)
            stage.isGeometryFlipped = !(layer?.contentsAreFlipped() ?? false)
            for l in all where l.frame != stage.bounds {
                l.frame = stage.bounds
                l.setNeedsLayout()
                l.layoutIfNeeded()
            }
        }
        follow()
    }

    // MARK: Visibility

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            stopAll()
            return
        }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibilityChanged() }
        }
        visibilityChanged()
    }

    private var onScreen: Bool {
        guard let window else { return false }
        return Self.assumeOnScreen || window.occlusionState.contains(.visible)
    }

    private var live: Bool { onScreen && effects.visible }

    private func visibilityChanged() {
        if live { syncLoops() } else { stopAll() }
    }

    private func stopAll() {
        for l in all { l.stop() }
    }

    // MARK: Updates

    private var outline: FXOutline {
        FXOutline(g: geometry, pulse: pulse, canvasWidth: bounds.width)
    }

    private func follow() {
        guard bounds.width > 0 else { return }
        let o = outline
        for l in all { l.follow(o) }
    }

    func update(geometry: IslandGeometry, target: IslandGeometry, pulse: IslandPulse, effects new: IslandEffects) {
        let old = effects
        effects = new
        if geometry != self.geometry || pulse != self.pulse {
            self.geometry = geometry
            self.pulse = pulse
            follow()
        }
        self.target = target
        guard live else {
            if old.visible != new.visible || !new.visible { stopAll() }
            return
        }
        let now = FX.now(stage)
        let reduce = new.reduceMotion
        if new.celebration.id != old.celebration.id {
            let c = new.celebration
            var style: DoneCelebrationStyle = c.encore ? .encore : (c.quiet ? .quiet : .standard)
            // A notice still popping out: start once its silhouette has nearly settled (~90 % of the flash
            // spring), keeping the burst in step with the badge's own check.
            let springing = abs(geometry.width - target.width) > 1 || abs(geometry.height - target.height) > 1
            let delay = springing && !reduce ? 0.16 : 0
            style.anchorBurst = max(0.3, style.anchorBurst - delay)
            celebration.play(at: now + delay, style: style, intensity: c.intensity, anchor: new.celebrationAnchor,
                             reduceMotion: reduce, settled: FXOutline(g: target, canvasWidth: bounds.width))
        }
        if new.error != old.error { error.play(at: now, reduceMotion: reduce) }
        if new.appear != old.appear {
            drip.play(at: now, target: FXOutline(g: target, canvasWidth: bounds.width), reduceMotion: reduce)
        }
        if new.milestone != old.milestone { confetti.play(at: now, reduceMotion: reduce) }
        if new.hover, !old.hover { sheen.sweep(at: now, reduceMotion: reduce) }
        syncLoops()
    }

    private func syncLoops() {
        let reduce = effects.reduceMotion
        attention.setActive(effects.attention, reduceMotion: reduce)
        if let tint = effects.permission, tint != permissionTint {
            permissionTint = tint
            permission.look.tint = NSColor(tint).usingColorSpace(.sRGB)?.cgColor ?? FX.orange
        }
        permission.setActive(effects.permission != nil, reduceMotion: reduce)
    }
}
