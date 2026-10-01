import XCTest
@testable import NotchBuddyCore

final class ShelfCatalogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ path: String, at offset: TimeInterval = 0, owned: Bool = false, origin: String? = nil) -> ShelfItem {
        ShelfItem(path: path, originPath: origin, byteSize: 100, addedAt: t0.addingTimeInterval(offset), ownedCopy: owned)
    }

    func testInsertPutsNewestFirstInGivenOrder() {
        var catalog = ShelfCatalog()
        catalog.insert([item("/a/one.txt")])
        catalog.insert([item("/a/two.txt", at: 1), item("/a/three.txt", at: 1)])
        XCTAssertEqual(catalog.items.map(\.name), ["two.txt", "three.txt", "one.txt"])
    }

    func testSameOriginMovesExistingToFrontAndHandsBackDuplicate() {
        var catalog = ShelfCatalog()
        let first = item("/a/one.txt")
        catalog.insert([first, item("/a/two.txt")])
        var again = item("/a/one.txt", at: 5)
        again.byteSize = 999
        let result = catalog.insert([again])
        XCTAssertEqual(catalog.items.map(\.name), ["one.txt", "two.txt"])
        XCTAssertEqual(catalog.items[0].id, first.id, "the existing item stays")
        XCTAssertEqual(catalog.items[0].byteSize, 999, "with the new size")
        XCTAssertEqual(catalog.items[0].addedAt, again.addedAt)
        XCTAssertEqual(result.placed.map(\.id), [first.id])
        XCTAssertEqual(result.discarded.map(\.id), [again.id])
    }

    func testDuplicatesWithinOneDropCollapse() {
        var catalog = ShelfCatalog()
        let result = catalog.insert([item("/a/x"), item("/a/x")])
        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(result.discarded.count, 1)
    }

    func testCopiesDedupeByOrigin() {
        var catalog = ShelfCatalog()
        let copy = item("/shelf/Files/1/shot.png", owned: true, origin: "/private/tmp/shot.png")
        catalog.insert([copy])
        let reference = item("/private/tmp/shot.png", at: 3)
        let result = catalog.insert([reference])
        XCTAssertEqual(catalog.items.map(\.id), [copy.id])
        XCTAssertTrue(catalog.items[0].ownedCopy)
        XCTAssertEqual(result.discarded.map(\.id), [reference.id])
    }

    func testSameIDIsTheSameItem() {
        var catalog = ShelfCatalog()
        let copy = item("/shelf/Files/1/shot.png", owned: true, origin: "/private/tmp/shot.png")
        catalog.insert([copy, item("/a/b")])
        var droppedBack = item("/shelf/Files/1/shot.png", at: 9, owned: true)
        droppedBack.id = copy.id
        let result = catalog.insert([droppedBack])
        XCTAssertEqual(catalog.count, 2)
        XCTAssertEqual(catalog.items[0].id, copy.id)
        XCTAssertTrue(result.discarded.isEmpty, "the only copy must not be disposed")
    }

    func testCapacityEvictsOldest() {
        var catalog = ShelfCatalog(capacity: 3)
        catalog.insert([item("/1"), item("/2"), item("/3")])
        let result = catalog.insert([item("/4"), item("/5")])
        XCTAssertEqual(catalog.items.map(\.name), ["4", "5", "1"])
        XCTAssertEqual(Set(result.discarded.map(\.name)), ["2", "3"])
        XCTAssertEqual(result.placed.map(\.name), ["4", "5"])
    }

    func testRemoveAndRemoveAll() {
        var catalog = ShelfCatalog()
        let a = item("/a"), b = item("/b")
        catalog.insert([a, b])
        XCTAssertEqual(catalog.remove(a.id)?.id, a.id)
        XCTAssertNil(catalog.remove(a.id))
        XCTAssertEqual(catalog.removeAll().map(\.id), [b.id])
        XCTAssertTrue(catalog.isEmpty)
    }

    func testMoveClamps() {
        var catalog = ShelfCatalog()
        let a = item("/a"), b = item("/b"), c = item("/c")
        catalog.insert([a, b, c])
        catalog.move(a.id, to: 99)
        XCTAssertEqual(catalog.items.map(\.name), ["b", "c", "a"])
        catalog.move(a.id, to: -3)
        XCTAssertEqual(catalog.items.map(\.name), ["a", "b", "c"])
    }

    func testNormalizeMergesPrivateTmp() {
        XCTAssertEqual(ShelfCatalog.normalize("/tmp/../tmp/x"), ShelfCatalog.normalize("/private/tmp/x"))
    }

    func testKinds() {
        XCTAssertEqual(ShelfKind.of(name: "shot.png", isDirectory: false), .image)
        XCTAssertEqual(ShelfKind.of(name: "clip.mov", isDirectory: false), .video)
        XCTAssertEqual(ShelfKind.of(name: "song.mp3", isDirectory: false), .audio)
        XCTAssertEqual(ShelfKind.of(name: "Spec.pdf", isDirectory: false), .pdf)
        XCTAssertEqual(ShelfKind.of(name: "logs.zip", isDirectory: false), .archive)
        XCTAssertEqual(ShelfKind.of(name: "main.swift", isDirectory: false), .code)
        XCTAssertEqual(ShelfKind.of(name: "notes.txt", isDirectory: false), .text)
        XCTAssertEqual(ShelfKind.of(name: "README.md", isDirectory: false), .text)
        XCTAssertEqual(ShelfKind.of(name: "Budget.numbers", isDirectory: true), .spreadsheet)
        XCTAssertEqual(ShelfKind.of(name: "Deck.key", isDirectory: false), .presentation)
        XCTAssertEqual(ShelfKind.of(name: "Letter.docx", isDirectory: false), .document)
        XCTAssertEqual(ShelfKind.of(name: "Safari.app", isDirectory: true), .app)
        XCTAssertEqual(ShelfKind.of(name: "Sources", isDirectory: true), .folder)
        XCTAssertEqual(ShelfKind.of(name: "v1.2", isDirectory: true), .folder)
        XCTAssertEqual(ShelfKind.of(name: "Makefile", isDirectory: false), .other)
    }

    func testSubtitlesAndTags() {
        let png = ShelfItem(path: "/x/shot.png", byteSize: 2_400_000, addedAt: t0)
        XCTAssertEqual(png.subtitle, "Изображение · 2,4 МБ")
        XCTAssertEqual(png.extensionTag, "PNG")
        let folder = ShelfItem(path: "/x/Sources", isDirectory: true, childCount: 12, addedAt: t0)
        XCTAssertEqual(folder.subtitle, "Папка · 12 объектов")
        XCTAssertNil(folder.extensionTag)
    }
}

