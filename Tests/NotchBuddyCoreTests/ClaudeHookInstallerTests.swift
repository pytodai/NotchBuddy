import XCTest
@testable import NotchBuddyCore

/// Everything runs against a temporary home directory; the real ~/.claude is never touched.
final class ClaudeHookInstallerTests: XCTestCase {
    private var home: URL!
    private var installer: ClaudeHookInstaller!
    private var bridge: String { home.appendingPathComponent(".notchbuddy/bin/notchbuddy-bridge").path }
    private var settings: URL { installer.settingsURL }
    private var backupsDir: URL { home.appendingPathComponent(".notchbuddy/backups") }

    /// Same shape as a real-world settings.json (foreign hooks on six events, a matcher group with
    /// statusMessage, permissions, an empty object), with fake commands. JS `JSON.stringify(_, null, 2)`
    /// style without a trailing newline, like Claude Code writes it.
    private static let foreignSettings = #"""
    {
      "agentPushNotifEnabled": true,
      "effortLevel": "xhigh",
      "enabledPlugins": {
        "code-review@claude-plugins-official": true,
        "swift-lsp@claude-plugins-official": true
      },
      "hooks": {
        "Notification": [
          {
            "hooks": [
              {
                "command": "\"$HOME/Library/Application Support/fake-brightness/status.sh\" waiting",
                "timeout": 5,
                "type": "command"
              }
            ]
          }
        ],
        "PreToolUse": [
          {
            "hooks": [
              {
                "command": "python3 ~/.claude/hooks/fake-guard.py",
                "statusMessage": "Проверяю плейс",
                "timeout": 10,
                "type": "command"
              }
            ],
            "matcher": "mcp__(Studio|hub)__.*"
          }
        ],
        "SessionEnd": [
          {
            "hooks": [
              {
                "command": "\"$HOME/Library/Application Support/fake-brightness/status.sh\" off",
                "timeout": 5,
                "type": "command"
              }
            ]
          }
        ],
        "SessionStart": [
          {
            "hooks": [
              {
                "command": "\"$HOME/Library/Application Support/fake-brightness/status.sh\" idle",
                "timeout": 5,
                "type": "command"
              }
            ]
          }
        ],
        "Stop": [
          {
            "hooks": [
              {
                "command": "\"$HOME/Library/Application Support/fake-brightness/status.sh\" done",
                "timeout": 5,
                "type": "command"
              }
            ]
          }
        ],
        "UserPromptSubmit": [
          {
            "hooks": [
              {
                "command": "\"$HOME/Library/Application Support/fake-brightness/status.sh\" busy",
                "timeout": 5,
                "type": "command"
              }
            ]
          }
        ]
      },
      "modelSettings": {
        "claude-opus-5": {
          "effortLevel": "xhigh"
        }
      },
      "permissions": {
        "additionalDirectories": [
          "/tmp"
        ],
        "allow": [
          "Bash(git *)",
          "Bash(/usr/bin/curl -s -o /dev/null -w \"  status=%{http_code}\\\\n\" \"https://example.com/\")"
        ],
        "deny": [
          "Bash(osascript *)"
        ]
      },
      "pluginConfigs": {},
      "ratio": 0.1,
      "remoteControlAtStartup": true,
      "switchModelsOnFlag": false
    }
    """#

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nb-claude-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"),
                                                withIntermediateDirectories: true)
        installer = ClaudeHookInstaller(home: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: Helpers

    private func writeSettings(_ text: String) throws {
        try Data(text.utf8).write(to: settings)
    }

    private func settingsText() throws -> String {
        try String(contentsOf: settings, encoding: .utf8)
    }

    private func settingsJSON() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
    }

    private func groups(_ event: String, in json: [String: Any]) -> [[String: Any]] {
        ((json["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
    }

    private func ourHandlers(in json: [String: Any]) -> [String: [[String: Any]]] {
        var result: [String: [[String: Any]]] = [:]
        for (event, value) in (json["hooks"] as? [String: Any]) ?? [:] {
            for group in (value as? [[String: Any]]) ?? [] {
                for handler in (group["hooks"] as? [[String: Any]]) ?? []
                where (handler["command"] as? String)?.contains(Paths.hookMarker) == true {
                    result[event, default: []].append(handler)
                }
            }
        }
        return result
    }

    private func backupFiles() -> [URL] {
        guard let e = FileManager.default.enumerator(at: backupsDir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.lastPathComponent == ".claude__settings.json" }
    }

    private func assertUnparsable(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case .unparsableConfig? = error as? HookInstallerError else {
                return XCTFail("unexpected error \(error)", file: file, line: line)
            }
        }
    }

    // MARK: Status

    func testAgentMissingWithoutClaudeDirectory() throws {
        try FileManager.default.removeItem(at: home.appendingPathComponent(".claude"))
        XCTAssertEqual(installer.status(), .agentMissing)
    }

    func testNotInstalledWithoutSettingsFile() {
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    func testNotInstalledWithForeignHooksOnly() throws {
        try writeSettings(Self.foreignSettings)
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    func testPartialWhenSomeEventsMissing() throws {
        try installer.install(bridgePath: bridge)
        var json = try settingsJSON()
        var hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        hooks["PermissionRequest"] = nil
        json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json).write(to: settings)

        guard case .partial(let message) = installer.status() else { return XCTFail("\(installer.status())") }
        XCTAssertTrue(message.contains("PermissionRequest"))

        try installer.install(bridgePath: bridge)
        XCTAssertEqual(installer.status(), .installed)
    }

    // MARK: Install

    func testInstallCreatesMissingSettingsFile() throws {
        try installer.install(bridgePath: bridge)

        let json = try settingsJSON()
        let command = ClaudeHookInstaller.hookCommand(bridgePath: bridge)
        let names = ClaudeHookInstaller.events.map(\.name)
        XCTAssertEqual(names.count, 14)
        XCTAssertEqual(Set((json["hooks"] as? [String: Any])?.keys ?? [:].keys), Set(names))
        for name in names {
            let eventGroups = groups(name, in: json)
            XCTAssertEqual(eventGroups.count, 1, name)
            let handlers = try XCTUnwrap(eventGroups.first?["hooks"] as? [[String: Any]])
            XCTAssertEqual(handlers.count, 1, name)
            XCTAssertEqual(handlers[0]["type"] as? String, "command")
            XCTAssertEqual(handlers[0]["command"] as? String, command)
        }
        func timeout(_ event: String) -> Int? {
            ((groups(event, in: json).first?["hooks"] as? [[String: Any]])?.first?["timeout"] as? NSNumber)?.intValue
        }
        XCTAssertEqual(timeout("PermissionRequest"), 900)
        XCTAssertEqual(timeout("SessionEnd"), 5)
        XCTAssertEqual(timeout("PreToolUse"), 10)
        XCTAssertEqual(groups("PreToolUse", in: json).first?["matcher"] as? String, "*")
        XCTAssertEqual(groups("PermissionRequest", in: json).first?["matcher"] as? String, "*")
        XCTAssertNil(groups("Stop", in: json).first?["matcher"])

        let statusLine = try XCTUnwrap(json["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["type"] as? String, "command")
        XCTAssertEqual(statusLine["command"] as? String, ClaudeHookInstaller.statusLineCommand(bridgePath: bridge))
        XCTAssertEqual(installer.status(), .installed)
        XCTAssertTrue(backupFiles().isEmpty, "nothing to back up for a new file")
    }

    func testCommandsKeepTheGuardedForm() {
        XCTAssertEqual(ClaudeHookInstaller.hookCommand(bridgePath: "/x/notchbuddy-bridge"),
                       #"/bin/sh -c '[ -x "/x/notchbuddy-bridge" ] && "/x/notchbuddy-bridge" --source claude; exit 0'"#)
        XCTAssertEqual(ClaudeHookInstaller.statusLineCommand(bridgePath: "/x/notchbuddy-bridge"),
                       #"/bin/sh -c '[ -x "/x/notchbuddy-bridge" ] && "/x/notchbuddy-bridge" statusline; exit 0'"#)
        let home = "$HOME/.notchbuddy/bin/notchbuddy-bridge"
        XCTAssertEqual(ClaudeHookInstaller.hookCommand(bridgePath: "/h/.notchbuddy/bin/notchbuddy-bridge"),
                       Paths.hookCommand(source: .claude).replacingOccurrences(of: home, with: "/h/.notchbuddy/bin/notchbuddy-bridge"))
    }

    func testInstallIntoEmptyFile() throws {
        for empty in ["", "  \n", "{}"] {
            try writeSettings(empty)
            try installer.install(bridgePath: bridge)
            XCTAssertEqual(installer.status(), .installed, "input: \(empty.debugDescription)")
            XCTAssertEqual(ourHandlers(in: try settingsJSON()).count, 14)
        }
    }

    func testInstallPreservesForeignContentAndOrder() throws {
        try writeSettings(Self.foreignSettings)
        let original = try settingsJSON()
        try installer.install(bridgePath: bridge)

        let json = try settingsJSON()
        for key in original.keys where key != "hooks" {
            XCTAssertEqual(json[key] as? NSObject, original[key] as? NSObject, key)
        }
        // Each foreign group is still first, untouched; ours comes after it.
        for (event, value) in try XCTUnwrap(original["hooks"] as? [String: Any]) {
            let before = try XCTUnwrap(value as? [[String: Any]])
            let after = groups(event, in: json)
            XCTAssertEqual(after.count, before.count + 1, event)
            XCTAssertEqual(Array(after.prefix(before.count)) as NSArray, before as NSArray, event)
        }
        XCTAssertEqual(ourHandlers(in: json).count, 14)
        XCTAssertEqual(installer.status(), .installed)

        // Key order and literals survive: top-level keys in the original order, statusLine appended.
        let text = try settingsText()
        guard case .object(let members) = try ClaudeHookInstaller.Node.parse(text) else { return XCTFail() }
        guard case .object(let originalMembers) = try ClaudeHookInstaller.Node.parse(Self.foreignSettings) else {
            return XCTFail()
        }
        XCTAssertEqual(members.map(\.key), originalMembers.map(\.key) + ["statusLine"])
        XCTAssertTrue(text.contains(#""ratio": 0.1,"#))
        XCTAssertTrue(text.contains(#""statusMessage": "Проверяю плейс","#))
        XCTAssertTrue(text.contains(#""pluginConfigs": {},"#))
        XCTAssertFalse(text.hasSuffix("\n"), "the original had no trailing newline")
    }

    func testInstallCreatesBackupOfExistingFile() throws {
        try writeSettings(Self.foreignSettings)
        try installer.install(bridgePath: bridge)
        let backups = backupFiles()
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(backups.first), encoding: .utf8), Self.foreignSettings)
    }

    func testInstallIsIdempotent() throws {
        try writeSettings(Self.foreignSettings)
        try installer.install(bridgePath: bridge)
        let once = try settingsText()
        try installer.install(bridgePath: bridge)
        XCTAssertEqual(try settingsText(), once)

        // Fresh file: the second install must not even rewrite (no backup appears).
        try FileManager.default.removeItem(at: settings)
        try FileManager.default.removeItem(at: backupsDir)
        try installer.install(bridgePath: bridge)
        try installer.install(bridgePath: bridge)
        XCTAssertTrue(backupFiles().isEmpty)
    }

    func testReinstallWithNewBridgePathReplacesOurEntries() throws {
        try writeSettings(Self.foreignSettings)
        try installer.install(bridgePath: "/old/place/notchbuddy-bridge")
        try installer.install(bridgePath: bridge)

        let json = try settingsJSON()
        let ours = ourHandlers(in: json)
        XCTAssertEqual(ours.count, 14)
        for (event, handlers) in ours {
            XCTAssertEqual(handlers.count, 1, event)
            XCTAssertEqual(handlers.first?["command"] as? String, ClaudeHookInstaller.hookCommand(bridgePath: bridge))
        }
        XCTAssertEqual((json["statusLine"] as? [String: Any])?["command"] as? String,
                       ClaudeHookInstaller.statusLineCommand(bridgePath: bridge))
    }

    // MARK: statusLine

    func testForeignStatusLineIsLeftAlone() throws {
        let foreign = #"""
        {
          "statusLine": {
            "command": "~/bin/my-statusline --fancy",
            "padding": 0,
            "type": "command"
          }
        }
        """#
        try writeSettings(foreign)
        try installer.install(bridgePath: bridge)
        let statusLine = try XCTUnwrap(try settingsJSON()["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, "~/bin/my-statusline --fancy")
        XCTAssertEqual(statusLine["padding"] as? Int, 0)

        try installer.uninstall()
        XCTAssertEqual(try settingsText(), foreign)
    }

    func testOurStatusLineIsRemovedOnUninstall() throws {
        try installer.install(bridgePath: bridge)
        XCTAssertNotNil(try settingsJSON()["statusLine"])
        try installer.uninstall()
        XCTAssertNil(try settingsJSON()["statusLine"])
    }

    // MARK: Uninstall

    func testUninstallRestoresOriginalFileExactly() throws {
        try writeSettings(Self.foreignSettings)
        try installer.install(bridgePath: bridge)
        try installer.uninstall()
        XCTAssertEqual(try settingsText(), Self.foreignSettings)
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    func testUninstallAfterInstallIntoMissingFileLeavesEmptyObject() throws {
        try installer.install(bridgePath: bridge)
        try installer.uninstall()
        XCTAssertTrue(try settingsJSON().isEmpty)
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    func testUninstallKeepsForeignHandlerSharingAGroupWithOurs() throws {
        let ours = ClaudeHookInstaller.hookCommand(bridgePath: bridge)
        let mixed: [String: Any] = ["hooks": ["Stop": [["hooks": [
            ["type": "command", "command": "echo foreign"],
            ["type": "command", "command": ours],
        ]]]]]
        try JSONSerialization.data(withJSONObject: mixed).write(to: settings)
        try installer.uninstall()

        let stopGroups = groups("Stop", in: try settingsJSON())
        XCTAssertEqual(stopGroups.count, 1)
        let handlers = try XCTUnwrap(stopGroups.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(handlers.map { $0["command"] as? String }, ["echo foreign"])
    }

    func testUninstallWithoutOurEntriesDoesNotRewrite() throws {
        let compact = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo hi"}]}]},"a":1}"#
        try writeSettings(compact)
        try installer.uninstall()
        XCTAssertEqual(try settingsText(), compact)
        XCTAssertTrue(backupFiles().isEmpty)
    }

    func testUninstallWithoutSettingsFileIsANoOp() throws {
        try installer.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
    }

    // MARK: Symlinks & permissions

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }

    private func fileType(_ url: URL) throws -> FileAttributeType? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
    }

    /// Dotfiles setup: settings.json is a link to a private file holding secrets.
    func testSymlinkedSettingsStayALinkAndKeepTargetMode() throws {
        let dotfiles = home.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("claude-settings.json")
        try Data(Self.foreignSettings.utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(atPath: settings.path, withDestinationPath: "../dotfiles/claude-settings.json")

        try installer.install(bridgePath: bridge)
        XCTAssertEqual(try fileType(settings), .typeSymbolicLink)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: settings.path),
                       "../dotfiles/claude-settings.json")
        let written = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(written.contains(Paths.hookMarker))
        XCTAssertEqual(try mode(target), 0o600)
        XCTAssertEqual(installer.status(), .installed)

        let backup = try XCTUnwrap(backupFiles().first)
        XCTAssertEqual(try fileType(backup), .typeRegular, "a copy of the contents, not of the link")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), Self.foreignSettings)

        try installer.uninstall()
        XCTAssertEqual(try fileType(settings), .typeSymbolicLink)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), Self.foreignSettings)
        XCTAssertEqual(try mode(target), 0o600)
    }

    func testNewSettingsFileIsPrivate() throws {
        try installer.install(bridgePath: bridge)
        XCTAssertEqual(try mode(settings), 0o600)
    }

    func testExistingModeIsKept() throws {
        try writeSettings(Self.foreignSettings)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: settings.path)
        try installer.install(bridgePath: bridge)
        XCTAssertEqual(try mode(settings), 0o640)
    }

    /// A world-readable settings.json (protected only by ~/.claude being 0700) must not leak through
    /// its backup, even when ~/.notchbuddy/backups already exists with 0755.
    func testBackupsArePrivate() throws {
        try writeSettings(Self.foreignSettings)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path)
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try installer.install(bridgePath: bridge)

        let backup = try XCTUnwrap(backupFiles().first)
        XCTAssertEqual(try mode(backup), 0o600)
        XCTAssertEqual(try mode(backup.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try mode(backupsDir), 0o700)
        XCTAssertEqual(try mode(settings), 0o644, "the live file keeps its own mode")
    }

    // MARK: Refusing to write

    func testUnparsableJSONThrowsAndLeavesFileUntouched() throws {
        let broken = #"{ "hooks": { "Stop": [ "#
        try writeSettings(broken)
        assertUnparsable { try installer.install(bridgePath: bridge) }
        assertUnparsable { try installer.uninstall() }
        XCTAssertEqual(try settingsText(), broken)
        XCTAssertTrue(backupFiles().isEmpty)
        guard case .error = installer.status() else { return XCTFail("\(installer.status())") }
    }

    func testNonObjectTopLevelIsRefused() throws {
        try writeSettings("[1, 2]")
        assertUnparsable { try installer.install(bridgePath: bridge) }
        XCTAssertEqual(try settingsText(), "[1, 2]")
    }

    func testMalformedHooksSectionIsRefused() throws {
        for text in [#"{"hooks": []}"#, #"{"hooks": {"Stop": {"hooks": []}}}"#] {
            try writeSettings(text)
            assertUnparsable { try installer.install(bridgePath: bridge) }
            XCTAssertEqual(try settingsText(), text)
        }
    }

    func testUnusualLiteralsSurviveRewrite() throws {
        let text = #"{"big": 12345678901234567890, "exp": 1.5e-7, "esc": "a\/b é 😀", "nested": [[], {}]}"#
        try writeSettings(text)
        try installer.install(bridgePath: bridge)
        let rewritten = try settingsText()
        XCTAssertTrue(rewritten.contains(#""big": 12345678901234567890"#))
        XCTAssertTrue(rewritten.contains(#""exp": 1.5e-7"#))
        XCTAssertTrue(rewritten.contains(#""esc": "a/b é 😀""#))
        let json = try settingsJSON()
        XCTAssertEqual(json["esc"] as? String, "a/b é 😀")
    }

    // MARK: The command really runs

    func testGuardedCommandRunsBridgeAndToleratesMissingBinary() throws {
        let dir = home.appendingPathComponent("odd dir/it's \"here\"", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fakeBridge = dir.appendingPathComponent("notchbuddy-bridge")
        let out = home.appendingPathComponent("args.txt")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$NB_TEST_OUT\"\n".utf8).write(to: fakeBridge)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBridge.path)

        let command = ClaudeHookInstaller.hookCommand(bridgePath: fakeBridge.path)
        XCTAssertEqual(try runShell(command, env: ["NB_TEST_OUT": out.path]).status, 0)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "--source\nclaude\n")

        try FileManager.default.removeItem(at: fakeBridge)
        let missing = try runShell(command, env: [:])
        XCTAssertEqual(missing.status, 0)
        XCTAssertEqual(missing.output, "")
    }

    /// Runs `command` the way Claude Code does: `/bin/sh -c <command>`.
    private func runShell(_ command: String, env: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": "/usr/bin:/bin"].merging(env) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output)
    }
}
