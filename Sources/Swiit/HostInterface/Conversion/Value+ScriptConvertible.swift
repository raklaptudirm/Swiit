import Foundation

// A value from a Swift value, and a value read as a Swift type: what converts to and from values.

extension Value {
    /// A Swift value as a value: a number, text, a list, a dictionary, an optional, or any type that
    /// says scripts can have it (`extension URL: ScriptConvertible {}`).
    public init<T: ScriptConvertible>(_ value: T) { self = value.value }

    /// Whether the value is an instance of the Swift type `T`, as `casting(to:)` says.
    public func isInstance<T: ScriptConvertible>(of type: T.Type) -> Bool {
        casting(to: type) != nil
    }

    /// The value as a `T` if it is one: strict, as `as?` is. An `Int` is not a `Double`, and a list
    /// casts only if every element does. `try T(value)` is the throwing form, and converts as a
    /// script's call does.
    public func casting<T: ScriptConvertible>(to type: T.Type = T.self) -> T? {
        // The plain ones, which a host asks per item, without building a value to compare.
        switch storage {
        case .int(let value) where T.self == Int.self: return value as? T
        case .string(let value) where T.self == String.self: return value as? T
        case .bool(let value) where T.self == Bool.self: return value as? T
        case .double(let value) where T.self == Double.self: return value as? T
        case .list(let value) where T.self == [Value].self: return value as? T
        case _ where T.self == Value.self: return self as? T
        // A Swift value or object a script holds as it is, when it is a `T`.
        case .object(let box as SwiftValue): if let held = box.value as? T { return held }
        default: break
        }
        guard let result = try? T(self), result.value == self else { return nil }
        return result
    }

    /// What the value is, as a type that is no concrete one: a protocol (`any Presentable`) or `Any`.
    /// A Swift value or object a script holds as it is, if it conforms; a number, text or a flag, as
    /// the Swift value it is. Nil otherwise, and never a conversion: `casting(to:)` converts.
    public func casting<T>(toExistential type: T.Type) -> T? {
        switch storage {
        case .object(let box as SwiftValue): return box.value as? T
        case .object(let object): return object as? T
        case .int(let value): return value as? T
        case .double(let value): return value as? T
        case .bool(let value): return value as? T
        case .string(let text): return text as? T
        default: return nil
        }
    }
}
