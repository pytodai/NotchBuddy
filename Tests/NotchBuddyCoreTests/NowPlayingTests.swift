import XCTest
@testable import NotchBuddyCore

final class NowPlayingParserTests: XCTestCase {
    func testSpotifyNotification() throws {
        let info: [AnyHashable: Any] = [
            "Player State": "Playing", "Name": "Midnight City", "Artist": "M83", "Album": "Hurry Up, We're Dreaming",
            "Track ID": "spotify:track:6GyFP1nfCDB8lbD2bG0Hq9", "Duration": NSNumber(value: 243_960),
            "Playback Position": NSNumber(value: 42.5), "Has Artwork": NSNumber(value: true),
        ]
        let report = try XCTUnwrap(NowPlayingParser.report(player: .spotify, userInfo: info))
        XCTAssertEqual(report.state, .playing)
        XCTAssertEqual(report.track?.id, "spotify:track:6GyFP1nfCDB8lbD2bG0Hq9")
        XCTAssertEqual(report.track?.title, "Midnight City")
        XCTAssertEqual(report.track?.subtitle, "M83 — Hurry Up, We're Dreaming")
        XCTAssertEqual(try XCTUnwrap(report.track?.duration), 243.96, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(report.position), 42.5, accuracy: 0.001)
    }

    /// The exact shape Spotify 1.2.95 posts on macOS 27 (captured passively; names and IDs replaced).
    func testSpotifyRealPayloadShape() throws {
        let info: [AnyHashable: Any] = [
            "Album Artist": "Artist", "Album": "Album", "Artist": "Artist", "Disc Number": NSNumber(value: 1),
            "Duration": NSNumber(value: 230_000), "Has Artwork": NSNumber(value: true), "Name": "Title",
            "Play Count": NSNumber(value: 0), "Playback Position": NSNumber(value: 0), "Player State": "Playing",
            "Popularity": NSNumber(value: 93), "Track ID": "spotify:track:0000000000000000000000",
            "Track Number": NSNumber(value: 1),
        ]
        let report = try XCTUnwrap(NowPlayingParser.report(player: .spotify, userInfo: info))
        XCTAssertEqual(report.state, .playing)
        XCTAssertEqual(report.track?.duration, 230)
        XCTAssertEqual(report.position, 0)
        XCTAssertEqual(NowPlayingParser.report(player: .spotify, userInfo: ["Player State": "Stopped"])?.state, .stopped)
    }

    func testSpotifyStoppedCarriesNoTrack() {
        let report = NowPlayingParser.report(player: .spotify, userInfo: ["Player State": "Stopped", "Name": "x"])
        XCTAssertEqual(report, PlayerReport(player: .spotify, state: .stopped))
    }

    func testMusicNotificationNormalizesPersistentIDToHex() throws {
        let info: [AnyHashable: Any] = [
            "Player State": "Paused", "Name": "Хочешь", "Artist": "Земфира", "Album": "Прости меня моя любовь",
            "Total Time": NSNumber(value: 225_000), "PersistentID": NSNumber(value: Int64(-6_155_203_428_870_742_307)),
        ]
        let report = try XCTUnwrap(NowPlayingParser.report(player: .appleMusic, userInfo: info))
        XCTAssertEqual(report.state, .paused)
        XCTAssertEqual(report.track?.id, "AA945317D5E49EDD")
        XCTAssertEqual(report.track?.duration, 225)
        XCTAssertNil(report.position, "Music's notification has no position")
    }

    func testMusicRadioStreamTitle() throws {
        let info: [AnyHashable: Any] = ["Player State": "Playing", "Name": "Radio Paradise", "Stream Title": "Song — Band"]
        let track = try XCTUnwrap(NowPlayingParser.report(player: .appleMusic, userInfo: info)?.track)
        XCTAssertEqual(track.title, "Song — Band")
        XCTAssertEqual(track.album, "Radio Paradise")
        XCTAssertNil(track.duration)
    }

    func testUnknownStateIsIgnored() {
        XCTAssertNil(NowPlayingParser.report(player: .spotify, userInfo: ["Name": "x"]))
        XCTAssertNil(NowPlayingParser.report(player: .spotify, userInfo: ["Player State": "Buffering"]))
    }

    func testScriptOutput() throws {
        let s = String(NowPlayingParser.separator)
        let output = ["playing", "spotify:track:1", "Title", "Artist", "Album", "200000", "61250",
                      "https://i.scdn.co/image/ab67616d0000b273"].joined(separator: s)
        let report = try XCTUnwrap(NowPlayingParser.report(player: .spotify, script: output))
        XCTAssertEqual(report.state, .playing)
        XCTAssertEqual(report.track?.duration, 200)
        XCTAssertEqual(try XCTUnwrap(report.position), 61.25, accuracy: 0.0001)
        XCTAssertEqual(report.track?.artworkURL?.host, "i.scdn.co")
    }

