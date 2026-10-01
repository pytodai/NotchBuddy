import Foundation

/// What the app bundle says about self-updates: Sparkle's keys in Info.plist, the version it carries, and the
/// project's release pages.
///
/// Sparkle refuses to start (and its standard controller then shows an alert) with a public key that is not a
/// base64 Ed25519 key, so the app only starts the updater when `canUpdate` holds. Development builds keep the
/// placeholder key and simply have no updater.
public struct UpdateConfiguration: Equatable, Sendable {
    public static let repository = URL(string: "https://github.com/pytodai/NotchBuddy")!
    public static let releasesPage = repository.appendingPathComponent("releases")
    /// The value `Resources/Info.plist` carries until a release build fills in the real key.
    public static let placeholderKey = "SPARKLE_PUBLIC_KEY_PLACEHOLDER"

    public var version: String?
    public var build: String?
    public var feedURL: URL?
    public var publicEDKey: String?
    /// `SUEnableAutomaticChecks`: the default before the user changes it.
    public var checksAutomatically: Bool
    /// `SUScheduledCheckInterval`, seconds (Sparkle's own default is a day).
    public var checkInterval: TimeInterval
    /// `SUAllowsAutomaticUpdates`: whether «install automatically» may be offered at all.
    public var allowsAutomaticUpdates: Bool

    public init(infoDictionary info: [String: Any]) {
        version = Self.string(info["CFBundleShortVersionString"])
        build = Self.string(info["CFBundleVersion"])
        feedURL = Self.string(info["SUFeedURL"]).flatMap { URL(string: $0) }
        publicEDKey = Self.string(info["SUPublicEDKey"])
        checksAutomatically = Self.bool(info["SUEnableAutomaticChecks"]) ?? false
        checkInterval = Self.number(info["SUScheduledCheckInterval"]) ?? 86_400
        allowsAutomaticUpdates = Self.bool(info["SUAllowsAutomaticUpdates"]) ?? true
    }

    /// The running app's own configuration.
    public static var main: UpdateConfiguration { UpdateConfiguration(infoDictionary: Bundle.main.infoDictionary ?? [:]) }

    /// A 32-byte Ed25519 public key in base64 (what `generate_keys` prints).
    public var hasValidPublicKey: Bool {
        guard let key = publicEDKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              let data = Data(base64Encoded: key) else { return false }
        return data.count == 32
    }

    /// The updater can run: an https feed and a real signing key.
    public var canUpdate: Bool {
        feedURL?.scheme?.lowercased() == "https" && hasValidPublicKey
    }

    /// Why there is no updater, for the log; nil when there is one.
    public var problem: String? {
        guard let feedURL else { return "no SUFeedURL" }
        guard feedURL.scheme?.lowercased() == "https" else { return "the feed is not https" }
        if publicEDKey == nil || publicEDKey == Self.placeholderKey { return "no signing key in this build" }
        return hasValidPublicKey ? nil : "SUPublicEDKey is not an Ed25519 key"
    }

    /// The release page of a version (`v1.2` tags).
    public static func releasePage(version: String) -> URL {
        releasesPage.appendingPathComponent("tag").appendingPathComponent("v" + version)
    }

    // MARK: Info.plist values

    private static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let text as String:
            switch text.lowercased() {
            case "yes", "true", "1": return true
            case "no", "false", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    private static func number(_ value: Any?) -> TimeInterval? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let text as String: return TimeInterval(text)
        default: return nil
        }
    }
}
