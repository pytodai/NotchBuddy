import XCTest
@testable import NotchBuddyCore

/// Installers of the catalog agents, against a temporary home; the real ~/.cursor, ~/.copilot, ~/.grok and
/// ~/Documents/Cline are never touched.
final class CatalogHookInstallerTests: XCTestCase {
    private var home: URL!
    private var bridge: String { home.appendingPathComponent(".notchbuddy/bin/notchbuddy-bridge").path }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("nb-catalog-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    private func makeExecutable(_ relative: String) throws {
        let url = home.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755]))
    }

    private func backups() -> [String] {
        let dir = home.appendingPathComponent(".notchbuddy/backups")
        let stamps = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return stamps.flatMap { (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent($0).path)) ?? [] }
    }

    private func json(_ url: URL) throws -> JSONValue { try JSONValue.parse(Data(contentsOf: url)) }

    func testGuardedCommandMatchesTheOriginalShape() {
        XCTAssertEqual(HookInstallers.guardedCommand(bridgePath: "/b/notchbuddy-bridge", source: .claude),
                       ClaudeHookInstaller.hookCommand(bridgePath: "/b/notchbuddy-bridge"))
        XCTAssertEqual(HookInstallers.guardedCommand(bridgePath: "/it's/notchbuddy-bridge", source: .grok),
                       #"/bin/sh -c '[ -x "/it'\''s/notchbuddy-bridge" ] && "/it'\''s/notchbuddy-bridge" --source grok; exit 0'"#)
    }

    // MARK: Drop-in files (Grok, Copilot)

    func testGrokDropInLifecycle() throws {
        let installer = HookInstallers.installer(for: .grok, home: home)
        XCTAssertEqual(installer.status(), .agentMissing, "no grok binary")
        try makeExecutable(".grok/bin/grok")
        XCTAssertEqual(installer.status(), .notInstalled)

        try installer.install(bridgePath: bridge)
        XCTAssertEqual(installer.status(), .installed)
        let file = home.appendingPathComponent(".grok/hooks/notchbuddy.json")
        let root = try json(file)
        let group = try XCTUnwrap(root.at("hooks", "PreToolUse")?.array?.first)
        XCTAssertNil(group["matcher"], "Grok rejects matchers on lifecycle events; none are written")
        XCTAssertEqual(group["hooks"]?.array?.first?["timeout"]?.double, 5)
        XCTAssertEqual(group["hooks"]?.array?.first?["command"]?.string,
                       HookInstallers.guardedCommand(bridgePath: bridge, source: .grok))
        XCTAssertEqual(root["hooks"]?.object?.count, DropInHooksSpec.grok.events.count)

        let before = try Data(contentsOf: file)
        try installer.install(bridgePath: bridge)
        XCTAssertEqual(try Data(contentsOf: file), before, "idempotent")
        XCTAssertTrue(backups().isEmpty, "nothing overwritten, nothing backed up")

        try installer.uninstall()
        XCTAssertFalse(fm.fileExists(atPath: file.path))
        XCTAssertEqual(backups().count, 1)
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    func testDropInNeverDeletesAForeignFileAtItsPath() throws {
        try makeExecutable(".grok/bin/grok")
        let file = home.appendingPathComponent(".grok/hooks/notchbuddy.json")
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"hooks":{}}"#.utf8).write(to: file)
        let installer = HookInstallers.installer(for: .grok, home: home)
        XCTAssertEqual(installer.status(), .notInstalled)
        try installer.uninstall()
        XCTAssertTrue(fm.fileExists(atPath: file.path))
        try Data("not json".utf8).write(to: file)
        if case .error = installer.status() {} else { XCTFail("unparsable file must report an error") }
    }

    func testCopilotDropInCarriesKeysForBothHosts() throws {
        try fm.createDirectory(at: home.appendingPathComponent("Applications/Visual Studio Code.app"),
                               withIntermediateDirectories: true)
        let installer = HookInstallers.installer(for: .copilot, home: home)
        XCTAssertEqual(installer.status(), .notInstalled)
        // Another tool's drop-in next to ours is left alone.
        let foreign = home.appendingPathComponent(".copilot/hooks/other-tool.json")
        try fm.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"hooks":{"Stop":[{"type":"command","command":"other"}]}}"#.utf8).write(to: foreign)

        try installer.install(bridgePath: bridge)
        XCTAssertEqual(installer.status(), .installed)
        let root = try json(home.appendingPathComponent(".copilot/hooks/notchbuddy.json"))
        XCTAssertEqual(root["version"]?.double, 1)
        let permission = try XCTUnwrap(root.at("hooks", "PermissionRequest")?.array?.first)
        XCTAssertEqual(permission["type"]?.string, "command")
        XCTAssertEqual(permission["command"]?.string, permission["bash"]?.string)
        XCTAssertEqual(permission["timeout"]?.double, 900)
        XCTAssertEqual(permission["timeoutSec"]?.double, 900)
        XCTAssertEqual(root.at("hooks", "Stop")?.array?.first?["timeout"]?.double, 10)
        XCTAssertTrue(permission["command"]?.string?.contains("--source copilot") ?? false)

        try installer.uninstall()
        XCTAssertTrue(fm.fileExists(atPath: foreign.path))
    }

    // MARK: Cursor

    /// A third-party tool's handlers in ~/.cursor/hooks.json.
    private static let foreignCursorHooks = """
    {
      "version": 1,
      "hooks": {
        "stop": [
          {
            "command": "/Users/me/.other-tool/bin/other-tool-bridge --source cursor"
          }
        ],
        "afterAgentResponse": [
          {
            "command": "/Users/me/.other-tool/bin/other-tool-bridge --source cursor"
          }
        ]
      }
    }

    """

    func testCursorMergesIntoTheSharedFile() throws {
        let installer = CursorHookInstaller(home: home)
        XCTAssertEqual(installer.status(), .agentMissing)
        try makeExecutable(".local/bin/cursor-agent")
        XCTAssertEqual(installer.status(), .notInstalled)

        let file = installer.hooksURL
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.foreignCursorHooks.utf8).write(to: file)
        XCTAssertEqual(installer.status(), .notInstalled)

        try installer.install(bridgePath: bridge)
        XCTAssertEqual(installer.status(), .installed)
        let root = try json(file)
        XCTAssertEqual(root["version"]?.double, 1)
        let stop = try XCTUnwrap(root.at("hooks", "stop")?.array)
        XCTAssertEqual(stop.count, 2, "the foreign handler stays, ours is appended")
        XCTAssertEqual(stop[0]["command"]?.string, "/Users/me/.other-tool/bin/other-tool-bridge --source cursor")
        XCTAssertEqual(stop[1]["timeout"]?.double, 5)
        XCTAssertEqual(stop[1]["command"]?.string, HookInstallers.guardedCommand(bridgePath: bridge, source: .cursor))
        XCTAssertNotNil(root.at("hooks", "afterAgentResponse"))
        XCTAssertNil(root.at("hooks", "beforeReadFile"), "file contents are never requested")
        XCTAssertEqual(backups().count, 1)

        let installed = try Data(contentsOf: file)
        try installer.install(bridgePath: bridge)
        XCTAssertEqual(try Data(contentsOf: file), installed, "idempotent")
        XCTAssertEqual(backups().count, 1)

        try installer.uninstall()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), Self.foreignCursorHooks,
                       "uninstall restores the foreign file byte for byte")
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    func testCursorCreatesTheFileAndRefusesBrokenOnes() throws {
        try makeExecutable(".local/bin/cursor-agent")
        let installer = CursorHookInstaller(home: home)
        try installer.install(bridgePath: bridge)
        let root = try json(installer.hooksURL)
        XCTAssertEqual(root["version"]?.double, 1)
        XCTAssertEqual(root["hooks"]?.object?.count, CursorHookInstaller.events.count)
        try installer.uninstall()
        XCTAssertEqual(try json(installer.hooksURL)["hooks"]?.object?.count, 0)

        try Data(#"{"hooks": [1, 2]}"#.utf8).write(to: installer.hooksURL)
        XCTAssertThrowsError(try installer.install(bridgePath: bridge))
        try Data("{ nope".utf8).write(to: installer.hooksURL)
        XCTAssertThrowsError(try installer.install(bridgePath: bridge))
        if case .error = installer.status() {} else { XCTFail("unparsable file must report an error") }
        XCTAssertEqual(try String(contentsOf: installer.hooksURL, encoding: .utf8), "{ nope")
    }

    // MARK: Cline

    func testClineScriptsLifecycle() throws {
        let installer = ClineHookInstaller(home: home)
        XCTAssertEqual(installer.status(), .agentMissing)
        try fm.createDirectory(at: home.appendingPathComponent(".vscode/extensions/saoudrizwan.claude-dev-4.1.20"),
                               withIntermediateDirectories: true)
        XCTAssertEqual(installer.status(), .notInstalled)

        try installer.install(bridgePath: bridge)
        XCTAssertEqual(installer.status(), .installed)
        for url in installer.files {
            XCTAssertTrue(fm.isExecutableFile(atPath: url.path), url.lastPathComponent)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.hasPrefix("#!/bin/sh\n"))
            XCTAssertTrue(text.contains("--source cline"))
        }
        XCTAssertEqual(Set(installer.files.map(\.lastPathComponent)), Set(ClineAdapter.events))
        XCTAssertTrue(installer.files.allSatisfy { $0.path.hasSuffix("Documents/Cline/Hooks/\($0.lastPathComponent)") })

        try installer.install(bridgePath: bridge)
        XCTAssertEqual(installer.status(), .installed)

        try fm.removeItem(at: installer.files[0])
        if case .partial = installer.status() {} else { XCTFail("one file missing is partial") }

        try installer.uninstall()
        XCTAssertTrue(installer.files.allSatisfy { !fm.fileExists(atPath: $0.path) })
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    func testClineNeverOverwritesAForeignHook() throws {
        try fm.createDirectory(at: home.appendingPathComponent(".vscode/extensions/saoudrizwan.claude-dev-4.1.20"),
                               withIntermediateDirectories: true)
        let installer = ClineHookInstaller(home: home)
        let foreign = installer.hooksDir.appendingPathComponent("PreToolUse")
        try fm.createDirectory(at: installer.hooksDir, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho mine\n".utf8).write(to: foreign)
        XCTAssertThrowsError(try installer.install(bridgePath: bridge))
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), "#!/bin/sh\necho mine\n")
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: installer.hooksDir.path))?.count, 1, "nothing half-installed")
        try installer.uninstall()
        XCTAssertTrue(fm.fileExists(atPath: foreign.path))
    }
}
