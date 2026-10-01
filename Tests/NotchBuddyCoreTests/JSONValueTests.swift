import XCTest
@testable import NotchBuddyCore

final class JSONValueTests: XCTestCase {
    private func json(_ value: JSONValue) -> String {
        String(decoding: value.serialized(), as: UTF8.self)
    }

    // MARK: string

    func testStringOfOrdinaryNumbers() {
        XCTAssertEqual(JSONValue.number(42).string, "42")
        XCTAssertEqual(JSONValue.number(-7).string, "-7")
        XCTAssertEqual(JSONValue.number(-0.0).string, "0")
        XCTAssertEqual(JSONValue.number(1.5).string, "1.5")
        XCTAssertEqual(JSONValue.number(1e18).string, "1000000000000000000")
    }

    /// `Int64(n)` used to trap on integral values outside Int64 (model-controlled tool arguments).
    func testStringOfHugeNumbersDoesNotTrap() throws {
        XCTAssertEqual(JSONValue.number(1e300).string, "1e+300")
        XCTAssertEqual(JSONValue.number(-1e300).string, "-1e+300")
        XCTAssertEqual(JSONValue.number(1e20).string, "1e+20")
        XCTAssertEqual(JSONValue.number(-9_223_372_036_854_775_808).string, "-9223372036854775808")
        XCTAssertEqual(JSONValue.number(9_223_372_036_854_775_808).string, "9223372036854775808", "2^63 fits UInt64")
        XCTAssertEqual(JSONValue.number(.infinity).string, "inf")
        XCTAssertEqual(JSONValue.number(-.infinity).string, "-inf")
        XCTAssertEqual(JSONValue.number(.nan).string, "nan")

        let parsed = try JSONValue.parse(Data(#"{"a":12345678901234567890,"b":1e300,"c":-1e300}"#.utf8))
        XCTAssertEqual(parsed["a"]?.string, "12345678901234567168", "nearest Double, printed without trapping")
        XCTAssertEqual(parsed["b"]?.string, "1e+300")
        XCTAssertEqual(parsed["c"]?.string, "-1e+300")
        XCTAssertFalse(parsed.compactText.isEmpty)
    }

    func testToolSummaryWithHugeNumbersDoesNotTrap() {
        XCTAssertEqual(ToolSummary.summarize(toolName: "mcp__db__run", input: ["query": .number(1e300)]), "1e+300")
        XCTAssertEqual(ToolSummary.summarize(toolName: "x", input: ["path": [.number(1e20), "b"]]), "1e+20 b")
        XCTAssertNotNil(ToolSummary.summarize(toolName: "x", input: ["content": .number(1e20)]))
    }

    /// The bridge normalizes before anything else; a trap there breaks the "always exit 0" contract.
    func testAdaptersNormalizeHugeNumericToolInput() throws {
        let payload = Data(#"""
            {"hook_event_name":"PreToolUse","session_id":"s","tool_name":"mcp__db__run",\#
            "tool_input":{"query":1e300,"content":12345678901234567890}}
            """#.utf8)
        for source in AgentSource.allCases {
            let e = try Adapters.adapter(for: source).normalize(stdin: payload, host: HostContext())
            XCTAssertEqual(e.toolSummary, "1e+300", source.rawValue)
            XCTAssertEqual(e.raw.at("tool_input", "content")?.string, "12345678901234567168", source.rawValue)
        }
    }

    // MARK: encoding

    func testIntegersKeepIntegerNotation() {
        XCTAssertEqual(json(["t": 600]), #"{"t":600}"#)
        XCTAssertEqual(json(["t": .number(10_000_000_000_000_000)]), #"{"t":10000000000000000}"#)
        XCTAssertEqual(json(["t": .number(9_223_372_036_854_775_808)]), #"{"t":9223372036854775808}"#)
        XCTAssertEqual(json(["t": .number(1.5)]), #"{"t":1.5}"#)
        XCTAssertEqual(json(["t": .number(1e300)]), #"{"t":1e+300}"#)
    }

    func testNonFiniteNumberEncodesAsNullAndKeepsTheDocument() throws {
        XCTAssertEqual(json(["a": .number(.infinity), "b": "x"]), #"{"a":null,"b":"x"}"#)
        XCTAssertEqual(json([.number(.nan), 1]), "[null,1]")
    }

    func testRoundTripThroughWire() throws {
        let raw: JSONValue = ["huge": .number(1e300), "big": .number(10_000_000_000_000_000), "n": 3, "s": "x"]
        let event = AgentEvent(source: .codex, hookEventName: "PreToolUse", kind: .toolWillRun, sessionId: "s", raw: raw)
        var buffer = try Wire.frame(BridgeRequest(event: event, expectsReply: false))
        let payload = try XCTUnwrap(Wire.takeFrame(from: &buffer))
        XCTAssertEqual(try Wire.decode(BridgeRequest.self, from: payload).event.raw, raw)
    }
}
