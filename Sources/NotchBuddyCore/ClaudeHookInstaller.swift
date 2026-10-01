import Foundation

/// Registers NotchBuddy in `~/.claude/settings.json`.
/// The file is parsed into an order-preserving tree, so a rewrite keeps foreign hooks,
/// key order and number literals exactly; only our handlers and our statusLine change.
public struct ClaudeHookInstaller: AgentHookInstaller {
    public let home: URL
    public init(home: URL = Paths.home) { self.home = home }

    public var source: AgentSource { .claude }
    public var configDir: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    public var settingsURL: URL { configDir.appendingPathComponent("settings.json") }
    public var files: [URL] { [settingsURL] }

    struct EventSpec: Sendable {
        let name: String
        /// `"*"` on events whose matcher we want to be explicit about; nil = key omitted.
        let matcher: String?
        /// Seconds.
        let timeout: Int
    }

    /// All 14 are already in the HOOK_EVENTS list of the terminal CLI 2.1.185, so none has to be dropped:
    /// unknown names would only produce warnings.
    static let events: [EventSpec] = [
        EventSpec(name: "SessionStart", matcher: nil, timeout: 10),
        EventSpec(name: "SessionEnd", matcher: nil, timeout: 5), // shares a 1.5 s budget, keep it small
        EventSpec(name: "UserPromptSubmit", matcher: nil, timeout: 10),
        EventSpec(name: "PreToolUse", matcher: "*", timeout: 10),
        EventSpec(name: "PostToolUse", matcher: "*", timeout: 10),
        EventSpec(name: "PostToolUseFailure", matcher: "*", timeout: 10),
        EventSpec(name: "PermissionRequest", matcher: "*", timeout: 900), // the bridge waits ≤ 600 s
        EventSpec(name: "Notification", matcher: "*", timeout: 10),
        EventSpec(name: "Stop", matcher: nil, timeout: 10),
        EventSpec(name: "StopFailure", matcher: nil, timeout: 10),
        EventSpec(name: "SubagentStart", matcher: nil, timeout: 10),
        EventSpec(name: "SubagentStop", matcher: nil, timeout: 10),
        EventSpec(name: "PreCompact", matcher: nil, timeout: 10),
        EventSpec(name: "PostCompact", matcher: nil, timeout: 10),
    ]

    /// Same guarded shape as `Paths.hookCommand(source:)`, pointed at `bridgePath`:
    /// a missing binary makes the hook a silent no-op, and the exit code is always 0.
    public static func hookCommand(bridgePath: String) -> String {
        guarded(bridgePath: bridgePath, arguments: "--source \(AgentSource.claude.rawValue)")
    }

    public static func statusLineCommand(bridgePath: String) -> String {
        guarded(bridgePath: bridgePath, arguments: "statusline")
    }

    private static func guarded(bridgePath: String, arguments: String) -> String {
        var escaped = ""
        for ch in bridgePath {
            if "\\\"$`".contains(ch) { escaped.append("\\") }
            escaped.append(ch)
        }
        let bin = "\"\(escaped)\""
        let script = "[ -x \(bin) ] && \(bin) \(arguments); exit 0"
        return "/bin/sh -c '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: AgentHookInstaller

    public func status() -> HookInstallStatus {
        guard FileManager.default.fileExists(atPath: configDir.path) else { return .agentMissing }
        let root: Node
        do { root = try load().root } catch { return .error(String(describing: error)) }
        let present = Self.eventsWithOurHandlers(in: root)
        let missing = Self.events.map(\.name).filter { !present.contains($0) }
        if missing.isEmpty { return .installed }
        if present.isEmpty { return .notInstalled }
        return .partial(L("Нет хуков NotchBuddy для событий: %@", missing.joined(separator: ", ")))
    }

    public func install(bridgePath: String) throws {
        let (text, root) = try load()
        let updated = try Self.installing(bridgePath: bridgePath, into: root, path: settingsURL.path)
        try save(updated, original: root, text: text)
    }

    public func uninstall() throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let (text, root) = try load()
        try save(Self.uninstalling(from: root), original: root, text: text)
    }

    // MARK: File IO

