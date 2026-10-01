import AppKit
import CoreImage
import ImageIO
import NotchBuddyCore
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

/// `NotchBuddy --render-promo <dir> [--size 1920x1080|3840x2160] [--fps 60|120] [--lang en|ru] [--from s] [--to s] [--at s,s,…]`:
/// films the promo storyboard (`PromoStoryboard.standard`) as `<dir>/frame_00000.png…`, then exits. Nothing else starts
/// (no socket, hooks, menu or services), and the island's panel is invisible (`IslandPanel.invisibleForTests`).
///
/// The island is the real Core Animation stage (`IslandStage`) in film mode, as in `--render-perf`: a virtual clock,
/// every baked track evaluated at the filmed moment, fake sessions pushed through the same `IslandViewState` calls the
/// controller makes. Each frame, the stage's canvas is composited by `CARenderer` (`FXFilm`) into a desktop: wallpaper,
/// menu bar, camera housing, the effects library's own layers (the drip, the green "done" celebration) at the same
/// moment, a cursor, captions and title cards, seen through a virtual camera (zoom, pan, motion blur on fast moves).
///
/// Frame `i` is video second `i / fps`; the storyboard's edit maps it to the story second the island lives at (1×, with
/// skips at cuts). Every motion is a function of those two clocks, so any frame rate samples the same film.
///
/// `--from/--to` render a range, `--at` single moments (video seconds); frames keep their index in the full video, so
/// the first seconds of a partial render encode as they are (`scripts/promo/encode.sh`). `--frames a:b` renders frames a
/// up to (not including) b. `--raw <fifo>` writes raw BGRA frames into a pipe for ffmpeg instead of PNGs (the 4K
/// master: `scripts/promo/master.sh`); `--info` prints the intended cuts and the island's transitions on camera (for
/// `scripts/promo/motion-check.py --allow-cuts / --allow-ui`), then the film's duration in seconds, and exits.
/// `NOTCHBUDDY_PROMO_CAPTURE_SCALE` (1…6): pixels per point of the island's capture (default 2, the panel's backing
/// scale; close shots at 4K upsample it).
@MainActor
enum PromoRenderer {
    nonisolated static let flag = "--render-promo"

    struct Options {
        var directory: String
        var width = 1920
        var height = 1080
        var fps = 60.0
        var lang = PromoLanguage.en
        var from: Double?
        var to: Double?
        var at: [Double] = []
        var frames: Range<Int>?
        var raw: String?
        var info = false
    }

    nonisolated static func options(_ arguments: [String]) -> Options? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = index + 1 < arguments.count && !arguments[index + 1].hasPrefix("--") ? arguments[index + 1] : nil
        var o = Options(directory: next ?? "build/promo-frames")
        func value(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        if let size = value("--size") {
            let parts = size.lowercased().split(separator: "x").compactMap { Int($0) }
            if parts.count == 2, parts[0] >= 320, parts[1] >= 180 { o.width = parts[0]; o.height = parts[1] }
        }
        if let fps = value("--fps").flatMap(Double.init), fps >= 1, fps <= 240 { o.fps = fps }
        if let lang = value("--lang").flatMap(PromoLanguage.init(rawValue:)) { o.lang = lang }
        o.from = value("--from").flatMap(Double.init)
        o.to = value("--to").flatMap(Double.init)
        o.at = value("--at")?.split(separator: ",").compactMap { Double($0) } ?? []
        if let range = value("--frames")?.split(separator: ":").compactMap({ Int($0) }), range.count == 2, range[0] < range[1] {
            o.frames = range[0]..<range[1]
        }
        o.raw = value("--raw")
        o.info = arguments.contains("--info")
        return o
    }

    static func run(_ options: Options, storyboard custom: PromoStoryboard? = nil) -> Int32 {
        let storyboard = custom ?? .standard
        if options.info {
            // For `scripts/promo/motion-check.py`: the intended cuts (`--allow-cuts`) and the island's own transitions
            // on camera (`--allow-ui`), in video seconds. The duration stays the last line (`master.sh` reads it).
            let cuts = storyboard.camera.filter { $0.cut && $0.at > 0 }.map(\.at)
                + storyboard.dissolves.map(\.at)
            let ui = storyboard.beats.compactMap { beat -> Double? in
                switch beat.action {
                case .island, .data, .usage: break
                default: return nil
                }
                let v = PromoStoryboard.video(at: beat.at, storyboard.clock)
                return v > 0.01 && abs(storyboard.story(at: v) - beat.at) < 1e-6 ? v : nil
            }
            func list(_ times: [Double]) -> String {
                Array(Set(times.map { String(format: "%.2f", $0) })).sorted { Double($0)! < Double($1)! }.joined(separator: ",")
            }
            print("cuts: \(list(cuts))")
            print("island: \(list(ui))")
            print(String(format: "%.6f", storyboard.duration))
            return 0
        }
        let directory = URL(fileURLWithPath: options.directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot create \(directory.path): \(error)\n".utf8))
            return 1
        }
        NSApp.setActivationPolicy(.accessory)
        // The island's own strings (`L(…)`) and its dates and numbers follow the film's language. Through the
        // environment override, so the settings store's own language (applied when it loads) cannot take it back;
        // nothing is written to defaults.
        setenv(L10n.environmentKey, options.lang.rawValue, 1)
        L10n.shared.override(options.lang == .ru ? .ru : .en)
        defer {
            PromoSettings.cleanUp()
            PromoShelfFilm.cleanUp()
        }
        guard let film = PromoFilm(options: options, storyboard: storyboard) else {
            FileHandle.standardError.write(Data("promo: cannot set up the renderer (Metal)\n".utf8))
            return 1
        }
        let total = Int((storyboard.duration * options.fps).rounded())
        let wanted: (Int) -> Bool = { index in
            if let frames = options.frames { return frames.contains(index) }
            let t = Double(index) / options.fps
            let ranged = options.from != nil || options.to != nil
            if ranged, t >= (options.from ?? 0) - 1e-9, t <= (options.to ?? .infinity) + 1e-9 { return true }
            if options.at.contains(where: { abs($0 * options.fps - Double(index)) < 0.5 }) { return true }
            return !ranged && options.at.isEmpty
        }
        let writer = PromoWriter()
        var raw: PromoRawWriter?
        if let path = options.raw {
            raw = PromoRawWriter(path: path, width: options.width, height: options.height)
            if raw == nil {
                FileHandle.standardError.write(Data("promo: cannot open \(path) for raw frames\n".utf8))
                return 1
            }
        }
        let started = Date()
        var written = 0
        for index in 0..<total where wanted(index) {
            let t = Double(index) / options.fps
            // One pool per frame: the captures, Core Image and the compositor's images are autoreleased, and the
            // whole film runs inside a single main-thread call (without it a full render grows past 5 GB).
            let ok: Bool = autoreleasepool {
                guard let image = film.frame(at: t) else { return false }
                if let raw {
                    raw.write(image)
                } else {
                    writer.write(image, to: directory.appendingPathComponent(String(format: "frame_%05d.png", index)))
                }
                return true
            }
            guard ok else {
                FileHandle.standardError.write(Data("promo: frame \(index) failed\n".utf8))
                return 1
            }
            written += 1
            if written % 60 == 0 {
                let rate = Double(written) / max(Date().timeIntervalSince(started), 0.001)
                print(String(format: "promo: %d frames (t = %.2f s), %.1f fps", written, t, rate))
                fflush(stdout)
            }
        }
        writer.finish()
        raw?.finish()
        print(String(format: "promo: wrote %d frames to %@ in %.0f s", written, options.raw ?? directory.path,
                     Date().timeIntervalSince(started)))
        return writer.failures == 0 && (raw?.failures ?? 0) == 0 ? 0 : 1
    }
}

