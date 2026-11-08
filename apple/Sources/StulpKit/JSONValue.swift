import Foundation

/// Any JSON value. Stulp's API carries free-form values in a few places (capability values, Flow
/// arguments, settings, app API answers); those stay JSON here instead of being forced into a type
/// the server never promised.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var number: Double? { if case .number(let n) = self { n } else { nil } }
    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    public var isNull: Bool { self == .null }

    public subscript(key: String) -> JSONValue? { object?[key] }

    /// The value as text for a field: strings as is, numbers without a pointless ".0".
    public var text: String {
        switch self {
        case .null: ""
        case .bool(let b): b ? "true" : "false"
        case .number(let n): n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .string(let s): s
        case .array, .object:
            (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? ""
        }
    }

    /// A Foundation object for `JSONSerialization` and WebKit replies.
    public var foundation: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n
        case .string(let s): s
        case .array(let a): a.map(\.foundation)
        case .object(let o): o.mapValues(\.foundation)
        }
    }

    /// From a Foundation object (`JSONSerialization`, a WebKit message body).
    public init(foundation value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            // NSNumber hides Bool; CFBoolean is the only reliable test.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSONValue(foundation: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSONValue(foundation: $0) })
        default: self = .null
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByNilLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(nilLiteral: ()) { self = .null }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

/// Text that the server sends either as a plain string or as `{"nl": …, "en": …}` (titles from an
/// app's manifest). The app is Dutch, so Dutch wins, then English, then whatever is there.
public struct LocalizedText: Sendable, Hashable, Decodable {
    public let text: String

    public init(_ text: String) { self.text = text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            text = s
        } else if let o = try? c.decode([String: String].self) {
            text = o["nl"] ?? o["en"] ?? o.values.sorted().first ?? ""
        } else if let n = try? c.decode(Double.self) {
            text = JSONValue.number(n).text
        } else {
            text = ""
        }
    }

    public static func resolve(_ value: JSONValue?) -> String {
        switch value {
        case .string(let s): s
        case .object(let o): o["nl"]?.string ?? o["en"]?.string ?? ""
        case .number(let n): JSONValue.number(n).text
        default: ""
        }
    }
}
