import Foundation

extension TypeImplementation {
    /// What a value of a type is, which decides how the interpreter stores it. It is the source of
    /// truth: `Value.Storage` is how a value of such a type is encoded, and this file says how, in both
    /// directions. A type's representation says which storage its values have, and a value's storage
    /// says which representation its type has.
    enum Representation: CaseIterable, Sendable, Equatable {
        /// The kinds the interpreter stores itself, for speed. Each is otherwise an ordinary Swift
        /// type: it has a name, bridged members, conformances and extensions like any other.
        case bool, int, double, string, list, dictionary
        /// A Swift value kept as it is under its Swift name.
        case held
        /// Stored properties in declaration order, held by value: a struct a program declares.
        case record

        /// Swift's name for the type, for the kinds the interpreter stores itself: `Array` for a list.
        var name: String? {
            switch self {
            case .bool: "Bool"
            case .int: "Int"
            case .double: "Double"
            case .string: "String"
            case .list: "Array"
            case .dictionary: "Dictionary"
            case .held, .record: nil
            }
        }

        /// The representation of the type Swift calls `name`, if the interpreter stores its values.
        init?(named name: String) {
            guard let found = Self.allCases.first(where: { $0.name == name }) else { return nil }
            self = found
        }

        /// The annotation for the type, with what it holds not known, for the kinds the interpreter
        /// stores itself.
        var annotation: TypeAnnotation? {
            switch self {
            case .bool: .bool
            case .int: .int
            case .double: .double
            case .string: .string
            case .list: .list(.unknown)
            case .dictionary: .dictionary(.unknown, .unknown)
            case .held, .record: nil
            }
        }

        /// The representation of the type an annotation names, if the interpreter stores its values.
        init?(_ annotation: TypeAnnotation) {
            switch annotation {
            case .bool: self = .bool
            case .int: self = .int
            case .double: self = .double
            case .string: self = .string
            case .list: self = .list
            case .dictionary: self = .dictionary
            default: return nil
            }
        }

        /// The representation of the type a value with this storage is of, if the storage is one of
        /// the encodings of a representation known so far. An enum, a class instance, a
        /// tuple, a function and nothing have none yet.
        init?(encoding storage: Value.Storage) {
            switch storage {
            case .bool: self = .bool
            case .int: self = .int
            case .double: self = .double
            case .string: self = .string
            case .list: self = .list
            case .dictionary: self = .dictionary
            case .object(let object) where object is SwiftValue: self = .held
            case .structure: self = .record
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
    /// The representation of the type this is a value of, if its storage is one the interpreter
    /// knows the type of.
    var representation: TypeImplementation.Representation? {
        TypeImplementation.Representation(encoding: storage)
    }
}
