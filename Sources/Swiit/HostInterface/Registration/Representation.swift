import Foundation

extension ImplementedType {
    /// What a value of a type is, which decides how the interpreter stores it. It is the source of
    /// truth: `Value.Storage` is how a value of such a type is encoded, and this file says how, in both
    /// directions. A type's representation says which storage its values have, and a value's storage
    /// says which representation its type has.
    enum Representation: Sendable, Equatable {
        /// One of the kinds the interpreter stores itself, such as a list or a string.
        case builtin(Value.Builtin)
        /// A Swift value kept as it is under its Swift name.
        case held

        /// The representation of the type a value with this storage is of, if the storage is one of
        /// the encodings of a representation known so far. A struct, an enum, a class instance, a
        /// tuple, a function and nothing have none yet.
        init?(encoding storage: Value.Storage) {
            switch storage {
            case .bool: self = .builtin(.bool)
            case .int: self = .builtin(.int)
            case .double: self = .builtin(.double)
            case .string: self = .builtin(.string)
            case .list: self = .builtin(.list)
            case .dictionary: self = .builtin(.dictionary)
            case .object(let object) where object is SwiftValue: self = .held
            default: return nil
            }
        }

        /// Whether a value stored as `storage` is one a type with this representation can have.
        func encodes(_ storage: Value.Storage) -> Bool {
            Representation(encoding: storage) == self
        }
    }
}

extension Value {
    /// Which of the core's kinds this is a value of, if its storage is one of theirs.
    var builtinKind: Builtin? {
        if case .builtin(let kind)? = ImplementedType.Representation(encoding: storage) {
            kind
        } else {
            nil
        }
    }
}
