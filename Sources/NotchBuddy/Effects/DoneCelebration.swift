import AppKit
import QuartzCore
import NotchBuddyCore

/// How a "done" celebration looks. Times are seconds from its start.
struct DoneCelebrationStyle: Equatable {
    /// Seconds the two comets take from the ear tips to the bottom center, where they meet.
    var travel: Double = 0.42
    /// How far the glow wave grows beyond the outline of a tall island (a closed one gets about half).
    var reach: CGFloat = 26
    var waveDuration: Double = 0.9
    /// Sparkles in the burst (1 = the standard count).
    var sparkles: Double = 1
    /// Peak of the green aura around the island (shadow opacity).
    var aura: Float = 0.9
    /// Peak of the green wash inside the island.
    var wash: Float = 1
    /// The comets and the traced rim (off: the wave, aura, wash and burst only).
    var comets = true
    /// When the sparkles burst at an anchor (the notice's badge has drawn its check by then).
    var anchorBurst: Double = 0.48
    /// Draw a check at the anchor (off where the anchor draws its own, like the notice's badge).
    var drawsCheck = false
    var checkSize: CGFloat = 12
    /// Seconds until everything has faded.
    var length: Double = 1.6
    /// The soft light around the crisp lines (wide strokes, the comets' glowing heads, the flare): 1 full, 0 crisp
    /// lines only.
    var glow: Double = 1
    /// Gold dots among the green sparks.
    var warmSparks = true

    static let standard = DoneCelebrationStyle()
    /// The island's own: thin green lines trace the outline and meet, one crisp ring leaves it, a few sparks at the
    /// check; no aura and only a whisper of light.
    static let calm = DoneCelebrationStyle(travel: 0.4, reach: 14, waveDuration: 0.75, sparkles: 0.6, aura: 0,
                                           wash: 0.3, anchorBurst: 0.46, length: 1.3, glow: 0.3, warmSparks: false)
    /// `calm` for another session finishing right after: a ring and a flash of the rim.
    static let calmEncore = DoneCelebrationStyle(travel: 0, reach: 12, waveDuration: 0.7, sparkles: 0.4, aura: 0,
                                                 wash: 0.2, comets: false, anchorBurst: 0.05, length: 1.0, glow: 0.3,
                                                 warmSparks: false)
    /// A "done" notice that stays in the notch strip: lighter.
    static let quiet = DoneCelebrationStyle(reach: 18, sparkles: 0.7, aura: 0.6, wash: 0.7)
    /// Another session finished while one celebration runs: a wave, a flash of the rim and a small burst.
    static let encore = DoneCelebrationStyle(travel: 0, reach: 20, waveDuration: 0.8, sparkles: 0.6, aura: 0.75,
                                             wash: 0.6, comets: false, anchorBurst: 0.05, length: 1.1)

    /// When the comets meet at the bottom center (the wave, the flare and the wash start there).
    var meet: Double { comets ? travel : 0.02 }
}

/// The green "done" celebration around the island's outline:
/// - two comets with glowing heads run from the ear tips down both sides and meet at the bottom center,
///   lighting the rim behind them (`.front`);
/// - where they meet: a flare, a glow wave that leaves the outline and fades, and a green aura that swells
///   and settles (`.behind`), and a soft green wash of the island itself (`.inside`);
/// - a burst of small green sparkles and dots that fly out and slow down like sparks, around the anchor
///   (the notice's check) or, without one, downward from the meeting point (`.front`); optionally a check
///   drawn at the anchor.
/// Several finishes in a row coalesce (`CelebrationCoalescer`): the first plays in full, the next add an
/// encore. Reduce Motion: the aura, the wash and the rim fade in and out, nothing moves.
final class DoneCelebrationLayer: FXLayer {
    // .behind
    private var aura: CALayer?
    /// Wave pairs (a soft glow and a crisp line); each play takes the next, so overlapping plays never cut
    /// each other's waves short.
    private var waves: [[CAShapeLayer]] = []
    private var nextWave = 0
    // .inside
    private var wash: CAGradientLayer?
    private var washMask: CAShapeLayer?
    // .front
    private var rims: [CAShapeLayer] = []
    /// The whole edge (an encore flashes it without a trace).
    private var edge: [CAShapeLayer] = []
    private var comets: [[CAShapeLayer]] = []
    private var heads: [CALayer] = []
    private var flare: CALayer?
    private var flareCore: CALayer?
    private var ring: CAShapeLayer?
    private var check: [CAShapeLayer] = []
    private var sprites: [CALayer] = []

