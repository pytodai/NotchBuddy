import Foundation

/// When the island's panel takes the mouse (`ignoresMouseEvents` off). Pure, so the tests can check every case; the
/// controller asks it on every pointer check.
///
/// The panel is a big transparent canvas over the top of the screen: it takes the mouse only while the pointer is on
/// the island itself, so everywhere else clicks, scrolls and drops reach the windows under it.
enum IslandMouseCapture {
    /// - Parameters:
    ///   - onIsland: the pointer is on the island (its silhouette plus `IslandMotion.enterSlop`).
    ///   - buttonsDown: a mouse button is down.
    ///   - ignoring: the panel ignores the mouse right now.
    ///   - fileDragWantsDrop: a file dragged from elsewhere is over the island and the shelf takes it.
    ///   - shelfDragOut: a tile is being dragged out of the shelf.
    static func takesMouse(onIsland: Bool, buttonsDown: Bool, ignoring: Bool, fileDragWantsDrop: Bool,
                           shelfDragOut: Bool) -> Bool {
        guard onIsland else { return false }
        // A tile dragged out and back over the island: the island takes the drag, so a drop there is refused and the
        // file slides back to its tile, instead of falling through to whatever window is hidden under the island.
        if shelfDragOut { return true }
        // A file dragged onto the island for the shelf: its drop lands on the shelf's page.
        if fileDragWantsDrop { return true }
        // Any other drag that started elsewhere is never caught (its drop belongs to the app it came from).
        return !(buttonsDown && ignoring)
    }
}