/// Raw BGRA frames into a pipe (`--raw <fifo>`) for `ffmpeg -f rawvideo -pix_fmt bgra -s WxH -r FPS -i <fifo>`: no PNG
/// encoding and nothing on disk, so a 4K 120 fps master goes straight into the hardware encoder.
private final class PromoRawWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "promo.raw", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 2)
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var failed = 0
    private let handle: FileHandle
    private let context: CGContext
    private let rect: CGRect
    private let bytes: Int
    var failures: Int { lock.withLock { failed } }

    init?(path: String, width: Int, height: Int) {
        guard let handle = FileHandle(forWritingAtPath: path),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        self.handle = handle
        self.context = context
        rect = CGRect(x: 0, y: 0, width: width, height: height)
        bytes = width * height * 4
    }

    /// One frame at a time on a serial queue (it owns the bitmap); at most two frames wait, so memory stays flat.
    func write(_ image: CGImage) {
        slots.wait()
        group.enter()
        queue.async { [self] in
            defer { slots.signal(); group.leave() }
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(rect)
            context.draw(image, in: rect)
            guard let data = context.data else {
                lock.withLock { failed += 1 }
                return
            }
            do {
                try handle.write(contentsOf: Data(bytesNoCopy: data, count: bytes, deallocator: .none))
            } catch {
                lock.withLock { failed += 1 }
            }
        }
    }

    func finish() {
        group.wait()
        try? handle.close()
    }
}

/// PNGs written off the main thread, a few at a time.
private final class PromoWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "promo.writer", qos: .utility, attributes: .concurrent)
    private let slots = DispatchSemaphore(value: 3)
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var failed = 0
    var failures: Int { lock.withLock { failed } }

    func write(_ image: CGImage, to url: URL) {
        slots.wait()
        group.enter()
        queue.async { [self] in
            defer { slots.signal(); group.leave() }
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                lock.withLock { failed += 1 }
                return
            }
            CGImageDestinationAddImage(destination, image, nil)
            if !CGImageDestinationFinalize(destination) { lock.withLock { failed += 1 } }
        }
    }

    func finish() { group.wait() }
}

// MARK: - The film

@MainActor
final class PromoFilm {
    let options: PromoRenderer.Options
    let storyboard: PromoStoryboard
    /// The notched MacBook screen, `storyboard.screenWidth` points wide (the open list's width follows it), per style.
    let notchMetrics: IslandMetrics
    let islandMetrics: IslandMetrics
    /// «Островок» on the external monitor (no notch), as `IslandPlacement` makes it on a notch-less screen.
    let monitorMetrics: IslandMetrics
    let screen: CGSize
    let island: PromoStage
    let fakes: PromoFakes
    private let comp: PromoCompositor
    private let beats: [PromoBeat]
    private var nextBeat = 0
    private var scene = PromoScene.empty
    private var usageChoice = UsageProviderChoice.auto
    /// Wall-clock time 0 of the story (the island's clocks tick from it).
    private let date0: Date
    private var blurStart: Double?
    private var cursor = PromoCursor()
    /// The dragged file's picture under the cursor.
    private var carry = PromoCarryTrack()
    /// When Finder selected the photo (story seconds).
    private var selectAt: Double?
    /// The frame held under a dissolve (the last moment before it), by the dissolve's start.
    private var held: (at: Double, image: CGImage)?
    /// The first moment filmed by this process (a chunk may start mid-film).
    private var started = false

    init?(options: PromoRenderer.Options, storyboard: PromoStoryboard) {
        self.options = options
        self.storyboard = storyboard
        beats = storyboard.beats.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        let W = storyboard.screenWidth
        var metrics = IslandPreviewRenderer.notched
        metrics.screenWidth = W
        notchMetrics = metrics
        // As `IslandPlacement` makes «Островок» on a notched screen: a capsule as tall as a notch-less screen's,
        // floating below the camera housing.
        islandMetrics = IslandMetrics(style: .floating, notchWidth: 0,
                                      barHeight: IslandMetrics.floatingBarHeight(menuBar: min(metrics.menuBarHeight, 28)),
                                      menuBarHeight: metrics.menuBarHeight,
                                      gap: metrics.barHeight.rounded() + IslandLayout.islandGap, screenWidth: W)
        let strip = PromoCompositor.monitorMenuBar
        monitorMetrics = IslandMetrics(style: .floating, notchWidth: 0,
                                       barHeight: IslandMetrics.floatingBarHeight(menuBar: min(strip, 28)),
                                       menuBarHeight: strip, gap: IslandLayout.islandGap, screenWidth: W)
        // Not rounded: the frames come out exactly `options.height` pixels tall (1512 pt wide → 850.5 pt at 16:9).
        screen = CGSize(width: W, height: W * CGFloat(options.height) / CGFloat(options.width))
        let scale = CGFloat(options.width) / W
        // A fixed moment, so every render shows the same clocks.
        date0 = Date(timeIntervalSinceReferenceDate: 780_912_060)  // 2025-09-30 09:41 UTC-ish; only differences show
        fakes = PromoFakes(now: date0, lang: options.lang)
        IslandLayout.widthScale = storyboard.islandWidthScale
        IslandSettings.register()
        PromoSettings.register(lang: options.lang)
        IslandWidgetPages.register()
        // The shelf scene's files and state; its page draws the widget on the film's clock.
        PromoShelfFilm.shared = PromoShelfFilm.make(lang: options.lang)
        if let id = WidgetKind.shelf.pageID {
            IslandPages.register(IslandPageSpec(id: id) { context in
                AnyView(PromoShelfPage(state: context.state, width: context.width))
            })
        }
        WidgetHub.shared = PromoFilm.widgets(tabs: [.agents], lang: options.lang)
        // Pixels per point of the island's capture. `cacheDisplay` draws the stage's layers from their backing stores
        // (the window's 2×): a denser bitmap only upsamples them (checked at 4K), so 2 unless asked.
        let captureScale = ProcessInfo.processInfo.environment["NOTCHBUDDY_PROMO_CAPTURE_SCALE"]
            .flatMap(Double.init).map { CGFloat(min(max($0, 1), 6)) } ?? 2
        island = PromoStage(metrics: metrics, captureScale: captureScale)
        guard let comp = PromoCompositor(screen: screen, scale: scale, metrics: metrics, storyboard: storyboard,
                                         lang: options.lang) else { return nil }
        self.comp = comp
        island.clockDate = { [date0] t in date0.addingTimeInterval(t) }
    }

    /// Every widget with sample data (nothing live starts: no player, calendar or drag detector).
    /// The film's language picks the sample track and file names; the shelf is the shelf scene's.
    private static func widgets(tabs: [WidgetKind], lang: PromoLanguage) -> WidgetHub {
        .preview(tabs: tabs, music: MusicPreviewRenderer.sampleModel(english: lang == .en),
                 calendar: CalendarPreviewRenderer.sampleService(),
                 timer: TimerSystemPreviewRenderer.sampleTimerStore(), system: TimerSystemPreviewRenderer.sampleSystemMonitor(),
                 shelf: PromoShelfFilm.shared?.widget)
    }

    /// The video at `v` seconds. Call with increasing `v`.
    func frame(at v: Double) -> CGImage? {
        guard let d = storyboard.dissolves.first(where: { v >= $0.at && v < $0.at + $0.length }) else { return shot(at: v) }
        if held?.at != d.at {
            // The last moment before the dissolve (a still one), rendered the same way whichever chunk gets here first.
            guard let before = shot(at: d.at - 0.001) else { return nil }
            held = (d.at, before)
        }
        guard let live = shot(at: v), let held else { return nil }
        return comp.dissolve(from: held.image, to: live, PromoEase.smoother((v - d.at) / d.length))
    }

