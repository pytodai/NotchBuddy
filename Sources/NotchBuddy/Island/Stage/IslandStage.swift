import AppKit
import NotchBuddyCore
import SwiftUI

/// What `IslandViewState` tells whoever draws the island. Every call is synchronous; `IslandStage` is the one
/// implementation (without a renderer the state drives the SwiftUI island, `IslandRootView`, instead).
@MainActor
protocol IslandRenderer: AnyObject {
    /// True while the renderer lays out new content: measurements reported meanwhile are recorded, not committed
    /// (the renderer commits once, with everything laid out).
    var isLayingOut: Bool { get }
    /// The content changes (`IslandViewState.setContent`): lay out the incoming pages, then commit the geometry
    /// (`IslandViewState.commitPending`).
    func showContent(from old: IslandMode, to new: IslandMode, exit: IslandExit)
    /// The silhouette heads for `IslandViewState.geometry` on `spring` (a content swap), with its pulse.
    func geometryCommitted(spring: GeoSpring, pulse: IslandPulse.Kind?)
    /// The target (or the flying marks) changed without a content swap: data, hover, press.
    func geometryRetargeted(spring: GeoSpring)
    /// The snapshot changed within the same mode (a session's status: the flying mascot's animation follows it).
    func snapshotChanged()
    func pressChanged()
    /// `mode` is likely next: build its content ahead (nothing shows).
    func prepare(_ mode: IslandMode)
    /// The flying mark's slot moved in the content on screen (the state retargets when the renderer says so).
    func heroSlotMoved()
    func pulseFired(_ kind: IslandPulse.Kind)
    func glowChanged(retrigger: Bool)
    func shake()
    /// Moved to another screen while retracted: new metrics, nothing animated.
    func metricsChanged()
    /// The same screen in the other style (`IslandMetrics.gap`): the pages move to where the island now floats; the shape
    /// follows on its spring (`geometryRetargeted`).
    func gapChanged()
}

