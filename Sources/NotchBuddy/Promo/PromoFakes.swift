import AppKit
import NotchBuddyCore

/// The promo's sessions, cards and usage: built through the real `SessionStore` from hook events, like the live app,
/// in the render's language. `now` is the video's time 0 (clocks on the island tick with the film).
///
/// Every agent only does what it really can: Claude and Codex send their last answer with `Stop` (the done card and
/// the list's answer line), Kimi's `Stop` has no text, Kimi's requests are never answered on the island.
@MainActor
struct PromoFakes {
    let now: Date
    let lang: PromoLanguage
    private var sessions: [PromoScene: [AgentSession]] = [:]
    private(set) var card: PermissionCardInfo
    private(set) var doneNotice: FlashNotice
    let usage: UsageState
    let agentUsages: [AgentUsage]

    static let claude = SessionKey(source: .claude, sessionId: "promo-claude")
    static let codex = SessionKey(source: .codex, sessionId: "promo-codex")
    static let kimi = SessionKey(source: .kimi, sessionId: "promo-kimi")

    init(now: Date, lang: PromoLanguage) {
        self.now = now
        self.lang = lang
        let en = lang == .en
        // A neutral home folder: nothing of the machine that renders the film shows up in it.
        let home = "/Users/you"
        let claudeCwd = "\(home)/code/weather-app", codexCwd = "\(home)/code/api-gateway", kimiCwd = "\(home)/code/landing"
        var store = SessionStore(staleAfter: .greatestFiniteMagnitude, workingTimeout: .greatestFiniteMagnitude)
        func event(_ key: SessionKey, _ kind: EventKind, cwd: String, at offset: TimeInterval, tool: String? = nil,
                   summary: String? = nil, message: String? = nil, title: String? = nil) {
            store.apply(AgentEvent(source: key.source, hookEventName: "\(kind)", kind: kind, sessionId: key.sessionId,
                                   cwd: cwd, toolName: tool, toolSummary: summary, message: message,
                                   timestamp: now.addingTimeInterval(offset), sessionTitle: title))
        }
        func snap(_ keys: [SessionKey]) -> [AgentSession] { SessionStore.ordered(keys.compactMap { store.sessions[$0] }) }

        // Claude: reworking the charts for a couple of minutes.
        event(Self.claude, .sessionStart, cwd: claudeCwd, at: -140, title: en ? "Smoother charts" : "Плавные графики")
        event(Self.claude, .promptSubmitted, cwd: claudeCwd, at: -134,
              message: en ? "Make the charts animate with one spring and a soft blur"
                          : "Сделай анимацию графиков одной пружиной и с мягким блюром")
        event(Self.claude, .toolWillRun, cwd: claudeCwd, at: -4, tool: "Bash", summary: "swift build -c release")
        sessions[.first] = snap([Self.claude])

        // Codex finished a while ago and said what it did; Kimi is editing.
        event(Self.codex, .sessionStart, cwd: codexCwd, at: -610, title: en ? "Flaky tests" : "Падающие тесты")
        event(Self.codex, .promptSubmitted, cwd: codexCwd, at: -600, message: en ? "Fix the flaky tests" : "Почини падающие тесты")
        event(Self.codex, .toolWillRun, cwd: codexCwd, at: -40, tool: "exec_command", summary: "npm test -- --watch=false")
        event(Self.codex, .stop, cwd: codexCwd, at: PromoStoryboard.trioAt,
              message: en ? "All 48 tests pass now: the flaky one was a race in the retry timer."
                          : "Все 48 тестов проходят: падал тот, где гонка в таймере повторов.")
        event(Self.kimi, .sessionStart, cwd: kimiCwd, at: -910, title: en ? "Hero section" : "Hero-блок")
        event(Self.kimi, .promptSubmitted, cwd: kimiCwd, at: -900,
              message: en ? "Refresh the hero section for mobile" : "Обнови hero-блок под мобильные")
        event(Self.kimi, .toolWillRun, cwd: kimiCwd, at: PromoStoryboard.trioAt + 0.8, tool: "WriteFile", summary: "src/components/Hero.tsx")
        sessions[.trio] = snap([Self.claude, Self.codex, Self.kimi])

        // The card: Claude wants to push.
        let command = "git push origin feat/smooth-charts"
        let push = AgentEvent(
            source: .claude, hookEventName: "PermissionRequest", kind: .permissionRequest, sessionId: Self.claude.sessionId,
            cwd: claudeCwd, toolName: "Bash", toolSummary: command, decisionSupported: true, canAlwaysAllow: true,
            timestamp: now.addingTimeInterval(PromoStoryboard.cardAt),
            raw: .object(["tool_input": .object([
                "command": .string(command),
                "description": .string(en ? "Push the branch to GitHub" : "Отправить ветку на GitHub"),
            ])]))
        card = PermissionCardInfo(id: push.id, event: push, receivedAt: now.addingTimeInterval(PromoStoryboard.cardAt),
                                  projectTitle: "weather-app")
        var waiting = store
        waiting.apply(push)
        sessions[.card] = SessionStore.ordered([Self.claude, Self.codex, Self.kimi].compactMap { waiting.sessions[$0] })

        event(Self.claude, .toolWillRun, cwd: claudeCwd, at: PromoStoryboard.approveAt - 0.15, tool: "Bash", summary: command)
        sessions[.approved] = snap([Self.claude, Self.codex, Self.kimi])

        let answer = en
            ? "Done! The charts now animate on a single spring with a soft blur-in.\n\n- One spring per change, retargeted with its speed\n- Bars and labels reveal along the same curve\n\nThe build passes, all 214 tests are green and the branch is pushed."
            : "Готово! Графики теперь анимируются одной пружиной с мягким блюром.\n\n- Одна пружина на изменение, со скоростью при смене цели\n- Столбцы и подписи проявляются по той же кривой\n\nСборка проходит, все 214 тестов зелёные, ветка отправлена."
        event(Self.claude, .stop, cwd: claudeCwd, at: PromoStoryboard.doneAt, message: answer)
        sessions[.done] = snap([Self.claude, Self.codex, Self.kimi])
        sessions[.settled] = sessions[.done]
        // As `AppModel` makes it on `Stop`: the session's title, "<agent> — готово", the answer it keeps.
        let finished = store.sessions[Self.claude]
        doneNotice = FlashNotice(key: Self.claude, kind: .finished, title: finished?.title ?? "weather-app",
                                 detail: L("%@ — готово", AgentSource.claude.displayName),
                                 reply: finished?.lastAgentMessage ?? answer)

        usage = .loaded(UsageSnapshot(
            fiveHour: UsageWindow(utilization: 42, resetsAt: now.addingTimeInterval(2 * 3600 + 600)),
            sevenDay: UsageWindow(utilization: 18, resetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600)), fetchedAt: now))
        agentUsages = [
            .claude(fiveHour: (42, now.addingTimeInterval(2 * 3600 + 600)),
                    sevenDay: (18, now.addingTimeInterval(3 * 86400 + 4 * 3600)), fetchedAt: now),
            AgentUsage(agent: .codex, windows: [
                AgentUsageWindow(id: "5h", used: 23, resetsAt: now.addingTimeInterval(3 * 3600 + 1500), minutes: 300),
                AgentUsageWindow(id: "7d", used: 14, resetsAt: now.addingTimeInterval(5 * 86400 + 7200), minutes: 10080),
            ], plan: "Plus", fetchedAt: now),
            AgentUsage(agent: .kimi, windows: [
                AgentUsageWindow(id: "5h", used: 8, resetsAt: now.addingTimeInterval(4 * 3600 + 900), minutes: 300),
                AgentUsageWindow(id: "7d", used: 31, resetsAt: now.addingTimeInterval(2 * 86400 + 3 * 3600), minutes: 10080),
            ], fetchedAt: now),
        ]
    }

    func snapshot(_ scene: PromoScene, usageChoice: UsageProviderChoice) -> IslandSnapshot {
        var s = IslandSnapshot(sessions: sessions[scene] ?? [], usage: usage)
        s.agentUsages = agentUsages
        s.usageChoice = usageChoice
        switch scene {
        case .card:
            s.card = card
            s.cardCount = 1
            s.cardIDs = [card.id]
        case .done:
            s.flash = doneNotice
            // The turn's length ("за 2:30"), as the controller passes it.
            s.flashDuration = 150
        case .empty, .first, .trio, .approved, .settled:
            break
        }
        return s
    }
}
