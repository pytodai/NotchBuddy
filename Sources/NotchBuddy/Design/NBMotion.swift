import SwiftUI

/// Motion tokens of the design system. Every curve is a `MotionCurve`, so it drives live SwiftUI
/// animations and can be sampled at any time (the `--render-design` filmstrips draw in-between frames
/// with the exact curve). All of them honour `NOTCHBUDDY_SLOWMO` through `IslandMotion.speed`.
enum NBMotion {
    /// A control going down under the pointer: fast, slightly soft.
    static let press = MotionCurve.spring(0.20, 0.62)
    /// A control coming back up: a little bounce ("squish").
    static let release = MotionCurve.spring(0.36, 0.52)
    /// Hover highlights.
    static let hover = MotionCurve.spring(0.26, 0.82)
    /// Switch knobs: travels with a small overshoot.
    static let knob = MotionCurve.spring(0.34, 0.64)
    /// Selection pills sliding between segments.
    static let pill = MotionCurve.spring(0.36, 0.74)
    /// Progress fills and rings.
    static let fill = MotionCurve.spring(0.62, 0.86)
    /// Icon morphs (play ↔ pause, sound on ↔ off, chevron).
    static let morph = MotionCurve.spring(0.40, 0.74)
    /// Chips and badges popping in.
    static let pop = MotionCurve.spring(0.32, 0.56)
    /// Icon hover gestures (gear turn, pin tilt, arrow jump).
    static let iconHover = MotionCurve.spring(0.44, 0.60)
    /// Icon hover gestures that shake or wobble (must not overshoot).
    static let iconWobble = MotionCurve.curve(.easeOut, 0.62)
    /// The "done" check drawing on, with its burst.
    static let celebrate = MotionCurve.curve(.easeOut, 0.9)
    /// The light band that sweeps across a control when the pointer arrives.
    static let sheenDuration: Double = 0.72
    /// Cross-fades.
    static let fade = MotionCurve.curve(.easeOut, 0.16)

    /// Loop periods (seconds).
    static let spinPeriod: Double = 1.1
    static let breathePeriod: Double = 2.2
    static let blinkPeriod: Double = 1.05

    /// Loops never redraw faster than this (icons pick a lower rate for slow loops: `NBIcon.loopFrameRate`).
    static let loopFrameInterval: Double = 1.0 / 60

    /// The animation for a curve, or a short fade-like ease when Reduce Motion is on.
    static func animation(_ curve: MotionCurve, reduced: Bool = false) -> Animation {
        reduced ? .easeOut(duration: 0.14).speed(IslandMotion.speed) : curve.animation
    }

    /// Loop phase 0 ..< 1 at a date (a shared clock: every loop with the same period is in step).
    static func phase(at date: Date, period: Double) -> Double {
        let p = period * IslandMotion.slowmo
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: p) / p
    }
}

// MARK: - Preview state

/// Forces an interaction state for renders of the design sheet (nil: follow the pointer).
struct NBForcedState: Equatable {
    var hovered: Bool?
    var pressed: Bool?
    /// Sheen band position −1 … 1.3 (nil: none).
    var sheen: Double?

    static let rest = NBForcedState(hovered: false, pressed: false)
    static let hover = NBForcedState(hovered: true, pressed: false, sheen: 0.42)
    static let press = NBForcedState(hovered: true, pressed: true)
}

private struct NBForcedStateKey: EnvironmentKey { static let defaultValue: NBForcedState? = nil }
private struct NBLoopsPausedKey: EnvironmentKey { static let defaultValue = false }
private struct NBHoverKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Forced interaction state (design sheet renders only).
    var nbForcedState: NBForcedState? {
        get { self[NBForcedStateKey.self] }
        set { self[NBForcedStateKey.self] = newValue }
    }

    /// Freezes every icon loop and shimmer below (set it while the island's panel is ordered out or
    /// occluded: SwiftUI keeps `TimelineView`s ticking in windows nobody sees).
    var nbLoopsPaused: Bool {
        get { self[NBLoopsPausedKey.self] }
        set { self[NBLoopsPausedKey.self] = newValue }
    }

    /// True inside a hovered control: its `NBIconView`s play their hover gesture.
    var nbControlHovered: Bool {
        get { self[NBHoverKey.self] }
        set { self[NBHoverKey.self] = newValue }
    }
}

// MARK: - Helpers

enum NBMath {
    static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
    /// 0 → 1 → 0 over 0 … 1.
    static func bump(_ x: Double) -> Double { x <= 0 || x >= 1 ? 0 : sin(.pi * x) }
    /// A decaying oscillation over 0 … 1 that starts and ends at 0.
    static func wobble(_ t: Double, cycles: Double = 2) -> Double {
        let x = clamp01(t)
        return sin(x * 2 * .pi * cycles) * (1 - x)
    }
    /// Sub-range of a progress: 0 before `from`, 1 after `to`.
    static func segment(_ t: Double, _ from: Double, _ to: Double) -> Double {
        clamp01((t - from) / max(to - from, 0.0001))
    }
    static func easeInOut(_ x: Double) -> Double {
        let t = clamp01(x)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp01(x), 3) }
}