/// The island, drawn by Core Animation: every transition is committed once, at its start, and the render server
/// plays it; NotchBuddy's main thread does no per-frame work, so a busy main thread (or a busy Mac) drops no frame
/// of the island's motion. See docs/island-architecture.md.
///
/// Layers, on the fixed transparent canvas (`IslandLayout.canvasSize`), centered on its top edge:
/// - `surface`: effects behind the island, the tinted halo and the ambient shadow (pre-rendered images stretched to
///   the silhouette's body, `IslandSurfaceImage`), and the black silhouette, a `CAShapeLayer` whose path (always
///   the same list of elements, `IslandPathBuilder`) follows the geometry's spring (`SpringTrack`) plus its pulse;
/// - `content`, masked by a second shape layer with the same path, its `sublayerTransform` carrying the closed
///   island's offset under a grown silhouette, its fit to a narrower one, and the press squish: the pages
///   (`IslandPage`, SwiftUI content laid out once at its final size, revealed and dismissed with opacity and
///   transform, its `.appearAfter` sections cascading in), effects inside the island, and the flying agent mark;
/// - `effectsAbove`: effects over the island, not masked (`IslandEffect`).
///
/// A change of mind (the pointer leaves mid-open) starts the next spring from the current one's value and speed at
/// that moment, which is exactly what the render server shows (it plays the same function).
@MainActor
final class IslandStage: IslandRenderer {
    unowned let state: IslandViewState
    let view = IslandStageView()
    let timeline = IslandTimeline()
    /// Media time (film renders step it).
    var clock: () -> CFTimeInterval = CACurrentMediaTime
    /// Tidying up once an animation is over (film renders collect it instead).
    var later: (_ seconds: Double, _ body: @escaping @MainActor () -> Void) -> Void = { seconds, body in
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds)) { MainActor.assumeIsolated { body() } }
    }

    private let surface = IslandLayerHostView()
    private let content = IslandFlippedView()
    private let heroHost = IslandLayerHostView()
    private let insideHost = IslandLayerHostView()
    private let aboveHost = IslandLayerHostView()
    private let behindLayer = CALayer()
    private let glowLayer = CALayer()
    private let shadowLayer = CALayer()
    private let silhouette = CAShapeLayer()
    private let mask = CAShapeLayer()

    // Motion
    private(set) var geometry = SpringTrack.rest(IslandGeometry().vector)
    private var pulse: PulseTrack?
    private var press = SpringTrack.rest([1])
    /// The closed island's offset in a grown (hovered, pressed) silhouette: it follows the target geometry on the
    /// geometry's spring (not the shape's height mid-flight: a closing list does not push the pill down).
    private var contentOffset = SpringTrack.rest([0])
    private var heroes: [SessionKey: HeroMark] = [:]
    /// The panel is on screen and not occluded: the flying mascot's frames play.
    private var windowVisible = true
    /// Effects that follow the silhouette (`addFollower`).
    private var followers: [IslandSilhouetteFollower] = []
    private var followerLayers: [ObjectIdentifier: CALayer] = [:]
    private var glow: IslandGlow?
    private var glowTint: NSColor?

    // Content
    private(set) var pages: [IslandPageID: IslandPage] = [:]
    private(set) var currentIDs: [IslandPageID] = []
    private(set) var isLayingOut = false
    /// The pages being laid out for a content swap (their measurements are the ones that count meanwhile).
    private var layingOut: Set<IslandPageID> = []
    /// The media time of the transition being committed (one clock for all its parts).
    private var transitionNow: CFTimeInterval?
    private var lastSize: CGSize = .zero
    /// Where the pages are laid out (`IslandMetrics.gap`: «Островок» floats below the canvas' top edge).
    private var layoutGap: CGFloat = 0

    init(state: IslandViewState) {
        self.state = state
        view.stage = self
        view.addSubview(surface)
        view.addSubview(content)
        view.addSubview(aboveHost)
        content.addSubview(insideHost)
        content.addSubview(heroHost)
        for layer in [glowLayer, shadowLayer] {
            layer.contentsScale = 2
            layer.contentsGravity = .resize
            layer.opacity = 0
            layer.actions = Self.noActions
        }
        glowLayer.contentsCenter = IslandSurfaceImage.glow.contentsCenter
        shadowLayer.contents = IslandSurfaceImage.shadow.image
        shadowLayer.contentsScale = IslandSurfaceImage.shadow.scale
        shadowLayer.contentsCenter = IslandSurfaceImage.shadow.contentsCenter
        for layer in [silhouette, mask] {
            layer.fillColor = NSColor.black.cgColor
            layer.actions = Self.noActions
            layer.path = CGPath(rect: .zero, transform: nil)
        }
        behindLayer.actions = Self.noActions
        surface.hostedLayer.addSublayer(behindLayer)
        surface.hostedLayer.addSublayer(glowLayer)
        surface.hostedLayer.addSublayer(shadowLayer)
        surface.hostedLayer.addSublayer(silhouette)
        content.layer?.mask = mask
        view.onLayout = { [weak self] in self?.layoutCanvas() }
        state.renderer = self
    }

    static let noActions: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(),
                                                "opacity": NSNull(), "contents": NSNull(), "transform": NSNull(),
                                                "sublayerTransform": NSNull(), "hidden": NSNull()]

    var canvas: CGSize { IslandLayout.canvasSize(state.metrics) }
    private var reduce: Bool { state.reduceMotion }

    private func layoutCanvas() {
        let bounds = view.bounds
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for v in [surface, content, heroHost, insideHost, aboveHost] as [NSView] {
            v.frame = CGRect(origin: .zero, size: bounds.size)
        }
        mask.frame = CGRect(origin: .zero, size: bounds.size)
        silhouette.frame = CGRect(origin: .zero, size: bounds.size)
        behindLayer.frame = CGRect(origin: .zero, size: bounds.size)
        for page in pages.values { page.layout(in: content.bounds, top: layoutGap) }
        CATransaction.commit()
    }

    // MARK: Pages

    /// The pages that show `mode`.
    private func pageIDs(for mode: IslandMode) -> [IslandPageID] {
        switch mode {
        case .hidden: return []
        case .idle, .collapsed: return state.metrics.style == .notch ? [.closedLeft, .closedRight] : [.closed]
        // The tab strip stays while its tabs swap under it (its pill glides; only the content slides).
        case .expanded: return state.tabsShown ? [.tabs, .list] : [.list]
        case .permission: return state.snapshot.card.map { [.card($0.id), .cardChrome] } ?? []
        case .flash: return state.snapshot.flash.map { [.flash($0.id)] } ?? []
        case .page(let id): return state.tabsShown && WidgetKind(pageID: id) != nil ? [.tabs, .custom(id)] : [.custom(id)]
        }
    }

    private func makePage(_ id: IslandPageID) -> IslandPage {
        let receiver = IslandPageReceiver()
        let page = IslandPage(id: id, state: state, receiver: receiver)
        receiver.stage = self
        receiver.page = page
        page.receiver = receiver
        page.builtAt = clock()
        page.sink.clock = { [weak self] in self?.clock() ?? CACurrentMediaTime() }
        page.view.accepts = { [weak self, weak page] in
            guard let self, let page else { return false }
            // The strip stays through tab switches: it takes clicks as soon as it has settled in, not only after
            // each new tab's own pause.
            if page.id == .tabs, self.currentIDs.contains(.tabs), let start = page.revealStart {
                return self.clock() - start > IslandChoreography.media(IslandMotion.interactiveDelay)
            }
            return self.state.contentInteractive && self.currentIDs.contains(page.id)
        }
        switch id {
        case .card(let cardID):
            page.model.card = state.snapshot.card?.id == cardID ? state.snapshot.card : nil
        case .flash(let noticeID):
            page.model.notice = state.snapshot.flash?.id == noticeID ? state.snapshot.flash : nil
        case .closedLeft, .closedRight:
            page.view.layer?.mask = halfMask(left: id == .closedLeft)
        default:
            break
        }
        page.view.layer?.opacity = 0
        page.layout(in: content.bounds, top: layoutGap)
        // Pages stack in the order they came, below the effects and the flying mark; a card goes under the queue
        // chrome that stays over the cards, a tab's content under the tab strip.
        let below: NSView = (id.isCard ? pages[.cardChrome]?.view : id.isTabContent ? pages[.tabs]?.view : nil) ?? insideHost
        content.addSubview(page.view, positioned: .below, relativeTo: below)
        pages[id] = page
        return page
    }

    /// A notch wing's cut: its half of the canvas.
    private func halfMask(left: Bool) -> CALayer {
        let layer = CALayer()
        layer.backgroundColor = NSColor.black.cgColor
        layer.actions = Self.noActions
        let width = canvas.width, height = canvas.height
        layer.frame = left ? CGRect(x: -width, y: -height, width: width * 1.5, height: height * 3)
            : CGRect(x: width / 2, y: -height, width: width * 1.5, height: height * 3)
        return layer
    }

    /// Whether a page's measurements are the silhouette's now.
    fileprivate func counts(_ page: IslandPage) -> Bool {
        guard page.id.measures else { return false }
        if isLayingOut { return layingOut.contains(page.id) }
        return currentIDs.contains(page.id) && page.phase == .live
    }

    // MARK: Transitions

    func showContent(from old: IslandMode, to new: IslandMode, exit: IslandExit) {
        let t0 = CACurrentMediaTime()
        let ids = pageIDs(for: new)
        isLayingOut = true
        layingOut = Set(ids)
        var incoming: [IslandPage] = []
        for id in ids {
            // A page built ahead that waited too long lost its fresh state (the list's rows cascade only when new); a
            // widget's page built ahead for a tab the pointer rests on keeps longer.
            // The list built ahead stays fresh until shown (`IslandPageModel.revealed`), so it is kept across hovers.
            let fresh = id == .list ? Self.listAheadLifetime : id.isTabContent && state.mode.isOpen ? 2.0 : 0.35
            if let ahead = pages[id], ahead.phase == .building, clock() - ahead.builtAt > IslandChoreography.media(fresh) {
                discard(ahead)
            }
            let page = pages[id] ?? makePage(id)
            let stays = currentIDs.contains(id) && page.phase == .live
            if !stays { page.phase = .building }
            page.view.isHidden = false
            syncModel(page)
            page.host.layoutSubtreeIfNeeded()
            page.receiver?.replay()
            if !stays { incoming.append(page) }
        }
        isLayingOut = false
        layingOut = []
        let t1 = CACurrentMediaTime()
        // Rendered before the clock starts: the first frame of the motion is not spent drawing the new content.
        for page in incoming { page.host.displayIfNeeded() }
        let t2 = CACurrentMediaTime()
        let now = clock()
        transitionNow = now
        for id in currentIDs where !ids.contains(id) {
            if let page = pages[id] { leave(page, exit: exit, at: now) }
        }
        currentIDs = ids
        for page in incoming { reveal(page, entrance: state.entrance, at: now) }
        state.commitPending()
        transitionNow = nil
        let t3 = CACurrentMediaTime()
        CATransaction.flush()
        let t4 = CACurrentMediaTime()
        debug(String(format: "show %@→%@: layout %.1f display %.1f bake %.1f flush %.1f ms (%d new pages)", "\(old)", "\(new)",
                     (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000, (t4 - t3) * 1000, incoming.count))
    }

    /// The page reads the hero and the entrance of what is on screen now (a leaving page keeps its own).
    private func syncModel(_ page: IslandPage) {
        if page.model.paused { page.model.paused = false }
        if page.model.entrance != state.entrance { page.model.entrance = state.entrance }
        if page.model.heroKey != state.heroKey { page.model.heroKey = state.heroKey }
        if page.model.heroFlies != state.heroFlies { page.model.heroFlies = state.heroFlies }
    }

    private func reveal(_ page: IslandPage, entrance: IslandEntrance, at now: CFTimeInterval) {
        page.generation &+= 1
        page.phase = .live
        page.model.revealed = true
        page.revealStart = now
        let e = reduce ? RevealParams.opacityOnly : IslandContentLayerParams.reveal(entrance, page.id.kind)
        page.pose = { t in IslandChoreography.reveal(e, IslandChoreography.local(t, from: now)) }
        bakePose(page, from: now, until: now + IslandChoreography.media(IslandChoreography.revealDuration(e)))
        // Opening: the content comes out of a blur as the shape grows (only for these ~200 ms: a filter costs the render
        // server an offscreen pass per frame).
        if !reduce, entrance == .open, page.id.kind != .closed, !page.id.isCard {
            bakeBlur(page, from: now) { t in IslandChoreography.revealBlur(e, IslandChoreography.local(t, from: now)) }
        } else {
            clearBlur(page)
        }
        cascade(page, start: now, compress: entrance == .morph ? 0.5 : 1)
    }

    /// A Gaussian blur on the page while it comes in or leaves (`layer.filters`, radius keyframed like everything else);
    /// the filter goes once it is over.
    private func bakeBlur(_ page: IslandPage, from now: CFTimeInterval, radius: @escaping (CFTimeInterval) -> Double) {
        // Films draw layers with `render(in:)`, which draws no filters: they skip it.
        guard !timeline.filming, let layer = page.view.layer, let blur = CIFilter(name: "CIGaussianBlur") else { return }
        blur.setValue(0, forKey: kCIInputRadiusKey)
        blur.setValue("blur", forKey: "name")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.filters = [blur]
        CATransaction.commit()
        let end = now + IslandChoreography.media(IslandChoreography.blurDuration)
        timeline.run(layer, "filters.blur.inputRadius", key: "blur", from: now, until: end) { t in
            IslandTimeline.number(radius(t))
        }
        page.blurGeneration &+= 1
        let generation = page.blurGeneration
        later(end - clock() + 0.03) { [weak self, weak page] in
            guard let page, page.blurGeneration == generation else { return }
            self?.clearBlur(page)
        }
    }

    private func clearBlur(_ page: IslandPage) {
        guard let layer = page.view.layer, layer.filters?.isEmpty == false else { return }
        timeline.forget(layer, key: "blur")
        layer.removeAnimation(forKey: "blur")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.filters = nil
        CATransaction.commit()
    }

    private func leave(_ page: IslandPage, exit: IslandExit, at now: CFTimeInterval) {
        let from = page.pose(now)
        page.generation &+= 1
        let generation = page.generation
        page.phase = .leaving
        let reduce = reduce
        page.pose = { t in from.then(IslandChoreography.exit(exit, IslandChoreography.local(t, from: now), reduce: reduce)) }
        let duration = IslandChoreography.media(IslandChoreography.exitDuration(exit, reduce: reduce))
        bakePose(page, from: now, until: now + duration)
        // Closing: it blurs out into the shrinking shape.
        if exit == .collapse, !reduce {
            bakeBlur(page, from: now) { t in IslandChoreography.exitBlur(IslandChoreography.local(t, from: now)) }
        }
        later(duration + 0.03) { [weak self, weak page] in
            guard let self, let page, page.generation == generation, page.phase == .leaving else { return }
            self.retire(page)
        }
    }

    private func retire(_ page: IslandPage) {
        page.cascade.layer?.mask = nil
        if page.id.persists {
            page.phase = .hidden
            page.view.isHidden = true
            page.model.paused = true
        } else {
            discard(page)
        }
    }

    private func discard(_ page: IslandPage) {
        page.view.removeFromSuperview()
        for layer in [page.view.layer, page.shift.layer].compactMap({ $0 }) { timeline.forget(layer) }
        if pages[page.id] === page { pages[page.id] = nil }
    }

    /// Builds the pages of `mode` ahead (the list while the pointer rests on the closed island), so opening it
    /// lays out and draws nothing new: the motion starts at once.
    func prepare(_ mode: IslandMode) {
        // The change that asked for it (the hover grow) goes to the render server first; the building waits a beat.
        CATransaction.flush()
        later(0.03) { [weak self] in self?.buildAhead(mode) }
    }

    /// A tab the pointer rests on in the strip, or the one a sideways swipe heads for: its page is built now (unseen),
    /// so the switch commits without laying anything out.
    func prepareTab(_ mode: IslandMode) {
        guard state.mode.isOpen, mode != state.mode else { return }
        later(0.02) { [weak self] in self?.buildAhead(mode, whileOpen: true) }
    }

    private func buildAhead(_ mode: IslandMode, whileOpen: Bool = false) {
        guard whileOpen ? state.mode.isOpen && state.mode != mode : !state.mode.isOpen else { return }
        var ids = pageIDs(for: mode)
        // Open, only the pages the switch would bring (the strip stays).
        if whileOpen { ids.removeAll { currentIDs.contains($0) } }
        guard !ids.isEmpty, !ids.contains(where: { currentIDs.contains($0) }) else { return }
        for id in ids {
            let keep = whileOpen ? 2.0 : id == .list ? Self.listAheadLifetime : 1.0
            // Built ahead and never shown, it follows the state on its own: a pointer back within `keep` reuses it (no
            // second build, no second stall).
            if let ahead = pages[id], ahead.phase == .building,
               clock() - ahead.builtAt < IslandChoreography.media(id == .list ? keep - 0.5 : 0.2) { continue }
            if let old = pages[id] {
                guard old.phase == .building || old.phase == .hidden else { continue }
                // A kept page (the closed island, the tab strip) is ready as it is.
                if old.phase == .hidden, id.persists { continue }
                discard(old)
            }
            let t0 = CACurrentMediaTime()
            let page = makePage(id)
            page.phase = .building
            page.model.entrance = mode.isOpen && !state.mode.isOpen ? .open : .morph
            page.model.heroKey = IslandViewState.heroKey(for: mode, state.snapshot, reduce: reduce)
            page.model.heroFlies = page.model.heroKey != nil
            let t1 = CACurrentMediaTime()
            page.host.layoutSubtreeIfNeeded()
            debug(String(format: "ahead %@: make %.1f layout %.1f ms", "\(id)", (t1 - t0) * 1000,
                         (CACurrentMediaTime() - t1) * 1000))
            // Not shown within a second (the pointer moved on): it goes.
            later(keep) { [weak self, weak page] in
                guard let self, let page, page.phase == .building, !self.currentIDs.contains(page.id) else { return }
                self.discard(page)
            }
        }
    }

    private func bakePose(_ page: IslandPage, from now: CFTimeInterval, until end: CFTimeInterval) {
        guard let layer = page.view.layer else { return }
        let pose = page.pose
        let anchor = CGPoint(x: canvas.width / 2, y: 0)
        timeline.run(layer, "opacity", from: now, until: end) { t in IslandTimeline.number(pose(t).opacity) }
        timeline.run(layer, "sublayerTransform", from: now, until: end) { t in
            IslandTimeline.transform(pose(t).transform(anchor: anchor))
        }
    }

    // MARK: Section cascade

    /// The page's sections (`.appearAfter`) fade in one after another from `start` (their delays run from there):
    /// a mask over the page whose parts, one per section, fade in on the sections' own curves; the mask goes once
    /// they are all in.
    /// `compress` < 1 brings the sections' delays forward (open → open: the new page is there as the old one goes).
    private func cascade(_ page: IslandPage, start: CFTimeInterval, compress: Double = 1) {
        let all = page.sink.sections.mapValues { section -> IslandSectionSink.Section in
            var section = section
            section.delay *= compress
            return section
        }
        page.sectionStarts = Dictionary(uniqueKeysWithValues: all.keys.map { ($0, start) })
        let running = page.sectionStarts.filter { id, begun in
            guard let section = all[id] else { return false }
            let curve = IslandChoreography.appearCurve(delay: section.delay, curve: section.curve, reduce: reduce)
            return begun + IslandChoreography.media(IslandChoreography.appearDuration(curve)) > start
        }
        page.sectionStarts = running
        guard !running.isEmpty, let cascadeLayer = page.cascade.layer else {
            page.cascade.layer?.mask = nil
            return
        }
        let origin = page.contentOrigin(canvasWidth: canvas.width)
        struct Part {
            let id: UUID
            let rect: CGRect
            let curve: MotionCurve
            let start: CFTimeInterval
        }
        let reduce = reduce
        let parts: [Part] = running.compactMap { id, begun in
            guard let s = all[id], s.rect.width > 0, s.rect.height > 0 else { return nil }
            return Part(id: id, rect: s.rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -0.5, dy: -0.5),
                        curve: IslandChoreography.appearCurve(delay: s.delay, curve: s.curve, reduce: reduce), start: begun)
        }
        guard !parts.isEmpty else {
            page.cascade.layer?.mask = nil
            return
        }
        // Each part's parent is the smallest part that contains it: nested sections (a row's text column) appear
        // inside their parent's fade.
        func contains(_ a: CGRect, _ b: CGRect) -> Bool { a.insetBy(dx: -1, dy: -1).contains(b) && a != b }
        var parent: [Int: Int] = [:]
        for (i, part) in parts.enumerated() {
            var best: Int?
            for (j, other) in parts.enumerated() where i != j && contains(other.rect, part.rect) {
                if best == nil || other.rect.width * other.rect.height < parts[best!].rect.width * parts[best!].rect.height {
                    best = j
                }
            }
            parent[i] = best
        }
        let bounds = page.cascade.bounds.insetBy(dx: -canvas.width, dy: -canvas.height)
        let maskLayer = CALayer()
        maskLayer.frame = page.cascade.bounds
        maskLayer.actions = Self.noActions
        let base = CAShapeLayer()
        base.frame = maskLayer.bounds
        base.actions = Self.noActions
        let union = parts.reduce(CGMutablePath()) { path, part in
            path.addRect(part.rect)
            return path
        }
        base.path = CGPath(rect: bounds, transform: nil).subtracting(union)
        base.fillColor = NSColor.black.cgColor
        maskLayer.addSublayer(base)
        var end = start
        for (i, part) in parts.enumerated() {
            let layer = CAShapeLayer()
            layer.frame = maskLayer.bounds
            layer.actions = Self.noActions
            layer.fillColor = NSColor.black.cgColor
            let children = parts.indices.filter { parent[$0] == i }
            let hole = children.reduce(CGMutablePath()) { path, j in
                path.addRect(parts[j].rect)
                return path
            }
            layer.path = children.isEmpty ? CGPath(rect: part.rect, transform: nil)
                : CGPath(rect: part.rect, transform: nil).subtracting(hole)
            maskLayer.addSublayer(layer)
            var chain: [Part] = [part]
            var k = parent[i]
            while let j = k {
                chain.append(parts[j])
                k = parent[j]
            }
            let stop = chain.map { $0.start + IslandChoreography.media(IslandChoreography.appearDuration($0.curve)) }.max() ?? start
            end = max(end, stop)
            timeline.run(layer, "opacity", from: start, until: stop) { t in
                IslandTimeline.number(chain.reduce(1.0) { value, p in
                    value * IslandChoreography.appearOpacity(p.curve, IslandChoreography.local(t, from: p.start))
                })
            }
        }
        cascadeLayer.mask = maskLayer
        page.cascadeGeneration &+= 1
        let generation = page.cascadeGeneration
        debug("cascade \(page.id) \(parts.count) parts \(parts.map { "\(Int($0.rect.minY))..\(Int($0.rect.maxY)) d\($0.curve.delay)" }) until \(Int((end - start) * 1000)) ms")
        later(end - clock() + 0.05) { [weak self, weak page] in
            guard let page, page.cascadeGeneration == generation else { return }
            self?.debug("cascade \(page.id) done")
            page.cascade.layer?.mask = nil
            page.sectionStarts = [:]
        }
    }

    // MARK: Geometry

    func geometryCommitted(spring: GeoSpring, pulse kind: IslandPulse.Kind?) {
        let now = transitionNow ?? clock()
        debug("commit \(spring.name) mode \(state.mode) target \(state.geometry) heroes \(state.heroes.map(\.rect))")
        if let kind, !reduce { startPulse(kind, at: now) }
        geometry = geometry.retargeted(to: state.geometry.vector, spring: spring.spring, at: now)
        retargetOffset(spring: spring, at: now)
        for id in currentIDs { if let page = pages[id] { syncModel(page) } }
        updateHeroes(at: now)
        rebake(from: now)
        if state.mode == .hidden { scheduleRetracted(from: now) }
        IslandPerf.shared?.motionCommitted()
    }

    func geometryRetargeted(spring: GeoSpring) {
        let now = transitionNow ?? clock()
        debug("retarget \(spring.name) mode \(state.mode) target \(state.geometry) heroes \(state.heroes.map(\.rect))")
        let target = state.geometry.vector
        if target != geometry.to { geometry = geometry.retargeted(to: target, spring: spring.spring, at: now) }
        retargetOffset(spring: spring, at: now)
        for id in currentIDs { if let page = pages[id] { syncModel(page) } }
        updateHeroes(at: now)
        rebake(from: now)
        IslandPerf.shared?.motionCommitted()
    }

    /// Leading and trailing, at most every `heroFollowInterval`: a slot sliding with a SwiftUI animation (a notch wing
    /// coming out) reports every frame, and each retarget re-bakes the surface.
    func heroSlotMoved() {
        guard !heroFollowScheduled else {
            heroFollowPending = true
            return
        }
        state.retarget()
        heroFollowScheduled = true
        later(Self.heroFollowInterval) { [weak self] in
            guard let self else { return }
            self.heroFollowScheduled = false
            if self.heroFollowPending {
                self.heroFollowPending = false
                self.heroSlotMoved()
            }
        }
    }

    static let heroFollowInterval: Double = 1.0 / 15
    /// How long the list built ahead (a hover on the closed island) is kept for the open that may follow.
    static let listAheadLifetime: Double = 4
    private var heroFollowScheduled = false
    private var heroFollowPending = false

    private func retargetOffset(spring: GeoSpring, at now: CFTimeInterval) {
        let offset = Double(IslandLayout.closedContentOffset(mode: state.mode, metrics: state.metrics, geometry: state.geometry))
        guard contentOffset.to != [offset] else { return }
        contentOffset = contentOffset.retargeted(to: [offset], spring: spring.spring, at: now)
    }

    func pressChanged() {
        let now = clock()
        let target: Double = state.pressed && !reduce ? 0.98 : 1
        guard press.to != [target] else { return }
        press = press.retargeted(to: [target], spring: IslandMotion.press.spring, at: now)
        rebake(from: now)
    }

    func pulseFired(_ kind: IslandPulse.Kind) {
        guard !reduce else { return }
        let now = clock()
        startPulse(kind, at: now)
        rebake(from: now)
    }

    private func startPulse(_ kind: IslandPulse.Kind, at now: CFTimeInterval) {
        let keyframes = KeyframeTimeline(initialValue: IslandPulse()) { IslandPulse.keyframes(kind) }
        pulse = PulseTrack(start: now, end: now + keyframes.duration, keyframes: keyframes)
    }

    func shake() {
        guard !reduce, let layer = view.layer else { return }
        let now = clock()
        let keyframes = KeyframeTimeline(initialValue: CGFloat(0)) { ErrorShake.keyframes() }
        timeline.run(layer, "sublayerTransform", key: "shake", from: now, until: now + keyframes.duration) { t in
            IslandTimeline.transform(CATransform3DMakeTranslation(keyframes.value(time: max(0, t - now)), 0, 0))
        }
    }

    func gapChanged() {
        let delta = Double(state.metrics.gap - layoutGap)
        layoutGap = state.metrics.gap
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for page in pages.values { page.layout(in: content.bounds, top: layoutGap) }
        CATransaction.commit()
        // The flying marks sit in the pages' frame: they move with them (and the content's transform), not on their spring.
        for hero in heroes.values {
            hero.track.from[1] += delta
            hero.track.to[1] += delta
        }
    }

    func metricsChanged() {
        layoutGap = state.metrics.gap
        for page in pages.values {
            page.view.removeFromSuperview()
            timeline.forget(page.view.layer!)
        }
        pages = [:]
        currentIDs = []
        for hero in heroes.values { hero.layer.removeFromSuperlayer() }
        heroes = [:]
        pulse = nil
        press = .rest([1])
        contentOffset = .rest([0])
        let now = clock()
        geometry = .rest(state.geometry.vector, at: now)
        lastSize = .zero
        view.needsLayout = true
        rebake(from: now)
    }

    private func scheduleRetracted(from now: CFTimeInterval) {
        // "Logically" retracted once the shape is within half a point of the top edge; gone at its full settle.
        let settle = geometry.settleTime()
        var logical = settle
        var t = now
        while t < settle {
            if abs(geometry.value(at: t)[1] - geometry.to[1]) < 0.5 {
                logical = t
                break
            }
            t += 1.0 / 240
        }
        let generation = state.generation
        later(logical - now) { [weak self] in
            guard let self, self.state.generation == generation, self.state.mode == .hidden else { return }
            self.state.onRetracted()
        }
        later(settle - now + 0.02) { [weak self] in
            guard let self, self.state.generation == generation, self.state.mode == .hidden else { return }
            self.state.onHidden()
        }
    }

    // MARK: Glow

    func glowChanged(retrigger: Bool) {
        let now = clock()
        let presented = (timeline.value(glowLayer, "opacity", at: now) as? NSNumber)?.doubleValue ?? 0
        guard let newGlow = state.glow else {
            guard glow != nil else { return }
            glow = nil
            let fade = MotionCurve.curve(.easeOut, 0.15)
            timeline.run(glowLayer, "opacity", from: now, until: now + IslandChoreography.media(0.15)) { t in
                IslandTimeline.number(presented * (1 - min(max(fade.progress(IslandChoreography.local(t, from: now)), 0), 1)))
            }
            return
        }
        guard retrigger || glow != newGlow else { return }
        glow = newGlow
        let tint = NSColor(newGlow.tint)
        if glowTint != tint || glowLayer.contents == nil {
            glowTint = tint
            timeline.set(glowLayer, "contents", IslandSurfaceImage.glow.tinted(tint))
        }
        let keyframes = KeyframeTimeline(initialValue: presented) { newGlow.keyframes() }
        timeline.run(glowLayer, "opacity", from: now, until: now + keyframes.duration) { t in
            IslandTimeline.number(keyframes.value(time: max(0, t - now)))
        }
    }

    // MARK: Hero

    /// The session whose mark the hero layer draws flies to its slot in the content on screen; one that only appears
    /// fades in place, one that is no longer drawn fades out.
    private func updateHeroes(at now: CFTimeInterval) {
        let subjects = Dictionary(state.heroes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (key, hero) in heroes where subjects[key] == nil && !hero.leaving {
            hero.leaving = true
            fade(hero, appearing: false, at: now)
        }
        for (key, subject) in subjects {
            if let hero = heroes[key], !hero.leaving {
                let target = subject.rect.vector
                if hero.track.to != target {
                    hero.track = hero.track.retargeted(to: target, spring: IslandMotion.hero.spring, at: now)
                }
                hero.flies = subject.flies
            } else {
                heroes[key]?.layer.removeFromSuperlayer()
                let hero = HeroMark(key: key, rect: subject.rect, at: now)
                hero.flies = subject.flies
                heroes[key] = hero
                heroHost.hostedLayer.addSublayer(hero.layer)
                fade(hero, appearing: true, at: now)
            }
        }
        updateHeroMascots()
    }

    func snapshotChanged() {
        updateHeroMascots()
    }

    /// Each flying mascot plays its session's state (a leaving one keeps what it showed); nothing plays while the
    /// panel cannot be seen (ordered out, occluded, the display asleep).
    private func updateHeroMascots() {
        let snapshot = state.snapshot
        let running = !timeline.filming && windowVisible
        for hero in heroes.values {
            let mascot = hero.leaving ? hero.mascot : snapshot.mascot(for: hero.key) ?? hero.mascot
            guard let mascot else { continue }
            hero.show(mascot, fresh: snapshot.mascotIntroIsFresh(for: hero.key), running: running)
            if timeline.filming, hero.filmSince == nil { hero.filmSince = clock() }
        }
    }

    /// Tests: the flying mascot of a session (what it plays) and its layer.
    func hero(_ key: SessionKey) -> (mascot: MascotState?, layer: CALayer)? {
        heroes[key].map { ($0.mascot, $0.layer) }
    }

    /// The panel's window became visible or stopped being visible (`IslandStageView`).
    fileprivate func windowVisibilityChanged(_ visible: Bool) {
        guard visible != windowVisible else { return }
        windowVisible = visible
        updateHeroMascots()
    }

    private func fade(_ hero: HeroMark, appearing: Bool, at now: CFTimeInterval) {
        let from = (timeline.value(hero.layer, "opacity", at: now) as? NSNumber)?.doubleValue ?? (appearing ? 0 : 1)
        let duration = IslandChoreography.media(IslandChoreography.heroFadeDuration)
        timeline.run(hero.layer, "opacity", from: now, until: now + duration) { t in
            IslandTimeline.number(IslandChoreography.heroOpacity(appearing: appearing, from: appearing ? 0 : from,
                                                                  IslandChoreography.local(t, from: now)))
        }
        guard !appearing else { return }
        let key = hero.key
        later(duration + 0.02) { [weak self, weak hero] in
            guard let self, let hero, hero.leaving, self.heroes[key] === hero else { return }
            hero.layer.removeFromSuperlayer()
            self.timeline.forget(hero.layer)
            self.heroes[key] = nil
        }
    }

    // MARK: Baking

    /// Everything that follows the silhouette, baked from `now` until it (and its pulse, the press and the flying
    /// marks) has settled: the shape and the mask, shadow and halo, the content's transform, the notch wings, the
    /// flying marks.
    private func rebake(from now: CFTimeInterval) {
        var end = geometry.settleTime()
        if let pulse { end = max(end, pulse.end) }
        end = max(end, press.settleTime(epsilon: 0.0005))
        end = max(end, contentOffset.settleTime(epsilon: 0.05))
        for hero in heroes.values where !hero.leaving { end = max(end, hero.track.settleTime()) }
        end = max(end, now + 1.0 / 60)
        let motion = SurfaceMotion(geometry: geometry, pulse: pulse, press: press, offset: contentOffset,
                                   canvasWidth: canvas.width, natural: state.contentSize(.closed).width,
                                   fitActive: state.closedFit && !reduce, notch: state.metrics.style == .notch,
                                   pageTop: layoutGap)
        let width = canvas.width
        timeline.run(silhouette, "path", from: now, until: end) { t in motion.path(t) }
        timeline.run(mask, "path", from: now, until: end) { t in motion.path(t) }

        let shadow = IslandSurfaceImage.shadow
        let glowImage = IslandSurfaceImage.glow
        func frame(_ image: IslandSurfaceImage, _ t: CFTimeInterval) -> CGRect {
            let (g, p) = motion.sample(t)
            return image.frame(bodyWidth: g.width - 2 * g.ear, height: g.height + p.dh, top: g.top,
                               detachment: g.detachment, canvasWidth: width)
        }
        timeline.run(shadowLayer, "bounds", from: now, until: end) { t in
            IslandTimeline.rect(CGRect(origin: .zero, size: frame(shadow, t).size))
        }
        timeline.run(shadowLayer, "position", from: now, until: end) { t in
            let r = frame(shadow, t)
            return IslandTimeline.point(CGPoint(x: r.midX, y: r.midY))
        }
        timeline.run(shadowLayer, "opacity", from: now, until: end) { t in
            IslandTimeline.number(min(max(motion.sample(t).0.shadow, 0), 1))
        }
        timeline.run(glowLayer, "bounds", from: now, until: end) { t in
            IslandTimeline.rect(CGRect(origin: .zero, size: frame(glowImage, t).size))
        }
        timeline.run(glowLayer, "position", from: now, until: end) { t in
            let r = frame(glowImage, t)
            return IslandTimeline.point(CGPoint(x: r.midX, y: r.midY))
        }

        // The content: the closed island sits in the middle of a grown silhouette, rides a narrower one, and squishes
        // under the mouse; all about the canvas' top center.
        if let layer = content.layer {
            let anchor = CGPoint(x: width / 2, y: 0)
            timeline.run(layer, "sublayerTransform", key: "group", from: now, until: end) { t in
                IslandTimeline.transform(motion.contentPose(t).transform(anchor: anchor))
            }
        }
        // The notch wings follow the silhouette's edges while it is narrower than them.
        for (id, sign) in [(IslandPageID.closedLeft, CGFloat(1)), (.closedRight, -1)] {
            guard let layer = pages[id]?.shift.layer else { continue }
            timeline.run(layer, "sublayerTransform", key: "wing", from: now, until: end) { t in
                IslandTimeline.transform(CATransform3DMakeTranslation(sign * motion.fit(t).inset, 0, 0))
            }
        }
        // The flying marks: their spring, held inside the silhouette's body on the way.
        for hero in heroes.values {
            let track = hero.track
            let flies = hero.flies
            timeline.run(hero.layer, "position", from: now, until: end) { t in
                let rect = CGRect(vector: track.value(at: t))
                let fit = motion.fit(t)
                let x = HeroPlacement.center(rect, midX: width / 2, inset: fit.inset, room: flies ? fit.room : nil)
                return IslandTimeline.point(CGPoint(x: x, y: rect.midY))
            }
            timeline.run(hero.layer, "bounds", from: now, until: end) { t in
                IslandTimeline.rect(CGRect(origin: .zero, size: CGRect(vector: track.value(at: t)).size))
            }
        }
        // Effects that follow the shape bake their own tracks from the same motion.
        if !followers.isEmpty {
            let silhouette = IslandSilhouetteMotion(canvasWidth: width, target: state.geometry,
                                                   sample: { t in motion.sample(t) })
            for follower in followers { follower.follow(silhouette, timeline: timeline, from: now, until: end) }
        }
        IslandPerf.note("rebake")
    }

    // MARK: Film renders

    nonisolated static let debugging = ProcessInfo.processInfo.environment["NOTCHBUDDY_STAGE_DEBUG"] == "1"
    var debugOrigin: CFTimeInterval = 0

    func debug(_ text: @autoclosure () -> String) {
        guard Self.debugging else { return }
        print(String(format: "[stage %+.0f ms] ", (clock() - debugOrigin) * 1000) + text())
    }

    /// Every layer shows its value at media time `t` (film mode only).
    func apply(at t: CFTimeInterval) {
        timeline.apply(at: t)
        // The flying mascots' sprite frames are not baked tracks: a film steps them itself.
        if timeline.filming { for hero in heroes.values { hero.filmFrame(at: t) } }
    }

    /// Adds an effect that follows the silhouette for as long as it stays (an attention rim, a permission aura): it gets
    /// a layer of its own in `placement`, and on every change of the shape the motion to bake.
    func addFollower(_ follower: IslandSilhouetteFollower) {
        guard !followers.contains(where: { $0 === follower }) else { return }
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: canvas)
        container.actions = Self.noActions
        effectsLayer(follower.placement).addSublayer(container)
        followers.append(follower)
        followerLayers[ObjectIdentifier(follower)] = container
        follower.attach(to: container)
        let now = clock()
        rebake(from: now)
    }

    func removeFollower(_ follower: IslandSilhouetteFollower) {
        followers.removeAll { $0 === follower }
        followerLayers.removeValue(forKey: ObjectIdentifier(follower))?.removeFromSuperlayer()
        follower.detach()
    }

    /// The geometry the render server shows at media time `t`.
    func presentedGeometry(at t: CFTimeInterval) -> IslandGeometry { IslandGeometry(vector: geometry.value(at: t)) }

    /// The layer that effects of `placement` go into (see `IslandEffect`).
    func effectsLayer(_ placement: IslandEffectPlacement) -> CALayer {
        switch placement {
        case .behind: return behindLayer
        case .inside: return insideHost.hostedLayer
        case .above: return aboveHost.hostedLayer
        }
    }
}

