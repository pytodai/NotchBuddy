import Foundation

/// Everything NotchBuddy knows about one agent, as data: names and colors for the UI, how to tell it is
/// installed, which hook protocol and installer it uses, and what the island may answer.
///
/// Adding an agent: write one descriptor in `AgentCatalog.all`. A Claude-compatible agent (Claude-shaped
/// JSON payloads, see `ClaudeCompatibleProfile`) that owns a whole drop-in hook file needs no other code;
/// a new wire format needs an adapter (`ProtocolFamily`) and maybe an installer (`InstallFamily`).
public struct AgentDescriptor: Sendable, Identifiable {
    public enum Kind: String, Sendable { case cli, ide, desktop, plugin }

    /// How the island can answer this agent's permission requests.
    public enum DecisionCapability: String, Sendable {
        /// Real allow / deny, and "no answer" falls back to the agent's own prompt (Claude, Codex, Copilot CLI).
        case full
        /// Only a pre-tool hook that fires for every call (Cursor, Grok): shown, not answered, on the island.
        case gate
        /// The hook can only block (Cline).
        case denyOnly
        /// Status only (Kimi).
        case observe
    }

    /// The code that parses this agent's hook stdin and renders decisions (`Adapters.adapter(for:)`).
    public enum ProtocolFamily: Sendable {
        case claude, codex, kimi
        /// Claude-shaped payloads described by data (`ClaudeCompatibleAdapter`).
        case claudeCompatible(ClaudeCompatibleProfile)
        case cursor
        case cline
    }

    /// The code that edits this agent's hook config (`HookInstallers.installer(for:)`).
    public enum InstallFamily: Sendable {
        case claudeSettings, codexHooks, kimiConfig
        /// A whole JSON file NotchBuddy owns (`DropInHookInstaller`).
        case dropInJSON(DropInHooksSpec)
        /// NotchBuddy's entries merged into the shared `~/.cursor/hooks.json` (`CursorHookInstaller`).
        case cursorHooks
        /// One executable per event in Cline's hooks folder (`ClineHookInstaller`).
        case clineScripts
    }

    /// "Installed" means a binary or an app / extension exists; a config dir alone is not enough
    /// (another tool may have created it). Absolute paths are resolved against the
    /// detector's root, relative ones against home.
    public struct Detection: Sendable {
        /// Executable names looked up in `AgentDetector.binaryDirs` plus `extraBinaryDirs`.
        public var binaries: [String]
        /// Extra directories (relative to home) to look for the binaries in, e.g. ".grok/bin".
        public var extraBinaryDirs: [String]
        /// Paths whose existence proves an install, e.g. "/Applications/Cursor.app".
        public var paths: [String]
        /// "<dir>/<prefix>": a directory entry in `<dir>` whose name starts with `<prefix>` (versioned
        /// extension folders such as ".vscode/extensions/saoudrizwan.claude-dev-").
        public var prefixedEntries: [String]

        public init(binaries: [String] = [], extraBinaryDirs: [String] = [], paths: [String] = [],
                    prefixedEntries: [String] = []) {
            self.binaries = binaries
            self.extraBinaryDirs = extraBinaryDirs
            self.paths = paths
            self.prefixedEntries = prefixedEntries
        }
    }

    /// A sign that a hook process was started by this agent (hook bleed): hosts such as
    /// Cursor and Grok also run the hooks other agents registered, with their own payloads.
    public enum HostMarker: Sendable, Equatable {
        /// The stdin JSON object has this key.
        case payloadKey(String)
        /// This environment variable is set and non-empty.
        case env(String)
        /// Env `env` equals the payload's string at `payloadKey`: proves the invocation is this agent's own
        /// (Claude exports `CLAUDE_CODE_SESSION_ID` = stdin `session_id` to every hook it runs).
        case envMatchesPayload(env: String, payloadKey: String)

