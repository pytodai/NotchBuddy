import SwiftUI

/// An icon from the set, animated.
///
/// ```swift
/// NBIconView(.settings)                                   // turns a tooth when hovered
/// NBIconView(.soundOn, value: soundsOn ? 1 : 0)            // waves ↔ cross morph
/// NBIconView(.pin, value: pinned ? 1 : 0, color: pinned ? NBAccent.brand.base : NBColor.inkSecondary)
/// NBIconView(.working, color: NBAccent.working.base, loops: true)
/// NBIconView(.done, color: NBAccent.done.base, drawsOnAppear: true)   // check + burst once
/// ```
///
/// Hover: the icon tracks the pointer itself, and also plays its gesture while an enclosing
/// `NBButton` (or anything that sets `nbControlHovered`) is hovered, or while `active` is true.
/// Loops (`loops: true`) are Core Animation sprites (no per-frame app work), drawn live only while the
/// hover gesture plays; never under Reduce Motion or in static renders; frozen by `nbLoopsPaused`.
struct NBIconView: View {
    let icon: NBIcon
    var size: CGFloat = 16
    var color: Color = NBColor.ink
    /// Second tone (nil: `color` at 22 %).
    var tone: Color?
    /// The state the icon shows (nil: `icon.defaultValue`).
    var value: Double?
    /// Plays the hover gesture regardless of the pointer.
    var active = false
    /// Runs the icon's loop (only icons with `icon.loops`): played by Core Animation from cached frames
    /// (`NBSpriteCache`), so a spinning icon costs the app nothing per frame.
    var loops = false
    /// `.done` / `.check`: draws on when it appears (the value animates from 0).
    var drawsOnAppear = false
    /// Stroke weight in grid units (default `NBIconPen.weight`).
    var weight: CGFloat = NBIconPen.weight
    /// Accent for icons with a semantic fill (battery level).
    var accent: Color?

    init(_ icon: NBIcon, size: CGFloat = 16, color: Color = NBColor.ink, tone: Color? = nil,
         value: Double? = nil, active: Bool = false, loops: Bool = false, drawsOnAppear: Bool = false,
         weight: CGFloat = NBIconPen.weight, accent: Color? = nil) {
        self.icon = icon
        self.size = size
        self.color = color
        self.tone = tone
        self.value = value
        self.active = active
        self.loops = loops
        self.drawsOnAppear = drawsOnAppear
        self.weight = weight
        self.accent = accent
    }

    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.nbControlHovered) private var controlHovered
    @Environment(\.nbForcedState) private var forced
    @Environment(\.nbLoopsPaused) private var loopsPaused
    @Environment(\.displayScale) private var displayScale
    @Environment(\.self) private var environment
    @State private var hovering = false
    @State private var appeared = false
    /// The hover gesture (or its way back) is playing: a looping icon draws live meanwhile.
    @State private var live = false
    @State private var liveGeneration = 0
    @State private var sprite: (key: NBSpriteCache.Key, sprite: NBSpriteCache.Sprite)?

    private var targetValue: Double {
        let v = value ?? icon.defaultValue
        return drawsOnAppear && !appeared && !staticRender ? 0 : v
    }

    private var targetHover: Double {
        if reduceMotion { return 0 }
        let hovered = forced?.hovered ?? (hovering || controlHovered)
        return active || hovered ? 1 : 0
    }

    private var runsLoop: Bool { loops && icon.loops && !reduceMotion && !staticRender }

    private var spriteKey: NBSpriteCache.Key? {
        guard runsLoop else { return nil }
        return NBSpriteCache.Key(icon: icon, size: size, scale: displayScale, ink: color.resolve(in: environment),
                                 tone: (tone ?? color.opacity(0.22)).resolve(in: environment),
                                 accent: accent?.resolve(in: environment), value: targetValue, weight: weight)
    }

    var body: some View {
        let key = spriteKey
        content(key)
            .frame(width: size, height: size)
            .animation(NBMotion.animation(icon.hoverCurve, reduced: reduceMotion), value: targetHover)
            .animation(NBMotion.animation(icon.valueCurve, reduced: reduceMotion), value: targetValue)
            .onHover { hovering = $0 }
            .onChange(of: targetHover) { _, hover in
                liveGeneration += 1
                if hover > 0 {
                    live = true
                } else {
                    // Back to the sprite once the gesture has returned to rest.
                    let generation = liveGeneration
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 * IslandMotion.slowmo) {
                        if liveGeneration == generation { live = false }
                    }
                }
            }
            .task(id: key) {
                guard let key else { return }
                if let made = NBSpriteCache.sprite(key) { sprite = (key, made) }
            }
            .onAppear {
                guard drawsOnAppear, !appeared else { return }
                // Next runloop turn: the first frame shows 0, then the value animates.
                DispatchQueue.main.async { appeared = true }
            }
            .accessibilityLabel(icon.title)
    }

    @ViewBuilder
    private func content(_ key: NBSpriteCache.Key?) -> some View {
        if runsLoop, !live, !loopsPaused, let key, let sprite, sprite.key == key {
            NBSpriteView(key: key, sprite: sprite.sprite)
        } else if runsLoop {
            TimelineView(.animation(minimumInterval: 1 / icon.loopFrameRate, paused: loopsPaused)) { timeline in
                glyph(phase: NBMotion.phase(at: timeline.date, period: icon.loopPeriod))
            }
        } else {
            glyph(phase: loops && icon.loops ? icon.restPhase : 0)
        }
    }

    private func glyph(phase: Double) -> NBIconGlyph {
        NBIconGlyph(icon: icon, color: color, tone: tone ?? color.opacity(0.22), accent: accent, weight: weight,
                    hover: targetHover, value: targetValue, phase: phase)
    }
}

