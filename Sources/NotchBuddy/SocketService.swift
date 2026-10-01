import Foundation
import NotchBuddyCore

/// Owns the Unix socket the bridge talks to and forwards requests to the model on the main actor.
@MainActor
final class SocketService {
    let path: String
    private let model: AppModel
    /// The running server. Lock-protected so a signal handler can stop it from any thread,
    /// even while the main thread is busy.
    private let running = ServerSlot()
    /// Human-readable reason when the server couldn't start (shown in the menu).
    private(set) var failure: String?

    var isRunning: Bool { running.server != nil }

    init(model: AppModel, path: String = Paths.socket) {
        self.model = model
        self.path = path
    }

    func start() {
        guard running.server == nil else { return }
        let server = UnixSocketServer(path: path) { [weak model] request, reply in
            // A permission card's content is linear in the payload (a Write of a large file): built here, on the
            // server's serial handler queue, so the main thread only shows it.
            let event = request.event
            let detail = event.kind == .permissionRequest && event.decisionSupported && reply != nil
                ? PermissionDetail(event: event) : nil
            // DispatchQueue.main keeps the server's delivery order (a Task hop wouldn't guarantee it).
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let model else {
                        reply?.close()
                        return
                    }
                    model.handle(request, reply: reply, detail: detail)
                }
            }
        }
        do {
            try server.start()
            running.server = server
            failure = nil
            Log.info("socket server listening at \(path)")
        } catch {
            failure = "\(error)"
            Log.error("socket server failed to start at \(path): \(error)")
        }
    }

    func stop() {
        guard stopFromAnyThread() else { return }
        Log.info("socket server stopped")
    }

    /// Stops listening and removes the socket file (only if it is still ours: the server checks).
    /// Safe from any thread and idempotent. Returns false if nothing was running.
    @discardableResult
    nonisolated func stopFromAnyThread() -> Bool {
        guard let server = running.take() else { return false }
        server.stop()
        return true
    }
}

private final class ServerSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UnixSocketServer?

    var server: UnixSocketServer? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    func take() -> UnixSocketServer? {
        lock.withLock {
            defer { value = nil }
            return value
        }
    }
}
