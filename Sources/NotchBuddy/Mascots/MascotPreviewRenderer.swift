import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// `NotchBuddy --render-mascots <dir>`: writes the mascots for design review, then exits.
///
///   sheet.png                 every character × state, each distinct frame in play order, 8× nearest-neighbour
///   sheet-<character>.png     the same, one character per file
///   posters.png               the Reduce Motion still of every character × state, 8×
///   gif/<character>-<state>.gif   each animation at 8× (intro once, then the loop), looping forever
///   island.png / island.gif   all mascots at real size (30 pt, @2x) on a black island, with session-row mock-ups
///   strip-<character>.png     the raw sprite strip the layers use (1 px per art pixel)
@MainActor
enum MascotPreviewRenderer {
    nonisolated static let flag = "--render-mascots"

    nonisolated static func requestedDirectory(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        return index + 1 < arguments.count ? arguments[index + 1] : "build/mascots"
    }

    static let zoom = 8
    static let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    static let backdrop = CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)

    static func run(outputDirectory: String) -> Int32 {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        let gifs = directory.appendingPathComponent("gif", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: gifs, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot create \(gifs.path): \(error)\n".utf8))
            return 1
        }
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            if !ok {
                failures += 1
                FileHandle.standardError.write(Data("failed: \(name)\n".utf8))
            }
        }
        let sheets = MascotCharacter.allCases.map { MascotSpriteSheet.shared($0) }
        for sheet in sheets {
            let name = sheet.character.rawValue
            check(writePNG(sheet.image, to: directory.appendingPathComponent("strip-\(name).png")), "strip \(name)")
            check(writePNG(sheetImage([sheet]), to: directory.appendingPathComponent("sheet-\(name).png")), "sheet \(name)")
            for state in MascotState.allCases {
                let url = gifs.appendingPathComponent("\(name)-\(state.rawValue).gif")
                check(writeStateGIF(sheet, state, to: url), "gif \(name)-\(state.rawValue)")
            }
            print("\(name): \(sheet.frames.count) frames")
        }
        check(writePNG(sheetImage(sheets), to: directory.appendingPathComponent("sheet.png")), "sheet")
        check(writePNG(postersImage(sheets), to: directory.appendingPathComponent("posters.png")), "posters")
        check(writePNG(island(sheets, time: nil), to: directory.appendingPathComponent("island.png")), "island")
        check(writeIslandGIF(sheets, to: directory.appendingPathComponent("island.gif")), "island.gif")
        let problems = layerCheck()
        for problem in problems { FileHandle.standardError.write(Data("layer-check: \(problem)\n".utf8)) }
        print("layer-check: \(problems.isEmpty ? "ok" : "\(problems.count) problem(s)")")
        failures += problems.count
        return failures == 0 ? 0 : 1
    }

    // MARK: Layer check

    /// Drives the real `PixelMascotLayer` offscreen and checks what it hands the render server: discrete
    /// keyframes with one more key time than values, the intro once per state change, nothing while paused,
    /// a still frame (plus the pulse for busy states) under Reduce Motion, and crisp whole-pixel sprite sizes.
    static func layerCheck() -> [String] {
        var problems: [String] = []
        for character in MascotCharacter.allCases {
            let sheet = MascotSpriteSheet.shared(character)
            for state in MascotState.allCases {
                let timeline = sheet.timelines[state]!
                let name = "\(character.rawValue)-\(state.rawValue)"
                let layer = PixelMascotLayer()
                layer.contentsScale = 2
                layer.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
                layer.configure(character: character, state: state, reduceMotion: false)
                layer.layoutIfNeeded()
                let sprite = layer.spriteLayer
                let keys = Set(sprite.animationKeys() ?? [])
                let expected: Set<String> = timeline.intro.isEmpty ? ["mascot.loop"] : ["mascot.loop", "mascot.intro"]
                if keys != expected { problems.append("\(name): animations \(keys.sorted()), expected \(expected.sorted())") }
                for key in keys {
                    guard let animation = sprite.animation(forKey: key) as? CAKeyframeAnimation,
                          let values = animation.values, let times = animation.keyTimes else {
                        problems.append("\(name): \(key) is not a keyframe animation"); continue
                    }
                    if animation.calculationMode != .discrete { problems.append("\(name): \(key) not discrete") }
                    if times.count != values.count + 1 || times.first?.doubleValue != 0 || times.last?.doubleValue != 1 {
                        problems.append("\(name): \(key) has \(values.count) values and \(times.count) key times")
                    }
                    let track = key == "mascot.intro" ? timeline.introDuration : timeline.loopDuration
                    if abs(animation.duration - track) > 1e-9 { problems.append("\(name): \(key) lasts \(animation.duration) s") }
                }
                if sprite.frame.size != CGSize(width: 30, height: 30) {
                    problems.append("\(name): sprite is \(sprite.frame.size) at 30 pt @2x, expected 30×30")
                }
                layer.setRunning(false)
                if !(sprite.animationKeys() ?? []).isEmpty { problems.append("\(name): still animating while hidden") }
                layer.setRunning(true)
                if Set(sprite.animationKeys() ?? []) != ["mascot.loop"] {
                    problems.append("\(name): after unhiding \(sprite.animationKeys() ?? []), expected only the loop")
                }
                layer.configure(character: character, state: state, reduceMotion: true)
                if !(sprite.animationKeys() ?? []).isEmpty { problems.append("\(name): frames animate under Reduce Motion") }
                if (layer.animation(forKey: "mascot.pulse") != nil) != timeline.pulses {
                    problems.append("\(name): Reduce Motion pulse \(timeline.pulses ? "missing" : "unexpected")")
                }
            }
        }
        // Whole device pixels per art pixel, nearest to the requested size.
        for (size, scale, side) in [(30.0, 2.0, 30.0), (24, 2, 20), (26, 2, 30), (20, 2, 20), (28, 1, 20), (40, 2, 40), (16, 3, 20.0 / 3 * 2)] {
            let layer = PixelMascotLayer()
            layer.contentsScale = scale
            layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            layer.configure(character: .claude, state: .idle, reduceMotion: false)
            layer.layoutIfNeeded()
            let actual = layer.spriteLayer.frame.width
            if abs(actual - side) > 0.001 { problems.append("size \(size) pt @\(scale)x: sprite \(actual) pt, expected \(side)") }
            let perCell = actual * scale / CGFloat(PixelArt.canvasSize)
            if abs(perCell - perCell.rounded()) > 0.001 { problems.append("size \(size) pt @\(scale)x: \(perCell) px per art pixel") }
        }
        return problems
    }

    // MARK: Sheets

    /// Distinct frames of a timeline in play order: intro, then the loop.
    static func playOrder(_ timeline: MascotSpriteSheet.Timeline) -> (intro: [Int], loop: [Int]) {
        var seen = Set<Int>()
        func distinct(_ track: [(frame: Int, ticks: Int)]) -> [Int] {
            track.compactMap { seen.insert($0.frame).inserted ? $0.frame : nil }
        }
        let intro = distinct(timeline.intro)
        return (intro, distinct(timeline.loop))
    }

    static func sheetImage(_ sheets: [MascotSpriteSheet]) -> CGImage? {
        let cell = PixelArt.canvasSize * zoom, gap = 8, labelWidth = 230, pad = 24
        let rows = sheets.flatMap { sheet in MascotState.allCases.map { (sheet, $0) } }
        let widest = rows.map { row -> Int in
            let order = playOrder(row.0.timelines[row.1]!)
            return order.intro.count + order.loop.count + (order.intro.isEmpty ? 0 : 1)
        }.max() ?? 1
        let width = pad * 2 + labelWidth + widest * (cell + gap)
        let height = pad * 2 + rows.count * (cell + gap)
        guard let context = MascotSpriteSheet.bitmap(width: width, height: height) else { return nil }
        context.setFillColor(backdrop)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, (sheet, state)) in rows.enumerated() {
            let top = pad + index * (cell + gap)
            let timeline = sheet.timelines[state]!
            let order = playOrder(timeline)
            draw(text: "\(sheet.character.rawValue) · \(state.rawValue)", size: 22, color: .white,
                 in: context, x: pad, top: top + 50, height: height)
            let detail = "\(Int(timeline.fps)) fps · " + (order.intro.isEmpty ? "loop" : "intro + loop")
            draw(text: detail, size: 15, color: NSColor(white: 0.6, alpha: 1), in: context, x: pad, top: top + 82, height: height)
            var x = pad + labelWidth
            for frame in order.intro {
                blit(sheet.frameImage(frame, scale: zoom, background: black), in: context, x: x, top: top, height: height)
                x += cell + gap
            }
            if !order.intro.isEmpty {
                // A thin divider between the one-shot intro and the loop.
                context.setFillColor(CGColor(red: 1, green: 0.62, blue: 0.1, alpha: 1))
                context.fill(CGRect(x: x + cell / 2 - 2, y: height - top - cell, width: 4, height: cell))
                x += cell + gap
            }
            for frame in order.loop {
                blit(sheet.frameImage(frame, scale: zoom, background: black), in: context, x: x, top: top, height: height)
                x += cell + gap
            }
        }
        return context.makeImage()
    }

    static func postersImage(_ sheets: [MascotSpriteSheet]) -> CGImage? {
        let cell = PixelArt.canvasSize * zoom, gap = 12, pad = 24, header = 40
        let states = MascotState.allCases
        let width = pad * 2 + states.count * (cell + gap)
        let height = pad * 2 + header + sheets.count * (cell + gap)
        guard let context = MascotSpriteSheet.bitmap(width: width, height: height) else { return nil }
        context.setFillColor(backdrop)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (column, state) in states.enumerated() {
            draw(text: state.rawValue, size: 20, color: .white, in: context, x: pad + column * (cell + gap), top: pad + 26,
                 height: height)
        }
        for (row, sheet) in sheets.enumerated() {
            for (column, state) in states.enumerated() {
                blit(sheet.frameImage(sheet.timelines[state]!.poster, scale: zoom, background: black), in: context,
                     x: pad + column * (cell + gap), top: pad + header + row * (cell + gap), height: height)
            }
        }
        return context.makeImage()
    }

    // MARK: Island (real size)

    /// Frame of `timeline` at `time` s after the state began (intro, then the loop).
    static func frame(_ timeline: MascotSpriteSheet.Timeline, at time: Double) -> Int { timeline.frame(at: time) }

    /// The black island at @2x: a grid of every character × state at 30 pt, and two session-row mock-ups.
    /// `time` nil draws the still (poster) frames.
    static func island(_ sheets: [MascotSpriteSheet], time: Double?) -> CGImage? {
        let scale = 2, mascot = 30, pixel = mascot * scale / PixelArt.canvasSize   // 3 device px per art pixel
        let states = MascotState.allCases
        let columnWidth = 64, nameWidth = 64, rowHeight = 50, header = 26, margin = 20
        let islandWidth = nameWidth + states.count * columnWidth + 24
        let mockHeight = 2 * 50 + 16
        let islandHeight = header + sheets.count * rowHeight + mockHeight + 12
        let width = (islandWidth + margin * 2) * scale, height = (islandHeight + margin) * scale
        guard let context = MascotSpriteSheet.bitmap(width: width, height: height) else { return nil }
        context.setFillColor(backdrop)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // The island hangs from the top edge: square top, rounded bottom corners.
        let islandRect = CGRect(x: margin * scale, y: height - islandHeight * scale, width: islandWidth * scale,
                                height: islandHeight * scale)
        let path = CGMutablePath()
        let radius = CGFloat(22 * scale)
        path.move(to: CGPoint(x: islandRect.minX, y: islandRect.maxY))
        path.addLine(to: CGPoint(x: islandRect.maxX, y: islandRect.maxY))
        path.addArc(tangent1End: CGPoint(x: islandRect.maxX, y: islandRect.minY),
                    tangent2End: CGPoint(x: islandRect.minX, y: islandRect.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: islandRect.minX, y: islandRect.minY),
                    tangent2End: CGPoint(x: islandRect.minX, y: islandRect.maxY), radius: radius)
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(black)
        context.fillPath()

        let left = margin + 12
        let secondary = NSColor(white: 1, alpha: 0.5)
        for (column, state) in states.enumerated() {
            draw(text: state.rawValue, size: CGFloat(10 * scale), color: secondary, in: context,
                 x: (left + nameWidth + column * columnWidth + mascot / 2) * scale, top: 18 * scale, height: height,
                 centered: true)
        }
        for (row, sheet) in sheets.enumerated() {
            let top = header + row * rowHeight
            draw(text: sheet.character.rawValue, size: CGFloat(11 * scale), color: .white, in: context,
                 x: left * scale, top: (top + 29) * scale, height: height)
            for (column, state) in states.enumerated() {
                let timeline = sheet.timelines[state]!
                let index = time.map { frame(timeline, at: $0) } ?? timeline.poster
                blit(sheet.frameImage(index, scale: pixel), in: context,
                     x: (left + nameWidth + column * columnWidth) * scale, top: (top + 6) * scale, height: height)
            }
        }
        // Session-row mock-ups: mascot, then title and a secondary line, as the expanded island will show them.
        let rows: [(MascotCharacter, MascotState, String, String)] = [
            (.claude, .working, "weather-app · Плавные графики", "Bash  swift build -c release"),
            (.codex, .waiting, "api-gateway · Падающие тесты", "Ждёт разрешения: apply_patch"),
        ]
        for (index, row) in rows.enumerated() {
            let top = header + sheets.count * rowHeight + 10 + index * 50
            let sheet = MascotSpriteSheet.shared(row.0)
            let timeline = sheet.timelines[row.1]!
            let frameIndex = time.map { frame(timeline, at: $0) } ?? timeline.poster
            blit(sheet.frameImage(frameIndex, scale: pixel), in: context, x: left * scale, top: top * scale, height: height)
            draw(text: row.2, size: CGFloat(12 * scale), color: .white, weight: .semibold, in: context,
                 x: (left + 40) * scale, top: (top + 13) * scale, height: height)
            draw(text: row.3, size: CGFloat(10.5 * Double(scale)), color: secondary, in: context,
                 x: (left + 40) * scale, top: (top + 30) * scale, height: height)
        }
        return context.makeImage()
    }

    static func writeIslandGIF(_ sheets: [MascotSpriteSheet], to url: URL) -> Bool {
        let fps = 24.0, seconds = 6.0
        let count = Int(fps * seconds)
        let images = (0..<count).compactMap { island(sheets, time: Double($0) / fps) }
        return writeGIF(images.map { ($0, 1 / fps) }, to: url)
    }

    static func writeStateGIF(_ sheet: MascotSpriteSheet, _ state: MascotState, to url: URL) -> Bool {
        let timeline = sheet.timelines[state]!
        var frames: [(CGImage, Double)] = []
        func append(_ track: [(frame: Int, ticks: Int)]) {
            for step in track {
                guard let image = sheet.frameImage(step.frame, scale: zoom, background: black) else { continue }
                frames.append((image, Double(step.ticks) / timeline.fps))
            }
        }
        append(timeline.intro)
        // Enough loops for about four seconds, so the GIF's own looping doesn't replay the intro too often.
        let loops = timeline.intro.isEmpty ? 1 : max(1, Int((4 / timeline.loopDuration).rounded(.up)))
        for _ in 0..<loops { append(timeline.loop) }
        return writeGIF(frames, to: url)
    }

    // MARK: Output

    static func writeGIF(_ frames: [(CGImage, Double)], to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                                frames.count, nil) else { return false }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        // GIF delays are whole centiseconds: carry the rounding error so the total duration stays exact.
        var owed = 0.0
        for (image, seconds) in frames {
            owed += seconds
            let delay = max(0.02, (owed * 100).rounded() / 100)
            owed -= delay
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ] as CFDictionary)
        }
        return CGImageDestinationFinalize(destination)
    }

    static func writePNG(_ image: CGImage?, to url: URL) -> Bool {
        guard let image,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    // MARK: Drawing (top-left coordinates on a bottom-left context of `height`)

    static func blit(_ image: CGImage?, in context: CGContext, x: Int, top: Int, height: Int) {
        guard let image else { return }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: x, y: height - top - image.height, width: image.width, height: image.height))
    }

    /// Text whose baseline sits `top` pixels from the top, starting at `x` (or centred on it).
    static func draw(text: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .medium, in context: CGContext,
                     x: Int, top: Int, height: Int, centered: Bool = false) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color,
        ]))
        let width = centered ? CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) : 0
        context.textPosition = CGPoint(x: CGFloat(x) - width / 2, y: CGFloat(height - top))
        CTLineDraw(line, context)
    }
}
