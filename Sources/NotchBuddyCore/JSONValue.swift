import Foundation

/// Arbitrary JSON value. Used to keep the agent's raw hook payload and to
/// build agent-specific output without per-agent Codable types.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // Integral values keep integer notation (a u64 `timeout` must not come back as `1e+16`).
            // Non-finite values have no JSON form; encoding them as null keeps the rest of the document.
            if let i = Int64(exactly: n) { try c.encode(i) }
            else if let u = UInt64(exactly: n) { try c.encode(u) }
            else if n.isFinite { try c.encode(n) }
            else { try c.encodeNil() }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func serialized(sortedKeys: Bool = true) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = sortedKeys ? [.sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
        return (try? e.encode(self)) ?? Data("null".utf8)
    }

    // MARK: Accessors

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    /// Follows a path of object keys, e.g. `value.at("tool_input", "command")`.
    public func at(_ path: String...) -> JSONValue? {
        var cur: JSONValue? = self
        for k in path { cur = cur?[k] }
        return cur
    }

    public var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return Self.numberText(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Integral values without a fraction ("42", not "42.0"). Never traps: `Int64(n)` would crash on
    /// integral values outside Int64 (e.g. a model-supplied `1e300` tool argument), so use `exactly:`.
    static func numberText(_ n: Double) -> String {
        if let i = Int64(exactly: n) { return String(i) }
        if let u = UInt64(exactly: n) { return String(u) }
        return String(n)
    }

    /// Compact single-line rendering for UI summaries.
    public var compactText: String {
        if let s = string { return s }
        return String(decoding: serialized(), as: UTF8.self)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
}