final class ShelfFormatTests: XCTestCase {
    func testSizes() {
        XCTAssertEqual(ShelfFormat.size(0), "0 Б")
        XCTAssertEqual(ShelfFormat.size(845), "845 Б")
        XCTAssertEqual(ShelfFormat.size(1_000), "1 КБ")
        XCTAssertEqual(ShelfFormat.size(8_400), "8,4 КБ")
        XCTAssertEqual(ShelfFormat.size(120_400), "120 КБ")
        XCTAssertEqual(ShelfFormat.size(999_700), "1 МБ")
        XCTAssertEqual(ShelfFormat.size(1_240_000), "1,2 МБ")
        XCTAssertEqual(ShelfFormat.size(3_400_000_000), "3,4 ГБ")
    }

    func testPlurals() {
        XCTAssertEqual(ShelfFormat.files(1), "1 файл")
        XCTAssertEqual(ShelfFormat.files(3), "3 файла")
        XCTAssertEqual(ShelfFormat.files(11), "11 файлов")
        XCTAssertEqual(ShelfFormat.files(21), "21 файл")
        XCTAssertEqual(ShelfFormat.objects(14), "14 объектов")
    }

    func testSummary() {
        var catalog = ShelfCatalog()
        catalog.insert([ShelfItem(path: "/a", byteSize: 1_000_000, addedAt: Date()),
                        ShelfItem(path: "/b", byteSize: 2_500_000, addedAt: Date())])
        XCTAssertEqual(ShelfFormat.summary(catalog), "2 файла · 3,5 МБ")
    }
}

