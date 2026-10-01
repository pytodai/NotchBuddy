import AppKit
import SwiftUI
import NotchBuddyCore

/// `NotchBuddy --render-previews <dir>`: renders the island's states to PNGs with fake sessions, for
/// design review, then exits. Nothing else starts: no socket, no hooks, no menu bar item.
///
/// Every state is drawn twice, for a screen without a notch (the island hangs from a 30 pt menu bar)
/// and for a notched MacBook screen. `<dir>/motion/*.png` are filmstrips: each transition as a row of
/// frames, drawn with the island's own pieces (silhouette, content views, reveal and exit effects,
/// staggered rows, keyframed badges, pulses, hero mark) driven by the very curves the live island
/// animates with (`IslandMotion`), sampled at the frame's time.
@MainActor
enum IslandPreviewRenderer {
    nonisolated static let flag = "--render-previews"

    nonisolated static func requestedDirectory(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        return index + 1 < arguments.count ? arguments[index + 1] : "build/previews"
    }

    static let floating = IslandMetrics(style: .floating, notchWidth: 0,
                                        barHeight: IslandMetrics.floatingBarHeight(menuBar: 30), menuBarHeight: 30)
    static let notched = IslandMetrics(style: .notch, notchWidth: 188, barHeight: 37, menuBarHeight: 37)

    /// Renders everything; returns the process exit status.
    static func run(outputDirectory: String) -> Int32 {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        let motion = directory.appendingPathComponent("motion", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: motion, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot create \(motion.path): \(error)\n".utf8))
            return 1
        }
        NSApp.setActivationPolicy(.accessory)
        let data = FakeData(now: Date())
        let clock = IslandClock(frozenAt: data.now)
        var failures = 0
        // `NOTCHBUDDY_PREVIEWS=stills,films,live` renders only those parts (default: everything).
        let parts = Set((ProcessInfo.processInfo.environment["NOTCHBUDDY_PREVIEWS"] ?? "stills,films,live")
            .split(separator: ",").map(String.init))
        for (suffix, metrics) in [("floating", floating), ("notch", notched)] {
            let studio = Studio(metrics: metrics, clock: clock)
            for scene in data.scenes() where parts.contains("stills") && (scene.pose.mode != .idle || metrics.style == .notch) {
                let image = studio.still(scene)
                failures += write(image, to: directory.appendingPathComponent("\(scene.name)-\(suffix).png")) ? 0 : 1
            }
            for film in data.films(notch: metrics.style == .notch) where parts.contains("films") {
                let image = studio.filmstrip(film)
                failures += write(image, to: motion.appendingPathComponent("\(film.name)-\(suffix).png")) ? 0 : 1
            }
            guard parts.contains("live") else { continue }
            let (live, problems) = LiveCheck.run(metrics: metrics, data: data)
            failures += write(live, to: directory.appendingPathComponent("live-states-\(suffix).png")) ? 0 : 1
            let timing = LiveCheck.timing(metrics: metrics, data: data)
            for line in timing.report { print("live-timing-\(suffix): \(line)") }
            for problem in problems + timing.problems {
                FileHandle.standardError.write(Data("live-states-\(suffix): \(problem)\n".utf8))
            }
            failures += problems.count + timing.problems.count
        }
        return failures == 0 ? 0 : 1
    }

    // MARK: Images

