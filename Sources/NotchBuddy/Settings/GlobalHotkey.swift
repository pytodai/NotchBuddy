import AppKit
import Carbon.HIToolbox
import Combine
import NotchBuddyCore

/// The global shortcut that opens / closes the island (Carbon `RegisterEventHotKey`: no Accessibility or
/// Input Monitoring permission, and NotchBuddy is not activated, so no app loses the keyboard).
///
/// Usage: `GlobalHotkey.shared.bind(to: SettingsStore.shared) { island.toggleFromHotkey() }` once at
/// launch. It follows the settings live and steps aside while a new combo is being recorded.
@MainActor
final class GlobalHotkey: ObservableObject {
    enum Status: Equatable {
        case off
        case active(HotkeyCombo)
        /// Registration refused: another app owns this combo (or it is reserved by the system).
        case taken(HotkeyCombo)
        /// Not registered: it is one of the Mac's own shortcuts, switched on (`name`: what macOS calls it). Carbon would
        /// accept it without a word, and then either the island or, say, the keyboard layout switch would stop working.
        case system(HotkeyCombo, name: String)
    }

    static let shared = GlobalHotkey()

    @Published private(set) var status: Status = .off
    /// The Mac's own shortcut a combo would take (`SystemHotkeys`; previews and tests swap it).
    var systemConflict: (HotkeyCombo) -> String? = { SystemHotkeys.conflict($0) }
    /// Nothing is registered while true (the recorder needs the keys).
    var suspended = false {
        didSet { if suspended != oldValue { apply() } }
    }

    private var action: () -> Void = {}
    private var wanted: HotkeyCombo?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var cancellable: AnyCancellable?
    private static let signature: OSType = 0x4E_42_48_4B  // "NBHK"

    /// Keeps the registration in sync with `enabled` / `combo` in `store`; `action` runs on the main thread.
    func bind(to store: SettingsStore, action: @escaping () -> Void) {
        self.action = action
        cancellable = store.$values
            .map { $0.hotkeyEnabled ? $0.hotkey : nil }
            .removeDuplicates()
            .sink { [weak self] combo in self?.set(combo) }
    }

    func set(_ combo: HotkeyCombo?) {
        wanted = combo
        apply()
    }

    private func apply() {
        unregister()
        guard let combo = wanted, !suspended else {
            status = .off
            return
        }
        guard combo.isUsable else {
            status = .off
            return
        }
        if let name = systemConflict(combo) {
            status = .system(combo, name: name)
            Log.info("hotkey: \(combo.display) is the macOS shortcut “\(name)”, not registered")
            return
        }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let result = RegisterEventHotKey(UInt32(combo.keyCode), Self.carbonModifiers(combo.modifiers), id,
                                         GetApplicationEventTarget(), 0, &ref)
        if result == noErr, let ref {
            hotKeyRef = ref
            status = .active(combo)
            Log.info("hotkey: \(combo.display) registered")
        } else {
            status = .taken(combo)
            Log.info("hotkey: \(combo.display) not available (OSStatus \(result))")
        }
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == GlobalHotkey.signature else { return OSStatus(eventNotHandledErr) }
            // Carbon delivers application-target events on the main thread.
            MainActor.assumeIsolated { GlobalHotkey.shared.fire() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, &handlerRef)
    }

    /// Previews: a hotkey object that only shows `status`.
    static func preview(status: Status) -> GlobalHotkey {
        let hotkey = GlobalHotkey()
        hotkey.status = status
        return hotkey
    }

    private func fire() {
        guard !suspended, case .active = status else { return }
        action()
    }

