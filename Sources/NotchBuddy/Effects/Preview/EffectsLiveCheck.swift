import AppKit
import SwiftUI
import NotchBuddyCore

/// Part of `--render-effects`: mounts the three `IslandEffectsView`s the way the island would (in an
/// NSHostingView, in a window that is never shown), drives them through state changes and checks that each
/// one reaches its layers: one-shots start, loops run and stop, nothing plays for the value a view was
/// created with or while hidden, the canvas is drawn top-down, and a frame of following a moving
/// silhouette stays cheap. Returns the problems found.
@MainActor
enum EffectsLiveCheck {
    static func run() -> [String] {
        var problems: [String] = []
        IslandEffectsHostView.assumeOnScreen = true
        defer { IslandEffectsHostView.assumeOnScreen = false }
        let metrics = FXMock.floating
        let canvas = IslandLayout.canvasSize(metrics)
        let pill = IslandLayout.geometry(mode: .collapsed, metrics: metrics, content: CGSize(width: 250, height: metrics.barHeight),
                                         hovering: false, pressed: false, lastPillWidth: 250)
        var effects = IslandEffects()
        // Created with a pending celebration: it must not play on mount.
        effects.celebrate(now: 0)
        let host = NSHostingView(rootView: root(pill, effects, canvas))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: canvas.width, height: canvas.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        settle(host)
        let hosts = find(host)
        guard hosts.count == 3 else { return ["expected 3 effect hosts, found \(hosts.count)"] }
        func layer<L: FXLayer>(_ type: L.Type, _ slot: IslandEffectsSlot) -> L? {
            hosts.first { $0.slot == slot }?.effectLayers.compactMap { $0 as? L }.first
        }
        func animating(_ l: CALayer?) -> Bool {
            guard let l else { return false }
            return !(l.animationKeys() ?? []).isEmpty || (l.sublayers ?? []).contains { animating($0) }
        }

        if animating(layer(DoneCelebrationLayer.self, .behind)) { problems.append("celebration played on mount") }
        for h in hosts where h.layer?.contentsAreFlipped() == false && h.effectLayers.first?.superlayer?.isGeometryFlipped == false {
            problems.append("\(h.slot) stage is drawn bottom-up")
        }
        if hosts.contains(where: { $0.hitTest(NSPoint(x: canvas.width / 2, y: 10)) != nil }) {
            problems.append("an effect host takes clicks")
        }

        // A finish, a waiting session, a card.
        effects.celebrate(now: 10)
        effects.attention = true
        effects.permission = SessionStatus.waitingForUser.tint
        host.rootView = root(pill, effects, canvas)
        settle(host)
        for slot in IslandEffectsSlot.allCases where !animating(layer(DoneCelebrationLayer.self, slot)) {
            problems.append("celebration did not start in \(slot)")
        }
        if layer(DoneCelebrationLayer.self, .front)?.isHidden != false { problems.append("celebration front stayed hidden") }
        if !animating(layer(AttentionPulseLayer.self, .behind)) { problems.append("attention rings not running") }
        if !animating(layer(PermissionGlowLayer.self, .behind)) { problems.append("permission aura not running") }

        // An error, a hover, a milestone, an appear.
        effects.flashError()
        effects.hover = true
        effects.confetti()
        effects.dripIn()
        host.rootView = root(pill, effects, canvas)
        settle(host)
        if !animating(layer(ErrorFlashLayer.self, .front)) { problems.append("error flash did not start") }
        if !animating(layer(HoverSheenLayer.self, .front)) { problems.append("sheen did not sweep") }
        if !animating(layer(ConfettiLayer.self, .front)) { problems.append("confetti did not start") }
        if !animating(layer(AppearDripLayer.self, .behind)) { problems.append("drip did not start") }

        // Following a moving silhouette: every frame of a spring updates the three hosts.
        let list = IslandLayout.geometry(mode: .expanded, metrics: metrics, content: CGSize(width: 492, height: 360),
                                         hovering: false, pressed: false, lastPillWidth: 250)
        let start = CACurrentMediaTime()
        let frames = 60
        for i in 0..<frames {
            let g = pill.interpolated(to: list, Double(i) / Double(frames - 1))
            for h in hosts { h.update(geometry: g, target: list, pulse: IslandPulse(), effects: effects) }
        }
        CATransaction.flush()
        let perFrame = (CACurrentMediaTime() - start) / Double(frames) * 1000
        print(String(format: "effects-live: following a spring costs %.2f ms per frame (3 slots, loops running)", perFrame))
        if perFrame > 4 { problems.append(String(format: "following costs %.2f ms per frame", perFrame)) }

        // Loops stop, and nothing runs while the island is hidden.
        effects.attention = false
        effects.permission = nil
        effects.visible = false
        effects.celebrate(now: 30)
        host.rootView = root(list, effects, canvas)
        settle(host)
        if layer(AttentionPulseLayer.self, .behind)?.isRunning == true { problems.append("attention kept running") }
        if layer(DoneCelebrationLayer.self, .behind)?.isHidden == false { problems.append("celebration runs while hidden") }
        window.contentView = nil
        return problems
    }

    private static func root(_ g: IslandGeometry, _ effects: IslandEffects, _ canvas: CGSize) -> AnyView {
        AnyView(ZStack(alignment: .top) {
            IslandEffectsView(geometry: g, effects: effects, slot: .behind)
            IslandSilhouette(g: g).fill(Color.black)
            IslandEffectsView(geometry: g, effects: effects, slot: .inside)
            IslandEffectsView(geometry: g, effects: effects, slot: .front)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .top))
    }

    private static func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        host.layoutSubtreeIfNeeded()
    }

    private static func find(_ view: NSView) -> [IslandEffectsHostView] {
        (view as? IslandEffectsHostView).map { [$0] } ?? view.subviews.flatMap(find)
    }
}