    static func image<V: View>(_ view: V, scale: CGFloat = 2) -> CGImage? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = scale
        return renderer.cgImage.flatMap(sRGB)
    }

    /// The renderer may hand back an HDR (PQ) image on an HDR display, which reads washed out once written: previews
    /// are plain sRGB.
    static func sRGB(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    /// Images side by side (or in a grid) on a dark background, with an optional header.
    static func stitch(_ images: [CGImage], columns: Int, header: CGImage?, spacing: Int = 16, padding: Int = 32) -> CGImage? {
        guard !images.isEmpty else { return nil }
        let cellWidth = images.map(\.width).max() ?? 0
        let cellHeight = images.map(\.height).max() ?? 0
        let rows = (images.count + columns - 1) / columns
        let headerHeight = header.map { $0.height + spacing } ?? 0
        let width = max(2 * padding + columns * cellWidth + (columns - 1) * spacing, (header?.width ?? 0) + 2 * padding)
        let height = 2 * padding + headerHeight + rows * cellHeight + (rows - 1) * spacing
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.07, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Core Graphics has a bottom-left origin; place everything from the top.
        if let header {
            context.draw(header, in: CGRect(x: padding, y: height - padding - header.height,
                                            width: header.width, height: header.height))
        }
        for (i, image) in images.enumerated() {
            let x = padding + (i % columns) * (cellWidth + spacing)
            let top = padding + headerHeight + (i / columns) * (cellHeight + spacing)
            context.draw(image, in: CGRect(x: x, y: height - top - image.height, width: image.width, height: image.height))
        }
        return context.makeImage()
    }

    private static func write(_ image: CGImage?, to url: URL) -> Bool {
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

// MARK: - Studio

/// Measures content like the live island does (the same `islandContentRoot`, in a window that is never
/// shown) and composes frames of the island from explicit values.
@MainActor
private struct Studio {
    let metrics: IslandMetrics
    let clock: IslandClock

    var canvasWidth: CGFloat { IslandLayout.canvasSize(metrics).width }

    struct Measured {
        var size: CGSize
        var slots: [HeroSlotID: CGRect]
    }

    /// A state of the island to film or photograph.
    struct Pose {
        var mode: IslandMode
        var snapshot: IslandSnapshot
        var hovering = false
        var pinned = false
        var armed = true
        var entrance: IslandEntrance = .open
    }

    // MARK: Content

    /// The content view of a pose; a permission card carries its queue chrome unless `chrome` is false
    /// (a filmed card advance draws the chrome once, staying, over the two cards).
    func content(_ pose: Pose, chrome: Bool = true) -> AnyView {
        let snapshot = pose.snapshot
        switch pose.mode {
        case .hidden:
            return AnyView(EmptyView())
        case .idle, .collapsed:
            return AnyView(CollapsedIslandView(snapshot: snapshot, metrics: metrics))
        case .expanded:
            return AnyView(ExpandedIslandView(snapshot: snapshot, metrics: metrics, width: IslandLayout.listWidth(metrics),
                                              pinned: pose.pinned, actions: IslandActions()))
        case .permission:
            guard let card = snapshot.card else { return AnyView(EmptyView()) }
            let view = PermissionCardView(card: card, total: snapshot.cardCount, queue: snapshot.cardIDs,
                                          metrics: metrics, width: IslandLayout.cardWidth(metrics),
                                          armed: pose.armed, presentedAt: nil, keyboardActive: false,
                                          decide: { _ in })
            guard chrome else { return AnyView(view) }
            return AnyView(view.overlay(alignment: .top) { queueChrome(pose) })
        case .flash:
            guard let notice = snapshot.flash else { return AnyView(EmptyView()) }
            return AnyView(FlashView(notice: notice, session: snapshot.session(notice.key), duration: snapshot.flashDuration,
                                     quiet: snapshot.flashQuiet, metrics: metrics,
                                     width: notice.isDoneCard ? IslandLayout.doneWidth(metrics) : IslandLayout.flashWidth(metrics),
                                     queued: snapshot.flashQueued, onTap: {}))
        case .page(let id):
            guard let spec = IslandPages.spec(id) else { return AnyView(EmptyView()) }
            return spec.content(IslandPageContext(state: IslandViewState(), width: spec.width(metrics)))
        }
    }

    func queueChrome(_ pose: Pose) -> PermissionQueueChrome {
        PermissionQueueChrome(queue: pose.snapshot.cardIDs, total: pose.snapshot.cardCount, metrics: metrics,
                              width: IslandLayout.cardWidth(metrics))
    }

    func measure(_ pose: Pose) -> Measured {
        guard pose.mode != .hidden else { return Measured(size: .zero, slots: [:]) }
        let box = MeasureBox()
        let kind = pose.mode.content
        let root = content(pose)
            .islandContentRoot(kind, state: box)
            .environment(\.islandStaticRender, true)
            .environment(\.islandEntrance, pose.entrance)
            .environment(clock)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(0.4)
        while box.sizes[kind] == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        let size = box.sizes[kind] ?? host.fittingSize
        window.contentView = nil
        return Measured(size: size, slots: box.slots)
    }

    func geometry(_ pose: Pose, _ measured: Measured, lastPill: CGFloat = 300) -> IslandGeometry {
        IslandLayout.geometry(mode: pose.mode, metrics: metrics,
                              content: CGSize(width: measured.size.width.rounded(), height: measured.size.height.rounded()),
                              hovering: pose.hovering, pressed: false, lastPillWidth: lastPill)
    }

    func heroKey(_ pose: Pose) -> SessionKey? {
        IslandViewState.heroKey(for: pose.mode, pose.snapshot, reduce: false)
    }

    func hero(_ pose: Pose, _ measured: Measured) -> HeroSubject? {
        guard let key = heroKey(pose), let slot = measured.slots[HeroSlotID(kind: pose.mode.content, key: key)] else { return nil }
        return HeroSubject(id: key, rect: slot.offsetBy(dx: (canvasWidth - measured.size.width.rounded()) / 2, dy: 0))
    }

    // MARK: Stills

    func still(_ scene: FakeData.Scene) -> CGImage? {
        let pose = scene.pose
        let measured = measure(pose)
        let g = geometry(pose, measured)
        let hero = hero(pose, measured)
        let layer = FilmLayer(id: "content", view: content(pose), filmTime: nil, reveal: nil, exit: nil,
                              heroKey: hero?.id, entrance: pose.entrance)
        let frame = IslandFrame(metrics: metrics, canvasWidth: canvasWidth, height: max(g.height + 70, 120),
                                geometry: g, glow: scene.glow, glowLevel: scene.glow?.rest ?? 0,
                                contentOffsetY: IslandLayout.closedContentOffset(mode: pose.mode, metrics: metrics, geometry: g),
                                layers: [layer], heroes: hero.map { [$0] } ?? [], heroOpacity: [:],
                                mascots: pose.snapshot.heroMascots(hero.map { [$0] } ?? []), label: nil)
            .environment(\.islandStaticRender, true)
            .environment(clock)
        return IslandPreviewRenderer.image(frame)
    }

    // MARK: Filmstrips

    /// One frame ~every 30–150 ms across a transition. Content swaps happen at t = 0 (phase 1: the
    /// incoming view runs its reveal curve, the outgoing one its exit curve); the silhouette moves one
    /// frame later (`commitDelay`, phase 2) on the film's spring, plus its keyframed pulse. Closed
    /// content rides a silhouette narrower than itself (`ClosedContentFit`) as it does live.
    func filmstrip(_ film: Film) -> CGImage? {
        let commitDelay = 0.012
        let fromM = measure(film.from)
        let toM = measure(film.to)
        let lastPill = fromM.size.width + 2 * IslandLayout.closedEar(metrics)
        let fromG = film.from.mode == .hidden && metrics.style == .floating
            ? IslandLayout.geometry(mode: .hidden, metrics: metrics, content: .zero, hovering: false, pressed: false,
                                    lastPillWidth: toM.size.width + 2 * IslandLayout.closedEar(metrics))
            : geometry(film.from, fromM, lastPill: lastPill)
        let toG = geometry(film.to, toM, lastPill: lastPill)
        let fromHero = hero(film.from, fromM)
        let toHero = hero(film.to, toM)
        let fromOffset = IslandLayout.closedContentOffset(mode: film.from.mode, metrics: metrics, geometry: fromG)
        let toOffset = IslandLayout.closedContentOffset(mode: film.to.mode, metrics: metrics, geometry: toG)
        let reveal = IslandContentLayerParams.reveal(film.to.entrance, film.to.mode.content)
        // The closed island's natural width, when one is on screen (the fit follows a content swap only).
        let closedNatural: CGFloat = film.to.mode.content == .closed && film.to.mode != .hidden
            ? toM.size.width.rounded() : (film.from.mode.content == .closed ? fromM.size.width.rounded() : 0)
        let fitActive = !film.sameContent || film.from.mode == .idle
        let widest = max(fromG.width, toG.width) * 1.06 + 80
        let tallest = max(fromG.height, toG.height) * 1.06 + 64
        let frameWidth = min(max(widest, 360), canvasWidth)
        let frameHeight = max(tallest, 110)

        var frames: [CGImage] = []
        for t in film.times {
            let geoP = film.spring.progress(t - commitDelay)
            let revealP = reveal.curve.progress(t)
            let layoutP = film.spring.progress(t)
            var g = fromG.interpolated(to: toG, geoP)
            g.shadow = min(max(g.shadow, 0), 1)
            let pulse = film.pulse.map { IslandPulse.value($0, at: t - commitDelay) } ?? IslandPulse()
            var layers: [FilmLayer] = []
            var to = film.to
            if to.mode == .permission, !to.armed, t >= PermissionArming.seconds { to.armed = true }
            // The next card of a queue: only the requests swap; the queue chrome stays and animates.
            let deck = film.from.mode == .permission && film.to.mode == .permission
            if film.sameContent {
                // The content's own layout moves with the data spring from phase 1 (SwiftUI interpolates it).
                let width = fromM.size.width + (toM.size.width - fromM.size.width) * CGFloat(layoutP)
                layers.append(FilmLayer(id: "same", view: content(to), filmTime: t, reveal: nil, exit: nil,
                                        heroKey: toHero?.id, entrance: film.to.entrance,
                                        previousStatus: film.previousStatus,
                                        pillWidth: metrics.style == .floating ? width : nil))
            } else {
                if film.from.mode != .hidden {
                    layers.append(FilmLayer(id: "out", view: content(film.from, chrome: !deck), filmTime: 30, reveal: nil,
                                            exit: (film.exit, film.exit.curve.progress(t)),
                                            heroKey: fromHero?.id, entrance: film.from.entrance))
                }
                if film.to.mode != .hidden {
                    layers.append(FilmLayer(id: "in", view: content(to, chrome: !deck), filmTime: t,
                                            reveal: (reveal, revealP),
                                            exit: nil, heroKey: toHero?.id, entrance: film.to.entrance,
                                            heroFlies: fromHero != nil && fromHero?.id == toHero?.id))
                }
                if deck {
                    layers.append(FilmLayer(id: "chrome", view: AnyView(queueChrome(to)), filmTime: 30, reveal: nil,
                                            exit: nil, heroKey: nil, entrance: film.from.entrance,
                                            queueChange: FilmQueueChange(previous: film.from.snapshot.cardIDs,
                                                                         progress: film.spring.progress(t))))
                }
            }
            // The hero flies on its own spring (committed with the geometry); one that only exists on
            // one side fades in place.
            var heroes: [HeroSubject] = []
            var heroOpacity: [SessionKey: Double] = [:]
            if let a = fromHero, let b = toHero, a.id == b.id {
                heroes = [HeroSubject(id: b.id, rect: lerp(a.rect, b.rect, IslandMotion.hero.progress(t - commitDelay)),
                                      flies: a.rect != b.rect)]
            } else {
                if let a = fromHero {
                    heroes.append(a)
                    heroOpacity[a.id] = 1 - min(max(IslandMotion.exitOut.progress(t - commitDelay), 0), 1)
                }
                if let b = toHero {
                    heroes.append(b)
                    heroOpacity[b.id] = min(max(IslandMotion.heroIn.progress(t - commitDelay), 0), 1)
                }
            }
            let offset = fromOffset + (toOffset - fromOffset) * CGFloat(geoP)
            let glowLevel = film.glow.map { $0.level(at: t) } ?? 0
            let view = IslandFrame(metrics: metrics, canvasWidth: canvasWidth, height: frameHeight, geometry: g,
                                   pulse: pulse, glow: film.glow, glowLevel: glowLevel,
                                   shakeX: film.shake ? ErrorShake.value(at: t) : 0,
                                   contentOffsetY: offset, layers: layers, heroes: heroes, heroOpacity: heroOpacity,
                                   mascots: film.from.snapshot.heroMascots(heroes)
                                       .merging(film.to.snapshot.heroMascots(heroes)) { _, new in new },
                                   label: nil, closedNatural: closedNatural, fitActive: fitActive)
                .frame(width: frameWidth, height: frameHeight)
                .clipped()
                .overlay(alignment: .bottomLeading) { TimeLabel(text: "\(Int((t * 1000).rounded())) мс") }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .environment(clock)
            if let image = IslandPreviewRenderer.image(view) { frames.append(image) }
        }
        guard frames.count == film.times.count else { return nil }
        let header = IslandPreviewRenderer.image(
            Text(verbatim: film.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .padding(.vertical, 2))
        return IslandPreviewRenderer.stitch(frames, columns: frames.count, header: header)
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ p: Double) -> CGRect {
        let k = CGFloat(p)
        return CGRect(x: a.minX + (b.minX - a.minX) * k, y: a.minY + (b.minY - a.minY) * k,
                      width: a.width + (b.width - a.width) * k, height: a.height + (b.height - a.height) * k)
    }
}

@MainActor
private final class MeasureBox: IslandContentReceiver {
    var sizes: [IslandContentKind: CGSize] = [:]
    var slots: [HeroSlotID: CGRect] = [:]

    func contentMeasured(_ kind: IslandContentKind, _ size: CGSize) { sizes[kind] = size }
    func heroSlotMeasured(_ id: HeroSlotID, _ rect: CGRect) { slots[id] = rect }
}

/// One content view in a frame, with its reveal (incoming) or exit (outgoing) at the filmed moment.
private struct FilmLayer: Identifiable {
    let id: String
    let view: AnyView
    let filmTime: Double?
    let reveal: (RevealParams, Double)?
    let exit: (IslandExit, Double)?
    let heroKey: SessionKey?
    let entrance: IslandEntrance
    /// The hero mark flies in from the outgoing content (`IslandMotion.heroTextLag`).
    var heroFlies = false
    var previousStatus: [SessionKey: SessionStatus] = [:]
    var pillWidth: CGFloat?
    var queueChange: FilmQueueChange?

    var body: some View {
        view
            .environment(\.islandFilmPillWidth, pillWidth)
            .environment(\.islandFilmQueueChange, queueChange)
            .fixedSize()
            .environment(\.islandFilmTime, filmTime)
            .environment(\.islandHeroKey, heroKey)
            .environment(\.islandHeroFlies, heroFlies)
            .environment(\.islandEntrance, entrance)
            .environment(\.islandFilmPreviousStatus, previousStatus)
            .modifier(RevealEffect(p: reveal?.1 ?? 1, e: reveal?.0 ?? .opacityOnly))
            .modifier(ExitEffect(q: exit?.1 ?? 0, e: exit?.0.params ?? IslandExit.out.params))
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// The island on a desktop backdrop, composed like `IslandView` from explicit values.
private struct IslandFrame: View {
    let metrics: IslandMetrics
    let canvasWidth: CGFloat
    let height: CGFloat
    let geometry: IslandGeometry
    var pulse = IslandPulse()
    var glow: IslandGlow?
    var glowLevel: Double = 0
    var shakeX: CGFloat = 0
    var contentOffsetY: CGFloat = 0
    let layers: [FilmLayer]
    let heroes: [HeroSubject]
    let heroOpacity: [SessionKey: Double]
    var mascots: [SessionKey: MascotState] = [:]
    let label: String?
    var closedNatural: CGFloat = 0
    var fitActive = false

    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper()
            MenuBarStrip(metrics: metrics)
            if metrics.style == .notch {
                // The camera housing the island wraps.
                IslandShape(earRadius: 0, bottomRadius: 9)
                    .fill(Color.black)
                    .frame(width: metrics.notchWidth, height: metrics.barHeight)
            }
            ZStack(alignment: .top) {
                IslandSurface(g: geometry, pulse: pulse, glow: glow, glowLevel: glowLevel)
                ZStack(alignment: .top) {
                    ForEach(layers) { layer in layer.body }
                    IslandHeroLayer(heroes: heroes, midX: canvasWidth / 2, opacity: heroOpacity, mascots: mascots)
                }
                .modifier(ClosedContentFit(width: geometry.width - 2 * geometry.ear, natural: closedNatural,
                                           active: fitActive, notch: metrics.style == .notch))
                .offset(y: contentOffsetY)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .mask(alignment: .top) { IslandSilhouette(g: geometry, pulse: pulse).fill(Color.black) }
            }
            .offset(x: shakeX)
            .frame(width: canvasWidth, height: height, alignment: .top)
            if metrics.style == .notch {
                // The camera housing has no pixels: whatever the island draws there is not seen.
                IslandShape(earRadius: 0, bottomRadius: 9)
                    .fill(Color.black)
                    .frame(width: metrics.notchWidth, height: metrics.barHeight)
            }
        }
        .frame(width: canvasWidth, height: height, alignment: .top)
        .overlay(alignment: .bottomLeading) {
            if let label { TimeLabel(text: label) }
        }
        .clipped()
    }
}

private struct TimeLabel: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Color.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .padding(8)
    }
}

private struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.22), Color(red: 0.05, green: 0.06, blue: 0.1)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.35, green: 0.22, blue: 0.55).opacity(0.55), .clear],
                           center: UnitPoint(x: 0.18, y: 0.1), startRadius: 0, endRadius: 360)
            RadialGradient(colors: [Color(red: 0.1, green: 0.42, blue: 0.5).opacity(0.45), .clear],
                           center: UnitPoint(x: 0.85, y: 0.55), startRadius: 0, endRadius: 420)
        }
    }
}