    static func carbonModifiers(_ modifiers: HotkeyModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

/// Records a new shortcut on the settings page.
///
/// Recording needs key events, and the island never takes the keyboard on its own: `onKeyboardRequest(true)`
/// asks the island to make its panel key (only while the pointer is over the island, like the
/// permission card's ⌘Y), `false` hands it back. While recording, the island's own key monitor must let
/// events through to `handle(_:)` (the recorder installs a local monitor too). Esc cancels, ⌫ alone cancels;
/// the pointer leaving the island should call `cancel()`. Recording stops by itself after `timeout`.
@MainActor
final class HotkeyRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    /// Modifiers held right now (drawn live while recording).
    @Published private(set) var heldModifiers: HotkeyModifiers = []
    /// Bumped when a combo was rejected (the keycaps shake).
    @Published private(set) var rejections = 0
    @Published private(set) var lastRejected: String?

    var onKeyboardRequest: (Bool) -> Void = { _ in }
    var onCapture: (HotkeyCombo) -> Void = { _ in }
    /// The Mac's own shortcut a combo would take (tests swap it).
    var systemConflict: (HotkeyCombo) -> String? = { SystemHotkeys.conflict($0) }

    static let timeout: TimeInterval = 10
    private var monitor: Any?
    private var timeoutTask: Task<Void, Never>?

    func start() {
        guard !isRecording else { return }
        isRecording = true
        heldModifiers = []
        lastRejected = nil
        GlobalHotkey.shared.suspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            // Local monitors run on the main thread; only plain values cross into the actor.
            let key = KeyPress(event)
            let consumed = MainActor.assumeIsolated { self?.consume(key) ?? false }
            return consumed ? nil : event
        }
        onKeyboardRequest(true)
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.timeout))
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
    }

    func cancel() {
        guard isRecording else { return }
        finish()
    }

    /// Previews: the recording look, without listening to anything (`rejected`: the message shown).
    func showPreview(held: HotkeyModifiers, rejected: String? = nil) {
        isRecording = true
        heldModifiers = held
        lastRejected = rejected
    }

    /// A key event, reduced to what the recorder needs.
    struct KeyPress: Sendable {
        enum Kind: Sendable { case down, modifiers, other }
        var kind: Kind
        var keyCode: UInt16
        var modifiers: HotkeyModifiers
        var isRepeat: Bool

        init(kind: Kind, keyCode: UInt16, modifiers: HotkeyModifiers, isRepeat: Bool = false) {
            self.kind = kind
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.isRepeat = isRepeat
        }

        init(_ event: NSEvent) {
            switch event.type {
            case .keyDown: kind = .down
            case .flagsChanged: kind = .modifiers
            default: kind = .other
            }
            keyCode = event.keyCode
            modifiers = HotkeyRecorder.modifiers(event.modifierFlags)
            isRepeat = kind == .down && event.isARepeat
        }
    }

    /// Handles a key event while recording (for the island's own key monitor); nil when it was consumed.
    func handle(_ event: NSEvent) -> NSEvent? {
        consume(KeyPress(event)) ? nil : event
    }

    /// True when the key belonged to the recorder.
    @discardableResult
    func consume(_ key: KeyPress) -> Bool {
        guard isRecording else { return false }
        switch key.kind {
        case .modifiers:
            heldModifiers = key.modifiers
            return true
        case .down:
            if key.isRepeat { return true }
            if key.modifiers.isEmpty, key.keyCode == UInt16(kVK_Escape) || key.keyCode == UInt16(kVK_Delete) {
                finish()
                return true
            }
            let combo = HotkeyCombo(keyCode: key.keyCode, modifiers: key.modifiers)
            if !combo.isUsable {
                lastRejected = L("%@ не подойдёт — нужен ⌘, ⌃ или ⌥", combo.display)
                rejections &+= 1
            } else if let name = systemConflict(combo) {
                lastRejected = L("%@ занято macOS: «%@»", combo.display, name)
                rejections &+= 1
            } else {
                finish()
                onCapture(combo)
            }
            return true
        case .other:
            return false
        }
    }

    private func finish() {
        isRecording = false
        heldModifiers = []
        timeoutTask?.cancel()
        timeoutTask = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        GlobalHotkey.shared.suspended = false
        onKeyboardRequest(false)
    }

    nonisolated static func modifiers(_ flags: NSEvent.ModifierFlags) -> HotkeyModifiers {
        var result: HotkeyModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }
}

/// The Mac's own keyboard shortcuts ("symbolic hotkeys": System Settings → Keyboard → Keyboard Shortcuts), read live with
/// `CopySymbolicHotKeys` (no permission needed). A global hotkey on one of them would either never fire or break it.
enum SystemHotkeys {
    /// What macOS calls the enabled shortcut `combo` would take, or nil.
    static func conflict(_ combo: HotkeyCombo) -> String? {
        HotkeyClashes.system(combo, in: current())
    }

    static func current() -> [HotkeyClashes.SystemHotkey] {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let list = array?.takeRetainedValue() as? [[String: Any]] else {
            return []
        }
        return list.compactMap { entry in
            guard let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.intValue,
                  code >= 0, code <= Int(UInt16.max),
                  let mods = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { return nil }
            let enabled = (entry[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue ?? false
            return HotkeyClashes.SystemHotkey(keyCode: UInt16(code), carbonModifiers: mods, enabled: enabled)
        }
    }
}
