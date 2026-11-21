import Foundation

// Which declared type a value is an instance of.

extension Value {
    /// The type the value is of, as a reference: a script's struct, enum or class by its declaration's,
    /// a Swift type's by its name, and `Int`, `String`, `Array`, `Optional` (for `nil`) and the
    /// rest of Swift's own. Nil for a tuple or a function, which no type declares. The reference may name
    /// nothing the interpreter knows (an encoded Swift value's), and `TypeRef.symbol(in:)`
    /// then gives nil.
    public var typeRef: TypeRef? {
        switch self.storage {
        case .nothing: .optional
        case .bool: .bool
        case .int: .int
        case .double: .double
        case .string: .string
        case .list: .array
        case .dictionary: .dictionary
        case .tuple, .function: nil
        case .structure(let structure): structure.typeRef
        case .enumValue(let value): value.type.typeRef
        case .object(let object):
            if let instance = object as? ClassInstance {
                instance.type.typeRef
            } else if let box = object as? SwiftValue {
                .native(box.typeName)
            } else if object is any LanguageObject {
                nil
            } else {
                .native(object.typeName)
            }
        }
    }

    /// Whether the value is an instance of the type `expected` names: that exact type, a class that
    /// inherits from it, or `Any`, as Swift's `is` says. A struct value that came from a Swift
    /// value (an encoded one, or one a host built by the type's name) also counts as an instance of
    /// a script's type of the same name, which is how members and display already treat it. A
    /// protocol is not asked here, because that takes an interpreter. Use
    /// `TypeExpression.conforms(to:in:)` for that.
    public func isInstance(of expected: TypeRef) -> Bool {
        if expected == .any { return true }
        if case .function = self.storage { return expected == .function }
        guard let own = typeRef else { return false }
        if own == expected { return true }
        if case .structure(let structure) = self.storage, case .native = own.kind,
            case .declared = expected.kind, structure.typeName == expected.name
        {
            return true
        }
        if case .object(let object) = self.storage, let instance = object as? ClassInstance {
            var type = instance.type.superclass
            while let current = type {
                if current.typeRef == expected { return true }
                type = current.superclass
            }
        }
        return false
    }
}
