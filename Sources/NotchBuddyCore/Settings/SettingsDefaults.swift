import Foundation

/// UserDefaults keys of every setting. Keys that existed before the settings page keep their names, so the
/// menu bar menu, `@AppStorage` users and `defaults write` keep working.
public enum SettingsKey {
    // Kept from earlier versions.
    public static let soundsEnabled = "soundsEnabled"
    public static let claudeUsageViaAPI = "usageNetworkEnabled"
    /// The earlier `defaults write … usageNetworkDisabled -bool true` opt-out (read by the migration only).
    public static let legacyUsageNetworkDisabled = "usageNetworkDisabled"
    public static let didOfferHooks = "didOfferHooks"

    public static let schemaVersion = "settings.schemaVersion"
    public static let soundVolume = "settings.sounds.volume"
    public static func sound(_ event: SoundEvent) -> String { "settings.sounds.\(event.rawValue)" }
    public static let kimiUsageViaAPI = "settings.usage.kimiAPI"
    public static let usageRefresh = "settings.usage.refreshSeconds"
    public static let usageProvider = "settings.usage.provider"
    public static let usageRing = "settings.widgets.usageRing"
    public static let hoverOpen = "settings.island.hoverOpen"
    public static let openOnPermission = "settings.island.openOnPermission"
    public static let showWithoutSessions = "settings.island.showWithoutSessions"
    public static let flashDuration = "settings.island.flashSeconds"
    public static let showsAgentReply = "settings.island.showsAgentReply"
    public static let pinOnOpen = "settings.island.pinOnOpen"
    public static let size = "settings.island.size"
    public static let screen = "settings.island.screen"
    /// «Стиль» on screens with a camera notch / on every other screen (monitors): «notch» or «island».
    public static let islandStyleNotched = "settings.island.style.notched"
    public static let islandStyleMonitors = "settings.island.style.monitors"
    /// «Ширина капсулы» of the closed «Островок», in points.
    public static let capsuleWidth = "settings.island.capsuleWidth"
    /// The dragged «Островок»'s offset per display (`IslandDisplayKey` → points).
    public static let islandOffsets = "settings.island.offsets"
    /// «Где показывать»: «all» / «only» / «except», the two lists of apps ("bundle id\tname"), and «Всегда показывать
    /// запросы агентов».
    public static let appFilter = "settings.island.apps.filter"
    public static let appsShownIn = "settings.island.apps.only"
    public static let appsHiddenIn = "settings.island.apps.except"
    public static let alwaysShowAgentRequests = "settings.island.apps.alwaysShowRequests"
    /// The former per-display styles (display UUID → «notch» / «island»), read by the migration only: a
    /// monitor whose UUID changed (another port, a dock) lost its choice.
    public static let legacyIslandStyles = "settings.island.styles"
    public static let hotkeyEnabled = "settings.hotkey.enabled"
    public static let hotkey = "settings.hotkey.combo"
    public static let widgets = "settings.widgets"
    public static let accent = "settings.appearance.accent"
    public static let motion = "settings.appearance.motion"
    /// «auto» / «ru» / «en» (`L10n` reads it too, also from the bridge).
    public static let language = L10n.settingsKey

    /// Every key the settings own (for tests and "reset").
    public static var all: [String] { NotchSettings.fields.map(\.key) + [schemaVersion] }
}

extension NotchSettings {
    /// Reads every setting; a missing or unreadable value falls back to its default.
    public static func load(from defaults: UserDefaults) -> NotchSettings {
        var settings = NotchSettings()
        for field in fields {
            if let stored = defaults.object(forKey: field.key) { field.read(&settings, stored) }
        }
        return settings
    }

    /// Writes the settings that differ from `old` (all of them when `old` is nil). Returns the keys written.
    @discardableResult
    public func save(to defaults: UserDefaults, changedFrom old: NotchSettings? = nil) -> [String] {
        var written: [String] = []
        for field in Self.fields where old.map({ field.differs(self, $0) }) ?? true {
            defaults.set(field.write(self), forKey: field.key)
            written.append(field.key)
        }
        return written
    }

    // MARK: Fields

    struct Field {
        let key: String
        let read: (inout NotchSettings, Any) -> Void
        let write: (NotchSettings) -> Any
        let differs: (NotchSettings, NotchSettings) -> Bool
    }

    private static func field<V: Equatable>(_ key: String, _ path: WritableKeyPath<NotchSettings, V>,
                                            decode: @escaping (Any) -> V?, encode: @escaping (V) -> Any) -> Field {
        Field(key: key,
              read: { settings, stored in if let value = decode(stored) { settings[keyPath: path] = value } },
              write: { encode($0[keyPath: path]) },
              differs: { $0[keyPath: path] != $1[keyPath: path] })
    }

    private static func bool(_ key: String, _ path: WritableKeyPath<NotchSettings, Bool>) -> Field {
        field(key, path, decode: SettingsCoercion.bool, encode: { $0 })
    }

