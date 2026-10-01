import AppKit
import NotchBuddyCore
import SwiftUI
import XCTest
@testable import NotchBuddy

/// Dragging a file back out of the shelf: a press anywhere on a tile reaches its AppKit drag source (on the stage too),
/// the drag carries the files, starts where the tile draws them, may be copied or moved by the receiver, and the island
/// takes the drag only while it is over the island.
@MainActor
final class ShelfDragOutTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("nb-dragout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Hits

    /// The picture, the name and the size line pass the press to the drag source under them. (They used to take it
    /// themselves: SwiftUI kept the press, and a tile could be dragged only by the strip between picture and name.)
    func testPressAnywhereOnATileReachesItsDragSource() throws {
        let shelf = ShelfPreviewRenderer.sampleShelf(in: folder)
        let host = Host(ShelfWidgetView(store: shelf.store, width: 492))
        defer { host.close() }
        let sources = host.sources
        XCTAssertGreaterThanOrEqual(sources.count, 4, "the sample shelf shows its tiles")
        var checked = 0
        for source in sources {
            let rect = source.convert(source.bounds, to: nil)
            // Tiles scrolled past the well's edge are clipped away.
            guard rect.maxX < host.size.width - 40 else { continue }
            for point in Self.grid(in: rect) {
                let hit = host.hit(point)
                XCTAssertTrue(hit === source, "\(point) on a tile hit \(hit.map { "\(type(of: $0))" } ?? "nothing")")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 100)
    }

    /// A hovered tile's buttons (× in the corner, open, show in Finder) keep their own clicks; the rest of it still drags.
    func testHoveredTileButtonsKeepTheirClicks() throws {
        let shelf = ShelfPreviewRenderer.sampleShelf(in: folder)
        let host = Host(ShelfWidgetView(store: shelf.store, width: 492).environment(\.shelfPreviewHover, 0))
        defer { host.close() }
        let source = try XCTUnwrap(host.sources.min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX })
        let rect = source.convert(source.bounds, to: nil)
        let scale = rect.width / ShelfTileView.size.width
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * scale, y: rect.maxY - y * scale) }
        // The × sits on the top-left corner; the two round actions under the name.
        let rowY = ShelfTileView.thumbTop + ShelfTileView.thumbBox.height + 5 + 28 + 9
        for (name, p) in [("remove", point(4.5, 4.5)), ("open", point(27.5, rowY)), ("reveal", point(62.5, rowY))] {
            XCTAssertFalse(host.hit(p) === source, "\(name) went to the drag source")
        }
        XCTAssertTrue(host.hit(point(45, ShelfTileView.thumbTop + 29)) === source, "the picture of a hovered tile still drags")
        XCTAssertTrue(host.hit(point(45, 80)) === source, "the name of a hovered tile still drags")
    }

    /// On the island's stage (the shelf tab as a live page) the tiles take the press the same way.
    func testTilesOnTheStageReachTheirDragSources() throws {
        let saved = WidgetHub.shared
        defer { WidgetHub.shared = saved }
        let shelf = ShelfPreviewRenderer.sampleShelf(in: folder)
        WidgetHub.shared = .preview(tabs: [.agents, .shelf], shelf: shelf)
        IslandWidgetPages.register()
        let fakes = StageFakes(now: Date())
        let state = IslandViewState()
        let stage = IslandStage(state: state)
        stage.timeline.filming = true
        var now: CFTimeInterval = 1000
        var jobs: [(at: CFTimeInterval, body: @MainActor () -> Void)] = []
        stage.clock = { now }
        stage.later = { seconds, body in jobs.append((now + max(0, seconds), body)) }
        state.jump(to: IslandPreviewRenderer.floating)
        let canvas = IslandLayout.canvasSize(state.metrics)
        let panel = IslandPanel()
        let container = IslandContainerView(host: stage.view)
        panel.contentView = container
        panel.setFrame(NSRect(x: -40_000, y: -40_000, width: canvas.width, height: canvas.height), display: false)
        defer { panel.orderOut(nil) }
        state.tabs = [.agents, .shelf]
        state.setContent(.tab(.shelf), snapshot: fakes.trio)
        let end = now + 1.5
        while now < end {
            now += 1.0 / 60
            while let i = jobs.indices.first(where: { jobs[$0].at <= now }) { jobs.remove(at: i).body() }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
            stage.apply(at: now)
        }
        // Fresh content takes clicks after `IslandMotion.interactiveDelay` (real time).
        let deadline = Date().addingTimeInterval(3)
        while !state.contentInteractive, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        container.layoutSubtreeIfNeeded()
        XCTAssertTrue(state.contentInteractive)
        let sources = Self.views(in: container).compactMap { $0 as? ShelfDragSourceView }
        XCTAssertGreaterThanOrEqual(sources.count, 4)
        let source = try XCTUnwrap(sources.min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX })
        let rect = source.convert(source.bounds, to: nil)
        for point in Self.grid(in: rect) {
            let hit = container.hitTest(container.superview.map { container.convert(point, to: $0) } ?? point)
            XCTAssertTrue(hit === source, "\(point) hit \(hit.map { "\(type(of: $0))" } ?? "nothing")")
        }
    }

    // MARK: What the drag carries

    func testDragCarriesTheFilesAsFileURLs() throws {
        let file = folder.appendingPathComponent("Отчёт.pdf")
        try Data("pdf".utf8).write(to: file)
        let sub = folder.appendingPathComponent("Папка", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let gone = ShelfItem(path: folder.appendingPathComponent("нет.txt").path, addedAt: Date())
        let items = [ShelfItem(path: file.path, addedAt: Date()), ShelfItem(path: sub.path, isDirectory: true, addedAt: Date()), gone]

        let present = ShelfDragOut.draggable(items)
        XCTAssertEqual(present.map(\.path), [file.path, sub.path], "a file gone since the last look is left out")

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("nb.dragout.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(ShelfDragOut.pasteboardWriters(for: present)))
        let urls = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
        XCTAssertEqual(urls.map(\.standardizedFileURL.path), [file.path, sub.path].map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        XCTAssertTrue(urls[1].hasDirectoryPath, "a folder goes as a folder")
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2, "one item per file")
        XCTAssertTrue(pasteboard.pasteboardItems?.allSatisfy { $0.types.contains(.fileURL) } ?? false)
    }

    /// Outside NotchBuddy the receiver may copy or move (as from a Finder window: Finder moves on the same volume,
    /// ⌥ copies); back over the island only copy, and the shelf refuses its own tile.
    func testOperations() {
        let outside = ShelfDragOut.operationMask(outsideApplication: true)
        XCTAssertTrue(outside.contains(.copy))
        XCTAssertTrue(outside.contains(.move))
        XCTAssertTrue(outside.contains(.generic), "receivers that only take a generic drop take it")
        XCTAssertFalse(outside.contains(.delete))
        XCTAssertEqual(ShelfDragOut.operationMask(outsideApplication: false), .copy)
        XCTAssertEqual(ShelfDragOut.describe([]), "cancelled")
        XCTAssertEqual(ShelfDragOut.describe(.move), "moved")
        XCTAssertEqual(ShelfDragOut.describe(.copy), "copied")
    }

    /// The drag image starts exactly where the tile draws its picture and lifts off from there.
    func testDragImageStartsWhereTheTileDrawsIt() {
        let icon = ShelfDragOut.imageFrame(imageSize: CGSize(width: 512, height: 512), isIcon: true)
        XCTAssertEqual(icon, CGRect(x: 18, y: 8, width: 54, height: 54))
        let wide = ShelfDragOut.imageFrame(imageSize: CGSize(width: 400, height: 200), isIcon: false)
        XCTAssertEqual(wide.width, 70, accuracy: 0.01)
        XCTAssertEqual(wide.height, 35, accuracy: 0.01)
        XCTAssertEqual(wide.midX, 45, accuracy: 0.01)
        XCTAssertEqual(wide.midY, ShelfTileView.thumbTop + ShelfTileView.thumbBox.height / 2, accuracy: 0.01)
        let tall = ShelfDragOut.imageFrame(imageSize: CGSize(width: 100, height: 200), isIcon: false)
        XCTAssertEqual(tall.height, 52, accuracy: 0.01)
        XCTAssertEqual(tall.width, 26, accuracy: 0.01)
        // A pressed tile is drawn a little smaller: the picture with it.
        let pressed = ShelfDragOut.imageFrame(imageSize: CGSize(width: 1, height: 1), isIcon: true,
                                              in: CGSize(width: 90 * 0.96, height: 118 * 0.96))
        XCTAssertEqual(pressed.width, 54 * 0.96, accuracy: 0.01)
        XCTAssertEqual(pressed.minX, 18 * 0.96, accuracy: 0.01)
        let picture = NSImage(size: NSSize(width: 400, height: 200))
        XCTAssertTrue(ShelfDragOut.dragImage(picture, size: wide.size, isIcon: true) === picture, "a Finder icon as is")
        XCTAssertEqual(ShelfDragOut.dragImage(picture, size: wide.size, isIcon: false).size, wide.size)
    }

    // MARK: The island during the drag

    /// The store holds the island while the tile is out and tells the controller about every step of the drag.
    func testStoreFollowsTheDragOut() {
        let store = ShelfStore(disk: ShelfDisk(directory: folder, disposal: .delete),
                               settings: ShelfSettings(defaults: UserDefaults(suiteName: "nb-dragout-test")!), persist: false)
        var steps = 0
        store.onDragOut = { steps += 1 }
        let id = UUID()
        store.dragOutMoved()
        XCTAssertEqual(steps, 0, "no drag, nothing to follow")
        store.dragOutBegan(id)
        XCTAssertEqual(store.draggingOut, id)
        store.dragOutMoved()
        store.dragOutMoved()
        XCTAssertEqual(steps, 3)
        store.dragOutEnded(UUID(), moved: false)
        XCTAssertEqual(store.draggingOut, id, "another tile's end does not let go")
        store.dragOutEnded(id, moved: false)
        XCTAssertNil(store.draggingOut)
        XCTAssertEqual(steps, 4, "the end re-checks the pointer too")
        store.dragOutMoved()
        XCTAssertEqual(steps, 4)
    }

    /// The panel takes the mouse only on the island: a tile dragged out goes through to the windows under the panel
    /// once it leaves the island, and is taken back (refused, slides home) over it; other drags keep their rules.
    func testPanelTakesTheDragOnlyOverTheIsland() {
        func takes(_ onIsland: Bool, buttons: Bool, ignoring: Bool, wantsDrop: Bool = false, dragOut: Bool = false) -> Bool {
            IslandMouseCapture.takesMouse(onIsland: onIsland, buttonsDown: buttons, ignoring: ignoring,
                                          fileDragWantsDrop: wantsDrop, shelfDragOut: dragOut)
        }
        // Off the island: never, whatever is dragged.
        for buttons in [false, true] {
            for ignoring in [false, true] {
                XCTAssertFalse(takes(false, buttons: buttons, ignoring: ignoring, dragOut: true))
                XCTAssertFalse(takes(false, buttons: buttons, ignoring: ignoring, wantsDrop: true))
            }
        }
        XCTAssertTrue(takes(true, buttons: false, ignoring: true), "a pointer on the island")
        XCTAssertTrue(takes(true, buttons: true, ignoring: false), "a press on the island (the start of a tile's drag)")
        XCTAssertFalse(takes(true, buttons: true, ignoring: true), "a drag from another app passing over")
        XCTAssertTrue(takes(true, buttons: true, ignoring: true, wantsDrop: true), "a file brought to the shelf")
        XCTAssertTrue(takes(true, buttons: true, ignoring: true, dragOut: true), "a tile dragged out and back")
    }

    /// A drag out that lasts holds the open island (the pointer is off it all along); it closes the usual moment after
    /// the drop.
    func testLongDragOutKeepsTheIslandUntilTheDrop() {
        var open = IslandOpenState()
        open.open(.hover, pointerInside: true, now: 0)
        var t = 0.1
        while t < 10 {
            open.pointer(inside: false, held: true, now: t)
            XCTAssertFalse(open.shouldClose(now: t, held: true), "closed under the drag at \(t) s")
            t += 0.1
        }
        open.pointer(inside: false, held: false, now: 10)
        XCTAssertFalse(open.shouldClose(now: 10 + IslandOpenState.leaveDelay / 2))
        XCTAssertTrue(open.shouldClose(now: 10 + IslandOpenState.leaveDelay + 0.01))
    }

    // MARK: Helpers

    /// Points across a tile's face, clear of its rounded corners.
    private static func grid(in rect: CGRect) -> [NSPoint] {
        var points: [NSPoint] = []
        let inner = rect.insetBy(dx: 7, dy: 7)
        for i in 0...6 {
            for j in 0...8 {
                points.append(NSPoint(x: inner.minX + inner.width * CGFloat(i) / 6, y: inner.minY + inner.height * CGFloat(j) / 8))
            }
        }
        return points
    }

    fileprivate static func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    /// The widget in a real island panel, off every screen.
    @MainActor
    private final class Host {
        let panel = IslandPanel()
        let container: IslandContainerView
        let size: CGSize

        init(_ content: some View) {
            size = CGSize(width: 532, height: ShelfWidgetView.height() + 30)
            let host = IslandHostingView(rootView: AnyView(
                content
                    .padding(.horizontal, 20)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .background(Color.black)))
            host.sizingOptions = []
            container = IslandContainerView(host: host)
            panel.contentView = container
            panel.setFrame(NSRect(x: -40_000, y: -40_000, width: size.width, height: size.height), display: false)
            let end = Date().addingTimeInterval(0.6)
            while Date() < end {
                container.layoutSubtreeIfNeeded()
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        }

        var sources: [ShelfDragSourceView] { ShelfDragOutTests.views(in: container).compactMap { $0 as? ShelfDragSourceView } }

        /// What takes a press at `point` (window coordinates).
        func hit(_ point: NSPoint) -> NSView? {
            container.hitTest(container.superview.map { container.convert(point, to: $0) } ?? point)
        }

        func close() { panel.orderOut(nil) }
    }
}
