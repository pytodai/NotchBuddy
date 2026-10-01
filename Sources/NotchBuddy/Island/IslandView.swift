import SwiftUI
import NotchBuddyCore

/// Root of the panel's hosting view. The panel is a fixed canvas (see `IslandLayout.canvasSize`); the
/// island hangs from its top center and never makes the panel resize.
struct IslandRootView: View {
    let state: IslandViewState

    var body: some View {
        IslandView(state: state)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .environment(\.colorScheme, .dark)
            .environment(state.clock)
            .environment(\.islandReduceMotion, state.reduceMotion)
    }
}

/// The black island.
///
/// Layers, all on the fixed canvas and centered on its top edge:
/// - `IslandSurface`: the black `IslandSilhouette` (the only thing whose size animates: one spring per
///   change, growing down and sideways from the top edge) with a constant-radius shadow and an optional
///   tinted glow (a pre-rendered image stretched to the shape, so a moving shape redraws no second blur);
/// - the content of the current mode at its natural size, and the hero layer (the agent mark that flies
///   between the closed island, the list and the card), both masked by the same silhouette; while the
///   silhouette is narrower than the closed island's content (growing out of the top edge or the notch,
///   retracting into it) that content rides the shape (`ClosedContentFit`), so its edges show as soon as
///   the shape does;
/// - on the closed island, a press area: the island squishes under the mouse and opens on click (not pinned).
/// Pulses (ear flare, latch, gulp) are keyframed on top of the spring; the error shake moves everything.
struct IslandView: View {
    let state: IslandViewState

    var body: some View {
        IslandBody(state: state)
            .keyframeAnimator(initialValue: IslandPulse(), trigger: state.pulseTick) { content, pulse in
                content.environment(\.islandPulse, pulse)
            } keyframes: { _ in
                IslandPulse.keyframes(state.pulseKind)
            }
            .keyframeAnimator(initialValue: CGFloat(0), trigger: state.errorShake) { content, x in
                content.offset(x: x)
            } keyframes: { _ in
                ErrorShake.keyframes()
            }
    }
}

private struct IslandBody: View {
    let state: IslandViewState
    @Environment(\.islandPulse) private var pulse

