import XCTest
@testable import NotchBuddyCore

final class UsageKimiTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nb-kimi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Response

    func testParsesCurrentShape() throws {
        let body = #"""
        {"usages":{"limit_5h":{"used_ratio":0.42,"reset_time":"2026-09-30T18:00:00Z"},
                   "limit_7d":{"used_ratio":"0.13","reset_time":"2026-10-03T00:00:00.123456+00:00"},
                   "limit_month_total":{"used_ratio":0.2},
                   "limit_month_code":{"used_ratio":0.15},
                   "limit_bogus":{"used_ratio":0.9}},
         "boosterWallet":{"balance":{"type":"BOOSTER","amount":"1","amountLeft":"1"}}}
        """#
        let usage = try XCTUnwrap(KimiUsageResponse.parse(Data(body.utf8), fetchedAt: now))
        XCTAssertEqual(usage.agent, .kimi)
        XCTAssertEqual(usage.windows.map(\.id), ["5h", "7d", "month"])
        XCTAssertEqual(usage.windows.map(\.used), [42, 13, 20], "ceil without float noise")
        XCTAssertEqual(usage.window("5h")?.resetsAt, UsageResponse.parseDate("2026-09-30T18:00:00Z"))
        XCTAssertNil(usage.window("month")?.resetsAt)
        XCTAssertEqual(usage.fetchedAt, now)
        XCTAssertEqual(usage.staleAfter, KimiUsageResponse.staleAfter)
    }

    func testRoundsUpLikeKimiAndClamps() {
        XCTAssertEqual(KimiUsageResponse.percent(ratio: 0.001), 1)
        XCTAssertEqual(KimiUsageResponse.percent(ratio: 0.421), 43)
        XCTAssertEqual(KimiUsageResponse.percent(ratio: 0.57), 57)
        XCTAssertEqual(KimiUsageResponse.percent(ratio: 1.7), 100)
        XCTAssertEqual(KimiUsageResponse.percent(ratio: -1), 0)
    }

    func testParsesLegacyShape() throws {
        let body = #"""
        {"usage":{"used":"40","limit":"1000","resetTime":"2026-08-03T05:20:51Z"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"used":"1","limit":"100","resetTime":"2026-08-01T05:20:51Z"}},
                   {"window":{"duration":1,"timeUnit":"TIME_UNIT_DAY"},"detail":{"remaining":"30","limit":"40","reset_in":120}},
                   {"window":{"duration":5,"timeUnit":"TIME_UNIT_EON"},"detail":{"used":"1","limit":"2"}},
                   {"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"used":"1","limit":"0"}}]}
        """#
        let usage = try XCTUnwrap(KimiUsageResponse.parse(Data(body.utf8), fetchedAt: now))
        XCTAssertEqual(usage.windows.map(\.id), ["5h", "7d", "1440min"])
        XCTAssertEqual(usage.window("5h")?.used, 1)
        XCTAssertEqual(usage.window("7d")?.used, 4)
        XCTAssertEqual(usage.window("1440min")?.used, 25)
        XCTAssertEqual(usage.window("1440min")?.resetsAt, now.addingTimeInterval(120))
        XCTAssertEqual(usage.window("1440min")?.label, "1\u{00A0}дн")
    }

    func testRejectsBodiesWithNothingUsable() {
        XCTAssertNil(KimiUsageResponse.parse(Data("[]".utf8), fetchedAt: now))
        XCTAssertNil(KimiUsageResponse.parse(Data("not json".utf8), fetchedAt: now))
        XCTAssertNil(KimiUsageResponse.parse(Data(#"{"usages":{}}"#.utf8), fetchedAt: now))
        XCTAssertNil(KimiUsageResponse.parse(Data(#"{"usages":{"limit_5h":{"reset_time":"x"}}}"#.utf8), fetchedAt: now))
    }

    // MARK: Credentials

    private func location() -> KimiLocation { KimiLocation(home: dir) }

    private func writeCredentials(_ json: String) throws {
        let url = location().credentialsFile
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    func testCredentialStates() throws {
        XCTAssertEqual(location().credentials(now: now), .missing)
        XCTAssertNil(location().credentialsModified())

        try writeCredentials(#"{"access_token":"","refresh_token":"","expires_at":0}"#)
        XCTAssertEqual(location().credentials(now: now), .revoked)
        XCTAssertNotNil(location().credentialsModified())

        try writeCredentials(#"{"access_token":"t0k","expires_at":\#(now.timeIntervalSince1970 - 5),"expires_in":900}"#)
        XCTAssertEqual(location().credentials(now: now), .expired)
        try writeCredentials(#"{"access_token":"t0k","expires_at":\#(now.timeIntervalSince1970 + 30)}"#)
        XCTAssertEqual(location().credentials(now: now), .expired, "under a minute left")

        try writeCredentials(#"{"access_token":"t0k","expires_at":\#(now.timeIntervalSince1970 + 600)}"#)
        guard case .fresh(let token) = location().credentials(now: now) else { return XCTFail("expected a fresh token") }
        XCTAssertEqual(token.value, "t0k")
        XCTAssertEqual(token.expiresAt, now.addingTimeInterval(600))

        try writeCredentials("{oops")
        XCTAssertEqual(location().credentials(now: now), .unreadable)
    }

    func testTokenNeverPrints() {
        let token = KimiAccessToken(value: "secret-value", expiresAt: now)
        XCTAssertFalse("\(token)".contains("secret"))
        XCTAssertFalse(String(reflecting: token).contains("secret"))
        var dumped = ""
        dump(token, to: &dumped)
        XCTAssertFalse(dumped.contains("secret"))
        XCTAssertFalse("\(KimiCredentialState.fresh(token))".contains("secret"))
    }

    func testConfigResolution() {
        let config = """
        default_model = "kimi"
        [providers."managed:kimi-code"]
        type = "kimi"
        base_url = "https://api.kimi.ai/coding/v1/"   # global
        [providers."managed:kimi-code".oauth]
        storage = "file"
        key = "oauth/kimi-code-env-0123456789abcdef"
        [providers.other]
        base_url = "https://evil.example/v1"
        """
        let parsed = KimiLocation.parseConfig(config)
        XCTAssertEqual(parsed.baseURL.absoluteString, "https://api.kimi.ai/coding/v1")
        XCTAssertEqual(parsed.storageName, "kimi-code-env-0123456789abcdef")

        let hostile = KimiLocation.parseConfig("""
        [providers."managed:kimi-code"]
        base_url = "https://evil.example/coding/v1"
        [providers."managed:kimi-code".oauth]
        key = "oauth/../../.ssh/id"
        """)
        XCTAssertEqual(hostile.baseURL, KimiLocation.defaultBaseURL)
        XCTAssertEqual(hostile.storageName, "kimi-code")
        XCTAssertEqual(KimiLocation.parseConfig("").baseURL, KimiLocation.defaultBaseURL)
        XCTAssertNil(KimiLocation.allowed(URL(string: "http://api.kimi.com/coding/v1")!))
        XCTAssertNil(KimiLocation.allowed(URL(string: "https://u:p@api.kimi.com/coding/v1")!))

        XCTAssertEqual(KimiLocation.storageName(forKey: "kimi-code"), "kimi-code")
        XCTAssertEqual(KimiLocation.storageName(forKey: "oauth/kimi-code"), "kimi-code")
        XCTAssertEqual(KimiLocation.storageName(forKey: nil), "kimi-code")
        XCTAssertEqual(KimiLocation(home: dir).usagesURL.absoluteString, "https://api.kimi.com/coding/v1/usages")
    }

    func testResolveReadsKimiHome() throws {
        let home = dir.appendingPathComponent("user")
        let kimi = home.appendingPathComponent(".kimi-code")
        try FileManager.default.createDirectory(at: kimi, withIntermediateDirectories: true)
        try Data("[providers.\"managed:kimi-code\"]\nbase_url = \"https://api.kimi.com/coding/v1\"\n".utf8)
            .write(to: kimi.appendingPathComponent("config.toml"))
        let resolved = KimiLocation.resolve(environment: [:], home: home)
        XCTAssertEqual(resolved.home.standardizedFileURL.path, kimi.standardizedFileURL.path)
        XCTAssertEqual(resolved.credentialsFile.lastPathComponent, "kimi-code.json")
        XCTAssertEqual(KimiLocation.resolve(environment: ["KIMI_CODE_HOME": "/x/k"], home: home).home.path, "/x/k")
    }

    // MARK: HTTP and scheduling

    func testInterpretsHTTPResults() {
        let ok = KimiFetchOutcome.interpret(status: 200, body: Data(#"{"usages":{"limit_5h":{"used_ratio":0.5}}}"#.utf8), now: now)
        guard case .ok(let usage) = ok else { return XCTFail("expected ok") }
        XCTAssertEqual(usage.window("5h")?.used, 50)
        XCTAssertEqual(KimiFetchOutcome.interpret(status: 200, body: Data("{}".utf8), now: now), .failed("неверный ответ"))
        XCTAssertEqual(KimiFetchOutcome.interpret(status: 401, body: Data(), now: now), .unauthorized)
        XCTAssertEqual(KimiFetchOutcome.interpret(status: 403, body: Data(), now: now), .unauthorized)
        XCTAssertEqual(KimiFetchOutcome.interpret(status: 404, body: Data(), now: now), .notAvailable)
        XCTAssertEqual(KimiFetchOutcome.interpret(status: 429, body: Data(), retryAfter: "120", now: now),
                       .rateLimited(retryAfter: 120))
        XCTAssertEqual(KimiFetchOutcome.interpret(status: 429, body: Data(), retryAfter: "soon", now: now),
                       .rateLimited(retryAfter: nil))
        XCTAssertEqual(KimiFetchOutcome.interpret(status: 502, body: Data(), now: now), .failed("ошибка сервера (502)"))
    }

    func testPolicyThrottlesAndBacksOff() {
        var policy = KimiFetchPolicy()
        let stamp = Date(timeIntervalSince1970: 1)
        XCTAssertTrue(policy.mayRequest(now: 0, credentialsModified: stamp))
        policy.willRequest(now: 0)
        XCTAssertFalse(policy.mayRequest(now: 60, credentialsModified: stamp), "at most once per 5 min")
        policy.record(.ok(.unavailable(.kimi, "")), now: 1, credentialsModified: stamp)
        XCTAssertFalse(policy.mayRequest(now: 300, credentialsModified: stamp))
        XCTAssertTrue(policy.mayRequest(now: 301, credentialsModified: stamp))

        var t: TimeInterval = 1000
        var delays: [TimeInterval] = []
        for _ in 0..<6 {
            policy.willRequest(now: t)
            policy.record(.failed("x"), now: t, credentialsModified: stamp)
            delays.append(policy.nextAttempt - t)
            t = policy.nextAttempt
        }
        XCTAssertEqual(delays, [300, 600, 1200, 2400, 3600, 3600])
        policy.record(.rateLimited(retryAfter: 99_999), now: t, credentialsModified: stamp)
        XCTAssertEqual(policy.nextAttempt - t, KimiFetchPolicy.maxRetryAfter)
        policy.record(.ok(.unavailable(.kimi, "")), now: t, credentialsModified: stamp)
        XCTAssertEqual(policy.failures, 0)
    }

    func testPolicyWaitsForKimiAfterARefusedToken() {
        var policy = KimiFetchPolicy()
        let first = Date(timeIntervalSince1970: 1), second = Date(timeIntervalSince1970: 2)
        policy.willRequest(now: 0)
        policy.record(.unauthorized, now: 0, credentialsModified: first)
        XCTAssertFalse(policy.mayRequest(now: 10_000, credentialsModified: first), "same token: never again")
        XCTAssertTrue(policy.mayRequest(now: 10_000, credentialsModified: second), "Kimi rewrote the file")

        policy.record(.notAvailable, now: 10_000, credentialsModified: second)
        XCTAssertTrue(policy.hidden)
        XCTAssertFalse(policy.mayRequest(now: 1e9, credentialsModified: Date()))
        XCTAssertFalse(policy.needsCredentials(modified: Date()))
    }

    func testPolicyReadsCredentialsAgainOnlyAfterTheyChange() {
        var policy = KimiFetchPolicy()
        let first = Date(timeIntervalSince1970: 1)
        XCTAssertTrue(policy.needsCredentials(modified: nil))
        policy.noteCredentials(usable: false, modified: nil)
        XCTAssertFalse(policy.needsCredentials(modified: nil), "still no file")
        XCTAssertTrue(policy.needsCredentials(modified: first), "file appeared")
        policy.noteCredentials(usable: false, modified: first)
        XCTAssertFalse(policy.needsCredentials(modified: first))
        policy.noteCredentials(usable: true, modified: first)
        XCTAssertTrue(policy.needsCredentials(modified: first), "a usable token is read each time (it may expire)")
        policy.noteCredentials(usable: false, modified: first)
        policy.forgetCredentials()
        XCTAssertTrue(policy.needsCredentials(modified: first), "toggled back on")
    }
}
