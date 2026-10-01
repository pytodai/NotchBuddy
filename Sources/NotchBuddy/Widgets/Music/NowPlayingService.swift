import AppKit
import Observation
import NotchBuddyCore

/// What is playing in Spotify and Music, pushed by the players themselves.
///
/// - Push, not polling: each player posts a distributed notification on every play, pause, stop and track
///   change, and NSWorkspace says when one launches or quits. With the island closed nothing runs at all.
///   While the widget is on screen (`setVisible`), a playing track's exact position is re-read every
///   10 s (a seek in the player posts nothing).
/// - Never launches a player: scripts go only to running players (`MusicScriptRunner`), and opening one
///   is an explicit click (`open`).
/// - The Automation consent dialog appears only for a click on a control. Until the user has allowed it,
///   the widget still shows the track (from the notifications) with a generated cover; artwork, the exact
///   position and the controls come with the permission.
@Observable
@MainActor
final class NowPlayingService {
    /// What the settings (⚙️) control. Codable, to be stored as is.
    struct Options: Equatable, Codable {
        var enabled = true
        var players: Set<MusicPlayer> = Set(MusicPlayer.allCases)
        /// Artwork, exact position and controls via AppleScript.
        var allowsScripting = true
        /// A paused track keeps the closed island's live activity this long.
        var pausedLinger: TimeInterval = 12
    }

    var options = Options() {
        didSet { if options != oldValue { optionsChanged() } }
    }

    private(set) var board = NowPlayingBoard()
    /// The current track's cover (a placeholder until the real one is in).
    private(set) var artwork: MusicArtwork?
    private(set) var runningPlayers: Set<MusicPlayer> = []
    private(set) var installedPlayers: [MusicPlayer] = []
    private(set) var access: [MusicPlayer: MusicAccess] = [:]
    /// The last skip the user asked for (+1 next, −1 previous; 0 otherwise), for the track change's direction.
    private(set) var skipDirection = 0
    /// A control was refused: Automation is off for this player (the widget shows where to allow it).
    private(set) var blockedPlayer: MusicPlayer?
    /// Whether the closed island should show the music live activity (playing, or paused a moment ago).
    private(set) var showsLiveActivity = false
    /// Counts track changes of the current player (a "now playing" peek can key on it).
    private(set) var trackChanges = 0

    /// The track the widget shows.
    var current: NowPlaying? {
        guard options.enabled else { return nil }
        return board.current
    }

    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var distributed: DistributedObserver?
    @ObservationIgnored private var visibleCount = 0
    @ObservationIgnored private var resyncTimer: Timer?
    @ObservationIgnored private var lingerTimer: Timer?
    @ObservationIgnored private var skipReset: Task<Void, Never>?
    @ObservationIgnored private var syncing: Set<MusicPlayer> = []
    @ObservationIgnored private var syncAgain: Set<MusicPlayer> = []
    @ObservationIgnored private var loadingArtwork: Set<String> = []
    @ObservationIgnored private let covers = MusicArtworkCache()
    @ObservationIgnored private let runner: MusicScriptRunner
    @ObservationIgnored private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    init(runner: MusicScriptRunner = .shared) {
        self.runner = runner
    }

    private func now() -> TimeInterval { AppClock.monotonicSeconds() }

    // MARK: Lifecycle

