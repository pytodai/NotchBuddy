import Foundation

// Installers for the agents added through `AgentCatalog`. Same rules as the original
// three (`AgentHookInstaller`): back up before writing, keep foreign content, idempotent, our entries are the
// ones whose command contains `Paths.hookMarker`, refuse unparsable files, atomic writes. They are reachable
// only from Settings → «Агенты и хуки» (`AgentDescriptor.settingsOnly`).

extension HookInstallers {
    /// `/bin/sh -c '[ -x "<bridge>" ] && "<bridge>" --source <id>; exit 0'`: a missing binary makes the hook a
    /// silent no-op and the exit code is always 0 (the shape Claude's and Codex's hooks use).
    public static func guardedCommand(bridgePath: String, source: AgentSource) -> String {
        var escaped = ""
        for ch in bridgePath {
            if "\\\"$`".contains(ch) { escaped.append("\\") }
            escaped.append(ch)
        }
        let bin = "\"\(escaped)\""
        let script = "[ -x \(bin) ] && \(bin) --source \(source.rawValue); exit 0"
        return "/bin/sh -c '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The installer the catalog names for `source`, or nil (no hook system / unknown id).
    static func catalogInstaller(for descriptor: AgentDescriptor, home: URL) -> AgentHookInstaller? {
        switch descriptor.install {
        case .claudeSettings: return ClaudeHookInstaller(home: home)
        case .codexHooks: return CodexHookInstaller(home: home)
        case .kimiConfig: return KimiHookInstaller(home: home)
        case .dropInJSON(let spec): return DropInHookInstaller(source: descriptor.id, spec: spec, home: home)
        case .cursorHooks: return CursorHookInstaller(home: home)
        case .clineScripts: return ClineHookInstaller(home: home)
        case nil: return nil
        }
    }

    static func agentFound(_ source: AgentSource, home: URL) -> Bool {
        AgentDetector(home: home).isInstalled(source)
    }
}

// MARK: - Drop-in JSON file (GitHub Copilot, Grok)

/// A whole hook file NotchBuddy owns, in a folder the agent merges (`~/.copilot/hooks/*.json`,
/// `~/.grok/hooks/*.json`). Install writes it, uninstall deletes it; nothing foreign is ever inside.
public struct DropInHooksSpec: Sendable {
    public enum Layout: Sendable {
        /// `hooks.<Event> = [{hooks: [handler]}]` (Claude-style groups, no matcher).
        case groups
        /// `hooks.<Event> = [handler]` (Copilot).
        case flat
    }

    public struct Event: Sendable {
        public var name: String
        /// Seconds.
        public var timeout: Int
        public init(_ name: String, timeout: Int) { self.name = name; self.timeout = timeout }
    }

    /// Relative to home.
    public var path: String
    public var layout: Layout
    public var events: [Event]
    /// Extra top-level members, e.g. `version: 1`.
    public var topLevel: [String: JSONValue]
    /// Handler keys written with the command (`command` is always written) and with the timeout.
    public var commandKeys: [String]
    public var timeoutKeys: [String]

    public init(path: String, layout: Layout, events: [Event], topLevel: [String: JSONValue] = [:],
                commandKeys: [String] = ["command"], timeoutKeys: [String] = ["timeout"]) {
        self.path = path
        self.layout = layout
        self.events = events
        self.topLevel = topLevel
        self.commandKeys = commandKeys
        self.timeoutKeys = timeoutKeys
    }

    /// VS Code reads `command`/`timeout`, the CLI `bash`/`timeoutSec` (VS Code's schema
    /// also knows both and allows extra keys). PermissionRequest exists only in the CLI; the bridge waits
    /// ≤ 600 s, so its hook gets 900 s.
    public static let copilot = DropInHooksSpec(
        path: ".copilot/hooks/notchbuddy.json", layout: .flat,
        events: [
            Event("SessionStart", timeout: 10), Event("SessionEnd", timeout: 5),
            Event("UserPromptSubmit", timeout: 10), Event("PreToolUse", timeout: 10),
            Event("PostToolUse", timeout: 10), Event("PostToolUseFailure", timeout: 10),
            Event("PermissionRequest", timeout: 900), Event("Notification", timeout: 10),
            Event("Stop", timeout: 10), Event("SubagentStart", timeout: 10), Event("SubagentStop", timeout: 10),
            Event("PreCompact", timeout: 10), Event("ErrorOccurred", timeout: 10),
        ],
        topLevel: ["version": 1], commandKeys: ["command", "bash"], timeoutKeys: ["timeout", "timeoutSec"])

