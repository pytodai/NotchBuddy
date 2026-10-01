import Foundation

// Every user setting of NotchBuddy as plain values: what the settings page edits and the app reads.
// Persistence (keys, defaults, migration) is in `SettingsDefaults.swift`.

// MARK: - Sounds

/// Something that can make a sound.
public enum SoundEvent: String, CaseIterable, Codable, Sendable {
    /// An agent finished its turn.
    case finished
    /// An agent needs the user (a notification, "ждёт тебя").
    case attention
    /// A new permission request reached the island.
    case permission
    /// A session failed.
    case error

    /// The sound the app made before settings existed (errors made none).
    public var defaultSound: String {
        switch self {
        case .finished: return "Glass"
        case .attention, .permission: return "Ping"
        case .error: return ""
        }
    }

    public var title: String {
        switch self {
        case .finished: return L("Агент закончил")
        case .attention: return L("Ждёт тебя")
        case .permission: return L("Запрос разрешения")
        case .error: return L("Ошибка")
        }
    }
}

// MARK: - Island behaviour

/// How long the pointer rests on the closed island before the list opens.
public enum HoverOpenDelay: String, CaseIterable, Codable, Sendable {
    case instant, quick, relaxed, slow
    /// Hover never opens the list; a click does.
    case never

    /// Open once the pointer has rested this long (nil: hover does not open).
    public var restDwell: TimeInterval? {
        switch self {
        case .instant: return 0
        case .quick: return 0.09
        case .relaxed: return 0.3
        case .slow: return 0.6
        case .never: return nil
        }
    }

    /// Open after this long over the island even while the pointer keeps moving (nil: hover does not open).
    public var maxDwell: TimeInterval? {
        switch self {
        case .instant: return 0.06
        case .quick: return 0.22
        case .relaxed: return 0.5
        case .slow: return 0.9
        case .never: return nil
        }
    }

    public var label: String {
        switch self {
        case .instant: return L("Сразу")
        case .quick: return L("0,1 с")
        case .relaxed: return L("0,3 с")
        case .slow: return L("0,6 с")
        case .never: return L("По клику")
        }
    }
}

/// How long a notice ("Готово", "Ждёт тебя") stays on the island.
public enum FlashDuration: Int, CaseIterable, Codable, Sendable {
    case short = 3
    case normal = 5
    case long = 8
    case veryLong = 12

    public var seconds: TimeInterval { TimeInterval(rawValue) }
    public var label: String { L("%@ с", rawValue) }
}

/// Overall scale of the open island.
public enum IslandSize: String, CaseIterable, Codable, Sendable {
    case small = "s"
    case medium = "m"
    case large = "l"

    /// Multiplier for the open island's widths.
    public var scale: Double {
        switch self {
        case .small: return 0.9
        case .medium: return 1
        case .large: return 1.12
        }
    }

    public var label: String {
        switch self {
        case .small: return L("Компактный")
        case .medium: return L("Обычный")
        case .large: return L("Крупный")
        }
    }
}

/// How the island sits at the top of a screen.
public enum IslandStyle: String, CaseIterable, Codable, Sendable {
    /// «Чёлка»: flush with the top edge, concave ears flaring into it (wraps the camera housing on a notched screen).
    case notch
    /// «Островок»: a detached black capsule floating just below the top edge, rounded all around (like the Dynamic
    /// Island of an iPhone 15 Pro). It grows downward from its own top; closed, it is a compact capsule.
    case island

    public var label: String {
        switch self {
        case .notch: return L("Чёлка")
        case .island: return L("Островок")
        }
    }
}

/// Which screen the island lives on.
public enum ScreenChoice: Equatable, Hashable, Sendable, RawRepresentable, Codable {
    /// The screen that holds the frontmost app's window (the island follows it).
    case activeWindow
    /// Always the main screen (the one with the menu bar in System Settings → Displays).
    case main
    /// One particular display. `id` is the display's UUID (stable across reconnects); `name` is shown when
    /// the display is not connected.
    case display(id: String, name: String)

    public init?(rawValue: String) {
        switch rawValue {
        case "activeWindow": self = .activeWindow
        case "main": self = .main
        default:
            guard rawValue.hasPrefix("display:") else { return nil }
            let body = rawValue.dropFirst("display:".count)
            let parts = body.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let id = parts.first, !id.isEmpty else { return nil }
            self = .display(id: String(id), name: parts.count > 1 ? String(parts[1]) : "")
        }
    }

