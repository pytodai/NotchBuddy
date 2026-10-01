import CryptoKit
import Foundation

/// The 12 Codex hook events, in Codex's own order (`HookEventsToml::matcher_groups_mut`).
enum CodexHookEvent: String, CaseIterable, Sendable {
    case preToolUse = "PreToolUse"
    case permissionRequest = "PermissionRequest"
    case postToolUse = "PostToolUse"
    case preCompact = "PreCompact"
    case postCompact = "PostCompact"
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case stop = "Stop"
    case interrupt = "Interrupt"

    /// `event_snake` used in trust keys and in the hash identity.
    var snakeName: String {
        switch self {
        case .preToolUse: return "pre_tool_use"
        case .permissionRequest: return "permission_request"
        case .postToolUse: return "post_tool_use"
        case .preCompact: return "pre_compact"
        case .postCompact: return "post_compact"
        case .sessionStart: return "session_start"
        case .sessionEnd: return "session_end"
        case .userPromptSubmit: return "user_prompt_submit"
        case .subagentStart: return "subagent_start"
        case .subagentStop: return "subagent_stop"
        case .stop: return "stop"
        case .interrupt: return "interrupt"
        }
    }

    init?(snakeName: String) {
        guard let event = Self.allCases.first(where: { $0.snakeName == snakeName }) else { return nil }
        self = event
    }

    /// Codex ignores matchers on these events, for dispatch and for the trust hash.
    var ignoresMatcher: Bool { self == .userPromptSubmit || self == .stop || self == .interrupt }

    /// Only these events keep `additionalContextLimit` in the normalized handler.
    var acceptsAdditionalContext: Bool {
        [.preToolUse, .postToolUse, .sessionStart, .userPromptSubmit, .subagentStart].contains(self)
    }

    /// Timeout as Codex normalizes it (`normalize_command_hook`): SessionEnd/Interrupt default 1 s and
    /// are clamped to 1...3; everything else defaults to 600 s and is at least 1.
    func normalizedTimeout(_ written: Int?) -> Int {
        switch self {
        case .sessionEnd, .interrupt: return min(max(written ?? 1, 1), 3)
        default: return max(written ?? 600, 1)
        }
    }
}

/// Codex hook trust: a user hook runs only if `config.toml` has
/// `[hooks.state."<hooks.json path>:<event_snake>:<group>:<handler>"] trusted_hash = "sha256:<hex>"`
/// and the hash matches the handler's normalized identity.
enum CodexTrust {
    static let defaultAdditionalContextLimit = 2500

