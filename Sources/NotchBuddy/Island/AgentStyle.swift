import SwiftUI
import NotchBuddyCore

/// Colors and marks the island uses for agents. The island is always black, so colors are fixed
/// (they do not follow the system appearance).
enum AgentStyle {
    static func tint(_ source: AgentSource) -> Color {
        switch source {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)   // Claude terracotta
        case .codex: return Color(white: 0.94)
        case .kimi: return Color(red: 0.47, green: 0.45, blue: 1.0)
        default: return Color(agentHex: AgentCatalog.descriptor(for: source)?.tint ?? 0x8C8C8C)
        }
    }

    /// Darker end of the badge gradient.
    static func tintDeep(_ source: AgentSource) -> Color {
        switch source {
        case .claude: return Color(red: 0.72, green: 0.34, blue: 0.23)
        case .codex: return Color(white: 0.74)
        case .kimi: return Color(red: 0.33, green: 0.27, blue: 0.86)
        default: return Color(agentHex: AgentCatalog.descriptor(for: source)?.tintDeep ?? 0x5A5A5A)
        }
    }

    static func glyphColor(_ source: AgentSource) -> Color {
        if source == .codex { return Color(white: 0.06) }
        // Light badges (Grok) need a dark glyph, like Codex.
        let tint = AgentCatalog.descriptor(for: source)?.tint ?? 0
        let luma = 0.299 * Double(tint >> 16 & 0xFF) + 0.587 * Double(tint >> 8 & 0xFF) + 0.114 * Double(tint & 0xFF)
        return luma > 180 ? Color(white: 0.06) : .white
    }

}

extension SessionStatus {
    var tint: Color {
        switch self {
        case .waitingForUser: return Color(red: 1.0, green: 0.62, blue: 0.1)
        case .working: return Color(red: 0.33, green: 0.64, blue: 1.0)
        case .finished: return Color(red: 0.25, green: 0.84, blue: 0.42)
        case .error: return Color(red: 1.0, green: 0.33, blue: 0.3)
        case .idle: return Color(white: 0.56)
        }
    }

    /// "Работает", "Ждёт тебя", "Готово", "Ошибка", "Свободен" (the copy catalog, `SessionStrings`).
    var label: String { SessionStrings.status(self) }

    /// Lower-case form for running text ("работает 2:14").
    var shortLabel: String { SessionStrings.statusInline(self) }

    /// Whether the elapsed time reads as a running clock (the agent is busy or the user is awaited).
    var runsClock: Bool { self == .working || self == .waitingForUser }
}

/// How a tool call is presented (session cards, permission card).
enum ToolStyle {
    static func symbol(for toolName: String?) -> String {
        switch kind(of: toolName) {
        case .shell: return "apple.terminal"
        case .edit: return "pencil"
        case .read: return "doc.text"
        case .web: return "globe"
        case .search: return "magnifyingglass"
        case .agent: return "person.2"
        case .plan: return "list.bullet.clipboard"
        case .mcp: return "puzzlepiece.extension"
        case .permissions: return "lock.open"
        case .other: return "wrench"
        }
    }

    /// Russian verb phrase for the card title.
    static func action(for toolName: String?) -> String {
        switch kind(of: toolName) {
        case .shell: return L("Выполнить команду")
        case .edit: return L("Изменить файлы")
        case .read: return L("Прочитать файл")
        case .web: return L("Обратиться к сети")
        case .search: return L("Искать по файлам")
        case .agent: return L("Запустить субагента")
        case .plan: return L("Утвердить план")
        case .mcp: return L("Вызвать MCP-инструмент")
        case .permissions: return L("Выдать дополнительные права")
        case .other: return L("Использовать инструмент")
        }
    }

    /// A tool as people name it ("exec_command" → "Терминал", "mcp__github__create_issue" → "MCP · github"): the copy
    /// catalog's (`SessionStrings.toolName`).
    static func displayName(_ toolName: String) -> String { SessionStrings.toolName(toolName) }

    private enum Kind { case shell, edit, read, web, search, agent, plan, mcp, permissions, other }

    private static func kind(of toolName: String?) -> Kind {
        guard let raw = toolName?.lowercased(), !raw.isEmpty else { return .other }
        if raw.hasPrefix("mcp__") { return .mcp }
        switch raw {
        case "bash", "shell", "exec_command", "local_shell", "unified_exec", "write_stdin", "run_shell_command", "bashoutput":
            return .shell
        case "edit", "multiedit", "write", "apply_patch", "notebookedit", "strreplacefile", "writefile":
            return .edit
        case "read", "readfile", "readmediafile", "notebookread", "view_image":
            return .read
        case "webfetch", "websearch", "fetchurl", "web_search", "searchweb":
            return .web
        case "grep", "glob", "ls", "list_dir":
            return .search
        case "task", "agent", "spawn_agent":
            return .agent
        case "exitplanmode":
            return .plan
        case "request_permissions":
            return .permissions
        default:
            return .other
        }
    }
}

/// Text colors on the black island. Status colors (`SessionStatus.tint`) color every indicator, pill and
/// chip; an agent's own color appears only in its `AgentMark`.
enum IslandPalette {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.64)
    /// About 5.3:1 on black, enough for 10.5–11 pt text.
    static let tertiary = Color.white.opacity(0.50)
    static let hairline = Color.white.opacity(0.1)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.38)
}

extension Color {
    /// 0xRRGGBB, as `AgentDescriptor.tint` stores it.
    init(agentHex hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
