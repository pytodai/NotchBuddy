import Foundation

/// Registers NotchBuddy in `~/.kimi-code/config.toml`.
/// The TOML is edited line by line: our `[[hooks]]` tables (recognized by `Paths.hookMarker`
/// in `command`) are cut out and appended fresh at the end; every other line stays as it was.
public struct KimiHookInstaller: AgentHookInstaller {
    public let home: URL
    public init(home: URL = Paths.home) { self.home = home }

    public var source: AgentSource { .kimi }
    public var configDir: URL { home.appendingPathComponent(".kimi-code", isDirectory: true) }
    public var configURL: URL { configDir.appendingPathComponent("config.toml") }
    public var files: [URL] { [configURL] }

    /// The 16 events node-sdk's strict config schema knows. The runtime accepts four
    /// more, but those break login/logout, and one invalid entry disables every hook.
    static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "PermissionResult", "Stop", "StopFailure", "Interrupt",
        "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "Notification",
    ]

    /// Seconds; the schema wants an integer in 1...600. Awaited events stall Kimi while the bridge runs.
    static let timeout = 5

    /// Kimi drops comments when it rewrites the file, so this is only a hint for humans.
    /// A marker written into the file and matched on uninstall: never localized.
    static let managedComment = "# NotchBuddy: таблицы [[hooks]] ниже добавлены приложением NotchBuddy"  // l10n-ignore

    /// A single simple command (no `;`, `&&`, `|`), so `/bin/sh` execs the bridge and its parent
    /// PID is Kimi itself. No guard is possible here; Kimi fails open anyway.
    public static func hookCommand(bridgePath: String) -> String {
        "'" + bridgePath.replacingOccurrences(of: "'", with: "'\\''") + "' --source \(AgentSource.kimi.rawValue)"
    }

    // MARK: AgentHookInstaller

    public func status() -> HookInstallStatus {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configDir.path) else { return .agentMissing }
        guard fm.fileExists(atPath: configURL.path) else { return .notInstalled }
        let present: Set<String>
        let problem: ConfigLines.HookProblem?
        do {
            let config = try ConfigLines(try readText() ?? "", path: configURL.path)
            try config.checkHooksAreArrayTables()
            present = config.ourEvents()
            problem = config.hookProblem(includingOurs: true)
        } catch {
            return .error(String(describing: error))
        }
        if let problem {
            // With our entries in place the user can still reinstall/remove; without them it's an error.
            return present.isEmpty ? .error(String(describing: problem.error(path: configURL.path))) : .partial(problem.message)
        }
        let missing = Self.events.filter { !present.contains($0) }
        if missing.isEmpty { return .installed }
        if present.isEmpty { return .notInstalled }
        return .partial(L("Нет хуков NotchBuddy для событий: %@", missing.joined(separator: ", ")))
    }

    public func install(bridgePath: String) throws {
        let old = try readText()
        let new = try Self.installing(bridgePath: bridgePath, into: old ?? "", path: configURL.path)
        try save(new, replacing: old)
    }

    public func uninstall() throws {
        guard let old = try readText() else { return }
        try save(try Self.uninstalling(from: old, path: configURL.path), replacing: old)
    }

    // MARK: File IO

    private func readText() throws -> String? {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: configURL) } catch {
            throw HookInstallerError.unparsableConfig(path: configURL.path, reason: error.localizedDescription)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw HookInstallerError.unparsableConfig(path: configURL.path, reason: L("файл не в кодировке UTF-8"))
        }
        return text
    }

    private func save(_ text: String, replacing old: String?) throws {
        guard text != old else { return }
        do { try HookInstallers.backup(configURL, home: home) } catch {
            throw HookInstallerError.writeFailed(path: configURL.path,
                                                 reason: L("не удалось сделать резервную копию: %@", error.localizedDescription))
        }
        try HookInstallers.write(text, to: configURL)
    }

    // MARK: Pure transforms

    static func installing(bridgePath: String, into text: String, path: String) throws -> String {
        let config = try ConfigLines(text, path: path)
        try config.checkHooksAreArrayTables()
        // One invalid [[hooks]] entry makes Kimi drop the whole section, ours included.
        if let problem = config.hookProblem(includingOurs: false) { throw problem.error(path: path) }
        var lines = config.withoutOurTables().lines
        while let last = lines.last, ConfigLines.isBlank(last) { lines.removeLast() }

        let cr = config.lineSuffix
        if !lines.isEmpty { lines.append(cr) }
        lines.append(managedComment + cr)
        let command = tomlString(hookCommand(bridgePath: bridgePath))
        for (n, event) in events.enumerated() {
            if n > 0 { lines.append(cr) }
            lines.append("[[hooks]]" + cr)
            lines.append("event = \(tomlString(event))" + cr)
            lines.append("command = \(command)" + cr)
            lines.append("timeout = \(timeout)" + cr)
        }
        let output = lines.joined(separator: "\n") + "\n"

        // Safety net: never write a file whose hooks section Kimi would reject.
        let check = try ConfigLines(output, path: path)
        try check.checkHooksAreArrayTables()
        if let problem = check.hookProblem(includingOurs: true) { throw problem.error(path: path) }
        guard check.ourEvents() == Set(events) else {
            throw HookInstallerError.unparsableConfig(path: path, reason: L("не удалось проверить результат правки"))
        }
        return output
    }

    /// Returns `text` unchanged when none of our tables is present.
    static func uninstalling(from text: String, path: String) throws -> String {
        let config = try ConfigLines(text, path: path)
        var (lines, removed) = config.withoutOurTables()
        guard removed else { return text }
        while let last = lines.last, ConfigLines.isBlank(last) { lines.removeLast() }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// TOML basic string.
    static func tomlString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

// MARK: - Line-based TOML structure

extension KimiHookInstaller {
    /// Just enough TOML structure to edit tables safely: which lines are table headers,
    /// which are `key = value` lines, and which belong to multi-line strings or arrays
    /// (so a `[[hooks]]` inside a string is never mistaken for a header). The scanning itself
    /// is `CodexConfigTOML`'s: dotted keys come as parts, so `["hooks.x"]` ≠ `hooks.x`.
    struct ConfigLines {
        enum Kind: Equatable {
            case header(path: [String], isArrayTable: Bool)
            /// `value` is the raw text after `=`, including continuation lines and any comment.
            case keyValue(keys: [String], value: String)
            case blank
            case comment
            case continuation
        }

        /// A `[[hooks]]` entry Kimi's config schema rejects.
        struct HookProblem {
            /// 1-based.
            let line: Int
            let reason: String
            let isOurs: Bool
            let breaksLogin: Bool

            var message: String {
                let consequence = breaksLogin
                    ? L("с такой записью Kimi не сможет войти в аккаунт или выйти из него")
                    : L("из-за неё Kimi отключит все хуки из config.toml, включая хуки NotchBuddy")
                let advice = isOurs ? L("переустановите хуки NotchBuddy") : L("исправьте или удалите эту запись [[hooks]]")
                return L("строка %@: %@ — %@; %@", line, reason, consequence, advice)
            }

            func error(path: String) -> HookInstallerError {
                .unparsableConfig(path: path, reason: message)
            }
        }

        /// Raw lines without `\n` (a CRLF file keeps its `\r`).
        let lines: [String]
        let kinds: [Kind]
        /// `"\r"` for CRLF files, appended to the lines we add.
        let lineSuffix: String
        private let path: String

        init(_ text: String, path: String) throws {
            self.path = path
            let document: CodexConfigTOML
            do { document = try CodexConfigTOML(text: text) } catch let error as CodexConfigTOML.ScanError {
                throw HookInstallerError.unparsableConfig(path: path, reason: error.description)
            }
            lines = document.lines.map { String(String.UnicodeScalarView($0)) }
            lineSuffix = text.contains("\r\n") ? "\r" : ""

            var kinds = [Kind](repeating: .continuation, count: lines.count)
            for item in document.items {
                switch item.kind {
                case .trivia:
                    kinds[item.firstLine] = Self.isBlank(lines[item.firstLine]) ? .blank : .comment
                case .header(let isArray):
                    kinds[item.firstLine] = .header(path: item.keys.map(\.name), isArrayTable: isArray)
                case .keyValue:
                    kinds[item.firstLine] = .keyValue(keys: item.keys.map(\.name),
                                                      value: String(String.UnicodeScalarView(item.value)))
                }
            }
            self.kinds = kinds
        }

        static func isBlank(_ line: String) -> Bool {
            line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// Appending `[[hooks]]` tables is only valid TOML if `hooks` is defined by nothing but plain
        /// `[[hooks]]` tables: `[hooks]`, `[hooks.x]`, `[[hooks.x]]` or a top-level `hooks…` key all clash.
        func checkHooksAreArrayTables() throws {
            var topLevel = true
            for (index, kind) in kinds.enumerated() {
                switch kind {
                case .header(let path, let isArray):
                    topLevel = false
                    if path.first == "hooks" && (path.count > 1 || !isArray) { throw conflict(index) }
                case .keyValue(let keys, _) where topLevel && keys.first == "hooks":
                    throw conflict(index)
                default:
                    break
                }
            }
        }

        private func conflict(_ index: Int) -> HookInstallerError {
            .unparsableConfig(path: path,
                              reason: L("строка %@: hooks задан не только таблицами [[hooks]], не могу безопасно изменить", index + 1))
        }

        /// `[[hooks]]` tables: header line up to the next header (exclusive) or EOF.
        var hookTables: [Range<Int>] {
            let headers = kinds.indices.filter { if case .header = kinds[$0] { return true }; return false }
            return headers.enumerated().compactMap { n, start in
                guard case .header(let path, true) = kinds[start], path == ["hooks"] else { return nil }
                let end = n + 1 < headers.count ? headers[n + 1] : lines.count
                return start..<end
            }
        }

        func value(of key: String, in table: Range<Int>) -> String? {
            for i in table { if case .keyValue(let keys, let value) = kinds[i], keys == [key] { return value } }
            return nil
        }

        /// The decoded string value of `key` (a trailing comment is not part of it).
        func string(of key: String, in table: Range<Int>) -> String? {
            guard let raw = value(of: key, in: table), case .string(let s) = TOMLValue(raw) else { return nil }
            return s
        }

        func isOurs(_ table: Range<Int>) -> Bool {
            string(of: "command", in: table)?.contains(Paths.hookMarker) ?? false
        }

        func ourEvents() -> Set<String> {
            Set(hookTables.filter(isOurs).compactMap { string(of: "event", in: $0) })
        }

        // MARK: Hook schema

        /// Keys `HookDefSchema` allows; it is `.strict()`, so anything else invalidates the section.
        static let hookKeys: Set<String> = ["event", "matcher", "command", "timeout"]

        /// Events the runtime accepts on top of the 16 node-sdk knows; node-sdk's strict reader
        /// (login/logout) rejects the file when one of them is present.
        static let runtimeOnlyEvents: Set<String> = ["UserPromptQueued", "TurnStarted", "SessionHeartbeat", "TaskStarted"]

        /// First `[[hooks]]` table Kimi would reject; `includingOurs: false` skips our own tables.
        func hookProblem(includingOurs: Bool) -> HookProblem? {
            for table in hookTables {
                let ours = isOurs(table)
                guard includingOurs || !ours else { continue }
                if let (line, reason, breaksLogin) = Self.problem(in: table, kinds: kinds) {
                    return HookProblem(line: line, reason: reason, isOurs: ours, breaksLogin: breaksLogin)
                }
            }
            return nil
        }

        /// `HookDefSchema`: `event` (enum), `matcher?` (string), `command` (non-empty string),
        /// `timeout?` (integer 1…600), nothing else.
        private static func problem(in table: Range<Int>, kinds: [Kind]) -> (Int, String, Bool)? {
            var seen = Set<String>()
            for i in table {
                guard case .keyValue(let keys, let raw) = kinds[i] else { continue }
                let line = i + 1
                let name = keys.joined(separator: ".")
                guard keys.count == 1, hookKeys.contains(name) else {
                    return (line, L("недопустимый ключ «%@» в [[hooks]] (разрешены только event, matcher, command, timeout)", name), false)
                }
                guard seen.insert(name).inserted else { return (line, L("ключ «%@» задан дважды", name), false) }
                let value = TOMLValue(raw)
                if value == .malformed { return (line, L("некорректное значение %@", name), false) }
                switch name {
                case "event":
                    guard case .string(let event) = value else { return (line, L("event должен быть строкой"), false) }
                    if runtimeOnlyEvents.contains(event) {
                        return (line, L("событие «%@» не поддерживается конфигурацией Kimi (node-sdk)", event), true)
                    }
                    if !KimiHookInstaller.events.contains(event) { return (line, L("неизвестное событие «%@»", event), false) }
                case "command":
                    guard case .string(let command) = value else { return (line, L("command должен быть строкой"), false) }
                    if command.isEmpty { return (line, L("пустой command"), false) }
                case "matcher":
                    guard case .string = value else { return (line, L("matcher должен быть строкой"), false) }
                default: // timeout
                    guard let seconds = value.integral, (1...600).contains(seconds) else {
                        return (line, L("timeout = %@: нужно целое число секунд от 1 до 600", value.display(raw)), false)
                    }
                }
            }
            let header = table.lowerBound + 1
            if !seen.contains("event") { return (header, L("в [[hooks]] нет обязательного ключа event"), false) }
            if !seen.contains("command") { return (header, L("в [[hooks]] нет обязательного ключа command"), false) }
            return nil
        }

        /// Lines with our tables (and our comment) cut out. Comments and blank lines at the end of a
        /// table belong to whatever follows, so they stay; blank runs left at the cuts are collapsed.
        func withoutOurTables() -> (lines: [String], removed: Bool) {
            var drop = Set<Int>()
            for table in hookTables where isOurs(table) {
                var last = table.lowerBound
                for i in table {
                    switch kinds[i] {
                    case .keyValue, .continuation: last = i
                    default: break
                    }
                }
                drop.formUnion(table.lowerBound...last)
            }
            for i in lines.indices where kinds[i] == .comment {
                if lines[i].trimmingCharacters(in: .whitespacesAndNewlines) == managedComment { drop.insert(i) }
            }
            guard !drop.isEmpty else { return (lines, false) }

            var out: [String] = []
            var afterCut = false
            for i in lines.indices {
                if drop.contains(i) { afterCut = true; continue }
                let blank = Self.isBlank(lines[i])
                if blank && afterCut && (out.last.map(Self.isBlank) ?? true) { continue }
                if !blank { afterCut = false }
                out.append(lines[i])
            }
            return (out, true)
        }

        /// Content of a one-line TOML string value (`"x"` or `'x'`); other values as written.
        static func unquoted(_ value: String) -> String {
            guard let q = value.first, q == "\"" || q == "'" else { return value }
            var out = ""
            var escaped = false
            for ch in value.dropFirst() {
                if escaped { out.append(ch); escaped = false }
                else if q == "\"" && ch == "\\" { escaped = true }
                else if ch == q { break }
                else { out.append(ch) }
            }
            return out
        }
    }

    /// A TOML value as far as the hooks schema cares.
    enum TOMLValue: Equatable {
        case string(String)
        case integer(Int)
        case float(Double)
        /// A boolean, date, array or inline table.
        case other
        /// Not a value (e.g. text left over after a string).
        case malformed

        /// `raw`: the text after `=`, possibly spanning lines, possibly with a trailing comment.
        init(_ raw: String) {
            var reader = Reader(scalars: Array(raw.unicodeScalars))
            reader.skipSpaces()
            guard let first = reader.current else { self = .malformed; return }
            let value: TOMLValue
            switch first {
            case "\"", "'":
                guard let s = reader.string() else { self = .malformed; return }
                value = .string(s)
            case "[", "{":
                self = .other  // bracket balance was already checked by the scanner
                return
            default:
                value = Self.scalar(reader.token())
            }
            self = reader.atEnd() ? value : .malformed
        }

        /// Kimi validates with zod after smol-toml: `5` and `5.0` are both the JS number 5.
        var integral: Int? {
            switch self {
            case .integer(let n): return n
            case .float(let d) where d.isFinite && d.rounded() == d && abs(d) < 1e15: return Int(d)
            default: return nil
            }
        }

        func display(_ raw: String) -> String {
            switch self {
            case .integer(let n): return String(n)
            case .float(let d): return String(d)
            case .string(let s): return KimiHookInstaller.tomlString(s)
            default:
                let firstLine = raw.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
                return firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        private static func scalar(_ token: String) -> TOMLValue {
            if token == "true" || token == "false" { return .other }
            let digits = token.replacingOccurrences(of: "_", with: "")
            for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where digits.hasPrefix(prefix) {
                return Int(digits.dropFirst(2), radix: radix).map { .integer($0) } ?? .malformed
            }
            if let n = Int(digits) { return .integer(n) }
            if ["inf", "+inf", "-inf", "nan", "+nan", "-nan"].contains(digits) { return .float(.nan) }
            if digits.unicodeScalars.contains(where: { ("0"..."9").contains($0) }),
               digits.unicodeScalars.allSatisfy({ "0123456789+-.eE".unicodeScalars.contains($0) }),
               let d = Double(digits) {
                return .float(d)
            }
            if token.first.map({ ("0"..."9").contains($0) }) == true { return .other }  // dates and times
            return .malformed
        }

        private struct Reader {
            let scalars: [Unicode.Scalar]
            var i = 0

            var current: Unicode.Scalar? { peek(0) }
            func peek(_ k: Int) -> Unicode.Scalar? { i + k < scalars.count ? scalars[i + k] : nil }

            mutating func skipSpaces() {
                while let c = current, c == " " || c == "\t" || c == "\r" { i += 1 }
            }

            /// Only a comment may follow a value.
            mutating func atEnd() -> Bool {
                skipSpaces()
                return current == nil || current == "#"
            }

            /// A bare token: number, boolean or date.
            mutating func token() -> String {
                var out = String.UnicodeScalarView()
                while let c = current, c != " ", c != "\t", c != "\r", c != "\n", c != "#" { out.append(c); i += 1 }
                return String(out)
            }

            /// Basic, literal, multi-line basic or multi-line literal string at the cursor.
            mutating func string() -> String? {
                guard let q = current else { return nil }
                if peek(1) == q && peek(2) == q { return multiline(q) }
                i += 1
                var out = String.UnicodeScalarView()
                while let c = current {
                    i += 1
                    if c == q { return String(out) }
                    if c == "\n" { return nil }
                    if q == "\"" && c == "\\" {
                        guard escape(into: &out) else { return nil }
                    } else {
                        out.append(c)
                    }
                }
                return nil
            }

            private mutating func multiline(_ q: Unicode.Scalar) -> String? {
                i += 3
                if current == "\n" { i += 1 } else if current == "\r" && peek(1) == "\n" { i += 2 }
                var out = String.UnicodeScalarView()
                while let c = current {
                    if c == q && peek(1) == q && peek(2) == q {
                        var run = 3  // up to two quotes may directly precede the closing delimiter
                        while run < 5, peek(run) == q { run += 1 }
                        for _ in 0..<(run - 3) { out.append(q) }
                        i += run
                        return String(out)
                    }
                    i += 1
                    guard q == "\"" && c == "\\" else { out.append(c); continue }
                    // A line-ending backslash swallows the newline and the whitespace after it.
                    var j = i
                    while j < scalars.count, scalars[j] == " " || scalars[j] == "\t" || scalars[j] == "\r" { j += 1 }
                    if j < scalars.count, scalars[j] == "\n" {
                        i = j
                        while let w = current, w == " " || w == "\t" || w == "\r" || w == "\n" { i += 1 }
                        continue
                    }
                    guard escape(into: &out) else { return nil }
                }
                return nil
            }

            /// Cursor just after a backslash.
            private mutating func escape(into out: inout String.UnicodeScalarView) -> Bool {
                guard let e = current else { return false }
                i += 1
                switch e {
                case "b": out.append("\u{08}")
                case "t": out.append("\t")
                case "n": out.append("\n")
                case "f": out.append("\u{0C}")
                case "r": out.append("\r")
                case "e": out.append("\u{1B}")
                case "\"", "\\": out.append(e)
                case "u", "U", "x":
                    let count = e == "u" ? 4 : e == "U" ? 8 : 2
                    var hex = ""
                    for _ in 0..<count {
                        guard let h = current else { return false }
                        hex.unicodeScalars.append(h)
                        i += 1
                    }
                    guard let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) else { return false }
                    out.append(scalar)
                default:
                    return false
                }
                return true
            }
        }
    }
}
