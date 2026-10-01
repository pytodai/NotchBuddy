import NotchBuddyCore

enum BridgeCommand: Equatable {
    case hook(AgentSource)
    case statusLine
    /// `hooks <install|uninstall|status> [claude|codex|kimi|all]` — manage agent hook configs from a terminal.
    case hooks(HooksAction, [AgentSource])
    /// Bad arguments: explain on stderr, still exit 0 (hooks must never fail because of us).
    case usage(String)

    /// The help, in the app's interface language (its setting, read from the app's defaults).
    static var usageText: String {
        let sources = AgentCatalog.all.map(\.id.rawValue).joined(separator: "|")
        let agents = AgentSource.allCases.map(\.rawValue).joined(separator: "|")
        return [
            L("Использование:"),
            "  notchbuddy-bridge --source <\(sources)>",
            "      " + L("хук агента: передаёт событие на остров NotchBuddy"),
            "  notchbuddy-bridge statusline",
            "      " + L("строка состояния Claude Code: запоминает лимиты и печатает одну строку"),
            "  notchbuddy-bridge hooks <install|uninstall|status> [\(agents)|all]",
            "      " + L("установить, удалить или проверить хуки агентов"),
        ].joined(separator: "\n")
    }

    static func parse(_ args: [String]) -> BridgeCommand {
        guard let first = args.first else { return .usage(usageText) }
        switch first {
        case "statusline", "--statusline":
            return .statusLine
        case "hooks":
            guard args.count >= 2, let action = HooksAction(rawValue: args[1]) else { return .usage(usageText) }
            let names = args.dropFirst(2)
            if names.isEmpty || names.contains("all") { return .hooks(action, AgentSource.allCases) }
            var sources: [AgentSource] = []
            for n in names {
                // Agents added through the catalog install only from Settings → «Агенты и хуки».
                guard let s = AgentSource(rawValue: n.lowercased()), AgentSource.allCases.contains(s) else {
                    return .usage(L("notchbuddy-bridge: неизвестный агент «%@»", n) + "\n" + usageText)
                }
                sources.append(s)
            }
            return .hooks(action, sources)
        case "--source":
            guard args.count >= 2 else { return .usage(usageText) }
            return source(args[1])
        default:
            if first.hasPrefix("--source=") { return source(String(first.dropFirst("--source=".count))) }
            return .usage(usageText)
        }
    }

    private static func source(_ raw: String) -> BridgeCommand {
        guard let source = AgentSource(rawValue: raw.lowercased()), AgentCatalog.descriptor(for: source) != nil else {
            return .usage(L("notchbuddy-bridge: неизвестный источник «%@»", raw) + "\n" + usageText)
        }
        return .hook(source)
    }
}