        func matches(payload: JSONValue?, env environment: [String: String]) -> Bool {
            switch self {
            case .payloadKey(let key):
                guard let value = payload?[key] else { return false }
                return !value.isNull
            case .env(let name):
                return !(environment[name] ?? "").isEmpty
            case .envMatchesPayload(let name, let key):
                guard let value = environment[name], !value.isEmpty else { return false }
                return payload?[key]?.string == value
            }
        }
    }

    public var id: AgentSource
    public var displayName: String
    public var shortName: String
    public var kind: Kind
    /// Badge colors (0xRRGGBB) and a one- or two-character glyph for agents without a drawn mark.
    public var tint: UInt32
    public var tintDeep: UInt32
    public var glyph: String
    /// The agent's GUI app, if any: its icon (`AgentAppIcon`).
    public var appBundleIdentifiers: [String]
    public var appNames: [String]
    public var detection: Detection
    public var protocolFamily: ProtocolFamily
    public var install: InstallFamily?
    public var decisions: DecisionCapability
    /// How this agent's invocations of foreign hooks can be recognized.
    public var hostMarkers: [HostMarker]
    /// Any of these proves an invocation is this agent's own, whatever `hostMarkers` of others say.
    public var selfProof: [HostMarker]
    /// False for the original three: their installers are also offered by the menu bar, the first-launch
    /// alert and `notchbuddy-bridge hooks`. True = the installer runs only from Settings → «Агенты и хуки».
    public var settingsOnly: Bool
    /// Settings subtitle: what the island can do for this agent (the Russian key; `capabilityNote` is localized).
    public var capabilityNoteKey: String?
    /// Shown after a successful install (restart needed…); nil = nothing to say. The key; `restartNote` is localized.
    public var restartNoteKey: String?

    /// Settings subtitle: what the island can do for this agent, in the interface language.
    public var capabilityNote: String? { capabilityNoteKey.map { L($0) } }
    /// Shown after a successful install, in the interface language.
    public var restartNote: String? { restartNoteKey.map { L($0) } }

    public init(id: AgentSource, displayName: String, shortName: String, kind: Kind, tint: UInt32, tintDeep: UInt32,
                glyph: String, appBundleIdentifiers: [String] = [], appNames: [String] = [],
                detection: Detection, protocolFamily: ProtocolFamily, install: InstallFamily?,
                decisions: DecisionCapability, hostMarkers: [HostMarker] = [], selfProof: [HostMarker] = [],
                settingsOnly: Bool = true, capabilityNote: String? = nil, restartNote: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.shortName = shortName
        self.kind = kind
        self.tint = tint
        self.tintDeep = tintDeep
        self.glyph = glyph
        self.appBundleIdentifiers = appBundleIdentifiers
        self.appNames = appNames
        self.detection = detection
        self.protocolFamily = protocolFamily
        self.install = install
        self.decisions = decisions
        self.hostMarkers = hostMarkers
        self.selfProof = selfProof
        self.settingsOnly = settingsOnly
        self.capabilityNoteKey = capabilityNote
        self.restartNoteKey = restartNote
    }
}