    private static func raw<V: RawRepresentable & Equatable>(_ key: String, _ path: WritableKeyPath<NotchSettings, V>) -> Field
    where V.RawValue == String {
        field(key, path, decode: { ($0 as? String).flatMap(V.init(rawValue:)) }, encode: { $0.rawValue })
    }

    private static func int<V: RawRepresentable & Equatable>(_ key: String, _ path: WritableKeyPath<NotchSettings, V>) -> Field
    where V.RawValue == Int {
        field(key, path, decode: { SettingsCoercion.int($0).flatMap(V.init(rawValue:)) }, encode: { $0.rawValue })
    }

    static let fields: [Field] = {
        var fields: [Field] = [
            bool(SettingsKey.soundsEnabled, \.soundsEnabled),
            field(SettingsKey.soundVolume, \.soundVolume,
                  decode: { SettingsCoercion.double($0).map { min(max($0, 0), 1) } }, encode: { $0 }),
            bool(SettingsKey.claudeUsageViaAPI, \.claudeUsageViaAPI),
            bool(SettingsKey.kimiUsageViaAPI, \.kimiUsageViaAPI),
            int(SettingsKey.usageRefresh, \.usageRefresh),
            raw(SettingsKey.usageProvider, \.usageProvider),
            bool(SettingsKey.usageRing, \.showsUsageRing),
            raw(SettingsKey.hoverOpen, \.hoverOpen),
            bool(SettingsKey.openOnPermission, \.openOnPermission),
            bool(SettingsKey.showWithoutSessions, \.showWithoutSessions),
            int(SettingsKey.flashDuration, \.flashDuration),
            bool(SettingsKey.showsAgentReply, \.showsAgentReply),
            bool(SettingsKey.pinOnOpen, \.pinOnOpen),
            raw(SettingsKey.size, \.size),
            raw(SettingsKey.screen, \.screen),
            raw(SettingsKey.islandStyleNotched, \.islandStyleNotched),
            raw(SettingsKey.islandStyleMonitors, \.islandStyleMonitors),
            field(SettingsKey.capsuleWidth, \.capsuleWidth,
                  decode: { SettingsCoercion.double($0).map(NotchSettings.clampedCapsuleWidth) }, encode: { $0 }),
            field(SettingsKey.islandOffsets, \.islandOffsets,
                  decode: { stored in
                      guard let map = stored as? [String: Any] else { return nil }
                      var offsets: [String: Double] = [:]
                      for (key, value) in map where !key.isEmpty {
                          guard let x = SettingsCoercion.double(value).map(NotchSettings.storedOffset), x != 0 else { continue }
                          offsets[key] = x
                      }
                      return offsets
                  },
                  encode: { $0 }),
            raw(SettingsKey.appFilter, \.appFilter),
            field(SettingsKey.appsShownIn, \.appsShownIn, decode: SettingsCoercion.apps, encode: { $0.map(\.stored) }),
            field(SettingsKey.appsHiddenIn, \.appsHiddenIn, decode: SettingsCoercion.apps, encode: { $0.map(\.stored) }),
            bool(SettingsKey.alwaysShowAgentRequests, \.alwaysShowAgentRequests),
            bool(SettingsKey.hotkeyEnabled, \.hotkeyEnabled),
            raw(SettingsKey.hotkey, \.hotkey),
            field(SettingsKey.widgets, \.widgets,
                  decode: { ($0 as? [String]).map { WidgetEntry.normalized($0.compactMap(WidgetEntry.init(stored:))) } },
                  encode: { $0.map(\.stored) }),
            raw(SettingsKey.accent, \.accent),
            raw(SettingsKey.motion, \.motion),
            raw(SettingsKey.language, \.language),
            bool(SettingsKey.didOfferHooks, \.didOfferHooks),
        ]
        for event in SoundEvent.allCases {
            fields.append(Field(
                key: SettingsKey.sound(event),
                read: { settings, stored in if let name = stored as? String { settings.sounds[event] = name } },
                write: { $0.sound(for: event) },
                differs: { $0.sound(for: event) != $1.sound(for: event) }))
        }
        return fields
    }()
}

/// Tolerant readers: values written by hand (`defaults write … -string YES`) still count.
enum SettingsCoercion {
    static func bool(_ value: Any) -> Bool? {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.lowercased() {
            case "1", "yes", "true", "on": return true
            case "0", "no", "false", "off": return false
            default: return nil
            }
        default: return nil
        }
    }

    static func int(_ value: Any) -> Int? {
        switch value {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    static func double(_ value: Any) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue.isFinite ? n.doubleValue : nil
        case let s as String: return Double(s.replacingOccurrences(of: ",", with: "."))
        default: return nil
        }
    }

    /// A list of chosen apps ("bundle id\tname" each, or a bare bundle id written by hand); unreadable entries and
    /// repeats are dropped.
    static func apps(_ value: Any) -> [ChosenApp]? {
        guard let list = value as? [Any] else { return nil }
        return ChosenApp.unique(list.compactMap { ($0 as? String).flatMap(ChosenApp.init(stored:)) })
    }
}

