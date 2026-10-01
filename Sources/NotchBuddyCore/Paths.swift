import Foundation

public enum Paths {
    /// The user's home. Overridable via NOTCHBUDDY_HOME (tests, debugging) so nothing touches the real one.
    public static var home: URL {
        if let h = ProcessInfo.processInfo.environment["NOTCHBUDDY_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    public static var root: URL { home.appendingPathComponent(".notchbuddy", isDirectory: true) }
    public static var binDir: URL { root.appendingPathComponent("bin", isDirectory: true) }
    public static var bridge: URL { binDir.appendingPathComponent("notchbuddy-bridge") }
    public static var runDir: URL { root.appendingPathComponent("run", isDirectory: true) }
    public static var backupsDir: URL { root.appendingPathComponent("backups", isDirectory: true) }
    public static var logsDir: URL { home.appendingPathComponent("Library/Logs/NotchBuddy", isDirectory: true) }

    /// Socket path. Overridable via NOTCHBUDDY_SOCKET (tests, debugging).
    public static var socket: String {
        if let s = ProcessInfo.processInfo.environment["NOTCHBUDDY_SOCKET"], !s.isEmpty { return s }
        return runDir.appendingPathComponent("nb.sock").path
    }

    /// Latest Claude rate limits written by `notchbuddy-bridge statusline` (see RateLimitsCache).
    public static var rateLimitsCache: URL { runDir.appendingPathComponent("rate-limits.json") }

    /// Shell-safe hook command registered in agent configs.
    /// Guarded so that a missing binary (app uninstalled) never breaks the agent.
    public static func hookCommand(source: AgentSource) -> String {
        let bin = "$HOME/.notchbuddy/bin/notchbuddy-bridge"
        return "/bin/sh -c '[ -x \"\(bin)\" ] && \"\(bin)\" --source \(source.rawValue); exit 0'"
    }

    /// Marker used to recognize our own entries in agent configs.
    public static let hookMarker = "notchbuddy-bridge"
}
