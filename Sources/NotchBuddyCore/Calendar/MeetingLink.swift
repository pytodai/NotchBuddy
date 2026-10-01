import Foundation

/// Video-call services the island recognizes in an event's URL, location or notes.
public enum MeetingService: String, CaseIterable, Sendable {
    case zoom, googleMeet, teams, telemost, jazz, kontur, vkCalls, mtsLink, webex, facetime, whereby, jitsi,
         slack, discord

    public var displayName: String {
        switch self {
        case .zoom: return "Zoom"
        case .googleMeet: return "Google Meet"
        case .teams: return "Teams"
        case .telemost: return L("Телемост")
        case .jazz: return "SaluteJazz"
        case .kontur: return L("Контур.Толк")
        case .vkCalls: return L("VK Звонки")
        case .mtsLink: return L("МТС Линк")
        case .webex: return "Webex"
        case .facetime: return "FaceTime"
        case .whereby: return "Whereby"
        case .jitsi: return "Jitsi"
        case .slack: return "Slack"
        case .discord: return "Discord"
        }
    }
}

/// A link that joins an event's call.
public struct MeetingLink: Equatable, Hashable, Sendable {
    public var service: MeetingService
    public var url: URL

    public init(service: MeetingService, url: URL) {
        self.service = service
        self.url = url
    }
}

/// Finds the call link of an event. Only https links on the known services' own hosts count (an invite
/// is someone else's text: a link anywhere else is never offered as "Подключиться"), and only paths that
/// join a call (not Zoom's "find a local number", not Teams' meeting options).
public enum MeetingLinkDetector {
    /// Notes can be long (Teams and Zoom paste pages of dial-in numbers); the link is near the top.
    static let notesScanLimit = 40_000

    /// The event's own URL wins, then its location, then its notes.
    public static func detect(url: String?, location: String?, notes: String?) -> MeetingLink? {
        for text in [url, location, notes.map { String($0.prefix(notesScanLimit)) }] {
            guard let text, !text.isEmpty else { continue }
            for candidate in candidates(in: text) {
                if let link = classify(candidate) { return link }
            }
        }
        return nil
    }

    /// `https://…` substrings, trimmed of the punctuation and brackets text wraps them in.
    static func candidates(in text: String) -> [String] {
        var results: [String] = []
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: "https://", options: [.caseInsensitive], range: searchRange) {
            var end = range.upperBound
            while end < text.endIndex, !isTerminator(text[end]) { end = text.index(after: end) }
            var candidate = String(text[range.lowerBound..<end])
            while let last = candidate.last, ".,;:!?)]}>'\"»”".contains(last) { candidate.removeLast() }
            results.append(candidate)
            searchRange = end..<text.endIndex
        }
        return results
    }

    private static func isTerminator(_ c: Character) -> Bool {
        c.isWhitespace || "<>\"'«»“”[](){}|\\^`".contains(c)
    }

    static func classify(_ string: String) -> MeetingLink? {
        guard let components = URLComponents(string: string),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              let rawHost = components.host?.lowercased(), !rawHost.isEmpty,
              let url = components.url else { return nil }
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        let path = components.path
        let lower = path.lowercased()
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        func starts(_ prefixes: String...) -> Bool { prefixes.contains { lower.hasPrefix($0) } }

        let service: MeetingService?
        if on("zoom.us") || on("zoom.com") || on("zoomgov.com") {
            service = starts("/j/", "/my/", "/w/", "/s/", "/wc/join/", "/wc/") ? .zoom : nil
        } else if host == "meet.google.com" {
            let code = lower.dropFirst()
            service = (code.range(of: #"^[a-z]{3,}-[a-z]{3,}-[a-z]{3,}"#, options: .regularExpression) != nil
                || starts("/lookup/")) ? .googleMeet : nil
        } else if host == "teams.microsoft.com" || host == "teams.live.com" || host == "teams.cloud.microsoft" {
            service = (lower.contains("meetup-join") || starts("/meet/", "/l/meet/")) ? .teams : nil
        } else if on("telemost.yandex.ru") || on("telemost.360.yandex.ru") || host == "telemost.yandex.com" {
            service = starts("/j/") ? .telemost : nil
        } else if on("salutejazz.ru") || host == "jazz.sber.ru" {
            service = path.count > 1 ? .jazz : nil
        } else if on("ktalk.ru") {
            service = path.count > 1 ? .kontur : nil
        } else if host == "calls.vk.com" || ((host == "vk.com" || host == "vk.ru") && starts("/call/")) {
            service = path.count > 1 ? .vkCalls : nil
        } else if on("mts-link.ru") || on("my.mts-link.ru") {
            service = path.count > 1 ? .mtsLink : nil
        } else if on("webex.com") {
            service = (lower.contains("/meet") || lower.contains("j.php") || lower.contains("/join")) ? .webex : nil
        } else if host == "facetime.apple.com" {
            service = starts("/join") ? .facetime : nil
        } else if on("whereby.com") {
            service = path.count > 1 ? .whereby : nil
        } else if host == "meet.jit.si" || host == "8x8.vc" {
            service = path.count > 1 ? .jitsi : nil
        } else if host == "app.slack.com" {
            service = starts("/huddle/") ? .slack : nil
        } else if host == "discord.gg" || (host == "discord.com" && starts("/invite/", "/channels/")) {
            service = path.count > 1 ? .discord : nil
        } else {
            service = nil
        }
        return service.map { MeetingLink(service: $0, url: url) }
    }
}