    /// Parsed settings; `{}` when the file is missing or blank.
    private func load() throws -> (text: String?, root: Node) {
        let url = settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, .object([])) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw HookInstallerError.unparsableConfig(path: url.path, reason: error.localizedDescription)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw HookInstallerError.unparsableConfig(path: url.path, reason: L("файл не в кодировке UTF-8"))
        }
        return (text, try Self.parseSettings(text, path: url.path))
    }

    /// Writes only when something changed, so repeated installs don't reformat the file or pile up backups.
    private func save(_ root: Node, original: Node, text: String?) throws {
        guard root != original else { return }
        var output = root.rendered()
        if text?.hasSuffix("\n") ?? true { output += "\n" }
        // Invalid JSON would make Claude Code skip the whole settings file.
        guard (try? JSONSerialization.jsonObject(with: Data(output.utf8))) is [String: Any] else {
            throw HookInstallerError.writeFailed(path: settingsURL.path, reason: L("получился некорректный JSON"))
        }
        do { try HookInstallers.backup(settingsURL, home: home) } catch {
            throw HookInstallerError.writeFailed(path: settingsURL.path,
                                                 reason: L("не удалось сделать резервную копию: %@", error.localizedDescription))
        }
        try HookInstallers.write(output, to: settingsURL)
    }

    // MARK: Pure transforms

    static func parseSettings(_ text: String, path: String) throws -> Node {
        func fail(_ reason: String) -> HookInstallerError { .unparsableConfig(path: path, reason: reason) }
        if text.allSatisfy(\.isWhitespace) { return .object([]) }
        let reference: Any
        do {
            reference = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            throw fail(L("некорректный JSON: %@", detail))
        }
        guard let referenceObject = reference as? [String: Any] else { throw fail(L("ожидался JSON-объект")) }
        let root: Node
        do { root = try Node.parse(text) } catch { throw fail(L("некорректный JSON")) }
        // Our own parser/renderer must be lossless before we dare to rewrite the user's file.
        guard let again = try? JSONSerialization.jsonObject(with: Data(root.rendered().utf8)) as? [String: Any],
              NSDictionary(dictionary: again).isEqual(to: referenceObject) else {
            throw fail(L("не удалось разобрать файл без потерь"))
        }
        return root
    }

    /// Drops our previous handlers, then appends one fresh matcher group per event.
    /// Event keys stay where they were; new ones go to the end of `hooks`.
    static func installing(bridgePath: String, into root: Node, path: String) throws -> Node {
        func fail(_ reason: String) -> HookInstallerError { .unparsableConfig(path: path, reason: reason) }
        guard case .object(var top) = root else { throw fail(L("ожидался JSON-объект")) }
        var hooks: [Member] = []
        if let existing = top.value(for: "hooks") {
            guard case .object(let members) = existing else { throw fail(L("поле hooks должно быть объектом")) }
            hooks = members
        }
        hooks = strippingOurHandlers(from: hooks, keepingEvents: Set(events.map(\.name))).members

        let command = hookCommand(bridgePath: bridgePath)
        for spec in events {
            var group: [Member] = []
            if let matcher = spec.matcher { group.append(Member("matcher", .string(matcher))) }
            let handler: Node = .object([
                Member("type", .string("command")),
                Member("command", .string(command)),
                Member("timeout", .number(String(spec.timeout))),
            ])
            group.append(Member("hooks", .array([handler])))
            if let existing = hooks.value(for: spec.name) {
                guard case .array(var groups) = existing else {
                    throw fail(L("hooks.%@ должно быть массивом", spec.name))
                }
                groups.append(.object(group))
                hooks.set(spec.name, .array(groups))
            } else {
                hooks.append(Member(spec.name, .array([.object(group)])))
            }
        }
        top.set("hooks", .object(hooks))

        let statusLine: Node = .object([
            Member("type", .string("command")),
            Member("command", .string(statusLineCommand(bridgePath: bridgePath))),
        ])
        if let existing = top.value(for: "statusLine") {
            if isOurs(existing) { top.set("statusLine", statusLine) } // a foreign one is left alone
        } else {
            top.append(Member("statusLine", statusLine))
        }
        return .object(top)
    }

    /// Removes our handlers, the groups/events/`hooks` object they leave empty, and our statusLine.
    static func uninstalling(from root: Node) -> Node {
        guard case .object(var top) = root else { return root }
        if case .object(let hooks)? = top.value(for: "hooks") {
            let (stripped, changed) = strippingOurHandlers(from: hooks, keepingEvents: [])
            if changed {
                if stripped.isEmpty { top.remove("hooks") } else { top.set("hooks", .object(stripped)) }
            }
        }
        if let statusLine = top.value(for: "statusLine"), isOurs(statusLine) { top.remove("statusLine") }
        return .object(top)
    }

    static func eventsWithOurHandlers(in root: Node) -> Set<String> {
        guard case .object(let hooks)? = root["hooks"] else { return [] }
        var found: Set<String> = []
        for member in hooks {
            guard case .array(let groups) = member.value else { continue }
            if groups.contains(where: { $0["hooks"]?.arrayValue?.contains(where: isOurs) ?? false }) {
                found.insert(member.key)
            }
        }
        return found
    }

    /// A handler (or statusLine) is ours when its command mentions the bridge binary.
    static func isOurs(_ node: Node) -> Bool {
        node["command"]?.stringValue?.contains(Paths.hookMarker) ?? false
    }

    /// Groups emptied by the removal are dropped; so are emptied events not in `keep`.
    private static func strippingOurHandlers(from hooks: [Member], keepingEvents keep: Set<String>)
        -> (members: [Member], changed: Bool) {
        var changed = false
        var result: [Member] = []
        for member in hooks {
            guard case .array(let groups) = member.value else { result.append(member); continue }
            var keptGroups: [Node] = []
            var eventChanged = false
            for group in groups {
                guard case .object(var fields) = group,
                      case .array(let handlers)? = fields.value(for: "hooks") else {
                    keptGroups.append(group)
                    continue
                }
                let keptHandlers = handlers.filter { !isOurs($0) }
                if keptHandlers.count == handlers.count { keptGroups.append(group); continue }
                eventChanged = true
                if keptHandlers.isEmpty { continue }
                fields.set("hooks", .array(keptHandlers))
                keptGroups.append(.object(fields))
            }
            if eventChanged { changed = true }
            if eventChanged && keptGroups.isEmpty && !keep.contains(member.key) { continue }
            result.append(Member(member.key, .array(keptGroups)))
        }
        return (result, changed)
    }
}

