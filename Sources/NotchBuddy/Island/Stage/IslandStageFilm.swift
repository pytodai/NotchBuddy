import AppKit
import NotchBuddyCore
import SwiftUI

/// `NotchBuddy --render-perf <dir>`: films the real Core Animation stage (`IslandStage`) with fake sessions and writes
/// PNGs, then exits. Nothing else starts.
///
/// The stage runs in film mode: its clock is virtual and every track it bakes (`IslandTimeline`) is evaluated at the
/// filmed moment and drawn, so each frame is exactly what the render server shows at that moment of the live motion.
/// `<dir>/film-*.png` are filmstrips of every transition, `<dir>/still-*.png` the settled states; the process prints
/// continuity checks (the silhouette never jumps between two frames 1/120 s apart, content is on screen while an open
/// silhouette is) and exits non-zero when one fails.
@MainActor
enum IslandStageFilm {
    nonisolated static let flag = "--render-perf"

    nonisolated static func requestedDirectory(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        return index + 1 < arguments.count ? arguments[index + 1] : "build/perf-previews"
    }

    static func run(outputDirectory: String) -> Int32 {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot create \(directory.path): \(error)\n".utf8))
            return 1
        }
        NSApp.setActivationPolicy(.accessory)
        let only = ProcessInfo.processInfo.environment["NOTCHBUDDY_FILMS"].map { Set($0.split(separator: ",").map(String.init)) }
        var failures = 0
        // «Островок» (the capsule floating below the top edge) is filmed on a screen without a notch.
        var island = IslandPreviewRenderer.floating
        island.gap = IslandLayout.islandGap
        let sets = ProcessInfo.processInfo.environment["NOTCHBUDDY_FILM_SETS"].map { Set($0.split(separator: ",").map(String.init)) }
        for (suffix, metrics) in [("floating", IslandPreviewRenderer.floating), ("notch", IslandPreviewRenderer.notched),
                                  ("island", island)] where sets == nil || sets!.contains(suffix) {
            let set = FilmSet(metrics: metrics)
            for film in set.films() where only == nil || only!.contains(film.name) {
                let (image, problems) = set.shoot(film)
                for problem in problems {
                    FileHandle.standardError.write(Data("film-\(film.name)-\(suffix): \(problem)\n".utf8))
                }
                failures += problems.count
                failures += write(image, to: directory.appendingPathComponent("film-\(film.name)-\(suffix).png")) ? 0 : 1
            }
            set.close()
            IslandLayout.capsuleWidth = CGFloat(NotchSettings.defaultCapsuleWidth)
            // «Островок» dragged sideways: on a panel as wide as the screen, as the app has it.
            guard metrics.detached else { continue }
            let wide = FilmSet(metrics: metrics, panelWidth: metrics.screenWidth)
            for film in FilmSet.sidewaysFilms(metrics) where only == nil || only!.contains(film.name) {
                let (image, problems) = wide.shoot(film)
                for problem in problems {
                    FileHandle.standardError.write(Data("film-\(film.name)-\(suffix): \(problem)\n".utf8))
                }
                failures += problems.count
                failures += write(image, to: directory.appendingPathComponent("film-\(film.name)-\(suffix).png")) ? 0 : 1
            }
            wide.close()
        }
        return failures == 0 ? 0 : 1
    }

    static func write(_ image: CGImage?, to url: URL) -> Bool {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("failed to render \(url.lastPathComponent)\n".utf8))
            return false
        }
        do {
            try png.write(to: url)
            print(url.path)
            return true
        } catch {
            FileHandle.standardError.write(Data("failed to write \(url.path): \(error)\n".utf8))
            return false
        }
    }
}

/// One filmed transition: a starting state, a change, the moments to draw.
@MainActor
struct StageFilm {
    let name: String
    let title: String
    var times: [Double] = [0, 0.016, 0.033, 0.05, 0.066, 0.083, 0.10, 0.133, 0.166, 0.20, 0.25, 0.32, 0.45, 0.7]
    /// Brings the stage to the starting state (it is settled before the change).
    let setup: (IslandViewState, StageFakes) -> Void
    /// The change at t = 0.
    let change: (IslandViewState, StageFakes, IslandStage) -> Void
    /// Further changes at later moments (an interruption).
    var later: [(Double, (IslandViewState, StageFakes, IslandStage) -> Void)] = []
    /// How much of the canvas' top each frame shows (default: up to 330 pt).
    var captureHeight: CGFloat?
}

/// The real stage in an offscreen panel with a virtual clock.
@MainActor
final class FilmSet {
    let metrics: IslandMetrics
    let fakes: StageFakes
    /// The panel's width (default: the canvas'; the sideways films take the screen's, as the app does).
    let panelWidth: CGFloat?
    private(set) var state: IslandViewState
    private(set) var stage: IslandStage
    private var panel: IslandPanel
    private var container: IslandContainerView
    private var now: CFTimeInterval = 1000
    private var pending: [(at: CFTimeInterval, body: @MainActor () -> Void)] = []

