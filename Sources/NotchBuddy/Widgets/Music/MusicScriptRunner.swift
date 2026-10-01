import AppKit
import CoreServices
import NotchBuddyCore

/// Whether NotchBuddy may send Apple events to a player (System Settings → Privacy → Automation).
enum MusicAccess: Equatable, Sendable {
    /// Not asked yet: the first click on a control asks (never anything else: a consent dialog must not
    /// appear because the island opened).
    case undetermined
    case granted
    case denied
}

/// What a player script returned.
enum MusicScriptResult: Sendable {
    case text(String)
    case data(Data)
    case nothing
    case notRunning
    case needsConsent
    case denied
    case failed(code: Int, message: String)
}

/// The player scripts, run in-process (NSAppleScript) on a private serial queue.
///
/// A script reaches a player only when it is already running: the runner checks first, and every handler
/// checks again (`application id … is running` does not launch anything) before its `tell`, so a player
/// that quit a moment ago is never relaunched. The Automation consent dialog is only ever shown with
/// `ask: true`, which the service passes for a click on a control.
final class MusicScriptRunner: @unchecked Sendable {
    static let shared = MusicScriptRunner()

    enum Handler: String, Sendable {
        case nowPlaying = "nowplaying"
        case artwork
        case playPause = "playpause"
        case next = "nexttrack"
        case previous = "previoustrack"
        case seek
    }

    private let queue = DispatchQueue(label: "me.sokolov.notchbuddy.music-script", qos: .userInitiated)
    /// Only touched on `queue`.
    private var compiled: [MusicPlayer: NSAppleScript] = [:]

    /// Automation for `player`: asks the user (a system dialog) only with `ask`. Never launches the player.
    func access(_ player: MusicPlayer, ask: Bool) async -> MusicAccess? {
        await onQueue { Self.permission(player, ask: ask) }
    }

    /// Runs `handler` of `player`'s script. Without `ask`, a missing consent is reported (`.needsConsent`),
    /// not asked for.
    func run(_ handler: Handler, on player: MusicPlayer, arguments: [String] = [], ask: Bool = false) async -> MusicScriptResult {
        await onQueue { [self] in
            switch Self.permission(player, ask: ask) {
            case nil: return .notRunning
            case .undetermined: return .needsConsent
            case .denied: return .denied
            case .granted: return execute(handler, player: player, arguments: arguments)
            }
        }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// nil: not running.
    private static func permission(_ player: MusicPlayer, ask: Bool) -> MusicAccess? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty else { return nil }
        let target = NSAppleEventDescriptor(bundleIdentifier: player.bundleID)
        // A concrete event (with wildcards TCC answers "would require consent" without ever asking).
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kCoreEventClass),
                                                           AEEventID(kAEGetData), ask)
        switch Int(status) {
        case Int(noErr): return .granted
        case -1743: return .denied        // errAEEventNotPermitted
        case -600: return nil             // procNotFound
        default: return .undetermined     // -1744 errAEEventWouldRequireUserConsent, or not answered
        }
    }

    private func execute(_ handler: Handler, player: MusicPlayer, arguments: [String]) -> MusicScriptResult {
        dispatchPrecondition(condition: .onQueue(queue))
        var error: NSDictionary?
        let script: NSAppleScript
        if let cached = compiled[player] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: MusicScripts.source(player)) else {
                return .failed(code: 0, message: "cannot create script")
            }
            guard fresh.compileAndReturnError(&error) else { return Self.failure(error) }
            compiled[player] = fresh
            script = fresh
        }
        let event = NSAppleEventDescriptor(eventClass: Self.fourCC("ascr"), eventID: Self.fourCC("psbr"),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: handler.rawValue), forKeyword: Self.fourCC("snam"))
        let list = NSAppleEventDescriptor.list()
        for (i, argument) in arguments.enumerated() {
            list.insert(NSAppleEventDescriptor(string: argument), at: i + 1)
        }
        event.setParam(list, forKeyword: Self.fourCC("----"))
        let result = script.executeAppleEvent(event, error: &error)
        if let error { return Self.failure(error) }
        switch result.descriptorType {
        case Self.fourCC("utxt"), Self.fourCC("TEXT"), Self.fourCC("utf8"):
            let text = result.stringValue ?? ""
            return text == "notrunning" ? .notRunning : .text(text)
        case Self.fourCC("null"), Self.fourCC("msng"), Self.fourCC("true"), Self.fourCC("fals"):
            return .nothing
        default:
            let data = result.data
            return data.isEmpty ? .nothing : .data(data)
        }
    }

    private static func failure(_ error: NSDictionary?) -> MusicScriptResult {
        let code = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        if code == -1743 { return .denied }
        if code == -600 { return .notRunning }
        return .failed(code: code, message: error?[NSAppleScript.errorMessage] as? String ?? "AppleScript error")
    }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// The scripts. Values never enter the source: `seek` gets its milliseconds as a handler argument.