    /// Port of `discovery.rs::hook_hash` + `fingerprint.rs::version_for_toml`: sha256 over the
    /// key-sorted compact JSON of `{event_name, matcher?, hooks:[normalized handler]}`.
    static func hash(event: CodexHookEvent, matcher: String?, command: String, timeout: Int?,
                     isAsync: Bool = false, statusMessage: String? = nil,
                     additionalContextLimit: Int? = nil) -> String {
        var handler: [(String, CanonicalJSON)] = [
            ("type", .string("command")),
            ("command", .string(command)),
            ("timeout", .int(event.normalizedTimeout(timeout))),
            ("async", .bool(isAsync)),  // as written in the file, even when Codex runs it synchronously
        ]
        if let statusMessage { handler.append(("statusMessage", .string(statusMessage))) }
        if event.acceptsAdditionalContext, let limit = additionalContextLimit, limit != defaultAdditionalContextLimit {
            handler.append(("additionalContextLimit", .int(limit)))
        }
        var identity: [(String, CanonicalJSON)] = [
            ("event_name", .string(event.snakeName)),
            ("hooks", .array([.object(handler)])),
        ]
        // An absent matcher is omitted, but "" is kept as "".
        if !event.ignoresMatcher, let matcher { identity.append(("matcher", .string(matcher))) }
        let digest = SHA256.hash(data: Data(CanonicalJSON.object(identity).text.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Hash of a command handler exactly as written in hooks.json; nil for other handler types.
    static func hash(event: CodexHookEvent, group: JSONValue, handler: JSONValue) -> String? {
        guard case .string("command")? = handler["type"], case .string(let command)? = handler["command"] else {
            return nil
        }
        var matcher: String?
        if case .string(let m)? = group["matcher"] { matcher = m }
        var statusMessage: String?
        if case .string(let s)? = handler["statusMessage"] { statusMessage = s }
        return hash(event: event, matcher: matcher, command: command,
                    timeout: handler["timeout"]?.double.flatMap { Int(exactly: $0) },
                    isAsync: handler["async"]?.bool ?? false,
                    statusMessage: statusMessage,
                    additionalContextLimit: handler["additionalContextLimit"]?.double.flatMap { Int(exactly: $0) })
    }

    static func key(hooksPath: String, event: CodexHookEvent, position: CodexHandlerPosition) -> String {
        "\(hooksPath):\(event.snakeName):\(position.group):\(position.handler)"
    }

    /// Inverse of `key` for keys that belong to `hooksPath`.
    static func parseKey(_ key: String, hooksPath: String) -> (CodexHookEvent, CodexHandlerPosition)? {
        let prefix = hooksPath + ":"
        guard key.hasPrefix(prefix) else { return nil }
        let parts = key.dropFirst(prefix.count).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let event = CodexHookEvent(snakeName: String(parts[0])),
              let group = Int(parts[1]), let handler = Int(parts[2]), group >= 0, handler >= 0 else { return nil }
        return (event, CodexHandlerPosition(group: group, handler: handler))
    }

    /// JSON string literal escaped like serde_json: only `"`, `\` and control characters; `/` and
    /// non-ASCII stay raw. Valid JSON, so hooks.json output uses it too.
    static func jsonQuoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

/// 0-based position of a handler: index of its matcher group in the event array, then inside the group.
struct CodexHandlerPosition: Hashable, Sendable {
    let group: Int
    let handler: Int
}

/// Just enough JSON for the hash identity: objects serialize with keys sorted by UTF-8 bytes.
private indirect enum CanonicalJSON {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([CanonicalJSON])
    case object([(String, CanonicalJSON)])

    var text: String {
        switch self {
        case .string(let s): return CodexTrust.jsonQuoted(s)
        case .int(let n): return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .array(let items): return "[" + items.map(\.text).joined(separator: ",") + "]"
        case .object(let fields):
            let sorted = fields.sorted { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
            return "{" + sorted.map { CodexTrust.jsonQuoted($0.0) + ":" + $0.1.text }.joined(separator: ",") + "}"
        }
    }
}

// MARK: - config.toml

/// Minimal line-based view of `~/.codex/config.toml`. It finds table headers and key/value items with
/// their dotted key paths and line spans (skipping over strings, multi-line strings and arrays) without
/// interpreting values, so the trust tables can be removed, renamed or appended while every other byte
/// of the file stays as it was.
struct CodexConfigTOML {
    struct ScanError: Error, Equatable {
        let line: Int
        let message: String
        var description: String { L("строка %@: %@", line, message) }
    }

    /// One component of a dotted key, with its location for in-place renaming.
    struct KeyPart: Equatable {
        let name: String
        let line: Int
        let start: Int  // unicode-scalar offsets in the line
        let end: Int
    }

    enum Kind: Equatable {
        case trivia  // blank or comment-only line
        case header(isArray: Bool)
        case keyValue
    }

    struct Item {
        let kind: Kind
        let firstLine: Int
        let lastLine: Int
        let keys: [KeyPart]  // header path, or the item's own dotted key
        let table: [String]  // enclosing table (for a header: its own path)
        let value: [Unicode.Scalar]

        var path: [String] {
            if case .header = kind { return keys.map(\.name) }
            return table + keys.map(\.name)
        }
    }

    /// One definition of `hooks.state."<key>"` in any TOML form.
    struct TrustEntry {
        let key: String
        let lines: ClosedRange<Int>  // what to delete to remove this definition
        let keyPart: KeyPart
        let trustedHash: String?
        let enabled: Bool?
        /// Exactly `[hooks.state."<key>"]` + `trusted_hash = "…"`: the form we write.
        let isCanonical: Bool
    }

    let text: String
    let lines: [[Unicode.Scalar]]
    let items: [Item]
    private let hadTrailingNewline: Bool
    private let lineSuffix: [Unicode.Scalar]

    init(text: String) throws {
        self.text = text
        var lines: [[Unicode.Scalar]] = [[]]
        for scalar in text.unicodeScalars {
            if scalar == "\n" { lines.append([]) } else { lines[lines.count - 1].append(scalar) }
        }
        if text.isEmpty {
            lines = []
            hadTrailingNewline = false
        } else if lines.last?.isEmpty == true {
            lines.removeLast()
            hadTrailingNewline = true
        } else {
            hadTrailingNewline = false
        }
        self.lines = lines
        lineSuffix = lines.contains { $0.last == "\r" } ? ["\r"] : []
        items = try Self.scan(lines)
    }

    // MARK: Queries

    /// All `hooks.state` definitions. Throws for layouts we cannot edit safely (an inline
    /// `hooks`/`hooks.state` table or `[[hooks.state]]`): appending a table there would break the file.
    func trustEntries() throws -> [TrustEntry] {
        var entries: [TrustEntry] = []
        var index = 0
        while index < items.count {
            let item = items[index]
            let path = item.path
            let underState = path.count >= 3 && path[0] == "hooks" && path[1] == "state"
            switch item.kind {
            case .header(let isArray):
                if isArray && path.count >= 2 && path[0] == "hooks" && path[1] == "state" {
                    throw ScanError(line: item.firstLine + 1, message: L("[[hooks.state]] не поддерживается"))
                }
                if underState {
                    var next = index + 1
                    var lastLine = item.firstLine
                    var values = 0
                    var trustedHash: String?
                    var enabled: Bool?
                    while next < items.count {
                        let inner = items[next]
                        if case .header = inner.kind { break }
                        if inner.kind == .keyValue {
                            lastLine = inner.lastLine
                            values += 1
                            let name = inner.keys.map(\.name)
                            if path.count == 3 && name == ["trusted_hash"] { trustedHash = Self.stringValue(inner.value) }
                            if path.count == 3 && name == ["enabled"] { enabled = Self.boolValue(inner.value) }
                        }
                        next += 1
                    }
                    entries.append(TrustEntry(
                        key: path[2], lines: item.firstLine...lastLine, keyPart: item.keys[2],
                        trustedHash: trustedHash, enabled: enabled,
                        isCanonical: path.count == 3 && values == 1 && trustedHash != nil))
                    index = next
                    continue
                }
            case .keyValue:
                if path == ["hooks"] || path == ["hooks", "state"] {
                    throw ScanError(line: item.firstLine + 1,
                                    message: L("hooks.state задан встроенной таблицей, автоматическое редактирование невозможно"))
                }
                if underState && item.table.count <= 2 {
                    var trustedHash: String?
                    var enabled: Bool?
                    if path.count == 4 && path[3] == "trusted_hash" { trustedHash = Self.stringValue(item.value) }
                    if path.count == 4 && path[3] == "enabled" { enabled = Self.boolValue(item.value) }
                    if path.count == 3 {
                        let fields = Self.inlineTableFields(item.value)
                        trustedHash = fields["trusted_hash"].flatMap(Self.stringValue)
                        enabled = fields["enabled"].flatMap(Self.boolValue)
                    }
                    entries.append(TrustEntry(
                        key: path[2], lines: item.firstLine...item.lastLine, keyPart: item.keys[2 - item.table.count],
                        trustedHash: trustedHash, enabled: enabled, isCanonical: false))
                }
            case .trivia:
                break
            }
            index += 1
        }
        return entries
    }

    /// `trusted_hash` per key, for keys defined with one. Later definitions win.
    func trustedHashes() throws -> [String: String] {
        var result: [String: String] = [:]
        for entry in try trustEntries() {
            if let hash = entry.trustedHash { result[entry.key] = hash }
        }
        return result
    }

    /// A boolean value at a full dotted path, e.g. `["features", "hooks"]`.
    func bool(at path: [String]) -> Bool? {
        items.last { $0.kind == .keyValue && $0.path == path }.flatMap { Self.boolValue($0.value) }
    }

    // MARK: Editing

    /// The file with whole lines removed, trust keys renamed in place and new trust tables appended.
    /// Returns the original text unchanged when there is nothing to do.
    func rendered(removing removals: [ClosedRange<Int>], renaming renames: [(KeyPart, String)],
                  appending tables: [(key: String, trustedHash: String)]) -> String {
        if removals.isEmpty && renames.isEmpty && tables.isEmpty { return text }
        var lines = self.lines
        for (part, newKey) in renames.sorted(by: { ($0.0.line, $0.0.start) > ($1.0.line, $1.0.start) }) {
            lines[part.line].replaceSubrange(part.start..<part.end, with: Self.quotedKey(newKey).unicodeScalars)
        }

        var removed = Set<Int>()
        for range in removals { removed.formUnion(range) }
        // Don't leave a doubled blank line (or a trailing one) where a table used to be.
        for start in removed.sorted() where !removed.contains(start - 1) {
            var end = start
            while removed.contains(end + 1) { end += 1 }
            let before = start - 1
            let after = end + 1
            if before >= 0, Self.isBlank(lines[before]), after >= lines.count || Self.isBlank(lines[after]) {
                removed.insert(before)
            }
        }
        var out = lines.indices.filter { !removed.contains($0) }.map { lines[$0] }

        if !tables.isEmpty {
            if let last = out.last, !Self.isBlank(last) { out.append(lineSuffix) }
            for (index, table) in tables.enumerated() {
                if index > 0 { out.append(lineSuffix) }
                out.append(Array("[hooks.state.\(Self.quotedKey(table.key))]".unicodeScalars) + lineSuffix)
                out.append(Array("trusted_hash = \(Self.quotedKey(table.trustedHash))".unicodeScalars) + lineSuffix)
            }
        }
        var result = String.UnicodeScalarView()
        for (index, line) in out.enumerated() {
            if index > 0 { result.append("\n") }
            result.append(contentsOf: line)
        }
        if !out.isEmpty && (hadTrailingNewline || !tables.isEmpty) { result.append("\n") }
        return String(result)
    }

    /// TOML basic string.
    static func quotedKey(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F { out += String(format: "\\u%04X", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    // MARK: Value helpers

    private static func isBlank(_ line: [Unicode.Scalar]) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    /// Leading basic or literal string of a raw value.
    static func stringValue(_ value: [Unicode.Scalar]) -> String? {
        var scanner = Scanner(lines: [value])
        scanner.skipSpaces()
        switch scanner.current {
        case "\"": return try? scanner.basicString()
        case "'": return try? scanner.literalString()
        default: return nil
        }
    }

    static func boolValue(_ value: [Unicode.Scalar]) -> Bool? {
        let text = String(String.UnicodeScalarView(value)).trimmingCharacters(in: .whitespaces)
        for (word, result) in [("true", true), ("false", false)] where text.hasPrefix(word) {
            let rest = text.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty || rest.hasPrefix("#") || rest.hasPrefix(",") || rest.hasPrefix("}") { return result }
        }
        return nil
    }

    /// Raw values of a single-line inline table `{ a = "x", b = false }`, keyed by bare/quoted key.
    static func inlineTableFields(_ value: [Unicode.Scalar]) -> [String: [Unicode.Scalar]] {
        var scanner = Scanner(lines: [value])
        scanner.skipSpaces()
        guard scanner.current == "{" else { return [:] }
        scanner.col += 1
        var fields: [String: [Unicode.Scalar]] = [:]
        while true {
            scanner.skipSpaces()
            if scanner.current == nil || scanner.current == "}" { return fields }
            guard let keys = try? scanner.key(until: "=") else { return fields }
            scanner.col += 1
            let start = scanner.col
            var depth = 0
            while let c = scanner.current {
                if c == "\"" { guard (try? scanner.basicString()) != nil else { return fields }; continue }
                if c == "'" { guard (try? scanner.literalString()) != nil else { return fields }; continue }
                if c == "[" || c == "{" { depth += 1 }
                if c == "]" || c == "}" {
                    if depth == 0 { break }
                    depth -= 1
                }
                if c == "," && depth == 0 { break }
                scanner.col += 1
            }
            if keys.count == 1 { fields[keys[0].name] = Array(value[start..<scanner.col]) }
            if scanner.current == "," { scanner.col += 1 }
        }
    }

    // MARK: Scanner

    private static func scan(_ lines: [[Unicode.Scalar]]) throws -> [Item] {
        var items: [Item] = []
        var table: [String] = []
        var scanner = Scanner(lines: lines)
        var index = 0
        while index < lines.count {
            scanner.line = index
            scanner.col = 0
            scanner.skipSpaces()
            guard let first = scanner.current, first != "#" else {
                items.append(Item(kind: .trivia, firstLine: index, lastLine: index, keys: [], table: table, value: []))
                index += 1
                continue
            }
            if first == "[" {
                let isArray = scanner.peek(1) == "["
                scanner.col += isArray ? 2 : 1
                let keys = try scanner.key(until: "]")
                scanner.col += 1
                if isArray {
                    guard scanner.current == "]" else { throw scanner.error(L("ожидалось «]]»")) }
                    scanner.col += 1
                }
                scanner.skipSpaces()
                if let rest = scanner.current, rest != "#" { throw scanner.error(L("лишний текст после заголовка таблицы")) }
                table = keys.map(\.name)
                items.append(Item(kind: .header(isArray: isArray), firstLine: index, lastLine: index,
                                  keys: keys, table: table, value: []))
                index += 1
            } else {
                let keys = try scanner.key(until: "=")
                scanner.col += 1
                let valueLine = scanner.line
                let valueCol = scanner.col
                try scanner.skipValue()
                var value = Array(lines[valueLine][valueCol...])
                if scanner.line > valueLine {
                    for line in lines[(valueLine + 1)...scanner.line] { value += ["\n"] + line }
                }
                items.append(Item(kind: .keyValue, firstLine: index, lastLine: scanner.line,
                                  keys: keys, table: table, value: value))
                index = scanner.line + 1
            }
        }
        return items
    }

    fileprivate struct Scanner {
        let lines: [[Unicode.Scalar]]
        var line = 0
        var col = 0

        var current: Unicode.Scalar? { peek(0) }

        func peek(_ offset: Int) -> Unicode.Scalar? {
            guard line < lines.count, col + offset < lines[line].count else { return nil }
            return lines[line][col + offset]
        }

        func error(_ message: String) -> ScanError { ScanError(line: line + 1, message: message) }

        mutating func skipSpaces() {
            while let c = current, c == " " || c == "\t" || c == "\r" || c == "\u{FEFF}" { col += 1 }
        }

        /// Dotted key up to (not including) `terminator`.
        mutating func key(until terminator: Unicode.Scalar) throws -> [KeyPart] {
            var parts: [KeyPart] = []
            while true {
                skipSpaces()
                let start = col
                guard let c = current else { throw error(L("неполный ключ")) }
                let name: String
                if c == "\"" {
                    name = try basicString()
                } else if c == "'" {
                    name = try literalString()
                } else if Self.isBare(c) {
                    var bare = String.UnicodeScalarView()
                    while let b = current, Self.isBare(b) { bare.append(b); col += 1 }
                    name = String(bare)
                } else {
                    throw error(L("недопустимый символ в ключе"))
                }
                parts.append(KeyPart(name: name, line: line, start: start, end: col))
                skipSpaces()
                guard let next = current else { throw error(L("неполный ключ")) }
                if next == "." { col += 1; continue }
                if next == terminator { return parts }
                throw error(L("недопустимый символ в ключе"))
            }
        }

        private static func isBare(_ c: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c) || c == "_" || c == "-"
        }

        /// Single-line `"…"` at the cursor; returns the decoded text.
        mutating func basicString() throws -> String {
            col += 1
            var out = String.UnicodeScalarView()
            while true {
                guard let c = current else { throw error(L("незакрытая строка")) }
                col += 1
                if c == "\"" { return String(out) }
                guard c == "\\" else { out.append(c); continue }
                guard let e = current else { throw error(L("незакрытая строка")) }
                col += 1
                switch e {
                case "b": out.append("\u{08}")
                case "t": out.append("\t")
                case "n": out.append("\n")
                case "f": out.append("\u{0C}")
                case "r": out.append("\r")
                case "e": out.append("\u{1B}")
                case "\"", "\\": out.append(e)
                case "u", "U":
                    let count = e == "u" ? 4 : 8
                    var hex = ""
                    for _ in 0..<count {
                        guard let h = current else { throw error(L("неверная escape-последовательность")) }
                        hex.unicodeScalars.append(h)
                        col += 1
                    }
                    guard let v = UInt32(hex, radix: 16), let s = Unicode.Scalar(v) else {
                        throw error(L("неверная escape-последовательность"))
                    }
                    out.append(s)
                default:
                    throw error(L("неверная escape-последовательность"))
                }
            }
        }

        /// Single-line `'…'` at the cursor.
        mutating func literalString() throws -> String {
            col += 1
            var out = String.UnicodeScalarView()
            while true {
                guard let c = current else { throw error(L("незакрытая строка")) }
                col += 1
                if c == "'" { return String(out) }
                out.append(c)
            }
        }

        /// `"""…"""` or `'''…'''` starting at the cursor, possibly spanning lines.
        mutating func skipMultilineString(quote: Unicode.Scalar) throws {
            let startLine = line
            col += 3
            while true {
                guard line < lines.count else {
                    throw ScanError(line: startLine + 1, message: L("незакрытая многострочная строка"))
                }
                guard let c = current else { line += 1; col = 0; continue }
                if quote == "\"" && c == "\\" { col += 2; continue }
                if c == quote && peek(1) == quote && peek(2) == quote {
                    col += 3
                    var extra = 0  // up to two quotes may directly precede the closing delimiter
                    while extra < 2, current == quote { col += 1; extra += 1 }
                    return
                }
                col += 1
            }
        }

        /// Skips a value (strings, nested arrays/inline tables, comments) that may span lines.
        mutating func skipValue() throws {
            let startLine = line
            var depth = 0
            var sawValue = false
            while true {
                guard let c = current else {
                    if depth > 0 {
                        line += 1
                        col = 0
                        guard line < lines.count else {
                            throw ScanError(line: startLine + 1, message: L("незакрытый массив или таблица"))
                        }
                        continue
                    }
                    guard sawValue else { throw error(L("нет значения")) }
                    return
                }
                switch c {
                case " ", "\t", "\r":
                    col += 1
                case "#":
                    col = lines[line].count
                case "\"", "'":
                    sawValue = true
                    if peek(1) == c && peek(2) == c {
                        try skipMultilineString(quote: c)
                    } else if c == "\"" {
                        _ = try basicString()
                    } else {
                        _ = try literalString()
                    }
                case "[", "{":
                    sawValue = true
                    depth += 1
                    col += 1
                case "]", "}":
                    depth -= 1
                    col += 1
                    if depth < 0 { throw error(L("лишняя закрывающая скобка")) }
                default:
                    sawValue = true
                    col += 1
                }
            }
        }
    }
}