    /// One moment of the film, as the camera sees it.
    private func shot(at v: Double) -> CGImage? {
        let t = storyboard.story(at: v)
        // Beats due by now, each at its own (story) moment; effects after the island has laid out that moment's content.
        var changed = !started
        started = true
        while nextBeat < beats.count, beats[nextBeat].at <= t + 1e-9 {
            let at = beats[nextBeat].at
            var effects: [PromoAction] = []
            island.advance(to: at)
            while nextBeat < beats.count, abs(beats[nextBeat].at - at) < 1e-9 {
                let action = beats[nextBeat].action
                switch action {
                case .drip, .celebrate, .cursor, .click, .carry: effects.append(action)
                case .island, .data, .hover, .usage, .tabs, .style:
                    changed = true
                    perform(action, at: at)
                default: perform(action, at: at)
                }
                nextBeat += 1
            }
            if !effects.isEmpty {
                island.pump()
                for action in effects { perform(action, at: at) }
            }
        }
        if changed { settle(at: t) }
        if let shelf = PromoShelfFilm.shared {
            // The shelf page's clock, and the pointer in its coordinates (its content hangs from the island's top,
            // centered) for the drop glow.
            shelf.now = t
            let width = IslandLayout.listWidth(island.state.metrics)
            let p = cursor.position(at: t)
            shelf.pointer = CGPoint(x: p.x - (screen.width - width) / 2, y: p.y - island.state.metrics.gap)
        }
        island.advance(to: t)
        guard var image = island.capture() else { return nil }
        if let start = blurStart {
            let p = (t - start) / 0.3
            if p >= 1 {
                blurStart = nil
            } else if p >= 0 {
                image = comp.blurred(image, radius: 9 * (1 - PromoEase.outCubic(p))) ?? image
            }
        }
        let aspect = comp.photoAspect
        let desk = PromoCompositor.Desk(selection: selectAt.map { PromoEase.smooth((t - $0) / 0.12) } ?? 0,
                                        carry: carry.state(at: t, cursor: cursor.position(at: t), aspect: aspect))
        return comp.render(video: v, story: t, island: image, geometry: island.stage.presentedGeometry(at: island.now),
                           cursor: cursor.state(at: t), desk: desk)
    }

    /// The island's content just changed. The few transitions SwiftUI runs on its own (wall) clock rather than the
    /// film's (a tab's name on the strip's pill) finish now, as the film's data changes do, whatever the render's speed
    /// and wherever a chunk of the master starts (it catches up on every earlier beat at once).
    private func settle(at t: Double) {
        island.advance(to: t)
        let until = Date().addingTimeInterval(0.6)
        while Date() < until { RunLoop.main.run(mode: .default, before: until) }
        island.pump()
    }

    private func snapshot(_ scene: PromoScene) -> IslandSnapshot { fakes.snapshot(scene, usageChoice: usageChoice) }

    private func perform(_ action: PromoAction, at t: Double) {
        let state = island.state
        switch action {
        case let .island(mode, scene, entrance, exit, pulse, glow, blur):
            self.scene = scene
            if mode == .permission {
                state.cardPresentedAt = AppClock.monotonicSeconds()
                // As the controller: the front card arms 500 ms after it appears ("Разрешить" has filled up).
                let id = snapshot(scene).card?.id
                island.later(PermissionArming.seconds) { state.armedCardID = id }
            } else if !mode.isOpen || mode == .expanded {
                state.armedCardID = nil
            }
            let islandGlow: IslandGlow? = glow.map { $0 == .card ? .card : .finished(quiet: false) }
            state.setContent(mode, snapshot: snapshot(scene), entrance: entrance, exit: exit, pulse: pulse, glow: islandGlow)
            if blur { blurStart = t }
        case .data(let scene):
            self.scene = scene
            state.updateData(snapshot(scene))
        case .hover(let on):
            state.setHovering(on)
        case .usage(let choice):
            usageChoice = choice
            state.updateData(snapshot(scene))
        case .tabs(let tabs):
            WidgetHub.shared = Self.widgets(tabs: tabs, lang: options.lang)
            state.tabs = tabs
        case .style(let style):
            let metrics: IslandMetrics
            switch style {
            case .notch: metrics = notchMetrics
            case .island: metrics = islandMetrics
            case .monitor: metrics = monitorMetrics
            }
            island.restyle(metrics)
            comp.restyle(metrics, monitor: style == .monitor)
        case .drip:
            comp.drip(at: t, geometry: state.geometry)
        case .celebrate:
            let metrics = state.metrics
            let canvas = IslandLayout.canvasSize(metrics)
            let anchor = IslandEffects.noticeBadge(metrics: metrics, canvasWidth: canvas.width, contentSize: state.contentSize(.flash))
            comp.celebrate(at: t, geometry: state.geometry, anchor: anchor)
        case let .cursor(point, duration):
            cursor.move(to: resolve(point), at: t, duration: duration)
        case .click:
            cursor.click(at: t)
        case .cursorVisible(let on):
            cursor.show(on, at: t)
        case .press(let down):
            cursor.press(down, at: t)
        case .select:
            selectAt = t
        case .carry(let step):
            switch step {
            case .lift: carry.add(.lift, at: t)
            case .drop: carry.add(.drop(cursor.position(at: t)), at: t)
            case .attach: carry.add(.attach(cursor.position(at: t)), at: t)
            }
        case .shelf(let step):
            guard let shelf = PromoShelfFilm.shared else { break }
            switch step {
            case .target: shelf.targetAt = t
            case .drop: shelf.dropAt = t
            case .lift: shelf.liftAt = t
            case .dragOut: shelf.outAt = t
            case .dragOutEnd: shelf.outEndAt = t
            }
        }
    }

    /// A storyboard point in screen points.
    private func resolve(_ point: PromoPoint) -> CGPoint {
        PromoCompositor.resolve(point, screen: screen, geometry: island.state.geometry)
    }
}

// MARK: - The island, filmed

/// The real stage in an offscreen, invisible panel with a virtual clock (`FilmSet`'s rig, driven along one timeline).
@MainActor
final class PromoStage {
    let state = IslandViewState()
    let stage: IslandStage
    private let panel = IslandPanel()
    private let container: IslandContainerView
    private let captureScale: CGFloat
    /// Where the panel's bottom-left corner sits (nil: off every screen).
    private let corner: CGPoint?
    /// Media time of the stage: 1000 + story time.
    private(set) var now: CFTimeInterval = 1000
    var clockDate: (Double) -> Date = { Date(timeIntervalSinceReferenceDate: $0) }
    private var pending: [(at: CFTimeInterval, body: @MainActor () -> Void)] = []

    init(metrics: IslandMetrics, captureScale: CGFloat) {
        self.captureScale = captureScale
        stage = IslandStage(state: state)
        container = IslandContainerView(host: stage.view)
        stage.timeline.filming = true
        // On a screen, so SwiftUI's display link ticks (a transition that carries its own animation would otherwise
        // stay at its first frame), at the bottom-left corner: the panel is at 1 % opacity and click-through in
        // render runs (`IslandPanel.invisibleForTests`), so nothing shows. `NOTCHBUDDY_PROMO_OFFSCREEN=1` keeps it off
        // every screen instead.
        let offscreen = ProcessInfo.processInfo.environment["NOTCHBUDDY_PROMO_OFFSCREEN"] == "1"
        corner = offscreen ? nil : (NSScreen.main ?? NSScreen.screens.first)?.frame.origin
        stage.clock = { [unowned self] in self.now }
        stage.later = { [unowned self] seconds, body in self.pending.append((self.now + max(0, seconds), body)) }
        state.jump(to: metrics)
        state.reduceMotion = false
        panel.contentView = container
        place(IslandLayout.canvasSize(metrics))
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        container.layoutSubtreeIfNeeded()
    }

    private func place(_ canvas: CGSize) {
        let origin = corner.map { CGPoint(x: $0.x, y: $0.y - canvas.height + 2) } ?? CGPoint(x: -40_000, y: -40_000)
        panel.setFrame(NSRect(origin: origin, size: canvas), display: false)
    }

    /// Another style while the island is hidden: as the controller moves it (`jump(to:)`, a canvas of the new size).
    func restyle(_ metrics: IslandMetrics) {
        state.jump(to: metrics)
        place(IslandLayout.canvasSize(metrics))
        container.layoutSubtreeIfNeeded()
        pump()
    }

    /// Runs `body` `seconds` of story time from now.
    func later(_ seconds: Double, _ body: @escaping @MainActor () -> Void) { pending.append((now + seconds, body)) }

    /// Story time `t`: due tidying runs, SwiftUI catches up, the baked tracks are evaluated.
    func advance(to t: Double) {
        now = 1000 + t
        state.clock.film(at: clockDate(t))
        while let i = pending.indices.filter({ pending[$0].at <= now }).min(by: { pending[$0].at < pending[$1].at }) {
            let job = pending.remove(at: i)
            job.body()
        }
        // Every page sees the time since it was revealed (`IslandPageModel.filmTime`).
        for page in stage.pages.values {
            let shown = page.phase == .live || page.phase == .leaving
            let time = shown ? max(0, now - (page.revealStart ?? now)) : 0
            if page.model.filmTime != time { page.model.filmTime = time }
        }
        pump()
        stage.apply(at: now)
    }