    private var outline: FXOutline?
    /// Counts plays: overlapping plays add up (additive animations under their own keys) instead of
    /// replacing each other.
    private var plays = 0
    /// Seeds the burst layout (random per play when 0; fixed in filmstrips).
    var seed: UInt64 = 0

    override init(slot: IslandEffectsSlot) {
        super.init(slot: slot)
        isHidden = true
        build()
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static let cometTiming = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.3, 1)

    private struct CometSpec {
        var lag: Double
        var width: CGFloat
        var color: CGColor
    }

    /// From the widest, faintest tail to the bright core (a stroke's color cannot fade along it; stacked
    /// strokes of growing length make the gradient).
    private static let cometStack = [
        CometSpec(lag: 0.15, width: 6, color: FX.a(FX.green, 0.14)),
        CometSpec(lag: 0.09, width: 3.2, color: FX.a(FX.green, 0.42)),
        CometSpec(lag: 0.05, width: 2.2, color: FX.a(FX.greenBright, 0.85)),
        CometSpec(lag: 0.02, width: 1.8, color: FX.mint),
    ]

    private func build() {
        switch slot {
        case .behind:
            let aura = add(CALayer())
            aura.shadowColor = FX.green
            aura.shadowRadius = 14
            aura.shadowOffset = CGSize(width: 0, height: 3)
            aura.shadowOpacity = 0
            self.aura = aura
            // A soft wide wave with a crisp thin one riding it.
            waves = (0..<3).map { _ in
                [add(CAShapeLayer.fxStroke(FX.a(FX.green, 0.16), width: 8)),
                 add(CAShapeLayer.fxStroke(FX.a(FX.greenBright, 0.8), width: 1.4))]
            }
            for w in waves.joined() { w.opacity = 0 }
        case .inside:
            let wash = add(CAGradientLayer(), canvasSized: false)
            wash.type = .radial
            wash.colors = [FX.a(FX.greenBright, 0.30), FX.a(FX.green, 0.12), FX.a(FX.green, 0)]
            wash.locations = [0, 0.42, 1]
            wash.opacity = 0
            let mask = CAShapeLayer.fxFill(FX.black)
            wash.mask = mask
            self.wash = wash
            washMask = mask
        case .front:
            rims = (0..<2).flatMap { _ in
                [add(CAShapeLayer.fxStroke(FX.a(FX.green, 0.14), width: 5)),
                 add(CAShapeLayer.fxStroke(FX.a(FX.greenBright, 0.55), width: 1.2))]
            }
            for r in rims {
                r.strokeEnd = 0
                r.opacity = 0
            }
            edge = [add(CAShapeLayer.fxStroke(FX.a(FX.green, 0.16), width: 5)),
                    add(CAShapeLayer.fxStroke(FX.a(FX.greenBright, 0.6), width: 1.2))]
            for e in edge { e.opacity = 0 }
            comets = (0..<2).map { _ in
                Self.cometStack.map { spec in
                    let l = add(CAShapeLayer.fxStroke(spec.color, width: spec.width))
                    l.strokeStart = 0
                    l.strokeEnd = 0
                    l.opacity = 0
                    return l
                }
            }
            heads = (0..<2).map { _ in
                let head = add(CALayer(), canvasSized: false)
                head.contents = FXSprites.glow(FX.greenBright, core: FX.white)
                head.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
                head.opacity = 0
                return head
            }
            let flare = add(CALayer(), canvasSized: false)
            flare.contents = FXSprites.glow(FX.greenBright, core: FX.mint)
            flare.bounds = CGRect(x: 0, y: 0, width: 110, height: 16)
            flare.opacity = 0
            self.flare = flare
            let core = add(CALayer(), canvasSized: false)
            core.contents = FXSprites.glow(FX.greenBright, core: FX.white)
            core.bounds = CGRect(x: 0, y: 0, width: 26, height: 26)
            core.opacity = 0
            flareCore = core
            let ring = add(CAShapeLayer.fxStroke(FX.a(FX.greenBright, 0.8), width: 1.3), canvasSized: false)
            ring.opacity = 0
            self.ring = ring
            check = [
                add(CAShapeLayer.fxStroke(FX.a(FX.green, 0.3), width: 6)),
                add(CAShapeLayer.fxStroke(FX.mint, width: 2.2)),
            ]
            for c in check {
                c.strokeEnd = 0
                c.opacity = 0
            }
        }
    }

    override func follow(_ outline: FXOutline) {
        self.outline = outline
        guard !isHidden, !outline.isEmpty else { return }
        FX.quietly { apply(outline) }
    }

