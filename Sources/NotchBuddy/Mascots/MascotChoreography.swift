/// A state's animation: an optional one-shot intro (done: the bounce; error: the shake and slump), then a loop.
struct MascotClip {
    struct Frame: Hashable {
        let art: PixelArt
        /// How long the frame stays up, in 1/`fps` s.
        let ticks: Int
    }

    let fps: Double
    let intro: [Frame]
    let loop: [Frame]
    /// Reduce Motion: the one frame shown instead of the animation.
    let poster: PixelArt
    /// Reduce Motion: whether that still frame pulses its opacity (busy states only).
    let pulses: Bool

    var introDuration: Double { Double(intro.reduce(0) { $0 + $1.ticks }) / fps }
    var loopDuration: Double { Double(loop.reduce(0) { $0 + $1.ticks }) / fps }
}

/// Shared effect sprites, drawn in the character's own palette (plus the shared prop neutrals).
enum MascotFX {
    /// Speech bubble with "!"; its tail points down towards the head.
    static let bubble = PixelArt("""
        .www.
        wwkww
        wwkww
        wwwww
        wwkww
        .www.
        ..w..
        """)
    static let sparkleBig = PixelArt("""
        ..a..
        ..a..
        aawaa
        ..a..
        ..a..
        """)
    static let sparkle = PixelArt("""
        .a.
        awa
        .a.
        """)
    static let glint = PixelArt("w")
    static let dot = PixelArt("a")
    /// Kimi's blue dot.
    static let brandDot = PixelArt("""
        aa
        aa
        """)
    /// A thought dot, a raindrop, a tear.
    static let thought = PixelArt("w")
    static let drop = PixelArt("b")
    static let tear = PixelArt("""
        b
        b
        """)
}

/// The six states' choreography, shared by every character. Frame counts and timing live here; the
/// characters supply parts and signature moves (`MascotRig`): Codex's cursor, Claude's spinning rays,
/// Kimi's bouncing dot.
enum MascotChoreography {
    static func clip(_ state: MascotState, rig: MascotRig) -> MascotClip {
        switch state {
        case .idle: return idle(rig)
        case .working: return working(rig)
        case .waiting: return waiting(rig)
        case .done: return done(rig)
        case .error: return error(rig)
        case .thinking: return thinking(rig)
        }
    }

    typealias Pose = MascotRig.Pose
    typealias Point = MascotRig.Point

    // MARK: States

    /// Breathing (a one-pixel squash every 0.75 s) and an occasional blink; Codex blinks its `_` cursor
    /// instead, Kimi's dot gives a little hop.
    static func idle(_ rig: MascotRig) -> MascotClip {
        let stand = rig.draw(Pose())
        let squash = rig.draw(Pose(squash: 1))
        var loop = Reel()
        if rig.cursorBlink {
            let standOff = rig.draw(Pose(face: .blink))
            let squashOff = rig.draw(Pose(face: .blink, squash: 1))
            loop.add(stand, 4); loop.add(standOff, 4); loop.add(squash, 4); loop.add(squashOff, 4)
        } else {
            let blink = rig.draw(Pose(face: .blink))
            let hop = rig.draw(Pose(dotDY: -1))
            loop.add(stand, 6); loop.add(squash, 6)
            loop.add(stand, 2); loop.add(hop, 2); loop.add(stand, 2)
            loop.add(squash, 6)
            loop.add(stand, 3); loop.add(blink, 1); loop.add(stand, 2); loop.add(squash, 6)
        }
        return MascotClip(fps: 8, intro: [], loop: loop.frames, poster: stand, pulses: false)
    }

    /// Busy: feet patter and the body bobs twice a beat. Codex's cursor blinks fast, Claude's rays spin a
    /// step every frame, Kimi's dot bounces on its perch, arms swing.
    static func working(_ rig: MascotRig) -> MascotClip {
        let dotHop = [0, -2, -1, 0]
        let length = rig.halo.isEmpty ? 8 : lcm(8, rig.halo.count)
        var loop = Reel()
        var poster: PixelArt?
        for tick in 0..<length {
            var pose = Pose()
            switch tick % 4 {
            case 0: pose.arms = .swingA; pose.legs = .stepA; pose.bodyDY = -1
            case 2: pose.arms = .swingB; pose.legs = .stepB; pose.bodyDY = -1
            default: break
            }
            pose.halo = tick
            pose.dotDY = dotHop[tick % dotHop.count]
            if rig.cursorBlink { pose.face = tick % 4 < 2 ? .open : .blink }
            let art = rig.draw(pose)
            if poster == nil { poster = art }
            loop.add(art)
        }
        return MascotClip(fps: 8, intro: [], loop: loop.frames, poster: poster ?? rig.draw(Pose()), pulses: true)
    }

