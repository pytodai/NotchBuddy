import Foundation

/// Modifier keys of a global shortcut.
public struct HotkeyModifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = HotkeyModifiers(rawValue: 1 << 0)
    public static let option = HotkeyModifiers(rawValue: 1 << 1)
    public static let shift = HotkeyModifiers(rawValue: 1 << 2)
    public static let command = HotkeyModifiers(rawValue: 1 << 3)

    /// In the order macOS draws them: ⌃⌥⇧⌘.
    public var symbols: [String] {
        var result: [String] = []
        if contains(.control) { result.append("⌃") }
        if contains(.option) { result.append("⌥") }
        if contains(.shift) { result.append("⇧") }
        if contains(.command) { result.append("⌘") }
        return result
    }
}

/// A global shortcut: a virtual key code (kVK_*, layout independent) and modifiers.
public struct HotkeyCombo: Equatable, Hashable, Sendable, Codable, RawRepresentable {
    public var keyCode: UInt16
    public var modifiers: HotkeyModifiers

    public init(keyCode: UInt16, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌃⌥N («N» for NotchBuddy): one reach from the home row, taken by no macOS shortcut. (⌃⌥Space, a former default,
    /// is macOS' "Select next source in Input menu" wherever two keyboard layouts are set up.)
    public static let defaultToggle = HotkeyCombo(keyCode: 45, modifiers: [.control, .option])
    /// The default of the versions before the settings page (⌃⌥N, off out of the box).
    public static let legacyDefault = HotkeyCombo(keyCode: 45, modifiers: [.control, .option])
    /// A former default (⌃⌥Space): it switches keyboard layouts on most Macs with two of them.
    public static let formerDefault = HotkeyCombo(keyCode: 49, modifiers: [.control, .option])

    /// Offered as one-click choices: none is a macOS shortcut out of the box or a well-known one of other apps
    /// (the settings page still hides one the Mac has taken, `HotkeyClashes`).
    public static let presets: [HotkeyCombo] = [
        .defaultToggle,                                                  // ⌃⌥N
        HotkeyCombo(keyCode: 34, modifiers: [.control, .option]),        // ⌃⌥I
        HotkeyCombo(keyCode: 45, modifiers: [.control, .option, .command]), // ⌃⌥⌘N
        HotkeyCombo(keyCode: 49, modifiers: [.control, .option, .command]), // ⌃⌥⌘Space
    ]

    /// Carbon modifier flags (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`), as `RegisterEventHotKey` and the
    /// system's symbolic hotkeys use them.
    public var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= 0x0100 }
        if modifiers.contains(.shift) { result |= 0x0200 }
        if modifiers.contains(.option) { result |= 0x0800 }
        if modifiers.contains(.control) { result |= 0x1000 }
        return result
    }

    /// "6:45" (modifiers : key code).
    public var rawValue: String { "\(modifiers.rawValue):\(keyCode)" }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":")
        guard parts.count == 2, let mods = UInt8(parts[0]), let code = UInt16(parts[1]),
              HotkeyKeys.name(for: code) != nil else { return nil }
        self.init(keyCode: code, modifiers: HotkeyModifiers(rawValue: mods & 0x0F))
    }

    /// The key's name alone ("N", "Space", "F5").
    public var keyName: String { HotkeyKeys.name(for: keyCode) ?? "#\(keyCode)" }

    /// Keycaps as drawn: ["⌃", "⌥", "N"].
    public var keycaps: [String] { modifiers.symbols + [keyName] }

    /// "⌃⌥N", "⌃⌥Space".
    public var display: String { modifiers.symbols.joined() + keyName }

    /// A shortcut that would not hijack ordinary typing: it needs ⌘, ⌃ or ⌥ (⇧ alone does not count),
    /// unless the key is a function key.
    public var isUsable: Bool {
        guard HotkeyKeys.name(for: keyCode) != nil, !HotkeyKeys.isModifier(keyCode) else { return false }
        if HotkeyKeys.isFunctionKey(keyCode) { return true }
        return !modifiers.intersection([.command, .control, .option]).isEmpty
    }
}