/// The drawing itself; `hover` and `value` animate (the glyph redraws each frame of a change).
struct NBIconGlyph: View, Animatable {
    let icon: NBIcon
    var color: Color
    var tone: Color
    var accent: Color?
    var weight: CGFloat = NBIconPen.weight
    var hover: Double
    var value: Double
    var phase: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(hover, value) }
        set {
            hover = newValue.first
            value = newValue.second
        }
    }

    @Environment(\.self) private var environment

    var body: some View {
        // The icon is drawn opaque into one layer that then takes the ink's opacity, so overlapping
        // strokes and fill-plus-stroke shapes never show darker seams or brighter joints.
        var ink = color.resolve(in: environment)
        let alpha = Double(ink.opacity)
        ink.opacity = 1
        var second = tone.resolve(in: environment)
        second.opacity = Float(min(1, Double(second.opacity) / max(alpha, 0.001)))
        let inkColor = Color(ink), toneColor = Color(second)
        return Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            NBDesignProbe.glyphDraws &+= 1
            ctx.opacity = alpha
            ctx.drawLayer { layer in
                let pen = NBIconPen(ctx: layer, size: size, ink: inkColor, tone: toneColor, weight: weight)
                NBIconPainter.draw(icon, pen: pen, state: NBIconState(hover: hover, value: value, phase: phase), accent: accent)
            }
        }
    }
}

/// A rounded tile holding an icon (settings rows, widget headers): accent gradient, top sheen, glyph.
struct NBIconTile: View {
    let icon: NBIcon
    var accent: NBAccent = .brand
    var size: CGFloat = 26
    var value: Double?
    var active = false
    var loops = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        NBIconView(icon, size: size * 0.64, color: accent.onAccent, tone: accent.onAccent.opacity(0.26),
                   value: value, active: active, loops: loops)
            .frame(width: size, height: size)
            .background {
                shape.fill(accent.fill)
                    .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0)],
                                                       startPoint: .top, endPoint: .center)))
            }
            .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
            .shadow(color: accent.base.opacity(0.35), radius: 6, y: 2)
    }
}