    /// Needs you: a "!" bubble hops over the head while the character waves (or, armless, sways side to
    /// side). Codex's cursor blinks, waiting for input.
    static func waiting(_ rig: MascotRig) -> MascotClip {
        let hop = [1, 0, 0, 1, 1, 1, 1, 1]
        let sway = [0, 0, -1, -1, 0, 0, 1, 1]
        let waves = rig.arms[.waveA] != nil
        var loop = Reel()
        func frame(_ tick: Int) -> PixelArt {
            var pose = Pose()
            if rig.cursorBlink {
                pose.face = (tick / 4) % 2 == 0 ? .open : .blink
            } else if tick == 13 {
                pose.face = .blink
            }
            if waves {
                pose.arms = (tick / 2) % 2 == 0 ? .waveA : .waveB
            } else {
                pose.bodyDX = sway[tick % sway.count]
            }
            pose.dotDY = tick % 8 == 1 || tick % 8 == 2 ? -1 : 0
            return rig.draw(pose).overlaying(MascotFX.bubble, x: rig.bubbleOrigin.x,
                                             y: rig.bubbleOrigin.y + hop[tick % hop.count])
        }
        for tick in 0..<16 { loop.add(frame(tick)) }
        return MascotClip(fps: 8, intro: [], loop: loop.frames, poster: frame(0), pulses: true)
    }

    /// A crouch and a happy bounce with a burst of sparkles, a squashy landing and a little second hop;
    /// then a content glow with the odd glint. Claude's rays whirl during the bounce.
    static func done(_ rig: MascotRig) -> MascotClip {
        let rise = max(1, min(3, rig.headroom))
        let spots = rig.sparkleSpots
        let low1 = spots[0], low2 = spots[1], high1 = spots[2], high2 = spots[3]
        var spin = 0
        func pose(_ base: Pose) -> Pose {
            var pose = base
            pose.halo = spin
            spin += 1
            return pose
        }
        func air(_ up: Int) -> Pose { Pose(arms: .up, legs: .tuck, face: .happy, dy: -up) }

        var intro = Reel()
        intro.add(rig.draw(pose(Pose(face: .happy, squash: 1))), 2)
        intro.add(rig.draw(pose(air(max(1, rise - 1)))))
        intro.add(rig.draw(pose(air(rise))).sparkles([(.dot, low1), (.dot, low2)]))
        intro.add(rig.draw(pose(air(rise))).sparkles([(.small, low1), (.small, low2), (.glint, high1)]), 2)
        intro.add(rig.draw(pose(air(max(1, rise - 1)))).sparkles([(.big, low1), (.small, low2), (.small, high1)]))
        intro.add(rig.draw(pose(Pose(arms: .up, face: .happy, squash: 1)))
            .sparkles([(.small, low1), (.big, low2), (.small, high1), (.glint, high2)]), 2)
        intro.add(rig.draw(pose(Pose(face: .happy))).sparkles([(.dot, low1), (.small, low2), (.big, high1), (.small, high2)]), 2)
        intro.add(rig.draw(pose(air(1))).sparkles([(.dot, low2), (.small, high1), (.big, high2)]), 2)
        intro.add(rig.draw(pose(Pose(face: .happy, squash: 1))).sparkles([(.glint, high1), (.small, high2)]), 2)
        intro.add(rig.draw(pose(Pose(face: .happy))).sparkles([(.glint, high2)]), 2)

        let stand = rig.draw(Pose(face: .happy)), squash = rig.draw(Pose(face: .happy, squash: 1))
        let hop = rig.draw(Pose(legs: .tuck, face: .happy, dy: -1))
        var loop = Reel()
        loop.add(stand, 2)
        loop.add(stand.sparkles([(.glint, high2)]), 1)
        loop.add(stand.sparkles([(.small, high2)]), 3)
        loop.add(stand.sparkles([(.glint, high2)]), 1)
        loop.add(stand, 2)
        loop.add(squash, 9)
        loop.add(stand, 2)
        loop.add(hop, 2)
        loop.add(stand.sparkles([(.glint, high1)]), 1)
        loop.add(stand.sparkles([(.small, high1)]), 3)
        loop.add(stand.sparkles([(.glint, high1)]), 1)
        loop.add(stand, 2)
        loop.add(squash, 9)
        let poster = stand.sparkles([(.small, high2), (.glint, high1)])
        return MascotClip(fps: 12, intro: intro.frames, loop: loop.frames, poster: poster, pulses: false)
    }

