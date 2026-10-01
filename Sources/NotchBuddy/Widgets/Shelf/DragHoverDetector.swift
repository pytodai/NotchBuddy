import AppKit
import NotchBuddyCore

/// Notices a file being dragged toward the island while the island's panel ignores the mouse.
///
/// The panel takes the mouse only over the island and never for a drag that started in another app, so it
/// gets no drag-destination callbacks until it lets such a drag in. This watches plain mouse events instead
/// (global monitors need no permission) and the drag pasteboard (`DragHoverMachine`): when a drag that
/// carries files comes near, `state.proximity` rises (the island can lean toward it); over the island
/// (`hotZone` plus `catchMargin`), `wantsDrop` turns true — the island opens the shelf and lets the panel
/// take the mouse, so the drop lands on `ShelfDropTarget`.
///
/// Wiring (IslandController):
/// ```
/// detector.hotZone = { [weak self] in self?.islandScreenRect }   // the island's rect, screen coordinates
/// detector.onChange = { [weak self] state in … open the shelf while state.isOverIsland … }
/// detector.start()                                              // with the pointer tracker
/// // checkPointer: let capture = onIsland && (!(buttonsDown && panel.ignoresMouseEvents) || detector.wantsDrop)
/// ```
/// Instead of `start()`, events from the pointer tracker's own monitors can be fed to `handle(_:)`.
@MainActor
final class DragHoverDetector {
    struct State: Equatable {
        /// A drag with files is under way somewhere on screen.
        var isDragging = false
        /// … and it is over the island (plus `catchMargin`).
        var isOverIsland = false
        /// 0 (far, or no drag) … 1 (over the island): the "magnet".
        var proximity: Double = 0
        /// Files the drag carries (best effort; 0 when unknown).
        var itemCount = 0
    }

    private(set) var state = State()
    /// The island's rect in screen coordinates (AppKit, bottom-left origin); nil while there is no island.
    var hotZone: () -> NSRect? = { nil }
    /// Room around the island that still counts as "over" it (a drop there opens the shelf in time).
    var catchMargin: CGFloat = 26
    var onChange: (State) -> Void = { _ in }
    var onEvent: (DragHoverMachine.Event) -> Void = { _ in }

    /// The panel should take the mouse over the island for this drag (so the drop reaches the shelf).
    var wantsDrop: Bool { state.isDragging && state.isOverIsland }

    var isRunning: Bool { globalMonitor != nil }

    private var machine = DragHoverMachine(changeCount: NSPasteboard(name: .drag).changeCount)
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var watchdog: Timer?
    private var lastPasteboardCheck: TimeInterval = 0
    private static let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]

    func start() {
        guard globalMonitor == nil else { return }
        _ = machine.reset(changeCount: NSPasteboard(name: .drag).changeCount)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] event in
            let type = event.type
            Self.onMain { self?.handle(type: type) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mask) { [weak self] event in
            let type = event.type
            Self.onMain { self?.handle(type: type) }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        emit(machine.reset(changeCount: NSPasteboard(name: .drag).changeCount))
        stopWatchdog()
        publish(State())
    }

    /// Feeds one mouse event (for callers with their own monitors). Other event types are ignored.
    func handle(_ event: NSEvent) {
        handle(type: event.type)
    }

    /// The island changed size or place under a resting drag: re-check where the drag is.
    func islandChanged() {
        guard machine.isDragging else { return }
        emit(machine.pointerChecked(inside: isInside(NSEvent.mouseLocation)))
        publishCurrent()
    }

    // MARK: Events

    private func handle(type: NSEvent.EventType) {
        let location = NSEvent.mouseLocation
        switch type {
        case .leftMouseDown:
            let onIsland = hotZone().map { $0.contains(location) } ?? false
            emit(machine.mouseDown(changeCount: NSPasteboard(name: .drag).changeCount, onIsland: onIsland))
            publishCurrent()
        case .leftMouseDragged:
            if machine.phase == .idle {
                // Only a drag that has not been classified yet reads the pasteboard, at most ~30 times a second.
                let now = ProcessInfo.processInfo.systemUptime
                guard now - lastPasteboardCheck > 0.033 else { return }
                lastPasteboardCheck = now
                let pasteboard = NSPasteboard(name: .drag)
                var count = 0
                let events = machine.mouseDragged(changeCount: pasteboard.changeCount, carriesFiles: {
                    let (files, n) = Self.inspect(pasteboard)
                    count = n
                    return files
                }, inside: isInside(location))
                if machine.isDragging {
                    state.itemCount = count
                    startWatchdog()
                }
                emit(events)
            } else if machine.isDragging {
                emit(machine.mouseDragged(changeCount: machine.baseline, carriesFiles: { true }, inside: isInside(location)))
            }
            publishCurrent()
        case .leftMouseUp:
            emit(machine.mouseUp(inside: isInside(location), changeCount: NSPasteboard(name: .drag).changeCount))
            stopWatchdog()
            publishCurrent()
        default:
            break
        }
    }

    /// While a drag is under way: catches the button going up where no event reports it, and the island
    /// growing under a drag that rests.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            Self.onMain { self?.tick() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func tick() {
        guard machine.isDragging else {
            stopWatchdog()
            return
        }
        let location = NSEvent.mouseLocation
        if NSEvent.pressedMouseButtons & 1 == 0 {
            emit(machine.mouseUp(inside: isInside(location), changeCount: NSPasteboard(name: .drag).changeCount))
            stopWatchdog()
        } else {
            emit(machine.pointerChecked(inside: isInside(location)))
        }
        publishCurrent()
    }

    // MARK: State

    private func isInside(_ point: NSPoint) -> Bool {
        guard let zone = hotZone() else { return false }
        return zone.insetBy(dx: -catchMargin, dy: -catchMargin).contains(point)
    }

    private func publishCurrent() {
        var next = state
        next.isDragging = machine.isDragging
        next.isOverIsland = machine.isInside
        if machine.isDragging, let zone = hotZone() {
            let p = NSEvent.mouseLocation
            let d = DragProximity.distance(x: p.x, y: p.y, minX: zone.minX, minY: zone.minY, maxX: zone.maxX, maxY: zone.maxY)
            // Quantized: a pointer inching along does not re-render the island 120 times a second.
            next.proximity = next.isOverIsland ? 1 : (DragProximity.value(distance: d) * 50).rounded() / 50
        } else {
            next.proximity = 0
            next.itemCount = 0
        }
        publish(next)
    }

    private func publish(_ next: State) {
        guard next != state else { return }
        state = next
        onChange(next)
    }

    private func emit(_ events: [DragHoverMachine.Event]) {
        for event in events { onEvent(event) }
    }

    /// Whether the drag carries files the shelf takes, and how many items.
    private static func inspect(_ pasteboard: NSPasteboard) -> (Bool, Int) {
        let types = Set(pasteboard.types ?? [])
        let files = !types.isDisjoint(with: acceptedTypes)
        let count = files ? (pasteboard.pasteboardItems?.count ?? 0) : 0
        return (files, count)
    }

    private static let acceptedTypes: Set<NSPasteboard.PasteboardType> = Set(
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    ).union([
        .fileURL,
        NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"),
        NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"),
        NSPasteboard.PasteboardType("NSPromiseContentsPboardType"),
        .png, .tiff, .pdf,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
    ])

    private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }
}
