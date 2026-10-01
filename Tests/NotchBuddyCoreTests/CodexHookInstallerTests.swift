@testable import NotchBuddyCore
import XCTest

final class CodexHookInstallerTests: XCTestCase {
    private var home: URL!
    private let bridge = "/Users/test/.notchbuddy/bin/notchbuddy-bridge"
    private let foreignCommand = "/bin/sh -c 'foreign-tool --hook'"

    private var installer: CodexHookInstaller { CodexHookInstaller(home: home) }
    private var codexDir: URL { home.appendingPathComponent(".codex") }
    private var hooksURL: URL { codexDir.appendingPathComponent("hooks.json") }
    private var configURL: URL { codexDir.appendingPathComponent("config.toml") }
    /// hooks.json path as Codex puts it into trust keys (symlinks resolved).
    private var keyPrefix: String { installer.trustKeyPrefixes()[0] }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("nb-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: Trust hash

    /// Trust hashes for a hook at a temporary path, one per event (the recipe Codex 0.155.1 uses when it writes
    /// trust into config.toml via `config/batchWrite`).
    func testHashForEveryEvent() {
        let dir = "/tmp/codex-e2e"
        let command = "'\(dir)/hook.py' --source codex"
        let expected: [(CodexHookEvent, Int, String)] = [
            (.preToolUse, 5, "8498016c920a5334488ad5918ae83efa46410663c469397abf7423f27f8e4a96"),
            (.postToolUse, 5, "2a48aedc426e35ff21966e0109f87fd6ceceae091c9ab3b4e57968df1e6ff254"),
            (.preCompact, 5, "bdc42104f197e11f2d9287ac352a96876f768a02e863aa998e482fd2ea8cbe95"),
            (.postCompact, 5, "bbc9bbf35d946abed0d27f1e99f2ae043a3b55fc0998a02a72c6508857c26138"),
            (.sessionStart, 5, "29bb2ceedeaecce30b614a38f2880d31d6a159a7631ee666b8602f6ba59e8b4f"),
            (.sessionEnd, 2, "43bf4c75ef539bcc3e5c4230439323f6362762fb9ab6dc9fb380b96ac581204d"),
            (.userPromptSubmit, 5, "0202286483ce52507d7b7f3ff308ed75f61fb3ceaa94ebc0e979641b172e7676"),
            (.subagentStart, 5, "1fb146abb6ffe36461fe4e099f86fac88ef4641f16f77bb7d6355ba952ada598"),
            (.subagentStop, 5, "c9111b77d9ed492c5ce963497ad7cb98d2cce01cff7f187f044548d3b99712b9"),
            (.stop, 5, "0ddf6dd7fc234ceca40c4cbfffebf36a36cc140ff12011f2b24ad6a8941630cf"),
            (.interrupt, 2, "ad170d7dcc93ff7e307455dbc3132dc514f320f22ecfe6f25af9b321ff13e90a"),
        ]
        for (event, timeout, hex) in expected {
            XCTAssertEqual(CodexTrust.hash(event: event, matcher: nil, command: command, timeout: timeout),
                           "sha256:" + hex, event.rawValue)
        }
        XCTAssertEqual(
            CodexTrust.hash(event: .permissionRequest, matcher: nil, command: command, timeout: 86400,
                            statusMessage: "Waiting for approval in NotchBuddy"),
            "sha256:7c519f6820f887781992f77860b7fd281fc7e6f5da6ac8e4be34699e438cbddf")
    }

    /// `currentHash` values in the form `hooks/list` reports them.
    func testHashMatchesCodexHooksListCurrentHash() {
        let command = "'/Users/me/.notchbuddy/bin/notchbuddy-bridge' --source codex"
        XCTAssertEqual(CodexTrust.hash(event: .permissionRequest, matcher: nil, command: command, timeout: 7200),
                       "sha256:dcc0fd28b8867100842c88a1988445617b6934b2a7847940c298901dbdaf1dde")
        XCTAssertEqual(CodexTrust.hash(event: .sessionStart, matcher: "startup|resume|clear", command: command, timeout: 5),
                       "sha256:aca1797b8527ff2e19b9adacc545ec8cf46939ff395278fa587eb7f11b208052")
        XCTAssertEqual(CodexTrust.hash(event: .stop, matcher: nil, command: command, timeout: 5, isAsync: true),
                       "sha256:091b779eb5edf40917ff286eebe415a85087144deab749949311e1010e9aea18")
    }

    /// Edge cases of the recipe.
    func testHashRecipeEdgeCases() {
        let c = "'/Users/me/.notchbuddy/bin/notchbuddy-bridge' --source codex"
        func h(_ e: CodexHookEvent, _ m: String?, _ t: Int?, async: Bool = false, status: String? = nil) -> String {
            CodexTrust.hash(event: e, matcher: m, command: c, timeout: t, isAsync: async, statusMessage: status)
        }
        // "" matcher is kept; "*" is hashed as written.
        XCTAssertEqual(h(.postToolUse, "", 5), "sha256:0f6c19f8dae21d9e181ac102062a1dd170e3b39c5144c474c2344f73a08aabc8")
        XCTAssertEqual(h(.postToolUse, "*", 5), "sha256:9fca8670add316edcec7f839f745d707f299e89625523c7292e0ad8d43a7811b")
        // Matcher dropped for UserPromptSubmit / Stop; missing timeout → 600.
        XCTAssertEqual(h(.stop, "xyz", nil), "sha256:757a01612b3a58a19e2b7c7d8ebf95e3646f9ba857afcc916cdf370131d664c1")
        XCTAssertEqual(h(.userPromptSubmit, "abc", nil), "sha256:fd9963dc34f60560fe5038231163b2f557eaccd7114aecfeeabbb5f970b225d7")
        // SessionEnd: clamped to 3; async hashed as written although Codex runs it synchronously.
        XCTAssertEqual(h(.sessionEnd, nil, 10), "sha256:61cd64323d0dea0a095133df4b8d1d6c91c447c9e1f8bf741d136e822d3aa0de")
        XCTAssertEqual(h(.sessionEnd, nil, 3, async: true), "sha256:e056d93fde44bc9fae09f0299f3d5fbf7d2b30f621bd902e55ab7fe0c6e9369d")
        XCTAssertEqual(h(.sessionEnd, nil, 2), "sha256:967ace110ac6dfcc3c39e032add142b49ec968ee4160d558319b953c90a3c11d")
        // Interrupt default 1 s; timeout 0 becomes 1 s.
        XCTAssertEqual(h(.interrupt, nil, nil), "sha256:0ac5bc9fcea886e69a8b887dc07a6b6052b7a5bf19f04e4b453b858048b61379")
        XCTAssertEqual(h(.permissionRequest, nil, 0), "sha256:4c05e218c46e2f8da20c28500000317f940a334f5c088d5309e5f9a655bfc48e")
        // Unicode, quotes, backslash, tab, control characters, DEL, emoji and U+2028 in statusMessage.
        XCTAssertEqual(h(.sessionStart, "startup|resume", 5, status: "Ждём NotchBuddy — ✓ \"q\" \\ tab\t"),
                       "sha256:9484b789e158bd5e5cd75d644cbfaa836db16e0df7fe50bc889756449e403654")
        XCTAssertEqual(h(.preToolUse, nil, 600, status: "ctl\u{01}\u{1f} del\u{7f} emoji😀 \u{2028}"),
                       "sha256:3d1ffc253d60ce8fb587ac63ddfd795b988fc7506cea01ec02aab3c01969d1c2")
        XCTAssertEqual(
            CodexTrust.hash(event: .stop, matcher: nil, command: "/usr/bin/env A=1 \"/path with space/bridge\" --x=<y>&z",
                            timeout: 5, isAsync: true),
            "sha256:ca19a6731f1e70ec29c4c197a1cd00dc922a8086467846753d5ded2f818ce128")
        // Our own handlers.
        let ours = CodexHookInstaller.hookCommand(bridgePath: bridge)
        XCTAssertEqual(CodexTrust.hash(event: .permissionRequest, matcher: nil, command: ours, timeout: 900),
                       "sha256:fc98984cf2c2805c80587de56369765b3a4f340bc4c61198a05a14b188e30527")
        XCTAssertEqual(CodexTrust.hash(event: .sessionEnd, matcher: nil, command: ours, timeout: 3),
                       "sha256:82e06bdfa763ebb3ae696e07ca987fd03349bed720ea9118bd994125a82b3811")
        XCTAssertEqual(CodexTrust.hash(event: .stop, matcher: nil, command: ours, timeout: 10),
                       "sha256:5826c7782144b0d09bc4667b82a7a24792ce02b191398c14de079fbd5429d948")
    }

    func testHashOfHandlerAsWrittenInHooksJSON() throws {
        let c = "'/Users/me/.notchbuddy/bin/notchbuddy-bridge' --source codex"
        let file = try CodexHooksFile(text: """
        {"hooks": {"PermissionRequest": [{"hooks": [{"type": "command", "command": "\(c)", "timeout": 86400, "statusMessage": "Waiting for approval in NotchBuddy"}]}],
         "PostToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "\(c)", "timeout": 5}]}],
         "SessionStart": [{"matcher": "startup|resume", "hooks": [{"type": "command", "command": "\(c)", "timeout": 5, "statusMessage": "\\u0416\\u0434\\u0451\\u043c NotchBuddy \\u2014 \\u2713 \\"q\\" \\\\ tab\\t"}]}],
         "Stop": [{"hooks": [{"type": "command", "command": "/usr/bin/env A=1 \\"/path with space/bridge\\" --x=<y>&z", "timeout": 5, "async": true}]}],
         "SessionEnd": [{"hooks": [{"type": "command", "command": "\(c)", "timeout": 2}]}]}}
        """)
        let first = CodexHandlerPosition(group: 0, handler: 0)
        XCTAssertEqual(file.hash(.permissionRequest, at: first), "sha256:7a193346fdff8e9bb13fac7f05fa9d0de11452fa8b977f70af05313019efd231")
        XCTAssertEqual(file.hash(.postToolUse, at: first), "sha256:9fca8670add316edcec7f839f745d707f299e89625523c7292e0ad8d43a7811b")
        XCTAssertEqual(file.hash(.sessionStart, at: first), "sha256:9484b789e158bd5e5cd75d644cbfaa836db16e0df7fe50bc889756449e403654")
        XCTAssertEqual(file.hash(.stop, at: first), "sha256:ca19a6731f1e70ec29c4c197a1cd00dc922a8086467846753d5ded2f818ce128")
        XCTAssertEqual(file.hash(.sessionEnd, at: first), "sha256:967ace110ac6dfcc3c39e032add142b49ec968ee4160d558319b953c90a3c11d")
    }

    func testTrustKeyFormat() {
        let snake = CodexHookEvent.allCases.map(\.snakeName)
        XCTAssertEqual(snake, ["pre_tool_use", "permission_request", "post_tool_use", "pre_compact", "post_compact",
                               "session_start", "session_end", "user_prompt_submit", "subagent_start", "subagent_stop",
                               "stop", "interrupt"])
        let key = CodexTrust.key(hooksPath: "/Users/a/.codex/hooks.json", event: .permissionRequest,
                                 position: CodexHandlerPosition(group: 2, handler: 1))
        XCTAssertEqual(key, "/Users/a/.codex/hooks.json:permission_request:2:1")
        let parsed = CodexTrust.parseKey(key, hooksPath: "/Users/a/.codex/hooks.json")
        XCTAssertEqual(parsed?.0, .permissionRequest)
        XCTAssertEqual(parsed?.1, CodexHandlerPosition(group: 2, handler: 1))
        XCTAssertNil(CodexTrust.parseKey("/Users/a/.codex/config.toml:stop:0:0", hooksPath: "/Users/a/.codex/hooks.json"))
    }

    // MARK: Command

    func testHookCommandIsGuardedAndRunsBridge() throws {
        XCTAssertEqual(CodexHookInstaller.hookCommand(bridgePath: bridge),
                       "/bin/sh -c '[ -x \"\(bridge)\" ] && \"\(bridge)\" --source codex; exit 0'")

        // A path with a space, a quote and a dollar still reaches the bridge with the payload on stdin.
        let dir = home.appendingPathComponent("it's $HOME dir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bin = dir.appendingPathComponent("notchbuddy-bridge")
        let out = home.appendingPathComponent("out.txt")
        try "#!/bin/sh\n{ echo \"$@\"; cat; } > '\(out.path)'\nexit 7\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let command = CodexHookInstaller.hookCommand(bridgePath: bin.path)
        XCTAssertTrue(command.contains(Paths.hookMarker))

        XCTAssertEqual(try runShell(command, stdin: "{\"hook_event_name\":\"Stop\"}"), 0)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "--source codex\n{\"hook_event_name\":\"Stop\"}")

        // Bridge gone (app removed): exit 0, nothing printed.
        try FileManager.default.removeItem(at: bin)
        XCTAssertEqual(try runShell(command, stdin: "{}"), 0)
    }

    // MARK: Install

    func testStatusAgentMissingWithoutCodexDir() throws {
        try FileManager.default.removeItem(at: codexDir)
        XCTAssertEqual(installer.status(), .agentMissing)
        try installer.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexDir.path))
    }

    func testInstallIntoEmptyCodexHome() throws {
        XCTAssertEqual(installer.status(), .notInstalled)
        try installer.install(bridgePath: bridge)

        let root = try rawHooks()
        XCTAssertEqual(Array(root.keys), ["hooks"])
        let events = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertEqual(Set(events.keys), Set(CodexHookEvent.allCases.map(\.rawValue)))
        let command = CodexHookInstaller.hookCommand(bridgePath: bridge)
        for event in CodexHookEvent.allCases {
            let groups = try XCTUnwrap(events[event.rawValue] as? [[String: Any]])
            XCTAssertEqual(groups.count, 1)
            XCTAssertEqual(Array(groups[0].keys), ["hooks"], "no matcher")
            let handlers = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
            XCTAssertEqual(handlers.count, 1)
            XCTAssertEqual(Set(handlers[0].keys), ["type", "command", "timeout"])
            XCTAssertEqual(handlers[0]["type"] as? String, "command")
            XCTAssertEqual(handlers[0]["command"] as? String, command)
        }
        XCTAssertEqual(timeout(events, .permissionRequest), 900)
        XCTAssertEqual(timeout(events, .sessionEnd), 3)
        XCTAssertEqual(timeout(events, .interrupt), 3)
        XCTAssertEqual(timeout(events, .stop), 10)
        XCTAssertEqual(timeout(events, .preToolUse), 10)

        let first = CodexHandlerPosition(group: 0, handler: 0)
        for event in CodexHookEvent.allCases { XCTAssertTrue(try isTrusted(event, first), event.rawValue) }
        XCTAssertEqual(installer.status(), .installed)
        let perms = try FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testTrustKeysUseRealPathOfSymlinkedHome() throws {
        let real = home.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let alias = home.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let linked = CodexHookInstaller(home: alias)
        try linked.install(bridgePath: bridge)

        let realKeyPath = try XCTUnwrap(realpath(real.path)) + "/.codex/hooks.json"
        XCTAssertEqual(linked.trustKeyPrefixes().first, realKeyPath)
        let config = try String(contentsOf: real.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        let trusted = try CodexConfigTOML(text: config).trustedHashes()
        XCTAssertNotNil(trusted[realKeyPath + ":stop:0:0"])
        XCTAssertEqual(linked.status(), .installed)
    }

    func testSymlinkedConfigStaysASymlink() throws {
        let dotfiles = home.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("codex-config.toml")
        try write("model = \"x\"\n", to: target)
        try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: target)

        try installer.install(bridgePath: bridge)
        let type = try FileManager.default.attributesOfItem(atPath: configURL.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink)
        XCTAssertTrue(try read(target).hasPrefix("model = \"x\"\n\n[hooks.state."))
        XCTAssertEqual(installer.status(), .installed)
    }

    func testInstallPreservesForeignHooksAndConfig() throws {
        let (hooksText, configText) = try writeForeignFixture()
        try installer.install(bridgePath: bridge)

        let file = try CodexHooksFile(text: try read(hooksURL))
        XCTAssertEqual(file.root["description"], "team hooks")
        XCTAssertEqual(file.root["hooks"]?["Notification"], try CodexHooksFile(text: hooksText).root["hooks"]?["Notification"])
        let permission = file.groups(.permissionRequest)
        XCTAssertEqual(permission.count, 2)
        XCTAssertEqual(permission[0]["matcher"], "Bash")
        XCTAssertEqual(permission[0]["hooks"]?[0]?["command"]?.string, foreignCommand)
        XCTAssertTrue(CodexHooksFile.isOurs(try XCTUnwrap(permission[1]["hooks"]?[0])))
        XCTAssertEqual(file.groups(.stop).count, 2)
        XCTAssertEqual(file.groups(.stop)[0]["hooks"]?[0]?["type"], "mcp_tool")

        // config.toml: everything kept byte for byte, our tables appended after it.
        let newConfig = try read(configURL)
        XCTAssertTrue(newConfig.hasPrefix(configText))
        XCTAssertTrue(try isTrusted(.permissionRequest, CodexHandlerPosition(group: 0, handler: 0)))
        XCTAssertTrue(try isTrusted(.permissionRequest, CodexHandlerPosition(group: 1, handler: 0)))
        XCTAssertTrue(try isTrusted(.stop, CodexHandlerPosition(group: 1, handler: 0)))
        XCTAssertEqual(installer.status(), .installed)
    }

    func testInstallIsIdempotent() throws {
        _ = try writeForeignFixture()
        try installer.install(bridgePath: bridge)
        let hooks = try read(hooksURL)
        let config = try read(configURL)
        try FileManager.default.removeItem(at: home.appendingPathComponent(".notchbuddy"))

        try installer.install(bridgePath: bridge)
        XCTAssertEqual(try read(hooksURL), hooks)
        XCTAssertEqual(try read(configURL), config)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".notchbuddy").path),
                       "nothing changed, so nothing was backed up or written")
        XCTAssertEqual(try CodexHooksFile(text: hooks).ourHandlers(.stop).count, 1)
    }

    func testInstallThenUninstallRestoresOriginalFiles() throws {
        let (hooksText, configText) = try writeForeignFixture()
        try installer.install(bridgePath: bridge)
        try installer.uninstall()
        XCTAssertEqual(try read(configURL), configText)
        XCTAssertEqual(try CodexHooksFile(text: try read(hooksURL)).root, try CodexHooksFile(text: hooksText).root)
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    func testForeignTrustSurvivesInstallAndUninstallWhenIndicesShift() throws {
        _ = try writeForeignFixture()
        try installer.install(bridgePath: bridge)

        // Another tool appends its group after ours and trusts it at index 2.
        let late = "/usr/local/bin/late-tool --hook"
        var file = try CodexHooksFile(text: try read(hooksURL))
        var root = file.root
        var events = try XCTUnwrap(root["hooks"]?.object)
        let lateGroup: JSONValue = ["hooks": [["type": "command", "command": .string(late), "timeout": 20]]]
        events["PermissionRequest"] = .array(file.groups(.permissionRequest) + [lateGroup])
        root["hooks"] = .object(events)
        try JSONValue.object(root).serialized().write(to: hooksURL)
        file = try CodexHooksFile(text: try read(hooksURL))
        let lateHash = try XCTUnwrap(file.hash(.permissionRequest, at: CodexHandlerPosition(group: 2, handler: 0)))
        try (read(configURL) + "\n[hooks.state.\"\(keyPrefix):permission_request:2:0\"]\ntrusted_hash = \"\(lateHash)\"\n")
            .write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(try isTrusted(.permissionRequest, CodexHandlerPosition(group: 2, handler: 0)))

        try installer.uninstall()
        let after = try CodexHooksFile(text: try read(hooksURL))
        let groups = after.groups(.permissionRequest)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0]["hooks"]?[0]?["command"]?.string, foreignCommand)
        XCTAssertEqual(groups[1]["hooks"]?[0]?["command"]?.string, late)
        XCTAssertTrue(try isTrusted(.permissionRequest, CodexHandlerPosition(group: 0, handler: 0)))
        XCTAssertTrue(try isTrusted(.permissionRequest, CodexHandlerPosition(group: 1, handler: 0)), "trust moved with the hook")

        let trusted = try CodexConfigTOML(text: try read(configURL)).trustedHashes()
        XCTAssertNil(trusted[keyPrefix + ":permission_request:2:0"])
        XCTAssertEqual(trusted.keys.filter { $0.contains("/.codex/hooks.json:") }.count, 2,
                       "only the two foreign entries of hooks.json remain")
        XCTAssertEqual(trusted["/Users/someone/.codex/config.toml:stop:0:0"], "sha256:other-file")
        XCTAssertFalse(try read(hooksURL).contains(Paths.hookMarker))
        XCTAssertTrue(try read(configURL).contains("# my codex config"))
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    func testOurHandlerInsideForeignGroupIsMovedOut() throws {
        let oldOurs = "'/old/place/notchbuddy-bridge' --source codex"
        try write("""
        {"hooks": {"PermissionRequest": [{"matcher": "Bash", "hooks": [
          {"type": "command", "command": "tool-a", "timeout": 5},
          {"type": "command", "command": "\(oldOurs)", "timeout": 60},
          {"type": "command", "command": "tool-b", "timeout": 5}]}]}}
        """, to: hooksURL)
        let before = try CodexHooksFile(text: try read(hooksURL))
        var config = ""
        for handler in 0..<3 {
            let hash = try XCTUnwrap(before.hash(.permissionRequest, at: CodexHandlerPosition(group: 0, handler: handler)))
            config += "[hooks.state.\"\(keyPrefix):permission_request:0:\(handler)\"]\ntrusted_hash = \"\(hash)\"\n\n"
        }
        try write(config, to: configURL)

        try installer.install(bridgePath: bridge)
        let after = try CodexHooksFile(text: try read(hooksURL))
        let groups = after.groups(.permissionRequest)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0]["matcher"], "Bash")
        XCTAssertEqual(groups[0]["hooks"]?.array?.compactMap { $0["command"]?.string }, ["tool-a", "tool-b"])
        XCTAssertTrue(try isTrusted(.permissionRequest, CodexHandlerPosition(group: 0, handler: 0)))
        XCTAssertTrue(try isTrusted(.permissionRequest, CodexHandlerPosition(group: 0, handler: 1)), "tool-b trust renamed")
        XCTAssertTrue(try isTrusted(.permissionRequest, CodexHandlerPosition(group: 1, handler: 0)))
        XCTAssertNil(try trustedHashes()[keyPrefix + ":permission_request:0:2"])
        try assertNoDuplicateTrustKeys()
        XCTAssertEqual(installer.status(), .installed)
    }

    func testReinstallWithNewBridgePathKeepsPositionAndForeignTrust() throws {
        try installer.install(bridgePath: bridge)
        // A foreign group lands after ours.
        var root = try CodexHooksFile(text: try read(hooksURL)).root
        var events = try XCTUnwrap(root["hooks"]?.object)
        events["Stop"] = .array((events["Stop"]?.array ?? []) + [["hooks": [["type": "command", "command": "later"]]]])
        root["hooks"] = .object(events)
        try JSONValue.object(root).serialized().write(to: hooksURL)
        let hash = try XCTUnwrap(try CodexHooksFile(text: try read(hooksURL)).hash(.stop, at: CodexHandlerPosition(group: 1, handler: 0)))
        try (read(configURL) + "\n[hooks.state.\"\(keyPrefix):stop:1:0\"]\ntrusted_hash = \"\(hash)\"\n")
            .write(to: configURL, atomically: true, encoding: .utf8)

        let newBridge = "/Applications/NotchBuddy.app/Contents/MacOS/notchbuddy-bridge"
        try installer.install(bridgePath: newBridge)
        let file = try CodexHooksFile(text: try read(hooksURL))
        XCTAssertEqual(file.groups(.stop)[0]["hooks"]?[0]?["command"]?.string, CodexHookInstaller.hookCommand(bridgePath: newBridge))
        XCTAssertEqual(file.groups(.stop)[1]["hooks"]?[0]?["command"]?.string, "later")
        XCTAssertTrue(try isTrusted(.stop, CodexHandlerPosition(group: 0, handler: 0)))
        XCTAssertTrue(try isTrusted(.stop, CodexHandlerPosition(group: 1, handler: 0)))
        try assertNoDuplicateTrustKeys()
        XCTAssertEqual(installer.status(), .installed)
    }

    func testOutputRespectsWholeFileDropConstraints() throws {
        _ = try writeForeignFixture()
        try installer.install(bridgePath: bridge)
        let root = try rawHooks()
        XCTAssertTrue(Set(root.keys).isSubset(of: ["description", "hooks"]))
        let events = try XCTUnwrap(root["hooks"] as? [String: Any])
        for event in CodexHookEvent.allCases {
            for group in try XCTUnwrap(events[event.rawValue] as? [[String: Any]]) {
                for handler in try XCTUnwrap(group["hooks"] as? [[String: Any]]) {
                    let type = try XCTUnwrap(handler["type"] as? String)
                    XCTAssertTrue(["command", "mcp_tool"].contains(type))
                    if let timeout = handler["timeout"] {
                        let number = try XCTUnwrap(timeout as? NSNumber, "timeout must be a JSON number")
                        XCTAssertFalse(CFNumberIsFloatType(number), "timeout must be an integer")
                        XCTAssertNotEqual(CFGetTypeID(number), CFBooleanGetTypeID())
                    }
                }
            }
        }
        let value = try JSONValue.parse(Data(try read(hooksURL).utf8))
        XCTAssertNil(CodexHooksFile.problem(in: value))
    }

    // MARK: Refusals

    func testRefusesHooksFileCodexWouldIgnore() throws {
        let cases = [
            #"{"extra": 1, "hooks": {}}"#,
            #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "x", "timeout": "5"}]}]}}"#,
            #"{"hooks": {"Stop": [{"hooks": [{"type": "http", "url": "x"}]}]}}"#,
            #"{"hooks": {"Stop": [{"hooks": [{"command": "x"}]}]}}"#,
            #"{"hooks": {"Stop": {"hooks": []}}}"#,
            #"{"hooks": {"#,
            // serde_json reads u64 only from an integer literal.
            #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "x", "timeout": 5.0}]}]}}"#,
            #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "x", "timeout": 1e3}]}]}}"#,
            #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "x", "timeout": -0}]}]}}"#,
            #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "x", "timeout": 18446744073709551616}]}]}}"#,
            // mcp_tool input must be a map representable as TOML: no null anywhere.
            #"{"hooks": {"Stop": [{"hooks": [{"type": "mcp_tool", "server": "s", "tool": "t", "input": null}]}]}}"#,
            #"{"hooks": {"Stop": [{"hooks": [{"type": "mcp_tool", "server": "s", "tool": "t", "input": {"a": null}}]}]}}"#,
            #"{"hooks": {"Stop": [{"hooks": [{"type": "mcp_tool", "server": "s", "tool": "t", "input": {"a": {"b": null}}}]}]}}"#,
            #"{"hooks": {"Stop": [{"hooks": [{"type": "mcp_tool", "server": "s", "tool": "t", "input": {"a": [null]}}]}]}}"#,
        ]
        for text in cases {
            try write(text, to: hooksURL)
            try? FileManager.default.removeItem(at: configURL)
            XCTAssertThrowsError(try installer.install(bridgePath: bridge), text) { error in
                guard case HookInstallerError.unparsableConfig(let path, _) = error else {
                    return XCTFail("unexpected \(error)")
                }
                XCTAssertEqual(path, self.hooksURL.path)
            }
            XCTAssertEqual(try read(hooksURL), text)
            XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
            guard case .error = installer.status() else { return XCTFail("status for \(text)") }
        }
    }

    func testMcpToolInputWithoutNullsIsAccepted() throws {
        try write(#"{"hooks": {"Stop": [{"hooks": [{"type": "mcp_tool", "server": "s", "tool": "t", "input": {"a": [1, {"b": "c"}]}}]}]}}"#,
                  to: hooksURL)
        try installer.install(bridgePath: bridge)
        XCTAssertEqual(installer.status(), .installed)
    }

    /// Another tool's numbers are written back exactly: `1e+16` or a rounded 2^53+ value would make
    /// Codex reject (or re-hash) the whole file.
    func testForeignNumberLiteralsSurviveInstallAndUninstall() throws {
        try write("""
        {"hooks": {
          "Stop": [{"hooks": [{"type": "command", "command": "foreign", "timeout": 10000000000000000}]}],
          "PreToolUse": [{"hooks": [{"type": "command", "command": "other", "timeout": 9007199254740993,
                                     "additionalContextLimit": 18446744073709551615}]}],
          "PostToolUse": [{"hooks": [{"type": "mcp_tool", "server": "s", "tool": "t",
                                      "input": {"ratio": 1.0, "exp": 1.5e-7, "big": 12345678901234567890}}]}]
        }}
        """, to: hooksURL)
        let literals = [
            #""timeout": 10000000000000000"#, #""timeout": 9007199254740993"#,
            #""additionalContextLimit": 18446744073709551615"#,
            #""ratio": 1.0"#, #""exp": 1.5e-7"#, #""big": 12345678901234567890"#,
        ]
        try installer.install(bridgePath: bridge)
        var text = try read(hooksURL)
        for literal in literals { XCTAssertTrue(text.contains(literal), literal) }
        XCTAssertEqual(installer.status(), .installed)

        try installer.uninstall()
        text = try read(hooksURL)
        for literal in literals { XCTAssertTrue(text.contains(literal), literal) }
        XCTAssertFalse(text.contains(Paths.hookMarker))
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    /// Stop = [ours, other] with other trusted at index 1; removing ours shifts it to 0 and the trust
    /// rename lives in config.toml. If that write fails, hooks.json must not stay shifted.
    func testFailedConfigWriteRollsBackHooksJSON() throws {
        try installer.install(bridgePath: bridge)
        var root = try CodexHooksFile(text: try read(hooksURL)).root
        var events = try XCTUnwrap(root["hooks"]?.object)
        events["Stop"] = .array((events["Stop"]?.array ?? []) + [["hooks": [["type": "command", "command": "other --hook"]]]])
        root["hooks"] = .object(events)
        try JSONValue.object(root).serialized().write(to: hooksURL)
        let otherHash = try XCTUnwrap(try CodexHooksFile(text: try read(hooksURL)).hash(.stop, at: CodexHandlerPosition(group: 1, handler: 0)))
        try (read(configURL) + "\n[hooks.state.\"\(keyPrefix):stop:1:0\"]\ntrusted_hash = \"\(otherHash)\"\n")
            .write(to: configURL, atomically: true, encoding: .utf8)
        let hooksBefore = try read(hooksURL)
        let configBefore = try read(configURL)

        var failing = installer
        failing.writeFile = { text, url in
            if url.lastPathComponent == "config.toml" {
                throw HookInstallerError.writeFailed(path: url.path, reason: "диск переполнен")
            }
            try HookInstallers.write(text, to: url)
        }
        XCTAssertThrowsError(try failing.uninstall()) { error in
            guard case HookInstallerError.writeFailed(let path, let reason) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(path, self.configURL.path)
            XCTAssertEqual(reason, "диск переполнен")
        }
        XCTAssertEqual(try read(hooksURL), hooksBefore, "hooks.json rolled back")
        XCTAssertEqual(try read(configURL), configBefore)
        XCTAssertTrue(try isTrusted(.stop, CodexHandlerPosition(group: 1, handler: 0)), "the other tool's hook still runs")

        try installer.uninstall()
        XCTAssertTrue(try isTrusted(.stop, CodexHandlerPosition(group: 0, handler: 0)), "trust moved with the hook")
    }

    func testFailedConfigWriteRemovesHooksJSONItCreated() throws {
        var failing = installer
        failing.writeFile = { text, url in
            if url.lastPathComponent == "config.toml" {
                throw HookInstallerError.writeFailed(path: url.path, reason: "диск переполнен")
            }
            try HookInstallers.write(text, to: url)
        }
        XCTAssertThrowsError(try failing.install(bridgePath: bridge))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    /// config.toml links into a read-only folder (home-manager/nix style): detected before hooks.json is touched.
    func testUnwritableConfigTargetIsDetectedBeforeWriting() throws {
        let readOnly = home.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        let target = readOnly.appendingPathComponent("config.toml")
        try write("model = \"x\"\n", to: target)
        try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }

        XCTAssertThrowsError(try installer.install(bridgePath: bridge)) { error in
            guard case HookInstallerError.writeFailed(let path, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(path, self.configURL.path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksURL.path))
        XCTAssertEqual(try read(target), "model = \"x\"\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".notchbuddy").path))
    }

    func testSymlinkedHooksFileStaysASymlinkAndIsBackedUpByContent() throws {
        let dotfiles = home.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("hooks.json")
        let original = #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "foreign"}]}]}}"#
        try write(original, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: hooksURL, withDestinationURL: target)

        try installer.install(bridgePath: bridge)
        let attributes = try FileManager.default.attributesOfItem(atPath: hooksURL.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertTrue(try read(target).contains(Paths.hookMarker))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)

        let backups = home.appendingPathComponent(".notchbuddy/backups")
        let stamp = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: backups.path).first)
        let backup = backups.appendingPathComponent(stamp).appendingPathComponent(".codex__hooks.json")
        let backupAttributes = try FileManager.default.attributesOfItem(atPath: backup.path)
        XCTAssertEqual(backupAttributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual((backupAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try read(backup), original)
    }

    func testRefusesConfigTOMLItCannotEditSafely() throws {
        for text in ["model = \"unterminated\n", "hooks = { state = {} }\n", "[hooks]\nstate = {}\n", "x = [1,\n"] {
            try write(text, to: configURL)
            XCTAssertThrowsError(try installer.install(bridgePath: bridge), text)
            XCTAssertFalse(FileManager.default.fileExists(atPath: hooksURL.path))
            XCTAssertEqual(try read(configURL), text)
        }
        try write("model = \"unterminated\n", to: configURL)
        guard case .error = installer.status() else { return XCTFail("expected .error") }
    }

    // MARK: Backups & status

    func testBackupsBothFilesBeforeWriting() throws {
        let (hooksText, configText) = try writeForeignFixture()
        try installer.install(bridgePath: bridge)
        let backups = home.appendingPathComponent(".notchbuddy/backups")
        let stamps = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        XCTAssertEqual(stamps.count, 1)
        let dir = backups.appendingPathComponent(stamps[0])
        XCTAssertEqual(try read(dir.appendingPathComponent(".codex__hooks.json")), hooksText)
        XCTAssertEqual(try read(dir.appendingPathComponent(".codex__config.toml")), configText)
    }

    func testStatusReportsMissingOrStaleTrust() throws {
        try installer.install(bridgePath: bridge)
        try write("", to: configURL)
        XCTAssertEqual(installer.status(), .partial("хуки без доверия"))

        try installer.install(bridgePath: bridge)
        XCTAssertEqual(installer.status(), .installed)

        // Editing one of our handlers (timeout) invalidates its hash → "modified" for Codex.
        var root = try CodexHooksFile(text: try read(hooksURL)).root
        var events = try XCTUnwrap(root["hooks"]?.object)
        events["Stop"] = [["hooks": [["type": "command", "command": .string(CodexHookInstaller.hookCommand(bridgePath: bridge)), "timeout": 11]]]]
        root["hooks"] = .object(events)
        try JSONValue.object(root).serialized().write(to: hooksURL)
        XCTAssertEqual(installer.status(), .partial("хуки без доверия: 1 из 12"))

        events["Stop"] = nil
        root["hooks"] = .object(events)
        try JSONValue.object(root).serialized().write(to: hooksURL)
        XCTAssertEqual(installer.status(), .partial("установлены не все хуки: 11 из 12"))
    }

    func testStatusWarnsWhenHooksFeatureDisabled() throws {
        try write("[features]\nhooks = false # off\n", to: configURL)
        try installer.install(bridgePath: bridge)
        guard case .partial(let message) = installer.status() else { return XCTFail("expected .partial") }
        XCTAssertTrue(message.contains("отключены"))
    }

    func testUninstallLeavesValidEmptyHooksFile() throws {
        try installer.install(bridgePath: bridge)
        try installer.uninstall()
        XCTAssertEqual(try JSONValue.parse(Data(try read(hooksURL).utf8)), ["hooks": [:]])
        XCTAssertTrue(try trustedHashes().isEmpty)
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    // MARK: TOML editing

    func testTrustInOtherTOMLFormsIsReplacedNotDuplicated() throws {
        try write("""
        [hooks.state]
        "\(keyPrefix):stop:0:0" = { trusted_hash = "sha256:stale", enabled = true }
        "\(keyPrefix):interrupt:0:0".trusted_hash = "sha256:stale"

        [hooks.state."\(keyPrefix):session_end:0:0"]
        enabled = false
        trusted_hash = "sha256:stale"
        """, to: configURL)
        let entries = try CodexConfigTOML(text: try read(configURL)).trustEntries()
        XCTAssertEqual(entries.map(\.trustedHash), ["sha256:stale", "sha256:stale", "sha256:stale"])
        XCTAssertEqual(entries.map(\.enabled), [true, nil, false])

        try installer.install(bridgePath: bridge)
        try assertNoDuplicateTrustKeys()
        XCTAssertFalse(try read(configURL).contains("sha256:stale"))
        XCTAssertEqual(installer.status(), .installed)
    }

    func testScannerSkipsMultilineValuesAndKeepsThem() throws {
        let original = """
        # header comment
        matrix = [
          [1, 2], # nested
          [3, 4],
        ]
        text = \"\"\"
        [hooks.state."/fake/hooks.json:stop:0:0"]
        trusted_hash = "sha256:nope" \\\"\"\"
        \"\"\"
        literal = '''
        [not.a.table]
        '''
        path = 'C:\\Users\\x'

        [[hooks.PermissionRequest]]
        [[hooks.PermissionRequest.hooks]]
        type = "command"
        command = "echo hi"

        [ features ]
        hooks = true

        """
        let doc = try CodexConfigTOML(text: original)
        XCTAssertTrue(try doc.trustEntries().isEmpty)
        XCTAssertEqual(doc.bool(at: ["features", "hooks"]), true)
        XCTAssertEqual(doc.items.filter { if case .header = $0.kind { return true }; return false }.count, 3)

        try write(original, to: configURL)
        try installer.install(bridgePath: bridge)
        XCTAssertTrue(try read(configURL).hasPrefix(original))
        XCTAssertEqual(installer.status(), .installed)
    }

    // MARK: Helpers

    /// Foreign hooks.json + config.toml where the foreign PermissionRequest hook is already trusted.
    @discardableResult
    private func writeForeignFixture() throws -> (String, String) {
        let hooksText = """
        {
          "description": "team hooks",
          "hooks": {
            "PermissionRequest": [
              {"matcher": "Bash", "hooks": [{"type": "command", "command": "\(foreignCommand)", "timeout": 30}]}
            ],
            "Stop": [{"hooks": [{"type": "mcp_tool", "server": "s", "tool": "t"}]}],
            "Notification": [{"hooks": [{"type": "command", "command": "claude-style"}]}]
          }
        }
        """
        try write(hooksText, to: hooksURL)
        let foreignHash = CodexTrust.hash(event: .permissionRequest, matcher: "Bash", command: foreignCommand, timeout: 30)
        XCTAssertEqual(foreignHash, "sha256:76bc737a224fae76e63c85d18a491c055f13e2b20f661c895ae7306d8cf996a1")
        let configText = """
        # my codex config
        model = "gpt-5.5"
        notify = ["/Applications/Some.app/SkyComputerUseClient", "turn-ended"]

        [features]
        multi_agent = true

        [desktop]
        note = \"\"\"
        [hooks.state."not-a-table"]
        \"\"\"

        [hooks.state]

        [hooks.state."\(keyPrefix):permission_request:0:0"]
        trusted_hash = "\(foreignHash)"

        [hooks.state."/Users/someone/.codex/config.toml:stop:0:0"]
        trusted_hash = "sha256:other-file"

        """
        try write(configText, to: configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        return (hooksText, configText)
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func rawHooks() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any])
    }

    private func timeout(_ events: [String: Any], _ event: CodexHookEvent) -> Int? {
        let groups = events[event.rawValue] as? [[String: Any]]
        let handlers = groups?.first?["hooks"] as? [[String: Any]]
        return (handlers?.first?["timeout"] as? NSNumber)?.intValue
    }

    private func trustedHashes() throws -> [String: String] {
        try CodexConfigTOML(text: FileManager.default.fileExists(atPath: configURL.path) ? read(configURL) : "").trustedHashes()
    }

    /// Codex's rule: the stored hash at `<realpath hooks.json>:<event>:<g>:<h>` equals the handler's hash.
    private func isTrusted(_ event: CodexHookEvent, _ position: CodexHandlerPosition) throws -> Bool {
        let file = try CodexHooksFile(text: try read(hooksURL))
        guard let hash = file.hash(event, at: position) else { return false }
        return try trustedHashes()[CodexTrust.key(hooksPath: keyPrefix, event: event, position: position)] == hash
    }

    private func assertNoDuplicateTrustKeys(file: StaticString = #filePath, line: UInt = #line) throws {
        let keys = try CodexConfigTOML(text: try read(configURL)).trustEntries().map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count, "duplicate TOML table", file: file, line: line)
    }

    private func runShell(_ command: String, stdin: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", command]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty, "hook command printed something")
        return process.terminationStatus
    }

    private func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
