import Foundation

/// Registers NotchBuddy in `~/.codex/hooks.json` and trusts those hooks in `~/.codex/config.toml`.
/// Untrusted Codex hooks silently never run, so both files are part of one install.
///
/// Trust keys contain the group/handler index inside each event array. To keep other tools' hooks
/// trusted, our group is updated in place when it already exists and appended after all foreign
/// groups otherwise; whenever removing our entries shifts a foreign handler, its trust table is
/// renamed to the new index (the hash does not depend on the position).
public struct CodexHookInstaller: AgentHookInstaller {
    public let home: URL
    /// File writer; tests swap it to simulate a failing write.
    var writeFile: @Sendable (String, URL) throws -> Void = { try HookInstallers.write($0, to: $1) }

    public init(home: URL = Paths.home) { self.home = home }

    public var source: AgentSource { .codex }
    var codexDir: URL { home.appendingPathComponent(".codex", isDirectory: true) }
    var hooksURL: URL { codexDir.appendingPathComponent("hooks.json") }
    var configURL: URL { codexDir.appendingPathComponent("config.toml") }
    public var files: [URL] { [hooksURL, configURL] }

    /// Guarded command (same shape as `Paths.hookCommand`): a missing bridge never breaks Codex.
    public static func hookCommand(bridgePath: String) -> String {
        var quotedPath = "\""
        for c in bridgePath {
            if "\\\"$`".contains(c) { quotedPath.append("\\") }
            quotedPath.append(c)
        }
        quotedPath += "\""
        let script = "[ -x \(quotedPath) ] && \(quotedPath) --source \(AgentSource.codex.rawValue); exit 0"
        return "/bin/sh -c '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Seconds. SessionEnd/Interrupt are capped at 3 by Codex; the permission wait must outlast
    /// the bridge's own decision deadline (`CodexAdapter.decisionTimeout`).
    static func timeout(for event: CodexHookEvent) -> Int {
        switch event {
        case .permissionRequest: return 900
        case .sessionEnd, .interrupt: return 3
        default: return 10
        }
    }

    static func ourGroup(event: CodexHookEvent, command: String) -> JSONValue {
        ["hooks": [["type": "command", "command": .string(command), "timeout": .number(Double(timeout(for: event)))]]]
    }

    /// hooks.json paths used in trust keys. Codex keys a symlinked CODEX_HOME by its real path; the
    /// literal path is kept as well (when it differs) in case the default `~/.codex` is not resolved.
    func trustKeyPrefixes() -> [String] {
        let literal = codexDir.standardizedFileURL.path
        var prefixes: [String] = []
        if let real = Self.realPath(literal) { prefixes.append(real + "/hooks.json") }
        let literalKey = literal + "/hooks.json"
        if !prefixes.contains(literalKey) { prefixes.append(literalKey) }
        return prefixes
    }

    // MARK: Status

    public func status() -> HookInstallStatus {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: codexDir.path, isDirectory: &isDir), isDir.boolValue else {
            return .agentMissing
        }
        let hooks: CodexHooksFile
        let config: CodexConfigTOML
        let trusted: [String: String]
        do {
            let loaded = try load()
            hooks = loaded.0
            config = loaded.1
            trusted = try trustedHashes(config)
        } catch let error as HookInstallerError {
            return .error(error.description)
        } catch {
            return .error(error.localizedDescription)
        }
        let prefixes = trustKeyPrefixes()
        var installedEvents = 0
        var untrustedEvents = 0
        for event in CodexHookEvent.allCases {
            let ours = hooks.ourHandlers(event)
            guard !ours.isEmpty else { continue }
            installedEvents += 1
            let allTrusted = ours.allSatisfy { position in
                guard let hash = hooks.hash(event, at: position) else { return false }
                return prefixes.contains { trusted[CodexTrust.key(hooksPath: $0, event: event, position: position)] == hash }
            }
            if !allTrusted { untrustedEvents += 1 }
        }
        let total = CodexHookEvent.allCases.count
        if installedEvents == 0 { return .notInstalled }
        if installedEvents < total { return .partial(L("установлены не все хуки: %@ из %@", installedEvents, total)) }
        if untrustedEvents == total { return .partial(L("хуки без доверия")) }
        if untrustedEvents > 0 { return .partial(L("хуки без доверия: %@ из %@", untrustedEvents, total)) }
        if config.bool(at: ["features", "hooks"]) == false || config.bool(at: ["features", "codex_hooks"]) == false {
            return .partial(L("хуки отключены в config.toml ([features] hooks = false)"))
        }
        return .installed
    }

