import AppKit
import NotchBuddyCore
import SwiftUI

/// `NotchBuddy --render-music <dir>`: the music widget's states and its motion, drawn with fake tracks
/// and procedurally painted covers to PNGs, then exit. Nothing else starts (no player is contacted).
@MainActor
enum MusicPreviewRenderer {
    nonisolated static let flag = "--render-music"

    nonisolated static func requestedDirectory(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        return index + 1 < arguments.count ? arguments[index + 1] : "build/music-previews"
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
        if !MusicFont.isAvailable { FileHandle.standardError.write(Data("warning: Manrope not found, system font used\n".utf8)) }
        let fake = Fake()
        var failures = 0
        func write(_ name: String, _ image: CGImage?) {
            failures += save(image, to: directory.appendingPathComponent("\(name).png")) ? 0 : 1
        }
        let width = IslandLayout.listWidth(floating) - 28

        write("widget-states", sheet(onIsland: true, [
            ("Играет · Spotify", AnyView(MusicWidgetView(model: fake.playing, width: width))),
            ("На паузе · Музыка", AnyView(MusicWidgetView(model: fake.paused, width: width))),
            ("Курсор на полосе, перемотка на 63 % · длинное название гаснет у края",
             AnyView(MusicWidgetView(model: fake.long, width: width, previewHover: true, previewScrub: 0.63))),
            ("Без обложки (нет доступа к Автоматизации): серый квадрат с нотой, позиция неизвестна",
             AnyView(MusicWidgetView(model: fake.placeholder, width: width))),
            ("Управление запрещено: подсказка, где разрешить", AnyView(MusicWidgetView(model: fake.blocked, width: width))),
            ("Радио: без длительности", AnyView(MusicWidgetView(model: fake.radio, width: width))),
            ("Ничего не играет", AnyView(MusicWidgetView(model: fake.empty, width: width))),
            ("Ничего не играет, Spotify запущен", AnyView(MusicWidgetView(model: fake.emptyRunning, width: width))),
        ], columns: 2))

        for (suffix, metrics) in [("floating", floating), ("notch", notched)] {
            let listWidth = IslandLayout.listWidth(metrics)
            write("island-expanded-\(suffix)", island(metrics: metrics, content: AnyView(
                MusicWidgetView(model: fake.playing, width: listWidth - 28)
                    .padding(.horizontal, 14)
                    .padding(.top, metrics.style == .notch ? metrics.barHeight + 8 : 12)
                    .padding(.bottom, 14)), open: true))
            write("island-live-activity-\(suffix)", sheet(onIsland: false, [
                ("Играет", island(metrics: metrics, content: AnyView(MusicLiveActivityView(model: fake.playing, metrics: metrics)),
                                  open: false)),
                ("На паузе (эквалайзер оседает в точки, обложка чуть отступает)",
                 island(metrics: metrics, content: AnyView(MusicLiveActivityView(model: fake.paused, metrics: metrics)), open: false)),
                ("Без обложки", island(metrics: metrics, content: AnyView(
                    MusicLiveActivityView(model: fake.placeholder, metrics: metrics)), open: false)),
            ].map { ($0.0, AnyView(Image(decorative: $0.1!, scale: 2))) }, columns: 3))
            let peekWidth = IslandLayout.flashWidth(metrics)
            write("island-peek-\(suffix)", island(metrics: metrics, content: AnyView(
                MusicPeekView(model: fake.peek, metrics: metrics, width: peekWidth)), open: true))
        }

        write("motion-play-pause", filmstrip(title: "Играть → пауза: треугольник расходится на две полосы (spring 0.3/0.86, без отскока)",
                                             times: [0, 0.03, 0.06, 0.09, 0.13, 0.18, 0.24, 0.32, 0.45]) { t in
            let p = MotionCurve.spring(0.3, 0.86).progress(t)
            return AnyView(MusicPlayButton(playing: true, size: 56, action: {}, morph: CGFloat(p)).padding(14))
        })
        write("motion-skip", filmstrip(title: "Следующий трек: треугольники перекатываются на слот вперёд (0,32 с)",
                                       times: [0, 0.04, 0.08, 0.12, 0.16, 0.2, 0.24, 0.28, 0.32]) { t in
            let p = MotionCurve.curve(.easeInOut, 0.32).progress(t)
            return AnyView(MusicSkipButton(forward: true, size: 56, action: {}, phase: CGFloat(p)).padding(14))
        })
        write("motion-cover-next", filmstrip(title: "Смена трека кнопкой «вперёд»: обложки сдвигаются на пятую часть и сменяют друг друга (spring 0.46/0.92)",
                                             times: [0, 0.04, 0.08, 0.12, 0.17, 0.23, 0.3, 0.4, 0.55]) { t in
            let p = MotionCurve.spring(0.46, 0.92).progress(t)
            return AnyView(MusicArtworkView(artwork: fake.cover(2), trackID: "b", playing: true, size: 88, cornerRadius: 18,
                                            direction: 1, swap: (p, fake.cover(0)))
                .frame(width: 150, height: 130))
        })
        write("motion-cover-natural", filmstrip(title: "Трек сменился сам: обложки просто перетекают друг в друга",
                                                times: [0, 0.04, 0.08, 0.12, 0.17, 0.23, 0.3, 0.4, 0.55]) { t in
            let p = MotionCurve.spring(0.46, 0.92).progress(t)
            return AnyView(MusicArtworkView(artwork: fake.cover(1), trackID: "b", playing: true, size: 88, cornerRadius: 18,
                                            direction: 0, swap: (p, fake.cover(0)))
                .frame(width: 150, height: 130))
        })
        write("motion-equalizer", filmstrip(title: "Эквалайзер (Core Animation, 60 к/с) в приглушённом цвете обложки; на паузе — точки",
                                            times: [0, 0.12, 0.24, 0.36, 0.48, 0.6, 0.72, 0.84, -1]) { t in
            AnyView(MusicEqualizer(playing: t >= 0, color: fake.playing.tint.color, filmTime: max(t, 0))
                .frame(width: 34, height: 28)
                .padding(20))
        })
        let (problems, checked) = selfCheck()
        for problem in problems { FileHandle.standardError.write(Data("music self-check: \(problem)\n".utf8)) }
        failures += problems.count
        write("selfcheck-service-widget", image(MusicWidgetView(model: checked, width: width).padding(20).background(Color.black)))
        if ProcessInfo.processInfo.environment["NOTCHBUDDY_MUSIC_DEBUG"] != nil, let np = fake.playing.nowPlaying {
            // The live clock texts (Text(timerInterval:)); the Core Animation bar does not render here.
            write("debug-live-times", image(MusicProgressRow(nowPlaying: np, seek: { _ in })
                .environment(\.islandStaticRender, false).frame(width: 400).padding(20).background(Color.black)))
        }
        return failures == 0 ? 0 : 1
    }

