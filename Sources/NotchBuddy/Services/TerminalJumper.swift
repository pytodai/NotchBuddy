import AppKit
import Darwin
import NotchBuddyCore

/// Brings a session's terminal tab / host app to the front.
///
/// `jump(to:)` decides synchronously which strategy applies and returns false only when there is
/// nothing to focus. The slow parts (AppleScript, tmux) run in the background and fall back to plain
/// app activation when they fail. No strategy launches an app that isn't running.
///
/// Every jump takes a ticket; background work of an older jump (a queued focus script, a fallback
/// activation after a timeout) stands down once a newer jump exists, so it never steals focus late.
final class TerminalJumper: TerminalJumping, Sendable {
    private let scripts = AppleScriptRunner.shared
    private let generations = JumpGenerations()

    init() {}

    @MainActor @discardableResult
    func jump(to session: AgentSession) -> Bool {
        let host = session.host
        let target = HostTarget(host)
        let ticket = generations.next()

        // Inside tmux the terminal env (bundle id, iTerm session, tty) is stale: it belongs to whoever started the server.
        if let pane = host.tmuxPane, Validate.tmuxPane(pane) {
            let fallback = target.runningApp()
            guard let tmux = TmuxFocus.executable() else {
                guard let fallback else { return false }
                AppActivator.activate(fallback, ticket: ticket)
                return true
            }
            Task { await self.focusTmux(tmux: tmux, pane: pane, socket: host.tmuxSocket, fallback: fallback, ticket: ticket) }
            return true
        }

        switch target.kind {
        case .iTerm:
            guard let app = target.runningApp() else { return false }
            focusITerm(sessionID: Validate.iTermUUID(from: host.itermSessionId), tty: verifiedTTY(host), app: app, ticket: ticket)
            return true
        case .terminalApp:
            guard let app = target.runningApp() else { return false }
            focusTerminalApp(tty: verifiedTTY(host), app: app, ticket: ticket)
            return true
        case .warp:
            guard let app = target.runningApp() else { return false }
            if let url = Validate.warpFocusURL(host.extra["WARP_FOCUS_URL"]) {
                open(url, thenActivate: app, ticket: ticket)
            } else {
                AppActivator.activate(app, ticket: ticket)
            }
            return true
        case .claudeDesktop:
            guard let app = target.runningApp() else { return false }
            // A Code session runs without a TTY; the desktop's terminal panel has one and no deep link.
            if host.tty == nil, let url = Validate.claudeContinueURL(host.extra["CLAUDE_CODE_HOST_SESSION_ID"]) {
                open(url, thenActivate: app, ticket: ticket)
            } else {
                AppActivator.activate(app, ticket: ticket)
            }
            return true
        case .codexDesktop:
            guard let app = target.runningApp() else { return false }
            if session.source == .codex, let url = Validate.codexThreadURL(session.key.sessionId) {
                open(url, thenActivate: app, ticket: ticket)
            } else {
                AppActivator.activate(app, ticket: ticket)
            }
            return true
        case .other:
            guard let app = target.runningApp() else {
                Log.info("jump: no running host app for \(session.key)")
                return false
            }
            AppActivator.activate(app, ticket: ticket)
            return true
        }
    }

    // MARK: iTerm2 / Terminal.app

    @MainActor
    private func focusITerm(sessionID: String?, tty: String?, app: NSRunningApplication, ticket: JumpTicket) {
        guard sessionID != nil || tty != nil else { return AppActivator.activate(app, ticket: ticket) }
        runFocusScript(FocusScripts.iTerm, arguments: [sessionID ?? "", tty ?? ""], app: app, label: "iTerm2", ticket: ticket)
    }

    @MainActor
    private func focusTerminalApp(tty: String?, app: NSRunningApplication, ticket: JumpTicket) {
        guard let tty else { return AppActivator.activate(app, ticket: ticket) }
        runFocusScript(FocusScripts.terminal, arguments: [tty], app: app, label: "Terminal", ticket: ticket)
    }

    /// Runs a focus script; anything but "ok" falls back to plain activation — unless a newer jump exists by then.
    @MainActor
    private func runFocusScript(_ source: String, arguments: [String], app: NSRunningApplication, label: String, ticket: JumpTicket) {
        let runner = scripts
        let bundleID = app.bundleIdentifier
        Task { @MainActor in
            let outcome = await runner.call(
                handler: FocusScripts.handler, in: source, arguments: arguments,
                target: bundleID, isCurrent: { ticket.isCurrent })
            switch outcome {
            case .success("ok"), .skipped:
                return
            case .success(let other):
                Log.info("jump: \(label) tab not found (\(other ?? "nil")); activating the app")
            case .failure(let code, let message) where code == AppleScriptOutcome.notAuthorized
                || code == AppleScriptOutcome.consentRequired:
                Log.error("jump: no Automation permission for \(label) (\(code): \(message)). "
                    + "Grant it in System Settings › Privacy & Security › Automation.")
            case .failure(let code, let message):
                Log.error("jump: \(label) AppleScript failed (\(code)): \(message)")
            case .timedOut:
                Log.info("jump: \(label) AppleScript timed out; activating the app")
            }
            AppActivator.activate(app, ticket: ticket)
        }
    }

