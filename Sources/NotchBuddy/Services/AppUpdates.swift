import AppKit
import NotchBuddyCore

/// The updater underneath `AppUpdates`: Sparkle in the app (`SparkleUpdater`), a stand-in in tests and previews.
@MainActor
protocol UpdaterDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var lastUpdateCheckDate: Date? { get }
    /// Shows the update window: a fresh check, or the update a background check already found.
    func checkForUpdates()
}

/// Self-updates as the UI sees them: Settings → «Обновления», «Проверить обновления…» in the menu bar menu and the dot
/// on its icon. Without a connected updater (a development build without a signing key, `swift run`) everything here
/// stays disabled.
///
/// A background check that finds a version while nobody is looking only marks it (the menu item and the dot); the
/// update window opens when the user asks. A version downloaded in the background («Устанавливать автоматически») is
/// installed on quit, from the menu or Settings, or on its own once the relaunch would lose nothing (`isQuiet`: every
/// session long silent, no card or notice waiting, the island closed) and the Mac has been idle for a couple of
/// minutes.
@MainActor
final class AppUpdates: NSObject, ObservableObject {
    static let shared = AppUpdates(configuration: .main)

    let configuration: UpdateConfiguration

    @Published private(set) var isRunning = false
    @Published private(set) var canCheck = false
    @Published private(set) var checksAutomatically: Bool
    @Published private(set) var installsAutomatically = false
    @Published private(set) var lastCheck: Date?
    /// A newer version a background check found that the user has not looked at yet.
    @Published private(set) var foundVersion: String?
    /// A version downloaded in the background, waiting for a quiet moment (or for the app to quit). Set exactly while
    /// it can be installed right away.
    @Published private(set) var downloadedVersion: String?

    /// Something waits for the user (the menu bar icon shows a dot).
    var needsAttention: Bool { foundVersion != nil || downloadedVersion != nil }
    /// Called whenever `needsAttention` may have changed.
    var onAttentionChange: () -> Void = {}