extension IslandPageID {
    var isCard: Bool {
        if case .card = self { return true }
        return false
    }

    /// The content of a tab (the list, a widget's page): it goes under the tab strip.
    var isTabContent: Bool {
        switch self {
        case .list: return true
        case .custom(let id): return WidgetKind(pageID: id) != nil
        default: return false
        }
    }
}

/// A keyframed pulse of the silhouette (`IslandPulse`) from `start`.
struct PulseTrack {
    let start: CFTimeInterval
    let end: CFTimeInterval
    let keyframes: KeyframeTimeline<IslandPulse>

    func value(at t: CFTimeInterval) -> IslandPulse {
        guard t >= start, t <= end else { return IslandPulse() }
        return keyframes.value(time: t - start)
    }
}

/// Everything the surface's tracks sample, copied at bake time (the tracks outlive the moment; they never read
/// the stage).
private struct SurfaceMotion {
    let geometry: SpringTrack
    let pulse: PulseTrack?
    let press: SpringTrack
    let offset: SpringTrack
    let canvasWidth: CGFloat
    let natural: CGFloat
    let fitActive: Bool
    let notch: Bool
    /// Where the pages are laid out («Островок»: its gap below the top edge); the shape's own `top` may be on its way.
    let pageTop: CGFloat

    func sample(_ t: CFTimeInterval) -> (IslandGeometry, IslandPulse) {
        var g = IslandGeometry(vector: geometry.value(at: t))
        g.shadow = min(max(g.shadow, 0), 1)
        return (g, pulse?.value(at: t) ?? IslandPulse())
    }

