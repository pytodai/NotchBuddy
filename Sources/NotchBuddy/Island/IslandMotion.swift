import SwiftUI
import NotchBuddyCore

// MARK: - Curves

/// A motion curve that drives a live SwiftUI animation and can be sampled at any time, so the preview
/// filmstrips (`IslandPreviews`) draw in-between frames with exactly the interpolation the island uses.
struct MotionCurve: Equatable {
    enum Kind: Equatable {
        case spring(Spring)
        case curve(UnitCurve, Double)
    }

    let kind: Kind
    var delay: Double = 0

    static func spring(_ response: Double, _ damping: Double) -> MotionCurve {
        MotionCurve(kind: .spring(Spring(response: response, dampingRatio: damping)))
    }

    static func curve(_ curve: UnitCurve, _ duration: Double) -> MotionCurve {
        MotionCurve(kind: .curve(curve, duration))
    }

    func delayed(_ seconds: Double) -> MotionCurve {
        var copy = self
        copy.delay += seconds
        return copy
    }

    var animation: Animation {
        let base: Animation
        switch kind {
        case .spring(let spring): base = .spring(spring)
        case .curve(let curve, let duration): base = .timingCurve(curve, duration: duration)
        }
        return (delay > 0 ? base.delay(delay) : base).speed(IslandMotion.speed)
    }

    /// Progress 0 → 1 (a spring may overshoot) `t` seconds after the animation started, delay included.
    func progress(_ t: Double) -> Double {
        let local = t - delay
        guard local > 0 else { return 0 }
        switch kind {
        case .spring(let spring): return spring.value(target: 1.0, time: local)
        case .curve(let curve, let duration): return curve.value(at: min(local / max(duration, 0.0001), 1))
        }
    }
}

/// The spring that moves the silhouette for one kind of change, and the pulse that accompanies it.
struct GeoSpring {
    let name: String
    let spring: Spring
    var pulse: IslandPulse.Kind?

    init(_ name: String, _ response: Double, _ damping: Double, pulse: IslandPulse.Kind? = nil) {
        self.name = name
        spring = Spring(response: response, dampingRatio: damping)
        self.pulse = pulse
    }

    var animation: Animation { .spring(spring, blendDuration: 0.1).speed(IslandMotion.speed) }
    /// How long this spring "owns" the shape: data changes meanwhile reuse it (no second spring).
    var settle: TimeInterval { spring.settlingDuration / IslandMotion.speed }
    func progress(_ t: Double) -> Double { t > 0 ? spring.value(target: 1.0, time: t) : 0 }
    var curve: MotionCurve { MotionCurve(kind: .spring(spring)) }
}

/// Every timing the island uses, in one place.
///
/// The silhouette (the black shape) is the only thing whose size animates: one spring per change,
/// committed in a single transaction once the new content has been measured (`IslandViewState`).
/// Content never resizes with it and never shows outside it (it is masked by the silhouette, which
/// uncovers it as it grows). One clock for every content swap:
/// - 0–50 ms: the outgoing view leaves (a quick ease-out, `exitOut`);
/// - from ~35 ms: the incoming view fades in (`RevealParams`, on its own curve, not the spring's), its
///   rows and sections cascade 20–22 ms apart (`AppearAfter`): readable by ~110 ms, sharp by ~180 ms;
/// - so the two never show at once, yet the shape is never an empty black box for long.
enum IslandMotion {
    /// `NOTCHBUDDY_SLOWMO=6` slows every animation down six times (SwiftUI, Core Animation and delays).
    static let slowmo: Double = max(1, ProcessInfo.processInfo.environment["NOTCHBUDDY_SLOWMO"].flatMap(Double.init) ?? 1)
    static var speed: Double { 1 / slowmo }
    static func delay(_ seconds: Double) -> Duration { .milliseconds(Int(seconds * 1000 * slowmo)) }
    /// A keyframe duration (keyframe animators take no `.speed`): slowed down with everything else.
    static func t(_ seconds: Double) -> Double { seconds * slowmo }
    /// A spring for a keyframe track, slowed down with everything else.
    static func kspring(_ response: Double, _ damping: Double) -> Spring {
        Spring(response: response * slowmo, dampingRatio: damping)
    }

