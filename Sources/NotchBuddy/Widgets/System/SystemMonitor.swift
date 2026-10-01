import AppKit
import IOKit.ps
import Observation
import SwiftUI
import notify
import NotchBuddyCore

/// What the system widget shows, kept fresh as cheaply as possible:
/// - the battery is pushed by `IOPowerSources` notifications (never polled), always — the low-battery live
///   activity and the power notices need it while nothing is on screen;
/// - CPU, memory and disk are sampled every 2 s, and only while a view that shows them is on screen
///   (`beginViewing` / `systemSampling`); each sample costs microseconds (`host_statistics`).
///
/// Wiring: create one at launch, call `start()`, set `onBatteryEvent` for power notices
/// (`BatteryNoticeView`), put `SystemWidgetView(monitor:metrics:width:)` on a widget page and
/// `BatteryLiveActivityView(monitor:metrics:)` in the closed island while `hasLiveActivity`.
@Observable
@MainActor
final class SystemMonitor {
    private(set) var battery: BatteryState?
    /// Busy share of all cores, smoothed (0…1).
    private(set) var cpu: Double?
    /// The last minute of CPU samples, oldest first.
    private(set) var cpuHistory: [Double] = []
    private(set) var memory: MemoryUsage?
    private(set) var disk: DiskUsage?
    private(set) var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private(set) var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    /// Counts samples (the sparkline slides one step per sample).
    private(set) var sampleCount = 0
    let preferences: SystemPreferences

    /// Plugged in, unplugged, low, critical, full (only when `preferences.powerNotices` or it is low/critical).
    @ObservationIgnored var onBatteryEvent: ((BatteryEvent) -> Void)?
    /// The low-battery live activity came or went.
    @ObservationIgnored var onChange: (() -> Void)?

    static let interval: TimeInterval = 2
    static let historyLength = 30

    @ObservationIgnored private let frozen: Bool
    @ObservationIgnored private var token: Int32 = NOTIFY_TOKEN_INVALID
    @ObservationIgnored private var sampler: Timer?
    @ObservationIgnored private var lastTicks: CPUTicks?
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastDiskRead = -TimeInterval.infinity

    init(preferences: SystemPreferences? = nil) {
        self.preferences = preferences ?? SystemPreferences()
        frozen = false
    }

    /// Fixed values (previews).
    init(frozenBattery battery: BatteryState?, cpu: Double?, history: [Double], memory: MemoryUsage?, disk: DiskUsage?,
         thermal: ProcessInfo.ThermalState = .nominal, uptime: TimeInterval = 3 * 86_400 + 4 * 3600,
         preferences: SystemPreferences? = nil) {
        self.preferences = preferences
            ?? SystemPreferences(defaults: UserDefaults(suiteName: "notchbuddy.system.preview") ?? .standard)
        frozen = true
        self.battery = battery
        self.cpu = cpu
        cpuHistory = history
        self.memory = memory
        self.disk = disk
        self.thermal = thermal
        self.uptime = uptime
        sampleCount = history.count
    }

    // MARK: Reading

    var policy: BatteryAlertPolicy {
        BatteryAlertPolicy(threshold: preferences.lowBatteryThreshold, critical: min(10, preferences.lowBatteryThreshold))
    }

    var isLowBattery: Bool { policy.isLow(battery) }
    var isCriticalBattery: Bool { policy.isCritical(battery) }

    /// The closed island shows the battery.
    var hasLiveActivity: Bool { preferences.lowBatteryLiveActivity && isLowBattery }

    // MARK: Lifecycle

    func start() {
        guard !frozen, token == NOTIFY_TOKEN_INVALID else { return }
        battery = BatteryState.read()
        let status = notify_register_dispatch(kIOPSNotifyAnyPowerSource, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readBattery() }
        }
        if status != NOTIFY_STATUS_OK { token = NOTIFY_TOKEN_INVALID }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readBattery() }
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.thermal = ProcessInfo.processInfo.thermalState }
        })
    }

    func stop() {
        if token != NOTIFY_TOKEN_INVALID {
            notify_cancel(token)
            token = NOTIFY_TOKEN_INVALID
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        sampler?.invalidate()
        sampler = nil
    }

    private func readBattery() {
        let old = battery
        let new = BatteryState.read()
        guard new != old else { return }
        let wasLive = hasLiveActivity
        battery = new
        if let new {
            for event in policy.events(from: old, to: new) where wants(event) {
                onBatteryEvent?(event)
            }
        }
        if hasLiveActivity != wasLive { onChange?() }
    }

    private func wants(_ event: BatteryEvent) -> Bool {
        switch event {
        case .low, .critical: return true
        case .pluggedIn, .unplugged, .full: return preferences.powerNotices
        }
    }

    // MARK: Sampling

    /// A view that shows CPU / memory / disk appeared: sample now and every 2 s until the last one goes.
    func beginViewing() {
        viewers += 1
        guard viewers == 1, !frozen else { return }
        uptime = ProcessInfo.processInfo.systemUptime
        sample()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        sampler = timer
    }

    func endViewing() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        sampler?.invalidate()
        sampler = nil
        // The next look starts a fresh CPU delta (a stale one would average over the whole pause).
        lastTicks = nil
    }

    private func sample() {
        if let ticks = CPUTicks.read() {
            if let last = lastTicks, let usage = CPULoad.usage(from: last, to: ticks) {
                let smoothed = CPULoad.smoothed(cpu, usage, alpha: 0.55)
                cpu = smoothed
                cpuHistory.append(usage)
                if cpuHistory.count > Self.historyLength { cpuHistory.removeFirst(cpuHistory.count - Self.historyLength) }
                sampleCount &+= 1
            }
            lastTicks = ticks
        }
        memory = MemoryUsage.read()
        let now = AppClock.monotonicSeconds()
        // Free space changes slowly and costs a filesystem call: every 10 s is plenty.
        if now - lastDiskRead >= 10 {
            disk = DiskUsage.read()
            lastDiskRead = now
        }
        uptime = ProcessInfo.processInfo.systemUptime
    }
}

/// Keeps a monitor sampling while the modified view is on screen.
struct SystemSampling: ViewModifier {
    let monitor: SystemMonitor

    func body(content: Content) -> some View {
        content
            .onAppear { monitor.beginViewing() }
            .onDisappear { monitor.endViewing() }
    }
}

extension View {
    func systemSampling(_ monitor: SystemMonitor) -> some View { modifier(SystemSampling(monitor: monitor)) }
}
