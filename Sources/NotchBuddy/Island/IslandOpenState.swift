import Foundation

/// Why the island is open as far as the user goes (the pointer, a click, the keyboard; permission cards and notices are
/// the model's), and when a pointer that has left closes it. Pure logic: `IslandController` feeds it what happens and
/// the time (monotonic seconds), the tests drive it the same way.
///
/// The rules:
/// - a click only opens; only 📌 keeps the island open after the pointer leaves (and Settings → «Закреплять открытый
///   список», an explicit opt-in that pins whatever opens it);
/// - an open, unpinned island the pointer has been off for `leaveDelay` closes — the settings page and every widget
///   tab too — whether an event reported the leave or only the poll saw it (events get lost: a fast exit, another
///   display, sleep, a Space switch, another app's window above the panel, a menu);
/// - something that holds the island (a permission card, a drag, an open menu) postpones that: the leave counts from
///   the moment it lets go;
/// - opened from afar (the hotkey, «Настройки…» in the menu bar) the pointer is elsewhere: it closes once the pointer
///   has come and gone, on a click anywhere else, on the hotkey again, when another app comes to the front (⌘Tab), or
///   `remoteVisitWindow` after it opened if the pointer never came.
struct IslandOpenState: Equatable {
    enum Opener: Equatable {
        /// The pointer rested on the closed island (or came straight back after it closed).
        case hover
        /// A click on the closed island or on a tab.
        case click
        /// The hotkey or the menu bar: the pointer is somewhere else.
        case remote
        /// A file dropped on the shelf.
        case drop
    }

    /// Nil: closed.
    private(set) var opener: Opener?
    private(set) var pinned = false
    /// The pointer has been on the island since it opened (an island opened from afar waits for it).
    private(set) var visited = false
    /// Since when the pointer has been off the open island (nil: on it, or closed).
    private(set) var outsideSince: TimeInterval?
    /// When it opened (monotonic seconds; nil: closed).
    private(set) var openedAt: TimeInterval?

    /// How long the pointer stays off an open island before it closes.
    static let leaveDelay: TimeInterval = IslandMotion.closeDelay
    /// How long an island opened from afar waits for the pointer to come before it closes on its own.
    static let remoteVisitWindow: TimeInterval = 4

    var isOpen: Bool { opener != nil }

    /// Worth polling the pointer for: open and free to close.
    var watchesLeave: Bool { isOpen && !pinned }

    /// Opens (or keeps open, taking the new reason). `pin`: Settings → «Закреплять открытый список».
    mutating func open(_ by: Opener, pointerInside: Bool, pin: Bool = false, now: TimeInterval) {
        let wasOpen = isOpen
        if !wasOpen || by != opener { openedAt = now }
        opener = by
        if pin { pinned = true }
        visited = (wasOpen && visited) || pointerInside
        outsideSince = pointerInside ? nil : (wasOpen ? outsideSince ?? now : now)
    }

    /// 📌 on.
    mutating func pin() {
        guard isOpen else { return }
        pinned = true
    }

    /// 📌 off. Returns true when that closes the island at once (the pointer is already off it).
    @discardableResult
    mutating func unpin(pointerInside: Bool, now: TimeInterval) -> Bool {
        guard pinned else { return false }
        pinned = false
        if pointerInside {
            visited = true
            outsideSince = nil
            return false
        }
        close()
        return true
    }

    /// A look at the pointer (an event or a poll tick). `held`: something keeps the island open for now.
    mutating func pointer(inside: Bool, held: Bool = false, now: TimeInterval) {
        guard isOpen else {
            outsideSince = nil
            return
        }
        if inside {
            visited = true
            outsideSince = nil
        } else if held || outsideSince == nil {
            // Held, the leave starts counting only once it lets go.
            outsideSince = now
        }
    }

    /// Whether the island should close now: open, not pinned, not held, the pointer has been on it and off it for
    /// `delay`.
    func shouldClose(now: TimeInterval, held: Bool = false, delay: TimeInterval = leaveDelay) -> Bool {
        guard isOpen, !pinned, !held else { return false }
        if unvisitedRemoteExpired(now: now) { return true }
        guard visited, let since = outsideSince else { return false }
        return now - since >= delay - 0.001
    }

    /// Opened from afar and the pointer never came within `remoteVisitWindow`.
    func unvisitedRemoteExpired(now: TimeInterval) -> Bool {
        guard opener == .remote, !visited, let openedAt else { return false }
        return now - openedAt >= Self.remoteVisitWindow - 0.001
    }

    /// Another app came to the front (⌘Tab, a click in its window, Mission Control). Returns true when that closes the
    /// island: one opened from afar that the pointer never visited (one the pointer is on stays; any other one closes on
    /// its own as the pointer is off it).
    mutating func frontmostAppChanged() -> Bool {
        clickedElsewhere()
    }

    /// A click somewhere else (another app, the desktop). Returns true when that closes the island: one opened from
    /// afar that the pointer never visited (any other one closes on its own as the pointer is off it).
    mutating func clickedElsewhere() -> Bool {
        guard isOpen, !pinned, opener == .remote, !visited else { return false }
        close()
        return true
    }

    mutating func close() {
        self = IslandOpenState()
    }
}