/// Sample copy of the previews (prompts, replies, the fake menu bar) in the render's language, so an English render
/// (`NOTCHBUDDY_LANG=en`) reads like an English user's Mac. Not interface text: previews only.
func sample(_ ru: String, _ en: String) -> String { L10n.shared.language == .ru ? ru : en }

private struct MenuBarStrip: View {
    let metrics: IslandMetrics

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
            Text("Terminal").font(.system(size: 13, weight: .bold))
            ForEach([sample("Файл", "File"), sample("Правка", "Edit"), sample("Вид", "View")], id: \.self) { Text($0).font(.system(size: 13)) }
            Spacer()
            Image(systemName: "wifi").font(.system(size: 13, weight: .semibold))
            Image(systemName: "battery.75percent").font(.system(size: 14))
            Text(sample("Вт 29 сент. 22:41", "Tue Sep 29 22:41")).font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(Color.white.opacity(0.9))
        .padding(.horizontal, 14)
        .frame(height: metrics.menuBarHeight)
        .background(Color.white.opacity(0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5) }
    }
}

// MARK: - Films

private struct Film {
    let name: String
    let title: String
    let times: [Double]
    let from: Studio.Pose
    let to: Studio.Pose
    let spring: GeoSpring
    var pulse: IslandPulse.Kind?
    var exit: IslandExit = .out
    var glow: IslandGlow?
    /// A data change inside the same content (the view stays; its pieces change in place).
    var sameContent = false
    var previousStatus: [SessionKey: SessionStatus] = [:]
    var shake = false
}

