import AppKit
import NotchBuddyCore
import SwiftUI

/// The AppKit side of a tile: dragging the file out (an `NSDraggingSession`, so the shelf knows when the
/// drag ends and can say what the receiver may do with the file), double-click to open, and the right-click menu.
///
/// It sits under the tile's picture and name, which take no hits (`ShelfTileView`), so a press anywhere on the tile
/// but its buttons lands here. (When the picture and name took hits, SwiftUI kept every press on them for itself and
/// a tile could be dragged only by the thin strip between them.)
///
/// SwiftUI's `.onDrag` gives neither an end callback nor an operation mask: the island would close under an
/// outgoing drag (the pointer leaves it at once) and could end the session by removing its source. While
/// `ShelfStore.draggingOut` is set, the controller keeps the island open, and every move of the drag re-checks the
/// pointer (`ShelfStore.onDragOut`): off the island the panel lets the drag reach the windows under it; back on the
/// island it takes the drag, so a drop there is refused and the file slides back to its tile instead of falling
/// through to a window hidden under the island.
///
/// Operations: `ShelfDragOut.operationMask` — what a Finder window offers outside NotchBuddy, only copy inside.
struct ShelfDragSource: NSViewRepresentable {
    let item: ShelfItem
    let image: NSImage?
    var imageIsIcon = true
    let store: ShelfStore
    let actions: ShelfTileActions
    /// The tile's press feedback (down on press, up on release or once the drag starts).
    var onPress: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> ShelfDragSourceView {
        let view = ShelfDragSourceView()
        update(view)
        return view
    }

    func updateNSView(_ view: ShelfDragSourceView, context: Context) {
        update(view)
    }

    private func update(_ view: ShelfDragSourceView) {
        view.item = item
        view.image = image
        view.imageIsIcon = imageIsIcon
        view.store = store
        view.actions = actions
        view.onPress = onPress
    }
}

final class ShelfDragSourceView: NSView, NSDraggingSource {
    var item: ShelfItem?
    var image: NSImage?
    var imageIsIcon = true
    weak var store: ShelfStore?
    var actions = ShelfTileActions()
    var onPress: (Bool) -> Void = { _ in }

    private var downEvent: NSEvent?
    /// The files of the drag under way (ended or not).
    private var dragged: [UUID] = []
    /// How far the pointer must travel before a press becomes a drag.
    static let dragThreshold: CGFloat = 3

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            downEvent = nil
            onPress(false)
            actions.open()
            return
        }
        downEvent = event
        onPress(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, let item else { return }
        let start = down.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) >= Self.dragThreshold else { return }
        downEvent = nil
        onPress(false)
        beginDrag([item], event: down)
    }

    override func mouseUp(with event: NSEvent) {
        downEvent = nil
        onPress(false)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(L("Открыть"), actions.open))
        menu.addItem(ClosureMenuItem(L("Показать в Finder"), actions.reveal))
        menu.addItem(ClosureMenuItem(L("Скопировать путь"), actions.copyPath))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Убрать с полки"), actions.remove))
        return menu
    }

    /// Starts the system drag with these files, the picture lifting off the tile where it is drawn.
    private func beginDrag(_ items: [ShelfItem], event: NSEvent) {
        let files = ShelfDragOut.draggable(items)
        guard !files.isEmpty else {
            // Gone since the last look (deleted, on an ejected disk): say so and let the shelf catch up.
            NSSound.beep()
            store?.refresh(force: true)
            return
        }
        let writers = ShelfDragOut.pasteboardWriters(for: files)
        var draggingItems: [NSDraggingItem] = []
        for (index, (file, writer)) in zip(files, writers).enumerated() {
            let own = index == 0 ? image : nil
            let picture = own ?? NSWorkspace.shared.icon(forFile: file.path)
            let isIcon = own == nil || imageIsIcon
            var frame = ShelfDragOut.imageFrame(imageSize: picture.size, isIcon: isIcon, in: bounds.size)
            // A stack of several: each next one a little behind (AppKit badges the count).
            frame = frame.offsetBy(dx: CGFloat(index) * 3, dy: CGFloat(index) * 3)
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            draggingItem.setDraggingFrame(frame, contents: ShelfDragOut.dragImage(picture, size: frame.size, isIcon: isIcon))
            draggingItems.append(draggingItem)
        }
        dragged = files.map(\.id)
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = draggingItems.count > 1 ? .pile : .none
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        ShelfDragOut.operationMask(outsideApplication: context == .outsideApplication)
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        guard let first = dragged.first else { return }
        MainActor.assumeIsolated { store?.dragOutBegan(first) }
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        MainActor.assumeIsolated { store?.dragOutMoved() }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let first = dragged.first else { return }
        let count = dragged.count
        dragged = []
        Log.info("shelf: \(count) file(s) dragged out, \(ShelfDragOut.describe(operation))")
        MainActor.assumeIsolated { store?.dragOutEnded(first, moved: operation.contains(.move)) }
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
