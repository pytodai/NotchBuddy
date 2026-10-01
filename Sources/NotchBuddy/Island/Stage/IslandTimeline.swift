import AppKit
import QuartzCore

/// Every animated value of the island's stage is a function of media time. `IslandTimeline.run` bakes one into a
/// Core Animation keyframe animation that the render server plays on its own (live): the main thread commits a
/// transition once, at its start, and does nothing per frame. The same functions are kept, so the stage can also
/// be drawn exactly as it looks at any moment (`apply(at:)`: film mode, used by `--render-perf`), and a transition
/// interrupted mid-flight can start from what is on screen (`value(_:_:at:)`).
///
/// Only keys the stage owns are animated: properties of layers it created, and on layers backing AppKit views only
/// `opacity`, `sublayerTransform` and the path of a mask it created (AppKit resets a view layer's `transform`).
@MainActor
final class IslandTimeline {
    /// Keyframes per second of media time (a 120 Hz display gets a keyframe per frame; the render server
    /// interpolates linearly between them).
    static let rate: Double = 120

    /// Film mode: tracks are only recorded; `apply(at:)` draws a moment.
    var filming = false

    private struct TrackKey: Hashable {
        let layer: ObjectIdentifier
        let key: String
    }

    private struct Track {
        weak var layer: CALayer?
        let keyPath: String
        let start: CFTimeInterval
        let end: CFTimeInterval
        let sample: (CFTimeInterval) -> Any
    }

    private var tracks: [TrackKey: Track] = [:]

    /// Animates `keyPath` of `layer` from `start` to `end` along `sample` (a function of media time). The model value
    /// becomes `sample(end)`. A track for the same layer and key replaces the previous one.
    func run(_ layer: CALayer, _ keyPath: String, key: String? = nil, from start: CFTimeInterval, until end: CFTimeInterval,
             sample: @escaping (CFTimeInterval) -> Any) {
        let key = key ?? keyPath
        let end = max(end, start + 1 / Self.rate)
        tracks[TrackKey(layer: ObjectIdentifier(layer), key: key)] =
            Track(layer: layer, keyPath: keyPath, start: start, end: end, sample: sample)
        if tracks.count > 256 { prune(before: start) }
        guard !filming else { return }
        let count = max(2, Int(((end - start) * Self.rate).rounded(.up)) + 1)
        var values: [Any] = []
        var times: [NSNumber] = []
        values.reserveCapacity(count)
        times.reserveCapacity(count)
        for i in 0..<count {
            let f = Double(i) / Double(count - 1)
            values.append(sample(start + f * (end - start)))
            times.append(NSNumber(value: f))
        }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times
        animation.calculationMode = .linear
        animation.beginTime = layer.convertTime(start, from: nil)
        animation.duration = end - start
        animation.fillMode = .both
        animation.isRemovedOnCompletion = true
        setModel(layer, keyPath, values[values.count - 1])
        layer.add(animation, forKey: key)
    }

    /// Sets `keyPath` to `value` at once (and forgets any track of it).
    func set(_ layer: CALayer, _ keyPath: String, key: String? = nil, _ value: Any) {
        let key = key ?? keyPath
        tracks[TrackKey(layer: ObjectIdentifier(layer), key: key)] = nil
        if !filming { layer.removeAnimation(forKey: key) }
        setModel(layer, keyPath, value)
    }

    /// What the track of `key` on `layer` shows at media time `t` (its model value when it has no track).
    func value(_ layer: CALayer, _ key: String, at t: CFTimeInterval) -> Any? {
        if let track = tracks[TrackKey(layer: ObjectIdentifier(layer), key: key)], track.layer === layer {
            return track.sample(min(max(t, track.start), track.end))
        }
        return layer.value(forKeyPath: key)
    }

    /// The track of `key` on `layer` is still moving at `t`.
    func isRunning(_ layer: CALayer, _ key: String, at t: CFTimeInterval) -> Bool {
        guard let track = tracks[TrackKey(layer: ObjectIdentifier(layer), key: key)], track.layer === layer else { return false }
        return t < track.end
    }

    /// Film mode: every tracked layer shows its value at media time `t`.
    func apply(at t: CFTimeInterval) {
        for track in tracks.values {
            guard let layer = track.layer else { continue }
            setModel(layer, track.keyPath, track.sample(min(max(t, track.start), track.end)))
        }
    }

    /// Forgets tracks of layers that are gone, and tracks that ended before `time`.
    func prune(before time: CFTimeInterval) {
        tracks = tracks.filter { $0.value.layer != nil && $0.value.end >= time - 1 }
    }

    /// Forgets one track (its animation is the caller's to remove).
    func forget(_ layer: CALayer, key: String) {
        tracks[TrackKey(layer: ObjectIdentifier(layer), key: key)] = nil
    }

    func forget(_ layer: CALayer) {
        tracks = tracks.filter { $0.key.layer != ObjectIdentifier(layer) }
    }

    private func setModel(_ layer: CALayer, _ keyPath: String, _ value: Any) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
    }

    // MARK: Values

    static func number(_ x: Double) -> NSNumber { NSNumber(value: x) }
    static func transform(_ t: CATransform3D) -> NSValue { NSValue(caTransform3D: t) }
    static func point(_ p: CGPoint) -> NSValue { NSValue(point: p) }
    static func rect(_ r: CGRect) -> NSValue { NSValue(rect: r) }
}

/// Opacity and a 2D move / scale of one layer, about an anchor point in its (top-left origin) coordinates.
struct IslandPose: Equatable {
    var opacity: Double = 1
    var scale: CGFloat = 1
    var dx: CGFloat = 0
    var dy: CGFloat = 0

    static let identity = IslandPose()

    /// `other` applied after (outside) this one: opacities multiply, scales multiply, offsets add.
    func then(_ other: IslandPose) -> IslandPose {
        IslandPose(opacity: opacity * other.opacity, scale: scale * other.scale, dx: dx * other.scale + other.dx,
                   dy: dy * other.scale + other.dy)
    }

    /// As a transform of a layer whose anchor is its top-left corner, scaling about `anchor`.
    func transform(anchor: CGPoint) -> CATransform3D {
        var t = CATransform3DMakeTranslation(anchor.x + dx, anchor.y + dy, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -anchor.x, -anchor.y, 0)
    }
}