final class ShelfDiskTests: XCTestCase {
    private var root: URL!
    private var disk: ShelfDisk!
    private var outside: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-tests-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home", isDirectory: true)
        outside = home.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        disk = ShelfDisk(directory: home.appendingPathComponent("Library/Application Support/NotchBuddy/Shelf"),
                         disposal: .delete, home: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String, bytes: Int = 10, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? outside).appendingPathComponent(name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    func testReferencesAreNotCopied() throws {
        let doc = try file("report.pdf", bytes: 1234)
        // (The test folder itself is temporary, so `.temporaryOnly` would copy here.)
        let items = disk.makeItems(for: [doc], policy: .never)
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].ownedCopy)
        XCTAssertEqual(items[0].path, ShelfCatalog.normalize(doc.path))
        XCTAssertEqual(items[0].byteSize, 1234)
        XCTAssertEqual(items[0].kind, .pdf)
        XCTAssertNotNil(items[0].bookmark)
    }

    func testAlwaysCopiesAndDisposeRemovesOnlyTheCopy() throws {
        let doc = try file("notes.txt")
        let item = try XCTUnwrap(disk.makeItems(for: [doc], policy: .always).first)
        XCTAssertTrue(item.ownedCopy)
        XCTAssertTrue(item.path.hasPrefix(ShelfCatalog.normalize(disk.filesDirectory.path)))
        XCTAssertEqual(item.originPath, ShelfCatalog.normalize(doc.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
        disk.dispose(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: doc.path), "the original is never touched")
    }

    func testDisposeNeverTouchesReferences() throws {
        let doc = try file("keep.txt")
        let item = try XCTUnwrap(disk.makeItems(for: [doc], policy: .never).first)
        disk.dispose(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: doc.path))
        // Even a forged "owned" item outside the shelf's storage is left alone.
        var forged = item
        forged.ownedCopy = true
        disk.dispose(forged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: doc.path))
    }

    func testTemporaryPlaces() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let disk = ShelfDisk(directory: home.appendingPathComponent("Shelf"), disposal: .delete, home: home)
        XCTAssertTrue(disk.isTemporary(URL(fileURLWithPath: "/tmp/a.png")))
        XCTAssertTrue(disk.isTemporary(URL(fileURLWithPath: "/private/var/folders/xy/abc/T/TemporaryItems/shot.png")))
        XCTAssertTrue(disk.isTemporary(home.appendingPathComponent("Library/Caches/com.app/x.bin")))
        XCTAssertTrue(disk.isTemporary(home.appendingPathComponent(".Trash/old.txt")))
        XCTAssertTrue(disk.isTemporary(home.appendingPathComponent("Library/Containers/com.x/Data/tmp/y.jpg")))
        XCTAssertFalse(disk.isTemporary(home.appendingPathComponent("Documents/report.pdf")))
        XCTAssertFalse(disk.isTemporary(home.appendingPathComponent("Library/Containers/com.x/Data/Documents/y")))
    }

    func testTemporaryOnlyCopiesTempFiles() throws {
        // The test root itself is under the system temporary folder.
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let temp = try file("shot.png", in: scratch)
        let custom = ShelfDisk(directory: disk.directory, disposal: .delete, home: URL(fileURLWithPath: "/nonexistent-home"))
        let item = try XCTUnwrap(custom.makeItems(for: [temp], policy: .temporaryOnly).first)
        XCTAssertTrue(item.ownedCopy)
        XCTAssertNil(item.bookmark)
        // Already on the shelf: not copied a second time.
        let again = custom.makeItems(for: [temp], policy: .temporaryOnly, existingOrigins: [item.originPath])
        XCTAssertEqual(again.count, 1)
        XCTAssertFalse(again[0].ownedCopy)
    }

    func testOwnCopyDroppedBackKeepsItsID() throws {
        let doc = try file("a.txt")
        let copy = try XCTUnwrap(disk.makeItems(for: [doc], policy: .always).first)
        let back = try XCTUnwrap(disk.makeItems(for: [URL(fileURLWithPath: copy.path)], policy: .always).first)
        XCTAssertEqual(back.id, copy.id)
        XCTAssertTrue(back.ownedCopy)
        XCTAssertEqual(back.path, copy.path)
        var catalog = ShelfCatalog()
        catalog.insert([copy])
        let result = catalog.insert([back])
        XCTAssertEqual(catalog.count, 1)
        XCTAssertTrue(result.discarded.isEmpty)
    }

    func testMissingFilesAreSkipped() {
        XCTAssertTrue(disk.makeItems(for: [outside.appendingPathComponent("nope.txt")], policy: .never).isEmpty)
    }

    func testFolders() throws {
        let folder = outside.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try file("1.png", in: folder)
        _ = try file("2.png", in: folder)
        _ = try file(".DS_Store", in: folder)
        let item = try XCTUnwrap(disk.makeItems(for: [folder], policy: .never).first)
        XCTAssertTrue(item.isDirectory)
        XCTAssertEqual(item.kind, .folder)
        XCTAssertEqual(item.childCount, 2)
        XCTAssertNil(item.byteSize)
    }

    func testSaveLoadRoundTrip() throws {
        var catalog = ShelfCatalog()
        catalog.insert(disk.makeItems(for: [try file("a.txt"), try file("b.txt")], policy: .never))
        try disk.save(catalog)
        let loaded = disk.load()
        XCTAssertEqual(loaded.items, catalog.items)
    }

    func testCorruptCatalogIsSetAside() throws {
        try FileManager.default.createDirectory(at: disk.directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: disk.catalogURL)
        XCTAssertTrue(disk.load().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.catalogURL.appendingPathExtension("bad").path))
    }

    func testResolveFollowsMovedFileAndDropsDeleted() throws {
        let doc = try file("draft.txt", bytes: 5)
        let item = try XCTUnwrap(disk.makeItems(for: [doc], policy: .never).first)
        let moved = outside.appendingPathComponent("final.txt")
        try FileManager.default.moveItem(at: doc, to: moved)
        let resolved = try XCTUnwrap(disk.resolve(item))
        XCTAssertEqual(resolved.id, item.id)
        XCTAssertEqual(resolved.name, "final.txt")
        XCTAssertEqual(ShelfCatalog.normalize(resolved.path), ShelfCatalog.normalize(moved.path))
        try FileManager.default.removeItem(at: moved)
        XCTAssertNil(disk.resolve(resolved))
    }

    func testPromisedFilesAreAdopted() throws {
        let promised = try file("IMG_0001.HEIC", bytes: 42)
        let item = try XCTUnwrap(disk.adoptPromisedFile(at: promised, suggestedName: "Фото.heic"))
        XCTAssertTrue(item.ownedCopy)
        XCTAssertEqual(item.name, "Фото.heic")
        XCTAssertEqual(item.byteSize, 42)
    }

    func testSafeNames() {
        XCTAssertEqual(ShelfDisk.safeName("../../etc/passwd"), "..∕..∕etc∕passwd")
        XCTAssertEqual(ShelfDisk.safeName(".."), "Файл")
        XCTAssertEqual(ShelfDisk.safeName("  "), "Файл")
    }

    func testSweepOrphans() throws {
        let doc = try file("a.txt")
        let kept = try XCTUnwrap(disk.makeItems(for: [doc], policy: .always).first)
        let orphan = try XCTUnwrap(disk.makeItems(for: [try file("b.txt")], policy: .always).first)
        var catalog = ShelfCatalog()
        catalog.insert([kept])
        disk.sweepOrphans(keeping: catalog)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }
}

