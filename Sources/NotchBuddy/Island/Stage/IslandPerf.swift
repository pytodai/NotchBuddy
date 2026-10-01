import AppKit
import Metal
import NotchBuddyCore
import QuartzCore

// MARK: - Probe

/// Debug-only frame-pacing probe (`NOTCHBUDDY_PERF=1`). Every island transition (a mode change, the closed
/// island's hover grow) is measured for a fixed window and reported as one line in
/// `~/Library/Logs/NotchBuddy/perf.log` (under `NOTCHBUDDY_HOME` when set):
///
/// - `main`: display-refresh callbacks on the main run loop (`NSScreen.displayLink`). A SwiftUI animation
///   advances only in such a tick, so for main-thread-driven motion these *are* the animation frames; for
///   Core Animation motion (`IslandStage`) they only show how busy the main thread was.
/// - `comp`: what the window server actually put on screen: a 2 pt, practically transparent Metal layer in the
///   island's panel (its empty top-left corner) is redrawn from a user-interactive background thread on every
///   vsync, and each drawable reports when it was displayed (`presentedTime`). This is the cadence at which the
///   window server composites the panel, i.e. the frame rate of render-server-driven motion; `lost` counts
///   drawables that were never displayed.
/// - `work`: how many times island code did per-frame work on the main thread during the window (a SwiftUI
///   silhouette path evaluated, an animatable effect updated), counted by `IslandPerf.note`. Zero means the
///   motion did not depend on the main thread at all.
/// - `latency`: from the change to the moment the silhouette's motion was committed ("measure, then move").
/// - `stall`: the longest a block posted to the main run loop waited (sampled every 4 ms).
///
/// A frame is "dropped" when it came more than 1.5 refresh intervals after the one before.
@MainActor
final class IslandPerf {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["NOTCHBUDDY_PERF"] == "1"
    static let shared: IslandPerf? = enabled ? IslandPerf() : nil

    /// Per-frame main-thread work of the island (a cheap no-op unless the probe is on).
    nonisolated static func note(_ what: StaticString) {
        guard enabled, Thread.isMainThread else { return }
        MainActor.assumeIsolated { shared?.work += 1 }
    }

    private struct Measurement {
        var name: String
        var start: CFTimeInterval
        var end: CFTimeInterval
        var main: [CFTimeInterval] = []
        var refresh: CFTimeInterval = 1.0 / 60
        var committed: CFTimeInterval?
    }

    private var current: Measurement?
    private var finishTask: Task<Void, Never>?
    private var mainLink: CADisplayLink?
    private let background = BackgroundSampler()
    fileprivate var work = 0
    private let logURL = Paths.logsDir.appendingPathComponent("perf.log")

    private init() {
        try? FileManager.default.createDirectory(at: Paths.logsDir, withIntermediateDirectories: true)
        write("# \(Date()) probe on, pid \(getpid()), \(ProcessInfo.processInfo.activeProcessorCount) cores, load \(Self.loadAverage())")
    }

    /// A transition starts now; it is measured for `window` seconds. One still being measured is cut short and
    /// reported (marked `~`).
    /// The next transition is reported under this name (the on-screen check's opening, not a regular one).
    var renameNext: String?
    /// …and measured this long (a grab: its fold, the drag and the settle).
    var windowNext: TimeInterval?

