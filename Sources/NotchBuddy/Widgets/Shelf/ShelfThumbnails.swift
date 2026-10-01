import AppKit
import NotchBuddyCore
import Observation
import QuickLookThumbnailing

/// A tile's picture: a Quick Look thumbnail of the file's content (photos, PDFs, documents, video frames),
/// or its Finder icon (folders, apps, files Quick Look cannot draw).
struct ShelfThumbnail {
    let image: NSImage
    /// A Finder icon rather than the content: drawn as is, without the photo frame.
    let isIcon: Bool
}

/// Thumbnails for the shelf's tiles, made once per file version and kept in memory (at most `limit`).
/// The Finder icon shows at once; Quick Look's picture replaces it when ready.
@MainActor
@Observable
final class ShelfThumbnails {
    private(set) var images: [UUID: ShelfThumbnail] = [:]

    @ObservationIgnored private var versions: [UUID: String] = [:]
    @ObservationIgnored private var inFlight: Set<UUID> = []
    @ObservationIgnored private var order: [UUID] = []
    @ObservationIgnored private let limit = 120
    /// Pixel size asked of Quick Look (tiles are ~64 pt; @2x with room for a hover zoom).
    nonisolated static let side: CGFloat = 168

    func thumbnail(for item: ShelfItem) -> ShelfThumbnail? { images[item.id] }

    /// Starts making the thumbnail if there is none for this version of the file.
    func load(_ item: ShelfItem) {
        let version = Self.version(of: item)
        if versions[item.id] == version, images[item.id] != nil || inFlight.contains(item.id) { return }
        versions[item.id] = version
        if images[item.id] == nil {
            let icon = NSWorkspace.shared.icon(forFile: item.path)
            icon.size = NSSize(width: 128, height: 128)
            store(ShelfThumbnail(image: icon, isIcon: true), for: item.id)
        }
        guard !item.isDirectory || item.kind != .folder else { return }
        inFlight.insert(item.id)
        let id = item.id
        let request = QLThumbnailGenerator.Request(fileAt: item.url,
                                                   size: CGSize(width: Self.side / 2, height: Self.side / 2),
                                                   scale: 2, representationTypes: [.lowQualityThumbnail, .thumbnail])
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let image = representation?.nsImage
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inFlight.remove(id)
                    guard let image, self.versions[id] == version else { return }
                    self.store(ShelfThumbnail(image: image, isIcon: false), for: id)
                }
            }
        }
    }

    /// Previews: puts a picture in place without Quick Look.
    func seed(_ thumbnail: ShelfThumbnail, for id: UUID) {
        store(thumbnail, for: id)
    }

    func forget(_ id: UUID) {
        images[id] = nil
        versions[id] = nil
        order.removeAll { $0 == id }
    }

    func forgetAll() {
        images.removeAll()
        versions.removeAll()
        order.removeAll()
    }

    /// Blocks (spinning the run loop) until pending Quick Look requests finish or `timeout` passes (previews).
    func waitForPending(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !inFlight.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func store(_ thumbnail: ShelfThumbnail, for id: UUID) {
        images[id] = thumbnail
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > limit {
            let evicted = order.removeFirst()
            images[evicted] = nil
            versions[evicted] = nil
        }
    }

    private static func version(of item: ShelfItem) -> String {
        let modified = (try? FileManager.default.attributesOfItem(atPath: item.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        return "\(item.path)|\(item.byteSize ?? -1)|\(modified)"
    }
}
