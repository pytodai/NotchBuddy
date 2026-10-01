import Foundation

// Kimi Code usage: `GET {base}/usages` with Kimi's own access token, read-only.
// NotchBuddy never refreshes that token (a refresh rotates it and can log the user out of Kimi), never writes
// Kimi's files, never logs the token, and only talks to Kimi's two official API hosts.

/// The body of `GET https://api.kimi.com/coding/v1/usages`, in either of its two shapes.
public enum KimiUsageResponse {
    /// Usage is only as fresh as Kimi's own last token; past this age the UI says how old it is.
    public static let staleAfter: TimeInterval = 60 * 60

    /// - Current: `{"usages":{"limit_5h"|"limit_7d"|"limit_month_total":{"used_ratio":0…1,"reset_time":"…"}}}`.
    /// - Legacy: `{"usage":{used,limit,resetTime},"limits":[{"window":{duration,timeUnit},"detail":{…}}]}`,
    ///   numbers often as decimal strings.
    /// nil when nothing usable is in it.
    public static func parse(_ data: Data, fetchedAt: Date) -> AgentUsage? {
        guard let json = try? JSONValue.parse(data), json.object != nil else { return nil }
        var windows: [AgentUsageWindow] = []
        func add(_ w: AgentUsageWindow) {
            if !windows.contains(where: { $0.id == w.id }) { windows.append(w) }
        }

        if let usages = json["usages"], usages.object != nil {
            for (key, minutes) in [("limit_5h", 300), ("limit_7d", 10080), ("limit_month_total", 43200)] {
                guard let entry = usages[key], let ratio = number(entry["used_ratio"]) else { continue }
                add(AgentUsageWindow(id: AgentUsageWindow.id(minutes: minutes), used: percent(ratio: ratio),
                                     resetsAt: resetDate(entry, now: fetchedAt), minutes: minutes))
            }
        }
        if windows.isEmpty {
            for item in json["limits"]?.array ?? [] {
                let duration = number(item.at("window", "duration")) ?? 0
                let unit = item.at("window", "timeUnit")?.string ?? item.at("window", "time_unit")?.string ?? ""
                let scale: Double = ["TIME_UNIT_MINUTE": 1, "TIME_UNIT_HOUR": 60, "TIME_UNIT_DAY": 1440,
                                     "TIME_UNIT_WEEK": 10080][unit] ?? 0
                let minutes = duration * scale
                guard minutes.isFinite, minutes >= 1, minutes < 1e7,
                      let w = legacyWindow(item["detail"], minutes: Int(minutes), now: fetchedAt) else { continue }
                add(w)
            }
            // The summary is the weekly window (the desktop labels it "1 week").
            if let w = legacyWindow(json["usage"], minutes: 10080, now: fetchedAt) { add(w) }
        }
        guard !windows.isEmpty else { return nil }
        return AgentUsage(agent: .kimi, windows: windows, fetchedAt: fetchedAt, staleAfter: staleAfter)
    }

    /// Kimi rounds up (`ceil(ratio * 100)`); a hair of float noise must not turn 42 % into 43 %.
    static func percent(ratio: Double) -> Double {
        let clamped = min(max(ratio, 0), 1)
        return min(max((clamped * 100 - 1e-6).rounded(.up), 0), 100)
    }

    private static func legacyWindow(_ detail: JSONValue?, minutes: Int, now: Date) -> AgentUsageWindow? {
        guard let detail, detail.object != nil, let limit = number(detail["limit"]), limit > 0 else { return nil }
        let used = number(detail["used"]) ?? number(detail["remaining"]).map { limit - $0 } ?? 0
        return AgentUsageWindow(id: AgentUsageWindow.id(minutes: minutes), used: percent(ratio: used / limit),
                                resetsAt: resetDate(detail, now: now), minutes: minutes)
    }

    static func number(_ value: JSONValue?) -> Double? {
        if let d = value?.double, d.isFinite { return d }
        if let s = value?.string?.trimmingCharacters(in: .whitespaces), let d = Double(s), d.isFinite { return d }
        return nil
    }

    private static func resetDate(_ entry: JSONValue, now: Date) -> Date? {
        for key in ["reset_time", "resetTime", "reset_at", "resetAt"] {
            if let s = entry[key]?.string, let d = UsageResponse.parseDate(s) { return d }
            if let n = entry[key]?.double, n.isFinite, n > 1e9 { return Date(timeIntervalSince1970: n) }
        }
        for key in ["reset_in", "resetIn", "ttl"] {
            if let n = number(entry[key]), n >= 0 { return now.addingTimeInterval(n) }
        }
        return nil
    }
}