    private func apply(_ o: FXOutline) {
        switch slot {
        case .behind:
            aura?.shadowPath = o.closed
            for w in waves.joined() { w.path = o.closed }
        case .inside:
            // A radial gradient from the bottom center, as wide as the island; the clip stays on the canvas.
            let box = o.box
            let r = max(box.width * 0.6, 60)
            let frame = CGRect(x: box.midX - r, y: box.maxY - r, width: 2 * r, height: 2 * r)
            wash?.frame = frame
            wash?.startPoint = CGPoint(x: 0.5, y: 0.5)
            wash?.endPoint = CGPoint(x: 1, y: 1)
            washMask?.frame = CGRect(x: -frame.minX, y: -frame.minY, width: bounds.width, height: bounds.height)
            washMask?.path = o.closed
        case .front:
            let (left, right) = o.halves
            for (i, r) in rims.enumerated() { r.path = i < 2 ? left : right }
            for e in edge { e.path = o.edge }
            for (i, stack) in comets.enumerated() {
                for l in stack { l.path = i == 0 ? left : right }
            }
            flare?.position = o.bottomCenter
            flareCore?.position = o.bottomCenter
        }
    }

    /// Plays one celebration at `begin` (the layer's local time; `FX.now(layer)` is now). `anchor`: where
    /// the sparkles burst (the notice's check), in canvas points; nil bursts from the bottom center downward.
    /// `intensity` 1 … 3: several sessions finished at once.
    /// `settled`: the silhouette the island is heading for, when it is still springing (a notice popping
    /// out as the celebration starts): the wave and the burst, which start later, are laid out on it. The
    /// rim, comets, aura and wash follow the moving shape frame by frame (`follow`).
    func play(at begin: CFTimeInterval, style: DoneCelebrationStyle = .standard, intensity: Int = 1,
              anchor: CGPoint? = nil, reduceMotion: Bool = false, settled: FXOutline? = nil) {
        guard var o = outline, !o.isEmpty else { return }
        if let settled, !settled.isEmpty { o = settled }
        isHidden = false
        FX.quietly { apply(outline ?? o) }
        let k = 1 + 0.25 * Double(min(max(intensity, 1), 3) - 1)
        plays &+= 1
        if reduceMotion {
            playReduced(begin, o)
            return
        }
        switch slot {
        case .behind: playBehind(begin, style, o, k)
        case .inside: playInside(begin, style)
        case .front: playFront(begin, style, o, k, anchor)
        }
    }

    // MARK: Behind: aura and waves

    private func playBehind(_ t0: CFTimeInterval, _ s: DoneCelebrationStyle, _ o: FXOutline, _ k: Double) {
        let meet = s.meet
        if let aura, s.aura > 0 {
            let peak = Double(s.aura) * min(k, 1.2)
            let L = s.length
            addShared(FX.keys("shadowOpacity", [0, peak * 0.35, peak, peak * 0.5, 0],
                              times: [0, meet * 0.85 / L, min((meet + 0.14) / L, 0.5), 0.66, 1],
                              duration: L, begin: t0, timings: [FX.easeInOut, FX.easeOut, FX.easeInOut, FX.easeInOut]),
                      to: aura, "celebrate")
            aura.add(FX.keys("shadowRadius", [10, 13, 20, 24], times: [0, meet / L, 0.55, 1],
                             duration: L, begin: t0, timings: [FX.easeInOut, FX.easeOut, FX.easeOut]),
                     forKey: "celebrateRadius")
        }
        // A closed island (≈ 36 pt) gets about half the reach of a notice or the list.
        let reach = s.reach * CGFloat(k) * min(max(o.box.height / 80, 0.5), 1)
        let begin = t0 + meet - 0.02
        let pair = waves[nextWave % waves.count]
        nextWave &+= 1
        for (i, wave) in pair.enumerated() {
            let soft = i == 0
            // Both reach as far at the same pace: one glowing ring (the soft stroke is the crisp one's glow).
            let d = s.waveDuration
            let to = o.grown(reach)
            wave.add(FX.basic("path", o.closed, to, duration: d, begin: begin, timing: FX.easeOut), forKey: "grow")
            wave.add(FX.basic("lineWidth", soft ? 5 : 1.7, soft ? 11 : 0.6, duration: d, begin: begin), forKey: "width")
            let glow = s.glow
            wave.add(FX.curve("opacity", duration: d, begin: begin) { t in
                FXEase.flash(t, rise: soft ? 0.1 : 0.05) * (soft ? glow : 1 - 0.35 * t)
            }, forKey: "fade")
        }
        retire(at: t0 + s.length + 0.1)
    }

