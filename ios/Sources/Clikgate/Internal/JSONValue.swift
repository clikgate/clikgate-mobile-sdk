import Foundation

// JSON is handled with JSONSerialization and hand-written mappings instead of Codable:
// synthesized Codable conformances roughly doubled the SDK's binary size.

typealias JSONObject = [String: Any]

/// A JSON value. Used so model types stay `Sendable`; public API exposes `[String: Any]`.
enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Converts a Foundation value (app code, Flutter, JSONSerialization) to a JSON value.
    /// Returns nil for values that aren't JSON-compatible.
    init?(any value: Any?) {
        guard let value = value else { self = .null; return }
        switch value {
        case is NSNull: self = .null
        case let s as String: self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else if CFNumberIsFloatType(n) { self = .double(n.doubleValue) }
            else { self = .int(n.int64Value) }
        case let a as [Any?]:
            var out: [JSONValue] = []
            out.reserveCapacity(a.count)
            for e in a { guard let v = JSONValue(any: e) else { return nil }; out.append(v) }
            self = .array(out)
        case let o as [String: Any?]:
            var out: [String: JSONValue] = [:]
            for (k, e) in o { guard let v = JSONValue(any: e) else { return nil }; out[k] = v }
            self = .object(out)
        case let d as Date: self = .string(ISO8601.format(d))
        case let u as URL: self = .string(u.absoluteString)
        default: return nil
        }
    }

    /// Foundation representation (NSNull for null), suitable for JSONSerialization and Flutter.
    var anyValue: Any { Self.foundation(self) }

    @inline(never)
    private static func foundation(_ v: JSONValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return Int(truncatingIfNeeded: i)
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(foundation)
        case .object(let o): return dictionary(o)
        }
    }

    @inline(never)
    static func dictionary(_ o: [String: JSONValue]) -> [String: Any] {
        var out: [String: Any] = [:]
        out.reserveCapacity(o.count)
        for (k, v) in o { out[k] = foundation(v) }
        return out
    }

    static func object(from any: Any?) -> [String: JSONValue] {
        if case .object(let o)? = JSONValue(any: any as? JSONObject) { return o }
        return [:]
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    var anyDictionary: [String: Any] { JSONValue.dictionary(self) }
}

enum JSON {
    static func data(_ object: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func object(_ data: Data?) -> JSONObject? {
        guard let data = data, !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
    }

    static func size(_ object: Any) -> Int { data(object)?.count ?? Int.max }
}

/// Typed reads from a JSONSerialization dictionary (nil for missing / NSNull / wrong type).
extension Dictionary where Key == String, Value == Any {
    @inline(never) func str(_ k: String) -> String? { self[k] as? String }
    @inline(never) func bool(_ k: String) -> Bool? { (self[k] as? NSNumber).map { $0.boolValue } }
    /// A JSON number (not a boolean).
    @inline(never) func num(_ k: String) -> NSNumber? {
        guard let n = self[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n
    }
    @inline(never) func int(_ k: String) -> Int? { num(k)?.intValue }
    @inline(never) func int64(_ k: String) -> Int64? { num(k)?.int64Value }
    func double(_ k: String) -> Double? { num(k)?.doubleValue }
    @inline(never) func obj(_ k: String) -> JSONObject? { self[k] as? JSONObject }
    func objects(_ k: String) -> [JSONObject] { (self[k] as? [Any])?.compactMap { $0 as? JSONObject } ?? [] }
    func strings(_ k: String) -> [String] { (self[k] as? [Any])?.compactMap { $0 as? String } ?? [] }
    func date(_ k: String) -> Date? { double(k).map { Date(timeIntervalSince1970: $0) } }
}

/// Builds a JSON object, writing `NSNull` only where a key must be explicitly null.
struct JSONBuilder {
    private(set) var object: JSONObject = [:]
    /// Sets the value when non-nil (omits the key otherwise).
    mutating func set(_ k: String, _ v: Any?) { if let v = v { object[k] = v } }
    /// Sets the value, or JSON null.
    mutating func setOrNull(_ k: String, _ v: Any?) { object[k] = v ?? NSNull() }
    mutating func set(_ k: String, _ d: Date?) { if let d = d { object[k] = d.timeIntervalSince1970 } }
}

enum ISO8601 {
    static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func parse(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }
}