    var body: some View {
        let g = state.geometry
        ZStack(alignment: .top) {
            IslandSurface(g: g, pulse: pulse, glow: state.glow, glowTick: state.glowTick)
            IslandPressArea(state: state)
            ZStack(alignment: .top) {
                IslandInteractionGate(state: state) { IslandContentLayer(state: state) }
                IslandHeroLayer(heroes: state.heroes, midX: IslandLayout.canvasSize(state.metrics).width / 2,
                                mascots: state.snapshot.heroMascots(state.heroes))
            }
            // Reduce Motion: no zoom of the row, no slide of the notch wings (they fade in as the silhouette
            // uncovers them) and no squish.
            .modifier(ClosedContentFit(width: g.width - 2 * g.ear, natural: state.contentSize(.closed).width,
                                       active: state.closedFit && !state.reduceMotion, notch: state.metrics.style == .notch))
            .offset(y: IslandLayout.closedContentOffset(mode: state.mode, metrics: state.metrics, geometry: g))
            .scaleEffect(state.pressed && !state.reduceMotion ? 0.98 : 1, anchor: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .mask(alignment: .top) {
                IslandSilhouette(g: g, pulse: pulse).fill(Color.black)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Surface

/// The black silhouette with its ambient shadow (constant radius; only its opacity follows the
/// geometry) and, for a notice or a card, a tinted halo that peaks and settles.
struct IslandSurface: View {
    let g: IslandGeometry
    let pulse: IslandPulse
    let glow: IslandGlow?
    var glowTick = 0
    /// Filmstrips and previews: the glow's level at the filmed moment.
    var glowLevel: Double?

    var body: some View {
        ZStack(alignment: .top) {
            if let glow {
                IslandGlowHalo(g: g, pulse: pulse, glow: glow, tick: glowTick, level: glowLevel)
                    .transition(.opacity.animation(.easeOut(duration: 0.15).speed(IslandMotion.speed)))
            }
            IslandSilhouette(g: g, pulse: pulse)
                .fill(Color.black)
                .shadow(color: .black.opacity(g.shadow), radius: 22, y: 10)
        }
        .allowsHitTesting(false)
    }
}

/// The tinted halo: a glow pre-rendered once (`GlowImage`) and stretched to the silhouette's body as it
/// moves. Only its opacity is keyframed (it peaks and settles).
private struct IslandGlowHalo: View {
    let g: IslandGeometry
    let pulse: IslandPulse
    let glow: IslandGlow
    let tick: Int
    let level: Double?
    @Environment(\.islandStaticRender) private var staticRender
    @State private var localTick = 0

    var body: some View {
        let halo = GlowSlice(g: g, pulse: pulse).foregroundStyle(glow.tint)
        if let level {
            halo.opacity(level)
        } else if staticRender {
            halo.opacity(glow.rest)
        } else {
            halo
                .keyframeAnimator(initialValue: 0.0, trigger: localTick) { view, level in
                    view.opacity(level)
                } keyframes: { _ in
                    glow.keyframes()
                }
                .onAppear { localTick &+= 1 }
                .onChange(of: tick) { localTick &+= 1 }
        }
    }
}

/// A glow around the silhouette's body, as `.shadow(radius: 18, y: 4)` of it would draw it, but from a
/// pre-rendered nine-slice image: the corners stay as rendered, the edges stretch. Its flat top (and the
/// dimming of the glow near it) sits above the canvas: the island continues behind the top edge.
private struct GlowSlice: View {
    let g: IslandGeometry
    let pulse: IslandPulse

    var body: some View {
        let pad = GlowImage.pad, dy = GlowImage.dy
        let width = max(0, g.width - 2 * g.ear)
        let height = max(0, g.height + pulse.dh)
        Image(decorative: GlowImage.image, scale: GlowImage.scale)
            .resizable(capInsets: GlowImage.caps, resizingMode: .stretch)
            .renderingMode(.template)
            .frame(width: width + 2 * pad, height: height + dy + 3 * pad)
            .offset(y: -2 * pad)
    }
}

/// The glow's source: the shadow alone (not the shape casting it) of a white rectangle with rounded
/// bottom corners, rendered once. Under the silhouette it is covered; where the offset glow peeks out
/// below the silhouette it continues without a seam. `caps` keep every non-uniform part of the shadow
/// out of the stretched middle: the top cap holds the dimming below the flat top, the bottom and side
/// caps hold the corners.
@MainActor
enum GlowImage {
    static let radius: CGFloat = 18
    static let dy: CGFloat = 4
    /// Room for the shadow around the shape (it fades out within ~2 radii).
    static let pad: CGFloat = (radius * 2.2).rounded(.up)
    static let corner = IslandLayout.openBottom
    static let scale: CGFloat = 2
    private static let side = 2 * (2 * pad + corner) + 8

    static let caps = EdgeInsets(top: 2 * pad, leading: 2 * pad + corner, bottom: 2 * pad + corner,
                                 trailing: 2 * pad + corner)

    static let image: CGImage = {
        // The shape is moved out of the rendered area; its shadow is moved back into it.
        let away: CGFloat = 8 * (side + 2 * pad)
        // Round all around (the top corners stay above the canvas unless the island is detached, «Островок»).
        let view = RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Color.white)
            .frame(width: side, height: side)
            .offset(x: away)
            .shadow(color: .white, radius: radius, x: -away, y: 0)
            .padding(pad)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        if let image = renderer.cgImage { return image }
        // Never expected; a transparent pixel keeps the island drawing.
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()
}

// MARK: - Press

/// The closed island's click target (its silhouette): squishes while the mouse is down, opens the list
/// on click (not pinned). Open content handles its own clicks.
private struct IslandPressArea: View {
    let state: IslandViewState

    var body: some View {
        let closed = !state.mode.isOpen && state.mode != .hidden
        Color.clear
            .contentShape(IslandSilhouette(g: state.geometry))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in state.actions.pressClosedIsland(true) }
                    .onEnded { value in
                        let moved = hypot(value.translation.width, value.translation.height)
                        if moved < 8 {
                            state.actions.tappedClosedIsland()
                        } else {
                            state.actions.pressClosedIsland(false)
                        }
                    }
            )
            .allowsHitTesting(closed)
    }
}

// MARK: - Content

/// Incoming open content takes clicks only after `IslandMotion.interactiveDelay`. The flag is read here
/// alone, so its flip mid-open re-renders nothing else.
private struct IslandInteractionGate<Content: View>: View {
    let state: IslandViewState
    @ViewBuilder let content: Content

    var body: some View {
        content.allowsHitTesting(state.contentInteractive)
    }
}

private struct IslandContentLayer: View {
    let state: IslandViewState

    var body: some View {
        let mode = state.mode
        let metrics = state.metrics
        let snapshot = state.snapshot
        let entrance = state.entrance
        let reduce = state.reduceMotion
        let actions = state.actions
        ZStack(alignment: .top) {
            if mode != .hidden {
                switch mode.content {
                case .closed:
                    CollapsedIslandView(snapshot: snapshot, metrics: metrics)
                        .islandContentRoot(.closed, state: state)
                        .allowsHitTesting(false)
                        .transition(.island(Self.reveal(entrance, .closed, reduce), exit: .out, reduce: reduce))
                case .expanded:
                    ExpandedIslandView(snapshot: snapshot, metrics: metrics,
                                       width: IslandLayout.listWidth(metrics),
                                       pinned: state.pinned, pinBounce: state.pinBounce,
                                       hoveredRowKey: state.hoveredRowKey, rowRemoval: state.rowRemoval,
                                       raisedRows: state.raisedRows, actions: actions)
                        .islandContentRoot(.expanded, state: state)
                        .transition(.island(Self.reveal(entrance, .expanded, reduce), exit: .out, reduce: reduce))
                case .permission:
                    if let card = snapshot.card {
                        // Only the request swaps when the front card changes (sent up, the next one rises);
                        // the queue chrome around it stays, so its dots and "1 из N" animate in place.
                        ZStack(alignment: .top) {
                            PermissionCardView(
                                card: card,
                                total: snapshot.cardCount,
                                queue: snapshot.cardIDs,
                                metrics: metrics,
                                width: IslandLayout.cardWidth(metrics),
                                armed: state.armedCardID == card.id,
                                presentedAt: state.cardPresentedAt,
                                keyboardActive: state.keyboardActive,
                                // Bound to this card's id: the controller drops it unless this card is still in front.
                                decide: { decision in actions.decide(card.id, decision) }
                            )
                            .equatable()
                            .islandContentRoot(.permission, state: state)
                            .id(card.id)
                            .transition(.island(Self.reveal(entrance, .permission, reduce), exit: .sent, reduce: reduce))
                        }
                        .overlay(alignment: .top) {
                            PermissionQueueChrome(queue: snapshot.cardIDs, total: snapshot.cardCount, metrics: metrics,
                                                  width: IslandLayout.cardWidth(metrics))
                        }
                        .transition(.island(Self.reveal(entrance, .permission, reduce), exit: .sent, reduce: reduce))
                    }
                case .flash:
                    if let notice = snapshot.flash {
                        FlashView(notice: notice, session: snapshot.session(notice.key),
                                  duration: snapshot.flashDuration, quiet: snapshot.flashQuiet,
                                  metrics: metrics, width: IslandLayout.flashWidth(metrics)) {
                            actions.tapFlash(notice)
                        }
                        .islandContentRoot(.flash, state: state)
                        .id(notice.id)
                        .transition(.island(Self.reveal(entrance, .flash, reduce), exit: .swap, reduce: reduce))
                    }
                case .page(let id):
                    if let spec = IslandPages.spec(id) {
                        spec.content(IslandPageContext(state: state, width: spec.width(metrics)))
                            .islandContentRoot(.page(id), state: state)
                            .id(id)
                            .transition(.island(Self.reveal(entrance, .page(id), reduce), exit: .out, reduce: reduce))
                    }
                }
            }
        }
        .environment(\.islandEntrance, entrance)
        .environment(\.islandHeroKey, state.heroKey)
        .environment(\.islandHeroFlies, state.heroFlies)
        .allowsHitTesting(state.contentInteractive)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// The list and the card do not blur as a whole: their rows and sections blur on their own.
    static func reveal(_ entrance: IslandEntrance, _ kind: IslandContentKind, _ reduce: Bool) -> RevealParams {
        reduce ? .opacityOnly : IslandContentLayerParams.reveal(entrance, kind)
    }
}

extension View {
    /// A content view at its natural size that reports its size and its hero slots to `receiver`.
    func islandContentRoot(_ kind: IslandContentKind, state receiver: IslandContentReceiver) -> some View {
        self
            .fixedSize()
            .environment(\.islandContentKind, kind)
            .environment(\.islandHeroSink, HeroSink(receiver: receiver))
            .coordinateSpace(.named(IslandContentSpace.name))
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                receiver.contentMeasured(kind, size)
            }
            .geometryGroup()
    }
}

enum IslandContentSpace {
    static let name = "islandContent"
}

/// Receives content sizes and hero slot rects (the live state, or a preview's measuring box).
@MainActor
protocol IslandContentReceiver: AnyObject {
    func contentMeasured(_ kind: IslandContentKind, _ size: CGSize)
    func heroSlotMeasured(_ id: HeroSlotID, _ rect: CGRect)
    /// Where the closed island's usage ring is (content coordinates; nil: none shown). A click there switches agent.
    func usageRingMeasured(_ rect: CGRect?)
}

extension IslandContentReceiver {
    func usageRingMeasured(_ rect: CGRect?) {}
}

extension IslandViewState: IslandContentReceiver {
    func usageRingMeasured(_ rect: CGRect?) {
        if closedRingRect != rect { closedRingRect = rect }
    }
}

/// Reports the closed island's usage ring to the stage (a click on it switches whose limits it shows).
struct UsageRingSlot: ViewModifier {
    @Environment(\.islandHeroSink) private var sink

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(IslandContentSpace.name))
            } action: { rect in
                sink.receiver?.usageRingMeasured(rect)
            }
            .onDisappear { sink.receiver?.usageRingMeasured(nil) }
    }
}