// MARK: - Order-preserving JSON

extension ClaudeHookInstaller {
    /// JSON value that keeps object key order and number literals exactly as written.
    enum Node: Equatable {
        case object([Member])
        case array([Node])
        case string(String)
        case number(String)
        case bool(Bool)
        case null

        subscript(key: String) -> Node? {
            if case .object(let members) = self { return members.value(for: key) }
            return nil
        }

        var stringValue: String? { if case .string(let s) = self { return s }; return nil }
        var arrayValue: [Node]? { if case .array(let a) = self { return a }; return nil }

        /// The same value as `JSONValue` (numbers become Double; for a repeated key the last one wins).
        var jsonValue: JSONValue {
            switch self {
            case .null: return .null
            case .bool(let b): return .bool(b)
            case .string(let s): return .string(s)
            case .number(let raw): return .number(Double(raw) ?? .nan)
            case .array(let items): return .array(items.map(\.jsonValue))
            case .object(let members):
                return .object(Dictionary(members.map { ($0.key, $0.value.jsonValue) }, uniquingKeysWith: { _, last in last }))
            }
        }

        /// A tree for a value we generate ourselves: integral numbers are written as integers,
        /// object keys in sorted order.
        init(_ value: JSONValue) {
            switch value {
            case .null: self = .null
            case .bool(let b): self = .bool(b)
            case .string(let s): self = .string(s)
            case .number(let n):
                self = .number(n.rounded() == n && abs(n) < 9e18 ? String(Int64(n)) : String(n))
            case .array(let items): self = .array(items.map(Node.init))
            case .object(let fields):
                self = .object(fields.keys.sorted().map { Member($0, Node(fields[$0]!)) })
            }
        }

        static func parse(_ text: String) throws -> Node {
            var parser = Parser(bytes: Array(text.utf8))
            return try parser.document()
        }

        /// Pretty JSON in the style of `JSON.stringify(value, null, 2)`, which is how Claude Code writes it.
        func rendered() -> String {
            var out = ""
            render(into: &out, level: 0)
            return out
        }

        private func render(into out: inout String, level: Int) {
            switch self {
            case .null: out += "null"
            case .bool(let b): out += b ? "true" : "false"
            case .number(let raw): out += raw
            case .string(let s): Self.quote(s, into: &out)
            case .array(let items):
                guard !items.isEmpty else { out += "[]"; return }
                out += "[\n"
                for (n, item) in items.enumerated() {
                    out += String(repeating: "  ", count: level + 1)
                    item.render(into: &out, level: level + 1)
                    out += n == items.count - 1 ? "\n" : ",\n"
                }
                out += String(repeating: "  ", count: level) + "]"
            case .object(let members):
                guard !members.isEmpty else { out += "{}"; return }
                out += "{\n"
                for (n, member) in members.enumerated() {
                    out += String(repeating: "  ", count: level + 1)
                    Self.quote(member.key, into: &out)
                    out += ": "
                    member.value.render(into: &out, level: level + 1)
                    out += n == members.count - 1 ? "\n" : ",\n"
                }
                out += String(repeating: "  ", count: level) + "}"
            }
        }