    func path(_ t: CFTimeInterval) -> CGPath {
        let (g, p) = sample(t)
        return IslandPathBuilder.path(g, pulse: p, canvasWidth: canvasWidth)
    }

    func fit(_ t: CFTimeInterval) -> IslandClosedFit {
        let g = sample(t).0
        return IslandClosedFit.at(bodyWidth: g.width - 2 * g.ear, natural: natural, active: fitActive, notch: notch)
    }

    /// The content's pose: fit (inside), then the closed island's offset in a grown silhouette, then the press, then
    /// along with the shape's top while it moves between the styles (the pages sit at `pageTop`).
    func contentPose(_ t: CFTimeInterval) -> IslandPose {
        let dy = CGFloat(offset.value(at: t)[0])
        let squish = CGFloat(press.value(at: t)[0])
        let top = max(0, sample(t).0.top)
        return IslandPose(scale: fit(t).scale).then(IslandPose(dy: dy)).then(IslandPose(scale: squish))
            .then(IslandPose(dy: top - pageTop))
    }
}

// MARK: - Hero mark

/// The flying agent mascot: a layer showing the agent's pixel mascot (`MascotAnimator`: its sprite strip as contents,
/// the frames stepped by the render server), on a spring of its own (`IslandMotion.hero`). Its slots report crisp
/// squares (`HeroSlot.sprite(in:scale:)`), so at rest every art pixel is whole device pixels.
@MainActor
final class HeroMark {
    let key: SessionKey
    let layer = CALayer()
    var track: SpringTrack
    var flies = false
    var leaving = false
    private(set) var mascot: MascotState?
    private var running = false
    /// Films: when the shown state began (media time) and whether it opened with its intro (`filmFrame(at:)`).
    var filmSince: CFTimeInterval?
    private var filmIntro = false

