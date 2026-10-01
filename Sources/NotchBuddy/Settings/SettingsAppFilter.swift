import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NotchBuddyCore

// Settings → Остров: «Где показывать» (in which apps the island shows) and the dragged capsule's «Положение».

// MARK: - Where the island shows

/// «Где показывать»: in every app, only while one of the chosen apps is in front, or everywhere except while one of them
/// is. Under the two "chosen" modes: the list of apps (icon, name, ×), «Добавить приложение…» with the running apps and
/// «Другое…» (an open panel on /Applications), and «Всегда показывать запросы агентов».
struct AppFilterSetting: View {
    @ObservedObject var store: SettingsStore
    /// «Другое…» (default: the open panel, into `store`).
    var onChooseOther: (() -> Void)?
    /// Static renders: the picker open with these apps (the live page reads the running ones).
    var previewPicking: [PickableApp]?

    @Environment(\.islandReduceMotion) private var reduceMotion
    @State private var picking = false

    private var filter: Binding<IslandAppFilter> {
        Binding(get: { store.values.appFilter }, set: { value in
            store.values.appFilter = value
            if !value.usesApps { picking = false }
        })
    }

    var body: some View {
        let mode = store.values.appFilter
        VStack(alignment: .leading, spacing: 7) {
            SettingsCaption(text: L("Где показывать"))
            SettingsSegmented(selection: filter, options: IslandAppFilter.allCases, label: \.label)
            Text(mode.hint)
                .settingsFont(10.5, .medium)
                .foregroundStyle(IslandPalette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.interpolate)
                .animation(IslandMotion.leaf, value: mode)
            if mode.usesApps {
                VStack(alignment: .leading, spacing: 9) {
                    ChosenAppsList(store: store, picking: previewPicking == nil ? $picking : .constant(true),
                                   previewApps: previewPicking,
                                   onChooseOther: onChooseOther ?? { AppChooser.chooseOther(into: store) })
                    SettingsToggleRow(title: L("Всегда показывать запросы агентов"),
                                      hint: L("Разрешения и «Ждёт тебя» появятся и там, где остров спрятан"),
                                      isOn: $store.values.alwaysShowAgentRequests)
                }
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(SettingsMotion.expand(reduce: reduceMotion), value: mode.usesApps)
    }
}

/// The apps of the current mode, one row each (real icon, name, ×), then «Добавить приложение…».
private struct ChosenAppsList: View {
    @ObservedObject var store: SettingsStore
    @Binding var picking: Bool
    let previewApps: [PickableApp]?
    let onChooseOther: () -> Void

    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        let apps = store.values.chosenApps
        VStack(spacing: 2) {
            if apps.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(IslandPalette.tertiary)
                        .frame(width: 22, height: 22)
                    Text(store.values.appFilter == .only ? L("Пока пусто — остров виден везде")
                         : L("Пока пусто — остров нигде не прячется"))
                        .settingsFont(11.5, .medium)
                        .foregroundStyle(IslandPalette.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .frame(height: 32)
                .transition(.opacity)
            }
            ForEach(apps) { app in
                ChosenAppRow(app: app) {
                    withAnimation(SettingsMotion.expand(reduce: reduceMotion)) { store.values.removeChosenApp(app.bundleID) }
                }
                .transition(.opacity.combined(with: .offset(x: 12)))
            }
            AddAppRow(open: picking) {
                withAnimation(SettingsMotion.expand(reduce: reduceMotion)) { picking.toggle() }
            }
            if picking {
                RunningAppsPicker(chosen: Set(apps.map(\.id)), preview: previewApps, onPick: { app in
                    withAnimation(SettingsMotion.expand(reduce: reduceMotion)) { store.values.addChosenApp(app) }
                }, onOther: onChooseOther)
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SettingsPalette.well))
        .animation(SettingsMotion.expand(reduce: reduceMotion), value: apps)
    }
}

private struct ChosenAppRow: View {
    let app: ChosenApp
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        let found = AppIcons.url(for: app.bundleID) != nil
        HStack(spacing: 9) {
            Image(nsImage: AppIcons.icon(for: app.bundleID))
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
                .opacity(found ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 0) {
                Text(AppIcons.name(for: app))
                    .settingsFont(12, .semibold)
                    .foregroundStyle(Color.white.opacity(found ? 0.92 : 0.6))
                    .lineLimit(1)
                if !found {
                    Text(L("Не установлено"))
                        .settingsFont(10, .medium)
                        .foregroundStyle(IslandPalette.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hovering ? Color.white : IslandPalette.tertiary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(hovering ? 0.14 : 0.06)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.88))
            .help(L("Убрать из списка"))
            .accessibilityLabel(L("Убрать %@", AppIcons.name(for: app)))
        }
        .padding(.horizontal, 9)
        .frame(height: found ? 32 : 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hovering ? 0.05 : 0)))
        .onHover { hovering = $0 }
        .animation(SettingsMotion.hover, value: hovering)
    }
}

private struct AddAppRow: View {
    let open: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(hovering || open ? Color.white : IslandPalette.secondary)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(hovering || open ? 0.14 : 0.08)))
                Text(L("Добавить приложение…"))
                    .settingsFont(12, .semibold)
                    .foregroundStyle(hovering || open ? Color.white : IslandPalette.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(IslandPalette.tertiary)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .onHover { hovering = $0 }
        .animation(SettingsMotion.hover, value: hovering)
    }
}

