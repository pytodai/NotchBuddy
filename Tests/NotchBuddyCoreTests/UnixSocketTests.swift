import Darwin
import XCTest
@testable import NotchBuddyCore

final class UnixSocketTests: XCTestCase {
    private var socketPath = ""
    private var servers: [UnixSocketServer] = []
    private var extraPaths: [String] = []

    override func setUp() {
        super.setUp()
        socketPath = Self.shortTempPath()
    }

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers = []
        unlink(socketPath)
        for path in extraPaths { try? FileManager.default.removeItem(atPath: path) }
        super.tearDown()
    }

    // MARK: Helpers

    /// sun_path is 104 bytes: keep test sockets short and out of the (long) temp dir.
    static func shortTempPath() -> String {
        "/tmp/nbt-\(UUID().uuidString.prefix(8).lowercased()).sock"
    }

    static func makeEvent(kind: EventKind = .permissionRequest, raw: JSONValue = ["tool_name": "Bash"]) -> AgentEvent {
        AgentEvent(source: .claude, hookEventName: "PermissionRequest", kind: kind, sessionId: "s-1",
                   cwd: "/tmp/project", toolName: "Bash", toolSummary: "ls -la", decisionSupported: true,
                   canAlwaysAllow: true, timestamp: Date(timeIntervalSince1970: 1_759_150_000),
                   host: HostContext(termProgram: "iTerm.app", tty: "/dev/ttys003", agentPid: 42, extra: ["K": "V"]),
                   raw: raw)
    }

    /// Thread-safe box for values captured by server handlers.
    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    @discardableResult
    private func startServer(path: String? = nil,
                             _ handler: @escaping @Sendable (BridgeRequest, ReplyHandle?) -> Void) throws -> UnixSocketServer {
        let server = UnixSocketServer(path: path ?? socketPath, handler: handler)
        try server.start()
        servers.append(server)
        return server
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }

    // MARK: Framing round trip

    func testFireAndForgetRequestReachesHandler() throws {
        let received = expectation(description: "handler")
        let captured = Box<(BridgeRequest, Bool)?>(nil)
        try startServer { request, reply in
            captured.value = (request, reply != nil)
            received.fulfill()
        }

        let event = Self.makeEvent(kind: .toolWillRun)
        let result = try UnixSocketClient.send(BridgeRequest(event: event, expectsReply: false), path: socketPath, timeout: 2)
        XCTAssertNil(result)
        wait(for: [received], timeout: 3)
        XCTAssertEqual(captured.value?.0, BridgeRequest(event: event, expectsReply: false))
        XCTAssertEqual(captured.value?.1, false, "no ReplyHandle for fire-and-forget requests")
    }

    func testReplyRoundTrip() throws {
        try startServer { request, reply in
            reply?.send(BridgeReply(eventId: request.event.id, decision: .deny(reason: "Не сейчас")))
        }
        let event = Self.makeEvent()
        let reply = try UnixSocketClient.send(BridgeRequest(event: event, expectsReply: true), path: socketPath, timeout: 5)
        XCTAssertEqual(reply, BridgeReply(eventId: event.id, decision: .deny(reason: "Не сейчас")))
    }

    func testReplyFromAnotherThreadLater() throws {
        try startServer { request, reply in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                reply?.send(BridgeReply(eventId: request.event.id, decision: .allowAlways))
                reply?.send(BridgeReply(eventId: request.event.id, decision: .allow))  // ignored
            }
        }
        let event = Self.makeEvent()
        let reply = try UnixSocketClient.send(BridgeRequest(event: event, expectsReply: true), path: socketPath, timeout: 5)
        XCTAssertEqual(reply?.decision, .allowAlways)
    }

    func testLargeFrameRoundTrip() throws {
        let big = String(repeating: "абв-xyz ", count: 200_000)  // ~2.4 MB, many partial reads/writes
        let captured = Box<BridgeRequest?>(nil)
        try startServer { request, reply in
            captured.value = request
            reply?.send(BridgeReply(eventId: request.event.id, decision: .allow))
        }
        let event = Self.makeEvent(raw: ["content": .string(big)])
        let reply = try UnixSocketClient.send(BridgeRequest(event: event, expectsReply: true), path: socketPath, timeout: 10)
        XCTAssertEqual(reply?.decision, .allow)
        XCTAssertEqual(captured.value?.event.raw["content"]?.string, big)
    }

    func testConcurrentClients() throws {
        let count = 24
        let seen = Box<Set<String>>([])
        try startServer { request, reply in
            seen.value.insert(request.event.sessionId)
            reply?.send(BridgeReply(eventId: request.event.id, decision: .allow))
        }
        let failures = Box(0)
        DispatchQueue.concurrentPerform(iterations: count) { i in
            var event = Self.makeEvent()
            event.sessionId = "s-\(i)"
            let expects = i % 2 == 0
            do {
                let reply = try UnixSocketClient.send(BridgeRequest(event: event, expectsReply: expects),
                                                      path: socketPath, timeout: 5)
                if expects && reply?.eventId != event.id { failures.value += 1 }
            } catch {
                failures.value += 1
            }
        }
        XCTAssertEqual(failures.value, 0)
        XCTAssertTrue(waitUntil { seen.value.count == count })
    }

    // MARK: Timeouts and closing

    func testTimeoutReturnsNil() throws {
        let held = Box<ReplyHandle?>(nil)
        try startServer { _, reply in held.value = reply }  // never answers
        let start = Date()
        let reply = try UnixSocketClient.send(BridgeRequest(event: Self.makeEvent(), expectsReply: true),
                                              path: socketPath, timeout: 0.3)
        XCTAssertNil(reply)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.25)
        XCTAssertLessThan(elapsed, 2)
    }

    func testServerCloseWithoutReplyReturnsNilPromptly() throws {
        try startServer { _, reply in reply?.close() }
        let start = Date()
        let reply = try UnixSocketClient.send(BridgeRequest(event: Self.makeEvent(), expectsReply: true),
                                              path: socketPath, timeout: 10)
        XCTAssertNil(reply)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testPeerCloseNotifiesOnce() throws {
        let closed = expectation(description: "onPeerClosed")
        closed.assertForOverFulfill = true
        let held = Box<ReplyHandle?>(nil)
        try startServer { _, reply in
            reply?.onPeerClosed = { closed.fulfill() }
            held.value = reply
        }
        _ = try UnixSocketClient.send(BridgeRequest(event: Self.makeEvent(), expectsReply: true),
                                      path: socketPath, timeout: 0.2)
        wait(for: [closed], timeout: 3)
        XCTAssertEqual(held.value?.isOpen, false)
        // Replying after the bridge left must neither crash (SIGPIPE) nor notify again.
        held.value?.send(BridgeReply(eventId: UUID(), decision: .allow))
        held.value?.close()
    }

    func testPeerClosedBeforeHandlerAssignedFiresOnAssignment() throws {
        let held = Box<ReplyHandle?>(nil)
        try startServer { _, reply in held.value = reply }
        _ = try UnixSocketClient.send(BridgeRequest(event: Self.makeEvent(), expectsReply: true),
                                      path: socketPath, timeout: 0.1)
        XCTAssertTrue(waitUntil { held.value != nil && held.value?.isOpen == false })

        let fired = expectation(description: "late onPeerClosed")
        held.value?.onPeerClosed = { fired.fulfill() }
        wait(for: [fired], timeout: 1)
    }

    func testNoPeerClosedNotificationAfterReply() throws {
        let notified = Box(false)
        try startServer { request, reply in
            reply?.onPeerClosed = { notified.value = true }
            reply?.send(BridgeReply(eventId: request.event.id, decision: .allow))
            XCTAssertEqual(reply?.isOpen, false)
        }
        _ = try UnixSocketClient.send(BridgeRequest(event: Self.makeEvent(), expectsReply: true), path: socketPath, timeout: 5)
        usleep(200_000)
        XCTAssertFalse(notified.value)
    }

    // MARK: Connection errors and robustness

    func testConnectFailureThrows() {
        XCTAssertThrowsError(try UnixSocketClient.send(BridgeRequest(event: Self.makeEvent(), expectsReply: false),
                                                       path: socketPath, timeout: 1))
    }

    func testTooLongPathThrows() {
        let path = "/tmp/" + String(repeating: "x", count: 120)
        XCTAssertThrowsError(try UnixSocketClient.send(BridgeRequest(event: Self.makeEvent(), expectsReply: false),
                                                       path: path, timeout: 1)) { error in
            XCTAssertEqual(error as? UnixSocketError, .pathTooLong(path))
        }
    }

    func testMalformedFrameIsDroppedAndServerKeepsWorking() throws {
        let calls = Box(0)
        try startServer { request, reply in
            calls.value += 1
            reply?.send(BridgeReply(eventId: request.event.id, decision: .allow))
        }

        // Valid length prefix, garbage JSON.
        let fd = try SocketIO.makeSocket()
        try SocketIO.connect(fd, path: socketPath, until: Deadline(after: 1))
        var garbage = Data([0, 0, 0, 5])
        garbage.append(Data("nope!".utf8))
        try SocketIO.writeAll(fd, garbage, until: Deadline(after: 1))
        XCTAssertNil(try SocketIO.readFrame(fd, until: Deadline(after: 2)), "server should just hang up")
        close(fd)

        let reply = try UnixSocketClient.send(BridgeRequest(event: Self.makeEvent(), expectsReply: true), path: socketPath, timeout: 5)
        XCTAssertEqual(reply?.decision, .allow)
        XCTAssertEqual(calls.value, 1)
    }

    func testPeerFromSameUserIsAccepted() throws {
        let fds = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        defer { fds.deallocate() }
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, fds), 0)
        XCTAssertTrue(SocketIO.peerIsCurrentUser(fds[0]))
        close(fds[0])
        close(fds[1])
    }

    // MARK: Filesystem

    func testSocketAndDirectoryPermissions() throws {
        let dir = "/tmp/nbt-\(UUID().uuidString.prefix(8).lowercased())"
        extraPaths.append(dir)
        let path = dir + "/run/s.sock"
        let server = try startServer(path: path) { _, _ in }

        var st = stat()
        XCTAssertEqual(lstat(path, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(lstat(dir + "/run", &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)

        server.stop()
        XCTAssertNotEqual(lstat(path, &st), 0, "stop() removes the socket file")
    }

    func testStaleSocketIsReplaced() throws {
        // Leave a socket file behind with nobody listening (as after a crash).
        let fd = try SocketIO.makeSocket()
        XCTAssertEqual(try SocketIO.withAddress(socketPath) { Darwin.bind(fd, $0, $1) }, 0)
        close(fd)

        let received = expectation(description: "handler")
        try startServer { _, _ in received.fulfill() }
        _ = try UnixSocketClient.send(BridgeRequest(event: Self.makeEvent(), expectsReply: false), path: socketPath, timeout: 1)
        wait(for: [received], timeout: 3)
    }

    func testSecondServerOnLiveSocketIsRefused() throws {
        try startServer { _, _ in }
        let second = UnixSocketServer(path: socketPath) { _, _ in }
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? UnixSocketError, .alreadyRunning(self.socketPath))
        }
    }

    func testRegularFileAtSocketPathIsNotDeleted() throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: socketPath, contents: Data("keep".utf8)))
        let server = UnixSocketServer(path: socketPath) { _, _ in }
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(error as? UnixSocketError, .pathOccupied(self.socketPath))
        }
        XCTAssertEqual(FileManager.default.contents(atPath: socketPath), Data("keep".utf8))
    }

    func testRestartAfterStop() throws {
        let server = try startServer { _, _ in }
        server.stop()
        XCTAssertThrowsError(try UnixSocketClient.send(BridgeRequest(event: Self.makeEvent(), expectsReply: false),
                                                       path: socketPath, timeout: 1))
        let received = expectation(description: "handler after restart")
        try startServer { _, _ in received.fulfill() }
        _ = try UnixSocketClient.send(BridgeRequest(event: Self.makeEvent(), expectsReply: false), path: socketPath, timeout: 1)
        wait(for: [received], timeout: 3)
    }
}