    init(key: SessionKey, rect: CGRect, at now: CFTimeInterval) {
        self.key = key
        track = .rest(rect.vector, at: now)
        MascotAnimator.prepare(layer)
        layer.actions = IslandStage.noActions
        layer.opacity = 0
        layer.bounds = CGRect(origin: .zero, size: rect.size)
        layer.position = CGPoint(x: rect.midX, y: rect.midY)
    }

    /// Plays `state` (a change of state plays its intro; the first one only when `fresh`), or holds its still frame
    /// while not `running`.
    func show(_ state: MascotState, fresh: Bool, running: Bool) {
        let changed = state != mascot
        guard changed || running != self.running else { return }
        let first = mascot == nil
        mascot = state
        self.running = running
        let intro = changed && (first ? fresh : true)
        if changed {
            filmSince = nil
            filmIntro = intro
        }
        MascotAnimator.show(MascotSpriteSheet.shared(MascotCharacter(agent: key.source)), state, on: layer,
                            running: running, intro: intro)
    }

    /// Films: shows the sprite frame of media time `t` (the render server plays them live).
    func filmFrame(at t: CFTimeInterval) {
        guard let mascot, let since = filmSince else { return }
        let sheet = MascotSpriteSheet.shared(MascotCharacter(agent: key.source))
        guard let timeline = sheet.timelines[mascot] else { return }
        let time = t - since + (filmIntro ? 0 : timeline.introDuration)
        let rect = sheet.contentsRect(timeline.frame(at: time))
        guard layer.contentsRect != rect else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsRect = rect
        CATransaction.commit()
    }
}

