import AppKit

/// The app the user works in, for Settings → Остров → «Где показывать» (`IslandAppVisibility`).
///
/// It follows app activation (`NSWorkspace.didActivateApplicationNotification`), the menu bar's owner (an agent app's
/// panel — a launcher, NotchBuddy's own menu or open panel — leaves the app behind it in charge) and Space changes.
/// NotchBuddy itself and agent apps never count: the last regular app stays. A change is reported 150 ms after things
/// settle, so a quick ⌘Tab through several apps hides or shows the island once, not on every app passed.
@MainActor
final class FrontmostAppWatcher {
    /// The app's bundle identifier (nil until one is known).
    private(set) var bundleID: String?
    /// The app changed (after the debounce).
    var onChange: () -> Void = {}

    static let debounce: TimeInterval = 0.15

    private var observers: [NSObjectProtocol] = []
    private var menuBarObservation: NSKeyValueObservation?
    private var pending: DispatchWorkItem?

    func start() {
        guard observers.isEmpty else { return }
        bundleID = Self.current()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
        menuBarObservation = NSWorkspace.shared.observe(\.menuBarOwningApplication, options: []) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.schedule() } }
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        menuBarObservation = nil
        pending?.cancel()
        pending = nil
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    private func evaluate() {
        pending = nil
        guard let next = Self.current(), next != bundleID else { return }
        bundleID = next
        onChange()
    }

    /// The regular app in front: the frontmost one, else the menu bar's owner; nil when neither is a regular app other
    /// than NotchBuddy (the caller keeps the last one).
    static func current() -> String? {
        let own = ProcessInfo.processInfo.processIdentifier
        let workspace = NSWorkspace.shared
        for app in [workspace.frontmostApplication, workspace.menuBarOwningApplication] {
            guard let app, app.processIdentifier != own, app.activationPolicy == .regular,
                  let id = app.bundleIdentifier, !id.isEmpty else { continue }
            return id
        }
        return nil
    }
}
