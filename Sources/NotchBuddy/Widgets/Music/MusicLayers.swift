import AppKit
import NotchBuddyCore
import QuartzCore
import SwiftUI

// The widget's moving parts run in Core Animation (the render server), like the island's other loops
// (`LoopLayerView`): the app does no per-frame work for them, they stop while the island is hidden or
// occluded, and ImageRenderer previews get a SwiftUI drawing of their resting frame instead.

// MARK: - Equalizer

/// Bars dancing to the music; paused, they sink into dots (and rise back out when it plays again).
struct MusicEqualizer: View {
    let playing: Bool
    let color: Color
    var bars = 4
    /// Previews: draw the loop at this moment (seconds).
    var filmTime: Double?

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        if staticRender || reduceMotion || filmTime != nil {
            GeometryReader { geo in
                let gap = geo.size.width * MusicEqualizerView.gapRatio(bars)
                let w = (geo.size.width - gap * CGFloat(bars - 1)) / CGFloat(bars)
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(0..<bars, id: \.self) { i in
                        let level = playing ? MusicEqualizerView.level(bar: i, at: filmTime ?? 0.37) : MusicEqualizerView.rest
                        Capsule().fill(color).frame(width: w, height: max(w, geo.size.height * level))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            }
        } else {
            MusicEqualizerLayer(playing: playing, color: NSColor(color), bars: bars)
        }
    }
}

private struct MusicEqualizerLayer: NSViewRepresentable {
    let playing: Bool
    let color: NSColor
    let bars: Int

    func makeNSView(context: Context) -> MusicEqualizerView {
        let view = MusicEqualizerView(bars: bars)
        view.igniteDelay = context.environment.islandIgniteDelay
        view.playing = playing
        view.color = color
        return view
    }

    func updateNSView(_ view: MusicEqualizerView, context: Context) {
        view.color = color
        view.playing = playing
    }
}

final class MusicEqualizerView: LoopLayerView {
    static let rest: CGFloat = 0.22
    static func gapRatio(_ bars: Int) -> CGFloat { bars > 3 ? 0.14 : 0.18 }

    /// Levels per bar over one period (irregular, so four bars never line up).
    private static let levels: [[Double]] = [
        [0.30, 0.92, 0.46, 0.74, 0.28, 1.00, 0.52, 0.66, 0.30],
        [0.70, 0.34, 1.00, 0.42, 0.86, 0.36, 0.78, 0.50, 0.70],
        [0.48, 0.82, 0.30, 0.96, 0.54, 0.40, 0.90, 0.34, 0.48],
        [0.84, 0.44, 0.70, 0.30, 0.96, 0.62, 0.38, 0.88, 0.84],
        [0.40, 0.76, 0.58, 0.94, 0.32, 0.70, 0.46, 1.00, 0.40],
    ]
    private static let periods: [CFTimeInterval] = [1.12, 0.94, 1.28, 1.03, 1.19]

    /// The keyframed level of `bar` at `t` seconds (previews draw with it).
    static func level(bar: Int, at t: Double) -> CGFloat {
        let values = levels[bar % levels.count]
        let period = periods[bar % periods.count]
        let x = (t.truncatingRemainder(dividingBy: period) / period) * Double(values.count - 1)
        let i = min(Int(x), values.count - 2)
        let f = x - Double(i)
        let eased = f * f * (3 - 2 * f)
        return CGFloat(values[i] + (values[i + 1] - values[i]) * eased)
    }

    var color: NSColor = .white {
        didSet { if oldValue != color { applyColor(animated: window != nil) } }
    }

    var playing = true {
        didSet { if oldValue != playing { playingChanged() } }
    }

    /// Each bar sits in a holder: the loop scales the bar, the pause/resume spring scales the holder.
    private let holders: [CALayer]
    private let bars: [CALayer]