    init(metrics: IslandMetrics, panelWidth: CGFloat? = nil) {
        self.metrics = metrics
        self.panelWidth = panelWidth
        fakes = StageFakes(now: Date())
        state = IslandViewState()
        stage = IslandStage(state: state)
        panel = IslandPanel()
        container = IslandContainerView(host: stage.slider)
        configure()
    }

    /// The set being filmed (a film's setup can reach its stage).
    static weak var current: IslandStage?

    private func configure() {
        FilmSet.current = stage
        stage.timeline.filming = true
        stage.clock = { [unowned self] in self.now }
        stage.later = { [unowned self] seconds, body in self.pending.append((self.now + max(0, seconds), body)) }
        state.jump(to: metrics)
        state.reduceMotion = ProcessInfo.processInfo.environment["NOTCHBUDDY_FILM_REDUCE"] == "1"
        let canvas = IslandLayout.canvasSize(metrics)
        stage.slider.canvasSize = canvas
        panel.contentView = container
        panel.setFrame(NSRect(x: -40_000, y: -40_000, width: max(canvas.width, panelWidth ?? 0), height: canvas.height),
                       display: false)
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        container.layoutSubtreeIfNeeded()
    }

    /// A fresh island for each film.
    private func reset() {
        panel.orderOut(nil)
        state = IslandViewState()
        stage = IslandStage(state: state)
        panel = IslandPanel()
        container = IslandContainerView(host: stage.slider)
        pending = []
        configure()
    }

    func close() { panel.orderOut(nil) }

    /// Virtual time passes: due tidying runs, SwiftUI catches up.
    private func advance(to t: CFTimeInterval) {
        now = t
        while let i = pending.indices.filter({ pending[$0].at <= t }).min(by: { pending[$0].at < pending[$1].at }) {
            let job = pending.remove(at: i)
            job.body()
        }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
        container.layoutSubtreeIfNeeded()
        stage.apply(at: t)
    }

    private func settle() {
        advance(to: now + 1.5)
        advance(to: now + 0.01)
    }

    func films() -> [StageFilm] {
        var films = StageFakes.films(notch: metrics.style == .notch)
        guard metrics.style == .floating else { return films }
        // Settings → Остров → Стиль, live: the shape morphs to the other style (closed, and with the list open).
        var other = metrics
        other.gap = metrics.gap > 0 ? 0 : IslandLayout.islandGap
        let title = metrics.gap > 0 ? "Стиль: островок → чёлка" : "Стиль: чёлка → островок"
        films.append(StageFilm(name: "style", title: title + " (свёрнут)",
                               setup: { s, f in s.setContent(.collapsed, snapshot: f.trio) },
                               change: { s, _, _ in s.morph(to: other) }))
        films.append(StageFilm(name: "style-open", title: title + " (список открыт)",
                               setup: { s, f in s.setContent(.expanded, snapshot: f.trio) },
                               change: { s, _, _ in s.morph(to: other) }, captureHeight: 420))
        guard metrics.detached else { return films }
        films += Self.capsuleFilms
        return films
    }