    /// ~/.grok/docs/user-guide/10-hooks.md: global drop-ins are always trusted; lifecycle events reject a
    /// matcher, so none is written; the default timeout is 5 s (all our hooks are fire-and-forget).
    public static let grok = DropInHooksSpec(
        path: ".grok/hooks/notchbuddy.json", layout: .groups,
        events: ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                 "Stop", "StopFailure", "Notification", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact"]
            .map { Event($0, timeout: 5) })

    /// The file's full text for `bridgePath`.
    func document(bridgePath: String, source: AgentSource) -> String {
        let command = JSONValue.string(HookInstallers.guardedCommand(bridgePath: bridgePath, source: source))
        var hooks: [String: JSONValue] = [:]
        for event in events {
            var handler: [String: JSONValue] = ["type": "command"]
            for key in commandKeys { handler[key] = command }
            for key in timeoutKeys { handler[key] = .number(Double(event.timeout)) }
            switch layout {
            case .flat: hooks[event.name] = [.object(handler)]
            case .groups: hooks[event.name] = [["hooks": [.object(handler)]]]
            }
        }
        var top = topLevel
        top["hooks"] = .object(hooks)
        let data = (try? JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: JSONValue.object(top).serialized()),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? JSONValue.object(top).serialized()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

public struct DropInHookInstaller: AgentHookInstaller {
    public let source: AgentSource
    public let spec: DropInHooksSpec
    public let home: URL

    public init(source: AgentSource, spec: DropInHooksSpec, home: URL = Paths.home) {
        self.source = source
        self.spec = spec
        self.home = home
    }

    public var fileURL: URL { home.appendingPathComponent(spec.path) }
    public var files: [URL] { [fileURL] }

    public func status() -> HookInstallStatus {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return HookInstallers.agentFound(source, home: home) ? .notInstalled : .agentMissing
        }
        guard let data = try? Data(contentsOf: fileURL), let root = try? JSONValue.parse(data), root.object != nil else {
            return .error(L("Не удалось разобрать %@", fileURL.path))
        }
        let hooks = root["hooks"]?.object ?? [:]
        let present = spec.events.map(\.name).filter { name in
            String(decoding: (hooks[name] ?? .null).serialized(), as: UTF8.self).contains(Paths.hookMarker)
        }
        if present.count == spec.events.count { return .installed }
        if present.isEmpty { return .notInstalled }
        let missing = spec.events.map(\.name).filter { !present.contains($0) }
        return .partial(L("Нет хуков NotchBuddy для событий: %@", missing.joined(separator: ", ")))
    }

    public func install(bridgePath: String) throws {
        let text = spec.document(bridgePath: bridgePath, source: source)
        if let current = try? String(contentsOf: fileURL, encoding: .utf8), current == text { return }
        try backupIfPresent()
        try HookInstallers.write(text, to: fileURL)
    }

    public func uninstall() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        // Never delete a file someone else wrote at our path.
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8), text.contains(Paths.hookMarker) else { return }
        try backupIfPresent()
        do { try FileManager.default.removeItem(at: fileURL) } catch {
            throw HookInstallerError.writeFailed(path: fileURL.path, reason: error.localizedDescription)
        }
    }

    private func backupIfPresent() throws {
        do { try HookInstallers.backup(fileURL, home: home) } catch {
            throw HookInstallerError.writeFailed(path: fileURL.path,
                                                 reason: L("не удалось сделать резервную копию: %@", error.localizedDescription))
        }
    }
}

// MARK: - Cursor (~/.cursor/hooks.json, shared)