final class DragHoverMachineTests: XCTestCase {
    func testPlainDragsAreIgnored() {
        var m = DragHoverMachine(changeCount: 5)
        XCTAssertEqual(m.mouseDown(changeCount: 5, onIsland: false), [])
        // A window move: the drag pasteboard does not change.
        XCTAssertEqual(m.mouseDragged(changeCount: 5, carriesFiles: { XCTFail("not consulted"); return true }, inside: true), [])
        XCTAssertEqual(m.mouseUp(inside: true), [])
        XCTAssertEqual(m.phase, .idle)
    }

    func testFileDragEntersExitsAndDrops() {
        var m = DragHoverMachine(changeCount: 5)
        _ = m.mouseDown(changeCount: 5, onIsland: false)
        XCTAssertEqual(m.mouseDragged(changeCount: 6, carriesFiles: { true }, inside: false), [.began])
        XCTAssertTrue(m.isDragging)
        XCTAssertEqual(m.mouseDragged(changeCount: 6, carriesFiles: { true }, inside: false), [])
        XCTAssertEqual(m.mouseDragged(changeCount: 6, carriesFiles: { true }, inside: true), [.entered])
        XCTAssertTrue(m.isInside)
        XCTAssertEqual(m.mouseDragged(changeCount: 6, carriesFiles: { true }, inside: false), [.exited])
        XCTAssertEqual(m.pointerChecked(inside: true), [.entered])
        XCTAssertEqual(m.mouseUp(inside: true), [.ended(overIsland: true)])
        XCTAssertFalse(m.isDragging)
    }