    func transition(_ name: String, window: TimeInterval = 0.5) {
        let name = renameNext ?? name
        let window = windowNext ?? window
        renameNext = nil
        windowNext = nil
        let now = CACurrentMediaTime()
        if let current { finish(interrupted: now < current.end) }
        current = Measurement(name: name, start: now, end: now + window * IslandMotion.slowmo)
        work = 0
        background.begin()
        startMainLink()
        finishTask?.cancel()
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(window * IslandMotion.slowmo * 1000) + 30))
            guard !Task.isCancelled else { return }
            self?.finish(interrupted: false)
        }
    }

    /// The silhouette's motion of the transition being measured was committed now.
    func motionCommitted() {
        guard current != nil, current?.committed == nil else { return }
        current?.committed = CACurrentMediaTime()
    }

    /// The compositor probe lives in the island's panel (its top-left corner, where nothing is drawn).
    func attach(to view: NSView) {
        background.attach(to: view)
    }

    /// The benchmark's names for mode changes.
    nonisolated static func name(from old: IslandMode, to new: IslandMode) -> String {
        if old != new, old.tab != nil, new.tab != nil { return "tab" }
        switch (old, new) {
        case (.collapsed, .expanded), (.idle, .expanded): return "open"
        case (.expanded, .collapsed), (.expanded, .idle): return "close"
        case (.collapsed, .flash), (.idle, .flash): return "flash"
        case (.flash, .flash): return "flash-next"
        case (.flash, .collapsed), (.flash, .idle): return "flash-out"
        case (.collapsed, .permission), (.idle, .permission): return "card"
        case (.permission, .permission): return "cardAdvance"
        case (.permission, .collapsed), (.permission, .idle): return "card-out"
        default: return "\(old)-\(new)"
        }
    }

    /// A free-form line in the log (benchmark markers).
    func mark(_ text: String) {
        write("# \(text) load \(Self.loadAverage())")
    }

    private func startMainLink() {
        guard mainLink == nil, let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(mainTick(_:)))
        link.add(to: .main, forMode: .common)
        mainLink = link
    }

    @objc private func mainTick(_ link: CADisplayLink) {
        guard var m = current else { return }
        let now = CACurrentMediaTime()
        if now > m.end { return }
        m.main.append(now)
        let refresh = link.targetTimestamp - link.timestamp
        if refresh > 0.002, refresh < 0.05 { m.refresh = refresh }
        current = m
    }

    private func finish(interrupted: Bool) {
        finishTask?.cancel()
        finishTask = nil
        mainLink?.invalidate()
        mainLink = nil
        guard let m = current else { return }
        current = nil
        let bg = background.end()
        let refresh = m.refresh
        let main = Self.stats(m.main, from: m.start, refresh: refresh)
        let presented = bg.presented.filter { $0 > m.start && $0 <= m.end }.sorted()
        let comp = Self.stats(presented, from: presented.first ?? m.start, refresh: refresh)
        let submitted = bg.submitted.filter { $0 > m.start && $0 <= m.end }.sorted()
        let sub = Self.stats(submitted, from: submitted.first ?? m.start, refresh: refresh)
        // Frames the window server skipped although the probe had drawn one: a display gap with a drawable waiting.
        var serverDrops = 0
        for (a, b) in zip(presented, presented.dropFirst()) where b - a > 1.5 * refresh {
            if submitted.contains(where: { $0 > a && $0 < b - refresh }) { serverDrops += 1 }
        }
        let latency = m.committed.map { ($0 - m.start) * 1000 } ?? -1
        let line = String(format: "%@%@ main[frames %d fps %.1f worst %.1fms dropped %d] comp[frames %d fps %.1f worst %.1fms dropped %d lost %d] probe[worst %.1fms server-drops %d] latency %.0fms stall %.1fms work %d refresh %.2fms load %@",
                          interrupted ? "~" : "", m.name.padding(toLength: 12, withPad: " ", startingAt: 0),
                          main.frames, main.fps, main.worst * 1000, main.dropped,
                          comp.frames, comp.fps, comp.worst * 1000, comp.dropped, bg.lost,
                          sub.worst * 1000, serverDrops,
                          latency, bg.stall * 1000, work, refresh * 1000, Self.loadAverage())
        write(line)
    }

    private struct Stats {
        var frames = 0
        var fps = 0.0
        var worst = 0.0
        var dropped = 0
    }

    /// Intervals between consecutive frames, the first measured from `start`.
    private static func stats(_ times: [CFTimeInterval], from start: CFTimeInterval, refresh: CFTimeInterval) -> Stats {
        guard let last = times.last else { return Stats() }
        var previous = start
        var s = Stats(frames: times.count)
        for t in times {
            let dt = t - previous
            s.worst = max(s.worst, dt)
            if dt > 1.5 * refresh { s.dropped += 1 }
            previous = t
        }
        // Frames per second over the window's span (a first frame at `start` itself opens the span, it is no interval).
        let span = last - start
        let intervals = times.first == start ? times.count - 1 : times.count
        s.fps = span > 0 ? Double(intervals) / span : 0
        return s
    }

    private func write(_ line: String) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    static func loadAverage() -> String {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return String(format: "%.1f", loads[0])
    }
}

