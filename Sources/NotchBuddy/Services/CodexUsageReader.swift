import CoreServices
import Foundation
import NotchBuddyCore

/// Codex's 5-hour / weekly usage, read from its own rollouts on this Mac.
/// No network, no credentials, nothing written under `~/.codex`.
///
/// - The newest rollout is found by modification time: one walk of `sessions/` at start (and every 10 min as a
///   safety net), then FSEvents paths and hook `transcript_path`s say which file moved.
/// - A file's tail is read only when its size or mtime changed since the last read, and only the last 64 KB
///   (growing to at most 8 MB past huge lines).
/// - A newer file without any `token_count` (a session with no model turn yet) never blanks the last good value.
@MainActor
final class CodexUsageReader {
    /// The last usage (nil: Codex never ran here, or none of its rollouts has rate limits yet).
    private(set) var snapshot: CodexRateLimits?
    /// Called on the main actor whenever `snapshot` changes.
    var onChange: ((CodexRateLimits?) -> Void)?

    private var home: URL
    private let worker: CodexRolloutWorker
    private var watcher: CodexRolloutWatcher?
    private var timer: Timer?
    private var running = false
    private var pendingHookCheck: Task<Void, Never>?

    static let rescanInterval: TimeInterval = 10 * 60
    /// The rollout writer is asynchronous: the turn's last `token_count` can land a moment after the hook fires.
    static let hookDelay: Duration = .milliseconds(600)

    init(home: URL = CodexHome.resolve()) {
        self.home = home
        worker = CodexRolloutWorker(home: home)
    }

    /// Whether Codex has ever run with this home (its `sessions` folder exists).
    var codexPresent: Bool {
        FileManager.default.fileExists(atPath: CodexHome.sessions(home).path)
    }

    func start() {
        guard !running else { return }
        running = true
        startWatching()
        timer = Timer.scheduledTimer(withTimeInterval: Self.rescanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(fullScan: true) }
        }
        timer?.tolerance = 60
        check(fullScan: true)
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        watcher?.stop()
        watcher = nil
        pendingHookCheck?.cancel()
    }

    /// Someone is about to look at the usage (the island opened): re-check the newest file (cheap when unchanged).
    func refresh() {
        guard running else { return }
        check(fullScan: false)
    }

    /// A Codex hook event: its `transcript_path` is the live rollout (and tells where `CODEX_HOME` really is).
    /// After a turn or a tool call, that file is read shortly after (only if it changed).
    func noteHookEvent(_ event: AgentEvent) {
        guard event.source == .codex, running else { return }
        let path = event.transcriptPath ?? event.raw["transcript_path"]?.string
        if let path, let root = CodexHome.root(ofTranscript: path), root.standardizedFileURL != home.standardizedFileURL {
            Log.info("codex usage: CODEX_HOME is \(root.path) (from a hook)")
            home = root
            startWatching()
            Task { await worker.setHome(root) }
        }
        guard [.stop, .stopFailed, .toolDidRun, .toolFailed, .sessionEnd].contains(event.kind) else { return }
        let candidate = path.map { URL(fileURLWithPath: $0) }
        pendingHookCheck?.cancel()
        pendingHookCheck = Task { [weak self] in
            try? await Task.sleep(for: Self.hookDelay)
            guard !Task.isCancelled else { return }
            self?.check(fullScan: false, candidate: candidate)
        }
    }

    private func startWatching() {
        watcher?.stop()
        let sessions = CodexHome.sessions(home)
        // Codex never ran yet: watch its home, so the first session is noticed.
        let target = FileManager.default.fileExists(atPath: sessions.path) ? sessions : home
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        let watcher = CodexRolloutWatcher()
        watcher.onRollout = { [weak self] url in
            Task { @MainActor in self?.check(fullScan: url == nil, candidate: url) }
        }
        watcher.start(path: target)
        self.watcher = watcher
    }

    private func check(fullScan: Bool, candidate: URL? = nil) {
        Task {
            let result = await worker.check(fullScan: fullScan, candidate: candidate)
            guard let result, result != snapshot else { return }
            snapshot = result
            Log.debug("codex usage: \(result.windows.map { "\($0.windowMinutes ?? 0)m \(Int($0.usedPercent))%" })")
            onChange?(result)
        }
    }
}

