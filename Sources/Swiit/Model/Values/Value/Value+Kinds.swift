import Foundation

// What kind a value is, and what Swift type it can be read as without a conversion.

extension Value {
    /// What a value is made of, as the interpreter says it. A host asks `typeRef`, `isInstance(of:)`
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
    public func casting(to type: TypeExpression) -> Value? {
        isInstance(of: type) ? self : nil
    }

    /// Whether the value is an instance of the type: a struct, an enum or a class by its
    /// reference, a list of ints, an optional string, `Any`, or a function. A class is also an
    /// instance of the classes it inherits from, as Swift's `is` says. A struct value that came
    /// from a Swift value (an encoded one, or one a host built by the type's name) also counts as
    /// an instance of a script's type of the same name, which is how members and display already
    /// treat it. A protocol is not asked here, because that takes an interpreter. Use
    /// `TypeExpression.conforms(to:in:)` for that.
    public func isInstance(of type: TypeExpression) -> Bool {
        matches(type)
    }

    private func matches(_ type: TypeExpression) -> Bool {
        switch type {
        case .named("Any"): return true
        case .named("Bool"): return kind == .bool
        case .named("Int"): return kind == .int
        case .named("Double"): return kind == .double
        case .named("String"): return kind == .string
        case .named("Function"), .function: return kind == .function
        case .named(let named):
            let arguments = named.arguments
            switch named.reference.name {
            case "Optional":
                return self == .nothing || arguments.first.map(matches) ?? true
            case "Array":
                guard case .list(let items) = self.storage else { return false }
                return items.allSatisfy { arguments.first.map($0.matches) ?? true }
            case "Dictionary":
                guard case .dictionary(let dictionary) = self.storage, arguments.count == 2 else {
                    return kind == .dictionary
                }
                return dictionary.allSatisfy {
                    $0.key.matches(arguments[0]) && $0.value.matches(arguments[1])
                }
            default: return isInstance(ofReference: named.reference)
            }
        case .tuple(let type):
            let elements = type.elements
            guard case .tuple(let tuple) = self.storage, tuple.count == elements.count
            else {
                return false
            }
            return zip(tuple, elements)
                .allSatisfy { field, element in
                    (element.label == nil || element.label == field.key)
                        && field.value.matches(element.type)
                }
        // A type used as a value is not a value of a type a host can ask about. Nor is a
        // generic parameter, which names no type.
        case .metatype, .parameter: return false
        }
    }

    /// The case of an enum, if this is one.
    var enumCase: Value.EnumCase? {
        if case .enumValue(let value) = self.storage { value } else { nil }
    }
}
