import Foundation

// Pure math behind the island's effects (`Sources/NotchBuddy/Effects`): no AppKit, so it is unit-tested
// here and sampled identically by the live Core Animation layers and the `--render-effects` filmstrips.

// MARK: - Random

/// A seeded generator (SplitMix64): particle layouts and confetti colors come out the same in a
/// filmstrip and on screen for the same seed.
public struct FXRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }

    /// Uniform in [a, b).
    public mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
}

// MARK: - Easing

/// Easing curves on 0 … 1 (clamped), and a spring's step response.
public enum FXEase {
    public static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// 0 below `a`, 1 above `b`, a smooth S between.
    public static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        guard b > a else { return x >= b ? 1 : 0 }
        let t = clamp01((x - a) / (b - a))
        return t * t * (3 - 2 * t)
    }

    public static func outCubic(_ t: Double) -> Double {
        let u = 1 - clamp01(t)
        return 1 - u * u * u
    }

    public static func outQuart(_ t: Double) -> Double {
        let u = 1 - clamp01(t)
        return 1 - u * u * u * u
    }

    public static func inCubic(_ t: Double) -> Double {
        let u = clamp01(t)
        return u * u * u
    }

    public static func inOutCubic(_ t: Double) -> Double {
        let u = clamp01(t)
        return u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
    }

    public static func inOutSine(_ t: Double) -> Double { (1 - cos(.pi * clamp01(t))) / 2 }

    /// Overshoots by about `overshoot` × 10 % before settling at 1.
    public static func outBack(_ t: Double, overshoot: Double = 1.4) -> Double {
        let u = clamp01(t) - 1
        return 1 + (overshoot + 1) * u * u * u + overshoot * u * u
    }

    /// A rise to `peak` over [0, `rise`], then an ease back to 0 by 1: the envelope of a flash.
    public static func flash(_ t: Double, rise: Double, peak: Double = 1) -> Double {
        let u = clamp01(t)
        guard u > 0, u < 1 else { return 0 }
        if u < rise { return peak * outCubic(u / max(rise, 1e-6)) }
        return peak * (1 - inOutSine((u - rise) / max(1 - rise, 1e-6)))
    }

    /// Step response 0 → 1 of a spring (`response` in seconds, `damping` ratio, as SwiftUI's `Spring`).
    public static func spring(_ t: Double, response: Double, damping: Double) -> Double {
        guard t > 0 else { return 0 }
        let w0 = 2 * Double.pi / max(response, 1e-4)
        let z = max(damping, 0)
        if z < 1 {
            let wd = w0 * sqrt(1 - z * z)
            return 1 - exp(-z * w0 * t) * (cos(wd * t) + (z * w0 / wd) * sin(wd * t))
        }
        return 1 - exp(-w0 * t) * (1 + w0 * t)
    }

    /// `n` + 1 evenly spaced samples of `f` over [0, 1] (keyframe values).
    public static func samples(_ n: Int, _ f: (Double) -> Double) -> [Double] {
        let count = max(n, 1)
        return (0...count).map { f(Double($0) / Double(count)) }
    }
}

// MARK: - Shake

/// A decaying horizontal shake: x(t) = A · e^(−t/τ) · sin(2π f t), faded to exactly 0 at `duration`.
public struct DampedShake: Equatable, Sendable {
    public var amplitude: Double
    public var frequency: Double
    public var decay: Double
    public var duration: Double

    public init(amplitude: Double = 6, frequency: Double = 7.5, decay: Double = 0.12, duration: Double = 0.5) {
        self.amplitude = amplitude
        self.frequency = frequency
        self.decay = decay
        self.duration = duration
    }

    public static let error = DampedShake()
    public static let nudge = DampedShake(amplitude: 3, frequency: 9, decay: 0.08, duration: 0.3)

