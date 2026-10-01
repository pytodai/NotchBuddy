import AppKit
import NotchBuddyCore
import Observation

/// The shelf as one piece for the island: settings, store and the drag detector, wired together.
///
/// Usage (IslandController / AppDelegate):
/// ```
/// let shelf = ShelfWidget()                                  // once, app lifetime
/// shelf.start(islandRect: { [weak self] in self?.islandScreenRect })   // with the pointer tracker; stop() with it
/// shelf.onDrag = { [weak self] state in self?.update() }     // re-resolve the mode
///
/// // Mode: while `shelf.opensForDrag`, open the island on the shelf (like a hover-open; close again on
/// // `.ended` unless pinned). Content: `ShelfWidgetView(store: shelf.store, width: …, pointerInside: …)`,
/// // and `.shelfDropTarget(shelf.store)` on the whole open island if drops anywhere on it should count.
/// // Closed island: `ShelfBadge(store: shelf.store, proximity: shelf.drag.proximity)` when
/// // `shelf.showsBadge`, or `ShelfDropHint(proximity:over:count:)` while `shelf.drag.isDragging`.
///
/// // Keep the island open while `shelf.store.draggingOut != nil` (a tile is being dragged out: the pointer
/// // leaves the island at once, and closing it would pull the drag's source away), and re-check the pointer on
/// // `shelf.store.onDragOut` (every move of that drag).
///
/// // IslandController.checkPointer — let a file drag onto the island (normally a drag that started
/// // elsewhere is never caught), and take a tile dragged out and back over it:
/// let capture = IslandMouseCapture.takesMouse(onIsland: …, buttonsDown: …, ignoring: panel.ignoresMouseEvents,
///                                             fileDragWantsDrop: shelf.wantsDrop, shelfDragOut: shelf.store.draggingOut != nil)
/// // and after the island's geometry changes: shelf.detector.islandChanged()
/// ```
@MainActor
@Observable
final class ShelfWidget {
    let settings: ShelfSettings
    let store: ShelfStore
    @ObservationIgnored let detector = DragHoverDetector()
    /// The drag detector's latest state (observable, for the badge's magnet and the drop hint).
    private(set) var drag = DragHoverDetector.State()
    /// Called on every change of `drag` (after it is stored).
    @ObservationIgnored var onDrag: (DragHoverDetector.State) -> Void = { _ in }
    /// Called for the detector's events (`.began`, `.entered`, `.exited`, `.ended`).
    @ObservationIgnored var onDragEvent: (DragHoverMachine.Event) -> Void = { _ in }

    init(settings: ShelfSettings? = nil, store: ShelfStore? = nil) {
        let settings = settings ?? .shared
        self.settings = settings
        self.store = store ?? ShelfStore(settings: settings)
        detector.onChange = { [weak self] state in self?.dragChanged(state) }
        detector.onEvent = { [weak self] event in self?.dragEvent(event) }
        followEnabled()
    }

    /// Starts watching for file drags (only while the shelf is enabled; switching it on or off in the
    /// settings starts or stops the watching by itself).
    func start(islandRect: @escaping () -> NSRect?) {
        detector.hotZone = islandRect
        started = true
        applyEnabled()
    }

    func stop() {
        started = false
        detector.stop()
    }

    @ObservationIgnored private var started = false

    private func applyEnabled() {
        if started, settings.enabled, !detector.isRunning {
            detector.start()
        } else if (!started || !settings.enabled), detector.isRunning {
            detector.stop()
        }
    }

    private func followEnabled() {
        withObservationTracking { _ = settings.enabled } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.applyEnabled()
                    self?.followEnabled()
                }
            }
        }
    }

    /// The island's panel should take the mouse over the island for the current drag.
    var wantsDrop: Bool { settings.enabled && detector.wantsDrop }

    /// A file drag is over the island and the shelf should open under it.
    var opensForDrag: Bool { settings.enabled && settings.opensOnDrag && drag.isOverIsland }

    /// The closed island shows the shelf's badge.
    var showsBadge: Bool { settings.enabled && settings.showsBadge && !store.isEmpty }

    private func dragChanged(_ state: DragHoverDetector.State) {
        drag = state
        onDrag(state)
    }

    private func dragEvent(_ event: DragHoverMachine.Event) {
        switch event {
        case .entered:
            // Light the shelf before SwiftUI's own drop callbacks start (the island is still opening).
            store.setDropTarget(true, location: nil, incoming: detector.state.itemCount)
        case .exited, .ended:
            store.setDropTarget(false)
        case .began:
            break
        }
        onDragEvent(event)
    }
}
