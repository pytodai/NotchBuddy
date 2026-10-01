import Foundation

// Now playing: what the music widget shows, from the players' own push notifications.
//
// macOS 15.4 put MediaRemote's now-playing API behind a private entitlement (an ordinary app gets nothing),
// so NotchBuddy follows the players directly:
// - Spotify and Music post a distributed notification on every play, pause, stop and track change
//   (`com.spotify.client.PlaybackStateChanged`, `com.apple.Music.playerInfo`) with the track's name,
//   artist, album, length and (Spotify) position. That push is all the widget needs to stay current:
//   nothing polls, and nothing reaches a player that is not running.
// - AppleScript (only to a running player, only once the user granted Automation) reads the artwork
//   and the exact position and sends play/pause/next/previous/seek.
// This file is the pure part (parsing, arbitration, formatting); the app side lives in
// `Sources/NotchBuddy/Widgets/Music`.

/// A music app the widget follows.
public enum MusicPlayer: String, CaseIterable, Codable, Sendable, Hashable {
    case spotify
    case appleMusic

    public var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .appleMusic: return "com.apple.Music"
        }
    }

    /// As the player calls itself in Russian UI ("Музыка" is Apple's own name for Music.app).
    public var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return L("Музыка")
        }
    }

    /// The distributed notification the player posts on every play/pause/stop/track change.
    public var notificationName: String {
        switch self {
        case .spotify: return "com.spotify.client.PlaybackStateChanged"
        case .appleMusic: return "com.apple.Music.playerInfo"
        }
    }

    public init?(bundleID: String) {
        guard let player = MusicPlayer.allCases.first(where: { $0.bundleID == bundleID }) else { return nil }
        self = player
    }
}

public enum PlaybackState: String, Equatable, Sendable {
    case playing
    case paused
    case stopped

    /// "Playing" (notifications), "playing" (`player state as text` in AppleScript), or the raw enumerator
    /// when a script hands it back untranslated («constant ****kPSP»).
    public init?(reported raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Four-char codes are case-sensitive: kPSP playing, kPSp paused, kPSS stopped, kPSF/kPSR seeking.
        if s.contains("kPSP") || s.contains("kPSF") || s.contains("kPSR") { self = .playing; return }
        if s.contains("kPSp") { self = .paused; return }
        if s.contains("kPSS") { self = .stopped; return }
        switch s.lowercased() {
        case "playing", "fast forwarding", "rewinding": self = .playing
        case "paused": self = .paused
        case "stopped": self = .stopped
        default: return nil
        }
    }
}

public struct NowPlayingTrack: Equatable, Sendable {
    /// Spotify's URI ("spotify:track:…") or Music's persistent ID as 16 hex digits; a composite of the
    /// names when the player gave neither.
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds; nil when unknown or endless (a radio stream).
    public var duration: TimeInterval?
    /// Spotify's artwork on its CDN (read by AppleScript; Music hands the image data over instead).
    public var artworkURL: URL?

    public init(id: String, title: String, artist: String = "", album: String = "", duration: TimeInterval? = nil,
                artworkURL: URL? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkURL = artworkURL
    }

    /// Spotify's ads come through as tracks.
    public var isAdvertisement: Bool { id.hasPrefix("spotify:ad:") }

    /// "Artist — Album", or whichever of them is known.
    public var subtitle: String {
        [artist, album].filter { !$0.isEmpty }.joined(separator: " — ")
    }
}

/// One player's current track and where it is in it.
public struct NowPlaying: Equatable, Sendable {
    public var player: MusicPlayer
    public var track: NowPlayingTrack
    public var state: PlaybackState
    /// The position at `anchor`; nil while unknown (a track already under way when the app started).
    public var position: TimeInterval?
    /// Monotonic seconds (`AppClock.monotonicSeconds`) when `position` was true.
    public var anchor: TimeInterval
    /// Monotonic seconds of the last play/pause or track change (the newest one leads the widget).
    public var changedAt: TimeInterval

    public init(player: MusicPlayer, track: NowPlayingTrack, state: PlaybackState, position: TimeInterval?,
                anchor: TimeInterval, changedAt: TimeInterval? = nil) {
        self.player = player
        self.track = track
        self.state = state
        self.position = position
        self.anchor = anchor
        self.changedAt = changedAt ?? anchor
    }

    public var isPlaying: Bool { state == .playing }

    /// Seconds into the track at monotonic `now`: runs on while playing, clamped to the track's length.
    public func elapsed(at now: TimeInterval) -> TimeInterval? {
        guard let position else { return nil }
        let running = isPlaying ? max(0, now - anchor) : 0
        let value = max(0, position + running)
        return track.duration.map { min(value, $0) } ?? value
    }

