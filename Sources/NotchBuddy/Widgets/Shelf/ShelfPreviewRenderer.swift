import AppKit
import NotchBuddyCore
import SwiftUI

/// `NotchBuddy --render-shelf <dir>`: draws the shelf's states to PNGs with real files (made in a scratch
/// folder, thumbnails from Quick Look), then exits. Nothing else starts: no socket, hooks or menu.
///
/// `<dir>/shelf-*.png`: the widget in an open island; `badge-*.png`: the closed island with the shelf's
/// live activity; `settings.png`; `motion/*.png`: filmstrips of the landing, the ghost tile and the badge,
/// sampled from the very curves the live views animate with; `live-shelf.png` and `live-shelf:` lines: the
/// real widget in an off-screen panel driven through the store (`ShelfLiveCheck`). Non-zero exit on a failure.
@MainActor
enum ShelfPreviewRenderer {
    nonisolated static let flag = "--render-shelf"

    /// The whole dispatch for `main.swift`: nil when the flag is absent, else the exit status.
    nonisolated static func runIfRequested(_ arguments: [String]) -> Int32? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let directory = index + 1 < arguments.count ? arguments[index + 1] : "build/shelf-previews"
        return MainActor.assumeIsolated {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            return run(outputDirectory: directory)
        }
    }

    static let width = IslandLayout.listWidth(IslandPreviewRenderer.floating)

    static func run(outputDirectory: String) -> Int32 {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        let motion = directory.appendingPathComponent("motion", isDirectory: true)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchbuddy-shelf-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: motion, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot create \(motion.path): \(error)\n".utf8))
            return 1
        }
        if !ShelfTypography.isAvailable { _ = ShelfTypography.font(12) }
        print("manrope: \(ShelfTypography.isAvailable ? "yes" : "no (system font)")")

        let files = FakeFiles.make(in: scratch)
        let disk = ShelfDisk(directory: scratch.appendingPathComponent("Shelf"), disposal: .delete)
        let all = disk.makeItems(for: files, policy: .never)
        let store = ShelfStore(disk: disk, settings: ShelfSettings(defaults: UserDefaults(suiteName: "nb-shelf-preview")!),
                               persist: false)
        for item in all { store.thumbnails.load(item) }
        store.thumbnails.waitForPending(timeout: 8)

        var failures = 0
        func save(_ name: String, _ image: CGImage?, in folder: URL = directory) {
            failures += write(image, to: folder.appendingPathComponent("\(name).png")) ? 0 : 1
        }
        let six = Array(all.prefix(6))

        // Widget states.
        store.load(preview: [])
        save("shelf-empty", island(ShelfWidgetView(store: store, width: width)))
        store.setDropTarget(true, location: CGPoint(x: 120, y: 100), incoming: 1)
        save("shelf-empty-drop", island(ShelfWidgetView(store: store, width: width).environment(\.shelfPreviewTime, 0.35)))
        store.setDropTarget(false)

        store.load(preview: six)
        save("shelf-items", island(ShelfWidgetView(store: store, width: width)))
        save("shelf-hover", island(ShelfWidgetView(store: store, width: width).environment(\.shelfPreviewHover, 1)))
        save("shelf-confirm-clear", island(ShelfWidgetView(store: store, width: width)
            .environment(\.shelfPreviewConfirmClear, true)))
        store.setDropTarget(true, location: CGPoint(x: 70, y: 110), incoming: 3)
        save("shelf-drop", island(ShelfWidgetView(store: store, width: width).environment(\.shelfPreviewTime, 0.35)))
        store.setDropTarget(false)
        store.load(preview: six, lastAdded: [six[0].id, six[1].id])
        save("shelf-landed", island(ShelfWidgetView(store: store, width: width)))
        store.load(preview: Array(six.prefix(3)), importing: 2)
        save("shelf-importing", island(ShelfWidgetView(store: store, width: width).environment(\.shelfPreviewTime, 0.4)))
        store.load(preview: all)
        save("shelf-many", island(ShelfWidgetView(store: store, width: width)))

        // Closed island: the badge and the drop hint.
        let pictures = six.prefix(3).map { store.thumbnails.thumbnail(for: $0) }
        let badges: [(String, AnyView)] = [
            ("badge-resting", AnyView(ShelfBadgeView(pictures: pictures, count: 6))),
            ("badge-one", AnyView(ShelfBadgeView(pictures: Array(pictures.prefix(1)), count: 1))),
            ("badge-magnet", AnyView(ShelfBadgeView(pictures: pictures, count: 6, proximity: 0.7))),
            ("badge-empty-magnet", AnyView(ShelfBadgeView(pictures: [], count: 0, proximity: 0.6))),
            ("badge-hint-near", AnyView(ShelfDropHint(proximity: 0.5, over: false).environment(\.shelfPreviewTime, 0.2))),
            ("badge-hint-over", AnyView(ShelfDropHint(proximity: 1, over: true, count: 3).environment(\.shelfPreviewTime, 0.2))),
        ]
        for (name, badge) in badges { save(name, closedIsland(badge)) }

        save("settings", panel(ShelfSettingsSection(settings: ShelfSettings(defaults: UserDefaults(suiteName: "nb-shelf-preview")!),
                                                    width: 440)))

        // Filmstrips.
        save("landing", filmstrip(title: "Файл ложится на полку (0–480 мс)", times: stride(from: 0.0, through: 0.48, by: 0.06)) { t in
            AnyView(LandingFrame(items: Array(six.prefix(4)), store: store, t: t))
        }, in: motion)
        save("ghost", filmstrip(title: "Файл над полкой: призрак раздвигает плитки (0–360 мс)", times: stride(from: 0.0, through: 0.36, by: 0.06)) { t in
            AnyView(GhostFrame(items: Array(six.prefix(4)), store: store, t: t))
        }, in: motion)
        save("badge-gulp", filmstrip(title: "Значок полки: файл падает в веер (0–540 мс)", times: stride(from: 0.0, through: 0.54, by: 0.06)) { t in
            AnyView(closedIslandBody(ShelfBadgeView(pictures: pictures, count: 6, addToken: 1)
                .environment(\.shelfBadgeLanding, ShelfMotion.badgeDrop.progress(t))))
        }, in: motion)
        save("badge-magnet", filmstrip(title: "Файл приближается к острову: веер тянется к нему", times: [0, 0.25, 0.5, 0.75, 1]) { p in
            AnyView(closedIslandBody(ShelfBadgeView(pictures: pictures, count: 6, proximity: p)))
        }, in: motion)

        // The real widget in a real panel, through the store's live paths.
        let live = ShelfLiveCheck.run(files: files, scratch: scratch)
        save("live-shelf", live.image)
        for problem in live.problems { FileHandle.standardError.write(Data("live-shelf: \(problem)\n".utf8)) }
        failures += live.problems.count
        return failures == 0 ? 0 : 1
    }

    static func column(_ images: [CGImage]) -> CGImage? {
        IslandPreviewRenderer.stitch(images, columns: 1, header: nil)
    }

    // MARK: Framing

    /// The widget in an open island (floating screen): black silhouette with ears, hanging from a menu bar.
    static func island<V: View>(_ content: V) -> CGImage? {
        let ear = IslandLayout.openEar
        let view = ZStack(alignment: .top) {
            Backdrop()
            VStack(spacing: 0) {
                content
                    .padding(.top, 2)
            }
            .frame(width: width)
            .padding(.horizontal, ear)
            .background(alignment: .top) {
                IslandShape(earRadius: ear, bottomRadius: IslandLayout.openBottom)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(0.55), radius: 22, y: 10)
            }
        }
        .frame(width: width + 2 * ear + 80, height: ShelfWidgetView.height() + 2 + 70, alignment: .top)
        return image(view)
    }

    static func closedIsland<V: View>(_ content: V) -> CGImage? {
        image(ZStack(alignment: .top) {
            Backdrop()
            closedIslandBody(content)
        }
        .frame(width: 360, height: 90, alignment: .top))
    }

    /// A closed, notch-less island: the agent's live activity on the left, the shelf's on the right.
    static func closedIslandBody<V: View>(_ content: V) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color(red: 0.85, green: 0.47, blue: 0.34)).frame(width: 16, height: 16)
            Text("работает 2:14")
                .font(ShelfTypography.font(12, 600))
                .foregroundStyle(Color.white.opacity(0.9))
            Spacer(minLength: 10)
            content
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .frame(minWidth: 250)
        .fixedSize()
        .padding(.horizontal, 11)
        .background(IslandShape(earRadius: 11, bottomRadius: 16).fill(Color.black)
            .shadow(color: .black.opacity(0.5), radius: 12, y: 5))
    }

    static func panel<V: View>(_ content: V) -> CGImage? {
        image(content
            .padding(22)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.black))
            .padding(24)
            .background(Color(white: 0.2)))
    }

    static func filmstrip<S: Sequence>(title: String, times: S, frame: (Double) -> AnyView) -> CGImage? where S.Element == Double {
        let frames = times.compactMap { t -> CGImage? in
            image(VStack(spacing: 6) {
                frame(t)
                Text(String(format: "%.0f мс", t * 1000))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .padding(8)
            .background(Color(white: 0.1)))
        }
        let header = image(Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white))
        return IslandPreviewRenderer.stitch(frames, columns: min(frames.count, 5), header: header)
    }

    static func image<V: View>(_ view: V) -> CGImage? {
        IslandPreviewRenderer.image(view.environment(\.islandStaticRender, true))
    }

    private static func write(_ image: CGImage?, to url: URL) -> Bool {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("failed to render \(url.lastPathComponent)\n".utf8))
            return false
        }
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