/// Merges NotchBuddy's handlers into Cursor's user hook file: `{"version": 1,
/// "hooks": {"<event>": [{"command", "timeout"}]}}`. Other tools' handlers stay; the file
/// is rewritten with the order-preserving tree Claude's installer uses.
public struct CursorHookInstaller: AgentHookInstaller {
    public let home: URL
    public init(home: URL = Paths.home) { self.home = home }

    public var source: AgentSource { .cursor }
    public var hooksURL: URL { home.appendingPathComponent(".cursor/hooks.json") }
    public var files: [URL] { [hooksURL] }

    /// Status events only; `beforeShellExecution`/`beforeReadFile` are left out (they carry every command / file
    /// content). Seconds; all fire-and-forget.
    public static let events = [
        "sessionStart", "sessionEnd", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure",
        "subagentStart", "subagentStop", "preCompact", "stop",
    ]
    static let timeout = 5

    typealias Node = ClaudeHookInstaller.Node
    typealias Member = ClaudeHookInstaller.Member

    public func status() -> HookInstallStatus {
        let fm = FileManager.default
        if !fm.fileExists(atPath: hooksURL.path) {
            return HookInstallers.agentFound(source, home: home) ? .notInstalled : .agentMissing
        }
        let root: Node
        do { root = try load().root } catch { return .error(String(describing: error)) }
        let present = Self.eventsWithOurHandlers(in: root)
        let missing = Self.events.filter { !present.contains($0) }
        if missing.isEmpty { return .installed }
        if present.isEmpty {
            return HookInstallers.agentFound(source, home: home) ? .notInstalled : .agentMissing
        }
        return .partial(L("Нет хуков NotchBuddy для событий: %@", missing.joined(separator: ", ")))
    }

    public func install(bridgePath: String) throws {
        let (text, root) = try load()
        try save(try Self.installing(bridgePath: bridgePath, into: root, path: hooksURL.path), original: root, text: text)
    }

    public func uninstall() throws {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else { return }
        let (text, root) = try load()
        try save(Self.uninstalling(from: root), original: root, text: text)
    }

    private func load() throws -> (text: String?, root: Node) {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else { return (nil, .object([])) }
        guard let data = try? Data(contentsOf: hooksURL), let text = String(data: data, encoding: .utf8) else {
            throw HookInstallerError.unparsableConfig(path: hooksURL.path, reason: L("файл не читается как UTF-8"))
        }
        return (text, try ClaudeHookInstaller.parseSettings(text, path: hooksURL.path))
    }

    private func save(_ root: Node, original: Node, text: String?) throws {
        guard root != original else { return }
        var output = root.rendered()
        if text?.hasSuffix("\n") ?? true { output += "\n" }
        guard (try? JSONSerialization.jsonObject(with: Data(output.utf8))) is [String: Any] else {
            throw HookInstallerError.writeFailed(path: hooksURL.path, reason: L("получился некорректный JSON"))
        }
        do { try HookInstallers.backup(hooksURL, home: home) } catch {
            throw HookInstallerError.writeFailed(path: hooksURL.path,
                                                 reason: L("не удалось сделать резервную копию: %@", error.localizedDescription))
        }
        try HookInstallers.write(output, to: hooksURL)
    }

    static func isOurs(_ node: Node) -> Bool { ClaudeHookInstaller.isOurs(node) }

    static func installing(bridgePath: String, into root: Node, path: String) throws -> Node {
        func fail(_ reason: String) -> HookInstallerError { .unparsableConfig(path: path, reason: reason) }
        guard case .object(var top) = uninstalling(from: root) else { throw fail(L("ожидался JSON-объект")) }
        if top.value(for: "version") == nil { top.insert(Member("version", .number("1")), at: 0) }
        var hooks: [Member] = []
        if let existing = top.value(for: "hooks") {
            guard case .object(let members) = existing else { throw fail(L("поле hooks должно быть объектом")) }
            hooks = members
        }
        let handler: Node = .object([
            Member("command", .string(HookInstallers.guardedCommand(bridgePath: bridgePath, source: .cursor))),
            Member("timeout", .number(String(timeout))),
        ])
        for event in events {
            if let existing = hooks.value(for: event) {
                guard case .array(var list) = existing else { throw fail(L("hooks.%@ должно быть массивом", event)) }
                list.append(handler)
                hooks.set(event, .array(list))
            } else {
                hooks.append(Member(event, .array([handler])))
            }
        }
        top.set("hooks", .object(hooks))
        return .object(top)
    }

