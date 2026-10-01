import AppKit
import NotchBuddyCore

/// Logs, config backups and "about" for the settings page.
@MainActor
final class SettingsMaintenance: ObservableObject {
    @Published private(set) var backups: BackupsMaintenance.Summary?
    @Published private(set) var clearing = false
    /// Result of the last clear, shown under the row.
    @Published private(set) var message: String?

    private let backupsDirectory: URL
    /// False in previews: nothing is read from or written to disk.
    private let live: Bool

    init(backupsDirectory: URL = Paths.backupsDir, preview: BackupsMaintenance.Summary? = nil) {
        self.backupsDirectory = backupsDirectory
        live = preview == nil
        backups = preview
    }

    func refresh() {
        guard live else { return }
        let dir = backupsDirectory
        Task.detached(priority: .utility) {
            let summary = BackupsMaintenance.summary(at: dir)
            await MainActor.run { [weak self] in self?.backups = summary }
        }
    }

    func clearBackups() {
        guard live, !clearing else { return }
        clearing = true
        message = nil
        let dir = backupsDirectory
        Task.detached(priority: .userInitiated) {
            let outcome: Result<Int, Error> = Result { try BackupsMaintenance.clear(at: dir) }
            let summary = BackupsMaintenance.summary(at: dir)
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch outcome {
                case .success(let removed):
                    Log.info("settings: removed \(removed) config backup folder(s)")
                    self.message = removed == 0 ? L("Удалять было нечего")
                        : L("Удалено: %@ %@", removed, RussianPlural.pick(removed, "копия", "копии", "копий"))
                case .failure(let error):
                    Log.error("settings: clearing backups failed: \(error)")
                    self.message = L("Не всё удалось удалить: %@", error.localizedDescription)
                }
                self.backups = summary
                self.clearing = false
            }
        }
    }

    // MARK: Finder

    func openLogs() {
        let fm = FileManager.default
        if fm.fileExists(atPath: Log.fileURL.path) {
            NSWorkspace.shared.open(Log.fileURL)
        } else {
            try? fm.createDirectory(at: Log.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Log.directory)
        }
    }

    func revealLogs() {
        let fm = FileManager.default
        if fm.fileExists(atPath: Log.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
        } else {
            try? fm.createDirectory(at: Log.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Log.directory)
        }
    }

    func revealBackups() {
        guard live else { return }
        if FileManager.default.fileExists(atPath: backupsDirectory.path) {
            NSWorkspace.shared.open(backupsDirectory)
        } else {
            message = L("Резервных копий ещё не было")
        }
    }

    func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: About

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static var build: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    /// Filled in once the repository is public.
    static let repositoryURL: URL? = nil
    static let fontLicenseURL = URL(string: "https://openfontlicense.org")!
}
