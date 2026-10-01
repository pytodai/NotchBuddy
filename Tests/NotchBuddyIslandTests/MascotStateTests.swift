import NotchBuddyCore
import QuartzCore
import XCTest
@testable import NotchBuddy

/// Which pixel-mascot animation a session shows, and where a hero slot's sprite lands.
final class MascotStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testTurnMapsToMascot() {
        var store = SessionStore()
        func apply(_ kind: EventKind, at offset: TimeInterval, tool: String? = nil) -> MascotState? {
            store.apply(AgentEvent(source: .claude, hookEventName: kind.rawValue, kind: kind, sessionId: "s",
                                   cwd: "/Users/u/proj", toolName: tool, timestamp: t0.addingTimeInterval(offset)))
            return store.sessions.values.first.map { MascotState(session: $0) }
        }
        XCTAssertEqual(apply(.promptSubmitted, at: 0), .thinking, "nothing ran yet: thinking")
        XCTAssertEqual(apply(.toolWillRun, at: 1, tool: "Bash"), .working)
        XCTAssertEqual(apply(.toolDidRun, at: 2, tool: "Bash"), .working, "between tool calls it keeps working")
        XCTAssertEqual(apply(.stop, at: 3), .done)
        XCTAssertEqual(apply(.promptSubmitted, at: 4), .thinking, "a new turn thinks again")
        XCTAssertEqual(apply(.permissionRequest, at: 5, tool: "Edit"), .waiting)
        XCTAssertEqual(apply(.toolDidRun, at: 6, tool: "Edit"), .working, "an answered request runs its tool")
        XCTAssertEqual(apply(.stopFailed, at: 7), .error)
        XCTAssertEqual(apply(.interrupted, at: 8), .idle)
    }

    /// Claude, Codex and Kimi have their own characters; the catalog's other agents get the generic blob.
    func testCharacterPerAgent() {
        XCTAssertEqual(MascotCharacter(agent: .claude), .claude)
        XCTAssertEqual(MascotCharacter(agent: .codex), .codex)
        XCTAssertEqual(MascotCharacter(agent: .kimi), .kimi)
        for agent in [AgentSource.cursor, .copilot, .cline, .grok] {
            XCTAssertEqual(MascotCharacter(agent: agent), .generic, agent.rawValue)
        }
        XCTAssertEqual(MascotCharacter(agent: AgentSource(rawValue: "future-agent")!), .generic)
    }

    func testIntroOnlyForAFreshState() throws {
        var store = SessionStore()
        store.apply(AgentEvent(source: .codex, hookEventName: "Stop", kind: .stop, sessionId: "s", cwd: "/Users/u/proj",
                               timestamp: t0))
        let session = try XCTUnwrap(store.sessions.values.first)
        XCTAssertTrue(session.mascotIntroIsFresh(now: t0.addingTimeInterval(1)))
        XCTAssertFalse(session.mascotIntroIsFresh(now: t0.addingTimeInterval(60)))
    }

    /// The flying mascot hands its frames to the render server (a discrete `contentsRect` loop, plus the intro for a
    /// fresh "done"), holds a still frame while paused, and a repeated state commits nothing new.
    @MainActor
    func testHeroMarkPlaysInRenderServer() throws {
        let hero = HeroMark(key: SessionKey(source: .codex, sessionId: "s"), rect: CGRect(x: 0, y: 0, width: 30, height: 30),
                            at: CACurrentMediaTime())
        hero.show(.working, fresh: false, running: true)
        let loop = try XCTUnwrap(hero.layer.animation(forKey: MascotAnimator.loopKey) as? CAKeyframeAnimation)
        XCTAssertEqual(loop.keyPath, "contentsRect")
        XCTAssertEqual(loop.calculationMode, .discrete)
        XCTAssertNil(hero.layer.animation(forKey: MascotAnimator.introKey))

        hero.show(.done, fresh: false, running: true)
        XCTAssertNotNil(hero.layer.animation(forKey: MascotAnimator.introKey), "a change of state plays its intro")

        hero.show(.done, fresh: false, running: false)
        XCTAssertNil(hero.layer.animationKeys(), "paused: nothing animates")
        hero.show(.done, fresh: false, running: true)
        XCTAssertNotNil(hero.layer.animation(forKey: MascotAnimator.loopKey))
        XCTAssertNil(hero.layer.animation(forKey: MascotAnimator.introKey), "resuming does not replay the intro")
    }

    /// A hero slot reports the square its sprite is drawn in: whole device pixels per art pixel, on whole pixels.
    func testSlotReportsCrispSprite() {
        let rect = HeroSlot.sprite(in: CGRect(x: 10.3, y: 4.1, width: 28, height: 28), scale: 2)
        XCTAssertEqual(rect.width, 30)
        XCTAssertEqual(rect.height, 30)
        XCTAssertEqual(rect.minX * 2, (rect.minX * 2).rounded())
        XCTAssertEqual(rect.minY * 2, (rect.minY * 2).rounded())
        XCTAssertEqual(rect.midX, 24.3, accuracy: 0.25)
        XCTAssertEqual(HeroSlot.sprite(in: CGRect(x: 0, y: 0, width: 28, height: 28), scale: 1).width, 20)
        XCTAssertEqual(HeroSlot.sprite(in: CGRect(x: 0, y: 0, width: 34, height: 34), scale: 2).width, 30)
    }
}