struct HeroSink {
    weak var receiver: IslandContentReceiver?
}

private struct IslandContentKindKey: EnvironmentKey { static let defaultValue = IslandContentKind.closed }
private struct IslandHeroSinkKey: EnvironmentKey { static let defaultValue = HeroSink() }

extension EnvironmentValues {
    var islandContentKind: IslandContentKind {
        get { self[IslandContentKindKey.self] }
        set { self[IslandContentKindKey.self] = newValue }
    }

    var islandHeroSink: HeroSink {
        get { self[IslandHeroSinkKey.self] }
        set { self[IslandHeroSinkKey.self] = newValue }
    }
}

// MARK: - Hero

/// A content view's agent mascot (`PixelMascotView`: the agent's pixel character, animated for `mascot`). While its
/// session is the hero, the mascot is drawn by the hero layer (flying between the closed island, the list's first
/// row and the card header) and this slot stays empty; it only reports where the mascot belongs: the square the
/// sprite is drawn in (a whole number of device pixels per art pixel, `PixelMascotLayer.crispSide`), so a flying
/// mascot lands exactly where the slot's own would be, just as crisp.
struct HeroSlot: View {
    let key: SessionKey
    let size: CGFloat
    var mascot: MascotState = .idle
    /// The state began a moment ago: the mascot plays its intro (done's jump, error's fall) when it appears.
    var introOnAppear = true
    @Environment(\.islandHeroKey) private var heroKey
    @Environment(\.islandHeroSink) private var sink
    @Environment(\.islandContentKind) private var kind
    @Environment(\.displayScale) private var displayScale

