import Foundation

// What kind a value is, and what Swift type it can be read as without a conversion.

extension Value {
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
