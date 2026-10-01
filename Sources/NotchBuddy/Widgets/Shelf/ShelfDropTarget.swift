import SwiftUI
import UniformTypeIdentifiers

/// Makes a view a drop target for the shelf: files dropped on it land on the shelf, and while a drag
/// hovers, the store's `dropTargeted` / `dropLocation` / `incomingCount` drive the highlight.
///
/// The shelf widget carries it; it can also go on the whole open island
/// (`.shelfDropTarget(store)`), so a drop anywhere on it lands on the shelf.
struct ShelfDropTarget: ViewModifier {
    let store: ShelfStore
    var enabled = true

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: ShelfStore.dropTypes, delegate: ShelfDropDelegate(store: store))
        } else {
            content
        }
    }
}

extension View {
    func shelfDropTarget(_ store: ShelfStore, enabled: Bool = true) -> some View {
        modifier(ShelfDropTarget(store: store, enabled: enabled))
    }
}

struct ShelfDropDelegate: DropDelegate {
    let store: ShelfStore

    func validateDrop(info: DropInfo) -> Bool {
        // A tile dragged out and back over its own shelf is not a drop.
        store.draggingOut == nil && info.hasItemsConforming(to: ShelfStore.dropTypes)
    }

    func dropEntered(info: DropInfo) {
        guard store.draggingOut == nil else { return }
        let count = info.itemProviders(for: ShelfStore.dropTypes).count
        withAnimation(ShelfMotion.target.animation) {
            store.setDropTarget(true, location: info.location, incoming: count)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard store.draggingOut == nil else { return DropProposal(operation: .forbidden) }
        store.setDropTarget(true, location: info.location)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        withAnimation(ShelfMotion.target.animation) {
            store.setDropTarget(false, location: nil)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: ShelfStore.dropTypes)
        withAnimation(ShelfMotion.landing.animation) {
            store.setDropTarget(false, location: nil)
        }
        return store.acceptDrop(providers)
    }
}
