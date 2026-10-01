import AppKit
import Combine
import NotchBuddyCore
import SwiftUI

/// Settings inside the island: the ⚙️ page (`SettingsPage`, registered as an `IslandPages` page) and the values the
/// island reads from `SettingsStore` (hover delay, notices, size, screen, motion, widgets).
///
/// The page is opened by ⚙️ in the list header (`actions.showPage(IslandSettings.pageID)`), morphs in from the list
/// like any page (the silhouette springs to its size, its cards cascade in), and goes back with the × in its own
/// header (`showPage(nil)`). It closes with the island once the pointer leaves, unless pinned (📌 beside the ×).
@MainActor
enum IslandSettings {
    static let pageID = "settings"

    /// One model for the app's lifetime: the open section survives closing and reopening the page.
    static let model = SettingsPageModel.live()

    static var store: SettingsStore { .shared }
    static var values: NotchSettings { SettingsStore.shared.values }

    /// Registers the page (once, at launch).
    static func register() {
        // A readable column, narrower than the wide list: list → settings morphs the width too.
        IslandPages.register(IslandPageSpec(id: pageID, width: { IslandLayout.settingsWidth($0) }) { context in
            AnyView(SettingsIslandPage(model: model, context: context))
        })
    }

    // MARK: What the island reads

    /// Rest on the closed island before the list opens (nil: hover never opens it, a click does).
    static var restDwell: Double? { values.hoverOpen.restDwell.map { max($0, 0.001) } }
    /// Over the island this long opens it even while the pointer keeps moving (nil: never).
    static var maxDwell: Double? { values.hoverOpen.maxDwell }
    /// Width multiplier of the open island (Settings → Остров → Размер).
    static var widthScale: CGFloat { CGFloat(values.size.scale) }
    /// The closed island's usage ring (Settings → Лимиты → «Кольцо на свёрнутом острове»).
    static var showsUsageRing: Bool { values.showsUsageRing }
}

/// The settings page on the stage: the page's model follows it on and off the screen.
private struct SettingsIslandPage: View {
    @ObservedObject var model: SettingsPageModel
    let context: IslandPageContext

    var body: some View {
        SettingsPage(model: model, metrics: context.metrics, width: context.width,
                     maxHeight: IslandLayout.maxOpenHeight,
                     pinned: context.state.pinned, pinBounce: context.state.pinBounce,
                     onTogglePin: context.actions.togglePin,
                     onClose: { context.actions.showPage(nil) })
            .onAppear { model.pageDidAppear() }
            .onDisappear { model.pageDidDisappear() }
    }
}