    /// Settings → Остров → «Ширина капсулы»: the closed capsule morphing between the slider's default, maximum and
    /// minimum, and its faces at the default width (every status, a single session without the ring, no session).
    private static var capsuleFilms: [StageFilm] {
        func set(_ s: IslandViewState, _ w: CGFloat) {
            IslandLayout.capsuleWidth = w
            s.capsuleWidth = w
        }
        func width(_ w: CGFloat) -> (IslandViewState, StageFakes, IslandStage) -> Void { { s, _, _ in set(s, w) } }
        /// A face of its own island (a data change that resizes nothing is not filmed reliably: SwiftUI catches up later).
        func face(_ f: StageFakes, _ status: SessionStatus?, ring: Bool = true, others: Bool = true) -> IslandSnapshot {
            var sessions: [AgentSession] = []
            if let status, var claude = f.sessions[StageFakes.claude] {
                claude.status = status
                sessions = [claude] + (others ? f.ordered([StageFakes.codex, StageFakes.kimi]) : [])
            }
            var snapshot = IslandSnapshot(sessions: sessions, usage: f.usage)
            snapshot.showsUsageRing = ring
            return snapshot
        }
        let initial = CGFloat(NotchSettings.defaultCapsuleWidth)
        let range = IslandLayout.capsuleWidthRange
        let faces: [(String, SessionStatus?, Bool, Bool)] = [
            ("waiting", .waitingForUser, true, true), ("finished", .finished, true, true), ("error", .error, true, true),
            ("single", .working, false, false), ("none", nil, true, false),
        ]
        return [
            StageFilm(name: "capsule-width",
                      title: "Ширина капсулы: \(Int(initial)) → \(Int(range.upperBound)) → \(Int(range.lowerBound)) → \(Int(initial)) пт",
                      times: [0, 0.05, 0.1, 0.2, 0.45, 0.55, 0.6, 0.7, 0.95, 1.05, 1.1, 1.2, 1.45],
                      setup: { s, f in
                          set(s, initial)
                          s.setContent(.collapsed, snapshot: f.trio)
                      },
                      change: width(range.upperBound),
                      later: [(0.5, width(range.lowerBound)), (1.0, width(initial))],
                      captureHeight: 96),
        ] + [range.lowerBound, initial, range.upperBound].map { w in
            StageFilm(name: "capsule-\(Int(w))", title: "Капсула \(Int(w)) пт: покой и наведение",
                      times: [0, 0.3],
                      setup: { s, f in
                          set(s, w)
                          s.setContent(.collapsed, snapshot: f.trio)
                      },
                      change: { s, _, _ in s.setHovering(true) },
                      captureHeight: 96)
        } + faces.map { name, status, ring, others in
            StageFilm(name: "capsule-face-\(name)", title: "Капсула \(Int(initial)) пт: \(name)", times: [0],
                      setup: { s, f in
                          set(s, initial)
                          s.setContent(.collapsed, snapshot: face(f, status, ring: ring, others: others))
                      },
                      change: { _, _, _ in },
                      captureHeight: 96)
        }
    }