    /// 0…1, when both the position and the length are known.
    public func progress(at now: TimeInterval) -> Double? {
        guard let duration = track.duration, duration > 0, let elapsed = elapsed(at: now) else { return nil }
        return min(max(elapsed / duration, 0), 1)
    }

    public func remaining(at now: TimeInterval) -> TimeInterval? {
        guard let duration = track.duration, let elapsed = elapsed(at: now) else { return nil }
        return max(0, duration - elapsed)
    }
}

/// What one notification or script run said about a player. `track` is nil when it said nothing about
/// the track (a stop, a bare state change).
public struct PlayerReport: Equatable, Sendable {
    public var player: MusicPlayer
    public var state: PlaybackState
    public var track: NowPlayingTrack?
    /// Seconds, when the report carried it (Spotify's notifications, scripts).
    public var position: TimeInterval?

    public init(player: MusicPlayer, state: PlaybackState, track: NowPlayingTrack? = nil, position: TimeInterval? = nil) {
        self.player = player
        self.state = state
        self.track = track
        self.position = position
    }
}

public enum NowPlayingParser {
    /// Separates the fields a now-playing script returns (ASCII unit separator: never in a title).
    public static let separator: Character = "\u{1F}"

    /// A player's distributed notification (`userInfo` as posted). Nil when it carries no player state.
    public static func report(player: MusicPlayer, userInfo: [AnyHashable: Any]) -> PlayerReport? {
        guard let raw = string(userInfo["Player State"]), let state = PlaybackState(reported: raw) else { return nil }
        guard state != .stopped else { return PlayerReport(player: player, state: .stopped) }
        var title = string(userInfo["Name"]) ?? ""
        var album = string(userInfo["Album"]) ?? ""
        var artist = string(userInfo["Artist"]) ?? ""
        if artist.isEmpty { artist = string(userInfo["Album Artist"]) ?? "" }
        let id: String?
        let duration: Double?
        var position: Double?
        switch player {
        case .spotify:
            id = string(userInfo["Track ID"])
            duration = number(userInfo["Duration"]).map { $0 / 1000 }
            position = number(userInfo["Playback Position"])
        case .appleMusic:
            id = musicPersistentID(userInfo["PersistentID"] ?? userInfo["Persistent ID"])
            duration = number(userInfo["Total Time"]).map { $0 / 1000 }
            // A radio stream: the song is in "Stream Title", the station in "Name".
            if let stream = string(userInfo["Stream Title"]), !stream.isEmpty {
                album = title
                title = stream
            }
        }
        if let p = position, !p.isFinite || p < 0 { position = nil }
        guard !title.isEmpty || !(id ?? "").isEmpty else {
            return PlayerReport(player: player, state: state, position: position)
        }
        let track = NowPlayingTrack(id: id.flatMap { $0.isEmpty ? nil : $0 } ?? compositeID(title, artist, album),
                                    title: title, artist: artist, album: album,
                                    duration: duration.flatMap { $0 > 0 && $0.isFinite ? $0 : nil })
        return PlayerReport(player: player, state: state, track: track, position: position)
    }

    /// The output of a now-playing script: state, id, title, artist, album, duration (ms), position (ms),
    /// artwork URL, separated by `separator`; or just a state ("stopped", or "paused" with no current
    /// track). Nil for anything else ("notrunning").
    public static func report(player: MusicPlayer, script output: String) -> PlayerReport? {
        let fields = output.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        guard let first = fields.first, let state = PlaybackState(reported: first) else { return nil }
        guard state != .stopped else { return PlayerReport(player: player, state: .stopped) }
        // A state and no current track (the script could not read one): nothing about the track.
        guard fields.count >= 8 else { return PlayerReport(player: player, state: state) }
        let (id, title, artist, album) = (fields[1], fields[2], fields[3], fields[4])
        let duration = Double(fields[5].trimmingCharacters(in: .whitespaces)).map { $0 / 1000 }
        let position = Double(fields[6].trimmingCharacters(in: .whitespaces)).map { $0 / 1000 }
        let artwork = URL(string: fields[7].trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == "https" ? $0 : nil }
        let track = NowPlayingTrack(id: id.isEmpty ? compositeID(title, artist, album) : id, title: title,
                                    artist: artist, album: album,
                                    duration: duration.flatMap { $0 > 0 ? $0 : nil }, artworkURL: artwork)
        return PlayerReport(player: player, state: state, track: track, position: position.flatMap { $0 >= 0 ? $0 : nil })
    }

