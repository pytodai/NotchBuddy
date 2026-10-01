import AppKit
import QuartzCore

/// Shows one mascot and plays its state's animation entirely in the render server: the sprite sheet is the
/// layer's `contents`, and a discrete `CAKeyframeAnimation` on `contentsRect` steps through the frames. No
/// timers and no main-thread work per frame; the main thread only touches the layer when the character,
/// the state, Reduce Motion or visibility changes.
///
/// The sprite is drawn at a whole number of device pixels per art pixel (the nearest to the requested
/// size, never less than one) and centred in the layer's bounds, so every art pixel is the same size and
/// perfectly crisp; the sprite may overhang the bounds by a few points, the art's margins are transparent.
final class PixelMascotLayer: CALayer {
    private(set) var character: MascotCharacter = .generic
    private(set) var state: MascotState = .idle
    private(set) var reduceMotion = false
    /// Off while the view is hidden or its window is occluded: animations are removed and the poster frame shows.
    private(set) var isRunning = true
    /// The loop starts at a random phase so several mascots don't breathe or blink in lockstep.
    var randomizesPhase = true

    private let sprite = CALayer()
    /// The layer that carries the sprite contents and frame animations (for the preview renderer's checks).
    var spriteLayer: CALayer { sprite }
    private var sheet: MascotSpriteSheet?
    /// The intro (done's jump, error's fall) plays once per state change, when the state is first shown.
    private var introPending = false

    override init() {
        super.init()
        MascotAnimator.prepare(sprite)
        addSublayer(sprite)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Nothing animates implicitly: frames swap instantly, geometry follows the view without sliding.
    override func action(forKey event: String) -> CAAction? { NSNull() }

    /// `introOnFirstShow`: whether the first state this layer shows plays its intro (a view built for a session
    /// that finished minutes ago should not jump again); every later change of state plays it.
    @MainActor func configure(character: MascotCharacter, state: MascotState, reduceMotion: Bool,
                              introOnFirstShow: Bool = true) {
        guard sheet == nil || character != self.character || state != self.state || reduceMotion != self.reduceMotion else {
            return
        }
        if sheet == nil {
            introPending = introOnFirstShow
        } else if character != self.character || state != self.state {
            introPending = true
        }
        self.character = character
        self.state = state
        self.reduceMotion = reduceMotion
        restart()
    }

    @MainActor func setRunning(_ running: Bool) {
        guard running != isRunning else { return }
        isRunning = running
        restart()
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = max(contentsScale, 1)
        let spriteSide = Self.crispSide(min(bounds.width, bounds.height), scale: scale)
        sprite.contentsScale = scale
        sprite.frame = CGRect(x: bounds.midX - spriteSide / 2, y: bounds.midY - spriteSide / 2,
                              width: spriteSide, height: spriteSide)
        // Snap the origin to device pixels too, so the art grid lines up with the screen's.
        sprite.frame.origin = CGPoint(x: (sprite.frame.minX * scale).rounded() / scale,
                                      y: (sprite.frame.minY * scale).rounded() / scale)
        CATransaction.commit()
    }

    override var contentsScale: CGFloat {
        didSet { sprite.contentsScale = contentsScale; setNeedsLayout() }
    }

    /// The side of the sprite drawn for a `side`-point view at `scale` device pixels per point: a whole number of
    /// device pixels per art pixel (at least one), the nearest to `side`.
    nonisolated static func crispSide(_ side: CGFloat, scale: CGFloat) -> CGFloat {
        let scale = max(scale, 1)
        let canvas = CGFloat(PixelArt.canvasSize)
        return max(1, (side * scale / canvas).rounded()) * canvas / scale
    }

    @MainActor private func restart() {
        let sheet = MascotSpriteSheet.shared(character)
        self.sheet = sheet
        guard let timeline = sheet.timelines[state] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        removeAnimation(forKey: "mascot.pulse")
        opacity = 1
        if reduceMotion {
            MascotAnimator.show(sheet, state, on: sprite, running: false)
            if timeline.pulses && isRunning { add(Self.pulse(), forKey: "mascot.pulse") }
        } else if MascotAnimator.show(sheet, state, on: sprite, running: isRunning, intro: introPending,
                                      randomPhase: randomizesPhase) {
            introPending = false
        }
        CATransaction.commit()
    }

    /// Reduce Motion: a slow, shallow opacity breath instead of frame changes.
    private static func pulse() -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.6
        animation.duration = 1.2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }
}