    // MARK: Self-check

    /// The service fed the players' notifications directly (nothing is posted system-wide, no player is
    /// contacted: the service is not started, so it has no Automation access and runs no script).
    private static func selfCheck() -> ([String], MusicWidgetModel) {
        var problems: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { problems.append(what) } }
        let service = NowPlayingService()
        service.receive(.spotify, userInfo: [
            "Player State": "Playing", "Name": "Мокрые крыши", "Artist": "Северный ветер", "Album": "Город после дождя",
            "Track ID": "spotify:track:check", "Duration": NSNumber(value: 215_000), "Playback Position": NSNumber(value: 42.5),
        ])
        expect(service.current?.track.title == "Мокрые крыши", "Spotify notification → current track")
        expect(abs((service.current?.elapsed(at: AppClock.monotonicSeconds()) ?? 0) - 42.5) < 1, "position from the notification")
        expect(service.showsLiveActivity, "playing → live activity")
        expect(service.artwork?.key == "spotify:track:check" && service.artwork?.isPlaceholder == true,
               "placeholder cover while Automation is not granted")
        let checked = service.model
        service.receive(.appleMusic, userInfo: ["Player State": "Paused", "Name": "Солёный воздух", "Artist": "Лагуна",
                                                "Total Time": NSNumber(value: 187_000), "PersistentID": NSNumber(value: 42)])
        expect(service.current?.player == .spotify, "a paused Music does not take over from a playing Spotify")
        service.receive(.spotify, userInfo: ["Player State": "Paused", "Track ID": "spotify:track:check", "Name": "Мокрые крыши"])
        expect(service.current?.player == .spotify && service.current?.isPlaying == false, "Spotify paused, still shown")
        expect(service.showsLiveActivity, "paused a moment ago → live activity lingers")
        service.receive(.spotify, userInfo: ["Player State": "Stopped"])
        expect(service.current?.player == .appleMusic, "Spotify stopped → Music's paused track")
        expect(service.artwork?.key == "000000000000002A", "the cover follows the current track")
        service.options.players = [.spotify]
        expect(service.current == nil, "Music turned off in the options")
        expect(!service.showsLiveActivity, "nothing to show")
        print("music self-check: \(problems.isEmpty ? "ok" : "\(problems.count) problem(s)")")
        return (problems, checked)
    }

    // MARK: Composition

    private static func image<V: View>(_ view: V, scale: CGFloat = 2) -> CGImage? {
        let renderer = ImageRenderer(content: view
            .environment(\.islandStaticRender, true)
            .environment(\.colorScheme, .dark))
        renderer.scale = scale
        return sRGB(renderer.cgImage)
    }

    /// ImageRenderer may hand back an extended-range image (SDR white well below 1.0 once written as PNG):
    /// redraw it into plain 8-bit sRGB.
    static func sRGB(_ image: CGImage?) -> CGImage? {
        guard let image else { return nil }
        if ProcessInfo.processInfo.environment["NOTCHBUDDY_MUSIC_DEBUG"] != nil {
            print("rendered: \(image.colorSpace?.name as String? ?? "?") bpc \(image.bitsPerComponent) info \(image.bitmapInfo.rawValue)")
        }
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// Labelled views in a grid on a dark grey backdrop; `onIsland`: each on a patch of the island's black.
    private static func sheet(onIsland: Bool, _ items: [(String, AnyView)], columns: Int) -> CGImage? {
        let cells = items.map { label, view in
            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
                if onIsland {
                    view
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.black))
                } else {
                    view
                }
            }
        }
        let rows = stride(from: 0, to: cells.count, by: columns).map { Array(cells[$0..<min($0 + columns, cells.count)]) }
        return image(
            VStack(alignment: .leading, spacing: 26) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(alignment: .top, spacing: 26) {
                        ForEach(rows[r].indices, id: \.self) { c in rows[r][c] }
                    }
                }
            }
            .padding(30)
            .background(Color(white: 0.12)))
    }

    /// Content inside the island's black silhouette, hanging from a menu bar over a wallpaper.
    private static func island(metrics: IslandMetrics, content: AnyView, open: Bool) -> CGImage? {
        let canvas: CGFloat = open ? IslandLayout.listWidth(metrics) + 160 : 720
        let ear = open ? IslandLayout.openEar : IslandLayout.closedEar(metrics)
        let bottom = open ? IslandLayout.openBottom : IslandLayout.closedBottom(metrics)
        return image(
            ZStack(alignment: .top) {
                PreviewWallpaper()
                PreviewMenuBar(metrics: metrics)
                content
                    .fixedSize()
                    .padding(.horizontal, ear)
                    .background(IslandShape(earRadius: ear, bottomRadius: bottom).fill(Color.black)
                        .shadow(color: .black.opacity(0.45), radius: 18, y: 8))
                if metrics.style == .notch {
                    IslandShape(earRadius: 0, bottomRadius: 9)
                        .fill(Color.black)
                        .frame(width: metrics.notchWidth, height: metrics.barHeight)
                }
            }
            .frame(width: canvas, alignment: .top)
            .frame(minHeight: open ? 250 : 90, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, open ? 36 : 22)
            .background(PreviewWallpaper())
            .clipped())
    }

    private static func filmstrip(title: String, times: [Double], frame: (Double) -> AnyView) -> CGImage? {
        let frames = times.map(frame)
        return image(
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.8))
                HStack(spacing: 8) {
                    ForEach(times.indices, id: \.self) { i in
                        VStack(spacing: 6) {
                            frames[i]
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black))
                            Text(times[i] < 0 ? "пауза" : "\(Int((times[i] * 1000).rounded())) мс")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(Color.white.opacity(0.55))
                        }
                    }
                }
            }
            .padding(24)
            .background(Color(white: 0.12)))
    }

    private static func save(_ image: CGImage?, to url: URL) -> Bool {
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

private struct PreviewWallpaper: View {
    var body: some View {
        // A quiet graphite desktop.
        ZStack {
            LinearGradient(colors: [Color(red: 0.25, green: 0.26, blue: 0.28), Color(red: 0.11, green: 0.115, blue: 0.125)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.42, green: 0.39, blue: 0.35).opacity(0.3), .clear],
                           center: UnitPoint(x: 0.2, y: 0.1), startRadius: 0, endRadius: 420)
        }
    }
}