// MARK: - Receiving measurements

/// A page's measurements reach the state only while that page is the one on screen (a leaving page, a notch wing's
/// twin and the card chrome only draw).
@MainActor
final class IslandPageReceiver: IslandContentReceiver {
    weak var stage: IslandStage?
    weak var page: IslandPage?
    /// The page's latest measurements (a page built ahead, or shown again, reports nothing new: these are replayed).
    private var size: (IslandContentKind, CGSize)?
    private var slots: [HeroSlotID: CGRect] = [:]

    func contentMeasured(_ kind: IslandContentKind, _ size: CGSize) {
        guard let stage, let page else { return }
        page.contentSize = CGSize(width: size.width.rounded(), height: size.height.rounded())
        self.size = (kind, size)
        guard stage.counts(page) else { return }
        stage.state.contentMeasured(kind, size)
    }

    func heroSlotMeasured(_ id: HeroSlotID, _ rect: CGRect) {
        slots[id] = rect
        if slots.count > 32 { slots = [id: rect] }
        guard let stage, let page, stage.counts(page) else { return }
        stage.state.heroSlotMeasured(id, rect)
    }

    func usageRingMeasured(_ rect: CGRect?) {
        guard let stage, let page, page.id == .closed || page.id == .closedLeft else { return }
        stage.state.usageRingMeasured(rect)
    }

