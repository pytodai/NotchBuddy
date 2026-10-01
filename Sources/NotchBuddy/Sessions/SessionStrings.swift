import Foundation
import NotchBuddyCore

/// Every Russian string the session cards show, in one place: status labels, human tool names, agents, host
/// apps, times and the card's actions. Pure (Foundation only), so `--render-sessions` can check it.
///
/// Style: sentence case, no raw tool ids ("exec_command" → "Терминал"), no quotes around prompts, non-breaking
/// spaces inside numbers with units ("5 мин"), "ё" where it belongs.
enum SessionStrings {
    static let nbsp = "\u{00A0}"

    // MARK: Agents

    /// Full product name: "Claude Code", "Codex", "Kimi Code".
    static func agentName(_ source: AgentSource) -> String {
        switch source {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .kimi: return "Kimi Code"
        default: return source.displayName
        }
    }

    /// Short name for tight spots: "Claude", "Codex", "Kimi".
    static func agentShortName(_ source: AgentSource) -> String {
        switch source {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .kimi: return "Kimi"
        default: return AgentCatalog.descriptor(for: source)?.shortName ?? source.rawValue
        }
    }

    // MARK: Status

    /// Pill label: "Работает", "Ждёт тебя", "Готово", "Ошибка", "Свободен".
    static func status(_ status: SessionStatus) -> String {
        switch status {
        case .working: return L("Работает")
        case .waitingForUser: return L("Ждёт тебя")
        case .finished: return L("Готово")
        case .error: return L("Ошибка")
        case .idle: return L("Свободен")
        }
    }

    /// Lower case, for running text: "работает 2:14".
    static func statusInline(_ status: SessionStatus) -> String {
        switch status {
        case .working: return L("работает")
        case .waitingForUser: return L("ждёт тебя")
        case .finished: return L("готово")
        case .error: return L("ошибка")
        case .idle: return L("свободен")
        }
    }

    /// What the card says when there is no tool to show.
    static func statusDetail(_ status: SessionStatus) -> String {
        switch status {
        case .working: return L("Думает…")
        case .waitingForUser: return L("Ждёт твоего ответа")
        case .finished: return L("Ход завершён")
        case .error: return L("Ход прервался с ошибкой")
        case .idle: return L("Нет активных задач")
        }
    }

    /// The label of the status clock in the card's details.
    static func statusClockLabel(_ status: SessionStatus) -> String {
        switch status {
        case .working: return L("В работе")
        case .waitingForUser: return L("Ждёт")
        case .finished: return L("Закончил")
        case .error: return L("Сбой")
        case .idle: return L("Без дела")
        }
    }

    // MARK: Tools

    enum ToolKind: Equatable {
        case shell, shellInput, shellOutput, stop, edit, write, patch, notebook, read, image, search, web, webSearch
        case agent, plan, todo, question, skill, permissions, wait, schedule, goal, mcp, other
    }

    static func toolKind(_ raw: String?) -> ToolKind {
        guard let raw, !raw.isEmpty else { return .other }
        let name = raw.lowercased()
        if name.hasPrefix("mcp__") { return .mcp }
        if name.hasPrefix("tower") { return .agent }
        switch name {
        case "bash", "shell", "exec_command", "local_shell", "unified_exec", "run_shell_command", "container.exec",
             "execute_command", "run_terminal_cmd":
            return .shell
        case "write_stdin": return .shellInput
        case "bashoutput", "taskoutput": return .shellOutput
        case "killshell", "killbash", "taskstop": return .stop
        case "edit", "multiedit", "strreplacefile", "str_replace", "str_replace_editor", "edit_file": return .edit
        case "write", "writefile", "create_file": return .write
        case "apply_patch": return .patch
        case "notebookedit": return .notebook
        case "read", "readfile", "notebookread", "view", "read_file", "open_file": return .read
        case "readmediafile", "view_image": return .image
        case "grep", "glob", "ls", "list_dir", "grep_files", "file_search", "find", "search_files", "codebase_search":
            return .search
        case "webfetch", "fetchurl", "fetch", "fetch_url": return .web
        case "websearch", "web_search", "searchweb", "web_search_preview": return .webSearch
        case "task", "agent", "spawn_agent", "agentswarm", "send_input", "wait_agent", "close_agent": return .agent
        case "exitplanmode", "enterplanmode": return .plan
        case "todowrite", "todoread", "update_plan", "settodolist", "tasklist", "taskcreate", "taskupdate": return .todo
        case "askuserquestion", "request_user_input": return .question
        case "skill": return .skill
        case "request_permissions": return .permissions
        case "waitfor", "sleep", "wait": return .wait
        case "croncreate", "crondelete", "cronlist": return .schedule
        case "creategoal", "getgoal", "updategoal", "setgoalbudget": return .goal
        default: return .other
        }
    }

