import Darwin
import XCTest
@testable import NotchBuddyCore

final class HostProbeTests: XCTestCase {
    // MARK: Fixtures (process trees observed on real hosts)

    private static let terminalApp = "/System/Applications/Utilities/Terminal.app"
    private static let claudeApp = "/Applications/Claude.app"
    private static let nestedClaudeCLI = "/Users/u/Library/Application Support/Claude/claude-code/2.1.284/claude.app"
    private static let warpApp = "/Applications/Warp.app"

    private static let bundles: [String: BundleInfo] = [
        terminalApp: BundleInfo(identifier: "com.apple.Terminal"),
        claudeApp: BundleInfo(identifier: "com.anthropic.claudefordesktop"),
        nestedClaudeCLI: BundleInfo(identifier: "com.anthropic.claude-code", isBackgroundOnly: true),
        warpApp: BundleInfo(identifier: "dev.warp.Warp-Stable"),
        "/Applications/Menu Thing.app": BundleInfo(identifier: "com.example.menuthing", isUIElement: true),
    ]

    private func probe(env: [String: String] = [:], parent: Int32, _ processes: [ProcessEntry]) -> HostContext {
        let table = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        return HostProbe(environment: env, parentPid: parent,
                         process: { table[$0] },
                         bundleInfo: { Self.bundles[$0] }).collect()
    }

    // MARK: Terminal apps

    func testTerminalAppChain() {
        let env = [
            "TERM_PROGRAM": "Apple_Terminal",
            "__CFBundleIdentifier": "com.apple.Terminal",
            "TERM_SESSION_ID": "8E1F0B5C-0000-4000-8000-000000000001",
            "TERM_PROGRAM_VERSION": "488",
        ]
        let host = probe(env: env, parent: 500, [
            ProcessEntry(pid: 500, ppid: 400, tty: "/dev/ttys003", path: "/Users/u/.local/share/claude/versions/2.1.185", name: "2.1.185"),
            ProcessEntry(pid: 400, ppid: 300, tty: "/dev/ttys003", path: "/bin/zsh"),
            ProcessEntry(pid: 300, ppid: 200, tty: "/dev/ttys003", path: "/usr/bin/login"),
            ProcessEntry(pid: 200, ppid: 1, path: Self.terminalApp + "/Contents/MacOS/Terminal"),
        ])
        XCTAssertEqual(host.termProgram, "Apple_Terminal")
        XCTAssertEqual(host.bundleIdentifier, "com.apple.Terminal")
        XCTAssertEqual(host.termSessionId, "8E1F0B5C-0000-4000-8000-000000000001")
        XCTAssertEqual(host.agentPid, 500)
        XCTAssertEqual(host.tty, "/dev/ttys003")
        XCTAssertEqual(host.appPid, 200)
        XCTAssertEqual(host.appPath, Self.terminalApp)
        XCTAssertEqual(host.appBundleIdentifier, "com.apple.Terminal")
        XCTAssertEqual(host.extra["TERM_PROGRAM_VERSION"], "488")
        XCTAssertNil(host.tmuxPane)
        XCTAssertNil(host.itermSessionId)
    }

    func testIntermediateShellsAreSkipped() {
        // `sh -c 'a; bridge'` keeps sh between the agent and the bridge.
        let host = probe(parent: 600, [
            ProcessEntry(pid: 600, ppid: 590, path: "/bin/sh"),
            ProcessEntry(pid: 590, ppid: 580, path: "/bin/zsh"),
            ProcessEntry(pid: 580, ppid: 400, tty: "/dev/ttys007", path: "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex"),
            ProcessEntry(pid: 400, ppid: 1, tty: "/dev/ttys007", path: "/bin/zsh"),
        ])
        XCTAssertEqual(host.agentPid, 580)
        XCTAssertEqual(host.tty, "/dev/ttys007")
        XCTAssertNil(host.appPid)
    }

    func testTTYIsTakenFromNearestAncestorOfTheAgent() {
        // The agent itself has no tty (e.g. launched detached), its parent shell does.
        let host = probe(parent: 700, [
            ProcessEntry(pid: 700, ppid: 690, path: "/usr/local/bin/kimi"),
            ProcessEntry(pid: 690, ppid: 1, tty: "/dev/ttys011", path: "/bin/zsh"),
        ])
        XCTAssertEqual(host.agentPid, 700)
        XCTAssertEqual(host.tty, "/dev/ttys011")
    }