    /// A startled wince (Codex: `>_<`) and a shake, then a slump with a sad face, greyed out: Codex rains
    /// from its own underside, the others shed a tear; Kimi's dot falls off and rolls to its feet.
    static func error(_ rig: MascotRig) -> MascotClip {
        let startle = min(1, rig.headroom)
        // A rain cloud hovers up a little to make room for its drizzle; everyone else sinks.
        let sink = rig.rainColumns.isEmpty ? 1 : -1
        let floor = Point(x: 17, y: 18)
        let fall: [Point]? = rig.dot.map { dot in
            [Point(x: dot.x + 1, y: dot.y + 2), Point(x: dot.x + 3, y: dot.y + 6), Point(x: floor.x, y: floor.y - 5),
             Point(x: floor.x, y: floor.y), Point(x: floor.x, y: floor.y - 1), Point(x: floor.x, y: floor.y)]
        }
        var intro = Reel()
        intro.add(rig.draw(Pose(arms: .up, face: .wince, dy: -startle, dotLoose: fall?[0])), 2)
        for (index, dx) in [1, -1, 1, -1, 1, 0].enumerated() {
            intro.add(rig.draw(Pose(arms: .up, face: .wince, dx: dx, dotLoose: fall.map { $0[min(index + 1, $0.count - 1)] })))
        }
        intro.add(rig.draw(Pose(arms: .droop, legs: .sit, face: .sad, squash: 2, bodyDY: sink, dotLoose: fall?.last,
                                tinted: true)), 2)

        let slump = rig.draw(Pose(arms: .droop, legs: .sit, face: .sad, squash: 1, bodyDY: sink, dotLoose: fall?.last,
                                  tinted: true))
        var loop = Reel()
        if rig.rainColumns.isEmpty {
            // A tear wells up under the eye, runs down two rows and drips off.
            let tear = Point(x: rig.tearOrigin.x, y: rig.tearOrigin.y)
            loop.add(slump, 8)
            loop.add(slump.overlaying(MascotFX.drop, x: tear.x, y: tear.y), 3)
            loop.add(slump.overlaying(MascotFX.tear, x: tear.x, y: tear.y), 3)
            loop.add(slump.overlaying(MascotFX.tear, x: tear.x, y: tear.y + 1), 2)
            loop.add(slump.overlaying(MascotFX.drop, x: tear.x, y: tear.y + 3), 2)
            loop.add(slump.overlaying(MascotFX.drop, x: tear.x, y: tear.y + 5), 2)
            loop.add(slump, 4)
        } else {
            // Drops fall from under the cloud, staggered: a steady drizzle.
            for tick in 0..<12 {
                var art = slump
                for (index, column) in rig.rainColumns.enumerated() {
                    let top = slump.lowestOpaqueRow(inColumn: column) + 1
                    let phase = (tick / 2 + index * 2) % 6
                    let y = top + phase
                    if phase < 4 && y < PixelArt.canvasSize { art = art.overlaying(MascotFX.drop, x: column, y: y) }
                }
                loop.add(art)
            }
        }
        return MascotClip(fps: 12, intro: intro.frames, loop: loop.frames, poster: loop.frames.first?.art ?? slump,
                          pulses: false)
    }

    /// Eyes up, breathing slowly, while "…" builds up in a thought (Codex types the dots after its `>`
    /// prompt; Claude turns its rays slowly instead, like its own spinner).
    static func thinking(_ rig: MascotRig) -> MascotClip {
        let breath = 16
        var loop = Reel()
        var poster: PixelArt?
        for tick in 0..<breath {
            let squash = tick >= breath / 2 ? 1 : 0
            var art: PixelArt
            if !rig.thinkFaces.isEmpty {
                art = rig.draw(Pose(faceArt: rig.thinkFaces[(tick / 4) % rig.thinkFaces.count], squash: squash))
            } else if !rig.halo.isEmpty {
                art = rig.draw(Pose(face: .up, squash: squash, halo: tick / 2))
            } else {
                art = rig.draw(Pose(face: .up, squash: squash))
                let shown = (tick / 4) % 4   // 0, 1, 2, 3 dots… then none
                let origin = rig.thoughtOrigin
                for index in 0..<3 where index < shown {
                    art = art.overlaying(MascotFX.thought, x: origin.x + index * 2, y: origin.y)
                }
            }
            if poster == nil || tick == 8 { poster = art }
            loop.add(art)
        }
        return MascotClip(fps: 10, intro: [], loop: loop.frames, poster: poster ?? rig.draw(Pose()), pulses: true)
    }

    // MARK: Helpers

    private static func lcm(_ a: Int, _ b: Int) -> Int {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        return a / gcd(a, b) * b
    }
}

/// Frames in order; a frame equal to the previous one extends it instead.
private struct Reel {
    private(set) var frames: [MascotClip.Frame] = []

    mutating func add(_ art: PixelArt, _ ticks: Int = 1) {
        if let last = frames.last, last.art == art {
            frames[frames.count - 1] = MascotClip.Frame(art: art, ticks: last.ticks + ticks)
        } else {
            frames.append(MascotClip.Frame(art: art, ticks: ticks))
        }
    }
}

private enum Sparkle { case glint, dot, small, big }

private extension PixelArt {
    func sparkles(_ items: [(Sparkle, MascotRig.Point)]) -> PixelArt {
        items.reduce(self) { art, item in
            let (kind, center) = item
            switch kind {
            case .glint: return art.overlaying(MascotFX.glint, x: center.x, y: center.y)
            case .dot: return art.overlaying(MascotFX.dot, x: center.x, y: center.y)
            case .small: return art.overlaying(MascotFX.sparkle, x: center.x - 1, y: center.y - 1)
            case .big: return art.overlaying(MascotFX.sparkleBig, x: center.x - 2, y: center.y - 2)
            }
        }
    }

    /// Bottom-most opaque row of `column` (-1 if the column is empty).
    func lowestOpaqueRow(inColumn column: Int) -> Int {
        for y in stride(from: height - 1, through: 0, by: -1) where self[column, y] != 0 { return y }
        return -1
    }
}