    /// «Островок» dragged sideways (on a screen-wide panel): the capsule resting at the left, the center and the right,
    /// a drag that rubber-bands at the left edge and is let go (it springs back inside), a drag let go near the center
    /// (the magnetic snap) and the capsule pressed again while it still settles (it is caught where it is drawn), the
    /// list opening from a capsule at either edge (it slides inward as it grows, so the open island stays on screen) and
    /// closing to it, and the open island at the left edge grabbed where its capsule sits (it folds back into the
    /// capsule, which follows the pointer: the fold carries on around the drag, nothing jumps).
    static func sidewaysFilms(_ metrics: IslandMetrics) -> [StageFilm] {
        let range = IslandLayout.shiftRange(width: IslandLayout.capsuleWidth, metrics: metrics)
        func rest(_ x: CGFloat) -> (IslandViewState, StageFakes) -> Void {
            { s, f in
                s.islandOffset = x
                s.setContent(.collapsed, snapshot: f.trio)
            }
        }
        /// A hand's drag from `from` to `to` over `duration`, sampled every 1/60 s, then let go.
        func drag(from: CGFloat, to: CGFloat, duration: Double) -> [(Double, (IslandViewState, StageFakes, IslandStage) -> Void)] {
            var press = IslandDrag(pressX: 0, start: from, range: range)
            var steps: [(Double, (IslandViewState, StageFakes, IslandStage) -> Void)] = []
            let count = Int(duration * 60)
            for i in 1...count {
                let p = Double(i) / Double(count)
                let eased = p * p * (3 - 2 * p)
                _ = press.pointer(x: (to - from) * CGFloat(eased), dy: 0)
                let x = press.x
                steps.append((Double(i) / 60, { s, _, stage in
                    s.dragShift = x
                    stage.dragSlide(to: x)
                }))
            }
            let rest = press.rest
            steps.append((duration + 1.0 / 60, { s, _, stage in
                s.dragShift = nil
                s.islandOffset = rest
                stage.settleSlide(spring: IslandMotion.drop)
            }))
            return steps
        }
        typealias Step = (Double, (IslandViewState, StageFakes, IslandStage) -> Void)
        /// The press, as `IslandController.dragClosedIsland` keeps it.
        final class Hand { var press: IslandDrag? }
        /// The pointer travels from `a` to `b` (from where it went down) over `duration` from `t0`, eased like a hand,
        /// sampled every 1/60 s: as the controller follows it. `catches`: a press on the capsule (it starts from where the
        /// capsule is drawn, `IslandStage.holdSlide`); else a grab (the fold carries on around the drag).
        func move(_ hand: Hand, to px: CGFloat, catches: Bool) -> (IslandViewState, StageFakes, IslandStage) -> Void {
            { s, _, stage in
                guard var press = hand.press else { return }
                let wasActive = press.active
                let moved = press.pointer(x: px, dy: 0, drawn: catches ? { stage.presentedShiftNow } : nil)
                hand.press = press
                guard press.active else { return }
                if !wasActive {
                    s.dragShift = press.x
                    if catches { stage.holdSlide(at: press.x) }
                    s.setHovering(true, riding: !catches)
                }
                if moved {
                    s.dragShift = press.x
                    stage.dragSlide(to: press.x)
                }
            }
        }
        func pull(_ hand: Hand, from a: CGFloat, to b: CGFloat, at t0: Double, duration: Double, catches: Bool) -> [Step] {
            let count = max(1, Int((duration * 60).rounded()))
            return (1...count).map { i in
                let p = Double(i) / Double(count)
                return (t0 + Double(i) / 60, move(hand, to: a + (b - a) * CGFloat(p * p * (3 - 2 * p)), catches: catches))
            }
        }
        /// Let go at `t`: it settles where it rests.
        func drop(_ hand: Hand, at t: Double) -> Step {
            (t, { s, _, stage in
                guard let press = hand.press, press.active else { return }
                hand.press = nil
                s.dragShift = nil
                s.islandOffset = press.rest
                stage.settleSlide(spring: IslandMotion.drop)
            })
        }
        let catchHand = Hand()
        let grabHand = Hand()
        let grabStart = IslandDragMath.grabThreshold
        let edgeTimes = [0, 0.1, 0.2, 0.3, 0.38, 0.45, 0.5, 0.55, 0.6, 0.7, 0.85]
        return [
            StageFilm(name: "capsule-left", title: "Островок у левого края", times: [0],
                      setup: rest(range.lowerBound), change: { _, _, _ in }, captureHeight: 72),
            StageFilm(name: "capsule-center", title: "Островок по центру", times: [0],
                      setup: rest(0), change: { _, _, _ in }, captureHeight: 72),
            StageFilm(name: "capsule-right", title: "Островок у правого края", times: [0],
                      setup: rest(range.upperBound), change: { _, _, _ in }, captureHeight: 72),
            StageFilm(name: "drag-edge", title: "Тянем влево за край: резинка, отпустили — пружина внутрь",
                      times: edgeTimes, setup: rest(range.lowerBound + 120), change: { _, _, _ in },
                      later: drag(from: range.lowerBound + 120, to: range.lowerBound - 80, duration: 0.4),
                      captureHeight: 72),
            StageFilm(name: "drag-snap", title: "Отпустили в 18 пт от центра: магнит к центру",
                      times: edgeTimes, setup: rest(240), change: { _, _, _ in },
                      later: drag(from: 240, to: 18, duration: 0.4), captureHeight: 72),
            StageFilm(name: "drag-catch", title: "Отпустили у центра и сразу схватили снова: капсула остаётся под курсором",
                      times: [0, 0.15, 0.3, 0.33, 0.36, 0.4, 0.45, 0.5, 0.6, 0.75, 0.9, 1.1],
                      setup: rest(240), change: { _, _, _ in catchHand.press = nil },
                      later: drag(from: 240, to: 18, duration: 0.3) + [
                          // Pressed again 50 ms into the settle (it is still on its way to the center), and pulled right.
                          (0.37, { s, _, _ in
                              catchHand.press = IslandDrag(pressX: 0, start: s.targetShift(),
                                                           range: IslandLayout.shiftRange(width: s.closedRestWidth, metrics: s.metrics))
                          }),
                      ] + pull(catchHand, from: 0, to: 200, at: 0.37, duration: 0.35, catches: true) + [drop(catchHand, at: 0.74)],
                      captureHeight: 72),
            StageFilm(name: "open-from-left", title: "Открытие из капсулы у левого края: список въезжает внутрь экрана",
                      setup: rest(range.lowerBound), change: { s, f, _ in s.setContent(.expanded, snapshot: f.trio) },
                      captureHeight: 420),
            StageFilm(name: "open-from-right", title: "Открытие из капсулы у правого края",
                      setup: rest(range.upperBound), change: { s, f, _ in s.setContent(.expanded, snapshot: f.trio) },
                      captureHeight: 420),
            StageFilm(name: "close-to-left", title: "Закрытие: список → капсула у левого края",
                      setup: { s, f in
                          s.islandOffset = range.lowerBound
                          s.setContent(.expanded, snapshot: f.trio)
                      },
                      change: { s, f, _ in s.setContent(.collapsed, snapshot: f.trio) }, captureHeight: 420),
            StageFilm(name: "grab-left",
                      title: "Открыт наведением у левого края, схватили там, где капсула: сворачивается в неё, она едет за курсором",
                      times: [0, 0.033, 0.066, 0.1, 0.15, 0.2, 0.3, 0.45, 0.7],
                      setup: { s, f in
                          s.islandOffset = range.lowerBound
                          s.setContent(.expanded, snapshot: f.trio)
                      },
                      change: { s, f, stage in
                          // `IslandController.beginGrab`: the island folds back (the close), the capsule is grabbed where it
                          // rests and pulled from the grab threshold on.
                          s.setContent(.collapsed, snapshot: f.trio)
                          grabHand.press = IslandDrag(pressX: 0, start: s.targetShift(),
                                                      range: IslandLayout.shiftRange(width: s.closedRestWidth, metrics: s.metrics),
                                                      threshold: IslandDragMath.grabThreshold)
                          move(grabHand, to: grabStart, catches: false)(s, f, stage)
                      },
                      later: pull(grabHand, from: grabStart, to: grabStart + 320, at: 0, duration: 0.45, catches: false)
                          + [drop(grabHand, at: 0.45 + 1.0 / 60)],
                      captureHeight: 420),
        ]
    }

