import Foundation
import NotchBuddyCore

// Which mascot animation a session shows on the island.
//
//   working, a tool ran this turn   → .working  (typing / pattering)
//   working, nothing ran yet        → .thinking (eyes up, "…"): the prompt was just sent, the model is reading
//   waiting for you                 → .waiting  (hopping "!")
//   finished                        → .done     (jump + sparkle once, then a content glow)
//   error                           → .error    (wince and fall once, then a grey slump)
//   idle                            → .idle     (breathing, a blink)
//
// "Thinking" turns into "working" at the turn's first tool call and stays there until the turn ends, so the
// mascot does not flicker between the two on every quick tool call.

extension MascotState {
    init(session: AgentSession) {
        if session.status == .working, session.isThinking {
            self = .thinking
        } else {
            self.init(status: session.status)
        }
    }
}

extension AgentSession {
    /// Working, and no tool has started, run or finished since it started working: the model is thinking.
    var isThinking: Bool {
        guard status == .working else { return false }
        let since = statusMoment.monotonic
        return !recentTools.calls.contains { call in
            call.isRunning || call.started.monotonic >= since || (call.finished?.monotonic ?? -.infinity) >= since
        }
    }

    /// Its status changed a moment ago: a mascot that appears now plays the state's intro (done's jump, error's
    /// fall). One built later for an old state (the list opening minutes after a session finished) shows it quietly.
    func mascotIntroIsFresh(now: Date = Date()) -> Bool {
        now.timeIntervalSince(statusSince) < 3
    }
}

extension IslandSnapshot {
    /// The mascot a session shows: its own state, or "waiting" for the session of a permission card that is not
    /// (or no longer) listed.
    func mascot(for key: SessionKey) -> MascotState? {
        if let session = session(key) { return MascotState(session: session) }
        if card?.event.sessionKey == key { return .waiting }
        return nil
    }

    /// Whether a mascot appearing now for `key` plays its state's intro.
    func mascotIntroIsFresh(for key: SessionKey, now: Date = Date()) -> Bool {
        session(key)?.mascotIntroIsFresh(now: now) ?? true
    }

    /// The mascot of each flying hero.
    func heroMascots(_ heroes: [HeroSubject]) -> [SessionKey: MascotState] {
        var result: [SessionKey: MascotState] = [:]
        for hero in heroes {
            if let state = mascot(for: hero.id) { result[hero.id] = state }
        }
        return result
    }
}
