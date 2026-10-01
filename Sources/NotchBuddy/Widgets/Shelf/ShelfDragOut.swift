import AppKit
import NotchBuddyCore

/// What a drag out of the shelf carries and how it looks (pure, so the tests can check it without a mouse).
///
/// The drag is a real system drag (`ShelfDragSourceView` starts an `NSDraggingSession`): every file goes on the drag
/// pasteboard as a file URL (`public.file-url`; AppKit also answers the old `NSFilenamesPboardType` from it), so Finder,
/// the desktop, Mail, Messages, editors and browsers take it like a file dragged from a Finder window.
enum ShelfDragOut {
    /// What the receiver may do with the files.
    ///
    /// Outside NotchBuddy: what a Finder window offers, and the receiver decides as it does for Finder — Finder moves
    /// on the same volume and copies across volumes (⌥ copies, ⌘ moves, ⌘⌥ makes an alias); Mail and editors copy. A
    /// moved file is followed by the shelf (a moved-out copy of its own leaves it).
    /// Inside NotchBuddy (back over the island) only copy: the shelf refuses its own tile, so the file slides back.
    static func operationMask(outsideApplication: Bool) -> NSDragOperation {
        outsideApplication ? [.copy, .move, .link, .generic] : .copy
    }

    /// For the log: what the receiver did.
    static func describe(_ operation: NSDragOperation) -> String {
        if operation.isEmpty { return "cancelled" }
        if operation.contains(.move) { return "moved" }
        if operation.contains(.copy) { return "copied" }
        if operation.contains(.link) { return "linked" }
        return "taken (\(operation.rawValue))"
    }

    /// The files that can still be dragged (a file that is gone since the last refresh is left out).
    static func draggable(_ items: [ShelfItem], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> [ShelfItem] {
        items.filter { exists($0.path) }
    }

    /// One pasteboard writer per file: its file URL (a folder's with the trailing slash).
    static func pasteboardWriters(for items: [ShelfItem]) -> [NSPasteboardWriting] {
        items.map { $0.url as NSURL }
    }

    /// Where the tile draws its picture, in the tile's coordinates (top-left origin): the drag image starts exactly
    /// there and lifts off the tile, as in Finder. Mirrors `ShelfThumbnailView`: a Finder icon is a square in the
    /// thumbnail box, a content thumbnail is fitted with air around its frame. `tile`: the tile's size right now (a
    /// pressed tile is drawn a little smaller).
    static func imageFrame(imageSize: CGSize, isIcon: Bool, in tile: CGSize = ShelfTileView.size) -> CGRect {
        let scale = tile.width > 0 ? tile.width / ShelfTileView.size.width : 1
        let frame = unscaledImageFrame(imageSize: imageSize, isIcon: isIcon)
        return CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
    }

    private static func unscaledImageFrame(imageSize: CGSize, isIcon: Bool) -> CGRect {
        let box = ShelfTileView.thumbBox
        let center = CGPoint(x: box.width / 2, y: ShelfTileView.thumbTop + box.height / 2)
        let size: CGSize
        if isIcon || imageSize.width <= 0 || imageSize.height <= 0 {
            let side = box.height - 4
            size = CGSize(width: side, height: side)
        } else {
            let aspect = imageSize.width / imageSize.height
            let maxW = box.width - 20, maxH = box.height - 6
            size = CGSize(width: min(maxW, maxH * aspect), height: min(maxH, maxW / max(aspect, 0.01)))
        }
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// The picture that follows the pointer: the Finder icon as is; a content thumbnail with the tile's rounded frame.
    static func dragImage(_ image: NSImage, size: CGSize, isIcon: Bool) -> NSImage {
        guard !isIcon else { return image }
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            path.addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.white.withAlphaComponent(0.16).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }
}