// MARK: - Migration

public enum SettingsMigration {
    public static let currentVersion = 3

    /// Brings stored settings up to `currentVersion`. Idempotent; returns what it changed (for the log).
    @discardableResult
    public static func migrate(_ defaults: UserDefaults) -> [String] {
        let version = defaults.object(forKey: SettingsKey.schemaVersion).flatMap(SettingsCoercion.int) ?? 0
        guard version < currentVersion else { return [] }
        var steps: [String] = []
        if version < 1 {
            // v1: the settings page. The API toggle replaces the hidden `usageNetworkDisabled` opt-out.
            if defaults.object(forKey: SettingsKey.claudeUsageViaAPI) == nil,
               let disabled = defaults.object(forKey: SettingsKey.legacyUsageNetworkDisabled).flatMap(SettingsCoercion.bool),
               disabled {
                defaults.set(false, forKey: SettingsKey.claudeUsageViaAPI)
                steps.append("usageNetworkDisabled → usageNetworkEnabled=false")
            }
            // Booleans written as strings by hand become real booleans (`@AppStorage` reads only those).
            for key in [SettingsKey.soundsEnabled, SettingsKey.claudeUsageViaAPI, SettingsKey.didOfferHooks] {
                if let text = defaults.object(forKey: key) as? String {
                    if let value = SettingsCoercion.bool(text) {
                        defaults.set(value, forKey: key)
                        steps.append("\(key): \"\(text)\" → \(value)")
                    } else {
                        defaults.removeObject(forKey: key)
                        steps.append("\(key): unreadable \"\(text)\" removed")
                    }
                }
            }
        }
        if version < 2 {
            // v2: widgets are the island's tabs. The usage ring ("usage:x" among the widgets) became its own switch;
            // "nowPlaying" is «Музыка»; the weather placeholder is gone.
            if let stored = defaults.object(forKey: SettingsKey.widgets) as? [String] {
                if defaults.object(forKey: SettingsKey.usageRing) == nil, let ring = WidgetEntry.legacyUsageRing(in: stored) {
                    defaults.set(ring, forKey: SettingsKey.usageRing)
                    steps.append("usage ring \(ring ? "on" : "off") moved out of the widgets")
                }
                let widgets = WidgetEntry.normalized(stored.compactMap(WidgetEntry.init(stored:)))
                defaults.set(widgets.map(\.stored), forKey: SettingsKey.widgets)
                steps.append("widgets → \(widgets.map(\.stored).joined(separator: ","))")
            }
            // The global hotkey is on by default now (⌃⌥Space). Earlier versions had it off with ⌃⌥N: a stored
            // "off" that was never paired with a combo of the user's own gives way to the new default.
            let combo = (defaults.object(forKey: SettingsKey.hotkey) as? String).flatMap(HotkeyCombo.init(rawValue:))
            if let enabled = defaults.object(forKey: SettingsKey.hotkeyEnabled).flatMap(SettingsCoercion.bool), !enabled,
               combo == nil || combo == .legacyDefault {
                defaults.removeObject(forKey: SettingsKey.hotkeyEnabled)
                defaults.removeObject(forKey: SettingsKey.hotkey)
                steps.append("hotkey → ⌃⌥Space, on")
            } else if defaults.object(forKey: SettingsKey.hotkeyEnabled) == nil, combo == .legacyDefault {
                defaults.removeObject(forKey: SettingsKey.hotkey)
            }
        }
        if version < 3 {
            // v3: ⌃⌥Space switched keyboard layouts on most Macs (macOS' "Select next source in Input menu"): the
            // default is ⌃⌥N now, and a stored ⌃⌥Space gives way to it.
            let combo = (defaults.object(forKey: SettingsKey.hotkey) as? String).flatMap(HotkeyCombo.init(rawValue:))
            if combo == .formerDefault {
                defaults.removeObject(forKey: SettingsKey.hotkey)
                steps.append("hotkey ⌃⌥Space → ⌃⌥N")
            }
            // «Стиль» per kind of screen instead of per display UUID (a monitor's UUID changes with the port or dock it
            // hangs on): a display set to «Островок» makes it the monitors' style.
            if let map = defaults.object(forKey: SettingsKey.legacyIslandStyles) as? [String: Any] {
                if defaults.object(forKey: SettingsKey.islandStyleMonitors) == nil,
                   map.values.contains(where: { ($0 as? String) == IslandStyle.island.rawValue }) {
                    defaults.set(IslandStyle.island.rawValue, forKey: SettingsKey.islandStyleMonitors)
                    steps.append("island style per display → monitors: island")
                }
                defaults.removeObject(forKey: SettingsKey.legacyIslandStyles)
            }
        }
        defaults.set(currentVersion, forKey: SettingsKey.schemaVersion)
        return steps
    }
}