    func testDragStartingInsideReportsBothEvents() {
        var m = DragHoverMachine(changeCount: 1)
        _ = m.mouseDown(changeCount: 1, onIsland: false)
        XCTAssertEqual(m.mouseDragged(changeCount: 2, carriesFiles: { true }, inside: true), [.began, .entered])
    }

    func testCancelledOutside() {
        var m = DragHoverMachine(changeCount: 1)
        _ = m.mouseDown(changeCount: 1, onIsland: false)
        _ = m.mouseDragged(changeCount: 2, carriesFiles: { true }, inside: true)
        XCTAssertEqual(m.mouseUp(inside: false), [.exited, .ended(overIsland: false)])
    }

    func testTextDragsAndOwnDragsAreIgnored() {
        var m = DragHoverMachine(changeCount: 1)
        _ = m.mouseDown(changeCount: 1, onIsland: false)
        XCTAssertEqual(m.mouseDragged(changeCount: 2, carriesFiles: { false }, inside: true), [])
        XCTAssertEqual(m.phase, .ignoring)
        XCTAssertEqual(m.mouseDragged(changeCount: 2, carriesFiles: { true }, inside: true), [])
        _ = m.mouseUp(inside: true)
        // Dragging a file out of the shelf: the button went down on the island.
        _ = m.mouseDown(changeCount: 2, onIsland: true)
        XCTAssertEqual(m.mouseDragged(changeCount: 3, carriesFiles: { true }, inside: false), [])
        XCTAssertEqual(m.mouseUp(inside: false), [])
    }

    func testMissedMouseDownUsesLastBaseline() {
        var m = DragHoverMachine(changeCount: 9)
        // Stale content from an earlier drag is not a new drag.
        XCTAssertEqual(m.mouseDragged(changeCount: 9, carriesFiles: { true }, inside: true), [])
        XCTAssertEqual(m.mouseDragged(changeCount: 10, carriesFiles: { true }, inside: true), [.began, .entered])
    }

    func testResetEndsOutside() {
        var m = DragHoverMachine(changeCount: 1)
        _ = m.mouseDown(changeCount: 1, onIsland: false)
        _ = m.mouseDragged(changeCount: 2, carriesFiles: { true }, inside: true)
        XCTAssertEqual(m.reset(changeCount: 2), [.exited, .ended(overIsland: false)])
        XCTAssertEqual(m.baseline, 2)
    }

    func testProximity() {
        XCTAssertEqual(DragProximity.value(distance: 0), 1)
        XCTAssertEqual(DragProximity.value(distance: 500), 0)
        let near = DragProximity.value(distance: 30), far = DragProximity.value(distance: 150)
        XCTAssertGreaterThan(near, far)
        XCTAssertGreaterThan(far, 0)
        XCTAssertEqual(DragProximity.distance(x: 5, y: 5, minX: 0, minY: 0, maxX: 10, maxY: 10), 0)
        XCTAssertEqual(DragProximity.distance(x: 13, y: 14, minX: 0, minY: 0, maxX: 10, maxY: 10), 5)
    }
}