    // MARK: Inside: wash

    private func playInside(_ t0: CFTimeInterval, _ s: DoneCelebrationStyle) {
        guard let wash else { return }
        let start = s.meet * 0.7
        let d = s.length - start
        addShared(FX.curve("opacity", duration: d, begin: t0 + start) { FXEase.flash($0, rise: 0.18, peak: Double(s.wash)) },
                  to: wash, "fade")
        // The wash spreads from the bottom center (its radius grows; the clip stays put).
        wash.add(FX.basic("endPoint", NSValue(point: CGPoint(x: 0.7, y: 0.7)), NSValue(point: CGPoint(x: 1.05, y: 1.05)),
                          duration: d * 0.7, begin: t0 + start), forKey: "spread")
        retire(at: t0 + s.length + 0.1)
    }

    // MARK: Front: rim, comets, flare, burst, check

    private func playFront(_ t0: CFTimeInterval, _ s: DoneCelebrationStyle, _ o: FXOutline, _ k: Double,
                           _ anchor: CGPoint?) {
        let meet = s.meet
        let (left, right) = o.halves
        if s.comets {
            // The rim lights up behind the comets and stays lit a moment after they meet.
            for (i, r) in rims.enumerated() {
                let trace = FX.basic("strokeEnd", 0, 1, duration: s.travel, begin: t0, timing: Self.cometTiming)
                trace.fillMode = .both
                trace.isRemovedOnCompletion = false
                r.add(trace, forKey: "trace")
                // Pairs of (soft, crisp): the soft one is light around the line.
                let k = i.isMultiple(of: 2) ? s.glow : 1
                addShared(FX.curve("opacity", duration: s.length, begin: t0) { t in
                    let x = t * s.length
                    return k * FXEase.smoothstep(0, 0.05, x) * (1 - FXEase.smoothstep(meet + 0.05, meet + 0.7, x))
                }, to: r, "fade")
            }
            // Comets: strokeEnd is the head, strokeStart the same run a little later, so the tail is as long
            // as the speed: it stretches mid-run and shrinks into the meeting point.
            for stack in comets {
                for (i, l) in stack.enumerated() {
                    let lag = Self.cometStack[i].lag
                    // The two widest strokes are the comet's glow.
                    let k = i < 2 ? s.glow : 1
                    l.add(FX.basic("strokeEnd", 0, 1, duration: s.travel, begin: t0, timing: Self.cometTiming), forKey: "end")
                    l.add(FX.basic("strokeStart", 0, 1, duration: s.travel, begin: t0 + lag, timing: Self.cometTiming),
                          forKey: "start")
                    l.add(FX.curve("opacity", duration: s.travel + lag, begin: t0) { t in
                        k * FXEase.smoothstep(0, 0.05, t * (s.travel + lag))
                    }, forKey: "fade")
                }
            }
            // A glowing head on each comet, fading as it arrives.
            for (i, head) in heads.enumerated() {
                let move = CAKeyframeAnimation(keyPath: "position")
                move.path = i == 0 ? left : right
                move.calculationMode = .paced
                move.timingFunction = Self.cometTiming
                move.duration = s.travel
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                let peak = min(1, 0.25 + 0.75 * s.glow)
                fade.values = [0, peak, peak, 0]
                fade.keyTimes = [0, 0.12, 0.8, 1]
                fade.duration = s.travel
                head.add(FX.group([move, fade], begin: t0, duration: s.travel), forKey: "run")
            }
        } else {
            // An encore: the whole rim flashes.
            for e in edge {
                addShared(FX.curve("opacity", duration: 0.7, begin: t0) { FXEase.flash($0, rise: 0.12, peak: 0.9) }, to: e, "fade")
            }
        }
        // The flare where the comets meet: a horizontal streak and a round core.
        if let flare, let flareCore {
            let begin = t0 + meet - 0.04
            let glow = s.glow
            addShared(FX.curve("opacity", duration: 0.5, begin: begin) { FXEase.flash($0, rise: 0.1, peak: 0.85 * glow) },
                      to: flare, "fade")
            flare.add(FX.basic("transform.scale.x", 0.25, 1.4 * k, duration: 0.5, begin: begin), forKey: "stretch")
            addShared(FX.curve("opacity", duration: 0.36, begin: begin) { FXEase.flash($0, rise: 0.14, peak: 0.95 * min(1, 0.3 + glow)) },
                      to: flareCore, "fade")
            flareCore.add(FX.basic("transform.scale", 0.4, 1.0, duration: 0.36, begin: begin), forKey: "grow")
        }
        // The burst.
        let burstAt = anchor != nil ? max(s.anchorBurst, s.comets ? 0 : 0.03) : meet
        let seed = self.seed == 0 ? UInt64.random(in: 1...UInt64.max) : self.seed &+ UInt64(sprites.count)
        let burst: FXBurst
        if let anchor {
            // All around the badge but toward the text on its right (π/2 points down, π left).
            burst = FXBurst(origin: anchor, angles: (0.36 * .pi)...(1.66 * .pi), startRadius: 9, gravity: 6,
                            kinds: Self.sparkKinds(s, radial: true), seed: seed)
        } else {
            // Downward from the bottom edge, in a fan (π/2 points down on the canvas).
            burst = FXBurst(origin: CGPoint(x: o.bottomCenter.x, y: o.bottomCenter.y + 1),
                            angles: (0.1 * .pi)...(0.9 * .pi), startRadius: 2, spread: Double(o.body.width) * 0.3,
                            gravity: 14, kinds: Self.sparkKinds(s, radial: false), seed: seed)
        }
        sprites += burst.play(in: self, begin: t0 + burstAt, scale: k)
        if let anchor, let ring {
            ring.frame = CGRect(x: anchor.x - 11, y: anchor.y - 11, width: 22, height: 22)
            ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)
            let begin = t0 + burstAt - 0.02
            ring.add(FX.basic("transform.scale", 0.8, 2.2, duration: 0.55, begin: begin), forKey: "grow")
            ring.add(FX.curve("opacity", duration: 0.55, begin: begin) { FXEase.flash($0, rise: 0.06, peak: 0.7) }, forKey: "fade")
        }
        if s.drawsCheck, let anchor {
            let size = s.checkSize
            let rect = CGRect(x: anchor.x - size / 2, y: anchor.y - size * 0.38, width: size, height: size * 0.76)
            let path = CheckmarkShape().path(in: rect).cgPath
            for c in check {
                c.path = path
                c.add(FX.curve("strokeEnd", duration: s.length, begin: t0) { t in
                    FXEase.outCubic((t * s.length - 0.14) / 0.3)
                }, forKey: "draw")
                c.add(FX.curve("opacity", duration: s.length, begin: t0) { t in
                    let x = t * s.length
                    return FXEase.smoothstep(0.12, 0.18, x) * (1 - FXEase.smoothstep(s.length - 0.35, s.length, x))
                }, forKey: "fade")
            }
        }
        retire(at: t0 + s.length + 0.1)
    }

    private static func sparkKinds(_ s: DoneCelebrationStyle, radial: Bool) -> [FXBurst.Kind] {
        let n = s.sparkles
        let far: ClosedRange<Double> = radial ? 16...34 : 20...54
        return [
            FXBurst.Kind(image: FXSprites.sparkle, size: 11, colors: [FX.greenBright, FX.mint, FX.green],
                         count: Int((9 * n).rounded()), distance: far, duration: 0.6...0.9, spin: 2.2),
            FXBurst.Kind(image: FXSprites.dot, size: 4.5, colors: s.warmSparks ? [FX.mint, FX.greenBright, FX.gold]
                                                                                : [FX.mint, FX.greenBright, FX.white],
                         count: Int((12 * n).rounded()), distance: (far.lowerBound * 1.1)...(far.upperBound * 1.35),
                         duration: 0.5...0.8),
        ]
    }

    // MARK: Reduce Motion

    private func playReduced(_ t0: CFTimeInterval, _ o: FXOutline) {
        let length = 1.2
        let fade = { (peak: Double) in FX.curve("opacity", duration: length, begin: t0) { FXEase.flash($0, rise: 0.3, peak: peak) } }
        switch slot {
        case .behind:
            if let aura {
                addShared(FX.curve("shadowOpacity", duration: length, begin: t0) { FXEase.flash($0, rise: 0.3, peak: 0.7) },
                          to: aura, "celebrate")
            }
        case .inside:
            if let wash { addShared(fade(0.8), to: wash, "fade") }
        case .front:
            for e in edge { addShared(fade(0.7), to: e, "fade") }
        }
        retire(at: t0 + length + 0.1)
    }

    /// Opacity-like animations add up under their own key: an encore swells what is already glowing.
    private func addShared(_ animation: CAPropertyAnimation, to layer: CALayer, _ key: String) {
        animation.isAdditive = true
        layer.add(animation, forKey: "\(key)-\(plays)")
    }

    override func didRetire() {
        for sprite in sprites { sprite.removeFromSuperlayer() }
        sprites.removeAll()
    }
}
