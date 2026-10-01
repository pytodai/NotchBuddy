import AppKit
import NotchBuddyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var socket: SocketService?
    private var island: IslandController?
    private var menuBar: MenuBarController?
    private var updater: SparkleUpdater?
    private var instanceLock: InstanceLock?
    private var perfHarness: IslandPerfHarness?
    private var signalSources: [DispatchSourceSignal] = []
    private var usageSink: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard claimSingleInstance() else {
            NSApp.terminate(nil)
            return
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        Log.info("NotchBuddy \(version) starting, pid \(getpid())")

        DispatchQueue.global(qos: .utility).async {
            HookInstallService.syncBridgeBinary()
            // The bridge's own strings (CLI help, statusLine, hook errors) in the app's language.
            HookInstallService.syncBridgeLocalization()
        }

        // The debug benchmark (`NOTCHBUDDY_PERF=1`) runs beside the installed app: no keychain, no network, no menu
        // bar item, no hook offer; its sessions are fake (`IslandPerfHarness`).
        let perf = IslandPerf.enabled
        let model = AppModel(jumper: TerminalJumper(), usageProvider: perf ? IslandPerfUsage() : UsageFetcher())
        let socket = SocketService(model: model)
        signalSources = SignalQuit.install([SIGTERM, SIGINT], socket: socket)
        socket.start()
        model.start()

        let island = IslandController(model: model)
        island.start()
        self.model = model
        self.socket = socket
        self.island = island
        if perf {
            Log.info("updates: off in the benchmark (Sparkle \(SparkleUpdater.frameworkVersion))")
            let harness = IslandPerfHarness(model: model, island: island)
            harness.start()
            perfHarness = harness
            return
        }

        // Self-updates (Sparkle). A background download installs on its own only when the relaunch loses nothing:
        // every session long silent, no card or notice waiting, the island closed.
        let updates = AppUpdates.shared
        updates.isQuiet = { [weak model, weak island] in
            guard let model, let island else { return false }
            return !island.isInUse && model.canRelaunchQuietly()
        }

        // The widgets' services and every agent's usage (Codex from its logs, Kimi when allowed, Claude from its own
        // fetcher). The benchmark runs none of them.
        let widgets = WidgetHub.shared
        widgets.start()
        widgets.usage.updateClaude(model.usage)
        usageSink = model.$usage.sink { [weak widgets] usage in widgets?.usage.updateClaude(usage) }
        model.onEvent = { [weak widgets] event in widgets?.usage.handle(event) }

        // Settings drive the notices' length and the usage refresh (the benchmark keeps the defaults).
        model.flashSeconds = { SettingsStore.shared.values.flashDuration.seconds }
        model.showsAgentReply = { SettingsStore.shared.values.showsAgentReply }
        model.setUsageRefreshInterval(SettingsStore.shared.values.usageRefresh.seconds)

        let hooks = HookInstallService()
        let menuBar = MenuBarController(model: model, hooks: hooks, socket: socket)
        self.menuBar = menuBar
        menuBar.openSettings = { [weak island] in island?.showSettings() }
        menuBar.updates = updates
        updates.onAttentionChange = { [weak menuBar, weak updates] in menuBar?.setUpdateBadge(updates?.needsAttention ?? false) }
        updater = SparkleUpdater.start(configuration: updates.configuration, updates: updates)
        // Hooks installed or removed in Settings show in the menu at once.
        IslandSettings.model.hooks.onChange = { [weak menuBar] in menuBar?.refreshHookStatuses() }

        // The offer is a non-modal window: socket events and the island keep working while it is up.
        Task {
            if await hooks.offerInstallOnFirstLaunch() { menuBar.refreshHookStatuses() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !IslandPerf.enabled { WidgetHub.shared.stop() }
        socket?.stop()
        Log.info("NotchBuddy exiting")
        Log.flush()
    }

    /// Launching the app again while it runs (Finder, Spotlight) opens the status menu as feedback.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar?.showMenu()
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Single instance

    /// The `flock` next to the socket is the only arbiter: of two copies launched at the same moment,
    /// exactly one gets it. The other one brings the winner forward and quits.
    private func claimSingleInstance() -> Bool {
        let lockPath = InstanceLockPath.path
        var outcome = InstanceLock.acquire(path: lockPath)
        // `build-app.sh --install` kills the old copy and opens the new one right away:
        // give a quitting instance a moment to release the lock.
        let deadline = Date().addingTimeInterval(2)
        while case .heldByOther = outcome, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            outcome = InstanceLock.acquire(path: lockPath)
        }
        switch outcome {
        case .acquired(let lock):
            instanceLock = lock
            return true
        case .heldByOther:
            if let other = Self.otherInstance() {
                Log.info("NotchBuddy already running (pid \(other.processIdentifier)); activating it and exiting")
                other.activate(options: [])
            } else {
                Log.info("another NotchBuddy holds the socket lock; exiting")
            }
            return false
        case .unavailable(let reason):
            Log.error("instance lock unavailable (\(reason)); continuing without it")
            return true
        }
    }

    /// Only a hint for activation; unbundled runs (`swift run`) have no bundle id.
    private static func otherInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != getpid() && !$0.isTerminated }
    }
}