// MARK: - Fake data

@MainActor
private struct FakeData {
    let now: Date
    let sessions: [SessionKey: AgentSession]
    let usage: UsageState
    let busyUsage: UsageState
    let claudeCard: PermissionCardInfo
    let codexCard: PermissionCardInfo

    static let claude = SessionKey(source: .claude, sessionId: "claude-1")
    static let codex = SessionKey(source: .codex, sessionId: "codex-1")
    static let kimi = SessionKey(source: .kimi, sessionId: "kimi-1")
    static let failed = SessionKey(source: .claude, sessionId: "claude-2")
    static let longName = SessionKey(source: .kimi, sessionId: "kimi-2")
    static let extra = (1...4).map { SessionKey(source: $0.isMultiple(of: 2) ? .codex : .claude, sessionId: "extra-\($0)") }

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
        event(Self.claude, .promptSubmitted, cwd: "\(home)/code/weather-app", ago: 134,
              message: sample("Сделай графики плавнее и добавь анимации", "Make the charts smoother and add animations"))
        event(Self.claude, .toolWillRun, cwd: "\(home)/code/weather-app", ago: 6,
              tool: "Bash", summary: "swift build -c release 2>&1 | tail -20")

        event(Self.codex, .promptSubmitted, cwd: "\(home)/code/api-gateway", ago: 400, message: sample("Почини падающие тесты", "Fix the failing tests"))
        event(Self.codex, .toolWillRun, cwd: "\(home)/code/api-gateway", ago: 90,
              tool: "exec_command", summary: "npm test -- --watch=false")
        event(Self.codex, .permissionRequest, cwd: "\(home)/code/api-gateway", ago: 45,
              tool: "exec_command", summary: "rm -rf node_modules && npm ci")

        event(Self.kimi, .promptSubmitted, cwd: "\(home)/code/landing-page", ago: 900, message: sample("Обнови hero-блок", "Update the hero section"))
        event(Self.kimi, .toolWillRun, cwd: "\(home)/code/landing-page", ago: 700, tool: "WriteFile", summary: "src/Hero.tsx")
        event(Self.kimi, .stop, cwd: "\(home)/code/landing-page", ago: 420,
              message: sample("Обновил hero-блок и адаптив для мобильных", "Updated the hero section and the mobile layout"))

