import Darwin
import Foundation
import NotchBuddyCore

/// Raw stdio and process plumbing for the bridge. Everything here is best effort and never throws.
enum BridgeIO {
    /// Agents stop hooks with SIGTERM (Claude, Kimi) or SIGKILL (Codex). A killed hook must leave no output
    /// and no error status behind. SIGPIPE is ignored so a closed stdout can't kill us mid-write.
    static func installSignalHandlers() {
        signal(SIGPIPE, SIG_IGN)
        for sig in [SIGTERM, SIGHUP, SIGINT] {
            signal(sig) { _ in _exit(0) }
        }
    }

    /// Reads stdin to EOF. Stops early (returns what it has) past `limit` bytes or on a read error.
    static func readStdin(limit: Int = 64 * 1024 * 1024) -> Data {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < limit {
            let n = chunk.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if n > 0 {
                data.append(contentsOf: chunk[0 ..< n])
            } else if n < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        return data
    }

    /// Writes exactly these bytes (no newline added), retrying partial writes.
    static func write(_ string: String, to fd: Int32) {
        let bytes = Array(string.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n > 0 {
                offset += n
            } else if n < 0, errno == EINTR {
                continue
            } else if n < 0, errno == EAGAIN {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&pfd, 1, 1000) <= 0 { return }
            } else {
                return
            }
        }
    }
}

/// Opt-in diagnostics: NOTCHBUDDY_DEBUG=1 appends to ~/Library/Logs/NotchBuddy/bridge.log. Never stdout/stderr.
enum DebugLog {
    static let isEnabled = ProcessInfo.processInfo.environment["NOTCHBUDDY_DEBUG"] == "1"
    private static let started = Date()

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let dir = Paths.logsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("bridge.log").path
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started) * 1000)
        let stamp = ISO8601DateFormatter().string(from: Date())
        BridgeIO.write("\(stamp) [\(getpid())] +\(elapsed)ms \(message())\n", to: fd)
    }
}