    init(bars count: Int) {
        holders = (0..<count).map { _ in CALayer() }
        bars = (0..<count).map { _ in CALayer() }
        super.init(frame: .zero)
        for (holder, bar) in zip(holders, bars) {
            holder.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            holder.addSublayer(bar)
            stage.addSublayer(holder)
        }
        applyColor(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutStage() {
        let n = CGFloat(bars.count)
        let gap = bounds.width * Self.gapRatio(bars.count)
        let w = max(1, (bounds.width - gap * (n - 1)) / n)
        for (i, (holder, bar)) in zip(holders, bars).enumerated() {
            let x = CGFloat(i) * (w + gap) + w / 2
            holder.bounds = CGRect(x: 0, y: 0, width: w, height: bounds.height)
            holder.position = CGPoint(x: x, y: 0)
            bar.bounds = holder.bounds
            bar.position = CGPoint(x: w / 2, y: 0)
            bar.cornerRadius = w / 2
            if !playing { holder.transform = CATransform3DMakeScale(1, Self.rest, 1) }
        }
    }

    private func applyColor(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            if animated {
                let fade = CABasicAnimation(keyPath: "backgroundColor")
                fade.fromValue = bar.presentation()?.backgroundColor ?? bar.backgroundColor
                fade.duration = 0.5 / IslandMotion.speed
                bar.add(fade, forKey: "tint")
            }
            bar.backgroundColor = color.cgColor
        }
        CATransaction.commit()
    }

    private func playingChanged() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (holder, bar) in zip(holders, bars) {
            let from: CGFloat
            if playing {
                from = Self.rest
            } else {
                // Sink from wherever the bar is in its dance.
                from = (bar.presentation()?.value(forKeyPath: "transform.scale.y") as? CGFloat) ?? 1
                bar.removeAnimation(forKey: "level")
                bar.transform = CATransform3DIdentity
            }
            let to: CGFloat = playing ? 1 : Self.rest
            holder.transform = CATransform3DMakeScale(1, to, 1)
            let spring = CASpringAnimation(keyPath: "transform.scale.y")
            spring.fromValue = from
            spring.toValue = to
            spring.mass = 1
            spring.stiffness = playing ? 220 : 300
            spring.damping = playing ? 16 : 24
            spring.duration = spring.settlingDuration
            spring.speed = Float(IslandMotion.speed)
            holder.add(spring, forKey: "settle")
        }
        CATransaction.commit()
        // The loops start (or stop) with the next layout pass.
        needsLayout = true
    }

    override func addLoops() {
        guard playing else { return }
        for (i, bar) in bars.enumerated() where bar.animation(forKey: "level") == nil {
            let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
            let values = Self.levels[i % Self.levels.count]
            a.values = values
            a.keyTimes = (0..<values.count).map { NSNumber(value: Double($0) / Double(values.count - 1)) }
            a.calculationMode = .cubic
            let phased = Self.phased(a, period: Self.periods[i % Self.periods.count])
            // Quick, springy motion: at the display's full rate.
            phased.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            bar.add(phased, forKey: "level")
        }
    }

    override func removeLoops() {
        bars.forEach { $0.removeAnimation(forKey: "level") }
    }
}

// MARK: - Progress

/// The track's progress: a thin white line on a grey groove, filling at the track's pace (one linear Core
/// Animation run to the end, restarted from the true position on every change). Under the pointer (or
/// while scrubbing) it thickens a little; there is no knob.
struct MusicProgressBar: View {
    /// 0…1 now; nil when the position is unknown.
    let fraction: Double?
    /// Fraction per second (0 while paused).
    let rate: Double
    let hovering: Bool
    /// The pointer's position while scrubbing.
    let scrub: Double?

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandFilmTime) private var filmTime

    static let restHeight: CGFloat = 4
    static let hoverHeight: CGFloat = 7
    static let groove = NSColor.white.withAlphaComponent(0.2)

    var body: some View {
        // A film draws what is on screen at its moment (the layer's own animation is played by the render server).
        if staticRender || filmTime != nil {
            GeometryReader { geo in
                let h = hovering || scrub != nil ? Self.hoverHeight : Self.restHeight
                let f = CGFloat(scrub ?? fraction ?? 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(MusicInk.groove).frame(height: h)
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(h, geo.size.width * f), height: h)
                        .opacity(fraction == nil && scrub == nil ? 0 : 1)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        } else {
            MusicProgressLayer(config: .init(fraction: fraction, rate: rate, hovering: hovering, scrub: scrub))
        }
    }
}