    /// Hands the page's latest measurements to the state again.
    func replay() {
        guard let stage, let page, stage.counts(page) else { return }
        if let (kind, size) = size { stage.state.contentMeasured(kind, size) }
        for (id, rect) in slots { stage.state.heroSlotMeasured(id, rect) }
    }
}

// MARK: - Stage view

/// The panel's island view: lays out the stage and takes the closed island's clicks (a press squishes it, a click
/// opens the list, not pinned); open content takes its own (each page once it is in and interactive).
final class IslandStageView: IslandFlippedView {
    weak var stage: IslandStage?
    var onLayout: () -> Void = {}
    private var downAt: NSPoint?

    private var occlusionObserver: NSObjectProtocol?

    override func layout() {
        super.layout()
        onLayout()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The flying mascot pauses while the panel cannot be seen (the pages' own mascots watch for themselves).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibilityChanged() }
            }
        }
        visibilityChanged()
    }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    private func visibilityChanged() {
        stage?.windowVisibilityChanged(window.map { $0.occlusionState.contains(.visible) } ?? false)
    }

    private var closed: Bool {
        guard let state = stage?.state else { return false }
        return !state.mode.isOpen && state.mode != .hidden
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let stage, !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // The panel takes the mouse only over the island itself (`IslandController`), so any point that reaches
        // here is on it.
        if closed { return self }
        if let hit = super.hitTest(point) { return hit }
        return stage.state.mode.isOpen ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard closed, let state = stage?.state else { return }
        downAt = event.locationInWindow
        state.actions.pressClosedIsland(true)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = downAt, let state = stage?.state else { return }
        downAt = nil
        let p = event.locationInWindow
        if hypot(p.x - start.x, p.y - start.y) < 8, closed {
            if onUsageRing(convert(p, from: nil), state: state) {
                // The usage ring switches whose limits it shows (Авто → Claude → Codex → Kimi); the island stays closed.
                state.actions.pressClosedIsland(false)
                state.actions.cycleUsage()
            } else {
                state.actions.tappedClosedIsland()
            }
        } else {
            state.actions.pressClosedIsland(false)
        }
    }

    /// Whether `point` (this view's coordinates) is on the closed island's usage ring, a few points around it included.
    private func onUsageRing(_ point: NSPoint, state: IslandViewState) -> Bool {
        guard let ring = state.closedRingRect, ring.width > 0 else { return false }
        let content = state.contentSize(.closed)
        let origin = CGPoint(x: (bounds.width - content.width) / 2, y: state.metrics.gap)
        return ring.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -7, dy: -8).contains(point)
    }
}

extension IslandStage {
    /// The Core Animation stage draws the island unless `NOTCHBUDDY_SWIFTUI_ISLAND=1` asks for the SwiftUI one
    /// (`IslandRootView`, kept for comparison).
    nonisolated static let enabled = ProcessInfo.processInfo.environment["NOTCHBUDDY_SWIFTUI_ISLAND"] != "1"
}
