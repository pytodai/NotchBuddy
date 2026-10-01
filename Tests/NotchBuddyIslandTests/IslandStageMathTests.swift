import QuartzCore
import SwiftUI
import XCTest
@testable import NotchBuddy

/// The motion model the stage bakes into Core Animation keyframes.
final class IslandStageMathTests: XCTestCase {
    // MARK: SpringTrack

    /// The closed-form spring is SwiftUI's `Spring(response:dampingRatio:)`: the stage's silhouette moves exactly as
    /// the SwiftUI island's did.
    func testSpringTrackMatchesSwiftUISpring() {
        for (response, damping) in [(0.46, 0.78), (0.36, 0.92), (0.48, 0.68), (0.30, 1.0), (0.26, 0.9)] {
            let spring = Spring(response: response, dampingRatio: damping)
            let track = SpringTrack(from: [0], to: [100], response: response, damping: damping, start: 10, slowmo: 1)
            for t in stride(from: 0.0, through: 1.2, by: 0.01) {
                let expected = 100 * spring.value(target: 1.0, time: t)
                XCTAssertEqual(track.value(at: 10 + t)[0], expected, accuracy: 0.05,
                               "spring \(response)/\(damping) at \(t)")
            }
        }
    }

    /// A change of mind mid-flight keeps both the position and the speed: no jump, no kink.
    func testRetargetKeepsValueAndSpeed() {
        let track = SpringTrack(from: [0, 40], to: [300, 500], response: 0.46, damping: 0.78, start: 0, slowmo: 1)
        let t = 0.08
        let next = track.retargeted(to: [120, 38], response: 0.36, damping: 0.92, at: t)
        let before = track.value(at: t), after = next.value(at: t)
        let v0 = track.speed(at: t), v1 = next.speed(at: t)
        for i in 0..<2 {
            XCTAssertEqual(before[i], after[i], accuracy: 1e-9)
            XCTAssertEqual(v0[i], v1[i], accuracy: 1e-6)
        }
        // And just after, it is still close (continuous, heading the new way).
        XCTAssertEqual(next.value(at: t + 0.001)[0], before[0] + v0[0] * 0.001, accuracy: 0.05)
    }

    func testSettleTimeIsSettled() {
        let track = SpringTrack(from: [0], to: [200], response: 0.48, damping: 0.68, start: 5, slowmo: 1)
        let settle = track.settleTime()
        XCTAssertGreaterThan(settle, 5.2)
        XCTAssertLessThan(settle, 6.5)
        for t in stride(from: settle, through: settle + 1, by: 0.01) {
            XCTAssertEqual(track.value(at: t)[0], 200, accuracy: 0.03)
        }
        XCTAssertEqual(SpringTrack.rest([3]).settleTime(), 0)
    }

    func testSlowmoStretchesTime() {
        let fast = SpringTrack(from: [0], to: [1], response: 0.4, damping: 0.8, start: 0, slowmo: 1)
        let slow = SpringTrack(from: [0], to: [1], response: 0.4, damping: 0.8, start: 0, slowmo: 6)
        XCTAssertEqual(fast.value(at: 0.1)[0], slow.value(at: 0.6)[0], accuracy: 1e-9)
    }

    // MARK: Silhouette path

    private func elements(_ path: CGPath) -> [CGPathElementType] {
        var types: [CGPathElementType] = []
        path.applyWithBlock { types.append($0.pointee.type) }
        return types
    }

    /// Core Animation interpolates two paths point by point only when they are built from the same elements: the
    /// silhouette always is, even retracted into nothing.
    func testSilhouettePathHasConstantTopology() {
        let shapes = [
            IslandGeometry(width: 0, height: 0, ear: 0, bottom: 0, shadow: 0),
            IslandGeometry(width: 135, height: 0, ear: 0, bottom: 0, shadow: 0),
            IslandGeometry(width: 302, height: 37, ear: 9, bottom: 16, shadow: 0.18),
            IslandGeometry(width: 524, height: 369, ear: 16, bottom: 28, shadow: 0.55),
            IslandGeometry(width: 4, height: 2, ear: 30, bottom: 40, shadow: 0),
        ]
        let reference = elements(IslandPathBuilder.path(shapes[2], pulse: IslandPulse(), canvasWidth: 700))
        XCTAssertEqual(reference.count, 9)
        for g in shapes {
            for pulse in [IslandPulse(), IslandPulse(earBoost: 4, dh: -10)] {
                XCTAssertEqual(elements(IslandPathBuilder.path(g, pulse: pulse, canvasWidth: 700)), reference)
            }
        }
    }