    /// Music's notification carries the persistent ID as a (signed 64-bit) number, AppleScript as 16 hex
    /// digits: both become the hex form, so a script and a notification agree on the track.
    static func musicPersistentID(_ value: Any?) -> String? {
        if let number = value as? NSNumber {
            return String(format: "%016llX", UInt64(bitPattern: number.int64Value))
        }
        if let text = value as? String, !text.isEmpty {
            if let signed = Int64(text) { return String(format: "%016llX", UInt64(bitPattern: signed)) }
            return text.uppercased()
        }
        return nil
    }

    static func compositeID(_ title: String, _ artist: String, _ album: String) -> String {
        "\(title)\u{1F}\(artist)\u{1F}\(album)"
    }

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

/// Every running player's state; `current` is the one the widget shows.
public struct NowPlayingBoard: Equatable, Sendable {
    public private(set) var entries: [MusicPlayer: NowPlaying] = [:]

    public init() {}

    public enum Change: Equatable, Sendable {
        case none
        /// Same track: names, length or artwork URL filled in.
        case metadata
        /// Played, paused or moved (a seek).
        case state
        /// Another track.
        case track
        /// The player stopped or quit.
        case removed
    }

    /// The player that is playing (the latest to start, if both are); otherwise the latest to pause.
    public var current: NowPlaying? {
        let all = Array(entries.values)
        if let playing = all.filter(\.isPlaying).max(by: Self.older) { return playing }
        return all.max(by: Self.older)
    }

    private static func older(_ a: NowPlaying, _ b: NowPlaying) -> Bool {
        a.changedAt == b.changedAt ? a.player.rawValue > b.player.rawValue : a.changedAt < b.changedAt
    }

    @discardableResult
    public mutating func apply(_ report: PlayerReport, at now: TimeInterval) -> Change {
        let player = report.player
        guard report.state != .stopped else { return remove(player) ? .removed : .none }
        guard var entry = entries[player] else {
            // First news from this player: a track already under way has an unknown position unless the
            // report carried it.
            guard let track = report.track else { return .none }
            entries[player] = NowPlaying(player: player, track: track, state: report.state, position: report.position,
                                         anchor: now, changedAt: now)
            return .track
        }
        if let track = report.track, track.id != entry.track.id {
            // Seen this player on another track: this one just started.
            entries[player] = NowPlaying(player: player, track: track, state: report.state,
                                         position: report.position ?? 0, anchor: now, changedAt: now)
            return .track
        }
        let before = entry
        if let track = report.track {
            entry.track = NowPlayingTrack(id: track.id,
                                          title: track.title.isEmpty ? entry.track.title : track.title,
                                          artist: track.artist.isEmpty ? entry.track.artist : track.artist,
                                          album: track.album.isEmpty ? entry.track.album : track.album,
                                          duration: track.duration ?? entry.track.duration,
                                          artworkURL: track.artworkURL ?? entry.track.artworkURL)
        }
        let stateChanged = entry.state != report.state
        if let position = report.position {
            entry.position = position
            entry.anchor = now
        } else if stateChanged {
            entry.position = entry.elapsed(at: now)
            entry.anchor = now
        }
        entry.state = report.state
        if stateChanged { entry.changedAt = now }
        entries[player] = entry
        if stateChanged { return .state }
        if entry.track != before.track { return .metadata }
        if let old = before.elapsed(at: now), let new = entry.elapsed(at: now), abs(old - new) > 1.5 { return .state }
        if before.position == nil, entry.position != nil { return .state }
        return .none
    }

    /// Play/pause as the user asked, before the player confirms it (the button answers at once).
    public mutating func setState(_ state: PlaybackState, for player: MusicPlayer, at now: TimeInterval) {
        guard var entry = entries[player], entry.state != state, state != .stopped else { return }
        entry.position = entry.elapsed(at: now)
        entry.anchor = now
        entry.state = state
        entry.changedAt = now
        entries[player] = entry
    }

    /// A seek, before the player confirms it.
    public mutating func setPosition(_ position: TimeInterval, for player: MusicPlayer, at now: TimeInterval) {
        guard var entry = entries[player] else { return }
        entry.position = max(0, entry.track.duration.map { min(position, $0) } ?? position)
        entry.anchor = now
        entries[player] = entry
    }

    @discardableResult
    public mutating func remove(_ player: MusicPlayer) -> Bool {
        entries.removeValue(forKey: player) != nil
    }
}

public enum NowPlayingFormat {
    /// "3:07", "1:02:03".
    public static func time(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "−2:13" (a true minus sign).
    public static func remaining(_ seconds: TimeInterval) -> String {
        "\u{2212}" + time(seconds.rounded(.up))
    }
}
