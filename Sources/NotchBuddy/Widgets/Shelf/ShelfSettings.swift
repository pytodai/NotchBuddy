import Foundation
import NotchBuddyCore
import Observation

/// The shelf's settings (`UserDefaults`), for the ⚙️ panel (`ShelfSettingsSection`) and the store.
@MainActor
@Observable
final class ShelfSettings {
    static let shared = ShelfSettings()

    enum Key {
        static let enabled = "shelf.enabled"
        static let copyPolicy = "shelf.copyPolicy"
        static let opensOnDrag = "shelf.opensOnDrag"
        static let showsBadge = "shelf.showsBadge"
    }

    /// The shelf exists at all (its tab, badge and drop target).
    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Key.enabled) }
    }

    /// Which dropped files the shelf copies into its own storage.
    var copyPolicy: ShelfCopyPolicy {
        didSet { defaults.set(copyPolicy.rawValue, forKey: Key.copyPolicy) }
    }

    /// A file dragged toward the island opens the shelf under it.
    var opensOnDrag: Bool {
        didSet { defaults.set(opensOnDrag, forKey: Key.opensOnDrag) }
    }

    /// The closed island shows how many files are on the shelf.
    var showsBadge: Bool {
        didSet { defaults.set(showsBadge, forKey: Key.showsBadge) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        copyPolicy = defaults.string(forKey: Key.copyPolicy).flatMap(ShelfCopyPolicy.init(rawValue:)) ?? .default
        opensOnDrag = defaults.object(forKey: Key.opensOnDrag) as? Bool ?? true
        showsBadge = defaults.object(forKey: Key.showsBadge) as? Bool ?? true
    }
}

extension ShelfCopyPolicy {
    /// Segment title in the settings.
    var title: String {
        switch self {
        case .never: return L("Никогда")
        case .temporaryOnly: return L("Временные")
        case .always: return L("Всегда")
        }
    }

    /// One line under the segments.
    var explanation: String {
        switch self {
        case .never:
            return L("Полка хранит ссылки: удалишь оригинал — он исчезнет и с полки.")
        case .temporaryOnly:
            return L("Снимки экрана, вложения и прочие временные файлы полка копирует к себе — они не пропадут.")
        case .always:
            return L("Полка хранит свою копию каждого файла. Убранные копии уходят в Корзину.")
        }
    }
}