    /// Lets SwiftUI lay out and measure what just changed (the stage commits the geometry once it has).
    func pump() {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
        container.layoutSubtreeIfNeeded()
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
    }

    /// The whole canvas, as the stage draws it now, at `captureScale` pixels per point.
    func capture() -> CGImage? {
        let rect = container.bounds
        let w = Int((rect.width * captureScale).rounded()), h = Int((rect.height * captureScale).rounded())
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = rect.size
        container.cacheDisplay(in: rect, to: rep)
        return rep.cgImage
    }
}

// MARK: - Cursor

/// The cursor, in story time: arcs between points (still at both ends), dips on a click.
struct PromoCursor {
    private var from = CGPoint.zero
    private var to = CGPoint.zero
    private var moveStart = 0.0
    private var moveLength = 0.0
    private(set) var clicks: [(at: Double, point: CGPoint)] = []
    private var visibility: [(at: Double, on: Bool)] = []
    private var presses: [(at: Double, down: Bool)] = []

    struct State {
        var position: CGPoint
        var scale: CGFloat
        var opacity: Float
        /// The rings of recent clicks: center, progress 0…1.
        var ripples: [(CGPoint, Double)]
    }

    static let rippleLength = 0.5

    func position(at t: Double) -> CGPoint {
        guard moveLength > 0 else { return t >= moveStart ? to : from }
        let x = min(max((t - moveStart) / moveLength, 0), 1)
        let p = CGFloat(PromoEase.reach(x))
        // A gentle arc (a hand's path), bowing down and away from the straight line.
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max(hypot(dx, dy), 0.001)
        var nx = -dy / length, ny = dx / length
        if ny < 0 { nx = -nx; ny = -ny }
        let bow = min(length * 0.12, 60)
        let control = CGPoint(x: (from.x + to.x) / 2 + nx * bow, y: (from.y + to.y) / 2 + ny * bow)
        let a = (1 - p) * (1 - p), b = 2 * (1 - p) * p, c = p * p
        return CGPoint(x: a * from.x + b * control.x + c * to.x, y: a * from.y + b * control.y + c * to.y)
    }

    mutating func move(to point: CGPoint, at t: Double, duration: Double) {
        from = position(at: t)
        if duration <= 0 { from = point }
        to = point
        moveStart = t
        moveLength = duration
    }

    mutating func click(at t: Double) { clicks.append((t, position(at: t))) }
    mutating func show(_ on: Bool, at t: Double) { visibility.append((t, on)) }
    mutating func press(_ down: Bool, at t: Double) { presses.append((t, down)) }

    /// How far the button is down (a drag holds it): 0…1, eased both ways.
    private func pressed(at t: Double) -> Double {
        var level = 0.0
        for (at, down) in presses where t >= at {
            let p = PromoEase.smooth((t - at) / 0.12)
            level = down ? level + (1 - level) * p : level * (1 - p)
        }
        return level
    }

    func state(at t: Double) -> State {
        var scale: CGFloat = 1 - 0.08 * CGFloat(pressed(at: t))
        var ripples: [(CGPoint, Double)] = []
        for click in clicks where t >= click.at {
            let d = t - click.at
            if d < 0.24 { scale *= 1 - 0.16 * CGFloat(sin(.pi * d / 0.24)) }
            if d < Self.rippleLength { ripples.append((click.point, d / Self.rippleLength)) }
        }
        var opacity: Float = 1
        for (at, on) in visibility where t >= at {
            let p = Float(min(max((t - at) / 0.25, 0), 1))
            opacity = on ? p : 1 - p
        }
        return State(position: position(at: t), scale: scale, opacity: opacity, ripples: ripples)
    }
}

enum PromoEase {
    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    static func outCubic(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }
    static func outQuint(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 5) }
    static func inCubic(_ x: Double) -> Double { pow(clamp(x), 3) }
    static func inOutCubic(_ x: Double) -> Double {
        let x = clamp(x)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
    static func smooth(_ x: Double) -> Double {
        let x = clamp(x)
        return x * x * (3 - 2 * x)
    }
    /// Smootherstep: still at both ends, and so is its acceleration (a camera move that starts and stops like a dolly).
    static func smoother(_ x: Double) -> Double {
        let x = clamp(x)
        return x * x * x * (x * (6 * x - 15) + 10)
    }
    /// A reach: still at both ends, fastest a third of the way (a hand moving a pointer).
    static func reach(_ x: Double) -> Double {
        let x = clamp(x)
        return 1 - pow(1 - x, 3) * (1 + 3 * x)
    }
    /// Out with a small overshoot (an icon landing).
    static func outBack(_ x: Double, _ s: Double = 1.4) -> Double {
        let x = clamp(x) - 1
        return 1 + (s + 1) * x * x * x + s * x * x
    }
}

// MARK: - Compositor

