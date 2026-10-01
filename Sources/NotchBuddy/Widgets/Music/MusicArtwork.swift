import AppKit
import ImageIO
import NotchBuddyCore
import SwiftUI

/// A track's cover, ready to draw: the image (nil: a neutral placeholder) and its colors. Built off the
/// main thread once per track.
struct MusicArtwork: Equatable, @unchecked Sendable {
    /// The track (`NowPlayingTrack.id`).
    let key: String
    let cover: CGImage?
    let palette: ArtworkPalette

    var isPlaceholder: Bool { cover == nil }

    static func == (a: MusicArtwork, b: MusicArtwork) -> Bool {
        a.key == b.key && a.cover === b.cover && a.palette == b.palette
    }
}

enum MusicArtworkFactory {
    /// Decodes a cover (JPEG, PNG, TIFF…): nil when it is not an image.
    static func make(key: String, data: Data) -> MusicArtwork? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 320,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return make(key: key, image: image)
    }

    static func make(key: String, image: CGImage) -> MusicArtwork {
        MusicArtwork(key: key, cover: image, palette: palette(of: image))
    }

    /// No cover: a neutral grey square with a note is drawn; the palette (stable per album) is kept for
    /// callers that want one, but nothing on screen is tinted by it.
    static func placeholder(key: String, seed: String) -> MusicArtwork {
        MusicArtwork(key: key, cover: nil, palette: ArtworkPalette.placeholder(seed: seed))
    }

    private static func palette(of image: CGImage) -> ArtworkPalette {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return .placeholder(seed: "\(image.width)x\(image.height)") }
        return ArtworkPalette.extract(rgba: pixels, width: side, height: side)
    }
}

extension PaletteColor {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
}

extension ArtworkPalette {
    /// The cover's color for the one small tinted mark (the equalizer), calmed: its hue at a soft
    /// saturation and an even, light value, so it reads as "the cover's color" on black without ever
    /// buzzing. A black-and-white cover gives a light grey.
    var calm: PaletteColor {
        if isMonochrome { return PaletteColor(0.86, 0.86, 0.87) }
        let (h, s, _) = primary.hsv
        return PaletteColor(h: h, s: min(s * 0.55, 0.36), v: 0.9)
    }
}

/// Covers already built, by track (a skip back and forth does not rebuild them).
@MainActor
final class MusicArtworkCache {
    private var entries: [String: MusicArtwork] = [:]
    private var order: [String] = []
    private let limit: Int

    init(limit: Int = 16) { self.limit = limit }

    subscript(key: String) -> MusicArtwork? {
        entries[key]
    }

    func insert(_ artwork: MusicArtwork) {
        if entries[artwork.key] == nil { order.append(artwork.key) }
        entries[artwork.key] = artwork
        while order.count > limit {
            entries[order.removeFirst()] = nil
        }
    }
}

/// The players' real app icons (nil when not installed: the badge draws its own).
@MainActor
enum MusicPlayerIcon {
    private static var cache: [MusicPlayer: NSImage?] = [:]

    /// Off for rendered films and previews, like `AgentAppIcon.useInstalledIcons`.
    static var useInstalledIcons = true

    static func image(_ player: MusicPlayer) -> NSImage? {
        guard useInstalledIcons else { return nil }
        if let hit = cache[player] { return hit }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[player] = icon
        return icon
    }

    static func isInstalled(_ player: MusicPlayer) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) != nil
    }
}