/// An app the picker offers.
struct PickableApp: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let icon: NSImage
    var id: String { bundleID.lowercased() }

    /// The regular apps running now (not NotchBuddy), by name.
    @MainActor
    static func running() -> [PickableApp] {
        let own = ProcessInfo.processInfo.processIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app -> PickableApp? in
            guard app.activationPolicy == .regular, app.processIdentifier != own, let id = app.bundleIdentifier,
                  seen.insert(id.lowercased()).inserted else { return nil }
            let name = app.localizedName ?? id
            return PickableApp(bundleID: id, name: name, icon: app.icon ?? AppIcons.icon(for: id))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// The running apps not chosen yet, as icon tiles, and «Другое…» (any app, from an open panel).
private struct RunningAppsPicker: View {
    let chosen: Set<String>
    let preview: [PickableApp]?
    let onPick: (ChosenApp) -> Void
    let onOther: () -> Void

    @State private var running: [PickableApp] = []

    private let columns = [GridItem(.adaptive(minimum: 74, maximum: 96), spacing: 4)]

    var body: some View {
        let apps = (preview ?? running).filter { !chosen.contains($0.id) }
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(apps) { app in
                PickerTile(title: app.name) {
                    Image(nsImage: app.icon).resizable().interpolation(.high).frame(width: 28, height: 28)
                } action: {
                    onPick(ChosenApp(bundleID: app.bundleID, name: app.name))
                }
                .help(app.name)
            }
            PickerTile(title: L("Другое…")) {
                Image(systemName: "folder")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(IslandPalette.secondary)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
            } action: {
                onOther()
            }
            .help(L("Выбрать приложение в папке «Программы»"))
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .onAppear { if preview == nil { running = PickableApp.running() } }
    }
}

private struct PickerTile<Icon: View>: View {
    let title: String
    @ViewBuilder var icon: () -> Icon
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                icon()
                Text(title)
                    .settingsFont(10, .semibold)
                    .foregroundStyle(hovering ? Color.white : IslandPalette.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hovering ? 0.09 : 0.03)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .onHover { hovering = $0 }
        .animation(SettingsMotion.hover, value: hovering)
    }
}

// MARK: - Icons and names

/// App icons and names by bundle identifier, looked up once (Launch Services is not free) and kept.
@MainActor
enum AppIcons {
    private static var icons: [String: NSImage] = [:]
    private static var urls: [String: URL?] = [:]

    static func url(for bundleID: String) -> URL? {
        let key = bundleID.lowercased()
        if let cached = urls[key] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        urls[key] = url
        return url
    }

    static func icon(for bundleID: String) -> NSImage {
        let key = bundleID.lowercased()
        if let icon = icons[key] { return icon }
        let icon = url(for: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        icons[key] = icon
        return icon
    }

    /// The app's name as Finder shows it, or the one stored when it was chosen.
    static func name(for app: ChosenApp) -> String {
        if let url = url(for: app.bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return app.name.isEmpty ? app.bundleID : app.name
    }
}

// MARK: - «Другое…»

/// «Другое…»: an open panel on /Applications. NotchBuddy comes to the front for it (the island's settings close as the
/// pointer goes there), the app that was in front gets it back afterwards, and the settings open again with the apps
/// added.
@MainActor
enum AppChooser {
    /// Opens the island's settings again (`IslandController.showSettings`).
    static var reopenSettings: () -> Void = {}
    private static var panel: NSOpenPanel?

    static func chooseOther(into store: SettingsStore) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.title = L("Выбери приложения")
        panel.message = L("Остров учтёт их в «Где показывать»")
        panel.prompt = L("Добавить")
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        self.panel = panel
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        panel.begin { response in
            MainActor.assumeIsolated {
                Self.panel = nil
                let apps = response == .OK ? panel.urls.compactMap(Self.app(at:)) : []
                for app in apps { store.values.addChosenApp(app) }
                if let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    previous.activate()
                }
                if !apps.isEmpty { reopenSettings() }
            }
        }
    }

    private static func app(at url: URL) -> ChosenApp? {
        guard let id = Bundle(url: url)?.bundleIdentifier, !id.isEmpty else { return nil }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return ChosenApp(bundleID: id, name: name)
    }
}

// MARK: - Position («Островок» dragged)

/// «Положение»: the capsule can be dragged sideways along the top; «Сбросить положение» brings it back to the center on
/// every screen (a double click on the capsule does it for one).
struct IslandPositionSetting: View {
    @ObservedObject var store: SettingsStore
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        let moved = !store.values.islandOffsets.isEmpty
        SettingsRow(title: L("Положение"),
                    hint: moved ? L("Капсула сдвинута — двойной клик по ней тоже вернёт её в центр")
                        : L("Потяни капсулу вбок, чтобы передвинуть; двойной клик — обратно в центр")) {
            Button(L("Сбросить положение")) {
                withAnimation(SettingsMotion.control(reduce: reduceMotion)) { store.values.islandOffsets = [:] }
            }
            .buttonStyle(SettingsButtonStyle(kind: .neutral))
            .disabled(!moved)
        }
    }
}