        event(Self.failed, .promptSubmitted, cwd: "\(home)/code/ml-pipeline", ago: 1500, message: sample("Перезапусти обучение", "Restart the training run"))
        event(Self.failed, .stopFailed, cwd: "\(home)/code/ml-pipeline", ago: 1210, message: "API Error: 529 Overloaded")

        event(Self.longName, .promptSubmitted, cwd: "\(home)/code/very-long-project-name-for-the-billing-service",
              ago: 30, message: sample("Добавь тесты", "Add tests"))
        for (i, key) in Self.extra.enumerated() {
            event(key, .promptSubmitted, cwd: "\(home)/code/service-\(i + 1)", ago: Double(200 + 60 * i), message: sample("Задача \(i + 1)", "Task \(i + 1)"))
            event(key, .toolWillRun, cwd: "\(home)/code/service-\(i + 1)", ago: Double(20 + 7 * i),
                  tool: ["Read", "Grep", "WebFetch", "mcp__github__create_issue"][i % 4], summary: "src/module\(i).swift")
        }
        sessions = store.sessions

        usage = .loaded(UsageSnapshot(
            fiveHour: UsageWindow(utilization: 42, resetsAt: now.addingTimeInterval(2 * 3600 + 10 * 60)),
            sevenDay: UsageWindow(utilization: 18, resetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600)),
            fetchedAt: now))
        busyUsage = .loaded(UsageSnapshot(
            fiveHour: UsageWindow(utilization: 78, resetsAt: now.addingTimeInterval(52 * 60)),
            sevenDay: UsageWindow(utilization: 64, resetsAt: now.addingTimeInterval(86400)),
            fetchedAt: now))

        let bash = AgentEvent(
            source: .claude, hookEventName: "PermissionRequest", kind: .permissionRequest, sessionId: Self.claude.sessionId,
            cwd: "\(home)/code/weather-app", toolName: "Bash", toolSummary: "rm -rf .build && swift build -c release",
            decisionSupported: true, canAlwaysAllow: true, timestamp: now.addingTimeInterval(-12),
            raw: .object(["tool_input": .object([
                "command": .string("rm -rf .build && swift build -c release && ./scripts/build-app.sh --install"),
                "description": .string(sample("Пересобрать приложение с нуля и установить его в /Applications", "Rebuild the app from scratch and install it in /Applications")),
            ])]))
        claudeCard = PermissionCardInfo(id: bash.id, event: bash, receivedAt: now.addingTimeInterval(-12),
                                        projectTitle: "weather-app")

        let permissions = AgentEvent(
            source: .codex, hookEventName: "PermissionRequest", kind: .permissionRequest, sessionId: Self.codex.sessionId,
            cwd: "\(home)/code/api-gateway", toolName: "request_permissions", toolSummary: "network, file_system",
            decisionSupported: true, canAlwaysAllow: false, timestamp: now.addingTimeInterval(-4),
            raw: .object(["tool_input": .object([
                "permissions": .object([
                    "network": .object(["allow": .array([.string("registry.npmjs.org")])]),
                    "file_system": .object(["write": .array([.string("\(home)/code/api-gateway/node_modules")])]),
                ]),
                "reason": .string(sample("Нужно скачать зависимости, чтобы запустить тесты", "Needs to download dependencies to run the tests")),
            ])]))
        codexCard = PermissionCardInfo(id: permissions.id, event: permissions, receivedAt: now.addingTimeInterval(-4),
                                       projectTitle: "api-gateway")
    }

    /// The chosen sessions in `SessionStore.ordered` order.
    func ordered(_ keys: [SessionKey]) -> [AgentSession] {
        SessionStore.ordered(keys.compactMap { sessions[$0] })
    }

    /// `session` with another status (since `ago` seconds).
    func with(_ key: SessionKey, _ status: SessionStatus, ago: TimeInterval, message: String? = nil) -> AgentSession {
        var s = sessions[key]!
        s.status = status
        s.statusMoment = .wallOnly(now.addingTimeInterval(-ago))
        s.lastEventMoment = .wallOnly(now.addingTimeInterval(-ago))
        if let message { s.lastMessage = message }
        return s
    }

    struct Scene {
        let name: String
        var pose: Studio.Pose
        var glow: IslandGlow?
    }

    func scenes() -> [Scene] {
        let all = ordered([Self.claude, Self.codex, Self.kimi, Self.failed])
        let finished = FlashNotice(key: Self.claude, kind: .finished, title: "weather-app", detail: L("%@ — готово", "Claude Code"))
        let attention = FlashNotice(key: Self.codex, kind: .attention, title: "api-gateway",
                                    detail: "rm -rf node_modules && npm ci")
        func scene(_ name: String, _ mode: IslandMode, _ snapshot: IslandSnapshot, hovering: Bool = false,
                   pinned: Bool = false, armed: Bool = true, glow: IslandGlow? = nil) -> Scene {
            Scene(name: name, pose: Studio.Pose(mode: mode, snapshot: snapshot, hovering: hovering, pinned: pinned, armed: armed),
                  glow: glow)
        }
        var finishedSnapshot = IslandSnapshot(sessions: all, flash: finished, usage: usage)
        finishedSnapshot.flashDuration = 252
        let done = FlashNotice(key: Self.claude, kind: .finished, title: "weather-app · Сделай графики плавнее",
                               detail: L("%@ — готово", "Claude Code"),
                               reply: "## Готово\nГрафики теперь рисуются через Core Animation: **60 fps** даже под нагрузкой.\n"
                                   + "- пружина появления 0.46/0.78\n- столбцы проявляются из размытия\n- `swift test`: 640 тестов зелёные\n"
                                   + "Осталось проверить на большом экране и подобрать отступы подписей.\nЕщё строка, которая видна только при прокрутке.")
        var doneSnapshot = IslandSnapshot(sessions: all, flash: done, usage: usage)
        doneSnapshot.flashDuration = 252
        doneSnapshot.flashQueued = 2
        return [
            scene("collapsed-working", .collapsed, IslandSnapshot(sessions: ordered([Self.claude]), usage: usage)),
            scene("collapsed-waiting", .collapsed, IslandSnapshot(sessions: ordered([Self.codex]), usage: usage)),
            scene("collapsed-3-sessions", .collapsed,
                  IslandSnapshot(sessions: ordered([Self.claude, Self.codex, Self.kimi]), usage: busyUsage)),
            scene("collapsed-hover", .collapsed, IslandSnapshot(sessions: ordered([Self.claude, Self.kimi]), usage: usage),
                  hovering: true),
            scene("collapsed-long-title", .collapsed,
                  IslandSnapshot(sessions: ordered([Self.longName, Self.kimi]), usage: busyUsage)),
            scene("collapsed-error", .collapsed, IslandSnapshot(sessions: [with(Self.claude, .error, ago: 3,
                  message: "API Error: 529 Overloaded")], usage: usage)),
            scene("idle-notch", .idle, IslandSnapshot(sessions: [], usage: usage), hovering: true),
            scene("expanded-list", .expanded, IslandSnapshot(sessions: all, usage: usage), pinned: true),
            scene("expanded-scroll", .expanded,
                  IslandSnapshot(sessions: ordered([Self.claude, Self.codex, Self.kimi, Self.failed] + Self.extra), usage: usage)),
            scene("expanded-empty", .expanded, IslandSnapshot(sessions: [], usage: .unavailable(LKey("нет данных (API выключен)")))),
            scene("permission-card", .permission,
                  IslandSnapshot(sessions: all, card: claudeCard, cardCount: 3,
                                 cardIDs: [claudeCard.id, codexCard.id, UUID()], usage: usage), glow: .card),
            scene("permission-card-codex-request_permissions", .permission,
                  IslandSnapshot(sessions: all, card: codexCard, cardCount: 1, cardIDs: [codexCard.id], usage: usage),
                  glow: .card),
            scene("permission-card-arming", .permission,
                  IslandSnapshot(sessions: all, card: claudeCard, cardCount: 1, cardIDs: [claudeCard.id], usage: usage),
                  armed: false, glow: .card),
            scene("flash-finished", .flash, finishedSnapshot, glow: .finished(quiet: false)),
            scene("flash-done-card", .flash, doneSnapshot, glow: .finished(quiet: false)),
            scene("flash-attention", .flash, IslandSnapshot(sessions: all, flash: attention, usage: usage), glow: .attention),
        ]
    }

    func films(notch: Bool) -> [Film] {
        let three = ordered([Self.claude, Self.codex, Self.kimi])
        let trio = IslandSnapshot(sessions: three, usage: usage)
        let pill = Studio.Pose(mode: .collapsed, snapshot: trio, hovering: true)
        let pillRest = Studio.Pose(mode: .collapsed, snapshot: trio, entrance: .close)
        let list = Studio.Pose(mode: .expanded, snapshot: trio, entrance: .open)
        let quick: [Double] = [0, 0.035, 0.055, 0.08, 0.10, 0.12, 0.15, 0.18, 0.245, 0.40]
        let slow: [Double] = [0, 0.035, 0.055, 0.08, 0.12, 0.18, 0.30, 0.48, 0.75, 1.0]

        var finishedSnapshot = IslandSnapshot(sessions: three, flash: FlashNotice(
            key: Self.claude, kind: .finished, title: "weather-app", detail: nil), usage: usage)
        finishedSnapshot.flashDuration = 252
        let attentionSnapshot = IslandSnapshot(sessions: three, flash: FlashNotice(
            key: Self.codex, kind: .attention, title: "api-gateway", detail: "rm -rf node_modules && npm ci"), usage: usage)

        // Claude waits for its card: it leads the closed island, and its mark flies into the card.
        let waiting = [with(Self.claude, .waitingForUser, ago: 1)] + ordered([Self.codex, Self.kimi])
        let cardSnapshot = IslandSnapshot(sessions: waiting, card: claudeCard, cardCount: 2,
                                          cardIDs: [claudeCard.id, codexCard.id], usage: usage)
        // A queue of three: the front dot leaves, the next one widens, "1 из 3" rolls to "1 из 2".
        let third = UUID()
        let queuedCard = IslandSnapshot(sessions: waiting, card: claudeCard, cardCount: 3,
                                        cardIDs: [claudeCard.id, codexCard.id, third], usage: usage)
        let nextCard = IslandSnapshot(sessions: waiting, card: codexCard, cardCount: 2, cardIDs: [codexCard.id, third],
                                      usage: usage)

        let working = ordered([Self.claude, Self.kimi])
        let failing = [with(Self.claude, .error, ago: 0, message: "API Error: 529 Overloaded")] + ordered([Self.kimi])

        return [
            Film(name: "open", title: "Открытие: свёрнут (курсор над ним) → список · spring 0.46/0.78 · вспышка ушек +4",
                 times: quick, from: pill, to: list, spring: IslandMotion.open, pulse: .earFlare(4)),
            Film(name: "close", title: "Закрытие: список → свёрнут · spring 0.36/0.92 · содержимое «распускается» к посадке",
                 times: quick, from: Studio.Pose(mode: .expanded, snapshot: trio, entrance: .open),
                 to: pillRest, spring: IslandMotion.close, pulse: .earFlare(3)),
            Film(name: "flash-finished", title: "Готово: свёрнут → уведомление · spring 0.48/0.68 · диск, галочка, пинг, зелёный ореол",
                 times: slow, from: Studio.Pose(mode: .collapsed, snapshot: trio),
                 to: Studio.Pose(mode: .flash, snapshot: finishedSnapshot, entrance: .pop),
                 spring: IslandMotion.flash, pulse: .earFlare(5), exit: .out, glow: .finished(quiet: false)),
            Film(name: "flash-attention", title: "Ждёт: свёрнут → уведомление · колокольчик звенит на 180 мс и 1,4 с",
                 times: [0, 0.035, 0.055, 0.08, 0.12, 0.2, 0.45, 1.0, 1.45, 1.7],
                 from: Studio.Pose(mode: .collapsed, snapshot: trio),
                 to: Studio.Pose(mode: .flash, snapshot: attentionSnapshot, entrance: .pop),
                 spring: IslandMotion.flash, pulse: .earFlare(5), exit: .out, glow: .attention),
            Film(name: "permission-in", title: "Запрос разрешения: свёрнут → карточка · секции каскадом, «Разрешить» заряжается 500 мс",
                 times: [0, 0.035, 0.055, 0.08, 0.10, 0.12, 0.15, 0.18, 0.25, 0.52],
                 from: Studio.Pose(mode: .collapsed, snapshot: IslandSnapshot(sessions: waiting, usage: usage)),
                 to: Studio.Pose(mode: .permission, snapshot: cardSnapshot, armed: false, entrance: .open),
                 spring: IslandMotion.open, pulse: .earFlare(4), glow: .card),
            Film(name: "card-advance", title: "Следующий запрос: карточка уходит вверх, остров «глотает», новая поднимается; точки очереди и «1 из N» — на месте",
                 times: [0, 0.035, 0.05, 0.065, 0.08, 0.10, 0.12, 0.15, 0.20, 0.52],
                 from: Studio.Pose(mode: .permission, snapshot: queuedCard, entrance: .open),
                 to: Studio.Pose(mode: .permission, snapshot: nextCard, armed: false, entrance: .deck),
                 spring: IslandMotion.morph, pulse: .gulp, exit: .sent, glow: .card),
            Film(name: "collapsed-status-change", title: "Смена статуса в свёрнутом: работает → ошибка · индикатор, подпись, ширина, встряска",
                 times: [0, 0.04, 0.08, 0.12, 0.18, 0.24, 0.32, 0.42, 0.56, 0.8],
                 from: Studio.Pose(mode: .collapsed, snapshot: IslandSnapshot(sessions: working, usage: usage)),
                 to: Studio.Pose(mode: .collapsed, snapshot: IslandSnapshot(sessions: failing, usage: usage)),
                 spring: IslandMotion.data, sameContent: true, previousStatus: [Self.claude: .working], shake: true),
            notch
                ? Film(name: "appear", title: "Первая сессия: вырез → крылья выезжают из-за камеры · spring 0.48/0.72",
                       times: quick, from: Studio.Pose(mode: .idle, snapshot: IslandSnapshot(usage: usage)),
                       to: Studio.Pose(mode: .collapsed, snapshot: trio, entrance: .pop), spring: IslandMotion.appear,
                       sameContent: true)
                : Film(name: "appear", title: "Появление: из верхнего края · spring 0.48/0.72 · ушки формируются по мере роста",
                       times: quick, from: Studio.Pose(mode: .hidden, snapshot: IslandSnapshot()),
                       to: Studio.Pose(mode: .collapsed, snapshot: trio, entrance: .pop), spring: IslandMotion.appear),
        ]
    }
}

