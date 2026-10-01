import AppKit
import NotchBuddyCore

/// The agents' real app icons (Claude, ChatGPT/Codex, Kimi), read from the installed bundles.
/// `nil` when the app isn't installed — `AgentMark` then draws its own badge.
@MainActor
enum AgentAppIcon {
    private static var cache: [AgentSource: NSImage?] = [:]

    /// macOS icons carry a transparent margin (about 100 of 1024 px per side); scaling by this makes the
    /// icon body fill the same box the drawn badge does.
    static let bodyScale: CGFloat = 1024 / 824

    /// Off for rendered films and previews (`--render-…`): they draw the badges, never the icons of the apps
    /// installed on the Mac that renders them.
    static var useInstalledIcons = true

    static func image(for source: AgentSource) -> NSImage? {
        guard useInstalledIcons else { return nil }
        if let hit = cache[source] { return hit }
        let icon = appURL(for: source).map { rasterized(NSWorkspace.shared.icon(forFile: $0.path)) }
        cache[source] = icon
        return icon
    }

    /// The icon drawn once from its large sizes into a single 256 px bitmap: every smaller size is scaled down from
    /// that. Some bundles ship broken small sizes (Kimi.app's 16 and 32 px images are coloured noise), and AppKit
    /// would pick exactly those for a 14–28 pt mark.
    static func rasterized(_ icon: NSImage, side: Int = 256) -> NSImage {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return icon }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        // The destination is 256 px, so the icon picks its 256 / 512 px image.
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1,
                  respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: side / 2, height: side / 2))
        image.addRepresentation(rep)
        return image
    }

    private static func appURL(for source: AgentSource) -> URL? {
        let (bundleIDs, names): ([String], [String]) = switch source {
        case .claude: (["com.anthropic.claudefordesktop"], ["Claude.app"])
        case .codex: (["com.openai.codex"], ["Codex.app", "ChatGPT.app"])
        case .kimi: (["com.moonshot.kimichat"], ["Kimi.app"])
        default: (AgentCatalog.descriptor(for: source)?.appBundleIdentifiers ?? [],
                  AgentCatalog.descriptor(for: source)?.appNames ?? [])
        }
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        let dirs = ["/Applications", NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            for name in names {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }
}