    //                                            response / damping        overshoot   95 %
    static let open = GeoSpring("open", 0.46, 0.78, pulse: .earFlare(4))    // 2.0 %   240 ms
    static let close = GeoSpring("close", 0.36, 0.92, pulse: .earFlare(3))  // 0.1 %   239 ms
    static let morph = GeoSpring("morph", 0.42, 0.86)                       // 0.5 %   251 ms
    static let flash = GeoSpring("flash", 0.48, 0.68, pulse: .earFlare(5))  // 5.4 %   216 ms
    static let appear = GeoSpring("appear", 0.48, 0.72)                     // 3.8 %   229 ms
    static let hide = GeoSpring("hide", 0.30, 1.0)                          // 0       227 ms
    static let data = GeoSpring("data", 0.38, 0.90)                         // 0.2 %   243 ms
    static let hover = GeoSpring("hover", 0.30, 0.80)                       // 1.5 %   162 ms
    static let press = GeoSpring("press", 0.20, 0.80)                       // 1.5 %   108 ms
    static let reduced = GeoSpring("reduced", 0.22, 1.0)                    // Reduce Motion
    /// A dragged «Островок» let go: it settles where it was dropped (back inside the screen, or onto the center) softly.
    static let drop = GeoSpring("drop", 0.40, 0.78)                         // 2.0 %   ~210 ms
    /// The flying agent mark: quicker than the silhouette, so it lands before the text beside it. It never
    /// leaves the silhouette, though: out of the closed island it would outrun the growing edge, so it is
    /// held just inside it (`HeroPlacement`) and lands as the edge passes its slot.
    static let hero = GeoSpring("hero", 0.26, 0.90)                         // 0.2 %   ~165 ms
    /// A hero mark that has nowhere to fly from fades in place, with the incoming content.
    static let heroIn = MotionCurve.curve(.easeOut, 0.12).delayed(0.035)

    /// The text beside a flying mark fades in this long after its row or section, once the mark has passed
    /// it (it would fly over it otherwise). Out of the closed island the mark is held inside the growing
    /// silhouette (`HeroPlacement`), so it clears the text as late as the edge does: later beside a notch,
    /// where the closed island is narrowest and the edge has the farthest to go, and on the way into a
    /// card, whose header text starts closer to the mark. Where the edge never catches the mark (a list
    /// opening from the pill, no notch) nothing changes, nor for a mark that fades in place (`flies` false:
    /// the content it came from did not show it).
    static func heroTextLag(_ entrance: IslandEntrance, flies: Bool, notch: Bool, card: Bool) -> Double {
        guard entrance == .open, flies else { return 0.05 }
        if notch { return card ? 0.085 : 0.075 }
        return card ? 0.07 : 0.05
    }

    /// An AppKit view (the card's code block) is not masked by the silhouette. While the card comes in it is
    /// drawn as a snapshot of itself (a SwiftUI image, masked and revealed like the sections around it); the
    /// live view, pixel for pixel the same, takes over this long after the card mounted (or once the
    /// block's own reveal has settled, if that is later), when the silhouette has settled around it.
    static let appKitSwap = 0.30

