import Darwin
import Foundation

// Collects `HostContext` inside the bridge: where the agent runs (terminal, tab, tmux pane, host app).
// Darwin + Foundation only (no AppKit): the bridge must start fast.

/// One process of the bridge's ancestry.
public struct ProcessEntry: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    /// Controlling terminal, e.g. "/dev/ttys003"; nil when none.
    public var tty: String?
    /// Executable path (proc_pidpath); "" when unavailable.
    public var path: String
    /// Kernel p_comm (≤16 chars; for symlinked executables it is the target's name).
    public var name: String

    public init(pid: Int32, ppid: Int32, tty: String? = nil, path: String, name: String? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.tty = tty
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
    }
}

/// The parts of an app bundle's Info.plist that decide whether it is a user-facing app.
public struct BundleInfo: Equatable, Sendable {
    public var identifier: String?
    public var packageType: String?
    /// LSUIElement: agent app without Dock icon (helpers, menu-bar utilities).
    public var isUIElement: Bool
    /// LSBackgroundOnly: e.g. the nested `claude.app` of Claude desktop.
    public var isBackgroundOnly: Bool

    public init(identifier: String?, packageType: String? = "APPL", isUIElement: Bool = false, isBackgroundOnly: Bool = false) {
        self.identifier = identifier
        self.packageType = packageType
        self.isUIElement = isUIElement
        self.isBackgroundOnly = isBackgroundOnly
    }

    /// Reads `<bundle>/Contents/Info.plist`.
    public static func read(bundlePath: String) -> BundleInfo? {
        let url = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        func flag(_ key: String) -> Bool {
            switch plist[key] {
            case let b as Bool: return b
            case let n as NSNumber: return n.boolValue
            case let s as String: return ["1", "yes", "true"].contains(s.lowercased())
            default: return false
            }
        }
        return BundleInfo(identifier: plist["CFBundleIdentifier"] as? String,
                          packageType: plist["CFBundlePackageType"] as? String,
                          isUIElement: flag("LSUIElement"),
                          isBackgroundOnly: flag("LSBackgroundOnly"))
    }
}

public enum ProcessTree {
    /// One process via sysctl(KERN_PROC_PID) + proc_pidpath. Nil if it doesn't exist (or isn't visible).
    public static func entry(_ pid: Int32) -> ProcessEntry? {
        guard pid > 0 else { return nil }
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &kp, &size, nil, 0) == 0, size > 0, kp.kp_proc.p_pid == pid else {
            return nil
        }
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : ""
        var comm = kp.kp_proc.p_comm
        let name = withUnsafeBytes(of: &comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return ProcessEntry(pid: pid, ppid: kp.kp_eproc.e_ppid, tty: ttyPath(kp.kp_eproc.e_tdev), path: path, name: name)
    }

    /// "/dev/ttysNNN" for a controlling-terminal device, nil for NODEV (-1).
    static func ttyPath(_ dev: dev_t) -> String? {
        guard dev != -1 else { return nil }
        var buffer = [CChar](repeating: 0, count: 128)
        guard devname_r(dev, S_IFCHR, &buffer, Int32(buffer.count)) != nil else { return nil }
        let name = String(cString: buffer)
        guard name.hasPrefix("tty") || name == "console" else { return nil }
        return "/dev/" + name
    }
}

/// Builds a `HostContext` from the environment and the process tree. Lookups are injectable for tests.
public struct HostProbe {
    public var environment: [String: String]
    /// Where the ancestry walk starts: the bridge's parent.
    public var parentPid: Int32
    public var process: (Int32) -> ProcessEntry?
    public var bundleInfo: (String) -> BundleInfo?

    static let maxAncestors = 32

