import AppKit
import SwiftUI
import NotchBuddyCore

/// `NotchBuddy --render-timer-system <dir>`: draws the timer and system widgets, their live activities,
/// notices and settings with made-up data to PNGs (inside the island's silhouette, hanging from the top edge of
/// a desktop), plus filmstrips of the animations, then exits. No timers, sampling or notifications run; the
/// real readers are called once and their readings printed (a check that they work on this Mac).
@MainActor
enum TimerSystemPreviewRenderer {
    nonisolated static let flag = "--render-timer-system"

    nonisolated static func requestedDirectory(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        return index + 1 < arguments.count ? arguments[index + 1] : "build/timer-system-previews"
    }

    static let floating = IslandMetrics(style: .floating, notchWidth: 0,
                                        barHeight: IslandMetrics.floatingBarHeight(menuBar: 30), menuBarHeight: 30)
    static let notched = IslandMetrics(style: .notch, notchWidth: 188, barHeight: 37, menuBarHeight: 37)
    static let pageWidth: CGFloat = 492

    static func run(outputDirectory: String) -> Int32 {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot create \(directory.path): \(error)\n".utf8))
            return 1
        }
        NSApp.setActivationPolicy(.accessory)
        print("manrope: \(GadgetFont.registerIfNeeded() ? "registered" : "missing (system font)")")
        printLiveReadings()

        let fake = FakeGadgets()
        var failures = 0
        var sheet: [CGImage] = []

        func save(_ name: String, _ image: CGImage?, inSheet: Bool = true) {
            guard let image else {
                FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
                failures += 1
                return
            }
            if inSheet { sheet.append(image) }
            if !write(image, to: directory.appendingPathComponent("\(name).png")) { failures += 1 }
        }

        // Timer widget.
        for (name, store) in fake.timerScenes() {
            save("timer-widget-\(name)", page(metrics: floating) { TimerWidgetView(store: store, metrics: floating, openSettings: {}) })
        }
        save("timer-widget-multi-notch", page(metrics: notched) {
            TimerWidgetView(store: fake.multiStore(), metrics: notched, openSettings: {})
        })
        save("timer-widget-done-burst", page(metrics: floating, filmTime: 0.62) {
            TimerWidgetView(store: fake.doneStore(), metrics: floating)
        }, inSheet: false)

        // Timer live activities.
        for (name, view) in fake.timerLiveScenes() {
            save("timer-live-\(name)", pill(metrics: name.hasSuffix("notch") ? notched : floating) { view })
        }

        // Timer notice.
        save("timer-notice", pill(metrics: floating, ear: IslandLayout.openEar, bottom: IslandLayout.openBottom, filmTime: 0.7) {
            TimerFinishNoticeView(store: fake.doneStore(), finish: fake.finish, metrics: floating)
        })
        save("timer-notice-notch", pill(metrics: notched, ear: IslandLayout.openEar, bottom: IslandLayout.openBottom) {
            TimerFinishNoticeView(store: fake.doneStore(), finish: fake.finish, metrics: notched)
        })
        save("motion-timer-celebration", filmstrip(times: [0, 0.08, 0.16, 0.26, 0.36, 0.46, 0.58, 0.72, 0.9, 1.15, 1.6]) { t in
            TimerCelebrationFrame(t: t, size: 96, lineWidth: 7.5)
                .frame(width: 150, height: 150)
                .background(Color.black)
        }, inSheet: false)
        save("motion-timer-ring", filmstrip(times: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) { t in
            let store = fake.urgentStore(left: 10.4 - t)
            return ZStack {
                if let timer = store.primary {
                    TimerDial(timer: timer, now: store.now, tint: store.tint(for: timer))
                }
            }
            .frame(width: 130, height: 130)
            .background(Color.black)
        }, inSheet: false)

        // System widget.
        for (name, monitor) in fake.systemScenes() {
            save("system-widget-\(name)", page(metrics: floating) { SystemWidgetView(monitor: monitor, metrics: floating, openSettings: {}) })
        }
        save("system-widget-notch", page(metrics: notched) {
            SystemWidgetView(monitor: fake.monitor(.battery), metrics: notched, openSettings: {})
        })
        save("motion-system-gauges", filmstrip(times: [0, 0.1, 0.18, 0.26, 0.36, 0.5, 0.7, 1.0, 1.5]) { t in
            HStack(spacing: 8) {
                GaugeTile(title: "ЦП", glyph: .chip, value: 0.37, tint: SystemPalette.cpu, format: SystemFormat.percent,
                          detail: "10 ядер", delay: 0.1)
                GaugeTile(title: "Память", glyph: .memory, value: 0.62, tint: SystemPalette.memory,
                          format: { SystemFormat.bytes(UInt64(Double(24 << 30) * $0), binary: true) }, detail: "из 24 ГБ", delay: 0.14)
            }
            .frame(width: 300)
            .padding(10)
            .background(Color.black)
            .environment(\.islandFilmTime, t)
        }, inSheet: false)