/// The agents NotchBuddy supports. Compiled into both the app and the bridge (the bridge is copied alone to
/// `~/.notchbuddy/bin`, so descriptors cannot live in a resource bundle).
public enum AgentCatalog {
    public static let all: [AgentDescriptor] = [
        // MARK: The original three (behavior unchanged; their code predates the catalog).
        AgentDescriptor(
            id: .claude, displayName: "Claude Code", shortName: "Claude", kind: .cli,
            tint: 0xD97857, tintDeep: 0xB8573B, glyph: "✳", appBundleIdentifiers: ["com.anthropic.claudefordesktop"],
            appNames: ["Claude.app"], detection: .init(paths: [".claude"]), protocolFamily: .claude,
            install: .claudeSettings, decisions: .full,
            selfProof: [.envMatchesPayload(env: "CLAUDE_CODE_SESSION_ID", payloadKey: "session_id")],
            settingsOnly: false, capabilityNote: LKey("Статус и разрешения с острова")),
        AgentDescriptor(
            id: .codex, displayName: "Codex", shortName: "Codex", kind: .cli,
            tint: 0xF0F0F0, tintDeep: 0xBDBDBD, glyph: ">_", appBundleIdentifiers: ["com.openai.codex"],
            appNames: ["Codex.app", "ChatGPT.app"], detection: .init(paths: [".codex"]), protocolFamily: .codex,
            install: .codexHooks, decisions: .full, settingsOnly: false,
            capabilityNote: LKey("Статус и разрешения с острова"),
            restartNote: LKey("Codex: новые сессии подхватят хуки; уже запущенные лучше перезапустить.")),
        AgentDescriptor(
            id: .kimi, displayName: "Kimi Code", shortName: "Kimi", kind: .cli,
            tint: 0x7873FF, tintDeep: 0x5445DB, glyph: "K", appBundleIdentifiers: ["com.moonshot.kimichat"],
            appNames: ["Kimi.app"], detection: .init(paths: [".kimi-code"]), protocolFamily: .kimi,
            install: .kimiConfig, decisions: .observe, settingsOnly: false,
            capabilityNote: LKey("Только статус: разрешения — в Kimi"),
            restartNote: LKey("Kimi Code: перезапусти его, чтобы хуки заработали.")),

        // MARK: Other agents with hook systems
        // Cursor IDE and `cursor-agent` share ~/.cursor/hooks.json. No "waiting for you" and
        // no PermissionRequest event: status only. Cursor also runs ~/.claude hooks with its own payloads.
        AgentDescriptor(
            id: .cursor, displayName: "Cursor", shortName: "Cursor", kind: .ide,
            tint: 0x2B2B2B, tintDeep: 0x121212, glyph: "▲",
            appBundleIdentifiers: ["com.todesktop.230313mzl4w4u92"], appNames: ["Cursor.app"],
            detection: .init(binaries: ["cursor-agent"], paths: ["/Applications/Cursor.app", "Applications/Cursor.app"]),
            protocolFamily: .cursor, install: .cursorHooks, decisions: .gate,
            hostMarkers: [.payloadKey("cursor_version")],
            capabilityNote: LKey("Только статус: у Cursor нет события «ждёт тебя»"),
            restartNote: LKey("Cursor: новые чаты подхватят хуки; если нет — перезапусти Cursor.")),
        // GitHub Copilot: VS Code agent mode and the Copilot CLI read ~/.copilot/hooks/*.json.
        // PascalCase event names give Claude-shaped snake_case payloads. Only the CLI has PermissionRequest.
        AgentDescriptor(
            id: .copilot, displayName: "GitHub Copilot", shortName: "Copilot", kind: .ide,
            tint: 0x8A63D2, tintDeep: 0x5B3BA0, glyph: "⌘",
            appBundleIdentifiers: ["com.microsoft.VSCode"], appNames: ["Visual Studio Code.app"],
            detection: .init(binaries: ["copilot"],
                             paths: ["/Applications/Visual Studio Code.app", "Applications/Visual Studio Code.app",
                                     "/Applications/Visual Studio Code - Insiders.app"]),
            protocolFamily: .claudeCompatible(.copilot), install: .dropInJSON(.copilot), decisions: .full,
            capabilityNote: LKey("VS Code — статус; Copilot CLI — ещё и разрешения"),
            restartNote: LKey("Copilot: новые чаты подхватят хуки (в VS Code должен быть включён chat.useHooks).")),
        // Cline VS Code extension: one executable per event in ~/Documents/Cline/Hooks.
        AgentDescriptor(
            id: .cline, displayName: "Cline", shortName: "Cline", kind: .plugin,
            tint: 0x3C3C3C, tintDeep: 0x1E1E1E, glyph: "C",
            detection: .init(binaries: ["cline"],
                             prefixedEntries: [".vscode/extensions/saoudrizwan.claude-dev-",
                                               ".cursor/extensions/saoudrizwan.claude-dev-"]),
            protocolFamily: .cline, install: .clineScripts, decisions: .denyOnly,
            capabilityNote: LKey("Только статус: разрешения — в Cline"),
            restartNote: LKey("Cline: хуки видны в его настройках (Hooks); проверь, что они включены.")),
        // xAI Grok CLI: ~/.grok/hooks/*.json drop-ins, Claude-style groups, camelCase payloads (~/.grok/docs
        // user-guide/10-hooks.md). Only PreToolUse can block (gate). Grok also runs ~/.claude and ~/.cursor hooks.
        AgentDescriptor(
            id: .grok, displayName: "Grok CLI", shortName: "Grok", kind: .cli,
            tint: 0xE6E6E6, tintDeep: 0xA8A8A8, glyph: "G",
            detection: .init(binaries: ["grok"], extraBinaryDirs: [".grok/bin"]),
            protocolFamily: .claudeCompatible(.grok), install: .dropInJSON(.grok), decisions: .gate,
            hostMarkers: [.env("GROK_HOOK_EVENT")],
            capabilityNote: LKey("Только статус: разрешения — в Grok"),
            restartNote: LKey("Grok: новые сессии подхватят хуки; в запущенной — /hooks, затем r.")),
    ]