/// All file work, off the main actor. Serial by being an actor; no read overlaps another.
actor CodexRolloutWorker {
    private struct Stamp: Equatable {
        var modified: Date
        var size: UInt64
    }

    private var home: URL
    /// Newest rollouts from the last walk (newest first), and files seen since.
    private var candidates: [URL] = []
    private var stamps: [URL: Stamp] = [:]
    /// What each file looked like when its tail was last read.
    private var readStamps: [URL: Stamp] = [:]
    private var lastGood: CodexRateLimits?
    private var scanned = false

    /// How many of the newest files a check may read before giving up on older ones.
    static let fallbackDepth = 4

    init(home: URL) {
        self.home = home
    }

    func setHome(_ home: URL) {
        guard home != self.home else { return }
        self.home = home
        candidates = []
        stamps = [:]
        readStamps = [:]
        scanned = false
    }

    /// The newest `codex` bucket snapshot, or nil when nothing changed since the last call.
    func check(fullScan: Bool, candidate: URL?) -> CodexRateLimits? {
        if fullScan || !scanned {
            candidates = CodexRollouts.newest(in: CodexHome.sessions(home), limit: 8).map(\.url)
            scanned = true
        }
        if let candidate, CodexRollouts.isRollout(candidate) {
            candidates.removeAll { $0 == candidate }
            candidates.insert(candidate, at: 0)
        }
        // Newest first by the files' current mtimes (a resumed session may have moved ahead).
        var current: [(URL, Stamp)] = candidates.compactMap { url in stamp(url).map { (url, $0) } }
        current.sort { $0.1.modified > $1.1.modified }
        candidates = current.map(\.0)

        let before = lastGood
        for (url, stamp) in current.prefix(Self.fallbackDepth) {
            if readStamps[url] == stamp {
                // Unchanged since it was read: whatever it had is already in `lastGood` (or it had nothing).
                if lastGood != nil { break }
                continue
            }
            readStamps[url] = stamp
            if let found = CodexRollouts.readTail(of: url)[CodexRateLimits.mainLimitID] {
                if lastGood.map({ found.capturedAt >= $0.capturedAt }) ?? true { lastGood = found }
                break
            }
        }
        if readStamps.count > 64 { readStamps = readStamps.filter { candidates.contains($0.key) } }
        return lastGood != before ? lastGood : nil
    }

    private func stamp(_ url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        return Stamp(modified: modified, size: size)
    }
}

/// FSEvents on Codex's `sessions/` (file-level, 1.5 s latency: an active turn's many writes arrive as about one
/// callback). Reports the last rollout path in each batch, or nil when the batch needs a rescan.
final class CodexRolloutWatcher: @unchecked Sendable {
    /// Called on a private queue.
    var onRollout: ((URL?) -> Void)?
    private var stream: FSEventStreamRef?
    /// The stream's reference to this watcher, released once the stream is gone (a callback may be running).
    private var info: UnsafeMutableRawPointer?
    private let queue = DispatchQueue(label: "me.sokolov.notchbuddy.codex-usage", qos: .utility)

    func start(path: URL) {
        stop()
        let info = Unmanaged.passRetained(self).toOpaque()
        var context = FSEventStreamContext(version: 0, info: info, retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<CodexRolloutWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let rescan = (0..<count).contains { i in
                flags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0
            }
            if rescan {
                me.onRollout?(nil)
            } else if let path = list.last(where: { CodexRollouts.isRollout(URL(fileURLWithPath: $0)) }) {
                me.onRollout?(URL(fileURLWithPath: path))
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.5, flags) else {
            Unmanaged<CodexRolloutWatcher>.fromOpaque(info).release()
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
        self.info = info
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        if let info {
            self.info = nil
            // After any callback already queued.
            queue.async { Unmanaged<CodexRolloutWatcher>.fromOpaque(info).release() }
        }
    }
}