    // Exits are gone by ~50 ms (6 % left at 40 ms), before the incoming view shows (from ~35–40 ms).
    static let exitOut = MotionCurve.curve(.easeOut, 0.05)
    static let exitSent = MotionCurve.curve(.easeOut, 0.06)
    static let exitSwap = MotionCurve.curve(.easeOut, 0.06)
    /// The open island closing: its content is drawn up into the shrinking shape and blurs out, readable for the first
    /// ~80 ms and gone by 150 ms, so the shape is never an empty block on its way down (the pill fades in from 90 ms).
    static let exitCollapse = MotionCurve.curve(.easeIn, 0.15)
    /// Incoming content: fast out of the gate, a long gentle settle (visible ~10 ms after its delay,
    /// opaque after ~30 ms, sharp after ~75 ms of a 0.18 s run).
    static let revealCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.25, y: 0.6),
                                              endControlPoint: UnitPoint(x: 0.3, y: 1))
    /// A staggered row or section: opaque ~60 ms after its delay, sharp after ~75 ms.
    static let rowIn = MotionCurve.spring(0.22, 0.92)
    static let leafCurve = MotionCurve.spring(0.26, 0.9)
    static var leaf: Animation { .snappy(duration: 0.26).speed(speed) }
    static var pop: Animation { .bouncy(duration: 0.40, extraBounce: 0.12).speed(speed) }
    static let fillCurve = MotionCurve.spring(0.60, 0.86)
    static var fill: Animation { fillCurve.animation }
    static var tint: Animation { .easeInOut(duration: 0.35).speed(speed) }
    static let pressCurve = MotionCurve.spring(0.20, 0.80)
    static let checkCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.3, y: 0), endControlPoint: UnitPoint(x: 0.2, y: 1))

    /// New open content ignores clicks this long (a double click on the closed island must not land on
    /// row 1); after that each row or section still takes clicks only once it is mostly in.
    static let interactiveDelay = 0.18
    /// Hover: open after resting this long, or after `maxDwell` in any case.
    static let restDwell = 0.09
    static let maxDwell = 0.22
    static let closeDelay = 0.35
    /// After a hover close, a pointer coming back near where it left the list (not racing past) reopens it
    /// at once for this long (`GraceZone` in `IslandController`).
    static let reopenGrace = 0.30
    /// The shape waits at most this long for the new content's measurement.
    static let commitFallback = 0.025
    /// The panel takes the mouse on the island's silhouette plus this much (and nowhere else).
    static let enterSlop: CGFloat = 1
    /// The hover state (breathing, close delay, keyboard) lets go only this far beyond the silhouette; the band
    /// takes no clicks and a rest there opens nothing.
    static let exitSlop: CGFloat = 10
    /// Kill switch for the flying agent mark.
    static let heroes = true

    static func geometry(from old: IslandMode, to new: IslandMode, reduce: Bool) -> GeoSpring {
        if reduce { return reduced }
        if new == .hidden { return hide }
        if old == .hidden { return new == .flash ? flash : (new.isOpen ? open : appear) }
        if new == .flash, old != .flash { return old.isOpen ? morph : flash }
        switch (old.isOpen, new.isOpen) {
        case (false, true): return open
        case (true, true): return morph
        case (true, false): return close
        case (false, false): return new == .idle ? close : appear
        }
    }
}

// MARK: - Entrances and exits

/// How incoming content appears. It has no animation of its own: it follows the progress of the
/// spring that moves the silhouette (the transaction of the mode change).
enum IslandEntrance: Equatable {
    /// Closed → list or card.
    case open
    /// Open → open (list ↔ card, flash → list).
    case morph
    /// Open → closed pill: it "blooms" as the silhouette lands.
    case close
    /// → notice; nothing → closed pill.
    case pop
    /// Next card, next notice: rises from below.
    case deck
    /// Another tab of the open island: slides in from the side it lies on (`forward`: from the right).
    case slide(forward: Bool)

    /// How far a tab slides in from its side.
    static let slideDistance: CGFloat = 26

    init(from old: IslandMode, to new: IslandMode) {
        switch new {
        case .hidden, .idle, .collapsed: self = old.isOpen ? .close : .pop
        case .flash: self = old == .flash ? .deck : (old.isOpen ? .morph : .pop)
        case .expanded, .permission, .page: self = old.isOpen ? .morph : .open
        }
    }