    /// Relaunching would lose nothing: no recent session, no card or notice waiting, the island closed.
    var isQuiet: () -> Bool = { false }
    /// Seconds since the last keyboard, mouse or trackpad event.
    var idleSeconds: () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }
    /// Brings the app forward before the update window opens (it has no Dock icon, so the window could open behind the
    /// frontmost app). Tests replace it.
    var activateApp: () -> Void = { NSApp.activate() }
    /// How long the Mac has to be idle before a downloaded update relaunches the app.
    static let quietIdleSeconds: TimeInterval = 120
    static let quietCheckInterval: TimeInterval = 60

    private var driver: UpdaterDriving?
    private var installNow: (() -> Void)?
    private var quietTimer: Timer?

    init(configuration: UpdateConfiguration) {
        self.configuration = configuration
        checksAutomatically = configuration.checksAutomatically
        super.init()
    }

    var version: String { configuration.version ?? "dev" }
    var build: String? { configuration.build }

    // MARK: Updater

    func connect(_ driver: UpdaterDriving) {
        self.driver = driver
        isRunning = true
        sync()
    }

    /// Re-reads the updater's state (its settings changed, a check started or ended).
    func sync() {
        guard let driver else { return }
        update(\.canCheck, driver.canCheckForUpdates)
        update(\.checksAutomatically, driver.automaticallyChecksForUpdates)
        update(\.installsAutomatically, driver.automaticallyDownloadsUpdates)
        update(\.lastCheck, driver.lastUpdateCheckDate)
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppUpdates, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    // MARK: Actions

    /// Opens the update window (the check runs in it), or brings back the update already found.
    func checkForUpdates() {
        guard let driver, driver.canCheckForUpdates else { return }
        activateApp()
        driver.checkForUpdates()
        sync()
    }

    func setChecksAutomatically(_ on: Bool) {
        guard let driver else { return }
        driver.automaticallyChecksForUpdates = on
        sync()
    }

    func setInstallsAutomatically(_ on: Bool) {
        guard let driver, configuration.allowsAutomaticUpdates else { return }
        driver.automaticallyDownloadsUpdates = on
        sync()
    }

    // MARK: Background checks

    /// A background check found `version`; the update window waits until the user asks for it.
    func found(version: String) {
        guard foundVersion != version else { return }
        Log.info("updates: version \(version) is available")
        foundVersion = version
        onAttentionChange()
    }

    /// The user has seen the update (its window came to the front, or they installed, skipped or dismissed it).
    func attended() {
        guard foundVersion != nil else { return }
        foundVersion = nil
        onAttentionChange()
    }

    /// `version` was downloaded in the background; `install` installs it and relaunches the app.
    func downloaded(version: String, install: @escaping () -> Void) {
        Log.info("updates: version \(version) downloaded; it installs when the app is quiet, or on quit")
        downloadedVersion = version
        foundVersion = nil
        installNow = install
        onAttentionChange()
        quietTimer?.invalidate()
        let timer = Timer(timeInterval: Self.quietCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.installIfQuiet() }
        }
        timer.tolerance = Self.quietCheckInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        quietTimer = timer
    }

    /// Installs the downloaded update now if nothing is going on. True if it did.
    @discardableResult
    func installIfQuiet() -> Bool {
        guard installNow != nil, isQuiet(), idleSeconds() >= Self.quietIdleSeconds else { return false }
        installDownloaded()
        return true
    }

    /// Installs the downloaded update and relaunches (the menu's «Обновить до … и перезапустить», the settings'
    /// «Установить и перезапустить»). Sparkle's handler works once: should the app keep running, the update is no
    /// longer offered here, and the next check brings it back.
    func installDownloaded() {
        guard let install = installNow else { return }
        let version = downloadedVersion
        installNow = nil
        downloadedVersion = nil
        quietTimer?.invalidate()
        quietTimer = nil
        onAttentionChange()
        Log.info("updates: installing version \(version ?? "?") and relaunching")
        install()
    }

    // MARK: Menu

    /// «Проверить обновления…» for the menu bar menu (or the found / downloaded version).
    func menuItem() -> NSMenuItem {
        let item: NSMenuItem
        if let version = downloadedVersion, installNow != nil {
            item = NSMenuItem(title: L("Обновить до %@ и перезапустить", version), action: #selector(installFromMenu(_:)),
                              keyEquivalent: "")
        } else if let version = foundVersion {
            item = NSMenuItem(title: L("Обновить до %@…", version), action: #selector(checkFromMenu(_:)), keyEquivalent: "")
        } else {
            item = NSMenuItem(title: L("Проверить обновления…"), action: #selector(checkFromMenu(_:)), keyEquivalent: "")
        }
        item.target = self
        if !isRunning {
            item.isEnabled = false
            item.toolTip = L("Обновления недоступны в этой сборке")
        } else {
            item.isEnabled = canCheck || installNow != nil
        }
        return item
    }

    @objc private func checkFromMenu(_ sender: NSMenuItem) { checkForUpdates() }

    @objc private func installFromMenu(_ sender: NSMenuItem) { installDownloaded() }
}

// MARK: - Previews

/// A fixed updater for `--render-settings`: nothing is checked or downloaded.
@MainActor
final class PreviewUpdater: UpdaterDriving {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = true
    var automaticallyDownloadsUpdates = false
    var lastUpdateCheckDate: Date? = Date().addingTimeInterval(-3 * 3600)
    private(set) var checks = 0

    func checkForUpdates() { checks += 1 }
}

extension AppUpdates {
    /// A connected, idle updater with the given version, for previews and tests.
    static func preview(version: String = "1.0", build: String = "1",
                        updater: UpdaterDriving? = nil) -> AppUpdates {
        let updates = AppUpdates(configuration: UpdateConfiguration(infoDictionary: [
            "CFBundleShortVersionString": version, "CFBundleVersion": build,
            "SUEnableAutomaticChecks": true, "SUAllowsAutomaticUpdates": true,
        ]))
        updates.connect(updater ?? PreviewUpdater())
        return updates
    }
}
