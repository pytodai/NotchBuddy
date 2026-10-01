import AppKit
import ImageIO
import NotchBuddyCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

// The promo's shelf scene: a photo is dragged from a Finder window onto the island, which opens into the shelf and
// takes it; then the photo is dragged out of the shelf into a Mail message.
//
// The shelf's page is the real widget's layout built from its real parts (header, well, tiles, ghost tile, marching
// border, landing effect, the motion curves of `ShelfMotion`), with every motion a function of the film's story clock:
// a film render never ticks SwiftUI's own animations (`IslandPageRoot` turns them off), so the live widget's
// transitions would land in one frame. The files are real (the shelf previews' sample files, thumbnails from Quick Look).

// MARK: - The desk (the external monitor's desktop)

/// Where the desktop's windows sit on the monitor's screen (points of the 1512 × 850.5 virtual screen), and the spots
/// the cursor aims at. Left of the open island: Finder (Downloads); right of it: a Mail message being written.
enum PromoDesk {
    static let finder = CGRect(x: 110, y: 158, width: 320, height: 232)
    static let mail = CGRect(x: 1082, y: 150, width: 320, height: 250)
    /// The window art's margin for its shadow (points on each side).
    static let shadowPad: CGFloat = 34

    // Finder's layout (window points).
    static let toolbar: CGFloat = 46
    static let sidebar: CGFloat = 100
    static let cell = CGSize(width: 70, height: 84)
    static let columns = 3
    static let iconBox: CGFloat = 48
    /// The grid's top-left in the window.
    static var grid: CGPoint {
        CGPoint(x: sidebar + (finder.width - sidebar - CGFloat(columns) * cell.width) / 2, y: toolbar + 8)
    }

    /// The icon at `index` of the Finder grid, in window points.
    static func iconRect(_ index: Int) -> CGRect {
        let col = index % columns, row = index / columns
        let x = grid.x + CGFloat(col) * cell.width + (cell.width - iconBox) / 2
        let y = grid.y + CGFloat(row) * cell.height + 4
        return CGRect(x: x, y: y, width: iconBox, height: iconBox)
    }

    /// The dragged photo's place in the Finder grid.
    static let photoIndex = 1

    /// The photo's icon on the screen.
    static var photoIcon: CGRect { iconRect(photoIndex).offsetBy(dx: finder.minX, dy: finder.minY) }

    // Mail's layout (window points).
    static let mailFieldHeight: CGFloat = 30
    /// Where the attachment goes in the message (window points): under the greeting.
    static let attachment = CGRect(x: 18, y: 148, width: 147, height: 98)
    static var attachmentOnScreen: CGRect { attachment.offsetBy(dx: mail.minX, dy: mail.minY) }
}

// MARK: - State

/// The shelf scene's state: the files, and when each step of it happens (story seconds). Set by the storyboard's
/// `.shelf` beats; `now` and `pointer` are set every frame. The film's shelf page draws from it.
@MainActor
@Observable
final class PromoShelfFilm {
    /// The render's shelf scene (made once per render, before the first frame).
    static var shared: PromoShelfFilm?

    @ObservationIgnored let widget: ShelfWidget
    /// On the shelf before the drop, newest first.
    @ObservationIgnored let resting: [ShelfItem]
    /// The photo that is dragged in (and out again).
    @ObservationIgnored let photo: ShelfItem
    /// What the Finder window shows (the photo at `PromoDesk.photoIndex`).
    @ObservationIgnored let finder: [ShelfItem]
    var store: ShelfStore { widget.store }

    /// Story seconds of the frame being filmed.
    var now: Double = 0
    /// The pointer in the shelf page's coordinates (its content's top-left), for the drop glow.
    var pointer: CGPoint?
    /// The drop target lights (a file dragged over the island).
    var targetAt: Double?
    /// The file is let go over the shelf: it lands.
    var dropAt: Double?
    /// The pointer rests on the landed tile: it lifts.
    var liftAt: Double?
    /// The landed tile is dragged out (it stays behind as a faint ghost, as in Finder).
    var outAt: Double?
    /// The drag out ended.
    var outEndAt: Double?