/// A wallpaper and a menu bar strip, so the black island reads as it does on screen.
private struct Backdrop: View {
    var body: some View {
        ZStack(alignment: .top) {
            // A calm, photo-like wallpaper in muted natural tones (slate sky over warm gray).
            LinearGradient(colors: [Color(red: 0.34, green: 0.37, blue: 0.41), Color(red: 0.46, green: 0.47, blue: 0.48),
                                    Color(red: 0.55, green: 0.53, blue: 0.5)],
                           startPoint: .top, endPoint: .bottom)
            Color.white.opacity(0.1).frame(height: 30)
        }
    }
}

// MARK: - Film frames

/// A well of tiles where the first one lands at `t` and the others slide right to make room.
private struct LandingFrame: View {
    let items: [ShelfItem]
    let store: ShelfStore
    let t: Double

    var body: some View {
        let p = ShelfMotion.landing.progress(t)
        let reflow = ShelfMotion.reflow.progress(t)
        let step = ShelfTileView.size.width + ShelfWidgetView.tileSpacing
        wellFrame {
            ZStack(alignment: .leading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let tile = ShelfTileView(item: item, thumbnail: store.thumbnails.thumbnail(for: item),
                                             justLanded: false)
                    if index == 0 {
                        tile.overlay(RoundedRectangle(cornerRadius: ShelfTileView.corner, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                                .opacity(t < 0.25 ? 1 : max(0, 1 - (t - 0.25) / ShelfMotion.landingGlow)))
                            .modifier(ShelfLandingEffect(progress: p))
                    } else {
                        tile.offset(x: CGFloat(index - 1) * step + step * CGFloat(reflow))
                    }
                }
            }
        }
    }
}

