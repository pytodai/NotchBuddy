import AppKit
import NotchBuddyCore
import Observation
import UniformTypeIdentifiers

/// The shelf's live state for the island: its files (newest first), the drop target, what just landed.
///
/// File work (copying temporary files in, reading sizes, following moved originals, saving `shelf.json`)
/// runs on a background queue; the catalog changes on the main actor. Referenced files are never modified;
/// the shelf's own copies go to the Trash when their item leaves (`ShelfDisk`).
@MainActor
@Observable
final class ShelfStore {
    /// Newest first.
    private(set) var items: [ShelfItem] = []
    /// Files being received (copied in, promised by the drag): tiles show a shimmer placeholder for them.
    private(set) var importing = 0
    /// Bumps each time files land (the badge's "gulp", the tiles' landing glow).
    private(set) var addToken = 0
    /// The items that landed with the last drop (they glow once).
    private(set) var lastAdded: Set<UUID> = []
    /// A drag with files hovers the shelf (its drop target lights up, a ghost tile makes room).
    private(set) var dropTargeted = false
    /// Where the drag is, in the drop target's coordinates (the glow follows it).
    private(set) var dropLocation: CGPoint?
    /// How many files the hovering drag carries (the ghost tile's "+3"); 0 when unknown.
    private(set) var incomingCount = 0
    /// A file is being dragged out of the shelf: keep the island open until the drag ends
    /// (`ShelfDragSource`; the pointer leaves the island at once). A drag-end callback that never comes cannot hold the
    /// island: once no mouse button has been down for `dragOutRelease`, the drag counts as over (`dragOutWatch`).
    private(set) var draggingOut: UUID?
    /// A drag out began, moved or ended (the controller re-checks the pointer: the panel lets the drag through to the
    /// windows under it off the island and takes it back on the island). The drag's own loop may run where no mouse
    /// event reaches the island's monitors, so this is how the island follows it.
    @ObservationIgnored var onDragOut: () -> Void = {}
    @ObservationIgnored private var dragOutWatch: Timer?
    @ObservationIgnored private var buttonsUpSince: TimeInterval?
    /// How long all mouse buttons stay up before a drag out with no end reported is let go.
    static let dragOutRelease: TimeInterval = 0.5

    let thumbnails = ShelfThumbnails()
    let settings: ShelfSettings

