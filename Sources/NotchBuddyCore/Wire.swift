import Foundation

/// Bridge → app. One frame per connection.
public struct BridgeRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var event: AgentEvent
    /// true only for permission requests: the bridge then waits for one `BridgeReply`.
    public var expectsReply: Bool

    public init(event: AgentEvent, expectsReply: Bool, version: Int = BridgeRequest.currentVersion) {
        self.version = version
        self.event = event
        self.expectsReply = expectsReply
    }
}

/// App → bridge, only when `expectsReply`.
public struct BridgeReply: Codable, Equatable, Sendable {
    public var eventId: UUID
    public var decision: PermissionDecision

    public init(eventId: UUID, decision: PermissionDecision) {
        self.eventId = eventId
        self.decision = decision
    }
}

public enum WireError: Error, Equatable {
    case frameTooLarge(Int)
    case truncated
    case closed
}

/// Framing: 4-byte big-endian payload length, then JSON payload.
public enum Wire {
    public static let maxFrame = 8 * 1024 * 1024

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    public static func frame<T: Encodable>(_ value: T) throws -> Data {
        let payload = try encoder.encode(value)
        guard payload.count <= maxFrame else { throw WireError.frameTooLarge(payload.count) }
        var len = UInt32(payload.count).bigEndian
        var out = Data(bytes: &len, count: 4)
        out.append(payload)
        return out
    }

    /// Tries to take one complete frame from the front of `buffer`.
    /// Returns nil if more bytes are needed; removes consumed bytes on success.
    public static func takeFrame(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let b = [UInt8](buffer.prefix(4))
        let len = Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        guard len <= maxFrame else { throw WireError.frameTooLarge(len) }
        guard buffer.count >= 4 + len else { return nil }
        let payload = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + len)
        buffer.removeFirst(4 + len)
        return payload
    }

    public static func decode<T: Decodable>(_ type: T.Type, from payload: Data) throws -> T {
        try decoder.decode(type, from: payload)
    }
}