private struct PreviewMenuBar: View {
    let metrics: IslandMetrics

    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
            Text("Music").font(.system(size: 13, weight: .bold))
            Text("Файл").font(.system(size: 13))
            Spacer()
            Image(systemName: "wifi").font(.system(size: 13, weight: .semibold))
            Text("Ср 30 сент. 21:07").font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(Color.white.opacity(0.9))
        .padding(.horizontal, 14)
        .frame(height: metrics.menuBarHeight)
        .background(Color.white.opacity(0.08))
    }
}

// MARK: - Fake data

@MainActor
private struct Fake {
    let covers: [MusicArtwork]
    let playing: MusicWidgetModel
    let paused: MusicWidgetModel
    let long: MusicWidgetModel
    let placeholder: MusicWidgetModel
    let blocked: MusicWidgetModel
    let radio: MusicWidgetModel
    let empty: MusicWidgetModel
    let emptyRunning: MusicWidgetModel
    let peek: MusicWidgetModel

    func cover(_ i: Int) -> MusicArtwork { covers[i % covers.count] }

    init() {
        let now = AppClock.monotonicSeconds()
        self.covers = [FakeCover.dusk, FakeCover.surf, FakeCover.print, FakeCover.portrait].enumerated().map { i, style in
            let image = MusicPreviewRenderer.coverImage(style) ?? MusicPreviewRenderer.coverImage(.surf)!
            return MusicArtworkFactory.make(key: "cover-\(i)", image: image)
        }
        let installed = MusicPlayer.allCases
        let covers = self.covers
        func model(_ player: MusicPlayer, _ id: String, _ title: String, _ artist: String, _ album: String,
                   duration: TimeInterval?, position: TimeInterval?, playing: Bool, cover: Int?) -> MusicWidgetModel {
            let track = NowPlayingTrack(id: id, title: title, artist: artist, album: album, duration: duration)
            let np = NowPlaying(player: player, track: track, state: playing ? .playing : .paused, position: position, anchor: now)
            let art = cover.map { i in MusicArtwork(key: id, cover: covers[i].cover, palette: covers[i].palette) }
                ?? MusicArtworkFactory.placeholder(key: id, seed: "\(artist)\u{1F}\(album)")
            return MusicWidgetModel(nowPlaying: np, artwork: art, installed: installed, running: [player],
                                    access: cover == nil ? .undetermined : .granted)
        }
        playing = model(.spotify, "spotify:track:1", "Мокрые крыши", "Северный ветер", "Город после дождя",
                        duration: 215, position: 72, playing: true, cover: 0)
        paused = model(.appleMusic, "A1", "Солёный воздух", "Лагуна", "Прибой", duration: 187, position: 131,
                       playing: false, cover: 1)
        long = model(.spotify, "spotify:track:2",
                     "Очень длинное название трека, которое не помещается в одну строку (Extended Mix)",
                     "Оркестр ночного трамвая feat. Хор бессонных", "Полное собрание сочинений, том второй",
                     duration: 402, position: 96, playing: true, cover: 2)
        placeholder = model(.appleMusic, "A2", "Тёплый ламповый вечер", "Кассета", "Сторона Б", duration: 244,
                            position: nil, playing: true, cover: nil)
        var blocked = model(.spotify, "spotify:track:3", "Чёрно-белое кино", "Плёнка", "Ретроспектива", duration: 198,
                            position: 12, playing: false, cover: 3)
        blocked.blocked = true
        blocked.access = .denied
        self.blocked = blocked
        radio = model(.appleMusic, "radio", "Утреннее шоу", "", "Радио «Волна»", duration: nil, position: 3600,
                      playing: true, cover: 1)
        empty = MusicWidgetModel(nowPlaying: nil, artwork: nil, installed: installed, running: [])
        emptyRunning = MusicWidgetModel(nowPlaying: nil, artwork: nil, installed: installed, running: [.spotify])
        peek = model(.spotify, "spotify:track:4", "Тихий полдень", "Сад камней", "Оттиск", duration: 176, position: 1,
                     playing: true, cover: 2)
    }
}

