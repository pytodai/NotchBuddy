import QuartzCore
import SwiftUI

/// A damped spring moving a vector of numbers from where it is (with the speed it has) toward a target: the same
/// oscillator as SwiftUI's `Spring(response:dampingRatio:)` (mass 1, stiffness (2π / response)², damping
/// 4π·ζ / response), solved in closed form, so it can be evaluated at any moment.
///
/// The stage bakes these into Core Animation keyframes (`IslandTimeline`): the render server plays them, and a
/// change of mind mid-flight (`retargeted`) starts the next spring from the current one's exact value *and speed*
/// at that moment — which is exactly what is on screen, since the screen shows the very same function.
/// (`CASpringAnimation` cannot do that for a shape: its initial velocity is one number for the whole path.)
struct SpringTrack: Equatable {
    var from: [Double]
    var to: [Double]
    var velocity: [Double]
    var response: Double
    var damping: Double
    /// Media time (`CACurrentMediaTime`) at which the spring starts.
    var start: CFTimeInterval
    /// `NOTCHBUDDY_SLOWMO`: local time runs this many times slower.
    var slowmo: Double = IslandMotion.slowmo

    /// Not moving: `value` everywhere.
    static func rest(_ value: [Double], at time: CFTimeInterval = 0) -> SpringTrack {
        SpringTrack(from: value, to: value, velocity: Array(repeating: 0, count: value.count), response: 0.3, damping: 1,
                    start: time)
    }

    init(from: [Double], to: [Double], velocity: [Double]? = nil, response: Double, damping: Double, start: CFTimeInterval,
         slowmo: Double = IslandMotion.slowmo) {
        precondition(from.count == to.count)
        self.from = from
        self.to = to
        self.velocity = velocity ?? Array(repeating: 0, count: from.count)
        self.response = response
        self.damping = damping
        self.start = start
        self.slowmo = slowmo
    }

    init(from: [Double], to: [Double], spring: Spring, start: CFTimeInterval) {
        self.init(from: from, to: to, response: spring.response, damping: spring.dampingRatio, start: start)
    }

    private var omega: Double { 2 * .pi / max(response, 0.0001) }

    /// Seconds of the spring's own clock at media time `time`.
    private func local(_ time: CFTimeInterval) -> Double { max(0, (time - start) / slowmo) }

    /// Displacement from the target and its speed, `t` seconds in, for one component.
    private func solve(_ x0: Double, _ v0: Double, _ t: Double) -> (x: Double, v: Double) {
        let w = omega
        let z = min(damping, 1)
        if z >= 1 {
            // Critically damped.
            let e = exp(-w * t)
            let b = v0 + w * x0
            let x = e * (x0 + b * t)
            let v = e * (b - w * (x0 + b * t))
            return (x, v)
        }
        let wd = w * sqrt(1 - z * z)
        let e = exp(-z * w * t)
        let b = (v0 + z * w * x0) / wd
        let c = cos(wd * t), s = sin(wd * t)
        let x = e * (x0 * c + b * s)
        // d/dt of e·(x0·c + b·s)
        let v = e * ((-z * w) * (x0 * c + b * s) + (-x0 * wd * s + b * wd * c))
        return (x, v)
    }

    /// The value at media time `time`.
    func value(at time: CFTimeInterval) -> [Double] {
        let t = local(time)
        guard t > 0 else { return from }
        return (0..<from.count).map { i in
            to[i] + solve(from[i] - to[i], velocity[i], t).x
        }
    }

    /// Units per second of media time, at `time`.
    func speed(at time: CFTimeInterval) -> [Double] {
        let t = local(time)
        return (0..<from.count).map { i in
            (t > 0 ? solve(from[i] - to[i], velocity[i], t).v : velocity[i]) / slowmo
        }
    }

    /// The spring heading for `target` from where this one is at `time`, keeping its speed.
    func retargeted(to target: [Double], response: Double, damping: Double, at time: CFTimeInterval) -> SpringTrack {
        let v = speed(at: time).map { $0 * slowmo }
        return SpringTrack(from: value(at: time), to: target, velocity: v, response: response, damping: damping,
                           start: time, slowmo: slowmo)
    }

    func retargeted(to target: [Double], spring: Spring, at time: CFTimeInterval) -> SpringTrack {
        retargeted(to: target, response: spring.response, damping: spring.dampingRatio, at: time)
    }

    /// Media time from which every component stays within `epsilon` of the target (and slower than `epsilon` × 10
    /// per second), at most 3 s (of the spring's clock) after the start.
    func settleTime(epsilon: Double = 0.02) -> CFTimeInterval {
        guard from != to || velocity.contains(where: { $0 != 0 }) else { return start }
        let w = omega
        let z = min(damping, 1)
        // The envelope bounds every component; step forward until all of them are inside.
        var t = 0.0
        let step = 1.0 / 240
        while t < 3 {
            var settled = true
            for i in 0..<from.count {
                let x0 = from[i] - to[i], v0 = velocity[i]
                let bound: Double
                if z >= 1 {
                    bound = exp(-w * t) * (abs(x0) + abs(v0 + w * x0) * t)
                } else {
                    let wd = w * sqrt(1 - z * z)
                    bound = exp(-z * w * t) * (abs(x0) + abs((v0 + z * w * x0) / wd))
                }
                if bound > epsilon { settled = false; break }
            }
            if settled { break }
            t += step
        }
        return start + t * slowmo
    }

    var isMoving: Bool { from != to || velocity.contains { $0 != 0 } }
}

extension IslandGeometry {
    /// (width, height, ear, bottom, shadow, top, crown).
    var vector: [Double] {
        [Double(width), Double(height), Double(ear), Double(bottom), shadow, Double(top), Double(crown)]
    }

    init(vector v: [Double]) {
        self.init(width: CGFloat(v[0]), height: CGFloat(v[1]), ear: CGFloat(v[2]), bottom: CGFloat(v[3]), shadow: v[4],
                  top: v.count > 5 ? CGFloat(v[5]) : 0, crown: v.count > 6 ? CGFloat(v[6]) : 0)
    }
}

extension CGRect {
    var vector: [Double] { [Double(midX), Double(midY), Double(width), Double(height)] }

    /// From (midX, midY, width, height).
    init(vector v: [Double]) {
        self.init(x: v[0] - v[2] / 2, y: v[1] - v[3] / 2, width: v[2], height: v[3])
    }
}