    /// When and how fast the incoming view fades in, and where it starts from. Not tied to the spring:
    /// the silhouette uncovers the content (it is masked by it), the content only has to be there.
    func params(blur: CGFloat) -> RevealParams {
        switch self {
        case .open: return RevealParams(delay: 0.035, duration: 0.18, blur: blur, scale: 0.96, dy: -8)
        // Open → open (list ↔ settings): the new page shows as the old one is nearly gone (~25 ms), no blank frame.
        case .morph: return RevealParams(delay: 0.026, duration: 0.18, blur: blur, scale: 0.98, dy: -6)
        // The closed island settles into the shrinking shape as the list blurs out above it (`IslandExit.collapse`);
        // it is sharp before the shape lands.
        case .close: return RevealParams(delay: 0.09, duration: 0.20, blur: blur, scale: 0.96, dy: -4)
        case .pop: return RevealParams(delay: 0.035, duration: 0.18, blur: blur, scale: 0.94, dy: -6)
        // The next card rises as the old one, sent up, is gone (~50 ms): a gap of ~15 ms, no overlap.
        case .deck: return RevealParams(delay: 0.045, duration: 0.18, blur: blur, scale: 0.99, dy: 12)
        // The next tab glides in from its side as the old one, slid the other way, is gone (~60 ms).
        case .slide(let forward): return RevealParams(delay: 0.04, duration: 0.24, blur: blur, scale: 0.995, dy: 0,
                                                      dx: forward ? Self.slideDistance : -Self.slideDistance)
        }
    }
}

/// The reveal of each content kind: the list and the card do not blur as a whole (their rows and
/// sections blur on their own), the pill and the notice do.
enum IslandContentLayerParams {
    static func reveal(_ entrance: IslandEntrance, _ kind: IslandContentKind) -> RevealParams {
        switch kind {
        // The closed island, dripping out of the top edge, rides the shape (`ClosedContentFit`).
        case .closed: return entrance.params(blur: 5)
        case .flash: return entrance.params(blur: 6)
        case .expanded, .permission, .page: return entrance.params(blur: 0)
        }
    }
}

struct RevealParams: Equatable {
    var delay: Double
    var duration: Double
    var blur: CGFloat
    var scale: CGFloat
    var dy: CGFloat
    /// Where it starts from sideways (a tab sliding in).
    var dx: CGFloat = 0

    /// The reveal's own animation (a transition's insertion runs on it, whatever the transaction).
    var curve: MotionCurve { MotionCurve.curve(IslandMotion.revealCurve, duration).delayed(delay) }

    static let opacityOnly = RevealParams(delay: 0.03, duration: 0.16, blur: 0, scale: 1, dy: 0)
}

/// Incoming content, `p` = progress of its reveal curve (0 … 1). Opaque within the first 45 % of it,
/// sharp by 85 %; it takes clicks only once it is nearly in.
struct RevealEffect: ViewModifier, Animatable {
    var p: Double
    let e: RevealParams

    var animatableData: Double {
        get { p }
        set { p = newValue }
    }

    func body(content: Content) -> some View {
        let q = min(max(p, 0), 1)
        content
            .opacity(smoothstep(0, 0.45, q))
            .blur(radius: e.blur * CGFloat(1 - smoothstep(0, 0.85, q)))
            .scaleEffect(1 - CGFloat(1 - q) * (1 - e.scale), anchor: .top)
            .offset(x: CGFloat(1 - q) * e.dx, y: CGFloat(1 - q) * e.dy)
            .allowsHitTesting(q > 0.9)
    }
}

/// How outgoing content leaves. It never takes hits while leaving.
enum IslandExit: Equatable {
    /// Mode content: drawn up into the island.
    case out
    /// A permission card leaving (answered, withdrawn, timed out): sent up into the island.
    case sent
    /// A notice replaced or dismissed.
    case swap
    /// A tab giving way to another: slides out toward the side opposite the new one (`forward`: to the left).
    case slide(forward: Bool)
    /// The open island closing: drawn up into the shrinking shape, blurring out (`IslandMotion.exitCollapse`).
    case collapse

    var curve: MotionCurve {
        switch self {
        case .out: return IslandMotion.exitOut
        case .sent: return IslandMotion.exitSent
        case .swap, .slide: return IslandMotion.exitSwap
        case .collapse: return IslandMotion.exitCollapse
        }
    }

    var params: ExitParams {
        switch self {
        case .out: return ExitParams(blur: 4, scale: 0.97, dy: -4)
        case .sent: return ExitParams(blur: 4, scale: 0.98, dy: -12)
        case .swap: return ExitParams(blur: 5, scale: 0.97, dy: -8)
        case .slide(let forward): return ExitParams(blur: 3, scale: 0.99, dy: 0, dx: forward ? -18 : 18)
        case .collapse: return ExitParams(blur: 8, scale: 0.94, dy: -8)
        }
    }
}