    private init(widget: ShelfWidget, resting: [ShelfItem], photo: ShelfItem, finder: [ShelfItem]) {
        self.widget = widget
        self.resting = resting
        self.photo = photo
        self.finder = finder
    }

    /// Writes the sample files into a scratch folder (the photo cropped to landscape, so it sits well in a tile and in
    /// a message), makes their items and thumbnails, and puts three of them on a shelf.
    static func make(lang: PromoLanguage) -> PromoShelfFilm {
        let english = lang == .en
        // One folder per process: the master's chunks render side by side.
        let scratch = scratchFolder
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let urls = ShelfPreviewRenderer.sampleFiles(in: scratch, english: english)
        let photoName = english ? "Sunset over the bay.jpg" : "Закат над заливом.jpg"
        if let url = urls.first(where: { $0.lastPathComponent == photoName }) { landscape(url) }
        let disk = ShelfDisk(directory: scratch.appendingPathComponent("Shelf"), disposal: .delete)
        let all = disk.makeItems(for: urls, policy: .never)
        let settings = ShelfSettings(defaults: UserDefaults(suiteName: "nb-shelf-preview")!)
        let store = ShelfStore(disk: disk, settings: settings, persist: false)
        for item in all { store.thumbnails.load(item) }
        store.thumbnails.waitForPending(timeout: 8)
        func item(_ name: String) -> ShelfItem? { all.first { $0.name == name } }
        let photo = item(photoName) ?? all[0]
        let resting = [english ? "Forecast redesign.pdf" : "Редизайн прогноза.pdf",
                       english ? "Screenshot 2026-09-30 at 10.42.18.png" : "Снимок экрана 2026-09-30 в 10.42.18.png",
                       "ForecastChart.swift"].compactMap(item)
        let others = [english ? "App icons" : "Иконки приложения", "build-logs.zip", "README.md", "notes.txt", "data.json"]
            .compactMap(item)
        var finder = others
        finder.insert(photo, at: min(PromoDesk.photoIndex, finder.count))
        store.load(preview: resting)
        return PromoShelfFilm(widget: ShelfWidget(settings: settings, store: store), resting: resting, photo: photo,
                              finder: Array(finder.prefix(6)))
    }

    private static var scratchFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "notchbuddy-promo-shelf-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    /// Removes the scene's files (at the end of a render).
    static func cleanUp() {
        try? FileManager.default.removeItem(at: scratchFolder)
    }

