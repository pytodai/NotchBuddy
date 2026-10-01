import Foundation
import NotchBuddyCore

/// What a permission card shows: exactly what the user is approving, built from the raw
/// `tool_input` (never from the one-line summary, which is cut and may be the model's own words).
///
/// - Shell-like tools: the full command (argv arrays are shell-quoted), then every other argument.
/// - Built-in file tools: the path, then the diff (`old_string`/`new_string`, `edits`) or the new
///   content, then every other argument.
/// - Codex `request_permissions`: the requested permissions as JSON; the model's `reason` is kept
///   apart as `justification`.
/// - MCP and any other tool: the full arguments as pretty-printed JSON.
///
/// Invisible and direction-changing characters are replaced with visible `⟨U+XXXX⟩` escapes.
///
/// Building one is linear in the payload (~0.1 ms per KB), so it is built once per request off the main thread
/// (`SocketService`), carried in `PendingPermission` / `PermissionCardInfo` and released with the card.
struct PermissionDetail: Equatable, Sendable {
    /// Monospaced body. Only a body longer than `maxBodyLength` is cut, with a marker saying so.
    var body: String
    /// The model's own explanation (Bash/Codex `description`, `request_permissions` `reason`).
    /// Shown labeled as such, never in place of the body.
    var justification: String?
    /// How many hidden characters were replaced with escapes (body and justification).
    var hiddenCharacters: Int
    /// Characters left out of `body` (0 when it is whole).
    var omittedCharacters: Int

    /// Far above any real command: macOS caps a command line at 1 MiB (ARG_MAX).
    static let maxBodyLength = 1_000_000

    init(event: AgentEvent) {
        let raw = Self.rawText(for: event)
        let body = VisibleText.escapingHidden(VisibleText.collapsingBlankRuns(raw.body))
        let justification = raw.justification.map(VisibleText.escapingHidden)
        hiddenCharacters = body.escaped + (justification?.escaped ?? 0)
        self.justification = justification?.text
        let head = body.text.prefix(Self.maxBodyLength)
        if head.endIndex == body.text.endIndex {
            self.body = body.text
            omittedCharacters = 0
        } else {
            omittedCharacters = body.text[head.endIndex...].count
            self.body = String(head) + L("\n\n… ещё %@ симв. не показано", omittedCharacters)
        }
    }

    // MARK: Building

    private static var noArguments: String { L("Без аргументов") }
    private static func rawText(for event: AgentEvent) -> (body: String, justification: String?) {
        let tool = event.toolName ?? ""
        guard let input = event.raw["tool_input"], !input.isNull else { return (fallback(event), nil) }
        guard let object = input.object else { return (string(input) ?? prettyJSON(input), nil) }

        if tool == "request_permissions" {
            var rest = object
            let reason = takeString("reason", from: &rest)
            if rest.isEmpty { return (L("Агент не указал, какие права нужны"), reason) }
            if rest.count == 1, let permissions = rest["permissions"] { return (prettyJSON(permissions), reason) }
            return (prettyJSON(.object(rest)), reason)
        }
        if tool.lowercased().hasPrefix("mcp__") {
            return (object.isEmpty ? noArguments : prettyJSON(input), nil)
        }

        var rest = object
        if let command = rest["command"].flatMap(commandText) {
            rest["command"] = nil
            // Codex puts "network-access <host>" here for network approvals: that is part of the
            // request, not the model's words, so it stays with the other arguments.
            let isNetwork = event.source == .codex && string(rest["description"])?.hasPrefix("network-access") == true
            let description = isNetwork ? nil : takeString("description", from: &rest)
            return (withOtherArguments(command, rest), description)
        }
        if let plan = string(rest["plan"]), nonEmpty(plan) != nil {
            rest["plan"] = nil
            return (withOtherArguments(plan, rest), nil)
        }
        if let pathKey = ["file_path", "notebook_path", "path"].first(where: { nonEmpty(string(rest[$0])) != nil }),
           let path = string(rest.removeValue(forKey: pathKey)) {
            var parts = [path]
            if let preview = takeFilePreview(from: &rest) {
                parts.append("")
                parts.append(preview)
            }
            return (withOtherArguments(parts.joined(separator: "\n"), rest), nil)
        }
        return (object.isEmpty ? noArguments : prettyJSON(input), nil)
    }

    /// Diff or new content of a built-in file tool; removes the keys it used from `rest`.
    private static func takeFilePreview(from rest: inout [String: JSONValue]) -> String? {
        if let old = string(rest["old_string"]) {
            rest["old_string"] = nil
            let new = takeString("new_string", from: &rest, keepingEmpty: true) ?? ""
            return diff(old: old, new: new)
        }
        if let edits = rest["edits"]?.array, !edits.isEmpty,
           edits.allSatisfy({ string($0["old_string"]) != nil && string($0["new_string"]) != nil }) {
            rest["edits"] = nil
            return edits.enumerated().map { index, edit in
                var other = edit.object ?? [:]
                let old = string(other.removeValue(forKey: "old_string")) ?? ""
                let new = string(other.removeValue(forKey: "new_string")) ?? ""
                var header = L("@@ правка %@ из %@", index + 1, edits.count)
                if !other.isEmpty { header += " (" + argumentLines(other).joined(separator: ", ") + ")" }
                return header + "\n" + diff(old: old, new: new)
            }.joined(separator: "\n\n")
        }
        for key in ["content", "new_source"] {
            if let text = string(rest[key]) {
                rest[key] = nil
                return text
            }
        }
        return nil
    }

    private static func diff(old: String, new: String) -> String {
        prefixed(old, with: "− ") + "\n" + prefixed(new, with: "+ ")
    }