    func start() {
        guard distributed == nil else { return }
        installedPlayers = MusicPlayer.allCases.filter(MusicPlayerIcon.isInstalled)
        // `.deliverImmediately`: AppKit holds distributed notifications back while the app is inactive
        // (the block API registers with `.coalesce`), and NotchBuddy is almost never the active app.
        distributed = DistributedObserver(names: MusicPlayer.allCases.flatMap(\.notificationNames)) { [weak self] name, info in
            guard let player = MusicPlayer.allCases.first(where: { $0.notificationNames.contains(name) }) else { return }
            self?.receive(player, userInfo: info)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let player = app?.bundleIdentifier.flatMap(MusicPlayer.init(bundleID:)) else { return }
                let launched = note.name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated { self?.playerRan(player, launched: launched) }
            }
            observers.append((workspace, token))
        }
        runningPlayers = Set(MusicPlayer.allCases.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
        })
        // A player already playing when the app starts: its state, if Automation was allowed before (no dialog).
        for player in runningPlayers where enabled(player) { refreshAccess(player, sync: true) }
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        distributed?.invalidate()
        distributed = nil
        resyncTimer?.invalidate()
        resyncTimer = nil
        lingerTimer?.invalidate()
        lingerTimer = nil
    }

    /// The music widget appeared on (true) or left (false) the screen. Calls are counted.
    func setVisible(_ visible: Bool) {
        let was = visibleCount > 0
        visibleCount = max(0, visibleCount + (visible ? 1 : -1))
        let isVisible = visibleCount > 0
        guard isVisible != was else { return }
        if isVisible {
            for player in runningPlayers where enabled(player) { refreshAccess(player, sync: true) }
            let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let current = self.current, current.isPlaying else { return }
                    self.sync(current.player)
                }
            }
            timer.tolerance = 2
            RunLoop.main.add(timer, forMode: .common)
            resyncTimer = timer
        } else {
            resyncTimer?.invalidate()
            resyncTimer = nil
        }
    }

    private func enabled(_ player: MusicPlayer) -> Bool {
        options.enabled && options.players.contains(player)
    }

    private func optionsChanged() {
        for player in MusicPlayer.allCases where !enabled(player) { board.remove(player) }
        afterChange(nil)
        if options.allowsScripting {
            for player in runningPlayers where enabled(player) { refreshAccess(player, sync: visibleCount > 0) }
        }
    }

    // MARK: Events

    /// A player's distributed notification (internal for the preview self-check).
    func receive(_ player: MusicPlayer, userInfo info: [AnyHashable: Any]) {
        guard enabled(player), let report = NowPlayingParser.report(player: player, userInfo: info) else { return }
        if report.state != .stopped { runningPlayers.insert(player) }
        apply(report)
        // Music's notification has no position: read it while someone is looking.
        if player == .appleMusic, visibleCount > 0, report.state != .stopped { sync(player) }
    }

    private func playerRan(_ player: MusicPlayer, launched: Bool) {
        if launched {
            runningPlayers.insert(player)
            if enabled(player) { refreshAccess(player, sync: false) }
        } else {
            runningPlayers.remove(player)
            if board.remove(player) { afterChange(nil) }
        }
    }

    private func apply(_ report: PlayerReport) {
        let before = current
        let change = board.apply(report, at: now())
        guard change != .none else { return }
        afterChange(before)
        if change == .track, current?.player == report.player {
            trackChanges &+= 1
            if board.entries[report.player]?.position == nil { sync(report.player) }
        }
    }

    /// Keeps the artwork and the live activity in step with `current`.
    private func afterChange(_ before: NowPlaying?) {
        if let current {
            if artwork?.key != current.track.id { loadArtwork(for: current) }
        } else if artwork != nil {
            artwork = nil
        }
        if before?.track.id != current?.track.id, before != nil, skipDirection != 0 {
            // The direction belongs to the change the skip caused, not to later ones.
            resetSkip(after: 0.9)
        }
        updateLiveActivity()
    }

    private func resetSkip(after seconds: Double) {
        skipReset?.cancel()
        skipReset = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            guard !Task.isCancelled else { return }
            self?.skipDirection = 0
        }
    }

    private func updateLiveActivity() {
        lingerTimer?.invalidate()
        lingerTimer = nil
        guard let current else {
            showsLiveActivity = false
            return
        }
        if current.isPlaying {
            showsLiveActivity = true
            return
        }
        let left = options.pausedLinger - (now() - current.changedAt)
        showsLiveActivity = left > 0
        guard left > 0 else { return }
        let timer = Timer(timeInterval: left + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLiveActivity() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        lingerTimer = timer
    }

    // MARK: Scripts

    /// Re-checks Automation without asking; with `sync`, reads the player's state once it is allowed.
    private func refreshAccess(_ player: MusicPlayer, sync: Bool) {
        guard options.allowsScripting else { return }
        Task {
            guard let result = await runner.access(player, ask: false) else { return }
            access[player] = result
            if result == .granted {
                if blockedPlayer == player { blockedPlayer = nil }
                if sync { self.sync(player) }
                if let current, current.player == player, artwork?.isPlaceholder ?? true { loadArtwork(for: current) }
            }
        }
    }

    /// Reads the player's exact state (one script run; a request while one runs is merged into a rerun).
    private func sync(_ player: MusicPlayer) {
        guard options.allowsScripting, enabled(player), access[player] == .granted else { return }
        guard !syncing.contains(player) else {
            syncAgain.insert(player)
            return
        }
        syncing.insert(player)
        Task {
            let result = await runner.run(.nowPlaying, on: player)
            syncing.remove(player)
            switch result {
            case .text(let output):
                if let report = NowPlayingParser.report(player: player, script: output), enabled(player) {
                    apply(report)
                    if let track = report.track, player == .spotify, track.artworkURL != nil,
                       current?.track.id == track.id, artwork?.isPlaceholder ?? true {
                        loadArtwork(for: current!)
                    }
                }
            case .notRunning:
                runningPlayers.remove(player)
                if board.remove(player) { afterChange(nil) }
            case .denied:
                access[player] = .denied
            case .needsConsent:
                access[player] = .undetermined
            default:
                break
            }
            if syncAgain.remove(player) != nil { sync(player) }
        }
    }

    private func loadArtwork(for playing: NowPlaying) {
        let track = playing.track
        let key = track.id
        if let hit = covers[key] {
            artwork = hit
            return
        }
        // Colors at once (stable per album), the real cover when it arrives.
        if artwork?.key != key {
            let seed = track.album.isEmpty ? "\(track.artist)\u{1F}\(track.title)" : "\(track.artist)\u{1F}\(track.album)"
            artwork = MusicArtworkFactory.placeholder(key: key, seed: seed)
        }
        guard options.allowsScripting, access[playing.player] == .granted, !loadingArtwork.contains(key) else { return }
        loadingArtwork.insert(key)
        let player = playing.player
        Task {
            defer { loadingArtwork.remove(key) }
            var made: MusicArtwork?
            switch player {
            case .spotify:
                guard let url = track.artworkURL ?? board.entries[.spotify].flatMap({ $0.track.id == key ? $0.track.artworkURL : nil }) else {
                    sync(.spotify)   // brings the URL; the sync loads the cover
                    return
                }
                guard Self.isSpotifyCDN(url), let (data, response) = try? await session.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                made = await Task.detached(priority: .userInitiated) { MusicArtworkFactory.make(key: key, data: data) }.value
            case .appleMusic:
                // The script reads whatever is current: keep it only if the track has not changed meanwhile.
                if case .data(let data) = await runner.run(.artwork, on: .appleMusic),
                   board.entries[.appleMusic]?.track.id == key {
                    made = await Task.detached(priority: .userInitiated) { MusicArtworkFactory.make(key: key, data: data) }.value
                }
            }
            guard let made else { return }
            covers.insert(made)
            if current?.track.id == key { artwork = made }
        }
    }

    /// Spotify's artwork hosts only (the URL comes from the player; nothing else is fetched).
    static func isSpotifyCDN(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "i.scdn.co" || host.hasSuffix(".scdn.co") || host.hasSuffix(".spotifycdn.com")
    }

    // MARK: Controls

    func togglePlayPause() {
        guard let current else { return }
        let target: PlaybackState = current.isPlaying ? .paused : .playing
        control(.playPause) { [weak self] in
            guard let self else { return }
            let before = self.current
            self.board.setState(target, for: current.player, at: self.now())
            self.afterChange(before)
        }
    }

    func nextTrack() {
        guard current != nil else { return }
        skipDirection = 1
        resetSkip(after: 3)
        control(.next)
    }

    /// Like the players' own button: back to the start first, the previous track within the first 3 s.
    func previousTrack() {
        guard let current else { return }
        if let elapsed = current.elapsed(at: now()), elapsed > 3 {
            seek(to: 0)
            return
        }
        skipDirection = -1
        resetSkip(after: 3)
        control(.previous)
    }

    func seek(toFraction fraction: Double) {
        guard let duration = current?.track.duration else { return }
        seek(to: min(max(fraction, 0), 1) * duration)
    }

    func seek(to seconds: TimeInterval) {
        guard let current else { return }
        let ms = Int((max(0, seconds) * 1000).rounded())
        control(.seek, arguments: [String(ms)]) { [weak self] in
            guard let self else { return }
            self.board.setPosition(seconds, for: current.player, at: self.now())
        }
    }

    /// Runs a control on the current player. The first one asks for Automation (the click is the user's
    /// consent to see the dialog); `optimistic` updates the widget before the player confirms.
    private func control(_ handler: MusicScriptRunner.Handler, arguments: [String] = [], optimistic: (() -> Void)? = nil) {
        guard options.allowsScripting, let player = current?.player else { return }
        let granted = access[player] == .granted
        if granted { optimistic?() }
        Task {
            if !granted {
                let answer = await runner.access(player, ask: true)
                access[player] = answer ?? .undetermined
                guard answer == .granted else {
                    blockedPlayer = answer == nil ? nil : player
                    return
                }
                blockedPlayer = nil
                optimistic?()
                if let current, artwork?.isPlaceholder ?? true { loadArtwork(for: current) }
            }
            switch await runner.run(handler, on: player, arguments: arguments) {
            case .denied:
                access[player] = .denied
                blockedPlayer = player
                sync(player)
            case .notRunning:
                runningPlayers.remove(player)
                if board.remove(player) { afterChange(nil) }
            case .failed:
                sync(player)
            default:
                // Spotify's notification confirms every control; Music's all but a seek.
                if handler == .seek || handler == .playPause { sync(player) }
            }
        }
    }

    /// Opens (launches) a player: only ever on a click.
    func open(_ player: MusicPlayer) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Views

    /// Everything the widget draws.
    var model: MusicWidgetModel {
        let current = current
        return MusicWidgetModel(nowPlaying: current, artwork: artwork?.key == current?.track.id ? artwork : nil,
                                installed: installedPlayers, running: runningPlayers,
                                access: current.flatMap { access[$0.player] } ?? .undetermined,
                                blocked: blockedPlayer != nil && blockedPlayer == current?.player,
                                skipDirection: skipDirection, controlsEnabled: options.allowsScripting)
    }

    var actions: MusicWidgetActions {
        MusicWidgetActions(
            playPause: { [weak self] in self?.togglePlayPause() },
            next: { [weak self] in self?.nextTrack() },
            previous: { [weak self] in self?.previousTrack() },
            seek: { [weak self] in self?.seek(toFraction: $0) },
            open: { [weak self] in self?.open($0) },
            openAutomationSettings: { [weak self] in self?.openAutomationSettings() })
    }
}

extension MusicPlayer {
    /// Music still posts its iTunes-era notification too (same payload; a duplicate changes nothing).
    var notificationNames: [String] {
        switch self {
        case .spotify: return [notificationName]
        case .appleMusic: return [notificationName, "com.apple.iTunes.playerInfo"]
        }
    }
}

/// Distributed notifications, delivered at once whether or not the app is active, on the main thread.
private final class DistributedObserver: NSObject {
    private let handler: @MainActor (String, [AnyHashable: Any]) -> Void

    init(names: [String], handler: @escaping @MainActor (String, [AnyHashable: Any]) -> Void) {
        self.handler = handler
        super.init()
        for name in names {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(received(_:)),
                                                                name: Notification.Name(name), object: nil,
                                                                suspensionBehavior: .deliverImmediately)
        }
    }

    func invalidate() {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func received(_ note: Notification) {
        let name = note.name.rawValue
        nonisolated(unsafe) let info = note.userInfo ?? [:]
        if Thread.isMainThread {
            MainActor.assumeIsolated { handler(name, info) }
        } else {
            DispatchQueue.main.async { [handler] in MainActor.assumeIsolated { handler(name, info) } }
        }
    }
}