// MARK: - Live check

/// The real island, not a re-creation: the Core Animation stage (`IslandStage`; `IslandRootView` with
/// `NOTCHBUDDY_SWIFTUI_ISLAND=1`) in an `IslandPanel` (far off every screen, so
/// nothing shows while this runs; it is drawn on demand for the captures), driven through its
/// modes via `IslandViewState` exactly as the controller does (measurement, two-phase commit, hero,
/// transitions, springs) and captured once each state has settled. Also checks that the silhouette
/// settled on the measured content and that the hero mark landed on its slot.
@MainActor
private enum LiveCheck {
    /// The stages of the checks (the state holds its renderer weakly).
    private static var stages: [IslandStage] = []

    /// The real island in a click-through panel far off every screen.
    private static func stage(_ metrics: IslandMetrics) -> (IslandViewState, IslandPanel, NSView, CGSize) {
        let state = IslandViewState()
        state.jump(to: metrics)
        let canvas = IslandLayout.canvasSize(metrics)
        let panel = IslandPanel()
        let container: IslandContainerView
        if IslandStage.enabled {
            // The island as the app draws it: the Core Animation stage.
            let stage = IslandStage(state: state)
            stages.append(stage)
            container = IslandContainerView(host: stage.view)
        } else {
            let host = IslandHostingView(rootView: IslandRootView(state: state))
            host.sizingOptions = []
            container = IslandContainerView(host: host)
        }
        panel.contentView = container
        // `IslandPanel` keeps any frame it is given (no constraining to a screen).
        panel.setFrame(NSRect(x: -40_000, y: -40_000, width: canvas.width, height: canvas.height), display: false)
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        return (state, panel, container, canvas)
    }