/// Tiles making room for the ghost tile of a drag over the shelf.
private struct GhostFrame: View {
    let items: [ShelfItem]
    let store: ShelfStore
    let t: Double

    var body: some View {
        let p = ShelfMotion.ghost.progress(t)
        let reflow = ShelfMotion.reflow.progress(t)
        let step = ShelfTileView.size.width + ShelfWidgetView.tileSpacing
        wellFrame(targeted: true, t: t) {
            ZStack(alignment: .leading) {
                ShelfGhostTile(count: 3, time: t)
                    .scaleEffect(0.4 + 0.6 * p)
                    .opacity(min(1, max(0, p) * 1.5))
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    ShelfTileView(item: item, thumbnail: store.thumbnails.thumbnail(for: item))
                        .offset(x: CGFloat(index) * step + step * CGFloat(reflow))
                }
            }
        }
    }
}

@ViewBuilder
private func wellFrame<C: View>(targeted: Bool = false, t: Double = 0, @ViewBuilder _ content: () -> C) -> some View {
    let shape = RoundedRectangle(cornerRadius: ShelfWidgetView.wellCorner, style: .continuous)
    content()
        .padding(ShelfWidgetView.wellPadding)
        .frame(width: 330, height: ShelfWidgetView.wellHeight, alignment: .leading)
        .background(shape.fill(ShelfPalette.well))
        .background(shape.fill(Color.white.opacity(targeted ? 0.03 : 0)))
        .clipShape(shape)
        .overlay {
            if targeted {
                MarchingBorder(cornerRadius: ShelfWidgetView.wellCorner, phase: CGFloat(-t * 22), dash: [8, 6], lineWidth: 1.2)
                    .fill(ShelfPalette.target)
            } else {
                shape.strokeBorder(ShelfPalette.hairline, lineWidth: 0.6)
            }
        }
        .padding(10)
        .background(Color.black)
}