/// Painted stand-ins for album covers, in the muted, natural colors of real photographs and prints.
enum FakeCover {
    /// A city at dusk after rain: slate sky, a warm haze on the horizon, dark blocks with a few lit windows.
    case dusk
    /// An overcast sea: grey-blue water, a line of surf, wet sand.
    case surf
    /// A print on warm paper: a terracotta disc, an olive block, a thin rule.
    case print
    /// A black-and-white portrait.
    case portrait
}

extension MusicPreviewRenderer {
    /// A painted album cover (no real artwork is used).
    static func coverImage(_ style: FakeCover) -> CGImage? {
        let view = FakeCoverView(style: style).frame(width: 300, height: 300).clipped()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return sRGB(renderer.cgImage)
    }
}

private func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(.sRGB, red: r, green: g, blue: b) }

/// A small deterministic generator, so the painted covers are the same on every run.
private struct SeededRandom {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
}

private struct FakeCoverView: View {
    let style: FakeCover

    var body: some View {
        ZStack {
            switch style {
            case .dusk: dusk
            case .surf: surf
            case .print: print
            case .portrait: portrait
            }
            FilmGrain(seed: grainSeed, amount: style == .portrait ? 0.09 : 0.06)
        }
        .frame(width: 300, height: 300)
    }

    private var grainSeed: UInt64 {
        switch style {
        case .dusk: return 11
        case .surf: return 23
        case .print: return 37
        case .portrait: return 41
        }
    }