    /// Crops the sample photo (a portrait dusk over a bay) to a 3:2 landscape around its horizon and sun.
    private static func landscape(_ url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let w = image.width, h = w * 2 / 3
        // The horizon is 42 % up from the bottom; keep it a little below the middle, the low sun above it.
        let top = max(0, min(image.height - h, Int(Double(image.height) * 0.58) - h * 3 / 5))
        guard let crop = image.cropping(to: CGRect(x: 0, y: top, width: w, height: h)),
              let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(out, crop, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(out)
    }

    func thumbnail(_ item: ShelfItem) -> ShelfThumbnail? { store.thumbnails.thumbnail(for: item) }

    // MARK: Levels at `now`

    /// The drop target's light, 0…1.
    var lit: Double {
        guard let targetAt, now >= targetAt else { return 0 }
        guard let dropAt, now >= dropAt else { return 1 }
        return clamp(1 - ShelfMotion.target.progress(now - dropAt))
    }

    /// Seconds the drop target has been lit (its dashes march, the tray's arrow bobs).
    var targetTime: Double { max(0, now - (targetAt ?? now)) }

    /// The header's switch from the summary to the drop prompt (`in`) and back to the new summary (`out`), springs.
    var promptIn: Double { targetAt.map { now >= $0 ? 1 : 0 } ?? 0 }
    var promptOut: Double { dropAt.map { ShelfMotion.target.progress(now - $0) } ?? 0 }

    var landed: Bool { dropAt.map { now >= $0 } ?? false }
    /// The landing tile's progress (the landing spring, overshooting a touch).
    var landing: Double { dropAt.map { ShelfMotion.landing.progress(now - $0) } ?? 0 }
    /// The landed tile's white outline, fading once (`ShelfTileView.landed`).
    var landingGlow: Double {
        guard let dropAt else { return 0 }
        let d = now - dropAt
        if d < 0.25 { return 1 }
        let x = clamp((d - 0.25) / ShelfMotion.landingGlow)
        return 1 - (1 - pow(1 - x, 2))  // ease out
    }
    /// The ghost tile leaving as the file lands (scale and fade, 0.12 s ease-out).
    var ghostOut: Double { dropAt.map { 1 - pow(1 - clamp((now - $0) / 0.12), 2) } ?? 0 }

    /// The landed tile lifted under the pointer (the tile's hover), 0…1.
    var lift: Double {
        guard let liftAt, now >= liftAt else { return 0 }
        let up = ShelfMotion.hover.progress(now - liftAt)
        guard let outAt, now >= outAt else { return up }
        let held = ShelfMotion.hover.progress(outAt - liftAt)
        return held * (1 - ShelfMotion.hover.progress(now - outAt))
    }

    /// The press that starts the drag out: the tile dips a little and comes back.
    var press: Double {
        guard let outAt else { return 0 }
        let d = now - outAt + 0.14
        guard d > 0, d < 0.32 else { return 0 }
        return sin(.pi * d / 0.32)
    }

    /// The tile's opacity while its file is dragged out (a faint ghost stays behind).
    var tileOpacity: Double {
        guard let outAt, now >= outAt else { return 1 }
        let fade = 1 - pow(1 - clamp((now - outAt) / 0.16), 2)
        var o = 1 - 0.6 * fade
        if let outEndAt, now >= outEndAt {
            o += (1 - o) * (1 - pow(1 - clamp((now - outEndAt) / 0.2), 2))
        }
        return o
    }

    private func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
}

// MARK: - The page

/// The shelf's page in the film (registered over the widget's own page id): the strip's room, then the widget.
struct PromoShelfPage: View {
    let state: IslandViewState
    let width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: IslandTabs.headerBlock(state.metrics))
            if let film = PromoShelfFilm.shared {
                PromoShelfWidget(film: film, width: width, headerBlock: IslandTabs.headerBlock(state.metrics))
            }
        }
        .frame(width: width)
    }
}

/// `ShelfWidgetView`'s layout and parts, driven by the film's clock.
private struct PromoShelfWidget: View {
    let film: PromoShelfFilm
    let width: CGFloat
    let headerBlock: CGFloat