    init(key: SessionKey, size: CGFloat, mascot: MascotState = .idle, introOnAppear: Bool = true) {
        self.key = key
        self.size = size
        self.mascot = mascot
        self.introOnAppear = introOnAppear
    }

    /// The session's own mascot: its status (`MascotState(session:)`), its intro only if the status is new.
    init(session: AgentSession, size: CGFloat) {
        self.init(key: session.key, size: size, mascot: MascotState(session: session),
                  introOnAppear: session.mascotIntroIsFresh())
    }

    var body: some View {
        ZStack {
            if heroKey != key {
                IslandMascot(source: key.source, state: mascot, size: size, introOnAppear: introOnAppear)
            }
        }
        .frame(width: size, height: size)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(IslandContentSpace.name))
        } action: { rect in
            sink.receiver?.heroSlotMeasured(HeroSlotID(kind: kind, key: key), Self.sprite(in: rect, scale: displayScale))
        }
    }

    /// The square the mascot's sprite takes in a slot: centered, crisp, on whole device pixels.
    static func sprite(in rect: CGRect, scale: CGFloat) -> CGRect {
        let scale = max(scale, 1)
        let side = PixelMascotLayer.crispSide(min(rect.width, rect.height), scale: scale)
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        return CGRect(x: snap(rect.midX - side / 2), y: snap(rect.midY - side / 2), width: side, height: side)
    }
}