    public func offset(at t: Double) -> Double {
        guard t > 0, t < duration else { return 0 }
        let tail = 1 - FXEase.smoothstep(duration * 0.7, duration, t)
        return amplitude * exp(-t / max(decay, 1e-4)) * sin(2 * .pi * frequency * t) * tail
    }
}

// MARK: - Celebration coalescing

/// Several sessions finishing in quick succession do not restart the green celebration each time: the
/// first one plays in full, the next ones (at least `encoreGap` apart) add a smaller "encore" wave on
/// top, up to `maxEncores`; the rest are absorbed. Only after `quiet` seconds without a finish does the
/// next one play in full again.
public struct CelebrationCoalescer: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// A full celebration; `intensity` 1 … 3 (several finished at the same moment).
        case play(intensity: Int)
        /// An encore on the running celebration; `total` finishes in this episode so far.
        case encore(total: Int)
        /// Absorbed by the running celebration.
        case absorb
    }

    public var quiet: TimeInterval
    public var encoreGap: TimeInterval
    public var maxEncores: Int

    public private(set) var lastEventAt: TimeInterval?
    public private(set) var lastPlayAt: TimeInterval = -.infinity
    public private(set) var encores = 0
    public private(set) var total = 0

    public init(quiet: TimeInterval = 1.6, encoreGap: TimeInterval = 0.35, maxEncores: Int = 3) {
        self.quiet = quiet
        self.encoreGap = encoreGap
        self.maxEncores = maxEncores
    }

    public mutating func register(count: Int = 1, at now: TimeInterval) -> Decision {
        let n = max(count, 1)
        defer { lastEventAt = now }
        if let last = lastEventAt, now - last < quiet {
            total += n
            guard encores < maxEncores, now - lastPlayAt >= encoreGap else { return .absorb }
            encores += 1
            lastPlayAt = now
            return .encore(total: total)
        }
        encores = 0
        total = n
        lastPlayAt = now
        return .play(intensity: min(n, 3))
    }
}

// MARK: - Number roll

/// How a number (or a clock like "2:14", a percentage like "73 %") rolls from one text to another: the
/// texts are aligned on the right, like an odometer; each changed digit rolls, a digit that appears or
/// goes away rolls in or out, other characters stay put.
public enum NumberRollPlan {
    public enum Direction: Equatable, Sendable {
        /// Increasing: the old digit leaves upward, the new one comes from below.
        case up
        case down
    }

    public struct Column: Equatable, Sendable {
        public var old: Character?
        public var new: Character?
        /// Position from the right (0 = last character): the rightmost digit rolls first.
        public var index: Int

        public var changes: Bool { old != new }
        public var isDigit: Bool { (new ?? old)?.isNumber ?? false }
    }

    public static func columns(from old: String, to new: String) -> [Column] {
        let a = Array(old), b = Array(new)
        let n = max(a.count, b.count)
        return (0..<n).map { i -> Column in
            // i counts from the left of the longer text; `r` from the right.
            let r = n - 1 - i
            let oa = a.count - 1 - r, nb = b.count - 1 - r
            return Column(old: oa >= 0 ? a[oa] : nil, new: nb >= 0 ? b[nb] : nil, index: r)
        }
    }

    /// Up when the digits read as a larger number (ties and non-numbers roll up too).
    public static func direction(from old: String, to new: String) -> Direction {
        let digits = { (s: String) in s.filter(\.isNumber) }
        let a = digits(old), b = digits(new)
        if a.count != b.count { return b.count > a.count ? .up : .down }
        return b >= a ? .up : .down
    }

    /// Progress of the column `index` (from the right) at overall progress `p`: columns start `stagger`
    /// of the whole run apart, each runs over the same share of it.
    public static func columnProgress(_ p: Double, index: Int, count: Int, stagger: Double = 0.12) -> Double {
        let span = stagger * Double(max(count - 1, 0))
        let share = 1 / (1 + span)
        let start = stagger * Double(index) * share
        return FXEase.clamp01((p - start) / share)
    }
}
