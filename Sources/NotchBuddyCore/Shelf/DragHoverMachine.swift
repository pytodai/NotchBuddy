import Foundation

/// Tells, from plain mouse events, when a drag that carries files is under way and whether it is over the
/// island, while the island's panel ignores the mouse (so it gets no drag-destination callbacks of its own).
///
/// The drag pasteboard's `changeCount` moves when a drag with content starts; a drag that leaves it alone
/// (moving a window, selecting text) carries nothing. A drag that starts on the island itself is the
/// island's own (dragging a file out of the shelf, scrolling) and is ignored until the button goes up.
///
/// Pure state: `DragHoverDetector` (app) feeds it events and the pasteboard's facts.
public struct DragHoverMachine: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// No button down, or a drag that carries nothing (yet).
        case idle
        /// The button went down on the island, or the drag carries something the shelf cannot take:
        /// ignored until the button goes up.
        case ignoring
        /// A drag with files from elsewhere.
        case dragging(inside: Bool)
    }

    public enum Event: Equatable, Sendable {
        /// A drag with files started somewhere on screen.
        case began
        case entered
        case exited
        /// The button went up (over the island or not). `overIsland` means the drop was offered to the island.
        case ended(overIsland: Bool)
    }

    public private(set) var phase: Phase = .idle
    /// The drag pasteboard's change count when the button last went down (or when watching started).
    public private(set) var baseline: Int

    public init(changeCount: Int) {
        baseline = changeCount
    }

    public var isDragging: Bool {
        if case .dragging = phase { return true }
        return false
    }

    public var isInside: Bool { phase == .dragging(inside: true) }

    public mutating func mouseDown(changeCount: Int, onIsland: Bool) -> [Event] {
        let ended = finish(inside: false)
        baseline = changeCount
        phase = onIsland ? .ignoring : .idle
        return ended
    }

    /// `carriesFiles` is read only when a new drag is detected (the change count moved since the button went
    /// down); pass a closure so the pasteboard is consulted only then.
    public mutating func mouseDragged(changeCount: Int, carriesFiles: () -> Bool, inside: Bool) -> [Event] {
        switch phase {
        case .ignoring:
            return []
        case .idle:
            guard changeCount != baseline else { return [] }
            guard carriesFiles() else {
                phase = .ignoring
                return []
            }
            phase = .dragging(inside: inside)
            return inside ? [.began, .entered] : [.began]
        case .dragging(let was):
            guard was != inside else { return [] }
            phase = .dragging(inside: inside)
            return [inside ? .entered : .exited]
        }
    }

    /// The pointer moved or the island changed size without a drag event (a watchdog tick).
    public mutating func pointerChecked(inside: Bool) -> [Event] {
        guard case .dragging(let was) = phase, was != inside else { return [] }
        phase = .dragging(inside: inside)
        return [inside ? .entered : .exited]
    }

    public mutating func mouseUp(inside: Bool, changeCount: Int? = nil) -> [Event] {
        let events = finish(inside: inside)
        if let changeCount { baseline = changeCount }
        phase = .idle
        return events
    }

    /// Watching stops (the island went away): a drag in progress ends outside.
    public mutating func reset(changeCount: Int) -> [Event] {
        let events = finish(inside: false)
        baseline = changeCount
        phase = .idle
        return events
    }

    private mutating func finish(inside: Bool) -> [Event] {
        guard case .dragging(let was) = phase else { return [] }
        phase = .idle
        var events: [Event] = []
        if was, !inside { events.append(.exited) }
        if !was, inside { events.append(.entered) }
        events.append(.ended(overIsland: inside))
        return events
    }
}

/// How close a dragged file is to the island, 0 (far) … 1 (on it), for the "magnet" that grows the island
/// toward an approaching drag. Distances in points from the island's rectangle.
public enum DragProximity {
    public static let reach: Double = 180

    public static func value(distance: Double) -> Double {
        guard distance > 0 else { return 1 }
        guard distance < reach else { return 0 }
        let t = 1 - distance / reach
        // Ease in: barely anything far away, a firm pull near the island.
        return t * t * (3 - 2 * t)
    }

    /// Distance from a point to a rectangle (0 inside). Plain numbers so it does not need CoreGraphics types.
    public static func distance(x: Double, y: Double, minX: Double, minY: Double, maxX: Double, maxY: Double) -> Double {
        let dx = max(minX - x, 0, x - maxX)
        let dy = max(minY - y, 0, y - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
