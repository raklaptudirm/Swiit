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

    /// Whether the value's type is `expected` or one it inherits from, by reference.
    func isInstance(ofReference expected: TypeRef) -> Bool {
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
