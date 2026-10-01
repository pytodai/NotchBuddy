import Foundation
import UniformTypeIdentifiers

// The file shelf ("Полка"): files dropped on the island wait there until they are dragged out again.
// This file holds the UI-free model (items, the catalog and its rules, formatting); `ShelfDisk` does
// the file-system work. Both are unit-tested; the app wraps them in `ShelfStore`.

/// When a dropped file is copied into the shelf's own storage instead of being referenced in place.
public enum ShelfCopyPolicy: String, Codable, CaseIterable, Sendable {
    /// Always reference the original (a deleted original disappears from the shelf).
    case never
    /// Copy only files that live in temporary places (screenshots' floating thumbnails, browser downloads
    /// in progress, attachments opened from Mail…): they would vanish soon.
    case temporaryOnly
    /// Copy everything: the shelf keeps its own snapshot of each file.
    case always

    public static let `default`: ShelfCopyPolicy = .temporaryOnly
}

/// What a file is, for its label and fallback icon.
public enum ShelfKind: String, Codable, CaseIterable, Sendable {
    case folder, image, video, audio, pdf, archive, code, text, document, spreadsheet, presentation, app, other

    /// Russian noun for the tile's subtitle ("Изображение · 2,4 МБ").
    public var label: String {
        switch self {
        case .folder: return L("Папка")
        case .image: return L("Изображение")
        case .video: return L("Видео")
        case .audio: return L("Аудио")
        case .pdf: return "PDF"
        case .archive: return L("Архив")
        case .code: return L("Код")
        case .text: return L("Текст")
        case .document: return L("Документ")
        case .spreadsheet: return L("Таблица")
        case .presentation: return L("Презентация")
        case .app: return L("Приложение")
        case .other: return L("Файл")
        }
    }

    /// Classifies by file name (and whether it is a directory); no file-system access.
    public static func of(name: String, isDirectory: Bool) -> ShelfKind {
        let ext = (name as NSString).pathExtension.lowercased()
        if isDirectory {
            if ext == "app" { return .app }
            if ["key", "pages", "numbers", "rtfd", "bundle"].contains(ext) == false { return .folder }
        }
        switch ext {
        case "key", "pptx", "ppt", "odp": return .presentation
        case "numbers", "xlsx", "xls", "csv", "tsv", "ods": return .spreadsheet
        case "pages", "docx", "doc", "rtf", "rtfd", "odt": return .document
        case "": return isDirectory ? .folder : .other
        default: break
        }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json)
            || type.conforms(to: .xml) || ["yml", "yaml", "toml", "md"].contains(ext) {
            return ext == "md" ? .text : .code
        }
        if type.conforms(to: .text) { return .text }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return .app }
        return .other
    }
}

/// One file on the shelf.
public struct ShelfItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Where the file is now (a reference: the original; a copy: inside the shelf's storage).
    public var path: String
    /// Where it was dropped from (equal to `path` for a reference). Two drops of the same origin are one item.
    public var originPath: String
    /// Follows the original when it is renamed or moved (references only; nil when it could not be made).
    public var bookmark: Data?
    public var name: String
    public var kind: ShelfKind
    public var isDirectory: Bool
    /// Bytes of a file (nil for a folder).
    public var byteSize: Int64?
    /// Entries directly inside a folder (nil for a file).
    public var childCount: Int?
    public var addedAt: Date
    /// The shelf owns this copy: it lives in the shelf's storage and leaves with the item.
    public var ownedCopy: Bool

    public init(id: UUID = UUID(), path: String, originPath: String? = nil, bookmark: Data? = nil, name: String? = nil,
                kind: ShelfKind? = nil, isDirectory: Bool = false, byteSize: Int64? = nil, childCount: Int? = nil,
                addedAt: Date, ownedCopy: Bool = false) {
        self.id = id
        self.path = path
        self.originPath = originPath ?? path
        self.bookmark = bookmark
        let displayName = name ?? (path as NSString).lastPathComponent
        self.name = displayName
        self.kind = kind ?? ShelfKind.of(name: displayName, isDirectory: isDirectory)
        self.isDirectory = isDirectory
        self.byteSize = byteSize
        self.childCount = childCount
        self.addedAt = addedAt
        self.ownedCopy = ownedCopy
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }

    /// Key for "the same file dropped again".
    public var dedupeKey: String { ShelfCatalog.normalize(originPath) }

    /// Upper-case extension for the tile's corner tag ("PNG"), nil for folders and extension-less files.
    public var extensionTag: String? {
        guard !isDirectory || kind == .app else { return nil }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, ext.count <= 5 else { return nil }
        return ext.uppercased()
    }

    /// "Изображение · 2,4 МБ", "Папка · 12 объектов".
    public var subtitle: String {
        if isDirectory, kind == .folder {
            guard let childCount else { return kind.label }
            return "\(kind.label) · \(ShelfFormat.objects(childCount))"
        }
        guard let byteSize else { return kind.label }
        return "\(kind.label) · \(ShelfFormat.size(byteSize))"
    }
}

/// The shelf's items, newest first, and the rules for changing them. Pure: the caller disposes of the
/// items an operation hands back (owned copies leave the disk with them) and persists the catalog.
public struct ShelfCatalog: Codable, Equatable, Sendable {
    public static let defaultCapacity = 60
    public static let currentVersion = 1

