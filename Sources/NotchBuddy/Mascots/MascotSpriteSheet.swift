import CoreGraphics
import Foundation

/// Every frame of one character, all states, deduplicated into a single horizontal strip image at one image
/// pixel per art pixel. Layers show a frame by pointing `contentsRect` at its cell and let the render server
/// scale it up with nearest-neighbour filtering. Built once per character (`MascotSpriteSheet.shared`).
final class MascotSpriteSheet {
    /// Frames sit in 22-pixel cells: a clear 1-pixel gutter on every side keeps filtering from bleeding
    /// neighbours in.
    static let cell = PixelArt.canvasSize + 2

    struct Timeline {
        let fps: Double
        /// Indices into the sheet's frames, with durations in ticks.
        let intro: [(frame: Int, ticks: Int)]
        let loop: [(frame: Int, ticks: Int)]
        let poster: Int
        let pulses: Bool

        var introDuration: Double { Double(intro.reduce(0) { $0 + $1.ticks }) / fps }
        var loopDuration: Double { Double(loop.reduce(0) { $0 + $1.ticks }) / fps }

        /// The frame on screen `time` s after the state began: the intro, then the loop (films and previews step
        /// the frames themselves; live layers let the render server do it).
        func frame(at time: Double) -> Int {
            func pick(_ track: [(frame: Int, ticks: Int)], _ tick: Int) -> Int {
                var elapsed = 0
                for step in track {
                    elapsed += step.ticks
                    if tick < elapsed { return step.frame }
                }
                return track.last?.frame ?? poster
            }
            let introTicks = intro.reduce(0) { $0 + $1.ticks }
            let tick = Int((max(0, time) * fps).rounded(.down))
            if tick < introTicks { return pick(intro, tick) }
            let loopTicks = loop.reduce(0) { $0 + $1.ticks }
            guard loopTicks > 0 else { return poster }
            return pick(loop, (tick - introTicks) % loopTicks)
        }
    }

    let character: MascotCharacter
    let image: CGImage
    let frames: [PixelArt]
    let timelines: [MascotState: Timeline]
    let palette: MascotPalette

    @MainActor static func shared(_ character: MascotCharacter) -> MascotSpriteSheet {
        if let sheet = cache[character] { return sheet }
        let sheet = MascotSpriteSheet(character: character)
        cache[character] = sheet
        return sheet
    }

    @MainActor private static var cache: [MascotCharacter: MascotSpriteSheet] = [:]

    init(character: MascotCharacter) {
        let rig = MascotRig.rig(for: character)
        var frames: [PixelArt] = []
        var index: [PixelArt: Int] = [:]
        func intern(_ art: PixelArt) -> Int {
            if let existing = index[art] { return existing }
            index[art] = frames.count
            frames.append(art)
            return frames.count - 1
        }
        var timelines: [MascotState: Timeline] = [:]
        for state in MascotState.allCases {
            let clip = MascotChoreography.clip(state, rig: rig)
            timelines[state] = Timeline(
                fps: clip.fps,
                intro: clip.intro.map { (intern($0.art), $0.ticks) },
                loop: clip.loop.map { (intern($0.art), $0.ticks) },
                poster: intern(clip.poster),
                pulses: clip.pulses)
        }
        self.character = character
        self.frames = frames
        self.timelines = timelines
        self.palette = rig.palette
        image = MascotSpriteSheet.strip(frames, palette: rig.palette)
    }

    /// The frame's cell in unit coordinates of `image` (for `CALayer.contentsRect`).
    func contentsRect(_ frame: Int) -> CGRect {
        let total = CGFloat(frames.count * Self.cell)
        return CGRect(x: CGFloat(frame * Self.cell + 1) / total, y: 1 / CGFloat(Self.cell),
                      width: CGFloat(PixelArt.canvasSize) / total, height: CGFloat(PixelArt.canvasSize) / CGFloat(Self.cell))
    }

    /// One frame as its own image, `scale` image pixels per art pixel, on `background` (nil = clear).
    func frameImage(_ frame: Int, scale: Int = 1, background: CGColor? = nil) -> CGImage? {
        Self.render(frames[frame], palette: palette, scale: scale, background: background)
    }

    // MARK: Rasterising

    private static func strip(_ frames: [PixelArt], palette: MascotPalette) -> CGImage {
        let width = frames.count * cell
        var pixels = [UInt8](repeating: 0, count: width * cell * 4)
        for (index, art) in frames.enumerated() {
            paint(art, palette: palette, into: &pixels, rowBytes: width * 4, originX: index * cell + 1, originY: 1, scale: 1)
        }
        return makeImage(pixels, width: width, height: cell)!
    }

    static func render(_ art: PixelArt, palette: MascotPalette, scale: Int, background: CGColor? = nil) -> CGImage? {
        let width = art.width * scale, height = art.height * scale
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        paint(art, palette: palette, into: &pixels, rowBytes: width * 4, originX: 0, originY: 0, scale: scale)
        guard let image = makeImage(pixels, width: width, height: height) else { return nil }
        guard let background else { return image }
        guard let context = bitmap(width: width, height: height) else { return nil }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func paint(_ art: PixelArt, palette: MascotPalette, into pixels: inout [UInt8], rowBytes: Int,
                              originX: Int, originY: Int, scale: Int) {
        for y in 0..<art.height {
            for x in 0..<art.width {
                let role = Int(art[x, y])
                guard role != 0 else { continue }
                let rgb = palette.rgb[role]
                for dy in 0..<scale {
                    for dx in 0..<scale {
                        let offset = (originY + y * scale + dy) * rowBytes + (originX + x * scale + dx) * 4
                        pixels[offset] = UInt8((rgb >> 16) & 0xFF)
                        pixels[offset + 1] = UInt8((rgb >> 8) & 0xFF)
                        pixels[offset + 2] = UInt8(rgb & 0xFF)
                        pixels[offset + 3] = 0xFF
                    }
                }
            }
        }
    }

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Opaque-or-clear pixels, so straight and premultiplied alpha coincide.
    private static func makeImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