    public var rawValue: String {
        switch self {
        case .activeWindow: return "activeWindow"
        case .main: return "main"
        case .display(let id, let name): return "display:\(id)\t\(name)"
        }
    }
}

// MARK: - Usage

public enum UsageRefreshInterval: Int, CaseIterable, Codable, Sendable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    public var seconds: TimeInterval { TimeInterval(rawValue) }
    public var label: String { L("%@ мин", rawValue / 60) }
}

// MARK: - Appearance

public enum MotionPreference: String, CaseIterable, Codable, Sendable {
    /// Follow System Settings → Accessibility → Display → Reduce motion.
    case system
    /// Full motion even when the system asks to reduce it.
    case full
    /// Reduced motion whatever the system says.
    case reduced

    public func reduceMotion(system: Bool) -> Bool {
        switch self {
        case .system: return system
        case .full: return false
        case .reduced: return true
        }
    }

    public var label: String {
        switch self {
        case .system: return L("Как в системе")
        case .full: return L("Полные")
        case .reduced: return L("Сниженные")
        }
    }
}

/// The accent of the settings page's controls (toggles, selections, progress): calm system tones only (no violet or
/// pink: the island itself stays black and white). A stored «violet» / «pink» of earlier versions reads as the default.
public enum AccentChoice: String, CaseIterable, Codable, Sendable {
    case azure, mint, lime, amber, coral, graphite

    /// sRGB components.
    public var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .azure: return (0.33, 0.64, 1.0)
        case .coral: return (1.0, 0.45, 0.36)
        case .amber: return (1.0, 0.7, 0.22)
        case .lime: return (0.55, 0.88, 0.3)
        case .mint: return (0.3, 0.86, 0.74)
        case .graphite: return (0.78, 0.8, 0.84)
        }
    }

    public var label: String {
        switch self {
        case .azure: return L("Лазурь")
        case .coral: return L("Коралл")
        case .amber: return L("Янтарь")
        case .lime: return L("Лайм")
        case .mint: return L("Мята")
        case .graphite: return L("Графит")
        }
    }
}

// MARK: - Language

extension AppLanguage {
    /// «Авто» in the interface language; the languages by their own names («Русский», «English»).
    public var label: String {
        switch self {
        case .auto: return L("Авто")
        case .ru: return UILanguage.ru.nativeName
        case .en: return UILanguage.en.nativeName
        }
    }
}

// MARK: - Widgets ("островки")

/// The island's widgets ("островки"): each is a tab of the open island and may show a live activity in the closed one.
/// «Агенты» (the sessions and their usage) is always there; the others are opt-in (Settings → Островки).
public enum WidgetKind: String, CaseIterable, Codable, Sendable {
    case agents, music, calendar, timer, system, shelf

    public var title: String {
        switch self {
        case .agents: return L("Агенты")
        case .music: return L("Музыка")
        case .calendar: return L("Календарь")
        case .timer: return L("Таймер")
        case .system: return L("Система")
        case .shelf: return L("Полка")
        }
    }

    public var subtitle: String {
        switch self {
        case .agents: return L("Сессии и лимиты — всегда на месте")
        case .music: return L("Трек, обложка и управление")
        case .calendar: return L("Встречи сегодня и завтра")
        case .timer: return L("Таймеры и помодоро")
        case .system: return L("Батарея, процессор, память")
        case .shelf: return L("Файлы под рукой: перетащи на остров")
        }
    }

    /// SF Symbol (the settings rows; the island draws its own icon set).
    public var symbol: String {
        switch self {
        case .agents: return "sparkles"
        case .music: return "music.note"
        case .calendar: return "calendar"
        case .timer: return "timer"
        case .system: return "cpu"
        case .shelf: return "tray.fill"
        }
    }

    /// Always on (it cannot be switched off, only moved).
    public var isRequired: Bool { self == .agents }

    /// Whether the island can already show it (all of them can).
    public var isAvailable: Bool { true }

    /// Only «Агенты» out of the box: without another widget the island has no tab strip.
    public var enabledByDefault: Bool { self == .agents }

    /// The island page that shows it (`IslandPages`); «Агенты» is the island's own list.
    public var pageID: String? { self == .agents ? nil : "widget.\(rawValue)" }