    // MARK: Install / uninstall

    public func install(bridgePath: String) throws {
        do {
            try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        } catch {
            throw HookInstallerError.writeFailed(path: codexDir.path, reason: error.localizedDescription)
        }
        try apply(command: Self.hookCommand(bridgePath: bridgePath))
    }

    public func uninstall() throws {
        guard FileManager.default.fileExists(atPath: codexDir.path) else { return }
        try apply(command: nil)
    }

    /// `command == nil` removes our entries; otherwise installs exactly one handler per event.
    private func apply(command: String?) throws {
        let (hooks, config) = try load()
        let entries: [CodexConfigTOML.TrustEntry]
        do { entries = try config.trustEntries() } catch let error as CodexConfigTOML.ScanError {
            throw HookInstallerError.unparsableConfig(path: configURL.path, reason: error.description)
        }

        var newHooks = hooks
        var changes: [CodexHookEvent: CodexHooksFile.EventChange] = [:]
        var newOurHashes: [CodexHookEvent: String] = [:]
        for event in CodexHookEvent.allCases {
            let desired = command.map { Self.ourGroup(event: event, command: $0) }
            if let desired, let handler = desired["hooks"]?[0] {
                newOurHashes[event] = CodexTrust.hash(event: event, group: desired, handler: handler)
            }
            changes[event] = newHooks.replaceOurGroups(event, with: desired)
        }

        let plan = TrustPlan(prefixes: trustKeyPrefixes(), oldHooks: hooks, changes: changes, newOurHashes: newOurHashes)
        let newConfigText = plan.apply(to: config, entries: entries)
        let newHooksText = newHooks.serialized()

        let hooksChanged = newHooks.node != hooks.node
        let configChanged = newConfigText != config.text
        guard hooksChanged || configChanged else { return }
        // Check both files before writing either, so a read-only config.toml (nix/home-manager link,
        // uchg flag…) can't leave hooks.json rewritten on its own.
        for (url, changed) in [(hooksURL, hooksChanged), (configURL, configChanged)] where changed {
            if let problem = HookInstallers.writeProblem(url) {
                throw HookInstallerError.writeFailed(path: url.path, reason: problem)
            }
        }
        let now = Date()
        do {
            if hooksChanged { try HookInstallers.backup(hooksURL, home: home, now: now) }
            if configChanged { try HookInstallers.backup(configURL, home: home, now: now) }
        } catch {
            throw HookInstallerError.writeFailed(path: home.appendingPathComponent(".notchbuddy/backups").path,
                                                 reason: error.localizedDescription)
        }
        // The pair must stay consistent: removing our group can shift foreign handlers, and their trust
        // entries are renamed only in config.toml. If config.toml can't be written, hooks.json goes back.
        if hooksChanged { try writeFile(newHooksText, hooksURL) }
        if configChanged {
            do {
                try writeFile(newConfigText, configURL)
            } catch {
                guard hooksChanged else { throw error }
                throw rollBackHooks(to: hooks.text, after: error)
            }
        }
    }

    /// Puts hooks.json back as it was (or removes it if it didn't exist); returns the error to throw.
    private func rollBackHooks(to original: String?, after failure: Error) -> Error {
        do {
            if let original {
                try HookInstallers.write(original, to: hooksURL)
            } else {
                try FileManager.default.removeItem(at: try HookInstallers.resolvedTarget(hooksURL))
            }
            return failure
        } catch {
            let reason: String
            if case HookInstallerError.writeFailed(_, let r) = failure { reason = r } else { reason = failure.localizedDescription }
            return HookInstallerError.writeFailed(
                path: configURL.path,
                reason: L("%@; hooks.json уже изменён, и вернуть его не удалось — восстановите его из резервной копии в %@",
                          reason, home.appendingPathComponent(".notchbuddy/backups").path))
        }
    }

