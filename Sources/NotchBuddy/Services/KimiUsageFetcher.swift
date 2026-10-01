import Foundation
import NotchBuddyCore

/// Kimi Code's 5-hour / weekly / monthly usage, opt-in.
///
/// Off by default: it borrows Kimi's own login. While the toggle is on:
/// - `~/.kimi-code/credentials/<name>.json` is read (never written); it is read again only after it changes, once
///   a read found no usable token. Kimi's token lives 15 minutes and Kimi refreshes it only for its own requests,
///   so a fresh one exists exactly while Kimi is in use, which is when its usage moves. NotchBuddy never refreshes it.
/// - `GET https://api.kimi.com/coding/v1/usages` (or Kimi's global host, never any other) goes out at most once per
///   5 minutes, backing off after failures; a refused token waits for Kimi to write a new one; a 404 (no Kimi Code
///   plan) hides the row until the next launch.
/// - The last good numbers are kept in `~/.notchbuddy/run/kimi-usage.json` (0600, numbers only) and shown with their age.
/// The token lives only in a local for the request: it is never logged, stored or put in an error.
@MainActor
final class KimiUsageFetcher {
    /// Same key as the settings page's «Лимиты Kimi» toggle.
    nonisolated static let enabledDefaultsKey = "settings.usage.kimiAPI"

    nonisolated static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledDefaultsKey)
    }

    nonisolated static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledDefaultsKey)
        Log.info("kimi usage: \(enabled ? "enabled" : "disabled") by the user")
    }

    /// What the row shows (nil: hidden, i.e. disabled or not a Kimi Code plan).
    private(set) var usage: AgentUsage?
    var onChange: ((AgentUsage?) -> Void)?

    private let state: KimiUsageFetchState
    private let defaults: UserDefaults
    private let cacheURL: URL
    private var timer: Timer?
    private var running = false
    private var inFlight = false

    static let tick: TimeInterval = 60

    init(location: KimiLocation = .resolve(), clock: AppClock = .system, defaults: UserDefaults = .standard,
         cacheURL: URL = AgentUsageCache.url(for: .kimi)) {
        state = KimiUsageFetchState(location: location, clock: clock, cacheURL: cacheURL)
        self.defaults = defaults
        self.cacheURL = cacheURL
    }

    var isEnabled: Bool { Self.isEnabled(defaults) }

    func start() {
        guard !running else { return }
        running = true
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer?.tolerance = 10
        if isEnabled, let cached = AgentUsageCache.read(from: cacheURL), cached.agent == .kimi {
            publish(cached)
        }
        poll()
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
    }

    /// Kimi just did something (a turn ended), or the usage is being looked at: try now if the policy allows.
    func nudge() {
        poll()
    }

    /// The toggle changed: fetch at once when turned on, hide the row when off.
    func enabledChanged() {
        if isEnabled {
            if usage == nil, let cached = AgentUsageCache.read(from: cacheURL) { publish(cached) }
            Task {
                await state.reset()
                poll()
            }
        } else {
            publish(nil)
        }
    }

    private func poll() {
        guard running, !inFlight else { return }
        guard isEnabled else {
            if usage != nil { publish(nil) }
            return
        }
        inFlight = true
        Task {
            let result = await state.poll(stillEnabled: { @MainActor [weak self] in self?.isEnabled ?? false })
            inFlight = false
            switch result {
            case .unchanged: break
            case .show(let usage): publish(usage)
            case .hide: publish(nil)
            }
        }
    }

    private func publish(_ new: AgentUsage?) {
        guard new != usage else { return }
        usage = new
        onChange?(new)
    }
}

