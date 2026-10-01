import Darwin
import Foundation
import NotchBuddyCore

/// Hook mode: stdin → AgentEvent → app socket → (permission only) decision → agent-specific stdout.
enum HookCommand {
    /// Non-permission events: just enough time to hand the frame to the app.
    static let fireAndForgetTimeout: TimeInterval = 2

    static func run(source: AgentSource) -> Int32 {
        let stdin = BridgeIO.readStdin()
        // Hook bleed: Cursor and Grok also run hooks registered for other
        // agents. Those invocations are dropped; the host agent reports through its own hooks.
        if let host = AgentCatalog.foreignHost(for: source, payload: try? JSONValue.parse(stdin),
                                               env: ProcessInfo.processInfo.environment) {
            DebugLog.log("\(source.rawValue): invocation from \(host.rawValue), dropped")
            return 0
        }
        let host = HostProbe.current()
        let adapter = Adapters.adapter(for: source)

        let event: AgentEvent
        do {
            event = try adapter.normalize(stdin: stdin, host: host)
        } catch {
            DebugLog.log("\(source.rawValue): normalize failed (\(error)), \(stdin.count) bytes")
            return 0
        }

        let expectsReply = adapter.expectsDecision(event)
        let timeout = expectsReply ? adapter.decisionTimeout : fireAndForgetTimeout
        DebugLog.log("\(source.rawValue) \(event.hookEventName) session=\(event.sessionId) expectsReply=\(expectsReply)")

        let reply: BridgeReply?
        do {
            reply = try send(event, expectsReply: expectsReply, timeout: timeout)
        } catch {
            DebugLog.log("app unreachable: \(error)")
            return 0
        }

        guard let reply, reply.eventId == event.id else {
            if expectsReply { DebugLog.log("no decision (timeout, app closed the request, or id mismatch)") }
            return 0
        }

        let output = adapter.render(reply.decision, for: event)
        DebugLog.log("decision \(reply.decision) → exit \(output.exitCode), stdout \(output.stdout?.utf8.count ?? 0) bytes")
        if let out = output.stdout, !out.isEmpty { BridgeIO.write(out, to: STDOUT_FILENO) }
        if let err = output.stderr, !err.isEmpty { BridgeIO.write(err, to: STDERR_FILENO) }
        return output.exitCode
    }

    /// Sends the event; if the frame is too large (huge tool payloads), retries without the raw stdin copy.
    private static func send(_ event: AgentEvent, expectsReply: Bool, timeout: TimeInterval) throws -> BridgeReply? {
        do {
            return try UnixSocketClient.send(BridgeRequest(event: event, expectsReply: expectsReply),
                                             path: Paths.socket, timeout: timeout)
        } catch WireError.frameTooLarge {
            var slim = event
            slim.raw = .null
            return try UnixSocketClient.send(BridgeRequest(event: slim, expectsReply: expectsReply),
                                             path: Paths.socket, timeout: timeout)
        }
    }
}