    // MARK: Loading

    private func load() throws -> (CodexHooksFile, CodexConfigTOML) {
        let hooksText = try read(hooksURL)
        let hooks: CodexHooksFile
        do { hooks = try CodexHooksFile(text: hooksText) } catch let error as CodexHooksFile.Invalid {
            throw HookInstallerError.unparsableConfig(path: hooksURL.path, reason: error.reason)
        }
        let config: CodexConfigTOML
        do { config = try CodexConfigTOML(text: try read(configURL) ?? "") } catch let error as CodexConfigTOML.ScanError {
            throw HookInstallerError.unparsableConfig(path: configURL.path, reason: error.description)
        }
        return (hooks, config)
    }

    private func trustedHashes(_ config: CodexConfigTOML) throws -> [String: String] {
        do { return try config.trustedHashes() } catch let error as CodexConfigTOML.ScanError {
            throw HookInstallerError.unparsableConfig(path: configURL.path, reason: error.description)
        }
    }

    private func read(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw HookInstallerError.unparsableConfig(path: url.path, reason: error.localizedDescription)
        }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// MARK: - Trust bookkeeping

/// Decides, for every `hooks.state` definition under our hooks.json path(s), whether to keep, remove
/// or rename it, and which trust tables to append for our handlers.
private struct TrustPlan {
    let prefixes: [String]
    let oldHooks: CodexHooksFile
    let changes: [CodexHookEvent: CodexHooksFile.EventChange]
    let newOurHashes: [CodexHookEvent: String]

    func apply(to config: CodexConfigTOML, entries: [CodexConfigTOML.TrustEntry]) -> String {
        var ourOld = Set<String>()        // keys of our handlers before the edit
        var ourNew: [String: String] = [:] // key → hash our handler needs after the edit
        var renames: [String: String] = [:]
        var foreignLive = Set<String>()   // keys of foreign handlers after the edit
        var ourHashes: [CodexHookEvent: Set<String>] = [:]
        var appendOrder: [String] = []

        for prefix in prefixes {
            for event in CodexHookEvent.allCases {
                guard let change = changes[event] else { continue }
                for position in change.ourOld {
                    ourOld.insert(CodexTrust.key(hooksPath: prefix, event: event, position: position))
                    if let hash = oldHooks.hash(event, at: position) { ourHashes[event, default: []].insert(hash) }
                }
                if let position = change.ourNew, let hash = newOurHashes[event] {
                    let key = CodexTrust.key(hooksPath: prefix, event: event, position: position)
                    ourNew[key] = hash
                    appendOrder.append(key)
                    ourHashes[event, default: []].insert(hash)
                }
                for (old, new) in change.foreignMoves {
                    let newKey = CodexTrust.key(hooksPath: prefix, event: event, position: new)
                    foreignLive.insert(newKey)
                    if old != new { renames[CodexTrust.key(hooksPath: prefix, event: event, position: old)] = newKey }
                }
            }
        }
        let renameTargets = Set(renames.values)
        let occurrences = Dictionary(grouping: entries, by: \.key).mapValues(\.count)

        var removals: [ClosedRange<Int>] = []
        var renaming: [(CodexConfigTOML.KeyPart, String)] = []
        var satisfied = Set<String>()
        for entry in entries {
            guard let (event, _) = prefixes.lazy.compactMap({ CodexTrust.parseKey(entry.key, hooksPath: $0) }).first else {
                continue  // not a key of our hooks.json: never touched
            }
            if let hash = ourNew[entry.key] {
                if entry.isCanonical && entry.trustedHash == hash && occurrences[entry.key] == 1 {
                    satisfied.insert(entry.key)
                } else {
                    removals.append(entry.lines)
                }
            } else if ourOld.contains(entry.key) {
                removals.append(entry.lines)
            } else if let newKey = renames[entry.key] {
                renaming.append((entry.keyPart, newKey))
            } else if renameTargets.contains(entry.key) {
                removals.append(entry.lines)  // stale entry where a moved foreign handler lands
            } else if !foreignLive.contains(entry.key), let hash = entry.trustedHash,
                      ourHashes[event]?.contains(hash) == true {
                removals.append(entry.lines)  // orphan left by an earlier install of ours
            }
        }
        let tables = appendOrder.filter { !satisfied.contains($0) }.map { (key: $0, trustedHash: ourNew[$0]!) }
        return config.rendered(removing: removals, renaming: renaming, appending: tables)
    }
}

// MARK: - hooks.json

private typealias Node = ClaudeHookInstaller.Node

/// `~/.codex/hooks.json`. Codex ignores the WHOLE file on any schema error (unknown top-level key,
/// unknown or missing handler `type`, non-integer `timeout`, …), so it is validated strictly before
/// we touch it and our own output always stays within the schema. The file is held as a lossless tree
/// (key order and number literals as written), so rewriting it never changes another tool's values:
/// a `timeout` of 10000000000000000 must not come back as `1e+16`, which Codex rejects.
struct CodexHooksFile {
    struct Invalid: Error { let reason: String }

