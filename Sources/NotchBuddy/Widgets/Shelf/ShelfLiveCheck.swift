import AppKit
import NotchBuddyCore
import SwiftUI

/// Part of `--render-shelf`: the real widget in a real (click-through, off-screen) island panel, driven
/// through the store's live paths — files added by URL, a drop's item providers (a file URL and promised
/// image data), the drop target lighting up, a removal, clear all — checking the shelf's contents after
/// each step and capturing the window (`live-shelf.png`). Nothing appears on screen.
@MainActor
enum ShelfLiveCheck {
    static func run(files: [URL], scratch: URL) -> (image: CGImage?, problems: [String]) {
        let disk = ShelfDisk(directory: scratch.appendingPathComponent("LiveShelf"), disposal: .delete)
        let settings = ShelfSettings(defaults: UserDefaults(suiteName: "nb-shelf-preview")!)
        let store = ShelfStore(disk: disk, settings: settings, persist: false)
        let width = ShelfPreviewRenderer.width
        let size = CGSize(width: width + 40, height: ShelfWidgetView.height() + 30)
        let panel = IslandPanel()
        let host = IslandHostingView(rootView: AnyView(
            ShelfWidgetView(store: store, width: width)
                .padding(.horizontal, 20)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Color.black)))
        host.sizingOptions = []
        panel.contentView = IslandContainerView(host: host)
        panel.setFrame(NSRect(x: -40_000, y: -40_000, width: size.width, height: size.height), display: false)
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        var problems: [String] = []
        var frames: [CGImage] = []
        func expect(_ count: Int, _ step: String, timeout: TimeInterval = 4) {
            let end = Date().addingTimeInterval(timeout)
            while (store.count != count || store.importing > 0), Date() < end { spin(0.02) }
            if store.count != count { problems.append("\(step): \(store.count) files on the shelf, expected \(count)") }
            print("live-shelf: \(step): \(store.count) \(store.count == count ? "✓" : "✗")")
        }
        /// Off every screen the panel gets few display frames, so springs need longer to settle than on screen.
        func snap() {
            spin(Double(ProcessInfo.processInfo.environment["NOTCHBUDDY_SHELF_SNAP"] ?? "2") ?? 2)
            if let image = capture(host) { frames.append(image) } else { problems.append("capture failed") }
        }

        spin(0.3)
        snap()
        let first = Array(files.prefix(3))
        store.add(first)
        expect(3, "add 3 by URL")
        snap()
        store.add([first[0]])
        expect(3, "the same file again")

        var providers: [NSItemProvider] = []
        if files.count > 3, let provider = NSItemProvider(contentsOf: files[3]) { providers.append(provider) }
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .png, properties: [:])
        if let png {
            let promised = NSItemProvider(item: png as NSData, typeIdentifier: "public.png")
            promised.suggestedName = "Вставленная картинка"
            providers.append(promised)
        }
        if !ShelfStore.canAccept(providers) { problems.append("a file URL and PNG data are not accepted") }
        // A drag pasteboard without file URLs or promises: the item providers take over.
        let empty = NSPasteboard(name: NSPasteboard.Name("notchbuddy.shelf.live.\(UUID().uuidString)"))
        empty.clearContents()
        store.acceptDrop(providers, pasteboard: empty)
        expect(3 + providers.count, "drop via item providers: file URL + PNG data")
        if let pasted = store.items.first(where: { $0.name.hasPrefix("Вставленная картинка") }) {
            if !pasted.ownedCopy { problems.append("promised data was not copied in") }
            if pasted.name != "Вставленная картинка.png" { problems.append("promised file named \(pasted.name)") }
        } else {
            problems.append("promised PNG missing")
        }

        // A drag pasteboard with file URLs (Finder's kind of drop).
        if files.count > 5 {
            empty.clearContents()
            empty.writeObjects([files[4] as NSURL, files[5] as NSURL])
            if !store.acceptPasteboard(empty) { problems.append("file URLs on the drag pasteboard not accepted") }
            expect(5 + providers.count, "drop via the drag pasteboard: 2 file URLs")
        }
        empty.releaseGlobally()

        store.setDropTarget(true, location: CGPoint(x: 90, y: 110), incoming: 2)
        snap()
        store.setDropTarget(false)
        let before = store.count
        if let id = store.items.first?.id {
            withAnimation(ShelfMotion.removal.animation) { store.remove(id) }
        }
        expect(before - 1, "remove one")
        snap()
        store.clear()
        expect(0, "clear all")
        snap()

        let image = ShelfPreviewRenderer.column(frames)
        return (image, problems)
    }

    private static func spin(_ seconds: TimeInterval) {
        let end = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
        }
    }

    private static func capture(_ view: NSView) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }
}
