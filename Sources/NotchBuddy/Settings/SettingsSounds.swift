import AppKit
import NotchBuddyCore

/// The island's sounds, as the settings say: per-event system sound, master switch, volume.
///
/// `IslandSounds.play(_:)` forwards here (`.finished`, `.attention`, `.permission`, `.error`). Several events within
/// `minimumGap` make one sound.
@MainActor
enum SettingsSounds {
    private static let minimumGap: TimeInterval = 0.8
    /// Monotonic seconds: setting the wall clock back must not silence every sound.
    private static var lastPlayed = -TimeInterval.infinity
    private static var current: NSSound?

    static func play(_ event: SoundEvent) {
        play(event, settings: SettingsStore.shared.values)
    }

    static func play(_ event: SoundEvent, settings: NotchSettings) {
        guard let name = settings.audibleSound(for: event) else { return }
        let now = AppClock.monotonicSeconds()
        guard now - lastPlayed >= minimumGap, let sound = NSSound(named: NSSound.Name(name)) else { return }
        lastPlayed = now
        current?.stop()
        sound.stop()
        sound.volume = Float(settings.soundVolume)
        sound.play()
        current = sound
    }

    /// Sounds the user can pick: the system's, plus any in /Library/Sounds and ~/Library/Sounds, by name.
    static let catalog: [String] = {
        let fm = FileManager.default
        let dirs = [URL(fileURLWithPath: "/System/Library/Sounds"), URL(fileURLWithPath: "/Library/Sounds"),
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds")]
        let extensions: Set<String> = ["aiff", "aif", "caf", "wav", "m4a", "mp3"]
        var names = Set<String>()
        for dir in dirs {
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where extensions.contains(url.pathExtension.lowercased()) {
                names.insert(url.deletingPathExtension().lastPathComponent)
            }
        }
        if names.isEmpty { names = Set(fallbackCatalog) }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()

    /// macOS's own sounds (used when the folders cannot be read).
    static let fallbackCatalog = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop",
                                  "Purr", "Sosumi", "Submarine", "Tink"]

    /// Display name ("" is silence).
    static func label(_ name: String) -> String { name.isEmpty ? L("Без звука") : name }
}

/// Plays one sound at a time for the settings page and says which one is playing (for the waveform).
@MainActor
final class SoundPreviewer: NSObject, ObservableObject, NSSoundDelegate {
    @Published private(set) var playing: String?
    private var sound: NSSound?

    func toggle(_ name: String, volume: Double) {
        if playing == name {
            stop()
        } else {
            play(name, volume: volume)
        }
    }

    func play(_ name: String, volume: Double) {
        stop()
        guard !name.isEmpty, let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = Float(max(volume, 0.05))
        sound.delegate = self
        self.sound = sound
        playing = name
        sound.play()
    }

    func stop() {
        sound?.delegate = nil
        sound?.stop()
        sound = nil
        playing = nil
    }

    nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        let id = ObjectIdentifier(sound)
        Task { @MainActor in
            guard let current = self.sound, ObjectIdentifier(current) == id else { return }
            self.sound = nil
            self.playing = nil
        }
    }
}