/// The fetcher's state, serialized (an attempt reserves its slot before it suspends).
actor KimiUsageFetchState {
    enum Result: Equatable {
        case unchanged
        case show(AgentUsage)
        case hide
    }

    private let location: KimiLocation
    private let clock: AppClock
    private let cacheURL: URL
    private var policy = KimiFetchPolicy()
    private var lastGood: AgentUsage?
    private var lastNote: String?

    init(location: KimiLocation, clock: AppClock, cacheURL: URL) {
        self.location = location
        self.clock = clock
        self.cacheURL = cacheURL
        lastGood = AgentUsageCache.read(from: cacheURL)
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    func poll(stillEnabled: @Sendable @MainActor () -> Bool) async -> Result {
        guard !policy.hidden else { return .hide }
        let modified = location.credentialsModified()
        guard policy.needsCredentials(modified: modified) else { return .unchanged }
        let now = clock.now()
        let token: KimiAccessToken
        switch location.credentials(now: now.wall) {
        case .fresh(let fresh):
            policy.noteCredentials(usable: true, modified: modified)
            token = fresh
        case .missing:
            policy.noteCredentials(usable: false, modified: modified)
            return note(LKey("нет входа в Kimi Code"))
        case .revoked:
            policy.noteCredentials(usable: false, modified: modified)
            return note(LKey("войдите в Kimi Code заново"))
        case .expired:
            policy.noteCredentials(usable: false, modified: modified)
            return note(LKey("откройте Kimi Code, чтобы обновить"))
        case .unreadable:
            policy.noteCredentials(usable: false, modified: modified)
            return note(LKey("не удалось прочитать вход Kimi"))
        }
        guard policy.mayRequest(now: now.monotonic, credentialsModified: modified) else { return .unchanged }
        policy.willRequest(now: now.monotonic)

        let outcome = await Self.request(location.usagesURL, token: token, now: now.wall)
        // The toggle may have been switched off while the request was out.
        guard await stillEnabled() else { return .hide }
        policy.record(outcome, now: clock.now().monotonic, credentialsModified: modified)
        switch outcome {
        case .ok(let usage):
            lastGood = usage
            lastNote = nil
            do {
                try AgentUsageCache.write(usage, to: cacheURL)
            } catch {
                Log.error("kimi usage: cannot write the cache: \(error.localizedDescription)")
            }
            Log.info("kimi usage: fetched (\(usage.windows.map { "\($0.id) \(Int($0.used))%" }.joined(separator: ", ")))")
            return .show(usage)
        case .unauthorized:
            Log.info("kimi usage: token refused; waiting for Kimi to refresh it")
            return note(LKey("откройте Kimi Code, чтобы обновить"))
        case .notAvailable:
            Log.info("kimi usage: /usages not available for this account; hidden until restart")
            return .hide
        case .rateLimited:
            Log.info("kimi usage: rate limited; next attempt in \(Int((policy.nextAttempt - clock.now().monotonic) / 60)) min")
            return note(LKey("лимит запросов, попробую позже"))
        case .failed(let reason):
            Log.info("kimi usage: \(reason); next attempt in \(Int((policy.nextAttempt - clock.now().monotonic) / 60)) min")
            return note(LKey("не удалось получить лимиты"))
        }
    }

    /// Shown again from scratch (the row was hidden): the note is re-sent and the credentials file re-read.
    func reset() {
        lastNote = nil
        policy.forgetCredentials()
    }

    /// With numbers already known, a problem only shows as their age; without any, as the row's note.
    private func note(_ text: String) -> Result {
        if let lastGood { return .show(lastGood) }
        guard text != lastNote else { return .unchanged }
        lastNote = text
        return .show(.unavailable(.kimi, text))
    }

    private static func request(_ url: URL, token: KimiAccessToken, now: Date) async -> KimiFetchOutcome {
        // `usagesURL` is built from an allow-listed base; checked again right before the token leaves.
        guard url.scheme == "https", let host = url.host?.lowercased(), KimiLocation.allowedHosts.contains(host) else {
            return .failed(LKey("неверный адрес"))
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NotchBuddy/0.1", forHTTPHeaderField: "User-Agent")
        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed(LKey("неверный ответ")) }
            return KimiFetchOutcome.interpret(status: http.statusCode, body: body,
                                              retryAfter: http.value(forHTTPHeaderField: "Retry-After"), now: now)
        } catch {
            return .failed(LKey("ошибка сети"))
        }
    }
}