    /// Films `film`: a row of frames, and the continuity problems found.
    func shoot(_ film: StageFilm) -> (CGImage?, [String]) {
        reset()
        film.setup(state, fakes)
        settle()
        let t0 = now
        film.change(state, fakes, stage)
        var laters = film.later.sorted { $0.0 < $1.0 }
        var problems: [String] = []
        // Continuity: the silhouette's presented geometry and its edges on screen (a dragged «Островок» slides), sampled
        // at 120 Hz, never jump.
        var previous = stage.presentedGeometry(at: t0)
        var previousShift = stage.presentedShift(at: t0)
        var sampleTime = t0
        let end = t0 + (film.times.last ?? 0.7) * IslandMotion.slowmo
        var checkEnd = end
        while sampleTime < checkEnd {
            sampleTime += 1.0 / 120
            if let next = laters.first, t0 + next.0 <= sampleTime {
                laters.removeFirst()
                advance(to: t0 + next.0)
                next.1(state, fakes, stage)
                checkEnd = max(checkEnd, now + 0.3)
            }
            let g = stage.presentedGeometry(at: sampleTime)
            let shift = stage.presentedShift(at: sampleTime)
            let jump = max(abs(g.width - previous.width), abs(g.height - previous.height))
            let left = abs((shift - g.width / 2) - (previousShift - previous.width / 2))
            let right = abs((shift + g.width / 2) - (previousShift + previous.width / 2))
            // A spring moves at most ~25 pt per 1/120 s at these sizes (a hand's drag less); more is a discontinuity.
            if jump > 30 { problems.append(String(format: "silhouette jumps %.0f pt at %.0f ms", jump, (sampleTime - t0) * 1000)) }
            if max(left, right) > 30 {
                problems.append(String(format: "silhouette's edge jumps %.0f pt sideways at %.0f ms", max(left, right),
                                       (sampleTime - t0) * 1000))
            }
            previous = g
            previousShift = shift
        }
        // Draw.
        reset()
        stage.debugOrigin = now
        film.setup(state, fakes)
        settle()
        let start = now
        stage.debugOrigin = start
        stage.debug("change \(film.name)")
        film.change(state, fakes, stage)
        laters = film.later.sorted { $0.0 < $1.0 }
        var frames: [CGImage] = []
        let canvas = IslandLayout.canvasSize(metrics)
        let height = min(canvas.height, film.captureHeight ?? 330)
        for t in film.times {
            while let next = laters.first, next.0 <= t {
                laters.removeFirst()
                advance(to: start + next.0)
                next.1(state, fakes, stage)
            }
            advance(to: start + t * IslandMotion.slowmo)
            stage.debug("frame \(Int(t * 1000)) ms: \(stage.presentedGeometry(at: now)) shift \(stage.presentedShift(at: now))")
            if let image = capture(height: height) {
                frames.append(StageFilmArt.frame(image, metrics: metrics, points: container.bounds.width,
                                                 label: "\(Int((t * 1000).rounded())) мс"))
            }
        }
        let header = IslandPreviewRenderer.image(
            Text(verbatim: film.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.white.opacity(0.85)))
        let columns = min(panelWidth == nil ? 7 : 3, frames.count)
        return (IslandPreviewRenderer.stitch(frames, columns: columns, header: header), problems)
    }

    /// The top `height` points of the canvas, as the stage draws it now.
    private func capture(height: CGFloat) -> CGImage? {
        let view = container
        let rect = NSRect(x: 0, y: view.bounds.height - height, width: view.bounds.width, height: height)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        return rep.cgImage
    }
}

/// Backdrop for the frames: a wallpaper, the menu bar, the camera housing on a notched screen.
@MainActor
enum StageFilmArt {
    private static var backdrops: [String: CGImage] = [:]

