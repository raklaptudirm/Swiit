import Foundation

// Which declared type a value is an instance of.

extension Value {
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
}