/// The desktop around the island, composited by `CARenderer` at the output resolution (points × `scale`), seen through
/// the camera; captions and titles over it, in the frame.
@MainActor
final class PromoCompositor {
    let screen: CGSize
    let scale: CGFloat
    let storyboard: PromoStoryboard
    private(set) var metrics: IslandMetrics
    /// The physical camera housing (it stays whatever the style).
    private let housing: IslandMetrics
    private let film: FXFilm
    private let world = CALayer()
    private let wallpaper = CALayer()
    private let menuBar = CALayer()
    /// The external monitor's room (wall, desk) and the display itself (aluminium frame, black bezel, stand), around
    /// the same virtual screen; shown only in the monitor scene, where the camera may pull back past the screen.
    private let room = CALayer()
    private var macMenuBarArt: CGImage?
    private var monitorMenuBarArt: CGImage?
    /// The monitor scene: no camera housing, a notch-less menu bar, the room around the display, a free camera.
    private(set) var monitor = false
    /// The menu bar's height on the external monitor (points).
    static let monitorMenuBar: CGFloat = 25
    private let canvasGroup = CALayer()
    private let fxBehind = CALayer()
    private let islandLayer = CALayer()
    private let fxInside = CALayer()
    private let insideMask = CAShapeLayer()
    private let notch = CAShapeLayer()
    private let fxFront = CALayer()
    private let rippleLayers = (0..<3).map { _ in CAShapeLayer() }
    /// The monitor's desktop windows (Finder, and Finder with the photo selected; Mail), between the wallpaper and the
    /// menu bar; shown only in the monitor scene.
    private let desk = CALayer()
    private let finderLayer = CALayer()
    private let finderSelected = CALayer()
    private let mailLayer = CALayer()
    /// The dragged photo under the cursor (above the island, as the window server draws a drag image).
    private let carryLayer = CALayer()
    /// The photo's width / height (the carried picture keeps it).
    private(set) var photoAspect: CGFloat = 1.5
    private let cursorLayer = CALayer()
    private let veil = CALayer()
    private var captions: [PromoCaptionLayers] = []
    private var titles: [(PromoTitle, [CALayer])] = []
    private var canvas: CGSize
    private let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    init?(screen: CGSize, scale: CGFloat, metrics: IslandMetrics, storyboard: PromoStoryboard, lang: PromoLanguage) {
        self.screen = screen
        self.scale = scale
        self.metrics = metrics
        housing = metrics
        self.storyboard = storyboard
        canvas = IslandLayout.canvasSize(metrics)
        guard let film = FXFilm(size: screen, scale: scale, background: CGColor(gray: 0, alpha: 1)) else { return nil }
        self.film = film
        // Art drawn for the closest shot (a zoom-through's last frames go to black, they need no more).
        let artZoom = min(storyboard.camera.map(\.zoom).max() ?? 1, 3.6)
        let cursorArt = PromoArt.cursor(scale: scale * artZoom)
        FX.quietly {
            let full = CGRect(origin: .zero, size: screen)
            for layer in [world, wallpaper, menuBar, canvasGroup, fxBehind, islandLayer, fxInside, notch, fxFront, cursorLayer, veil]
                as [CALayer] { layer.actions = FXLayer.noActions }
            world.bounds = full
            world.anchorPoint = .zero
            world.position = .zero
            film.root.addSublayer(world)

            wallpaper.frame = full
            let wallScale = scale * min(artZoom, 2)
            wallpaper.contents = PromoArt.wallpaper(size: CGSize(width: screen.width * wallScale, height: screen.height * wallScale))
            wallpaper.contentsGravity = .resize
            world.addSublayer(wallpaper)

            macMenuBarArt = PromoArt.menuBar(width: screen.width, height: metrics.menuBarHeight, notch: metrics.notchWidth,
                                             lang: lang, scale: scale * artZoom)
            monitorMenuBarArt = PromoArt.menuBar(width: screen.width, height: Self.monitorMenuBar, notch: 0,
                                                 lang: lang, scale: scale * artZoom)
            menuBar.frame = CGRect(x: 0, y: 0, width: screen.width, height: metrics.menuBarHeight)
            menuBar.contents = macMenuBarArt
            menuBar.contentsGravity = .resize
            world.addSublayer(menuBar)

            buildRoom()
            room.isHidden = true
            world.insertSublayer(room, below: wallpaper)

            buildDesk(lang: lang, scale: scale * min(artZoom, 2))
            desk.isHidden = true
            world.insertSublayer(desk, below: menuBar)

            world.addSublayer(canvasGroup)
            for layer in [fxBehind, islandLayer, fxInside, fxFront] { canvasGroup.addSublayer(layer) }
            islandLayer.contentsGravity = .resize
            insideMask.fillColor = CGColor(gray: 0, alpha: 1)
            fxInside.mask = insideMask
            fxInside.opacity = 0.7
            // The camera housing: the island's black runs under it («Чёлка»), the capsule floats below it («Островок»).
            notch.fillColor = CGColor(gray: 0, alpha: 1)
            canvasGroup.insertSublayer(notch, above: islandLayer)
            layoutCanvas()

            for ring in rippleLayers {
                ring.actions = FXLayer.noActions
                ring.fillColor = nil
                ring.strokeColor = CGColor(gray: 1, alpha: 1)
                ring.opacity = 0
                world.addSublayer(ring)
            }

            carryLayer.actions = FXLayer.noActions
            carryLayer.contentsGravity = .resize
            carryLayer.opacity = 0
            carryLayer.shadowColor = CGColor(gray: 0, alpha: 1)
            carryLayer.shadowOffset = CGSize(width: 0, height: 5)
            world.addSublayer(carryLayer)

            cursorLayer.contents = cursorArt.image
            cursorLayer.bounds = CGRect(origin: .zero, size: cursorArt.size)
            cursorLayer.anchorPoint = CGPoint(x: cursorArt.hotSpot.x / max(cursorArt.size.width, 1),
                                              y: cursorArt.hotSpot.y / max(cursorArt.size.height, 1))
            cursorLayer.shadowOpacity = 0
            cursorLayer.opacity = 0
            world.addSublayer(cursorLayer)

            veil.frame = full
            veil.backgroundColor = CGColor(gray: 0, alpha: 1)
            veil.opacity = 0
            film.root.addSublayer(veil)

            for caption in storyboard.captions {
                let layers = PromoCaptionLayers(caption, lang: lang, screen: screen, scale: scale)
                film.root.addSublayer(layers.group)
                captions.append(layers)
            }
            for title in storyboard.titles {
                var parts: [CALayer] = []
                let pieces = PromoArt.titlePieces(title, lang: lang, scale: scale)
                // A centered stack: icon, name, line, small line (gaps after each piece).
                let gaps: [CGFloat] = [26, 14, 22, 0]
                let present = pieces.indices.filter { pieces[$0] != nil }
                var total: CGFloat = 0
                for (n, i) in present.enumerated() {
                    total += CGFloat(pieces[i]!.height) / scale + (n < present.count - 1 ? gaps[i] : 0)
                }
                var y = screen.height * 0.5 - total / 2
                for (i, piece) in pieces.enumerated() {
                    let layer = CALayer()
                    layer.actions = FXLayer.noActions
                    layer.opacity = 0
                    if let piece {
                        let size = CGSize(width: CGFloat(piece.width) / scale, height: CGFloat(piece.height) / scale)
                        layer.contents = piece
                        layer.bounds = CGRect(origin: .zero, size: size)
                        layer.position = CGPoint(x: screen.width / 2, y: y + size.height / 2)
                        y += size.height + (i < gaps.count ? gaps[i] : 0)
                    }
                    film.root.addSublayer(layer)
                    parts.append(layer)
                }
                titles.append((title, parts))
            }
        }
        CATransaction.flush()
    }

    /// Lays the island's canvas out for the current style.
    private func layoutCanvas() {
        canvas = IslandLayout.canvasSize(metrics)
        canvasGroup.frame = CGRect(x: (screen.width - canvas.width) / 2, y: 0, width: canvas.width, height: canvas.height)
        for layer in [fxBehind, islandLayer, fxInside, fxFront, notch] as [CALayer] {
            layer.frame = CGRect(origin: .zero, size: canvas)
        }
        insideMask.frame = CGRect(origin: .zero, size: canvas)
        notch.path = CGPath(roundedRect: CGRect(x: (canvas.width - housing.notchWidth) / 2, y: -12,
                                                width: housing.notchWidth, height: housing.barHeight + 12),
                            cornerWidth: 9, cornerHeight: 9, transform: nil)
    }

    func restyle(_ metrics: IslandMetrics, monitor: Bool = false) {
        self.metrics = metrics
        self.monitor = monitor
        FX.quietly {
            for host in [fxBehind, fxInside, fxFront] { host.sublayers?.forEach { $0.removeFromSuperlayer() } }
            layoutCanvas()
            notch.isHidden = monitor
            room.isHidden = !monitor
            desk.isHidden = !monitor
            menuBar.frame = CGRect(x: 0, y: 0, width: screen.width, height: monitor ? Self.monitorMenuBar : housing.menuBarHeight)
            menuBar.contents = monitor ? monitorMenuBarArt : macMenuBarArt
        }
    }

    /// The room around the external monitor, in screen points (the screen is (0, 0, width, height)): a pale wall, a
    /// desk, and a Studio-Display-like monitor — a thin black bezel in an aluminium frame on a slim stand.
    private func buildRoom() {
        let W = screen.width, H = screen.height
        let bezel: CGFloat = 30, edge: CGFloat = 8
        let deskY = H + 0.30 * H
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
        func layer(_ frame: CGRect, _ color: CGColor? = nil) -> CALayer {
            let l = CALayer()
            l.actions = FXLayer.noActions
            l.frame = frame
            l.backgroundColor = color
            return l
        }
        func gradient(_ frame: CGRect, _ colors: [CGColor], _ stops: [NSNumber]? = nil, horizontal: Bool = false) -> CAGradientLayer {
            let g = CAGradientLayer()
            g.actions = FXLayer.noActions
            g.frame = frame
            g.colors = colors
            g.locations = stops
            if horizontal {
                g.startPoint = CGPoint(x: 0, y: 0.5)
                g.endPoint = CGPoint(x: 1, y: 0.5)
            }
            return g
        }
        room.actions = FXLayer.noActions
        room.frame = CGRect(x: -2 * W, y: -2 * H, width: 5 * W, height: 5 * H)
        room.sublayerTransform = CATransform3DMakeTranslation(2 * W, 2 * H, 0)
        let span = CGRect(x: -2 * W, y: -2 * H, width: 5 * W, height: 5 * H)

        // The wall: a warm light gray, a little darker toward the desk, with soft daylight falling on it from the left.
        room.addSublayer(gradient(CGRect(x: span.minX, y: span.minY, width: span.width, height: deskY - span.minY),
                                  [rgb(0.925, 0.918, 0.905), rgb(0.905, 0.897, 0.884), rgb(0.852, 0.842, 0.828)],
                                  [0, 0.62, 1]))
        let daylight = CAGradientLayer()
        daylight.actions = FXLayer.noActions
        daylight.type = .radial
        daylight.frame = CGRect(x: -1.6 * W, y: -1.5 * H, width: 3.4 * W, height: 3.6 * H)
        daylight.colors = [rgb(1, 0.99, 0.97, 0.55), rgb(1, 0.99, 0.97, 0)]
        daylight.startPoint = CGPoint(x: 0.5, y: 0.5)
        daylight.endPoint = CGPoint(x: 1, y: 1)
        room.addSublayer(daylight)

        // The desk: a pale oak top, lit along its back edge, a shade deeper toward the camera.
        room.addSublayer(gradient(CGRect(x: span.minX, y: deskY, width: span.width, height: span.maxY - deskY),
                                  [rgb(0.83, 0.79, 0.74), rgb(0.78, 0.74, 0.69), rgb(0.70, 0.66, 0.61)],
                                  [0, 0.12, 1]))
        room.addSublayer(layer(CGRect(x: span.minX, y: deskY - 0.5, width: span.width, height: 1.5),
                               rgb(1, 1, 1, 0.45)))
        // Where the wall meets the desk: a soft band of shade.
        room.addSublayer(gradient(CGRect(x: span.minX, y: deskY - 26, width: span.width, height: 26),
                                  [rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.05)]))

