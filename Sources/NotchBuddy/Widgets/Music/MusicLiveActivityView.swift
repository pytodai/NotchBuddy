import NotchBuddyCore
import SwiftUI

/// The closed island while music plays, as a live activity (the Dynamic Island's compact music): on a
/// notched screen the cover beside the camera on the left and a small equalizer in the cover's calmed
/// color on the right (the wings come out from behind the housing like the sessions' do). Without a notch:
/// one row, cover, "title  artist", equalizer.
struct MusicLiveActivityView: View {
    let model: MusicWidgetModel
    let metrics: IslandMetrics

    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch metrics.style {
            case .floating: floating
            case .notch: notched
            }
        }
        .frame(height: metrics.barHeight)
        // The equalizer starts once the island has landed.
        .environment(\.islandIgniteDelay, 0.18)
    }

    private var tint: Color { model.tint.color }

    private func cover(_ nowPlaying: NowPlaying, size: CGFloat) -> some View {
        MusicArtworkView(artwork: model.artwork, trackID: nowPlaying.track.id, playing: nowPlaying.isPlaying,
                         size: size, cornerRadius: size * 0.26, direction: model.skipDirection)
    }

    // MARK: Notch

    private var notched: some View {
        NotchWingsLayout(notchWidth: metrics.notchWidth, minWing: model.nowPlaying == nil ? 0 : 40, maxWing: 64) {
            ZStack(alignment: .leading) {
                if let nowPlaying = model.nowPlaying {
                    cover(nowPlaying, size: 21)
                        .padding(.leading, 10)
                        .modifier(NotchWingInset(sign: 1))
                        .transition(.notchWing(edge: .leading, reduce: reduceMotion))
                }
            }
            ZStack(alignment: .trailing) {
                if let nowPlaying = model.nowPlaying {
                    MusicEqualizer(playing: nowPlaying.isPlaying, color: tint)
                        .frame(width: 17, height: 13)
                        .padding(.trailing, 12)
                        .modifier(NotchWingInset(sign: -1))
                        .transition(.notchWing(edge: .trailing, reduce: reduceMotion))
                }
            }
        }
    }

    // MARK: Without a notch

    @ViewBuilder
    private var floating: some View {
        if let nowPlaying = model.nowPlaying {
            LiveActivityRow(minWidth: IslandLayout.collapsedMinWidth, maxWidth: IslandLayout.collapsedMaxWidth) {
                cover(nowPlaying, size: 22)
                    .padding(.leading, 8)
                ZStack(alignment: .leading) {
                    line(nowPlaying.track)
                        .id(nowPlaying.track.id)
                        .transition(.push(from: model.skipDirection < 0 ? .leading : model.skipDirection > 0 ? .trailing : .bottom)
                            .combined(with: .opacity))
                }
                .clipped()
                .animation(.spring(response: 0.42, dampingFraction: 0.88).speed(IslandMotion.speed), value: nowPlaying.track.id)
                .padding(.leading, 9)
                .layoutValue(key: RowRole.self, value: .shrinks)
                Color.clear
                    .frame(width: 12)
                    .layoutValue(key: RowRole.self, value: .slack)
                MusicEqualizer(playing: nowPlaying.isPlaying, color: tint)
                    .frame(width: 16, height: 12)
                    .padding(.trailing, 14)
            }
            // Text centered on the menu bar's text line, not on the taller island.
            .offset(y: -1.5)
        } else {
            Color.clear.frame(width: IslandLayout.collapsedMinWidth * 0.6)
        }
    }

    private func line(_ track: NowPlayingTrack) -> some View {
        let title: Text = Text(track.title.isEmpty ? L("Без названия") : track.title)
            .font(MusicFont.font(13, .semibold))
            .foregroundStyle(MusicInk.title)
        let artist: Text = Text(track.artist.isEmpty ? "" : "  \(track.artist)")
            .font(MusicFont.font(12.5, .medium))
            .foregroundStyle(MusicInk.subtitle)
        return (title + artist)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// A new track, announced for a moment ("Сейчас играет"): the island pops out under the notch with the
/// cover, title and artist, then folds back into the live activity. Rows rise in a short cascade.
struct MusicPeekView: View {
    let model: MusicWidgetModel
    let metrics: IslandMetrics
    let width: CGFloat

    var body: some View {
        let notch = metrics.style == .notch
        VStack(spacing: 0) {
            if notch { Color.clear.frame(height: metrics.barHeight) }
            if let nowPlaying = model.nowPlaying {
                HStack(spacing: 12) {
                    MusicArtworkView(artwork: model.artwork, trackID: nowPlaying.track.id, playing: nowPlaying.isPlaying,
                                     size: 44, cornerRadius: 10, direction: model.skipDirection)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nowPlaying.isPlaying ? L("Сейчас играет") : L("На паузе"))
                            .font(MusicFont.font(10.5, .semibold))
                            .foregroundStyle(MusicInk.faint)
                            .appearAfter(0.03, style: .rise)
                        Text(nowPlaying.track.title.isEmpty ? L("Без названия") : nowPlaying.track.title)
                            .font(MusicFont.font(14.5, .semibold))
                            .foregroundStyle(MusicInk.title)
                            .lineLimit(1)
                            .appearAfter(0.05, style: .rise)
                        if !nowPlaying.track.subtitle.isEmpty {
                            Text(nowPlaying.track.subtitle)
                                .font(MusicFont.font(12.5, .medium))
                                .foregroundStyle(MusicInk.subtitle)
                                .lineLimit(1)
                                .appearAfter(0.07, style: .rise)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    MusicEqualizer(playing: nowPlaying.isPlaying, color: model.tint.color)
                        .frame(width: 17, height: 14)
                        .padding(.trailing, 4)
                }
                .padding(.leading, 14)
                .padding(.trailing, 16)
                .padding(.top, notch ? 6 : 12)
                .padding(.bottom, 13)
            }
        }
        .frame(width: width)
    }
}