// MARK: - Kimi's login, read-only

/// Kimi's access token, kept only for one request. Its descriptions never show the value.
public struct KimiAccessToken: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    public let value: String
    public let expiresAt: Date

    public init(value: String, expiresAt: Date) {
        self.value = value
        self.expiresAt = expiresAt
    }

    public var description: String { "KimiAccessToken(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["expiresAt": expiresAt]) }
}

public enum KimiCredentialState: Equatable, Sendable {
    /// No credentials file: never logged in (or another Kimi home).
    case missing
    /// Logged out or revoked (`access_token: ""`).
    case revoked
    /// Valid for less than the minimum: Kimi refreshes it on its next request, not NotchBuddy.
    case expired
    case unreadable
    case fresh(KimiAccessToken)
}

/// Where Kimi Code keeps its login, and which API it talks to.
public struct KimiLocation: Equatable, Sendable {
    public static let defaultBaseURL = URL(string: "https://api.kimi.com/coding/v1")!
    /// The only hosts the token is ever sent to.
    public static let allowedHosts: Set<String> = ["api.kimi.com", "api.kimi.ai"]

    public var home: URL
    public var baseURL: URL
    /// The credentials file's name without `.json` ("kimi-code").
    public var storageName: String

    public init(home: URL, baseURL: URL = KimiLocation.defaultBaseURL, storageName: String = "kimi-code") {
        self.home = home
        self.baseURL = baseURL
        self.storageName = storageName
    }

    public var credentialsFile: URL {
        home.appendingPathComponent("credentials", isDirectory: true).appendingPathComponent("\(storageName).json")
    }

    public var usagesURL: URL { baseURL.appendingPathComponent("usages") }

    /// `KIMI_CODE_HOME` (rarely visible to a launchd app) or `~/.kimi-code`, then its `config.toml`.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               home: URL = Paths.home) -> KimiLocation {
        let kimiHome = environment["KIMI_CODE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".kimi-code", isDirectory: true)
        let config = (try? String(contentsOf: kimiHome.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        let parsed = parseConfig(config)
        return KimiLocation(home: kimiHome, baseURL: parsed.baseURL, storageName: parsed.storageName)
    }

    /// `[providers."managed:kimi-code"] base_url` and `[providers."managed:kimi-code".oauth] key`, tolerant of
    /// anything else in the file. A base URL off Kimi's official hosts is ignored.
    public static func parseConfig(_ text: String) -> (baseURL: URL, storageName: String) {
        var section = ""
        var base: URL?
        var key: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).replacingOccurrences(of: " ", with: "")
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = unquote(line[line.index(after: eq)...])
            switch (section, name) {
            case ("providers.\"managed:kimi-code\"", "base_url"): base = URL(string: value)
            case ("providers.\"managed:kimi-code\".oauth", "key"): key = value
            default: break
            }
        }
        let baseURL = base.flatMap(allowed) ?? defaultBaseURL
        return (baseURL, storageName(forKey: key))
    }