/// The probe's off-main-thread half: a user-interactive thread with its own display link (vsync as the system
/// delivers it) that redraws the compositor probe, and a pinger that measures how long blocks wait for the main
/// run loop.
private final class BackgroundSampler: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var measuring = false
    private var presented: [CFTimeInterval] = []
    private var submitted: [CFTimeInterval] = []
    private var lost = 0
    private var stall: CFTimeInterval = 0
    private var thread: Thread?
    private let metal: CAMetalLayer? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.maximumDrawableCount = 3
        layer.allowsNextDrawableTimeout = true
        layer.drawableSize = CGSize(width: 4, height: 4)
        return layer
    }()
    private lazy var queue = metal?.device?.makeCommandQueue()
    private var tick = 0
    private nonisolated(unsafe) var link: CADisplayLink?
    private var pingInFlight = false

    struct Result {
        var presented: [CFTimeInterval]
        /// When the probe drew each frame (a gap here is the probe's own thread starved, not the window server).
        var submitted: [CFTimeInterval]
        var lost: Int
        var stall: CFTimeInterval
    }

    @MainActor
    func attach(to view: NSView) {
        guard let metal else { return }
        view.wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.frame = CGRect(x: 1, y: view.bounds.height - 3, width: 2, height: 2)
        metal.autoresizingMask = [.layerMinYMargin]
        metal.zPosition = 1000
        view.layer?.addSublayer(metal)
        CATransaction.commit()
    }

    @MainActor
    func begin() {
        lock.withLock {
            measuring = true
            presented = []
            submitted = []
            lost = 0
            stall = 0
        }
        guard thread == nil else { return }
        // Made here (the screen is main-thread state), run on the sampler's own thread.
        link = NSScreen.main?.displayLink(target: self, selector: #selector(vsync(_:)))
        let thread = Thread { [weak self] in self?.run() }
        thread.qualityOfService = .userInteractive
        thread.name = "NotchBuddy perf probe"
        thread.start()
        self.thread = thread
    }

    func end() -> Result {
        lock.withLock {
            measuring = false
            return Result(presented: presented, submitted: submitted, lost: lost, stall: stall)
        }
    }

    private func run() {
        link?.add(to: .current, forMode: .default)
        let pinger = Timer(timeInterval: 0.004, repeats: true) { [weak self] _ in self?.ping() }
        RunLoop.current.add(pinger, forMode: .default)
        RunLoop.current.run()
    }

    /// Redraws the compositor probe (a clear, alternating between two nearly transparent blacks) and notes when the
    /// window server displayed it. Drawn on every vsync once the probe runs, so a measurement never sees it wake up.
    @objc private func vsync(_ link: CADisplayLink) {
        guard let metal, let queue,
              let drawable = metal.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        tick &+= 1
        let now = CACurrentMediaTime()
        lock.withLock { if measuring { submitted.append(now) } }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: tick % 2 == 0 ? 0.004 : 0.008)
        buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        drawable.addPresentedHandler { [weak self] shown in
            let time = shown.presentedTime
            guard let self else { return }
            self.lock.withLock {
                guard self.measuring else { return }
                if time > 0 { self.presented.append(time) } else { self.lost += 1 }
            }
        }
        buffer.present(drawable)
        buffer.commit()
    }

    private func ping() {
        let go: Bool = lock.withLock {
            guard measuring, !pingInFlight else { return false }
            pingInFlight = true
            return true
        }
        guard go else { return }
        let sent = CACurrentMediaTime()
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            let waited = CACurrentMediaTime() - sent
            guard let self else { return }
            self.lock.withLock {
                self.pingInFlight = false
                if self.measuring { self.stall = max(self.stall, waited) }
            }
        }
        CFRunLoopWakeUp(main)
    }
}

// MARK: - Debug trigger

/// `NOTCHBUDDY_PERF=1` only: a benchmark script drives the real island through its transitions with fake
/// sessions by posting the distributed notification `me.sokolov.notchbuddy.perf` with `userInfo["action"]` =
/// `open` | `close` | `flash` | `card` | `cardAdvance` | `hover` | `drag <dx>` | `grab <dx>` (and the helpers `seed`, `dismiss`,
/// `clearCards`, `mark`, `style notch|island`, `offset <x>`, `quit`). `NotchBuddy --perf-send <action> [text]` posts one
/// and exits.
enum IslandPerfTrigger {
    static let notification = Notification.Name("me.sokolov.notchbuddy.perf")
    static let sendFlag = "--perf-send"