    /// The real pipeline mid-flight, as numbers (a capture of the layer tree cannot show SwiftUI's
    /// opacity and blur mid-animation): how long after `setContent` the silhouette's single commit came
    /// (measure, then move, in the new content's first layout pass: within ~3 frames even in a debug
    /// build, never a second commit), and whether the shape was heading for the measured content 40, 70
    /// and 110 ms in.
    static func timing(metrics: IslandMetrics, data: FakeData) -> (report: [String], problems: [String]) {
        let (state, panel, _, _) = stage(metrics)
        defer { panel.orderOut(nil) }
        let trio = IslandSnapshot(sessions: data.ordered([FakeData.claude, FakeData.codex, FakeData.kimi]), usage: data.usage)
        let waiting = [data.with(FakeData.claude, .waitingForUser, ago: 1)] + data.ordered([FakeData.codex, FakeData.kimi])
        let card = IslandSnapshot(sessions: waiting, card: data.claudeCard, cardCount: 2,
                                  cardIDs: [data.claudeCard.id, data.codexCard.id], usage: data.usage)
        let next = IslandSnapshot(sessions: waiting, card: data.codexCard, cardCount: 1, cardIDs: [data.codexCard.id],
                                  usage: data.usage)
        var finished = trio
        finished.flash = FlashNotice(key: FakeData.claude, kind: .finished, title: "weather-app", detail: nil)
        var report: [String] = []
        var problems: [String] = []

        /// `limit`: the latest acceptable commit (a cold open, with nothing built ahead, may take longer: it lays
        /// the whole list out first).
        func probe(_ name: String, limit: Double = 0.05, change: () -> Void) {
            let commits = state.commitCount
            let t0 = CACurrentMediaTime()
            change()
            var committedAfter: Double?
            var aimed: [String] = []
            for t in [0.04, 0.07, 0.11] {
                while CACurrentMediaTime() < t0 + t {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
                    if committedAfter == nil, state.commitCount > commits { committedAfter = CACurrentMediaTime() - t0 }
                }
                let target = state.target(), g = state.geometry
                aimed.append(abs(g.width - target.width) < 0.5 && abs(g.height - target.height) < 0.5 ? "✓" : "✗")
            }
            spin(0.7)
            let ms = committedAfter.map { "\(Int(($0 * 1000).rounded())) мс" } ?? "нет"
            report.append("\(name): коммит силуэта через \(ms), цель \(aimed.joined()) (40/70/110 мс), коммитов \(state.commitCount - commits)")
            if let committedAfter, committedAfter > limit { problems.append("\(name): commit \(ms) after setContent") }
            if committedAfter == nil { problems.append("\(name): no commit within 110 ms") }
            if aimed.contains("✗") { problems.append("\(name): silhouette not aimed at the measured content (\(aimed.joined()))") }
            if state.commitCount - commits > 1 { problems.append("\(name): \(state.commitCount - commits) commits (one expected)") }
        }

        state.setContent(.collapsed, snapshot: trio)
        spin(0.8)
        // As in the app: the pointer rests on the island first (the hover grow builds the list ahead), then it opens.
        state.setHovering(true)
        spin(0.15)
        probe("открытие") { state.setContent(.expanded, snapshot: trio) }
        probe("закрытие") { state.setContent(.collapsed, snapshot: trio) }
        spin(1.2)
        // Opened with nothing built ahead (the global hotkey, the menu's «Настройки…»).
        probe("открытие без наведения", limit: 0.11) { state.setContent(.expanded, snapshot: trio) }
        probe("снова закрыт") { state.setContent(.collapsed, snapshot: trio) }
        probe("карточка") {
            state.cardPresentedAt = AppClock.monotonicSeconds()
            state.setContent(.permission, snapshot: card, glow: .card)
        }
        probe("следующая карточка") {
            state.cardPresentedAt = AppClock.monotonicSeconds()
            state.setContent(.permission, snapshot: next, entrance: .deck, pulse: .gulp, glow: .card)
        }
        probe("вспышка") { state.setContent(.flash, snapshot: finished, glow: .finished(quiet: false)) }
        probe("снова свёрнут") { state.setContent(.collapsed, snapshot: trio) }
        return (report, problems)
    }

