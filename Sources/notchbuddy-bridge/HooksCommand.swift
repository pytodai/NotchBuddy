import Darwin
import NotchBuddyCore

enum HooksAction: String, Equatable {
    case install, uninstall, status
}

/// Interactive hook management. Unlike hook mode, this reports errors and exits non-zero.
enum HooksCommand {
    static func run(_ action: HooksAction, sources: [AgentSource]) -> Int32 {
        var failed = false
        for source in sources {
            let installer = HookInstallers.installer(for: source)
            do {
                switch action {
                case .install: try installer.install(bridgePath: Paths.bridge.path)
                case .uninstall: try installer.uninstall()
                case .status: break
                }
                print("\(source.displayName): \(describe(installer.status()))")
            } catch {
                failed = true
                BridgeIO.write("\(source.displayName): \(error)\n", to: STDERR_FILENO)
            }
        }
        return failed ? 1 : 0
    }

    static func describe(_ status: HookInstallStatus) -> String {
        switch status {
        case .installed: return L("установлены")
        case .notInstalled: return L("не установлены")
        case .partial(let why): return L("частично (%@)", why)
        case .agentMissing: return L("агент не найден")
        case .error(let why): return L("ошибка: %@", why)
        }
    }
}