        // The stand: a soft contact shadow on the desk, a flat foot and a slim aluminium neck.
        let footWidth = 0.30 * W
        let contact = CALayer()
        contact.actions = FXLayer.noActions
        contact.frame = CGRect(x: W / 2 - footWidth * 0.55, y: deskY - 4, width: footWidth * 1.1, height: 22)
        contact.shadowPath = CGPath(ellipseIn: contact.bounds.insetBy(dx: 10, dy: 4), transform: nil)
        contact.shadowColor = CGColor(gray: 0, alpha: 1)
        contact.shadowOpacity = 0.32
        contact.shadowRadius = 9
        contact.shadowOffset = .zero
        room.addSublayer(contact)
        let foot = gradient(CGRect(x: W / 2 - footWidth / 2, y: deskY - 9, width: footWidth, height: 12),
                            [rgb(0.86, 0.86, 0.87), rgb(0.70, 0.70, 0.72)])
        foot.cornerRadius = 6
        room.addSublayer(foot)
        let neckWidth = 0.15 * W
        let neck = gradient(CGRect(x: W / 2 - neckWidth / 2, y: H + bezel, width: neckWidth, height: deskY - 8 - (H + bezel)),
                            [rgb(0.64, 0.64, 0.66), rgb(0.83, 0.83, 0.84), rgb(0.76, 0.76, 0.78), rgb(0.62, 0.62, 0.64)],
                            [0, 0.38, 0.7, 1], horizontal: true)
        room.addSublayer(neck)
        // The neck in the display's shade, just under it.
        room.addSublayer(gradient(CGRect(x: W / 2 - neckWidth / 2, y: H + bezel, width: neckWidth, height: 40),
                                  [rgb(0, 0, 0, 0.18), rgb(0, 0, 0, 0)]))