    static func frame(_ island: CGImage, metrics: IslandMetrics, points: CGFloat? = nil, label: String) -> CGImage {
        let width = island.width, height = island.height
        // The capture's own scale (1× or 2×, whatever screen the offscreen panel counts as on): the backdrop and the
        // camera housing are drawn at it, so the housing is exactly the notch the island was laid out around.
        let scale = max(1, (CGFloat(width) / (points ?? IslandLayout.canvasSize(metrics).width)).rounded())
        let key = "\(metrics.style)-\(width)x\(height)"
        let backdrop = backdrops[key] ?? {
            let size = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
            let image = IslandPreviewRenderer.image(FilmBackdrop(metrics: metrics).frame(width: size.width, height: size.height),
                                                    scale: scale)
            backdrops[key] = image
            return image
        }()
        let notch = metrics.style == .notch ? IslandPreviewRenderer.image(
            IslandShape(earRadius: 0, bottomRadius: 9).fill(Color.black)
                .frame(width: metrics.notchWidth, height: metrics.barHeight), scale: scale) : nil
        let labelImage = IslandPreviewRenderer.image(
            Text(verbatim: label).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Color.white)
                .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.black.opacity(0.55))))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return island }
        let all = CGRect(x: 0, y: 0, width: width, height: height)
        if let backdrop { context.draw(backdrop, in: all) }
        context.draw(island, in: all)
        if let notch {
            context.draw(notch, in: CGRect(x: (width - notch.width) / 2, y: height - notch.height,
                                           width: notch.width, height: notch.height))
        }
        if let labelImage {
            context.draw(labelImage, in: CGRect(x: 16, y: 16, width: labelImage.width, height: labelImage.height))
        }
        return context.makeImage() ?? island
    }
}

private struct FilmBackdrop: View {
    let metrics: IslandMetrics

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.22), Color(red: 0.05, green: 0.06, blue: 0.1)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.35, green: 0.22, blue: 0.55).opacity(0.55), .clear],
                           center: UnitPoint(x: 0.18, y: 0.1), startRadius: 0, endRadius: 360)
            RadialGradient(colors: [Color(red: 0.1, green: 0.42, blue: 0.5).opacity(0.45), .clear],
                           center: UnitPoint(x: 0.85, y: 0.55), startRadius: 0, endRadius: 420)
            HStack(spacing: 16) {
                Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
                Text("Terminal").font(.system(size: 13, weight: .bold))
                Text(sample("Файл", "File")).font(.system(size: 13))
                Spacer()
                Text(sample("Ср 30 сент. 17:41", "Wed Sep 30 17:41")).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 14)
            .frame(height: metrics.menuBarHeight)
            .background(Color.white.opacity(0.08))
        }
    }
}

// MARK: - Fake data

/// Sessions, cards and notices for the films.
@MainActor
struct StageFakes {
    let now: Date
    let sessions: [SessionKey: AgentSession]
    let usage: UsageState
    let claudeCard: PermissionCardInfo
    let codexCard: PermissionCardInfo

    static let claude = SessionKey(source: .claude, sessionId: "claude-1")
    static let codex = SessionKey(source: .codex, sessionId: "codex-1")
    static let kimi = SessionKey(source: .kimi, sessionId: "kimi-1")
    static let late = SessionKey(source: .codex, sessionId: "codex-late")

    init(now: Date) {
        self.now = now
        var store = SessionStore(staleAfter: .greatestFiniteMagnitude, workingTimeout: .greatestFiniteMagnitude)
        func event(_ key: SessionKey, _ kind: EventKind, cwd: String, ago: TimeInterval, tool: String? = nil,
                   summary: String? = nil, message: String? = nil) {
            store.apply(AgentEvent(source: key.source, hookEventName: "\(kind)", kind: kind, sessionId: key.sessionId,
                                   cwd: cwd, toolName: tool, toolSummary: summary, message: message,
                                   timestamp: now.addingTimeInterval(-ago)))
        }
        let home = NSHomeDirectory()
        event(Self.claude, .promptSubmitted, cwd: "\(home)/code/weather-app", ago: 134, message: sample("Сделай графики плавнее", "Make the charts smoother"))
        event(Self.claude, .toolWillRun, cwd: "\(home)/code/weather-app", ago: 6, tool: "Bash",
              summary: "swift build -c release 2>&1 | tail -20")
        event(Self.codex, .promptSubmitted, cwd: "\(home)/code/api-gateway", ago: 400, message: sample("Почини падающие тесты", "Fix the failing tests"))
        event(Self.codex, .toolWillRun, cwd: "\(home)/code/api-gateway", ago: 90, tool: "exec_command",
              summary: "npm test -- --watch=false")
        event(Self.kimi, .promptSubmitted, cwd: "\(home)/code/landing-page", ago: 900, message: sample("Обнови hero-блок", "Update the hero section"))
        event(Self.kimi, .stop, cwd: "\(home)/code/landing-page", ago: 420, message: sample("Обновил hero-блок и адаптив", "Updated the hero section and the layout"))
        event(Self.late, .promptSubmitted, cwd: "\(home)/code/billing", ago: 2, message: sample("Добавь тесты", "Add tests"))
        sessions = store.sessions
        usage = .loaded(UsageSnapshot(
            fiveHour: UsageWindow(utilization: 42, resetsAt: now.addingTimeInterval(2 * 3600 + 600)),
            sevenDay: UsageWindow(utilization: 18, resetsAt: now.addingTimeInterval(3 * 86400)), fetchedAt: now))
        let bash = AgentEvent(
            source: .claude, hookEventName: "PermissionRequest", kind: .permissionRequest, sessionId: Self.claude.sessionId,
            cwd: "\(home)/code/weather-app", toolName: "Bash", toolSummary: "rm -rf .build && swift build -c release",
            decisionSupported: true, canAlwaysAllow: true, timestamp: now.addingTimeInterval(-3),
            raw: .object(["tool_input": .object([
                "command": .string("rm -rf .build && swift build -c release && ./scripts/build-app.sh --install"),
                "description": .string(sample("Пересобрать приложение с нуля и установить его", "Rebuild the app from scratch and install it")),
            ])]))
        claudeCard = PermissionCardInfo(id: bash.id, event: bash, receivedAt: now.addingTimeInterval(-3), projectTitle: "weather-app")
        let npm = AgentEvent(
            source: .codex, hookEventName: "PermissionRequest", kind: .permissionRequest, sessionId: Self.codex.sessionId,
            cwd: "\(home)/code/api-gateway", toolName: "exec_command", toolSummary: "rm -rf node_modules && npm ci",
            decisionSupported: true, timestamp: now.addingTimeInterval(-1),
            raw: .object(["tool_input": .object(["command": .string("rm -rf node_modules && npm ci")])]))
        codexCard = PermissionCardInfo(id: npm.id, event: npm, receivedAt: now.addingTimeInterval(-1), projectTitle: "api-gateway")
    }