    @ObservationIgnored private var catalog: ShelfCatalog
    @ObservationIgnored private let disk: ShelfDisk
    @ObservationIgnored private let io = DispatchQueue(label: "notchbuddy.shelf.io", qos: .userInitiated)
    @ObservationIgnored private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.name = "notchbuddy.shelf.promises"
        return queue
    }()
    @ObservationIgnored private var lastRefresh: TimeInterval = 0
    @ObservationIgnored private var persists: Bool

    /// `persist: false` keeps everything in memory (previews).
    init(disk: ShelfDisk = .standard, settings: ShelfSettings? = nil, persist: Bool = true) {
        self.disk = disk
        self.settings = settings ?? .shared
        self.persists = persist
        catalog = persist ? disk.load() : ShelfCatalog()
        items = catalog.items
        if persist {
            refresh(force: true)
            let disk = disk, snapshot = catalog
            io.async {
                disk.sweepOrphans(keeping: snapshot)
                disk.sweepIncoming()
            }
        }
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    var totalBytes: Int64 { catalog.totalBytes }
    var summary: String { ShelfFormat.summary(catalog) }

    // MARK: Adding

    /// Files dropped or handed over (Finder URLs). Copies are made off the main thread.
    func add(_ urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }
        let disk = disk, policy = settings.copyPolicy, origins = catalog.origins
        importing += fileURLs.count
        io.async {
            let items = disk.makeItems(for: fileURLs, policy: policy, existingOrigins: origins)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.importing = max(0, self.importing - fileURLs.count)
                    self.insert(items)
                }
            }
        }
    }

    /// A drop: file URLs, and files the drag only promises (Photos, Mail attachments, screenshot thumbnails,
    /// images from a browser), which are copied in while the drag's temporary file still exists.
    /// Returns false when nothing in the drop is a file.
    @discardableResult
    func accept(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: NSURL.self) { [weak self] object, _ in
                    guard let url = (object as? NSURL) as URL? else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.add([url]) } }
                }
            } else if let type = Self.promisedType(of: provider) {
                accepted = true
                importing += 1
                let disk = disk
                let name = Self.suggestedName(for: provider, type: type)
                provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, _ in
                    // The file is deleted when this returns: copy it in now.
                    let item = url.flatMap { disk.adoptPromisedFile(at: $0, suggestedName: name) }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.importing = max(0, self.importing - 1)
                            if let item { self.insert([item]) }
                        }
                    }
                }
            }
        }
        return accepted
    }

    /// A drop, read the AppKit way first: file URLs, then file promises (Mail attachments, Photos, browser
    /// images: received into a staging folder and copied in); item providers only for what is left (plain
    /// image data). Returns false when nothing in the drop is a file.
    @discardableResult
    func acceptDrop(_ providers: [NSItemProvider], pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> Bool {
        acceptPasteboard(pasteboard) || accept(providers)
    }

    /// File URLs or file promises on a drag pasteboard. False when it holds neither.
    @discardableResult
    func acceptPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            add(urls)
            return true
        }
        guard let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
                as? [NSFilePromiseReceiver], !promises.isEmpty,
              let staging = try? disk.makeIncomingFolder() else { return false }
        let disk = disk
        for promise in promises {
            let expected = max(promise.fileNames.count, 1)
            importing += expected
            var left = expected
            promise.receivePromisedFiles(atDestination: staging, options: [:], operationQueue: promiseQueue) { [weak self] url, error in
                // On `promiseQueue`: the file is written; copy it in and drop the staged one.
                let item = error == nil ? disk.adoptPromisedFile(at: url) : nil
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if left > 0 {
                            left -= 1
                            self.importing = max(0, self.importing - 1)
                        }
                        if let item { self.insert([item]) }
                    }
                }
            }
            // A promise that writes fewer files than it named: its placeholders go after a while.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, left > 0 else { return }
                self.importing = max(0, self.importing - left)
                left = 0
            }
        }
        return true
    }

    /// Whether a drop offers anything the shelf takes.
    nonisolated static func canAccept(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || promisedType(of: $0) != nil }
    }

    /// Types a drop target registers for: file URLs, file promises, and plain image/video/PDF data.
    static let dropTypes: [UTType] = [.fileURL, .image, .movie, .pdf, .data]
        + NSFilePromiseReceiver.readableDraggedTypes.map { UTType(importedAs: $0) }

    // MARK: Removing

    func remove(_ id: UUID) {
        guard let item = catalog.remove(id) else { return }
        publish()
        thumbnails.forget(id)
        dispose([item])
    }

    func clear() {
        let gone = catalog.removeAll()
        guard !gone.isEmpty else { return }
        publish()
        dispose(gone)
        for item in gone { thumbnails.forget(item.id) }
    }

    func move(_ id: UUID, to position: Int) {
        catalog.move(id, to: position)
        publish()
    }

    // MARK: Actions

    func open(_ id: UUID) {
        guard let item = catalog.item(id) else { return }
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ ids: [UUID]) {
        let urls = ids.compactMap { catalog.item($0)?.url }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func revealAll() { reveal(items.map(\.id)) }

    func copyPath(_ id: UUID) {
        guard let item = catalog.item(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path, forType: .string)
    }

    /// A tile's file started leaving the shelf by drag.
    func dragOutBegan(_ id: UUID) {
        draggingOut = id
        buttonsUpSince = nil
        dragOutWatch?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDragOut() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        dragOutWatch = timer
        onDragOut()
    }

    /// The drag out moved (`NSDraggingSource.draggingSession(_:movedTo:)`).
    func dragOutMoved() {
        guard draggingOut != nil else { return }
        onDragOut()
    }

    /// A drag holds a mouse button down; all buttons up for `dragOutRelease` and no end reported: it is over.
    private func checkDragOut() {
        guard draggingOut != nil else { return stopDragOutWatch() }
        guard NSEvent.pressedMouseButtons == 0 else {
            buttonsUpSince = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard let since = buttonsUpSince else {
            buttonsUpSince = now
            return
        }
        guard now - since >= Self.dragOutRelease else { return }
        Log.info("shelf: drag out had no end callback; released after \(Int(Self.dragOutRelease * 1000)) ms with the buttons up")
        draggingOut = nil
        stopDragOutWatch()
        onDragOut()
    }

    private func stopDragOutWatch() {
        dragOutWatch?.invalidate()
        dragOutWatch = nil
        buttonsUpSince = nil
    }

    /// The drag out ended. A moved file is looked up again (a moved original is followed by its bookmark; a
    /// moved-out copy of the shelf's own leaves the shelf).
    func dragOutEnded(_ id: UUID, moved: Bool) {
        if draggingOut == id {
            draggingOut = nil
            stopDragOutWatch()
            onDragOut()
        }
        guard moved else { return }
        refresh(force: true)
        // Finder may finish the move only after the drop returns: look once more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh(force: true) }
    }

    // MARK: Drop target

    /// The drop target's hover (from `ShelfDropTarget`, or from `DragHoverDetector` while the island is closed).
    func setDropTarget(_ targeted: Bool, location: CGPoint? = nil, incoming: Int? = nil) {
        if dropTargeted != targeted { dropTargeted = targeted }
        if location != dropLocation { dropLocation = location }
        if let incoming, incoming != incomingCount { incomingCount = incoming }
        if !targeted, incomingCount != 0, incoming == nil { incomingCount = 0 }
    }

    // MARK: Refresh

    /// Follows moved originals and drops files that are gone (at most every few seconds unless forced).
    func refresh(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastRefresh > 4, persists else { return }
        lastRefresh = now
        let disk = disk, snapshot = catalog.items
        io.async {
            let resolved = snapshot.map { (id: $0.id, item: disk.resolve($0)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.applyRefresh(resolved) }
            }
        }
    }

    // MARK: Previews

    /// Puts items on the shelf directly (previews and filmstrips; nothing is copied or saved).
    func load(preview items: [ShelfItem], lastAdded: Set<UUID> = [], importing: Int = 0) {
        catalog = ShelfCatalog()
        catalog.insert(items)
        self.lastAdded = lastAdded
        self.importing = importing
        publish(save: false)
    }

    // MARK: Private

    private func insert(_ incoming: [ShelfItem]) {
        guard !incoming.isEmpty else { return }
        let result = catalog.insert(incoming)
        lastAdded = Set(result.placed.map(\.id))
        addToken &+= 1
        publish()
        dispose(result.discarded)
    }

    private func applyRefresh(_ resolved: [(id: UUID, item: ShelfItem?)]) {
        var changed = false
        for (id, fresh) in resolved {
            guard let current = catalog.item(id) else { continue }
            if let fresh {
                if fresh != current {
                    catalog.update(fresh)
                    changed = true
                }
            } else {
                catalog.remove(id)
                thumbnails.forget(id)
                changed = true
            }
        }
        if changed { publish() }
    }

    private func publish(save: Bool = true) {
        if items != catalog.items { items = catalog.items }
        guard save, persists else { return }
        let disk = disk, snapshot = catalog
        io.async { try? disk.save(snapshot) }
    }

    private func dispose(_ items: [ShelfItem]) {
        let owned = items.filter(\.ownedCopy)
        guard !owned.isEmpty, persists else { return }
        let disk = disk
        io.async { owned.forEach(disk.dispose) }
    }

    /// The type to ask a provider without a file URL for (a promised file or plain image data).
    private nonisolated static func promisedType(of provider: NSItemProvider) -> String? {
        let types = provider.registeredTypeIdentifiers
        let wanted: [UTType] = [.image, .movie, .audio, .pdf, .archive, .data]
        for want in wanted {
            if let match = types.first(where: { UTType($0)?.conforms(to: want) == true && $0 != UTType.fileURL.identifier }) {
                return match
            }
        }
        return nil
    }

    private nonisolated static func suggestedName(for provider: NSItemProvider, type: String) -> String? {
        let ext = UTType(type)?.preferredFilenameExtension
        guard var name = provider.suggestedName, !name.isEmpty else {
            return ext.map { L("Файл.%@", $0) }
        }
        if let ext, (name as NSString).pathExtension.isEmpty { name += ".\(ext)" }
        return name
    }
}
