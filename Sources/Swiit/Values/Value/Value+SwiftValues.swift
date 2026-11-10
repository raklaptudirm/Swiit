import Foundation

// Making a value from a Swift value, and asking what kind it is.

extension Value {
    /// A Swift value as a value: a number, text, a list, a dictionary, an optional, or any type that
    /// says scripts can have it (`extension URL: ScriptConvertible {}`).
    public init<T: ScriptConvertible>(_ value: T) { self = value.value }

    /// What a value is made of, as the interpreter says it. A host asks `typeID`, `isInstance(of:)`
    /// and the views (`tuple`, `structure`, `enumCase`, `function`) instead, and makes its own
    /// taxonomy of them if it wants one to switch over.
    enum Kind: Sendable {
        case nothing, bool, int, double, string, list, dictionary
        case tuple, structure, enumeration, function, object
    }

    var kind: Kind {
        switch self.storage {
        case .nothing: .nothing
        case .bool: .bool
        case .int: .int
        case .double: .double
        case .string: .string
        case .list: .list
        case .dictionary: .dictionary
        case .tuple: .tuple
        case .structure: .structure
        case .enumValue: .enumeration
        case .function: .function
        case .object: .object
        }
    }

    /// The type the value is of, as an ID: a script's struct, enum or class by its declaration's,
    /// a Swift type's by its name, and `Int`, `String`, `Array`, `Optional` (for `nil`) and the
    /// rest of Swift's own. Nil for a tuple or a function, which no type declares. The ID may name
    /// nothing the interpreter knows (an encoded Swift value's), and `Symbol.ID.symbol(in:)`
    /// then gives nil.
    public var typeID: Symbol.ID? {
        switch self.storage {
        case .nothing: .optional
        case .bool: .bool
        case .int: .int
        case .double: .double
        case .string: .string
        case .list: .array
        case .dictionary: .dictionary
        case .tuple, .function: nil
        case .structure(let structure): structure.id
        case .enumValue(let value): value.type.id
        case .object(let object):
            if let instance = object as? ClassInstance {
                instance.type.id
            } else if let box = object as? SwiftValue {
                .host(box.typeName)
            } else if object is any LanguageObject {
                nil
            } else {
                .host(object.typeName)
            }
        }
    }

    /// Whether the value is an instance of the type `id` names: of exactly that type, of a class
    /// that inherits from it, or `Any`, as Swift's `is` says. A struct value that came from a
    /// Swift value (an encoded one, or one a host built by the type's name) also counts as an
    /// instance of a type a script declares of the same name, which members and display already
    /// treat it as. A protocol it conforms to is not asked here, since that takes an
    /// interpreter: `ScriptType.conforms(to:in:)` is.
    public func isInstance(of id: Symbol.ID) -> Bool {
        if id == .any { return true }
        if case .function = self.storage { return id == .function }
        guard let own = typeID else { return false }
        if own == id { return true }
        if case .structure(let structure) = self.storage, case .host = own.kind,
            case .declared = id.kind, structure.typeName == id.name
        {
            return true
        }
        if case .object(let object) = self.storage, let instance = object as? ClassInstance {
            var type = instance.type.superclass
            while let current = type {
                if current.id == id { return true }
                type = current.superclass
            }
        }
        return false
    }

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

    /// The value itself if it is of that script type (a struct or enum by name, a list of ints, an
    /// optional string), else nil.
    public func casting(to type: ScriptType) -> Value? {
        matches(type) ? self : nil
    }

    private func matches(_ type: ScriptType) -> Bool {
        switch type {
        case .named("Any", _): return true
        case .named("Bool", _): return kind == .bool
        case .named("Int", _): return kind == .int
        case .named("Double", _): return kind == .double
        case .named("String", _): return kind == .string
        case .named("Function", _), .function: return kind == .function
        case .named("Optional", let arguments):
            return self == .nothing || arguments.first.map(matches) ?? true
        case .named("Array", let arguments):
            guard case .list(let items) = self.storage else { return false }
            return items.allSatisfy { arguments.first.map($0.matches) ?? true }
        case .named("Dictionary", let arguments):
            guard case .dictionary(let dictionary) = self.storage, arguments.count == 2 else {
                return kind == .dictionary
            }
            return dictionary.allSatisfy {
                $0.key.matches(arguments[0]) && $0.value.matches(arguments[1])
            }
        case .named(let name, _):
            switch self.storage {
            case .structure(let structure): return structure.id == name
            case .enumValue(let value): return value.type.id == name
            case .object: return typeID == name
            default: return false
            }
        case .tuple(let elements):
            guard case .tuple(let tuple) = self.storage, tuple.count == elements.count
            else {
                return false
            }
            return zip(tuple, elements)
                .allSatisfy { field, element in
                    (element.label == nil || element.label == field.key)
                        && field.value.matches(element.type)
                }
        // A type used as a value is not a value of a type a host can ask about.
        case .metatype: return false
        }
    }

    /// The case of an enum, if this is one.
    var enumCase: Value.EnumCase? {
        if case .enumValue(let value) = self.storage { value } else { nil }
    }
}

extension Value {
    /// A date, held as the Swift value it is.
    static func date(_ date: Date) -> Value {
        SwiftValue.make(date, as: "Date")
    }

    /// The date it holds, if it's one.
    var date: Date? {
        if case .object(let box as SwiftValue) = self.storage { box.value as? Date } else { nil }
    }
}