    /// A tool as a person would name it: "Bash" → "Терминал", "mcp__github__create_issue" → "MCP · github".
    /// Unknown tools keep their own name (snake_case turned into words).
    static func toolName(_ raw: String) -> String {
        switch toolKind(raw) {
        case .shell: return L("Терминал")
        case .shellInput: return L("Ввод в терминал")
        case .shellOutput: return L("Вывод команды")
        case .stop: return L("Остановка задачи")
        case .edit: return L("Правка файла")
        case .write: return L("Запись файла")
        case .patch: return L("Правка файлов")
        case .notebook: return L("Правка блокнота")
        case .read: return L("Чтение")
        case .image: return L("Просмотр картинки")
        case .search: return L("Поиск")
        case .web: return L("Веб")
        case .webSearch: return L("Поиск в сети")
        case .agent: return L("Субагент")
        case .plan: return raw.lowercased() == "enterplanmode" ? L("Режим плана") : L("План")
        case .todo: return L("Список задач")
        case .question: return L("Вопрос тебе")
        case .skill: return L("Навык")
        case .permissions: return L("Запрос прав")
        case .wait: return L("Ожидание")
        case .schedule: return L("Расписание")
        case .goal: return L("Цель")
        case .mcp: return "MCP · \(mcpServer(raw) ?? L("сервер"))"
        case .other: return prettified(raw)
        }
    }

    /// The MCP tool itself ("mcp__github__create_issue" → "create issue"), shown before its summary.
    static func mcpTool(_ raw: String) -> String? {
        guard raw.lowercased().hasPrefix("mcp__") else { return nil }
        let rest = raw.dropFirst(5)
        guard let separator = rest.range(of: "__") else { return nil }
        let tool = String(rest[separator.upperBound...])
        return tool.isEmpty ? nil : prettified(tool, capitalize: false)
    }

    static func mcpServer(_ raw: String) -> String? {
        guard raw.lowercased().hasPrefix("mcp__") else { return nil }
        let rest = raw.dropFirst(5)
        let server = rest.range(of: "__").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
        return server.isEmpty ? nil : server
    }

    /// SF Symbol of a tool.
    static func toolSymbol(_ raw: String?) -> String {
        switch toolKind(raw) {
        case .shell, .shellInput, .shellOutput: return "terminal"
        case .stop: return "stop.circle"
        case .edit, .notebook: return "pencil.line"
        case .write: return "square.and.pencil"
        case .patch: return "doc.badge.plus"
        case .read: return "doc.text"
        case .image: return "photo"
        case .search: return "magnifyingglass"
        case .web: return "globe"
        case .webSearch: return "network"
        case .agent: return "person.2"
        case .plan: return "map"
        case .todo: return "checklist"
        case .question: return "questionmark.bubble"
        case .skill: return "sparkles"
        case .permissions: return "lock.open"
        case .wait: return "hourglass"
        case .schedule: return "calendar.badge.clock"
        case .goal: return "scope"
        case .mcp: return "puzzlepiece.extension"
        case .other: return "wrench.and.screwdriver"
        }
    }

    /// Whether the summary is code-like (a command, a path, a pattern): set in a monospaced face.
    static func toolSummaryIsCode(_ raw: String?) -> Bool {
        switch toolKind(raw) {
        case .agent, .question, .plan, .todo, .skill, .goal, .webSearch: return false
        default: return true
        }
    }

