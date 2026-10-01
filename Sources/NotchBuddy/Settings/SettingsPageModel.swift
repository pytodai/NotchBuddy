import AppKit
import NotchBuddyCore

/// Everything the settings page shows and edits, in one object the island keeps for the app's lifetime (so the
/// open section survives closing and reopening the page).
///
/// Usage: `let settingsModel = SettingsPageModel.live()` once; show
/// `SettingsPage(model: settingsModel, metrics: metrics, onClose: …)` inside the expanded island; call
/// `pageDidAppear()` / `pageDidDisappear()` when it is shown / hidden.
@MainActor
final class SettingsPageModel: ObservableObject {
    let store: SettingsStore
    let hooks: HookSettingsModel
    let maintenance: SettingsMaintenance
    let recorder: HotkeyRecorder
    let hotkey: GlobalHotkey
    let updates: AppUpdates
    let previewer = SoundPreviewer()

    /// The open section (one at a time).
    @Published var expanded: SettingsSection?
    /// The event whose sound list is open in the sounds section.
    @Published var soundPicker: SoundEvent?
    @Published private(set) var screens: [ScreenOption]
    /// Bumped when a section opens (its icon plays).
    @Published private(set) var iconBounce: [SettingsSection: Int] = [:]
    /// Static renders only: «Добавить приложение…» shown open with these apps.
    @Published var previewPicking: [PickableApp]?

    /// Reads the system's Reduce Motion (injected by previews).
    var systemReduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(store: SettingsStore, hooks: HookSettingsModel, maintenance: SettingsMaintenance,
         recorder: HotkeyRecorder? = nil, hotkey: GlobalHotkey? = nil, screens: [ScreenOption]? = nil,
         updates: AppUpdates? = nil) {
        let recorder = recorder ?? HotkeyRecorder()
        self.store = store
        self.hooks = hooks
        self.maintenance = maintenance
        self.recorder = recorder
        self.hotkey = hotkey ?? .shared
        self.updates = updates ?? .shared
        self.screens = screens ?? SettingsScreens.options()
        recorder.onCapture = { [weak store] combo in
            store?.values.hotkey = combo
            store?.values.hotkeyEnabled = true
        }
    }

    static func live() -> SettingsPageModel {
        SettingsPageModel(store: .shared, hooks: .live(), maintenance: SettingsMaintenance())
    }

    /// The page came on screen: re-read what may have changed elsewhere.
    func pageDidAppear() {
        hooks.refresh()
        maintenance.refresh()
        store.refreshLaunchAtLogin()
        updates.sync()
        let fresh = SettingsScreens.options()
        if fresh != screens { screens = fresh }
    }

    /// The page left the screen: nothing keeps playing or listening.
    func pageDidDisappear() {
        previewer.stop()
        recorder.cancel()
        soundPicker = nil
    }

    func toggle(_ section: SettingsSection) {
        guard section.expandable else { return }
        if expanded == section {
            expanded = nil
        } else {
            expanded = section
            iconBounce[section, default: 0] &+= 1
        }
        if expanded != .sounds { soundPicker = nil }
        if expanded != .hotkey { recorder.cancel() }
        if expanded != .sounds { previewer.stop() }
    }

    var reduceMotion: Bool { store.values.motion.reduceMotion(system: systemReduceMotion()) }
}

// MARK: - Screens

struct ScreenOption: Identifiable, Equatable {
    /// Display UUID.
    let id: String
    let name: String
    let isMain: Bool
    let hasNotch: Bool
}

/// Displays for the "which screen" setting.
@MainActor
enum SettingsScreens {
    static func options() -> [ScreenOption] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let id = uuid(for: screen) else { return nil }
            return ScreenOption(id: id, name: screen.localizedName, isMain: index == 0,
                                hasNotch: screen.safeAreaInsets.top > 0)
        }
    }

    static func uuid(for screen: NSScreen) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(screen.displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The screen the island should use for `choice`; nil: follow the frontmost window (`ScreenLocator`), which is
    /// also the answer when the chosen display is not connected.
    static func screen(for choice: ScreenChoice) -> NSScreen? {
        switch choice {
        case .activeWindow: return nil
        case .main: return NSScreen.screens.first
        case .display(let id, _): return NSScreen.screens.first { uuid(for: $0) == id }
        }
    }
}