struct ExitParams: Equatable {
    var blur: CGFloat
    var scale: CGFloat
    var dy: CGFloat
    var dx: CGFloat = 0
}

/// Outgoing content, `q` = 0 in place … 1 gone.
struct ExitEffect: ViewModifier, Animatable {
    var q: Double
    let e: ExitParams

    var animatableData: Double {
        get { q }
        set { q = newValue }
    }

    func body(content: Content) -> some View {
        let k = min(max(q, 0), 1)
        content
            // AppKit-backed children (the code block) are not masked by the silhouette: they are gone
            // within the first half of the exit.
            .environment(\.islandExitProgress, k)
            .opacity(1 - k)
            .blur(radius: e.blur * CGFloat(k))
            .scaleEffect(1 - CGFloat(k) * (1 - e.scale), anchor: .top)
            .offset(x: CGFloat(k) * e.dx, y: CGFloat(k) * e.dy)
            .allowsHitTesting(k == 0)
    }
}

extension AnyTransition {
    /// Content of a mode: in and out on its own curves (the silhouette's spring only uncovers it).
    static func island(_ reveal: RevealParams, exit: IslandExit, reduce: Bool = false) -> AnyTransition {
        let insertion = AnyTransition.modifier(active: RevealEffect(p: 0, e: reveal), identity: RevealEffect(p: 1, e: reveal))
            .animation(reveal.curve.animation)
        if reduce {
            return .asymmetric(insertion: insertion,
                               removal: .opacity.animation(.easeOut(duration: 0.08).speed(IslandMotion.speed)))
        }
        return .asymmetric(
            insertion: insertion,
            removal: .modifier(active: ExitEffect(q: 1, e: exit.params), identity: ExitEffect(q: 0, e: exit.params))
                .animation(exit.curve.animation)
        )
    }
}

func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    guard b > a else { return x >= b ? 1 : 0 }
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

// MARK: - Staggered reveals

/// Where a staggered element starts from.
struct AppearStyle: Equatable {
    var dy: CGFloat
    var blur: CGFloat
    var scale: CGFloat
    var opacityOnly = false

    /// A list row dropping out of the island.
    static let row = AppearStyle(dy: -8, blur: 4, scale: 0.97)
    /// The row whose agent mark is the flying hero: it must not move under the mark.
    static let heroRow = AppearStyle(dy: 0, blur: 4, scale: 1)
    static let header = AppearStyle(dy: -6, blur: 4, scale: 1)
    static let section = AppearStyle(dy: -6, blur: 4, scale: 1)
    static let deckSection = AppearStyle(dy: 10, blur: 4, scale: 1)
    static let rise = AppearStyle(dy: 6, blur: 0, scale: 1)
    static let fade = AppearStyle(dy: 0, blur: 0, scale: 1, opacityOnly: true)
}