// MARK: - Signals

/// SIGTERM / SIGINT (`pkill`, Ctrl-C) always quit promptly and leave no socket file behind.
///
/// The handler runs on its own queue, so it fires even when the main thread is stuck (a modal session,
/// a deferred terminate, a hang). It asks the main thread to clean up and exit first; if that has not
/// happened within `mainThreadGrace`, it does the same itself.
enum SignalQuit {
    static let mainThreadGrace: TimeInterval = 0.5
    private static let queue = DispatchQueue(label: "me.sokolov.notchbuddy.signals")
    private static let exiting = OnceFlag()

    /// Keep the returned sources alive for the process lifetime.
    static func install(_ signals: [Int32], socket: SocketService) -> [DispatchSourceSignal] {
        signals.map { sig in
            signal(sig, SIG_IGN)   // delivered to the dispatch source instead of the default action
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { handle(sig, socket: socket) }
            source.resume()
            return source
        }
    }

    private static func handle(_ sig: Int32, socket: SocketService) {
        Log.info("signal \(sig) received; quitting")
        // A run-loop block rather than DispatchQueue.main: it also runs inside nested run loops
        // (menu tracking, modal sessions) started from a main-queue callout.
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) { cleanUpAndExit(socket) }
        CFRunLoopWakeUp(main)
        queue.asyncAfter(deadline: .now() + mainThreadGrace) {
            cleanUpAndExit(socket)
            // Reached only if the main thread claimed the exit and got stuck in it.
            queue.asyncAfter(deadline: .now() + 2) { _exit(0) }
        }
    }

    /// Stops the server (it unlinks the socket file only if it is still ours), flushes the log, exits.
    /// The kernel drops the instance `flock` on exit. The lock file itself stays on purpose:
    /// unlinking a flock file lets two later instances lock two different inodes.
    private static func cleanUpAndExit(_ socket: SocketService) {
        guard exiting.claim() else { return }
        socket.stopFromAnyThread()
        Log.info("NotchBuddy exiting (signal)")
        Log.flush()
        exit(0)
    }
}

/// True for exactly one caller, from any thread.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

/// Advisory `flock` held for the process lifetime; the kernel releases it on exit, even after a crash.
final class InstanceLock {
    enum Outcome {
        case acquired(InstanceLock)
        case heldByOther
        case unavailable(String)
    }

    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    deinit { close(fd) }

    static func acquire(path: String) -> Outcome {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return .unavailable("\(error)")
        }
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .unavailable(String(cString: strerror(errno))) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let err = errno
            close(fd)
            return err == EWOULDBLOCK ? .heldByOther : .unavailable(String(cString: strerror(err)))
        }
        return .acquired(InstanceLock(fd: fd))
    }
}
