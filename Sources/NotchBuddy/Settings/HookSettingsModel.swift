import AppKit
import NotchBuddyCore

/// Hook status and install / reinstall / uninstall for the settings page, through `HookInstallService`
/// (backups, serial IO queue, logging all happen there). Results are shown inline under the agent's row
/// instead of in alerts.
@MainActor
final class HookSettingsModel: ObservableObject {
    struct Note: Equatable {
        enum Kind: Equatable { case success, info, warning, error }
        var kind: Kind
        var text: String
    }

    @Published private(set) var reports: [AgentSource: HookReport]
    @Published private(set) var busy: Set<AgentSource> = []
    @Published private(set) var notes: [AgentSource: Note] = [:]
    /// Bumped when an operation succeeds (the row plays its check).
    @Published private(set) var successTick: [AgentSource: Int] = [:]
    /// Called after every change, so other views of the same state (the menu bar menu) refresh.
    var onChange: () -> Void = {}

    private let service: HookInstallService?
    private var refreshTask: Task<Void, Never>?

    /// `service` nil: a static preview with the given reports (buttons do nothing).
    init(service: HookInstallService?, reports: [AgentSource: HookReport] = [:]) {
        self.service = service
        self.reports = reports
    }

    static func live() -> HookSettingsModel { HookSettingsModel(service: HookInstallService()) }

    func refresh() {
        guard let service, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            let fresh = await service.reports()
            guard let self else { return }
            for (source, report) in fresh where !busy.contains(source) && reports[source] != report {
                reports[source] = report
            }
            refreshTask = nil
        }
    }

    func install(_ source: AgentSource) { run(source, install: true) }
    func uninstall(_ source: AgentSource) { run(source, install: false) }

    /// Shows the agent's config files in Finder.
    func reveal(_ source: AgentSource) {
        guard let files = reports[source]?.existingFiles, !files.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    func dismissNote(_ source: AgentSource) { notes[source] = nil }

    private func run(_ source: AgentSource, install: Bool) {
        guard let service, !busy.contains(source) else { return }
        busy.insert(source)
        notes[source] = nil
        Task { [weak self] in
            let result: Result<HookReport, Error>
            do {
                result = .success(install ? try await service.install(source) : try await service.uninstall(source))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            switch result {
            case .success(let report):
                reports[source] = report
                successTick[source, default: 0] &+= 1
                if install, let note = HookInstallService.followUpNote(for: source, status: report.status) {
                    notes[source] = Note(kind: report.status == .installed ? .info : .warning, text: note)
                } else {
                    notes[source] = Note(kind: .success, text: install ? L("Хуки установлены") : L("Хуки удалены"))
                }
            case .failure(let error):
                reports[source] = await service.report(for: source)
                let verb = install ? L("установить") : L("удалить")
                notes[source] = Note(kind: .error, text: L("Не удалось %@: %@", verb, HookInstallService.describe(error)))
            }
            busy.remove(source)
            onChange()
        }
    }
}

extension HookInstallStatus {
    /// Short status for the settings row.
    var settingsLabel: String {
        switch self {
        case .installed: return L("Подключён")
        case .notInstalled: return L("Не подключён")
        case .partial: return L("Частично")
        case .agentMissing: return L("Не найден")
        case .error: return L("Ошибка")
        }
    }
}
