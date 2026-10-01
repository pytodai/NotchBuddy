import Darwin
import Foundation
import NotchBuddyCore

/// Claude Code `statusLine` command: saves `rate_limits` for the app and prints one short line.
/// Runs on every status refresh, so it must be quick and must always exit 0.
enum StatusLineCommand {
    static func run() -> Int32 {
        // Always drain stdin: exiting without reading it makes Claude Code see EPIPE and blank the line.
        let stdin = BridgeIO.readStdin()
        guard let payload = try? JSONValue.parse(stdin) else { return 0 }

        let limits = RateLimitsCache.fromStatusLine(payload)
        if let limits {
            do { try limits.write() } catch { DebugLog.log("statusline: cache write failed: \(error)") }
        }

        let line = render(payload, limits: limits)
        if !line.isEmpty { BridgeIO.write(line + "\n", to: STDOUT_FILENO) }
        return 0
    }

    /// "Opus · ctx 42% · 5ч 23% · 7д 41%", leaving out whatever is unknown.
    static func render(_ payload: JSONValue, limits: RateLimitsCache?) -> String {
        var parts: [String] = []
        if let model = payload.at("model", "display_name")?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            parts.append(String(model.prefix(40)))
        }
        if let context = payload.at("context_window", "used_percentage")?.double {
            parts.append("ctx \(percent(context))%")
        }
        if let five = limits?.fiveHour { parts.append(L("5ч %@%%", percent(five.usedPercentage))) }
        if let seven = limits?.sevenDay { parts.append(L("7д %@%%", percent(seven.usedPercentage))) }
        return parts.joined(separator: " · ")
    }

    private static func percent(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, 0), 999).rounded())
    }
}