    /// `some_tool_name` → "Some tool name"; CamelCase stays as is.
    static func prettified(_ raw: String, capitalize: Bool = true) -> String {
        guard raw.contains("_") else { return raw }
        let words = raw.split(separator: "_").map(String.init).filter { !$0.isEmpty }
        guard let first = words.first else { return raw }
        let head = capitalize ? first.prefix(1).uppercased() + first.dropFirst() : first
        return ([head] + words.dropFirst()).joined(separator: " ")
    }

    /// A summary as one line: the adapters' " ⏎ " marks and runs of whitespace become single spaces.
    static func oneLine(_ text: String?) -> String? {
        guard let text else { return nil }
        return SessionNaming.oneLine(text.replacingOccurrences(of: " ⏎ ", with: " "))
    }

    /// What a call works on, for people: a patch names its files ("src/auth.ts +2") instead of showing
    /// "*** Begin Patch", an MCP call leads with its tool; everything else is the summary on one line.
    static func toolSummary(_ tool: String, _ summary: String?) -> String? {
        var text = oneLine(summary)
        if toolKind(tool) == .patch, let raw = summary, let files = patchFiles(raw), let first = files.first {
            text = files.count > 1 ? "\(first) +\(files.count - 1)" : first
        }
        if let mcp = mcpTool(tool) { text = text.map { "\(mcp) · \($0)" } ?? mcp }
        return text
    }

