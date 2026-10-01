import XCTest
@testable import NotchBuddyCore

/// The open `AgentSource`, the catalog lookups, hook-bleed detection and install detection.
final class AgentCatalogTests: XCTestCase {
    // MARK: AgentSource

    func testCodableFormIsABareStringLikeTheOldEnum() throws {
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(AgentSource.claude), as: UTF8.self), #""claude""#)
        XCTAssertEqual(try JSONDecoder().decode(AgentSource.self, from: Data(#""codex""#.utf8)), .codex)
        let key = SessionKey(source: .kimi, sessionId: "s1")
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(key), as: UTF8.self).contains(#""source":"kimi""#), true)
        XCTAssertEqual(try JSONDecoder().decode(SessionKey.self, from: JSONEncoder().encode(key)), key)
        // New ids travel over the same wire.
        let event = AgentEvent(source: .cursor, hookEventName: "stop", kind: .stop, sessionId: "c1")
        let frame = try JSONEncoder().encode(BridgeRequest(event: event, expectsReply: false))
        XCTAssertEqual(try JSONDecoder().decode(BridgeRequest.self, from: frame).event.source, .cursor)
        // An empty id never decodes.
        XCTAssertThrowsError(try JSONDecoder().decode(AgentSource.self, from: Data(#""""#.utf8)))
    }

    func testRawValueValidation() {
        XCTAssertEqual(AgentSource(rawValue: "Cursor"), .cursor)
        XCTAssertNil(AgentSource(rawValue: ""))
        XCTAssertNil(AgentSource(rawValue: "a b"))
        XCTAssertNil(AgentSource(rawValue: "../x"))
        XCTAssertNotNil(AgentSource(rawValue: "qwen-code_2"))
    }

    func testOriginalThreeStayTheBuiltInList() {
        XCTAssertEqual(AgentSource.allCases, [.claude, .codex, .kimi])
        XCTAssertEqual(AgentSource.claude.displayName, "Claude Code")
        XCTAssertEqual(AgentSource.codex.displayName, "Codex")
        XCTAssertEqual(AgentSource.kimi.displayName, "Kimi Code")
        XCTAssertEqual(AgentSource(rawValue: "someday")?.displayName, "someday")
        XCTAssertTrue(AgentSource.allCases.allSatisfy { AgentCatalog.descriptor(for: $0)?.settingsOnly == false })
    }

    func testCatalogAgentsAreSettingsOnlyAndListed() {
        for source in [AgentSource.cursor, .copilot, .cline, .grok] {
            let d = AgentCatalog.descriptor(for: source)
            XCTAssertEqual(d?.settingsOnly, true, source.rawValue)
            XCTAssertNotNil(d?.install, source.rawValue)
            XCTAssertNotNil(d?.capabilityNote, source.rawValue)
        }
        XCTAssertEqual(AgentCatalog.settingsAgents, [.claude, .codex, .kimi, .cursor, .copilot, .cline, .grok])
        XCTAssertEqual(Set(AgentCatalog.all.map(\.id)).count, AgentCatalog.all.count)
    }

    func testFactoriesFollowTheCatalog() {
        XCTAssertTrue(Adapters.adapter(for: .claude) is ClaudeAdapter)
        XCTAssertTrue(Adapters.adapter(for: .cursor) is CursorAdapter)
        XCTAssertTrue(Adapters.adapter(for: .cline) is ClineAdapter)
        XCTAssertEqual((Adapters.adapter(for: .copilot) as? ClaudeCompatibleAdapter)?.source, .copilot)
        XCTAssertEqual((Adapters.adapter(for: .grok) as? ClaudeCompatibleAdapter)?.source, .grok)
        let unknown = Adapters.adapter(for: AgentSource(rawValue: "nobody")!)
        XCTAssertThrowsError(try unknown.normalize(stdin: Data("{}".utf8), host: HostContext()))

        let home = FileManager.default.temporaryDirectory
        XCTAssertTrue(HookInstallers.installer(for: .kimi, home: home) is KimiHookInstaller)
        XCTAssertTrue(HookInstallers.installer(for: .cursor, home: home) is CursorHookInstaller)
        XCTAssertTrue(HookInstallers.installer(for: .cline, home: home) is ClineHookInstaller)
        XCTAssertEqual((HookInstallers.installer(for: .grok, home: home) as? DropInHookInstaller)?.spec.path,
                       ".grok/hooks/notchbuddy.json")
        XCTAssertEqual(HookInstallers.installer(for: AgentSource(rawValue: "nobody")!, home: home).status(), .agentMissing)
    }

    // MARK: Hook bleed

    func testCursorRunningClaudeHooksIsDropped() {
        let cursorPayload: JSONValue = ["hook_event_name": "sessionStart", "session_id": "c1", "cursor_version": "3.15.6"]
        XCTAssertEqual(AgentCatalog.foreignHost(for: .claude, payload: cursorPayload, env: [:]), .cursor)
        // Cursor's own hooks are its own.
        XCTAssertNil(AgentCatalog.foreignHost(for: .cursor, payload: cursorPayload, env: [:]))
    }

    func testGrokRunningClaudeOrCursorHooksIsDropped() {
        let env = ["GROK_HOOK_EVENT": "pre_tool_use", "GROK_SESSION_ID": "g1"]
        let payload: JSONValue = ["hookEventName": "pre_tool_use", "sessionId": "g1"]
        XCTAssertEqual(AgentCatalog.foreignHost(for: .claude, payload: payload, env: env), .grok)
        XCTAssertEqual(AgentCatalog.foreignHost(for: .cursor, payload: payload, env: env), .grok)
        XCTAssertNil(AgentCatalog.foreignHost(for: .grok, payload: payload, env: env))
    }

    func testRealClaudeIsNeverDropped() {
        let payload: JSONValue = ["hook_event_name": "Stop", "session_id": "abc"]
        XCTAssertNil(AgentCatalog.foreignHost(for: .claude, payload: payload, env: [:]))
        XCTAssertNil(AgentCatalog.foreignHost(for: .codex, payload: payload, env: ["TERM_PROGRAM": "vscode"]))
        // Claude's own proof wins even if a marker of another host leaked into the environment.
        let env = ["CLAUDE_CODE_SESSION_ID": "abc", "GROK_HOOK_EVENT": "stop"]
        XCTAssertNil(AgentCatalog.foreignHost(for: .claude, payload: payload, env: env))
        XCTAssertNil(AgentCatalog.foreignHost(for: .claude, payload: nil, env: [:]))
    }

    // MARK: Detection

    func testDetectionNeedsABinaryOrAnAppNotJustAConfigDir() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nb-detect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home"), root = base.appendingPathComponent("root")
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent(".grok/hooks"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let detector = AgentDetector(home: home, root: root)
        XCTAssertFalse(detector.isInstalled(.grok), "config dir alone")
        XCTAssertFalse(detector.isInstalled(.cursor))
        XCTAssertFalse(detector.isInstalled(.cline))

        let grok = home.appendingPathComponent(".grok/bin/grok")
        try fm.createDirectory(at: grok.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: grok.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        XCTAssertTrue(detector.isInstalled(.grok))

        try fm.createDirectory(at: root.appendingPathComponent("Applications/Cursor.app"), withIntermediateDirectories: true)
        XCTAssertTrue(detector.isInstalled(.cursor))

        try fm.createDirectory(at: home.appendingPathComponent(".vscode/extensions/saoudrizwan.claude-dev-4.1.20"),
                               withIntermediateDirectories: true)
        XCTAssertTrue(detector.isInstalled(.cline))
    }
}
