import Foundation

/// The shelf on disk: `shelf.json` (the catalog) and `Files/<id>/<name>` (copies the shelf owns), under
/// `~/Library/Application Support/NotchBuddy/Shelf` (inside `NOTCHBUDDY_HOME` when that is set).
///
/// Referenced files are never modified, moved or deleted: only the shelf's own copies leave the disk, and
/// by default they go to the Trash (a copy may be the only one left, e.g. a screenshot dragged straight from
/// its floating thumbnail).
public struct ShelfDisk: Sendable {
    public enum Disposal: Sendable {
        /// Owned copies go to the Trash (the app).
        case trash
        /// Owned copies are deleted (tests, scratch shelves).
        case delete
    }

    public let directory: URL
    public var disposal: Disposal
    /// Where "temporary" places are judged from (the user's home).
    public var home: URL

    public init(directory: URL, disposal: Disposal = .trash, home: URL = Paths.home) {
        self.directory = directory
        self.disposal = disposal
        self.home = home
    }

    /// The app's shelf.
    public static var standard: ShelfDisk {
        ShelfDisk(directory: Paths.home.appendingPathComponent("Library/Application Support/NotchBuddy/Shelf",
                                                               isDirectory: true))
    }

    public var catalogURL: URL { directory.appendingPathComponent("shelf.json") }
    public var filesDirectory: URL { directory.appendingPathComponent("Files", isDirectory: true) }

    // MARK: Catalog

    /// The saved catalog; empty when there is none. An unreadable file is set aside (`shelf.json.bad`) so the
    /// next save does not silently replace it.
    public func load(capacity: Int = ShelfCatalog.defaultCapacity) -> ShelfCatalog {
        guard let data = try? Data(contentsOf: catalogURL) else { return ShelfCatalog(capacity: capacity) }
        do {
            var catalog = try Self.decoder.decode(ShelfCatalog.self, from: data)
            catalog.capacity = capacity
            return catalog
        } catch {
            let bad = catalogURL.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.moveItem(at: catalogURL, to: bad)
            return ShelfCatalog(capacity: capacity)
        }
    }