        // The display: its shadow on the wall, the aluminium edge (lit from above), the black bezel (the screen's own
        // layers sit over its middle).
        let outer = CGRect(x: -bezel - edge, y: -bezel - edge, width: W + 2 * (bezel + edge), height: H + 2 * (bezel + edge))
        let cast = CALayer()
        cast.actions = FXLayer.noActions
        cast.frame = outer
        cast.shadowPath = CGPath(roundedRect: cast.bounds, cornerWidth: 28, cornerHeight: 28, transform: nil)
        cast.shadowColor = CGColor(gray: 0, alpha: 1)
        cast.shadowOpacity = 0.22
        cast.shadowRadius = 46
        cast.shadowOffset = CGSize(width: 0, height: 30)
        room.addSublayer(cast)
        let frame = gradient(outer, [rgb(0.86, 0.86, 0.87), rgb(0.76, 0.76, 0.78), rgb(0.70, 0.70, 0.72)], [0, 0.5, 1])
        frame.cornerRadius = 28
        frame.borderColor = rgb(0, 0, 0, 0.12)
        frame.borderWidth = 0.75
        room.addSublayer(frame)
        let black = layer(CGRect(x: -bezel, y: -bezel, width: W + 2 * bezel, height: H + 2 * bezel), rgb(0.02, 0.02, 0.022))
        black.cornerRadius = 21
        room.addSublayer(black)
    }

    /// The monitor's desktop: Finder on Downloads (left of the island) and a Mail message (right of it), drawn once.
    private func buildDesk(lang: PromoLanguage, scale: CGFloat) {
        desk.actions = FXLayer.noActions
        desk.frame = CGRect(origin: .zero, size: screen)
        guard let shelf = PromoShelfFilm.shared else { return }
        let items = shelf.finder.map { (name: $0.name, thumbnail: shelf.thumbnail($0)) }
        let selected = shelf.finder.firstIndex(of: shelf.photo)
        let pad = PromoDesk.shadowPad
        for (layer, image, frame) in [
            (finderLayer, PromoArt.finderWindow(items: items, selected: nil, lang: lang, scale: scale), PromoDesk.finder),
            (finderSelected, PromoArt.finderWindow(items: items, selected: selected, lang: lang, scale: scale), PromoDesk.finder),
            (mailLayer, PromoArt.mailWindow(lang: lang, scale: scale), PromoDesk.mail),
        ] {
            layer.actions = FXLayer.noActions
            layer.contents = image
            layer.contentsGravity = .resize
            layer.frame = frame.insetBy(dx: -pad, dy: -pad)
            desk.addSublayer(layer)
        }
        finderSelected.opacity = 0
        // The photo itself (the file, not its thumbnail): it ends as the message's attachment, larger than a tile.
        if let image = NSImage(contentsOf: shelf.photo.url) {
            if image.size.height > 0 { photoAspect = image.size.width / image.size.height }
            carryLayer.contents = PromoArt.carriedPhoto(image, size: PromoDesk.attachment.size, scale: scale)
        }
    }

    // MARK: Effects (the library's layers, started at story time)

    func drip(at t: Double, geometry: IslandGeometry) {
        let outline = FXOutline(g: geometry, canvasWidth: canvas.width)
        let layer = AppearDripLayer(slot: .behind)
        add(layer, to: fxBehind, outline: outline)
        layer.play(at: film.t0 + t, target: outline)
    }

    func celebrate(at t: Double, geometry: IslandGeometry, anchor: CGPoint) {
        let outline = FXOutline(g: geometry, canvasWidth: canvas.width)
        // As `IslandEffectsDirector.celebrate`: the calm style, lines starting as the notice lands (0.14 s in).
        var style = DoneCelebrationStyle.calm
        style.anchorBurst = max(0.3, style.anchorBurst - 0.14)
        for (slot, host) in [(IslandEffectsSlot.behind, fxBehind), (.inside, fxInside), (.front, fxFront)] {
            let layer = DoneCelebrationLayer(slot: slot)
            layer.seed = 11
            add(layer, to: host, outline: outline)
            layer.play(at: film.t0 + t, style: style, intensity: 1, anchor: anchor)
        }
    }

    private func add(_ layer: FXLayer, to host: CALayer, outline: FXOutline) {
        FX.quietly {
            layer.frame = CGRect(origin: .zero, size: canvas)
            host.addSublayer(layer)
            layer.setNeedsLayout()
            layer.layoutIfNeeded()
            layer.follow(outline)
        }
    }

    // MARK: Frame

    /// `from` fading out over `to` (`p` 0…1, already eased).
    func dissolve(from a: CGImage, to b: CGImage, _ p: Double) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: b.width, height: b.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: b.width, height: b.height)
        ctx.interpolationQuality = .high
        ctx.draw(b, in: rect)
        ctx.setAlpha(CGFloat(1 - min(max(p, 0), 1)))
        ctx.draw(a, in: rect)
        return ctx.makeImage()
    }

    /// The island's snapshot blurred by `radius` points, inside its own silhouette (the edge stays crisp).
    func blurred(_ image: CGImage, radius: Double) -> CGImage? {
        guard radius > 0.05 else { return image }
        let sharp = CIImage(cgImage: image)
        let px = radius * Double(image.width) / Double(canvas.width)
        let soft = sharp.clampedToExtent().applyingGaussianBlur(sigma: px).cropped(to: sharp.extent)
        let inside = soft.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: sharp])
        let out = inside.composited(over: sharp)
        return ci.createCGImage(out, from: sharp.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// `v`: video seconds (camera, captions, titles, dips); `t`: story seconds (the island, its effects, the cursor).
    /// A fast camera move smears the world (not the type over it): the world is filmed alone, blurred, and the type
    /// filmed on a clear background over it.
    /// The desk's state at a moment: Finder's selection (0…1) and the carried photo.
    struct Desk {
        var selection: Double = 0
        var carry: PromoCarryTrack.State?
    }

    func render(video v: Double, story t: Double, island: CGImage, geometry: IslandGeometry, cursor: PromoCursor.State,
                desk: Desk = Desk()) -> CGImage? {
        let view = camera(at: v, geometry: geometry)
        let smear = motionBlur(at: v, geometry: geometry)
        func scene(world showWorld: Bool, overlays: Bool) -> CGImage? {
            film.frame(at: t) { [self] _ in
                world.isHidden = !showWorld
                islandLayer.contents = island
                insideMask.path = FXOutline(g: geometry, canvasWidth: canvas.width).closed
                var m = CATransform3DMakeTranslation(-view.origin.x * view.zoom, -view.origin.y * view.zoom, 0)
                m = CATransform3DScale(m, view.zoom, view.zoom, 1)
                world.transform = m
                finderSelected.opacity = Float(desk.selection)
                if let carry = desk.carry, carry.opacity > 0.001 {
                    carryLayer.bounds = CGRect(origin: .zero, size: carry.size)
                    carryLayer.position = carry.center
                    carryLayer.opacity = carry.opacity
                    carryLayer.shadowOpacity = Float(0.28 * carry.lifted)
                    carryLayer.shadowRadius = 9 * carry.lifted
                    carryLayer.shadowOffset = CGSize(width: 0, height: 5 * carry.lifted)
                } else {
                    carryLayer.opacity = 0
                }
                cursorLayer.position = cursor.position
                cursorLayer.transform = CATransform3DMakeScale(cursor.scale, cursor.scale, 1)
                cursorLayer.opacity = cursor.opacity
                for (i, ring) in rippleLayers.enumerated() {
                    guard i < cursor.ripples.count, cursor.opacity > 0.01 else {
                        ring.opacity = 0
                        continue
                    }
                    let (center, p) = cursor.ripples[i]
                    let r = 6 + 20 * CGFloat(PromoEase.outCubic(p))
                    ring.path = CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r), transform: nil)
                    ring.lineWidth = 1.6
                    ring.opacity = Float(0.9 * pow(1 - p, 1.6)) * cursor.opacity
                }
                var veilOpacity = 0.0
                for dip in storyboard.dips { veilOpacity = max(veilOpacity, Self.dip(v, dip)) }
                veil.opacity = overlays ? Float(veilOpacity) : 0
                for caption in captions {
                    caption.group.isHidden = !overlays
                    caption.apply(at: v)
                }
                for (title, parts) in titles {
                    for part in parts { part.isHidden = !overlays }
                    Self.applyTitle(title, parts, at: v)
                }
            }
        }
        guard let smear else { return scene(world: true, overlays: true) }
        guard let world = scene(world: true, overlays: false) else { return nil }
        film.background = CGColor(gray: 0, alpha: 0)
        let type = scene(world: false, overlays: true)
        film.background = CGColor(gray: 0, alpha: 1)
        let input = CIImage(cgImage: world)
        var out = smear(input.clampedToExtent()).cropped(to: input.extent)
        if let type { out = CIImage(cgImage: type).composited(over: out) }
        return ci.createCGImage(out, from: input.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    static func dip(_ v: Double, _ d: PromoDip) -> Double {
        guard v >= d.start, v <= d.end else { return 0 }
        if v < d.full { return d.opacity * PromoEase.smooth((v - d.start) / max(d.full - d.start, 0.001)) }
        if v <= d.hold { return d.opacity }
        return d.opacity * (1 - PromoEase.smooth((v - d.hold) / max(d.end - d.hold, 0.001)))
    }

    /// The title's pieces rise in one after another (the icon lands with a small overshoot), and fade together.
    private static func applyTitle(_ title: PromoTitle, _ parts: [CALayer], at v: Double) {
        for (i, layer) in parts.enumerated() {
            let delay = Double(i) * 0.16
            let d = v - title.start - delay
            guard d > 0 else {
                layer.opacity = 0
                continue
            }
            var alpha = PromoEase.smooth(d / 0.45)
            var dy = CGFloat(1 - PromoEase.outQuint(d / 0.9)) * 22
            var s: CGFloat = 1
            if i == 0, title.icon {
                s = CGFloat(0.82 + 0.18 * PromoEase.outBack(d / 0.75))
                dy *= 0.4
            } else if i == 1 {
                s = CGFloat(1.045 - 0.045 * PromoEase.outQuint(d / 1.1))
            }
            if let end = title.end, v > end - 0.3 {
                let q = PromoEase.smooth((v - (end - 0.3)) / 0.3)
                alpha *= 1 - q
                dy -= CGFloat(q) * 8
            }
            // The end card keeps breathing: a slow push on the whole stack.
            var drift: CGFloat = 1
            if title.end == nil { drift = 1 + 0.035 * CGFloat(PromoEase.smooth((v - title.start) / 3.5)) }
            let center = layer.superlayer.map { $0.bounds.midY } ?? layer.position.y
            dy += (layer.position.y - center) * (drift - 1)
            layer.opacity = Float(alpha)
            var m = CATransform3DMakeTranslation(0, dy, 0)
            m = CATransform3DScale(m, s * drift, s * drift, 1)
            layer.transform = m
        }
    }

    // MARK: Camera

    struct View {
        var zoom: CGFloat
        /// Top-left of the visible part of the screen, in screen points.
        var origin: CGPoint
    }

    static func resolve(_ point: PromoPoint, screen: CGSize, geometry g: IslandGeometry) -> CGPoint {
        switch point {
        case let .screen(x, y):
            return CGPoint(x: x * screen.width, y: y * screen.height)
        case let .island(x, y):
            let left = screen.width / 2 - g.width / 2
            return CGPoint(x: left + x * g.width, y: g.top + y * g.height)
        case let .points(x, y):
            return CGPoint(x: x, y: y)
        }
    }

    /// Where the focus point sits in the frame, from the top (a little high: the captions live below).
    nonisolated static let anchorY: CGFloat = 0.42

    /// The view of `focus` at `zoom`, kept on the screen; close shots may show the black bezel above its top edge (up
    /// to 30 % of the frame: the island hangs from the black, as on the real MacBook).
    private func view(zoom: CGFloat, focus: CGPoint) -> View {
        if monitor {
            // The monitor stands in its room: the camera may pull back past the screen and frames it freely.
            let w = screen.width / zoom, h = screen.height / zoom
            return View(zoom: zoom, origin: CGPoint(x: focus.x - w / 2, y: focus.y - h * Self.anchorY))
        }
        let z = max(zoom, 1)
        let w = screen.width / z, h = screen.height / z
        let bezel = 0.3 * h * CGFloat(PromoEase.smooth(Double(z - 1.5)))
        let x = min(max(focus.x - w / 2, 0), screen.width - w)
        let y = min(max(focus.y - h * Self.anchorY, -bezel), screen.height - h)
        return View(zoom: z, origin: CGPoint(x: x, y: y))
    }

    private func anchor(_ view: View) -> CGPoint {
        CGPoint(x: view.origin.x + screen.width / view.zoom / 2, y: view.origin.y + screen.height / view.zoom * Self.anchorY)
    }

    /// The camera at video second `v` (`.island` focus points follow the island as it is drawn now).
    func camera(at v: Double, geometry: IslandGeometry) -> View {
        let keys = storyboard.camera
        guard let first = keys.first else { return view(zoom: 1, focus: CGPoint(x: screen.width / 2, y: 0)) }
        guard let a = keys.lastIndex(where: { $0.at <= v }) else {
            return view(zoom: first.zoom, focus: Self.resolve(first.focus, screen: screen, geometry: geometry))
        }
        let ka = keys[a]
        let fa = Self.resolve(ka.focus, screen: screen, geometry: geometry)
        guard a + 1 < keys.count, !keys[a + 1].cut else { return view(zoom: ka.zoom, focus: fa) }
        let kb = keys[a + 1]
        let fb = Self.resolve(kb.focus, screen: screen, geometry: geometry)
        let x = (v - ka.at) / max(kb.at - ka.at, 0.001)
        // Smootherstep: still at both ends, and so is the acceleration (no sudden start or stop).
        let p = PromoEase.smoother(x)
        // Zoom in log space (a push feels even), the focus along the visible rect's clamped path.
        let z = CGFloat(exp(log(Double(ka.zoom)) + (log(Double(kb.zoom)) - log(Double(ka.zoom))) * p))
        let ca = anchor(view(zoom: ka.zoom, focus: fa)), cb = anchor(view(zoom: kb.zoom, focus: fb))
        let k = CGFloat(p)
        return view(zoom: z, focus: CGPoint(x: ca.x + (cb.x - ca.x) * k, y: ca.y + (cb.y - ca.y) * k))
    }

    /// A camera move fast enough to smear, as a 1/120 s shutter would see it (the same at any frame rate): a blur along
    /// it (pan) or from its pivot (zoom). Slow moves stay sharp.
    private func motionBlur(at v: Double, geometry: IslandGeometry) -> ((CIImage) -> CIImage)? {
        let shutter = 1.0 / 120
        let v0 = v - shutter
        guard v0 > 0, !storyboard.camera.contains(where: { $0.cut && $0.at > v0 && $0.at <= v }) else { return nil }
        let now = camera(at: v, geometry: geometry), before = camera(at: v0, geometry: geometry)
        let px = scale
        let width = Double(screen.width * px), height = Double(screen.height * px)
        let zoomRatio = Double(now.zoom / before.zoom)
        let zoomAmount = abs(log(zoomRatio)) * width * 0.5 - width * 0.004
        if zoomAmount > 0 {
            // The point that stays put between the two views (the zoom's pivot), in CI's bottom-up pixels.
            let dz = now.zoom - before.zoom
            let pivot = CGPoint(x: (now.zoom * now.origin.x - before.zoom * before.origin.x) / dz,
                                y: (now.zoom * now.origin.y - before.zoom * before.origin.y) / dz)
            let out = CGPoint(x: (pivot.x - now.origin.x) * now.zoom * px, y: (pivot.y - now.origin.y) * now.zoom * px)
            let amount = min(zoomAmount, width * 0.03)
            return { image in
                image.applyingFilter("CIZoomBlur", parameters: [
                    kCIInputCenterKey: CIVector(x: out.x, y: CGFloat(height) - out.y),
                    kCIInputAmountKey: amount,
                ])
            }
        }
        // Where the frame's center (now) was a moment ago, in output pixels.
        let center = CGPoint(x: now.origin.x + screen.width / now.zoom / 2, y: now.origin.y + screen.height / now.zoom / 2)
        let was = CGPoint(x: (center.x - before.origin.x) * before.zoom * px, y: (center.y - before.origin.y) * before.zoom * px)
        let shift = CGPoint(x: width / 2 - was.x, y: height / 2 - was.y)
        let length = Double(hypot(shift.x, shift.y)) - width * 0.006
        guard length > 0 else { return nil }
        let radius = min(length * 0.6, width * 0.025)
        let angle = atan2(Double(-shift.y), Double(shift.x))
        return { image in
            image.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: angle])
        }
    }
}

