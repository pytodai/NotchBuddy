import NotchBuddyCore
import SwiftUI

/// Everything the music widget draws (`NowPlayingService.model`, or fake data in previews).
struct MusicWidgetModel: Equatable {
    var nowPlaying: NowPlaying?
    var artwork: MusicArtwork?
    var installed: [MusicPlayer] = []
    var running: Set<MusicPlayer> = []
    /// Automation for the current player.
    var access: MusicAccess = .undetermined
    /// A control was refused: show where to allow it.
    var blocked = false
    /// +1 / −1: the track changes because the user skipped forward / back.
    var skipDirection = 0
    /// Scripting is off in the options: the transport shows but does not respond.
    var controlsEnabled = true

    var palette: ArtworkPalette {
        artwork?.palette ?? .placeholder(seed: nowPlaying.map { "\($0.track.artist)\u{1F}\($0.track.album)" } ?? "")
    }

    /// The equalizer's color: the real cover's color, calmed; light grey without a cover.
    var tint: PaletteColor {
        if let artwork, !artwork.isPlaceholder { return artwork.palette.calm }
        return MusicInk.neutralTint
    }
}

struct MusicWidgetActions {
    var playPause: () -> Void = {}
    var next: () -> Void = {}
    var previous: () -> Void = {}
    /// To a fraction of the track (0…1).
    var seek: (Double) -> Void = { _ in }
    var open: (MusicPlayer) -> Void = { _ in }
    var openAutomationSettings: () -> Void = {}
}

/// The service-backed widget for the expanded island: tells the service when it is on screen (so the
/// exact position is only re-read while someone looks).
struct MusicWidget: View {
    let service: NowPlayingService
    let width: CGFloat

    var body: some View {
        MusicWidgetView(model: service.model, actions: service.actions, width: width)
            .onAppear { service.setVisible(true) }
            .onDisappear { service.setVisible(false) }
    }
}

/// Музыка, the way the Dynamic Island shows it: on the island's black, the cover as a small rounded
/// square, the title in white and the artist in grey, a small equalizer in the cover's color; a thin white
/// progress line you can scrub; plain white transport. With nothing playing, a grey square and buttons to
/// open the installed players.
struct MusicWidgetView: View {
    let model: MusicWidgetModel
    var actions = MusicWidgetActions()
    let width: CGFloat
    /// Previews: the pointer is over the card / the progress bar.
    var previewHover = false
    var previewScrub: Double?

    @State private var hovering = false

    var body: some View {
        ZStack {
            if let nowPlaying = model.nowPlaying {
                MusicPlayerCard(nowPlaying: nowPlaying, model: model, actions: actions, hovering: hovering || previewHover,
                                previewScrub: previewScrub)
                    .transition(Self.swap)
            } else {
                MusicEmptyCard(model: model, actions: actions)
                    .transition(Self.swap)
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.42, dampingFraction: 0.9).speed(IslandMotion.speed), value: model.nowPlaying == nil)
        .animation(.spring(response: 0.36, dampingFraction: 0.9).speed(IslandMotion.speed), value: model.blocked)
        .onHover { hovering = $0 }
    }

    private static let swap: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.98)).animation(.spring(response: 0.36, dampingFraction: 0.92).delay(0.05)),
        removal: .opacity.animation(.easeOut(duration: 0.12)))
}

// MARK: - Playing

private struct MusicPlayerCard: View {
    let nowPlaying: NowPlaying
    let model: MusicWidgetModel
    let actions: MusicWidgetActions
    let hovering: Bool
    var previewScrub: Double?

    var body: some View {
        let playing = nowPlaying.isPlaying
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                MusicArtworkView(artwork: model.artwork, trackID: nowPlaying.track.id, playing: playing, size: 52,
                                 cornerRadius: 11, direction: model.skipDirection,
                                 onTap: { actions.open(nowPlaying.player) })
                    .help(L("Открыть %@", nowPlaying.player.accusative))
                MusicTrackTitles(track: nowPlaying.track, direction: model.skipDirection, hovering: hovering)
                MusicEqualizer(playing: playing, color: model.tint.color)
                    .frame(width: 16, height: 14)
            }
            MusicProgressRow(nowPlaying: nowPlaying, seek: actions.seek, previewHover: previewScrub != nil,
                             previewScrub: previewScrub)
                .disabled(!model.controlsEnabled)
                .padding(.top, 14)
            ZStack {
                MusicTransport(playing: playing, actions: actions)
                    .disabled(!model.controlsEnabled)
                    .opacity(model.controlsEnabled ? 1 : 0.35)
                HStack {
                    Spacer(minLength: 0)
                    MusicSourceButton(player: nowPlaying.player) { actions.open(nowPlaying.player) }
                }
            }
            .padding(.top, 4)
            if model.blocked {
                MusicAccessHint(player: nowPlaying.player, open: actions.openAutomationSettings)
                    .padding(.top, 8)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -4)), removal: .opacity))
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