/// Names of the virtual key codes (US ANSI positions, `HIToolbox/Events.h`).
public enum HotkeyKeys {
    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 117: "⌦", 115: "Home", 119: "End", 116: "PgUp",
        121: "PgDn", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    private static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                                    105, 107, 113, 106, 64, 79, 80, 90]
    /// ⌘ ⇧ ⇪ ⌥ ⌃ (both sides) and fn.
    private static let modifierKeys: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    public static func name(for keyCode: UInt16) -> String? { names[keyCode] }
    public static func isFunctionKey(_ keyCode: UInt16) -> Bool { functionKeys.contains(keyCode) }
    public static func isModifier(_ keyCode: UInt16) -> Bool { modifierKeys.contains(keyCode) }
}

/// Shortcuts a global hotkey must not take: the Mac's own ("symbolic hotkeys": switching keyboard layouts, Spotlight,
/// Show Desktop, Mission Control…, read live by the app) and a few well-known ones of other apps (a warning only).
public enum HotkeyClashes {
    /// One of the Mac's shortcuts as `CopySymbolicHotKeys` reports it.
    public struct SystemHotkey: Equatable, Sendable {
        public var keyCode: UInt16
        /// Carbon modifier flags; the fn flag (0x20000, set on function keys) is ignored.
        public var carbonModifiers: UInt32
        public var enabled: Bool

        public init(keyCode: UInt16, carbonModifiers: UInt32, enabled: Bool) {
            self.keyCode = keyCode
            self.carbonModifiers = carbonModifiers
            self.enabled = enabled
        }
    }

    /// The four modifiers a hotkey can carry (⌘ ⇧ ⌥ ⌃), without fn, Caps Lock or the keypad flag.
    static let modifierMask: UInt32 = 0x0100 | 0x0200 | 0x0800 | 0x1000

    /// What macOS calls the shortcut `combo` would steal (nil: none of the enabled ones).
    public static func system(_ combo: HotkeyCombo, in hotkeys: [SystemHotkey]) -> String? {
        let mods = combo.carbonModifiers
        guard hotkeys.contains(where: { $0.enabled && $0.keyCode == combo.keyCode
            && ($0.carbonModifiers & modifierMask) == mods }) else { return nil }
        return systemName(combo)
    }

    /// The name of a macOS shortcut (the defaults of System Settings → Keyboard → Keyboard Shortcuts), or a generic one.
    public static func systemName(_ combo: HotkeyCombo) -> String {
        let ctrl: HotkeyModifiers = [.control]
        switch (combo.keyCode, combo.modifiers) {
        case (49, ctrl): return L("Предыдущий источник ввода")
        case (49, [.control, .option]): return L("Следующий источник ввода")
        case (49, [.command]): return L("Поиск Spotlight")
        case (49, [.option, .command]): return L("Окно поиска Finder")
        case (103, []): return L("Показать рабочий стол")
        case (126, ctrl): return "Mission Control"
        case (125, ctrl): return L("Окна программы")
        case (123, ctrl), (124, ctrl): return L("Переход между столами")
        case (20, [.shift, .command]), (21, [.shift, .command]), (23, [.shift, .command]): return L("Снимок экрана")
        case (50, [.command]): return L("Следующее окно")
        default: return L("сочетание macOS")
        }
    }

    /// A well-known shortcut of other apps that a global hotkey would take from them (a warning, not a refusal).
    public static func app(_ combo: HotkeyCombo) -> String? {
        switch (combo.keyCode, combo.modifiers) {
        case (34, [.option, .command]), (38, [.option, .command]): return L("инструменты разработчика в браузерах")
        case (50, [.control]): return L("терминал в VS Code")
        case (103, []), (111, []): return L("клавиши F11 и F12 в программах")
        case (49, [.control]), (49, [.command]), (49, [.shift, .command]): return L("переключение раскладки")
        default: return nil
        }
    }
}