    func ordered(_ keys: [SessionKey]) -> [AgentSession] { SessionStore.ordered(keys.compactMap { sessions[$0] }) }

    var trio: IslandSnapshot { IslandSnapshot(sessions: ordered([Self.claude, Self.codex, Self.kimi]), usage: usage) }

    var waiting: [AgentSession] {
        var claude = sessions[Self.claude]!
        claude.status = .waitingForUser
        return [claude] + ordered([Self.codex, Self.kimi])
    }

    var card: IslandSnapshot {
        IslandSnapshot(sessions: waiting, card: claudeCard, cardCount: 2, cardIDs: [claudeCard.id, codexCard.id], usage: usage)
    }

    var nextCard: IslandSnapshot {
        IslandSnapshot(sessions: waiting, card: codexCard, cardCount: 1, cardIDs: [codexCard.id], usage: usage)
    }

    var finished: IslandSnapshot {
        var s = trio
        s.flash = FlashNotice(key: Self.claude, kind: .finished, title: "weather-app", detail: nil)
        s.flashDuration = 252
        return s
    }

    var withLateRow: IslandSnapshot {
        IslandSnapshot(sessions: ordered([Self.claude, Self.codex, Self.kimi, Self.late]), usage: usage)
    }

    static func films(notch: Bool) -> [StageFilm] {
        var films: [StageFilm] = [
            StageFilm(name: "appear", title: notch ? "Первая сессия: вырез → крылья" : "Появление из верхнего края",
                      setup: { s, f in s.setContent(notch ? .idle : .hidden, snapshot: IslandSnapshot(usage: f.usage)) },
                      change: { s, f, _ in s.setContent(.collapsed, snapshot: f.trio) }),
            StageFilm(name: "hover", title: "Курсор над свёрнутым: остров «дышит»",
                      times: [0, 0.033, 0.066, 0.1, 0.15, 0.25],
                      setup: { s, f in s.setContent(.collapsed, snapshot: f.trio) },
                      change: { s, _, _ in s.setHovering(true) }),
            StageFilm(name: "open", title: "Открытие: свёрнут → список (spring 0.46/0.78, ушки +4)",
                      setup: { s, f in
                          s.setContent(.collapsed, snapshot: f.trio)
                          s.setHovering(true)
                      },
                      change: { s, f, _ in s.setContent(.expanded, snapshot: f.trio) }),
            StageFilm(name: "close", title: "Закрытие: список → свёрнут",
                      setup: { s, f in s.setContent(.expanded, snapshot: f.trio) },
                      change: { s, f, _ in s.setContent(.collapsed, snapshot: f.trio) }),
            StageFilm(name: "open-interrupted", title: "Передумал: открытие прервано закрытием на 80 мс",
                      setup: { s, f in s.setContent(.collapsed, snapshot: f.trio) },
                      change: { s, f, _ in s.setContent(.expanded, snapshot: f.trio) },
                      later: [(0.08, { s, f, _ in s.setContent(.collapsed, snapshot: f.trio) })]),
            StageFilm(name: "card", title: "Запрос разрешения: свёрнут → карточка",
                      setup: { s, f in s.setContent(.collapsed, snapshot: IslandSnapshot(sessions: f.waiting, usage: f.usage)) },
                      change: { s, f, _ in
                          s.cardPresentedAt = AppClock.monotonicSeconds()
                          s.setContent(.permission, snapshot: f.card, glow: .card)
                      }),
            StageFilm(name: "cardAdvance", title: "Следующий запрос: карточка уходит вверх, остров «глотает», новая поднимается",
                      setup: { s, f in s.setContent(.permission, snapshot: f.card, glow: .card) },
                      change: { s, f, _ in s.setContent(.permission, snapshot: f.nextCard, entrance: .deck, pulse: .gulp, glow: .card) }),
            StageFilm(name: "follower", title: "Эффект, который следует за формой (IslandOutlineGlow): карточка → следующая",
                      setup: { s, f in
                          s.setContent(.permission, snapshot: f.card, glow: .card)
                          FilmSet.current?.addFollower(IslandOutlineGlow(tint: SessionStatus.waitingForUser.tint))
                      },
                      change: { s, f, _ in s.setContent(.permission, snapshot: f.nextCard, entrance: .deck, pulse: .gulp, glow: .card) }),
            // The green celebration that plays with it is a Core Animation effect these frames cannot draw: see
            // `--render-effects` (island-done-*).
            StageFilm(name: "flash", title: "Готово: уведомление (салют — в --render-effects island-done-*)",
                      times: [0, 0.033, 0.066, 0.1, 0.15, 0.2, 0.3, 0.45, 0.6, 0.9],
                      setup: { s, f in s.setContent(.collapsed, snapshot: f.trio) },
                      change: { s, f, _ in s.setContent(.flash, snapshot: f.finished, glow: .finished(quiet: false)) }),
            StageFilm(name: "flash-out", title: "Уведомление → свёрнут",
                      setup: { s, f in s.setContent(.flash, snapshot: f.finished, glow: .finished(quiet: false)) },
                      change: { s, f, _ in s.setContent(.collapsed, snapshot: f.trio) }),
            StageFilm(name: "late-row", title: "Новая сессия приходит в открытый список",
                      times: [0, 0.033, 0.066, 0.1, 0.15, 0.2, 0.3, 0.45],
                      setup: { s, f in s.setContent(.expanded, snapshot: f.trio) },
                      change: { s, f, _ in s.updateData(f.withLateRow) }),
            StageFilm(name: "shake", title: "Ошибка: остров встряхивается",
                      times: [0, 0.03, 0.06, 0.1, 0.15, 0.2, 0.3],
                      setup: { s, f in s.setContent(.collapsed, snapshot: f.trio) },
                      change: { s, _, _ in s.shake() }),
        ]
        IslandPages.register(IslandPageSpec(id: "film-demo") { context in
            AnyView(FilmDemoPage(width: context.width))
        })
        IslandSettings.register()
        films.append(StageFilm(name: "page", title: "Своя страница (IslandPages): список → страница",
                               setup: { s, f in s.setContent(.expanded, snapshot: f.trio) },
                               change: { s, f, _ in s.setContent(.page("film-demo"), snapshot: f.trio) }))
        films.append(StageFilm(name: "settings", title: "⚙️: список → настройки (страница морфится из списка)",
                               setup: { s, f in s.setContent(.expanded, snapshot: f.trio) },
                               change: { s, f, _ in s.setContent(.page(IslandSettings.pageID), snapshot: f.trio) }))
        films.append(StageFilm(name: "settings-back", title: "Настройки → назад к списку",
                               setup: { s, f in s.setContent(.page(IslandSettings.pageID), snapshot: f.trio) },
                               change: { s, f, _ in s.setContent(.expanded, snapshot: f.trio) }))
        if !notch {
            films.append(StageFilm(name: "retract", title: "Нет сессий: остров втягивается в верхний край",
                                   setup: { s, f in s.setContent(.collapsed, snapshot: f.trio) },
                                   change: { s, f, _ in s.setContent(.hidden, snapshot: IslandSnapshot(usage: f.usage)) }))
        }
        return films
    }
}

/// A stand-in page for the films (what a settings page plugs in as).
private struct FilmDemoPage: View {
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Настройки"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IslandPalette.secondary)
                .frame(height: 30)
                .appearAfter(0.02, style: .header)
            ForEach(Array([L("Звуки уведомлений"), L("Лимиты Claude через API"), L("Запускать при входе")].enumerated()), id: \.offset) { index, title in
                HStack {
                    Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(IslandPalette.primary)
                    Spacer()
                    Capsule().fill(SessionStatus.finished.tint).frame(width: 34, height: 20)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.055)))
                .appearAfter(0.035 + 0.022 * Double(index), style: .row)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(width: width)
    }
}