/// Title and "artist — album". A new track glides in from the skip's side (or rises, when it changed by
/// itself) while the old one fades.
private struct MusicTrackTitles: View {
    let track: NowPlayingTrack
    let direction: Int
    let hovering: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 3) {
                MarqueeText(text: track.title.isEmpty ? L("Без названия") : track.title, font: MusicFont.font(15, .semibold),
                            color: MusicInk.title, active: hovering)
                if !track.subtitle.isEmpty {
                    MarqueeText(text: track.subtitle, font: MusicFont.font(13, .medium), color: MusicInk.subtitle,
                                active: hovering)
                }
            }
            .id(track.id)
            .transition(transition)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .animation(.spring(response: 0.42, dampingFraction: 0.92).speed(IslandMotion.speed), value: track.id)
    }

    private var transition: AnyTransition {
        let dx: CGFloat = direction < 0 ? -18 : direction > 0 ? 18 : 0
        let dy: CGFloat = direction == 0 ? 8 : 0
        return .asymmetric(insertion: .offset(x: dx, y: dy).combined(with: .opacity),
                           removal: .offset(x: -dx, y: -dy).combined(with: .opacity))
    }
}

/// The player's small grey icon at the end of the transport row: opens the player.
private struct MusicSourceButton: View {
    let player: MusicPlayer
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            MusicSourceBadge(player: player, size: 16, monochrome: !hovering)
                .opacity(hovering ? 1 : 0.55)
                // Flush with the times' and the equalizer's right edge.
                .frame(width: 30, height: 30, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15).speed(IslandMotion.speed), value: hovering)
        .onHover { hovering = $0 }
        .help(L("Открыть %@", player.accusative))
    }
}

/// 0:42 ━━━━━━──────── −2:13. Drag (or click) to seek; the line thickens under the pointer.
struct MusicProgressRow: View {
    let nowPlaying: NowPlaying
    let seek: (Double) -> Void
    var previewHover = false
    var previewScrub: Double?

    @State private var hovering = false
    @State private var scrub: Double?
    @State private var barWidth: CGFloat = 1
    @Environment(\.islandStaticRender) private var islandStaticRender
    @Environment(\.islandFilmTime) private var filmTime
    /// Previews and films draw the clocks as text (a live timer text runs on the wall clock).
    private var staticRender: Bool { islandStaticRender || filmTime != nil }

    var body: some View {
        let now = AppClock.monotonicSeconds()
        let duration = nowPlaying.track.duration
        let fraction = nowPlaying.progress(at: now)
        let rate = nowPlaying.isPlaying ? duration.map { 1 / $0 } ?? 0 : 0
        let scrubbing = previewScrub ?? scrub
        HStack(spacing: 10) {
            if duration == nil {
                // A stream: no length, no position; a live mark and a plain groove instead of a bar.
                MusicLiveBadge()
                Capsule()
                    .fill(MusicInk.groove)
                    .frame(height: MusicProgressBar.restHeight)
                    .frame(height: 14)
            } else {
                elapsed(now: now, scrubbing: scrubbing)
                    .fixedSize()
                    .frame(minWidth: 34, alignment: .leading)
                MusicProgressBar(fraction: fraction, rate: rate, hovering: hovering || previewHover, scrub: scrubbing)
                    .frame(height: 14)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = max(1, $0) }
                    .contentShape(Rectangle())
                    .onHover { inside in
                        withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard fraction != nil else { return }
                                scrub = min(max(value.location.x / barWidth, 0), 1)
                            }
                            .onEnded { _ in
                                if let scrub { seek(scrub) }
                                scrub = nil
                            }
                    )
                remaining(now: now, scrubbing: scrubbing)
                    .fixedSize()
                    .frame(minWidth: 38, alignment: .trailing)
            }
        }
        .font(MusicFont.font(11, .semibold).monospacedDigit())
    }

    private var timeColor: Color { MusicInk.time }

    @ViewBuilder
    private func elapsed(now: TimeInterval, scrubbing: Double?) -> some View {
        if let scrubbing, let duration = nowPlaying.track.duration {
            Text(NowPlayingFormat.time(scrubbing * duration)).foregroundStyle(Color.white)
        } else if let elapsed = nowPlaying.elapsed(at: now) {
            if nowPlaying.isPlaying, !staticRender {
                let start = Date().addingTimeInterval(-elapsed)
                Text(timerInterval: start...start.addingTimeInterval(nowPlaying.track.duration ?? 24 * 3600),
                     countsDown: false, showsHours: false)
                    .foregroundStyle(timeColor)
            } else {
                Text(NowPlayingFormat.time(elapsed)).foregroundStyle(timeColor)
            }
        } else {
            Text("–:––").foregroundStyle(timeColor)
        }
    }

    @ViewBuilder
    private func remaining(now: TimeInterval, scrubbing: Double?) -> some View {
        if let duration = nowPlaying.track.duration {
            if let scrubbing {
                Text(NowPlayingFormat.remaining(duration * (1 - scrubbing))).foregroundStyle(Color.white)
            } else if let left = nowPlaying.remaining(at: now) {
                if nowPlaying.isPlaying, !staticRender {
                    HStack(spacing: 0) {
                        Text("\u{2212}")
                        Text(timerInterval: Date()...Date().addingTimeInterval(left), countsDown: true, showsHours: false)
                    }
                    .foregroundStyle(timeColor)
                } else {
                    Text(NowPlayingFormat.remaining(left)).foregroundStyle(timeColor)
                }
            } else {
                Text(NowPlayingFormat.time(duration)).foregroundStyle(timeColor)
            }
        }
    }
}