    /// The widget a page id shows ("widget.music" → .music).
    public init?(pageID: String) {
        guard pageID.hasPrefix("widget."), let kind = WidgetKind(rawValue: String(pageID.dropFirst("widget.".count))),
              kind != .agents else { return nil }
        self = kind
    }

    /// A stored name, including the ones earlier versions wrote ("nowPlaying" → music). The closed island's usage ring
    /// and the weather placeholder are no longer widgets (nil).
    public init?(storedName: String) {
        switch storedName {
        case "nowPlaying": self = .music
        case "usage", "weather": return nil
        default:
            guard let kind = WidgetKind(rawValue: storedName) else { return nil }
            self = kind
        }
    }
}

public struct WidgetEntry: Equatable, Hashable, Sendable, Codable {
    public var kind: WidgetKind
    public var enabled: Bool

    public init(_ kind: WidgetKind, enabled: Bool) {
        self.kind = kind
        self.enabled = enabled
    }

    public static var defaults: [WidgetEntry] {
        WidgetKind.allCases.map { WidgetEntry($0, enabled: $0.enabledByDefault) }
    }

    /// Every known widget exactly once, in the stored order: unknown and repeated ones are dropped, missing ones
    /// appended with their default state; a required one is always on.
    public static func normalized(_ entries: [WidgetEntry]) -> [WidgetEntry] {
        var seen = Set<WidgetKind>()
        var result = entries.filter { seen.insert($0.kind).inserted }
        for kind in WidgetKind.allCases where !seen.contains(kind) {
            result.append(WidgetEntry(kind, enabled: kind.enabledByDefault))
        }
        for index in result.indices where result[index].kind.isRequired { result[index].enabled = true }
        return result
    }

    /// "music:1".
    var stored: String { "\(kind.rawValue):\(enabled ? 1 : 0)" }

    init?(stored: String) {
        let parts = stored.split(separator: ":")
        guard parts.count == 2, let kind = WidgetKind(storedName: String(parts[0])) else { return nil }
        self.init(kind, enabled: parts[1] == "1")
    }

    /// The closed island's usage ring as earlier versions stored it among the widgets ("usage:0"), if it is there.
    static func legacyUsageRing(in stored: [String]) -> Bool? {
        for item in stored {
            let parts = item.split(separator: ":")
            if parts.count == 2, parts[0] == "usage" { return parts[1] == "1" }
        }
        return nil
    }
}

// MARK: - Usage display

/// Whose usage the island shows: «Авто» (every agent with numbers; the closed island's ring follows the session it
/// shows), or one agent. A click on the usage steps through them (`next`).
public enum UsageProviderChoice: String, CaseIterable, Codable, Sendable {
    case auto, claude, codex, kimi

    public var label: String {
        switch self {
        case .auto: return L("Авто")
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .kimi: return "Kimi"
        }
    }

    /// The agent it pins (nil: automatic).
    public var agent: AgentSource? {
        switch self {
        case .auto: return nil
        case .claude: return .claude
        case .codex: return .codex
        case .kimi: return .kimi
        }
    }