    /// The stored TTY, unless the agent is gone or now sits on another TTY (names are recycled).
    private func verifiedTTY(_ host: HostContext) -> String? {
        guard let tty = host.tty, Validate.tty(tty) else { return nil }
        if let pid = host.agentPid, pid > 1 {
            guard let current = ProcessLookup.info(pid) else { return nil }
            if let currentTTY = current.tty, currentTTY != tty { return nil }
        }
        return tty
    }

    // MARK: URL hosts (Warp, Claude desktop, Codex desktop)

    @MainActor
    private func open(_ url: URL, thenActivate app: NSRunningApplication, ticket: JumpTicket) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { _, error in
            if let error {
                Log.error("jump: opening \(url.scheme ?? "?")://… failed: \(error.localizedDescription)")
            }
            // Stale ids are ignored silently by some hosts, so make sure the app itself comes forward.
            Task { @MainActor in AppActivator.activate(app, onlyIfNotFrontmost: true, ticket: ticket) }
        }
        // Hand the link to the very app that hosts the session, not whichever app claims the scheme.
        if let appURL = app.bundleURL {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config, completionHandler: completion)
        } else {
            NSWorkspace.shared.open(url, configuration: config, completionHandler: completion)
        }
    }

    // MARK: tmux

    /// Selects the pane on the right server, then focuses the terminal that shows the tmux client.
    /// Falls back to the (possibly stale) host app from the pane's environment.
    private func focusTmux(tmux: String, pane: String, socket: String?, fallback: NSRunningApplication?, ticket: JumpTicket) async {
        let t = TmuxFocus(executable: tmux, socket: socket.flatMap(Validate.tmuxSocket))
        guard ticket.isCurrent else { return }
        let client = await t.selectPane(pane)
        guard let client else {
            if let fallback { await AppActivator.activate(fallback, ticket: ticket) }
            return
        }
        guard let app = ProcessLookup.hostApp(ofDescendant: client.pid) else {
            if let fallback { await AppActivator.activate(fallback, ticket: ticket) }
            return
        }
        let tty = Validate.tty(client.tty) ? client.tty : nil
        await MainActor.run {
            guard ticket.isCurrent else { return }
            switch HostTarget.Kind(bundleID: app.bundleIdentifier) {
            case .iTerm: focusITerm(sessionID: nil, tty: tty, app: app, ticket: ticket)
            case .terminalApp: focusTerminalApp(tty: tty, app: app, ticket: ticket)
            default: AppActivator.activate(app, ticket: ticket)
            }
        }
    }
}

// MARK: - Host classification

/// Which app hosts the session and how to find it. Process-tree data beats inherited env.
private struct HostTarget {
    enum Kind {
        case iTerm, terminalApp, warp, claudeDesktop, codexDesktop, other

        init(bundleID: String?) {
            switch bundleID {
            case "com.googlecode.iterm2"?: self = .iTerm
            case "com.apple.Terminal"?: self = .terminalApp
            case let id? where id.hasPrefix("dev.warp.Warp"): self = .warp
            case "com.anthropic.claudefordesktop"?: self = .claudeDesktop
            case "com.openai.codex"?: self = .codexDesktop
            default: self = .other
            }
        }
    }

    /// TERM_PROGRAM → bundle id, as Claude Code maps it.
    static let termProgramBundles: [String: String] = [
        "iTerm.app": "com.googlecode.iterm2",
        "Apple_Terminal": "com.apple.Terminal",
        "WarpTerminal": "dev.warp.Warp-Stable",
        "ghostty": "com.mitchellh.ghostty",
        "kitty": "net.kovidgoyal.kitty",
        "WezTerm": "com.github.wez.wezterm",
        "vscode": "com.microsoft.VSCode",
        "zed": "dev.zed.Zed",
        "claude-desktop": "com.anthropic.claudefordesktop",
    ]

    let kind: Kind
    let bundleID: String?
    let pid: pid_t?