    public var version = ShelfCatalog.currentVersion
    public private(set) var items: [ShelfItem]
    /// The most items kept; the oldest beyond it leave the shelf.
    public var capacity: Int

    public init(items: [ShelfItem] = [], capacity: Int = ShelfCatalog.defaultCapacity) {
        self.items = items
        self.capacity = max(1, capacity)
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }
    public var totalBytes: Int64 { items.reduce(0) { $0 + ($1.byteSize ?? 0) } }

    public func item(_ id: UUID) -> ShelfItem? { items.first { $0.id == id } }

    /// Origins already on the shelf (to skip copying a file that is there already).
    public var origins: Set<String> { Set(items.map(\.dedupeKey)) }

    /// Puts new items in front, in the given order. A file already on the shelf (same origin, or the same id:
    /// one of the shelf's own copies dropped back on it) is not added
    /// twice: the existing item moves to the front with the new drop's size, and the new item is handed back
    /// (dispose it if it is an owned copy). Items beyond `capacity` (the oldest) are handed back too.
    /// Returns (items now on the shelf that came from this drop, items to dispose).
    @discardableResult
    public mutating func insert(_ incoming: [ShelfItem]) -> (placed: [ShelfItem], discarded: [ShelfItem]) {
        var placed: [ShelfItem] = []
        var discarded: [ShelfItem] = []
        var front: [ShelfItem] = []
        var seen = Set<String>()
        for var item in incoming {
            let key = item.dedupeKey
            if seen.contains(key) {
                discarded.append(item)
                continue
            }
            seen.insert(key)
            if let index = items.firstIndex(where: { $0.id == item.id || $0.dedupeKey == key }) {
                var existing = items.remove(at: index)
                existing.addedAt = item.addedAt
                if existing.ownedCopy == item.ownedCopy {
                    existing.byteSize = item.byteSize ?? existing.byteSize
                    existing.childCount = item.childCount ?? existing.childCount
                }
                if item.id != existing.id { discarded.append(item) }
                item = existing
            }
            front.append(item)
            placed.append(item)
        }
        items = front + items
        if items.count > capacity {
            let overflow = Array(items[capacity...])
            items.removeLast(items.count - capacity)
            discarded.append(contentsOf: overflow)
            let gone = Set(overflow.map(\.id))
            placed.removeAll { gone.contains($0.id) }
        }
        return (placed, discarded)
    }

    /// Removes one item; returns it (to dispose).
    @discardableResult
    public mutating func remove(_ id: UUID) -> ShelfItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    /// Empties the shelf; returns what was on it (to dispose).
    @discardableResult
    public mutating func removeAll() -> [ShelfItem] {
        defer { items.removeAll() }
        return items
    }

    /// Replaces an item's file facts after a refresh (moved original, new size); keeps its place.
    public mutating func update(_ item: ShelfItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
    }

    /// Moves an item to a new position (drag to reorder), clamped to the shelf.
    public mutating func move(_ id: UUID, to position: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        items.insert(item, at: min(max(0, position), items.count))
    }

    /// Standard spelling of a path, without touching the disk: `..` and `.` resolved, and the system's own
    /// `/private` links folded (so /tmp/x and /private/tmp/x are one file).
    public static func normalize(_ path: String) -> String {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        for linked in ["/private/tmp", "/private/var", "/private/etc"]
        where standard == linked || standard.hasPrefix(linked + "/") {
            return String(standard.dropFirst("/private".count))
        }
        return standard
    }
}

/// Localized formatting for the shelf.
public enum ShelfFormat {
    /// Finder-style decimal sizes with the language's decimal separator: "845 Б", "8,4 КБ", "120 КБ", "1,2 МБ", "3,4 ГБ".
    public static func size(_ bytes: Int64) -> String {
        let units = [L("Б"), L("КБ"), L("МБ"), L("ГБ"), L("ТБ")]
        var value = Double(max(0, bytes))
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return L("%@ Б", Int(value)) }
        // One decimal below 10 ("8,4 КБ"), whole numbers above ("120 КБ"); 999.6 rounds up a unit.
        if value < 9.95 {
            let text = L10n.decimal(value)
            return "\(text.hasSuffix(",0") || text.hasSuffix(".0") ? String(text.dropLast(2)) : text) \(units[unit])"
        }
        let whole = Int(value.rounded())
        if whole >= 1000, unit < units.count - 1 { return "1 \(units[unit + 1])" }
        return "\(whole) \(units[unit])"
    }

    public static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        Lp(n, one, few, many)
    }

    /// "1 файл", "3 файла", "12 файлов".
    public static func files(_ n: Int) -> String { "\(n) \(plural(n, "файл", "файла", "файлов"))" }

    /// "1 объект", "4 объекта", "12 объектов".
    public static func objects(_ n: Int) -> String { "\(n) \(plural(n, "объект", "объекта", "объектов"))" }

    /// The shelf's summary line: "3 файла · 12 МБ" (no size when nothing has a known size).
    public static func summary(_ catalog: ShelfCatalog) -> String {
        let bytes = catalog.totalBytes
        return bytes > 0 ? "\(files(catalog.count)) · \(size(bytes))" : files(catalog.count)
    }
}