    /// Wrappers between the agent and the bridge (sh -c / zsh -c may stay in the chain).
    static let shellNames: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "login"]

    /// Env vars forwarded in `HostContext.extra`. Never forward the whole environment: it holds tokens.
    public static let extraAllowlist: [String] = [
        "TERM_PROGRAM_VERSION", "LC_TERMINAL", "TERMINAL_EMULATOR", "TMUX", "STY", "WINDOW",
        "ZELLIJ_SESSION_NAME", "ZELLIJ_PANE_ID",
        "KITTY_WINDOW_ID", "KITTY_PID", "KITTY_LISTEN_ON", "WEZTERM_PANE", "WEZTERM_UNIX_SOCKET",
        "WARP_FOCUS_URL", "WARP_TERMINAL_SESSION_UUID", "GHOSTTY_RESOURCES_DIR", "GHOSTTY_SURFACE_ID",
        "VSCODE_PID", "VSCODE_IPC_HOOK_CLI", "VSCODE_GIT_IPC_HANDLE", "CURSOR_TRACE_ID",
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_HOST_SESSION_ID", "CLAUDE_CODE_SESSION_ID", "CLAUDE_PID",
        "CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "CODEX_THREAD_ID", "CODEX_SESSION_ID",
        "SSH_CONNECTION", "SSH_TTY", "CMUX_SOCKET_PATH", "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID",
        // Hook runners of catalog agents (session / event / cwd fallbacks). Never CURSOR_USER_EMAIL (PII).
        "GROK_HOOK_EVENT", "GROK_SESSION_ID", "GROK_WORKSPACE_ROOT", "CURSOR_PROJECT_DIR",
    ]
    static let maxExtraValueLength = 1024

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                parentPid: Int32 = getppid(),
                process: @escaping (Int32) -> ProcessEntry? = ProcessTree.entry,
                bundleInfo: @escaping (String) -> BundleInfo? = BundleInfo.read) {
        self.environment = environment
        self.parentPid = parentPid
        self.process = process
        self.bundleInfo = bundleInfo
    }

    /// The bridge's own host context.
    public static func current() -> HostContext { HostProbe().collect() }

    public func collect() -> HostContext {
        var host = HostContext()
        host.termProgram = env("TERM_PROGRAM")
        host.bundleIdentifier = env("__CFBundleIdentifier")
        host.itermSessionId = env("ITERM_SESSION_ID")
        host.termSessionId = env("TERM_SESSION_ID")
        host.tmuxPane = env("TMUX_PANE")
        host.tmuxSocket = env("TMUX").flatMap { tmux in
            tmux.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        }.flatMap { $0.isEmpty ? nil : $0 }

        let chain = ancestry()
        if let agentIndex = agentIndex(in: chain) {
            host.agentPid = chain[agentIndex].pid
            host.tty = chain[agentIndex...].first { $0.tty != nil }?.tty
        } else if parentPid > 1 {
            host.agentPid = parentPid
        }
        if let app = hostApp(in: chain) {
            host.appPid = app.pid
            host.appPath = app.bundlePath
            host.appBundleIdentifier = app.identifier
        }

        var extra: [String: String] = [:]
        for key in Self.extraAllowlist {
            if let value = env(key), value.count <= Self.maxExtraValueLength { extra[key] = value }
        }
        host.extra = extra
        return host
    }

    // MARK: Steps

    private func env(_ key: String) -> String? {
        guard let value = environment[key], !value.isEmpty else { return nil }
        return value
    }

    /// Ancestors from the bridge's parent upward, nearest first, stopping before launchd.
    func ancestry() -> [ProcessEntry] {
        var chain: [ProcessEntry] = []
        var seen = Set<Int32>()
        var pid = parentPid
        while pid > 1, chain.count < Self.maxAncestors, seen.insert(pid).inserted, let entry = process(pid) {
            chain.append(entry)
            pid = entry.ppid
        }
        return chain
    }

    /// CLAUDE_PID (Claude Code ≥ 2.1.284) when it is really one of our ancestors,
    /// otherwise the first ancestor that is not a shell wrapper.
    func agentIndex(in chain: [ProcessEntry]) -> Int? {
        if let claudePid = env("CLAUDE_PID").flatMap({ Int32($0) }),
           let index = chain.firstIndex(where: { $0.pid == claudePid }) {
            return index
        }
        if let index = chain.firstIndex(where: { !isShell($0) }) { return index }
        return chain.isEmpty ? nil : 0
    }

    private func isShell(_ entry: ProcessEntry) -> Bool {
        let base = (entry.path as NSString).lastPathComponent
        return Self.shellNames.contains(base) || Self.shellNames.contains(entry.name)
    }

    struct HostApp: Equatable {
        var pid: Int32
        var bundlePath: String
        var identifier: String?
    }

    /// Nearest ancestor running the main executable of a regular, top-level app bundle.
    /// Skips helpers nested in another bundle (Claude Helper.app, Code Helper.app) and
    /// LSUIElement / LSBackgroundOnly bundles (the nested claude.app of Claude desktop).
    /// When several consecutive ancestors run the same bundle (Warp's pty server under Warp),
    /// the outermost one is the app.
    func hostApp(in chain: [ProcessEntry]) -> HostApp? {
        var infoCache: [String: BundleInfo?] = [:]
        func isRegularApp(_ bundlePath: String) -> BundleInfo? {
            if let cached = infoCache[bundlePath] { return cached }
            var result: BundleInfo?
            if let info = bundleInfo(bundlePath), !info.isUIElement, !info.isBackgroundOnly,
               info.packageType == nil || info.packageType == "APPL" {
                result = info
            }
            infoCache[bundlePath] = result
            return result
        }

        for (index, entry) in chain.enumerated() {
            guard let bundlePath = Self.topLevelAppBundle(forExecutable: entry.path),
                  let info = isRegularApp(bundlePath) else { continue }
            var outermost = entry
            for next in chain[(index + 1)...] {
                guard Self.topLevelAppBundle(forExecutable: next.path) == bundlePath else { break }
                outermost = next
            }
            return HostApp(pid: outermost.pid, bundlePath: bundlePath, identifier: info.identifier)
        }
        return nil
    }

    /// "/Applications/X.app" for "/Applications/X.app/Contents/MacOS/x"; nil for anything else,
    /// including bundles nested inside another bundle.
    static func topLevelAppBundle(forExecutable path: String) -> String? {
        let marker = ".app/Contents/MacOS/"
        guard let range = path.range(of: marker, options: .backwards) else { return nil }
        let executable = path[range.upperBound...]
        guard !executable.isEmpty, !executable.contains("/") else { return nil }
        let bundlePath = String(path[..<range.lowerBound]) + ".app"
        let parent = (bundlePath as NSString).deletingLastPathComponent
        guard !(parent + "/").contains(".app/") else { return nil }
        return bundlePath
    }
}
