import CoreServices
import Foundation

/// Outcome of one AppleScript handler call.
enum AppleScriptOutcome: Equatable, Sendable {
    case success(String?)
    case failure(code: Int, message: String)
    case timedOut
    /// Never run: a newer request superseded it, or it was still queued when its deadline passed.
    case skipped

    /// errAEEventNotPermitted: the user denied (or never granted) Automation for the target app.
    static let notAuthorized = -1743
    /// errAEEventWouldRequireUserConsent
    static let consentRequired = -1744
    /// procNotFound: the target app is not running.
    static let appNotRunning = -600
    /// errAETimeout
    static let appleEventTimeout = -1712
}

/// Runs AppleScript in-process (NSAppleScript), off the main thread, one script at a time.
///
/// Apple events block until the target replies or the user answers the Automation consent dialog,
/// so everything runs on a private serial queue; serializing also keeps a slow jump from landing
/// after a later one. Scripts are compiled once per source and cached. Values are never spliced
/// into the source: they are passed as arguments to a handler (`on focus(a, b)`) via a subroutine
/// Apple event, so no escaping is involved at all.
///
/// Stale work is dropped instead of running late (a focus script that runs after the user moved on
/// switches tabs and steals focus): a job still queued when its caller's timeout passed, or one whose
/// `isCurrent` says a newer request replaced it, is skipped. With a `target`, the Automation consent
/// is settled first (that is where a first jump blocks), and the job is re-checked once it is answered.
final class AppleScriptRunner: @unchecked Sendable {
    static let shared = AppleScriptRunner()

    /// After a consent dialog, a still-current job runs only if it was requested at most this long ago.
    static let consentGrace: TimeInterval = 30

    private let queue = DispatchQueue(label: "me.sokolov.notchbuddy.applescript", qos: .userInitiated)
    /// Only touched on `queue`.
    private var compiled: [String: NSAppleScript] = [:]

    /// Calls handler `handler` of the script `source` with string arguments.
    /// Returns `.timedOut` after `timeout`; a job not started by then is dropped. `target` (bundle id of the
    /// scripted app) enables the consent pre-flight. `isCurrent` is called on the runner's queue right
    /// before the script would run; returning false skips it (`.skipped`).
    func call(
        handler: String, in source: String, arguments: [String], timeout: TimeInterval = 6,
        target: String? = nil, isCurrent: @escaping @Sendable () -> Bool = { true }
    ) async -> AppleScriptOutcome {
        let job = Job(timeout: timeout, grace: max(timeout, Self.consentGrace), isCurrent: isCurrent)
        return await withCheckedContinuation { (continuation: CheckedContinuation<AppleScriptOutcome, Never>) in
            let once = ResumeOnce(continuation)
            queue.async { [self] in
                once.resume(run(job, handler: handler, source: source, arguments: arguments, target: target))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                once.resume(.timedOut)
            }
        }
    }

    /// Deadlines of one call, on the monotonic clock (keeps counting during sleep).
    struct Job: Sendable {
        let startDeadline: UInt64
        let lateDeadline: UInt64
        let isCurrent: @Sendable () -> Bool

        init(timeout: TimeInterval, grace: TimeInterval, isCurrent: @escaping @Sendable () -> Bool, now: UInt64 = Job.now()) {
            startDeadline = now + UInt64(max(timeout, 0) * 1e9)
            lateDeadline = now + UInt64(max(grace, 0) * 1e9)
            self.isCurrent = isCurrent
        }

        static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }

        /// May a job taken off the queue at `now` still start?
        func mayStart(now: UInt64 = Job.now()) -> Bool { now < startDeadline && isCurrent() }

        /// May it still run after waiting for the consent dialog?
        func mayRunAfterConsent(now: UInt64 = Job.now()) -> Bool { now < lateDeadline && isCurrent() }
    }

    private func run(_ job: Job, handler: String, source: String, arguments: [String], target: String?) -> AppleScriptOutcome {
        dispatchPrecondition(condition: .onQueue(queue))
        guard job.mayStart() else {
            Log.info("applescript: dropped a stale \(handler) request (timed out in the queue or superseded)")
            return .skipped
        }
        if let target {
            // Blocks while the consent dialog is up; answered instantly once the user has decided.
            let status = Self.automationPermission(for: target)
            switch Int(status) {
            case AppleScriptOutcome.notAuthorized:
                return .failure(code: AppleScriptOutcome.notAuthorized, message: "Automation not permitted for \(target)")
            case AppleScriptOutcome.appNotRunning:
                // `tell application id …` would launch it; a jump never launches apps.
                return .failure(code: AppleScriptOutcome.appNotRunning, message: "\(target) is not running")
            default:
                break   // granted, or undetermined for another reason: the script reports its own errors
            }
            guard job.mayRunAfterConsent() else {
                Log.info("applescript: dropped a \(handler) request that became stale during the consent dialog")
                return .skipped
            }
        }
        return execute(handler: handler, source: source, arguments: arguments)
    }

    /// Asks TCC (showing the consent dialog if needed) whether we may send Apple events to `bundleID`.
    private static func automationPermission(for bundleID: String) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        // A concrete event: with wildcards TCC answers errAEEventWouldRequireUserConsent without asking,
        // and the dialog would then pop up later inside the script, bypassing the staleness check.
        return AEDeterminePermissionToAutomateTarget(
            target.aeDesc, AEEventClass(kCoreEventClass), AEEventID(kAEGetData), true)
    }

    private func execute(handler: String, source: String, arguments: [String]) -> AppleScriptOutcome {
        dispatchPrecondition(condition: .onQueue(queue))
        var error: NSDictionary?
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else {
                return .failure(code: 0, message: "cannot create script")
            }
            guard fresh.compileAndReturnError(&error) else { return Self.failure(error) }
            compiled[source] = fresh
            script = fresh
        }

        let event = NSAppleEventDescriptor(
            eventClass: Self.fourCC("ascr"),                  // kASAppleScriptSuite
            eventID: Self.fourCC("psbr"),                     // kASSubroutineEvent
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        // Handler names are case-insensitive and must be sent lowercased.
        event.setParam(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: Self.fourCC("snam"))  // keyASSubroutineName
        let list = NSAppleEventDescriptor.list()
        for (i, arg) in arguments.enumerated() {
            list.insert(NSAppleEventDescriptor(string: arg), at: i + 1)
        }
        event.setParam(list, forKeyword: Self.fourCC("----"))  // keyDirectObject

        let result = script.executeAppleEvent(event, error: &error)
        if let error { return Self.failure(error) }
        return .success(result.stringValue)
    }

    private static func failure(_ error: NSDictionary?) -> AppleScriptOutcome {
        let code = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        let message = error?[NSAppleScript.errorMessage] as? String ?? "unknown AppleScript error"
        return .failure(code: code, message: message)
    }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// Runs a command-line tool (no shell) off the main thread with a hard timeout.
enum Subprocess {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
    }

    /// Returns nil if the tool can't be launched or doesn't exit within `timeout` (it is then killed).
    /// stderr is discarded; stdin is /dev/null.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> Output? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Output?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, arguments, timeout: timeout))
            }
        }
    }

    private static func runBlocking(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain stdout concurrently so a chatty tool can't block on a full pipe.
        let collected = DataBox()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            collected.data = pipe.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 0.5) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            _ = reader.wait(timeout: .now() + 0.5)
            return nil
        }
        _ = reader.wait(timeout: .now() + 1)
        return Output(status: process.terminationStatus, stdout: collected.data)
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }
}

/// Resumes a continuation exactly once, whichever of several racing callbacks comes first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