    /// Result of rewriting one event array.
    struct EventChange {
        var ourOld: [CodexHandlerPosition] = []
        var ourNew: CodexHandlerPosition?
        /// Every foreign handler: old position → new position.
        var foreignMoves: [(CodexHandlerPosition, CodexHandlerPosition)] = []
    }

    let text: String?
    fileprivate private(set) var node: Node

    /// The file as plain JSON values.
    var root: [String: JSONValue] { node.jsonValue.object ?? [:] }

    init(text: String?) throws {
        self.text = text
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            node = .object([])
            return
        }
        let value: JSONValue
        do { value = try JSONValue.parse(Data(text.utf8)) } catch {
            throw Invalid(reason: L("некорректный JSON"))
        }
        if let problem = Self.problem(in: value) { throw Invalid(reason: L("%@ — Codex игнорирует весь файл", problem)) }
        guard let node = try? Node.parse(text), node.jsonValue == value else {
            throw Invalid(reason: L("не удалось разобрать файл без потерь"))
        }
        if let problem = Self.literalProblem(in: node) { throw Invalid(reason: L("%@ — Codex игнорирует весь файл", problem)) }
        self.node = node
    }

    func groups(_ event: CodexHookEvent) -> [JSONValue] {
        groupNodes(event).map(\.jsonValue)
    }

    private func groupNodes(_ event: CodexHookEvent) -> [Node] {
        node["hooks"]?[event.rawValue]?.arrayValue ?? []
    }

    static func isOurs(_ handler: JSONValue) -> Bool {
        guard case .string("command")? = handler["type"], case .string(let command)? = handler["command"] else {
            return false
        }
        return command.contains(Paths.hookMarker)
    }

    private static func isOurs(_ handler: Node) -> Bool {
        guard handler["type"]?.stringValue == "command", let command = handler["command"]?.stringValue else {
            return false
        }
        return command.contains(Paths.hookMarker)
    }

    func ourHandlers(_ event: CodexHookEvent) -> [CodexHandlerPosition] {
        groupNodes(event).enumerated().flatMap { g, group in
            (group["hooks"]?.arrayValue ?? []).enumerated()
                .filter { Self.isOurs($0.element) }
                .map { CodexHandlerPosition(group: g, handler: $0.offset) }
        }
    }

    func hash(_ event: CodexHookEvent, at position: CodexHandlerPosition) -> String? {
        let groups = groupNodes(event)
        guard groups.indices.contains(position.group),
              let handlers = groups[position.group]["hooks"]?.arrayValue,
              handlers.indices.contains(position.handler) else { return nil }
        return CodexTrust.hash(event: event, group: groups[position.group].jsonValue,
                               handler: handlers[position.handler].jsonValue)
    }