    public func save(_ catalog: ShelfCatalog) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Self.encoder.encode(catalog).write(to: catalogURL, options: .atomic)
    }

    // MARK: Adding

    /// Shelf items for dropped files: facts read from disk, copies made where `policy` asks (a file whose
    /// origin is already in `existingOrigins` is not copied again; the catalog merges it). Files that do not
    /// exist are skipped. Blocking file I/O: call it off the main thread.
    public func makeItems(for urls: [URL], policy: ShelfCopyPolicy, existingOrigins: Set<String> = [],
                          now: Date = Date()) -> [ShelfItem] {
        var items: [ShelfItem] = []
        for url in urls where url.isFileURL {
            let origin = ShelfCatalog.normalize(url.path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: origin, isDirectory: &isDirectory) else { continue }
            // One of the shelf's own copies dropped back on it: it is that item.
            let ownCopy = isInside(origin, filesDirectory)
            let copy = !ownCopy && !existingOrigins.contains(origin)
                && (policy == .always || (policy == .temporaryOnly && isTemporary(URL(fileURLWithPath: origin))))
            // An own copy keeps its item's id (its folder's name), so the catalog finds the item again.
            let folderID = UUID(uuidString: URL(fileURLWithPath: origin).deletingLastPathComponent().lastPathComponent)
            let id = ownCopy ? (folderID ?? UUID()) : UUID()
            var path = origin
            if copy {
                guard let copied = try? copyIn(URL(fileURLWithPath: origin), id: id) else { continue }
                path = copied.path
            }
            var item = facts(path: path, isDirectory: isDirectory.boolValue, id: id, now: now)
            item.originPath = origin
            item.ownedCopy = copy || ownCopy
            if !item.ownedCopy { item.bookmark = try? URL(fileURLWithPath: path).bookmarkData(options: []) }
            items.append(item)
        }
        return items
    }

    /// An item for data the drag only promised (a file written to a temporary place by the drag, e.g. Photos,
    /// Mail attachments, screenshot thumbnails): always copied in, since the source file will not stay.
    public func adoptPromisedFile(at url: URL, suggestedName: String? = nil, now: Date = Date()) -> ShelfItem? {
        let id = UUID()
        guard let copied = try? copyIn(url, id: id, name: suggestedName) else { return nil }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: copied.path, isDirectory: &isDirectory)
        var item = facts(path: copied.path, isDirectory: isDirectory.boolValue, id: id, now: now)
        item.originPath = copied.path
        item.ownedCopy = true
        return item
    }

    /// Where a referenced file is now: follows its bookmark when the original moved or was renamed. Nil when
    /// the file is gone. Sizes are read again.
    public func resolve(_ item: ShelfItem) -> ShelfItem? {
        var path = item.path
        if !FileManager.default.fileExists(atPath: path), let bookmark = item.bookmark {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
            path = url.path
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        var fresh = facts(path: path, isDirectory: isDirectory.boolValue, id: item.id, now: item.addedAt)
        fresh.originPath = item.path == item.originPath ? path : item.originPath
        fresh.ownedCopy = item.ownedCopy
        fresh.bookmark = item.bookmark
        if path != item.path, !item.ownedCopy {
            fresh.bookmark = (try? URL(fileURLWithPath: path).bookmarkData(options: [])) ?? item.bookmark
        }
        return fresh
    }

    // MARK: Removing

    /// Removes an item's owned copy from disk (a referenced file is never touched).
    public func dispose(_ item: ShelfItem) {
        guard item.ownedCopy else { return }
        let url = URL(fileURLWithPath: item.path)
        guard isInside(ShelfCatalog.normalize(url.path), filesDirectory) else { return }
        // The copy lives in its own `Files/<id>/` folder: that folder goes.
        let folder = url.deletingLastPathComponent()
        let target = folder.lastPathComponent == item.id.uuidString ? folder : url
        switch disposal {
        case .trash:
            if (try? FileManager.default.trashItem(at: target, resultingItemURL: nil)) == nil {
                try? FileManager.default.removeItem(at: target)
            }
        case .delete:
            try? FileManager.default.removeItem(at: target)
        }
    }

    /// Owned copies no item refers to any more (a crash between copying and saving): removed like `dispose`.
    public func sweepOrphans(keeping catalog: ShelfCatalog) {
        let keep = Set(catalog.items.filter(\.ownedCopy).map(\.id.uuidString))
        guard let folders = try? FileManager.default.contentsOfDirectory(at: filesDirectory, includingPropertiesForKeys: nil)
        else { return }
        for folder in folders where !keep.contains(folder.lastPathComponent) {
            switch disposal {
            case .trash:
                if (try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)) == nil {
                    try? FileManager.default.removeItem(at: folder)
                }
            case .delete:
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// Where file promises are written before they are copied in (`Incoming/<uuid>/`).
    public var incomingDirectory: URL { directory.appendingPathComponent("Incoming", isDirectory: true) }

    public func makeIncomingFolder() throws -> URL {
        let folder = incomingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// Leftovers of promises that never finished (a quit mid-drop). Only at launch.
    public func sweepIncoming() {
        try? FileManager.default.removeItem(at: incomingDirectory)
    }

    // MARK: Temporary places

    /// Files in places that are cleaned up behind the user's back: the system temporary folders
    /// (`/tmp`, `/private/var/folders/…`, including screenshots' `TemporaryItems`), caches, sandboxed apps'
    /// `tmp`, the Trash and Mail's downloads.
    public func isTemporary(_ url: URL) -> Bool {
        let path = ShelfCatalog.normalize(url.path)
        let home = ShelfCatalog.normalize(self.home.path)
        let system = ["/tmp/", "/var/folders/", "/var/tmp/"]
        if system.contains(where: { path.hasPrefix($0) }) { return true }
        let tmp = ShelfCatalog.normalize(NSTemporaryDirectory())
        if path.hasPrefix(tmp.hasSuffix("/") ? tmp : tmp + "/") { return true }
        let userPlaces = ["Library/Caches/", ".Trash/", "Library/Mail Downloads/",
                          "Library/Containers/com.apple.mail/Data/Library/Mail Downloads/"]
        if userPlaces.contains(where: { path.hasPrefix("\(home)/\($0)") }) { return true }
        // A sandboxed app's own temporary folder.
        let containers = "\(home)/Library/Containers/"
        if path.hasPrefix(containers), path.contains("/Data/tmp/") { return true }
        return false
    }

    // MARK: Private

    private func copyIn(_ source: URL, id: UUID, name: String? = nil) throws -> URL {
        let folder = filesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fileName = Self.safeName(name ?? source.lastPathComponent)
        let target = folder.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return target
    }

    private func facts(path: String, isDirectory: Bool, id: UUID, now: Date) -> ShelfItem {
        var size: Int64?
        var children: Int?
        if isDirectory {
            let kind = ShelfKind.of(name: (path as NSString).lastPathComponent, isDirectory: true)
            if kind == .folder {
                children = (try? FileManager.default.contentsOfDirectory(atPath: path))?
                    .filter { !$0.hasPrefix(".") }.count
            }
        } else if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let bytes = attributes[.size] as? NSNumber {
            size = bytes.int64Value
        }
        return ShelfItem(id: id, path: path, isDirectory: isDirectory, byteSize: size, childCount: children,
                         addedAt: now)
    }

    private func isInside(_ path: String, _ folder: URL) -> Bool {
        let base = ShelfCatalog.normalize(folder.path)
        return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// A file name that cannot escape its folder.
    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "∕").replacingOccurrences(of: ":", with: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." { return L("Файл") }
        return trimmed
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        return JSONDecoder()
    }()
}