    static func run(metrics: IslandMetrics, data: FakeData) -> (CGImage?, [String]) {
        let (state, panel, container, canvas) = stage(metrics)
        defer { panel.orderOut(nil) }

        var frames: [CGImage] = []
        var problems: [String] = []
        func shot(_ label: String) {
            spin(0.75)
            let target = state.target()
            let g = state.geometry
            if abs(g.width - target.width) > 0.5 || abs(g.height - target.height) > 0.5 {
                problems.append("\(label): silhouette \(g.width)×\(g.height) ≠ target \(target.width)×\(target.height)")
            }
            if state.mode != .hidden, state.mode != .idle {
                let content = state.contentSize(state.mode.content)
                let expectedWidth = content.width + 2 * g.ear
                if !state.hovering, !state.pressed, abs(expectedWidth - g.width) > 0.5 {
                    problems.append("\(label): width \(g.width) ≠ measured content \(content.width) + ears")
                }
            }
            if state.heroKey != nil, state.heroes.isEmpty {
                problems.append("\(label): hero \(state.heroKey!) has no slot")
            }
            let height = min(canvas.height, max(g.height + 60, 110))
            if let image = capture(container, height: height) {
                let labelImage = IslandPreviewRenderer.image(
                    Text(verbatim: label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.white.opacity(0.85)))
                frames.append(labelled(image, labelImage))
            }
        }

        let trio = IslandSnapshot(sessions: data.ordered([FakeData.claude, FakeData.codex, FakeData.kimi]), usage: data.usage)
        state.setContent(.collapsed, snapshot: trio)
        shot("свёрнут")
        state.setHovering(true)
        shot("курсор над ним")
        state.setPressed(true)
        shot("нажат")
        state.pinned = true
        state.setContent(.expanded, snapshot: trio)
        shot("список (закреплён)")
        var many = trio
        many.sessions = data.ordered([FakeData.claude, FakeData.codex, FakeData.kimi, FakeData.failed] + FakeData.extra)
        state.updateData(many)
        shot("8 сессий: прокрутка")
        let waiting = [data.with(FakeData.claude, .waitingForUser, ago: 1)] + data.ordered([FakeData.codex, FakeData.kimi])
        let card = IslandSnapshot(sessions: waiting, card: data.claudeCard, cardCount: 2,
                                  cardIDs: [data.claudeCard.id, data.codexCard.id], usage: data.usage)
        state.cardPresentedAt = AppClock.monotonicSeconds()
        state.setContent(.permission, snapshot: card, glow: .card)
        state.armedCardID = data.claudeCard.id
        shot("карточка разрешения")
        let next = IslandSnapshot(sessions: waiting, card: data.codexCard, cardCount: 1, cardIDs: [data.codexCard.id],
                                  usage: data.usage)
        state.setContent(.permission, snapshot: next, entrance: .deck, pulse: .gulp, glow: .card)
        state.armedCardID = data.codexCard.id
        shot("следующая карточка")
        var finished = trio
        finished.flash = FlashNotice(key: FakeData.claude, kind: .finished, title: "weather-app", detail: nil)
        finished.flashDuration = 252
        state.pinned = false
        state.setContent(.flash, snapshot: finished, glow: .finished(quiet: false))
        shot("вспышка «готово»")
        state.setContent(.collapsed, snapshot: trio)
        shot("снова свёрнут")
        if metrics.style == .notch {
            state.setContent(.idle, snapshot: IslandSnapshot(usage: data.usage))
            shot("нет сессий: размер выреза")
        } else {
            state.setContent(.hidden, snapshot: IslandSnapshot(usage: data.usage))
            shot("нет сессий: спрятан")
        }
        return (IslandPreviewRenderer.stitch(frames, columns: 5, header: nil), problems)
    }

    private static func spin(_ seconds: TimeInterval) {
        spin(until: CACurrentMediaTime() + seconds)
    }

    private static func spin(until end: CFTimeInterval) {
        while CACurrentMediaTime() < end {
            let left = end - CACurrentMediaTime()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(max(0, min(left, 0.002))))
        }
    }

    /// The top `height` points of the view, as drawn right now.
    private static func capture(_ view: NSView, height: CGFloat) -> CGImage? {
        let rect = NSRect(x: 0, y: view.bounds.height - height, width: view.bounds.width, height: height)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        return rep.cgImage
    }

    /// The capture on the preview wallpaper color, with its label underneath.
    private static func labelled(_ image: CGImage, _ label: CGImage?) -> CGImage {
        let labelHeight = (label?.height ?? 0) + 12
        let width = image.width, height = image.height + labelHeight
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.setFillColor(CGColor(red: 0.16, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: labelHeight, width: width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: labelHeight, width: width, height: image.height))
        if let label {
            context.draw(label, in: CGRect(x: 12, y: 4, width: label.width, height: label.height))
        }
        return context.makeImage() ?? image
    }
}
