import AppKit
import SwiftUI

/// Counts glyph draws (the live check reads it to measure loop frame rates). One integer increment per
/// icon frame: free in production.
enum NBDesignProbe {
    static var glyphDraws = 0
}

/// The live half of `--render-design`: the components in a real window (a click-through panel far off
/// every screen, never shown), driven through their state changes on the real run loop, so the paths an
/// image render never takes (keyframe animators, animatable glyphs mid-flight, TimelineView loops,
/// numeric content transitions) all run. Reports loop frame rates and process CPU while looping.
@MainActor
enum NBDesignLiveCheck {
    final class Model: ObservableObject {
        @Published var on = false
        @Published var value: Double = 0.2
        @Published var count = 1
        @Published var selection = 0
        @Published var morph = false
        @Published var loops = false
        @Published var hoverLoops = false
    }

    private struct Gallery: View {
        @ObservedObject var model: Model

        var body: some View {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    NBSwitch(isOn: $model.on)
                    NBSegmentedPicker(selection: $model.selection, options: [.init(0, "А"), .init(1, "Б"), .init(2, "В")])
                        .frame(width: 160)
                    NBChip("работает", icon: .working, accent: .working, count: model.count)
                    NBBadge(count: model.count)
                }
                HStack(spacing: 12) {
                    NBIconView(.soundOn, size: 24, value: model.morph ? 0 : 1)
                    NBIconView(.play, size: 24, value: model.morph ? 1 : 0)
                    NBIconView(.pin, size: 24, value: model.morph ? 1 : 0)
                    NBIconView(.settings, size: 24, active: model.morph)
                    NBIconView(.done, size: 24, drawsOnAppear: true)
                    NBProgressBar(value: model.value, active: model.loops).frame(width: 120)
                    NBProgressRing(value: model.value)
                    NBSlider(value: $model.value).frame(width: 120)
                }
                HStack(spacing: 12) {
                    ForEach([NBIcon.working, .waiting, .terminal, .web, .cpu, .sparkle], id: \.self) { icon in
                        NBIconView(icon, size: 24, active: model.hoverLoops, loops: model.loops)
                    }
                }
                NBButton("Разрешить", icon: .check, kind: .primary) {}
            }
            .padding(20)
            .frame(width: 720, height: 220)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        }
    }

    struct Result {
        var report: [String] = []
        var problems: [String] = []
    }

    private static func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.004))
        }
    }

    private static func spriteViews(in view: NSView) -> [NBSpriteNSView] {
        var found: [NBSpriteNSView] = []
        if let sprite = view as? NBSpriteNSView { found.append(sprite) }
        for sub in view.subviews { found += spriteViews(in: sub) }
        return found
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    static func run() -> Result {
        var result = Result()
        let model = Model()
        // What the measuring loop itself costs (run-loop polling in a debug build).
        let base0 = cpuSeconds()
        spin(1.0)
        let baseline = cpuSeconds() - base0
        let panel = NSPanel(contentRect: NSRect(x: -40_000, y: -40_000, width: 720, height: 220),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        let host = NSHostingView(rootView: Gallery(model: model))
        panel.contentView = host
        panel.setFrame(NSRect(x: -40_000, y: -40_000, width: 720, height: 220), display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        spin(0.3)

        // State changes, each with time to animate: none of them may crash or hang the run loop.
        let t0 = CACurrentMediaTime()
        let changes: [(String, () -> Void)] = [
            ("switch on", { model.on = true }),
            ("switch off", { model.on = false }),
            ("segment", { model.selection = 2 }),
            ("count", { model.count = 7 }),
            ("icon morphs", { model.morph = true }),
            ("icon morphs back", { model.morph = false }),
            ("fill", { model.value = 0.86 }),
        ]
        for (_, change) in changes {
            change()
            spin(0.18)
        }
        let changeTime = CACurrentMediaTime() - t0
        result.report.append(String(format: "live: %d state changes animated on the run loop in %.2f s", changes.count, changeTime))

        // Loops: frames per second per looping icon, and CPU while six loop (after every spring settled).
        spin(1.6)
        NBDesignProbe.glyphDraws = 0
        let idleCPU0 = cpuSeconds()
        spin(1.0)
        let idleDraws = NBDesignProbe.glyphDraws
        let idleCPU = max(0, cpuSeconds() - idleCPU0 - baseline)
        result.report.append(String(format: "live: at rest %d glyph draws/s, %.1f%% CPU above the measuring loop's own %.1f%%",
                                    idleDraws, idleCPU * 100, baseline * 100))
        if idleCPU > 0.05 {
            result.problems.append(String(format: "%.1f%% CPU with nothing animating", idleCPU * 100))
        }

        // Loops: Core Animation sprites, no per-frame app work.
        model.loops = true
        spin(0.6)
        let spriteList = spriteViews(in: host)
        let playing = spriteList.filter { $0.isPlaying }.count
        if let wrong = spriteList.first(where: { abs($0.bounds.width - 24) > 0.5 || abs($0.bounds.height - 24) > 0.5 }) {
            result.problems.append("sprite laid out at \(wrong.bounds.size), icon is 24 × 24")
        }
        NBDesignProbe.glyphDraws = 0
        let cpu0 = cpuSeconds()
        spin(2.0)
        let loopDraws = NBDesignProbe.glyphDraws
        let loopCPU = max(0, cpuSeconds() - cpu0 - 2 * baseline) / 2
        result.report.append(String(format: "live: 6 looping icons → %d Core Animation sprites playing, %d app draws in 2 s, +%.1f%% CPU",
                                    playing, loopDraws, loopCPU * 100))
        if playing != 6 { result.problems.append("\(playing) of 6 loops became sprites") }
        if loopDraws > 0 { result.problems.append("\(loopDraws) glyph draws while sprites loop") }

        // Hover gesture on looping icons: drawn live (the loop continues) at the icon's rate, then back to sprites.
        model.hoverLoops = true
        spin(0.2)
        NBDesignProbe.glyphDraws = 0
        let liveStart = CACurrentMediaTime()
        spin(1.0)
        let fps = Double(NBDesignProbe.glyphDraws) / 6 / (CACurrentMediaTime() - liveStart)
        let budget = [NBIcon.working, .waiting, .terminal, .web, .cpu, .sparkle].map(\.loopFrameRate).reduce(0, +) / 6
        model.hoverLoops = false
        spin(1.3)
        let back = spriteViews(in: host).filter { $0.isPlaying }.count
        result.report.append(String(format: "live: hovered loops draw live ≈ %.0f fps (budget %.0f), then %d/6 back to sprites",
                                    fps, budget, back))
        if fps > budget * 1.15 { result.problems.append(String(format: "live loops at %.0f fps (budget %.0f)", fps, budget)) }
        if fps < budget * 0.4 { result.problems.append(String(format: "live loops stall at %.0f fps", fps)) }
        if back != 6 { result.problems.append("only \(back)/6 loops returned to sprites after hover") }

        // Paused: no draws at all.
        let pausedHost = NSHostingView(rootView: Gallery(model: model).environment(\.nbLoopsPaused, true))
        panel.contentView = pausedHost
        spin(1.8)  // the new host's one-shots (the check drawing on) finish first
        NBDesignProbe.glyphDraws = 0
        spin(0.8)
        if NBDesignProbe.glyphDraws > 0 {
            result.problems.append("nbLoopsPaused: \(NBDesignProbe.glyphDraws) glyph draws while paused")
        } else {
            result.report.append("live: nbLoopsPaused stops every loop (0 draws)")
        }
        if idleDraws > 30 {
            result.problems.append("\(idleDraws) glyph draws in a second with nothing animating")
        }
        model.loops = false
        spin(0.2)
        return result
    }
}
