import Foundation
import Observation
import NotchBuddyCore

/// The timer widget's settings (⚙️ in the open island), kept in `UserDefaults` under `timer.*`.
@Observable
@MainActor
final class TimerPreferences {
    enum Key {
        static let sound = "timer.sound"
        static let celebrate = "timer.celebrate"
        static let liveActivity = "timer.liveActivity"
        static let customSeconds = "timer.customSeconds"
        static let saved = "timer.saved"
    }

    /// System sounds offered for the end of a timer, with localized names ("" is silence).
    static var sounds: [(name: String, title: String)] {
        [
            ("Hero", L("Фанфары")), ("Glass", L("Стекло")), ("Purr", L("Мурлыканье")), ("Submarine", L("Сонар")),
            ("Funk", L("Фанк")), ("Ping", L("Пинг")), ("Pop", L("Хлопок")), ("Tink", L("Колокольчик")), ("Bottle", L("Бутылка")),
            ("Blow", L("Порыв")), ("Morse", L("Морзе")), ("Frog", L("Лягушка")), ("Sosumi", L("Сосуми")), ("Basso", L("Бас")),
        ]
    }

    static func soundTitle(_ name: String) -> String {
        name.isEmpty ? L("Без звука") : sounds.first { $0.name == name }?.title ?? name
    }

    @ObservationIgnored let defaults: UserDefaults

    /// The sound at the end of a timer ("" is none).
    var sound: String {
        didSet { defaults.set(sound, forKey: Key.sound) }
    }

    /// Confetti and a burst of light when a timer ends (Reduce Motion: a glow only).
    var celebrate: Bool {
        didSet { defaults.set(celebrate, forKey: Key.celebrate) }
    }

    /// The closed island counts down the soonest timer.
    var liveActivity: Bool {
        didSet { defaults.set(liveActivity, forKey: Key.liveActivity) }
    }

    /// The custom picker's last value.
    var customSeconds: TimeInterval {
        didSet { defaults.set(customSeconds, forKey: Key.customSeconds) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sound = defaults.string(forKey: Key.sound) ?? "Hero"
        celebrate = defaults.object(forKey: Key.celebrate) as? Bool ?? true
        liveActivity = defaults.object(forKey: Key.liveActivity) as? Bool ?? true
        let custom = defaults.object(forKey: Key.customSeconds) as? Double ?? 7 * 60 + 30
        customSeconds = custom.isFinite ? min(max(custom, 5), 24 * 3600 - 1) : 450
    }
}
