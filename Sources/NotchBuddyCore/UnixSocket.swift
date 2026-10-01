import Darwin
import Foundation

// POSIX AF_UNIX stream sockets carrying Wire frames (4-byte big-endian length + JSON).
// All descriptors are non-blocking with SO_NOSIGPIPE; waits use poll() against a deadline.

public enum UnixSocketError: Error, Equatable {
    /// The path does not fit into `sockaddr_un.sun_path` (103 bytes + NUL).
    case pathTooLong(String)
    /// Another server is accepting connections on this path.
    case alreadyRunning(String)
    /// Something that is not a socket already exists at the path; we refuse to delete it.
    case pathOccupied(String)
    case timedOut
    case system(call: String, errno: Int32)
}

// MARK: - Reply handle

/// Handle for answering one bridge connection that expects a reply.
public final class ReplyHandle: @unchecked Sendable {
    private enum State { case open, replied, closed, peerClosed }

    private let lock = NSLock()
    private var state: State = .open
    private var fd: Int32
    private var watcher: DispatchSourceRead?
    private var peerClosedHandler: (@Sendable () -> Void)?
    private var peerClosedNotified = false

    init(fd: Int32) {
        self.fd = fd
    }

    /// A handle with no connection behind it (the app's debug benchmark feeds fake permission requests): it stays
    /// open until answered or closed, and a reply goes nowhere.
    public static func unconnected() -> ReplyHandle {
        ReplyHandle(fd: -1)
    }

    deinit {
        if state == .open { closeDescriptor() }
    }

    /// Sends the reply frame and closes the connection. Safe to call once; later calls are ignored.
    public func send(_ reply: BridgeReply) {
        guard let frame = try? Wire.frame(reply) else {
            close()
            return
        }
        locked {
            guard state == .open else { return }
            state = .replied
            // A vanished peer yields EPIPE (no SIGPIPE thanks to SO_NOSIGPIPE); nothing else to do then.
            try? SocketIO.writeAll(fd, frame, until: Deadline(after: 2))
            closeDescriptor()
        }
    }

    /// Closes without replying (bridge falls back to the agent's normal prompt).
    public func close() {
        locked {
            guard state == .open else { return }
            state = .closed
            closeDescriptor()
        }
    }

    /// Called (on an arbitrary queue) once when the peer disconnects before a reply was sent.
    /// If the peer is already gone when the handler is assigned, it is called right away.
    public var onPeerClosed: (@Sendable () -> Void)? {
        get { locked { peerClosedHandler } }
        set {
            let fireNow: (@Sendable () -> Void)? = locked {
                peerClosedHandler = newValue
                return takePeerClosedHandlerIfDue()
            }
            fireNow?()
        }
    }

    public var isOpen: Bool { locked { state == .open } }

    // MARK: Internals

    /// Watches the connection for hangup; must be called before the handle is shared.
    func startWatching(on queue: DispatchQueue) {
        locked {
            guard state == .open else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let descriptor = fd
            source.setEventHandler { [weak self] in self?.connectionReadable() }
            // The descriptor stays open until the source is fully cancelled, so it can't be reused under us.
            source.setCancelHandler { Darwin.close(descriptor) }
            watcher = source
            source.resume()
        }
    }

