import AppKit
import SwiftUI
import NotchBuddyCore

/// `NotchBuddy --render-settings <dir>`: draws the settings page with fake data inside the island's silhouette
/// (every section open in turn, several scroll positions, both screen styles) to PNGs, then exits. Nothing is
/// read from or written to the real settings, hooks or backups.
@MainActor
enum SettingsPreviewRenderer {
    nonisolated static let flag = "--render-settings"

    nonisolated static func requestedDirectory(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        return index + 1 < arguments.count ? arguments[index + 1] : "build/settings-previews"
    }

    static let floating = IslandMetrics(style: .floating, notchWidth: 0,
                                        barHeight: IslandMetrics.floatingBarHeight(menuBar: 30), menuBarHeight: 30)
    static let notched = IslandMetrics(style: .notch, notchWidth: 188, barHeight: 37, menuBarHeight: 37)

    static func run(outputDirectory: String) -> Int32 {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot create \(directory.path): \(error)\n".utf8))
            return 1
        }
        NSApp.setActivationPolicy(.accessory)
        SettingsFont.registerIfNeeded()
        let suite = "me.sokolov.notchbuddy.settings-preview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return 1 }
        defer { defaults.removePersistentDomain(forName: suite) }

        var failures = 0
        var sheet: [CGImage] = []
        func emit(_ name: String, _ image: CGImage?, sheetIt: Bool = true) {
            guard let image else {
                FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
                failures += 1
                return
            }
            if write(image, to: directory.appendingPathComponent("\(name).png")) {
                if sheetIt { sheet.append(image) }
            } else {
                failures += 1
            }
        }

        // 1. Overview, both screen styles.
        for (suffix, metrics) in [("floating", floating), ("notch", notched)] {
            let model = makeModel(defaults: defaults)
            emit("overview-\(suffix)", shot(model, metrics: metrics))
        }

        // 2. Every section open, scrolled so its card is at the top.
        for section in SettingsSection.allCases where section.expandable {
            let model = makeModel(defaults: defaults)
            model.expanded = section
            emit("section-\(section.rawValue)", shot(model, metrics: floating, scrollTo: section))
        }

        // 3. The island section open, at several scroll positions (top, middle, end).
        do {
            let model = makeModel(defaults: defaults)
            model.expanded = .island
            let (natural, viewport) = measure(model, metrics: floating)
            let end = max(0, natural - viewport)
            for (i, offset) in [0, end / 2, end].enumerated() {
                emit("scroll-\(i)-island-\(Int(offset))", shot(model, metrics: floating, scroll: offset))
            }
        }

        // 4. States: a sound list open, recording a hotkey, a different accent, reduced motion, notch + open section.
        do {
            let model = makeModel(defaults: defaults)
            model.expanded = .sounds
            model.soundPicker = .finished
            emit("state-sound-picker", shot(model, metrics: floating, scrollTo: .sounds))

            let recording = makeModel(defaults: defaults)
            recording.expanded = .hotkey
            recording.recorder.showPreview(held: [.control, .option])
            emit("state-hotkey-recording", shot(recording, metrics: floating, scrollTo: .hotkey))

            let accent = makeModel(defaults: defaults)
            accent.store.values.accent = .mint
            accent.store.values.hotkeyEnabled = false
            accent.expanded = .appearance
            emit("state-accent-mint", shot(accent, metrics: floating, scrollTo: .appearance))

            let notch = makeModel(defaults: defaults)
            notch.expanded = .agents
            emit("state-agents-notch", shot(notch, metrics: notched, scrollTo: .agents))

            let off = makeModel(defaults: defaults)
            off.store.values.soundsEnabled = false
            off.expanded = .sounds
            emit("state-sounds-off", shot(off, metrics: floating, scrollTo: .sounds))

            // «Островок» on monitors: «Ширина капсулы» with the capsule's real-size preview (at the default and wider).
            for width in [NotchSettings.defaultCapsuleWidth, 300] {
                let capsule = makeModel(defaults: defaults)
                capsule.store.values.setIslandStyle(.island, hasNotch: false)
                capsule.store.values.capsuleWidth = width
                capsule.expanded = .island
                let (natural, viewport) = measure(capsule, metrics: floating)
                let end = max(0, natural - viewport)
                emit("state-capsule-width-\(Int(width))", shot(capsule, metrics: floating, scroll: end * 0.55))
            }
        }