    private var dusk: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(stops: [.init(color: rgb(0.24, 0.28, 0.35), location: 0),
                                   .init(color: rgb(0.45, 0.47, 0.52), location: 0.42),
                                   .init(color: rgb(0.76, 0.63, 0.52), location: 0.66),
                                   .init(color: rgb(0.56, 0.45, 0.39), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            Skyline(seed: 5, windows: false).fill(rgb(0.2, 0.21, 0.24)).frame(height: 150).offset(y: -52).blur(radius: 1.2)
            Skyline(seed: 9, windows: false).fill(rgb(0.1, 0.11, 0.13)).frame(height: 190).offset(y: -40)
            Skyline(seed: 9, windows: true).fill(rgb(0.95, 0.77, 0.5).opacity(0.75)).frame(height: 190).offset(y: -40)
            // The wet street, catching the haze.
            LinearGradient(colors: [rgb(0.3, 0.27, 0.26), rgb(0.08, 0.085, 0.1)], startPoint: .top, endPoint: .bottom)
                .frame(height: 40)
            Rectangle().fill(rgb(0.85, 0.66, 0.45).opacity(0.25)).frame(width: 70, height: 40).blur(radius: 8).offset(x: 40)
        }
        .blur(radius: 0.4)
    }

    private var surf: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [rgb(0.62, 0.67, 0.7), rgb(0.8, 0.81, 0.8)], startPoint: .top, endPoint: .bottom)
            // Low clouds.
            Ellipse().fill(Color.white.opacity(0.18)).frame(width: 260, height: 50).blur(radius: 18).offset(x: -40, y: 30)
            Ellipse().fill(rgb(0.5, 0.55, 0.58).opacity(0.35)).frame(width: 220, height: 40).blur(radius: 16).offset(x: 70, y: 70)
            LinearGradient(colors: [rgb(0.36, 0.45, 0.48), rgb(0.25, 0.34, 0.36)], startPoint: .top, endPoint: .bottom)
                .frame(height: 170).offset(y: 130)
            Wave(phase: 0.4, amplitude: 4).fill(Color.white.opacity(0.28)).frame(height: 60).offset(y: 170).blur(radius: 1)
            Wave(phase: 1.3, amplitude: 6).fill(rgb(0.86, 0.87, 0.85).opacity(0.85)).frame(height: 90).offset(y: 206)
                .blur(radius: 1.5)
            Wave(phase: 2.1, amplitude: 7).fill(rgb(0.62, 0.57, 0.49)).frame(height: 90).offset(y: 222)
            LinearGradient(colors: [rgb(0.55, 0.5, 0.43), rgb(0.7, 0.64, 0.55)], startPoint: .top, endPoint: .bottom)
                .frame(height: 50).offset(y: 250)
        }
        .blur(radius: 0.5)
    }

    private var print: some View {
        ZStack {
            rgb(0.9, 0.87, 0.81)
            Circle().fill(rgb(0.71, 0.39, 0.27)).frame(width: 150).offset(x: -40, y: -34)
            Rectangle().fill(rgb(0.38, 0.41, 0.3)).frame(width: 84, height: 132).offset(x: 72, y: 52)
                .blendMode(.multiply)
            Rectangle().fill(rgb(0.16, 0.16, 0.15)).frame(width: 190, height: 2).offset(x: -10, y: 108)
            Circle().fill(rgb(0.16, 0.16, 0.15)).frame(width: 10).offset(x: 98, y: -104)
        }
    }

    private var portrait: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.74), Color(white: 0.34)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Ellipse().fill(Color(white: 0.1)).frame(width: 250, height: 190).offset(x: 20, y: 150).blur(radius: 2)
            Ellipse().fill(Color(white: 0.13)).frame(width: 96, height: 118).offset(x: 20, y: 0).blur(radius: 1.5)
            Ellipse().fill(Color.white.opacity(0.14)).frame(width: 40, height: 80).offset(x: 2, y: -6).blur(radius: 10)
        }
    }
}