    /// Kimi's `resolveKimiTokenStorageName`: "oauth/kimi-code" and "kimi-code" → "kimi-code", "oauth/<x>" → "<x>".
    public static func storageName(forKey key: String?) -> String {
        guard var name = key?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return "kimi-code" }
        if name.hasPrefix("oauth/") { name.removeFirst("oauth/".count) }
        let safe = name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil && !name.hasPrefix(".")
        return safe ? name : "kimi-code"
    }

    static func allowed(_ url: URL) -> URL? {
        guard url.scheme == "https", let host = url.host, allowedHosts.contains(host.lowercased()),
              url.user == nil, url.password == nil, url.query == nil else { return nil }
        var s = url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    private static func unquote(_ raw: Substring) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let hash = s.range(of: " #") { s = String(s[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
        if s.count >= 2, let first = s.first, first == "\"" || first == "'", s.last == first {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    /// Reads the credentials file (never writes it, never refreshes). Fresh only with at least `minValidity` left.
    public func credentials(now: Date, minValidity: TimeInterval = 60) -> KimiCredentialState {
        let data: Data
        do {
            data = try Data(contentsOf: credentialsFile)
        } catch CocoaError.fileReadNoSuchFile {
            return .missing
        } catch {
            return FileManager.default.fileExists(atPath: credentialsFile.path) ? .unreadable : .missing
        }
        guard let json = try? JSONValue.parse(data), json.object != nil else { return .unreadable }
        guard let token = json["access_token"]?.string, !token.isEmpty else { return .revoked }
        guard let expires = KimiUsageResponse.number(json["expires_at"]), expires > 0 else { return .expired }
        let expiresAt = Date(timeIntervalSince1970: expires)
        guard expiresAt.timeIntervalSince(now) >= minValidity else { return .expired }
        return .fresh(KimiAccessToken(value: token, expiresAt: expiresAt))
    }

    /// The credentials file's modification time (nil when missing): the fetcher reads the file again only after it changes.
    public func credentialsModified(fileManager: FileManager = .default) -> Date? {
        (try? fileManager.attributesOfItem(atPath: credentialsFile.path))?[.modificationDate] as? Date
    }
}

// MARK: - One request's outcome, and when to try again

public enum KimiFetchOutcome: Equatable, Sendable {
    case ok(AgentUsage)
    /// 401/403: the token expired or was revoked. Wait for Kimi to refresh it (the file changes); never retry as is.
    case unauthorized
    /// 404: not a Kimi Code plan. Hide the row until the app restarts.
    case notAvailable
    /// 429 (with the server's Retry-After, seconds).
    case rateLimited(retryAfter: TimeInterval?)
    /// Network error, 5xx, or a body with nothing usable.
    case failed(String)

    /// Maps an HTTP result. Never looks at request headers.
    public static func interpret(status: Int, body: Data, retryAfter: String? = nil, now: Date) -> KimiFetchOutcome {
        switch status {
        case 200:
            return KimiUsageResponse.parse(body, fetchedAt: now).map(KimiFetchOutcome.ok) ?? .failed(LKey("неверный ответ"))
        case 401, 403: return .unauthorized
        case 404: return .notAvailable
        case 429:
            let seconds = retryAfter.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            return .rateLimited(retryAfter: seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
        default: return .failed(L("ошибка сервера (%@)", status))
        }
    }
}

/// When the fetcher may call `/usages` again: at most once per `minInterval`, backing off after failures
/// (5 → 10 → 20 → 40 → 60 min), never again with a token the server refused until Kimi rewrites the credentials
/// file, never again after a 404. The credentials file itself is read again only after it changes, once a read
/// found no usable token (or when that token's time runs out). Monotonic seconds throughout.
public struct KimiFetchPolicy: Equatable, Sendable {
    public static let minInterval: TimeInterval = 5 * 60
    public static let maxBackoff: TimeInterval = 60 * 60
    public static let maxRetryAfter: TimeInterval = 6 * 60 * 60

    public private(set) var nextAttempt: TimeInterval = -.infinity
    public private(set) var failures = 0
    public private(set) var hidden = false
    /// The credentials file's mtime when the server refused its token.
    public private(set) var refusedCredentials: Date??
    /// The mtime of the last read that found no usable token.
    private var unusableCredentials: Date??

    public init() {}

    /// Whether to read the credentials file now (it may hold a new token).
    public func needsCredentials(modified: Date?) -> Bool {
        guard !hidden else { return false }
        if let unusable = unusableCredentials, unusable == modified { return false }
        return true
    }

    /// Records what a read of the credentials file found.
    public mutating func noteCredentials(usable: Bool, modified: Date?) {
        unusableCredentials = usable ? nil : .some(modified)
    }

    /// Forgets that the file held no usable token (the toggle was switched back on): the next poll reads it again.
    public mutating func forgetCredentials() {
        unusableCredentials = nil
    }

    /// Whether a request may go out now with a token from the file as of `modified`.
    public func mayRequest(now: TimeInterval, credentialsModified modified: Date?) -> Bool {
        guard !hidden, now >= nextAttempt else { return false }
        if let refused = refusedCredentials, refused == modified { return false }
        return true
    }

    /// Reserves the slot before the request is sent (callers may overlap).
    public mutating func willRequest(now: TimeInterval) {
        nextAttempt = now + Self.minInterval
    }

    public mutating func record(_ outcome: KimiFetchOutcome, now: TimeInterval, credentialsModified modified: Date?) {
        switch outcome {
        case .ok:
            failures = 0
            refusedCredentials = nil
            nextAttempt = now + Self.minInterval
        case .unauthorized:
            refusedCredentials = .some(modified)
            nextAttempt = now + Self.minInterval
        case .notAvailable:
            hidden = true
        case .rateLimited(let retryAfter):
            failures += 1
            nextAttempt = now + max(backoff, min(retryAfter ?? 0, Self.maxRetryAfter))
        case .failed:
            failures += 1
            nextAttempt = now + backoff
        }
    }

    private var backoff: TimeInterval {
        min(Self.minInterval * pow(2, Double(max(failures - 1, 0))), Self.maxBackoff)
    }
}
