import XCTest
@testable import NotchBuddyCore

/// Everything runs against a temporary home directory; the real ~/.kimi-code is never touched.
final class KimiHookInstallerTests: XCTestCase {
    private var home: URL!
    private var installer: KimiHookInstaller!
    private var bridge: String { home.appendingPathComponent(".notchbuddy/bin/notchbuddy-bridge").path }
    private var config: URL { installer.configURL }
    private var backupsDir: URL { home.appendingPathComponent(".notchbuddy/backups") }

    /// Shape of a real-world config.toml (quoted table keys, a multi-line array) plus a foreign hook.
    private static let foreignConfig = """
    default_model = "kimi-code/k3"

    [providers."managed:kimi-code"]
    type = "kimi"
    api_key = ""
    base_url = "https://api.example.com/coding/v1"

    [models."kimi-code/k3"]
    provider = "managed:kimi-code"
    model = "k3"
    capabilities = [
      "thinking",
      "tool_use",
    ]
    display_name = "K3"

    [thinking]
    enabled = true
    effort = "high"

    # my own hook
    [[hooks]]
    event = "Stop"
    command = "/usr/local/bin/fake-notify --done"
    timeout = 30

    """

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nb-kimi-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".kimi-code"),
                                                withIntermediateDirectories: true)
        installer = KimiHookInstaller(home: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: Helpers

    private func writeConfig(_ text: String) throws {
        try Data(text.utf8).write(to: config)
    }

    private func configText() throws -> String {
        try String(contentsOf: config, encoding: .utf8)
    }

    private func ourTableCount(_ text: String) -> Int {
        text.components(separatedBy: "\n").filter { $0.contains(Paths.hookMarker) }.count
    }

    private func backupFiles() -> [URL] {
        guard let e = FileManager.default.enumerator(at: backupsDir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.lastPathComponent == ".kimi-code__config.toml" }
    }

    private func assertUnparsable(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case .unparsableConfig? = error as? HookInstallerError else {
                return XCTFail("unexpected error \(error)", file: file, line: line)
            }
        }
    }

    // MARK: Status

    func testAgentMissingWithoutKimiDirectory() throws {
        try FileManager.default.removeItem(at: home.appendingPathComponent(".kimi-code"))
        XCTAssertEqual(installer.status(), .agentMissing)
    }

    func testNotInstalledWithoutConfigOrWithForeignHooksOnly() throws {
        XCTAssertEqual(installer.status(), .notInstalled)
        try writeConfig(Self.foreignConfig)
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    func testPartialWhenSomeEventsMissing() throws {
        let command = KimiHookInstaller.tomlString(KimiHookInstaller.hookCommand(bridgePath: bridge))
        try writeConfig("""
        [[hooks]]
        event = "SessionStart"
        command = \(command)
        timeout = 5

        [[hooks]]
        event = "Stop"
        command = \(command)
        timeout = 5

        """)
        guard case .partial(let message) = installer.status() else { return XCTFail("\(installer.status())") }
        XCTAssertTrue(message.contains("PermissionRequest"))
        XCTAssertFalse(message.contains("SessionStart"))
    }

    // MARK: Install

    func testRegistersExactlyTheSixteenNodeSDKEvents() {
        let events = KimiHookInstaller.events
        XCTAssertEqual(events.count, 16)
        XCTAssertEqual(Set(events).count, 16)
        for runtimeOnly in ["UserPromptQueued", "TurnStarted", "SessionHeartbeat", "TaskStarted"] {
            XCTAssertFalse(events.contains(runtimeOnly), runtimeOnly)
        }
    }

    func testInstallIntoMissingFile() throws {
        try installer.install(bridgePath: bridge)
        let text = try configText()

        let command = "'\(bridge)' --source kimi"
        XCTAssertTrue(text.hasPrefix("""
        \(KimiHookInstaller.managedComment)
        [[hooks]]
        event = "SessionStart"
        command = "\(command)"
        timeout = 5

        [[hooks]]
        event = "SessionEnd"
        """))
        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0 == "[[hooks]]" }.count, 16)
        XCTAssertEqual(ourTableCount(text), 16)
        XCTAssertEqual(text.components(separatedBy: "timeout = 5\n").count - 1, 16)
        XCTAssertFalse(text.contains("matcher"))
        XCTAssertTrue(text.hasSuffix("timeout = 5\n"))
        for event in KimiHookInstaller.events { XCTAssertTrue(text.contains("event = \"\(event)\"\n"), event) }
        XCTAssertEqual(installer.status(), .installed)
        XCTAssertTrue(backupFiles().isEmpty, "nothing to back up for a new file")
    }

    func testInstallIntoEmptyFile() throws {
        try writeConfig("")
        try installer.install(bridgePath: bridge)
        XCTAssertTrue(try configText().hasPrefix(KimiHookInstaller.managedComment + "\n[[hooks]]\n"))
        XCTAssertEqual(installer.status(), .installed)
    }

    func testInstallAppendsAndLeavesExistingContentAlone() throws {
        try writeConfig(Self.foreignConfig)
        try installer.install(bridgePath: bridge)
        let text = try configText()
        XCTAssertTrue(text.hasPrefix(Self.foreignConfig + "\n" + KimiHookInstaller.managedComment + "\n[[hooks]]\n"))
        XCTAssertEqual(ourTableCount(text), 16)
        XCTAssertEqual(installer.status(), .installed)
    }

    func testInstallCreatesBackupOfExistingFile() throws {
        try writeConfig(Self.foreignConfig)
        try installer.install(bridgePath: bridge)
        let backups = backupFiles()
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(backups.first), encoding: .utf8), Self.foreignConfig)
    }

    func testInstallIsIdempotent() throws {
        try writeConfig(Self.foreignConfig)
        try installer.install(bridgePath: bridge)
        let once = try configText()
        try installer.install(bridgePath: bridge)
        XCTAssertEqual(try configText(), once)
    }

    func testReinstallWithNewBridgePathReplacesOurTables() throws {
        try writeConfig(Self.foreignConfig)
        try installer.install(bridgePath: "/old/place/notchbuddy-bridge")
        try installer.install(bridgePath: bridge)
        let text = try configText()
        XCTAssertEqual(ourTableCount(text), 16)
        XCTAssertFalse(text.contains("/old/place"))
        XCTAssertEqual(text.components(separatedBy: KimiHookInstaller.managedComment).count - 1, 1)
    }

    func testCommandIsASingleSimpleCommand() {
        let command = KimiHookInstaller.hookCommand(bridgePath: "/Users/me/.notchbuddy/bin/notchbuddy-bridge")
        XCTAssertEqual(command, "'/Users/me/.notchbuddy/bin/notchbuddy-bridge' --source kimi")
        for forbidden in [";", "&&", "|", ">"] { XCTAssertFalse(command.contains(forbidden), forbidden) }
    }

    func testCRLFFileKeepsItsLineEndings() throws {
        let crlf = "a = 1\r\n[t]\r\nb = 2\r\n"
        try writeConfig(crlf)
        try installer.install(bridgePath: bridge)
        let text = try configText()
        XCTAssertTrue(text.hasPrefix(crlf + "\r\n"))
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        try installer.uninstall()
        XCTAssertEqual(try configText(), crlf)
    }

    // MARK: Uninstall

    func testUninstallRestoresOriginalFileExactly() throws {
        try writeConfig(Self.foreignConfig)
        try installer.install(bridgePath: bridge)
        try installer.uninstall()
        XCTAssertEqual(try configText(), Self.foreignConfig)
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    func testUninstallAfterInstallIntoMissingFileLeavesEmptyFile() throws {
        try installer.install(bridgePath: bridge)
        try installer.uninstall()
        XCTAssertEqual(try configText(), "")
    }

    /// Kimi's login/logout rewrite drops comments and may interleave tables.
    func testUninstallFindsOurTablesByCommandWithoutComments() throws {
        let command = KimiHookInstaller.tomlString(KimiHookInstaller.hookCommand(bridgePath: bridge))
        try writeConfig("""
        default_model = "x"

        [[hooks]]
        event = "SessionStart"
        command = \(command)
        timeout = 5

        [[hooks]]
        event = "Stop"
        command = "/usr/local/bin/fake-notify --done"
        timeout = 30

        [[hooks]]
        event = "Stop"
        command = \(command)
        timeout = 5

        # thinking settings
        [thinking]
        enabled = true

        """)
        try installer.uninstall()
        XCTAssertEqual(try configText(), """
        default_model = "x"

        [[hooks]]
        event = "Stop"
        command = "/usr/local/bin/fake-notify --done"
        timeout = 30

        # thinking settings
        [thinking]
        enabled = true

        """)
    }

    func testUninstallWithoutOurTablesDoesNotRewrite() throws {
        let text = "x = 1\n\n\n[[hooks]]\nevent = \"Stop\"\ncommand = \"echo hi\"\n\n\n"
        try writeConfig(text)
        try installer.uninstall()
        XCTAssertEqual(try configText(), text)
        XCTAssertTrue(backupFiles().isEmpty)
    }

    func testUninstallWithoutConfigIsANoOp() throws {
        try installer.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
    }

    /// Header-looking lines inside multi-line strings and arrays are values, not tables.
    func testMultilineValuesAreNotMistakenForTables() throws {
        let tricky = #"""
        [profiles.review]
        prompt = """
        [[hooks]]
        command = "notchbuddy-bridge"
        """
        literal = '''
        [[hooks]]
        '''
        matrix = [
          ["a", "b"],
          ["c # not a comment", "]"],
        ]

        """#
        try writeConfig(tricky)
        XCTAssertEqual(installer.status(), .notInstalled)
        try installer.uninstall()
        XCTAssertEqual(try configText(), tricky)

        try installer.install(bridgePath: bridge)
        XCTAssertTrue(try configText().hasPrefix(tricky))
        XCTAssertEqual(installer.status(), .installed)
        try installer.uninstall()
        XCTAssertEqual(try configText(), tricky)
    }

    // MARK: Refusing to write

    func testHooksDefinedAnotherWayIsRefused() throws {
        for text in [
            "hooks = []\n",
            "hooks.enabled = true\n",
            "[hooks]\nevent = \"Stop\"\n",
            // A sub-table makes `hooks` a table, so appending [[hooks]] would break the whole file.
            "[hooks.extra]\nfoo = 1\n",
            "[hooks.\"x\"]\nfoo = 1\n",
            "[ hooks . PreToolUse ]\ncommand = \"x\"\n",
            "[[hooks.PreToolUse]]\ncommand = \"x\"\n",
            "[[\"hooks\".PreToolUse]]\ncommand = \"x\"\n",
            "[[hooks]]\nevent = \"Stop\"\ncommand = \"x\"\n\n[hooks.sub]\na = 1\n",
        ] {
            try writeConfig(text)
            assertUnparsable { try installer.install(bridgePath: bridge) }
            XCTAssertEqual(try configText(), text)
            guard case .error = installer.status() else { return XCTFail("\(installer.status())") }
        }
        XCTAssertTrue(backupFiles().isEmpty)
    }

    func testHooksKeyInsideAnotherTableIsFine() throws {
        try writeConfig("[plugins.foo]\nhooks = []\n")
        try installer.install(bridgePath: bridge)
        XCTAssertEqual(installer.status(), .installed)
    }

    /// A quoted key with a dot is one key, not a path under `hooks`.
    func testQuotedDottedKeyIsNotHooks() throws {
        for text in ["[\"hooks.x\"]\nfoo = 1\n", "\"hooks.x\" = 1\n", "[[\"hooks.x\"]]\nfoo = 1\n"] {
            try writeConfig(text)
            try installer.install(bridgePath: bridge)
            XCTAssertTrue(try configText().hasPrefix(text), text)
            XCTAssertEqual(installer.status(), .installed, text)
            try installer.uninstall()
            XCTAssertEqual(try configText(), text)
        }
    }

    // MARK: Foreign [[hooks]] entries must fit Kimi's schema

    private static func foreignHook(_ body: String) -> String {
        "default_model = \"x\"\n\n[[hooks]]\n\(body)\n"
    }

    func testInvalidForeignHookEntryIsRefused() throws {
        let cases: [(body: String, mentions: String)] = [
            ("event = \"Stop\"\ncommand = \"notify-send done\"\ntimeout = 1800", "timeout"),
            ("event = \"Stop\"\ncommand = \"notify\"\ntimeout = 0", "timeout"),
            ("event = \"Stop\"\ncommand = \"notify\"\ntimeout = 5.5", "timeout"),
            ("event = \"Stop\"\ncommand = \"notify\"\ntimeout = \"5\"", "timeout"),
            ("event = \"Stop\"\ncommand = \"notify\"\ntype = \"command\"", "«type»"),
            ("event = \"Stop\"\ncommand = \"notify\"\nenv.FOO = \"1\"", "«env.FOO»"),
            ("event = \"TaskCompleted\"\ncommand = \"notify\"", "TaskCompleted"),
            ("event = \"TurnStarted\"\ncommand = \"notify\"", "войти"),
            ("event = \"Stop\"", "command"),
            ("command = \"notify\"", "event"),
            ("event = \"Stop\"\ncommand = \"\"", "command"),
            ("event = \"Stop\"\ncommand = [\"notify\"]", "command"),
            ("event = \"Stop\"\ncommand = \"notify\"\nmatcher = 1", "matcher"),
            ("event = \"Stop\"\ncommand = \"notify\"\ncommand = \"again\"", "дважды"),
            ("event = \"Stop\" \"x\"\ncommand = \"notify\"", "event"),
        ]
        for (body, mentions) in cases {
            let text = Self.foreignHook(body)
            try writeConfig(text)
            XCTAssertThrowsError(try installer.install(bridgePath: bridge), body) { error in
                guard case .unparsableConfig(_, let reason)? = error as? HookInstallerError else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertTrue(reason.contains("строка "), reason)
                XCTAssertTrue(reason.contains(mentions), "\(reason) should mention \(mentions)")
            }
            XCTAssertEqual(try configText(), text)
            guard case .error(let message) = installer.status() else { return XCTFail("\(body): \(installer.status())") }
            XCTAssertTrue(message.contains(mentions), message)
        }
        XCTAssertTrue(backupFiles().isEmpty)
    }

    func testValidForeignHookVariantsAreAccepted() throws {
        for body in [
            "event = \"Stop\"\ncommand = \"notify\"\ntimeout = 600",
            "event = \"Stop\"\ncommand = \"notify\"\ntimeout = 1 # short",
            "event = \"Stop\"\ncommand = \"notify\"\ntimeout = 5.0",
            "event = 'PreToolUse'\nmatcher = \"^(Bash|Write)$\"\ncommand = 'C:\\tools\\x'",
            "event = \"Stop\"\ncommand = \"\"\"\nnotify --long\n\"\"\"",
            "\"event\" = \"Stop\"\ncommand = \"notify\" # comment",
        ] {
            let text = Self.foreignHook(body)
            try writeConfig(text)
            try installer.install(bridgePath: bridge)
            XCTAssertEqual(installer.status(), .installed, body)
            try installer.uninstall()
            XCTAssertEqual(try configText(), text, body)
        }
    }

    /// Our hooks are in place, then someone adds a broken entry: Kimi would now drop them all.
    func testStatusReportsInvalidForeignEntryNextToOurs() throws {
        try writeConfig(Self.foreignConfig)
        try installer.install(bridgePath: bridge)
        try writeConfig(try configText() + "\n[[hooks]]\nevent = \"Stop\"\ncommand = \"late\"\ntimeout = 1800\n")
        guard case .partial(let message) = installer.status() else { return XCTFail("\(installer.status())") }
        XCTAssertTrue(message.contains("timeout"), message)
        XCTAssertTrue(message.contains("отключит все хуки"), message)

        // Uninstall still works (it only removes our tables).
        try installer.uninstall()
        XCTAssertFalse(try configText().contains(Paths.hookMarker))
        XCTAssertTrue(try configText().contains("command = \"late\""))
    }

    /// Our own table edited by hand (timeout out of range): reinstall repairs it.
    func testOurBrokenEntryIsRepairedByReinstall() throws {
        try installer.install(bridgePath: bridge)
        let broken = try configText().replacingOccurrences(of: "timeout = 5\n", with: "timeout = 900\n")
        try writeConfig(broken)
        guard case .partial(let message) = installer.status() else { return XCTFail("\(installer.status())") }
        XCTAssertTrue(message.contains("переустановите"), message)
        try installer.install(bridgePath: bridge)
        XCTAssertEqual(installer.status(), .installed)
    }

    // MARK: Recognizing our tables

    /// Only the command string counts: a trailing comment mentioning the bridge doesn't make it ours.
    func testCommentAfterCommandDoesNotMakeATableOurs() throws {
        let text = """
        [[hooks]]
        event = "Stop"
        command = "/usr/local/bin/my-notify" # used to be notchbuddy-bridge

        """
        try writeConfig(text)
        XCTAssertEqual(installer.status(), .notInstalled)
        let config = try KimiHookInstaller.ConfigLines(text, path: config.path)
        XCTAssertTrue(config.ourEvents().isEmpty)

        try installer.uninstall()
        XCTAssertEqual(try configText(), text)
        try installer.install(bridgePath: bridge)
        XCTAssertTrue(try configText().hasPrefix(text))
        try installer.uninstall()
        XCTAssertEqual(try configText(), text)
    }

    // MARK: Symlinks

    func testSymlinkedConfigStaysALinkAndKeepsTargetMode() throws {
        let dotfiles = home.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("kimi.toml")
        try Data(Self.foreignConfig.utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)

        try installer.install(bridgePath: bridge)
        let attributes = try FileManager.default.attributesOfItem(atPath: config.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(ourTableCount(try String(contentsOf: target, encoding: .utf8)), 16)
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertEqual(installer.status(), .installed)

        let backup = try XCTUnwrap(backupFiles().first)
        let backupAttributes = try FileManager.default.attributesOfItem(atPath: backup.path)
        XCTAssertEqual(backupAttributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual((backupAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), Self.foreignConfig)

        try installer.uninstall()
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), Self.foreignConfig)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: config.path)[.type]) as? FileAttributeType,
                       .typeSymbolicLink)
    }

    func testBrokenTOMLIsRefusedAndLeftUntouched() throws {
        for text in [
            "prompt = \"\"\"\nnever closed\n",
            "list = [\n  1,\n",
            "[models.\"k3\"\n",
            "just some words\n",
        ] {
            try writeConfig(text)
            assertUnparsable { try installer.install(bridgePath: bridge) }
            assertUnparsable { try installer.uninstall() }
            XCTAssertEqual(try configText(), text)
        }
        XCTAssertTrue(backupFiles().isEmpty)
    }

    // MARK: The command really runs

    func testCommandRunsBridgeFromPathWithSpacesAndQuotes() throws {
        let dir = home.appendingPathComponent("odd dir/it's \"here\"", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fakeBridge = dir.appendingPathComponent("notchbuddy-bridge")
        let out = home.appendingPathComponent("args.txt")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$NB_TEST_OUT\"\n".utf8).write(to: fakeBridge)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBridge.path)

        // Round-trip through the TOML file to also check the string escaping.
        try installer.install(bridgePath: fakeBridge.path)
        let line = try XCTUnwrap(try configText().components(separatedBy: "\n").first { $0.hasPrefix("command = ") })
        let command = KimiHookInstaller.ConfigLines.unquoted(String(line.dropFirst("command = ".count)))
        XCTAssertEqual(command, KimiHookInstaller.hookCommand(bridgePath: fakeBridge.path))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": "/usr/bin:/bin", "NB_TEST_OUT": out.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "--source\nkimi\n")
    }
}