    /// The same outline as the SwiftUI silhouette (`IslandSilhouette`), flush with the top edge.
    func testSilhouettePathMatchesSwiftUIShape() {
        let g = IslandGeometry(width: 524, height: 369, ear: 16, bottom: 28, shadow: 0.55)
        let pulse = IslandPulse(earBoost: 2, dh: 3)
        let canvas = CGRect(x: 0, y: 0, width: 700, height: 700)
        let swiftUI = IslandSilhouette(g: g, pulse: pulse).path(in: canvas).cgPath
        let stage = IslandPathBuilder.path(g, pulse: pulse, canvasWidth: 700)
        XCTAssertEqual(swiftUI.boundingBoxOfPath.integral, stage.boundingBoxOfPath.integral)
        for point in [CGPoint(x: 350, y: 1), CGPoint(x: 350, y: 371), CGPoint(x: 100, y: 200), CGPoint(x: 90, y: 360),
                      CGPoint(x: 91, y: 2), CGPoint(x: 612, y: 300)] {
            XCTAssertEqual(swiftUI.contains(point), stage.contains(point), "\(point)")
        }
    }

    // MARK: Poses and choreography

    func testPoseComposesAboutAnchor() {
        let inner = IslandPose(opacity: 0.5, scale: 0.9, dx: 0, dy: -8)
        let outer = IslandPose(opacity: 0.5, scale: 0.5, dx: 10, dy: 0)
        let both = inner.then(outer)
        XCTAssertEqual(both.opacity, 0.25)
        XCTAssertEqual(both.scale, 0.45, accuracy: 1e-9)
        let anchor = CGPoint(x: 350, y: 0)
        let p = CGPoint(x: 100, y: 50)
        func apply(_ t: CATransform3D, _ p: CGPoint) -> CGPoint {
            CGPoint(x: t.m11 * p.x + t.m21 * p.y + t.m41, y: t.m12 * p.x + t.m22 * p.y + t.m42)
        }
        let stepwise = apply(outer.transform(anchor: anchor), apply(inner.transform(anchor: anchor), p))
        let combined = apply(both.transform(anchor: anchor), p)
        XCTAssertEqual(stepwise.x, combined.x, accuracy: 1e-9)
        XCTAssertEqual(stepwise.y, combined.y, accuracy: 1e-9)
        // The anchor stays put under a scale.
        let fixed = apply(IslandPose(scale: 0.5).transform(anchor: anchor), anchor)
        XCTAssertEqual(fixed.x, anchor.x, accuracy: 1e-9)
    }

    func testRevealAndExitEndpoints() {
        for entrance in [IslandEntrance.open, .morph, .close, .pop, .deck] {
            let e = IslandContentLayerParams.reveal(entrance, .expanded)
            XCTAssertEqual(IslandChoreography.reveal(e, 0).opacity, 0)
            let end = IslandChoreography.reveal(e, IslandChoreography.revealDuration(e))
            XCTAssertEqual(end.opacity, 1, accuracy: 1e-6)
            XCTAssertEqual(end.scale, 1, accuracy: 1e-6)
            XCTAssertEqual(end.dy, 0, accuracy: 1e-6)
        }
        for exit in [IslandExit.out, .sent, .swap] {
            XCTAssertEqual(IslandChoreography.exit(exit, 0, reduce: false), .identity)
            XCTAssertEqual(IslandChoreography.exit(exit, IslandChoreography.exitDuration(reduce: false), reduce: false).opacity,
                           0, accuracy: 1e-6)
            XCTAssertEqual(IslandChoreography.exit(exit, IslandChoreography.exitDuration(reduce: true), reduce: true).opacity,
                           0, accuracy: 1e-6)
        }
    }

    /// Outgoing content is gone before incoming content shows (no overlap), and the incoming content is readable
    /// soon after (no long empty island).
    func testNoOverlapNoLongBlank() {
        for entrance in [IslandEntrance.open, .morph, .deck] {
            let e = IslandContentLayerParams.reveal(entrance, .permission)
            for exit in [IslandExit.out, .sent] {
                for t in stride(from: 0.0, through: 0.2, by: 0.005) {
                    let out = IslandChoreography.exit(exit, t, reduce: false).opacity
                    let incoming = IslandChoreography.reveal(e, t).opacity
                    XCTAssertLessThan(min(out, incoming), 0.2, "\(entrance) \(exit) at \(t)")
                }
            }
            XCTAssertGreaterThan(IslandChoreography.reveal(e, 0.11).opacity, 0.9, "\(entrance)")
        }
    }

