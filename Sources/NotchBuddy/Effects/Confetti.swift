import AppKit
import QuartzCore
import NotchBuddyCore

/// Confetti-lite for milestones (say, a long session finished, the tenth "done" of the day): two short
/// bursts of strips and discs pop from the island's lower corners, arc outward and flutter down, fading
/// before they fall far (`.front`). A few dozen pieces, one CAEmitterLayer per side, gone in ~2 s.
/// Reduce Motion: nothing.
final class ConfettiLayer: FXLayer {
    struct Style: Equatable {
        var colors: [CGColor] = [FX.green, FX.greenBright, FX.mint, FX.gold, FX.white,
                                 CGColor(srgbRed: 0.47, green: 0.62, blue: 1.0, alpha: 1),
                                 CGColor(srgbRed: 1.0, green: 0.55, blue: 0.45, alpha: 1)]
        /// Pieces per side.
        var pieces: Float = 30
        var length: Double = 2.2

        static let standard = Style()
    }

    var look = Style.standard
    /// Fixed in filmstrips (random per burst when 0).
    var seed: UInt32 = 0
    private var emitters: [CAEmitterLayer] = []

    override init(slot: IslandEffectsSlot) {
        super.init(slot: slot)
        isHidden = true
        guard slot == .front else { return }
        emitters = (0..<2).map { _ in
            let e = CAEmitterLayer()
            e.actions = Self.noActions
            e.birthRate = 0
            e.renderMode = .unordered
            e.emitterShape = .circle
            e.emitterMode = .volume
            e.emitterSize = CGSize(width: 16, height: 16)
            addSublayer(e)
            return e
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var outline: FXOutline?

    override func follow(_ outline: FXOutline) {
        self.outline = outline
    }

    func play(at begin: CFTimeInterval, reduceMotion: Bool = false) {
        guard slot == .front, !reduceMotion, let o = outline, !o.isEmpty else { return }
        isHidden = false
        let body = o.body
        let corner = min(body.height * 0.5, 18)
        for (i, e) in emitters.enumerated() {
            let left = i == 0
            FX.quietly {
                e.frame = bounds
                e.emitterPosition = CGPoint(x: left ? body.minX + corner * 0.4 : body.maxX - corner * 0.4,
                                            y: body.maxY - corner * 0.4)
                e.seed = seed == 0 ? UInt32.random(in: 1...UInt32.max) : seed &+ UInt32(i)
            }
            // Out and down from each lower corner (π/2 is straight down, 0 right, π left), pulled back
            // inward as they fall: they stay within the panel's canvas (~100 pt beside a notice).
            let longitude: CGFloat = left ? .pi * 0.72 : .pi * 0.28
            // The emitter's clock starts at the burst: an emitter left idle would otherwise catch up on the
            // time it missed with the burst's birth rate (a clump of pre-aged pieces).
            e.beginTime = begin
            e.emitterCells = cells(longitude: longitude, inward: left ? 1 : -1)
            let on = FX.basic("birthRate", 1, 1, duration: 0.1, begin: 0.0001, timing: FX.linear)
            on.fillMode = .removed
            e.add(on, forKey: "burst")
        }
        retire(at: begin + look.length)
    }

    private func cells(longitude: CGFloat, inward: CGFloat) -> [CAEmitterCell] {
        let rate = look.pieces / 0.1 / Float(look.colors.count) / 2
        // Each cell (a color × a shape) gets its own drift and weight, so the burst opens up as it falls
        // instead of moving as a clump.
        var rng = FXRandom(seed: UInt64(seed == 0 ? UInt32.random(in: 1...UInt32.max) : seed))
        return look.colors.flatMap { color -> [CAEmitterCell] in
            [FXSprites.strip, FXSprites.disc].map { image in
                let c = CAEmitterCell()
                c.contents = FXSprites.tinted(image, color)
                c.birthRate = rate
                c.lifetime = 1.5
                c.lifetimeRange = 0.4
                c.velocity = CGFloat(rng.range(110, 170))
                c.velocityRange = 60
                c.emissionLongitude = longitude + CGFloat(rng.range(-0.12, 0.12)) * .pi
                c.emissionRange = .pi * 0.36
                c.yAcceleration = CGFloat(rng.range(200, 300))
                c.xAcceleration = CGFloat(rng.range(30, 110)) * inward
                c.scale = image === FXSprites.strip ? 0.55 : 0.5
                c.scaleRange = 0.15
                c.spin = 0
                c.spinRange = 9
                // Fully visible for most of the flight, then gone.
                c.alphaRange = 0.1
                c.alphaSpeed = -0.6
                return c
            }
        }
    }

    override func didRetire() {
        for e in emitters { e.emitterCells = nil }
    }
}
