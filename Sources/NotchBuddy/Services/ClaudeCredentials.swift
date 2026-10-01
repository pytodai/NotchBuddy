import Foundation
import NotchBuddyCore

/// Read-only view of the OAuth login Claude Code keeps in the login keychain. NotchBuddy never refreshes the token
/// and never writes the keychain or the credentials file: a refresh would rotate the refresh token and log Claude
/// Code out.
struct ClaudeCredentials: Sendable {
    let accessToken: String
    let expiresAt: Date?

    enum Failure: Error, Equatable, Sendable {
        /// No keychain item and no `~/.claude/.credentials.json`.
        case notFound
        /// The item exists but has no `claudeAiOauth` (e.g. only MCP tokens).
        case noOAuthLogin
        /// Expired or about to: Claude Code refreshes it on its next API call.
        case expired
        /// Token without `user:profile` (setup-token / inference-only) can't read usage.
        case missingScope
        case unreadable
        case timedOut
        /// The user switched «Лимиты Claude через API» off: the keychain is not touched.
        case disabled
    }

    static let keychainService = "Claude Code-credentials"
    /// Claude Code treats a token as expired 5 min early; so do we.
    static let expiryMargin: TimeInterval = 5 * 60
    static let securityTimeout: TimeInterval = 5

    /// Keychain account name as Claude Code computes it: the login name if it is "simple", else a constant.
    static var keychainAccount: String {
        let name = NSUserName()
        return name.range(of: #"^[a-zA-Z0-9._-]+$"#, options: .regularExpression) != nil ? name : "claude-code-user"
    }

    /// Reads via `/usr/bin/security` (the Claude-created item's ACL trusts it, so no consent prompt),
    /// then falls back to the documented plaintext store.
    static func load(now: Date = Date()) async -> Result<ClaudeCredentials, Failure> {
        guard UsageFetcher.isNetworkEnabled() else { return .failure(.disabled) }
        let args = ["find-generic-password", "-s", keychainService, "-a", keychainAccount, "-w"]
        guard let out = await Subprocess.run("/usr/bin/security", args, timeout: securityTimeout) else {
            return .failure(.timedOut)
        }
        if out.status == 0 {
            return parse(decodeSecurityOutput(out.stdout), now: now)
        }
        // 44 = errSecItemNotFound; other codes (locked keychain, denied) are treated the same way.
        if let data = try? Data(contentsOf: plaintextFile) {
            return parse(data, now: now)
        }
        return .failure(.notFound)
    }

    static var plaintextFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
    }

    /// Parses `{"claudeAiOauth":{"accessToken":…,"expiresAt":<epoch ms>,"scopes":[…]}}`.
    static func parse(_ data: Data, now: Date) -> Result<ClaudeCredentials, Failure> {
        guard let json = try? JSONValue.parse(data) else { return .failure(.unreadable) }
        guard let oauth = json["claudeAiOauth"], oauth.object != nil,
              let token = oauth["accessToken"]?.string, !token.isEmpty else { return .failure(.noOAuthLogin) }
        if let scopes = oauth["scopes"]?.array?.compactMap(\.string), !scopes.isEmpty, !scopes.contains("user:profile") {
            return .failure(.missingScope)
        }
        let expiresAt = oauth["expiresAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
        if let expiresAt, now.addingTimeInterval(expiryMargin) >= expiresAt {
            return .failure(.expired)
        }
        return .success(ClaudeCredentials(accessToken: token, expiresAt: expiresAt))
    }

    /// `security -w` prints the secret as-is, or as bare hex when it holds non-printable bytes.
    static func decodeSecurityOutput(_ raw: Data) -> Data {
        let text = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.hasPrefix("{"), text.count % 2 == 0,
              text.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil else { return Data(text.utf8) }
        var bytes = [UInt8]()
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return Data(text.utf8) }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}

/// Keeps the token out of logs, `print`, `dump` and string interpolation.
extension ClaudeCredentials: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "ClaudeCredentials(token: <redacted>, expiresAt: \(expiresAt.map { "\($0)" } ?? "nil"))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["expiresAt": expiresAt as Any]) }
}
