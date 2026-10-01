import AppKit
import Combine
import NotchBuddyCore

/// Every setting of the app, observable, persisted in UserDefaults as it changes.
///
/// `values` is the single source of truth: edit it (`store.values.soundVolume = 0.5`, `$store.values.accent`)
/// and the changed keys are written at once; everything that observes the store follows live. Keys shared
/// with older code ("soundsEnabled", "usageNetworkEnabled", "didOfferHooks") are the same keys, and a change
/// made there (the menu bar menu, the island's sound button) shows up here on the next run-loop turn.
///
/// Launch at login is not a stored value: it is the system's login-item state (`LaunchAtLogin`).
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var values: NotchSettings {
        didSet {
            if values.language != oldValue.language, appliesLanguage { L10n.shared.setPreference(values.language) }
            guard !reloading, values != oldValue else { return }
            values.save(to: defaults, changedFrom: oldValue)
        }
    }

    @Published private(set) var launchAtLogin: LaunchAtLogin.State
    /// Why the last launch-at-login change did not take (shown under the row).
    @Published private(set) var launchAtLoginProblem: String?

    let defaults: UserDefaults
    /// Whether this store drives the interface language (the app's own store; previews keep theirs to themselves).
    private let appliesLanguage: Bool
    private var reloading = false
    private var observer: NSObjectProtocol?
    private var reloadScheduled = false

    /// `launchAtLogin`: injected by previews (nil reads the system).
    init(defaults: UserDefaults = .standard, launchAtLogin: LaunchAtLogin.State? = nil, observeDefaults: Bool = true) {
        self.defaults = defaults
        appliesLanguage = defaults == .standard
        let steps = SettingsMigration.migrate(defaults)
        if !steps.isEmpty { Log.info("settings: migrated (\(steps.joined(separator: "; ")))") }
        let loaded = NotchSettings.load(from: defaults)
        values = loaded
        // The interface language, before anything is drawn (the environment's NOTCHBUDDY_LANG still wins).
        if appliesLanguage { L10n.shared.setPreference(loaded.language) }
        self.launchAtLogin = launchAtLogin ?? LaunchAtLogin.state
        guard observeDefaults else { return }
        // Posted synchronously on the writing thread (our own writes included): re-read on the next main
        // run-loop turn, once, whatever the number of writes.
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                          object: defaults, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { self?.reloadFromDefaults() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Re-reads everything (a change made outside the store). Publishes only when something differs.
    func reloadFromDefaults() {
        let fresh = NotchSettings.load(from: defaults)
        guard fresh != values else { return }
        reloading = true
        values = fresh
        reloading = false
    }

    /// A value, as a stream that emits the current one first and then each change.
    func publisher<V: Equatable>(_ path: KeyPath<NotchSettings, V>) -> AnyPublisher<V, Never> {
        $values.map(path).removeDuplicates().eraseToAnyPublisher()
    }

    /// Everything back to the defaults (the first-launch hook offer stays answered).
    func resetAll() {
        values = values.reset()
        Log.info("settings: reset to defaults")
    }

    // MARK: Derived values the island reads

    /// Reduce Motion as the island should apply it: the system setting unless the user overrode it.
    var reduceMotion: Bool {
        values.motion.reduceMotion(system: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    // MARK: Launch at login

    func refreshLaunchAtLogin() {
        let state = LaunchAtLogin.state
        if state != launchAtLogin { launchAtLogin = state }
        if state != .requiresApproval, launchAtLoginProblem != nil, state != .unavailable { launchAtLoginProblem = nil }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchAtLoginProblem = nil
        } catch {
            Log.error("settings: launch at login → \(enabled) failed: \(error)")
            launchAtLoginProblem = "\(error)"
        }
        launchAtLogin = LaunchAtLogin.state
        Log.info("settings: launch at login now \(launchAtLogin)")
    }

    func openLoginItemsSettings() {
        LaunchAtLogin.openSystemSettings()
    }
}