// MARK: - Fake files

/// Real files with real content, so Quick Look draws real thumbnails.
private enum FakeFiles {
    static func make(in folder: URL, english: Bool = false) -> [URL] {
        var urls: [URL] = []
        func add(_ name: String, _ data: Data?) {
            let url = folder.appendingPathComponent(name)
            if let data, (try? data.write(to: url)) != nil { urls.append(url) }
        }
        add(english ? "Screenshot 2026-09-30 at 10.42.18.png" : "Снимок экрана 2026-09-30 в 10.42.18.png",
            png(width: 1440, height: 900, draw: drawScreenshot))
        add(english ? "Sunset over the bay.jpg" : "Закат над заливом.jpg", jpeg(width: 1200, height: 1600, draw: drawSunset))
        add(english ? "Forecast redesign.pdf" : "Редизайн прогноза.pdf",
            pdf(title: english ? "Forecast redesign" : "Редизайн прогноза"))
        add("ForecastChart.swift", Data(swiftSource.utf8))
        let assets = folder.appendingPathComponent(english ? "App icons" : "Иконки приложения", isDirectory: true)
        try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        for i in 1...7 { try? Data([UInt8(i)]).write(to: assets.appendingPathComponent("icon-\(i).png")) }
        urls.append(assets)
        add("build-logs.zip", zipData())
        add("README.md", Data("# Weather\n\nПрогноз погоды на неделю: температура, осадки, ветер.\n".utf8))
        add("Палитра.png", png(width: 800, height: 800, draw: drawPalette))
        add("notes.txt", Data(String(repeating: "Заметки к релизу.\n", count: 40).utf8))
        add("Промо.png", png(width: 1600, height: 900, draw: drawPromo))
        add("Договор аренды.pdf", pdf(title: "Договор аренды"))
        add("data.json", Data("{\"island\": true, \"shelf\": [1, 2, 3]}".utf8))
        return urls
    }

    private static func bitmap(width: Int, height: Int, draw: (CGContext, CGSize) -> Void) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(context.cgContext, CGSize(width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func png(width: Int, height: Int, draw: (CGContext, CGSize) -> Void) -> Data? {
        bitmap(width: width, height: height, draw: draw)?.representation(using: .png, properties: [:])
    }

    private static func jpeg(width: Int, height: Int, draw: (CGContext, CGSize) -> Void) -> Data? {
        bitmap(width: width, height: height, draw: draw)?.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private static func gradient(_ c: CGContext, _ colors: [NSColor], from: CGPoint, to: CGPoint) {
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray,
                           locations: nil)!
        c.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func drawScreenshot(_ c: CGContext, _ s: CGSize) {
        // A muted landscape wallpaper: warm gray ground under a pale slate sky.
        gradient(c, [NSColor(red: 0.42, green: 0.40, blue: 0.36, alpha: 1), NSColor(red: 0.58, green: 0.60, blue: 0.62, alpha: 1),
                     NSColor(red: 0.70, green: 0.74, blue: 0.78, alpha: 1)],
                 from: .zero, to: CGPoint(x: 0, y: s.height))
        // A window with a sidebar and text lines.
        let window = CGRect(x: 180, y: 120, width: 1080, height: 660)
        c.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor)
        c.addPath(CGPath(roundedRect: window, cornerWidth: 22, cornerHeight: 22, transform: nil))
        c.fillPath()
        c.setFillColor(NSColor(white: 0.9, alpha: 1).cgColor)
        c.fill(CGRect(x: window.minX, y: window.minY, width: 260, height: window.height - 40))
        c.setFillColor(NSColor(white: 0.86, alpha: 1).cgColor)
        c.fill(CGRect(x: window.minX, y: window.maxY - 44, width: window.width, height: 44))
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFillColor(color.cgColor)
            c.fillEllipse(in: CGRect(x: window.minX + 22 + CGFloat(i) * 26, y: window.maxY - 30, width: 16, height: 16))
        }
        for row in 0..<9 {
            c.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor)
            let w = CGFloat([620, 540, 700, 480, 660, 300, 590, 640, 420][row])
            c.fill(CGRect(x: window.minX + 310, y: window.maxY - 110 - CGFloat(row) * 56, width: w, height: 18))
        }
        c.setFillColor(NSColor(white: 0.22, alpha: 1).cgColor)
        c.addPath(CGPath(roundedRect: CGRect(x: window.minX + 310, y: window.minY + 40, width: 200, height: 54),
                         cornerWidth: 12, cornerHeight: 12, transform: nil))
        c.fillPath()
    }

