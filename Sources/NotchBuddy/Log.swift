import Foundation
import NotchBuddyCore
import os

/// Tiny logger: unified logging (os.Logger) plus a plain file in `Paths.logsDir`
/// that rotates to `notchbuddy.1.log` at ~1 MB.
enum Log {
    static let subsystem = "me.sokolov.notchbuddy"
    static let maxFileSize: UInt64 = 1_000_000

    /// Overridable before the first log call (tests).
    nonisolated(unsafe) static var directory: URL = Paths.logsDir
    static var fileURL: URL { directory.appendingPathComponent("notchbuddy.log") }
    static var previousFileURL: URL { directory.appendingPathComponent("notchbuddy.1.log") }

    private static let logger = Logger(subsystem: subsystem, category: "app")
    private static let sink = FileSink()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        sink.append(level: "INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        sink.append(level: "ERROR", message)
    }

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    /// Waits (briefly) until earlier lines are on disk. Used right before `exit`.
    static func flush(timeout: TimeInterval = 0.5) {
        sink.flush(timeout: timeout)
    }
}

/// Serializes file writes on a private queue; never throws into callers.
private final class FileSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "me.sokolov.notchbuddy.log", qos: .utility)
    private var handle: FileHandle?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func append(level: String, _ message: String) {
        let now = Date()
        queue.async { [self] in
            let line = "\(formatter.string(from: now)) [\(level)] \(message)\n"
            guard let handle = openHandle() else { return }
            do {
                try handle.write(contentsOf: Data(line.utf8))
                if try handle.offset() >= Log.maxFileSize { rotate() }
            } catch {
                self.handle = nil
            }
        }
    }

    func flush(timeout: TimeInterval) {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    private func openHandle() -> FileHandle? {
        if let handle {
            // Reopen if the file was deleted under us (user cleared ~/Library/Logs).
            var st = stat()
            if fstat(handle.fileDescriptor, &st) == 0, st.st_nlink > 0 { return handle }
            try? handle.close()
            self.handle = nil
        }
        let fm = FileManager.default
        let url = Log.fileURL
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            handle = h
            return h
        } catch {
            return nil
        }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: Log.previousFileURL)
        try? fm.moveItem(at: Log.fileURL, to: Log.previousFileURL)
    }
}