        private static func quote(_ s: String, into out: inout String) {
            out += "\""
            for scalar in s.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case "\u{08}": out += "\\b"
                case "\u{0C}": out += "\\f"
                case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
                default: out.unicodeScalars.append(scalar)
                }
            }
            out += "\""
        }
    }

    struct Member: Equatable {
        var key: String
        var value: Node
        init(_ key: String, _ value: Node) { self.key = key; self.value = value }
    }

    struct ParseError: Error {}

    /// Strict enough for input that JSONSerialization has already accepted.
    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func document() throws -> Node {
            let result = try value()
            skipWhitespace()
            guard i == bytes.count else { throw ParseError() }
            return result
        }

        private mutating func value() throws -> Node {
            skipWhitespace()
            guard i < bytes.count else { throw ParseError() }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return .number(try number())
            }
        }

        private mutating func object() throws -> Node {
            i += 1
            var members: [Member] = []
            skipWhitespace()
            if peek(UInt8(ascii: "}")) { i += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard peek(UInt8(ascii: "\"")) else { throw ParseError() }
                let key = try string()
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                members.append(Member(key, try value()))
                skipWhitespace()
                if peek(UInt8(ascii: ",")) { i += 1; continue }
                try expect(UInt8(ascii: "}"))
                return .object(members)
            }
        }

        private mutating func array() throws -> Node {
            i += 1
            var items: [Node] = []
            skipWhitespace()
            if peek(UInt8(ascii: "]")) { i += 1; return .array(items) }
            while true {
                items.append(try value())
                skipWhitespace()
                if peek(UInt8(ascii: ",")) { i += 1; continue }
                try expect(UInt8(ascii: "]"))
                return .array(items)
            }
        }

        private mutating func string() throws -> String {
            i += 1 // opening quote
            var buffer: [UInt8] = []
            while i < bytes.count {
                let byte = bytes[i]
                i += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return String(decoding: buffer, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard i < bytes.count else { throw ParseError() }
                    let escape = bytes[i]
                    i += 1
                    switch escape {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): buffer.append(escape)
                    case UInt8(ascii: "b"): buffer.append(0x08)
                    case UInt8(ascii: "f"): buffer.append(0x0C)
                    case UInt8(ascii: "n"): buffer.append(0x0A)
                    case UInt8(ascii: "r"): buffer.append(0x0D)
                    case UInt8(ascii: "t"): buffer.append(0x09)
                    case UInt8(ascii: "u"):
                        let character = try unicodeEscape()
                        buffer.append(contentsOf: Array(String(character).utf8))
                    default: throw ParseError()
                    }
                default:
                    buffer.append(byte)
                }
            }
            throw ParseError()
        }

        /// After `\u`: one code unit, or a surrogate pair written as two escapes.
        private mutating func unicodeEscape() throws -> Character {
            let first = try hex4()
            if (0xD800..<0xDC00).contains(first), i + 1 < bytes.count,
               bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                let save = i
                i += 2
                let second = try hex4()
                if (0xDC00..<0xE000).contains(second) {
                    let scalar = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    return Character(Unicode.Scalar(scalar) ?? "\u{FFFD}")
                }
                i = save
            }
            return Character(Unicode.Scalar(first) ?? "\u{FFFD}")
        }

        private mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count,
                  let value = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else {
                throw ParseError()
            }
            i += 4
            return value
        }

        private mutating func number() throws -> String {
            let start = i
            while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
            guard i > start else { throw ParseError() }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }

        private mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { throw ParseError() }
            i += w.count
        }

        private mutating func expect(_ byte: UInt8) throws {
            guard peek(byte) else { throw ParseError() }
            i += 1
        }

        private func peek(_ byte: UInt8) -> Bool { i < bytes.count && bytes[i] == byte }

        private mutating func skipWhitespace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }
    }
}

/// Also used by `CodexHooksFile`, which needs the same lossless tree for hooks.json.
extension Array where Element == ClaudeHookInstaller.Member {
    /// Last occurrence wins, as in `JSON.parse`.
    func value(for key: String) -> ClaudeHookInstaller.Node? {
        last(where: { $0.key == key })?.value
    }

    /// Replaces the value in place (last occurrence) or appends a new member.
    mutating func set(_ key: String, _ value: ClaudeHookInstaller.Node) {
        if let index = lastIndex(where: { $0.key == key }) { self[index].value = value }
        else { append(ClaudeHookInstaller.Member(key, value)) }
    }

    mutating func remove(_ key: String) {
        removeAll { $0.key == key }
    }
}