/// An element that appears `delay` after it is mounted inside content that is already revealing
/// (list rows, card sections, notice lines). It takes no clicks until it is mostly in: the effect is
/// `Animatable`, so the gate (and the opacity and blur curves) follow the animation frame by frame
/// instead of flipping with the model value.
struct AppearAfter: ViewModifier {
    let delay: Double
    var style: AppearStyle = .row
    var curve: MotionCurve = IslandMotion.rowIn
    /// False: shown as is (the modifier stays, so toggling it never remounts the content).
    var enabled = true

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandFilmTime) private var filmTime
    @Environment(\.islandReduceMotion) private var reduceMotion
    /// On the Core Animation stage the section does not animate in SwiftUI: the stage reveals it (`StagedSection`).
    @Environment(\.islandSectionSink) private var sectionSink
    @State private var shown = false
    /// On the stage: whether this section came in with its page (the stage reveals it) or later (a row arriving in
    /// the open list animates in SwiftUI, as everywhere else). Decided when it appears.
    @State private var staged: Bool?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let sectionSink, filmTime == nil, !staticRender {
            stagedBody(content: content, sink: sectionSink)
        } else {
            swiftUIBody(content: content)
        }
    }

    /// The same modifiers either way, so the decision never remounts the content.
    private func stagedBody(content: Content, sink: IslandSectionSink) -> some View {
        let byStage = staged ?? sink.takesNewSections
        let q: Double = !enabled || byStage || shown ? 1 : 0
        return content
            .modifier(AppearEffect(q: q, style: style, plain: style.opacityOnly || reduceMotion))
            .modifier(StagedSection(sink: sink, delay: delay, style: style, curve: curve, enabled: enabled && byStage))
            .onAppear {
                staged = byStage
                guard enabled, !byStage, !shown else {
                    shown = true
                    return
                }
                let animation = reduceMotion
                    ? Animation.easeOut(duration: 0.14).delay(0.04).speed(IslandMotion.speed)
                    : curve.delayed(delay).animation
                withAnimation(animation) { shown = true }
            }
    }

    @ViewBuilder
    private func swiftUIBody(content: Content) -> some View {
        let q: Double = {
            if !enabled { return 1 }
            if let filmTime { return curve.delayed(delay).progress(filmTime) }
            return shown || staticRender ? 1 : 0
        }()
        content
            .modifier(AppearEffect(q: q, style: style, plain: style.opacityOnly || reduceMotion))
            .onAppear {
                guard enabled else {
                    shown = true
                    return
                }
                guard !shown, !staticRender, filmTime == nil else { return }
                let animation = reduceMotion
                    ? Animation.easeOut(duration: 0.14).delay(0.04).speed(IslandMotion.speed)
                    : curve.delayed(delay).animation
                withAnimation(animation) { shown = true }
            }
    }
}

/// `AppearAfter`'s look at progress `q` (0 … 1, a spring may overshoot): readable early, blur gone by
/// three quarters, offset and scale settle over the whole course.
struct AppearEffect: ViewModifier, Animatable {
    var q: Double
    let style: AppearStyle
    let plain: Bool

    var animatableData: Double {
        get { q }
        set { q = newValue }
    }

    func body(content: Content) -> some View {
        let k = min(max(q, 0), 1)
        content
            .opacity(min(max(q * 1.6, 0), 1))
            .blur(radius: plain ? 0 : style.blur * CGFloat(1 - smoothstep(0, 0.75, k)))
            .scaleEffect(plain ? 1 : 1 - CGFloat(1 - q) * (1 - style.scale), anchor: .top)
            .offset(y: plain ? 0 : CGFloat(1 - q) * style.dy)
            .allowsHitTesting(k > 0.85)
    }
}

extension View {
    func appearAfter(_ delay: Double, style: AppearStyle = .row, curve: MotionCurve = IslandMotion.rowIn,
                     enabled: Bool = true) -> some View {
        modifier(AppearAfter(delay: delay, style: style, curve: curve, enabled: enabled))
    }
}

// MARK: - One-shots

/// One-shot animations (a check drawn on, an error shake, a notice's choreography) play once per event,
/// not every time a view that shows the event is mounted again.
@MainActor
enum OneShots {
    private static var played = Set<String>()

    static func hasPlayed(_ key: String) -> Bool { played.contains(key) }

    /// True the first time only: the caller plays the animation.
    static func claim(_ key: String) -> Bool {
        if played.count > 400 { played.removeAll() }
        return played.insert(key).inserted
    }
}

// MARK: - Pulses

/// Additive, keyframed deformations of the silhouette on top of its spring (ears flaring out as it opens,
/// a latch when pinned, a "gulp" when the front card changes).
struct IslandPulse: Equatable {
    var earBoost: CGFloat = 0
    var dh: CGFloat = 0

    enum Kind: Equatable {
        case earFlare(CGFloat)
        case latch
        case gulp
    }

    struct Params {
        var ear: CGFloat = 0
        var dh1: CGFloat = 0
        var t1: Double = 0.01
        var dh2: CGFloat = 0
        var t2: Double = 0.01
        var t3: Double = 0.01
        var settle = Spring(response: 0.3, dampingRatio: 0.8)
    }

    static func params(_ kind: Kind) -> Params {
        switch kind {
        case .earFlare(let a):
            return Params(ear: a)
        case .latch:
            return Params(dh1: 3, t1: 0.08, dh2: -1, t2: 0.10, t3: 0.16, settle: Spring(response: 0.2, dampingRatio: 0.7))
        case .gulp:
            return Params(dh1: -10, t1: 0.10, dh2: -10, t2: 0.03, t3: 0.40, settle: Spring(response: 0.30, dampingRatio: 0.62))
        }
    }