    /// Arguments not shown above, so nothing the agent sent stays hidden.
    private static func withOtherArguments(_ text: String, _ rest: [String: JSONValue]) -> String {
        guard !rest.isEmpty else { return text }
        return text + L("\n\n── другие параметры ──\n") + argumentLines(rest).joined(separator: "\n")
    }

    private static func argumentLines(_ arguments: [String: JSONValue]) -> [String] {
        arguments.keys.sorted().map { "\($0): \(compactJSON(arguments[$0] ?? .null))" }
    }

    /// A command string as is, or an argv array quoted for a POSIX shell. Nil for anything else.
    private static func commandText(_ value: JSONValue) -> String? {
        if case .string(let s) = value { return nonEmpty(s) == nil ? nil : s }
        guard let items = value.array, !items.isEmpty else { return nil }
        let argv = items.compactMap { item -> String? in
            if case .string(let s) = item { return s }
            return nil
        }
        guard argv.count == items.count else { return nil }
        return argv.map(shellQuoted).joined(separator: " ")
    }

    private static let shellSafe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")

    static func shellQuoted(_ arg: String) -> String {
        if !arg.isEmpty, arg.unicodeScalars.allSatisfy(shellSafe.contains) { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Only real JSON strings (`JSONValue.string` also renders numbers and booleans).
    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    /// Removes a string argument and returns it trimmed (nil if blank). Non-string values stay in `rest`.
    private static func takeString(_ key: String, from rest: inout [String: JSONValue], keepingEmpty: Bool = false) -> String? {
        guard case .string(let s)? = rest[key] else { return nil }
        rest[key] = nil
        return keepingEmpty ? s : nonEmpty(s)
    }

    private static func fallback(_ event: AgentEvent) -> String {
        if let summary = nonEmpty(event.toolSummary) {
            // Adapters fold newlines into " ⏎ " for one-line summaries; unfold them for the card.
            return summary.replacingOccurrences(of: " ⏎ ", with: "\n")
        }
        return nonEmpty(event.message) ?? L("Без подробностей")
    }

    static func prettyJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return value.compactText }
        return String(decoding: data, as: UTF8.self)
    }

    private static func compactJSON(_ value: JSONValue) -> String {
        String(decoding: value.serialized(sortedKeys: true), as: UTF8.self)
    }

    private static func prefixed(_ s: String, with marker: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { marker + $0 }.joined(separator: "\n")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

/// Makes text safe to show for approval: characters that are invisible or change the display
/// order (bidi controls, zero-width and other format characters, stray controls, tag characters,
/// variation selectors) are replaced with a visible escape such as `⟨U+202E⟩`.
enum VisibleText {
    static func escapingHidden(_ text: String) -> (text: String, escaped: Int) {
        // Fast path: nearly every payload is clean, and bodies can be large.
        guard text.unicodeScalars.contains(where: mayNeedEscape) else { return (text, 0) }
        let scalars = text.unicodeScalars
        var out = String.UnicodeScalarView()
        var escaped = 0
        var previous: Unicode.Scalar?
        var index = scalars.startIndex
        while index != scalars.endIndex {
            let scalar = scalars[index]
            let next = scalars.index(after: index)
            let crlf = scalar == "\r" && next != scalars.endIndex && scalars[next] == "\n"
            if !crlf, isHidden(scalar, after: previous) {
                out.append(contentsOf: escape(scalar).unicodeScalars)
                escaped += 1
            } else {
                out.append(scalar)
            }
            previous = scalar
            index = next
        }
        return (String(out), escaped)
    }

    static func escaped(_ text: String) -> String { escapingHidden(text).text }

    /// Replaces runs of 3+ blank (whitespace-only) lines with one visible marker, so padding can't push
    /// the part that matters below the fold of the code box.
    static func collapsingBlankRuns(_ text: String) -> String {
        guard text.contains("\n\n\n") || text.contains("\r\n\r\n\r\n") else { return text }
        var out: [Substring] = []
        var blank = 0
        func flush() {
            if blank >= 3 { out.append(Substring("⟨\(blank) \(Lp(blank, "пустая строка|пустые строки|пустых строк"))⟩")) }
            else { out.append(contentsOf: Array(repeating: "", count: blank)) }
            blank = 0
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.allSatisfy(\.isWhitespace) { blank += 1; continue }
            flush()
            out.append(line)
        }
        flush()
        return out.joined(separator: "\n")
    }

    static func escape(_ scalar: Unicode.Scalar) -> String {
        "⟨U+" + String(format: "%04X", scalar.value) + "⟩"
    }

    private static func mayNeedEscape(_ scalar: Unicode.Scalar) -> Bool {
        isHidden(scalar, after: nil)
    }

    private static func isHidden(_ scalar: Unicode.Scalar, after previous: Unicode.Scalar?) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A:
            return false
        case 0xFE0E, 0xFE0F:
            // Text/emoji presentation selectors are normal right after an emoji.
            guard let previous else { return true }
            return !previous.properties.isEmoji
        case 0x034F,            // combining grapheme joiner
             0x115F, 0x1160,    // Hangul choseong/jungseong fillers
             0x17B4, 0x17B5,    // Khmer inherent vowels
             0x180B...0x180F,   // Mongolian variation selectors
             0x3164, 0xFFA0,    // Hangul fillers
             0x2800,            // Braille pattern blank (renders as a space)
             0xFE00...0xFE0D,   // variation selectors
             0xE0100...0xE01EF: // variation selectors supplement
            return true
        default:
            break
        }
        switch scalar.properties.generalCategory {
        // Cf covers U+200B–U+200F, U+202A–U+202E, U+2060–U+2069, U+061C, U+FEFF and tag characters.
        case .control, .format, .lineSeparator, .paragraphSeparator, .unassigned, .surrogate:
            return true
        default:
            return false
        }
    }
}
