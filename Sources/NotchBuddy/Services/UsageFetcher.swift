import Foundation
import NotchBuddyCore

/// Claude 5-hour / 7-day usage.
///
/// 1. The statusLine cache written by `notchbuddy-bridge statusline`, when it is fresh (no secrets, no network).
/// 2. Otherwise `GET /api/oauth/usage` with Claude Code's OAuth token, read-only and never refreshed,
///    at most once per 5 min, with exponential backoff on errors and 429s. Without a usable login (none, expired,
///    unreadable) the keychain is read again only after 15–30 min, or after 5 min once Claude is in use or the
///    usage is being looked at (`nudge`). Only while the menu toggle
///    «Лимиты Claude через API» is on; off, the keychain is never read and nothing goes to the network.
/// The last good snapshot is kept and returned while later attempts fail.
/// Throttling, backoff and cache age run on the monotonic clock: setting the wall clock back must not stop
/// fetches for hours, nor make a cache written before the jump look fresh.
final class UsageFetcher: UsageProviding {
    /// Menu toggle «Лимиты Claude через API» (default on).
    static let networkEnabledDefaultsKey = "usageNetworkEnabled"
    /// The earlier `defaults write` opt-out; still honoured while the toggle was never touched.
    static let legacyNetworkDisabledDefaultsKey = "usageNetworkDisabled"

    private let state: UsageFetchState

    init(clock: AppClock = .system) {
        state = UsageFetchState(clock: clock)
    }

    func fetch() async -> UsageState {
        await state.fetch()
    }

    func nudge() async {
        await state.nudge()
    }

    /// Path 2 (keychain token + network) allowed?
    static func isNetworkEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        if let enabled = defaults.object(forKey: networkEnabledDefaultsKey) as? Bool { return enabled }
        return !defaults.bool(forKey: legacyNetworkDisabledDefaultsKey)
    }

    static func setNetworkEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: networkEnabledDefaultsKey)
        Log.info("usage: API path \(enabled ? "enabled" : "disabled") by the user")
    }
}

