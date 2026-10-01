import AppKit
import Combine
import NotchBuddyCore
import Sparkle

/// Sparkle 2 behind `UpdaterDriving`: one `SPUStandardUpdaterController` (Sparkle's own windows and settings), an
/// EdDSA-signed appcast (`SUFeedURL`, `SUPublicEDKey` in Info.plist), gentle reminders for an app without a Dock icon
/// and background downloads handed to `AppUpdates`, which installs them at a quiet moment.
@MainActor
final class SparkleUpdater: NSObject, UpdaterDriving {
    private var controller: SPUStandardUpdaterController?
    private weak var updates: AppUpdates?
    private var observers: [AnyCancellable] = []

    /// The embedded Sparkle.framework's version.
    static var frameworkVersion: String {
        Bundle(for: SPUUpdater.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Starts Sparkle for the running app; nil (and a line in the log) when this build cannot update itself.
    static func start(configuration: UpdateConfiguration, updates: AppUpdates) -> SparkleUpdater? {
        let sparkle = frameworkVersion
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            Log.info("updates: off (Sparkle \(sparkle); not running from an app bundle)")
            return nil
        }
        if let problem = configuration.problem {
            Log.info("updates: off (Sparkle \(sparkle); \(problem))")
            return nil
        }
        let updater = SparkleUpdater(updates: updates)
        do {
            try updater.start()
        } catch {
            Log.error("updates: Sparkle \(sparkle) did not start: \(error.localizedDescription)")
            return nil
        }
        Log.info("updates: Sparkle \(sparkle), feed \(configuration.feedURL?.absoluteString ?? "-")")
        updates.connect(updater)
        return updater
    }

    private init(updates: AppUpdates) {
        self.updates = updates
        super.init()
    }

    private func start() throws {
        // Started by hand rather than with `startingUpdater: true`: on a configuration error the controller would show a
        // modal alert of its own; here it goes to the log and the app just has no updater.
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self,
                                                      userDriverDelegate: self)
        try controller.updater.start()
        self.controller = controller
        let updater = controller.updater
        let changes: [AnyPublisher<Void, Never>] = [
            updater.publisher(for: \.canCheckForUpdates).map { _ in () }.eraseToAnyPublisher(),
            updater.publisher(for: \.automaticallyChecksForUpdates).map { _ in () }.eraseToAnyPublisher(),
            updater.publisher(for: \.automaticallyDownloadsUpdates).map { _ in () }.eraseToAnyPublisher(),
        ]
        observers = changes.map { publisher in
            publisher.sink { [weak self] in
                Task { @MainActor in self?.updates?.sync() }
            }
        }
    }

    // MARK: UpdaterDriving

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

// MARK: - SPUUpdaterDelegate

extension SparkleUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Log.info("updates: found \(item.displayVersionString) (build \(item.versionString))")
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error = error as NSError?, error.code != Int(SUError.noUpdateError.rawValue) {
            Log.error("updates: check ended with \(error.localizedDescription)")
        }
        updates?.sync()
    }

    /// A background download is ready: install it at a quiet moment instead of waiting for the app to quit.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard let updates else { return false }
        updates.downloaded(version: item.displayVersionString, install: immediateInstallHandler)
        return true
    }
}

// MARK: - SPUStandardUserDriverDelegate (gentle reminders)

extension SparkleUpdater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows a scheduled update itself only when it would come up in focus (right after launch); otherwise the
    /// menu bar icon gets a dot and the update waits in the menu and in Settings.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                           andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let version = update.displayVersionString
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated {
            if handleShowingUpdate {
                // The window is about to open: make sure it is not left behind the frontmost app.
                updates?.activateApp()
            } else if !userInitiated {
                updates?.found(version: version)
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { updates?.attended() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            updates?.attended()
            updates?.sync()
        }
    }
}