    /// Removes our handlers from `event`; with `desired`, puts it in place of our first own group
    /// (keeping its index) or appends it after all foreign groups. Foreign groups and handlers are
    /// carried over untouched.
    mutating func replaceOurGroups(_ event: CodexHookEvent, with desired: JSONValue?) -> EventChange {
        let desired = desired.map(Node.init)
        let old = groupNodes(event)
        var change = EventChange()
        var new: [Node] = []
        let target = desired == nil ? nil : old.firstIndex { group in
            let handlers = group["hooks"]?.arrayValue ?? []
            return !handlers.isEmpty && handlers.allSatisfy(Self.isOurs)
        }
        for (g, group) in old.enumerated() {
            let handlers = group["hooks"]?.arrayValue ?? []
            let ours = handlers.indices.filter { Self.isOurs(handlers[$0]) }
            change.ourOld += ours.map { CodexHandlerPosition(group: g, handler: $0) }
            if g == target, let desired {
                change.ourNew = CodexHandlerPosition(group: new.count, handler: 0)
                // Same values in another key order is no change: nothing to rewrite.
                new.append(group.jsonValue == desired.jsonValue ? group : desired)
                continue
            }
            let kept = handlers.indices.filter { !Self.isOurs(handlers[$0]) }
            if !ours.isEmpty && kept.isEmpty { continue }  // the group held only our handlers
            for (newIndex, oldIndex) in kept.enumerated() {
                change.foreignMoves.append((CodexHandlerPosition(group: g, handler: oldIndex),
                                            CodexHandlerPosition(group: new.count, handler: newIndex)))
            }
            if ours.isEmpty {
                new.append(group)
            } else if case .object(var members) = group {
                members.set("hooks", .array(kept.map { handlers[$0] }))
                new.append(.object(members))
            }
        }
        if let desired, target == nil {
            change.ourNew = CodexHandlerPosition(group: new.count, handler: 0)
            new.append(desired)
        }

        guard new != old, case .object(var top) = node else { return change }
        var events: [ClaudeHookInstaller.Member] = []
        if case .object(let members)? = top.value(for: "hooks") { events = members }
        if new.isEmpty { events.remove(event.rawValue) } else { events.set(event.rawValue, .array(new)) }
        top.set("hooks", .object(events))
        node = .object(top)
        return change
    }

    // MARK: Validation

    /// First reason serde would reject the file with (`config/src/hook_config.rs`), or nil.
    static func problem(in value: JSONValue) -> String? {
        guard let object = value.object else { return L("корневой элемент не объект") }
        if let key = object.keys.sorted().first(where: { $0 != "description" && $0 != "hooks" }) {
            return L("неизвестный ключ верхнего уровня «%@»", key)
        }
        if let description = object["description"], !isOptionalString(description) {
            return L("«description» не строка")
        }
        guard let hooks = object["hooks"] else { return nil }
        guard let events = hooks.object else { return L("«hooks» не объект") }
        for event in CodexHookEvent.allCases {
            guard let value = events[event.rawValue] else { continue }
            guard let groups = value.array else { return L("«%@» не массив", event.rawValue) }
            for group in groups {
                guard let fields = group.object else { return L("%@: группа не объект", event.rawValue) }
                if let matcher = fields["matcher"], !isOptionalString(matcher) {
                    return L("%@: «matcher» не строка", event.rawValue)
                }
                guard let handlers = fields["hooks"] else { continue }
                guard let list = handlers.array else { return L("%@: «hooks» в группе не массив", event.rawValue) }
                for handler in list {
                    if let problem = handlerProblem(handler) { return "\(event.rawValue): \(problem)" }
                }
            }
        }
        return nil
    }