    init(_ host: HostContext) {
        var bundle = host.appBundleIdentifier ?? host.bundleIdentifier
            ?? host.termProgram.flatMap { Self.termProgramBundles[$0] }
        // Weak signals for app-hosted agents, used only when nothing better is known.
        if bundle == nil, host.tty == nil {
            if host.extra["CLAUDE_CODE_ENTRYPOINT"] == "claude-desktop" {
                bundle = "com.anthropic.claudefordesktop"
            } else if host.extra["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] == "Codex Desktop" {
                bundle = "com.openai.codex"
            }
        }
        bundleID = bundle
        kind = Kind(bundleID: bundle)
        pid = host.appPid
    }

    /// The live host app, or nil if it has quit (never launch it).
    func runningApp() -> NSRunningApplication? {
        if let pid, pid > 1, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
           bundleID == nil || app.bundleIdentifier == bundleID {   // guards against PID reuse
            return app
        }
        guard let bundleID else { return nil }
        // TERM_PROGRAM only says "Warp", not which release channel is running.
        let candidates = kind == .warp ? [bundleID] + Self.warpChannels.filter { $0 != bundleID } : [bundleID]
        for id in candidates {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { !$0.isTerminated }) {
                return app
            }
        }
        return nil
    }

    static let warpChannels = ["dev.warp.Warp-Stable", "dev.warp.Warp-Beta", "dev.warp.Warp-Preview"]
}

// MARK: - Jump generations

/// Monotonic jump counter shared by a jumper and its background work.
final class JumpGenerations: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: UInt64 = 0

    /// Starts a new jump; every earlier ticket stops being current.
    func next() -> JumpTicket {
        lock.lock()
        defer { lock.unlock() }
        latest &+= 1
        return JumpTicket(owner: self, number: latest)
    }

    fileprivate func isLatest(_ number: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return number == latest
    }
}

/// One jump. `isCurrent` turns false as soon as a newer jump starts (any strategy).
struct JumpTicket: Sendable {
    fileprivate let owner: JumpGenerations
    fileprivate let number: UInt64

    var isCurrent: Bool { owner.isLatest(number) }
}

// MARK: - Activation

/// macOS 14 cooperative activation with a LaunchServices fallback.
@MainActor
enum AppActivator {
    /// `ticket`: skip (and skip the delayed fallback) once a newer jump has started.
    static func activate(_ app: NSRunningApplication, onlyIfNotFrontmost: Bool = false, ticket: JumpTicket? = nil) {
        guard !app.isTerminated, ticket?.isCurrent ?? true else { return }
        if onlyIfNotFrontmost, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return }
        if app.isHidden { app.unhide() }
        NSApp.yieldActivation(to: app)
        guard app.activate(from: .current, options: [.activateAllWindows]) else {
            return openViaLaunchServices(app)
        }
        // A non-activating panel click doesn't make us the active app, so the request can be ignored silently.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            MainActor.assumeIsolated {
                if ticket?.isCurrent ?? true,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                    openViaLaunchServices(app)
                }
            }
        }
    }

    private static func openViaLaunchServices(_ app: NSRunningApplication) {
        guard !app.isTerminated, let url = app.bundleURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { Log.error("jump: activating \(url.lastPathComponent) failed: \(error.localizedDescription)") }
        }
    }
}

// MARK: - Focus scripts

/// Handlers take their values as arguments (never spliced into the source). Each returns "ok" or "not found".
private enum FocusScripts {
    static let handler = "focus"

    /// iTerm2: match the session's unique ID (UUID from ITERM_SESSION_ID); fall back to its tty.
    static let iTerm = """
    on focus(sessionID, ttyPath)
        with timeout of 5 seconds
            tell application id "com.googlecode.iterm2"
                repeat with attempt from 1 to 2
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                set matched to false
                                if attempt is 1 then
                                    if sessionID is not "" and (unique ID of s) is sessionID then set matched to true
                                else
                                    if ttyPath is not "" and (tty of s) is ttyPath then set matched to true
                                end if
                                if matched then
                                    if miniaturized of w then set miniaturized of w to false
                                    select w
                                    select t
                                    select s
                                    activate
                                    return "ok"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end repeat
            end tell
        end timeout
        return "not found"
    end focus
    """

    /// Terminal.app: tabs expose no session id, so match the tty.
    static let terminal = """
    on focus(ttyPath)
        with timeout of 5 seconds
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if (tty of t) is ttyPath then
                            if miniaturized of w then set miniaturized of w to false
                            set selected of t to true
                            set frontmost of w to true
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
        end timeout
        return "not found"
    end focus
    """
}

// MARK: - tmux

