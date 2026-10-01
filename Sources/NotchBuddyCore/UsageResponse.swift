import Foundation

/// Body of `GET https://api.anthropic.com/api/oauth/usage`.
/// Only the two windows NotchBuddy shows are kept; unknown and newer keys are ignored.
public struct UsageResponse: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        /// 0...100 (already a percentage here, unlike the 0...1 rate-limit headers).
        public var utilization: Double
        public var resetsAt: Date?

        public init(utilization: Double, resetsAt: Date?) {
            self.utilization = utilization
            self.resetsAt = resetsAt
        }
    }

    public var fiveHour: Window?
    public var sevenDay: Window?

    public init(fiveHour: Window?, sevenDay: Window?) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    public enum Parsed: Equatable, Sendable {
        case usage(UsageResponse)
        /// A body without any known key, e.g. `{"error":{"type":"rate_limit_error",...}}` sent with HTTP 200.
        case errorEnvelope(type: String?)
        case invalid
    }

    /// Top-level keys Claude Code itself recognizes (binary constant `pWp`).
    /// A body with none of them is an in-band error envelope.
    public static let knownKeys = [
        "five_hour", "seven_day", "seven_day_oauth_apps", "seven_day_opus", "seven_day_sonnet", "cinder_cove", "extra_usage",
    ]

    public static func parse(_ data: Data) -> Parsed {
        guard let json = try? JSONValue.parse(data), let object = json.object else { return .invalid }
        guard knownKeys.contains(where: { object[$0] != nil }) else {
            return .errorEnvelope(type: json.at("error", "type")?.string)
        }
        return .usage(UsageResponse(fiveHour: window(object["five_hour"]), sevenDay: window(object["seven_day"])))
    }

    /// `{utilization: number|null, resets_at: string|null}` or null. A null utilization means "no such limit".
    static func window(_ value: JSONValue?) -> Window? {
        guard let value, let raw = value["utilization"]?.double, raw.isFinite else { return nil }
        let resets: Date?
        switch value["resets_at"] {
        case .string(let s)?: resets = parseDate(s)
        case .number(let n)?: resets = Date(timeIntervalSince1970: n)   // tolerate epoch seconds
        default: resets = nil
        }
        return Window(utilization: min(max(raw, 0), 100), resetsAt: resets)
    }

    /// ISO-8601 with or without fractional seconds (the server sends 6 digits and `+00:00`).
    /// The fraction is split off by hand: `ISO8601DateFormatter` is unreliable with more than 3 digits.
    public static func parseDate(_ string: String) -> Date? {
        let s = string.trimmingCharacters(in: .whitespaces)
        let pattern = #"^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})(\.\d+)?(Z|z|[+-]\d{2}:?\d{2})?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func group(_ i: Int) -> String? {
            Range(m.range(at: i), in: s).map { String(s[$0]) }
        }
        guard var base = group(1) else { return nil }
        base = base.replacingOccurrences(of: " ", with: "T")
        var zone = group(3) ?? "Z"
        if zone == "z" { zone = "Z" }
        if zone != "Z", !zone.contains(":") { zone.insert(":", at: zone.index(zone.startIndex, offsetBy: 3)) }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let whole = formatter.date(from: base + zone) else { return nil }
        let fraction = group(2).flatMap { Double("0" + $0) } ?? 0
        return whole.addingTimeInterval(fraction)
    }
}