    func testScriptOutputRawEnumeratorAndEmptyFields() throws {
        let s = String(NowPlayingParser.separator)
        let output = ["«constant ****kPSp»", "", "Title", "", "", "0", "", "http://insecure"].joined(separator: s)
        let report = try XCTUnwrap(NowPlayingParser.report(player: .appleMusic, script: output))
        XCTAssertEqual(report.state, .paused)
        XCTAssertNil(report.track?.duration)
        XCTAssertNil(report.position)
        XCTAssertNil(report.track?.artworkURL, "only https artwork is fetched")
        XCTAssertFalse(report.track?.id.isEmpty ?? true)
    }

    func testScriptStoppedAndNotRunning() {
        XCTAssertEqual(NowPlayingParser.report(player: .spotify, script: "stopped"),
                       PlayerReport(player: .spotify, state: .stopped))
        XCTAssertNil(NowPlayingParser.report(player: .spotify, script: "notrunning"))
        XCTAssertEqual(NowPlayingParser.report(player: .appleMusic, script: "paused"),
                       PlayerReport(player: .appleMusic, state: .paused), "a state without a track is not a stop")
    }

    func testPlaybackStateSpellings() {
        XCTAssertEqual(PlaybackState(reported: "Playing"), .playing)
        XCTAssertEqual(PlaybackState(reported: "fast forwarding"), .playing)
        XCTAssertEqual(PlaybackState(reported: "kPSS"), .stopped)
        XCTAssertNil(PlaybackState(reported: ""))
    }
}

final class NowPlayingBoardTests: XCTestCase {
    private func track(_ id: String, duration: TimeInterval? = 200) -> NowPlayingTrack {
        NowPlayingTrack(id: id, title: "T\(id)", artist: "A", album: "B", duration: duration)
    }

    func testFirstSightWithoutPositionIsUnknown() {
        var board = NowPlayingBoard()
        XCTAssertEqual(board.apply(PlayerReport(player: .appleMusic, state: .playing, track: track("1")), at: 100), .track)
        XCTAssertNil(board.current?.elapsed(at: 110))
        XCTAssertNil(board.current?.progress(at: 110))
    }

    func testTrackChangeStartsAtZeroAndRuns() throws {
        var board = NowPlayingBoard()
        board.apply(PlayerReport(player: .appleMusic, state: .playing, track: track("1")), at: 100)
        XCTAssertEqual(board.apply(PlayerReport(player: .appleMusic, state: .playing, track: track("2")), at: 150), .track)
        XCTAssertEqual(try XCTUnwrap(board.current?.elapsed(at: 160)), 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(board.current?.progress(at: 250)), 0.5, accuracy: 0.001)
        XCTAssertEqual(board.current?.elapsed(at: 10_000), 200, "clamped to the track's length")
    }

    func testPauseFreezesAndResumeContinues() throws {
        var board = NowPlayingBoard()
        board.apply(PlayerReport(player: .spotify, state: .playing, track: track("1"), position: 30), at: 100)
        XCTAssertEqual(board.apply(PlayerReport(player: .spotify, state: .paused, track: track("1")), at: 110), .state)
        XCTAssertEqual(try XCTUnwrap(board.current?.elapsed(at: 500)), 40, accuracy: 0.001)
        board.apply(PlayerReport(player: .spotify, state: .playing), at: 600)
        XCTAssertEqual(try XCTUnwrap(board.current?.elapsed(at: 605)), 45, accuracy: 0.001)
    }

    func testMetadataMergeKeepsArtworkAndDuration() {
        var board = NowPlayingBoard()
        var first = track("1")
        first.artworkURL = URL(string: "https://i.scdn.co/image/x")
        board.apply(PlayerReport(player: .spotify, state: .playing, track: first, position: 0), at: 0)
        var bare = track("1", duration: nil)
        bare.title = "Renamed"
        XCTAssertEqual(board.apply(PlayerReport(player: .spotify, state: .playing, track: bare), at: 1), .metadata)
        XCTAssertEqual(board.current?.track.title, "Renamed")
        XCTAssertEqual(board.current?.track.duration, 200)
        XCTAssertNotNil(board.current?.track.artworkURL)
    }

    func testSeekReportedByPositionIsAStateChange() {
        var board = NowPlayingBoard()
        board.apply(PlayerReport(player: .spotify, state: .playing, track: track("1"), position: 10), at: 0)
        XCTAssertEqual(board.apply(PlayerReport(player: .spotify, state: .playing, track: track("1"), position: 11), at: 1), .none)
        XCTAssertEqual(board.apply(PlayerReport(player: .spotify, state: .playing, track: track("1"), position: 90), at: 2), .state)
    }

