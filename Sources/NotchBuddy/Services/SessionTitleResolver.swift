import Foundation
import NotchBuddyCore

/// Finds the chat titles no hook event carries and hands them to `AppModel`:
/// - Claude: the title records in each session's transcript (`AgentSession.transcriptPath`);
/// - Codex: `thread_name` in `$CODEX_HOME/session_index.jsonl` (the hook's `session_id` is the thread id).
/// Kimi's title comes with its events (`SessionStore`).
///
/// Files are read on a background queue, only when their size, mtime or identity changed, and then only what was
/// appended (Claude: at most the last 64 KB). Each session (and the Codex index) is checked at most once per
/// `minInterval`: on its hook events, and by a timer that runs while such sessions exist, so a title written
/// after the turn's last event still shows up.
@MainActor
final class SessionTitleResolver {
    static let minInterval: TimeInterval = 5

    /// Receives each title found (on the main actor). `AppModel` wires it to `setChatTitle(_:for:)`.
    var onTitle: (@MainActor (String, SessionKey) -> Void)?
    /// The sessions to name. `AppModel` wires it to its store.
    var sessions: @MainActor () -> [AgentSession] = { [] }

    private let clock: AppClock
    private let files: TitleFiles
    private var active = false
    private var timer: Timer?
    /// Monotonic seconds of each session's last check, and of the Codex index's.
    private var lastCheck: [SessionKey: TimeInterval] = [:]
    private var lastCodexCheck = -TimeInterval.infinity
    private var inFlight: Set<SessionKey> = []
    private var codexInFlight = false

    init(clock: AppClock = .system, codexIndexPath: String = CodexSessionIndex.defaultPath()) {
        self.clock = clock
        files = TitleFiles(codexIndexPath: codexIndexPath)
    }

    /// Starts checking (nothing is read before this: previews and tests build models without starting them).
    func start() {
        guard !active else { return }
        active = true
        tick()
    }

    func stop() {
        active = false
        timer?.invalidate()
        timer = nil
    }

    /// A hook event touched `session`: check its title now, unless it was checked within `minInterval`.
    func sessionUpdated(_ session: AgentSession) {
        guard active, Self.needsLookup(session) else { return }
        let now = clock.now().monotonic
        check(session, now: now)
        updateTimer(needed: true)
    }

    // MARK: Internals

    /// Sessions whose title lives in a file: Claude with a transcript, and every Codex session.
    private static func needsLookup(_ s: AgentSession) -> Bool {
        switch s.source {
        case .claude: return s.transcriptPath?.isEmpty == false
        case .codex: return true
        default: return false  // Kimi and catalog agents: titles come in the payload or from the first prompt
        }
    }

    private func tick() {
        guard active else { return }
        let current = sessions().filter(Self.needsLookup)
        forgetAllBut(current)
        let now = clock.now().monotonic
        for session in current { check(session, now: now) }
        updateTimer(needed: !current.isEmpty)
    }

    private func check(_ session: AgentSession, now: TimeInterval) {
        switch session.source {
        case .claude:
            guard let path = session.transcriptPath, !inFlight.contains(session.key),
                  now - (lastCheck[session.key] ?? -.infinity) >= Self.minInterval else { return }
            lastCheck[session.key] = now
            inFlight.insert(session.key)
            let key = session.key
            files.claudeTitle(path: path) { [weak self] title in
                Task { @MainActor in
                    guard let self else { return }
                    self.inFlight.remove(key)
                    guard self.active, let title,
                          let session = self.sessions().first(where: { $0.key == key }) else { return }
                    self.deliver(title, to: session)
                }
            }
        case .codex:
            guard !codexInFlight, now - lastCodexCheck >= Self.minInterval else { return }
            lastCodexCheck = now
            codexInFlight = true
            files.codexNames { [weak self] names in
                Task { @MainActor in
                    guard let self else { return }
                    self.codexInFlight = false
                    guard self.active, !names.isEmpty else { return }
                    for s in self.sessions() where s.source == .codex {
                        if let name = names[s.key.sessionId] { self.deliver(name, to: s) }
                    }
                }
            }
        default:
            break
        }
    }

    /// Hands over a title unless the session already has it.
    private func deliver(_ title: String, to session: AgentSession) {
        guard session.chatTitle != title else { return }
        onTitle?(title, session.key)
    }

    /// Drops the state of sessions that went away (and their transcripts' cached reads).
    private func forgetAllBut(_ current: [AgentSession]) {
        let keys = Set(current.map(\.key))
        lastCheck = lastCheck.filter { keys.contains($0.key) }
        files.keepTranscripts(Set(current.compactMap { $0.source == .claude ? $0.transcriptPath : nil }))
    }

    private func updateTimer(needed: Bool) {
        if needed, timer == nil {
            let t = Timer.scheduledTimer(withTimeInterval: Self.minInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            t.tolerance = 1
            timer = t
        } else if !needed, let t = timer {
            t.invalidate()
            timer = nil
        }
    }
}

/// The file trackers, used only on `queue` (never on the main thread).
private final class TitleFiles: @unchecked Sendable {
    private let queue = DispatchQueue(label: "me.sokolov.notchbuddy.session-titles", qos: .utility)
    private var transcripts: [String: ClaudeTranscriptTitle.Tracker] = [:]
    private var codex: CodexSessionIndex.Tracker

    init(codexIndexPath: String) {
        codex = CodexSessionIndex.Tracker(path: codexIndexPath)
    }

    /// The best title in the transcript at `path` (re-read only if it changed), or nil if none was found yet.
    func claudeTitle(path: String, completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            var tracker = self.transcripts[path] ?? ClaudeTranscriptTitle.Tracker(path: path)
            tracker.refresh()
            self.transcripts[path] = tracker
            completion(tracker.titles.best)
        }
    }

    /// Every thread name in the Codex index (re-read only if it changed).
    func codexNames(completion: @escaping @Sendable ([String: String]) -> Void) {
        queue.async {
            self.codex.refresh()
            completion(self.codex.names)
        }
    }

    /// Forgets the transcripts not in `paths`.
    func keepTranscripts(_ paths: Set<String>) {
        queue.async {
            guard self.transcripts.keys.contains(where: { !paths.contains($0) }) else { return }
            self.transcripts = self.transcripts.filter { paths.contains($0.key) }
        }
    }
}