/// Building silhouettes along the bottom (or, with `windows`, just their lit windows).
private struct Skyline: Shape {
    let seed: UInt64
    let windows: Bool

    func path(in rect: CGRect) -> Path {
        var random = SeededRandom(state: seed)
        var p = Path()
        var x = rect.minX - 6
        while x < rect.maxX {
            let w = 22 + CGFloat(random.next()) * 34
            let h = rect.height * (0.35 + CGFloat(random.next()) * 0.62)
            let top = rect.maxY - h
            if windows {
                var wy = top + 8
                while wy < rect.maxY - 10 {
                    var wx = x + 5
                    while wx < x + w - 7 {
                        if random.next() < 0.14 { p.addRect(CGRect(x: wx, y: wy, width: 3, height: 4)) }
                        wx += 7
                    }
                    wy += 9
                }
            } else {
                p.addRect(CGRect(x: x, y: top, width: w + 1, height: h))
            }
            x += w
        }
        return p
    }
}

/// Fine, even noise over the whole cover, like film or paper.
private struct FilmGrain: View {
    let seed: UInt64
    let amount: Double

    var body: some View {
        Canvas { ctx, size in
            var random = SeededRandom(state: seed)
            for _ in 0..<5200 {
                let x = random.next() * size.width, y = random.next() * size.height
                let light = random.next() < 0.5
                ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)),
                         with: .color(light ? Color.white.opacity(amount) : Color.black.opacity(amount * 1.4)))
            }
        }
        .allowsHitTesting(false)
    }
}

private struct Wave: Shape {
    var phase: Double
    var amplitude: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + amplitude))
        for x in stride(from: 0, through: rect.width, by: 4) {
            let y = rect.minY + amplitude + amplitude * CGFloat(sin(Double(x) / 38 + phase))
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

extension MusicPreviewRenderer {
    /// A playing track with its cover, for the island's widget films (`--render-widgets`; `english`: the promo film's
    /// English cut gets an English title).
    static func sampleModel(english: Bool = false) -> MusicWidgetModel {
        var model = Fake().playing
        guard english, let track = model.nowPlaying?.track else { return model }
        model.nowPlaying?.track = NowPlayingTrack(id: track.id, title: "Rain on the Roofs", artist: "North Wind",
                                                  album: "City After Rain", duration: track.duration)
        return model
    }
}