    @KeyframesBuilder<IslandPulse>
    static func keyframes(_ kind: Kind) -> some Keyframes<IslandPulse> {
        let k = params(kind)
        KeyframeTrack(\.earBoost) {
            CubicKeyframe(k.ear, duration: IslandMotion.t(0.12))
            SpringKeyframe(0, duration: IslandMotion.t(0.36), spring: IslandMotion.kspring(0.36, 0.8))
        }
        KeyframeTrack(\.dh) {
            CubicKeyframe(k.dh1, duration: IslandMotion.t(k.t1))
            CubicKeyframe(k.dh2, duration: IslandMotion.t(k.t2))
            SpringKeyframe(0, duration: IslandMotion.t(k.t3),
                           spring: Spring(response: k.settle.response * IslandMotion.slowmo, dampingRatio: k.settle.dampingRatio))
        }
    }

    static func value(_ kind: Kind, at t: Double) -> IslandPulse {
        guard t > 0 else { return IslandPulse() }
        return KeyframeTimeline(initialValue: IslandPulse()) { keyframes(kind) }.value(time: t)
    }
}

/// A tinted halo around the silhouette (a notice, a permission card).
struct IslandGlow: Equatable {
    var tint: Color
    var peak: Double
    var rest: Double
    var rise = 0.18
    var settle = 0.6

    static func finished(quiet: Bool) -> IslandGlow {
        IslandGlow(tint: SessionStatus.finished.tint, peak: quiet ? 0.30 : 0.55, rest: 0.22)
    }
    static let attention = IslandGlow(tint: SessionStatus.waitingForUser.tint, peak: 0.60, rest: 0.25)
    static let card = IslandGlow(tint: SessionStatus.waitingForUser.tint, peak: 0.30, rest: 0.16)
    static let cardQueued = IslandGlow(tint: SessionStatus.waitingForUser.tint, peak: 0.45, rest: 0.16)
    /// Reduce Motion's stand-in for the error shake: a red glow that fades in and out.
    static let error = IslandGlow(tint: SessionStatus.error.tint, peak: 0.6, rest: 0, rise: 0.15, settle: 0.25)

    @KeyframesBuilder<Double>
    func keyframes() -> some Keyframes<Double> {
        KeyframeTrack {
            CubicKeyframe(peak, duration: IslandMotion.t(rise))
            CubicKeyframe(rest, duration: IslandMotion.t(settle))
        }
    }

    func level(at t: Double) -> Double {
        guard t > 0 else { return 0 }
        return KeyframeTimeline(initialValue: 0.0) { keyframes() }.value(time: t)
    }
}

/// The whole closed island shakes once when its session fails.
enum ErrorShake {
    @KeyframesBuilder<CGFloat>
    static func keyframes() -> some Keyframes<CGFloat> {
        KeyframeTrack {
            CubicKeyframe(-5, duration: IslandMotion.t(0.05))
            CubicKeyframe(5, duration: IslandMotion.t(0.08))
            CubicKeyframe(-3, duration: IslandMotion.t(0.07))
            CubicKeyframe(2, duration: IslandMotion.t(0.06))
            SpringKeyframe(0, duration: IslandMotion.t(0.2), spring: IslandMotion.kspring(0.2, 0.6))
        }
    }

    static func value(at t: Double) -> CGFloat {
        guard t > 0 else { return 0 }
        return KeyframeTimeline(initialValue: CGFloat(0)) { keyframes() }.value(time: t)
    }
}

// MARK: - Environment

/// Filmstrips: the queue dots move from `previous` to the current queue (`progress` 0 … 1).
struct FilmQueueChange: Equatable {
    var previous: [UUID]
    var progress: Double
}