    /// Removes our handlers and the events they leave empty; keeps `version` and everything else.
    static func uninstalling(from root: Node) -> Node {
        guard case .object(var top) = root, case .object(let hooks)? = top.value(for: "hooks") else { return root }
        var kept: [Member] = []
        var changed = false
        for member in hooks {
            guard case .array(let list) = member.value else { kept.append(member); continue }
            let filtered = list.filter { !isOurs($0) }
            if filtered.count == list.count { kept.append(member); continue }
            changed = true
            if !filtered.isEmpty { kept.append(Member(member.key, .array(filtered))) }
        }
        guard changed else { return root }
        top.set("hooks", .object(kept))
        return .object(top)
    }

    static func eventsWithOurHandlers(in root: Node) -> Set<String> {
        guard case .object(let hooks)? = root["hooks"] else { return [] }
        return Set(hooks.filter { $0.value.arrayValue?.contains(where: isOurs) ?? false }.map(\.key))
    }
}

// MARK: - Cline (one script per event)

/// Writes `~/Documents/Cline/Hooks/<Event>`: the only folder both Cline runtimes read
/// (legacy: exactly that path, file name = event, executable = enabled). Each file is a tiny `sh` script that
/// hands stdin to the bridge; a file without our marker is never touched.
public struct ClineHookInstaller: AgentHookInstaller {
    public let home: URL
    public init(home: URL = Paths.home) { self.home = home }

    public var source: AgentSource { .cline }
    public var hooksDir: URL { home.appendingPathComponent("Documents/Cline/Hooks", isDirectory: true) }
    public var files: [URL] { ClineAdapter.events.map { hooksDir.appendingPathComponent($0) } }

    public static func script(bridgePath: String) -> String {
        """
        #!/bin/sh
        # Added by NotchBuddy (\(Paths.hookMarker)); removed by its uninstall. Prints nothing: status only.
        \(HookInstallers.guardedCommand(bridgePath: bridgePath, source: .cline))

        """
    }

    public func status() -> HookInstallStatus {
        let fm = FileManager.default
        // ~/Documents is TCC-protected: look there only when Cline is on this Mac (and then the question
        // "may NotchBuddy access Documents" comes from the Settings page the user opened).
        guard HookInstallers.agentFound(source, home: home) else { return .agentMissing }
        let ours = files.filter { url in
            fm.isExecutableFile(atPath: url.path)
                && ((try? String(contentsOf: url, encoding: .utf8))?.contains(Paths.hookMarker) ?? false)
        }
        if ours.count == files.count { return .installed }
        if ours.isEmpty { return .notInstalled }
        let missing = files.filter { !ours.contains($0) }.map(\.lastPathComponent)
        return .partial(L("Нет хуков NotchBuddy для событий: %@", missing.joined(separator: ", ")))
    }

    public func install(bridgePath: String) throws {
        let fm = FileManager.default
        let text = Self.script(bridgePath: bridgePath)
        // Refuse before writing anything if a foreign hook already owns one of the names.
        for url in files where fm.fileExists(atPath: url.path) && !isOurs(url) {
            throw HookInstallerError.unparsableConfig(
                path: url.path, reason: L("там уже есть чужой хук Cline; NotchBuddy его не трогает"))
        }
        for url in files {
            if (try? String(contentsOf: url, encoding: .utf8)) != text {
                try HookInstallers.write(text, to: url)
            }
            do { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) } catch {
                throw HookInstallerError.writeFailed(path: url.path, reason: error.localizedDescription)
            }
        }
    }

    public func uninstall() throws {
        let fm = FileManager.default
        for url in files where fm.fileExists(atPath: url.path) && isOurs(url) {
            do { try fm.removeItem(at: url) } catch {
                throw HookInstallerError.writeFailed(path: url.path, reason: error.localizedDescription)
            }
        }
    }

    private func isOurs(_ url: URL) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8))?.contains(Paths.hookMarker) ?? false
    }
}
