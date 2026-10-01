import AppKit
import CoreGraphics

/// Keyboard shortcuts for the permission card: ⌘Y allow, ⌘N deny, ⌘T answer in the terminal.
///
/// The island never takes the keyboard on its own: no timers, no guessing from typing pauses.
/// The non-activating panel becomes key (NotchBuddy stays inactive) only while the pointer is over a
/// visible card, and resigns the moment the pointer leaves, so the frontmost app gets its keys back.
/// A card that appears under a resting pointer waits until the pointer moves.
///
/// While the panel is key, only the three shortcuts (and ⌘C on selected card text) stay with it;
/// they are swallowed, and key repeats are ignored. Any other key was meant for the app the user
/// works in: the keyboard is handed back at once (until the pointer leaves the card and returns)
/// and the key is re-posted to the frontmost app when NotchBuddy is allowed to post events
/// (otherwise only that one key is lost). Escape just hands the keyboard back. Whether a shortcut
/// may answer the card (arming, which card) is decided by the receiver of `onShortcut`.
///
/// Once another app takes the keyboard (the panel resigns key without `giveKeyBack`: ⌘Tab, Spotlight, the
/// terminal activated by "В терминал") the card never takes it back on its own: it waits until the pointer
/// leaves the card and returns, whatever re-renders or queued cards come meanwhile.
@MainActor
final class IslandKeyFocus {
    enum Shortcut: Equatable {
        case allow, deny, terminal
    }

    /// A shortcut was pressed while the pointer was over the card.
    var onShortcut: (Shortcut) -> Void = { _ in }
    /// The panel gained (true) or lost (false) the keyboard.
    var onKeyboardChange: (Bool) -> Void = { _ in }
    /// Whether the pointer is over the card right now, from screen geometry (hover events can lag).
    var pointerIsOverCard: () -> Bool = { false }

    private weak var panel: IslandPanel?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var cardVisible = false
    private var pointerInside = false
    /// Pointer location when the card appeared; the keyboard waits until the pointer leaves it.
    private var restingPointer: NSPoint?
    /// A key meant for another app arrived while hovering: stay released until the pointer leaves.
    private var releasedUntilExit = false
    /// Settings records a new hotkey: the panel takes the keyboard while the pointer is over the island, and every
    /// key goes to the recorder's own monitor.
    private var recording = false