    /// Авто → Claude → Codex → Kimi → Авто.
    public var next: UsageProviderChoice {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

// MARK: - All settings

public struct NotchSettings: Equatable, Sendable {
    // Sounds
    public var soundsEnabled = true
    /// 0…1.
    public var soundVolume = 0.7
    /// System sound name per event; "" is silence.
    public var sounds: [SoundEvent: String] = Dictionary(uniqueKeysWithValues: SoundEvent.allCases.map { ($0, $0.defaultSound) })

    // Usage
    /// «Лимиты Claude через API»: keychain token + api.anthropic.com (off: statusLine only).
    public var claudeUsageViaAPI = true
    /// «Лимиты Kimi через API»: Kimi Code's own login (read only) + api.kimi.com, throttled (off: no Kimi row).
    public var kimiUsageViaAPI = false
    public var usageRefresh = UsageRefreshInterval.oneMinute
    /// Whose usage the list's footer and the closed island's ring show (a click on the usage steps through).
    public var usageProvider = UsageProviderChoice.auto
    /// The closed island's usage ring.
    public var showsUsageRing = true

    // Island
    public var hoverOpen = HoverOpenDelay.quick
    public var openOnPermission = true
    public var showWithoutSessions = false
    public var flashDuration = FlashDuration.normal
    /// «Показывать ответ агента при завершении»: a finished turn opens the «Готово» card with the agent's last answer.
    public var showsAgentReply = true
    public var pinOnOpen = false
    public var size = IslandSize.medium
    public var screen = ScreenChoice.activeWindow
    /// «Стиль» on a screen with a camera notch (the MacBook's own) and on every other screen (monitors).
    public var islandStyleNotched = IslandStyle.notch
    public var islandStyleMonitors = IslandStyle.notch
    /// «Ширина капсулы»: how wide the closed «Островок» is, in points (`capsuleWidthRange`). «Чёлка» ignores it.
    public var capsuleWidth = NotchSettings.defaultCapsuleWidth
    /// «Островок» dragged sideways: its center's offset from the screen's top center, per display (`IslandDisplayKey`),
    /// in points. A display it was never moved on is not stored (centered).
    public var islandOffsets: [String: Double] = [:]
    /// «Где показывать» (`IslandPlacementSettings.swift`): every app, only the chosen ones, or all but the chosen ones.
    public var appFilter = IslandAppFilter.all
    /// The apps of «Только в выбранных» and of «Везде, кроме выбранных» (each mode keeps its own list).
    public var appsShownIn: [ChosenApp] = []
    public var appsHiddenIn: [ChosenApp] = []
    /// «Всегда показывать запросы агентов»: permission cards and "needs you" notices show even where the island hides.
    public var alwaysShowAgentRequests = true

    // Hotkey (⌃⌥N out of the box)
    public var hotkeyEnabled = true
    public var hotkey = HotkeyCombo.defaultToggle

    // Widgets
    public var widgets = WidgetEntry.defaults

    // Appearance
    public var accent = AccentChoice.azure
    public var motion = MotionPreference.system

    // Language («Язык / Language»: Авто follows macOS)
    public var language = AppLanguage.auto

    // Bookkeeping
    /// The first-launch hook offer was answered (`HookInstallService.didOfferHooksKey`).
    public var didOfferHooks = false

    public init() {}

    /// «Ширина капсулы»: the slider's range and its default (about an iPhone's Dynamic Island with a live activity, at
    /// the closed island's height).
    public static let capsuleWidthRange: ClosedRange<Double> = 140...360
    public static let defaultCapsuleWidth: Double = 190

    /// A width the slider or `defaults write` gave, as the capsule takes it: whole points within the range.
    public static func clampedCapsuleWidth(_ width: Double) -> Double {
        guard width.isFinite else { return defaultCapsuleWidth }
        return min(max(width.rounded(), capsuleWidthRange.lowerBound), capsuleWidthRange.upperBound)
    }

    /// Whether either kind of screen uses «Островок» (where «Ширина капсулы» applies).
    public var usesIslandStyle: Bool { islandStyleNotched == .island || islandStyleMonitors == .island }

    public func sound(for event: SoundEvent) -> String {
        sounds[event] ?? event.defaultSound
    }

    /// What `play` should play for `event`, or nil for silence.
    public func audibleSound(for event: SoundEvent) -> String? {
        guard soundsEnabled, soundVolume > 0 else { return nil }
        let name = sound(for: event)
        return name.isEmpty ? nil : name
    }

    /// The look the island takes on a screen with (`hasNotch`) or without a camera notch.
    public func islandStyle(hasNotch: Bool) -> IslandStyle {
        hasNotch ? islandStyleNotched : islandStyleMonitors
    }

    public mutating func setIslandStyle(_ style: IslandStyle, hasNotch: Bool) {
        if hasNotch { islandStyleNotched = style } else { islandStyleMonitors = style }
    }

    public var enabledWidgets: [WidgetKind] {
        widgets.filter(\.enabled).map(\.kind)
    }

    /// Moves the widget at `from` to `to` (indices in `widgets`, `to` counted before the move).
    public mutating func moveWidget(from: Int, to: Int) {
        guard widgets.indices.contains(from) else { return }
        let target = min(max(to, 0), widgets.count - 1)
        guard target != from else { return }
        let entry = widgets.remove(at: from)
        widgets.insert(entry, at: target)
    }

    /// Everything back to the defaults, except bookkeeping.
    public func reset() -> NotchSettings {
        var fresh = NotchSettings()
        fresh.didOfferHooks = didOfferHooks
        return fresh
    }
}
