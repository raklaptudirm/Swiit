import Foundation

// The symbols that are types, and what belongs to a type besides its functions and properties.

extension Symbol {
    /// A type: which of the five kinds of nominal type Swift declares, the reference that names it, the
    /// types it is generic over and the protocols it conforms to. A type a script declares, a type a
    /// host offers and a type the core bridges are described the same way. What the type has (methods,
    /// properties, initializers, cases, associated types) is read with
    /// ``TypeExpression/members(named:in:)``.
    public struct Nominal: Symbol.Declaration {
        public var header: Header

        /// The five kinds of nominal type Swift declares.
        public enum Kind: Sendable, Hashable {
            case structure, enumeration, `class`, actor, `protocol`
        }

        public var kind: Kind
        /// The reference that names the type. A type that `check` describes before its source is run
        /// has a reference nothing is declared under yet.
        public var typeRef: TypeRef
        /// A generic type's parameters, `Element` for an array, each with what it must be.
        public var genericParameters: [GenericParameter]
        /// The protocols it conforms to, each with what its generic parameters must be for it: a
        /// `ClosedRange` is a `Sequence` when its `Bound` is an `Int`.
        public var conformances: [TypeRef: [GenericParameter]]

        /// The type of this symbol as a value: the type it names.
        public var typeExpression: TypeExpression { .named(typeRef) }

        public init(
            name: String,
            summary: String? = nil,
            attributes: [Attribute] = [],
            kind: Kind,
            typeRef: TypeRef,
            genericParameters: [GenericParameter] = [],
            conformances: [TypeRef: [GenericParameter]] = [:]
        ) {
            header = Header(name: name, summary: summary, attributes: attributes)
            self.kind = kind
            self.typeRef = typeRef
            self.genericParameters = genericParameters
            self.conformances = conformances
        }
    }

    /// A type parameter, with what it asks of the type given for it: `Element` in `Array<Element>`,
    /// `T` in `func f<T: Comparable>`.
    public struct GenericParameter: Symbol.Declaration {
        public var header: Header
        /// The requirements a type given for it must meet.
        public var constraints: [Constraint]

        /// The type of this symbol as a value: the parameter itself.
        public var typeExpression: TypeExpression { .parameter(name) }

        public init(name: String, constraints: [Constraint] = []) {
            header = Header(name: name)
            self.constraints = constraints
        }
    }

    /// A case of an enum: the values it carries (none for most), and its raw value when the enum has
    /// them.
    public struct EnumCase: Symbol.Declaration {
        public var header: Header
        /// The values it carries, each with its label if it has one.
        public var payload: [TypeExpression.TupleElement]
        public var rawValue: Value?

        public init(
            name: String,
            summary: String? = nil,
            attributes: [Attribute] = [],
            payload: [TypeExpression.TupleElement] = [],
            rawValue: Value? = nil
        ) {
            header = Header(name: name, summary: summary, attributes: attributes)
            self.payload = payload
            self.rawValue = rawValue
        }
    }

    /// An associated type, which a protocol asks of the types that conform to it and each of them
    /// binds: a sequence's `Element` is `String` for a sequence of text.
    public struct AssociatedType: Symbol.Declaration {
        public var header: Header
        public var role: Role

        /// Whether the symbol is what a protocol asks for or what a type binds it to.
        public enum Role: Sendable, Hashable {
            /// In a protocol: what the type that binds it must conform to.
            case requirement(constraints: [Constraint])
            /// In a type that conforms: the type it is bound to.
            case binding(TypeExpression)
        }

        /// The type of this symbol as a value: what it is bound to, or the parameter it stands for
        /// in the protocol.
        public var typeExpression: TypeExpression {
            if case .binding(let type) = role { type } else { .parameter(name) }
        }

        public init(
            name: String,
            summary: String? = nil,
            attributes: [Attribute] = [],
            role: Role
        ) {
            header = Header(name: name, summary: summary, attributes: attributes)
            self.role = role
        }
    }
}
