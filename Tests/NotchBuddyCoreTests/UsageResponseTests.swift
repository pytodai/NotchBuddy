import XCTest
@testable import NotchBuddyCore

/// Body shapes of the usage endpoint. No network involved.
final class UsageResponseTests: XCTestCase {
    private func parse(_ json: String) -> UsageResponse.Parsed {
        UsageResponse.parse(Data(json.utf8))
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    func testFullBody() {
        let body = """
        {
          "five_hour":            { "utilization": 33.0, "resets_at": "2026-04-11T07:00:00.528743+00:00" },
          "seven_day":            { "utilization": 13.0, "resets_at": "2026-04-17T00:59:59.951713+00:00" },
          "seven_day_oauth_apps": null,
          "seven_day_opus":       null,
          "seven_day_sonnet":     { "utilization": 1.0,  "resets_at": "2026-04-16T03:00:00.951719+00:00" },
          "extra_usage":          { "is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null, "currency": null },
          "cinder_cove":          null
        }
        """
        guard case .usage(let u) = parse(body) else { return XCTFail("expected usage") }
        XCTAssertEqual(u.fiveHour?.utilization, 33)
        XCTAssertEqual(u.sevenDay?.utilization, 13)
        XCTAssertEqual(u.fiveHour!.resetsAt!.timeIntervalSince1970,
                       date("2026-04-11T07:00:00Z").timeIntervalSince1970 + 0.528743, accuracy: 0.0001)
        XCTAssertEqual(u.sevenDay!.resetsAt!.timeIntervalSince1970,
                       date("2026-04-17T00:59:59Z").timeIntervalSince1970 + 0.951713, accuracy: 0.0001)
    }

    func testNullWindowsAndNullUtilization() {
        let body = #"{"five_hour":null,"seven_day":{"utilization":null,"resets_at":null}}"#
        XCTAssertEqual(parse(body), .usage(UsageResponse(fiveHour: nil, sevenDay: nil)))
    }

    func testMissingResetsAtAndIntegerUtilization() {
        let body = #"{"five_hour":{"utilization":7},"unknown_future_key":{"x":1}}"#
        XCTAssertEqual(parse(body), .usage(UsageResponse(fiveHour: .init(utilization: 7, resetsAt: nil), sevenDay: nil)))
    }

    func testUtilizationIsClamped() {
        let body = #"{"five_hour":{"utilization":130.5,"resets_at":null},"seven_day":{"utilization":-2,"resets_at":null}}"#
        guard case .usage(let u) = parse(body) else { return XCTFail("expected usage") }
        XCTAssertEqual(u.fiveHour?.utilization, 100)
        XCTAssertEqual(u.sevenDay?.utilization, 0)
    }

    func testInBandErrorEnvelope() {
        let body = #"{"error":{"message":"Rate limited. Please try again later.","type":"rate_limit_error"}}"#
        XCTAssertEqual(parse(body), .errorEnvelope(type: "rate_limit_error"))
        XCTAssertEqual(parse("{}"), .errorEnvelope(type: nil))
    }

    func testInvalidBodies() {
        XCTAssertEqual(parse("<html>Just a moment...</html>"), .invalid)
        XCTAssertEqual(parse("[1,2]"), .invalid)
        XCTAssertEqual(parse(""), .invalid)
    }

    func testDateFormats() {
        let base = date("2026-09-29T20:00:00Z").timeIntervalSince1970
        XCTAssertEqual(UsageResponse.parseDate("2026-09-29T20:00:00Z")?.timeIntervalSince1970, base)
        XCTAssertEqual(UsageResponse.parseDate("2026-09-29T20:00:00+00:00")?.timeIntervalSince1970, base)
        XCTAssertEqual(UsageResponse.parseDate("2026-09-29T23:00:00+03:00")?.timeIntervalSince1970, base)
        XCTAssertEqual(UsageResponse.parseDate("2026-09-29T23:00:00+0300")?.timeIntervalSince1970, base)
        XCTAssertEqual(UsageResponse.parseDate("2026-09-29T20:00:00")?.timeIntervalSince1970, base)
        XCTAssertEqual(UsageResponse.parseDate("2026-09-29T20:00:00.5Z")!.timeIntervalSince1970, base + 0.5, accuracy: 0.0001)
        XCTAssertEqual(UsageResponse.parseDate("2026-09-29T20:00:00.000000+00:00")?.timeIntervalSince1970, base)
        XCTAssertEqual(UsageResponse.parseDate("2026-09-29T20:00:00.123456789Z")!.timeIntervalSince1970,
                       base + 0.123456789, accuracy: 0.0001)
        XCTAssertNil(UsageResponse.parseDate("tomorrow"))
        XCTAssertNil(UsageResponse.parseDate("2026-09-29"))
    }

    func testEpochSecondsResetTolerated() {
        let body = #"{"five_hour":{"utilization":1,"resets_at":1759172400}}"#
        guard case .usage(let u) = parse(body) else { return XCTFail("expected usage") }
        XCTAssertEqual(u.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1759172400))
    }
}