    static func sendIfRequested(_ arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: sendFlag), index + 1 < arguments.count else { return false }
        var info: [String: String] = ["action": arguments[index + 1]]
        if index + 2 < arguments.count { info["text"] = arguments[(index + 2)...].joined(separator: " ") }
        DistributedNotificationCenter.default().postNotificationName(notification, object: nil, userInfo: info,
                                                                     deliverImmediately: true)
        return true
    }
}

/// Fake agent sessions, fed through `AppModel.handle` exactly as socket events are (`NOTCHBUDDY_PERF=1` only).
@MainActor
final class IslandPerfHarness {
    private let model: AppModel
    private let island: IslandController
    private var observer: NSObjectProtocol?
    private let home = "/Users/demo"

    static let claude = SessionKey(source: .claude, sessionId: "perf-claude")
    static let codex = SessionKey(source: .codex, sessionId: "perf-codex")
    static let kimi = SessionKey(source: .kimi, sessionId: "perf-kimi")

    init(model: AppModel, island: IslandController) {
        self.model = model
        self.island = island
    }

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: IslandPerfTrigger.notification, object: nil, queue: .main
        ) { [weak self] note in
            let action = note.userInfo?["action"] as? String ?? ""
            let text = note.userInfo?["text"] as? String ?? ""
            MainActor.assumeIsolated { self?.run(action, text: text) }
        }
        Log.info("perf: harness listening for \(IslandPerfTrigger.notification.rawValue)")
    }

    private func run(_ action: String, text: String) {
        switch action {
        case "seed": seed()
        case "open": island.perfSetOpen(true)
        case "hoverOpen":
            // As a resting pointer does it: the hover grow, then the list ~0.12 s later. From a capsule moved aside
            // (`offset`) it is reported as "open-offset" (the list slides inward as it grows).
            island.perfHover(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.island.perfShifted { IslandPerf.shared?.renameNext = "open-offset" }
                    self.island.perfSetOpen(true)
                }
            }
        case "close":
            if island.perfShifted { IslandPerf.shared?.renameNext = "close-offset" }
            island.perfSetOpen(false)
        case "hover": island.perfToggleHover()
        case "flash": finish(Self.claude)
        case "dismiss": model.dismissFlash()
        case "card": request(Self.claude, command: "rm -rf .build && swift build -c release && ./scripts/build-app.sh --install")
        case "cardAdvance":
            if model.pendingPermissions.count < 2 {
                request(Self.codex, command: "npm ci && npm test -- --watch=false")
            }
            if let front = model.pendingPermissions.first { model.decide(front.id, .deny(reason: nil)) }
        case "clearCards":
            for pending in model.pendingPermissions { model.decide(pending.id, .deny(reason: nil)) }
            seed()
        case "tabs":
            // The strip with these tabs (default: two widgets that need no permission).
            let kinds = (text.isEmpty ? "agents,timer,system" : text).split(separator: ",").compactMap { WidgetKind(rawValue: String($0)) }
            island.perfSetTabs(kinds)
        case "tab": if let kind = WidgetKind(rawValue: text) { island.perfSelectTab(kind) }
        case "tabClick":
            // As a click does it: the pointer rests on the tab (its page is built ahead), then clicks ~0.15 s later.
            guard let kind = WidgetKind(rawValue: text) else { break }
            island.perfPrepareTab(kind)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                MainActor.assumeIsolated { self?.island.perfSelectTab(kind) }
            }
        case "style":
            // «Чёлка» (notch) or «Островок» (island) on the screen the bench runs on; the user's settings stay as they are.
            island.perfSetStyle(IslandStyle(rawValue: text) ?? .notch)
        case "offset":
            // «Островок» moved sideways (points from the center; nothing is saved).
            island.perfSetOffset(CGFloat(Double(text) ?? 0))
        case "drag":
            // The closed capsule dragged sideways by this many points (and let go).
            island.perfDrag(by: CGFloat(Double(text) ?? 300))
        case "grab":
            // The open island grabbed where its capsule sits and pulled sideways by this many points (and let go).
            island.perfGrab(by: CGFloat(Double(text) ?? 300))
        case "mark": IslandPerf.shared?.mark(text)
        case "verify": verify(block: Double(text) ?? 0.3)
        case "quit": NSApp.terminate(nil)
        default: Log.info("perf: unknown action \(action)")
        }
    }

    /// Opens the list and, with the main thread blocked for `block` seconds right after, films the panel from a
    /// background thread (the window server's own picture of it) and compares the silhouette's height in each shot
    /// with the spring's value at that moment: the render server has to play the motion without the app.
    private func verify(block: Double) {
        // Without the stage (the SwiftUI island) there is no model to compare with: only the heights are reported.
        let stage = island.perfStage
        let window = UInt32(island.perfWindowNumber)
        IslandPerf.shared?.renameNext = "verify-open"
        island.perfSetOpen(true)
        let start = CACurrentMediaTime()
        let shots = ScreenShots(window: window, until: start + 0.6, points: Double(island.perfCanvasHeight),
                                column: Double(island.perfIslandColumn))
        shots.run()
        let blockEnd = CACurrentMediaTime() + block
        while CACurrentMediaTime() < blockEnd {}
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                let samples = shots.results()
                var errors: [Double] = []
                var heights: [Double] = []
                for sample in samples {
                    heights.append(sample.height)
                    guard let stage else { continue }
                    // The picture is at most a frame old: the spring anywhere in the frame before the shot counts.
                    let range = stride(from: sample.time - 1.0 / 30, through: sample.time + 1.0 / 120, by: 1.0 / 240)
                        .map { Double(stage.presentedGeometry(at: $0).bottomEdge) }
                    let lo = range.min() ?? 0, hi = range.max() ?? 0
                    let error = sample.height < lo ? lo - sample.height : (sample.height > hi ? sample.height - hi : 0)
                    errors.append(error)
                }
                let during = samples.filter { $0.time < start + block }.count
                let moved = Set(samples.filter { $0.time < start + block }.map { Int($0.height) }).count
                errors.sort()
                let error = errors.isEmpty ? "n/a (SwiftUI island)"
                    : String(format: "median %.1f pt max %.1f pt", errors[errors.count / 2], errors[errors.count - 1])
                IslandPerf.shared?.mark(String(format: "verify block %.0fms: %d shots (%d while blocked, %d distinct heights), height vs spring: %@, heights %@",
                                               block * 1000, samples.count, during, moved, error,
                                               heights.map { String(Int($0)) }.joined(separator: ",")))
                self.island.perfSetOpen(false)
            }
        }
    }

    private func send(_ key: SessionKey, _ kind: EventKind, project: String, tool: String? = nil, summary: String? = nil,
                      message: String? = nil, raw: JSONValue = .null, reply: Bool = false) {
        let event = AgentEvent(source: key.source, hookEventName: "\(kind)", kind: kind, sessionId: key.sessionId,
                               cwd: "\(home)/code/\(project)", toolName: tool, toolSummary: summary, message: message,
                               decisionSupported: reply, canAlwaysAllow: reply && key.source == .claude, raw: raw)
        model.handle(BridgeRequest(event: event, expectsReply: reply), reply: reply ? ReplyHandle.unconnected() : nil)
    }

    /// Three sessions: Claude and Codex working, Kimi finished.
    private func seed() {
        send(Self.claude, .promptSubmitted, project: "weather-app", message: "Сделай графики плавнее")
        send(Self.claude, .toolWillRun, project: "weather-app", tool: "Bash", summary: "swift build -c release 2>&1 | tail -20")
        send(Self.codex, .promptSubmitted, project: "api-gateway", message: "Почини падающие тесты")
        send(Self.codex, .toolWillRun, project: "api-gateway", tool: "exec_command", summary: "npm test -- --watch=false")
        if model.store.sessions[Self.kimi] == nil {
            send(Self.kimi, .promptSubmitted, project: "landing-page", message: "Обнови hero-блок")
            send(Self.kimi, .stop, project: "landing-page", message: "Обновил hero-блок и адаптив для мобильных")
            model.dismissFlash()
        }
    }

    /// The session finishes its turn: a "finished" notice. It is put back to work first, so every call notifies.
    private func finish(_ key: SessionKey) {
        if model.store.sessions[key]?.status != .working {
            send(key, .promptSubmitted, project: "weather-app", message: "Ещё раз")
        }
        send(key, .stop, project: "weather-app", message: "Готово: графики теперь плавные")
    }

    private func request(_ key: SessionKey, command: String) {
        let project = key == Self.claude ? "weather-app" : "api-gateway"
        let tool = key.source == .claude ? "Bash" : "exec_command"
        send(key, .permissionRequest, project: project, tool: tool, summary: command,
             raw: .object(["tool_input": .object(["command": .string(command),
                                                  "description": .string("Пересобрать и установить приложение")])]),
             reply: true)
    }
}