    private static let byId: [AgentSource: AgentDescriptor] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func descriptor(for source: AgentSource) -> AgentDescriptor? { byId[source] }

    /// Agents listed in Settings → «Агенты и хуки»: every catalog agent that has an installer.
    public static var settingsAgents: [AgentSource] { all.filter { $0.install != nil }.map(\.id) }

    /// When a hook registered for `source` was actually run by another catalog agent (hook bleed), that agent;
    /// nil when the invocation is `source`'s own or cannot be told apart.
    /// The bridge drops such invocations: the host agent has its own adapter and installer, and reporting
    /// the same turn twice (or a Cursor chat as a phantom Claude session) is worse than reporting it once.
    public static func foreignHost(for source: AgentSource, payload: JSONValue?, env: [String: String]) -> AgentSource? {
        if let own = descriptor(for: source), own.selfProof.contains(where: { $0.matches(payload: payload, env: env) }) {
            return nil
        }
        for other in all where other.id != source {
            if other.hostMarkers.contains(where: { $0.matches(payload: payload, env: env) }) { return other.id }
        }
        return nil
    }
}

/// Whether an agent is installed on this Mac (read-only file checks).
public struct AgentDetector: Sendable {
    /// Where CLIs usually live; `extraBinaryDirs` of a descriptor are added. Relative = under home.
    public static let binaryDirs = [".local/bin", "/opt/homebrew/bin", "/usr/local/bin", ".bun/bin",
                                    ".npm-global/bin", ".volta/bin", "bin"]

    public var home: URL
    /// Prefix for absolute paths, so tests can point detection at a fake file system.
    public var root: URL

    /// `root` nil: "/" for the user's real home; a relocated home (tests, `NOTCHBUDDY_HOME`) is also the root,
    /// so apps and binaries of the real Mac never leak into it.
    public init(home: URL = Paths.home, root: URL? = nil) {
        self.home = home
        let realHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        self.root = root ?? (home.standardizedFileURL.path == realHome ? URL(fileURLWithPath: "/") : home)
    }

    func resolve(_ path: String) -> URL {
        path.hasPrefix("/") ? root.appendingPathComponent(String(path.dropFirst())) : home.appendingPathComponent(path)
    }

    public func isInstalled(_ descriptor: AgentDescriptor) -> Bool {
        let fm = FileManager.default
        let d = descriptor.detection
        for name in d.binaries {
            for dir in Self.binaryDirs + d.extraBinaryDirs where fm.isExecutableFile(atPath: resolve(dir).appendingPathComponent(name).path) {
                return true
            }
        }
        if d.paths.contains(where: { fm.fileExists(atPath: resolve($0).path) }) { return true }
        for entry in d.prefixedEntries {
            let url = resolve(entry)
            let prefix = url.lastPathComponent
            let names = (try? fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
            if names.contains(where: { $0.hasPrefix(prefix) }) { return true }
        }
        return false
    }

    public func isInstalled(_ source: AgentSource) -> Bool {
        AgentCatalog.descriptor(for: source).map(isInstalled) ?? false
    }
}
