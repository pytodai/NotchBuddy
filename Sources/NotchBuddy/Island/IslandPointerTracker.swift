import AppKit

/// Follows the pointer for the island without any permission prompt.
///
/// The panel ignores the mouse most of the time, so SwiftUI hover cannot be relied on. Instead:
/// - a global monitor sees pointer moves over other apps (mouse events need no Accessibility access);
/// - a local monitor and the panel's tracking area see moves over NotchBuddy's own panel;
/// - a 10 Hz watchdog runs only while the pointer is inside the island and has moved in the last
///   second, catching exits no event reports (the pointer warped to another display).
/// Nothing runs while the island is ordered out. Pointer speed (an exponential average over event
/// timestamps) lets the controller tell a resting pointer from one sweeping across the top.
@MainActor
final class IslandPointerTracker {
    /// `fromEvent` is false for watchdog ticks (the pointer may not have moved).
    var onMove: (_ fromEvent: Bool) -> Void = { _ in }
    /// A mouse button went down in another app or on the desktop (never on NotchBuddy's own windows).
    var onClickElsewhere: () -> Void = {}
    /// Pointer speed in points per second (smoothed).
    private(set) var speed: CGFloat = 0

    /// `speed`, or 0 once no move has been seen for a moment (the pointer is resting).
    var currentSpeed: CGFloat {
        ProcessInfo.processInfo.systemUptime - lastTimestamp > 0.12 ? 0 : speed
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var clickMonitor: Any?
    private var watchdog: Timer?
    private var wantsWatching = false
    private var idleTicks = 0
    private var lastLocation: NSPoint?
    private var lastTimestamp: TimeInterval = 0

    private static let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

    var isRunning: Bool { globalMonitor != nil }

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] event in
            let timestamp = event.timestamp
            Self.onMain { self?.noteEvent(timestamp: timestamp) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mask.union(.leftMouseUp)) { [weak self] event in
            let timestamp = event.timestamp
            Self.onMain { self?.noteEvent(timestamp: timestamp) }
            return event
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Self.onMain { self?.onClickElsewhere() }
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        globalMonitor = nil
        localMonitor = nil
        clickMonitor = nil
        setWatching(false)
        speed = 0
        lastLocation = nil
    }

    /// A pointer event (monitors, the panel's tracking area).
    func noteEvent(timestamp: TimeInterval? = nil) {
        let location = NSEvent.mouseLocation
        let now = timestamp ?? ProcessInfo.processInfo.systemUptime
        if let last = lastLocation, now > lastTimestamp {
            let dt = max(now - lastTimestamp, 0.004)
            let v = min(hypot(location.x - last.x, location.y - last.y) / CGFloat(dt), 6000)
            // A long pause resets the average (the pointer was resting).
            speed = dt > 0.25 ? v * 0.5 : 0.5 * v + 0.5 * speed
        }
        lastLocation = location
        lastTimestamp = now
        idleTicks = 0
        if wantsWatching, watchdog == nil { startWatchdog() }
        onMove(true)
    }

    /// Polls the pointer while it is inside the island (only then).
    func setWatching(_ watching: Bool) {
        wantsWatching = watching
        if watching {
            idleTicks = 0
            if watchdog == nil { startWatchdog() }
        } else {
            stopWatchdog()
        }
    }

    private func startWatchdog() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Self.onMain { self?.tick() }
        }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func tick() {
        let location = NSEvent.mouseLocation
        if let last = lastLocation, abs(location.x - last.x) < 0.5, abs(location.y - last.y) < 0.5 {
            idleTicks += 1
            speed *= 0.5
        } else {
            idleTicks = 0
            lastLocation = location
            lastTimestamp = ProcessInfo.processInfo.systemUptime
        }
        onMove(false)
        // A pointer parked on the island needs no polling; the next event (or a change of the island's
        // size, which re-checks the pointer) starts it again.
        if idleTicks >= 10 { stopWatchdog() }
    }

    /// Monitor handlers arrive on the main thread; this only guards the assumption.
    private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }
}