/// The debug benchmark's usage figures: fixed, no keychain, no network.
struct IslandPerfUsage: UsageProviding {
    func fetch() async -> UsageState {
        .loaded(UsageSnapshot(fiveHour: UsageWindow(utilization: 42, resetsAt: Date().addingTimeInterval(7800)),
                              sevenDay: UsageWindow(utilization: 18, resetsAt: Date().addingTimeInterval(270_000)),
                              fetchedAt: Date()))
    }

    func nudge() async {}
}

/// Where a dev instance keeps its single-instance lock: under `NOTCHBUDDY_HOME` when that is set (a benchmark or
/// debugging instance leaves nothing outside its own home), next to the socket otherwise (the installed app).
enum InstanceLockPath {
    static var path: String {
        let env = ProcessInfo.processInfo.environment
        guard let home = env["NOTCHBUDDY_HOME"], !home.isEmpty else { return Paths.socket + ".lock" }
        let socketName = (Paths.socket as NSString).lastPathComponent
        return Paths.runDir.appendingPathComponent(socketName + ".lock").path
    }
}

/// The benchmark's on-screen check: pictures of the island's panel taken by the window server from a background
/// thread (`CGWindowListCreateImage`, looked up at run time: the SDK marks it unavailable; capturing one's own
/// window needs no permission), and the silhouette's height at the canvas' center in each.
private final class ScreenShots: @unchecked Sendable {
    struct Sample {
        /// Media time of the shot (the middle of the call).
        var time: CFTimeInterval
        /// Height of the opaque island at the canvas' center, in points.
        var height: Double
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let create: CreateImage? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    private let window: UInt32
    private let until: CFTimeInterval
    /// The panel's height in points (the picture is in pixels).
    private let points: Double
    /// Where the island's center is across the picture (0…1: the panel spans the screen, the island may be moved).
    private let column: Double
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var done = false