        // Battery live activity and notices.
        for (name, state) in [("low", fake.lowBattery), ("critical", fake.criticalBattery)] {
            save("battery-live-\(name)", pill(metrics: floating) { BatteryLiveActivityView(state: state, metrics: floating) })
            save("battery-live-\(name)-notch", pill(metrics: notched) { BatteryLiveActivityView(state: state, metrics: notched) })
        }
        for (name, event, state) in fake.batteryNotices() {
            save("battery-notice-\(name)", pill(metrics: floating, ear: IslandLayout.openEar, bottom: IslandLayout.openBottom) {
                BatteryNoticeView(event: event, state: state, metrics: floating)
            })
        }

        // Settings.
        save("settings", settings(fake))

        save("timer-system-sheet", IslandPreviewRenderer.stitch(sheet, columns: 3, header: nil), inSheet: false)

        // The real store and monitor, hosted off screen: ticks, the finish, sampling.
        for problem in LiveGadgetCheck.run() {
            FileHandle.standardError.write(Data("live-check: \(problem)\n".utf8))
            failures += 1
        }
        return failures == 0 ? 0 : 1
    }

    // MARK: Frames

    private static func image<V: View>(_ view: V, filmTime: Double? = nil) -> CGImage? {
        IslandPreviewRenderer.image(view.environment(\.islandStaticRender, filmTime == nil)
            .environment(\.islandFilmTime, filmTime))
    }

    /// An open island (a widget page) hanging from the top edge of a desktop.
    private static func page<V: View>(metrics: IslandMetrics, filmTime: Double? = nil, @ViewBuilder _ content: () -> V) -> CGImage? {
        let view = content()
            .padding(.top, metrics.style == .notch ? 0 : 2)
            .frame(width: pageWidth)
        return image(Backdrop(metrics: metrics, ear: IslandLayout.openEar, bottom: IslandLayout.openBottom) { view }, filmTime: filmTime)
    }

    /// A closed island (a live activity) or a notice.
    private static func pill<V: View>(metrics: IslandMetrics, ear: CGFloat? = nil, bottom: CGFloat? = nil, filmTime: Double? = nil,
                                      @ViewBuilder _ content: () -> V) -> CGImage? {
        let view = content()
        return image(Backdrop(metrics: metrics, ear: ear ?? IslandLayout.closedEar(metrics),
                              bottom: bottom ?? IslandLayout.closedBottom(metrics), minWidth: 560) { view }, filmTime: filmTime)
    }

    private static func filmstrip<V: View>(times: [Double], _ frame: (Double) -> V) -> CGImage? {
        let frames = times.compactMap { t in
            IslandPreviewRenderer.image(VStack(spacing: 4) {
                frame(t)
                Text(String(format: "%.2f s", t))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .environment(\.islandFilmTime, t))
        }
        return IslandPreviewRenderer.stitch(frames, columns: frames.count, header: nil, spacing: 8, padding: 16)
    }

    private static func settings(_ fake: FakeGadgets) -> CGImage? {
        let view = VStack(alignment: .leading, spacing: 18) {
            TimerSettingsSection(preferences: fake.timerPreferences)
            SystemSettingsSection(preferences: fake.systemPreferences)
        }
        .padding(18)
        .frame(width: 472)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.black))
        .padding(24)
        .background(Color(white: 0.12))
        return image(view)
    }

    private static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            print(url.path)
            return true
        } catch {
            FileHandle.standardError.write(Data("failed to write \(url.path): \(error)\n".utf8))
            return false
        }
    }

    /// One reading from each real source (no sampling loop, no notifications).
    private static func printLiveReadings() {
        if let battery = BatteryState.read() {
            print("battery: \(battery.percent) % phase=\(battery.phase) left=\(battery.minutesLeft.map(String.init) ?? "-") min lpm=\(battery.lowPowerMode)")
        } else {
            print("battery: none")
        }
        if let a = CPUTicks.read() {
            usleep(250_000)
            if let b = CPUTicks.read(), let usage = CPULoad.usage(from: a, to: b) {
                print("cpu: \(SystemFormat.percent(usage)) over 0.25 s, \(CPULoad.coreCount) cores")
            }
        }
        if let memory = MemoryUsage.read() {
            print("memory: \(SystemFormat.bytes(memory.used, binary: true)) of \(SystemFormat.bytes(memory.total, binary: true)) pressure=\(memory.pressure) swap=\(SystemFormat.bytes(memory.swapUsed, binary: true))")
        }
        if let disk = DiskUsage.read() {
            print("disk: \(SystemFormat.bytes(disk.free, binary: false)) free of \(SystemFormat.bytes(disk.total, binary: false))")
        }
    }
}