        // 5. Motion: the page mounting (cards drop in one after another) and a section opening (its rows cascade),
        // sampled on the very curves the live page runs (`appearAfter`).
        do {
            let times = [0.0, 0.03, 0.05, 0.08, 0.11, 0.15, 0.2, 0.3]
            let model = makeModel(defaults: defaults)
            emit("motion-page-open", filmstrip(model, metrics: floating, times: times), sheetIt: false)
            let open = makeModel(defaults: defaults)
            open.expanded = .island
            emit("motion-section-open", filmstrip(open, metrics: floating, times: times, cropTo: 330), sheetIt: false)
        }

        // 6. The live page (real scroll view, measuring, springs) in an off-screen window: open and close sections.
        let (live, problems) = liveCheck(defaults: defaults)
        for (i, shot) in live.enumerated() { emit("live-\(i)", shot, sheetIt: false) }
        for problem in problems { FileHandle.standardError.write(Data("live: \(problem)\n".utf8)) }
        failures += problems.count

        // 7. The entry button (gear in the list header, × in the settings header).
        emit("entry-buttons", image(entryButtons, scale: 3), sheetIt: false)

        // Contact sheet of everything above.
        let small = sheet.compactMap { downscale($0, by: 2) }
        emit("contact-sheet", IslandPreviewRenderer.stitch(small, columns: 4, header: nil), sheetIt: false)
        return failures == 0 ? 0 : 1
    }

    // MARK: Fake data

    private static func makeModel(defaults: UserDefaults) -> SettingsPageModel {
        defaults.dictionaryRepresentation().keys.forEach(defaults.removeObject(forKey:))
        let store = SettingsStore(defaults: defaults, launchAtLogin: .enabled, observeDefaults: false)
        store.values.hotkeyEnabled = true
        store.values.soundVolume = 0.7
        store.values.sounds[.error] = "Basso"
        let home = URL(fileURLWithPath: "/Users/me")
        let hooks = HookSettingsModel(service: nil, reports: [
            .claude: HookReport(status: .installed, existingFiles: [home.appendingPathComponent(".claude/settings.json")]),
            .codex: HookReport(status: .partial(L("хуки без доверия: %@ из %@", 2, 16)),
                               existingFiles: [home.appendingPathComponent(".codex/hooks.json")]),
            .kimi: HookReport(status: .notInstalled, existingFiles: []),
        ])
        let maintenance = SettingsMaintenance(preview: .init(snapshots: 7, files: 12, bytes: 48_200, newest: Date()))
        let model = SettingsPageModel(
            store: store, hooks: hooks, maintenance: maintenance, recorder: HotkeyRecorder(),
            hotkey: .preview(status: .active(.defaultToggle)),
            screens: [ScreenOption(id: "A", name: L10n.shared.language == .ru ? "Встроенный дисплей Retina" : "Built-in Retina Display", isMain: true, hasNotch: true),
                      ScreenOption(id: "B", name: "DELL U2720Q", isMain: false, hasNotch: false)])
        model.systemReduceMotion = { false }
        return model
    }

    // MARK: Live check

    private static func liveCheck(defaults: UserDefaults) -> ([CGImage], [String]) {
        let model = makeModel(defaults: defaults)
        let metrics = floating
        let host = NSHostingView(rootView: SettingsPage(model: model, metrics: metrics, onClose: {})
            .background(Color.black)
            .environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: -40_000, y: -40_000, width: 540, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var shots: [CGImage] = []
        var problems: [String] = []
        var sizes: [CGSize] = []

        func settle(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        }
        func snap(_ label: String) {
            let size = host.fittingSize
            sizes.append(size)
            print("live \(label): page \(Int(size.width))×\(Int(size.height))")
            if size.height > IslandLayout.maxOpenHeight + 0.5 {
                problems.append("\(label): page \(Int(size.height)) pt tall, over \(Int(IslandLayout.maxOpenHeight))")
            }
            window.setContentSize(NSSize(width: size.width, height: size.height))
            settle(0.05)
            let rect = host.bounds
            if let rep = host.bitmapImageRepForCachingDisplay(in: rect) {
                host.cacheDisplay(in: rect, to: rep)
                if let image = rep.cgImage { shots.append(image) }
            }
        }
        func toggle(_ section: SettingsSection) {
            withAnimation(SettingsMotion.expand(reduce: false)) { model.toggle(section) }
            settle(0.9)
        }

        settle(0.6)
        snap("overview")
        toggle(.sounds)
        snap("sounds open")
        toggle(.widgets)
        snap("widgets open (scrolled into view)")
        toggle(.widgets)
        snap("all closed")
        if let first = sizes.first, let last = sizes.last, abs(first.height - last.height) > 0.5 {
            problems.append("closing every section left the page \(Int(last.height)) pt tall (was \(Int(first.height)))")
        }
        // Settings → «Язык · Language» applies live: the same page, nothing rebuilt, must redraw in the other
        // language (every `L(…)` in a body is observed) and come back unchanged.
        let shown = shots.last
        let other: UILanguage = L10n.shared.currentLanguage == .ru ? .en : .ru
        L10n.shared.override(other)
        settle(0.4)
        snap("language → \(other.rawValue)")
        if let shown, let switched = shots.last, Self.sameImage(shown, switched) {
            problems.append("switching the language to \(other.rawValue) did not redraw the page")
        }
        L10n.shared.override(nil)
        settle(0.4)
        snap("language back")
        if let shown, let back = shots.last, !Self.sameImage(shown, back) {
            problems.append("switching the language back did not restore the page")
        }
        return (shots, problems)
    }

    private static func sameImage(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height,
              let da = a.dataProvider?.data, let db = b.dataProvider?.data else { return false }
        return CFEqual(da, db)
    }

    // MARK: Filmstrips

    private static func filmstrip(_ model: SettingsPageModel, metrics: IslandMetrics, times: [Double],
                                  cropTo height: CGFloat? = nil) -> CGImage? {
        let (_, viewport) = measure(model, metrics: metrics)
        let frames: [CGImage] = times.compactMap { t in
            let frame = page(model, metrics: metrics, viewport: viewport)
                .environment(\.islandFilmTime, t)
                .frame(height: height, alignment: .top)
                .clipped()
                .background(Color.black)
                .overlay(alignment: .bottomTrailing) {
                    Text("\(Int((t * 1000).rounded())) мс")
                        .settingsFont(10, .bold)
                        .foregroundStyle(Color.white.opacity(0.6))
                        .padding(6)
                }
            return image(frame, scale: 1)
        }
        return IslandPreviewRenderer.stitch(frames, columns: frames.count, header: nil, spacing: 8, padding: 16)
    }

    // MARK: Composition

    private static func page(_ model: SettingsPageModel, metrics: IslandMetrics, scroll: CGFloat = 0,
                             viewport: CGFloat? = nil) -> some View {
        SettingsPage(model: model, metrics: metrics, staticScroll: scroll, staticViewport: viewport, onClose: {})
            .environment(\.islandStaticRender, true)
    }

    /// The cards' natural height and the viewport the page would use.
    private static func measure(_ model: SettingsPageModel, metrics: IslandMetrics) -> (CGFloat, CGFloat) {
        SectionFrameCollector.shared.frames = [:]
        SectionFrameCollector.shared.contentHeight = nil
        _ = image(page(model, metrics: metrics, viewport: 10), scale: 1)
        let natural = SectionFrameCollector.shared.contentHeight ?? SettingsPage.estimatedContentHeight
        let header: CGFloat = metrics.style == .notch ? metrics.barHeight : 50
        let viewport = min(natural, IslandLayout.maxOpenHeight - header)
        return (natural, viewport)
    }

    /// The page in the island on a desktop, scrolled by `scroll` or so that `scrollTo`'s card is at the top.
    private static func shot(_ model: SettingsPageModel, metrics: IslandMetrics, scroll: CGFloat = 0,
                             scrollTo: SettingsSection? = nil) -> CGImage? {
        let (natural, viewport) = measure(model, metrics: metrics)
        var offset = scroll
        if let scrollTo, let frame = SectionFrameCollector.shared.frames[scrollTo] {
            offset = min(max(0, frame.minY - 6), max(0, natural - viewport))
        }
        let content = page(model, metrics: metrics, scroll: offset, viewport: viewport)
        guard let measured = image(content, scale: 1) else { return nil }
        let size = CGSize(width: measured.width, height: measured.height)
        return image(desktop(content, size: size, metrics: metrics), scale: 2)
    }

    private static func desktop(_ content: some View, size: CGSize, metrics: IslandMetrics) -> some View {
        let ear = IslandLayout.openEar
        let margin: CGFloat = 40
        let width = size.width + 2 * ear + 2 * margin
        let height = size.height + 70
        let silhouette = IslandShape(earRadius: ear, bottomRadius: IslandLayout.openBottom)
        return ZStack(alignment: .top) {
            // A plain, neutral desktop (no colored glow behind the island).
            LinearGradient(colors: [Color(red: 0.36, green: 0.37, blue: 0.39), Color(red: 0.24, green: 0.25, blue: 0.27)],
                           startPoint: .top, endPoint: .bottom)
            // The menu bar strip.
            Rectangle().fill(Color.black.opacity(0.28)).frame(height: metrics.menuBarHeight)
                .frame(maxHeight: .infinity, alignment: .top)
            silhouette
                .fill(Color.black)
                .frame(width: size.width + 2 * ear, height: size.height)
                .shadow(color: .black.opacity(0.55), radius: 22, y: 8)
            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .mask(silhouette.frame(width: size.width + 2 * ear, height: size.height))
        }
        .frame(width: width, height: height)
        .environment(\.colorScheme, .dark)
    }

    private static var entryButtons: some View {
        HStack(spacing: 18) {
            VStack(spacing: 6) {
                SettingsEntryButton(isOpen: false, action: {})
                Text("⚙︎ в списке").settingsFont(9, .semibold).foregroundStyle(IslandPalette.tertiary)
            }
            VStack(spacing: 6) {
                SettingsEntryButton(isOpen: true, action: {})
                Text("× в настройках").settingsFont(9, .semibold).foregroundStyle(IslandPalette.tertiary)
            }
            ForEach(SettingsSection.allCases) { section in
                SettingsIconTile(section: section, size: 28)
            }
        }
        .padding(18)
        .background(Color.black)
        .environment(\.islandStaticRender, true)
    }

    // MARK: Images

    private static func image<V: View>(_ view: V, scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = scale
        return renderer.cgImage
    }

    private static func downscale(_ image: CGImage, by factor: Int) -> CGImage? {
        let width = image.width / factor
        let height = image.height / factor
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// 8-bit sRGB (a render with app icons comes out as 16-bit extended-range, which viewers show washed out).
    private static func normalized(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let flat = normalized(image),
              let png = NSBitmapImageRep(cgImage: flat).representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            print(url.path)
            return true
        } catch {
            FileHandle.standardError.write(Data("failed to write \(url.path): \(error)\n".utf8))
            return false
        }
    }
}