    init(window: UInt32, until: CFTimeInterval, points: Double, column: Double = 0.5) {
        self.window = window
        self.until = until
        self.points = points
        self.column = min(max(column, 0), 1)
    }

    func run() {
        let thread = Thread { [self] in
            guard let create = Self.create else { return }
            while CACurrentMediaTime() < until {
                let before = CACurrentMediaTime()
                // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming
                guard let image = create(.null, 1 << 3, window, 1 << 0)?.takeRetainedValue() else { break }
                let after = CACurrentMediaTime()
                if let pixels = Self.islandHeight(image, column: column) {
                    let height = pixels * points / Double(max(1, image.height))
                    lock.withLock { samples.append(Sample(time: (before + after) / 2, height: height)) }
                }
            }
            lock.withLock { done = true }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func results() -> [Sample] { lock.withLock { samples } }

    /// The lowest opaque row in the image's column at `column` (0…1; the canvas is transparent around the island).
    private static func islandHeight(_ image: CGImage, column: Double) -> Double? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: 1, height: height, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Draw so that the island's center column lands in the 1-pixel-wide context.
        let x = Int((Double(width) * column).rounded())
        context.draw(image, in: CGRect(x: -x, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: 4 * height)
        // A bitmap context keeps its top row first: the island hangs from row 0 (or floats a little below it); find its
        // lowest opaque row. In test runs the panel is at 1 % opacity (`IslandPanel.invisibleForTests`): the black
        // silhouette is then the column's most opaque part (alpha ≈ 3 of 255, the shadow ≤ 1), so the threshold follows
        // the column's peak.
        let peak = (0..<height).map { Int(pixels[4 * $0 + 3]) }.max() ?? 0
        let threshold = peak > 232 ? 216 : max(1, peak * 2 / 3)
        guard let bottom = (0..<height).last(where: { Int(pixels[4 * $0 + 3]) > threshold }) else { return 0 }
        return Double(bottom + 1)
    }
}