    /// Closing: the list blurs out into the shrinking shape while the pill fades in under it — readable content all the way
    /// (no empty black block), and the two never both fully there.
    func testCloseKeepsContentOnScreen() {
        let pill = IslandContentLayerParams.reveal(.close, .closed)
        for t in stride(from: 0.0, through: 0.3, by: 0.005) {
            let list = IslandChoreography.exit(.collapse, t, reduce: false).opacity
            let incoming = IslandChoreography.reveal(pill, t).opacity
            XCTAssertGreaterThan(max(list, incoming), 0.3, "an empty island at \(t)")
            XCTAssertLessThan(min(list, incoming), 0.6, "both at once at \(t)")
        }
        XCTAssertEqual(IslandChoreography.exit(.collapse, IslandChoreography.exitDuration(.collapse, reduce: false),
                                               reduce: false).opacity, 0, accuracy: 1e-6)
        XCTAssertEqual(IslandChoreography.exitBlur(0), 0)
        XCTAssertEqual(IslandChoreography.exitBlur(0.2), 8, accuracy: 1e-6)
        let open = IslandContentLayerParams.reveal(.open, .expanded)
        XCTAssertEqual(IslandChoreography.revealBlur(open, 0), 7, accuracy: 1e-6)
        XCTAssertEqual(IslandChoreography.revealBlur(open, 0.2), 0, accuracy: 1e-6)
    }

    /// Open → open (list → settings): the new page is in before the old one is fully gone (no blank frame at ~50 ms).
    func testMorphHasNoBlankFrame() {
        let page = IslandContentLayerParams.reveal(.morph, .page("settings"))
        for t in stride(from: 0.0, through: 0.12, by: 0.004) {
            let out = IslandChoreography.exit(.out, t, reduce: false).opacity
            let incoming = IslandChoreography.reveal(page, t).opacity
            XCTAssertGreaterThan(out + incoming, 0.25, "blank at \(t)")
        }
        XCTAssertGreaterThan(IslandChoreography.reveal(page, 0.05).opacity, 0.6)
    }

    func testSectionOpacity() {
        let curve = IslandChoreography.appearCurve(delay: 0.057, curve: IslandMotion.rowIn, reduce: false)
        XCTAssertEqual(IslandChoreography.appearOpacity(curve, 0.05), 0)
        XCTAssertEqual(IslandChoreography.appearOpacity(curve, IslandChoreography.appearDuration(curve)), 1, accuracy: 1e-6)
        let reduced = IslandChoreography.appearCurve(delay: 0.057, curve: IslandMotion.rowIn, reduce: true)
        XCTAssertEqual(IslandChoreography.appearOpacity(reduced, IslandChoreography.appearDuration(reduced)), 1, accuracy: 1e-6)
    }

    func testClosedFit() {
        // Wider than the closed content: nothing to fit.
        XCTAssertEqual(IslandClosedFit.at(bodyWidth: 500, natural: 280, active: true, notch: false).scale, 1)
        // Half as wide, no notch: scaled with the shape.
        let half = IslandClosedFit.at(bodyWidth: 140, natural: 280, active: true, notch: false)
        XCTAssertEqual(half.scale, 0.5, accuracy: 1e-9)
        XCTAssertEqual(half.room ?? 0, 140, accuracy: 1e-9)
        // Beside a notch the wings are pulled in instead.
        let notch = IslandClosedFit.at(bodyWidth: 200, natural: 300, active: true, notch: true)
        XCTAssertEqual(notch.scale, 1)
        XCTAssertEqual(notch.inset, 50)
        XCTAssertEqual(IslandClosedFit.at(bodyWidth: 100, natural: 300, active: false, notch: true).inset, 0)
    }

    // MARK: Timeline

    @MainActor
    func testTimelineFilmsItsTracks() {
        let timeline = IslandTimeline()
        timeline.filming = true
        let layer = CALayer()
        timeline.run(layer, "opacity", from: 1, until: 2) { t in IslandTimeline.number(t - 1) }
        timeline.apply(at: 1.25)
        XCTAssertEqual(Double(layer.opacity), 0.25, accuracy: 1e-6)
        timeline.apply(at: 5)
        XCTAssertEqual(Double(layer.opacity), 1, accuracy: 1e-6)
        XCTAssertEqual((timeline.value(layer, "opacity", at: 1.5) as? NSNumber)?.doubleValue ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertTrue(timeline.isRunning(layer, "opacity", at: 1.9))
        XCTAssertFalse(timeline.isRunning(layer, "opacity", at: 2.1))
    }

    @MainActor
    func testTimelineBakesKeyframes() {
        let timeline = IslandTimeline()
        let layer = CALayer()
        timeline.run(layer, "opacity", from: 10, until: 10.5) { t in IslandTimeline.number((t - 10) * 2) }
        let animation = layer.animation(forKey: "opacity") as? CAKeyframeAnimation
        XCTAssertNotNil(animation)
        XCTAssertEqual(animation?.values?.count, 61)
        XCTAssertEqual(animation?.duration ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(animation?.calculationMode, .linear)
        // The model value is the end of the motion (what stays once the animation is removed).
        XCTAssertEqual(Double(layer.opacity), 1, accuracy: 1e-9)
    }
}