private struct IslandStaticRenderKey: EnvironmentKey { static let defaultValue = false }
private struct IslandFilmTimeKey: EnvironmentKey { static let defaultValue: Double? = nil }
private struct IslandEntranceKey: EnvironmentKey { static let defaultValue = IslandEntrance.pop }
private struct IslandIgniteDelayKey: EnvironmentKey { static let defaultValue: Double = 0.06 }
private struct IslandReduceMotionKey: EnvironmentKey { static let defaultValue = false }
private struct IslandPulseKey: EnvironmentKey { static let defaultValue = IslandPulse() }
private struct IslandHeroKeyKey: EnvironmentKey { static let defaultValue: SessionKey? = nil }
private struct IslandHeroFliesKey: EnvironmentKey { static let defaultValue = false }
private struct IslandFilmStatusKey: EnvironmentKey { static let defaultValue: [SessionKey: SessionStatus] = [:] }
private struct IslandFilmPillWidthKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
private struct IslandFilmQueueChangeKey: EnvironmentKey { static let defaultValue: FilmQueueChange? = nil }
private struct IslandExitProgressKey: EnvironmentKey { static let defaultValue: Double = 0 }

extension EnvironmentValues {
    /// True when the island is rendered to an image (`--render-previews`): one-shot and repeating
    /// animations show their resting frame, and AppKit-backed views are replaced by SwiftUI drawings.
    var islandStaticRender: Bool {
        get { self[IslandStaticRenderKey.self] }
        set { self[IslandStaticRenderKey.self] = newValue }
    }

    /// Filmstrip frames: seconds since the content was mounted. Time-driven pieces draw their state at
    /// this moment instead of animating.
    var islandFilmTime: Double? {
        get { self[IslandFilmTimeKey.self] }
        set { self[IslandFilmTimeKey.self] = newValue }
    }

    /// Filmstrip frames: the status each session had before the change being filmed.
    var islandFilmPreviousStatus: [SessionKey: SessionStatus] {
        get { self[IslandFilmStatusKey.self] }
        set { self[IslandFilmStatusKey.self] = newValue }
    }

    /// Filmstrips: the closed island's row width at the filmed moment.
    var islandFilmPillWidth: CGFloat? {
        get { self[IslandFilmPillWidthKey.self] }
        set { self[IslandFilmPillWidthKey.self] = newValue }
    }

    /// Filmstrips: the permission queue before the change being filmed, and how far the change is.
    var islandFilmQueueChange: FilmQueueChange? {
        get { self[IslandFilmQueueChangeKey.self] }
        set { self[IslandFilmQueueChangeKey.self] = newValue }
    }

    /// 0 … 1 while the content around this view leaves (`ExitEffect`); AppKit-backed views fade faster.
    /// Read it only in a small leaf view: it changes every frame of an exit.
    var islandExitProgress: Double {
        get { self[IslandExitProgressKey.self] }
        set { self[IslandExitProgressKey.self] = newValue }
    }

    /// How the current content came in (card sections cascade differently for a new card in a queue).
    var islandEntrance: IslandEntrance {
        get { self[IslandEntranceKey.self] }
        set { self[IslandEntranceKey.self] = newValue }
    }

    /// When a Core Animation indicator mounted now should "ignite" (scale in).
    var islandIgniteDelay: Double {
        get { self[IslandIgniteDelayKey.self] }
        set { self[IslandIgniteDelayKey.self] = newValue }
    }

    var islandReduceMotion: Bool {
        get { self[IslandReduceMotionKey.self] }
        set { self[IslandReduceMotionKey.self] = newValue }
    }

    /// Current additive deformation of the silhouette (read only by the surface and the mask).
    var islandPulse: IslandPulse {
        get { self[IslandPulseKey.self] }
        set { self[IslandPulseKey.self] = newValue }
    }

    /// The session whose agent mark is drawn by the hero layer (content leaves a hole for it).
    var islandHeroKey: SessionKey? {
        get { self[IslandHeroKeyKey.self] }
        set { self[IslandHeroKeyKey.self] = newValue }
    }

    /// The hero mark flies in from the content before (it showed it too) rather than fading in place
    /// (`IslandMotion.heroTextLag`).
    var islandHeroFlies: Bool {
        get { self[IslandHeroFliesKey.self] }
        set { self[IslandHeroFliesKey.self] = newValue }
    }
}