/// "● ЭФИР" for a stream: a small red dot (the one status color) and grey caps.
private struct MusicLiveBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color(red: 1, green: 0.27, blue: 0.23)).frame(width: 5, height: 5)
            Text(L("ЭФИР"))
                .font(MusicFont.font(10, .bold))
                .kerning(0.6)
                .foregroundStyle(MusicInk.time)
        }
    }
}

/// Automation is off for the player: where to turn it on.
private struct MusicAccessHint: View {
    let player: MusicPlayer
    let open: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.04))
            Text(L("Чтобы управлять %@, разреши это в «Автоматизации».", player.instrumental))
                .font(MusicFont.font(11.5, .medium))
                .foregroundStyle(MusicInk.subtitle)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(L("Открыть"), action: open)
                .buttonStyle(IslandButtonStyle(kind: .secondary, height: 24, stretches: false))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

extension MusicPlayer {
    /// "управлять Spotify", "управлять Музыкой".
    var instrumental: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return L("Музыкой")
        }
    }

    /// "Открыть Spotify", "Открыть Музыку".
    var accusative: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return L("Музыку")
        }
    }
}

// MARK: - Nothing playing

private struct MusicEmptyCard: View {
    let model: MusicWidgetModel
    let actions: MusicWidgetActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                MusicNoArtwork(side: 52)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Ничего не играет"))
                        .font(MusicFont.font(15, .semibold))
                        .foregroundStyle(MusicInk.title)
                    Text(subtitle)
                        .font(MusicFont.font(13, .medium))
                        .foregroundStyle(MusicInk.subtitle)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.installed.isEmpty {
                HStack(spacing: 8) {
                    ForEach(model.installed, id: \.self) { player in
                        OpenPlayerButton(player: player, running: model.running.contains(player)) { actions.open(player) }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var subtitle: String {
        if model.installed.isEmpty { return L("Поставь Spotify или открой Музыку — здесь появится то, что играет.") }
        return L("Включи трек — здесь появятся обложка и управление.")
    }
}

/// "Открыть Spotify": the app's icon in grey, in its own colors under the pointer.
private struct OpenPlayerButton: View {
    let player: MusicPlayer
    let running: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                MusicSourceBadge(player: player, size: 16, monochrome: !hovering)
                    .animation(.easeOut(duration: 0.18).speed(IslandMotion.speed), value: hovering)
                Text(running ? L("Перейти в %@", player.accusative) : L("Открыть %@", player.accusative))
                    .font(MusicFont.font(12, .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: 30)
        }
        .buttonStyle(MusicPillButtonStyle())
        .onHover { hovering = $0 }
    }
}

/// A grey capsule that lightens under the pointer and presses in a touch.
struct MusicPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MusicPillBody(configuration: configuration)
    }
}

private struct MusicPillBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.18 : hovering ? 0.14 : 0.1)))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.9).speed(IslandMotion.speed), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14).speed(IslandMotion.speed), value: hovering)
            .onHover { hovering = $0 }
    }
}