    private func connectionReadable() {
        let fire: (@Sendable () -> Void)? = locked {
            guard state == .open else { return nil }
            var scratch = [UInt8](repeating: 0, count: 4096)
            let n = scratch.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, MSG_DONTWAIT) }
            if n > 0 { return nil }  // unexpected extra bytes from the bridge: discarded
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return nil }
            state = .peerClosed
            closeDescriptor()
            return takePeerClosedHandlerIfDue()
        }
        fire?()
    }

    /// Caller holds the lock.
    private func takePeerClosedHandlerIfDue() -> (@Sendable () -> Void)? {
        guard state == .peerClosed, !peerClosedNotified, let handler = peerClosedHandler else { return nil }
        peerClosedNotified = true
        return handler
    }

    /// Caller holds the lock (or is deinit).
    private func closeDescriptor() {
        if let watcher {
            watcher.cancel()
            self.watcher = nil
        } else if fd >= 0 {
            Darwin.close(fd)
        }
        fd = -1
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

// MARK: - Server

/// App side: listens on a Unix socket, accepts one `BridgeRequest` frame per connection.
/// Creates the parent directory with 0700 and the socket with 0600, removes a stale socket file,
/// rejects peers whose uid differs from ours (getpeereid).
public final class UnixSocketServer: @unchecked Sendable {
    /// How long a freshly connected bridge has to deliver its request frame.
    static let requestTimeout: TimeInterval = 5

    public let path: String
    private let handler: @Sendable (BridgeRequest, ReplyHandle?) -> Void
    private let lock = NSLock()
    private var listener: DispatchSourceRead?
    private var socketIdentity: (dev: dev_t, ino: ino_t)?
    private let acceptQueue = DispatchQueue(label: "notchbuddy.socket.accept")
    private let readQueue = DispatchQueue(label: "notchbuddy.socket.read", attributes: .concurrent)
    private let handlerQueue = DispatchQueue(label: "notchbuddy.socket.handler")
    private let watchQueue = DispatchQueue(label: "notchbuddy.socket.watch")

    /// `handler` is invoked on the server's private queue. `reply` is non-nil iff `request.expectsReply`.
    public init(path: String, handler: @escaping @Sendable (BridgeRequest, ReplyHandle?) -> Void) {
        self.path = path
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listener == nil else { return }

        try createParentDirectory()
        try removeStaleSocket()

        let fd = try SocketIO.makeSocket()
        do {
            let rc = try SocketIO.withAddress(path) { bind(fd, $0, $1) }
            guard rc == 0 else { throw UnixSocketError.system(call: "bind", errno: errno) }
            guard chmod(path, 0o600) == 0 else { throw UnixSocketError.system(call: "chmod", errno: errno) }
            guard listen(fd, 128) == 0 else { throw UnixSocketError.system(call: "listen", errno: errno) }
        } catch {
            Darwin.close(fd)
            throw error
        }

        var st = stat()
        if lstat(path, &st) == 0 { socketIdentity = (st.st_dev, st.st_ino) }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
        source.setCancelHandler { Darwin.close(fd) }
        listener = source
        source.resume()
    }

    public func stop() {
        lock.lock()
        let source = listener
        let identity = socketIdentity
        listener = nil
        socketIdentity = nil
        lock.unlock()

        guard let source else { return }
        source.cancel()
        // Remove the socket file only if it is still ours (a newer instance may have replaced it).
        var st = stat()
        if let identity, lstat(path, &st) == 0, st.st_dev == identity.dev, st.st_ino == identity.ino {
            unlink(path)
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener != nil
    }

    // MARK: Connections

    private func acceptPending(on listenFD: Int32) {
        while true {
            let conn = accept(listenFD, nil, nil)
            if conn < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                // Out of descriptors: the source would refire at once, so back off briefly.
                if errno == EMFILE || errno == ENFILE { usleep(50_000) }
                return  // EAGAIN: drained; anything else: try again on the next readiness event
            }
            SocketIO.configure(conn)
            guard SocketIO.peerIsCurrentUser(conn) else {
                Darwin.close(conn)
                continue
            }
            readQueue.async { [weak self] in
                guard let self else {
                    Darwin.close(conn)
                    return
                }
                self.serve(conn)
            }
        }
    }

    private func serve(_ fd: Int32) {
        let request: BridgeRequest
        do {
            guard let payload = try SocketIO.readFrame(fd, until: Deadline(after: Self.requestTimeout)) else {
                Darwin.close(fd)
                return
            }
            request = try Wire.decode(BridgeRequest.self, from: payload)
        } catch {
            Darwin.close(fd)
            return
        }
        guard isRunning else {
            Darwin.close(fd)
            return
        }

        let handler = self.handler
        guard request.expectsReply else {
            Darwin.close(fd)
            handlerQueue.async { handler(request, nil) }
            return
        }
        let reply = ReplyHandle(fd: fd)
        reply.startWatching(on: watchQueue)
        handlerQueue.async { handler(request, reply) }
    }

    // MARK: Filesystem

    private func createParentDirectory() throws {
        let dir = (path as NSString).deletingLastPathComponent
        guard !dir.isEmpty, !FileManager.default.fileExists(atPath: dir) else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func removeStaleSocket() throws {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        guard (st.st_mode & S_IFMT) == S_IFSOCK else { throw UnixSocketError.pathOccupied(path) }
        if SocketIO.isAccepting(path) { throw UnixSocketError.alreadyRunning(path) }
        unlink(path)
    }
}

// MARK: - Client

/// Bridge side.
public enum UnixSocketClient {
    /// A live server accepts immediately; anything slower means the app is wedged or absent.
    static let connectTimeout: TimeInterval = 0.5

    /// Connects, writes the request frame. If `expectsReply`, blocks until a `BridgeReply` arrives,
    /// the peer closes (returns nil), or `timeout` elapses (returns nil). Throws if it cannot connect.
    public static func send(_ request: BridgeRequest, path: String, timeout: TimeInterval) throws -> BridgeReply? {
        let frame = try Wire.frame(request)
        let fd = try SocketIO.makeSocket()
        defer { Darwin.close(fd) }

        try SocketIO.connect(fd, path: path, until: Deadline(after: connectTimeout))
        try SocketIO.writeAll(fd, frame, until: Deadline(after: min(max(timeout, 1), 5)))
        guard request.expectsReply else { return nil }

        guard let payload = try? SocketIO.readFrame(fd, until: Deadline(after: timeout)) else { return nil }
        return try? Wire.decode(BridgeReply.self, from: payload)
    }
}

// MARK: - Low-level helpers

/// A point on the monotonic clock (keeps counting during sleep).
struct Deadline {
    let nanos: UInt64

    init(after seconds: TimeInterval) {
        let clamped = seconds.isFinite ? min(max(seconds, 0), 60 * 60 * 24 * 365) : 60 * 60 * 24 * 365
        nanos = Deadline.now() &+ UInt64(clamped * 1_000_000_000)
    }

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }

    /// Milliseconds left, capped so a single poll() re-checks the clock at least once a second.
    var pollSliceMillis: Int32 {
        let now = Deadline.now()
        guard nanos > now else { return 0 }
        let ms = (nanos - now + 999_999) / 1_000_000
        return Int32(min(ms, 1000))
    }
}

enum SocketIO {
    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.system(call: "socket", errno: errno) }
        configure(fd)
        return fd
    }

    /// FD_CLOEXEC, SO_NOSIGPIPE, O_NONBLOCK.
    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity, !bytes.contains(0) else {
            throw UnixSocketError.pathTooLong(path)
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }

    static func connect(_ fd: Int32, path: String, until deadline: Deadline) throws {
        let rc = try withAddress(path) { Darwin.connect(fd, $0, $1) }
        if rc == 0 { return }
        let err = errno
        guard err == EINPROGRESS || err == EINTR else { throw UnixSocketError.system(call: "connect", errno: err) }
        guard wait(fd, for: Int16(POLLOUT), until: deadline) else { throw UnixSocketError.timedOut }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) != 0 { soError = errno }
        if soError != 0 { throw UnixSocketError.system(call: "connect", errno: soError) }
    }

    /// True if some process is currently accepting connections on `path`.
    static func isAccepting(_ path: String) -> Bool {
        guard let fd = try? makeSocket() else { return false }
        defer { Darwin.close(fd) }
        return (try? connect(fd, path: path, until: Deadline(after: 0.2))) != nil
    }

    static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == getuid()
    }

    /// Waits until `fd` is ready for `events`. Returns false only when the deadline passes;
    /// readiness, hangup and poll errors all return true so the next syscall reports the outcome.
    static func wait(_ fd: Int32, for events: Int16, until deadline: Deadline) -> Bool {
        while true {
            let slice = deadline.pollSliceMillis
            if slice == 0 { return false }
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let r = poll(&pfd, 1, slice)
            if r > 0 { return true }
            if r < 0, errno != EINTR, errno != EAGAIN { return true }
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data, until deadline: Deadline) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, base + offset, buffer.count - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                let err = n < 0 ? errno : EPIPE
                if err == EINTR { continue }
                if err == EAGAIN || err == EWOULDBLOCK {
                    guard wait(fd, for: Int16(POLLOUT), until: deadline) else { throw UnixSocketError.timedOut }
                    continue
                }
                throw UnixSocketError.system(call: "write", errno: err)
            }
        }
    }

    /// Reads exactly one Wire frame. Returns nil if the peer closes first or the deadline passes.
    static func readFrame(_ fd: Int32, until deadline: Deadline) throws -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let frame = try Wire.takeFrame(from: &buffer) { return frame }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0 ..< n])
                continue
            }
            if n == 0 { return nil }
            switch errno {
            case EINTR:
                continue
            case EAGAIN, EWOULDBLOCK:
                guard wait(fd, for: Int16(POLLIN), until: deadline) else { return nil }
            case ECONNRESET:
                return nil
            case let err:
                throw UnixSocketError.system(call: "read", errno: err)
            }
        }
    }
}