/// All mutable state lives here, so overlapping `fetch()` calls can't double-request.
actor UsageFetchState {
    static let cacheFreshness: TimeInterval = 15 * 60
    static let minInterval: TimeInterval = 5 * 60
    static let maxBackoff: TimeInterval = 30 * 60
    static let maxRetryAfter: TimeInterval = 6 * 60 * 60
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let userAgent = "NotchBuddy/0.1"

    private let clock: AppClock
    /// The newest snapshot and when it was obtained (monotonic seconds; -∞ when unknown).
    private var lastGood: (snapshot: UsageSnapshot, obtained: TimeInterval)?
    private var lastReason = LKey("нет данных")
    /// Monotonic seconds before which the network is not tried again.
    private var nextAttempt = -TimeInterval.infinity
    /// Monotonic seconds of the last attempt (keychain read, then maybe the network).
    private var lastAttempt = -TimeInterval.infinity
    /// `nextAttempt` is a no-login pause (longer than `minInterval`) that `nudge` may shorten.
    private var skipPause = false
    private var consecutiveFailures = 0
    private var cacheAge = RateLimitsFreshness()

    init(clock: AppClock) {
        self.clock = clock
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    func fetch() async -> UsageState {
        let now = clock.now()
        let cache = RateLimitsCache.read()
        let age = cacheAge.observe(cache, now: now)
        let cached = cache.map(Self.snapshot(from:))
        // Obtained this long ago by the app's own clock (unknown age: older than anything else).
        let cachedObtained = age.map { now.monotonic - $0 } ?? -.infinity
        if let cached, let age, age <= Self.cacheFreshness {
            remember(cached, obtained: cachedObtained)
            return .loaded(cached.rolledOver(at: now.wall))
        }

        let networkEnabled = UsageFetcher.isNetworkEnabled()
        if now.monotonic >= nextAttempt, networkEnabled {
            // Reserve the slot before suspending: the actor is re-entrant across `await`.
            nextAttempt = now.monotonic + Self.minInterval
            lastAttempt = now.monotonic
            skipPause = false
            apply(await requestUsage())
        }

        if let cached { remember(cached, obtained: cachedObtained) }
        if let lastGood { return .loaded(lastGood.snapshot.rolledOver(at: clock.now().wall)) }
        return .unavailable(networkEnabled ? lastReason : Self.networkOffReason)
    }

    static let networkOffReason = LKey("нет данных (API выключен)")
    /// Pauses without a usable login: nothing will change until the user signs in (or Claude Code refreshes
    /// the token), and each attempt spawns `/usr/bin/security`.
    static let noLoginPause: TimeInterval = 30 * 60
    static let badLoginPause: TimeInterval = 15 * 60

    /// Claude is in use or the usage is being looked at: a no-login pause shrinks back to `minInterval` after
    /// the last attempt (never shorter, so a stream of nudges cannot spawn the keychain tool any faster).
    func nudge() {
        guard skipPause else { return }
        skipPause = false
        nextAttempt = min(nextAttempt, lastAttempt + Self.minInterval)
    }

    // MARK: Outcomes

    private enum Outcome {
        case success(UsageSnapshot)
        /// No request was sent (no login, expired token…). Retried after `pause` (see `nudge`).
        case skipped(String, pause: TimeInterval = UsageFetchState.minInterval)
        /// The request failed. `backoff` escalates the delay; `retryAfter` comes from the server.
        case failed(String, backoff: Bool, retryAfter: TimeInterval? = nil, fixedDelay: TimeInterval? = nil)
    }

    private func apply(_ outcome: Outcome) {
        let now = clock.now()
        switch outcome {
        case .success(let snapshot):
            consecutiveFailures = 0
            remember(snapshot, obtained: now.monotonic)
            Log.info("usage: fetched (5h \(Self.percent(snapshot.fiveHour)), 7d \(Self.percent(snapshot.sevenDay)))")
        case .skipped(let reason, let pause):
            lastReason = reason
            nextAttempt = now.monotonic + pause
            skipPause = pause > Self.minInterval
            Log.debug("usage: network skipped: \(reason); next attempt in \(Int(pause / 60)) min")
        case .failed(let reason, let backoff, let retryAfter, let fixedDelay):
            lastReason = reason
            var delay = fixedDelay ?? Self.minInterval
            if backoff {
                consecutiveFailures += 1
                delay = min(Self.minInterval * pow(2, Double(consecutiveFailures - 1)), Self.maxBackoff)
            }
            if let retryAfter, retryAfter > 0 { delay = max(delay, min(retryAfter, Self.maxRetryAfter)) }
            nextAttempt = now.monotonic + delay
            Log.info("usage: \(reason); next attempt in \(Int(delay / 60)) min")
        }
    }

    /// Keeps the newest snapshot by when the app obtained it, not by its wall-clock stamp (which may predate a jump).
    private func remember(_ snapshot: UsageSnapshot, obtained: TimeInterval) {
        if lastGood.map({ obtained >= $0.obtained }) ?? true { lastGood = (snapshot, obtained) }
    }

    // MARK: Network

    private func requestUsage() async -> Outcome {
        let credentials: ClaudeCredentials
        switch await ClaudeCredentials.load() {
        case .success(let c): credentials = c
        case .failure(.notFound), .failure(.noOAuthLogin): return .skipped(LKey("нет входа в Claude"), pause: Self.noLoginPause)
        case .failure(.expired): return .skipped(LKey("токен Claude истёк"), pause: Self.badLoginPause)
        case .failure(.missingScope): return .skipped(LKey("токен без доступа к лимитам"), pause: Self.noLoginPause)
        case .failure(.unreadable), .failure(.timedOut):
            return .skipped(LKey("не удалось прочитать вход Claude"), pause: Self.badLoginPause)
        case .failure(.disabled): return .skipped(Self.networkOffReason)
        }
        // The toggle may have been switched off while the keychain was being read.
        guard UsageFetcher.isNetworkEnabled() else { return .skipped(Self.networkOffReason) }

        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: HTTPURLResponse
        do {
            let (body, raw) = try await session.data(for: request)
            guard let http = raw as? HTTPURLResponse else { return .failed(LKey("неверный ответ"), backoff: true) }
            data = body
            response = http
        } catch {
            return .failed(LKey("ошибка сети"), backoff: true)
        }
        // A Retry-After date is on the server's clock: measured against the response's own Date header, a local
        // clock set hours back does not turn it into a six-hour pause.
        let now = clock.now().wall
        let serverNow = Self.parseHTTPDate(response.value(forHTTPHeaderField: "Date")) ?? now
        return Self.interpret(status: response.statusCode, body: data,
                              retryAfter: response.value(forHTTPHeaderField: "Retry-After"), now: now, serverNow: serverNow)
    }

    /// Maps an HTTP result onto an outcome. Never inspects or logs the request headers.
    private static func interpret(status: Int, body: Data, retryAfter: String?, now: Date, serverNow: Date) -> Outcome {
        let retry = parseRetryAfter(retryAfter, now: serverNow)
        switch status {
        case 200:
            switch UsageResponse.parse(body) {
            case .usage(let u):
                return .success(UsageSnapshot(fiveHour: u.fiveHour.map(window), sevenDay: u.sevenDay.map(window), fetchedAt: now))
            case .errorEnvelope(let type):
                return type == "rate_limit_error"
                    ? .failed(LKey("лимит запросов"), backoff: true, retryAfter: retry)
                    : .failed(LKey("ошибка сервера"), backoff: true)
            case .invalid:
                return .failed(LKey("неверный ответ"), backoff: true)
            }
        case 401:
            // Claude Code refreshes the token on its next API call; just re-read it later.
            return .failed(LKey("токен Claude устарел"), backoff: false, fixedDelay: 10 * 60)
        case 403:
            if String(decoding: body.prefix(4096), as: UTF8.self).localizedCaseInsensitiveContains("revoked") {
                return .failed(LKey("вход в Claude отозван"), backoff: false, fixedDelay: maxBackoff)
            }
            return .failed(LKey("доступ запрещён"), backoff: true)   // e.g. a Cloudflare challenge
        case 429:
            return .failed(LKey("лимит запросов"), backoff: true, retryAfter: retry)
        default:
            return .failed(L("ошибка сервера (%@)", status), backoff: true, retryAfter: retry)
        }
    }

    /// Seconds or an HTTP date. `0` (common here) means "no hint".
    static func parseRetryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return seconds.isFinite && seconds > 0 ? seconds : nil }
        guard let date = parseHTTPDate(value) else { return nil }
        let delta = date.timeIntervalSince(now)
        return delta > 0 ? delta : nil
    }

    /// An IMF-fixdate ("Tue, 29 Sep 2026 19:49:00 GMT").
    static func parseHTTPDate(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }

    // MARK: Mapping

    private static func window(_ w: UsageResponse.Window) -> UsageWindow {
        UsageWindow(utilization: w.utilization, resetsAt: w.resetsAt)
    }

    static func snapshot(from cache: RateLimitsCache) -> UsageSnapshot {
        func window(_ w: RateLimitsCache.Window?) -> UsageWindow? {
            w.map { UsageWindow(utilization: min(max($0.usedPercentage, 0), 100), resetsAt: $0.resetsAt) }
        }
        return UsageSnapshot(fiveHour: window(cache.fiveHour), sevenDay: window(cache.sevenDay), fetchedAt: cache.capturedAt)
    }

    private static func percent(_ w: UsageWindow?) -> String {
        w.map { IslandFormat.percent($0.utilization) } ?? "—"
    }
}

private extension UsageSnapshot {
    /// A window whose reset time has passed no longer has its old usage: show it as fresh.
    func rolledOver(at now: Date) -> UsageSnapshot {
        func roll(_ w: UsageWindow?) -> UsageWindow? {
            guard let w, let resets = w.resetsAt, now >= resets else { return w }
            return UsageWindow(utilization: 0, resetsAt: nil)
        }
        return UsageSnapshot(fiveHour: roll(fiveHour), sevenDay: roll(sevenDay), fetchedAt: fetchedAt)
    }
}