    func testPlayingPlayerLeadsThenLatestPaused() {
        var board = NowPlayingBoard()
        board.apply(PlayerReport(player: .spotify, state: .playing, track: track("s"), position: 0), at: 0)
        board.apply(PlayerReport(player: .appleMusic, state: .paused, track: track("m")), at: 5)
        XCTAssertEqual(board.current?.player, .spotify, "a playing player beats a newer paused one")
        board.apply(PlayerReport(player: .spotify, state: .paused), at: 10)
        XCTAssertEqual(board.current?.player, .spotify, "both paused: the latest change leads")
        board.apply(PlayerReport(player: .appleMusic, state: .playing), at: 20)
        XCTAssertEqual(board.current?.player, .appleMusic)
        XCTAssertEqual(board.apply(PlayerReport(player: .appleMusic, state: .stopped), at: 30), .removed)
        XCTAssertEqual(board.current?.player, .spotify)
        XCTAssertTrue(board.remove(.spotify))
        XCTAssertNil(board.current)
    }

    func testOptimisticToggleAndSeek() throws {
        var board = NowPlayingBoard()
        board.apply(PlayerReport(player: .spotify, state: .playing, track: track("1"), position: 0), at: 0)
        board.setState(.paused, for: .spotify, at: 20)
        XCTAssertEqual(board.current?.state, .paused)
        XCTAssertEqual(try XCTUnwrap(board.current?.elapsed(at: 99)), 20, accuracy: 0.001)
        board.setPosition(500, for: .spotify, at: 30)
        XCTAssertEqual(board.current?.elapsed(at: 31), 200, "clamped")
    }

    func testFormat() {
        XCTAssertEqual(NowPlayingFormat.time(0), "0:00")
        XCTAssertEqual(NowPlayingFormat.time(42.9), "0:42")
        XCTAssertEqual(NowPlayingFormat.time(3723), "1:02:03")
        XCTAssertEqual(NowPlayingFormat.remaining(137.2), "\u{2212}2:18")
        XCTAssertEqual(NowPlayingFormat.time(.nan), "0:00")
    }
}

final class ArtworkPaletteTests: XCTestCase {
    /// An image of horizontal stripes: (color, share of rows).
    private func image(_ stripes: [((UInt8, UInt8, UInt8), Int)], width: Int = 20) -> ([UInt8], Int, Int) {
        var pixels: [UInt8] = []
        var height = 0
        for ((r, g, b), rows) in stripes {
            for _ in 0..<(rows * width) { pixels += [r, g, b, 255] }
            height += rows
        }
        return (pixels, width, height)
    }

    func testDominantVividColorLeadsAndSecondHueIsFound() {
        let (px, w, h) = image([((220, 40, 50), 14), ((40, 80, 230), 6)])
        let palette = ArtworkPalette.extract(rgba: px, width: w, height: h)
        XCTAssertFalse(palette.isMonochrome)
        XCTAssertGreaterThan(palette.primary.r, 0.7)
        XCTAssertGreaterThan(palette.secondary.b, 0.7)
    }

    func testDarkBackgroundDoesNotWinOverASmallBrightAccent() {
        let (px, w, h) = image([((12, 12, 16), 16), ((250, 150, 30), 4)])
        let palette = ArtworkPalette.extract(rgba: px, width: w, height: h)
        let (hue, s, _) = palette.primary.hsv
        XCTAssertGreaterThan(s, 0.6)
        XCTAssertEqual(hue, 0.09, accuracy: 0.05, "orange")
    }

    func testGreyscaleIsMonochromeWithSoftWhiteGlow() {
        let (px, w, h) = image([((30, 30, 30), 10), ((200, 200, 200), 10)])
        let palette = ArtworkPalette.extract(rgba: px, width: w, height: h)
        XCTAssertTrue(palette.isMonochrome)
        XCTAssertLessThan(palette.glow.hsv.s, 0.1)
    }

    func testAccentIsReadableOnBlack() {
        let (px, w, h) = image([((20, 10, 120), 20)])
        let palette = ArtworkPalette.extract(rgba: px, width: w, height: h)
        XCTAssertGreaterThanOrEqual(palette.accent.luminance, 0.3)
    }

    func testPlaceholderIsStablePerSeed() {
        XCTAssertEqual(ArtworkPalette.placeholder(seed: "M83 — Hurry Up"), ArtworkPalette.placeholder(seed: "M83 — Hurry Up"))
        XCTAssertNotEqual(ArtworkPalette.placeholder(seed: "a").primary, ArtworkPalette.placeholder(seed: "b").primary)
    }

    func testHSVRoundTrip() {
        let c = PaletteColor(0.2, 0.6, 0.9)
        let (h, s, v) = c.hsv
        let back = PaletteColor(h: h, s: s, v: v)
        XCTAssertEqual(back.r, c.r, accuracy: 1e-9)
        XCTAssertEqual(back.g, c.g, accuracy: 1e-9)
        XCTAssertEqual(back.b, c.b, accuracy: 1e-9)
    }
}