// MARK: - Kinetic captions

/// One caption's layers: a word per layer (they rise in one after another), and the small line under them.
@MainActor
final class PromoCaptionLayers {
    let caption: PromoCaption
    let group = CALayer()
    private var words: [(layer: CALayer, rest: CGPoint)] = []
    private var sub: (layer: CALayer, rest: CGPoint)?

    init(_ caption: PromoCaption, lang: PromoLanguage, screen: CGSize, scale: CGFloat) {
        self.caption = caption
        group.actions = FXLayer.noActions
        group.frame = CGRect(origin: .zero, size: screen)
        let left = caption.place == .left
        let maxWidth = left ? screen.width * 0.3 : screen.width * 0.84
        let space = caption.size * 0.27
        let lineHeight = caption.size * 1.18
        // Words, wrapped greedily into lines.
        let images = caption.text(lang).split(separator: " ").map {
            PromoArt.word(String($0), size: caption.size, ink: caption.ink, scale: scale)
        }
        var lines: [[(CGImage?, CGSize)]] = [[]]
        var lineWidth: CGFloat = 0
        for image in images {
            let size = CGSize(width: CGFloat(image?.width ?? 0) / scale, height: CGFloat(image?.height ?? 0) / scale)
            let pad = PromoArt.wordPadding(caption.size)
            let advance = size.width - 2 * pad
            if lineWidth > 0, lineWidth + space + advance > maxWidth {
                lines.append([])
                lineWidth = 0
            }
            lineWidth += (lineWidth > 0 ? space : 0) + advance
            lines[lines.count - 1].append((image, size))
        }
        let subImage = caption.sub.map { PromoArt.subline($0(lang), size: caption.size * 0.46, ink: caption.ink, scale: scale) }
        let subSize = subImage.map { CGSize(width: CGFloat($0?.width ?? 0) / scale, height: CGFloat($0?.height ?? 0) / scale) }
        let block = CGFloat(lines.count) * lineHeight + (subSize.map { $0.height * 0.75 + 8 } ?? 0)
        let top: CGFloat
        switch caption.place {
        case .left: top = screen.height * 0.40 - block / 2
        case .top: top = screen.height * 0.135 - block / 2
        case .bottom: top = screen.height * 0.9 - block
        }
        let pad = PromoArt.wordPadding(caption.size)
        for (row, line) in lines.enumerated() {
            let width = line.reduce(CGFloat(0)) { $0 + $1.1.width - 2 * pad } + space * CGFloat(max(line.count - 1, 0))
            var x = left ? screen.width * 0.065 : (screen.width - width) / 2
            let y = top + CGFloat(row) * lineHeight + lineHeight / 2
            for (image, size) in line {
                let layer = CALayer()
                layer.actions = FXLayer.noActions
                layer.contents = image
                layer.bounds = CGRect(origin: .zero, size: size)
                let rest = CGPoint(x: x - pad + size.width / 2, y: y)
                layer.position = rest
                layer.opacity = 0
                group.addSublayer(layer)
                words.append((layer, rest))
                x += size.width - 2 * pad + space
            }
        }
        if let subImage, let subSize {
            let layer = CALayer()
            layer.actions = FXLayer.noActions
            layer.contents = subImage
            layer.bounds = CGRect(origin: .zero, size: subSize)
            let y = top + CGFloat(lines.count) * lineHeight + 8 + subSize.height * 0.375
            let x = left ? screen.width * 0.065 - PromoArt.wordPadding(caption.size * 0.46) + subSize.width / 2 : screen.width / 2
            let rest = CGPoint(x: x, y: y)
            layer.position = rest
            layer.opacity = 0
            group.addSublayer(layer)
            sub = (layer, rest)
        }
    }

    func apply(at v: Double) {
        let c = caption
        guard v > c.start - 0.01, v < c.end + 0.5 else {
            for w in words { w.layer.opacity = 0 }
            sub?.layer.opacity = 0
            return
        }
        let rise = c.size * 0.55
        func place(_ layer: CALayer, _ rest: CGPoint, delay: Double, exitDelay: Double, rise: CGFloat) {
            let d = v - c.start - delay
            guard d > 0 else {
                layer.opacity = 0
                return
            }
            let p = PromoEase.outQuint(d / 0.6)
            var alpha = PromoEase.smooth(d / 0.32)
            var dy = CGFloat(1 - p) * rise
            let s = CGFloat(0.94 + 0.06 * p)
            let exitStart = c.end - 0.3 + exitDelay
            if v > exitStart {
                let q = PromoEase.smooth((v - exitStart) / 0.28)
                alpha *= 1 - q
                dy -= CGFloat(PromoEase.inCubic(q)) * rise * 0.45
            }
            layer.opacity = Float(max(0, min(1, alpha)))
            var m = CATransform3DMakeTranslation(0, dy, 0)
            m = CATransform3DScale(m, s, s, 1)
            layer.transform = m
        }
        for (i, w) in words.enumerated() {
            place(w.layer, w.rest, delay: Double(i) * 0.065, exitDelay: Double(i) * 0.012, rise: rise)
        }
        if let sub {
            place(sub.layer, sub.rest, delay: Double(words.count) * 0.065 + 0.12, exitDelay: 0, rise: rise * 0.5)
        }
    }
}