    private static func handlerProblem(_ handler: JSONValue) -> String? {
        guard let fields = handler.object else { return L("обработчик не объект") }
        guard let typeValue = fields["type"] else { return L("у обработчика нет поля «type»") }
        guard case .string(let type) = typeValue else { return L("«type» не строка") }
        let optionalStrings: [String]
        switch type {
        case "command":
            guard case .string? = fields["command"] else { return L("у обработчика нет строки «command»") }
            if let async = fields["async"], async.bool == nil { return L("«async» не boolean") }
            optionalStrings = ["commandWindows", "command_windows", "statusMessage"]
        case "mcp_tool":
            guard case .string? = fields["server"], case .string? = fields["tool"] else {
                return L("у mcp_tool-обработчика нет «server»/«tool»")
            }
            // serde_json::Map, then converted to TOML: null (explicit or nested) is not representable.
            if let input = fields["input"] {
                guard input.object != nil else { return L("«input» не объект") }
                if containsNull(input) { return L("«input» содержит null, который не переводится в TOML") }
            }
            optionalStrings = ["statusMessage"]
        case "prompt", "agent":
            return nil
        default:
            return L("неизвестный тип обработчика «%@»", type)
        }
        for key in optionalStrings where !(fields[key].map(isOptionalString) ?? true) {
            return L("«%@» не строка", key)
        }
        for key in countKeys(type) where !(fields[key].map(isOptionalCount) ?? true) {
            return L("«%@» должен быть целым неотрицательным числом", key)
        }
        return nil
    }

    /// `Option<u64>` fields of a handler type.
    private static func countKeys(_ type: String) -> [String] {
        switch type {
        case "command": return ["timeout", "additionalContextLimit"]
        case "mcp_tool": return ["timeout"]
        default: return []
        }
    }

    /// serde_json reads a u64 only from an integer literal: `5.0`, `1e3` or `-0` are errors.
    fileprivate static func literalProblem(in node: Node) -> String? {
        guard case .object(let events)? = node["hooks"] else { return nil }
        for event in CodexHookEvent.allCases {
            for group in events.value(for: event.rawValue)?.arrayValue ?? [] {
                for handler in group["hooks"]?.arrayValue ?? [] {
                    guard let type = handler["type"]?.stringValue else { continue }
                    for key in countKeys(type) {
                        guard case .number(let raw)? = handler[key] else { continue }
                        if !raw.utf8.allSatisfy({ (48...57).contains($0) }) || UInt64(raw) == nil {
                            return L("%@: «%@» = %@ — нужно целое неотрицательное число без точки и экспоненты", event.rawValue, key, raw)
                        }
                    }
                }
            }
        }
        return nil
    }

    private static func containsNull(_ value: JSONValue) -> Bool {
        switch value {
        case .null: return true
        case .array(let items): return items.contains(where: containsNull)
        case .object(let fields): return fields.values.contains(where: containsNull)
        default: return false
        }
    }

    private static func isOptionalString(_ value: JSONValue) -> Bool {
        if case .string = value { return true }
        return value.isNull
    }

    /// Value-level check; `literalProblem` also requires an integer literal in u64 range.
    private static func isOptionalCount(_ value: JSONValue) -> Bool {
        if value.isNull { return true }
        guard let n = value.double else { return false }
        return n >= 0 && n.rounded() == n
    }

    // MARK: Output

    /// Pretty JSON, 2-space indent, keys in schema order (Codex's event order), unknown keys sorted after.
    /// Values (numbers included) are written exactly as they were read.
    func serialized() -> String {
        Self.ordered(node).rendered() + "\n"
    }

    private static let keyOrder: [String] = ["description", "matcher", "hooks"]
        + CodexHookEvent.allCases.map(\.rawValue)
        + ["type", "command", "commandWindows", "timeout", "async", "statusMessage", "additionalContextLimit"]

    private static func ordered(_ node: Node) -> Node {
        switch node {
        case .array(let items):
            return .array(items.map(ordered))
        case .object(let members):
            let sorted = members.enumerated().sorted { x, y in
                let ia = keyOrder.firstIndex(of: x.element.key) ?? Int.max
                let ib = keyOrder.firstIndex(of: y.element.key) ?? Int.max
                if ia != ib { return ia < ib }
                if x.element.key != y.element.key { return x.element.key < y.element.key }
                return x.offset < y.offset
            }
            return .object(sorted.map { ClaudeHookInstaller.Member($0.element.key, ordered($0.element.value)) })
        default:
            return node
        }
    }
}