    func testClaudePidIsPreferredWhenItIsAnAncestor() {
        let chain = [
            ProcessEntry(pid: 800, ppid: 790, path: "/usr/bin/python3"),
            ProcessEntry(pid: 790, ppid: 1, tty: "/dev/ttys002", path: "/Users/u/.local/share/claude/versions/2.1.284", name: "2.1.284"),
        ]
        XCTAssertEqual(probe(env: ["CLAUDE_PID": "790"], parent: 800, chain).agentPid, 790)
        XCTAssertEqual(probe(parent: 800, chain).agentPid, 800, "without CLAUDE_PID: first non-shell ancestor")
        XCTAssertEqual(probe(env: ["CLAUDE_PID": "12345"], parent: 800, chain).agentPid, 800,
                       "a stale CLAUDE_PID that is not an ancestor is ignored")
    }

    // MARK: Host app detection

    func testClaudeDesktopCodeSessionSkipsNestedBackgroundApp() {
        let host = probe(env: ["CLAUDE_CODE_HOST_SESSION_ID": "local_abc-123", "CLAUDE_CODE_ENTRYPOINT": "claude-desktop",
                               "__CFBundleIdentifier": "com.anthropic.claudefordesktop"],
                         parent: 900, [
            ProcessEntry(pid: 900, ppid: 890, path: Self.nestedClaudeCLI + "/Contents/MacOS/claude"),
            ProcessEntry(pid: 890, ppid: 880, path: Self.claudeApp + "/Contents/Helpers/disclaimer"),
            ProcessEntry(pid: 880, ppid: 1, path: Self.claudeApp + "/Contents/MacOS/Claude"),
        ])
        XCTAssertEqual(host.agentPid, 900)
        XCTAssertNil(host.tty)
        XCTAssertEqual(host.appPid, 880)
        XCTAssertEqual(host.appBundleIdentifier, "com.anthropic.claudefordesktop")
        XCTAssertEqual(host.extra["CLAUDE_CODE_HOST_SESSION_ID"], "local_abc-123")
        XCTAssertEqual(host.extra["CLAUDE_CODE_ENTRYPOINT"], "claude-desktop")
    }

    func testHelperAppNestedInsideAnotherBundleIsSkipped() {
        let host = probe(env: ["TERM_PROGRAM": "claude-desktop"], parent: 1000, [
            ProcessEntry(pid: 1000, ppid: 990, tty: "/dev/ttys004", path: "/Users/u/.local/share/claude/versions/2.1.185"),
            ProcessEntry(pid: 990, ppid: 980, tty: "/dev/ttys004", path: "/bin/zsh"),
            ProcessEntry(pid: 980, ppid: 970,
                         path: Self.claudeApp + "/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"),
            ProcessEntry(pid: 970, ppid: 1, path: Self.claudeApp + "/Contents/MacOS/Claude"),
        ])
        XCTAssertEqual(host.appPid, 970)
        XCTAssertEqual(host.appPath, Self.claudeApp)
    }

    func testOutermostProcessOfTheSameBundleIsTheApp() {
        // Warp: agent → zsh → stable (pty server) → stable (the app).
        let host = probe(env: ["WARP_FOCUS_URL": "warp://session/438eab7f93a2400fbecb55242eb99e4e"], parent: 1100, [
            ProcessEntry(pid: 1100, ppid: 1090, tty: "/dev/ttys009", path: "/opt/homebrew/bin/node"),
            ProcessEntry(pid: 1090, ppid: 1080, tty: "/dev/ttys009", path: "/bin/zsh"),
            ProcessEntry(pid: 1080, ppid: 1070, path: Self.warpApp + "/Contents/MacOS/stable"),
            ProcessEntry(pid: 1070, ppid: 1, path: Self.warpApp + "/Contents/MacOS/stable"),
        ])
        XCTAssertEqual(host.appPid, 1070)
        XCTAssertEqual(host.appBundleIdentifier, "dev.warp.Warp-Stable")
        XCTAssertEqual(host.extra["WARP_FOCUS_URL"], "warp://session/438eab7f93a2400fbecb55242eb99e4e")
    }

