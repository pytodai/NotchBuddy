import Foundation
import Observation

/// The system widget's settings (⚙️ in the open island), kept in `UserDefaults` under `system.*`.
@Observable
@MainActor
final class SystemPreferences {
    enum Key {
        static let lowBatteryLiveActivity = "system.lowBatteryLiveActivity"
        static let lowBatteryThreshold = "system.lowBatteryThreshold"
        static let powerNotices = "system.powerNotices"
        static let showsCPU = "system.showsCPU"
        static let showsMemory = "system.showsMemory"
        static let showsDisk = "system.showsDisk"
    }

    /// Choices for "low battery at".
    static let thresholds = [10, 15, 20, 30]

    @ObservationIgnored let defaults: UserDefaults

    /// The closed island shows the battery when it runs low on battery power.
    var lowBatteryLiveActivity: Bool {
        didSet { defaults.set(lowBatteryLiveActivity, forKey: Key.lowBatteryLiveActivity) }
    }

    /// Percent at which the battery counts as low.
    var lowBatteryThreshold: Int {
        didSet { defaults.set(lowBatteryThreshold, forKey: Key.lowBatteryThreshold) }
    }

    /// A short notice on plugging in / unplugging and at full charge.
    var powerNotices: Bool {
        didSet { defaults.set(powerNotices, forKey: Key.powerNotices) }
    }

    var showsCPU: Bool {
        didSet { defaults.set(showsCPU, forKey: Key.showsCPU) }
    }

    var showsMemory: Bool {
        didSet { defaults.set(showsMemory, forKey: Key.showsMemory) }
    }

    var showsDisk: Bool {
        didSet { defaults.set(showsDisk, forKey: Key.showsDisk) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lowBatteryLiveActivity = defaults.object(forKey: Key.lowBatteryLiveActivity) as? Bool ?? true
        let threshold = defaults.object(forKey: Key.lowBatteryThreshold) as? Int ?? 20
        lowBatteryThreshold = Self.thresholds.contains(threshold) ? threshold : 20
        powerNotices = defaults.object(forKey: Key.powerNotices) as? Bool ?? true
        showsCPU = defaults.object(forKey: Key.showsCPU) as? Bool ?? true
        showsMemory = defaults.object(forKey: Key.showsMemory) as? Bool ?? true
        showsDisk = defaults.object(forKey: Key.showsDisk) as? Bool ?? true
    }
}
