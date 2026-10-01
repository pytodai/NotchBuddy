import AppKit
import QuartzCore
import SwiftUI
import NotchBuddyCore

/// `NotchBuddy --render-effects <dir>`: renders filmstrips of every effect to PNGs and exits (nothing
/// else starts). Each effect is played by its real layer class on a stand-in island (the real silhouette
/// and a picture of real or mock content), composited frame by frame by `CARenderer` (`FXFilm`).
/// `NOTCHBUDDY_EFFECTS=done,attention` renders only those films (by name prefix).
@MainActor
enum EffectsPreviewRenderer {
    nonisolated static let flag = "--render-effects"

    nonisolated static func requestedDirectory(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        return index + 1 < arguments.count ? arguments[index + 1] : "build/effects"
    }

    static func run(outputDirectory: String) -> Int32 {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot create \(directory.path): \(error)\n".utf8))
            return 1
        }
        NSApp.setActivationPolicy(.accessory)
        let only = ProcessInfo.processInfo.environment["NOTCHBUDDY_EFFECTS"].map {
            $0.split(separator: ",").map(String.init)
        }
        var failures = 0
        for scene in FXScenes.all where only.map({ list in list.contains { scene.name.hasPrefix($0) } }) ?? true {
            guard let sheet = render(scene) else {
                FileHandle.standardError.write(Data("failed to render \(scene.name)\n".utf8))
                failures += 1
                continue
            }
            failures += write(sheet, to: directory.appendingPathComponent("\(scene.name).png")) ? 0 : 1
        }
        if only == nil || only!.contains("live") {
            let problems = EffectsLiveCheck.run()
            for problem in problems { FileHandle.standardError.write(Data("effects-live: \(problem)\n".utf8)) }
            if problems.isEmpty { print("effects-live: wiring OK") }
            failures += problems.count
        }
        return failures == 0 ? 0 : 1
    }

    /// Plays a scene and lays its frames out on a sheet with the title and the time of each frame.
    static func render(_ scene: FXScene) -> CGImage? {
        if let view = scene.view {
            var frames: [(Double, CGImage)] = []
            for t in scene.times {
                let (image, _) = FXMock.image(view(t).padding(18).background(Color(cgColor: scene.background)))
                guard let image else { return nil }
                frames.append((t, image))
            }
            return sheet(scene, frames)
        }
        guard let stage = FXStage(metrics: scene.metrics, background: scene.background) else { return nil }
        let prepare = scene.build(stage)
        var frames: [(Double, CGImage)] = []
        for t in scene.times {
            guard let image = stage.film.frame(at: t, prepare: prepare),
                  let cropped = stage.film.crop(image, scene.crop(stage)) else { return nil }
            frames.append((t, cropped))
        }
        return sheet(scene, frames)
    }

    private static func sheet(_ scene: FXScene, _ frames: [(Double, CGImage)]) -> CGImage? {
        let columns = scene.columns
        let rows = stride(from: 0, to: frames.count, by: columns).map { Array(frames[$0..<min($0 + columns, frames.count)]) }
        let view = VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(scene.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text(scene.note).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { c in
                            let (t, image) = rows[r][c]
                            VStack(alignment: .leading, spacing: 4) {
                                Image(decorative: image, scale: 2)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                Text(String(format: "%.2f s", t))
                                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: max(560, CGFloat(frames.first.map { $0.1.width } ?? 0) / 2 * CGFloat(columns)
                   + CGFloat(columns - 1) * 8 + 40), alignment: .leading)
        .background(Color(white: 0.11))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.cgImage
    }

    static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
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

// MARK: - Stage

/// A canvas like the island panel's, in slot order: `.behind` effects, the island's surface, `.inside`
/// effects, the island's content, `.front` effects.
@MainActor
final class FXStage {
    let metrics: IslandMetrics
    let film: FXFilm
    let canvas: CGRect
    let behind = CALayer()
    let inside = CALayer()
    let front = CALayer()
    private let islandSurface = CALayer()
    private let islandContent = CALayer()
    private(set) var island: FXIslandMock?
    private(set) var effects: [FXLayer] = []

    init?(metrics: IslandMetrics, background: CGColor) {
        self.metrics = metrics
        let size = IslandLayout.canvasSize(metrics)
        canvas = CGRect(origin: .zero, size: size)
        guard let film = FXFilm(size: size, background: background) else { return nil }
        self.film = film
        FX.quietly {
            for l in [behind, islandSurface, inside, islandContent, front] {
                l.frame = canvas
                l.actions = FXLayer.noActions
                film.root.addSublayer(l)
            }
        }
        CATransaction.flush()
    }

    var t0: CFTimeInterval { film.t0 }

    func outline(_ g: IslandGeometry, pulse: IslandPulse = IslandPulse()) -> FXOutline {
        FXOutline(g: g, pulse: pulse, canvasWidth: canvas.width)
    }

    /// Places a stand-in island with `image` (content at its natural size, centered, from the top edge).
    @discardableResult
    func placeIsland(_ g: IslandGeometry, image: CGImage?, contentSize: CGSize) -> FXIslandMock {
        let frame = CGRect(x: canvas.midX - contentSize.width / 2, y: 0, width: contentSize.width, height: contentSize.height)
        let mock = FXIslandMock(outline: outline(g), image: image, contentFrame: frame)
        FX.quietly {
            islandSurface.addSublayer(mock.surface)
            islandContent.addSublayer(mock.content)
            mock.layout(canvas: canvas)
        }
        island = mock
        return mock
    }

    /// Adds an effect layer to its slot, following `outline`.
    @discardableResult
    func add<L: FXLayer>(_ layer: L, following o: FXOutline) -> L {
        FX.quietly {
            layer.frame = canvas
            switch layer.slot {
            case .behind: behind.addSublayer(layer)
            case .inside: inside.addSublayer(layer)
            case .front: front.addSublayer(layer)
            }
            layer.layoutIfNeeded()
            layer.follow(o)
        }
        effects.append(layer)
        return layer
    }

    /// One effect per slot.
    func addAllSlots<L: FXLayer>(_ make: (IslandEffectsSlot) -> L, following o: FXOutline) -> [L] {
        IslandEffectsSlot.allCases.map { add(make($0), following: o) }
    }

    /// Moves the island and every effect to `o` (an island that springs during the film).
    func follow(_ o: FXOutline, contentAlpha: Float = 1, contentOffset: CGFloat = 0) {
        island?.set(o, contentAlpha: contentAlpha, contentOffset: contentOffset)
        for e in effects { e.follow(o) }
    }

    /// Moves the whole scene sideways (the island's error shake moves everything).
    func shift(x: CGFloat) {
        for l in [behind, islandSurface, inside, islandContent, front] {
            l.frame = CGRect(x: x, y: 0, width: canvas.width, height: canvas.height)
        }
    }

    /// Crop around the island: `margin` at the sides, `below` under it.
    func crop(_ o: FXOutline, margin: CGFloat = 56, below: CGFloat = 64, minWidth: CGFloat = 0) -> CGRect {
        let box = o.box
        let width = max(box.width + 2 * margin, minWidth)
        return CGRect(x: canvas.midX - width / 2, y: 0, width: width, height: box.maxY + below).integral
    }
}

// MARK: - Scenes

@MainActor
struct FXScene {
    var name: String
    var title: String
    var note: String
    var metrics: IslandMetrics
    var times: [Double]
    var columns = 4
    var background = CGColor(gray: 0.035, alpha: 1)
    /// Sets the stage up and plays the effect; returns an optional per-frame update (island springs).
    var build: (FXStage) -> ((Double) -> Void)? = { _ in nil }
    var crop: (FXStage) -> CGRect = { $0.canvas }
    /// A SwiftUI effect: the frame at `t`, drawn with `ImageRenderer` (no stage).
    var view: ((Double) -> AnyView)?
}

/// Mock content for the stand-in islands, drawn with the island's own views where they are cheap to
/// build (the notice), and simple SwiftUI stand-ins elsewhere.
@MainActor
enum FXMock {
    static let floating = IslandMetrics(style: .floating, notchWidth: 0,
                                        barHeight: IslandMetrics.floatingBarHeight(menuBar: 30), menuBarHeight: 30)
    static let notched = IslandMetrics(style: .notch, notchWidth: 188, barHeight: 37, menuBarHeight: 37)

    static func image<V: View>(_ view: V) -> (CGImage?, CGSize) {
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, .dark)
            .environment(\.islandStaticRender, true))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return (nil, .zero) }
        return (image, CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }

    /// The "done" notice (the real `FlashView`, resting frame).
    static func notice(_ metrics: IslandMetrics, kind: FlashNotice.Kind = .finished) -> (CGImage?, CGSize) {
        let notice = FlashNotice(key: SessionKey(source: .claude, sessionId: "fx"), kind: kind,
                                 title: kind == .finished ? "Рефакторинг парсера хуков" : "weather-app",
                                 detail: kind == .attention ? "npm run build" : nil)
        return image(FlashView(notice: notice, session: nil, duration: 734, metrics: metrics,
                               width: IslandLayout.flashWidth(metrics), onTap: {}))
    }

    /// Where the notice's badge sits (the check), in canvas points, for a notice of `size`.
    static func noticeBadge(_ metrics: IslandMetrics, canvas: CGRect, size: CGSize) -> CGPoint {
        let left = canvas.midX - size.width / 2
        if metrics.style == .notch {
            // Notch strip: the 22 pt badge 12 pt from the left wing's start.
            return CGPoint(x: left + 12 + 11, y: metrics.barHeight / 2)
        }
        return CGPoint(x: left + 16 + 17, y: size.height / 2 - 0.5)
    }

    /// A closed island row: agent, title, status.
    static func pill(_ metrics: IslandMetrics, status: String, tint: Color, width: CGFloat = 250) -> (CGImage?, CGSize) {
        image(HStack(spacing: 8) {
            AgentMark(source: .claude, size: 20)
            Text("weather-app")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 6)
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(status)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: metrics.barHeight))
    }

    /// A closed island row with an empty 16 pt slot on the left where a celebration draws its check.
    static func pillWithCheckSlot(_ metrics: IslandMetrics, width: CGFloat = 250) -> (CGImage?, CGSize) {
        image(HStack(spacing: 8) {
            Color.clear.frame(width: 16, height: 16)
            Text("weather-app")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 6)
            Text("готово")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SessionStatus.finished.tint)
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: metrics.barHeight))
    }

    /// A permission card stand-in.
    static func card(_ metrics: IslandMetrics) -> (CGImage?, CGSize) {
        let width = IslandLayout.cardWidth(metrics)
        let orange = SessionStatus.waitingForUser.tint
        return image(VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AgentMark(source: .claude, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Выполнить команду").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text("Claude Code · weather-app").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Text("ждёт 0:12").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(orange)
            }
            Text("swift build -c release && ./scripts/build-app.sh")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
            HStack(spacing: 8) {
                Text("Отклонить").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 34)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                Text("Разрешить").font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).frame(height: 34)
                    .background(Capsule().fill(Color.white))
            }
        }
        .padding(.top, metrics.style == .notch ? metrics.barHeight + 8 : 16)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .frame(width: width))
    }

    /// An expanded list stand-in.
    static func list(_ metrics: IslandMetrics) -> (CGImage?, CGSize) {
        let width = IslandLayout.listWidth(metrics)
        let rows: [(String, String, Color)] = [
            ("Рефакторинг парсера хуков", "работает 2:14", SessionStatus.working.tint),
            ("Новый онбординг", "ждёт тебя 0:45", SessionStatus.waitingForUser.tint),
            ("Чистка README", "готово", SessionStatus.finished.tint),
        ]
        return image(VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Сессии").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Image(systemName: "gearshape.fill").foregroundStyle(.white.opacity(0.5))
            }
            .frame(height: 34)
            ForEach(rows.indices, id: \.self) { i in
                let row = rows[i]
                HStack(spacing: 10) {
                    AgentMark(source: [.claude, .codex, .kimi][i], size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                        Text(row.1).font(.system(size: 12)).foregroundStyle(row.2)
                    }
                    Spacer()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
            }
        }
        .padding(.top, metrics.style == .notch ? metrics.barHeight : 6)
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(width: width))
    }

    static func geometry(_ mode: IslandMode, _ metrics: IslandMetrics, _ size: CGSize, hovering: Bool = false) -> IslandGeometry {
        IslandLayout.geometry(mode: mode, metrics: metrics, content: size, hovering: hovering, pressed: false,
                              lastPillWidth: size.width)
    }
}
