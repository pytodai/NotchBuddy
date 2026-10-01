import AppKit
import NotchBuddyCore

/// The island's sounds, as Settings → «Звуки» says (`SettingsSounds`: a system sound per event, a master switch and a
/// volume). On by default; the menu bar's «Звуки» and the island's 🔊 flip the same switch.
@MainActor
enum IslandSounds {
    enum Cue {
        /// An agent finished its turn.
        case finished
        /// An agent needs the user (a notification).
        case attention
        /// A new permission request reached the island.
        case permission
        /// A session failed.
        case error

        var event: SoundEvent {
            switch self {
            case .finished: return .finished
            case .attention: return .attention
            case .permission: return .permission
            case .error: return .error
            }
        }
    }

    static let defaultsKey = "soundsEnabled"

    static var isEnabled: Bool {
        get { SettingsStore.shared.values.soundsEnabled }
        set { SettingsStore.shared.values.soundsEnabled = newValue }
    }

    static func play(_ cue: Cue) {
        // The debug benchmark (`NOTCHBUDDY_PERF=1`) fires dozens of notices: silently.
        guard !IslandPerf.enabled else { return }
        SettingsSounds.play(cue.event)
    }
}
