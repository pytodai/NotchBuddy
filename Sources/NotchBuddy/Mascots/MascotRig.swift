/// One character's parts. Frames are composed, never drawn whole: legs underneath, then the body with its
/// face patch (and, per character, arms, a ray halo, a brand dot) on top, squashed at the waist
/// and shifted as one piece. Characters therefore share every animation (`MascotChoreography`) while keeping
/// their own anatomy and their brand's signature moves.
struct MascotRig {
    enum Arms: CaseIterable { case rest, waveA, waveB, up, swingA, swingB, droop }
    /// `stepA` / `stepB`: one foot lifted (pattering while busy); `sit`: feet splayed (the error slump).
    enum Legs: CaseIterable { case stand, stepA, stepB, tuck, sit }
    enum Face: CaseIterable { case open, blink, happy, wince, sad, up }

    struct Point: Hashable {
        var x: Int
        var y: Int
    }

    let palette: MascotPalette
    /// Row removed to squash (breathing, landing, slumping); rows above it slide down.
    let waistRow: Int
    /// 20×20 layers. The body carries no face: faces are sparse patches drawn on top of it.
    let body: PixelArt
    /// Optional: characters without arms sway instead of waving.
    var arms: [Arms: PixelArt] = [:]
    /// Optional: a character without legs floats.
    var legs: [Legs: PixelArt] = [:]
    /// Where face patches go on the body.
    let faceOrigin: Point
    let faces: [Face: PixelArt]
    /// Face frames cycled while thinking instead of the thought dots (Codex types `...` after its prompt).
    var thinkFaces: [PixelArt] = []
    /// Idles and waits like a terminal cursor (the `_` blinks at 1 Hz) instead of an occasional eye blink.
    var cursorBlink = false
    /// Rotation steps of rays drawn behind the body (Claude's starburst): working spins through them,
    /// thinking turns them slowly, everything else shows the first. Empty = no halo.
    var halo: [PixelArt] = []
    /// Top-left cell of the 2×2 brand dot (Kimi's blue dot), which bounces while the character works
    /// and falls off when it fails. Nil = no dot.
    var dot: Point?
    /// Error: roles recoloured once the character has slumped (Codex turns into a grey rain cloud,
    /// Claude's rays go out).
    var errorTint: [PixelRole: PixelRole] = [:]
    /// Error: cells the rain drips from (Codex rains from its own underside); empty = a tear from `tearOrigin`.
    var rainColumns: [Int] = []
    /// Error: where a tear wells up (just under an eye, on the slumped pose).
    var tearOrigin = Point(x: 6, y: 13)
    /// Top-left of the "!" speech bubble (5×7) while waiting.
    var bubbleOrigin = Point(x: 0, y: 0)
    /// Left of the three thought dots (one row, 5 cells) while thinking.
    var thoughtOrigin = Point(x: 14, y: 2)
    /// Sparkle spots for the happy bounce: two low ones beside the body, two high ones above it.
    var sparkleSpots: [Point] = [.init(x: 2, y: 13), .init(x: 17, y: 11), .init(x: 16, y: 3), .init(x: 3, y: 5)]

    struct Pose: Hashable {
        var arms: Arms = .rest
        var legs: Legs = .stand
        var face: Face = .open
        /// A face frame drawn instead of `face` (work and think sequences).
        var faceArt: PixelArt?
        var squash = 0
        /// Moves the body without the legs (negative = up): the bob of a step, a sway, sitting down.
        var bodyDX = 0
        var bodyDY = 0
        /// Moves everything.
        var dx = 0
        var dy = 0
        /// Halo rotation step.
        var halo = 0
        /// Brand dot hop above its perch (negative = up; moves with the body).
        var dotDY = 0
        /// Brand dot knocked off: drawn at this canvas cell instead, independent of the body.
        var dotLoose: Point?
        /// `errorTint` applied.
        var tinted = false
    }

    func draw(_ pose: Pose) -> PixelArt {
        var upper = body
        if !halo.isEmpty { upper = upper.underlaying(halo[((pose.halo % halo.count) + halo.count) % halo.count]) }
        let face = pose.faceArt ?? faces[pose.face] ?? faces[.open] ?? PixelArt(width: 0, height: 0)
        upper = upper.overlaying(face, x: faceOrigin.x, y: faceOrigin.y)
        if let arms = arms[pose.arms] { upper = upper.overlaying(arms) }
        if let dot, pose.dotLoose == nil {
            upper = upper.overlaying(MascotFX.brandDot, x: dot.x, y: dot.y + pose.dotDY)
        }
        if pose.squash > 0 { upper = upper.squashed(atRow: waistRow, by: pose.squash) }
        if pose.tinted { upper = upper.recolored(errorTint) }
        upper = upper.shifted(dx: pose.dx + pose.bodyDX, dy: pose.dy + pose.bodyDY)
        var art = upper
        if let legs = legs[pose.legs] {
            let feet = legs.shifted(dx: pose.dx, dy: pose.dy)
            art = art.underlaying(pose.tinted ? feet.recolored(errorTint) : feet)
        }
        if let loose = pose.dotLoose {
            let dot = pose.tinted ? MascotFX.brandDot.recolored(errorTint) : MascotFX.brandDot
            art = art.overlaying(dot, x: loose.x, y: loose.y)
        }
        return art
    }

    /// Topmost opaque row of the standing pose, halo included (how far the character may hop without clipping).
    var headroom: Int {
        let art = draw(Pose())
        for y in 0..<art.height {
            for x in 0..<art.width where art[x, y] != 0 { return y }
        }
        return 0
    }
}

extension MascotRig {
    static func rig(for character: MascotCharacter) -> MascotRig {
        switch character {
        case .claude: return .claude
        case .codex: return .codex
        case .kimi: return .kimi
        case .generic: return .generic
        }
    }
}
