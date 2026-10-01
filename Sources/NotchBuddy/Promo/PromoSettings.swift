import AppKit
import NotchBuddyCore
import SwiftUI

/// The settings page the promo films: the real `SettingsPage` over a throwaway store with the defaults (a temporary
/// defaults suite, removed when the render ends) and fake hook, backup and screen data, so nothing of the machine
/// that renders the film shows up and nothing is read from or written to the real settings, hooks or backups.
@MainActor
enum PromoSettings {
    private static var suite: String?

    /// Replaces the stage's settings page (`IslandSettings.pageID`) with the promo's. Call after `IslandSettings.register()`.
    static func register(lang: PromoLanguage) {
        let name = "me.sokolov.notchbuddy.promo.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { return }
        suite = name
        let store = SettingsStore(defaults: defaults, launchAtLogin: .enabled, observeDefaults: false)
        store.values.language = lang == .ru ? .ru : .en
        let home = URL(fileURLWithPath: "/Users/you")
        var reports: [AgentSource: HookReport] = [
            .claude: HookReport(status: .installed, existingFiles: [home.appendingPathComponent(".claude/settings.json")]),
            .codex: HookReport(status: .installed, existingFiles: [home.appendingPathComponent(".codex/hooks.json")]),
            .kimi: HookReport(status: .installed, existingFiles: [home.appendingPathComponent(".kimi-code/config.toml")]),
        ]
        for agent in AgentCatalog.settingsAgents where reports[agent] == nil {
            reports[agent] = HookReport(status: .notInstalled, existingFiles: [])
        }
        let hooks = HookSettingsModel(service: nil, reports: reports)
        let maintenance = SettingsMaintenance(preview: .init(snapshots: 2, files: 3, bytes: 12_400, newest: Date()))
        let model = SettingsPageModel(
            store: store, hooks: hooks, maintenance: maintenance, recorder: HotkeyRecorder(),
            hotkey: .preview(status: .active(.defaultToggle)),
            screens: [ScreenOption(id: "A", name: lang == .ru ? "Встроенный дисплей Retina" : "Built-in Retina Display",
                                   isMain: true, hasNotch: true)])
        model.systemReduceMotion = { false }
        IslandPages.register(IslandPageSpec(id: IslandSettings.pageID, width: { IslandLayout.settingsWidth($0) }) { context in
            AnyView(SettingsPage(model: model, metrics: context.metrics, width: context.width,
                                 maxHeight: IslandLayout.maxOpenHeight,
                                 pinned: context.state.pinned, pinBounce: context.state.pinBounce,
                                 onTogglePin: context.actions.togglePin,
                                 onClose: { context.actions.showPage(nil) }))
        })
    }

    /// Removes the throwaway defaults suite.
    static func cleanUp() {
        guard let suite else { return }
        UserDefaults.standard.removePersistentDomain(forName: suite)
        self.suite = nil
    }
}