    private typealias V = ShelfWidgetView

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: V.headerHeight)
                .appearAfter(0.02, style: .header)
            well
                .padding(.horizontal, V.sidePadding)
                .padding(.bottom, 10)
                .appearAfter(0.05, style: .section)
        }
        .frame(width: width, height: V.height(), alignment: .top)
    }

    private var items: [ShelfItem] { film.landed ? [film.photo] + film.resting : film.resting }

    // MARK: Header

    private var header: some View {
        let lit = film.lit
        let t = film.targetTime
        let before = ShelfFormat.summary(ShelfCatalog(items: film.resting))
        let after = ShelfFormat.summary(ShelfCatalog(items: [film.photo] + film.resting))
        let promptIn = film.promptIn, promptOut = film.promptOut
        let prompt = promptIn * (1 - promptOut)
        return HStack(spacing: 8) {
            ShelfTrayGlyph(size: 18, arrow: CGFloat(0.5 + lit * (0.05 + 0.45 * sin(t * 2 * .pi / 0.9))), open: CGFloat(lit))
                .frame(width: 18, height: 18)
            Text(L("Полка"))
                .font(ShelfTypography.font(13.5, 680))
                .foregroundStyle(ShelfPalette.primary)
            ZStack(alignment: .leading) {
                // The resting summary gives way to the prompt (in from below), which gives way to the new count (in
                // from above), as the live header's transitions do.
                Text(before)
                    .foregroundStyle(ShelfPalette.tertiary)
                    .opacity(1 - promptIn)
                Text(L("Отпусти — положу на полку"))
                    .foregroundStyle(ShelfPalette.primary)
                    .opacity(min(max(prompt, 0), 1))
                    .offset(y: CGFloat(-8 * promptOut))
                Text(after)
                    .foregroundStyle(ShelfPalette.tertiary)
                    .opacity(min(max(promptOut, 0), 1))
                    .offset(y: CGFloat(-8 * (1 - promptOut)))
            }
            .font(ShelfTypography.digits(11.5, 560))
            .lineLimit(1)
            Spacer(minLength: 8)
            ShelfGlyph(kind: .reveal).icon(13, ShelfPalette.secondary, weight: 1.4)
                .frame(width: 26, height: 24)
            Text(L("Очистить"))
                .font(ShelfTypography.font(11.5, 650))
                .foregroundStyle(ShelfPalette.secondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.6))
        }
        .padding(.leading, V.textInset - 2)
        .padding(.trailing, 14)
    }

    // MARK: Well

    private var well: some View {
        let shape = RoundedRectangle(cornerRadius: V.wellCorner, style: .continuous)
        let lit = film.lit
        return ZStack(alignment: .topLeading) {
            shape.fill(ShelfPalette.well)
            glow.clipShape(shape).opacity(lit)
            tiles
                .frame(width: width - 2 * V.sidePadding, height: V.wellHeight, alignment: .topLeading)
                .clipShape(shape)
        }
        .frame(width: width - 2 * V.sidePadding, height: V.wellHeight)
        .overlay {
            ZStack {
                shape.strokeBorder(ShelfPalette.hairline, lineWidth: 0.6).opacity(1 - lit)
                MarchingBorder(cornerRadius: V.wellCorner, phase: CGFloat(-film.targetTime * 22), dash: [8, 6], lineWidth: 1.2)
                    .fill(ShelfPalette.target)
                    .opacity(lit)
            }
        }
    }

    /// A faint neutral light under the dragged file, following the pointer across the well.
    private var glow: some View {
        GeometryReader { geo in
            let p = film.pointer.map { CGPoint(x: $0.x - V.sidePadding, y: $0.y - headerBlock - V.headerHeight) }
                ?? CGPoint(x: geo.size.width * 0.2, y: geo.size.height / 2)
            ZStack {
                Color.white.opacity(0.03)
                RadialGradient(colors: [Color.white.opacity(0.07), .clear],
                               center: UnitPoint(x: p.x / max(geo.size.width, 1), y: p.y / max(geo.size.height, 1)),
                               startRadius: 0, endRadius: 190)
            }
        }
    }

    private var tiles: some View {
        let step = ShelfTileView.size.width + V.tileSpacing
        let resting = film.resting
        return ZStack(alignment: .topLeading) {
            // Before the drop the ghost tile holds the front slot ("Here"); the file lands in it as the ghost leaves.
            if !film.landed || film.ghostOut < 1 {
                let out = film.ghostOut
                ShelfGhostTile(count: 1, time: film.targetTime)
                    .scaleEffect(CGFloat(1 - 0.4 * out))
                    .opacity((1 - out) * min(1, film.lit * 4))
                    .offset(x: V.wellPadding, y: V.wellPadding)
            }
            if film.landed {
                landedTile
                    .offset(x: V.wellPadding, y: V.wellPadding)
            }
            ForEach(Array(resting.enumerated()), id: \.element.id) { index, item in
                ShelfTileView(item: item, thumbnail: film.thumbnail(item))
                    .offset(x: V.wellPadding + CGFloat(index + 1) * step, y: V.wellPadding)
            }
        }
    }

    /// The photo's tile: it lands (`ShelfLandingEffect`), glows once, lifts under the pointer and is dragged out.
    private var landedTile: some View {
        let shape = RoundedRectangle(cornerRadius: ShelfTileView.corner, style: .continuous)
        let glow = film.landingGlow
        let lift = CGFloat(film.lift)
        return ShelfTileView(item: film.photo, thumbnail: film.thumbnail(film.photo))
            .overlay {
                // The landing outline, and the hover's brighter fill and edge (`ShelfTileView`'s own looks).
                shape.fill(Color.white.opacity(0.05 * glow + 0.045 * Double(lift)))
                shape.strokeBorder(Color.white.opacity(0.07 * Double(lift)), lineWidth: 0.6)
                shape.strokeBorder(Color.white.opacity(0.5), lineWidth: 1).opacity(glow)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.55 * Double(lift)), radius: 10 * lift, y: 5 * lift)
            .scaleEffect(1 + 0.035 * lift - 0.04 * CGFloat(film.press))
            .offset(y: -2 * lift)
            .opacity(film.tileOpacity)
            .modifier(ShelfLandingEffect(progress: film.landing))
    }
}