    /// The files an `apply_patch` touches ("*** Update File: a.swift", Add, Delete), in order; nil when none.
    static func patchFiles(_ patch: String) -> [String]? {
        var files: [String] = []
        let text = patch.replacingOccurrences(of: " ⏎ ", with: "\n")
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            for marker in ["*** Update File:", "*** Add File:", "*** Delete File:"] where line.hasPrefix(marker) {
                let path = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty, !files.contains(path) { files.append(path) }
            }
        }
        return files.isEmpty ? nil : files
    }

    /// An agent's answer as one plain line (Markdown marks dropped), reading like a sentence: a heading gets its
    /// full stop, list items run on with commas ("бренд: заголовок, адаптив, кнопка."). The card's activity line.
    static func replyLine(_ reply: String?) -> String? {
        guard let reply else { return nil }
        var line = ""
        var previousWasItem = false
        for raw in markdownStripped(reply).split(separator: "\n") {
            var text = String(raw)
            let item = text.hasPrefix("• ")
            if item { text = String(text.dropFirst(2)) }
            let last = line.last
            if line.isEmpty {
                line = text
            } else if item && previousWasItem {
                if last == "." || last == ";" { line.removeLast() }
                line += ", " + text
            } else if let last, ".:;!?…,—".contains(last) {
                line += " " + text
            } else {
                line += ". " + text
            }
            previousWasItem = item
        }
        if previousWasItem, let last = line.last, !".!?…".contains(last) { line += "." }
        return oneLine(line)
    }

    /// An answer's text without Markdown decoration: headers, list bullets (as "•"), emphasis, inline code
    /// and code fences; blank lines dropped.
    static func markdownStripped(_ reply: String) -> String {
        markdownLines(reply).map(\.text).joined(separator: "\n")
    }

    /// `markdownStripped` line by line, headings marked (the card sets them bold).
    static func markdownLines(_ reply: String) -> [(text: String, heading: Bool)] {
        var lines: [(text: String, heading: Bool)] = []
        let text = reply.replacingOccurrences(of: " ⏎ ", with: "\n")
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { continue }
            var heading = false
            while line.hasPrefix("#") { line.removeFirst(); heading = true }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "• " + line.dropFirst(2) }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { lines.append((line, heading)) }
        }
        return lines
    }

    /// Outcome of a call in the timeline.
    static func toolOutcome(_ outcome: ToolCall.Outcome) -> String {
        switch outcome {
        case .running: return L("идёт")
        case .succeeded: return L("готово")
        case .failed: return L("ошибка")
        case .abandoned: return L("прервано")
        }
    }

    // MARK: Times

    /// "12 с", "5 мин", "2 ч 10 мин", "3 д 4 ч" (non-breaking spaces inside).
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = wholeSeconds(interval)
        if seconds < 60 { return L("%@\u{00A0}с", seconds) }
        let minutes = seconds / 60
        if minutes < 60 { return L("%@\u{00A0}мин", minutes) }
        let hours = minutes / 60, restMinutes = minutes % 60
        if hours < 24 {
            return restMinutes == 0 ? L("%@\u{00A0}ч", hours) : L("%@\u{00A0}ч %@\u{00A0}мин", hours, restMinutes)
        }
        let days = hours / 24, restHours = hours % 24
        return restHours == 0 ? L("%@\u{00A0}д", days) : L("%@\u{00A0}д %@\u{00A0}ч", days, restHours)
    }

    /// Running clock: "0:07", "2:14", "1:02:03".
    static func clock(_ interval: TimeInterval) -> String {
        let seconds = wholeSeconds(interval)
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "только что", "5 мин назад", "2 ч назад", "3 д назад" (the larger unit alone).
    static func ago(_ interval: TimeInterval) -> String {
        let seconds = wholeSeconds(interval)
        if seconds < 60 { return L("только что") }
        let minutes = seconds / 60
        if minutes < 60 { return L("%@\u{00A0}мин назад", minutes) }
        let hours = minutes / 60
        if hours < 24 { return L("%@\u{00A0}ч назад", hours) }
        return L("%@\u{00A0}д назад", hours / 24)
    }

    /// How long a tool call ran: "0,4 с", "12 с", "1:05", "1:02:03".
    static func toolDuration(_ interval: TimeInterval) -> String {
        let value = interval.isFinite ? max(interval, 0) : 0
        if value < 9.95 {
            let tenths = Int((value * 10).rounded())
            return L("%@,%@\u{00A0}с", tenths / 10, tenths % 10)
        }
        if value < 59.5 { return L("%@\u{00A0}с", Int(value.rounded())) }
        return clock(value)
    }

    /// The card's clock for a status that began `since`: a running clock while it works or waits ("2:14"),
    /// "5 мин назад" once it has stopped.
    static func statusClock(_ status: SessionStatus, since: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(since)
        return runsClock(status) ? clock(interval) : ago(interval)
    }

    /// "работает 2:14", "ждёт тебя 0:45", "готово 5 мин назад".
    static func statusWithTime(_ status: SessionStatus, since: Date, now: Date) -> String {
        "\(statusInline(status)) \(statusClock(status, since: since, now: now))"
    }

    static func runsClock(_ status: SessionStatus) -> Bool { status == .working || status == .waitingForUser }

    /// Localized plural, by its Russian forms: plural(2, "вызов", "вызова", "вызовов") → "вызова" / "…s" (key "вызов|вызова|вызовов", see `Lp`).
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        Lp(n, one, few, many)
    }

    /// "3 вызова", "1 ошибка"…
    static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        "\(n)\(nbsp)\(plural(n, one, few, many))"
    }

    private static func wholeSeconds(_ interval: TimeInterval) -> Int {
        // Clamped before converting: `Int(_:)` traps on NaN/∞ and past Int.max.
        interval.isFinite ? Int(min(max(interval, 0), 1e12)) : 0
    }

    // MARK: Places

    /// The project line: the folder's name, or "без папки" for scratch and temporary folders.
    static func project(_ session: AgentSession) -> String {
        session.projectName ?? SessionNaming.noProjectLabel
    }

    /// A path for people: the home folder as "~".
    static func path(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The app the session runs in: "iTerm2", "VS Code", "Claude" (desktop), "Терминал"…, with " · tmux" when inside
    /// tmux; nil when nothing is known.
    static func hostApp(_ host: HostContext) -> String? {
        var name: String?
        for bundle in [host.appBundleIdentifier, host.bundleIdentifier].compactMap({ $0 }) {
            if let known = appNames(bundle) { name = known; break }
        }
        if name == nil, let path = host.appPath, !path.isEmpty {
            let file = (path as NSString).lastPathComponent
            name = file.hasSuffix(".app") ? String(file.dropLast(4)) : file
        }
        if name == nil, let program = host.termProgram { name = termPrograms[program] ?? program }
        if name == nil, let client = host.extra[KimiAdapter.clientTypeKey] {
            name = client.contains("vscode") ? "VS Code" : client.contains("desktop") ? "Kimi" : nil
        }
        if name == nil, host.tty == nil {
            if host.extra["CLAUDE_CODE_ENTRYPOINT"] == "claude-desktop" { name = "Claude" }
            if host.extra["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] == "Codex Desktop" { name = "Codex" }
        }
        if host.tmuxPane != nil || host.extra["TMUX"] != nil {
            return name.map { "\($0) · tmux" } ?? "tmux"
        }
        if host.extra["ZELLIJ_SESSION_NAME"] != nil { return name.map { "\($0) · zellij" } ?? "zellij" }
        if name == nil, host.extra["SSH_CONNECTION"] != nil { return "SSH" }
        return name
    }

    static var termPrograms: [String: String] {
        [
            "iTerm.app": "iTerm2", "Apple_Terminal": L("Терминал"), "WarpTerminal": "Warp", "ghostty": "Ghostty",
            "kitty": "kitty", "WezTerm": "WezTerm", "vscode": "VS Code", "zed": "Zed", "Hyper": "Hyper",
            "alacritty": "Alacritty", "tabby": "Tabby", "claude-desktop": "Claude", "tmux": "tmux",
        ]
    }

    static func appNames(_ bundle: String) -> String? {
        switch bundle {
        case "com.googlecode.iterm2": return "iTerm2"
        case "com.apple.Terminal": return L("Терминал")
        case "com.mitchellh.ghostty": return "Ghostty"
        case "net.kovidgoyal.kitty": return "kitty"
        case "com.github.wez.wezterm": return "WezTerm"
        case "org.alacritty": return "Alacritty"
        case "com.microsoft.VSCode": return "VS Code"
        case "com.microsoft.VSCodeInsiders": return "VS Code Insiders"
        case "com.todesktop.230313mzl4w4u92": return "Cursor"
        case "com.exafunction.windsurf": return "Windsurf"
        case "dev.zed.Zed": return "Zed"
        case "com.anthropic.claudefordesktop": return "Claude"
        case "com.openai.codex": return "Codex"
        case "com.moonshot.kimichat": return "Kimi"
        case "co.zeit.hyper": return "Hyper"
        default:
            if bundle.hasPrefix("dev.warp.Warp") { return "Warp" }
            if bundle.hasPrefix("com.jetbrains.") { return "JetBrains" }
            return nil
        }
    }

    // MARK: Card

    enum Card {
        static var prompt: String { L("Запрос") }
        static var showFullPrompt: String { L("Показать полностью") }
        static var showLessPrompt: String { L("Свернуть запрос") }
        static var awaitingApproval: String { L("ждёт") }
        static var reply: String { L("Ответ") }
        static var tools: String { L("Инструменты") }
        static var app: String { L("Приложение") }
        static var session: String { L("Сессия") }
        static var noPrompt: String { L("Запроса пока не было") }
        static var noTools: String { L("Инструменты ещё не вызывались") }
        static var subagent: String { L("субагент") }
        static var expand: String { L("Подробнее") }
        static var collapse: String { L("Свернуть") }
        /// "ещё 3" / "3 more".
        static func moreTools(_ n: Int) -> String { L("ещё %@", n) }
    }

    enum Actions {
        static var jump: String { L("Перейти") }
        static var jumpHelp: String { L("Открыть терминал или приложение этой сессии") }
        static var copyPath: String { L("Скопировать путь") }
        static var copied: String { L("Скопировано") }
        static var openFolder: String { L("Открыть папку") }
        static var remove: String { L("Убрать") }
        static var removeHelp: String { L("Убрать из списка (ждущие запросы уйдут в терминал)") }
    }
}