/// Plays a mascot state on any layer: the character's sprite strip as `contents` and a discrete keyframe animation
/// on `contentsRect` that the render server steps through (the intro once, then the loop forever); the main thread
/// only touches the layer when the state changes. Used by `PixelMascotLayer` and by the island's flying hero mark
/// (`HeroMark`), whose bounds the stage animates with keyframes of its own (`contentsGravity = .resize` and
/// nearest-neighbour filtering keep the art crisp once it rests at a whole number of pixels per art pixel).
@MainActor
enum MascotAnimator {
    static let loopKey = "mascot.loop"
    static let introKey = "mascot.intro"

    /// Prepares a layer for sprite frames (once).
    nonisolated static func prepare(_ layer: CALayer) {
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        layer.contentsGravity = .resize
        layer.isOpaque = false
    }

    /// Shows `state`: its still frame when not `running`, else the intro (when asked and the state has one) and the
    /// loop. Returns whether the frames were set moving (an intro asked for has then been played).
    @discardableResult
    static func show(_ sheet: MascotSpriteSheet, _ state: MascotState, on layer: CALayer, running: Bool,
                     intro: Bool = false, randomPhase: Bool = true) -> Bool {
        guard let timeline = sheet.timelines[state] else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        stop(layer)
        if (layer.contents as AnyObject?) !== sheet.image { layer.contents = sheet.image }
        layer.contentsRect = sheet.contentsRect(timeline.poster)
        guard running else { return false }
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        let playIntro = intro && !timeline.intro.isEmpty
        if let loop = keyframes(timeline.loop, fps: timeline.fps, sheet: sheet) {
            loop.repeatCount = .infinity
            if playIntro {
                // Added first, so the intro (added on top) wins while it runs; `.backwards` holds the loop's
                // first frame underneath, so there is never a gap between the two.
                loop.beginTime = now + timeline.introDuration
                loop.fillMode = .backwards
            } else if randomPhase {
                // A random phase, so several mascots don't breathe or blink in lockstep.
                loop.timeOffset = Double.random(in: 0..<timeline.loopDuration)
            }
            layer.contentsRect = sheet.contentsRect(timeline.loop[0].frame)
            layer.add(loop, forKey: loopKey)
        }
        if playIntro, let intro = keyframes(timeline.intro, fps: timeline.fps, sheet: sheet) {
            intro.beginTime = now
            layer.add(intro, forKey: introKey)
        }
        return true
    }

    /// Stops the frames where they are (the model's frame shows).
    static func stop(_ layer: CALayer) {
        layer.removeAnimation(forKey: loopKey)
        layer.removeAnimation(forKey: introKey)
    }

    private static func keyframes(_ track: [(frame: Int, ticks: Int)], fps: Double,
                                  sheet: MascotSpriteSheet) -> CAKeyframeAnimation? {
        let total = track.reduce(0) { $0 + $1.ticks }
        guard total > 0 else { return nil }
        let animation = CAKeyframeAnimation(keyPath: "contentsRect")
        animation.calculationMode = .discrete
        animation.values = track.map { NSValue(rect: sheet.contentsRect($0.frame)) }
        // Discrete key times: one more than the values, from 0 to 1.
        var elapsed = 0
        var times: [NSNumber] = [0]
        for step in track {
            elapsed += step.ticks
            times.append(NSNumber(value: Double(elapsed) / Double(total)))
        }
        animation.keyTimes = times
        animation.duration = Double(total) / fps
        animation.isRemovedOnCompletion = true
        return animation
    }
}

/// Hosts a `PixelMascotLayer` and pauses it whenever it can't be seen: hidden (itself or an ancestor), out
/// of a window, or the window occluded.
final class PixelMascotNSView: NSView {
    let mascotLayer = PixelMascotLayer()
    private var occlusionObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(mascotLayer)
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Pure decoration: clicks go to whatever the mascot sits in (a session card's button, the island).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mascotLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRunning() }
            }
        }
        updateScale()
        updateRunning()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateRunning()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateRunning()
    }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if mascotLayer.contentsScale != scale { mascotLayer.contentsScale = scale }
    }

    private func updateRunning() {
        let visible = window.map { $0.occlusionState.contains(.visible) } ?? false
        mascotLayer.setRunning(visible && !isHiddenOrHasHiddenAncestor)
    }
}
