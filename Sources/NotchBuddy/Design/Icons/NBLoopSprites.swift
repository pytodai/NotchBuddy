import AppKit
import SwiftUI

/// Icon loops played by Core Animation: the loop's frames are drawn once (the same `NBIconGlyph`,
/// ~0.1 ms a frame), cached, and handed to the render server as a `contents` keyframe animation. A
/// looping icon then costs the app no work per frame, however long it spins; SwiftUI draws live only
/// while the icon's hover gesture plays.
@MainActor
enum NBSpriteCache {
    struct Key: Hashable {
        var icon: NBIcon
        var size: CGFloat
        var scale: CGFloat
        var ink: Color.Resolved
        var tone: Color.Resolved
        var accent: Color.Resolved?
        var value: Double
        var weight: CGFloat
    }

    struct Sprite {
        var frames: [CGImage]
        var period: Double
        var frameRate: Double
    }

    private static var store: [Key: Sprite] = [:]
    private static var bytes = 0
    /// Frames of every cached loop together stay under this (the cache empties when it would not).
    static let byteBudget = 24 << 20
    static let maximumFrames = 96

    static func sprite(_ key: Key) -> Sprite? {
        if let hit = store[key] { return hit }
        let period = key.icon.loopPeriod
        let count = min(maximumFrames, max(8, Int((period * key.icon.loopFrameRate).rounded())))
        var frames: [CGImage] = []
        frames.reserveCapacity(count)
        for i in 0..<count {
            let glyph = NBIconGlyph(icon: key.icon, color: Color(key.ink), tone: Color(key.tone),
                                    accent: key.accent.map { Color($0) }, weight: key.weight,
                                    hover: 0, value: key.value, phase: Double(i) / Double(count))
                .frame(width: key.size, height: key.size)
            let renderer = ImageRenderer(content: glyph)
            renderer.scale = key.scale
            guard let image = renderer.cgImage else { return nil }
            frames.append(image)
        }
        let size = frames.reduce(0) { $0 + $1.bytesPerRow * $1.height }
        if bytes + size > byteBudget {
            store.removeAll()
            bytes = 0
        }
        let sprite = Sprite(frames: frames, period: period, frameRate: Double(count) / period)
        store[key] = sprite
        bytes += size
        return sprite
    }
}

/// Plays a sprite's frames in a layer, on the shared loop clock (`NBMotion.phase`), so a sprite that
/// replaces the live drawing continues where it was.
struct NBSpriteView: NSViewRepresentable {
    let key: NBSpriteCache.Key
    let sprite: NBSpriteCache.Sprite

    func makeNSView(context: Context) -> NBSpriteNSView {
        let view = NBSpriteNSView()
        view.show(sprite, key: key)
        return view
    }

    func updateNSView(_ view: NBSpriteNSView, context: Context) {
        view.show(sprite, key: key)
    }
}

final class NBSpriteNSView: NSView {
    private let sprite = CALayer()
    private var key: NBSpriteCache.Key?
    private var current: NBSpriteCache.Sprite?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        sprite.contentsGravity = .resizeAspect
        layer?.addSublayer(sprite)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The loop animation is attached (the live check reads this).
    var isPlaying: Bool { sprite.animation(forKey: "loop") != nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.frame = bounds
        CATransaction.commit()
    }

    func show(_ sprite: NBSpriteCache.Sprite, key: NBSpriteCache.Key) {
        guard key != self.key else { return }
        self.key = key
        current = sprite
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.sprite.contentsScale = key.scale
        self.sprite.contents = sprite.frames.first
        CATransaction.commit()
        play()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { sprite.removeAnimation(forKey: "loop") } else { play() }
    }

    private func play() {
        sprite.removeAnimation(forKey: "loop")
        guard window != nil, let current, current.frames.count > 1 else { return }
        let duration = current.period * IslandMotion.slowmo
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = current.frames
        animation.calculationMode = .discrete
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.timeOffset = NBMotion.phase(at: Date(), period: current.period) * duration
        let rate = Float(min(60, current.frameRate))
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: min(10, rate), maximum: rate, preferred: rate)
        sprite.add(animation, forKey: "loop")
    }
}

/// The light band of an active progress bar, as a Core Animation loop.
struct NBShimmerLayer: NSViewRepresentable {
    var period: Double = 1.6

    func makeNSView(context: Context) -> NBShimmerNSView { NBShimmerNSView(period: period) }
    func updateNSView(_ view: NBShimmerNSView, context: Context) {}
}

final class NBShimmerNSView: NSView {
    private let band = CAGradientLayer()
    private let period: Double

    init(period: Double) {
        self.period = period
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        band.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.45).cgColor,
                       NSColor.white.withAlphaComponent(0).cgColor]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.compositingFilter = "plusL"
        layer?.addSublayer(band)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = bounds.height / 2
        let width = max(24, bounds.width * 0.35)
        band.frame = CGRect(x: -width, y: 0, width: width, height: bounds.height)
        CATransaction.commit()
        play()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { band.removeAnimation(forKey: "shimmer") } else { play() }
    }

    private func play() {
        guard window != nil, bounds.width > 0 else { return }
        let width = band.bounds.width
        let duration = period * IslandMotion.slowmo
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = -width / 2
        animation.toValue = bounds.width + width / 2
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.timeOffset = NBMotion.phase(at: Date(), period: period) * duration
        band.add(animation, forKey: "shimmer")
    }
}