/// Runs a real `TimerStore` (a 2.4 s timer) and `SystemMonitor` with their widgets hosted in a window placed off
/// every screen (nothing shows, nothing takes focus) and checks what they did.
@MainActor
private enum LiveGadgetCheck {
    static func run() -> [String] {
        var problems: [String] = []
        let suite = "notchbuddy.previews.live"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let prefs = TimerPreferences(defaults: defaults)
        prefs.sound = ""
        let store = TimerStore(preferences: prefs, restore: false)
        var finishes: [(TimerFinish, TimeInterval)] = []
        store.onFinish = { finishes.append(($0, AppClock.monotonicSeconds())) }
        store.start()
        let monitor = SystemMonitor(preferences: SystemPreferences(defaults: defaults))
        monitor.start()

        let root = VStack(spacing: 0) {
            TimerWidgetView(store: store, metrics: TimerSystemPreviewRenderer.floating)
            TimerLiveActivity(store: store, metrics: TimerSystemPreviewRenderer.floating)
            SystemWidgetView(monitor: monitor, metrics: TimerSystemPreviewRenderer.floating)
        }
        .environment(\.colorScheme, .dark)
        let window = NSPanel(contentRect: NSRect(x: -30000, y: -30000, width: 560, height: 1200),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        defer {
            store.stop()
            monitor.stop()
            window.orderOut(nil)
            window.contentView = nil
        }

        // Two timers out of phase: A (3 s) now, B (2 s) 0.45 s later. Each shown second changes on its own
        // schedule; B ends first.
        let started = AppClock.monotonicSeconds()
        guard store.start(seconds: 3, label: "А") != nil else { return ["could not start a timer"] }
        var bStarted: TimeInterval?
        var ticks: [TimeInterval] = []
        var last = store.now
        while AppClock.monotonicSeconds() - started < 4.2 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            if bStarted == nil, AppClock.monotonicSeconds() - started >= 0.45 {
                bStarted = AppClock.monotonicSeconds() - started
                store.start(seconds: 2, label: "Б")
                last = store.now
            }
            if store.now != last {
                last = store.now
                ticks.append(store.now.monotonic - started)
            }
        }
        let b = bStarted ?? 0.45
        print("live-check: B started at \(String(format: "%.3f", b)); ticks at \(ticks.map { String(format: "%.3f", $0) }.joined(separator: " "))")
        for (finish, at) in finishes {
            print("live-check: finish \"\(finish.label)\" at \(String(format: "%.3f", at - started)) s, lateness \(String(format: "%.3f", finish.lateness))")
        }
        let deadlines = ["Б": b + 2, "А": 3.0]
        if finishes.map(\.0.label) != ["Б", "А"] { problems.append("finishes \(finishes.map(\.0.label))") }
        for (finish, at) in finishes {
            let late = at - started - (deadlines[finish.label] ?? 0)
            if late < -0.001 || late > 0.1 { problems.append("\(finish.label) finished \(late) s off its deadline") }
        }
        if !store.isEmpty { problems.append("finished timers are still in the store") }
        if store.recentFinish?.label != "А" { problems.append("recent finish is \(String(describing: store.recentFinish?.label))") }
        for e in [1.0, b + 1, 2.0] where !ticks.contains(where: { abs($0 - e) < 0.06 }) {
            problems.append("no tick near \(e) s")
        }
        if ticks.contains(where: { t in ![1.0, b + 1, 2.0, b + 2, 3.0].contains { abs($0 - t) < 0.06 } }) {
            problems.append("a tick when no shown second changed")
        }
        if monitor.sampleCount < 2 || monitor.cpu == nil || monitor.memory == nil {
            problems.append("system sampling: \(monitor.sampleCount) samples, cpu \(String(describing: monitor.cpu))")
        } else {
            print("live-check: system \(monitor.sampleCount) samples, cpu \(SystemFormat.percent(monitor.cpu ?? 0)), memory \(SystemFormat.percent(monitor.memory?.fraction ?? 0)), disk \(monitor.disk.map { SystemFormat.bytes($0.free, binary: false) } ?? "-") free")
        }
        // Sampling stops with the last view.
        window.contentView = nil
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        let after = monitor.sampleCount
        let until = AppClock.monotonicSeconds() + 2.3
        while AppClock.monotonicSeconds() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        if monitor.sampleCount != after { problems.append("sampling kept running with no view on screen") }
        return problems
    }
}