    /// A quiet dusk over a bay in natural, photo-like colors: pale slate sky warming toward the horizon, a
    /// soft low sun, gray-blue water with a faint glitter, a dark wooded headland.
    private static func drawSunset(_ c: CGContext, _ s: CGSize) {
        let horizon = s.height * 0.42
        // Sky.
        c.saveGState()
        c.clip(to: CGRect(x: 0, y: horizon, width: s.width, height: s.height - horizon))
        gradient(c, [NSColor(red: 0.47, green: 0.55, blue: 0.64, alpha: 1), NSColor(red: 0.72, green: 0.73, blue: 0.74, alpha: 1),
                     NSColor(red: 0.90, green: 0.80, blue: 0.68, alpha: 1)],
                 from: CGPoint(x: 0, y: s.height), to: CGPoint(x: 0, y: horizon))
        // A soft haze around a pale sun, low on the horizon.
        let sun = s.width * 0.16
        let center = CGPoint(x: s.width * 0.6, y: horizon + sun * 0.55)
        let haze = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [NSColor(red: 1, green: 0.93, blue: 0.82, alpha: 0.55).cgColor,
                                       NSColor(red: 1, green: 0.93, blue: 0.82, alpha: 0).cgColor] as CFArray, locations: nil)!
        c.drawRadialGradient(haze, startCenter: center, startRadius: 0, endCenter: center, endRadius: sun * 2.6, options: [])
        c.setFillColor(NSColor(red: 1.0, green: 0.95, blue: 0.86, alpha: 1).cgColor)
        c.fillEllipse(in: CGRect(x: center.x - sun / 2, y: center.y - sun / 2, width: sun, height: sun))
        c.restoreGState()
        // Water with a faint, broken reflection.
        c.saveGState()
        c.clip(to: CGRect(x: 0, y: 0, width: s.width, height: horizon))
        gradient(c, [NSColor(red: 0.56, green: 0.60, blue: 0.64, alpha: 1), NSColor(red: 0.24, green: 0.29, blue: 0.34, alpha: 1)],
                 from: CGPoint(x: 0, y: horizon), to: .zero)
        let widths: [CGFloat] = [0.2, 0.14, 0.17, 0.09, 0.12, 0.06, 0.08, 0.04, 0.05, 0.03]
        for (i, w) in widths.enumerated() {
            c.setFillColor(NSColor(red: 1, green: 0.94, blue: 0.84, alpha: 0.32 - CGFloat(i) * 0.025).cgColor)
            let y = horizon - 14 - CGFloat(i) * 30
            let jitter = CGFloat([0, 14, -10, 8, -6, 12, -4, 6, -8, 2][i])
            c.fill(CGRect(x: center.x - s.width * w / 2 + jitter, y: y, width: s.width * w, height: 4))
        }
        c.restoreGState()
        // A wooded headland on the left.
        c.setFillColor(NSColor(red: 0.16, green: 0.18, blue: 0.17, alpha: 1).cgColor)
        c.move(to: CGPoint(x: 0, y: horizon - 6))
        c.addCurve(to: CGPoint(x: s.width * 0.46, y: horizon - 6), control1: CGPoint(x: s.width * 0.12, y: horizon + 110),
                   control2: CGPoint(x: s.width * 0.3, y: horizon + 40))
        c.addLine(to: CGPoint(x: 0, y: horizon - 6))
        c.fillPath()
    }

    private static func drawPalette(_ c: CGContext, _ s: CGSize) {
        c.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor)
        c.fill(CGRect(origin: .zero, size: s))
        // Earthy, natural swatches (stone, sand, clay, moss, slate…), not saturated system hues.
        let colors: [NSColor] = [(0.80, 0.76, 0.69), (0.66, 0.55, 0.44), (0.55, 0.40, 0.33), (0.47, 0.51, 0.40),
                                 (0.36, 0.42, 0.37), (0.45, 0.52, 0.58), (0.30, 0.35, 0.42), (0.72, 0.67, 0.60),
                                 (0.24, 0.23, 0.22)].map { NSColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
        for (i, color) in colors.enumerated() {
            c.setFillColor(color.cgColor)
            let x = CGFloat(i % 3) * 250 + 40, y = CGFloat(i / 3) * 250 + 40
            c.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: 220, height: 220), cornerWidth: 40, cornerHeight: 40,
                             transform: nil))
            c.fillPath()
        }
    }

    private static func drawPromo(_ c: CGContext, _ s: CGSize) {
        gradient(c, [NSColor(white: 0.16, alpha: 1), NSColor(white: 0.3, alpha: 1)],
                 from: CGPoint(x: 0, y: s.height), to: .zero)
        c.setFillColor(NSColor.black.cgColor)
        let island = CGRect(x: s.width / 2 - 360, y: s.height - 300, width: 720, height: 300)
        c.addPath(CGPath(roundedRect: island, cornerWidth: 80, cornerHeight: 80, transform: nil))
        c.fillPath()
        c.setFillColor(NSColor(white: 0.26, alpha: 1).cgColor)
        for i in 0..<5 {
            c.addPath(CGPath(roundedRect: CGRect(x: island.minX + 60 + CGFloat(i) * 124, y: island.minY + 70, width: 104,
                                                 height: 120), cornerWidth: 18, cornerHeight: 18, transform: nil))
        }
        c.fillPath()
    }

    private static func pdf(title text: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let c = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        c.beginPDFPage(nil)
        let ns = NSGraphicsContext(cgContext: c, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let title = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: NSColor.black])
        title.draw(at: CGPoint(x: 56, y: 760))
        c.setFillColor(NSColor(white: 0.25, alpha: 1).cgColor)
        c.fill(CGRect(x: 56, y: 740, width: 120, height: 5))
        for i in 0..<22 {
            c.setFillColor(NSColor(white: 0.72, alpha: 1).cgColor)
            c.fill(CGRect(x: 56, y: 700 - CGFloat(i) * 26, width: CGFloat([470, 440, 480, 300][i % 4]), height: 9))
        }
        c.setFillColor(NSColor(white: 0.1, alpha: 1).cgColor)
        c.addPath(CGPath(roundedRect: CGRect(x: 56, y: 60, width: 483, height: 60), cornerWidth: 14, cornerHeight: 14, transform: nil))
        c.fillPath()
        NSGraphicsContext.restoreGraphicsState()
        c.endPDFPage()
        c.closePDF()
        return data as Data
    }

    /// An empty but valid zip archive (22-byte end-of-central-directory record) padded with a stored note.
    private static func zipData() -> Data {
        var bytes: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        bytes += [UInt8](repeating: 0, count: 18)
        return Data(bytes) + Data(repeating: 0, count: 2_400_000)
    }

    private static let swiftSource = """
    import SwiftUI
    import Charts

    /// The week's temperatures as a smooth line.
    struct ForecastChart: View {
        let days: [DayForecast]
        var body: some View {
            Chart(days) { LineMark(x: .value("Day", $0.date), y: .value("°C", $0.high)) }
                .chartYAxis(.hidden)
        }
    }
    """
}

extension ShelfPreviewRenderer {
    /// A shelf holding real sample files (written into `folder`) with their thumbnails, for the island's widget films.
    /// `english`: English file names (the promo film's English cut).
    static func sampleShelf(in folder: URL, english: Bool = false) -> ShelfWidget {
        let files = FakeFiles.make(in: folder, english: english)
        let disk = ShelfDisk(directory: folder.appendingPathComponent("Shelf"), disposal: .delete)
        let all = disk.makeItems(for: files, policy: .never)
        let settings = ShelfSettings(defaults: UserDefaults(suiteName: "nb-shelf-preview")!)
        let store = ShelfStore(disk: disk, settings: settings, persist: false)
        for item in all { store.thumbnails.load(item) }
        store.thumbnails.waitForPending(timeout: 8)
        store.load(preview: Array(all.prefix(6)))
        return ShelfWidget(settings: settings, store: store)
    }
}

extension ShelfPreviewRenderer {
    /// The sample files themselves (real content, written into `folder`), for films that set up their own shelf.
    static func sampleFiles(in folder: URL, english: Bool = false) -> [URL] {
        FakeFiles.make(in: folder, english: english)
    }
}