/// Numbers leave as whole milliseconds (`div 1`), so no locale's decimal comma gets in the way.
enum MusicScripts {
    static func source(_ player: MusicPlayer) -> String {
        switch player {
        case .spotify: return spotify
        case .appleMusic: return music
        }
    }

    private static let helpers = """
    on txt(v)
        try
            if v is missing value then return ""
            return v as text
        end try
        return ""
    end txt
    """

    static let spotify = """
    \(helpers)

    on nowplaying()
        if application id "com.spotify.client" is not running then return "notrunning"
        set sep to character id 31
        with timeout of 3 seconds
            tell application id "com.spotify.client"
                set pstate to ""
                try
                    set pstate to (player state as text)
                end try
                if pstate is "stopped" or pstate is "" or pstate contains "kPSS" then return "stopped"
                try
                    set trk to current track
                on error
                    return pstate
                end try
                set pos to 0
                try
                    set pos to ((player position) * 1000) div 1
                end try
                set dur to 0
                try
                    set dur to (duration of trk) div 1
                end try
                return pstate & sep & my txt(id of trk) & sep & my txt(name of trk) & sep & my txt(artist of trk) & sep & my txt(album of trk) & sep & (dur as text) & sep & (pos as text) & sep & my txt(artwork url of trk)
            end tell
        end timeout
    end nowplaying

    on artwork()
        return ""
    end artwork

    on playpause()
        if application id "com.spotify.client" is not running then return "notrunning"
        with timeout of 3 seconds
            tell application id "com.spotify.client" to playpause
        end timeout
        return "ok"
    end playpause

    on nexttrack()
        if application id "com.spotify.client" is not running then return "notrunning"
        with timeout of 3 seconds
            tell application id "com.spotify.client" to next track
        end timeout
        return "ok"
    end nexttrack

    on previoustrack()
        if application id "com.spotify.client" is not running then return "notrunning"
        with timeout of 3 seconds
            tell application id "com.spotify.client" to previous track
        end timeout
        return "ok"
    end previoustrack

    on seek(ms)
        if application id "com.spotify.client" is not running then return "notrunning"
        with timeout of 3 seconds
            tell application id "com.spotify.client" to set player position to ((ms as integer) / 1000)
        end timeout
        return "ok"
    end seek
    """

    static let music = """
    \(helpers)

    on nowplaying()
        if application id "com.apple.Music" is not running then return "notrunning"
        set sep to character id 31
        with timeout of 3 seconds
            tell application id "com.apple.Music"
                set pstate to ""
                try
                    set pstate to (player state as text)
                end try
                if pstate is "stopped" or pstate is "" or pstate contains "kPSS" then return "stopped"
                try
                    set trk to current track
                on error
                    return pstate
                end try
                set nm to my txt(name of trk)
                set al to my txt(album of trk)
                try
                    set streamTitle to my txt(current stream title)
                    if streamTitle is not "" then
                        set al to nm
                        set nm to streamTitle
                    end if
                end try
                set dur to 0
                try
                    set dur to ((duration of trk) * 1000) div 1
                end try
                set pos to 0
                try
                    set pos to ((player position) * 1000) div 1
                end try
                return pstate & sep & my txt(persistent ID of trk) & sep & nm & sep & my txt(artist of trk) & sep & al & sep & (dur as text) & sep & (pos as text) & sep & ""
            end tell
        end timeout
    end nowplaying

    on artwork()
        if application id "com.apple.Music" is not running then return "notrunning"
        with timeout of 5 seconds
            tell application id "com.apple.Music"
                try
                    return raw data of artwork 1 of current track
                end try
                try
                    return data of artwork 1 of current track
                end try
            end tell
        end timeout
        return ""
    end artwork

    on playpause()
        if application id "com.apple.Music" is not running then return "notrunning"
        with timeout of 3 seconds
            tell application id "com.apple.Music" to playpause
        end timeout
        return "ok"
    end playpause

    on nexttrack()
        if application id "com.apple.Music" is not running then return "notrunning"
        with timeout of 3 seconds
            tell application id "com.apple.Music" to next track
        end timeout
        return "ok"
    end nexttrack

    on previoustrack()
        if application id "com.apple.Music" is not running then return "notrunning"
        with timeout of 3 seconds
            tell application id "com.apple.Music" to previous track
        end timeout
        return "ok"
    end previoustrack

    on seek(ms)
        if application id "com.apple.Music" is not running then return "notrunning"
        with timeout of 3 seconds
            tell application id "com.apple.Music" to set player position to ((ms as integer) / 1000)
        end timeout
        return "ok"
    end seek
    """
}