/// The island's silhouette around `content`, hanging from the top of a desktop with a menu bar.
private struct Backdrop<Content: View>: View {
    let metrics: IslandMetrics
    let ear: CGFloat
    let bottom: CGFloat
    var minWidth: CGFloat = 0
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, ear)
            .background(alignment: .top) {
                IslandShape(earRadius: ear, bottomRadius: bottom)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 40)
            .frame(minWidth: minWidth, alignment: .top)
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    LinearGradient(colors: [Color(red: 0.13, green: 0.2, blue: 0.34), Color(red: 0.33, green: 0.22, blue: 0.42),
                                            Color(red: 0.66, green: 0.4, blue: 0.36)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Rectangle().fill(Color.white.opacity(0.1)).frame(height: metrics.menuBarHeight)
                }
            }
    }
}

// MARK: - Fake data

@MainActor
private struct FakeGadgets {
    let now = Moment(wall: FakeGadgets.date(14, 23), monotonic: 50_000)
    let timerPreferences = TimerPreferences(defaults: FakeGadgets.defaults("timer"))
    let systemPreferences = SystemPreferences(defaults: FakeGadgets.defaults("system"))

    static func date(_ hour: Int, _ minute: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 30; c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c) ?? Date()
    }

    static func defaults(_ name: String) -> UserDefaults {
        let suite = "notchbuddy.previews.\(name)"
        let d = UserDefaults(suiteName: suite) ?? .standard
        d.removePersistentDomain(forName: suite)
        return d
    }

    var finish: TimerFinish {
        TimerFinish(id: UUID(uuidString: "00000000-0000-0000-0000-00000000F1F1")!, label: "Помодоро", duration: 1500,
                    finishedAt: now, lateness: 0)
    }

    /// A timer started `elapsed` seconds ago, running (or paused after `pausedAfter`).
    func item(_ label: String, minutes: Double, elapsed: Double, paused: Bool = false, id: Int) -> TimerItem {
        let duration = minutes * 60
        let state: TimerItem.State = paused ? .paused(remaining: duration - elapsed)
            : .running(deadline: now.monotonic + duration - elapsed)
        return TimerItem(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!, label: label,
                         duration: duration, state: state, startedAt: now.wall.addingTimeInterval(-elapsed))
    }

    func store(_ items: [TimerItem], finish: TimerFinish? = nil) -> TimerStore {
        TimerStore(frozenAt: now, engine: TimerEngine(timers: items), recentFinish: finish, preferences: timerPreferences)
    }

    func multiStore() -> TimerStore {
        store([item("Помодоро", minutes: 25, elapsed: 12 * 60 + 13, id: 1),
               item("Паста", minutes: 18, elapsed: 90, id: 2),
               item("Стирка", minutes: 55, elapsed: 23 * 60, paused: true, id: 3)])
    }

    func doneStore() -> TimerStore {
        store([item("Паста", minutes: 18, elapsed: 90, id: 2)], finish: finish)
    }

    func urgentStore(left: Double) -> TimerStore {
        store([item("Чай", minutes: 3, elapsed: 180 - left, id: 4)])
    }

    func timerScenes() -> [(String, TimerStore)] {
        [
            ("empty", store([])),
            ("running", store([item("Помодоро", minutes: 25, elapsed: 10 * 60 + 47, id: 1)])),
            ("multi", multiStore()),
            ("paused", store([item("Созвон", minutes: 10, elapsed: 3 * 60 + 25, paused: true, id: 5)])),
            ("urgent", urgentStore(left: 7.3)),
            ("done", doneStore()),
        ]
    }

    func timerLiveScenes() -> [(String, AnyView)] {
        let running = item("Помодоро", minutes: 25, elapsed: 10 * 60 + 47, id: 1)
        let tea = item("Чай", minutes: 3, elapsed: 40, id: 4)
        let paused = item("Созвон", minutes: 10, elapsed: 3 * 60 + 25, paused: true, id: 5)
        let urgent = item("Чай", minutes: 3, elapsed: 180 - 6.4, id: 4)
        var scenes: [(String, AnyView)] = []
        for (suffix, metrics) in [("floating", TimerSystemPreviewRenderer.floating), ("notch", TimerSystemPreviewRenderer.notched)] {
            scenes.append(("running-\(suffix)", AnyView(TimerLiveActivityView(timer: running, now: now, tint: TimerPalette.tomato,
                                                                             others: 0, metrics: metrics))))
            scenes.append(("others-\(suffix)", AnyView(TimerLiveActivityView(timer: tea, now: now, tint: TimerPalette.violet,
                                                                            others: 2, metrics: metrics))))
            scenes.append(("paused-\(suffix)", AnyView(TimerLiveActivityView(timer: paused, now: now, tint: TimerPalette.coral,
                                                                            metrics: metrics))))
            scenes.append(("urgent-\(suffix)", AnyView(TimerLiveActivityView(timer: urgent, now: now, tint: TimerPalette.coral,
                                                                            metrics: metrics))))
            scenes.append(("done-\(suffix)", AnyView(TimerLiveActivityView(timer: nil, finish: finish, now: now, tint: TimerPalette.done,
                                                                          metrics: metrics))))
        }
        return scenes
    }

    // MARK: System

    enum Power { case battery, charging, low, desktop, busy }

    let history: [Double] = [0.18, 0.22, 0.2, 0.31, 0.46, 0.38, 0.29, 0.24, 0.26, 0.52, 0.71, 0.64, 0.41, 0.33, 0.28,
                             0.25, 0.3, 0.27, 0.22, 0.35, 0.44, 0.39, 0.3, 0.26, 0.21, 0.24, 0.29, 0.34, 0.31, 0.37]

    var lowBattery: BatteryState { BatteryState(percent: 14, onAC: false, charging: false, minutesToEmpty: 26) }
    var criticalBattery: BatteryState { BatteryState(percent: 6, onAC: false, charging: false, minutesToEmpty: 9) }

    func monitor(_ power: Power) -> SystemMonitor {
        let memory = MemoryUsage(used: UInt64(14.9 * 1_073_741_824), total: 24 << 30)
        let disk = DiskUsage(free: 312_400_000_000, total: 994_700_000_000)
        switch power {
        case .battery:
            return SystemMonitor(frozenBattery: BatteryState(percent: 64, onAC: false, charging: false, minutesToEmpty: 192),
                                 cpu: 0.37, history: history, memory: memory, disk: disk, preferences: systemPreferences)
        case .charging:
            return SystemMonitor(frozenBattery: BatteryState(percent: 41, onAC: true, charging: true, minutesToFull: 48,
                                                             lowPowerMode: true),
                                 cpu: 0.12, history: history.map { $0 * 0.5 }, memory: memory, disk: disk, preferences: systemPreferences)
        case .low:
            return SystemMonitor(frozenBattery: lowBattery, cpu: 0.58, history: history.map { min($0 * 1.5, 1) },
                                 memory: MemoryUsage(used: 21 << 30, total: 24 << 30, pressure: .warning), disk: disk,
                                 preferences: systemPreferences)
        case .desktop:
            return SystemMonitor(frozenBattery: nil, cpu: 0.22, history: history, memory: memory,
                                 disk: DiskUsage(free: 61_000_000_000, total: 494_000_000_000), preferences: systemPreferences)
        case .busy:
            return SystemMonitor(frozenBattery: BatteryState(percent: 80, onAC: true, charging: false),
                                 cpu: 0.93, history: history.map { min($0 * 2.4, 1) },
                                 memory: MemoryUsage(used: UInt64(23.1 * 1_073_741_824), total: 24 << 30, pressure: .critical),
                                 disk: disk, thermal: .serious, preferences: systemPreferences)
        }
    }

    func systemScenes() -> [(String, SystemMonitor)] {
        [("battery", monitor(.battery)), ("charging", monitor(.charging)), ("low", monitor(.low)),
         ("busy", monitor(.busy)), ("desktop", monitor(.desktop))]
    }

    func batteryNotices() -> [(String, BatteryEvent, BatteryState)] {
        [("plugged", .pluggedIn(percent: 23, charging: true), BatteryState(percent: 23, onAC: true, charging: true, minutesToFull: 95)),
         ("low", .low(percent: 20), BatteryState(percent: 20, onAC: false, charging: false, minutesToEmpty: 38)),
         ("full", .full, BatteryState(percent: 100, onAC: true, charging: false, charged: true))]
    }
}

extension TimerSystemPreviewRenderer {
    /// Three timers (one paused), for the island's widget films.
    static func sampleTimerStore() -> TimerStore { FakeGadgets().multiStore() }
    /// A timer in its last seconds.
    static func sampleUrgentTimerStore() -> TimerStore { FakeGadgets().urgentStore(left: 7.3) }
    /// On battery (or low on it), for the island's widget films.
    static func sampleSystemMonitor(low: Bool = false) -> SystemMonitor { FakeGadgets().monitor(low ? .low : .battery) }
}