    func install(on panel: IslandPanel) {
        self.panel = panel
        // Local monitors run on the main thread, inside NotchBuddy's own event dispatch.
        // Note: `self?.handle(event) ?? event` would turn a swallowed key (nil) back into the event.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWindow.didResignKeyNotification, let panel = self.panel, panel.allowsKey, self.cardVisible {
                        // Another app took the keyboard (⌘Tab, a click elsewhere, "В терминал" activating the
                        // terminal; `giveKeyBack` clears `allowsKey` first, so it is not this): stay released until
                        // the pointer leaves the card and comes back, even as the next card of a queue rises.
                        self.releasedUntilExit = true
                        panel.allowsKey = false
                    }
                    self.onKeyboardChange(self.panel?.isKeyWindow ?? false)
                }
            })
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        setCardVisible(false)
    }

    /// A permission card is on screen (true) or gone (false). Replacing one card with the next keeps
    /// the current state: the pointer is still where the user put it.
    func setCardVisible(_ visible: Bool) {
        if visible != cardVisible {
            cardVisible = visible
            releasedUntilExit = false
            restingPointer = visible ? NSEvent.mouseLocation : nil
        }
        apply()
    }

    /// Hover entered or left the island.
    func pointerChanged(inside: Bool) {
        pointerInside = inside
        // Re-ordering the panel (see `giveKeyBack`) can replay hover events; only a real exit counts.
        if !inside, !pointerIsOverCard() { releasedUntilExit = false }
        apply()
    }

    /// The keyboard goes back to the frontmost app and stays there until the pointer leaves the card and comes
    /// back (after "answer in the terminal": the terminal gets it even when it was already frontmost, so no
    /// resign of the panel says so).
    func releaseUntilExit() {
        releasedUntilExit = true
        giveKeyBack()
    }

    /// Settings started (true) or finished (false) recording a hotkey (`HotkeyRecorder.onKeyboardRequest`).
    func setRecording(_ on: Bool) {
        guard recording != on else { return }
        recording = on
        apply()
    }

    /// The pointer moved over the card.
    func pointerMoved() {
        guard cardVisible, pointerInside else { return }
        apply()
    }

    // MARK: Key status

    private func apply() {
        guard let panel else { return }
        if wantsKeyboard(panel) {
            panel.allowsKey = true
            if !panel.isKeyWindow { panel.makeKey() }
        } else {
            giveKeyBack()
        }
    }

    private func wantsKeyboard(_ panel: IslandPanel) -> Bool {
        if recording { return pointerInside && panel.isVisible && pointerIsOverCard() }
        guard cardVisible, pointerInside, !releasedUntilExit, panel.isVisible, pointerIsOverCard() else { return false }
        if let resting = restingPointer {
            let now = NSEvent.mouseLocation
            guard abs(now.x - resting.x) > 1 || abs(now.y - resting.y) > 1 else { return false }
            restingPointer = nil
        }
        return true
    }

    /// Resigns key status so the keyboard returns to the active app (NotchBuddy is never active).
    private func giveKeyBack() {
        guard let panel else { return }
        panel.allowsKey = false
        guard panel.isKeyWindow else { return }
        // A non-activating panel cannot hand key focus back directly; re-ordering it makes the window
        // server return it to the active app's key window.
        let visible = panel.isVisible
        panel.orderOut(nil)
        if visible { panel.orderFrontRegardless() }
    }

    // MARK: Keys

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let panel, event.window === panel else { return event }
        // The hotkey recorder's monitor takes these.
        if recording { return event }
        let overCard = panel.isKeyWindow && cardVisible && pointerIsOverCard()
        if overCard, let shortcut = Self.shortcut(for: event) {
            if !event.isARepeat { onShortcut(shortcut) }
            return nil
        }
        if overCard, Self.isCopy(event), let text = panel.firstResponder as? NSTextView, text.selectedRange().length > 0 {
            text.copy(nil)
            return nil
        }
        releasedUntilExit = pointerIsOverCard()
        giveKeyBack()
        // Escape only drops the card's hold on the keyboard: passing it on could interrupt the agent
        // in its terminal when the user meant to dismiss the card.
        if event.keyCode != 53 {  // kVK_Escape
            // Meant for the app the user is working in.
            Self.forwardToFrontmostApp(event)
        }
        return nil
    }

    private static func shortcut(for event: NSEvent) -> Shortcut? {
        guard modifiers(of: event) == .command else { return nil }
        switch letter(of: event) {
        case "y": return .allow
        case "n": return .deny
        case "t": return .terminal
        default: return nil
        }
    }

    private static func isCopy(_ event: NSEvent) -> Bool {
        modifiers(of: event) == .command && letter(of: event) == "c"
    }

    private static func modifiers(of event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection([.command, .option, .control, .shift])
    }

    /// Latin letter of the key; on non-Latin layouts (e.g. Russian) falls back to the physical key.
    private static func letter(of event: NSEvent) -> Character? {
        if let c = event.charactersIgnoringModifiers?.lowercased().first, c.isASCII, c.isLetter { return c }
        switch event.keyCode {
        case 16: return "y"   // kVK_ANSI_Y
        case 45: return "n"   // kVK_ANSI_N
        case 17: return "t"   // kVK_ANSI_T
        case 8: return "c"    // kVK_ANSI_C
        default: return nil
        }
    }

    /// Re-posts a key that reached the panel to the app it was meant for. Needs the "post events"
    /// permission (Accessibility); checked without prompting, and skipped without it.
    private static func forwardToFrontmostApp(_ event: NSEvent) {
        guard CGPreflightPostEventAccess(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let copy = event.cgEvent?.copy() else { return }
        copy.postToPid(app.processIdentifier)
    }
}