/// tmux commands for one server. tmux runs as a daemon, so the pane's own ancestry
/// never reaches the terminal: the terminal is found through the attached client instead.
private struct TmuxFocus {
    struct Client {
        let tty: String
        let pid: pid_t
        let activity: Int
        let session: String
    }

    let executable: String
    let socket: String?

    /// GUI apps get a minimal PATH, so look in the usual install locations.
    static func executable() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Makes `pane` current in its window and session and switches the most recently active client to it.
    /// Returns that client, or nil when the pane is gone or nobody is attached.
    func selectPane(_ pane: String) async -> Client? {
        guard let session = await tmux(["display-message", "-p", "-t", pane, "#{session_name}"]), !session.isEmpty else {
            Log.info("jump: tmux pane \(pane) not found")
            return nil
        }
        _ = await tmux(["select-window", "-t", pane])
        _ = await tmux(["select-pane", "-t", pane])

        let format = "#{client_tty}\t#{client_pid}\t#{client_activity}\t#{client_session}"
        let clients = (await tmux(["list-clients", "-F", format]) ?? "")
            .split(separator: "\n")
            .compactMap { line -> Client? in
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count == 4, let pid = pid_t(f[1]) else { return nil }
                return Client(tty: f[0], pid: pid, activity: Int(f[2]) ?? 0, session: f[3])
            }
        let onSession = clients.filter { $0.session == session }
        guard let client = (onSession.isEmpty ? clients : onSession).max(by: { $0.activity < $1.activity }) else {
            Log.info("jump: no tmux client attached to \(session)")
            return nil
        }
        if client.session != session {
            _ = await tmux(["switch-client", "-c", client.tty, "-t", pane])
        }
        return client
    }

    private func tmux(_ args: [String]) async -> String? {
        let full = (socket.map { ["-S", $0] } ?? []) + args
        guard let out = await Subprocess.run(executable, full, timeout: 3), out.status == 0 else { return nil }
        return String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Process lookup

private enum ProcessLookup {
    struct Info {
        let ppid: pid_t
        let tty: String?
    }

    static func info(_ pid: pid_t) -> Info? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &kp, &size, nil, 0) == 0, size > 0, kp.kp_proc.p_pid == pid else { return nil }
        var tty: String?
        let dev = kp.kp_eproc.e_tdev
        if dev != -1, let name = devname(dev, S_IFCHR) {   // -1 == NODEV: no controlling terminal
            let n = String(cString: name)
            if n.hasPrefix("tty") { tty = "/dev/" + n }
        }
        return Info(ppid: kp.kp_eproc.e_ppid, tty: tty)
    }

    /// Nearest ancestor (or `pid` itself) that is a regular GUI app. Skips helpers.
    static func hostApp(ofDescendant pid: pid_t) -> NSRunningApplication? {
        var current = pid
        var steps = 0
        while current > 1, steps < 32 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            guard let parent = info(current)?.ppid, parent != current else { return nil }
            current = parent
            steps += 1
        }
        return nil
    }
}

// MARK: - Input validation

/// Every value comes from an agent's environment; only well-formed ones are used.
private enum Validate {
    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    static func tty(_ s: String) -> Bool { matches(s, #"^/dev/ttys[0-9]{1,4}$"#) }

    /// `ITERM_SESSION_ID` = `w0t0p0:<UUID>`; only the UUID is stable.
    static func iTermUUID(from sessionID: String?) -> String? {
        guard let sessionID, let uuid = sessionID.split(separator: ":", maxSplits: 1).last.map(String.init),
              matches(uuid, #"^[0-9A-Fa-f-]{36}$"#) else { return nil }
        return uuid
    }

    static func tmuxPane(_ s: String) -> Bool { matches(s, #"^%[0-9]{1,6}$"#) }

    static func tmuxSocket(_ s: String) -> String? {
        s.hasPrefix("/") && !s.contains(where: { $0.isNewline || $0 == "\0" }) ? s : nil
    }

    static func warpFocusURL(_ s: String?) -> URL? {
        guard let s, matches(s, #"^(warp|warppreview|warpdev|warposs)://session/[0-9a-f]{32}$"#) else { return nil }
        return URL(string: s)
    }

    static func claudeContinueURL(_ hostSessionID: String?) -> URL? {
        guard let id = hostSessionID, matches(id, #"^local_[A-Za-z0-9-]{1,64}$"#) else { return nil }
        return URL(string: "claude://code/continue?session=\(id)")
    }

    static func codexThreadURL(_ threadID: String) -> URL? {
        guard matches(threadID, #"^[A-Za-z0-9_-]{1,128}$"#) else { return nil }
        return URL(string: "codex://threads/\(threadID)")
    }
}
