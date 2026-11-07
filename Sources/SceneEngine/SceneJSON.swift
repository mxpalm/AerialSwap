import Foundation

/// A JSON value from a wallpaper's files, read the loose way Wallpaper Engine writes them: vectors are strings like
/// `"1 0.5 0"`, numbers and booleans stand in for each other, and any value may be `{"user": …, "value": …}`, a binding
/// to one of the wallpaper's properties.
public enum SceneJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SceneJSON])
    case object([String: SceneJSON])

    /// Parses JSON5 (comments, trailing commas and `Infinity` occur in the wild); a byte-order mark is skipped.
    public init(data: Data, name: String) throws {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed, .fragmentsAllowed])
        } catch {
            throw SceneError.malformed(name)
        }
        self = try Self(object, depth: 0, name: name)
    }

    private init(_ value: Any, depth: Int, name: String) throws {
        guard depth < SceneLimits.maxJSONDepth else { throw SceneError.tooLarge(name) }
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(try array.map { try Self($0, depth: depth + 1, name: name) })
        case let dictionary as [String: Any]:
            self = .object(try dictionary.mapValues { try Self($0, depth: depth + 1, name: name) })
        default: self = .null
        }
    }

    public subscript(key: String) -> SceneJSON? {
        if case .object(let dictionary) = self { return dictionary[key] }
        return nil
    }

    public var object: [String: SceneJSON]? { if case .object(let d) = self { d } else { nil } }
    public var array: [SceneJSON]? { if case .array(let a) = self { a } else { nil } }

    public var string: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        default: nil
        }
    }

    /// A finite number; numeric strings and booleans count.
    public var number: Double? {
        let value: Double? = switch self {
        case .number(let n): n
        case .bool(let b): b ? 1 : 0
        case .string(let s): Double(s.trimmingCharacters(in: .whitespaces))
        case .array(let a) where a.count == 1: a[0].number
        default: nil
        }
        return value.flatMap { $0.isFinite ? $0 : nil }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let b): b
        case .number(let n): n != 0
        case .string(let s): s == "true" || s == "1" ? true : (s == "false" || s == "0" ? false : nil)
        default: nil
        }
    }

    /// Components of a vector written as `"x y z"`, an array, or a single number. Non-finite parts make it nil.
    public var vector: [Double]? {
        let parts: [Double?] = switch self {
        case .string(let s): s.split(whereSeparator: { $0 == " " || $0 == "," }).map { Double($0) }
        case .array(let a): a.map(\.number)
        case .number(let n): [n]
        default: [nil]
        }
        let values = parts.compactMap { $0 }
        guard !values.isEmpty, values.count == parts.count, values.allSatisfy(\.isFinite) else { return nil }
        return values
    }

    /// The name of the property this value is bound to, when it's a `{"user": …}` binding. `user` is a name or
    /// `{"name": …, "condition": …}` (the binding then holds when the property equals the condition).
    public var userBinding: (name: String, condition: SceneJSON?)? {
        guard let user = self["user"] else { return nil }
        if let name = user.string { return (name, nil) }
        if let name = user["name"]?.string { return (name, user["condition"]) }
        return nil
    }

    /// This value with property bindings resolved against `properties` (name → current value). A binding whose
    /// property is unknown falls back to its `value`.
    public func resolved(_ properties: [String: SceneJSON]) -> SceneJSON {
        guard let binding = userBinding else {
            if case .object(let dictionary) = self, let value = dictionary["value"],
               dictionary.keys.allSatisfy({ $0 == "value" || $0 == "script" || $0 == "scriptproperties" }) {
                return value
            }
            return self
        }
        guard let bound = properties[binding.name] else { return self["value"] ?? .null }
        if let condition = binding.condition { return .bool(bound.string == condition.string) }
        return bound
    }
}