// MARK: - The file under the cursor

/// The dragged file's picture under the cursor (the drag image), in story time: it appears as a drag starts, follows
/// the cursor, and either melts into the shelf (`drop`) or settles into the message as its attachment (`attach`).
struct PromoCarryTrack {
    enum Event: Equatable {
        case lift
        case drop(CGPoint)
        case attach(CGPoint)
    }

    private(set) var events: [(at: Double, event: Event)] = []

    struct State {
        var center: CGPoint
        /// The picture's size (points).
        var size: CGSize
        var opacity: Float
        /// 1: the drag image's soft shadow; 0: none (settled in the message).
        var lifted: CGFloat
    }

    /// The drag image's size: the picture fit in 64 points (`ShelfDragSource`).
    static func dragSize(aspect: CGFloat) -> CGSize {
        aspect >= 1 ? CGSize(width: 64, height: 64 / aspect) : CGSize(width: 64 * aspect, height: 64)
    }

    mutating func add(_ event: Event, at t: Double) { events.append((t, event)) }

    func state(at t: Double, cursor: CGPoint, aspect: CGFloat) -> State? {
        guard let last = events.last(where: { $0.at <= t }) else { return nil }
        let small = Self.dragSize(aspect: aspect)
        let d = t - last.at
        switch last.event {
        case .lift:
            let p = PromoEase.smooth(d / 0.14)
            return State(center: cursor, size: small, opacity: Float(0.85 * p), lifted: 1)
        case .drop(let at):
            guard d < 0.2 else { return nil }
            let q = PromoEase.smooth(d / 0.2)
            let s = 1 - 0.12 * CGFloat(q)
            return State(center: at, size: CGSize(width: small.width * s, height: small.height * s),
                         opacity: Float(0.85 * (1 - q)), lifted: 1)
        case .attach(let at):
            let p = CGFloat(PromoEase.smoother(d / 0.5))
            let slot = PromoDesk.attachmentOnScreen
            let center = CGPoint(x: at.x + (slot.midX - at.x) * p, y: at.y + (slot.midY - at.y) * p)
            // Log-space size, so it grows evenly.
            let k = Double(slot.width / small.width)
            let s = CGFloat(pow(k, Double(p)))
            return State(center: center, size: CGSize(width: small.width * s, height: small.height * s),
                         opacity: Float(0.85 + 0.15 * Double(p)), lifted: 1 - p)
        }
    }
}