private struct MusicProgressLayer: NSViewRepresentable {
    let config: MusicProgressView.Config

    func makeNSView(context: Context) -> MusicProgressView { MusicProgressView() }

    func updateNSView(_ view: MusicProgressView, context: Context) {
        view.config = config
    }
}

final class MusicProgressView: NSView {
    struct Config: Equatable {
        var fraction: Double?
        var rate: Double
        var hovering: Bool
        var scrub: Double?
    }

    var config = Config(fraction: nil, rate: 0, hovering: false, scrub: nil) {
        didSet { if config != oldValue { apply(from: oldValue) } }
    }

    private let track = CALayer()
    private let fill = CALayer()
    private var laidOutWidth: CGFloat = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        track.backgroundColor = MusicProgressBar.groove.cgColor
        fill.backgroundColor = NSColor.white.cgColor
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        for sublayer in [track, fill] { layer?.addSublayer(sublayer) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        if bounds.width != laidOutWidth {
            laidOutWidth = bounds.width
            apply(from: nil)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        for sublayer in [track, fill] { sublayer.contentsScale = window?.backingScaleFactor ?? 2 }
    }

    private static func height(_ config: Config) -> CGFloat {
        config.hovering || config.scrub != nil ? MusicProgressBar.hoverHeight : MusicProgressBar.restHeight
    }

    private func apply(from old: Config?) {
        let w = bounds.width, midY = bounds.midY
        guard w > 0 else { return }
        let h = Self.height(config)
        let oldHeight = old.map(Self.height) ?? h
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        track.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        track.position = CGPoint(x: w / 2, y: midY)
        track.cornerRadius = h / 2
        fill.position = CGPoint(x: 0, y: midY)
        fill.cornerRadius = h / 2

        // Where it is now, and (playing) a linear run to the end at the track's pace.
        fill.removeAnimation(forKey: "run")
        let known = config.scrub ?? config.fraction
        let f = CGFloat(min(max(known ?? 0, 0), 1))
        let start = max(h, f * w)
        fill.opacity = known == nil ? 0 : 1
        if config.scrub == nil, let fraction = config.fraction, config.rate > 0, fraction < 1 {
            let remaining = (1 - fraction) / config.rate
            fill.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            let run = CABasicAnimation(keyPath: "bounds.size.width")
            run.fromValue = start
            run.toValue = w
            run.duration = remaining
            run.timingFunction = CAMediaTimingFunction(name: .linear)
            // Slow and steady: as many frames as it takes to move about a quarter point per frame.
            let speed = (w * (1 - f)) / CGFloat(max(remaining, 0.001))
            let fps = Float(min(max(speed * 4, 10), 60))
            run.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 60, preferred: fps)
            fill.add(run, forKey: "run")
        } else {
            fill.bounds = CGRect(x: 0, y: 0, width: start, height: h)
        }
        CATransaction.commit()

        // Thicker under the pointer: a quick spring with no overshoot.
        if oldHeight != h {
            for target in [track, fill] {
                for (key, from, to) in [("bounds.size.height", oldHeight, h), ("cornerRadius", oldHeight / 2, h / 2)] {
                    let spring = CASpringAnimation(keyPath: key)
                    spring.fromValue = from
                    spring.toValue = to
                    spring.stiffness = 420
                    spring.damping = 40
                    spring.duration = spring.settlingDuration
                    spring.speed = Float(IslandMotion.speed)
                    target.add(spring, forKey: "hover-\(key)")
                }
            }
        }
    }
}
