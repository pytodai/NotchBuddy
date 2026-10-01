import AppKit

/// Dragging the closed «Островок» sideways (horizontally only): pure math, tested in `IslandDragTests`.
///
/// A press on the closed capsule that travels `threshold` sideways becomes a drag; from then on the capsule follows the
/// pointer's x (its y never changes), rendered by moving the whole stage rigidly (`IslandStage.dragSlide`), so it keeps
/// up with every mouse event. Near the screen's edges it rubber-bands; let go, it settles inside the screen with a soft
/// spring (`IslandMotion.drop`), onto the center when it was dropped within `snapDistance` of it. The offset is kept per
/// display (`NotchSettings.islandOffsets`).
///
/// A press on an open island where its capsule sits grabs the capsule only after a clear sideways pull
/// (`grabThreshold`): there the press may have been meant for a tab or a header button under it.
enum IslandDragMath {
    /// Sideways travel (points, button down) before the closed capsule moves: below it a press is still a click.
    static let threshold: CGFloat = 4
    /// Sideways travel before a press on an open island grabs its capsule: above the closed capsule's click slop (8 pt,
    /// `IslandStageView.mouseUp`), so a sloppy click on a tab or ⚙ 🔊 📌 there stays a click.
    static let grabThreshold: CGFloat = 12
    /// Let go this close to the center, the capsule settles on the center (a gentle magnetic snap).
    static let snapDistance: CGFloat = 24
    /// Past the screen's margin the capsule follows less and less, never more than this much further.
    static let rubberBand: CGFloat = 8

    /// Whether a press that has moved `dx`, `dy` since it went down is a drag now (sideways only).
    static func begins(dx: CGFloat, dy: CGFloat, threshold: CGFloat = threshold) -> Bool {
        abs(dx) >= threshold
    }

    /// Whether a press on an open island that has moved `dx`, `dy` grabs its capsule: `grabThreshold` sideways, and more
    /// sideways than up or down.
    static func grabBegins(dx: CGFloat, dy: CGFloat) -> Bool {
        abs(dx) >= grabThreshold && abs(dx) > abs(dy)
    }

    /// The capsule's offset while dragged: where it was when the drag began (`start`), plus the pointer's sideways travel
    /// `dx` less a lag that fades out after the threshold T, rubber-banded past `range`. The lag, (T + 2u)·e^(−u/T) for u
    /// points past the threshold, starts at T with the capsule at rest, so the capsule leaves its place at zero speed,
    /// catches up at most ~1.45× the pointer's speed, and follows it 1:1 after about seven times T of travel (~30 pt for a
    /// press on the capsule, ~85 pt for a grab out of the open island, whose fold carries the capsule meanwhile).
    static func follow(start: CGFloat, dx: CGFloat, range: ClosedRange<CGFloat>, threshold: CGFloat = threshold) -> CGFloat {
        let travel = abs(dx)
        var moved: CGFloat = 0
        if travel > threshold {
            let u = travel - threshold
            moved = travel - (threshold + 2 * u) * exp(-u / threshold)
        }
        return rubberBanded(start + (dx < 0 ? -moved : moved), range: range)
    }

    /// `x` held inside `range` softly: past an end it moves on with growing resistance, at most `rubberBand` further.
    static func rubberBanded(_ x: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        if x > range.upperBound { return range.upperBound + band(x - range.upperBound) }
        if x < range.lowerBound { return range.lowerBound - band(range.lowerBound - x) }
        return x
    }

    private static func band(_ over: CGFloat) -> CGFloat {
        rubberBand * over / (over + 2 * rubberBand)
    }

    /// Where the capsule rests once let go at `x`: inside `range`, on the center within `snapDistance` of it; whole points.
    static func settle(_ x: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        let clamped = min(max(x, range.lowerBound), range.upperBound)
        if abs(clamped) <= snapDistance, range.contains(0) { return 0 }
        return clamped.rounded()
    }

    /// Whether moving from `a` to `b` passed the center (a light haptic tick marks it).
    static func crossesCenter(from a: CGFloat, to b: CGFloat) -> Bool {
        (a < 0 && b >= 0) || (a > 0 && b <= 0)
    }
}

/// One press on the capsule, from the mouse going down until it comes up: a click until it travels the threshold
/// sideways, a drag from then on.
struct IslandDrag: Equatable {
    /// The pointer's x on screen when the press began.
    let pressX: CGFloat
    /// The capsule's offset when the drag began: where it was drawn (a press on the capsule, caught even while it still
    /// settles after a drop), or where it rests (a grab out of the open island: the island folds back there, and the rest
    /// of that motion carries on around the drag, `IslandStage.dragSlide`).
    private(set) var start: CGFloat
    /// Where it may rest on this screen (`IslandLayout.shiftRange` for the closed capsule).
    let range: ClosedRange<CGFloat>
    /// Sideways travel before it is a drag (`IslandDragMath.threshold`, or `grabThreshold` out of the open island).
    let threshold: CGFloat
    /// The press became a drag.
    private(set) var active = false
    /// The capsule's offset now.
    private(set) var x: CGFloat

    init(pressX: CGFloat, start: CGFloat, range: ClosedRange<CGFloat>, threshold: CGFloat = IslandDragMath.threshold) {
        self.pressX = pressX
        self.start = start
        self.range = range
        self.threshold = threshold
        x = start
    }

    /// The pointer is at (`px`, with `dy` of vertical travel). `drawn`, asked once as the drag begins: where the capsule
    /// is drawn then, which it starts from (nil: from `start`). Returns true when the capsule moved (or the drag began).
    mutating func pointer(x px: CGFloat, dy: CGFloat, drawn: (() -> CGFloat)? = nil) -> Bool {
        let dx = px - pressX
        var began = false
        if !active {
            guard IslandDragMath.begins(dx: dx, dy: dy, threshold: threshold) else { return false }
            active = true
            began = true
            if let drawn {
                start = drawn().rounded()
                x = start
            }
        }
        let next = IslandDragMath.follow(start: start, dx: dx, range: range, threshold: threshold).rounded()
        guard next != x else { return began }
        x = next
        return true
    }

    /// Where it settles when let go now.
    var rest: CGFloat { IslandDragMath.settle(x, range: range) }
}