    func testUIElementAndUnknownBundlesAreNotHostApps() {
        let host = probe(parent: 1200, [
            ProcessEntry(pid: 1200, ppid: 1190, path: "/opt/homebrew/bin/node"),
            ProcessEntry(pid: 1190, ppid: 1180, path: "/Applications/Menu Thing.app/Contents/MacOS/Menu Thing"),
            ProcessEntry(pid: 1180, ppid: 1, path: "/Applications/Unreadable.app/Contents/MacOS/Unreadable"),
        ])
        XCTAssertNil(host.appPid)
        XCTAssertNil(host.appPath)
    }

    func testTopLevelAppBundleParsing() {
        XCTAssertEqual(HostProbe.topLevelAppBundle(forExecutable: "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
                       "/Applications/iTerm.app")
        XCTAssertNil(HostProbe.topLevelAppBundle(forExecutable: "/Applications/Claude.app/Contents/Helpers/disclaimer"))
        XCTAssertNil(HostProbe.topLevelAppBundle(
            forExecutable: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"))
        XCTAssertNil(HostProbe.topLevelAppBundle(forExecutable: "/Applications/X.app/Contents/MacOS/sub/tool"))
        XCTAssertNil(HostProbe.topLevelAppBundle(forExecutable: "/usr/bin/login"))
        XCTAssertNil(HostProbe.topLevelAppBundle(forExecutable: ""))
    }

    // MARK: Environment

    func testTmuxAndITermFields() {
        let host = probe(env: [
            "TMUX": "/private/tmp/tmux-501/default,4242,0",
            "TMUX_PANE": "%3",
            "ITERM_SESSION_ID": "w0t1p0:4CAE163E-37A6-424C-8F5C-4C7D8BF58D47",
            "TERM_PROGRAM": "tmux",
        ], parent: 1300, [ProcessEntry(pid: 1300, ppid: 1, tty: "/dev/ttys012", path: "/opt/homebrew/bin/codex")])
        XCTAssertEqual(host.tmuxSocket, "/private/tmp/tmux-501/default")
        XCTAssertEqual(host.tmuxPane, "%3")
        XCTAssertEqual(host.itermSessionId, "w0t1p0:4CAE163E-37A6-424C-8F5C-4C7D8BF58D47")
        XCTAssertEqual(host.extra["TMUX"], "/private/tmp/tmux-501/default,4242,0")
    }

    func testExtraIsAllowlistedAndSkipsEmptyOrHugeValues() {
        let host = probe(env: [
            "KITTY_WINDOW_ID": "7",
            "WEZTERM_PANE": "3",
            "GHOSTTY_SURFACE_ID": "99",
            "CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "Codex Desktop",
            "CLAUDE_CODE_OAUTH_TOKEN": "secret",
            "ANTHROPIC_API_KEY": "secret",
            "GITHUB_TOKEN": "secret",
            "CURSOR_TRACE_ID": "",
            "VSCODE_GIT_IPC_HANDLE": String(repeating: "x", count: 5000),
            "TERM_PROGRAM": "",
        ], parent: 1400, [])
        XCTAssertEqual(host.extra, [
            "KITTY_WINDOW_ID": "7",
            "WEZTERM_PANE": "3",
            "GHOSTTY_SURFACE_ID": "99",
            "CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "Codex Desktop",
        ])
        XCTAssertNil(host.termProgram, "empty env values count as unset")
    }

    // MARK: Degenerate trees

    func testNoProcessInfoFallsBackToParentPid() {
        let host = probe(parent: 1500, [])
        XCTAssertEqual(host.agentPid, 1500)
        XCTAssertNil(host.tty)
        XCTAssertNil(host.appPid)
    }

    func testCyclicParentLinksTerminate() {
        let host = probe(parent: 1600, [
            ProcessEntry(pid: 1600, ppid: 1601, path: "/bin/sh"),
            ProcessEntry(pid: 1601, ppid: 1600, path: "/bin/zsh"),
        ])
        XCTAssertEqual(host.agentPid, 1600, "only shells: fall back to the nearest ancestor")
    }

    // MARK: Live system

    func testLiveProcessLookup() throws {
        let me = try XCTUnwrap(ProcessTree.entry(getpid()))
        XCTAssertEqual(me.pid, getpid())
        XCTAssertEqual(me.ppid, getppid())
        XCTAssertFalse(me.path.isEmpty)
        XCTAssertNil(ProcessTree.entry(-5))
    }

    func testLiveProbeIsFast() {
        let start = Date()
        let host = HostProbe().collect()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNotNil(host.agentPid)
        XCTAssertLessThan(elapsed, 0.2, "probe took \(Int(elapsed * 1000)) ms")
    }
}
