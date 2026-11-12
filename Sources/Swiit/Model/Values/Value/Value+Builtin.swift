extension Value {
    /// A type whose values Swiit holds as its own storage, for speed, and that is otherwise an
    /// ordinary Swift type: it has a name, bridged members, conformances and extensions like any
    /// other. This is the one place that says which storage is which type.
    enum Builtin: CaseIterable, Sendable {
        case bool, int, double, string, list, dictionary

        /// Swift's name for the type: what a script writes and what the bridge calls it.
        var name: String {
            switch self {
            case .bool: "Bool"
            case .int: "Int"
            case .double: "Double"
            case .string: "String"
            case .list: "Array"
            case .dictionary: "Dictionary"
            }
        }

        /// The type named, if Swiit holds it as its own storage.
        init?(named name: String) {
            guard let found = Self.allCases.first(where: { $0.name == name }) else { return nil }
            self = found
        }

        /// The type a value's storage is, if it is one of these.
        init?(_ storage: Value.Storage) {
            switch storage {
            case .bool: self = .bool
            case .int: self = .int
            case .double: self = .double
            case .string: self = .string
            case .list: self = .list
            case .dictionary: self = .dictionary
            default: return nil
            }
        }

        /// The type an annotation names, if it is one of these.
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

        /// The annotation for the type, with what it holds not known.
        var annotation: TypeAnnotation {
            switch self {
            case .bool: .bool
            case .int: .int
            case .double: .double
            case .string: .string
            case .list: .list(.unknown)
            case .dictionary: .dictionary(.unknown, .unknown)
            }
        }
    }
}
