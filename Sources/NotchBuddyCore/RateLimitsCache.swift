import Foundation

/// Claude subscription usage as seen by Claude Code's statusLine (`rate_limits` in its stdin JSON).
/// Written atomically by `notchbuddy-bridge statusline`, read by the app.
public struct RateLimitsCache: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        /// 0...100
        public var usedPercentage: Double
        public var resetsAt: Date?
        public init(usedPercentage: Double, resetsAt: Date?) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }
    }

    public var fiveHour: Window?
    public var sevenDay: Window?
    /// When the statusLine produced this snapshot.
    public var capturedAt: Date

    public init(fiveHour: Window?, sevenDay: Window?, capturedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.capturedAt = capturedAt
    }

    /// Parses the `rate_limits` object of a statusLine payload:
    /// `{"five_hour":{"used_percentage":12.5,"resets_at":1759150000}, "seven_day":{...}}` (resets_at = epoch seconds).
    public static func fromStatusLine(_ payload: JSONValue, now: Date = Date()) -> RateLimitsCache? {
        guard let rl = payload["rate_limits"], rl.object != nil else { return nil }
        func window(_ key: String) -> Window? {
            guard let w = rl[key], let used = w["used_percentage"]?.double else { return nil }
            let resets = w["resets_at"]?.double.map { Date(timeIntervalSince1970: $0) }
            return Window(usedPercentage: used, resetsAt: resets)
        }
        let five = window("five_hour"), seven = window("seven_day")
        guard five != nil || seven != nil else { return nil }
        return RateLimitsCache(fiveHour: five, sevenDay: seven, capturedAt: now)
    }

    public func write(to url: URL = Paths.rateLimitsCache) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Wire.encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL = Paths.rateLimitsCache) -> RateLimitsCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Wire.decoder.decode(RateLimitsCache.self, from: data)
    }
}

/// How old the statusLine cache is, judged without trusting the wall clock across a jump.
///
/// `capturedAt` is the bridge's wall-clock stamp, so the app measures a snapshot's age on its own monotonic
/// clock from the read that first found it. The age at that read comes from the wall clock, bounded by what
/// the app itself saw: never negative, and when an earlier read found something else, no more than the time
/// since that read (the file was written in between). A snapshot that is already there on the first read and
/// is stamped more than `futureSkew` ahead of the wall clock has an unknown age: after the clock is set back
/// it would otherwise pass for fresh until the clock caught up, hours later.
public struct RateLimitsFreshness: Equatable, Sendable {
    /// Clock skew between the bridge's and the app's reads of the same wall clock that is still plausible.
    public static let futureSkew: TimeInterval = 60

    private struct Sighting: Equatable, Sendable {
        var capturedAt: Date
        var firstRead: Moment
        /// Age at `firstRead`; nil when unknown.
        var ageThen: TimeInterval?
    }

    private var lastRead: Moment?
    private var current: Sighting?

    public init() {}

    /// Records one read of the cache file (`nil`: missing or unreadable) at `now`, and returns the snapshot's
    /// age in seconds, or nil when it is unknown (treat as stale).
    public mutating func observe(_ cache: RateLimitsCache?, now: Moment) -> TimeInterval? {
        defer { lastRead = now }
        guard let cache else {
            current = nil
            return nil
        }
        if let seen = current, seen.capturedAt == cache.capturedAt {
            return seen.ageThen.map { $0 + max(now.since(seen.firstRead), 0) }
        }
        let wallAge = now.wall.timeIntervalSince(cache.capturedAt)
        let ageThen: TimeInterval?
        if let lastRead {
            // Written since the previous read, which found no file or another snapshot.
            let bound = max(now.since(lastRead), 0)
            ageThen = wallAge.isFinite ? min(max(wallAge, 0), bound) : bound
        } else if wallAge.isFinite, wallAge >= -Self.futureSkew {
            ageThen = max(wallAge, 0)
        } else {
            ageThen = nil
        }
        current = Sighting(capturedAt: cache.capturedAt, firstRead: now, ageThen: ageThen)
        return ageThen
    }
}