/// Draws the hero agent mark at its slot. It flies on `IslandMotion.hero`, committed with the geometry but
/// quicker, so it lands before the text beside it; with nowhere to fly from it fades in place.
struct IslandHeroLayer: View {
    let heroes: [HeroSubject]
    /// The canvas' center: a mark left of it sits in the notch's left wing (see `islandClosedInset`).
    var midX: CGFloat = 0
    /// Filmstrips: opacity per hero (live, insertions and removals fade on their own).
    var opacity: [SessionKey: Double] = [:]
    /// Each hero's mascot state (its session's, `MascotState(session:)`).
    var mascots: [SessionKey: MascotState] = [:]

    static let drawSize: CGFloat = 34

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(heroes) { hero in
                PixelMascotImage(character: MascotCharacter(agent: hero.source), state: mascots[hero.id] ?? .idle,
                                 size: Self.drawSize)
                    .modifier(HeroPlacement(rect: hero.rect, midX: midX, holdsInside: hero.flies))
                    .opacity(opacity[hero.id] ?? 1)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(IslandMotion.heroIn.animation),
                        removal: .opacity.animation(IslandMotion.exitOut.animation)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// A hero mark at its rect (animated on the hero spring), beside a notch pulled in with the closed
/// island's wings (`islandClosedInset`). A flying mark never leaves the silhouette's body
/// (`islandHeroRoom`, animated with the silhouette): out of the closed island (most of all beside a
/// notch) it would outrun the growing edge and be cut by it, so it is held just inside the edge
/// instead, eased onto it rather than stopped, and lands as the edge passes its slot. A flight that
/// stays clear of the edge is not touched.
struct HeroPlacement: ViewModifier, Animatable {
    var rect: CGRect
    let midX: CGFloat
    /// A flying mark (`HeroSubject.flies`); one that appeared in place is uncovered by the silhouette.
    var holdsInside = true
    @Environment(\.islandClosedInset) private var inset
    @Environment(\.islandHeroRoom) private var room

    var animatableData: CGRect.AnimatableData {
        get { rect.animatableData }
        set { rect.animatableData = newValue }
    }

    /// The mark keeps at least this far inside the edge.
    static let margin: CGFloat = 1.5
    /// The hold eases in over this distance: a mark more than `margin + softness / 2` inside is not moved.
    static let softness: CGFloat = 4

    func body(content: Content) -> some View {
        let x = Self.center(rect, midX: midX, inset: inset, room: holdsInside ? room : nil)
        content
            .scaleEffect(rect.width / IslandHeroLayer.drawSize)
            .position(x: x, y: rect.midY)
    }

    /// The mark's center: its slot's, moved with the wings, then kept inside a body `2 × room` wide.
    static func center(_ rect: CGRect, midX: CGFloat, inset: CGFloat, room: CGFloat?) -> CGFloat {
        let x = rect.midX + (rect.midX < midX ? inset : -inset)
        guard let room else { return x }
        let lo = midX - room + margin + rect.width / 2
        let hi = midX + room - margin - rect.width / 2
        guard lo <= hi else { return x }
        return -hold(-hold(x, above: lo), above: -hi)
    }

    /// `x` where it is `softness / 2` or more above `floor`; below that it eases (continuous in value and
    /// speed) onto `floor`, which it never passes.
    private static func hold(_ x: CGFloat, above floor: CGFloat) -> CGFloat {
        let knee = floor + softness / 2
        guard x < knee else { return x }
        let d = max(x - (knee - softness), 0)
        return floor + d * d / (2 * softness)
    }
}

private struct IslandHeroRoomKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }

extension EnvironmentValues {
    /// Half the width of the silhouette's body (without the ears) at this moment, in the coordinates of the
    /// content and the hero layer (`ClosedContentFit` sets it); nil where there is no silhouette.
    var islandHeroRoom: CGFloat? {
        get { self[IslandHeroRoomKey.self] }
        set { self[IslandHeroRoomKey.self] = newValue }
    }
}

// MARK: - Closed content on a growing shape

/// Closed content rides the silhouette while the shape is narrower than it: growing out of the top edge
/// (no notch) the whole row scales with the shape from its top center; beside a notch the wings slide
/// out from behind the camera housing with the shape's edges (`islandClosedInset`), at full size. So
/// the agent mark and the usage ring show as soon as the shape does, not once it has widened.
///
/// Only after a content swap (`IslandViewState.closedFit`): when data changes the row's width, the row
/// lays itself out with the same spring as the shape and needs no help.
///
/// It also tells the hero layer how wide the silhouette's body is at this moment (`islandHeroRoom`, in the
/// content's own coordinates), in every mode: the flying mark stays inside it.
struct ClosedContentFit: ViewModifier, Animatable {
    /// The silhouette's body (its width without the ears), animated with it.
    var width: CGFloat
    /// The closed content's natural width.
    let natural: CGFloat
    let active: Bool
    let notch: Bool

    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }

    func body(content: Content) -> some View {
        let short = active && natural > 1 ? min(max(natural - width, 0), natural) : 0
        let scale = notch ? 1 : max(0.3, 1 - short / max(natural, 1))
        content
            .environment(\.islandClosedInset, notch ? short / 2 : 0)
            .environment(\.islandHeroRoom, width / 2 / scale)
            .scaleEffect(scale, anchor: .top)
    }
}

private struct IslandClosedInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    /// Beside a notch: how far each wing of the closed island is pulled in toward the camera housing,
    /// so it stays at the edge of a silhouette that is still narrower than the content.
    var islandClosedInset: CGFloat {
        get { self[IslandClosedInsetKey.self] }
        set { self[IslandClosedInsetKey.self] = newValue }
    }
}

/// A notch wing that follows the silhouette's edge (`ClosedContentFit`); `sign` +1 on the left wing.
struct NotchWingInset: ViewModifier {
    let sign: CGFloat
    @Environment(\.islandClosedInset) private var inset

    func body(content: Content) -> some View {
        content.offset(x: sign * inset)
    }
}
